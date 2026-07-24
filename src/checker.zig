//! Checker core (M4/M5): structural assignability, inference, literal
//! widening, control-flow narrowing, tsc-coded diagnostics; multi-file
//! programs via the sealed module graph (M5).
//!
//! Scope & stance (documented deviations are intentional for the M6 subset):
//!
//! - **Multi-file (M5)**: a Checker instance checks a *partition* of the
//!   program's files. Symbols are addressed globally
//!   (`sym_base[file] + local`); imported bindings resolve through the
//!   sealed link tables (read-only, no locks) and foreign symbols' types
//!   are constructed on demand in the local type store (duplicated across
//!   checker instances by design). Diagnostics are tagged with their file;
//!   `seal` keeps only diagnostics in *owned* files, so a diagnostic is
//!   reported exactly once — by the checker that owns the file — and the
//!   merged output is byte-identical for any partition count.
//!   Cross-file cuts (documented): `export =` / `import x = require()`
//!   and ambient `declare module` are out of subset (parser flags them);
//!   a namespace import used in *type* position (`ns.T`) types as `any`;
//!   an unnamed `export default function/class` declaration types as
//!   `any` when imported.
//! - **strict semantics only**: strictNullChecks, strictFunctionTypes
//!   (function-type parameters contravariant, *method* parameters bivariant,
//!   like tsc), noImplicitAny (TS7006 on unannotated, uncontextual params).
//! - **Freshness**: object literal types and literal types carry a fresh bit
//!   (in the type identity, see types.zig). Fresh object literals get excess
//!   property checking (TS2353); fresh literal types widen at mutable
//!   positions (`let`, object properties, returns) and survive `const`
//!   declarations, so `const x = "a"; let y = x;` gives `y: string` while
//!   `const x: "a" = "a"; let y = x;` keeps `"a"` — tsc's behavior.
//! - **`&&`/`||`/`??`** follow tsc: `A && B` is `falsy(A) | B` where
//!   falsy(string) = `""`, falsy(number) = `0`, falsy(boolean) = `false`,
//!   object types contribute nothing; `A || B` is `truthy(A) | B`;
//!   `A ?? B` is `nonNullable(A) | B`.
//! - **Narrowing**: truthiness, `typeof`, `===`/`!==`/`==`/`!=` against
//!   literals and null/undefined, discriminated unions (literal-typed
//!   property, incl. `switch`), `in`, `instanceof`, assignment narrowing,
//!   optional-chain guards. Narrowing targets are identifier references
//!   (per-symbol); property *paths* are only narrowed as discriminants of
//!   their root. Loop back-edges start from the declared type (tsc-style),
//!   so recursion terminates without a fixpoint iteration.
//! - **Relation cache**: (source, target) TypeId pairs, tri-state. A cycle
//!   (in-progress hit) optimistically reports "assignable"; the final result
//!   recorded for the outer pair may bake that assumption in (tsc tracks
//!   "Maybe" results more precisely — accepted simplification).
//! - **readonly**: ignored by the assignability relation (tsc also allows
//!   readonly<->mutable property assignment); enforced at write sites
//!   (TS2540) and via TS2588 for `const`.
//! - **Out of scope, degrade to `any` without wrong answers**: `as const`,
//!   getters/setters divergence, `this` parameter types, async/`await`
//!   Promise typing (async fns are unchecked for returns), generators,
//!   `keyof` on non-object types, generic indexed access, declaration
//!   merging beyond interface-interface, iterables beyond
//!   array/tuple/string in `for..of`.
//! - **No lib**: there are no global/ambient types. Arrays, tuples and
//!   strings expose `length` and numeric indexing only; there are no
//!   methods on primitives or arrays. TS2304 fires for any global
//!   (`console`, `Math`, ...) — corpora and conformance cases stay
//!   lib-free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const intern = @import("intern.zig");
const binder = @import("binder.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const modules = @import("modules.zig");
const ZeroPagedArray = @import("zeropage.zig").ZeroPagedArray;

const Ast = ast.Ast;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Bind = binder.Bind;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const FlowId = binder.FlowId;
const Span = source.Span;
const TypeId = types.TypeId;
const Store = types.Store;

pub const Error = error{OutOfMemory};

pub const FileId = modules.FileId;

/// Per-symbol type-computation state (`sym_state`). `not_computed = 0` is
/// load-bearing: `sym_state` is a demand-zeroed `ZeroPagedArray`, so an
/// untouched entry reads as `.not_computed` without ever being written — and
/// without faulting its page resident. Do not reorder or renumber.
const SymState = enum(u8) {
    not_computed = 0,
    in_progress = 1,
    computed = 2,
};

/// A checker diagnostic: tsc error code + file + span + rendered message.
pub const Diag = struct {
    code: u16,
    file: FileId = 0,
    span: Span,
    msg: []const u8,
};

pub const Stats = struct {
    types_created: usize = 0,
    type_bytes: usize = 0,
    relation_entries: usize = 0,
    relation_bytes: usize = 0,
    relation_hits: usize = 0,
    relation_misses: usize = 0,
    node_type_hits: usize = 0,
    node_type_misses: usize = 0,
    scratch_high_water: usize = 0,
    flow_queries: usize = 0,
    /// M15 instantiation-cache accounting.
    inst_hits: usize = 0,
    inst_misses: usize = 0,
    inst_maps: usize = 0,
};

/// Sealed check result for one file.
pub const Check = struct {
    diagnostics: []const Diag,
    stats: Stats,
};

/// Type-check one bound file with an unlinked single-file program
/// (imports type as `any`; no module diagnostics). Diagnostics and message
/// strings go into `arena`; all type storage and caches live in an
/// internal checker arena that is freed on return (the caller keeps only
/// diagnostics + stats). Total on arbitrary parser/binder output: never
/// fails except on OOM.
pub fn check(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    bind: *const Bind,
    src: []const u8,
) Error!Check {
    const prog = try arena.create(modules.Program);
    prog.* = try modules.singleFileProgram(arena, "", src, tree, bind);
    return checkFiles(arena, io, gpa, interner, prog, &.{0}, null, true);
}

/// Type-check `owned` files of a linked multi-file program. Cross-file
/// symbol lookups go through `prog.links` (sealed, read-only); types of
/// imported symbols are constructed on demand in this checker's local
/// store. Only diagnostics located in owned files are returned, sorted by
/// (file, position, code) — so concatenating the outputs of any partition
/// of the program's files yields byte-identical diagnostics.
pub fn checkFiles(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    prog: *const modules.Program,
    owned: []const FileId,
    base: ?*const types.Store,
    inst_cache_on: bool,
) Error!Check {
    var c = try Checker.init(arena, io, gpa, interner, prog, owned, base, inst_cache_on);
    defer c.deinit();
    try c.run();
    return c.seal();
}

/// Like `checkFiles`, but also renders `--dump-types` output (a `;; path`
/// header then one `name: type` line per file-scope value declaration,
/// per owned file) into `w`.
pub fn checkFilesAndDump(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    prog: *const modules.Program,
    owned: []const FileId,
    base: ?*const types.Store,
    inst_cache_on: bool,
    w: *std.Io.Writer,
) (Error || std.Io.Writer.Error)!Check {
    var c = try Checker.init(arena, io, gpa, interner, prog, owned, base, inst_cache_on);
    defer c.deinit();
    try c.run();
    for (owned) |f| {
        c.setFile(f);
        try w.print(";; {s}\n", .{prog.files[f].path});
        try c.dumpTypes(w);
    }
    return c.seal();
}

/// Like `check`, but also renders `--dump-types` output (one
/// `name: type` line per file-scope value declaration) into `w`.
pub fn checkAndDump(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    bind: *const Bind,
    src: []const u8,
    w: *std.Io.Writer,
) (Error || std.Io.Writer.Error)!Check {
    const prog = try arena.create(modules.Program);
    prog.* = try modules.singleFileProgram(arena, "", src, tree, bind);
    var c = try Checker.init(arena, io, gpa, interner, prog, &.{0}, null, true);
    defer c.deinit();
    try c.run();
    try c.dumpTypes(w);
    return c.seal();
}

/// Build the shared frozen base type store (M14.5 piece 2).
/// Runs single-threaded after link, before any checker worker spawns. The
/// returned store's arrays live in `store_arena` (which must outlive every
/// overlay built over it); the caller freezes-and-shares it as each
/// per-checker overlay's `base`.
///
/// Base payload today: the well-known intrinsics only. Because a fresh
/// overlay then allocates its first local id at `base_len` (== the intrinsic
/// count) exactly as a non-overlay store allocates its first non-intrinsic id,
/// overlay TypeIds match the non-frozen path id-for-id — so diagnostics are
/// byte-identical with the frozen store on or off. Pre-expanding the
/// lib/`@types` body into the base (the RSS win, reusing the M11 merge table
/// to enumerate lib symbols) is deferred to the larger embedded lib: it would
/// relocate lib types to low base ids. The display-order prerequisite that used
/// to block it — union/intersection members were printed in raw-TypeId order —
/// is resolved (M19.1): `printType` now orders members structurally
/// (`sortMembersStructural`/`writeSortKey`), TypeId-independent, so relocating
/// lib ids no longer changes any message. The overlay machinery is fully in
/// place for the payload follow-up (piece 2).
pub fn buildBaseStore(store_arena: Allocator) Error!types.Store {
    var base = try types.Store.init(store_arena);
    base.freeze();
    return base;
}

/// Structural recursion depth limit for `instantiate`/`substThis`. Chosen to
/// sit just above tsc's effective instantiation-depth threshold for the
/// deeply-nested-generic shape (tsc is clean at ~100 levels, reports TS2589
/// beyond), so ztsc stays clean where tsc is clean and reports TS2589 where
/// tsc does. Exceeding it emits TS2589 and truncates the offending subtree to
/// `error_type` (M15).
const max_instantiation_depth = 100;
/// Global cap on total `instantiate` node-visits within one checker run — a
/// dormant M16 safety net against instantiation-count explosion (recursive
/// conditional/mapped types, once those land). Set far above anything the
/// current subset produces, so it never fires here (and thus can never make
/// the `--no-inst-cache` oracle diverge: only the cache-independent depth
/// limit fires in-subset).
const max_instantiation_count = 5_000_000;
/// Upper bound on scratch-arena physical capacity retained across the
/// per-statement reset (`run`). The scratch arena is a transient workspace
/// reset after every top-level statement; with plain `.retain_capacity` the
/// arena keeps the high-water of the single largest statement (a big JSX-return
/// materializing generic component props can spike it to ~130 MB) resident for
/// the whole process, so a later peak elsewhere (type arenas, other files)
/// stacks on top of the stuck spike. Shrinking to this limit after each
/// statement releases the spike's physical pages while retaining enough
/// capacity that the common small-statement path never re-hits the backing
/// allocator. Safe by construction: the shrink runs at the exact point
/// `.retain_capacity` already logically frees everything, so nothing live is
/// referenced past it.
const scratch_retain_limit = 8 * 1024 * 1024;
/// Recursion-depth cap for the structural assignability relation
/// (`isAssignable`). A recursive generic alias whose recursion is *undecidable*
/// to ztsc — react-hook-form's `PathValueImpl`/`Path` peel a generic string
/// path param `P` that stays symbolic, so the `P extends `${infer K}.${infer
/// R}`` guard never resolves — makes `isAssignable` walk (via its deferred-
/// conditional and `ref` arms) an unbounded chain of *distinct* interned
/// `conditional`/`union`/`ref` types. Each is a fresh TypeId, so neither the
/// per-pair relation memo nor the per-ref expansion memo repeats, and the walk
/// recurses until the stack overflows. tsc bounds the same shape by capping its
/// own relation recursion and assuming the pair related past the limit
/// (`recursiveTypeRelatedTo` → `Ternary.Maybe`); we mirror that. Assume-true can
/// only *drop* diagnostics, never add a false positive. Chosen far above any
/// depth the conformance suite reaches (its diagnostics stay byte-identical) yet
/// far below the worker-thread stack-overflow depth, leaving a wide safety
/// margin on the smallest (main-thread) stack.
const max_relation_depth = 900;
/// Recursion-depth cap for alias-instance expansion (`aliasInstance`; see the
/// `alias_depth` field). Fires only on pathological mutually-recursive generic
/// alias chains (e.g. `@scalar/typebox`'s conditional type modules, whose
/// type-argument defaults chain through ~80 distinct aliases and would otherwise
/// overflow the stack). Past the cap the expansion yields `error_type`, which
/// suppresses cascades rather than adding a diagnostic (no false positive; tsc
/// resolves these via deferred conditional evaluation, out of ztsc's subset).
/// Set far above any depth in-subset code or the conformance suite reaches, well
/// below the worker-stack overflow depth.
const max_alias_depth = 200;
const max_type_string = 160;

const FnCtx = struct {
    /// Effective return-check target (0 = none / inferring). For an async
    /// function this is the awaited *payload* `T` of the declared
    /// `Promise<T>`, not the `Promise<T>` itself.
    ret_ann: TypeId = 0,
    is_async: bool = false,
    is_generator: bool = false,
    /// For a generator with an annotated `Generator<T>`/`Iterator<T>`/
    /// `IterableIterator<T>` return: the yield element type `T` (0 = infer /
    /// unchecked).
    yield_type: TypeId = 0,
};

/// A memoized expression type together with the contextual type it was
/// synthesized under (M8: contextual re-check cache).
const NodeType = struct { ty: TypeId, ctx: TypeId };

/// One in-progress `interfaceGeneric` resolution (M17.2 base-cycle detection).
const IfaceFrame = struct { sym: SymbolId, resolving_base: bool = false };

/// Bounds of a fresh higher-order type-param symbol (see `fresh_tp_ids`). The
/// constraint/default are already `M`-instantiated TypeIds (`no_type` = none).
const FreshTp = struct { name: Atom, constraint: TypeId, default: TypeId, has_default: bool };

const Checker = struct {
    out: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    prog: *const modules.Program,
    /// Files this checker instance owns (checks fully; only their
    /// diagnostics survive `seal`).
    owned: []const FileId,
    owned_mask: []bool = &.{},
    /// Current-file views (switched by `setFile`); all `tree`/`bind`/`src`
    /// uses below refer to the file being traversed *right now*.
    cur_file: FileId = 0,
    tree: *const Ast,
    bind: *const Bind,
    src: []const u8,

    /// Checker arena: type store, caches. Freed at the end of check().
    /// Heap-allocated so `Allocator` handles stay valid when the Checker
    /// struct moves.
    carena: *std.heap.ArenaAllocator,
    /// Scratch arena: worklists, printer buffers; reset per statement.
    /// `scratch_arena` is a *pointer* so it can be swapped for `inst_arena`
    /// during the outermost `instantiate()` call (see `instantiate`), routing
    /// every transient allocation made while materializing a generic type into
    /// a region that is released the moment the top-level substitution
    /// finishes — bounding the per-statement scratch high-water to the largest
    /// single instantiation instead of the sum of all of a statement's.
    scratch_arena: *std.heap.ArenaAllocator,
    /// Dedicated arena swapped in for `scratch_arena` while the outermost
    /// `instantiate()` runs; reset (shrunk to `scratch_retain_limit`) at that
    /// call's exit. Never holds anything referenced past the top-level
    /// substitution: results are interned into `ts`, persistent keys into
    /// `carena` (the `canonMapId`/`mintFreshTp` discipline), so the reset frees
    /// only genuinely dead intermediates.
    inst_arena: *std.heap.ArenaAllocator,

    ts: Store = undefined,

    diags: std.ArrayList(Diag) = .empty,
    diag_seen: std.AutoHashMapUnmanaged(u128, void) = .empty,

    // --- caches (checker arena) -------------------------------------------
    /// Global symbol -> declared value type. 0 = not computed.
    /// Global symbol -> declared value type. `0` = not computed. Demand-zeroed
    /// (see `ZeroPagedArray`): indexed by global SymbolId so it spans the whole
    /// symbol space, but only pages for symbols this checker touches ever
    /// become resident.
    sym_types: ZeroPagedArray(TypeId) = .{},
    /// Global symbol -> computation state (`.not_computed` = 0). Same
    /// demand-zeroed backing as `sym_types`.
    sym_state: ZeroPagedArray(SymState) = .{},
    /// (file << 32 | node) -> synthesized type + the contextual type it was
    /// checked under (memoized; dedupes diags). Keeping `ctx` on the value
    /// (rather than in the key) means a re-check under a *different* context
    /// misses and recomputes — fixing the first-check-wins staleness (M8) —
    /// while node-only readers still find the node's most-recent (canonical)
    /// type in the single slot.
    node_types: std.AutoHashMapUnmanaged(u64, NodeType) = .empty,
    /// (file << 32 | FnProto node) -> signature TypeId + the contextual
    /// signature it was built under. Arrow/function-expression signatures
    /// depend on `ctx_sig` (contextual parameter types), so — like
    /// `node_types` (M8) — a re-check under a different context must miss and
    /// recompute rather than return the first (stale) signature. Named
    /// declarations always pass `no_type`, so they still hit unconditionally.
    sig_cache: std.AutoHashMapUnmanaged(u64, NodeType) = .empty,
    /// (file << 32 | owner node) -> primary (lowest) scope id. Populated
    /// lazily per file by `faultScopes` on the first `scopeOf` read in that
    /// file (M12 right-sizing), so a checker only maps scopes for files it
    /// actually traverses — not every file of the program, per instance.
    node_scopes: std.AutoHashMapUnmanaged(u64, ScopeId) = .empty,
    /// Per-file flag: has this file's scope-owner map been faulted into
    /// `node_scopes` yet?
    scopes_faulted: []bool = &.{},
    /// Global SymbolIds that are the target of a reassignment (`x = …`, `x++`,
    /// destructuring-assignment element) *anywhere* in their file — i.e. not
    /// effectively `const`. Populated lazily per file by `ensureReassignScan`
    /// (see the `.start`/closure-capture gate in `flowTypeInner`). Order-
    /// invariant: a pure function of the file's assignment AST nodes.
    reassigned_syms: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// `(sym, for_head_scope)` pairs where `sym` is assigned somewhere inside a
    /// `for`/`for..of`/`for..in` whose header scope is `for_head_scope` (each
    /// enclosing loop of an assignment is recorded, so nested loops are all
    /// covered). Lets a loop label distinguish "reassigned *inside this loop*"
    /// from merely "reassigned before the loop" — the latter keeps its pre-loop
    /// narrowing across the loop (tsc), the former re-widens. Populated
    /// alongside `reassigned_syms` in `ensureReassignScan`.
    reassigned_in_loop: std.AutoHashMapUnmanaged(SymLoop, void) = .empty,
    /// Per-file flag: has this file's reassignment scan run yet?
    reassign_scanned: []bool = &.{},
    /// Recursion depth of TS4.4 aliased-condition narrowing (following a
    /// `const` alias into its initializer, then possibly an alias-of-alias).
    /// Capped like tsc's `inlineLevel` to bound alias chains.
    alias_inline_level: u32 = 0,
    /// FileId -> module namespace object type (0 = in progress).
    ns_types: std.AutoHashMapUnmanaged(FileId, TypeId) = .empty,
    /// Ambient-module namespace-object cache, keyed by ambient_exports index.
    ambient_ns_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// (source << 32 | target) -> Relation.
    relation: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    /// ref TypeId -> expanded structural type.
    expansions: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty,
    /// Instantiated interface/alias OBJECT TypeId -> its canonical origin
    /// `makeRef(sym, canonical-args)`. Two objects that carry the SAME origin
    /// ref denote the same nominal instantiation `G<A…>` (identical symbol AND
    /// element-wise-equal args, since `makeRef` interns), so they are mutually
    /// assignable by identity — regardless of any structural divergence between
    /// them. This is what lets the relation short-circuit the one-step
    /// (annotation `aliasInstance`/`expandRef`) vs two-step (call-return
    /// `instantiate` of a pre-expanded signature return) materializations of the
    /// same generic type, whose nested keyof/mapped/conditional members reduce
    /// non-confluently into distinct interned objects. It is an identity-only
    /// shortcut (no variance): it fires solely when both origins are equal.
    origin: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty,
    /// Generic (uninstantiated) bodies per symbol: interface/class-instance/
    /// class-static/alias.
    iface_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Gray stack of interfaces currently mid-resolution in `interfaceGeneric`
    /// (the ones marked `no_type`). Each frame records whether it is presently
    /// resolving its `extends` bases. On a re-entry, if *every* frame from the
    /// re-entered symbol to the top is in that base phase, the slice is a true
    /// `extends` cycle and TS2310 fires for every member — not just whichever
    /// symbol happened to start the traversal; a re-entry reached through a
    /// member/type-arg edge (a legal recursive reference) fires nothing. That
    /// makes the diagnostic set a pure function of the extends graph,
    /// independent of resolution/partition order (M17.2).
    iface_stack: std.ArrayListUnmanaged(IfaceFrame) = .empty,
    /// Class-position decorators (`@deco class C {}`) pending their target.
    /// A decorator statement precedes its class in the same statement list;
    /// checkStatement pushes here and checkClass consumes them (M18.3).
    pending_class_decos: std.ArrayListUnmanaged(Node) = .empty,
    class_inst_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    class_static_cache: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Classes whose base-static fold is on the stack, so a malformed `extends`
    /// cycle skips the recursive base fold instead of overflowing (the result
    /// cache stays unpoisoned — static-field-initializer re-entry must still
    /// see the class's own members).
    class_static_base_active: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Enum symbol -> value object type (the `typeof E` object with members).
    enum_value_cache: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Enum symbol -> computed EnumInfo (const-ness, member values).
    enum_info_cache: std.AutoHashMapUnmanaged(SymbolId, EnumInfo) = .empty,
    alias_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    alias_state: std.AutoHashMapUnmanaged(SymbolId, u8) = .empty,
    /// Alias symbols found to be (transitively) self-recursive while their
    /// generic body was materialized — marked when `aliasInstance` re-enters an
    /// in-progress alias (state == 1). Used to scope the recursion-accumulator
    /// default substitution in `fixTypeArgs` (RHF `PathInternal<T, Tr = T>`)
    /// away from non-recursive library defaults (redux `Reducer<S, A, P = S>`).
    alias_recursive: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Narrowed-type cache per (flow, reference, declared) query.
    flow_cache: std.AutoHashMapUnmanaged(FlowQ, TypeId) = .empty,
    /// Interned narrowing reference keys (RefKey -> dense index).
    ref_keys: std.AutoHashMapUnmanaged(RefKey, u32) = .empty,
    /// (flow << 32 | symbol) -> definitely-assigned (2 computing, 0/1 result).
    da_cache: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    /// containsTypeParam memo: 0 unknown, 1 no, 2 yes.
    ctp_cache: std.AutoHashMapUnmanaged(TypeId, u8) = .empty,
    /// M15 instantiation memo: `(canonical_map_id << 32 | t) -> result`. A
    /// substitution is a pure function of `(t, map-contents)`; `map_id`
    /// canonically identifies the map's `(type-param, arg)` set (order- and
    /// slice-identity-independent, see `canonMapId`), so this is sound even
    /// though results are interned permanently. Gated by `inst_cache_on`
    /// (`--no-inst-cache` disables it — the correctness oracle / benchmark
    /// "before" leg). Never populated for a subtree whose computation tripped
    /// the depth/count limit (`inst_limit_tripped`).
    inst_cache: std.AutoHashMapUnmanaged(u64, TypeId) = .empty,
    /// Canonical substitution-map interning: packed sorted `(sym,arg)` pair
    /// bytes -> a small stable id. The byte keys are duped into the checker
    /// arena (scratch is reset per statement).
    inst_map_ids: std.StringHashMapUnmanaged(u32) = .empty,
    inst_map_next: u32 = 1,
    /// `SymbolId -> declared constraint TypeId` (`no_type` = unconstrained).
    /// Avoids re-resolving the constraint AST on every assignability check.
    tp_constraint_cache: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Higher-order type-param rewrite (M20a). When an object's generic call/
    /// construct signature (`interface H<T>{ <U extends C<T> = D<T>>(…):… }`) is
    /// instantiated under a map `M`, an own param `U` whose constraint/default
    /// mentions `T` gets a *fresh* symbol whose constraint/default are the
    /// `M`-substituted `C[T:=…]`/`D[T:=…]`. The AST readers can't express that
    /// (the AST holds the un-substituted `C<T>`), so the fresh symbol's bounds
    /// live here and `typeParamConstraint`/`typeParamDefault`/`…HasDefault`/
    /// `symNameAtom` consult it first. Ids are `>= fresh_tp_base` (above the real
    /// + merged symbol space) and are minted deterministically, keyed by
    /// `(orig_param_sym, canonical_map_id)`, so the same instantiation reuses the
    /// same fresh symbol (inst-cache coherent; `--no-inst-cache` agrees).
    fresh_tp_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    fresh_tp_info: std.ArrayListUnmanaged(FreshTp) = .empty,
    fresh_tp_base: u32 = 0,
    fresh_tp_next: u32 = 0,
    /// `(file << 32 | type-node) -> TypeId`. A type annotation resolves names
    /// against its (lexically fixed) enclosing scope and any enclosing
    /// interface's `this` type — both a deterministic function of the node's
    /// location — so a node's synthesized type is context-free and memoizable
    /// by node alone (unlike `node_types`, whose value is contextual). Gated by
    /// `inst_cache_on` so the oracle validates it.
    type_node_cache: std.AutoHashMapUnmanaged(u64, TypeId) = .empty,
    /// Atom cache to avoid re-locking the shared interner.
    atom_cache: std.StringHashMapUnmanaged(Atom) = .empty,
    /// `unique symbol` nominal identity: (file << 32 | annotation node) ->
    /// a dense id. Keyed by declaration site so a value reference to a
    /// `unique symbol` const yields the same nominal type as its computed-key
    /// use (`{ [k]: … }`) and element access (`o[k]`).
    unique_sym_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    unique_sym_next: u32 = 1,
    /// Recursion bound for the type-materializing fallback of qualified
    /// computed-key resolution (`constSymbolKeyAtom`): an adversarial alias
    /// cycle (`[A.k]` where `A`'s type materialization re-resolves the same
    /// key) degrades to the placeholder instead of recursing unboundedly.
    computed_key_depth: u32 = 0,
    /// `infer V` binder identity (M16a): (conditional nodeKey, name atom) -> a
    /// dense id. Keyed by (conditional, name) so the *same* infer name used at
    /// several sites in one conditional's extends clause is one variable
    /// (same-name union/intersection), and re-evaluating the same conditional
    /// node (memo off) yields stable ids.
    infer_ids: std.AutoHashMapUnmanaged(InferKey, u32) = .empty,
    infer_next: u32 = 1,
    /// Stack of conditional-type nodeKeys whose infer scopes are currently
    /// active (innermost last). `infer V` binders resolve against the top;
    /// bare references to a `V` search the whole stack innermost-outward so a
    /// nested conditional inside a true branch still sees the enclosing
    /// conditional's infer vars (e.g. react-hook-form `PathValueImpl` /
    /// `ValidPathPrefixImpl`, where `K`/`R` from an outer `P extends
    /// `${infer K}.${infer R}`` are used deep inside nested conditionals).
    /// Each scope covers its conditional's extends and true branches only.
    infer_scopes: std.ArrayListUnmanaged(u64) = .empty,
    /// Mapped-type key parameter identity (M16b): mapped-type nodeKey -> a dense
    /// id for its `K` (stable across the memo-off re-evaluations of the node).
    mapped_key_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    mapped_key_next: u32 = 1,
    /// The mapped key parameter currently in scope (0 = none). While building a
    /// mapped type's `as`/value branches, a bare reference to `K` resolves to
    /// this `mapped_param` type; the constraint is evaluated with it cleared.
    cur_mapped_key_name: Atom = 0,
    cur_mapped_key_ty: TypeId = 0,
    /// Infer-scope stack height captured when `cur_mapped_key_*` was entered.
    /// A same-named outer `infer X` (scope index < this) is OUTER to the mapped
    /// key `[X in K]` and is shadowed by it (lexical innermost-wins); an `infer
    /// X` pushed by a conditional NESTED in the mapped value (index >= this)
    /// stays inner and still wins. See the resolution site in
    /// `typeFromTypeNodeUncached`.
    cur_mapped_key_scope_depth: usize = 0,
    /// Type-param names of the alias declaration whose (memoized) generic body
    /// is currently being materialized. Such a param is lexically the innermost
    /// binding of its name inside the body, so it shadows a same-named `infer`
    /// binder or mapped key belonging to whatever *other* declaration first
    /// referenced this alias — matching tsc lexical scoping. Without this, the
    /// alias body (e.g. `PathImpl<K, V, Tr>`) is memoized once with its own `V`
    /// mis-bound to an enclosing conditional's `infer V` and its `K` to an outer
    /// mapped key, an order-dependent leak. Only *colliding* names are hidden —
    /// non-colliding outer `infer` scopes stay visible (a blanket clear regresses
    /// types that legitimately thread infer vars across alias refs).
    tp_shadow: []const Atom = &.{},
    /// While materializing a *homomorphic* mapped prop, the self-index `T[K]`
    /// yields the source property's *declared* type (no `| undefined` for an
    /// optional prop) — optionality is carried by the prop's modifier flags
    /// instead, matching tsc (so `Required<{x?:T}>[x]` is `T`, not `T|undefined`).
    homo_index_mode: bool = false,

    // --- context ------------------------------------------------------------
    cur_scope: ScopeId = binder.file_scope,
    /// Innermost enclosing function-ish return context.
    fn_ctx: ?FnCtx = null,
    /// `this` type inside class methods (0 = any).
    this_type: TypeId = 0,
    /// The class symbol whose constructor body is currently being checked
    /// (`no_symbol` = not in a constructor). A `readonly` property may be
    /// assigned via `this.x` inside the constructor of the class that OWNS the
    /// declaration (tsc allows exactly this; an inherited readonly still errors).
    ctor_class_sym: SymbolId = binder.no_symbol,
    /// Set once any method declares a polymorphic `this` return; gates the
    /// per-property-access `this`-substitution walk so codebases without
    /// `this` types pay nothing.
    has_this_types: bool = false,
    inst_depth: u32 = 0,
    /// Live recursion depth of alias-instance expansion (`aliasInstance`).
    /// `alias_state` already breaks *direct* self-recursion with a lazy ref, but
    /// a chain of mutually-referential generic aliases — especially conditional
    /// aliases whose type-argument *defaults* pull in the next alias — expands
    /// through a fresh sym at each step, so no single `alias_state` entry is ever
    /// "in progress". Bounded here against `max_alias_depth` so such a chain
    /// terminates (as `error_type`) instead of overflowing the worker stack.
    alias_depth: u32 = 0,
    /// Live recursion depth of the structural assignability relation
    /// (`isAssignable`), checked against `max_relation_depth` to break the
    /// otherwise-unbounded walk over an undecidable recursive alias's
    /// expansions (see the constant's doc comment).
    rel_depth: u32 = 0,
    /// Total `instantiate` node-visits this run (checked against
    /// `max_instantiation_count`).
    inst_count: u64 = 0,
    /// Set when the current top-level `instantiate` call tripped the depth or
    /// count limit; suppresses memoization of the (truncated) results for that
    /// call. Reset at each top-level entry (`inst_depth == 0`).
    inst_limit_tripped: bool = false,
    /// Diagnostic span used when the instantiation limit is hit (TS2589),
    /// tracked at expression / assignability boundaries where materialization
    /// is triggered.
    inst_span: Span = .{ .start = 0, .end = 0 },
    /// Master switch for the M15 caching layer (`--no-inst-cache` clears it):
    /// the instantiate memo, map interning, constraint memo, and type-node
    /// memo. The depth/count limits are independent of it.
    inst_cache_on: bool = true,
    /// While set, `instantiateId`'s depth/count guard truncates silently
    /// (no TS2589) — used for origin-tag bookkeeping (`tagInstantiatedOrigin`).
    suppress_inst_diag: bool = false,
    /// Set while checking the operand of an `expr as const` const
    /// assertion: object/array literals produce readonly, non-widened,
    /// literal-typed members (recursively). Cleared at function bodies.
    const_ctx: bool = false,
    /// Set when generic inference fell back to a constraint (tsc then
    /// reports only the first failing argument).
    infer_fell_back: bool = false,
    stats: Stats = .{},

    // Well-known atoms (interned once in init).
    atom_length: Atom = 0,
    typeof_atoms: [8]Atom = @splat(0),
    typeof_union: TypeId = 0,
    // Names of the lib interfaces primitives/arrays bridge to (M10).
    atom_Array: Atom = 0,
    atom_String: Atom = 0,
    atom_Number: Atom = 0,
    atom_Boolean: Atom = 0,
    atom_Function: Atom = 0,
    // Names of the lib interfaces async/await + generators bridge to (M11).
    atom_Promise: Atom = 0,
    atom_PromiseLike: Atom = 0,
    atom_Generator: Atom = 0,
    atom_Iterator: Atom = 0,
    atom_IterableIterator: Atom = 0,
    /// TS ≥5.6 lib built-in iterator families (`IteratorObject` and the
    /// `MapIterator`-style named iterators) — first type arg is the yield type.
    atom_IteratorObject: Atom = 0,
    atom_ArrayIterator: Atom = 0,
    atom_MapIterator: Atom = 0,
    atom_SetIterator: Atom = 0,
    atom_StringIterator: Atom = 0,
    atom_RegExpStringIterator: Atom = 0,
    atom_sym_iterator: Atom = 0,
    atom_sym_asyncIterator: Atom = 0,
    atom_next: Atom = 0,
    atom_value: Atom = 0,
    atom_done: Atom = 0,
    /// Lib async-iterator families — first type arg is the yield type.
    atom_AsyncGenerator: Atom = 0,
    atom_AsyncIterator: Atom = 0,
    atom_AsyncIterableIterator: Atom = 0,
    atom_AsyncIteratorObject: Atom = 0,
    atom_JSX: Atom = 0,
    atom_IntrinsicElements: Atom = 0,
    atom_Element: Atom = 0,
    atom_ElementAttributesProperty: Atom = 0,
    atom_ElementChildrenAttribute: Atom = 0,
    atom_IntrinsicAttributes: Atom = 0,
    atom_IntrinsicClassAttributes: Atom = 0,
    atom_children: Atom = 0,

    const typeof_names = [8][]const u8{
        "string", "number", "bigint", "boolean", "symbol", "undefined", "object", "function",
    };

    fn init(
        out: Allocator,
        io: Io,
        gpa: Allocator,
        interner: *Interner,
        prog: *const modules.Program,
        owned: []const FileId,
        /// Frozen shared base type store (M14.5). When non-null, this
        /// checker's store is an overlay over it, so lib/`@types` types the
        /// base already holds are shared (not re-interned per checker). Null
        /// keeps the pre-M14.5 per-checker-expands-everything path
        /// (`--no-frozen-store`).
        base: ?*const types.Store,
        /// Enable the M15 instantiation caching layer (`false` under
        /// `--no-inst-cache`, the correctness oracle / benchmark "before" leg).
        inst_cache_on: bool,
    ) Error!Checker {
        const first = if (owned.len > 0) owned[0] else 0;
        const f0 = &prog.files[first];
        var c: Checker = .{
            .out = out,
            .io = io,
            .gpa = gpa,
            .interner = interner,
            .prog = prog,
            .owned = owned,
            .cur_file = first,
            .tree = f0.tree,
            .bind = f0.bind,
            .src = f0.src,
            .carena = undefined,
            .scratch_arena = undefined,
            .inst_arena = undefined,
            .inst_cache_on = inst_cache_on,
        };
        c.carena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.carena);
        c.carena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.carena.deinit();
        c.scratch_arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.scratch_arena);
        c.scratch_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.scratch_arena.deinit();
        c.inst_arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.inst_arena);
        c.inst_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.inst_arena.deinit();
        const arena_alloc = c.carena.allocator();
        c.ts = if (base) |b| try Store.initOverlay(arena_alloc, b) else try Store.init(arena_alloc);
        // Sized to include the merged-symbol range (ids ≥ totalSymbols()),
        // so merged ids are valid sym_types/sym_state indices (M11a). These
        // are indexed by *global* SymbolId — a checker reads them for foreign
        // (lib/import/merged) symbols too, so they must span the whole space.
        // M12 right-sizing: a `ZeroPagedArray` maps them demand-zeroed, so the
        // eager memset is gone — only pages for symbols this checker actually
        // touches become resident, and the `.not_computed`/`0` initial state
        // is the kernel's documented MAP_ANON zero-fill (not an allocator
        // accident). Freed in `deinit`.
        const total_syms = prog.symbolSpace();
        // Fresh higher-order type-param symbols are minted above the whole real
        // + merged symbol space so they never index the per-symbol arrays.
        c.fresh_tp_base = total_syms;
        c.fresh_tp_next = total_syms;
        c.sym_types = try ZeroPagedArray(TypeId).alloc(total_syms);
        errdefer c.sym_types.free();
        c.sym_state = try ZeroPagedArray(SymState).alloc(total_syms);
        errdefer c.sym_state.free();
        c.owned_mask = try arena_alloc.alloc(bool, prog.files.len);
        @memset(c.owned_mask, false);
        for (owned) |f| c.owned_mask[f] = true;
        // Owner node -> primary scope map is filled lazily per file by
        // `faultScopes`; only the per-file "already faulted" flags are set up
        // here (all false = nothing mapped yet).
        c.scopes_faulted = try arena_alloc.alloc(bool, prog.files.len);
        @memset(c.scopes_faulted, false);
        c.reassign_scanned = try arena_alloc.alloc(bool, prog.files.len);
        @memset(c.reassign_scanned, false);
        c.atom_length = try c.atom("length");
        c.atom_Array = try c.atom("Array");
        c.atom_String = try c.atom("String");
        c.atom_Number = try c.atom("Number");
        c.atom_Boolean = try c.atom("Boolean");
        c.atom_Function = try c.atom("Function");
        c.atom_Promise = try c.atom("Promise");
        c.atom_PromiseLike = try c.atom("PromiseLike");
        c.atom_Generator = try c.atom("Generator");
        c.atom_Iterator = try c.atom("Iterator");
        c.atom_IterableIterator = try c.atom("IterableIterator");
        c.atom_IteratorObject = try c.atom("IteratorObject");
        c.atom_ArrayIterator = try c.atom("ArrayIterator");
        c.atom_MapIterator = try c.atom("MapIterator");
        c.atom_SetIterator = try c.atom("SetIterator");
        c.atom_StringIterator = try c.atom("StringIterator");
        c.atom_RegExpStringIterator = try c.atom("RegExpStringIterator");
        c.atom_sym_iterator = try c.atom(ast.wellKnownSymbolKey("iterator").?);
        c.atom_sym_asyncIterator = try c.atom(ast.wellKnownSymbolKey("asyncIterator").?);
        c.atom_next = try c.atom("next");
        c.atom_value = try c.atom("value");
        c.atom_done = try c.atom("done");
        c.atom_AsyncGenerator = try c.atom("AsyncGenerator");
        c.atom_AsyncIterator = try c.atom("AsyncIterator");
        c.atom_AsyncIterableIterator = try c.atom("AsyncIterableIterator");
        c.atom_AsyncIteratorObject = try c.atom("AsyncIteratorObject");
        c.atom_JSX = try c.atom("JSX");
        c.atom_IntrinsicElements = try c.atom("IntrinsicElements");
        c.atom_Element = try c.atom("Element");
        c.atom_ElementAttributesProperty = try c.atom("ElementAttributesProperty");
        c.atom_ElementChildrenAttribute = try c.atom("ElementChildrenAttribute");
        c.atom_IntrinsicAttributes = try c.atom("IntrinsicAttributes");
        c.atom_IntrinsicClassAttributes = try c.atom("IntrinsicClassAttributes");
        c.atom_children = try c.atom("children");
        for (typeof_names, 0..) |n, i| c.typeof_atoms[i] = try c.atom(n);
        var tu: [8]TypeId = undefined;
        for (c.typeof_atoms, 0..) |a, i| tu[i] = try c.ts.makeStringLiteral(a, false);
        c.typeof_union = try c.ts.makeUnion(arena_alloc, &tu);
        return c;
    }

    fn deinit(c: *Checker) void {
        c.sym_types.free();
        c.sym_state.free();
        c.diag_seen.deinit(c.gpa);
        c.diags.deinit(c.gpa);
        c.carena.deinit();
        c.gpa.destroy(c.carena);
        c.scratch_arena.deinit();
        c.gpa.destroy(c.scratch_arena);
        c.inst_arena.deinit();
        c.gpa.destroy(c.inst_arena);
    }

    fn run(c: *Checker) Error!void {
        for (c.owned) |f| {
            c.setFile(f);
            c.cur_scope = binder.file_scope;
            c.fn_ctx = null;
            c.this_type = 0;
            for (c.tree.nodeRange(0)) |stmt| {
                if (stmt != null_node) try c.checkStatement(stmt);
                c.noteScratch();
                _ = c.scratch_arena.reset(.{ .retain_with_limit = scratch_retain_limit });
            }
        }
        // TDZ / use-before-assign / 2304 come from the walk itself.
        // Debug-only soundness net over every composite interned this run: a
        // member id past the id space is the fingerprint of a use-after-realloc
        // escape into an interned type (compiled out in release).
        c.ts.debugValidateComposites();
    }

    fn seal(c: *Checker) Error!Check {
        // Keep only owned-file diagnostics (foreign spans are reported by
        // the checker that owns them), sorted for deterministic output.
        var w: usize = 0;
        for (c.diags.items) |d| {
            if (!c.owned_mask[d.file]) continue;
            c.diags.items[w] = d;
            w += 1;
        }
        c.diags.items.len = w;
        std.mem.sort(Diag, c.diags.items, {}, struct {
            fn lessThan(_: void, x: Diag, y: Diag) bool {
                if (x.file != y.file) return x.file < y.file;
                if (x.span.start != y.span.start) return x.span.start < y.span.start;
                return x.code < y.code;
            }
        }.lessThan);
        const list = try c.out.dupe(Diag, c.diags.items);
        c.stats.types_created = c.ts.count();
        c.stats.type_bytes = c.ts.typeBytes();
        c.stats.relation_entries = c.relation.count();
        c.stats.relation_bytes = c.relation.capacity() * (8 + 1);
        return .{ .diagnostics = list, .stats = c.stats };
    }

    fn noteScratch(c: *Checker) void {
        const cap = c.scratch_arena.queryCapacity();
        if (cap > c.stats.scratch_high_water) c.stats.scratch_high_water = cap;
    }

    fn scratch(c: *Checker) Allocator {
        return c.scratch_arena.allocator();
    }
    fn ca(c: *Checker) Allocator {
        return c.carena.allocator();
    }

    // =====================================================================
    // multi-file context & global symbols
    // =====================================================================
    //
    // SymbolIds inside the checker (and inside type payloads) are GLOBAL:
    // `sym_base[file] + local`. Locals returned by binder lookups are
    // converted at the boundary (`toGlobal`). Functions that traverse a
    // symbol's declaration nodes first switch the current-file context
    // (`enterSymFile`), so `c.tree`/`c.bind`/`c.src` always match the
    // nodes in hand.

    fn setFile(c: *Checker, f: FileId) void {
        c.cur_file = f;
        const pf = &c.prog.files[f];
        c.tree = pf.tree;
        c.bind = pf.bind;
        c.src = pf.src;
    }

    const SavedCtx = struct { file: FileId, scope: ScopeId };

    fn saveCtx(c: *const Checker) SavedCtx {
        return .{ .file = c.cur_file, .scope = c.cur_scope };
    }

    fn restoreCtx(c: *Checker, s: SavedCtx) void {
        if (s.file != c.cur_file) c.setFile(s.file);
        c.cur_scope = s.scope;
    }

    /// Switch to `sym`'s file (scope untouched; callers set it).
    fn enterSymFile(c: *Checker, sym: SymbolId) SavedCtx {
        const saved = c.saveCtx();
        const f = c.symFile(sym);
        if (f != c.cur_file) c.setFile(f);
        return saved;
    }

    /// Representative *real* constituent id for decl/scope/file operations on
    /// a (possibly merged) symbol (M11a). Non-merged ids pass through; a
    /// merged id resolves to a type-space contributor when one exists (so
    /// interface/class/alias decl walks land on real nodes), else its first
    /// part. Type materialization that must fold *all* constituents
    /// (`interfaceGeneric`, merged value type) does not go through here.
    fn reprSym(c: *const Checker, sym: SymbolId) SymbolId {
        if (!c.prog.isMergedId(sym)) return sym;
        const m = c.prog.mergedSym(sym);
        for (m.parts) |p| {
            const f = c.prog.files[c.symFile(p)].bind.symbol_flags[p - c.prog.sym_base[c.symFile(p)]];
            if (f.interface or f.class or f.type_alias or f.enum_decl or f.namespace_decl) return p;
        }
        return m.parts[0];
    }

    /// File that owns global symbol `sym` (fast path: current file). A merged
    /// id resolves via its representative constituent.
    fn symFile(c: *const Checker, sym0: SymbolId) FileId {
        const sym = if (c.prog.isMergedId(sym0)) c.reprSym(sym0) else sym0;
        const base = c.prog.sym_base;
        if (sym >= base[c.cur_file] and sym < base[c.cur_file + 1]) return c.cur_file;
        var lo: usize = 0;
        var hi: usize = c.prog.files.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (base[mid] <= sym) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Whether a symbol is declared in a `.d.ts` declaration file (a library /
    /// ambient type). Used to gate expansions that are safe for user source but
    /// pathological on deeply-recursive library generics.
    fn symInDeclFile(c: *const Checker, sym: SymbolId) bool {
        return std.mem.endsWith(u8, c.prog.files[c.symFile(sym)].path, ".d.ts");
    }

    /// Local (per-file) id of a global symbol (via representative for merged).
    fn localOf(c: *const Checker, sym: SymbolId) SymbolId {
        const s = c.reprSym(sym);
        return s - c.prog.sym_base[c.symFile(s)];
    }

    /// Global id of a local symbol of the current file.
    fn toGlobal(c: *const Checker, local: SymbolId) SymbolId {
        if (local == binder.no_symbol) return binder.no_symbol;
        return c.prog.sym_base[c.cur_file] + local;
    }

    fn toGlobalIn(c: *const Checker, file: FileId, local: SymbolId) SymbolId {
        if (local == binder.no_symbol) return binder.no_symbol;
        return c.prog.sym_base[file] + local;
    }

    fn symBind(c: *const Checker, sym: SymbolId) *const Bind {
        return c.prog.files[c.symFile(sym)].bind;
    }

    /// Combined symbol flags. A merged symbol reports the OR of its
    /// constituents' flags (M11a).
    fn symFlags(c: *const Checker, sym: SymbolId) binder.SymbolFlags {
        if (c.prog.isMergedId(sym)) return c.prog.mergedSym(sym).flags;
        const f = c.symFile(sym);
        return c.prog.files[f].bind.symbol_flags[sym - c.prog.sym_base[f]];
    }

    fn symNameAtom(c: *const Checker, sym: SymbolId) Atom {
        if (c.isFreshTp(sym)) return c.freshTp(sym).name;
        if (c.prog.isMergedId(sym)) return c.prog.mergedSym(sym).name;
        const f = c.symFile(sym);
        return c.prog.files[f].bind.symbol_names[sym - c.prog.sym_base[f]];
    }

    /// Local scope id of `sym` within its own file (via representative for
    /// merged symbols).
    fn symScope(c: *const Checker, sym: SymbolId) ScopeId {
        const s = c.reprSym(sym);
        const f = c.symFile(s);
        return c.prog.files[f].bind.symbol_scopes[s - c.prog.sym_base[f]];
    }

    /// True when `sym` is a loop-header binding — the variable of a
    /// `for`/`for..of`/`for..in` (both declare their binding in a `.for_head`
    /// scope). Such a variable is re-established every iteration, so its
    /// pre-loop flow is meaningless and the loop-label narrowing shortcut (which
    /// trusts the pre-loop entry for a loop-invariant reference) must not fire —
    /// a `for (const x of xs)` binding is not in the reassignment scan yet is
    /// effectively assigned by every iteration.
    fn symDeclaredInForHead(c: *const Checker, sym: SymbolId) bool {
        const s = c.reprSym(sym);
        const f = c.symFile(s);
        const b = c.prog.files[f].bind;
        return b.scope_kinds[b.symbol_scopes[s - c.prog.sym_base[f]]] == .for_head;
    }

    /// Decl nodes of a global symbol (valid in `symFile(sym)`'s tree). For a
    /// merged symbol this is the representative constituent's decls; folding
    /// *all* constituents is done by the type materializers.
    fn declsOf(c: *const Checker, sym: SymbolId) []const Node {
        const s = c.reprSym(sym);
        const f = c.symFile(s);
        return c.prog.files[f].bind.declsOf(s - c.prog.sym_base[f]);
    }

    /// (file << 32 | node) cache key for the current file.
    fn nodeKey(c: *const Checker, node: Node) u64 {
        return (@as(u64, c.cur_file) << 32) | node;
    }

    /// Most-recent memoized type of `node` (ignoring which context produced
    /// it) — for node-only readers (narrowing, EPC, flow, error elaboration)
    /// that just want the type the node was last determined to have.
    fn nodeType(c: *const Checker, node: Node) ?TypeId {
        return if (c.node_types.get(c.nodeKey(node))) |e| e.ty else null;
    }

    /// Link target of an import-binding symbol (null in unlinked mode).
    fn importTarget(c: *const Checker, sym: SymbolId) ?modules.Target {
        if (c.prog.links.len == 0 or c.prog.isMergedId(sym)) return null;
        const f = c.symFile(sym);
        return c.prog.links[f].importTarget(sym - c.prog.sym_base[f]);
    }

    // =====================================================================
    // small helpers
    // =====================================================================

    fn atom(c: *Checker, text: []const u8) Error!Atom {
        const gop = try c.atom_cache.getOrPut(c.ca(), text);
        if (!gop.found_existing) {
            gop.value_ptr.* = try c.interner.intern(c.io, c.gpa, text);
        }
        return gop.value_ptr.*;
    }

    /// Intern text from a *transient* buffer (a scratch/stack slice). Goes
    /// straight to the interner (which copies the bytes) instead of `atom`,
    /// whose `atom_cache` would otherwise store the caller's slice as a key and
    /// dangle once the buffer is freed. Use for any computed/temporary string.
    fn internText(c: *Checker, text: []const u8) Error!Atom {
        return c.interner.intern(c.io, c.gpa, text);
    }

    fn atomText(c: *Checker, a: Atom) []const u8 {
        if (a == 0) return "";
        return c.interner.lookup(c.io, a);
    }

    fn tokenText(c: *const Checker, tok: TokenIndex) []const u8 {
        return c.tree.tokenSlice(c.src, tok);
    }

    fn atomOfToken(c: *Checker, tok: TokenIndex) Error!Atom {
        return c.atom(c.tokenText(tok));
    }

    /// Property-name atom: string keys lose quotes.
    fn memberAtom(c: *Checker, tok: TokenIndex) Error!Atom {
        const text = c.tokenText(tok);
        if (c.tree.tokens.tag(tok) == .string_literal) return c.atom(stripQuotes(text));
        return c.atom(text);
    }

    /// Member-name atom honoring a `[Symbol.iterator]` computed key (mirrors the
    /// binder's `memberKey`): with the `computed` flag set, `tok` names the
    /// well-known symbol and the member is keyed by a synthetic `__@name` atom.
    fn memberKey(c: *Checker, tok: TokenIndex, flags: u32) Error!Atom {
        if (flags & ast.Flags.computed_sym != 0) {
            // `[k]` / `[a.b]` computed key naming a const `unique symbol`:
            // resolve it in the current scope to its nominal `__@u<id>` atom.
            return c.computedSymKey(tok, flags, c.cur_scope);
        }
        if (flags & ast.Flags.computed != 0) {
            if (ast.wellKnownSymbolKey(c.tokenText(tok))) |k| return c.atom(k);
        }
        return c.memberAtom(tok);
    }

    /// Nominal `unique symbol` type for the `unique symbol` annotation node
    /// `ann`. Keyed by declaration site (file + node) so every resolution of
    /// the same annotation — the declared type of the const, and thus every
    /// value reference to it — yields the identical nominal type.
    fn uniqueSymType(c: *Checker, ann: Node) Error!TypeId {
        const gop = try c.unique_sym_ids.getOrPut(c.ca(), (@as(u64, c.cur_file) << 32) | ann);
        if (!gop.found_existing) {
            gop.value_ptr.* = c.unique_sym_next;
            c.unique_sym_next += 1;
        }
        return c.ts.makeUniqueSymbol(gop.value_ptr.*);
    }

    /// Synthetic member atom for a value whose type is a `unique symbol`, so a
    /// computed key `{ [k]: … }` and an element access `o[k]` agree on the
    /// property name. `__@` cannot begin a real identifier, so it never
    /// collides with an ordinary member (mirrors `wellKnownSymbolKey`).
    fn uniqueSymAtom(c: *Checker, t: TypeId) Error!?Atom {
        const r = try c.ts.regular(t);
        if (c.ts.kind(r) != .unique_symbol) return null;
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "__@u{d}", .{c.ts.uniqueSymId(r)}) catch unreachable;
        return try c.internText(s); // stack buffer: copy, don't store as a cache key
    }

    /// Prefix of a computed-key placeholder atom (see `computedSymPlaceholder`).
    const computed_sym_prefix = "__@k$";

    /// Placeholder member atom for a computed const-`unique symbol` key, keyed
    /// by the identifier text (matches the binder's `computedSymPlaceholder`).
    /// Used as a lenient fallback when the key identifier can't be resolved to
    /// a `unique symbol` (e.g. a plain `symbol`, or an unresolved import): the
    /// member still exists and is keyed by name, degrading nominal identity to
    /// same-name matching rather than emitting a spurious error.
    fn computedSymPlaceholder(c: *Checker, name: []const u8) Error!Atom {
        const s = try std.fmt.allocPrint(c.scratch(), "{s}{s}", .{ computed_sym_prefix, name });
        return c.internText(s); // scratch slice: copy, don't store as a cache key
    }

    /// Resolve a computed-key identifier `name` (a `[k]` key) in `scope` to the
    /// nominal `__@u<id>` atom of the const `unique symbol` it denotes. Returns
    /// null when it does not resolve to a `unique symbol` — the caller then
    /// falls back to the name placeholder. Resolution goes through the value
    /// space and `typeOfSymbol`, so an imported key resolves to the *declaring*
    /// site's nominal id, giving cross-file key identity for free.
    fn constSymbolKeyAtom(c: *Checker, name: []const u8, scope: ScopeId) Error!?Atom {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            // Qualified `[a.b]` key: resolve `a` in the value space, then find
            // the member *symbol* `b` directly on it (class statics, namespace
            // exports). Symbol-level lookup goes through `typeOfSymbol`'s
            // per-member guard, so a self-referential key (`[C.k]` inside `C`
            // itself, node's `[EventEmitter.captureRejectionSymbol]`) resolves
            // nominally without re-entering the class-static materialization.
            // `name` may live in scratch (see `computedSymKey`): intern the
            // pieces via `internText` — `atom` would store the transient
            // slice as an `atom_cache` key and dangle after a scratch reset.
            const obj = switch (c.resolveSpace(try c.internText(name[0..dot]), scope, true)) {
                .sym => |s| s,
                else => return null,
            };
            const member = try c.internText(name[dot + 1 ..]);
            if (c.qualifiedKeyMemberSym(obj, member)) |msym| {
                return c.uniqueSymAtom(try c.typeOfSymbol(msym));
            }
            // Fallback for a base that is not itself a class/namespace (an
            // import binding, or a var whose *type* carries the member —
            // rxjs's `[Symbol.observable]` on `var Symbol: SymbolConstructor`):
            // materialize the base's type. Depth-bounded: an alias cycle
            // re-resolving the same key degrades to the placeholder.
            if (c.computed_key_depth >= 4) return null;
            c.computed_key_depth += 1;
            defer c.computed_key_depth -= 1;
            const p = (try c.propOfType(try c.typeOfSymbol(obj), member)) orelse return null;
            return c.uniqueSymAtom(p.ty);
        }
        const a = try c.atom(name);
        const sym = switch (c.resolveSpace(a, scope, true)) {
            .sym => |s| s,
            else => return null,
        };
        return c.uniqueSymAtom(try c.typeOfSymbol(sym));
    }

    /// Member symbol `name` of `obj` for qualified computed-key resolution:
    /// a class's static (own class, or the class constituent of a merge), or
    /// a namespace export. Null when `obj` is neither, or the member is
    /// absent — the caller then falls back to type materialization.
    fn qualifiedKeyMemberSym(c: *Checker, obj: SymbolId, name: Atom) ?SymbolId {
        if (c.prog.isMergedId(obj)) {
            const m = c.prog.mergedSym(obj);
            for (m.parts) |p| {
                if (c.symFlags(p).class) {
                    if (c.classStaticMemberSym(p, name)) |s| return s;
                }
            }
            if (m.flags.namespace_decl) return c.namespaceMemberSym(obj, name);
            return null;
        }
        const f = c.symFlags(obj);
        if (f.class) {
            if (c.classStaticMemberSym(obj, name)) |s| return s;
        }
        if (f.namespace_decl) return c.namespaceMemberSym(obj, name);
        return null;
    }

    /// Static member `name` of class `cls` as a global symbol id, or null.
    fn classStaticMemberSym(c: *Checker, cls: SymbolId, name: Atom) ?SymbolId {
        const cb = c.symBind(cls);
        const ss = cb.staticsScopeOf(c.localOf(cls)) orelse return null;
        const local = cb.lookupInScope(ss, name) orelse return null;
        return c.toGlobalIn(c.symFile(cls), local);
    }

    /// Final member atom for a computed const-symbol key token, resolved in
    /// `scope`: the nominal `__@u<id>` when the key denotes a `unique symbol`,
    /// else the name placeholder. For a qualified `[a.b]` key the object
    /// identifier sits two tokens before the member identifier (see parser).
    fn computedSymKey(c: *Checker, tok: TokenIndex, flags: u32, scope: ScopeId) Error!Atom {
        const name = if (flags & ast.Flags.computed_sym_qual != 0)
            try std.fmt.allocPrint(c.scratch(), "{s}.{s}", .{ c.tokenText(tok - 2), c.tokenText(tok) })
        else
            c.tokenText(tok);
        if (try c.constSymbolKeyAtom(name, scope)) |k| return k;
        return c.computedSymPlaceholder(name);
    }

    /// Rekey a bound member atom (from the binder's member index) to its
    /// nominal `__@u<id>` when it is a computed-key placeholder; otherwise
    /// return it unchanged. `scope` must reach the key identifier's binding.
    fn nominalizeComputedKey(c: *Checker, name: Atom, scope: ScopeId) Error!Atom {
        const text = c.atomText(name);
        if (!std.mem.startsWith(u8, text, computed_sym_prefix)) return name;
        const ident = text[computed_sym_prefix.len..];
        if (try c.constSymbolKeyAtom(ident, scope)) |k| return k;
        return name;
    }

    /// Resolve a declaration's type annotation that is allowed to be a
    /// `unique symbol` (variable / class field / interface-or-type-literal
    /// property). When the annotation is `unique symbol`, returns its nominal
    /// type and — unless the modifiers make it legal (`valid`) — reports the
    /// position diagnostic `code` (TS1330/1331/1332). Any other annotation
    /// falls through to `typeFromTypeNode`, whose default reports TS1335 for a
    /// `unique symbol` in a disallowed position. Diagnostics dedup by span, so
    /// resolving the same annotation on both the type and check passes is safe.
    fn annTypeMaybeUnique(c: *Checker, ann: Node, valid: bool, code: u16, span: Span) Error!TypeId {
        if (ann != null_node and c.nodeTag(ann) == .unique_symbol_type) {
            if (!valid) {
                const msg = switch (code) {
                    1330 => "A property of an interface or type literal whose type is a 'unique symbol' type must be 'readonly'.",
                    1331 => "A property of a class whose type is a 'unique symbol' type must be both 'static' and 'readonly'.",
                    else => "A variable whose type is a 'unique symbol' type must be 'const'.",
                };
                try c.diagFmt(code, span, "{s}", .{msg});
            }
            return c.uniqueSymType(ann);
        }
        return c.typeFromTypeNode(ann);
    }

    /// Whether `node` is a fresh `Symbol(...)` / `Symbol.for(...)` call — the
    /// only initializer tsc accepts for a `unique symbol` const without a
    /// TS2322 (a plain `symbol` value is not assignable to `unique symbol`).
    fn isFreshSymbolCall(c: *Checker, node: Node) bool {
        if (node == null_node or c.nodeTag(node) != .call_expr) return false;
        const callee = c.tree.nodeData(node).lhs;
        switch (c.nodeTag(callee)) {
            .identifier => return std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(callee)), "Symbol"),
            .member_expr => {
                const md = c.tree.nodeData(callee);
                if (c.nodeTag(md.lhs) != .identifier) return false;
                if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(md.lhs)), "Symbol")) return false;
                const m = c.tokenText(md.rhs);
                return std.mem.eql(u8, m, "for");
            },
            else => return false,
        }
    }

    /// If `node` is syntactically `Symbol.<wellKnownName>` (e.g.
    /// `Symbol.iterator`), returns the synthetic member key `__@<name>` used by
    /// the declaration side (`ast.wellKnownSymbolKey`). Matches the identifier
    /// text `Symbol` like the binder/parser do — a purely syntactic recognizer,
    /// independent of whether the real lib types `Symbol.iterator` as a
    /// `unique symbol`.
    fn wellKnownKeyOfExpr(c: *const Checker, node: Node) ?[]const u8 {
        if (node == null_node or c.nodeTag(node) != .member_expr) return null;
        const md = c.tree.nodeData(node);
        if (c.nodeTag(md.lhs) != .identifier) return null;
        if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(md.lhs)), "Symbol")) return null;
        return ast.wellKnownSymbolKey(c.tokenText(md.rhs));
    }

    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
            if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
            return text[1..];
        }
        if (text.len >= 1 and (text[0] == '"' or text[0] == '\'')) return text[1..];
        return text;
    }

    fn tokSpan(c: *const Checker, tok: TokenIndex) Span {
        const start = c.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(c.src, c.tree.tokens.tag(tok), start) };
    }

    fn nodeSpan(c: *const Checker, node: Node) Span {
        return c.tree.span(c.src, node);
    }

    fn nodeTag(c: *const Checker, node: Node) ast.Tag {
        return c.tree.nodeTag(node);
    }

    fn diagFmt(c: *Checker, code: u16, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
        const key = (@as(u128, c.cur_file) << 64) | (@as(u128, code) << 32) | span.start;
        const gop = try c.diag_seen.getOrPut(c.gpa, key);
        if (gop.found_existing) return;
        const msg = try std.fmt.allocPrint(c.out, fmt, args);
        try c.diags.append(c.gpa, .{ .code = code, .file = c.cur_file, .span = span, .msg = msg });
    }

    fn scopeOf(c: *Checker, node: Node) Error!?ScopeId {
        if (!c.scopes_faulted[c.cur_file]) try c.faultScopes(c.cur_file);
        return c.node_scopes.get((@as(u64, c.cur_file) << 32) | node);
    }

    /// Lazily map every scope-owner node of file `f` to its primary (lowest)
    /// scope id, the first time this checker reads a scope in that file (M12
    /// right-sizing). First scope wins because `scope_owners` is walked in
    /// ascending scope order and only unset keys are written.
    fn faultScopes(c: *Checker, f: FileId) Error!void {
        const arena_alloc = c.carena.allocator();
        const b = c.prog.files[f].bind;
        for (b.scope_owners, 0..) |owner, s| {
            if (s == 0) continue;
            const key = (@as(u64, @intCast(f)) << 32) | owner;
            const gop = try c.node_scopes.getOrPut(arena_alloc, key);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(s);
        }
        c.scopes_faulted[f] = true;
    }

    /// Nearest enclosing function/file scope (for TDZ containment).
    fn containerOf(c: *const Checker, s: ScopeId) ScopeId {
        var cur = s;
        while (cur != binder.file_scope) {
            switch (c.bind.scope_kinds[cur]) {
                .function, .file => return cur,
                else => cur = c.bind.scope_parents[cur],
            }
        }
        return binder.file_scope;
    }

    // =====================================================================
    // name resolution (value vs type space)
    // =====================================================================

    /// Import bindings are optimistic in both spaces (the target decides;
    /// refined at use sites via the link tables) except that a type-only
    /// import never has value meaning (TS1361 at value uses).
    fn hasValueMeaning(f: binder.SymbolFlags) bool {
        if (f.import_binding and f.type_only) return false;
        return f.var_decl or f.let_decl or f.const_decl or f.function or f.class or
            f.param or f.catch_param or f.import_binding or f.enum_decl or f.namespace_decl;
    }

    fn hasTypeMeaning(f: binder.SymbolFlags) bool {
        return f.class or f.interface or f.type_alias or f.type_param or
            f.import_binding or f.enum_decl or f.namespace_decl;
    }

    const Resolved = union(enum) {
        sym: SymbolId,
        wrong_space: SymbolId,
        none,
    };

    /// Resolve in the current file's scope chain; returns GLOBAL ids.
    fn resolveSpace(c: *Checker, a: Atom, from: ScopeId, want_value: bool) Resolved {
        var s = from;
        var wrong: SymbolId = binder.no_symbol;
        while (true) {
            if (c.bind.lookupInScope(s, a)) |sym| {
                const f = c.bind.symbol_flags[sym];
                const ok = if (want_value) hasValueMeaning(f) else hasTypeMeaning(f);
                if (ok) {
                    // A reference from inside a contributing file binds to the
                    // file-local declaration; if that declaration is a
                    // cross-file merge constituent, route to the merged symbol
                    // so its full member set (folded from every file) is seen
                    // (M11a). Its OR-of-constituents flags keep `ok` valid.
                    const g = c.toGlobal(sym);
                    return .{ .sym = c.prog.mergedOf(g) orelse g };
                }
                if (wrong == binder.no_symbol) wrong = sym;
            }
            // A bare name unresolved in *this* file's copy of a namespace body
            // may be declared in another file's contribution to the same
            // cross-file-merged namespace (M11b). Real `@types/node` relies on
            // this: `namespace NodeJS { interface ProcessEnv extends Dict<…> }`
            // sits in `process.d.ts` while `interface Dict<T>` is declared in
            // `globals.d.ts`'s `namespace NodeJS`. Consult the merged member
            // index for the enclosing namespace scope.
            if (c.bind.scope_kinds[s] == .namespace) {
                if (c.mergedNsMemberOfScope(s, a)) |gsym| {
                    const gf = c.symFlags(gsym);
                    const ok = if (want_value) hasValueMeaning(gf) else hasTypeMeaning(gf);
                    if (ok) return .{ .sym = gsym };
                }
            }
            if (s == binder.file_scope) break;
            s = c.bind.scope_parents[s];
        }
        // Global (lib) fallback: bare names not found in the file's scope
        // chain resolve against the injected lib's top-level declarations
        // (M10). The table already holds GLOBAL SymbolIds.
        if (c.prog.globals.lookup(a)) |gsym| {
            const gf = c.symFlags(gsym);
            const ok = if (want_value) hasValueMeaning(gf) else hasTypeMeaning(gf);
            if (ok) return .{ .sym = gsym };
            if (wrong == binder.no_symbol) return .{ .wrong_space = gsym };
        }
        if (wrong != binder.no_symbol) return .{ .wrong_space = c.toGlobal(wrong) };
        return .none;
    }

    /// Edit distance <= threshold spelling suggestion among scope-visible
    /// names (tsc's TS2552/TS2551 "Did you mean ...?").
    fn suggestName(c: *Checker, a: Atom, from: ScopeId, want_value: bool) ?Atom {
        const text = c.atomText(a);
        if (text.len < 3) return null;
        var best: ?Atom = null;
        var best_d: usize = @max(2, (text.len * 34 + 99) / 100) + 1;
        var s = from;
        while (true) {
            const lo = c.bind.scope_members_start[s];
            const hi = c.bind.scope_members_start[s + 1];
            for (lo..hi) |i| {
                const cand = c.bind.member_atoms[i];
                if (cand == a) continue;
                const f = c.bind.symbol_flags[c.bind.member_syms[i]];
                const ok = if (want_value) hasValueMeaning(f) else hasTypeMeaning(f);
                if (!ok) continue;
                const cand_text = c.atomText(cand);
                const d = editDistance(text, cand_text, best_d);
                if (d < best_d) {
                    best_d = d;
                    best = cand;
                }
            }
            if (s == binder.file_scope) break;
            s = c.bind.scope_parents[s];
        }
        return best;
    }

    fn suggestProp(c: *Checker, a: Atom, obj: TypeId) ?Atom {
        const text = c.atomText(a);
        if (text.len < 3) return null;
        var best: ?Atom = null;
        var best_d: usize = @max(2, (text.len * 34 + 99) / 100) + 1;
        const t = c.resolveStructural(obj) catch return null;
        if (c.ts.kind(t) != .object) return null;
        for (0..c.ts.objectPropCount(t)) |i| {
            const p = c.ts.objectProp(t, @intCast(i));
            const cand_text = c.atomText(p.name);
            const d = editDistance(text, cand_text, best_d);
            if (d < best_d) {
                best_d = d;
                best = p.name;
            } else if (d == best_d and best != null and
                std.mem.order(u8, cand_text, c.atomText(best.?)) == .lt)
            {
                // Tie on edit distance: prefer the lexicographically smaller
                // name so the suggestion is byte-identical across --workers
                // (props are iterated in atom order, which is not stable).
                best = p.name;
            }
        }
        return best;
    }

    fn editDistance(a: []const u8, b: []const u8, cap: usize) usize {
        if (a.len > 32 or b.len > 32) return cap + 1;
        const big = @max(a.len, b.len);
        const small = @min(a.len, b.len);
        if (big - small > cap) return cap + 1;
        var row: [33]usize = undefined;
        for (0..b.len + 1) |j| row[j] = j;
        var i: usize = 1;
        while (i <= a.len) : (i += 1) {
            var prev = row[0];
            row[0] = i;
            var j: usize = 1;
            while (j <= b.len) : (j += 1) {
                const tmp = row[j];
                const cost: usize = if (toLower(a[i - 1]) == toLower(b[j - 1])) 0 else 1;
                row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), prev + cost);
                prev = tmp;
            }
        }
        return row[b.len];
    }

    fn toLower(ch: u8) u8 {
        return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }

    // =====================================================================
    // literal freshness / widening helpers
    // =====================================================================

    /// Fresh literal -> base primitive; unions widen fresh members; fresh
    /// object literals lose freshness (their props were already widened at
    /// creation unless contextually kept).
    fn widenLiteral(c: *Checker, t: TypeId) Error!TypeId {
        if (c.ts.isFreshLiteral(t)) {
            const base = c.ts.literalBase(t);
            return if (base != types.no_type) base else t;
        }
        switch (c.ts.kind(t)) {
            .union_type => {
                var any_fresh = false;
                for (try c.memberList(t)) |m| {
                    if (c.ts.isFreshLiteral(m) or c.ts.objectIsFresh(m)) any_fresh = true;
                }
                if (!any_fresh) return t;
                var list: std.ArrayList(TypeId) = .empty;
                defer list.deinit(c.scratch());
                for (try c.memberList(t)) |m| try list.append(c.scratch(), try c.widenLiteral(m));
                return c.ts.makeUnion(c.scratch(), list.items);
            },
            .object => return c.ts.regular(t),
            else => return t,
        }
    }

    /// Widen a contextually-typed return expression: suppress literal widening
    /// where the contextual return type admits the literal (tsc's
    /// isLiteralOfContextualType), otherwise widen exactly as `widenLiteral`.
    /// Object literals were already contextually typed member-by-member inside
    /// `checkObjectLiteral` (and `widenLiteral` de-freshens an object without
    /// touching its members), so only a *bare* primitive-literal return needs
    /// suppression here (`() => 'Polygon'` under `() => 'Polygon'`); a union
    /// distributes so a mixed `cond ? 'a' : null` keeps `'a'` under a
    /// literal-admitting context. With no context this is `widenLiteral`.
    fn widenToContext(c: *Checker, t: TypeId, ret_ctx: TypeId) Error!TypeId {
        if (ret_ctx == types.no_type) return c.widenLiteral(t);
        switch (c.ts.kind(t)) {
            .union_type => {
                var any_fresh = false;
                for (try c.memberList(t)) |m| {
                    if (c.ts.isFreshLiteral(m) or c.ts.objectIsFresh(m)) any_fresh = true;
                }
                if (!any_fresh) return t;
                var list: std.ArrayList(TypeId) = .empty;
                defer list.deinit(c.scratch());
                for (try c.memberList(t)) |m| try list.append(c.scratch(), try c.widenToContext(m, ret_ctx));
                return c.ts.makeUnion(c.scratch(), list.items);
            },
            .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false => {
                if (c.ts.isFreshLiteral(t) and try c.contextAdmitsLiteral(ret_ctx, t)) return c.ts.regularLiteral(t);
                return c.widenLiteral(t);
            },
            else => return c.widenLiteral(t),
        }
    }

    // =====================================================================
    // type printing
    // =====================================================================

    /// Render `t` tsc-style into the output arena (for messages).
    fn typeToString(c: *Checker, t: TypeId) Error![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(c.out);
        defer aw.deinit();
        c.printType(&aw.writer, t, 0) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        var s = aw.written();
        if (s.len > max_type_string) {
            s = s[0..max_type_string];
        }
        return c.out.dupe(u8, s);
    }

    const PrintErr = std.Io.Writer.Error;

    fn printType(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32) PrintErr!void {
        if (t == types.no_type) return w.writeAll("any");
        if (depth > 6) return w.writeAll("...");
        const s = &c.ts;
        switch (s.kind(t)) {
            .none => try w.writeAll("any"),
            .any, .err => try w.writeAll("any"),
            .unknown => try w.writeAll("unknown"),
            .never => try w.writeAll("never"),
            .void => try w.writeAll("void"),
            .undefined => try w.writeAll("undefined"),
            .null => try w.writeAll("null"),
            .string => try w.writeAll("string"),
            .number => try w.writeAll("number"),
            .boolean => try w.writeAll("boolean"),
            .bigint => try w.writeAll("bigint"),
            .symbol => try w.writeAll("symbol"),
            .unique_symbol => try w.writeAll("unique symbol"),
            .object_keyword => try w.writeAll("object"),
            .bool_true => try w.writeAll("true"),
            .bool_false => try w.writeAll("false"),
            .string_literal => try w.print("\"{s}\"", .{c.atomText(s.literalAtom(t))}),
            .bigint_literal => try w.print("{s}", .{c.atomText(s.literalAtom(t))}),
            .number_literal, .number_literal_fresh => try printNumber(w, s.numberValue(t)),
            .union_type => {
                // Display order is a *structural* (TypeId-independent) sort so
                // relocating lib types to low base ids never reorders a message
                // (M19.1); null and undefined always go last, matching tsc.
                const all = s.members(t);
                const buf = c.scratch().alloc(TypeId, all.len) catch return error.WriteFailed;
                var m: usize = 0;
                for (all) |x| {
                    if (s.kind(x) == .null or s.kind(x) == .undefined) continue;
                    buf[m] = x;
                    m += 1;
                }
                const sorted = try c.sortMembersStructural(buf[0..m], depth + 1);
                var first = true;
                for (sorted) |x| {
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try c.printTypeParen(w, x, depth + 1, true);
                }
                for (all) |x| {
                    if (s.kind(x) != .null) continue;
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try w.writeAll("null");
                }
                for (all) |x| {
                    if (s.kind(x) != .undefined) continue;
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try w.writeAll("undefined");
                }
            },
            .intersection => {
                const sorted = try c.sortMembersStructural(s.members(t), depth + 1);
                for (sorted, 0..) |x, i| {
                    if (i > 0) try w.writeAll(" & ");
                    try c.printTypeParen(w, x, depth + 1, true);
                }
            },
            .array => {
                try c.printTypeParen(w, s.arrayElem(t), depth + 1, false);
                try w.writeAll("[]");
            },
            .tuple => {
                // `as const` tuples are readonly (flag on every element).
                if (s.tupleLen(t) > 0 and s.tupleElem(t, 0).readonly()) try w.writeAll("readonly ");
                try w.writeAll("[");
                for (0..s.tupleLen(t)) |i| {
                    if (i > 0) try w.writeAll(", ");
                    const e = s.tupleElem(t, @intCast(i));
                    if (e.rest()) try w.writeAll("...");
                    try c.printType(w, e.ty, depth + 1);
                    if (e.optional()) try w.writeAll("?");
                }
                try w.writeAll("]");
            },
            .object => {
                const n = s.objectPropCount(t);
                const sidx = s.objectStringIndex(t);
                const nidx = s.objectNumberIndex(t);
                const ncall = s.objectCallSigCount(t);
                const nconstruct = s.objectConstructSigCount(t);
                if (n == 0 and sidx == 0 and nidx == 0 and ncall == 0 and nconstruct == 0) return w.writeAll("{}");
                try w.writeAll("{ ");
                var first = true;
                // Call / construct signatures (M18.1), printed member-style.
                for (0..ncall) |i| {
                    if (!first) try w.writeAll(" ");
                    first = false;
                    try c.printSigMember(w, s.objectCallSig(t, @intCast(i)), false, depth + 1);
                }
                for (0..nconstruct) |i| {
                    if (!first) try w.writeAll(" ");
                    first = false;
                    try c.printSigMember(w, s.objectConstructSig(t, @intCast(i)), true, depth + 1);
                }
                // Properties are *stored* sorted by name atom (canonical for
                // interning), but atom ids depend on the parallel intern order,
                // so displaying in stored order makes messages differ across
                // --workers/--checkers. Render in name-*text* order instead:
                // names are unique within an object, so this is a total order
                // and byte-identical for any worker/checker count (determinism
                // contract). Storage stays atom-sorted (lookup/interning intact).
                const order = c.propDisplayOrder(t, n) catch return error.WriteFailed;
                for (order) |i| {
                    const p = s.objectProp(t, i);
                    if (!first) try w.writeAll(" ");
                    first = false;
                    try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.optional()) "?" else "" });
                    try c.printType(w, p.ty, depth + 1);
                    try w.writeAll(";");
                }
                if (sidx != 0) {
                    if (!first) try w.writeAll(" ");
                    first = false;
                    try w.writeAll("[x: string]: ");
                    try c.printType(w, sidx, depth + 1);
                    try w.writeAll(";");
                }
                if (nidx != 0) {
                    if (!first) try w.writeAll(" ");
                    try w.writeAll("[x: number]: ");
                    try c.printType(w, nidx, depth + 1);
                    try w.writeAll(";");
                }
                try w.writeAll(" }");
            },
            .function => {
                const tps = s.fnTypeParams(t);
                if (tps.len > 0) {
                    try w.writeAll("<");
                    for (tps, 0..) |tp, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.print("{s}", .{c.symbolName(tp)});
                    }
                    try w.writeAll(">");
                }
                try w.writeAll("(");
                for (0..s.fnParamCount(t)) |i| {
                    if (i > 0) try w.writeAll(", ");
                    const p = s.fnParam(t, @intCast(i));
                    if (p.rest()) try w.writeAll("...");
                    if (p.name != 0) {
                        try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.flags & types.param_flag_optional != 0) "?" else "" });
                    }
                    try c.printType(w, p.ty, depth + 1);
                }
                try w.writeAll(") => ");
                try c.printType(w, s.fnReturn(t), depth + 1);
            },
            .overloads => {
                try w.writeAll("{ ");
                for (s.members(t), 0..) |m, i| {
                    if (i > 0) try w.writeAll(" ");
                    try c.printType(w, m, depth + 1);
                    try w.writeAll(";");
                }
                try w.writeAll(" }");
            },
            .ref => {
                try w.print("{s}", .{c.symbolName(s.refSymbol(t))});
                const args = s.refArgs(t);
                if (args.len > 0) {
                    try w.writeAll("<");
                    for (args, 0..) |a, i| {
                        if (i > 0) try w.writeAll(", ");
                        try c.printType(w, a, depth + 1);
                    }
                    try w.writeAll(">");
                }
            },
            .type_param => try w.print("{s}", .{c.symbolName(s.typeParamSymbol(t))}),
            .class_value => try w.print("typeof {s}", .{c.symbolName(s.classSymbol(t))}),
            .enum_type => try w.print("{s}", .{c.symbolName(s.enumSymbol(t))}),
            .this_type => try w.writeAll("this"),
            .infer_var => try w.print("infer {s}", .{c.atomText(s.inferVarName(t))}),
            .mapped_param => try w.print("{s}", .{c.atomText(s.mappedParamName(t))}),
            .index_access => {
                try c.printTypeParen(w, s.indexAccessObj(t), depth + 1, false);
                try w.writeAll("[");
                try c.printType(w, s.indexAccessIndex(t), depth + 1);
                try w.writeAll("]");
            },
            .mapped => {
                try w.writeAll("{ [");
                try c.printType(w, s.mappedKeyParam(t), depth + 1);
                try w.writeAll(" in ");
                if (s.mappedHomomorphic(t)) {
                    try w.writeAll("keyof ");
                    try c.printType(w, s.mappedSource(t), depth + 1);
                } else {
                    try c.printType(w, s.mappedConstraint(t), depth + 1);
                }
                try w.writeAll("]: ");
                try c.printType(w, s.mappedValue(t), depth + 1);
                try w.writeAll(" }");
            },
            .conditional => {
                try c.printTypeParen(w, s.condCheck(t), depth + 1, false);
                try w.writeAll(" extends ");
                try c.printTypeParen(w, s.condExtends(t), depth + 1, false);
                try w.writeAll(" ? ");
                try c.printType(w, s.condTrue(t), depth + 1);
                try w.writeAll(" : ");
                try c.printType(w, s.condFalse(t), depth + 1);
            },
            .template_literal_type => {
                try w.writeAll("`");
                try w.writeAll(c.atomText(s.templateHead(t)));
                for (0..s.templateHoleCount(t)) |i| {
                    try w.writeAll("${");
                    try c.printType(w, s.templateHole(t, @intCast(i)), depth + 1);
                    try w.writeAll("}");
                    try w.writeAll(c.atomText(s.templateChunk(t, @intCast(i))));
                }
                try w.writeAll("`");
            },
            .string_mapping => {
                try w.print("{s}<", .{stringMappingName(s.stringMappingKind(t))});
                try c.printType(w, s.stringMappingArg(t), depth + 1);
                try w.writeAll(">");
            },
            .keyof_op => {
                try w.writeAll("keyof ");
                try c.printTypeParen(w, s.keyofOperand(t), depth + 1, false);
            },
        }
    }

    fn stringMappingName(kind_idx: u32) []const u8 {
        return switch (kind_idx) {
            types.string_mapping_uppercase => "Uppercase",
            types.string_mapping_lowercase => "Lowercase",
            types.string_mapping_capitalize => "Capitalize",
            types.string_mapping_uncapitalize => "Uncapitalize",
            else => "Uppercase",
        };
    }

    /// Print a call/construct signature in object-member form (M18.1):
    /// `<T>(a: A): R;` for a call sig, `new <T>(a: A): R;` for a construct sig.
    fn printSigMember(c: *Checker, w: *std.Io.Writer, sig: TypeId, is_construct: bool, depth: u32) PrintErr!void {
        const s = c.ts;
        if (is_construct) try w.writeAll("new ");
        const tps = s.fnTypeParams(sig);
        if (tps.len > 0) {
            try w.writeAll("<");
            for (tps, 0..) |tp, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}", .{c.symbolName(tp)});
            }
            try w.writeAll(">");
        }
        try w.writeAll("(");
        for (0..s.fnParamCount(sig)) |i| {
            if (i > 0) try w.writeAll(", ");
            const p = s.fnParam(sig, @intCast(i));
            if (p.rest()) try w.writeAll("...");
            if (p.name != 0) {
                try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.flags & types.param_flag_optional != 0) "?" else "" });
            }
            try c.printType(w, p.ty, depth + 1);
        }
        try w.writeAll("): ");
        try c.printType(w, s.fnReturn(sig), depth + 1);
        try w.writeAll(";");
    }

    fn printTypeParen(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32, in_union: bool) PrintErr!void {
        const k = c.ts.kind(t);
        const needs = switch (k) {
            .function => true,
            .union_type, .intersection => !in_union,
            else => false,
        };
        if (needs) try w.writeAll("(");
        try c.printType(w, t, depth);
        if (needs) try w.writeAll(")");
    }

    /// One display-time member of a union/intersection paired with its
    /// structural sort key.
    const DisplayMember = struct { ty: TypeId, key: []const u8 };

    /// Order-preserving 8-byte big-endian encoding of an f64 so number-literal
    /// sort keys compare numerically as raw bytes (`-1` < `0` < `2` < `10`).
    fn encodeF64Key(v: f64) [8]u8 {
        var bits: u64 = @bitCast(v);
        bits = if (bits >> 63 != 0) ~bits else bits | (@as(u64, 1) << 63);
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, bits, .big);
        return out;
    }

    /// Writes a **TypeId-independent** structural sort key for `t`: a kind-rank
    /// byte (so intrinsics keep their canonical `Kind` order — `string` before
    /// `number` before `boolean`) followed by structural content — array
    /// element recursion, an order-preserving numeric encoding for number
    /// literals, and the human rendering (symbol names / atom text / literal
    /// text, never raw TypeIds) for everything else. Keying on *structure*, not
    /// on id assignment, is what keeps union/intersection display order stable
    /// when lib types are relocated to low base ids (M19.1).
    fn writeSortKey(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32) PrintErr!void {
        const k = c.ts.kind(t);
        try w.writeByte(@intFromEnum(k));
        if (depth > 6) return;
        switch (k) {
            .array => try c.writeSortKey(w, c.ts.arrayElem(t), depth + 1),
            .number_literal, .number_literal_fresh => try w.writeAll(&encodeF64Key(c.ts.numberValue(t))),
            // Render the key at *exactly* the display depth (`depth`, not
            // `depth + 1`): union/intersection members are displayed via
            // `printType(t, depth)`, and `printType` collapses everything past
            // depth 6 to "...". Keying one level deeper made every member at
            // display-depth 6 hash to "..." — equal keys — so the sort fell
            // back to `makeUnion`'s TypeId order, which differs across checker
            // partitions (a deep-union member-order divergence across
            // --checkers). Matching the depth makes the key equal iff the two
            // members render identically, so order is TypeId-independent.
            else => try c.printType(w, t, depth),
        }
    }

    /// Returns `members` reordered into the structural display order (see
    /// `writeSortKey`). Keys are rendered once into scratch, then sorted; a
    /// scratch-owned slice of the reordered TypeIds is returned. Members that
    /// render identically produce equal keys and print byte-identically either
    /// way, so an unstable sort stays deterministic.
    fn sortMembersStructural(c: *Checker, members: []const TypeId, depth: u32) PrintErr![]TypeId {
        const sc = c.scratch();
        const items = sc.alloc(DisplayMember, members.len) catch return error.WriteFailed;
        for (members, 0..) |mem, i| {
            var aw: std.Io.Writer.Allocating = .init(sc);
            try c.writeSortKey(&aw.writer, mem, depth);
            items[i] = .{ .ty = mem, .key = aw.written() };
        }
        std.mem.sort(DisplayMember, items, {}, struct {
            fn less(_: void, a: DisplayMember, b: DisplayMember) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.less);
        const out = sc.alloc(TypeId, members.len) catch return error.WriteFailed;
        for (items, 0..) |it, i| out[i] = it.ty;
        return out;
    }

    /// Display order for an object type's `n` properties: their stored slots
    /// reordered by property-name *text*. Object props are stored sorted by
    /// name *atom* (see `types.makeObject`), but atom ids are assigned in
    /// parallel-intern order and so vary run-to-run and across --workers;
    /// text order is content-derived and therefore byte-identical for any
    /// worker/checker count. Names are unique within an object, so the order
    /// is total (an unstable sort stays deterministic). Scratch-owned slice.
    fn propDisplayOrder(c: *Checker, t: TypeId, n: usize) Error![]u32 {
        const order = try c.scratch().alloc(u32, n);
        for (order, 0..) |*x, i| x.* = @intCast(i);
        const Ctx = struct { c: *Checker, t: TypeId };
        std.mem.sort(u32, order, Ctx{ .c = c, .t = t }, struct {
            fn less(ctx: Ctx, a: u32, b: u32) bool {
                const na = ctx.c.atomText(ctx.c.ts.objectProp(ctx.t, a).name);
                const nb = ctx.c.atomText(ctx.c.ts.objectProp(ctx.t, b).name);
                return std.mem.order(u8, na, nb) == .lt;
            }
        }.less);
        return order;
    }

    fn printNumber(w: *std.Io.Writer, v: f64) PrintErr!void {
        if (v == @floor(v) and @abs(v) < 1e15) {
            try w.print("{d}", .{@as(i64, @intFromFloat(v))});
        } else {
            try w.print("{d}", .{v});
        }
    }

    fn symbolName(c: *Checker, sym: u32) []const u8 {
        if (c.isFreshTp(sym)) return c.atomText(c.freshTp(sym).name);
        if (sym == 0 or sym >= c.prog.symbolSpace()) return "?";
        return c.atomText(c.symNameAtom(sym));
    }

    fn dumpTypes(c: *Checker, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
        for (1..c.bind.symbol_names.len) |i| {
            const local: SymbolId = @intCast(i);
            if (c.bind.symbol_scopes[local] != binder.file_scope) continue;
            const f = c.bind.symbol_flags[local];
            if (!hasValueMeaning(f)) continue;
            const sym = c.toGlobal(local);
            const t = try c.typeOfSymbol(sym);
            const str = try c.typeToString(t);
            try w.print("{s}: {s}\n", .{ c.symbolName(sym), str });
        }
    }

    // =====================================================================
    // type-node conversion
    // =====================================================================

    fn typeFromTypeNode(c: *Checker, node: Node) Error!TypeId {
        if (node == null_node) return types.no_type;
        // A type annotation resolves names against its lexically-fixed scope
        // (and any enclosing interface's `this`), both determined by the node's
        // location — so its synthesized type is context-free and memoizable by
        // `(file, node)` alone. (Diagnostics emitted here dedupe on
        // `(file, code, span)`, so skipping re-evaluation is diagnostic-safe.)
        // Only *compound* nodes are cached: leaf annotations (a bare name or a
        // literal) recompute in O(1), so caching them is pure memory overhead —
        // the re-walk cost the memo targets lives in the recursive kinds. This
        // keeps the memo small on non-generic-heavy code (RSS-neutral) while
        // still collapsing repeated walks of nested generic/object/function
        // annotations.
        const cacheable = c.inst_cache_on and typeNodeCacheable(c.nodeTag(node));
        const key = c.nodeKey(node);
        if (cacheable) {
            if (c.type_node_cache.get(key)) |t| return t;
        }
        const result = try c.typeFromTypeNodeUncached(node);
        if (cacheable) try c.type_node_cache.put(c.ca(), key, result);
        return result;
    }

    /// Type-node kinds whose synthesis recurses into sub-nodes (so re-walking
    /// is non-trivial and worth memoizing). Leaf kinds are excluded.
    fn typeNodeCacheable(tag: ast.Tag) bool {
        return switch (tag) {
            .type_ref,
            .qualified_name,
            .array_type,
            .tuple_type,
            .union_type,
            .intersection_type,
            .object_type,
            .function_type,
            .constructor_type,
            .keyof_type,
            .typeof_type,
            .indexed_access_type,
            => true,
            else => false,
        };
    }

    fn typeFromTypeNodeUncached(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        switch (c.nodeTag(node)) {
            .identifier => return c.typeFromTypeName(node, &.{}),
            .type_ref => {
                const r = c.tree.extraData(ast.SubRange, d.rhs);
                const arg_nodes = c.tree.extraRange(r.start, r.end);
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (arg_nodes) |an| {
                    if (an != null_node) try args.append(c.scratch(), try c.typeFromTypeNode(an));
                }
                return c.typeFromTypeName(d.lhs, args.items);
            },
            .qualified_name => return c.typeFromQualifiedName(node, &.{}),
            .import_type => {
                // Bare `import("m")` in type position: resolve for discovery /
                // TS2307; the module namespace itself is not a type — `any`.
                _ = try c.resolveImportTypeModule(node, true);
                return types.any_type;
            },
            .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(node)), false),
            .template_literal => return c.ts.makeStringLiteral(try c.templateAtom(c.tree.nodeMainToken(node)), false),
            .number_literal => return c.ts.makeNumberLiteral(c.numberTokenValue(c.tree.nodeMainToken(node)), false),
            .bigint_literal => return c.ts.makeBigIntLiteral(try c.atomOfToken(c.tree.nodeMainToken(node)), false),
            .true_literal => return types.true_type,
            .false_literal => return types.false_type,
            .null_literal => return types.null_type,
            .prefix_unary => {
                // Negative numeric literal type `-1`.
                if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .minus and
                    d.lhs != 0 and c.nodeTag(d.lhs) == .number_literal)
                {
                    const v = c.numberTokenValue(c.tree.nodeMainToken(d.lhs));
                    return c.ts.makeNumberLiteral(-v, false);
                }
                return types.any_type;
            },
            .array_type => return c.ts.makeArray(try c.typeFromTypeNode(d.lhs)),
            .tuple_type => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (c.tree.nodeRange(node)) |el| {
                    if (el == null_node) continue;
                    const ed = c.tree.nodeData(el);
                    switch (c.nodeTag(el)) {
                        .optional_type => try elems.append(c.scratch(), .{
                            .ty = try c.typeFromTypeNode(ed.lhs),
                            .flags = types.elem_flag_optional,
                        }),
                        .rest_type => try elems.append(c.scratch(), .{
                            .ty = try c.typeFromTypeNode(ed.lhs),
                            .flags = types.elem_flag_rest,
                        }),
                        else => try elems.append(c.scratch(), .{ .ty = try c.typeFromTypeNode(el) }),
                    }
                }
                return c.ts.makeTuple(elems.items);
            },
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (c.tree.nodeRange(node)) |m| {
                    if (m != null_node) try parts.append(c.scratch(), try c.typeFromTypeNode(m));
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            .intersection_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (c.tree.nodeRange(node)) |m| {
                    if (m != null_node) try parts.append(c.scratch(), try c.typeFromTypeNode(m));
                }
                return c.ts.makeIntersection(c.scratch(), parts.items);
            },
            .object_type => return c.objectTypeFromMembers(c.tree.nodeRange(node), 0),
            .function_type => return c.signatureOfProto(node, d.lhs, false, true),
            .constructor_type => {
                // `new (…) => R` / `abstract new (…) => R` (M18.1): an object
                // type with a single construct signature and no call signature.
                // (Abstract-ness is not yet modelled — under-reports TS2511 on
                // `new (abstractCtor)()`, never a false positive.)
                const sig = try c.signatureOfProto(node, d.lhs, false, true);
                return c.ts.makeObjectSigs(&.{}, 0, 0, types.obj_flag_not_inferable, &.{}, &.{sig});
            },
            .keyof_type => return c.keyofType(try c.typeFromTypeNode(d.lhs)),
            .typeof_type => return c.typeofEntity(d.lhs),
            .readonly_type => return c.typeFromTypeNode(d.lhs), // readonly T[] ~ T[]
            .unique_symbol_type => {
                // A `unique symbol` reached through the generic type path is in
                // a disallowed position (param, return, alias, array, union,
                // …). The allowed declaration sites (const variable, static
                // readonly field, readonly interface/type-literal property)
                // resolve it via `annTypeMaybeUnique` and never land here.
                try c.diagFmt(1335, c.nodeSpan(node), "'unique symbol' types are not allowed here.", .{});
                return c.uniqueSymType(node);
            },
            .indexed_access_type => {
                const obj = try c.typeFromTypeNode(d.lhs);
                const idx = try c.typeFromTypeNode(d.rhs);
                return c.reduceIndexedAccess(obj, idx);
            },
            .conditional_type => return c.conditionalTypeFromNode(node),
            .infer_type => return c.inferVarFromNode(node),
            .mapped_type_node => return c.mappedTypeFromNode(node),
            .template_literal_type_node => return c.templateTypeFromNode(node),
            .paren_type, .optional_type, .rest_type => return c.typeFromTypeNode(d.lhs),
            // A predicate in return-type position behaves like `boolean` for
            // a plain guard (`x is T`), or `void` for an assertion function
            // (`asserts ...`, rhs bit0). signatureOfProto attaches the
            // predicate; this keeps every other consumer (TS2355, etc.)
            // consistent.
            .type_predicate => return if (d.rhs != 0) types.void_type else types.boolean_type,
            .this_expr => return if (c.this_type != 0) c.this_type else types.any_type,
            .error_node, .unsupported => return types.any_type,
            else => return types.any_type,
        }
    }

    /// A named type reference (identifier, possibly with type arguments).
    fn typeFromTypeName(c: *Checker, name_node: Node, args: []const TypeId) Error!TypeId {
        if (name_node == null_node) return types.any_type;
        // `member_expr` appears when the name came from expression position
        // (class/interface `extends` clauses); it shares qualified_name's
        // layout (lhs = base node, rhs = name token).
        if (c.nodeTag(name_node) == .qualified_name or c.nodeTag(name_node) == .member_expr)
            return c.typeFromQualifiedName(name_node, args);
        if (c.nodeTag(name_node) != .identifier) return types.any_type;
        const tok = c.tree.nodeMainToken(name_node);
        switch (c.tree.tokens.tag(tok)) {
            .keyword_any => return types.any_type,
            .keyword_unknown => return types.unknown_type,
            .keyword_never => return types.never_type,
            .keyword_void => return types.void_type,
            .keyword_undefined => return types.undefined_type,
            .keyword_number => return types.number_type,
            .keyword_string => return types.string_type,
            .keyword_boolean => return types.boolean_type,
            .keyword_bigint => return types.bigint_type,
            .keyword_symbol => return types.symbol_type,
            .keyword_object => return types.object_keyword_type,
            else => {},
        }
        const a = try c.atomOfToken(tok);
        // An `infer V` binder is in scope (extends + true branches) as a bare
        // type reference to `V`. It shadows outer names, matching tsc. Search
        // the active conditional scopes innermost-outward: a nested conditional
        // in an outer conditional's true branch still resolves the outer infer
        // vars (only scopes that actually declared `V` have an entry).
        // A same-named type param of the alias body currently being built is
        // more local than any outer `infer`/mapped binder, so it shadows them
        // (tsc lexical scoping) — skip both lookups for such a name.
        const shadowed = indexOfAtom(c.tp_shadow, a) != null;
        if (args.len == 0 and !shadowed) {
            // Lexical innermost-wins between an outer conditional's `infer X`
            // and a same-named mapped key `[X in K]`: the mapped key is
            // declared INSIDE the branch that binds `infer X`, so within the
            // mapped `as`/value a bare `X` is the mapped param and shadows the
            // infer binder — matching tsc, and (crucially) making the built
            // value route-independent. `cur_mapped_key_scope_depth` is the
            // infer-scope stack height when the mapped key was entered: scopes
            // below it are OUTER (mapped key shadows them); scopes at/above it
            // belong to a conditional NESTED in the mapped value and stay inner
            // (they still win). Without this, `{ [P in K]: T[P] }` nested in a
            // `… infer P …` branch built its value as `T[infer_var]`; the
            // unbound infer var collapses the indexed access to `any` at
            // reduction → every prop dropped to required (the
            // `--checkers`-partition-dependent TS2739/TS2322 non-confluence).
            const mk_here = c.cur_mapped_key_name != 0 and c.cur_mapped_key_name == a;
            var i = c.infer_scopes.items.len;
            while (i > 0) {
                i -= 1;
                if (mk_here and i < c.cur_mapped_key_scope_depth) return c.cur_mapped_key_ty;
                if (c.infer_ids.get(.{ .cond = c.infer_scopes.items[i], .name = a })) |id| {
                    return c.ts.makeInferVar(id, a);
                }
            }
            // A mapped type's key parameter `K` is in scope in its `as`/value
            // branches (M16b); a bare `K` there resolves to the mapped_param.
            if (mk_here) return c.cur_mapped_key_ty;
        }
        switch (c.resolveSpace(a, c.cur_scope, false)) {
            .sym => |sym0| {
                var sym = sym0;
                var f = c.symFlags(sym);
                if (f.import_binding) {
                    const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
                    switch (tgt.kind) {
                        .binding => {
                            const g = c.toGlobalIn(tgt.file, tgt.payload);
                            // Route through the cross-file merge index so an
                            // imported interface augmented by a `declare module`
                            // in another file resolves to the folded interface
                            // (M11c cross-file augmentation).
                            sym = c.prog.mergedOf(g) orelse g;
                            f = c.symFlags(sym);
                            if (!hasTypeMeaning(f) or f.import_binding) {
                                if (hasValueMeaning(f)) {
                                    try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
                                    return types.error_type;
                                }
                                return types.any_type;
                            }
                        },
                        // Namespace-as-type / unresolved: any (documented).
                        .namespace, .default_expr, .ambient_ns, .any => return types.any_type,
                    }
                }
                return c.materializeTypeRef(sym, args, tok, a);
            },
            .wrong_space => {
                try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
                return types.error_type;
            },
            .none => {
                // Inside a `declare module "X"` augmentation of a real module,
                // an unqualified name resolves against X's own exports — the
                // augmentation shares X's symbol table in tsc. Lets `declare
                // module "leaflet" { namespace DrawEvents { interface DrawStop
                // extends LeafletEvent … } }` reach leaflet's `LeafletEvent`;
                // without it the heritage base silently drops and the interface
                // loses every inherited member (→ spurious TS2352 downstream on
                // a `DrawStop`-typed value cast to a `LeafletEvent` handler).
                if (try c.augmentModuleTypeSym(c.cur_scope, a)) |gsym| {
                    return c.materializeTypeRef(gsym, args, tok, a);
                }
                // The four intrinsic string transforms are magic global
                // aliases (`type Uppercase<S extends string> = intrinsic;`),
                // not declared in ztsc's minimal lib — recognize them by name
                // here, after user symbols (which would shadow) had their turn.
                if (args.len == 1) {
                    if (intrinsicStringMapping(c.atomText(a))) |kind_idx| {
                        return c.applyStringMapping(kind_idx, args[0]);
                    }
                }
                if (c.suggestName(a, c.cur_scope, false)) |sugg| {
                    try c.diagFmt(2552, c.tokSpan(tok), "Cannot find name '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
                } else {
                    try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{c.tokenText(tok)});
                }
                return types.error_type;
            },
        }
    }

    /// Materialize a resolved type-space symbol `sym` into its `TypeId`
    /// (type-parameter / enum / alias-instance / interface-or-class ref),
    /// applying `args`. Shared by the ordinary scope-resolution arm and the
    /// `declare module` augmentation fallback so both build the identical type.
    fn materializeTypeRef(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex, a: Atom) Error!TypeId {
        const f = c.symFlags(sym);
        if (f.type_param) return c.ts.makeTypeParam(sym);
        if (f.enum_decl) return c.ts.makeEnumType(sym);
        if (f.type_alias) {
            // The real lib declares the four string transforms as
            // `type Uppercase<S extends string> = intrinsic;`. Recognize an
            // `intrinsic`-bodied alias by name and apply the mapping (ztsc has
            // no general `intrinsic` mechanism). A user alias of the same name
            // with a real body is unaffected.
            if (args.len == 1) {
                if (intrinsicStringMapping(c.atomText(a))) |kind_idx| {
                    if (c.aliasBodyIsIntrinsic(sym)) return c.applyStringMapping(kind_idx, args[0]);
                }
            }
            return c.aliasInstance(sym, args, tok);
        }
        if (f.interface or f.class) {
            const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
            // The global `Array<T>` / `ReadonlyArray<T>` lower to `T[]`: tsc
            // treats `Array<T>` and `T[]` as the *same* type, and
            // `ReadonlyArray<T>` as `readonly T[]` (which ztsc already folds to
            // `T[]`; array readonly-ness is not modeled). Keeping them as
            // structural refs instead makes `T[]` fail to relate to them
            // through the interface body (ref→array has no structural bridge).
            if (fixed.len == 1 and (c.globalSymNamed(sym, "Array") or c.globalSymNamed(sym, "ReadonlyArray"))) {
                return c.ts.makeArray(fixed[0]);
            }
            return c.ts.makeRef(sym, fixed);
        }
        return types.any_type;
    }

    /// Walk outward from `from` for an enclosing `declare module "X"`
    /// augmentation block; if found, resolve the augmented module X (via the
    /// current file's specifier map) and return export `a`'s type-space global
    /// symbol. Powers tsc's rule that unqualified names inside a module
    /// augmentation see the augmented module's own exports.
    fn augmentModuleTypeSym(c: *Checker, from: ScopeId, a: Atom) Error!?SymbolId {
        if (c.prog.files.len == 0) return null;
        var s = from;
        while (true) {
            const owner = c.bind.scope_owners[s];
            if (owner != 0 and c.nodeTag(owner) == .namespace_decl) {
                const nd = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(owner).lhs);
                if (nd.flags & ast.Flags.ambient_module != 0 and nd.name_token != 0) {
                    const spec = try c.memberAtom(nd.name_token);
                    if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| {
                        if (c.moduleExportTarget(.{ .file = mfile }, a)) |tgt| {
                            if (c.targetTypeSym(tgt)) |gsym| {
                                if (hasTypeMeaning(c.symFlags(gsym))) return gsym;
                            }
                        }
                    }
                }
            }
            if (s == binder.file_scope) break;
            s = c.bind.scope_parents[s];
        }
        return null;
    }

    /// Resolve member `name` of namespace symbol `ns_sym` to its global id, or
    /// null. A merged namespace (M11b) consults its merged member index; a
    /// plain namespace looks the name up in its single (merged-within-file)
    /// body scope. The caller filters by space/`exported`.
    fn namespaceMemberSym(c: *Checker, ns_sym: SymbolId, name: Atom) ?SymbolId {
        if (c.prog.isMergedId(ns_sym)) {
            return c.prog.mergedSym(ns_sym).members.lookup(name);
        }
        const nb = c.symBind(ns_sym);
        const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return null;
        const local = nb.lookupInScope(ns, name) orelse return null;
        return c.toGlobalIn(c.symFile(ns_sym), local);
    }

    /// If namespace scope `s` belongs to a symbol that is a cross-file merge
    /// constituent, return member `a` from the merged member index (a global
    /// id), else null. Lets a bare name inside one file's namespace body see
    /// declarations another file contributed to the same merged namespace.
    fn mergedNsMemberOfScope(c: *Checker, s: ScopeId, a: Atom) ?SymbolId {
        const owner = c.bind.scope_owners[s];
        if (owner == 0 or c.nodeTag(owner) != .namespace_decl) return null;
        const nd = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(owner).lhs);
        // Only named namespaces merge by name; `global {}` / `declare module`
        // blocks carry a keyword/string name_token, not an identifier.
        if (nd.flags & (ast.Flags.global_aug | ast.Flags.ambient_module) != 0) return null;
        if (nd.name_token == 0) return null;
        const name = c.atomOfToken(nd.name_token) catch return null;
        const local = c.bind.lookupInScope(c.bind.scope_parents[s], name) orelse return null;
        const merged = c.prog.mergedOf(c.toGlobal(local)) orelse return null;
        if (!c.prog.isMergedId(merged)) return null;
        return c.prog.mergedSym(merged).members.lookup(a);
    }

    /// A resolved type-position `import("m")` target: an on-disk program file
    /// or an ambient/augmentation module (M11c).
    const ModuleRef = union(enum) { file: FileId, ambient: u32 };

    /// The left side of a qualified type/entity name (`A.B.T`), resolved to the
    /// container that holds its members: either a namespace symbol or a whole
    /// module namespace object (`import * as ns from "m"`). Unifies the two
    /// member-lookup mechanisms (namespace scope vs module export table) so a
    /// namespace-import qualifier reaches a named-export module's members —
    /// e.g. `import * as mod from "./m"; interface I extends mod.Base {}`.
    const NsContainer = union(enum) { ns: SymbolId, module: ModuleRef };

    /// Resolve an `.import_type` node's specifier to its module. Reports TS2307
    /// (deduped per span) when the specifier resolves to neither an on-disk
    /// module nor an ambient `declare module`.
    fn resolveImportTypeModule(c: *Checker, import_node: Node, report: bool) Error!?ModuleRef {
        const spec_tok = c.tree.nodeData(import_node).lhs;
        if (spec_tok == 0) return null;
        const spec = try c.memberAtom(spec_tok);
        if (c.prog.files.len != 0) {
            if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| return .{ .file = mfile };
        }
        if (c.ambientIndex(spec)) |idx| return .{ .ambient = idx };
        if (report) {
            try c.diagFmt(2307, c.tokSpan(spec_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{stripQuotes(c.tokenText(spec_tok))});
        }
        return null;
    }

    /// Ambient-module registry index matching specifier `spec`: exact name,
    /// else a wildcard pattern (`declare module "*.css"`). Mirrors the linker's
    /// `ambientKey` so import() types resolve against the same registry.
    fn ambientIndex(c: *Checker, spec: Atom) ?u32 {
        const specs = c.prog.ambient_specs;
        for (specs, 0..) |s, i| if (s == spec) return @intCast(i);
        const text = c.atomText(spec);
        for (specs, 0..) |s, i| {
            const pat = c.atomText(s);
            const star = std.mem.indexOfScalar(u8, pat, '*') orelse continue;
            const prefix = pat[0..star];
            const suffix = pat[star + 1 ..];
            if (text.len >= prefix.len + suffix.len and
                std.mem.startsWith(u8, text, prefix) and
                std.mem.endsWith(u8, text, suffix)) return @intCast(i);
        }
        return null;
    }

    /// Look up export `name` in a resolved module, returning its link Target.
    fn moduleExportTarget(c: *Checker, m: ModuleRef, name: Atom) ?modules.Target {
        switch (m) {
            .file => |f| {
                if (c.prog.links.len == 0) return null;
                return c.prog.links[f].exportTarget(name);
            },
            .ambient => |idx| {
                const ae = c.prog.ambient_exports[idx];
                var lo: usize = 0;
                var hi: usize = ae.atoms.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (ae.atoms[mid] == name) return ae.targets[mid];
                    if (ae.atoms[mid] < name) lo = mid + 1 else hi = mid;
                }
                return null;
            },
        }
    }

    /// The global symbol an export Target denotes (for type materialization),
    /// or null for non-binding targets (namespace objects, default expressions).
    fn targetTypeSym(c: *Checker, tgt: modules.Target) ?SymbolId {
        return switch (tgt.kind) {
            // Route through the cross-file merge index so a `ns.I` / qualified /
            // `import("m").I` reference to an interface augmented by a
            // `declare module` in another file sees the folded interface (M11c).
            .binding => blk: {
                const g = c.toGlobalIn(tgt.file, tgt.payload);
                break :blk c.prog.mergedOf(g) orelse g;
            },
            else => null,
        };
    }

    /// `import("m").T[<args>]` in type position (M14): resolve the module, then
    /// its exported type `T`. Unresolved module ⇒ TS2307 (in the resolver);
    /// missing/non-type member ⇒ TS2694, matching tsc.
    fn importTypeMember(c: *Checker, import_node: Node, name_tok: TokenIndex, args: []const TypeId) Error!TypeId {
        const m = (try c.resolveImportTypeModule(import_node, true)) orelse return types.error_type;
        const name = try c.memberAtom(name_tok);
        if (c.moduleExportTarget(m, name)) |tgt| {
            if (c.targetTypeSym(tgt)) |sym| {
                if (hasTypeMeaning(c.symFlags(sym))) return c.namedTypeFromSymbol(sym, args, name_tok);
            }
        }
        const spec_tok = c.tree.nodeData(import_node).lhs;
        try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ stripQuotes(c.tokenText(spec_tok)), c.atomText(name) });
        return types.error_type;
    }

    /// Resolve a qualified type name `A.B.T` (in type position) by walking
    /// namespace containers left-to-right, then building the final member's
    /// type. Missing/non-exported members report TS2694 like tsc.
    fn typeFromQualifiedName(c: *Checker, node: Node, args: []const TypeId) Error!TypeId {
        const d = c.tree.nodeData(node);
        const name_tok: TokenIndex = d.rhs;
        // `import("m").T` — the qualifier base is a module, not a namespace sym.
        if (c.nodeTag(d.lhs) == .import_type) return c.importTypeMember(d.lhs, name_tok, args);
        const name = try c.memberAtom(name_tok);
        const container = (try c.resolveNsContainer(d.lhs)) orelse return types.any_type;
        switch (container) {
            .ns => |ns_sym| {
                if (c.namespaceMemberSym(ns_sym, name)) |g| {
                    const mf = c.symFlags(g);
                    if (mf.exported and hasTypeMeaning(mf)) {
                        return c.namedTypeFromSymbol(g, args, name_tok);
                    }
                }
                try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ c.symbolName(ns_sym), c.atomText(name) });
                return types.error_type;
            },
            .module => |m| {
                if (c.moduleExportTarget(m, name)) |tgt| {
                    if (c.targetTypeSym(tgt)) |g| {
                        if (hasTypeMeaning(c.symFlags(g))) return c.namedTypeFromSymbol(g, args, name_tok);
                    }
                }
                // A member ztsc cannot resolve through a namespace-import module
                // (incomplete `export *` / re-export modeling, CommonJS namespace
                // identity out of subset) degrades to `any` rather than a
                // spurious TS2694 — the documented M20 under-report policy. The
                // fix is that resolvable members (`extends mod.Base`) now bind;
                // unresolvable ones stay as lenient as the pre-fix `any`.
                return types.any_type;
            },
        }
    }

    /// Resolve the qualifier of a dotted type/entity name (identifier or nested
    /// qualified name) to the container that holds its members — a namespace
    /// symbol or a whole-module namespace object. Follows `import * as ns` /
    /// `import = require` bindings to the imported module so `ns.Member` reaches
    /// a named-export module's exports (previously such a base silently degraded
    /// to `any`, so heritage `extends ns.Base` inherited zero members). Null for
    /// a non-namespace or unresolvable qualifier.
    fn resolveNsContainer(c: *Checker, node: Node) Error!?NsContainer {
        switch (c.nodeTag(node)) {
            .identifier => {
                const a = try c.atomOfToken(c.tree.nodeMainToken(node));
                switch (c.resolveSpace(a, c.cur_scope, false)) {
                    .sym => |sym| {
                        if (c.symFlags(sym).namespace_decl) return .{ .ns = sym };
                        if (c.symFlags(sym).import_binding) {
                            if (c.importTarget(sym)) |tgt| return c.containerFromImportTarget(tgt);
                        }
                        return null;
                    },
                    else => return null,
                }
            },
            .qualified_name, .member_expr => {
                const d = c.tree.nodeData(node);
                const name = try c.memberAtom(d.rhs);
                // `import("m").NS` as a namespace container: the module itself.
                if (c.nodeTag(d.lhs) == .import_type) {
                    const m = (try c.resolveImportTypeModule(d.lhs, true)) orelse return null;
                    return c.nestNsContainer(.{ .module = m }, name);
                }
                const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
                return c.nestNsContainer(outer, name);
            },
            else => return null,
        }
    }

    /// Follow an import-binding link target to the namespace container it
    /// denotes: a namespace declaration symbol (the `export =` entity of an
    /// `export =`-module, or a re-export), or the whole-module namespace object
    /// of a plain named-export module (`import * as`). Null otherwise.
    fn containerFromImportTarget(c: *Checker, tgt: modules.Target) ?NsContainer {
        switch (tgt.kind) {
            .binding => {
                const g = c.toGlobalIn(tgt.file, tgt.payload);
                if (c.symFlags(g).namespace_decl) return .{ .ns = g };
                if (c.symFlags(g).import_binding) {
                    if (c.importTarget(g)) |t2| return c.containerFromImportTarget(t2);
                }
                return null;
            },
            .namespace => return .{ .module = .{ .file = tgt.file } },
            .ambient_ns => return .{ .module = .{ .ambient = tgt.payload } },
            else => return null,
        }
    }

    /// Resolve member `name` of a container to a *nested* namespace container
    /// (for a deeper `a.b.c` qualifier). Requires the member to be an exported
    /// namespace (or a re-export/namespace-import of one). Null otherwise.
    fn nestNsContainer(c: *Checker, outer: NsContainer, name: Atom) ?NsContainer {
        switch (outer) {
            .ns => |ns| {
                const g = c.namespaceMemberSym(ns, name) orelse return null;
                const mf = c.symFlags(g);
                if (!mf.exported) return null;
                if (mf.namespace_decl) return .{ .ns = g };
                if (mf.import_binding) {
                    if (c.importTarget(g)) |t2| return c.containerFromImportTarget(t2);
                }
                return null;
            },
            .module => |m| {
                const tgt = c.moduleExportTarget(m, name) orelse return null;
                return c.containerFromImportTarget(tgt);
            },
        }
    }

    /// The exported member symbol `name` of a namespace container (global id),
    /// or null. Shared by qualified-entity resolution that needs the member's
    /// declaration symbol (class-`extends` bases) rather than its type.
    fn containerMemberSym(c: *Checker, container: NsContainer, name: Atom) ?SymbolId {
        switch (container) {
            .ns => |ns| {
                const g = c.namespaceMemberSym(ns, name) orelse return null;
                return if (c.symFlags(g).exported) g else null;
            },
            .module => |m| {
                const tgt = c.moduleExportTarget(m, name) orelse return null;
                return c.targetTypeSym(tgt);
            },
        }
    }

    /// Display text of a qualified-name qualifier's trailing identifier, for
    /// TS2694 messages (`Namespace '<here>' has no exported member '…'`).
    fn qualifierText(c: *Checker, node: Node) []const u8 {
        return switch (c.nodeTag(node)) {
            .identifier => c.tokenText(c.tree.nodeMainToken(node)),
            .qualified_name, .member_expr => c.tokenText(c.tree.nodeData(node).rhs),
            else => "",
        };
    }

    /// Build the type of a named type symbol (interface/class/alias/enum/
    /// type-param). Shared by bare and qualified type-name resolution.
    fn namedTypeFromSymbol(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!TypeId {
        const f = c.symFlags(sym);
        if (f.type_param) return c.ts.makeTypeParam(sym);
        if (f.enum_decl) return c.ts.makeEnumType(sym);
        if (f.type_alias) return c.aliasInstance(sym, args, tok);
        if (f.interface or f.class) {
            const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
            return c.ts.makeRef(sym, fixed);
        }
        return types.any_type;
    }

    /// `typeof entity` in type position: the entity's value type.
    fn typeofEntity(c: *Checker, node: Node) Error!TypeId {
        if (node == null_node) return types.any_type;
        // `typeof import("m")` — the module's value-namespace object type.
        if (c.nodeTag(node) == .import_type) {
            const m = (try c.resolveImportTypeModule(node, true)) orelse return types.error_type;
            return switch (m) {
                .file => |f| c.namespaceObjectType(f),
                .ambient => |idx| c.ambientNamespaceType(idx),
            };
        }
        // `typeof import("m").val` — the value type of the export `val`.
        if (c.nodeTag(node) == .qualified_name) {
            const d = c.tree.nodeData(node);
            if (c.nodeTag(d.lhs) == .import_type) {
                const m = (try c.resolveImportTypeModule(d.lhs, true)) orelse return types.error_type;
                const name = try c.memberAtom(d.rhs);
                if (c.moduleExportTarget(m, name)) |tgt| return c.targetValueType(tgt);
                const spec_tok = c.tree.nodeData(d.lhs).lhs;
                try c.diagFmt(2694, c.tokSpan(d.rhs), "Namespace '{s}' has no exported member '{s}'.", .{ stripQuotes(c.tokenText(spec_tok)), c.atomText(name) });
                return types.error_type;
            }
        }
        if (c.nodeTag(node) != .identifier) return types.any_type;
        const tok = c.tree.nodeMainToken(node);
        if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
        const a = try c.atomOfToken(tok);
        switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |sym| return c.typeOfSymbol(sym),
            .wrong_space => return types.any_type,
            .none => {
                // `typeof globalThis` — always in scope (see checkIdentifier).
                if (std.mem.eql(u8, c.atomText(a), "globalThis")) return types.any_type;
                try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{c.tokenText(tok)});
                return types.error_type;
            },
        }
    }

    const TypeParamInfo = struct {
        sym: SymbolId,
        constraint: Node,
        default: Node,
    };

    /// Type parameters of a generic symbol (class/interface/alias), from
    /// its first declaration. Symbol ids in the result are global.
    fn typeParamsOf(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        const decls = c.declsOf(sym);
        if (decls.len == 0) return;
        const decl = decls[0];
        const d = c.tree.nodeData(decl);
        var tp_start: u32 = 0;
        var tp_end: u32 = 0;
        switch (c.nodeTag(decl)) {
            .class_decl => {
                const data = c.tree.extraData(ast.ClassData, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            .interface_decl => {
                const data = c.tree.extraData(ast.InterfaceData, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            .type_alias => {
                const data = c.tree.extraData(ast.TypeAlias, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            else => return,
        }
        const decl_scope = (try c.scopeOf(decl)) orelse return;
        for (c.tree.extraRange(tp_start, tp_end)) |tp| {
            if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
            const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
            const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
            const td = c.tree.nodeData(tp);
            try buf.append(c.scratch(), .{ .sym = c.toGlobal(tp_sym), .constraint = td.lhs, .default = td.rhs });
        }
    }

    /// Type-parameter symbols of a single declaration node (class/interface/
    /// alias), in positional order, resolved in the current file context.
    /// Reopened interface blocks each bind a *distinct* type-param symbol for
    /// the same positional name, so an instantiation must map all of them (see
    /// `buildInstMap`).
    fn typeParamSymsOfDecl(c: *Checker, decl: Node, buf: *std.ArrayList(SymbolId)) Error!void {
        const d = c.tree.nodeData(decl);
        var tp_start: u32 = 0;
        var tp_end: u32 = 0;
        switch (c.nodeTag(decl)) {
            .class_decl => {
                const data = c.tree.extraData(ast.ClassData, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            .interface_decl => {
                const data = c.tree.extraData(ast.InterfaceData, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            .type_alias => {
                const data = c.tree.extraData(ast.TypeAlias, d.lhs);
                tp_start = data.tp_start;
                tp_end = data.tp_end;
            },
            else => return,
        }
        const decl_scope = (try c.scopeOf(decl)) orelse return;
        for (c.tree.extraRange(tp_start, tp_end)) |tp| {
            if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
            const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
            const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
            try buf.append(c.scratch(), c.toGlobal(tp_sym));
        }
    }

    /// Build the type-parameter → argument substitution map for instantiating
    /// generic `sym` with `args`. A reopened interface (or a cross-file merged
    /// interface, M11a) binds a distinct type-param symbol per declaration
    /// block, but tsc unifies them by position — so every block's i-th
    /// type-param symbol maps to `args[i]`. Missing args fall back to `any`.
    fn buildInstMap(c: *Checker, sym: SymbolId, args: []const TypeId, out: *std.ArrayList(TpMap)) Error!void {
        var one = [_]SymbolId{sym};
        const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
        for (parts) |csym| {
            const saved = c.enterSymFile(csym);
            defer c.restoreCtx(saved);
            for (c.declsOf(csym)) |decl| {
                var syms: std.ArrayList(SymbolId) = .empty;
                defer syms.deinit(c.scratch());
                try c.typeParamSymsOfDecl(decl, &syms);
                for (syms.items, 0..) |tp_sym, i| {
                    const ty = if (i < args.len) args[i] else types.any_type;
                    try out.append(c.scratch(), .{ .sym = tp_sym, .ty = ty });
                }
            }
        }
    }

    /// Check type-argument arity against a generic symbol and fill defaults.
    /// Returns null (after TS2314/2558) on arity mismatch.
    fn fixTypeArgs(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!?[]const TypeId {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        if (args.len == tps.items.len) return try c.scratch().dupe(TypeId, args);
        var min: usize = 0;
        for (tps.items) |tp| {
            if (tp.default == 0) min += 1;
        }
        if (args.len < min or args.len > tps.items.len) {
            if (tps.items.len == 0) {
                // Non-generic type applied to type args. Report TS2315 (as tsc
                // does) but degrade to the base type rather than dropping it,
                // so a `X extends NonGeneric<T>` base keeps its inherited
                // members instead of stripping them all. (Historically this
                // bridged @types/node's generic `Buffer<T> extends
                // Uint8Array<T>` onto the 5.5.4 lib's non-generic
                // `Uint8Array`; the TS 7.0.2 lib is generic, so that skew is
                // gone, but the degradation stays the right lenient default.)
                try c.diagFmt(2315, c.tokSpan(tok), "Type '{s}' is not generic.", .{c.symbolName(sym)});
                return try c.scratch().dupe(TypeId, &.{});
            }
            if (min == tps.items.len) {
                try c.diagFmt(2314, c.tokSpan(tok), "Generic type '{s}' requires {d} type argument(s).", .{ c.symbolName(sym), min });
            } else {
                // With defaults the valid arity is a range (tsc's TS2707).
                try c.diagFmt(2707, c.tokSpan(tok), "Generic type '{s}' requires between {d} and {d} type arguments.", .{ c.symbolName(sym), min, tps.items.len });
            }
            return null;
        }
        var out = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| {
            if (i < args.len) {
                out[i] = args[i];
            } else if (tp.default != 0) {
                // Defaults are nodes of the declaring file; evaluate there,
                // then substitute the already-resolved params so `B = A` sees
                // the supplied `A` (and `C = B` the defaulted `B`).
                var def: TypeId = undefined;
                {
                    const saved = c.enterSymFile(sym);
                    defer c.restoreCtx(saved);
                    c.cur_scope = c.symScope(tp.sym);
                    def = try c.typeFromTypeNode(tp.default);
                }
                // A *bare* default reference to an earlier own param (`Tr = T`)
                // whose alias is *self-recursive* is the recursion accumulator of
                // RHF's `PathInternal<T, TraversedTypes = T>`: its termination
                // guard `AnyIsEqual<Tr, V>` only fires once `Tr` is the concrete
                // form, so the default must resolve to that param's supplied
                // argument even for a library (`.d.ts`) generic. This is a single
                // symbol swap (no expansion), so it cannot reintroduce the
                // deep-generic OOM that gates `.d.ts` defaults. Scoping to
                // recursive aliases keeps non-recursive library defaults (e.g.
                // redux `Reducer<S, A, PreloadedState = S>`) on the pre-existing
                // unsubstituted path — substituting those would eagerly reduce
                // otherwise-deferred store machinery (`ExtractStoreExtensions`)
                // that only reduces cleanly once the infer-var/poison work lands.
                const bare_earlier: ?usize = if (c.ts.kind(def) == .type_param) blk: {
                    const dsym = c.ts.typeParamSymbol(def);
                    for (tps.items[0..i], 0..) |ptp, j| {
                        if (ptp.sym == dsym) break :blk j;
                    }
                    break :blk null;
                } else null;
                // A *ground* referenced argument (no type param anywhere) can
                // always be swapped in — this is a single symbol swap identical
                // to the function-call default path (`inferTypeArgs` fills an
                // uninferable default via `instantiate(def, resolved)`), so the
                // alias annotation `UseFormReturn<P>` fills its
                // `TTransformedValues = TFieldValues` default to the supplied `P`
                // exactly as `useForm<P>()`'s return does, keeping the two sides
                // structurally identical (reflexive assignability). A ground arg
                // cannot re-materialize deferred `.d.ts` machinery (the OOM guard
                // and the redux `ExtractStoreExtensions` unmask both require an
                // *abstract* arg), so those concerns below don't apply here.
                const ground_earlier = bare_earlier != null and
                    !(try c.containsTypeParam(out[bare_earlier.?]));
                // Ensure the generic body is built so self-recursion is detected
                // (the flag is set when materialization re-enters this alias).
                const recursive = if (bare_earlier != null and !ground_earlier and c.symInDeclFile(sym)) rec: {
                    if ((c.alias_state.get(sym) orelse 0) != 1) _ = try c.aliasGeneric(sym);
                    break :rec (c.alias_state.get(sym) orelse 0) == 1 or c.alias_recursive.contains(sym);
                } else true;
                if (bare_earlier != null and (ground_earlier or recursive or !c.symInDeclFile(sym))) {
                    out[i] = out[bare_earlier.?];
                } else if (c.symInDeclFile(sym)) {
                    // A *complex* or non-recursive library default (e.g. RTK's
                    // `ExtractStoreExtensionsFromEnhancerTuple` tuple default, or
                    // `Reducer`'s `PreloadedState = S`) stays unsubstituted:
                    // threading a concrete arg through it re-materializes
                    // deeply-recursive `.d.ts` types (the historic OOM) or unmasks
                    // a still-deferred reduction, so keep prior lenient behavior.
                    out[i] = def;
                } else {
                    // Substitute the already-resolved params into the default so
                    // an earlier-param reference (`B = A`) sees the supplied `A`
                    // (and `C = B` the defaulted `B`) for user generics.
                    const pmap = try c.scratch().alloc(TpMap, i);
                    for (tps.items[0..i], 0..) |ptp, j| pmap[j] = .{ .sym = ptp.sym, .ty = out[j] };
                    out[i] = try c.instantiate(def, pmap);
                }
            } else {
                out[i] = types.any_type;
            }
        }
        return out;
    }

    /// keyof T for the resolved structural type (object-ish only; the M6
    /// subset has non-generic keys).
    fn keyofType(c: *Checker, t: TypeId) Error!TypeId {
        const r = try c.resolveStructural(t);
        switch (c.ts.kind(r)) {
            .any, .err => return c.makeUnion2(types.string_type, c.makeUnion2(types.number_type, types.symbol_type) catch unreachable),
            .object => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (0..c.ts.objectPropCount(r)) |i| {
                    const p = c.ts.objectProp(r, @intCast(i));
                    try parts.append(c.scratch(), try c.ts.makeStringLiteral(p.name, false));
                }
                if (c.ts.objectStringIndex(r) != 0) {
                    try parts.append(c.scratch(), types.string_type);
                    try parts.append(c.scratch(), types.number_type);
                }
                if (c.ts.objectNumberIndex(r) != 0) try parts.append(c.scratch(), types.number_type);
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            .array, .tuple => return types.number_type, // approximation (no lib members)
            // `keyof` of a mapped type reflects its key set (M16d, closing the
            // loop with M16b): `keyof { [K in "a"|"b"]: X }` === `"a" | "b"`.
            // The key set is the constraint (homomorphic → `keyof source`),
            // possibly narrowed by an `as` remap. A generic key set stays
            // deferred; a concrete `as` clause is applied per key.
            .mapped => return c.keyofMapped(r),
            // `keyof (A & B) === keyof A | keyof B` (tsc `getIndexType` maps over
            // the intersection constituents and unions the per-constituent key
            // sets). A concrete param-free intersection would otherwise fall to
            // the `else` arm and wrongly collapse to `never`, so a conditional
            // `K extends keyof (A & B)` (react-hook-form `PathValue`/`FieldPath`
            // over an intersection form type) took its false arm. Per-member
            // deferral is automatic: a generic constituent's `keyofType` returns
            // its own deferred `keyof`, which the union carries and reduces once
            // that constituent is known.
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                // `memberList` DUPES the member ids onto scratch before the loop.
                // Iterating `c.ts.members(r)` directly would be a use-after-
                // realloc: the recursive `keyofType(m)` interns new composite
                // types (its own `makeUnion`, and — under instantiation — nested
                // `instantiate` calls), which append to the store's `extra`
                // array and can move its backing buffer, dangling a live slice
                // captured from `members(r)`. A later iteration would then read a
                // stale/garbage member id (in Debug a 0xAA-poison bounds panic;
                // in ReleaseFast an unchecked garbage read). Every other member-
                // iterating site that interns in its body already dupes first.
                for (try c.memberList(r)) |m| {
                    try parts.append(c.scratch(), try c.keyofType(m));
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            // A generic operand (a type param or another deferred node) → a
            // deferred `keyof` that resolves on instantiation. `keyof T` is not
            // computable until `T` is known, so it must not collapse to `never`.
            .type_param, .index_access, .conditional, .keyof_op, .infer_var, .this_type => return c.ts.makeKeyof(r),
            else => {
                if (try c.containsTypeParam(r)) return c.ts.makeKeyof(r);
                return types.never_type;
            },
        }
    }

    /// `keyof` of a (deferred) mapped type: its key set. Non-remapped maps use
    /// the constraint directly (homomorphic → `keyof source`); an `as` clause
    /// with concrete keys is applied per member so `Omit`-style filtering and
    /// renames are reflected.
    fn keyofMapped(c: *Checker, m: TypeId) Error!TypeId {
        const s = &c.ts;
        const homomorphic = s.mappedHomomorphic(m);
        const constraint: TypeId = if (homomorphic)
            try c.keyofType(s.mappedSource(m))
        else
            s.mappedConstraint(m);
        const as_clause = s.mappedAs(m);
        if (as_clause == 0) return constraint;
        // With an `as` remap, the keys are the remapped set. Only enumerate
        // when the constraint is a concrete literal / union of literals;
        // otherwise defer via a keyof over the whole mapped type.
        const key_id = s.mappedParamId(s.mappedKeyParam(m));
        var keys_buf = [_]TypeId{constraint};
        const keys: []const TypeId = if (s.kind(constraint) == .union_type)
            try c.memberList(constraint)
        else
            keys_buf[0..];
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (keys) |k| {
            switch (s.kind(k)) {
                .string_literal, .number_literal, .number_literal_fresh => {
                    const nm = (try c.remapKey(as_clause, key_id, k)) orelse continue;
                    try parts.append(c.scratch(), try s.makeStringLiteral(nm, false));
                },
                else => return c.ts.makeKeyof(m), // non-enumerable key set — defer
            }
        }
        return s.makeUnion(c.scratch(), parts.items);
    }

    /// T[K] with literal / index-signature keys (non-generic subset).
    fn indexedAccessType(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
        const r = try c.resolveStructural(obj);
        switch (c.ts.kind(idx)) {
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(idx)) |m| {
                    try parts.append(c.scratch(), try c.indexedAccessType(obj, m));
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            .string_literal => {
                if (try c.propOfType(r, c.ts.literalAtom(idx))) |p| {
                    return if (p.optional() and !c.homo_index_mode) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                }
                if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0) {
                    return c.ts.objectStringIndex(r);
                }
                // Property genuinely absent (no index signature). tsc's
                // `getIndexedAccessType` resolves a missing type-level access
                // to `unknown`, NOT `any` — decisive for a conditional check
                // type like `TOpt['returnObjects'] extends true`: an absent
                // property must yield the FALSE branch (`unknown extends true`
                // is false), whereas `any extends true` wrongly took the true
                // branch (i18next `t()` → `$SpecialObject` instead of `string`).
                // An `any`/error object still indexes to `any`.
                return switch (c.ts.kind(r)) {
                    .any, .err => types.any_type,
                    else => types.unknown_type,
                };
            },
            .number_literal, .number_literal_fresh => {
                // A concrete numeric index into a tuple selects that element
                // (matching tsc) — this is also what makes a homomorphic map
                // over a tuple preserve per-element types.
                if (c.ts.kind(r) == .tuple) {
                    const v = c.ts.numberValue(idx);
                    if (v == @floor(v) and v >= 0) {
                        const i: u32 = @intFromFloat(v);
                        if (i < c.ts.tupleLen(r)) {
                            const e = c.ts.tupleElem(r, i);
                            return if (e.rest()) c.elemOfArrayish(e.ty) else e.ty;
                        }
                    }
                }
                return c.numberIndexType(r);
            },
            .number => return c.numberIndexType(r),
            .string => {
                if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0) {
                    return c.ts.objectStringIndex(r);
                }
                return types.any_type;
            },
            else => return types.any_type,
        }
    }

    fn numberIndexType(c: *Checker, r: TypeId) Error!TypeId {
        switch (c.ts.kind(r)) {
            .array => return c.ts.arrayElem(r),
            .tuple => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (0..c.ts.tupleLen(r)) |i| {
                    const e = c.ts.tupleElem(r, @intCast(i));
                    const et = if (e.rest()) c.elemOfArrayish(e.ty) else e.ty;
                    try parts.append(c.scratch(), et);
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            .object => {
                if (c.ts.objectNumberIndex(r) != 0) return c.ts.objectNumberIndex(r);
                if (c.ts.objectStringIndex(r) != 0) return c.ts.objectStringIndex(r);
                return types.any_type;
            },
            .string => return types.string_type,
            else => return types.any_type,
        }
    }

    fn elemOfArrayish(c: *Checker, t: TypeId) TypeId {
        return if (c.ts.kind(t) == .array) c.ts.arrayElem(t) else types.any_type;
    }

    /// Copy union members to scratch: slices into the type store dangle
    /// as soon as a new type is interned (extra array may grow).
    fn memberList(c: *Checker, t: TypeId) Error![]const TypeId {
        return c.scratch().dupe(TypeId, c.ts.members(t));
    }

    fn refArgsList(c: *Checker, t: TypeId) Error![]const TypeId {
        return c.scratch().dupe(TypeId, c.ts.refArgs(t));
    }

    fn makeUnion2(c: *Checker, a: TypeId, b: TypeId) Error!TypeId {
        return c.ts.makeUnion(c.scratch(), &.{ a, b });
    }

    /// tsc's `getUnionType([left, right], UnionReduction.Subtype)` — the union
    /// reduction it applies to the `&&` / `||` / `??` result. Build the union,
    /// then drop any member that is a subtype of another member, so
    /// `Item[] | never[]` (and ztsc's `[] : any[]` fallback branch) collapses
    /// into the concrete `Item[]` instead of leaving a two-array union that
    /// later mis-reports `.map(...)` as not callable (TS2349).
    fn logicalUnion(c: *Checker, a: TypeId, b: TypeId) Error!TypeId {
        const u = try c.ts.makeUnion(c.scratch(), &.{ a, b });
        return c.reduceSubtypes(u);
    }

    /// Remove union members that are subtypes of another member. Mutually
    /// assignable members (e.g. `any[]` vs `Item[]`) collapse to exactly one
    /// (the first kept). tsc guard mirrored from `strictSubtypeRelation`: an
    /// *empty anonymous object type* (`{}` — the `?? {}` / `|| {}` fallback)
    /// never absorbs another member — `T | {}` must not collapse to `{}` —
    /// while `{}` itself is still absorbed by a member it's assignable to
    /// (e.g. `{ [k: string]: any } | {}` -> the indexed type, matching tsc).
    /// Order-invariant: members are already TypeId-sorted by `makeUnion`, and
    /// the kept set is a deterministic function of that order.
    fn reduceSubtypes(c: *Checker, t: TypeId) Error!TypeId {
        if (c.ts.kind(t) != .union_type) return t;
        const members = try c.memberList(t);
        // Guard cost: `||`/`??` unions are tiny; skip pathological ones
        // (leaving the union untouched is always sound — never a new FP).
        if (members.len < 2 or members.len > 32) return t;
        var kept: std.ArrayList(TypeId) = .empty;
        defer kept.deinit(c.scratch());
        outer: for (members, 0..) |m, i| {
            const m_empty = c.isEmptyAnonObject(m);
            for (members, 0..) |o, j| {
                if (i == j) continue;
                if (c.isEmptyAnonObject(o)) continue; // `{}` never absorbs
                if (!try c.isAssignable(m, o)) continue; // m not a subtype of o
                if (!m_empty and try c.isAssignable(o, m)) {
                    // Mutually assignable: keep m only if its twin isn't kept.
                    for (kept.items) |k| if (k == o) continue :outer;
                } else {
                    // Strict subtype (or the `{}` member itself): m is redundant.
                    continue :outer;
                }
            }
            try kept.append(c.scratch(), m);
        }
        if (kept.items.len == members.len) return t;
        return c.ts.makeUnion(c.scratch(), kept.items);
    }

    /// tsc's `isEmptyAnonymousObjectType`: a structural object type with no
    /// properties, no call/construct signatures, and no index signatures.
    /// Named refs are not resolved — only literal `{}` shapes qualify (the
    /// `|| {}` / `?? {}` fallback), matching tsc's Anonymous-flag check.
    fn isEmptyAnonObject(c: *Checker, t: TypeId) bool {
        const s = &c.ts;
        if (s.kind(t) != .object) return false;
        return s.objectPropCount(t) == 0 and
            s.objectStringIndex(t) == 0 and s.objectNumberIndex(t) == 0 and
            s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0;
    }

    /// `string | number | symbol` — the apparent constraint of a deferred
    /// `keyof T` (M16d) and TS's `PropertyKey`.
    fn propertyKeyType(c: *Checker) Error!TypeId {
        return c.ts.makeUnion(c.scratch(), &.{ types.string_type, types.number_type, types.symbol_type });
    }

    /// Object type from interface/object-literal-type member nodes.
    fn objectTypeFromMembers(c: *Checker, member_nodes: []const Node, obj_flags: u32) Error!TypeId {
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
        defer prop_index.deinit(c.scratch());
        var sindex: TypeId = 0;
        var nindex: TypeId = 0;
        // Method overload grouping: name -> sig list.
        var methods: std.AutoHashMapUnmanaged(Atom, std.ArrayList(TypeId)) = .empty;
        defer {
            var it = methods.valueIterator();
            while (it.next()) |l| l.deinit(c.scratch());
            methods.deinit(c.scratch());
        }
        var order: std.ArrayList(Atom) = .empty;
        defer order.deinit(c.scratch());
        // Method names declared optional (`m?(): T`) — tsc marks the resulting
        // property optional (e.g. `PropertyDescriptor.get?`/`set?`).
        var optional_methods: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer optional_methods.deinit(c.scratch());
        // Call / construct signature lists (M18.1), kept in declaration order.
        var call_sigs: std.ArrayList(TypeId) = .empty;
        defer call_sigs.deinit(c.scratch());
        var construct_sigs: std.ArrayList(TypeId) = .empty;
        defer construct_sigs.deinit(c.scratch());
        // Accessor keys, to type a get/set pair as one property and mark a
        // get-only accessor read-only.
        var getter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer getter_keys.deinit(c.scratch());
        var setter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer setter_keys.deinit(c.scratch());

        for (member_nodes) |m| {
            if (m == null_node) continue;
            const md = c.tree.nodeData(m);
            switch (c.nodeTag(m)) {
                .property_signature => {
                    const name = try c.memberKey(c.tree.nodeMainToken(m), md.rhs);
                    var flags: u32 = 0;
                    if (md.rhs & ast.Flags.optional != 0) flags |= types.prop_flag_optional;
                    if (md.rhs & ast.Flags.readonly != 0) flags |= types.prop_flag_readonly;
                    const ty = if (md.lhs != 0)
                        try c.annTypeMaybeUnique(md.lhs, md.rhs & ast.Flags.readonly != 0, 1330, c.tokSpan(c.tree.nodeMainToken(m)))
                    else
                        types.any_type;
                    try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = ty, .flags = flags });
                },
                .method_signature => {
                    const name = try c.memberKey(c.tree.nodeMainToken(m), md.rhs);
                    // `get x(): T` / `set x(v: T)` accessor signatures: the
                    // property type is the getter return (or setter param).
                    const is_get = md.rhs & ast.Flags.get != 0;
                    const is_set = md.rhs & ast.Flags.set != 0;
                    if (is_get or is_set) {
                        const sig = try c.signatureOfProto(m, md.lhs, true, false);
                        if (is_get) {
                            try getter_keys.put(c.scratch(), name, {});
                            const gt = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.any_type;
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = gt, .flags = 0 });
                        } else {
                            try setter_keys.put(c.scratch(), name, {});
                            if (!getter_keys.contains(name)) {
                                const st = if (c.ts.kind(sig) == .function and c.ts.fnParamCount(sig) > 0)
                                    c.ts.fnParam(sig, 0).ty
                                else
                                    types.any_type;
                                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = st, .flags = 0 });
                            }
                        }
                        continue;
                    }
                    const sig = try c.signatureOfProto(m, md.lhs, true, true);
                    if (md.rhs & ast.Flags.optional != 0) try optional_methods.put(c.scratch(), name, {});
                    const gop = try methods.getOrPut(c.scratch(), name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                        try order.append(c.scratch(), name);
                    }
                    try gop.value_ptr.append(c.scratch(), sig);
                },
                .index_signature => {
                    const e = c.tree.extraData(ast.IndexSig, md.lhs);
                    const key = try c.typeFromTypeNode(e.key_type);
                    const val = try c.typeFromTypeNode(e.value_type);
                    if (key == types.number_type) nindex = val else sindex = val;
                },
                // Call / construct signatures (M18.1). Compared like function
                // types (not methods), so params are contravariant.
                .call_signature => {
                    try call_sigs.append(c.scratch(), try c.signatureOfProto(m, md.lhs, false, true));
                },
                .construct_signature => {
                    try construct_sigs.append(c.scratch(), try c.signatureOfProto(m, md.lhs, false, true));
                },
                else => {},
            }
        }
        for (order.items) |name| {
            const sigs = methods.get(name).?;
            const ty = try c.ts.makeOverloads(sigs.items);
            const mflags: u32 = if (optional_methods.contains(name)) types.prop_flag_optional else 0;
            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = ty, .flags = mflags });
        }
        // Get-only accessors are read-only properties.
        var git = getter_keys.keyIterator();
        while (git.next()) |k| {
            if (setter_keys.contains(k.*)) continue;
            if (prop_index.get(k.*)) |idx| props.items[idx].flags |= types.prop_flag_readonly;
        }
        return c.ts.makeObjectSigs(props.items, sindex, nindex, obj_flags, call_sigs.items, construct_sigs.items);
    }

    /// Append `p`, replacing any existing prop with the same name. `index`
    /// maps name atom -> slot in `props` so accumulation is O(1) amortized
    /// instead of a linear rescan per insert (O(P^2) for large interfaces).
    fn upsertProp(
        alloc: Allocator,
        props: *std.ArrayList(types.Prop),
        index: *std.AutoHashMapUnmanaged(Atom, u32),
        p: types.Prop,
    ) Error!void {
        const gop = try index.getOrPut(alloc, p.name);
        if (gop.found_existing) {
            props.items[gop.value_ptr.*] = p;
            return;
        }
        gop.value_ptr.* = @intCast(props.items.len);
        try props.append(alloc, p);
    }

    /// Fold the properties of a spread source (`{ ...src }`) into an object
    /// literal's property set. An intersection source contributes the props of
    /// every constituent (a later constituent wins on a name clash, mirroring
    /// tsc's spread over `A & B`); without this, spreading a value of an
    /// intersection type produced an empty `{}` (the object-only guard skipped
    /// it), which then failed assignment to the very type it was spread from.
    fn gatherSpreadProps(
        c: *Checker,
        st: TypeId,
        props: *std.ArrayList(types.Prop),
        prop_index: *std.AutoHashMapUnmanaged(Atom, u32),
        str_index_vals: *std.ArrayList(TypeId),
        num_index_vals: *std.ArrayList(TypeId),
    ) Error!void {
        switch (c.ts.kind(st)) {
            .object => {
                // tsc's `getSpreadType` carries the source's index signatures
                // into the result, so `{ ...src }` of `{ [k: string]: any }`
                // keeps the string index (`updated.arr` stays `any`, not a
                // missing-property TS2551/2339).
                if (c.ts.objectStringIndex(st) != 0) try str_index_vals.append(c.scratch(), c.ts.objectStringIndex(st));
                if (c.ts.objectNumberIndex(st) != 0) try num_index_vals.append(c.scratch(), c.ts.objectNumberIndex(st));
                for (0..c.ts.objectPropCount(st)) |i| {
                    const p = c.ts.objectProp(st, @intCast(i));
                    // tsc's `getSpreadType`: when a property is present in both
                    // the accumulated left (`{ a, b, ... }`) and this spread and
                    // the spread's property is OPTIONAL, the result keeps the
                    // LEFT's optionality and unions the value types. So an
                    // explicit required prop stays required even when a later
                    // `Partial<…>` spread re-supplies it optionally — without
                    // this, every prop of `{ id, active, ...overrides }` (with
                    // `overrides: Partial<X>`) became optional and failed
                    // assignment to the required target (TS2322 factory FPs).
                    if (p.flags & types.prop_flag_optional != 0) {
                        if (prop_index.get(p.name)) |idx| {
                            props.items[idx].ty = try c.logicalUnion(props.items[idx].ty, try c.removeUndefined(p.ty));
                            continue;
                        }
                    }
                    try upsertProp(c.scratch(), props, prop_index, .{ .name = p.name, .ty = p.ty, .flags = p.flags & types.prop_flag_optional });
                }
            },
            .intersection => {
                for (try c.memberList(st)) |m| {
                    try c.gatherSpreadProps(try c.resolveStructural(m), props, prop_index, str_index_vals, num_index_vals);
                }
            },
            else => {},
        }
    }

    // =====================================================================
    // signatures
    // =====================================================================

    /// Build the signature type for a FnProto (function decl/expr, arrow,
    /// method, function type). `report_implicit` controls TS7006.
    /// `ctx_sig` supplies contextual parameter types (arrow inference).
    fn signatureOfProto(c: *Checker, node: Node, proto_idx: u32, is_method: bool, report_implicit: bool) Error!TypeId {
        return c.signatureOfProtoCtx(node, proto_idx, is_method, report_implicit, types.no_type);
    }

    fn signatureOfProtoCtx(
        c: *Checker,
        node: Node,
        proto_idx: u32,
        is_method: bool,
        report_implicit: bool,
        ctx_sig: TypeId,
    ) Error!TypeId {
        if (c.sig_cache.get(c.nodeKey(node))) |cached| {
            if (cached.ctx == ctx_sig) return cached.ty;
        }
        const proto = c.tree.extraData(ast.FnProto, proto_idx);
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        if (try c.scopeOf(node)) |s| c.cur_scope = s;

        // Type parameters (global symbol ids in the signature type).
        var tps: std.ArrayList(u32) = .empty;
        defer tps.deinit(c.scratch());
        // A signature's own type parameter shadows an enclosing mapped-type key
        // of the same name (tsc lexical scoping): while materializing this
        // sig's params/return, a bare `K` that names an own type param must
        // resolve to that param, not the outer mapped key. Without this, a
        // generic method declared inside a mapped-type value branch (e.g.
        // `addEventListener<K extends keyof ElementEventMap>` materialized while
        // some `{[K in …]: …}` is being expanded) has its own `K` mis-bound to a
        // `mapped_param`, which `containsTypeParam` misses — so `eraseTypeParams`
        // silently no-ops and the sig never relates (order-dependent, since it
        // only triggers when the mapped key happens to be in scope at
        // materialization time). Cleared for the whole body via defer.
        const saved_mkey_name = c.cur_mapped_key_name;
        const saved_mkey_ty = c.cur_mapped_key_ty;
        defer {
            c.cur_mapped_key_name = saved_mkey_name;
            c.cur_mapped_key_ty = saved_mkey_ty;
        }
        for (c.tree.extraRange(proto.tp_start, proto.tp_end)) |tp| {
            if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
            const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
            if (c.cur_mapped_key_name != 0 and c.cur_mapped_key_name == a) {
                c.cur_mapped_key_name = 0;
                c.cur_mapped_key_ty = 0;
            }
            if (c.bind.lookupInScope(c.cur_scope, a)) |tp_sym| {
                try tps.append(c.scratch(), c.toGlobal(tp_sym));
            }
            // Evaluate constraints eagerly so their diagnostics are
            // partition-independent (owners always see them).
            const td = c.tree.nodeData(tp);
            if (td.lhs != 0) _ = try c.typeFromTypeNode(td.lhs);
        }

        var params: std.ArrayList(types.Param) = .empty;
        defer params.deinit(c.scratch());
        const param_nodes = c.tree.extraRange(proto.params_start, proto.params_end);
        var pi: u32 = 0;
        // A leading `this` parameter is a receiver *annotation*, not a real
        // parameter: excluded from the param list (so it never counts toward
        // arity) and stored on the signature for the receiver check / body.
        var this_ty: TypeId = 0;
        var seen_param = false;
        for (param_nodes) |pn| {
            if (pn == null_node) continue;
            if (!seen_param) {
                seen_param = true;
                if (c.thisParamAnn(pn)) |ann_node| {
                    this_ty = if (ann_node != 0) try c.typeFromTypeNode(ann_node) else types.any_type;
                    if (this_ty == types.no_type) this_ty = types.any_type;
                    continue;
                }
            }
            const p = try c.paramInfo(pn, pi, ctx_sig, report_implicit);
            try params.append(c.scratch(), p);
            // Pin the parameter symbol's type so body checking sees the
            // contextual/inferred type (not a re-derivation without ctx). When a
            // contextual signature is supplied (`ctx_sig`), FORCE-overwrite any
            // previously-pinned value: the same arrow is materialized once per
            // overload candidate during resolution (`argumentsMatch` trials), and
            // `setTypeOfSymbol` is first-writer-wins — so a rejected candidate's
            // param types (e.g. reduce's non-generic `(prev:T,cur:T)=>T` pinning
            // `acc:T`) would otherwise freeze and block the SELECTED overload's
            // correct `acc:U` types. The last materialization is the one the body
            // is actually checked under, so it must win.
            if (p.name != 0) {
                if (c.bind.lookupInScope(c.cur_scope, p.name)) |psym| {
                    if (c.bind.symbol_flags[psym].param) {
                        const gsym = c.toGlobal(psym);
                        if (ctx_sig != types.no_type and gsym != binder.no_symbol and gsym < c.sym_types.items.len) {
                            c.sym_types.items[gsym] = p.ty;
                            c.sym_state.items[gsym] = .computed;
                        } else {
                            c.setTypeOfSymbol(gsym, p.ty);
                        }
                    }
                }
            }
            pi += 1;
        }

        const is_async = proto.flags & ast.Flags.async != 0;
        const is_generator = proto.flags & ast.Flags.generator != 0;
        // Contextual return type: the return of the contextual signature this
        // arrow/function expression is checked against (annotation, argument, or
        // property position). Threaded into the body's return-type probe so
        // return expressions are contextually typed. An async body's returns are
        // typed by the *awaited* contextual type (`Promise<T>` context → `T`).
        const ret_ctx: TypeId = if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function)
            c.ts.fnReturn(ctx_sig)
        else
            types.no_type;
        var ret: TypeId = types.any_type;
        var pred: ?types.Predicate = null;
        if (proto.return_type != 0 and c.nodeTag(proto.return_type) == .type_predicate) {
            // `x is T` / `asserts x[ is T]`: a plain guard returns boolean;
            // an assertion function returns void (no value required, so no
            // TS2355). The predicate rides along for call-site narrowing.
            const p = try c.predicateFromNode(proto.return_type, params.items);
            pred = p;
            ret = if (p.asserts) types.void_type else types.boolean_type;
        } else if (proto.return_type != 0 and c.nodeTag(proto.return_type) == .this_expr and
            is_method and c.ts.kind(c.this_type) == .ref)
        {
            // Polymorphic `this` return (`foo(): this`). Kept as a marker so a
            // call through a subclass receiver types as the subclass.
            ret = try c.ts.makeThisType(c.this_type);
            c.has_this_types = true;
        } else if (proto.return_type != 0) {
            ret = try c.typeFromTypeNode(proto.return_type);
        } else if (is_async and !is_generator) {
            // async without annotation → infer the payload from the body
            // (flattening a single returned `Promise` level), wrap in the
            // global `Promise<T>`. `async g() {}` → `Promise<void>`.
            if (node != 0 and c.tree.nodeData(node).rhs != 0 and
                (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr or
                    c.nodeTag(node) == .function_decl or c.nodeTag(node) == .class_method))
            {
                try c.sig_cache.put(c.ca(), c.nodeKey(node), .{ .ty = try c.ts.makeFunction(params.items, try c.makePromise(types.any_type), tps.items, if (is_method) types.fn_flag_method else 0), .ctx = ctx_sig });
                const payload = try c.awaitedType(try c.inferReturnType(node, c.tree.nodeData(node).rhs, if (ret_ctx != types.no_type) try c.awaitedType(ret_ctx) else types.no_type));
                ret = try c.makePromise(payload);
            } else {
                ret = try c.makePromise(types.void_type);
            }
        } else if (is_generator) {
            // Generator return-type inference (yield union → `Generator<T>`) is
            // a gap: unannotated generators type as `any` (no false positives).
            ret = types.any_type;
        } else if (node != 0 and c.tree.nodeData(node).rhs != 0 and
            (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr or
                c.nodeTag(node) == .function_decl or c.nodeTag(node) == .class_method))
        {
            // Reserve the cache slot to break recursion (self-recursive
            // unannotated functions infer any, TS7023-adjacent).
            try c.sig_cache.put(c.ca(), c.nodeKey(node), .{ .ty = try c.ts.makeFunction(params.items, types.any_type, tps.items, if (is_method) types.fn_flag_method else 0), .ctx = ctx_sig });
            ret = try c.inferReturnType(node, c.tree.nodeData(node).rhs, ret_ctx);
        } else if (proto.flags & (ast.Flags.get) != 0) {
            ret = types.any_type;
        } else if (c.tree.nodeData(node).rhs == 0 and c.nodeTag(node) != .function_type and c.nodeTag(node) != .method_signature) {
            ret = types.any_type; // overload signature without annotation
        }

        // TS 5.5 inferred type predicate: a boolean-returning single-param
        // callback whose body narrows that param synthesizes an implicit
        // `x is T` guard, so `arr.filter(x => x !== null)` picks the
        // `filter<S extends T>(…): S[]` overload. Only when no explicit
        // predicate was written and the param has a real (contextual) type.
        if (pred == null and tps.items.len == 0 and
            (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr))
        {
            pred = try c.inferredPredicate(params.items, ret, c.tree.nodeData(node).rhs);
        }

        const sig = try c.ts.makeFunctionThis(params.items, ret, tps.items, if (is_method) types.fn_flag_method else 0, pred, this_ty);
        try c.sig_cache.put(c.ca(), c.nodeKey(node), .{ .ty = sig, .ctx = ctx_sig });
        return sig;
    }

    /// TS 5.5 inferred type predicate. Returns an implicit `x is T` guard for a
    /// boolean-returning single-parameter arrow/function whose body narrows
    /// that parameter, or null (the old under-reporting behavior) when the
    /// shape is anything we are not certain about. Conservative on purpose:
    /// only equality / `typeof` / `instanceof` / `in` guards (optionally under
    /// `!`), gated by tsc's own soundness rule — the true-branch narrowing
    /// must differ from the declared type AND the false branch must exclude the
    /// narrowed type entirely. That gate rejects truthiness (`!!x`, `x => !!x`)
    /// exactly as tsc does: the falsy branch of `number | null` keeps `number`.
    fn inferredPredicate(c: *Checker, params: []const types.Param, ret: TypeId, body: Node) Error!?types.Predicate {
        if (body == null_node) return null;
        switch (c.ts.kind(ret)) {
            .boolean, .bool_true, .bool_false => {},
            else => return null,
        }
        if (params.len == 0) return null;

        // The single guard expression: an expression body, or a block whose
        // only statement is `return <expr>`.
        var guard = body;
        if (c.nodeTag(body) == .block) {
            var expr: Node = null_node;
            var count: usize = 0;
            for (c.tree.nodeRange(body)) |st| {
                if (st == null_node) continue;
                count += 1;
                if (c.nodeTag(st) == .return_stmt and c.tree.nodeData(st).lhs != 0) {
                    expr = c.tree.nodeData(st).lhs;
                } else return null;
            }
            if (count != 1 or expr == null_node) return null;
            guard = expr;
        }

        // Unwrap parens and leading `!` (each `!` flips the narrowing sense).
        var sense = true;
        unwrap: while (guard != null_node) {
            switch (c.nodeTag(guard)) {
                .paren_expr => guard = c.tree.nodeData(guard).lhs,
                .prefix_unary => {
                    if (c.tree.tokens.tag(c.tree.nodeMainToken(guard)) != .bang) break :unwrap;
                    sense = !sense;
                    guard = c.tree.nodeData(guard).lhs;
                },
                else => break :unwrap,
            }
        }
        if (guard == null_node) return null;
        // Only shapes `narrowByGuardExpr`/`narrowByCondition` handle soundly
        // (a bare identifier is allowed so truthiness reaches — and is
        // rejected by — the gate; calls reach `narrowByGuardCall`, i.e. a
        // callback that merely wraps a user-defined guard).
        switch (c.nodeTag(guard)) {
            .binary, .identifier, .member_expr, .optional_member_expr => {},
            .call_expr, .call_expr_targs, .optional_call => {},
            else => return null,
        }

        // tsc 5.5 narrows one parameter of a possibly multi-parameter callback
        // (`arr.filter((x, i) => x !== null)` guards `x`; `i` is untouched).
        // Try each parameter; synthesize only when *exactly one* passes the
        // gate — an ambiguous guard (two params both narrowed) has no clear
        // oracle semantics, so it keeps the old (no-predicate) behavior.
        var found: ?types.Predicate = null;
        for (params, 0..) |p, pi| {
            if (p.name == 0) continue;
            const declared = p.ty;
            if (!c.isNarrowable(declared)) continue;
            // The guarded parameter's symbol, resolved exactly as `identIsSym`
            // will resolve the references inside the body.
            const psym: SymbolId = switch (c.resolveSpace(p.name, c.cur_scope, true)) {
                .sym => |s| s,
                else => continue,
            };
            const key = RefKey{ .sym = psym };
            const true_ty = try c.narrowByGuardExpr(declared, guard, sense, key, 0);
            if (true_ty == declared or c.ts.kind(true_ty) == .never) continue;
            const false_ty = try c.narrowByGuardExpr(declared, guard, !sense, key, 0);
            // Soundness: the false branch must fully exclude the narrowed type.
            if (try c.typesOverlap(true_ty, false_ty)) continue;
            if (found != null) return null; // ambiguous: two params narrowed
            found = types.Predicate{ .param = @intCast(pi), .ty = true_ty, .asserts = false };
        }
        return found;
    }

    /// Narrow `t` by a *guard expression* for inferred-predicate synthesis
    /// only. Unlike flow narrowing (where the binder decomposes `&&`/`||`/`!`
    /// into branch conditions), the whole callback body is one expression
    /// here, so the logical operators are recursed structurally with the
    /// exact branch semantics tsc's flow analysis produces:
    ///   true(A && B)  = true(B) over true(A)
    ///   false(A && B) = false(A) | false(B) over true(A)
    /// (and the De Morgan dual for `||`). Leaves delegate to
    /// `narrowByCondition`; unhandled shapes return `t`, which the caller's
    /// `true_ty == declared` gate then rejects (no predicate — old behavior).
    fn narrowByGuardExpr(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey, depth: u32) Error!TypeId {
        if (cond == null_node or depth > 8) return t;
        const d = c.tree.nodeData(cond);
        switch (c.nodeTag(cond)) {
            .paren_expr => return c.narrowByGuardExpr(t, d.lhs, sense, key, depth + 1),
            .prefix_unary => {
                if (c.tree.tokens.tag(c.tree.nodeMainToken(cond)) != .bang)
                    return t;
                return c.narrowByGuardExpr(t, d.lhs, !sense, key, depth + 1);
            },
            .binary => switch (c.tree.tokens.tag(c.tree.nodeMainToken(cond))) {
                .amp_amp => {
                    const a_true = try c.narrowByGuardExpr(t, d.lhs, true, key, depth + 1);
                    if (sense) return c.narrowByGuardExpr(a_true, d.rhs, true, key, depth + 1);
                    const a_false = try c.narrowByGuardExpr(t, d.lhs, false, key, depth + 1);
                    const b_false = try c.narrowByGuardExpr(a_true, d.rhs, false, key, depth + 1);
                    return c.makeUnion2(a_false, b_false);
                },
                .pipe_pipe => {
                    const a_false = try c.narrowByGuardExpr(t, d.lhs, false, key, depth + 1);
                    if (!sense) return c.narrowByGuardExpr(a_false, d.rhs, false, key, depth + 1);
                    const a_true = try c.narrowByGuardExpr(t, d.lhs, true, key, depth + 1);
                    const b_true = try c.narrowByGuardExpr(a_false, d.rhs, true, key, depth + 1);
                    return c.makeUnion2(a_true, b_true);
                },
                else => return c.narrowByCondition(t, cond, sense, key),
            },
            else => return c.narrowByCondition(t, cond, sense, key),
        }
    }

    /// True when some constituent of `a` is assignable into `b` (a non-empty
    /// overlap). Used to reject an inferred predicate whose true and false
    /// branches are not disjoint.
    fn typesOverlap(c: *Checker, a: TypeId, b: TypeId) Error!bool {
        if (c.ts.kind(a) == .union_type) {
            for (try c.memberList(a)) |m| {
                if (try c.isAssignable(m, b)) return true;
            }
            return false;
        }
        return c.isAssignable(a, b);
    }

    /// If `pn` is a leading `this` parameter (`this: T`), return its type
    /// annotation node (0 when unannotated); otherwise null.
    fn thisParamAnn(c: *Checker, pn: Node) ?Node {
        const d = c.tree.nodeData(pn);
        const name_node: Node = switch (c.nodeTag(pn)) {
            .param, .param_full => d.lhs,
            else => pn,
        };
        if (name_node == 0 or c.nodeTag(name_node) != .this_expr) return null;
        return switch (c.nodeTag(pn)) {
            .param => d.rhs,
            .param_full => c.tree.extraData(ast.ParamFull, d.rhs).type_ann,
            else => 0,
        };
    }

    /// Resolve a `.type_predicate` return-type node into a `Predicate`:
    /// map the guarded name to a parameter index and evaluate the target
    /// type. `this is T` uses the `this_param` sentinel.
    fn predicateFromNode(c: *Checker, node: Node, params: []const types.Param) Error!types.Predicate {
        const d = c.tree.nodeData(node);
        const asserts = d.rhs != 0;
        const target: TypeId = if (d.lhs != 0) try c.typeFromTypeNode(d.lhs) else types.no_type;
        const name_tok = c.tree.nodeMainToken(node);
        var param: u32 = types.Predicate.this_param;
        if (c.tree.tokens.tag(name_tok) != .keyword_this) {
            const a = try c.atomOfToken(name_tok);
            for (params, 0..) |p, i| {
                if (p.name == a) {
                    param = @intCast(i);
                    break;
                }
            }
        }
        return .{ .param = param, .ty = target, .asserts = asserts };
    }

    fn paramInfo(c: *Checker, pn: Node, index: u32, ctx_sig: TypeId, report_implicit: bool) Error!types.Param {
        const d = c.tree.nodeData(pn);
        var name_node: Node = 0;
        var type_ann: Node = 0;
        var init_node: Node = 0;
        var flags_word: u32 = 0;
        switch (c.nodeTag(pn)) {
            .param => {
                name_node = d.lhs;
                type_ann = d.rhs;
            },
            .param_full => {
                const e = c.tree.extraData(ast.ParamFull, d.rhs);
                name_node = d.lhs;
                type_ann = e.type_ann;
                init_node = e.init;
                flags_word = e.flags;
            },
            else => {
                name_node = pn;
            },
        }
        var flags: u32 = 0;
        if (flags_word & ast.Flags.optional != 0) flags |= types.param_flag_optional;
        if (flags_word & ast.Flags.rest != 0) flags |= types.param_flag_rest;
        if (init_node != 0) flags |= types.param_flag_initializer;

        const name: Atom = if (name_node != 0 and c.nodeTag(name_node) == .identifier)
            try c.atomOfToken(c.tree.nodeMainToken(name_node))
        else
            0;

        var ty: TypeId = types.no_type;
        if (type_ann != 0) {
            ty = try c.typeFromTypeNode(type_ann);
        } else if (init_node != 0) {
            ty = try c.widenLiteral(try c.checkExprCached(init_node, types.no_type));
        } else if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function) {
            if (c.paramTypeAt(ctx_sig, index)) |ct| ty = ct;
        }
        if (ty == types.no_type) {
            // `noImplicitAny: false` suppresses TS7006 — the parameter still
            // types as `any` below, only the diagnostic is gone.
            if (report_implicit and name != 0 and c.prog.no_implicit_any) {
                const tok = c.tree.nodeMainToken(name_node);
                try c.diagFmt(7006, c.tokSpan(tok), "Parameter '{s}' implicitly has an 'any' type.", .{c.tokenText(tok)});
            }
            ty = types.any_type;
        }
        // `x?: T` reads as T | undefined.
        if (flags & types.param_flag_optional != 0) {
            ty = try c.makeUnion2(ty, types.undefined_type);
        }
        return .{ .name = name, .ty = ty, .flags = flags };
    }

    /// Union of return expression types (widened), plus undefined when the
    /// body can complete normally alongside value returns.
    ///
    /// `ret_ctx` is the *contextual return type* — the return type of the
    /// contextual signature this function expression/arrow is being checked
    /// against (from a variable annotation, argument position, or property
    /// position). When present it becomes the contextual type of every return
    /// expression, so object literals keep the literal discriminants the
    /// context expects (`{ type: 'Polygon' }` under `() => Polygon` keeps
    /// `type: "Polygon"` instead of widening to `string`), unions distribute,
    /// and nested arrows inherit both param and return context via
    /// `checkExprCached` → `checkFunctionLikeExpr`. With no context it is
    /// `types.no_type`, and normal widening applies (tsc's
    /// isLiteralOfContextualType).
    fn inferReturnType(c: *Checker, fn_node: Node, body: Node, ret_ctx: TypeId) Error!TypeId {
        if (body == 0) return types.any_type;
        // Establish *this* function's async/generator context while checking
        // its body: `await`/`yield` legality (TS1308/TS1163…) must be judged
        // against the function being inferred, not the enclosing one. Without
        // this, an `await` in an async arrow probed for its return type is
        // checked under the outer (possibly non-async) `fn_ctx`, emitting a
        // TS1308 false positive that then caches — and whether this probe or
        // the full `checkFunctionBody` reaches the node first is cache-order
        // dependent, so the error moved across files with --workers/--checkers.
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fn_node).lhs);
        const saved_ctx = c.fn_ctx;
        defer c.fn_ctx = saved_ctx;
        c.fn_ctx = .{
            .ret_ann = types.no_type,
            .is_async = proto.flags & ast.Flags.async != 0,
            .is_generator = proto.flags & ast.Flags.generator != 0,
            .yield_type = 0,
        };
        if (c.nodeTag(body) != .block) {
            return c.widenToContext(try c.checkExprCached(body, ret_ctx), ret_ctx);
        }
        var rets: std.ArrayList(Node) = .empty;
        defer rets.deinit(c.scratch());
        var ret_scopes: std.ArrayList(ScopeId) = .empty;
        defer ret_scopes.deinit(c.scratch());
        var bare_return = false;
        // Base scope for the body: a function/arrow body block binds its
        // statements directly in the function scope (no separate block scope),
        // so start from the function's own scope.
        const base_scope = (try c.scopeOf(fn_node)) orelse c.cur_scope;
        for (c.tree.nodeRange(body)) |stmt| {
            if (stmt != null_node) try c.collectReturns(stmt, &rets, &ret_scopes, &bare_return, base_scope);
        }
        if (rets.items.len == 0) return types.void_type;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        // Each return expression is resolved in the scope where its `return`
        // statement lives (a return inside a try/if/loop block sees that
        // block's locals), not the ambient scope of this type probe.
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        for (rets.items, ret_scopes.items) |r, sc| {
            c.cur_scope = sc;
            try parts.append(c.scratch(), try c.widenToContext(try c.checkExprCached(r, ret_ctx), ret_ctx));
        }
        if (bare_return or !c.stmtListTerminal(c.tree.nodeRange(body))) {
            try parts.append(c.scratch(), types.undefined_type);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    fn collectReturns(c: *Checker, node: Node, out: *std.ArrayList(Node), out_scopes: ?*std.ArrayList(ScopeId), bare: *bool, scope: ScopeId) Error!void {
        if (node == null_node) return;
        switch (c.nodeTag(node)) {
            .return_stmt => {
                const d = c.tree.nodeData(node);
                if (d.lhs != 0) {
                    try out.append(c.scratch(), d.lhs);
                    if (out_scopes) |os| try os.append(c.scratch(), scope);
                } else bare.* = true;
                return;
            },
            // Don't descend into nested functions/classes.
            .arrow_fn, .function_expr, .function_decl, .class_decl, .class_method => return,
            else => {},
        }
        // A return nested in a block/try/loop/switch resolves its expression in
        // that construct's scope; track it as we descend.
        const inner = (try c.scopeOf(node)) orelse scope;
        var it = c.tree.childIterator(node);
        while (it.next()) |child| try c.collectReturns(child, out, out_scopes, bare, inner);
    }

    // =====================================================================
    // symbol typing
    // =====================================================================

    fn typeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
        if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return types.any_type;
        if (c.sym_state.items[sym] == .computed) return c.sym_types.items[sym];
        if (c.sym_state.items[sym] == .in_progress) return types.any_type; // circular
        c.sym_state.items[sym] = .in_progress;
        const t = c.computeTypeOfSymbol(sym) catch |err| {
            c.sym_state.items[sym] = .not_computed;
            return err;
        };
        c.sym_types.items[sym] = t;
        c.sym_state.items[sym] = .computed;
        return t;
    }

    fn setTypeOfSymbol(c: *Checker, sym: SymbolId, t: TypeId) void {
        if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return;
        if (c.sym_state.items[sym] == .computed) return;
        c.sym_types.items[sym] = t;
        c.sym_state.items[sym] = .computed;
    }

    fn computeTypeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
        // A merged symbol's value type. For a merged *namespace* (M11b) the
        // value object is anchored to the merged id — `classStaticType` walks
        // the merged member index; a cross-file kind combination
        // (function/enum/class + namespace) intersects the non-namespace
        // constituent's value. Otherwise (M11a var/function) it is the first
        // value-space constituent's type. Type space is materialized via
        // `expandRef`/`interfaceGeneric`, which fold every constituent.
        if (c.prog.isMergedId(sym)) {
            const m = c.prog.mergedSym(sym);
            if (m.flags.namespace_decl) {
                var ns_val = try c.ts.makeClassValue(sym);
                // Intersect the first value-space constituent (a function/class/
                // enum callable base, *or* a `var console: Console`-style
                // variable) so a namespace merged onto a typed global keeps that
                // global's members. Without this a `var X: T` + `namespace X {…}`
                // merge drops `T` and every `X.member` is a phantom TS2339.
                // A callable base that is itself declared across lib + node
                // (`function setTimeout(): number` + node's `global{}`
                // `setTimeout(): NodeJS.Timeout`, plus `namespace setTimeout`)
                // folds every overload node-first, so `typeof setTimeout` stays
                // callable with the node return type.
                if (try c.mergedFunctionValue(m.parts)) |ft| {
                    return c.ts.makeIntersection(c.scratch(), &.{ ft, ns_val });
                }
                for (m.parts) |p| {
                    const pf = c.symFlags(p);
                    if (pf.function or pf.enum_decl or pf.class) {
                        ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.typeOfSymbol(p), ns_val });
                        break;
                    }
                    if (pf.var_decl or pf.let_decl or pf.const_decl) {
                        ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.variableSymbolType(p), ns_val });
                        break;
                    }
                }
                return ns_val;
            }
            // A global function declared in more than one file (lib.dom's
            // `setInterval(): number` + @types/node's `global{}`
            // `setInterval(): NodeJS.Timeout`) merges into one overload set,
            // node's signatures first — see `mergedFunctionValue`.
            if (try c.mergedFunctionValue(m.parts)) |ft| return ft;
            for (m.parts) |p| {
                if (hasValueMeaning(c.symFlags(p))) return c.typeOfSymbol(p);
            }
            return types.any_type;
        }
        const f = c.symFlags(sym);
        if (f.import_binding) return c.importedSymbolType(sym);
        // A namespace is a value object of its exported members, modeled as a
        // `class_value` anchored to the namespace symbol (so it prints
        // `typeof N` and resolves members via classStaticType). When merged
        // with a class the class_value already carries the namespace members;
        // with a function/enum the callable/base value is intersected with
        // the namespace object.
        if (f.namespace_decl) {
            const ns_val = try c.ts.makeClassValue(sym);
            if (f.class) return ns_val;
            if (f.function) return c.ts.makeIntersection(c.scratch(), &.{ try c.functionSymbolType(sym), ns_val });
            if (f.enum_decl) return c.ts.makeIntersection(c.scratch(), &.{ try c.enumValueType(sym), ns_val });
            // Same-file `var X: T` + `namespace X {…}` (a namespace merged onto a
            // typed global within one file): keep T's members.
            if (f.var_decl or f.let_decl or f.const_decl)
                return c.ts.makeIntersection(c.scratch(), &.{ try c.variableSymbolType(sym), ns_val });
            return ns_val;
        }
        if (f.enum_decl) return c.enumValueType(sym);
        if (f.class) return c.ts.makeClassValue(sym);
        if (f.function) return c.functionSymbolType(sym);
        if (f.property or f.method or f.getter or f.setter) return c.memberTypeOf(sym);

        // The remaining cases traverse decl nodes: switch to the symbol's
        // file and declaring scope.
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(sym);

        if (f.catch_param) {
            const decls = c.declsOf(sym);
            if (decls.len > 0 and c.nodeTag(decls[0]) == .declarator_full) {
                const dd = c.tree.nodeData(decls[0]);
                const e = c.tree.extraData(ast.DeclaratorFull, dd.rhs);
                if (e.type_ann != 0) return c.typeFromTypeNode(e.type_ann);
            }
            return types.unknown_type; // useUnknownInCatchVariables (strict)
        }
        if (f.param) {
            const decls = c.declsOf(sym);
            for (decls) |decl| {
                switch (c.nodeTag(decl)) {
                    .param, .param_full => {
                        const p = try c.paramInfo(decl, 0, types.no_type, false);
                        // Pattern params: paramInfo names only identifiers;
                        // for destructured params fall through to any.
                        if (p.name != 0 and p.name == c.symNameAtom(sym)) return p.ty;
                        return c.bindingElementType(sym, decl, p.ty);
                    },
                    else => {},
                }
            }
            return types.any_type;
        }
        if (f.var_decl or f.let_decl or f.const_decl) return c.variableSymbolType(sym);
        return types.any_type;
    }

    /// Fold every callable constituent of a merged global function symbol into
    /// one overload set, non-lib declarations before lib ones. tsc binds a
    /// program's root files and their type-reference dependencies (@types)
    /// before the default library, so the @types/node `global{}` timer
    /// signatures (`setInterval(...): NodeJS.Timeout`) precede lib.dom's
    /// `number` ones and win first-match overload resolution — the same order
    /// tsc produces. Returns null when fewer than two constituents are callable
    /// (the overwhelmingly common single-contributor global keeps its type via
    /// the caller's existing first-value-constituent path).
    fn mergedFunctionValue(c: *Checker, parts: []const u32) Error!?TypeId {
        var nonlib: std.ArrayList(TypeId) = .empty;
        defer nonlib.deinit(c.scratch());
        var lib: std.ArrayList(TypeId) = .empty;
        defer lib.deinit(c.scratch());
        for (parts) |p| {
            if (!c.symFlags(p).function) continue;
            var t = try c.typeOfSymbol(p);
            // A constituent that also carries a namespace (node's `setTimeout`
            // is `function setTimeout` + `namespace setTimeout`) materializes as
            // `overloads & class_value`; unwrap the callable part so its
            // signatures still fold in.
            if (c.ts.kind(t) == .intersection) {
                for (try c.memberList(t)) |m| {
                    const rm = try c.resolveStructural(m);
                    if (c.ts.kind(rm) == .function or c.ts.kind(rm) == .overloads) {
                        t = rm;
                        break;
                    }
                }
            }
            const k = c.ts.kind(t);
            if (k != .function and k != .overloads) continue;
            if (modules.isLibPath(c.prog.files[c.symFile(p)].path))
                try lib.append(c.scratch(), t)
            else
                try nonlib.append(c.scratch(), t);
        }
        if (nonlib.items.len + lib.items.len < 2) return null;
        // When a non-lib file (@types/node's `global{}`) redeclares a lib
        // global function, tsc's effective type is the node one at BOTH the
        // call site (`setTimeout(): NodeJS.Timeout`) and through `ReturnType`
        // — node dominates end-to-end. Use the non-lib signatures alone when
        // present (dropping the shadowed lib.dom `number` overloads); fall back
        // to folding all when every constituent is a lib.
        const groups: []const *std.ArrayList(TypeId) = if (nonlib.items.len != 0)
            &.{&nonlib}
        else
            &.{&lib};
        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        for (groups) |grp| {
            for (grp.items) |o| {
                if (c.ts.kind(o) == .overloads) {
                    for (c.ts.members(o)) |mm| try sigs.append(c.scratch(), mm);
                } else try sigs.append(c.scratch(), o);
            }
        }
        if (sigs.items.len == 1) return sigs.items[0];
        return try c.ts.makeOverloads(sigs.items);
    }

    /// The last call signature (a `.function` TypeId) reachable from any
    /// callable shape: a bare function, an overload set (tsc's
    /// `inferFromSignatures` aligns from the end, so the last wins), a
    /// callable object carrying call signatures, or an intersection that wraps
    /// one (`overloads & namespaceObject`). Null when nothing is callable.
    fn lastCallSig(c: *Checker, t0: TypeId) Error!?TypeId {
        const s = &c.ts;
        const t = try c.resolveStructural(t0);
        switch (s.kind(t)) {
            .function => return t,
            .overloads => {
                const ms = try c.memberList(t);
                return if (ms.len > 0) ms[ms.len - 1] else null;
            },
            .object => {
                const n = s.objectCallSigCount(t);
                return if (n > 0) s.objectCallSig(t, n - 1) else null;
            },
            .intersection => {
                var found: ?TypeId = null;
                for (try c.memberList(t)) |m| {
                    if (try c.lastCallSig(m)) |sig| found = sig;
                }
                return found;
            },
            else => return null,
        }
    }

    /// The declared value type of a `var`/`let`/`const` symbol. Self-contained
    /// (switches to the symbol's file/scope) so it can also be called for a
    /// symbol that additionally carries a `namespace` meaning (e.g. `@types/node`
    /// declares `var console: Console` alongside `namespace console { … }`).
    fn variableSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(sym);
        const is_const = c.symFlags(sym).const_decl;
        const decls = c.declsOf(sym);
        for (decls) |decl| {
            // A symbol can merge a value declaration with a type-only one
            // (e.g. lib's `interface Object {}` + `declare var Object: {…}`).
            // Only the variable declarators carry the value type; skip the
            // type-space decls so they don't short-circuit to `any`.
            switch (c.nodeTag(decl)) {
                .declarator, .declarator_init, .declarator_full => {},
                else => continue,
            }
            const t = try c.declaratorType(sym, decl, is_const);
            if (t != types.no_type) return t;
        }
        return types.any_type;
    }

    // =====================================================================
    // imported symbols (M5)
    // =====================================================================

    /// Value type of an import binding, via the sealed link tables.
    fn importedSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
        const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
        return c.targetValueType(tgt);
    }

    fn targetValueType(c: *Checker, tgt: modules.Target) Error!TypeId {
        switch (tgt.kind) {
            .any => return types.any_type,
            .binding => return c.typeOfSymbol(c.toGlobalIn(tgt.file, tgt.payload)),
            .namespace => return c.namespaceObjectType(tgt.file),
            .ambient_ns => return c.ambientNamespaceType(tgt.payload),
            .default_expr => {
                const saved = c.saveCtx();
                defer c.restoreCtx(saved);
                c.setFile(tgt.file);
                c.cur_scope = binder.file_scope;
                const inner = c.tree.nodeData(tgt.payload).lhs;
                switch (c.nodeTag(inner)) {
                    .function_decl => return c.signatureOfProto(inner, c.tree.nodeData(inner).lhs, false, true),
                    // Unnamed `export default class`: documented cut.
                    .class_decl => return types.any_type,
                    else => return c.widenLiteral(try c.checkExprCached(inner, types.no_type)),
                }
            },
        }
    }

    /// The module namespace object of `file` (`import * as ns`): one
    /// read-only property per value-space export. Type-space-only exports
    /// (interfaces, aliases, `export type`) are omitted — accessing them
    /// as values is a property error, close to tsc's behavior. Cycle-safe.
    fn namespaceObjectType(c: *Checker, file: FileId) Error!TypeId {
        if (c.ns_types.get(file)) |t| {
            if (t == types.no_type) return types.any_type; // ns cycle
            return t;
        }
        try c.ns_types.put(c.ca(), file, types.no_type);
        // `export = X` module (e.g. `@types/react` `export = React`): the value
        // namespace object is the value type of the export-equals target, not an
        // empty object built from the (absent) named exports. `typeof
        // import("react").createContext` must reach React's members.
        if (c.prog.links.len != 0) {
            if (c.prog.links[file].exportTarget(c.prog.export_equals_atom)) |eq| {
                if (!eq.type_only) {
                    const t = try c.targetValueType(eq);
                    try c.ns_types.put(c.ca(), file, t);
                    return t;
                }
            }
        }
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        if (c.prog.links.len != 0) {
            const l = &c.prog.links[file];
            for (l.export_atoms, l.export_targets) |name, tgt| {
                if (name == c.prog.export_equals_atom) continue; // reserved key
                if (tgt.type_only) continue;
                var ty: TypeId = types.any_type;
                switch (tgt.kind) {
                    .binding => {
                        const g0 = c.toGlobalIn(tgt.file, tgt.payload);
                        // A cross-file `declare module` augmentation may have
                        // merged this export (`namespace control` + a plugin's
                        // `namespace control { sideBySide }`): use the merged
                        // view so `L.control.sideBySide` resolves.
                        const g = c.prog.mergedOf(g0) orelse g0;
                        const f = c.symFlags(g);
                        if (!hasValueMeaning(f)) continue;
                        ty = try c.typeOfSymbol(g);
                    },
                    .namespace => ty = try c.namespaceObjectType(tgt.file),
                    .ambient_ns => ty = try c.ambientNamespaceType(tgt.payload),
                    .default_expr => ty = try c.targetValueType(tgt),
                    .any => {},
                }
                try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
            }
        }
        // Cross-package `declare module "M" { const drawLocal … }` value
        // augmentations add fresh exports to M's namespace object that have no
        // constituent in M's own export table (so no merge formed). Fold them
        // in: `import L from "leaflet"; L.drawLocal` (leaflet-draw augments
        // leaflet). Members already present as a real export are skipped (those
        // merge through the export-table path above).
        try c.appendAugmentedModuleExports(file, &props);
        const obj = try c.ts.makeObject(props.items, 0, 0, 0);
        try c.ns_types.put(c.ca(), file, obj);
        return obj;
    }

    /// Append value-space members contributed by cross-file `declare module`
    /// augmentation blocks whose specifier resolves to `file`, for names not
    /// already collected. Deterministic: files then block members in id order.
    fn appendAugmentedModuleExports(c: *Checker, file: FileId, props: *std.ArrayList(types.Prop)) Error!void {
        for (c.prog.files, 0..) |*pf, fi| {
            const b = pf.bind;
            if (!b.is_module or b.ambient_modules.len == 0) continue;
            const base = c.prog.sym_base[fi];
            for (b.ambient_modules) |am| {
                const mfile = pf.specs.get(am.spec) orelse continue;
                if (mfile != file) continue;
                const lo = b.scope_members_start[am.scope];
                const hi = b.scope_members_start[am.scope + 1];
                for (lo..hi) |i| {
                    const g = base + b.member_syms[i];
                    const f = c.symFlags(g);
                    if (!hasValueMeaning(f)) continue;
                    const name = b.member_atoms[i];
                    var dup = false;
                    for (props.items) |p| {
                        if (p.name == name) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;
                    var flags: u32 = types.prop_flag_readonly;
                    if (!f.const_decl and !f.readonly_member) flags = 0;
                    try props.append(c.scratch(), .{
                        .name = name,
                        .ty = try c.typeOfSymbol(c.prog.mergedOf(g) orelse g),
                        .flags = flags,
                    });
                }
            }
        }
    }

    /// Namespace object of an ambient module (`import * as ns from "fs"`,
    /// M11c): one read-only property per value-space export. Cycle-safe via
    /// `ambient_ns_types`.
    fn ambientNamespaceType(c: *Checker, idx: u32) Error!TypeId {
        if (c.ambient_ns_types.get(idx)) |t| {
            if (t == types.no_type) return types.any_type; // cycle
            return t;
        }
        try c.ambient_ns_types.put(c.ca(), idx, types.no_type);
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        const ae = c.prog.ambient_exports[idx];
        for (ae.atoms, ae.targets) |name, tgt| {
            if (name == c.prog.export_equals_atom) continue; // reserved key
            if (tgt.type_only) continue;
            const ty = try c.targetValueType(tgt);
            try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
        }
        const obj = try c.ts.makeObject(props.items, 0, 0, 0);
        try c.ambient_ns_types.put(c.ca(), idx, obj);
        return obj;
    }

    /// Type of one variable declarator for `sym` (no_type if this decl
    /// contributes none, e.g. bare `declarator` in a multi-decl symbol).
    fn declaratorType(c: *Checker, sym: SymbolId, decl: Node, is_const: bool) Error!TypeId {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .declarator => return types.any_type,
            .declarator_init => {
                const init_t = try c.checkExprCached(d.rhs, types.no_type);
                const vt = if (is_const) try c.ts.regular(init_t) else try c.widenLiteral(init_t);
                if (c.nodeTag(d.lhs) == .identifier) return vt;
                return c.bindingElementType(sym, decl, vt);
            },
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                var vt: TypeId = types.any_type;
                if (e.type_ann != 0) {
                    vt = try c.annTypeMaybeUnique(e.type_ann, is_const, 1332, c.nodeSpan(d.lhs));
                } else if (e.init != 0) {
                    const init_t = try c.checkExprCached(e.init, types.no_type);
                    vt = if (is_const) try c.ts.regular(init_t) else try c.widenLiteral(init_t);
                }
                if (c.nodeTag(d.lhs) == .identifier) return vt;
                return c.bindingElementType(sym, decl, vt);
            },
            else => return types.any_type,
        }
    }

    /// Type of `sym` when bound by a destructuring pattern whose whole
    /// value has type `whole`: walk the pattern to the binding position.
    fn bindingElementType(c: *Checker, sym: SymbolId, decl: Node, whole: TypeId) Error!TypeId {
        const d = c.tree.nodeData(decl);
        const pattern: Node = switch (c.nodeTag(decl)) {
            .declarator, .declarator_init, .declarator_full, .param, .param_full => d.lhs,
            else => decl,
        };
        const name = c.symNameAtom(sym);
        var result: TypeId = types.any_type;
        _ = try c.findBindingType(pattern, name, whole, &result);
        return result;
    }

    fn findBindingType(c: *Checker, pat: Node, name: Atom, whole: TypeId, out: *TypeId) Error!bool {
        if (pat == null_node) return false;
        const d = c.tree.nodeData(pat);
        switch (c.nodeTag(pat)) {
            .identifier => {
                if ((try c.atomOfToken(c.tree.nodeMainToken(pat))) == name) {
                    out.* = whole;
                    return true;
                }
                return false;
            },
            .object_pattern => {
                for (c.tree.nodeRange(pat)) |el| {
                    if (el == null_node) continue;
                    const ed = c.tree.nodeData(el);
                    switch (c.nodeTag(el)) {
                        .binding_property => {
                            const key = try c.memberAtom(c.tree.nodeMainToken(el));
                            var pt: TypeId = types.any_type;
                            if (try c.propOfType(try c.resolveStructural(whole), key)) |p| {
                                pt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                            }
                            if (ed.rhs != 0) pt = try c.removeUndefined(pt); // default strips undefined
                            if (ed.lhs != 0) {
                                if (try c.findBindingType(ed.lhs, name, pt, out)) return true;
                            } else if (key == name) {
                                out.* = pt;
                                return true;
                            }
                        },
                        .rest_element => {
                            // `{a, b, ...rest}` → rest = `whole` minus the
                            // sibling-named keys (tsc's object rest type,
                            // `Omit<whole, "a"|"b">`). Binding it to the whole
                            // object wrongly kept the destructured props, which
                            // then read as duplicated by a later spread (TS2783).
                            const rest_ty = try c.objectRestType(whole, pat);
                            if (try c.findBindingType(ed.lhs, name, rest_ty, out)) return true;
                        },
                        else => {},
                    }
                }
                return false;
            },
            .array_pattern => {
                const r = try c.resolveStructural(whole);
                var i: u32 = 0;
                for (c.tree.nodeRange(pat)) |el| {
                    if (el == null_node) continue;
                    defer i += 1;
                    if (c.nodeTag(el) == .omitted) continue;
                    var et: TypeId = types.any_type;
                    switch (c.ts.kind(r)) {
                        .array => et = c.ts.arrayElem(r),
                        .tuple => {
                            if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                        },
                        else => {},
                    }
                    if (c.nodeTag(el) == .rest_element) {
                        const ed = c.tree.nodeData(el);
                        const rest_t = try c.ts.makeArray(et);
                        if (try c.findBindingType(ed.lhs, name, rest_t, out)) return true;
                    } else if (c.nodeTag(el) == .binding_default) {
                        const ed = c.tree.nodeData(el);
                        if (try c.findBindingType(ed.lhs, name, try c.removeUndefined(et), out)) return true;
                    } else {
                        if (try c.findBindingType(el, name, et, out)) return true;
                    }
                }
                return false;
            },
            .binding_default => return c.findBindingType(d.lhs, name, whole, out),
            .rest_element => return c.findBindingType(d.lhs, name, whole, out),
            else => return false,
        }
    }

    /// Object binding-pattern rest type: `whole` with every key named by a
    /// sibling `binding_property` in `pat` removed (tsc's `{a, ...rest}` →
    /// `rest = Omit<whole, "a">`). Objects and intersections of objects are
    /// filtered (index signatures preserved); anything else (unions, generics,
    /// `any`) falls back to `whole` unchanged — lenient, matching how the rest
    /// of the checker treats non-enumerable shapes.
    fn objectRestType(c: *Checker, whole: TypeId, pat: Node) Error!TypeId {
        const r = try c.resolveStructural(whole);
        const kind = c.ts.kind(r);
        if (kind != .object and kind != .intersection) return whole;

        var excluded: std.ArrayList(Atom) = .empty;
        defer excluded.deinit(c.scratch());
        for (c.tree.nodeRange(pat)) |el| {
            if (el == null_node) continue;
            if (c.nodeTag(el) == .binding_property) {
                try excluded.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(el)));
            }
        }

        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var sidx: TypeId = 0;
        var nidx: TypeId = 0;
        // Flatten one level: a plain object contributes its own props; an
        // intersection contributes each object member's props (later members
        // win on a name clash, mirroring intersection member order). A member
        // that is not a plain object makes the shape non-enumerable → bail to
        // `whole` rather than drop constraints.
        const members: []const TypeId = if (kind == .intersection) try c.memberList(r) else &.{r};
        for (members) |m| {
            const rm = try c.resolveStructural(m);
            if (c.ts.kind(rm) != .object) return whole;
            if (c.ts.objectStringIndex(rm) != 0) sidx = c.ts.objectStringIndex(rm);
            if (c.ts.objectNumberIndex(rm) != 0) nidx = c.ts.objectNumberIndex(rm);
            for (0..c.ts.objectPropCount(rm)) |i| {
                const p = c.ts.objectProp(rm, @intCast(i));
                if (containsAtom(excluded.items, p.name)) continue;
                var replaced = false;
                for (props.items) |*existing| {
                    if (existing.name == p.name) {
                        existing.* = p;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) try props.append(c.scratch(), p);
            }
        }
        return c.ts.makeObject(props.items, sidx, nidx, 0);
    }

    fn functionSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(sym);
        const decls = c.declsOf(sym);
        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        var impl_sig: TypeId = types.no_type;
        for (decls) |decl| {
            if (c.nodeTag(decl) != .function_decl) continue;
            const d = c.tree.nodeData(decl);
            const sig = try c.signatureOfProto(decl, d.lhs, false, true);
            if (d.rhs == 0) {
                try sigs.append(c.scratch(), sig); // overload signature
            } else {
                impl_sig = sig;
            }
        }
        if (sigs.items.len == 0) {
            return if (impl_sig != types.no_type) impl_sig else types.any_type;
        }
        return c.ts.makeOverloads(sigs.items);
    }

    /// Type of a class/interface member symbol (unsubstituted).
    fn memberTypeOf(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(sym);
        const f = c.symFlags(sym);
        const decls = c.declsOf(sym);
        if (f.method) {
            var sigs: std.ArrayList(TypeId) = .empty;
            defer sigs.deinit(c.scratch());
            var impl_sig: TypeId = types.no_type;
            for (decls) |decl| {
                const tag = c.nodeTag(decl);
                if (tag != .class_method and tag != .method_signature) continue;
                const d = c.tree.nodeData(decl);
                const sig = try c.signatureOfProto(decl, d.lhs, true, true);
                if (tag == .class_method and d.rhs != 0) impl_sig = sig else try sigs.append(c.scratch(), sig);
            }
            if (sigs.items.len == 0) {
                return if (impl_sig != types.no_type) impl_sig else types.any_type;
            }
            return c.ts.makeOverloads(sigs.items);
        }
        if (f.getter or f.setter) {
            // Getter return type wins; setter-only uses its param type.
            for (decls) |decl| {
                const tag = c.nodeTag(decl);
                if (tag != .class_method and tag != .method_signature) continue;
                const d = c.tree.nodeData(decl);
                const proto = c.tree.extraData(ast.FnProto, d.lhs);
                if (proto.flags & ast.Flags.get != 0) {
                    if (proto.return_type != 0) return c.typeFromTypeNode(proto.return_type);
                    if (tag == .class_method and d.rhs != 0) return c.inferReturnType(decl, d.rhs, types.no_type);
                }
            }
            for (decls) |decl| {
                const tag = c.nodeTag(decl);
                if (tag != .class_method and tag != .method_signature) continue;
                const d = c.tree.nodeData(decl);
                const sig = try c.signatureOfProto(decl, d.lhs, true, false);
                if (c.ts.fnParamCount(sig) > 0) return c.ts.fnParam(sig, 0).ty;
            }
            return types.any_type;
        }
        // Property: class_field / property_signature / ctor param property.
        for (decls) |decl| {
            const d = c.tree.nodeData(decl);
            switch (c.nodeTag(decl)) {
                .class_field => {
                    const e = c.tree.extraData(ast.Field, d.lhs);
                    if (e.type_ann != 0) {
                        const ok = e.flags & ast.Flags.static != 0 and e.flags & ast.Flags.readonly != 0;
                        return c.annTypeMaybeUnique(e.type_ann, ok, 1331, c.tokSpan(c.tree.nodeMainToken(decl)));
                    }
                    if (e.init != 0) return c.widenLiteral(try c.checkExprCached(e.init, types.no_type));
                    return types.any_type;
                },
                .property_signature => {
                    if (d.lhs != 0) {
                        const ok = d.rhs & ast.Flags.readonly != 0;
                        return c.annTypeMaybeUnique(d.lhs, ok, 1330, c.tokSpan(c.tree.nodeMainToken(decl)));
                    }
                    return types.any_type;
                },
                .param, .param_full => {
                    const p = try c.paramInfo(decl, 0, types.no_type, false);
                    return p.ty;
                },
                else => {},
            }
        }
        return types.any_type;
    }

    // =====================================================================
    // named-type expansion & instantiation
    // =====================================================================

    fn aliasInstance(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!TypeId {
        // Crash guard for pathological mutually-recursive generic alias chains
        // (see `max_alias_depth`). `alias_state` only breaks direct self-
        // recursion; a chain through distinct syms is bounded here.
        if (c.alias_depth >= max_alias_depth) return types.error_type;
        c.alias_depth += 1;
        defer c.alias_depth -= 1;
        const state = c.alias_state.get(sym) orelse 0;
        if (state == 1) {
            // In-progress: recursive alias; leave a lazy ref. Record the
            // self-recursion so `fixTypeArgs` can scope its accumulator-default
            // substitution to genuinely recursive aliases.
            try c.alias_recursive.put(c.ca(), sym, {});
            const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
            return c.ts.makeRef(sym, fixed);
        }
        const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
        const generic = try c.aliasGeneric(sym);
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        if (tps.items.len == 0) return generic;
        var map = try c.scratch().alloc(TpMap, tps.items.len);
        for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = fixed[i] };
        const result = try c.instantiate(generic, map);
        // Same recursive shrinking-argument reduction as `expandRef` — applied
        // here so a materialized annotation (`type A = Tail<"a.b.c">`) reduces
        // all the way to `"c"` rather than stalling at the one-step `Tail<"b.c">`
        // ref, keeping the displayed type and the declared type in step with the
        // structural reduction the relation check performs.
        const orig = try c.ts.makeRef(sym, fixed);
        const reduced = try c.reexpandShrinking(orig, result);
        // Origin tag (see `origin`): a one-step alias instantiation carries the
        // canonical `makeRef(sym, fixed)` so the reflexive fast-path can match
        // it against a two-step re-instantiation of the same alias object.
        if (originTaggable(c.ts.kind(reduced))) try c.origin.put(c.ca(), reduced, orig);
        return reduced;
    }

    fn aliasGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.alias_generic.get(sym)) |t| return t;
        try c.alias_state.put(c.ca(), sym, 1);
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        // The alias body is a separate lexical declaration: its own type params
        // shadow any same-named `infer`/mapped binder of the referencing site
        // (see `tp_shadow`). Build the shadow name set for the duration of the
        // body materialization.
        var shadow_buf: std.ArrayList(Atom) = .empty;
        defer shadow_buf.deinit(c.scratch());
        {
            var body_tps: std.ArrayList(TypeParamInfo) = .empty;
            defer body_tps.deinit(c.scratch());
            try c.typeParamsOf(sym, &body_tps);
            for (body_tps.items) |tp| try shadow_buf.append(c.scratch(), c.symNameAtom(tp.sym));
        }
        const saved_shadow = c.tp_shadow;
        c.tp_shadow = shadow_buf.items;
        defer c.tp_shadow = saved_shadow;
        const decls = c.declsOf(sym);
        var result: TypeId = types.any_type;
        for (decls) |decl| {
            if (c.nodeTag(decl) != .type_alias) continue;
            const d = c.tree.nodeData(decl);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s else c.cur_scope = c.symScope(sym);
            result = try c.typeFromTypeNode(d.rhs);
            break;
        }
        // `type T = T` (any cycle collapsing to a self-ref) is circular.
        if (c.ts.kind(result) == .ref and c.ts.refSymbol(result) == sym) {
            const decls2 = c.declsOf(sym);
            if (decls2.len > 0) {
                const data = c.tree.extraData(ast.TypeAlias, c.tree.nodeData(decls2[0]).lhs);
                try c.diagFmt(2456, c.tokSpan(data.name_token), "Type alias '{s}' circularly references itself.", .{c.symbolName(sym)});
            }
            result = types.error_type;
        }
        try c.alias_generic.put(c.ca(), sym, result);
        try c.alias_state.put(c.ca(), sym, 2);
        return result;
    }

    /// Resolve `.ref` chains to a structural type (object/function/...).
    fn resolveStructural(c: *Checker, t0: TypeId) Error!TypeId {
        // A polymorphic `this` type has the apparent structure of its home
        // class instance.
        var t = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
        var i: u32 = 0;
        while (c.ts.kind(t) == .ref) : (i += 1) {
            if (i > 16) return types.error_type;
            t = try c.expandRef(t);
        }
        return t;
    }

    fn expandRef(c: *Checker, ref: TypeId) Error!TypeId {
        if (c.expansions.get(ref)) |t| {
            if (t == types.no_type) return types.error_type; // cycle
            return t;
        }
        try c.expansions.put(c.ca(), ref, types.no_type); // in-progress
        const sym = c.ts.refSymbol(ref);
        const args = try c.scratch().dupe(TypeId, c.ts.refArgs(ref));
        const f = c.symFlags(sym);
        var generic: TypeId = types.any_type;
        if (f.class) {
            generic = try c.classInstanceGeneric(sym);
        } else if (f.interface) {
            generic = try c.interfaceGeneric(sym);
        } else if (f.type_alias) {
            generic = try c.aliasGeneric(sym);
            if (c.ts.kind(generic) == .ref and c.ts.refSymbol(generic) == sym) {
                generic = types.error_type;
            }
        }
        var result = generic;
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        if (tps.items.len > 0) {
            // Map every declaration block's positional type params (reopened /
            // merged interfaces bind a distinct symbol per block) to args.
            var map_list: std.ArrayList(TpMap) = .empty;
            defer map_list.deinit(c.scratch());
            try c.buildInstMap(sym, args, &map_list);
            result = try c.instantiate(generic, map_list.items);
            // Recursive-reduction of a shrinking alias (see `reexpandShrinking`):
            // `Tail<"a.b.c">` instantiates its conditional body to the bare ref
            // `Tail<"b.c">`; eagerly re-expand while the argument metric strictly
            // decreases so it fully reduces to `"c"`. A growing recursion
            // (`Grow<{deeper:T}>`) never re-expands — its metric increases.
            if (f.type_alias) result = try c.reexpandShrinking(ref, result);
        }
        // Origin tag: this object is the materialization of `ref =
        // makeRef(sym, canonical-args)` (interface refs carry default-filled
        // args from `fixTypeArgs`). Record it so a structurally-divergent
        // re-materialization of the SAME `ref` relates by identity. Only
        // objects are tagged — a ref that resolved to a union/primitive/etc.
        // is already compared by its own rules.
        if (originTaggable(c.ts.kind(result))) try c.origin.put(c.ca(), result, ref);
        try c.expansions.put(c.ca(), ref, result);
        return result;
    }

    /// A materialized generic instantiation carries an origin tag (see `origin`)
    /// only when it lands on a structural shape whose identity the reflexive /
    /// equivalence fast-path can exploit: an object, a function, or an
    /// intersection (a callable-object `Callable & {…}` alias such as RTK's
    /// `AsyncThunk<…>` materializes to a kept intersection, and its two
    /// route-divergent instantiations must relate by origin). Unions/primitives
    /// are compared by their own rules and are never tagged.
    fn originTaggable(k: types.Kind) bool {
        return k == .object or k == .function or k == .intersection;
    }

    /// Depth ceiling on the recursive origin-arg equivalence walk (see
    /// `originArgEquiv`) — a belt on top of the structure-only reduction, which
    /// already terminates (each hop peels a ref/intersection/tuple layer).
    const origin_equiv_depth: u32 = 8;

    fn isEmptyObjectType(c: *Checker, t: TypeId) bool {
        const s = &c.ts;
        return s.kind(t) == .object and s.objectPropCount(t) == 0 and
            s.objectStringIndex(t) == 0 and s.objectNumberIndex(t) == 0 and
            s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0;
    }

    /// Canonicalize a type for origin-arg equivalence: resolve refs to their
    /// structural form, and drop empty-object members from an intersection
    /// (`T & {} ≡ T` — `{}` adds no constraint to an object member, a SOUND
    /// rewrite). Returns the interned TypeId so two structurally-identical
    /// reductions compare equal by identity, never by assignability.
    fn reduceForOriginEquiv(c: *Checker, t: TypeId) Error!TypeId {
        const r = try c.resolveStructural(t);
        if (c.ts.kind(r) != .intersection) return r;
        var non_empty: std.ArrayList(TypeId) = .empty;
        defer non_empty.deinit(c.scratch());
        for (try c.memberList(r)) |m| {
            const rm = try c.resolveStructural(m);
            if (!c.isEmptyObjectType(rm)) try non_empty.append(c.scratch(), rm);
        }
        if (non_empty.items.len == 1) return try c.reduceForOriginEquiv(non_empty.items[0]);
        return r;
    }

    /// Are two origin args EQUAL as types? Sound, identity-based (never mutual
    /// assignability): exact TypeId equality, OR same-symbol refs whose args are
    /// pairwise equivalent, OR same-shape tuples elementwise, OR one is the
    /// `T & {}` form of the other, OR two materializations sharing a same-symbol
    /// origin tag. Anything else — including `unknown`/`any` collapse against a
    /// concrete type — is NOT equivalent, so a genuinely different instantiation
    /// still fails the relation.
    fn originArgEquiv(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
        if (a0 == b0) return true;
        if (depth > origin_equiv_depth) return false;
        const s = &c.ts;
        // Compare same-symbol refs structurally WITHOUT expanding (so the
        // recursion tracks arg identity, not the materialized objects).
        if (s.kind(a0) == .ref and s.kind(b0) == .ref and s.refSymbol(a0) == s.refSymbol(b0)) {
            const sa = s.refArgs(a0);
            const ta = s.refArgs(b0);
            if (sa.len == ta.len) {
                var all = true;
                for (sa, ta) |x, y| {
                    if (!try c.originArgEquiv(x, y, depth + 1)) {
                        all = false;
                        break;
                    }
                }
                if (all) return true;
            }
        }
        const a = try c.reduceForOriginEquiv(a0);
        const b = try c.reduceForOriginEquiv(b0);
        // Identity after reduction — but not for the trivial top/bottom types,
        // whose relation the normal walk already handles permissively (guards
        // against a cycle-truncated `error_type` on both sides reading as equal).
        if (a == b) {
            return switch (s.kind(a)) {
                .any, .err, .unknown, .never, .none => false,
                else => true,
            };
        }
        const ak = s.kind(a);
        if (ak != s.kind(b)) return false;
        if (ak == .tuple) {
            if (s.tupleLen(a) != s.tupleLen(b)) return false;
            for (0..s.tupleLen(a)) |i| {
                const ea = s.tupleElem(a, @intCast(i));
                const eb = s.tupleElem(b, @intCast(i));
                if (ea.flags != eb.flags) return false;
                if (!try c.originArgEquiv(ea.ty, eb.ty, depth + 1)) return false;
            }
            return true;
        }
        // Two distinct materializations of the same generic (each carrying an
        // origin tag): recurse on the origin refs.
        if (ak == .object or ak == .function or ak == .intersection) {
            if (c.origin.get(a)) |oa| {
                if (c.origin.get(b)) |ob| {
                    if (oa == ob) return true;
                    if (s.kind(oa) == .ref and s.kind(ob) == .ref and s.refSymbol(oa) == s.refSymbol(ob)) {
                        return try c.originArgEquiv(oa, ob, depth + 1);
                    }
                }
            }
        }
        return false;
    }

    /// Ceiling on eager recursive re-expansion of a shrinking alias — a
    /// belt-and-braces bound on top of the strict-decrease rule (which already
    /// guarantees termination, since the metric is a non-negative integer that
    /// strictly decreases each hop). Hitting it stops expanding and keeps the
    /// lazy ref — exactly the pre-fix behavior.
    const shrink_reexpand_ceiling: u32 = 100;

    /// Eagerly reduce a recursive alias reference whose argument demonstrably
    /// SHRINKS on each hop. `result0` is what `Alias<args>` (identified by
    /// `orig_ref`) instantiated to. When that is a bare `.ref` back to a type
    /// alias with a STRICTLY SMALLER structural argument metric, re-expand it —
    /// this is what carries `Tail<"a.b.c">` → `Tail<"b.c">` → `Tail<"c">` → `"c"`
    /// and tuple peels like `[H, ...infer R]` all the way down.
    ///
    /// The strict-decrease test is precisely what keeps the unbounded `Grow<T> =
    /// … Grow<{deeper:T}>` case (conformance instantiation/003 + the Grow-like
    /// negative control) from ever eagerly expanding: its argument GROWS, so the
    /// metric rises and we stop, leaving the lazy ref (the relation cap /
    /// deliberate under-report handles it, unchanged). Mutual recursion (A→B→A)
    /// re-expands whenever a hop strictly shrinks and is otherwise conservatively
    /// left lazy (a non-decreasing hop stops the loop).
    fn reexpandShrinking(c: *Checker, orig_ref: TypeId, result0: TypeId) Error!TypeId {
        var result = result0;
        if (c.ts.kind(result) != .ref) return result;
        var prev_ref = orig_ref;
        var iter: u32 = 0;
        while (c.ts.kind(result) == .ref and iter < shrink_reexpand_ceiling) : (iter += 1) {
            const rsym = c.ts.refSymbol(result);
            if (!c.symFlags(rsym).type_alias) break;
            // Cross-alias ENTRY on the first hop: when a NON-recursive wrapper
            // alias reduced to a bare ref of a *different*, self-recursive alias
            // (`ExtractStoreExtensions<…> → ExtractStoreExtensionsFromEnhancerTuple
            // <Tail, Acc>`), the `orig`/`result` symbols differ and the summed
            // metric — comparing two unrelated aliases — need not decrease, so
            // the argument-wise recursion would never start. Expand once to
            // "enter" the inner alias; every subsequent hop is same-alias and
            // must pass the strict argument-wise shrink test below. The growing-
            // argument guards (003/010) are self-recursive (same symbol as
            // `orig`) or reduce to a union (not a bare ref), so they never take
            // this entry — only the strict-shrink path, which correctly stops.
            const entry = iter == 0 and c.ts.refSymbol(prev_ref) != rsym;
            if (!entry and !c.refStrictlyShrinks(prev_ref, result)) break; // not shrinking → leave lazy
            prev_ref = result;
            result = try c.expandRef(result);
        }
        return result;
    }

    /// Decide whether the hop `prev_ref → cur_ref` strictly shrinks, i.e. the
    /// recursion is making progress toward a base case and may be eagerly driven.
    ///
    /// For a SELF-recursive hop (both refs name the same alias), the decision is
    /// ARGUMENT-WISE: the hop shrinks iff at least one positional argument's
    /// structural metric strictly decreases. This is what carries an accumulator
    /// alias `Rec<Tup, Acc> = Tup extends [infer H, ...infer T] ? Rec<T, Acc &
    /// F<H>> : Acc` down: the tuple argument strictly shrinks each hop even
    /// though the growing accumulator would keep a *summed* metric flat or rising
    /// (the RTK `ExtractStoreExtensionsFromEnhancerTuple` + `Acc` and RHF
    /// `PathInternal<V, Tr|V>` shapes). The shrinking argument is a non-negative
    /// integer bounded below, so a single always-decreasing argument terminates;
    /// `shrink_reexpand_ceiling` backstops any pathological alternation. The
    /// growing-argument guards (conformance 003/010) stay safe: their sole
    /// argument GROWS, so no argument decreases and the hop is not driven.
    ///
    /// For a CROSS-alias hop (mutual recursion A→B), no positional correspondence
    /// holds, so fall back to the conservative SUMMED strict-decrease test.
    fn refStrictlyShrinks(c: *Checker, prev_ref: TypeId, cur_ref: TypeId) bool {
        const s = &c.ts;
        if (s.kind(prev_ref) != .ref or s.kind(cur_ref) != .ref)
            return c.shrinkMetric(cur_ref, 0) < c.shrinkMetric(prev_ref, 0);
        if (s.refSymbol(prev_ref) == s.refSymbol(cur_ref)) {
            const pargs = s.refArgs(prev_ref);
            const cargs = s.refArgs(cur_ref);
            if (pargs.len == cargs.len and pargs.len > 0) {
                for (pargs, cargs) |p, q| {
                    if (c.shrinkMetric(q, 0) < c.shrinkMetric(p, 0)) return true;
                }
                return false;
            }
        }
        return c.shrinkMetric(cur_ref, 0) < c.shrinkMetric(prev_ref, 0);
    }

    /// A conservative structural size metric used only to decide whether a
    /// recursive alias argument is shrinking. It must (a) DECREASE for the
    /// canonical peels — string-literal length for template peels, tuple arity
    /// for tuple peels — and (b) INCREASE for `Grow`-style wrapping. String and
    /// number literals contribute their text length; tuples/objects/refs charge
    /// per element so arity is visible; everything else is a small constant.
    /// Bounded by a depth cap so a pathological argument can't blow the stack.
    fn shrinkMetric(c: *Checker, t: TypeId, depth: u32) u64 {
        if (depth > 40) return 1;
        const s = &c.ts;
        return switch (s.kind(t)) {
            .string_literal, .bigint_literal => 1 + @as(u64, @intCast(c.atomText(s.literalAtom(t)).len)),
            .number_literal, .number_literal_fresh => 3,
            .tuple => blk: {
                var sum: u64 = 1;
                for (0..s.tupleLen(t)) |i| sum += 1 + c.shrinkMetric(s.tupleElem(t, @intCast(i)).ty, depth + 1);
                break :blk sum;
            },
            .array => 2 + c.shrinkMetric(s.arrayElem(t), depth + 1),
            .union_type, .intersection, .overloads => blk: {
                var sum: u64 = 1;
                for (s.members(t)) |m| sum += 1 + c.shrinkMetric(m, depth + 1);
                break :blk sum;
            },
            .object => blk: {
                var sum: u64 = 1;
                for (0..s.objectPropCount(t)) |i| sum += 2 + c.shrinkMetric(s.objectProp(t, @intCast(i)).ty, depth + 1);
                break :blk sum;
            },
            .ref => blk: {
                var sum: u64 = 1;
                for (s.refArgs(t)) |a| sum += c.shrinkMetric(a, depth + 1);
                break :blk sum;
            },
            else => 1,
        };
    }

    /// A re-entry into `interfaceGeneric(sym)` closed a reference loop. If the
    /// whole loop — every gray frame from `sym` to the top — is currently
    /// resolving an `extends` base, it is a genuine base cycle: report TS2310
    /// for each member (tsc reports on every interface in the cycle), each
    /// attributed to its own declaration file so `diagFmt`'s per-(file,code,
    /// span) dedup keeps one per member and its owning checker keeps its own.
    /// A loop that runs through a member or type-argument edge is a legal
    /// recursive reference and reports nothing. Either way the emitted set is
    /// a pure function of the extends graph — order- and partition-independent
    /// (M17.2).
    fn emitBaseCycle(c: *Checker, sym: SymbolId) Error!void {
        const stack = c.iface_stack.items;
        var start: usize = stack.len;
        while (start > 0) : (start -= 1) {
            if (stack[start - 1].sym == sym) break;
        }
        if (start == 0) return; // sym not on the stack (defensive; shouldn't happen)
        for (stack[start - 1 ..]) |fr| {
            if (!fr.resolving_base) return; // loop closes through a non-base edge
        }
        for (stack[start - 1 ..]) |fr| {
            const saved = c.enterSymFile(fr.sym);
            defer c.restoreCtx(saved);
            const decls = c.declsOf(fr.sym);
            if (decls.len == 0) continue;
            const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decls[0]).lhs);
            try c.diagFmt(2310, c.tokSpan(data.name_token), "Type '{s}' recursively references itself as a base type.", .{c.symbolName(fr.sym)});
        }
    }

    /// Generic (type-params-as-themselves) instance shape of an interface,
    /// with `extends` bases merged (derived members win).
    fn interfaceGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        if (c.iface_generic.get(sym)) |t| {
            if (t == types.no_type) {
                // Recursive base chain: `sym` is still on the gray stack, so
                // the slice from it to the top is the cycle. Fire TS2310 for
                // every member (tsc reports on each interface in the cycle),
                // attributed to its own file — the diagnostic set no longer
                // depends on which member the traversal entered first (M17.2).
                try c.emitBaseCycle(sym);
                return types.error_type;
            }
            return t;
        }
        try c.iface_generic.put(c.ca(), sym, types.no_type);
        try c.iface_stack.append(c.ca(), .{ .sym = sym });
        defer _ = c.iface_stack.pop();

        // Constituents: a within-file interface is one symbol carrying every
        // reopened block's decls; a cross-file merged interface (M11a) is a
        // list of per-file symbols. Members are converted in *each* constituent's
        // own file context (member type nodes resolve against that file's
        // scopes). A merged interface must fold in TWO phases — all constituents'
        // DIRECT members first, then every constituent's `extends` bases — so an
        // own member (which may live on a LATER cross-file constituent, e.g. a
        // `lib.dom.iterable` augmentation) overrides an inherited one gathered
        // from an EARLIER constituent's base. Folding whole per-constituent
        // objects (direct + inherited) instead would let an earlier
        // constituent's inherited member shadow a later constituent's own
        // member. This mirrors the single-file binder merge, where all reopened
        // blocks' direct members are gathered before any base is applied.
        var one = [_]SymbolId{sym};
        const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];

        // Phase 1: direct members of every interface constituent, unioned with
        // earlier-file members winning on conflict (disjoint in the clean case;
        // conflicts are TS2717, deferred).
        var result: TypeId = types.no_type;
        for (parts) |csym| {
            if (!c.symFlags(csym).interface) continue;
            const dm = try c.interfaceConstituentDirect(csym);
            result = if (result == types.no_type) dm else try c.mergeBaseObject(result, dm, true);
        }
        // An empty interface (no members, no bases) is still a nominal shape:
        // it lacks the implied string index that an empty object *literal* has.
        if (result == types.no_type) result = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_not_inferable);
        // Phase 2: merge every constituent's `extends` bases; the phase-1 direct
        // members win, so an own member overrides an inherited one.
        for (parts) |csym| {
            if (!c.symFlags(csym).interface) continue;
            result = try c.interfaceConstituentApplyBases(csym, result);
        }
        try c.iface_generic.put(c.ca(), sym, result);
        return result;
    }

    /// Set `this` to `sym`'s generic instance (polymorphic `this` return,
    /// `this` property/param types). Caller saves/restores `c.this_type`.
    fn setInterfaceThis(c: *Checker, sym: SymbolId) Error!void {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        const args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        c.this_type = try c.ts.makeRef(sym, args);
    }

    /// Direct members (no `extends` bases) of one interface symbol: the union of
    /// every reopened block's members, converted in the symbol's own file
    /// context. See `interfaceGeneric` for why bases are applied separately.
    fn interfaceConstituentDirect(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        try c.setInterfaceThis(sym);

        var all_members: std.ArrayList(Node) = .empty;
        defer all_members.deinit(c.scratch());
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .interface_decl) continue;
            const d = c.tree.nodeData(decl);
            const data = c.tree.extraData(ast.InterfaceData, d.lhs);
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m != null_node) try all_members.append(c.scratch(), m);
            }
        }
        // Convert members in the (first) interface scope.
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) == .interface_decl) {
                if (try c.scopeOf(decl)) |s| c.cur_scope = s;
                break;
            }
        }
        return c.objectTypeFromMembers(all_members.items, types.obj_flag_not_inferable);
    }

    /// Merge one interface symbol's `extends` bases into `acc` (members already
    /// in `acc` win), converting the heritage clauses in the symbol's own file
    /// context. Marks the current gray frame as resolving bases so a re-entry is
    /// recognized as a base cycle (TS2310); member/type-argument resolution
    /// stays out of the base phase, so a recursive reference through them is
    /// legal and reports nothing (M17.2).
    fn interfaceConstituentApplyBases(c: *Checker, sym: SymbolId, acc: TypeId) Error!TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        try c.setInterfaceThis(sym);

        var bases: std.ArrayList(TypeId) = .empty;
        defer bases.deinit(c.scratch());
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .interface_decl) continue;
            const d = c.tree.nodeData(decl);
            const data = c.tree.extraData(ast.InterfaceData, d.lhs);
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            for (c.tree.extraRange(data.extends_start, data.extends_end)) |h| {
                if (h == null_node or c.nodeTag(h) != .heritage) continue;
                const hd = c.tree.nodeData(h);
                var targs: std.ArrayList(TypeId) = .empty;
                defer targs.deinit(c.scratch());
                if (hd.rhs != 0) {
                    const r = c.tree.extraData(ast.SubRange, hd.rhs);
                    for (c.tree.extraRange(r.start, r.end)) |an| {
                        if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                    }
                }
                const base = try c.typeFromTypeName(hd.lhs, targs.items);
                try bases.append(c.scratch(), base);
            }
        }
        const frame_idx: ?usize = if (c.iface_stack.items.len > 0) c.iface_stack.items.len - 1 else null;
        if (frame_idx) |fi| c.iface_stack.items[fi].resolving_base = true;
        defer if (frame_idx) |fi| {
            c.iface_stack.items[fi].resolving_base = false;
        };
        var own = acc;
        for (bases.items) |base| {
            own = try c.mergeBaseResolved(own, try c.resolveStructural(base));
        }
        return own;
    }

    /// Merge one resolved base into `derived`. A base that reduces to an
    /// intersection of objects (e.g. `interface X extends Omit<M, K> & { … }`,
    /// or a `type` alias whose body is an intersection) contributes the members
    /// of each object constituent — folded left-to-right so an earlier
    /// constituent (and `derived` itself) wins on a name clash. Without this,
    /// `mergeBaseObject`'s object-only guard would silently drop every inherited
    /// member of an intersection base.
    fn mergeBaseResolved(c: *Checker, derived: TypeId, base: TypeId) Error!TypeId {
        if (c.ts.kind(base) == .intersection) {
            var result = derived;
            for (try c.memberList(base)) |m| {
                result = try c.mergeBaseResolved(result, try c.resolveStructural(m));
            }
            return result;
        }
        return c.mergeBaseObject(derived, base, false);
    }

    /// Combined overload set of two callable members (`.function` or
    /// `.overloads`), `a`'s signatures before `b`'s. Returns null when either
    /// side is not callable, so the caller falls back to earlier-wins.
    fn unionCallableSigs(c: *Checker, a: TypeId, b: TypeId) Error!?TypeId {
        const s = &c.ts;
        const ka = s.kind(a);
        const kb = s.kind(b);
        const a_ok = ka == .function or ka == .overloads;
        const b_ok = kb == .function or kb == .overloads;
        if (!a_ok or !b_ok) return null;
        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        for ([2]TypeId{ a, b }) |o| {
            if (s.kind(o) == .overloads) {
                for (s.members(o)) |m| try sigs.append(c.scratch(), m);
            } else {
                try sigs.append(c.scratch(), o);
            }
        }
        return try s.makeOverloads(sigs.items);
    }

    /// Merge base-object members into `derived` (derived wins). When
    /// `union_overloads` is set (the cross-file interface-declaration Phase-1
    /// merge), a method declared in BOTH objects contributes its signatures to
    /// a single combined overload set (`derived`'s first) rather than the
    /// earlier declaration hiding the later's overloads — mirroring tsc's
    /// declaration-order overload concatenation across merged interface
    /// declarations, and the within-file reopened-block behavior already
    /// implemented in `objectTypeFromMembers`. Base/heritage merging keeps
    /// `union_overloads` false: an inherited member is shadowed, not unioned.
    fn mergeBaseObject(c: *Checker, derived: TypeId, base: TypeId, union_overloads: bool) Error!TypeId {
        if (c.ts.kind(base) != .object or c.ts.kind(derived) != .object) return derived;
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var idx: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
        defer idx.deinit(c.scratch());
        for (0..c.ts.objectPropCount(derived)) |i| {
            const p = c.ts.objectProp(derived, @intCast(i));
            try idx.put(c.scratch(), p.name, @intCast(props.items.len));
            try props.append(c.scratch(), p);
        }
        for (0..c.ts.objectPropCount(base)) |i| {
            const bp = c.ts.objectProp(base, @intCast(i));
            if (idx.get(bp.name)) |di| {
                if (union_overloads) {
                    if (try c.unionCallableSigs(props.items[di].ty, bp.ty)) |mt| props.items[di].ty = mt;
                }
            } else {
                try idx.put(c.scratch(), bp.name, @intCast(props.items.len));
                try props.append(c.scratch(), bp);
            }
        }
        const sidx = if (c.ts.objectStringIndex(derived) != 0) c.ts.objectStringIndex(derived) else c.ts.objectStringIndex(base);
        const nidx = if (c.ts.objectNumberIndex(derived) != 0) c.ts.objectNumberIndex(derived) else c.ts.objectNumberIndex(base);
        // Preserve call/construct signatures from both sides (M18.1): a callable
        // interface extending another accumulates every signature.
        if (!c.ts.objectHasSigs(derived) and !c.ts.objectHasSigs(base)) {
            return c.ts.makeObject(props.items, sidx, nidx, c.ts.objectFlags(derived) & ~types.obj_flag_has_sigs);
        }
        var calls: std.ArrayList(TypeId) = .empty;
        defer calls.deinit(c.scratch());
        var constructs: std.ArrayList(TypeId) = .empty;
        defer constructs.deinit(c.scratch());
        for ([2]TypeId{ derived, base }) |o| {
            for (0..c.ts.objectCallSigCount(o)) |i| try calls.append(c.scratch(), c.ts.objectCallSig(o, @intCast(i)));
            for (0..c.ts.objectConstructSigCount(o)) |i| try constructs.append(c.scratch(), c.ts.objectConstructSig(o, @intCast(i)));
        }
        return c.ts.makeObjectSigs(props.items, sidx, nidx, c.ts.objectFlags(derived) & ~types.obj_flag_has_sigs, calls.items, constructs.items);
    }

    /// Generic instance shape of a class: instance members + base instance.
    fn classInstanceGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.class_inst_generic.get(sym)) |t| {
            if (t == types.no_type) return types.error_type;
            return t;
        }
        try c.class_inst_generic.put(c.ca(), sym, types.no_type);
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        // `this` inside member type nodes (a `foo(): this` return, a `x: this`
        // property, a `this` parameter) refers to this class's generic
        // instance. Set it here so member signatures pick up the polymorphic
        // `this` marker even when they are first evaluated through instance
        // expansion (before `checkClass`).
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        {
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(sym, &tps);
            const args = try c.scratch().alloc(TypeId, tps.items.len);
            for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
            c.this_type = try c.ts.makeRef(sym, args);
        }
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        // A class instance is a nominal shape without the implied string index
        // that an object/type literal carries (an empty `class C {}` must still
        // fail assignment to `{[k:string]:T}`).
        var result: TypeId = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_not_inferable);
        if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
            const kscope = c.symScope(sym);
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                const msym = c.toGlobal(c.bind.member_syms[i]);
                const name = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope);
                const mf = c.symFlags(msym);
                if (isCtorName(c, name)) continue;
                var flags: u32 = 0;
                if (mf.optional_member) flags |= types.prop_flag_optional;
                if (mf.readonly_member) flags |= types.prop_flag_readonly;
                // A get-only accessor is a read-only property (TS2540 on write).
                if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
                try props.append(c.scratch(), .{
                    .name = name,
                    .ty = try c.memberTypeOf(msym),
                    .flags = flags,
                });
            }
            result = try c.ts.makeObject(props.items, 0, 0, types.obj_flag_not_inferable);
        }
        // Merge base class instance.
        if (try c.baseClassRef(sym)) |base_ref| {
            result = try c.mergeBaseObject(result, try c.resolveStructural(base_ref), false);
        } else if (try c.baseExprConstructType(sym)) |base_ctor| {
            // `extends <value with construct signatures>`: the base instance is
            // the construct signature's return type.
            const inst = c.ts.objectConstructSig(base_ctor, 0);
            const ret = c.ts.fnReturn(inst);
            result = try c.mergeBaseObject(result, try c.resolveStructural(ret), false);
        }
        // Cross-file `declare module` augmentation (M11c): an `interface Map`
        // block in another package folds its members into the resolved class's
        // instance type (interface-augments-class declaration merge). The class
        // is the merged symbol's representative constituent; each interface
        // constituent supplies augmentation members, added on top of the base
        // and unioning any callable-signature overloads (e.g. `on(...)`).
        if (c.prog.isMergedId(sym)) {
            for (c.prog.mergedSym(sym).parts) |p| {
                if (!c.symFlags(p).interface) continue;
                result = try c.mergeBaseObject(result, try c.interfaceConstituentDirect(p), true);
            }
        }
        try c.class_inst_generic.put(c.ca(), sym, result);
        return result;
    }

    fn isCtorName(c: *Checker, name: Atom) bool {
        return std.mem.eql(u8, c.atomText(name), "constructor");
    }

    /// Is `name` an OWN instance member (field, param-property, accessor,
    /// method) of the class whose constructor is currently being checked? Used
    /// to permit a `readonly` assignment via `this.name` inside that
    /// constructor (an inherited readonly is not own → still TS2540).
    fn ctorClassOwnsMember(c: *Checker, name: Atom) bool {
        if (c.ctor_class_sym == binder.no_symbol) return false;
        const saved = c.enterSymFile(c.ctor_class_sym);
        defer c.restoreCtx(saved);
        const ms = c.bind.membersScopeOf(c.localOf(c.ctor_class_sym)) orelse return false;
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            if (c.bind.member_atoms[i] == name) return true;
        }
        return false;
    }

    /// The `extends` base of a class as a ref (or null). The base name
    /// resolves in the class's own file (so imported bases work).
    fn baseClassRef(c: *Checker, sym: SymbolId) Error!?TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            if (data.extends == 0) return null;
            const hd = c.tree.nodeData(data.extends);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            const base_sym = (try c.classBaseEntitySym(hd.lhs)) orelse return null;
            if (!c.symFlags(base_sym).class) return null;
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            if (hd.rhs != 0) {
                const r = c.tree.extraData(ast.SubRange, hd.rhs);
                for (c.tree.extraRange(r.start, r.end)) |an| {
                    if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                }
            }
            const name_tok = switch (c.nodeTag(hd.lhs)) {
                .identifier => c.tree.nodeMainToken(hd.lhs),
                else => c.tree.nodeData(hd.lhs).rhs,
            };
            const fixed = try c.fixTypeArgs(base_sym, targs.items, name_tok) orelse return null;
            return try c.ts.makeRef(base_sym, fixed);
        }
        return null;
    }

    /// The base *class symbol* of `sym` (`class D extends B`), when the base
    /// resolves to a class declaration. Mirrors `baseClassRef`'s resolution but
    /// yields the symbol — used to inherit static members (`typeof D` includes
    /// `typeof B`'s statics: `Map.include`/`GridLayer.extend` reach `Class`).
    fn baseClassSym(c: *Checker, sym: SymbolId) Error!?SymbolId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            if (data.extends == 0) return null;
            const hd = c.tree.nodeData(data.extends);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            const base_sym = (try c.classBaseEntitySym(hd.lhs)) orelse return null;
            if (!c.symFlags(base_sym).class) return null;
            if (base_sym == sym) return null; // self-extends: no static inherit
            return base_sym;
        }
        return null;
    }

    /// Resolve a class `extends` entity (identifier or dotted, e.g.
    /// `React.Component`) to its declaration symbol. Import bindings are
    /// followed; a namespace import of an `export =`-namespace module (the
    /// @types/react shape) resolves through the exported namespace. Null for
    /// anything unresolvable or non-symbolic (expressions, mixins).
    fn classBaseEntitySym(c: *Checker, node: Node) Error!?SymbolId {
        switch (c.nodeTag(node)) {
            .identifier => {
                const a = try c.atomOfToken(c.tree.nodeMainToken(node));
                switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| {
                        if (!c.symFlags(sym).import_binding) return sym;
                        const tgt = c.importTarget(sym) orelse return null;
                        return c.importedContainerSym(tgt);
                    },
                    else => return null,
                }
            },
            .member_expr, .qualified_name => {
                // `extends mod.Base` — resolve the qualifier to its container
                // (namespace symbol or whole-module namespace of an
                // `import * as`), then take the exported member. Shares the
                // unified resolver so a namespace-import qualifier over a plain
                // named-export module works, not just `export =` namespaces.
                const d = c.tree.nodeData(node);
                const container = (try c.resolveNsContainer(d.lhs)) orelse return null;
                return c.containerMemberSym(container, try c.memberAtom(d.rhs));
            },
            else => return null,
        }
    }

    /// When a class `extends <expr>` and `<expr>` is a *value* (not a class
    /// symbol) whose type carries construct signatures — the
    /// `declare const Base: { new (input): R }` mixin-base pattern, e.g. the
    /// AWS-SDK Smithy `class XCommand extends XCommand_base` where the base
    /// const's type has a `new(input)` signature — returns that base
    /// constructor object type (resolved structurally). The derived class then
    /// inherits both the construct signature (for `new Derived(args)`) and the
    /// signature's return type as its base instance. Null when there is no
    /// extends clause, the base resolves to a class symbol (handled by
    /// `baseClassRef`), or the base value has no construct signatures.
    fn baseExprConstructType(c: *Checker, sym: SymbolId) Error!?TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            if (data.extends == 0) return null;
            const hd = c.tree.nodeData(data.extends);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            // A class-symbol base is `baseClassRef`'s job; skip it here.
            if (try c.classBaseEntitySym(hd.lhs)) |bs| {
                if (c.symFlags(bs).class) return null;
            }
            const bt = try c.resolveStructural(try c.checkExprCached(hd.lhs, types.no_type));
            if (c.ts.kind(bt) == .object and c.ts.objectConstructSigCount(bt) > 0) return bt;
            return null;
        }
        return null;
    }

    /// The declaration symbol behind an import target: a direct binding, or —
    /// for a whole-module (`import * as X`) target — the module's `export =`
    /// entity when it is a symbol (namespace/class), which is how `X.Member`
    /// reaches into `export = X`-style packages. Null otherwise.
    fn importedContainerSym(c: *Checker, tgt: modules.Target) ?SymbolId {
        switch (tgt.kind) {
            .binding => return c.toGlobalIn(tgt.file, tgt.payload),
            .namespace => {
                if (c.prog.links.len == 0) return null;
                const eq = c.prog.links[tgt.file].exportTarget(c.prog.export_equals_atom) orelse return null;
                return c.targetTypeSym(eq);
            },
            .ambient_ns => {
                const eq = c.moduleExportTarget(.{ .ambient = tgt.payload }, c.prog.export_equals_atom) orelse return null;
                return c.targetTypeSym(eq);
            },
            else => return null,
        }
    }

    /// Whether a class symbol is declared `abstract`.
    fn classIsAbstract(c: *Checker, sym: SymbolId) Error!bool {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            return data.flags & ast.Flags.abstract != 0;
        }
        return false;
    }

    /// Whether a class member symbol's declaration is `abstract`.
    fn memberIsAbstract(c: *Checker, msym: SymbolId) bool {
        for (c.declsOf(msym)) |decl| {
            const d = c.tree.nodeData(decl);
            switch (c.nodeTag(decl)) {
                .class_method => {
                    const proto = c.tree.extraData(ast.FnProto, d.lhs);
                    if (proto.flags & ast.Flags.abstract != 0) return true;
                },
                .class_field => {
                    const f = c.tree.extraData(ast.Field, d.lhs);
                    if (f.flags & ast.Flags.abstract != 0) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// A concrete class extending an abstract one must implement every
    /// still-abstract inherited member. One missing member → TS2515; two or
    /// more → the aggregate TS2654. Both point at the derived class name.
    fn checkAbstractImplementation(c: *Checker, class_sym: SymbolId, class_node: Node) Error!void {
        if (try c.classIsAbstract(class_sym)) return;
        const base_ref = try c.baseClassRef(class_sym) orelse return;
        const direct_base = c.ts.refSymbol(base_ref);

        // Names the derived class (and any concrete override on the way up)
        // provides; walking most-derived first, the first declaration of each
        // name wins. The derived class itself is concrete, so all its members
        // count as implementations.
        var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer seen.deinit(c.scratch());
        try c.collectClassMemberAtoms(class_sym, &seen);

        var unimpl: std.ArrayList(Atom) = .empty;
        defer unimpl.deinit(c.scratch());

        var cur = direct_base;
        var depth: u32 = 0;
        while (depth < 64) : (depth += 1) {
            {
                const saved = c.enterSymFile(cur);
                defer c.restoreCtx(saved);
                if (c.bind.membersScopeOf(c.localOf(cur))) |ms| {
                    const lo = c.bind.scope_members_start[ms];
                    const hi = c.bind.scope_members_start[ms + 1];
                    // Collect this base's unimplemented members in source
                    // order (scope-member order is name-bucketed, not
                    // declaration order) so the TS2654 list matches tsc.
                    const Unimpl = struct { atom: Atom, start: u32 };
                    var batch: std.ArrayList(Unimpl) = .empty;
                    defer batch.deinit(c.scratch());
                    for (lo..hi) |i| {
                        const name_atom = c.bind.member_atoms[i];
                        if (isCtorName(c, name_atom)) continue;
                        if (seen.contains(name_atom)) continue;
                        try seen.put(c.scratch(), name_atom, {});
                        const local_sym = c.bind.member_syms[i];
                        const msym = c.toGlobal(local_sym);
                        if (c.memberIsAbstract(msym)) {
                            const decls = c.bind.declsOf(local_sym);
                            const start = if (decls.len > 0) c.nodeSpan(decls[0]).start else 0;
                            try batch.append(c.scratch(), .{ .atom = name_atom, .start = start });
                        }
                    }
                    std.mem.sort(Unimpl, batch.items, {}, struct {
                        fn lessThan(_: void, x: Unimpl, y: Unimpl) bool {
                            return x.start < y.start;
                        }
                    }.lessThan);
                    for (batch.items) |u| try unimpl.append(c.scratch(), u.atom);
                }
            }
            const nb = try c.baseClassRef(cur) orelse break;
            cur = c.ts.refSymbol(nb);
        }

        if (unimpl.items.len == 0) return;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(class_node).lhs);
        const span = c.tokSpan(data.name_token);
        const class_name = c.symbolName(class_sym);
        const base_name = c.symbolName(direct_base);
        if (unimpl.items.len == 1) {
            try c.diagFmt(2515, span, "Non-abstract class '{s}' does not implement inherited abstract member {s} from class '{s}'.", .{
                class_name, c.atomText(unimpl.items[0]), base_name,
            });
        } else {
            var names: std.Io.Writer.Allocating = .init(c.scratch());
            defer names.deinit();
            for (unimpl.items, 0..) |m, i| {
                if (i > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
                names.writer.print("'{s}'", .{c.atomText(m)}) catch return error.OutOfMemory;
            }
            try c.diagFmt(2654, span, "Non-abstract class '{s}' is missing implementations for the following members of '{s}': {s}.", .{
                class_name, base_name, names.written(),
            });
        }
    }

    /// Record every member-name of a class (instance and static) into `seen`.
    fn collectClassMemberAtoms(c: *Checker, sym: SymbolId, seen: *std.AutoHashMapUnmanaged(Atom, void)) Error!void {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        const local = c.localOf(sym);
        inline for (.{ c.bind.membersScopeOf(local), c.bind.staticsScopeOf(local) }) |maybe_scope| {
            if (maybe_scope) |ms| {
                const lo = c.bind.scope_members_start[ms];
                const hi = c.bind.scope_members_start[ms + 1];
                for (lo..hi) |i| try seen.put(c.scratch(), c.bind.member_atoms[i], {});
            }
        }
    }

    /// Static side of a class (statics as object props; construct handled
    /// separately by `new` resolution).
    // =====================================================================
    // enums (M11)
    // =====================================================================

    const EnumInfo = struct {
        is_const: bool,
        /// Every member is a string constant (nominal string enum).
        all_string: bool,
        /// No string members (pure numeric / auto-increment / computed).
        all_numeric: bool,
        /// At least one member has a non-constant initializer.
        has_computed: bool,
        /// Numeric member values, for numeric-literal membership checks.
        values: []const f64,

        fn hasValue(self: EnumInfo, v: f64) bool {
            for (self.values) |x| {
                if (x == v) return true;
            }
            return false;
        }
    };

    const EnumInitKind = enum { numeric, string, computed };

    /// Classify an enum member initializer for constant folding. Only literal
    /// numbers (incl. unary `-`/`+`) and string literals fold to constants;
    /// anything else is "computed".
    fn classifyEnumInit(c: *Checker, node: Node) struct { kind: EnumInitKind, value: f64 } {
        switch (c.nodeTag(node)) {
            .number_literal => return .{ .kind = .numeric, .value = c.numberTokenValue(c.tree.nodeMainToken(node)) },
            .prefix_unary => {
                const d = c.tree.nodeData(node);
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
                if ((op == .minus or op == .plus) and d.lhs != 0 and c.nodeTag(d.lhs) == .number_literal) {
                    const v = c.numberTokenValue(c.tree.nodeMainToken(d.lhs));
                    return .{ .kind = .numeric, .value = if (op == .minus) -v else v };
                }
                return .{ .kind = .computed, .value = 0 };
            },
            .string_literal => return .{ .kind = .string, .value = 0 },
            else => return .{ .kind = .computed, .value = 0 },
        }
    }

    /// Const-ness, string/numeric nature, and numeric member values of an
    /// enum symbol (all declaration blocks merged). Pure computation, cached.
    fn enumInfo(c: *Checker, sym: SymbolId) Error!EnumInfo {
        if (c.enum_info_cache.get(sym)) |info| return info;
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        var values: std.ArrayList(f64) = .empty;
        defer values.deinit(c.scratch());
        var is_const = false;
        var has_string = false;
        var has_computed = false;
        var member_count: u32 = 0;
        var auto: f64 = 0;
        var auto_ok = true;
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .enum_decl) continue;
            const d = c.tree.nodeData(decl);
            const data = c.tree.extraData(ast.EnumData, d.lhs);
            if (data.flags & ast.Flags.const_enum != 0) is_const = true;
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m == null_node or c.nodeTag(m) != .enum_member) continue;
                member_count += 1;
                const init_node = c.tree.nodeData(m).lhs;
                if (init_node == null_node) {
                    if (auto_ok) {
                        try values.append(c.scratch(), auto);
                        auto += 1;
                    }
                    continue;
                }
                const ci = c.classifyEnumInit(init_node);
                switch (ci.kind) {
                    .numeric => {
                        try values.append(c.scratch(), ci.value);
                        auto = ci.value + 1;
                        auto_ok = true;
                    },
                    .string => {
                        has_string = true;
                        auto_ok = false;
                    },
                    .computed => {
                        has_computed = true;
                        auto_ok = false;
                    },
                }
            }
        }
        const info: EnumInfo = .{
            .is_const = is_const,
            .all_string = has_string and !has_computed and values.items.len == 0 and member_count > 0,
            .all_numeric = !has_string,
            .has_computed = has_computed,
            .values = try c.ca().dupe(f64, values.items),
        };
        try c.enum_info_cache.put(c.ca(), sym, info);
        return info;
    }

    /// Whether an enum has any string-valued member (non-allocating scan).
    /// A string enum is stringish; an all-numeric enum is numberish — this
    /// lets numeric enums take part in arithmetic/comparison like `number`.
    fn enumHasStringMember(c: *Checker, sym: SymbolId) bool {
        if (c.enum_info_cache.get(sym)) |info| return !info.all_numeric;
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .enum_decl) continue;
            const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m == null_node or c.nodeTag(m) != .enum_member) continue;
                const init_node = c.tree.nodeData(m).lhs;
                if (init_node != null_node and c.classifyEnumInit(init_node).kind == .string) return true;
            }
        }
        return false;
    }

    /// The value object of an enum (`typeof E`): one readonly property per
    /// member, each typed as the (nominal) enum type.
    fn enumValueType(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.enum_value_cache.get(sym)) |t| return t;
        const enum_t = try c.ts.makeEnumType(sym);
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .enum_decl) continue;
            const d = c.tree.nodeData(decl);
            const data = c.tree.extraData(ast.EnumData, d.lhs);
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m == null_node or c.nodeTag(m) != .enum_member) continue;
                const name = try c.memberAtom(c.tree.nodeMainToken(m));
                var dup = false;
                for (props.items) |p| {
                    if (p.name == name) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue; // first declaration wins (unique object keys)
                try props.append(c.scratch(), .{ .name = name, .ty = enum_t, .flags = types.prop_flag_readonly });
            }
        }
        const result = try c.ts.makeObject(props.items, 0, 0, 0);
        try c.enum_value_cache.put(c.ca(), sym, result);
        return result;
    }

    /// Nominal enum assignability (identical enums are caught by `s == t`
    /// upstream). Matches tsc 5.5: a numeric enum interconverts with `number`
    /// (and accepts numeric literals equal to a member value); a string enum
    /// is a subtype of `string` but nothing widens *into* it.
    fn enumAssignable(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
        if (sk == .enum_type and tk == .enum_type) return false;
        if (sk == .enum_type) {
            const info = try c.enumInfo(c.ts.enumSymbol(s));
            if (tk == .number and info.all_numeric) return true;
            if (tk == .string and info.all_string) return true;
            return false;
        }
        // tk == .enum_type
        const info = try c.enumInfo(c.ts.enumSymbol(t));
        if (info.all_numeric) {
            if (sk == .number) return true;
            if (sk == .number_literal or sk == .number_literal_fresh) {
                if (info.has_computed) return true;
                return info.hasValue(c.ts.numberValue(s));
            }
        }
        return false;
    }

    /// Does a string-valued member of enum `sym` have the value `val`? Used by
    /// the *comparable* relation (TS2367): a string enum overlaps a string
    /// literal equal to one of its member values, even though the literal is
    /// not assignable into the nominal enum.
    fn enumHasStringValue(c: *Checker, sym: SymbolId, val: Atom) Error!bool {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .enum_decl) continue;
            const d = c.tree.nodeData(decl);
            const data = c.tree.extraData(ast.EnumData, d.lhs);
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m == null_node or c.nodeTag(m) != .enum_member) continue;
                const init_node = c.tree.nodeData(m).lhs;
                if (init_node == null_node or c.nodeTag(init_node) != .string_literal) continue;
                if ((try c.memberAtom(c.tree.nodeMainToken(init_node))) == val) return true;
            }
        }
        return false;
    }

    /// Type-check an enum declaration: validate member initializers (TS1061)
    /// and check any initializer expressions.
    fn checkEnum(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const data = c.tree.extraData(ast.EnumData, d.lhs);
        // A member with no initializer is only legal when the previous member
        // (or the start of the enum) is a numeric constant it can continue.
        var prev_numeric_const = true;
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const init_node = c.tree.nodeData(m).lhs;
            if (init_node == null_node) {
                if (!prev_numeric_const) {
                    try c.diagFmt(1061, c.tokSpan(c.tree.nodeMainToken(m)), "Enum member must have initializer.", .{});
                }
                continue; // auto-increment continues the numeric chain
            }
            _ = try c.checkExprCached(init_node, types.no_type);
            // Only a string-valued member blocks a following bare member. A
            // non-literal ("computed") initializer may still be a constant
            // enum expression (e.g. a reference to a `const`), which tsc lets
            // a subsequent member continue — so we don't force TS1061 there.
            prev_numeric_const = c.classifyEnumInit(init_node).kind != .string;
        }
    }

    fn classStaticType(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.class_static_cache.get(sym)) |t| return t;
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        if (c.bind.staticsScopeOf(c.localOf(sym))) |ss| {
            const kscope = c.symScope(sym);
            const lo = c.bind.scope_members_start[ss];
            const hi = c.bind.scope_members_start[ss + 1];
            for (lo..hi) |i| {
                const msym = c.toGlobal(c.bind.member_syms[i]);
                const mf = c.symFlags(msym);
                var flags: u32 = 0;
                if (mf.readonly_member) flags |= types.prop_flag_readonly;
                if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
                try props.append(c.scratch(), .{
                    .name = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope),
                    // Route through typeOfSymbol (not memberTypeOf directly) so a
                    // static field whose initializer reads a sibling static —
                    // `static a = () => C.b; static b = 1` — re-enters the
                    // in-progress guard (returns `any` transiently, then the
                    // outer frame resolves the real type) instead of rebuilding
                    // this same static object and recursing to a stack overflow.
                    // Statics can't reference the class type params, so the
                    // per-symbol type cache is sound here.
                    .ty = try c.typeOfSymbol(msym),
                    .flags = flags,
                });
            }
        }
        // Namespace value members: one property per *exported* value-space
        // member. A merged namespace (M11b) draws them from its merged member
        // index (member ids may themselves be merged); a plain namespace from
        // its (merged-within-file) body scope.
        if (c.symFlags(sym).namespace_decl) {
            var midx_atoms: []const Atom = &.{};
            var midx_syms: []const u32 = &.{};
            if (c.prog.isMergedId(sym)) {
                const idx = c.prog.mergedSym(sym).members;
                midx_atoms = idx.atoms;
                midx_syms = idx.syms;
            } else if (c.bind.namespaceScopeOf(c.localOf(sym))) |ns| {
                const lo = c.bind.scope_members_start[ns];
                const hi = c.bind.scope_members_start[ns + 1];
                // Lift the body-scope segment to global ids in this file.
                const gs = try c.scratch().alloc(u32, hi - lo);
                for (lo..hi, 0..) |i, k| gs[k] = c.toGlobal(c.bind.member_syms[i]);
                midx_atoms = c.bind.member_atoms[lo..hi];
                midx_syms = gs;
            }
            for (midx_atoms, midx_syms) |name, msym| {
                const mf = c.symFlags(msym);
                if (!mf.exported or !hasValueMeaning(mf)) continue;
                var dup = false;
                for (props.items) |p| {
                    if (p.name == name) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                var flags: u32 = 0;
                if (mf.const_decl or mf.readonly_member) flags |= types.prop_flag_readonly;
                try props.append(c.scratch(), .{
                    .name = name,
                    .ty = try c.typeOfSymbol(msym),
                    .flags = flags,
                });
            }
        }
        var result = try c.ts.makeObject(props.items, 0, 0, 0);
        // Static members are inherited: `typeof D` includes `typeof Base`'s
        // statics (own members win over inherited). This is how leaflet's
        // `Map.include`/`GridLayer.extend` reach the static `extend`/`include`
        // declared on the root `class Class`. Guard the recursion against a
        // malformed `extends` cycle without poisoning the result cache — a
        // static-field initializer that reads a sibling static re-enters this
        // function and must still see the class's own members.
        if (!c.class_static_base_active.contains(sym)) {
            if (try c.baseClassSym(sym)) |base| {
                try c.class_static_base_active.put(c.ca(), sym, {});
                const base_static = try c.classStaticType(base);
                _ = c.class_static_base_active.remove(sym);
                result = try c.mergeBaseObject(result, base_static, false);
            }
        }
        try c.class_static_cache.put(c.ca(), sym, result);
        return result;
    }

    /// Constructor signatures of a class (own or inherited); empty list
    /// means the default ctor.
    fn ctorSignatures(c: *Checker, sym: SymbolId, out: *std.ArrayList(TypeId)) Error!void {
        var cur = sym;
        var depth: u32 = 0;
        while (depth < 16) : (depth += 1) {
            const saved = c.enterSymFile(cur);
            defer c.restoreCtx(saved);
            if (c.bind.membersScopeOf(c.localOf(cur))) |ms| {
                const lo = c.bind.scope_members_start[ms];
                const hi = c.bind.scope_members_start[ms + 1];
                for (lo..hi) |i| {
                    if (!isCtorName(c, c.bind.member_atoms[i])) continue;
                    const csym = c.bind.member_syms[i];
                    for (c.bind.declsOf(csym)) |decl| {
                        if (c.nodeTag(decl) != .class_method) continue;
                        const d = c.tree.nodeData(decl);
                        // Overload signatures (no body) participate; the
                        // implementation is used only if it's alone.
                        const sig = try c.signatureOfProto(decl, d.lhs, true, true);
                        if (d.rhs == 0) try out.append(c.scratch(), sig);
                    }
                    if (out.items.len == 0) {
                        for (c.bind.declsOf(csym)) |decl| {
                            if (c.nodeTag(decl) != .class_method) continue;
                            const d = c.tree.nodeData(decl);
                            if (d.rhs != 0) {
                                try out.append(c.scratch(), try c.signatureOfProto(decl, d.lhs, true, true));
                            }
                        }
                    }
                    if (out.items.len > 0) return;
                }
            }
            // Inherit base ctor.
            const base = try c.baseClassRef(cur) orelse {
                // `extends <value with construct signatures>` (mixin-base):
                // inherit the base value's construct signatures.
                if (try c.baseExprConstructType(cur)) |base_ctor| {
                    for (0..c.ts.objectConstructSigCount(base_ctor)) |i| {
                        try out.append(c.scratch(), c.ts.objectConstructSig(base_ctor, @intCast(i)));
                    }
                }
                return;
            };
            cur = c.ts.refSymbol(base);
        }
    }

    const TpMap = struct { sym: SymbolId, ty: TypeId };
    const InferKey = struct { cond: u64, name: Atom };

    /// Whether a higher-order signature is safe to instantiate-and-keep (M20a).
    /// The rewrite substitutes the sig body and mints fresh symbols for own
    /// params whose bounds move under the map. It is sound only when every own
    /// param's constraint/default is *bare* (a plain type param) or absent: then
    /// the fresh param needs no constraint enforcement (a bare bound was never
    /// enforceable anyway — the `bare_outer` escape in `inferTypeArgs`) and its
    /// default is a simple substitution. A sig with a *structured* bound (RHF's
    /// `<TName extends FieldPath<TFieldValues>>`, whose `Path`/`PathValue` deep
    /// conditional+template types ztsc can't fully reduce) is NOT eligible: it
    /// is dropped exactly as before this rewrite, so those call sites keep their
    /// pristine behavior (no churn) instead of trading one unreducible-type
    /// diagnostic for another.
    fn higherOrderSigEligible(c: *Checker, sig: TypeId) Error!bool {
        for (c.ts.fnTypeParams(sig)) |p| {
            const con = try c.typeParamConstraint(p);
            if (con != types.no_type and c.ts.kind(con) != .type_param and !try c.boundReducible(con, 0) and !try c.boundHasReducerShape(con, 0)) return false;
            const def = try c.typeParamDefault(p);
            if (def != types.no_type and c.ts.kind(def) != .type_param and !try c.boundReducible(def, 0) and !try c.boundHasReducerShape(def, 0)) return false;
        }
        return true;
    }

    /// Complements `boundReducible`: a structured bound the landed reducer chain
    /// now drives home even though a static structural walk can't prove it
    /// reduces. True when the bound contains a template-literal pattern (the RHF
    /// `Path`/`FieldPath` dotted-path builder — reduced by template-hole
    /// enumeration) or a mapped type (RHF `RegisterOptions`). Such a bound makes
    /// its higher-order signature `higherOrderSigEligible`, so an instantiated
    /// generic interface method (`register`/`watch`/`setValue` on a concrete
    /// `UseFormReturn<F>`) relates its field-name literal against the reduced
    /// `Path<F>` union. A bare `infer`-over-tuple bound (redux
    /// `ExtractStoreExtensionsFromEnhancerTuple`) has neither shape and stays
    /// gated — the reducer can't peel it, so its sig keeps the pristine drop.
    fn boundHasReducerShape(c: *Checker, t: TypeId, depth: u32) Error!bool {
        if (depth > 6) return false;
        const s = &c.ts;
        switch (s.kind(t)) {
            .template_literal_type, .mapped => return true,
            .conditional => return (try c.boundHasReducerShape(s.condCheck(t), depth + 1)) or
                (try c.boundHasReducerShape(s.condExtends(t), depth + 1)) or
                (try c.boundHasReducerShape(s.condTrue(t), depth + 1)) or
                (try c.boundHasReducerShape(s.condFalse(t), depth + 1)),
            .array => return c.boundHasReducerShape(s.arrayElem(t), depth + 1),
            .tuple => {
                for (0..s.tupleLen(t)) |i| {
                    if (try c.boundHasReducerShape(s.tupleElem(t, @intCast(i)).ty, depth + 1)) return true;
                }
                return false;
            },
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| {
                    if (try c.boundHasReducerShape(m, depth + 1)) return true;
                }
                return false;
            },
            .keyof_op => return c.boundHasReducerShape(s.keyofOperand(t), depth + 1),
            .index_access => return (try c.boundHasReducerShape(s.indexAccessObj(t), depth + 1)) or
                (try c.boundHasReducerShape(s.indexAccessIndex(t), depth + 1)),
            .ref => {
                const sym = s.refSymbol(t);
                for (s.refArgs(t)) |a| {
                    if (try c.boundHasReducerShape(a, depth + 1)) return true;
                }
                if (c.symFlags(sym).type_alias) {
                    return c.boundHasReducerShape(try c.aliasGeneric(sym), depth + 1);
                }
                return false;
            },
            else => return false,
        }
    }

    /// Whether an own-param *bound* (constraint/default) reduces once its
    /// enclosing generic is substituted — the gate for whether a higher-order
    /// sig is safe to rewrite (M20a). A *bare* bound is handled elsewhere; this
    /// judges structured bounds. A plain conditional (`DBTypes extends DBSchema
    /// ? … : …`, idb) or `keyof T` reduces once its check type is concrete and
    /// is eligible. A bound whose evaluation needs recursive peeling ztsc can't
    /// perform — a template-literal pattern (`${infer K}.${infer R}`, RHF
    /// `Path`) or an `infer`-bearing conditional (redux
    /// `ExtractStoreExtensionsFromEnhancerTuple`) — is not. Alias refs are
    /// expanded (depth-capped; the cap trips to *not reducible*, the safe side,
    /// so a deep recursive alias like `Path` is excluded).
    fn boundReducible(c: *Checker, t: TypeId, depth: u32) Error!bool {
        if (depth > 6) return false;
        const s = &c.ts;
        switch (s.kind(t)) {
            .template_literal_type, .string_mapping, .infer_var, .mapped => return false,
            .conditional => {
                // An `infer` in the extends clause means the bound is peeled
                // structurally (recursive tuple/string walks ztsc can't do).
                if (try c.containsInfer(s.condExtends(t))) return false;
                return (try c.boundReducible(s.condCheck(t), depth + 1)) and
                    (try c.boundReducible(s.condExtends(t), depth + 1)) and
                    (try c.boundReducible(s.condTrue(t), depth + 1)) and
                    (try c.boundReducible(s.condFalse(t), depth + 1));
            },
            .array => return c.boundReducible(s.arrayElem(t), depth + 1),
            .tuple => {
                for (0..s.tupleLen(t)) |i| {
                    if (!try c.boundReducible(s.tupleElem(t, @intCast(i)).ty, depth + 1)) return false;
                }
                return true;
            },
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| {
                    if (!try c.boundReducible(m, depth + 1)) return false;
                }
                return true;
            },
            .keyof_op => return c.boundReducible(s.keyofOperand(t), depth + 1),
            .index_access => return (try c.boundReducible(s.indexAccessObj(t), depth + 1)) and
                (try c.boundReducible(s.indexAccessIndex(t), depth + 1)),
            .ref => {
                // Expand a type-alias ref to inspect its body (`FieldPath<T>` →
                // `Path<T>` → the template/infer core). Interface/class refs are
                // structural objects — reducible, no expansion needed. Also check
                // the ref's own type arguments.
                const sym = s.refSymbol(t);
                for (s.refArgs(t)) |a| {
                    if (!try c.boundReducible(a, depth + 1)) return false;
                }
                if (c.symFlags(sym).type_alias) {
                    return c.boundReducible(try c.aliasGeneric(sym), depth + 1);
                }
                return true;
            },
            else => return true,
        }
    }

    /// Whether an object call/construct signature `sig` references a type param
    /// bound *outside* itself — structurally (excluding its own `<...>`), or
    /// through one of its own params' constraint/default (`<U extends C<T>>`,
    /// where `T` is the enclosing generic's param). Such a signature must be
    /// (re-)instantiated with the enclosing generic; one that mentions only its
    /// own params is self-contained. `bound` is the enclosing type-param scope.
    /// A higher-order sig that is not `higherOrderSigEligible` is treated as
    /// self-contained (returns false) so instantiation skips it — the pristine,
    /// pre-rewrite behavior.
    fn sigReferencesOuterParam(c: *Checker, sig: TypeId, bound: []const u32) Error!bool {
        const own = c.ts.fnTypeParams(sig);
        if (own.len != 0 and !try c.higherOrderSigEligible(sig)) return false;
        if (try c.containsFreeTypeParam(sig, bound)) return true;
        if (own.len == 0) return false;
        // Inside the sig, both the enclosing scope and the sig's own params are
        // bound; a constraint/default reaching anything else is an outer ref.
        var scope: std.ArrayList(u32) = .empty;
        defer scope.deinit(c.scratch());
        try scope.appendSlice(c.scratch(), bound);
        try scope.appendSlice(c.scratch(), own);
        for (own) |p| {
            const con = try c.typeParamConstraint(p);
            if (con != types.no_type and try c.containsFreeTypeParam(con, scope.items)) return true;
            const def = try c.typeParamDefault(p);
            if (def != types.no_type and try c.containsFreeTypeParam(def, scope.items)) return true;
        }
        return false;
    }

    fn containsTypeParam(c: *Checker, t: TypeId) Error!bool {
        if (c.ctp_cache.get(t)) |v| {
            if (v != 0) return v == 2;
        }
        try c.ctp_cache.put(c.ca(), t, 1); // assume no while computing (cycles)
        const result = try c.containsTypeParamInner(t);
        try c.ctp_cache.put(c.ca(), t, if (result) 2 else 1);
        return result;
    }

    fn containsTypeParamInner(c: *Checker, t: TypeId) Error!bool {
        const s = &c.ts;
        switch (s.kind(t)) {
            .type_param => return true,
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| {
                    if (try c.containsTypeParam(m)) return true;
                }
                return false;
            },
            .array => return c.containsTypeParam(s.arrayElem(t)),
            .tuple => {
                for (0..s.tupleLen(t)) |i| {
                    if (try c.containsTypeParam(s.tupleElem(t, @intCast(i)).ty)) return true;
                }
                return false;
            },
            .object => {
                for (0..s.objectPropCount(t)) |i| {
                    if (try c.containsTypeParam(s.objectProp(t, @intCast(i)).ty)) return true;
                }
                if (s.objectStringIndex(t) != 0 and try c.containsTypeParam(s.objectStringIndex(t))) return true;
                if (s.objectNumberIndex(t) != 0 and try c.containsTypeParam(s.objectNumberIndex(t))) return true;
                // A call/construct signature may reference a type param that
                // appears nowhere else (a callable interface whose only generic
                // use is its signature, e.g. `interface B<T,Y> { (...a:Y):T }`);
                // without this the object is judged concrete and instantiation
                // skips it, leaving the sig unsubstituted. A *higher-order* sig
                // (`<U extends C<T>>(…)`) counts too when it reaches the outer
                // `T` through its own param's constraint/default — the M20a
                // rewrite substitutes those, so instantiation must be triggered.
                for (0..s.objectCallSigCount(t)) |i| {
                    if (try c.sigReferencesOuterParam(s.objectCallSig(t, @intCast(i)), &.{})) return true;
                }
                for (0..s.objectConstructSigCount(t)) |i| {
                    if (try c.sigReferencesOuterParam(s.objectConstructSig(t, @intCast(i)), &.{})) return true;
                }
                return false;
            },
            .function => {
                if (try c.containsTypeParam(s.fnReturn(t))) return true;
                for (0..s.fnParamCount(t)) |i| {
                    if (try c.containsTypeParam(s.fnParam(t, @intCast(i)).ty)) return true;
                }
                // The type predicate's guarded type (`x is S`) can carry a type
                // param not present anywhere else in the signature.
                if (s.fnHasPredicate(t)) {
                    const pr = s.fnPredicate(t);
                    if (pr.ty != types.no_type and try c.containsTypeParam(pr.ty)) return true;
                }
                return false;
            },
            .ref => {
                for (s.refArgs(t)) |a| {
                    if (try c.containsTypeParam(a)) return true;
                }
                return false;
            },
            // A deferred conditional is "generic" (deferrable) iff any part
            // still mentions an *outer* type param. `infer_var` binders are not
            // type params, so they never make a conditional generic.
            .conditional => {
                if (try c.containsTypeParam(s.condCheck(t))) return true;
                if (try c.containsTypeParam(s.condExtends(t))) return true;
                if (try c.containsTypeParam(s.condTrue(t))) return true;
                if (try c.containsTypeParam(s.condFalse(t))) return true;
                return false;
            },
            .index_access => {
                if (try c.containsTypeParam(s.indexAccessObj(t))) return true;
                if (try c.containsTypeParam(s.indexAccessIndex(t))) return true;
                return false;
            },
            // A deferred mapped type needs (re-)instantiation while *any* part
            // still mentions an outer type param — the value/`as` branches as
            // well as the key set, so a `{[K in "a"]: T}` with generic `T` is
            // reached and its props substituted. Whether it *materializes* vs
            // stays deferred is decided separately (by the key set) in
            // `reduceMapped`. The `mapped_param` key is not an outer param.
            .mapped => {
                if (try c.containsTypeParam(s.mappedConstraint(t))) return true;
                if (try c.containsTypeParam(s.mappedValue(t))) return true;
                if (s.mappedAs(t) != 0 and try c.containsTypeParam(s.mappedAs(t))) return true;
                if (s.mappedSource(t) != 0 and try c.containsTypeParam(s.mappedSource(t))) return true;
                return false;
            },
            // A template-literal pattern / string-mapping is generic (deferred)
            // iff a hole / the argument still mentions an outer type param.
            .template_literal_type => {
                for (0..s.templateHoleCount(t)) |i| {
                    if (try c.containsTypeParam(s.templateHole(t, @intCast(i)))) return true;
                }
                return false;
            },
            .string_mapping => return c.containsTypeParam(s.stringMappingArg(t)),
            .keyof_op => return c.containsTypeParam(s.keyofOperand(t)),
            else => return false,
        }
    }

    /// True iff `t` mentions a *free* type parameter — one not bound by an
    /// enclosing signature's own `<...>`. Unlike `containsTypeParam`, a
    /// signature's own params are treated as bound (not free), so
    /// `{ f: <T>() => T }` reports **false**: it is a concrete object whose
    /// only type variables are locally quantified. Used to decide whether an
    /// indexed access `Obj[K]` is genuinely generic (must defer) or resolvable
    /// now — indexing/mapping over such an object must reduce eagerly, else the
    /// generic member is stranded as an unresolved `Obj["f"]` and lost.
    /// `bound` is the stack of type-param symbols currently in scope.
    fn containsFreeTypeParam(c: *Checker, t: TypeId, bound: []const u32) Error!bool {
        const s = &c.ts;
        // No enclosing signature scope and no free var found up to here: the
        // cached whole-type predicate is an exact, cheaper answer.
        if (bound.len == 0 and !try c.containsTypeParam(t)) return false;
        switch (s.kind(t)) {
            .type_param => {
                const sym = s.typeParamSymbol(t);
                for (bound) |b| {
                    if (b == sym) return false; // bound by an enclosing signature
                }
                return true;
            },
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| {
                    if (try c.containsFreeTypeParam(m, bound)) return true;
                }
                return false;
            },
            .array => return c.containsFreeTypeParam(s.arrayElem(t), bound),
            .tuple => {
                for (0..s.tupleLen(t)) |i| {
                    if (try c.containsFreeTypeParam(s.tupleElem(t, @intCast(i)).ty, bound)) return true;
                }
                return false;
            },
            .object => {
                for (0..s.objectPropCount(t)) |i| {
                    if (try c.containsFreeTypeParam(s.objectProp(t, @intCast(i)).ty, bound)) return true;
                }
                if (s.objectStringIndex(t) != 0 and try c.containsFreeTypeParam(s.objectStringIndex(t), bound)) return true;
                if (s.objectNumberIndex(t) != 0 and try c.containsFreeTypeParam(s.objectNumberIndex(t), bound)) return true;
                return false;
            },
            .function => {
                // The signature's own type params shadow within its body, so
                // extend the bound set before descending.
                const own = s.fnTypeParams(t);
                var scope_buf: std.ArrayList(u32) = .empty;
                defer scope_buf.deinit(c.scratch());
                const inner: []const u32 = if (own.len == 0) bound else blk: {
                    try scope_buf.appendSlice(c.scratch(), bound);
                    try scope_buf.appendSlice(c.scratch(), own);
                    break :blk scope_buf.items;
                };
                if (try c.containsFreeTypeParam(s.fnReturn(t), inner)) return true;
                for (0..s.fnParamCount(t)) |i| {
                    if (try c.containsFreeTypeParam(s.fnParam(t, @intCast(i)).ty, inner)) return true;
                }
                if (s.fnHasPredicate(t)) {
                    const pr = s.fnPredicate(t);
                    if (pr.ty != types.no_type and try c.containsFreeTypeParam(pr.ty, inner)) return true;
                }
                return false;
            },
            .ref => {
                for (s.refArgs(t)) |a| {
                    if (try c.containsFreeTypeParam(a, bound)) return true;
                }
                return false;
            },
            .conditional => {
                if (try c.containsFreeTypeParam(s.condCheck(t), bound)) return true;
                if (try c.containsFreeTypeParam(s.condExtends(t), bound)) return true;
                if (try c.containsFreeTypeParam(s.condTrue(t), bound)) return true;
                if (try c.containsFreeTypeParam(s.condFalse(t), bound)) return true;
                return false;
            },
            .index_access => {
                if (try c.containsFreeTypeParam(s.indexAccessObj(t), bound)) return true;
                if (try c.containsFreeTypeParam(s.indexAccessIndex(t), bound)) return true;
                return false;
            },
            .mapped => {
                if (try c.containsFreeTypeParam(s.mappedConstraint(t), bound)) return true;
                if (try c.containsFreeTypeParam(s.mappedValue(t), bound)) return true;
                if (s.mappedAs(t) != 0 and try c.containsFreeTypeParam(s.mappedAs(t), bound)) return true;
                if (s.mappedSource(t) != 0 and try c.containsFreeTypeParam(s.mappedSource(t), bound)) return true;
                return false;
            },
            .template_literal_type => {
                for (0..s.templateHoleCount(t)) |i| {
                    if (try c.containsFreeTypeParam(s.templateHole(t, @intCast(i)), bound)) return true;
                }
                return false;
            },
            .string_mapping => return c.containsFreeTypeParam(s.stringMappingArg(t), bound),
            .keyof_op => return c.containsFreeTypeParam(s.keyofOperand(t), bound),
            else => return false,
        }
    }

    fn tpLookup(map: []const TpMap, sym: SymbolId) ?TypeId {
        for (map) |m| {
            if (m.sym == sym) return m.ty;
        }
        return null;
    }

    /// Canonicalize a substitution map to a stable small id: sort the
    /// `(sym, arg)` pairs and intern the packed bytes. Two maps with the same
    /// `(sym → arg)` set (regardless of slice order or identity) get the same
    /// id, so the id keys the instantiate memo soundly. Called once per
    /// top-level `instantiate`; the id is threaded down the recursion unchanged.
    fn canonMapId(c: *Checker, map: []const TpMap) Error!u32 {
        const sorted = try c.scratch().dupe(TpMap, map);
        std.mem.sort(TpMap, sorted, {}, struct {
            fn lt(_: void, a: TpMap, b: TpMap) bool {
                return a.sym < b.sym;
            }
        }.lt);
        // Pack each pair as two little-endian u32 words (8 bytes/pair).
        const bytes = try c.scratch().alloc(u8, sorted.len * 8);
        for (sorted, 0..) |m, i| {
            std.mem.writeInt(u32, bytes[i * 8 ..][0..4], m.sym, .little);
            std.mem.writeInt(u32, bytes[i * 8 + 4 ..][0..4], m.ty, .little);
        }
        const gop = try c.inst_map_ids.getOrPut(c.ca(), bytes);
        if (!gop.found_existing) {
            gop.key_ptr.* = try c.ca().dupe(u8, bytes); // scratch is reset per stmt
            gop.value_ptr.* = c.inst_map_next;
            c.inst_map_next += 1;
            c.stats.inst_maps += 1;
        }
        return gop.value_ptr.*;
    }

    /// True for a fresh higher-order type-param symbol (`fresh_tp_ids`).
    inline fn isFreshTp(c: *const Checker, sym: SymbolId) bool {
        return c.fresh_tp_base != 0 and sym >= c.fresh_tp_base;
    }

    /// Bounds record for a fresh higher-order type-param symbol.
    fn freshTp(c: *const Checker, sym: SymbolId) *const FreshTp {
        return &c.fresh_tp_info.items[sym - c.fresh_tp_base];
    }

    /// Mint (or reuse) a fresh symbol for own type-param `orig` when a
    /// signature is instantiated under `map` (canonical id `map_id`, computed
    /// on demand when memoization is off). The fresh symbol carries the
    /// already-`map`-substituted `constraint`/`default`. Deterministic and
    /// memoized per `(orig, canonical map)`, so a repeat instantiation reuses
    /// the same id (interning coherence).
    fn mintFreshTp(c: *Checker, orig: SymbolId, map: []const TpMap, map_id: ?u32, constraint: TypeId, default: TypeId, has_default: bool) Error!u32 {
        const mid: u32 = map_id orelse try c.canonMapId(map);
        const key = (@as(u64, orig) << 32) | mid;
        const gop = try c.fresh_tp_ids.getOrPut(c.ca(), key);
        if (!gop.found_existing) {
            gop.value_ptr.* = c.fresh_tp_next;
            c.fresh_tp_next += 1;
            try c.fresh_tp_info.append(c.ca(), .{
                .name = c.symNameAtom(orig),
                .constraint = constraint,
                .default = default,
                .has_default = has_default,
            });
        }
        return gop.value_ptr.*;
    }

    /// Substitute the type parameters in `map` throughout `t`. Public entry:
    /// canonicalizes the map (when caching is on) and dispatches to the
    /// memoized recursive walk.
    fn instantiate(c: *Checker, t: TypeId, map: []const TpMap) Error!TypeId {
        if (map.len == 0) return t;
        if (!try c.containsTypeParam(t)) return t;
        // At the outermost substitution, route every transient allocation the
        // call tree makes (worklists in `instantiateId`, the reduction helpers'
        // scratch, `makeUnion`/`makeObject` temporaries) into `inst_arena` by
        // swapping it in for `scratch_arena`, then release it on exit. This
        // bounds the per-statement scratch high-water to the single largest
        // instantiation rather than the sum of every one a statement performs
        // (a JSX return that materializes many generic component props spiked
        // the old shared arena to ~130 MB and it stuck for the process).
        // Safe because the tree keeps nothing past its own return: the result
        // is interned into `ts`, and any persistent key is copied into `carena`
        // (`canonMapId`/`mintFreshTp`) or the permanent output arena
        // (`diagFmt`) — the same discipline that already lets scratch reset per
        // statement. The swap is restored (and the arena released) on every
        // exit including errors, so `scratch_arena` is the shared arena
        // everywhere outside a top-level `instantiate`.
        if (c.inst_depth == 0) {
            // Reset the truncation flag at each top-level entry so a limit trip
            // in one instantiation never suppresses caching of the next.
            c.inst_limit_tripped = false;
            const saved = c.scratch_arena;
            c.scratch_arena = c.inst_arena;
            defer {
                const cap = c.inst_arena.queryCapacity();
                if (cap > c.stats.scratch_high_water) c.stats.scratch_high_water = cap;
                _ = c.inst_arena.reset(.{ .retain_with_limit = scratch_retain_limit });
                c.scratch_arena = saved;
            }
            const map_id: ?u32 = if (c.inst_cache_on) try c.canonMapId(map) else null;
            return c.instantiateId(t, map, map_id);
        }
        const map_id: ?u32 = if (c.inst_cache_on) try c.canonMapId(map) else null;
        return c.instantiateId(t, map, map_id);
    }

    /// Record the origin of a re-instantiated generic materialization without
    /// charging the substitution of its origin args against the shared
    /// instantiation budget (`inst_count`/`inst_depth`) — pure bookkeeping must
    /// not influence whether a later, unrelated instantiation trips TS2589, nor
    /// emit a diagnostic of its own. A trip during arg substitution just yields
    /// a non-matching origin ref (safe: the reflexive fast-path simply won't
    /// fire, falling back to the structural walk).
    fn tagInstantiatedOrigin(c: *Checker, result: TypeId, orig_ref: TypeId, map: []const TpMap, map_id: ?u32) Error!void {
        const saved_count = c.inst_count;
        const saved_depth = c.inst_depth;
        const saved_trip = c.inst_limit_tripped;
        const saved_suppress = c.suppress_inst_diag;
        c.suppress_inst_diag = true;
        defer {
            c.inst_count = saved_count;
            c.inst_depth = saved_depth;
            c.inst_limit_tripped = saved_trip;
            c.suppress_inst_diag = saved_suppress;
        }
        var oargs: std.ArrayList(TypeId) = .empty;
        defer oargs.deinit(c.scratch());
        for (c.ts.refArgs(orig_ref)) |a| try oargs.append(c.scratch(), try c.instantiateId(a, map, map_id));
        const new_ref = try c.ts.makeRef(c.ts.refSymbol(orig_ref), oargs.items);
        try c.origin.put(c.ca(), result, new_ref);
    }

    /// Memoized recursive substitution. `map_id` (when non-null) canonically
    /// identifies `map`; it keys the memo and is threaded unchanged down the
    /// recursion. A `null` id disables the memo (`--no-inst-cache`).
    fn instantiateId(c: *Checker, t: TypeId, map: []const TpMap, map_id: ?u32) Error!TypeId {
        if (!try c.containsTypeParam(t)) return t;
        if (map_id) |mid| {
            if (c.inst_cache.get((@as(u64, mid) << 32) | t)) |r| {
                c.stats.inst_hits += 1;
                return r;
            }
        }
        c.stats.inst_misses += 1;
        // Depth/count guard — cache-independent, so it fires identically with
        // the memo on or off. Exceeding it is TS2589 (excessively deep /
        // possibly infinite): report once at the materialization site and
        // truncate this subtree to `error_type`.
        if (c.inst_depth > max_instantiation_depth or c.inst_count > max_instantiation_count) {
            c.inst_limit_tripped = true;
            if (!c.suppress_inst_diag) try c.diagFmt(2589, c.inst_span, "Type instantiation is excessively deep and possibly infinite.", .{});
            return types.error_type;
        }
        c.inst_depth += 1;
        c.inst_count += 1;
        defer c.inst_depth -= 1;
        const s = &c.ts;
        const result: TypeId = switch (s.kind(t)) {
            .type_param => tpLookup(map, s.typeParamSymbol(t)) orelse t,
            .union_type => blk: {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiateId(m, map, map_id));
                break :blk try s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => blk: {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiateId(m, map, map_id));
                const inter = try s.makeIntersection(c.scratch(), parts.items);
                // Propagate the origin tag through instantiation of a callable-
                // object alias that materializes to a kept intersection (RTK's
                // `AsyncThunk<…>` = `AsyncThunkActionCreator<…> & {…}`): the
                // pre-expanded sig-return `t` carries `origin[t] =
                // makeRef(G, own-params)`, and the substituted result denotes
                // `G<args'…>`. Without this the two route-divergent
                // instantiations of the same alias lose all origin identity and
                // the equivalence fast-path cannot fire. Budget-shielded like the
                // object arm.
                if (c.origin.get(t)) |orig_ref| {
                    if (inter != t and c.ts.kind(inter) == .intersection) try c.tagInstantiatedOrigin(inter, orig_ref, map, map_id);
                }
                break :blk inter;
            },
            .overloads => blk: {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiateId(m, map, map_id));
                break :blk try s.makeOverloads(parts.items);
            },
            .array => try s.makeArray(try c.instantiateId(s.arrayElem(t), map, map_id)),
            .tuple => blk: {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.instantiateId(e.ty, map, map_id), .flags = e.flags });
                }
                break :blk try s.makeTuple(elems.items);
            },
            .object => blk: {
                var props: std.ArrayList(types.Prop) = .empty;
                defer props.deinit(c.scratch());
                for (0..s.objectPropCount(t)) |i| {
                    const p = s.objectProp(t, @intCast(i));
                    try props.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiateId(p.ty, map, map_id), .flags = p.flags });
                }
                const sidx = if (s.objectStringIndex(t) != 0) try c.instantiateId(s.objectStringIndex(t), map, map_id) else 0;
                const nidx = if (s.objectNumberIndex(t) != 0) try c.instantiateId(s.objectNumberIndex(t), map, map_id) else 0;
                // Call/construct signatures (M18.1) are `.function` types that
                // may mention the interface's type params (e.g. jest's
                // `Mock<T, Y, C>` call sig `(...args: Y): T`). Instantiate each
                // and preserve them via `makeObjectSigs` — dropping them here
                // (the prior `makeObject` path) made an instantiated callable
                // interface non-callable, so `Mock<any, any, any>` was not
                // assignable to any concrete function type.
                // A *higher-order* signature that declares its own type params
                // whose constraints/defaults reference the interface's params
                // (react-redux's `<AD extends DispatchType = DispatchType>(): AD`,
                // TypedUseSelectorHook's `<S>(sel:(st:TState)=>S):S`) is
                // instantiated the same way; the `.function` arm mints fresh
                // symbols for the own params, carrying the substituted
                // constraints/defaults (M20a), so the call site resolves them
                // correctly instead of stranding the interface param.
                var call_sigs: std.ArrayList(TypeId) = .empty;
                defer call_sigs.deinit(c.scratch());
                var construct_sigs: std.ArrayList(TypeId) = .empty;
                defer construct_sigs.deinit(c.scratch());
                for (0..s.objectCallSigCount(t)) |i| {
                    const sig = s.objectCallSig(t, @intCast(i));
                    // A non-eligible higher-order sig (RHF-style deep bound) is
                    // dropped — the pristine behavior — so its call sites are
                    // unchanged; eligible ones and param-free ones instantiate.
                    if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                    try call_sigs.append(c.scratch(), try c.instantiateId(sig, map, map_id));
                }
                for (0..s.objectConstructSigCount(t)) |i| {
                    const sig = s.objectConstructSig(t, @intCast(i));
                    if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                    try construct_sigs.append(c.scratch(), try c.instantiateId(sig, map, map_id));
                }
                const obj = try s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
                // Propagate the origin tag through instantiation (see `origin`):
                // if `t` is the pre-expanded materialization of `G<A…>`, the
                // instantiated result denotes `G<A'…>` with each arg substituted
                // by `map`. Bookkeeping is budget-shielded so it never trips
                // TS2589 on unrelated deep instantiations.
                if (c.origin.get(t)) |orig_ref| {
                    if (obj != t and c.ts.kind(obj) == .object) try c.tagInstantiatedOrigin(obj, orig_ref, map, map_id);
                }
                break :blk obj;
            },
            .function => blk: {
                const tps = s.fnTypeParams(t);
                // Higher-order rewrite (M20a): an own type param whose
                // constraint/default is changed by `map` (`<U extends C<T>>`
                // under `T:=…`) gets a *fresh* symbol carrying the substituted
                // bounds, and its references in the body are rewritten to it.
                // Params unaffected by `map` keep their original symbol (the
                // AST-derived constraint/default path — zero behavior change).
                var kept: std.ArrayList(u32) = .empty;
                defer kept.deinit(c.scratch());
                var fresh_map: std.ArrayList(TpMap) = .empty;
                defer fresh_map.deinit(c.scratch());
                // Mint fresh params only for an eligible sig (all own bounds
                // bare/absent); otherwise keep the original params + AST bounds
                // (the pre-rewrite behavior for standalone generic functions).
                const eligible = tps.len != 0 and map.len > 0 and try c.higherOrderSigEligible(t);
                for (tps) |tp| {
                    if (tpLookup(map, tp) != null) continue; // substituted away
                    var fresh: ?u32 = null;
                    if (eligible) {
                        const od = try c.typeParamDefault(tp);
                        const oc = try c.typeParamConstraint(tp);
                        const nd = if (od != types.no_type) try c.instantiate(od, map) else od;
                        const nc = if (oc != types.no_type) try c.instantiate(oc, map) else oc;
                        // Fresh param carries the substituted *default* (so a
                        // no-arg `<AD = DispatchType>()` resolves to the supplied
                        // dispatch). Its *constraint* is enforced only when it
                        // was a structured, reducible bound (idb `StoreName
                        // extends StoreNames<DBTypes>` → a concrete store-name
                        // union that makes `"requests"` assignable). A *bare*
                        // bound (`filter<S extends T>`) carries no constraint:
                        // it was never enforceable pre-rewrite (`bare_outer`),
                        // and enforcing its substituted form would erase a
                        // legitimate inference. Mint only when a bound moved.
                        const fc = if (oc != types.no_type and c.ts.kind(oc) != .type_param) nc else types.no_type;
                        if (nc != oc or nd != od) {
                            fresh = try c.mintFreshTp(tp, map, map_id, fc, nd, od != types.no_type);
                        }
                    }
                    if (fresh) |fid| {
                        try kept.append(c.scratch(), fid);
                        try fresh_map.append(c.scratch(), .{ .sym = tp, .ty = try s.makeTypeParam(fid) });
                    } else {
                        try kept.append(c.scratch(), tp);
                    }
                }
                // Body substitution map: the incoming map plus the fresh-param
                // rewrites. Identical to `map` when no own param was affected,
                // so non-higher-order sigs keep their exact prior behavior.
                var sub_map = map;
                var sub_id = map_id;
                if (fresh_map.items.len > 0) {
                    var em: std.ArrayList(TpMap) = .empty;
                    defer em.deinit(c.scratch());
                    try em.appendSlice(c.scratch(), map);
                    try em.appendSlice(c.scratch(), fresh_map.items);
                    sub_map = try c.scratch().dupe(TpMap, em.items);
                    sub_id = if (c.inst_cache_on) try c.canonMapId(sub_map) else null;
                }
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiateId(p.ty, sub_map, sub_id), .flags = p.flags });
                }
                const ret = try c.instantiateId(s.fnReturn(t), sub_map, sub_id);
                // Preserve the type predicate (`x is S`) through instantiation,
                // substituting its guarded type (`S` → arg). Dropping it (the
                // prior behavior) erased the guard on real-lib overloads like
                // `filter<S extends T>(p: (v: T) => v is S): S[]`, so a plain
                // boolean predicate spuriously matched the type-guard overload.
                // The `this` type is likewise preserved and instantiated.
                const pred: ?types.Predicate = if (s.fnHasPredicate(t)) blk_p: {
                    const pr = s.fnPredicate(t);
                    break :blk_p types.Predicate{
                        .param = pr.param,
                        .asserts = pr.asserts,
                        .ty = if (pr.ty != types.no_type) try c.instantiateId(pr.ty, sub_map, sub_id) else pr.ty,
                    };
                } else null;
                const this_ty = s.fnThisType(t);
                const fnres = try s.makeFunctionThis(params.items, ret, kept.items, s.fnFlags(t), pred, if (this_ty != 0) try c.instantiateId(this_ty, sub_map, sub_id) else 0);
                // Propagate the origin tag through function instantiation (see
                // the `.object` arm) — an aliased function member such as RHF's
                // `UseFormClearErrors<T>` relates by identity across builds.
                if (c.origin.get(t)) |orig_ref| {
                    if (fnres != t and c.ts.kind(fnres) == .function) try c.tagInstantiatedOrigin(fnres, orig_ref, map, map_id);
                }
                break :blk fnres;
            },
            .ref => blk: {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.instantiateId(a, map, map_id));
                break :blk try s.makeRef(s.refSymbol(t), args.items);
            },
            .conditional => blk: {
                const check0 = s.condCheck(t);
                // Distribution: a naked type-param check distributes over a
                // union member-wise, re-binding that param per member so the
                // branches reflect each member (not the whole union).
                if (s.condDistributive(t) and s.kind(check0) == .type_param) {
                    const new_check = try c.instantiateId(check0, map, map_id);
                    if (s.kind(new_check) == .never) break :blk types.never_type;
                    if (s.kind(new_check) == .union_type) {
                        const csym = s.typeParamSymbol(check0);
                        var parts: std.ArrayList(TypeId) = .empty;
                        defer parts.deinit(c.scratch());
                        for (try c.memberList(new_check)) |m| {
                            const m2 = try c.mapWith(map, csym, m);
                            try parts.append(c.scratch(), try c.instantiate(t, m2));
                        }
                        break :blk try s.makeUnion(c.scratch(), parts.items);
                    }
                }
                const chk = try c.instantiateId(check0, map, map_id);
                const ext = try c.instantiateId(s.condExtends(t), map, map_id);
                const tru = try c.instantiateId(s.condTrue(t), map, map_id);
                const fls = try c.instantiateId(s.condFalse(t), map, map_id);
                break :blk try c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
            },
            .index_access => blk: {
                const obj = try c.instantiateId(s.indexAccessObj(t), map, map_id);
                const idx = try c.instantiateId(s.indexAccessIndex(t), map, map_id);
                break :blk try c.reduceIndexedAccess(obj, idx);
            },
            .mapped => blk: {
                const kp = s.mappedKeyParam(t); // key param identity is stable
                const con = try c.instantiateId(s.mappedConstraint(t), map, map_id);
                const val = try c.instantiateId(s.mappedValue(t), map, map_id);
                const as_c = if (s.mappedAs(t) != 0) try c.instantiateId(s.mappedAs(t), map, map_id) else 0;
                const src = if (s.mappedSource(t) != 0) try c.instantiateId(s.mappedSource(t), map, map_id) else 0;
                break :blk try c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
            },
            .template_literal_type => blk: {
                var holes: std.ArrayList(TypeId) = .empty;
                defer holes.deinit(c.scratch());
                for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.instantiateId(s.templateHole(t, @intCast(i)), map, map_id));
                break :blk try c.reduceTemplate(s.templateHead(t), holes.items, t);
            },
            .string_mapping => blk: {
                const arg = try c.instantiateId(s.stringMappingArg(t), map, map_id);
                break :blk try c.applyStringMapping(s.stringMappingKind(t), arg);
            },
            .keyof_op => blk: {
                const op = try c.instantiateId(s.keyofOperand(t), map, map_id);
                break :blk try c.keyofType(op);
            },
            else => t,
        };
        // Memoize only when nothing below tripped the limit (a truncated result
        // is depth-dependent, not a pure function of `(t, map)`).
        if (map_id) |mid| {
            if (!c.inst_limit_tripped) try c.inst_cache.put(c.ca(), (@as(u64, mid) << 32) | t, result);
        }
        return result;
    }

    /// Replace every polymorphic `this` marker in `t` with `repl` (the concrete
    /// receiver at a property access). Gated by `has_this_types`, so it is a
    /// no-op cost for programs that never declare a `this`-return.
    fn substThis(c: *Checker, t: TypeId, repl: TypeId) Error!TypeId {
        if (!c.has_this_types) return t;
        if (!c.containsThisType(t)) return t;
        if (c.inst_depth > max_instantiation_depth) return types.error_type;
        c.inst_depth += 1;
        defer c.inst_depth -= 1;
        const s = &c.ts;
        switch (s.kind(t)) {
            .this_type => return repl,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
                return s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
                return s.makeIntersection(c.scratch(), parts.items);
            },
            .overloads => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
                return s.makeOverloads(parts.items);
            },
            .array => return s.makeArray(try c.substThis(s.arrayElem(t), repl)),
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.substThis(e.ty, repl), .flags = e.flags });
                }
                return s.makeTuple(elems.items);
            },
            .function => {
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substThis(p.ty, repl), .flags = p.flags });
                }
                const ret = try c.substThis(s.fnReturn(t), repl);
                const this_ty = s.fnThisType(t);
                const pred: ?types.Predicate = if (s.fnHasPredicate(t)) s.fnPredicate(t) else null;
                return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), pred, this_ty);
            },
            .ref => {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substThis(a, repl));
                return s.makeRef(s.refSymbol(t), args.items);
            },
            else => return t,
        }
    }

    fn containsThisType(c: *Checker, t: TypeId) bool {
        const s = &c.ts;
        return switch (s.kind(t)) {
            .this_type => true,
            .array => c.containsThisType(s.arrayElem(t)),
            .union_type, .intersection, .overloads => blk: {
                for (s.members(t)) |m| {
                    if (c.containsThisType(m)) break :blk true;
                }
                break :blk false;
            },
            .tuple => blk: {
                for (0..s.tupleLen(t)) |i| {
                    if (c.containsThisType(s.tupleElem(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .function => blk: {
                if (c.containsThisType(s.fnReturn(t))) break :blk true;
                for (0..s.fnParamCount(t)) |i| {
                    if (c.containsThisType(s.fnParam(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .ref => blk: {
                for (s.refArgs(t)) |a| {
                    if (c.containsThisType(a)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    // =====================================================================
    // conditional types + `infer` (M16a)
    // =====================================================================

    fn mapWith(c: *Checker, map: []const TpMap, sym: SymbolId, ty: TypeId) Error![]TpMap {
        var list: std.ArrayList(TpMap) = .empty;
        var found = false;
        for (map) |m| {
            if (m.sym == sym) {
                try list.append(c.scratch(), .{ .sym = sym, .ty = ty });
                found = true;
            } else try list.append(c.scratch(), m);
        }
        if (!found) try list.append(c.scratch(), .{ .sym = sym, .ty = ty });
        return list.items;
    }

    /// Dense, stable id for an `infer V` binder in conditional `cond`
    /// (a nodeKey). Same (conditional, name) → same id.
    fn inferVarId(c: *Checker, cond: u64, name: Atom) Error!u32 {
        const gop = try c.infer_ids.getOrPut(c.ca(), .{ .cond = cond, .name = name });
        if (!gop.found_existing) {
            gop.value_ptr.* = c.infer_next;
            c.infer_next += 1;
        }
        return gop.value_ptr.*;
    }

    fn inferVarFromNode(c: *Checker, node: Node) Error!TypeId {
        const name = try c.atomOfToken(c.tree.nodeData(node).lhs);
        if (c.infer_scopes.items.len == 0) {
            try c.diagFmt(1338, c.nodeSpan(node), "'infer' declarations are only permitted in the 'extends' clause of a conditional type.", .{});
            return types.any_type;
        }
        // An `infer V` binder belongs to the immediately-enclosing conditional
        // (top of the scope stack) — its extends clause is where it is declared.
        const id = try c.inferVarId(c.infer_scopes.items[c.infer_scopes.items.len - 1], name);
        return c.ts.makeInferVar(id, name);
    }

    fn conditionalTypeFromNode(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const e = c.tree.extraData(ast.ConditionalType, d.rhs);
        const chk = try c.typeFromTypeNode(d.lhs);
        // The extends + true branches share this conditional's infer scope; the
        // false branch does not (infer binders are scoped to the true branch).
        // Push onto the scope stack (rather than overwrite) so a nested
        // conditional inside the true branch still resolves this conditional's
        // infer vars — the check clause above was already evaluated under the
        // enclosing scopes only.
        try c.infer_scopes.append(c.ca(), c.nodeKey(node));
        const extends_ty = try c.typeFromTypeNode(e.extends_type);
        const true_ty = try c.typeFromTypeNode(e.true_type);
        _ = c.infer_scopes.pop();
        const false_ty = try c.typeFromTypeNode(e.false_type);
        // Distributivity is a property of a *naked type-parameter* check. A
        // naked `infer` var (e.g. `F extends (...)=>any` inside Awaited, where
        // F is captured by an enclosing conditional) behaves the same way: once
        // F resolves to a union like `fn | undefined | null`, the branches must
        // reflect each member.
        const chk_k = c.ts.kind(chk);
        const distributive = chk_k == .type_param or chk_k == .infer_var;
        return c.reduceConditional(chk, extends_ty, true_ty, false_ty, distributive);
    }

    /// The single evaluation point for a conditional, used at build time and
    /// on each instantiation: defer while a check/extends is still generic,
    /// otherwise resolve concretely. Distribution over a naked-param union is
    /// handled by `instantiateId` (it holds the substitution map needed to
    /// re-bind the param per member). Counts against the TS2589 depth/count
    /// budget so a self-referential conditional terminates.
    fn reduceConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
        if (c.inst_depth > max_instantiation_depth or c.inst_count > max_instantiation_count) {
            c.inst_limit_tripped = true;
            if (!c.suppress_inst_diag) try c.diagFmt(2589, c.inst_span, "Type instantiation is excessively deep and possibly infinite.", .{});
            return types.error_type;
        }
        c.inst_depth += 1;
        c.inst_count += 1;
        defer c.inst_depth -= 1;
        const s = &c.ts;
        // A naked `infer`-var check belongs to an *enclosing* conditional's
        // inference (`F extends (...)=>any` inside Awaited, where F is captured
        // by the outer `then(onfulfilled: infer F,...)` conditional). It is not
        // yet bound during instantiateId of the enclosing true branch; keep it
        // symbolic so substInfer re-enters here once F resolves. Without this,
        // it would relate against an unbound infer var and collapse to `never`.
        if (s.kind(chk) == .infer_var) {
            return s.makeConditional(chk, extends_ty, true_ty, false_ty, distributive);
        }
        // Distribute a distributive conditional over a concrete union check
        // member-wise (the naked check resolved, via substInfer, to a union
        // like `fn | undefined | null`). Each member is inferred independently
        // and the results unioned — this is what lets Awaited pick the callable
        // `then` argument out of its `| undefined | null`.
        if (distributive and s.kind(chk) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(chk)) |m| {
                // A distributive conditional's true/false branch may BE the
                // check type (`T extends U ? never : T` = Exclude, `? T :
                // never` = Extract). When the naked-type-param distribution in
                // `instantiateId` was bypassed — because the instantiated check
                // is not a naked param but a `keyof X` / indexed access that
                // resolved to this union (the `Omit`/`Exclude<keyof T, K>`
                // composition) — the branch was baked to the WHOLE union
                // instead of the per-member value. Rebind a branch that IS the
                // check to the current member so `Omit<T, K>` actually strips
                // the excluded keys. A branch that doesn't reference the check
                // (e.g. `never`) is untouched, so ordinary distributions
                // (Awaited) are unchanged.
                const tru_m = if (true_ty == chk) m else true_ty;
                const fls_m = if (false_ty == chk) m else false_ty;
                try parts.append(c.scratch(), try c.reduceConditional(m, extends_ty, tru_m, fls_m, false));
            }
            return s.makeUnion(c.scratch(), parts.items);
        }
        // Defer while a mapped key parameter is still unbound (M16b): a
        // conditional in a mapped type's `as`/value branch (`P extends K ?
        // never : P`) must stay symbolic until each key is materialized, or it
        // would resolve against the still-abstract `mapped_param`.
        // A check/extends type whose only type variables are bound within a
        // member signature (`{ f: <T>() => T } extends ...`) is concrete for
        // resolution purposes, so the *free* type-param test gates deferral.
        const ext_generic = try c.containsFreeTypeParam(extends_ty, &.{}) or try c.containsMappedParam(extends_ty);
        const chk_generic = try c.containsFreeTypeParam(chk, &.{}) or try c.containsMappedParam(chk);
        if (chk_generic or ext_generic) {
            // Narrow decidability carve-out (see objectDecidablyNotExtends): a
            // concrete-shaped object check whose free params live only in
            // property values has a fixed shape. When the target is decidable
            // from that shape alone, the false branch holds for every
            // substitution, so resolve rather than defer into a conditional
            // that can never relate (e.g. Awaited<{ data: P }> → { data: P }).
            if (!ext_generic and s.kind(chk) == .object and try c.objectDecidablyNotExtends(chk, extends_ty)) {
                return false_ty;
            }
            // A concrete *function* check (`(value: number) => Promise<R> | R`
            // with a free `R` only in the return) is likewise non-instantiable:
            // its relation to a function pattern is decided by its parameter
            // shape, and free params in the return flow into the pattern's
            // (`… => any`) return harmlessly. Resolve it rather than deferring —
            // this is what lets Awaited unwrap a real Promise's `then` callback
            // without erasing the method's own `TResult` params.
            if (!ext_generic and s.kind(chk) == .function and s.kind(try c.resolveStructural(extends_ty)) == .function) {
                return c.resolveConcreteConditional(chk, extends_ty, true_ty, false_ty);
            }
            return s.makeConditional(chk, extends_ty, true_ty, false_ty, distributive);
        }
        return c.resolveConcreteConditional(chk, extends_ty, true_ty, false_ty);
    }

    fn resolveConcreteConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId) Error!TypeId {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(c.scratch());
        try c.collectInferVars(extends_ty, &ids);
        // `any` as the check type takes *both* branches (tsc): infer vars bind
        // `any`, and the result is trueBranch | falseBranch. This is what makes
        // `Awaited<any>` collapse to `any` instead of surviving as a deferred
        // conditional that poisons downstream inference.
        if (c.ts.kind(chk) == .any) {
            const any_vals = try c.scratch().alloc(TypeId, ids.items.len);
            for (any_vals) |*v| v.* = types.any_type;
            const t = try c.substInfer(true_ty, ids.items, any_vals);
            return c.makeUnion2(t, false_ty);
        }
        const vals = try c.scratch().alloc(TypeId, ids.items.len);
        for (vals) |*v| v.* = types.no_type;
        if (ids.items.len > 0) {
            try c.inferFromExtends(chk, extends_ty, ids.items, vals, false, 0);
            for (vals) |*v| {
                if (v.* == types.no_type) v.* = types.unknown_type; // unmatched → unknown
            }
        }
        const resolved_extends = try c.substInfer(extends_ty, ids.items, vals);
        if (try c.isAssignable(chk, resolved_extends)) {
            return c.substInfer(true_ty, ids.items, vals);
        }
        return false_ty; // infer binders are out of scope in the false branch
    }

    /// Narrow decidability rule for a deferred conditional whose *check* is a
    /// concrete-shaped object literal (`{ data: P }`) carrying free type params
    /// only in property VALUES. Such a check has a fixed shape, so some
    /// `extends` targets are decidable for every substitution of those params.
    /// Returns true when the object *definitely does not* satisfy `extends_ty`
    /// (the conditional then takes its false branch) — the only direction we
    /// resolve, since a "true" match could hinge on a value type that depends
    /// on the free params. Kept deliberately shape-only:
    ///   * an object is never `null`/`undefined` (Awaited's outer branch);
    ///   * an object lacking a required member NAME is not assignable to a
    ///     structural target that requires it (Awaited's `then` branch).
    /// Anything else stays deferred (return false).
    fn objectDecidablyNotExtends(c: *Checker, chk_obj: TypeId, extends_ty: TypeId) Error!bool {
        const s = &c.ts;
        const ext = try c.resolveStructural(extends_ty);
        switch (s.kind(ext)) {
            .null, .undefined => return true,
            .union_type => {
                // Decidable only if the whole target is null/undefined-shaped.
                for (try c.memberList(ext)) |m| {
                    const mk = s.kind(try c.resolveStructural(m));
                    if (mk != .null and mk != .undefined) return false;
                }
                return true;
            },
            .object, .intersection => {
                // A missing required member name is decidable regardless of the
                // free params — but only when no index signature could supply
                // it. If every required name is present, the value types may
                // depend on the params, so stay deferred.
                if (s.objectStringIndex(chk_obj) != 0 or s.objectNumberIndex(chk_obj) != 0) return false;
                const members: []const TypeId = if (s.kind(ext) == .intersection) try c.memberList(ext) else &.{ext};
                for (members) |mem| {
                    if (s.kind(mem) != .object) continue;
                    for (0..s.objectPropCount(mem)) |i| {
                        const p = s.objectProp(mem, @intCast(i));
                        if (p.optional()) continue;
                        if (s.objectPropByName(chk_obj, p.name) == null) return true; // required name absent
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    fn indexOfId(ids: []const u32, id: u32) ?usize {
        for (ids, 0..) |x, i| {
            if (x == id) return i;
        }
        return null;
    }

    fn indexOfAtom(atoms: []const Atom, needle: Atom) ?usize {
        for (atoms, 0..) |x, i| {
            if (x == needle) return i;
        }
        return null;
    }

    fn collectInferVars(c: *Checker, t: TypeId, out: *std.ArrayList(u32)) Error!void {
        const s = &c.ts;
        switch (s.kind(t)) {
            .infer_var => {
                const id = s.inferVarId(t);
                if (indexOfId(out.items, id) == null) try out.append(c.scratch(), id);
            },
            .array => try c.collectInferVars(s.arrayElem(t), out),
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| try c.collectInferVars(m, out);
            },
            .tuple => {
                for (0..s.tupleLen(t)) |i| try c.collectInferVars(s.tupleElem(t, @intCast(i)).ty, out);
            },
            .object => {
                for (0..s.objectPropCount(t)) |i| try c.collectInferVars(s.objectProp(t, @intCast(i)).ty, out);
                if (s.objectStringIndex(t) != 0) try c.collectInferVars(s.objectStringIndex(t), out);
                if (s.objectNumberIndex(t) != 0) try c.collectInferVars(s.objectNumberIndex(t), out);
                // Call/construct signatures carry infer vars too (`new (x: infer
                // P) => …`, a `JSXElementConstructor` construct constituent).
                for (0..s.objectCallSigCount(t)) |i| try c.collectInferVars(s.objectCallSig(t, @intCast(i)), out);
                for (0..s.objectConstructSigCount(t)) |i| try c.collectInferVars(s.objectConstructSig(t, @intCast(i)), out);
            },
            .function => {
                for (0..s.fnParamCount(t)) |i| try c.collectInferVars(s.fnParam(t, @intCast(i)).ty, out);
                try c.collectInferVars(s.fnReturn(t), out);
            },
            .ref => {
                for (try c.refArgsList(t)) |a| try c.collectInferVars(a, out);
            },
            .template_literal_type => {
                for (0..s.templateHoleCount(t)) |i| try c.collectInferVars(s.templateHole(t, @intCast(i)), out);
            },
            .string_mapping => try c.collectInferVars(s.stringMappingArg(t), out),
            .keyof_op => try c.collectInferVars(s.keyofOperand(t), out),
            else => {},
        }
    }

    /// Infer `infer` binders by structurally matching a concrete `source`
    /// against the `pattern` (the extends clause). `contra` flips the
    /// same-name combine rule (union in covariant positions, intersection in
    /// contravariant/function-parameter positions).
    fn inferFromExtends(c: *Checker, source0: TypeId, pattern: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
        if (depth > 24) return;
        const s = &c.ts;
        switch (s.kind(pattern)) {
            .infer_var => {
                const idx = indexOfId(ids, s.inferVarId(pattern)) orelse return;
                if (vals[idx] == types.no_type) {
                    vals[idx] = source0;
                } else if (contra) {
                    vals[idx] = try c.ts.makeIntersection(c.scratch(), &.{ vals[idx], source0 });
                } else {
                    vals[idx] = try c.makeUnion2(vals[idx], source0);
                }
            },
            .array => {
                const src = try c.resolveStructural(source0);
                switch (s.kind(src)) {
                    .array => try c.inferFromExtends(s.arrayElem(src), s.arrayElem(pattern), ids, vals, contra, depth + 1),
                    .tuple => {
                        for (0..s.tupleLen(src)) |i|
                            try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.arrayElem(pattern), ids, vals, contra, depth + 1);
                    },
                    else => {},
                }
            },
            .tuple => {
                const src = try c.resolveStructural(source0);
                if (s.kind(src) != .tuple) return;
                const plen = s.tupleLen(pattern);
                const slen = s.tupleLen(src);
                // Locate the (at most one, per the TS grammar) rest element in
                // the pattern. `[infer H, ...infer R]` must bind R to the rest
                // *tuple* — not to the first rest element (the pre-fix bug):
                // positional `@min` matching aliased `...infer R` onto src[k].
                var rest_idx: ?u32 = null;
                for (0..plen) |i| {
                    if (s.tupleElem(pattern, @intCast(i)).rest()) {
                        rest_idx = @intCast(i);
                        break;
                    }
                }
                if (rest_idx == null) {
                    const n = @min(slen, plen);
                    for (0..n) |i|
                        try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.tupleElem(pattern, @intCast(i)).ty, ids, vals, contra, depth + 1);
                    return;
                }
                const ri = rest_idx.?;
                const suffix = plen - ri - 1; // fixed pattern elements after the rest
                if (slen < ri + suffix) return; // source too short: no valid match
                // Prefix: pattern[0..ri] positionally against src[0..ri].
                for (0..ri) |i|
                    try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.tupleElem(pattern, @intCast(i)).ty, ids, vals, contra, depth + 1);
                // Suffix: pattern[ri+1..] positionally against the src tail.
                for (0..suffix) |j|
                    try c.inferFromExtends(s.tupleElem(src, @intCast(slen - suffix + j)).ty, s.tupleElem(pattern, @intCast(ri + 1 + j)).ty, ids, vals, contra, depth + 1);
                // Rest: pattern[ri] captures the middle src[ri..slen-suffix] as a
                // tuple. `...infer R` stores the infer var directly as the
                // element type → bind R to that middle tuple; `...(infer U)[]`
                // binds U from each middle element; anything else recurses
                // structurally against the reconstructed middle tuple.
                const rest_pat = s.tupleElem(pattern, ri).ty;
                var mid: std.ArrayList(types.TupleElem) = .empty;
                defer mid.deinit(c.scratch());
                var k: u32 = ri;
                while (k < slen - suffix) : (k += 1) {
                    const e = s.tupleElem(src, k);
                    try mid.append(c.scratch(), .{ .ty = e.ty, .flags = e.flags });
                }
                const mid_tuple = try s.makeTuple(mid.items);
                if (s.kind(rest_pat) == .array) {
                    for (mid.items) |me|
                        try c.inferFromExtends(me.ty, s.arrayElem(rest_pat), ids, vals, contra, depth + 1);
                } else {
                    try c.inferFromExtends(mid_tuple, rest_pat, ids, vals, contra, depth + 1);
                }
            },
            .ref => {
                const src = try c.resolveStructural(source0);
                if (s.kind(source0) == .ref and s.refSymbol(source0) == s.refSymbol(pattern)) {
                    const pa = try c.scratch().dupe(TypeId, s.refArgs(pattern));
                    const aa = try c.scratch().dupe(TypeId, s.refArgs(source0));
                    const n = @min(pa.len, aa.len);
                    for (0..n) |i| try c.inferFromExtends(aa[i], pa[i], ids, vals, contra, depth + 1);
                    return;
                }
                // `Array<infer U>` (and other single-arg generics) vs an
                // array/tuple source: bind the arg from the element type.
                const pa = try c.scratch().dupe(TypeId, s.refArgs(pattern));
                if (pa.len == 1) {
                    switch (s.kind(src)) {
                        .array => return c.inferFromExtends(s.arrayElem(src), pa[0], ids, vals, contra, depth + 1),
                        .tuple => {
                            for (0..s.tupleLen(src)) |i|
                                try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, pa[0], ids, vals, contra, depth + 1);
                            return;
                        },
                        else => {},
                    }
                }
                const rp = try c.resolveStructural(pattern);
                if (rp != pattern) try c.inferFromExtends(src, rp, ids, vals, contra, depth + 1);
            },
            .object => {
                const src = try c.resolveStructural(source0);
                if (s.kind(src) != .object) return;
                for (0..s.objectPropCount(pattern)) |i| {
                    const pp = s.objectProp(pattern, @intCast(i));
                    if (s.objectPropByName(src, pp.name)) |sp| {
                        try c.inferFromExtends(sp.ty, pp.ty, ids, vals, contra, depth + 1);
                    }
                }
                // A construct-signature pattern (`new (props: infer P) => …`,
                // e.g. `JSXElementConstructor`'s class constituent) is an object
                // carrying a construct signature; a call-signature pattern object
                // (a function type with extra members) carries call sigs. Infer
                // through both signature kinds, aligning source→pattern sigs from
                // the end like tsc's `inferFromSignatures`.
                try c.inferFromObjectSigs(src, pattern, false, ids, vals, contra, depth);
                try c.inferFromObjectSigs(src, pattern, true, ids, vals, contra, depth);
            },
            .function => {
                var src = try c.resolveStructural(source0);
                // A callable-object source (an interface/type literal carrying
                // call signatures — e.g. React's `ForwardRefExoticComponent<P>`,
                // whose `(props: P): ReactNode` sig makes it a component) stands
                // in for a bare function when matched against a function-type
                // pattern. tsc's `inferFromSignatures` aligns source/target sigs
                // from the end, so a single-signature pattern infers from the
                // source's LAST call signature (the overload picked for the
                // most-general shape). Extract it and recurse.
                if (s.kind(src) == .object) {
                    const ncall = s.objectCallSigCount(src);
                    if (ncall > 0)
                        try c.inferFromExtends(s.objectCallSig(src, ncall - 1), pattern, ids, vals, contra, depth + 1);
                    return;
                }
                // An intersection whose callable part is an overload set
                // (`typeof setTimeout` is `overloads & namespaceObject` after
                // the lib+node timer merge): infer through its last call
                // signature so `ReturnType<typeof setTimeout>` reads the node
                // return type instead of collapsing to `unknown`.
                // An intersection carrying a callable OBJECT (React's
                // `ForwardRefExoticComponent<P> & {…}`) is left to the existing
                // object/construct-signature inference, so `ComponentProps<typeof
                // C>` is unaffected.
                if (s.kind(src) == .intersection) {
                    // Restrict to the shape the lib+node timer merge produces: an
                    // OVERLOAD SET intersected with a namespace value object
                    // (`typeof setTimeout` = `overloads & typeof setTimeout`).
                    // Only the multi-signature overload case needs this routing —
                    // a plain function intersected with its statics (every
                    // `typeof f`, e.g. `typeof Icon`) is already inferred through
                    // the existing object/construct-signature path, so leaving it
                    // alone keeps `ComponentProps<typeof C>` and other conditional
                    // types untouched.
                    var callable: TypeId = types.no_type;
                    for (try c.memberList(src)) |m| {
                        const rm = try c.resolveStructural(m);
                        if (s.kind(rm) == .overloads) callable = rm;
                    }
                    if (callable == types.no_type) return;
                    if (try c.lastCallSig(callable)) |sig| src = sig else return;
                }
                if (s.kind(src) != .function) return;
                // A generic *source* signature must be reduced to its base
                // signature before we infer *through* it: each of the source's
                // own type params is erased to its constraint (or `unknown`
                // when unconstrained), matching tsc's `getBaseSignature`.
                // Otherwise those bound params leak into the infer results, e.g.
                // `(<T>(x: T) => T) extends (x: infer A) => infer B` must yield
                // `unknown, unknown` (not `T, T`), and `<T extends string>`
                // yields `string, string`. Defaults are ignored (only the
                // constraint erases). This only touches the source's *own*
                // params; outer/free params still flow through untouched.
                var base_map: std.ArrayList(TpMap) = .empty;
                defer base_map.deinit(c.scratch());
                for (s.fnTypeParams(src)) |p| {
                    const con = try c.typeParamConstraint(p);
                    const bt = if (con != types.no_type) con else types.unknown_type;
                    try base_map.append(c.scratch(), .{ .sym = p, .ty = bt });
                }
                const n = @min(s.fnParamCount(src), s.fnParamCount(pattern));
                for (0..n) |i| {
                    var sp = s.fnParam(src, @intCast(i)).ty;
                    if (base_map.items.len != 0) sp = try c.instantiate(sp, base_map.items);
                    try c.inferFromExtends(sp, s.fnParam(pattern, @intCast(i)).ty, ids, vals, !contra, depth + 1);
                }
                var sr = s.fnReturn(src);
                if (base_map.items.len != 0) sr = try c.instantiate(sr, base_map.items);
                try c.inferFromExtends(sr, s.fnReturn(pattern), ids, vals, contra, depth + 1);
            },
            .union_type => {
                for (try c.memberList(pattern)) |m| {
                    if (try c.containsInfer(m)) try c.inferFromExtends(source0, m, ids, vals, contra, depth + 1);
                }
            },
            // Intersection pattern (`object & { then(onfulfilled: infer F, …) }`
            // for Awaited; `NextExt & infer Ext` for a redux StoreEnhancer).
            // tsc's rule: first cancel constituents that are *identical* between
            // source and pattern, then infer the residual source into the
            // pattern's infer-bearing constituents. A pattern constituent that is
            // a *foreign type variable* (a signature-local / free type param, not
            // one of our infer ids) with no identical match in the source
            // POISONS the inference — tsc attributes no candidate to the infer
            // var, which then resolves to its constraint. This is what makes
            // `StoreEnhancer<{dispatch}> extends StoreEnhancer<infer E>` yield
            // `{}` (E's constraint) instead of dragging the whole
            // function-return intersection (incl. `Store<unknown, …>`) into E,
            // while an ordinary `string & infer X` still residuals to X.
            .intersection => {
                const isrc = try c.resolveStructural(source0);
                const src_members: []const TypeId = if (s.kind(isrc) == .intersection)
                    try c.memberList(isrc)
                else
                    &.{isrc};
                const matched = try c.scratch().alloc(bool, src_members.len);
                for (matched) |*mm| mm.* = false;
                for (try c.memberList(pattern)) |m| {
                    if (try c.containsInfer(m)) continue;
                    var found = false;
                    for (src_members, 0..) |sm, i| {
                        if (!matched[i] and sm == m) {
                            matched[i] = true;
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;
                    // Unmatched foreign type variable → poison the whole
                    // intersection: leave its infer vars unbound.
                    if (s.kind(m) == .type_param or s.kind(try c.resolveStructural(m)) == .type_param) return;
                }
                // Residual source: the un-cancelled constituents. When nothing
                // cancelled, reuse `source0` verbatim (preserves the Awaited path
                // and its display exactly); otherwise rebuild from the residue.
                var n_matched: usize = 0;
                for (matched) |mm| {
                    if (mm) n_matched += 1;
                }
                var residual_src = source0;
                if (n_matched != 0) {
                    var residue: std.ArrayList(TypeId) = .empty;
                    defer residue.deinit(c.scratch());
                    for (src_members, 0..) |sm, i| {
                        if (!matched[i]) try residue.append(c.scratch(), sm);
                    }
                    residual_src = if (residue.items.len == 0)
                        types.unknown_type
                    else
                        try c.ts.makeIntersection(c.scratch(), residue.items);
                }
                for (try c.memberList(pattern)) |m| {
                    if (try c.containsInfer(m)) try c.inferFromExtends(residual_src, m, ids, vals, contra, depth + 1);
                }
            },
            // `S extends `${infer H}-${infer R}`` — pattern-match the concrete
            // source string against the template, binding each hole's infer var.
            .template_literal_type => {
                const src = try c.resolveStructural(source0);
                if (try c.stringLiteralOf(src)) |atom_| {
                    try c.inferFromTemplate(c.atomText(atom_), pattern, ids, vals);
                }
            },
            else => {},
        }
    }

    /// Infer through the call (`is_construct == false`) or construct signatures
    /// shared by a source object and a signature-bearing pattern object. tsc's
    /// `inferFromSignatures` pairs source/target signatures aligned from the END
    /// of each list, so an N-signature source and a 1-signature pattern infer
    /// from the source's last signature. Each paired signature is a `.function`
    /// TypeId, so the recursion lands back in the `.function` arm (params
    /// contravariant, return covariant).
    fn inferFromObjectSigs(c: *Checker, src: TypeId, pattern: TypeId, is_construct: bool, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
        const s = &c.ts;
        const scount = if (is_construct) s.objectConstructSigCount(src) else s.objectCallSigCount(src);
        const pcount = if (is_construct) s.objectConstructSigCount(pattern) else s.objectCallSigCount(pattern);
        if (scount == 0 or pcount == 0) return;
        const len = @min(scount, pcount);
        for (0..len) |i| {
            const ssig = if (is_construct) s.objectConstructSig(src, scount - len + @as(u32, @intCast(i))) else s.objectCallSig(src, scount - len + @as(u32, @intCast(i)));
            const psig = if (is_construct) s.objectConstructSig(pattern, pcount - len + @as(u32, @intCast(i))) else s.objectCallSig(pattern, pcount - len + @as(u32, @intCast(i)));
            try c.inferFromExtends(ssig, psig, ids, vals, contra, depth + 1);
        }
    }

    /// Greedy pattern-match a concrete string against a template-literal
    /// pattern, binding each `infer` hole (tsc's rules: a non-empty following
    /// literal captures up to its *first* occurrence — lazy; the last hole
    /// takes the remainder; two adjacent holes split one character to the
    /// first). No backtracking (a documented M16c simplification, exact for
    /// the single-delimiter forms tsc users rely on).
    fn inferFromTemplate(c: *Checker, text: []const u8, tpl: TypeId, ids: []const u32, vals: []TypeId) Error!void {
        const s = &c.ts;
        const head = c.atomText(s.templateHead(tpl));
        if (!std.mem.startsWith(u8, text, head)) return;
        const n = s.templateHoleCount(tpl);
        var pos: usize = head.len;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const hole = s.templateHole(tpl, i);
            const chunk = c.atomText(s.templateChunk(tpl, i));
            var cap_end: usize = undefined;
            if (i + 1 == n) {
                // Last hole: `chunk` is the tail literal; text must end with it.
                if (!std.mem.endsWith(u8, text[pos..], chunk)) return;
                cap_end = text.len - chunk.len;
            } else if (chunk.len == 0) {
                // Adjacent holes with no separator: capture one char.
                cap_end = @min(pos + 1, text.len);
            } else {
                const rel = std.mem.indexOf(u8, text[pos..], chunk) orelse return;
                cap_end = pos + rel;
            }
            const captured = text[pos..cap_end];
            try c.bindTemplateInfer(hole, captured, ids, vals);
            pos = cap_end + (if (i + 1 == n) chunk.len else if (chunk.len == 0) @as(usize, 0) else chunk.len);
        }
    }

    /// Bind the infer var(s) in a template hole to a captured substring. The
    /// common case is a bare `infer X` (→ the string-literal of the capture);
    /// a `string`/`number` typed hole binds nothing.
    fn bindTemplateInfer(c: *Checker, hole: TypeId, captured: []const u8, ids: []const u32, vals: []TypeId) Error!void {
        const s = &c.ts;
        if (s.kind(hole) != .infer_var) return;
        const idx = indexOfId(ids, s.inferVarId(hole)) orelse return;
        const lit = try c.ts.makeStringLiteral(try c.internText(captured), false);
        if (vals[idx] == types.no_type) {
            vals[idx] = lit;
        } else {
            vals[idx] = try c.makeUnion2(vals[idx], lit);
        }
    }

    fn containsInfer(c: *Checker, t: TypeId) Error!bool {
        const s = &c.ts;
        return switch (s.kind(t)) {
            .infer_var => true,
            .array => c.containsInfer(s.arrayElem(t)),
            .union_type, .intersection, .overloads => blk: {
                for (try c.memberList(t)) |m| {
                    if (try c.containsInfer(m)) break :blk true;
                }
                break :blk false;
            },
            .tuple => blk: {
                for (0..s.tupleLen(t)) |i| {
                    if (try c.containsInfer(s.tupleElem(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .object => blk: {
                for (0..s.objectPropCount(t)) |i| {
                    if (try c.containsInfer(s.objectProp(t, @intCast(i)).ty)) break :blk true;
                }
                if (s.objectStringIndex(t) != 0 and try c.containsInfer(s.objectStringIndex(t))) break :blk true;
                if (s.objectNumberIndex(t) != 0 and try c.containsInfer(s.objectNumberIndex(t))) break :blk true;
                for (0..s.objectCallSigCount(t)) |i| {
                    if (try c.containsInfer(s.objectCallSig(t, @intCast(i)))) break :blk true;
                }
                for (0..s.objectConstructSigCount(t)) |i| {
                    if (try c.containsInfer(s.objectConstructSig(t, @intCast(i)))) break :blk true;
                }
                break :blk false;
            },
            .function => blk: {
                if (try c.containsInfer(s.fnReturn(t))) break :blk true;
                for (0..s.fnParamCount(t)) |i| {
                    if (try c.containsInfer(s.fnParam(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .ref => blk: {
                for (s.refArgs(t)) |a| {
                    if (try c.containsInfer(a)) break :blk true;
                }
                break :blk false;
            },
            .conditional => blk: {
                if (try c.containsInfer(s.condCheck(t))) break :blk true;
                if (try c.containsInfer(s.condExtends(t))) break :blk true;
                if (try c.containsInfer(s.condTrue(t))) break :blk true;
                if (try c.containsInfer(s.condFalse(t))) break :blk true;
                break :blk false;
            },
            .template_literal_type => blk: {
                for (0..s.templateHoleCount(t)) |i| {
                    if (try c.containsInfer(s.templateHole(t, @intCast(i)))) break :blk true;
                }
                break :blk false;
            },
            .string_mapping => c.containsInfer(s.stringMappingArg(t)),
            .keyof_op => c.containsInfer(s.keyofOperand(t)),
            // A deferred mapped type / indexed access may carry an `infer` var in
            // its key source or value; `substInfer` descends into both (their
            // `.mapped` / `.index_access` arms), so this predicate must see them.
            .mapped => blk: {
                if (try c.containsInfer(s.mappedConstraint(t))) break :blk true;
                if (try c.containsInfer(s.mappedValue(t))) break :blk true;
                if (s.mappedAs(t) != 0 and try c.containsInfer(s.mappedAs(t))) break :blk true;
                if (s.mappedSource(t) != 0 and try c.containsInfer(s.mappedSource(t))) break :blk true;
                break :blk false;
            },
            .index_access => blk: {
                if (try c.containsInfer(s.indexAccessObj(t))) break :blk true;
                if (try c.containsInfer(s.indexAccessIndex(t))) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    /// Replace `infer` binders (`ids[i]`) with their inferred `vals[i]`.
    fn substInfer(c: *Checker, t: TypeId, ids: []const u32, vals: []const TypeId) Error!TypeId {
        if (ids.len == 0 or !try c.containsInfer(t)) return t;
        const s = &c.ts;
        switch (s.kind(t)) {
            .infer_var => {
                const idx = indexOfId(ids, s.inferVarId(t)) orelse return t;
                return vals[idx];
            },
            .array => return s.makeArray(try c.substInfer(s.arrayElem(t), ids, vals)),
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
                return s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
                return s.makeIntersection(c.scratch(), parts.items);
            },
            .overloads => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
                return s.makeOverloads(parts.items);
            },
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.substInfer(e.ty, ids, vals), .flags = e.flags });
                }
                return s.makeTuple(elems.items);
            },
            .object => {
                var props: std.ArrayList(types.Prop) = .empty;
                defer props.deinit(c.scratch());
                for (0..s.objectPropCount(t)) |i| {
                    const p = s.objectProp(t, @intCast(i));
                    try props.append(c.scratch(), .{ .name = p.name, .ty = try c.substInfer(p.ty, ids, vals), .flags = p.flags });
                }
                const sidx = if (s.objectStringIndex(t) != 0) try c.substInfer(s.objectStringIndex(t), ids, vals) else 0;
                const nidx = if (s.objectNumberIndex(t) != 0) try c.substInfer(s.objectNumberIndex(t), ids, vals) else 0;
                // Preserve and substitute call/construct signatures — dropping
                // them (the old `makeObject` path) lost the inferred `new (props:
                // P) => …` shape needed to decide a construct-pattern conditional.
                if (s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0)
                    return s.makeObject(props.items, sidx, nidx, s.objectFlags(t));
                var call_sigs: std.ArrayList(TypeId) = .empty;
                defer call_sigs.deinit(c.scratch());
                var construct_sigs: std.ArrayList(TypeId) = .empty;
                defer construct_sigs.deinit(c.scratch());
                for (0..s.objectCallSigCount(t)) |i| try call_sigs.append(c.scratch(), try c.substInfer(s.objectCallSig(t, @intCast(i)), ids, vals));
                for (0..s.objectConstructSigCount(t)) |i| try construct_sigs.append(c.scratch(), try c.substInfer(s.objectConstructSig(t, @intCast(i)), ids, vals));
                return s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
            },
            .function => {
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substInfer(p.ty, ids, vals), .flags = p.flags });
                }
                const ret = try c.substInfer(s.fnReturn(t), ids, vals);
                const this_ty = s.fnThisType(t);
                return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, if (this_ty != 0) try c.substInfer(this_ty, ids, vals) else 0);
            },
            .ref => {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substInfer(a, ids, vals));
                return s.makeRef(s.refSymbol(t), args.items);
            },
            .conditional => {
                // Distribution over an `infer`-var check that resolves to a
                // union (mirrors the naked type-param path in `instantiateId`):
                // a distributive conditional whose check *is* one of the infer
                // vars being substituted must re-bind that var per union member
                // so the true/false branches reflect each member — not the whole
                // union. Substituting the branches with the whole union first
                // (the general path below) bakes `Draft<V>` into
                // `Draft<Error | null>` before it can distribute, which is what
                // broke immer's `WritableNonArrayDraft` value type
                // (`T[K] extends infer V ? V extends object ? Draft<V> : V
                // : never`): the inner `V extends object` is a distributive
                // infer-var check.
                const check0 = s.condCheck(t);
                if (s.condDistributive(t) and s.kind(check0) == .infer_var) {
                    if (indexOfId(ids, s.inferVarId(check0))) |vi| {
                        const cv = vals[vi];
                        if (s.kind(cv) == .union_type) {
                            var parts: std.ArrayList(TypeId) = .empty;
                            defer parts.deinit(c.scratch());
                            const vals2 = try c.scratch().dupe(TypeId, vals);
                            for (try c.memberList(cv)) |m| {
                                vals2[vi] = m;
                                try parts.append(c.scratch(), try c.substInfer(t, ids, vals2));
                            }
                            return s.makeUnion(c.scratch(), parts.items);
                        }
                    }
                }
                const chk = try c.substInfer(check0, ids, vals);
                const ext = try c.substInfer(s.condExtends(t), ids, vals);
                const tru = try c.substInfer(s.condTrue(t), ids, vals);
                const fls = try c.substInfer(s.condFalse(t), ids, vals);
                return c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
            },
            .index_access => {
                const obj = try c.substInfer(s.indexAccessObj(t), ids, vals);
                const idx = try c.substInfer(s.indexAccessIndex(t), ids, vals);
                return c.reduceIndexedAccess(obj, idx);
            },
            .template_literal_type => {
                var holes: std.ArrayList(TypeId) = .empty;
                defer holes.deinit(c.scratch());
                for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.substInfer(s.templateHole(t, @intCast(i)), ids, vals));
                return c.reduceTemplate(s.templateHead(t), holes.items, t);
            },
            .string_mapping => return c.applyStringMapping(s.stringMappingKind(t), try c.substInfer(s.stringMappingArg(t), ids, vals)),
            .keyof_op => return c.keyofType(try c.substInfer(s.keyofOperand(t), ids, vals)),
            // Re-enter `reduceMapped` with the branches' `infer` vars bound: a
            // mapped alias deferred while its key source was still an `infer` var
            // (see `reduceMapped`) now materializes its key set. Without this arm
            // the map falls through unchanged and stays `{}`.
            .mapped => {
                const kp = s.mappedKeyParam(t); // key param identity is stable
                const con = try c.substInfer(s.mappedConstraint(t), ids, vals);
                const val = try c.substInfer(s.mappedValue(t), ids, vals);
                const as_c = if (s.mappedAs(t) != 0) try c.substInfer(s.mappedAs(t), ids, vals) else 0;
                const src = if (s.mappedSource(t) != 0) try c.substInfer(s.mappedSource(t), ids, vals) else 0;
                return c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
            },
            else => return t,
        }
    }

    // =====================================================================
    // mapped types (M16b)
    // =====================================================================

    /// Dense, stable id for a mapped type's key parameter `K`, keyed by the
    /// mapped-type nodeKey. Mapped nodes are excluded from the type-node memo,
    /// so the node may be re-evaluated — the id must be stable across calls.
    fn mappedKeyId(c: *Checker, node: Node) Error!u32 {
        const gop = try c.mapped_key_ids.getOrPut(c.ca(), c.nodeKey(node));
        if (!gop.found_existing) {
            gop.value_ptr.* = c.mapped_key_next;
            c.mapped_key_next += 1;
        }
        return gop.value_ptr.*;
    }

    fn mappedTypeFromNode(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const m = c.tree.extraData(ast.MappedTypeData, d.lhs);
        const key_name = try c.atomOfToken(m.key_name_token);
        const key_id = try c.mappedKeyId(node);
        const key_param = try c.ts.makeMappedParam(key_id, key_name);

        var flags: u32 = m.flags;
        // Homomorphic detection: the constraint is syntactically `keyof X`.
        // Store `X` as the src_type (so its per-prop modifiers and array/tuple-
        // ness can be preserved) rather than pre-evaluating `keyof X`, which
        // would collapse to `never` while `X` is a generic parameter.
        var src_type: TypeId = 0;
        var constraint: TypeId = 0;
        if (c.nodeTag(m.constraint) == .keyof_type) {
            flags |= types.mapped_flag_homomorphic;
            src_type = try c.typeFromTypeNode(c.tree.nodeData(m.constraint).lhs);
        } else {
            constraint = try c.typeFromTypeNode(m.constraint);
        }

        // The key parameter is in scope in the `as` and value branches only
        // (never in the constraint), so evaluate those with it bound.
        const saved_name = c.cur_mapped_key_name;
        const saved_ty = c.cur_mapped_key_ty;
        const saved_depth = c.cur_mapped_key_scope_depth;
        c.cur_mapped_key_name = key_name;
        c.cur_mapped_key_ty = key_param;
        c.cur_mapped_key_scope_depth = c.infer_scopes.items.len;
        const as_clause = if (m.as_type != null_node) try c.typeFromTypeNode(m.as_type) else 0;
        const value = if (m.value != null_node) try c.typeFromTypeNode(m.value) else types.any_type;
        c.cur_mapped_key_name = saved_name;
        c.cur_mapped_key_ty = saved_ty;
        c.cur_mapped_key_scope_depth = saved_depth;

        return c.reduceMapped(key_param, constraint, value, as_clause, src_type, flags);
    }

    /// The single evaluation point for a mapped type (build time + each
    /// instantiation): defer while the key set is still generic, else
    /// materialize. Counted against the TS2589 depth/count budget.
    fn reduceMapped(c: *Checker, key_param: TypeId, constraint: TypeId, value: TypeId, as_clause: TypeId, src_type: TypeId, flags: u32) Error!TypeId {
        if (c.inst_depth > max_instantiation_depth or c.inst_count > max_instantiation_count) {
            c.inst_limit_tripped = true;
            if (!c.suppress_inst_diag) try c.diagFmt(2589, c.inst_span, "Type instantiation is excessively deep and possibly infinite.", .{});
            return types.error_type;
        }
        c.inst_depth += 1;
        c.inst_count += 1;
        defer c.inst_depth -= 1;
        const homomorphic = flags & types.mapped_flag_homomorphic != 0;
        // Deferral is decided by the *key set* only: the value/`as` branches may
        // still be generic (they materialize into generic-typed props). The key
        // set of a homomorphic map is literally `keyof src` — NOT `src` itself.
        // A concrete-keyed source with still-generic *values* (e.g.
        // `Partial<Impl<T>>` where `Impl<T>`'s props are as-yet-unreduced
        // conditionals from a recursive `Merge<…>`) has a fully concrete key set
        // and MUST materialize; testing `src` directly saw the free type params
        // buried in those value branches and stranded the whole map deferred as
        // `{ [P in keyof {…}]: … }`, dropping every member (react-hook-form
        // `FieldErrors<Form>` collapsing to just its `{form?;root?}` constituent).
        // `keyofType` yields a concrete literal union for an object/array/tuple
        // source and a deferred `keyof T` (which the tests below still flag) for a
        // naked type param / index / conditional — so genericness is judged on the
        // keys alone. The non-homomorphic key source is the constraint directly.
        // The map stays deferred while its key set mentions a free type param OR
        // an as-yet-unbound `infer` var. The `infer`-var case arises when a mapped
        // alias is applied to an infer var of an enclosing conditional
        // (`Rec<…> = … ? Acc & F<Head> : Acc`, F a mapped alias): `keyof (Acc &
        // F<Head>)` carries `keyof Head`, so `containsInfer` keeps it deferred and
        // `substInfer` (its `.mapped` arm) re-enters here once `Head` binds.
        const key_src = if (homomorphic) try c.keyofType(src_type) else constraint;
        const key_generic = try c.containsFreeTypeParam(key_src, &.{}) or try c.containsInfer(key_src);
        if (key_generic) {
            return c.ts.makeMapped(key_param, constraint, value, as_clause, src_type, flags);
        }
        return c.materializeMapped(key_param, constraint, value, as_clause, src_type, flags);
    }

    fn applyPropModifiers(base: u32, flags: u32) u32 {
        var f = base;
        if (flags & types.mapped_flag_readonly_add != 0) f |= types.prop_flag_readonly;
        if (flags & types.mapped_flag_readonly_remove != 0) f &= ~types.prop_flag_readonly;
        if (flags & types.mapped_flag_optional_add != 0) f |= types.prop_flag_optional;
        if (flags & types.mapped_flag_optional_remove != 0) f &= ~types.prop_flag_optional;
        return f;
    }

    fn applyElemModifiers(base: u32, flags: u32) u32 {
        var f = base;
        if (flags & types.mapped_flag_readonly_add != 0) f |= types.elem_flag_readonly;
        if (flags & types.mapped_flag_readonly_remove != 0) f &= ~types.elem_flag_readonly;
        if (flags & types.mapped_flag_optional_add != 0) f |= types.elem_flag_optional;
        if (flags & types.mapped_flag_optional_remove != 0) f &= ~types.elem_flag_optional;
        return f;
    }

    /// Materialize a concrete mapped type (its key set is known). Homomorphic
    /// maps iterate the src_type's own members (preserving modifiers and
    /// array/tuple-ness); others iterate the constraint's literal members.
    fn materializeMapped(c: *Checker, key_param: TypeId, constraint: TypeId, value: TypeId, as_clause: TypeId, src_type: TypeId, flags: u32) Error!TypeId {
        const s = &c.ts;
        const key_id = s.mappedParamId(key_param);
        const homomorphic = flags & types.mapped_flag_homomorphic != 0;

        if (homomorphic) {
            const saved_hi = c.homo_index_mode;
            c.homo_index_mode = true;
            defer c.homo_index_mode = saved_hi;
            const src = try c.resolveStructural(src_type);
            switch (s.kind(src)) {
                .any, .err => return types.any_type,
                .array => {
                    // A homomorphic map over an array yields an array; the
                    // element is the value with `K` bound to the number index.
                    const elem = try c.substMappedKey(value, key_id, types.number_type);
                    return s.makeArray(elem);
                },
                .tuple => {
                    var elems: std.ArrayList(types.TupleElem) = .empty;
                    defer elems.deinit(c.scratch());
                    for (0..s.tupleLen(src)) |i| {
                        const e = s.tupleElem(src, @intCast(i));
                        const key_lit = try s.makeNumberLiteral(@floatFromInt(i), false);
                        const et = try c.substMappedKey(value, key_id, key_lit);
                        try elems.append(c.scratch(), .{ .ty = et, .flags = applyElemModifiers(e.flags, flags) });
                    }
                    return s.makeTuple(elems.items);
                },
                .union_type => {
                    // A homomorphic map distributes over a union source: tsc's
                    // `mapType` yields `M<A> | M<B>` for `M<A | B>` (a homomorphic
                    // mapped type — `{ [P in keyof T]: … }` — is applied to each
                    // constituent). Without this a union source fell through to
                    // `{}`, so `Readonly<A | B>` (react-pdf's `ImageProps =
                    // ImageWithSrcProp | ImageWithSourceProp` read off a class
                    // component's `props: Readonly<P>`) collapsed to `{}` and every
                    // attribute read as excess against `IntrinsicAttributes & {}`.
                    // Restricted to a union whose every constituent is a plain,
                    // named-property object (no index signature): that is the
                    // props-union case we need (react-pdf `ImageProps`), and it
                    // keeps the map well-defined. A union of pure index-signature
                    // objects (`Record<string,A> | Record<string,B>` — redux's
                    // `SliceCaseReducers<State>` default, reached only when
                    // `createSlice`'s reducer inference falls back to the
                    // constraint) keeps the prior `{}` fallback: distributing it
                    // would materialize a spurious `{ [x:string]: … }` that fails a
                    // named-property target (a separate, pre-existing inference
                    // gap). Under-report over a false positive.
                    // Snapshot the members: the per-member recursion below
                    // materializes new types, which may reallocate the type
                    // store's member backing and invalidate a live `members(src)`
                    // slice.
                    const umembers = try c.scratch().dupe(TypeId, c.ts.members(src));
                    var all_obj = true;
                    for (umembers) |m| {
                        const rm = try c.resolveStructural(m);
                        // An intersection member (`PropsWithChildren<TextProps>` =
                        // `TextProps & {children?}`) is fine — its per-member map is
                        // the `.intersection` arm below. A plain object member must
                        // carry named props and NO index signature; a pure
                        // index-signature object (`Record<string,V>`) is the redux
                        // `SliceCaseReducers` fallback and must not distribute.
                        const ok = s.kind(rm) == .intersection or
                            (s.kind(rm) == .object and
                                s.objectPropCount(rm) > 0 and
                                s.objectStringIndex(rm) == 0 and
                                s.objectNumberIndex(rm) == 0);
                        if (!ok) {
                            all_obj = false;
                            break;
                        }
                    }
                    if (all_obj) {
                        var parts: std.ArrayList(TypeId) = .empty;
                        defer parts.deinit(c.scratch());
                        for (umembers) |m| {
                            try parts.append(c.scratch(), try c.materializeMapped(key_param, constraint, value, as_clause, m, flags));
                        }
                        return c.ts.makeUnion(c.scratch(), parts.items);
                    }
                    return types.empty_object_type;
                },
                .object, .intersection => {
                    // A homomorphic map iterates the source's own members. An
                    // intersection source (`{ [K in keyof (A & B)]: … }`) has
                    // key set `keyof A | keyof B`; flatten every object
                    // constituent's props so members of both survive — without
                    // this the intersection fell through to `{}` and dropped
                    // them all (e.g. `WithBaseUIEvent<ComponentPropsWithRef<'img'>>`,
                    // whose argument is `ClassAttributes & ImgHTMLAttributes`).
                    var srcprops: std.ArrayList(types.Prop) = .empty;
                    defer srcprops.deinit(c.scratch());
                    try c.collectHomoProps(src, &srcprops);
                    var props: std.ArrayList(types.Prop) = .empty;
                    defer props.deinit(c.scratch());
                    for (srcprops.items) |p| {
                        const key_lit = try s.makeStringLiteral(p.name, false);
                        const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                        const pt = try c.substMappedKey(value, key_id, key_lit);
                        try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(p.flags, flags) });
                    }
                    // Preserve the source's index signatures: a homomorphic map
                    // over `Record<string, V>` / any index-signatured source
                    // yields `{ [k: string]: mapped(V) }`, not `{}`. `keyof T`
                    // for such a source includes `string`/`number`, so the value
                    // `T[K]` is remapped with K bound to that primitive. An `as`
                    // clause with no string-literal filter passes index keys
                    // through unchanged (tsc keeps the signature). The optional
                    // (`+?`) modifier bakes `| undefined` into the value type
                    // (tsc's addOptionality for a mapped index info).
                    var sindex: TypeId = 0;
                    var nindex: TypeId = 0;
                    if (as_clause == 0) {
                        var src_sidx: TypeId = 0;
                        var src_nidx: TypeId = 0;
                        try c.collectHomoIndex(src, &src_sidx, &src_nidx);
                        if (src_sidx != 0) {
                            var v = try c.substMappedKey(value, key_id, types.string_type);
                            if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                            sindex = v;
                        }
                        if (src_nidx != 0) {
                            var v = try c.substMappedKey(value, key_id, types.number_type);
                            if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                            nindex = v;
                        }
                    }
                    return c.objectFromProps(props.items, sindex, nindex);
                },
                else => return types.empty_object_type,
            }
        }

        // Non-homomorphic: the key set is the constraint's members. An
        // intersection constraint (`keyof T & string` — the string-key filter
        // idiom) is simplified to the surviving literal members here; without
        // it the intersection fell through to `{}` (spurious TS2353/TS2339 on
        // legitimately-remapped keys — an M17.4 false-positive fix).
        var keyset: std.ArrayList(TypeId) = .empty;
        defer keyset.deinit(c.scratch());
        try c.collectMappedKeys(constraint, &keyset);
        const keys = keyset.items;

        // Modifiers-type preservation for the `Pick`/`Omit` shape. When the
        // mapped value is `T[K]` (an indexed access whose index is this map's
        // key parameter), `T` is the modifiers type: a source prop's
        // optional/readonly modifier carries onto the mapped prop, mirroring how
        // tsc copies modifiers from a mapped type's modifiers type even for a
        // non-homomorphic `{ [P in K]: T[P] }` (`K extends keyof T`). Only ADDS
        // a base modifier (the map's own `+/-` still applies on top via
        // `applyPropModifiers`), so it can only relax an over-strict required
        // prop — never a new false positive. Without it, `Pick`/`Omit` props
        // read as required (spurious TS2739/TS2741).
        var mod_src: TypeId = 0;
        if (s.kind(value) == .index_access and s.kind(s.indexAccessIndex(value)) == .mapped_param) {
            const o = try c.resolveStructural(s.indexAccessObj(value));
            // The modifiers type may be an object OR an intersection of objects
            // (`Omit<Partial<Base> & (A|B|C), K>` — react-hook-form
            // `RegisterOptions`). For an intersection, `propOfTypeEx` merges each
            // constituent's optional/readonly flags (required wins), so a source
            // prop that is optional in the `Partial<…>` constituent and absent
            // elsewhere stays optional. Without this the intersection failed the
            // `.object` gate, `mod_src` stayed 0, and every Pick/Omit prop read as
            // required (spurious TS2739/TS2741 on `{ required }` → `RegisterOptions`).
            if (s.kind(o) == .object or s.kind(o) == .intersection) mod_src = o;
        }
        const mod_mask = types.prop_flag_optional | types.prop_flag_readonly;

        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var sindex: TypeId = 0;
        var nindex: TypeId = 0;
        for (keys) |key_lit| {
            switch (s.kind(key_lit)) {
                .string => sindex = try c.substMappedKey(value, key_id, key_lit),
                .number => nindex = try c.substMappedKey(value, key_id, key_lit),
                .string_literal => {
                    const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                    const pt = try c.substMappedKey(value, key_id, key_lit);
                    var base: u32 = 0;
                    if (mod_src != 0) {
                        if (try c.propOfTypeEx(mod_src, s.literalAtom(key_lit), false)) |sp| base = sp.flags & mod_mask;
                    }
                    try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) });
                },
                .number_literal, .number_literal_fresh => {
                    const nm = try c.numberLiteralAtom(key_lit);
                    const pt = try c.substMappedKey(value, key_id, key_lit);
                    var base: u32 = 0;
                    if (mod_src != 0) {
                        if (try c.propOfTypeEx(mod_src, nm, false)) |sp| base = sp.flags & mod_mask;
                    }
                    try props.append(c.scratch(), .{ .name = nm, .ty = pt, .flags = applyPropModifiers(base, flags) });
                },
                else => {}, // non-key member (e.g. symbol) — skip
            }
        }
        if (props.items.len == 0 and sindex == 0 and nindex == 0) return types.empty_object_type;
        return s.makeObject(props.items, sindex, nindex, 0);
    }

    /// Collect the distinct own props of an objectish source (object, or an
    /// intersection of objects) for a homomorphic mapped type's key iteration.
    /// The first occurrence of each name wins its modifier flags; the mapped
    /// value is recomputed per key against the whole source, so a colliding
    /// name's property type stays correct regardless of which flags are kept.
    fn collectHomoProps(c: *Checker, t: TypeId, out: *std.ArrayList(types.Prop)) Error!void {
        const r = try c.resolveStructural(t);
        switch (c.ts.kind(r)) {
            .object => {
                for (0..c.ts.objectPropCount(r)) |i| {
                    const p = c.ts.objectProp(r, @intCast(i));
                    for (out.items) |*o| {
                        if (o.name == p.name) break;
                    } else try out.append(c.scratch(), p);
                }
            },
            .intersection => {
                for (try c.memberList(r)) |m| try c.collectHomoProps(m, out);
            },
            else => {},
        }
    }

    /// Collect the string/number index-signature value types of a homomorphic
    /// mapped source (object, or an intersection of objects). Sets `*sidx` /
    /// `*nidx` to the source's index value type when present (first constituent
    /// wins — intersection index-value merging is a rare edge left to the
    /// source shape). Used so a homomorphic map preserves index signatures.
    fn collectHomoIndex(c: *Checker, t: TypeId, sidx: *TypeId, nidx: *TypeId) Error!void {
        const r = try c.resolveStructural(t);
        switch (c.ts.kind(r)) {
            .object => {
                if (sidx.* == 0) sidx.* = c.ts.objectStringIndex(r);
                if (nidx.* == 0) nidx.* = c.ts.objectNumberIndex(r);
            },
            .intersection => {
                for (try c.memberList(r)) |m| try c.collectHomoIndex(m, sidx, nidx);
            },
            else => {},
        }
    }

    /// Flatten a non-homomorphic mapped-type constraint into its concrete key
    /// members for `materializeMapped`'s prop loop. A union contributes each
    /// member; a bare `string`/`number`/literal contributes itself; an
    /// intersection `(K1|K2|…) & string` (the `keyof T & string` idiom that
    /// filters `keyof T` to its string-named keys) contributes the union
    /// literals that survive the primitive filter — string literals pass a
    /// `string` filter, number literals a `number` filter. This mirrors tsc's
    /// simplification of `("a"|"b") & string` to `"a"|"b"`.
    fn collectMappedKeys(c: *Checker, constraint0: TypeId, out: *std.ArrayList(TypeId)) Error!void {
        const s = &c.ts;
        const constraint = try c.resolveStructural(constraint0);
        switch (s.kind(constraint)) {
            .union_type => for (try c.memberList(constraint)) |m| try c.collectMappedKeys(m, out),
            .intersection => {
                var want_string = false;
                var want_number = false;
                var want_symbol = false;
                var cands: std.ArrayList(TypeId) = .empty;
                defer cands.deinit(c.scratch());
                for (try c.memberList(constraint)) |m0| {
                    const m = try c.resolveStructural(m0);
                    switch (s.kind(m)) {
                        .string => want_string = true,
                        .number => want_number = true,
                        .symbol => want_symbol = true,
                        .union_type => for (try c.memberList(m)) |lm| try cands.append(c.scratch(), lm),
                        else => try cands.append(c.scratch(), m),
                    }
                }
                for (cands.items) |cand| {
                    const keep = switch (s.kind(try c.resolveStructural(cand))) {
                        .string_literal => !want_number and !want_symbol,
                        .number_literal, .number_literal_fresh => !want_string and !want_symbol,
                        else => false,
                    };
                    if (keep) try out.append(c.scratch(), cand);
                }
            },
            // An enum key domain (`{ [P in E]: V }` / `Record<E, V>`) is
            // materialized as an INDEX signature (`string` for a string enum,
            // `number` for a numeric one), not named props. ztsc has no
            // per-member enum literal type, so it cannot name the props by
            // member value — and, symmetrically, an object literal built with
            // computed enum-member keys (`{ [E.A]: v }`) collapses to `{}`.
            // Emitting named props here would make every such literal fail the
            // now-required keys (spurious TS2739). An index signature keeps both
            // sides consistent: `Object.values`/`entries` inference recovers `V`
            // from the index (fixing the `unknown[]`/TS2339 collapse), and a
            // `{}`-shaped computed-key literal stays assignable. The tradeoff is
            // under-reporting a genuinely missing enum key — acceptable, and no
            // worse than today (the map previously collapsed to `{}` outright).
            .enum_type => {
                const info = try c.enumInfo(s.enumSymbol(constraint));
                try out.append(c.scratch(), if (info.all_string) types.string_type else types.number_type);
            },
            else => try out.append(c.scratch(), constraint),
        }
    }

    /// Build an object from possibly-duplicate-named props (later wins), then
    /// intern. `as` remapping can collide keys, so dedup by name here.
    /// `sindex`/`nindex` carry the string/number index-signature value types
    /// (0 = none) — a homomorphic mapped type over an index-signatured source
    /// must preserve those signatures, not just the named props.
    fn objectFromProps(c: *Checker, props: []const types.Prop, sindex: TypeId, nindex: TypeId) Error!TypeId {
        var index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
        defer index.deinit(c.scratch());
        var out: std.ArrayList(types.Prop) = .empty;
        defer out.deinit(c.scratch());
        for (props) |p| {
            if (index.get(p.name)) |i| {
                out.items[i] = p;
            } else {
                try index.put(c.scratch(), p.name, @intCast(out.items.len));
                try out.append(c.scratch(), p);
            }
        }
        return c.ts.makeObject(out.items, sindex, nindex, 0);
    }

    /// Resolve a mapped type's `as` remap for one src_type key. Returns the new
    /// property-name atom, or `null` when the key should be filtered out (the
    /// remap evaluates to `never` — the `Omit`/key-filter idiom). With no `as`
    /// clause the original key name is kept. A template-literal `as` clause
    /// (`` as `get${Capitalize<K & string>}` ``, M16c) reduces through
    /// `substMappedKey` to a concrete string-literal before reaching here.
    fn remapKey(c: *Checker, as_clause: TypeId, key_id: u32, key_lit: TypeId) Error!?Atom {
        if (as_clause == 0) return c.ts.literalAtom(key_lit);
        const nk0 = try c.substMappedKey(as_clause, key_id, key_lit);
        const nk = try c.resolveStructural(nk0);
        return switch (c.ts.kind(nk)) {
            .never => null, // filtered
            .string_literal => c.ts.literalAtom(nk),
            .number_literal, .number_literal_fresh => try c.numberLiteralAtom(nk),
            else => null, // non-static key (union/template pattern/string) — dropped
        };
    }

    fn numberLiteralAtom(c: *Checker, lit: TypeId) Error!Atom {
        var buf: [32]u8 = undefined;
        const v = c.ts.numberValue(lit);
        const txt = if (v == @floor(v) and std.math.isFinite(v))
            std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch return c.atom("0")
        else
            std.fmt.bufPrint(&buf, "{d}", .{v}) catch return c.atom("0");
        // `txt` is a stack-buffer slice — intern (copy) rather than caching the
        // transient slice as an `atom_cache` key.
        return c.internText(txt);
    }

    /// `Obj[Idx]`: defer while the index is still a mapped key parameter (or
    /// either side still mentions one), so a mapped value `T[K]` stays symbolic
    /// until each key is materialized; otherwise resolve concretely.
    fn reduceIndexedAccess(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
        // Mapped-internal `T[K]` (M16b): stays symbolic until each key is
        // materialized. Checked first because a `mapped_param` is not a free
        // type param (so `containsTypeParam` would miss it).
        if (try c.containsMappedParam(idx) or try c.containsMappedParam(obj)) {
            return c.ts.makeIndexAccess(obj, idx);
        }
        // Distribute over a union index (M16d): `Obj[A | B]` === `Obj[A] |
        // Obj[B]`. Holds whether or not `Obj` is generic, and is how a
        // `keyof`-derived index expands once the key union is known.
        if (c.ts.kind(idx) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(idx)) |m| try parts.append(c.scratch(), try c.reduceIndexedAccess(obj, m));
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        // Generic object and/or index (M16d): defer as `T[K]`; resolved in
        // `instantiateId`'s `.index_access` arm once the operands are concrete.
        //
        // The index uses the deep *free* type-param test (tsc `isGenericIndexType`):
        // a member that is itself a generic signature (`{ f: <T>() => T }`) does
        // not make the index generic, so the access resolves now instead of
        // stranding the member as `Obj["f"]`.
        //
        // The OBJECT uses a *shallow* generic test (tsc `isGenericObjectType`),
        // NOT the deep free-type-param scan: a plain intersection/tuple/object is
        // not a generic object type merely because a deeply-nested member type
        // (e.g. a tuple element's complex generic signature) mentions a type
        // variable. Property PRESENCE is instantiation-invariant, so a concrete
        // literal key resolves to the same property now as after instantiation.
        // Deferring on the deep scan stranded `([TFn,i18n,boolean] & {t;i18n})['i18n']`
        // as an unreduced `.index_access`, on which member access (`.t`) then
        // wrongly reported TS2339. Only defer when a top-level constituent is
        // itself instantiable (a bare type variable, mapped/conditional/keyof, …).
        if (try c.isGenericObjectForIndex(obj) or try c.containsFreeTypeParam(idx, &.{})) {
            return c.ts.makeIndexAccess(obj, idx);
        }
        return c.indexedAccessType(obj, idx);
    }

    /// Shallow analogue of tsc's `isGenericObjectType` for the object side of an
    /// indexed access: is `t` (or a union/intersection constituent of it) an
    /// *instantiable* type whose indexed property genuinely depends on later
    /// instantiation? Plain object/tuple/array containers are NOT generic here
    /// even when their members mention free type params — indexing them by a
    /// concrete key resolves the same before and after instantiation.
    fn isGenericObjectForIndex(c: *Checker, t0: TypeId) Error!bool {
        const s = &c.ts;
        const t = try c.resolveStructural(t0);
        return switch (s.kind(t)) {
            .type_param, .infer_var, .mapped_param, .mapped, .index_access, .conditional, .keyof_op, .string_mapping, .template_literal_type => true,
            .union_type, .intersection => blk: {
                for (try c.memberList(t)) |m| {
                    if (try c.isGenericObjectForIndex(m)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn containsMappedParam(c: *Checker, t: TypeId) Error!bool {
        const s = &c.ts;
        return switch (s.kind(t)) {
            .mapped_param => true,
            .array => c.containsMappedParam(s.arrayElem(t)),
            .index_access => (try c.containsMappedParam(s.indexAccessObj(t))) or (try c.containsMappedParam(s.indexAccessIndex(t))),
            .union_type, .intersection, .overloads => blk: {
                for (try c.memberList(t)) |m| {
                    if (try c.containsMappedParam(m)) break :blk true;
                }
                break :blk false;
            },
            .tuple => blk: {
                for (0..s.tupleLen(t)) |i| {
                    if (try c.containsMappedParam(s.tupleElem(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .object => blk: {
                for (0..s.objectPropCount(t)) |i| {
                    if (try c.containsMappedParam(s.objectProp(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .function => blk: {
                if (try c.containsMappedParam(s.fnReturn(t))) break :blk true;
                for (0..s.fnParamCount(t)) |i| {
                    if (try c.containsMappedParam(s.fnParam(t, @intCast(i)).ty)) break :blk true;
                }
                break :blk false;
            },
            .ref => blk: {
                for (s.refArgs(t)) |a| {
                    if (try c.containsMappedParam(a)) break :blk true;
                }
                break :blk false;
            },
            .conditional => blk: {
                if (try c.containsMappedParam(s.condCheck(t))) break :blk true;
                if (try c.containsMappedParam(s.condExtends(t))) break :blk true;
                if (try c.containsMappedParam(s.condTrue(t))) break :blk true;
                if (try c.containsMappedParam(s.condFalse(t))) break :blk true;
                break :blk false;
            },
            .template_literal_type => blk: {
                for (0..s.templateHoleCount(t)) |i| {
                    if (try c.containsMappedParam(s.templateHole(t, @intCast(i)))) break :blk true;
                }
                break :blk false;
            },
            .string_mapping => c.containsMappedParam(s.stringMappingArg(t)),
            .keyof_op => c.containsMappedParam(s.keyofOperand(t)),
            else => false,
        };
    }

    /// Replace the mapped key parameter (`key_id`) with a concrete key type
    /// throughout `t`, reducing any `Obj[Idx]` that becomes concrete.
    fn substMappedKey(c: *Checker, t: TypeId, key_id: u32, key_ty: TypeId) Error!TypeId {
        if (!try c.containsMappedParam(t)) return t;
        const s = &c.ts;
        switch (s.kind(t)) {
            .mapped_param => return if (s.mappedParamId(t) == key_id) key_ty else t,
            .index_access => {
                const obj = try c.substMappedKey(s.indexAccessObj(t), key_id, key_ty);
                const idx = try c.substMappedKey(s.indexAccessIndex(t), key_id, key_ty);
                return c.reduceIndexedAccess(obj, idx);
            },
            .array => return s.makeArray(try c.substMappedKey(s.arrayElem(t), key_id, key_ty)),
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substMappedKey(m, key_id, key_ty));
                return s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substMappedKey(m, key_id, key_ty));
                return s.makeIntersection(c.scratch(), parts.items);
            },
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.substMappedKey(e.ty, key_id, key_ty), .flags = e.flags });
                }
                return s.makeTuple(elems.items);
            },
            .object => {
                var props: std.ArrayList(types.Prop) = .empty;
                defer props.deinit(c.scratch());
                for (0..s.objectPropCount(t)) |i| {
                    const p = s.objectProp(t, @intCast(i));
                    try props.append(c.scratch(), .{ .name = p.name, .ty = try c.substMappedKey(p.ty, key_id, key_ty), .flags = p.flags });
                }
                return s.makeObject(props.items, 0, 0, 0);
            },
            .function => {
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substMappedKey(p.ty, key_id, key_ty), .flags = p.flags });
                }
                const ret = try c.substMappedKey(s.fnReturn(t), key_id, key_ty);
                return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, s.fnThisType(t));
            },
            .ref => {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substMappedKey(a, key_id, key_ty));
                return s.makeRef(s.refSymbol(t), args.items);
            },
            .conditional => {
                const chk = try c.substMappedKey(s.condCheck(t), key_id, key_ty);
                const ext = try c.substMappedKey(s.condExtends(t), key_id, key_ty);
                const tru = try c.substMappedKey(s.condTrue(t), key_id, key_ty);
                const fls = try c.substMappedKey(s.condFalse(t), key_id, key_ty);
                return c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
            },
            .template_literal_type => {
                var holes: std.ArrayList(TypeId) = .empty;
                defer holes.deinit(c.scratch());
                for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.substMappedKey(s.templateHole(t, @intCast(i)), key_id, key_ty));
                return c.reduceTemplate(s.templateHead(t), holes.items, t);
            },
            .string_mapping => return c.applyStringMapping(s.stringMappingKind(t), try c.substMappedKey(s.stringMappingArg(t), key_id, key_ty)),
            .keyof_op => return c.keyofType(try c.substMappedKey(s.keyofOperand(t), key_id, key_ty)),
            else => return t,
        }
    }

    // =====================================================================
    // template-literal types + string intrinsics (M16c)
    // =====================================================================

    fn intrinsicStringMapping(name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "Uppercase")) return types.string_mapping_uppercase;
        if (std.mem.eql(u8, name, "Lowercase")) return types.string_mapping_lowercase;
        if (std.mem.eql(u8, name, "Capitalize")) return types.string_mapping_capitalize;
        if (std.mem.eql(u8, name, "Uncapitalize")) return types.string_mapping_uncapitalize;
        return null;
    }

    /// Whether type alias `sym`'s body is the bare `intrinsic` keyword-identifier
    /// (`type Uppercase<S extends string> = intrinsic;`), the marker the real lib
    /// uses for its magic string transforms. Distinguishes them from a user alias
    /// that merely shares the name.
    fn aliasBodyIsIntrinsic(c: *Checker, sym: SymbolId) bool {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .type_alias) continue;
            const body = c.tree.nodeData(decl).rhs;
            if (body == null_node or c.nodeTag(body) != .identifier) return false;
            return std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(body)), "intrinsic");
        }
        return false;
    }

    /// The literal text following template hole `i` in a template-literal type
    /// node: strip the `template_middle` (`}…${`) or `template_tail` (`}…\``)
    /// delimiters. No unescaping (a documented M16c simplification — escapes in
    /// template *types* are rare).
    fn templateChunkText(c: *Checker, tok: TokenIndex) []const u8 {
        const text = c.tokenText(tok);
        // middle: `}...${` (drop 1 leading `}`, 2 trailing `${`);
        // tail:   `}...\`` (drop 1 leading `}`, 1 trailing backtick).
        return switch (c.tree.tokens.tag(tok)) {
            .template_middle => if (text.len >= 3) text[1 .. text.len - 2] else "",
            .template_tail => if (text.len >= 2) text[1 .. text.len - 1] else "",
            else => text,
        };
    }

    /// Head literal text of a template-literal type node's main token: strip
    /// the `template_head` (`` `…${ ``) or `no_substitution` (`` `…` ``) delims.
    fn templateHeadText(c: *Checker, tok: TokenIndex) []const u8 {
        const text = c.tokenText(tok);
        return switch (c.tree.tokens.tag(tok)) {
            .template_head => if (text.len >= 3) text[1 .. text.len - 2] else "",
            .no_substitution_template_literal => if (text.len >= 2) text[1 .. text.len - 1] else "",
            else => text,
        };
    }

    /// Does the contextual type want a template-literal-typed value? True when
    /// `ctx` is (or a union contains) a template-literal type — the only case
    /// in which a template *expression* should keep a template-literal type
    /// instead of widening to `string`. Gating on this keeps every other
    /// template expression at `string` (zero blast radius).
    fn ctxWantsTemplate(c: *Checker, ctx: TypeId) Error!bool {
        if (ctx == types.no_type) return false;
        const r = try c.resolveStructural(ctx);
        switch (c.ts.kind(r)) {
            .template_literal_type => return true,
            .union_type => {
                for (try c.memberList(r)) |m| if (try c.ctxWantsTemplate(m)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// The `template_middle` / `template_tail` chunk token immediately following
    /// a substitution that ends at byte `after`. Robust under nested template
    /// substitutions: an inner template's tokens all start before `after`, so
    /// the first middle/tail token at or past `after` is this template's chunk.
    fn templateChunkTokAfter(c: *Checker, head_tok: TokenIndex, after: u32) TokenIndex {
        const n = c.tree.tokens.len();
        var t: usize = @as(usize, head_tok) + 1;
        while (t < n) : (t += 1) {
            const tg = c.tree.tokens.tag(@intCast(t));
            if ((tg == .template_middle or tg == .template_tail) and c.tree.tokens.start(@intCast(t)) >= after)
                return @intCast(t);
        }
        return head_tok;
    }

    /// A template-literal *expression* (`` `head${e0}c0${e1}…` ``) contextually
    /// typed by a template-literal type: build the corresponding template-literal
    /// *type* (`` `head${T0}c0${T1}…` ``) from the head/chunk texts and the
    /// substitution types, rather than widening to `string`. This lets
    /// `` `material-symbols:${status.icon}` `` (`status.icon: string`) satisfy a
    /// `` `${string}:${string}` `` target — matching tsc's contextual typing.
    fn templateExprType(c: *Checker, node: Node) Error!TypeId {
        const main_tok = c.tree.nodeMainToken(node);
        const head = try c.atom(c.templateHeadText(main_tok));
        var holes: std.ArrayList(TypeId) = .empty;
        defer holes.deinit(c.scratch());
        var chunks: std.ArrayList(Atom) = .empty;
        defer chunks.deinit(c.scratch());
        for (c.tree.nodeRange(node)) |sub| {
            const st = if (sub != null_node) try c.checkExprCached(sub, types.no_type) else types.string_type;
            try holes.append(c.scratch(), st);
            const ctok = c.templateChunkTokAfter(main_tok, c.nodeSpan(sub).end);
            try chunks.append(c.scratch(), try c.atom(c.templateChunkText(ctok)));
        }
        if (holes.items.len == 0) return c.ts.makeStringLiteral(head, false);
        return c.reduceTemplateChunks(head, holes.items, chunks.items);
    }

    fn templateTypeFromNode(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const e = c.tree.extraData(ast.TemplateLitType, d.lhs);
        const head = try c.atom(c.templateHeadText(c.tree.nodeMainToken(node)));
        const hole_nodes = c.tree.extraRange(e.holes_start, e.holes_end);
        const chunk_toks = c.tree.extraRange(e.chunks_start, e.chunks_end);
        if (hole_nodes.len == 0) return c.ts.makeStringLiteral(head, false);
        var holes: std.ArrayList(TypeId) = .empty;
        defer holes.deinit(c.scratch());
        var chunks: std.ArrayList(Atom) = .empty;
        defer chunks.deinit(c.scratch());
        for (hole_nodes, 0..) |hn, i| {
            try holes.append(c.scratch(), try c.typeFromTypeNode(hn));
            const ct = if (i < chunk_toks.len) try c.atom(c.templateChunkText(chunk_toks[i])) else try c.atom("");
            try chunks.append(c.scratch(), ct);
        }
        return c.reduceTemplateChunks(head, holes.items, chunks.items);
    }

    /// Re-evaluate a template from an existing template-literal `tpl` (reuses
    /// its stored chunk atoms) with fresh `holes` (post-substitution).
    fn reduceTemplate(c: *Checker, head: Atom, holes: []const TypeId, tpl: TypeId) Error!TypeId {
        var chunks: std.ArrayList(Atom) = .empty;
        defer chunks.deinit(c.scratch());
        for (0..c.ts.templateHoleCount(tpl)) |i| try chunks.append(c.scratch(), c.ts.templateChunk(tpl, @intCast(i)));
        return c.reduceTemplateChunks(head, holes, chunks.items);
    }

    /// A partially-evaluated template builder: a concrete `head` string plus a
    /// list of committed *pattern* holes (a non-enumerable hole type and the
    /// literal text that follows it). Concrete/enumerable text is folded into
    /// `head` (no pattern holes yet) or into the last hole's `chunk`.
    const TplBuilder = struct {
        head: std.ArrayList(u8),
        holes: std.ArrayList(TypeId),
        chunks: std.ArrayList(std.ArrayList(u8)),
    };

    /// The single evaluation point for a template-literal type (build time +
    /// each instantiation). Defers (keeps the template symbolic) while any hole
    /// is still generic; otherwise cross-products the enumerable holes and
    /// keeps non-enumerable (`string`/`number`) holes as a pattern. Counted
    /// against the TS2589 depth/count budget.
    fn reduceTemplateChunks(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
        if (c.inst_depth > max_instantiation_depth or c.inst_count > max_instantiation_count) {
            c.inst_limit_tripped = true;
            if (!c.suppress_inst_diag) try c.diagFmt(2589, c.inst_span, "Type instantiation is excessively deep and possibly infinite.", .{});
            return types.error_type;
        }
        c.inst_depth += 1;
        c.inst_count += 1;
        defer c.inst_depth -= 1;
        // Still generic in any hole → defer (keep the deferred template type).
        for (holes) |h| {
            if (try c.containsTypeParam(h) or try c.containsMappedParam(h) or try c.containsInfer(h)) {
                return c.ts.makeTemplateLiteral(head, holes, chunks);
            }
        }
        return c.evalTemplate(head, holes, chunks);
    }

    /// Concrete cross-product evaluation. Produces a union of string-literal
    /// types (all holes enumerable) and/or template-literal *pattern* types
    /// (some hole is a bare `string`/`number`). Bounds the working set by the
    /// M15 count limit; on explosion trips TS2589 (bounded, never hangs).
    fn evalTemplate(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
        const gpa = c.scratch();
        var builders: std.ArrayList(TplBuilder) = .empty;
        defer {
            for (builders.items) |*b| freeBuilder(gpa, b);
            builders.deinit(gpa);
        }
        {
            var b0: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
            try b0.head.appendSlice(gpa, c.atomText(head));
            try builders.append(gpa, b0);
        }
        // tsc caps a template-literal union at 100000 members, emitting TS2590
        // past it. Match that so a `${D}${D}${D}${D}${D}` (10^5) blowup trips
        // gracefully instead of materializing millions of string literals.
        const cap: usize = 100_000;
        for (holes, 0..) |hole, i| {
            const chunk_text = c.atomText(chunks[i]);
            var forms: std.ArrayList(Atom) = .empty;
            defer forms.deinit(gpa);
            const enumerable = try c.enumerableForms(hole, &forms);
            var next: std.ArrayList(TplBuilder) = .empty;
            if (enumerable) {
                for (builders.items) |*b| {
                    for (forms.items) |f| {
                        var nb = try cloneBuilder(gpa, b);
                        try appendConcrete(gpa, &nb, c.atomText(f));
                        try appendConcrete(gpa, &nb, chunk_text);
                        try next.append(gpa, nb);
                    }
                    freeBuilder(gpa, b);
                }
            } else {
                for (builders.items) |*b| {
                    var nb = try cloneBuilder(gpa, b);
                    try nb.holes.append(gpa, hole);
                    var ch: std.ArrayList(u8) = .empty;
                    try ch.appendSlice(gpa, chunk_text);
                    try nb.chunks.append(gpa, ch);
                    try next.append(gpa, nb);
                    freeBuilder(gpa, b);
                }
            }
            builders.deinit(gpa);
            builders = next;
            if (builders.items.len >= cap) {
                c.inst_limit_tripped = true;
                try c.diagFmt(2590, c.inst_span, "Expression produces a union type that is too complex to represent.", .{});
                return types.string_type;
            }
        }
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(gpa);
        for (builders.items) |*b| {
            const bhead = try c.internText(b.head.items);
            if (b.holes.items.len == 0) {
                try parts.append(gpa, try c.ts.makeStringLiteral(bhead, false));
            } else {
                var chunk_atoms: std.ArrayList(Atom) = .empty;
                defer chunk_atoms.deinit(gpa);
                for (b.chunks.items) |ch| try chunk_atoms.append(gpa, try c.internText(ch.items));
                try parts.append(gpa, try c.ts.makeTemplateLiteral(bhead, b.holes.items, chunk_atoms.items));
            }
        }
        return c.ts.makeUnion(gpa, parts.items);
    }

    fn cloneBuilder(gpa: std.mem.Allocator, b: *const TplBuilder) Error!TplBuilder {
        var nb: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
        try nb.head.appendSlice(gpa, b.head.items);
        try nb.holes.appendSlice(gpa, b.holes.items);
        for (b.chunks.items) |ch| {
            var c2: std.ArrayList(u8) = .empty;
            try c2.appendSlice(gpa, ch.items);
            try nb.chunks.append(gpa, c2);
        }
        return nb;
    }

    fn freeBuilder(gpa: std.mem.Allocator, b: *TplBuilder) void {
        b.head.deinit(gpa);
        b.holes.deinit(gpa);
        for (b.chunks.items) |*ch| ch.deinit(gpa);
        b.chunks.deinit(gpa);
    }

    /// Append concrete text: into the running `head` while no pattern hole has
    /// been committed, otherwise onto the last committed hole's chunk.
    fn appendConcrete(gpa: std.mem.Allocator, b: *TplBuilder, text: []const u8) Error!void {
        if (b.chunks.items.len == 0) {
            try b.head.appendSlice(gpa, text);
        } else {
            try b.chunks.items[b.chunks.items.len - 1].appendSlice(gpa, text);
        }
    }

    /// If `hole` enumerates to a finite set of concrete strings, append them to
    /// `out` and return true; otherwise (bare `string`/`number`, deferred
    /// intrinsic, …) return false — the hole must stay a pattern.
    fn enumerableForms(c: *Checker, hole0: TypeId, out: *std.ArrayList(Atom)) Error!bool {
        const s = &c.ts;
        const hole = try c.resolveStructural(hole0);
        switch (s.kind(hole)) {
            .string_literal => {
                try out.append(c.scratch(), s.literalAtom(hole));
                return true;
            },
            .number_literal, .number_literal_fresh => {
                try out.append(c.scratch(), try c.numberLiteralAtom(hole));
                return true;
            },
            .bigint_literal => {
                try out.append(c.scratch(), s.literalAtom(hole));
                return true;
            },
            .bool_true => {
                try out.append(c.scratch(), try c.atom("true"));
                return true;
            },
            .bool_false => {
                try out.append(c.scratch(), try c.atom("false"));
                return true;
            },
            // `boolean` interpolates as the union `"false" | "true"`.
            .boolean => {
                try out.append(c.scratch(), try c.atom("false"));
                try out.append(c.scratch(), try c.atom("true"));
                return true;
            },
            .null => {
                try out.append(c.scratch(), try c.atom("null"));
                return true;
            },
            .undefined => {
                try out.append(c.scratch(), try c.atom("undefined"));
                return true;
            },
            .union_type => {
                for (try c.memberList(hole)) |m| {
                    if (!try c.enumerableForms(m, out)) return false;
                }
                return true;
            },
            // The `Core & string` template-hole idiom, generalized: `"a" & string`
            // (a single literal), `("a"|"b") & string` (a literal UNION, which the
            // single-literal `stringLiteralOf` path missed — it left the hole a
            // malformed pattern), and — the load-bearing case for recursive
            // path builders — `PathInternal<V, …> & string` where the non-primitive
            // member is an alias `.ref` inside the hole. Each member is resolved
            // structurally, which DRIVES such a ref home (e.g. `PInt<{deep}>` →
            // `"deep"`) under the ordinary shrinking discipline; the string/number
            // primitive constraint is absorbed and the sole literal core enumerates.
            // Two non-primitive members (a genuine literal-vs-literal intersection)
            // or a non-enumerable core fall back to keeping the hole a pattern.
            .intersection => {
                var core: TypeId = types.no_type;
                for (try c.memberList(hole)) |m0| {
                    const m = try c.resolveStructural(m0);
                    switch (s.kind(m)) {
                        // primitive supertypes absorbed by a string/number literal
                        .string, .number, .bigint => {},
                        else => {
                            if (core != types.no_type) return false;
                            core = m;
                        },
                    }
                }
                if (core != types.no_type) return c.enumerableForms(core, out);
                return false;
            },
            else => return false, // string / number / pattern / mapping → keep as pattern
        }
    }

    /// The single concrete string-literal atom `t` denotes, seeing through a
    /// `literal & primitive` intersection (`"a" & string` → `"a"`). Null when
    /// `t` is not a single concrete string.
    fn stringLiteralOf(c: *Checker, t0: TypeId) Error!?Atom {
        const s = &c.ts;
        const t = try c.resolveStructural(t0);
        return switch (s.kind(t)) {
            .string_literal => s.literalAtom(t),
            .number_literal, .number_literal_fresh => try c.numberLiteralAtom(t),
            .intersection => blk: {
                for (try c.memberList(t)) |m| {
                    if (s.kind(m) == .string_literal) break :blk s.literalAtom(m);
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// Apply a string-transform intrinsic. Concrete string → transformed
    /// string-literal; union → distribute; still-generic arg → defer as a
    /// `string_mapping` type. `string` itself maps to `string`.
    fn applyStringMapping(c: *Checker, kind_idx: u32, arg0: TypeId) Error!TypeId {
        const s = &c.ts;
        const arg = try c.resolveStructural(arg0);
        switch (s.kind(arg)) {
            .string => return types.string_type,
            .any, .err => return arg,
            .never => return types.never_type,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(arg)) |m| try parts.append(c.scratch(), try c.applyStringMapping(kind_idx, m));
                return s.makeUnion(c.scratch(), parts.items);
            },
            else => {},
        }
        if (try c.stringLiteralOf(arg)) |atom_| {
            const src = c.atomText(atom_);
            const buf = try c.scratch().alloc(u8, src.len);
            defer c.scratch().free(buf);
            transformString(kind_idx, src, buf);
            return s.makeStringLiteral(try c.internText(buf), false);
        }
        // Still generic (type param / mapped_param / infer / nested template
        // pattern / another mapping) → defer.
        return s.makeStringMapping(kind_idx, arg);
    }

    fn transformString(kind_idx: u32, src: []const u8, dst: []u8) void {
        for (src, 0..) |ch, i| dst[i] = ch;
        switch (kind_idx) {
            types.string_mapping_uppercase => for (dst) |*ch| {
                ch.* = std.ascii.toUpper(ch.*);
            },
            types.string_mapping_lowercase => for (dst) |*ch| {
                ch.* = std.ascii.toLower(ch.*);
            },
            types.string_mapping_capitalize => if (dst.len > 0) {
                dst[0] = std.ascii.toUpper(dst[0]);
            },
            types.string_mapping_uncapitalize => if (dst.len > 0) {
                dst[0] = std.ascii.toLower(dst[0]);
            },
            else => {},
        }
    }

    /// Does concrete `text` match template-literal pattern `tpl`? Used for
    /// `"axb"`-assignable-to-`` `a${string}b` ``. Backtracks over occurrences of
    /// each hole's following literal so multi-hole patterns match soundly.
    fn matchTemplatePattern(c: *Checker, text: []const u8, tpl: TypeId) Error!bool {
        const head = c.atomText(c.ts.templateHead(tpl));
        if (!std.mem.startsWith(u8, text, head)) return false;
        return c.matchTplHole(text[head.len..], tpl, 0);
    }

    fn matchTplHole(c: *Checker, rest: []const u8, tpl: TypeId, i: u32) Error!bool {
        const s = &c.ts;
        const n = s.templateHoleCount(tpl);
        if (i == n) return rest.len == 0;
        const hole = s.templateHole(tpl, i);
        const chunk = c.atomText(s.templateChunk(tpl, i));
        if (i + 1 == n) {
            if (!std.mem.endsWith(u8, rest, chunk)) return false;
            return c.holeAccepts(hole, rest[0 .. rest.len - chunk.len]);
        }
        if (chunk.len == 0) {
            var split: usize = 0;
            while (split <= rest.len) : (split += 1) {
                if ((try c.holeAccepts(hole, rest[0..split])) and try c.matchTplHole(rest[split..], tpl, i + 1)) return true;
            }
            return false;
        }
        var from: usize = 0;
        while (std.mem.indexOf(u8, rest[from..], chunk)) |rel| {
            const pos = from + rel;
            if ((try c.holeAccepts(hole, rest[0..pos])) and try c.matchTplHole(rest[pos + chunk.len ..], tpl, i + 1)) return true;
            from = pos + 1;
        }
        return false;
    }

    /// Whether a template pattern hole type admits the substring `str`.
    fn holeAccepts(c: *Checker, hole0: TypeId, str: []const u8) Error!bool {
        const s = &c.ts;
        const hole = try c.resolveStructural(hole0);
        switch (s.kind(hole)) {
            .string, .any, .err => return true,
            .number => return isNumericString(str),
            .bigint => return isNumericString(str),
            .boolean => return std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "false"),
            .bool_true => return std.mem.eql(u8, str, "true"),
            .bool_false => return std.mem.eql(u8, str, "false"),
            .string_literal => return std.mem.eql(u8, str, c.atomText(s.literalAtom(hole))),
            .number_literal, .number_literal_fresh => return std.mem.eql(u8, str, c.atomText(try c.numberLiteralAtom(hole))),
            .union_type => {
                for (try c.memberList(hole)) |m| {
                    if (try c.holeAccepts(m, str)) return true;
                }
                return false;
            },
            .template_literal_type => return c.matchTemplatePattern(str, hole),
            else => return false,
        }
    }

    fn isNumericString(str: []const u8) bool {
        if (str.len == 0) return false;
        _ = std.fmt.parseFloat(f64, str) catch return false;
        return true;
    }

    // =====================================================================
    // properties & type parts
    // =====================================================================

    /// Property of a *structural* type (call resolveStructural first).
    /// Handles objects, intersections, arrays/tuples/strings (`length`),
    /// and type params (via constraint).
    fn propOfType(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
        return c.propOfTypeEx(t, name, true);
    }

    /// Named-property lookup. `allow_index=true` (the member-access default)
    /// lets a string index signature stand in for any name — `obj.foo` on a
    /// `{ [k: string]: V }` yields `V`. `allow_index=false` is the *assignability*
    /// rule: a source's index signature does NOT satisfy a required *named*
    /// target property (tsc reports TS2741/TS2740), so `{ [k: string]: any }` is
    /// not assignable to `Date`/`{ x: number }`. Only the relation callers pass
    /// false; the index signature is related separately (indexSignaturesRelatedTo).
    fn propOfTypeEx(c: *Checker, t: TypeId, name: Atom, allow_index: bool) Error!?types.Prop {
        const s = &c.ts;
        switch (s.kind(t)) {
            .object => {
                if (s.objectPropByName(t, name)) |p| return p;
                if (allow_index and s.objectStringIndex(t) != 0) {
                    return .{ .name = name, .ty = s.objectStringIndex(t), .flags = 0 };
                }
                // A callable object/interface (one carrying call/construct
                // signatures, e.g. react-i18next `TFunction`) inherits the
                // apparent members of the global `Function` interface
                // (`.bind`/`.call`/`.apply`/`.name`/`.length`/…). Plain
                // (non-callable) objects do NOT — an absent member stays TS2339.
                if (s.objectCallSigCount(t) > 0 or s.objectConstructSigCount(t) > 0) {
                    return c.functionInterfaceProp(name);
                }
                return null;
            },
            .intersection => {
                var found: ?types.Prop = null;
                for (try c.memberList(t)) |m| {
                    const r = try c.resolveStructural(m);
                    if (try c.propOfTypeEx(r, name, allow_index)) |p| {
                        if (found == null) {
                            found = p;
                        } else {
                            const merged = try c.ts.makeIntersection(c.scratch(), &.{ found.?.ty, p.ty });
                            found = .{ .name = name, .ty = merged, .flags = found.?.flags & p.flags };
                        }
                    }
                }
                return found;
            },
            .array, .tuple, .string, .string_literal => {
                if (name == c.atom_length) {
                    if (s.kind(t) == .tuple) {
                        var has_var = false;
                        for (0..s.tupleLen(t)) |i| {
                            const e = s.tupleElem(t, @intCast(i));
                            if (e.optional() or e.rest()) has_var = true;
                        }
                        if (!has_var) {
                            return .{ .name = name, .ty = try s.makeNumberLiteral(@floatFromInt(s.tupleLen(t)), false), .flags = types.prop_flag_readonly };
                        }
                    }
                    // `Array<T>.length` is *writable* in tsc (`arr.length = 0`
                    // is idiomatic truncation); `string.length` and a fixed
                    // tuple's length (above) are readonly.
                    const flags: u32 = if (s.kind(t) == .array) 0 else types.prop_flag_readonly;
                    return .{ .name = name, .ty = types.number_type, .flags = flags };
                }
                return c.primitiveInterfaceProp(t, name);
            },
            .number, .number_literal, .number_literal_fresh, .boolean, .bool_true, .bool_false => {
                return c.primitiveInterfaceProp(t, name);
            },
            .type_param => {
                const constraint = try c.typeParamConstraint(s.typeParamSymbol(t));
                if (constraint == types.no_type) return null;
                return c.propOfTypeEx(try c.resolveStructural(constraint), name, allow_index);
            },
            .ref => return c.propOfTypeEx(try c.resolveStructural(t), name, allow_index),
            .class_value => return c.propOfTypeEx(try c.classStaticType(s.classSymbol(t)), name, allow_index),
            .enum_type => {
                // A value of enum type borrows its base primitive's members.
                const info = try c.enumInfo(s.enumSymbol(t));
                const base: TypeId = if (info.all_string) types.string_type else types.number_type;
                return c.propOfTypeEx(base, name, allow_index);
            },
            // A bare function type or overload set (arrow/normal function,
            // `(x) => y`, an overloaded signature) has the apparent members of
            // the global `Function` interface.
            .function, .overloads => return c.functionInterfaceProp(name),
            else => return null,
        }
    }

    /// Look `name` up on the global `Function` interface — the apparent members
    /// (`bind`/`call`/`apply`/`name`/`length`/`toString`/…) that tsc gives every
    /// function-shaped type. Returns null when the lib has no `Function`
    /// interface (`--noLib`) or the property genuinely isn't a `Function`
    /// member, so a bogus member on a callable still degrades to TS2339.
    fn functionInterfaceProp(c: *Checker, name: Atom) Error!?types.Prop {
        const sym = c.prog.globals.lookup(c.atom_Function) orelse return null;
        if (!c.symFlags(sym).interface) return null;
        const ref = try c.ts.makeRef(sym, &.{});
        return c.propOfType(try c.resolveStructural(ref), name);
    }

    /// Bridge a primitive/array/tuple to its lib interface (M10) and look
    /// the property up there: `arr.map` -> `Array<T>.map`, `"x".toUpperCase`
    /// -> `String.toUpperCase`, etc. Returns null when no lib is loaded or
    /// the interface is missing, so member access degrades to TS2339 exactly
    /// as it did lib-free.
    fn primitiveInterfaceProp(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
        const s = &c.ts;
        var iface_atom: Atom = 0;
        var elem: TypeId = types.no_type;
        var has_elem = false;
        switch (s.kind(t)) {
            .array => {
                iface_atom = c.atom_Array;
                elem = s.arrayElem(t);
                has_elem = true;
            },
            .tuple => {
                iface_atom = c.atom_Array;
                elem = try c.tupleElementUnion(t);
                has_elem = true;
            },
            .string, .string_literal => iface_atom = c.atom_String,
            .number, .number_literal, .number_literal_fresh => iface_atom = c.atom_Number,
            .boolean, .bool_true, .bool_false => iface_atom = c.atom_Boolean,
            else => return null,
        }
        const sym = c.prog.globals.lookup(iface_atom) orelse return null;
        if (!c.symFlags(sym).interface) return null;
        const args: []const TypeId = if (has_elem) &.{elem} else &.{};
        const ref = try s.makeRef(sym, args);
        return c.propOfType(try c.resolveStructural(ref), name);
    }

    /// Wrap `payload` in the global `Promise<T>` (M11). Falls back to `any`
    /// when the lib has no `Promise` interface (e.g. `--noLib`).
    fn makePromise(c: *Checker, payload: TypeId) Error!TypeId {
        const sym = c.prog.globals.lookup(c.atom_Promise) orelse return types.any_type;
        if (!c.symFlags(sym).interface) return types.any_type;
        return c.ts.makeRef(sym, &.{payload});
    }

    /// Whether `t` is a `.ref` to `Promise`/`PromiseLike` whose first type
    /// argument is exactly the type parameter `tp_sym` (the `PromiseLike<T>`
    /// member of a `.then` onfulfilled return `T | PromiseLike<T>`).
    fn isPromiseLikeOf(c: *Checker, t: TypeId, tp_sym: u32) bool {
        if (c.ts.kind(t) != .ref) return false;
        const sym = c.ts.refSymbol(t);
        const p = c.prog.globals.lookup(c.atom_Promise);
        const pl = c.prog.globals.lookup(c.atom_PromiseLike);
        if ((p == null or sym != p.?) and (pl == null or sym != pl.?)) return false;
        const args = c.ts.refArgs(t);
        if (args.len == 0) return false;
        return c.ts.kind(args[0]) == .type_param and c.ts.typeParamSymbol(args[0]) == tp_sym;
    }

    /// Single-level `Awaited<T>`: unwrap a `Promise<T>` to `T`; any other type
    /// passes through (await on a non-thenable yields the value itself).
    /// Deeper `Awaited<T>` recursion (`Promise<Promise<T>>`) is a known gap.
    fn awaitedType(c: *Checker, t: TypeId) Error!TypeId {
        // `Awaited<T>` distributes over unions: `await (Promise<X> | undefined)`
        // is `X | undefined` (tsc). Without this, a `Promise<X> | undefined`
        // receiver — common now that optional chains yield `... | undefined` —
        // fails to unwrap and surfaces spurious property/callable errors.
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.awaitedType(m));
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        if (c.ts.kind(t) == .ref) {
            const sym = c.prog.globals.lookup(c.atom_Promise) orelse return t;
            if (c.ts.refSymbol(t) == sym) {
                const args = c.ts.refArgs(t);
                if (args.len >= 1) return args[0];
            }
        }
        return t;
    }

    /// If `t` is a ref to one of the lib's iterator interfaces whose first
    /// type arg is the yield element (`Generator<T>`/`Iterator<T>`/
    /// `IterableIterator<T>`, plus the TS ≥5.6 `IteratorObject<T>` and the
    /// named built-in iterators like `MapIterator<T>`), return that `T`;
    /// otherwise 0.
    fn generatorYieldType(c: *Checker, t: TypeId) TypeId {
        if (c.ts.kind(t) != .ref) return 0;
        const sym = c.ts.refSymbol(t);
        const names = [_]Atom{
            c.atom_Generator,      c.atom_Iterator,       c.atom_IterableIterator,
            c.atom_IteratorObject, c.atom_ArrayIterator,  c.atom_MapIterator,
            c.atom_SetIterator,    c.atom_StringIterator, c.atom_RegExpStringIterator,
        };
        for (names) |name| {
            const g = c.prog.globals.lookup(name) orelse continue;
            if (sym == g) {
                const args = c.ts.refArgs(t);
                if (args.len >= 1) return args[0];
                return 0;
            }
        }
        return 0;
    }

    /// Async analogue of `generatorYieldType`: the first type arg of a lib
    /// async-iterator ref (`AsyncGenerator<T>`/`AsyncIterator<T>`/
    /// `AsyncIterableIterator<T>`/`AsyncIteratorObject<T>`), else 0.
    fn asyncGeneratorYieldType(c: *Checker, t: TypeId) TypeId {
        if (c.ts.kind(t) != .ref) return 0;
        const sym = c.ts.refSymbol(t);
        const names = [_]Atom{
            c.atom_AsyncGenerator,        c.atom_AsyncIterator,
            c.atom_AsyncIterableIterator, c.atom_AsyncIteratorObject,
        };
        for (names) |name| {
            const g = c.prog.globals.lookup(name) orelse continue;
            if (sym == g) {
                const args = c.ts.refArgs(t);
                if (args.len >= 1) return args[0];
                return 0;
            }
        }
        return 0;
    }

    /// Union of a tuple's element types (the element type used when a tuple
    /// borrows `Array<T>` members).
    fn tupleElementUnion(c: *Checker, t: TypeId) Error!TypeId {
        const s = &c.ts;
        const n = s.tupleLen(t);
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (0..n) |i| try parts.append(c.scratch(), s.tupleElem(t, @intCast(i)).ty);
        return s.makeUnion(c.scratch(), parts.items);
    }

    /// Uninferred own-type-param value for contextual signature instantiation:
    /// declared default, else constraint, else `unknown` (tsc's order).
    fn typeParamFallback(c: *Checker, sym: SymbolId) Error!TypeId {
        const d = try c.typeParamDefault(sym);
        if (d != types.no_type) return d;
        const con = try c.typeParamConstraint(sym);
        if (con != types.no_type) return con;
        return types.unknown_type;
    }

    fn typeParamConstraint(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.isFreshTp(sym)) return c.freshTp(sym).constraint;
        if (c.inst_cache_on) {
            if (c.tp_constraint_cache.get(sym)) |t| return t;
        }
        const result = try c.typeParamConstraintUncached(sym);
        if (c.inst_cache_on) try c.tp_constraint_cache.put(c.ca(), sym, result);
        return result;
    }

    fn typeParamConstraintUncached(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        const decls = c.declsOf(sym);
        for (decls) |decl| {
            if (c.nodeTag(decl) != .type_param) continue;
            const d = c.tree.nodeData(decl);
            if (d.lhs == 0) return types.no_type;
            c.cur_scope = c.symScope(sym);
            return c.typeFromTypeNode(d.lhs);
        }
        return types.no_type;
    }

    /// The default type of a type parameter (`<T = D>`), evaluated in its
    /// declaring file + declaration scope, or `no_type` if it has none. The
    /// result references earlier type-params as their type-param types; a
    /// caller wanting `B = A` to see the supplied `A` must instantiate the
    /// result under the mapping resolved so far.
    fn typeParamDefault(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.isFreshTp(sym)) return c.freshTp(sym).default;
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .type_param) continue;
            const d = c.tree.nodeData(decl);
            if (d.rhs == 0) return types.no_type;
            c.cur_scope = c.symScope(sym);
            return c.typeFromTypeNode(d.rhs);
        }
        return types.no_type;
    }

    /// Whether a type parameter declares a default (`<T = D>`).
    fn typeParamHasDefault(c: *Checker, sym: SymbolId) bool {
        if (c.isFreshTp(sym)) return c.freshTp(sym).has_default;
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .type_param) continue;
            return c.tree.nodeData(decl).rhs != 0;
        }
        return false;
    }

    /// Minimum required type-argument count for a signature: type params up to
    /// the first defaulted one (defaults are trailing-only, so this is the
    /// count of params without a default).
    fn sigMinTargs(c: *Checker, tps: []const u32) usize {
        var min: usize = 0;
        for (tps) |tp| {
            if (!c.typeParamHasDefault(tp)) min += 1;
        }
        return min;
    }

    /// Whether `n` explicit type arguments satisfy a signature's arity given
    /// defaults: `min <= n <= tps.len`.
    fn sigTargArityOk(c: *Checker, sig: TypeId, n: usize) bool {
        const tps = c.ts.fnTypeParams(sig);
        if (n > tps.len) return false;
        return n >= c.sigMinTargs(tps);
    }

    fn removeUndefined(c: *Checker, t: TypeId) Error!TypeId {
        return c.filterUnion(t, struct {
            fn keep(ch: *Checker, m: TypeId) bool {
                return ch.ts.kind(m) != .undefined;
            }
        }.keep);
    }

    fn nonNullable(c: *Checker, t: TypeId) Error!TypeId {
        return c.filterUnion(t, struct {
            fn keep(ch: *Checker, m: TypeId) bool {
                const k = ch.ts.kind(m);
                return k != .undefined and k != .null;
            }
        }.keep);
    }

    fn filterUnion(c: *Checker, t: TypeId, comptime keep: fn (*Checker, TypeId) bool) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                if (keep(c, m)) try parts.append(c.scratch(), m);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        return if (keep(c, t)) t else types.never_type;
    }

    fn containsNullish(c: *Checker, t: TypeId) bool {
        return c.unionAnyMember(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                const k = ch.ts.kind(m);
                return k == .null or k == .undefined or k == .void or k == .unknown;
            }
        }.f);
    }

    fn containsNull(c: *Checker, t: TypeId) bool {
        return c.unionAnyMember(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                return ch.ts.kind(m) == .null;
            }
        }.f);
    }

    fn containsUndefinedish(c: *Checker, t: TypeId) bool {
        return c.unionAnyMember(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                const k = ch.ts.kind(m);
                return k == .undefined or k == .void;
            }
        }.f);
    }

    fn unionAnyMember(c: *Checker, t: TypeId, comptime f: fn (*Checker, TypeId) bool) bool {
        if (c.ts.kind(t) == .union_type) {
            for (c.ts.members(t)) |m| {
                if (f(c, m)) return true;
            }
            return false;
        }
        return f(c, t);
    }

    /// The definitely-truthy part of `t` (removes null/undefined/false/
    /// falsy literals; boolean -> true; object types kept).
    fn getTruthyPart(c: *Checker, t: TypeId) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const p = try c.getTruthyPart(m);
                if (p != types.never_type) try parts.append(c.scratch(), p);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        const s = &c.ts;
        return switch (s.kind(t)) {
            .null, .undefined, .void, .bool_false => types.never_type,
            .boolean => types.true_type,
            .string_literal => if (c.atomText(s.literalAtom(t)).len == 0) types.never_type else t,
            .number_literal, .number_literal_fresh => if (s.numberValue(t) == 0) types.never_type else t,
            .bigint_literal => blk: {
                const text = c.atomText(s.literalAtom(t));
                break :blk if (isZeroBigInt(text)) types.never_type else t;
            },
            else => t,
        };
    }

    /// The definitely-falsy part of `t` (tsc's `A && B` left contribution
    /// and falsy-branch narrowing): string -> "", number -> 0, boolean ->
    /// false, bigint -> 0n; object types contribute nothing.
    fn getFalsyPart(c: *Checker, t: TypeId, for_narrowing: bool) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const p = try c.getFalsyPart(m, for_narrowing);
                if (p != types.never_type) try parts.append(c.scratch(), p);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        const s = &c.ts;
        return switch (s.kind(t)) {
            .null, .undefined, .void, .bool_false => t,
            .boolean => types.false_type,
            .bool_true => types.never_type,
            .any, .err => types.any_type,
            .unknown => types.unknown_type,
            .string => if (for_narrowing) types.string_type else try s.makeStringLiteral(try c.atom(""), false),
            .number => if (for_narrowing) types.number_type else try s.makeNumberLiteral(0, false),
            .bigint => if (for_narrowing) types.bigint_type else try s.makeBigIntLiteral(try c.atom("0n"), false),
            .string_literal => if (c.atomText(s.literalAtom(t)).len == 0) t else types.never_type,
            .number_literal, .number_literal_fresh => if (s.numberValue(t) == 0) t else types.never_type,
            .bigint_literal => if (isZeroBigInt(c.atomText(s.literalAtom(t)))) t else types.never_type,
            else => types.never_type, // objects, functions, tuples, refs...
        };
    }

    fn isZeroBigInt(text: []const u8) bool {
        for (text) |ch| {
            if (ch >= '1' and ch <= '9') return false;
        }
        return true;
    }

    // =====================================================================
    // assignability
    // =====================================================================

    fn isComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
        return (try c.isAssignable(a, b)) or (try c.isAssignable(b, a));
    }

    /// The `as`-cast overlap test (TS2352). tsc uses its *comparable* relation
    /// here, which is strictly more lenient than mutual assignability: an
    /// optional source property may satisfy a required target property
    /// (`{ legends?: X[] }` overlaps `{ legends: X[] }`). ztsc's isComparable
    /// (assignable either way) misses exactly that case, so after the two
    /// assignability probes fail, retry each direction with the optional→
    /// required leniency. Kept to the cast site only — narrowing/discriminant
    /// uses of isComparable are unchanged.
    fn castComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
        return c.castComparableRec(a, b, 0);
    }

    /// tsc's *comparable* relation distributes over unions existentially and
    /// resolves a type parameter to its constraint. A cast `x as T` where `T`
    /// is a type parameter is legal iff `x` is comparable to `T`'s constraint —
    /// and an unconstrained parameter (constraint `unknown`/`any`) is
    /// comparable to anything, since it could be instantiated to `x`'s type.
    /// Likewise a union on either side is comparable iff SOME constituent is
    /// (`{full_name} as ({full_name; id} | null)` overlaps the non-null branch).
    /// Oracle-verified: a *constrained* parameter still rejects a
    /// non-overlapping cast (`T extends {a} as {b}`), and a union rejects only
    /// when NO constituent overlaps (`{q} as (number | boolean)`).
    fn castComparableRec(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
        if (depth > 8) return true; // under-report over false-reject, per policy
        const a = try c.resolveStructural(a0);
        const b = try c.resolveStructural(b0);
        // Type parameter on either side → defer to its constraint; unconstrained
        // (or unknown/any constraint) overlaps everything.
        if (c.ts.kind(a) == .type_param) {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(a));
            if (con == types.no_type or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any or con == a) return true;
            return c.castComparableRec(con, b0, depth + 1);
        }
        if (c.ts.kind(b) == .type_param) {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(b));
            if (con == types.no_type or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any or con == b) return true;
            return c.castComparableRec(a0, con, depth + 1);
        }
        // Existential union distribution on either side.
        if (c.ts.kind(a) == .union_type) {
            for (try c.memberList(a)) |m| {
                if (try c.castComparableRec(m, b0, depth + 1)) return true;
            }
            return false;
        }
        if (c.ts.kind(b) == .union_type) {
            for (try c.memberList(b)) |m| {
                if (try c.castComparableRec(a0, m, depth + 1)) return true;
            }
            return false;
        }
        if (try c.isComparable(a0, b0)) return true;
        return (try c.lenientOverlap(a0, b0, depth)) or (try c.lenientOverlap(b0, a0, depth));
    }

    /// One direction of the lenient comparable relation: does source `s0`
    /// overlap target `t0` when optional source props may satisfy required
    /// target props? Only the object/object and array/array shapes get the
    /// leniency (the shapes where optionality lives); anything else defers to
    /// the ordinary comparable check. Depth-capped at 8 — beyond that it
    /// answers `true` (under-report, per policy: a cast that deep is not worth
    /// a false rejection).
    fn lenientOverlap(c: *Checker, s0: TypeId, t0: TypeId, depth: u32) Error!bool {
        if (depth > 8) return true;
        const s = try c.resolveStructural(s0);
        const t = try c.resolveStructural(t0);
        const sk = c.ts.kind(s);
        const tk = c.ts.kind(t);
        if (sk == .array and tk == .array) {
            return c.lenientComparable(c.ts.arrayElem(s), c.ts.arrayElem(t), depth + 1);
        }
        // Comparability distributes over a target intersection: the source must
        // overlap EACH constituent (tsc `typeRelatedToEachType`). The dogfood
        // cast `{…} as (A & { id: string })` overlaps in the `comparable(target,
        // source)` direction — the relation *source* is then the intersection,
        // so the object arm below reaches its members via `propOfType`.
        if (tk == .intersection) {
            for (try c.memberList(t)) |m| {
                if (!try c.lenientOverlap(s0, m, depth)) return false;
            }
            return true;
        }
        if (tk == .object) {
            for (0..c.ts.objectPropCount(t)) |i| {
                const tp = c.ts.objectProp(t, @intCast(i));
                // `propOfType` (unlike `objectPropByName`) reaches through a
                // source intersection / ref / string index signature, so the
                // winning direction — where the intersection being cast to is
                // the relation *source* — resolves each target member. Optional
                // target props may be absent (the optional→required leniency);
                // present props need only be comparable (either direction).
                const sp = (try c.propOfType(s, tp.name)) orelse {
                    if (tp.optional()) continue;
                    return false; // required target member absent from source
                };
                if (!try c.lenientComparable(sp.ty, tp.ty, depth + 1)) return false;
            }
            return true;
        }
        return false; // non-object shapes: the isComparable probes already ruled
    }

    fn lenientComparable(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
        // Nested comparability (array elements, object props) distributes over
        // unions and resolves type-parameter constraints exactly like the
        // top-level cast — an array of a union of literals overlaps an array of
        // an intersection element when SOME source constituent overlaps.
        return c.castComparableRec(a, b, depth);
    }

    /// Union-distributing overlap test for TS2367/TS2678: some pair of
    /// constituents must be comparable.
    fn typesHaveOverlap(c: *Checker, a: TypeId, b: TypeId) Error!bool {
        if (c.ts.kind(a) == .union_type) {
            for (try c.memberList(a)) |m| {
                if (try c.typesHaveOverlap(m, b)) return true;
            }
            return false;
        }
        if (c.ts.kind(b) == .union_type) {
            for (try c.memberList(b)) |m| {
                if (try c.typesHaveOverlap(a, m)) return true;
            }
            return false;
        }
        // tsc's comparable relation: `null` / `undefined` are comparable to
        // every type, so an equality test against (or of) a nullish operand is
        // never TS2367 — `x === null` is the idiomatic guard even when `x`'s
        // declared type can't be null (oracle-verified: `number === null`,
        // `string === undefined`, `null === undefined` are all clean).
        const ka = c.ts.kind(a);
        const kb = c.ts.kind(b);
        if (ka == .null or ka == .undefined or kb == .null or kb == .undefined) return true;
        // tsc's *comparable* relation: a string enum overlaps a string literal
        // equal to one of its member values (`x === 'FEMALE'` where `enum
        // CattleSex { Female = 'FEMALE' }`), even though the plain literal is not
        // *assignable* into the nominal string enum. Only a member-value match
        // overlaps — a non-member literal (`x === 'ZEBRA'`) stays TS2367. (The
        // numeric-enum ↔ number-literal case already overlaps via `isComparable`
        // → `enumAssignable`.)
        const ra = try c.ts.regularLiteral(a);
        const rb = try c.ts.regularLiteral(b);
        if (c.ts.kind(ra) == .enum_type and c.ts.kind(rb) == .string_literal) {
            if (try c.enumHasStringValue(c.ts.enumSymbol(ra), c.ts.literalAtom(rb))) return true;
        }
        if (c.ts.kind(rb) == .enum_type and c.ts.kind(ra) == .string_literal) {
            if (try c.enumHasStringValue(c.ts.enumSymbol(rb), c.ts.literalAtom(ra))) return true;
        }
        return c.isComparable(a, b);
    }

    fn isAssignable(c: *Checker, s0: TypeId, t0: TypeId) Error!bool {
        // Structural-relation recursion guard (see `max_relation_depth`). Past
        // the cap, assume the pair related — this only drops diagnostics, never
        // adds a false positive. Returns before the `(s,t)` relation memo below,
        // so the capped result is never cached and a shallower re-encounter of
        // the same pair still computes the real answer.
        if (c.rel_depth > max_relation_depth) return true;
        c.rel_depth += 1;
        defer c.rel_depth -= 1;
        // A polymorphic `this` relates through its apparent instance type. This
        // is a subset simplification (true `this` is nominally narrower than
        // the base), but sound for the fluent/builder patterns we support.
        const s1 = if (c.ts.kind(s0) == .this_type) c.ts.thisTypeInstance(s0) else s0;
        const t1 = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
        var s = try c.ts.regularLiteral(s1);
        var t = try c.ts.regularLiteral(t1);
        s = try c.ts.regular(s);
        t = try c.ts.regular(t);
        if (s == t) return true;
        const sk = c.ts.kind(s);
        const tk = c.ts.kind(t);
        // Reflexive origin fast-path (see `origin`): two distinct materialized
        // types (object or function member) that both denote the same generic
        // instantiation `G<A…>` — identical symbol AND element-wise-equal args,
        // so identical interned origin refs — are mutually assignable by
        // identity. This short-circuits the structural walk that would otherwise
        // fail on non-confluent one-step vs two-step reductions of the same
        // type. Identity-only: no variance, it fires solely when the origin refs
        // are equal.
        if (originTaggable(sk) and sk == tk) {
            if (c.origin.get(s)) |os| {
                if (c.origin.get(t)) |ot| {
                    // Reflexive identity: same interned origin ref (see `origin`).
                    if (os == ot) return true;
                    // Variance-free EQUIVALENCE: both denote `G<…>` for the same
                    // `G`, and each arg pair is equal — by TypeId identity or by a
                    // SOUND reduction (`T & {} ≡ T`; interned structural forms
                    // compared by identity, never by mutual assignability). Two
                    // args that are equal types make the two instantiations the
                    // SAME type regardless of `G`'s variance, so the relation is
                    // reflexive. This closes the RTK non-confluence where one
                    // instantiation carries an unreduced config `C1 = P & Omit<…>`
                    // and the other the concrete reduction `C2 = P`.
                    if (c.ts.kind(os) == .ref and c.ts.kind(ot) == .ref and
                        c.ts.refSymbol(os) == c.ts.refSymbol(ot))
                    {
                        if (try c.originArgEquiv(os, ot, 0)) return true;
                    }
                }
            }
        }
        // Trivial targets/sources.
        switch (tk) {
            .any, .err, .unknown, .none => return true,
            else => {},
        }
        if (tk == .never) return sk == .never; // even `any` is not assignable to never
        switch (sk) {
            .any, .err, .never, .none => return true,
            else => {},
        }
        if (tk == .void) return sk == .undefined or sk == .void;

        // Literal -> base primitive.
        const base = c.ts.literalBase(s);
        if (base != types.no_type and base == t) return true;

        // Cache compound comparisons (recursion termination for refs).
        const cacheable = isCompound(sk) or isCompound(tk);
        const key = (@as(u64, s) << 32) | t;
        if (cacheable) {
            if (c.relation.get(key)) |v| {
                c.stats.relation_hits += 1;
                if (v == 2) return true; // in progress: assume (recursive types)
                return v == 1;
            }
            c.stats.relation_misses += 1;
            try c.relation.put(c.ca(), key, 2);
        }
        const result = try c.isAssignableInner(s, t, sk, tk);
        if (cacheable) try c.relation.put(c.ca(), key, @intFromBool(result));
        return result;
    }

    fn isCompound(k: types.Kind) bool {
        return switch (k) {
            .union_type, .intersection, .array, .tuple, .object, .function, .overloads, .ref, .class_value, .conditional, .mapped, .index_access, .template_literal_type, .keyof_op => true,
            else => false,
        };
    }

    fn isAssignableInner(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
        // Deferred conditional *source* is handled first (before union
        // distribution): it resolves to one of its branches, so it is
        // assignable to `t` exactly when *both* branches are — even when `t`
        // is a union. Identity is already caught by `s == t` (hash-consed).
        if (sk == .conditional) {
            if (tk == .conditional and c.ts.condCheck(s) == c.ts.condCheck(t) and c.ts.condExtends(s) == c.ts.condExtends(t)) {
                return (try c.isAssignable(c.ts.condTrue(s), c.ts.condTrue(t))) and
                    (try c.isAssignable(c.ts.condFalse(s), c.ts.condFalse(t)));
            }
            return (try c.isAssignable(c.ts.condTrue(s), t)) and (try c.isAssignable(c.ts.condFalse(s), t));
        }
        // A deferred `keyof T` source (M16d) relates through its apparent
        // constraint `string | number | symbol`; handled before union-target
        // distribution because `keyof T` is assignable to the whole key union,
        // not to any single member. Identity (`keyof T <: keyof T`) is caught
        // by the `s == t` fast path.
        if (sk == .keyof_op) return c.isAssignable(try c.propertyKeyType(), t);
        // Source union distributes first.
        if (sk == .union_type) {
            for (try c.memberList(s)) |m| {
                if (!try c.isAssignable(m, t)) return false;
            }
            return true;
        }
        if (tk == .union_type) {
            for (try c.memberList(t)) |m| {
                if (try c.isAssignable(s, m)) return true;
            }
            return false;
        }
        if (tk == .intersection) {
            for (try c.memberList(t)) |m| {
                if (!try c.isAssignable(s, m)) return false;
            }
            return true;
        }
        if (sk == .intersection) {
            for (try c.memberList(s)) |m| {
                if (try c.isAssignable(m, t)) return true;
            }
            // Fall through: merged-members structural check for object targets.
            if (tk == .object or tk == .ref) {
                return c.structuralAssignable(s, try c.resolveStructural(t));
            }
            return false;
        }
        // Deferred conditional *target*: the source must satisfy whichever
        // branch the conditional resolves to, so require it against both.
        if (tk == .conditional) {
            return (try c.isAssignable(s, c.ts.condTrue(t))) and (try c.isAssignable(s, c.ts.condFalse(t)));
        }
        // Template-literal pattern *target* (M16c): a concrete string literal is
        // assignable iff its text matches the pattern; `string` and non-string
        // sources are not. (Identical patterns / `string` already resolved via
        // `s == t` / `literalBase`.)
        if (tk == .template_literal_type) {
            if (try c.stringLiteralOf(s)) |atom_| return c.matchTemplatePattern(c.atomText(atom_), t);
            // A template-pattern / string-mapping *source* against a pattern
            // target (both subtypes of `string`): ztsc has no pattern↔pattern
            // matcher, so rather than reject valid assignments — a false
            // positive, e.g. `` `a${string}` `` → `` `${string}` `` or
            // `` `hi-${string}` `` → `` `${string}-${string}` `` — it accepts
            // leniently. This under-reports genuine pattern mismatches, which
            // is policy-acceptable for v0.0.1 (identical patterns already
            // resolved via `s == t`). M17.4: was a release-blocking FP.
            if (sk == .template_literal_type or sk == .string_mapping) return true;
            return false;
        }
        // Template-literal pattern *source*: assignable only to `string` (fast
        // path via `literalBase`) or an identical pattern (`s == t`). Reaching
        // here means neither — so no.
        if (sk == .template_literal_type or sk == .string_mapping) return false;
        // Any callable value — arrow/normal functions, overload sets, classes
        // used as values, and callable object/interface types — is assignable
        // to the global `Function` interface. tsc models this via the apparent
        // members a function inherits from `Function`; we special-case the
        // target so an incomplete structural relation against the `Function`
        // interface body can't reject valid code (e.g. `TimerHandler =
        // string | Function` for setInterval/setTimeout). Plain (non-callable)
        // objects are intentionally excluded.
        if (tk == .ref and c.globalSymNamed(c.ts.refSymbol(t), "Function") and try c.isCallableForFunctionIface(s, sk)) return true;
        // Refs: expand and recurse (cache on the ref pair terminates cycles).
        if (sk == .ref or tk == .ref) {
            const rs = try c.resolveStructural(s);
            const rt = try c.resolveStructural(t);
            if (rs == s and rt == t) return false;
            return c.isAssignable(rs, rt);
        }
        // Enum types are nominal (identical enums caught by s == t earlier).
        if (sk == .enum_type or tk == .enum_type) return c.enumAssignable(s, t, sk, tk);
        // Type parameters.
        if (sk == .type_param) {
            const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(s));
            if (constraint != types.no_type) return c.isAssignable(constraint, t);
            return false;
        }
        if (tk == .type_param) return false;

        switch (tk) {
            .boolean => return sk == .bool_true or sk == .bool_false,
            // A `unique symbol` widens to `symbol`; the reverse and cross-decl
            // (distinct `unique symbol`s) are caught by the `s == t` fast path
            // failing above, so nothing else is assignable here.
            .symbol => return sk == .unique_symbol,
            .object_keyword => return isNonPrimitiveKind(sk),
            .array => {
                if (sk == .array) return c.isAssignable(c.ts.arrayElem(s), c.ts.arrayElem(t));
                if (sk == .tuple) {
                    const elem = c.ts.arrayElem(t);
                    for (0..c.ts.tupleLen(s)) |i| {
                        const e = c.ts.tupleElem(s, @intCast(i));
                        const et = if (e.rest()) c.elemOfArrayish(e.ty) else e.ty;
                        if (!try c.isAssignable(et, elem)) return false;
                    }
                    return true;
                }
                return false;
            },
            .tuple => {
                if (sk != .tuple) return false;
                return c.tupleAssignable(s, t);
            },
            .function => {
                if (sk == .function) return c.signatureAssignable(s, t);
                if (sk == .overloads) {
                    for (try c.memberList(s)) |m| {
                        if (try c.signatureAssignable(m, t)) return true;
                    }
                    return false;
                }
                // Callable object → function type (M18.1): some call signature
                // of the object must be assignable to the target function.
                if (sk == .object) {
                    for (0..c.ts.objectCallSigCount(s)) |i| {
                        if (try c.signatureAssignable(c.ts.objectCallSig(s, @intCast(i)), t)) return true;
                    }
                    return false;
                }
                return false;
            },
            .overloads => {
                for (try c.memberList(t)) |m| {
                    if (!try c.isAssignable(s, m)) return false;
                }
                return true;
            },
            .object => return c.structuralAssignable(s, t),
            .class_value => return false,
            else => return false,
        }
    }

    fn isNonPrimitiveKind(k: types.Kind) bool {
        return switch (k) {
            .object, .array, .tuple, .function, .overloads, .ref, .class_value, .intersection, .object_keyword => true,
            else => false,
        };
    }

    /// Does `s` carry a call or construct signature — i.e. is it assignable to
    /// the global `Function` interface? Functions, overload sets and classes
    /// used as values always qualify; object/interface types only if they
    /// declare at least one call or construct signature (plain objects do not).
    fn isCallableForFunctionIface(c: *Checker, s: TypeId, sk: types.Kind) Error!bool {
        switch (sk) {
            .function, .overloads, .class_value => return true,
            .object => return c.ts.objectCallSigCount(s) > 0 or c.ts.objectConstructSigCount(s) > 0,
            .ref => {
                const r = try c.resolveStructural(s);
                if (c.ts.kind(r) == .object) return c.ts.objectCallSigCount(r) > 0 or c.ts.objectConstructSigCount(r) > 0;
                return false;
            },
            else => return false,
        }
    }

    fn tupleAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
        const s_len = c.ts.tupleLen(s);
        const t_len = c.ts.tupleLen(t);
        var t_required: u32 = 0;
        var t_has_rest = false;
        for (0..t_len) |i| {
            const e = c.ts.tupleElem(t, @intCast(i));
            if (e.rest()) t_has_rest = true else if (!e.optional()) t_required += 1;
        }
        var s_min: u32 = 0;
        var s_has_rest = false;
        for (0..s_len) |i| {
            const e = c.ts.tupleElem(s, @intCast(i));
            if (e.rest()) s_has_rest = true else if (!e.optional()) s_min += 1;
        }
        if (s_min < t_required) return false;
        if (!t_has_rest and (s_len > t_len or s_has_rest)) return false;
        for (0..s_len) |i| {
            const se = c.ts.tupleElem(s, @intCast(i));
            const st = if (se.rest()) c.elemOfArrayish(se.ty) else se.ty;
            const tt = c.tupleElemTypeAt(t, @intCast(i)) orelse return false;
            if (!try c.isAssignable(st, tt)) return false;
        }
        return true;
    }

    fn tupleElemTypeAt(c: *Checker, t: TypeId, i: u32) ?TypeId {
        const len = c.ts.tupleLen(t);
        if (i < len) {
            const e = c.ts.tupleElem(t, i);
            return if (e.rest()) c.elemOfArrayish(e.ty) else e.ty;
        }
        if (len > 0) {
            const last = c.ts.tupleElem(t, len - 1);
            if (last.rest()) return c.elemOfArrayish(last.ty);
        }
        return null;
    }

    /// Object-target structural check. `s` is any structural source
    /// (object, array/tuple/string via length lookup, function, ...).
    fn structuralAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
        if (c.ts.kind(t) != .object) return false;
        const n = c.ts.objectPropCount(t);
        const sidx = c.ts.objectStringIndex(t);
        const nidx = c.ts.objectNumberIndex(t);
        const t_calls = c.ts.objectCallSigCount(t);
        const t_constructs = c.ts.objectConstructSigCount(t);
        // {} accepts anything non-nullish — but a callable/constructable
        // target with no members is not empty: its signatures must be checked.
        if (n == 0 and sidx == 0 and nidx == 0 and t_calls == 0 and t_constructs == 0) {
            const k = c.ts.kind(s);
            return k != .null and k != .undefined and k != .void;
        }
        for (0..n) |i| {
            const tp = c.ts.objectProp(t, @intCast(i));
            // A source string index signature does NOT satisfy a required named
            // target property (tsc TS2741/TS2740); it is related separately as an
            // index signature below. So `{ [k: string]: any }` is not assignable
            // to `Date`/`{ x: number }`.
            const sp = (try c.propOfTypeEx(s, tp.name, false)) orelse {
                if (tp.optional()) continue;
                return false;
            };
            if (sp.optional() and !tp.optional()) return false;
            var st = sp.ty;
            if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
            var tt = tp.ty;
            if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
            if (!try c.isAssignable(st, tt)) return false;
        }
        // Target string index signature. tsc: the source satisfies it via
        // (a) a compatible *source* string index signature, or (b) being an
        // object with an *implied* index (object/type literal, not an
        // interface / class-instance / array / tuple / function / primitive)
        // whose every known property conforms. A source with neither — a bare
        // primitive, function, class instance, or interface without an index —
        // fails vacuously no longer: it fails, period. (M17.1)
        if (sidx != 0) {
            switch (c.ts.kind(s)) {
                .object => {
                    if (c.ts.objectStringIndex(s) != 0) {
                        if (!try c.isAssignable(c.ts.objectStringIndex(s), sidx)) return false;
                    } else if (c.ts.objectHasImpliedIndex(s)) {
                        for (0..c.ts.objectPropCount(s)) |i| {
                            const sp = c.ts.objectProp(s, @intCast(i));
                            if (!try c.isAssignable(sp.ty, sidx)) return false;
                        }
                    } else return false; // interface / class instance, no index sig
                },
                else => return false,
            }
        }
        // Target number index signature. Arrays and tuples always carry a
        // numeric index; a source `string` indexes numerically to `string`; an
        // object satisfies via a source number index, a source string index
        // (string keys subsume numeric ones), or — when it has an implied index
        // — its *numerically named* properties.
        if (nidx != 0) {
            switch (c.ts.kind(s)) {
                .array => {
                    if (!try c.isAssignable(c.ts.arrayElem(s), nidx)) return false;
                },
                .tuple => {
                    for (0..c.ts.tupleLen(s)) |i| {
                        if (!try c.isAssignable(c.ts.tupleElem(s, @intCast(i)).ty, nidx)) return false;
                    }
                },
                .string => {
                    if (!try c.isAssignable(types.string_type, nidx)) return false;
                },
                .object => {
                    if (c.ts.objectNumberIndex(s) != 0) {
                        if (!try c.isAssignable(c.ts.objectNumberIndex(s), nidx)) return false;
                    } else if (c.ts.objectStringIndex(s) != 0) {
                        if (!try c.isAssignable(c.ts.objectStringIndex(s), nidx)) return false;
                    } else if (c.ts.objectHasImpliedIndex(s)) {
                        for (0..c.ts.objectPropCount(s)) |i| {
                            const sp = c.ts.objectProp(s, @intCast(i));
                            if (!isNumericPropName(c.atomText(sp.name))) continue;
                            if (!try c.isAssignable(sp.ty, nidx)) return false;
                        }
                    } else return false; // interface / class instance, no index sig
                },
                else => return false,
            }
        }
        // Target call / construct signatures (M18.1): the source must supply a
        // matching signature for each. A source that cannot be called (or
        // constructed) provides none and fails a non-empty requirement.
        if (t_calls > 0 and !try c.sourceSatisfiesSigs(s, t, false)) return false;
        if (t_constructs > 0 and !try c.sourceSatisfiesSigs(s, t, true)) return false;
        return true;
    }

    /// Whether `s` provides a signature assignable to each of `t`'s call
    /// (`is_construct == false`) or construct (`true`) signatures (M18.1).
    /// Function ↔ callable-object relate in both directions; a `class_value`
    /// satisfies construct signatures (constructable) — under-reporting exact
    /// shape mismatches rather than spuriously rejecting a valid class value.
    fn sourceSatisfiesSigs(c: *Checker, s: TypeId, t: TypeId, is_construct: bool) Error!bool {
        const sk = c.ts.kind(s);
        if (sk == .any or sk == .err) return true;
        if (is_construct and sk == .class_value) return true;
        var src: std.ArrayList(TypeId) = .empty;
        defer src.deinit(c.scratch());
        switch (sk) {
            .function => if (!is_construct) try src.append(c.scratch(), s),
            .overloads => if (!is_construct) {
                for (try c.memberList(s)) |m| try src.append(c.scratch(), m);
            },
            .object => {
                const cnt = if (is_construct) c.ts.objectConstructSigCount(s) else c.ts.objectCallSigCount(s);
                for (0..cnt) |i| {
                    try src.append(c.scratch(), if (is_construct) c.ts.objectConstructSig(s, @intCast(i)) else c.ts.objectCallSig(s, @intCast(i)));
                }
            },
            else => {},
        }
        const t_cnt = if (is_construct) c.ts.objectConstructSigCount(t) else c.ts.objectCallSigCount(t);
        for (0..t_cnt) |i| {
            const tsig = if (is_construct) c.ts.objectConstructSig(t, @intCast(i)) else c.ts.objectCallSig(t, @intCast(i));
            var matched = false;
            for (src.items) |ssig| {
                if (try c.signatureAssignable(ssig, tsig)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }

    /// A property name that a *number* index signature constrains: a canonical
    /// non-negative integer string (`"0"`, `"1"`, `"42"` — not `"01"`, `"1.5"`,
    /// `"-1"`, or any non-digit name). Conservative on purpose: a name we do not
    /// recognise as numeric is treated as string-keyed and skipped for a number
    /// index (an under-report, never a false rejection).
    fn isNumericPropName(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text.len > 1 and text[0] == '0') return false; // no leading zeros
        for (text) |ch| if (ch < '0' or ch > '9') return false;
        return true;
    }

    /// strictFunctionTypes: contravariant params for function types,
    /// bivariant for methods; covariant returns; `void` target returns
    /// accept anything.
    fn signatureAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
        // tsc's canonical type-IDENTITY probe `(<G>() => G extends X ? A : B)`
        // (react-hook-form's `IsEqual`, and other libraries) compares two types
        // for identity: `IsEqual<X,Y>` reduces to `(<G>()=>G extends X?1:2)
        // extends (<G>()=>G extends Y?1:2)`, which tsc accepts iff X and Y are
        // identical. The general `eraseTypeParams` path below erases the lone
        // `G` to `any`, collapsing both conditional returns to `1|2` — so the
        // probe wrongly reported *any* two sigs assignable and `IsEqual<X,Y>`
        // was always `true` (making RHF `Path`/`PathValue` over an `any`-valued
        // field, `AnyIsEqual<T,Record<string,any>>`, take the wrong branch and
        // drop the deep `` `${K}.${…}` `` members). Recognize the exact shape and
        // relate by extends/branch identity — leaving the lenient erasure every
        // other generic-signature relation relies on untouched (a general
        // abstract-param relation here regresses jest/mock generic sigs).
        if (try c.identityProbeRelated(s, t)) |res| return res;
        const bivariant = (c.ts.fnFlags(s) & types.fn_flag_method != 0) or
            (c.ts.fnFlags(t) & types.fn_flag_method != 0);
        // Erase generics to their constraints (documented simplification).
        const se = try c.eraseTypeParams(s);
        const te = try c.eraseTypeParams(t);
        if (try c.requiredParams(se) > c.paramTotal(te)) return false;
        const s_count = c.ts.fnParamCount(se);
        const t_count = c.ts.fnParamCount(te);
        const pairs = @min(c.paramTotal(se), @max(s_count, t_count));
        var i: u32 = 0;
        while (i < pairs) : (i += 1) {
            var sp = c.paramTypeAt(se, i) orelse break;
            const tp = c.paramTypeAt(te, i) orelse break;
            // An optional *source* parameter admits `undefined` at the call
            // site, so its effective type for the contravariant relation is
            // `T | undefined` — exactly as an explicit `?` target param already
            // has undefined baked into its stored type. Without this, a
            // default-valued source param (`b: boolean = false`, whose stored
            // type stays the bare `boolean`) fails against an optional target
            // param `b?: boolean` (`boolean | undefined`), a phantom TS2322 tsc
            // does not report. A *required* source param is untouched, so it
            // still (correctly) fails that target.
            if (i < c.ts.fnParamCount(se)) {
                const spar = c.ts.fnParam(se, i);
                if (spar.optional() and !spar.rest()) sp = try c.makeUnion2(sp, types.undefined_type);
            }
            const contra = try c.isAssignable(tp, sp);
            if (!contra) {
                if (!bivariant) return false;
                if (!try c.isAssignable(sp, tp)) return false;
            }
        }
        const t_ret = c.ts.fnReturn(te);
        // A void-returning target accepts any source return (tsc's early-out).
        // An `asserts x[ is T]` predicate always returns void, so any target
        // assertion predicate lands here and is accepted regardless of source
        // — matching tsc, which compares predicates only after this gate.
        if (t_ret == types.void_type) return true;
        // Type-predicate relation (M17.3). Once the target return type is
        // non-void, a target type predicate (`x is T`, return boolean)
        // constrains the source per tsc's `compareTypePredicateRelatedTo`:
        //   - the source must also be a type predicate (else TS2322,
        //     "Signature '…' must be a type predicate") — but only when the
        //     target guards an *identifier* (`this is T` targets do not force
        //     the source to be a predicate);
        //   - the predicate kinds must match: same asserts-ness and the same
        //     guarded position (`this` vs a parameter index);
        //   - the asserted type is covariant — source type assignable to
        //     target type.
        // A plain-boolean source → predicate target therefore *fails* (tsc
        // rejects it), and a predicate source → boolean target is fine (the
        // target has no predicate, so this block is skipped).
        if (c.ts.fnHasPredicate(te)) {
            const tp = c.ts.fnPredicate(te);
            if (!c.ts.fnHasPredicate(se)) {
                if (tp.param != types.Predicate.this_param) return false;
            } else {
                const spd = c.ts.fnPredicate(se);
                if (spd.asserts != tp.asserts) return false;
                if (spd.param != tp.param) return false;
                if (tp.ty != types.no_type) {
                    if (spd.ty == types.no_type) return false;
                    if (!try c.isAssignable(spd.ty, tp.ty)) return false;
                }
            }
        }
        const s_ret = c.ts.fnReturn(se);
        // Covariant return relation. A `void` source return was previously
        // special-cased to accept only `void`/`any`/`unknown` targets — but
        // that manual enumeration rejected union targets containing `void`
        // (e.g. `() => void` vs `() => void | undefined`), which tsc accepts
        // via the union's `void` member. The general relation already gets
        // every case right (`void <: void|undefined` true, `void <: undefined`
        // false, `void <: number` false, `void <: any/unknown` trivially
        // true), so defer to it unconditionally.
        return c.isAssignable(s_ret, t_ret);
    }

    /// If `sig` is the type-identity probe `<G>() => (G extends X ? A : B)` — a
    /// single type param, no value params, a conditional return checked on that
    /// param — return its conditional; else null.
    fn identityProbeCond(c: *Checker, sig: TypeId) ?TypeId {
        if (c.ts.kind(sig) != .function) return null;
        const tps = c.ts.fnTypeParams(sig);
        if (tps.len != 1) return null;
        if (c.ts.fnParamCount(sig) != 0) return null;
        const ret = c.ts.fnReturn(sig);
        if (c.ts.kind(ret) != .conditional) return null;
        const chk = c.ts.condCheck(ret);
        if (c.ts.kind(chk) != .type_param) return null;
        if (c.ts.typeParamSymbol(chk) != tps[0]) return null;
        return ret;
    }

    /// When BOTH `s` and `t` are the identity probe `<G>()=>G extends _?_:_`,
    /// relate them by IDENTITY of the extends types and branches (tsc's rule),
    /// returning the result; otherwise null (fall through to the normal
    /// signature relation).
    fn identityProbeRelated(c: *Checker, s: TypeId, t: TypeId) Error!?bool {
        const cs = c.identityProbeCond(s) orelse return null;
        const ct = c.identityProbeCond(t) orelse return null;
        const xs = try c.resolveStructural(c.ts.condExtends(cs));
        const xt = try c.resolveStructural(c.ts.condExtends(ct));
        // Only decide when BOTH extends types are GROUND. While either is still
        // abstract (`IsEqual<TraversedTypes, infer V>` mid-reduction) the probe
        // must stay deferred, so leave the pre-existing erasure path untouched
        // — this keeps the change strictly additive (it alters only the
        // concrete `IsEqual<A,B>` case, which is the bug).
        if (try c.containsTypeParam(xs) or try c.containsInfer(xs) or
            try c.containsTypeParam(xt) or try c.containsInfer(xt)) return null;
        // Structural IDENTITY (not mutual assignability): the probe holds only
        // when the two extends types and the two branches are the SAME type.
        // ztsc interns objects/unions/etc. structurally, so identity is TypeId
        // equality after `resolveStructural`. Mutual assignability is too loose
        // — an `any`-valued index signature (`Record<string,any>`) is mutually
        // assignable to a distinct object shape yet is not identical, which is
        // exactly the case `IsEqual` must separate.
        const ident = struct {
            fn eq(cc: *Checker, a: TypeId, b: TypeId) Error!bool {
                return (try cc.resolveStructural(a)) == (try cc.resolveStructural(b));
            }
        }.eq;
        if (xs != xt) return false;
        if (!try ident(c, c.ts.condTrue(cs), c.ts.condTrue(ct))) return false;
        if (!try ident(c, c.ts.condFalse(cs), c.ts.condFalse(ct))) return false;
        return true;
    }

    fn eraseTypeParams(c: *Checker, sig: TypeId) Error!TypeId {
        // Non-generic early-out before the dupe (the common case).
        const sig_tps = c.ts.fnTypeParams(sig);
        if (sig_tps.len == 0) return sig;
        const tps = try c.scratch().dupe(u32, sig_tps);
        // Fixed base-constraint mapper: each type param → its declared
        // constraint (or `any`). Kept immutable so it can be re-applied.
        const base_map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| {
            const constraint = try c.typeParamConstraint(tp);
            base_map[i] = .{ .sym = tp, .ty = if (constraint != types.no_type) constraint else types.any_type };
        }
        // Resolve nested type-param references inside constraints to a fixed
        // point (tsc `getBaseSignature`): a constraint like
        // `Ret extends TOpt['returnObjects'] extends true ? object : string`
        // still mentions `TOpt`, so a single substitution leaves a deferred
        // conditional that never reduces. Re-applying the *same* base mapper
        // `tps.len - 1` times drives `TOpt` down to its own constraint, letting
        // the conditional collapse (here to `string`). Without this, the erased
        // return type stays an unresolved conditional and a perfectly valid
        // signature (react-i18next `TFunction`) fails to relate to a plain
        // `(key: string) => string`.
        const resolved = try c.scratch().alloc(TpMap, tps.len);
        @memcpy(resolved, base_map);
        const rounds: usize = if (tps.len > 1) tps.len - 1 else 0;
        var iter: usize = 0;
        while (iter < rounds) : (iter += 1) {
            var changed = false;
            for (resolved) |*r| {
                const ni = try c.instantiate(r.ty, base_map);
                if (ni != r.ty) changed = true;
                r.ty = ni;
            }
            if (!changed) break;
        }
        return c.instantiate(sig, resolved);
    }

    /// i-th effective parameter type (expanding a trailing rest).
    fn paramTypeAt(c: *Checker, sig: TypeId, i: u32) ?TypeId {
        const count = c.ts.fnParamCount(sig);
        if (i < count) {
            const p = c.ts.fnParam(sig, i);
            return if (p.rest()) c.elemOfArrayish(p.ty) else p.ty;
        }
        if (count > 0) {
            const last = c.ts.fnParam(sig, count - 1);
            if (last.rest()) return c.elemOfArrayish(last.ty);
        }
        return null;
    }

    fn paramTotal(c: *Checker, sig: TypeId) u32 {
        const count = c.ts.fnParamCount(sig);
        if (count > 0 and c.ts.fnParam(sig, count - 1).rest()) return std.math.maxInt(u32);
        return count;
    }

    fn requiredParams(c: *Checker, sig: TypeId) Error!u32 {
        var n: u32 = 0;
        for (0..c.ts.fnParamCount(sig)) |i| {
            const p = c.ts.fnParam(sig, @intCast(i));
            if (p.optional() or p.rest()) break;
            n += 1;
        }
        // tsc's `getMinArgumentCount` walks back from the last required
        // parameter and drops any trailing parameter whose type accepts
        // `void` — the `(x: void) => T` idiom (e.g. redux-toolkit's
        // `ActionCreatorWithoutPayload`, `(noArgument: void) => …`) is thus
        // callable with zero arguments and assignable to `() => T`.
        while (n > 0) {
            if (!try c.paramAcceptsVoid(c.ts.fnParam(sig, n - 1).ty)) break;
            n -= 1;
        }
        return n;
    }

    /// A parameter type "accepts void" (tsc's `acceptsVoid` via `everyType`)
    /// when it is `void`, or a union whose every member accepts void.
    fn paramAcceptsVoid(c: *Checker, ty: TypeId) Error!bool {
        if (ty == types.void_type) return true;
        const r = try c.resolveStructural(ty);
        if (r == types.void_type) return true;
        if (c.ts.kind(r) == .union_type) {
            const ms = try c.memberList(r);
            if (ms.len == 0) return false;
            for (ms) |m| if (!try c.paramAcceptsVoid(m)) return false;
            return true;
        }
        return false;
    }

    // =====================================================================
    // diagnostic-emitting assignment check (2322 / 2739 / 2741 / 2353)
    // =====================================================================

    /// Check `source` (the type of `expr_node`, which may be 0) against
    /// `target`, reporting at `span`. Returns true when assignable.
    fn checkAssignable(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
        // Anchor any TS2589 raised while expanding either side (instantiation
        // limit) at the assignment site.
        c.inst_span = span;
        if (try c.isAssignable(src_t, target)) {
            // Excess property check for fresh object literals.
            if (expr_node != 0) {
                try c.excessPropertyCheck(expr_node, src_t, target);
            }
            return true;
        }
        // tsc elaborates object/array literal mismatches per member.
        if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
            return false;
        }
        try c.reportNotAssignable(2322, src_t, target, span);
        return false;
    }

    /// `expr satisfies T`: same relation as `checkAssignable`, but a
    /// top-level failure is reported as TS1360 ("does not satisfy the
    /// expected type") rather than TS2322/2741. Nested member mismatches
    /// and excess properties elaborate exactly like an assignment.
    fn checkSatisfies(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
        if (try c.isAssignable(src_t, target)) {
            if (expr_node != 0) try c.excessPropertyCheck(expr_node, src_t, target);
            return true;
        }
        if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
            return false;
        }
        // TS7 surfaces the specific missing-property error (TS2741/2739) in
        // place of the TS1360 wrapper when the operand is an object missing
        // required members; a primitive/non-object mismatch still gets TS1360.
        if (try c.tryReportMissingProps(src_t, target, span)) return false;
        try c.diagFmt(1360, span, "Type '{s}' does not satisfy the expected type '{s}'.", .{
            try c.typeToString(src_t), try c.typeToString(target),
        });
        return false;
    }

    /// Element/property-wise TS2322 elaboration for fresh literals (what
    /// tsc reports instead of one top-level error). Returns true when at
    /// least one narrower diagnostic was emitted.
    fn elaborateLiteralError(c: *Checker, expr_node0: Node, src_t: TypeId, target: TypeId) Error!bool {
        var expr_node = expr_node0;
        while (c.nodeTag(expr_node) == .paren_expr) expr_node = c.tree.nodeData(expr_node).lhs;
        const rt = try c.resolveStructural(target);
        switch (c.nodeTag(expr_node)) {
            .array_literal => {
                const rtk = c.ts.kind(rt);
                if (rtk != .array and rtk != .tuple) return false;
                var reported = false;
                var i: u32 = 0;
                for (c.tree.nodeRange(expr_node)) |el| {
                    if (el == null_node) continue;
                    defer i += 1;
                    if (c.nodeTag(el) == .omitted or c.nodeTag(el) == .spread_element) continue;
                    const tt = if (rtk == .array) c.ts.arrayElem(rt) else (c.tupleElemTypeAt(rt, i) orelse continue);
                    const et = c.nodeType(el) orelse continue;
                    if (try c.isAssignable(et, tt)) continue;
                    if (!try c.elaborateLiteralError(el, et, tt)) {
                        try c.reportNotAssignable(2322, et, tt, c.nodeSpan(el));
                    }
                    reported = true;
                }
                return reported;
            },
            .object_literal => {
                if (c.ts.kind(rt) != .object) return false;
                var reported = false;
                for (c.tree.nodeRange(expr_node)) |prop| {
                    if (prop == null_node) continue;
                    const pd = c.tree.nodeData(prop);
                    const tag = c.nodeTag(prop);
                    if (tag != .object_property and tag != .object_shorthand) continue;
                    if (tag == .object_property and pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                    const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                    const tp = c.ts.objectPropByName(rt, key) orelse continue;
                    const value_node = if (tag == .object_property) pd.rhs else pd.lhs;
                    const vt = c.nodeType(value_node) orelse continue;
                    if (try c.isAssignable(vt, tp.ty)) continue;
                    if (!try c.elaborateLiteralError(value_node, vt, tp.ty)) {
                        // tsc anchors an object-literal member mismatch at the
                        // property NAME (for shorthand the name IS the value), not
                        // the value expression.
                        try c.reportNotAssignable(2322, vt, tp.ty, c.tokSpan(c.tree.nodeMainToken(prop)));
                    }
                    reported = true;
                }
                _ = src_t;
                return reported;
            },
            else => return false,
        }
    }

    /// tsc reports contextually-typed callback return mismatches as TS2322
    /// at the callback body, not TS2345 on the argument.
    fn elaborateCallbackError(c: *Checker, arg_node: Node, at: TypeId, pt: TypeId) Error!bool {
        const tag = c.nodeTag(arg_node);
        if (tag != .arrow_fn and tag != .function_expr) return false;
        if (c.ts.kind(at) != .function) return false;
        const rpt = try c.resolveStructural(pt);
        if (c.ts.kind(rpt) != .function) return false;
        if (!try c.callbackParamsCompatible(at, rpt)) return false;
        const s_ret = c.ts.fnReturn(at);
        const t_ret = c.ts.fnReturn(rpt);
        if (t_ret == types.void_type) return false;
        if (try c.isAssignable(s_ret, t_ret)) return false;
        const body = c.tree.nodeData(arg_node).rhs;
        const span = if (body != 0 and c.nodeTag(body) != .block)
            c.nodeSpan(body)
        else
            c.nodeSpan(arg_node);
        try c.reportNotAssignable(2322, s_ret, t_ret, span);
        return true;
    }

    fn callbackParamsCompatible(c: *Checker, s: TypeId, t: TypeId) Error!bool {
        if (try c.requiredParams(s) > c.paramTotal(t)) return false;
        const pairs = @min(c.paramTotal(s), @max(c.ts.fnParamCount(s), c.ts.fnParamCount(t)));
        var i: u32 = 0;
        while (i < pairs) : (i += 1) {
            const sp = c.paramTypeAt(s, i) orelse break;
            const tp = c.paramTypeAt(t, i) orelse break;
            if (!try c.isAssignable(tp, sp) and !try c.isAssignable(sp, tp)) return false;
        }
        return true;
    }

    /// Missing-property refinement: when `src` is object-y and `target` is an
    /// object type with required properties absent from `src`, report the
    /// specific missing-property error (TS2741 for one, TS2739 for several) at
    /// `span` and return true. Shared by the assignment check (in place of
    /// TS2322), `satisfies` (in place of TS1360), and the `this`-receiver check
    /// (in place of TS2684): TS7 surfaces this specific error where tsc 5.5
    /// emitted the wrapper code.
    fn tryReportMissingProps(c: *Checker, src_t: TypeId, target: TypeId, span: Span) Error!bool {
        const rs = try c.resolveStructural(src_t);
        const rt = try c.resolveStructural(target);
        if (!isSourceObjecty(c.ts.kind(rs)) or c.ts.kind(rt) != .object) return false;
        var missing: std.ArrayList(Atom) = .empty;
        defer missing.deinit(c.scratch());
        for (0..c.ts.objectPropCount(rt)) |i| {
            const tp = c.ts.objectProp(rt, @intCast(i));
            if (tp.optional()) continue;
            // A source index signature does not supply a named property (see
            // structuralAssignable): keep the missing-property diagnostic in
            // step with the relation so `{ [k: string]: any }` → `Date` reports
            // the missing Date members (TS2740), not a bare TS2322.
            if ((try c.propOfTypeEx(rs, tp.name, false)) == null) {
                try missing.append(c.scratch(), tp.name);
            }
        }
        // Emit the missing names in name-*text* order. They were gathered in
        // the target's stored (atom-sorted) prop order, which varies across
        // --workers/--checkers; text order is content-derived and stable
        // (determinism contract). Names are unique, so the order is total.
        std.mem.sort(Atom, missing.items, c, struct {
            fn less(cc: *Checker, a: Atom, b: Atom) bool {
                return std.mem.order(u8, cc.atomText(a), cc.atomText(b)) == .lt;
            }
        }.less);
        if (missing.items.len == 1) {
            try c.diagFmt(2741, span, "Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{
                c.atomText(missing.items[0]), try c.typeToString(src_t), try c.typeToString(target),
            });
            return true;
        }
        if (missing.items.len > 1) {
            var names: std.Io.Writer.Allocating = .init(c.scratch());
            defer names.deinit();
            for (missing.items, 0..) |m, i| {
                if (i > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
                names.writer.print("{s}", .{c.atomText(m)}) catch return error.OutOfMemory;
            }
            try c.diagFmt(2739, span, "Type '{s}' is missing the following properties from type '{s}': {s}", .{
                try c.typeToString(src_t), try c.typeToString(target), names.written(),
            });
            return true;
        }
        return false;
    }

    fn reportNotAssignable(c: *Checker, code: u16, src_t: TypeId, target: TypeId, span: Span) Error!void {
        // Missing-property refinement (tsc: 2739 / 2741 instead of 2322).
        if (code == 2322) {
            if (try c.tryReportMissingProps(src_t, target, span)) return;
            // Did-you-mean morph (tsc: TS2820): a string-literal source rejected
            // by a union of string literals with a close member. tsc's
            // getSuggestedTypeForNonexistentStringLiteralType.
            if (try c.stringLiteralSuggestion(src_t, target)) |sugg| {
                try c.diagFmt(2820, span, "Type '{s}' is not assignable to type '{s}'. Did you mean '\"{s}\"'?", .{
                    try c.typeToString(src_t), try c.typeToString(target), c.atomText(sugg),
                });
                return;
            }
        }
        const msg_fmt = "Type '{s}' is not assignable to type '{s}'.";
        if (code == 2345) {
            try c.diagFmt(2345, span, "Argument of type '{s}' is not assignable to parameter of type '{s}'.", .{
                try c.typeToString(src_t), try c.typeToString(target),
            });
        } else {
            try c.diagFmt(code, span, msg_fmt, .{ try c.typeToString(src_t), try c.typeToString(target) });
        }
    }

    /// tsc's getSuggestedTypeForNonexistentStringLiteralType: when a string
    /// literal is rejected by a union, suggest the closest string-literal member
    /// (drives the TS2322 -> TS2820 morph). Returns the suggested member's value
    /// atom, or null when the source is not a string literal, the target is not
    /// a union of string literals, or nothing is close enough.
    fn stringLiteralSuggestion(c: *Checker, src_t: TypeId, target: TypeId) Error!?Atom {
        const rs = try c.resolveStructural(src_t);
        if (c.ts.kind(rs) != .string_literal) return null;
        const rt = try c.resolveStructural(target);
        if (c.ts.kind(rt) != .union_type) return null;
        var cand_atoms: std.ArrayList(Atom) = .empty;
        defer cand_atoms.deinit(c.scratch());
        var cand_names: std.ArrayList([]const u8) = .empty;
        defer cand_names.deinit(c.scratch());
        for (try c.memberList(rt)) |m| {
            const rm = try c.resolveStructural(m);
            if (c.ts.kind(rm) != .string_literal) continue;
            const a = c.ts.literalAtom(rm);
            try cand_atoms.append(c.scratch(), a);
            try cand_names.append(c.scratch(), c.atomText(a));
        }
        if (cand_names.items.len == 0) return null;
        const name = c.atomText(c.ts.literalAtom(rs));
        const idx = intern.spellingSuggestion(c.scratch(), name, cand_names.items) orelse return null;
        return cand_atoms.items[idx];
    }

    fn isSourceObjecty(k: types.Kind) bool {
        return k == .object or k == .intersection;
    }

    /// tsc's excess property check: only *fresh* object literals, checked
    /// against object-ish targets; recurses into nested literal properties.
    fn excessPropertyCheck(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!void {
        var node = expr_node;
        // Unwrap parens and a JSX expression container (`prop={{ … }}`): the
        // object literal inside a JSX attribute value is fresh and excess-checked
        // exactly like a call argument or assignment RHS.
        while (true) {
            switch (c.nodeTag(node)) {
                .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
                else => break,
            }
            if (node == null_node) return;
        }
        if (c.nodeTag(node) != .object_literal) return;
        if (!c.ts.objectIsFresh(src_t)) return;
        const rt = try c.resolveStructural(target);
        switch (c.ts.kind(rt)) {
            .object => {
                if (c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0) return;
                // The empty object type `{}` accepts any properties: tsc's
                // `hasExcessProperties` bails on `isEmptyObjectType(target)`
                // (e.g. react-i18next's `values?: {}`). No prop is ever excess.
                if (c.isEmptyObjectType(rt)) return;
            },
            .union_type => {
                // Check against the union: a property is excess if no
                // object constituent knows it.
            },
            else => return,
        }
        for (c.tree.nodeRange(node)) |prop| {
            if (prop == null_node) continue;
            const tag = c.nodeTag(prop);
            if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
            const key_tok = c.tree.nodeMainToken(prop);
            if (tag == .object_property) {
                const pd = c.tree.nodeData(prop);
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
            }
            const key = try c.memberAtom(key_tok);
            const known = try c.targetKnowsProp(rt, key);
            if (!known) {
                try c.diagFmt(2353, c.tokSpan(key_tok), "Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{
                    c.atomText(key), try c.typeToString(target),
                });
                return; // one excess error per literal, like tsc's early bail
            }
            // Recurse into nested fresh literals.
            if (tag == .object_property) {
                const pd = c.tree.nodeData(prop);
                if (c.nodeTag(pd.rhs) == .object_literal) {
                    if (c.nodeType(pd.rhs)) |nested_t| {
                        if (try c.targetPropType(rt, key)) |tp| {
                            try c.excessPropertyCheck(pd.rhs, nested_t, tp);
                        }
                    }
                }
            }
        }
    }

    fn targetKnowsProp(c: *Checker, rt: TypeId, key: Atom) Error!bool {
        switch (c.ts.kind(rt)) {
            .union_type => {
                for (try c.memberList(rt)) |m| {
                    if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
                }
                return false;
            },
            .object => {
                if (c.ts.objectPropByName(rt, key) != null) return true;
                return c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0;
            },
            .intersection => {
                for (try c.memberList(rt)) |m| {
                    if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
                }
                return false;
            },
            .any, .err, .unknown => return true,
            else => return true, // non-object targets: not our business here
        }
    }

    fn targetPropType(c: *Checker, rt: TypeId, key: Atom) Error!?TypeId {
        if (try c.propOfType(rt, key)) |p| return p.ty;
        return null;
    }

    // =====================================================================
    // expressions
    // =====================================================================

    fn checkExprCached(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        if (node == null_node) return types.any_type;
        // Anchor any TS2589 raised while materializing this expression's type
        // (instantiation limit) at the expression's span.
        c.inst_span = c.nodeSpan(node);
        const key = c.nodeKey(node);
        if (c.node_types.get(key)) |e| {
            if (e.ctx == ctx) {
                c.stats.node_type_hits += 1;
                return e.ty;
            }
        }
        c.stats.node_type_misses += 1;
        const t = try c.checkExpr(node, ctx);
        try c.node_types.put(c.ca(), key, .{ .ty = t, .ctx = ctx });
        return t;
    }

    fn checkExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        const d = c.tree.nodeData(node);
        const main_tok = c.tree.nodeMainToken(node);
        switch (c.nodeTag(node)) {
            .identifier => return c.checkIdentifier(node),
            .number_literal => return c.ts.makeNumberLiteral(c.numberTokenValue(main_tok), true),
            .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(main_tok), true),
            .bigint_literal => return c.ts.makeBigIntLiteral(try c.atomOfToken(main_tok), true),
            .template_literal => return c.ts.makeStringLiteral(try c.templateAtom(main_tok), true),
            .true_literal => return c.ts.makeBooleanLiteral(true, true),
            .false_literal => return c.ts.makeBooleanLiteral(false, true),
            .null_literal => return types.null_type,
            .regex_literal => return types.any_type, // RegExp needs lib (documented)
            .this_expr => return if (c.this_type != 0) c.this_type else types.any_type,
            .super_expr => return types.any_type,
            .import_expr => return types.any_type,
            .omitted, .error_node, .unsupported => return types.any_type,
            .paren_expr => return c.checkExprCached(d.lhs, ctx),
            .seq_expr => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return c.checkExprCached(d.rhs, ctx);
            },
            .template_expr => {
                // When the contextual type wants a template-literal type, keep
                // the expression's template structure (checkExprCached on each
                // substitution happens inside templateExprType); otherwise a
                // template expression is just `string`.
                if (try c.ctxWantsTemplate(ctx)) return c.templateExprType(node);
                for (c.tree.nodeRange(node)) |sub| {
                    if (sub != null_node) _ = try c.checkExprCached(sub, types.no_type);
                }
                return types.string_type;
            },
            .tagged_template => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                _ = try c.checkExprCached(d.rhs, types.no_type);
                return types.any_type;
            },
            .array_literal => return c.checkArrayLiteral(node, ctx),
            .object_literal => return c.checkObjectLiteral(node, ctx),
            .member_expr, .optional_member_expr => return c.checkMemberExpr(node),
            .index_expr, .optional_index_expr => return c.checkIndexExpr(node),
            .call_expr, .call_expr_targs, .optional_call => return c.checkCallExpr(node, false, ctx),
            .new_expr, .new_expr_targs, .new_expr_bare => return c.checkCallExpr(node, true, ctx),
            .binary => return c.checkBinary(node, ctx),
            .assign => return c.checkAssignExpr(node),
            .cond_expr => {
                const e = c.tree.extraData(ast.CondExpr, d.rhs);
                _ = try c.checkExprCached(d.lhs, types.no_type);
                const then_t = try c.checkExprCached(e.then_expr, ctx);
                const else_t = try c.checkExprCached(e.else_expr, ctx);
                return c.makeUnion2(then_t, else_t);
            },
            .prefix_unary => return c.checkPrefixUnary(node),
            .postfix_unary => {
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkArithmeticOperand(ot, d.lhs);
                return types.number_type;
            },
            .non_null => {
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                return c.nonNullable(ot);
            },
            .as_expr => {
                // `expr as const`: a const assertion. Check the operand in
                // const context (readonly/non-widened literals) and return
                // that type; there is no target to compare against.
                if (c.nodeTag(d.rhs) == .const_type) {
                    const prev = c.const_ctx;
                    c.const_ctx = true;
                    defer c.const_ctx = prev;
                    const et = try c.checkExprCached(d.lhs, types.no_type);
                    // De-fresh a bare primitive literal so it does not widen.
                    return c.ts.regularLiteral(et);
                }
                const et = try c.checkExprCached(d.lhs, types.no_type);
                const tt = try c.typeFromTypeNode(d.rhs);
                if (tt == types.error_type) return et;
                if (!try c.castComparable(try c.widenLiteral(et), tt)) {
                    try c.diagFmt(2352, c.nodeSpan(node), "Conversion of type '{s}' to type '{s}' may be a mistake because neither type sufficiently overlaps with the other. If this was intentional, convert the expression to 'unknown' first.", .{
                        try c.typeToString(et), try c.typeToString(tt),
                    });
                }
                return tt;
            },
            .satisfies_expr => {
                // `expr satisfies T`: validate assignability to T but keep
                // the operand's own (narrow) type as the result.
                const tt = try c.typeFromTypeNode(d.rhs);
                const et = try c.checkExprCached(d.lhs, tt);
                if (tt == types.error_type) return et;
                _ = try c.checkSatisfies(et, tt, d.lhs, c.nodeSpan(d.lhs));
                return et;
            },
            .arrow_fn, .function_expr => return c.checkFunctionLikeExpr(node, ctx),
            .class_decl => {
                try c.checkClass(node);
                return types.any_type; // class expressions: minimal support
            },
            .yield_expr => {
                // `yield x`: relate `x` to the generator's yield type `T`
                // (`Generator<T>`). Delegation `yield* x` (rhs=1) is unchecked
                // (iterable-protocol; a gap). `yield`'s own value type is `any`
                // (the caller-supplied `.next(v)` value — TNext, out of subset).
                const yt: TypeId = if (c.fn_ctx) |fc| fc.yield_type else 0;
                const in_async = if (c.fn_ctx) |fc| fc.is_async else false;
                const delegate = d.rhs != 0;
                if (d.lhs != 0) {
                    const vt = try c.checkExprCached(d.lhs, if (delegate) types.no_type else yt);
                    if (!delegate and yt != 0 and yt != types.no_type and yt != types.error_type and c.ts.kind(yt) != .any) {
                        // Async generators may yield `T | PromiseLike<T>`:
                        // the yielded value is awaited before it is emitted.
                        const eff_vt = if (in_async) try c.awaitedType(vt) else vt;
                        _ = try c.checkAssignable(eff_vt, yt, d.lhs, c.nodeSpan(d.lhs));
                    }
                }
                return types.any_type;
            },
            .spread_element => {
                return c.checkExprCached(d.lhs, types.no_type);
            },
            .jsx_element => return c.checkJsxElement(node),
            else => {
                // Recovery leftovers: visit children, type any.
                var it = c.tree.childIterator(node);
                while (it.next()) |child| _ = try c.checkExprCached(child, types.no_type);
                return types.any_type;
            },
        }
    }

    // =====================================================================
    // JSX (`.tsx`): elements type as `JSX.Element`; attributes are checked
    // like an object literal assigned to the element's props type — intrinsic
    // (`<div>`) props come from `JSX.IntrinsicElements[tag]`, component
    // (`<Foo>`) props from the component's first parameter.
    // =====================================================================

    fn checkJsxElement(c: *Checker, node: Node) Error!TypeId {
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        var props: TypeId = types.no_type; // no_type = unknown target (skip attr typing)
        var is_component = false;
        if (e.tag == null_node) {
            // Fragment `<>…</>`: no attributes, no props.
        } else if (c.isIntrinsicJsxTag(e.tag)) {
            const tag_atom = try c.atomOfToken(c.tree.nodeMainToken(e.tag));
            if (try c.jsxNamespaceType(c.atom_IntrinsicElements)) |ie| {
                if (try c.propOfType(try c.resolveStructural(ie), tag_atom)) |p| {
                    props = p.ty;
                } else {
                    try c.diagFmt(2339, c.nodeSpan(e.tag), "Property '{s}' does not exist on type 'JSX.IntrinsicElements'.", .{c.atomText(tag_atom)});
                }
            }
        } else {
            is_component = true;
            const tag_ty = try c.checkExprCached(e.tag, types.no_type);
            // Explicit type arguments on the tag (`<Select<string> …>`): resolve
            // them and instantiate the component signature so props (and the
            // contextual types of attribute handlers) become concrete.
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            for (c.tree.extraRange(e.targs_start, e.targs_end)) |tn| {
                if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
            }
            props = (try c.jsxComponentProps(tag_ty, targs.items, node)) orelse types.no_type;
        }
        try c.checkJsxAttributes(node, e, props, is_component, c.jsxChildrenPresent(e));
        for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
            switch (c.nodeTag(ch)) {
                .jsx_expr_container => {
                    const cd = c.tree.nodeData(ch);
                    if (cd.lhs != null_node) _ = try c.checkExprCached(cd.lhs, types.no_type);
                },
                .jsx_element => _ = try c.checkJsxElement(ch),
                else => {}, // jsx_text
            }
        }
        return (try c.jsxNamespaceType(c.atom_Element)) orelse types.any_type;
    }

    /// Whether a JSX tag node is an intrinsic element (simple lowercase-initial
    /// identifier). Uppercase or dotted names are component values.
    fn isIntrinsicJsxTag(c: *Checker, tag: Node) bool {
        if (c.nodeTag(tag) != .identifier) return false;
        const text = c.tokenText(c.tree.nodeMainToken(tag));
        return text.len > 0 and text[0] >= 'a' and text[0] <= 'z';
    }

    /// Resolve the type `JSX.<member>` (e.g. `JSX.Element`,
    /// `JSX.IntrinsicElements`) from the global `JSX` namespace, or null when
    /// no such namespace/member exists.
    fn jsxNamespaceType(c: *Checker, member: Atom) Error!?TypeId {
        const g = c.jsxNamespaceMember(member) orelse return null;
        return try c.namedTypeFromSymbol(g, &.{}, 0);
    }

    /// The (global) symbol for `JSX.<member>`, or null when the namespace or
    /// member is absent. Existence checks use this directly so generic members
    /// (e.g. `IntrinsicClassAttributes<T>`) are never instantiated bare.
    fn jsxNamespaceMember(c: *Checker, member: Atom) ?SymbolId {
        const jsx_sym = switch (c.resolveSpace(c.atom_JSX, c.cur_scope, false)) {
            .sym => |s| if (c.symFlags(s).namespace_decl) s else return null,
            else => return null,
        };
        const nb = c.symBind(jsx_sym);
        const ns = nb.namespaceScopeOf(c.localOf(jsx_sym)) orelse return null;
        const local = nb.lookupInScope(ns, member) orelse return null;
        const g = c.toGlobalIn(c.symFile(jsx_sym), local);
        const mf = c.symFlags(g);
        if (!(mf.exported and hasTypeMeaning(mf))) return null;
        return g;
    }

    /// Props type of a component tag. Function components: the first parameter
    /// of the call signature. Class components (`class C extends Component<P>`):
    /// the member of the instance type named by `JSX.ElementAttributesProperty`
    /// (typically `props`). Null when it has no discernible props (so attribute
    /// typing is skipped).
    fn jsxComponentProps(c: *Checker, tag_ty: TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
        const t = try c.resolveStructural(tag_ty);
        var sig = switch (c.ts.kind(t)) {
            .function => t,
            .overloads => blk: {
                const sigs = try c.memberList(t);
                break :blk if (sigs.len > 0) sigs[0] else return null;
            },
            .class_value => return c.jsxClassComponentProps(t),
            // A callable *object* — a call/construct-signature-bearing interface
            // used as a component — takes its first call signature.
            .object => if (c.ts.objectCallSigCount(t) > 0)
                c.ts.objectCallSig(t, 0)
            else
                return null,
            // A function merged with a namespace
            // (`declare function Icon(…); declare namespace Icon { … }`) types as
            // an *intersection* of the function value and the namespace object
            // (`computeTypeOfSymbol`). Pull the props from the callable
            // constituent; without this the whole props target is dropped and
            // every attribute goes unchecked (missing/excess/value all silently
            // pass — e.g. a bad `<Icon name>` slips through).
            .intersection => blk: {
                for (try c.memberList(t)) |m| {
                    const rm = try c.resolveStructural(m);
                    switch (c.ts.kind(rm)) {
                        .function => break :blk rm,
                        .overloads => {
                            const sigs = try c.memberList(rm);
                            if (sigs.len > 0) break :blk sigs[0];
                        },
                        .object => if (c.ts.objectCallSigCount(rm) > 0) break :blk c.ts.objectCallSig(rm, 0),
                        else => {},
                    }
                }
                return null;
            },
            else => return null,
        };
        // Bind explicit type arguments (`<Select<string> …>`) into the signature
        // so the props type is concrete. Mirrors the explicit-targ path of a
        // generic call; a count mismatch reports TS2558 there. With no explicit
        // args, a *generic* component's type params are inferred from the
        // attributes (tsc's "attributes object as the sole argument" model) —
        // without this `<Controller name control render>` keeps its props type
        // generic, so `control={control}` relates `Control<Form>` against the
        // still-free `Control<TFieldValues>` and its deferred `_defaultValues`
        // mapped-over-conditional spuriously fails (TS2322).
        if (explicit_targs.len > 0) {
            sig = try c.instantiateSigForCall(sig, explicit_targs, &.{}, node, types.no_type);
        } else if (c.ts.fnTypeParams(sig).len > 0) {
            const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
            const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
            sig = try c.inferJsxTargs(sig, tps, e);
        }
        if (c.ts.fnParamCount(sig) == 0) return types.empty_object_type;
        return c.ts.fnParam(sig, 0).ty;
    }

    /// Infer a generic component's type arguments from its JSX attributes,
    /// mirroring tsc's "attributes object as the sole argument" model, then
    /// return the signature instantiated with them. Only non-function attribute
    /// values drive inference (a `render` callback is contextually typed, not a
    /// Phase-1 inference source). A param no attribute constrains falls back to
    /// its default, else its constraint, else `unknown` — so an un-inferred
    /// `Controller<TFieldValues, TName>` resolves to concrete
    /// `ControllerProps<Form, FieldPath<Form>, …>` whose props relate reflexively.
    /// Whether `t` is (or resolves to) an object whose string index signature is
    /// `any` and which carries no required named properties — the `Record<string,
    /// any>` shape (react-hook-form `FieldValues`). Such a constraint imposes no
    /// real requirement, so a JSX-inferred object candidate should not be clamped
    /// to it. Deliberately narrow: a concrete-valued index (`Record<string,
    /// string>`) or an index-plus-required-props shape returns false.
    /// Whether the type param `sym` appears at the *top level* of a signature's
    /// return type `ret`: it is the whole return, or a member of a top-level
    /// union/intersection (recursively). Mirrors tsc's `isTypeParameterAtTopLevel`
    /// — a tuple element, an object property, or an array element is NOT top-level.
    /// tsc keeps a literal inference candidate when its param is top-level in the
    /// return (`id<T>(x: T): T` → `id(false)` stays `false`) and widens it
    /// otherwise (`useState<S>(x): [S, …]` → `useState(false)` widens `S` to
    /// `boolean`). A top-level named alias (`type Foo<S> = S | undefined`) is
    /// resolved once so `S` is still found.
    fn typeParamAtTopLevel(c: *Checker, ret: TypeId, sym: u32) Error!bool {
        const t = if (c.ts.kind(ret) == .ref) try c.resolveStructural(ret) else ret;
        switch (c.ts.kind(t)) {
            .type_param => return c.ts.typeParamSymbol(t) == sym,
            .union_type, .intersection => {
                for (try c.memberList(t)) |m| {
                    switch (c.ts.kind(m)) {
                        .type_param => if (c.ts.typeParamSymbol(m) == sym) return true,
                        .union_type, .intersection => if (try c.typeParamAtTopLevel(m, sym)) return true,
                        else => {},
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// Whether a type-parameter constraint is (or contains, through a union /
    /// intersection) a primitive, literal, enum, template-literal, string-mapping
    /// or `keyof` type — tsc's `hasPrimitiveConstraint`. Such a constraint makes
    /// tsc KEEP a literal inference candidate (mapped through
    /// `getRegularTypeOfLiteralType`, not widened): `f<T extends 'a' | 'b'>(x: T)`
    /// called with `'a'` fixes `T` to `'a'`, and `h<T extends string>(x: T): T[]`
    /// keeps the passed string literal. `no_type` (no constraint) is not primitive.
    fn constraintIsPrimitive(c: *Checker, constraint: TypeId) Error!bool {
        if (constraint == types.no_type) return false;
        return c.typeHasPrimitive(try c.resolveStructural(constraint));
    }

    fn typeHasPrimitive(c: *Checker, t: TypeId) Error!bool {
        return switch (c.ts.kind(t)) {
            .string, .number, .boolean, .bigint, .symbol, .undefined, .null, .void, .never, .unique_symbol, .enum_type, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .template_literal_type, .string_mapping, .keyof_op => true,
            .union_type, .intersection => blk: {
                for (try c.memberList(t)) |m| {
                    if (try c.typeHasPrimitive(try c.resolveStructural(m))) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn constraintIsAnyIndex(c: *Checker, t: TypeId) Error!bool {
        if (t == types.no_type) return false;
        const r = try c.resolveStructural(t);
        if (c.ts.kind(r) != .object) return false;
        const sidx = c.ts.objectStringIndex(r);
        if (sidx == 0 or c.ts.kind(try c.resolveStructural(sidx)) != .any) return false;
        for (0..c.ts.objectPropCount(r)) |i| {
            if (!c.ts.objectProp(r, @intCast(i)).optional()) return false;
        }
        return true;
    }

    fn inferJsxTargs(c: *Checker, sig: TypeId, tps: []const u32, e: ast.JsxElementData) Error!TypeId {
        if (c.ts.fnParamCount(sig) == 0) return sig;
        const rp0 = try c.resolveStructural(c.ts.fnParam(sig, 0).ty);
        const candidates = try c.scratch().alloc(TypeId, tps.len);
        for (candidates) |*x| x.* = types.no_type;
        // Phase 1: unify each non-function attribute value against its target prop.
        for (c.tree.extraRange(e.attrs_start, e.attrs_end)) |attr| {
            if (c.nodeTag(attr) == .jsx_spread_attribute) continue;
            const name_tok = c.tree.nodeMainToken(attr);
            if (c.tree.tokens.tag(name_tok) == .jsx_name) continue; // hyphenated data-*/aria-*
            const ad = c.tree.nodeData(attr);
            // Skip a function-valued attribute (`render={() => …}`): a callback is
            // contextually typed, not a raw inference source, and typing it here
            // context-free would pollute the candidates.
            if (ad.lhs != null_node and c.nodeTag(ad.lhs) == .jsx_expr_container) {
                const cd = c.tree.nodeData(ad.lhs);
                if (cd.lhs != null_node and (c.nodeTag(cd.lhs) == .arrow_fn or c.nodeTag(cd.lhs) == .function_expr)) continue;
            }
            const pt = (try c.propOfType(rp0, try c.memberAtom(name_tok))) orelse continue;
            const vty = try c.jsxAttributeValueType(ad.lhs, types.no_type);
            try c.unify(pt.ty, vty, tps, candidates, 0);
        }
        // Resolve each param: inferred candidate (clamped to its constraint when
        // it violates it), else default, else constraint, else `unknown`. Mirrors
        // the final resolution loop of `inferTypeArgs`, threading each resolved
        // arg into `prov` so a later param's constraint (`TName extends
        // FieldPath<TFieldValues>`) sees the earlier one substituted.
        const args_buf = try c.scratch().alloc(TypeId, tps.len);
        const prov = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| prov[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
        for (tps, 0..) |tp, i| {
            var constraint: TypeId = try c.typeParamConstraint(tp);
            if (constraint != types.no_type) constraint = try c.instantiate(constraint, prov);
            if (candidates[i] != types.no_type) {
                args_buf[i] = candidates[i];
                const bare_outer = constraint != types.no_type and
                    c.ts.kind(constraint) == .type_param and
                    tpIndex(tps, c.ts.typeParamSymbol(constraint)) == null;
                // An `any`-valued index-signature constraint (`TFieldValues
                // extends FieldValues`, `FieldValues = Record<string, any>`) is
                // satisfied by any object candidate: tsc admits a named interface
                // there (every member is trivially assignable to `any`), so the
                // attribute-derived candidate must NOT be clamped down to
                // `FieldValues`. ztsc's general object→`{[x:string]:any}` relation
                // still rejects a named interface (a separate, unrelated gap), so
                // the clamp is bypassed explicitly here. Without this, `Controller`
                // resolves `TFieldValues` to `FieldValues`, its `_defaultValues`
                // stays `{[x:string]:any}`, and `control={control}` fails (TS2322).
                const any_index_ok = try c.constraintIsAnyIndex(constraint) and
                    c.ts.kind(try c.resolveStructural(candidates[i])) == .object;
                if (constraint != types.no_type and !bare_outer and !any_index_ok and
                    !try c.isAssignable(candidates[i], constraint))
                {
                    args_buf[i] = constraint;
                }
            } else if (c.typeParamHasDefault(tp)) {
                args_buf[i] = try c.instantiate(try c.typeParamDefault(tp), prov);
            } else {
                args_buf[i] = if (constraint != types.no_type) constraint else types.unknown_type;
            }
            prov[i].ty = args_buf[i];
        }
        const map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
        return c.instantiate(sig, map);
    }

    /// Props of a class component: read the member named by
    /// `JSX.ElementAttributesProperty` (its single member's name, e.g. `props`)
    /// off the class instance type. Null when the selector namespace is absent
    /// (tsc leaves such attributes unchecked) or the class is generic (own type
    /// params — an uncommon shape we do not model here).
    fn jsxClassComponentProps(c: *Checker, class_val: TypeId) Error!?TypeId {
        const name = (try c.jsxPropsMemberName()) orelse return null;
        const cls = c.ts.classSymbol(class_val);
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(cls, &tps);
        if (tps.items.len != 0) return null; // generic class component: unmodeled
        const inst = try c.ts.makeRef(cls, &.{});
        const rinst = try c.resolveStructural(inst);
        if (try c.propOfType(rinst, name)) |p| return p.ty;
        // No resolvable props member — a modeling gap, not a genuinely
        // props-less component (an empty `Component<{}>` still yields a `props`
        // member above). This surfaces for class components whose base is a
        // class+interface declaration merge we don't fully fold (`@types/react`
        // `Component<P>` merges `interface Component extends ComponentLifecycle`
        // with `class Component { readonly props: Readonly<P> }`). Leave the
        // attributes unchecked (tsc's behavior for an unknown props target)
        // rather than reject every attribute against `{}` — under-report over a
        // false positive.
        return null;
    }

    /// Name of the props member per `JSX.ElementAttributesProperty` — the name
    /// of that interface's single property (React uses `props`). Null when the
    /// interface is absent or empty.
    fn jsxPropsMemberName(c: *Checker) Error!?Atom {
        const t = (try c.jsxNamespaceType(c.atom_ElementAttributesProperty)) orelse return null;
        const rt = try c.resolveStructural(t);
        if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return null;
        return c.ts.objectProp(rt, 0).name;
    }

    /// One explicit (literal) JSX attribute gathered during the first pass.
    const JsxAttr = struct {
        name: Atom,
        ty: TypeId,
        value: Node,
        name_tok: TokenIndex,
        overwritten: bool = false, // shadowed by a later `{...spread}` (TS2783)
    };

    /// Check a JSX element's attributes against its props type (`no_type` =
    /// unknown target, only value expressions are checked). Mirrors tsc's
    /// "attributes object assigned to props" model: per-attribute value
    /// mismatches report at the value; excess/missing report the whole object.
    ///
    /// Spread attributes (`<C {...p} />`) fold their object's properties into
    /// the attribute set (later wins). A spread's props count toward
    /// required-prop satisfaction, an explicit attribute overwritten by a later
    /// spread's REQUIRED member is TS2783 (an OPTIONAL spread member does not
    /// overwrite — tsc's checkSpreadPropOverrides rule), and a non-object
    /// spread is TS2698. Where a spread's
    /// contents cannot be confidently enumerated (`any`, generics, unions,
    /// index signatures) the missing-prop check is skipped rather than risk a
    /// false positive — tsc reports fewer such cases than it would with full
    /// generic inference, which is out of scope here.
    ///
    /// For component tags the allowed-attribute set is widened by
    /// `JSX.IntrinsicAttributes` (so `key`/`ref`-style props do not read as
    /// excess), and JSX children satisfy the `JSX.ElementChildrenAttribute`
    /// prop (so a required `children` is not spuriously reported missing). We
    /// do not type-check children values (lenient; documented).
    fn checkJsxAttributes(c: *Checker, node: Node, e: ast.JsxElementData, props: TypeId, is_component: bool, has_children: bool) Error!void {
        const attrs = c.tree.extraRange(e.attrs_start, e.attrs_end);
        const rt: TypeId = if (props != types.no_type) try c.resolveStructural(props) else types.no_type;
        // Missing/excess checks run against object targets and intersections
        // of objects (real React's `DetailedHTMLProps<...> = ClassAttributes &
        // P`); anything else (unions, generics, `any`) is handled leniently —
        // only per-attribute value assignability there. `target_props` is the
        // flattened view used by the missing/weak checks.
        var target_props: std.ArrayList(types.Prop) = .empty;
        defer target_props.deinit(c.scratch());
        const shape: JsxTargetShape = if (rt == types.no_type)
            .not_objecty
        else
            try c.jsxTargetShape(rt, &target_props);
        const is_obj_target = shape != .not_objecty;
        const target_open = shape == .open_object;

        // Names allowed but not required on a component via IntrinsicAttributes,
        // plus whether that selector interface exists at all. When it does, a
        // component's effective props target is `IntrinsicAttributes & Props`
        // (an intersection), for which tsc reports missing/excess as plain
        // TS2322 rather than the single-object TS2741/2739 refinement.
        var ia_names: std.ArrayList(Atom) = .empty;
        defer ia_names.deinit(c.scratch());
        var has_intrinsic_attrs = false;
        if (is_component) {
            if (c.jsxNamespaceMember(c.atom_IntrinsicAttributes) != null) {
                has_intrinsic_attrs = true;
                try c.jsxIntrinsicAttrNames(&ia_names);
            }
        }

        var built: std.ArrayList(JsxAttr) = .empty;
        defer built.deinit(c.scratch());
        // Props known to be provided, in source order (explicit attrs +
        // enumerable spread contents + JSX children) — the missing-required
        // check reads the names, the whole-object diagnostics build the
        // combined "attributes object" from it (later wins on duplicates).
        var provided: std.ArrayList(types.Prop) = .empty;
        defer provided.deinit(c.scratch());
        var has_spread = false;
        var spread_opaque = false; // a spread whose props we could not enumerate
        var spread_non_object = false; // saw a primitive spread (TS2698)
        var last_spread_ty: TypeId = types.no_type; // for the TS2559 message

        for (attrs) |attr| {
            if (c.nodeTag(attr) == .jsx_spread_attribute) {
                has_spread = true;
                const sd = c.tree.nodeData(attr);
                if (sd.lhs == null_node) continue;
                const sty = try c.resolveStructural(try c.checkExprCached(sd.lhs, types.no_type));
                last_spread_ty = sty;
                switch (try c.jsxSpreadInfo(sty, &provided)) {
                    .non_object => {
                        spread_non_object = true;
                        try c.diagFmt(2698, c.nodeSpan(sd.lhs), "Spread types may only be created from object types.", .{});
                    },
                    .unknown_shape => spread_opaque = true,
                    .names => |names| {
                        // A prior explicit attr re-provided by this spread is
                        // overwritten → TS2783 (this usage will be overwritten).
                        for (built.items) |*b| {
                            if (b.overwritten) continue;
                            if (containsAtom(names, b.name)) {
                                b.overwritten = true;
                                try c.diagFmt(2783, c.tokSpan(b.name_tok), "'{s}' is specified more than once, so this usage will be overwritten.", .{c.atomText(b.name)});
                            }
                        }
                    },
                }
                continue;
            }
            const ad = c.tree.nodeData(attr);
            const name_tok = c.tree.nodeMainToken(attr);
            // Contextual type for the value = the target prop's type (used only
            // for a template-literal expression value; see jsxAttributeValueType).
            const vctx: TypeId = if (rt != types.no_type and c.tree.tokens.tag(name_tok) != .jsx_name) blk: {
                const nm = try c.memberAtom(name_tok);
                break :blk if (try c.propOfType(rt, nm)) |p| p.ty else types.no_type;
            } else types.no_type;
            const vty = try c.jsxAttributeValueType(ad.lhs, vctx);
            // Hyphenated names (`data-*`, `aria-*`) are exempt from excess and
            // assignability checks (tsc), but their value expressions are still
            // checked — `jsxAttributeValueType` above did that.
            if (c.tree.tokens.tag(name_tok) == .jsx_name) continue;
            const name = try c.memberAtom(name_tok);
            try built.append(c.scratch(), .{ .name = name, .ty = vty, .value = ad.lhs, .name_tok = name_tok });
            try provided.append(c.scratch(), .{ .name = name, .ty = vty });
        }

        if (rt == types.no_type) return;

        // JSX children satisfy the ElementChildrenAttribute prop (usually
        // `children`) on component tags — count it as provided.
        if (is_component and has_children) {
            try provided.append(c.scratch(), .{ .name = try c.jsxChildrenAttrName(), .ty = types.any_type });
        }

        // Per-attribute value assignability + excess, for explicit attrs.
        var first_excess: Span = .{ .start = 0, .end = 0 };
        var have_excess = false;
        for (built.items) |b| {
            if (b.overwritten) continue; // shadowed by a later spread (TS2783)
            if (try c.propOfType(rt, b.name)) |p| {
                // tsc anchors a JSX attribute value mismatch at the attribute
                // NAME node (not the value), matching the excess-property anchor
                // above. Per-member elaboration for object/array-literal values
                // still points at the offending member via `b.value` below.
                const vspan = c.tokSpan(b.name_tok);
                // An optional prop (`date?: Date`) admits `undefined`, so an
                // explicit `date={maybeUndefined}` is not an error — mirrors the
                // structural object relation and the optional indexed-access path
                // (src/checker.zig:2864). Widen the target to `p.ty | undefined`
                // ONLY when the value can actually be undefined: a value that
                // never yields `undefined` (e.g. a fresh object literal) gets the
                // identical verdict from bare `p.ty`, and keeping it off the
                // object-to-union path avoids a distinct union-relation gap. A
                // required prop keeps `p.ty`, so an explicit `undefined` on it
                // still rejects.
                const target = if (p.optional() and c.containsUndefinedish(try c.resolveStructural(b.ty)))
                    try c.makeUnion2(p.ty, types.undefined_type)
                else
                    p.ty;
                _ = try c.checkAssignable(b.ty, target, b.value, vspan);
            } else if (target_open and !containsAtom(ia_names.items, b.name)) {
                if (!have_excess) {
                    first_excess = c.tokSpan(b.name_tok);
                    have_excess = true;
                }
            }
        }

        if (!is_obj_target) return; // lenient target: value checks only

        // When `JSX.IntrinsicAttributes` exists, a component's effective props
        // target is the intersection `IntrinsicAttributes & Props`, for which
        // tsgo reports missing props as plain TS2322 — UNLESS the namespace
        // also declares `IntrinsicClassAttributes` (as @types/react does), in
        // which case tsgo surfaces the refined TS2741/2739 against the plain
        // props type. Empirically bisected against tsgo 7.0.2; matched as
        // observed. Excess is always the plain TS2322 form.
        const raw_2322 = has_intrinsic_attrs and
            c.jsxNamespaceMember(c.atom_IntrinsicClassAttributes) == null;

        if (have_excess) {
            // Excess wins over missing and is never refined to a
            // missing-property code (tsc's message is the excess flavor).
            try c.diagFmt(2322, first_excess, "Type '{s}' is not assignable to type '{s}'.", .{
                try c.typeToString(try c.jsxAttrsObject(provided.items)),
                try c.jsxTargetString(props, has_intrinsic_attrs),
            });
            return;
        }

        // Missing required props. When a spread's contents are opaque, any
        // required prop might come from it — skip to avoid a false positive.
        if (has_spread and spread_opaque) return;

        // Weak-type check (TS2559): the target has only optional props and the
        // (spread-provided) attributes share none of them. Fires only for
        // fully-enumerated spread sources — explicit-attr mismatches are excess
        // (TS2322, above), and opaque spreads were already skipped.
        if (has_spread and target_open) {
            var target_weak = target_props.items.len > 0 or ia_names.items.len > 0;
            for (target_props.items) |tp| {
                if (!tp.optional()) {
                    target_weak = false;
                    break;
                }
            }
            if (target_weak and (spread_non_object or provided.items.len > 0)) {
                var common = false;
                for (provided.items) |pp| {
                    if ((try c.propOfType(rt, pp.name)) != null or containsAtom(ia_names.items, pp.name)) {
                        common = true;
                        break;
                    }
                }
                if (!common) {
                    const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
                    const src_ty = if (last_spread_ty != types.no_type) last_spread_ty else try c.jsxAttrsObject(provided.items);
                    try c.diagFmt(2559, span, "Type '{s}' has no properties in common with type '{s}'.", .{
                        try c.typeToString(src_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
                    });
                    return;
                }
            }
        }

        var any_missing = false;
        for (target_props.items) |tp| {
            if (tp.optional()) continue;
            if (!providedHas(provided.items, tp.name)) {
                any_missing = true;
                break;
            }
        }
        if (!any_missing) return;
        const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
        if (spread_non_object) {
            // The attributes' source type is the primitive spread itself —
            // plain TS2322 (a primitive never gets the missing-prop codes).
            try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
                try c.typeToString(last_spread_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
            });
            return;
        }
        const combined = try c.jsxAttrsObject(provided.items);
        if (raw_2322) {
            try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
                try c.typeToString(combined), try c.jsxTargetString(props, true),
            });
        } else {
            try c.reportNotAssignable(2322, combined, props, span);
        }
    }

    /// Build the fresh object type standing in for the written attributes — the
    /// combined explicit + spread-provided props, later occurrence winning.
    /// Source type of the whole-object TS2322/2741/2739 messages.
    fn jsxAttrsObject(c: *Checker, provided: []const types.Prop) Error!TypeId {
        var out: std.ArrayList(types.Prop) = .empty;
        defer out.deinit(c.scratch());
        for (provided) |p| {
            // Widened for display (`label="x"` prints as `label: string`,
            // matching tsc's messages); assignability used the fresh types.
            const wty = try c.widenLiteral(p.ty);
            var replaced = false;
            for (out.items) |*o| {
                if (o.name == p.name) {
                    o.ty = wty; // later wins
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.append(c.scratch(), .{ .name = p.name, .ty = wty });
        }
        return c.ts.makeObject(out.items, 0, 0, types.obj_flag_fresh);
    }

    /// Display string for the props target: `IntrinsicAttributes & <Props>`
    /// when the selector interface participates, else just the props type.
    fn jsxTargetString(c: *Checker, props: TypeId, with_intrinsic: bool) Error![]const u8 {
        const s = try c.typeToString(props);
        if (!with_intrinsic) return s;
        return std.fmt.allocPrint(c.scratch(), "IntrinsicAttributes & {s}", .{s});
    }

    fn providedHas(list: []const types.Prop, name: Atom) bool {
        for (list) |p| if (p.name == name) return true;
        return false;
    }

    const JsxSpread = union(enum) { non_object, unknown_shape, names: []const Atom };

    /// Classify a spread attribute's (resolved) type. `.names` are the prop
    /// names it definitely contributes (their full props appended to
    /// `provided` too); `.unknown_shape` means "unknown contents, could
    /// provide anything" (any/union/generic/index-signature); `.non_object`
    /// is a primitive (→ TS2698).
    fn jsxSpreadInfo(c: *Checker, rst: TypeId, provided: *std.ArrayList(types.Prop)) Error!JsxSpread {
        switch (c.ts.kind(rst)) {
            .object => {
                if (c.ts.objectStringIndex(rst) != 0 or c.ts.objectNumberIndex(rst) != 0) return .unknown_shape;
                var names: std.ArrayList(Atom) = .empty;
                for (0..c.ts.objectPropCount(rst)) |i| {
                    const p = c.ts.objectProp(rst, @intCast(i));
                    // `names` drives the TS2783 overwrite check, which tsc
                    // (checkSpreadPropOverrides) fires only for a REQUIRED
                    // spread member — an optional prop in the spread does not
                    // overwrite a prior explicit attribute. `provided` still
                    // gets every prop (required-satisfaction reads all).
                    if (!p.optional()) try names.append(c.scratch(), p.name);
                    try provided.append(c.scratch(), p);
                }
                return .{ .names = try names.toOwnedSlice(c.scratch()) };
            },
            .intersection => {
                var names: std.ArrayList(Atom) = .empty;
                for (try c.memberList(rst)) |m| {
                    const r = try c.resolveStructural(m);
                    if (c.ts.kind(r) != .object or c.ts.objectStringIndex(r) != 0 or c.ts.objectNumberIndex(r) != 0) {
                        names.deinit(c.scratch());
                        return .unknown_shape;
                    }
                    for (0..c.ts.objectPropCount(r)) |i| {
                        const p = c.ts.objectProp(r, @intCast(i));
                        if (!p.optional()) try names.append(c.scratch(), p.name);
                        try provided.append(c.scratch(), p);
                    }
                }
                return .{ .names = try names.toOwnedSlice(c.scratch()) };
            },
            .number, .number_literal, .number_literal_fresh, .string, .string_literal, .boolean, .bool_true, .bool_false, .bigint, .bigint_literal => return .non_object,
            else => return .unknown_shape, // any/unknown/union/type_param/mapped/…
        }
    }

    const JsxTargetShape = enum { not_objecty, open_object, closed_object };

    /// Classify a (resolved) props target and flatten its properties into
    /// `out`. Objects and intersections of objects are checkable (`open` when
    /// no constituent has an index signature — tsc only excess-checks open
    /// targets); anything else is `.not_objecty` (checked leniently).
    fn jsxTargetShape(c: *Checker, rt: TypeId, out: *std.ArrayList(types.Prop)) Error!JsxTargetShape {
        switch (c.ts.kind(rt)) {
            .object => {
                for (0..c.ts.objectPropCount(rt)) |i| {
                    try out.append(c.scratch(), c.ts.objectProp(rt, @intCast(i)));
                }
                const open = c.ts.objectStringIndex(rt) == 0 and c.ts.objectNumberIndex(rt) == 0;
                return if (open) .open_object else .closed_object;
            },
            .intersection => {
                var shape: JsxTargetShape = .open_object;
                for (try c.memberList(rt)) |m| {
                    switch (try c.jsxTargetShape(try c.resolveStructural(m), out)) {
                        .not_objecty => return .not_objecty,
                        .closed_object => shape = .closed_object,
                        .open_object => {},
                    }
                }
                return shape;
            },
            else => return .not_objecty,
        }
    }

    /// Names declared on `JSX.IntrinsicAttributes` (React: `key`, inherited
    /// from `React.Attributes`) — allowed on any component tag without being
    /// required.
    fn jsxIntrinsicAttrNames(c: *Checker, out: *std.ArrayList(Atom)) Error!void {
        const t = (try c.jsxNamespaceType(c.atom_IntrinsicAttributes)) orelse return;
        const rt = try c.resolveStructural(t);
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        if (try c.jsxTargetShape(rt, &props) == .not_objecty) return;
        for (props.items) |p| try out.append(c.scratch(), p.name);
    }

    /// The prop name JSX children flow into, per `JSX.ElementChildrenAttribute`
    /// (its single member's name — React uses `children`). Defaults to
    /// `children` when the selector interface is absent/empty.
    fn jsxChildrenAttrName(c: *Checker) Error!Atom {
        const t = (try c.jsxNamespaceType(c.atom_ElementChildrenAttribute)) orelse return c.atom_children;
        const rt = try c.resolveStructural(t);
        if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return c.atom_children;
        return c.ts.objectProp(rt, 0).name;
    }

    /// Whether a JSX element has meaningful children (any element/expression,
    /// or non-whitespace text) — whitespace-only text does not count.
    fn jsxChildrenPresent(c: *Checker, e: ast.JsxElementData) bool {
        for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
            switch (c.nodeTag(ch)) {
                .jsx_element => return true,
                .jsx_expr_container => {
                    if (c.tree.nodeData(ch).lhs != null_node) return true;
                },
                else => { // jsx_text
                    // tsc ignores text that is whitespace-only AND spans a
                    // newline (trivia between lines); same-line whitespace is
                    // a meaningful space child.
                    const span = c.nodeSpan(ch);
                    if (span.end <= c.src.len and span.start < span.end) {
                        var has_newline = false;
                        var non_ws = false;
                        for (c.src[span.start..span.end]) |ch2| {
                            if (ch2 == '\n' or ch2 == '\r') {
                                has_newline = true;
                            } else if (ch2 != ' ' and ch2 != '\t') {
                                non_ws = true;
                                break;
                            }
                        }
                        if (non_ws or !has_newline) return true;
                    }
                },
            }
        }
        return false;
    }

    fn containsAtom(list: []const Atom, name: Atom) bool {
        for (list) |a| if (a == name) return true;
        return false;
    }

    /// Type of a JSX attribute value: `name` → `true`, `name="s"` → fresh
    /// `"s"` literal, `name={e}` → type of `e` (literals kept fresh, so
    /// literal-union props accept them; widening is display-only), `name=<x/>`
    /// → JSX.Element.
    fn jsxAttributeValueType(c: *Checker, value: Node, ctx: TypeId) Error!TypeId {
        if (value == null_node) return types.true_type; // boolean shorthand
        switch (c.nodeTag(value)) {
            .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(value)), true),
            .jsx_expr_container => {
                const cd = c.tree.nodeData(value);
                if (cd.lhs == null_node) return types.undefined_type;
                // Contextually type the value by the target prop type for a
                // template-literal expression (so it keeps its template structure
                // instead of widening to `string`, e.g. `<Icon name={`ns:${s}`} />`
                // against a `` `${string}:${string}` `` prop), for an object
                // literal (so its properties are typed by the target — e.g.
                // `style={{ position: 'absolute' }}` against `CSSProperties`, whose
                // `position` is a union of string literals: without the context the
                // literal widens to `string` and rejects), and for an array literal
                // (so a fixed-length target picks the tuple member of a union —
                // e.g. `radius={[8, 8, 8, 8]}` against `number | [number, number,
                // number, number]`: without the context it widens to `number[]`
                // and fails the tuple). Other value kinds are checked context-free.
                const vctx = switch (c.nodeTag(cd.lhs)) {
                    .template_expr, .object_literal, .array_literal => ctx,
                    else => types.no_type,
                };
                return c.checkExprCached(cd.lhs, vctx);
            },
            .jsx_element => return c.checkJsxElement(value),
            else => return types.any_type,
        }
    }

    fn checkIdentifier(c: *Checker, node: Node) Error!TypeId {
        const tok = c.tree.nodeMainToken(node);
        if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
        const a = try c.atomOfToken(tok);
        switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |sym| {
                const f = c.symFlags(sym);
                if (f.import_binding) {
                    if (c.importTarget(sym)) |tgt| {
                        if (tgt.kind == .binding) {
                            const tf = c.symFlags(c.toGlobalIn(tgt.file, tgt.payload));
                            // A pure type target is 2693 (matches tsc even
                            // through `export type` chains); a value target
                            // reached through `export type` is 1362.
                            if (!hasValueMeaning(tf) and hasTypeMeaning(tf)) {
                                try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                                return types.error_type;
                            }
                        }
                        if (tgt.type_only) {
                            try c.diagFmt(1362, c.tokSpan(tok), "'{s}' cannot be used as a value because it was exported using 'export type'.", .{c.tokenText(tok)});
                            return types.error_type;
                        }
                    }
                }
                const declared = try c.typeOfSymbol(sym);
                // TDZ (TS2448): block-scoped use before declaration in the
                // same function container.
                if ((f.let_decl or f.const_decl or f.class) and !f.function and !f.var_decl and !f.param) {
                    try c.checkTdz(sym, node, tok);
                }
                // Definite assignment (TS2454).
                if ((f.let_decl or f.var_decl) and !f.param and !f.const_decl) {
                    try c.checkUseBeforeAssigned(sym, node, tok, declared);
                }
                // Flow narrowing.
                return c.flowTypeOfReference(node, sym, declared);
            },
            .wrong_space => |sym| {
                const wf = c.symFlags(sym);
                if (wf.import_binding and wf.type_only) {
                    try c.diagFmt(1361, c.tokSpan(tok), "'{s}' cannot be used as a value because it was imported using 'import type'.", .{c.tokenText(tok)});
                    return types.error_type;
                }
                try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                return types.error_type;
            },
            .none => {
                // `globalThis` is always in scope (the global-scope object).
                // ztsc doesn't synthesize the global object type, so resolve it
                // to `any` rather than reporting TS2304 (matches tsc's
                // in-scope behavior; the common use is `(globalThis as any)`).
                if (std.mem.eql(u8, c.atomText(a), "globalThis")) return types.any_type;
                if (c.suggestName(a, c.cur_scope, true)) |sugg| {
                    try c.diagFmt(2552, c.tokSpan(tok), "Cannot find name '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
                } else {
                    try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{c.tokenText(tok)});
                }
                return types.error_type;
            },
        }
    }

    fn checkTdz(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex) Error!void {
        _ = node;
        if (c.symFile(sym) != c.cur_file) return; // cross-file: no TDZ
        const decls = c.declsOf(sym);
        if (decls.len == 0) return;
        const decl_span = c.nodeSpan(decls[0]);
        const use_start = c.tree.tokens.start(tok);
        if (use_start >= decl_span.start) return;
        // Uses inside a *nested function* run later — no TDZ error.
        const use_container = c.containerOf(c.cur_scope);
        const decl_container = c.containerOf(c.symScope(sym));
        if (use_container != decl_container) return;
        const kindname = if (c.symFlags(sym).class) "Class" else "Block-scoped variable";
        try c.diagFmt(2448, c.tokSpan(tok), "{s} '{s}' used before its declaration.", .{ kindname, c.tokenText(tok) });
    }

    fn checkUseBeforeAssigned(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex, declared: TypeId) Error!void {
        // Only for declarations without initializer whose type excludes
        // undefined/any, used in the same function container.
        if (c.symFile(sym) != c.cur_file) return; // cross-file: assigned
        const decls = c.declsOf(sym);
        var has_init = false;
        var has_definite = false;
        for (decls) |decl| {
            switch (c.nodeTag(decl)) {
                .declarator_init => has_init = true,
                .declarator_full => {
                    const e = c.tree.extraData(ast.DeclaratorFull, c.tree.nodeData(decl).rhs);
                    if (e.init != 0) has_init = true;
                    if (e.flags & ast.Flags.definite != 0) has_definite = true;
                },
                .declarator => {},
                else => has_init = true, // params, for-of bindings, recovery
            }
        }
        // A use *before* the declaration (TDZ position) is also
        // definitely-unassigned even when the declarator has an
        // initializer (tsc reports 2448 + 2454 together).
        var before_decl = false;
        if (decls.len > 0) {
            const decl_span = c.nodeSpan(decls[0]);
            if (c.tree.tokens.start(tok) < decl_span.start) before_decl = true;
        }
        if ((has_init or has_definite) and !before_decl) return;
        const dk = c.ts.kind(declared);
        if (dk == .any or dk == .err or dk == .unknown or dk == .void or dk == .none) return;
        if (c.containsUndefinedish(declared)) return;
        if (c.containerOf(c.cur_scope) != c.containerOf(c.symScope(sym))) return;
        const flow = c.bind.flowAt(node) orelse return;
        if (!try c.definitelyAssigned(flow, sym)) {
            try c.diagFmt(2454, c.tokSpan(tok), "Variable '{s}' is used before being assigned.", .{c.tokenText(tok)});
        }
    }

    fn checkArrayLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        // `[...] as const`: a readonly tuple of the (non-widened) element
        // types. Nested literals recurse because const_ctx stays set.
        if (c.const_ctx) return c.checkConstArrayLiteral(node);
        const rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
        // Tuple context: a direct tuple contextual type, or an inference target
        // `T` whose constraint is tuple-like. `Promise.all([a, b])` infers into
        // `all<T extends readonly unknown[] | []>` — the `[]` member of the
        // constraint puts the array literal in tuple context (matching tsc), so
        // it becomes `[typeof a, typeof b]` and the tuple overload wins.
        var ctx_tuple_ty: TypeId = if (rctx != types.no_type and c.ts.kind(rctx) == .tuple) rctx else types.no_type;
        if (ctx_tuple_ty == types.no_type and rctx != types.no_type and c.ts.kind(rctx) == .type_param) {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rctx));
            if (con != types.no_type) {
                const rcon = try c.resolveStructural(con);
                if (c.ts.kind(rcon) == .tuple) {
                    ctx_tuple_ty = rcon;
                } else if (c.ts.kind(rcon) == .union_type) {
                    for (try c.memberList(rcon)) |m| {
                        if (c.ts.kind(try c.resolveStructural(m)) == .tuple) {
                            ctx_tuple_ty = try c.resolveStructural(m);
                            break;
                        }
                    }
                }
            }
        }
        // Union contextual type (`T[] | [A, B] | T`, or the react-hook-form
        // `Path<F> | Path<F>[]` shape): a tuple constituent puts the literal in
        // tuple context (matching tsc's `someType(ctx, isTupleLikeType)`).
        if (ctx_tuple_ty == types.no_type and rctx != types.no_type and c.ts.kind(rctx) == .union_type) {
            for (try c.memberList(rctx)) |m| {
                if (c.ts.kind(try c.resolveStructural(m)) == .tuple) {
                    ctx_tuple_ty = try c.resolveStructural(m);
                    break;
                }
            }
        }
        const ctx_tuple = ctx_tuple_ty != types.no_type;
        // Contextual element type for a plain (non-tuple) array literal. A
        // direct array context yields its element; a union context contributes
        // the element type of each array-like constituent (so array-literal
        // elements are contextually typed — literals stay literal instead of
        // widening).
        const ctx_elem: TypeId = if (!ctx_tuple) try c.contextualArrayElemType(rctx) else types.no_type;

        var elem_types: std.ArrayList(TypeId) = .empty;
        defer elem_types.deinit(c.scratch());
        var tuple_elems: std.ArrayList(types.TupleElem) = .empty;
        defer tuple_elems.deinit(c.scratch());
        var i: u32 = 0;
        for (c.tree.nodeRange(node)) |el| {
            if (el == null_node) continue;
            if (c.nodeTag(el) == .omitted) {
                try elem_types.append(c.scratch(), types.undefined_type);
                try tuple_elems.append(c.scratch(), .{ .ty = types.undefined_type });
                i += 1;
                continue;
            }
            if (c.nodeTag(el) == .spread_element) {
                const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(el).lhs, types.no_type));
                switch (c.ts.kind(st)) {
                    .array => {
                        try elem_types.append(c.scratch(), c.ts.arrayElem(st));
                        try tuple_elems.append(c.scratch(), .{ .ty = st, .flags = types.elem_flag_rest });
                    },
                    .tuple => {
                        for (0..c.ts.tupleLen(st)) |j| {
                            const e = c.ts.tupleElem(st, @intCast(j));
                            try elem_types.append(c.scratch(), e.ty);
                            try tuple_elems.append(c.scratch(), e);
                        }
                    },
                    else => {
                        // Spread of a non-array iterable (`[...set]`, `[...map]`):
                        // its element type via the `[Symbol.iterator]` protocol.
                        const elem = (try c.iterationElementType(st)) orelse types.any_type;
                        try elem_types.append(c.scratch(), elem);
                        try tuple_elems.append(c.scratch(), .{ .ty = try c.ts.makeArray(elem), .flags = types.elem_flag_rest });
                    },
                }
                i += 1;
                continue;
            }
            var ectx: TypeId = ctx_elem;
            if (ctx_tuple) {
                ectx = c.tupleElemTypeAt(ctx_tuple_ty, i) orelse types.no_type;
            }
            var et = try c.checkExprCached(el, ectx);
            if (!try c.keepLiteral(et, ectx)) et = try c.widenLiteral(et);
            try elem_types.append(c.scratch(), et);
            try tuple_elems.append(c.scratch(), .{ .ty = et });
            i += 1;
        }
        if (ctx_tuple) return c.ts.makeTuple(tuple_elems.items);
        if (elem_types.items.len == 0) {
            if (ctx_elem != types.no_type) return c.ts.makeArray(ctx_elem);
            return c.ts.makeArray(types.any_type); // evolving arrays out of scope
        }
        return c.ts.makeArray(try c.ts.makeUnion(c.scratch(), elem_types.items));
    }

    /// The element type an array literal's elements should be contextually
    /// typed against, given a (structurally resolved) contextual type. A direct
    /// array yields its element type; a union contributes the element type of
    /// every array-like constituent (mirrors tsc's per-element
    /// `getContextualTypeForElementExpression` mapping over the union). Returns
    /// `no_type` when nothing array-like is present.
    fn contextualArrayElemType(c: *Checker, rctx: TypeId) Error!TypeId {
        if (rctx == types.no_type) return types.no_type;
        switch (c.ts.kind(rctx)) {
            .array => return c.ts.arrayElem(rctx),
            .union_type => {
                var elems: std.ArrayList(TypeId) = .empty;
                defer elems.deinit(c.scratch());
                for (try c.memberList(rctx)) |m| {
                    const e = try c.contextualArrayElemType(try c.resolveStructural(m));
                    if (e != types.no_type) try elems.append(c.scratch(), e);
                }
                if (elems.items.len == 0) return types.no_type;
                return c.ts.makeUnion(c.scratch(), elems.items);
            },
            else => return types.no_type,
        }
    }

    /// `[...] as const` -> a readonly tuple. Elements keep their literal
    /// types (de-freshened so they never widen); nested array/object
    /// literals recurse via the still-set `const_ctx`.
    fn checkConstArrayLiteral(c: *Checker, node: Node) Error!TypeId {
        var elems: std.ArrayList(types.TupleElem) = .empty;
        defer elems.deinit(c.scratch());
        for (c.tree.nodeRange(node)) |el| {
            if (el == null_node) continue;
            switch (c.nodeTag(el)) {
                .omitted => try elems.append(c.scratch(), .{ .ty = types.undefined_type, .flags = types.elem_flag_readonly }),
                .spread_element => {
                    const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(el).lhs, types.no_type));
                    switch (c.ts.kind(st)) {
                        .tuple => {
                            for (0..c.ts.tupleLen(st)) |j| {
                                const e = c.ts.tupleElem(st, @intCast(j));
                                try elems.append(c.scratch(), .{ .ty = e.ty, .flags = e.flags | types.elem_flag_readonly });
                            }
                        },
                        .array => try elems.append(c.scratch(), .{ .ty = c.ts.arrayElem(st), .flags = types.elem_flag_rest | types.elem_flag_readonly }),
                        else => try elems.append(c.scratch(), .{ .ty = types.any_type, .flags = types.elem_flag_readonly }),
                    }
                },
                else => {
                    const et = try c.ts.regularLiteral(try c.checkExprCached(el, types.no_type));
                    try elems.append(c.scratch(), .{ .ty = et, .flags = types.elem_flag_readonly });
                },
            }
        }
        return c.ts.makeTuple(elems.items);
    }

    /// Collect the free type-param symbols reachable in `t` (structural walk,
    /// no expansion — a `ref` contributes its args, not its resolved body).
    fn collectTypeParamSyms(c: *Checker, t: TypeId, out: *std.ArrayList(u32)) Error!void {
        const s = &c.ts;
        switch (s.kind(t)) {
            .type_param => {
                const sym = s.typeParamSymbol(t);
                for (out.items) |x| if (x == sym) return;
                try out.append(c.scratch(), sym);
            },
            .array => try c.collectTypeParamSyms(s.arrayElem(t), out),
            .union_type, .intersection, .overloads => {
                for (try c.memberList(t)) |m| try c.collectTypeParamSyms(m, out);
            },
            .tuple => {
                for (0..s.tupleLen(t)) |i| try c.collectTypeParamSyms(s.tupleElem(t, @intCast(i)).ty, out);
            },
            .object => {
                for (0..s.objectPropCount(t)) |i| try c.collectTypeParamSyms(s.objectProp(t, @intCast(i)).ty, out);
                if (s.objectStringIndex(t) != 0) try c.collectTypeParamSyms(s.objectStringIndex(t), out);
                if (s.objectNumberIndex(t) != 0) try c.collectTypeParamSyms(s.objectNumberIndex(t), out);
            },
            .function => {
                for (0..s.fnParamCount(t)) |i| try c.collectTypeParamSyms(s.fnParam(t, @intCast(i)).ty, out);
                try c.collectTypeParamSyms(s.fnReturn(t), out);
            },
            .ref => {
                for (try c.refArgsList(t)) |a| try c.collectTypeParamSyms(a, out);
            },
            .template_literal_type => {
                for (0..s.templateHoleCount(t)) |i| try c.collectTypeParamSyms(s.templateHole(t, @intCast(i)), out);
            },
            .string_mapping => try c.collectTypeParamSyms(s.stringMappingArg(t), out),
            .keyof_op => try c.collectTypeParamSyms(s.keyofOperand(t), out),
            .conditional => {
                try c.collectTypeParamSyms(s.condCheck(t), out);
                try c.collectTypeParamSyms(s.condExtends(t), out);
                try c.collectTypeParamSyms(s.condTrue(t), out);
                try c.collectTypeParamSyms(s.condFalse(t), out);
            },
            .index_access => {
                try c.collectTypeParamSyms(s.indexAccessObj(t), out);
                try c.collectTypeParamSyms(s.indexAccessIndex(t), out);
            },
            else => {},
        }
    }

    /// Reduce a (possibly generic) type to its base constraint by substituting
    /// every free type param with its own declared constraint, iterated to a
    /// fixed point (tsc's `getBaseConstraintOfType`). Lets a deferred alias
    /// like `FieldPath<TFieldValues>` collapse to its concrete `${string}`
    /// template union once the abstract inner params are replaced by their
    /// constraints, so constraint-sensitive tests can see through it.
    fn baseConstraintOf(c: *Checker, t: TypeId) Error!TypeId {
        var syms: std.ArrayList(u32) = .empty;
        defer syms.deinit(c.scratch());
        try c.collectTypeParamSyms(t, &syms);
        if (syms.items.len == 0) return t;
        const map = try c.scratch().alloc(TpMap, syms.items.len);
        for (syms.items, 0..) |sym, i| {
            const con = try c.typeParamConstraint(sym);
            map[i] = .{ .sym = sym, .ty = if (con != types.no_type) con else types.unknown_type };
        }
        var cur = t;
        var iter: usize = 0;
        while (iter < 8) : (iter += 1) {
            const ni = try c.instantiate(cur, map);
            if (ni == cur) break;
            cur = ni;
        }
        return cur;
    }

    /// Is `t` (resolved) a primitive / literal / template / enum type, or a
    /// union of such — i.e. a context that keeps a matching fresh literal
    /// (tsc's `maybeTypeOfKind(..., Literal-ish)`)?
    fn isPrimitiveLiteralish(c: *Checker, t: TypeId) Error!bool {
        const r = try c.resolveStructural(t);
        return switch (c.ts.kind(r)) {
            .string, .string_literal, .template_literal_type, .string_mapping, .number, .number_literal, .number_literal_fresh, .bigint, .bigint_literal, .boolean, .bool_true, .bool_false, .enum_type => true,
            .union_type => blk: {
                for (try c.memberList(r)) |m| {
                    if (try c.isPrimitiveLiteralish(m)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    /// Would contextually typing an object-literal argument by `pt` preserve a
    /// property literal that would otherwise widen? True only when `pt` (an
    /// object) has a property whose type is a *type variable* whose base
    /// constraint is primitive-literal-ish — the `name: TFieldName` (`TFieldName
    /// extends FieldPath<T>`) shape. This gates the object-literal contextual
    /// pass so it fires for react-hook-form-style literal-key inference but not
    /// for object literals whose params are plain callbacks (`openDB({ upgrade
    /// }))`) or unions, which contextual typing would perturb without benefit.
    fn paramWantsLiteralCtx(c: *Checker, pt: TypeId) Error!bool {
        const r = try c.resolveStructural(pt);
        if (c.ts.kind(r) != .object) return false;
        for (0..c.ts.objectPropCount(r)) |i| {
            const p = c.ts.objectProp(r, @intCast(i));
            const pr = try c.resolveStructural(p.ty);
            if (c.ts.kind(pr) != .type_param) continue;
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(pr));
            if (con == types.no_type) continue;
            const base = if (try c.containsTypeParam(con)) try c.baseConstraintOf(con) else con;
            if (try c.isPrimitiveLiteralish(base)) return true;
        }
        return false;
    }

    /// Does the contextual type admit literal types of `t`'s kind, so the
    /// fresh literal should be kept instead of widened? (tsc's
    /// isLiteralOfContextualType; contextual `boolean` counts because it
    /// *is* `true | false` — our canonical form collapses that union.)
    fn keepLiteral(c: *Checker, t: TypeId, ctx: TypeId) Error!bool {
        if (ctx == types.no_type) return false;
        if (!c.ts.isFreshLiteral(t)) return true;
        return c.contextAdmitsLiteral(ctx, t);
    }

    fn contextAdmitsLiteral(c: *Checker, ctx: TypeId, lit: TypeId) Error!bool {
        const r = try c.resolveStructural(ctx);
        const lk = c.ts.kind(lit);
        const lit_is_bool = lk == .bool_true or lk == .bool_false;
        switch (c.ts.kind(r)) {
            .string_literal => return lk == .string_literal,
            .number_literal, .number_literal_fresh => return lk == .number_literal or lk == .number_literal_fresh,
            .bigint_literal => return lk == .bigint_literal,
            .bool_true, .bool_false, .boolean => return lit_is_bool,
            .union_type => {
                for (try c.memberList(r)) |m| {
                    if (try c.contextAdmitsLiteral(m, lit)) return true;
                }
                return false;
            },
            // A template-literal or string-mapping context is a string subtype
            // that admits any string literal *matching the pattern* (tsc
            // isLiteralOfContextualType final mask: TemplateLiteral/StringMapping
            // & isTypeAssignableTo). A generic call whose parameter is
            // constrained to such a type — react-hook-form's `name: FieldPath<T>`
            // (a `` `${string}` ``/dotted-path template union) — keeps the fresh
            // field-name literal so the type param infers to it rather than
            // widening to `string`.
            .template_literal_type, .string_mapping => return lk == .string_literal and try c.isAssignable(lit, r),
            .type_param => {
                const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
                if (constraint == types.no_type) return false;
                if (try c.contextAdmitsLiteral(constraint, lit)) return true;
                // A generic constraint (`TFieldName extends FieldPath<
                // TFieldValues>`) stays deferred while its own type params are
                // abstract, so the resolved form is neither a literal nor a
                // template and the test above fails. Reduce it to its base
                // constraint (inner params → their constraints) so the alias
                // collapses to its concrete `${string}` template union and can
                // admit the field-name literal. Only the generic case retries —
                // a concrete constraint already had its full say above.
                if (try c.containsTypeParam(constraint)) {
                    const base = try c.baseConstraintOf(constraint);
                    if (base != constraint) return c.contextAdmitsLiteral(base, lit);
                }
                return false;
            },
            else => return false,
        }
    }

    /// The literal type an object-literal property value denotes *syntactically*
    /// — a string/number/boolean literal — for use as a discriminant when the
    /// contextual type is a union. `no_type` for anything else (no full check).
    fn discriminantLiteralOf(c: *Checker, node: Node) Error!TypeId {
        if (node == null_node) return types.no_type;
        return switch (c.nodeTag(node)) {
            .string_literal => try c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(node)), false),
            .number_literal => try c.ts.makeNumberLiteral(c.numberTokenValue(c.tree.nodeMainToken(node)), false),
            .true_literal => types.true_type,
            .false_literal => types.false_type,
            else => types.no_type,
        };
    }

    /// Discriminant-guided contextual typing: when an object literal is typed by
    /// a union, filter the union to the constituents whose properties accept the
    /// literal-valued properties of the source (tsc's
    /// `discriminateTypeByDiscriminantProperties`). Typing each property against
    /// the surviving constituent(s) keeps its literal discriminant instead of
    /// widening it against a union-wide property type (`'X' | string` = `string`)
    /// that no arm's literal discriminant would then match. Only ever *narrows*
    /// the union (each removed member has a discriminant that rejects the source
    /// literal, so it can never be the target) — an empty result means no arm
    /// matched, so the original union stands and the mismatch is reported.
    fn discriminateCtxUnion(c: *Checker, node: Node, rctx: TypeId) Error!TypeId {
        var surviving = try c.memberList(rctx);
        var narrowed = false;
        for (c.tree.nodeRange(node)) |prop| {
            if (prop == null_node or c.nodeTag(prop) != .object_property) continue;
            const pd = c.tree.nodeData(prop);
            if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
            const lit = try c.discriminantLiteralOf(pd.rhs);
            if (lit == types.no_type) continue;
            const key = try c.memberAtom(c.tree.nodeMainToken(prop));
            var keep: std.ArrayList(TypeId) = .empty;
            defer keep.deinit(c.scratch());
            for (surviving) |m| {
                if (try c.propOfType(try c.resolveStructural(m), key)) |p| {
                    if (try c.isAssignable(lit, p.ty)) try keep.append(c.scratch(), m);
                } else {
                    try keep.append(c.scratch(), m); // member does not constrain `key`
                }
            }
            if (keep.items.len > 0 and keep.items.len < surviving.len) {
                surviving = try c.scratch().dupe(TypeId, keep.items);
                narrowed = true;
            }
        }
        if (!narrowed) return rctx;
        return c.ts.makeUnion(c.scratch(), surviving);
    }

    fn checkObjectLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        var rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
        if (rctx != types.no_type and c.ts.kind(rctx) == .union_type) {
            rctx = try c.discriminateCtxUnion(node, rctx);
        }
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
        defer prop_index.deinit(c.scratch());
        // Accessor keys, to type a get/set pair as one property and mark a
        // get-only accessor read-only.
        var getter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer getter_keys.deinit(c.scratch());
        var setter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        defer setter_keys.deinit(c.scratch());
        // Value types of computed keys that widen to `string`/`number` — they
        // become the object's index signatures (`{ [layer]: v }` → `{ [x:
        // string]: v }`), matching tsc. Multiple such keys union their values.
        var str_index_vals: std.ArrayList(TypeId) = .empty;
        defer str_index_vals.deinit(c.scratch());
        var num_index_vals: std.ArrayList(TypeId) = .empty;
        defer num_index_vals.deinit(c.scratch());
        // Spreading an `any`-typed source poisons the whole object literal to
        // `any` (tsc: `{ ...anyVal, x }` has type `any`), so member access on
        // it is unchecked. Tracked here and short-circuited after the loop.
        var spread_any = false;
        // Spreading a bare type parameter (`{ ...data, extra }` with `data: T`)
        // keeps `T` as a spread member in tsc's spread type — the whole literal
        // is then assignable back to `T`. ztsc has no props to fold for a
        // type-param source, so it is retained here and the result becomes
        // `T & { own props }` (an intersection is assignable to any member, so
        // `→ T` holds), matching tsc's generic-spread behavior.
        var generic_spreads: std.ArrayList(TypeId) = .empty;
        defer generic_spreads.deinit(c.scratch());

        for (c.tree.nodeRange(node)) |prop| {
            if (prop == null_node) continue;
            const pd = c.tree.nodeData(prop);
            switch (c.nodeTag(prop)) {
                .object_property => {
                    if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                        const kt = try c.checkExprCached(c.tree.nodeData(pd.lhs).lhs, types.no_type);
                        // A `unique symbol` key names a real, nominally-keyed
                        // property (`{ [k]: v }`); any other computed key stays
                        // dynamic (no static member).
                        if (try c.uniqueSymAtom(kt)) |key| {
                            const pctx = try c.ctxPropType(rctx, ctx, key);
                            var vt = try c.checkExprCached(pd.rhs, pctx);
                            if (c.const_ctx) {
                                vt = try c.ts.regularLiteral(vt);
                            } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                            continue;
                        }
                        // Non-symbol computed key (`{ [expr]: v }`): a `string`-
                        // or `number`-widening key contributes an index
                        // signature; a literal key names a real property. The
                        // value is contextually typed by the target's matching
                        // property/index (so `value: STATUS` under a `Record<…>`
                        // context keeps its literal instead of widening).
                        const rk = try c.resolveStructural(kt);
                        const key_kind = c.ts.kind(rk);
                        const pctx: TypeId = if (rctx == types.no_type) types.no_type else switch (key_kind) {
                            .string_literal => try c.ctxPropType(rctx, ctx, c.ts.dataA(rk)),
                            .string, .template_literal_type, .string_mapping => if (c.ts.kind(rctx) == .object and c.ts.objectStringIndex(rctx) != 0) c.ts.objectStringIndex(rctx) else types.no_type,
                            .number, .number_literal, .number_literal_fresh => if (c.ts.kind(rctx) == .object and c.ts.objectNumberIndex(rctx) != 0) c.ts.objectNumberIndex(rctx) else types.no_type,
                            else => types.no_type,
                        };
                        var vt = try c.checkExprCached(pd.rhs, pctx);
                        if (c.const_ctx) {
                            vt = try c.ts.regularLiteral(vt);
                        } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                        switch (key_kind) {
                            .string_literal => {
                                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = c.ts.dataA(rk), .ty = vt });
                            },
                            .string, .template_literal_type, .string_mapping => try str_index_vals.append(c.scratch(), vt),
                            .number, .number_literal, .number_literal_fresh => try num_index_vals.append(c.scratch(), vt),
                            else => {}, // symbol/unknown/other: no static member
                        }
                        continue;
                    }
                    const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                    const pctx = try c.ctxPropType(rctx, ctx, key);
                    var vt = try c.checkExprCached(pd.rhs, pctx);
                    if (c.const_ctx) {
                        vt = try c.ts.regularLiteral(vt);
                    } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                    try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                },
                .object_shorthand => {
                    const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                    var vt = try c.checkExprCached(pd.lhs, types.no_type);
                    const pctx = try c.ctxPropType(rctx, ctx, key);
                    if (c.const_ctx) {
                        vt = try c.ts.regularLiteral(vt);
                    } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                    if (pd.rhs != 0) _ = try c.checkExprCached(pd.rhs, types.no_type);
                    try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                },
                .object_method => {
                    if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                        _ = try c.checkExprCached(pd.rhs, types.no_type);
                        continue;
                    }
                    const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                    // Accessor shorthand (`get x() {}` / `set x(v) {}`): the
                    // property type is the getter's return type (or the
                    // setter's parameter type when there's no getter). A
                    // get-only accessor is read-only.
                    const fproto = c.tree.extraData(ast.FnProto, c.tree.nodeData(pd.rhs).lhs);
                    const is_get = fproto.flags & ast.Flags.get != 0;
                    const is_set = fproto.flags & ast.Flags.set != 0;
                    if (is_get or is_set) {
                        const sig = try c.checkExprCached(pd.rhs, types.no_type);
                        if (is_get) {
                            try getter_keys.put(c.scratch(), key, {});
                            const gt = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.any_type;
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = gt });
                        } else {
                            try setter_keys.put(c.scratch(), key, {});
                            // A getter, if present, wins the property type.
                            if (!getter_keys.contains(key)) {
                                const st = if (c.ts.kind(sig) == .function and c.ts.fnParamCount(sig) > 0)
                                    c.ts.fnParam(sig, 0).ty
                                else
                                    types.any_type;
                                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = st });
                            }
                        }
                        continue;
                    }
                    const pctx = try c.ctxPropType(rctx, ctx, key);
                    const mt = try c.checkExprCached(pd.rhs, pctx);
                    try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = mt });
                },
                .spread_element => {
                    const st = try c.resolveStructural(try c.checkExprCached(pd.lhs, types.no_type));
                    if (c.ts.kind(st) == .any or c.ts.kind(st) == .err) spread_any = true;
                    if (c.ts.kind(st) == .type_param) {
                        try generic_spreads.append(c.scratch(), st);
                        continue;
                    }
                    try c.gatherSpreadProps(st, &props, &prop_index, &str_index_vals, &num_index_vals);
                },
                else => _ = try c.checkExprCached(prop, types.no_type),
            }
        }
        if (spread_any) return types.any_type;
        // Get-only accessors are read-only properties.
        var git = getter_keys.keyIterator();
        while (git.next()) |k| {
            if (setter_keys.contains(k.*)) continue;
            if (prop_index.get(k.*)) |idx| props.items[idx].flags |= types.prop_flag_readonly;
        }
        // `{...} as const`: every property is readonly.
        if (c.const_ctx) {
            for (props.items) |*p| p.flags |= types.prop_flag_readonly;
        }
        const sidx = if (str_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), str_index_vals.items) else 0;
        const nidx = if (num_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), num_index_vals.items) else 0;
        const obj = try c.ts.makeObject(props.items, sidx, nidx, types.obj_flag_fresh);
        // A type-parameter spread (`{ ...data, extra }`, `data: T`) yields
        // `T & { extra }` so the literal stays assignable to `T`.
        if (generic_spreads.items.len > 0) {
            try generic_spreads.append(c.scratch(), obj);
            return c.ts.makeIntersection(c.scratch(), generic_spreads.items);
        }
        return obj;
    }

    /// Contextual type for property `key` of an object literal typed by
    /// `ctx` (unions: union of the property across constituents).
    fn ctxPropType(c: *Checker, rctx: TypeId, ctx: TypeId, key: Atom) Error!TypeId {
        if (ctx == types.no_type) return types.no_type;
        switch (c.ts.kind(rctx)) {
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(rctx)) |m| {
                    // Recurse (not a bare `propOfType`) so a union member that
                    // is itself an intersection — an *optional* parameter typed
                    // `RegisterOptions | undefined` where RegisterOptions is
                    // `Partial<C> & (A | B | C)` — routes through the
                    // intersection arm below and finds the union-nested prop.
                    const pt = try c.ctxPropType(try c.resolveStructural(m), ctx, key);
                    if (pt != types.no_type) try parts.append(c.scratch(), pt);
                }
                if (parts.items.len == 0) return types.no_type;
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            // A contextual property inside an intersection (`Partial<C> & (A |
            // B | C)`) may live in a *union* member. `propOfType` has no union
            // arm, so the intersection lookup below would miss it and the
            // property would widen (react-hook-form's RegisterOptions:
            // `valueAsNumber?: false | true`, so a fresh `valueAsNumber: true`
            // widened to `boolean` and matched no union arm → TS2345). Recurse
            // per member — a union member is handled by the arm above — and
            // intersect the per-member contextual types, mirroring tsc's
            // `getTypeOfPropertyOfContextualType` over an intersection.
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(rctx)) |m| {
                    const pt = try c.ctxPropType(try c.resolveStructural(m), ctx, key);
                    if (pt != types.no_type) try parts.append(c.scratch(), pt);
                }
                if (parts.items.len == 0) return types.no_type;
                if (parts.items.len == 1) return parts.items[0];
                return c.ts.makeIntersection(c.scratch(), parts.items);
            },
            else => {
                if (try c.propOfType(rctx, key)) |p| return p.ty;
                return types.no_type;
            },
        }
    }

    /// Does `node` denote an optional chain — i.e. does its object/callee
    /// spine contain a `?.` link (without crossing parentheses, `!`, or `new`,
    /// which all break the chain)? A member/element/call access whose object is
    /// such a chain *continues* it: it short-circuits on a nullish object
    /// rather than erroring, and propagates `undefined` to the chain's result
    /// (tsc's `OptionalChain` node flag / optional-type marker).
    fn isOptionalChain(c: *Checker, node: Node) bool {
        return switch (c.nodeTag(node)) {
            .optional_member_expr, .optional_index_expr, .optional_call => true,
            .member_expr, .index_expr, .call_expr, .call_expr_targs => c.isOptionalChain(c.tree.nodeData(node).lhs),
            else => false,
        };
    }

    /// Type of a chain link's object/callee, WITHOUT the chain's short-circuit
    /// `undefined` (that is tracked in `chained`). Only called when `node` is
    /// itself an optional chain, so downstream declared-nullish still reports.
    fn chainObjType(c: *Checker, node: Node, chained: *bool) Error!TypeId {
        return switch (c.nodeTag(node)) {
            .member_expr, .optional_member_expr => c.memberChainInner(node, chained),
            .index_expr, .optional_index_expr => c.indexChainInner(node, chained),
            .call_expr, .call_expr_targs, .optional_call => c.checkCallExprInner(node, false, chained, types.no_type),
            else => c.checkExprCached(node, types.no_type),
        };
    }

    fn checkMemberExpr(c: *Checker, node: Node) Error!TypeId {
        var chained = false;
        const pt = try c.memberChainInner(node, &chained);
        if (chained) return c.makeUnion2(pt, types.undefined_type);
        return pt;
    }

    /// Property access, treated as a link in a (possibly single-element)
    /// optional chain. Returns the property type WITHOUT the chain's
    /// short-circuit `undefined`; sets `chained.*` when this `?.` link — or an
    /// earlier one in the object spine — short-circuits on a nullish object. A
    /// non-`?.` continuation whose object is *declared* nullish still reports
    /// TS2532/18047-9 via `checkNullishAccess` (the marker distinguishes the
    /// chain's own undefined from an inherently-nullable intermediate).
    fn memberChainInner(c: *Checker, node: Node, chained: *bool) Error!TypeId {
        const d = c.tree.nodeData(node);
        const own_optional = c.nodeTag(node) == .optional_member_expr;
        var obj_t = if (c.isOptionalChain(d.lhs))
            try c.chainObjType(d.lhs, chained)
        else
            try c.checkExprCached(d.lhs, types.no_type);
        const name_tok: TokenIndex = d.rhs;
        const name = try c.memberAtom(name_tok);
        if (own_optional) {
            if (c.containsNullish(obj_t) or c.ts.kind(obj_t) == .null or c.ts.kind(obj_t) == .undefined) {
                chained.* = true;
            }
            obj_t = try c.nonNullable(obj_t);
        } else {
            obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
        }
        var pt = try c.propertyTypeOf(obj_t, name, name_tok);
        // Property-path narrowing: peel the whole access spine into a member
        // path (`x.p`, `this.p`, `x.a.b`, …) capped at `max_ref_depth`.
        if (try c.buildRefKey(node)) |key| {
            pt = try c.flowTypeOfKey(node, key, pt);
        }
        return pt;
    }

    /// TS18047/18048/18049 (entity names) / TS2531/2532/2533 (expressions)
    /// for non-optional access on possibly-nullish objects. Returns the
    /// non-nullable remainder to continue checking with.
    fn checkNullishAccess(c: *Checker, t: TypeId, obj_node: Node, access_node: Node) Error!TypeId {
        const k = c.ts.kind(t);
        const has_null = c.containsNull(t) or k == .null;
        const has_undef = c.containsUndefinedish(t) or k == .undefined or k == .void;
        if (!has_null and !has_undef) return t;
        _ = access_node;
        const span = c.nodeSpan(obj_node);
        // tsc's entity-name codes (18047-49) apply to identifier-rooted
        // paths only; a `this`-rooted path gets the expression codes
        // (2531-33, "Object is possibly ...").
        const this_rooted = blk: {
            var n = obj_node;
            while (c.nodeTag(n) == .member_expr or c.nodeTag(n) == .optional_member_expr or c.nodeTag(n) == .paren_expr) {
                n = c.tree.nodeData(n).lhs;
            }
            break :blk c.nodeTag(n) == .this_expr;
        };
        const name_opt: ?[]const u8 = if (this_rooted) null else c.entityNameOf(obj_node);
        if (name_opt) |name| {
            if (has_null and has_undef) {
                try c.diagFmt(18049, span, "'{s}' is possibly 'null' or 'undefined'.", .{name});
            } else if (has_null) {
                try c.diagFmt(18047, span, "'{s}' is possibly 'null'.", .{name});
            } else {
                try c.diagFmt(18048, span, "'{s}' is possibly 'undefined'.", .{name});
            }
        } else {
            if (has_null and has_undef) {
                try c.diagFmt(2533, span, "Object is possibly 'null' or 'undefined'.", .{});
            } else if (has_null) {
                try c.diagFmt(2531, span, "Object is possibly 'null'.", .{});
            } else {
                try c.diagFmt(2532, span, "Object is possibly 'undefined'.", .{});
            }
        }
        return c.nonNullable(t);
    }

    /// Render an entity-name-ish expression (a, a.b, a.b.c) or null.
    fn entityNameOf(c: *Checker, node: Node) ?[]const u8 {
        switch (c.nodeTag(node)) {
            .identifier => return c.tokenText(c.tree.nodeMainToken(node)),
            .member_expr, .optional_member_expr => {
                const d = c.tree.nodeData(node);
                // A `?.` link still roots an entity-name path, so tsc uses the
                // named codes (18047-9) rather than the object codes (2531-3)
                // for a nullish access on `a?.b`.
                const base = c.entityNameOf(d.lhs) orelse return null;
                _ = base;
                // Rebuild from source bytes: span of the whole node.
                const span = c.nodeSpan(node);
                if (span.end <= c.src.len and span.start < span.end) {
                    const text = c.src[span.start..span.end];
                    if (text.len <= 64 and std.mem.indexOfAny(u8, text, " \t\n(") == null) return text;
                }
                return null;
            },
            .this_expr => return "this",
            else => return null,
        }
    }

    /// Property `name` on `t`, with TS2339/TS2551 on failure.
    fn propertyTypeOf(c: *Checker, t: TypeId, name: Atom, name_tok: TokenIndex) Error!TypeId {
        const k = c.ts.kind(t);
        switch (k) {
            .any, .err, .none => return types.any_type,
            // Property access on `never` is silently `never` (tsc; typically
            // the non-nullable remainder of a null-narrowed reference).
            .never => return types.never_type,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| {
                    const rm = try c.resolveStructural(m);
                    if (c.ts.kind(rm) == .any or c.ts.kind(rm) == .err) {
                        try parts.append(c.scratch(), types.any_type);
                        continue;
                    }
                    const p = (try c.propOfType(rm, name)) orelse {
                        try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'.", .{
                            c.atomText(name), try c.typeToString(t),
                        });
                        return types.error_type;
                    };
                    var pt = try c.substThis(p.ty, m);
                    if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                    try parts.append(c.scratch(), pt);
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            else => {
                const r = try c.resolveStructural(t);
                if (c.ts.kind(r) == .any or c.ts.kind(r) == .err) return types.any_type;
                if (try c.propOfType(r, name)) |p| {
                    var pt = try c.substThis(p.ty, t);
                    if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                    return pt;
                }
                // Instance access to a static member (TS2576).
                if (k == .ref) {
                    const cls = c.ts.refSymbol(t);
                    const cls_bind = c.symBind(cls);
                    if (c.symFlags(cls).class) {
                        if (cls_bind.staticsScopeOf(c.localOf(cls))) |ss| {
                            if (cls_bind.lookupInScope(ss, name) != null) {
                                try c.diagFmt(2576, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'. Did you mean to access the static member '{s}.{s}' instead?", .{
                                    c.atomText(name), try c.typeToString(t), c.symbolName(cls), c.atomText(name),
                                });
                                return types.error_type;
                            }
                        }
                    }
                }
                if (c.suggestProp(name, r)) |sugg| {
                    try c.diagFmt(2551, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'. Did you mean '{s}'?", .{
                        c.atomText(name), try c.typeToString(t), c.atomText(sugg),
                    });
                } else {
                    try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'.", .{
                        c.atomText(name), try c.typeToString(t),
                    });
                }
                return types.error_type;
            },
        }
    }

    fn checkIndexExpr(c: *Checker, node: Node) Error!TypeId {
        var chained = false;
        const r = try c.indexChainInner(node, &chained);
        if (chained) return c.makeUnion2(r, types.undefined_type);
        return r;
    }

    /// Element access as an optional-chain link (see `memberChainInner`).
    fn indexChainInner(c: *Checker, node: Node, chained: *bool) Error!TypeId {
        const d = c.tree.nodeData(node);
        const own_optional = c.nodeTag(node) == .optional_index_expr;
        var obj_t = if (c.isOptionalChain(d.lhs))
            try c.chainObjType(d.lhs, chained)
        else
            try c.checkExprCached(d.lhs, types.no_type);
        const idx_t = try c.checkExprCached(d.rhs, types.no_type);
        if (own_optional) {
            if (c.containsNullish(obj_t)) chained.* = true;
            obj_t = try c.nonNullable(obj_t);
        } else {
            obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
        }
        const r = try c.resolveStructural(obj_t);
        const rk = c.ts.kind(r);
        if (rk == .any or rk == .err) return types.any_type;
        var result: TypeId = types.any_type;
        // `o[Symbol.iterator]` (and the other well-known symbols): the member
        // is keyed syntactically by `__@iterator` on the declaration side
        // (`wellKnownSymbolKey`), so the access side must key it the same way.
        // In the real lib `Symbol.iterator` is typed `unique symbol`, so this
        // must run *before* the generic `unique symbol` (`__@uN`) path below,
        // which would otherwise look up a mismatched nominal key.
        if (c.wellKnownKeyOfExpr(d.rhs)) |wk| {
            const key = try c.atom(wk);
            if (try c.propOfType(r, key)) |p| {
                result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            } else {
                try c.diagFmt(2339, c.nodeSpan(d.rhs), "Property '{s}' does not exist on type '{s}'.", .{
                    c.atomText(key), try c.typeToString(obj_t),
                });
                result = types.error_type;
            }
            return result;
        }
        // `o[k]` where `k` is a `unique symbol`: resolve the nominally-keyed
        // property (see `uniqueSymAtom`).
        if (try c.uniqueSymAtom(idx_t)) |key| {
            if (try c.propOfType(r, key)) |p| {
                result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            } else {
                // A `unique symbol` that does not key a member of the target:
                // tsc reports TS7053 (implicit-any index) rather than TS2339,
                // since the key is a symbol, not a named property. Suppressed
                // under `noImplicitAny: false` (implicit-'any' family).
                if (c.prog.no_implicit_any) {
                    try c.diagFmt(7053, c.nodeSpan(d.rhs), "Element implicitly has an 'any' type because expression of type 'unique symbol' can't be used to index type '{s}'.", .{
                        try c.typeToString(obj_t),
                    });
                }
                result = types.error_type;
            }
            return result;
        }
        const ik = c.ts.kind(try c.ts.regularLiteral(idx_t));
        switch (ik) {
            .string_literal => {
                const key = c.ts.literalAtom(try c.ts.regularLiteral(idx_t));
                if (try c.propOfType(r, key)) |p| {
                    result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                } else if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                    result = c.ts.objectStringIndex(r);
                } else {
                    // Element access `o['k']` with a string-literal key that is
                    // neither a known property nor covered by a string index is,
                    // for tsc, an implicit-'any' element access (TS7053) — NOT a
                    // missing-property TS2339 (which is reserved for dotted `o.k`).
                    // Suppressed under `noImplicitAny: false`; the result is `any`
                    // either way.
                    if (c.prog.no_implicit_any) {
                        try c.diagFmt(7053, c.nodeSpan(node), "Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{
                            try c.typeToString(idx_t), try c.typeToString(obj_t),
                        });
                    }
                    result = types.any_type;
                }
            },
            .number_literal => {
                const rl = try c.ts.regularLiteral(idx_t);
                if (rk == .tuple) {
                    const v = c.ts.numberValue(rl);
                    const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                    if (iv < c.ts.tupleLen(r)) {
                        const e = c.ts.tupleElem(r, iv);
                        result = if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
                    } else if (c.tupleElemTypeAt(r, iv)) |et| {
                        result = et;
                    } else {
                        try c.diagFmt(2493, c.nodeSpan(d.rhs), "Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{
                            try c.typeToString(r), c.ts.tupleLen(r), iv,
                        });
                        result = types.error_type;
                    }
                } else {
                    result = try c.numberIndexType(r);
                }
            },
            .number => result = try c.numberIndexType(r),
            .string => {
                if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                    result = c.ts.objectStringIndex(r);
                } else if (rk == .array or rk == .tuple or rk == .string) {
                    result = types.any_type;
                } else {
                    result = types.any_type;
                }
            },
            else => result = types.any_type,
        }
        return result;
    }

    fn checkPrefixUnary(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
        switch (op) {
            .keyword_typeof => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return c.typeof_union;
            },
            .bang => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return types.boolean_type;
            },
            .keyword_void => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return types.undefined_type;
            },
            .keyword_delete => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return types.boolean_type;
            },
            .keyword_await => {
                // `await` legality: inside a non-async function → TS1308; at the
                // top level of a non-module file → TS1375 (top-level await is
                // otherwise allowed under module: esnext).
                if (c.fn_ctx) |fc| {
                    if (!fc.is_async) {
                        try c.diagFmt(1308, c.nodeSpan(node), "'await' expressions are only allowed within async functions and at the top levels of modules.", .{});
                    }
                } else if (c.bind.imports.len == 0 and c.bind.exports.len == 0) {
                    try c.diagFmt(1375, c.nodeSpan(node), "'await' expressions are only allowed at the top level of a file when that file is a module, but this file has no imports or exports. Consider adding an empty 'export {{}}' to make this file a module.", .{});
                }
                // `await e`: unwrap `Promise<T>` to `T`; a non-thenable passes
                // through. Single-level only (deeper `Awaited<T>` is a gap).
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                return try c.awaitedType(ot);
            },
            .minus => {
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                const rl = try c.ts.regularLiteral(ot);
                if (c.ts.kind(rl) == .number_literal) {
                    return c.ts.makeNumberLiteral(-c.ts.numberValue(rl), c.ts.isFreshLiteral(ot));
                }
                try c.checkArithmeticOperand(ot, d.lhs);
                if (c.isBigintish(ot)) return types.bigint_type;
                return types.number_type;
            },
            .plus, .tilde => {
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkArithmeticOperand(ot, d.lhs);
                return types.number_type;
            },
            .plus_plus, .minus_minus => {
                const ot = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkArithmeticOperand(ot, d.lhs);
                return types.number_type;
            },
            else => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                return types.any_type;
            },
        }
    }

    fn isNumberish(c: *Checker, t: TypeId) bool {
        return c.unionAnyMemberAll(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                return switch (ch.ts.kind(m)) {
                    .number, .number_literal, .number_literal_fresh, .any, .err, .never => true,
                    .enum_type => !ch.enumHasStringMember(ch.ts.enumSymbol(m)),
                    else => false,
                };
            }
        }.f);
    }

    fn isBigintish(c: *Checker, t: TypeId) bool {
        return c.unionAnyMemberAll(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                return switch (ch.ts.kind(m)) {
                    .bigint, .bigint_literal, .any, .err, .never => true,
                    else => false,
                };
            }
        }.f);
    }

    fn isStringish(c: *Checker, t: TypeId) bool {
        return c.unionAnyMemberAll(t, struct {
            fn f(ch: *Checker, m: TypeId) bool {
                return switch (ch.ts.kind(m)) {
                    .string, .string_literal, .any, .err, .never => true,
                    .enum_type => ch.enumHasStringMember(ch.ts.enumSymbol(m)),
                    else => false,
                };
            }
        }.f);
    }

    fn unionAnyMemberAll(c: *Checker, t: TypeId, comptime f: fn (*Checker, TypeId) bool) bool {
        if (c.ts.kind(t) == .union_type) {
            for (c.ts.members(t)) |m| {
                if (!f(c, m)) return false;
            }
            return true;
        }
        return f(c, t);
    }

    fn isArithmeticOperand(c: *Checker, t: TypeId) bool {
        return c.isNumberish(t) or c.isBigintish(t);
    }

    fn checkArithmeticOperand(c: *Checker, t: TypeId, node: Node) Error!void {
        if (c.isArithmeticOperand(t)) return;
        try c.diagFmt(2356, c.nodeSpan(node), "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.", .{});
    }

    /// TS2359 gate: is `t` a valid `instanceof` right-hand side — i.e. `any`,
    /// or a type assignable to the `Function` interface? tsc accepts any type
    /// that carries a call or construct signature (constructor interfaces like
    /// `ErrorConstructor`/`RegExpConstructor` behind the `Error`/`RegExp`
    /// value globals, plain function types, class constructors), or that
    /// declares a `[Symbol.hasInstance]` method. Refs are resolved structurally
    /// so a value typed as a constructor interface is recognized; a union is
    /// valid iff every constituent is, an intersection iff any is, and a
    /// type-parameter defers to its constraint.
    fn instanceofRhsIsFunctionLike(c: *Checker, t: TypeId, depth: u32) Error!bool {
        if (depth > 8) return true; // give up conservatively — never over-report
        switch (c.ts.kind(t)) {
            .any, .err, .function, .overloads, .class_value => return true,
            else => {},
        }
        const rs = try c.resolveStructural(t);
        switch (c.ts.kind(rs)) {
            .any, .err, .function, .overloads, .class_value => return true,
            .object => {
                if (c.ts.objectHasSigs(rs)) return true;
                // A plain object with a `[Symbol.hasInstance]` method is a
                // legal RHS (tsc), even without call/construct signatures.
                if (c.ts.objectPropByName(rs, try c.atom("__@hasInstance")) != null) return true;
                return false;
            },
            .union_type => {
                for (try c.memberList(rs)) |m| {
                    if (!try c.instanceofRhsIsFunctionLike(m, depth + 1)) return false;
                }
                return true;
            },
            .intersection => {
                for (try c.memberList(rs)) |m| {
                    if (try c.instanceofRhsIsFunctionLike(m, depth + 1)) return true;
                }
                return false;
            },
            .type_param => {
                const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rs));
                if (con == types.no_type or con == rs or con == t) return false;
                return c.instanceofRhsIsFunctionLike(con, depth + 1);
            },
            else => return false,
        }
    }

    fn checkBinary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        const d = c.tree.nodeData(node);
        const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
        switch (op) {
            .amp_amp => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                const falsy = try c.getFalsyPart(lt, false);
                return c.logicalUnion(falsy, rt);
            },
            .pipe_pipe => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                const truthy = try c.getTruthyPart(lt);
                return c.logicalUnion(truthy, rt);
            },
            .question_question => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                return c.logicalUnion(try c.nonNullable(lt), rt);
            },
            .plus => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                const lk = c.ts.kind(lt);
                const rk = c.ts.kind(rt);
                if (lk == .any or rk == .any or lk == .err or rk == .err) return types.any_type;
                if (c.isStringish(lt) or c.isStringish(rt)) {
                    // string + anything stringifiable
                    return types.string_type;
                }
                if (c.isNumberish(lt) and c.isNumberish(rt)) return types.number_type;
                if (c.isBigintish(lt) and c.isBigintish(rt)) return types.bigint_type;
                try c.diagFmt(2365, c.nodeSpan(node), "Operator '+' cannot be applied to types '{s}' and '{s}'.", .{
                    try c.typeToString(lt), try c.typeToString(rt),
                });
                return types.error_type;
            },
            .minus, .asterisk, .slash, .percent, .asterisk_asterisk, .lt_lt, .gt_gt, .gt_gt_gt, .amp, .pipe, .caret => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                if (!c.isArithmeticOperand(lt)) {
                    try c.diagFmt(2362, c.nodeSpan(d.lhs), "The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
                }
                if (!c.isArithmeticOperand(rt)) {
                    try c.diagFmt(2363, c.nodeSpan(d.rhs), "The right-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
                }
                if (c.isBigintish(lt) and c.isBigintish(rt) and
                    !c.isNumberish(lt) and !c.isNumberish(rt)) return types.bigint_type;
                return types.number_type;
            },
            .lt, .gt, .lt_eq, .gt_eq => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                // tsc's relational rule (checkBinaryLikeExpressionWorker): strip
                // null/undefined (checkNonNullType), then the pair is legal iff
                // BOTH sides are number/bigint-like, OR NEITHER side is
                // number-like and one is comparable to the other. The
                // "neither number-like" guard is essential: it rejects
                // `{valueOf():number} > number` even though `number` is
                // assignable to `{valueOf():number}` (oracle-verified), while
                // still admitting `Date > Date`, `string > string`, and any two
                // structurally-comparable object types.
                const ls = try c.nonNullable(lt);
                const rs = try c.nonNullable(rt);
                const lk = c.ts.kind(ls);
                const rk = c.ts.kind(rs);
                const ok = lk == .any or rk == .any or lk == .err or rk == .err or blk: {
                    const lnum = c.isNumberish(ls) or c.isBigintish(ls);
                    const rnum = c.isNumberish(rs) or c.isBigintish(rs);
                    if (lnum and rnum) break :blk true;
                    if (!lnum and !rnum) break :blk (try c.isComparable(ls, rs));
                    break :blk false;
                };
                if (!ok) {
                    try c.diagFmt(2365, c.nodeSpan(node), "Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{
                        c.tokenText(c.tree.nodeMainToken(node)), try c.typeToString(lt), try c.typeToString(rt),
                    });
                }
                return types.boolean_type;
            },
            .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                // TS2367: no overlap (any union constituents comparable).
                if (!try c.typesHaveOverlap(lt, rt)) {
                    try c.diagFmt(2367, c.nodeSpan(node), "This comparison appears to be unintentional because the types '{s}' and '{s}' have no overlap.", .{
                        try c.typeToString(lt), try c.typeToString(rt),
                    });
                }
                return types.boolean_type;
            },
            .keyword_instanceof => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                if (!try c.instanceofRhsIsFunctionLike(rt, 0)) {
                    try c.diagFmt(2359, c.nodeSpan(d.rhs), "The right-hand side of an 'instanceof' expression must be of type 'any' or of a type assignable to the 'Function' interface type.", .{});
                }
                return types.boolean_type;
            },
            .keyword_in => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, types.no_type);
                if (!c.isStringish(lt) and !c.isNumberish(lt) and c.ts.kind(lt) != .symbol) {
                    try c.diagFmt(2360, c.nodeSpan(d.lhs), "The left-hand side of an 'in' expression must be of type 'any', 'string', 'number', or 'symbol'.", .{});
                }
                const rk = c.ts.kind(try c.resolveStructural(rt));
                if (!isNonPrimitiveKind(rk) and rk != .any and rk != .err and rk != .type_param and rk != .union_type and rk != .unknown) {
                    try c.diagFmt(2361, c.nodeSpan(d.rhs), "The right-hand side of an 'in' expression must not be a primitive.", .{});
                }
                return types.boolean_type;
            },
            else => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                _ = try c.checkExprCached(d.rhs, types.no_type);
                return types.any_type;
            },
        }
    }

    fn checkAssignExpr(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
        const target_t = try c.checkAssignmentTarget(d.lhs);
        var rhs_ctx: TypeId = if (op == .eq) target_t else types.no_type;
        if (target_t == types.error_type) rhs_ctx = types.no_type;
        const rt = try c.checkExprCached(d.rhs, rhs_ctx);
        switch (op) {
            .eq => {
                if (target_t != types.error_type and target_t != types.any_type) {
                    _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
                }
                return rt;
            },
            .plus_eq => {
                if (c.isStringish(target_t)) return types.string_type;
                return types.number_type;
            },
            .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => {
                if (target_t != types.error_type and target_t != types.any_type) {
                    _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
                }
                return rt;
            },
            else => return types.number_type, // -=, *=, ... numeric compounds
        }
    }

    /// Type of an assignment target; reports TS2588 (const) and TS2540
    /// (readonly property).
    fn checkAssignmentTarget(c: *Checker, node: Node) Error!TypeId {
        switch (c.nodeTag(node)) {
            .identifier => {
                const tok = c.tree.nodeMainToken(node);
                const a = try c.atomOfToken(tok);
                switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| {
                        const sf = c.symFlags(sym);
                        if (sf.const_decl) {
                            try c.diagFmt(2588, c.tokSpan(tok), "Cannot assign to '{s}' because it is a constant.", .{c.tokenText(tok)});
                            return types.error_type; // suppress cascading 2322
                        }
                        if (sf.import_binding) {
                            try c.diagFmt(2632, c.tokSpan(tok), "Cannot assign to '{s}' because it is an import.", .{c.tokenText(tok)});
                            return types.error_type;
                        }
                        return c.typeOfSymbol(sym);
                    },
                    .wrong_space => return types.error_type,
                    .none => {
                        try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{c.tokenText(tok)});
                        return types.error_type;
                    },
                }
            },
            .member_expr => {
                const d = c.tree.nodeData(node);
                var obj_t = try c.checkExprCached(d.lhs, types.no_type);
                obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
                const name = try c.memberAtom(d.rhs);
                const r = try c.resolveStructural(obj_t);
                if (try c.propOfType(r, name)) |p| {
                    // A readonly property may be assigned via `this.x` inside the
                    // constructor of the class that OWNS the declaration (tsc:
                    // `checkReferenceExpression`). An inherited readonly still
                    // errors, so the property must be an OWN member of the
                    // constructor's class.
                    const ctor_ok = c.nodeTag(d.lhs) == .this_expr and c.ctorClassOwnsMember(name);
                    if (p.readonly() and !ctor_ok) {
                        try c.diagFmt(2540, c.tokSpan(d.rhs), "Cannot assign to '{s}' because it is a read-only property.", .{c.atomText(name)});
                        return types.error_type; // suppress cascading 2322
                    }
                    // An optional property accepts `undefined` as a write target
                    // (exactOptionalPropertyTypes is off): `x.opt = undefined` is
                    // legal. Fold `| undefined` in exactly as the read path does,
                    // so the write-target type is not narrower than the read type.
                    if (p.optional()) return c.makeUnion2(p.ty, types.undefined_type);
                    return p.ty;
                }
                return c.propertyTypeOf(obj_t, name, d.rhs);
            },
            .index_expr => {
                // Writing to a readonly tuple element (from `as const`) is
                // TS2540, like a readonly property.
                const d = c.tree.nodeData(node);
                const r = try c.resolveStructural(try c.checkExprCached(d.lhs, types.no_type));
                if (c.ts.kind(r) == .tuple) {
                    const idx_t = try c.ts.regularLiteral(try c.checkExprCached(d.rhs, types.no_type));
                    if (c.ts.kind(idx_t) == .number_literal) {
                        const v = c.ts.numberValue(idx_t);
                        const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                        if (iv < c.ts.tupleLen(r) and c.ts.tupleElem(r, iv).readonly()) {
                            try c.diagFmt(2540, c.nodeSpan(d.rhs), "Cannot assign to '{d}' because it is a read-only property.", .{iv});
                            return types.error_type;
                        }
                    }
                }
                return c.checkIndexExpr(node);
            },
            .array_literal, .object_literal, .array_pattern, .object_pattern => {
                // Destructuring assignment targets: check element reads only.
                var it = c.tree.childIterator(node);
                while (it.next()) |child| _ = try c.checkExprCached(child, types.no_type);
                return types.any_type;
            },
            else => return c.checkExprCached(node, types.no_type),
        }
    }

    fn checkFunctionLikeExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        // A const assertion does not propagate into function bodies.
        const prev_cc = c.const_ctx;
        c.const_ctx = false;
        defer c.const_ctx = prev_cc;
        const d = c.tree.nodeData(node);
        var ctx_sig: TypeId = types.no_type;
        if (ctx != types.no_type) {
            const rctx = try c.resolveStructural(ctx);
            switch (c.ts.kind(rctx)) {
                .function => ctx_sig = rctx,
                .union_type => {
                    for (try c.memberList(rctx)) |m| {
                        const rm = try c.resolveStructural(m);
                        if (c.ts.kind(rm) == .function) {
                            ctx_sig = rm;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
        const sig = try c.signatureOfProtoCtx(node, d.lhs, false, ctx_sig == types.no_type, ctx_sig);
        // Check the body.
        try c.checkFunctionBody(node, d.lhs, d.rhs, sig);
        return sig;
    }

    fn templateAtom(c: *Checker, tok: TokenIndex) Error!Atom {
        const text = c.tokenText(tok);
        if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
            return c.atom(text[1 .. text.len - 1]);
        }
        return c.atom(text);
    }

    fn numberTokenValue(c: *const Checker, tok: TokenIndex) f64 {
        const raw = c.tokenText(tok);
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (raw) |ch| {
            if (ch == '_') continue;
            if (n >= buf.len) break;
            buf[n] = ch;
            n += 1;
        }
        const text = buf[0..n];
        if (text.len > 2 and text[0] == '0') {
            const radix: ?u8 = switch (text[1]) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                else => null,
            };
            if (radix) |r| {
                const v = std.fmt.parseInt(u64, text[2..], r) catch return 0;
                return @floatFromInt(v);
            }
        }
        return std.fmt.parseFloat(f64, text) catch 0;
    }

    // =====================================================================
    // calls
    // =====================================================================

    const CallShape = struct {
        callee: Node,
        targ_nodes: []const Node = &.{},
        arg_nodes: []const Node = &.{},
        optional: bool = false,
    };

    fn callShape(c: *Checker, node: Node) CallShape {
        const d = c.tree.nodeData(node);
        switch (c.nodeTag(node)) {
            .call_expr, .new_expr => {
                const r = c.tree.extraData(ast.SubRange, d.rhs);
                return .{ .callee = d.lhs, .arg_nodes = c.tree.extraRange(r.start, r.end) };
            },
            .call_expr_targs, .new_expr_targs, .optional_call => {
                const info = c.tree.extraData(ast.CallInfo, d.rhs);
                return .{
                    .callee = d.lhs,
                    .targ_nodes = c.tree.extraRange(info.targs_start, info.targs_end),
                    .arg_nodes = c.tree.extraRange(info.args_start, info.args_end),
                    .optional = c.nodeTag(node) == .optional_call,
                };
            },
            .new_expr_bare => return .{ .callee = d.lhs },
            else => return .{ .callee = d.lhs },
        }
    }

    fn checkCallExpr(c: *Checker, node: Node, is_new: bool, ctx: TypeId) Error!TypeId {
        var chained = false;
        const result = try c.checkCallExprInner(node, is_new, &chained, ctx);
        if (chained) return c.makeUnion2(result, types.undefined_type);
        return result;
    }

    /// Call/new as an optional-chain link (see `memberChainInner`). Returns the
    /// return type WITHOUT the chain's short-circuit `undefined`; sets
    /// `chained.*` when this `?.()` — or an earlier link in the callee spine —
    /// short-circuits on a nullish callee.
    fn checkCallExprInner(c: *Checker, node: Node, is_new: bool, chained: *bool, ctx: TypeId) Error!TypeId {
        const shape = c.callShape(node);
        var callee_t = if (c.isOptionalChain(shape.callee))
            try c.chainObjType(shape.callee, chained)
        else
            try c.checkExprCached(shape.callee, types.no_type);
        if (shape.optional) {
            if (c.containsNullish(callee_t)) chained.* = true;
            callee_t = try c.nonNullable(callee_t);
        }
        var r = try c.resolveStructural(callee_t);
        var rk = c.ts.kind(r);
        // A merged value (e.g. `function F(){}` + `namespace F {}`) types as an
        // intersection of a callable and the namespace object; pick the
        // callable (or constructable, for `new`) member to resolve against.
        if (rk == .intersection) {
            for (try c.memberList(r)) |m| {
                const rm = try c.resolveStructural(m);
                const mk = c.ts.kind(rm);
                // A merged/curried callable can present its call signatures on
                // an OBJECT member (an interface with call/construct sigs), not
                // only as a `.function`/`.overloads` — e.g. RTK's
                // `createAsyncThunk: CreateAsyncThunkFunction<C> & { withTypes }`
                // whose callable arm is `CreateAsyncThunkFunction` (an object
                // carrying call signatures). Accept it so the `.object` call/new
                // arm resolves the signatures instead of falling through to
                // TS2349/TS2351.
                const usable = if (is_new)
                    (mk == .class_value or (mk == .object and c.ts.objectConstructSigCount(rm) > 0))
                else
                    (mk == .function or mk == .overloads or (mk == .object and c.ts.objectCallSigCount(rm) > 0));
                if (usable) {
                    r = rm;
                    rk = mk;
                    break;
                }
            }
        }
        if (rk == .any or rk == .err) {
            for (shape.arg_nodes) |an| {
                if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
            }
            return if (rk == .err) types.error_type else types.any_type;
        }
        // Calling a value of the global `Function` type: tsc treats `Function`
        // as callable, accepting any arguments and yielding `any` (the interface
        // body carries no call signature, so a structural resolve would report
        // TS2349). Mirrors the assignable-to-`Function` special-case in the
        // relation. Only for calls — `new (x: Function)` stays unmodeled.
        if (!is_new and c.ts.kind(callee_t) == .ref and
            c.globalSymNamed(c.ts.refSymbol(callee_t), "Function"))
        {
            for (shape.arg_nodes) |an| {
                if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
            }
            return types.any_type;
        }

        // Explicit type arguments.
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        for (shape.targ_nodes) |tn| {
            if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
        }

        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        var instance_ret: TypeId = types.no_type; // for `new C(...)`

        if (is_new) {
            if (rk == .class_value) {
                const cls = c.ts.classSymbol(r);
                if (try c.classIsAbstract(cls)) {
                    try c.diagFmt(2511, c.nodeSpan(node), "Cannot create an instance of an abstract class.", .{});
                }
                var ctor_sigs: std.ArrayList(TypeId) = .empty;
                defer ctor_sigs.deinit(c.scratch());
                try c.ctorSignatures(cls, &ctor_sigs);
                // Class type params (not the ctor's own).
                var tps: std.ArrayList(TypeParamInfo) = .empty;
                defer tps.deinit(c.scratch());
                try c.typeParamsOf(cls, &tps);
                var tp_syms = try c.scratch().alloc(u32, tps.items.len);
                for (tps.items, 0..) |tp, i| tp_syms[i] = tp.sym;
                const inst_args = try c.scratch().alloc(TypeId, tps.items.len);
                if (targs.items.len > 0) {
                    const fixed = try c.fixTypeArgs(cls, targs.items, c.tree.nodeMainToken(node)) orelse return types.error_type;
                    @memcpy(inst_args, fixed);
                } else if (tps.items.len > 0) {
                    // Infer class type args from ctor arguments.
                    const ctor = if (ctor_sigs.items.len > 0) ctor_sigs.items[0] else types.no_type;
                    if (ctor != types.no_type) {
                        try c.inferTypeArgs(ctor, tp_syms, shape.arg_nodes, inst_args, types.no_type, types.no_type);
                    } else {
                        for (inst_args) |*x| x.* = types.any_type;
                    }
                }
                instance_ret = try c.ts.makeRef(cls, inst_args);
                if (ctor_sigs.items.len == 0) {
                    // Default constructor: no args allowed beyond none? tsc
                    // allows zero args (inherited default). Check arity 0.
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    if (countArgs(shape.arg_nodes) > 0) {
                        try c.diagFmt(2554, c.nodeSpan(node), "Expected 0 arguments, but got {d}.", .{countArgs(shape.arg_nodes)});
                    }
                    return instance_ret;
                }
                // Instantiate ctor sigs with the class args.
                var map = try c.scratch().alloc(TpMap, tps.items.len);
                for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = inst_args[i] };
                for (ctor_sigs.items) |sig| {
                    try sigs.append(c.scratch(), try c.instantiate(sig, map));
                }
            } else if (rk == .object and c.ts.objectConstructSigCount(r) > 0) {
                // Callable object with construct signatures (M18.1), e.g.
                // `declare var Array: ArrayConstructor` then `new Array()`.
                // The signature's own return type is the instance type, so no
                // `instance_ret` override is needed (unlike a class value).
                for (0..c.ts.objectConstructSigCount(r)) |i| {
                    try sigs.append(c.scratch(), c.ts.objectConstructSig(r, @intCast(i)));
                }
            } else {
                try c.diagFmt(2351, c.nodeSpan(shape.callee), "This expression is not constructable.", .{});
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return types.error_type;
            }
        } else {
            switch (rk) {
                .function => try sigs.append(c.scratch(), r),
                .overloads => {
                    for (try c.memberList(r)) |m| try sigs.append(c.scratch(), m);
                },
                // Calling `never` is silently `never` (tsc; typically the
                // non-nullable remainder of a null-narrowed reference).
                .never => {
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.never_type;
                },
                // Callable object with call signatures (M18.1).
                .object => {
                    if (c.ts.objectCallSigCount(r) == 0) {
                        try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return types.error_type;
                    }
                    for (0..c.ts.objectCallSigCount(r)) |i| {
                        try sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
                    }
                },
                // Calling a union (e.g. `(A[] | B[]).map(...)`, where the member
                // access yields a union of the constituents' call-signature
                // functions). tsc: the union is callable iff EVERY constituent is
                // callable; the call resolves against the gathered signatures
                // (overload-style). A single `any`/`err` member makes the whole
                // call `any` (its signatures are unconstrained). A `never` member
                // contributes nothing (callable). Any non-callable member keeps
                // the TS2349.
                .union_type => {
                    var all_callable = true;
                    var saw_any = false;
                    for (try c.memberList(r)) |m| {
                        const rm = try c.resolveStructural(m);
                        switch (c.ts.kind(rm)) {
                            .any, .err => saw_any = true,
                            .never => {},
                            .function => try sigs.append(c.scratch(), rm),
                            .overloads => {
                                for (try c.memberList(rm)) |mm| try sigs.append(c.scratch(), mm);
                            },
                            .object => {
                                const n = c.ts.objectCallSigCount(rm);
                                if (n == 0) {
                                    all_callable = false;
                                } else {
                                    for (0..n) |i| try sigs.append(c.scratch(), c.ts.objectCallSig(rm, @intCast(i)));
                                }
                            },
                            else => all_callable = false,
                        }
                    }
                    if (!all_callable) {
                        try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return types.error_type;
                    }
                    if (saw_any or sigs.items.len == 0) {
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return types.any_type;
                    }
                },
                else => {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.error_type;
                },
            }
        }

        const result = try c.resolveSignatureCall(node, sigs.items, targs.items, shape.arg_nodes, instance_ret, if (is_new) types.no_type else ctx);
        return result;
    }

    /// Receiver check for a signature with an explicit `this` parameter
    /// (`f(this: T, …)`): the call's receiver must be assignable to `T`
    /// (TS2684). A member call `obj.m()` uses `obj`'s type; a bare call uses
    /// `void` (no receiver).
    fn checkThisArg(c: *Checker, node: Node, sig: TypeId) Error!void {
        const this_ty = c.ts.fnThisType(sig);
        if (this_ty == 0) return;
        const callee = c.callShape(node).callee;
        var recv: TypeId = types.void_type;
        switch (c.nodeTag(callee)) {
            .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {
                recv = try c.checkExprCached(c.tree.nodeData(callee).lhs, types.no_type);
            },
            else => {},
        }
        if (!try c.isAssignable(recv, this_ty)) {
            // TS7 reports the specific missing-property error (TS2741/2739) when
            // the receiver simply lacks required members; a member present with
            // an incompatible type still yields the TS2684 wrapper.
            if (try c.tryReportMissingProps(recv, this_ty, c.nodeSpan(callee))) return;
            try c.diagFmt(2684, c.nodeSpan(callee), "The 'this' context of type '{s}' is not assignable to method's 'this' of type '{s}'.", .{
                try c.typeToString(recv), try c.typeToString(this_ty),
            });
        }
    }

    fn countArgs(arg_nodes: []const Node) usize {
        var n: usize = 0;
        for (arg_nodes) |a| {
            if (a != null_node) n += 1;
        }
        return n;
    }

    /// Pick a signature (first match for overloads, like tsc), infer type
    /// arguments, check arguments, and return the (instantiated) return
    /// type; `instance_ret` overrides the return for `new`.
    fn resolveSignatureCall(
        c: *Checker,
        node: Node,
        sigs: []const TypeId,
        explicit_targs: []const TypeId,
        arg_nodes: []const Node,
        instance_ret: TypeId,
        ret_ctx: TypeId,
    ) Error!TypeId {
        if (sigs.len == 0) return types.any_type;
        const nargs = countArgs(arg_nodes);
        if (sigs.len == 1) {
            const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
            if (instance_ret == types.no_type) try c.checkThisArg(node, inst);
            try c.checkCallArguments(node, inst, arg_nodes, true);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
        }
        // Overloads: first signature whose arity fits and whose args check.
        for (sigs) |sig| {
            // With explicit type arguments, only a signature with the matching
            // type-parameter count is a candidate (tsc). Skips e.g. the
            // non-generic `new (): Map<any, any>` when `new Map<K, V>()` names
            // two type args, so the generic overload is chosen instead.
            if (explicit_targs.len > 0 and !c.sigTargArityOk(sig, explicit_targs.len)) continue;
            const inst = try c.instantiateSigForCall(sig, explicit_targs, arg_nodes, node, ret_ctx);
            if (nargs < try c.requiredParams(inst) or nargs > c.paramTotal(inst)) continue;
            if (try c.argumentsMatch(inst, arg_nodes)) {
                try c.checkCallArguments(node, inst, arg_nodes, true);
                return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
            }
        }
        try c.diagFmt(2769, c.nodeSpan(c.callShape(node).callee), "No overload matches this call.", .{});
        // Continue with the first signature for downstream typing.
        const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        for (arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
    }

    /// Instantiate a (possibly generic) signature for a call: explicit
    /// type args win; otherwise unify parameters against arguments
    /// (two-phase: plain args first, then context-sensitive function args).
    fn instantiateSigForCall(c: *Checker, sig: TypeId, explicit_targs: []const TypeId, arg_nodes: []const Node, node: Node, ret_ctx: TypeId) Error!TypeId {
        c.infer_fell_back = false;
        const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        if (tps.len == 0) return sig;
        var args_buf = try c.scratch().alloc(TypeId, tps.len);
        if (explicit_targs.len > 0) {
            const min = c.sigMinTargs(tps);
            if (explicit_targs.len < min or explicit_targs.len > tps.len) {
                if (min == tps.len) {
                    try c.diagFmt(2558, c.nodeSpan(node), "Expected {d} type arguments, but got {d}.", .{ tps.len, explicit_targs.len });
                } else {
                    try c.diagFmt(2558, c.nodeSpan(node), "Expected {d}-{d} type arguments, but got {d}.", .{ min, tps.len, explicit_targs.len });
                }
            }
            for (tps, 0..) |tp, i| {
                if (i < explicit_targs.len) {
                    args_buf[i] = explicit_targs[i];
                } else if (c.typeParamHasDefault(tp)) {
                    // A missing trailing arg takes its default, instantiated
                    // under the args resolved so far (so `B = A` sees the
                    // supplied `A`, `C = B` sees the defaulted `B`).
                    const def = try c.typeParamDefault(tp);
                    const pmap = try c.scratch().alloc(TpMap, i);
                    for (tps[0..i], 0..) |ptp, j| pmap[j] = .{ .sym = ptp, .ty = args_buf[j] };
                    args_buf[i] = try c.instantiate(def, pmap);
                } else {
                    args_buf[i] = types.any_type;
                }
            }
        } else {
            // The receiver type feeds inference of a `this`-parameter type
            // param (recomputed only when the signature declares one, since
            // `checkExprCached` on the member object is otherwise wasted work).
            var recv_ty: TypeId = types.no_type;
            if (c.ts.fnThisType(sig) != 0) {
                const callee = c.callShape(node).callee;
                switch (c.nodeTag(callee)) {
                    .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {
                        recv_ty = try c.checkExprCached(c.tree.nodeData(callee).lhs, types.no_type);
                    },
                    else => {},
                }
            }
            try c.inferTypeArgs(sig, tps, arg_nodes, args_buf, ret_ctx, recv_ty);
        }
        var map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
        return c.instantiate(sig, map);
    }

    /// tsc's `InferencePriority.ReturnType`: infer still-unbound type params by
    /// unifying the signature's return type against the structurally-resolved
    /// contextual return type `ret_ctx`, writing into `target` only where it is
    /// currently `no_type`. Used both to *seed* callback contextual typing
    /// (before argument inference) and to *fill* leftover params (after it).
    /// No-op when nothing is unbound or the context is `any`/`unknown`/error.
    fn fillFromReturnContext(c: *Checker, sig: TypeId, tp_syms: []const u32, ret_ctx: TypeId, target: []TypeId, bare_callback_only: bool) Error!void {
        if (ret_ctx == types.no_type or c.ts.kind(sig) != .function) return;
        var any_empty = false;
        for (target) |t| {
            if (t == types.no_type) any_empty = true;
        }
        if (!any_empty) return;
        const rctx = try c.resolveStructural(ret_ctx);
        const rk = c.ts.kind(rctx);
        if (rk == .any or rk == .unknown or rk == .err) return;
        const ret = c.ts.fnReturn(sig);
        const rc = try c.scratch().alloc(TypeId, tp_syms.len);
        for (rc) |*x| x.* = types.no_type;
        try c.unify(ret, rctx, tp_syms, rc, 0);
        for (target, 0..) |*t, i| {
            if (t.* != types.no_type or rc[i] == types.no_type) continue;
            // Seed path (`bare_callback_only`): only fill a param that is the
            // *bare* return type of some callback parameter — `map<U>(cb: (…) =>
            // U)`, where seeding `U` cleanly propagates a literal-keeping
            // contextual return into the callback body. A param buried in a
            // union callback return (`flatMap<U>(cb: (…) => U | readonly U[])`)
            // is left to the ordinary post-argument fill (Phase 3), so seeding
            // never perturbs the callback's contextual type into a spurious
            // self-mismatch on already-hard flatMap inferences.
            if (bare_callback_only and !c.paramIsBareCallbackReturn(sig, tp_syms[i])) continue;
            // The final resolution loop only clamps a candidate to its
            // constraint when that constraint is *retrievable and concrete*;
            // otherwise it trusts the candidate outright. A low-priority
            // contextual guess must not exploit that trust to override a param's
            // default. Skip when the constraint is a bare outer type param, or
            // is unretrievable while the param has a default — the higher-order
            // `<AD extends TBase = TBase>` (redux `useDispatch`) shape, whose
            // minted param keeps only the substituted default.
            // `featureCollection`'s `G` keeps a concrete `Geometry` constraint,
            // so it is still filled.
            const con = try c.typeParamConstraint(tp_syms[i]);
            const bare_outer_con = con != types.no_type and
                c.ts.kind(con) == .type_param and
                tpIndex(tp_syms, c.ts.typeParamSymbol(con)) == null;
            const undefendable_default = con == types.no_type and c.typeParamHasDefault(tp_syms[i]);
            if (bare_outer_con or undefendable_default) continue;
            t.* = rc[i];
        }
    }

    /// True when `tp_sym` is the *bare* return type of some function-typed
    /// parameter of `sig` — the `map<U>(cb: (…) => U)` shape, where seeding `U`
    /// from the call's contextual return type cleanly makes the callback body
    /// keep literal discriminants. A union/array-wrapped return (`flatMap`'s
    /// `U | readonly U[]`) does not qualify.
    fn paramIsBareCallbackReturn(c: *Checker, sig: TypeId, tp_sym: u32) bool {
        const n = c.ts.fnParamCount(sig);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const pt = c.ts.fnParam(sig, i).ty;
            if (c.ts.kind(pt) != .function) continue;
            const r = c.ts.fnReturn(pt);
            if (c.ts.kind(r) == .type_param and c.ts.typeParamSymbol(r) == tp_sym) return true;
        }
        return false;
    }

    /// Basic unification: gather candidates for each type parameter from
    /// argument types matched against parameter positions; default to the
    /// constraint or `unknown`.
    fn inferTypeArgs(
        c: *Checker,
        sig: TypeId,
        tp_syms: []const u32,
        arg_nodes: []const Node,
        out: []TypeId,
        ret_ctx: TypeId,
        recv_ty: TypeId,
    ) Error!void {
        const candidates = try c.scratch().alloc(TypeId, tp_syms.len);
        for (candidates) |*x| x.* = types.no_type;

        // Infer type parameters that appear in an explicit `this` parameter
        // (`flat<A, D extends number = 1>(this: A, depth?: D)`) from the call's
        // receiver — tsc treats the receiver as the `this` argument. Without it
        // `A` stays unbound and `arr.flat()`'s `FlatArray<A, D>[]` return
        // collapses to `unknown[]` (spurious TS2339 on every element access).
        // Gated on a signature that actually declares a `this` type, so the
        // common array/iterator methods (whose element type already flows from
        // the receiver's `Array<T>` interface, no `this` param) are untouched.
        const this_ty = c.ts.fnThisType(sig);
        if (this_ty != 0 and recv_ty != types.no_type) {
            try c.unify(this_ty, recv_ty, tp_syms, candidates, 0);
        }

        // Phase 1: non-function arguments.
        var ai: u32 = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            const tag = c.nodeTag(an);
            if (tag == .arrow_fn or tag == .function_expr) continue;
            const pt = c.paramTypeAt(sig, ai) orelse continue;
            // Contextually type an array literal by the parameter so a
            // tuple-constrained target (`T extends readonly unknown[] | []`)
            // infers a tuple, not a widened array — the crux of picking the
            // tuple `Promise.all` overload. Other argument shapes keep the
            // context-free inference to avoid perturbing literal widening.
            // A nested generic *call* argument is also contextually typed by
            // `pt` (the still-uninstantiated parameter, whose free type params
            // act as the inference variables): `new Map(rows.map(r => [r.id,
            // r.n]))` threads `Iterable<readonly [K,V]>` into `.map`'s callback
            // so the array literal forms a tuple, and the outer `K`/`V` then
            // infer `string`/`number` from `[string, number][]` instead of
            // collapsing to `unknown`.
            var arg_ctx = switch (tag) {
                .array_literal, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => pt,
                // Contextually type an object-literal argument by the parameter
                // so a property whose parameter type is a literal-constrained
                // inference target (`name: TFieldName`, `TFieldName extends
                // FieldPath<T>` — a string-literal union) keeps its literal
                // instead of widening to `string`. Without it, `useWatch({
                // control, name: 'selectedActions' })` widens `'selectedActions'`
                // → `string`, which fails the `FieldPath` constraint, so
                // `TFieldName` falls back to the whole path union and the return
                // `FieldPathValue<T, TFieldName>` collapses. Mirrors tsc's
                // `getContextualTypeForArgument`. Gated to params that actually
                // have a literal-keeping type-variable property so unrelated
                // object-literal arguments (callback bags like `openDB({ upgrade
                // })`) keep their context-free check.
                .object_literal => if (try c.paramWantsLiteralCtx(pt)) pt else types.no_type,
                else => types.no_type,
            };
            // Fresh object literal into a bare type-param parameter (`truncate<T
            // extends AllGeoJSON>(v: T)` called with `{ type: 'Feature', … }`):
            // contextually type it by the type param's instantiated constraint,
            // so a discriminant property whose constraint type is a literal
            // (`type: 'Feature'`) keeps its literal instead of widening. Without
            // it the widened `{ type: string }` fails `T extends AllGeoJSON`, so
            // `T` is clamped to the whole constraint union → the argument's real
            // shape is lost. Mirrors tsc's `getContextualTypeForArgument`
            // falling back to the instantiated constraint. A non-fresh variable
            // argument is not an object-literal node, so it never reaches here —
            // its already-widened type still fails the constraint (unchanged).
            if (tag == .object_literal and c.ts.kind(try c.resolveStructural(pt)) == .type_param) {
                const con = try c.typeParamConstraint(c.ts.typeParamSymbol(try c.resolveStructural(pt)));
                if (con != types.no_type) arg_ctx = con;
            }
            const at = try c.checkExprCached(an, arg_ctx);
            try c.unify(pt, at, tp_syms, candidates, 0);
        }
        // Phase 1.5: contextual return-type *seed* (tsc's ReturnType-priority
        // inference happens *before* callback arguments are contextually
        // typed). A type param appearing only in a callback's return position
        // and in the signature's return type — `Array.map<U>(cb: (…) => U):
        // U[]` under an expected `Polygon[]` — is fixed to `Polygon` from the
        // outer context, so the callback body is typed against `Polygon` and
        // keeps its literal discriminants (`{ type: 'Polygon' }`) instead of
        // widening `U` to `any` and inferring `{ type: string }`. The seed only
        // feeds the contextual `partial` below; argument inference still writes
        // the committed `candidates` (so argument evidence wins the final args).
        // Allocated only when there is a contextual return to seed from — the
        // overwhelmingly common uncontextual call keeps the original (no extra
        // scratch) path, using `candidates` directly as the partial source.
        const seed: []const TypeId = if (ret_ctx != types.no_type) blk: {
            const s = try c.scratch().alloc(TypeId, tp_syms.len);
            for (s, 0..) |*x, i| x.* = candidates[i];
            try c.fillFromReturnContext(sig, tp_syms, ret_ctx, s, true);
            break :blk s;
        } else candidates;
        // Phase 2: function arguments, contextually typed by the partial
        // instantiation (seeded with the return-context inferences above).
        var partial = try c.scratch().alloc(TpMap, tp_syms.len);
        for (tp_syms, 0..) |tp, i| {
            partial[i] = .{ .sym = tp, .ty = if (seed[i] != types.no_type) seed[i] else types.any_type };
        }
        ai = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            const tag = c.nodeTag(an);
            if (tag != .arrow_fn and tag != .function_expr) continue;
            const pt0 = c.paramTypeAt(sig, ai) orelse continue;
            const pt_partial = try c.instantiate(pt0, partial);
            const at = try c.checkExprCached(an, pt_partial);
            try c.unify(pt0, at, tp_syms, candidates, 0);
        }
        // Phase 3: contextual return-type inference for any params still
        // unbound after argument inference (argument inference always wins —
        // this only *fills* params that no argument constrained) — so
        // `union(featureCollection(xs))` recovers `featureCollection`'s `G`
        // from the expected `FeatureCollection<Polygon | MultiPolygon>` instead
        // of falling back to `G`'s constraint (the whole `Geometry` union).
        try c.fillFromReturnContext(sig, tp_syms, ret_ctx, candidates, false);
        // A provisional map over the raw candidates, so an inter-dependent
        // constraint (`K extends keyof T`, M16d) is checked with the *other*
        // params already substituted — `keyof T` becomes `keyof {…}` before the
        // satisfaction test, instead of staying a deferred `keyof T` that no
        // literal is assignable to.
        var prov = try c.scratch().alloc(TpMap, tp_syms.len);
        for (tp_syms, 0..) |tp, i| {
            prov[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
        }
        // `infos[i].constraint` is an AST node id in the type param's
        // *declaring* file (e.g. a foreign generic's `.d.ts`), not in `c.tree`
        // (the call site). It is resolved via the symbol below so the
        // constraint is evaluated in its declaring file + declaration scope
        // (`enterSymFile` + `symScope`, per `typeParamConstraint`); evaluating
        // the raw node against `c.tree` reads out of bounds when the two files
        // differ. `tp == infos[i].sym`, and the symbol's type_param decl is the
        // very node the constraint field came from, so this is equivalent.
        // Resolve in declaration order, feeding each resolved arg back into
        // `prov` so a later param's constraint that references an earlier one
        // sees the *resolved* value, not the `any` placeholder. tsc's
        // `getInferredTypes` works this way; without it an un-inferred `TOpt`
        // stayed `any` inside `Ret extends TReturn<TOpt>`, so
        // `any['returnObjects'] extends true` wrongly took the true branch
        // (i18next `t()` → `$SpecialObject` instead of `string`).
        // Signature return type (for the literal-widening top-level test below);
        // `no_type` when `sig` is not a plain function (an overload set never
        // reaches per-signature inference here).
        const sig_ret: TypeId = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.no_type;
        for (tp_syms, 0..) |tp, i| {
            var constraint: TypeId = try c.typeParamConstraint(tp);
            if (constraint != types.no_type) constraint = try c.instantiate(constraint, prov);
            if (candidates[i] != types.no_type) {
                out[i] = candidates[i];
                // tsc's `getCovariantInference` widens a fresh-literal inference
                // candidate (`getWidenedLiteralType`) before fixing the param —
                // UNLESS the param has a primitive/literal constraint (which
                // keeps the literal) or it appears at the top level of the
                // signature's return type. `useState<S>(x): [S, …]` → `S` is a
                // tuple element (not top-level), no constraint → `useState(false)`
                // widens `S` to `boolean`, so `setX(true)` no longer spuriously
                // fails; `id<T>(x: T): T` keeps `T` (top-level return);
                // `f<T extends 'a' | 'b'>` keeps the literal (primitive
                // constraint). Only fresh literals widen, so `x as const` and a
                // `null` candidate stay narrow. An explicit type argument never
                // reaches here (it fills `out` directly upstream).
                if (sig_ret != types.no_type and
                    !try c.constraintIsPrimitive(constraint) and
                    !try c.typeParamAtTopLevel(sig_ret, tp))
                {
                    out[i] = try c.widenLiteral(out[i]);
                }
                // Candidate violating the constraint falls back to the
                // constraint (tsc then re-checks args against it). But skip
                // the fallback when the constraint — after substituting the
                // params inferred so far — still references an *outer* type
                // param we cannot resolve here: e.g. a generic-interface
                // method `filter<S extends T>` accessed on an instantiated
                // `Array<number|null>`, whose receiver `T` is not part of this
                // call's inference set. The constraint stays a bare `T`, so
                // `isAssignable(number, T)` always fails and would erase the
                // legitimately-inferred `S=number` back to `T` (`S[]` → `T[]`).
                // tsc has the substituted bound (`S extends number|null`) and
                // keeps `number`; we cannot recover it, so trust the candidate.
                // The skip is deliberately narrow — only a *bare* outer type
                // param (`S extends T`, `T` being the receiver's param). A
                // complex constraint that merely mentions an outer param
                // (`K extends keyof T`) still falls back, so RHF-style deep
                // generics keep their prior (permissive) behavior.
                const bare_outer = constraint != types.no_type and
                    c.ts.kind(constraint) == .type_param and
                    tpIndex(tp_syms, c.ts.typeParamSymbol(constraint)) == null;
                if (constraint != types.no_type and !bare_outer and
                    !try c.isAssignable(candidates[i], constraint))
                {
                    out[i] = constraint;
                    c.infer_fell_back = true;
                }
            } else if (c.typeParamHasDefault(tp)) {
                // Uninferable param with a default takes it, instantiated under
                // the params resolved so far (`B = A` sees the inferred `A`).
                const def = try c.typeParamDefault(tp);
                out[i] = try c.instantiate(def, prov);
            } else {
                out[i] = if (constraint != types.no_type) constraint else types.unknown_type;
            }
            prov[i].ty = out[i];
        }
    }

    fn tpIndex(tp_syms: []const u32, sym: u32) ?usize {
        for (tp_syms, 0..) |s, i| {
            if (s == sym) return i;
        }
        return null;
    }

    fn unify(c: *Checker, param: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
        if (depth > 16) return;
        const s = &c.ts;
        // An `any` source infers `any` for every inference position in the
        // pattern (tsc's inferFromTypes). Without this, `any` slips past the
        // structural cases (it matches nothing and everything), leaving params
        // unbound — e.g. `then`'s `TResult1 | PromiseLike<TResult1>` against an
        // `any` callback return would bind nothing because `any` is assignable
        // to the union's other members.
        if (s.kind(arg) == .any) {
            try c.bindAnyToTypeParams(param, tp_syms, candidates, depth);
            return;
        }
        switch (s.kind(param)) {
            .type_param => {
                if (tpIndex(tp_syms, s.typeParamSymbol(param))) |i| {
                    const cand = arg;
                    if (candidates[i] == types.no_type) {
                        candidates[i] = cand;
                    } else {
                        candidates[i] = try c.makeUnion2(candidates[i], cand);
                    }
                }
            },
            .array => {
                const ra = try c.resolveStructural(arg);
                switch (s.kind(ra)) {
                    .array => try c.unify(s.arrayElem(param), s.arrayElem(ra), tp_syms, candidates, depth + 1),
                    .tuple => {
                        for (0..s.tupleLen(ra)) |i| {
                            try c.unify(s.arrayElem(param), s.tupleElem(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                        }
                    },
                    .union_type => {
                        // A nullable/union iterable context (`Iterable<E> |
                        // null` — the Map/Set constructor parameter shape):
                        // infer from each constituent, ignoring the members
                        // (`null`/`undefined`) that yield no iteration element.
                        // Mirrors tsc's `getContextualType` mapping over union
                        // constituents.
                        for (try c.memberList(ra)) |m| {
                            try c.unify(param, m, tp_syms, candidates, depth + 1);
                        }
                    },
                    else => {
                        // Array param (`U[]`) against an iterable-shaped arg
                        // (`Iterable<E>`, `Set<E>`, `Map<K,V>`): infer `U` from
                        // the iteration element, matching tsc's member-based
                        // `inferFromTypes` (Array's `[Symbol.iterator]` vs the
                        // source's). This lets a tuple contextual type thread
                        // from `new Map(...)`'s `Iterable<readonly [K, V]>`
                        // parameter through `.map`'s `U[]` return into the
                        // callback body, so the returned array literal is formed
                        // as a tuple instead of widening.
                        if (try c.iterationElementType(ra)) |elem| {
                            try c.unify(s.arrayElem(param), elem, tp_syms, candidates, depth + 1);
                        }
                    },
                }
            },
            .tuple => {
                const ra = try c.resolveStructural(arg);
                if (s.kind(ra) == .tuple) {
                    const n = @min(s.tupleLen(param), s.tupleLen(ra));
                    for (0..n) |i| {
                        try c.unify(s.tupleElem(param, @intCast(i)).ty, s.tupleElem(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                    }
                }
            },
            .union_type => {
                // Unify against the single type-param member if the rest
                // doesn't already accept the arg (common: T | undefined).
                var tp_member: TypeId = types.no_type;
                var n_tp: usize = 0;
                // `T | PromiseLike<T>` (the `.then` onfulfilled return shape):
                // a promise-typed arg should infer `T` from the *awaited* value,
                // not the whole promise — otherwise `p.then(async d => …)`
                // infers `Promise<Promise<X>>` (tsc uses `Awaited` here). This
                // pairs with type-parameter defaults: `then<R1 = T, …>` now
                // fills/threads `R1`, surfacing the promise-nesting that the
                // awaited unwrap corrects.
                var promise_of_tp = false;
                // Identify the single naked type-param member first so we can
                // tell whether a *wrapper* member (`ReadonlyArray<T>` in
                // `T | ReadonlyArray<T>`) already infers T — in which case the
                // naked fallback must stand down (tsc infers a naked union
                // member last, only when no other member supplied a candidate).
                for (try c.memberList(param)) |m| {
                    if (s.kind(m) == .type_param and tpIndex(tp_syms, s.typeParamSymbol(m)) != null) {
                        tp_member = m;
                        n_tp += 1;
                    }
                }
                const tp_idx: ?usize = if (tp_member != types.no_type) tpIndex(tp_syms, s.typeParamSymbol(tp_member)) else null;
                const before: TypeId = if (tp_idx) |ix| candidates[ix] else types.no_type;
                for (try c.memberList(param)) |m| {
                    if (m == tp_member) continue;
                    if (try c.containsTypeParam(m)) {
                        try c.unify(m, arg, tp_syms, candidates, depth + 1);
                    }
                }
                // A wrapper member contributed a candidate for the naked var.
                const wrapper_inferred = if (tp_idx) |ix| candidates[ix] != before else false;
                if (n_tp == 1) {
                    for (try c.memberList(param)) |m| {
                        if (m == tp_member) continue;
                        if (c.isPromiseLikeOf(m, s.typeParamSymbol(tp_member))) promise_of_tp = true;
                    }
                    var rest_ok = false;
                    for (try c.memberList(param)) |m| {
                        if (m == tp_member) continue;
                        if (try c.isAssignable(arg, m)) rest_ok = true;
                    }
                    if (promise_of_tp) {
                        const awaited = try c.awaitedType(arg);
                        if (awaited != arg) {
                            try c.unify(tp_member, awaited, tp_syms, candidates, depth + 1);
                        } else if (!rest_ok) {
                            try c.unify(tp_member, arg, tp_syms, candidates, depth + 1);
                        }
                    } else if (!wrapper_inferred) {
                        // Naked fallback: infer `T` from the arg. When the param's
                        // OTHER members are concrete (`T | undefined`) and the arg
                        // is a union sharing some of them, infer `T` from the
                        // REMAINDER (`X | undefined` → `T = X`), matching tsc's
                        // union inference (identical members pair off, `T` takes
                        // the rest). Without this, a reducer parameter
                        // `state: S[K] | undefined` would pollute the inferred
                        // element with a spurious `| undefined`. Falls back to the
                        // whole arg when nothing subtracts (and infers nothing
                        // when the whole arg is already covered — `rest_ok`), so
                        // the `T | ReadonlyArray<T>` (flatMap) path is unchanged.
                        var rem: std.ArrayList(TypeId) = .empty;
                        defer rem.deinit(c.scratch());
                        const arg_members: []const TypeId = if (s.kind(arg) == .union_type) try c.memberList(arg) else &.{arg};
                        for (arg_members) |am| {
                            var matched = false;
                            for (try c.memberList(param)) |m| {
                                if (m == tp_member) continue;
                                if (try c.containsTypeParam(m)) continue;
                                if (try c.isAssignable(am, m)) {
                                    matched = true;
                                    break;
                                }
                            }
                            if (!matched) try rem.append(c.scratch(), am);
                        }
                        if (rem.items.len > 0 and rem.items.len < arg_members.len) {
                            try c.unify(tp_member, try s.makeUnion(c.scratch(), rem.items), tp_syms, candidates, depth + 1);
                        } else if (!rest_ok) {
                            try c.unify(tp_member, arg, tp_syms, candidates, depth + 1);
                        }
                    }
                }
            },
            .object => {
                const ra = try c.resolveStructural(arg);
                if (s.kind(ra) == .object) {
                    // Same-origin fast path (tsc's `inferFromTypes` same-reference
                    // rule). A generic interface/alias parameter whose type args
                    // include the signature's fresh type params is materialized as
                    // an *expanded object* (instantiated at its own defaults via
                    // the higher-order-sig machinery), yet its origin tag still
                    // records the pre-default ref — e.g. `Control<TFieldValues,
                    // any, TTransformedValues>`. When the argument is an expansion
                    // of the SAME generic (`Control<Payload, …>`), walking the two
                    // objects prop-by-prop cannot invert `TFieldValues` through
                    // Control's deeply nested mapped/conditional members
                    // (`FieldErrors<T>`, `Subjects<T>`, …). Instead pair the origin
                    // type args positionally and infer from them — this is how
                    // `useWatch({ control, name })` recovers `TFieldValues` from
                    // the `control: Control<TFieldValues>` property. Identity-only:
                    // it fires solely when both origins are refs to the SAME
                    // symbol (a different generic falls through to the structural
                    // walk below). Mirrors the `.ref` arm's identity pairing.
                    if (c.origin.get(param)) |po| {
                        if (c.origin.get(ra)) |ao| {
                            if (s.kind(po) == .ref and s.kind(ao) == .ref and
                                s.refSymbol(po) == s.refSymbol(ao))
                            {
                                const pa = try c.scratch().dupe(TypeId, s.refArgs(po));
                                const aa = try c.scratch().dupe(TypeId, s.refArgs(ao));
                                const n = @min(pa.len, aa.len);
                                for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                                return;
                            }
                        }
                    }
                    for (0..s.objectPropCount(param)) |i| {
                        const pp = s.objectProp(param, @intCast(i));
                        if (s.objectPropByName(ra, pp.name)) |ap| {
                            try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                        }
                    }
                    const pidx = s.objectStringIndex(param);
                    if (pidx != 0) {
                        if (s.objectStringIndex(ra) != 0) {
                            try c.unify(pidx, s.objectStringIndex(ra), tp_syms, candidates, depth + 1);
                        } else {
                            // Reverse index-signature inference (tsc's
                            // `inferFromIndexTypes`): a target string index
                            // `{ [s: string]: T }` — the `Object.values`/`entries`
                            // parameter — infers `T` from a named-property source
                            // (`{ x: {...} }`) by matching each own property's type,
                            // since the source has no index signature to pair with.
                            // Without it `Object.values({x:{s:1}})` leaves `T`
                            // unbound and the result collapses to `unknown[]`.
                            for (0..s.objectPropCount(ra)) |i| {
                                const ap = s.objectProp(ra, @intCast(i));
                                try c.unify(pidx, ap.ty, tp_syms, candidates, depth + 1);
                            }
                        }
                    }
                    if (s.objectNumberIndex(param) != 0 and s.objectNumberIndex(ra) != 0) {
                        try c.unify(s.objectNumberIndex(param), s.objectNumberIndex(ra), tp_syms, candidates, depth + 1);
                    }
                    return;
                }
                // Array/tuple/string arg against an object-shaped param
                // (`ArrayLike<T>`, `Iterable<T>`, `{ length: number }`):
                // the param's number index matches the element type, and
                // its props resolve on the arg via `propOfType` (which
                // covers the element-instantiated `Array<T>`/primitive
                // interface members, e.g. `[Symbol.iterator]`). Fixes
                // `Array.from(xs)` inferring `unknown[]` from an array.
                const elem: TypeId = switch (s.kind(ra)) {
                    .array => s.arrayElem(ra),
                    .tuple => try c.tupleElementUnion(ra),
                    .string, .string_literal => types.string_type,
                    else => return,
                };
                if (s.objectNumberIndex(param) != 0) {
                    // Array-like param (`Array<T>`/`ReadonlyArray<T>`/`ArrayLike<T>`):
                    // the element type is fully determined by the number index.
                    // Scraping the methods too would pull `T` from partial
                    // shapes like `at(i): T | undefined` / `find(): T | undefined`,
                    // polluting the inference with a spurious `| undefined`
                    // (and, for `flatMap`'s `U | ReadonlyArray<U>`, corrupting U).
                    try c.unify(s.objectNumberIndex(param), elem, tp_syms, candidates, depth + 1);
                } else {
                    // No number index (`Iterable<T>`): the element flows only
                    // through members like `[Symbol.iterator](): Iterator<T>`,
                    // so resolve `T` by matching those props on the arg.
                    for (0..s.objectPropCount(param)) |i| {
                        const pp = s.objectProp(param, @intCast(i));
                        if (try c.propOfType(ra, pp.name)) |ap| {
                            try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                        }
                    }
                }
            },
            .function => {
                var ra = try c.resolveStructural(arg);
                // A callable intersection (`Reducer<S> & { … }` — RTK's
                // `ReducerWithInitialState`): infer against its function
                // constituent. Without this a reducer passed as a slice value
                // would infer nothing (the reverse-mapped element stalls at
                // `unknown`).
                if (s.kind(ra) == .intersection) {
                    for (try c.memberList(ra)) |m| {
                        const rm = try c.resolveStructural(m);
                        if (s.kind(rm) == .function) {
                            ra = rm;
                            break;
                        }
                    }
                }
                // A callable OBJECT argument (an interface carrying call
                // signatures rather than a bare function — e.g. `Number`, whose
                // `NumberConstructor` has `(value?: any): number`, passed as
                // `arr.map(Number)`) stands in for a function. Sibling of the
                // inferFromExtends `.function` arm (da9cc33): tsc's
                // inferFromSignatures aligns source/target sigs from the END, so
                // a single-signature function param infers from the source's
                // LAST call signature (the overload picked for the most-general
                // shape). Extract it and fall through to the function inference.
                if (s.kind(ra) == .object) {
                    const ncall = s.objectCallSigCount(ra);
                    if (ncall == 0) return;
                    ra = s.objectCallSig(ra, ncall - 1);
                }
                if (s.kind(ra) != .function) return;
                // A *generic function value* passed where a function is
                // expected (`.then(getProjectTransform)`): first instantiate
                // its own type params from the expected parameter types
                // (tsc's contextual signature instantiation), so its return
                // contributes `ProjectResponse`, not a foreign free `T`.
                const own = s.fnTypeParams(ra);
                if (own.len > 0) {
                    const own_syms = try c.scratch().dupe(u32, own);
                    const own_cands = try c.scratch().alloc(TypeId, own.len);
                    for (own_cands) |*v| v.* = types.no_type;
                    const np = @min(s.fnParamCount(param), s.fnParamCount(ra));
                    for (0..np) |i| {
                        // Reversed roles: the arg's param types are the pattern,
                        // the expected param types the source.
                        try c.unify(s.fnParam(ra, @intCast(i)).ty, s.fnParam(param, @intCast(i)).ty, own_syms, own_cands, depth + 1);
                    }
                    var map_list: std.ArrayList(TpMap) = .empty;
                    defer map_list.deinit(c.scratch());
                    var all_unbound = true;
                    for (own_syms, own_cands) |sym, cand| {
                        if (cand != types.no_type) all_unbound = false;
                        const v = if (cand != types.no_type) cand else try c.typeParamFallback(sym);
                        try map_list.append(c.scratch(), .{ .sym = sym, .ty = v });
                    }
                    // Only substitute when something was actually inferred —
                    // an unbound-everything map would erase params to their
                    // fallbacks and *lose* inference the caller could still do.
                    if (!all_unbound) {
                        ra = try c.instantiate(ra, map_list.items);
                        if (s.kind(ra) != .function) return;
                    }
                }
                const n = @min(s.fnParamCount(param), s.fnParamCount(ra));
                for (0..n) |i| {
                    try c.unify(s.fnParam(param, @intCast(i)).ty, s.fnParam(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
                try c.unify(s.fnReturn(param), s.fnReturn(ra), tp_syms, candidates, depth + 1);
                // Infer type params from the *predicate guard* too:
                // `filter<S extends T>(p: (x: T) => x is S)` gets `S` from an
                // argument `(x): x is number`. Only plain guards (not
                // `asserts`) with concrete guard types on both sides.
                if (s.fnHasPredicate(param) and s.fnHasPredicate(ra)) {
                    const pp = s.fnPredicate(param);
                    const ap = s.fnPredicate(ra);
                    if (!pp.asserts and !ap.asserts and pp.ty != 0 and ap.ty != 0)
                        try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                }
            },
            .ref => {
                const ra = try c.resolveStructural(arg);
                if (s.kind(arg) == .ref and s.refSymbol(arg) == s.refSymbol(param)) {
                    const pa = try c.scratch().dupe(TypeId, s.refArgs(param));
                    const aa = try c.scratch().dupe(TypeId, s.refArgs(arg));
                    const n = @min(pa.len, aa.len);
                    for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                    return;
                }
                // A union argument paired against a named-type param: match the
                // union member sharing the param's symbol and infer from *that*
                // member's type args (tsc's `inferFromTypes` pairs union members
                // by identity before falling back to structural inference).
                // Crux of `Array.from(map.values())` element recovery: the
                // iterator's `next(): IteratorResult<T, TReturn>` return is the
                // union alias `IteratorYieldResult<T> | IteratorReturnResult<
                // TReturn>`; without identity pairing, unifying `IteratorYield
                // Result<T>` against that union falls to the structural arm
                // (object-vs-union) and binds nothing, collapsing the element
                // to `unknown`.
                const uni: TypeId = if (s.kind(arg) == .union_type) arg else if (s.kind(ra) == .union_type) ra else 0;
                if (uni != 0) {
                    var matched = false;
                    for (try c.memberList(uni)) |am| {
                        if (s.kind(am) == .ref and s.refSymbol(am) == s.refSymbol(param)) {
                            try c.unify(param, am, tp_syms, candidates, depth + 1);
                            matched = true;
                        }
                    }
                    if (matched) return;
                }
                try c.unify(try c.resolveStructural(param), ra, tp_syms, candidates, depth + 1);
            },
            .conditional => {
                // A generic conditional target (`ReducersMapObject<S> = keyof P
                // extends keyof S ? { [K in keyof S]: … } : never`) carries its
                // inference positions in the branches. tsc's `inferFromTypes`
                // recurses into both; the `: never` false branch contributes
                // nothing, while the true branch reaches the reverse-mapped
                // inference below. This is how `configureStore({ reducer: {…} })`
                // recovers `S` from the object-literal reducer map.
                try c.unify(s.condTrue(param), arg, tp_syms, candidates, depth + 1);
                try c.unify(s.condFalse(param), arg, tp_syms, candidates, depth + 1);
            },
            .mapped => try c.inferReverseMapped(param, arg, tp_syms, candidates, depth),
            else => {},
        }
    }

    /// Reverse-mapped-type inference (tsc's `inferReverseMappedType`): infer the
    /// source `S` of a HOMOMORPHIC mapped target `{ [K in keyof S]: F<S[K]> }`
    /// from an object-literal argument. For each source property `k`, infer the
    /// element `S[k]` by matching the argument's `k`-typed property against the
    /// value template with `S[K]` replaced by a fresh element variable, then
    /// reassemble `S` as `{ k: inferred, … }`. Deliberately conservative — bails
    /// (leaving prior behavior) on any non-vanilla shape (`as`-clause rename,
    /// non-`keyof` constraint, a source that isn't a bare inference-target type
    /// param, a non-object argument) so it can only ADD inferences where the
    /// param would otherwise stay unbound.
    fn inferReverseMapped(c: *Checker, m: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
        const s = &c.ts;
        if (!s.mappedHomomorphic(m)) return; // only `[K in keyof S]`
        if (s.mappedAs(m) != 0) return; // no key remap
        const src = s.mappedSource(m);
        if (s.kind(src) != .type_param) return; // source must be a bare param
        const src_sym = s.typeParamSymbol(src);
        const idx = tpIndex(tp_syms, src_sym) orelse return; // …that we're inferring
        const ra = try c.resolveStructural(arg);
        if (s.kind(ra) != .object) return;
        const key_param = s.mappedKeyParam(m);
        const key_id = s.mappedParamId(key_param);
        const value = s.mappedValue(m);
        // Element inference variable standing in for `S[K]` throughout the value
        // template. A single fresh var suffices — the template is the same for
        // every key, only the matched argument property differs.
        const fp_sym = try c.mintReverseElemVar(s.mappedParamName(key_param));
        const fp_ty = try s.makeTypeParam(fp_sym);
        const template = try c.substElemAccess(value, src_sym, key_id, fp_ty, 0);
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        const local_syms = [_]u32{fp_sym};
        for (0..s.objectPropCount(ra)) |i| {
            const p = s.objectProp(ra, @intCast(i));
            var elem = [_]TypeId{types.no_type};
            try c.unify(template, p.ty, &local_syms, &elem, depth + 1);
            // The inferred element is `S[k]`, which can never legitimately BE
            // `S` itself. A bare `S` appearing in the candidate is a
            // contextual-feedback artifact (the object literal was
            // contextually typed with a partially-resolved `S`, injecting it
            // into the reducer's `state:` parameter); strip it so the inferred
            // state is the reducer's own state, not a self-referential union.
            const et = try c.stripSourceParam(if (elem[0] != types.no_type) elem[0] else types.unknown_type, src_sym);
            try props.append(c.scratch(), .{ .name = p.name, .ty = et, .flags = 0 });
        }
        if (props.items.len == 0) return;
        const obj = try c.objectFromProps(props.items, 0, 0);
        // The reverse-mapped object is the authoritative inference for a
        // homomorphic mapped target; it wins over an uninformative `any` that a
        // sibling union member (`Reducer<S, A, P>`) may have bound first. Union
        // only with another genuine candidate.
        candidates[idx] = if (candidates[idx] == types.no_type or candidates[idx] == types.any_type)
            obj
        else
            try c.makeUnion2(candidates[idx], obj);
    }

    /// Drop bare `type_param` members from a reverse-mapped element inference.
    /// The element is `S[k]` — the reducer's concrete state — so any free type
    /// param surviving in it is a contextual-feedback artifact (the object
    /// literal was contextually typed with a still-unresolved param, injecting
    /// it into the reducer's `state:`/`PreloadedState` position). A union sheds
    /// those members; a type that IS exactly a bare param degrades to `unknown`.
    fn stripSourceParam(c: *Checker, t: TypeId, sym: u32) Error!TypeId {
        _ = sym;
        const s = &c.ts;
        if (s.kind(t) == .type_param) return types.unknown_type;
        if (s.kind(t) != .union_type) return t;
        var kept: std.ArrayList(TypeId) = .empty;
        defer kept.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            if (s.kind(m) == .type_param) continue;
            try kept.append(c.scratch(), m);
        }
        if (kept.items.len == 0) return types.unknown_type;
        return s.makeUnion(c.scratch(), kept.items);
    }

    /// Mint a throwaway element inference variable for `inferReverseMapped`.
    /// Reuses the fresh higher-order type-param id pool (ids `>= fresh_tp_base`)
    /// so `makeTypeParam` accepts it and name/constraint lookups stay in bounds;
    /// the var never escapes into a result (only the concrete inferred element
    /// does), so it needs no constraint.
    fn mintReverseElemVar(c: *Checker, name: Atom) Error!u32 {
        const id = c.fresh_tp_next;
        c.fresh_tp_next += 1;
        try c.fresh_tp_info.append(c.ca(), .{ .name = name, .constraint = types.no_type, .default = types.no_type, .has_default = false });
        return id;
    }

    /// Replace every `S[K]` (an index access whose object is the type param
    /// `src_sym` and whose index is this map's key param `key_id`) with `fp`.
    /// A homomorphic mapped value references its source only through `S[K]`, so
    /// this yields the per-element template `F<fp>`.
    fn substElemAccess(c: *Checker, t: TypeId, src_sym: u32, key_id: u32, fp: TypeId, depth: u32) Error!TypeId {
        if (depth > 16) return t;
        const s = &c.ts;
        switch (s.kind(t)) {
            .index_access => {
                const obj = s.indexAccessObj(t);
                const ix = s.indexAccessIndex(t);
                if (s.kind(obj) == .type_param and s.typeParamSymbol(obj) == src_sym and
                    s.kind(ix) == .mapped_param and s.mappedParamId(ix) == key_id)
                {
                    return fp;
                }
                return s.makeIndexAccess(try c.substElemAccess(obj, src_sym, key_id, fp, depth + 1), try c.substElemAccess(ix, src_sym, key_id, fp, depth + 1));
            },
            .array => return s.makeArray(try c.substElemAccess(s.arrayElem(t), src_sym, key_id, fp, depth + 1)),
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |mm| try parts.append(c.scratch(), try c.substElemAccess(mm, src_sym, key_id, fp, depth + 1));
                return s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |mm| try parts.append(c.scratch(), try c.substElemAccess(mm, src_sym, key_id, fp, depth + 1));
                return s.makeIntersection(c.scratch(), parts.items);
            },
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.substElemAccess(e.ty, src_sym, key_id, fp, depth + 1), .flags = e.flags });
                }
                return s.makeTuple(elems.items);
            },
            .object => {
                var oprops: std.ArrayList(types.Prop) = .empty;
                defer oprops.deinit(c.scratch());
                for (0..s.objectPropCount(t)) |i| {
                    const p = s.objectProp(t, @intCast(i));
                    try oprops.append(c.scratch(), .{ .name = p.name, .ty = try c.substElemAccess(p.ty, src_sym, key_id, fp, depth + 1), .flags = p.flags });
                }
                return s.makeObject(oprops.items, 0, 0, 0);
            },
            .function => {
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substElemAccess(p.ty, src_sym, key_id, fp, depth + 1), .flags = p.flags });
                }
                const ret = try c.substElemAccess(s.fnReturn(t), src_sym, key_id, fp, depth + 1);
                return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, s.fnThisType(t));
            },
            .ref => {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substElemAccess(a, src_sym, key_id, fp, depth + 1));
                return s.makeRef(s.refSymbol(t), args.items);
            },
            .conditional => {
                const chk = try c.substElemAccess(s.condCheck(t), src_sym, key_id, fp, depth + 1);
                const ext = try c.substElemAccess(s.condExtends(t), src_sym, key_id, fp, depth + 1);
                const tru = try c.substElemAccess(s.condTrue(t), src_sym, key_id, fp, depth + 1);
                const fls = try c.substElemAccess(s.condFalse(t), src_sym, key_id, fp, depth + 1);
                return s.makeConditional(chk, ext, tru, fls, s.condDistributive(t));
            },
            else => return t,
        }
    }

    /// Bind `any` to every in-scope type param mentioned in `pattern` (tsc:
    /// inference from an `any` source assigns `any` to all inference
    /// positions). Structure mirrors `containsTypeParamInner`; depth-capped
    /// like `unify` (recursive refs terminate on the cap; re-binding is
    /// idempotent since `any | any` folds).
    fn bindAnyToTypeParams(c: *Checker, pattern: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
        if (depth > 16) return;
        const s = &c.ts;
        switch (s.kind(pattern)) {
            .type_param => {
                if (tpIndex(tp_syms, s.typeParamSymbol(pattern))) |i| {
                    candidates[i] = if (candidates[i] == types.no_type)
                        types.any_type
                    else
                        try c.makeUnion2(candidates[i], types.any_type);
                }
            },
            .union_type, .intersection, .overloads => {
                for (try c.memberList(pattern)) |m| try c.bindAnyToTypeParams(m, tp_syms, candidates, depth + 1);
            },
            .array => try c.bindAnyToTypeParams(s.arrayElem(pattern), tp_syms, candidates, depth + 1),
            .tuple => {
                for (0..s.tupleLen(pattern)) |i| {
                    try c.bindAnyToTypeParams(s.tupleElem(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
            },
            .object => {
                for (0..s.objectPropCount(pattern)) |i| {
                    try c.bindAnyToTypeParams(s.objectProp(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
                if (s.objectStringIndex(pattern) != 0) try c.bindAnyToTypeParams(s.objectStringIndex(pattern), tp_syms, candidates, depth + 1);
                if (s.objectNumberIndex(pattern) != 0) try c.bindAnyToTypeParams(s.objectNumberIndex(pattern), tp_syms, candidates, depth + 1);
            },
            .function => {
                for (0..s.fnParamCount(pattern)) |i| {
                    try c.bindAnyToTypeParams(s.fnParam(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
                try c.bindAnyToTypeParams(s.fnReturn(pattern), tp_syms, candidates, depth + 1);
            },
            .ref => {
                for (s.refArgs(pattern)) |a| try c.bindAnyToTypeParams(a, tp_syms, candidates, depth + 1);
            },
            else => {},
        }
    }

    /// Would every argument check against `sig`? (Silent, for overload
    /// selection.)
    fn argumentsMatch(c: *Checker, sig: TypeId, arg_nodes: []const Node) Error!bool {
        // Overload probing: contextually type each argument by this candidate's
        // parameter and test assignability. Checking a context-sensitive
        // argument (an arrow/function body) under a *rejected* candidate's
        // parameter can emit spurious diagnostics — e.g. `arr.reduce((sum, x) =>
        // sum + x.weight_kg, 0)` probes the non-generic `reduce(cb: (T, T) => T,
        // init: T)` overload before the generic `reduce<U>(…, init: U)`; that
        // overload types `sum` as the element `T` (an object), so the body's `+`
        // reports TS2365 — then the overload is rejected on `0` (not a `T`) and
        // the generic overload wins with `sum: number`. Roll the diagnostic list
        // back on every rejecting return so only the ACCEPTED candidate's
        // argument diagnostics survive (emitted once here; `checkCallArguments`
        // then cache-hits the same (node, ctx) check without duplicating them).
        const saved_diags = c.diags.items.len;
        var ai: u32 = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            if (c.nodeTag(an) == .spread_element) return true; // don't reject on spreads
            const pt = c.paramTypeAt(sig, ai) orelse {
                c.diags.items.len = saved_diags;
                return false;
            };
            const tag = c.nodeTag(an);
            // Array literals are contextually typed by the (already-inferred)
            // parameter, so a tuple parameter sees a tuple — otherwise the
            // `Promise.all` tuple overload's `values: [A, B]` would be tested
            // against a widened `(A | B)[]` and spuriously rejected. Object
            // literals likewise: without the contextual parameter a fresh
            // `{ month: 'short' }` widens its string-literal properties to
            // `string`, so an overload whose options type has literal-union
            // members (`Intl.DateTimeFormat`'s `month?: "short" | …`) is
            // spuriously rejected — the single-signature path already types
            // args by `pt`, so overload probing must match it. A nested generic
            // *call* argument is contextually typed too: `new Map(rows.map(r =>
            // [r.id, r.n]))` needs the constructor's `Iterable<readonly [K,V]>`
            // parameter to thread into `.map`'s callback so the returned array
            // literal forms a tuple — without the context the callback widens
            // to `(string|number)[]` and every Map overload is rejected.
            const ctx_typed = switch (tag) {
                .arrow_fn, .function_expr, .array_literal, .object_literal, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => true,
                else => false,
            };
            const at = if (ctx_typed)
                try c.checkExprCached(an, pt)
            else
                try c.checkExprCached(an, types.no_type);
            if (!try c.isAssignable(at, pt)) {
                c.diags.items.len = saved_diags;
                return false;
            }
        }
        return true;
    }

    fn checkCallArguments(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool) Error!void {
        const nargs = countArgs(arg_nodes);
        const required = try c.requiredParams(sig);
        const total = c.paramTotal(sig);
        var has_spread = false;
        for (arg_nodes) |an| {
            if (an != null_node and c.nodeTag(an) == .spread_element) has_spread = true;
        }
        if (report and !has_spread) {
            if (nargs < required) {
                if (total == std.math.maxInt(u32)) {
                    try c.diagFmt(2555, c.nodeSpan(node), "Expected at least {d} arguments, but got {d}.", .{ required, nargs });
                } else if (required != total) {
                    try c.diagFmt(2554, c.nodeSpan(node), "Expected {d}-{d} arguments, but got {d}.", .{ required, total, nargs });
                } else {
                    try c.diagFmt(2554, c.nodeSpan(node), "Expected {d} arguments, but got {d}.", .{ required, nargs });
                }
            } else if (nargs > total) {
                if (required != total) {
                    try c.diagFmt(2554, c.nodeSpan(node), "Expected {d}-{d} arguments, but got {d}.", .{ required, total, nargs });
                } else {
                    try c.diagFmt(2554, c.nodeSpan(node), "Expected {d} arguments, but got {d}.", .{ total, nargs });
                }
            }
        }
        const first_error_only = c.infer_fell_back;
        var reported_arg = false;
        var ai: u32 = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            if (c.nodeTag(an) == .spread_element) {
                _ = try c.checkExprCached(an, types.no_type);
                continue;
            }
            const pt = c.paramTypeAt(sig, ai) orelse {
                _ = try c.checkExprCached(an, types.no_type);
                continue;
            };
            const at = try c.checkExprCached(an, pt);
            if (report and !try c.isAssignable(at, pt)) {
                if (first_error_only and reported_arg) continue;
                if (!try c.elaborateCallbackError(an, at, pt) and
                    !try c.elaborateLiteralError(an, at, pt))
                {
                    try c.reportNotAssignable(2345, at, pt, c.nodeSpan(an));
                }
                reported_arg = true;
            } else if (report) {
                try c.excessPropertyCheck(an, at, pt);
            }
        }
    }

    // =====================================================================
    // control-flow narrowing
    // =====================================================================

    /// Maximum tracked reference-path depth. tsc caps reference narrowing;
    /// ztsc's live need tops out at depth-2 (`a.b.c`). Paths deeper than this
    /// are not tracked (sound under-narrowing = pre-depth-N behavior).
    const max_ref_depth = 3;

    /// One link in a reference path: either a dotted member (`.p`, property
    /// atom in `atom`) or a constant element access (`[i]`, index in `index`).
    /// Only *constant* integer indices are trackable — a variable index
    /// (`arr[i]`) is not a stable reference, so `buildRefKey` rejects it. The
    /// unused field is always 0 so two `PathElem`s hash/compare canonically as
    /// part of an `AutoHashMap` key.
    const PathElem = struct {
        is_index: bool = false,
        atom: Atom = 0,
        index: u32 = 0,
    };

    /// A narrowable reference: a bare identifier (`len == 0`) or a member
    /// path `sym.path[0].path[1]…` capped at `max_ref_depth`. `path[0]` is the
    /// innermost link (closest to the root), `path[len-1]` the outermost. Each
    /// link is a dotted member (`.p`) or a constant element access (`[i]`), so
    /// `data.Legend[0].rules` is a depth-3 reference (`Legend`, `[0]`, `rules`).
    /// A `this`-rooted path uses the sentinel root `this_flow_root` (flow
    /// graphs are per-function, so the sentinel never crosses a `this`-rebind
    /// boundary). Trailing `path` slots past `len` are always default so the
    /// struct hashes/compares canonically as an `AutoHashMap` key.
    const RefKey = struct {
        sym: SymbolId,
        path: [max_ref_depth]PathElem = [_]PathElem{.{}} ** max_ref_depth,
        len: u8 = 0,
    };

    /// Sentinel `RefKey.sym` for `this`-rooted property paths.
    const this_flow_root: SymbolId = std.math.maxInt(SymbolId);

    const FlowQ = struct { file: FileId, flow: FlowId, key: u32, declared: TypeId };
    const SymLoop = struct { sym: SymbolId, scope: ScopeId };

    fn refKeyIndex(c: *Checker, key: RefKey) Error!u32 {
        const gop = try c.ref_keys.getOrPut(c.ca(), key);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(c.ref_keys.count());
        return gop.value_ptr.*;
    }

    /// A constant, non-negative integer element-access index (`arr[0]`), else
    /// null. A variable/expression index (`arr[i]`) is not a stable reference,
    /// so it is untracked (sound under-narrowing). The 4096 bound matches the
    /// tuple-index ceiling used by `indexChainInner`.
    fn constIndexOf(c: *Checker, rhs: Node) ?u32 {
        var n = rhs;
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        if (c.nodeTag(n) != .number_literal) return null;
        const v = c.numberTokenValue(c.tree.nodeMainToken(n));
        if (v < 0 or v != @floor(v) or v >= 4096) return null;
        return @intFromFloat(v);
    }

    /// Build the tracked reference key for a member/element-access node by
    /// peeling its spine right-to-left, collecting dotted-member atoms and
    /// constant element indices, until it bottoms out at a bare identifier
    /// (resolved to a value symbol) or `this`. Returns null when the root is
    /// neither (call result, non-constant index, etc.) or the path is deeper
    /// than `max_ref_depth` (untracked = sound under-narrowing).
    fn buildRefKey(c: *Checker, node: Node) Error!?RefKey {
        var elems: [max_ref_depth]PathElem = [_]PathElem{.{}} ** max_ref_depth;
        var count: usize = 0;
        var n = node;
        while (true) {
            while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
            const tag = c.nodeTag(n);
            const d = c.tree.nodeData(n);
            if (tag == .member_expr or tag == .optional_member_expr) {
                if (count >= max_ref_depth) return null; // too deep: not tracked
                elems[count] = .{ .atom = try c.memberAtom(d.rhs) };
            } else if (tag == .index_expr or tag == .optional_index_expr) {
                const iv = c.constIndexOf(d.rhs) orelse return null; // variable index: untracked
                if (count >= max_ref_depth) return null;
                elems[count] = .{ .is_index = true, .index = iv };
            } else break;
            count += 1;
            n = d.lhs;
        }
        // `n` is the root. A bare identifier must resolve to a value symbol
        // (skip the `undefined` keyword, which is not a reference); `this`
        // uses the sentinel root.
        var key: RefKey = .{ .sym = 0, .len = @intCast(count) };
        if (c.nodeTag(n) == .identifier) {
            const base_tok = c.tree.nodeMainToken(n);
            if (c.tree.tokens.tag(base_tok) == .keyword_undefined) return null;
            const a = try c.atomOfToken(base_tok);
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| key.sym = sym,
                else => return null,
            }
        } else if (c.nodeTag(n) == .this_expr) {
            key.sym = this_flow_root;
        } else return null;
        // Links were collected outermost-first; reverse so `path[0]` is the
        // innermost link (closest to the root).
        var i: usize = 0;
        while (i < count) : (i += 1) key.path[i] = elems[count - 1 - i];
        return key;
    }

    /// Does `node` denote exactly this reference? Peels the member/element
    /// spine right-to-left, matching each link against the key's path
    /// (outermost = `path[len-1]`), and bottoms out at the root identifier /
    /// `this`.
    fn refMatches(c: *Checker, node: Node, key: RefKey) Error!bool {
        if (node == null_node) return false;
        var n = node;
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        if (key.len == 0) return c.identIsSym(n, key.sym);
        var i: usize = key.len;
        while (i > 0) : (i -= 1) {
            while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
            const tag = c.nodeTag(n);
            const d = c.tree.nodeData(n);
            const pe = key.path[i - 1];
            if (pe.is_index) {
                if (tag != .index_expr and tag != .optional_index_expr) return false;
                const iv = c.constIndexOf(d.rhs) orelse return false;
                if (iv != pe.index) return false;
            } else {
                if (tag != .member_expr and tag != .optional_member_expr) return false;
                if ((try c.memberAtom(d.rhs)) != pe.atom) return false;
            }
            n = d.lhs;
        }
        return c.identIsSym(n, key.sym);
    }

    /// Is `target` a proper prefix of the tracked reference `key`? Writing any
    /// prefix (the root, or `root.path[0..k]` for `k < len`) invalidates the
    /// whole subtree's narrowing.
    fn refPrefixWritten(c: *Checker, target: Node, key: RefKey) Error!bool {
        if (key.len == 0) return false;
        var k: u8 = 0;
        while (k < key.len) : (k += 1) {
            var pk: RefKey = .{ .sym = key.sym, .len = k };
            var j: usize = 0;
            while (j < k) : (j += 1) pk.path[j] = key.path[j];
            if (try c.refMatches(target, pk)) return true;
        }
        return false;
    }

    /// Is narrowing worth running for this declared type?
    fn isNarrowable(c: *Checker, declared: TypeId) bool {
        return switch (c.ts.kind(declared)) {
            .any, .err, .never, .void, .none => false,
            else => true,
        };
    }

    fn flowTypeOfReference(c: *Checker, node: Node, sym: SymbolId, declared: TypeId) Error!TypeId {
        if (!c.isNarrowable(declared)) return declared;
        const flow = c.bind.flowAt(node) orelse return declared;
        c.stats.flow_queries += 1;
        return c.flowType(flow, .{ .sym = sym }, declared, 0);
    }

    fn flowTypeOfKey(c: *Checker, node: Node, key: RefKey, declared: TypeId) Error!TypeId {
        if (!c.isNarrowable(declared)) return declared;
        const flow = c.bind.flowAt(node) orelse return declared;
        c.stats.flow_queries += 1;
        return c.flowType(flow, key, declared, 0);
    }

    fn flowType(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
        if (flow == binder.no_flow) return declared;
        if (flow == binder.unreachable_flow) return types.never_type;
        if (depth > 4000) return declared; // pathological chains: stay sound
        const q: FlowQ = .{ .file = c.cur_file, .flow = flow, .key = try c.refKeyIndex(key), .declared = declared };
        if (c.flow_cache.get(q)) |t| {
            if (t == types.no_type) return declared; // in progress (loop)
            return t;
        }
        try c.flow_cache.put(c.ca(), q, types.no_type);
        const result = try c.flowTypeInner(flow, key, declared, depth);
        try c.flow_cache.put(c.ca(), q, result);
        return result;
    }

    fn flowTypeInner(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
        const b = c.bind;
        switch (b.flow_tags[flow]) {
            .none => return declared,
            .start => {
                // A function/arrow body's start records its definition-point
                // flow as the antecedent. For a constant bare-identifier
                // reference captured by this closure, continue analysis in the
                // enclosing function so its narrowing is preserved (tsc narrows
                // `const`/effectively-const references across closures, but not
                // property paths, `this`, or reassignable variables). Namespace
                // and file starts have `no_flow` here and stop at `declared`.
                const ante = b.flow_a[flow];
                if (ante == binder.no_flow) return declared;
                // A closure whose textual definition point is unreachable (e.g. a
                // hoisted `function` declared after a `return`) can still be
                // invoked — its body runs in a fresh reachable context. Crossing
                // into the unreachable definition-point flow would yield `never`
                // for a captured reference, which then makes a property *write*
                // target (`ref.current = x`) spuriously collapse to `never` (a
                // read to `never` is silently accepted, so only writes surface it).
                // Use the declared type instead: there is no valid narrowing at an
                // unreachable definition point.
                if (ante == binder.unreachable_flow) return declared;
                if (key.len != 0 or key.sym == this_flow_root) return declared;
                const sf = c.symFlags(key.sym);
                if (!sf.const_decl) {
                    // Effectively-const let/var/param: tsc narrows a captured
                    // reference across a closure like a `const` when the variable
                    // is a mutable *local* that is never reassigned (matching
                    // tsc's `isParameterOrMutableLocalVariable` + the
                    // function-expression/arrow container walk in
                    // `checkIdentifier`). Excluded, so the declared type stands:
                    //   • non let/var/param/catch symbols,
                    //   • module/global top-level or exported variables — a
                    //     top-level `let` may be reassigned by any function, so
                    //     tsc never trusts the narrowing across a closure (a
                    //     top-level `const` still does, via the const path above),
                    //   • the crossed closure being a *function declaration*
                    //     (only function-expression/arrow/method containers extend
                    //     the flow — a hoisted `function` captures at its
                    //     definition point, before any guard),
                    //   • reassignment anywhere (conservative vs tsc's
                    //     position-based `lastAssignmentPos`; only ever
                    //     under-narrows, never a new false positive).
                    if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return declared;
                    if (sf.exported) return declared;
                    if (c.symFile(key.sym) != c.cur_file) return declared;
                    const decl_scope = c.bind.symbol_scopes[c.localOf(key.sym)];
                    if (c.bind.scope_kinds[c.containerOf(decl_scope)] != .function) return declared;
                    switch (c.nodeTag(b.flowNode(flow))) {
                        .arrow_fn, .function_expr, .object_method, .class_method => {},
                        else => return declared, // function declaration etc.
                    }
                    try c.ensureReassignScan();
                    if (c.reassigned_syms.contains(key.sym)) return declared;
                }
                return c.flowType(ante, key, declared, depth + 1);
            },
            .unreachable_ => return types.never_type,
            .assign => {
                const target = b.flowNode(flow);
                const ante = b.flow_a[flow];
                // Re-evaluating the initializer/rhs resolves names in the scope
                // where the assignment lives, not the reference's query scope.
                {
                    const saved = c.cur_scope;
                    defer c.cur_scope = saved;
                    c.cur_scope = b.flowScope(flow);
                    if (try c.assignNarrows(target, key, declared)) |narrowed| {
                        return narrowed;
                    }
                }
                return c.flowType(ante, key, declared, depth + 1);
            },
            .cond_true, .cond_false => {
                const cond = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                const sense = b.flow_tags[flow] == .cond_true;
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                c.cur_scope = b.flowScope(flow);
                return c.narrowByCondition(before, cond, sense, key);
            },
            .switch_clause => {
                const clause = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                c.cur_scope = b.flowScope(flow);
                return c.narrowBySwitchClause(before, clause, key);
            },
            .call_stmt => {
                const call = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                // The assertion callee is re-checked here; resolve it in the
                // scope where the call statement lives (it may be reached via a
                // loop back-edge from a shallower query scope).
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                c.cur_scope = b.flowScope(flow);
                return c.narrowByAssertCall(before, call, key);
            },
            .branch_label, .loop_label => {
                const antes = b.flowAntecedents(flow);
                // A loop label whose reference is *never assigned inside the
                // loop* keeps its pre-loop narrowing across the whole loop body
                // (tsc `getTypeAtFlowLoopLabel`: a reference only re-widens at a
                // back edge when the loop actually assigns it). The binder builds
                // a loop label with antecedent[0] = the pre-loop entry edge and
                // [1..] = back edges / `continue` jumps. For an unassigned simple
                // reference the type is invariant around the loop, so its type at
                // the label is exactly the entry type — take antecedent[0] alone
                // and skip the back edges. This both preserves the narrowing
                // (ztsc previously widened to `declared` at the in-progress back
                // edge, dropping every loop-crossing narrowing — `x: T | null`
                // guarded by an early return re-acquired `| null` inside a
                // following `for`/`while`) and avoids poisoning the flow cache
                // with an under-approximation while the label is in progress.
                // "Assigned inside this loop" is exact for `for/for..of/for..in`
                // (see `reassigned_in_loop` below) and a sound over-approximation
                // (file-level `reassigned_syms`) for `while`/`do`.
                // Loop-header bindings (a `for..of` element is not in the
                // reassignment scan yet is re-bound every iteration) and property
                // paths keep the full union-over-all-antecedents behavior.
                //
                // The shortcut fires *only when the pre-loop entry is actually
                // narrower than the declared type* — i.e. there is a narrowing to
                // preserve. When the entry equals `declared` the reference is
                // un-narrowed and the ordinary union path (which re-walks the back
                // edges and, in doing so, populates the flow cache exactly as
                // before) reproduces the pre-fix result byte-for-byte. This keeps
                // the change surgical: it can only ever *retain* a narrowing that
                // the old code dropped, never perturb the cache interaction of a
                // reference that was never narrowed before the loop (which would
                // otherwise unmask unrelated latent FPs downstream).
                if (b.flow_tags[flow] == .loop_label and antes.len >= 1 and key.len == 0 and
                    !c.symDeclaredInForHead(key.sym))
                {
                    try c.ensureReassignScan();
                    // "Assigned inside *this* loop" is the exact tsc predicate. A
                    // `for`/`for..of`/`for..in` label's own scope is the loop's
                    // `.for_head`, so a symbol assigned before the loop but never
                    // inside it (`let x; …; x = f(); if(!x) return; for(…) use(x)`)
                    // keeps its narrowing. `while`/`do` push no header scope, so
                    // there the coarse file-level "reassigned anywhere" test is
                    // used (sound: an assignment inside the loop always lands in
                    // the file scan → never keeps a mutated narrowing).
                    const loop_scope = b.flowScope(flow);
                    const assigned_in_loop = if (b.scope_kinds[loop_scope] == .for_head)
                        c.reassigned_in_loop.contains(.{ .sym = key.sym, .scope = loop_scope })
                    else
                        c.reassigned_syms.contains(key.sym);
                    if (!assigned_in_loop) {
                        const entry_t = try c.flowType(antes[0], key, declared, depth + 1);
                        if (entry_t != declared) return entry_t;
                    }
                }
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (antes) |a| {
                    const t = try c.flowType(a, key, declared, depth + 1);
                    // In-progress loop back-edges return `declared`
                    // (tsc: start from declared type at back edges).
                    if (t != types.never_type) try parts.append(c.scratch(), t);
                }
                if (parts.items.len == 0) return types.never_type;
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
        }
    }

    /// If the assign-flow node writes the reference (or invalidates a
    /// property path by writing its root), the type after the assignment;
    /// null when it is unrelated.
    fn assignNarrows(c: *Checker, target: Node, key: RefKey, declared: TypeId) Error!?TypeId {
        if (target == null_node) return null;
        const root_sym = key.sym;
        switch (c.nodeTag(target)) {
            .declarator_init => {
                const d = c.tree.nodeData(target);
                if (!try c.patternBindsSym(d.lhs, root_sym)) return null;
                if (key.len != 0) return declared; // root re-init: reset path
                if (c.nodeTag(d.lhs) != .identifier) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                return try c.assignmentReduced(declared, vt);
            },
            .declarator_full => {
                const d = c.tree.nodeData(target);
                if (!try c.patternBindsSym(d.lhs, root_sym)) return null;
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (key.len != 0) return declared;
                if (e.init == 0) return declared;
                if (c.nodeTag(d.lhs) != .identifier) return declared;
                const vt = c.nodeType(e.init) orelse try c.checkExprCached(e.init, types.no_type);
                return try c.assignmentReduced(declared, vt);
            },
            .assign => {
                const d = c.tree.nodeData(target);
                // Full path write: <ref> = v narrows the tracked reference.
                if (key.len != 0 and try c.refMatches(d.lhs, key)) {
                    const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                    if (op != .eq) return declared;
                    const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                    return try c.assignmentReduced(declared, vt);
                }
                // Writing any proper prefix of the path (its root, or an
                // intermediate member) invalidates the whole subtree.
                if (try c.refPrefixWritten(d.lhs, key)) return declared;
                if (c.nodeTag(d.lhs) == .identifier) {
                    if (!try c.identIsSym(d.lhs, root_sym)) return null;
                    // key.len != 0 was caught above by refPrefixWritten.
                    const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                    if (op != .eq) {
                        const vt = c.nodeType(target) orelse declared;
                        return try c.assignmentReduced(declared, vt);
                    }
                    const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                    return try c.assignmentReduced(declared, vt);
                }
                if (try c.patternBindsSym(d.lhs, root_sym)) return declared;
                return null;
            },
            .prefix_unary, .postfix_unary => {
                const d = c.tree.nodeData(target);
                if (try c.refMatches(d.lhs, key)) {
                    return try c.assignmentReduced(declared, types.number_type);
                }
                if (try c.refPrefixWritten(d.lhs, key)) return declared;
                return null;
            },
            // for-of / for-in left (var decl or expression).
            .var_decl_one, .var_decl => {
                if (try c.varDeclBindsSym(target, root_sym)) {
                    if (key.len != 0) return declared;
                    // The element type was computed when the statement was
                    // checked; the symbol type already reflects it.
                    return try c.typeOfSymbol(root_sym);
                }
                return null;
            },
            .identifier => {
                if (!try c.identIsSym(target, root_sym)) return null;
                return declared;
            },
            else => {
                if (try c.patternBindsSym(target, root_sym)) return declared;
                return null;
            },
        }
    }

    /// Narrow `t` (the flow type of the reference) by a decomposed
    /// condition node.
    /// Whether the tracked reference is a *constant reference* in tsc's sense:
    /// a root-identifier reference to a `const`, or to a parameter / mutable
    /// local that is never reassigned anywhere in its file. Aliased-condition
    /// narrowing requires this — an alias snapshots the condition at its
    /// declaration point, so a reassignable subject could make the snapshot
    /// stale (mirrors tsc's `isConstantReference`).
    fn isConstantRefSym(c: *Checker, key: RefKey) Error!bool {
        if (key.len != 0) return false;
        if (key.sym == this_flow_root) return false;
        const sf = c.symFlags(key.sym);
        if (sf.const_decl) return true;
        if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return false;
        if (sf.exported) return false; // a top-level export may be reassigned elsewhere
        if (c.symFile(key.sym) != c.cur_file) return false;
        try c.ensureReassignScan();
        return !c.reassigned_syms.contains(key.sym);
    }

    /// TS4.4 aliased-condition support: if `cond` is a bare identifier bound to
    /// a `const` variable whose declarator has an initializer and no explicit
    /// type annotation, and the tracked reference `key` is a constant
    /// reference, return that initializer expression so the caller can narrow
    /// `key` by it. Any unmet precondition returns null (narrowing untouched):
    ///   • alias must be declared `const` (a never-reassigned `let` does NOT
    ///     narrow — verified against tsc 5.9.3),
    ///   • the declarator must carry no explicit type annotation (`const m:
    ///     boolean = …` does not narrow), and bind a plain identifier (no
    ///     destructured alias),
    ///   • same-file, non-exported (so the initializer resolves in scope).
    fn constAliasInit(c: *Checker, cond: Node, key: RefKey) Error!?Node {
        if (c.nodeTag(cond) != .identifier) return null;
        if (!try c.isConstantRefSym(key)) return null;
        const a = try c.atomOfToken(c.tree.nodeMainToken(cond));
        const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |s| s,
            else => return null,
        };
        if (sym == key.sym) return null; // matched-reference case handled by the caller
        const sf = c.symFlags(sym);
        if (!sf.const_decl) return null;
        if (sf.exported) return null;
        if (c.symFile(sym) != c.cur_file) return null;
        const decls = c.declsOf(sym);
        if (decls.len != 1) return null;
        const decl = decls[0];
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .declarator_init => {
                if (c.nodeTag(d.lhs) != .identifier) return null;
                return d.rhs;
            },
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (e.type_ann != 0 or e.init == 0) return null;
                if (c.nodeTag(d.lhs) != .identifier) return null;
                return e.init;
            },
            else => return null,
        }
    }

    fn narrowByCondition(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey) Error!TypeId {
        if (cond == null_node) return t;
        const d = c.tree.nodeData(cond);
        switch (c.nodeTag(cond)) {
            .paren_expr => return c.narrowByCondition(t, d.lhs, sense, key),
            .non_null => return c.narrowByCondition(t, d.lhs, sense, key),
            .identifier => {
                if (try c.refMatches(cond, key)) {
                    return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
                }
                // Aliased-condition narrowing (tsc TS4.4 "control flow analysis
                // of aliased conditions and discriminants"): the condition is a
                // bare identifier bound to a `const` whose initializer is itself
                // a narrowing expression. Narrow the tracked reference by that
                // initializer instead. `constAliasInit` enforces tsc's rules
                // (const alias, no explicit annotation, subject a constant
                // reference so the snapshot cannot go stale); the level cap
                // bounds alias-of-alias chains.
                if (c.alias_inline_level < 5) {
                    if (try c.constAliasInit(cond, key)) |init_expr| {
                        c.alias_inline_level += 1;
                        defer c.alias_inline_level -= 1;
                        return c.narrowByCondition(t, init_expr, sense, key);
                    }
                }
                return t;
            },
            .member_expr, .optional_member_expr => {
                // The path itself is the condition.
                if (try c.refMatches(cond, key)) {
                    return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
                }
                // `if (<ref>.p)` / `if (<ref>?.p)` — discriminate the tracked
                // reference by the truthiness of an extra property `p`.
                if (try c.refMatches(d.lhs, key)) {
                    var base = t;
                    if (c.nodeTag(cond) == .optional_member_expr and sense) {
                        base = try c.nonNullable(base);
                    }
                    const prop = try c.memberAtom(d.rhs);
                    return c.narrowByPropTruthiness(base, prop, sense);
                }
                // A truthy optional chain (`if (a?.b.c)`, `if (!a?.b.c)` else)
                // implies its receivers did not short-circuit: narrow a contained
                // receiver reference to non-null. This is tsc's
                // `narrowTypeByTruthiness` optional-chain-containment rule — it
                // fires on the true branch only (a falsy chain says nothing about
                // whether the receiver was nullish).
                if (sense and try c.optionalChainContainsRef(cond, key)) {
                    return c.nonNullable(t);
                }
                return t;
            },
            .binary => {
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(cond));
                switch (op) {
                    .eq_eq_eq, .bang_eq_eq, .eq_eq, .bang_eq => {
                        const strict = op == .eq_eq_eq or op == .bang_eq_eq;
                        var eff_sense = sense;
                        if (op == .bang_eq_eq or op == .bang_eq) eff_sense = !sense;
                        return c.narrowByEqualityCond(t, d.lhs, d.rhs, strict, eff_sense, key);
                    },
                    .keyword_in => {
                        // `"p" in x`
                        if (!try c.refMatches(d.rhs, key)) return t;
                        const lhs_t = try c.checkExprCached(d.lhs, types.no_type);
                        const rl = try c.ts.regularLiteral(lhs_t);
                        if (c.ts.kind(rl) != .string_literal) return t;
                        return c.narrowByInProp(t, c.ts.literalAtom(rl), sense);
                    },
                    .keyword_instanceof => {
                        if (!try c.refMatches(d.lhs, key)) return t;
                        const rt = try c.checkExprCached(d.rhs, types.no_type);
                        if (try c.instanceofInstanceType(rt)) |inst|
                            return c.narrowByInstance(t, inst, sense);
                        return t;
                    },
                    else => return t,
                }
            },
            .prefix_unary => return t, // `!` was decomposed by the binder
            .call_expr, .call_expr_targs, .optional_call => {
                // A truthy optional-*call* chain (`if (a?.m())`, or the
                // fall-through of `if (!a?.m()) return`) implies its receivers
                // did not short-circuit: narrow a contained receiver to
                // non-null. Symmetric with the optional-member arm above
                // (tsc's `narrowTypeByTruthiness` optional-chain containment);
                // fires on the truthy branch only. This is what lets the common
                // `if (!raw?.trim()) return ''; …raw…` guard narrow `raw`.
                if (sense and try c.optionalChainContainsRef(cond, key)) {
                    return c.nonNullable(t);
                }
                return c.narrowByGuardCall(t, cond, sense, key);
            },
            else => return t,
        }
    }

    fn narrowByEqualityCond(c: *Checker, t: TypeId, lhs: Node, rhs: Node, strict: bool, sense: bool, key: RefKey) Error!TypeId {
        // typeof <ref> === "..."
        if (try c.typeofTargetOf(lhs, key)) {
            const rt = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
            if (c.ts.kind(rt) == .string_literal) {
                return c.narrowByTypeof(t, c.ts.literalAtom(rt), sense);
            }
            return t;
        }
        if (try c.typeofTargetOf(rhs, key)) {
            const lt = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
            if (c.ts.kind(lt) == .string_literal) {
                return c.narrowByTypeof(t, c.ts.literalAtom(lt), sense);
            }
            return t;
        }
        // `typeof <optional-chain-containing-ref> === "…"`: the chain short-
        // circuits to `undefined` (so `typeof` is `"undefined"`) exactly when a
        // receiver was nullish. If this branch forces `typeof(chain) !=
        // "undefined"`, that receiver did not short-circuit — narrow it non-null
        // (tsc's `narrowTypeByTypeof` optional-chain-containment rule). `sense`
        // here is already equals-folded (`!==`/`!=` inverted by the caller).
        if (try c.typeofChainContainsRef(lhs, key)) {
            return c.narrowByTypeofChainContainment(t, rhs, sense);
        }
        if (try c.typeofChainContainsRef(rhs, key)) {
            return c.narrowByTypeofChainContainment(t, lhs, sense);
        }
        // <ref> === <literal> / <literal> === <ref>
        if (try c.refMatches(lhs, key)) {
            return c.narrowByLiteralEquality(t, rhs, strict, sense);
        }
        if (try c.refMatches(rhs, key)) {
            return c.narrowByLiteralEquality(t, lhs, strict, sense);
        }
        // <ref>.k === <literal> narrows <ref> by its discriminant. `<ref>` is
        // the tracked reference — a root symbol (`x.k`, key.len == 0) or a
        // member path (`f.geometry.k`, narrowing the union stored at the
        // tracked `f.geometry`). The union `t` is `<ref>`'s type, so the same
        // discriminant filter applies regardless of the reference's depth.
        if (try c.discriminantOfRef(lhs, key)) |prop_tok| {
            const other = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
            const narrowed = try c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense);
            // An OPTIONAL discriminant read (`x?.k === lit`) short-circuits to
            // `undefined` when the receiver is nullish, so the equality also
            // forces the receiver non-nullish on the asserting branch (tsc's
            // optional-chain containment). The discriminant filter alone keeps
            // `undefined` (no `k` prop → conservatively kept), so strip it too.
            if (c.nodeTag(lhs) == .optional_member_expr) {
                return c.narrowByOptChainContainment(narrowed, rhs, strict, sense);
            }
            return narrowed;
        }
        if (try c.discriminantOfRef(rhs, key)) |prop_tok| {
            const other = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
            const narrowed = try c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense);
            if (c.nodeTag(rhs) == .optional_member_expr) {
                return c.narrowByOptChainContainment(narrowed, lhs, strict, sense);
            }
            return narrowed;
        }
        // Optional-chain containment: `a?.….m() === <value>` narrows the chain's
        // *receiver* `a` to non-null (tsc's narrowTypeByOptionalChainContainment).
        // If `a` were nullish the whole chain short-circuits to `undefined`, so
        // when the comparison to `value` can only hold for a non-undefined (and,
        // for `==`/`!=`, non-null) `value`, the receiver did not short-circuit.
        if (try c.optionalChainContainsRef(lhs, key)) {
            return c.narrowByOptChainContainment(t, rhs, strict, sense);
        }
        if (try c.optionalChainContainsRef(rhs, key)) {
            return c.narrowByOptChainContainment(t, lhs, strict, sense);
        }
        return t;
    }

    /// Walks an optional chain's receiver spine (`chain.expression` at each
    /// link), returning true when `key` matches a receiver at some optional
    /// link — i.e. `key`'s reference is a container of the chain's short-circuit
    /// (tsc's `optionalChainContainsReference`). Only fires for a chain that
    /// actually has a `?.` link; a plain `a.b.c` never matches.
    fn optionalChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
        var n = node;
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        while (c.isOptionalChain(n)) {
            n = c.tree.nodeData(n).lhs; // step to this link's object/callee
            if (try c.refMatches(n, key)) return true;
        }
        return false;
    }

    /// Apply tsc's `narrowTypeByOptionalChainContainment`: remove `null`/
    /// `undefined` from the receiver `t` when the comparand `value` forces the
    /// chain to not have short-circuited in this branch. `strict` selects the
    /// nullable set (`===`/`!==` → `undefined` only; `==`/`!=` → `null` |
    /// `undefined`). `sense` is the already-bang-folded truthiness (so `!==`
    /// arrives as an inverted `===`): with the operator's equals-ness folded in,
    /// `sense` true means "narrow when every comparand constituent is
    /// non-nullish and not any/unknown"; `sense` false means "narrow when every
    /// comparand constituent is nullish".
    fn narrowByOptChainContainment(c: *Checker, t: TypeId, value: Node, strict: bool, sense: bool) Error!TypeId {
        const vt = try c.checkExprCached(value, types.no_type);
        if (c.optChainComparandRemovesNullable(vt, strict, sense)) return c.nonNullable(t);
        return t;
    }

    fn optChainComparandRemovesNullable(c: *Checker, vt: TypeId, strict: bool, sense: bool) bool {
        if (c.ts.kind(vt) == .union_type) {
            for (c.ts.members(vt)) |m| {
                if (!c.optChainComparandConstituentOk(m, strict, sense)) return false;
            }
            return true;
        }
        return c.optChainComparandConstituentOk(vt, strict, sense);
    }

    fn optChainComparandConstituentOk(c: *Checker, m: TypeId, strict: bool, sense: bool) bool {
        const k = c.ts.kind(m);
        const nullish = k == .undefined or k == .void or (!strict and k == .null);
        if (sense) {
            // Every constituent must be non-nullish and not any/unknown/err
            // (their domains include undefined/null, so they can't force a
            // non-null receiver).
            return !nullish and k != .any and k != .unknown and k != .err;
        }
        // Every constituent must be nullish.
        return nullish;
    }

    fn typeofTargetOf(c: *Checker, node: Node, key: RefKey) Error!bool {
        if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
        if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
        return c.refMatches(c.tree.nodeData(node).lhs, key);
    }

    /// `node` is `typeof <expr>` whose `<expr>` is an optional chain containing
    /// `key`'s reference at an optional link (but is not the ref itself — that
    /// exact case is `typeofTargetOf`).
    fn typeofChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
        if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
        if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
        return c.optionalChainContainsRef(c.tree.nodeData(node).lhs, key);
    }

    /// Narrow a chain receiver `t` to non-null when a `typeof <chain>` branch
    /// forces `typeof(chain) != "undefined"`. `sense` is the equals-folded
    /// branch truthiness (true ⇒ the branch asserts `typeof(chain) == literal`).
    /// The chain did not short-circuit iff its `typeof` is not `"undefined"`, so
    /// narrow iff `sense == (literal != "undefined")`.
    fn narrowByTypeofChainContainment(c: *Checker, t: TypeId, value: Node, sense: bool) Error!TypeId {
        const rt = try c.ts.regularLiteral(try c.checkExprCached(value, types.no_type));
        if (c.ts.kind(rt) != .string_literal) return t;
        const is_undef_lit = c.ts.literalAtom(rt) == c.typeof_atoms[5]; // "undefined"
        if (sense != is_undef_lit) return c.nonNullable(t);
        return t;
    }

    /// `<ref>.k` where `<ref>` is exactly `key`'s reference: returns the
    /// discriminant property token `k`. Handles any tracked reference — a root
    /// symbol (`x.k`) *or* a depth-1 member path (`f.geometry.k`) — by reusing
    /// `refMatches` on the access base.
    ///
    /// A *plain* `.k` access is a discriminant read. An *optional* `?.k` access
    /// short-circuits to `undefined` when the base is nullish, so comparing it
    /// is the optional-chain-containment pattern (handled downstream), not a
    /// discriminant — accepted here only for a root-symbol ref, where tsc's
    /// `getDiscriminantPropertyAccess` still treats `x?.k === lit` as a
    /// discriminant (and where this preserves the pre-existing behavior). For a
    /// member-path ref, only the plain access counts, so an optional discriminant
    /// read on the tracked member (`m?.k`) stays with the containment machinery.
    fn discriminantOfRef(c: *Checker, node: Node, key: RefKey) Error!?TokenIndex {
        if (node == null_node) return null;
        switch (c.nodeTag(node)) {
            .member_expr => {},
            .optional_member_expr => if (key.len != 0) return null,
            else => return null,
        }
        const d = c.tree.nodeData(node);
        if (!try c.refMatches(d.lhs, key)) return null;
        return d.rhs;
    }

    fn identIsSym(c: *Checker, node: Node, sym: SymbolId) Error!bool {
        if (node == null_node) return false;
        if (sym == this_flow_root) return c.nodeTag(node) == .this_expr;
        if (c.nodeTag(node) != .identifier) return false;
        const a = try c.atomOfToken(c.tree.nodeMainToken(node));
        if (a != c.symNameAtom(sym)) return false;
        return switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |s| s == sym,
            else => false,
        };
    }

    /// Populate `reassigned_syms` for the current file: the set of value
    /// symbols that are ever the target of a reassignment (`x = …`, `x += …`,
    /// `x++`, or a destructuring-assignment element). Runs once per file
    /// (`reassign_scanned`); the declarator initializer is *not* a
    /// reassignment. Order-invariant — a pure function of the file's AST.
    fn ensureReassignScan(c: *Checker) Error!void {
        if (c.reassign_scanned[c.cur_file]) return;
        c.reassign_scanned[c.cur_file] = true;
        const b = c.bind;
        var flow: FlowId = 0;
        while (flow < b.flow_tags.len) : (flow += 1) {
            if (b.flow_tags[flow] != .assign) continue;
            const node = b.flowNode(flow);
            if (node == null_node) continue;
            const scope = b.flowScope(flow);
            switch (c.nodeTag(node)) {
                .assign => try c.markReassignTarget(c.tree.nodeData(node).lhs, scope),
                .prefix_unary, .postfix_unary => {
                    switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                        .plus_plus, .minus_minus => try c.markReassignTarget(c.tree.nodeData(node).lhs, scope),
                        else => {},
                    }
                },
                // declarator_init / declarator_full / for-in-of bindings are
                // the variable's *initialization*, not a reassignment.
                else => {},
            }
        }
    }

    /// Record `sym` as reassigned, and for every `for`/`for..of`/`for..in`
    /// header scope enclosing the assignment's `scope`, record that `sym` is
    /// assigned *inside that loop*. The ancestor walk means an assignment nested
    /// N loops deep marks all N enclosing loops.
    fn recordReassign(c: *Checker, sym: SymbolId, scope: ScopeId) Error!void {
        try c.reassigned_syms.put(c.ca(), sym, {});
        const b = c.bind;
        var s = scope;
        while (true) {
            if (b.scope_kinds[s] == .for_head)
                try c.reassigned_in_loop.put(c.ca(), .{ .sym = sym, .scope = s }, {});
            const p = b.scope_parents[s];
            if (p == s) break;
            s = p;
        }
    }

    fn markReassignTarget(c: *Checker, target: Node, scope: ScopeId) Error!void {
        if (target == null_node) return;
        var n = target;
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        switch (c.nodeTag(n)) {
            .identifier => {
                const a = try c.atomOfToken(c.tree.nodeMainToken(n));
                switch (c.resolveSpace(a, scope, true)) {
                    .sym => |s| try c.recordReassign(s, scope),
                    else => {},
                }
            },
            // Destructuring-assignment target: `[a] = …` / `({a} = …)`.
            .array_literal, .object_literal, .array_pattern, .object_pattern => {
                for (c.tree.nodeRange(n)) |el| {
                    if (el != null_node) try c.markReassignTarget(el, scope);
                }
            },
            .binding_property, .object_shorthand, .object_property => {
                const d = c.tree.nodeData(n);
                if (d.lhs != 0) {
                    try c.markReassignTarget(d.lhs, scope);
                } else {
                    const a = try c.memberAtom(c.tree.nodeMainToken(n));
                    switch (c.resolveSpace(a, scope, true)) {
                        .sym => |s| try c.recordReassign(s, scope),
                        else => {},
                    }
                }
            },
            .binding_default, .rest_element, .spread_element => {
                try c.markReassignTarget(c.tree.nodeData(n).lhs, scope);
            },
            // member_expr (`o.p = v`) reassigns a property, not a variable.
            else => {},
        }
    }

    fn patternBindsSym(c: *Checker, pat: Node, sym: SymbolId) Error!bool {
        if (pat == null_node) return false;
        if (sym == this_flow_root) return false; // a pattern never binds `this`
        switch (c.nodeTag(pat)) {
            .identifier => return (try c.atomOfToken(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym),
            .array_pattern, .object_pattern, .array_literal, .object_literal => {
                for (c.tree.nodeRange(pat)) |el| {
                    if (el != null_node and try c.patternBindsSym(el, sym)) return true;
                }
                return false;
            },
            .binding_property, .object_shorthand, .object_property => {
                const d = c.tree.nodeData(pat);
                if (d.lhs != 0) return c.patternBindsSym(d.lhs, sym);
                return (try c.memberAtom(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym);
            },
            .binding_default, .rest_element, .spread_element => {
                return c.patternBindsSym(c.tree.nodeData(pat).lhs, sym);
            },
            else => return false,
        }
    }

    fn varDeclBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
        const d = c.tree.nodeData(decl);
        if (c.nodeTag(decl) == .var_decl_one) {
            return c.declaratorBindsSym(d.lhs, sym);
        }
        for (c.tree.nodeRange(decl)) |dn| {
            if (dn != null_node and try c.declaratorBindsSym(dn, sym)) return true;
        }
        return false;
    }

    fn declaratorBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
        const d = c.tree.nodeData(decl);
        return switch (c.nodeTag(decl)) {
            .declarator, .declarator_init, .declarator_full => c.patternBindsSym(d.lhs, sym),
            else => c.patternBindsSym(decl, sym),
        };
    }

    /// tsc's getAssignmentReducedType: keep declared-union constituents
    /// the assigned type is assignable to.
    fn assignmentReduced(c: *Checker, declared: TypeId, assigned0: TypeId) Error!TypeId {
        const dk = c.ts.kind(declared);
        if (dk == .any or dk == .err or dk == .unknown) {
            if (dk == .unknown) return c.widenLiteral(assigned0);
            return declared;
        }
        const assigned = try c.ts.regular(try c.ts.regularLiteral(assigned0));
        if (dk != .union_type) return declared;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(declared)) |m| {
            if (try c.isAssignable(assigned, m)) try parts.append(c.scratch(), m);
        }
        if (parts.items.len == 0) {
            for (try c.memberList(declared)) |m| {
                if (try c.isComparable(assigned, m)) try parts.append(c.scratch(), m);
            }
        }
        if (parts.items.len == 0) return declared;
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    fn narrowByLiteralEquality(c: *Checker, t: TypeId, other: Node, strict: bool, sense: bool) Error!TypeId {
        const ot0 = try c.checkExprCached(other, types.no_type);
        const ot = try c.ts.regularLiteral(ot0);
        const ok = c.ts.kind(ot);
        const is_nullish = ok == .null or ok == .undefined;
        if (!strict and is_nullish) {
            // == null / == undefined match both.
            if (sense) {
                return c.filterUnion(t, struct {
                    fn keep(ch: *Checker, m: TypeId) bool {
                        const k = ch.ts.kind(m);
                        return k == .null or k == .undefined or k == .any or k == .unknown or k == .err;
                    }
                }.keep);
            }
            return c.nonNullable(t);
        }
        const is_literal = c.ts.literalBase(ot) != types.no_type or is_nullish;
        if (!is_literal) return t;
        if (sense) {
            return c.narrowToValue(t, ot);
        }
        return c.narrowExcludeValue(t, ot);
    }

    /// Narrow `t` to the single value type `v` (=== true branch).
    fn narrowToValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const nm = try c.narrowToValue(m, v);
                if (nm != types.never_type) try parts.append(c.scratch(), nm);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        const mt = try c.ts.regularLiteral(t);
        const k = c.ts.kind(mt);
        if (mt == v) return v;
        if (k == .any or k == .unknown or k == .err) return v;
        // `=== null` / `=== undefined`: only a matching nullish member (handled
        // by `mt == v` above) survives; any other concrete member is excluded.
        // Without this the false branch of `x !== null` stayed `number | null`,
        // defeating the inferred-predicate disjointness gate (and under-
        // narrowing `if (x === null)`).
        if (c.ts.kind(v) == .null or c.ts.kind(v) == .undefined) return types.never_type;
        if (c.ts.literalBase(v) == mt) return v; // string narrowed by "a"
        if (k == .boolean and (c.ts.kind(v) == .bool_true or c.ts.kind(v) == .bool_false)) return v;
        if (c.ts.literalBase(mt) != types.no_type or k == .null or k == .undefined) {
            return types.never_type; // different literal
        }
        // Non-literal member unrelated to v's base: exclude.
        if (c.ts.literalBase(v) != types.no_type) return types.never_type;
        return mt;
    }

    /// Remove the single value type `v` from `t` (!== true branch).
    fn narrowExcludeValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const nm = try c.narrowExcludeValue(m, v);
                if (nm != types.never_type) try parts.append(c.scratch(), nm);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        const mt = try c.ts.regularLiteral(t);
        if (mt == v) return types.never_type;
        if (c.ts.kind(mt) == .boolean) {
            if (c.ts.kind(v) == .bool_true) return types.false_type;
            if (c.ts.kind(v) == .bool_false) return types.true_type;
        }
        return t;
    }

    fn narrowByTypeof(c: *Checker, t0: TypeId, str: Atom, sense: bool) Error!TypeId {
        var which: usize = typeof_names.len;
        for (c.typeof_atoms, 0..) |a, i| {
            if (a == str) which = i;
        }
        if (which == typeof_names.len) return t0;
        // A bare type parameter (an unconstrained `T`, or `T = any`) is not
        // disprovably a non-object: `typeofMatches` only inspects concrete
        // kinds, so narrowing the type param directly would collapse
        // `typeof x === 'object'` to `never`. Narrow its *constraint* instead
        // (sound, and matches tsc's constraint-based reference narrowing).
        const t = if (c.ts.kind(t0) == .type_param) try c.baseConstraintOf(t0) else t0;
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const keep = c.typeofMatches(m, which);
                const kept = if (sense) keep else !keep;
                if (kept) try parts.append(c.scratch(), m);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        }
        const k = c.ts.kind(t);
        if (k == .any or k == .unknown or k == .err) {
            if (!sense) return t;
            return switch (which) {
                0 => types.string_type,
                1 => types.number_type,
                2 => types.bigint_type,
                3 => types.boolean_type,
                4 => types.symbol_type,
                5 => types.undefined_type,
                6 => if (k == .unknown) try c.makeUnion2(types.object_keyword_type, types.null_type) else types.any_type,
                7 => t, // "function": no Function type in subset — keep
                else => t,
            };
        }
        const matches = c.typeofMatches(t, which);
        if (sense) return if (matches) t else types.never_type;
        return if (matches) types.never_type else t;
    }

    fn typeofMatches(c: *Checker, t: TypeId, which: usize) bool {
        const k = c.ts.kind(t);
        return switch (which) {
            0 => k == .string or k == .string_literal,
            1 => k == .number or k == .number_literal or k == .number_literal_fresh,
            2 => k == .bigint or k == .bigint_literal,
            3 => k == .boolean or k == .bool_true or k == .bool_false,
            4 => k == .symbol,
            5 => k == .undefined or k == .void,
            6 => k == .null or k == .object or k == .array or k == .tuple or k == .ref or
                k == .object_keyword or k == .intersection,
            7 => k == .function or k == .overloads or k == .class_value,
            else => false,
        };
    }

    fn narrowByDiscriminant(c: *Checker, t: TypeId, prop: Atom, value: TypeId, sense: bool) Error!TypeId {
        if (c.ts.kind(t) != .union_type) {
            return t;
        }
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            const p = try c.propOfType(rm, prop);
            var matches = true; // members without the prop stay (conservative)
            if (p) |pp| {
                const pv = try c.ts.regularLiteral(pp.ty);
                if (c.ts.literalBase(pv) != types.no_type or c.ts.kind(pv) == .null or c.ts.kind(pv) == .undefined) {
                    matches = try c.isComparable(pv, value);
                } else {
                    matches = try c.isComparable(pp.ty, value);
                }
            }
            const kept = if (sense) matches else blk: {
                // false branch removes members whose discriminant is
                // *exactly* the value.
                if (p) |pp| {
                    const pv = try c.ts.regularLiteral(pp.ty);
                    break :blk pv != value;
                }
                break :blk true;
            };
            if (kept) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    fn narrowByPropTruthiness(c: *Checker, t: TypeId, prop: Atom, sense: bool) Error!TypeId {
        if (c.ts.kind(t) != .union_type) return t;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            var keep = true;
            if (try c.propOfType(rm, prop)) |p| {
                if (sense) {
                    // True branch: drop members whose prop is definitely falsy.
                    const truthy = try c.getTruthyPart(p.ty);
                    keep = truthy != types.never_type;
                } else {
                    const falsy = try c.getFalsyPart(p.ty, true);
                    keep = falsy != types.never_type or p.optional();
                }
            }
            if (keep) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    fn narrowByInProp(c: *Checker, t: TypeId, prop: Atom, sense: bool) Error!TypeId {
        if (c.ts.kind(t) != .union_type) return t;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            const has = (try c.propOfType(rm, prop)) != null;
            const optional = if (try c.propOfType(rm, prop)) |p| p.optional() else false;
            const kept = if (sense) has else (!has or optional);
            if (kept) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    /// If `call`'s callee is a predicate signature whose guarded parameter
    /// receives `key` as its argument, return that predicate; else null.
    /// Shared by user-defined type guards and assertion functions.
    fn guardTargetFor(c: *Checker, call: Node, key: RefKey) Error!?types.Predicate {
        const shape = c.callShape(call);
        // Obtain the callee's type for predicate inspection. When the callee is
        // a MEMBER/element access (`rule.abstract.startsWith`), re-checking it
        // here — a flow-narrowing side query — would re-evaluate its receiver;
        // if this query is a re-entrant walk of a loop back-edge triggered by
        // the very call statement/condition being checked (loop label still in
        // progress), the receiver is transiently re-widened to its declared
        // type, so the member access raises a spurious TS18048/2532 and caches a
        // poisoned type. For those callees, consult only the already-computed
        // type: a genuine member-callee guard is checked top-down before any
        // read whose narrowing depends on it, so it is memoized by then; an
        // un-memoized member callee means we are in that premature re-entrant
        // state, so skip (sound under-narrowing). A bare-identifier callee
        // (`isT(x)`) has no receiver to re-widen and is not always memoized as a
        // node type, so it is safe to (re-)check directly.
        const callee = shape.callee;
        const callee_t = switch (c.nodeTag(callee)) {
            .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.nodeType(callee) orelse return null,
            else => try c.checkExprCached(callee, types.no_type),
        };
        if (!c.ts.fnHasPredicate(callee_t)) return null;
        const pred = c.ts.fnPredicate(callee_t);
        if (pred.param == types.Predicate.this_param) return null; // `this is T`: gap
        if (pred.param >= shape.arg_nodes.len) return null;
        const arg = shape.arg_nodes[pred.param];
        if (arg == null_node or !try c.refMatches(arg, key)) return null;
        return pred;
    }

    /// `if (isT(x))` — a user-defined type guard used in a condition.
    /// True branch narrows the argument to the predicate type; the false
    /// branch takes the complement (union filtering handles both).
    fn narrowByGuardCall(c: *Checker, t: TypeId, call: Node, sense: bool, key: RefKey) Error!TypeId {
        const pred = (try c.guardTargetFor(call, key)) orelse return t;
        if (pred.asserts) return t; // assertion fns narrow after the call, not here
        if (pred.ty == types.no_type) return t;
        return c.narrowByInstance(t, pred.ty, sense);
    }

    /// `assertIsT(x);` — an assertion-function call statement narrows the
    /// argument to the asserted type for the rest of the flow; a bare
    /// `asserts cond` narrows by truthiness.
    fn narrowByAssertCall(c: *Checker, t: TypeId, call: Node, key: RefKey) Error!TypeId {
        const pred = (try c.guardTargetFor(call, key)) orelse return t;
        if (!pred.asserts) return t; // plain guards don't narrow as statements
        if (pred.ty == types.no_type) return c.getTruthyPart(t); // `asserts cond`
        return c.narrowByInstance(t, pred.ty, true);
    }

    /// tsc's `getInstanceType(constructorType)`: prefer the `prototype`
    /// property type (when present and not `any`), else the union of the
    /// construct signatures' return types. Returns `no_type` when the RHS is
    /// not a usable constructor (→ no narrowing, sound under-narrowing).
    fn instanceTypeOfConstructor(c: *Checker, rt: TypeId) Error!TypeId {
        if (try c.propOfType(rt, try c.internText("prototype"))) |p| {
            const k = c.ts.kind(p.ty);
            if (k != .any and k != .err and k != .unknown) return p.ty;
        }
        var obj = rt;
        if (c.ts.kind(obj) == .ref) obj = try c.expandRef(obj);
        if (c.ts.kind(obj) == .object) {
            const n = c.ts.objectConstructSigCount(obj);
            if (n > 0) {
                var rets: std.ArrayList(TypeId) = .empty;
                defer rets.deinit(c.scratch());
                for (0..n) |i| {
                    try rets.append(c.scratch(), c.ts.fnReturn(c.ts.objectConstructSig(obj, @intCast(i))));
                }
                return c.ts.makeUnion(c.scratch(), rets.items);
            }
        }
        return types.no_type;
    }

    /// The instance type produced by `x instanceof RHS`, or `null` when the
    /// RHS is not a usable constructor (→ no narrowing). A plain `class`
    /// value maps to `C<any…>`. An `.intersection` of constructors is handled
    /// member-wise: a `declare module` augmentation merges a class declaration
    /// with itself into `typeof C & typeof C`, and mixins yield `typeof A &
    /// typeof B` — in both cases the constructor is NOT a `.class_value`, so
    /// without this the narrowing collapsed (`instanceTypeOfConstructor` finds
    /// no `prototype`/construct sig on the intersection and gives up), leaving
    /// the operand at its declared base type.
    fn instanceofInstanceType(c: *Checker, rt: TypeId) Error!?TypeId {
        switch (c.ts.kind(rt)) {
            .class_value => {
                const cls = c.ts.classSymbol(rt);
                var tps: std.ArrayList(TypeParamInfo) = .empty;
                defer tps.deinit(c.scratch());
                try c.typeParamsOf(cls, &tps);
                const args = try c.scratch().alloc(TypeId, tps.items.len);
                for (args) |*x| x.* = types.any_type;
                return try c.ts.makeRef(cls, args);
            },
            .intersection => {
                var insts: std.ArrayList(TypeId) = .empty;
                defer insts.deinit(c.scratch());
                for (try c.memberList(rt)) |m| {
                    const mi = (try c.instanceofInstanceType(m)) orelse continue;
                    var seen = false;
                    for (insts.items) |e| {
                        if (e == mi) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try insts.append(c.scratch(), mi);
                }
                if (insts.items.len == 0) {
                    const inst = try c.instanceTypeOfConstructor(rt);
                    return if (inst == types.no_type) null else inst;
                }
                if (insts.items.len == 1) return insts.items[0];
                return try c.ts.makeIntersection(c.scratch(), insts.items);
            },
            else => {
                const inst = try c.instanceTypeOfConstructor(rt);
                return if (inst == types.no_type) null else inst;
            },
        }
    }

    fn narrowByInstance(c: *Checker, t: TypeId, instance: TypeId, sense: bool) Error!TypeId {
        if (c.ts.kind(t) == .union_type) {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| {
                const matches = try c.isAssignable(m, instance);
                const kept = if (sense) matches else !matches;
                if (kept) try parts.append(c.scratch(), m);
            }
            const result = try c.ts.makeUnion(c.scratch(), parts.items);
            if (sense and result == types.never_type) {
                if (try c.isAssignable(instance, t)) return instance;
            }
            return result;
        }
        if (sense) {
            if (try c.isAssignable(t, instance)) return t;
            if (try c.isAssignable(instance, t)) return instance;
            const k = c.ts.kind(t);
            if (k == .any or k == .unknown or k == .err) return instance;
            // Unrelated `t` and guard `C`: tsc narrows to the intersection
            // `t & C` (e.g. `Array.isArray(s)` with `s: string` → `string &
            // any[]`, which carries the array members; disjoint primitives
            // reduce to `never`). Previously kept `t`, dropping the guard, so
            // `s.map(...)` in the true branch reported TS2339 on `string`.
            return c.ts.makeIntersection(c.scratch(), &.{ t, instance });
        }
        return t;
    }

    fn narrowBySwitchClause(c: *Checker, t: TypeId, clause: Node, key: RefKey) Error!TypeId {
        if (clause == null_node) return t;
        // Find the owning switch statement's discriminant: clause nodes
        // don't back-reference it, so scan: the discriminant condition
        // narrows only when it's the reference or `ref.prop`.
        const sw = c.switchOfClause(clause) orelse return t;
        const disc = c.tree.nodeData(sw).lhs;
        const is_default = c.nodeTag(clause) == .default_clause;

        var prop: Atom = 0;
        var direct = false;
        if (try c.refMatches(disc, key)) {
            direct = true;
        } else if (try c.discriminantOfRef(disc, key)) |prop_tok| {
            prop = try c.memberAtom(prop_tok);
        }
        if (!direct and prop == 0 and c.nodeTag(disc) == .prefix_unary and try c.typeofTargetOf(disc, key)) {
            // switch (typeof x)
            if (is_default) return t;
            const test_node = c.tree.nodeData(clause).lhs;
            const tt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
            if (c.ts.kind(tt) == .string_literal) {
                return c.narrowByTypeof(t, c.ts.literalAtom(tt), true);
            }
            return t;
        }
        if (!direct and prop == 0) return t;

        if (is_default) {
            // Exclude every case value.
            var cur = t;
            const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
            for (c.tree.extraRange(r.start, r.end)) |cl| {
                if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
                const test_node = c.tree.nodeData(cl).lhs;
                if (test_node == 0) continue;
                const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
                if (c.ts.literalBase(vt) == types.no_type and c.ts.kind(vt) != .null and c.ts.kind(vt) != .undefined) continue;
                cur = if (prop == 0)
                    try c.narrowExcludeValue(cur, vt)
                else
                    try c.narrowByDiscriminant(cur, prop, vt, false);
            }
            return cur;
        }
        const test_node = c.tree.nodeData(clause).lhs;
        if (test_node == 0) return t;
        const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
        const is_lit = c.ts.literalBase(vt) != types.no_type or c.ts.kind(vt) == .null or c.ts.kind(vt) == .undefined;
        if (!is_lit) return t;
        return if (prop == 0)
            try c.narrowToValue(t, vt)
        else
            try c.narrowByDiscriminant(t, prop, vt, true);
    }

    /// The switch statement owning a case/default clause (linear scan of
    /// switch nodes; cached would be overkill for the subset).
    fn switchOfClause(c: *Checker, clause: Node) ?Node {
        // Clause nodes are created right after their tests and before the
        // switch node itself; scan forward from the clause for a switch
        // whose clause range contains it.
        var n: Node = clause + 1;
        const total: Node = @intCast(c.tree.nodes.len);
        while (n < total) : (n += 1) {
            if (c.nodeTag(n) != .switch_stmt) continue;
            const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(n).rhs);
            for (c.tree.extraRange(r.start, r.end)) |cl| {
                if (cl == clause) return n;
            }
        }
        return null;
    }

    // --- definite assignment (TS2454) ------------------------------------

    fn definitelyAssigned(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
        if (flow == binder.no_flow or flow == binder.unreachable_flow) return true;
        const key = (@as(u64, flow) << 32) | sym;
        if (c.da_cache.get(key)) |v| {
            if (v == 2) return true; // optimistic on loops
            return v == 1;
        }
        try c.da_cache.put(c.ca(), key, 2);
        const result = try c.definitelyAssignedInner(flow, sym);
        try c.da_cache.put(c.ca(), key, @intFromBool(result));
        return result;
    }

    fn definitelyAssignedInner(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
        const b = c.bind;
        switch (b.flow_tags[flow]) {
            .none => return true,
            .unreachable_ => return true,
            .start => return false,
            .assign => {
                const target = b.flowNode(flow);
                if (try c.assignTargetsSymForDa(target, sym)) return true;
                return c.definitelyAssigned(b.flow_a[flow], sym);
            },
            .cond_true, .cond_false, .switch_clause, .call_stmt => {
                return c.definitelyAssigned(b.flow_a[flow], sym);
            },
            .branch_label, .loop_label => {
                for (b.flowAntecedents(flow)) |a| {
                    if (!try c.definitelyAssigned(a, sym)) return false;
                }
                return true;
            },
        }
    }

    fn assignTargetsSymForDa(c: *Checker, target: Node, sym: SymbolId) Error!bool {
        if (target == null_node) return false;
        switch (c.nodeTag(target)) {
            .declarator_init => return c.patternBindsSym(c.tree.nodeData(target).lhs, sym),
            .declarator_full => {
                const d = c.tree.nodeData(target);
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (e.init == 0) return false;
                return c.patternBindsSym(d.lhs, sym);
            },
            .assign => {
                const d = c.tree.nodeData(target);
                return c.patternBindsSym(d.lhs, sym);
            },
            .prefix_unary, .postfix_unary => {
                return c.identIsSym(c.tree.nodeData(target).lhs, sym);
            },
            .var_decl_one, .var_decl => return c.varDeclBindsSym(target, sym),
            else => return c.patternBindsSym(target, sym),
        }
    }

    // =====================================================================
    // statements & declarations
    // =====================================================================

    fn checkStatement(c: *Checker, node: Node) Error!void {
        if (node == null_node) return;
        // Baseline anchor for any TS2589 raised while materializing types in
        // this statement (refined to finer spans at expression / assignment
        // boundaries).
        c.inst_span = c.nodeSpan(node);
        const d = c.tree.nodeData(node);
        const stmt_tag = c.nodeTag(node);
        // A class-position decorator applies to the class that immediately
        // follows it in the statement list (possibly through an `export`
        // wrapper). Any other statement means a preceding decorator had no
        // class target — drop the pending set so it can't attach to a later
        // class. (`export_default` can also wrap the decorated class.)
        switch (stmt_tag) {
            .decorator, .class_decl, .export_decl, .export_default => {},
            else => c.pending_class_decos.clearRetainingCapacity(),
        }
        switch (stmt_tag) {
            .block => {
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                if (try c.scopeOf(node)) |s| c.cur_scope = s;
                for (c.tree.nodeRange(node)) |stmt| try c.checkStatement(stmt);
            },
            .var_decl_one, .var_decl => try c.checkVarDeclStatement(node),
            .expr_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
            .empty_stmt, .debugger_stmt, .error_node, .unsupported, .omitted => {},
            .if_stmt => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkStatement(d.rhs);
            },
            .if_else_stmt => {
                const e = c.tree.extraData(ast.IfElse, d.rhs);
                _ = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkStatement(e.then_stmt);
                try c.checkStatement(e.else_stmt);
            },
            .while_stmt => {
                _ = try c.checkExprCached(d.lhs, types.no_type);
                try c.checkStatement(d.rhs);
            },
            .do_stmt => {
                try c.checkStatement(d.lhs);
                _ = try c.checkExprCached(d.rhs, types.no_type);
            },
            .for_stmt => {
                const e = c.tree.extraData(ast.For, d.lhs);
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                if (try c.scopeOf(node)) |s| c.cur_scope = s;
                if (e.init != 0) {
                    switch (c.nodeTag(e.init)) {
                        .var_decl_one, .var_decl => try c.checkVarDeclStatement(e.init),
                        else => _ = try c.checkExprCached(e.init, types.no_type),
                    }
                }
                if (e.cond != 0) _ = try c.checkExprCached(e.cond, types.no_type);
                if (e.update != 0) _ = try c.checkExprCached(e.update, types.no_type);
                try c.checkStatement(d.rhs);
            },
            .for_in_stmt, .for_of_stmt => try c.checkForInOf(node),
            .switch_stmt => try c.checkSwitch(node),
            .case_clause, .default_clause => {}, // handled by checkSwitch
            .try_stmt => {
                const e = c.tree.extraData(ast.Try, d.rhs);
                try c.checkStatement(d.lhs);
                if (e.catch_clause != 0) {
                    const cd = c.tree.nodeData(e.catch_clause);
                    const saved = c.cur_scope;
                    defer c.cur_scope = saved;
                    if (try c.scopeOf(e.catch_clause)) |s| c.cur_scope = s;
                    if (cd.rhs != 0) {
                        if (c.nodeTag(cd.rhs) == .block) {
                            for (c.tree.nodeRange(cd.rhs)) |stmt| try c.checkStatement(stmt);
                        } else {
                            try c.checkStatement(cd.rhs);
                        }
                    }
                }
                if (e.finally_block != 0) try c.checkStatement(e.finally_block);
            },
            .throw_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
            .return_stmt => try c.checkReturn(node),
            .break_stmt, .continue_stmt => {},
            .labeled_stmt => try c.checkStatement(d.lhs),
            .function_decl => try c.checkFunctionDecl(node),
            .decorator => try c.pending_class_decos.append(c.ca(), node),
            .class_decl => try c.checkClass(node),
            .interface_decl => try c.checkInterfaceDecl(node),
            .type_alias => try c.checkTypeAliasDecl(node),
            .enum_decl => try c.checkEnum(node),
            .namespace_decl => try c.checkNamespace(node),
            .import_decl => {}, // M5
            .export_named, .export_all => {},
            .export_decl => try c.checkStatement(d.lhs),
            .export_default => {
                switch (c.nodeTag(d.lhs)) {
                    .function_decl, .class_decl => try c.checkStatement(d.lhs),
                    else => _ = try c.checkExprCached(d.lhs, types.no_type),
                }
            },
            else => _ = try c.checkExprCached(node, types.no_type),
        }
    }

    fn checkVarDeclStatement(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const is_const = c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .keyword_const;
        if (c.nodeTag(node) == .var_decl_one) {
            try c.checkDeclarator(d.lhs, is_const);
        } else {
            for (c.tree.nodeRange(node)) |decl| {
                if (decl != null_node) try c.checkDeclarator(decl, is_const);
            }
        }
    }

    fn checkDeclarator(c: *Checker, decl: Node, is_const: bool) Error!void {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .declarator => {},
            .declarator_init => {
                _ = try c.checkExprCached(d.rhs, types.no_type);
                // Materialize the symbol's type (infers + caches).
                try c.materializePatternTypes(d.lhs);
            },
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                const name_span = if (c.nodeTag(d.lhs) == .identifier)
                    c.tokSpan(c.tree.nodeMainToken(d.lhs))
                else
                    c.nodeSpan(d.lhs);
                const ann: TypeId = if (e.type_ann != 0) try c.annTypeMaybeUnique(e.type_ann, is_const, 1332, name_span) else types.no_type;
                // A `unique symbol` const accepts only a fresh `Symbol()` /
                // `Symbol.for()` initializer; the assignability check (a plain
                // `symbol` is not assignable to `unique symbol`) is skipped for
                // that one form, matching tsc.
                if (e.init != 0 and e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and c.isFreshSymbolCall(e.init)) {
                    _ = try c.checkExprCached(e.init, ann);
                    try c.materializePatternTypes(d.lhs);
                    return;
                }
                if (e.init != 0) {
                    const it = try c.checkExprCached(e.init, ann);
                    if (ann != types.no_type and ann != types.error_type) {
                        _ = try c.checkAssignable(it, ann, e.init, name_span);
                    }
                }
                try c.materializePatternTypes(d.lhs);
            },
            else => {},
        }
    }

    /// Force typeOfSymbol for every name bound by a pattern so inference
    /// diagnostics fire deterministically at the declaration site.
    fn materializePatternTypes(c: *Checker, pat: Node) Error!void {
        if (pat == null_node) return;
        switch (c.nodeTag(pat)) {
            .identifier => {
                const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
                switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| _ = try c.typeOfSymbol(sym),
                    else => {},
                }
            },
            .array_pattern, .object_pattern => {
                for (c.tree.nodeRange(pat)) |el| {
                    if (el != null_node) try c.materializePatternTypes(el);
                }
            },
            .binding_property => {
                const d = c.tree.nodeData(pat);
                if (d.lhs != 0) {
                    try c.materializePatternTypes(d.lhs);
                } else {
                    const a = try c.memberAtom(c.tree.nodeMainToken(pat));
                    switch (c.resolveSpace(a, c.cur_scope, true)) {
                        .sym => |sym| _ = try c.typeOfSymbol(sym),
                        else => {},
                    }
                }
                if (d.rhs != 0) _ = try c.checkExprCached(d.rhs, types.no_type);
            },
            .binding_default => {
                const d = c.tree.nodeData(pat);
                try c.materializePatternTypes(d.lhs);
                _ = try c.checkExprCached(d.rhs, types.no_type);
            },
            .rest_element => try c.materializePatternTypes(c.tree.nodeData(pat).lhs),
            else => {},
        }
    }

    fn checkForInOf(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const e = c.tree.extraData(ast.ForInOf, d.lhs);
        const is_of = c.nodeTag(node) == .for_of_stmt;
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(node)) |s| c.cur_scope = s;

        const rt = try c.checkExprCached(e.right, types.no_type);
        var elem_t: TypeId = types.any_type;
        if (is_of) {
            elem_t = try c.forOfElementType(rt, e.right, e.is_await != 0);
        } else {
            elem_t = types.string_type; // for..in keys
            const rk = c.ts.kind(try c.resolveStructural(rt));
            if (!isNonPrimitiveKind(rk) and rk != .any and rk != .err and rk != .unknown and rk != .type_param) {
                try c.diagFmt(2407, c.nodeSpan(e.right), "The right-hand side of a 'for...in' statement must be of type 'any', an object type or a type parameter, but here has type '{s}'.", .{try c.typeToString(rt)});
            }
        }
        // Bind the left side.
        switch (c.nodeTag(e.left)) {
            .var_decl_one, .var_decl => {
                const ld = c.tree.nodeData(e.left);
                const decl = if (c.nodeTag(e.left) == .var_decl_one) ld.lhs else blk: {
                    const range = c.tree.nodeRange(e.left);
                    break :blk if (range.len > 0) range[0] else null_node;
                };
                if (decl != null_node) {
                    const dd = c.tree.nodeData(decl);
                    switch (c.nodeTag(decl)) {
                        .declarator => {
                            if (c.nodeTag(dd.lhs) == .identifier) {
                                const a = try c.atomOfToken(c.tree.nodeMainToken(dd.lhs));
                                if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
                                    c.setTypeOfSymbol(c.toGlobal(sym), elem_t);
                                }
                            } else {
                                try c.assignPatternFromType(dd.lhs, elem_t);
                            }
                        },
                        .declarator_full => {
                            const ee = c.tree.extraData(ast.DeclaratorFull, dd.rhs);
                            if (ee.type_ann != 0) {
                                const ann = try c.typeFromTypeNode(ee.type_ann);
                                _ = try c.checkAssignable(elem_t, ann, 0, c.nodeSpan(dd.lhs));
                            }
                            try c.materializePatternTypes(dd.lhs);
                        },
                        else => {},
                    }
                }
            },
            else => _ = try c.checkExprCached(e.left, types.no_type),
        }
        try c.checkStatement(d.rhs);
    }

    /// Pre-set the types of identifiers bound in a destructuring pattern
    /// from the element type (for-of patterns).
    fn assignPatternFromType(c: *Checker, pat: Node, whole: TypeId) Error!void {
        if (pat == null_node) return;
        switch (c.nodeTag(pat)) {
            .identifier => {
                const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
                if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), whole);
            },
            .object_pattern => {
                for (c.tree.nodeRange(pat)) |el| {
                    if (el == null_node) continue;
                    const ed = c.tree.nodeData(el);
                    if (c.nodeTag(el) == .binding_property) {
                        const key = try c.memberAtom(c.tree.nodeMainToken(el));
                        var pt: TypeId = types.any_type;
                        if (try c.propOfType(try c.resolveStructural(whole), key)) |p| pt = p.ty;
                        if (ed.lhs != 0) {
                            try c.assignPatternFromType(ed.lhs, pt);
                        } else {
                            const a = try c.memberAtom(c.tree.nodeMainToken(el));
                            if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), pt);
                        }
                    }
                }
            },
            .array_pattern => {
                const r = try c.resolveStructural(whole);
                var i: u32 = 0;
                for (c.tree.nodeRange(pat)) |el| {
                    if (el == null_node) continue;
                    defer i += 1;
                    var et: TypeId = types.any_type;
                    switch (c.ts.kind(r)) {
                        .array => et = c.ts.arrayElem(r),
                        .tuple => {
                            if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                        },
                        else => {},
                    }
                    try c.assignPatternFromType(el, et);
                }
            },
            .binding_default => try c.assignPatternFromType(c.tree.nodeData(pat).lhs, whole),
            .rest_element => try c.assignPatternFromType(c.tree.nodeData(pat).lhs, try c.ts.makeArray(whole)),
            else => {},
        }
    }

    /// Element type of `for (x of expr)`, diagnosing TS2488 when `expr` is not
    /// iterable. Arrays/tuples/strings resolve directly; everything else goes
    /// through the `[Symbol.iterator]()` protocol (`iterationElementType`).
    fn forOfElementType(c: *Checker, rt: TypeId, right_node: Node, is_await: bool) Error!TypeId {
        if (is_await) {
            if (try c.asyncIterationElementType(rt)) |e| return e;
            if (right_node != 0) {
                try c.diagFmt(2504, c.nodeSpan(right_node), "Type '{s}' must have a '[Symbol.asyncIterator]()' method that returns an async iterator.", .{try c.typeToString(rt)});
            }
            return types.any_type;
        }
        if (try c.iterationElementType(rt)) |e| return e;
        if (right_node != 0) {
            try c.diagFmt(2488, c.nodeSpan(right_node), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{try c.typeToString(rt)});
        }
        return types.any_type;
    }

    /// The type produced by iterating `rt` (the `x` in `for (x of rt)` and the
    /// element of `[...rt]`), or null when `rt` is not iterable. Handles
    /// arrays/tuples/strings directly, `Generator`/`Iterator`/`IterableIterator`
    /// refs, and the general `[Symbol.iterator]() -> { next(): { value } }`
    /// protocol (so `Map`/`Set` and user-defined iterables work).
    fn iterationElementType(c: *Checker, rt: TypeId) Error!?TypeId {
        const r = try c.resolveStructural(rt);
        switch (c.ts.kind(r)) {
            .array => return c.ts.arrayElem(r),
            .tuple => return try c.numberIndexType(r),
            .string, .string_literal => return types.string_type,
            .any, .err => return types.any_type,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(r)) |m| {
                    const e = (try c.iterationElementType(m)) orelse return null;
                    try parts.append(c.scratch(), e);
                }
                return try c.ts.makeUnion(c.scratch(), parts.items);
            },
            else => {},
        }
        // `[Symbol.iterator](): Iterator<E>` protocol.
        if (try c.propOfType(r, c.atom_sym_iterator)) |p| {
            const ret = try c.callableReturn(p.ty);
            if (ret != 0) {
                // Lib iterables return `IterableIterator<E>`/`Iterator<E>`.
                const y2 = c.generatorYieldType(ret);
                if (y2 != 0) return y2;
                // General protocol: the iterator's `next()` result `value`.
                if (try c.iteratorNextValue(ret, false)) |v| return v;
            }
        }
        return null;
    }

    /// The type produced by `for await (x of rt)`: the
    /// `[Symbol.asyncIterator]()` protocol, falling back to the sync protocol
    /// with `Awaited<…>` applied to the element (tsc allows `for await` over
    /// a plain iterable). Null when `rt` is neither.
    fn asyncIterationElementType(c: *Checker, rt: TypeId) Error!?TypeId {
        const r = try c.resolveStructural(rt);
        switch (c.ts.kind(r)) {
            .any, .err => return types.any_type,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(r)) |m| {
                    const e = (try c.asyncIterationElementType(m)) orelse return null;
                    try parts.append(c.scratch(), e);
                }
                return try c.ts.makeUnion(c.scratch(), parts.items);
            },
            else => {},
        }
        if (try c.propOfType(r, c.atom_sym_asyncIterator)) |p| {
            const ret = try c.callableReturn(p.ty);
            if (ret != 0) {
                const y = c.asyncGeneratorYieldType(ret);
                if (y != 0) return y;
                if (try c.iteratorNextValue(ret, true)) |v| return v;
            }
            return null;
        }
        if (try c.iterationElementType(rt)) |e| return try c.awaitedType(e);
        return null;
    }

    /// Return type of a callable prop (`.function` or the first `.overloads`
    /// signature); 0 if `ty` is not callable.
    fn callableReturn(c: *Checker, ty: TypeId) Error!TypeId {
        switch (c.ts.kind(ty)) {
            .function => return c.ts.fnReturn(ty),
            .overloads => {
                const sigs = try c.memberList(ty);
                return if (sigs.len > 0) c.ts.fnReturn(sigs[0]) else 0;
            },
            else => return 0,
        }
    }

    /// The `value` type of an iterator's `next()` result, i.e. the yield type
    /// of an arbitrary (non-lib-named) iterator object. Null if `iter` has no
    /// `next(): { value }` shape. With `is_async`, `next()`'s `Promise<…>`
    /// return is unwrapped first (the `AsyncIterator` protocol).
    fn iteratorNextValue(c: *Checker, iter: TypeId, is_async: bool) Error!?TypeId {
        const r = try c.resolveStructural(iter);
        const nextp = (try c.propOfType(r, c.atom_next)) orelse return null;
        var ret = try c.callableReturn(nextp.ty);
        if (ret == 0) return null;
        if (is_async) ret = try c.awaitedType(ret);
        const rr = try c.resolveStructural(ret);
        if (c.ts.kind(rr) == .union_type) {
            // The lib's `next(): IteratorResult<T, TReturn>` is the union
            // `IteratorYieldResult<T> | IteratorReturnResult<TReturn>`,
            // discriminated on `done`: the iteration type is the `value` of
            // the constituents whose `done` is not literally `true`.
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(rr)) |m| {
                const rm = try c.resolveStructural(m);
                if (try c.propOfType(rm, c.atom_done)) |dp| {
                    if (c.ts.kind(try c.resolveStructural(dp.ty)) == .bool_true) continue;
                }
                const vp = (try c.propOfType(rm, c.atom_value)) orelse continue;
                try parts.append(c.scratch(), vp.ty);
            }
            if (parts.items.len == 0) return null;
            return try c.ts.makeUnion(c.scratch(), parts.items);
        }
        const valp = (try c.propOfType(rr, c.atom_value)) orelse return null;
        return valp.ty;
    }

    fn checkSwitch(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const disc_t = try c.checkExprCached(d.lhs, types.no_type);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(node)) |s| c.cur_scope = s;
        const r = c.tree.extraData(ast.SubRange, d.rhs);
        for (c.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node) continue;
            const cd = c.tree.nodeData(clause);
            if (c.nodeTag(clause) == .case_clause and cd.lhs != 0) {
                const case_t = try c.checkExprCached(cd.lhs, types.no_type);
                if (!try c.isComparable(case_t, disc_t)) {
                    try c.diagFmt(2678, c.nodeSpan(cd.lhs), "Type '{s}' is not comparable to type '{s}'.", .{
                        try c.typeToString(case_t), try c.typeToString(disc_t),
                    });
                }
            }
            const cr = c.tree.extraData(ast.SubRange, cd.rhs);
            for (c.tree.extraRange(cr.start, cr.end)) |stmt| try c.checkStatement(stmt);
        }
    }

    fn checkReturn(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const ctx = c.fn_ctx orelse {
            if (d.lhs != 0) _ = try c.checkExprCached(d.lhs, types.no_type);
            return;
        };
        if (d.lhs != 0) {
            const rt = try c.checkExprCached(d.lhs, ctx.ret_ann);
            // async: `return v` in a `Promise<T>` relates the awaited `v` to the
            // payload `T` (so `return somePromise` is not double-wrapped).
            const eff_rt = if (ctx.is_async) try c.awaitedType(rt) else rt;
            if (ctx.ret_ann != types.no_type and ctx.ret_ann != types.error_type and
                ctx.ret_ann != types.any_type and c.ts.kind(ctx.ret_ann) != .none)
            {
                _ = try c.checkAssignable(eff_rt, ctx.ret_ann, d.lhs, c.nodeSpan(d.lhs));
            }
        } else if (ctx.ret_ann != types.no_type) {
            const k = c.ts.kind(ctx.ret_ann);
            const allows_bare = k == .void or k == .any or k == .unknown or k == .err or k == .none or
                c.containsUndefinedish(ctx.ret_ann);
            if (!allows_bare) {
                try c.diagFmt(2322, c.nodeSpan(node), "Type 'undefined' is not assignable to type '{s}'.", .{try c.typeToString(ctx.ret_ann)});
            }
        }
    }

    fn checkFunctionDecl(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        // Builds the signature (reports 7006 etc. once).
        _ = try c.signatureOfProto(node, d.lhs, false, true);
        if (d.rhs != 0) {
            const sig = try c.signatureOfProto(node, d.lhs, false, true);
            try c.checkFunctionBody(node, d.lhs, d.rhs, sig);
        }
    }

    fn checkFunctionBody(c: *Checker, node: Node, proto_idx: u32, body: Node, sig: TypeId) Error!void {
        if (body == 0) return;
        const proto = c.tree.extraData(ast.FnProto, proto_idx);
        const saved_scope = c.cur_scope;
        const saved_ctx = c.fn_ctx;
        const saved_this = c.this_type;
        defer {
            c.cur_scope = saved_scope;
            c.fn_ctx = saved_ctx;
            c.this_type = saved_this;
        }
        if (try c.scopeOf(node)) |s| c.cur_scope = s;
        // An explicit `this` parameter types `this` inside the body.
        if (c.ts.kind(sig) == .function) {
            const tt = c.ts.fnThisType(sig);
            if (tt != 0) c.this_type = tt;
        }
        const is_async = proto.flags & ast.Flags.async != 0;
        const is_generator = proto.flags & ast.Flags.generator != 0;
        const ann: TypeId = if (proto.return_type != 0) try c.typeFromTypeNode(proto.return_type) else types.no_type;
        // Effective return-check target. For async this is the awaited payload
        // `T` of the declared `Promise<T>`; a non-Promise annotation is TS1064.
        var eff_ann = ann;
        var yield_type: TypeId = 0;
        if (is_async and is_generator) {
            // `async function*`: annotated with an AsyncGenerator-family type,
            // not Promise — TS1064 does not apply. Relate `yield x` to its
            // first type arg (yielded promises are awaited at the yield site).
            yield_type = c.asyncGeneratorYieldType(ann);
            eff_ann = types.no_type;
        } else if (is_async and ann != types.no_type) {
            const k = c.ts.kind(ann);
            const is_promise = c.ts.kind(ann) == .ref and c.prog.globals.lookup(c.atom_Promise) != null and
                c.ts.refSymbol(ann) == c.prog.globals.lookup(c.atom_Promise).?;
            if (is_promise) {
                eff_ann = try c.awaitedType(ann);
            } else if (k != .err and k != .none) {
                try c.diagFmt(1064, c.nodeSpan(proto.return_type), "The return type of an async function or method must be the global Promise<T> type. Did you mean to write 'Promise<{s}>'?", .{try c.typeToString(ann)});
                eff_ann = types.no_type; // suppress payload assignability noise
            }
        } else if (is_generator) {
            // Generators: relate `yield x` to `T` from `Generator<T>`; return
            // values (→ TReturn) are unchecked (gap).
            yield_type = c.generatorYieldType(ann);
            eff_ann = types.no_type;
        }
        c.fn_ctx = .{ .ret_ann = eff_ann, .is_async = is_async, .is_generator = is_generator, .yield_type = yield_type };

        // Check parameter initializers against annotations.
        for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
            if (pn == null_node or c.nodeTag(pn) != .param_full) continue;
            const pd = c.tree.nodeData(pn);
            const e = c.tree.extraData(ast.ParamFull, pd.rhs);
            if (e.init != 0 and e.type_ann != 0) {
                const ann_t = try c.typeFromTypeNode(e.type_ann);
                const it = try c.checkExprCached(e.init, ann_t);
                _ = try c.checkAssignable(it, ann_t, e.init, c.nodeSpan(e.init));
            } else if (e.init != 0) {
                _ = try c.checkExprCached(e.init, types.no_type);
            }
        }

        if (c.nodeTag(body) == .block) {
            for (c.tree.nodeRange(body)) |stmt| try c.checkStatement(stmt);
            // Ending-return analysis (TS2355/2366). For async the target is the
            // Promise payload; generators do not require an ending return.
            if (!is_generator and eff_ann != types.no_type and eff_ann != types.error_type) {
                const k = c.ts.kind(eff_ann);
                const exempt = k == .void or k == .any or k == .err or k == .unknown or k == .none or
                    c.containsUndefinedish(eff_ann);
                if (!exempt) {
                    var rets: std.ArrayList(Node) = .empty;
                    defer rets.deinit(c.scratch());
                    var bare = false;
                    for (c.tree.nodeRange(body)) |stmt| {
                        if (stmt != null_node) try c.collectReturns(stmt, &rets, null, &bare, binder.file_scope);
                    }
                    const span = if (proto.name_token != 0) c.tokSpan(proto.name_token) else c.tokSpan(c.tree.nodeMainToken(node));
                    if (!c.stmtListTerminal(c.tree.nodeRange(body))) {
                        if (rets.items.len == 0 and !bare) {
                            try c.diagFmt(2355, span, "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.", .{});
                        } else {
                            try c.diagFmt(2366, span, "Function lacks ending return statement and return type does not include 'undefined'.", .{});
                        }
                    }
                }
            }
        } else {
            // Arrow expression body. For async, relate the awaited body type to
            // the Promise payload (`async () => p` returns `Promise<T>`).
            const rt = try c.checkExprCached(body, eff_ann);
            if (eff_ann != types.no_type and eff_ann != types.error_type) {
                const eff_rt = if (is_async) try c.awaitedType(rt) else rt;
                _ = try c.checkAssignable(eff_rt, eff_ann, body, c.nodeSpan(body));
            }
        }
    }

    // --- syntactic reachability (2366/return-undefined inference) ---------

    fn stmtListTerminal(c: *Checker, stmts: []const Node) bool {
        // Does control flow fall off the end of this list? Walk forward tracking
        // reachability: the first terminal statement (return/throw/terminal
        // loop…) kills it, and straight-line code never revives it. A terminal
        // statement in the *middle* therefore makes the whole list terminal —
        // trailing dead code or a hoisted `function`/type declaration after a
        // `return` does not resurrect the endpoint (the previous "inspect the
        // last statement only" rule wrongly did, adding a phantom `| undefined`
        // to the inferred return type of the common
        // `return { … }; function helper() {…}` hook pattern).
        var reachable = true;
        for (stmts) |s| {
            if (s == null_node or !reachable) continue;
            if (c.stmtTerminal(s)) reachable = false;
        }
        return !reachable;
    }

    fn stmtTerminal(c: *Checker, node: Node) bool {
        const d = c.tree.nodeData(node);
        switch (c.nodeTag(node)) {
            .return_stmt, .throw_stmt => return true,
            .block => return c.stmtListTerminal(c.tree.nodeRange(node)),
            .if_else_stmt => {
                const e = c.tree.extraData(ast.IfElse, d.rhs);
                return c.stmtTerminal(e.then_stmt) and c.stmtTerminal(e.else_stmt);
            },
            .labeled_stmt => return c.stmtTerminal(d.lhs),
            .try_stmt => {
                const e = c.tree.extraData(ast.Try, d.rhs);
                // A `finally` that itself ends abruptly (return/throw) makes the
                // whole statement terminal regardless of the try/catch bodies.
                if (e.finally_block != null_node and c.stmtTerminal(e.finally_block)) return true;
                // Otherwise the statement can complete normally if the try block
                // can, or — when a catch exists — if the catch block can. It is
                // terminal only when neither falls through.
                const try_terminal = c.stmtTerminal(d.lhs);
                if (e.catch_clause != null_node) {
                    const catch_block = c.tree.nodeData(e.catch_clause).rhs;
                    return try_terminal and c.stmtTerminal(catch_block);
                }
                return try_terminal;
            },
            .switch_stmt => return c.switchTerminal(node),
            .while_stmt => {
                // while (true) without break is terminal-ish.
                if (c.nodeTag(d.lhs) == .true_literal and !c.containsBreak(d.rhs)) return true;
                return false;
            },
            .for_stmt => {
                const e = c.tree.extraData(ast.For, d.lhs);
                if (e.cond == 0 and !c.containsBreak(d.rhs)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// A switch is terminal if it has a default (or is exhaustive over a
    /// literal-union discriminant), every clause ends terminally, and no
    /// clause breaks out.
    fn switchTerminal(c: *Checker, node: Node) bool {
        const d = c.tree.nodeData(node);
        const r = c.tree.extraData(ast.SubRange, d.rhs);
        var has_default = false;
        var n_cases: usize = 0;
        for (c.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node) continue;
            const cd = c.tree.nodeData(clause);
            if (c.nodeTag(clause) == .default_clause) has_default = true else n_cases += 1;
            const cr = c.tree.extraData(ast.SubRange, cd.rhs);
            const stmts = c.tree.extraRange(cr.start, cr.end);
            for (stmts) |s| {
                if (s != null_node and c.containsBreak(s)) return false;
            }
            // A clause with statements must end terminally (empty clauses
            // fall through to the next).
            var has_stmt = false;
            for (stmts) |s| {
                if (s != null_node) has_stmt = true;
            }
            if (has_stmt and !c.stmtListTerminal(stmts)) return false;
        }
        if (has_default) return true;
        // Exhaustiveness: discriminant type's union members all covered.
        return c.switchIsExhaustive(node);
    }

    fn switchIsExhaustive(c: *Checker, node: Node) bool {
        const d = c.tree.nodeData(node);
        // switch (typeof x): exhaustive when every typeof outcome of x's
        // type is covered by a case string.
        if (c.nodeTag(d.lhs) == .prefix_unary and
            c.tree.tokens.tag(c.tree.nodeMainToken(d.lhs)) == .keyword_typeof)
        {
            return c.typeofSwitchIsExhaustive(node, c.tree.nodeData(d.lhs).lhs);
        }
        const disc_t0 = c.nodeType(d.lhs) orelse return false;
        const disc_t = disc_t0;
        if (c.ts.kind(disc_t) != .union_type) return false;
        const r = c.tree.extraData(ast.SubRange, d.rhs);
        for (c.ts.members(disc_t)) |m| {
            const rm = c.ts.regularLiteral(m) catch return false;
            if (c.ts.literalBase(rm) == types.no_type and
                c.ts.kind(rm) != .null and c.ts.kind(rm) != .undefined) return false;
            var covered = false;
            for (c.tree.extraRange(r.start, r.end)) |clause| {
                if (clause == null_node or c.nodeTag(clause) != .case_clause) continue;
                const test_node = c.tree.nodeData(clause).lhs;
                if (test_node == 0) continue;
                const tt0 = c.nodeType(test_node) orelse continue;
                const tt = c.ts.regularLiteral(tt0) catch continue;
                if (tt == rm) covered = true;
            }
            if (!covered) return false;
        }
        return true;
    }

    fn typeofSwitchIsExhaustive(c: *Checker, sw: Node, operand: Node) bool {
        const t = c.nodeType(operand) orelse return false;
        const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
        // For each possible typeof outcome of t, require a covering case.
        for (0..typeof_names.len) |which| {
            var possible = false;
            if (c.ts.kind(t) == .union_type) {
                for (c.ts.members(t)) |m| {
                    if (c.typeofMatches(m, which)) possible = true;
                }
            } else {
                possible = c.typeofMatches(t, which);
            }
            if (!possible) continue;
            var covered = false;
            for (c.tree.extraRange(r.start, r.end)) |clause| {
                if (clause == null_node or c.nodeTag(clause) != .case_clause) continue;
                const test_node = c.tree.nodeData(clause).lhs;
                if (test_node == 0) continue;
                const tt0 = c.nodeType(test_node) orelse continue;
                const tt = c.ts.regularLiteral(tt0) catch continue;
                if (c.ts.kind(tt) != .string_literal) continue;
                if (c.ts.literalAtom(tt) == c.typeof_atoms[which]) covered = true;
            }
            if (!covered) return false;
        }
        return true;
    }

    fn containsBreak(c: *Checker, node: Node) bool {
        if (node == null_node) return false;
        switch (c.nodeTag(node)) {
            .break_stmt => return true,
            // Breaks inside nested loops/switches target those.
            .while_stmt, .do_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => return false,
            .arrow_fn, .function_expr, .function_decl, .class_decl => return false,
            else => {},
        }
        var it = c.tree.childIterator(node);
        while (it.next()) |child| {
            if (c.containsBreak(child)) return true;
        }
        return false;
    }

    // --- classes / interfaces / aliases ------------------------------------

    /// Check a namespace body: enter the (merged) namespace scope and check
    /// each body statement there. Member visibility/typing is materialized by
    /// classStaticType (value) and typeFromQualifiedName (type).
    fn checkNamespace(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const data = c.tree.extraData(ast.NamespaceData, d.lhs);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        // The body scope is the one owned by this node, or — for a merged
        // block whose scope is owned by an earlier block — the namespace
        // symbol's members scope.
        if (try c.scopeOf(node)) |s| {
            c.cur_scope = s;
        } else if (data.name_token != 0) {
            const a = try c.atomOfToken(data.name_token);
            if (c.bind.lookupInScope(saved, a)) |sym| {
                if (c.bind.namespaceScopeOf(sym)) |ns| c.cur_scope = ns;
            }
        }
        for (c.tree.extraRange(data.body_start, data.body_end)) |stmt| {
            if (stmt != null_node) try c.checkStatement(stmt);
        }
    }

    fn checkClass(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const data = c.tree.extraData(ast.ClassData, d.lhs);
        const saved_scope = c.cur_scope;
        const saved_this = c.this_type;
        defer {
            c.cur_scope = saved_scope;
            c.this_type = saved_this;
        }
        if (try c.scopeOf(node)) |s| c.cur_scope = s;

        var class_sym: SymbolId = binder.no_symbol;
        if (data.name_token != 0) {
            const a = try c.atomOfToken(data.name_token);
            if (c.bind.lookupInScope(saved_scope, a)) |sym| {
                if (c.bind.symbol_flags[sym].class) class_sym = c.toGlobal(sym);
            }
        }

        // Instance type for `this` (generic: tp refs as args).
        var this_t: TypeId = types.any_type;
        if (class_sym != binder.no_symbol) {
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(class_sym, &tps);
            var args = try c.scratch().alloc(TypeId, tps.items.len);
            for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
            this_t = try c.ts.makeRef(class_sym, args);
            // Eagerly expand so member diagnostics (7006, bad annotations)
            // fire even for unused classes.
            _ = try c.resolveStructural(this_t);
            _ = try c.classStaticType(class_sym);
            try c.evalTypeParamDecls(class_sym);
        }

        // Class-position decorators (`@deco class C {}`): evaluated in the
        // scope surrounding the class, with the enclosing `this`. Snapshot and
        // clear the pending set first so a nested decorated class inside a
        // member body cannot re-consume them.
        if (c.pending_class_decos.items.len > 0) {
            const decos = try c.scratch().dupe(Node, c.pending_class_decos.items);
            c.pending_class_decos.clearRetainingCapacity();
            const saved_ds = c.cur_scope;
            c.cur_scope = saved_scope;
            c.this_type = saved_this;
            const class_val: TypeId = if (class_sym != binder.no_symbol)
                try c.ts.makeClassValue(class_sym)
            else
                types.any_type;
            for (decos) |deco| {
                const dt = try c.checkDecorator(deco);
                try c.checkDecoratorSig(deco, dt, .class, class_val);
            }
            c.cur_scope = saved_ds;
        }

        // extends: base must be a class (checked in baseClassRef); type
        // args arity checked there too.
        if (class_sym != binder.no_symbol and data.extends != 0) {
            _ = try c.baseClassRef(class_sym);
            const hd = c.tree.nodeData(data.extends);
            _ = try c.checkExprCached(hd.lhs, types.no_type);
        }

        // implements clauses: instance assignable to each interface.
        if (class_sym != binder.no_symbol) {
            for (c.tree.extraRange(data.impl_start, data.impl_end)) |h| {
                if (h == null_node or c.nodeTag(h) != .heritage) continue;
                const hd = c.tree.nodeData(h);
                var targs: std.ArrayList(TypeId) = .empty;
                defer targs.deinit(c.scratch());
                if (hd.rhs != 0) {
                    const rr = c.tree.extraData(ast.SubRange, hd.rhs);
                    for (c.tree.extraRange(rr.start, rr.end)) |an| {
                        if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                    }
                }
                const iface = try c.typeFromTypeName(hd.lhs, targs.items);
                if (iface != types.error_type and iface != types.any_type) {
                    if (!try c.isAssignable(this_t, iface)) {
                        try c.diagFmt(2420, c.nodeSpan(hd.lhs), "Class '{s}' incorrectly implements interface '{s}'.", .{
                            c.symbolName(class_sym), try c.typeToString(iface),
                        });
                    }
                }
            }
        }

        // A concrete class must implement inherited abstract members.
        if (class_sym != binder.no_symbol) try c.checkAbstractImplementation(class_sym, node);

        const class_is_abstract = data.flags & ast.Flags.abstract != 0;

        // Members.
        const members = c.tree.extraRange(data.members_start, data.members_end);
        for (members, 0..) |member, mi| {
            if (member == null_node) continue;
            const md = c.tree.nodeData(member);
            switch (c.nodeTag(member)) {
                .class_field => {
                    const e = c.tree.extraData(ast.Field, md.lhs);
                    const is_static = e.flags & ast.Flags.static != 0;
                    if (e.flags & ast.Flags.abstract != 0 and !class_is_abstract) {
                        try c.diagFmt(1244, c.tokSpan(c.tree.nodeMainToken(member)), "Abstract properties can only appear within an abstract class.", .{});
                    }
                    c.this_type = if (is_static and class_sym != binder.no_symbol)
                        try c.ts.makeClassValue(class_sym)
                    else
                        this_t;
                    var ann: TypeId = types.no_type;
                    if (e.type_ann != 0) {
                        const ok = is_static and e.flags & ast.Flags.readonly != 0;
                        ann = try c.annTypeMaybeUnique(e.type_ann, ok, 1331, c.tokSpan(c.tree.nodeMainToken(member)));
                    }
                    // A `unique symbol` static-readonly field, like a const,
                    // takes only a fresh `Symbol()` initializer without TS2322.
                    if (e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and e.init != 0 and c.isFreshSymbolCall(e.init)) {
                        _ = try c.checkExprCached(e.init, ann);
                        continue;
                    }
                    if (e.init != 0) {
                        const it = try c.checkExprCached(e.init, ann);
                        if (ann != types.no_type and ann != types.error_type) {
                            _ = try c.checkAssignable(it, ann, e.init, c.tokSpan(c.tree.nodeMainToken(member)));
                        }
                    }
                },
                .class_method => {
                    const proto = c.tree.extraData(ast.FnProto, md.lhs);
                    const is_static = proto.flags & ast.Flags.static != 0;
                    const is_abstract = proto.flags & ast.Flags.abstract != 0;
                    if (is_abstract and !class_is_abstract) {
                        try c.diagFmt(1244, c.tokSpan(c.tree.nodeMainToken(member)), "Abstract methods can only appear within an abstract class.", .{});
                    }
                    if (is_abstract and md.rhs != 0) {
                        try c.diagFmt(1245, c.tokSpan(c.tree.nodeMainToken(member)), "Method '{s}' cannot have an implementation because it is marked abstract.", .{c.tokenText(c.tree.nodeMainToken(member))});
                    }
                    c.this_type = if (is_static and class_sym != binder.no_symbol)
                        try c.ts.makeClassValue(class_sym)
                    else
                        this_t;
                    const sig = try c.signatureOfProto(member, md.lhs, true, true);
                    if (md.rhs != 0) {
                        const is_ctor = !is_static and c.isCtorName(try c.memberAtom(c.tree.nodeMainToken(member)));
                        const saved_ctor = c.ctor_class_sym;
                        if (is_ctor) c.ctor_class_sym = class_sym;
                        defer c.ctor_class_sym = saved_ctor;
                        try c.checkFunctionBody(member, md.lhs, md.rhs, sig);
                    }
                },
                .decorator => {
                    // A member decorator expression is evaluated in the scope
                    // surrounding the class (at class-definition time), so its
                    // `this` is the enclosing `this`, not the instance.
                    c.this_type = saved_this;
                    const dt = try c.checkDecorator(member);
                    // The decorated member is the next non-decorator member.
                    var target: Node = null_node;
                    var k = mi + 1;
                    while (k < members.len) : (k += 1) {
                        if (members[k] != null_node and c.nodeTag(members[k]) != .decorator) {
                            target = members[k];
                            break;
                        }
                    }
                    if (target != null_node) try c.checkMemberDecoratorSig(member, dt, target, this_t, class_sym);
                },
                else => {},
            }
        }
    }

    /// Type-check a decorator expression (`@expr`) and return its type.
    /// Standard decorators name-resolve and type-check the expression: an
    /// undefined name ⇒ TS2304, and the callee/args of a factory `@f(args)`
    /// are checked. The returned type is the decorator function itself (for a
    /// factory, the call's return type) — the value `checkDecoratorSig` relates
    /// against the expected context-typed decorator signature.
    fn checkDecorator(c: *Checker, node: Node) Error!TypeId {
        const expr = c.tree.nodeData(node).lhs;
        if (expr == null_node) return types.any_type;
        return c.checkExprCached(expr, types.no_type);
    }

    /// The position a decorator is applied to. Drives which TS12xx code and
    /// which `Class*DecoratorContext` shape apply (tsc §checkDecorators).
    const DecoPos = enum { class, method, getter, setter, field, accessor };

    fn decoCode(pos: DecoPos) u16 {
        return switch (pos) {
            .class => 1238, // class decorator
            .field, .accessor => 1240, // property decorator
            .method, .getter, .setter => 1241, // method decorator
        };
    }

    fn decoContextName(pos: DecoPos) []const u8 {
        return switch (pos) {
            .class => "ClassDecoratorContext",
            .method => "ClassMethodDecoratorContext",
            .getter => "ClassGetterDecoratorContext",
            .setter => "ClassSetterDecoratorContext",
            .field => "ClassFieldDecoratorContext",
            .accessor => "ClassAccessorDecoratorContext",
        };
    }

    /// Signature check for a class-member decorator: classify the member's
    /// position, build the `value` argument type tsc synthesizes for it, and
    /// relate the decorator against the expected context-typed signature.
    fn checkMemberDecoratorSig(c: *Checker, deco: Node, dt: TypeId, target: Node, this_t: TypeId, class_sym: SymbolId) Error!void {
        const md = c.tree.nodeData(target);
        var pos: DecoPos = .method;
        var value: TypeId = types.any_type;
        switch (c.nodeTag(target)) {
            .class_field => {
                const e = c.tree.extraData(ast.Field, md.lhs);
                if (e.flags & ast.Flags.accessor != 0) {
                    pos = .accessor;
                    // `accessor x` decorators receive a
                    // `ClassAccessorDecoratorTarget<This, Value>`.
                    value = c.decoContextRef("ClassAccessorDecoratorTarget");
                } else {
                    pos = .field;
                    // Field decorators receive `undefined` as the value.
                    value = types.undefined_type;
                }
            },
            .class_method => {
                const proto = c.tree.extraData(ast.FnProto, md.lhs);
                if (proto.flags & ast.Flags.get != 0) {
                    pos = .getter;
                } else if (proto.flags & ast.Flags.set != 0) {
                    pos = .setter;
                } else {
                    pos = .method;
                }
                const is_static = proto.flags & ast.Flags.static != 0;
                const saved = c.this_type;
                c.this_type = if (is_static and class_sym != binder.no_symbol)
                    try c.ts.makeClassValue(class_sym)
                else
                    this_t;
                // The value is the member's own function type. Suppress TS7006
                // here — the member's own pass reports implicit-any.
                value = c.signatureOfProto(target, md.lhs, true, false) catch types.any_type;
                c.this_type = saved;
            },
            else => return,
        }
        try c.checkDecoratorSig(deco, dt, pos, value);
    }

    /// Build a `.ref` to a decorator-family lib interface by name (default
    /// type args), or `any` when absent (e.g. `--noLib`).
    fn decoContextRef(c: *Checker, name: []const u8) TypeId {
        const a = c.atom(name) catch return types.any_type;
        const sym = c.prog.globals.lookup(a) orelse return types.any_type;
        if (!c.symFlags(sym).interface) return types.any_type;
        return c.ts.makeRef(sym, &.{}) catch types.any_type;
    }

    /// Relate a decorator against the expected `(value, context) => …` shape
    /// for its position and emit TS1238/1240/1241 when no call signature fits
    /// (tsc: "Unable to resolve signature of … decorator when called as an
    /// expression."). Policy: under-report freely, never a false positive —
    /// generic decorators and any/unknown parameter types are always accepted,
    /// and the `value`/`context` relations run only where a mismatch is
    /// unambiguous.
    fn checkDecoratorSig(c: *Checker, deco: Node, dt: TypeId, pos: DecoPos, value: TypeId) Error!void {
        const r = try c.resolveStructural(dt);
        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        switch (c.ts.kind(r)) {
            .any, .unknown, .err => return, // permissive: no reliable shape
            .function => try sigs.append(c.scratch(), r),
            .overloads => {
                for (try c.memberList(r)) |m| try sigs.append(c.scratch(), m);
            },
            .object => {
                if (c.ts.objectCallSigCount(r) == 0) return; // non-callable: under-report
                for (0..c.ts.objectCallSigCount(r)) |i| {
                    try sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
                }
            },
            else => return, // not callable in a shape we model: under-report
        }
        if (sigs.items.len == 0) return;

        // Expected context interface for this position (null under --noLib →
        // context relation is skipped, value/arity relation still applies).
        const ctx_atom = c.atom(decoContextName(pos)) catch 0;
        const ctx_sym: ?SymbolId = if (ctx_atom != 0) c.prog.globals.lookup(ctx_atom) else null;

        for (sigs.items) |sig| {
            if (try c.decoSigMatches(sig, pos, value, ctx_sym)) return; // some overload fits
        }
        const expr = c.tree.nodeData(deco).lhs;
        const span = if (expr != null_node) c.nodeSpan(expr) else c.nodeSpan(deco);
        try c.diagFmt(decoCode(pos), span, "Unable to resolve signature of {s} decorator when called as an expression.", .{switch (pos) {
            .class => "class",
            .field, .accessor => "property",
            .method, .getter, .setter => "method",
        }});
    }

    /// Does one decorator call signature accept the runtime `(value, context)`
    /// call? Conservative: a generic signature or any indeterminate parameter
    /// is treated as a match (under-report, never a false positive).
    fn decoSigMatches(c: *Checker, sig: TypeId, pos: DecoPos, value: TypeId, ctx_sym: ?SymbolId) Error!bool {
        // Generic decorators need inference we don't model here — accept.
        if (c.ts.fnTypeParams(sig).len > 0) return true;
        // The runtime invokes a decorator with 2 arguments; a signature that
        // *requires* more can never resolve (tsc: "expects N").
        if (try c.requiredParams(sig) > 2) return false;
        // Value argument vs the first parameter.
        if (c.paramTypeAt(sig, 0)) |p0| {
            if (!try c.decoAcceptsValue(pos, value, p0)) return false;
        }
        // Context argument vs the second parameter: fail only on an
        // unambiguous decorator-context kind mismatch.
        if (ctx_sym != null) {
            if (c.paramTypeAt(sig, 1)) |p1| {
                if (c.decoContextMismatch(p1, ctx_sym.?)) return false;
            }
        }
        return true;
    }

    /// True if `value` is acceptable as the first decorator argument for `p0`.
    /// Permissive supertypes (`any`/`unknown`/`object`/`Function`, a matching
    /// context/target ref, or a constructor-typed parameter for a class
    /// decorator) are accepted without an assignability probe so an incomplete
    /// relation cannot produce a false positive.
    fn decoAcceptsValue(c: *Checker, pos: DecoPos, value: TypeId, p0: TypeId) Error!bool {
        switch (c.ts.kind(p0)) {
            .any, .unknown, .err, .object_keyword => return true,
            .ref => {
                const psym = c.ts.refSymbol(p0);
                if (c.globalSymNamed(psym, "Function")) return true;
                if (pos == .accessor and c.globalSymNamed(psym, "ClassAccessorDecoratorTarget")) return true;
            },
            .object => {
                // A constructor-typed parameter accepts a class value.
                if (pos == .class and c.ts.objectConstructSigCount(p0) > 0) return true;
            },
            else => {},
        }
        if (value == 0 or value == types.error_type or value == types.any_type) return true;
        return c.isAssignable(value, p0);
    }

    /// True when `p1` is a ref to a *different* decorator-context interface
    /// than expected (e.g. `ClassMethodDecoratorContext` where a class
    /// decorator wants `ClassDecoratorContext`). Anything else (a union like
    /// `DecoratorContext`, `any`, an unrelated type) is accepted.
    fn decoContextMismatch(c: *Checker, p1: TypeId, ctx_sym: SymbolId) bool {
        if (c.ts.kind(p1) != .ref) return false;
        const psym = c.ts.refSymbol(p1);
        const family = [_][]const u8{
            "ClassDecoratorContext",       "ClassMethodDecoratorContext",
            "ClassGetterDecoratorContext", "ClassSetterDecoratorContext",
            "ClassFieldDecoratorContext",  "ClassAccessorDecoratorContext",
        };
        for (family) |name| {
            if (c.globalSymNamed(psym, name)) return psym != ctx_sym;
        }
        return false;
    }

    /// Is `sym` the global interface/type named `name`?
    fn globalSymNamed(c: *Checker, sym: SymbolId, name: []const u8) bool {
        const a = c.atom(name) catch return false;
        const g = c.prog.globals.lookup(a) orelse return false;
        return g == sym;
    }

    fn checkInterfaceDecl(c: *Checker, node: Node) Error!void {
        // Eagerly expand so member-type diagnostics (2304 in bodies, 7006 in
        // method signatures) fire even for unused interfaces.
        const d = c.tree.nodeData(node);
        const data = c.tree.extraData(ast.InterfaceData, d.lhs);
        if (data.name_token == 0) return;
        const a = try c.atomOfToken(data.name_token);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
            if (c.bind.symbol_flags[sym].interface) {
                _ = try c.interfaceGeneric(c.toGlobal(sym));
                try c.evalTypeParamDecls(c.toGlobal(sym));
            }
        }
    }

    fn checkTypeAliasDecl(c: *Checker, node: Node) Error!void {
        const d = c.tree.nodeData(node);
        const data = c.tree.extraData(ast.TypeAlias, d.lhs);
        if (data.name_token == 0) return;
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
            if (c.bind.symbol_flags[sym].type_alias) {
                _ = try c.aliasGeneric(c.toGlobal(sym));
                try c.evalTypeParamDecls(c.toGlobal(sym));
            }
        }
    }

    /// Eagerly evaluate type-parameter constraint/default annotations of a
    /// generic declaration so their diagnostics fire during the owner's
    /// file walk (partition-independent output; lazy paths only reach them
    /// on instantiation).
    fn evalTypeParamDecls(c: *Checker, sym: SymbolId) Error!void {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        for (tps.items) |tp| {
            const saved = c.enterSymFile(sym);
            defer c.restoreCtx(saved);
            c.cur_scope = c.symScope(tp.sym);
            if (tp.constraint != 0) _ = try c.typeFromTypeNode(tp.constraint);
            if (tp.default != 0) _ = try c.typeFromTypeNode(tp.default);
        }
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

const TestCheck = struct {
    arena: std.heap.ArenaAllocator,
    interner: Interner,
    result: Check,

    fn init(src: []const u8) !TestCheck {
        var t: TestCheck = undefined;
        t.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer t.arena.deinit();
        t.interner = Interner.init();
        errdefer t.interner.deinit(testing.allocator);
        const alloc = t.arena.allocator();
        const tree = try alloc.create(Ast);
        tree.* = try parser.parse(alloc, src);
        const bound = try alloc.create(Bind);
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &t.interner, tree, src, false);
        t.result = try check(alloc, testing.io, testing.allocator, &t.interner, tree, bound, src);
        return t;
    }

    fn deinit(t: *TestCheck) void {
        t.interner.deinit(testing.allocator);
        t.arena.deinit();
    }
};

/// Expect exactly these tsc codes, in span order.
fn expectCodes(src: []const u8, expected: []const u16) !void {
    var t = try TestCheck.init(src);
    defer t.deinit();
    var ok = t.result.diagnostics.len == expected.len;
    if (ok) {
        for (expected, t.result.diagnostics) |want, got| {
            if (want != got.code) ok = false;
        }
    }
    if (!ok) {
        std.debug.print("--- source: {s}\n--- got {d} diagnostics:\n", .{ src, t.result.diagnostics.len });
        for (t.result.diagnostics) |dd| {
            std.debug.print("  TS{d} [{d}..{d}] {s}\n", .{ dd.code, dd.span.start, dd.span.end, dd.msg });
        }
        return error.TestExpectedEqual;
    }
}

fn expectClean(src: []const u8) !void {
    try expectCodes(src, &.{});
}

test "smoke: assignability basics" {
    try expectClean("const a: number = 1; const b: string = \"x\"; let c: boolean = true;");
    try expectCodes("const a: string = 1;", &.{2322});
    try expectCodes("let x: number = 1; x = \"nope\";", &.{2322});
}

test "assignability matrix: intrinsics and literals" {
    // literals -> primitives
    try expectClean("const s: string = \"a\"; const n: number = 1; const b: boolean = true;");
    try expectClean("const t: true = true; const u: \"a\" = \"a\"; const v: 1 = 1;");
    try expectCodes("const t: true = false;", &.{2322});
    try expectCodes("const u: \"a\" = \"b\";", &.{2322});
    // null/undefined strictness
    try expectCodes("const n: number = null;", &.{2322});
    try expectCodes("const n: number = undefined;", &.{2322});
    try expectClean("const n: number | null = null;");
    try expectClean("const v: void = undefined;");
    try expectCodes("const u: undefined = null;", &.{2322});
    // any / unknown / never
    try expectClean("declare const a: any; const n: number = a;");
    try expectClean("let u: unknown; u = 1; u = \"x\"; u = null;");
    try expectCodes("declare const u: unknown; const n: number = u;", &.{2322});
    try expectClean("declare const nv: never; const n: number = nv;");
}

test "assignability: unions" {
    try expectClean("let x: string | number = 1; x = \"a\";");
    try expectCodes("let x: string | number = true;", &.{2322});
    try expectClean("declare const a: string; const u: string | number = a;");
    try expectCodes("declare const u: string | number; const s: string = u;", &.{2322});
    try expectClean("declare const u: \"a\" | \"b\"; const s: string = u;");
    try expectClean("type AB = \"a\" | \"b\"; type ABC = AB | \"c\"; declare const x: AB; const y: ABC = x;");
}

test "assignability: objects, width and optionality" {
    try expectClean("interface P { x: number; y: number; } declare const p: { x: number; y: number; z: string }; const q: P = p;");
    try expectCodes("interface P { x: number; y: number; } declare const p: { x: number }; const q: P = p;", &.{2741});
    try expectCodes("interface P { x: number; y: number; } const q: P = {} as { a: 1 };", &.{2739});
    try expectClean("interface P { x?: number; } declare const p: {}; const q: P = p;");
    try expectCodes("interface P { x: number; } declare const p: { x?: number }; const q: P = p;", &.{2322});
    try expectClean("interface P { x?: number; } declare const p: { x: number }; const q: P = p;");
}

test "assignability: arrays and tuples" {
    try expectClean("const a: number[] = [1, 2, 3];");
    try expectCodes("const a: number[] = [1, \"x\"];", &.{2322});
    try expectClean("const t: [number, string] = [1, \"a\"];");
    try expectCodes("const t: [number, string] = [1];", &.{2322});
    try expectCodes("const t: [number] = [1, 2];", &.{2322});
    // tuple -> array
    try expectClean("declare const t: [number, number]; const a: number[] = t;");
    try expectCodes("declare const t: [number, string]; const a: number[] = t;", &.{2322});
    // array -> tuple: no
    try expectCodes("declare const a: number[]; const t: [number] = a;", &.{2322});
    // Source may have more elements than the target allows (tsc errors).
    try expectCodes("declare const t: [number, string?]; const u: [number] = t;", &.{2322});
    try expectClean("declare const t: [number]; const u: [number, string?] = t;");
}

test "assignability: functions (strictFunctionTypes)" {
    // Param contravariance for function types.
    try expectClean("type F = (x: string | number) => void; declare const f: (x: string | number | boolean) => void; const g: F = f;");
    try expectCodes("type F = (x: string | number) => void; declare const f: (x: string) => void; const g: F = f;", &.{2322});
    // Return covariance.
    try expectClean("type F = () => string | number; declare const f: () => string; const g: F = f;");
    try expectCodes("type F = () => string; declare const f: () => string | number; const g: F = f;", &.{2322});
    // Fewer params ok, more required params not.
    try expectClean("type F = (a: number, b: string) => void; declare const f: (a: number) => void; const g: F = f;");
    try expectCodes("type F = (a: number) => void; declare const f: (a: number, b: string) => void; const g: F = f;", &.{2322});
    // void target return accepts anything.
    try expectClean("type F = () => void; declare const f: () => number; const g: F = f;");
    // Method bivariance.
    try expectClean(
        \\interface Emitter { on(x: string | number): void; }
        \\declare const e: { on(x: string): void };
        \\const m: Emitter = e;
    );
}

test "assignability: recursive interface terminates" {
    try expectClean(
        \\interface Tree { value: number; next: Tree | null; }
        \\interface Tree2 { value: number; next: Tree2 | null; }
        \\declare const a: Tree;
        \\const b: Tree2 = a;
    );
    try expectCodes(
        \\interface Tree { value: number; next: Tree | null; }
        \\interface Tree2 { value: string; next: Tree2 | null; }
        \\declare const a: Tree;
        \\const b: Tree2 = a;
    , &.{2322});
}

test "excess property checking: fresh literals only" {
    try expectCodes("const p: { a: number } = { a: 1, b: 2 };", &.{2353});
    try expectClean("const tmp = { a: 1, b: 2 }; const p: { a: number } = tmp;");
    try expectCodes("interface P { a: number; } function f(p: P): void {} f({ a: 1, extra: true });", &.{2353});
    // Union target: property known in one constituent.
    try expectClean("type U = { a: number } | { b: string }; const u: U = { a: 1 };");
    try expectCodes("type U = { a: number } | { b: string }; const u: U = { a: 1, c: 2 };", &.{2353});
    // Index signature target admits extras.
    try expectClean("const p: { a: number; [k: string]: number } = { a: 1, b: 2 };");
}

test "literal widening: let vs const, annotation vs fresh" {
    try expectClean("const x = \"a\"; const y: \"a\" = x;");
    // let widens fresh literals -> string.
    try expectCodes("let x = \"a\"; const y: \"a\" = x;", &.{2322});
    // Annotated const gives non-widening literal.
    try expectClean("const x: \"a\" = \"a\"; let y = x; const z: \"a\" = y;");
    // const-forwarded fresh literal widens at let.
    try expectCodes("const x = \"a\"; let y = x; const z: \"a\" = y;", &.{2322});
    // Object literal props widen.
    try expectCodes("const o = { s: \"a\" }; const t: { s: \"a\" } = o;", &.{2322});
    try expectClean("const o: { s: \"a\" } = { s: \"a\" };");
}

test "narrowing: truthiness" {
    try expectClean(
        \\function f(x: string | null): string {
        \\  if (x) { return x; }
        \\  return "";
        \\}
    );
    try expectCodes(
        \\function f(x: string | null): string {
        \\  if (x) {}
        \\  return x;
        \\}
    , &.{2322});
    try expectClean(
        \\function f(x: { a: number } | undefined): number {
        \\  if (!x) { return 0; }
        \\  return x.a;
        \\}
    );
}

test "narrowing: typeof guards incl. else branch" {
    try expectClean(
        \\function f(x: string | number): number {
        \\  if (typeof x === "string") { return x.length; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: string | number | boolean): number {
        \\  if (typeof x === "string") { return 0; }
        \\  if (typeof x === "boolean") { return 1; }
        \\  return x;
        \\}
    );
    try expectCodes(
        \\function f(x: string | number): number {
        \\  if (typeof x === "string") { return x; }
        \\  return x;
        \\}
    , &.{2322});
}

test "narrowing: equality with literals and null/undefined" {
    try expectClean(
        \\function f(x: "a" | "b" | null): "b" {
        \\  if (x === null) { return "b"; }
        \\  if (x === "a") { return "b"; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: number | null | undefined): number {
        \\  if (x == null) { return 0; }
        \\  return x;
        \\}
    );
    try expectClean(
        \\function f(x: number | null | undefined): number {
        \\  if (x !== undefined && x !== null) { return x; }
        \\  return 0;
        \\}
    );
}

test "narrowing: discriminated unions incl. switch and never" {
    try expectClean(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function area(s: Shape): number {
        \\  if (s.kind === "circle") { return s.radius * s.radius; }
        \\  return s.side * s.side;
        \\}
    );
    try expectClean(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function area(s: Shape): number {
        \\  switch (s.kind) {
        \\    case "circle": return s.radius;
        \\    case "square": return s.side;
        \\  }
        \\}
    );
    try expectCodes(
        \\interface Circle { kind: "circle"; radius: number; }
        \\interface Square { kind: "square"; side: number; }
        \\type Shape = Circle | Square;
        \\function f(s: Shape): number {
        \\  if (s.kind === "circle") { return s.side; }
        \\  return 0;
        \\}
    , &.{2339});
    // never via exhaustion
    try expectClean(
        \\function f(x: "a" | "b"): number {
        \\  switch (x) {
        \\    case "a": return 0;
        \\    case "b": return 1;
        \\    default: {
        \\      const n: never = x;
        \\      return n;
        \\    }
        \\  }
        \\}
    );
}

test "narrowing: in / instanceof / optional chain" {
    try expectClean(
        \\type U = { swim: () => void } | { fly: () => void };
        \\function f(u: U): void {
        \\  if ("swim" in u) { u.swim(); } else { u.fly(); }
        \\}
    );
    try expectClean(
        \\class A { a: number = 1; }
        \\class B { b: string = ""; }
        \\function f(x: A | B): number {
        \\  if (x instanceof A) { return x.a; }
        \\  return x.b.length;
        \\}
    );
    try expectClean(
        \\interface Box { inner?: { value: number }; }
        \\function f(b: Box): number {
        \\  if (b.inner) { return b.inner.value; }
        \\  return 0;
        \\}
    );
}

test "narrowing: assignment narrowing and loop widening" {
    try expectClean(
        \\let x: string | number = "a";
        \\const s: string = x;
        \\x = 1;
        \\const n: number = x;
    );
    try expectCodes(
        \\let x: string | number = "a";
        \\x = 1;
        \\const s: string = x;
    , &.{2322});
    // Loop back-edge resets to declared type.
    try expectCodes(
        \\declare const cond: boolean;
        \\let x: string | number = "a";
        \\while (cond) {
        \\  const s: string = x;
        \\  x = 1;
        \\}
    , &.{2322});
}

test "possibly nullish access (18047/18048/2532)" {
    try expectCodes("declare const s: string | undefined; s.length;", &.{18048});
    try expectCodes("declare const s: string | null; s.length;", &.{18047});
    try expectCodes("declare const s: string | null | undefined; s.length;", &.{18049});
    try expectClean("declare const s: string | undefined; s?.length;");
    try expectClean("declare const s: string | undefined; const n: number | undefined = s?.length;");
}

test "calls: arity, arguments, overloads pick-first" {
    try expectCodes("function f(a: number): void {} f();", &.{2554});
    try expectCodes("function f(a: number): void {} f(1, 2);", &.{2554});
    try expectClean("function f(a: number, b?: string): void {} f(1); f(1, \"x\");");
    try expectCodes("function f(a: number): void {} f(\"x\");", &.{2345});
    try expectClean("function f(...rest: number[]): void {} f(); f(1); f(1, 2, 3);");
    try expectCodes("function f(...rest: number[]): void {} f(1, \"x\");", &.{2345});
    // Overloads: first match wins.
    try expectClean(
        \\function pick(x: string): string;
        \\function pick(x: number): number;
        \\function pick(x: string | number): string | number { return x; }
        \\const s: string = pick("a");
        \\const n: number = pick(1);
    );
    try expectCodes(
        \\function pick(x: string): string;
        \\function pick(x: number): number;
        \\function pick(x: string | number): string | number { return x; }
        \\pick(true);
    , &.{2769});
    try expectCodes("declare const n: number; n();", &.{2349});
    // Negative controls for the global-`Function`-is-callable fix (see the
    // conformance fixture `calls/037_function_type_callable`): values that are
    // genuinely not callable still report TS2349.
    try expectCodes("declare const o: { a: number }; o();", &.{2349});
    try expectCodes("declare const s: string; s();", &.{2349});
}

test "generic calls: basic inference and explicit args" {
    try expectClean(
        \\function id<T>(x: T): T { return x; }
        \\const n: number = id(1);
        \\const s: string = id("a");
        \\const e: number = id<number>(2);
    );
    try expectClean(
        \\function first<T>(xs: T[]): T { return xs[0]; }
        \\const n: number = first([1, 2]);
    );
    // Literal preserved through inference; widened at let.
    try expectClean(
        \\function id<T>(x: T): T { return x; }
        \\const a: "a" = id("a");
    );
    // Contextual arrow param from generic signature.
    try expectClean(
        \\function map<T, U>(xs: T[], f: (x: T) => U): U[] {
        \\  const out: U[] = [];
        \\  let i = 0;
        \\  for (const x of xs) { out[i] = f(x); i = i + 1; }
        \\  return out;
        \\}
        \\const ns: number[] = map(["a", "bb"], (s) => s.length);
    );
    try expectCodes(
        \\function id<T>(x: T): T { return x; }
        \\id<number, string>(1);
    , &.{2558});
    // Constraint default when uninferrable.
    try expectClean(
        \\function make<T extends { a: number }>(): T | undefined { return undefined; }
        \\const r = make();
    );
}

test "classes: fields, methods, this, new, statics, implements" {
    try expectClean(
        \\class Point {
        \\  x: number;
        \\  y: number = 0;
        \\  constructor(x: number) { this.x = x; }
        \\  dist(): number { return this.x * this.x + this.y * this.y; }
        \\}
        \\const p = new Point(1);
        \\const n: number = p.dist();
    );
    try expectCodes("class C { x: number = \"nope\"; }", &.{2322});
    try expectCodes("class C { constructor(a: number) {} } new C();", &.{2554});
    try expectCodes("class C { m(): number { return 1; } } const c = new C(); c.m(\"x\");", &.{2554});
    try expectClean(
        \\class Base { a: number = 1; }
        \\class Derived extends Base { b: string = ""; }
        \\const d = new Derived();
        \\const n: number = d.a;
        \\const s: string = d.b;
    );
    try expectClean(
        \\class Counter {
        \\  static count: number = 0;
        \\  static bump(): number { return Counter.count + 1; }
        \\}
        \\const n: number = Counter.bump();
    );
    try expectCodes(
        \\interface Named { name: string; }
        \\class C implements Named { id: number = 1; }
    , &.{2420});
    try expectClean(
        \\interface Named { name: string; }
        \\class C implements Named { name: string = "c"; }
    );
    // Generic class.
    try expectClean(
        \\class Box<T> {
        \\  value: T;
        \\  constructor(v: T) { this.value = v; }
        \\  get(): T { return this.value; }
        \\}
        \\const b = new Box<number>(1);
        \\const n: number = b.get();
        \\const c = new Box("s");
        \\const s: string = c.get();
    );
}

test "interfaces: extends, merge, generics" {
    try expectClean(
        \\interface A { a: number; }
        \\interface B extends A { b: string; }
        \\declare const x: B;
        \\const n: number = x.a;
        \\const s: string = x.b;
    );
    try expectClean(
        \\interface M { a: number; }
        \\interface M { b: string; }
        \\declare const m: M;
        \\const n: number = m.a;
        \\const s: string = m.b;
    );
    try expectClean(
        \\interface Box<T> { value: T; }
        \\declare const b: Box<string>;
        \\const s: string = b.value;
    );
    try expectCodes(
        \\interface Box<T> { value: T; }
        \\declare const b: Box<string>;
        \\const n: number = b.value;
    , &.{2322});
    try expectCodes("interface Box<T> { value: T; } declare const b: Box;", &.{2314});
}

test "type aliases: generics, recursion, keyof, indexed access, typeof" {
    try expectClean(
        \\type Pair<A, B> = { first: A; second: B };
        \\declare const p: Pair<number, string>;
        \\const n: number = p.first;
        \\const s: string = p.second;
    );
    try expectClean(
        \\type Tree = { value: number; children: Tree[] };
        \\declare const t: Tree;
        \\const n: number = t.children[0].value;
    );
    try expectCodes("type T = T;", &.{2456});
    try expectClean(
        \\interface P { a: number; b: string; }
        \\declare const k: keyof P;
        \\const s: "a" | "b" = k;
    );
    try expectClean(
        \\interface P { a: number; b: string; }
        \\declare const v: P["a"];
        \\const n: number = v;
    );
    try expectClean(
        \\const origin = { x: 0, y: 0 };
        \\declare const p: typeof origin;
        \\const n: number = p.x;
    );
}

test "operators: arithmetic, plus, comparisons, 2367" {
    try expectClean("const n: number = 1 + 2 * 3; const s: string = \"a\" + 1;");
    try expectCodes("declare const o: {}; const x = o * 2;", &.{2362});
    try expectCodes("declare const o: {}; const x = 2 * o;", &.{2363});
    try expectCodes("declare const o: { a: number }; const x = o + 1;", &.{2365});
    try expectCodes("declare const s: string; declare const n: number; s < n;", &.{2365});
    try expectCodes("declare const a: string; declare const b: number; a === b;", &.{2367});
    try expectClean("declare const a: \"x\" | \"y\"; a === \"x\";");
    try expectCodes("declare const a: \"x\" | \"y\"; if (a === \"z\") {}", &.{2367});
}

test "logical operator result types" {
    try expectClean("declare const s: string; declare const n: number; const r: \"\" | number = s && n;");
    try expectClean("declare const s: string | null; const r: string = s ?? \"fallback\";");
    try expectClean("declare const s: string | undefined; const r: string = s || \"x\";");
    try expectClean("declare const b: boolean; const r: false | string = b && \"yes\";");
}

test "TDZ and use-before-assigned" {
    try expectCodes("x; let x = 1;", &.{ 2448, 2454 }); // tsc reports both
    try expectClean("function f(): number { return x; } let x = 1;");
    try expectCodes("let y: number; const z: number = y;", &.{2454});
    try expectClean("let y: number; y = 1; const z: number = y;");
    try expectClean("let y: number | undefined; const z: number | undefined = y;");
    try expectClean("declare const c: boolean; let y: number; if (c) { y = 1; } else { y = 2; } const z: number = y;");
    try expectCodes("declare const c: boolean; let y: number; if (c) { y = 1; } const z: number = y;", &.{2454});
}

test "cannot find name / wrong space / suggestions" {
    try expectCodes("missing();", &.{2304});
    try expectCodes("const x: NotAType = 1;", &.{2304});
    try expectCodes("interface I { a: number; } const x = I;", &.{2693});
    try expectCodes("const value = 1; const x: number = valeu;", &.{2552});
    try expectCodes("declare const o: { total: number }; o.totol;", &.{2551});
    try expectCodes("declare const o: { a: number }; o.b;", &.{2339});
}

test "implicit any params (7006)" {
    try expectCodes("function f(x): void {}", &.{7006});
    try expectClean("function f(x = 3): number { return x; }");
    try expectClean("const f: (x: number) => number = (x) => x + 1;");
    try expectCodes("const f = (x) => x;", &.{7006});
}

test "noImplicitAny off: TS7006 suppressed, param still types as any" {
    const src =
        \\function f(x) { return x.anything.at.all; }
        \\const n: number = f(1);
    ;
    // Default (noImplicitAny on): the unannotated param reports TS7006.
    try expectCodes(src, &.{7006});

    // noImplicitAny off: TS7006 is suppressed. `x` still types as `any`, so the
    // deep member access is silently allowed and nothing else cascades — the
    // observable output is "today minus the diagnostic".
    var t: TestCheck = undefined;
    t.arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer t.arena.deinit();
    t.interner = Interner.init();
    defer t.interner.deinit(testing.allocator);
    const alloc = t.arena.allocator();
    const tree = try alloc.create(Ast);
    tree.* = try parser.parse(alloc, src);
    const bound = try alloc.create(Bind);
    bound.* = try binder.bind(alloc, testing.io, testing.allocator, &t.interner, tree, src, false);
    const prog = try alloc.create(modules.Program);
    prog.* = try modules.singleFileProgram(alloc, "", src, tree, bound);
    prog.no_implicit_any = false; // the effective tsconfig value
    const result = try checkFiles(alloc, testing.io, testing.allocator, &t.interner, prog, &.{0}, null, true);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "return checking: 2355 / 2366 / exhaustive switch" {
    try expectCodes("function f(): number {}", &.{2355});
    try expectCodes("declare const c: boolean; function f(): number { if (c) { return 1; } }", &.{2366});
    try expectClean("declare const c: boolean; function f(): number { if (c) { return 1; } return 2; }");
    try expectClean("function f(): void {}");
    try expectClean("function f(x: \"a\" | \"b\"): number { switch (x) { case \"a\": return 0; case \"b\": return 1; } }");
    try expectCodes("function f(x: string): number { switch (x) { case \"a\": return 0; } }", &.{2366});
    try expectClean("function f(): number { while (true) {} }");
}

test "const assignment / readonly (2588 / 2540)" {
    try expectCodes("const x = 1; x = 2;", &.{2588});
    try expectCodes("interface P { readonly a: number; } declare const p: P; p.a = 2;", &.{2540});
    try expectClean("interface P { readonly a: number; } declare const p: P; const n: number = p.a;");
}

test "for-of: arrays, tuples, strings; bad iterables" {
    try expectClean("for (const n of [1, 2, 3]) { const x: number = n; }");
    try expectClean("declare const t: [number, string]; for (const v of t) { const x: number | string = v; }");
    try expectClean("declare const s: string; for (const ch of s) { const c: string = ch; }");
    try expectCodes("for (const x of 42) {}", &.{2488});
}

test "switch comparability (2678)" {
    try expectCodes("declare const n: number; switch (n) { case \"a\": break; }", &.{2678});
    try expectClean("declare const n: number; switch (n) { case 1: break; default: break; }");
}

test "as-casts (2352)" {
    try expectClean("declare const u: unknown; const n = u as number;");
    try expectClean("declare const n: number | string; const m = n as number;");
    try expectCodes("declare const s: string; const n = s as number;", &.{2352});
    try expectClean("declare const s: string; const n = s as unknown as number;");
    // Cast to/from an unconstrained type parameter overlaps anything.
    try expectClean("function f<T>(x: { a: number }): T { return x as T; }");
    try expectClean("function f<T>(x: T): { a: number } { return x as { a: number }; }");
    // Union target: overlaps via one constituent; rejects when none overlap.
    try expectClean("declare const o: { name: string }; const p = o as ({ name: string; id: number } | null);");
    try expectCodes("declare const o: { q: number }; const n = o as (number | boolean);", &.{2352});
    // A constrained type parameter still rejects a non-overlapping cast.
    try expectCodes("function f<T extends { a: number }>(x: T): { b: string } { return x as { b: string }; }", &.{2352});
}

test "printer goldens via diagnostics" {
    var t = try TestCheck.init("const x: { a: number; b?: string } = 1;");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.result.diagnostics.len);
    try testing.expectEqualStrings("Type '1' is not assignable to type '{ a: number; b?: string; }'.", t.result.diagnostics[0].msg);

    var t2 = try TestCheck.init("declare function f(cb: (x: number) => string): void; f(3);");
    defer t2.deinit();
    try testing.expectEqual(@as(usize, 1), t2.result.diagnostics.len);
    try testing.expectEqualStrings("Argument of type '3' is not assignable to parameter of type '(x: number) => string'.", t2.result.diagnostics[0].msg);

    var t3 = try TestCheck.init("const x: [number, string] | null = true;");
    defer t3.deinit();
    try testing.expectEqual(@as(usize, 1), t3.result.diagnostics.len);
    try testing.expectEqualStrings("Type 'true' is not assignable to type '[number, string] | null'.", t3.result.diagnostics[0].msg);
}

test "stress: checker total on random and token soup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0xc4ec_2026);
    const random = prng.random();

    const vocab = [_][]const u8{
        "if",        "else",   "function", "class",      "const",  "let",    "var",     "interface",
        "type",      "of",     "in",       "for",        "while",  "switch", "case",    "return",
        "new",       "typeof", "extends",  "implements", "x",      "y",      "Foo",     "42",
        "\"s\"",     "{",      "}",        "(",          ")",      "[",      "]",       ";",
        ",",         ":",      "?",        ".",          "=>",     "=",      "+",       "-",
        "===",       "!==",    "&&",       "||",         "??",     "!",      "|",       "&",
        "<",         ">",      "keyof",    "readonly",   "number", "string", "boolean", "null",
        "undefined", "never",  "unknown",  "any",        "true",   "false",  "...",     "?.",
    };

    var buf: [1024]u8 = undefined;
    for (0..150) |round| {
        var len: usize = 0;
        if (round % 2 == 0) {
            len = random.uintLessThan(usize, 256);
            random.bytes(buf[0..len]);
        } else {
            const count = random.uintLessThan(usize, 80);
            for (0..count) |_| {
                const word = vocab[random.uintLessThan(usize, vocab.len)];
                if (len + word.len + 1 > buf.len) break;
                @memcpy(buf[len..][0..word.len], word);
                len += word.len;
                buf[len] = if (random.uintLessThan(u8, 8) == 0) '\n' else ' ';
                len += 1;
            }
        }
        const alloc = arena.allocator();
        const tree = try alloc.create(Ast);
        tree.* = parser.parse(alloc, buf[0..len]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SourceTooLarge => unreachable,
        };
        const bound = try alloc.create(Bind);
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, buf[0..len], false);
        const result = try check(alloc, testing.io, testing.allocator, &interner, tree, bound, buf[0..len]);
        for (result.diagnostics) |dd| {
            try testing.expect(dd.span.start <= len + 1);
            try testing.expect(dd.code != 0);
        }
        _ = arena.reset(.retain_capacity);
    }
}

fn fuzzCheckerOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [400]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, ':', 3),
        .value(u8, '=', 3),
        .value(u8, ';', 3),
        .value(u8, '|', 2),
        .value(u8, '\n', 3),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    const alloc = arena.allocator();
    const tree = try alloc.create(Ast);
    tree.* = parser.parse(alloc, source_buf[0..len]) catch return;
    const bound = try alloc.create(Bind);
    bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, source_buf[0..len], false);
    _ = try check(alloc, testing.io, testing.allocator, &interner, tree, bound, source_buf[0..len]);
}

test "fuzz: checker on arbitrary bytes" {
    try testing.fuzz({}, fuzzCheckerOne, .{});
}

test "assignability matrix: intrinsics x intrinsics (table test)" {
    // Row = source, column = target. 1 = assignable under strict rules.
    const names = [_][]const u8{ "any", "unknown", "never", "void", "undefined", "null", "string", "number", "boolean", "bigint" };
    // Rows in the same order; targets across.
    const table = [10][10]u1{
        // to:  any un nv vo ud nl st nu bo bi     from:
        .{ 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 }, // any (assignable to all but never)
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, // unknown
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, // never
        .{ 1, 1, 0, 1, 0, 0, 0, 0, 0, 0 }, // void
        .{ 1, 1, 0, 1, 1, 0, 0, 0, 0, 0 }, // undefined
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 0, 0 }, // null
        .{ 1, 1, 0, 0, 0, 0, 1, 0, 0, 0 }, // string
        .{ 1, 1, 0, 0, 0, 0, 0, 1, 0, 0 }, // number
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0 }, // boolean
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, // bigint
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var expected_errors: usize = 0;
    const w = &aw.writer;
    for (names, 0..) |n, i| w.print("declare const s{d}: {s};\n", .{ i, n }) catch return error.OutOfMemory;
    for (names, 0..) |sname, i| {
        _ = sname;
        for (names, 0..) |tname, j| {
            w.print("const t{d}_{d}: {s} = s{d};\n", .{ i, j, tname, i }) catch return error.OutOfMemory;
            if (table[i][j] == 0) expected_errors += 1;
        }
    }
    var t = try TestCheck.init(aw.written());
    defer t.deinit();
    var got_2322: usize = 0;
    for (t.result.diagnostics) |d| {
        if (d.code == 2322) got_2322 += 1 else return error.TestUnexpectedResult;
    }
    try testing.expectEqual(expected_errors, got_2322);
}
