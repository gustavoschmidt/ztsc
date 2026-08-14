//! Recursive-descent TypeScript parser producing the data-oriented AST.
//!
//! Design decisions:
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
//! - **Generic-call / instantiation-expression heuristic**: `expr < ...` is
//!   treated as type arguments only if the `<...>` parses as a type list AND
//!   the token after the closing `>` may follow a type-argument list in
//!   expression position (`canFollowTypeArgsInExpr`, mirroring tsc's
//!   `canFollowTypeArgumentsInExpression`). `(` and a template head keep the
//!   type-argument reading outright — so `f<T>(x)` is a generic call and
//!   `a < b > (c)` is one too, *exactly like tsc*; otherwise the reading wins
//!   only when the next token starts no expression (`f<T>;`, `f<T>,`,
//!   `f<T>)`), i.e. an instantiation expression, which is what `<` `>` `+`
//!   `-` and any expression-starting token are excluded for.
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
const directives = @import("directives.zig");
const literals = @import("literals.zig");

const TokTag = scanner.Tag;
const Token = scanner.Token;
const Node = ast.Node;
const TokenIndex = ast.TokenIndex;
const null_node = ast.null_node;
const Code = diagnostics.Code;

/// Internal error set of the node-building helpers. NOT `parse`'s error set,
/// which also carries `SourceTooLarge`.
const Error = error{OutOfMemory};
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

/// A `.d.ts`/`.d.mts`/`.d.cts` declaration file is an entirely ambient context:
/// every declaration is implicitly `declare`, so namespace members are visible
/// as `N.member` without an explicit `export` (tsc's ambient-namespace rule).
/// One implementation, in the path utilities; re-exported here because the
/// front end's callers reach for it as `parser.isDeclarationPath`.
pub const isDeclarationPath = @import("../link/paths.zig").isDeclarationPath;

/// Everything the tsconfig can change about the GRAMMAR itself. Kept to the
/// options that decide whether a byte sequence parses at all, so a file's
/// tokens/nodes stay a pure function of its text plus this struct.
pub const Opts = struct {
    /// JSX enabled (`.tsx`/`.jsx`): `<` in expression position starts an
    /// element rather than a type assertion.
    jsx: bool = false,
    /// `compilerOptions.experimentalDecorators`: the legacy decorator dialect,
    /// whose grammar allows decorators on PARAMETERS. Off (the standard TC39
    /// dialect) a parameter decorator is TS1206. See `tsconfig.Config`.
    experimental_decorators: bool = false,
    /// The file is a declaration file (`.d.ts`/`.d.mts`/`.d.cts`), which is
    /// an ambient context from its first token: every declaration in it
    /// behaves as if written `declare`. See `Parser.ambient`.
    dts: bool = false,
    /// Backing allocator for the transient parse arena (see `parseOpts`).
    /// Null — the default — uses `std.heap.page_allocator`, which is what
    /// every caller wants: the arena is freed before `parseOpts` returns, so
    /// going straight to the OS avoids churning a shared allocator from many
    /// parse threads at once. Set it to hand the parse its own memory (tests,
    /// a failing allocator, an allocation budget).
    scratch: ?std.mem.Allocator = null,
};

pub fn parse(gpa: Allocator, src: []const u8) error{ OutOfMemory, SourceTooLarge }!ast.Ast {
    return parseOpts(gpa, src, .{});
}

pub fn parseOpts(gpa: Allocator, src: []const u8, opts: Opts) error{ OutOfMemory, SourceTooLarge }!ast.Ast {
    if (src.len > scanner.max_source_len) return error.SourceTooLarge;
    // Build the AST in a transient scratch arena so the growable lists'
    // doubling reallocs and their final tail slack are freed here, then
    // seal exact-size copies into `gpa` (the retained per-file arena). The
    // AST is pointer-free u32 data, so a flat copy is self-consistent.
    var scratch = std.heap.ArenaAllocator.init(opts.scratch orelse std.heap.page_allocator);
    defer scratch.deinit();
    var p: Parser = .{
        .gpa = scratch.allocator(),
        .out = gpa,
        .src = src,
        .scn = scanner.Scanner.init(src),
        .jsx = opts.jsx,
        .experimental_decorators = opts.experimental_decorators,
        .ambient = opts.dts,
    };
    p.parseRoot() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Backtrack => unreachable, // spec == 0 at top level
    };
    return p.sealInto(gpa);
}

const max_la = 5; // `[a.b]` computed-key gate peeks `[ a . b ]` = 5 tokens

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
    /// Legacy (`experimentalDecorators`) grammar: parameter decorators are
    /// legal. See `Opts.experimental_decorators`.
    experimental_decorators: bool = false,

    /// AMBIENT CONTEXT (tsc's `NodeFlags.Ambient`, propagated by
    /// `setContextFlag` while parsing): true inside a `declare` declaration,
    /// inside a `declare namespace`/`declare global`/`declare module "…"`
    /// body, and throughout a `.d.ts` file. Saved/restored around each body
    /// like every other parse context flag — a plain `namespace` nested in an
    /// ambient one stays ambient, which is what tsc means by the flag.
    /// Recorded on the nodes that need it (`parseDeclarator`), because a
    /// declarator has no link back to the statement that carries `declare`.
    ambient: bool = false,

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

    /// Start offset of the last SYNTACTIC diagnostic recorded, for tsc's
    /// one-per-position rule (`addDiag`). Not derivable from `diags` — the last
    /// entry there may be a grammar-class one, which does not participate.
    last_syntactic_start: ?u32 = null,

    /// Nesting depth of class bodies, for TS1213 — tsc's `getContainingClass`.
    /// A class body is strict whatever the file is, and tsc says so in its own
    /// wording, so the choice between TS1212 and TS1213 is this counter.
    class_depth: u32 = 0,
    /// Whether the file has top-level module syntax (`import`/`export`), tsc's
    /// `externalModuleIndicator`, for TS1214. Only known once the whole file is
    /// parsed, so the diagnostics are recorded as TS1212 and rewritten in
    /// `sealInto`.
    saw_module_syntax: bool = false,

    /// Copy the parsed lists into `out` at exact size. `out` is an arena, so
    /// each `dupe`/`setCapacity` is a single tight allocation with no slack
    /// and no stranded intermediate buffers (those stay in the scratch arena
    /// and are freed when `parse` returns).
    fn sealInto(p: *Parser, out: Allocator) Error!ast.Ast {
        // TS1214: a strict-reserved word in an external module gets tsc's
        // module-specific wording. Whether the file IS one is only settled at
        // EOF (any top-level `import`/`export`), so the reports were recorded
        // under TS1212 and are relabelled here. Not the class ones — a class body
        // is strict for a reason of its own and tsc prefers to say that.
        if (p.saw_module_syntax) {
            for (p.diags.items) |*d| {
                d.code = switch (d.code) {
                    .strict_reserved_word => .strict_reserved_word_in_module,
                    // TS1100 -> TS1215, the same relabel for the
                    // `eval`/`arguments` family (tsc picks both wordings with
                    // one `getStrictMode…Message` helper).
                    .eval_in_strict => .eval_in_module,
                    .arguments_in_strict => .arguments_in_module,
                    else => d.code,
                };
            }
        }
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
            // Comment directives are scanned from the raw bytes rather than
            // from trivia the scanner has already discarded. The scan is gated
            // on the file containing `@ts-` at all, so this is one vectorised
            // sweep for a file without directives, and it runs on the same
            // (parallel) worker as the parse itself.
            .comment_directives = try directives.scan(out, p.src),
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
        try p.checkLiteral(t);
    }

    /// The literal-TEXT grammar rules (legacy octal, bad escapes, an empty radix
    /// — `literals.zig`). tsc reports these from its scanner; ztsc's scanner is a
    /// pure tokenizer, so they run here, on the one funnel every consumed token
    /// passes through. Speculation is safe: `restore` truncates `diags`, so a
    /// token consumed twice is diagnosed once.
    ///
    /// Both guards are a single byte test, so a literal that has nothing wrong
    /// with it — which is nearly all of them — costs one comparison.
    fn checkLiteral(p: *Parser, t: Token) Error!void {
        switch (t.tag) {
            .numeric_literal, .bigint_literal => {
                const text = p.tokenText(t);
                if (literals.checkNumeric(text, t.start)) |f| {
                    try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                }
                // TS1351: `3a`. Reported at the identifier, which is exactly
                // where the parser's own "';' expected" would land, so the
                // one-per-position rule keeps tsc's answer and drops ours.
                if (literals.identifierAfterNumeric(p.src, t.end)) |f| {
                    try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                }
            },
            .string_literal => {
                const text = p.tokenText(t);
                if (!literals.EscapeWalk.any(text)) return;
                var w: literals.EscapeWalk = .init(text, t.start);
                while (w.next()) |f| {
                    try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                }
            },
            else => {},
        }
    }

    fn tokenText(p: *const Parser, t: Token) []const u8 {
        const end = @min(if (t.end > t.start) t.end else t.start, @as(u32, @intCast(p.src.len)));
        return p.src[@min(t.start, end)..end];
    }

    /// Source text of an already-consumed token, by index.
    fn tokenTextAt(p: *const Parser, tok: u32) []const u8 {
        const start = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
        const end = @min(scanner.tokenEnd(p.src, p.tok_tags.items[tok], start), @as(u32, @intCast(p.src.len)));
        return p.src[@min(start, end)..end];
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

    /// Append a diagnostic, applying tsc's one-per-position rule for the
    /// syntactic ones:
    ///
    ///     // Don't report another error if it would just be at the same
    ///     // position as the last error.
    ///     const lastError = lastOrUndefined(parseDiagnostics);
    ///     if (!lastError || start !== lastError.start) { ... push ... }
    ///
    /// A recovering parser reaches the same token from several directions and
    /// has something to say each time ("';' expected", then "Expression
    /// expected", then "unexpected token"); tsc keeps the first and drops the
    /// rest, and a report that keeps them all is one right key plus several
    /// wrong ones. The comparison is against the last SYNTACTIC diagnostic
    /// only, because the grammar-class ones do not live in tsc's
    /// `parseDiagnostics` and so neither suppress nor are suppressed by these.
    fn addDiag(p: *Parser, code: Code, span: ast.Diagnostic) Error!void {
        if (code.class() == .syntactic) {
            if (p.last_syntactic_start) |last| {
                if (last == span.span.start) return;
            }
            p.last_syntactic_start = span.span.start;
        }
        try p.diags.append(p.gpa, span);
    }

    fn errAtCur(p: *Parser, code: Code) Error!void {
        const t = p.cur();
        const end = if (t.end > t.start) t.end else t.start + 1;
        try p.addDiag(code, .{
            .code = code,
            .span = .{ .start = t.start, .end = @min(end, @as(u32, @intCast(p.src.len)) + 1) },
        });
    }

    /// Report the current no-token-starts-here token. tsc's scanner separates
    /// three answers here, and so does ztsc's:
    ///
    ///   - `#!` outside the first line: TS18026, reported over the two bytes;
    ///   - a byte that begins no UTF-8 sequence: TS1490, reported ONCE at the
    ///     start of the FILE (not at the byte), because tsc decodes up front
    ///     and its scanner blames the file, then stops — which is why the token
    ///     covers the whole remainder and the next token is `eof`;
    ///   - anything else: TS1127 over the one byte.
    fn errAtJunkToken(p: *Parser) Error!void {
        switch (p.curTag()) {
            .hash_bang => try p.errAtCur(.shebang_not_at_start),
            .binary_content => try p.addDiag(.file_appears_binary, .{
                .code = .file_appears_binary,
                .span = .{ .start = 0, .end = 0 },
            }),
            else => try p.errAtCur(.unexpected_character),
        }
    }

    /// Report at the END of the current token, zero-width. tsc's scanner calls
    /// `error(message)` with no position for the unterminated STRING, TEMPLATE
    /// and block-COMMENT cases, and that defaults to the scanner's `pos` — one
    /// past the last byte consumed, not the opening quote. Measured against
    /// tsgo: `var a = "abc` answers at column 13, `` `abc<nl>zz<nl> `` at the
    /// end of the file. The unterminated REGEX diagnostic passes `tokenStart`
    /// explicitly and so stays on the opening `/`; it keeps using `errAtCur`.
    fn errAtCurEnd(p: *Parser, code: Code) Error!void {
        const t = p.cur();
        const at = @min(@max(t.end, t.start), @as(u32, @intCast(p.src.len)));
        try p.addDiag(code, .{ .code = code, .span = .{ .start = at, .end = at } });
    }

    fn errAtToken(p: *Parser, code: Code, tok: u32) Error!void {
        const start = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
        const end = scanner.tokenEnd(p.src, p.tok_tags.items[tok], start);
        try p.addDiag(code, .{
            .code = code,
            .span = .{ .start = start, .end = if (end > start) end else start + 1 },
        });
    }

    /// A diagnostic spanning a whole consumed token run, `from`..`to`
    /// inclusive — the shape tsc's `parseErrorAt(node.pos, node.end)` gives a
    /// grammar error blamed on an entire expression rather than one token.
    fn errAtRange(p: *Parser, code: Code, from: u32, to: u32) Error!void {
        const start = p.tok_starts.items[from] & scanner.Tokens.start_mask;
        const to_start = p.tok_starts.items[to] & scanner.Tokens.start_mask;
        const end = scanner.tokenEnd(p.src, p.tok_tags.items[to], to_start);
        try p.addDiag(code, .{
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

    /// In JSX name position (tag or attribute name), extend the current
    /// identifier-like token over any immediately-following `-name` runs so
    /// `data-foo`, `aria-label`, and custom-element tags `<my-widget>` lex as
    /// one `.jsx_name` token. A no-op unless a `-` abuts the current token, so
    /// ordinary `a-b` subtraction (only ever seen in expression position) is
    /// untouched. Drops stale lookahead scanned past the merged name.
    fn rescanJsxName(p: *Parser) void {
        p.fill(0);
        const t = p.la[0];
        if (!isNameLike(t.tag)) return;
        const norm_end = scanner.tokenEnd(p.src, t.tag, t.start);
        // Only a `-` (`data-foo`) or a `:` (`svg:path`) can extend a JSX name;
        // anything else means the ordinary token already covers it.
        if (norm_end >= p.src.len or (p.src[norm_end] != '-' and p.src[norm_end] != ':')) return;
        const end = scanner.scanJsxName(p.src, t.start);
        // A merge may only ever EXTEND the token. Anything else rewinds
        // `p.scn.index` to at or before where this token already started, and
        // the parser re-reads it forever instead of making progress. There is
        // no input for which shortening is the right answer, so leaving the
        // token alone is both the safe and the correct fallback.
        if (end <= norm_end) return;
        p.la[0] = .{ .tag = .jsx_name, .start = t.start, .end = end, .newline_before = t.newline_before };
        p.scn.index = end;
        p.la_len = 1;
    }

    /// In JSX attribute-value position, re-lex a leading quote as a JSX
    /// attribute string: it runs to the matching quote, so a raw line break
    /// is content (`defaults="line one\nline two"`) and `\` is a literal
    /// byte, not an escape. Normal scanning stops such a string at the
    /// newline and reports it unterminated. Drops stale lookahead scanned
    /// past the (now longer) string.
    fn rescanJsxAttributeString(p: *Parser) void {
        p.fill(0);
        const t = p.la[0];
        switch (t.tag) {
            .string_literal, .unterminated_string_literal => {},
            else => return,
        }
        const end = scanner.scanJsxString(p.src, t.start) orelse return;
        p.la[0] = .{ .tag = .jsx_string, .start = t.start, .end = end, .newline_before = t.newline_before };
        p.scn.index = end;
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
        last_syntactic_start: ?u32,
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
            .last_syntactic_start = p.last_syntactic_start,
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
        p.last_syntactic_start = s.last_syntactic_start;
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
    /// consumed`, with the subset-boundary diagnostic. The covered construct
    /// is classified from its first token (census) and stored in `lhs`.
    fn unsupportedFrom(p: *Parser, start_tok: u32) PE!Node {
        return p.unsupportedKindFrom(start_tok, p.classifyUnsupported(start_tok));
    }

    /// `unsupportedFrom` with an explicit construct kind — for the sites where
    /// the construct is not inferable from its first token (a conditional type
    /// starts at an ordinary type token, a named tuple member at its name).
    fn unsupportedKindFrom(p: *Parser, start_tok: u32, kind: ast.UnsupportedKind) PE!Node {
        if (p.spec > 0) return error.Backtrack;
        const last = @max(start_tok, p.lastIdx());
        try p.errAtToken(.unsupported_syntax, start_tok);
        return p.addNode(.{ .tag = .unsupported, .main_token = start_tok, .data = .{ .lhs = @intFromEnum(kind), .rhs = last } });
    }

    /// Classify an out-of-subset construct from its first token, for the
    /// census histogram. Coarse where two constructs share a leading token
    /// (a construct signature `new (...)` and a constructor type both read as
    /// `constructor type`); the callers that need a finer answer pass it
    /// explicitly via `unsupportedKindFrom`.
    fn classifyUnsupported(p: *Parser, start_tok: u32) ast.UnsupportedKind {
        const n = p.tok_tags.items.len;
        const t1: TokTag = if (start_tok + 1 < n) p.tokTagAt(start_tok + 1) else .eof;
        const t2: TokTag = if (start_tok + 2 < n) p.tokTagAt(start_tok + 2) else .eof;
        const t3: TokTag = if (start_tok + 3 < n) p.tokTagAt(start_tok + 3) else .eof;
        return switch (p.tokTagAt(start_tok)) {
            .at => .decorator,
            .keyword_namespace, .keyword_module => .namespace_dotted,
            .keyword_declare => .ambient_declare,
            .keyword_static => .static_block,
            .keyword_export => .export_equals,
            .keyword_unique => .unique_symbol,
            .keyword_infer => .infer_type,
            .keyword_typeof => .import_type,
            .template_head, .no_substitution_template_literal => .template_literal_type,
            .l_bracket => .computed_member,
            .l_paren, .lt => .call_or_construct_signature,
            .keyword_new => if (t1 == .dot) .new_target else .constructor_type,
            .keyword_import => if (isIdentLike(t1) and t2 == .eq) .import_equals else .import_type,
            .l_brace => if (t1 == .l_bracket and isIdentLike(t2) and t3 == .keyword_in) .mapped_type else .unknown,
            else => .unknown,
        };
    }

    // --- classification helpers ------------------------------------------

    /// Tokens acceptable as an identifier/binding name (ztsc is
    /// always-strict, but strict-reserved words are accepted at parse level
    /// and left to the binder — documented deviation to keep recovery sane).
    fn isIdentLike(tag: TokTag) bool {
        return tag == .identifier or tag.isContextualKeyword() or tag.isStrictReservedKeyword();
    }

    /// A ModuleExportName (the name/alias position of an import or export
    /// specifier): any IdentifierName — i.e. a plain identifier OR any reserved
    /// word, notably `default` in `export { default as x } from "m"` and
    /// `export { x as default }` — or a string literal.
    fn isModuleExportName(tag: TokTag) bool {
        return tag == .identifier or tag.isKeyword() or tag == .string_literal;
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

    /// tsc's `isStartOfStatement`, the gate on its statement-list loops: a
    /// token that answers false is NOT handed to `parseStatement` at all —
    /// `parseList` reports one "Declaration or statement expected." (TS1128)
    /// and skips exactly that token. Without the gate a recovering parser
    /// instead tries to read an expression statement out of a `}` or a `,` and
    /// answers with a cascade of "Expression expected"/"';' expected" that tsc
    /// never produces.
    ///
    /// Deliberately CONSERVATIVE where tsc looks ahead: `const`, `export`,
    /// `import` and the modifier words go through tsc's `isStartOfDeclaration`
    /// lookahead, and are answered `true` here unconditionally. A false `true`
    /// only keeps ztsc's existing recovery for that token; a false `false`
    /// would manufacture a TS1128 tsc does not report.
    fn atStartOfStatement(p: *Parser) bool {
        return switch (p.curTag()) {
            .at,
            .semicolon,
            .l_brace,
            .keyword_var,
            .keyword_let,
            .keyword_using,
            .keyword_function,
            .keyword_class,
            .keyword_enum,
            .keyword_if,
            .keyword_do,
            .keyword_while,
            .keyword_for,
            .keyword_continue,
            .keyword_break,
            .keyword_return,
            .keyword_with,
            .keyword_switch,
            .keyword_throw,
            .keyword_try,
            .keyword_debugger,
            // `catch`/`finally` do not start a statement, but tsc says they do
            // here so that a stray one is parsed and complained about later.
            .keyword_catch,
            .keyword_finally,
            // The lookahead group (see the doc comment).
            .keyword_const,
            .keyword_export,
            .keyword_import,
            .keyword_async,
            .keyword_declare,
            .keyword_interface,
            .keyword_module,
            .keyword_namespace,
            .keyword_type,
            .keyword_global,
            .keyword_accessor,
            .keyword_public,
            .keyword_private,
            .keyword_protected,
            .keyword_static,
            .keyword_readonly,
            .keyword_abstract,
            // An unterminated block comment is TRIVIA to tsc: its scanner
            // reports TS1010 and hands the parser EOF, so nothing lands here.
            // ztsc keeps it as a token that spans to end of file; letting
            // `parseStatement` own it reproduces tsc's single TS1010, whereas
            // treating it as junk would add a TS1128 tsc never reports.
            .unterminated_comment,
            => true,
            // tsc's `isStartOfExpression`, including its error tolerance: the
            // start of a BINARY operator counts, so `* x;` is parsed as an
            // expression statement with a missing left operand (TS1109) rather
            // than skipped.
            else => |tag| canStartExpression(tag) or binaryPrec(tag, false) != 0,
        };
    }

    /// The diagnostic tsc's `parseList` reports for a token that starts no list
    /// element, for the statement-list contexts. A junk token gets its scanner
    /// diagnostic FIRST, so that the one-per-position rule in `addDiag` drops
    /// the TS1128 that would otherwise land on the same character — which is
    /// exactly what tsc's `parseErrorAtPosition` does.
    fn errNotAStatement(p: *Parser, code: Code) PE!void {
        if (p.spec > 0) return error.Backtrack;
        switch (p.curTag()) {
            .unknown, .hash_bang, .binary_content => try p.errAtJunkToken(),
            else => {},
        }
        try p.errAtCur(code);
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
        try p.parseStatementList(top, .eof, false);
        const range = try p.scratchToSpan(top);
        p.nodes.items(.data)[0] = .{ .lhs = range.start, .rhs = range.end };

        // Seal the token stream with the eof token.
        const t = p.cur();
        std.debug.assert(t.tag == .eof);
        try p.appendTok(t);
    }

    /// Parse statements until `terminator` (or eof), pushing them on
    /// scratch. Guarantees progress on every iteration.
    fn parseStatementList(p: *Parser, top: usize, terminator: TokTag, ambient_reported: bool) PE!void {
        _ = top;
        // TS1036, tsc's `checkGrammarStatementInAmbientContext`: an ambient
        // context declares, it does not execute. tsc reports it ONCE per
        // containing block ("we only want to really report an error once to
        // prevent noisiness"), which is exactly one flag per call of this
        // function — every block, module block and source file gets its own.
        var reported_ambient_stmt = ambient_reported;
        while (p.curTag() != terminator and p.curTag() != .eof) {
            // tsc's `parseList` gate: a token that starts no statement is
            // reported and skipped, never parsed.
            if (!p.atStartOfStatement()) {
                try p.errNotAStatement(if (terminator == .eof and p.curTag() == .keyword_default)
                    .expected_export
                else
                    .expected_declaration_or_statement);
                _ = try p.bump();
                continue;
            }
            const before = p.curIdx();
            const stmt = try p.parseStatement();
            try p.pushScratch(stmt);
            // `p.curIdx() > before` is load-bearing, not just an optimization: a
            // statement that consumed NOTHING leaves `before` one past the end of
            // the token array, and the report indexes it. (Found by a `.d.ts`
            // holding nothing but `with (foo) {}`, which ztsc parses to no
            // tokens at all — it crashed the whole run.)
            if (p.ambient and !reported_ambient_stmt and p.spec == 0 and
                p.curIdx() > before and stmt != null_node and
                isExecutableStatement(p.nodes.items(.tag)[stmt]))
            {
                try p.errAtToken(.statement_not_allowed_in_ambient, before);
                reported_ambient_stmt = true;
            }
            if (p.curIdx() == before) {
                // The statement consumed nothing: force progress, then
                // synchronize at a statement boundary.
                try p.errAtCur(.unexpected_token);
                _ = try p.bump();
                p.synchronize();
            }
        }
    }

    /// A statement that RUNS, as opposed to one that only declares. The
    /// complement of tsc's ambient-context allowance: `var`/`let`/`const`,
    /// `function`, `class`, `interface`, `type`, `enum`, `namespace`/`module`,
    /// every import and export form, and an empty statement are all legal in an
    /// ambient context; everything else is TS1036.
    fn isExecutableStatement(tag: ast.Tag) bool {
        return switch (tag) {
            .block,
            .expr_stmt,
            .if_stmt,
            .if_else_stmt,
            .while_stmt,
            .do_stmt,
            .for_stmt,
            .for_in_stmt,
            .for_of_stmt,
            .switch_stmt,
            .try_stmt,
            .throw_stmt,
            .return_stmt,
            .break_stmt,
            .continue_stmt,
            .labeled_stmt,
            .debugger_stmt,
            // A stray `;` counts: tsc reports TS1036 for `declare namespace N { ; }`.
            .empty_stmt,
            => true,
            else => false,
        };
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
                        // `declare` leaves no trace on the variable statement
                        // node itself (it starts at `var`/`let`/`const`), so
                        // the ambient context is what carries the modifier to
                        // the declarators. See `Parser.ambient`.
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseVarStatement();
                    },
                    .keyword_function => {
                        _ = try p.bump();
                        // `declare` puts the whole declaration in an ambient
                        // context, tsc's `NodeFlags.Ambient` — which is what
                        // makes a body here TS1183. Only the var arm below used
                        // to set it, because only declarators needed it.
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseFunctionDecl(ast.Flags.declare, false);
                    },
                    .keyword_async => {
                        _ = try p.bump();
                        _ = try p.bump();
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseFunctionDecl(ast.Flags.declare | ast.Flags.async, false);
                    },
                    .keyword_class => {
                        _ = try p.bump();
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseClassDecl(ast.Flags.declare);
                    },
                    .keyword_abstract => {
                        _ = try p.bump();
                        _ = try p.bump();
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
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
                        // `declare namespace N { ... }` (ambient, identifier
                        // name) or `declare module "spec" { ... }` (ambient
                        // module / augmentation). Both in subset.
                        _ = try p.bump(); // `declare`
                        if (isIdentLike(p.peekTag(1)) and !p.peekNewline(1)) {
                            return p.parseNamespaceDecl(ast.Flags.declare);
                        }
                        if (p.peekTag(1) == .string_literal and !p.peekNewline(1)) {
                            return p.parseAmbientModule();
                        }
                        const start = p.curIdx();
                        _ = try p.bump();
                        p.skipUnsupportedBlockish();
                        return p.unsupportedFrom(start);
                    },
                    .keyword_global => {
                        // `declare global { ... }` — global-scope augmentation
                        // In subset: a block whose members merge into
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
            .keyword_global => {
                // Bare `global { ... }` augmentation (no leading `declare`), as
                // used inside ambient module blocks in real `@types/node`
                // (`declare module "buffer" { global { var Buffer … } }`). Only
                // when directly followed by `{`; otherwise `global` is an
                // ordinary contextual-keyword identifier (`global.foo`, a label).
                if (p.peekTag(1) == .l_brace) return p.parseGlobalAugmentation();
                if (p.peekTag(1) == .colon) {
                    const label = try p.bump();
                    _ = try p.bump(); // ':'
                    const body = try p.parseStatement();
                    return p.addNode(.{ .tag = .labeled_stmt, .main_token = label, .data = .{ .lhs = body, .rhs = 0 } });
                }
                return p.parseExpressionStatement();
            },
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
            .at => return p.parseDecorator(),
            .unterminated_comment => {
                try p.errAtCurEnd(.unterminated_comment);
                const tok = try p.bump();
                return p.addNode(.{ .tag = .error_node, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            .unknown, .hash_bang, .binary_content => {
                try p.errAtJunkToken();
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
        return p.parseBlockAs(.plain);
    }

    /// The body of a function, method, accessor, constructor or arrow. Same
    /// grammar as `parseBlock`; the distinction is TS1183 — tsc's
    /// `checkGrammarStatementInAmbientContext` answers "an implementation cannot
    /// be declared in ambient contexts" for a block whose parent is function-like
    /// and "statements are not allowed" for one whose parent is a block, module
    /// block or source file, and reports either on the block's first token.
    fn parseFunctionBody(p: *Parser) PE!Node {
        return p.parseBlockAs(.function_body);
    }

    const BlockRole = enum { plain, function_body };

    fn parseBlockAs(p: *Parser, role: BlockRole) PE!Node {
        const at_brace = p.curTag() == .l_brace;
        const l_brace = try p.expect(.l_brace, .expected_l_brace);
        // An ambient body reports once, on the `{`, and suppresses the TS1036
        // its own statements would otherwise each be a candidate for — tsc sets
        // the "already reported" bit on the block, which is the very object the
        // inner statements consult.
        const ambient_body = role == .function_body and p.ambient and at_brace and p.spec == 0;
        if (ambient_body) try p.errAtToken(.implementation_not_allowed_in_ambient, l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.parseStatementList(top, .r_brace, ambient_body);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .block, .main_token = l_brace, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseExpressionStatement(p: *Parser) PE!Node {
        const expr = try p.parseExpression(.{});
        try p.expectSemicolonAfterExpression(expr);
        return p.addNode(.{ .tag = .expr_stmt, .main_token = p.nodes.items(.main_token)[expr], .data = .{ .lhs = expr, .rhs = 0 } });
    }

    /// `expectSemicolon` for an EXPRESSION STATEMENT, which tsc words
    /// differently: `parseErrorForMissingSemicolonAfter` blames the expression
    /// rather than the token after it when the whole expression is a bare
    /// identifier, because `foo bar` is much more likely a misspelled keyword
    /// than a forgotten semicolon. Measured against tsgo: `zzz qqq;` answers
    /// TS1434 over `zzz`, while `"a" b;` and `f() g;` answer TS1005 at the
    /// second token. `declare` is silent (a `declare` that failed to parse has
    /// already reported), and a token the scanner already complained about is
    /// left to that complaint.
    ///
    /// tsc additionally offers a spelling suggestion (TS1435) when the word is
    /// close to a keyword; ztsc reports the plain TS1434 there, which is the
    /// same one-wrong-key cost as the TS1005 it replaces.
    fn expectSemicolonAfterExpression(p: *Parser, expr: Node) PE!void {
        switch (p.curTag()) {
            .semicolon => _ = try p.bump(),
            .r_brace, .eof => {},
            else => {
                if (p.nlBefore()) return;
                if (p.spec > 0) return error.Backtrack;
                if (expr != null_node and p.nodes.items(.tag)[expr] == .identifier and
                    p.curTag() != .unknown and p.curTag() != .binary_content)
                {
                    const tok = p.nodes.items(.main_token)[expr];
                    const at = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
                    // Only when the word's own position is still free. If a
                    // diagnostic already sits there, the one-per-position rule
                    // would drop the TS1434 and this statement would go
                    // unreported — while tsc, which reached that state through a
                    // different recovery (a missing `,` in a declarator list, an
                    // `import X` it turns into `import X =`), still answers at
                    // the NEXT token. Keeping ztsc's "';' expected" there is the
                    // closer answer of the two.
                    if (p.last_syntactic_start != at) {
                        if (p.tokTagAt(tok) != .keyword_declare) {
                            try p.errAtToken(.unexpected_keyword_or_identifier, tok);
                        }
                        return;
                    }
                }
                try p.errAtCur(.expected_semicolon);
            },
        }
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
        // An AMBIENT declarator (`declare var x: T`, or any `var`/`let` in a
        // `.d.ts` / `declare namespace` / `declare global` body) records the
        // context on itself: the variable statement keeps no `declare` bit
        // (it starts at `var`), and a declarator has no parent link to look
        // for one. Read as "assigned by definition" — tsc's
        // `NodeFlags.Ambient` arm of `assumeInitialized`.
        //
        // Deliberately confined to the long form, so the bit never changes
        // which node tag a declarator gets: an ambient declarator with
        // neither annotation nor `!` is typed from its initializer or is
        // `any`, and both of those are already exempt from every rule that
        // reads the bit. Widening the long form to cover them would retag
        // every `export const x = "lit"` in every `.d.ts`, which downstream
        // reads as "annotated" (`constEnumString`, `symExplicitlyTyped`).
        if (p.ambient) flags |= ast.Flags.declare;
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
        var is_await: u32 = 0;
        if (p.curTag() == .keyword_await) {
            _ = try p.bump(); // `for await` — recorded for the checker
            is_await = 1;
        }
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
                const extra = try p.addExtra(ast.ForInOf{ .left = init, .right = right, .is_await = is_await });
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
            if (!p.atStartOfStatement()) {
                try p.errNotAStatement(.expected_statement);
                _ = try p.bump();
                continue;
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
    /// The name is required for a declaration, optional for a function
    /// expression and for `export default function (…) {…}` — the one
    /// declaration form the grammar lets go unnamed.
    fn parseFunctionDecl(p: *Parser, flags_in: u32, is_expr: bool) PE!Node {
        return p.parseFunctionDeclNamed(flags_in, is_expr, is_expr);
    }

    fn parseFunctionDeclNamed(p: *Parser, flags_in: u32, is_expr: bool, anon_ok: bool) PE!Node {
        var flags = flags_in;
        const kw = try p.bump(); // `function`
        if (try p.eat(.asterisk) != null) flags |= ast.Flags.generator;
        var name_tok: u32 = 0;
        if (isIdentLike(p.curTag())) {
            try p.checkStrictReserved();
            name_tok = try p.bump();
            try p.checkEvalOrArguments(name_tok);
        } else if (!anon_ok) {
            try p.fail(.expected_identifier);
        }
        const proto = try p.parseFnProtoRest(flags, name_tok);
        var body: Node = null_node;
        if (p.curTag() == .l_brace) {
            body = try p.parseFunctionBody();
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
        if (p.atLt()) tp = try p.parseTypeParams(.callable);
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

    /// Can `tag` begin a type parameter's name (or another variance modifier)?
    /// Decides whether a preceding contextual `out` is a MODIFIER rather than
    /// the parameter's own name. A fully reserved word (`extends`) is not
    /// ident-like, so `<out extends X>` keeps parsing as a parameter named
    /// `out` — tsc reports TS1359 there instead, a deliberate under-report on
    /// a shape no real code writes.
    fn typeParamNameFollows(tag: TokTag) bool {
        return isIdentLike(tag) or tag == .keyword_in or tag == .keyword_out or tag == .keyword_const;
    }

    /// Which modifiers a type-parameter list's OWNER admits. Declaration-site
    /// variance (`in`/`out`, TS 4.7) belongs to the three forms that declare a
    /// named generic type — class, interface, type alias; `const` (TS 5.0)
    /// belongs to the forms that have a CALL SITE to infer from — function,
    /// method, class (its constructor). Only a class admits both; the two
    /// remaining forms admit exactly one each, which is why this is one enum
    /// rather than two flags.
    const TypeParamOwner = enum {
        /// Function, method, arrow, function/constructor type: `const` only.
        callable,
        /// Class: both.
        class,
        /// Interface, type alias: `in`/`out` only.
        type_decl,

        fn allowsVariance(o: TypeParamOwner) bool {
            return o != .callable;
        }
        fn allowsConst(o: TypeParamOwner) bool {
            return o != .type_decl;
        }
    };

    fn parseTypeParams(p: *Parser, owner: TypeParamOwner) PE!ast.SubRange {
        _ = try p.expectLt();
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .gt and p.curTag() != .eof) {
            const before = p.curIdx();
            // Leading modifiers: `const` (TS 5.0) and the `in`/`out` variance
            // annotations (TS 4.7). Consumed and dropped — the CHECKER reads
            // them back off the tokens before the name (see
            // `declaredVarianceOfTypeParam`; the binder does the same for
            // `const`, into `SymbolFlags.const_type_param`), so a modifier
            // costs no node, symbol, or type-store memory.
            //
            // `out` is a CONTEXTUAL keyword, so unlike `const` and `in` it is
            // ident-like: it is the modifier exactly when a name can follow it
            // (tsc's `parseAnyContextualModifier` -> `canFollowModifier`), and
            // `<out>`, `<out, T>` and `<out = X>` still declare a parameter
            // *named* `out`, as tsc parses them.
            var out_tok: ?u32 = null;
            // tsc's `checkGrammarModifiers` reports the FIRST offending
            // modifier of a type parameter and stops, so `<const in out T>` on
            // a function is one TS1274 (at `in`), not two.
            var reported = false;
            while (true) {
                const tag = p.curTag();
                const is_modifier = switch (tag) {
                    .keyword_const, .keyword_in => true,
                    .keyword_out => typeParamNameFollows(p.peekTag(1)),
                    else => false,
                };
                if (!is_modifier) break;
                const tok = try p.bump();
                // Diagnostics only — `errAtToken` does not backtrack, and a
                // speculative parse that loses discards them with `restore`,
                // so reporting here cannot cost us an arrow function.
                const bad: ?diagnostics.Code = if (tag == .keyword_const)
                    (if (owner.allowsConst()) null else .const_modifier_not_valid_here)
                else if (!owner.allowsVariance())
                    (if (tag == .keyword_in) .in_modifier_not_valid_here else .out_modifier_not_valid_here)
                else if (tag == .keyword_in and out_tok != null)
                    .in_must_precede_out
                else
                    null;
                if (bad) |code| {
                    if (!reported) try p.errAtToken(code, tok);
                    reported = true;
                }
                if (tag == .keyword_out) out_tok = tok;
            }
            if (!isIdentLike(p.curTag())) {
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
            if (p.curIdx() == before) {
                // tsc's `abortParsingListOrMoveToNextToken`: a token that starts
                // no parameter is reported (already done, inside `parseParam`)
                // and SKIPPED, and the list keeps going. Ending the list here
                // instead left the rest of the header to be re-read as
                // statements, which invented diagnostics tsc never has:
                // `function* f(a = yield => yield) {}` is one "',' expected"
                // for tsc, because it skips the `=>` and takes `yield` as a
                // second parameter, closing the list at the real `)`.
                if (p.spec > 0) break; // speculating: let the caller decide
                _ = try p.bump();
                continue;
            }
            try p.pushScratch(param);
            if (try p.eat(.comma) == null and p.curTag() != .r_paren) {
                try p.fail(.expected_comma);
            }
        }
        _ = try p.expect(.r_paren, .expected_r_paren);
        return p.scratchToSpan(top);
    }

    fn parseParam(p: *Parser) PE!Node {
        // Parameter decorators (`@dec x: T`) are a grammar error under TC39
        // standard decorators: consume them (so the parameter itself still
        // parses cleanly, no cascade) and report TS1206 per decorator.
        //
        // Under `experimentalDecorators` they are legal, so the diagnostic is
        // dropped. The expression is still consumed and then DISCARDED rather
        // than hung off the parameter: a legacy parameter decorator is only
        // ever a value read from the enclosing scope, so the sole check it
        // could contribute is on names ztsc would have to bind through a new
        // AST edge. Skipping it under-reports (an undefined name inside
        // `@Inject(Nope)` goes unnamed) and can never invent a diagnostic —
        // the trade the flag is documented to make.
        while (p.curTag() == .at) {
            if (p.spec > 0) return error.Backtrack;
            const at = try p.bump(); // `@`
            if (canStartExpression(p.curTag())) _ = try p.parseLhsExpression(.{});
            if (!p.experimental_decorators) try p.errAtToken(.decorator_not_valid_here, at);
        }
        const start_tok = p.curIdx();
        var flags: u32 = 0;
        var access_reported = false;
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
            if (!access_reported and p.spec == 0 and accessibilityRepeat(flags, bit)) {
                try p.errAtCur(.accessibility_modifier_already_seen);
                access_reported = true;
            }
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
        if (try p.eat(.colon) != null) {
            // A parameter's type annotation is a full type — including a
            // conditional (`x: T extends U ? A : B`). Clear the function-type
            // speculation flag so `parseType` claims a trailing `extends` here:
            // a parameter list can never be followed by a bare `extends`, so the
            // conditional is unambiguous once we are past the `:`. Without this,
            // the `spec == 0` guard in `parseType` truncated the annotation to
            // its check type and derailed the whole param list (e.g. base-ui's
            // `(value: Value extends number ? number : Value, …) => void`).
            const saved_spec = p.spec;
            p.spec = 0;
            defer p.spec = saved_spec;
            type_ann = try p.parseType();
        }
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
                    try p.checkStrictReserved();
                    const tok = try p.bump();
                    try p.checkEvalOrArguments(tok);
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
            } else if (p.curTag() == .l_bracket) {
                // `{[key]: target}` / `{[key]: target = init}` — a computed
                // binding key. The `= init` default is folded into the target
                // as a `binding_default` so the node keeps its two slots
                // (key, target) — bluesky's `const {[key]: _, ...rest} = prev`.
                const lb = try p.bump();
                const key_expr = try p.parseAssignExpr(.{});
                _ = try p.expect(.r_bracket, .expected_r_bracket);
                var target: Node = null_node;
                if (try p.eat(.colon) != null) target = try p.parseBindingName();
                if (try p.eat(.eq)) |eq_tok| {
                    const init = try p.parseAssignExpr(.{});
                    target = try p.addNode(.{ .tag = .binding_default, .main_token = eq_tok, .data = .{ .lhs = target, .rhs = init } });
                }
                try p.pushScratch(try p.addNode(.{
                    .tag = .binding_property_computed,
                    .main_token = lb,
                    .data = .{ .lhs = key_expr, .rhs = target },
                }));
            } else {
                try p.fail(.expected_binding_pattern_property);
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
        if (p.atLt()) tp = try p.parseTypeParams(.class);

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
        // Inside the body every strict-reserved word is TS1213 rather than
        // TS1212 (tsc's `getContainingClass`), including in nested functions and
        // nested classes — hence a depth counter rather than a flag.
        p.class_depth += 1;
        defer p.class_depth -= 1;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            const diags_before = p.diags.items.len;
            if (try p.eat(.semicolon) != null) continue;
            try p.pushScratch(try p.parseClassMember());
            if (p.curIdx() == before) {
                // The member parse consumed nothing. If it already said why
                // (a member-name failure reports TS1068 at this very token),
                // do not say it a second time — tsc reports one diagnostic
                // here, and a duplicate key is a false positive.
                if (p.diags.items.len == diags_before) try p.errAtCur(.expected_class_member);
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
        var expr = try p.parseLhsExpression(.{ .no_calls = false });
        var targs_extra: u32 = 0;
        if (p.takeInstantiationTargs(&expr)) |range| {
            // `extends A<T>, B` — the `,` let the call chain read `<T>` as an
            // instantiation expression; the heritage clause owns it.
            targs_extra = try p.addExtra(range);
        } else if (p.atLt()) {
            const range = try p.parseTypeArgs();
            targs_extra = try p.addExtra(range);
        }
        return p.addNode(.{ .tag = .heritage, .main_token = start_tok, .data = .{ .lhs = expr, .rhs = targs_extra } });
    }

    /// A decorator `@expr` (TC39 standard decorators). The expression is a
    /// left-hand-side expression — identifier, property access (`@a.b`), or
    /// call (`@a.b(args)`) — not an arbitrary expression (no binary ops). The
    /// resulting `.decorator` node carries the expression in `data.lhs`; the
    /// checker name-resolves and type-checks it (undefined name ⇒ TS2304).
    fn parseDecorator(p: *Parser) PE!Node {
        const at = try p.bump(); // `@`
        var expr: Node = null_node;
        if (canStartExpression(p.curTag())) expr = try p.parseLhsExpression(.{ .in_decorator = true });
        return p.addNode(.{ .tag = .decorator, .main_token = at, .data = .{ .lhs = expr, .rhs = 0 } });
    }

    /// TS1028, tsc's `checkGrammarModifiers`: at most one of
    /// `public`/`private`/`protected` per member or parameter property. `already`
    /// is the flag set accumulated so far, `bit` the modifier about to be
    /// consumed; true when `bit` is the second one.
    ///
    /// tsc `return`s out of its whole modifier walk on the first hit, so
    /// `public protected private x` is ONE diagnostic, not two — callers stop
    /// asking once it has answered true.
    fn accessibilityRepeat(already: u32, bit: u32) bool {
        const access = ast.Flags.public | ast.Flags.private | ast.Flags.protected;
        return bit & access != 0 and already & access != 0;
    }

    fn parseClassMember(p: *Parser) PE!Node {
        const start_tok = p.curIdx();

        // Decorators on members: a `.decorator` node preceding the decorated
        // member (the body loop re-enters for the member itself).
        if (p.curTag() == .at) return p.parseDecorator();

        // `static { … }` — a class static initialization block. Parsed as a
        // plain `.block` member so the statements inside land in the tree with
        // real spans instead of derailing the member loop (which read `static`
        // as a FIELD name and then answered "';' expected" at the `{`, the
        // single largest source of ztsc's excess TS1005). The binder ignores a
        // `.block` member, so the body is not checked yet — an under-report,
        // never a wrong answer.
        if (p.curTag() == .keyword_static and p.peekTag(1) == .l_brace) {
            _ = try p.bump(); // `static`
            return p.parseBlock();
        }

        var flags: u32 = 0;
        var access_reported = false;
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
            if (!access_reported and p.spec == 0 and accessibilityRepeat(flags, bit)) {
                try p.errAtCur(.accessibility_modifier_already_seen);
                access_reported = true;
            }
            _ = try p.bump();
            flags |= bit;
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
                } else if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .r_bracket) {
                    // `[k]` where `k` is a plain identifier: a computed key
                    // naming a const `unique symbol` (drizzle's
                    // `static readonly [entityKind]`, typebox's `[Kind]`). The
                    // checker resolves the identifier to its nominal symbol id.
                    _ = try p.bump(); // `[`
                    name_tok = try p.bump(); // identifier
                    _ = try p.eat(.r_bracket);
                    flags |= ast.Flags.computed | ast.Flags.computed_sym;
                } else if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .dot and
                    isIdentLike(p.peekTag(3)) and p.peekTag(4) == .r_bracket)
                {
                    // `[a.b]` member-expression computed key (node's
                    // `[EventEmitter.captureRejectionSymbol]`): keyed by the
                    // member's nominal symbol id, resolved by the checker.
                    // The object identifier sits at `name_tok - 2`.
                    _ = try p.bump(); // `[`
                    _ = try p.bump(); // object identifier
                    _ = try p.bump(); // `.`
                    name_tok = try p.bump(); // member identifier
                    _ = try p.eat(.r_bracket);
                    flags |= ast.Flags.computed | ast.Flags.computed_sym | ast.Flags.computed_sym_qual;
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
                    // A CLASS member name: tsc's `parseClassElement` answers
                    // TS1068 here, not the object-literal TS1136.
                    try p.fail(.expected_class_member);
                    return p.errorNode();
                }
            },
        }

        // Optional method `m?(): T` / `m?<K>(): T` (ambient/overload members).
        if (p.curTag() == .question) {
            switch (p.peekTag(1)) {
                .l_paren, .lt, .lt_lt, .lt_lt_eq => {
                    _ = try p.bump();
                    flags |= ast.Flags.optional;
                },
                else => {},
            }
        }
        if (p.curTag() == .l_paren or p.atLt()) {
            // Method / constructor / accessor.
            const proto = try p.parseFnProtoRest(flags, name_tok);
            var body: Node = null_node;
            if (p.curTag() == .l_brace) {
                body = try p.parseFunctionBody();
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
        if (p.atLt()) tp = try p.parseTypeParams(.type_decl);
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
        if (isIdentLike(p.curTag())) {
            try p.checkStrictReserved();
            return p.bump();
        }
        try p.fail(.expected_identifier);
        return p.lastIdx();
    }

    /// The EXPORT name of `export * as X from "m"` / `export * as "s" from "m"`
    /// — a ModuleExportName, so a string literal is legal there (ES2022
    /// arbitrary module namespace identifiers). Only the export side: a LOCAL
    /// binding (`import { "s" as x }`) still has to be an identifier.
    fn expectModuleExportName(p: *Parser) PE!u32 {
        if (p.curTag() == .string_literal) return p.bump();
        return p.expectIdentLike();
    }

    /// TS1212/TS1213/TS1214, tsc's `checkStrictModeIdentifier`: a future-reserved
    /// word standing where an *Identifier* is required. Call sites are the three
    /// funnels that turn a token into an Identifier — a declaration name
    /// (`expectIdentLike`), a binding name, and an identifier reference. Deliberately
    /// NOT the IdentifierName positions, where every reserved word is legal:
    /// after a `.`, as a member or property name, as an import/export specifier
    /// name, or as a JSX name. Nor a modifier — `public x` reaches the modifier
    /// loop, never this.
    ///
    /// ztsc is always-strict, so there is no mode to test; tsc reaches the same
    /// state whenever `alwaysStrict` is on, which `strict` implies.
    ///
    /// An AMBIENT identifier is exempt — tsc's condition includes
    /// `!(node.flags & NodeFlags.Ambient)`, so `declare namespace Foo { export
    /// var static: any; }` and every name in a `.d.ts` are fine. A declaration
    /// file describes an interface that may well have been written in sloppy
    /// mode, so the reserved-word rule has nothing to say about it.
    ///
    /// Skipped while speculating: a construct that only ever gets parsed inside a
    /// lookahead is not committed source, and the real parse reports it.
    fn checkStrictReserved(p: *Parser) Error!void {
        if (p.spec > 0 or p.ambient) return;
        if (!p.curTag().isStrictReservedKeyword()) return;
        try p.errAtCur(if (p.class_depth > 0)
            .strict_reserved_word_in_class
        else
            .strict_reserved_word);
    }

    /// TS1100/TS1210/TS1215, tsc's `checkStrictModeEvalOrArguments`: `eval` and
    /// `arguments` may be READ in strict mode but not DECLARED or ASSIGNED to.
    /// Called from the declaring funnels (binding name, function name) and the
    /// assignment/update targets — never from a plain reference, which is legal
    /// (`f(eval)` is fine; measured).
    ///
    /// The class/module/plain choice is TS1212's, so the wording is picked the
    /// same way: a containing class wins outright, and "module" is only settled
    /// at EOF, so `sealInto` relabels. Ambient contexts are exempt — tsc exempts
    /// PARAMETERS explicitly (`declare function h(eval: any)` is silent) and
    /// not variables, but a single rule that never fires in a `.d.ts` can only
    /// under-report, while the split rule risks inventing keys inside `lib`.
    fn checkEvalOrArguments(p: *Parser, tok: u32) Error!void {
        if (p.spec > 0 or p.ambient) return;
        if (p.tokTagAt(tok) != .identifier) return;
        const text = p.tokenTextAt(tok);
        const is_eval = std.mem.eql(u8, text, "eval");
        if (!is_eval and !std.mem.eql(u8, text, "arguments")) return;
        const code: Code = if (p.class_depth > 0)
            (if (is_eval) .eval_in_class else .arguments_in_class)
        else
            (if (is_eval) .eval_in_strict else .arguments_in_strict);
        try p.errAtToken(code, tok);
    }

    /// `checkEvalOrArguments` on an already-parsed expression, when that
    /// expression is the TARGET of an assignment or of `++`/`--`.
    fn checkEvalOrArgumentsTarget(p: *Parser, expr: Node) Error!void {
        if (expr == null_node) return;
        if (p.nodes.items(.tag)[expr] != .identifier) return;
        try p.checkEvalOrArguments(p.nodes.items(.main_token)[expr]);
    }

    /// A JSX tag or attribute name: `JsxIdentifier` is an *IdentifierName*, so
    /// every reserved word is legal here (`<Foo in="SourceAlpha" for="x">`, the
    /// SVG filter attributes, `<svg.default />`) — tsc parses both positions
    /// with `parseIdentifierName`. Additionally it may span `-` (`data-foo`,
    /// `<my-widget>`); the rescan runs first so the hyphenated run is a single
    /// `.jsx_name` token.
    fn expectJsxName(p: *Parser) PE!u32 {
        p.rescanJsxName();
        if (p.curTag() == .jsx_name or isNameLike(p.curTag())) return p.bump();
        try p.fail(.expected_identifier);
        return p.lastIdx();
    }

    fn parseTypeAlias(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `type`
        const name_tok = try p.expectIdentLike();
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams(.type_decl);
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
        // Member name: an enum member name is a PropertyName, so a numeric or
        // private one PARSES and is then rejected by name (TS2452 / TS18024) —
        // rejecting it here instead cost a false TS1003 and, with it, the whole
        // file's semantic pass.
        const name_code: ?Code = switch (p.curTag()) {
            .numeric_literal => .enum_member_numeric_name,
            .private_identifier => .enum_member_private_name,
            else => null,
        };
        if (name_code == null and !isIdentLike(p.curTag()) and p.curTag() != .string_literal) {
            try p.fail(.expected_identifier);
            return p.errorNode();
        }
        if (name_code) |code| {
            if (p.spec > 0) return error.Backtrack;
            try p.errAtCur(code);
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
        // `declare namespace N { ... }` makes the whole body ambient; a plain
        // `namespace` nested in an ambient one inherits it.
        const was_ambient = p.ambient;
        p.ambient = was_ambient or flags & ast.Flags.declare != 0;
        defer p.ambient = was_ambient;
        try p.parseStatementList(top, .r_brace, false);
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
    /// linker merges into the program global table. `name_token` points
    /// at the `global` keyword purely for span/dump purposes.
    fn parseGlobalAugmentation(p: *Parser) PE!Node {
        const kw = try p.bump(); // `global`
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        const was_ambient = p.ambient;
        p.ambient = true;
        defer p.ambient = was_ambient;
        try p.parseStatementList(top, .r_brace, false);
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

    /// `declare module "spec" { ... }` (the `declare` already consumed).
    /// Modeled as a `namespace_decl` flagged `ambient_module`; `name_token`
    /// is the specifier string literal. The block's exports become an ambient
    /// module the linker resolves imports of `"spec"` against, and merges into
    /// a real module's exports when `"spec"` also resolves (augmentation).
    ///
    /// The *shorthand* form has no block at all — `declare module "*.scss";`
    /// — and declares a module whose every export is `any`. That is exactly
    /// what an empty body already means downstream (the linker's
    /// `ambientOpaque`: an ambient module with no named exports degrades
    /// imports to `any`), so the shorthand parses to the same node with an
    /// empty body span. Demanding the `{` instead cost the whole rest of the
    /// file: a project `global.d.ts` that opens with `declare module "*.scss";`
    /// and then augments an interface lost the augmentation to error recovery,
    /// and under `skipLibCheck` the parse error itself was invisible.
    fn parseAmbientModule(p: *Parser) PE!Node {
        const kw = try p.bump(); // `module`
        const spec_tok = try p.bump(); // string literal
        if (p.curTag() != .l_brace) {
            _ = try p.eat(.semicolon);
            const empty = try p.scratchToSpan(p.scratchTop());
            const extra_short = try p.addExtra(ast.NamespaceData{
                .flags = ast.Flags.declare | ast.Flags.ambient_module,
                .name_token = spec_tok,
                .body_start = empty.start,
                .body_end = empty.end,
            });
            return p.addNode(.{ .tag = .namespace_decl, .main_token = kw, .data = .{ .lhs = extra_short, .rhs = 0 } });
        }
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        const was_ambient = p.ambient;
        p.ambient = true;
        defer p.ambient = was_ambient;
        try p.parseStatementList(top, .r_brace, false);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const body = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.NamespaceData{
            .flags = ast.Flags.declare | ast.Flags.ambient_module,
            .name_token = spec_tok,
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
        p.saw_module_syntax = true;
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
                return p.finishImportEquals(kw, default_name, 0);
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
        try p.skipImportAttributes();
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

    /// `import <name> = require("m");` or `import <name> = A.B;` (CommonJS /
    /// TS-namespace alias). Positioned just before the `=`; `name_tok` is the
    /// local binding, `import_kw` anchors the node span. `flags` carries
    /// `Flags.exported` for the `export import` form.
    fn finishImportEquals(p: *Parser, import_kw: u32, name_tok: u32, flags: u32) PE!Node {
        _ = try p.bump(); // '='
        var module_token: u32 = 0;
        var entity: Node = 0;
        if (isIdentLike(p.curTag()) and std.mem.eql(u8, p.laText(0), "require") and p.peekTag(1) == .l_paren) {
            _ = try p.bump(); // require
            _ = try p.expect(.l_paren, .expected_l_paren);
            module_token = try p.expect(.string_literal, .expected_string_literal);
            _ = try p.expect(.r_paren, .expected_r_paren);
        } else {
            entity = try p.parseEntityName();
        }
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.ImportEquals{
            .name_token = name_tok,
            .module_token = module_token,
            .entity = entity,
            .flags = flags,
        });
        return p.addNode(.{ .tag = .import_equals, .main_token = import_kw, .data = .{ .lhs = extra, .rhs = 0 } });
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
            if (!isModuleExportName(p.curTag())) {
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

    /// Import attributes — `with { type: "json" }` (ES2025) or the deprecated
    /// `assert { ... }` — on an `import`, `export * from` or `export { } from`
    /// declaration. Consumed, not modeled: the module resolver ztsc has does
    /// not vary by attribute, and a construct the parser rejects costs a false
    /// syntax error (which suppresses the file's whole semantic pass). Must be
    /// on the same line as the module specifier, as in tsc's
    /// `tryParseImportAttributes`.
    fn skipImportAttributes(p: *Parser) Error!void {
        const tag = p.curTag();
        if (tag != .keyword_with and tag != .keyword_assert) return;
        if (p.nlBefore() or p.peekTag(1) != .l_brace) return;
        _ = try p.bump();
        p.skipBalancedBraces();
    }

    fn parseExportStatement(p: *Parser) PE!Node {
        const kw = try p.bump(); // `export`
        p.saw_module_syntax = true;
        switch (p.curTag()) {
            .keyword_default => {
                _ = try p.bump();
                const inner = switch (p.curTag()) {
                    // `export default function (…) {…}` may be anonymous.
                    .keyword_function => try p.parseFunctionDeclNamed(0, false, true),
                    .keyword_async => blk: {
                        if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                            _ = try p.bump();
                            break :blk try p.parseFunctionDeclNamed(ast.Flags.async, false, true);
                        }
                        const e = try p.parseAssignExpr(.{});
                        try p.expectSemicolon();
                        break :blk e;
                    },
                    .keyword_class => try p.parseClassDecl(0),
                    // `export default interface I { … }` — legal, and the only
                    // TYPE-side default export form.
                    .keyword_interface => try p.parseStatement(),
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
                // `export = <entity>;` (CommonJS export assignment).
                _ = try p.bump();
                const entity = if (canStartExpression(p.curTag())) try p.parseAssignExpr(.{}) else 0;
                try p.expectSemicolon();
                return p.addNode(.{ .tag = .export_assign, .main_token = kw, .data = .{ .lhs = entity, .rhs = 0 } });
            },
            .keyword_import => {
                // `export import A = B.C;` inside a namespace (exported alias).
                const imp_kw = try p.bump();
                const name_tok = try p.expectIdentLike();
                if (p.curTag() != .eq) {
                    try p.fail(.expected_eq);
                    return p.addNode(.{ .tag = .export_assign, .main_token = kw, .data = .{ .lhs = 0, .rhs = 0 } });
                }
                return p.finishImportEquals(imp_kw, name_tok, ast.Flags.exported);
            },
            .asterisk => {
                _ = try p.bump();
                var ns_name: u32 = 0;
                if (try p.eat(.keyword_as) != null) ns_name = try p.expectModuleExportName();
                _ = try p.expect(.keyword_from, .expected_from);
                const mod = try p.expect(.string_literal, .expected_string_literal);
                try p.skipImportAttributes();
                try p.expectSemicolon();
                const extra = try p.addExtra(ast.ExportAll{ .flags = 0, .name_token = ns_name });
                return p.addNode(.{ .tag = .export_all, .main_token = kw, .data = .{ .lhs = extra, .rhs = mod } });
            },
            .keyword_as => {
                // `export as namespace <Ident>;` — UMD global declaration. The
                // name is kept: the binder publishes the module's `export =`
                // entity under it as a global, which is what makes
                // `React.CSSProperties` resolve in a file that never imports
                // React. Common in the ecosystem's `export = X; export as
                // namespace X;` shape.
                _ = try p.bump(); // `as`
                if (p.curTag() == .keyword_namespace) _ = try p.bump();
                const name_tok = try p.expectIdentLike();
                try p.expectSemicolon();
                return p.addNode(.{ .tag = .export_as_ns, .main_token = kw, .data = .{ .lhs = name_tok, .rhs = 0 } });
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
                    if (try p.eat(.keyword_as) != null) ns_name = try p.expectModuleExportName();
                    _ = try p.expect(.keyword_from, .expected_from);
                    const mod = try p.expect(.string_literal, .expected_string_literal);
                    try p.skipImportAttributes();
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
            if (!isModuleExportName(p.curTag())) {
                try p.fail(.expected_identifier);
                if (p.curIdx() == before) break;
                continue;
            }
            const name = try p.bump();
            var alias: u32 = 0;
            if (try p.eat(.keyword_as) != null) {
                // The export name (alias) is also a ModuleExportName, so
                // `export { Foo as default }` and string aliases are legal.
                if (isModuleExportName(p.curTag())) {
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
        try p.skipImportAttributes();
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
        /// Inside a decorator's `@ LeftHandSideExpression` (tsc's
        /// `NodeFlags.Decorator` parsing context). A `[` after the decorator
        /// expression is NOT an element access — it opens the decorated
        /// member's COMPUTED PROPERTY NAME, which is on the next line as
        /// often as not (`@ApiProperty(...) \n [Field.NAME]!: T`). tsc
        /// suppresses the element-access production in exactly this context
        /// (`parseMemberExpressionRest`'s `!inDecoratorContext()`); without
        /// it the decorator swallows the member name and the class body
        /// derails. Cleared inside argument lists and parentheses, which
        /// parse with a fresh context here as they do there.
        in_decorator: bool = false,
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
                // `<`/`<<` covers a generic async arrow `async <T>(x) => …`;
                // speculation backtracks if it turns out to be `async < b`.
                if (!p.peekNewline(1) and (t1 == .l_paren or t1 == .lt or t1 == .lt_lt or isIdentLike(t1))) {
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
            try p.checkEvalOrArgumentsTarget(lhs);
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
        if (p.atLt()) tp = try p.parseTypeParams(.callable);
        if (p.curTag() != .l_paren) return error.Backtrack;
        const params = try p.parseParams();
        var ret: Node = null_node;
        if (try p.eat(.colon) != null) {
            // An arrow's return-type annotation is a full type — including a
            // conditional (`(x: X): X extends null ? null : string => …`).
            // Clear the speculation flag across it, the way `parseParam` and
            // `parseFunctionType` do: the `spec == 0` guard in `parseType`
            // otherwise leaves `extends` unclaimed, the annotation stops at
            // its check type, no `=>` follows, and the whole arrow backtracks
            // into a parenthesized expression. This does not commit us to an
            // arrow — the `=>` test below still backtracks, and `restore`
            // truncates anything the annotation parse appended, diagnostics
            // included.
            const saved_spec = p.spec;
            p.spec = 0;
            defer p.spec = saved_spec;
            ret = try p.parseReturnType();
        }
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
        if (p.curTag() == .l_brace) return p.parseFunctionBody();
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

    /// tsc's `parseUnaryExpressionOrHigher`: parse one unary expression, then
    /// — and only at this outermost level — enforce the ES2016 exponentiation
    /// grammar, whose left operand is an `UpdateExpression`, never a
    /// `UnaryExpression`. `-a ** b` is therefore a syntax error asking for
    /// parentheses; `++a ** b` and `a++ ** b` are updates and are fine.
    ///
    /// The check lives here rather than one level down in
    /// `parseSimpleUnaryExpr` for the reason tsc splits the two functions:
    /// in `- -a ** b` only the OUTER unary is the left operand of `**`, so
    /// exactly one error is due. Nested prefix operators recurse into
    /// `parseSimpleUnaryExpr`, which never looks at what follows.
    fn parseUnaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        const first_tok = p.curIdx();
        const node = try p.parseSimpleUnaryExpr(ctx);
        if (p.curTag() == .asterisk_asterisk) {
            // Speculation reports nothing (`checkNullishMixing`'s rule): a
            // discarded parse must not leave a diagnostic behind, and the
            // real parse that follows reaches this same point.
            if (p.spec == 0) {
                if (expLhsCode(p, node)) |code| try p.errAtRange(code, first_tok, p.lastIdx());
            }
        }
        return node;
    }

    /// The grammar code owed for a `**` left operand that parsed as `node`, or
    /// null when the operand is an `UpdateExpression` (a `++`/`--` prefix or
    /// postfix, or a plain left-hand-side expression) and therefore legal.
    fn expLhsCode(p: *Parser, node: Node) ?Code {
        const main = p.nodes.items(.main_token)[node];
        return switch (p.nodes.items(.tag)[node]) {
            .prefix_unary => switch (p.tokTagAt(main)) {
                .plus => .exp_lhs_plus,
                .minus => .exp_lhs_minus,
                .tilde => .exp_lhs_tilde,
                .bang => .exp_lhs_bang,
                .keyword_delete => .exp_lhs_delete,
                .keyword_void => .exp_lhs_void,
                .keyword_typeof => .exp_lhs_typeof,
                .keyword_await => .exp_lhs_await,
                // `++x` / `--x` are UpdateExpressions: legal.
                else => null,
            },
            // `<T>x ** 2`. `x as T` cannot arrive here — `as` is parsed by
            // `parseBinaryExpr`, above this function.
            .as_expr => if (p.tokTagAt(main) == .lt) .exp_lhs_type_assertion else null,
            else => null,
        };
    }

    fn parseSimpleUnaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        // Legacy angle-bracket type assertion `<T>expr`. Only in files where
        // JSX is off: in a `.tsx`/`.jsx` file a `<` in expression position
        // opens an element and tsc rejects this assertion form outright.
        // Reached only after the generic-arrow speculation in `parseAssignExpr`
        // has already declined `<T>(x) => y`. Only a lone `<` opens one:
        // tsc does not split a `<<` here either (`<<T>(x: T) => T>v` is a
        // syntax error for it too).
        if (!p.jsx and p.curTag() == .lt) return p.parseTypeAssertion(ctx);
        switch (p.curTag()) {
            .bang, .tilde, .plus, .minus, .plus_plus, .minus_minus, .keyword_typeof, .keyword_void, .keyword_delete => {
                const op = try p.bump();
                const operand = try p.parseSimpleUnaryExpr(ctx);
                // `++eval` / `--arguments` assign to their operand.
                const tag = p.tokTagAt(op);
                if (tag == .plus_plus or tag == .minus_minus) try p.checkEvalOrArgumentsTarget(operand);
                return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_await => {
                // `await expr` when an expression follows; else `await` is
                // an ordinary identifier.
                if (canStartExpression(p.peekTag(1)) and p.peekTag(1) != .colon) {
                    const op = try p.bump();
                    const operand = try p.parseSimpleUnaryExpr(ctx);
                    return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = operand, .rhs = 0 } });
                }
            },
            else => {},
        }
        return p.parsePostfixExpr(ctx);
    }

    /// `<T>expr` — the pre-`as` assertion syntax, still legal in non-JSX
    /// files. It is the same operation as `expr as T`, so it reuses
    /// `.as_expr`; `main_token` is the `<` (the node's span still covers
    /// the whole assertion, which is what diagnostics report).
    fn parseTypeAssertion(p: *Parser, ctx: ExprCtx) PE!Node {
        const lt = try p.bump(); // `<`
        // `<const>x` is a const assertion, the angle-bracket spelling of
        // `x as const`.
        const ty = if (p.curTag() == .keyword_const and p.peekTag(1) == .gt)
            try p.leaf(.const_type)
        else
            try p.parseType();
        _ = try p.expectGt();
        const operand = try p.parseSimpleUnaryExpr(ctx);
        return p.addNode(.{ .tag = .as_expr, .main_token = lt, .data = .{ .lhs = operand, .rhs = ty } });
    }

    fn parsePostfixExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        const lhs = try p.parseLhsExpression(ctx);
        if ((p.curTag() == .plus_plus or p.curTag() == .minus_minus) and !p.nlBefore()) {
            const op = try p.bump();
            try p.checkEvalOrArgumentsTarget(lhs); // `eval++` assigns to `eval`
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
                            // `a?.<T>(...)` — a call, or nothing at all.
                            if (try p.tryParseTypeArgsInExpr(ctx, true)) |targs| {
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
                    // In a decorator this `[` starts the decorated member's
                    // computed name, not an element access. See `in_decorator`.
                    if (ctx.in_decorator) return lhs;
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
                    // Generic call / instantiation-expression speculation.
                    const lt = p.curIdx();
                    const targs = (try p.tryParseTypeArgsInExpr(ctx, false)) orelse return lhs;
                    // `f<T>` with no argument list is an instantiation
                    // expression; so is a `<T>` inside a `new` callee or a
                    // heritage clause, whose owner claims the type arguments
                    // back off the node (`takeInstantiationTargs`) — exactly
                    // how tsc routes `new C<T>()` and `extends C<T>`. The loop
                    // continues either way, so a template head still tags the
                    // instantiation (`f<T>\`x\``).
                    if (ctx.no_calls or p.curTag() != .l_paren) {
                        const extra = try p.addExtra(targs);
                        lhs = try p.addNode(.{ .tag = .instantiation_expr, .main_token = lt, .data = .{ .lhs = lhs, .rhs = extra } });
                        continue;
                    }
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

    /// If `expr` is an instantiation expression, unwrap it in place and hand
    /// back its type-argument range. The `<T>` of `new C<T>(…)` and of
    /// `extends C<T>` is parsed by the call chain — the only place that can
    /// tell type arguments from a relational `<` — and claimed here by the
    /// construct that actually owns it, as tsc does.
    fn takeInstantiationTargs(p: *Parser, expr: *Node) ?ast.SubRange {
        if (p.nodes.items(.tag)[expr.*] != .instantiation_expr) return null;
        const d = p.nodes.items(.data)[expr.*];
        expr.* = d.lhs;
        return .{ .start = p.extra.items[d.rhs], .end = p.extra.items[d.rhs + 1] };
    }

    /// `<T, ...>` accepted as type arguments when the token that follows the
    /// closing `>` may follow a type-argument list in expression position
    /// (see `canFollowTypeArgsInExpr`); otherwise the parse is undone — the
    /// scanner, the token/node/extra/scratch/diagnostic arrays and the
    /// speculation depth all return to their entry values — and null is
    /// returned so the caller re-reads the `<` as a relational operator.
    ///
    /// `require_paren` narrows acceptance to a following `(`: the call-only
    /// sites (`a?.<T>(…)`, `new C<T>(…)`), where the grammar admits no
    /// instantiation expression.
    fn tryParseTypeArgsInExpr(p: *Parser, ctx: ExprCtx, require_paren: bool) PE!?ast.SubRange {
        const state = p.save();
        const saved_spec = p.spec;
        p.spec += 1;
        const result: PE!ast.SubRange = p.parseTypeArgs();
        // Restore the depth unconditionally, on the error path too: a `spec`
        // left set past a construct's end silently mis-parses everything after
        // it (`parseType`'s `extends` guard, `unsupportedFrom`, every `fail`).
        p.spec = saved_spec;
        const range = result catch |err| switch (err) {
            error.Backtrack => {
                p.restore(state);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const ok = if (require_paren) p.curTag() == .l_paren else p.canFollowTypeArgsInExpr(ctx);
        if (!ok) {
            p.restore(state);
            return null;
        }
        return range;
    }

    /// tsc's `canFollowTypeArgumentsInExpression`: given a `<…>` that parsed
    /// as a type-argument list, does the token after the closing `>` allow
    /// that reading over the relational one?
    fn canFollowTypeArgsInExpr(p: *Parser, ctx: ExprCtx) bool {
        switch (p.curTag()) {
            // These commit to the type-argument reading even where JavaScript
            // would see a comparison: `f<T>(x)`, `f<T>\`x\``.
            .l_paren, .no_substitution_template_literal, .template_head => return true,
            // A type-argument list followed by `<` never makes sense, one
            // followed by `>` is ambiguous with a re-scanned `>>`, and here
            // `+`/`-` read as unary operators, not binary ones. The whole
            // `>`-family counts as `>`: tsc's scanner emits a bare `>` and
            // merges `>>`/`>=`/… only on demand, so `f<T> >= 1` sees a plain
            // `>` there and takes the relational reading — this parser's
            // maximal munch has to answer the same way.
            .lt, .gt, .gt_gt, .gt_gt_gt, .gt_eq, .gt_gt_eq, .gt_gt_gt_eq, .plus, .minus => return false,
            else => {},
        }
        // `as` / `satisfies` are binary operators at relational precedence for
        // this test (tsc has them in `getBinaryOperatorPrecedence`), even
        // though `parseBinaryExpr` gives them their own arm here.
        if (p.curTag() == .keyword_as or p.curTag() == .keyword_satisfies) return true;
        // Otherwise the type-argument reading wins when the next token cannot
        // continue the expression: a line break, a binary operator, or
        // anything that starts no expression at all.
        return p.nlBefore() or binaryPrec(p.curTag(), ctx.no_in) > 0 or !canStartExpression(p.curTag());
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
            // The `new.target` meta-property. Anything else after the dot is
            // not a meta-property at all, so it keeps the subset boundary.
            _ = try p.bump(); // `.`
            if (isIdentLike(p.curTag()) and std.mem.eql(u8, p.laText(0), "target")) {
                _ = try p.bump(); // `target`
                return p.addNode(.{ .tag = .new_target, .main_token = kw, .data = .{ .lhs = 0, .rhs = 0 } });
            }
            _ = try p.eat(.identifier);
            return p.unsupportedFrom(kw);
        }
        // Callee: member expression only (calls bind to the outer chain).
        var callee = try p.parsePrimaryExpr(ctx);
        callee = try p.parseCallChain(callee, .{ .no_in = ctx.no_in, .no_calls = true });

        // `new C<T>` / `new C<T>(…)`: the callee chain parses `<T>` under
        // `no_calls`, so the argument list stays with the `new`.
        var targs: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.takeInstantiationTargs(&callee)) |r| targs = r;
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
        if (targs.start != targs.end) {
            // `new C<T>` with no argument list — an empty one is implied.
            const info = try p.addExtra(ast.CallInfo{
                .targs_start = targs.start,
                .targs_end = targs.end,
                .args_start = 0,
                .args_end = 0,
            });
            return p.addNode(.{ .tag = .new_expr_targs, .main_token = kw, .data = .{ .lhs = callee, .rhs = info } });
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
        var targs: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.curTag() != .gt) {
            tag = try p.parseJsxTagName();
            // Explicit type arguments on a component tag: `<Select<string> …>`.
            // In a `.tsx` open tag this `<` is unambiguous (no cast ambiguity),
            // so parse it directly with the ordinary type-argument machinery —
            // scanning is already in normal (TS) mode here, exactly as an
            // attribute's `{expr}` container re-enters. Type args are parsed
            // only on the opening tag; closing tags never carry them.
            if (p.atLt()) targs = try p.parseTypeArgs();
        }
        const attrs = try p.parseJsxAttributes();
        var close_lt: TokenIndex = 0;
        var children: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.curTag() == .slash) {
            _ = try p.bump(); // '/'
            _ = try p.expect(.gt, .expected_gt);
        } else {
            _ = try p.expect(.gt, .expected_gt);
            const kids = try p.parseJsxChildren();
            children = kids.range;
            close_lt = kids.close_lt;
        }
        const data = try p.addExtra(ast.JsxElementData{
            .tag = tag,
            .close_lt = close_lt,
            .targs_start = targs.start,
            .targs_end = targs.end,
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
        // A tag name may be rooted at `this` (`<this.Component />`); only the
        // root, never a member of the chain. The rescan runs first so a
        // hyphenated custom element `<this-thing />` still lexes as one name.
        p.rescanJsxName();
        var node: Node = if (p.curTag() == .keyword_this)
            try p.leaf(.this_expr)
        else blk: {
            const tok = try p.expectJsxName();
            break :blk try p.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
        };
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
                const name = try p.expectJsxName();
                var value: Node = null_node;
                if (try p.eat(.eq) != null) value = try p.parseJsxAttributeValue();
                try p.pushScratch(try p.addNode(.{ .tag = .jsx_attribute, .main_token = name, .data = .{ .lhs = value, .rhs = 0 } }));
            }
            if (p.curIdx() == before) break; // no progress: bail to avoid a loop
        }
        return p.scratchToSpan(top);
    }

    fn parseJsxAttributeValue(p: *Parser) PE!Node {
        p.rescanJsxAttributeString();
        switch (p.curTag()) {
            .string_literal, .jsx_string => return p.leaf(.string_literal),
            .l_brace => {
                const lb = try p.bump();
                // `a={}` — an EMPTY container is legal JSX (tsc's JsxExpression
                // has an optional expression); the type error it earns is the
                // checker's, not a syntax error. Same shape as a child `{}`.
                var expr: Node = null_node;
                if (p.curTag() != .r_brace) expr = try p.parseAssignExpr(.{});
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

    /// The children of one non-self-closing element plus the `<` token of the
    /// `</tag>` that ended them (0 when the closing tag was never reached).
    const JsxChildren = struct { range: ast.SubRange, close_lt: TokenIndex };

    /// Children of a non-self-closing element, up to the matching `</tag>`
    /// (whose closing tag this consumes).
    fn parseJsxChildren(p: *Parser) PE!JsxChildren {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        var close_lt: TokenIndex = 0;
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
                    // `{...items}` — a spread CHILD, the same `...` the
                    // attribute list already accepts. The spread is not
                    // modelled; the expression inside is what gets checked.
                    _ = try p.eat(.dot_dot_dot);
                    var expr: Node = null_node;
                    if (p.curTag() != .r_brace) expr = try p.parseAssignExpr(.{});
                    _ = try p.expect(.r_brace, .expected_r_brace);
                    try p.pushScratch(try p.addNode(.{ .tag = .jsx_expr_container, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } }));
                    pos = p.lastTokEnd();
                },
                .lt => {
                    p.jsxResync(tok.start);
                    if (p.peekTag(1) == .slash) {
                        close_lt = try p.bump(); // '<'
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
        return .{ .range = try p.scratchToSpan(top), .close_lt = close_lt };
    }

    fn parsePrimaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        if (p.jsx and p.curTag() == .lt) return p.parseJsxElement();
        switch (p.curTag()) {
            .numeric_literal => return p.leaf(.number_literal),
            .bigint_literal => return p.leaf(.bigint_literal),
            .string_literal => return p.leaf(.string_literal),
            .unterminated_string_literal => {
                try p.errAtCurEnd(.unterminated_string);
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
                try p.errAtCurEnd(.unterminated_template);
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
            .unknown, .hash_bang, .binary_content => {
                if (p.spec > 0) return error.Backtrack;
                try p.errAtJunkToken();
                _ = try p.bump();
                return p.errorNode();
            },
            .unterminated_comment => {
                if (p.spec > 0) return error.Backtrack;
                try p.errAtCurEnd(.unterminated_comment);
                _ = try p.bump();
                return p.errorNode();
            },
            else => {
                if (isIdentLike(p.curTag())) {
                    try p.checkStrictReserved();
                    return p.leaf(.identifier);
                }
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
                    try p.errAtCurEnd(.unterminated_template);
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
                if (p.curTag() == .l_brace) body = try p.parseFunctionBody() else try p.fail(.expected_l_brace);
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
        const ty = try p.parseNonConditionalType();
        // Conditional type `C extends E ? T : F`. The `extends` clause
        // is a non-conditional type (a nested conditional there needs
        // parentheses, matching tsc); the two branches are full types. The
        // `spec == 0` guard keeps `extends` unclaimed while speculatively
        // parsing a function type, exactly as before.
        if (p.curTag() == .keyword_extends and !p.nlBefore() and p.spec == 0) {
            const ext_kw = try p.bump();
            const extends_ty = try p.parseNonConditionalType();
            _ = try p.expect(.question, .expected_colon);
            const true_ty = try p.parseType();
            _ = try p.expect(.colon, .expected_colon);
            const false_ty = try p.parseType();
            const extra = try p.addExtra(ast.ConditionalType{
                .extends_type = extends_ty,
                .true_type = true_ty,
                .false_type = false_ty,
            });
            return p.addNode(.{ .tag = .conditional_type, .main_token = ext_kw, .data = .{ .lhs = ty, .rhs = extra } });
        }
        return ty;
    }

    /// A type minus a trailing conditional: the function-type forms plus a
    /// union type. Shared by `parseType` (for the check and extends clauses of
    /// a conditional) so a conditional's `extends` clause and check type both
    /// admit function types without recursing into conditional parsing.
    fn parseNonConditionalType(p: *Parser) PE!Node {
        // Function type `(params) => R` / `<T>(params) => R`; constructor
        // type `new (...) => R` / `abstract new (...) => R`.
        switch (p.curTag()) {
            .lt, .lt_lt => return p.parseFunctionType(),
            .l_paren => {
                if (try p.tryParseFunctionType()) |ft| return ft;
            },
            .keyword_new => return p.parseConstructorType(false),
            .keyword_abstract => {
                if (p.peekTag(1) == .keyword_new) return p.parseConstructorType(true);
            },
            else => {},
        }
        return p.parseUnionType();
    }

    /// Standalone constructor type `new (params) => R` / `abstract new … => R`
    /// `abstract` (already at cursor) is consumed first when present.
    fn parseConstructorType(p: *Parser, is_abstract: bool) PE!Node {
        const start_tok = p.curIdx();
        if (is_abstract) _ = try p.bump(); // `abstract`
        _ = try p.bump(); // `new`
        var tp: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.atLt()) tp = try p.parseTypeParams(.callable);
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
        return p.addNode(.{ .tag = .constructor_type, .main_token = start_tok, .data = .{ .lhs = proto, .rhs = @intFromBool(is_abstract) } });
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
        if (p.atLt()) tp = try p.parseTypeParams(.callable);
        const params = try p.parseParams();
        _ = try p.expect(.arrow, .expected_arrow);
        // Past the `=>` the function type is committed — a parenthesized type
        // is no longer a live alternative — so clear the speculation flag for
        // the return type, exactly as `parseParam` does for a parameter's
        // annotation. Without this the `spec == 0` guard in `parseType` refuses
        // a conditional nested inside the return type, the enclosing type
        // argument list then fails, and the whole function type backtracks into
        // a parenthesized type (rxjs's `bindCallback.d.ts`:
        // `(...arg: A) => Observable<R extends [] ? void : …>`).
        const ret = blk: {
            const saved_spec = p.spec;
            p.spec = 0;
            defer p.spec = saved_spec;
            break :blk try p.parseReturnType();
        };
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
            .keyword_unique => {
                // `unique symbol`: a nominal symbol type. Any other
                // `unique T` is out of subset.
                if (p.peekTag(1) == .keyword_symbol) {
                    const kw = try p.bump(); // `unique`
                    _ = try p.bump(); // `symbol`
                    return p.addNode(.{ .tag = .unique_symbol_type, .main_token = kw, .data = .{ .lhs = 0, .rhs = 0 } });
                }
                const start = try p.bump();
                _ = try p.parseTypeOperator();
                return p.unsupportedFrom(start);
            },
            .keyword_infer => {
                // `infer V`: a binder introduced in a conditional type's
                // extends clause, optionally with a TS 4.8 constraint
                // (`infer V extends C`) — kept, because it decides the
                // conditional: an inference that does not satisfy `C` takes
                // the FALSE branch.
                const kw = try p.bump();
                const name = try p.expectIdentLike();
                var constraint: Node = null_node;
                if (p.curTag() == .keyword_extends and !p.nlBefore()) {
                    _ = try p.bump();
                    constraint = try p.parseNonConditionalType();
                }
                return p.addNode(.{ .tag = .infer_type, .main_token = kw, .data = .{ .lhs = name, .rhs = constraint } });
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
                const inner = if (p.curTag() == .keyword_import)
                    // `typeof import("m")[.value]`.
                    try p.parseImportType()
                else if (p.curTag() == .keyword_this)
                    // `typeof this[.a.b]` — a type query may name the `this`
                    // VALUE, which no other entity-name position may. Seeded
                    // as `.this_expr` so the checker reads the enclosing
                    // declaration's `this`, not a name called "this".
                    try p.parseEntityNameFrom(try p.leaf(.this_expr))
                else
                    try p.parseEntityName();
                // `typeof f<T>` — a type-position instantiation expression.
                // A line break before the `<` ends the type query (tsc applies
                // ASI here so the next line's `<` is not swallowed).
                var targs: u32 = 0;
                if (p.atLt() and !p.nlBefore()) {
                    targs = try p.addExtra(try p.parseTypeArgs());
                }
                return p.addNode(.{ .tag = .typeof_type, .main_token = kw, .data = .{ .lhs = inner, .rhs = targs } });
            },
            .l_brace => return p.parseObjectType(),
            .l_bracket => return p.parseTupleType(),
            .l_paren => {
                const lp = try p.bump();
                const inner = try p.parseType();
                _ = try p.expect(.r_paren, .expected_r_paren);
                return p.addNode(.{ .tag = .paren_type, .main_token = lp, .data = .{ .lhs = inner, .rhs = 0 } });
            },
            .template_head, .no_substitution_template_literal => return p.parseTemplateLiteralType(),
            .keyword_import => return p.parseImportType(),
            .unknown, .hash_bang, .binary_content => {
                if (p.spec > 0) return error.Backtrack;
                try p.errAtJunkToken();
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
        return p.parseEntityNameFrom(try p.leaf(.identifier));
    }

    /// The `.B.C` tail of an entity name, over an already-parsed head.
    fn parseEntityNameFrom(p: *Parser, head: Node) PE!Node {
        var name = head;
        while (p.curTag() == .dot) {
            const dot = try p.bump();
            const part = try p.expectMemberName();
            name = try p.addNode(.{ .tag = .qualified_name, .main_token = dot, .data = .{ .lhs = name, .rhs = part } });
        }
        return name;
    }

    /// `import("m")[.A.B][<args>]` in type position. Builds an
    /// `.import_type` node (specifier string token in `lhs`), wraps qualifiers
    /// in `qualified_name`, and type arguments in `type_ref` — so the checker
    /// resolves it the same way it resolves `Ns.T<...>`.
    fn parseImportType(p: *Parser) PE!Node {
        const kw = try p.bump(); // import
        _ = try p.expect(.l_paren, .expected_l_paren);
        var spec_tok: u32 = 0;
        if (p.curTag() == .string_literal) {
            spec_tok = p.curIdx();
            _ = try p.bump();
        } else {
            try p.fail(.expected_type);
        }
        // Tolerate `import("m", { with: {...} })` assertions: skip to `)`.
        while (p.curTag() != .r_paren and p.curTag() != .eof) _ = try p.bump();
        _ = try p.expect(.r_paren, .expected_r_paren);
        var ty = try p.addNode(.{ .tag = .import_type, .main_token = kw, .data = .{ .lhs = spec_tok, .rhs = 0 } });
        while (p.curTag() == .dot) {
            const dot = try p.bump();
            const part = try p.expectMemberName();
            ty = try p.addNode(.{ .tag = .qualified_name, .main_token = dot, .data = .{ .lhs = ty, .rhs = part } });
        }
        if (p.atLt()) {
            const lt_tok = p.curIdx();
            const targs = try p.parseTypeArgs();
            const extra = try p.addExtra(targs);
            ty = try p.addNode(.{ .tag = .type_ref, .main_token = lt_tok, .data = .{ .lhs = ty, .rhs = extra } });
        }
        return ty;
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
                // Named rest element `...name: T[]`: the label is
                // cosmetic — drop it and parse the element type.
                if (isIdentLike(p.curTag()) and p.peekTag(1) == .colon) {
                    _ = try p.bump(); // name
                    _ = try p.bump(); // ':'
                }
                const ty = try p.parseType();
                try p.pushScratch(try p.addNode(.{ .tag = .rest_type, .main_token = dots, .data = .{ .lhs = ty, .rhs = 0 } }));
            } else if (isIdentLike(p.curTag()) and
                (p.peekTag(1) == .colon or (p.peekTag(1) == .question and p.peekTag(2) == .colon)))
            {
                // Named tuple member `[x: T]` / `[x?: T]`: the label is
                // cosmetic (a display aid); the element type is `T`, optional
                // iff `?` is present. (The all-or-none-labeled rule TS5084 is
                // not enforced — an under-report, never a false positive.)
                _ = try p.bump(); // name
                const q_tok = try p.eat(.question);
                _ = try p.bump(); // ':'
                var ty = try p.parseType();
                if (q_tok) |q| ty = try p.addNode(.{ .tag = .optional_type, .main_token = q, .data = .{ .lhs = ty, .rhs = 0 } });
                try p.pushScratch(ty);
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
        const lb = try p.bump(); // '{'
        // Mapped type `{ [K in C as N]: V }`: after an optional
        // `readonly`/`+`/`-` modifier the shape is `[ ident in`. The `readonly`
        // form is only distinguishable from a `readonly [k: K]: V` index
        // signature by the token after the key ident (`in` vs `:`), which is
        // why the `{` is consumed first (so the check fits the lookahead).
        var flags: u32 = 0;
        var is_mapped = false;
        if (p.curTag() == .plus and p.peekTag(1) == .keyword_readonly) {
            _ = try p.bump();
            _ = try p.bump();
            flags |= ast.mapped_flag_readonly_add;
            is_mapped = true;
        } else if (p.curTag() == .minus and p.peekTag(1) == .keyword_readonly) {
            _ = try p.bump();
            _ = try p.bump();
            flags |= ast.mapped_flag_readonly_remove;
            is_mapped = true;
        } else if (p.curTag() == .keyword_readonly and p.peekTag(1) == .l_bracket and
            isIdentLike(p.peekTag(2)) and p.peekTag(3) == .keyword_in)
        {
            _ = try p.bump();
            flags |= ast.mapped_flag_readonly_add;
            is_mapped = true;
        } else if (p.curTag() == .l_bracket and isIdentLike(p.peekTag(1)) and p.peekTag(2) == .keyword_in) {
            is_mapped = true;
        }
        if (is_mapped) return p.parseMappedType(lb, flags);
        const members = try p.parseTypeMembersRest();
        return p.addNode(.{ .tag = .object_type, .main_token = lb, .data = .{ .lhs = members.start, .rhs = members.end } });
    }

    /// Template-literal type `` `head${T}mid${U}tail` ``. Mirrors
    /// `parseTemplateExpr`'s head/middle/tail token loop, but each substitution
    /// is a *type* (not an expression). The hole type nodes are stored as one
    /// SubRange; the chunk tokens (middle/tail) as a parallel range so the
    /// checker can read each hole's trailing literal text.
    fn parseTemplateLiteralType(p: *Parser) PE!Node {
        if (p.curTag() == .no_substitution_template_literal) {
            const tok = try p.bump();
            const extra = try p.addExtra(ast.TemplateLitType{
                .holes_start = 0,
                .holes_end = 0,
                .chunks_start = 0,
                .chunks_end = 0,
            });
            return p.addNode(.{ .tag = .template_literal_type_node, .main_token = tok, .data = .{ .lhs = extra, .rhs = 0 } });
        }
        const head = try p.bump(); // template_head
        var chunk_toks: std.ArrayList(u32) = .empty;
        defer chunk_toks.deinit(p.gpa);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (true) {
            try p.pushScratch(try p.parseType());
            if (p.curTag() != .r_brace) {
                try p.fail(.expected_r_brace);
                break;
            }
            p.rescanTemplatePart();
            switch (p.curTag()) {
                .template_middle => {
                    try chunk_toks.append(p.gpa, p.curIdx());
                    _ = try p.bump();
                    continue;
                },
                .template_tail => {
                    try chunk_toks.append(p.gpa, p.curIdx());
                    _ = try p.bump();
                    break;
                },
                .unterminated_template => {
                    try p.errAtCurEnd(.unterminated_template);
                    _ = try p.bump();
                    break;
                },
                else => break,
            }
        }
        const holes = try p.scratchToSpan(top);
        const chunks = try p.listToSpan(chunk_toks.items);
        const extra = try p.addExtra(ast.TemplateLitType{
            .holes_start = holes.start,
            .holes_end = holes.end,
            .chunks_start = chunks.start,
            .chunks_end = chunks.end,
        });
        return p.addNode(.{ .tag = .template_literal_type_node, .main_token = head, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    /// Parse a mapped type body after `{` and any leading readonly modifier
    /// have been consumed (`flags` carries the readonly modifier already).
    fn parseMappedType(p: *Parser, lb: u32, flags_in: u32) PE!Node {
        var flags = flags_in;
        _ = try p.expect(.l_bracket, .expected_type);
        const key_name_token = try p.expectIdentLike();
        _ = try p.expect(.keyword_in, .expected_type);
        const constraint = try p.parseType();
        // `as N` key remap (optional).
        var as_type: Node = null_node;
        if (p.curTag() == .keyword_as) {
            _ = try p.bump();
            as_type = try p.parseType();
        }
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        // optional modifier: `?` / `+?` / `-?`.
        if (p.curTag() == .plus and p.peekTag(1) == .question) {
            _ = try p.bump();
            _ = try p.bump();
            flags |= ast.mapped_flag_optional_add;
        } else if (p.curTag() == .minus and p.peekTag(1) == .question) {
            _ = try p.bump();
            _ = try p.bump();
            flags |= ast.mapped_flag_optional_remove;
        } else if (p.curTag() == .question) {
            _ = try p.bump();
            flags |= ast.mapped_flag_optional_add;
        }
        var value: Node = null_node;
        if (try p.eat(.colon) != null) value = try p.parseType();
        _ = try p.eat(.semicolon);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const extra = try p.addExtra(ast.MappedTypeData{
            .key_name_token = key_name_token,
            .constraint = constraint,
            .as_type = as_type,
            .value = value,
            .flags = flags,
        });
        return p.addNode(.{ .tag = .mapped_type_node, .main_token = lb, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    /// `{ member; member, ... }` shared by interfaces and object types.
    fn parseTypeMemberList(p: *Parser) PE!ast.SubRange {
        _ = try p.expect(.l_brace, .expected_l_brace);
        return p.parseTypeMembersRest();
    }

    /// The member loop after the opening `{` has been consumed. Shared with the
    /// mapped-type detection path, which must consume `{` before deciding.
    fn parseTypeMembersRest(p: *Parser) PE!ast.SubRange {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            const diags_before = p.diags.items.len;
            try p.pushScratch(try p.parseTypeMember());
            // Separators: `;` or `,`, or just a newline.
            _ = try p.eat(.semicolon) orelse try p.eat(.comma);
            if (p.curIdx() == before) {
                // `parseTypeMember` already reported TS1131 at this token when
                // it failed on the member name; one diagnostic per token is
                // what tsc emits, so do not double it.
                if (p.diags.items.len == diags_before) try p.errAtCur(.expected_type_member);
                _ = try p.bump();
            }
        }
        _ = try p.expect(.r_brace, .expected_r_brace);
        return p.scratchToSpan(top);
    }

    fn parseTypeMember(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        var flags: u32 = 0;

        // Call signature `(...): R` / `<T>(...): R`. A bare `(`/`<`
        // starting a member is a call signature (interfaces have no positional
        // members, so this never conflicts with a parenthesized name).
        if (p.curTag() == .l_paren or p.atLt()) {
            const proto = try p.parseFnProtoRest(0, 0);
            return p.addNode(.{ .tag = .call_signature, .main_token = start_tok, .data = .{ .lhs = proto, .rhs = 0 } });
        }
        // Construct signature `new (...): R` / `new <T>(...): R`.
        if (p.curTag() == .keyword_new and (p.peekTag(1) == .l_paren or p.peekTag(1) == .lt or p.peekTag(1) == .lt_lt)) {
            _ = try p.bump(); // `new`
            const proto = try p.parseFnProtoRest(0, 0);
            return p.addNode(.{ .tag = .construct_signature, .main_token = start_tok, .data = .{ .lhs = proto, .rhs = 0 } });
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
            // `['data-state']: string` / `[0]: T`. A computed key whose
            // expression is a literal is late-bound to exactly that literal's
            // own name, so it is indistinguishable from writing the name
            // directly (bluesky's `RadixPassThroughTriggerProps`).
            if ((p.peekTag(1) == .string_literal or p.peekTag(1) == .numeric_literal) and
                p.peekTag(2) == .r_bracket)
            {
                _ = try p.bump(); // `[`
                name_tok = try p.bump(); // literal
                _ = try p.eat(.r_bracket);
            }
            // Well-known-symbol key `[Symbol.iterator](): T` — keyed by a
            // synthetic atom, then parsed as an ordinary member below.
            else if (try p.eatWellKnownSymbolName()) |ntok| {
                name_tok = ntok;
                flags |= ast.Flags.computed;
            } else if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .r_bracket) {
                // `[k]` naming a const `unique symbol` (typebox's `[Kind]: 'X'`,
                // drizzle's interface `[entityKind]: string`). Keyed by the
                // symbol's nominal id, resolved by the checker.
                _ = try p.bump(); // `[`
                name_tok = try p.bump(); // identifier
                _ = try p.eat(.r_bracket);
                flags |= ast.Flags.computed | ast.Flags.computed_sym;
            } else if (isIdentLike(p.peekTag(1)) and p.peekTag(2) == .dot and
                isIdentLike(p.peekTag(3)) and p.peekTag(4) == .r_bracket)
            {
                // `[a.b]` member-expression computed key (util's
                // `[promisify.custom]: TCustom`, rxjs's `[Symbol.observable]`
                // for a non-well-known `Symbol` member). Keyed by the member's
                // nominal symbol id, resolved by the checker; the object
                // identifier sits at `name_tok - 2`.
                _ = try p.bump(); // `[`
                _ = try p.bump(); // object identifier
                _ = try p.bump(); // `.`
                name_tok = try p.bump(); // member identifier
                _ = try p.eat(.r_bracket);
                flags |= ast.Flags.computed | ast.Flags.computed_sym | ast.Flags.computed_sym_qual;
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

    fn parseIndexSignature(p: *Parser, flags: u32) PE!Node {
        const lb = try p.bump(); // '['
        const name_tok = try p.expectIdentLike();
        _ = try p.expect(.colon, .expected_colon);
        const key_type = try p.parseType();
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        _ = try p.expect(.colon, .expected_colon);
        const value_type = try p.parseType();
        // A type-literal member list separates with `;` OR `,`
        // (`{ [k: string]: E, [k: number]: E }` is legal and common); the
        // member loop eats the separator, so a `,` here is not a missing
        // semicolon. Without this, that shape reported a false TS1005 — and a
        // false parse error suppresses the whole file's semantic pass.
        if (p.curTag() != .comma) try p.expectSemicolon();
        const extra = try p.addExtra(ast.IndexSig{ .name_token = name_tok, .key_type = key_type, .value_type = value_type });
        return p.addNode(.{ .tag = .index_signature, .main_token = lb, .data = .{ .lhs = extra, .rhs = flags } });
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const source = @import("source.zig");

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

test "golden: ambient context marks declarators `declare`" {
    // `declare` leaves no bit on the variable statement (it starts at `var`),
    // so each declarator carries the ambient context itself.
    try expectSExpr("declare var x: number;",
        \\(var_decl_one var (declarator_full :declare (identifier x) (identifier number)))
    );
    try expectSExpr("declare namespace N { let m: number; }",
        \\(namespace_decl :declare N (var_decl_one let (declarator_full :declare (identifier m) (identifier number))))
    );
    try expectSExpr("declare global { var g: string; }",
        \\(namespace_decl :declare global (var_decl_one var (declarator_full :declare (identifier g) (identifier string))))
    );
    // …and only there: the context is restored on the way out.
    try expectSExpr("declare var x: number; let y: number;",
        \\(var_decl_one var (declarator_full :declare (identifier x) (identifier number)))
        \\(var_decl_one let (declarator_full (identifier y) (identifier number)))
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

test "golden: instantiation expressions (TS 4.7)" {
    // No argument list, and `;` starts no expression: an instantiation
    // expression, not `f < T > (nothing)`.
    try expectSExpr("g = f<T>;",
        \\(expr_stmt (assign = (identifier g) (instantiation_expr (identifier f) (identifier T))))
    );
    // Same where a `,` follows.
    try expectSExpr("x = [f<T>, g<U>];",
        \\(expr_stmt (assign = (identifier x) (array_literal (instantiation_expr (identifier f) (identifier T)) (instantiation_expr (identifier g) (identifier U)))))
    );
    // An identifier CAN start an expression: relational, as in tsc.
    try expectSExpr("x = a < b > c;",
        \\(expr_stmt (assign = (identifier x) (binary > (binary < (identifier a) (identifier b)) (identifier c))))
    );
    // `+` and `-` read as unary operators here, so they too keep the
    // relational reading.
    try expectSExpr("x = a < b > +c;",
        \\(expr_stmt (assign = (identifier x) (binary > (binary < (identifier a) (identifier b)) (prefix_unary + (identifier c)))))
    );
    // An argument list still wins: a generic call, not an instantiation.
    try expectSExpr("f<T>(x);",
        \\(expr_stmt (call_expr_targs (identifier f) (identifier T) (identifier x)))
    );
    // A `new` callee's `<T>` belongs to the `new`, with or without arguments.
    try expectSExpr("x = new C<T>;",
        \\(expr_stmt (assign = (identifier x) (new_expr_targs (identifier C) (identifier T))))
    );
    try expectSExpr("x = new C<T>(a);",
        \\(expr_stmt (assign = (identifier x) (new_expr_targs (identifier C) (identifier T) (identifier a))))
    );
    // A heritage clause's `<T>` belongs to the clause, even when a `,`
    // follows and would otherwise read as an instantiation expression.
    try expectSExpr("interface I extends A<T>, B {}",
        \\(interface_decl I (heritage (identifier A) (identifier T)) (heritage (identifier B)))
    );
    // Type position: `typeof f<T>` is a type query with type arguments.
    try expectSExpr("type R = typeof f<T>;",
        \\(type_alias R (typeof_type (identifier f) (identifier T)))
    );
    // A line break before the `<` ends the type query (ASI).
    try expectSExpr("type R = typeof f;",
        \\(type_alias R (typeof_type (identifier f)))
    );
}

test "instantiation speculation restores the speculation depth" {
    // A `<…>` that backtracks must leave `spec` exactly as it found it — the
    // `parseType` guards keyed on it (a conditional type's `extends`, the
    // out-of-subset reporter) silently mis-parse everything after the leak.
    // The relational statement below backtracks out of a type-argument list;
    // the conditional type after it is the canary.
    try expectSExpr("x = a < b > c;\ntype C<T> = T extends string ? 1 : 2;",
        \\(expr_stmt (assign = (identifier x) (binary > (binary < (identifier a) (identifier b)) (identifier c))))
        \\(type_alias C (type_param T) (conditional_type (identifier T) (identifier string) (number_literal 1) (number_literal 2)))
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

test "golden: import() types" {
    try expectSExpr("type T = import(\"m\").Foo;",
        \\(type_alias T (qualified_name (import_type "m") Foo))
    );
    try expectSExpr("type T = import(\"m\").Bar<A>;",
        \\(type_alias T (type_ref (qualified_name (import_type "m") Bar) (identifier A)))
    );
    try expectSExpr("type T = import(\"m\").NS.Inner;",
        \\(type_alias T (qualified_name (qualified_name (import_type "m") NS) Inner))
    );
    try expectSExpr("type T = typeof import(\"m\");",
        \\(type_alias T (typeof_type (import_type "m")))
    );
    try expectSExpr("type T = typeof import(\"m\").val;",
        \\(type_alias T (typeof_type (qualified_name (import_type "m") val)))
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
    // `export default function` may be anonymous — the one declaration
    // form the grammar lets go unnamed. A plain one still may not.
    try expectSExpr("export default function (a: number) {}",
        \\(export_default (function_decl (param (identifier a) (identifier number)) (block)))
    );
    try expectDiagCount("function (a: number) {}", 1);
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
    // ModuleExportName: `default` (a reserved word) is legal in both the name
    // and alias positions of a specifier — the renamed-default re-export used
    // by uuid/react-spinners barrels, and re-exporting a binding as default.
    try expectSExpr("export { default as v4 } from \"mod\";",
        \\(export_named from="mod" (export_specifier default as=v4))
    );
    try expectSExpr("export { Foo as default };",
        \\(export_named (export_specifier Foo as=default))
    );
    try expectSExpr("import { default as v4 } from \"mod\";",
        \\(import_decl from="mod" (import_specifier default as=v4))
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
    // `declare module "spec"` (ambient module / augmentation) is in subset as
    // of the ambient-modules work; `declare global` too. Non-`declare` string modules stay
    // out of subset.
    try expectDiagCount("declare module \"foo\" { export function f(): void; }", 0);
    try expectDiagCount("module \"bar\" { export const x = 1; }", 1);
    try expectDiagCount("declare global { interface Window {} }", 0);
}

test "decorators: parsed into the AST (no longer out of subset)" {
    // A class decorator parses cleanly (no parser diagnostic) as a sibling
    // `.decorator` node preceding the class. The expression is an LHS
    // expression — here a decorator factory call `@Component({...})`.
    try expectDiagCount("@Component({selector: \"x\"}) class Foo {}", 0);
    // Member decorators become `.decorator` member nodes in the class body.
    try expectDiagCount("class A { @observable x = 1; }", 0);
    // Structure: `@a.b` property-access decorator + accessor member decorator.
    try expectSExpr("@a.b class Foo {}",
        \\(decorator (member_expr (identifier a) b))
        \\(class_decl Foo)
    );
}

test "template literal types parse in subset" {
    try expectDiagCount("type T = `prefix-${string}`;", 0);
    try expectDiagCount("type U<A, B> = `${A}-${B}`;", 0);
    try expectDiagCount("type P = `plain`;", 0);
    try expectDiagCount("type N = `x${`y${1}`}z`;", 0);
    try expectSExpr("type T = `a${string}b${number}`;",
        \\(type_alias T (template_literal_type_node (identifier string) (identifier number)))
    );
}

test "mapped types parse in subset" {
    try expectDiagCount("type M = { [K in Keys]: boolean };", 0);
    try expectDiagCount("type P<T> = { [K in keyof T]?: T[K] };", 0);
    try expectDiagCount("type R<T> = { readonly [K in keyof T]: T[K] };", 0);
    try expectDiagCount("type Q<T> = { -readonly [K in keyof T]-?: T[K] };", 0);
    try expectDiagCount("type O<T, X> = { [K in keyof T as X]: T[K] };", 0);
    try expectSExpr("type M = { [K in Keys]: boolean };",
        \\(type_alias M (mapped_type_node (identifier Keys) (identifier boolean)))
    );
}

test "conditional types and infer parse in subset" {
    // Conditional types and `infer` binders are now real AST nodes.
    try expectDiagCount("type C<T> = T extends string ? 1 : 0;", 0);
    try expectDiagCount("type E<T> = T extends Array<infer U> ? U : never;", 0);
    try expectDiagCount("type R<T> = T extends (...a: any[]) => infer R ? R : never;", 0);
    // Nested conditional in the true branch.
    try expectDiagCount("type N<T> = T extends string ? T extends \"a\" ? 1 : 2 : 3;", 0);
    try expectSExpr("type C<T> = T extends string ? 1 : 0;",
        \\(type_alias C (type_param T) (conditional_type (identifier T) (identifier string) (number_literal 1) (number_literal 0)))
    );
}

test "import= and export= parse in subset (CommonJS)" {
    try expectDiagCount("import x = require(\"m\");", 0);
    try expectDiagCount("export = thing;", 0);
    try expectDiagCount("import A = B.C;", 0);
    try expectSExpr("import x = require(\"m\");",
        \\(import_equals x require="m")
    );
    try expectSExpr("export = thing;",
        \\(export_assign (identifier thing))
    );
    try expectSExpr("import A = B.C;",
        \\(import_equals A (qualified_name (identifier B) C))
    );
}

test "unsupported: misc type-level constructs" {
    try expectDiagCount("type U = unique T;", 1); // `unique` non-symbol operand
}

test "named tuple members parse" {
    // Labels are cosmetic — the element types are preserved, label dropped.
    try expectDiagCount("type NT = [x: number, y: number];", 0);
    try expectDiagCount("type NR = [head: string, ...tail: number[]];", 0);
    try expectSExpr("type P = [x: number, y?: string];",
        \\(type_alias P (tuple_type (identifier number) (optional_type (identifier string))))
    );
}

test "call/construct signatures & constructor types parse" {
    // Bare call signature, construct signature, standalone constructor type,
    // and `abstract new` all parse cleanly (no more unsupported_syntax).
    try expectDiagCount("interface I { (x: number): string; }", 0); // call signature
    try expectDiagCount("interface I { new (x: number): Thing; }", 0); // construct signature
    try expectDiagCount("type F = new () => Thing;", 0); // constructor type
    try expectDiagCount("type AF = abstract new (x: number) => Thing;", 0);
    try expectDiagCount("interface I { <T>(x: T): T; new <T>(): T[]; }", 0); // generic sigs
    try expectSExpr("type F = new () => Thing;",
        \\(type_alias F (constructor_type (identifier Thing)))
    );
    try expectSExpr("interface C { (x: number): string; new (): C; readonly p: number; }",
        \\(interface_decl C (call_signature (param (identifier x) (identifier number)) (identifier string)) (construct_signature (identifier C)) (property_signature :readonly p (identifier number)))
    );
}

test "unique symbol parses in subset" {
    try expectDiagCount("const k: unique symbol = Symbol();", 0);
    try expectDiagCount("let m: unique symbol;", 0); // position error is a checker concern
    try expectDiagCount("declare const d: unique symbol;", 0);
}

test "type predicates parse cleanly" {
    try expectDiagCount("function f(x: unknown): x is string { return true; }", 0);
    try expectDiagCount("function f(x: unknown): asserts x is string {}", 0);
    try expectDiagCount("function f(c: unknown): asserts c {}", 0);
    try expectDiagCount("const f = (x: unknown): x is string => true;", 0);
}

test "unsupported: class oddities" {
    try expectDiagCount("class B { [computeKey()]() {} }", 1); // computed member name (non-symbol)
}

test "class static initialization block parses as a member block" {
    // The statements land in the tree with real spans (the body is not checked
    // yet — see `parseClassMember`). What must NOT happen is the old reading of
    // `static` as a FIELD name, which answered "';' expected" at the `{`.
    try expectDiagCount("class A { static { init(); } }", 0);
    try expectDiagCount("class A { static { const a = 1; a; } x = 2; }", 0);
    try expectSExpr("class A { static { f(); } }",
        \\(class_decl A (block (expr_stmt (call_expr (identifier f)))))
    );
}

test "new.target is a meta-property expression" {
    try expectSExpr("x = new.target;",
        \\(expr_stmt (assign = (identifier x) (new_target)))
    );
    try expectDiagCount("class C { constructor() { if (new.target) {} } }", 0);
    // `new.<anything else>` is not a meta-property; the boundary holds.
    try expectDiagCount("x = new.other;", 1);
}

test "well-known symbol computed member is in subset" {
    // `[Symbol.iterator]` methods parse cleanly (keyed by a synthetic atom).
    try expectDiagCount("class C { [Symbol.iterator]() {} }", 0);
    try expectDiagCount("interface I { [Symbol.iterator](): Iterator<number>; }", 0);
}

test "member-expression computed keys are in subset" {
    // `[a.b]` keys (node's `[EventEmitter.captureRejectionSymbol]`, util's
    // `[promisify.custom]`, rxjs's non-well-known `[Symbol.observable]`).
    try expectDiagCount("declare class C { [EventEmitter.captureRejectionSymbol]?<K>(error: Error): void; }", 0);
    try expectDiagCount("interface I { [promisify.custom]: number; }", 0);
    try expectDiagCount("interface O { [Symbol.observable]: () => number; }", 0);
    // Deeper qualification and non-name keys stay out of subset.
    try expectDiagCount("class B { [a.b.c]() {} }", 1);
    try expectDiagCount("interface J { [a.b.c]: number; }", 1);
}

test "jsx parses cleanly in tsx mode" {
    const cases = [_][]const u8{
        "const a = <div className=\"x\">hello</div>;",
        "const b = <Foo count={1} name=\"y\" />;",
        "const c = <><span>a</span>{x}</>;",
        "const d = <A.B prop=\"y\">child</A.B>;",
        "const e = <div {...props} id={f()} />;",
        "const g = <ul>{items.map(i => <li>{i}</li>)}</ul>;",
        // Hyphenated JSX names: `data-*`/`aria-*` attributes and a
        // custom-element tag lex as single names spanning `-`.
        "const h = <div data-foo=\"x\" aria-label=\"y\" />;",
        "const i = <my-widget data-n={1} />;",
        // A tag name rooted at `this`, self-closing and with children.
        "const j = <this.Component {...props} />;",
        "const k = <this.a.B x={1}>child</this.a.B>;",
        // An attribute string runs to the matching quote: raw line breaks
        // are content, `\` is literal, and `<`/`>`/`/`/`{` are content too.
        "const l = <div title=\"line one\nline two\" id=\"x\" />;",
        "const m = <div title='one\ntwo' />;",
        "const n = <div title=\"a\\b > c / d { e\" />;",
        // A JSX name is an IdentifierName, so reserved words are legal in both
        // the attribute and the tag position. The SVG filter primitives use
        // `in`/`in2`, and `for`/`class`/`default`/`if` all appear as attribute
        // names in real .tsx. Before this, `in="SourceAlpha"` ended the
        // attribute list and produced a cascade of "expected '>'".
        "const o = <feColorMatrix in=\"SourceAlpha\" in2=\"hardAlpha\" />;",
        "const p = <label for=\"x\" class=\"y\" default=\"z\" if=\"q\" />;",
        "const q = <Foo.default x={1} />;",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try parseOpts(arena.allocator(), src, .{ .jsx = true });
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
        const tree = try parseOpts(arena.allocator(), "const a = x < y;", .{});
        try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    }
}

test "jsx: a hyphenated name whose identifier part is escaped terminates" {
    // `rescanJsxName` merges `<name>-<name>` runs into one token by rescanning
    // from the token's START. `scanJsxName` used a bare `isIdentCont` loop, so
    // a name whose first character is a `\u` escape stopped on the backslash
    // and returned the start offset: a ZERO-LENGTH token, with the scanner
    // rewound onto it, which the parser then re-read forever. Only the
    // hyphenated forms hang — without a `-` the merge never runs — so the
    // escaped-but-unhyphenated cases are here to hold the pair together.
    //
    // These are all errors for tsc (TS17021, "Unicode escape sequence cannot
    // appear here"), which ztsc does not report; what is under test is that
    // parsing TERMINATES and consumes the name, not the diagnostic.
    const cases = [_][]const u8{
        "; <\\u0061-b></a-b>;",
        "; <\\u{0061}-b></a-b>;",
        "; <a-\\u0063></a-c>;",
        "; <a-\\u{0063}></a-c>;",
        "; <\\u0061></a>;",
        "; <\\u{0061}></a>;",
        "; <Comp\\u{0061} x={12} />;",
        "; <x.\\u0076ideo />;",
        ";<video data-\\u0076ideo />;",
        ";<video \\u0073rc=\"\" />;",
        // A malformed escape must not merge either: `\u` with no digits is
        // not an identifier escape, so the name is left exactly as lexed.
        "; <\\u-b></a-b>;",
        "; <\\-b></a-b>;",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try parseOpts(arena.allocator(), src, .{ .jsx = true });
        // Termination is the assertion; the tree must still cover the source.
        try testing.expect(tree.nodes.len > 0);
    }
}

test "scanJsxName spans escapes, non-ASCII and hyphens, and always advances" {
    // Exactly `identifierRest`'s span plus `-`.
    try testing.expectEqual(@as(u32, 5), scanner.scanJsxName("a-b-c", 0));
    try testing.expectEqual(@as(u32, 8), scanner.scanJsxName("data-foo", 0));
    // A leading escape is consumed, and so is the `-name` run after it.
    try testing.expectEqual(@as(u32, 8), scanner.scanJsxName("\\u0061-b", 0));
    try testing.expectEqual(@as(u32, 10), scanner.scanJsxName("\\u{0061}-b", 0));
    // An escape in the middle, and a non-ASCII identifier byte.
    try testing.expectEqual(@as(u32, 8), scanner.scanJsxName("a-\\u0063", 0));
    try testing.expectEqual(@as(u32, 5), scanner.scanJsxName("caf\xC3\xA9", 0));
    // A malformed escape stops the scan rather than consuming a partial one.
    try testing.expectEqual(@as(u32, 0), scanner.scanJsxName("\\u-b", 0));
    // Stopping at the start is exactly the case `rescanJsxName` must refuse to
    // install, since it would rewind the scanner onto the same token.
    try testing.expectEqual(@as(u32, 0), scanner.scanJsxName("+b", 0));
}

test "jsx name rescan does not disturb subtraction lexing" {
    // The `-`-spanning JSX name scan is entered only in JSX name position;
    // in expression position `-` must still lex as subtraction, even in
    // `.tsx` files (jsx on) where the rescan machinery is live.
    inline for (.{ "const j = a-b;", "const k = x - 1;", "const l = a-b-c;" }) |src| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try parseOpts(arena.allocator(), src, .{ .jsx = true });
        try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
        const got = try dumpSource(arena.allocator(), src);
        // A binary `-` node, not a single merged identifier token.
        try testing.expect(std.mem.indexOf(u8, got, "(binary -") != null);
    }
}

test "unsupported constructs still leave following code parsable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "type C = unique Foo;\nconst after: number = 1;";
    const tree = try parse(arena.allocator(), src);
    try testing.expect(tree.diagnostics.len >= 1);
    const got = try dumpSource(arena.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, got, "(var_decl_one const (declarator_full (identifier after) (identifier number) (number_literal 1)))") != null);
}

// --- error recovery ----------------------------------------------------------------

/// The (code, 1-based line, 1-based column) of every parse diagnostic, in the
/// order recorded — the shape the TS-suite oracle compares, so a position
/// regression shows up here rather than only in a 20-minute sweep.
fn expectDiags(src: []const u8, opts: Opts, expected: []const struct { u16, u32, u32 }) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tree = try parseOpts(alloc, src, opts);
    var got: std.ArrayList(u8) = .empty;
    var want: std.ArrayList(u8) = .empty;
    for (tree.diagnostics) |d| {
        var line: u32 = 1;
        var col: u32 = 1;
        for (src[0..@min(d.span.start, src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        try got.print(alloc, "TS{d} {d}:{d}\n", .{ d.code.tsCode(), line, col });
    }
    for (expected) |e| try want.print(alloc, "TS{d} {d}:{d}\n", .{ e[0], e[1], e[2] });
    try testing.expectEqualStrings(want.items, got.items);
}

test "literal grammar: octal, leading zeros, empty radix, bad escapes" {
    // Codes and columns are tsgo 7.0.2's, verified by running both compilers
    // over these exact lines.
    try expectDiags("var a = 010;\n", .{}, &.{.{ 1121, 1, 9 }});
    try expectDiags("var a = 08;\n", .{}, &.{.{ 1489, 1, 9 }});
    try expectDiags("var a = 0x;\n", .{}, &.{.{ 1125, 1, 11 }});
    try expectDiags("var a = 0b;\n", .{}, &.{.{ 1177, 1, 11 }});
    try expectDiags("var a = 0o;\n", .{}, &.{.{ 1178, 1, 11 }});
    try expectDiags("var a = \"\\101\";\n", .{}, &.{.{ 1487, 1, 10 }});
    try expectDiags("var a = \"\\8\";\n", .{}, &.{.{ 1488, 1, 10 }});
    try expectDiags("var a = \"\\x1\";\n", .{}, &.{.{ 1125, 1, 13 }});
    try expectDiags("var a = \"\\u12\";\n", .{}, &.{.{ 1125, 1, 14 }});
    try expectDiags("var a = \"\\u{110000}\";\n", .{}, &.{.{ 1198, 1, 13 }});
    // Clean literals stay clean, `\0` alone is the NUL escape, and a tagged
    // template's raw text is the tag's business (so templates are not walked).
    try expectDiags("var a = 0;\nvar b = 0.5;\nvar c = 0x1F;\nvar d = 0o17;\nvar e = 0b101;\nvar f = 1e10;\nvar g = 10n;\n", .{}, &.{});
    try expectDiags("var h = \"a\\nb\\0c\\x41\\u0041\\u{1F600}\";\n", .{}, &.{});
    try expectDiags("var t = tag`\\101`;\n", .{}, &.{});
}

test "ambient context: TS1036 once per block, TS1183 on a body" {
    try expectDiags("declare namespace N { var a: number; a; }\n", .{}, &.{.{ 1036, 1, 38 }});
    // One per containing block: the second `a;` is silent, the nested block's
    // own statement is not.
    try expectDiags("declare namespace N { var a: number; a; a; { a; } }\n", .{}, &.{
        .{ 1036, 1, 38 }, .{ 1036, 1, 46 },
    });
    try expectDiags("declare namespace N { ; }\n", .{}, &.{.{ 1036, 1, 23 }});
    // Declarations are what an ambient context is for.
    try expectDiags("declare namespace N { var a: number; function f(): void; class C {} interface I {} type T = number; enum E {} namespace M {} }\n", .{}, &.{});
    // A body reports on its `{` and suppresses the statements inside it.
    try expectDiags("declare function f(): void { return; }\n", .{}, &.{.{ 1183, 1, 28 }});
    try expectDiags("declare class C { m() { } }\n", .{}, &.{.{ 1183, 1, 23 }});
    // A `.d.ts` is ambient throughout.
    try expectDiags("declare var a: number;\na;\n", .{ .dts = true }, &.{.{ 1036, 2, 1 }});
    // A statement that consumes no tokens must not be blamed on a token that
    // does not exist. This `.d.ts` — a `with` statement, which ztsc's parser has
    // no production for — indexed one past the token array and crashed the run,
    // so the assertion is only that it comes back at all, with every span inside
    // the file.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const src = "with (foo) {\n}\n";
        const tree = try parseOpts(arena.allocator(), src, .{ .dts = true });
        for (tree.diagnostics) |d| try testing.expect(d.span.end <= src.len + 1);
    }
}

test "TS1028: one accessibility modifier per member" {
    try expectDiags("class C { public private x = 1; }\n", .{}, &.{.{ 1028, 1, 18 }});
    try expectDiags("class C { constructor(public private x: number) {} }\n", .{}, &.{.{ 1028, 1, 30 }});
    // tsc returns out of its modifier walk on the first hit: one, not two.
    try expectDiags("class C { public protected private x = 1; }\n", .{}, &.{.{ 1028, 1, 18 }});
    try expectDiags("class C { public a = 1; private b = 2; protected c = 3; static d = 4; }\n", .{}, &.{});
}

test "TS1212/1213/1214: a strict-reserved word as an Identifier" {
    try expectDiags("var yield = 1;\n", .{}, &.{.{ 1212, 1, 5 }});
    try expectDiags("var package = 1;\nvar interface = 2;\nvar let = 3;\n", .{}, &.{
        .{ 1212, 1, 5 }, .{ 1212, 2, 5 }, .{ 1212, 3, 5 },
    });
    try expectDiags("function f(public: number) { return public; }\n", .{}, &.{
        .{ 1212, 1, 12 }, .{ 1212, 1, 37 },
    });
    // A class body is strict on its own account, a module likewise.
    try expectDiags("class C { m() { var static = 1; } }\n", .{}, &.{.{ 1213, 1, 21 }});
    // An ambient declaration is exempt (tsc: `!(node.flags & NodeFlags.Ambient)`).
    try expectDiags("export declare namespace Foo {\n  export var static: any;\n}\n", .{}, &.{});
    try expectDiags("declare var yield: number;\n", .{}, &.{});
    try expectDiags("var yield: number;\n", .{ .dts = true }, &.{});
    try expectDiags("export var e = 1;\nvar static = 2;\n", .{}, &.{.{ 1214, 2, 5 }});
    // IdentifierName positions take every reserved word: a property name, a
    // member name, a member access, an export alias, an enum member. And a
    // modifier is a modifier.
    try expectDiags("var l = { yield: 1, static: 2 };\n", .{}, &.{});
    try expectDiags("class D { static = 1; public = 2; }\nvar v = d.static + d.public;\n", .{}, &.{});
    try expectDiags("var q = 1;\nexport { q as yield };\n", .{}, &.{});
    try expectDiags("enum Col { yield = 1, static = 2 }\n", .{}, &.{});
    // `yield` in expression position is a YieldExpression, not an identifier.
    try expectDiags("function* g() { yield 1; yield* [2]; }\n", .{}, &.{});
}

test "one parse diagnostic per position (tsc's parseErrorAtPosition rule)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Recovery reaches this token from three directions; tsc keeps the first.
    const tree = try parse(arena.allocator(), "var a = { + };\n");
    var seen: ?u32 = null;
    for (tree.diagnostics) |d| {
        if (d.code.class() != .syntactic) continue;
        if (seen) |s| try testing.expect(s != d.span.start);
        seen = d.span.start;
    }
}

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
fn checkSpansNested(tree: *const ast.Ast, src: []const u8, node: ast.Node, parent: source.Span) !void {
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
    const file_span: source.Span = .{ .start = 0, .end = @intCast(src.len) };
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
