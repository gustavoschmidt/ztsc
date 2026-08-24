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
const modifier_order = @import("modifier_order.zig");
const param_modifiers = @import("param_modifiers.zig");
const index_signature = @import("index_signature.zig");
const computed_member = @import("computed_member.zig");
const decorator_target = @import("decorator_target.zig");
const regexp = @import("regexp.zig");

const TokTag = scanner.Tag;
const Token = scanner.Token;
const Node = ast.Node;
const TokenIndex = ast.TokenIndex;
const null_node = ast.null_node;
const Code = diagnostics.Code;
const Span = source.Span;

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

/// The innermost function-like boundary a parse is inside. See `Parser.fn_ctx`.
const FnCtx = enum {
    /// No enclosing function body: a source file's or namespace's top level.
    none,
    /// A non-async function, method, accessor, arrow, or a class field
    /// initializer (tsc parses one as its own implicit function).
    sync,
    /// An `async` function, method or arrow — tsc's await context.
    async_fn,
    /// A class `static { … }` block — also an await context, and the only
    /// boundary with grammar rules of its own.
    static_block,

    /// Whether `await` is the operator here rather than an Identifier
    /// (tsc's `inAwaitContext`).
    fn awaits(k: FnCtx) bool {
        return k == .async_fn or k == .static_block;
    }
};

/// What a `break`/`continue` may jump to WITHOUT crossing a function boundary.
/// See `Parser.jump`; a jump that resolves to none of these from inside a
/// function is TS1107.
const JumpCtx = struct {
    /// Enclosing iteration statements — the target of an unlabeled
    /// `break`/`continue`.
    loops: u32 = 0,
    /// Enclosing `switch` statements — the target of an unlabeled `break`.
    switches: u32 = 0,
    /// Where this function's own labels start in `Parser.labels`. A label
    /// outside a function is invisible inside it, which is the whole point of
    /// resetting here.
    labels_base: usize = 0,
    /// Is there a function-like ancestor at all? A jump that resolves to
    /// nothing at a source file's top level is a DIFFERENT diagnostic (TS1104 /
    /// TS1105 / TS1115 / TS1116), so TS1107 only ever fires inside one.
    in_function: bool = false,
};

/// The three kinds of `node.parent` a statement can have, as far as tsc's
/// grammar checks care: `SourceFile`, `ModuleBlock`, and everything else.
const ElementHome = enum { source_file, module_block, other };

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

    /// What tsc's `node.parent` is for a declaration in the statement list now
    /// being parsed. Saved/restored around each body exactly like `ambient`.
    ///
    /// Two rules read it, and they need different cuts of the same fact — which
    /// is why it is one field and not two booleans that could drift:
    ///
    ///   * a class-member modifier in statement position is TS1044 ("cannot
    ///     appear on a module or namespace element") in a MODULE BODY (either
    ///     arm) and TS1184 ("Modifiers cannot appear here.") in `.other`, which
    ///     is tsc's `checkGrammarModifiers` testing the parent for
    ///     SourceFile-or-ModuleBlock;
    ///   * a `declare` modifier in an already ambient context is TS1038 only
    ///     when the parent is a MODULE BLOCK — tsc's test names that kind
    ///     alone, and a `.d.ts` file's top level (ambient, but a SourceFile) is
    ///     silent, measured.
    ///
    /// A SUBSTATEMENT position (`if (x) public var y = 1;`) inherits its
    /// enclosing list's answer rather than getting its own — tsc would say
    /// TS1184 there; no corpus case writes it.
    element_home: ElementHome = .source_file,

    /// Lookahead queue of scanned-but-not-consumed tokens; la[0] is current.
    la: [max_la]Token = undefined,
    la_len: u8 = 0,

    /// Merge-conflict marker offsets seen so far, for the TS1185 batch
    /// `flushConflictMarkers` appends. An accumulator because `fill` — where a
    /// marker is skipped — is infallible and so cannot allocate a diagnostic;
    /// a fixed buffer keeps it that way. A file with more than this many
    /// markers under-reports the rest, which no real file and no corpus case
    /// comes near (the largest writes four).
    conflict_markers: [16]u32 = undefined,
    conflict_marker_len: u8 = 0,

    tok_tags: std.ArrayList(TokTag) = .empty,
    tok_starts: std.ArrayList(u32) = .empty,
    nodes: std.MultiArrayList(ast.NodeItem) = .empty,
    extra: std.ArrayList(u32) = .empty,
    scratch: std.ArrayList(u32) = .empty,
    diags: std.ArrayList(ast.Diagnostic) = .empty,
    /// Retained computed member names, appended as each member is finished.
    /// Accumulator: node indices grow with creation order, so appending here
    /// keeps `ast.Ast.computed_keys` sorted by member node for the binary
    /// search `Ast.computedKey` does. Empty for almost every file.
    computed_keys: std.ArrayList(ast.ComputedKey) = .empty,

    /// Is the type-member list being parsed an INTERFACE body rather than an
    /// object type literal? The two share `parseTypeMember` and differ in one
    /// rule: which wording a non-late-bindable computed name gets (TS1169 vs
    /// TS1170, `computed_member.zig`). Saved/restored around each member list,
    /// so a type literal nested in an interface member answers for itself.
    in_interface_body: bool = false,

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

    /// Is the class whose body is being parsed `abstract`? Read only by
    /// `modifier_order.check`, whose two `abstract` PAIRS sit behind tsc's
    /// TS1244 ("abstract methods can only appear within an abstract class") and
    /// so must stay silent on a plain class's member. A flag rather than a
    /// counter because it describes the INNERMOST class body, and a nested class
    /// declaration restores the enclosing one's answer on the way out.
    abstract_class: bool = false,

    /// Is the class whose body is being parsed a class DECLARATION rather than a
    /// class expression? Read only by `decorator_target.zig`, for which legacy
    /// decorators reject every member of a class EXPRESSION. A flag rather than
    /// a counter for the same reason as `abstract_class`: it describes the
    /// innermost class body, and each nested class restores the enclosing
    /// answer on the way out.
    in_class_decl: bool = false,

    /// The innermost function-like boundary being parsed. tsc keeps the same
    /// information in two context bits (`NodeFlags.AwaitContext` plus the
    /// container kind); one enum is enough here because every rule that reads it
    /// asks about the INNERMOST boundary:
    ///
    ///   * `.async_fn` and `.static_block` are tsc's await context — `await` is
    ///     the operator, never an Identifier (TS1359 for a binding named
    ///     `await`, TS1109 when the operator has no operand);
    ///   * `.static_block` additionally earns the four static-block grammar
    ///     rules (TS18037 `await`, TS1163 `yield`, TS18041 `return`, TS18038
    ///     `for await`), all of which tsc reports only when the *innermost*
    ///     container is the block — a nested `async function` inside one is
    ///     ordinary async code;
    ///   * `.none` is "no function body at all", which is what TS1108 says
    ///     about a `return`.
    ///
    /// Set at every function-like boundary — a function/method/accessor body
    /// (with its parameters), an arrow body, a static block, and a class field
    /// initializer, which tsc parses outside the await context because the
    /// initializer runs as its own implicit function.
    fn_ctx: FnCtx = .none,

    /// tsc's `inYieldContext()`: is the innermost function-like boundary a
    /// GENERATOR? Set and restored at exactly the boundaries `fn_ctx` is, and a
    /// separate field because generator-ness cross-cuts sync/async (an `async
    /// function*` is both) — folding it in would double `FnCtx` for one bit.
    ///
    /// Nothing INHERITS it: an arrow, a static block and a class field
    /// initializer all turn it off, which is what makes `function* g() { return
    /// () => ({ b: yield 2 }) }` a TS1163 (`YieldExpression20_es6`).
    yield_ctx: bool = false,

    /// What a `break`/`continue` at this point may jump to, for TS1107. tsc
    /// walks out of the statement looking for an iteration statement, a
    /// `switch` or a matching label, and stops the moment it reaches a
    /// FUNCTION-LIKE — a jump may not cross one. Saved and restored at every
    /// function boundary, exactly where `fn_ctx` is.
    jump: JumpCtx = .{},

    /// The label names of the enclosing labeled statements, innermost last —
    /// the stack `JumpCtx.labels_base` slices. Mutable state because it is a
    /// scope stack, pushed and popped around each labeled statement's body.
    labels: std.ArrayList(u32) = .empty,

    /// tsc's `NodeFlags.DisallowConditionalTypesContext`: true while parsing a
    /// type position where a conditional type may not appear unparenthesized —
    /// the `extends` clause of a conditional type, and the constraint of an
    /// `infer T extends C`. Set by `disallowConditionalTypesAnd`'s two callers
    /// and CLEARED again on the way down into a postfix type, so a parenthesized
    /// or braced type (`(A extends B ? C : D)`, a mapped type's `in` clause)
    /// starts over with conditionals allowed — tsc's
    /// `allowConditionalTypesAnd(parsePostfixTypeOrHigher)`.
    ///
    /// One rule reads it: whether `infer T extends C` keeps its constraint or
    /// hands the `extends` back to an enclosing conditional type. See the
    /// `.keyword_infer` arm.
    no_cond_type: bool = false,
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
            .computed_keys = try out.dupe(ast.ComputedKey, p.computed_keys.items),
        };
    }

    // =====================================================================
    // token plumbing
    // =====================================================================

    fn fill(p: *Parser, n: usize) void {
        while (p.la_len <= n) {
            var t = p.scn.next();
            // A merge-conflict marker is TRIVIA (tsc's scanner `continue`s past
            // it whenever `skipTrivia` is set, which it is for a parser), so the
            // grammar never sees one. It carries a diagnostic, though, and this
            // path cannot allocate — hence the fixed side buffer.
            while (t.tag == .conflict_marker) {
                p.noteConflictMarker(t);
                const nl = t.newline_before;
                t = p.scn.next();
                t.newline_before = t.newline_before or nl;
            }
            p.la[p.la_len] = t;
            p.la_len += 1;
        }
    }

    /// Record the marker inside a `.conflict_marker` token for the TS1185 that
    /// `flushConflictMarkers` appends once the parse is over.
    fn noteConflictMarker(p: *Parser, t: Token) void {
        // The marker is the first line-start run of seven WITHIN the token: the
        // token's own start on the ordinary path, and past the whitespace text
        // on the JSX-children one (see `scanJsxChild`).
        var at = t.start;
        while (at < t.end and !scanner.isConflictMarker(p.src, at)) at += 1;
        if (at >= t.end) return;
        // Set semantics, not a high-water mark: a speculative parse can scan
        // two markers and then backtrack to before the FIRST, so "later than
        // the last one seen" would drop it when the re-scan reaches it again.
        for (p.conflict_markers[0..p.conflict_marker_len]) |m| {
            if (m == at) return;
        }
        if (p.conflict_marker_len == p.conflict_markers.len) return;
        p.conflict_markers[p.conflict_marker_len] = at;
        p.conflict_marker_len += 1;
    }

    /// Append one TS1185 per marker seen. Deferred to the end of the parse
    /// because `fill` is infallible; the driver sorts diagnostics by position
    /// before emitting them, so the deferral is invisible. The one-per-position
    /// rule is honoured by declining a position a syntactic diagnostic already
    /// holds — tsc, which pushes the marker at scan time, would instead have
    /// suppressed the later parse error, but no token can start at a marker
    /// (it is trivia), so nothing reaches that position from the parser side.
    fn flushConflictMarkers(p: *Parser) Error!void {
        for (p.conflict_markers[0..p.conflict_marker_len]) |at| {
            var taken = false;
            for (p.diags.items) |d| {
                if (d.span.start == at and d.code.class() == .syntactic) taken = true;
            }
            if (taken) continue;
            try p.diags.append(p.gpa, .{
                .code = .merge_conflict_marker,
                .span = .{ .start = at, .end = at + 7 },
            });
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
                // TS6188/TS6189 first, because tsc's scanner reports a
                // misplaced separator from inside the digit scan and the radix
                // / leading-zero / exponent rules only afterwards — and where
                // the two coincide (`0x_`'s separator against its "digit
                // expected") the one-per-position rule keeps whichever came
                // first.
                if (literals.SeparatorWalk.any(text)) {
                    var sw: literals.SeparatorWalk = .init(text, t.start);
                    while (sw.next()) |f| {
                        try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                    }
                }
                if (literals.checkNumeric(text, t.start)) |f| {
                    try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                }
                // TS1352/TS1353, in tsc's order: its scanner reports the empty
                // exponent (above) before the suffix, and the two land on
                // different characters so both survive the one-per-position
                // rule. Only a NUMERIC-tagged token can carry a misplaced
                // suffix; a well-formed BigInt is its own tag.
                if (t.tag == .numeric_literal) {
                    if (literals.bigintSuffixMisuse(text, t.start)) |f| {
                        try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
                    }
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

    /// The escape-sequence rules for a template part that has just been
    /// consumed. Not folded into `checkLiteral` (which fires for every token)
    /// because whether a bad escape is an error depends on WHO consumed the
    /// token: a TAGGED template legalizes every one of them, since the tag
    /// function is handed the raw text. tsc reaches the same split by scanning
    /// template tokens with error emission off (recording
    /// `TokenFlags.ContainsInvalidEscape`) and re-scanning —
    /// `reScanTemplateToken(isTaggedTemplate: false)` — only where the parser
    /// knows there is no tag. Measured against tsgo, the two positions tsc never
    /// re-scans are a tagged template and a BARE `` `…` `` literal TYPE
    /// (`type T = ` + "`\\u`" + ` is silent, while `` type T = `\x1${string}` ``
    /// reports), so neither of those calls this.
    fn checkTemplateEscapes(p: *Parser, tok: u32) Error!void {
        const text = p.tokenTextAt(tok);
        if (!literals.EscapeWalk.any(text)) return;
        const start = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
        var w: literals.EscapeWalk = .init(text, start);
        while (w.next()) |f| {
            try p.addDiag(f.code, .{ .code = f.code, .span = f.span });
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

    /// The three messages tsc gives a MISSING NAME NODE — `createIdentifier`'s
    /// own "Identifier expected", and the two its callers pass in,
    /// `parsePrimaryExpression`'s "Expression expected" and
    /// `parseEntityNameOfTypeReference`'s "Type expected". They are the only
    /// diagnostics that move at end of file (see `errAtCur`).
    fn missingNameNode(code: Code) bool {
        return switch (code) {
            .expected_expression, .expected_identifier, .expected_type => true,
            else => false,
        };
    }

    /// Where the CURRENT token's leading trivia BEGAN — just past the last real
    /// token, or the start of the file when there is none. tsc's
    /// `scanner.getTokenFullStart()`, which is `fullStartPos`, set at the top of
    /// `scan()` before the trivia loop runs.
    fn curFullStart(p: *Parser) u32 {
        if (p.tok_tags.items.len == 0) return 0;
        return p.lastTokEnd();
    }

    /// Report at the current token's FULL start, zero-width — tsc's
    /// `parseErrorAtPosition(scanner.getTokenFullStart(), 0, …)`, which is what
    /// `createMissingNode(…, reportAtCurrentPosition: true, …)` passes. The
    /// difference from `errAtCur` is exactly the leading trivia: measured
    /// against tsgo, `a[/*c*/]` blames the byte after the `[`, not the `]`.
    fn errAtFullStart(p: *Parser, code: Code) Error!void {
        const at = p.curFullStart();
        try p.addDiag(code, .{ .code = code, .span = .{ .start = at, .end = at } });
    }

    fn errAtCur(p: *Parser, code: Code) Error!void {
        const t = p.cur();
        // tsc's `createMissingNode(reportAtCurrentPosition: token() ===
        // EndOfFileToken)`: when the parse ran out of FILE, a missing name node
        // is blamed on the position where the eof token's trivia began — just
        // past the last real token — and not on the eof token itself. tsc's own
        // comment is "Only for end of file because the error gets reported
        // incorrectly on embedded script tags". Measured against tsgo: `const y
        // =` followed by a comment line answers TS1109 at the end of the FIRST
        // line, and `const c = foo.` answers TS1003 there, while `const a = {`
        // and `class D { m(` keep their TS1005 on the eof token — `parseExpected`
        // has no such rule.
        if (t.tag == .eof and missingNameNode(code)) {
            const at = p.curFullStart();
            return p.addDiag(code, .{ .code = code, .span = .{ .start = at, .end = at } });
        }
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

    /// Report zero-width at the END of an ALREADY CONSUMED token — the
    /// `errAtCurEnd` of a token the parser has walked past. tsc's
    /// `grammarErrorAtPos(node, node.pos, …)` lands there whenever the node
    /// whose `pos` is being blamed is EMPTY and begins after that token: an
    /// empty `VariableDeclarationList` starts where the `var` ended, which is
    /// column 4 of `var ;` and column 9 of `for (var in X)`.
    fn errAtTokenEnd(p: *Parser, code: Code, tok: u32) Error!void {
        const start = p.tok_starts.items[tok] & scanner.Tokens.start_mask;
        const at = scanner.tokenEnd(p.src, p.tok_tags.items[tok], start);
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

    /// Byte range of the consumed token run `from`..`to` inclusive — the
    /// `node.pos`..`node.end` of a node that spans exactly those tokens. A
    /// token START already has its leading trivia skipped, so this is tsc's
    /// `skipTrivia(sourceText, node.pos)`..`node.end` too.
    fn tokSpan(p: *Parser, from: TokenIndex, to: TokenIndex) Span {
        const start = p.tok_starts.items[from] & scanner.Tokens.start_mask;
        const to_start = p.tok_starts.items[to] & scanner.Tokens.start_mask;
        return .{ .start = start, .end = scanner.tokenEnd(p.src, p.tok_tags.items[to], to_start) };
    }

    /// A diagnostic spanning a whole consumed token run, `from`..`to`
    /// inclusive — the shape tsc's `parseErrorAt(node.pos, node.end)` gives a
    /// grammar error blamed on an entire expression rather than one token.
    fn errAtRange(p: *Parser, code: Code, from: u32, to: u32) Error!void {
        const s = p.tokSpan(from, to);
        try p.errAtBytes(code, s.start, s.end);
    }

    /// A diagnostic over an explicit byte range that ALSO names a second range
    /// whose source text fills the message's `{0}` — the JSX unclosed-tag
    /// family, the only codes whose message interpolates.
    fn errAtSpanArg(p: *Parser, code: Code, span: Span, arg: Span) Error!void {
        try p.addDiag(code, .{
            .code = code,
            .span = .{ .start = span.start, .end = if (span.end > span.start) span.end else span.start + 1 },
            .arg = arg,
        });
    }

    /// A diagnostic over an explicit byte range, for the rule whose start is not
    /// a token START: tsgo's `parseErrorAtRange(typeNode, …)` blames a type
    /// constituent from its FULL start — the offset just past the previous
    /// token, leading trivia included — so no token index names it.
    fn errAtBytes(p: *Parser, code: Code, start: u32, end: u32) Error!void {
        try p.addDiag(code, .{
            .code = code,
            .span = .{ .start = start, .end = if (end > start) end else start + 1 },
        });
    }

    fn tokTagAt(p: *Parser, tok: u32) TokTag {
        return p.tok_tags.items[tok];
    }

    // --- rescanning (grammar-context lexing) -----------------------------

    /// Read the current (terminated) regex token as a PATTERN and record what
    /// its body and flags get wrong. tsc runs this from the checker's grammar
    /// pass, not from the parse, so every code `regexp` reports is grammar-class
    /// and is gated by the program's syntactic diagnostics like any other
    /// semantic one; appending straight to `p.diags` is what `addDiag` would do
    /// for a grammar code anyway, and keeps the walk's own
    /// one-diagnostic-per-position rule the only one in play.
    fn checkRegex(p: *Parser) Error!void {
        const t = p.cur();
        try regexp.validate(p.gpa, p.src, t.start, t.end, &p.diags);
    }

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

    /// Does this token START with a `>`? The maximal-munch scanner is wrong
    /// wherever the grammar wants a single `>`: type-argument lists say so with
    /// `expectGt`, and a JSX tag has the same problem — `<div>>` scans as
    /// `<`, `div`, `>>`, and the second `>` is CHILD TEXT (TS1382), not part of
    /// the tag.
    fn isGtFamily(t: TokTag) bool {
        return switch (t) {
            .gt, .gt_gt, .gt_gt_gt, .gt_eq, .gt_gt_eq, .gt_gt_gt_eq => true,
            else => false,
        };
    }

    /// Consume the `>` that closes a JSX tag, splitting a munched `>`-family
    /// token so the remainder falls back into the child text. Unlike `expectGt`
    /// the failure is reported at the CURRENT token, which is where a JSX tag's
    /// "'>' expected" has always landed.
    ///
    /// Returns the byte offset just past the `>` — where the children begin.
    /// `lastTokEnd` cannot answer that for a split token: it RESCANS from the
    /// token's start, so the `>` of a split `>>` measures two bytes wide and the
    /// second `>` would vanish out of the child text it belongs to.
    fn expectJsxGt(p: *Parser) PE!u32 {
        if (isGtFamily(p.curTag())) {
            const start = p.cur().start;
            _ = if (p.curTag() == .gt) try p.bump() else try p.splitGt();
            return start + 1;
        }
        _ = try p.expect(.gt, .expected_gt);
        return p.lastTokEnd();
    }

    /// The expression between the brackets of an element access. An EMPTY one
    /// (`a[]`) is TS1011 rather than the generic "Expression expected": tsc's
    /// `parseElementAccessExpression` special-cases the closing bracket and
    /// reports at it, then carries on with a missing node.
    fn parseElementAccessArgument(p: *Parser) PE!Node {
        if (p.curTag() != .r_bracket) return p.parseExpression(.{});
        try p.errAtFullStart(.element_access_needs_argument);
        return null_node;
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
        n_computed_keys: usize,
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
            .n_computed_keys = p.computed_keys.items.len,
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
        p.computed_keys.shrinkRetainingCapacity(s.n_computed_keys);
        p.last_syntactic_start = s.last_syntactic_start;
    }

    // --- node construction -------------------------------------------------

    fn addNode(p: *Parser, item: ast.NodeItem) Error!Node {
        const i: Node = @intCast(p.nodes.len);
        try p.nodes.append(p.gpa, item);
        return i;
    }

    fn nodeTagAt(p: *const Parser, node: Node) ast.Tag {
        return p.nodes.items(.tag)[node];
    }

    fn nodeMainTokenAt(p: *const Parser, node: Node) u32 {
        return p.nodes.items(.main_token)[node];
    }

    fn nodeDataAt(p: *const Parser, node: Node) ast.Data {
        return p.nodes.items(.data)[node];
    }

    /// One field of an extra record the parser itself wrote, by name — the
    /// build-time counterpart of `Ast.extraData`, which cannot run until the
    /// tree is finished. Reading a single field keeps the caller from having to
    /// know the record's layout.
    fn extraFieldAt(p: *const Parser, comptime T: type, comptime name: []const u8, index: u32) u32 {
        const fields = @typeInfo(T).@"struct".fields;
        const off = comptime blk: {
            for (fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) break :blk i;
            }
            @compileError("no field '" ++ name ++ "' in " ++ @typeName(T));
        };
        return p.extra.items[index + off];
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

    /// tsc's `canFollowModifier`: what a modifier keyword must be followed by
    /// for it to BE a modifier rather than the name itself. A destructuring
    /// pattern, a rest `...`, or any literal property name — which is where
    /// RESERVED words count too, so `constructor(static export a)` reads both
    /// as modifiers and answers once, for the `static`.
    fn canFollowModifier(tag: TokTag) bool {
        return switch (tag) {
            .l_bracket, .l_brace, .dot_dot_dot, .string_literal, .numeric_literal, .bigint_literal => true,
            else => isNameLike(tag),
        };
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
            .keyword_abstract,
            // An unterminated block comment is TRIVIA to tsc: its scanner
            // reports TS1010 and hands the parser EOF, so nothing lands here.
            // ztsc keeps it as a token that spans to end of file; letting
            // `parseStatement` own it reproduces tsc's single TS1010, whereas
            // treating it as junk would add a TS1128 tsc never reports.
            .unterminated_comment,
            => true,
            // The one group tsc does NOT wave through: a class-member modifier
            // is a statement start only when a declaration follows it, or when
            // the next token cannot be a member NAME. `static test()` inside a
            // function body is neither, so tsc refuses to parse it as a
            // statement at all — see `classMemberModifierStartsStatement`.
            .keyword_public,
            .keyword_private,
            .keyword_protected,
            .keyword_static,
            .keyword_readonly,
            => p.classMemberModifierStartsStatement(),
            // tsc's `isStartOfExpression`, including its error tolerance: the
            // start of a BINARY operator counts, so `* x;` is parsed as an
            // expression statement with a missing left operand (TS1109) rather
            // than skipped.
            else => |tag| canStartExpression(tag) or binaryPrec(tag, false) != 0,
        };
    }

    /// tsc's `isStartOfStatement` arm for `public`/`private`/`protected`/
    /// `static`/`readonly`:
    ///
    ///     return isStartOfDeclaration() ||
    ///         !lookAhead(nextTokenIsIdentifierOrKeywordOnSameLine);
    ///
    /// These words are legal identifiers, so `static;`, `readonly = 1` and
    /// `public.x` are ordinary expression statements — but `static test()` in a
    /// function body is neither an expression tsc wants nor a declaration, and
    /// it is much more likely a class member written one brace too deep. tsc
    /// answers TS1128 on the WORD and drops it, which is what returning false
    /// here buys (`parseStatementList`'s not-a-statement arm).
    ///
    /// `accessor` and `abstract` belong to the same tsc group but stay
    /// unconditionally true above: ztsc's `startsDeclarationAt` does not walk
    /// past them, so the answer here would be a false `false` for
    /// `accessor class C {}` — and a false `false` manufactures a TS1128 tsc
    /// does not report, while a false `true` only keeps ztsc's existing
    /// recovery.
    fn classMemberModifierStartsStatement(p: *Parser) bool {
        if (p.statementModifierRunLen() != 0) return true;
        if (p.peekNewline(1)) return true;
        const next = p.peekTag(1);
        return !(next == .identifier or next.isKeyword());
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

        try p.flushConflictMarkers();
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
        // The first `@` of the decorator run currently open, for TS1206. A
        // statement-position decorator run may only decorate a CLASS
        // declaration; the run is judged where it ENDS, once the token after it
        // is known, and reports once on its first `@` (`decorator_target.zig`).
        var deco_at: ?u32 = null;
        while (p.curTag() != terminator and p.curTag() != .eof) {
            if (p.curTag() == .at) {
                if (deco_at == null) deco_at = p.curIdx();
            } else if (deco_at) |at| {
                deco_at = null;
                if (p.spec == 0 and !p.decoratedStatementIsClass()) {
                    if (decorator_target.diagnose(p.experimental_decorators, .{ .kind = .other })) |code| {
                        try p.errAtToken(code, at);
                    }
                }
            }
            // tsc's `parseList` gate: a token that starts no statement is
            // reported and skipped, never parsed.
            if (!p.atStartOfStatement()) {
                try p.errNotAStatement(if (terminator == .eof and p.curTag() == .keyword_default)
                    .expected_export
                else
                    .expected_declaration_or_statement);
                // tsc's `abortParsingListOrMoveToNextToken`: the token is
                // dropped only when NO enclosing list would take it. A
                // class-member modifier inside a class body is a member start,
                // so tsc ends the statement list right here and lets the class
                // body have the token — which is how `class C { m() { static x
                // = 1; } }` ends up with `static x = 1` as a MEMBER and one
                // extra "Declaration or statement expected." on the now-unpaired
                // final `}`. The `}` the aborted block then fails to find lands
                // on this same position and is dropped by `addDiag`'s
                // one-per-position rule, exactly as in tsc.
                if (p.class_depth > 0 and statementModifierCode(p.curTag()) != null) return;
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

    /// Does a CLASS declaration follow the decorator run that just closed? tsc
    /// parses decorators as part of the modifier list, so every modifier that
    /// may precede `class` in statement position is transparent here:
    /// `@dec export class C {}`, `@dec declare class C {}` and
    /// `@dec export default class C {}` are all silent, measured against
    /// tsgo 7.0.2. Anything else the run precedes is TS1206.
    fn decoratedStatementIsClass(p: *Parser) bool {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            switch (p.peekTag(i)) {
                .keyword_class => return true,
                .keyword_export, .keyword_default, .keyword_declare, .keyword_abstract => {},
                else => return false,
            }
        }
        return false;
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

    /// The TS1044/TS1024 code a CLASS-MEMBER modifier earns in statement
    /// position, or null when the word is not one. tsc's `checkGrammarModifiers`
    /// words the accessibility trio and `static` as "cannot appear on a module
    /// or namespace element" and `readonly` as "can only appear on a property
    /// declaration or index signature"; the message names the modifier, which a
    /// code-plus-span Diagnostic cannot interpolate, so there is one code each.
    fn statementModifierCode(tag: TokTag) ?Code {
        return switch (tag) {
            .keyword_public => .public_not_on_module_element,
            .keyword_private => .private_not_on_module_element,
            .keyword_protected => .protected_not_on_module_element,
            .keyword_static => .static_not_on_module_element,
            .keyword_readonly => .readonly_not_on_property,
            else => null,
        };
    }

    /// Consume a run of class-member modifiers standing in front of a
    /// DECLARATION (`public var x`, `static class C`, `export public import …`)
    /// and report the FIRST one — tsc's grammar pass returns out of its modifier
    /// walk on the first hit, which is why `public private var x` answers once
    /// (the same rule TS1028 already follows). Consuming the whole run lets the
    /// declaration itself parse cleanly, so there is no cascade: measured
    /// against tsgo, every one of these positions is where ztsc used to answer
    /// TS1434 or TS1005 instead.
    ///
    /// A modifier only when a declaration actually follows: these are all
    /// contextual keywords, and `readonly = 1` or a bare `public` is an ordinary
    /// expression. A line break ends the run, because tsc's `isDeclaration`
    /// lookahead applies ASI to each modifier — `public` alone on its line is
    /// the expression `public` (TS1212), not a modifier for the next line's
    /// `var`.
    fn eatStatementModifiers(p: *Parser) PE!void {
        const n = p.statementModifierRunLen();
        if (n == 0) return;
        const first = p.curIdx();
        // Outside a module body tsc words the same condition as TS1184 rather
        // than naming the modifier — see `Parser.element_home`.
        const code: Code = if (p.element_home != .other)
            statementModifierCode(p.curTag()).?
        else
            .modifiers_not_allowed_here;
        for (0..n) |_| _ = try p.bump();
        try p.errAtToken(code, first);
    }

    /// How many leading tokens are class-member modifiers in front of a
    /// declaration, or 0 when this is not that shape. Bounded by the lookahead
    /// window: a run longer than three keeps ztsc's existing answer rather than
    /// reading past `max_la` (no real code writes even two).
    fn statementModifierRunLen(p: *Parser) u32 {
        var n: u32 = 0;
        while (n < max_la - 2 and statementModifierCode(p.peekTag(n)) != null) {
            n += 1;
            if (p.peekNewline(n)) return 0;
        }
        if (n == 0 or !p.startsDeclarationAt(n)) return 0;
        return n;
    }

    /// Does a DECLARATION begin `n` tokens ahead? tsc's `isDeclaration`
    /// lookahead, minus the modifier loop `statementModifierRunLen` runs itself.
    /// Conservative where tsc looks further (`interface`/`type` want an
    /// identifier on the same line, `let` wants a binding): answering true only
    /// ever moves a modifier word out of expression position, and the modifier
    /// diagnostic that follows is tsc's own answer for every such shape.
    /// Does a `declare` immediately followed by this token act as a MODIFIER?
    /// Exactly the tag set the `declare` arm of `parseStatementUnchecked`
    /// switches on — kept here so the arm and TS1038's guard cannot disagree
    /// about what `declare` is doing. (`declare` before anything else is an
    /// ordinary identifier: `declare = 1`, `declare.x`.)
    fn declareIsModifier(t: TokTag) bool {
        return switch (t) {
            .keyword_var,
            .keyword_let,
            .keyword_const,
            .keyword_function,
            .keyword_async,
            .keyword_class,
            .keyword_abstract,
            .keyword_interface,
            .keyword_type,
            .keyword_enum,
            .keyword_module,
            .keyword_namespace,
            .keyword_global,
            .keyword_export,
            => true,
            else => false,
        };
    }

    fn startsDeclarationAt(p: *Parser, n: u32) bool {
        return switch (p.peekTag(n)) {
            .keyword_var,
            .keyword_let,
            .keyword_const,
            .keyword_function,
            .keyword_class,
            .keyword_enum,
            .keyword_interface,
            .keyword_type,
            .keyword_namespace,
            .keyword_module,
            .keyword_import,
            .keyword_declare,
            .keyword_abstract,
            .keyword_async,
            => true,
            else => false,
        };
    }

    /// A statement in a position that has a PARENT in tsc's tree — a statement
    /// list, a clause, or the single statement an `if`/`while`/`for`/label
    /// carries. tsc's `checkGrammarModuleElementContext` asks exactly that
    /// question of a module element, so the check belongs here and not in
    /// `parseStatementUnchecked`, which is also how a declaration reached
    /// THROUGH its own modifiers (`export namespace N`) gets one answer rather
    /// than two.
    fn parseStatement(p: *Parser) PE!Node {
        if (p.element_home == .other and p.spec == 0) {
            // tsc's `grammarErrorOnFirstToken`, which is the token still under
            // the cursor here (`errAtToken` cannot be used: the token has not
            // been consumed yet, so it has no index).
            if (p.moduleElementCode()) |code| try p.errAtCur(code);
        }
        return p.parseStatementUnchecked();
    }

    /// The single statement an `if`/`else`/`while`/`do`/`for` or a label carries.
    /// tsc's parent for it is that statement — never a SourceFile or a
    /// ModuleBlock — so a module element there is out of context whatever list
    /// encloses the whole thing (`if (x) namespace N {}` is TS1235 even at the
    /// top level of a file). See `Parser.element_home`.
    fn parseSubstatement(p: *Parser) PE!Node {
        const was_home = p.element_home;
        p.element_home = .other;
        defer p.element_home = was_home;
        return p.parseStatement();
    }

    /// tsc's `checkGrammarModuleElementContext`, as a question about the tokens
    /// a statement starts with: which code a MODULE ELEMENT earns in a statement
    /// list that is not a module body, or null when these tokens start no module
    /// element at all (`import(…)`, `module.exports`, `declare = 1`).
    ///
    /// A declaration that merely CARRIES `export`/`declare` as a modifier is
    /// TS1184 instead, because tsc reaches it through `checkGrammarModifiers`.
    /// The split follows tsc's node kinds exactly: `export namespace N` is a
    /// ModuleDeclaration (TS1235) while `export function f` is a
    /// FunctionDeclaration with an `export` modifier (TS1184), and `export
    /// default 1` is an ExportAssignment (TS1258) while `export default class C`
    /// is again a declaration with modifiers (TS1184). Every arm was measured
    /// against tsgo 7.0.2 rather than inferred.
    fn moduleElementCode(p: *Parser) ?Code {
        return switch (p.curTag()) {
            // `import(…)` and `import.meta` are expressions, not declarations.
            .keyword_import => if (p.peekTag(1) == .l_paren or p.peekTag(1) == .dot)
                null
            else
                .import_not_at_top_level,
            .keyword_namespace, .keyword_module => p.namespaceElementCode(0),
            .keyword_declare => p.declareElementCode(0),
            .keyword_export => switch (p.peekTag(1)) {
                .eq => .export_assign_not_at_top_level,
                .keyword_import => .import_not_at_top_level,
                .asterisk, .l_brace => .export_not_at_top_level,
                .keyword_as => .export_as_namespace_not_at_top_level,
                // `export type { … }` and `export type * from` are export
                // declarations; `export type X = …` is an alias declaration
                // whose `export` is a modifier.
                .keyword_type => if (p.peekTag(2) == .l_brace or p.peekTag(2) == .asterisk)
                    .export_not_at_top_level
                else
                    .modifiers_not_allowed_here,
                .keyword_namespace, .keyword_module => p.namespaceElementCode(1),
                .keyword_declare => p.declareElementCode(1),
                .keyword_default => if (p.defaultExportIsDeclaration())
                    .modifiers_not_allowed_here
                else
                    .export_default_not_at_top_level,
                else => if (p.startsDeclarationAt(1)) .modifiers_not_allowed_here else null,
            },
            else => null,
        };
    }

    /// `namespace`/`module` sits `n` tokens ahead: an ambient module when its
    /// name is a STRING (`declare module "spec"`, TS1234 — not allowed even at
    /// the top level of a namespace), a namespace when it is an identifier
    /// (TS1235), and neither when no name follows (`module.exports = …`).
    fn namespaceElementCode(p: *Parser, n: u32) ?Code {
        if (p.peekNewline(n + 1)) return null;
        const t = p.peekTag(n + 1);
        if (t == .string_literal) return .ambient_module_not_at_top_level;
        return if (isIdentLike(t)) .namespace_not_at_top_level else null;
    }

    /// `declare` sits `n` tokens ahead. `declare global { … }` is a
    /// ModuleDeclaration too (tsc's `isGlobalScopeAugmentation`), and tsc words
    /// it as the ambient-module case.
    fn declareElementCode(p: *Parser, n: u32) ?Code {
        if (p.peekNewline(n + 1)) return null;
        return switch (p.peekTag(n + 1)) {
            .keyword_global => .ambient_module_not_at_top_level,
            .keyword_namespace, .keyword_module => p.namespaceElementCode(n + 1),
            // `declare export function f() {}` — the TS1029 modifier order, which
            // is still one modifier list on one declaration. `startsDeclarationAt`
            // deliberately omits `export` (it is a modifier, not a declaration
            // keyword), so the two module-element forms behind it are named here.
            .keyword_export => switch (p.peekTag(n + 2)) {
                .keyword_namespace, .keyword_module => p.namespaceElementCode(n + 2),
                else => .modifiers_not_allowed_here,
            },
            else => if (p.startsDeclarationAt(n + 1)) .modifiers_not_allowed_here else null,
        };
    }

    /// Does `export default` here introduce a DECLARATION rather than an
    /// expression? `async` only counts before `function` and `abstract` only
    /// before `class`, because `export default async () => 1` and `export
    /// default abstract` are expressions.
    fn defaultExportIsDeclaration(p: *Parser) bool {
        return switch (p.peekTag(2)) {
            .keyword_function, .keyword_class, .keyword_interface => true,
            .keyword_async => p.peekTag(3) == .keyword_function,
            .keyword_abstract => p.peekTag(3) == .keyword_class,
            else => false,
        };
    }

    fn parseStatementUnchecked(p: *Parser) PE!Node {
        switch (p.curTag()) {
            .keyword_public,
            .keyword_private,
            .keyword_protected,
            .keyword_static,
            .keyword_readonly,
            => {
                if (p.statementModifierRunLen() == 0) return p.parseExpressionStatement();
                try p.eatStatementModifiers();
                // Already reported on the modifier run; the declaration behind
                // it must not earn a second answer.
                return p.parseStatementUnchecked();
            },
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
            .keyword_using => {
                // `using x = res;` — an explicit-resource declaration (TS 5.2).
                if (p.startsUsingDeclaration(0)) return p.parseVarStatement();
                return p.parseExpressionStatement();
            },
            .keyword_await => {
                // `await using x = res;` — tsc's `isAwaitUsingDeclaration`.
                // The `await` is consumed here so the declaration list starts at
                // `using`, which is the token `Binder.declKindOfVar` reads.
                if (p.peekTag(1) == .keyword_using and !p.peekNewline(1) and p.startsUsingDeclaration(1)) {
                    _ = try p.bump(); // `await`
                    return p.parseVarStatement();
                }
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
            .keyword_class => return p.parseClassDecl(0, .declaration),
            .keyword_abstract => {
                if (!p.peekNewline(1)) {
                    if (p.peekTag(1) == .keyword_class) {
                        _ = try p.bump();
                        return p.parseClassDecl(ast.Flags.abstract, .declaration);
                    }
                    // The `async` treatment, for the same reason and from the
                    // same tsc code: `isDeclaration`'s modifier loop consumes
                    // `abstract` and looks at what follows, so any OTHER
                    // declaration behind it is parsed WITH the modifier and
                    // `checkGrammarModifiers` answers TS1242 on the word.
                    // `abstract interface I {}` used to be an expression
                    // statement here, which cost the TS1242 and read the rest as
                    // an unexpected keyword (TS1434) besides.
                    if (p.spec == 0 and (asyncModifierTarget(p.peekTag(1)) or p.peekTag(1) == .keyword_function)) {
                        const kw = try p.bump();
                        try p.errAtToken(.abstract_modifier_not_valid_here, kw);
                        return p.parseStatementUnchecked();
                    }
                }
                return p.parseExpressionStatement();
            },
            .keyword_async => {
                if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                    _ = try p.bump();
                    return p.parseFunctionDecl(ast.Flags.async, false);
                }
                // Any OTHER declaration behind `async` is tsc's TS1042: its
                // `isDeclaration` lookahead sees the declaration, so `async` is
                // parsed as a MODIFIER and `checkGrammarModifiers` rejects it
                // on the word — while the declaration itself parses and binds
                // as if the modifier were not there. `async class C {}` used to
                // be an expression statement here, which cost the TS1042 and
                // the class both.
                if (p.spec == 0 and !p.peekNewline(1) and asyncModifierTarget(p.peekTag(1))) {
                    const kw = try p.bump();
                    try p.errAtToken(.async_modifier_not_allowed_here, kw);
                    return p.parseStatementUnchecked();
                }
                return p.parseExpressionStatement();
            },
            .keyword_interface => {
                // ASI: tsc's `isDeclaration` lookahead for `interface` is
                // `nextTokenIsIdentifierOrKeywordOnSameLine`, so a LINE BREAK
                // after the word ends the statement and `interface` is an
                // ordinary identifier reference — `asiPreventsParsingAsInterface02`
                // writes `interface \n I \n {}` and means three statements.
                if (isIdentLike(p.peekTag(1)) and !p.peekNewline(1)) return p.parseInterfaceDecl(0);
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
                // TS1038, before the `declare` is consumed so it can be blamed
                // on the token still under the cursor. `declareIsModifier` is
                // the switch's own tag set, hoisted: reporting for a shape the
                // switch would have let fall through to an expression statement
                // (`declare = 1`) would be a key on a program that has no
                // modifier in it at all.
                if (!p.peekNewline(1) and declareIsModifier(p.peekTag(1)) and
                    p.ambient and p.element_home == .module_block and p.spec == 0)
                {
                    try p.errAtCur(.declare_in_ambient_context);
                }
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
                        return p.parseClassDecl(ast.Flags.declare, .declaration);
                    },
                    .keyword_abstract => {
                        _ = try p.bump();
                        _ = try p.bump();
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseClassDecl(ast.Flags.declare | ast.Flags.abstract, .declaration);
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
                        if (isModuleNameLiteral(p.peekTag(1)) and !p.peekNewline(1)) {
                            return p.parseAmbientModule(true);
                        }
                        if (p.peekTag(1) == .l_brace and !p.peekNewline(1)) {
                            return p.parseAnonymousNamespace(true);
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
                    .keyword_export => {
                        // `declare export function f() {}` — the modifiers in
                        // the order tsc calls TS1029, which it reports while
                        // still parsing both as one modifier list. Reading
                        // `declare` as an expression instead cost a false
                        // TS2304 and lost the TS1183 the body earns.
                        // TS1029, but only where tsc's `checkGrammarModifiers`
                        // actually reaches the pair. Three earlier arms
                        // short-circuit its walk and each is tsgo's whole answer
                        // for that shape (measured), so reporting here as well
                        // would be a second, wrong key:
                        //   * `declare export = x` -> TS1120 `An export
                        //     assignment cannot have modifiers.`, on the
                        //     statement;
                        //   * a statement list that is not a module body ->
                        //     TS1184 `Modifiers cannot appear here.`, which
                        //     ztsc already reports;
                        //   * an ALREADY ambient context (inside `declare module
                        //     "m" { … }`) -> TS1038 `A 'declare' modifier cannot
                        //     be used in an already ambient context.`
                        // ztsc reports neither TS1120 nor TS1038 yet, so those
                        // two stay under-reports.
                        const pair_reaches = p.element_home != .other and !p.ambient and p.peekTag(2) != .eq;
                        _ = try p.bump(); // `declare`
                        if (pair_reaches) try p.errAtCur(.mod_order_export_declare);
                        const was_ambient = p.ambient;
                        p.ambient = true;
                        defer p.ambient = was_ambient;
                        return p.parseExportStatement();
                    },
                    else => {},
                };
                return p.parseExpressionStatement();
            },
            .keyword_import => return p.parseImportStatement(null),
            .keyword_export => return p.parseExportStatement(),
            .keyword_global => {
                // Bare `global { ... }` augmentation (no leading `declare`), as
                // used inside ambient module blocks in real `@types/node`
                // (`declare module "buffer" { global { var Buffer … } }`). Only
                // when directly followed by `{`; otherwise `global` is an
                // ordinary contextual-keyword identifier (`global.foo`, a label).
                if (p.peekTag(1) == .l_brace) return p.parseGlobalAugmentation();
                if (p.peekTag(1) == .colon) return p.parseLabeledStatement();
                return p.parseExpressionStatement();
            },
            .keyword_enum => return p.parseEnumDecl(0),
            .keyword_namespace, .keyword_module => {
                // Only a namespace when followed by a name / string.
                const t1 = p.peekTag(1);
                if (isIdentLike(t1) and !p.peekNewline(1)) {
                    return p.parseNamespaceDecl(0);
                }
                if (isModuleNameLiteral(t1) and !p.peekNewline(1)) {
                    // `module "x" { }` with no `declare`: the same declaration
                    // an ambient one makes, plus the TS1035 that says so.
                    return p.parseAmbientModule(false);
                }
                if (t1 == .l_brace and !p.peekNewline(1)) return p.parseAnonymousNamespace(false);
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
                if (isIdentLike(p.curTag()) and p.peekTag(1) == .colon) return p.parseLabeledStatement();
                return p.parseExpressionStatement();
            },
        }
    }

    /// `label: stmt`. Current token is the label, the next one its `:`.
    ///
    /// tsc reports TS1344 on the LABEL when what it labels is a DECLARATION
    /// rather than a statement. Measured against tsgo: `var`/`let`/`const`,
    /// `function` (plain, `async`, generator), `class`, `interface`, `enum`,
    /// `type`, `namespace`, `import` and anything carrying a modifier all answer
    /// it; `if`/`for`/`while`/`do`/`switch`/`try`/`throw`/`debugger`/`;`/a
    /// block/an expression/a nested LABEL do not (`a: b: var v = 1` reports on
    /// `b`, the label whose statement is the declaration, and not on `a`, whose
    /// statement is a labeled statement).
    ///
    /// Decided on the parsed NODE rather than on a lookahead, so the questions
    /// of whether `let` and `async` are keywords here are already answered.
    fn parseLabeledStatement(p: *Parser) PE!Node {
        const label = try p.bump();
        _ = try p.bump(); // ':'
        // The label is a jump target for everything inside it and for nothing
        // outside — a function nested in it starts its own slice of the stack.
        try p.labels.append(p.gpa, label | (if (p.labelTargetsIteration()) label_on_iteration else 0));
        defer p.labels.shrinkRetainingCapacity(p.labels.items.len - 1);
        const body = try p.parseSubstatement();
        if (isDeclarationTag(p.nodes.items(.tag)[body])) {
            try p.errAtToken(.label_not_allowed, label);
        }
        return p.addNode(.{ .tag = .labeled_stmt, .main_token = label, .data = .{ .lhs = body, .rhs = 0 } });
    }

    /// Statement tags that are DECLARATIONS — the set a label may not carry.
    /// `.unsupported` is excluded: it stands for a construct ztsc does not
    /// model, and guessing which side of this line it falls on would invent a
    /// diagnostic over a parser gap.
    fn isDeclarationTag(tag: ast.Tag) bool {
        return switch (tag) {
            .var_decl,
            .var_decl_one,
            .function_decl,
            .class_decl,
            .interface_decl,
            .type_alias,
            .enum_decl,
            .namespace_decl,
            .import_decl,
            .import_equals,
            .export_decl,
            .export_default,
            .export_assign,
            => true,
            else => false,
        };
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
        // A block is the one statement list that is NOT a module body — see
        // `Parser.element_home`.
        const was_home = p.element_home;
        p.element_home = .other;
        defer p.element_home = was_home;
        try p.parseStatementList(top, .r_brace, ambient_body);
        _ = try p.expect(.r_brace, .expected_r_brace);
        // `{ a, b } = fn()` — a destructuring assignment whose parentheses were
        // forgotten reaches here as a BLOCK followed by `=`. tsc's `parseBlock`
        // ends with exactly this check and consumes the `=` so the right-hand
        // side becomes its own statement instead of a second cascade; without
        // it the `=` fell through to the statement list as a plain TS1128.
        if (p.curTag() == .eq) {
            try p.errAtCur(.destructuring_assignment_needs_parens);
            _ = try p.bump();
        }
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
                    !scannerAlreadyReported(p.curTag()))
                {
                    // At the WORD unconditionally, even when a diagnostic
                    // already sits there: tsc reports at that position too and
                    // its `parseErrorAtPosition` drops the duplicate, so the
                    // statement goes unreported in tsc as well. ztsc used to
                    // answer "';' expected" at the NEXT token instead, to keep
                    // the statement from going silent — but that is a key tsgo
                    // does not have, and the two recoveries that made the guard
                    // look right (`import Foo From "m"` and a declarator list
                    // cut short at a missing comma) now follow tsc's own shape.
                    const tok = p.nodes.items(.main_token)[expr];
                    try p.errForMissingSemicolonAfterWord(tok);
                    return;
                }
                try p.errAtCur(.expected_semicolon);
            },
        }
    }

    /// The word half of tsc's `parseErrorForMissingSemicolonAfter`: a statement
    /// that is nothing but a bare identifier, followed by something other than
    /// `;`. tsc switches on the WORD before falling back to TS1434, because a
    /// word that names a DECLARATION form is far more likely a declaration
    /// whose name the grammar rejected than a misspelled identifier — and then
    /// it answers about the NAME, at the token that should have been one.
    ///
    /// `parseErrorForInvalidName`'s two arms are the `blank` case (the name
    /// position holds the token that would have FOLLOWED a name — `{` for a
    /// namespace or interface, `=` for a type alias, i.e. the declaration has no
    /// name at all) and the reserved-word case (there IS a token there, it just
    /// cannot be a name — `type void`, `interface void`). The interpolating
    /// codes take their `{0}` from the reported span, which is exactly that
    /// token.
    ///
    /// `declare` is silent: a `declare` that failed to parse has already
    /// reported. Every arm was oracle-probed against tsgo 7.0.2.
    fn errForMissingSemicolonAfterWord(p: *Parser, tok: u32) Error!void {
        // A word that only LOOKS like an identifier because it was spelled with
        // a `\uXXXX` escape: tsc's scanner cooks the text before consulting
        // `textToKeyword`, so `var x = "hello"` is a keyword `var` there
        // and a plain `var` statement — with one TS1260 for the escape and
        // nothing else. ztsc's scanner deliberately never keyword-matches an
        // escaped token, so the statement arrives here instead; answering the
        // escape rather than TS1434 lands the same code at the same span
        // (`scannerUnicodeEscapeInKeyword1`/`2`, whose seven positions already
        // agreed and only disagreed on the code).
        if (isEscapedKeyword(p, tok)) return p.errAtToken(.keyword_with_escape, tok);
        const blank_interface = p.curTag() == .l_brace;
        switch (p.tokTagAt(tok)) {
            .keyword_declare => {},
            .keyword_var, .keyword_let, .keyword_const => try p.errAtToken(.variable_declaration_not_allowed_here, tok),
            .keyword_is => try p.errAtToken(.type_predicate_not_allowed_here, tok),
            .keyword_interface => try p.errAtCur(if (blank_interface)
                .interface_needs_a_name
            else
                .interface_name_reserved),
            .keyword_namespace, .keyword_module => try p.errAtCur(if (blank_interface)
                .namespace_needs_a_name
            else
                .namespace_name_reserved),
            .keyword_type => try p.errAtCur(if (p.curTag() == .eq)
                .expected_type
            else
                .type_alias_name_reserved),
            else => try p.errAtToken(.unexpected_keyword_or_identifier, tok),
        }
    }

    /// Is `tok` an identifier whose `\uXXXX` escapes cook down to a KEYWORD —
    /// the token tsc's scanner would have handed back as that keyword? The
    /// backslash probe short-circuits every ordinary word before the decode.
    fn isEscapedKeyword(p: *const Parser, tok: u32) bool {
        const text = p.tokenTextAt(tok);
        if (std.mem.indexOfScalar(u8, text, '\\') == null) return false;
        var buf: [scanner.max_unescaped_ident]u8 = undefined;
        const cooked = scanner.unescapeIdentifier(text, &buf) orelse return false;
        return scanner.isKeywordText(cooked);
    }

    /// Token tags the SCANNER has already reported on, so the parser must not
    /// add a second complaint about the same text: none of them is the WORD
    /// `expectSemicolonAfterExpression`'s misspelled-keyword theory is about.
    /// The unterminated forms matter beyond tidiness — `f` followed by an
    /// unterminated template is a TAGGED TEMPLATE tsc answers only TS1160 for,
    /// so blaming `f` was a key tsgo does not have
    /// (`taggedTemplatesWithIncompleteNoSubstitutionTemplate1`/`2`).
    fn scannerAlreadyReported(tag: TokTag) bool {
        return switch (tag) {
            .unknown,
            .binary_content,
            .unterminated_string_literal,
            .unterminated_template,
            .unterminated_regexp_literal,
            .unterminated_comment,
            => true,
            else => false,
        };
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
        try p.checkDestructuringInitializers(node);
        try p.expectSemicolon();
        return node;
    }

    /// tsc's `checkGrammarVariableDeclaration`, the destructuring arm: a
    /// declarator whose name is a BINDING PATTERN must carry an initializer.
    /// TS1182, blamed on the whole declaration — which starts at the pattern,
    /// so the declarator's own main token is the anchor.
    ///
    /// tsc's three exemptions, all of them the reason this is a post-pass on the
    /// finished list rather than a line inside `parseVarDecl`:
    ///
    ///   * a `for…in`/`for…of` head, whose declaration never has an initializer
    ///     by construction — and which is only distinguishable from a plain
    ///     `for (var {}; ;)` head (where the rule DOES apply, measured) after
    ///     the list has been parsed;
    ///   * an AMBIENT declarator (`declare var {x};`), where
    ///     `checkAmbientInitializer` takes the branch instead and says nothing;
    ///   * a declarator that has an initializer.
    ///
    /// The arm sits ahead of TS1155's in tsc's chain and `return`s, so `const
    /// {};` answers for the pattern alone.
    fn checkDestructuringInitializers(p: *Parser, node: Node) Error!void {
        if (p.spec != 0 or p.ambient or node == null_node) return;
        switch (p.nodeTagAt(node)) {
            .var_decl_one => try p.checkDestructuringInitializer(p.nodeDataAt(node).lhs),
            .var_decl => {
                const data = p.nodeDataAt(node);
                for (p.extra.items[data.lhs..data.rhs]) |d| try p.checkDestructuringInitializer(d);
            },
            else => {},
        }
    }

    fn checkDestructuringInitializer(p: *Parser, decl: Node) Error!void {
        if (decl == null_node) return;
        const d = p.nodeDataAt(decl);
        switch (p.nodeTagAt(decl)) {
            // `declarator_init` always has one, so only these two can be bare.
            .declarator => {},
            .declarator_full => {
                if (p.extraFieldAt(ast.DeclaratorFull, "init", d.rhs) != null_node) return;
            },
            else => return,
        }
        switch (p.nodeTagAt(d.lhs)) {
            .object_pattern, .array_pattern => {},
            else => return,
        }
        try p.errAtToken(.destructuring_needs_initializer, p.nodeMainTokenAt(decl));
    }

    /// Does `using` — the token `n` ahead — begin a DECLARATION? tsc's
    /// `nextTokenIsBindingIdentifierOrStartOfObjectDestructuringOnSameLine`: an
    /// identifier or an OBJECT pattern on the same line. An ARRAY pattern is
    /// deliberately absent, measured against tsgo — `using [b] = null` stays the
    /// element access `using[b]`, while `using {a} = null` is a declaration that
    /// then earns TS1492.
    fn startsUsingDeclaration(p: *Parser, n: u32) bool {
        if (p.peekNewline(n + 1)) return false;
        const t = p.peekTag(n + 1);
        return isIdentLike(t) or t == .l_brace;
    }

    /// `var`/`let`/`const`/`using` declarator list (shared with for-init).
    fn parseVarDecl(p: *Parser, no_in: bool) PE!Node {
        const kw = try p.bump(); // var/let/const/using
        if (p.curTag() == .keyword_enum) {
            // `const enum E { ... }` — main_token stays on `const`.
            _ = try p.bump(); // `enum`
            return p.parseEnumDeclFrom(kw, ast.Flags.const_enum);
        }
        // TS1492: a `using` declaration binds one name, never a pattern. Blamed
        // on the pattern and reported before it is parsed; the pattern itself
        // parses and binds as usual, because tsgo answers the TS2339 that
        // `using { a } = null` earns alongside the TS1492.
        const pattern_code: ?Code = if (p.tokTagAt(kw) == .keyword_using)
            if (kw > 0 and p.tokTagAt(kw - 1) == .keyword_await)
                .await_using_binding_pattern
            else
                .using_binding_pattern
        else
            null;
        // tsc's `parseDelimitedList` asks `isListElement` before the FIRST
        // element too, so a list whose head is already a TERMINATOR parses zero
        // declarators — and `checkGrammarVariableDeclarationList` answers for
        // the empty list (TS1123) instead of the parser answering "Variable
        // declaration expected" at whatever follows. `const` at end of file,
        // `var ;` and a `for (var in X)` head are all this shape; the last one
        // is why the code is GRAMMAR-class, since tsgo reports the RHS's TS2304
        // beside it.
        if ((!p.atStartOfDeclarator() and p.varDeclaratorListDone()) or p.atForOfWithNoDeclarator()) {
            if (p.spec > 0) return error.Backtrack;
            try p.errAtTokenEnd(.empty_var_decl_list, kw);
            return p.addNode(.{ .tag = .var_decl, .main_token = kw, .data = .{ .lhs = 0, .rhs = 0 } });
        }
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        list: while (true) {
            if (pattern_code) |code| {
                if (p.curTag() == .l_brace or p.curTag() == .l_bracket) try p.errAtCur(code);
            }
            const before = p.curIdx();
            try p.pushScratch(try p.parseDeclarator(no_in));
            if (try p.eat(.comma) == null) {
                // tsc's `parseDelimitedList` does NOT end the list on a missing
                // comma: it reports one and keeps reading declarators, so `var
                // y: z is number` is three of them with two "',' expected"
                // between, where ztsc used to hand the rest of the line to the
                // statement list and answer for it there. The list ends only
                // where `isVariableDeclaratorListTerminator` says it does.
                if (p.varDeclaratorListDone()) break;
                try p.fail(.expected_comma);
                // tsc's own zero-length-element guard: a declarator that
                // consumed nothing would spin here forever.
                if (p.curIdx() == before) _ = try p.bump();
            }
            // Whether or not a comma was there, `parseDelimitedList` re-asks
            // `isListElement` at the top of the next iteration; a token that
            // starts no declarator is never handed to `parseVariableDeclaration`
            // at all. It goes to `isListTerminator` — which ends the list
            // silently — and then to `abortParsingListOrMoveToNextToken`, which
            // files `parsingContextErrors(VariableDeclarations)` (TS1134, which
            // the one-per-position rule drops whenever a "',' expected" just
            // filed already used this position) and then either ABANDONS the
            // list, when an enclosing context would take the token, or steps
            // OVER it and asks again.
            //
            // `var a = q~;` is the abandoning shape: the `~` starts a
            // statement, so the list stops and `~;` becomes its own (whose
            // missing operand is tsc's TS1109). `var mul = ~[1], "";` is the
            // same shape one comma later — the `""` is no binding name, so it
            // earns the TS1134 here and is left to the statement list, where
            // ztsc used to instead parse it as a declarator with a missing name
            // and then answer a SECOND TS1134 on the `;` past it
            // (`bitwiseNotOperatorInvalidOperations`).
            //
            // `var x = { ` + "`a`" + `: 321 }` is the advancing shape, and the
            // reason this is a loop rather than a break: the initializer's
            // object literal aborts empty at the template (TS1136) and the
            // template is then taken as a TAGGED TEMPLATE of it, so the
            // declarator ends on the `:` — which starts neither a declarator
            // nor a statement. tsc steps over it and lands TS1134 on the `321`
            // (`templateStringInPropertyName{1,2,ES6_1,ES6_2}`).
            while (!p.atStartOfDeclarator()) {
                if (p.varDeclaratorListDone()) break :list;
                try p.errAtCur(.expected_binding);
                if (p.abandonsVarDeclList()) break :list;
                _ = try p.bump();
            }
        }
        const items = p.scratch.items[top..];
        if (items.len == 1) {
            return p.addNode(.{ .tag = .var_decl_one, .main_token = kw, .data = .{ .lhs = items[0], .rhs = 0 } });
        }
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .var_decl, .main_token = kw, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    /// tsc's `canFollowContextualOfKeyword`, asked by
    /// `parseVariableDeclarationList` BEFORE the delimited list and only when
    /// the list's first token is `of`: `nextTokenIsIdentifier() && nextToken()
    /// === CloseParenToken`. A hit means the `of` is the for-of KEYWORD and the
    /// declaration list is empty, not a declarator named `of`.
    ///
    /// `for (var of X) {}` is the shape: `of` is followed by an identifier and
    /// then `)`, so tsc parses an empty list, answers TS1123 at the position
    /// right after `var`, and reads `of X` as the for-of head. ztsc took `of`
    /// as the declarator name and then wanted a second `of`, reporting two
    /// TS1005s at the `X` instead (`parserForOfStatement2`,
    /// `parserES5ForOfStatement2`, and the `for (var of of)` pair at 21).
    ///
    /// `for (var of; ;)` is deliberately NOT this shape — `;` is no identifier,
    /// so `of` stays the declarator name, which is why `parserForOfStatement17`
    /// already agreed.
    ///
    /// Not gated on being in a for-head, exactly as tsc's is not: the lookahead
    /// already demands a `)` two tokens on, which no statement-level
    /// declaration list can produce.
    fn atForOfWithNoDeclarator(p: *Parser) bool {
        return p.curTag() == .keyword_of and
            isIdentLike(p.peekTag(1)) and
            p.peekTag(2) == .r_paren;
    }

    /// tsc's `isVariableDeclaratorListTerminator`: anything a `;` could stand
    /// in for (ASI included), the `in`/`of` of a for-head, or an `=>` — tsc's
    /// own "error recovery tweak", which stops the list dead so an arrow
    /// function whose parameter list was mistaken for a declaration does not
    /// swallow the body.
    fn varDeclaratorListDone(p: *Parser) bool {
        return switch (p.curTag()) {
            .semicolon, .r_brace, .eof, .arrow, .keyword_in, .keyword_of => true,
            else => p.nlBefore(),
        };
    }

    /// Declarations that `async` may stand in front of and earn TS1042 —
    /// tsc's `isDeclaration` lookahead minus `function` (where `async` is
    /// legal) and minus `declare`, which takes tsc's ambient-context arm and
    /// answers TS1040 on the `declare` instead.
    fn asyncModifierTarget(tag: TokTag) bool {
        return switch (tag) {
            .keyword_class,
            .keyword_enum,
            .keyword_interface,
            .keyword_namespace,
            .keyword_module,
            .keyword_var,
            .keyword_let,
            .keyword_const,
            .keyword_type,
            .keyword_abstract,
            .keyword_import,
            => true,
            else => false,
        };
    }

    /// tsc's `isListElement(VariableDeclarations)`, i.e.
    /// `isBindingIdentifierOrPrivateIdentifierOrPattern` — exactly the tags
    /// `parseBindingName` accepts without complaint.
    fn atStartOfDeclarator(p: *Parser) bool {
        return switch (p.curTag()) {
            .l_bracket, .l_brace, .private_identifier => true,
            else => |tag| isIdentLike(tag),
        };
    }

    /// Standing in for tsc's `isInSomeParsingContext` as
    /// `abortParsingListOrMoveToNextToken` asks it from a declarator list: is
    /// this token something an ENCLOSING construct is waiting for, so that the
    /// list must hand it back rather than skip it? The enclosing statement list
    /// takes anything `isStartOfStatement` accepts, and a closing bracket
    /// belongs to whatever opened it, exactly as in `canAbandonArgList` —
    /// skipping one would let a single unclosed `(` eat the rest of the file.
    /// The declarator list's own terminators never reach here: the caller
    /// answers those first, and silently, as `isListTerminator` does.
    fn abandonsVarDeclList(p: *Parser) bool {
        return switch (p.curTag()) {
            .r_paren, .r_bracket => true,
            else => p.atStartOfStatement(),
        };
    }

    fn parseDeclarator(p: *Parser, no_in: bool) PE!Node {
        const name_tok = p.curIdx();
        const name = try p.parseBindingName(.private_name_in_var_decl);
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
        const then_stmt = try p.parseSubstatement();
        if (try p.eat(.keyword_else) != null) {
            const else_stmt = try p.parseSubstatement();
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
        const body = try p.parseLoopBody();
        return p.addNode(.{ .tag = .while_stmt, .main_token = kw, .data = .{ .lhs = cond, .rhs = body } });
    }

    fn parseDoStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        const body = try p.parseLoopBody();
        _ = try p.expect(.keyword_while, .expected_while);
        _ = try p.expect(.l_paren, .expected_l_paren);
        const cond = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        _ = try p.eat(.semicolon); // ASI always permits omitting it here
        return p.addNode(.{ .tag = .do_stmt, .main_token = kw, .data = .{ .lhs = body, .rhs = cond } });
    }

    /// tsc's `checkGrammarForInOrForOfStatement`, the arm about the declaration
    /// LIST: a `for…in`/`for…of` head takes exactly ONE declaration, and that
    /// one may not have an initializer. tsc `return`s on its first hit, so a
    /// head with two INITIALIZED declarations answers for the count alone.
    ///
    /// Positions are tsc's, measured: the count is blamed on the SECOND
    /// declarator's first token (`grammarErrorOnFirstToken(declarations[1])`),
    /// and the initializer and the TYPE ANNOTATION on the declarator's NAME
    /// (`grammarErrorOnNode(firstDeclaration.name/firstDeclaration)`, whose
    /// first token is the same one).
    fn checkForInOfHead(p: *Parser, init: Node, is_of: bool) Error!void {
        if (p.spec != 0 or init == null_node) return;
        switch (p.nodeTagAt(init)) {
            .var_decl => {
                const data = p.nodeDataAt(init);
                // An EMPTY list already answered TS1123 (`parseVarDecl`), and
                // tsc's `checkGrammarVariableDeclarationList` `return`s true
                // there, so the count arm never runs.
                if (data.rhs - data.lhs < 2) return;
                const second = p.extra.items[data.lhs + 1];
                const code: Code = if (is_of) .for_of_one_declaration else .for_in_one_declaration;
                try p.errAtToken(code, p.nodeMainTokenAt(second));
            },
            .var_decl_one => {
                const decl = p.nodeDataAt(init).lhs;
                const has_init = switch (p.nodeTagAt(decl)) {
                    .declarator_init => true,
                    .declarator_full => p.extraFieldAt(ast.DeclaratorFull, "init", p.nodeDataAt(decl).rhs) != null_node,
                    else => false,
                };
                if (!has_init) {
                    // Last arm of tsc's chain: the head's one declaration may
                    // not carry a TYPE ANNOTATION either. `grammarErrorOnNode`
                    // blames the whole declaration, whose first token is the
                    // name — the same anchor the initializer arm uses.
                    const ann = switch (p.nodeTagAt(decl)) {
                        .declarator_full => p.extraFieldAt(ast.DeclaratorFull, "type_ann", p.nodeDataAt(decl).rhs),
                        else => null_node,
                    };
                    if (ann == null_node) return;
                    const tcode: Code = if (is_of) .for_of_type_annotation else .for_in_type_annotation;
                    return p.errAtToken(tcode, p.nodeMainTokenAt(decl));
                }
                const code: Code = if (is_of) .for_of_declaration_initializer else .for_in_declaration_initializer;
                try p.errAtToken(code, p.nodeMainTokenAt(decl));
            },
            else => {},
        }
    }

    fn parseForStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        var is_await: u32 = 0;
        if (p.curTag() == .keyword_await) {
            const aw = try p.bump(); // `for await` — recorded for the checker
            is_await = 1;
            // TS18038: same rule as TS18037 for the loop form, and tsc words it
            // for the loop rather than for the operator.
            if (p.fn_ctx == .static_block and p.spec == 0) {
                try p.errAtToken(.for_await_in_static_block, aw);
            }
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
                try p.checkForInOfHead(init, is_of);
                _ = try p.bump();
                const right = if (is_of) try p.parseAssignExpr(.{}) else try p.parseExpression(.{});
                _ = try p.expect(.r_paren, .expected_r_paren);
                const body = try p.parseLoopBody();
                const extra = try p.addExtra(ast.ForInOf{ .left = init, .right = right, .is_await = is_await });
                return p.addNode(.{
                    .tag = if (is_of) .for_of_stmt else .for_in_stmt,
                    .main_token = kw,
                    .data = .{ .lhs = extra, .rhs = body },
                });
            }
            // Not a `for…in`/`for…of` head after all, so the destructuring rule
            // applies to this list the way it does to a statement's.
            try p.checkDestructuringInitializers(init);
        }
        _ = try p.expect(.semicolon, .expected_semicolon);
        var cond: Node = null_node;
        if (p.curTag() != .semicolon) cond = try p.parseExpression(.{});
        _ = try p.expect(.semicolon, .expected_semicolon);
        var update: Node = null_node;
        if (p.curTag() != .r_paren and p.curTag() != .eof) update = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        const body = try p.parseLoopBody();
        const extra = try p.addExtra(ast.For{ .init = init, .cond = cond, .update = update });
        return p.addNode(.{ .tag = .for_stmt, .main_token = kw, .data = .{ .lhs = extra, .rhs = body } });
    }

    fn parseSwitchStatement(p: *Parser) PE!Node {
        const kw = try p.bump();
        _ = try p.expect(.l_paren, .expected_l_paren);
        const disc = try p.parseExpression(.{});
        _ = try p.expect(.r_paren, .expected_r_paren);
        _ = try p.expect(.l_brace, .expected_l_brace);
        // An unlabeled `break` inside the clauses targets the switch.
        p.jump.switches += 1;
        defer p.jump.switches -= 1;

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
        // A case/default clause is a statement list but not a module body: the
        // parent tsc sees is the CaseClause, so `case 1: namespace N {}` is
        // TS1235 — see `Parser.element_home`.
        const was_home = p.element_home;
        p.element_home = .other;
        defer p.element_home = was_home;
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
        // Where a `return` may stand, tsc's `checkGrammarReturnStatement` /
        // `checkGrammarStaticBlock`: inside a class static block it is TS18041,
        // and with no function body around it at all it is TS1108. A class field
        // initializer counts as a body (`.sync`), which is why `fn_ctx` and not
        // a "saw a function" flag answers this.
        if (p.spec == 0 and !p.ambient) switch (p.fn_ctx) {
            .static_block => try p.errAtToken(.return_in_static_block, kw),
            .none => try p.errAtToken(.return_outside_function, kw),
            .sync, .async_fn => {},
        };
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
        // An AMBIENT context skips the whole family: tsc guards
        // `checkGrammarBreakOrContinueStatement` behind
        // `checkGrammarStatementInAmbientContext`, which has already answered
        // TS1036 for the statement and returns true. Measured — `break;` alone
        // in a `.d.ts` is TS1036 and nothing else.
        if (p.spec == 0 and !p.ambient) {
            if (p.jumpTargetCode(is_break, label)) |code| try p.errAtToken(code, kw);
        }
        try p.expectSemicolon();
        return p.addNode(.{
            .tag = if (is_break) .break_stmt else .continue_stmt,
            .main_token = kw,
            .data = .{ .lhs = label, .rhs = 0 },
        });
    }

    /// What a `break`/`continue` earns where it stands, or null when it has a
    /// target. tsc walks out of the statement and answers on the first thing it
    /// meets: the target itself (silence), a FUNCTION-LIKE (TS1107 — a jump may
    /// not cross one), or the source file (TS1104/TS1105 unlabeled,
    /// TS1115/TS1116 labeled).
    ///
    /// An unlabeled `break` takes an iteration statement or a `switch`, an
    /// unlabeled `continue` an iteration statement only, and a labeled one any
    /// enclosing label of the same name — except that a labeled `continue`
    /// additionally needs that label to sit on an ITERATION statement, which is
    /// its own TS1115 and the one answer that outranks the boundary.
    fn jumpTargetCode(p: *Parser, is_break: bool, label: u32) ?Code {
        if (label == 0) {
            if (p.jump.loops > 0 or (is_break and p.jump.switches > 0)) return null;
        } else {
            const name = p.tokenTextAt(label);
            for (p.labels.items[p.jump.labels_base..]) |l| {
                if (!std.mem.eql(u8, p.tokenTextAt(l & label_token_mask), name)) continue;
                if (is_break or l & label_on_iteration != 0) return null;
                return .continue_label_not_iteration;
            }
        }
        if (p.jump.in_function) return .jump_crosses_function_boundary;
        if (label != 0) {
            return if (is_break) .break_label_not_enclosing else .continue_label_not_iteration;
        }
        return if (is_break) .break_outside_iteration_or_switch else .continue_outside_iteration;
    }

    /// `Parser.labels` packs "this label sits on an iteration statement" into
    /// the top bit of the label's token index. Token indices are bounded by the
    /// source-length limit, so the bit is free.
    const label_on_iteration: u32 = 1 << 31;
    const label_token_mask: u32 = label_on_iteration - 1;

    /// Does the labeled statement about to be parsed carry an ITERATION
    /// statement? tsc follows a chain of labels to find out
    /// (`isIterationStatement(…, /*lookInLabeledStatements*/ true)`), which is
    /// what `a: b: while (c) { continue a; }` needs. The chain is walked over
    /// LOOKAHEAD, so a chain deeper than the window answers "iteration" and
    /// under-reports rather than inventing a TS1115.
    fn labelTargetsIteration(p: *Parser) bool {
        var i: usize = 0;
        while (i + 1 < max_la) {
            switch (p.peekTag(i)) {
                .keyword_while, .keyword_do, .keyword_for => return true,
                else => {},
            }
            if (isIdentLike(p.peekTag(i)) and p.peekTag(i + 1) == .colon) {
                i += 2;
                continue;
            }
            return false;
        }
        return true;
    }

    /// Parse the body of an iteration statement: one more jump target for the
    /// `break`/`continue` inside it.
    fn parseLoopBody(p: *Parser) PE!Node {
        p.jump.loops += 1;
        defer p.jump.loops -= 1;
        return p.parseSubstatement();
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
        const star = try p.eat(.asterisk);
        if (star != null) flags |= ast.Flags.generator;
        // The NAME's context: a function DECLARATION's name is parsed in the
        // enclosing context (`async function await() {}` at the top level is
        // legal, and a plain `function await() {}` inside a static block is
        // not), while a function EXPRESSION that is itself `async`/`*` parses
        // its name inside the new context — tsc's `parseFunctionExpression`
        // wraps exactly that one in `doInAwaitContext`. Neither ever turns an
        // inherited await context OFF, which is why `.sync` is only installed
        // once the name is behind us.
        const saved_fn_ctx = p.fn_ctx;
        const saved_yield_ctx = p.yield_ctx;
        defer p.yield_ctx = saved_yield_ctx;
        defer p.fn_ctx = saved_fn_ctx;
        const saved_jump = p.jump;
        defer p.jump = saved_jump;
        p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
        const inner: FnCtx = if (flags & ast.Flags.async != 0) .async_fn else .sync;
        if (is_expr and inner == .async_fn) p.fn_ctx = inner;
        var name_tok: u32 = 0;
        if (isIdentLike(p.curTag())) {
            try p.checkStrictReserved();
            try p.checkAwaitReservedName();
            name_tok = try p.bump();
            try p.checkEvalOrArguments(name_tok);
        } else if (!anon_ok) {
            try p.fail(.expected_identifier);
        }
        p.fn_ctx = inner;
        p.yield_ctx = star != null;
        const proto = try p.parseFnProtoRest(flags, name_tok);
        var body: Node = null_node;
        if (p.curTag() == .l_brace) {
            body = try p.parseFunctionBody();
        } else {
            // Overload signature / ambient declaration.
            try p.expectSemicolon();
        }
        try p.checkGeneratorStar(star, body != null_node);
        return p.addNode(.{
            .tag = if (is_expr) .function_expr else .function_decl,
            .main_token = kw,
            .data = .{ .lhs = proto, .rhs = body },
        });
    }

    /// tsc's `checkGrammarFunctionLikeDeclaration`, the asterisk arm: a
    /// generator declared where no body can follow. Blamed on the `*` itself
    /// (`grammarErrorOnNode(node.asteriskToken, …)`) and, like tsc's, a single
    /// `if`/`else` — an AMBIENT generator answers for its context and never for
    /// the body it also lacks, measured on `declare function *df(): any;`.
    ///
    /// A function EXPRESSION always has a body and is never ambient, so the two
    /// arms only ever fire for a declaration or a class method.
    fn checkGeneratorStar(p: *Parser, star: ?TokenIndex, has_body: bool) Error!void {
        const tok = star orelse return;
        if (p.spec != 0) return;
        if (p.ambient) {
            try p.errAtToken(.generator_in_ambient_context, tok);
        } else if (!has_body) {
            try p.errAtToken(.overload_signature_generator, tok);
        }
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
        // tsc's `parseParameterList` returns a MISSING list the moment the `(`
        // is not there — it neither reads parameters nor goes on to expect a
        // `)`. Reading the list anyway made `function =>` answer with a second
        // "')' expected" at end of file that tsc never has.
        if (p.curTag() != .l_paren) {
            try p.fail(.expected_l_paren);
            return .{ .start = 0, .end = 0 };
        }
        _ = try p.bump();
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
        // parses cleanly, no cascade) and report ONCE on the run's first `@`,
        // which is where tsc's `checkGrammarModifiers` stops.
        //
        // Under `experimentalDecorators` they are legal, so the diagnostic is
        // dropped. The expression is still consumed and then DISCARDED rather
        // than hung off the parameter: a legacy parameter decorator is only
        // ever a value read from the enclosing scope, so the sole check it
        // could contribute is on names ztsc would have to bind through a new
        // AST edge. Skipping it under-reports (an undefined name inside
        // `@Inject(Nope)` goes unnamed) and can never invent a diagnostic —
        // the trade the flag is documented to make.
        var deco_at: ?u32 = null;
        // The parameter's FULL start — the offset just past the previous token,
        // leading trivia and all. TS1433 is blamed there where TS1206 is blamed
        // on the `@` itself; measured against tsgo 7.0.2 on
        // `m(a: C,    @dec this: C)`, which answers at the column right after
        // the comma for the one and at the `@` for the other.
        var deco_start: u32 = 0;
        while (p.curTag() == .at) {
            if (p.spec > 0) return error.Backtrack;
            if (deco_at == null) deco_start = p.lastTokEnd();
            const at = try p.bump(); // `@`
            if (deco_at == null) deco_at = at;
            if (canStartExpression(p.curTag())) _ = try p.parseLhsExpression(.{});
        }
        if (deco_at) |at| {
            // A `this` parameter is TS1433 whichever dialect is in force, and it
            // answers ahead of TS1206. Otherwise the only rule ztsc applies here
            // is the dialect one: legacy decorators allow a parameter decorator,
            // TC39 ones do not. tsc narrows the legacy side further (the owner
            // must be a constructor, method or setter WITH A BODY, in a class
            // DECLARATION) — a deliberate under-report, since the owner's body
            // is not parsed yet and no measured case in the suite needs it.
            const site: decorator_target.Site = .{
                .kind = .parameter,
                .this_param = p.curTag() == .keyword_this,
                .param_owner_decoratable = true,
                .has_body = true,
                .in_class_decl = true,
            };
            if (decorator_target.diagnose(p.experimental_decorators, site)) |code| {
                if (code == .decorator_on_this_param)
                    try p.errAtBytes(code, deco_start, deco_start + 1)
                else
                    try p.errAtToken(code, at);
            }
        }
        const start_tok = p.curIdx();
        var flags: u32 = 0;
        // tsc's `parseModifiers` consumes EVERY modifier keyword here, the ones
        // a parameter may not carry included, and leaves the complaint to
        // `checkGrammarModifiers` — which stops at its first hit. Consuming them
        // is what turns `constructor(static a: number)` from a cascade of "','
        // expected" into the one TS1090 tsc answers. The first problem found is
        // held back rather than reported on the spot, because a `this` parameter
        // overrides all of them (see below).
        var problem: ?struct { code: Code, tok: TokenIndex } = null;
        var first_mod: ?TokenIndex = null;
        var seen_static = false;
        while (param_modifiers.role(p.curTag())) |role| {
            // tsc's `hasSeenStaticModifier` guard: a SECOND `static` is not a
            // modifier, so `constructor(static static a)` reads the second one
            // as the parameter's NAME.
            if (seen_static and p.curTag() == .keyword_static) break;
            // Only a modifier if a binding follows (else it's the name).
            if (!canFollowModifier(p.peekTag(1))) break;
            if (first_mod == null) first_mod = p.curIdx();
            if (p.curTag() == .keyword_static) seen_static = true;
            const code: ?Code = switch (role) {
                // Same walk as a class member's: `constructor(readonly readonly
                // y)` is TS1030 and `constructor(override public foo)` is
                // TS1029. A parameter is never in an abstract-member position,
                // so the abstract pairs are unreachable here whatever the class
                // is.
                .property => |bit| blk: {
                    defer flags |= bit;
                    break :blk modifier_order.check(flags, bit, .other, false);
                },
                .rejected => |c| c,
            };
            if (problem == null) {
                if (code) |c| problem = .{ .code = c, .tok = p.curIdx() };
            }
            _ = try p.bump();
        }
        // `checkGrammarModifiers` opens with the `this` parameter and returns
        // there: any modifier on one is TS1433 and nothing else is said, so this
        // replaces whatever the walk above found.
        if (p.curTag() == .keyword_this) {
            if (first_mod) |m| problem = .{ .code = .decorator_on_this_param, .tok = m };
        }
        if (p.spec == 0) {
            if (problem) |it| try p.errAtToken(it.code, it.tok);
        }
        if (try p.eat(.dot_dot_dot) != null) flags |= ast.Flags.rest;
        var name: Node = null_node;
        if (p.curTag() == .keyword_this) {
            const tok = try p.bump();
            name = try p.addNode(.{ .tag = .this_expr, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
        } else {
            name = try p.parseBindingName(.private_name_as_param);
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

    /// A binding name: an identifier or a destructuring pattern.
    ///
    /// `private_code` is what a `#name` here earns — tsc's
    /// `parseIdentifierOrPattern(privateIdentifierDiagnosticMessage)`, whose
    /// caller picks the wording: TS18029 in a variable declaration, TS18009 in a
    /// parameter list, TS18016 anywhere else. tsc reports it and then reads the
    /// token as the name anyway (its `createIdentifier` recurses with
    /// `isIdentifier: true`), so a `#foo` binding produces exactly one
    /// diagnostic rather than that one plus a "Variable declaration expected."
    fn parseBindingName(p: *Parser, private_code: Code) PE!Node {
        switch (p.curTag()) {
            .l_bracket => return p.parseArrayPattern(),
            .l_brace => return p.parseObjectPattern(),
            .private_identifier => {
                try p.errAtCur(private_code);
                const tok = try p.bump();
                return p.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
            },
            else => {
                if (isIdentLike(p.curTag())) {
                    try p.checkStrictReserved();
                    try p.checkAwaitReservedName();
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
                const target = try p.parseBindingName(.private_name_outside_class);
                try p.pushScratch(try p.addNode(.{ .tag = .rest_element, .main_token = dots, .data = .{ .lhs = target, .rhs = 0 } }));
                // TS2462 is blamed on the bound NAME, not on the `...`.
                if (p.curTag() == .comma) try p.errAtToken(.rest_must_be_last, p.nodes.items(.main_token)[target]);
            } else if (p.atStartOfDeclarator()) {
                try p.pushScratch(try p.parseBindingElement());
            } else {
                // tsc's `parsingContextErrors(ArrayBindingElements)`: a token
                // that starts no element is TS1181 here, not the TS1134 that
                // `parseIdentifierOrPattern` would give — the array pattern has
                // its own wording, exactly as the object one has TS1180's.
                //
                // …and `abortParsingListOrMoveToNextToken`'s two-way recovery.
                // A token some ENCLOSING list would take ends this one and is
                // left where it is (`isInSomeParsingContext`, approximated by
                // the statement list, which is the enclosing context that
                // matters here): `let[0] = 100` leaves `0` to become the
                // expression statement tsc parses. Anything else — an operator
                // no list starts with — is SKIPPED and the pattern keeps
                // reading, so `var [...x = a]` stays one diagnostic instead of
                // handing `= a]` to the enclosing declarator.
                try p.fail(.expected_binding_pattern_element);
                if (p.atStartOfStatement()) break;
                _ = try p.bump();
                continue;
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
        const target = try p.parseBindingName(.private_name_outside_class);
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
                var target = try p.parseBindingName(.private_name_outside_class);
                // `{ ...a: b }` — tsc's `parseObjectBindingElement` reads a
                // PropertyName before it can know whether a `:` follows, so a
                // rest element WITH one parses and
                // `checkGrammarBindingElement` reports TS2566 on the bound
                // name. Refusing the `:` here answered "',' expected" and threw
                // away the rest of the declaration with it.
                if (p.curTag() == .colon) {
                    _ = try p.bump();
                    const bound = try p.parseBindingName(.private_name_outside_class);
                    try p.errAtToken(.rest_element_property_name, p.nodes.items(.main_token)[bound]);
                    target = bound;
                }
                try p.pushScratch(try p.addNode(.{ .tag = .rest_element, .main_token = dots, .data = .{ .lhs = target, .rhs = 0 } }));
                // TS2462 is blamed on the bound NAME, not on the `...`.
                if (p.curTag() == .comma) try p.errAtToken(.rest_must_be_last, p.nodes.items(.main_token)[target]);
            } else if (isNameLike(p.curTag()) or p.curTag() == .string_literal or
                p.curTag() == .numeric_literal or p.curTag() == .bigint_literal)
            {
                // A BINDING property name may be a BigInt literal without
                // TS1539: tsc answers only the semantic TS2538 for `{ 0n: f } =
                // arr` (measured — the grammar check is on the three positions
                // that DECLARE a member, not on this one).
                const key = try p.bump();
                var value: Node = null_node;
                if (try p.eat(.colon) != null) {
                    value = try p.parseBindingName(.private_name_outside_class);
                } else {
                    // Shorthand: the key IS the bound name, so `{ await }` in an
                    // await context is TS1359 — while `{ await: other }` names a
                    // property and is fine (measured).
                    try p.checkAwaitReservedNameAt(key);
                }
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
                if (try p.eat(.colon) != null) target = try p.parseBindingName(.private_name_outside_class);
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

    /// Is the `class` being parsed a DECLARATION or an EXPRESSION? The two share
    /// every production; only legacy decorators tell them apart, and they do it
    /// member by member (`decorator_target.zig`).
    const ClassForm = enum { declaration, expression };

    fn parseClassDecl(p: *Parser, flags_in: u32, form: ClassForm) PE!Node {
        const kw = try p.bump(); // `class`
        var name_tok: u32 = 0;
        if (isIdentLike(p.curTag()) and p.curTag() != .keyword_implements) {
            // A class name is parsed in the ENCLOSING context (tsc's
            // `parseNameOfClassDeclarationOrExpression` inherits it), so
            // `class await {}` inside a static block is TS1359.
            try p.checkAwaitReservedName();
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
        const was_abstract_class = p.abstract_class;
        p.abstract_class = flags_in & ast.Flags.abstract != 0;
        defer p.abstract_class = was_abstract_class;
        const was_class_decl = p.in_class_decl;
        p.in_class_decl = form == .declaration;
        defer p.in_class_decl = was_class_decl;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        // The first `@` of the decorator run currently open. The run is judged
        // against the member that closes it (`decorator_target.zig`), so the
        // member itself needs it — a decorated member that is a grammar error
        // suppresses the TS116x its computed name would otherwise earn, exactly
        // as tsc's `checkGrammarModifiers` short-circuits `checkGrammarProperty`.
        var deco_at: ?u32 = null;
        while (p.curTag() != .r_brace and p.curTag() != .eof) {
            const before = p.curIdx();
            const diags_before = p.diags.items.len;
            if (try p.eat(.semicolon) != null) continue;
            if (p.curTag() == .at) {
                if (deco_at == null) deco_at = p.curIdx();
                try p.pushScratch(try p.parseDecorator());
                continue;
            }
            try p.pushScratch(try p.parseClassMember(deco_at, top));
            deco_at = null;
            try p.dropDecoratorsOnStaticBlock(top);
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
    /// TS1206 for a DECORATED static block: `@dec static { }` is not a thing —
    /// tsc's `checkClassStaticBlockDeclaration` reports "Decorators are not
    /// valid here." on the first `@` and never looks at the expression, so the
    /// decorator nodes are dropped from the member list here as well. Keeping
    /// them would have the binder resolve the decorator name and the checker
    /// type it, inventing the TS2304/TS2307 tsc does not report.
    ///
    /// Called after each member is pushed, with `top` the scratch base of the
    /// member list, so the run being dropped is exactly the decorators that
    /// precede the block just parsed.
    fn dropDecoratorsOnStaticBlock(p: *Parser, top: usize) Error!void {
        const items = p.scratch.items;
        if (items.len <= top + 1) return;
        const tags = p.nodes.items(.tag);
        if (tags[items[items.len - 1]] != .block) return;
        var n = items.len - 1;
        while (n > top and tags[items[n - 1]] == .decorator) n -= 1;
        if (n == items.len - 1) return;
        if (p.spec == 0) try p.errAtToken(.decorator_not_valid_here, p.nodes.items(.main_token)[items[n]]);
        items[n] = items[items.len - 1];
        p.scratch.shrinkRetainingCapacity(n + 1);
    }

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
    /// How many class-member modifiers stand in front of a `static { … }` block,
    /// or null when this member is not a static block at all. Bounded by the
    /// lookahead window (`max_la`), so a run longer than three keeps ztsc's
    /// existing answer rather than reading past it — no real code writes even
    /// two, and `classStaticBlock20.ts`'s worst case is `readonly private
    /// static {`.
    fn staticBlockRunLen(p: *Parser) ?u32 {
        var n: u32 = 0;
        while (n < max_la - 2) : (n += 1) {
            switch (p.peekTag(n)) {
                .keyword_static => if (p.peekTag(n + 1) == .l_brace) return n,
                else => {},
            }
            if (classMemberModifierBit(p.peekTag(n)) == 0) return null;
        }
        return null;
    }

    /// The `ast.Flags` bit a class-member modifier keyword carries, or 0 when the
    /// token is not one. Shared by the modifier loop and `staticBlockRunLen` so
    /// the two cannot disagree about what a modifier is.
    fn classMemberModifierBit(tag: TokTag) u32 {
        return switch (tag) {
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
    }

    // --- computed member names ---------------------------------------------

    /// A parsed computed member name `[expr]`, in the protocol the binder and
    /// checker read off the member's `ast.Flags` word.
    const ComputedName = struct {
        /// The `[` — the token tsc anchors a member diagnostic on, because
        /// `member.name` IS the whole computed-name node.
        l_bracket: u32,
        /// The token the member's `main_token` becomes: the key's own literal
        /// for a literal key, the last identifier of a late-bindable one, and
        /// the `[` itself for a key that names nothing.
        name_tok: u32,
        /// The `computed*` bits to OR into the member's flag word.
        flags: u32,
        /// The retained `.computed_name` node, or `null_node` when nothing
        /// downstream needs the expression back.
        key: Node,
        /// Does the key earn a TS116x? (`computed_member.zig`.) The code also
        /// depends on the member's shape, which is only known once the rest of
        /// the member has been parsed, so the caller emits it.
        non_bindable: bool,
    };

    /// Parse a computed member name `[expr]` — the one place class members and
    /// type members agree, so the one place the classification lives.
    ///
    /// tsc has no special cases here: the name is a ComputedPropertyName holding
    /// an expression, and the member it names is decided later, from the
    /// expression's TYPE (`isLateBindableName`). ztsc keys members by an atom
    /// derived from a token, so the classification picks the token — and the
    /// four answers are the four `computed*` flag combinations:
    ///
    ///   * a string or numeric literal key names exactly what the literal
    ///     spells, so it is keyed by the literal token and carries no computed
    ///     flag at all — `["data-state"]: string` is indistinguishable from
    ///     writing the name;
    ///   * `[Symbol.iterator]` and its well-known siblings are keyed by the
    ///     synthetic `__@iterator` atom (`ast.wellKnownSymbolKey`);
    ///   * `[k]` and `[a.b]` name a const `unique symbol` (or a literal
    ///     constant): keyed by a placeholder the checker rekeys nominally;
    ///   * everything else names NOTHING, which is exactly tsc's answer for a
    ///     non-late-bindable name (`bindPropertyOrMethodOrAccessor` binds it
    ///     anonymously and no late-binding pass ever finds it). The member is
    ///     still PARSED and checked — only its name is absent.
    ///
    /// The key expression is retained (`ast.Ast.computedKey`) for the two
    /// classes whose expression the checker must evaluate: the placeholder ones,
    /// whose identifier may not resolve at all (TS2304) or may have a type that
    /// cannot name a property (TS2464), and the nameless ones. A literal needs
    /// no evaluation, and `[Symbol.<known>]` cannot fail — which matters,
    /// because the vendored lib writes hundreds of those and re-checking each
    /// one buys nothing.
    fn parseComputedMemberName(p: *Parser) PE!ComputedName {
        const lb = try p.bump(); // `[`
        const expr = try p.parseAssignExpr(.{});
        _ = try p.eat(.r_bracket); // best-effort; recovery handles malformed
        const tag = p.nodeTagAt(expr);
        if (tag == .string_literal or tag == .number_literal) {
            return .{
                .l_bracket = lb,
                .name_tok = p.nodeMainTokenAt(expr),
                .flags = 0,
                .key = null_node,
                .non_bindable = false,
            };
        }
        if (tag == .member_expr) {
            // `member_expr` stores its property NAME as a token, not a node.
            const d = p.nodeDataAt(expr);
            if (p.nodeTagAt(d.lhs) == .identifier and p.memberNameIsIdent(d.rhs)) {
                const obj_tok = p.nodeMainTokenAt(d.lhs);
                const name_tok = d.rhs;
                if (std.mem.eql(u8, p.tokenTextAt(obj_tok), "Symbol") and
                    ast.wellKnownSymbolKey(p.tokenTextAt(name_tok)) != null)
                {
                    return .{
                        .l_bracket = lb,
                        .name_tok = name_tok,
                        .flags = ast.Flags.computed,
                        .key = null_node,
                        .non_bindable = false,
                    };
                }
                // `[a.b]`: the placeholder atom is built from the two
                // identifiers' text, and `memberNameKey` finds the object one at
                // `name_tok - 2` — which holds because `[`, `a`, `.`, `b` are
                // adjacent in the token stream (comments are trivia).
                return .{
                    .l_bracket = lb,
                    .name_tok = name_tok,
                    .flags = ast.Flags.computed | ast.Flags.computed_sym | ast.Flags.computed_sym_qual,
                    .key = try p.addComputedNameNode(lb, expr),
                    .non_bindable = false,
                };
            }
        }
        if (tag == .identifier) {
            return .{
                .l_bracket = lb,
                .name_tok = p.nodeMainTokenAt(expr),
                .flags = ast.Flags.computed | ast.Flags.computed_sym,
                .key = try p.addComputedNameNode(lb, expr),
                .non_bindable = false,
            };
        }
        return .{
            .l_bracket = lb,
            .name_tok = lb,
            .flags = ast.Flags.computed_expr,
            .key = try p.addComputedNameNode(lb, expr),
            .non_bindable = p.computedNameIsNonBindable(expr),
        };
    }

    fn addComputedNameNode(p: *Parser, lb: u32, expr: Node) Error!Node {
        return p.addNode(.{ .tag = .computed_name, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } });
    }

    /// tsc's `isNonBindableDynamicName`, as tsgo answers it — purely
    /// syntactically. See `computed_member.zig` for the measurements.
    fn computedNameIsNonBindable(p: *Parser, expr: Node) bool {
        return switch (p.nodeTagAt(expr)) {
            // `isStringOrNumericLiteralLike`: a NO-SUBSTITUTION template
            // literal names a property just as a string literal does
            // (`` [`tpl`] `` is silent, measured).
            .string_literal, .number_literal, .template_literal => false,
            // `isSignedNumericLiteral`: `[-1]` / `[+1]` name `-1` / `1`.
            .prefix_unary => switch (p.tokTagAt(p.nodeMainTokenAt(expr))) {
                .plus, .minus => p.nodeTagAt(p.nodeDataAt(expr).lhs) != .number_literal,
                else => true,
            },
            else => !p.isEntityNameExpr(expr),
        };
    }

    /// tsc's `isEntityNameExpression`: an identifier, or a dotted chain of
    /// them. `this.x`, `a?.b` and `(a)` are all NOT one — which is why
    /// `[(s)]` reports where `[s]` does not.
    fn isEntityNameExpr(p: *Parser, expr: Node) bool {
        return switch (p.nodeTagAt(expr)) {
            .identifier => true,
            .member_expr => blk: {
                const d = p.nodeDataAt(expr);
                break :blk p.memberNameIsIdent(d.rhs) and p.isEntityNameExpr(d.lhs);
            },
            else => false,
        };
    }

    /// Is a `member_expr`'s property-name TOKEN an Identifier in tsc's sense? A
    /// keyword in that position is one (`a.default`); a private name (`a.#b`) is
    /// not, which is what keeps it out of an entity-name chain.
    fn memberNameIsIdent(p: *Parser, tok: u32) bool {
        const t = p.tokTagAt(tok);
        return isNameLike(t) and t != .private_identifier;
    }

    /// Finish a member whose name was computed: report the TS116x its home and
    /// shape earn, and retain the key expression against the member node.
    ///
    /// `modifiers_reported` is tsc's short-circuit — `checkGrammarProperty` and
    /// `checkGrammarMethod` never run on a member whose modifier list already
    /// answered, so `@dec [foo()]: any` in a class expression is TS1206 alone
    /// and `public private [foo()]: any` is TS1028 alone. The key is retained
    /// either way: the diagnostic is suppressed, the AST edge is not.
    fn finishComputedName(
        p: *Parser,
        cn: ComputedName,
        member: Node,
        home: computed_member.Home,
        kind: computed_member.MemberKind,
        modifiers_reported: bool,
    ) Error!void {
        if (cn.non_bindable and !modifiers_reported) {
            if (computed_member.grammarCode(home, kind, p.ambient)) |code| {
                try p.errAtToken(code, cn.l_bracket);
            }
        }
        if (cn.key != null_node) try p.computed_keys.append(p.gpa, .{ .member = member, .key = cn.key });
    }

    /// `deco_at` is the first `@` of the decorator run this member closes, if
    /// any, and `members_top` the scratch base of the member list — the members
    /// already parsed, which a decorated accessor consults for its pair.
    fn parseClassMember(p: *Parser, deco_at: ?u32, members_top: usize) PE!Node {
        // `static { … }` — a class static initialization block. Parsed as a
        // plain `.block` member so the statements inside land in the tree with
        // real spans instead of derailing the member loop (which read `static`
        // as a FIELD name and then answered "';' expected" at the `{`, the
        // single largest source of ztsc's excess TS1005).
        //
        // The block is a function-like boundary and an await context, which
        // `fn_ctx` records for the four grammar rules that only hold there
        // (TS18037/TS1163/TS18041/TS18038) and for `await`-as-a-name (TS1359).
        //
        // A modifier RUN may precede it (`async static {`, `public static {`,
        // `readonly private static {`): tsc parses all of them as one modifier
        // list on the static block and reports a single TS1184 on the FIRST one
        // (`checkGrammarModifiers` returns on its first hit). Without the run
        // the modifier loop below broke on the `{` after `static`, read `static`
        // as the member NAME and answered a TS1005/TS1434 cascade.
        if (p.staticBlockRunLen()) |n| {
            if (n > 0) {
                if (p.spec == 0) try p.errAtCur(.modifiers_not_allowed_here);
                for (0..n) |_| _ = try p.bump();
            }
            _ = try p.bump(); // `static`
            const saved_fn_ctx = p.fn_ctx;
            const saved_yield_ctx = p.yield_ctx;
            defer p.yield_ctx = saved_yield_ctx;
            defer p.fn_ctx = saved_fn_ctx;
            const saved_jump = p.jump;
            defer p.jump = saved_jump;
            p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
            p.fn_ctx = .static_block;
            p.yield_ctx = false;
            return p.parseBlock();
        }

        var flags: u32 = 0;
        // The modifier run, COLLECTED rather than judged on the spot: tsc walks
        // one modifier list per member, decorators and keywords together, and
        // `return`s on its first error — and a decorator sits ahead of every
        // keyword, so `@dec public private x` in a class expression is the
        // decorator's TS1206 alone. Half of the walk (TS1242/TS1244/TS1253, and
        // TS1089's trailing block) also needs the member's KIND, which is not
        // known until the name and what follows it have been read. So the run is
        // banked here and `memberModErr` judges it at each report site, once the
        // shape — and so the decorator's verdict — is settled.
        //
        // Sixteen entries is enough by construction: `classMemberModifierBit`
        // spells twelve distinct modifiers, so a longer run must repeat one and
        // the walk returns at that repeat well inside the buffer. A run that
        // somehow overflows anyway drops its tail, which can only turn a
        // diagnostic into silence — never into a wrong one.
        var mods: [16]modifier_order.Mod = undefined;
        var n_mods: usize = 0;
        // `const` in a class-member modifier list is TS1248 and nothing else —
        // it carries no flag because it means nothing. tsc's parser accepts it
        // as a modifier so the member behind it still parses (`static const H =
        // 1` declares `H`), and `checkGrammarModifiers` then rejects it on the
        // member NAME.
        var saw_const = false;
        while (true) {
            const is_const = p.curTag() == .keyword_const;
            const bit = classMemberModifierBit(p.curTag());
            if (bit == 0 and !is_const) break;
            // A modifier only if a member name (or `*`/`[`) follows on any
            // line (get/set/async additionally require same-line names).
            const t1 = p.peekTag(1);
            const name_follows = isNameLike(t1) or t1 == .string_literal or
                t1 == .numeric_literal or t1 == .l_bracket or t1 == .asterisk;
            if (!name_follows) break;
            if (is_const) {
                saw_const = true;
                _ = try p.bump();
                continue;
            }
            if ((bit == ast.Flags.get or bit == ast.Flags.set or bit == ast.Flags.async) and p.peekNewline(1)) break;
            if (n_mods < mods.len) {
                mods[n_mods] = .{ .bit = bit, .token = p.curIdx() };
                n_mods += 1;
            }
            _ = try p.bump();
            flags |= bit;
        }

        const star = try p.eat(.asterisk);
        if (star != null) flags |= ast.Flags.generator;

        // Member name.
        var name_tok: u32 = 0;
        var computed: ?ComputedName = null;
        switch (p.curTag()) {
            .l_bracket => {
                // Computed member name / index signature in class.
                if (p.atIndexSignature()) {
                    _ = try p.reportMemberGrammar(deco_at, .{ .kind = .other }, p.memberModErr(mods[0..n_mods], .other, 0));
                    return p.parseIndexSignatureAsClassMember(flags);
                }
                const cn = try p.parseComputedMemberName();
                name_tok = cn.name_tok;
                flags |= cn.flags;
                computed = cn;
            },
            .string_literal, .numeric_literal, .private_identifier => name_tok = try p.bump(),
            // `class K { 4n = 0 }` — TS1539, exactly as in an object literal.
            .bigint_literal => {
                try p.errAtCur(.bigint_property_name);
                name_tok = try p.bump();
            },
            else => {
                if (isNameLike(p.curTag())) {
                    name_tok = try p.bump();
                } else {
                    // A CLASS member name: tsc's `parseClassElement` answers
                    // TS1068 here, not the object-literal TS1136.
                    _ = try p.reportMemberGrammar(deco_at, .{ .kind = .other }, p.memberModErr(mods[0..n_mods], .other, 0));
                    try p.fail(.expected_class_member);
                    return p.errorNode();
                }
            },
        }

        // TS1248 joins the modifier list's one diagnostic, blamed on the NAME.
        // `const` is never the FIRST error of a list that already has one:
        // tsc stops at the earliest modifier it rejects, and a repeated or
        // out-of-order one ahead of the `const` gets there first.
        const const_at: TokenIndex = if (saw_const) name_tok else 0;

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
            const saved_fn_ctx = p.fn_ctx;
            const saved_yield_ctx = p.yield_ctx;
            defer p.yield_ctx = saved_yield_ctx;
            defer p.fn_ctx = saved_fn_ctx;
            const saved_jump = p.jump;
            defer p.jump = saved_jump;
            p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
            p.fn_ctx = if (flags & ast.Flags.async != 0) .async_fn else .sync;
            p.yield_ctx = star != null;
            const proto = try p.parseFnProtoRest(flags, name_tok);
            var body: Node = null_node;
            if (p.curTag() == .l_brace) {
                body = try p.parseFunctionBody();
            } else {
                try p.expectSemicolon(); // overload signature / abstract
            }
            const member = try p.addNode(.{ .tag = .class_method, .main_token = name_tok, .data = .{ .lhs = proto, .rhs = body } });
            try p.checkGeneratorStar(star, body != null_node);
            const is_accessor = flags & (ast.Flags.get | ast.Flags.set) != 0;
            const is_ctor = !is_accessor and computed == null and
                p.tokTagAt(name_tok) == .keyword_constructor;
            const mod_member: modifier_order.Member = if (is_accessor)
                .accessor
            else if (is_ctor)
                .constructor
            else
                .method;
            const grammar_err = try p.reportMemberGrammar(deco_at, .{
                .kind = if (is_accessor)
                    .accessor
                else if (is_ctor)
                    .constructor
                else
                    .method,
                .private_name = computed == null and p.tokTagAt(name_tok) == .private_identifier,
                .has_body = body != null_node,
                .in_class_decl = p.in_class_decl,
                .second_accessor_of_modified_pair = is_accessor and computed == null and
                    p.isSecondAccessorOfModifiedPair(members_top, name_tok, flags),
            }, p.memberModErr(mods[0..n_mods], mod_member, const_at));
            if (computed) |cn| {
                // An accessor is judged by neither `checkGrammarProperty` nor
                // `checkGrammarMethod`; a method is, and what it earns turns on
                // whether it has a BODY.
                const kind: computed_member.MemberKind = if (is_accessor)
                    .accessor
                else if (body != null_node)
                    .method_impl
                else
                    .method_signature;
                try p.finishComputedName(cn, member, .class_body, kind, grammar_err);
            }
            return member;
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
        if (try p.eat(.eq) != null) {
            // A field initializer runs as its own implicit function, so it is
            // parsed outside any enclosing await context: `x = await` inside a
            // class written in a static block names the outer `await` binding.
            const saved_fn_ctx = p.fn_ctx;
            const saved_yield_ctx = p.yield_ctx;
            defer p.yield_ctx = saved_yield_ctx;
            defer p.fn_ctx = saved_fn_ctx;
            const saved_jump = p.jump;
            defer p.jump = saved_jump;
            p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
            p.fn_ctx = .sync;
            p.yield_ctx = false;
            init = try p.parseAssignExpr(.{});
        }
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.Field{ .flags = flags, .type_ann = type_ann, .init = init });
        const member = try p.addNode(.{ .tag = .class_field, .main_token = name_tok, .data = .{ .lhs = extra, .rhs = 0 } });
        const grammar_err = try p.reportMemberGrammar(deco_at, .{
            .kind = .property,
            .private_name = computed == null and p.tokTagAt(name_tok) == .private_identifier,
            .abstract = flags & ast.Flags.abstract != 0,
            .declare = flags & ast.Flags.declare != 0,
            .in_class_decl = p.in_class_decl,
        }, p.memberModErr(mods[0..n_mods], .property, const_at));
        if (computed) |cn| try p.finishComputedName(cn, member, .class_body, .property, grammar_err);
        return member;
    }

    /// The one diagnostic a class member's KEYWORD modifier run earns, judged
    /// against the member kind the run turned out to introduce. `const_at` is
    /// the member's name token when the run carried a `const` (TS1248, blamed
    /// on the name) and 0 otherwise — it is the last thing tsc's walk can
    /// reach, so it only speaks when the walk itself found nothing.
    fn memberModErr(
        p: *Parser,
        mods: []const modifier_order.Mod,
        member: modifier_order.Member,
        const_at: TokenIndex,
    ) ?ModifierErr {
        if (modifier_order.walk(mods, member, p.abstract_class)) |f| {
            return .{ .code = f.code, .token = f.token };
        }
        if (const_at != 0) return .{ .code = .const_class_member, .token = const_at };
        return null;
    }

    /// The one grammar diagnostic a class member's modifier list earns, if any.
    /// tsc walks decorators and keyword modifiers as ONE list and `return`s on
    /// its first hit, and a decorator always precedes the keywords, so the
    /// decorator's verdict wins over a repeated/out-of-order modifier. True when
    /// something was reported — tsc's
    /// `if (!checkGrammarModifiers(node) && !checkGrammarProperty(node))`, which
    /// is what keeps the TS116x of a decorated computed name quiet.
    fn reportMemberGrammar(
        p: *Parser,
        deco_at: ?u32,
        site: decorator_target.Site,
        mod_err: ?ModifierErr,
    ) Error!bool {
        if (p.spec != 0) return false;
        if (deco_at) |at| {
            if (decorator_target.diagnose(p.experimental_decorators, site)) |code| {
                try p.errAtToken(code, at);
                return true;
            }
        }
        if (mod_err) |m| {
            try p.errAtToken(m.code, m.token);
            return true;
        }
        return false;
    }

    /// Is the accessor being finished the SECOND `get`/`set` of its name in this
    /// class body, with the first DECORATED? tsc's `getAllAccessorDeclarations`
    /// pairs by property name and matching `static`-ness and skips dynamic names
    /// entirely; only the second of the pair may be told off (TS1207).
    ///
    /// tsc's own wording for the first accessor's side of the test is "has
    /// modifiers", but tsgo 7.0.2 answers as though it read "has decorators":
    /// `static get x() {}` followed by `@dec static set x(v) {}` is silent,
    /// where `@a get x() {}` followed by `@b set x(v) {}` is TS1207.
    ///
    /// `members_top` is the scratch base of the member list, whose entries are
    /// the members already parsed plus the decorator nodes between them.
    fn isSecondAccessorOfModifiedPair(p: *Parser, members_top: usize, name_tok: u32, flags: u32) bool {
        const items = p.scratch.items[members_top..];
        const tags = p.nodes.items(.tag);
        const data = p.nodes.items(.data);
        const main = p.nodes.items(.main_token);
        const name = p.tokenTextAt(name_tok);
        const is_static = flags & ast.Flags.static != 0;
        var seen: u32 = 0;
        var first_modified = false;
        for (items, 0..) |m, i| {
            if (tags[m] != .class_method) continue;
            // `flags` is `ast.FnProto`'s first field, so it is the first word of
            // the method's extra data.
            const proto_flags = p.extra.items[data[m].lhs];
            if (proto_flags & (ast.Flags.get | ast.Flags.set) == 0) continue;
            if ((proto_flags & ast.Flags.static != 0) != is_static) continue;
            if (main[m] == 0 or !std.mem.eql(u8, p.tokenTextAt(main[m]), name)) continue;
            seen += 1;
            if (seen > 1) return false; // this member is the third or later
            first_modified = i > 0 and tags[items[i - 1]] == .decorator;
        }
        return seen == 1 and first_modified;
    }

    /// A modifier-order diagnostic held back until the member's whole modifier
    /// list has been judged. See `reportMemberGrammar`.
    const ModifierErr = struct { code: Code, token: u32 };

    fn parseIndexSignatureAsClassMember(p: *Parser, flags: u32) PE!Node {
        return p.parseIndexSignature(flags, true);
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
        const members = blk: {
            const saved = p.in_interface_body;
            defer p.in_interface_body = saved;
            p.in_interface_body = true;
            break :blk try p.parseTypeMemberList();
        };
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
            try p.checkAwaitReservedName();
            return p.bump();
        }
        try p.fail(.expected_identifier);
        return p.lastIdx();
    }

    /// The EXPORT name of `export * as X from "m"` / `export * as "s" from "m"`
    /// — a ModuleExportName, so a string literal is legal there (ES2022
    /// arbitrary module namespace identifiers). Only the export side: a LOCAL
    /// binding (`import { "s" as x }`) still has to be an identifier.
    ///
    /// tsc parses it with `parseIdentifierName`, which takes any IdentifierName
    /// — every reserved word included. `export * as default from "./0"` is the
    /// spelling that needs it, and it is neither exotic nor an error: it is how
    /// a module re-exports another's namespace AS its default, and the whole
    /// point of `exportAsNamespace4`/`5`. Routing it through `expectIdentLike`
    /// rejected the `default` (TS1003) and then read the rest of the line as a
    /// statement (TS1434), two false positives against an oracle that reports
    /// nothing at all. An IdentifierName position is also exempt from the
    /// strict-reserved and `await` checks `expectIdentLike` performs — see
    /// `checkStrictReserved`.
    fn expectModuleExportName(p: *Parser) PE!u32 {
        if (isModuleExportName(p.curTag())) return p.bump();
        try p.fail(.expected_identifier);
        return p.lastIdx();
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

    /// TS1359, tsc's `createIdentifier`: inside an await context — an `async`
    /// function's parameters and body, or a class static block — `await` is not
    /// a BindingIdentifier, so a declaration trying to bind that name reports
    /// "Identifier expected. 'await' is a reserved word that cannot be used
    /// here." Called from the same funnels as `checkStrictReserved` plus the two
    /// name positions that bump their token directly (a class name, an
    /// object-pattern shorthand), and deliberately NOT from an identifier
    /// REFERENCE: there `await` is the operator, and a missing operand is the
    /// TS1109 the unary arm reports.
    ///
    /// The message names the token, which the renderer reads back off the span —
    /// see `main.zig`'s emit loop.
    fn checkAwaitReservedName(p: *Parser) Error!void {
        if (p.spec > 0 or p.ambient) return;
        if (!p.fn_ctx.awaits() or p.curTag() != .keyword_await) return;
        try p.errAtCur(.reserved_word_here);
    }

    /// `checkAwaitReservedName` for a token that has already been consumed.
    fn checkAwaitReservedNameAt(p: *Parser, tok: u32) Error!void {
        if (p.spec > 0 or p.ambient) return;
        if (!p.fn_ctx.awaits() or p.tokTagAt(tok) != .keyword_await) return;
        try p.errAtToken(.reserved_word_here, tok);
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
        // `enum void {}` — a RESERVED word as the enum's name. tsc's
        // `parseIdentifier` consumes the word (its answer is TS1359, on the word)
        // and carries on with the body, so the `{` is still the `{`. Leaving the
        // keyword unconsumed sent it into `parseEnumMember` instead — legal now
        // that a member name is any PropertyName — and the `{` behind it became a
        // second, false "',' expected".
        if (p.curTag() != .l_brace and p.curTag().isKeyword()) _ = try p.bump();
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
        // A COMPUTED member name is legal in an enum when it wraps a string,
        // numeric or no-substitution-template literal — tsc's
        // `checkGrammarEnumDeclaration` only rejects the ones that are not
        // (`[foo]`, `["a" + "b"]`, `[0n]`) — and the name it declares is the
        // literal's own, so the brackets are simply consumed and the literal
        // becomes the member's name token: `["4"] = 4` and `"4" = 4` are the
        // same member, which is also how they collide.
        var computed_at: ?u32 = null;
        if (p.curTag() == .l_bracket) {
            if (p.peekTag(2) == .r_bracket and switch (p.peekTag(1)) {
                .string_literal, .numeric_literal, .no_substitution_template_literal => true,
                else => false,
            }) {
                computed_at = p.curIdx();
                _ = try p.bump(); // `[`
            } else {
                if (p.spec > 0) return error.Backtrack;
                try p.errAtCur(.computed_name_in_enum);
                // Consume the whole member so nothing cascades: the bracketed
                // expression, then any initializer. No member is produced —
                // tsc's answer for one of these is the TS1164 alone.
                _ = try p.bump(); // `[`
                var depth: u32 = 1;
                while (depth > 0 and p.curTag() != .eof) {
                    switch (p.curTag()) {
                        .l_bracket => depth += 1,
                        .r_bracket => depth -= 1,
                        else => {},
                    }
                    _ = try p.bump();
                }
                if (try p.eat(.eq) != null) _ = try p.parseAssignExpr(.{});
                return p.errorNode();
            }
        }
        // Member name: an enum member name is a PropertyName, so a numeric or
        // private one PARSES and is then rejected by name (TS2452 / TS18024) —
        // rejecting it here instead cost a false TS1003 and, with it, the whole
        // file's semantic pass. TS2452 is about the NAME, not the token: a
        // BigInt literal (`0n`) and a string that spells a number (`"3"`) earn
        // it as surely as `3` does (measured).
        const name_code: ?Code = switch (p.curTag()) {
            .numeric_literal, .bigint_literal => .enum_member_numeric_name,
            .string_literal, .no_substitution_template_literal => if (literals.isNumericName(literals.stripQuotes(p.laText(0))))
                .enum_member_numeric_name
            else
                null,
            .private_identifier => .enum_member_private_name,
            else => null,
        };
        // `isNameLike`, not `isIdentLike`: a PropertyName admits every reserved
        // word, so `enum Bool { false }` and `enum E { new, default }` are legal
        // enums whose members are named after keywords (measured — tsgo answers
        // nothing for either, nor for the `Bool.false` type reference they make
        // possible). Rejecting them here cost a false TS1003 plus the TS1128
        // cascade behind it.
        if (name_code == null and !isNameLike(p.curTag()) and p.curTag() != .string_literal and
            p.curTag() != .no_substitution_template_literal)
        {
            try p.fail(.expected_identifier);
            return p.errorNode();
        }
        if (name_code) |code| {
            if (p.spec > 0) return error.Backtrack;
            // tsc blames the whole member name, which for a computed one starts
            // at the `[`.
            if (computed_at) |lb| try p.errAtToken(code, lb) else try p.errAtCur(code);
        }
        const name_tok = try p.bump();
        if (computed_at != null) _ = try p.expect(.r_bracket, .expected_r_bracket);
        var init: Node = null_node;
        if (try p.eat(.eq) != null) init = try p.parseAssignExpr(.{});
        return p.addNode(.{ .tag = .enum_member, .main_token = name_tok, .data = .{ .lhs = init, .rhs = 0 } });
    }

    /// `namespace N { ... }` / `module N { ... }`, dotted names included. The
    /// `namespace`/`module` keyword must not yet be consumed. A string-module
    /// name (`module "x" {}`) is `parseAmbientModule` and a missing one
    /// (`module {}`) is `parseAnonymousNamespace`; both are dispatched before
    /// this is reached.
    fn parseNamespaceDecl(p: *Parser, flags: u32) PE!Node {
        const kw = try p.bump(); // `namespace` / `module`
        // `declare namespace N { ... }` makes the whole body ambient; a plain
        // `namespace` nested in an ambient one inherits it. Set here rather than
        // inside `parseNamespaceName` so a dotted name sets it once, for the one
        // body all its segments share.
        const was_ambient = p.ambient;
        p.ambient = was_ambient or flags & ast.Flags.declare != 0;
        defer p.ambient = was_ambient;
        // A namespace block IS a module body however deeply it is nested.
        const was_home = p.element_home;
        p.element_home = .module_block;
        defer p.element_home = was_home;
        return p.parseNamespaceName(kw, flags, false);
    }

    /// One segment of a namespace name, plus everything to its right.
    ///
    /// A DOTTED name is sugar: `namespace A.B.C { … }` declares `A`, whose sole
    /// member is `B`, whose sole member is `C`, which holds the body — which is
    /// exactly the tree tsc's `parseModuleOrNamespaceDeclaration` builds, one
    /// recursive call per `.`. Desugaring here means the binder, the linker and
    /// the checker never learn that dotted names exist.
    ///
    /// Each inner segment is wrapped in an `export_decl`: `A.B.C` is reachable
    /// from outside as `A.B.C`, so every segment but the outermost is an export
    /// of the one before it. tsc gets there by a different route (the nested
    /// declaration is a member of a namespace whose only body is that
    /// declaration) and the observable answer is the same.
    fn parseNamespaceName(p: *Parser, kw: u32, flags: u32, nested: bool) PE!Node {
        // A segment behind a `.` is an IdentifierName, so a reserved word PARSES
        // there and only there — tsc's `parseIdentifierName()` for the nested
        // case against `parseIdentifier()` for the first, which is what makes
        // `declare namespace chrome.debugger { }` parse while `declare namespace
        // debugger { }` does not.
        //
        // Parsing is not the whole verdict: tsc's BINDER runs
        // `checkStrictModeIdentifier` over the name either way, and a
        // ModuleDeclaration's name is not one of the IdentifierName positions
        // that check exempts. So a FUTURE-reserved word is TS1212 on a nested
        // segment exactly as on the first (`namespace private.public.foo`,
        // measured) while `debugger`, a plain reserved word, stays legal.
        const name_tok = if (nested and isNameLike(p.curTag()) and p.curTag() != .private_identifier) blk: {
            try p.checkStrictReserved();
            break :blk try p.bump();
        } else try p.expectIdentLike();
        // TS1540: `module M { }` is the deprecated spelling of `namespace M { }`
        // — only `declare module "spec" { }` may still say `module`, and that
        // form never reaches here. tsc blames the NAME, so a dotted name
        // answers once per segment.
        if (p.spec == 0 and p.tokTagAt(kw) == .keyword_module) {
            try p.errAtToken(.module_keyword_for_namespace, name_tok);
        }
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        if (try p.eat(.dot) != null) {
            // The inner segments carry neither `declare` nor `export`: the
            // outermost one already answered for both, and repeating `declare`
            // would re-enter the ambient bookkeeping this body has entered once.
            const inner = try p.parseNamespaceName(kw, flags & ~ast.Flags.declare, true);
            try p.pushScratch(try p.addNode(.{
                .tag = .export_decl,
                .main_token = kw,
                .data = .{ .lhs = inner, .rhs = 0 },
            }));
        } else {
            _ = try p.expect(.l_brace, .expected_l_brace);
            try p.parseStatementList(top, .r_brace, false);
            _ = try p.expect(.r_brace, .expected_r_brace);
        }
        const body = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.NamespaceData{
            .flags = flags,
            .name_token = name_tok,
            .body_start = body.start,
            .body_end = body.end,
        });
        return p.addNode(.{ .tag = .namespace_decl, .main_token = kw, .data = .{ .lhs = extra, .rhs = 0 } });
    }

    /// `module { … }` / `namespace { … }` — a namespace with NO NAME, which is
    /// TS1437 on the `{`. tsc parses it as a namespace whose name node is
    /// missing, so the body still parses and its declarations still bind;
    /// ztsc models "declares no namespace symbol, contributes its body outward"
    /// with the same `global_aug` flag `declare global { … }` uses, which is
    /// what keeps `declare module { class XDate … }` followed by
    /// `new XDate()` from inventing a TS2304 the oracle does not report.
    fn parseAnonymousNamespace(p: *Parser, declared: bool) PE!Node {
        const kw = try p.bump(); // `module` / `namespace`
        if (p.spec == 0) try p.errAtCur(.namespace_needs_a_name);
        _ = try p.expect(.l_brace, .expected_l_brace);
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        const was_ambient = p.ambient;
        p.ambient = was_ambient or declared;
        defer p.ambient = was_ambient;
        const was_home = p.element_home;
        p.element_home = .module_block;
        defer p.element_home = was_home;
        try p.parseStatementList(top, .r_brace, false);
        _ = try p.expect(.r_brace, .expected_r_brace);
        const body = try p.scratchToSpan(top);
        const extra = try p.addExtra(ast.NamespaceData{
            .flags = ast.Flags.global_aug | (if (declared) ast.Flags.declare else 0),
            .name_token = kw,
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
        // A module block IS a module body however deeply it is nested.
        const was_home = p.element_home;
        p.element_home = .module_block;
        defer p.element_home = was_home;
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

    /// Can this token start the NAME of a `module "…" { }`? A quoted string is
    /// the only legal spelling, but a template is taken too so it can be
    /// rejected with TS1443 instead of derailing the declaration behind it.
    fn isModuleNameLiteral(t: TokTag) bool {
        return switch (t) {
            .string_literal, .no_substitution_template_literal, .template_head => true,
            else => false,
        };
    }

    /// `declare module "spec" { ... }` (the `declare` already consumed).
    /// Modeled as a `namespace_decl` flagged `ambient_module`; `name_token`
    /// is the specifier string literal. The block's exports become an ambient
    /// module the linker resolves imports of `"spec"` against, and merges into
    /// a real module's exports when `"spec"` also resolves (augmentation).
    ///
    /// `declared` is whether a `declare` modifier introduced this declaration.
    /// TS1035: a QUOTED module name declares an EXTERNAL module, which only an
    /// ambient declaration may do — `module "M" { }` on its own is an error,
    /// while the same source in a `.d.ts` is silent because the whole file is
    /// ambient from its first token.
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
    fn parseAmbientModule(p: *Parser, declared: bool) PE!Node {
        const kw = try p.bump(); // `module`
        const spec_tok = p.curIdx();
        if (p.curTag() == .no_substitution_template_literal or p.curTag() == .template_head) {
            // TS1443: a module name is a `'`/`"` string, never a template. tsc
            // parses the template anyway — substitutions and all — so the body
            // behind it still parses; only the name is rejected.
            _ = try p.parseTemplateExpr(false);
            if (p.spec == 0) try p.errAtToken(.module_name_needs_quoted_string, spec_tok);
        } else {
            _ = try p.bump(); // string literal
            if (!declared and !p.ambient and p.spec == 0) {
                try p.errAtToken(.quoted_module_name_needs_ambient, spec_tok);
            }
        }
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
        // A module block IS a module body however deeply it is nested.
        const was_home = p.element_home;
        p.element_home = .module_block;
        defer p.element_home = was_home;
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

    /// `import …;` in all its spellings. `export_kw` is the token index of a
    /// preceding `export` modifier, or null (an optional, not a 0 sentinel: the
    /// `export` of a file's FIRST statement IS token 0) — tsc parses
    /// `export import` as one
    /// statement with a modifier list and lets `checkGrammarModifiers` judge it:
    /// an ImportEqualsDeclaration (`export import A = B.C;`, the exported
    /// namespace alias) accepts `export`, while an ES6 ImportDeclaration
    /// (`export import d from "m"`) earns TS1191 and nothing else — the file
    /// still parses, so its semantic pass runs (the `es6Import*WithExport`
    /// family is 8 corpus cases whose real keys are all downstream of that).
    fn parseImportStatement(p: *Parser, export_kw: ?u32) PE!Node {
        // `import(` / `import.` are expressions, not declarations.
        if (p.peekTag(1) == .l_paren or p.peekTag(1) == .dot) {
            return p.parseExpressionStatement();
        }
        const kw = try p.bump(); // `import`
        p.saw_module_syntax = true;
        // `Flags.exported` deliberately NOT set on the ES6 form: the binder reads
        // only `type_only` out of `ImportData.flags`, and whether tsc's
        // `export import { a } from "m"` really re-exports `a` (the family's
        // remaining TS2323/TS2614 keys) is a binder question, not a parse one.
        var flags: u32 = 0;

        // `import "module";` — a side-effect-only import, which carries import
        // ATTRIBUTES like every other form (`import "./a.json" with { type:
        // "json" }`); skipping them only in the clause-ful arms cost a false
        // TS1005 at the `with`, and the file's whole semantic pass with it.
        if (p.curTag() == .string_literal) {
            const mod = try p.bump();
            try p.skipImportAttributes();
            try p.expectSemicolon();
            if (export_kw) |m| try p.errAtToken(.import_cannot_have_modifiers, m);
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

        // `import defer * as ns from "m"` (TC39 deferred module evaluation,
        // TS 5.9): `defer` is a CONTEXTUAL keyword, not a binding, and the
        // namespace clause is the only one the form admits. Nothing about the
        // TYPES changes — deferral is an evaluation-order guarantee — so the
        // token is simply dropped and `* as ns` binds as usual. Recognized
        // only immediately before `*`: `import defer from "m"` and `import
        // defer, * as ns from "m"` are both ordinary DEFAULT imports of a
        // binding named `defer`, and reading `defer` as the keyword there
        // invented a namespace and lost a TS1192.
        if (isIdentLike(p.curTag()) and p.peekTag(1) == .asterisk and
            std.mem.eql(u8, p.laText(0), "defer")) _ = try p.bump();

        if (isIdentLike(p.curTag())) {
            // `import d ...` — but `import x = require(...)` is out of subset.
            default_name = try p.bump();
            // The ImportEqualsDeclaration arm — `export` belongs here, and it
            // anchors the node: a declaration's span starts at its first
            // MODIFIER, which is what puts TS1202 on the `export` of
            // `export import a = require("m")` rather than on the `import`.
            //
            // `flags` (i.e. `type_only`) rides along: `import type X =
            // require("m")` is erased, so tsc's `checkImportEqualsDeclaration`
            // exempts it from the same TS1202 (`!node.isTypeOnly`).
            //
            // Reached without an `=` too, which is tsc's
            // `tokenAfterImportedIdentifierDefinitelyProducesImportDeclaration`:
            // after `import <name>`, ONLY `,` and `from` keep the ES form, so
            // every other token makes this an import-equals whose `=` is
            // missing. That is the whole of tsc's recovery for `import Foo From
            // "./x"` — "'=' expected" on `From`, `From` read as the module
            // reference, and "';' expected" on the string — where ztsc used to
            // guess "'from' expected" and then trip over the rest of the line.
            if (p.curTag() != .comma and p.curTag() != .keyword_from) {
                return p.finishImportEquals(export_kw orelse kw, default_name, flags | (if (export_kw != null) ast.Flags.exported else 0));
            }
            _ = try p.eat(.comma);
        }
        if (p.curTag() == .asterisk) {
            _ = try p.bump();
            // tsc's `parseNamespaceImport` expects `as` and then reads the next
            // token as the namespace NAME whether or not it found one, so
            // `import * from N from "m"` binds `from` and carries on.
            if (try p.eat(.keyword_as) == null) try p.fail(.expected_as);
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
            // tsc's `parseModuleSpecifier` runs whether or not `parseExpected`
            // found the `from`, and it accepts ANY expression ("we check to
            // ensure that it is only a string literal later in the grammar
            // check pass"). Consuming it is what keeps the rest of the line
            // from being read as a fresh statement: `import * from N from "m"`
            // takes `N` as the specifier and answers "';' expected" on the
            // SECOND `from`, where ztsc used to leave `N` behind and blame it.
            // The token is dropped rather than recorded — a non-literal
            // specifier names no module.
            if (canStartExpression(p.curTag()) and !p.nlBefore()) _ = try p.parseExpression(.{});
        }
        try p.skipImportAttributes();
        try p.expectSemicolon();
        if (export_kw) |m| try p.errAtToken(.import_cannot_have_modifiers, m);

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
    /// local binding, `anchor_kw` the declaration's FIRST token — the `export`
    /// when there is one, else the `import` — which is where the node's span
    /// begins. `flags` carries `Flags.exported` for the `export import` form.
    fn finishImportEquals(p: *Parser, anchor_kw: u32, name_tok: u32, flags: u32) PE!Node {
        // tsc's `parseImportEqualsDeclaration` opens with `parseExpected(=)`:
        // the caller decides this is an import-equals from the token AFTER the
        // name, so the `=` itself may well be missing.
        _ = try p.expect(.eq, .expected_eq);
        var module_token: u32 = 0;
        var entity: Node = 0;
        if (isIdentLike(p.curTag()) and std.mem.eql(u8, p.laText(0), "require") and p.peekTag(1) == .l_paren) {
            _ = try p.bump(); // require
            _ = try p.expect(.l_paren, .expected_l_paren);
            module_token = try p.expect(.string_literal, .expected_string_literal);
            _ = try p.expect(.r_paren, .expected_r_paren);
        } else if (isIdentLike(p.curTag())) {
            entity = try p.parseEntityName();
        } else {
            // tsc's `parseEntityName` makes a MISSING identifier here and
            // consumes nothing, leaving the token to whoever comes next — which
            // is what lets `import abstract class D {}` recover into
            // `import abstract = <missing>` plus a clean `class D {}`.
            // `parseEntityName`'s unconditional `leaf` would have eaten the
            // `class`. The node is left null rather than anchored at the last
            // consumed token: that token is `name_tok` itself, so the alias
            // would name ITSELF and the resolver would chase the cycle.
            try p.fail(.expected_identifier);
        }
        try p.expectSemicolon();
        const extra = try p.addExtra(ast.ImportEquals{
            .name_token = name_tok,
            .module_token = module_token,
            .entity = entity,
            .flags = flags,
        });
        return p.addNode(.{ .tag = .import_equals, .main_token = anchor_kw, .data = .{ .lhs = extra, .rhs = 0 } });
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

    /// `export export = x` / `export declare export = y`: an export ASSIGNMENT
    /// standing behind modifiers. Returns how many tokens sit between the
    /// caller's `export` and the assignment's own `export` keyword (that
    /// keyword included), plus the `ast.Flags` those modifiers carry — or null
    /// when this is any other `export` statement.
    ///
    /// Positioned after the leading `export` has been consumed. tsc collects
    /// `export`, `declare` and the member modifiers into ONE list before it
    /// decides what the declaration is, so the run has to be recognized before
    /// the ordinary repeat/modifier loops split it up: their answers (TS1030,
    /// TS1184) are for a different declaration than the one that is really
    /// here.
    fn exportAssignModifierRun(p: *Parser) ?struct { len: usize, flags: u32 } {
        var flags: u32 = 0;
        var n: u32 = 0;
        // `peekTag(n + 1)` bounds the walk; two modifiers is already more than
        // any real code writes.
        while (n + 1 < max_la) : (n += 1) {
            switch (p.peekTag(n)) {
                .keyword_export => if (p.peekTag(n + 1) == .eq)
                    return .{ .len = n + 1, .flags = flags },
                .keyword_declare => flags |= ast.Flags.declare,
                .keyword_public, .keyword_private, .keyword_protected, .keyword_static, .keyword_readonly, .keyword_abstract => {},
                else => return null,
            }
        }
        return null;
    }

    fn parseExportStatement(p: *Parser) PE!Node {
        const kw = try p.bump(); // `export`
        p.saw_module_syntax = true;
        // An export assignment behind modifiers is TS1120, blamed on the
        // statement. A `declare` among them also makes it AMBIENT, which is
        // what drops the TS1203 an `export =` otherwise earns — tsc's ESM check
        // is guarded on `!(node.flags & NodeFlags.Ambient)` — so the flag is
        // recorded in the node's otherwise-unused `rhs` for the linker to read.
        var assign_flags: u32 = 0;
        if (p.exportAssignModifierRun()) |run| {
            try p.errAtToken(.export_assign_with_modifiers, kw);
            assign_flags = run.flags;
            for (0..run.len) |_| _ = try p.bump();
        }
        // `export export class Foo {}` — tsc collects both into one modifier
        // list and reports TS1030 on the second, then declares the class as
        // usual. Refusing the second `export` here answered "an export clause
        // expected" and cost the file its whole semantic pass.
        while (p.curTag() == .keyword_export) {
            // `export export = x` is TS1120 (`An export assignment cannot have
            // modifiers.`) in tsc, reported on the statement — an earlier arm
            // than the repeat, and tsgo's whole answer for that shape. Same for
            // a statement list that is not a module body, where TS1233 has
            // already been reported. Neither is a repeat diagnostic, so the
            // repeat must stay quiet rather than add a second, wrong key.
            if (p.element_home != .other and p.peekTag(1) != .eq) try p.errAtCur(.mod_seen_export);
            _ = try p.bump();
        }
        // `export public import a = x.c;` — a member modifier between `export`
        // and the declaration, which tsc parses into the same modifier list.
        try p.eatStatementModifiers();
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
                    .keyword_class => try p.parseClassDecl(0, .declaration),
                    // `export default interface I { … }` — legal, and the only
                    // TYPE-side default export form.
                    // `export default interface I { … }` — the declaration
                    // behind the modifiers, already answered for by the
                    // `export` this statement started with.
                    .keyword_interface => try p.parseStatementUnchecked(),
                    .keyword_abstract => blk: {
                        if (p.peekTag(1) == .keyword_class) {
                            _ = try p.bump();
                            break :blk try p.parseClassDecl(ast.Flags.abstract, .declaration);
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
                return p.addNode(.{ .tag = .export_assign, .main_token = kw, .data = .{ .lhs = entity, .rhs = assign_flags } });
            },
            // `export import A = B.C;` is an exported namespace alias and legal;
            // `export import d from "m"` is an ES6 import declaration with a
            // modifier, which tsc PARSES and then answers TS1191 for. Both
            // spellings start the same way, so the one statement parser decides,
            // and the `export` token it is handed is what TS1191 is blamed on.
            .keyword_import => return p.parseImportStatement(kw),
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
                const decl = try p.parseStatementUnchecked();
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
                const decl = try p.parseStatementUnchecked();
                return p.addNode(.{ .tag = .export_decl, .main_token = kw, .data = .{ .lhs = decl, .rhs = 0 } });
            },
            .at => {
                // `export @dec class C { }` — tsc parses decorators and
                // modifiers as ONE list, in either order, so the decorators may
                // follow the `export`. Both orders are silent.
                //
                // The decorator nodes are parsed (so a malformed one still
                // reports) but not retained: a `.decorator` node is checked as a
                // sibling STATEMENT, and this one has no place in the statement
                // list — the `export` already claimed it. Deliberate
                // under-report of the decorator's own name resolution, the same
                // trade a decorated class EXPRESSION makes, and never a false
                // positive.
                while (p.curTag() == .at) _ = try p.parseDecorator();
                const decl = try p.parseStatementUnchecked();
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
        // TS1163, tsc's `checkYieldExpression`: a YieldExpression outside a
        // generator body. Two ways to be outside one, and the difference is
        // which of tsc's two `yield` readings applies:
        //
        //   * a static block is a function-like container that is not a
        //     generator and never can be, so every `yield` spelling there is an
        //     error;
        //   * anywhere else, tsc's `isYieldExpression` only reads `yield` as an
        //     operator when an identifier, keyword or literal follows it on the
        //     SAME LINE. Without one the word is an ordinary Identifier and its
        //     verdict belongs to the TS1212/TS1213 reserved-word family, which
        //     `checkStrictReserved` owns — so `var x = yield;` in a plain
        //     function must stay silent here.
        const outside = p.fn_ctx == .static_block or
            (!p.yield_ctx and !p.peekNewline(1) and yieldOperandFollows(p.peekTag(1)));
        const kw = try p.bump();
        if (outside and p.spec == 0) {
            try p.errAtToken(.yield_not_in_generator, kw);
        }
        var delegate: u32 = 0;
        var operand: Node = null_node;
        if (!p.nlBefore()) {
            const star = try p.eat(.asterisk);
            if (star != null) delegate = 1;
            // tsc's `parseYieldExpression` commits on the `*` alone:
            //
            //     if (!hasPrecedingLineBreak() && (token() === AsteriskToken || isStartOfExpression()))
            //         yield [*] parseAssignmentExpressionOrHigher()
            //
            // so once a `*` is consumed the operand is MANDATORY and its
            // absence is TS1109 at whatever follows — `yield *;` blames the
            // `;`, and a `yield*` alone on its line blames the `}` on the next
            // (`YieldStarExpression3_es6`, `YieldExpression5_es6`). A BARE
            // `yield` keeps the optional reading: `function* g() { yield; }`
            // is legal.
            if (star != null or (canStartExpression(p.curTag()) and !p.nlBefore())) {
                operand = try p.parseAssignExpr(ctx);
            }
        }
        return p.addNode(.{ .tag = .yield_expr, .main_token = kw, .data = .{ .lhs = operand, .rhs = delegate } });
    }

    /// tsc's `nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine`, the lookahead
    /// that decides whether a `yield` OUTSIDE a generator is an operator or an
    /// ordinary identifier. Deliberately narrower than "can start an
    /// expression": `yield (x)` is the call `yield(x)` to tsc, not a yield of
    /// `(x)`.
    fn yieldOperandFollows(t: TokTag) bool {
        return isIdentLike(t) or t == .numeric_literal or t == .bigint_literal or
            t == .string_literal;
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
        const body = try p.parseArrowBody(ctx, 0);
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
                const body = try p.parseArrowBody(ctx, flags);
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
        const body = try p.parseArrowBody(ctx, flags);
        return p.addNode(.{ .tag = .arrow_fn, .main_token = arrow_tok, .data = .{ .lhs = proto, .rhs = body } });
    }

    /// An arrow's body, with the function-like boundary it establishes. Every
    /// arrow form funnels through here — the one-parameter shorthand, the
    /// parenthesized form and the generic form — so `flags` is the only place
    /// that has to know whether the arrow is `async`.
    fn parseArrowBody(p: *Parser, ctx: ExprCtx, flags: u32) PE!Node {
        const saved_fn_ctx = p.fn_ctx;
        const saved_yield_ctx = p.yield_ctx;
        defer p.yield_ctx = saved_yield_ctx;
        defer p.fn_ctx = saved_fn_ctx;
        const saved_jump = p.jump;
        defer p.jump = saved_jump;
        p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
        p.fn_ctx = if (flags & ast.Flags.async != 0) .async_fn else .sync;
        // An arrow is never a generator, so it turns the yield context OFF.
        p.yield_ctx = false;
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
                // In an await context `await` is ALWAYS the operator — an
                // operand that is missing earns the TS1109 the operand parse
                // reports, which is what tsc answers for `await;` inside an
                // async function or a static block. Outside one, `await` is an
                // ordinary identifier unless an expression follows.
                //
                if (p.fn_ctx.awaits() or (canStartExpression(p.peekTag(1)) and p.peekTag(1) != .colon)) {
                    const op = try p.bump();
                    // TS18037: the operator is legal syntax inside a static
                    // block but never legal code there — a static initializer
                    // cannot await. Only the INNERMOST boundary counts: an
                    // `async function` written inside the block is ordinary
                    // async code.
                    if (p.fn_ctx == .static_block and p.spec == 0) {
                        try p.errAtToken(.await_in_static_block, op);
                    }
                    // A MISSING operand is reported here rather than left to the
                    // operand parse, because that parse turns the failure into
                    // `Backtrack` while speculating — abandoning the construct
                    // being tried instead of reporting inside it. `async (a =
                    // await) => {}` in an async body is exactly that shape: tsc
                    // parses the arrow and answers one TS1109 in its parameter
                    // list, where aborting the arrow re-reads the whole
                    // statement and invents a cascade. Reporting while
                    // speculating is safe — `restore` drops the diagnostic along
                    // with the rest of an abandoned parse.
                    if (!canStartExpression(p.curTag())) {
                        try p.errAtCur(.expected_expression);
                        return p.addNode(.{ .tag = .prefix_unary, .main_token = op, .data = .{ .lhs = try p.errorNode(), .rhs = 0 } });
                    }
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
                            const index = try p.parseElementAccessArgument();
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
                            const tmpl = try p.parseTemplateExpr(true);
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
                    const index = try p.parseElementAccessArgument();
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
                // `.unterminated_template` included: `f` followed by an
                // unterminated template is a TAGGED TEMPLATE to tsc, which
                // answers only the scanner's TS1160 for it. Left out, the tag
                // ended a statement of its own and the shape earned a second,
                // invented key (TS1434, then TS1005).
                .template_head, .no_substitution_template_literal, .unterminated_template => {
                    const tmpl = try p.parseTemplateExpr(true);
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
                // tsc's `parseDelimitedList` does not give up on the list
                // here. It re-asks `isListElement` at the top of the next
                // iteration, and only a token that starts NO argument reaches
                // `abortParsingListOrMoveToNextToken` — which force-advances
                // past it so the loop can go on to the element after. So
                // `f(name:string)` stays ONE argument list whose single
                // complaint is the "',' expected" just filed. (tsc's own
                // "argument expression expected" for the skipped token lands
                // on the position that complaint already used and is dropped
                // by the one-per-position rule, which `errAtCur` applies too
                // — so force-advancing adds no diagnostic.)
                //
                // Abandoning the list instead left `:string)` to be re-parsed
                // as statements: a spurious TS1434 at `string` and TS1128 at
                // `)`, in `staticsInAFunction` and
                // `overloadingStaticFunctionsInFunctions`.
                //
                // A token that DOES start an argument must not be skipped —
                // the loop below parses it as the next element, which is what
                // makes `foo(public blaz() {})` two "',' expected" and nothing
                // more. Swallowing the `blaz` there cost four extra keys in
                // `errorRecoveryInClassDeclaration`.
                if (!startsArgument(p.curTag()) and !canAbandonArgList(p.curTag()) and !p.nlBefore()) {
                    _ = try p.bump();
                    continue;
                }
                if (p.curIdx() == before) break;
            }
            if (p.curIdx() == before) break;
        }
        _ = try p.expect(.r_paren, .expected_r_paren);
        return p.scratchToSpan(top);
    }

    /// tsc's `isListElement(ParsingContext.ArgumentExpressions)`: `token() ===
    /// DotDotDotToken || isStartOfExpression()`. A token that answers yes is
    /// the next ARGUMENT and must be left for the loop to parse, never skipped
    /// as noise.
    fn startsArgument(tag: TokTag) bool {
        return tag == .dot_dot_dot or canStartExpression(tag);
    }

    /// Standing in for tsc's `isInSomeParsingContext`: is the token something
    /// an ENCLOSING construct is waiting for, so that an unterminated argument
    /// list must hand it back rather than skip it? A closing bracket or a
    /// statement separator belongs to whatever opened it; skipping one would
    /// let a single unclosed `(` eat the rest of the file.
    fn canAbandonArgList(tag: TokTag) bool {
        return switch (tag) {
            .r_brace, .r_bracket, .r_paren, .semicolon, .eof => true,
            else => false,
        };
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

    /// The opening tag whose children are being parsed — tsc's `openingTag`
    /// argument to `parseJsxChildren`/`parseJsxChild`, and the thing a closing
    /// tag is matched against.
    const JsxOpening = struct {
        /// The tag NAME's byte range, or null when there is none to compare or
        /// to quote: a fragment `<>`, or a name that failed to parse. Both stay
        /// silent — the fragment because the TS17014/TS17015 pair speaks for it
        /// instead, the unparsed name because the parse has already reported
        /// there and there is no text to put in a message.
        name: ?Span,
        /// Where "has no corresponding closing tag" is blamed: the NAME for an
        /// element (tsc: `parseErrorAt(skipTrivia(tag.pos), tag.end)`), the
        /// whole `<>` for a fragment (tsc passes the opening NODE).
        report: Span,
        fragment: bool,
    };

    /// The byte range of a tag name that may not have parsed at all: a failed
    /// `parseJsxTagName` consumes nothing, leaving `to` BEHIND `from`, and the
    /// arithmetic in `tokSpan` would then quote an arbitrary stretch of the
    /// file into the message.
    fn jsxNameSpan(p: *Parser, from: TokenIndex, to: TokenIndex) ?Span {
        if (to < from) return null;
        const s = p.tokSpan(from, to);
        return if (s.end > s.start) s else null;
    }

    /// tsc's `tagNamesAreEquivalent`, over source text rather than nodes: two
    /// tag names match when they spell the same thing. tsc compares the parsed
    /// entity-name structure, which also ignores the trivia a spaced
    /// `< A . B >` carries, so ASCII whitespace is dropped from both sides.
    ///
    /// A name holding a `\` is ESCAPED (`<abc>`), which tsc resolves before
    /// comparing and ztsc does not resolve at all. Comparing raw bytes there
    /// would call `abc` and `abc` different and invent a mismatch, so an
    /// escaped name is treated as equivalent to anything — tsc's own answer for
    /// one is TS17021 on the escape, never a tag mismatch.
    fn jsxTagNamesEquivalent(src: []const u8, a: Span, b: Span) bool {
        if (jsxNameIsEscaped(src, a) or jsxNameIsEscaped(src, b)) return true;
        var i = a.start;
        var j = b.start;
        while (true) {
            while (i < a.end and std.ascii.isWhitespace(src[i])) i += 1;
            while (j < b.end and std.ascii.isWhitespace(src[j])) j += 1;
            if (i == a.end or j == b.end) return i == a.end and j == b.end;
            if (src[i] != src[j]) return false;
            i += 1;
            j += 1;
        }
    }

    fn jsxNameIsEscaped(src: []const u8, s: Span) bool {
        return std.mem.indexOfScalar(u8, src[s.start..s.end], '\\') != null;
    }

    /// What `parseJsxElement` hands back to whoever parses its siblings.
    const JsxElementResult = struct {
        node: Node,
        /// Token index of the `<` of the closing tag this element consumed
        /// (0 when it consumed none).
        close_lt: TokenIndex,
        /// tsc's `lastChild` recovery signal: the closing tag consumed here
        /// named the ENCLOSING element rather than this one
        /// (`<div><span></div>`), so the enclosing element must take that tag
        /// as its own instead of going looking for a second one.
        closed_enclosing: bool,
    };

    /// `<tag ...>children</tag>`, `<tag .../>`, or `<>children</>`.
    /// Current token is `<`. `enclosing` is the opening tag of the element
    /// whose CHILD this is, or null in expression and attribute-value position
    /// (tsc's `openingTag` parameter); it is what tells a stray `</div>` apart
    /// from a genuinely mismatched one.
    fn parseJsxElement(p: *Parser, enclosing: ?JsxOpening) PE!JsxElementResult {
        const lt = try p.bump(); // '<'
        var tag: Node = null_node;
        var targs: ast.SubRange = .{ .start = 0, .end = 0 };
        const empty: Span = .{ .start = 0, .end = 0 };
        var opening: JsxOpening = .{ .name = null, .report = empty, .fragment = true };
        if (p.curTag() != .gt) {
            const name_from = p.curIdx();
            tag = try p.parseJsxTagName();
            const name = p.jsxNameSpan(name_from, p.lastIdx());
            opening = .{ .name = name, .report = name orelse empty, .fragment = false };
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
        var closed_enclosing = false;
        // tsc's `parseJsxOpeningOrSelfClosingElementOrOpeningFragment`: ONLY a
        // `>` opens a child list. Every other token is expected to be `/` and
        // the element comes out SELF-CLOSING — so a broken attribute list
        // (`<span a="x", b/>`) never swallows the rest of the file as children,
        // which is where a whole family of invented "has no corresponding
        // closing tag" reports came from. The "'/' expected" and the "'>'
        // expected" behind it land on the same token, where tsc's
        // one-per-position rule keeps the first.
        if (p.curTag() == .slash or !isGtFamily(p.curTag())) {
            _ = try p.expect(.slash, .expected_slash);
            _ = try p.expectJsxGt();
        } else {
            const after_gt = try p.expectJsxGt();
            // A fragment's `<>` is complete only now, and it is the range tsc
            // blames for an unclosed one (there is no name to blame).
            if (opening.fragment) opening.report = p.tokSpan(lt, p.lastIdx());
            const kids = try p.parseJsxChildren(after_gt, opening);
            children = kids.range;
            close_lt = kids.close_lt;
            if (kids.end == .closing_tag) {
                const closing = try p.parseJsxClosingElement();
                close_lt = closing.lt;
                closed_enclosing = try p.checkJsxClosingTag(opening, closing.name, enclosing);
            }
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
        return .{
            .node = try p.addNode(.{ .tag = .jsx_element, .main_token = lt, .data = .{ .lhs = data, .rhs = 0 } }),
            .close_lt = close_lt,
            .closed_enclosing = closed_enclosing,
        };
    }

    /// The `<` token and NAME range of a `</tag>`. `name` is null when there
    /// was no name to read — the fragment spelling `</>`, or no closing tag at
    /// all — which is the case that reports nothing (see `checkJsxClosingTag`).
    const JsxClosing = struct { lt: TokenIndex, name: ?Span };

    /// `</tag>`, `</>`, or nothing at all — at end of file tsc's
    /// `parseExpected(LessThanSlashToken)` consumes nothing and reports "'</'
    /// expected" on the token that IS there, which is what the fall-through
    /// arm does.
    fn parseJsxClosingElement(p: *Parser) PE!JsxClosing {
        if (p.curTag() != .lt or p.peekTag(1) != .slash) {
            try p.fail(.expected_lt_slash);
            return .{ .lt = 0, .name = null };
        }
        const lt = try p.bump(); // '<'
        _ = try p.bump(); // '/'
        var name: ?Span = null;
        // No name means `</>`, the fragment closer. tsc reaches it through
        // `parseJsxClosingFragment`, which never parses a name, so the
        // "Identifier expected" a named element's closer would give here is
        // not tsc's answer either.
        if (!isGtFamily(p.curTag())) {
            const from = p.curIdx();
            _ = try p.parseJsxTagName();
            name = p.tokSpan(from, p.lastIdx());
        }
        _ = try p.expectJsxGt();
        return .{ .lt = lt, .name = name };
    }

    /// tsc's closing-tag check, the three-way arm at the bottom of
    /// `parseJsxElementOrSelfClosingElementOrFragment`. Returns whether the
    /// closing tag turned out to belong to the ENCLOSING element.
    fn checkJsxClosingTag(p: *Parser, opening: JsxOpening, closing_name: ?Span, enclosing: ?JsxOpening) Error!bool {
        if (opening.fragment) {
            // `<>…</div>`: tsc's `parseJsxClosingFragment` blames the name it
            // found where `</>` was due. A `</>` (no name) is the match, so
            // nothing is reported for it.
            if (closing_name) |n| {
                if (p.spec == 0) try p.errAtBytes(.jsx_expected_fragment_closing, n.start, n.end);
            }
            return false;
        }
        // An element whose own name never parsed has nothing to compare or to
        // quote. A named element closed by `</>`, or by nothing at all: tsc's
        // `parseJsxElementName` leaves a MISSING identifier there and has
        // already reported at that position ("Identifier expected" / "'</'
        // expected"), so its one-per-position rule drops the mismatch message.
        // Reporting nothing is the same observable answer for both.
        const open_name = opening.name orelse return false;
        const closing = closing_name orelse return false;
        if (jsxTagNamesEquivalent(p.src, open_name, closing)) return false;
        // `<div><span></div>`: the `</div>` closes the element OUTSIDE this
        // one, so THIS element is the unclosed one and the enclosing element
        // adopts the tag. tsc's `openingTag` test, and the reason the enclosing
        // opening tag is threaded down here at all.
        const belongs_to_enclosing = if (enclosing) |e|
            if (e.name) |en| jsxTagNamesEquivalent(p.src, closing, en) else false
        else
            false;
        if (p.spec != 0) return belongs_to_enclosing;
        if (belongs_to_enclosing) {
            try p.errAtSpanArg(.jsx_element_unclosed, opening.report, open_name);
        } else {
            // Reported on the CLOSING tag but naming the OPENING one — the one
            // diagnostic whose message argument is not its own span.
            try p.errAtSpanArg(.jsx_expected_closing_tag, closing, open_name);
        }
        return belongs_to_enclosing;
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
        // tsc's `parseJsxTagName` returns a JsxNamespacedName immediately, so a
        // namespaced tag never carries a `.B.C` chain.
        if (try p.eatJsxNamespaceTail()) return node;
        while (p.curTag() == .dot) {
            const dot = try p.bump();
            const name = try p.expectMemberName();
            node = try p.addNode(.{ .tag = .member_expr, .main_token = dot, .data = .{ .lhs = node, .rhs = name } });
        }
        return node;
    }

    /// The `: name` tail of a JsxNamespacedName (`<svg:path>`, `a:b={1}`), in
    /// either a tag-name or an attribute-name position. Returns true when one
    /// was there.
    ///
    /// The ABUTTING spelling is already a single `.jsx_name` token —
    /// `rescanJsxName` merges over the `:` — so this only ever fires for the
    /// SPACED spelling `<svg : path>`, which tsc accepts because its
    /// `parseJsxTagName` reads an ordinary `:` token with trivia allowed on both
    /// sides. There the namespace part alone stands as the node: a token is a
    /// byte range and no single token spans `svg : path`. So a spaced namespaced
    /// name loses its qualifier for the `JSX.IntrinsicElements` lookup — an
    /// under-report on a spelling no real code writes (both corpus cases name a
    /// lowercase namespace, so the intrinsic classification is still right).
    fn eatJsxNamespaceTail(p: *Parser) PE!bool {
        if (p.curTag() != .colon) return false;
        _ = try p.bump(); // ':'
        _ = try p.expectJsxName();
        return true;
    }

    fn parseJsxAttributes(p: *Parser) PE!ast.SubRange {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        while (!isGtFamily(p.curTag()) and p.curTag() != .slash and p.curTag() != .eof) {
            const before = p.curIdx();
            if (p.curTag() == .l_brace) {
                const lb = try p.bump(); // '{'
                _ = try p.eat(.dot_dot_dot); // '...'
                const expr = try p.parseAssignExpr(.{});
                _ = try p.expect(.r_brace, .expected_r_brace);
                try p.pushScratch(try p.addNode(.{ .tag = .jsx_spread_attribute, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } }));
            } else {
                const name = try p.expectJsxName();
                _ = try p.eatJsxNamespaceTail();
                var value: Node = null_node;
                if (try p.eat(.eq) != null) value = try p.parseJsxAttributeValue();
                try p.pushScratch(try p.addNode(.{ .tag = .jsx_attribute, .main_token = name, .data = .{ .lhs = value, .rhs = 0 } }));
            }
            if (p.curIdx() == before) break; // no progress: bail to avoid a loop
        }
        return p.scratchToSpan(top);
    }

    /// The expression inside a `{ … }` JSX container, attribute value or child
    /// alike. The JSX grammar allows only an AssignmentExpression there, but
    /// tsc's `parseJsxExpression` reads a full comma SEQUENCE anyway ("we can
    /// unambiguously parse a comma sequence and provide a better error message
    /// in grammar checking") and its `checkGrammarJsxExpression` answers TS18007
    /// for one. Stopping at the comma instead cost a false "'}' expected" plus
    /// the file's whole semantic pass.
    fn parseJsxContainerExpr(p: *Parser) PE!Node {
        const start_tok = p.curIdx();
        const expr = try p.parseExpression(.{});
        if (p.nodes.items(.tag)[expr] == .seq_expr) {
            try p.errAtRange(.jsx_comma_operator, start_tok, p.lastIdx());
        }
        return expr;
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
                if (p.curTag() != .r_brace) expr = try p.parseJsxContainerExpr();
                _ = try p.expect(.r_brace, .expected_r_brace);
                return p.addNode(.{ .tag = .jsx_expr_container, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } });
            },
            // An attribute value is not a child, so no enclosing tag can claim
            // its closing tag (tsc's `inExpressionContext: true` call, which
            // passes no `openingTag`).
            .lt => return (try p.parseJsxElement(null)).node,
            else => {
                try p.fail(.expected_expression);
                return p.errorNode();
            },
        }
    }

    /// A bare `}` or `>` in JSX child text is TS1381 / TS1382 — the two
    /// characters that would have ended a container or a tag, and that JSX makes
    /// the author write as `{'}'}` / `&rbrace;` or `{'>'}` / `&gt;`. tsc reports
    /// them from `scanJsxToken`, one per byte, as it walks the text; the text is
    /// still a child either way. Byte-wise is correct: both are ASCII, so they
    /// can never be a continuation byte of a UTF-8 sequence.
    fn reportJsxTextPunctuation(p: *Parser, start: u32, end: u32) Error!void {
        if (p.spec != 0) return;
        for (p.src[start..end], start..) |c, i| {
            const code: Code = switch (c) {
                '}' => .jsx_text_rbrace,
                '>' => .jsx_text_gt,
                else => continue,
            };
            try p.errAtBytes(code, @intCast(i), @intCast(i + 1));
        }
    }

    /// How a child list ended — which is what decides what the element does
    /// about its closing tag.
    const JsxChildrenEnd = enum {
        /// A `</` is next (or the file ran out before one): the element parses
        /// it as its own closing tag.
        closing_tag,
        /// tsc's `lastChild` recovery: the last child already consumed a
        /// closing tag that named THIS opening, so `close_lt` is set and there
        /// is no second closing tag to look for.
        adopted,
        /// A conflict marker ended the children and reported its own message;
        /// nothing further is expected of the element.
        reported,
    };

    /// The children of one non-self-closing element, the `<` token of a closing
    /// tag already adopted from a child (0 otherwise), and how the list ended.
    const JsxChildren = struct {
        range: ast.SubRange,
        close_lt: TokenIndex,
        end: JsxChildrenEnd,
    };

    /// Children of a non-self-closing element, up to but NOT including its
    /// `</tag>` — tsc's `parseJsxChildren`, which likewise stops at `</` and
    /// leaves the closing element to its caller. `start` is the byte offset
    /// just past the opening tag's `>`; `opening` is that tag, which the end of
    /// the file is blamed on.
    fn parseJsxChildren(p: *Parser, start: u32, opening: JsxOpening) PE!JsxChildren {
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        var close_lt: TokenIndex = 0;
        var end: JsxChildrenEnd = .closing_tag;
        var pos = start;
        while (true) {
            const tok = p.scn.scanJsxChild(pos);
            switch (tok.tag) {
                .jsx_text => {
                    const idx = p.curIdx();
                    try p.appendTok(.{ .tag = .jsx_text, .start = tok.start, .end = tok.end, .newline_before = false });
                    try p.pushScratch(try p.addNode(.{ .tag = .jsx_text, .main_token = idx, .data = .{ .lhs = 0, .rhs = 0 } }));
                    try p.reportJsxTextPunctuation(tok.start, tok.end);
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
                    if (p.curTag() != .r_brace) expr = try p.parseJsxContainerExpr();
                    _ = try p.expect(.r_brace, .expected_r_brace);
                    try p.pushScratch(try p.addNode(.{ .tag = .jsx_expr_container, .main_token = lb, .data = .{ .lhs = expr, .rhs = 0 } }));
                    pos = p.lastTokEnd();
                },
                .conflict_marker => {
                    // tsc's `parseJsxChild` ENDS the child list on a marker, and
                    // the "'</' expected" that follows lands on the marker
                    // token's start — the end of the opening tag's line, because
                    // `scanJsxToken` fixed `tokenStart` before it went looking
                    // (`conflictMarkerTrivia3.tsx`).
                    p.noteConflictMarker(tok);
                    p.jsxResync(tok.end);
                    try p.errAtBytes(.expected_lt_slash, tok.start, tok.end);
                    end = .reported;
                    break;
                },
                .lt => {
                    p.jsxResync(tok.start);
                    // `</` is the element's own closing tag; leave it for
                    // `parseJsxClosingElement`, which checks its name.
                    if (p.peekTag(1) == .slash) break;
                    const child = try p.parseJsxElement(opening);
                    try p.pushScratch(child.node);
                    if (child.closed_enclosing) {
                        close_lt = child.close_lt;
                        end = .adopted;
                        break;
                    }
                    pos = p.lastTokEnd();
                },
                else => { // eof, or a token no JSX child can start
                    // tsc's `parseJsxChild` blames the OPENING tag rather than
                    // the end of the file ("which is useless"), then lets the
                    // caller's `parseJsxClosingElement` add its "'</' expected".
                    p.jsxResync(tok.start);
                    if (p.spec == 0) {
                        if (opening.fragment) {
                            try p.errAtBytes(.jsx_fragment_unclosed, opening.report.start, opening.report.end);
                        } else if (opening.name) |n| {
                            try p.errAtSpanArg(.jsx_element_unclosed, opening.report, n);
                        }
                    }
                    break;
                },
            }
        }
        return .{ .range = try p.scratchToSpan(top), .close_lt = close_lt, .end = end };
    }

    /// A JSX element in EXPRESSION position, with tsc's adjacent-element
    /// recovery: `<a/><b/>` is not a `<` comparison but a forgotten wrapper, so
    /// `parseJsxElementOrSelfClosingElementOrFragment` speculatively parses the
    /// second element whenever a `<` follows the first, joins the two with a
    /// synthetic comma and reports TS2657 over the whole run.
    ///
    /// tsc's speculation is `tryParse`, which keeps the nested parse's
    /// diagnostics because the nested call always returns a node — so it never
    /// actually rolls back, and parsing straight through is the same thing.
    /// tsc recurses (threading the run's start through `topInvalidNodePosition`)
    /// and so records one TS2657 per pair, all at that same start; the
    /// one-per-position rule keeps the innermost, which spans the whole run.
    /// The loop below reports that surviving diagnostic directly, which is also
    /// what keeps a long run from recursing once per element.
    ///
    /// Only expression position: an element in a CHILD or ATTRIBUTE-VALUE
    /// position is `inExpressionContext: false`, where a following `<` is the
    /// next child or the closing tag.
    fn parseJsxElementInExpr(p: *Parser) PE!Node {
        const run_start = p.curIdx();
        // A FRAGMENT is excluded, and it is the one exclusion this rule needs.
        // tsc's guard is the bare `token() === LessThanToken`, but its fragment
        // recovery gets there first: `tsxFragmentErrors.tsx` writes `<>hi</div>`
        // and then `<>eof` on a later line, and tsgo answers TS17015/TS17014 for
        // the unmatched fragment and NO TS2657 — the `</div>` is not accepted as
        // the fragment's closing tag, so everything after it, the second
        // fragment included, is read as a CHILD and no `<` is ever left standing
        // where this recovery could see it. ztsc does not model that closing-tag
        // check, so a fragment's trailing `<` cannot be told from an adjacent
        // element's and the recovery declines to guess. `<div></div>` runs, which
        // is every corpus case that wants a TS2657, are unaffected.
        const opens_fragment = p.peekTag(1) == .gt;
        var node = (try p.parseJsxElement(null)).node;
        if (p.curTag() != .lt or opens_fragment) return node;
        while (p.curTag() == .lt) {
            const lt = p.curIdx();
            const next = (try p.parseJsxElement(null)).node;
            node = try p.addNode(.{ .tag = .seq_expr, .main_token = lt, .data = .{ .lhs = node, .rhs = next } });
        }
        try p.errAtRange(.jsx_needs_one_parent, run_start, p.lastIdx());
        return node;
    }

    fn parsePrimaryExpr(p: *Parser, ctx: ExprCtx) PE!Node {
        if (p.jsx and p.curTag() == .lt) return p.parseJsxElementInExpr();
        switch (p.curTag()) {
            .numeric_literal => return p.leaf(.number_literal),
            .bigint_literal => return p.leaf(.bigint_literal),
            .string_literal => return p.leaf(.string_literal),
            .unterminated_string_literal => {
                try p.errAtCurEnd(.unterminated_string);
                return p.leaf(.string_literal);
            },
            .regexp_literal => {
                try p.checkRegex();
                return p.leaf(.regex_literal);
            },
            .unterminated_regexp_literal => {
                try p.errAtCur(.unterminated_regexp);
                return p.leaf(.regex_literal);
            },
            .slash, .slash_eq => {
                p.rescanRegex();
                if (p.curTag() == .unterminated_regexp_literal) {
                    try p.errAtCur(.unterminated_regexp);
                } else {
                    try p.checkRegex();
                }
                return p.leaf(.regex_literal);
            },
            .no_substitution_template_literal, .template_head, .unterminated_template => return p.parseTemplateExpr(false),
            .keyword_true => return p.leaf(.true_literal),
            .keyword_false => return p.leaf(.false_literal),
            .keyword_null => return p.leaf(.null_literal),
            .keyword_this => return p.leaf(.this_expr),
            .keyword_super => {
                const node = try p.leaf(.super_expr);
                // tsc's `parseSuperExpression`: after `super` the grammar wants
                // `(`, `.` or `[`; anything else is TS1034, reported on the
                // token that should have been the dot (tsc reaches it through
                // `parseExpectedToken(DotToken, …)`, which blames the CURRENT
                // token). tsc then synthesizes `super.<missing>`; the node is
                // left as the bare `super` here because TS1034 is a parse
                // diagnostic and so the program's semantic pass never runs.
                switch (p.curTag()) {
                    .l_paren, .dot, .l_bracket => {},
                    // `super<T>()` — tsc looks for a type-argument list BEFORE
                    // this check (its own answer there is TS2754, `'super' may
                    // not use type arguments`, which ztsc does not report yet),
                    // and only a `<` that fails to parse as one reaches TS1034.
                    // Staying silent keeps the under-report instead of turning
                    // it into a wrong key.
                    .lt, .lt_lt => {},
                    else => try p.errAtCur(.super_needs_call_or_member),
                }
                return node;
            },
            .keyword_import => return p.leaf(.import_expr),
            .keyword_function => return p.parseFunctionDecl(0, true),
            .keyword_async => {
                if (p.peekTag(1) == .keyword_function and !p.peekNewline(1)) {
                    _ = try p.bump();
                    return p.parseFunctionDecl(ast.Flags.async, true);
                }
                return p.leaf(.identifier);
            },
            .keyword_class => return p.parseClassDecl(0, .expression),
            .at => {
                // A decorated class EXPRESSION: `({ x: @dec class {} })`,
                // `f(@dec class {})`. TC39 standard decorators put the
                // decorator list in the ClassExpression production
                // (`ClassExpression : DecoratorList? class BindingIdentifier?
                // ClassTail`), which is why an `@` can start an expression at
                // all. A decorator anywhere ELSE in expression position is
                // TS1206, exactly as at statement level.
                //
                // The decorator nodes are parsed (so a malformed one still
                // reports) but not attached to the class: a class EXPRESSION has
                // nowhere to hang them. Deliberate under-report — the
                // decorator's own signature check is skipped for this form,
                // never a false positive.
                const at = p.curIdx();
                while (p.curTag() == .at) _ = try p.parseDecorator();
                if (p.curTag() == .keyword_class) {
                    // Legacy decorators decorate a class DECLARATION only, so
                    // `var v = @dec class C {}` is TS1206 where the same source
                    // under TC39 decorators is silent.
                    if (p.spec == 0) {
                        if (decorator_target.diagnose(p.experimental_decorators, .{ .kind = .class_expr })) |code| {
                            try p.errAtToken(code, at);
                        }
                    }
                    return p.parseClassDecl(0, .expression);
                }
                try p.errAtToken(.decorator_not_valid_here, p.lastIdx());
                return p.parseAssignExpr(ctx);
            },
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
    /// `tagged` is true for the `` tag`…` `` form, whose parts admit every
    /// otherwise-invalid escape — see `checkTemplateEscapes`.
    fn parseTemplateExpr(p: *Parser, tagged: bool) PE!Node {
        // An UNTERMINATED no-substitution template is still a template literal
        // to tsc's parser — its scanner returns the token with `isUnterminated`
        // set and has already reported TS1160 — so it forms the same leaf, and
        // a tag in front of it still forms a tagged template. Escapes are not
        // checked: the literal has no end, so its tail is not a fragment tsc
        // ever validates.
        if (p.curTag() == .unterminated_template) {
            try p.errAtCurEnd(.unterminated_template);
            return p.leaf(.template_literal);
        }
        if (p.curTag() == .no_substitution_template_literal) {
            const tok = try p.bump();
            if (!tagged) try p.checkTemplateEscapes(tok);
            return p.addNode(.{ .tag = .template_literal, .main_token = tok, .data = .{ .lhs = 0, .rhs = 0 } });
        }
        const head = try p.bump(); // template_head
        if (!tagged) try p.checkTemplateEscapes(head);
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
                    const part = try p.bump();
                    if (!tagged) try p.checkTemplateEscapes(part);
                    continue;
                },
                .template_tail => {
                    const part = try p.bump();
                    if (!tagged) try p.checkTemplateEscapes(part);
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
            // A stray `;` — `var tt = { aa; }`, `var v = { foo(); }`. tsc passes
            // `considerSemicolonAsDelimiter: true` for an object literal alone
            // among its delimited lists, and CONSUMES the `;` rather than giving
            // up on the list ("this can happen when people do things like use a
            // semicolon to delimit object literal members"). Breaking out here
            // instead left the `}` to be re-read as a statement, which answered a
            // second, false TS1128. The TS1136 is usually suppressed by the
            // one-per-position rule, the missing comma having already been
            // reported at this very token.
            //
            // tsc's condition includes `!scanner.hasPrecedingLineBreak()`, and it
            // is load-bearing: `var v = {\n  a\n;` (no closing brace) answers ONE
            // key in tsgo, because the `;` on its own line is NOT consumed and the
            // "'}' expected" that follows lands on it and is suppressed as a
            // repeat position. Consuming it moved that diagnostic to EOF, where
            // nothing suppressed it.
            if (p.curTag() == .semicolon and !p.nlBefore()) {
                if (p.spec > 0) return error.Backtrack;
                try p.errAtCur(.expected_property_name);
                _ = try p.bump();
                continue;
            }
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
            .bigint_literal => {
                // `{ 1n: 123 }` — TS1539. The grammar accepts a BigInt literal
                // as a PropertyName, so it parses and the member is real; a
                // parse error here cost the file its whole semantic pass.
                try p.errAtCur(.bigint_property_name);
                key_tok = p.curIdx();
                key = try p.leaf(.bigint_literal);
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
                    // `{ #x: 1 }` / `{ #m() {} }` / `{ get #p() {} }` — an
                    // object literal is never a class body, so a private name
                    // here is always TS18016 (tsc's parser reads it as the
                    // PropertyName and its grammar pass reports).
                    if (p.curTag() == .private_identifier) try p.errAtCur(.private_name_outside_class);
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
                const saved_fn_ctx = p.fn_ctx;
                const saved_yield_ctx = p.yield_ctx;
                defer p.yield_ctx = saved_yield_ctx;
                defer p.fn_ctx = saved_fn_ctx;
                const saved_jump = p.jump;
                defer p.jump = saved_jump;
                p.jump = .{ .labels_base = p.labels.items.len, .in_function = true };
                p.fn_ctx = if (flags & ast.Flags.async != 0) .async_fn else .sync;
                p.yield_ctx = flags & ast.Flags.generator != 0;
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

    /// Who owns a trailing `?` at the very top of a type.
    ///
    /// In a plain TUPLE element it is the optional-element marker and the tuple
    /// owns it (`[string?]`); everywhere else it is tsc's JSDoc postfix-nullable
    /// marker and `parsePostfixType` reports TS17019 on it (`let x: string?`).
    /// The distinction is threaded only down the spine of positions where the
    /// child can still BE the element's top node — which is exactly the reach of
    /// the `type.pos === type.type.pos` test tsc's `parseTupleElementType` uses
    /// to convert the nullable node back into an optional one. So a nested
    /// marker (`[Array<string?>]`, `[A | B?]`, `[keyof string?]`) still reads as
    /// nullable, as it does in tsc.
    const TrailingQuestion = enum { nullable_marker, tuple_optional };

    fn parseType(p: *Parser) PE!Node {
        return p.parseTypeIn(.nullable_marker);
    }

    fn parseTypeIn(p: *Parser, tq: TrailingQuestion) PE!Node {
        const ty = try p.parseNonConditionalType(tq);
        // Conditional type `C extends E ? T : F`. The `extends` clause
        // is a non-conditional type (a nested conditional there needs
        // parentheses, matching tsc); the two branches are full types. The
        // `spec == 0` guard keeps `extends` unclaimed while speculatively
        // parsing a function type, exactly as before.
        if (p.curTag() == .keyword_extends and !p.nlBefore() and p.spec == 0) {
            const ext_kw = try p.bump();
            const extends_ty = blk: {
                // tsc's `disallowConditionalTypesAnd(parseTypeWorker)`: the
                // clause admits no bare conditional, and an `infer T extends C`
                // inside it therefore KEEPS its constraint — the `?` that
                // follows can only belong to this conditional.
                const saved_ncd = p.no_cond_type;
                defer p.no_cond_type = saved_ncd;
                p.no_cond_type = true;
                break :blk try p.parseNonConditionalType(.nullable_marker);
            };
            _ = try p.expect(.question, .expected_colon);
            // Both branches are full types again (`allowConditionalTypesAnd`).
            const saved_ncd = p.no_cond_type;
            defer p.no_cond_type = saved_ncd;
            p.no_cond_type = false;
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
    fn parseNonConditionalType(p: *Parser, tq: TrailingQuestion) PE!Node {
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
        return p.parseUnionType(tq);
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

    /// A function or constructor type written BARE as a union or intersection
    /// constituent — `type U = string | () => void`. The grammar wants
    /// parentheses, but tsc's `parseFunctionOrConstructorTypeToError` parses the
    /// shorthand anyway ("we'll try to parse them gracefully and issue a helpful
    /// message") and answers one TS1385/TS1386/TS1387/TS1388. Refusing it
    /// instead produced a TS1110/TS1005/TS1109/TS1128 cascade — 134 excess keys
    /// across the corpus's two cases for this rule.
    ///
    /// Only a constituent that FOLLOWS an operator can be one, which is why
    /// `type F = () => void` is legal and `type U = A | () => void` is not; the
    /// caller passes `from`, the offset just past that operator, because tsgo
    /// blames the constituent from its FULL start (leading trivia included, so
    /// the space after the `|` is where the squiggle begins — measured on all 16
    /// keys of `unparenthesizedFunctionTypeInUnionOrIntersection.ts`).
    ///
    /// Returns null when this constituent is not one of the two shapes, leaving
    /// the caller to parse it normally. The `(`-led shape is decided by trying
    /// the function type, which is what tsc's `isUnambiguouslyStartOfFunctionType`
    /// lookahead decides: `A | (B)` is a parenthesized type, `A | (b: B) => C`
    /// is a function type.
    fn parseBareFnTypeConstituent(p: *Parser, from: u32, is_union: bool) PE!?Node {
        const node, const is_ctor = switch (p.curTag()) {
            .lt, .lt_lt => .{ try p.parseFunctionType(), false },
            .l_paren => blk: {
                const ft = try p.tryParseFunctionType() orelse return null;
                break :blk .{ ft, false };
            },
            .keyword_new => .{ try p.parseConstructorType(false), true },
            .keyword_abstract => blk: {
                if (p.peekTag(1) != .keyword_new) return null;
                break :blk .{ try p.parseConstructorType(true), true };
            },
            else => return null,
        };
        const code: Code = if (is_ctor)
            (if (is_union) .ctor_type_in_union else .ctor_type_in_intersection)
        else
            (if (is_union) .fn_type_in_union else .fn_type_in_intersection);
        try p.errAtBytes(code, from, p.lastTokEnd());
        return node;
    }

    fn parseUnionType(p: *Parser, tq: TrailingQuestion) PE!Node {
        var first_pipe: u32 = 0;
        var leading_bare: ?Node = null;
        if (p.curTag() == .pipe) {
            first_pipe = try p.bump(); // leading `|`
            leading_bare = try p.parseBareFnTypeConstituent(p.lastTokEnd(), true);
        }
        const first = leading_bare orelse try p.parseIntersectionType(tq);
        if (p.curTag() != .pipe and first_pipe == 0) return first;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.pushScratch(first);
        var main_tok = first_pipe;
        while (p.curTag() == .pipe) {
            const tok = try p.bump();
            if (main_tok == 0) main_tok = tok;
            const from = p.lastTokEnd();
            const bare = try p.parseBareFnTypeConstituent(from, true);
            try p.pushScratch(bare orelse try p.parseIntersectionType(.nullable_marker));
        }
        if (main_tok == 0) main_tok = p.nodes.items(.main_token)[first];
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .union_type, .main_token = main_tok, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseIntersectionType(p: *Parser, tq: TrailingQuestion) PE!Node {
        var first_amp: u32 = 0;
        var leading_bare: ?Node = null;
        if (p.curTag() == .amp) {
            first_amp = try p.bump();
            leading_bare = try p.parseBareFnTypeConstituent(p.lastTokEnd(), false);
        }
        const first = leading_bare orelse try p.parseTypeOperator(tq);
        if (p.curTag() != .amp and first_amp == 0) return first;
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.pushScratch(first);
        var main_tok = first_amp;
        while (p.curTag() == .amp) {
            const tok = try p.bump();
            if (main_tok == 0) main_tok = tok;
            const from = p.lastTokEnd();
            const bare = try p.parseBareFnTypeConstituent(from, false);
            try p.pushScratch(bare orelse try p.parseTypeOperator(.nullable_marker));
        }
        if (main_tok == 0) main_tok = p.nodes.items(.main_token)[first];
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .intersection_type, .main_token = main_tok, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    fn parseTypeOperator(p: *Parser, tq: TrailingQuestion) PE!Node {
        switch (p.curTag()) {
            .keyword_keyof => {
                const kw = try p.bump();
                const operand = try p.parseTypeOperator(.nullable_marker);
                return p.addNode(.{ .tag = .keyof_type, .main_token = kw, .data = .{ .lhs = operand, .rhs = 0 } });
            },
            .keyword_readonly => {
                const kw = try p.bump();
                const operand = try p.parseTypeOperator(.nullable_marker);
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
                _ = try p.parseTypeOperator(.nullable_marker);
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
                    // tsc's `tryParseConstraintOfInferType`: parse the
                    // constraint with conditional types disallowed, then keep it
                    // only if a conditional type could not have claimed this
                    // `extends` instead. Where conditionals ARE allowed and a
                    // `?` follows, the whole constraint is given back and the
                    // `extends` belongs to the conditional type around the
                    // `infer` — `{ [P in infer U extends keyof T ? 1 : 0]: 1 }`
                    // is a mapped type over a conditional, not an `infer` with a
                    // constraint. Inside a conditional's own `extends` clause
                    // (`no_cond_type`) there is no such reading, so the
                    // constraint stands: `T extends infer U extends number ? 1 :
                    // 0` binds `U` with a constraint.
                    const state = p.save();
                    const saved_ncd = p.no_cond_type;
                    _ = try p.bump();
                    p.no_cond_type = true;
                    const c = try p.parseNonConditionalType(.nullable_marker);
                    p.no_cond_type = saved_ncd;
                    if (saved_ncd or p.curTag() != .question) {
                        constraint = c;
                    } else {
                        p.restore(state);
                    }
                }
                return p.addNode(.{ .tag = .infer_type, .main_token = kw, .data = .{ .lhs = name, .rhs = constraint } });
            },
            // tsc's `allowConditionalTypesAnd(parsePostfixTypeOrHigher)`: below
            // the type operators the context starts over, so a parenthesized,
            // braced or bracketed type nested in a conditional's `extends`
            // clause admits a conditional type of its own.
            else => {
                const saved_ncd = p.no_cond_type;
                defer p.no_cond_type = saved_ncd;
                p.no_cond_type = false;
                return p.parsePostfixType(tq);
            },
        }
    }

    /// tsc's `parsePostfixTypeOrHigher`: `T[]`, `T[K]`, and JSDoc's postfix
    /// nullability markers `T?` / `T!`, which tsc's parser accepts in a `.ts`
    /// file and its CHECKER reports (TS17019) — so the file's semantic pass
    /// still runs. See `orNull` for the desugaring and `TrailingQuestion` for
    /// the one position where a `?` is not this marker.
    fn parsePostfixType(p: *Parser, tq: TrailingQuestion) PE!Node {
        const start_tok = p.curIdx();
        var ty = try p.parsePrimaryType();
        while (!p.nlBefore()) {
            switch (p.curTag()) {
                .l_bracket => {
                    const lb = try p.bump();
                    if (try p.eat(.r_bracket) != null) {
                        ty = try p.addNode(.{ .tag = .array_type, .main_token = lb, .data = .{ .lhs = ty, .rhs = 0 } });
                    } else {
                        const index = try p.parseType();
                        _ = try p.expect(.r_bracket, .expected_r_bracket);
                        ty = try p.addNode(.{ .tag = .indexed_access_type, .main_token = lb, .data = .{ .lhs = ty, .rhs = index } });
                    }
                },
                .bang => {
                    const mark = try p.bump();
                    try p.errAtRange(.non_nullable_type_postfix, start_tok, mark);
                },
                .question => {
                    // `T ? X : Y` — a conditional type's `?`, not a marker.
                    // tsc's `lookAhead(nextTokenIsStartOfType)`, and the only
                    // reason `string?[]` answers TS1005 rather than TS17019.
                    if (tq == .tuple_optional or p.startsTypeAt(1)) return ty;
                    const mark = try p.bump();
                    try p.errAtRange(.nullable_type_postfix, start_tok, mark);
                    ty = try p.orNull(ty, mark);
                },
                else => return ty,
            }
        }
        return ty;
    }

    /// `T | null`, the desugaring of a `?T` / `T?` marker: measured, not
    /// assumed — `let a: ?string; let b: string = a;` answers "Type 'string |
    /// null' is not assignable to type 'string'" (tsc's
    /// `getTypeFromJSDocNullableTypeNode` adds `null` under strictNullChecks).
    /// Synthesizing the union the source should have written keeps the marker
    /// out of the AST vocabulary entirely, so no consumer downstream has to
    /// know it existed; `mark` (the `?`) stands in as the `null` member's token,
    /// which only ever supplies a span.
    fn orNull(p: *Parser, ty: Node, mark: u32) PE!Node {
        const null_ty = try p.addNode(.{ .tag = .null_literal, .main_token = mark, .data = .{ .lhs = 0, .rhs = 0 } });
        const top = p.scratchTop();
        defer p.scratch.shrinkRetainingCapacity(top);
        try p.pushScratch(ty);
        try p.pushScratch(null_ty);
        const range = try p.scratchToSpan(top);
        return p.addNode(.{ .tag = .union_type, .main_token = mark, .data = .{ .lhs = range.start, .rhs = range.end } });
    }

    /// tsc's `isStartOfType` applied `n` tokens ahead. Liberal where tsc looks
    /// further (`-` only before a numeric literal, `(` only before a
    /// parenthesized-or-function type): saying "a type starts here" only ever
    /// declines to read a `?` as a nullability marker, so erring that way costs
    /// a missing TS17019 rather than a false one.
    fn startsTypeAt(p: *Parser, n: usize) bool {
        const tag = p.peekTag(n);
        return switch (tag) {
            .keyword_void,
            .keyword_null,
            .keyword_true,
            .keyword_false,
            .keyword_this,
            .keyword_typeof,
            .keyword_new,
            .keyword_import,
            .keyword_function,
            .l_brace,
            .l_bracket,
            .l_paren,
            .lt,
            .lt_lt,
            .pipe,
            .amp,
            .minus,
            .asterisk,
            .question,
            .bang,
            .dot_dot_dot,
            .string_literal,
            .numeric_literal,
            .bigint_literal,
            .no_substitution_template_literal,
            .template_head,
            => true,
            else => isIdentLike(tag),
        };
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
            .question => {
                // `?T` — tsc's `parseJSDocUnknownOrNullableType`, which takes a
                // full `parseType()` operand. Measured against tsgo: `Array<?>`
                // answers TS1110 at the `>`, i.e. the operand is parsed
                // unconditionally (tsc's JSDocUnknownType lookahead for `?,`
                // `?)` `?>` is not reached in a `.ts` file).
                const mark = try p.bump();
                const inner = try p.parseType();
                try p.errAtRange(.nullable_type_prefix, mark, p.lastIdx());
                return p.orNull(inner, mark);
            },
            .bang => {
                // `!T` — tsc's `parseJSDocNonNullableType`, whose operand is a
                // `parseNonArrayType()`, so the `[]` of `!string[]` binds
                // outside the marker. The marker itself means nothing in a
                // `.ts` file, so the operand IS the type.
                const mark = try p.bump();
                const inner = try p.parsePrimaryType();
                try p.errAtRange(.non_nullable_type_prefix, mark, p.lastIdx());
                return inner;
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
                    // The HEAD of a type reference is an identifier REFERENCE —
                    // tsc's `parseIdentifier`, and its binder's
                    // `checkStrictModeIdentifier` does not exempt it the way it
                    // exempts an IdentifierName. So `var v: yield` is TS1212
                    // wherever it stands, generator body or not, and `var u:
                    // public` with it (measured). The `.B.C` tail is an
                    // IdentifierName and stays exempt.
                    try p.checkStrictReserved();
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
                var ty = try p.parseTypeIn(.tuple_optional);
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
        const members = blk: {
            // A type literal nested in an interface member answers for itself.
            const saved = p.in_interface_body;
            defer p.in_interface_body = saved;
            p.in_interface_body = false;
            break :blk try p.parseTypeMembersRest();
        };
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
        try p.checkTemplateEscapes(head);
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
                    const part = try p.bump();
                    try p.checkTemplateEscapes(part);
                    continue;
                },
                .template_tail => {
                    try chunk_toks.append(p.gpa, p.curIdx());
                    const part = try p.bump();
                    try p.checkTemplateEscapes(part);
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

        // Modifiers. tsc runs `parseModifiers` here — BEFORE it knows which
        // member kind follows — and lets `checkGrammarModifiers` judge the run
        // against that kind afterwards: TS1071 on an index signature, TS1070 on
        // any other type member. Consuming only `readonly` left the rest as a
        // phantom property named `static`/`public`/…, which then earned a
        // duplicate-identifier TS2300 the moment two of them shared a block
        // (`staticIndexSignature4/5`) and a TS7008 of its own when the keyword
        // was one the checker could see (`async`, `export`, `in`, `out`).
        //
        // `readonly` is the one keyword this position allows on a property; on a
        // method it is TS1024, which ztsc under-reports rather than mis-word.
        var bad_modifier: TokenIndex = 0;
        while (index_signature.isModifierKind(p.curTag())) {
            const t1 = p.peekTag(1);
            if (!(isNameLike(t1) or t1 == .string_literal or t1 == .numeric_literal or t1 == .l_bracket)) break;
            const was_readonly = p.curTag() == .keyword_readonly;
            const m = try p.bump();
            if (was_readonly) {
                flags |= ast.Flags.readonly;
            } else if (bad_modifier == 0) {
                bad_modifier = m;
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
        var computed: ?ComputedName = null;
        if (p.curTag() == .l_bracket) {
            if (p.atIndexSignature()) {
                return p.parseIndexSignature(flags, false);
            }
            const cn = try p.parseComputedMemberName();
            name_tok = cn.name_tok;
            flags |= cn.flags;
            computed = cn;
        }
        // Not an index signature, so the run of modifiers above answers for the
        // member it DOES introduce. tsc stops at the first offender.
        if (bad_modifier != 0 and p.spec == 0) {
            const at = p.tokSpan(bad_modifier, bad_modifier);
            try p.errAtSpanArg(.type_member_modifier, at, at);
        }

        // Property / method name.
        if (name_tok != 0) {
            // already set by the well-known-symbol path above
        } else if (isNameLike(p.curTag()) or p.curTag() == .string_literal or
            p.curTag() == .numeric_literal or p.curTag() == .bigint_literal)
        {
            // `interface I { #x: string }` / `type A = { #m(): string }` — a
            // TYPE member list is never a class body either, so TS18016.
            if (p.curTag() == .private_identifier) try p.errAtCur(.private_name_outside_class);
            // `interface G { 2n: string }` — TS1539, as in an object literal.
            if (p.curTag() == .bigint_literal) try p.errAtCur(.bigint_property_name);
            name_tok = try p.bump();
        } else {
            try p.fail(.expected_type_member);
            return p.errorNode();
        }
        if (try p.eat(.question) != null) flags |= ast.Flags.optional;

        if (p.curTag() == .l_paren or p.atLt()) {
            const proto = try p.parseFnProtoRest(flags, name_tok);
            // `type A = { get foo() { return 0 } }` — tsc's `parseTypeMember`
            // ends every method and accessor with `parseFunctionBlockOrSemicolon`,
            // so a BODY here parses and the grammar pass answers TS1183: a type
            // member list is an ambient context, and that is the one diagnostic
            // tsgo gives the whole shape. Refusing the `{` answered TS1131 and
            // then re-read the closing `}` as a statement — two false keys per
            // accessor. The body is parsed for its own diagnostics and dropped:
            // a signature has no implementation to hang it off, and the ambient
            // flag keeps its statements from each earning a TS1036 of their own.
            if (p.curTag() == .l_brace) {
                const was_ambient = p.ambient;
                p.ambient = true;
                defer p.ambient = was_ambient;
                _ = try p.parseFunctionBody();
            }
            const member = try p.addNode(.{ .tag = .method_signature, .main_token = name_tok, .data = .{ .lhs = proto, .rhs = flags } });
            if (computed) |cn| try p.finishComputedName(cn, member, p.typeMemberHome(), .method_signature, false);
            return member;
        }
        var type_ann: Node = null_node;
        if (try p.eat(.colon) != null) type_ann = try p.parseType();
        const member = try p.addNode(.{ .tag = .property_signature, .main_token = name_tok, .data = .{ .lhs = type_ann, .rhs = flags } });
        if (computed) |cn| try p.finishComputedName(cn, member, p.typeMemberHome(), .property, false);
        return member;
    }

    /// Which of tsc's two type-member wordings this member list gets. An
    /// interface and an object type literal are the same grammar and differ only
    /// here (TS1169 vs TS1170).
    fn typeMemberHome(p: *const Parser) computed_member.Home {
        return if (p.in_interface_body) .interface_body else .type_literal;
    }

    /// tsc's `isUnambiguouslyIndexSignature`, run as a lookahead from the `[`.
    /// The sequence an index signature is SPELLED with is `[ id :`, but tsc
    /// claims five more for error recovery, each of which then answers one
    /// grammar diagnostic instead of a cascade of parse errors: `[...`, `[]`,
    /// `[id,`, `[id?,`, `[id?:`, `[id?]`, and `[<modifier> id`. Plain `[id]`,
    /// `[id.b]`, `[id =` and a literal key are NOT claimed — they are computed
    /// property names, which is why `[Symbol.iterator]` and `[Kind]` still
    /// parse as members.
    fn atIndexSignature(p: *Parser) bool {
        std.debug.assert(p.curTag() == .l_bracket);
        const t1 = p.peekTag(1);
        if (t1 == .dot_dot_dot or t1 == .r_bracket) return true;
        if (index_signature.isModifierKind(t1)) return isIdentLike(p.peekTag(2));
        if (!isIdentLike(t1)) return false;
        const t2 = p.peekTag(2);
        // A `,` cannot appear in a computed property name (no comma expression
        // there), so tsc reads it as a badly formed indexer to give the better
        // error.
        if (t2 == .colon or t2 == .comma) return true;
        if (t2 != .question) return false;
        const t3 = p.peekTag(3);
        return t3 == .colon or t3 == .comma or t3 == .r_bracket;
    }

    /// `[k: K]: V` and every shape `atIndexSignature` claims. tsc parses the
    /// brackets as a PARAMETER LIST and leaves the judging to
    /// `checkGrammarIndexSignatureParameters`; `index_signature.check` is that
    /// function, and this collects the shape it needs.
    /// `in_class` distinguishes a CLASS index signature from a type member's:
    /// `static` is legal on the former and TS1071 on the latter, which is the
    /// one modifier whose verdict depends on where the signature sits.
    fn parseIndexSignature(p: *Parser, flags: u32, in_class: bool) PE!Node {
        const lb = try p.bump(); // '['
        // TS1071: the modifiers an index signature may not carry. tsc blames
        // the FIRST offending one and names it, so this is the rule that pays
        // for `Diagnostic.arg`: eleven keywords, one sentence, and the word
        // wanted is the source text of the very token being reported on. (The
        // fixed small families — TS1030's "modifier already seen", TS1044's
        // module-element four — keep their comptime templates; what tips this
        // one over is needing an enum arm per keyword to say one thing.)
        if (p.spec == 0) {
            const tags = p.tok_tags.items;
            const first = index_signature.memberStartTokenIn(tags, lb);
            if (index_signature.firstBadModifier(tags, first, lb, in_class)) |bad| {
                const at = p.tokSpan(bad, bad);
                try p.errAtSpanArg(.index_sig_modifier, at, at);
            }
        }
        var shape: index_signature.Shape = .{
            .bracket_token = lb,
            .parameters = 0,
            .name_token = null,
            .trailing_comma = null,
            .rest = null,
            .modifier = null,
            .question = null,
            .initializer = false,
            .parameter_type = false,
            .parameter_type_indexable = false,
            .parameter_type_bad_key = false,
            .value_type = false,
        };
        // Only the FIRST parameter is described: every rule past the count
        // check reads `parameters[0]`, and the count check outranks them all.
        var key_type: Node = null_node;
        while (p.curTag() != .r_bracket and p.curTag() != .eof) {
            const first = shape.parameters == 0;
            const rest = try p.eat(.dot_dot_dot);
            var modifier: ?u32 = null;
            while (index_signature.isModifierKind(p.curTag()) and isIdentLike(p.peekTag(1))) {
                const m = try p.bump();
                if (modifier == null) modifier = m;
            }
            const name_tok = try p.expectIdentLike();
            const question = try p.eat(.question);
            var ty: Node = null_node;
            // Whether the annotation is the bare `string`, `number` or `symbol`
            // keyword — the only spellings that provably clear tsc's TS1337 and
            // TS1268, which sit ahead of the value-type check and need the type
            // resolved. One token exactly, so `string[]` and `string | number`
            // do not qualify.
            var indexable = false;
            var bad_key = false;
            if (try p.eat(.colon) != null) {
                const key_kw = p.curTag();
                const before = p.curIdx();
                ty = try p.parseType();
                if (p.curIdx() == before + 1) {
                    indexable = key_kw == .keyword_string or key_kw == .keyword_number or
                        key_kw == .keyword_symbol;
                    // …and the keywords `isValidIndexKeyType` provably rejects
                    // (TS1268). `true`/`false` are left out: a literal type is
                    // TS1337, which comes first and is not modelled.
                    bad_key = switch (key_kw) {
                        .keyword_any,
                        .keyword_boolean,
                        .keyword_void,
                        .keyword_unknown,
                        .keyword_never,
                        .keyword_object,
                        .keyword_bigint,
                        .keyword_undefined,
                        .keyword_null,
                        => true,
                        else => false,
                    };
                }
            }
            var initializer = false;
            if (try p.eat(.eq) != null) {
                _ = try p.parseAssignExpr(.{});
                initializer = true;
            }
            if (first) {
                shape.name_token = name_tok;
                shape.rest = rest;
                shape.modifier = modifier;
                shape.question = question;
                shape.initializer = initializer;
                shape.parameter_type = ty != null_node;
                shape.parameter_type_indexable = indexable;
                shape.parameter_type_bad_key = bad_key;
                key_type = ty;
            }
            shape.parameters += 1;
            // A `,` that is the last thing in the brackets is tsc's
            // `hasTrailingComma` on the parameter list.
            const comma = try p.eat(.comma) orelse break;
            shape.trailing_comma = if (p.curTag() == .r_bracket) comma else null;
            // `expectIdentLike` does not consume on failure, so a token that is
            // neither a name nor `]` would spin here forever without this.
            if (!isIdentLike(p.curTag()) and p.curTag() != .dot_dot_dot and
                !index_signature.isModifierKind(p.curTag())) break;
        }
        _ = try p.expect(.r_bracket, .expected_r_bracket);
        var value_type: Node = null_node;
        if (try p.eat(.colon) != null) {
            value_type = try p.parseType();
            shape.value_type = true;
        }
        // A type-literal member list separates with `;` OR `,`
        // (`{ [k: string]: E, [k: number]: E }` is legal and common); the
        // member loop eats the separator, so a `,` here is not a missing
        // semicolon. Without this, that shape reported a false TS1005 — and a
        // false parse error suppresses the whole file's semantic pass.
        if (p.curTag() != .comma) try p.expectSemicolon();
        const reports = index_signature.check(shape);
        if (reports.trailing_comma) |r| try p.errAtToken(r.code, r.token);
        if (reports.initializer_outside_impl) |r| try p.errAtToken(r.code, r.token);
        if (reports.chain) |r| try p.errAtToken(r.code, r.token);
        // The checker wants a key and a value type; a missing one becomes an
        // error node rather than 0, which is what every other recovery path in
        // this parser hands it.
        const extra = try p.addExtra(ast.IndexSig{
            .name_token = shape.name_token orelse lb,
            .key_type = if (key_type != null_node) key_type else try p.errorNode(),
            .value_type = if (value_type != null_node) value_type else try p.errorNode(),
        });
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

test "a computed member name is parsed, whatever the key" {
    // A method with a BODY is silent whatever its computed key says (tsc's
    // `checkGrammarMethod` judges only a method with no body); the member is
    // parsed and its name is simply absent. Measured against tsgo, `t/k8.ts`.
    try expectDiagCount("class B { [computeKey()]() {} }", 0);
    // The same key on a PROPERTY and on an overload signature does earn a
    // TS116x — see `computed_member.zig` for which wording goes where.
    try expectDiagCount("class B { [computeKey()]: number; }", 1);
    try expectDiagCount("class B { [computeKey()](): void; }", 1);
    try expectDiagCount("interface B { [computeKey()]: number }", 1);
    try expectDiagCount("type B = { [computeKey()]: number }", 1);
    // …and a literal, a template literal, a signed number and an entity name
    // are all late-bindable in principle, so none of them does.
    try expectDiagCount("class B { [\"lit\"]: number; }", 0);
    try expectDiagCount("class B { [`tpl`]: number; }", 0);
    try expectDiagCount("class B { [-1]: number; }", 0);
    try expectDiagCount("class B { [a.b.c]: number; }", 0);
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
    // Deeper qualification is an entity name too, so it parses and reports
    // nothing — the member just has no name (tsgo agrees, `t/k8.ts`).
    try expectDiagCount("class B { [a.b.c]() {} }", 0);
    try expectDiagCount("interface J { [a.b.c]: number; }", 0);
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

test "TS1120: an export assignment cannot have modifiers" {
    try expectDiags("var x;\nexport export = x;\n", .{}, &.{.{ 1120, 2, 1 }});
    try expectDiags("var x;\nexport declare export = x;\n", .{}, &.{.{ 1120, 2, 1 }});
    // Not the repeat diagnostic, and not every `export export`.
    try expectDiags("var x;\nexport = x;\n", .{}, &.{});
    try expectDiags("export export class C {}\n", .{}, &.{.{ 1030, 1, 8 }});
    try expectDiags("export declare const c: number;\n", .{}, &.{});
}

test "an unterminated template is still a template (and still takes a tag)" {
    // tsc's scanner reports TS1160 and hands the parser a template token, so
    // the tag forms a tagged template and nothing else is blamed.
    try expectDiags("function f(x: TemplateStringsArray) {}\nf `abc", .{}, &.{.{ 1160, 2, 7 }});
    try expectDiags("let s = `abc", .{}, &.{.{ 1160, 1, 13 }});
}

test "TS1109: `yield*` demands an operand" {
    try expectDiags("function* g() {\n  yield *;\n}\n", .{}, &.{.{ 1109, 2, 10 }});
    try expectDiags("function* g() {\n  yield*\n}\n", .{}, &.{.{ 1109, 3, 1 }});
    // A BARE `yield` keeps the optional reading.
    try expectDiags("function* g() {\n  yield;\n  yield 1;\n  yield* [2];\n}\n", .{}, &.{});
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
