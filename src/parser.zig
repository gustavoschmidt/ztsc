//! Recursive-descent TypeScript parser (M2) producing the data-oriented AST.
//!
//! Design decisions (documented per the M2 plan):
//!
//! - **The parser drives the scanner with grammar context** (tsc-shaped):
//!   it pulls tokens from `scanner.Scanner` through a small lookahead queue
//!   and appends them to the SoA token arrays *as they are consumed*. Where
//!   lexing is grammar-dependent the parser rescans: `/` in expression
//!   position becomes a regex via `reScanSlashAsRegex`, a `}` closing a
//!   template substitution becomes a middle/tail via `reScanTemplateToken`,
//!   and maximal-munched `>>`/`>>=`/... tokens are *split* when a `>` closes
//!   type arguments (the consumed `>` is appended, the remainder becomes the
//!   current token — no array surgery, because unconsumed tokens are never
//!   in the arrays yet). `<<` is split the same way when `<` opens nested
//!   type arguments.
//! - **Speculation via snapshot/restore** (tsc's lookAhead/tryParse): arrow
//!   functions vs. parenthesized expressions, generic calls vs. relational
//!   `<`, and function types vs. parenthesized types are disambiguated by
//!   parsing speculatively; on failure the token/node/extra/diagnostic
//!   arrays are truncated and the scanner rewound. While speculating
//!   (`spec > 0`), grammar mismatches raise `error.Backtrack` instead of
//!   recording diagnostics.
//! - **Generic-call heuristic**: `expr < ...` is treated as type arguments
//!   only if the `<...>` parses as a type list AND the next token is `(`
//!   (so `f<T>(x)` is a generic call, and `a < b > (c)` — which also
//!   satisfies this — parses as a generic call *exactly like tsc*). Bare
//!   instantiation expressions (`f<T>;`) and generic tagged templates
//!   (`f<T>\`x\``) are NOT recognized and fall back to relational operators;
//!   this is a documented deviation from tsc 4.7+.
//! - **ASI** uses the scanner's preceded-by-newline flags: a statement may
//!   end at `;`, `}`, EOF, or a line break. Restricted productions are
//!   honored: no line break before postfix `++`/`--`, after `return`/
//!   `break`/`continue`/`throw`, or before `=>`.
//! - **Error recovery**: every diagnostic-producing path leaves the parser
//!   at a well-defined token; statement/list loops guarantee progress (every
//!   iteration consumes at least one token or exits), so the parser can
//!   never hang. After a malformed statement the parser synchronizes at a
//!   statement boundary. Random byte/token soup terminates with diagnostics
//!   and a partial tree (stress-asserted in tests).
//! - **Out-of-subset syntax** (enums, namespaces, decorators, mapped/
//!   conditional/template-literal types, JSX, `import =`, ...) produces an
//!   `.unsupported` node covering the construct's token range plus an
//!   `unsupported_syntax` diagnostic. Sub-terms parsed while measuring the
//!   construct's extent may remain in `nodes` unreferenced by the tree
//!   (harmless; the corpus contains none).
//! - Expression-position destructuring (`[a, b] = c`) keeps the literal
//!   cover grammar (LHS stays an array/object literal), like tsc's parse
//!   tree before binding. Declarations and parameters get true pattern
//!   nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const TokTag = scanner.Tag;
const Token = scanner.Token;
const Node = ast.Node;
const null_node = ast.null_node;
const Code = diagnostics.Code;

pub const Error = error{OutOfMemory};
/// Internal error set: Backtrack is only raised while speculating and never
/// escapes `parse`.
const PE = error{ OutOfMemory, Backtrack };

/// Parse `src` into a sealed Ast. All output lives in `gpa` (the per-file
/// arena). Never fails on malformed input — only on OOM / oversized source.
/// True for source whose extension enables JSX (`.tsx` / `.jsx`). In these
/// files `<` in expression position begins a JSX element rather than a
/// type assertion / relational operator.
pub fn isJsxPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx");
}

pub fn parse(gpa: Allocator, src: []const u8) error{ OutOfMemory, SourceTooLarge }!ast.Ast {
    return parseOpts(gpa, src, false);
}

pub fn parseOpts(gpa: Allocator, src: []const u8, jsx: bool) error{ OutOfMemory, SourceTooLarge }!ast.Ast {
    if (src.len > scanner.max_source_len) return error.SourceTooLarge;
    // Build the AST in a transient scratch arena so the growable lists'
    // doubling reallocs and their final tail slack are freed here, then
    // seal exact-size copies into `gpa` (the retained per-file arena). The
    // AST is pointer-free u32 data, so a flat copy is self-consistent.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var p: Parser = .{
        .gpa = scratch.allocator(),
        .out = gpa,
        .src = src,
        .scn = scanner.Scanner.init(src),
        .jsx = jsx,
    };
    p.parseRoot() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Backtrack => unreachable, // spec == 0 at top level
    };
    return p.sealInto(gpa);
}

const max_la = 4;

const Parser = struct {
    /// Transient arena: all growable lists live here during the parse.
    gpa: Allocator,
    /// Retained per-file arena: the sealed AST is copied here.
    out: Allocator,
    src: []const u8,
    scn: scanner.Scanner,
    /// JSX enabled (`.tsx`/`.jsx`): `<` in expression position starts an
    /// element. Off in `.ts`, where `<T>x` is a type assertion.
    jsx: bool = false,

    /// Lookahead queue of scanned-but-not-consumed tokens; la[0] is current.
    la: [max_la]Token = undefined,
    la_len: u8 = 0,

    tok_tags: std.ArrayList(TokTag) = .empty,
    tok_starts: std.ArrayList(u32) = .empty,
    nodes: std.MultiArrayList(ast.NodeItem) = .empty,
    extra: std.ArrayList(u32) = .empty,
    scratch: std.ArrayList(u32) = .empty,
    diags: std.ArrayList(ast.Diagnostic) = .empty,

    /// Speculation depth; > 0 makes expectation failures raise Backtrack.
    spec: u32 = 0,

    /// Copy the parsed lists into `out` at exact size. `out` is an arena, so
    /// each `dupe`/`setCapacity` is a single tight allocation with no slack
    /// and no stranded intermediate buffers (those stay in the scratch arena
    /// and are freed when `parse` returns).
    fn sealInto(p: *Parser, out: Allocator) Error!ast.Ast {
        const tags = try out.dupe(TokTag, p.tok_tags.items);
        const starts = try out.dupe(u32, p.tok_starts.items);
        const extra_data = try out.dupe(u32, p.extra.items);
        const diags = try out.dupe(ast.Diagnostic, p.diags.items);

        // Seal the node SoA: exact-size backing in `out`, field-by-field copy.
        var nodes: std.MultiArrayList(ast.NodeItem) = .empty;
        try nodes.setCapacity(out, p.nodes.len);
        nodes.len = p.nodes.len;
        const src_nodes = p.nodes.slice();
        const dst_nodes = nodes.slice();
        @memcpy(dst_nodes.items(.tag), src_nodes.items(.tag));
        @memcpy(dst_nodes.items(.main_token), src_nodes.items(.main_token));
        @memcpy(dst_nodes.items(.data), src_nodes.items(.data));

        return .{
            .tokens = .{ .tags = tags, .starts = starts },
            .nodes = nodes.toOwnedSlice(),
            .extra_data = extra_data,
            .diagnostics = diags,
        };
    }

    // =====================================================================
    // token plumbing
    // =====================================================================

    fn fill(p: *Parser, n: usize) void {
        while (p.la_len <= n) {
            p.la[p.la_len] = p.scn.next();
            p.la_len += 1;
        }
    }

    fn cur(p: *Parser) Token {
        p.fill(0);
        return p.la[0];
    }

    fn curTag(p: *Parser) TokTag {
        return p.cur().tag;
    }

    fn peekTag(p: *Parser, n: usize) TokTag {
        std.debug.assert(n < max_la);
        p.fill(n);
        return p.la[n].tag;
    }

    fn peekNewline(p: *Parser, n: usize) bool {
        std.debug.assert(n < max_la);
        p.fill(n);
        return p.la[n].newline_before;
    }

    /// True if a line break precedes the current token.
    fn nlBefore(p: *Parser) bool {
        return p.cur().newline_before;
    }

    /// Token index the current token will get when consumed.
    fn curIdx(p: *Parser) u32 {
        return @intCast(p.tok_tags.items.len);
    }

    /// Source text of the n-th lookahead token (not yet consumed).
    fn laText(p: *Parser, n: usize) []const u8 {
        std.debug.assert(n < max_la);
        p.fill(n);
        const t = p.la[n];
        const end = scanner.tokenEnd(p.src, t.tag, t.start);
        return p.src[t.start..end];
    }

    /// If positioned at a well-known-symbol computed name `[Symbol.<name>]`
    /// (e.g. `[Symbol.iterator]`), consume the four tokens `[ Symbol . <name>`
    /// plus the closing `]`, and return the `<name>` token index. The member
    /// is then keyed by a synthetic atom (see `ast.wellKnownSymbolKey`); the
    /// `Symbol.<name>` key expression itself is discarded (it has no runtime
    /// meaning here). Returns null — consuming nothing — if the shape does not
    /// match or `<name>` is a well-known symbol ztsc does not model.
    fn eatWellKnownSymbolName(p: *Parser) Error!?u32 {
        if (p.curTag() != .l_bracket) return null;
        if (!isNameLike(p.peekTag(1)) or !std.mem.eql(u8, p.laText(1), "Symbol")) return null;
        if (p.peekTag(2) != .dot) return null;
        if (!isNameLike(p.peekTag(3))) return null;
        if (ast.wellKnownSymbolKey(p.laText(3)) == null) return null;
        _ = try p.bump(); // [
        _ = try p.bump(); // Symbol
        _ = try p.bump(); // .
        const name_tok = try p.bump(); // <name>
        _ = try p.eat(.r_bracket); // ] (best-effort; recovery handles malformed)
        return name_tok;
    }

    /// Index of the last consumed token (0 if none yet).
    fn lastIdx(p: *Parser) u32 {
        const n = p.tok_tags.items.len;
        return if (n == 0) 0 else @intCast(n - 1);
    }

    /// Consume the current token, appending it to the SoA arrays.
    fn bump(p: *Parser) Error!u32 {
        const t = p.cur();
        std.debug.assert(t.tag != .eof);
        const idx = p.curIdx();
        try p.appendTok(t);
        p.la_len -= 1;
        std.mem.copyForwards(Token, p.la[0..p.la_len], p.la[1 .. p.la_len + 1]);
        return idx;
    }

    fn appendTok(p: *Parser, t: Token) Error!void {
        try p.tok_tags.append(p.gpa, t.tag);
        try p.tok_starts.append(
            p.gpa,
            t.start | @as(u32, if (t.newline_before) scanner.Tokens.newline_flag else 0),
        );
    }

    fn eat(p: *Parser, tag: TokTag) Error!?u32 {
        if (p.curTag() != tag) return null;
        return try p.bump();
    }

    /// Consume `tag` or report `code`. On failure the current token is NOT
    /// consumed and the returned index anchors to the last consumed token.
    fn expect(p: *Parser, tag: TokTag, code: Code) PE!u32 {
        if (p.curTag() == tag) return p.bump();
        try p.fail(code);
        return p.lastIdx();
    }

    /// Record a diagnostic at the current token, or Backtrack if speculating.
    fn fail(p: *Parser, code: Code) PE!void {
        if (p.spec > 0) return error.Backtrack;
        try p.errAtCur(code);
    }

    fn errAtCur(p: *Parser, code: Code) Error!void {
        const t = p.cur();
        const end = if (t.end > t.start) t.end else t.start + 1;
        try p.diags.append(p.gpa, .{
            .code = code,
            .span = .{ .start = t.start, .end = @min(end, @as(u32, @intCast(p.src.len)) + 1) },
        });
    }

    fn errAtToken(p: *Parser, code: Code, tok: u32) Error!void {
        const start = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
        const end = scanner.tokenEnd(p.src, p.tok_tags.items[tok], start);
        try p.diags.append(p.gpa, .{
            .code = code,
            .span = .{ .start = start, .end = if (end > start) end else start + 1 },
        });
    }

    fn tokTagAt(p: *Parser, tok: u32) TokTag {
        return p.tok_tags.items[tok];
    }

    // --- rescanning (grammar-context lexing) -----------------------------

    /// Current `/` or `/=` becomes a regex literal.
    fn rescanRegex(p: *Parser) void {
        p.fill(0);
        p.la[0] = p.scn.reScanSlashAsRegex(p.la[0]);
        p.la_len = 1; // drop lookahead scanned past the regex start
    }

    /// Current `}` becomes a template middle/tail part.
    fn rescanTemplatePart(p: *Parser) void {
        p.fill(0);
        p.la[0] = p.scn.reScanTemplateToken(p.la[0]);
        p.la_len = 1;
    }

    /// Consume a `>` out of a maximal-munched `>`-family token; the
    /// remainder becomes the current token.
    fn splitGt(p: *Parser) Error!u32 {
        p.fill(0);
        const t = p.la[0];
        const idx = p.curIdx();
        try p.appendTok(.{ .tag = .gt, .start = t.start, .end = t.start + 1, .newline_before = t.newline_before });
        const rem: TokTag = switch (t.tag) {
            .gt_gt => .gt,
            .gt_gt_gt => .gt_gt,
            .gt_eq => .eq,
            .gt_gt_eq => .gt_eq,
            .gt_gt_gt_eq => .gt_gt_eq,
            else => unreachable,
        };
        p.la[0] = .{ .tag = rem, .start = t.start + 1, .end = t.end, .newline_before = false };
        return idx;
    }

    /// Consume a `<` out of `<<` / `<<=`; the remainder becomes current.
    fn splitLt(p: *Parser) Error!u32 {
        p.fill(0);
        const t = p.la[0];
        const idx = p.curIdx();
        try p.appendTok(.{ .tag = .lt, .start = t.start, .end = t.start + 1, .newline_before = t.newline_before });
        const rem: TokTag = switch (t.tag) {
            .lt_lt => .lt,
            .lt_lt_eq => .lt_eq,
            else => unreachable,
        };
        p.la[0] = .{ .tag = rem, .start = t.start + 1, .end = t.end, .newline_before = false };
        return idx;
    }

    /// Consume a closing `>` of type args/params, splitting compound tokens.
    fn expectGt(p: *Parser) PE!u32 {
        switch (p.curTag()) {
            .gt => return p.bump(),
            .gt_gt, .gt_gt_gt, .gt_eq, .gt_gt_eq, .gt_gt_gt_eq => return p.splitGt(),
            else => {
                try p.fail(.expected_gt);
                return p.lastIdx();
            },
        }
    }

    /// Consume an opening `<` of type args/params, splitting `<<`.
    fn expectLt(p: *Parser) PE!u32 {
        switch (p.curTag()) {
            .lt => return p.bump(),
            .lt_lt, .lt_lt_eq => return p.splitLt(),
            else => {
                try p.fail(.expected_lt);
                return p.lastIdx();
            },
        }
    }

    fn atLt(p: *Parser) bool {
        return switch (p.curTag()) {
            .lt, .lt_lt, .lt_lt_eq => true,
            else => false,
        };
    }

    // --- speculation -------------------------------------------------------

    const State = struct {
        scn_index: u32,
        la: [max_la]Token,
        la_len: u8,
        n_tokens: usize,
        n_nodes: usize,
        n_extra: usize,
        n_scratch: usize,
        n_diags: usize,
    };

    fn save(p: *Parser) State {
        return .{
            .scn_index = p.scn.index,
            .la = p.la,
            .la_len = p.la_len,
            .n_tokens = p.tok_tags.items.len,
            .n_nodes = p.nodes.len,
            .n_extra = p.extra.items.len,
            .n_scratch = p.scratch.items.len,
            .n_diags = p.diags.items.len,
        };
    }

    fn restore(p: *Parser, s: State) void {
        p.scn.index = s.scn_index;
        p.la = s.la;
        p.la_len = s.la_len;
        p.tok_tags.shrinkRetainingCapacity(s.n_tokens);
        p.tok_starts.shrinkRetainingCapacity(s.n_tokens);
        p.nodes.shrinkRetainingCapacity(s.n_nodes);
        p.extra.shrinkRetainingCapacity(s.n_extra);
        p.scratch.shrinkRetainingCapacity(s.n_scratch);
        p.diags.shrinkRetainingCapacity(s.n_diags);
    }

    // --- node construction -------------------------------------------------

    fn addNode(p: *Parser, item: ast.NodeItem) Error!Node {
        const i: Node = @intCast(p.nodes.len);
        try p.nodes.append(p.gpa, item);
        return i;
    }

    fn addExtra(p: *Parser, extra: anytype) Error!u32 {
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        try p.extra.ensureUnusedCapacity(p.gpa, fields.len);
        const i: u32 = @intCast(p.extra.items.len);
        inline for (fields) |field| {
            comptime std.debug.assert(field.type == u32);
            p.extra.appendAssumeCapacity(@field(extra, field.name));
        }
        return i;
    }

    /// Copy `items` (node indices) into extra_data, returning the range.
    fn listToSpan(p: *Parser, items: []const u32) Error!ast.SubRange {
        try p.extra.appendSlice(p.gpa, items);
        return .{
            .start = @intCast(p.extra.items.len - items.len),
            .end = @intCast(p.extra.items.len),
        };
    }

    fn scratchTop(p: *Parser) usize {
        return p.scratch.items.len;
    }

    fn pushScratch(p: *Parser, node: Node) Error!void {
        try p.scratch.append(p.gpa, node);
    }

    fn scratchToSpan(p: *Parser, top: usize) Error!ast.SubRange {
        return p.listToSpan(p.scratch.items[top..]);
    }

    fn errorNode(p: *Parser) Error!Node {
        return p.addNode(.{ .tag = .error_node, .main_token = p.lastIdx(), .data = .{ .lhs = 0, .rhs = 0 } });
    }

    /// Build an `.unsupported` node spanning tokens `start_tok..last
    /// consumed`, with the subset-boundary diagnostic.
    fn unsupportedFrom(p: *Parser, start_tok: u32) PE!Node {
        if (p.spec > 0) return error.Backtrack;
        const last = @max(start_tok, p.lastIdx());
        try p.errAtToken(.unsupported_syntax, start_tok);
        return p.addNode(.{ .tag = .unsupported, .main_token = start_tok, .data = .{ .lhs = 0, .rhs = last } });
    }

    // --- classification helpers ------------------------------------------

    /// Tokens acceptable as an identifier/binding name (ztsc is
    /// always-strict, but strict-reserved words are accepted at parse level
    /// and left to the binder — documented deviation to keep recovery sane).
    fn isIdentLike(tag: TokTag) bool {
        return tag == .identifier or tag.isContextualKeyword() or tag.isStrictReservedKeyword();
    }

    /// Tokens acceptable as a member/property name (any keyword works).
    fn isNameLike(tag: TokTag) bool {
        return tag == .identifier or tag == .private_identifier or tag.isKeyword();
    }

    fn isAssignOp(tag: TokTag) bool {
        return switch (tag) {
            .eq, .plus_eq, .minus_eq, .asterisk_eq, .asterisk_asterisk_eq, .slash_eq, .percent_eq, .lt_lt_eq, .gt_gt_eq, .gt_gt_gt_eq, .amp_eq, .pipe_eq, .caret_eq, .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => true,
            else => false,
        };
    }

    /// Binary operator precedence; 0 = not a binary operator here.
    fn binaryPrec(tag: TokTag, no_in: bool) u8 {
        return switch (tag) {
            .question_question => 1,
            .pipe_pipe => 2,
            .amp_amp => 3,
            .pipe => 4,
            .caret => 5,
            .amp => 6,
            .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => 7,
            .lt, .gt, .lt_eq, .gt_eq, .keyword_instanceof => 8,
            .keyword_in => if (no_in) 0 else 8,
            .lt_lt, .gt_gt, .gt_gt_gt => 9,
            .plus, .minus => 10,
            .asterisk, .slash, .percent => 11,
            .asterisk_asterisk => 12,
            else => 0,
        };
    }

    fn canStartExpression(tag: TokTag) bool {
        return switch (tag) {
            .identifier,
            .private_identifier,
            .numeric_literal,
            .bigint_literal,
            .string_literal,
            .regexp_literal,
            .no_substitution_template_literal,
            .template_head,
            .l_paren,
            .l_bracket,
            .l_brace,
            .slash,
            .slash_eq,
            .plus,
            .minus,
            .bang,
            .tilde,
            .plus_plus,
            .minus_minus,
            .lt,
            .lt_lt,
            .keyword_this,
            .keyword_super,
            .keyword_true,
            .keyword_false,
            .keyword_null,
            .keyword_new,
            .keyword_function,
            .keyword_class,
            .keyword_typeof,
            .keyword_void,
            .keyword_delete,
            .keyword_import,
            .unterminated_string_literal,
            .unterminated_template,
            .unterminated_regexp_literal,
            => true,
            else => isIdentLike(tag),
        };
    }

    // =====================================================================
    // statements
    // =====================================================================

    fn parseRoot(p: *Parser) PE!void {
        // Node 0 is the root; extra_data[0] is the reserved none-sentinel.
        _ = try p.addNode(.{ .tag = .root, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
        try p.extra.append(p.gpa, 0);

        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.parseStatementList(top, .eof);
        const range = try p.scratchToSpan(top);
        p.nodes.items(.data)[0] = .{ .lhs = range.start, .rhs = range.end };

        // Seal the token stream with the eof token.
        const t = p.cur();
        std.debug.assert(t.tag == .eof);
        try p.appendTok(t);
    }

    /// Parse statements until `terminator` (or eof), pushing them on
    /// scratch. Guarantees progress on every iteration.
    fn parseStatementList(p: *Parser, top: usize, terminator: TokTag) PE!void {
        _ = top;
        while (p.curTag() != terminator and p.curTag() != .eof) {
            const before = p.curIdx();
            const stmt = try p.parseStatement();
            try p.pushScratch(stmt);
            if (p.curIdx() == before) {
                // The statement consumed nothing: force progress, then
                // synchronize at a statement boundary.
                try p.errAtCur(.unexpected_token);
                _ = try p.bump();
                p.synchronize();
            }
        }
    }

    /// Skip tokens (silently) until a plausible statement boundary.
    fn synchronize(p: *Parser) void {
        while (true) {
            switch (p.curTag()) {
                .eof, .semicolon, .r_brace, .l_brace => return,
                .keyword_var,
                .keyword_let,
                .keyword_const,
                .keyword_function,
                .keyword_class,
                .keyword_interface,
                .keyword_if,
                .keyword_while,
                .keyword_do,
                .keyword_for,
                .keyword_switch,
                .keyword_try,
                .keyword_return,
                .keyword_throw,
                .keyword_break,
                .keyword_continue,
                .keyword_import,
                .keyword_export,
                => return,
                else => _ = p.bump() catch return,
            }
        }
    }

    fn parseStatement(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .l_brace => return p.parseBlock(),
            .semicolon => {
                const tok = try p.bump();
                return p.addNode(.{ .tag = .empty_stmt, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            .keyword_var, .keyword_const => return p.parseVarStatement(),
            .keyword_let => {
                // `let` is a declaration only when a binding follows.
                const t1 = p.peekTag(1);
                if (isIdentLike(t1) or t1 == .l_bracket or t1 == .l_brace) return p.parseVarStatement();
                return p.parseExpressionStatement();
            },
            .keyword_if => return p.parseIfStatement(),
            .keyword_while => return p.parseWhileStatement(),
            .keyword_do => return p.parseDoStatement(),
            .keyword_for => return p.parseForStatement(),
            .keyword_switch => return p.parseSwitchStatement(),
            .keyword_try => return p.parseTryStatement(),
            .keyword_throw => return p.parseThrowStatement(),
            .keyword_return => return p.parseReturnStatement(),
            .keyword_break, .keyword_continue => return p.parseBreakContinue(),
            .keyword_debugger => {
                const tok = try p.bump();
                try p.expectSemicolon();
                return p.addNode(.{ .tag = .debugger_stmt, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            .keyword_function => return p.parseFunctionDecl(0, false),
            .keyword_class => return p.parseClassDecl(0),
            .keyword_abstract => {
                if (p.peekTag(1) == .keyword_class and !p.peekNewline(1)) {
                    _ = try p.bump();
                    return p.parseClassDecl(ast.Flags.abstract);
                }
                return p.parseExpressionStatement();
            },
            .keyword_async => {
                if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                    _ = try p.bump();
                    return p.parseFunctionDecl(ast.Flags.async, false);
                }
                return p.parseExpressionStatement();
            },
            .keyword_interface => {
                if (isIdentLike(p.peekTag(1))) return p.parseInterfaceDecl(0);
                return p.parseExpressionStatement();
            },
            .keyword_type => {
                // `type X =` / `type X<...> =` starts an alias; otherwise
                // `type` is an ordinary identifier expression.
                if (isIdentLike(p.peekTag(1)) and !p.peekNewline(1)) {
                    const t2 = p.peekTag(2);
                    if (t2 == .eq or t2 == .lt or t2 == .lt_lt) return p.parseTypeAlias(0);
                }
                return p.parseExpressionStatement();
            },
            .keyword_declare => {
                if (!p.peekNewline(1)) switch (p.peekTag(1)) {
                    .keyword_var, .keyword_let, .keyword_const => {
                        // `declare const enum ...`
                        if (p.peekTag(1) == .keyword_const and p.peekTag(2) == .keyword_enum) {
                            _ = try p.bump(); // `declare`
                            _ = try p.bump(); // `const`
                            return p.parseEnumDecl(ast.Flags.declare | ast.Flags.const_enum);
                        }
                        _ = try p.bump();
                        return p.parseVarStatement();
                    },
                    .keyword_function => {
                        _ = try p.bump();
                        return p.parseFunctionDecl(ast.Flags.declare, false);
                    },
                    .keyword_async => {
                        _ = try p.bump();
                        _ = try p.bump();
                        return p.parseFunctionDecl(ast.Flags.declare | ast.Flags.async, false);
                    },
                    .keyword_class => {
                        _ = try p.bump();
                        return p.parseClassDecl(ast.Flags.declare);
                    },
                    .keyword_abstract => {
                        _ = try p.bump();
                        _ = try p.bump();
                        return p.parseClassDecl(ast.Flags.declare | ast.Flags.abstract);
                    },
                    .keyword_interface => {
                        _ = try p.bump();
                        return p.parseInterfaceDecl(ast.Flags.declare);
                    },
                    .keyword_type => {
                        _ = try p.bump();
                        return p.parseTypeAlias(ast.Flags.declare);
                    },
                    .keyword_enum => {
                        _ = try p.bump(); // `declare`
                        return p.parseEnumDecl(ast.Flags.declare);
                    },
                    .keyword_module, .keyword_namespace => {
                        // `declare namespace N { ... }` (ambient): in subset
                        // for an identifier name; a string-module name stays
                        // unsupported.
                        _ = try p.bump(); // `declare`
                        if (isIdentLike(p.peekTag(1)) and !p.peekNewline(1)) {
                            return p.parseNamespaceDecl(ast.Flags.declare);
                        }
                        const start = p.curIdx();
                        _ = try p.bump();
                        p.skipUnsupportedBlockish();
                        return p.unsupportedFrom(start);
                    },
                    .keyword_global => {
                        // `declare global { ... }` — global-scope augmentation
                        // (M11a). In subset: a block whose members merge into
                        // the program's global symbol table at link time.
                        _ = try p.bump(); // `declare`
                        return p.parseGlobalAugmentation();
                    },
                    else => {},
                };
                return p.parseExpressionStatement();
            },
            .keyword_import => return p.parseImportStatement(),
            .keyword_export => return p.parseExportStatement(),
            .keyword_enum => return p.parseEnumDecl(0),
            .keyword_namespace, .keyword_module => {
                // Only a namespace when followed by a name / string.
                const t1 = p.peekTag(1);
                if (isIdentLike(t1) and !p.peekNewline(1)) {
                    return p.parseNamespaceDecl(0);
                }
                if (t1 == .string_literal and !p.peekNewline(1)) {
                    // String-module name (`module "x" {}`) is augmentation:
                    // still out of subset.
                    const start = try p.bump();
                    p.skipUnsupportedBlockish();
                    return p.unsupportedFrom(start);
                }
                return p.parseExpressionStatement();
            },
            .at => {
                // Decorator: out of subset. Consume `@expr` and report.
                const start = try p.bump();
                if (canStartExpression(p.curTag())) {
                    _ = try p.parseLhsExpression(.{});
                }
                return p.unsupportedFrom(start);
            },
            .unterminated_comment => {
                try p.errAtCur(.unterminated_comment);
                const tok = try p.bump();
                return p.addNode(.{ .tag = .error_node, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            .unknown => {
                try p.errAtCur(.unexpected_character);
                const tok = try p.bump();
                return p.addNode(.{ .tag = .error_node, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            else => {
                // Labeled statement?
                if (isIdentLike(p.curTag()) and p.peekTag(1) == .colon) {
                    const label = try p.bump();
                    _ = try p.bump(); // ':'
                    const body = try p.parseStatement();
                    return p.addNode(.{ .tag = .labeled_stmt, .main_token = label, .data = .{ .lhs = body, .rhs = 0 } });
                }
                return p.parseExpressionStatement();
            },
        }
    }

    fn parseBlock(p: *Parser) PE!Node {
        const l_brace = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.parseStatementList(top, .r_brace);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .block, .main_token = l_brace, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseExpressionStatement(p: *Parser) PE!Node {
        const expr = try p.parseExpression(.{});
        try p.expectSemicolon();
        return p.addNode(.{ .tag = .expr_stmt, .main_token = p.nodes.items(.main_token)[expr], .data = .{ .lhs = expr, .rhs = 0 } });
    }

    /// ASI: `;` is consumed; `}`, EOF, or a preceding line break also
    /// terminate the statement; anything else is an error (not consumed).
    fn expectSemicolon(p: *Parser) PE!void {
        switch (p.curTag()) {
            .semicolon => _ = try p.bump(),
            .r_brace, .eof => {},
            else => {
                if (p.nlBefore()) return;
                try p.fail(.expected_semicolon);
            },
        }
    }

    fn parseVarStatement(p: *Parser) PE!Node {
        const node = try p.parseVarDecl(false);
        try p.expectSemicolon();
        return node;
    }

    /// `var`/`let`/`const` declarator list (shared with for-init).
    fn parseVarDecl(p: *Parser, no_in: bool) PE!Node {
        const kw = try p.bump(); // var/let/const
        if (p.curTag() == .keyword_enum) {
            // `const enum E { ... }` — main_token stays on `const`.
            _ = try p.bump(); // `enum`
            return p.parseEnumDeclFrom(kw, ast.Flags.const_enum);
        }
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) {
            try p.pushScratch(try p.parseDeclarator(no_in));
            if (try p.eat(.comma) == null) break;
        }
        const items = p.scratch.items[top..];
        if (items.len == 1) {
            return p.addNode(.{ .tag = .var_decl_one, .main_token = kw, .data = .{ .lhs = items[0], .rhs = 0 } });
        }
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .var_decl, .main_token = kw, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseDeclarator(p: *Parser, no_in: bool) PE!Node {
        const name_tok = p.curIdx();
        const name = try p.parseBindingName();
        var flags: u32 = 0;
        if (p.curTag() == .bang and !p.nlBefore()) {
            _ = try p.bump();
            flags |= ast.Flags.definite;
        }
        var type_ann: Node = null_node;
        if (try p.eat(.colon) != null) type_ann = try p.parseType();
        var init: Node = null_node;
        if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{ .no_in = no_in });

        if (flags == 0 and type_ann == null_node) {
            if (init == null_node) {
                return p.addNode(.{ .tag = .declarator, .main_token = name_tok, .data = .{ .lhs = name, .rhs = 0 } });
            }
            return p.addNode(.{ .tag = .declarator_init, .main_token = name_tok, .data = .{ .lhs = name, .rhs = init } });
        }
        const extra = try p.addExtra(ast.DeclaratorFull{ .flags = flags, .type_ann = type_ann, .init = init });
        return p.addNode(.{ .tag = .declarator_full, .main_token = name_tok, .data = .{ .lhs = name, .rhs = extra } });
    }

    fn parseIfStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        _ = try p.expect(.l_paren, .expected_l_paren);
        const cond = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        const then_stmt = try p.parseStatement();
        if (try p.eat(.keyword_else) != null) {
            const else_stmt = try p.parseStatement();
            const extra = try p.addExtra(ast.IfElse{ .then_stmt = then_stmt, .else_stmt = else_stmt });
            return p.addNode(.{ .tag = .if_else_stmt, .main_token = kw, .data = .{ .lhs = cond, .rhs = extra } });
        }
        return p.addNode(.{ .tag = .if_stmt, .main_token = kw, .data = .{ .lhs = cond, .rhs = then_stmt } });
    }

    fn parseWhileStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        _ = try p.expect(.l_paren, .expected_l_paren);
        const cond = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        const body = try p.parseStatement();
        return p.addNode(.{ .tag = .while_stmt, .main_token = kw, .data = .{ .lhs = cond, .rhs = body } });
    }

    fn parseDoStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        const body = try p.parseStatement();
        _ = try p.expect(.keyword_while, .expected_while);
        _ = try p.expect(.l_paren, .expected_l_paren);
        const cond = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        _ = try p.eat(.semicolon); // ASI always permits omitting it here
        return p.addNode(.{ .tag = .do_stmt, .main_token = kw, .data = .{ .lhs = body, .rhs = cond } });
    }

    fn parseForStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        if (p.curTag() == .keyword_await) _ = try p.bump(); // `for await` — parsed, checker's business
        _ = try p.expect(.l_paren, .expected_l_paren);

        var init: Node = null_node;
        if (p.curTag() != .semicolon) {
            switch (p.curTag()) {
                .keyword_var, .keyword_let, .keyword_const => init = try p.parseVarDecl(true),
                else => init = try p.parseExpression(.{ .no_in = true }),
            }
            // for-of / for-in?
            if (p.curTag() == .keyword_of or p.curTag() == .keyword_in) {
                const is_of = p.curTag() == .keyword_of;
                _ = try p.bump();
                const right = if (is_of) try p.parseAssignExpr(.{}) else try p.parseExpression(.{});
                _ = try p.expect(.r_paren, .expected_r_paren);
                const body = try p.parseStatement();
                const extra = try p.addExtra(ast.ForInOf{ .left = init, .right = right });
                return p.addNode(.{
                    .tag = if (is_of) .for_of_stmt else .for_in_stmt,
                    .main_token = kw,
                    .data = .{ .lhs = extra, .rhs = body },
                });
            }
        }
        _ = try p.expect(.semicolon, .expected_semicolon);
        var cond: Node = null_node;
        if (p.curTag() != .semicolon) cond = try p.parseExpression(.{});
        _ = try p.expect(.semicolon, .expected_semicolon);
        var update: Node = null_node;
        if (p.curTag() != .r_paren and p.curTag() != .eof) update = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        const body = try p.parseStatement();
        const extra = try p.addExtra(ast.For{ .init = init, .cond = cond, .update = update });
        return p.addNode(.{ .tag = .for_stmt, .main_token = kw, .data = .{ .lhs = extra, .rhs = body } });
    }

    fn parseSwitchStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        _ = try p.expect(.l_paren, .expected_l_paren);
        const disc = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        _ = try p.expect(.l_brace, .expected_l_brace);

        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        var seen_default = false;
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            switch (p.curTag()) {
                .keyword_case => {
                    const case_kw = try p.bump();
                    const test_expr = try p.parseExpression(.{});
                    _ = try p.expect(.colon, .expected_colon);
                    const range = try p.parseClauseStatements();
                    const extra = try p.addExtra(range);
                    try p.pushScratch(try p.addNode(.{ .tag = .case_clause, .main_token = case_kw, .data = .{ .lhs = test_expr, .rhs = extra } }));
                },
                .keyword_default => {
                    const def_kw = try p.bump();
                    if (seen_default) try p.errAtToken(.multiple_default_clauses, def_kw);
                    seen_default = true;
                    _ = try p.expect(.colon, .expected_colon);
                    const range = try p.parseClauseStatements();
                    const extra = try p.addExtra(range);
                    try p.pushScratch(try p.addNode(.{ .tag = .default_clause, .main_token = def_kw, .data = .{ .lhs = 0, .rhs = extra } }));
                },
                else => {
                    try p.fail(.expected_case_or_default);
                    if (p.curIdx() == before) _ = try p.bump();
                },
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const clauses = try p.scratchToSpan(top);
        const extra = try p.addExtra(clauses);
        return p.addNode(.{ .tag = .switch_stmt, .main_token = kw, .data = .{ .lhs = disc, .rhs = extra } });
    }

    fn parseClauseStatements(p: *Parser) PE!ast.SubRange {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) {
            switch (p.curTag()) {
                .keyword_case, .keyword_default, .r_brace, .eof => break,
                else => {},
            }
            const before = p.curIdx();
            try p.pushScratch(try p.parseStatement());
            if (p.curIdx() == before) {
                try p.errAtCur(.unexpected_token);
                _ = try p.bump();
                p.synchronize();
            }
        }
        return p.scratchToSpan(top);
    }

    fn parseTryStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        const block = try p.parseBlock();
        var catch_clause: Node = null_node;
        var finally_block: Node = null_node;
        if (p.curTag() == .keyword_catch) {
            const catch_kw = try p.bump();
            var binding: Node = null_node;
            if (try p.eat(.l_paren) != null) {
                binding = try p.parseDeclarator(false); // allows `e: unknown`
                _ = try p.expect(.r_paren, .expected_r_paren);
            }
            const catch_block = try p.parseBlock();
            catch_clause = try p.addNode(.{ .tag = .catch_clause, .main_token = catch_kw, .data = .{ .lhs = binding, .rhs = catch_block } });
        }
        if (try p.eat(.keyword_finally) != null) {
            finally_block = try p.parseBlock();
        }
        if (catch_clause == null_node and finally_block == null_node) {
            try p.fail(.expected_catch_or_finally);
        }
        const extra = try p.addExtra(ast.Try{ .catch_clause = catch_clause, .finally_block = finally_block });
        return p.addNode(.{ .tag = .try_stmt, .main_token = kw, .data = .{ .lhs = block, .rhs = extra } });
    }

    fn parseThrowStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        var expr: Node = null_node;
        if (p.nlBefore()) {
            // Restricted production: `throw\nexpr` is a syntax error.
            try p.fail(.line_break_not_allowed);
            expr = try p.errorNode();
        } else {
            expr = try p.parseExpression(.{});
            try p.expectSemicolon();
        }
        return p.addNode(.{ .tag = .throw_stmt, .main_token = kw, .data = .{ .lhs = expr, .rhs = 0 } });
    }

    fn parseReturnStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        var expr: Node = null_node;
        const t = p.curTag();
        // ASI: `return\nvalue` returns undefined.
        if (t != .semicolon and t != .r_brace and t != .eof and !p.nlBefore() and canStartExpression(t)) {
            expr = try p.parseExpression(.{});
        }
        try p.expectSemicolon();
        return p.addNode(.{ .tag = .return_stmt, .main_token = kw, .data = .{ .lhs = expr, .rhs = 0 } });
    }

    fn parseBreakContinue(p: *Parser) PE!Node {
        const is_break = p.curTag() == .keyword_break;
        const kw = try p.bump();
        var label: u32 = 0;
        if (isIdentLike(p.curTag()) and !p.nlBefore()) {
            label = try p.bump();
        }
        try p.expectSemicolon();
        return p.addNode(.{
            .tag = if (is_break) .break_stmt else .continue_stmt,
            .main_token = kw,
            .data = .{ .lhs = label, .rhs = 0 },
        });
    }

    // =====================================================================
    // functions, classes, interfaces, aliases
    // =====================================================================

    /// Parse from the `function` keyword. `flags` carries async/declare.
    fn parseFunctionDecl(p: *Parser, flags_in: u32, is_expr: bool) PE!Node {
        var flags = flags_in;
        const kw = try p.bump(); // `function`
        if (try p.eat(.asterisk) != null) flags |= ast.Flags.generator;
        var name_tok: u32 = 0;
        if (isIdentLike(p.curTag())) {
            name_tok = try p.bump();
        } else if (!is_expr) {
            try p.fail(.expected_identifier);
        }
        const proto = try p.parseFnProtoRest(flags, name_tok);
        var body: Node = null_node;
        if (p.curTag() == .l_brace) {
            body = try p.parseBlock();
        } else {
            // Overload signature / ambient declaration.
            try p.expectSemicolon();
        }
        return p.addNode(.{
            .tag = if (is_expr) .function_expr else .function_decl,
            .main_token = kw,
            .data = .{ .lhs = proto, .rhs = body },
        });
    }

    /// Type params + params + return type → extra index of FnProto.
    fn parseFnProtoRest(p: *Parser, flags: u32, name_tok: u32) PE!u32 {
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();
        const params = try p.parseParams();
        var ret: Node = null_node;
        if (try p.eat(.colon) != null) ret = try p.parseReturnType();
        return p.addExtra(ast.FnProto{
            .flags = flags,
            .name_token = name_tok,
            .tp_start = tp.start,
            .tp_end = tp.end,
            .params_start = params.start,
            .params_end = params.end,
            .return_type = ret,
        });
    }

    /// Return-type position: parses a type, or a type predicate
    /// (`x is T`, `asserts x is T`, `asserts x`) into a `.type_predicate`
    /// node whose main_token names the guarded parameter.
    fn parseReturnType(p: *Parser) PE!Node {
        if (p.curTag() == .keyword_asserts and !p.peekNewline(1) and (isIdentLike(p.peekTag(1)) or p.peekTag(1) == .keyword_this)) {
            _ = try p.bump(); // asserts
            const name_tok = try p.bump(); // name/this
            var target: Node = null_node;
            if (try p.eat(.keyword_is) != null) target = try p.parseType();
            return p.addNode(.{ .tag = .type_predicate, .main_token = name_tok, .data = .{ .lhs = target, .rhs = 1 } });
        }
        if ((isIdentLike(p.curTag()) or p.curTag() == .keyword_this) and p.peekTag(1) == .keyword_is and !p.peekNewline(1)) {
            const name_tok = try p.bump();
            _ = try p.bump(); // is
            const target = try p.parseType();
            return p.addNode(.{ .tag = .type_predicate, .main_token = name_tok, .data = .{ .lhs = target, .rhs = 0 } });
        }
        return p.parseType();
    }

    fn parseTypeParams(p: *Parser) PE!ast.SubRange {
        _ = try p.expectLt();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .gt and p.curTag() != .eof) {
            const before = p.curIdx();
            if (!isIdentLike(p.curTag())) {
                // `const T` / `in`/`out` variance — consume modifiers.
                switch (p.curTag()) {
                    .keyword_const, .keyword_in, .keyword_out => {
                        _ = try p.bump();
                        continue;
                    },
                    else => {},
                }
                try p.fail(.expected_identifier);
                if (p.curIdx() == before) break;
                continue;
            }
            const name = try p.bump();
            var constraint: Node = null_node;
            var default: Node = null_node;
            if (try p.eat(.keyword_extends) != null) constraint = try p.parseType();
            if (try p.eat(.eq) != null) default = try p.parseType();
            try p.pushScratch(try p.addNode(.{ .tag = .type_param, .main_token = name, .data = .{ .lhs = constraint, .rhs = default } }));
            if (try p.eat(.comma) == null) break;
        }
        _ = try p.expectGt();
        return p.scratchToSpan(top);
    }

    fn parseParams(p: *Parser) PE!ast.SubRange {
        _ = try p.expect(.l_paren, .expected_l_paren);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_paren and p.curTag() != .eof) {
            const before = p.curIdx();
            const param = try p.parseParam();
            try p.pushScratch(param);
            if (try p.eat(.comma) == null and p.curTag() != .r_paren) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break; // no progress: bail out
        }
        _ = try p.expect(.r_paren, .expected_r_paren);
        return p.scratchToSpan(top);
    }

    fn parseParam(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        var flags: u32 = 0;
        // Constructor parameter properties: visibility/readonly/override.
        while (true) {
            const bit: u32 = switch (p.curTag()) {
                .keyword_public => ast.Flags.public,
                .keyword_private => ast.Flags.private,
                .keyword_protected => ast.Flags.protected,
                .keyword_readonly => ast.Flags.readonly,
                .keyword_override => ast.Flags.override,
                else => 0,
            };
            if (bit == 0) break;
            // Only a modifier if a binding follows (else it's the name).
            const t1 = p.peekTag(1);
            if (!(isIdentLike(t1) or t1 == .l_bracket or t1 == .l_brace or t1 == .dot_dot_dot or t1 == .keyword_this)) break;
            _ = try p.bump();
            flags |= bit;
        }
        if (try p.eat(.dot_dot_dot) != null) flags |= ast.Flags.rest;
        var name: Node = null_node;
        if (p.curTag() == .keyword_this) {
            const tok = try p.bump();
            name = try p.addNode(.{ .tag = .this_expr, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
        } else {
            name = try p.parseBindingName();
        }
        if (p.curTag() == .question) {
            _ = try p.bump();
            flags |= ast.Flags.optional;
        }
        var type_ann: Node = null_node;
        if (try p.eat(.colon) != null) type_ann = try p.parseType();
        var init: Node = null_node;
        if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{});

        if (flags == 0 and init == null_node) {
            return p.addNode(.{ .tag = .param, .main_token = start_tok, .data = .{ .lhs = name, .rhs = type_ann } });
        }
        const extra = try p.addExtra(ast.ParamFull{ .flags = flags, .type_ann = type_ann, .init = init });
        return p.addNode(.{ .tag = .param_full, .main_token = start_tok, .data = .{ .lhs = name, .rhs = extra } });
    }

    // --- binding patterns ---------------------------------------------------

    fn parseBindingName(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .l_bracket => return p.parseArrayPattern(),
            .l_brace => return p.parseObjectPattern(),
            else => {
                if (isIdentLike(p.curTag())) {
                    const tok = try p.bump();
                    return p.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
                }
                try p.fail(.expected_binding);
                return p.errorNode();
            },
        }
    }

    fn parseArrayPattern(p: *Parser) PE!Node {
        const l_bracket = try p.bump();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_bracket and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .comma) {
                const tok = try p.bump();
                try p.pushScratch(try p.addNode(.{ .tag = .omitted, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } }));
                continue;
            }
            if (p.curTag() == .dot_dot_dot) {
                const dots = try p.bump();
                const target = try p.parseBindingName();
                try p.pushScratch(try p.addNode(.{ .tag = .rest_element, .main_token = dots, .data = .{ .lhs = target, .rhs = 0 } }));
                if (p.curTag() == .comma) try p.errAtCur(.rest_must_be_last);
            } else {
                try p.pushScratch(try p.parseBindingElement());
            }
            if (try p.eat(.comma) == null and p.curTag() != .r_bracket) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .array_pattern, .main_token = l_bracket, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    /// Pattern with optional default: `x`, `[a]`, `{a}`, each `= init`.
    fn parseBindingElement(p: *Parser) PE!Node {
        const target = try p.parseBindingName();
        if (p.curTag() == .eq) {
            const eq_tok = try p.bump();
            const init = try p.parseAssignExpr(.{});
            return p.addNode(.{ .tag = .binding_default, .main_token = eq_tok, .data = .{ .lhs = target, .rhs = init } });
        }
        return target;
    }

    fn parseObjectPattern(p: *Parser) PE!Node {
        const l_brace = try p.bump();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .dot_dot_dot) {
                const dots = try p.bump();
                const target = try p.parseBindingName();
                try p.pushScratch(try p.addNode(.{ .tag = .rest_element, .main_token = dots, .data = .{ .lhs = target, .rhs = 0 } }));
                if (p.curTag() == .comma) try p.errAtCur(.rest_must_be_last);
            } else if (isNameLike(p.curTag()) or p.curTag() == .string_literal or p.curTag() == .numeric_literal) {
                const key = try p.bump();
                var value: Node = null_node;
                if (try p.eat(.colon) != null) value = try p.parseBindingName();
                var init: Node = null_node;
                if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{});
                try p.pushScratch(try p.addNode(.{ .tag = .binding_property, .main_token = key, .data = .{ .lhs = value, .rhs = init } }));
            } else {
                try p.fail(.expected_property_name);
                if (p.curIdx() == before) break;
            }
            if (try p.eat(.comma) == null and p.curTag() != .r_brace) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .object_pattern, .main_token = l_brace, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    // --- classes ------------------------------------------------------------

    fn parseClassDecl(p: *Parser, flags_in: u32) PE!Node {
        const kw = try p.bump(); // `class`
        var name_tok: u32 = 0;
        if (isIdentLike(p.curTag()) and p.curTag() != .keyword_implements) {
            name_tok = try p.bump();
        }
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();

        var extends: Node = null_node;
        if (try p.eat(.keyword_extends) != null) {
            extends = try p.parseHeritage();
        }
        var impl: ast.SubRange = .{ .start = 0, .end = 0 };
        if (try p.eat(.keyword_implements) != null) {
            const top = p.scratchTop();
            defer p.scratch.shrinkRetainingCapacity(top);
            while (true) {
                try p.pushScratch(try p.parseHeritage());
                if (try p.eat(.comma) == null) break;
            }
            impl = try p.scratchToSpan(top);
        }

        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            if (try p.eat(.semicolon) != null) continue;
            try p.pushScratch(try p.parseClassMember());
            if (p.curIdx() == before) {
                try p.errAtCur(.expected_class_member);
                _ = try p.bump();
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const members = try p.scratchToSpan(top);

        const extra = try p.addExtra(ast.ClassData{
            .flags = flags_in,
            .name_token = name_tok,
            .tp_start = tp.start,
            .tp_end = tp.end,
            .extends = extends,
            .impl_start = impl.start,
            .impl_end = impl.end,
            .members_start = members.start,
            .members_end = members.end,
        });
        return p.addNode(.{ .tag = .class_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    /// `extends`/`implements` entry: LHS expression + optional type args.
    fn parseHeritage(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        const expr = try p.parseLhsExpression(.{ .no_calls = false });
        var targs_extra: u32 = 0;
        if (p.atLt()) {
            const range = try p.parseTypeArgs();
            targs_extra = try p.addExtra(range);
        }
        return p.addNode(.{ .tag = .heritage, .main_token = start_tok, .data = .{ .lhs = expr, .rhs = targs_extra } });
    }

    fn parseClassMember(p: *Parser) PE!Node {
        const start_tok = p.curIdx();

        // Decorators on members: out of subset.
        if (p.curTag() == .at) {
            _ = try p.bump();
            if (canStartExpression(p.curTag())) _ = try p.parseLhsExpression(.{});
            return p.unsupportedFrom(start_tok);
        }

        var flags: u32 = 0;
        while (true) {
            const bit: u32 = switch (p.curTag()) {
                .keyword_static => ast.Flags.static,
                .keyword_public => ast.Flags.public,
                .keyword_private => ast.Flags.private,
                .keyword_protected => ast.Flags.protected,
                .keyword_readonly => ast.Flags.readonly,
                .keyword_abstract => ast.Flags.abstract,
                .keyword_override => ast.Flags.override,
                .keyword_declare => ast.Flags.declare,
                .keyword_async => ast.Flags.async,
                .keyword_accessor => ast.Flags.accessor,
                .keyword_get => ast.Flags.get,
                .keyword_set => ast.Flags.set,
                else => 0,
            };
            if (bit == 0) break;
            // A modifier only if a member name (or `*`/`[`) follows on any
            // line (get/set/async additionally require same-line names).
            const t1 = p.peekTag(1);
            const name_follows = isNameLike(t1) or t1 == .string_literal or
                t1 == .numeric_literal or t1 == .l_bracket or t1 == .asterisk;
            if (!name_follows) break;
            if ((bit == ast.Flags.get or bit == ast.Flags.set or bit == ast.Flags.async) and p.peekNewline(1)) break;
            _ = try p.bump();
            flags |= bit;
            // `static { ... }` initialization block: out of subset.
            if (bit == ast.Flags.static and p.curTag() == .l_brace) {
                p.skipBalancedBraces();
                return p.unsupportedFrom(start_tok);
            }
        }

        if (try p.eat(.asterisk) != null) flags |= ast.Flags.generator;

        // Member name.
        var name_tok: u32 = 0;
        switch (p.curTag()) {
            .l_bracket => {
                // Computed member name / index signature in class.
                if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .colon) {
                    return p.parseIndexSignatureAsClassMember(flags);
                }
                // Well-known-symbol key `[Symbol.iterator]`: keyed by a
                // synthetic atom, then parsed as an ordinary method/field.
                if (try p.eatWellKnownSymbolName()) |ntok| {
                    name_tok = ntok;
                    flags |= ast.Flags.computed;
                } else {
                    _ = try p.bump();
                    _ = try p.parseAssignExpr(.{});
                    _ = try p.eat(.r_bracket);
                    // Other computed names are out of subset; skip the member.
                    p.skipToMemberEnd();
                    return p.unsupportedFrom(start_tok);
                }
            },
            .string_literal, .numeric_literal, .private_identifier => name_tok = try p.bump(),
            else => {
                if (isNameLike(p.curTag())) {
                    name_tok = try p.bump();
                } else {
                    try p.fail(.expected_property_name);
                    return p.errorNode();
                }
            },
        }

        if (p.curTag() == .l_paren or p.atLt()) {
            // Method / constructor / accessor.
            const proto = try p.parseFnProtoRest(flags, name_tok);
            var body: Node = null_node;
            if (p.curTag() == .l_brace) {
                body = try p.parseBlock();
            } else {
                try p.expectSemicolon(); // overload signature / abstract
            }
            return p.addNode(.{ .tag = .class_method, .main_token = name_tok, .data = .{ .lhs = proto, .rhs = body } });
        }

        // Field.
        if (p.curTag() == .question) {
            _ = try p.bump();
            flags |= ast.Flags.optional;
        } else if (p.curTag() == .bang and !p.nlBefore()) {
            _ = try p.bump();
            flags |= ast.Flags.definite;
        }
        var type_ann: Node = null_node;
        if (try p.eat(.colon) != null) type_ann = try p.parseType();
        var init: Node = null_node;
        if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{});
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.Field{ .flags = flags, .type_ann = type_ann, .init = init });
        return p.addNode(.{ .tag = .class_field, .main_token = name_tok, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    fn parseIndexSignatureAsClassMember(p: *Parser, flags: u32) PE!Node {
        return p.parseIndexSignature(flags);
    }

    /// Skip to the likely end of a malformed/unsupported class member.
    fn skipToMemberEnd(p: *Parser) void {
        var depth: u32 = 0;
        while (true) {
            switch (p.curTag()) {
                .eof => return,
                .semicolon => {
                    if (depth == 0) {
                        _ = p.bump() catch return;
                        return;
                    }
                    _ = p.bump() catch return;
                },
                .l_brace => {
                    depth += 1;
                    _ = p.bump() catch return;
                },
                .r_brace => {
                    if (depth == 0) return;
                    depth -= 1;
                    _ = p.bump() catch return;
                    if (depth == 0) return;
                },
                else => _ = p.bump() catch return,
            }
        }
    }

    // --- interfaces, type aliases -------------------------------------------

    fn parseInterfaceDecl(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `interface`
        const name_tok = try p.expectIdentLike();
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();
        var ext: ast.SubRange = .{ .start = 0, .end = 0 };
        if (try p.eat(.keyword_extends) != null) {
            const top = p.scratchTop();
            defer p.scratch.shrinkRetainingCapacity(top);
            while (true) {
                try p.pushScratch(try p.parseHeritage());
                if (try p.eat(.comma) == null) break;
            }
            ext = try p.scratchToSpan(top);
        }
        const members = try p.parseTypeMemberList();
        const extra = try p.addExtra(ast.InterfaceData{
            .flags = flags,
            .name_token = name_tok,
            .tp_start = tp.start,
            .tp_end = tp.end,
            .extends_start = ext.start,
            .extends_end = ext.end,
            .members_start = members.start,
            .members_end = members.end,
        });
        return p.addNode(.{ .tag = .interface_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    fn expectIdentLike(p: *Parser) PE!u32 {
        if (isIdentLike(p.curTag())) return p.bump();
        try p.fail(.expected_identifier);
        return p.lastIdx();
    }

    fn parseTypeAlias(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `type`
        const name_tok = try p.expectIdentLike();
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();
        _ = try p.expect(.eq, .expected_eq);
        const value = try p.parseType();
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.TypeAlias{
            .flags = flags,
            .name_token = name_tok,
            .tp_start = tp.start,
            .tp_end = tp.end,
        });
        return p.addNode(.{ .tag = .type_alias, .main_token = kw, .data = .{ .lhs = extra, .rhs = value } });
    }

    /// `enum E { ... }` — consumes the `enum` keyword itself.
    fn parseEnumDecl(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `enum`
        return p.parseEnumDeclFrom(kw, flags);
    }

    /// Enum body parse. `kw` is the node's main token (the `enum` keyword, or
    /// the `const` keyword for a `const enum`); the `enum` keyword must have
    /// already been consumed by the caller.
    fn parseEnumDeclFrom(p: *Parser, kw: u32, flags: u32) PE!Node {
        const name_tok = try p.expectIdentLike();
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            try p.pushScratch(try p.parseEnumMember());
            if (try p.eat(.comma) == null and p.curTag() != .r_brace) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const members = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.EnumData{
            .flags = flags,
            .name_token = name_tok,
            .members_start = members.start,
            .members_end = members.end,
        });
        return p.addNode(.{ .tag = .enum_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    fn parseEnumMember(p: *Parser) PE!Node {
        // Member name: identifier(-like) or string literal.
        if (!isIdentLike(p.curTag()) and p.curTag() != .string_literal) {
            try p.fail(.expected_identifier);
            return p.errorNode();
        }
        const name_tok = try p.bump();
        var init: Node = null_node;
        if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{});
        return p.addNode(.{ .tag = .enum_member, .main_token = name_tok, .data = .{ .lhs = init, .rhs = 0 } });
    }

    /// `namespace N { ... }` / `module N { ... }`. The `namespace`/`module`
    /// keyword must not yet be consumed. Only identifier-named namespaces are
    /// in subset; a string-module name (`module "x" {}`, augmentation) or a
    /// dotted name (`namespace A.B {}`) falls back to unsupported.
    fn parseNamespaceDecl(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `namespace` / `module`
        const name_tok = try p.expectIdentLike();
        // Dotted namespace name (`namespace A.B { ... }`) is deferred.
        if (p.curTag() == .dot) {
            p.skipUnsupportedBlockish();
            return p.unsupportedFrom(kw);
        }
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.parseStatementList(top, .r_brace);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const body = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.NamespaceData{
            .flags = flags,
            .name_token = name_tok,
            .body_start = body.start,
            .body_end = body.end,
        });
        return p.addNode(.{ .tag = .namespace_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    /// `declare global { ... }` (the `declare` already consumed). Modeled as a
    /// `namespace_decl` flagged `global_aug`: no namespace symbol is declared;
    /// the block's top-level declarations become global contributions the
    /// linker merges into the program global table (M11a). `name_token` points
    /// at the `global` keyword purely for span/dump purposes.
    fn parseGlobalAugmentation(p: *Parser) PE!Node {
        const kw = try p.bump(); // `global`
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.parseStatementList(top, .r_brace);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const body = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.NamespaceData{
            .flags = ast.Flags.declare | ast.Flags.global_aug,
            .name_token = kw,
            .body_start = body.start,
            .body_end = body.end,
        });
        return p.addNode(.{ .tag = .namespace_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    // --- modules --------------------------------------------------------------

    fn parseImportStatement(p: *Parser) PE!Node {
        // `import(` / `import.` are expressions, not declarations.
        if (p.peekTag(1) == .l_paren or p.peekTag(1) == .dot) {
            return p.parseExpressionStatement();
        }
        const kw = try p.bump(); // `import`
        var flags: u32 = 0;

        // `import "module";`
        if (p.curTag() == .string_literal) {
            const mod = try p.bump();
            try p.expectSemicolon();
            const extra = try p.addExtra(ast.ImportData{
                .flags = 0,
                .default_name_token = 0,
                .ns_name_token = 0,
                .spec_start = 0,
                .spec_end = 0,
            });
            return p.addNode(.{ .tag = .import_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
        }

        // `import type ...` (but `import type from "m"` imports a default
        // named `type`).
        if (p.curTag() == .keyword_type) {
            const t1 = p.peekTag(1);
            const is_type_only = (isIdentLike(t1) and !(t1 == .keyword_from and p.peekTag(2) == .string_literal)) or
                t1 == .l_brace or t1 == .asterisk;
            if (is_type_only) {
                _ = try p.bump();
                flags |= ast.Flags.type_only;
            }
        }

        var default_name: u32 = 0;
        var ns_name: u32 = 0;
        var specs: ast.SubRange = .{ .start = 0, .end = 0 };

        if (isIdentLike(p.curTag())) {
            // `import d ...` — but `import x = require(...)` is out of subset.
            default_name = try p.bump();
            if (p.curTag() == .eq) {
                p.skipToMemberEnd();
                const node = try p.unsupportedFrom(kw);
                return node;
            }
            _ = try p.eat(.comma);
        }
        if (p.curTag() == .asterisk) {
            _ = try p.bump();
            if (try p.eat(.keyword_as) == null) try p.fail(.expected_import_clause);
            ns_name = try p.expectIdentLike();
        } else if (p.curTag() == .l_brace) {
            specs = try p.parseImportSpecifiers();
        } else if (default_name == 0) {
            try p.fail(.expected_import_clause);
        }

        var mod: u32 = 0;
        if (try p.eat(.keyword_from) != null) {
            mod = try p.expect(.string_literal, .expected_string_literal);
        } else if (default_name != 0 or ns_name != 0 or specs.start != specs.end) {
            try p.fail(.expected_from);
        }
        // Import attributes (`assert { ... }`) — consumed, not modeled.
        if (p.curTag() == .keyword_assert and p.peekTag(1) == .l_brace) {
            _ = try p.bump();
            p.skipBalancedBraces();
        }
        try p.expectSemicolon();

        const extra = try p.addExtra(ast.ImportData{
            .flags = flags,
            .default_name_token = default_name,
            .ns_name_token = ns_name,
            .spec_start = specs.start,
            .spec_end = specs.end,
        });
        return p.addNode(.{ .tag = .import_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
    }

    fn parseImportSpecifiers(p: *Parser) PE!ast.SubRange {
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            var spec_flags: u32 = 0;
            // `type name` / `type name as alias` (but `type as x` and plain
            // `type` are imports of the name `type`).
            if (p.curTag() == .keyword_type) {
                const t1 = p.peekTag(1);
                if (isIdentLike(t1) or t1 == .string_literal) {
                    if (!(t1 == .keyword_as and !isIdentLike(p.peekTag(2)))) {
                        _ = try p.bump();
                        spec_flags |= ast.Flags.type_only;
                    }
                }
            }
            if (!isIdentLike(p.curTag()) and p.curTag() != .string_literal) {
                try p.fail(.expected_identifier);
                if (p.curIdx() == before) break;
                continue;
            }
            const name = try p.bump();
            var alias: u32 = 0;
            if (try p.eat(.keyword_as) != null) alias = try p.expectIdentLike();
            try p.pushScratch(try p.addNode(.{ .tag = .import_specifier, .main_token = name, .data = .{ .lhs = alias, .rhs = spec_flags } }));
            if (try p.eat(.comma) == null and p.curTag() != .r_brace) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        return p.scratchToSpan(top);
    }

    fn parseExportStatement(p: *Parser) PE!Node {
        const kw = try p.bump(); // `export`
        switch (p.curTag()) {
            .keyword_default => {
                _ = try p.bump();
                const inner = switch (p.curTag()) {
                    .keyword_function => try p.parseFunctionDecl(0, false),
                    .keyword_async => blk: {
                        if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                            _ = try p.bump();
                            break :blk try p.parseFunctionDecl(ast.Flags.async, false);
                        }
                        const e = try p.parseAssignExpr(.{});
                        try p.expectSemicolon();
                        break :blk e;
                    },
                    .keyword_class => try p.parseClassDecl(0),
                    .keyword_abstract => blk: {
                        if (p.peekTag(1) == .keyword_class) {
                            _ = try p.bump();
                            break :blk try p.parseClassDecl(ast.Flags.abstract);
                        }
                        const e = try p.parseAssignExpr(.{});
                        try p.expectSemicolon();
                        break :blk e;
                    },
                    else => blk: {
                        const e = try p.parseAssignExpr(.{});
                        try p.expectSemicolon();
                        break :blk e;
                    },
                };
                return p.addNode(.{ .tag = .export_default, .main_token = kw, .data = .{ .lhs = inner, .rhs = 0 } });
            },
            .eq => {
                // `export = x;` — out of subset.
                _ = try p.bump();
                if (canStartExpression(p.curTag())) _ = try p.parseAssignExpr(.{});
                _ = try p.eat(.semicolon);
                return p.unsupportedFrom(kw);
            },
            .asterisk => {
                _ = try p.bump();
                var ns_name: u32 = 0;
                if (try p.eat(.keyword_as) != null) ns_name = try p.expectIdentLike();
                _ = try p.expect(.keyword_from, .expected_from);
                const mod = try p.expect(.string_literal, .expected_string_literal);
                try p.expectSemicolon();
                const extra = try p.addExtra(ast.ExportAll{ .flags = 0, .name_token = ns_name });
                return p.addNode(.{ .tag = .export_all, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
            },
            .l_brace => return p.parseExportNamed(kw, 0),
            .keyword_type => {
                const t1 = p.peekTag(1);
                if (t1 == .l_brace) {
                    _ = try p.bump();
                    return p.parseExportNamed(kw, ast.Flags.type_only);
                }
                if (t1 == .asterisk) {
                    _ = try p.bump();
                    _ = try p.bump();
                    var ns_name: u32 = 0;
                    if (try p.eat(.keyword_as) != null) ns_name = try p.expectIdentLike();
                    _ = try p.expect(.keyword_from, .expected_from);
                    const mod = try p.expect(.string_literal, .expected_string_literal);
                    try p.expectSemicolon();
                    const extra = try p.addExtra(ast.ExportAll{ .flags = ast.Flags.type_only, .name_token = ns_name });
                    return p.addNode(.{ .tag = .export_all, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
                }
                // `export type X = ...` — a type alias declaration.
                const decl = try p.parseStatement();
                return p.addNode(.{ .tag = .export_decl, .main_token = kw, .data = .{ .lhs = decl, .rhs = 0 } });
            },
            .keyword_var,
            .keyword_let,
            .keyword_const,
            .keyword_function,
            .keyword_class,
            .keyword_interface,
            .keyword_abstract,
            .keyword_async,
            .keyword_declare,
            .keyword_enum,
            .keyword_namespace,
            .keyword_module,
            => {
                const decl = try p.parseStatement();
                return p.addNode(.{ .tag = .export_decl, .main_token = kw, .data = .{ .lhs = decl, .rhs = 0 } });
            },
            else => {
                try p.fail(.expected_export_clause);
                return p.errorNode();
            },
        }
    }

    fn parseExportNamed(p: *Parser, kw: u32, flags: u32) PE!Node {
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            var spec_flags: u32 = 0;
            if (p.curTag() == .keyword_type) {
                const t1 = p.peekTag(1);
                if (isIdentLike(t1) or t1 == .string_literal) {
                    if (!(t1 == .keyword_as and !isIdentLike(p.peekTag(2)))) {
                        _ = try p.bump();
                        spec_flags |= ast.Flags.type_only;
                    }
                }
            }
            if (!isIdentLike(p.curTag()) and p.curTag() != .string_literal) {
                try p.fail(.expected_identifier);
                if (p.curIdx() == before) break;
                continue;
            }
            const name = try p.bump();
            var alias: u32 = 0;
            if (try p.eat(.keyword_as) != null) {
                if (isIdentLike(p.curTag()) or p.curTag() == .string_literal) {
                    alias = try p.bump();
                } else {
                    try p.fail(.expected_identifier);
                }
            }
            try p.pushScratch(try p.addNode(.{ .tag = .export_specifier, .main_token = name, .data = .{ .lhs = alias, .rhs = spec_flags } }));
            if (try p.eat(.comma) == null and p.curTag() != .r_brace) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const specs = try p.scratchToSpan(top);

        var mod: u32 = 0;
        if (try p.eat(.keyword_from) != null) {
            mod = try p.expect(.string_literal, .expected_string_literal);
        }
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.ExportNamed{ .flags = flags, .spec_start = specs.start, .spec_end = specs.end });
        return p.addNode(.{ .tag = .export_named, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
    }

    // --- unsupported-construct skipping ---------------------------------------

    /// Skip a header (until `{`, `;`, newline, or eof) plus a balanced brace
    /// block if one starts. Used for enums/namespaces/const enums.
    fn skipUnsupportedBlockish(p: *Parser) void {
        while (true) {
            switch (p.curTag()) {
                .eof, .r_brace => return,
                .semicolon => {
                    _ = p.bump() catch return;
                    return;
                },
                .l_brace => {
                    p.skipBalancedBraces();
                    return;
                },
                else => {
                    if (p.nlBefore()) return;
                    _ = p.bump() catch return;
                },
            }
        }
    }

    /// Consume from a `{` through its matching `}` (token-level balance).
    fn skipBalancedBraces(p: *Parser) void {
        if (p.curTag() != .l_brace) return;
        _ = p.bump() catch return;
        var depth: u32 = 1;
        while (depth > 0) {
            switch (p.curTag()) {
                .eof => return,
                .l_brace => depth += 1,
                .r_brace => depth -= 1,
                else => {},
            }
            _ = p.bump() catch return;
        }
    }

    // =====================================================================
    // expressions
    // =====================================================================

    const ExprCtx = struct {
        no_in: bool = false,
        no_calls: bool = false,
    };

    /// Expression including the comma operator.
    fn parseExpression(p: *Parser, ctx: ExprCtx) PE!Node {
        var lhs = try p.parseAssignExpr(ctx);
        while (p.curTag() == .comma) {
            const op = try p.bump();
            const rhs = try p.parseAssignExpr(ctx);
            lhs = try p.addNode(.{ .tag = .seq_expr, .main_token = op, .data = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseAssignExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        // Arrow-function fast paths and speculation.
        switch (p.curTag()) {
            .keyword_yield => return p.parseYield(ctx),
            .l_paren, .lt, .lt_lt => {
                if (try p.tryParseArrow(ctx)) |arrow| return arrow;
            },
            .keyword_async => {
                const t1 = p.peekTag(1);
                if (!p.peekNewline(1) and (t1 == .l_paren or isIdentLike(t1))) {
                    if (try p.tryParseArrow(ctx)) |arrow| return arrow;
                }
            },
            else => {
                // `x => ...`
                if (isIdentLike(p.curTag()) and p.peekTag(1) == .arrow) {
                    return p.parseSimpleArrow(ctx);
                }
            },
        }

        const lhs = try p.parseBinaryExpr(ctx, 1);

        if (p.curTag() == .question) {
            const q = try p.bump();
            const then_expr = try p.parseAssignExpr(.{ .no_in = false });
            _ = try p.expect(.colon, .expected_colon);
            const else_expr = try p.parseAssignExpr(ctx);
            const extra = try p.addExtra(ast.CondExpr{ .then_expr = then_expr, .else_expr = else_expr });
            return p.addNode(.{ .tag = .cond_expr, .main_token = q, .data = .{ .lhs = lhs, .rhs = extra } });
        }
        if (isAssignOp(p.curTag())) {
            const op = try p.bump();
            const rhs = try p.parseAssignExpr(ctx);
            return p.addNode(.{ .tag = .assign, .main_token = op, .data = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseYield(p: *Parser, ctx: ExprCtx) PE!Node {
        const kw = try p.bump();
        var delegate: u32 = 0;
        var operand: Node = null_node;
        if (!p.nlBefore()) {
            if (try p.eat(.asterisk) != null) delegate = 1;
            if (canStartExpression(p.curTag()) and !p.nlBefore()) {
                operand = try p.parseAssignExpr(ctx);
            }
        }
        return p.addNode(.{ .tag = .yield_expr, .main_token = kw, .data = .{ .lhs = operand, .rhs = delegate } });
    }

    /// `x => body` — no parens, no speculation needed.
    fn parseSimpleArrow(p: *Parser, ctx: ExprCtx) PE!Node {
        const name_tok = try p.bump();
        const name = try p.addNode(.{ .tag = .identifier, .main_token = name_tok, .data = .{ .lhs = 0, .rhs = 0 } });
        const param = try p.addNode(.{ .tag = .param, .main_token = name_tok, .data = .{ .lhs = name, .rhs = 0 } });
        const params = try p.listToSpan(&.{param});
        if (p.nlBefore()) try p.errAtCur(.newline_before_arrow);
        const arrow_tok = try p.expect(.arrow, .expected_arrow);
        const proto = try p.addExtra(ast.FnProto{
            .flags = 0,
            .name_token = 0,
            .tp_start = 0,
            .tp_end = 0,
            .params_start = params.start,
            .params_end = params.end,
            .return_type = 0,
        });
        const body = try p.parseArrowBody(ctx);
        return p.addNode(.{ .tag = .arrow_fn, .main_token = arrow_tok, .data = .{ .lhs = proto, .rhs = body } });
    }

    /// Speculatively parse `[async] [<T>] (params) [: R] => body`.
    fn tryParseArrow(p: *Parser, ctx: ExprCtx) PE!?Node {
        const state = p.save();
        p.spec += 1;
        const result = p.parseParenArrow(ctx);
        p.spec -= 1;
        return result catch |err| switch (err) {
            error.Backtrack => {
                p.restore(state);
                return null;
            },
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn parseParenArrow(p: *Parser, ctx: ExprCtx) PE!Node {
        var flags: u32 = 0;
        if (p.curTag() == .keyword_async) {
            _ = try p.bump();
            flags |= ast.Flags.async;
            if (isIdentLike(p.curTag()) and !p.nlBefore()) {
                // `async x => ...`
                const name_tok = try p.bump();
                const name = try p.addNode(.{ .tag = .identifier, .main_token = name_tok, .data = .{ .lhs = 0, .rhs = 0 } });
                const param = try p.addNode(.{ .tag = .param, .main_token = name_tok, .data = .{ .lhs = name, .rhs = 0 } });
                const params = try p.listToSpan(&.{param});
                if (p.curTag() != .arrow or p.nlBefore()) return error.Backtrack;
                const arrow_tok = try p.bump();
                const proto = try p.addExtra(ast.FnProto{
                    .flags = flags,
                    .name_token = 0,
                    .tp_start = 0,
                    .tp_end = 0,
                    .params_start = params.start,
                    .params_end = params.end,
                    .return_type = 0,
                });
                // Committed: the body parses non-speculatively.
                p.spec -= 1;
                defer p.spec += 1;
                const body = try p.parseArrowBody(ctx);
                return p.addNode(.{ .tag = .arrow_fn, .main_token = arrow_tok, .data = .{ .lhs = proto, .rhs = body } });
            }
        }
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();
        if (p.curTag() != .l_paren) return error.Backtrack;
        const params = try p.parseParams();
        var ret: Node = null_node;
        if (try p.eat(.colon) != null) ret = try p.parseReturnType();
        if (p.curTag() != .arrow) return error.Backtrack;
        if (p.nlBefore()) {
            // A line break before `=>` is a syntax error, but once we see
            // the arrow this *is* an arrow function; report and continue.
            p.spec -= 1;
            try p.errAtCur(.newline_before_arrow);
            p.spec += 1;
        }
        const arrow_tok = try p.bump();
        const proto = try p.addExtra(ast.FnProto{
            .flags = flags,
            .name_token = 0,
            .tp_start = tp.start,
            .tp_end = tp.end,
            .params_start = params.start,
            .params_end = params.end,
            .return_type = ret,
        });
        // Committed: parse the body non-speculatively so its errors surface.
        p.spec -= 1;
        defer p.spec += 1;
        const body = try p.parseArrowBody(ctx);
        return p.addNode(.{ .tag = .arrow_fn, .main_token = arrow_tok, .data = .{ .lhs = proto, .rhs = body } });
    }

    fn parseArrowBody(p: *Parser, ctx: ExprCtx) PE!Node {
        if (p.curTag() == .l_brace) return p.parseBlock();
        return p.parseAssignExpr(.{ .no_in = ctx.no_in });
    }

    fn parseBinaryExpr(p: *Parser, ctx: ExprCtx, min_prec: u8) PE!Node {
        var lhs = try p.parseUnaryExpr(ctx);
        while (true) {
            // `as` / `satisfies` bind at relational precedence.
            if ((p.curTag() == .keyword_as or p.curTag() == .keyword_satisfies) and !p.nlBefore() and min_prec <= 8) {
                const is_satisfies = p.curTag() == .keyword_satisfies;
                const op = try p.bump();
                // `expr as const`: the `const` contextual keyword is the
                // "type" (a const assertion), not a type reference.
                if (!is_satisfies and p.curTag() == .keyword_const) {
                    const ct = try p.leaf(.const_type);
                    lhs = try p.addNode(.{ .tag = .as_expr, .main_token = op, .data = .{ .lhs = lhs, .rhs = ct } });
                    continue;
                }
                const ty = try p.parseType();
                if (is_satisfies) {
                    lhs = try p.addNode(.{ .tag = .satisfies_expr, .main_token = op, .data = .{ .lhs = lhs, .rhs = ty } });
                } else {
                    lhs = try p.addNode(.{ .tag = .as_expr, .main_token = op, .data = .{ .lhs = lhs, .rhs = ty } });
                }
                continue;
            }
            const tag = p.curTag();
            const prec = binaryPrec(tag, ctx.no_in);
            if (prec == 0 or prec < min_prec) return lhs;
            const op = try p.bump();
            // `**` is right-associative; everything else left.
            const rhs = try p.parseBinaryExpr(ctx, if (tag == .asterisk_asterisk) prec else prec + 1);
            try p.checkNullishMixing(tag, op, lhs, rhs);
            lhs = try p.addNode(.{ .tag = .binary, .main_token = op, .data = .{ .lhs = lhs, .rhs = rhs } });
        }
    }

    /// `a ?? b || c` (and friends) is a grammar error without parens.
    fn checkNullishMixing(p: *Parser, op: TokTag, op_tok: u32, lhs: Node, rhs: Node) Error!void {
        if (p.spec > 0) return;
        const check = struct {
            fn opOf(pp: *Parser, node: Node) ?TokTag {
                if (pp.nodes.items(.tag)[node] != .binary) return null;
                return pp.tok_tags.items[pp.nodes.items(.main_token)[node]];
            }
        };
        const l = check.opOf(p, lhs);
        const r = check.opOf(p, rhs);
        const bad = switch (op) {
            .question_question => (l == .pipe_pipe or l == .amp_amp or r == .pipe_pipe or r == .amp_amp),
            .pipe_pipe, .amp_amp => (l == .question_question or r == .question_question),
            else => false,
        };
        if (bad) try p.errAtToken(.nullish_mixed_with_logical, op_tok);
    }

    fn parseUnaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        switch (p.curTag()) {
            .bang, .tilde, .plus, .minus, .plus_plus, .minus_minus, .keyword_typeof, .keyword_void, .keyword_delete => {
                const op = try p.bump();
                const operand = try p.parseUnaryExpr(ctx);
                return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_await => {
                // `await expr` when an expression follows; else `await` is
                // an ordinary identifier.
                if (canStartExpression(p.peekTag(1)) and p.peekTag(1) != .colon) {
                    const op = try p.bump();
                    const operand = try p.parseUnaryExpr(ctx);
                    return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = operand, .rhs = 0 } });
                }
            },
            else => {},
        }
        return p.parsePostfixExpr(ctx);
    }

    fn parsePostfixExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        const lhs = try p.parseLhsExpression(ctx);
        if ((p.curTag() == .plus_plus or p.curTag() == .minus_minus) and !p.nlBefore()) {
            const op = try p.bump();
            return p.addNode(.{ .tag = .postfix_unary, .main_token = op, .data = .{ .lhs = lhs, .rhs = 0 } });
        }
        return lhs;
    }

    /// MemberExpression / CallExpression chains, incl. optional chaining,
    /// non-null `!`, tagged templates, and generic-call speculation.
    fn parseLhsExpression(p: *Parser, ctx: ExprCtx) PE!Node {
        const lhs = if (p.curTag() == .keyword_new)
            try p.parseNewExpr(ctx)
        else
            try p.parsePrimaryExpr(ctx);
        return p.parseCallChain(lhs, ctx);
    }

    fn parseCallChain(p: *Parser, lhs_in: Node, ctx: ExprCtx) PE!Node {
        var lhs = lhs_in;
        while (true) {
            switch (p.curTag()) {
                .dot => {
                    const dot = try p.bump();
                    const name = try p.expectMemberName();
                    lhs = try p.addNode(.{ .tag = .member_expr, .main_token = dot, .data = .{ .lhs = lhs, .rhs = name } });
                },
                .question_dot => {
                    const qd = try p.bump();
                    switch (p.curTag()) {
                        .l_paren => {
                            const info = try p.parseCallInfo(.{ .start = 0, .end = 0 });
                            lhs = try p.addNode(.{ .tag = .optional_call, .main_token = qd, .data = .{ .lhs = lhs, .rhs = info } });
                        },
                        .l_bracket => {
                            _ = try p.bump();
                            const index = try p.parseExpression(.{});
                            _ = try p.expect(.r_bracket, .expected_r_bracket);
                            lhs = try p.addNode(.{ .tag = .optional_index_expr, .main_token = qd, .data = .{ .lhs = lhs, .rhs = index } });
                        },
                        .lt, .lt_lt => {
                            // `a?.<T>(...)`
                            if (try p.tryParseTypeArgsInExpr()) |targs| {
                                const info = try p.parseCallInfo(targs);
                                lhs = try p.addNode(.{ .tag = .optional_call, .main_token = qd, .data = .{ .lhs = lhs, .rhs = info } });
                            } else {
                                const name = try p.expectMemberName();
                                lhs = try p.addNode(.{ .tag = .optional_member_expr, .main_token = qd, .data = .{ .lhs = lhs, .rhs = name } });
                            }
                        },
                        .template_head, .no_substitution_template_literal => {
                            try p.fail(.tagged_template_in_optional_chain);
                            const tmpl = try p.parseTemplateExpr();
                            lhs = try p.addNode(.{ .tag = .tagged_template, .main_token = p.nodes.items(.main_token)[tmpl], .data = .{ .lhs = lhs, .rhs = tmpl } });
                        },
                        else => {
                            const name = try p.expectMemberName();
                            lhs = try p.addNode(.{ .tag = .optional_member_expr, .main_token = qd, .data = .{ .lhs = lhs, .rhs = name } });
                        },
                    }
                },
                .l_bracket => {
                    const lb = try p.bump();
                    const index = try p.parseExpression(.{});
                    _ = try p.expect(.r_bracket, .expected_r_bracket);
                    lhs = try p.addNode(.{ .tag = .index_expr, .main_token = lb, .data = .{ .lhs = lhs, .rhs = index } });
                },
                .l_paren => {
                    if (ctx.no_calls) return lhs;
                    const lp = p.curIdx();
                    const args = try p.parseArguments();
                    const extra = try p.addExtra(args);
                    lhs = try p.addNode(.{ .tag = .call_expr, .main_token = lp, .data = .{ .lhs = lhs, .rhs = extra } });
                },
                .bang => {
                    if (p.nlBefore()) return lhs;
                    const tok = try p.bump();
                    lhs = try p.addNode(.{ .tag = .non_null, .main_token = tok, .data = .{ .lhs = lhs, .rhs = 0 } });
                },
                .template_head, .no_substitution_template_literal => {
                    const tmpl = try p.parseTemplateExpr();
                    lhs = try p.addNode(.{ .tag = .tagged_template, .main_token = p.nodes.items(.main_token)[tmpl], .data = .{ .lhs = lhs, .rhs = tmpl } });
                },
                .lt, .lt_lt => {
                    if (ctx.no_calls) return lhs;
                    // Generic call speculation: `f<T>(...)`.
                    const targs = (try p.tryParseTypeArgsInExpr()) orelse return lhs;
                    const lp = p.curIdx();
                    const args = try p.parseArguments();
                    const info = try p.addExtra(ast.CallInfo{
                        .targs_start = targs.start,
                        .targs_end = targs.end,
                        .args_start = args.start,
                        .args_end = args.end,
                    });
                    lhs = try p.addNode(.{ .tag = .call_expr_targs, .main_token = lp, .data = .{ .lhs = lhs, .rhs = info } });
                },
                else => return lhs,
            }
        }
    }

    fn expectMemberName(p: *Parser) PE!u32 {
        if (isNameLike(p.curTag())) return p.bump();
        try p.fail(.expected_identifier);
        return p.lastIdx();
    }

    /// Type args + parenthesized args → extra→CallInfo (targs may be empty).
    fn parseCallInfo(p: *Parser, targs: ast.SubRange) PE!u32 {
        const args = try p.parseArguments();
        return p.addExtra(ast.CallInfo{
            .targs_start = targs.start,
            .targs_end = targs.end,
            .args_start = args.start,
            .args_end = args.end,
        });
    }

    /// `<T, ...>` accepted as type arguments only when `(` follows (see
    /// module docs); otherwise restores and returns null.
    fn tryParseTypeArgsInExpr(p: *Parser) PE!?ast.SubRange {
        const state = p.save();
        p.spec += 1;
        const result: PE!ast.SubRange = p.parseTypeArgs();
        p.spec -= 1;
        const range = result catch |err| switch (err) {
            error.Backtrack => {
                p.restore(state);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (p.curTag() != .l_paren) {
            p.restore(state);
            return null;
        }
        return range;
    }

    fn parseArguments(p: *Parser) PE!ast.SubRange {
        _ = try p.expect(.l_paren, .expected_l_paren);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_paren and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .dot_dot_dot) {
                const dots = try p.bump();
                const expr = try p.parseAssignExpr(.{});
                try p.pushScratch(try p.addNode(.{ .tag = .spread_element, .main_token = dots, .data = .{ .lhs = expr, .rhs = 0 } }));
            } else if (p.curTag() == .comma) {
                try p.errAtCur(.argument_expected);
                _ = try p.bump();
                continue;
            } else {
                try p.pushScratch(try p.parseAssignExpr(.{}));
            }
            if (try p.eat(.comma) == null and p.curTag() != .r_paren) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_paren, .expected_r_paren);
        return p.scratchToSpan(top);
    }

    fn parseNewExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        const kw = try p.bump(); // `new`
        if (p.curTag() == .dot) {
            // `new.target` — out of subset.
            _ = try p.bump();
            _ = try p.eat(.identifier);
            return p.unsupportedFrom(kw);
        }
        // Callee: member expression only (calls bind to the outer chain).
        var callee = try p.parsePrimaryExpr(ctx);
        callee = try p.parseCallChain(callee, .{ .no_in = ctx.no_in, .no_calls = true });

        var targs: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) {
            if (try p.tryParseTypeArgsInExpr()) |r| targs = r;
        }
        if (p.curTag() == .l_paren) {
            const args = try p.parseArguments();
            if (targs.start != targs.end) {
                const info = try p.addExtra(ast.CallInfo{
                    .targs_start = targs.start,
                    .targs_end = targs.end,
                    .args_start = args.start,
                    .args_end = args.end,
                });
                return p.addNode(.{ .tag = .new_expr_targs, .main_token = kw, .data = .{ .lhs = callee, .rhs = info } });
            }
            const extra = try p.addExtra(args);
            return p.addNode(.{ .tag = .new_expr, .main_token = kw, .data = .{ .lhs = callee, .rhs = extra } });
        }
        return p.addNode(.{ .tag = .new_expr_bare, .main_token = kw, .data = .{ .lhs = callee, .rhs = 0 } });
    }

    // --- JSX (parsed only when `p.jsx`; entered from parsePrimaryExpr) -----
    //
    // Opening tags, attributes, and `{expr}` containers use ordinary
    // trivia-skipping scanning. Children *text* does not (whitespace is
    // significant), so it is scanned directly via `scanner.scanJsxChild`
    // from a tracked byte offset, and lookahead is dropped when switching
    // back to normal scanning (`jsxResync`).

    /// Byte offset just past the last consumed token — where JSX child text
    /// resumes.
    fn lastTokEnd(p: *Parser) u32 {
        const i = p.lastIdx();
        const start = p.tok_starts.items[i] & scanner.Tokens.start_mask;
        return scanner.tokenEnd(p.src, p.tok_tags.items[i], start);
    }

    /// Resume normal scanning at byte offset `pos`, dropping stale lookahead.
    fn jsxResync(p: *Parser, pos: u32) void {
        p.scn.index = pos;
        p.la_len = 0;
    }

    /// `<tag ...>children</tag>`, `<tag .../>`, or `<>children</>`.
    /// Current token is `<`.
    fn parseJsxElement(p: *Parser) PE!Node {
        const lt = try p.bump(); // '<'
        var tag: Node = null_node;
        if (p.curTag() != .gt) tag = try p.parseJsxTagName();
        const attrs = try p.parseJsxAttributes();
        var self_closing: u32 = 0;
        var children: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.curTag() == .slash) {
            _ = try p.bump(); // '/'
            _ = try p.expect(.gt, .expected_gt);
            self_closing = 1;
        } else {
            _ = try p.expect(.gt, .expected_gt);
            children = try p.parseJsxChildren();
        }
        const data = try p.addExtra(ast.JsxElementData{
            .tag = tag,
            .self_closing = self_closing,
            .attrs_start = attrs.start,
            .attrs_end = attrs.end,
            .children_start = children.start,
            .children_end = children.end,
        });
        return p.addNode(.{ .tag = .jsx_element, .main_token = lt, .data = .{ .lhs = data, .rhs = 0 } });
    }

    /// Tag name: `div`, `Foo`, or a member chain `A.B.C`, as a value
    /// expression the checker resolves (lowercase leaf = intrinsic).
    fn parseJsxTagName(p: *Parser) PE!Node {
        const tok = try p.expectIdentLike();
        var node = try p.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
        while (p.curTag() == .dot) {
            const dot = try p.bump();
            const name = try p.expectMemberName();
            node = try p.addNode(.{ .tag = .member_expr, .main_token = dot, .data = .{ .lhs = node, .rhs = name } });
        }
        return node;
    }

    fn parseJsxAttributes(p: *Parser) PE!ast.SubRange {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .gt and p.curTag() != .slash and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .l_brace) {
                const lb = try p.bump(); // '{'
                _ = try p.eat(.dot_dot_dot); // '...'
                const expr = try p.parseAssignExpr(.{});
                _ = try p.expect(.r_brace, .expected_r_brace);
                try p.pushScratch(try p.addNode(.{ .tag = .jsx_spread_attribute, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } }));
            } else {
                const name = try p.expectIdentLike();
                var value: Node = null_node;
                if (try p.eat(.eq) != null) value = try p.parseJsxAttributeValue();
                try p.pushScratch(try p.addNode(.{ .tag = .jsx_attribute, .main_token = name, .data = .{ .lhs = value, .rhs = 0 } }));
            }
            if (p.curIdx() == before) break; // no progress: bail to avoid a loop
        }
        return p.scratchToSpan(top);
    }

    fn parseJsxAttributeValue(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .string_literal => return p.leaf(.string_literal),
            .l_brace => {
                const lb = try p.bump();
                const expr = try p.parseAssignExpr(.{});
                _ = try p.expect(.r_brace, .expected_r_brace);
                return p.addNode(.{ .tag = .jsx_expr_container, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } });
            },
            .lt => return p.parseJsxElement(),
            else => {
                try p.fail(.expected_expression);
                return p.errorNode();
            },
        }
    }

    /// Children of a non-self-closing element, up to the matching `</tag>`
    /// (whose closing tag this consumes).
    fn parseJsxChildren(p: *Parser) PE!ast.SubRange {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        var pos = p.lastTokEnd(); // just past the opening '>'
        while (true) {
            const tok = p.scn.scanJsxChild(pos);
            switch (tok.tag) {
                .jsx_text => {
                    const idx = p.curIdx();
                    try p.appendTok(.{ .tag = .jsx_text, .start = tok.start, .end = tok.end, .newline_before = false });
                    try p.pushScratch(try p.addNode(.{ .tag = .jsx_text, .main_token = idx, .data = .{ .lhs = 0, .rhs = 0 } }));
                    pos = tok.end;
                },
                .l_brace => {
                    p.jsxResync(tok.start);
                    const lb = try p.bump(); // '{'
                    var expr: Node = null_node;
                    if (p.curTag() != .r_brace) expr = try p.parseAssignExpr(.{});
                    _ = try p.expect(.r_brace, .expected_r_brace);
                    try p.pushScratch(try p.addNode(.{ .tag = .jsx_expr_container, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } }));
                    pos = p.lastTokEnd();
                },
                .lt => {
                    p.jsxResync(tok.start);
                    if (p.peekTag(1) == .slash) {
                        _ = try p.bump(); // '<'
                        _ = try p.bump(); // '/'
                        if (p.curTag() != .gt) _ = try p.parseJsxTagName();
                        _ = try p.expect(.gt, .expected_gt);
                        break;
                    }
                    try p.pushScratch(try p.parseJsxElement());
                    pos = p.lastTokEnd();
                },
                else => { // eof or unexpected
                    p.jsxResync(tok.start);
                    try p.fail(.expected_gt);
                    break;
                },
            }
        }
        return p.scratchToSpan(top);
    }

    fn parsePrimaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        if (p.jsx and p.curTag() == .lt) return p.parseJsxElement();
        switch (p.curTag()) {
            .numeric_literal => return p.leaf(.number_literal),
            .bigint_literal => return p.leaf(.bigint_literal),
            .string_literal => return p.leaf(.string_literal),
            .unterminated_string_literal => {
                try p.errAtCur(.unterminated_string);
                return p.leaf(.string_literal);
            },
            .regexp_literal => return p.leaf(.regex_literal),
            .unterminated_regexp_literal => {
                try p.errAtCur(.unterminated_regexp);
                return p.leaf(.regex_literal);
            },
            .slash, .slash_eq => {
                p.rescanRegex();
                if (p.curTag() == .unterminated_regexp_literal) {
                    try p.errAtCur(.unterminated_regexp);
                }
                return p.leaf(.regex_literal);
            },
            .no_substitution_template_literal, .template_head => return p.parseTemplateExpr(),
            .unterminated_template => {
                try p.errAtCur(.unterminated_template);
                return p.leaf(.template_literal);
            },
            .keyword_true => return p.leaf(.true_literal),
            .keyword_false => return p.leaf(.false_literal),
            .keyword_null => return p.leaf(.null_literal),
            .keyword_this => return p.leaf(.this_expr),
            .keyword_super => return p.leaf(.super_expr),
            .keyword_import => return p.leaf(.import_expr),
            .keyword_function => return p.parseFunctionDecl(0, true),
            .keyword_async => {
                if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                    _ = try p.bump();
                    return p.parseFunctionDecl(ast.Flags.async, true);
                }
                return p.leaf(.identifier);
            },
            .keyword_class => return p.parseClassDecl(0),
            .l_paren => {
                const lp = try p.bump();
                const inner = try p.parseExpression(.{});
                _ = try p.expect(.r_paren, .expected_r_paren);
                return p.addNode(.{ .tag = .paren_expr, .main_token = lp, .data = .{ .lhs = inner, .rhs = 0 } });
            },
            .l_bracket => return p.parseArrayLiteral(),
            .l_brace => return p.parseObjectLiteral(),
            .keyword_new => return p.parseNewExpr(ctx),
            .private_identifier => {
                // `#x in obj` (ergonomic brand check) or an error; parse as
                // an identifier-shaped leaf either way.
                return p.leaf(.identifier);
            },
            .unknown => {
                try p.fail(.unexpected_character);
                _ = try p.bump();
                return p.errorNode();
            },
            .unterminated_comment => {
                try p.fail(.unterminated_comment);
                _ = try p.bump();
                return p.errorNode();
            },
            else => {
                if (isIdentLike(p.curTag())) return p.leaf(.identifier);
                try p.fail(.expected_expression);
                return p.errorNode();
            },
        }
    }

    fn leaf(p: *Parser, comptime tag: ast.Tag) PE!Node {
        const tok = try p.bump();
        return p.addNode(.{ .tag = tag, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
    }

    /// Template literal: `plain` → leaf; with substitutions → template_expr.
    /// The parser owns the `}` → middle/tail rescan (grammar context).
    fn parseTemplateExpr(p: *Parser) PE!Node {
        if (p.curTag() == .no_substitution_template_literal) {
            return p.leaf(.template_literal);
        }
        const head = try p.bump(); // template_head
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) {
            try p.pushScratch(try p.parseExpression(.{}));
            if (p.curTag() != .r_brace) {
                try p.fail(.expected_r_brace);
                break;
            }
            p.rescanTemplatePart();
            switch (p.curTag()) {
                .template_middle => {
                    _ = try p.bump();
                    continue;
                },
                .template_tail => {
                    _ = try p.bump();
                    break;
                },
                .unterminated_template => {
                    try p.errAtCur(.unterminated_template);
                    _ = try p.bump();
                    break;
                },
                else => unreachable,
            }
        }
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .template_expr, .main_token = head, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseArrayLiteral(p: *Parser) PE!Node {
        const lb = try p.bump();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_bracket and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .comma) {
                const tok = try p.bump();
                try p.pushScratch(try p.addNode(.{ .tag = .omitted, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } }));
                continue;
            }
            if (p.curTag() == .dot_dot_dot) {
                const dots = try p.bump();
                const expr = try p.parseAssignExpr(.{});
                try p.pushScratch(try p.addNode(.{ .tag = .spread_element, .main_token = dots, .data = .{ .lhs = expr, .rhs = 0 } }));
            } else {
                try p.pushScratch(try p.parseAssignExpr(.{}));
            }
            if (try p.eat(.comma) == null and p.curTag() != .r_bracket) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .array_literal, .main_token = lb, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseObjectLiteral(p: *Parser) PE!Node {
        const lb = try p.bump();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            try p.pushScratch(try p.parseObjectMember());
            if (try p.eat(.comma) == null and p.curTag() != .r_brace) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .object_literal, .main_token = lb, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseObjectMember(p: *Parser) PE!Node {
        if (p.curTag() == .dot_dot_dot) {
            const dots = try p.bump();
            const expr = try p.parseAssignExpr(.{});
            return p.addNode(.{ .tag = .spread_element, .main_token = dots, .data = .{ .lhs = expr, .rhs = 0 } });
        }

        var flags: u32 = 0;
        // get/set/async modifiers (only when a property name follows).
        while (true) {
            const bit: u32 = switch (p.curTag()) {
                .keyword_get => ast.Flags.get,
                .keyword_set => ast.Flags.set,
                .keyword_async => ast.Flags.async,
                else => 0,
            };
            if (bit == 0) break;
            const t1 = p.peekTag(1);
            const name_follows = isNameLike(t1) or t1 == .string_literal or
                t1 == .numeric_literal or t1 == .l_bracket or t1 == .asterisk;
            if (!name_follows or p.peekNewline(1)) break;
            _ = try p.bump();
            flags |= bit;
        }
        if (try p.eat(.asterisk) != null) flags |= ast.Flags.generator;

        // Key.
        var key: Node = null_node;
        var key_tok: u32 = 0;
        switch (p.curTag()) {
            .string_literal => {
                key_tok = p.curIdx();
                key = try p.leaf(.string_literal);
            },
            .numeric_literal => {
                key_tok = p.curIdx();
                key = try p.leaf(.number_literal);
            },
            .l_bracket => {
                const lb = try p.bump();
                const expr = try p.parseAssignExpr(.{});
                _ = try p.expect(.r_bracket, .expected_r_bracket);
                key_tok = lb;
                key = try p.addNode(.{ .tag = .computed_name, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } });
            },
            else => {
                if (isNameLike(p.curTag())) {
                    key_tok = p.curIdx();
                    key = try p.leaf(.identifier);
                } else {
                    try p.fail(.expected_property_name);
                    return p.errorNode();
                }
            },
        }

        switch (p.curTag()) {
            .colon => {
                _ = try p.bump();
                const value = try p.parseAssignExpr(.{});
                return p.addNode(.{ .tag = .object_property, .main_token = key_tok, .data = .{ .lhs = key, .rhs = value } });
            },
            .l_paren, .lt, .lt_lt => {
                // Method shorthand: value is a function_expr.
                const proto = try p.parseFnProtoRest(flags, key_tok);
                var body: Node = null_node;
                if (p.curTag() == .l_brace) body = try p.parseBlock() else try p.fail(.expected_l_brace);
                const func = try p.addNode(.{ .tag = .function_expr, .main_token = key_tok, .data = .{ .lhs = proto, .rhs = body } });
                return p.addNode(.{ .tag = .object_method, .main_token = key_tok, .data = .{ .lhs = key, .rhs = func } });
            },
            .eq => {
                // `{ a = 1 }` — cover grammar for destructuring defaults.
                _ = try p.bump();
                const init = try p.parseAssignExpr(.{});
                return p.addNode(.{ .tag = .object_shorthand, .main_token = key_tok, .data = .{ .lhs = key, .rhs = init } });
            },
            else => {
                return p.addNode(.{ .tag = .object_shorthand, .main_token = key_tok, .data = .{ .lhs = key, .rhs = 0 } });
            },
        }
    }

    // =====================================================================
    // types
    // =====================================================================

    fn parseType(p: *Parser) PE!Node {
        // Function type `(params) => R` / `<T>(params) => R`; constructor
        // type `new (...) => R` is out of subset.
        switch (p.curTag()) {
            .lt, .lt_lt => return p.parseFunctionType(),
            .l_paren => {
                if (try p.tryParseFunctionType()) |ft| return ft;
            },
            .keyword_new => {
                const start = p.curIdx();
                _ = try p.bump();
                _ = try p.tryParseFunctionType(); // best-effort shape consume
                return p.unsupportedFrom(start);
            },
            .keyword_abstract => {
                if (p.peekTag(1) == .keyword_new) {
                    const start = try p.bump();
                    _ = try p.bump();
                    if (try p.tryParseFunctionType()) |_| {}
                    return p.unsupportedFrom(start);
                }
            },
            else => {},
        }
        const ty = try p.parseUnionType();
        // Conditional type `T extends U ? X : Y` — out of subset.
        if (p.curTag() == .keyword_extends and !p.nlBefore() and p.spec == 0) {
            const start_tok = p.nodes.items(.main_token)[ty];
            _ = try p.bump();
            _ = try p.parseUnionType();
            _ = try p.expect(.question, .expected_colon);
            _ = try p.parseType();
            _ = try p.expect(.colon, .expected_colon);
            _ = try p.parseType();
            return p.unsupportedFrom(start_tok);
        }
        return ty;
    }

    fn tryParseFunctionType(p: *Parser) PE!?Node {
        const state = p.save();
        p.spec += 1;
        const result = p.parseFunctionType();
        p.spec -= 1;
        return result catch |err| switch (err) {
            error.Backtrack => {
                p.restore(state);
                return null;
            },
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn parseFunctionType(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams();
        const params = try p.parseParams();
        _ = try p.expect(.arrow, .expected_arrow);
        const ret = try p.parseReturnType();
        const proto = try p.addExtra(ast.FnProto{
            .flags = 0,
            .name_token = 0,
            .tp_start = tp.start,
            .tp_end = tp.end,
            .params_start = params.start,
            .params_end = params.end,
            .return_type = ret,
        });
        return p.addNode(.{ .tag = .function_type, .main_token = start_tok, .data = .{ .lhs = proto, .rhs = 0 } });
    }

    fn parseUnionType(p: *Parser) PE!Node {
        var first_pipe: u32 = 0;
        if (p.curTag() == .pipe) first_pipe = try p.bump(); // leading `|`
        const first = try p.parseIntersectionType();
        if (p.curTag() != .pipe and first_pipe == 0) return first;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.pushScratch(first);
        var main_tok = first_pipe;
        while (p.curTag() == .pipe) {
            const tok = try p.bump();
            if (main_tok == 0) main_tok = tok;
            try p.pushScratch(try p.parseIntersectionType());
        }
        if (main_tok == 0) main_tok = p.nodes.items(.main_token)[first];
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .union_type, .main_token = main_tok, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseIntersectionType(p: *Parser) PE!Node {
        var first_amp: u32 = 0;
        if (p.curTag() == .amp) first_amp = try p.bump();
        const first = try p.parseTypeOperator();
        if (p.curTag() != .amp and first_amp == 0) return first;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.pushScratch(first);
        var main_tok = first_amp;
        while (p.curTag() == .amp) {
            const tok = try p.bump();
            if (main_tok == 0) main_tok = tok;
            try p.pushScratch(try p.parseTypeOperator());
        }
        if (main_tok == 0) main_tok = p.nodes.items(.main_token)[first];
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .intersection_type, .main_token = main_tok, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseTypeOperator(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .keyword_keyof => {
                const kw = try p.bump();
                const operand = try p.parseTypeOperator();
                return p.addNode(.{ .tag = .keyof_type, .main_token = kw, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_readonly => {
                const kw = try p.bump();
                const operand = try p.parseTypeOperator();
                return p.addNode(.{ .tag = .readonly_type, .main_token = kw, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_unique, .keyword_infer => {
                // unique symbol / infer T — out of subset.
                const start = try p.bump();
                _ = try p.parseTypeOperator();
                return p.unsupportedFrom(start);
            },
            else => return p.parsePostfixType(),
        }
    }

    fn parsePostfixType(p: *Parser) PE!Node {
        var ty = try p.parsePrimaryType();
        while (p.curTag() == .l_bracket and !p.nlBefore()) {
            const lb = try p.bump();
            if (try p.eat(.r_bracket) != null) {
                ty = try p.addNode(.{ .tag = .array_type, .main_token = lb, .data = .{ .lhs = ty, .rhs = 0 } });
            } else {
                const index = try p.parseType();
                _ = try p.expect(.r_bracket, .expected_r_bracket);
                ty = try p.addNode(.{ .tag = .indexed_access_type, .main_token = lb, .data = .{ .lhs = ty, .rhs = index } });
            }
        }
        return ty;
    }

    fn parsePrimaryType(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .string_literal => return p.leaf(.string_literal),
            .numeric_literal => return p.leaf(.number_literal),
            .bigint_literal => return p.leaf(.bigint_literal),
            .keyword_true => return p.leaf(.true_literal),
            .keyword_false => return p.leaf(.false_literal),
            .keyword_null => return p.leaf(.null_literal),
            .keyword_this => return p.leaf(.this_expr),
            .keyword_void => return p.leaf(.identifier),
            .minus => {
                // Negative literal type.
                const op = try p.bump();
                const operand = if (p.curTag() == .numeric_literal or p.curTag() == .bigint_literal)
                    try p.leaf(.number_literal)
                else blk: {
                    try p.fail(.expected_type);
                    break :blk try p.errorNode();
                };
                return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_typeof => {
                const kw = try p.bump();
                if (p.curTag() == .keyword_import) {
                    // `typeof import("m")` — out of subset.
                    p.skipImportTypeTail();
                    return p.unsupportedFrom(kw);
                }
                const entity = try p.parseEntityName();
                return p.addNode(.{ .tag = .typeof_type, .main_token = kw, .data = .{ .lhs = entity, .rhs = 0 } });
            },
            .l_brace => return p.parseObjectType(),
            .l_bracket => return p.parseTupleType(),
            .l_paren => {
                const lp = try p.bump();
                const inner = try p.parseType();
                _ = try p.expect(.r_paren, .expected_r_paren);
                return p.addNode(.{ .tag = .paren_type, .main_token = lp, .data = .{ .lhs = inner, .rhs = 0 } });
            },
            .template_head, .no_substitution_template_literal => {
                // Template literal type — out of subset.
                const start = p.curIdx();
                _ = try p.parseTemplateExpr();
                return p.unsupportedFrom(start);
            },
            .keyword_import => {
                const start = p.curIdx();
                p.skipImportTypeTail();
                return p.unsupportedFrom(start);
            },
            .unknown => {
                try p.fail(.unexpected_character);
                _ = try p.bump();
                return p.errorNode();
            },
            else => {
                if (isIdentLike(p.curTag())) {
                    const name = try p.parseEntityName();
                    if (p.atLt()) {
                        const lt_tok = p.curIdx();
                        const targs = try p.parseTypeArgs();
                        const extra = try p.addExtra(targs);
                        return p.addNode(.{ .tag = .type_ref, .main_token = lt_tok, .data = .{ .lhs = name, .rhs = extra } });
                    }
                    return name;
                }
                try p.fail(.expected_type);
                return p.errorNode();
            },
        }
    }

    /// `A` / `A.B.C` in type positions.
    fn parseEntityName(p: *Parser) PE!Node {
        var name = try p.leaf(.identifier);
        while (p.curTag() == .dot) {
            const dot = try p.bump();
            const part = try p.expectMemberName();
            name = try p.addNode(.{ .tag = .qualified_name, .main_token = dot, .data = .{ .lhs = name, .rhs = part } });
        }
        return name;
    }

    /// Consume `import("m")[.qualifier][<args>]` without building nodes.
    fn skipImportTypeTail(p: *Parser) void {
        _ = p.bump() catch return; // import
        if (p.curTag() == .l_paren) {
            _ = p.bump() catch return;
            var depth: u32 = 1;
            while (depth > 0) {
                switch (p.curTag()) {
                    .eof => return,
                    .l_paren => depth += 1,
                    .r_paren => depth -= 1,
                    else => {},
                }
                _ = p.bump() catch return;
            }
        }
        while (p.curTag() == .dot) {
            _ = p.bump() catch return;
            if (isNameLike(p.curTag())) _ = p.bump() catch return;
        }
    }

    fn parseTypeArgs(p: *Parser) PE!ast.SubRange {
        _ = try p.expectLt();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) {
            try p.pushScratch(try p.parseType());
            if (try p.eat(.comma) == null) break;
        }
        _ = try p.expectGt();
        return p.scratchToSpan(top);
    }

    fn parseTupleType(p: *Parser) PE!Node {
        const lb = try p.bump();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_bracket and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .dot_dot_dot) {
                const dots = try p.bump();
                const ty = try p.parseType();
                try p.pushScratch(try p.addNode(.{ .tag = .rest_type, .main_token = dots, .data = .{ .lhs = ty, .rhs = 0 } }));
            } else if (isIdentLike(p.curTag()) and
                (p.peekTag(1) == .colon or (p.peekTag(1) == .question and p.peekTag(2) == .colon)))
            {
                // Named tuple member `[x: T]` — out of subset.
                const start = p.curIdx();
                _ = try p.bump();
                _ = try p.eat(.question);
                _ = try p.bump(); // ':'
                _ = try p.parseType();
                try p.pushScratch(try p.unsupportedFrom(start));
            } else {
                var ty = try p.parseType();
                if (p.curTag() == .question) {
                    const q = try p.bump();
                    ty = try p.addNode(.{ .tag = .optional_type, .main_token = q, .data = .{ .lhs = ty, .rhs = 0 } });
                }
                try p.pushScratch(ty);
            }
            if (try p.eat(.comma) == null and p.curTag() != .r_bracket) {
                try p.fail(.expected_comma);
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .tuple_type, .main_token = lb, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseObjectType(p: *Parser) PE!Node {
        // Mapped type `{ [K in T]: V }` — out of subset.
        if (p.curTag() == .l_brace and p.peekTag(1) == .l_bracket and
            isIdentLike(p.peekTag(2)) and p.peekTag(3) == .keyword_in)
        {
            const start = p.curIdx();
            p.skipBalancedBraces();
            return p.unsupportedFrom(start);
        }
        const lb = p.curIdx();
        const members = try p.parseTypeMemberList();
        return p.addNode(.{ .tag = .object_type, .main_token = lb, .data = .{ .lhs = members.start, .rhs = members.end } });
    }

    /// `{ member; member, ... }` shared by interfaces and object types.
    fn parseTypeMemberList(p: *Parser) PE!ast.SubRange {
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            try p.pushScratch(try p.parseTypeMember());
            // Separators: `;` or `,`, or just a newline.
            _ = try p.eat(.semicolon) orelse try p.eat(.comma);
            if (p.curIdx() == before) {
                try p.errAtCur(.expected_type_member);
                _ = try p.bump();
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        return p.scratchToSpan(top);
    }

    fn parseTypeMember(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        var flags: u32 = 0;

        // Call signature `(...)` / construct signature `new (...)` — out of
        // subset (ROADMAP.md §6 keeps interfaces to prop/method/index signatures).
        if (p.curTag() == .l_paren or p.atLt()) {
            try p.parseFunctionTypeShapeless();
            return p.unsupportedFrom(start_tok);
        }
        if (p.curTag() == .keyword_new and (p.peekTag(1) == .l_paren or p.peekTag(1) == .lt or p.peekTag(1) == .lt_lt)) {
            _ = try p.bump();
            _ = try p.parseFunctionTypeShapeless();
            return p.unsupportedFrom(start_tok);
        }

        // readonly modifier (only when a name follows).
        if (p.curTag() == .keyword_readonly) {
            const t1 = p.peekTag(1);
            if (isNameLike(t1) or t1 == .string_literal or t1 == .numeric_literal or t1 == .l_bracket) {
                _ = try p.bump();
                flags |= ast.Flags.readonly;
            }
        }
        // get/set accessor signatures.
        if ((p.curTag() == .keyword_get or p.curTag() == .keyword_set) and
            (isNameLike(p.peekTag(1)) or p.peekTag(1) == .string_literal or p.peekTag(1) == .numeric_literal))
        {
            flags |= if (p.curTag() == .keyword_get) ast.Flags.get else ast.Flags.set;
            _ = try p.bump();
        }

        // Index signature `[k: K]: V`.
        var name_tok: u32 = 0;
        if (p.curTag() == .l_bracket) {
            if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .colon) {
                return p.parseIndexSignature(flags);
            }
            // Well-known-symbol key `[Symbol.iterator](): T` — keyed by a
            // synthetic atom, then parsed as an ordinary member below.
            if (try p.eatWellKnownSymbolName()) |ntok| {
                name_tok = ntok;
                flags |= ast.Flags.computed;
            } else {
                // Other computed properties in a type are out of subset.
                _ = try p.bump();
                _ = try p.parseAssignExpr(.{});
                _ = try p.eat(.r_bracket);
                if (try p.eat(.colon) != null) _ = try p.parseType();
                return p.unsupportedFrom(start_tok);
            }
        }

        // Property / method name.
        if (name_tok != 0) {
            // already set by the well-known-symbol path above
        } else if (isNameLike(p.curTag()) or p.curTag() == .string_literal or p.curTag() == .numeric_literal) {
            name_tok = try p.bump();
        } else {
            try p.fail(.expected_type_member);
            return p.errorNode();
        }
        if (try p.eat(.question) != null) flags |= ast.Flags.optional;

        if (p.curTag() == .l_paren or p.atLt()) {
            const proto = try p.parseFnProtoRest(flags, name_tok);
            return p.addNode(.{ .tag = .method_signature, .main_token = name_tok, .data = .{ .lhs = proto, .rhs = flags } });
        }
        var type_ann: Node = null_node;
        if (try p.eat(.colon) != null) type_ann = try p.parseType();
        return p.addNode(.{ .tag = .property_signature, .main_token = name_tok, .data = .{ .lhs = type_ann, .rhs = flags } });
    }

    /// Parse a `(params): R` / `<T>(params): R` signature shape, discarding
    /// the result (used inside unsupported call/construct signatures).
    fn parseFunctionTypeShapeless(p: *Parser) PE!void {
        if (p.atLt()) _ = try p.parseTypeParams();
        _ = try p.parseParams();
        if (try p.eat(.colon) != null) _ = try p.parseReturnType();
    }

    fn parseIndexSignature(p: *Parser, flags: u32) PE!Node {
        const lb = try p.bump(); // '['
        const name_tok = try p.expectIdentLike();
        _ = try p.expect(.colon, .expected_colon);
        const key_type = try p.parseType();
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        _ = try p.expect(.colon, .expected_colon);
        const value_type = try p.parseType();
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.IndexSig{ .name_token = name_tok, .key_type = key_type, .value_type = value_type });
        return p.addNode(.{ .tag = .index_signature, .main_token = lb, .data = .{ .lhs = extra, .rhs = flags } });
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parse `src` and render the root's children as newline-joined
/// S-expressions (the golden format).
fn dumpSource(alloc: Allocator, src: []const u8) ![]u8 {
    var tree = try parse(alloc, src);
    _ = &tree;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var it = tree.childIterator(0);
    var first = true;
    while (it.next()) |child| {
        if (!first) try aw.writer.writeAll("\n");
        first = false;
        try tree.dump(src, &aw.writer, child);
    }
    return aw.toOwnedSlice();
}

/// Golden test: exact S-expression match, and no diagnostics expected.
fn expectSExpr(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tree = try parse(alloc, src);
    if (tree.diagnostics.len != 0) {
        std.debug.print("--- unexpected diagnostics for: {s}\n", .{src});
        for (tree.diagnostics) |d| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ d.span.start, d.span.end, d.message() });
        }
        return error.TestUnexpectedDiagnostics;
    }
    const got = try dumpSource(alloc, src);
    testing.expectEqualStrings(expected, got) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        return err;
    };
}

/// Golden test allowing (and requiring) at least `min_diags` diagnostics.
fn expectSExprWithDiags(src: []const u8, min_diags: usize, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tree = try parse(alloc, src);
    if (tree.diagnostics.len < min_diags) {
        std.debug.print("--- expected >= {d} diagnostics, got {d} for: {s}\n", .{ min_diags, tree.diagnostics.len, src });
        return error.TestExpectedDiagnostics;
    }
    const got = try dumpSource(alloc, src);
    testing.expectEqualStrings(expected, got) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        return err;
    };
}

/// Count diagnostics and validate all spans are within file bounds.
fn expectDiagCount(src: []const u8, min: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), src);
    if (tree.diagnostics.len < min) {
        std.debug.print("--- expected >= {d} diagnostics, got {d} for: {s}\n", .{ min, tree.diagnostics.len, src });
        for (tree.diagnostics) |d| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ d.span.start, d.span.end, d.message() });
        }
        return error.TestExpectedDiagnostics;
    }
    for (tree.diagnostics) |d| {
        try testing.expect(d.span.start <= d.span.end);
        try testing.expect(d.span.start <= src.len);
        try testing.expect(d.span.end <= src.len + 1); // eof-anchored spans may be len+1
    }
}

// --- golden: variables & literals ------------------------------------------

test "golden: const with type and init" {
    try expectSExpr("const x: number = 1;",
        \\(var_decl_one const (declarator_full (identifier x) (identifier number) (number_literal 1)))
    );
}

test "golden: let without init, var multiple declarators" {
    try expectSExpr("let y;",
        \\(var_decl_one let (declarator (identifier y)))
    );
    try expectSExpr("var a = 1, b, c: string;",
        \\(var_decl var (declarator_init (identifier a) (number_literal 1)) (declarator (identifier b)) (declarator_full (identifier c) (identifier string)))
    );
}

test "golden: literal kinds" {
    try expectSExpr("x = [1, 0xFFn, \"s\", `t`, /re/g, true, false, null, undefined, this];",
        \\(expr_stmt (assign = (identifier x) (array_literal (number_literal 1) (bigint_literal 0xFFn) (string_literal "s") (template_literal `t`) (regex_literal /re/g) (true_literal) (false_literal) (null_literal) (identifier undefined) (this_expr))))
    );
}

test "golden: definite assignment declarator" {
    try expectSExpr("let x!: number;",
        \\(var_decl_one let (declarator_full :definite (identifier x) (identifier number)))
    );
}

// --- golden: expressions & precedence ---------------------------------------

test "golden: arithmetic precedence" {
    try expectSExpr("x = 1 + 2 * 3;",
        \\(expr_stmt (assign = (identifier x) (binary + (number_literal 1) (binary * (number_literal 2) (number_literal 3)))))
    );
    try expectSExpr("x = (1 + 2) * 3;",
        \\(expr_stmt (assign = (identifier x) (binary * (paren_expr (binary + (number_literal 1) (number_literal 2))) (number_literal 3))))
    );
}

test "golden: exponentiation is right-associative" {
    try expectSExpr("x = 2 ** 3 ** 4;",
        \\(expr_stmt (assign = (identifier x) (binary ** (number_literal 2) (binary ** (number_literal 3) (number_literal 4)))))
    );
}

test "golden: comparison / equality / logical stack" {
    try expectSExpr("x = a < b == c && d || e;",
        \\(expr_stmt (assign = (identifier x) (binary || (binary && (binary == (binary < (identifier a) (identifier b)) (identifier c)) (identifier d)) (identifier e))))
    );
}

test "golden: shift binds tighter than relational" {
    try expectSExpr("x = a << 2 < b >>> 1;",
        \\(expr_stmt (assign = (identifier x) (binary < (binary << (identifier a) (number_literal 2)) (binary >>> (identifier b) (number_literal 1)))))
    );
}

test "golden: in and instanceof are relational" {
    try expectSExpr("x = \"k\" in obj && v instanceof C;",
        \\(expr_stmt (assign = (identifier x) (binary && (binary in (string_literal "k") (identifier obj)) (binary instanceof (identifier v) (identifier C)))))
    );
}

test "golden: nullish coalescing parses alone" {
    try expectSExpr("x = a ?? b ?? c;",
        \\(expr_stmt (assign = (identifier x) (binary ?? (binary ?? (identifier a) (identifier b)) (identifier c))))
    );
}

test "golden: ?? mixed with || / && is a grammar error (TS behavior)" {
    // tsc: error TS5076. We keep the tree but must diagnose.
    try expectDiagCount("x = a ?? b || c;", 1);
    try expectDiagCount("x = a || b ?? c;", 1);
    try expectDiagCount("x = a && b ?? c;", 1);
    // Parenthesized forms are fine.
    try expectSExpr("x = (a ?? b) || c;",
        \\(expr_stmt (assign = (identifier x) (binary || (paren_expr (binary ?? (identifier a) (identifier b))) (identifier c))))
    );
    try expectSExpr("x = a ?? (b || c);",
        \\(expr_stmt (assign = (identifier x) (binary ?? (identifier a) (paren_expr (binary || (identifier b) (identifier c))))))
    );
}

test "golden: conditional expression nests" {
    try expectSExpr("x = a ? b : c ? d : e;",
        \\(expr_stmt (assign = (identifier x) (cond_expr (identifier a) (identifier b) (cond_expr (identifier c) (identifier d) (identifier e)))))
    );
}

test "golden: compound assignment right-associates" {
    try expectSExpr("a += b ||= c;",
        \\(expr_stmt (assign += (identifier a) (assign ||= (identifier b) (identifier c))))
    );
}

test "golden: comma operator" {
    try expectSExpr("x = (a, b, c);",
        \\(expr_stmt (assign = (identifier x) (paren_expr (seq_expr (seq_expr (identifier a) (identifier b)) (identifier c)))))
    );
}

test "golden: unary and postfix" {
    try expectSExpr("x = -+!~a;",
        \\(expr_stmt (assign = (identifier x) (prefix_unary - (prefix_unary + (prefix_unary ! (prefix_unary ~ (identifier a)))))))
    );
    try expectSExpr("x = typeof void delete a.b;",
        \\(expr_stmt (assign = (identifier x) (prefix_unary typeof (prefix_unary void (prefix_unary delete (member_expr (identifier a) b))))))
    );
    try expectSExpr("i++; --j;",
        \\(expr_stmt (postfix_unary ++ (identifier i)))
        \\(expr_stmt (prefix_unary -- (identifier j)))
    );
}

test "golden: member / index / call chains" {
    try expectSExpr("a.b.c[0](x, ...rest);",
        \\(expr_stmt (call_expr (index_expr (member_expr (member_expr (identifier a) b) c) (number_literal 0)) (identifier x) (spread_element (identifier rest))))
    );
}

test "golden: optional chaining combos" {
    try expectSExpr("a?.b;",
        \\(expr_stmt (optional_member_expr (identifier a) b))
    );
    try expectSExpr("a?.[k];",
        \\(expr_stmt (optional_index_expr (identifier a) (identifier k)))
    );
    try expectSExpr("f?.(x);",
        \\(expr_stmt (optional_call (identifier f) (identifier x)))
    );
    try expectSExpr("a?.b!.c;",
        \\(expr_stmt (member_expr (non_null (optional_member_expr (identifier a) b)) c))
    );
    try expectSExpr("a!?.b;",
        \\(expr_stmt (optional_member_expr (non_null (identifier a)) b))
    );
}

test "golden: non-null combines with calls and as" {
    try expectSExpr("x = f()!.y as T;",
        \\(expr_stmt (assign = (identifier x) (as_expr (member_expr (non_null (call_expr (identifier f))) y) (identifier T))))
    );
}

test "golden: new expressions" {
    try expectSExpr("x = new C;",
        \\(expr_stmt (assign = (identifier x) (new_expr_bare (identifier C))))
    );
    try expectSExpr("x = new C(1);",
        \\(expr_stmt (assign = (identifier x) (new_expr (identifier C) (number_literal 1))))
    );
    try expectSExpr("x = new a.B<T>(1).m();",
        \\(expr_stmt (assign = (identifier x) (call_expr (member_expr (new_expr_targs (member_expr (identifier a) B) (identifier T) (number_literal 1)) m))))
    );
    try expectSExpr("x = new new C()();",
        \\(expr_stmt (assign = (identifier x) (new_expr (new_expr (identifier C)))))
    );
}

test "golden: generic call vs relational (documented heuristic)" {
    // `f<T>(x)` — type arguments (matches tsc).
    try expectSExpr("f<T>(x);",
        \\(expr_stmt (call_expr_targs (identifier f) (identifier T) (identifier x)))
    );
    // `a < b > (c)` — ALSO a generic call, exactly like tsc.
    try expectSExpr("a < b > (c);",
        \\(expr_stmt (call_expr_targs (identifier a) (identifier b) (identifier c)))
    );
    // No `(` after `>` — relational chain, not type arguments.
    try expectSExpr("x = a < b && c > d;",
        \\(expr_stmt (assign = (identifier x) (binary && (binary < (identifier a) (identifier b)) (binary > (identifier c) (identifier d)))))
    );
    // Nested generic closes with `>>` split.
    try expectSExpr("f<Map<K, V>>(m);",
        \\(expr_stmt (call_expr_targs (identifier f) (type_ref (identifier Map) (identifier K) (identifier V)) (identifier m)))
    );
}

test "golden: template literals with substitutions" {
    try expectSExpr("x = `a${b}c${d}e`;",
        \\(expr_stmt (assign = (identifier x) (template_expr (identifier b) (identifier d))))
    );
    try expectSExpr("x = `outer${`inner${y}`}end`;",
        \\(expr_stmt (assign = (identifier x) (template_expr (template_expr (identifier y)))))
    );
    try expectSExpr("x = tag`a${b}`;",
        \\(expr_stmt (assign = (identifier x) (tagged_template (identifier tag) (template_expr (identifier b)))))
    );
    try expectSExpr("x = `obj${ {a: {b: 1}} }`;",
        \\(expr_stmt (assign = (identifier x) (template_expr (object_literal (object_property (identifier a) (object_literal (object_property (identifier b) (number_literal 1))))))))
    );
}

test "golden: object literal forms" {
    try expectSExpr("x = {a: 1, b, \"c\": 2, 3: d, [k]: e, ...rest};",
        \\(expr_stmt (assign = (identifier x) (object_literal (object_property (identifier a) (number_literal 1)) (object_shorthand b (identifier b)) (object_property (string_literal "c") (number_literal 2)) (object_property (number_literal 3) (identifier d)) (object_property (computed_name (identifier k)) (identifier e)) (spread_element (identifier rest)))))
    );
    try expectSExpr("x = {m() { return 1; }};",
        \\(expr_stmt (assign = (identifier x) (object_literal (object_method (identifier m) (function_expr m (block (return_stmt (number_literal 1))))))))
    );
}

test "golden: array literal with holes and spread" {
    try expectSExpr("x = [1, , 2, ...xs];",
        \\(expr_stmt (assign = (identifier x) (array_literal (number_literal 1) (omitted) (number_literal 2) (spread_element (identifier xs)))))
    );
}

test "golden: as and satisfies" {
    try expectSExpr("x = v as string | number;",
        \\(expr_stmt (assign = (identifier x) (as_expr (identifier v) (union_type (identifier string) (identifier number)))))
    );
    try expectSExpr("x = v satisfies T;",
        \\(expr_stmt (assign = (identifier x) (satisfies_expr (identifier v) (identifier T))))
    );
    // `as const`: the `const` keyword parses as a const-assertion type.
    try expectSExpr("x = v as const;",
        \\(expr_stmt (assign = (identifier x) (as_expr (identifier v) (const_type))))
    );
}

// --- golden: arrow functions -------------------------------------------------

test "golden: arrow forms" {
    try expectSExpr("f = x => x;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (param (identifier x)) (identifier x))))
    );
    try expectSExpr("f = (a, b) => a + b;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (param (identifier a)) (param (identifier b)) (binary + (identifier a) (identifier b)))))
    );
    try expectSExpr("f = () => ({});",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (paren_expr (object_literal)))))
    );
    try expectSExpr("f = (x: number, y = 2): number => x + y;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (param (identifier x) (identifier number)) (param_full (identifier y) (number_literal 2)) (identifier number) (binary + (identifier x) (identifier y)))))
    );
    try expectSExpr("f = async (x) => x;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn :async (param (identifier x)) (identifier x))))
    );
    try expectSExpr("f = async x => x;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn :async (param (identifier x)) (identifier x))))
    );
    try expectSExpr("f = <T>(x: T) => x;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (type_param T) (param (identifier x) (identifier T)) (identifier x))))
    );
}

test "golden: paren expr is not an arrow" {
    try expectSExpr("x = (a, b);",
        \\(expr_stmt (assign = (identifier x) (paren_expr (seq_expr (identifier a) (identifier b)))))
    );
    try expectSExpr("y = (z);",
        \\(expr_stmt (assign = (identifier y) (paren_expr (identifier z))))
    );
    // Call of `async` as a plain identifier.
    try expectSExpr("async(1);",
        \\(expr_stmt (call_expr (identifier async) (number_literal 1)))
    );
}

test "golden: arrows nest and capture bodies" {
    try expectSExpr("f = a => b => a + b;",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (param (identifier a)) (arrow_fn (param (identifier b)) (binary + (identifier a) (identifier b))))))
    );
    try expectSExpr("f = (a) => { return a; };",
        \\(expr_stmt (assign = (identifier f) (arrow_fn (param (identifier a)) (block (return_stmt (identifier a))))))
    );
}

// --- golden: statements -------------------------------------------------------

test "golden: if / else chains" {
    try expectSExpr("if (a) b(); else if (c) d(); else e();",
        \\(if_else_stmt (identifier a) (expr_stmt (call_expr (identifier b))) (if_else_stmt (identifier c) (expr_stmt (call_expr (identifier d))) (expr_stmt (call_expr (identifier e)))))
    );
}

test "golden: while / do-while" {
    try expectSExpr("while (x) { x--; }",
        \\(while_stmt (identifier x) (block (expr_stmt (postfix_unary -- (identifier x)))))
    );
    try expectSExpr("do x++; while (x < 3);",
        \\(do_stmt (expr_stmt (postfix_unary ++ (identifier x))) (binary < (identifier x) (number_literal 3)))
    );
}

test "golden: classic for" {
    try expectSExpr("for (let i = 0; i < n; i++) f(i);",
        \\(for_stmt (var_decl_one let (declarator_init (identifier i) (number_literal 0))) (binary < (identifier i) (identifier n)) (postfix_unary ++ (identifier i)) (expr_stmt (call_expr (identifier f) (identifier i))))
    );
    try expectSExpr("for (;;) break;",
        \\(for_stmt (break_stmt))
    );
}

test "golden: for-of and for-in" {
    try expectSExpr("for (const x of xs) f(x);",
        \\(for_of_stmt (var_decl_one const (declarator (identifier x))) (identifier xs) (expr_stmt (call_expr (identifier f) (identifier x))))
    );
    try expectSExpr("for (const k in obj) f(k);",
        \\(for_in_stmt (var_decl_one const (declarator (identifier k))) (identifier obj) (expr_stmt (call_expr (identifier f) (identifier k))))
    );
    try expectSExpr("for (x of xs) {}",
        \\(for_of_stmt (identifier x) (identifier xs) (block))
    );
}

test "golden: switch with case/default" {
    try expectSExpr("switch (x) { case 1: a(); break; default: b(); }",
        \\(switch_stmt (identifier x) (case_clause (number_literal 1) (expr_stmt (call_expr (identifier a))) (break_stmt)) (default_clause (expr_stmt (call_expr (identifier b)))))
    );
}

test "golden: try / catch / finally" {
    try expectSExpr("try { f(); } catch (e) { g(e); } finally { h(); }",
        \\(try_stmt (block (expr_stmt (call_expr (identifier f)))) (catch_clause (declarator (identifier e)) (block (expr_stmt (call_expr (identifier g) (identifier e))))) (block (expr_stmt (call_expr (identifier h)))))
    );
    try expectSExpr("try { f(); } catch { g(); }",
        \\(try_stmt (block (expr_stmt (call_expr (identifier f)))) (catch_clause (block (expr_stmt (call_expr (identifier g))))))
    );
    try expectSExpr("try { f(); } catch (e: unknown) {}",
        \\(try_stmt (block (expr_stmt (call_expr (identifier f)))) (catch_clause (declarator_full (identifier e) (identifier unknown)) (block)))
    );
}

test "golden: labeled statement, break/continue with labels" {
    try expectSExpr("outer: for (;;) { continue outer; break outer; }",
        \\(labeled_stmt outer (for_stmt (block (continue_stmt outer) (break_stmt outer))))
    );
}

test "golden: throw and empty statement" {
    try expectSExpr("throw new Error(\"x\");",
        \\(throw_stmt (new_expr (identifier Error) (string_literal "x")))
    );
    try expectSExpr(";",
        \\(empty_stmt)
    );
}

// --- golden: ASI --------------------------------------------------------------

test "golden: ASI return newline value" {
    // `return\nvalue` is `return; value;` (restricted production).
    try expectSExpr("function f() { return\n1; }",
        \\(function_decl f (block (return_stmt) (expr_stmt (number_literal 1))))
    );
    try expectSExpr("function f() { return 1; }",
        \\(function_decl f (block (return_stmt (number_literal 1))))
    );
}

test "golden: ASI between statements without semicolons" {
    try expectSExpr("let a = 1\nlet b = 2",
        \\(var_decl_one let (declarator_init (identifier a) (number_literal 1)))
        \\(var_decl_one let (declarator_init (identifier b) (number_literal 2)))
    );
}

test "golden: ASI does not split across operators" {
    try expectSExpr("x = a\n+ b;",
        \\(expr_stmt (assign = (identifier x) (binary + (identifier a) (identifier b))))
    );
}

test "golden: no-newline restriction on postfix ++" {
    // `a\n++b` is `a; ++b;` per ASI.
    try expectSExpr("a\n++b",
        \\(expr_stmt (identifier a))
        \\(expr_stmt (prefix_unary ++ (identifier b)))
    );
}

test "golden: ASI break with newline label" {
    try expectSExpr("while (x) { break\nfoo; }",
        \\(while_stmt (identifier x) (block (break_stmt) (expr_stmt (identifier foo))))
    );
}

test "errors: throw with line break" {
    try expectDiagCount("function f() { throw\nnew Error(); }", 1);
}

// --- golden: functions ---------------------------------------------------------

test "golden: function declarations" {
    try expectSExpr("function add(a: number, b: number): number { return a + b; }",
        \\(function_decl add (param (identifier a) (identifier number)) (param (identifier b) (identifier number)) (identifier number) (block (return_stmt (binary + (identifier a) (identifier b)))))
    );
    try expectSExpr("async function go() {}",
        \\(function_decl :async go (block))
    );
}

test "golden: optional / default / rest params" {
    try expectSExpr("function f(a?: string, b = 1, ...rest: number[]) {}",
        \\(function_decl f (param_full :optional (identifier a) (identifier string)) (param_full (identifier b) (number_literal 1)) (param_full :rest (identifier rest) (array_type (identifier number))) (block))
    );
}

test "golden: overload signatures then implementation" {
    try expectSExpr("function f(x: string): string;\nfunction f(x: number): number;\nfunction f(x) { return x; }",
        \\(function_decl f (param (identifier x) (identifier string)) (identifier string))
        \\(function_decl f (param (identifier x) (identifier number)) (identifier number))
        \\(function_decl f (param (identifier x)) (block (return_stmt (identifier x))))
    );
}

test "golden: generic function with constraint and default" {
    try expectSExpr("function pick<T extends object, K = string>(o: T, k: K): void {}",
        \\(function_decl pick (type_param T (identifier object)) (type_param K (identifier string)) (param (identifier o) (identifier T)) (param (identifier k) (identifier K)) (identifier void) (block))
    );
}

test "golden: function expression and IIFE" {
    try expectSExpr("x = function named() { return 1; };",
        \\(expr_stmt (assign = (identifier x) (function_expr named (block (return_stmt (number_literal 1))))))
    );
    try expectSExpr("(function () {})();",
        \\(expr_stmt (call_expr (paren_expr (function_expr (block)))))
    );
}

// --- golden: classes ------------------------------------------------------------

test "golden: class with fields, methods, visibility" {
    try expectSExpr("class Point { private x: number = 0; readonly y!: number; static origin: Point; constructor(x: number) { this.x = x; } dist(): number { return this.x; } }",
        \\(class_decl Point (class_field :private x (identifier number) (number_literal 0)) (class_field :readonly :definite y (identifier number)) (class_field :static origin (identifier Point)) (class_method constructor (param (identifier x) (identifier number)) (block (expr_stmt (assign = (member_expr (this_expr) x) (identifier x))))) (class_method dist (identifier number) (block (return_stmt (member_expr (this_expr) x)))))
    );
}

test "golden: class extends and implements with type args" {
    try expectSExpr("class Dog extends Animal<string> implements Pet, Named {}",
        \\(class_decl Dog (heritage (identifier Animal) (identifier string)) (heritage (identifier Pet)) (heritage (identifier Named)))
    );
}

test "golden: generic class, parameter properties" {
    try expectSExpr("class Box<T> { constructor(private value: T) {} get(): T { return this.value; } }",
        \\(class_decl Box (type_param T) (class_method constructor (param_full :private (identifier value) (identifier T)) (block)) (class_method get (identifier T) (block (return_stmt (member_expr (this_expr) value)))))
    );
}

test "golden: abstract class and method modifiers" {
    try expectSExpr("abstract class Base { abstract area(): number; protected static count = 0; }",
        \\(class_decl :abstract Base (class_method :abstract area (identifier number)) (class_field :static :protected count (number_literal 0)))
    );
}

test "golden: class expression and getters/setters" {
    try expectSExpr("const C = class Inner { get v(): number { return 1; } set v(n: number) {} };",
        \\(var_decl_one const (declarator_init (identifier C) (class_decl Inner (class_method :get v (identifier number) (block (return_stmt (number_literal 1)))) (class_method :set v (param (identifier n) (identifier number)) (block)))))
    );
}

test "golden: private-hash field names parse" {
    try expectSExpr("class A { #x = 1; m() { return this.#x; } }",
        \\(class_decl A (class_field #x (number_literal 1)) (class_method m (block (return_stmt (member_expr (this_expr) #x)))))
    );
}

// --- golden: interfaces & type aliases -------------------------------------------

test "golden: interface with members" {
    try expectSExpr("interface Shape { kind: string; area(): number; readonly id?: number; [key: string]: unknown; }",
        \\(interface_decl Shape (property_signature kind (identifier string)) (method_signature area (identifier number)) (property_signature :readonly :optional id (identifier number)) (index_signature key (identifier string) (identifier unknown)))
    );
}

test "golden: interface extends multiple" {
    try expectSExpr("interface A extends B, C<number> { x: string; }",
        \\(interface_decl A (heritage (identifier B)) (heritage (identifier C) (identifier number)) (property_signature x (identifier string)))
    );
}

test "golden: generic interface with method type params" {
    try expectSExpr("interface Mapper<T> { map<U>(f: (t: T) => U): U[]; }",
        \\(interface_decl Mapper (type_param T) (method_signature map (type_param U) (param (identifier f) (function_type (param (identifier t) (identifier T)) (identifier U))) (array_type (identifier U))))
    );
}

test "golden: type alias forms" {
    try expectSExpr("type ID = string | number;",
        \\(type_alias ID (union_type (identifier string) (identifier number)))
    );
    try expectSExpr("type Pair<A, B = A> = [A, B];",
        \\(type_alias Pair (type_param A) (type_param B (identifier A)) (tuple_type (identifier A) (identifier B)))
    );
    try expectSExpr("type Fn = (x: number) => string;",
        \\(type_alias Fn (function_type (param (identifier x) (identifier number)) (identifier string)))
    );
}

// --- golden: the type grammar ----------------------------------------------------

test "golden: union, intersection, precedence" {
    try expectSExpr("type T = A & B | C & D;",
        \\(type_alias T (union_type (intersection_type (identifier A) (identifier B)) (intersection_type (identifier C) (identifier D))))
    );
    try expectSExpr("type U = | A | B;",
        \\(type_alias U (union_type (identifier A) (identifier B)))
    );
}

test "golden: array / tuple / parenthesized types" {
    try expectSExpr("type T = string[][];",
        \\(type_alias T (array_type (array_type (identifier string))))
    );
    try expectSExpr("type T = (A | B)[];",
        \\(type_alias T (array_type (paren_type (union_type (identifier A) (identifier B)))))
    );
    try expectSExpr("type T = [number, string?, ...boolean[]];",
        \\(type_alias T (tuple_type (identifier number) (optional_type (identifier string)) (rest_type (array_type (identifier boolean)))))
    );
}

test "golden: object type literals" {
    try expectSExpr("type O = { a: number; b?: string, readonly c: boolean };",
        \\(type_alias O (object_type (property_signature a (identifier number)) (property_signature :optional b (identifier string)) (property_signature :readonly c (identifier boolean))))
    );
}

test "golden: keyof / typeof / indexed access" {
    try expectSExpr("type K = keyof Config;",
        \\(type_alias K (keyof_type (identifier Config)))
    );
    try expectSExpr("type V = typeof settings.theme;",
        \\(type_alias V (typeof_type (qualified_name (identifier settings) theme)))
    );
    try expectSExpr("type E = Config[\"theme\"];",
        \\(type_alias E (indexed_access_type (identifier Config) (string_literal "theme")))
    );
    try expectSExpr("type N = Config[keyof Config];",
        \\(type_alias N (indexed_access_type (identifier Config) (keyof_type (identifier Config))))
    );
}

test "golden: literal types" {
    try expectSExpr("type L = \"a\" | 1 | -2 | true | false | null;",
        \\(type_alias L (union_type (string_literal "a") (number_literal 1) (prefix_unary - (number_literal 2)) (true_literal) (false_literal) (null_literal)))
    );
}

test "golden: generic type refs and qualified names" {
    try expectSExpr("type M = Map<string, Set<number>>;",
        \\(type_alias M (type_ref (identifier Map) (identifier string) (type_ref (identifier Set) (identifier number))))
    );
    try expectSExpr("let x: NS.Inner.Thing<T>;",
        \\(var_decl_one let (declarator_full (identifier x) (type_ref (qualified_name (qualified_name (identifier NS) Inner) Thing) (identifier T))))
    );
}

test "golden: function types nest" {
    try expectSExpr("type F = (cb: (e: Error) => void) => () => number;",
        \\(type_alias F (function_type (param (identifier cb) (function_type (param (identifier e) (identifier Error)) (identifier void))) (function_type (identifier number))))
    );
    try expectSExpr("type G = <T>(x: T) => T;",
        \\(type_alias G (function_type (type_param T) (param (identifier x) (identifier T)) (identifier T)))
    );
}

test "golden: readonly array type operator" {
    try expectSExpr("type R = readonly string[];",
        \\(type_alias R (readonly_type (array_type (identifier string))))
    );
}

// --- golden: modules ------------------------------------------------------------

test "golden: import forms" {
    try expectSExpr("import \"./side-effect\";",
        \\(import_decl from="./side-effect")
    );
    try expectSExpr("import def from \"mod\";",
        \\(import_decl default=def from="mod")
    );
    try expectSExpr("import * as ns from \"mod\";",
        \\(import_decl ns=ns from="mod")
    );
    try expectSExpr("import def, { a, b as c } from \"mod\";",
        \\(import_decl default=def from="mod" (import_specifier a) (import_specifier b as=c))
    );
    try expectSExpr("import def, * as ns from \"mod\";",
        \\(import_decl default=def ns=ns from="mod")
    );
}

test "golden: type-only imports" {
    try expectSExpr("import type { T, U as V } from \"mod\";",
        \\(import_decl :type from="mod" (import_specifier T) (import_specifier U as=V))
    );
    try expectSExpr("import type Def from \"mod\";",
        \\(import_decl :type default=Def from="mod")
    );
    try expectSExpr("import { type T, x } from \"mod\";",
        \\(import_decl from="mod" (import_specifier :type T) (import_specifier x))
    );
    // `import type from "m"` imports a default binding named `type`.
    try expectSExpr("import type from \"mod\";",
        \\(import_decl default=type from="mod")
    );
}

test "golden: export forms" {
    try expectSExpr("export const x = 1;",
        \\(export_decl (var_decl_one const (declarator_init (identifier x) (number_literal 1))))
    );
    try expectSExpr("export function f() {}",
        \\(export_decl (function_decl f (block)))
    );
    try expectSExpr("export default class C {}",
        \\(export_default (class_decl C))
    );
    try expectSExpr("export default 42;",
        \\(export_default (number_literal 42))
    );
    try expectSExpr("export { a, b as c };",
        \\(export_named (export_specifier a) (export_specifier b as=c))
    );
    try expectSExpr("export { a } from \"mod\";",
        \\(export_named from="mod" (export_specifier a))
    );
    try expectSExpr("export * from \"mod\";",
        \\(export_all from="mod")
    );
    try expectSExpr("export * as ns from \"mod\";",
        \\(export_all ns=ns from="mod")
    );
}

test "golden: type-only exports" {
    try expectSExpr("export type { T };",
        \\(export_named :type (export_specifier T))
    );
    try expectSExpr("export type Alias = number;",
        \\(export_decl (type_alias Alias (identifier number)))
    );
    try expectSExpr("export interface I { x: number; }",
        \\(export_decl (interface_decl I (property_signature x (identifier number))))
    );
}

test "golden: dynamic import and import.meta are expressions" {
    try expectSExpr("import(\"./m\").then(f);",
        \\(expr_stmt (call_expr (member_expr (call_expr (import_expr) (string_literal "./m")) then) (identifier f)))
    );
    try expectSExpr("x = import.meta;",
        \\(expr_stmt (assign = (identifier x) (member_expr (import_expr) meta)))
    );
}

// --- golden: destructuring --------------------------------------------------------

test "golden: array destructuring declarations" {
    try expectSExpr("const [a, b] = pair;",
        \\(var_decl_one const (declarator_init (array_pattern (identifier a) (identifier b)) (identifier pair)))
    );
    try expectSExpr("const [x = 1, , ...rest] = xs;",
        \\(var_decl_one const (declarator_init (array_pattern (binding_default (identifier x) (number_literal 1)) (omitted) (rest_element (identifier rest))) (identifier xs)))
    );
    try expectSExpr("let [[a], [b]] = m;",
        \\(var_decl_one let (declarator_init (array_pattern (array_pattern (identifier a)) (array_pattern (identifier b))) (identifier m)))
    );
}

test "golden: object destructuring declarations" {
    try expectSExpr("const {a, b: c, d = 1, e: f = 2, ...rest} = o;",
        \\(var_decl_one const (declarator_init (object_pattern (binding_property a) (binding_property b (identifier c)) (binding_property d (number_literal 1)) (binding_property e (identifier f) (number_literal 2)) (rest_element (identifier rest))) (identifier o)))
    );
    try expectSExpr("const {a: {b}} = o;",
        \\(var_decl_one const (declarator_init (object_pattern (binding_property a (object_pattern (binding_property b)))) (identifier o)))
    );
}

test "golden: destructuring with type annotations" {
    try expectSExpr("const {x, y}: Point = p;",
        \\(var_decl_one const (declarator_full (object_pattern (binding_property x) (binding_property y)) (identifier Point) (identifier p)))
    );
}

test "golden: destructuring params" {
    try expectSExpr("function f({a, b}: Opts, [c, d]: number[]) {}",
        \\(function_decl f (param (object_pattern (binding_property a) (binding_property b)) (identifier Opts)) (param (array_pattern (identifier c) (identifier d)) (array_type (identifier number))) (block))
    );
    try expectSExpr("g = ({a = 1}, [b] = []) => a + b;",
        \\(expr_stmt (assign = (identifier g) (arrow_fn (param (object_pattern (binding_property a (number_literal 1)))) (param_full (array_pattern (identifier b)) (array_literal)) (binary + (identifier a) (identifier b)))))
    );
}

test "golden: destructuring assignment uses literal cover grammar" {
    try expectSExpr("[a, b] = [b, a];",
        \\(expr_stmt (assign = (array_literal (identifier a) (identifier b)) (array_literal (identifier b) (identifier a))))
    );
    try expectSExpr("({a} = o);",
        \\(expr_stmt (paren_expr (assign = (object_literal (object_shorthand a (identifier a))) (identifier o))))
    );
}

test "golden: for-of with destructuring" {
    try expectSExpr("for (const [k, v] of entries) {}",
        \\(for_of_stmt (var_decl_one const (declarator (array_pattern (identifier k) (identifier v)))) (identifier entries) (block))
    );
}

// --- subset boundary: unsupported constructs never crash --------------------------

test "enums parse into enum_decl / enum_member nodes" {
    try expectSExpr("enum Color { Red = 1, Green }",
        \\(enum_decl Color (enum_member Red (number_literal 1)) (enum_member Green))
    );
    // `const enum` parses too; main token stays on `const`.
    try expectSExpr("const enum Fast { A }",
        \\(enum_decl Fast (enum_member A))
    );
    // String enum members and a trailing comma.
    try expectSExpr("enum S { A = \"a\", B = \"b\", }",
        \\(enum_decl S (enum_member A (string_literal "a")) (enum_member B (string_literal "b")))
    );
}

test "namespaces and modules (identifier-named) parse" {
    try expectDiagCount("namespace NS { export const x = 1; }", 0);
    try expectDiagCount("module M { let y = 2; }", 0);
    try expectDiagCount("declare namespace D { export const x: number; }", 0);
    try expectSExpr("namespace NS { export const x = 1; }",
        \\(namespace_decl NS (export_decl (var_decl_one const (declarator_init (identifier x) (number_literal 1)))))
    );
}

test "unsupported: string-module and global augmentation" {
    // String-module names stay out of subset (M11c); `declare global` is
    // in subset as of M11a.
    try expectDiagCount("declare module \"foo\" { export function f(): void; }", 1);
    try expectDiagCount("module \"bar\" { export const x = 1; }", 1);
    try expectDiagCount("declare global { interface Window {} }", 0);
}

test "unsupported: decorators" {
    try expectDiagCount("@Component({selector: \"x\"}) class Foo {}", 1);
    try expectDiagCount("class A { @observable x = 1; }", 1);
}

test "unsupported: conditional and mapped types" {
    try expectDiagCount("type C<T> = T extends string ? 1 : 0;", 1);
    try expectDiagCount("type M = { [K in Keys]: boolean };", 1);
}

test "unsupported: template literal types and infer" {
    try expectDiagCount("type T = `prefix-${string}`;", 1);
    try expectDiagCount("type E<T> = T extends Array<infer U> ? U : never;", 1);
}

test "unsupported: import= and export=" {
    try expectDiagCount("import x = require(\"m\");", 1);
    try expectDiagCount("export = thing;", 1);
}

test "unsupported: misc type-level constructs" {
    try expectDiagCount("type F = new () => Thing;", 1); // constructor type
    try expectDiagCount("type P = typeof import(\"m\");", 1);
    try expectDiagCount("type U = unique symbol;", 1);
    try expectDiagCount("interface I { (x: number): string; }", 1); // call signature
    try expectDiagCount("interface I { new (x: number): Thing; }", 1); // construct signature
    try expectDiagCount("type NT = [x: number, y: number];", 1); // named tuple members
}

test "type predicates parse cleanly" {
    try expectDiagCount("function f(x: unknown): x is string { return true; }", 0);
    try expectDiagCount("function f(x: unknown): asserts x is string {}", 0);
    try expectDiagCount("function f(c: unknown): asserts c {}", 0);
    try expectDiagCount("const f = (x: unknown): x is string => true;", 0);
}

test "unsupported: class oddities" {
    try expectDiagCount("class A { static { init(); } }", 1);
    try expectDiagCount("class B { [computeKey()]() {} }", 1); // computed member name (non-symbol)
    try expectDiagCount("x = new.target;", 1);
}

test "well-known symbol computed member is in subset" {
    // `[Symbol.iterator]` methods parse cleanly (keyed by a synthetic atom).
    try expectDiagCount("class C { [Symbol.iterator]() {} }", 0);
    try expectDiagCount("interface I { [Symbol.iterator](): Iterator<number>; }", 0);
}

test "jsx parses cleanly in tsx mode" {
    const cases = [_][]const u8{
        "const a = <div className=\"x\">hello</div>;",
        "const b = <Foo count={1} name=\"y\" />;",
        "const c = <><span>a</span>{x}</>;",
        "const d = <A.B prop=\"y\">child</A.B>;",
        "const e = <div {...props} id={f()} />;",
        "const g = <ul>{items.map(i => <li>{i}</li>)}</ul>;",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try parseOpts(arena.allocator(), src, true);
        if (tree.diagnostics.len != 0) {
            std.debug.print("--- unexpected JSX parse diag for: {s}\n", .{src});
            for (tree.diagnostics) |d| std.debug.print("  {s}\n", .{d.message()});
            return error.TestUnexpectedDiagnostics;
        }
    }
    // `<` stays a relational/type-argument operator in `.ts` (jsx off).
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try parseOpts(arena.allocator(), "const a = x < y;", false);
        try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    }
}

test "unsupported constructs still leave following code parsable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "type C<T> = T extends string ? 1 : 0;\nconst after: number = 1;";
    const tree = try parse(arena.allocator(), src);
    try testing.expect(tree.diagnostics.len >= 1);
    const got = try dumpSource(arena.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, got, "(var_decl_one const (declarator_full (identifier after) (identifier number) (number_literal 1)))") != null);
}

// --- error recovery ----------------------------------------------------------------

test "recovery: N distinct errors produce >= N diagnostics" {
    // Three separate statements, each with one syntax error.
    try expectDiagCount(
        \\let x = ;
        \\if (a { f(); }
        \\const = 3;
    , 3);
}

test "recovery: missing semicolons and parens" {
    try expectDiagCount("let a = 1 let b = 2", 1); // no ASI on same line
    try expectDiagCount("f(1, 2", 1);
    try expectDiagCount("while (x { y(); }", 1);
}

test "recovery: partial tree survives errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "const good1 = 1;\nlet bad = ;\nconst good2 = 2;";
    const tree = try parse(arena.allocator(), src);
    try testing.expect(tree.diagnostics.len >= 1);
    const got = try dumpSource(arena.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, got, "good1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "good2") != null);
    // Every diagnostic span stays inside the file.
    for (tree.diagnostics) |d| {
        try testing.expect(d.span.start <= src.len);
        try testing.expect(d.span.end <= src.len + 1);
        try testing.expect(d.span.start <= d.span.end);
    }
}

test "recovery: unterminated constructs at EOF" {
    try expectDiagCount("const s = \"abc", 1);
    try expectDiagCount("const t = `abc${x", 1);
    try expectDiagCount("const r = /abc", 1);
    try expectDiagCount("/* trailing", 1);
    try expectDiagCount("class C { m() {", 1);
    try expectDiagCount("if (x) {", 1);
}

test "recovery: junk between statements" {
    try expectDiagCount("let a = 1; ### ; let b = 2;", 1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "let a = 1; %%% let b = 2;";
    const tree = try parse(arena.allocator(), src);
    const got = try dumpSource(arena.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, got, "(identifier b)") != null);
    try testing.expect(tree.diagnostics.len >= 1);
}

// --- span checks --------------------------------------------------------------------

/// Recursively assert child spans nest within their parent's span and stay
/// inside the file.
fn checkSpansNested(tree: *const ast.Ast, src: []const u8, node: ast.Node, parent: ast.Span) !void {
    const sp = tree.span(src, node);
    try testing.expect(sp.start <= sp.end);
    try testing.expect(sp.end <= src.len);
    try testing.expect(sp.start >= parent.start and sp.end <= parent.end);
    var it = tree.childIterator(node);
    while (it.next()) |child| {
        try checkSpansNested(tree, src, child, sp);
    }
}

test "spans: derived spans nest within parents on a corpus sample" {
    const src =
        \\import type { Config } from "./config";
        \\import { load, save as persist } from "./io";
        \\
        \\export interface Shape { kind: "circle" | "square"; r?: number; }
        \\export type Result<T> = { ok: true; value: T } | { ok: false; error: string };
        \\
        \\export function area(s: Shape, scale: number = 1): number {
        \\  if (s.kind === "circle") { return 3.14 * s.r! ** 2 * scale; }
        \\  for (let i = 0; i < 3; i++) { scale += i; }
        \\  const [a, b = 2, ...rest] = [1, 2, 3];
        \\  const { kind: k, ...others } = s;
        \\  return a ?? b;
        \\}
        \\
        \\export class Circle<T> extends Base<T> implements Shape {
        \\  private static count = 0;
        \\  readonly kind = "circle";
        \\  constructor(public r: number) { super(); }
        \\  area(): number { return Math.PI * this.r ** 2; }
        \\}
        \\
        \\const f = async (x: number): Promise<number> => x * 2;
        \\const g = <T>(v: T) => `value: ${v} and ${`nested ${v}`}`;
        \\label: for (const key in { a: 1 }) { if (key) continue label; else break; }
        \\switch (f) { case g: break; default: f?.(1)!; }
        \\try { throw new Error("e"); } catch (e: unknown) { } finally { }
        \\let m = new Map<string, number[]>();
        \\m.get("k")?.[0]!;
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), src);
    if (tree.diagnostics.len != 0) {
        for (tree.diagnostics) |d| {
            std.debug.print("[{d}..{d}] {s}\n", .{ d.span.start, d.span.end, d.message() });
        }
        return error.TestUnexpectedDiagnostics;
    }
    const file_span: ast.Span = .{ .start = 0, .end = @intCast(src.len) };
    var it = tree.childIterator(0);
    while (it.next()) |child| {
        try checkSpansNested(&tree, src, child, file_span);
    }
}

test "memory: bytes per node <= 24 on a representative snippet" {
    const src =
        \\export interface Point { x: number; y: number; label?: string; }
        \\export type Shape = { kind: "circle"; r: number } | { kind: "square"; s: number };
        \\export function area(shape: Shape): number {
        \\  if (shape.kind === "circle") { return Math.PI * shape.r * shape.r; }
        \\  return shape.s * shape.s;
        \\}
        \\export class Registry<T> {
        \\  private items: T[] = [];
        \\  add(item: T): number { this.items.push(item); return this.items.length; }
        \\  get(index: number): T | undefined { return this.items[index]; }
        \\}
        \\const registry = new Registry<Shape>();
        \\registry.add({ kind: "circle", r: 1 });
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tree = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const bpn = tree.bytesPerNode();
    try testing.expect(bpn > 0);
    if (bpn > 24.0) {
        std.debug.print("bytes/node = {d:.2} (nodes {d}, node bytes {d}, extra bytes {d})\n", .{
            bpn, tree.nodes.len, tree.nodeBytes(), tree.extraBytes(),
        });
        return error.BytesPerNodeTooHigh;
    }
}

// --- stress: parser is total ---------------------------------------------------------

/// Oracle for arbitrary input: parsing terminates, the tree is bounded by
/// the token count (progress guarantee), the token stream ends with eof,
/// and node/extra references stay in bounds.
fn checkParserOnArbitraryBytes(alloc: Allocator, input: []const u8) !void {
    const tree = parse(alloc, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SourceTooLarge => unreachable,
    };
    const n_tokens = tree.tokens.len();
    try testing.expect(n_tokens >= 1);
    try testing.expectEqual(scanner.Tag.eof, tree.tokens.tag(n_tokens - 1));
    // Progress guarantee: node and extra growth are linear in tokens.
    try testing.expect(tree.nodes.len <= 8 * n_tokens + 8);
    try testing.expect(tree.extra_data.len <= 16 * n_tokens + 16);
    // All node main_tokens and diag spans are in bounds.
    for (0..tree.nodes.len) |i| {
        try testing.expect(tree.nodeMainToken(@intCast(i)) < n_tokens);
        const d = tree.nodeData(@intCast(i));
        if (tree.nodeTag(@intCast(i)) == .unsupported) {
            try testing.expect(d.rhs < n_tokens);
        }
    }
    for (tree.diagnostics) |d| {
        try testing.expect(d.span.start <= input.len);
        try testing.expect(d.span.end <= input.len + 1);
    }
}

test "stress: deterministic random byte soup terminates with diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x4d32_2026);
    const random = prng.random();
    var buf: [384]u8 = undefined;
    for (0..600) |_| {
        const n = random.uintLessThan(usize, buf.len + 1);
        random.bytes(buf[0..n]);
        try checkParserOnArbitraryBytes(arena.allocator(), buf[0..n]);
        _ = arena.reset(.retain_capacity);
    }
}

test "stress: token soup (valid tokens, random order) terminates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x70cc_2026);
    const random = prng.random();

    const vocab = [_][]const u8{
        "if",      "else",       "for",       "while",     "return",   "function", "class", "const",
        "let",     "var",        "interface", "type",      "import",   "export",   "new",   "typeof",
        "extends", "implements", "as",        "satisfies", "keyof",    "in",       "of",    "async",
        "await",   "yield",      "static",    "private",   "readonly", "this",     "super", "null",
        "true",    "false",      "x",         "y",         "foo",      "Bar",      "42",    "3.14",
        "\"s\"",   "`t`",        "`a${",      "}",         "{",        "}",        "(",     ")",
        "[",       "]",          ";",         ",",         ":",        "?",        ".",     "?.",
        "...",     "=>",         "=",         "+",         "-",        "*",        "/",     "%",
        "**",      "==",         "===",       "!=",        "<",        ">",        "<=",    ">=",
        "<<",      ">>",         ">>>",       "&&",        "||",       "??",       "!",     "~",
        "&",       "|",          "^",         "++",        "--",       "+=",       "??=",   "@",
        "#",       "\\",         "enum",      "namespace", "declare",  "abstract", "0x1n",  "/re/g",
    };

    var buf: [2048]u8 = undefined;
    for (0..400) |_| {
        var len: usize = 0;
        const count = random.uintLessThan(usize, 120);
        for (0..count) |_| {
            const w = vocab[random.uintLessThan(usize, vocab.len)];
            if (len + w.len + 1 > buf.len) break;
            @memcpy(buf[len..][0..w.len], w);
            len += w.len;
            buf[len] = if (random.uintLessThan(u8, 6) == 0) '\n' else ' ';
            len += 1;
        }
        try checkParserOnArbitraryBytes(arena.allocator(), buf[0..len]);
        _ = arena.reset(.retain_capacity);
    }
}

fn fuzzParserOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, '<', 3),
        .value(u8, '>', 3),
        .value(u8, '`', 3),
        .value(u8, '$', 2),
        .value(u8, '=', 3),
        .value(u8, ';', 3),
        .value(u8, '\n', 3),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try checkParserOnArbitraryBytes(arena.allocator(), source_buf[0..len]);
}

test "fuzz: parser on arbitrary bytes" {
    try testing.fuzz({}, fuzzParserOne, .{});
}

test "stress: pathological nesting terminates (deep parens, brackets, generics)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    // x = ((((((...))))));
    @memset(buf[0..], '(');
    @memcpy(buf[0..4], "x = ");
    try checkParserOnArbitraryBytes(arena.allocator(), buf[0..200]);
    _ = arena.reset(.retain_capacity);
    // Deep unclosed generics: type T = A<A<A<...
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(testing.allocator);
    try s.appendSlice(testing.allocator, "type T = ");
    for (0..100) |_| try s.appendSlice(testing.allocator, "A<");
    try checkParserOnArbitraryBytes(arena.allocator(), s.items);
    _ = arena.reset(.retain_capacity);
    // Deep template nesting.
    s.clearRetainingCapacity();
    try s.appendSlice(testing.allocator, "x = ");
    for (0..80) |_| try s.appendSlice(testing.allocator, "`${");
    try checkParserOnArbitraryBytes(arena.allocator(), s.items);
}

test "tokens: parser-consumed token stream matches rescan-corrected lexing" {
    // The parser's token array must reflect grammar-context rescans:
    // regexes, template middles/tails, and split `>`s.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "if (x) /re/.test(y); let m: Map<string, Array<number>> = z; x = `a${b}c`;";
    const tree = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    var found_regex = false;
    var found_middle_or_tail = false;
    var gt_count: usize = 0;
    for (0..tree.tokens.len()) |i| {
        switch (tree.tokens.tag(i)) {
            .regexp_literal => found_regex = true,
            .template_middle, .template_tail => found_middle_or_tail = true,
            .gt => gt_count += 1,
            .gt_gt, .gt_gt_gt => return error.UnsplitGtLeaked,
            else => {},
        }
    }
    try testing.expect(found_regex);
    try testing.expect(found_middle_or_tail);
    try testing.expectEqual(@as(usize, 2), gt_count); // `>>` split into two `>`s
}
