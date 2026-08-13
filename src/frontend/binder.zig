//! Per-file binder: symbol tables, scope tree, control-flow graph.
//!
//! Design decisions:
//!
//! - **Everything is u32 indices in flat arrays**, matching the AST's
//!   data-oriented style. Symbols, scopes, and flow nodes are SoA; the sealed
//!   `Bind` result lives in the per-file arena and is immutable afterwards.
//!   0 is the "none" sentinel throughout (symbol 0 and flow 0 are reserved
//!   dummies; scope 0 is the file scope, which is never a child).
//! - **Scope member maps**: during binding, a single file-wide open-addressed
//!   hash map keyed by `(scope << 32) | atom` handles inserts and duplicate
//!   detection in O(1) — one map per file, not one per scope, so there is no
//!   per-scope HashMap churn. At seal time members are flattened into two
//!   parallel arrays (`member_atoms`, `member_syms`) segmented per scope via
//!   `scope_members_start` (n+1 entries, so `end == start[s+1]`), each
//!   segment **sorted by atom for binary-search lookup**. Sorted-segment
//!   lookup costs 8 bytes/member with zero per-scope allocation; a
//!   per-scope table would pay ~2x for load factor plus per-scope headers.
//! - **Symbols support multiple declarations** (function overloads,
//!   interface-interface merge) via a per-symbol decl list, built during
//!   binding as linked links in scratch and sealed into one flat `decls`
//!   array segmented by `symbol_decls_start` (n+1 entries).
//! - **One symbol per (scope, name)** across value and type space, tsc-style:
//!   `var x; interface x {}` is one symbol with both flags set. Conflicts are
//!   detected with per-kind "excludes" masks (see `DeclKind.excludes`).
//! - **Hoisting**: `var` and (per modern/strict semantics that ES modules
//!   imply) *not* function declarations — functions in blocks bind in the
//!   block. `var` binds in the nearest enclosing function/file scope; the
//!   scopes it hoists past are recorded (`var_transits`) so a later
//!   `let x` in one of those blocks still reports TS2451 regardless of
//!   declaration order. let/const/class bind in the current block and record
//!   their first declaration node for the checker's TDZ checks (not checked here).
//! - **Flow graph** modeled on tsc's antecedent-linked flow nodes: `start`,
//!   `assign`, `cond_true`/`cond_false`, `branch_label` (join),
//!   `loop_label` (join with loop-back edges added later), `switch_clause`,
//!   and a single shared `unreachable` node (flow 1). Labels keep antecedent
//!   lists in `flow_extra`; single-antecedent joins collapse to their
//!   antecedent and never allocate a node. Flow ids are attached to
//!   identifier/member reads via a compact (node, flow) map sorted by node —
//!   8 bytes per *reference* instead of 4 bytes per *node* for a full side
//!   array; `flowAt` is a binary search.
//! - Deferred flow precision (documented for the checker): `??` and optional chaining
//!   bind linearly (no nullish branch); `continue` joins the loop head
//!   (for `for(;;)` this skips the update's assignments — conservative);
//!   try/catch/finally uses the pre-try state as the catch antecedent and
//!   joins conservatively; default-parameter and `getter/setter` flows are
//!   linear; labeled `continue` falls back to the innermost loop if the
//!   label doesn't name a loop.
//! - Not bound (documented): function/class *expression* names (their
//!   self-references show up as unresolved refs, which the binder treats as
//!   non-errors), computed member names as symbols (the key expression is
//!   still bound), and declaration merging beyond interface-interface
//!   (class+interface pairs merge into one SYMBOL here, but the two halves'
//!   members and bases are folded by the checker — `classInstanceGeneric` —
//!   not by sharing a members scope, so the fold does not depend on which
//!   block the file happens to write first).
//!
//! Unresolved identifiers are NOT errors at bind time (globals and cross-file
//! imports resolve at link time); they are exposed via `Bind.unresolved`.
//!
//! This file is the *construction* half: `bind()`, the `Binder` machine and
//! the golden tests. The sealed result surface (`Bind` and its ids, flags and
//! records) lives in bind_result.zig and its text dump in bind_dump.zig; both
//! are re-exported below, so a consumer can keep importing `binder` alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const intern = @import("../intern.zig");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Diagnostic = diagnostics.Diagnostic;
const Code = diagnostics.Code;
const Span = source.Span;

const bind_result = @import("bind_result.zig");

// The sealed result surface lives in bind_result.zig; re-exported here so
// every consumer can keep importing `binder`.
pub const SymbolId = bind_result.SymbolId;
pub const no_symbol = bind_result.no_symbol;
pub const ScopeId = bind_result.ScopeId;
pub const file_scope = bind_result.file_scope;
pub const FlowId = bind_result.FlowId;
pub const no_flow = bind_result.no_flow;
pub const unreachable_flow = bind_result.unreachable_flow;
pub const ScopeKind = bind_result.ScopeKind;
pub const SymbolFlags = bind_result.SymbolFlags;
pub const FlowTag = bind_result.FlowTag;
pub const ImportKind = bind_result.ImportKind;
pub const ExportKind = bind_result.ExportKind;
pub const ImportRec = bind_result.ImportRec;
pub const ExportRec = bind_result.ExportRec;
pub const Ref = bind_result.Ref;
pub const AmbientModule = bind_result.AmbientModule;
pub const Bind = bind_result.Bind;

const Error = error{OutOfMemory};

const fbits = bind_result.fbits;
const mask_let_const_class = bind_result.mask_let_const_class;
const mask_value = bind_result.mask_value;
const mask_type = bind_result.mask_type;
const mask_member = bind_result.mask_member;

/// Strip surrounding quotes from a module-specifier string-literal token.
fn stripModuleQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
        if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
        return text[1..];
    }
    return text;
}

/// The modifiers that make a class member non-public (tsc's
/// `ModifierFlags.NonPublic`). `public` is the default and never restricts.
const nonpublic_mask: u32 = ast.Flags.private | ast.Flags.protected;

/// What kind of declaration is being bound; determines the flags a new
/// symbol gets and which existing flags it refuses to merge with.
const DeclKind = enum {
    var_decl,
    let_decl,
    const_decl,
    function,
    class,
    interface,
    type_alias,
    enum_decl,
    /// One member of an enum body (tsc's `SymbolFlags.EnumMember`).
    enum_member,
    namespace,
    /// A `namespace`/`module` whose body is type-only (see
    /// `SymbolFlags.ns_uninstantiated`). Same symbol shape as `.namespace`,
    /// but it excludes nothing and nothing excludes it.
    namespace_type,
    type_param,
    param,
    catch_param,
    import_value,
    import_type,
    property,
    method,
    getter,
    setter,
    /// `fn.prop = value` — an expando property declaration.
    expando_member,

    fn flags(k: DeclKind) SymbolFlags {
        return switch (k) {
            .var_decl => .{ .var_decl = true },
            .let_decl => .{ .let_decl = true },
            .const_decl => .{ .const_decl = true },
            .function => .{ .function = true },
            .class => .{ .class = true },
            .interface => .{ .interface = true },
            .type_alias => .{ .type_alias = true },
            .enum_decl => .{ .enum_decl = true },
            .enum_member => .{ .enum_member = true },
            .namespace => .{ .namespace_decl = true },
            .namespace_type => .{ .namespace_decl = true, .ns_uninstantiated = true },
            .type_param => .{ .type_param = true },
            .param => .{ .param = true },
            .catch_param => .{ .catch_param = true },
            .import_value => .{ .import_binding = true },
            .import_type => .{ .import_binding = true, .type_only = true },
            .property => .{ .property = true },
            .method => .{ .method = true },
            .getter => .{ .getter = true },
            .setter => .{ .setter = true },
            .expando_member => .{ .expando_member = true },
        };
    }

    /// Existing-symbol flag bits this declaration kind cannot merge with.
    /// One symbol spans value and type space, so e.g. `var` excludes other
    /// value declarations but not `interface`.
    fn excludes(k: DeclKind) u32 {
        return switch (k) {
            // var+var and var+param merge; everything else valueish clashes.
            // A namespace merges with function/class/enum/interface, so those
            // kinds whitelist the namespace bit here (and vice-versa below).
            .var_decl => mask_value & ~(fbits(.{ .var_decl = true }) | fbits(.{ .param = true })),
            .let_decl, .const_decl => mask_value,
            // A function also merges with a *class* — tsc's `FunctionExcludes`
            // omits `Class` and `ClassExcludes` omits `Function`, so a `.d.ts`
            // can model a callable class (`function UAParser(…): IResult` next
            // to `class UAParser`). The pair is only legal when every class
            // declaration is ambient; `checkFunctionClassMerge` reports
            // TS2813/TS2814 otherwise.
            .function => mask_value & ~(fbits(.{ .function = true }) |
                fbits(.{ .namespace_decl = true }) | fbits(.{ .class = true })),
            .class => (mask_value & ~(fbits(.{ .class = true }) |
                fbits(.{ .namespace_decl = true }) | fbits(.{ .function = true }))) |
                (mask_type & ~(fbits(.{ .interface = true }) | fbits(.{ .namespace_decl = true }))),
            .interface => mask_type & ~(fbits(.{ .interface = true }) | fbits(.{ .class = true }) |
                fbits(.{ .namespace_decl = true })),
            // A type alias also merges with a namespace (the alias carries the
            // type meaning; the namespace the value + container meaning).
            .type_alias => mask_type & ~fbits(.{ .namespace_decl = true }),
            // Two enum blocks (incl. const enum) with the same name merge;
            // everything else in value or type space clashes (bar namespace).
            .enum_decl => (mask_value | mask_type) & ~(fbits(.{ .enum_decl = true }) | fbits(.{ .namespace_decl = true })),
            // tsc's `EnumMemberExcludes = EnumMember`: members share a table
            // with nothing else, so only another member of the same name
            // clashes (`enum E { A, A }` — TS2300 at both spellings).
            .enum_member => fbits(.{ .enum_member = true }),
            // A namespace merges with another namespace, function, class,
            // enum, interface, and type alias; it clashes with var/let/const.
            .namespace => (mask_value & ~(fbits(.{ .namespace_decl = true }) |
                fbits(.{ .function = true }) | fbits(.{ .class = true }) | fbits(.{ .enum_decl = true }))) |
                (mask_type & ~(fbits(.{ .namespace_decl = true }) | fbits(.{ .interface = true }) |
                    fbits(.{ .class = true }) | fbits(.{ .enum_decl = true }) | fbits(.{ .type_alias = true }))),
            // tsc's `NamespaceModuleExcludes = 0`.
            .namespace_type => 0,
            .type_param => mask_type & ~fbits(.{ .class = true }),
            .param => mask_value & ~fbits(.{ .var_decl = true }),
            .catch_param => mask_value,
            .import_value => mask_value | mask_type,
            .import_type => mask_type | fbits(.{ .import_binding = true }),
            .property => mask_member,
            .method => mask_member & ~fbits(.{ .method = true }),
            .getter => mask_member & ~fbits(.{ .setter = true }),
            .setter => mask_member & ~fbits(.{ .getter = true }),
            // Repeated `fn.prop = …` statements are all declarations of the
            // same property; they merge (the member type unions them).
            .expando_member => 0,
        };
    }

    fn isBlockScoped(k: DeclKind) bool {
        return switch (k) {
            .let_decl, .const_decl, .class => true,
            else => false,
        };
    }

    fn isTypeOnly(k: DeclKind) bool {
        return switch (k) {
            .interface, .type_alias, .type_param, .import_type => true,
            else => false,
        };
    }

    fn isImport(k: DeclKind) bool {
        return k == .import_value or k == .import_type;
    }
};

/// Bind a sealed parse tree. Output goes into `arena` (the per-file binder
/// arena) and is sealed on return; internal scratch is freed before
/// returning. `interner`/`io`/`gpa` follow the shared-interner contract
/// (gpa must be thread-safe when binding files in parallel).
/// Total on arbitrary parser output: never fails except on OOM.
pub fn bind(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,
    is_dts: bool,
) Error!Bind {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();

    var b: Binder = .{
        .arena = arena,
        .scratch = scratch_arena.allocator(),
        .io = io,
        .gpa = gpa,
        .interner = interner,
        .tree = tree,
        .src = src,
        // A `.d.ts` file is entirely ambient: seed `ambient` so every top-level
        // `namespace N { … }` treats its members as implicitly exported (visible
        // as `N.member`), matching tsc — declaration files omit `export` on
        // namespace members that are nonetheless part of the public shape.
        .ambient = is_dts,
        .is_dts = is_dts,
    };

    // Reserved entries (0-sentinel style, like the AST).
    try b.sym_names.append(b.scratch, 0);
    try b.sym_flags.append(b.scratch, .{});
    try b.sym_scopes.append(b.scratch, 0);
    try b.sym_decl_head.append(b.scratch, 0);
    try b.sym_decl_tail.append(b.scratch, 0);
    try b.sym_decl_count.append(b.scratch, 0);
    try b.sym_reported.append(b.scratch, 0);
    try b.sym_block.append(b.scratch, 0);
    try b.decl_links.append(b.scratch, .{ .value = 0, .next = 0 });
    try b.decl_name_toks.append(b.scratch, 0);
    try b.ante_links.append(b.scratch, .{ .value = 0, .next = 0 });

    try b.scope_parents.append(b.scratch, 0);
    try b.scope_kinds.append(b.scratch, .file);
    try b.scope_owners.append(b.scratch, 0);

    try b.addFlowRaw(.none, 0, 0); // flow 0
    try b.addFlowRaw(.unreachable_, 0, 0); // flow 1
    b.cur_flow = try b.addFlow(.start, no_flow, 0); // file entry

    // Bind all top-level statements of the root.
    for (tree.nodeRange(0)) |stmt| {
        if (stmt != null_node) try b.bindStatement(stmt);
    }

    return b.seal();
}

const Link = struct { value: u32, next: u32 };
const Pending = struct { head: u32 = 0, tail: u32 = 0, count: u32 = 0 };
const PendingId = u32;

const CtxKind = enum(u8) { loop, switch_blk, labeled };
const Ctx = struct {
    kind: CtxKind,
    label: Atom = 0,
    /// Pending join for `break` targets.
    brk: PendingId,
    /// Pending join for `continue` targets (loops only).
    cont: PendingId = 0,
};

const CondFlows = struct { t: FlowId, f: FlowId };

/// One `?.` of an optional chain being bound: the flow the short-circuit test
/// is made in, the expression tested (the link's receiver), and the flow the
/// chain continues in when it did *not* short-circuit.
const ChainTest = struct { ante: FlowId, expr: Node, taken: FlowId };

const Binder = struct {
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,

    // symbols under construction (scratch)
    sym_names: std.ArrayList(Atom) = .empty,
    sym_flags: std.ArrayList(SymbolFlags) = .empty,
    sym_scopes: std.ArrayList(ScopeId) = .empty,
    sym_decl_head: std.ArrayList(u32) = .empty,
    sym_decl_tail: std.ArrayList(u32) = .empty,
    sym_decl_count: std.ArrayList(u32) = .empty,
    /// How many of a symbol's declarations an earlier failed merge has
    /// already named, so `reportDuplicate` reports each spelling once. Pure
    /// bookkeeping for the diagnostic; scratch-only, never sealed.
    sym_reported: std.ArrayList(u32) = .empty,
    /// The declaration BLOCK (`cur_block`) a symbol was most recently
    /// declared in — see `mergesAcrossBlocks`. Scratch-only bookkeeping for
    /// the duplicate-member diagnostic.
    sym_block: std.ArrayList(Node) = .empty,
    decl_links: std.ArrayList(Link) = .empty,
    /// Name token of each `decl_links` entry, so a failed merge can point at
    /// declarations bound earlier. Parallel to `decl_links` and, like it,
    /// scratch-only — the sealed `Bind` keeps declaration NODES, and
    /// recovering a name token from a node would mean a switch over every
    /// declaration shape.
    decl_name_toks: std.ArrayList(TokenIndex) = .empty,

    // scopes under construction
    scope_parents: std.ArrayList(ScopeId) = .empty,
    scope_kinds: std.ArrayList(ScopeKind) = .empty,
    scope_owners: std.ArrayList(Node) = .empty,
    /// The active scope chain as an explicit stack (for var-hoist checks).
    scope_stack: std.ArrayList(ScopeId) = .empty,
    /// One map for the whole file: (scope << 32 | atom) -> symbol.
    members: std.AutoHashMapUnmanaged(u64, SymbolId) = .empty,
    /// (scope, atom) pairs a `var` hoisted past, for order-independent
    /// var-vs-let conflict detection.
    var_transits: std.ArrayList(Link) = .empty, // value=scope, next=atom (reused shape)
    /// class/interface symbol -> members scope (merge reuses it).
    member_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,
    static_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,
    namespace_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,
    /// Enum symbol -> its member scope, so every block of a merged `enum E`
    /// binds into one table (the same reuse `namespace_scopes` gives bodies).
    enum_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,
    /// Expando-function symbol -> the scope its `fn.prop = …` properties are
    /// declared in (created on the first such assignment).
    expando_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,

    // flow under construction
    flow_tags: std.ArrayList(FlowTag) = .empty,
    flow_a: std.ArrayList(u32) = .empty,
    flow_b: std.ArrayList(u32) = .empty,
    flow_scopes: std.ArrayList(ScopeId) = .empty,
    pendings: std.ArrayList(Pending) = .empty,
    ante_links: std.ArrayList(Link) = .empty,
    flow_pairs: std.ArrayList(Link) = .empty, // value=node, next=flow
    /// Short-circuit tests of the optional chains currently being bound
    /// (`bindOptionalChain`); a nested chain occupies a suffix of the stack.
    chain_sc: std.ArrayList(ChainTest) = .empty,

    refs: std.ArrayList(Ref) = .empty,
    import_recs: std.ArrayList(ImportRec) = .empty,
    export_recs: std.ArrayList(ExportRec) = .empty,
    diags: std.ArrayList(Diagnostic) = .empty,
    /// Per-file atom cache so repeated identifiers don't hit the shared
    /// (mutex-guarded) interner more than once each.
    atom_cache: std.StringHashMapUnmanaged(Atom) = .empty,
    /// Every atom this file touched, in first-touch order (`Bind.first_touch`).
    first_touch: std.ArrayList(Atom) = .empty,

    cur_scope: ScopeId = file_scope,
    var_scope: ScopeId = file_scope,
    cur_flow: FlowId = no_flow,
    /// The pending join for the enclosing CONSTRUCTOR's return edges, or null
    /// when the current function is not a constructor body. tsc's
    /// `currentReturnTarget`, built for constructors only — the note in
    /// `bindContainer` says why: *"We create a return control flow graph for
    /// IIFEs and constructors. For constructors we use the return control flow
    /// graph in strict property initialization checks."* Saved/restored by
    /// `saveState`, so a `return` inside a callback declared in the constructor
    /// does not join the constructor's exit.
    ctor_return: ?PendingId = null,
    ctxs: std.ArrayList(Ctx) = .empty,
    /// Contexts below this index belong to enclosing functions.
    ctx_base: usize = 0,
    /// Set by a labeled statement wrapping a loop/switch.
    pending_label: Atom = 0,
    /// True while binding the name(s) of an `export`ed declaration.
    exporting_node: Node = 0,
    /// The class / interface / object-type declaration whose members are
    /// being bound (0 outside one). Two blocks of a merging container share a
    /// member scope, and a name repeated ACROSS them merges rather than
    /// clashing — see `mergesAcrossBlocks`.
    cur_block: Node = 0,
    /// True while binding inside an ambient (`declare`) namespace body, where
    /// members are implicitly exported (visible as `N.member` without an
    /// explicit `export`), matching tsc's ambient-context rule.
    ambient: bool = false,
    /// Scopes holding this file's `declare global { … }` / bare `global { … }`
    /// block members — the file's global contributions, in creation order.
    /// One scope per distinct *enclosing container*, not one per block: blocks
    /// sharing a container merge within the file exactly as reopened
    /// namespaces do, while a `global { … }` nested in `declare module "m"`
    /// gets its own scope parented to `m`'s body, so names inside it resolve
    /// outward into the module (tsc's `resolveName` walks the node parent
    /// chain; real `@types/node` leans on it heavily — `events.d.ts` declares
    /// `type Key<…>` in the module body and uses it from `global { namespace
    /// NodeJS { … } }`).
    global_scopes: std.ArrayList(ScopeId) = .empty,
    /// Set once any top-level `import`/`export` is bound: the file is a module
    /// Includes `export {}` (a marker export with no bindings), which
    /// is exactly how a source file opts into module semantics.
    saw_module_syntax: bool = false,
    /// Set once a top-level *export declaration* is bound — `export { … }`,
    /// `export * from`, `export =`, or `export default <expr>`. Statements that
    /// merely carry an `export` MODIFIER (`export const x`, `export default
    /// function f() {}`) do not count. This is tsc's `hasExportDeclarations`,
    /// and its absence in a `.d.ts` makes the file an *export context* (see
    /// `applyExportContext`).
    saw_export_declaration: bool = false,
    /// The source is a `.d.ts` declaration file (tsc's `NodeFlags.Ambient` on
    /// the source file). Read by `seal` for the export-context rule; `ambient`
    /// is seeded from it but moves around during binding.
    is_dts: bool = false,
    /// Name from `export as namespace X;` (the UMD global declaration), or 0.
    umd_name: Atom = 0,
    /// `declare module "spec" { … }` blocks collected during binding.
    ambient_mods: std.ArrayList(AmbientModule) = .empty,
    /// Body scope of the `declare module "spec" { … }` block currently being
    /// bound (0 = none). That body is a MODULE body, so its `export { … }`
    /// statements are module exports, while a plain `namespace N { … }` nested
    /// anywhere inside it exports namespace members instead.
    ambient_mod_scope: ScopeId = 0,

    // --- small helpers ------------------------------------------------------

    fn atomOf(b: *Binder, text: []const u8) Error!Atom {
        const gop = try b.atom_cache.getOrPut(b.scratch, text);
        if (!gop.found_existing) {
            const a = try b.interner.intern(b.io, b.gpa, text);
            gop.value_ptr.* = a;
            // Cache miss == this file's first touch of the string. The list is
            // the file's contribution to the program-wide interning order the
            // driver replays to make atom ids independent of worker scheduling
            // (`Interner.renumber`). Atoms from the frozen prefix — the lib's,
            // interned before any worker started — never move, so recording
            // them would only make the replay longer.
            if (!b.interner.isFrozen(a)) try b.first_touch.append(b.scratch, a);
        }
        return gop.value_ptr.*;
    }

    fn tokenText(b: *Binder, tok: TokenIndex) []const u8 {
        return b.tree.tokenSlice(b.src, tok);
    }

    /// Atom of an identifier-ish token, `\uXXXX` escapes decoded — the name
    /// tsc files the symbol under (`escapedText`). The decoded bytes are
    /// duplicated into the binder's scratch arena before they reach
    /// `atom_cache`, which stores the caller's slice as its key.
    fn atomOfIdent(b: *Binder, text: []const u8) Error!Atom {
        var buf: [scanner.max_unescaped_ident]u8 = undefined;
        const decoded = scanner.unescapeIdentifier(text, &buf) orelse return b.atomOf(text);
        if (b.atom_cache.get(decoded)) |a| return a;
        return b.atomOf(try b.scratch.dupe(u8, decoded));
    }

    /// Atom of an identifier-ish token.
    fn atomOfToken(b: *Binder, tok: TokenIndex) Error!Atom {
        return b.atomOfIdent(b.tokenText(tok));
    }

    /// Atom of a member/property name token; string keys lose their quotes
    /// so `"a"` and `a` name the same member. An identifier key's `\uXXXX`
    /// escapes are decoded (`o.a` is `o.a`); a STRING key's are not —
    /// string escapes are a different grammar, and `memberAtom`'s job is the
    /// syntactic key.
    fn memberAtom(b: *Binder, tok: TokenIndex) Error!Atom {
        const text = b.tokenText(tok);
        switch (b.tree.tokens.tag(tok)) {
            // `.jsx_string` is a JSX attribute's quoted value.
            .string_literal, .jsx_string => return b.atomOf(stripQuotes(text)),
            else => return b.atomOfIdent(text),
        }
    }

    /// Member-name atom honoring a `[Symbol.iterator]` computed key: when the
    /// `computed` flag is set, `tok` is the well-known-symbol property name and
    /// the member is keyed by a synthetic `__@name` atom. (`wellKnownSymbolKey`
    /// returns a static string, so it is a safe `atom_cache` key.)
    fn memberNameKey(b: *Binder, tok: TokenIndex, flags: u32) Error!Atom {
        if (flags & ast.Flags.computed_sym != 0) {
            // A `[k]` (or qualified `[a.b]`) computed key naming a const
            // `unique symbol`. The binder cannot resolve nominal symbol
            // identity, so it keys the member by a placeholder derived from
            // the key's source text; the checker rekeys it to the symbol's
            // `__@u<id>` atom when materializing the class/interface type
            // (`nominalizeComputedKey`). For the qualified form the object
            // identifier sits two tokens before the member identifier.
            if (flags & ast.Flags.computed_sym_qual != 0) {
                const s = try std.fmt.allocPrint(b.scratch, "__@k${s}.{s}", .{ b.tokenText(tok - 2), b.tokenText(tok) });
                return b.atomOf(s);
            }
            return b.computedSymPlaceholder(b.tokenText(tok));
        }
        if (flags & ast.Flags.computed != 0) {
            if (ast.wellKnownSymbolKey(b.tokenText(tok))) |k| return b.atomOf(k);
        }
        return b.memberAtom(tok);
    }

    /// Placeholder member atom for a computed const-`unique symbol` key,
    /// carrying the key identifier's text so the checker can resolve it. The
    /// `__@k$` prefix cannot appear in a real identifier, so it never collides.
    fn computedSymPlaceholder(b: *Binder, name: []const u8) Error!Atom {
        const s = try std.fmt.allocPrint(b.scratch, "__@k${s}", .{name});
        return b.atomOf(s);
    }

    /// Atom of a module-specifier string token (contents without quotes).
    fn moduleAtom(b: *Binder, tok: TokenIndex) Error!Atom {
        if (tok == 0) return 0;
        return b.atomOf(stripQuotes(b.tokenText(tok)));
    }

    /// Strips the delimiters off a literal module specifier. Backticks are
    /// included because a no-substitution template literal is a legal
    /// specifier for `import()` (`` import(`./m`) ``).
    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and (text[0] == '"' or text[0] == '\'' or text[0] == '`')) {
            const last = text[text.len - 1];
            if (last == text[0]) return text[1 .. text.len - 1];
            return text[1..];
        }
        if (text.len >= 1 and (text[0] == '"' or text[0] == '\'' or text[0] == '`')) return text[1..];
        return text;
    }

    fn tokSpan(b: *Binder, tok: TokenIndex) Span {
        const start = b.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(b.src, b.tree.tokens.tag(tok), start) };
    }

    fn diag(b: *Binder, code: Code, tok: TokenIndex) Error!void {
        try b.diags.append(b.scratch, .{ .code = code, .span = b.tokSpan(tok) });
    }

    fn nodeTag(b: *const Binder, node: Node) ast.Tag {
        return b.tree.nodeTag(node);
    }

    // --- scopes -----------------------------------------------------------

    fn newScope(b: *Binder, kind: ScopeKind, owner: Node, parent: ScopeId) Error!ScopeId {
        const id: ScopeId = @intCast(b.scope_parents.items.len);
        try b.scope_parents.append(b.scratch, parent);
        try b.scope_kinds.append(b.scratch, kind);
        try b.scope_owners.append(b.scratch, owner);
        return id;
    }

    /// Create a scope as a child of the current one and enter it.
    fn pushScope(b: *Binder, kind: ScopeKind, owner: Node) Error!ScopeId {
        const id = try b.newScope(kind, owner, b.cur_scope);
        try b.scope_stack.append(b.scratch, id);
        b.cur_scope = id;
        return id;
    }

    fn popScope(b: *Binder, to: ScopeId) void {
        while (b.scope_stack.items.len > 0 and
            b.scope_stack.items[b.scope_stack.items.len - 1] != to)
        {
            _ = b.scope_stack.pop();
        }
        b.cur_scope = to;
    }

    const SavedState = struct {
        cur_scope: ScopeId,
        var_scope: ScopeId,
        cur_flow: FlowId,
        ctx_base: usize,
        ctx_len: usize,
        stack_len: usize,
        ctor_return: ?PendingId,
    };

    fn saveState(b: *Binder) SavedState {
        return .{
            .cur_scope = b.cur_scope,
            .var_scope = b.var_scope,
            .cur_flow = b.cur_flow,
            .ctx_base = b.ctx_base,
            .ctx_len = b.ctxs.items.len,
            .stack_len = b.scope_stack.items.len,
            .ctor_return = b.ctor_return,
        };
    }

    fn restoreState(b: *Binder, s: SavedState) void {
        b.cur_scope = s.cur_scope;
        b.var_scope = s.var_scope;
        b.cur_flow = s.cur_flow;
        b.ctx_base = s.ctx_base;
        b.ctxs.items.len = s.ctx_len;
        b.scope_stack.items.len = s.stack_len;
        b.ctor_return = s.ctor_return;
    }

    // --- symbols ------------------------------------------------------------

    fn appendDecl(b: *Binder, sym: SymbolId, node: Node, name_tok: TokenIndex) Error!void {
        const link: u32 = @intCast(b.decl_links.items.len);
        try b.decl_links.append(b.scratch, .{ .value = node, .next = 0 });
        try b.decl_name_toks.append(b.scratch, name_tok);
        if (b.sym_decl_head.items[sym] == 0) {
            b.sym_decl_head.items[sym] = link;
        } else {
            b.decl_links.items[b.sym_decl_tail.items[sym]].next = link;
        }
        b.sym_decl_tail.items[sym] = link;
        b.sym_decl_count.items[sym] += 1;
    }

    fn memberKey(scope: ScopeId, atom: Atom) u64 {
        return (@as(u64, scope) << 32) | atom;
    }

    /// Flag bits used for the excludes check. A type-only import occupies
    /// the *type* space only, so `import type { T } ...; let T;` merges
    /// without error while `type T = ...` still clashes with it.
    fn effectiveBits(f: SymbolFlags) u32 {
        var bits = f.bits();
        if (f.import_binding and f.type_only) {
            bits &= ~fbits(.{ .import_binding = true });
            bits |= fbits(.{ .type_alias = true });
        }
        // A non-instantiated namespace occupies no exclusion space at all
        // (tsc's `NamespaceModule`), so it merges with anything — including a
        // `var`/`let`/`const` of the same name. The bit stays on the symbol:
        // only the excludes check ignores it, so name resolution and the
        // `N.member` container meaning are untouched.
        if (f.ns_uninstantiated) bits &= ~fbits(.{ .namespace_decl = true });
        return bits;
    }

    /// Pick the diagnostic code for a declaration that failed the excludes
    /// check against `existing`. Choices documented in the module header;
    /// golden-tested against the codes tsc reports for the common cases.
    /// Which message a failed merge gets, in tsc's `declareSymbol` order:
    /// an `enum` on either side wins, then a block-scoped EXISTING symbol,
    /// then the generic duplicate.
    ///
    /// The block-scoped arm reads the EXISTING symbol's flags alone, and
    /// `class` is not one of tsc's `SymbolFlags.BlockScopedVariable` bits.
    /// Both halves were verified against the pinned oracle in each order:
    /// `let x; var x;` and `let x; class x {}` are TS2451, while `var x;
    /// let x;`, `class x {} let x;` and `class x {} var x;` are all TS2300.
    fn dupCode(existing: SymbolFlags, kind: DeclKind) Code {
        if (existing.catch_param) return .catch_redeclare;
        const e_import = existing.import_binding;
        const n_import = kind.isImport();
        if (e_import != n_import) return .import_conflict;
        if (e_import and n_import) return .duplicate_identifier;
        if (existing.enum_decl or kind == .enum_decl) return .enum_merge_conflict;
        if (existing.let_decl or existing.const_decl) return .block_scoped_redeclare;
        return .duplicate_identifier;
    }

    /// Report a failed merge the way tsc does: at EVERY declaration of the
    /// name, not only at the newcomer. tsc's `declareSymbol` runs
    /// `addDuplicateDeclarationErrorsForSymbols` over `symbol.declarations`
    /// *and* over the incoming node, so `var g; var g; class g {}` is three
    /// TS2300s and `let f; let f; let f;` three TS2451s — one per spelling of
    /// the name, which is what the oracle prints.
    ///
    /// `sym_reported` is how many of the symbol's declarations have already
    /// been named in some earlier clash. tsc re-reports them and lets its
    /// diagnostic collection deduplicate; carrying the count instead keeps
    /// the walk O(new declarations) and needs no dedup pass. The newcomer is
    /// appended by the caller straight after, hence the `+ 1`.
    /// Report `code` at the symbol's FIRST declaration. TS2440 needs it: the
    /// message names the import declaration, which may be the one already in
    /// the table (`let b = 1; import { b } from "./m";` points at line 2's
    /// import, not at the `let`).
    fn diagAtFirstDecl(b: *Binder, sym: SymbolId, code: Code) Error!void {
        const link = b.sym_decl_head.items[sym];
        if (link == 0) return;
        try b.diag(code, b.decl_name_toks.items[link]);
    }

    /// Do the declarations already in the table and the one now being bound
    /// belong to DIFFERENT blocks of a merging container? Two `interface I`
    /// blocks — and a `class C` + `interface C` pair — contribute to one
    /// member table, and tsc merges same-named members across them instead of
    /// calling them duplicates; a type conflict there is TS2717
    /// ("Subsequent property declarations must have the same type"), not
    /// TS2300. Within ONE block a repeated name is a genuine duplicate, which
    /// is why this keys off the block and not off the scope.
    fn mergesAcrossBlocks(b: *Binder, scope: ScopeId, sym: SymbolId) bool {
        switch (b.scope_kinds.items[scope]) {
            .class_members, .class_statics, .interface_members => {},
            else => return false,
        }
        return b.sym_block.items[sym] != b.cur_block;
    }

    fn reportDuplicate(b: *Binder, sym: SymbolId, code: Code, name_tok: TokenIndex) Error!void {
        const already = b.sym_reported.items[sym];
        var link = b.sym_decl_head.items[sym];
        var i: u32 = 0;
        while (link != 0) : (link = b.decl_links.items[link].next) {
            if (i >= already) try b.diag(code, b.decl_name_toks.items[link]);
            i += 1;
        }
        try b.diag(code, name_tok);
        b.sym_reported.items[sym] = i + 1;
    }

    /// Declare `atom` in `scope`. Merges with an existing symbol when the
    /// excludes masks allow it (overloads, interface merge, var+var, value/
    /// type-space sharing); reports a diagnostic at `name_tok` otherwise
    /// (the *later* declaration site, one diagnostic per clash).
    fn declare(
        b: *Binder,
        scope: ScopeId,
        atom: Atom,
        kind: DeclKind,
        decl_node: Node,
        name_tok: TokenIndex,
        extra_flags: SymbolFlags,
    ) Error!SymbolId {
        const flags = kind.flags().merge(extra_flags);

        // Hoisted var: check the scopes it hoists past for block-scoped
        // clashes, and record transits for later `let`s (order-independent).
        if (kind == .var_decl and scope != b.cur_scope) {
            var i = b.scope_stack.items.len;
            while (i > 0) {
                i -= 1;
                const s = b.scope_stack.items[i];
                if (s == scope) break;
                if (b.members.get(memberKey(s, atom))) |sym| {
                    if (b.sym_flags.items[sym].bits() & mask_let_const_class != 0) {
                        try b.diag(.block_scoped_redeclare, name_tok);
                    }
                }
                try b.var_transits.append(b.scratch, .{ .value = s, .next = atom });
            }
        }
        // Block-scoped decl: a var declared *inside* this scope's subtree
        // (already hoisted out) still clashes.
        if (kind.isBlockScoped()) {
            for (b.var_transits.items) |t| {
                if (t.value == scope and t.next == atom) {
                    try b.diag(.block_scoped_redeclare, name_tok);
                    break;
                }
            }
        }

        const n_import = kind.isImport();
        const gop = try b.members.getOrPut(b.scratch, memberKey(scope, atom));
        if (gop.found_existing) {
            const sym = gop.value_ptr.*;
            const existing = b.sym_flags.items[sym];
            if (effectiveBits(existing) & kind.excludes() != 0 and
                !b.mergesAcrossBlocks(scope, sym))
            {
                const code = dupCode(existing, kind);
                switch (code) {
                    // TS2492 names the REDECLARATION alone and leaves the
                    // `catch (e)` binding unmarked; a duplicate TYPE
                    // PARAMETER likewise names only the later one (tsc
                    // catches that one in `checkTypeParameters`, comparing
                    // each against its predecessors, not in `declareSymbol`).
                    .catch_redeclare => try b.diag(code, name_tok),
                    // TS2440 always lands on the IMPORT declaration, whichever
                    // side of the clash it is: `import {a} …; let a = 1;` and
                    // `let b = 1; import {b} …` both point at the import.
                    .import_conflict => if (n_import)
                        try b.diag(code, name_tok)
                    else
                        try b.diagAtFirstDecl(sym, code),
                    else => if (kind == .type_param or existing.type_param)
                        try b.diag(code, name_tok)
                    else
                        try b.reportDuplicate(sym, code, name_tok),
                }
            } else if (kind == .function or kind == .method) {
                // Overload grouping: at most one implementation. tsc names
                // every declaration of the name, overload signatures
                // included — `function f(): void; function f() {} function
                // f() {}` is three TS2393s, not one. A CONSTRUCTOR gets its
                // own message (TS2392) instead.
                if (flags.has_impl and existing.has_impl) {
                    // A class constructor is spelled with the `constructor`
                    // keyword and is never static.
                    const is_ctor = !extra_flags.static_member and
                        b.tree.tokens.tag(name_tok) == .keyword_constructor;
                    const code: Code = if (is_ctor)
                        .duplicate_constructor_implementation
                    else
                        .duplicate_function_implementation;
                    try b.reportDuplicate(sym, code, name_tok);
                }
                try b.checkFunctionClassMerge(sym, existing, flags, name_tok);
            } else if (kind == .class) {
                try b.checkFunctionClassMerge(sym, existing, flags, name_tok);
            }
            b.sym_flags.items[sym] = existing.merge(flags);
            b.sym_block.items[sym] = b.cur_block;
            try b.appendDecl(sym, decl_node, name_tok);
            try b.noteExport(sym, atom, scope);
            return sym;
        }

        const sym: SymbolId = @intCast(b.sym_names.items.len);
        try b.sym_names.append(b.scratch, atom);
        try b.sym_flags.append(b.scratch, flags);
        try b.sym_scopes.append(b.scratch, scope);
        try b.sym_decl_head.append(b.scratch, 0);
        try b.sym_decl_tail.append(b.scratch, 0);
        try b.sym_decl_count.append(b.scratch, 0);
        try b.sym_reported.append(b.scratch, 0);
        try b.sym_block.append(b.scratch, b.cur_block);
        gop.value_ptr.* = sym;
        try b.appendDecl(sym, decl_node, name_tok);
        try b.noteExport(sym, atom, scope);
        return sym;
    }

    /// The function/class merge check, tsc's `checkFunctionOrConstructorSymbol`
    /// arm for `hasNonAmbientClass`. The binder lets the two kinds merge (a
    /// `.d.ts` models a callable class that way — ua-parser-js declares
    /// `function UAParser(…): IResult` overloads next to `class UAParser`), but
    /// the pair is only legal when the class is ambient. Otherwise the class
    /// gets TS2813 and *every* function declaration gets TS2814, whether or not
    /// it has a body — verified against tsgo 7.0.2 in both declaration orders.
    ///
    /// `existing` is the symbol's flags *before* this declaration merges in and
    /// `incoming` the new declaration's, so "the class half was already
    /// reported" is exactly `existing.function` — the class arm runs once, when
    /// the two kinds first meet.
    fn checkFunctionClassMerge(
        b: *Binder,
        sym: SymbolId,
        existing: SymbolFlags,
        incoming: SymbolFlags,
        name_tok: TokenIndex,
    ) Error!void {
        if (incoming.class) {
            // A class landing on an existing function set.
            if (!existing.function or !incoming.nonambient_class) return;
            try b.diag(.class_cannot_implement_overloads, name_tok);
            try b.diagMergedDecls(sym, .function_decl, .function_merge_needs_ambient_class);
            return;
        }
        // A function/method landing on an existing class.
        if (!existing.nonambient_class) return;
        try b.diag(.function_merge_needs_ambient_class, name_tok);
        // Only the first function of the merge reports the class half; a
        // second overload would otherwise repeat TS2813 on the same class.
        // (A symbol never has two class declarations — `ClassExcludes`
        // includes `Class` — so the single non-ambient one is the target.)
        if (!existing.function)
            try b.diagMergedDecls(sym, .class_decl, .class_cannot_implement_overloads);
    }

    /// Report `code` at the name of every declaration of `sym` whose node tag
    /// is `tag`. Used by the function/class merge check, which reports on
    /// declarations bound *before* the one that closed the merge.
    fn diagMergedDecls(b: *Binder, sym: SymbolId, tag: ast.Tag, code: Code) Error!void {
        var link = b.sym_decl_head.items[sym];
        while (link != 0) {
            const l = b.decl_links.items[link];
            link = l.next;
            const node = l.value;
            if (b.tree.nodeTag(node) != tag) continue;
            const d = b.tree.nodeData(node);
            const tok: TokenIndex = switch (tag) {
                .function_decl => b.tree.extraData(ast.FnProto, d.lhs).name_token,
                .class_decl => b.tree.extraData(ast.ClassData, d.lhs).name_token,
                else => 0,
            };
            if (tok != 0) try b.diag(code, tok);
        }
    }

    /// While binding the names of `export <decl>`, emit an export record
    /// for each name bound in the file scope.
    fn noteExport(b: *Binder, sym: SymbolId, atom: Atom, scope: ScopeId) Error!void {
        if (b.exporting_node == 0) return;
        // A member `export`ed inside a namespace is visible as `N.member`;
        // mark the flag so the checker exposes it, but emit no cross-file
        // ExportRec (namespaces are not module exports).
        if (scope != file_scope) {
            if (b.scope_kinds.items[scope] == .namespace) {
                b.sym_flags.items[sym].exported = true;
            }
            return;
        }
        if (b.sym_flags.items[sym].exported) return; // one record per symbol
        b.sym_flags.items[sym].exported = true;
        try b.export_recs.append(b.scratch, .{
            .exported = atom,
            .local = atom,
            .module = 0,
            .sym = sym,
            .node = b.exporting_node,
            .kind = .named,
            .type_only = false,
        });
    }

    // --- flow -----------------------------------------------------------------

    fn addFlowRaw(b: *Binder, tag: FlowTag, a: u32, bb: u32) Error!void {
        try b.flow_tags.append(b.scratch, tag);
        try b.flow_a.append(b.scratch, a);
        try b.flow_b.append(b.scratch, bb);
        try b.flow_scopes.append(b.scratch, b.cur_scope);
    }

    fn addFlow(b: *Binder, tag: FlowTag, antecedent: FlowId, node: Node) Error!FlowId {
        const id: FlowId = @intCast(b.flow_tags.items.len);
        try b.addFlowRaw(tag, antecedent, node);
        return id;
    }

    fn newPending(b: *Binder) Error!PendingId {
        const id: PendingId = @intCast(b.pendings.items.len);
        try b.pendings.append(b.scratch, .{});
        return id;
    }

    /// Add an antecedent to a pending join; unreachable and duplicate
    /// antecedents are skipped (tsc does the same).
    fn pendAdd(b: *Binder, pid: PendingId, flow: FlowId) Error!void {
        if (flow == no_flow or flow == unreachable_flow) return;
        const p = &b.pendings.items[pid];
        var l = p.head;
        while (l != 0) : (l = b.ante_links.items[l].next) {
            if (b.ante_links.items[l].value == flow) return;
        }
        const link: u32 = @intCast(b.ante_links.items.len);
        try b.ante_links.append(b.scratch, .{ .value = flow, .next = 0 });
        if (p.head == 0) p.head = link else b.ante_links.items[p.tail].next = link;
        p.tail = link;
        p.count += 1;
    }

    /// Turn a pending join into a flow id: 0 antecedents -> unreachable,
    /// 1 -> pass through, else a branch_label (a holds the pending id until
    /// seal() rewrites it into a flow_extra range).
    fn finishPending(b: *Binder, pid: PendingId) Error!FlowId {
        const p = b.pendings.items[pid];
        if (p.count == 0) return unreachable_flow;
        if (p.count == 1) return b.ante_links.items[p.head].value;
        return b.addFlow(.branch_label, pid, 0);
    }

    /// A loop head must exist before its back edges do, so it is created
    /// eagerly with its own pending antecedent list.
    fn newLoopLabel(b: *Binder) Error!FlowId {
        const pid = try b.newPending();
        return b.addFlow(.loop_label, pid, 0);
    }

    fn addLoopAntecedent(b: *Binder, label: FlowId, flow: FlowId) Error!void {
        try b.pendAdd(b.flow_a.items[label], flow);
    }

    fn attachFlow(b: *Binder, node: Node) Error!void {
        try b.flow_pairs.append(b.scratch, .{ .value = node, .next = b.cur_flow });
    }

    /// A literal element index — the only element access the checker tracks as
    /// a narrowing reference (`Checker.constIndexOf`). Deliberately coarser
    /// than that predicate (no range/sign test): an index the checker rejects
    /// simply leaves an unused flow entry.
    /// The syntactic half of tsc's `isNarrowableReference` element-access arm:
    /// an index that *could* denote a stable reference — a numeric literal
    /// (`arr[0]`) or a bare identifier (`map[key]`). The semantic half — is the
    /// identifier a `const` or a never-assigned local? — needs symbol
    /// resolution, which is not available here; the checker applies it in
    /// `stableIndexSymbol` and simply does not build a key when it fails, so an
    /// index that turns out to be unstable costs one unused flow entry.
    fn isNarrowableIndex(b: *const Binder, node: Node) bool {
        var n = node;
        while (b.nodeTag(n) == .paren_expr) n = b.tree.nodeData(n).lhs;
        return switch (b.nodeTag(n)) {
            .number_literal, .identifier => true,
            else => false,
        };
    }

    /// A bare identifier or a `a.b.c` chain of them — tsc's isDottedName,
    /// the gate for creating an assertion-candidate call flow node.
    fn isDottedName(b: *const Binder, node: Node) bool {
        return switch (b.nodeTag(node)) {
            .identifier, .this_expr, .super_expr => true,
            .paren_expr => b.isDottedName(b.tree.nodeData(node).lhs),
            .member_expr => b.isDottedName(b.tree.nodeData(node).lhs),
            else => false,
        };
    }

    // --- control-flow contexts (break/continue targets) -----------------------

    fn findBreakCtx(b: *Binder, label: Atom) ?*Ctx {
        var i = b.ctxs.items.len;
        while (i > b.ctx_base) {
            i -= 1;
            const c = &b.ctxs.items[i];
            if (label != 0) {
                if (c.label == label) return c;
            } else if (c.kind != .labeled) {
                return c;
            }
        }
        return null;
    }

    fn findContinueCtx(b: *Binder, label: Atom) ?*Ctx {
        var i = b.ctxs.items.len;
        var fallback: ?*Ctx = null;
        while (i > b.ctx_base) {
            i -= 1;
            const c = &b.ctxs.items[i];
            if (c.kind != .loop) continue;
            if (label == 0 or c.label == label) return c;
            if (fallback == null) fallback = c; // documented fallback
        }
        return fallback;
    }

    fn takePendingLabel(b: *Binder) Atom {
        const l = b.pending_label;
        b.pending_label = 0;
        return l;
    }

    // --- statements -------------------------------------------------------------

    fn bindStatement(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .block => {
                const saved = b.cur_scope;
                _ = try b.pushScope(.block, node);
                for (b.tree.nodeRange(node)) |stmt| try b.bindStatement(stmt);
                b.popScope(saved);
            },
            .var_decl_one, .var_decl => try b.bindVarDecl(node),
            .expr_stmt => {
                try b.bindExpandoAssignment(d.lhs);
                try b.bindExpr(d.lhs);
                // A call statement with a dotted-name callee may be an
                // assertion function; record a flow node so the checker can
                // narrow after it. Non-assertion calls pass through.
                const inner = d.lhs;
                switch (b.nodeTag(inner)) {
                    .call_expr, .call_expr_targs, .optional_call => {
                        if (b.isDottedName(b.tree.nodeData(inner).lhs)) {
                            b.cur_flow = try b.addFlow(.call_stmt, b.cur_flow, inner);
                        }
                    },
                    else => {},
                }
            },
            .empty_stmt, .debugger_stmt, .error_node, .unsupported, .omitted => {},

            .if_stmt => {
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindStatement(d.rhs);
                const after_then = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, cond.f);
                b.cur_flow = try b.finishPending(pid);
            },
            .if_else_stmt => {
                const e = b.tree.extraData(ast.IfElse, d.rhs);
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindStatement(e.then_stmt);
                const after_then = b.cur_flow;
                b.cur_flow = cond.f;
                try b.bindStatement(e.else_stmt);
                const after_else = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, after_else);
                b.cur_flow = try b.finishPending(pid);
            },
            .while_stmt => try b.bindWhile(node, d.lhs, d.rhs),
            .do_stmt => try b.bindDoWhile(node, d.lhs, d.rhs),
            .for_stmt => try b.bindFor(node),
            .for_in_stmt, .for_of_stmt => try b.bindForInOf(node),
            .switch_stmt => try b.bindSwitch(node),
            .try_stmt => try b.bindTry(node),
            .throw_stmt => {
                try b.bindExpr(d.lhs);
                b.cur_flow = unreachable_flow;
            },
            .return_stmt => {
                try b.bindExpr(d.lhs);
                // Inside a constructor, a `return` is an edge to the exit join
                // the initialization check queries (`ctor_return`); everywhere
                // else the flow simply ends.
                if (b.ctor_return) |pid| try b.pendAdd(pid, b.cur_flow);
                b.cur_flow = unreachable_flow;
            },
            .break_stmt => {
                const label: Atom = if (d.lhs != 0) try b.atomOfToken(d.lhs) else 0;
                if (b.findBreakCtx(label)) |ctx| try b.pendAdd(ctx.brk, b.cur_flow);
                b.cur_flow = unreachable_flow;
            },
            .continue_stmt => {
                const label: Atom = if (d.lhs != 0) try b.atomOfToken(d.lhs) else 0;
                if (b.findContinueCtx(label)) |ctx| try b.pendAdd(ctx.cont, b.cur_flow);
                b.cur_flow = unreachable_flow;
            },
            .labeled_stmt => try b.bindLabeled(node),

            .function_decl => try b.bindFunctionDecl(node),
            .class_decl => try b.bindClass(node, true),
            .interface_decl => try b.bindInterface(node),
            .type_alias => try b.bindTypeAlias(node),
            .enum_decl => try b.bindEnum(node),
            .namespace_decl => {
                const data = b.tree.extraData(ast.NamespaceData, b.tree.nodeData(node).lhs);
                if (data.flags & ast.Flags.global_aug != 0) {
                    try b.bindGlobalAugmentation(node);
                } else if (data.flags & ast.Flags.ambient_module != 0) {
                    try b.bindAmbientModule(node);
                } else {
                    try b.bindNamespace(node);
                }
            },
            // Only a *top-level* import/export makes the file a module; the same
            // syntax nested in a namespace / `declare module` block does not.
            .import_decl => {
                if (b.cur_scope == file_scope) b.saw_module_syntax = true;
                try b.bindImport(node);
            },
            .export_decl => {
                if (b.cur_scope == file_scope) b.saw_module_syntax = true;
                const saved = b.exporting_node;
                b.exporting_node = node;
                try b.bindStatement(d.lhs);
                b.exporting_node = saved;
            },
            .export_default => {
                if (b.cur_scope == file_scope) {
                    b.saw_module_syntax = true;
                    // `export default function f() {}` / `class C {}` is a
                    // declaration with a modifier, not tsc's ExportAssignment.
                    switch (b.nodeTag(d.lhs)) {
                        .function_decl, .class_decl => {},
                        else => b.saw_export_declaration = true,
                    }
                }
                try b.bindExportDefault(node);
            },
            .export_named => {
                if (b.cur_scope == file_scope) {
                    b.saw_module_syntax = true;
                    b.saw_export_declaration = true;
                }
                try b.bindExportNamed(node);
            },
            .export_all => {
                if (b.cur_scope == file_scope) {
                    b.saw_module_syntax = true;
                    b.saw_export_declaration = true;
                }
                try b.bindExportAll(node);
            },
            .export_assign => {
                if (b.cur_scope == file_scope) {
                    b.saw_module_syntax = true;
                    b.saw_export_declaration = true;
                }
                try b.bindExportAssign(node);
            },
            // `export as namespace X;` — record the UMD global name. It is NOT
            // treated as module-marking syntax: whether the file is a module is
            // already decided by its `export =` / import list, and flipping a
            // file's classification here would move far more than this.
            .export_as_ns => b.umd_name = try b.atomOfToken(d.lhs),
            .import_equals => try b.bindImportEquals(node),

            // Anything else in statement position (recovery leftovers) is
            // bound as an expression — keeps the binder total.
            else => try b.bindExpr(node),
        }
    }

    fn bindLabeled(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const label = try b.atomOfToken(b.tree.nodeMainToken(node));
        switch (b.nodeTag(d.lhs)) {
            // The loop/switch consumes the label into its own context.
            .while_stmt, .do_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => {
                b.pending_label = label;
                try b.bindStatement(d.lhs);
                b.pending_label = 0;
            },
            else => {
                const brk = try b.newPending();
                try b.ctxs.append(b.scratch, .{ .kind = .labeled, .label = label, .brk = brk });
                try b.bindStatement(d.lhs);
                _ = b.ctxs.pop();
                try b.pendAdd(brk, b.cur_flow);
                b.cur_flow = try b.finishPending(brk);
            },
        }
    }

    const LoopCtx = struct { brk: PendingId, cont: PendingId };

    fn pushLoopCtx(b: *Binder, label: Atom) Error!LoopCtx {
        const brk = try b.newPending();
        const cont = try b.newPending();
        try b.ctxs.append(b.scratch, .{
            .kind = .loop,
            .label = label,
            .brk = brk,
            .cont = cont,
        });
        return .{ .brk = brk, .cont = cont };
    }

    fn bindWhile(b: *Binder, node: Node, cond_node: Node, body: Node) Error!void {
        _ = node;
        // Capture the label before binding sub-expressions, so a label never
        // leaks into a loop nested inside the condition.
        const label = b.takePendingLabel();
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        const cond = try b.bindCondition(cond_node);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        b.cur_flow = cond.t;
        try b.bindStatement(body);
        _ = b.ctxs.pop();
        try b.pendAdd(cont, b.cur_flow);
        try b.addLoopAntecedent(loop, try b.finishPending(cont));
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
    }

    fn bindDoWhile(b: *Binder, node: Node, body: Node, cond_node: Node) Error!void {
        _ = node;
        const label = b.takePendingLabel();
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        try b.bindStatement(body);
        _ = b.ctxs.pop();
        // continue targets the condition check.
        try b.pendAdd(cont, b.cur_flow);
        b.cur_flow = try b.finishPending(cont);
        const cond = try b.bindCondition(cond_node);
        try b.addLoopAntecedent(loop, cond.t);
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
    }

    fn bindFor(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.For, d.lhs);
        const label = b.takePendingLabel();
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.for_head, node);

        if (e.init != 0) {
            switch (b.nodeTag(e.init)) {
                .var_decl_one, .var_decl => try b.bindVarDecl(e.init),
                else => try b.bindExpr(e.init),
            }
        }
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        var cond: CondFlows = .{ .t = loop, .f = unreachable_flow }; // for(;;)
        if (e.cond != 0) cond = try b.bindCondition(e.cond);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        b.cur_flow = cond.t;
        try b.bindStatement(d.rhs);
        _ = b.ctxs.pop();
        // continue joins before the update expression runs.
        try b.pendAdd(cont, b.cur_flow);
        b.cur_flow = try b.finishPending(cont);
        if (e.update != 0) try b.bindExpr(e.update);
        try b.addLoopAntecedent(loop, b.cur_flow);
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
        b.popScope(saved_scope);
    }

    fn bindForInOf(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.ForInOf, d.lhs);
        const label = b.takePendingLabel();
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.for_head, node);

        try b.bindExpr(e.right); // evaluated once, before the loop
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        // The per-iteration element binding is an assignment for narrowing.
        switch (b.nodeTag(e.left)) {
            .var_decl_one, .var_decl => try b.bindVarDecl(e.left),
            else => try b.bindExpr(e.left),
        }
        b.cur_flow = try b.addFlow(.assign, b.cur_flow, e.left);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        try b.bindStatement(d.rhs);
        _ = b.ctxs.pop();
        try b.pendAdd(cont, b.cur_flow);
        try b.addLoopAntecedent(loop, try b.finishPending(cont));
        // Loop exit: iteration may not run at all -> exit from the loop head.
        try b.pendAdd(brk, loop);
        b.cur_flow = try b.finishPending(brk);
        b.popScope(saved_scope);
    }

    fn bindSwitch(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const label = b.takePendingLabel();
        try b.bindExpr(d.lhs);
        const pre = b.cur_flow;
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.block, node); // one case-block scope for all clauses

        const brk = try b.newPending();
        try b.ctxs.append(b.scratch, .{
            .kind = .switch_blk,
            .label = label,
            .brk = brk,
        });
        var has_default = false;
        var prev: FlowId = unreachable_flow; // fallthrough from previous clause
        const r = b.tree.extraData(ast.SubRange, d.rhs);
        for (b.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node) continue;
            const ctag = b.nodeTag(clause);
            if (ctag == .default_clause) has_default = true;
            const cd = b.tree.nodeData(clause);
            if (ctag == .case_clause and cd.lhs != 0) {
                b.cur_flow = pre;
                try b.bindExpr(cd.lhs); // case test expression
            }
            const clause_flow = try b.addFlow(.switch_clause, pre, clause);
            const pid = try b.newPending();
            try b.pendAdd(pid, prev); // fallthrough (skipped if unreachable)
            try b.pendAdd(pid, clause_flow);
            b.cur_flow = try b.finishPending(pid);
            if (ctag == .case_clause or ctag == .default_clause) {
                const cr = b.tree.extraData(ast.SubRange, cd.rhs);
                for (b.tree.extraRange(cr.start, cr.end)) |stmt| try b.bindStatement(stmt);
            }
            prev = b.cur_flow;
        }
        _ = b.ctxs.pop();
        try b.pendAdd(brk, prev);
        b.popScope(saved_scope);
        // No clause matched. Kept as its own flow node rather than the raw
        // pre-switch edge so the checker can drop it when the switch is
        // exhaustive over a literal-union discriminant — the binder cannot
        // know that, it is a type question. Created after the case-block scope
        // is popped: the discriminant the checker re-reads through it lives in
        // the enclosing scope, not the case block.
        if (!has_default) try b.pendAdd(brk, try b.addFlow(.switch_no_match, pre, node));
        b.cur_flow = try b.finishPending(brk);
    }

    fn bindTry(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.Try, d.rhs);
        const pre = b.cur_flow;
        try b.bindStatement(d.lhs); // try block
        const after_try = b.cur_flow;

        var after_catch: FlowId = unreachable_flow;
        if (e.catch_clause != 0) {
            // Conservative: the catch body starts from the pre-try state
            // (any prefix of the try block may have run).
            b.cur_flow = pre;
            const cd = b.tree.nodeData(e.catch_clause);
            const saved_scope = b.cur_scope;
            _ = try b.pushScope(.catch_clause, e.catch_clause);
            if (cd.lhs != 0) try b.bindCatchBinding(cd.lhs);
            // The catch body's statements bind directly in the catch scope so
            // `catch (e) { let e; }` is caught (TS2492).
            if (cd.rhs != 0 and b.nodeTag(cd.rhs) == .block) {
                for (b.tree.nodeRange(cd.rhs)) |stmt| try b.bindStatement(stmt);
            } else {
                try b.bindStatement(cd.rhs);
            }
            b.popScope(saved_scope);
            after_catch = b.cur_flow;
        }

        const pid = try b.newPending();
        try b.pendAdd(pid, after_try);
        try b.pendAdd(pid, after_catch);
        var joined = try b.finishPending(pid);
        if (e.finally_block != 0) {
            // Conservative: the finally body may also run mid-try.
            const fp = try b.newPending();
            try b.pendAdd(fp, pre);
            try b.pendAdd(fp, joined);
            b.cur_flow = try b.finishPending(fp);
            try b.bindStatement(e.finally_block);
            joined = b.cur_flow;
        }
        b.cur_flow = joined;
    }

    fn bindCatchBinding(b: *Binder, binding: Node) Error!void {
        switch (b.nodeTag(binding)) {
            .declarator_full => {
                const d = b.tree.nodeData(binding);
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, .catch_param, binding);
                try b.bindType(e.type_ann);
            },
            .declarator => {
                try b.bindPattern(b.tree.nodeData(binding).lhs, .catch_param, binding);
            },
            else => try b.bindPattern(binding, .catch_param, binding),
        }
    }

    // --- declarations ------------------------------------------------------------

    fn declKindOfVar(b: *Binder, node: Node) DeclKind {
        return switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
            .keyword_const => .const_decl,
            .keyword_let => .let_decl,
            else => .var_decl,
        };
    }

    fn bindVarDecl(b: *Binder, node: Node) Error!void {
        const kind = b.declKindOfVar(node);
        const d = b.tree.nodeData(node);
        if (b.nodeTag(node) == .var_decl_one) {
            try b.bindDeclarator(d.lhs, kind);
        } else {
            for (b.tree.nodeRange(node)) |decl| {
                if (decl != null_node) try b.bindDeclarator(decl, kind);
            }
        }
    }

    fn bindDeclarator(b: *Binder, node: Node, kind: DeclKind) Error!void {
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .declarator => try b.bindPattern(d.lhs, kind, node),
            .declarator_init => {
                try b.bindPattern(d.lhs, kind, node);
                try b.bindExpr(d.rhs);
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
            },
            .declarator_full => {
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, kind, node);
                try b.bindType(e.type_ann);
                if (e.init != 0) {
                    try b.bindExpr(e.init);
                    b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                }
            },
            else => {}, // recovery leftovers
        }
    }

    /// Declare all names bound by a pattern. `var` names go to the nearest
    /// function/file scope; everything else binds in the current scope.
    fn bindPattern(b: *Binder, node: Node, kind: DeclKind, decl_node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, .{});
            },
            .array_pattern, .object_pattern => {
                for (b.tree.nodeRange(node)) |el| try b.bindPattern(el, kind, decl_node);
            },
            .binding_default => {
                try b.bindPattern(d.lhs, kind, decl_node);
                try b.bindExpr(d.rhs);
            },
            .rest_element => try b.bindPattern(d.lhs, kind, decl_node),
            .binding_property => {
                if (d.lhs != 0) {
                    // `key: target` — the key is a property name, not a binding.
                    try b.bindPattern(d.lhs, kind, decl_node);
                } else {
                    // Shorthand `{ a }` (possibly with a default) binds the key.
                    const tok = b.tree.nodeMainToken(node);
                    const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                    _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, .{});
                }
                if (d.rhs != 0) try b.bindExpr(d.rhs); // default initializer
            },
            .binding_property_computed => {
                // `[expr]: target` — the key is an ordinary expression read in
                // the enclosing scope; only the target binds.
                if (d.lhs != 0) try b.bindExpr(d.lhs);
                if (d.rhs != 0) try b.bindPattern(d.rhs, kind, decl_node);
            },
            .omitted, .error_node, .unsupported => {},
            else => {}, // not a pattern (recovery); no bindings
        }
    }

    fn bindFunctionDecl(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const proto = b.tree.extraData(ast.FnProto, d.lhs);
        if (proto.name_token != 0) {
            const atom = try b.atomOfToken(proto.name_token);
            const flags: SymbolFlags = .{ .has_impl = d.rhs != 0 };
            _ = try b.declare(b.cur_scope, atom, .function, node, proto.name_token, flags);
        }
        try b.bindFunctionLike(node, d.lhs, d.rhs, false);
    }

    /// Shared by function declarations/expressions, arrows, methods, and
    /// function types. Creates the function scope (params + body top-level
    /// share it, so `function f(x) { let x }` clashes) and a fresh `start`
    /// flow for the body. `is_ctor` adds parameter properties.
    fn bindFunctionLike(b: *Binder, node: Node, proto_idx: u32, body: Node, is_ctor: bool) Error!void {
        const proto = b.tree.extraData(ast.FnProto, proto_idx);
        // Flow node in effect where this function expression appears — its
        // "definition point". Recorded as the body-start's antecedent so the
        // checker can continue flow analysis into the enclosing function for a
        // constant reference captured by this closure (tsc: FlowStart.node).
        const outer_flow = b.cur_flow;
        const saved = b.saveState();
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;

        const s = try b.pushScope(.function, node);
        b.var_scope = s;
        b.ctx_base = b.ctxs.items.len;
        // tsc's `currentReturnTarget`: a CONSTRUCTOR gets a return-edge join so
        // `strictPropertyInitialization` can ask what every path out of it left
        // assigned (`checkPropertyInit`). Cleared for every other function-like
        // so a nested `return` never joins an enclosing constructor's exit.
        const ret_pid: ?PendingId = if (is_ctor and body != 0) try b.newPending() else null;
        b.ctor_return = ret_pid;

        try b.bindTypeParams(proto.tp_start, proto.tp_end);
        for (b.tree.extraRange(proto.params_start, proto.params_end)) |param| {
            try b.bindParam(param, is_ctor);
        }
        try b.bindType(proto.return_type);

        if (body != 0) {
            b.cur_flow = try b.addFlow(.start, outer_flow, node);
            if (b.nodeTag(body) == .block) {
                // Body statements bind directly in the function scope.
                for (b.tree.nodeRange(body)) |stmt| try b.bindStatement(stmt);
            } else {
                try b.bindExpr(body); // arrow expression body
            }
            if (ret_pid) |pid| {
                // The fall-off-the-end edge, then the join itself, recorded
                // against the constructor node — the one node/flow pair whose
                // key is the declaration rather than a reference, which is why
                // no `attachFlow` caller can collide with it. A body that ends
                // unreachable with no `return` leaves the join empty, and
                // `finishPending` answers `unreachable_flow`: nothing flows out
                // of `constructor() { throw … }`, so it initializes everything.
                try b.pendAdd(pid, b.cur_flow);
                try b.flow_pairs.append(b.scratch, .{ .value = node, .next = try b.finishPending(pid) });
            }
        }
        // A NAMED function expression can call itself: tsc's `resolveName`
        // stops at the `FunctionExpression` whose own name matches, so the
        // name is visible in the body and nowhere else. Declared after the
        // params/body so a parameter or local of the same name keeps the slot
        // (it shadows the self-reference, as in tsc). Bluesky's
        // `(function tick(last) { … frame = tick(next) … })(start)` needs it.
        //
        // Only a REAL `function name(…)` expression, which is why the `function`
        // keyword is checked rather than `proto.name_token`: an object-literal
        // method shorthand (`{ get(k) { … } }`) is also a `function_expr`, with
        // its KEY as the name token, and binding that would shadow a same-named
        // import inside the method body (bluesky's `get(key) { return get(key,
        // store) }` over `idb-keyval`).
        if (b.nodeTag(node) == .function_expr and proto.name_token != 0 and
            b.tree.tokens.tag(b.tree.nodeMainToken(node)) == .keyword_function)
        {
            const self_atom = try b.atomOfToken(proto.name_token);
            if (b.members.get(memberKey(s, self_atom)) == null) {
                _ = try b.declare(s, self_atom, .function, node, proto.name_token, .{ .has_impl = body != 0 });
            }
        }
        b.restoreState(saved);
    }

    /// Does a `const` modifier precede the type parameter named by `name_tok`?
    /// The parser consumes `const`/`in`/`out` without storing them, so the
    /// answer lives in the token stream — and only those three tags can occupy
    /// the slots between the opening `<`/`,` and the name, so the walk cannot
    /// run past its own parameter. Same readback `declaredVarianceOfTypeParam`
    /// does for the variance annotations.
    fn constTypeParam(b: *Binder, name_tok: TokenIndex) bool {
        var tok = name_tok;
        while (tok > 0) {
            tok -= 1;
            switch (b.tree.tokens.tag(tok)) {
                .keyword_const => return true,
                .keyword_in, .keyword_out => {},
                else => return false,
            }
        }
        return false;
    }

    fn bindTypeParams(b: *Binder, start: u32, end: u32) Error!void {
        for (b.tree.extraRange(start, end)) |tp| {
            if (tp == null_node or b.nodeTag(tp) != .type_param) continue;
            const tok = b.tree.nodeMainToken(tp);
            _ = try b.declare(b.cur_scope, try b.atomOfToken(tok), .type_param, tp, tok, .{
                .const_type_param = constTypeParam(b, tok),
            });
            const d = b.tree.nodeData(tp);
            try b.bindType(d.lhs); // constraint
            try b.bindType(d.rhs); // default
        }
    }

    fn bindParam(b: *Binder, node: Node, is_ctor: bool) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .param => {
                try b.bindPattern(d.lhs, .param, node);
                try b.bindType(d.rhs);
            },
            .param_full => {
                const e = b.tree.extraData(ast.ParamFull, d.rhs);
                try b.bindPattern(d.lhs, .param, node);
                try b.bindType(e.type_ann);
                try b.bindExpr(e.init);
                // Constructor parameter property: also a class member.
                const prop_mask = ast.Flags.public | ast.Flags.private |
                    ast.Flags.protected | ast.Flags.readonly;
                if (is_ctor and e.flags & prop_mask != 0 and
                    b.nodeTag(d.lhs) == .identifier)
                {
                    const class_scope = b.scope_parents.items[b.cur_scope];
                    if (b.memberScopeOfClassScope(class_scope)) |ms| {
                        const tok = b.tree.nodeMainToken(d.lhs);
                        _ = try b.declare(ms, try b.atomOfToken(tok), .property, node, tok, .{
                            .readonly_member = e.flags & ast.Flags.readonly != 0,
                            .non_public = e.flags & nonpublic_mask != 0,
                        });
                    }
                }
            },
            else => try b.bindPattern(node, .param, node),
        }
    }

    /// Find the class_members scope hanging off a class scope.
    fn memberScopeOfClassScope(b: *Binder, class_scope: ScopeId) ?ScopeId {
        var s: ScopeId = class_scope + 1;
        while (s < b.scope_parents.items.len) : (s += 1) {
            if (b.scope_parents.items[s] == class_scope and
                b.scope_kinds.items[s] == .class_members) return s;
        }
        return null;
    }

    fn bindClass(b: *Binder, node: Node, declare_name: bool) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ClassData, d.lhs);
        var class_sym: SymbolId = no_symbol;
        if (declare_name and data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            // Ambient-ness decides whether a merge with function declarations
            // of the same name is legal (see `checkFunctionClassMerge`): a
            // `.d.ts`, a `declare namespace` body, or an explicit `declare`.
            const is_ambient = b.ambient or (data.flags & ast.Flags.declare) != 0;
            class_sym = try b.declare(b.cur_scope, atom, .class, node, data.name_token, .{
                .nonambient_class = !is_ambient,
            });
        }
        const saved = b.saveState();
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;

        const cs = try b.pushScope(.class, node);
        // A class EXPRESSION's name is not declared in the enclosing scope,
        // but it IS visible inside its own body — `var x = class C { m(c: C)
        // {} }` names the class (tsc gives the ClassExpression a local
        // symbol in its own scope). Declared here, in the class scope, so it
        // shadows nothing outside.
        if (!declare_name and data.name_token != 0) {
            _ = try b.declare(cs, try b.atomOfToken(data.name_token), .class, node, data.name_token, .{
                .nonambient_class = !b.ambient,
            });
        }
        try b.bindTypeParams(data.tp_start, data.tp_end);

        if (data.extends != 0) try b.bindHeritage(data.extends, true);
        for (b.tree.extraRange(data.impl_start, data.impl_end)) |h| {
            if (h != null_node) try b.bindHeritage(h, false);
        }

        const ms = try b.newScope(.class_members, node, cs);
        const ss = try b.newScope(.class_statics, node, cs);
        if (class_sym != no_symbol) {
            try b.member_scopes.put(b.scratch, class_sym, ms);
            try b.static_scopes.put(b.scratch, class_sym, ss);
        }
        const saved_block = b.cur_block;
        b.cur_block = node;
        defer b.cur_block = saved_block;

        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node) continue;
            const md = b.tree.nodeData(member);
            switch (b.nodeTag(member)) {
                .class_field => {
                    const f = b.tree.extraData(ast.Field, md.lhs);
                    const is_static = f.flags & ast.Flags.static != 0;
                    const tok = b.tree.nodeMainToken(member);
                    _ = try b.declare(if (is_static) ss else ms, try b.memberNameKey(tok, f.flags), .property, member, tok, .{
                        .static_member = is_static,
                        .optional_member = f.flags & ast.Flags.optional != 0,
                        .readonly_member = f.flags & ast.Flags.readonly != 0,
                        .non_public = f.flags & nonpublic_mask != 0,
                    });
                    try b.bindType(f.type_ann);
                    try b.bindExpr(f.init);
                },
                .class_method => {
                    const proto = b.tree.extraData(ast.FnProto, md.lhs);
                    const is_static = proto.flags & ast.Flags.static != 0;
                    const is_get = proto.flags & ast.Flags.get != 0;
                    const is_set = proto.flags & ast.Flags.set != 0;
                    const tok = b.tree.nodeMainToken(member);
                    const atom = try b.memberNameKey(tok, proto.flags);
                    const kind: DeclKind = if (is_get) .getter else if (is_set) .setter else .method;
                    _ = try b.declare(if (is_static) ss else ms, atom, kind, member, tok, .{
                        .static_member = is_static,
                        .has_impl = md.rhs != 0 and !is_get and !is_set,
                        .non_public = proto.flags & nonpublic_mask != 0,
                    });
                    const is_ctor = b.tree.tokens.tag(tok) == .keyword_constructor and !is_static;
                    try b.bindFunctionLike(member, md.lhs, md.rhs, is_ctor);
                },
                .decorator => try b.bindExpr(md.lhs),
                .error_node, .unsupported => {},
                else => {},
            }
        }
        b.restoreState(saved);
    }

    /// `extends`/`implements` entry: `extends` is a value read (with flow),
    /// `implements` is a type reference; type arguments are types either way.
    fn bindHeritage(b: *Binder, node: Node, is_value: bool) Error!void {
        const d = b.tree.nodeData(node);
        if (is_value) {
            try b.bindExpr(d.lhs);
        } else {
            try b.bindTypeName(d.lhs);
        }
        if (d.rhs != 0) {
            const r = b.tree.extraData(ast.SubRange, d.rhs);
            for (b.tree.extraRange(r.start, r.end)) |arg| try b.bindType(arg);
        }
    }

    /// An enum declares one symbol (a value and a type) plus a scope holding
    /// its MEMBERS. The member types still come from the value object the
    /// checker materializes off the AST; what the scope adds is tsc's
    /// `resolveName` case for `SyntaxKind.EnumDeclaration`, which consults
    /// the enum's own table before any enclosing one — so `enum E { A = 1,
    /// B = A }` names the member (and shadows an outer `A`), and two members
    /// of one name are TS2300 at both spellings.
    ///
    /// Every block of a merged `enum E` shares one scope, keyed by the enum
    /// symbol exactly as `bindNamespace` keys namespace bodies: a second
    /// block sees the first block's members (`enum E { A0 = 100 } enum E {
    /// … = A0 }`).
    fn bindEnum(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.EnumData, d.lhs);
        var sym: SymbolId = no_symbol;
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            sym = try b.declare(b.cur_scope, atom, .enum_decl, node, data.name_token, .{});
        }
        var e_scope: ScopeId = 0;
        if (sym != no_symbol) {
            if (b.enum_scopes.get(sym)) |existing| {
                e_scope = existing;
            } else {
                e_scope = try b.newScope(.enum_body, node, b.cur_scope);
                try b.enum_scopes.put(b.scratch, sym, e_scope);
            }
        } else {
            e_scope = try b.newScope(.enum_body, node, b.cur_scope);
        }

        // Only the lexical scope changes: an enum body declares no variables
        // and starts no flow of its own, so `var_scope`/`cur_flow` stay put
        // and a member initializer keeps flowing in the enclosing container.
        const saved_scope = b.cur_scope;
        b.cur_scope = e_scope;
        defer b.cur_scope = saved_scope;
        // Members are declared in TWO passes so a member initializer can name
        // a member declared after it — tsc's table is complete before any
        // initializer is evaluated, and `enum E { A = B, B = 1 }` really does
        // resolve `B` (the *value* is the separate `computeConstantValue`
        // question, which reports its own TS2651/TS18033).
        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node or b.nodeTag(member) != .enum_member) continue;
            const name_tok = b.tree.nodeMainToken(member);
            const atom = try b.memberAtom(name_tok);
            _ = try b.declare(e_scope, atom, .enum_member, member, name_tok, .{});
        }
        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node or b.nodeTag(member) != .enum_member) continue;
            try b.bindExpr(b.tree.nodeData(member).lhs); // optional initializer
        }
    }

    /// tsc's `getModuleInstanceState`, reduced to the yes/no the excludes
    /// check needs: does this `namespace`/`module` block emit a runtime
    /// object? A body of interfaces, type aliases, `const enum`s, side-effect-
    /// free imports and other non-instantiated namespaces does not; anything
    /// else (a `var`, `function`, `class`, non-const `enum`, statement) does.
    /// Read straight off the AST — no scopes, no symbols — so the answer is
    /// the same whichever of `const X` / `namespace X` the binder reaches
    /// first. `preserveConstEnums`/`isolatedModules` are off, matching the
    /// oracle's defaults, so a const-enum-only body counts as type-only.
    fn instantiated(b: *Binder, node: Node) bool {
        const data = b.tree.extraData(ast.NamespaceData, b.tree.nodeData(node).lhs);
        for (b.tree.extraRange(data.body_start, data.body_end)) |raw| {
            if (raw == null_node) continue;
            var stmt = raw;
            // `export interface I {}` is still just an interface.
            while (b.nodeTag(stmt) == .export_decl) {
                stmt = b.tree.nodeData(stmt).lhs;
                if (stmt == null_node) return true;
            }
            switch (b.nodeTag(stmt)) {
                .interface_decl, .type_alias => {},
                // An import binds a name but emits nothing on its own; tsc
                // only calls it instantiating when it is re-`export`ed (the
                // `export_decl` unwrapping above already made that visible).
                .import_decl, .import_equals => {},
                .enum_decl => {
                    const e = b.tree.extraData(ast.EnumData, b.tree.nodeData(stmt).lhs);
                    if (e.flags & ast.Flags.const_enum == 0) return true;
                },
                .namespace_decl => if (b.instantiated(stmt)) return true,
                else => return true,
            }
        }
        return false;
    }

    /// A namespace declares one symbol (both a value and a type container).
    /// Its body is a scope; `export`ed members are visible as `N.member`.
    /// Multiple `namespace N {}` blocks in one file (and namespace + function
    /// /class/enum/interface merges) share a single members scope, reused via
    /// `member_scopes` — the same one-scope pattern interface merging uses.
    fn bindNamespace(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.NamespaceData, d.lhs);
        var sym: SymbolId = no_symbol;
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            // Declared (and possibly marked exported by an outer `export`)
            // in the enclosing scope before the body clears exporting_node.
            // The instantiated/type-only distinction is read off the AST, as
            // tsc's `getModuleInstanceState` does, so it is available for the
            // excludes check no matter which of `const X` / `namespace X`
            // comes first in the file.
            // The flag is an AND over the merged blocks, so it survives only
            // while *every* block of the name is type-only; `declare` merges
            // flags by OR, which is the wrong fold for it.
            const prev_inst_ns = if (b.members.get(memberKey(b.cur_scope, atom))) |p|
                b.sym_flags.items[p].namespace_decl and !b.sym_flags.items[p].ns_uninstantiated
            else
                false;
            const inst = b.instantiated(node);
            const kind: DeclKind = if (inst) .namespace else .namespace_type;
            sym = try b.declare(b.cur_scope, atom, kind, node, data.name_token, .{});
            b.sym_flags.items[sym].ns_uninstantiated = !inst and !prev_inst_ns;
        }

        const saved = b.saveState();
        // In an ambient namespace (`declare namespace`, or one nested inside
        // an ambient namespace) every member is implicitly exported: bind the
        // body with `exporting_node` pinned to the namespace so each member's
        // `noteExport` marks it visible as `N.member`. Otherwise members need
        // an explicit `export` (so plain `namespace` members stay private).
        const was_ambient = b.ambient;
        const is_ambient = was_ambient or (data.flags & ast.Flags.declare != 0);
        b.ambient = is_ambient;
        defer b.ambient = was_ambient;
        const clear_export = b.exporting_node;
        b.exporting_node = if (is_ambient) node else 0;
        defer b.exporting_node = clear_export;

        // Merged blocks bind into one shared namespace scope.
        var ns_scope: ScopeId = 0;
        if (sym != no_symbol) {
            if (b.namespace_scopes.get(sym)) |existing| {
                ns_scope = existing;
            } else {
                ns_scope = try b.newScope(.namespace, node, b.cur_scope);
                try b.namespace_scopes.put(b.scratch, sym, ns_scope);
            }
        } else {
            ns_scope = try b.newScope(.namespace, node, b.cur_scope);
        }

        try b.scope_stack.append(b.scratch, ns_scope);
        b.cur_scope = ns_scope;
        b.var_scope = ns_scope; // a namespace is a var container
        b.ctx_base = b.ctxs.items.len;
        b.cur_flow = try b.addFlow(.start, no_flow, node);

        for (b.tree.extraRange(data.body_start, data.body_end)) |stmt| {
            try b.bindStatement(stmt);
        }
        b.restoreState(saved);
    }

    /// `declare global { … }`. Binds the block's declarations into a scope
    /// shared by every global block with the same enclosing container (so
    /// blocks merge, and the linker harvests one segment per container). The
    /// scope's PARENT is that container, so a reference inside the block sees
    /// the enclosing `declare module` body's locals — tsc resolves names by
    /// walking the node parent chain, and a `global { … }` node's parent is
    /// the module declaration, not the source file. No `global` symbol is
    /// declared: the members are contributions to the *program* global table,
    /// resolved cross-file at link time. The body is an ambient context.
    fn bindGlobalAugmentation(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.NamespaceData, d.lhs);

        var gs: ScopeId = 0;
        for (b.global_scopes.items) |cand| {
            if (b.scope_parents.items[cand] == b.cur_scope) {
                gs = cand;
                break;
            }
        }
        if (gs == 0) {
            gs = try b.newScope(.namespace, node, b.cur_scope);
            try b.global_scopes.append(b.scratch, gs);
        }

        const saved = b.saveState();
        // Ambient body (declarations may omit initializers/bodies), but members
        // are program globals — not `N.member` namespace exports — so
        // `exporting_node` stays clear.
        const was_ambient = b.ambient;
        b.ambient = true;
        defer b.ambient = was_ambient;
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;

        try b.scope_stack.append(b.scratch, gs);
        b.cur_scope = gs;
        b.var_scope = gs;
        b.ctx_base = b.ctxs.items.len;
        b.cur_flow = try b.addFlow(.start, no_flow, node);

        for (b.tree.extraRange(data.body_start, data.body_end)) |stmt| {
            if (stmt != null_node) try b.bindStatement(stmt);
        }
        b.restoreState(saved);
    }

    /// `declare module "spec" { … }`. Binds the body into a fresh scope
    /// (ambient context, so declarations may omit bodies/initializers) and
    /// records `(spec, scope)`. Members need explicit `export` to be module
    /// exports — like an ambient namespace body, `exporting_node` is set per
    /// nested `export` statement, not pinned.
    fn bindAmbientModule(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.NamespaceData, d.lhs);
        const spec = try b.atomOf(stripModuleQuotes(b.tokenText(data.name_token)));
        const ms = try b.newScope(.namespace, node, file_scope);
        const export_start: u32 = @intCast(b.export_recs.items.len);

        const saved = b.saveState();
        const was_ambient = b.ambient;
        b.ambient = true;
        defer b.ambient = was_ambient;
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;
        const saved_mod_scope = b.ambient_mod_scope;
        b.ambient_mod_scope = ms;
        defer b.ambient_mod_scope = saved_mod_scope;

        try b.scope_stack.append(b.scratch, ms);
        b.cur_scope = ms;
        b.var_scope = ms;
        b.ctx_base = b.ctxs.items.len;
        b.cur_flow = try b.addFlow(.start, no_flow, node);

        for (b.tree.extraRange(data.body_start, data.body_end)) |stmt| {
            if (stmt != null_node) try b.bindStatement(stmt);
        }
        b.restoreState(saved);
        try b.ambient_mods.append(b.scratch, .{
            .spec = spec,
            .scope = ms,
            .export_start = export_start,
            .export_end = @intCast(b.export_recs.items.len),
        });
    }

    fn bindInterface(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.InterfaceData, d.lhs);
        var sym: SymbolId = no_symbol;
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            sym = try b.declare(b.cur_scope, atom, .interface, node, data.name_token, .{});
        }
        const saved_scope = b.cur_scope;
        const saved_block = b.cur_block;
        b.cur_block = node;
        defer b.cur_block = saved_block;

        // Each block gets its OWN type-parameter scope, while merged blocks
        // share ONE members scope — which is parented to the FIRST block's.
        // A later block's type parameters are therefore off the members'
        // parent chain, and `interface A<T> { x: T } interface A<U> { y: U }`
        // reports a spurious "Cannot find name 'U'". tsc reports TS2428
        // ("All declarations of 'A' must have identical type parameters")
        // there and never resolves `U` at all, so the two agree on nothing
        // but the code. Sharing this scope the way the members scope is
        // shared was tried and reverted: it makes every block's parameters
        // one symbol, which loses the per-block DEFAULTS that
        // `test/conformance/instantiation/040_merged_interface_type_param_defaults.ts`
        // pins (real `@types/node` depends on them). The fix is TS2428 plus a
        // per-block parameter list, not one scope.
        const is = try b.pushScope(.interface, node);
        try b.bindTypeParams(data.tp_start, data.tp_end);
        for (b.tree.extraRange(data.extends_start, data.extends_end)) |h| {
            if (h != null_node) try b.bindHeritage(h, false);
        }

        // Interface-interface merge within a file shares one members scope.
        var ms: ScopeId = 0;
        if (sym != no_symbol) {
            if (b.member_scopes.get(sym)) |existing| {
                ms = existing;
            } else {
                ms = try b.newScope(.interface_members, node, is);
                try b.member_scopes.put(b.scratch, sym, ms);
            }
        } else {
            ms = try b.newScope(.interface_members, node, is);
        }

        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node) continue;
            try b.bindTypeMember(member, ms);
        }
        b.popScope(saved_scope);
    }

    /// A member of an interface or object-type literal.
    fn bindTypeMember(b: *Binder, member: Node, ms: ScopeId) Error!void {
        const md = b.tree.nodeData(member);
        switch (b.nodeTag(member)) {
            .property_signature => {
                const tok = b.tree.nodeMainToken(member);
                _ = try b.declare(ms, try b.memberNameKey(tok, md.rhs), .property, member, tok, .{
                    .optional_member = md.rhs & ast.Flags.optional != 0,
                    .readonly_member = md.rhs & ast.Flags.readonly != 0,
                });
                try b.bindType(md.lhs);
            },
            .method_signature => {
                const tok = b.tree.nodeMainToken(member);
                const is_get = md.rhs & ast.Flags.get != 0;
                const is_set = md.rhs & ast.Flags.set != 0;
                const kind: DeclKind = if (is_get) .getter else if (is_set) .setter else .method;
                _ = try b.declare(ms, try b.memberNameKey(tok, md.rhs), kind, member, tok, .{});
                try b.bindFunctionType(member, md.lhs);
            },
            .index_signature => {
                const e = b.tree.extraData(ast.IndexSig, md.lhs);
                try b.bindType(e.key_type);
                try b.bindType(e.value_type);
            },
            // Call / construct signatures: unnamed members carrying a
            // proto scope, no declared symbol.
            .call_signature, .construct_signature => try b.bindFunctionType(member, md.lhs),
            .error_node, .unsupported => {},
            else => {},
        }
    }

    fn bindTypeAlias(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.TypeAlias, d.lhs);
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            _ = try b.declare(b.cur_scope, atom, .type_alias, node, data.name_token, .{});
        }
        if (data.tp_start != data.tp_end) {
            const saved_scope = b.cur_scope;
            _ = try b.pushScope(.type_alias, node);
            try b.bindTypeParams(data.tp_start, data.tp_end);
            try b.bindType(d.rhs);
            b.popScope(saved_scope);
        } else {
            try b.bindType(d.rhs);
        }
    }

    // --- imports & exports ----------------------------------------------------

    fn bindImport(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ImportData, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const decl_type_only = data.flags & ast.Flags.type_only != 0;
        var any_binding = false;

        if (data.default_name_token != 0) {
            any_binding = true;
            const atom = try b.atomOfToken(data.default_name_token);
            const kind: DeclKind = if (decl_type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, atom, kind, node, data.default_name_token, .{});
            try b.import_recs.append(b.scratch, .{
                .local = atom,
                .imported = try b.atomOf("default"),
                .module = module,
                .node = node,
                .kind = .default,
                .type_only = decl_type_only,
                .scope = b.cur_scope,
            });
        }
        if (data.ns_name_token != 0) {
            any_binding = true;
            const atom = try b.atomOfToken(data.ns_name_token);
            const kind: DeclKind = if (decl_type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, atom, kind, node, data.ns_name_token, .{});
            try b.import_recs.append(b.scratch, .{
                .local = atom,
                .imported = try b.atomOf("*"),
                .module = module,
                .node = node,
                .kind = .namespace,
                .type_only = decl_type_only,
                .scope = b.cur_scope,
            });
        }
        for (b.tree.extraRange(data.spec_start, data.spec_end)) |spec| {
            if (spec == null_node or b.nodeTag(spec) != .import_specifier) continue;
            any_binding = true;
            const sd = b.tree.nodeData(spec);
            const imported_tok = b.tree.nodeMainToken(spec);
            const local_tok = if (sd.lhs != 0) sd.lhs else imported_tok;
            const type_only = decl_type_only or sd.rhs & ast.Flags.type_only != 0;
            const imported = try b.memberAtom(imported_tok);
            const local = try b.atomOfToken(local_tok);
            const kind: DeclKind = if (type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, local, kind, spec, local_tok, .{});
            try b.import_recs.append(b.scratch, .{
                .local = local,
                .imported = imported,
                .module = module,
                .node = spec,
                .kind = .named,
                .type_only = type_only,
                .scope = b.cur_scope,
            });
        }
        if (!any_binding and module != 0) {
            try b.import_recs.append(b.scratch, .{
                .local = 0,
                .imported = 0,
                .module = module,
                .node = node,
                .kind = .side_effect,
                .type_only = false,
            });
        }
    }

    fn bindExportDefault(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const inner = d.lhs;
        var local: Atom = 0;
        var sym: SymbolId = no_symbol;
        switch (b.nodeTag(inner)) {
            .function_decl => {
                const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(inner).lhs);
                if (proto.name_token != 0) local = try b.atomOfToken(proto.name_token);
                try b.bindStatement(inner);
                if (local != 0) sym = b.members.get(memberKey(b.cur_scope, local)) orelse no_symbol;
            },
            .class_decl => {
                const data = b.tree.extraData(ast.ClassData, b.tree.nodeData(inner).lhs);
                if (data.name_token != 0) local = try b.atomOfToken(data.name_token);
                try b.bindStatement(inner);
                if (local != 0) sym = b.members.get(memberKey(b.cur_scope, local)) orelse no_symbol;
            },
            else => {
                try b.bindExpr(inner);
                // Record a bare `export default <ident>` name so an ambient
                // module can resolve it in its block scope.
                if (b.nodeTag(inner) == .identifier) local = try b.atomOfToken(b.tree.nodeMainToken(inner));
            },
        }
        if (sym != no_symbol) {
            b.sym_flags.items[sym].exported = true;
            b.sym_flags.items[sym].export_default = true;
        }
        try b.export_recs.append(b.scratch, .{
            .exported = try b.atomOf("default"),
            .local = local,
            .module = 0,
            .sym = sym,
            .node = node,
            .kind = .default,
            .type_only = false,
            .scope = b.cur_scope,
        });
    }

    /// `export = <entity>;` (CommonJS export assignment). The module's export
    /// *is* the named entity; the linker resolves `local` in the file scope and
    /// stores it under the reserved `export=` key. Bind the entity reference so
    /// it resolves like any value use.
    fn bindExportAssign(b: *Binder, node: Node) Error!void {
        const entity = b.tree.nodeData(node).lhs;
        var local: Atom = 0;
        if (entity != 0) {
            try b.bindExpr(entity);
            if (b.nodeTag(entity) == .identifier) {
                local = try b.atomOfToken(b.tree.nodeMainToken(entity));
            }
        }
        try b.export_recs.append(b.scratch, .{
            .exported = 0,
            .local = local,
            .module = 0,
            .sym = no_symbol,
            .node = node,
            .kind = .equals,
            .type_only = false,
            .scope = b.cur_scope,
        });
    }

    /// `import x = require("m");` (CommonJS import) or `import A = B.C;` (a
    /// TS entity-name alias). The `require` form rides the module graph like an
    /// ES import (`ImportKind.equals`); the entity-alias form is left lenient
    /// (the local resolves to `any`, no cross-scope reference bound so no
    /// spurious TS2304 — a documented under-report for a rare construct).
    fn bindImportEquals(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ImportEquals, d.lhs);
        if (b.cur_scope == file_scope) b.saw_module_syntax = true;
        const local = try b.atomOfToken(data.name_token);
        // `export import X = …` carries its `export` as a MODIFIER FLAG — the
        // parser does not wrap it in an `export_decl` — so `noteExport` has to
        // be armed by hand. Without the record the alias was marked `exported`
        // for namespace-member lookup but published nothing at file scope:
        // `export import Alias = Inner` in a module was invisible to every
        // importer (TS2305 "has no exported member"). preact's jsx-runtime
        // publishes its whole `JSX` namespace exactly this way.
        const saved_exporting = b.exporting_node;
        if (data.flags & ast.Flags.exported != 0) b.exporting_node = node;
        defer b.exporting_node = saved_exporting;
        _ = try b.declare(b.cur_scope, local, .import_value, node, data.name_token, .{});
        if (data.module_token != 0) {
            const module = try b.moduleAtom(data.module_token);
            if (module != 0) {
                try b.import_recs.append(b.scratch, .{
                    .local = local,
                    .imported = 0,
                    .module = module,
                    .node = node,
                    .kind = .equals,
                    .type_only = false,
                    .scope = b.cur_scope,
                });
            }
        }
    }

    fn bindExportNamed(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ExportNamed, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const decl_type_only = data.flags & ast.Flags.type_only != 0;
        // `namespace N { export { x }; }` re-exports `x` as the NAMESPACE
        // member `N.x` — it is not a module export (`noteExport` draws the same
        // line for `export <decl>` forms). Both `@types/node`'s `namespace test
        // { export { after, … }; }` and its `global { namespace NodeJS {
        // export { BufferEncoding }; } }` are this shape; treating them as
        // module exports put names the module never exported into its table
        // and, in `events.d.ts`, made a value export collide with the module's
        // `export = EventEmitter` (TS2309). So it is recorded under its own
        // kind, `.ns_named`, which every module-export table skips.
        //
        // Recorded rather than dropped because a namespace's aliases ARE
        // reachable — `import { EventEmitter } from "node:events"` resolves
        // through `export = EventEmitter` to the namespace member of that name,
        // which `events.d.ts` writes as `export { internal as EventEmitter }`.
        // Dropping the record made that import (and every @types/node type
        // reached the same way) `any`. A `declare module "spec" { … }` body IS
        // a module body, so its own `export { … }` records normally.
        const in_ns = b.cur_scope != file_scope and b.cur_scope != b.ambient_mod_scope;
        for (b.tree.extraRange(data.spec_start, data.spec_end)) |spec| {
            if (spec == null_node or b.nodeTag(spec) != .export_specifier) continue;
            const sd = b.tree.nodeData(spec);
            const local_tok = b.tree.nodeMainToken(spec);
            const local = try b.memberAtom(local_tok);
            const exported = if (sd.lhs != 0) try b.memberAtom(sd.lhs) else local;
            const type_only = decl_type_only or sd.rhs & ast.Flags.type_only != 0;
            try b.export_recs.append(b.scratch, .{
                .exported = exported,
                .local = local,
                .module = module,
                .sym = no_symbol, // local exports resolved at seal
                .node = spec,
                .kind = if (module != 0) .reexport_named else if (in_ns) .ns_named else .named,
                .type_only = type_only,
                .scope = b.cur_scope,
            });
        }
    }

    fn bindExportAll(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ExportAll, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const ns: Atom = if (data.name_token != 0) try b.atomOfToken(data.name_token) else 0;
        try b.export_recs.append(b.scratch, .{
            .exported = ns,
            .local = 0,
            .module = module,
            .sym = no_symbol,
            .node = node,
            .kind = if (ns != 0) .reexport_ns else .reexport_all,
            .type_only = data.flags & ast.Flags.type_only != 0,
        });
    }

    // --- expressions -------------------------------------------------------------

    /// Bind an expression subtree: record identifier references (with flow
    /// attachment), assignments (flow), branches (flow), and nested
    /// function/class scopes. Total on any tree shape.
    /// `fn.prop = value;` in statement position *declares* `prop` on the
    /// function value `fn` — TS 3.1 "properties declarations on functions"
    /// (`Stats.Row = Row`, `Stats.displayName = "Stats"`). tsc's shape, and
    /// this function's, is narrow on purpose:
    ///
    ///   - a plain (non-compound) `=` in an expression statement,
    ///   - the target is `<identifier>.<name>` — not computed, not nested,
    ///   - the identifier resolves *in the current scope* (tsc's same-scope
    ///     rule) to a symbol whose declaration is a `function` or a variable
    ///     initialized with a function expression / arrow.
    ///
    /// Everything else is left to ordinary assignment checking, so `const obj
    /// = {}; obj.x = 1` stays the TS2339 tsc reports. Repeated assignments to
    /// one name merge into a single property whose declarations are all the
    /// assignments.
    fn bindExpandoAssignment(b: *Binder, node: Node) Error!void {
        if (b.nodeTag(node) != .assign) return;
        if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) != .eq) return;
        const d = b.tree.nodeData(node);
        if (b.nodeTag(d.lhs) != .member_expr) return;
        const td = b.tree.nodeData(d.lhs);
        if (b.nodeTag(td.lhs) != .identifier) return;
        const name_tok = td.rhs;
        if (name_tok == 0) return;

        const obj_atom = try b.atomOfToken(b.tree.nodeMainToken(td.lhs));
        const sym = b.members.get(memberKey(b.cur_scope, obj_atom)) orelse return;
        if (!b.isFunctionValueSymbol(sym)) return;

        var xs = b.expando_scopes.get(sym) orelse 0;
        if (xs == 0) {
            xs = try b.newScope(.expando, node, b.cur_scope);
            try b.expando_scopes.put(b.scratch, sym, xs);
        }
        const atom = try b.memberAtom(name_tok);
        _ = try b.declare(xs, atom, .expando_member, node, name_tok, .{});
        b.sym_flags.items[sym].expando = true;
    }

    /// Whether `sym` is expando-eligible: a function declaration, or a
    /// `const` initialized with a function expression / arrow. `let`/`var`
    /// are *not* eligible (oracle-checked: `let g = function () {}; g.h = 2`
    /// is a TS2339), and neither is a class.
    fn isFunctionValueSymbol(b: *Binder, sym: SymbolId) bool {
        const f = b.sym_flags.items[sym];
        if (f.class) return false;
        if (f.function) return true;
        if (!f.const_decl) return false;
        var link = b.sym_decl_head.items[sym];
        while (link != 0) : (link = b.decl_links.items[link].next) {
            const decl = b.decl_links.items[link].value;
            const init: Node = switch (b.nodeTag(decl)) {
                .declarator_init => b.tree.nodeData(decl).rhs,
                .declarator_full => b.tree.extraData(
                    ast.DeclaratorFull,
                    b.tree.nodeData(decl).rhs,
                ).init,
                else => continue,
            };
            if (init == null_node) continue;
            switch (b.nodeTag(init)) {
                .arrow_fn, .function_expr => return true,
                else => {},
            }
        }
        return false;
    }

    // --- optional chains ------------------------------------------------------
    //
    // tsc's `bindOptionalChainFlow`/`bindOptionalChain`/`bindOptionalChainRest`.
    // An optional chain is a short-circuiting conditional written as a postfix
    // expression: `a?.b.c(d)` evaluates `b.c(d)` only when `a` is non-nullish,
    // so *inside the chain* — including the argument list, which the parser
    // hangs off a node several links above the `?.` — `a` is already known
    // non-nullish. tsc gets that by binding the chain's REST under the
    // non-short-circuited branch of a flow condition on the receiver; without
    // it `trending?.trends?.map(t => trending.recId)` reports TS18048 on the
    // second `trending`.

    /// The receiver of a chain link, or `null_node` when `node` is not a link
    /// shape. tsc's `isOptionalChain` walks exactly these four forms; a
    /// parenthesis is not one of them, which is why `(a?.b).c` ends the chain.
    fn chainReceiver(b: *const Binder, node: Node) Node {
        return switch (b.nodeTag(node)) {
            .member_expr,
            .optional_member_expr,
            .index_expr,
            .optional_index_expr,
            .call_expr,
            .call_expr_targs,
            .optional_call,
            .non_null,
            => b.tree.nodeData(node).lhs,
            else => null_node,
        };
    }

    /// tsc's `isOptionalChainRoot`: the link that carries the `?.` itself.
    fn isChainRoot(b: *const Binder, node: Node) bool {
        return switch (b.nodeTag(node)) {
            .optional_member_expr, .optional_index_expr, .optional_call => true,
            else => false,
        };
    }

    /// tsc's `isOptionalChain`: a `?.` link, or a link whose receiver is one.
    fn isOptionalChain(b: *const Binder, node: Node) bool {
        var n = node;
        while (n != null_node) {
            if (b.isChainRoot(n)) return true;
            n = b.chainReceiver(n);
        }
        return false;
    }

    /// Does this link bind an expression *after* its own `?.` would be tested?
    /// A property name and a `!` do not; an element index and a non-empty
    /// argument list do. (Type arguments do, syntactically, but types carry no
    /// flow.)
    fn linkBindsRest(b: *const Binder, node: Node) bool {
        const d = b.tree.nodeData(node);
        return switch (b.nodeTag(node)) {
            .index_expr, .optional_index_expr => true,
            .call_expr => blk: {
                const r = b.tree.extraData(ast.SubRange, d.rhs);
                break :blk r.end > r.start;
            },
            .call_expr_targs, .optional_call => blk: {
                const info = b.tree.extraData(ast.CallInfo, d.rhs);
                break :blk info.args_end > info.args_start;
            },
            else => false,
        };
    }

    /// Is there anything in this chain for the short-circuit conditions to
    /// govern? `a?.b.c` has no rest at all: every link is a property name, so
    /// binding it under the non-short-circuited flow and binding it under the
    /// entry flow are the same thing, and in VALUE position (where the flow is
    /// restored afterwards either way) the conditions would be pure garbage.
    /// `?.` is far too common to spend flow nodes on that.
    fn chainHasRest(b: *const Binder, node: Node) bool {
        var above = false;
        var out = false;
        var n = node;
        while (n != null_node) {
            const rest = b.linkBindsRest(n);
            // Everything seen so far — this link's own rest included — is
            // bound after this `?.` is tested. The deepest root wins.
            if (b.isChainRoot(n)) out = above or rest;
            above = above or rest;
            var recv = b.chainReceiver(n);
            while (b.nodeTag(recv) == .paren_expr) recv = b.tree.nodeData(recv).lhs;
            n = recv;
        }
        return out;
    }

    /// Bind one link of an optional chain: its receiver (recursively), then —
    /// when the link carries a `?.` — the condition that decides whether the
    /// chain short-circuits, and finally the link's own "rest" (element index
    /// or call arguments) under the *non*-short-circuited flow.
    ///
    /// Every `?.` pushes its test onto `chain_sc`; the caller turns those into
    /// the chain's short-circuit edges.
    fn bindChainLink(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        // tsc attaches a reference's flow node in `bindWorker`, which runs
        // before the node's children — so a chain link records the flow the
        // chain was *entered* in, not the one its own `?.` produced.
        switch (b.nodeTag(node)) {
            .member_expr, .optional_member_expr => try b.attachFlow(node),
            .index_expr, .optional_index_expr => {
                if (isNarrowableIndex(b, d.rhs)) try b.attachFlow(node);
            },
            else => {},
        }

        // The receiver. tsc reaches through parentheses here (its
        // `isTopLevelLogicalExpression` skips them), so `(a?.b)?.c` still
        // binds `.c` knowing `a` is non-nullish.
        const recv = d.lhs;
        var inner = recv;
        while (b.nodeTag(inner) == .paren_expr) inner = b.tree.nodeData(inner).lhs;
        if (inner != null_node and b.isOptionalChain(inner)) {
            try b.bindChainLink(inner);
        } else {
            try b.bindExpr(recv);
        }

        if (b.isChainRoot(node)) {
            const taken = try b.addFlow(.cond_true, b.cur_flow, recv);
            try b.chain_sc.append(b.scratch, .{ .ante = b.cur_flow, .expr = recv, .taken = taken });
            b.cur_flow = taken;
        }

        // `bindOptionalChainRest`.
        switch (b.nodeTag(node)) {
            .index_expr, .optional_index_expr => try b.bindExpr(d.rhs),
            .call_expr => {
                const r = b.tree.extraData(ast.SubRange, d.rhs);
                for (b.tree.extraRange(r.start, r.end)) |a| try b.bindExpr(a);
            },
            .call_expr_targs, .optional_call => {
                const info = b.tree.extraData(ast.CallInfo, d.rhs);
                for (b.tree.extraRange(info.targs_start, info.targs_end)) |t| try b.bindType(t);
                for (b.tree.extraRange(info.args_start, info.args_end)) |a| try b.bindExpr(a);
            },
            // A property name and a `!` have no rest to bind.
            else => {},
        }
    }

    /// An optional chain in VALUE position (tsc's `isTopLevelLogicalExpression`
    /// arm of `bindOptionalChainFlow`): the flow afterwards joins every
    /// short-circuit edge with both outcomes of the whole chain.
    ///
    /// When the chain moved `cur_flow` only through its own `?.` conditions —
    /// the overwhelming majority: no assignment, `&&`, or `?:` anywhere in an
    /// index or argument — that join is *by construction* the flow the chain
    /// started in: `narrow(t, e, true) ∪ narrow(t, e, false) == t` telescopes
    /// the whole ladder back to its base. Restoring it directly keeps the
    /// common case at one flow node per `?.` instead of four.
    fn bindOptionalChainValue(b: *Binder, node: Node) Error!void {
        const pre = b.cur_flow;
        const base = b.chain_sc.items.len;
        defer b.chain_sc.shrinkRetainingCapacity(base);
        try b.bindChainLink(node);
        const tests = b.chain_sc.items[base..];
        if (b.chainIsLinear(tests, pre)) {
            b.cur_flow = pre;
            return;
        }
        const pid = try b.newPending();
        for (tests) |t| try b.pendAdd(pid, try b.addFlow(.cond_false, t.ante, t.expr));
        try b.pendAdd(pid, try b.addFlow(.cond_true, b.cur_flow, node));
        try b.pendAdd(pid, try b.addFlow(.cond_false, b.cur_flow, node));
        b.cur_flow = try b.finishPending(pid);
    }

    /// Did the chain's flow advance *only* through its own `?.` conditions?
    fn chainIsLinear(b: *const Binder, tests: []const ChainTest, pre: FlowId) bool {
        var prev = pre;
        for (tests) |t| {
            if (t.ante != prev) return false;
            prev = t.taken;
        }
        return b.cur_flow == prev;
    }

    /// An optional chain used as a CONDITION. The true outcome sits at the end
    /// of the non-short-circuited chain; the false outcome joins that with
    /// every short-circuit edge, so a chain that yielded `undefined` because
    /// its receiver was nullish does not narrow the receiver on the else
    /// branch (`if (a?.b) {} else { a.b }` must still report on `a`).
    fn bindOptionalChainCondition(b: *Binder, node: Node) Error!CondFlows {
        const pre = b.cur_flow;
        const base = b.chain_sc.items.len;
        defer b.chain_sc.shrinkRetainingCapacity(base);
        try b.bindChainLink(node);
        const t = try b.addFlow(.cond_true, b.cur_flow, node);
        const pid = try b.newPending();
        for (b.chain_sc.items[base..]) |sc| {
            try b.pendAdd(pid, try b.addFlow(.cond_false, sc.ante, sc.expr));
        }
        try b.pendAdd(pid, try b.addFlow(.cond_false, b.cur_flow, node));
        b.cur_flow = pre;
        return .{ .t = t, .f = try b.finishPending(pid) };
    }

    fn bindExpr(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => try b.bindIdentifierRef(node),
            .member_expr, .optional_member_expr => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
                // Narrowable reference (`x.y` discriminants): attach flow.
                try b.attachFlow(node);
            },
            .non_null => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
            },
            .index_expr, .optional_index_expr => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
                try b.bindExpr(d.rhs);
                // An element access whose index is a literal (`arr[0]`) or a
                // bare identifier (`ICON_BY_TAG[tag]`) is a narrowable
                // reference exactly like a dotted member — `if
                // (isImageElement(elements[0]))` and `if (map[k]) map[k].use()`
                // both have to narrow the reads of the same access. A computed
                // index (`arr[i + 1]`, `f()[k]`) is not a stable reference
                // (the checker's `buildRefKey` rejects it), so it gets no flow
                // entry and costs nothing.
                if (isNarrowableIndex(b, d.rhs)) try b.attachFlow(node);
            },
            .assign => {
                try b.bindExpr(d.lhs);
                try b.bindExpr(d.rhs);
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
            },
            .prefix_unary, .postfix_unary => {
                try b.bindExpr(d.lhs);
                switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                    .plus_plus, .minus_minus => {
                        b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                    },
                    else => {},
                }
            },
            .binary => {
                switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                    .amp_amp, .pipe_pipe => {
                        // Value position: bind as condition, then join.
                        const cond = try b.bindCondition(node);
                        const pid = try b.newPending();
                        try b.pendAdd(pid, cond.t);
                        try b.pendAdd(pid, cond.f);
                        b.cur_flow = try b.finishPending(pid);
                    },
                    else => {
                        try b.bindExpr(d.lhs);
                        try b.bindExpr(d.rhs);
                    },
                }
            },
            .cond_expr => {
                const e = b.tree.extraData(ast.CondExpr, d.rhs);
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindExpr(e.then_expr);
                const after_then = b.cur_flow;
                b.cur_flow = cond.f;
                try b.bindExpr(e.else_expr);
                const after_else = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, after_else);
                b.cur_flow = try b.finishPending(pid);
            },
            .as_expr, .satisfies_expr => {
                try b.bindExpr(d.lhs);
                try b.bindType(d.rhs);
            },
            .call_expr_targs, .optional_call, .new_expr_targs => {
                if (b.nodeTag(node) != .new_expr_targs and b.isOptionalChain(node) and
                    b.chainHasRest(node))
                {
                    return b.bindOptionalChainValue(node);
                }
                try b.bindExpr(d.lhs);
                const info = b.tree.extraData(ast.CallInfo, d.rhs);
                for (b.tree.extraRange(info.targs_start, info.targs_end)) |t| try b.bindType(t);
                for (b.tree.extraRange(info.args_start, info.args_end)) |a| try b.bindExpr(a);
            },
            .instantiation_expr => {
                try b.bindExpr(d.lhs);
                const r = b.tree.extraData(ast.SubRange, d.rhs);
                for (b.tree.extraRange(r.start, r.end)) |t| try b.bindType(t);
            },
            .object_literal => {
                for (b.tree.nodeRange(node)) |prop| {
                    if (prop == null_node) continue;
                    const pd = b.tree.nodeData(prop);
                    switch (b.nodeTag(prop)) {
                        .object_property => {
                            // Non-computed keys are names, not references.
                            if (pd.lhs != 0 and b.nodeTag(pd.lhs) == .computed_name) {
                                try b.bindExpr(pd.lhs);
                            }
                            try b.bindExpr(pd.rhs);
                        },
                        .object_shorthand => {
                            try b.bindExpr(pd.lhs); // shorthand *is* a reference
                            try b.bindExpr(pd.rhs); // cover-grammar default
                        },
                        .object_method => {
                            if (pd.lhs != 0 and b.nodeTag(pd.lhs) == .computed_name) {
                                try b.bindExpr(pd.lhs);
                            }
                            try b.bindExpr(pd.rhs); // function_expr
                        },
                        else => try b.bindExpr(prop), // spread etc.
                    }
                }
            },
            .arrow_fn, .function_expr => try b.bindFunctionLike(node, d.lhs, d.rhs, false),
            .class_decl => try b.bindClass(node, false), // class expression
            .function_decl => try b.bindFunctionDecl(node), // recovery
            .interface_decl => try b.bindInterface(node),
            .type_alias => try b.bindTypeAlias(node),
            .block => try b.bindStatement(node),

            // Leaves without references.
            .number_literal,
            .string_literal,
            .bigint_literal,
            .regex_literal,
            .template_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .this_expr,
            .super_expr,
            .new_target,
            .import_expr,
            .omitted,
            .error_node,
            .unsupported,
            .empty_stmt,
            .debugger_stmt,
            => {},

            .jsx_element => {
                const e = b.tree.extraData(ast.JsxElementData, d.lhs);
                // Intrinsic tags (`<div>`) are not value references; component
                // tags (`<Foo>`, `<A.B>`) are. Attributes and children carry
                // ordinary expressions.
                if (e.tag != null_node and !isIntrinsicJsxTag(b, e.tag)) try b.bindExpr(e.tag);
                for (b.tree.extraRange(e.attrs_start, e.attrs_end)) |attr| try b.bindExpr(attr);
                for (b.tree.extraRange(e.children_start, e.children_end)) |ch| try b.bindExpr(ch);
            },

            .call_expr => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                // `import("m")` in *expression* position is a module
                // dependency exactly like the type-position `import("m")`.
                if (b.nodeTag(d.lhs) == .import_expr) try b.bindDynamicImport(node);
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindExpr(child);
            },

            // Everything else: recurse over expression children generically.
            else => {
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindExpr(child);
            },
        }
    }

    /// An intrinsic JSX tag is a simple lowercase-initial identifier (`div`);
    /// uppercase or dotted names (`Foo`, `A.B`) denote component values.
    fn isIntrinsicJsxTag(b: *Binder, tag: Node) bool {
        if (b.nodeTag(tag) != .identifier) return false;
        const text = b.tokenText(b.tree.nodeMainToken(tag));
        return text.len > 0 and text[0] >= 'a' and text[0] <= 'z';
    }

    fn bindIdentifierRef(b: *Binder, node: Node) Error!void {
        const tok = b.tree.nodeMainToken(node);
        // `undefined` is an intrinsic, not a reference (like `null`).
        if (b.tree.tokens.tag(tok) == .keyword_undefined) return;
        const atom = try b.atomOfToken(tok);
        try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
        try b.attachFlow(node);
    }

    /// Bind a condition expression, producing the flows for its true and
    /// false outcomes. Decomposes `&&`, `||`, `!`, and parens so the checker can
    /// narrow each operand (truthiness/typeof/equality/discriminant).
    fn bindCondition(b: *Binder, node: Node) Error!CondFlows {
        if (node == null_node) {
            return .{ .t = b.cur_flow, .f = unreachable_flow };
        }
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .paren_expr => return b.bindCondition(d.lhs),
            .prefix_unary => {
                if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) == .bang) {
                    const inner = try b.bindCondition(d.lhs);
                    return .{ .t = inner.f, .f = inner.t };
                }
            },
            .binary => switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                .amp_amp => {
                    const lhs = try b.bindCondition(d.lhs);
                    b.cur_flow = lhs.t;
                    const rhs = try b.bindCondition(d.rhs);
                    const pid = try b.newPending();
                    try b.pendAdd(pid, lhs.f);
                    try b.pendAdd(pid, rhs.f);
                    return .{ .t = rhs.t, .f = try b.finishPending(pid) };
                },
                .pipe_pipe => {
                    const lhs = try b.bindCondition(d.lhs);
                    b.cur_flow = lhs.f;
                    const rhs = try b.bindCondition(d.rhs);
                    const pid = try b.newPending();
                    try b.pendAdd(pid, lhs.t);
                    try b.pendAdd(pid, rhs.t);
                    return .{ .t = try b.finishPending(pid), .f = rhs.f };
                },
                else => {},
            },
            // An optional chain is itself a short-circuiting condition; its
            // outcomes are built from the chain's own tests.
            .member_expr,
            .optional_member_expr,
            .index_expr,
            .optional_index_expr,
            .call_expr,
            .call_expr_targs,
            .optional_call,
            .non_null,
            => {
                if (b.isOptionalChain(node)) return b.bindOptionalChainCondition(node);
            },
            else => {},
        }
        try b.bindExpr(node);
        return .{
            .t = try b.addFlow(.cond_true, b.cur_flow, node),
            .f = try b.addFlow(.cond_false, b.cur_flow, node),
        };
    }

    // --- types ---------------------------------------------------------------

    /// Bind a type subtree: record type references (no flow attachment) and
    /// scopes for function types. Intrinsic keyword types (`number`, ...)
    /// are not references.
    fn bindType(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => try b.bindTypeName(node),
            .qualified_name => try b.bindTypeName(node),
            .type_ref => {
                try b.bindTypeName(d.lhs);
                const r = b.tree.extraData(ast.SubRange, d.rhs);
                for (b.tree.extraRange(r.start, r.end)) |arg| try b.bindType(arg);
            },
            .typeof_type => {
                // `typeof x` references the *value* x.
                try b.bindTypeofEntity(d.lhs);
                // `typeof f<T>` — the type arguments are ordinary types.
                if (d.rhs != 0) {
                    const r = b.tree.extraData(ast.SubRange, d.rhs);
                    for (b.tree.extraRange(r.start, r.end)) |arg| try b.bindType(arg);
                }
            },
            .import_type => try b.bindImportType(node),
            .function_type, .method_signature, .constructor_type => try b.bindFunctionType(node, d.lhs),
            .object_type => {
                const ms = try b.newScope(.interface_members, node, b.cur_scope);
                // An object-type literal is its own (unshared) block, so a
                // repeated member name in it is always a duplicate.
                const saved_block = b.cur_block;
                b.cur_block = node;
                defer b.cur_block = saved_block;
                for (b.tree.nodeRange(node)) |member| {
                    if (member != null_node) try b.bindTypeMember(member, ms);
                }
            },
            .number_literal,
            .string_literal,
            .bigint_literal,
            .template_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .this_expr,
            .error_node,
            .unsupported,
            => {},
            else => {
                // array/tuple/union/intersection/keyof/readonly/paren/
                // indexed-access/optional/rest: children are all types.
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindType(child);
            },
        }
    }

    /// A type-position name: the leftmost identifier of `A.B.C` is the
    /// reference; intrinsics (number/string/...) are skipped.
    fn bindTypeName(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                if (isIntrinsicTypeToken(b.tree.tokens.tag(tok))) return;
                const atom = try b.atomOfToken(tok);
                try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
            },
            .qualified_name => try b.bindTypeName(b.tree.nodeData(node).lhs),
            else => try b.bindType(node),
        }
    }

    /// `typeof entity` in type position: a value-space reference without
    /// flow attachment (narrowing does not apply inside types).
    fn bindTypeofEntity(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                if (b.tree.tokens.tag(tok) == .keyword_undefined) return;
                const atom = try b.atomOfToken(tok);
                try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
            },
            .qualified_name => try b.bindTypeofEntity(b.tree.nodeData(node).lhs),
            .import_type => try b.bindImportType(node),
            else => {},
        }
    }

    /// A type-position `import("m")`: register the specifier as a module
    /// dependency so discovery pulls `m` into the program. Emitted as a
    /// side-effect import record (no local binding); `linkImports` skips it and
    /// the checker resolves the module's exports lazily via `ProgFile.specs`.
    /// An expression `import("m")` with a literal specifier: register `m` as a
    /// module dependency so discovery pulls it into the program and the checker
    /// can give the call `Promise<<namespace object of m>>` (`importCallType`).
    /// A side-effect record, like `bindImportType` — no local binding, and
    /// `linkImports` skips it. Not `type_only`: this is a runtime import.
    /// A computed specifier registers nothing (tsc cannot resolve it either).
    /// A no-substitution template literal (`` import(`./m`) ``) IS a literal
    /// specifier and tsc resolves it exactly like the quoted form — the AST
    /// node is `.template_literal`, so it has to be admitted alongside
    /// `.string_literal` here and in `importCallType`.
    fn bindDynamicImport(b: *Binder, node: Node) Error!void {
        const r = b.tree.extraData(ast.SubRange, b.tree.nodeData(node).rhs);
        const args = b.tree.extraRange(r.start, r.end);
        if (args.len == 0) return;
        switch (b.nodeTag(args[0])) {
            .string_literal, .template_literal => {},
            else => return,
        }
        const module = try b.moduleAtom(b.tree.nodeMainToken(args[0]));
        if (module == 0) return;
        try b.import_recs.append(b.scratch, .{
            .local = 0,
            .imported = 0,
            .module = module,
            .node = node,
            .kind = .side_effect,
            .type_only = false,
        });
    }

    fn bindImportType(b: *Binder, node: Node) Error!void {
        const spec_tok = b.tree.nodeData(node).lhs;
        if (spec_tok == 0) return; // parse error: no specifier
        const module = try b.moduleAtom(spec_tok);
        if (module == 0) return;
        try b.import_recs.append(b.scratch, .{
            .local = 0,
            .imported = 0,
            .module = module,
            .node = node,
            .kind = .side_effect,
            .type_only = true,
        });
    }

    fn isIntrinsicTypeToken(tag: scanner.Tag) bool {
        return switch (tag) {
            .keyword_any,
            .keyword_unknown,
            .keyword_never,
            .keyword_void,
            .keyword_number,
            .keyword_string,
            .keyword_boolean,
            .keyword_object,
            .keyword_symbol,
            .keyword_bigint,
            .keyword_undefined,
            => true,
            else => false,
        };
    }

    /// A function *type* gets a scope for its type/value params but no flow.
    fn bindFunctionType(b: *Binder, node: Node, proto_idx: u32) Error!void {
        const proto = b.tree.extraData(ast.FnProto, proto_idx);
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.function, node);
        try b.bindTypeParams(proto.tp_start, proto.tp_end);
        for (b.tree.extraRange(proto.params_start, proto.params_end)) |param| {
            try b.bindParam(param, false);
        }
        try b.bindType(proto.return_type);
        b.popScope(saved_scope);
    }

    // --- seal ---------------------------------------------------------------------

    /// Flatten scratch state into arena-allocated, immutable arrays; resolve
    /// recorded references (unresolved ones are kept, they are not errors);
    /// resolve local `export {...}` records against the file scope.
    fn seal(b: *Binder) Error!Bind {
        const arena = b.arena;
        const n_syms = b.sym_names.items.len;
        const n_scopes = b.scope_parents.items.len;

        // Symbols.
        const symbol_names = try arena.dupe(Atom, b.sym_names.items);
        const symbol_flags = try arena.dupe(SymbolFlags, b.sym_flags.items);
        const symbol_scopes = try arena.dupe(ScopeId, b.sym_scopes.items);
        const decls_start = try arena.alloc(u32, n_syms + 1);
        var total_decls: u32 = 0;
        for (b.sym_decl_count.items, 0..) |count, i| {
            decls_start[i] = total_decls;
            total_decls += count;
        }
        decls_start[n_syms] = total_decls;
        const decls = try arena.alloc(Node, total_decls);
        {
            var out: usize = 0;
            for (0..n_syms) |i| {
                var l = b.sym_decl_head.items[i];
                while (l != 0) : (l = b.decl_links.items[l].next) {
                    decls[out] = b.decl_links.items[l].value;
                    out += 1;
                }
            }
        }

        // Scopes + member maps (sorted by (scope, atom) for binary search).
        const scope_parents = try arena.dupe(ScopeId, b.scope_parents.items);
        const scope_kinds = try arena.dupe(ScopeKind, b.scope_kinds.items);
        const scope_owners = try arena.dupe(Node, b.scope_owners.items);

        const Entry = struct { scope: ScopeId, atom: Atom, sym: SymbolId };
        var entries = try b.scratch.alloc(Entry, b.members.count());
        {
            var it = b.members.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                entries[i] = .{
                    .scope = @intCast(kv.key_ptr.* >> 32),
                    .atom = @truncate(kv.key_ptr.*),
                    .sym = kv.value_ptr.*,
                };
            }
        }
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, x: Entry, y: Entry) bool {
                if (x.scope != y.scope) return x.scope < y.scope;
                return x.atom < y.atom;
            }
        }.lessThan);
        const members_start = try arena.alloc(u32, n_scopes + 1);
        const member_atoms = try arena.alloc(Atom, entries.len);
        const member_syms = try arena.alloc(SymbolId, entries.len);
        {
            var e: usize = 0;
            for (0..n_scopes) |s| {
                members_start[s] = @intCast(e);
                while (e < entries.len and entries[e].scope == @as(ScopeId, @intCast(s))) : (e += 1) {
                    member_atoms[e] = entries[e].atom;
                    member_syms[e] = entries[e].sym;
                }
            }
            members_start[n_scopes] = @intCast(e);
        }

        // Global contributions: a module offers its `declare global`
        // block members; a script/the lib offers its whole file scope. Both
        // segments are already sorted by atom, so we reference the subslice.
        // A script/the lib offers its whole file scope; every file (module or
        // script) also offers every `declare global {}` / bare `global {}`
        // block, whose members land in `global_scope`. Real `@types/node`
        // declares `namespace NodeJS` inside bare `global {}` blocks nested in
        // `declare module "process"`/`"timers"` — files that are *scripts*
        // (no top-level import/export), so their `global_scope` must merge in
        // too, not just `file_scope`. Contribute both segments.
        const is_module = b.saw_module_syntax;
        // `export as namespace X;` publishes the module's `export =` entity
        // under the global name X — the UMD global. That is what makes a
        // `React.CSSProperties` annotation resolve in a file that never
        // imports React; without it the qualified name found nothing and the
        // whole annotation degraded to `any`. Only the `export = <ident>`
        // shape is modeled (the ecosystem's `export = X; export as namespace
        // X;` pair); a UMD name over a named-export module keeps the old
        // discard. Resolved here rather than at bind time because the entity
        // is routinely declared *after* the `export =` line.
        var umd_atom: Atom = 0;
        var umd_sym: SymbolId = no_symbol;
        if (b.umd_name != 0) {
            for (b.export_recs.items) |rec| {
                if (rec.kind != .equals or rec.local == 0) continue;
                const lo = members_start[file_scope];
                const hi = members_start[file_scope + 1];
                const seg = member_atoms[lo..hi];
                if (std.sort.binarySearch(Atom, seg, rec.local, struct {
                    fn cmp(key: Atom, mid: Atom) std.math.Order {
                        return std.math.order(key, mid);
                    }
                }.cmp)) |i| {
                    umd_atom = b.umd_name;
                    umd_sym = member_syms[lo + i];
                }
                break;
            }
        }
        var global_atoms: []Atom = &.{};
        var global_syms: []SymbolId = &.{};
        var global_aug_start: u32 = 0;
        // Start offset of each atom-sorted run inside `global_atoms` (see
        // `Bind.global_runs`); left empty when the whole slice is one run.
        var global_runs: std.ArrayList(u32) = .empty;
        defer global_runs.deinit(b.scratch);
        {
            // Own (non-augmentation) segment: a script/lib's whole file scope,
            // plus the UMD entry if any. Then the augmentation segment: every
            // `global { … }` block scope, in creation order. `global_aug_start`
            // splits them for `mergeGlobals`, which merges the two classes in
            // separate passes (tsc's precedence).
            const flo = if (!is_module) members_start[file_scope] else 0;
            const fhi = if (!is_module) members_start[file_scope + 1] else 0;
            const fn_ = (fhi - flo) + @as(u32, if (umd_atom != 0) 1 else 0);
            var gn_: u32 = 0;
            for (b.global_scopes.items) |gs| gn_ += members_start[gs + 1] - members_start[gs];
            global_aug_start = fn_;
            if (gn_ == 0) {
                // No global blocks: the file scope segment is already
                // contiguous unless the UMD entry has to be appended.
                if (umd_atom == 0) {
                    global_atoms = member_atoms[flo..fhi];
                    global_syms = member_syms[flo..fhi];
                } else {
                    const ca = try arena.alloc(Atom, fn_);
                    const cs = try arena.alloc(SymbolId, fn_);
                    @memcpy(ca[0 .. fn_ - 1], member_atoms[flo..fhi]);
                    @memcpy(cs[0 .. fn_ - 1], member_syms[flo..fhi]);
                    ca[fn_ - 1] = umd_atom;
                    cs[fn_ - 1] = umd_sym;
                    global_atoms = ca;
                    global_syms = cs;
                    try global_runs.appendSlice(b.scratch, &.{ 0, fn_ - 1 });
                }
            } else if (fn_ == 0 and b.global_scopes.items.len == 1) {
                const gs = b.global_scopes.items[0];
                global_atoms = member_atoms[members_start[gs]..members_start[gs + 1]];
                global_syms = member_syms[members_start[gs]..members_start[gs + 1]];
            } else {
                const ca = try arena.alloc(Atom, fn_ + gn_);
                const cs = try arena.alloc(SymbolId, fn_ + gn_);
                var at: u32 = fhi - flo;
                @memcpy(ca[0..at], member_atoms[flo..fhi]);
                @memcpy(cs[0..at], member_syms[flo..fhi]);
                try global_runs.append(b.scratch, 0);
                if (umd_atom != 0) {
                    try global_runs.append(b.scratch, at);
                    ca[at] = umd_atom;
                    cs[at] = umd_sym;
                    at += 1;
                }
                for (b.global_scopes.items) |gs| {
                    const glo = members_start[gs];
                    const ghi = members_start[gs + 1];
                    try global_runs.append(b.scratch, at);
                    @memcpy(ca[at .. at + (ghi - glo)], member_atoms[glo..ghi]);
                    @memcpy(cs[at .. at + (ghi - glo)], member_syms[glo..ghi]);
                    at += ghi - glo;
                }
                global_atoms = ca;
                global_syms = cs;
            }
        }

        const msp = try sealPairMap(arena, b.scratch, &b.member_scopes);
        const ssp = try sealPairMap(arena, b.scratch, &b.static_scopes);
        const nsp = try sealPairMap(arena, b.scratch, &b.namespace_scopes);
        const xsp = try sealPairMap(arena, b.scratch, &b.expando_scopes);
        const esp = try sealPairMap(arena, b.scratch, &b.enum_scopes);

        // Flow: convert label pending ids into flow_extra ranges.
        const n_flows = b.flow_tags.items.len;
        const flow_tags = try arena.dupe(FlowTag, b.flow_tags.items);
        const flow_a = try arena.alloc(u32, n_flows);
        const flow_b = try arena.alloc(u32, n_flows);
        var extra: std.ArrayList(FlowId) = .empty;
        defer extra.deinit(b.scratch);
        for (0..n_flows) |i| {
            switch (b.flow_tags.items[i]) {
                .branch_label, .loop_label => {
                    const p = b.pendings.items[b.flow_a.items[i]];
                    flow_a[i] = @intCast(extra.items.len);
                    var l = p.head;
                    while (l != 0) : (l = b.ante_links.items[l].next) {
                        try extra.append(b.scratch, b.ante_links.items[l].value);
                    }
                    flow_b[i] = @intCast(extra.items.len);
                },
                else => {
                    flow_a[i] = b.flow_a.items[i];
                    flow_b[i] = b.flow_b.items[i];
                },
            }
        }
        const flow_extra = try arena.dupe(FlowId, extra.items);
        const flow_scopes = try arena.dupe(ScopeId, b.flow_scopes.items);

        // Node -> flow attachment map, sorted by node id.
        std.mem.sort(Link, b.flow_pairs.items, {}, struct {
            fn lessThan(_: void, x: Link, y: Link) bool {
                return x.value < y.value;
            }
        }.lessThan);
        const flow_map_nodes = try arena.alloc(Node, b.flow_pairs.items.len);
        const flow_map_ids = try arena.alloc(FlowId, b.flow_pairs.items.len);
        for (b.flow_pairs.items, 0..) |pair, i| {
            flow_map_nodes[i] = pair.value;
            flow_map_ids[i] = pair.next;
        }

        var result: Bind = .{
            .symbol_names = symbol_names,
            .symbol_flags = symbol_flags,
            .symbol_scopes = symbol_scopes,
            .symbol_decls_start = decls_start,
            .symbol_decls = decls,
            .scope_parents = scope_parents,
            .scope_kinds = scope_kinds,
            .scope_owners = scope_owners,
            .scope_members_start = members_start,
            .member_atoms = member_atoms,
            .member_syms = member_syms,
            .member_scope_syms = msp.keys,
            .member_scope_ids = msp.vals,
            .static_scope_syms = ssp.keys,
            .static_scope_ids = ssp.vals,
            .ns_scope_syms = nsp.keys,
            .ns_scope_ids = nsp.vals,
            .expando_scope_syms = xsp.keys,
            .expando_scope_ids = xsp.vals,
            .enum_scope_syms = esp.keys,
            .enum_scope_ids = esp.vals,
            .flow_tags = flow_tags,
            .flow_a = flow_a,
            .flow_b = flow_b,
            .flow_scopes = flow_scopes,
            .flow_extra = flow_extra,
            .flow_map_nodes = flow_map_nodes,
            .flow_map_ids = flow_map_ids,
            .imports = &.{},
            .exports = &.{},
            .unresolved = &.{},
            .diagnostics = &.{},
            .is_module = is_module,
            .global_atoms = global_atoms,
            .global_syms = global_syms,
            .global_aug_start = global_aug_start,
            .global_runs = try arena.dupe(u32, global_runs.items),
            .first_touch = try arena.dupe(Atom, b.first_touch.items),
        };

        // Resolve recorded references; keep the unresolved ones.
        var unresolved: std.ArrayList(Ref) = .empty;
        defer unresolved.deinit(b.scratch);
        for (b.refs.items) |ref| {
            if (result.resolve(ref.atom, ref.scope) == null) {
                try unresolved.append(b.scratch, ref);
            }
        }
        result.unresolved = try arena.dupe(Ref, unresolved.items);

        // Resolve local `export { a }` records + mark the symbols exported.
        // The lookup starts in the record's OWN scope and walks outward: a
        // `declare module "spec" { class S {} export { S }; }` block and a
        // `namespace N { export { x }; }` body both name entities that are not
        // in the file scope, and tsc resolves them by walking the enclosing
        // containers. The `global { … }` blocks are consulted last, as the
        // program globals tsc would have found after the lexical chain ran out
        // — that is what makes `declare module "buffer" { global { var Buffer …
        // } export { Buffer }; }` (real `@types/node`) resolve.
        for (b.export_recs.items) |*rec| {
            if ((rec.kind == .named or rec.kind == .ns_named) and rec.sym == no_symbol and rec.local != 0 and rec.module == 0) {
                if (result.resolveWithGlobals(rec.local, rec.scope, b.global_scopes.items)) |sym| {
                    rec.sym = sym;
                    symbol_flags[sym].exported = true;
                }
            }
            // `export default A;` where `A` is a bare identifier is an ALIAS to
            // the local entity, carrying every meaning it has — tsc's
            // `bindExportAssignment` declares an alias exactly when the
            // expression is an entity name. Resolving the local here is what
            // makes `import type A from "./m"` a type: without it the export is
            // only a `default_expr` (the *value* of the expression), so the type
            // meaning was silently dropped and the import became `any`.
            // `export default class B {}` already carried its symbol from
            // `bindExportDefault`, which is why the declaration form worked.
            //
            // The local is NOT marked `exported`: `export default A` publishes
            // `A` under the name `default` only, never under `A`.
            if (rec.kind == .default and rec.sym == no_symbol and rec.local != 0 and rec.module == 0) {
                if (result.resolveWithGlobals(rec.local, rec.scope, b.global_scopes.items)) |sym| rec.sym = sym;
            }
        }
        // tsc's *export context* (`setExportContextFlag` / `hasExportDeclarations`):
        // a declaration file whose top level contains no export DECLARATION
        // (`export { … }`, `export * from`, `export =`, `export default <expr>`)
        // implicitly exports every top-level declaration, `export` modifier or
        // not. React Native's `Appearance.d.ts` leans on it — `type
        // ColorSchemeName` carries no modifier, yet
        // `import {ColorSchemeName} from 'react-native'` (which reaches it via
        // the barrel's `export *`) resolves for tsc.
        if (b.is_dts and b.saw_module_syntax and !b.saw_export_declaration) {
            const lo = members_start[file_scope];
            const hi = members_start[file_scope + 1];
            for (member_atoms[lo..hi], member_syms[lo..hi]) |atom, sym| {
                if (symbol_flags[sym].exported) continue;
                // ALIASES are exempt: tsc's `declareModuleMember` routes an
                // `Alias` symbol to `container.locals` unless it is an export
                // specifier or an `export import a = b`, so a plain `import {X}
                // from …` is never re-exported by the context rule.
                // `@atproto/api`'s `types.d.ts` proves it — it type-imports
                // `AppBskyActorDefs`, and re-exporting that would shadow the
                // real `export * as AppBskyActorDefs` with a type-only alias.
                if (symbol_flags[sym].import_binding) continue;
                symbol_flags[sym].exported = true;
                const dlo = decls_start[sym];
                try b.export_recs.append(b.scratch, .{
                    .exported = atom,
                    .local = atom,
                    .module = 0,
                    .sym = sym,
                    .node = if (decls_start[sym + 1] > dlo) decls[dlo] else 0,
                    .kind = .named,
                    .type_only = false,
                });
            }
        }

        result.imports = try arena.dupe(ImportRec, b.import_recs.items);
        result.exports = try arena.dupe(ExportRec, b.export_recs.items);
        result.diagnostics = try arena.dupe(Diagnostic, b.diags.items);
        result.ambient_modules = try arena.dupe(AmbientModule, b.ambient_mods.items);
        return result;
    }

    fn sealPairMap(
        arena: Allocator,
        scratch: Allocator,
        map: *std.AutoHashMapUnmanaged(SymbolId, ScopeId),
    ) Error!struct { keys: []const u32, vals: []const u32 } {
        const Pair = struct { k: u32, v: u32 };
        var pairs = try scratch.alloc(Pair, map.count());
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            pairs[i] = .{ .k = kv.key_ptr.*, .v = kv.value_ptr.* };
        }
        std.mem.sort(Pair, pairs, {}, struct {
            fn lessThan(_: void, x: Pair, y: Pair) bool {
                return x.k < y.k;
            }
        }.lessThan);
        const keys = try arena.alloc(u32, pairs.len);
        const vals = try arena.alloc(u32, pairs.len);
        for (pairs, 0..) |p, j| {
            keys[j] = p.k;
            vals[j] = p.v;
        }
        return .{ .keys = keys, .vals = vals };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

test "remapAtoms: every Bind field is accounted for" {
    // A new field holding an `Atom` (directly, or inside a record) must be
    // rewritten by `remapAtoms`; bump the count once it is.
    try testing.expectEqual(Bind.remap_field_count, @typeInfo(Bind).@"struct".fields.len);
}

test "remapAtoms: a renumbered file resolves exactly as it did" {
    const src =
        \\declare const zulu: number;
        \\declare const alpha: string;
        \\export function mike(kilo: number) { const oscar = kilo; return oscar; }
        \\export { zulu, alpha };
        \\declare module "sierra" { export const x: number; }
    ;
    var t = try TestBind.init(src);
    defer t.deinit();

    const before = try t.dumpAlloc(testing.allocator);
    defer testing.allocator.free(before);

    // Renumber against the reverse of the file's own first-touch order: the
    // ids move as far as they can, so anything `remapAtoms` forgets shows up.
    var order: std.ArrayList(Atom) = .empty;
    defer order.deinit(testing.allocator);
    var i = t.b.first_touch.len;
    while (i > 0) : (i -= 1) try order.append(testing.allocator, t.b.first_touch[i - 1]);
    const rn = try t.interner.renumber(testing.allocator, testing.allocator, order.items);
    defer testing.allocator.free(rn.map);
    try testing.expect(!rn.identity);
    try testing.expectEqual(@as(u32, 0), rn.uncovered);
    try t.b.remapAtoms(testing.allocator, rn.map);

    // The dump prints names, not ids: same file, same names, same structure.
    const after = try t.dumpAlloc(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    // Name resolution goes through the atom-sorted member segments, so it only
    // works if `remapAtoms` restored their order.
    for ([_][]const u8{ "zulu", "alpha", "mike" }) |name| {
        const a = try t.interner.intern(testing.io, testing.allocator, name);
        try testing.expect(t.b.resolve(a, file_scope) != null);
    }
    for (0..t.b.scope_members_start.len - 1) |s| {
        const lo = t.b.scope_members_start[s];
        const hi = t.b.scope_members_start[s + 1];
        for (lo + 1..hi) |k| try testing.expect(t.b.member_atoms[k - 1] < t.b.member_atoms[k]);
    }
    // Records carry atoms too.
    try testing.expect(t.b.ambient_modules.len == 1);
    try testing.expectEqualStrings("sierra", t.interner.lookup(testing.io, t.b.ambient_modules[0].spec));
    for (t.b.exports) |rec| {
        if (rec.exported == 0) continue;
        try testing.expect(t.interner.lookup(testing.io, rec.exported).len > 0);
    }
}

/// Everything needed to bind a source string in a test.
const TestBind = struct {
    arena: std.heap.ArenaAllocator,
    interner: Interner,
    tree: Ast,
    b: Bind,
    src: []const u8,

    fn init(src: []const u8) !TestBind {
        var t: TestBind = undefined;
        t.src = src;
        t.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer t.arena.deinit();
        t.interner = Interner.init();
        errdefer t.interner.deinit(testing.allocator);
        t.tree = try parser.parse(t.arena.allocator(), src);
        t.b = try bind(t.arena.allocator(), testing.io, testing.allocator, &t.interner, &t.tree, src, false);
        return t;
    }

    fn deinit(t: *TestBind) void {
        t.interner.deinit(testing.allocator);
        t.arena.deinit();
    }

    fn dumpAlloc(t: *TestBind, alloc: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try t.b.dump(testing.io, &t.interner, &t.tree, t.src, &aw.writer);
        return aw.toOwnedSlice();
    }

    fn atom(t: *TestBind, text: []const u8) !Atom {
        return t.interner.intern(testing.io, testing.allocator, text);
    }

    /// The nth (0-based) identifier node whose token text equals `name`.
    fn identNode(t: *TestBind, name: []const u8, nth: usize) ?Node {
        var seen: usize = 0;
        for (0..t.tree.nodes.len) |i| {
            const node: Node = @intCast(i);
            if (t.tree.nodeTag(node) != .identifier) continue;
            const text = t.tree.tokenSlice(t.src, t.tree.nodeMainToken(node));
            if (!std.mem.eql(u8, text, name)) continue;
            if (seen == nth) return node;
            seen += 1;
        }
        return null;
    }
};

fn expectDump(src: []const u8, expected: []const u8) !void {
    var t = try TestBind.init(src);
    defer t.deinit();
    const got = try t.dumpAlloc(t.arena.allocator());
    testing.expectEqualStrings(expected, got) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        return err;
    };
}

fn expectBindCodes(src: []const u8, expected: []const Code) !void {
    var t = try TestBind.init(src);
    defer t.deinit();
    testing.expectEqual(expected.len, t.b.diagnostics.len) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        for (t.b.diagnostics) |d| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ d.span.start, d.span.end, d.message() });
        }
        return err;
    };
    for (expected, t.b.diagnostics) |want, got| {
        testing.expectEqual(want, got.code) catch |err| {
            std.debug.print("--- source: {s}\n", .{src});
            return err;
        };
    }
}

test "smoke: bind a small file" {
    var t = try TestBind.init("const x = 1; function f(a: number) { return a + x; }");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.diagnostics.len);
    try testing.expect(t.b.symbolCount() >= 3);
    const x = try t.atom("x");
    try testing.expect(t.b.resolve(x, file_scope) != null);
}

// --- goldens: hoisting & scopes ---------------------------------------------

test "golden: var hoists out of blocks to the function scope" {
    try expectDump("function f() { var x = 1; { var y = 2; let z = 3; } }",
        \\scope 0: file
        \\  f: function impl
        \\  scope 1: function f
        \\    x: var
        \\    y: var
        \\    scope 2: block
        \\      z: let
        \\flow: nodes=5 attach=0 (start=2 assign=3 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: function declaration in a block is block-scoped (modern semantics)" {
    try expectDump("{ function g() {} }",
        \\scope 0: file
        \\  scope 1: block
        \\    g: function impl
        \\    scope 2: function g
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: let shadowing chain (TDZ names, one symbol per scope)" {
    try expectDump("let a = 1; { let a = 2; { let a = 3; a; } a; } a;",
        \\scope 0: file
        \\  a: let
        \\  scope 1: block
        \\    a: let
        \\    scope 2: block
        \\      a: let
        \\flow: nodes=4 attach=3 (start=1 assign=3 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: class members vs statics, parameter properties" {
    try expectDump("class C<T> { x: number = 1; static y: string; m(p: T): void {} static s(): void {} constructor(private z: number) {} }",
        \\scope 0: file
        \\  C: class
        \\  scope 1: class C
        \\    T: type-param
        \\    scope 2: class_members C
        \\      x: property
        \\      m: method impl
        \\      constructor: method impl
        \\      z: property
        \\    scope 3: class_statics C
        \\      y: property static
        \\      s: method static impl
        \\    scope 4: function m
        \\      p: param
        \\    scope 5: function s
        \\    scope 6: function constructor
        \\      z: param
        \\flow: nodes=4 attach=1 (start=4 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: params, destructured params, defaults referencing earlier params" {
    try expectDump("function h(a: number, [b, c]: number[], { d, e: f2 = a }: any, g2 = a + b) {}",
        \\scope 0: file
        \\  h: function impl
        \\  scope 1: function h
        \\    a: param
        \\    b: param
        \\    c: param
        \\    d: param
        \\    f2: param
        \\    g2: param
        \\flow: nodes=2 attach=3 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
    // The defaults' references to earlier params resolve in-file.
    var t = try TestBind.init("function h(a: number, g2 = a + 1) {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "golden: catch parameter gets its own scope shared with the body" {
    try expectDump("try { f(); } catch (e) { g(e); }",
        \\scope 0: file
        \\  scope 1: block
        \\  scope 2: catch_clause
        \\    e: catch
        \\flow: nodes=4 attach=3 (start=1 assign=0 cond=0 branch=1 loop=0 switch=0 call=2)
        \\unresolved: f(1) g(1)
        \\
    );
}

test "golden: for and for-of heads scope their declarations" {
    try expectDump("for (let i = 0; i < 10; i++) { i; } for (const x of xs) { x; }",
        \\scope 0: file
        \\  scope 1: for_head
        \\    i: let
        \\    scope 2: block
        \\  scope 3: for_head
        \\    x: const
        \\    scope 4: block
        \\flow: nodes=8 attach=5 (start=1 assign=3 cond=2 branch=0 loop=2 switch=0 call=0)
        \\unresolved: xs(1)
        \\
    );
}

test "golden: import records incl. type-only, namespace, side-effect" {
    try expectDump("import d, { a, b as c, type T } from \"./m\"; import * as ns from \"./n\"; import type X from \"./x\"; import \"./side\";",
        \\scope 0: file
        \\  d: import
        \\  a: import
        \\  c: import
        \\  T: import type-only
        \\  ns: import
        \\  X: import type-only
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\import local=d imported=default from="./m" default
        \\import local=a imported=a from="./m" named
        \\import local=c imported=b from="./m" named
        \\import local=T imported=T from="./m" named type-only
        \\import local=ns imported=* from="./n" namespace
        \\import local=X imported=default from="./x" default type-only
        \\import local=- imported=- from="./side" side_effect
        \\
    );
}

test "golden: export records (decl, alias, re-export, star, default)" {
    try expectDump("export const k = 1; export function ef() {} export { k as kk }; export type { T2 } from \"./t\"; export * from \"./all\"; export default 42;",
        \\scope 0: file
        \\  k: const exported
        \\  ef: function exported impl
        \\  scope 1: function ef
        \\flow: nodes=3 attach=0 (start=2 assign=1 cond=0 branch=0 loop=0 switch=0 call=0)
        \\export exported=k local=k named
        \\export exported=ef local=ef named
        \\export exported=kk local=k named
        \\export exported=T2 local=T2 from="./t" reexport_named type-only
        \\export exported=- local=- from="./all" reexport_all
        \\export exported=default local=- default
        \\
    );
}

test "golden: overload signatures group into one symbol" {
    try expectDump("function ov(a: number): void; function ov(a: string): void; function ov(a: any): void {}",
        \\scope 0: file
        \\  ov: function impl decls=3
        \\  scope 1: function ov
        \\    a: param
        \\  scope 2: function ov
        \\    a: param
        \\  scope 3: function ov
        \\    a: param
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: interface-interface merge shares one members scope" {
    try expectDump("interface I { a: number; m(): void; } interface I { b: string; }",
        \\scope 0: file
        \\  I: interface decls=2
        \\  scope 1: interface I
        \\    scope 2: interface_members I
        \\      a: property
        \\      m: method
        \\      b: property
        \\    scope 3: function m
        \\  scope 4: interface I
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

test "golden: type alias with type params" {
    try expectDump("type Alias<T> = T | null; let v: Alias<number>;",
        \\scope 0: file
        \\  Alias: type
        \\  v: let
        \\  scope 1: type_alias Alias
        \\    T: type-param
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0)
        \\
    );
}

// --- duplicate-declaration diagnostics --------------------------------------

// Every failed merge is reported at EVERY spelling of the name, tsc's
// `addDuplicateDeclarationErrorsForSymbols` — see `reportDuplicate`. The
// expectations below (codes AND counts) were read off the pinned tsgo 7.0.2
// oracle, one probe file per group.

test "dup: let/let redeclare is TS2451, once per declaration" {
    try expectBindCodes("let x = 1; let x = 2;", &.{ .block_scoped_redeclare, .block_scoped_redeclare });
    // Three declarations, three diagnostics — never nine.
    try expectBindCodes(
        "let x = 1; let x = 2; let x = 3;",
        &.{ .block_scoped_redeclare, .block_scoped_redeclare, .block_scoped_redeclare },
    );
    try testing.expectEqual(@as(u16, 2451), Code.block_scoped_redeclare.tsCode());
}

test "dup: var-vs-let picks the code off the EXISTING symbol" {
    // tsc's `declareSymbol` tests `symbol.flags & BlockScopedVariable` — the
    // symbol already in the table — so the two orders differ.
    try expectBindCodes("var x; let x;", &.{ .duplicate_identifier, .duplicate_identifier });
    try expectBindCodes("let x; var x;", &.{ .block_scoped_redeclare, .block_scoped_redeclare });
    // Order-independence across blocks: the var hoists past the let's scope
    // and lands in the same table, so the clash names both spellings.
    try expectBindCodes("let x; { var x; }", &.{ .block_scoped_redeclare, .block_scoped_redeclare });
    // A `let` INSIDE the block the var hoisted out of is the transit check,
    // which has only the newcomer to name (ztsc reports TS2451 where tsc has
    // the more specific TS2481 — a pre-existing divergence, not this rule).
    try expectBindCodes("{ var x; let x; }", &.{.block_scoped_redeclare});
    // No conflict when the block-scoped name is in a sibling/inner scope.
    try expectBindCodes("var x; { let x; }", &.{});
    try expectBindCodes("function f() { { let x; } var x; }", &.{});
}

test "dup: class/let and class/class" {
    // A `class` is not one of tsc's `BlockScopedVariable` bits, so it only
    // yields TS2451 when the *existing* symbol is a `let`/`const`.
    try expectBindCodes("let A; class A {}", &.{ .block_scoped_redeclare, .block_scoped_redeclare });
    try expectBindCodes("class A {} let A;", &.{ .duplicate_identifier, .duplicate_identifier });
    try expectBindCodes("class A {} var A;", &.{ .duplicate_identifier, .duplicate_identifier });
    try expectBindCodes("class A {} class A {}", &.{ .duplicate_identifier, .duplicate_identifier });
}

test "dup: var/function is TS2300, var/var and var/param merge" {
    try expectBindCodes("function f() {} var f;", &.{ .duplicate_identifier, .duplicate_identifier });
    try expectBindCodes("var x; var x;", &.{});
    try expectBindCodes("function f(x: number) { var x; }", &.{});
    // Declarations that merged silently are still named when a LATER one
    // clashes: `var g; var g; class g {}` is three TS2300s.
    try expectBindCodes(
        "var g; var g; class g {}",
        &.{ .duplicate_identifier, .duplicate_identifier, .duplicate_identifier },
    );
}

test "dup: an enum on either side of a failed merge is TS2567" {
    try expectBindCodes("enum E { A } var E;", &.{ .enum_merge_conflict, .enum_merge_conflict });
    try expectBindCodes("var E; enum E { A }", &.{ .enum_merge_conflict, .enum_merge_conflict });
    try expectBindCodes("enum E { A } class E {}", &.{ .enum_merge_conflict, .enum_merge_conflict });
    // Enum+enum and enum+namespace still merge.
    try expectBindCodes("enum E { A } enum E { B }", &.{});
    try expectBindCodes("enum E { A } namespace E { export const v = 1; }", &.{});
    try testing.expectEqual(@as(u16, 2567), Code.enum_merge_conflict.tsCode());
}

test "dup: a type-only namespace merges with a variable, an instantiated one does not" {
    // tsc's `NamespaceModuleExcludes = 0`: a namespace whose body declares only
    // types emits no runtime object, so it neither displaces nor is displaced
    // by a variable of the same name, in either declaration order.
    try expectBindCodes("namespace N { type A = number; } const N = 1;", &.{});
    try expectBindCodes("const M = 1; namespace M { interface I { a: number } }", &.{});
    try expectBindCodes("namespace E {} var E: number;", &.{});
    try expectBindCodes("namespace O { namespace Inner { type A = number; } } let O: number;", &.{});
    try expectBindCodes("namespace C { const enum K { A } } let C: number;", &.{});
    // A value in the body makes it instantiated, and the clash is real again.
    // The code comes off the EXISTING symbol: a namespace is not a
    // `BlockScopedVariable`, so `namespace P {…} const P` is TS2300 while
    // `const V; namespace V {…}` is TS2451 (both oracle-verified).
    const dup2: []const Code = &.{ .duplicate_identifier, .duplicate_identifier };
    try expectBindCodes("namespace P { export const v = 1; } const P = 2;", dup2);
    try expectBindCodes("namespace Q { function f() {} } const Q = 2;", dup2);
    try expectBindCodes("namespace R { enum K { A } } const R = 2;", dup2);
    try expectBindCodes("namespace S { namespace In { export class C {} } } const S = 2;", dup2);
    try expectBindCodes(
        "const V = 2; namespace V { export const v = 1; }",
        &.{ .block_scoped_redeclare, .block_scoped_redeclare },
    );
    // The flag is an AND over merged blocks, not an OR: one instantiated block
    // makes the whole symbol a value module whichever order it is bound in.
    // Both namespace blocks are declarations of the name, so the clash names
    // all three spellings.
    const dup3: []const Code = &.{ .duplicate_identifier, .duplicate_identifier, .duplicate_identifier };
    try expectBindCodes("namespace T { type A = number; } namespace T { export const v = 1; } const T = 2;", dup3);
    try expectBindCodes("namespace U { export const v = 1; } namespace U { type A = number; } const U = 2;", dup3);
}

test "dup: two function implementations is TS2393, overloads are fine" {
    const impl2: []const Code = &.{ .duplicate_function_implementation, .duplicate_function_implementation };
    try expectBindCodes("function f() {} function f() {}", impl2);
    try expectBindCodes("function f(): void; function f() {}", &.{});
    try expectBindCodes(
        "class C { m(): void; m(a: number): void; m(a?: number) {} }",
        &.{},
    );
    try expectBindCodes("class C { m() {} m() {} }", impl2);
    // The overload SIGNATURE is a declaration of the name too, so it is named
    // alongside both implementations (oracle-verified: three TS2393s).
    try expectBindCodes(
        "function f(): void; function f() {} function f() {}",
        &.{ .duplicate_function_implementation, .duplicate_function_implementation, .duplicate_function_implementation },
    );
}

test "dup: duplicate parameters are TS2300 (strict mode)" {
    const dup2: []const Code = &.{ .duplicate_identifier, .duplicate_identifier };
    try expectBindCodes("function f(a: number, a: string) {}", dup2);
    try expectBindCodes("function f([a, b]: any, { a: a2, c: a }: any) {}", dup2);
}

test "dup: import conflicts are TS2440, duplicate imports TS2300" {
    // TS2440 names the IMPORT declaration and nothing else, in either
    // order — the message *is* "Import declaration conflicts with local
    // declaration of 'a'" (oracle-verified in both orders).
    try expectBindCodes("import { a } from \"./m\"; let a = 1;", &.{.import_conflict});
    try expectBindCodes("let a = 1; import { a } from \"./m\";", &.{.import_conflict});
    // Two imports of one name are an ordinary duplicate, at both spellings.
    try expectBindCodes(
        "import { a } from \"./m\"; import { a } from \"./n\";",
        &.{ .duplicate_identifier, .duplicate_identifier },
    );
    // Type-only imports live in type space only.
    try expectBindCodes("import type { T } from \"./m\"; let T = 1;", &.{});
    try expectBindCodes("import type { T } from \"./m\"; type T = number;", &.{.import_conflict});
}

test "dup: a name repeated across MERGING blocks is not a duplicate" {
    // Two `interface I` blocks (and a class + interface pair) share one
    // member table; a same-named member merges there and a type conflict is
    // TS2717, not TS2300. Within one block it is still a duplicate.
    try expectBindCodes("interface I { a: number; } interface I { a: string; }", &.{});
    try expectBindCodes("class C { p: number; } interface C { p: string; }", &.{});
    try expectBindCodes(
        "interface I { a: number; a: string; }",
        &.{ .duplicate_identifier, .duplicate_identifier },
    );
    // An object-type literal is its own block.
    try expectBindCodes(
        "type T = { a: number; a: string; };",
        &.{ .duplicate_identifier, .duplicate_identifier },
    );
}

test "dup: a duplicate type parameter names only the later one" {
    // tsc catches these in `checkTypeParameters`, comparing each parameter
    // against its predecessors — so only the second is reported.
    try expectBindCodes("interface I<T, T> {}", &.{.duplicate_identifier});
    try expectBindCodes("class C<T, T> {}", &.{.duplicate_identifier});
    try expectBindCodes("function f<T, T>() {}", &.{.duplicate_identifier});
    try expectBindCodes("type A<T, T> = T;", &.{.duplicate_identifier});
}

test "dup: two constructor implementations are TS2392, not TS2393" {
    try expectBindCodes(
        "class C { constructor(a: number) {} constructor(b: string) {} }",
        &.{ .duplicate_constructor_implementation, .duplicate_constructor_implementation },
    );
    try expectBindCodes("class C { constructor(); constructor(a?: number) {} }", &.{});
    try testing.expectEqual(@as(u16, 2392), Code.duplicate_constructor_implementation.tsCode());
}

test "dup: catch-clause redeclaration is TS2492, var escape is allowed" {
    // The one code that is NOT repeated at every spelling: tsc marks the
    // redeclaration and leaves the `catch (e)` binding alone.
    try expectBindCodes("try {} catch (e) { let e; }", &.{.catch_redeclare});
    try expectBindCodes("try {} catch (e) { var e; }", &.{});
}

test "dup: type-space clashes" {
    const dup2: []const Code = &.{ .duplicate_identifier, .duplicate_identifier };
    try expectBindCodes("interface I {} type I = number;", dup2);
    try expectBindCodes("type T = number; type T = string;", dup2);
    try expectBindCodes("class C {} type C = number;", dup2);
    // Value/type space sharing is legal (one merged symbol).
    try expectBindCodes("var x = 1; interface x {}", &.{});
    try expectBindCodes("function f() {} interface f {}", &.{});
}

test "dup: class members" {
    const dup2: []const Code = &.{ .duplicate_identifier, .duplicate_identifier };
    try expectBindCodes("class C { x: number; x: string; }", dup2);
    try expectBindCodes("class C { x: number; m() {} }", &.{});
    // Instance and static sides are separate tables.
    try expectBindCodes("class C { x: number; static x: string; }", &.{});
    // get/set pairs merge silently.
    try expectBindCodes("class C { get v(): number { return 1; } set v(n: number) {} }", &.{});
    try expectBindCodes("interface I { a: number; a: string; }", dup2);
}

// --- flow graph structure -----------------------------------------------------

test "flow: if/else join has both assignment antecedents" {
    var t = try TestBind.init("let x = 1; if (c) { x = 2; } else { x = 3; } x;");
    defer t.deinit();
    const read = t.identNode("x", 3).?; // decl, =2 target, =3 target, read
    const flow = t.b.flowAt(read).?;
    try testing.expectEqual(FlowTag.branch_label, t.b.flow_tags[flow]);
    const antes = t.b.flowAntecedents(flow);
    try testing.expectEqual(@as(usize, 2), antes.len);
    for (antes) |a| try testing.expectEqual(FlowTag.assign, t.b.flow_tags[a]);
}

test "flow: while loop head has entry and loop-back antecedents" {
    var t = try TestBind.init("let i = 0; while (c) { i = i + 1; } i;");
    defer t.deinit();
    const read = t.identNode("i", 3).?; // decl, =target, read in i+1, final read
    const flow = t.b.flowAt(read).?;
    // Exiting the loop: the false branch of the condition.
    try testing.expectEqual(FlowTag.cond_false, t.b.flow_tags[flow]);
    const loop = t.b.flowAntecedents(flow)[0];
    try testing.expectEqual(FlowTag.loop_label, t.b.flow_tags[loop]);
    const antes = t.b.flowAntecedents(loop);
    try testing.expectEqual(@as(usize, 2), antes.len); // entry + back edge
    var has_assign_back_edge = false;
    for (antes) |a| {
        if (t.b.flow_tags[a] == .assign) has_assign_back_edge = true;
    }
    try testing.expect(has_assign_back_edge);
}

test "flow: statements after an early return are unreachable" {
    var t = try TestBind.init("function f(x: number) { if (x) { return; } x; } function g(y: number) { return; y; }");
    defer t.deinit();
    // In f, `x;` after the conditional return is reachable (join of the
    // false branch); in g, `y;` is dead.
    const x_read = t.identNode("x", 2).?; // param, cond, read
    try testing.expect(t.b.flowAt(x_read).? != unreachable_flow);
    const y_read = t.identNode("y", 1).?; // param, read
    try testing.expectEqual(unreachable_flow, t.b.flowAt(y_read).?);
}

test "flow: switch fallthrough joins, break isolates" {
    var t = try TestBind.init("let a = 0; switch (v) { case 1: a; break; case 2: a = 1; case 3: a; }");
    defer t.deinit();
    // Read in case 1: only the switch_clause flow reaches it (no fallthrough).
    const first = t.identNode("a", 1).?;
    const f1 = t.b.flowAt(first).?;
    try testing.expectEqual(FlowTag.switch_clause, t.b.flow_tags[f1]);
    // Read in case 3: fallthrough from case 2's assignment joins the clause.
    const third = t.identNode("a", 3).?;
    const f3 = t.b.flowAt(third).?;
    try testing.expectEqual(FlowTag.branch_label, t.b.flow_tags[f3]);
    const antes = t.b.flowAntecedents(f3);
    try testing.expectEqual(@as(usize, 2), antes.len);
    var tags: [2]FlowTag = undefined;
    for (antes, 0..) |a, i| tags[i] = t.b.flow_tags[a];
    try testing.expect((tags[0] == .assign and tags[1] == .switch_clause) or
        (tags[0] == .switch_clause and tags[1] == .assign));
}

test "flow: && decomposes conditions for narrowing" {
    var t = try TestBind.init("if (a && b) { c; }");
    defer t.deinit();
    const read = t.identNode("c", 0).?;
    const flow = t.b.flowAt(read).?;
    // Inside the then-branch: true of `b`, whose antecedent is true of `a`.
    try testing.expectEqual(FlowTag.cond_true, t.b.flow_tags[flow]);
    const prev = t.b.flowAntecedents(flow)[0];
    try testing.expectEqual(FlowTag.cond_true, t.b.flow_tags[prev]);
}

// --- resolve() & unresolved references -----------------------------------------

test "resolve: shadowing chain picks the innermost symbol" {
    var t = try TestBind.init("let a = 1; function f() { let a = 2; { let a = 3; } }");
    defer t.deinit();
    const a = try t.atom("a");
    // Scopes: 0 file, 1 function f, 2 inner block.
    const file_sym = t.b.resolve(a, 0).?;
    const fn_sym = t.b.resolve(a, 1).?;
    const blk_sym = t.b.resolve(a, 2).?;
    try testing.expect(file_sym != fn_sym and fn_sym != blk_sym);
    try testing.expectEqual(@as(ScopeId, 0), t.b.symbol_scopes[file_sym]);
    try testing.expectEqual(@as(ScopeId, 1), t.b.symbol_scopes[fn_sym]);
    try testing.expectEqual(@as(ScopeId, 2), t.b.symbol_scopes[blk_sym]);
    // A name only in the file scope resolves from the inner block.
    const f_atom = try t.atom("f");
    try testing.expectEqual(t.b.resolve(f_atom, 0).?, t.b.resolve(f_atom, 2).?);
    // Unknown names resolve to null.
    const nope = try t.atom("nope");
    try testing.expectEqual(@as(?SymbolId, null), t.b.resolve(nope, 2));
}

test "resolve: hoisted var and params resolve from nested blocks" {
    var t = try TestBind.init("function f(p: number) { { var v = p; } return v; }");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "resolve: forward references to hoisted declarations resolve" {
    var t = try TestBind.init("f(); function f() {} let i: I; interface I {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "unresolved: iteration order and contents" {
    var t = try TestBind.init("foo(bar); let baz = qux; type T = Missing;");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 4), t.b.unresolved.len);
    try testing.expectEqual(try t.atom("foo"), t.b.unresolved[0].atom);
    try testing.expectEqual(try t.atom("bar"), t.b.unresolved[1].atom);
    try testing.expectEqual(try t.atom("qux"), t.b.unresolved[2].atom);
    try testing.expectEqual(try t.atom("Missing"), t.b.unresolved[3].atom);
    // Intrinsic type names and `undefined` are not references.
    var t2 = try TestBind.init("let a: number = undefined; let b: string | null;");
    defer t2.deinit();
    try testing.expectEqual(@as(usize, 0), t2.b.unresolved.len);
}

test "symbols: TDZ position is recorded via the first decl node" {
    var t = try TestBind.init("let x = 1;");
    defer t.deinit();
    const x = try t.atom("x");
    const sym = t.b.resolve(x, 0).?;
    const decls = t.b.declsOf(sym);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqual(ast.Tag.declarator_init, t.tree.nodeTag(decls[0]));
}

test "records: member scopes are queryable for classes and interfaces" {
    var t = try TestBind.init("class C { m() {} static s() {} } interface I { p: number; }");
    defer t.deinit();
    const c_sym = t.b.resolve(try t.atom("C"), 0).?;
    const i_sym = t.b.resolve(try t.atom("I"), 0).?;
    const cm = t.b.membersScopeOf(c_sym).?;
    const cs = t.b.staticsScopeOf(c_sym).?;
    const im = t.b.membersScopeOf(i_sym).?;
    try testing.expect(t.b.lookupInScope(cm, try t.atom("m")) != null);
    try testing.expect(t.b.lookupInScope(cs, try t.atom("s")) != null);
    try testing.expect(t.b.lookupInScope(im, try t.atom("p")) != null);
    try testing.expectEqual(@as(?ScopeId, null), t.b.staticsScopeOf(i_sym));
}

// --- stress: the binder is total on arbitrary parser output ---------------------

/// Oracle: binding any parse tree terminates and produces internally
/// consistent, in-bounds output.
fn checkBinderOnArbitraryBytes(alloc: Allocator, interner: *Interner, input: []const u8) !void {
    const tree = parser.parse(alloc, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SourceTooLarge => unreachable,
    };
    const b = try bind(alloc, testing.io, testing.allocator, interner, &tree, input, false);

    const n_syms = b.symbol_names.len;
    const n_scopes = b.scope_parents.len;
    const n_flows = b.flow_tags.len;
    try testing.expect(n_syms >= 1 and n_scopes >= 1 and n_flows >= 3);
    try testing.expectEqual(n_syms + 1, b.symbol_decls_start.len);
    try testing.expectEqual(n_scopes + 1, b.scope_members_start.len);

    for (b.symbol_scopes) |s| try testing.expect(s < n_scopes);
    for (0..n_syms) |i| {
        try testing.expect(b.symbol_decls_start[i] <= b.symbol_decls_start[i + 1]);
    }
    try testing.expectEqual(@as(usize, b.symbol_decls_start[n_syms]), b.symbol_decls.len);
    for (b.symbol_decls) |n| try testing.expect(n < tree.nodes.len);

    for (b.scope_parents, 0..) |p, i| {
        try testing.expect(p < n_scopes);
        if (i > 0) try testing.expect(p < i); // parents precede children
    }
    for (0..n_scopes) |s| {
        const lo = b.scope_members_start[s];
        const hi = b.scope_members_start[s + 1];
        try testing.expect(lo <= hi);
        // Sorted-by-atom segments (binary-search invariant).
        var j = lo;
        while (j + 1 < hi) : (j += 1) {
            try testing.expect(b.member_atoms[j] < b.member_atoms[j + 1]);
        }
    }
    try testing.expectEqual(@as(usize, b.scope_members_start[n_scopes]), b.member_atoms.len);
    for (b.member_syms) |sym| try testing.expect(sym != 0 and sym < n_syms);

    for (0..n_flows) |f| {
        switch (b.flow_tags[f]) {
            .branch_label, .loop_label => {
                try testing.expect(b.flow_a[f] <= b.flow_b[f]);
                try testing.expect(b.flow_b[f] <= b.flow_extra.len);
                for (b.flow_extra[b.flow_a[f]..b.flow_b[f]]) |a| {
                    try testing.expect(a < n_flows);
                }
            },
            .assign, .cond_true, .cond_false, .switch_clause, .switch_no_match, .call_stmt => {
                try testing.expect(b.flow_a[f] < n_flows);
                try testing.expect(b.flow_b[f] < tree.nodes.len);
            },
            .none, .unreachable_, .start => {},
        }
    }
    var k: usize = 0;
    while (k + 1 < b.flow_map_nodes.len) : (k += 1) {
        try testing.expect(b.flow_map_nodes[k] <= b.flow_map_nodes[k + 1]);
    }
    for (b.flow_map_ids) |f| try testing.expect(f != 0 and f < n_flows);
    for (b.unresolved) |r| {
        try testing.expect(r.atom != 0);
        try testing.expect(r.scope < n_scopes);
        try testing.expect(r.node < tree.nodes.len);
    }
    for (b.diagnostics) |d| {
        try testing.expect(d.span.start <= input.len);
        try testing.expect(d.span.end <= input.len + 1);
    }
}

test "stress: bind deterministic random byte soup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0xb1d_2026);
    const random = prng.random();
    var buf: [384]u8 = undefined;
    for (0..400) |_| {
        const n = random.uintLessThan(usize, buf.len + 1);
        random.bytes(buf[0..n]);
        try checkBinderOnArbitraryBytes(arena.allocator(), &interner, buf[0..n]);
        _ = arena.reset(.retain_capacity);
    }
}

test "stress: bind token soup (valid tokens, random order)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x70cc_2027);
    const random = prng.random();

    const vocab = [_][]const u8{
        "if",      "else",       "for",       "while",     "return",   "function",    "class",  "const",
        "let",     "var",        "interface", "type",      "import",   "export",      "new",    "typeof",
        "extends", "implements", "as",        "satisfies", "keyof",    "in",          "of",     "async",
        "await",   "yield",      "static",    "private",   "readonly", "this",        "super",  "null",
        "true",    "false",      "x",         "y",         "foo",      "Bar",         "42",     "3.14",
        "\"s\"",   "`t`",        "`a${",      "}",         "{",        "}",           "(",      ")",
        "[",       "]",          ";",         ",",         ":",        "?",           ".",      "?.",
        "...",     "=>",         "=",         "+",         "-",        "*",           "/",      "%",
        "**",      "==",         "===",       "!=",        "<",        ">",           "<=",     ">=",
        "<<",      ">>",         ">>>",       "&&",        "||",       "??",          "!",      "~",
        "&",       "|",          "^",         "++",        "--",       "+=",          "??=",    "@",
        "#",       "\\",         "enum",      "namespace", "declare",  "abstract",    "0x1n",   "/re/g",
        "break",   "continue",   "switch",    "case",      "default",  "try",         "catch",  "finally",
        "throw",   "do",         "get",       "set",       "from",     "constructor", "label:", "undefined",
    };

    var buf: [2048]u8 = undefined;
    for (0..300) |_| {
        var len: usize = 0;
        const count = random.uintLessThan(usize, 120);
        for (0..count) |_| {
            const word = vocab[random.uintLessThan(usize, vocab.len)];
            if (len + word.len + 1 > buf.len) break;
            @memcpy(buf[len..][0..word.len], word);
            len += word.len;
            buf[len] = if (random.uintLessThan(u8, 6) == 0) '\n' else ' ';
            len += 1;
        }
        try checkBinderOnArbitraryBytes(arena.allocator(), &interner, buf[0..len]);
        _ = arena.reset(.retain_capacity);
    }
}

test "stress: bind pathological nesting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    // Deep blocks: {{{{ ... }}}} — one scope per block.
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(testing.allocator);
    for (0..200) |_| try s.appendSlice(testing.allocator, "{ let x = 1; ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
    _ = arena.reset(.retain_capacity);
    // Deep expression nesting.
    s.clearRetainingCapacity();
    try s.appendSlice(testing.allocator, "x = ");
    for (0..200) |_| try s.appendSlice(testing.allocator, "(a && ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
    _ = arena.reset(.retain_capacity);
    // Deep unclosed loops.
    s.clearRetainingCapacity();
    for (0..100) |_| try s.appendSlice(testing.allocator, "while (c) { for (;;) ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
}

fn fuzzBinderOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, '=', 3),
        .value(u8, ';', 3),
        .value(u8, '\n', 3),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, source_buf[0..len]);
}

test "fuzz: binder on arbitrary bytes" {
    try testing.fuzz({}, fuzzBinderOne, .{});
}

test "memory: sealed byte accounting is consistent" {
    var t = try TestBind.init(
        \\import { a } from "./m";
        \\export function f(x: number): number {
        \\  let total = 0;
        \\  for (let i = 0; i < x; i++) { total = total + a; }
        \\  return total;
        \\}
    );
    defer t.deinit();
    try testing.expect(t.b.symbolBytes() > 0);
    try testing.expect(t.b.scopeBytes() > 0);
    try testing.expect(t.b.flowBytes() > 0);
    try testing.expect(t.b.recordBytes() > 0);
    try testing.expectEqual(
        t.b.symbolBytes() + t.b.scopeBytes() + t.b.flowBytes() + t.b.recordBytes(),
        t.b.totalBytes(),
    );
    // SoA sanity: 12 fixed bytes per symbol + starts + decls.
    const n = t.b.symbol_names.len;
    try testing.expectEqual(
        n * 12 + (n + 1) * 4 + t.b.symbol_decls.len * 4,
        t.b.symbolBytes(),
    );
}

test "records: exported overloads produce a single export record" {
    var t = try TestBind.init("export function f(): void; export function f() {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), t.b.exports.len);
    try testing.expectEqual(@as(usize, 2), t.b.declsOf(t.b.exports[0].sym).len);
}
