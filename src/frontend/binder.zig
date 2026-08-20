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
const numeric_lit = @import("../numeric_lit.zig");
const diagnostics = @import("diagnostics.zig");
const literals = @import("literals.zig");
const default_exports = @import("default_exports.zig");
const member_names = @import("member_names.zig");
const decl_spaces = @import("decl_spaces.zig");
const impl_expected = @import("impl_expected.zig");
const index_signature = @import("index_signature.zig");
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
pub const AliasMerge = bind_result.AliasMerge;
pub const Bind = bind_result.Bind;

const Error = error{OutOfMemory};

const fbits = bind_result.fbits;
const effectiveBits = bind_result.effectiveBits;
const excludesOfFlags = bind_result.excludesOfFlags;
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

/// An ECMAScript `#name` member carries no modifier at all, but it is
/// non-public in the one sense `Symbol.non_public` (and the
/// `prop_flag_non_public` the checker derives from it) is FOR: it belongs to
/// the class that declared it and to no other, so the structural relation, the
/// `keyof` key list and the object-spread filter must all screen it out
/// (`nominal_members.zig` carries the wave-22 oracle for every shape).
///
/// The test is on the TOKEN TAG, never on the name text — `#x` and a quoted
/// `{"#x": 1}` key intern to the same atom, and a name read would take the
/// interner's shard mutex on a per-member path (see `nominal_members.zig`'s
/// COST note). A member declaration is bound once, so this costs one tag load.
///
/// `accessOfMember` reads the MODIFIERS, so a `#name` still answers `.public`
/// there and the TS2341/TS2445 access rules stay off it: an access from
/// outside is `accessibility.checkPrivateName`'s TS18013, as before.
fn isPrivateNameToken(b: *const Binder, tok: TokenIndex) bool {
    return b.tree.tokens.tag(tok) == .private_identifier;
}

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
    ///
    /// Every kind's mask is a pure function of the FLAGS it contributes, so the
    /// rule has one definition (`bind_result.excludesOfFlags`) shared with the
    /// linker's cross-file global merge, which only ever sees folded flags.
    fn excludes(k: DeclKind) u32 {
        return excludesOfFlags(k.flags());
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
    try b.sym_local_bits.append(b.scratch, 0);
    try b.sym_exported_bits.append(b.scratch, 0);
    try b.decl_links.append(b.scratch, .{ .value = 0, .next = 0 });
    try b.decl_name_toks.append(b.scratch, 0);
    try b.decl_origins.append(b.scratch, .{ .block = 0, .exported = false, .ambient = false });
    try b.ante_links.append(b.scratch, .{ .value = 0, .next = 0 });

    try b.scope_parents.append(b.scratch, 0);
    try b.scope_kinds.append(b.scratch, .file);
    try b.scope_owners.append(b.scratch, 0);

    try b.addFlowRaw(.none, 0, 0); // flow 0
    try b.addFlowRaw(.unreachable_, 0, 0); // flow 1
    b.cur_flow = try b.addFlow(.start, no_flow, 0); // file entry

    // Bind all top-level statements of the root.
    try b.recordOverloadSiblings(tree.nodeRange(0));
    for (tree.nodeRange(0)) |stmt| {
        if (stmt != null_node) try b.bindStatement(stmt);
    }

    // Post-bind checks over a name's whole declaration SET: each one is a
    // property of the set rather than of any single declaration, so each runs
    // once the last declaration is in.
    try b.checkMergedExports();
    try b.checkRedeclaredExports();
    try b.checkMissingImplementations();
    try b.checkEnumFirstMembers();
    try b.checkNamespacePriorToMerge();
    try b.checkThisBeforeSuper();
    try b.collectAliasMerges();
    return b.seal();
}

const Link = struct { value: u32, next: u32 };

/// The IDENTIFIER an evolving-array operation is rooted at, or `null_node`.
///
/// tsc's `isNarrowableOperand` read in the `getReferenceRoot` direction: a
/// parenthesized expression, the left of an `=` and the right of a comma all
/// stand for the reference inside them, so `(x = [], x).push(5)` and
/// `((x))[3] = v` mutate the same `x` a bare `x.push(5)` does
/// (`controlFlowArrays.ts` f16). Narrowed to a plain identifier root because
/// only a variable ever holds an evolving array.
///
/// Shared: the binder decides which reads to record and which calls advance
/// the flow, and the checker has to find the same identifier again from the
/// mutation node it stored.
pub fn narrowableOperandIdent(tree: *const Ast, expr: Node) Node {
    var e = expr;
    while (e != null_node) {
        const d = tree.nodeData(e);
        switch (tree.nodeTag(e)) {
            .identifier => return e,
            .paren_expr => e = d.lhs,
            .assign => {
                if (tree.tokens.tag(tree.nodeMainToken(e)) != .eq) return null_node;
                e = d.lhs;
            },
            .seq_expr => e = d.rhs,
            else => return null_node,
        }
    }
    return null_node;
}

/// Where one declaration of a symbol was bound: which `cur_block` it sat in,
/// whether it carried an `export` modifier, and whether it was in an AMBIENT
/// context. Packed into one word because there is one per declaration of every
/// symbol in the file — see `decl_origins`. (A block is an AST node index;
/// `u30` bounds it at 2^30 nodes, three orders of magnitude past the largest
/// file either compiler will parse.)
const DeclOrigin = packed struct(u32) {
    exported: bool,
    ambient: bool,
    block: u30,
};
const Pending = struct { head: u32 = 0, tail: u32 = 0, count: u32 = 0 };
const PendingId = u32;
/// The non-list half of a `reduce_label` (see `Binder.reduce_edges`).
const ReduceEdges = struct { target: FlowId, antecedent: FlowId };

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

/// The first `export = <entity>` of one container: where to point the duplicate
/// diagnostic, and whether it has already been pointed at (a THIRD export
/// assignment must not name the first one twice).
const ExportEqNote = struct { tok: TokenIndex, reported: bool = false };

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
    /// Where each `decl_links` entry came from: the declaration BLOCK it was
    /// bound in, whether it carried an `export` modifier, and whether it was in
    /// an AMBIENT context. tsc records the first two by splitting a container's
    /// members over an `exports` and a `locals` table; ztsc has one member table
    /// per scope, so the facts have to be carried per declaration for
    /// `checkMergedExports` (TS2395) to reconstruct the split, and the ambient
    /// bit for `checkMissingImplementations` (TS2391) to skip a `.d.ts`. Parallel
    /// to `decl_links` and, like it, scratch-only.
    decl_origins: std.ArrayList(DeclOrigin) = .empty,
    /// Flag bits contributed by the declarations of a symbol that did NOT carry
    /// an `export` modifier, within the block those declarations are in
    /// (`sym_block`; reset when the block changes). tsc's `locals` table entry
    /// for a container member, which an EXPORTED declaration fills with a
    /// placeholder of no meaning — see `priorFlags`. Scratch-only.
    sym_local_bits: std.ArrayList(u32) = .empty,
    /// The other half: flag bits contributed by the `export`ed declarations of
    /// a symbol — tsc's `exports` table entry for the name, which is SHARED by
    /// every block of a merging container and so is never reset. Read by
    /// `collectAliasMerges` for the meanings TS2440 compares against.
    /// Scratch-only.
    sym_exported_bits: std.ArrayList(u32) = .empty,

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
    /// Export-assignment container -> the first `export = <entity>` seen in it.
    /// tsc's binder declares `export=` as an ALIAS in the container's export
    /// table, where a second one is an ordinary duplicate (`AliasExcludes`
    /// covers `Alias`) reported at every declaration; ztsc keeps export
    /// assignments out of the symbol table (the linker reads the records
    /// directly), so this two-field note stands in for that table entry. See
    /// `bindExportAssign`. Scratch-only bookkeeping, never sealed.
    export_eq_first: std.AutoHashMapUnmanaged(ScopeId, ExportEqNote) = .empty,

    // flow under construction
    flow_tags: std.ArrayList(FlowTag) = .empty,
    flow_a: std.ArrayList(u32) = .empty,
    flow_b: std.ArrayList(u32) = .empty,
    flow_scopes: std.ArrayList(ScopeId) = .empty,
    pendings: std.ArrayList(Pending) = .empty,
    ante_links: std.ArrayList(Link) = .empty,
    /// The two extra edges a `reduce_label` carries (its target label and the
    /// node it continues at), indexed by that flow node's `flow_b`. Kept out
    /// of the SoA columns because it is the only tag needing four edges and
    /// there are a handful per file — `seal` flattens all three parts into one
    /// `flow_extra` range (see `FlowTag.reduce_label`).
    reduce_edges: std.ArrayList(ReduceEdges) = .empty,
    flow_pairs: std.ArrayList(Link) = .empty, // value=node, next=flow
    /// tsc's `isEvolvingArrayOperationTarget` reads, recorded while the PARENT
    /// is bound (the AST has no parent links). value = the identifier node,
    /// next = the index expression of an `x[i] = v` target or `null_node` for
    /// the `.length` / `.push` / `.unshift` property forms. See
    /// `Bind.array_op_nodes`.
    array_ops: std.ArrayList(Link) = .empty,
    /// `Bind.alias_merges`, filled by the post-pass `collectAliasMerges`.
    alias_merges: std.ArrayList(AliasMerge) = .empty,
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
    /// True while binding the parameter list or body of a constructor whose
    /// class has an `extends` clause that is not `null` — the one region tsc's
    /// `checkThisBeforeSuper` covers. `getThisContainer` is asked with
    /// `includeArrowFunctions`, so a `this` inside ANY nested function-like
    /// (arrow included) has a different container and is exempt; every
    /// `bindFunctionLike` therefore overwrites this, and `saveState` restores
    /// it. Measured: `constructor() { const f = () => this.a; super(); }` is
    /// clean, `constructor() { const o = { p: this }; super(); }` is not.
    in_derived_ctor: bool = false,
    /// Has a `super(…)` call been bound in the function-like body currently
    /// being walked? tsc's `findFirstSuperCall`, which searches a constructor's
    /// body and stops at every function-like node — so, exactly like
    /// `in_derived_ctor`, `bindFunctionLike` overwrites this on the way in and
    /// `saveState` restores it on the way out, which is what makes a `super()`
    /// in a nested arrow or function not count for the constructor around it
    /// (TS2377).
    saw_super_call: bool = false,
    /// The `this` expressions — and the `super`s that are not a call's callee,
    /// which earn the same rule under a different code — collected by that
    /// flag, each with the flow node in effect where it was written (tsc's
    /// `node.flowNode`). Answered once the whole file is bound
    /// (`checkThisBeforeSuper`), because a loop's back edges do not exist until
    /// its body has been walked. Accumulator, never sealed; empty for every
    /// file with no derived constructor.
    this_in_derived_ctor: std.ArrayList(Link) = .empty, // value = this_expr/super_expr node, next = flow
    /// For each BODYLESS function or method declaration, the declaration that
    /// immediately follows it in the same sibling list — tsc's
    /// `subsequentNode.pos === node.end`, which decides whether a missing
    /// implementation is TS2391 or one of the three sharper diagnostics
    /// (`overloadSiblingDiag`). Only a sibling list can answer the question and
    /// only a bodyless declaration can ask it, so it is recorded as the lists
    /// are walked and read once the file is bound. Accumulator, never sealed.
    overload_next: std.AutoHashMapUnmanaged(Node, Node) = .empty,
    /// The `.call_stmt` flow nodes that stand for a `super(...)` call. The tag
    /// is shared with assertion-call flows, so the walk needs the binder's own
    /// record of which is which; a file has a handful of super calls at most,
    /// so a linear scan is the whole data structure.
    super_call_flows: std.ArrayList(FlowId) = .empty,
    ctxs: std.ArrayList(Ctx) = .empty,
    /// Contexts below this index belong to enclosing functions.
    ctx_base: usize = 0,
    /// Set by a labeled statement wrapping a loop/switch.
    pending_label: Atom = 0,
    /// True while binding the name(s) of an `export`ed declaration.
    exporting_node: Node = 0,
    /// True while binding the DECLARATION under an `export default` — the
    /// modifier form (`export default class C {}`), not the expression one.
    ///
    /// Such a declaration publishes under the name `default`, never under `C`,
    /// so its local name carries no exported meaning: tsc's `locals` entry for
    /// it is the same meaningless placeholder every exported declaration gets,
    /// and the collision that DOES exist lives on the `default` export name
    /// (TS2528, `checkDefaultExportClashes`). Kept separate from
    /// `exporting_node` because that field also drives `noteExport`, and an
    /// export record under the local name would publish `C` as well.
    in_export_default: bool = false,
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
    ///
    /// A NUMERIC key is keyed by the string JavaScript names it by, not by how
    /// it was spelled: `{ 0: x }`, `{ 0.0: x }` and `{ "0": x }` all declare the
    /// member `0`, and `{ 0b11010: x }` declares `26`. Mirrors the checker's
    /// `memberAtom`, which must agree key for key.
    fn memberAtom(b: *Binder, tok: TokenIndex) Error!Atom {
        const text = b.tokenText(tok);
        switch (b.tree.tokens.tag(tok)) {
            // `.jsx_string` is a JSX attribute's quoted value; a
            // no-substitution template is a string literal for naming purposes
            // (tsc's `isStringLiteralLike`), so `` obj[`k`] `` keys under `k`.
            .string_literal, .jsx_string, .no_substitution_template_literal => return b.atomOf(stripQuotes(text)),
            .numeric_literal => {
                var buf: [numeric_lit.max_name]u8 = undefined;
                // Stack buffer: `atomOf` copies into the interner, but the
                // per-file `atom_cache` would keep the slice as a key, so probe
                // it and dupe on a miss (the same dance as `atomOfIdent`).
                const canon = numeric_lit.name(&buf, text);
                if (b.atom_cache.get(canon)) |a| return a;
                return b.atomOf(try b.scratch.dupe(u8, canon));
            },
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

    /// Does this member's flag word say its computed name names NOTHING?
    ///
    /// tsc's `bindPropertyOrMethodOrAccessor` routes a member with a dynamic
    /// name through `bindAnonymousDeclaration(node, …, InternalSymbolName.Computed)`
    /// instead of `declareSymbolAndAddToSymbolTable`, so the member never enters
    /// its container's symbol table; only the *late-binding* pass, which handles
    /// the string-literal / numeric-literal / `unique symbol` keys, puts one
    /// back. `ast.Flags.computed_expr` marks exactly the residue, and the
    /// member's `main_token` is its `[` — an atom nothing should ever be keyed
    /// by, which is why declaring one made every such member in a body collide
    /// with the next under a TS2300.
    fn nameless(flags: u32) bool {
        return flags & ast.Flags.computed_expr != 0;
    }

    /// Bind a member's retained computed-key EXPRESSION (`ast.Ast.computedKey`).
    /// The key is evaluated where the member is written, so it binds in the
    /// enclosing scope like any other expression there; without this the
    /// checker's `computed_key.zig` walk would find unresolved names in it.
    fn bindComputedKey(b: *Binder, member: Node, flags: u32) Error!void {
        if (flags & (ast.Flags.computed | ast.Flags.computed_sym | ast.Flags.computed_expr) == 0) return;
        const key = b.tree.computedKey(member) orelse return;
        try b.bindExpr(b.tree.nodeData(key).lhs);
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
    /// One copy of the rule, in `literals.zig`, so the parser's numeric-name
    /// check and the member atom a quoted name interns to cannot disagree.
    const stripQuotes = literals.stripQuotes;

    fn tokSpan(b: *Binder, tok: TokenIndex) Span {
        const start = b.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(b.src, b.tree.tokens.tag(tok), start) };
    }

    fn diag(b: *Binder, code: Code, tok: TokenIndex) Error!void {
        try b.diags.append(b.scratch, .{ .code = code, .span = b.tokSpan(tok) });
    }

    /// A diagnostic whose message interpolates the text of ANOTHER token —
    /// `Diagnostic.arg`, the parser's `errAtSpanArg` on this side of the fence.
    /// Only for codes whose template carries a `{0}` naming something other
    /// than the span it is reported on.
    fn diagArg(b: *Binder, code: Code, tok: TokenIndex, arg_tok: TokenIndex) Error!void {
        try b.diags.append(b.scratch, .{ .code = code, .span = b.tokSpan(tok), .arg = b.tokSpan(arg_tok) });
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
        in_derived_ctor: bool,
        saw_super_call: bool,
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
            .in_derived_ctor = b.in_derived_ctor,
            .saw_super_call = b.saw_super_call,
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
        b.in_derived_ctor = s.in_derived_ctor;
        b.saw_super_call = s.saw_super_call;
    }

    // --- symbols ------------------------------------------------------------

    fn appendDecl(b: *Binder, sym: SymbolId, node: Node, name_tok: TokenIndex) Error!void {
        const link: u32 = @intCast(b.decl_links.items.len);
        try b.decl_links.append(b.scratch, .{ .value = node, .next = 0 });
        try b.decl_name_toks.append(b.scratch, name_tok);
        try b.decl_origins.append(b.scratch, .{
            .block = @intCast(b.cur_block),
            .exported = b.exporting_node != 0,
            .ambient = b.ambient,
        });
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

    /// The token a DUPLICATE-NAME diagnostic points at for the declaration
    /// `decl` whose name token is `name_tok`.
    ///
    /// For an ordinary member they are the same token. For a COMPUTED one they
    /// are not: `name_tok` is the key's last identifier (`iterator` in
    /// `[Symbol.iterator]`, `staticProp` in `[C1.staticProp]`) because that is
    /// what the member name is derived from, while tsc reports at the whole
    /// computed-name node — whose first token is the `[`. Walks back over the
    /// key's `a.b.c` run, so it answers `name_tok` unchanged for anything that
    /// is not that shape.
    ///
    /// Report-time only: every caller is a diagnostic path, so a declaration
    /// that never clashes pays nothing.
    fn dupDiagTok(b: *Binder, decl: Node, name_tok: TokenIndex) TokenIndex {
        if (decl == null_node or name_tok == 0) return name_tok;
        if (!declNameIsComputed(b, decl)) return name_tok;
        var t = name_tok;
        const floor = if (name_tok > 8) name_tok - 8 else 1;
        while (t > floor) {
            t -= 1;
            switch (b.tree.tokens.tag(t)) {
                .l_bracket => return t,
                .identifier, .dot => {},
                else => return name_tok,
            }
        }
        return name_tok;
    }

    /// Is this member declaration's name a computed one (`[expr]`)? The flag word
    /// sits in a different place for each member shape — the same places
    /// `bindClassMembers` and `bindTypeMember` read it from when they build the
    /// member key.
    fn declNameIsComputed(b: *Binder, decl: Node) bool {
        const d = b.tree.nodeData(decl);
        const flags: u32 = switch (b.nodeTag(decl)) {
            .class_field => b.tree.extraData(ast.Field, d.lhs).flags,
            .class_method => b.tree.extraData(ast.FnProto, d.lhs).flags,
            .property_signature, .method_signature => d.rhs,
            else => return false,
        };
        return flags & (ast.Flags.computed | ast.Flags.computed_sym) != 0;
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
        // Two import bindings of one name are an ordinary duplicate; an import
        // beside a local declaration is no binder clash at all (the excludes
        // table merges them, and TS2440 is the checker's — see
        // `checker/alias_conflict.zig`).
        if (existing.import_binding or kind.isImport()) return .duplicate_identifier;
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
            // Two blocks of one namespace share ztsc's body scope, but tsc gives
            // each `ModuleDeclaration` its own `locals` and merges only the
            // EXPORTED members (into the namespace symbol's `exports`). So two
            // NON-EXPORTED locals of the same name in different blocks are two
            // unrelated symbols to tsc and no duplicate at all:
            //
            //     namespace F { class Helper {} }
            //     namespace F { class Helper {} }   // legal
            //
            // (`duplicateAnonymousModuleClasses`). It takes BOTH sides in the
            // shared `exports` table to clash, so a non-exported block-local
            // beside an `export`ed one is legal too (`moduleMerge`) — while every
            // member of a `declare namespace` is implicitly exported
            // (`exporting_node` is pinned to the block) and still reported.
            .namespace => {
                const new_exported = b.exporting_node != 0;
                const old_exported = b.sym_flags.items[sym].exported;
                if (new_exported and old_exported) return false;
            },
            else => return false,
        }
        return b.sym_block.items[sym] != b.cur_block;
    }

    fn reportDuplicate(b: *Binder, sym: SymbolId, code: Code, decl: Node, name_tok: TokenIndex) Error!void {
        const already = b.sym_reported.items[sym];
        var link = b.sym_decl_head.items[sym];
        var i: u32 = 0;
        while (link != 0) : (link = b.decl_links.items[link].next) {
            const l = b.decl_links.items[link];
            if (i >= already) try b.diag(code, b.dupDiagTok(l.value, b.decl_name_toks.items[link]));
            i += 1;
        }
        try b.diag(code, b.dupDiagTok(decl, name_tok));
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

        const gop = try b.members.getOrPut(b.scratch, memberKey(scope, atom));
        if (gop.found_existing) {
            const sym = gop.value_ptr.*;
            const existing = b.sym_flags.items[sym];
            // A container's `locals` table is per BLOCK: reopening a namespace
            // starts a fresh one.
            if (b.sym_block.items[sym] != b.cur_block) b.sym_local_bits.items[sym] = 0;
            const prior = b.priorFlags(scope, sym, existing);
            if (effectiveBits(prior) & kind.excludes() != 0 and
                !b.mergesAcrossBlocks(scope, sym))
            {
                const code = dupCode(prior, kind);
                switch (code) {
                    // TS2492 names the REDECLARATION alone and leaves the
                    // `catch (e)` binding unmarked; a duplicate TYPE
                    // PARAMETER likewise names only the later one (tsc
                    // catches that one in `checkTypeParameters`, comparing
                    // each against its predecessors, not in `declareSymbol`).
                    .catch_redeclare => try b.diag(code, name_tok),
                    else => if (kind == .type_param or existing.type_param)
                        try b.diag(code, name_tok)
                    else
                        try b.reportDuplicate(sym, code, decl_node, name_tok),
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
                    try b.reportDuplicate(sym, code, decl_node, name_tok);
                }
                try b.checkFunctionClassMerge(sym, existing, flags, name_tok);
            } else if (kind == .class) {
                try b.checkFunctionClassMerge(sym, existing, flags, name_tok);
            }
            b.sym_flags.items[sym] = existing.merge(flags);
            b.sym_block.items[sym] = b.cur_block;
            if (b.declaresLocalMeaning())
                b.sym_local_bits.items[sym] |= flags.bits()
            else
                b.sym_exported_bits.items[sym] |= flags.bits();
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
        const local_meaning = b.declaresLocalMeaning();
        try b.sym_local_bits.append(b.scratch, if (local_meaning) flags.bits() else 0);
        try b.sym_exported_bits.append(b.scratch, if (local_meaning) 0 else flags.bits());
        gop.value_ptr.* = sym;
        try b.appendDecl(sym, decl_node, name_tok);
        try b.noteExport(sym, atom, scope);
        return sym;
    }

    /// The export context a nested container BODY runs under: none. `export`
    /// and `export default` apply to the declaration they wrap, never to the
    /// declarations inside its body (tsc gets this from `container` moving), so
    /// every site that pushes a function/class/namespace body clears both flags
    /// and restores them on the way out.
    const ExportCtx = struct { node: Node, default: bool };

    fn clearExportCtx(b: *Binder) ExportCtx {
        const saved: ExportCtx = .{ .node = b.exporting_node, .default = b.in_export_default };
        b.exporting_node = 0;
        b.in_export_default = false;
        return saved;
    }

    fn restoreExportCtx(b: *Binder, saved: ExportCtx) void {
        b.exporting_node = saved.node;
        b.in_export_default = saved.default;
    }

    /// Does the declaration being bound put a MEANING in its container's
    /// `locals` table? An `export`ed one does not — tsc leaves a placeholder
    /// there and declares the meaning in `exports` — and an `export default`
    /// declaration does not either, for the same reason under a different name
    /// (see `in_export_default`).
    fn declaresLocalMeaning(b: *const Binder) bool {
        return b.exporting_node == 0 and !b.in_export_default;
    }

    /// The flags a new declaration's `excludes` mask is tested against: which
    /// of the name's EARLIER declarations can displace it.
    ///
    /// Everywhere but a module/namespace container that is simply the symbol's
    /// accumulated flags. A container, though, has TWO symbol tables in tsc —
    /// `exports` and `locals` — and an `export`ed member is declared in
    /// `exports` with its full meaning while `locals` gets a placeholder of no
    /// meaning at all (`ExportValue` for a value, nothing for a type; neither
    /// appears in any `excludes` mask). So:
    ///
    ///   * an `export`ed newcomer is checked against `exports` (the earlier
    ///     exported declarations) AND the current block's `locals` — i.e.
    ///     against everything, which is the accumulated flags;
    ///   * a LOCAL newcomer is checked against `locals` alone, where the
    ///     earlier exported declarations left nothing to collide with.
    ///
    /// Hence `export type A = {}; type A = {}` is not a duplicate identifier at
    /// all (verified against tsgo 7.0.2, in both orders — reversed, the local
    /// declaration is in `locals` first and the exported one's placeholder does
    /// collide, so TS2300 stands). What such a pair earns instead is TS2395,
    /// which `checkMergedExports` reports.
    ///
    /// `ns_uninstantiated` is folded in from the live flags because it is set
    /// *after* `declare` returns (`bindNamespace` needs the symbol id first),
    /// so the accumulated local bits never carry it.
    fn priorFlags(b: *Binder, scope: ScopeId, sym: SymbolId, existing: SymbolFlags) SymbolFlags {
        if (b.exporting_node != 0 and !b.in_export_default) return existing;
        if (scope != file_scope and b.scope_kinds.items[scope] != .namespace) return existing;
        var f: SymbolFlags = @bitCast(b.sym_local_bits.items[sym]);
        f.ns_uninstantiated = existing.ns_uninstantiated;
        return f;
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

    /// tsc's `checkExportsOnMergedDeclarations` (TS2395): every declaration of a
    /// name that MERGED must agree on visibility — all `export`ed or all local —
    /// in each declaration space they claim in common. See `decl_spaces.zig`.
    ///
    /// Runs once over the file's symbols after everything is bound, rather than
    /// per declaration as tsc does, because the rule is about the whole set: tsc
    /// runs the check on the first declaration of each KIND and lets its
    /// diagnostic collection dedupe the repeats, which one pass over the set
    /// produces directly.
    ///
    /// Only a module/namespace CONTAINER has the exports/locals split the rule
    /// exists to police; a script's top level, a function body, a class or an
    /// interface has one table and no `export` modifiers to disagree about.
    fn checkMergedExports(b: *Binder) Error!void {
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            if (b.sym_decl_count.items[sym] < 2) continue;
            // A failed merge was already reported. tsc answers one with a FRESH
            // symbol, so the declarations it split apart are not a merged
            // declaration and never reach this check.
            if (b.sym_reported.items[sym] != 0) continue;
            // `export default class C {}` carries BOTH modifiers, which tsc
            // weighs against the non-default declarations separately (TS2652).
            // ztsc does not report that one, and reporting TS2395 in its place
            // would be the wrong error, so the symbol is left alone.
            if (b.sym_flags.items[sym].export_default) continue;
            const scope = b.sym_scopes.items[sym];
            if (scope == file_scope) {
                if (!b.saw_module_syntax) continue;
            } else if (b.scope_kinds.items[scope] != .namespace) continue;
            try b.checkMergedExportsOf(sym);
        }
    }

    /// The binder's half of TS2440 ("Import declaration conflicts with local
    /// declaration"): every alias whose NAME also declares a meaning of its
    /// own, with those meanings and the token the message lands on. The
    /// checker's half — resolving the alias's TARGET and intersecting the two
    /// meaning sets — is `checker/alias_conflict.zig`; the split follows tsc,
    /// whose `checkAliasSymbol` reads `symbol.flags` straight from the binder.
    ///
    /// Which declarations count is a question only the binder can answer,
    /// because it is about tsc's two member tables. An `export`ed declaration
    /// lands in the container's `exports`, a plain one in its `locals`, and
    /// `checkAliasSymbol` looks at `symbol.exportSymbol ?? symbol` — so as soon
    /// as ANY declaration of the name is exported, the exported set is the one
    /// compared and the local ones drop out. `namespace Q { var z; export
    /// import z = M; }` is silent in the oracle for exactly that reason, while
    /// `namespace M1 { export var q = 5; } namespace M1 { export import q =
    /// M1.s; }` — both in the shared `exports` table, across blocks — is the
    /// error (`varNameConflictsWithImportInDifferentPartOfModule`).
    ///
    /// Nothing is recorded for the overwhelming majority of aliases, which
    /// merge with nothing: `flags` is empty and the record is skipped.
    fn collectAliasMerges(b: *Binder) Error!void {
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            if (!b.sym_flags.items[sym].import_binding) continue;
            const exported = b.sym_exported_bits.items[sym];
            const bits = if (exported != 0) exported else b.sym_local_bits.items[sym];
            // The alias's own bits are not a meaning of the name.
            const others: SymbolFlags = @bitCast(bits & ~fbits(.{ .import_binding = true }));
            if (others.bits() == 0) continue;
            var link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                const l = b.decl_links.items[link];
                if (!isAliasDecl(b, l.value)) continue;
                try b.alias_merges.append(b.scratch, .{
                    .sym = sym,
                    .decl = l.value,
                    .tok = aliasDeclTok(b, l.value, b.decl_name_toks.items[link]),
                    .flags = others,
                });
                break;
            }
        }
    }

    fn isAliasDecl(b: *const Binder, decl: Node) bool {
        if (decl == null_node) return false;
        return switch (b.nodeTag(decl)) {
            .import_decl, .import_specifier, .import_equals => true,
            else => false,
        };
    }

    /// The token TS2440 lands on for the alias declaration `decl`.
    ///
    /// tsc reports it from `checkAliasSymbol` as `error(node, …)` — at the
    /// whole ALIAS DECLARATION, not at the local name it binds. For `import x =
    /// m.m` that is the `import` keyword (or the `export` in front of `export
    /// import q = M1.s`), and for a named import specifier it is the IMPORTED
    /// name, where `x as x44` starts. The other two shapes — a default import
    /// and `import * as ns` — report at the local name: the `ImportClause`
    /// starts there, and a `NamespaceImport` is one of the node kinds
    /// `getErrorSpanForNode` narrows to its own name (oracle-checked: `import *
    /// as a from "./m"` reports at the `a`, not at the `*`).
    fn aliasDeclTok(b: *const Binder, decl: Node, name_tok: TokenIndex) TokenIndex {
        switch (b.nodeTag(decl)) {
            .import_equals => {
                const main = b.tree.nodeMainToken(decl);
                // `export import q = …`: tsc's node span starts at the modifier.
                if (main > 0 and b.tree.tokens.tag(main - 1) == .keyword_export) return main - 1;
                return main;
            },
            .import_specifier => return b.tree.nodeMainToken(decl),
            else => return name_tok,
        }
    }

    /// TS2323: a MODULE's exported binding declared more than once.
    ///
    /// `var v` twice, or two `function f` overloads with two bodies, MERGE into
    /// one symbol and earn no duplicate-identifier error — but a module's export
    /// list is a set of bindings, and it cannot carry the same name twice, so
    /// tsc rejects the merge at the module boundary instead:
    ///
    ///     export var Foo = 2;
    ///     export var Foo = 42;   // TS2323, on BOTH names
    ///
    /// Three conditions, each measured against tsgo:
    ///
    ///   * the MODULE's top level only. A `namespace N` merges the same pair
    ///     silently (`export var nv` twice inside one is legal), and a script
    ///     has no export list at all.
    ///   * a symbol that is ONLY `var`, or ONLY `function` — the two meanings
    ///     that merge into a single emitted binding. `let`/`const` are TS2451
    ///     and a `var` beside a `function` is TS2300, so neither is a merge at
    ///     all; `interface`, `enum` and `namespace` merge into one binding and
    ///     are legal; a `class` is a duplicate identifier. Reading it off the
    ///     symbol's own meaning bits is what makes every one of those fall out
    ///     of the same test, and is why the check does not consult
    ///     `sym_reported` — TS2393 ("duplicate function implementation") rides
    ///     ALONGSIDE this diagnostic, and a rejected merge never has a single
    ///     meaning bit to begin with.
    ///   * every declaration `export`ed by a MODIFIER. A mixed set is TS2395,
    ///     and a name exported by an `export { … }` specifier is one binding
    ///     however many times its target was declared.
    ///
    /// A FUNCTION additionally counts only its IMPLEMENTATIONS: an overload set
    /// is many declarations of one binding, so `export function f(a: number):
    /// number; export function f(a: any): any { … }` is legal and common. What
    /// collides is a second BODY, and tsc reports only on the bodies —
    /// `f(sig); f(){}; f(){}` answers TS2393 three times and TS2323 twice
    /// (measured).
    fn checkRedeclaredExports(b: *Binder) Error!void {
        if (!b.saw_module_syntax) return;
        const var_only = bind_result.fbits(.{ .var_decl = true });
        const fn_only = bind_result.fbits(.{ .function = true });
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            if (b.sym_decl_count.items[sym] < 2) continue;
            if (b.sym_scopes.items[sym] != file_scope) continue;
            const meaning = b.sym_flags.items[sym].bits() &
                (bind_result.mask_value | bind_result.mask_type);
            const fns = meaning == fn_only;
            if (meaning != var_only and !fns) continue;
            var bindings: u32 = 0;
            var link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                if (!b.declIsExported(link)) break;
                if (!fns or b.functionHasBody(b.decl_links.items[link].value)) bindings += 1;
            } else {
                if (bindings < 2) continue;
                link = b.sym_decl_head.items[sym];
                while (link != 0) : (link = b.decl_links.items[link].next) {
                    const l = b.decl_links.items[link];
                    if (fns and !b.functionHasBody(l.value)) continue;
                    try b.diag(.redeclared_exported_variable, b.dupDiagTok(l.value, b.decl_name_toks.items[link]));
                }
            }
        }
    }

    /// Is this declaration a function WITH a body — an implementation rather
    /// than an overload signature?
    fn functionHasBody(b: *const Binder, node: Node) bool {
        if (node == null_node or b.nodeTag(node) != .function_decl) return false;
        return b.tree.nodeData(node).rhs != 0;
    }

    /// TS1194: an `export { … }` / `export * from …` statement written in a
    /// NAMESPACE body — tsc's `checkExportDeclaration`.
    ///
    /// A namespace's exports are its `export`ed members; an export DECLARATION
    /// is module syntax, and belongs to a module's top level or to a `declare
    /// module "spec"` block. The rule has two shapes, and tsc anchors them
    /// differently (`error(node.moduleSpecifier, …)` vs `error(node, …)`):
    ///
    ///   * with a module specifier, it is rejected outright — in an ambient
    ///     namespace too — and reported at the SPECIFIER;
    ///   * without one, it is rejected only in a live namespace, and reported
    ///     at the statement. `declare namespace Q { function _try(…): any;
    ///     export { _try as try }; }` is the ambient re-export idiom, and
    ///     legal (`exportDeclarationsInAmbientNamespaces`).
    ///
    /// `declare module "spec"` and `declare global` are ambient MODULES, not
    /// namespaces, and take neither arm.
    fn checkNamespaceExportDecl(b: *Binder, node: Node, module_token: TokenIndex) Error!void {
        if (!b.inPlainNamespaceBody()) return;
        if (module_token != 0) return b.diag(.export_decl_in_namespace, module_token);
        if (b.ambient) return;
        try b.diag(.export_decl_in_namespace, b.tree.nodeMainToken(node));
    }

    /// TS1147, the IMPORT half of the same rule
    /// (`checkExternalImportOrExportDeclaration`): an import that names a
    /// MODULE — `import … from "m"`, `import x = require("m")` — written in a
    /// namespace body. Reported at the specifier, and in an ambient namespace
    /// too: what tsc exempts is a `declare module "spec"` block, not ambience.
    /// An entity-name alias (`import A = B.C`) names no module and is the
    /// normal way to alias inside a namespace, so it carries no specifier here.
    fn checkNamespaceImportDecl(b: *Binder, module_token: TokenIndex) Error!void {
        if (module_token == 0) return;
        if (!b.inPlainNamespaceBody()) return;
        try b.diag(.import_in_namespace_references_module, module_token);
    }

    /// Is the statement being bound directly inside a `namespace`/`module`
    /// body — as opposed to a file's top level, or a `declare module "spec"` /
    /// `declare global` block, which are ambient MODULES and take module
    /// syntax?
    fn inPlainNamespaceBody(b: *const Binder) bool {
        if (b.cur_scope == file_scope) return false;
        if (b.scope_kinds.items[b.cur_scope] != .namespace) return false;
        const owner = b.scope_owners.items[b.cur_scope];
        if (owner == null_node or b.nodeTag(owner) != .namespace_decl) return false;
        const data = b.tree.extraData(ast.NamespaceData, b.tree.nodeData(owner).lhs);
        return data.flags & (ast.Flags.ambient_module | ast.Flags.global_aug) == 0;
    }

    /// Does this declaration publish a module binding — either through an
    /// `export` modifier, or as the declaration form of `export default`?
    ///
    /// `decl_origins.exported` covers only the first: `export default function
    /// f() {}` leaves `exporting_node` clear because the name it publishes is
    /// `default`, not `f` (see `in_export_default`). The binding is a binding
    /// all the same, and two of them collide exactly as two `export var` do —
    /// tsc answers TS2323 for `default` at each function's NAME. Recognized off
    /// the token before the declaration's own first token, which is where the
    /// modifier that would otherwise have set the flag sits.
    fn declIsExported(b: *const Binder, link: u32) bool {
        if (b.decl_origins.items[link].exported) return true;
        const node = b.decl_links.items[link].value;
        if (node == null_node) return false;
        const main = b.tree.nodeMainToken(node);
        return main > 0 and b.tree.tokens.tag(main - 1) == .keyword_default;
    }

    /// The per-symbol half. Declarations are grouped by the BLOCK they were
    /// bound in: each `namespace N { … }` block has its own `locals` table, so a
    /// local declaration in one block and an `export`ed one in another never
    /// share a table and are not an error (`duplicateSymbolsExportMatching`'s
    /// first three `namespace M` blocks are all legal for exactly that reason).
    fn checkMergedExportsOf(b: *Binder, sym: SymbolId) Error!void {
        const head = b.sym_decl_head.items[sym];
        var group = head;
        while (group != 0) : (group = b.decl_links.items[group].next) {
            const block = b.decl_origins.items[group].block;
            if (b.blockSeenBefore(head, group, block)) continue;

            var exported: decl_spaces.Spaces = .{};
            var local: decl_spaces.Spaces = .{};
            var link = group;
            while (link != 0) : (link = b.decl_links.items[link].next) {
                const o = b.decl_origins.items[link];
                if (o.block != block) continue;
                // An unmodelled declaration kind (an alias, whose spaces are
                // its target's) switches the whole symbol off rather than
                // inviting a guess.
                const sp = b.declSpaces(b.decl_links.items[link].value) orelse return;
                if (o.exported) exported = exported.merge(sp) else local = local.merge(sp);
            }
            const common = decl_spaces.conflict(exported, local);
            if (!common.any()) continue;

            link = group;
            while (link != 0) : (link = b.decl_links.items[link].next) {
                const o = b.decl_origins.items[link];
                if (o.block != block) continue;
                const node = b.decl_links.items[link].value;
                const sp = b.declSpaces(node) orelse continue;
                // Only the declarations that contributed to the shared space.
                if (!sp.intersect(common).any()) continue;
                try b.diag(
                    .merged_decl_export_mismatch,
                    b.dupDiagTok(node, b.decl_name_toks.items[link]),
                );
            }
        }
    }

    /// Is the declaration behind `link` in an AMBIENT context — tsc's
    /// `NodeFlags.Ambient`?
    ///
    /// `decl_origins` carries the INHERITED half (a `.d.ts`, a `declare
    /// namespace` body, a `declare class` body), which is all `b.ambient` knows
    /// when the name is bound: a declaration's OWN `declare` modifier is not in
    /// it, because `bindNamespace`/`bindClass` declare the name before entering
    /// the body it makes ambient. So the modifier is read back off the node here.
    /// Without it `declare namespace foo { … } class foo {}` — legal, and the
    /// point of `partiallyAmbientClodule` — looked like a namespace written
    /// before a live class.
    fn declIsAmbient(b: *Binder, link: u32) bool {
        if (b.decl_origins.items[link].ambient) return true;
        const node = b.decl_links.items[link].value;
        if (node == null_node) return false;
        const d = b.tree.nodeData(node);
        const flags: u32 = switch (b.nodeTag(node)) {
            .function_decl, .class_method => b.tree.extraData(ast.FnProto, d.lhs).flags,
            .class_decl => b.tree.extraData(ast.ClassData, d.lhs).flags,
            .namespace_decl => b.tree.extraData(ast.NamespaceData, d.lhs).flags,
            .enum_decl => b.tree.extraData(ast.EnumData, d.lhs).flags,
            else => return false,
        };
        return flags & ast.Flags.declare != 0;
    }

    /// Was `block` already the block of a declaration earlier in `sym`'s list
    /// than `stop`? Keeps `checkMergedExportsOf` to one report per group without
    /// a set: a name has a handful of declarations at most.
    fn blockSeenBefore(b: *Binder, head: u32, stop: u32, block: u31) bool {
        var link = head;
        while (link != stop) : (link = b.decl_links.items[link].next) {
            if (b.decl_origins.items[link].block == block) return true;
        }
        return false;
    }

    /// tsc's `checkFunctionOrConstructorSymbol` arm for a missing implementation
    /// (TS2391, TS2390 for a constructor): a name declared with overload
    /// signatures needs one declaration with a BODY, and the diagnostic lands on
    /// the LAST non-ambient function-like declaration of the name. The
    /// per-declaration rule — and every exclusion — is `impl_expected.zig`.
    ///
    /// One pass over the file's symbols after everything is bound, for the same
    /// reason `checkMergedExports` is: the verdict is a property of the whole
    /// declaration set, and "the last one" is only known once there are no more.
    /// Remember which declaration immediately follows each function or method in
    /// `list` (see `overload_next`). Two jobs: it names the sibling
    /// `overloadSiblingDiag` inspects, and its presence for a given pair IS
    /// tsc's `previousDeclaration.end === node.pos` — a pair with a node between
    /// them never gets an entry, which is exactly "not consecutive". A
    /// body-carrying declaration needs an entry for the same reason a bodyless
    /// one does: `function m() {} function f() {} function m();` blames `f`.
    /// One entry per function-like declaration in the file, in per-file scratch.
    fn recordOverloadSiblings(b: *Binder, list: []const Node) Error!void {
        if (list.len < 2) return;
        for (list[0 .. list.len - 1], list[1..]) |n, next| {
            if (n == null_node or next == null_node) continue;
            const decl = b.exportedDecl(n);
            switch (b.nodeTag(decl)) {
                .function_decl, .class_method => try b.overload_next.put(b.scratch, decl, b.exportedDecl(next)),
                else => {},
            }
        }
    }

    /// The declaration a statement DECLARES, looking through the `export`
    /// wrappers the parser puts around it. A declaration list holds the
    /// wrapper, while a symbol's declaration list holds what is inside it, so
    /// anything that pairs the two has to agree on which node it means.
    fn exportedDecl(b: *Binder, node: Node) Node {
        return switch (b.nodeTag(node)) {
            .export_decl, .export_default => b.tree.nodeData(node).lhs,
            else => node,
        };
    }

    /// What KIND of function-like a declaration is, in tsc's terms — the axis
    /// `reportImplementationExpectedError` compares before it will call two
    /// declarations two halves of one overload set. ztsc spells constructors,
    /// accessors and ordinary methods with a single `.class_method` tag, so the
    /// distinction tsc gets from `SyntaxKind` is reconstructed here.
    const FnKind = enum { function, method, ctor, accessor, other };

    fn fnKindOf(b: *Binder, node: Node) FnKind {
        switch (b.nodeTag(node)) {
            .function_decl => return .function,
            .class_method => {
                const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(node).lhs);
                if (proto.flags & (ast.Flags.get | ast.Flags.set) != 0) return .accessor;
                const tok = b.tree.nodeMainToken(node);
                if (b.tree.tokens.tag(tok) == .keyword_constructor and
                    proto.flags & ast.Flags.static == 0) return .ctor;
                return .method;
            },
            else => return .other,
        }
    }

    /// The name token of a function-like declaration (0 = none). A method's name
    /// is its `main_token`; a `function` statement carries it in the prototype.
    fn fnNameTok(b: *Binder, node: Node) TokenIndex {
        return switch (b.nodeTag(node)) {
            .function_decl => b.tree.extraData(ast.FnProto, b.tree.nodeData(node).lhs).name_token,
            .class_method => b.tree.nodeMainToken(node),
            else => 0,
        };
    }

    /// What the declaration IMMEDIATELY FOLLOWING a bodyless `node` turns the
    /// missing implementation into, per tsc's `reportImplementationExpectedError`:
    ///
    ///   * a sibling of a DIFFERENT kind, or none at all → nothing here; the
    ///     caller falls through to TS2391/TS2390;
    ///   * the same kind and the same name, differing only in `static` → the
    ///     pair is a mixed static/instance overload set (TS2387/TS2388), blamed
    ///     on the SIBLING's name;
    ///   * the same kind and the same name otherwise → nothing at all: the two
    ///     declarations failed to merge for a reason the binder has already
    ///     reported (a duplicate identifier), and tsc deliberately stays quiet;
    ///   * the same kind, a DIFFERENT name, and a body → the implementation is
    ///     there but misnamed (TS2389), again on the sibling's name.
    const SiblingVerdict = union(enum) {
        /// No usable sibling: the caller reports TS2391/TS2390 as before.
        fall_through,
        /// A sibling that explains the missing body without a diagnostic of its
        /// own — tsc's "we should already report error in binder" arm.
        silent,
        /// `arg` is 0 for the codes whose message names nothing but itself, and
        /// the token whose TEXT fills `{0}` for the one that does (TS2389 names
        /// the overload the implementation should have been called).
        report: struct { code: Code, tok: TokenIndex, arg: TokenIndex = 0 },
    };

    fn overloadSiblingDiag(b: *Binder, node: Node) SiblingVerdict {
        const next = b.overload_next.get(node) orelse return .fall_through;
        const kind = b.fnKindOf(node);
        if (kind != b.fnKindOf(next)) return .fall_through;
        const name_tok = b.fnNameTok(node);
        const next_tok = b.fnNameTok(next);
        if (name_tok == 0 or next_tok == 0) return .fall_through;

        const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(node).lhs);
        const next_proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(next).lhs);
        // tsc matches two computed names on being computed at all, and two
        // literal (or private) names on their text.
        const both_computed = proto.flags & ast.Flags.computed != 0 and
            next_proto.flags & ast.Flags.computed != 0;
        const same_name = both_computed or
            std.mem.eql(u8, b.tokenText(name_tok), b.tokenText(next_tok));

        if (same_name) {
            if (kind != .method) return .silent;
            const a_static = proto.flags & ast.Flags.static != 0;
            const b_static = next_proto.flags & ast.Flags.static != 0;
            if (a_static == b_static) return .silent;
            return .{ .report = .{
                .code = if (a_static) .overload_must_be_static else .overload_must_not_be_static,
                .tok = next_tok,
            } };
        }
        // A misnamed IMPLEMENTATION only: a second bodyless signature of another
        // name is simply an unrelated declaration, and tsc keeps looking (which
        // for ztsc means falling through to TS2391).
        if (b.tree.nodeData(next).rhs == 0) return .fall_through;
        return .{ .report = .{ .code = .overload_impl_name_mismatch, .tok = next_tok, .arg = name_tok } };
    }

    /// tsc's `reportImplementationExpectedError`, whole: the sharper sibling arms
    /// first (which can also silence the report outright), then the generic
    /// "implementation is missing" / "constructor implementation is missing" /
    /// "abstract declarations must be consecutive".
    ///
    /// Its two call sites differ ONLY in what they screen out first. The
    /// `lastSeenNonAmbientDeclaration` arm reaches here for a declaration that
    /// legitimately wants a body (`impl_expected.expected`); the non-consecutive
    /// pair arm reaches here for whatever the previous declaration happened to
    /// be — `declare`, optional and body-carrying alike, since tsc applies none
    /// of those exclusions on that path (all three verified against tsgo 7.0.2).
    fn reportImplExpected(b: *Binder, sym: SymbolId, link: u32) Error!void {
        const node = b.decl_links.items[link].value;
        const name_tok = b.decl_name_toks.items[link];
        // tsc's `nodeIsMissing(node.name)` bail: a recovered declaration with no
        // name to report at.
        if (name_tok == 0) return;
        // What immediately follows can give a sharper answer than the generic
        // "implementation is missing" — or explain the missing body without a
        // diagnostic at all.
        switch (b.overloadSiblingDiag(node)) {
            .fall_through => {},
            .silent => return,
            .report => |r| return if (r.arg == 0) b.diag(r.code, r.tok) else b.diagArg(r.code, r.tok, r.arg),
        }
        if (b.scope_kinds.items[b.sym_scopes.items[sym]] == .class_members and
            b.tree.tokens.tag(name_tok) == .keyword_constructor)
        {
            return b.diag(.missing_constructor_implementation, name_tok);
        }
        const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(node).lhs);
        // An `abstract` method is legally bodyless, so the only thing wrong with
        // it is the gap: tsc words that as its own diagnostic.
        if (proto.flags & ast.Flags.abstract != 0) {
            return b.diag(.abstract_decls_not_consecutive, name_tok);
        }
        // A computed method name (`[Symbol.iterator](x: string): string;`) is
        // reported at the `[`, as every duplicate-name diagnostic is.
        return b.diag(.missing_function_implementation, b.dupDiagTok(node, name_tok));
    }

    /// tsc's OTHER `reportImplementationExpectedError` call site: inside
    /// `checkFunctionOrConstructorSymbol`'s walk, `previousDeclaration.end !==
    /// node.pos` — two declarations of one overload set with a NODE between
    /// them. The report lands on the EARLIER of the pair.
    ///
    ///     function m(): void;
    ///     const x = 1;          // ← the gap
    ///     function m(): void {} // TS2391 lands on line 1's `m`
    ///
    /// The byte test is `recordOverloadSiblings`' map: a pair with something
    /// between them has no entry, which is precisely non-consecutive (leading
    /// trivia is not a node, so a blank line or a comment keeps them adjacent).
    ///
    /// Not reached for an INTERFACE or type-literal member — tsc's
    /// `inAmbientContextOrInterface` clears `previousDeclaration` for every one
    /// of those, and their signatures are legally bodyless anyway.
    fn checkConsecutiveDecls(b: *Binder, sym: SymbolId) Error!void {
        var prev: u32 = 0;
        var body_seen = false;
        var link = b.sym_decl_head.items[sym];
        while (link != 0) : (link = b.decl_links.items[link].next) {
            // An AMBIENT declaration drops whatever came before it, then becomes
            // the previous declaration itself — so `declare function f();
            // declare const x; declare function f();` is silent while
            // `declare function f(); const x = 1; function f() {}` reports.
            if (b.decl_origins.items[link].ambient) prev = 0;
            const node = b.decl_links.items[link].value;
            switch (b.nodeTag(node)) {
                .function_decl, .class_method => {},
                // A non-function-like declaration of the same name (a merged
                // `namespace`, a `class`) is not part of the overload set; tsc's
                // walk passes over it without disturbing the pairing.
                else => continue,
            }
            // tsc's walk collects functions, methods, method signatures and
            // constructors — never ACCESSORS, which ztsc spells with the same
            // node tag and which are legally bodyless.
            if (b.fnKindOf(node) == .accessor) continue;
            const has_body = b.tree.nodeData(node).rhs != 0;
            if (has_body and body_seen) {
                // A SECOND implementation is TS2393/TS2392's business, and tsc
                // takes that branch instead of this one.
            } else if (prev != 0 and
                (b.overload_next.get(b.decl_links.items[prev].value) orelse null_node) != node)
            {
                try b.reportImplExpected(sym, prev);
            }
            if (has_body) body_seen = true;
            prev = link;
        }
    }

    fn checkMissingImplementations(b: *Binder) Error!void {
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            const f = b.sym_flags.items[sym];
            if (!f.function and !f.method) continue;
            if (b.scope_kinds.items[b.sym_scopes.items[sym]] != .interface_members) {
                try b.checkConsecutiveDecls(sym);
            }

            // tsc's `lastSeenNonAmbientDeclaration`.
            var last: u32 = 0;
            var link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                if (b.decl_origins.items[link].ambient) continue;
                switch (b.nodeTag(b.decl_links.items[link].value)) {
                    .function_decl, .class_method => last = link,
                    else => {},
                }
            }
            if (last == 0) continue;

            const node = b.decl_links.items[last].value;
            const name_tok = b.decl_name_toks.items[last];
            if (name_tok == 0) continue;
            const d = b.tree.nodeData(node);
            const proto = b.tree.extraData(ast.FnProto, d.lhs);
            const scope = b.scope_kinds.items[b.sym_scopes.items[sym]];
            const is_ctor = scope == .class_members and
                b.tree.tokens.tag(name_tok) == .keyword_constructor;
            // THIS call site's screen: only a declaration that legitimately wants
            // a body gets the report (`impl_expected.zig` holds every exclusion).
            if (impl_expected.expected(scope, b.nodeTag(node), proto.flags, is_ctor, d.rhs != 0) == .none) continue;
            try b.reportImplExpected(sym, last);
        }
    }

    /// tsc's `checkEnumDeclaration` arm for TS2432: the blocks of a merged
    /// `enum` share one member table, so only ONE of them may start with a
    /// member that omits its initializer — a second such block would give its
    /// first member the value 0 all over again.
    ///
    ///     enum E { A }
    ///     enum E { B }   // TS2432 on `B`
    ///
    /// Reported on the offending block's first member, and only from the second
    /// such block on: `enum E { A } enum E { B = 1 } enum E { C }` names `C`
    /// alone.
    fn checkEnumFirstMembers(b: *Binder) Error!void {
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            if (!b.sym_flags.items[sym].enum_decl) continue;
            if (b.sym_decl_count.items[sym] < 2) continue;
            var seen_missing = false;
            var link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                const node = b.decl_links.items[link].value;
                // A merged `enum`/`namespace` pair puts both kinds here.
                if (b.nodeTag(node) != .enum_decl) continue;
                const data = b.tree.extraData(ast.EnumData, b.tree.nodeData(node).lhs);
                const members = b.tree.extraRange(data.members_start, data.members_end);
                if (members.len == 0 or members[0] == null_node) continue;
                const first = members[0];
                // `enum_member`: lhs = the initializer expression (0 = none).
                if (b.tree.nodeData(first).lhs != 0) continue;
                if (seen_missing) {
                    try b.diag(.enum_first_member_needs_initializer, b.tree.nodeMainToken(first));
                } else {
                    seen_missing = true;
                }
            }
        }
    }

    /// tsc's `checkModuleDeclaration` arm for TS2434: a namespace that merges
    /// with a class or a function must not be written BEFORE it. The merged
    /// value is the class/function object with the namespace's exports added, so
    /// the namespace block has to run second:
    ///
    ///     namespace m { var y = 2; }
    ///     class m { }                 // TS2434 on the namespace's name
    ///
    /// Only an INSTANTIATED, non-ambient namespace block is judged (a type-only
    /// one emits nothing, so nothing has to run at all — `namespace m {} class m
    /// {}` is legal), and only against a non-ambient class or an IMPLEMENTED
    /// function (an overload signature has no body to be shadowed).
    fn checkNamespacePriorToMerge(b: *Binder) Error!void {
        for (1..b.sym_names.items.len) |i| {
            const sym: SymbolId = @intCast(i);
            const f = b.sym_flags.items[sym];
            if (!f.namespace_decl or f.ns_uninstantiated) continue;
            if (!f.class and !f.function) continue;
            if (b.sym_decl_count.items[sym] < 2) continue;

            // tsc's `getFirstNonAmbientClassOrFunctionDeclaration`.
            var merge_tok: TokenIndex = 0;
            var link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                if (b.declIsAmbient(link)) continue;
                const node = b.decl_links.items[link].value;
                switch (b.nodeTag(node)) {
                    .class_decl => {},
                    // A function needs a BODY to be the merge's runtime half.
                    .function_decl => if (b.tree.nodeData(node).rhs == 0) continue,
                    else => continue,
                }
                merge_tok = b.decl_name_toks.items[link];
                break;
            }
            if (merge_tok == 0) continue;

            link = b.sym_decl_head.items[sym];
            while (link != 0) : (link = b.decl_links.items[link].next) {
                if (b.declIsAmbient(link)) continue;
                const node = b.decl_links.items[link].value;
                if (b.nodeTag(node) != .namespace_decl) continue;
                if (!b.instantiated(node)) continue;
                const name_tok = b.decl_name_toks.items[link];
                // Token indices run in source order, so this is tsc's
                // `node.pos < firstNonAmbientClassOrFunc.pos`.
                if (name_tok < merge_tok) try b.diag(.namespace_prior_to_merge, name_tok);
            }
        }
    }

    /// TS17009/TS17011, tsc's `checkThisBeforeSuper`: a derived class's
    /// constructor may not touch `this` — nor reach for a property of `super` —
    /// on any path that has not yet run `super(...)`, because the base
    /// constructor is what brings the instance into existence. Two codes for one
    /// rule, exactly as tsc words them at its two call sites
    /// (`checkThisExpression` and `checkSuperExpression`).
    ///
    /// A post-bind check because the answer is a property of the finished flow
    /// GRAPH: `super(); while (x) { this.a }` is clean only once the loop's back
    /// edge is in place, and that edge does not exist while the body is being
    /// walked. Nothing to do for a file with no derived constructor, which is
    /// most of them.
    fn checkThisBeforeSuper(b: *Binder) Error!void {
        if (b.this_in_derived_ctor.items.len == 0) return;
        const memo = try b.scratch.alloc(PostSuper.State, b.flow_tags.items.len);
        defer b.scratch.free(memo);
        @memset(memo, .unknown);
        const ps: PostSuper = .{
            .tags = b.flow_tags.items,
            .a = b.flow_a.items,
            .b = b.flow_b.items,
            .reduce_edges = b.reduce_edges.items,
            .pendings = b.pendings.items,
            .ante_links = b.ante_links.items,
            .super_flows = b.super_call_flows.items,
            .memo = memo,
        };
        for (b.this_in_derived_ctor.items) |t| {
            if (ps.ask(t.next)) continue;
            const code: Code = if (b.nodeTag(t.value) == .super_expr)
                .super_before_super_property
            else
                .super_before_this;
            try b.diag(code, b.tree.nodeMainToken(t.value));
        }
    }

    /// tsc's `isPostSuperFlowNode`, over the binder's UNSEALED flow arrays: has
    /// every path reaching `flow` already run a `super(...)` call?
    ///
    /// A join answers yes only when all of its antecedents do (tsc's `every`).
    /// An unreachable edge answers YES — nothing reaches it, so there is no path
    /// to blame, which is why `constructor() { throw 1; this.a = 1 }` is clean.
    /// A cycle answers yes for the same reason in the other direction: a loop's
    /// back edge re-enters a label the walk is already inside, and the only way
    /// around that label is the entry edge the walk is already testing. Both
    /// arms are measured against tsgo (`super(); while (x) { this.a }` clean,
    /// `while (x) { super() } this.a` reported).
    const PostSuper = struct {
        tags: []const FlowTag,
        a: []const u32,
        b: []const u32,
        reduce_edges: []const ReduceEdges,
        pendings: []const Pending,
        ante_links: []const Link,
        super_flows: []const FlowId,
        /// One entry per flow node. A fixpoint cache, not just a speed-up: the
        /// `in_progress` state is what terminates a loop's back edge.
        memo: []State,

        const State = enum(u8) { unknown, in_progress, yes, no };

        fn ask(ps: PostSuper, flow: FlowId) bool {
            switch (ps.memo[flow]) {
                .yes => return true,
                .no => return false,
                .in_progress => return true,
                .unknown => {},
            }
            ps.memo[flow] = .in_progress;
            const answer = ps.compute(flow);
            ps.memo[flow] = if (answer) .yes else .no;
            return answer;
        }

        fn compute(ps: PostSuper, flow: FlowId) bool {
            var f = flow;
            while (true) {
                switch (ps.tags[f]) {
                    .unreachable_ => return true,
                    .none, .start => return false,
                    .call_stmt => {
                        for (ps.super_flows) |s| if (s == f) return true;
                        f = ps.a[f];
                    },
                    .assign, .cond_true, .cond_false, .chain_taken, .chain_short, .switch_clause, .switch_no_match, .array_mutation => f = ps.a[f],
                    // Pass through to the continuation. The target label is
                    // walked with its full antecedent list, which can only
                    // make the answer more conservative ("super may not have
                    // run"), never less.
                    .reduce_label => f = ps.reduce_edges[ps.b[f]].antecedent,
                    .branch_label, .loop_label => {
                        // `flow_a` holds the pending id until seal() flattens
                        // the list into `flow_extra`.
                        const p = ps.pendings[ps.a[f]];
                        if (p.count == 0) return true; // no path in at all
                        var l = p.head;
                        while (l != 0) : (l = ps.ante_links[l].next) {
                            if (!ps.ask(ps.ante_links[l].value)) return false;
                        }
                        return true;
                    },
                }
            }
        }
    };

    /// The declaration spaces of one declaration NODE — `decl_spaces.ofTag` plus
    /// the one fact that is not a property of the kind: a `namespace` block
    /// claims the VALUE space only when it is instantiated.
    fn declSpaces(b: *Binder, node: Node) ?decl_spaces.Spaces {
        if (node == null_node) return null;
        const tag = b.nodeTag(node);
        var sp = decl_spaces.ofTag(tag) orelse return null;
        if (tag == .namespace_decl and b.instantiated(node)) sp.value = true;
        return sp;
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

    /// tsc's `createReduceLabel`. `pid` is the pending holding the reduced
    /// antecedent list; `flow_a` keeps it (like a label's) until `seal`, and
    /// `flow_b` indexes the two edges that do not fit in the SoA columns.
    fn addReduceLabel(b: *Binder, target: FlowId, antecedent: FlowId, pid: PendingId) Error!FlowId {
        const idx: u32 = @intCast(b.reduce_edges.items.len);
        try b.reduce_edges.append(b.scratch, .{ .target = target, .antecedent = antecedent });
        return b.addFlow(.reduce_label, pid, idx);
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
    /// an index that *could* denote a stable reference — a literal
    /// (`arr[0]`, `s["kind"]`, `` s[`kind`] ``) or a bare identifier
    /// (`map[key]`). The semantic half — is the identifier a `const` or a
    /// never-assigned local? — needs symbol resolution, which is not available
    /// here; the checker applies it in `stableIndexSymbol` and simply does not
    /// build a key when it fails, so an index that turns out to be unstable
    /// costs one unused flow entry.
    ///
    /// A STRING-literal index has to be here for the same reason a numeric one
    /// does: it names a property (`Checker.pathElemOfAccess` folds it to the
    /// same member link `s.kind` gets), so without a flow node attached the
    /// checker has nothing to query and `s["kind"]` never narrowed at all.
    fn isNarrowableIndex(b: *const Binder, node: Node) bool {
        var n = node;
        while (b.nodeTag(n) == .paren_expr) n = b.tree.nodeData(n).lhs;
        return switch (b.nodeTag(n)) {
            .number_literal, .identifier, .string_literal, .template_literal => true,
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
                try b.recordOverloadSiblings(b.tree.nodeRange(node));
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
            .class_decl => try b.bindClass(node, true, 0),
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
                try b.checkNamespaceImportDecl(d.rhs);
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
                        .function_decl, .class_decl, .interface_decl => {},
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
                try b.checkNamespaceExportDecl(node, d.rhs);
                try b.bindExportNamed(node);
            },
            .export_all => {
                if (b.cur_scope == file_scope) {
                    b.saw_module_syntax = true;
                    b.saw_export_declaration = true;
                }
                try b.checkNamespaceExportDecl(node, d.rhs);
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
                try b.recordOverloadSiblings(b.tree.extraRange(cr.start, cr.end));
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
                try b.recordOverloadSiblings(b.tree.nodeRange(cd.rhs));
                for (b.tree.nodeRange(cd.rhs)) |stmt| try b.bindStatement(stmt);
            } else {
                try b.bindStatement(cd.rhs);
            }
            b.popScope(saved_scope);
            after_catch = b.cur_flow;
        }

        if (e.finally_block == 0) {
            const pid = try b.newPending();
            try b.pendAdd(pid, after_try);
            try b.pendAdd(pid, after_catch);
            b.cur_flow = try b.finishPending(pid);
            return;
        }

        // tsc's `bindTryStatement` finally arm. The finally block is entered
        // from the normal completion of the try/catch block AND — this is the
        // conservative part — from an exception raised at any point inside
        // them, which is approximated by the pre-try flow. All of those are
        // real for a reference read INSIDE the finally block, so they are the
        // label's antecedents.
        const fp = try b.newPending();
        try b.pendAdd(fp, after_try);
        try b.pendAdd(fp, after_catch);
        const normal_count = b.pendings.items[fp].count;
        try b.pendAdd(fp, pre); // the exception edge
        const all_count = b.pendings.items[fp].count;
        const finally_label = try b.finishPending(fp);
        b.cur_flow = finally_label;
        try b.bindStatement(e.finally_block);
        const end_finally = b.cur_flow;

        // Leaving the statement normally, though, means no exception was
        // raised — so the exception edge must be dropped on the way out. tsc
        // spells that `createReduceLabel(finallyLabel, normalExitLabel
        // .antecedents, currentFlow)`: continue at the end of the finally
        // block, but with the finally label restricted to the normal-exit
        // edges. Joining the pre-try flow in unconditionally instead (what
        // ztsc did) made every variable the try block assigns read as possibly
        // unassigned afterwards (`flowAfterFinally1`).
        if (normal_count == 0 or end_finally == unreachable_flow) {
            // No normal way in (or the finally block never completes): the
            // statement has no normal exit either.
            b.cur_flow = unreachable_flow;
        } else if (all_count == normal_count) {
            // The exception edge was already one of the normal ones (or was
            // unreachable): nothing to reduce.
            b.cur_flow = end_finally;
        } else {
            const rp = try b.newPending();
            try b.pendAdd(rp, after_try);
            try b.pendAdd(rp, after_catch);
            b.cur_flow = try b.addReduceLabel(finally_label, end_finally, rp);
        }
    }

    fn bindCatchBinding(b: *Binder, binding: Node) Error!void {
        switch (b.nodeTag(binding)) {
            .declarator_full => {
                const d = b.tree.nodeData(binding);
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, .catch_param, binding, .{});
                try b.bindType(e.type_ann);
            },
            .declarator => {
                try b.bindPattern(b.tree.nodeData(binding).lhs, .catch_param, binding, .{});
            },
            else => try b.bindPattern(binding, .catch_param, binding, .{}),
        }
    }

    // --- declarations ------------------------------------------------------------

    fn declKindOfVar(b: *Binder, node: Node) DeclKind {
        return switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
            // A `using`/`await using` declaration is block-scoped and immutable,
            // exactly like `const` — tsc gives it `NodeFlags.Const` and reports
            // an assignment to one as "Cannot assign to 'x' because it is a
            // constant". The parser puts the declaration list's `main_token` on
            // the `using` keyword for both forms so this one arm covers them.
            // (wave-6 A: the only binder line the `using` work needed.)
            .keyword_const, .keyword_using => .const_decl,
            .keyword_let => .let_decl,
            else => .var_decl,
        };
    }

    fn bindVarDecl(b: *Binder, node: Node) Error!void {
        const kind = b.declKindOfVar(node);
        const d = b.tree.nodeData(node);
        // `b.ambient` covers the INHERITED half (a `.d.ts`, a `declare
        // namespace` body); the statement's own `declare` modifier is a token
        // in front of `var`/`let`/`const`, which is where the parser leaves it.
        const mt = b.tree.nodeMainToken(node);
        const ambient = b.ambient or (mt > 0 and b.tree.tokens.tag(mt - 1) == .keyword_declare);
        const extra: SymbolFlags = .{ .ambient_var = ambient };
        if (b.nodeTag(node) == .var_decl_one) {
            try b.bindDeclarator(d.lhs, kind, extra);
        } else {
            for (b.tree.nodeRange(node)) |decl| {
                if (decl != null_node) try b.bindDeclarator(decl, kind, extra);
            }
        }
    }

    fn bindDeclarator(b: *Binder, node: Node, kind: DeclKind, extra: SymbolFlags) Error!void {
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .declarator => try b.bindPattern(d.lhs, kind, node, extra),
            .declarator_init => {
                try b.bindPattern(d.lhs, kind, node, extra);
                try b.bindNamedExpr(d.rhs, b.assignedNameToken(d.lhs));
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
            },
            .declarator_full => {
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, kind, node, extra);
                try b.bindType(e.type_ann);
                if (e.init != 0) {
                    try b.bindNamedExpr(e.init, b.assignedNameToken(d.lhs));
                    b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                }
            },
            else => {}, // recovery leftovers
        }
    }

    /// Declare all names bound by a pattern. `var` names go to the nearest
    /// function/file scope; everything else binds in the current scope.
    fn bindPattern(b: *Binder, node: Node, kind: DeclKind, decl_node: Node, extra: SymbolFlags) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, extra);
            },
            .array_pattern, .object_pattern => {
                for (b.tree.nodeRange(node)) |el| try b.bindPattern(el, kind, decl_node, extra);
            },
            .binding_default => {
                try b.bindPattern(d.lhs, kind, decl_node, extra);
                try b.bindExpr(d.rhs);
            },
            .rest_element => try b.bindPattern(d.lhs, kind, decl_node, extra),
            .binding_property => {
                if (d.lhs != 0) {
                    // `key: target` — the key is a property name, not a binding.
                    try b.bindPattern(d.lhs, kind, decl_node, extra);
                } else {
                    // Shorthand `{ a }` (possibly with a default) binds the key.
                    const tok = b.tree.nodeMainToken(node);
                    const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                    _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, extra);
                }
                if (d.rhs != 0) try b.bindExpr(d.rhs); // default initializer
            },
            .binding_property_computed => {
                // `[expr]: target` — the key is an ordinary expression read in
                // the enclosing scope; only the target binds.
                if (d.lhs != 0) try b.bindExpr(d.lhs);
                if (d.rhs != 0) try b.bindPattern(d.rhs, kind, decl_node, extra);
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
        try b.bindFunctionLike(node, d.lhs, d.rhs, .not_ctor);
    }

    /// What kind of constructor (if any) a function-like is — the axis three
    /// separate rules read: parameter properties, the constructor return join,
    /// and `this`-before-`super`.
    const CtorKind = enum {
        not_ctor,
        /// A constructor of a class with no `extends`, or with `extends null`
        /// (tsc's `classDeclarationExtendsNull`, which skips the `super` check
        /// because there is no base constructor to call).
        base_ctor,
        derived_ctor,

        fn isCtor(k: CtorKind) bool {
            return k != .not_ctor;
        }
    };

    /// Shared by function declarations/expressions, arrows, methods, and
    /// function types. Creates the function scope (params + body top-level
    /// share it, so `function f(x) { let x }` clashes) and a fresh `start`
    /// flow for the body. A constructor also gets parameter properties.
    fn bindFunctionLike(b: *Binder, node: Node, proto_idx: u32, body: Node, ctor: CtorKind) Error!void {
        const is_ctor = ctor.isCtor();
        const proto = b.tree.extraData(ast.FnProto, proto_idx);
        // Flow node in effect where this function expression appears — its
        // "definition point". Recorded as the body-start's antecedent so the
        // checker can continue flow analysis into the enclosing function for a
        // constant reference captured by this closure (tsc: FlowStart.node).
        const outer_flow = b.cur_flow;
        const saved = b.saveState();
        const saved_export = b.clearExportCtx();
        defer b.restoreExportCtx(saved_export);

        const s = try b.pushScope(.function, node);
        b.var_scope = s;
        b.ctx_base = b.ctxs.items.len;
        // tsc's `currentReturnTarget`: a CONSTRUCTOR gets a return-edge join so
        // `strictPropertyInitialization` can ask what every path out of it left
        // assigned (`checkPropertyInit`). Cleared for every other function-like
        // so a nested `return` never joins an enclosing constructor's exit.
        const ret_pid: ?PendingId = if (is_ctor and body != 0) try b.newPending() else null;
        b.ctor_return = ret_pid;
        // Overwritten (not or-ed) so that a nested function-like of any kind —
        // arrow included, which is what `includeArrowFunctions` buys tsc — ends
        // the region `this`-before-`super` covers.
        b.in_derived_ctor = ctor == .derived_ctor;
        b.saw_super_call = false;

        try b.bindTypeParams(proto.tp_start, proto.tp_end);
        const home: ParamHome = .{ .ctor = is_ctor, .body = body != 0 };
        for (b.tree.extraRange(proto.params_start, proto.params_end)) |param| {
            try b.bindParam(param, home);
        }
        try b.bindType(proto.return_type);

        if (body != 0) {
            b.cur_flow = try b.addFlow(.start, outer_flow, node);
            if (b.nodeTag(body) == .block) {
                // Body statements bind directly in the function scope.
                try b.recordOverloadSiblings(b.tree.nodeRange(body));
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
            // TS2377, tsc's `checkConstructorDeclaration`: a derived class's
            // IMPLEMENTATION has to call the base constructor somewhere. The
            // question is the one `saw_super_call` answers, and it is asked
            // here — after the body, before `restoreState` puts the enclosing
            // function's answer back.
            if (ctor == .derived_ctor and !b.saw_super_call) {
                try b.diag(.derived_ctor_needs_super_call, memberStartToken(b, b.tree.nodeMainToken(node)));
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

    /// The first token of the class member whose NAME is `name_tok` — its
    /// leading modifier run, if it has one. tsc anchors a diagnostic taken on
    /// the whole declaration there, so `private constructor() {}` reports at
    /// `private`, not at `constructor`.
    ///
    /// Read back off the token stream, the same trick `constTypeParam` uses and
    /// for the same reason: the parser consumes a member modifier without
    /// storing where it was, and only a modifier keyword can occupy a slot
    /// between the member's start and its name, so the walk cannot run past its
    /// own member. (A DECORATOR can sit ahead of the run and is not covered —
    /// an under-shot span on a shape no diagnostic here reaches.)
    fn memberStartToken(b: *const Binder, name_tok: TokenIndex) TokenIndex {
        var tok = name_tok;
        while (tok > 0) {
            switch (b.tree.tokens.tag(tok - 1)) {
                .keyword_public,
                .keyword_private,
                .keyword_protected,
                .keyword_static,
                .keyword_readonly,
                .keyword_abstract,
                .keyword_override,
                .keyword_declare,
                .keyword_async,
                .keyword_accessor,
                => tok -= 1,
                else => return tok,
            }
        }
        return tok;
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

    /// Where a parameter list lives, on the two axes the parameter rules read.
    ///
    /// Both rules are really "is there a body to do the work": a parameter
    /// property has nothing to assign the member from without one, and an
    /// initializer has nothing to run. `ctor` is the extra condition on the
    /// first — a parameter property declares a CLASS member, so only a
    /// constructor can carry it.
    const ParamHome = struct {
        /// The list belongs to a `constructor`. A bodyless one still BINDS its
        /// parameter properties as members (tsc's
        /// `isParameterPropertyDeclaration` asks only about the parent's kind)
        /// and reports TS2369 on top.
        ctor: bool = false,
        /// The function-like has a body: a declaration or method with a block,
        /// an arrow. False for every signature-only position — an overload, an
        /// `abstract`/`declare`d member, a method/call/construct signature, and
        /// every function TYPE.
        body: bool = false,
    };

    fn bindParam(b: *Binder, node: Node, home: ParamHome) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .param => {
                try b.bindPattern(d.lhs, .param, node, .{});
                try b.bindType(d.rhs);
                if (!home.body) try b.reportPatternInitializers(d.lhs);
            },
            .param_full => {
                const e = b.tree.extraData(ast.ParamFull, d.rhs);
                try b.bindPattern(d.lhs, .param, node, .{});
                try b.bindType(e.type_ann);
                try b.bindExpr(e.init);
                // TS2369, tsc's `checkParameter`: a parameter property outside
                // a constructor implementation has no body to assign it, so
                // every other position rejects the modifier. `main_token` on a
                // `.param_full` is the parameter's first token — the modifier
                // itself, which is where tsc's parameter-node span starts.
                if (e.flags & member_names.param_property_mask != 0 and !(home.ctor and home.body)) {
                    try b.diag(.param_property_outside_ctor_impl, b.tree.nodeMainToken(node));
                }
                // TS2371, the same rule for the other thing a body is needed
                // for. The parameter's OWN initializer answers at the parameter
                // (`main_token`); the ones inside its pattern answer at their
                // own binding elements.
                if (!home.body) {
                    if (e.init != null_node) try b.diag(.param_initializer_outside_impl, b.tree.nodeMainToken(node));
                    try b.reportPatternInitializers(d.lhs);
                }
                // Constructor parameter property: also a class member.
                const prop_mask = ast.Flags.public | ast.Flags.private |
                    ast.Flags.protected | ast.Flags.readonly;
                if (home.ctor and e.flags & prop_mask != 0 and
                    b.nodeTag(d.lhs) == .identifier)
                {
                    const class_scope = b.scope_parents.items[b.cur_scope];
                    if (b.memberScopeOfClassScope(class_scope)) |ms| {
                        const tok = b.tree.nodeMainToken(d.lhs);
                        // TS2398: the modifier makes this a class member, and
                        // `constructor` is the one member name a class cannot
                        // have. Still DECLARED (under the literal text — the
                        // constructor itself sits under a reserved key), so two
                        // ctor signatures that both spell it are still the
                        // duplicate identifier tsc reports.
                        if (b.tree.tokens.tag(tok) == .keyword_constructor) {
                            try b.diag(.ctor_as_param_property_name, tok);
                        }
                        _ = try b.declare(ms, try b.atomOfToken(tok), .property, node, tok, .{
                            .readonly_member = e.flags & ast.Flags.readonly != 0,
                            .non_public = e.flags & nonpublic_mask != 0,
                        });
                    }
                }
            },
            else => {
                try b.bindPattern(node, .param, node, .{});
                if (!home.body) try b.reportPatternInitializers(node);
            },
        }
    }

    /// TS2371 for every `= …` inside a parameter's binding pattern, when the
    /// signature it belongs to has no body to run them (see
    /// `param_initializer_outside_impl`).
    ///
    /// tsc's `checkVariableLikeDeclaration` anchors this on the element's NAME
    /// — its binding TARGET, not the element's first token. The two differ only
    /// for a renamed element, and there they differ visibly: `({ key: [y] = [1]
    /// })` answers at the `[`, not at `key`.
    ///
    /// That same function returns EARLY, before this rule, for a renamed
    /// element whose target is a plain identifier in a parameter of a bodyless
    /// function — `({ key: target = 1 }) => …` as a TYPE is the shape tsc
    /// answers TS2842 ("unused renaming … did you mean a type annotation?")
    /// for, and it gets that instead of this.
    ///
    /// Walked separately from `bindPattern` because that walk is shared with
    /// variable, catch and implementation-parameter bindings, none of which
    /// this rule touches.
    fn reportPatternInitializers(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .array_pattern, .object_pattern => {
                for (b.tree.nodeRange(node)) |el| try b.reportPatternInitializers(el);
            },
            .binding_default => {
                try b.diag(.param_initializer_outside_impl, b.tree.nodeMainToken(d.lhs));
                try b.reportPatternInitializers(d.lhs);
            },
            // `key`, `key: target` or `key: target = init` — `lhs` is the
            // target, 0 for the shorthand whose key IS the target.
            .binding_property => {
                if (isRenamedToIdent(b, d.lhs)) return;
                const anchor = if (d.lhs != null_node) b.tree.nodeMainToken(d.lhs) else b.tree.nodeMainToken(node);
                if (d.rhs != 0) try b.diag(.param_initializer_outside_impl, anchor);
                try b.reportPatternInitializers(d.lhs);
            },
            // `[expr]: target`, where a defaulted target is a `binding_default`.
            .binding_property_computed => {
                if (isRenamedToIdent(b, bindingTargetOf(b, d.rhs))) return;
                try b.reportPatternInitializers(d.rhs);
            },
            .rest_element => try b.reportPatternInitializers(d.lhs),
            else => {},
        }
    }

    /// Is this element's binding target a plain identifier written out beside
    /// a property name — the TS2842 shape `checkVariableLikeDeclaration`
    /// returns on? A shorthand (`target == 0`) is not renamed, and a target
    /// that is itself a pattern is not an identifier.
    fn isRenamedToIdent(b: *const Binder, target: Node) bool {
        return target != null_node and b.nodeTag(target) == .identifier;
    }

    /// The binding TARGET under an optional `= default` — tsc's
    /// `BindingElement.name`. Every pattern tag's `main_token` is its own first
    /// token, so the target's names the position to report.
    fn bindingTargetOf(b: *const Binder, node: Node) Node {
        if (node != null_node and b.nodeTag(node) == .binding_default) return b.tree.nodeData(node).lhs;
        return node;
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

    /// What diagnostics print for a class expression the syntax gives no name
    /// to at all — tsc's `getNameOfSymbolAsWritten` fallback, verbatim.
    const anonymous_class_display = "(Anonymous class)";

    /// Bind an expression that is being GIVEN a name by the syntax around it —
    /// tsc's `getAssignedName`. An anonymous class expression has no name of
    /// its own, so `getNameOfSymbolAsWritten` falls back to the name it is
    /// assigned to: `const K = class { … }` prints as `typeof K`, `{ c: class
    /// { … } }` as `typeof c`, and only a class with no such parent prints
    /// `typeof (Anonymous class)`.
    ///
    /// The name is passed DOWN from the parent because the binder walks
    /// top-down and the ast carries no parent links. Every other expression
    /// ignores it, so this is `bindExpr` with one extra argument.
    fn bindNamedExpr(b: *Binder, expr: Node, name_tok: TokenIndex) Error!void {
        if (expr != null_node and name_tok != 0 and b.nodeTag(expr) == .class_decl) {
            const data = b.tree.extraData(ast.ClassData, b.tree.nodeData(expr).lhs);
            if (data.name_token == 0) return b.bindClass(expr, false, name_tok);
        }
        return b.bindExpr(expr);
    }

    /// An identifier-shaped name token, or 0 — a quoted or numeric property key
    /// is left to the `(Anonymous class)` fallback rather than printed with its
    /// punctuation.
    fn plainNameToken(b: *Binder, tok: TokenIndex) TokenIndex {
        if (tok == 0) return 0;
        const tag = b.tree.tokens.tag(tok);
        return if (tag == .identifier or tag.isKeyword()) tok else 0;
    }

    /// The name token `bindNamedExpr` should carry for an assignment target:
    /// tsc's `getAssignedName` takes the identifier of `x = <expr>` and the
    /// property name of `o.x = <expr>`, and nothing at all from a computed or
    /// call-rooted target.
    fn assignedNameToken(b: *Binder, target: Node) TokenIndex {
        if (target == null_node) return 0;
        return switch (b.nodeTag(target)) {
            .identifier => b.tree.nodeMainToken(target),
            // `.member_expr`'s main token is the dot; `rhs` is the name token.
            .member_expr => @intCast(b.tree.nodeData(target).rhs),
            else => 0,
        };
    }

    fn bindClass(b: *Binder, node: Node, declare_name: bool, anon_name_tok: TokenIndex) Error!void {
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
        const saved_export = b.clearExportCtx();
        defer b.restoreExportCtx(saved_export);
        // A `declare class`'s members are ambient, so a bodyless method there is
        // a declaration and not a missing implementation
        // (`checkMissingImplementations`). Inherited, like a `declare namespace`
        // body's: `declare namespace N { class C { m(): void; } }`.
        const was_ambient = b.ambient;
        b.ambient = was_ambient or (data.flags & ast.Flags.declare) != 0;
        defer b.ambient = was_ambient;

        const cs = try b.pushScope(.class, node);
        // A class EXPRESSION's name is not declared in the enclosing scope,
        // but it IS visible inside its own body — `var x = class C { m(c: C)
        // {} }` names the class (tsc gives the ClassExpression a local
        // symbol in its own scope). Declared here, in the class scope, so it
        // shadows nothing outside.
        //
        // A class with no name at all (`const K = class { … }`, and
        // `export default class { … }`, whose name is `default` and never its
        // own text) gets the same local symbol under the reserved
        // `member_names.class_expr_name` key. Everything downstream of a class
        // is SymbolId-keyed — the member and static tables below, the instance
        // shape, `this`, and `typeof C` — so a class without a symbol has no
        // members to check and no type to be: the checker typed every class
        // expression `any`.
        var self_sym: SymbolId = no_symbol;
        if (class_sym == no_symbol) {
            const named = data.name_token != 0;
            const atom = if (named)
                try b.atomOfToken(data.name_token)
            else
                try b.atomOf(member_names.class_expr_name);
            // The reported position of a nameless class is its `class` keyword.
            const tok = if (named) data.name_token else b.tree.nodeMainToken(node);
            self_sym = try b.declare(cs, atom, .class, node, tok, .{
                .nonambient_class = !b.ambient,
            });
            // The SCOPE key stays reserved — nothing may reach this symbol by
            // name — but the symbol's DISPLAY name is what diagnostics print,
            // and tsc prints the name the syntax assigns the class
            // (`bindNamedExpr`), or `(Anonymous class)` when there is none.
            // The two are stored separately: `members` is keyed by the atom
            // passed to `declare`, `sym_names` holds the printed spelling.
            if (!named) {
                b.sym_names.items[self_sym] = if (anon_name_tok != 0)
                    try b.atomOfToken(anon_name_tok)
                else
                    try b.atomOf(anonymous_class_display);
            }
        }
        try b.bindTypeParams(data.tp_start, data.tp_end);

        if (data.extends != 0) try b.bindHeritage(data.extends, true);
        for (b.tree.extraRange(data.impl_start, data.impl_end)) |h| {
            if (h != null_node) try b.bindHeritage(h, false);
        }
        // Does this class have a base CONSTRUCTOR to call? `extends null` does
        // not (tsc's `classDeclarationExtendsNull`, which exempts the class from
        // the `super`-before-`this` rule entirely — measured: `class C extends
        // null { a: any; constructor() { this.a = 1 } }` is clean). tsc asks the
        // question of the base TYPE; the syntactic form is the only way to write
        // it, and reading the heritage expression here keeps the binder out of
        // type resolution.
        const derived = data.extends != 0 and
            b.nodeTag(b.tree.nodeData(data.extends).lhs) != .null_literal;

        const ms = try b.newScope(.class_members, node, cs);
        const ss = try b.newScope(.class_statics, node, cs);
        if (class_sym != no_symbol) {
            try b.member_scopes.put(b.scratch, class_sym, ms);
            try b.static_scopes.put(b.scratch, class_sym, ss);
        }
        // A class EXPRESSION's self-name symbol names the SAME class, so it owns
        // the same two member tables. Without this the name resolved to a class
        // symbol with no members at all: `const K = class Foo { static p = 1; m()
        // { return Foo.p } }` answered TS2339 for `Foo.p`, and `classStaticBlock27.ts`
        // reported six of them once static-block bodies started being checked.
        if (self_sym != no_symbol) {
            try b.member_scopes.put(b.scratch, self_sym, ms);
            try b.static_scopes.put(b.scratch, self_sym, ss);
        }
        const saved_block = b.cur_block;
        b.cur_block = node;
        defer b.cur_block = saved_block;

        // A STATIC BLOCK is the one part of a class body whose control flow
        // leaves it (see the `.block` arm). Successive blocks chain through
        // this, and the class hands it to whatever follows the declaration;
        // null means the body had none and the outer flow is untouched.
        var static_exit: ?FlowId = null;

        try b.recordOverloadSiblings(b.tree.extraRange(data.members_start, data.members_end));
        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node) continue;
            const md = b.tree.nodeData(member);
            switch (b.nodeTag(member)) {
                .class_field => {
                    const f = b.tree.extraData(ast.Field, md.lhs);
                    const is_static = f.flags & ast.Flags.static != 0;
                    const tok = b.tree.nodeMainToken(member);
                    try b.bindComputedKey(member, f.flags);
                    if (!nameless(f.flags)) {
                        _ = try b.declare(if (is_static) ss else ms, try b.memberNameKey(tok, f.flags), .property, member, tok, .{
                            .static_member = is_static,
                            .optional_member = f.flags & ast.Flags.optional != 0,
                            .readonly_member = f.flags & ast.Flags.readonly != 0,
                            .non_public = f.flags & nonpublic_mask != 0 or isPrivateNameToken(b, tok),
                        });
                    }
                    try b.bindType(f.type_ann);
                    try b.bindExpr(f.init);
                },
                .class_method => {
                    const proto = b.tree.extraData(ast.FnProto, md.lhs);
                    const is_static = proto.flags & ast.Flags.static != 0;
                    const is_get = proto.flags & ast.Flags.get != 0;
                    const is_set = proto.flags & ast.Flags.set != 0;
                    const tok = b.tree.nodeMainToken(member);
                    try b.bindComputedKey(member, proto.flags);
                    // TS1341: an ACCESSOR named `constructor` is not the
                    // constructor (tsc's parser only makes a METHOD of that name
                    // a `ConstructorDeclaration`) — it is an ordinary accessor
                    // occupying a slot the prototype reserves, which tsc rejects
                    // outright. Not gated on `static`.
                    if ((is_get or is_set) and b.tree.tokens.tag(tok) == .keyword_constructor) {
                        try b.diag(.ctor_may_not_be_accessor, tok);
                    }
                    const kind: DeclKind = if (is_get) .getter else if (is_set) .setter else .method;
                    if (!nameless(proto.flags)) {
                        // The constructor goes in the member table under a RESERVED
                        // key, tsc's `InternalSymbolName.Constructor`: `constructor`
                        // is a name a parameter property can be spelled with
                        // (`constructor(public constructor: string)`), and keying
                        // both under the literal text made every such class a
                        // duplicate-identifier pair. Nothing looks the constructor
                        // up by text — `isCtorMember`/`isCtorName` are the only two
                        // ways to ask, and both know the reserved spelling.
                        const atom = if (member_names.isCtorMethod(b.tree, member, proto.flags))
                            try b.atomOf(member_names.ctor_member_name)
                        else
                            try b.memberNameKey(tok, proto.flags);
                        _ = try b.declare(if (is_static) ss else ms, atom, kind, member, tok, .{
                            .static_member = is_static,
                            // `m?(): number` is an OPTIONAL property whose type
                            // is `(() => number) | undefined`, exactly as
                            // `m?: () => number` is — tsc reads optionality off
                            // the declaration in
                            // `getTypeOfVariableOrParameterOrProperty` and does
                            // not care whether it is a method or a field. So
                            // `c.m()` is TS2722 and `const d: C = {}` is legal.
                            //
                            // (wave-24 A) This one word could not land before a
                            // `super.<name>` reference was narrowable:
                            // `refkey.buildRefKey` bottomed out at an
                            // identifier or `this` and had no `super` root, so
                            // `super.m && super.m()` narrowed nothing and every
                            // optional method reached that way was a false
                            // TS2722 (`controlFlowSuperPropertyAccess`). The
                            // `super_flow_root` sentinel beside
                            // `this_flow_root` (refkey.zig), read by
                            // `identIsSym`/`isPatternRoot` in flow.zig, is what
                            // made it net positive.
                            .optional_member = proto.flags & ast.Flags.optional != 0,
                            .has_impl = md.rhs != 0 and !is_get and !is_set,
                            .non_public = proto.flags & nonpublic_mask != 0 or isPrivateNameToken(b, tok),
                        });
                    }
                    const is_ctor = b.tree.tokens.tag(tok) == .keyword_constructor and !is_static;
                    const ctor: CtorKind = if (!is_ctor)
                        .not_ctor
                    else if (derived)
                        .derived_ctor
                    else
                        .base_ctor;
                    try b.bindFunctionLike(member, md.lhs, md.rhs, ctor);
                },
                // `static { … }` — the parser's only `.block` class member.
                //
                // (wave-7 A: the static-block SCOPE region of `bindClass`.)
                //
                // tsc binds a ClassStaticBlockDeclaration as a function-like
                // container: its own locals, its own control-flow graph, and a
                // `this` that is the class's static side (the checker's job,
                // `checkStaticBlock`). A `.function` scope is therefore exactly
                // right — every boundary rule that reads the scope chain
                // (`var` hoisting, `arguments`, TDZ, `enclosingFnIsAsync`)
                // wants the block to BE a boundary — and the scope hangs off
                // the class scope like a method body's, not off `ss`: a member
                // table is never in the lexical chain (see
                // `resolvePrivateName`), and a bare name inside the block does
                // not see the static members (`x` is TS2304 where `this.x`
                // resolves), which is exactly what parenting at `cs` gives.
                .block => {
                    const saved_sb = b.saveState();
                    // A static block is a SCOPE boundary but not a FLOW one:
                    // it runs at class-definition time, so tsc threads the
                    // enclosing control flow straight through it. `let x:
                    // number | string = 1; class C { static { x = "a" } } x`
                    // narrows to `string`, and a variable assigned there is
                    // assigned afterwards (`classStaticBlock28` reported a
                    // false TS2454 while the block started a fresh graph).
                    // A CONDITIONAL assignment inside still leaves it
                    // possibly-unassigned, which falls out of the same splice
                    // — verified against the oracle all three ways.
                    if (static_exit) |f| b.cur_flow = f;
                    const sbs = try b.pushScope(.function, member);
                    b.var_scope = sbs;
                    b.ctx_base = b.ctxs.items.len;
                    // No `return` may reach out of a static block (TS18041), so
                    // there is no return target to join into.
                    b.ctor_return = null;
                    try b.recordOverloadSiblings(b.tree.nodeRange(member));
                    for (b.tree.nodeRange(member)) |stmt| try b.bindStatement(stmt);
                    static_exit = b.cur_flow;
                    b.restoreState(saved_sb);
                },
                .decorator => try b.bindExpr(md.lhs),
                .error_node, .unsupported => {},
                else => {},
            }
        }
        try b.checkDuplicateIndexSignatures(b.tree.extraRange(data.members_start, data.members_end));
        b.restoreState(saved);
        // A static block's flow is the class declaration's own continuation.
        // Nothing else in the body leaks: a computed member NAME assigns at
        // class-definition time too, but tsc still calls the variable
        // unassigned afterwards (`privateNameComputedPropertyName2`), so the
        // restore above is what the rest of the body gets.
        if (static_exit) |f| b.cur_flow = f;
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
        // Which BLOCK of the namespace this is, so a name declared in two blocks
        // can be told from one declared twice in one (`mergesAcrossBlocks`).
        const saved_block = b.cur_block;
        b.cur_block = node;
        defer b.cur_block = saved_block;
        // In an ambient namespace (`declare namespace`, or one nested inside
        // an ambient namespace) every member is implicitly exported: bind the
        // body with `exporting_node` pinned to the namespace so each member's
        // `noteExport` marks it visible as `N.member`. Otherwise members need
        // an explicit `export` (so plain `namespace` members stay private).
        const was_ambient = b.ambient;
        const is_ambient = was_ambient or (data.flags & ast.Flags.declare != 0);
        b.ambient = is_ambient;
        defer b.ambient = was_ambient;
        const saved_export = b.clearExportCtx();
        defer b.restoreExportCtx(saved_export);
        // A `declare namespace` body exports its members implicitly, so the
        // context is re-armed at the block itself rather than cleared.
        if (is_ambient) b.exporting_node = node;

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

        try b.recordOverloadSiblings(b.tree.extraRange(data.body_start, data.body_end));
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
        const saved_export = b.clearExportCtx();
        defer b.restoreExportCtx(saved_export);

        try b.scope_stack.append(b.scratch, gs);
        b.cur_scope = gs;
        b.var_scope = gs;
        b.ctx_base = b.ctxs.items.len;
        b.cur_flow = try b.addFlow(.start, no_flow, node);

        try b.recordOverloadSiblings(b.tree.extraRange(data.body_start, data.body_end));
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
    ///
    /// The block scope's PARENT is the ENCLOSING scope, not the file scope. At
    /// the top level those are the same thing; nested — `declare module "Map" {
    /// import { Cls } from "M"; module "Observable" { interface Observable {
    /// foo(): Cls } } }` — they are not, and tsc resolves `Cls` by walking the
    /// node parent chain out through the enclosing module block, where the
    /// import lives. Parenting to `file_scope` reported TS2304 for it
    /// (moduleAugmentationInAmbientModule1-4); `bindGlobalAugmentation` already
    /// parents its block the same way, which is why the `global { … }` spelling
    /// of the same test (…5) was the one that passed.
    fn bindAmbientModule(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.NamespaceData, d.lhs);
        const spec = try b.atomOf(stripModuleQuotes(b.tokenText(data.name_token)));
        const ms = try b.newScope(.namespace, node, b.cur_scope);
        const export_start: u32 = @intCast(b.export_recs.items.len);

        const saved = b.saveState();
        const was_ambient = b.ambient;
        b.ambient = true;
        defer b.ambient = was_ambient;
        const saved_export = b.clearExportCtx();
        defer b.restoreExportCtx(saved_export);
        const saved_mod_scope = b.ambient_mod_scope;
        b.ambient_mod_scope = ms;
        defer b.ambient_mod_scope = saved_mod_scope;

        try b.scope_stack.append(b.scratch, ms);
        b.cur_scope = ms;
        b.var_scope = ms;
        b.ctx_base = b.ctxs.items.len;
        b.cur_flow = try b.addFlow(.start, no_flow, node);

        try b.recordOverloadSiblings(b.tree.extraRange(data.body_start, data.body_end));
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

        const members = b.tree.extraRange(data.members_start, data.members_end);
        for (members) |member| {
            if (member == null_node) continue;
            try b.bindTypeMember(member, ms);
        }
        try b.checkDuplicateIndexSignatures(members);
        b.popScope(saved_scope);
    }

    /// TS2374 for the index signatures of ONE member list — a class body, an
    /// `interface` block, or an object-type literal — that share a key domain
    /// with a sibling (`index_signature.duplicateKey`).
    ///
    /// Only INSTANCE signatures: `static [k: string]` lives on the class value's
    /// type, which tsc's `getIndexSymbol(classSymbol)` never reads, so two
    /// static signatures are silently accepted (measured) and a static beside an
    /// instance one is not a pair at all.
    ///
    /// One list at a time, so signatures pooled across a merged declaration
    /// (`interface A {…} interface A {…}`, or a class beside its `interface`
    /// half) go unreported — an under-report, and the only part of the rule that
    /// would need symbol-level index-signature identity to answer.
    fn checkDuplicateIndexSignatures(b: *Binder, members: []const Node) Error!void {
        // Two parallel scratch lists rather than a struct: `duplicateKey` takes
        // the keys as a slice, and every member list in real code has zero or
        // one index signature, so the loop below usually appends nothing.
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(b.scratch);
        var sites: std.ArrayList(Node) = .empty;
        defer sites.deinit(b.scratch);
        for (members) |member| {
            if (member == null_node or b.nodeTag(member) != .index_signature) continue;
            const md = b.tree.nodeData(member);
            if (md.rhs & ast.Flags.static != 0) continue;
            const e = b.tree.extraData(ast.IndexSig, md.lhs);
            // tsc reads `declaration.parameters.length === 1 &&
            // declaration.parameters[0].type` before anything else, so a
            // signature the grammar already rejected for its parameter COUNT
            // claims no key domain — `[a: string, b: string]` beside
            // `[c: string]` is not a duplicate pair. The parser decided that
            // (`index_signature.check`) and reported it at this very token, so
            // the answer is read back rather than recomputed.
            if (b.indexSigParamCountRejected(e.name_token)) continue;
            if (e.key_type == null_node or b.nodeTag(e.key_type) == .error_node) continue;
            const span = b.tree.span(b.src, e.key_type);
            try keys.append(b.scratch, b.src[span.start..span.end]);
            try sites.append(b.scratch, member);
        }
        if (keys.items.len < 2) return;
        for (sites.items, 0..) |member, i| {
            if (!index_signature.duplicateKey(keys.items, i)) continue;
            const start = index_signature.memberStartToken(&b.tree.tokens, b.tree.nodeMainToken(member));
            try b.diag(.duplicate_index_signature, start);
        }
    }

    /// Did the parser answer TS1096 ("An index signature must have exactly one
    /// parameter") for the signature whose first parameter is `name_token`?
    ///
    /// That diagnostic is anchored on exactly this token (`index_signature`'s
    /// chain reports `shape.name_token`, which is what the parser stores as
    /// `IndexSig.name_token`), so the match is a span-start equality rather than
    /// a containment test. Almost every file carries no parse diagnostics at
    /// all, and this is only reached for a member list with two or more index
    /// signatures.
    fn indexSigParamCountRejected(b: *const Binder, name_token: TokenIndex) bool {
        if (b.tree.diagnostics.len == 0) return false;
        const start = b.tree.tokens.start(name_token);
        for (b.tree.diagnostics) |d| {
            if (d.code == .index_sig_one_parameter and d.span.start == start) return true;
        }
        return false;
    }

    /// A member of an interface or object-type literal.
    fn bindTypeMember(b: *Binder, member: Node, ms: ScopeId) Error!void {
        const md = b.tree.nodeData(member);
        switch (b.nodeTag(member)) {
            .property_signature => {
                const tok = b.tree.nodeMainToken(member);
                try b.bindComputedKey(member, md.rhs);
                if (!nameless(md.rhs)) {
                    _ = try b.declare(ms, try b.memberNameKey(tok, md.rhs), .property, member, tok, .{
                        .optional_member = md.rhs & ast.Flags.optional != 0,
                        .readonly_member = md.rhs & ast.Flags.readonly != 0,
                    });
                }
                try b.bindType(md.lhs);
            },
            .method_signature => {
                const tok = b.tree.nodeMainToken(member);
                const is_get = md.rhs & ast.Flags.get != 0;
                const is_set = md.rhs & ast.Flags.set != 0;
                const kind: DeclKind = if (is_get) .getter else if (is_set) .setter else .method;
                try b.bindComputedKey(member, md.rhs);
                if (!nameless(md.rhs)) {
                    _ = try b.declare(ms, try b.memberNameKey(tok, md.rhs), kind, member, tok, .{});
                }
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

    /// TS2528, once per file: which of the file's `export default`s cannot share
    /// the `default` export slot. The rule (and why "more than one" is the wrong
    /// test) is default_exports.zig; this half maps the export records onto it
    /// and owns the report positions — tsc's `getNameOfDeclaration(decl) ||
    /// decl`, i.e. the declaration's own name, or the whole `export default`
    /// statement when it declares none.
    ///
    /// Only file-scope records take part. A `declare module "spec" { export
    /// default … }` block is a container of its own and would need its own slot;
    /// mixing the two would report a clash between declarations that never
    /// shared a table.
    fn checkDefaultExportClashes(b: *Binder) Error!void {
        var kinds: std.ArrayList(default_exports.Kind) = .empty;
        defer kinds.deinit(b.scratch);
        var toks: std.ArrayList(TokenIndex) = .empty;
        defer toks.deinit(b.scratch);
        for (b.export_recs.items) |rec| {
            if (rec.kind != .default or rec.scope != file_scope) continue;
            const inner = b.tree.nodeData(rec.node).lhs;
            // `getNameOfDeclaration`: the declared name when there is one. An
            // anonymous `export default function () {}` and an expression that
            // is not an entity name both fall back to the statement, which is
            // why those keys sit at the `export` keyword.
            var tok = b.tree.nodeMainToken(rec.node);
            const kind: default_exports.Kind = switch (b.nodeTag(inner)) {
                .function_decl => k: {
                    const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(inner).lhs);
                    if (proto.name_token != 0) tok = proto.name_token;
                    break :k .function;
                },
                .class_decl => k: {
                    const data = b.tree.extraData(ast.ClassData, b.tree.nodeData(inner).lhs);
                    if (data.name_token != 0) tok = data.name_token;
                    break :k .class_;
                },
                .interface_decl => k: {
                    const data = b.tree.extraData(ast.InterfaceData, b.tree.nodeData(inner).lhs);
                    if (data.name_token != 0) tok = data.name_token;
                    break :k .interface_;
                },
                // `export default Foo` — an ALIAS to every meaning `Foo` has,
                // and the one expression form that reports on its own name.
                .identifier => k: {
                    tok = b.tree.nodeMainToken(inner);
                    break :k .alias;
                },
                else => .property,
            };
            try kinds.append(b.scratch, kind);
            try toks.append(b.scratch, tok);
        }
        if (kinds.items.len < 2) return;
        const out = try b.scratch.alloc(bool, kinds.items.len);
        defer b.scratch.free(out);
        default_exports.clashing(kinds.items, out);
        for (out, toks.items) |clashes, tok| {
            if (clashes) try b.diag(.multiple_default_exports, tok);
        }
    }

    fn bindExportDefault(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const inner = d.lhs;
        var local: Atom = 0;
        var sym: SymbolId = no_symbol;
        // The declaration forms below publish under `default`, not under their
        // own name, so their local name declares no meaning — see
        // `in_export_default`. The expression form declares nothing at all.
        const saved_default = b.in_export_default;
        b.in_export_default = true;
        defer b.in_export_default = saved_default;
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
            // `export default interface I { … }` — the one TYPE-side default
            // export form. Like the class case: a declaration carrying an
            // export-default modifier, so the name is declared in the file
            // scope and ALSO recorded as the module's default.
            .interface_decl => {
                const data = b.tree.extraData(ast.InterfaceData, b.tree.nodeData(inner).lhs);
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
        var name_tok: TokenIndex = 0;
        if (entity != 0) {
            try b.bindExpr(entity);
            if (b.nodeTag(entity) == .identifier) {
                name_tok = b.tree.nodeMainToken(entity);
                local = try b.atomOfToken(name_tok);
            }
        }
        // A container may have only ONE export assignment: tsc reports TS2300
        // ("Duplicate identifier 'export='") at the ENTITY of every one of them
        // when there are two or more (`duplicateExportAssignments`). Only the
        // identifier form is named — for any other expression there is no single
        // token to point at, and an under-report is the safe direction.
        if (name_tok != 0) {
            const gop = try b.export_eq_first.getOrPut(b.scratch, b.cur_scope);
            if (gop.found_existing) {
                if (!gop.value_ptr.reported) {
                    try b.diag(.duplicate_identifier, gop.value_ptr.tok);
                    gop.value_ptr.reported = true;
                }
                try b.diag(.duplicate_identifier, name_tok);
            } else {
                gop.value_ptr.* = .{ .tok = name_tok };
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
        try b.checkNamespaceImportDecl(data.module_token);
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
    ///   - the target is `<identifier>.<name>`, or `<identifier>["name"]` /
    ///     `<identifier>[42]` — tsc's `isBindableStaticElementAccessExpression`,
    ///     whose `isLiteralLikeElementAccess` accepts exactly a string or
    ///     numeric literal argument. `decl["B"] = 'foo'` declares `B`, and
    ///     `decl3[77] = 0` declares `77` (`declarationEmitLateBoundAssignments2`).
    ///   - the identifier resolves *in the current scope* (tsc's same-scope
    ///     rule) to a symbol whose declaration is a `function` or a variable
    ///     initialized with a function expression / arrow.
    ///
    /// Everything else is left to ordinary assignment checking, so `const obj
    /// = {}; obj.x = 1` stays the TS2339 tsc reports. Repeated assignments to
    /// one name merge into a single property whose declarations are all the
    /// assignments.
    ///
    ///   - `decl[k] = 0` for a `const k` of literal type (or a `const k` that is
    ///     a `unique symbol`) is late-bound too, but the NAME is the const's
    ///     TYPE, which no binder can see. The member is declared under the
    ///     computed-key placeholder `__@k$k` and the checker rekeys it once the
    ///     const's type is in hand (`signatures.expandoProps` →
    ///     `nominalizeComputedKey`), dropping it when the key turns out not to
    ///     be late-bindable at all (`let k = "Y"`).
    fn bindExpandoAssignment(b: *Binder, node: Node) Error!void {
        if (b.nodeTag(node) != .assign) return;
        if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) != .eq) return;
        const d = b.tree.nodeData(node);
        const key = expandoTargetName(b, d.lhs) orelse return;
        const td = b.tree.nodeData(d.lhs);
        if (b.nodeTag(td.lhs) != .identifier) return;

        const obj_atom = try b.atomOfToken(b.tree.nodeMainToken(td.lhs));
        const sym = b.expandoTargetSym(obj_atom) orelse return;
        if (!b.isFunctionValueSymbol(sym)) return;

        var xs = b.expando_scopes.get(sym) orelse 0;
        if (xs == 0) {
            xs = try b.newScope(.expando, node, b.cur_scope);
            try b.expando_scopes.put(b.scratch, sym, xs);
        }
        const atom = if (key.computed)
            try b.computedSymPlaceholder(b.tokenText(key.tok))
        else
            try b.memberAtom(key.tok);
        _ = try b.declare(xs, atom, .expando_member, node, key.tok, .{});
        b.sym_flags.items[sym].expando = true;
    }

    /// The property-name token of an expando assignment target, plus whether it
    /// still needs the checker's late-bound rekey.
    const ExpandoKey = struct { tok: TokenIndex, computed: bool = false };

    /// The property name an expando assignment target names, or null when the
    /// target is not one of the bindable shapes: `obj.name` (the name token),
    /// ``obj["name"]`` / ``obj[`name`]`` / `obj[42]` (the literal's token), and
    /// `obj[k]` for a plain identifier key — the last of which names nothing
    /// syntactically and is reported `computed` so the caller keys it by a
    /// placeholder. A key that is neither a literal nor a bare identifier
    /// (`obj[Symbol()]`, `obj[a.b]`) is not bindable at all. The
    /// template-literal arm is tsc's `isStringLiteralLike`, which a
    /// no-substitution template satisfies.
    fn expandoTargetName(b: *Binder, target: Node) ?ExpandoKey {
        const d = b.tree.nodeData(target);
        switch (b.nodeTag(target)) {
            .member_expr => return if (d.rhs == 0) null else .{ .tok = d.rhs },
            .index_expr => {
                if (d.rhs == null_node) return null;
                return switch (b.nodeTag(d.rhs)) {
                    .string_literal, .template_literal, .number_literal => .{ .tok = b.tree.nodeMainToken(d.rhs) },
                    .identifier => .{ .tok = b.tree.nodeMainToken(d.rhs), .computed = true },
                    else => null,
                };
            },
            else => return null,
        }
    }

    /// The function value an expando assignment's target names. tsc's
    /// `bindPropertyAssignment` looks the name up in *two* scopes —
    /// `blockScopeContainer` and `container` — so an assignment written inside
    /// an `if` block still finds the `function d() {}` declared in the
    /// enclosing function or module:
    ///
    ///     function d() {}
    ///     if (b) { d.q = false }      // declares `q` on `d`
    ///     d.q
    ///
    /// Looking only at the innermost scope left every conditionally-assigned
    /// expando property off the function's type (a TS2339 on each read).
    /// Intermediate blocks are walked through but never *matched* on, which is
    /// tsc's shape exactly: it consults the innermost block and the function
    /// container, nothing in between.
    fn expandoTargetSym(b: *Binder, obj_atom: Atom) ?SymbolId {
        if (b.members.get(memberKey(b.cur_scope, obj_atom))) |s| return s;
        var s = b.cur_scope;
        while (s != 0) {
            switch (b.scope_kinds.items[s]) {
                // The innermost scope IS the container: already tried.
                .function, .file, .namespace => return null,
                .block, .for_head, .catch_clause => {},
                // Any other scope (class body, enum, …) is not a statement
                // container an expando assignment can sit directly in.
                else => return null,
            }
            const p = b.scope_parents.items[s];
            if (p == s) return null;
            s = p;
            switch (b.scope_kinds.items[s]) {
                .function, .file, .namespace => return b.members.get(memberKey(s, obj_atom)),
                else => {},
            }
        }
        return null;
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
            const taken = try b.addFlow(.chain_taken, b.cur_flow, recv);
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
        for (tests) |t| try b.pendAdd(pid, try b.addFlow(.chain_short, t.ante, t.expr));
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
            try b.pendAdd(pid, try b.addFlow(.chain_short, sc.ante, sc.expr));
        }
        try b.pendAdd(pid, try b.addFlow(.cond_false, b.cur_flow, node));
        b.cur_flow = pre;
        return .{ .t = t, .f = try b.finishPending(pid) };
    }

    /// A `super` reaching for a PROPERTY inside a derived class's constructor —
    /// the TS17011 half of the `this`-before-`super` rule, recorded with the
    /// flow in effect exactly as a `this` is.
    ///
    /// tsc's condition is "any `super` that is not the callee of its own call",
    /// but the only OTHER legal shape is a property access: a bare `super` is
    /// TS1034 in tsc's parser, which suppresses the file's whole semantic pass,
    /// so reporting nothing there is what matches. Measured: `superAccess2.ts`
    /// (`xx = super`, `constructor(public z = super, …)`) answers TS1034 five
    /// times and no TS17011, and `super<T>()` — whose callee is a bare `super`
    /// under a type-argument list — answers TS2754 alone.
    fn noteSuperProperty(b: *Binder, recv: Node) Error!void {
        if (!b.in_derived_ctor or b.nodeTag(recv) != .super_expr) return;
        try b.this_in_derived_ctor.append(b.scratch, .{ .value = recv, .next = b.cur_flow });
    }

    fn bindExpr(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => try b.bindIdentifierRef(node),
            .member_expr, .optional_member_expr => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
                try b.noteSuperProperty(d.lhs);
                // Narrowable reference (`x.y` discriminants): attach flow.
                try b.attachFlow(node);
                // `x.length` — the read-only half of tsc's
                // `isEvolvingArrayOperationTarget` (`x.push`/`x.unshift` are
                // recorded by the CALL arm, since tsc requires the call).
                // `x?.length` counts too: tsc's test is `isPropertyAccess-
                // Expression(parent)`, and a `?.` access is one
                // (`narrowSwitchOptionalChainContainmentEvolvingArrayNoCrash1.ts`
                // switches on exactly `foo?.length`).
                if (b.isNamedMember(node, "length")) {
                    const recv = narrowableOperandIdent(b.tree, d.lhs);
                    if (recv != null_node) try b.noteArrayOpTarget(recv, null_node);
                }
            },
            .non_null => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
            },
            .index_expr, .optional_index_expr => {
                if (b.isOptionalChain(node) and b.chainHasRest(node)) return b.bindOptionalChainValue(node);
                try b.bindExpr(d.lhs);
                try b.bindExpr(d.rhs);
                try b.noteSuperProperty(d.lhs);
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
                // `x = class { … }` / `o.x = class { … }` name the class too,
                // but only a plain `=` does — a compound assignment is a read
                // and a write of an already-named binding.
                if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) == .eq) {
                    try b.bindNamedExpr(d.rhs, b.plainNameToken(b.assignedNameToken(d.lhs)));
                } else {
                    try b.bindExpr(d.rhs);
                }
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                // tsc's `bindBinaryExpressionFlow`: `x[i] = v` can GROW an
                // evolving array, so it gets its own flow node on top of the
                // assignment one (which stands for the write to `x[i]`).
                if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) == .eq and
                    b.nodeTag(d.lhs) == .index_expr)
                {
                    const idx = b.tree.nodeData(d.lhs);
                    const recv = narrowableOperandIdent(b.tree, idx.lhs);
                    if (recv != null_node) {
                        try b.noteArrayOpTarget(recv, idx.rhs);
                        b.cur_flow = try b.addFlow(.array_mutation, b.cur_flow, node);
                    }
                }
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
                    .amp_amp, .pipe_pipe, .question_question => {
                        // Value position: bind as condition, then join.
                        // tsc's `bindBinaryExpressionFlow` treats all three
                        // short-circuiting operators alike here
                        // (`isLogicalOrCoalescingBinaryOperator`).
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
                if (b.nodeTag(node) != .new_expr_targs) {
                    // `super<T>()`: type arguments do not change what the call
                    // IS — tsc's `isSuperCall` and `bindCallExpressionFlow` look
                    // only at the callee — so it advances the flow and counts as
                    // the constructor's super call exactly as a bare `super()`
                    // does. Without this `superWithTypeArgument.ts` was a false
                    // TS2377.
                    try b.bindSuperCall(node, d.lhs);
                    try b.bindArrayMutationCall(node, d.lhs);
                }
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
                                try b.bindExpr(pd.rhs);
                            } else {
                                try b.bindNamedExpr(pd.rhs, b.plainNameToken(b.tree.nodeMainToken(prop)));
                            }
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
            .arrow_fn, .function_expr => try b.bindFunctionLike(node, d.lhs, d.rhs, .not_ctor),
            .class_decl => try b.bindClass(node, false, 0), // class expression
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
            .new_target,
            .import_expr,
            .omitted,
            .error_node,
            .unsupported,
            .empty_stmt,
            .debugger_stmt,
            => {},

            .super_expr => {},

            // A leaf as far as names go, but a NARROWABLE reference all the
            // same: tsc's `checkThisExpression` hands `tryGetThisTypeAt`'s
            // answer to `getFlowTypeOfReference`, so `if (this.isFoo()) { const
            // f: Foo = this }` refines the bare keyword exactly as it refines
            // `this.p`. The checker's `this_flow_root` sentinel is the key that
            // matches it (`flow.identIsSym`), and it can only be queried at a
            // node the binder gave a flow to.
            //
            // Inside a derived class's constructor the keyword's position
            // relative to the `super(...)` call is also a diagnostic (TS17009)
            // — recorded with the flow in effect and answered once the file's
            // flow graph is complete. The `super` half of that rule is
            // `noteSuperProperty`.
            .this_expr => {
                try b.attachFlow(node);
                if (b.in_derived_ctor) {
                    try b.this_in_derived_ctor.append(b.scratch, .{ .value = node, .next = b.cur_flow });
                }
            },

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
                try b.bindSuperCall(node, d.lhs);
                try b.bindArrayMutationCall(node, d.lhs);
            },

            // Everything else: recurse over expression children generically.
            else => {
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindExpr(child);
            },
        }
    }

    /// tsc's `bindCallExpressionFlow` for a `super(...)` call: it advances the
    /// flow — in ANY position, not just as a statement — so that `this` after it
    /// can be told apart from `this` before it (TS17009), and it is the call
    /// TS2377 asks the constructor for. Called AFTER the arguments are bound,
    /// as in tsc, which is why `super(this)` still reports.
    ///
    /// A no-op for every other callee, so both call shapes hand it theirs.
    fn bindSuperCall(b: *Binder, node: Node, callee: Node) Error!void {
        if (b.nodeTag(callee) != .super_expr) return;
        b.cur_flow = try b.addFlow(.call_stmt, b.cur_flow, node);
        try b.super_call_flows.append(b.scratch, b.cur_flow);
        b.saw_super_call = true;
    }

    /// Is `node` a (non-optional) `obj.<name>` member access?
    fn isNamedMember(b: *Binder, node: Node, name: []const u8) bool {
        const rhs = b.tree.nodeData(node).rhs;
        if (rhs == 0) return false;
        return std.mem.eql(u8, b.tokenText(rhs), name);
    }

    /// tsc's `bindCallExpressionFlow` array-mutation arm: `x.push(…)` and
    /// `x.unshift(…)` grow an EVOLVING array, so the call advances the flow
    /// with a node the checker reads the pushed element types off
    /// (`getTypeAtFlowArrayMutation`), and the receiver read is exempt from
    /// the type the array has evolved to so far.
    ///
    /// tsc admits any narrowable operand as the receiver; this is restricted
    /// to a plain IDENTIFIER, because only a variable of the auto/auto-array
    /// type ever evolves — a dotted receiver would build a flow node that no
    /// query can ever match, and pay for it in every walk that passes through.
    fn bindArrayMutationCall(b: *Binder, node: Node, callee: Node) Error!void {
        if (b.nodeTag(callee) != .member_expr) return;
        const recv = narrowableOperandIdent(b.tree, b.tree.nodeData(callee).lhs);
        if (recv == null_node) return;
        if (!b.isNamedMember(callee, "push") and !b.isNamedMember(callee, "unshift")) return;
        try b.noteArrayOpTarget(recv, null_node);
        b.cur_flow = try b.addFlow(.array_mutation, b.cur_flow, node);
    }

    /// Record `node` as an evolving-array operation target (see
    /// `Bind.array_op_nodes`). `index` is the index expression whose type the
    /// checker still has to find number-like, or `null_node`.
    fn noteArrayOpTarget(b: *Binder, node: Node, index: Node) Error!void {
        try b.array_ops.append(b.scratch, .{ .value = node, .next = index });
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

    /// tsc's `isLogicalExpression`: a `&&` / `||` / `??`, seen through
    /// parentheses AND `!`. Those build their own condition edges, so the
    /// enclosing `bindCondition` must not add a leaf pair on top.
    fn isLogicalExpr(b: *const Binder, node: Node) bool {
        var n = node;
        while (n != null_node) {
            const d = b.tree.nodeData(n);
            switch (b.nodeTag(n)) {
                .paren_expr => n = d.lhs,
                .prefix_unary => {
                    if (b.tree.tokens.tag(b.tree.nodeMainToken(n)) != .bang) return false;
                    n = d.lhs;
                },
                .binary => return switch (b.tree.tokens.tag(b.tree.nodeMainToken(n))) {
                    .amp_amp, .pipe_pipe, .question_question => true,
                    else => false,
                },
                else => return false,
            }
        }
        return false;
    }

    /// The LEFT operand of `??`, bound as a condition.
    ///
    /// tsc decides "this test is about NULLISHNESS, not truthiness" in
    /// `narrowType`, by looking UP from the flow node's expression:
    /// `isBinaryExpression(expr.parent) && parent.operatorToken === ?? &&
    /// parent.left === expr`. ztsc's AST carries no parent links, so the two
    /// leaf edges record the `??` node itself instead and the checker reads
    /// the operand back off it — the marker is unambiguous because the `??`
    /// node never appears on a flow edge any other way (as a whole condition
    /// it contributes only its operands' joins).
    ///
    /// A left operand that builds its OWN edges — a nested `&&`/`||`/`??`
    /// (through parens and `!`, exactly tsc's `isLogicalExpression`) or an
    /// optional chain — is delegated unchanged: in tsc those inner operands'
    /// parent is not the `??` either, so they narrow by truthiness.
    fn bindNullishTest(b: *Binder, lhs: Node, qq: Node) Error!CondFlows {
        if (b.isLogicalExpr(lhs) or (lhs != null_node and b.isOptionalChain(lhs))) {
            return b.bindCondition(lhs);
        }
        try b.bindExpr(lhs);
        return .{
            .t = try b.addFlow(.cond_true, b.cur_flow, qq),
            .f = try b.addFlow(.cond_false, b.cur_flow, qq),
        };
    }

    /// Bind a condition expression, producing the flows for its true and
    /// false outcomes. Decomposes `&&`, `||`, `??`, `!`, and parens so the
    /// checker can narrow each operand
    /// (truthiness/nullishness/typeof/equality/discriminant).
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
                // tsc's `bindLogicalLikeExpression` routes `??` through the
                // very same `else` arm as `||`: the right operand is reached
                // from the left's FALSE outcome, and both operands' true
                // outcomes join. What differs is only what "false" MEANS for
                // the left operand — nullish, not falsy — and that is
                // `bindNullishTest`'s job.
                .question_question => {
                    const lhs = try b.bindNullishTest(d.lhs, node);
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
                try b.checkDuplicateIndexSignatures(b.tree.nodeRange(node));
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
            try b.bindParam(param, .{});
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
                // Target, continuation, then the reduced antecedent list.
                .reduce_label => {
                    const ed = b.reduce_edges.items[b.flow_b.items[i]];
                    const p = b.pendings.items[b.flow_a.items[i]];
                    flow_a[i] = @intCast(extra.items.len);
                    try extra.append(b.scratch, ed.target);
                    try extra.append(b.scratch, ed.antecedent);
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

        // Evolving-array operation targets, sorted by node id and deduped (a
        // node can be visited twice — an optional chain re-binds its value
        // form — and the entries for one node are identical anyway).
        std.mem.sort(Link, b.array_ops.items, {}, struct {
            fn lessThan(_: void, x: Link, y: Link) bool {
                return x.value < y.value;
            }
        }.lessThan);
        var n_ops: usize = 0;
        for (b.array_ops.items) |pair| {
            if (n_ops != 0 and b.array_ops.items[n_ops - 1].value == pair.value) continue;
            b.array_ops.items[n_ops] = pair;
            n_ops += 1;
        }
        const array_op_nodes = try arena.alloc(Node, n_ops);
        const array_op_indexes = try arena.alloc(Node, n_ops);
        for (b.array_ops.items[0..n_ops], 0..) |pair, i| {
            array_op_nodes[i] = pair.value;
            array_op_indexes[i] = pair.next;
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
            .array_op_nodes = array_op_nodes,
            .array_op_indexes = array_op_indexes,
            .alias_merges = try arena.dupe(AliasMerge, b.alias_merges.items),
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
        try b.checkDefaultExportClashes();
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
        \\flow: nodes=5 attach=0 (start=2 assign=3 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
        \\
    );
}

test "golden: function declaration in a block is block-scoped (modern semantics)" {
    try expectDump("{ function g() {} }",
        \\scope 0: file
        \\  scope 1: block
        \\    g: function impl
        \\    scope 2: function g
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=4 attach=3 (start=1 assign=3 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\      __@ctor: method impl
        \\      z: property
        \\    scope 3: class_statics C
        \\      y: property static
        \\      s: method static impl
        \\    scope 4: function m
        \\      p: param
        \\    scope 5: function s
        \\    scope 6: function constructor
        \\      z: param
        \\flow: nodes=4 attach=1 (start=4 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=2 attach=3 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=4 attach=3 (start=1 assign=0 cond=0 branch=1 loop=0 switch=0 call=2 arraymut=0 reduce=0)
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
        \\flow: nodes=8 attach=5 (start=1 assign=3 cond=2 branch=0 loop=2 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=3 attach=0 (start=2 assign=1 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0 call=0 arraymut=0 reduce=0)
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
    // Enum+enum and enum+namespace still merge. Two blocks whose first member
    // omits its initializer are TS2432 (`checkEnumFirstMembers`) and not a
    // failed merge; giving the second block's first member a value keeps the
    // pair silent.
    try expectBindCodes("enum E { A } enum E { B }", &.{.enum_first_member_needs_initializer});
    try expectBindCodes("enum E { A } enum E { B = 1 }", &.{});
    try expectBindCodes("enum E { A } namespace E { export const v = 1; }", &.{});
    try testing.expectEqual(@as(u16, 2567), Code.enum_merge_conflict.tsCode());
}

test "merged declarations must agree on visibility (TS2395)" {
    const both: []const Code = &.{ .merged_decl_export_mismatch, .merged_decl_export_mismatch };
    // One space claimed twice with disagreeing visibility, in a namespace body
    // and at the top level of a module.
    try expectBindCodes("namespace N { interface I {} export interface I {} }", both);
    try expectBindCodes("namespace N { export interface I {} interface I {} }", both);
    try expectBindCodes("interface c {} export interface c {}", both);
    try expectBindCodes("interface d {} export class d {}", both);
    try expectBindCodes("namespace M {} export namespace M {}", both);
    try expectBindCodes("namespace M { var v: string; export var v: string; }", both);
    // An `export`ed declaration leaves nothing in `locals` for a later local one
    // to collide with, so this pair is TS2395 and NOT a duplicate identifier —
    // while the reverse order stays a duplicate and earns no TS2395.
    try expectBindCodes("export type A = {}; type A = {}", both);
    try expectBindCodes("type A = {}; export type A = {}", &.{ .duplicate_identifier, .duplicate_identifier });
    // No space in common: a type, a namespace and a value can share a name.
    try expectBindCodes("type t = 0; namespace t { interface I {} } export const t = 0;", &.{});
    try expectBindCodes("interface b {} export const b = 1;", &.{});
    // Each block of a reopened namespace has its own `locals`, so a local in one
    // block beside an `export`ed one in another is legal.
    try expectBindCodes(
        "namespace M { export interface E {} interface I {} } namespace M { interface E {} export interface I {} }",
        &.{},
    );
    // A script's top level has no export table to disagree with.
    try expectBindCodes("interface c {} interface c {}", &.{});
    try testing.expectEqual(@as(u16, 2395), Code.merged_decl_export_mismatch.tsCode());
}

test "an overload set needs an implementation (TS2391, TS2390)" {
    try expectBindCodes("function f();", &.{.missing_function_implementation});
    try expectBindCodes("function f(): void; function f() {}", &.{});
    // The LAST non-ambient declaration is the one named, whether or not an
    // earlier one had a body.
    try expectBindCodes(
        "class C { m(n: number): string; m(x: any) { return \"\"; } m(s: string): string; }",
        &.{.missing_function_implementation},
    );
    try expectBindCodes("class C { static s(): void; }", &.{.missing_function_implementation});
    try expectBindCodes("class C { constructor(); }", &.{.missing_constructor_implementation});
    try expectBindCodes("namespace N { function f(): void; }", &.{.missing_function_implementation});
    // Ambient, `abstract`, optional, accessor, and interface/type-literal
    // members are all legally bodyless.
    try expectBindCodes("declare function f(): void;", &.{});
    try expectBindCodes("declare class C { m(): void; }", &.{});
    try expectBindCodes("declare namespace N { function f(): void; }", &.{});
    try expectBindCodes("abstract class C { abstract m(): void; }", &.{});
    try expectBindCodes("class C { m?(): void; }", &.{});
    try expectBindCodes("interface I { m(): void; }", &.{});
    try expectBindCodes("type T = { m(): void };", &.{});
    try testing.expectEqual(@as(u16, 2391), Code.missing_function_implementation.tsCode());
    try testing.expectEqual(@as(u16, 2390), Code.missing_constructor_implementation.tsCode());
}

test "a namespace may not precede the class or function it merges with (TS2434)" {
    try expectBindCodes("namespace m { var y = 2; } function m() {}", &.{.namespace_prior_to_merge});
    try expectBindCodes("namespace m { export var y = 2; } class m {}", &.{.namespace_prior_to_merge});
    // Legal: the namespace comes second, is type-only, or the merge partner is
    // ambient / an overload signature with no body.
    try expectBindCodes("function m() {} namespace m { export var y = 2; }", &.{});
    try expectBindCodes("namespace m {} function m() {}", &.{});
    try expectBindCodes("namespace m { export var y = 2; } declare function m(): void;", &.{});
    try expectBindCodes("namespace m { export interface I { a: number } } function m() {}", &.{});
    try testing.expectEqual(@as(u16, 2434), Code.namespace_prior_to_merge.tsCode());
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

test "dup: an import merges with a local declaration, two imports are TS2300" {
    // tsc's `AliasExcludes = Alias`: an import binding merges with every
    // other meaning at bind time. Whether the pair is legal depends on the
    // meanings of the import's TARGET, which only the checker can resolve —
    // TS2440 is `checker/alias_conflict.zig`'s (in either order).
    try expectBindCodes("import { a } from \"./m\"; let a = 1;", &.{});
    try expectBindCodes("let a = 1; import { a } from \"./m\";", &.{});
    try expectBindCodes("import type { T } from \"./m\"; let T = 1;", &.{});
    try expectBindCodes("import type { T } from \"./m\"; type T = number;", &.{});
    // Two imports of one name are an ordinary duplicate, at both spellings.
    try expectBindCodes(
        "import { a } from \"./m\"; import { a } from \"./n\";",
        &.{ .duplicate_identifier, .duplicate_identifier },
    );
    try expectBindCodes(
        "import type { T } from \"./m\"; import { T } from \"./n\";",
        &.{ .duplicate_identifier, .duplicate_identifier },
    );
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
            .reduce_label => {
                // target + continuation + at least one reduced antecedent.
                try testing.expect(b.flow_a[f] + 2 < b.flow_b[f]);
                try testing.expect(b.flow_b[f] <= b.flow_extra.len);
                for (b.flow_extra[b.flow_a[f]..b.flow_b[f]]) |a| {
                    try testing.expect(a < n_flows);
                }
                try testing.expectEqual(FlowTag.branch_label, b.flow_tags[b.reduceTarget(@intCast(f))]);
            },
            .assign, .cond_true, .cond_false, .chain_taken, .chain_short, .switch_clause, .switch_no_match, .call_stmt, .array_mutation => {
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
