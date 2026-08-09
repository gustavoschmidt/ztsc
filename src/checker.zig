//! Checker core: structural assignability, inference, literal
//! widening, control-flow narrowing, tsc-coded diagnostics; multi-file
//! programs via the sealed module graph.
//!
//! Scope & stance (documented deviations are intentional for the v0.0.1 subset):
//!
//! - **Multi-file**: a Checker instance checks a *partition* of the
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
const ast = @import("frontend/ast.zig");
const scanner = @import("frontend/scanner.zig");
const intern = @import("intern.zig");
const binder = @import("frontend/binder.zig");
const types = @import("types.zig");
const source = @import("frontend/source.zig");
const libs = @import("libs.zig");
const modules = @import("link/modules.zig");
const parser = @import("frontend/parser.zig");
const ZeroPagedArray = @import("zeropage.zig").ZeroPagedArray;
pub const BumpArena = @import("checker/bump.zig").BumpArena;
pub const prof_zig = @import("checker/prof.zig");
pub const memprof_zig = @import("checker/memprof.zig");
pub const memo_zig = @import("checker/memo.zig");
pub const lazy_zig = @import("checker/instantiate.zig");

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
pub const SymState = enum(u8) {
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

/// Program AST-node count above which per-checker sizing estimates switch
/// from this checker's OWN files to the whole program (see the type-store
/// reserve in `init`). Set above every `bench/corpus/real` package (the
/// largest, hono, is 115,808 nodes) so no gated peak-RSS row can move, and
/// far below any application (immich is 1,138,954).
pub const large_program_nodes: usize = 1 << 18;

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
    /// instantiation-cache accounting.
    inst_hits: usize = 0,
    inst_misses: usize = 0,
    inst_maps: usize = 0,
    /// Node visits spent substituting a SIGNATURE'S OWN type parameter's
    /// constraint and default (`instantiateId`'s `.function` arm). tsc resolves
    /// a cloned type parameter's constraint lazily; ztsc substitutes it eagerly
    /// on every instantiation of the signature, and on a kysely-shaped library
    /// a bound is a mapped type over every column of every table in scope.
    inst_bound_visits: u64 = 0,
    /// The share of `inst_bound_visits` whose substituted bound is ENFORCED as
    /// the fresh parameter's constraint (`fc`).
    inst_bound_enforced: u64 = 0,
    /// The share carried only as `FreshTp.widen_bound` (unenforced).
    inst_bound_widen: u64 = 0,
    /// The share that moved nothing, so no fresh parameter was minted and the
    /// substituted bound was discarded on the spot.
    inst_bound_discarded: u64 = 0,
    /// Fresh type parameters minted with an UNSUBSTITUTED bound
    /// (`FreshTp.pending_bound`), and how many of those bounds anybody ever
    /// asked for. Always counted (not prof-gated): the ratio is the whole
    /// point of the deferral and it costs two increments per mint.
    bound_deferred: u64 = 0,
    bound_forced: u64 = 0,
    /// Deferred bounds that, once forced, turned out NOT to move — the mints
    /// `boundMayMove` made speculatively, where the eager code would have kept
    /// the original parameter. Zero on every gated corpus; a non-zero here is
    /// the interning-identity risk of the whole change, made observable.
    bound_speculative: u64 = 0,
    /// `Checker.inst_count` at seal: the instantiation work this instance
    /// charged against `max_instantiation_count`, and the comparator for
    /// tsgo's `--extendedDiagnostics` Instantiations. Reported so the quantity
    /// that gates TS2589 is observable to a gate — it is required to be
    /// run-to-run invariant at a fixed configuration (`bench/repeat_sweep.sh`),
    /// and it is *not* invariant across configurations: the partition splits
    /// it between instances and the memo suppresses repeat visits.
    instantiations: usize = 0,
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

/// Build the shared frozen base type store (frozen-base piece 2).
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
/// lib/`@types` body into the base (the RSS win, reusing the cross-file merge table
/// to enumerate lib symbols) is deferred to the larger embedded lib: it would
/// relocate lib types to low base ids. The display-order prerequisite that used
/// to block it — union/intersection members were printed in raw-TypeId order —
/// is resolved: `printType` now orders members structurally
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
/// `error_type`.
pub const max_instantiation_depth = 100;
/// Cap on `instantiate` node-visits spent on one *source element*, reset at
/// the top of `checkStatement` exactly as tsc resets `instantiationCount` at
/// the top of `checkSourceElement`. The limit tsc documents is "5M type
/// instantiations caused by the same statement" — a per-statement resource
/// budget, not a per-compilation one.
///
/// It used to be per-checker-lifetime here, and that is a different thing
/// entirely. A single runaway annotation exhausted it while materializing one
/// import (hoppscotch's `HoppRESTRequest`, a verzod/zod entity whose eager
/// expansion is effectively unbounded), and from that point on *every*
/// instantiation this checker performed — for the rest of the run, in every
/// later file — took the guard's early exit and truncated to `error_type`.
/// `const xs: string[] = []; xs.push("a")` three lines below the import
/// reported `Property 'push' does not exist on type 'string[]'`. A
/// statement-scoped budget cannot poison an unrelated later statement, which
/// is the whole reason tsc scopes it there.
///
/// The value is sized against measured demand rather than inherited: ztsc's
/// unit is one structural node visit (tsc's is a much coarser
/// `instantiateType` call), and 5M of them intern roughly half a gigabyte of
/// types — a cap that permits that per statement is not a cap. Per-statement
/// maxima over the benchmark corpus at `--checkers=1` are chalk 74,
/// @types/react 775, @types/node 830, zod 1,142, hono 3,346, drizzle-orm
/// 4,161, typebox 15,400, ajv 21,201. 250,000 is an order of magnitude above
/// the worst of those and two orders below the runaway, and it bounds a
/// pathological statement to tens of megabytes instead of hundreds.
///
/// The element the budget is scoped to is the statement *or* the cross-file
/// declaration materialization a statement demands, whichever frame the work
/// is really being done for: `enterSymFile` opens a fresh budget and
/// `restoreCtx` closes it. Without that split the budget is spent on work
/// whose assignment to a statement is a function of `--checkers=N`, and the
/// cap becomes a partition-dependent decision variable — see `enterSymFile`.
pub const max_instantiation_count = 250_000;
/// The same cap for a CROSS-FILE DECLARATION materialization — the window
/// `enterSymFile` opens — where it has to be much larger.
///
/// A statement's budget is a fairness device: the answer it truncates is that
/// statement's, and the next statement starts over. A declaration's is not.
/// Its result is memoized under the SYMBOL (`inst_cache`, `expansions`, the
/// per-symbol member table) and read by every later statement in the program,
/// so a truncation there is published once and never revisited — and which
/// statement happened to demand it first decides what the whole run sees.
///
/// The number is set by what those materializations actually cost. immich's
/// repository classes are ~100 kysely-typed methods each, and the profiler's
/// `-- budget trips by the declaration frame that was live --` axis shows
/// INDIVIDUAL members (`query`, `streamForSearchDuplicates`, `getById`)
/// exceeding 250,000 node visits starting from zero; on the whole package
/// 3,916 of 5,290 trips fire inside a table construction. Every one of those
/// is a member type published truncated.
///
/// Why not raise `max_instantiation_count` itself: measured, and it is a
/// blocker on the library corpus. At tsc's own 5 M, immich excess does fall
/// (c4 123 -> 95, c1 152 -> 94, cross-partition divergence 29 -> 1 keys) and
/// the plateau starts at 3 M — but zod goes 0.15 s / 53 MB to 1.37 s /
/// 301 MB, nine times tsgo's wall on a gated package, because zod's cost is
/// in ordinary source elements that used to trip and now run to completion.
/// Splitting the two caps buys immich's declaration truncations without
/// touching what a statement may spend.
pub const max_decl_instantiation_count = 5_000_000;
/// How many times one type may re-enter the *live* `instantiateId` chain
/// before the expansion is treated as a non-terminating recursive-alias cycle
/// and cut.
///
/// ztsc instantiates structurally and eagerly where tsc defers, so a generic
/// alias that references itself through an indexed access re-expands forever
/// with a growing argument. ajv's `UncheckedJSONSchemaType<T, IsPartial>` is
/// the canonical shape — an eleven-frame cycle
///
///   {allOf?: UncheckedPartialSchema<T>[]; …}          (three object frames)
///     → T extends any[] ? … : …                       (five conditionals)
///       → {[P in keyof UncheckedJSONSchemaType<T[0], true>]: …[P]}
///         → UncheckedJSONSchemaType<T[0], true>[P]
///           → {allOf?: …}                             (lap 2)
///
/// whose type argument grows `T` → `T[0]` → `T[0][0]` …, so no `(map, type)`
/// pair ever repeats and the instantiation memo cannot break it. Only the
/// depth cap stopped it, at depth 101 — and *where* the chain happened to be
/// when it got there is a function of what this checker instance had already
/// materialized, i.e. of the partition. Repetition on the live chain is not:
/// it is a property of the type.
///
/// The cut is silent (returns `error_type` without TS2589), matching the
/// project's under-report policy for exactly this class — see
/// test/conformance/instantiation/003, 010 and 018, where tsc reports TS2589
/// on a growing recursive alias and ztsc deliberately stays quiet rather than
/// false-positive a valid deep recursion. Genuinely deep *acyclic*
/// instantiation still reports: `max_instantiation_depth` is untouched, and a
/// 130-level nested tuple (conformance 002) repeats no type at all.
///
/// Four is chosen from the observed split. Peak chain repetition, whole
/// program at `--checkers=1`: 2 for chalk, @types/node, @types/react, hono
/// and zod; 3 for hoppscotch's js-sandbox and 4 for excalidraw (both already
/// inside runaway expansions); against 51 for drizzle-orm, 98 for ajv and 101
/// for typebox. It also has to leave room under `max_instantiation_depth`:
/// four laps of ajv's eleven-frame cycle is depth 44, well clear of 100,
/// where eight laps would not be.
pub const max_chain_repeats = 4;
/// Depth below which `chainRepeats` does not bother scanning. No cycle can
/// have completed `max_chain_repeats` laps in fewer frames than this, and the
/// scan sits on the hottest path in the checker.
pub const chain_scan_floor = 8;
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
///
/// The limit is a straight RSS/allocator-traffic trade and was measured on the
/// dogfood project at `--checkers=4` (medians of interleaved runs, instructions
/// retired as the load-insensitive wall proxy):
///
///   8 MiB (was)  236.5 MB  21.721 G ins
///   1 MiB        235.6 MB  21.720 G ins
///   256 KiB      229.0 MB  21.758 G ins  (+0.17%)
///    64 KiB      227.7 MB  21.818 G ins  (+0.44%)
///
/// 256 KiB is the knee: below it the per-statement re-`mmap` traffic starts
/// costing more than the pages it hands back.
pub const scratch_retain_limit = 256 * 1024;
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
pub const max_relation_depth = 900;
/// How many times ONE generic may reappear on the relation's live source or
/// target stack, each time as a strictly LATER instantiation of itself, before
/// the pair is assumed related — tsc's `isDeeplyNestedType` maxDepth.
///
/// `max_relation_depth` alone cannot close a walk like zod's: `ZodType`'s
/// members return `ZodOptional<this>`, `ZodArray<this>`, `ZodIntersection<this,
/// T>` … so the pair at each level is a strictly LARGER instantiation of the
/// same handful of generics, a dozen ways per level. Nothing repeats, so both
/// memos miss, and the walk ran until the per-statement instantiation budget
/// tripped — whereupon the truncation to `error_type` came back as a FALSE
/// relation and was cached, which is where `ZodString` stopped satisfying
/// `ZodType<string | number | symbol, any, any>`. Recognising the *generic*
/// rather than the instantiation closes it in two levels.
///
/// The GROWTH half of the test (`relIdDeeplyNested`) is what makes so small a
/// limit safe: an ordinary recursive type meeting itself through its own
/// members — `Uint8Array<ArrayBufferLike>`, whose `subarray`/`slice` hand back
/// the same instantiation — re-enters with the same ref and is not counted at
/// all. Only a chain that keeps building a bigger argument is.
///
/// Assume-related is the same direction the depth cap already takes: it can
/// only drop diagnostics, never invent one. It is nevertheless recorded
/// (`rel_guard_tripped`), because a NEGATIVE verdict built on an assumed YES
/// is not evidence — see that field.
pub const max_relation_identity_repeats = 2;
/// How many times one generic may be re-entered by the polymorphic-`this`
/// rewrite (`substThis`) before its subject is left symbolic. The instantiation
/// analogue of `max_relation_identity_repeats`, and chosen the same way — see
/// the growth cut in `substThis` for the shape it closes.
pub const max_this_subst_repeats = 2;
/// Buckets in the relation-stack occupancy filter (`rel_src_buckets`).
pub const rel_id_buckets = 64;

/// One live relation frame's recursion identity for one side: the generic
/// (`sym`) and the exact instantiation of it (`ref`, the interned origin ref).
/// `relIdDeeplyNested` counts occurrences of `sym` whose `ref` keeps growing.
pub const RelId = struct { sym: SymbolId, ref: TypeId };
/// Recursion-depth cap for alias-instance expansion (`aliasInstance`; see the
/// `alias_depth` field). Fires only on pathological mutually-recursive generic
/// alias chains (e.g. `@scalar/typebox`'s conditional type modules, whose
/// type-argument defaults chain through ~80 distinct aliases and would otherwise
/// overflow the stack). Past the cap the expansion yields `error_type`, which
/// suppresses cascades rather than adding a diagnostic (no false positive; tsc
/// resolves these via deferred conditional evaluation, out of ztsc's subset).
/// Set far above any depth in-subset code or the conformance suite reaches, well
/// below the worker-stack overflow depth.
pub const max_alias_depth = 200;
pub const max_type_string = 160;

pub const FnCtx = struct {
    /// Effective return-check target (0 = none / inferring). For an async
    /// function this is the awaited *payload* `T` of the declared
    /// `Promise<T>`, not the `Promise<T>` itself.
    ret_ann: TypeId = 0,
    /// Contextual return type when the function has NO annotation but is being
    /// checked against a contextual signature (`const f: Creator = (n) => ({…})`
    /// — the object literal's contextual type is `Creator`'s return type). Types
    /// the return expressions; never reported against, so an inference gap here
    /// can only lose a contextual type, never raise a diagnostic. 0 = none.
    ret_ctx: TypeId = 0,
    is_async: bool = false,
    is_generator: bool = false,
    /// For a generator with an annotated `Generator<T>`/`Iterator<T>`/
    /// `IterableIterator<T>` return: the yield element type `T` (0 = infer /
    /// unchecked).
    yield_type: TypeId = 0,
};

/// A function body whose check was postponed because it was reached while
/// *materializing* a class field's type from its initializer.
///
/// An un-annotated field (`toggle = () => { … this.setState(…) … }`) has its
/// type inferred by checking the initializer, and that happens from inside
/// `classInstanceType` — while the instance type is still being built. Walking
/// the body there resolves every `this.<member>` against the in-progress
/// (therefore `any`) instance, and `node_types` then caches the initializer's
/// type so `checkClass`'s later, correct pass never re-enters the body. Every
/// callback inside such a body lost its contextual type: `this.setState((prev)
/// => …)` reported TS7006 on `prev`, and the whole any-receiver chain below it
/// cascaded. Queueing the body and draining it once the instance type is
/// complete keeps the field's type exactly as before while checking the body
/// against the finished class.
pub const DeferredBody = struct {
    file: FileId,
    node: Node,
    proto_idx: u32,
    body: Node,
    sig: TypeId,
    /// Contextual return type at the queue site (see `checkFunctionBody`).
    ret_ctx: TypeId,
    /// `this` in force where the body was found — the class's generic instance
    /// for an instance field, whatever the ambient value was otherwise.
    this_type: TypeId,
};

/// One written type-argument list awaiting its TS2344 constraint check.
///
/// The check cannot run where the reference is CONVERTED. Conversion happens
/// wherever a type is first needed — which is routinely in the middle of some
/// class's instance materialization, where a `keyof` over that class answers
/// with whatever half of the member table exists so far. Deciding "does not
/// satisfy" against a half-built key set is exactly how a negative check
/// invents diagnostics (drizzle's `keyof PgSelectBase<…> & string` answered
/// with 7 of its 28 keys, and any argument fails a set that small).
///
/// tsc has no such exposure: `checkTypeArgumentConstraints` runs from
/// `checkSourceElement`, a walk that happens after declarations resolve. This
/// is that ordering — the reference is queued during conversion and drained
/// once every statement of every owned file has been checked, when every
/// class table is complete.
///
/// Six `u32`s and no per-entry allocation. The written argument *nodes* are
/// not kept: they are a `SubRange` of the (immutable) tree, so the drain reads
/// them back out of `node`. Their *types* are kept — re-converting them at the
/// drain is not sound, because an argument may be written under a binder that
/// only exists mid-walk (`infer X`, a mapped type's key parameter), and those
/// live on checker stacks that are unwound long before the drain runs; a
/// re-conversion answers `TS2304 Cannot find name 'X'` instead. They go into
/// the shared `pending_type_args_pool` rather than a slice of their own.
pub const PendingTypeArgs = struct {
    /// File the reference was written in — where its diagnostics belong, and
    /// whose tree `node` indexes.
    file: FileId,
    /// The `type_ref` node. The drain re-reads its written argument nodes
    /// (`writtenTypeArgNodes`) instead of the queue storing a copy.
    node: Node,
    /// The generic the name resolved to.
    sym: SymbolId,
    /// `this` in force at the reference, so a constraint mentioning `this`
    /// resolves at drain time exactly as it would have in place.
    this_type: TypeId,
    /// This entry's run of resolved arguments in `pending_type_args_pool`,
    /// positionally paired with the non-hole entries of the node list.
    args_start: u32,
    args_len: u32,
};

/// A memoized expression type together with the contextual type it was
/// synthesized under (contextual re-check cache).
pub const NodeType = struct { ty: TypeId, ctx: TypeId };

/// One in-progress `interfaceGeneric` resolution (base-cycle detection).
pub const IfaceFrame = struct { sym: SymbolId, resolving_base: bool = false };

/// Bounds of a fresh higher-order type-param symbol (see `fresh_tp_ids`). The
/// constraint/default are already `M`-instantiated TypeIds (`no_type` = none).
pub const FreshTp = struct {
    name: Atom,
    constraint: TypeId,
    default: TypeId,
    has_default: bool,
    /// The `const` modifier of the ORIGINAL type parameter this fresh id
    /// stands in for, carried across so a `const` parameter of a generic
    /// method survives the receiver's instantiation.
    const_tp: bool = false,
    /// A BARE outer bound (`<T extends TB>` where `TB` is the enclosing
    /// interface's parameter) after substitution — `no_type` when the bound
    /// was absent or already structured (then `constraint` holds it).
    ///
    /// Such a bound is deliberately NOT enforced (see `mintFreshTp`'s caller:
    /// enforcing a substituted bare bound erases legitimate inferences), but
    /// it still has to be VISIBLE to the literal-widening rule: tsc keeps an
    /// inferred literal whenever the parameter has a primitive constraint,
    /// and `<T extends TB>` under `TB := "asset"` is one. Without it, kysely's
    /// `selectAll<T extends TB>(table: T)` widened `"asset"` to `string` and
    /// the row type `Selectable<DB[T]>` collapsed to `{}`.
    widen_bound: TypeId = types.no_type,
    /// The DECLARATION symbol this fresh id stands in for (transitively — a
    /// fresh parameter that is itself re-freshened records the original).
    /// Two signatures whose parameters share their origins are two
    /// instantiations of one generic declaration, which is what tsc's
    /// signature relation tests as `source.symbol === target.symbol` before
    /// erasing the pair to `any` (`signatureAssignableModeInnerErase`).
    orig: SymbolId = 0,
    /// DEFERRED BOUND. When this is not `no_type`, `constraint` and
    /// `widen_bound` above are not yet computed: this is the *unsubstituted*
    /// constraint of `orig` and `pending_map` the canonical id of the map to
    /// substitute it under. `resolveFreshBound` forces it (and clears this
    /// field) on the first read through `typeParamConstraint` — the single
    /// reader of a fresh parameter's bound — so a bound no call site ever
    /// resolves costs nothing. On immich 88% of them are never read.
    pending_bound: TypeId = types.no_type,
    pending_map: u32 = 0,
    /// Whether a forced bound is ENFORCED (`constraint`) rather than merely
    /// carried for the literal-widening rule (`widen_bound`); the `eligible`
    /// / `kind(oc) != .type_param` gate of the mint site, evaluated eagerly
    /// because it needs no substitution.
    pending_enforce: bool = false,
    /// Whether this record would have been minted even had the constraint
    /// turned out not to move — i.e. the DEFAULT moved. When false and the
    /// forced bound turns out to equal the unsubstituted one, the mint was
    /// speculative: the eager code would have kept the original parameter,
    /// whose constraint is `pending_bound` *enforced*, so that is what the
    /// resolution installs regardless of `pending_enforce`.
    pending_default_moved: bool = false,
};

/// The set of type-parameter symbols a type mentions (`Checker.tp_mentions`).
/// `saturated` means "gave up, assume every symbol": the walk stops at a
/// signature that binds its own type parameters rather than reason about
/// which of them shadow what.
pub const Mentions = struct { syms: []const SymbolId, saturated: bool };

/// One entry of `Checker.mapped_key_scopes`: a mapped type's key parameter
/// `K`, in scope for that map's `as`/value branches (and for anything nested
/// in them).
pub const MappedKeyScope = struct {
    name: Atom,
    /// The `mapped_param` type `name` resolves to, or 0 for a SHADOW entry:
    /// a nearer non-mapped binder of the same name (a signature's own type
    /// parameter) that hides every enclosing mapped key called `name`.
    ty: TypeId,
    /// `infer_scopes` stack height when this key was entered. A same-named
    /// outer `infer X` (scope index < this) is OUTER to the mapped key `[X in
    /// K]` and is shadowed by it (lexical innermost-wins); an `infer X` pushed
    /// by a conditional NESTED in the mapped value (index >= this) stays inner
    /// and still wins.
    infer_depth: usize,
};

/// Every long-lived `Checker` container whose storage comes from `cm()` (the
/// freeing container allocator) rather than the checker arena. Listed once so
/// `deinit` cannot fall behind the field set: a container added to `Checker`
/// and fed from `cm()` but forgotten here leaks its whole table.
/// Outcomes of the relation's lazy member route (`lazyRefRelate`), counted
/// under `--lazy-stats`. A conversion that is not firing looks exactly like a
/// conversion that is firing and losing, so the bail reasons are the only way
/// to aim the next one.
pub const LazyStat = enum(u8) {
    /// Decided by the lazy route.
    hit,
    /// Target is not a `.ref`.
    tgt_not_ref,
    /// Source is neither a `.ref` nor a materialized `.object`.
    src_kind,
    /// Both sides denote the same generic — the variance question.
    same_symbol,
    /// Source is a callable or fresh object literal.
    src_object_shape,
    /// A `this` marker on one of the four operands.
    this_types,

    // Why a side had no readable member table (`lazyTableOutcome`).
    /// `--eager-members`.
    tbl_disabled,
    /// Not an interface or class reference — an alias body REDUCES when
    /// instantiated, so its members are not a substitution of the generic's.
    tbl_not_nominal,
    /// The generic table is on the stack; `expandRef` cuts the cycle.
    tbl_in_progress,
    /// A class table built inside a materialization cycle, which `expandRef`
    /// refuses to publish.
    tbl_provisional,
    /// No `expandRef` has built this symbol's generic table yet, and this
    /// route may read one but never build one.
    tbl_unbuilt,
    /// The generic resolved to something other than an object (a base cycle).
    tbl_not_object,
    /// This exact reference's expansion is already memoized — the eager path
    /// is free and owns the `origin` tag.
    tbl_already_expanded,
    /// The table carries call/construct signatures, whose count does not
    /// survive instantiation (`higherOrderSigEligible`).
    tbl_has_sigs,
    /// The symbol declares no type parameters, so the expansion IS the
    /// generic and there is nothing to defer.
    tbl_no_type_params,
};

pub const map_containers = [_][]const u8{
    "node_types",               "sig_cache",            "node_scopes",
    "reassigned_syms",          "reassigned_in_loop",   "member_written_syms",
    "member_written_in_loop",   "ns_types",             "ambient_ns_types",
    "relation",                 "expansions",           "overload_rotate",
    "origin",                   "iface_generic",        "iface_stack",
    "pending_class_decos",      "class_inst_generic",   "class_static_cache",
    "class_static_base_active", "class_ctor_cache",     "enum_value_cache",
    "enum_info_cache",          "enum_relation_cache",  "alias_generic",
    "alias_state",              "alias_recursive",      "flow_same",
    "flow_narrow",              "ref_keys",             "flow_loop_stack",
    "flow_stack",               "flow_tmp",             "da_cache",
    "ctp_cache",                "cmp_cache",            "ctt_cache",
    "ci_cache",                 "infer_visited",        "subst_this_cache",
    "mmp_cache",                "arrayish_elem_cache",  "tp_constraint_cache",
    "erase_cache",              "erase_any_cache",      "inst_map_ids",
    "fresh_tp_ids",             "this_tp_ids",          "fresh_tp_info",
    "type_node_cache",          "atom_cache",           "infer_ids",
    "infer_scopes",             "mapped_key_ids",       "mapped_key_scopes",
    "inst_diag_at",             "infer_active",         "lazy_member_active",
    "chain_guards",             "never_isect",          "deep_path_list",
    "deep_path_ids",            "flow_reach",           "member_type_stack",
    "lazy_index_objs",          "pending_type_args",    "pending_type_args_pool",
    "pending_type_args_seen",   "tp_constrained_cache", "nominal_bases",
    "nominal_base_pool",        "keyof_mapped_active",  "ctp_syms_seen",
    "weak_types",               "lazy_member",          "lazy_map",
    "pattern_root_decls",       "pattern_root_ids",     "pattern_narrow_busy",
    "key_name_types",           "enum_members",         "keyof_obj_cache",
    "trunc_expansions",         "inst_map_bytes",       "tp_mentions",
    "smk_cache",
};

/// One enum member as `eachEnumMember` yields it: the name atom and the
/// constant value literal (`no_type` when the initializer is computed).
pub const EnumMemberEntry = struct { name: Atom, value: TypeId };
/// A memoized `keyof <object table>`, tagged with the `key_name_types`
/// generation it was computed under — see `Checker.keyof_obj_cache`.
pub const KeyofEntry = struct { ty: TypeId, gen: u32 };

/// Hash context for a DENSE INTEGER key — one 64-bit avalanche instead of
/// `AutoContext`'s Wyhash over the key's bytes.
///
/// Wyhash is the right default for arbitrary keys, but the checker's hottest
/// maps are keyed by packed small integers (`inst_cache`'s
/// `map_id << 32 | type_id`), and a general byte hash costs several times an
/// integer mix on an 8-byte key. `instantiateId` probes `inst_cache` 11.1 M
/// times on immich and inserts 5.9 M, which made this the single most executed
/// hash in the run.
///
/// The mix is the standard MurmurHash3 64-bit finalizer: every input bit
/// affects every output bit, so both halves of a packed key reach the bucket
/// index (low bits) and the slot fingerprint (top 7 bits). Nothing observable
/// depends on it — the maps it keys are pure memos, read only by `get`, and
/// nothing iterates them.
pub fn IntCtx(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            // A key wider than the mix folds its halves in first; every input
            // bit still reaches the finalizer (`smk_cache`'s 97-bit key).
            var x: u64 = if (@bitSizeOf(K) > 64)
                @as(u64, @truncate(k)) ^ (@as(u64, @truncate(k >> 64)) *% 0x9e3779b97f4a7c15)
            else
                k;
            x ^= x >> 33;
            x *%= 0xff51afd7ed558ccd;
            x ^= x >> 33;
            x *%= 0xc4ceb9fe1a85ec53;
            x ^= x >> 33;
            return x;
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            return a == b;
        }
    };
}

/// `std.AutoHashMapUnmanaged` with `IntCtx` in place of `AutoContext`.
pub fn IntMap(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, IntCtx(K), std.hash_map.default_max_load_percentage);
}

/// Where one symbol's declared heritage lives in `Checker.nominal_base_pool`.
/// Eight bytes per symbol ever asked, and the pool holds four bytes per
/// declared `extends` clause — see `declaredBaseRefs`.
pub const BaseSpan = struct { start: u32, len: u32 };

pub const Checker = struct {
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
    /// Prefix sums of per-file flow-node counts: `flow_base[f] + local` is a
    /// program-global flow id. Lets `FlowQ` pack `(file, flow)` into one u32
    /// (same idiom as `Program.sym_base`).
    flow_base: []const u32 = &.{},
    /// `flow_base[cur_file]`, refreshed by `setFile` — `flowType` runs on the
    /// current file's graph and is hot enough to want the index precomputed.
    cur_flow_base: u32 = 0,
    /// Prefix sums of per-file AST node counts: `node_base[f] + node` is a
    /// program-global node id (same idiom as `flow_base` / `Program.sym_base`).
    /// Used where a *declaration site* must name itself with a number that is a
    /// property of the program rather than of this checker's traversal order —
    /// see `uniqueSymType`.
    node_base: []const u32 = &.{},

    /// Checker arena: type store, caches. Freed at the end of check().
    /// Heap-allocated so `Allocator` handles stay valid when the Checker
    /// struct moves.
    carena: *std.heap.ArenaAllocator,
    /// Scratch arena: worklists, printer buffers. Released per EXPRESSION
    /// (`checkExprCached` takes a mark and restores it), with a whole-arena
    /// reset per statement behind that as a backstop — see `bump.zig` for the
    /// contract, which no caller may loosen back to per-statement.
    /// `scratch_arena` is a *pointer* so it can be swapped for `inst_arena`
    /// during the outermost `instantiate()` call (see `instantiate`), routing
    /// every transient allocation made while materializing a generic type into
    /// a region that is released the moment the top-level substitution
    /// finishes — bounding the per-statement scratch high-water to the largest
    /// single instantiation instead of the sum of all of a statement's.
    scratch_arena: *BumpArena,
    /// Dedicated arena swapped in for `scratch_arena` while the outermost
    /// `instantiate()` runs; reset (shrunk to `scratch_retain_limit`) at that
    /// call's exit. Never holds anything referenced past the top-level
    /// substitution: results are interned into `ts`, persistent keys into
    /// `carena` (the `canonMapId`/`mintFreshTp` discipline), so the reset frees
    /// only genuinely dead intermediates.
    ///
    /// Rewound at a finer grain than that, too: `instantiateId` takes a
    /// `BumpArena` mark on entry and restores it on exit, so the region holds
    /// one root-to-leaf path's buffers rather than every buffer the whole
    /// substitution ever made. See `BumpArena` for why the standard arena
    /// could not do this and what the discipline costs.
    inst_arena: *BumpArena,

    ts: Store = undefined,

    diags: std.ArrayList(Diag) = .empty,
    diag_seen: std.AutoHashMapUnmanaged(u128, void) = .empty,
    /// `(file << 32) | code` -> index into `diags` of this file's single
    /// instantiation-limit diagnostic (see `instLimitDiag`). Indices stay
    /// valid: `diags` only grows until `seal`, except for the speculative
    /// rollback in `argumentsMatch`, which goes through `rollbackDiags` and
    /// drops any entry it would strand.
    inst_diag_at: std.AutoHashMapUnmanaged(u64, usize) = .empty,

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
    /// misses and recomputes — fixing the first-check-wins staleness —
    /// while node-only readers still find the node's most-recent (canonical)
    /// type in the single slot.
    node_types: IntMap(u64, NodeType) = .empty,
    /// (file << 32 | FnProto node) -> signature TypeId + the contextual
    /// signature it was built under. Arrow/function-expression signatures
    /// depend on `ctx_sig` (contextual parameter types), so — like
    /// `node_types` — a re-check under a different context must miss and
    /// recompute rather than return the first (stale) signature. Named
    /// declarations always pass `no_type`, so they still hit unconditionally.
    sig_cache: IntMap(u64, NodeType) = .empty,
    /// (file << 32 | owner node) -> primary (lowest) scope id. Populated
    /// lazily per file by `faultScopes` on the first `scopeOf` read in that
    /// file (right-sizing), so a checker only maps scopes for files it
    /// actually traverses — not every file of the program, per instance.
    node_scopes: IntMap(u64, ScopeId) = .empty,
    /// Per-file flag: has this file's scope-owner map been faulted into
    /// `node_scopes` yet?
    scopes_faulted: []bool = &.{},
    /// Global SymbolIds that are the target of a reassignment (`x = …`, `x++`,
    /// destructuring-assignment element) *anywhere* in their file — i.e. not
    /// effectively `const`. Populated lazily per file by `ensureReassignScan`
    /// (see the `.start`/closure-capture gate in `flowTypeInner`). Order-
    /// invariant: a pure function of the file's assignment AST nodes.
    reassigned_syms: IntMap(SymbolId, void) = .empty,
    /// `(sym, for_head_scope)` pairs where `sym` is assigned somewhere inside a
    /// `for`/`for..of`/`for..in` whose header scope is `for_head_scope` (each
    /// enclosing loop of an assignment is recorded, so nested loops are all
    /// covered). Lets a loop label distinguish "reassigned *inside this loop*"
    /// from merely "reassigned before the loop" — the latter keeps its pre-loop
    /// narrowing across the loop (tsc), the former re-widens. Populated
    /// alongside `reassigned_syms` in `ensureReassignScan`.
    reassigned_in_loop: std.AutoHashMapUnmanaged(SymLoop, void) = .empty,
    /// Root symbols that are the base of a *member/element write* (`o.p = …`,
    /// `o[i] = …`, `o.p++`) somewhere in their file — i.e. a property path
    /// rooted at `sym` may be invalidated. Used only to decide whether a
    /// property-path narrowing survives a `while`/`do` loop back edge (the
    /// coarse, file-level over-approximation; `for` loops use the exact
    /// per-scope `member_written_in_loop`). Populated alongside
    /// `reassigned_syms` in `ensureReassignScan`.
    member_written_syms: IntMap(SymbolId, void) = .empty,
    /// `(root_sym, for_head_scope)` pairs where a member/element write rooted at
    /// `root_sym` occurs inside the loop whose header scope is `for_head_scope`.
    /// Lets a `for`-loop label keep a property-path narrowing whose root is not
    /// written inside the loop (over-conservative on the property name: any
    /// write to *some* property of the same root blocks the shortcut, which is
    /// sound — it can only fail to retain a narrowing, never introduce one).
    member_written_in_loop: std.AutoHashMapUnmanaged(SymLoop, void) = .empty,
    /// Per-file flag: has this file's reassignment scan run yet?
    reassign_scanned: []bool = &.{},
    /// Recursion depth of TS4.4 aliased-condition narrowing (following a
    /// `const` alias into its initializer, then possibly an alias-of-alias).
    /// Capped like tsc's `inlineLevel` to bound alias chains.
    alias_inline_level: u32 = 0,
    /// FileId -> module namespace object type (0 = in progress).
    ns_types: IntMap(FileId, TypeId) = .empty,
    /// Ambient-module namespace-object cache, keyed by ambient_exports index.
    ambient_ns_types: IntMap(u32, TypeId) = .empty,
    /// (source << 32 | target) -> Relation.
    ///
    /// Its SIZE is traversal-order dependent, and deliberately so: the `2`
    /// mark `relate` writes means "in progress, assume related", and a
    /// re-entry answered from it never recurses. Settle a pair before meeting
    /// it again and its subtree is walked and memoized; meet it while its own
    /// frame is live and the subtree is never visited. The verdicts are the
    /// same either way — this is tsc's `Ternary.Maybe` and the only thing that
    /// terminates a recursive type — but the SET of pairs reached is not, so
    /// `relation cache entries` (and `inst cache hits`, which counts the
    /// substitutions those extra subtrees re-request) move run to run wherever
    /// the traversal order does. Under the parallel front end it does: atom
    /// ids are the sort key every declaration and property table is reached
    /// through. See bench/repeat_sweep.sh, which pins both counters under a
    /// serial front end and documents why it cannot under a parallel one.
    relation: IntMap(u64, u8) = .empty,
    /// ref TypeId -> expanded structural type.
    expansions: IntMap(TypeId, TypeId) = .empty,
    /// ref TypeId -> the `budget_epoch` in which expanding it came back
    /// TRUNCATED (see `expandRef`). A truncation is not a fact about the
    /// reference, so it is never published to `expansions` — but it IS a fact
    /// about the budget window that produced it, and re-deriving it costs the
    /// full expansion prologue (`typeParamsOf`, `buildInstMap`, `canonMapId`)
    /// every time. An entry from an EARLIER window is stale and ignored, so
    /// the first reader in the next window recomputes exactly as before.
    trunc_expansions: IntMap(TypeId, u64) = .empty,
    /// `.overloads` TypeId -> the index at which its LAST declaration group
    /// starts. An entry exists only for a merged global function whose
    /// signatures come from two groups of declarations (the default library,
    /// and a module's `declare global { … }` augmentation of the same name).
    /// The interned member list is in declaration order — what
    /// `getSignaturesOfType` reports, and so what `ReturnType`/`Parameters`
    /// and the printer see — while overload RESOLUTION tries the last group
    /// first (tsc's `reorderCandidates`). `overloadCandidates` applies it;
    /// everything else reads the members as stored. See `mergedFunctionValue`.
    overload_rotate: IntMap(TypeId, u32) = .empty,
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
    origin: IntMap(TypeId, TypeId) = .empty,
    /// Declared (`in`/`out`) variance of a generic symbol's type parameters,
    /// packed 2 bits each (see `Variance`), lowest bits first. A cached 0 —
    /// the overwhelmingly common case — means "no parameter is annotated", so
    /// the relation's variance probe costs one hash lookup on hot paths.
    /// Parameters past the 16th are read as unannotated.
    variance_cache: IntMap(SymbolId, u32) = .empty,
    /// The two `G<…marker…>` references a variance MEASUREMENT is currently
    /// relating (`{0,0}` outside one). The relation must compare these
    /// structurally: answering them from `G`'s *declared* variance is what
    /// the measurement is trying to verify, so it would make every annotation
    /// vacuously true. tsc keeps the same exemption as its `markerTypes` set.
    variance_marker_refs: [2]TypeId = .{ 0, 0 },
    /// Structurally MEASURED variance of a generic symbol's type parameters
    /// (`Measured`, tsc's `getVariances`), packed 3 bits each, lowest bits
    /// first. A cached 0 means "no parameter yielded a verdict", so the
    /// relation's probe costs one hash lookup on hot paths. Parameters past
    /// the 10th are read as unmeasured.
    measured_variance: IntMap(SymbolId, u32) = .empty,
    /// Generic symbols whose measurement is on the stack right now. tsc's
    /// `emptyArray` sentinel: a pair of references to a generic that is
    /// measuring ITSELF is assumed related, which is what stops the
    /// measurement from chasing a generic that instantiates itself.
    measuring_variance: IntMap(SymbolId, void) = .empty,
    /// How many measurements are on the stack (`max_variance_measure_depth`).
    variance_measure_depth: u32 = 0,
    /// Every `G<…marker…>` reference ever minted for a variance measurement
    /// (tsc's `markerTypes`). Those pairs are what a measurement asks the
    /// relation about, so answering them FROM a variance verdict would make
    /// every measurement vacuously covariant.
    marker_refs: IntMap(TypeId, void) = .empty,
    /// Generic (uninstantiated) bodies per symbol: interface/class-instance/
    /// class-static/alias.
    iface_generic: IntMap(SymbolId, TypeId) = .empty,
    /// Gray stack of interfaces currently mid-resolution in `interfaceGeneric`
    /// (the ones marked `no_type`). Each frame records whether it is presently
    /// resolving its `extends` bases. On a re-entry, if *every* frame from the
    /// re-entered symbol to the top is in that base phase, the slice is a true
    /// `extends` cycle and TS2310 fires for every member — not just whichever
    /// symbol happened to start the traversal; a re-entry reached through a
    /// member/type-arg edge (a legal recursive reference) fires nothing. That
    /// makes the diagnostic set a pure function of the extends graph,
    /// independent of resolution/partition order.
    iface_stack: std.ArrayListUnmanaged(IfaceFrame) = .empty,
    /// Class-position decorators (`@deco class C {}`) pending their target.
    /// A decorator statement precedes its class in the same statement list;
    /// checkStatement pushes here and checkClass consumes them.
    pending_class_decos: std.ArrayListUnmanaged(Node) = .empty,
    /// Are we inside an ambient context (tsc's `NodeFlags.Ambient`)? Seeded
    /// per file from the `.d.ts` extension and pushed by every `declare`
    /// namespace / ambient module / `declare global` body. Drives the ambient
    /// grammar checks (TS1039).
    ambient_ctx: bool = false,
    /// Declared `extends` heritage per symbol, as a span of
    /// `nominal_base_pool` — the nominal-heritage relation fast path's index
    /// (`declaredBaseRefs`). Filled lazily, only for symbols the relation
    /// actually asks about, and empty-but-present for the ones with no
    /// heritage at all.
    nominal_bases: IntMap(SymbolId, BaseSpan) = .empty,
    /// Backing store for `nominal_bases`: each symbol's declared base
    /// references, laid out contiguously in the order they were written.
    nominal_base_pool: std.ArrayListUnmanaged(TypeId) = .empty,
    class_inst_generic: IntMap(SymbolId, TypeId) = .empty,
    class_static_cache: IntMap(SymbolId, TypeId) = .empty,
    /// Classes whose base-static fold is on the stack, so a malformed `extends`
    /// cycle skips the recursive base fold instead of overflowing (the result
    /// cache stays unpoisoned — static-field-initializer re-entry must still
    /// see the class's own members).
    class_static_base_active: IntMap(SymbolId, void) = .empty,
    /// Mapped types whose key set `keyofMapped` is enumerating. An `as` clause
    /// is allowed to mention `keyof` of the very map it renames the keys of
    /// (sequelize's `InferAttributes<M>` filters `Key extends keyof Model`,
    /// and `M` is a model class whose own attribute type IS that map), so
    /// remapping one key can ask for the key set again. That question has no
    /// answer yet; re-entry defers with `keyof <map>` — the same result the
    /// non-enumerable path already returns — instead of recursing until the
    /// thread stack dies.
    keyof_mapped_active: IntMap(TypeId, void) = .empty,
    /// Composite types `collectTypeParamSyms` has already walked, for the
    /// duration of one top-level collect. See there.
    ctp_syms_seen: IntMap(TypeId, void) = .empty,
    /// Member symbols whose type is being resolved by `lazyRefProp` (the
    /// cycle-safe single-member lookup). A member whose own annotation indexes
    /// back into the class at the very member being resolved (`class C { a:
    /// C["a"] }`) is genuinely circular; re-entry returns null so the caller
    /// falls back to the ordinary not-found result instead of recursing.
    lazy_member_active: IntMap(SymbolId, void) = .empty,
    /// Member symbols whose type `memberTypeOf` is computing, innermost last
    /// (both the eager whole-table walk and the lazy single-member lookup push
    /// here). A member that re-appears is one whose type demanded itself; the
    /// slice from its first occurrence to the top is exactly the circle, which
    /// `reportMemberCycle` names (TS2502 / TS7022 / TS7023). Reporting only —
    /// the recursion is cut where it always was.
    member_type_stack: std.ArrayListUnmanaged(SymbolId) = .empty,
    /// Object types of the single-member indexed accesses currently in flight
    /// (`C["m"]` taken while `C`'s own table is materializing). A GENERIC one
    /// is an access tsc defers — it answers with an unresolved
    /// `IndexedAccessType` and looks no member up — so a resolution circle
    /// that only closes through it is not a circle tsc ever sees, and
    /// `reportMemberCycle` stays silent. Kept as the raw object types so the
    /// genericity question is asked only when a circle is actually found; the
    /// lookup and its cut are unaffected either way.
    lazy_index_objs: std.ArrayListUnmanaged(TypeId) = .empty,
    /// Class symbol -> its *structural* constructor object (statics + construct
    /// signatures returning the instance). See `classConstructType`.
    class_ctor_cache: IntMap(SymbolId, TypeId) = .empty,
    /// The interned `typeof globalThis` marker (see `globalThisType`).
    global_this_ty: TypeId = types.no_type,
    /// Enum symbol -> value object type (the `typeof E` object with members).
    enum_value_cache: IntMap(SymbolId, TypeId) = .empty,
    /// Enum symbol -> computed EnumInfo (const-ness, member values).
    enum_info_cache: IntMap(SymbolId, EnumInfo) = .empty,
    /// Enum symbol -> its members' `(name, constant value)` in declaration
    /// order — `eachEnumMember`'s walk, memoized. The walk re-derives every
    /// member from the AST: it re-scans each name token, re-interns the text,
    /// re-classifies each initializer and re-folds aliased constants. Nothing
    /// in it depends on the caller, and every consumer asks about ONE member,
    /// so a whole-enum walk per question is quadratic in the enum's size.
    /// `enumMemberValue` alone (the relation, narrowing, and every enum-keyed
    /// index) measured 4.3% of immich's check phase that way. Interning is
    /// idempotent, so the memoized walk creates exactly the types the first
    /// unmemoized one created, in the same order.
    enum_members: IntMap(SymbolId, []const EnumMemberEntry) = .empty,
    /// Nesting of `aliasedEnumInitValue` — an enum member initialized with
    /// ANOTHER enum's member folds that member's constant value, and a cycle
    /// (`enum A { X = B.X }` / `enum B { X = A.X }`) would otherwise recur
    /// forever. tsc guards the same walk with `EvaluatorResult.isSyntacticallyString`
    /// bookkeeping plus a resolution cycle check; a depth cap is enough here
    /// because the fold is only ever a chain of constant references.
    enum_alias_depth: u32 = 0,
    /// `(source enum symbol, target enum symbol)` -> whether the two relate
    /// structurally (tsc's `enumRelation`). See `enumsStructurallyRelated`.
    enum_relation_cache: IntMap(u64, bool) = .empty,
    alias_generic: IntMap(SymbolId, TypeId) = .empty,
    alias_state: IntMap(SymbolId, u8) = .empty,
    /// Alias symbols found to be (transitively) self-recursive while their
    /// generic body was materialized — marked when `aliasInstance` re-enters an
    /// in-progress alias (state == 1). Used to scope the recursion-accumulator
    /// default substitution in `fixTypeArgs` (RHF `PathInternal<T, Tr = T>`)
    /// away from non-recursive library defaults (redux `Reducer<S, A, P = S>`).
    alias_recursive: IntMap(SymbolId, void) = .empty,
    /// Narrowed-type cache per `(flow, reference, declared)` query, split by
    /// outcome so the overwhelmingly common one costs no value slot. See
    /// `FlowQ` for the packed key and why the split is behaviour-preserving.
    ///
    /// `flow_same` holds every query whose answer is "the declared type" —
    /// both *in progress* (the loop sentinel) and *finished, nothing narrowed*.
    /// Those two states are observationally identical (`flowType` returns
    /// `declared` for either), so they can share one value-less set.
    flow_same: std.AutoHashMapUnmanaged(FlowQ, void) = .empty,
    /// The other ~1.5%: queries that actually narrowed. Disjoint from
    /// `flow_same` (a key is moved here when its result comes back != declared).
    flow_narrow: std.AutoHashMapUnmanaged(FlowQ, TypeId) = .empty,
    /// The queries currently on the `flowType` walk stack, innermost last.
    /// Only consulted on a `flow_same` hit under a back-edge walk (see
    /// `flowInFlight`), so a push/pop list beats a hash set by a wide margin.
    flow_stack: std.ArrayList(FlowQ) = .empty,
    /// Nesting bound for the re-walk `flowInFlight` unlocks.
    flow_busy_depth: u32 = 0,
    /// Transient memo for re-entrant answers taken while a loop fixpoint is in
    /// flight. They are derived from a *partial* fixpoint, so they must never
    /// reach `flow_same`/`flow_narrow`; without the memo the re-walk that
    /// produces them is exponential, because every node on the re-walked chain
    /// re-checks the expression that caused the re-entry. Valid only while some
    /// back-edge walk is in flight, so it is dropped when the outermost one
    /// finishes.
    flow_tmp: std.AutoHashMapUnmanaged(FlowQ, TypeId) = .empty,
    /// tsc's in-process loop-label stack. A query that re-enters a loop label
    /// still being computed is answered with the partial union gathered so far
    /// (see `LoopFrame`), never with the declared type.
    flow_loop_stack: std.ArrayList(LoopFrame) = .empty,
    /// Nesting depth of loop-label BACK-edge walks. Non-zero means every flow
    /// answer being computed right now is taken against a partial fixpoint, so
    /// it belongs in `flow_tmp` rather than the persistent cache.
    flow_back_edge: u32 = 0,
    /// Interned narrowing reference keys (RefQ -> dense index).
    ref_keys: std.AutoHashMapUnmanaged(RefQ, u32) = .empty,
    /// Over-deep reference paths, indexed by `RefKey.deep - 1`. Appended to
    /// only by `makeRefKey`, and only for the rare path that does not fit
    /// inline, so this stays a few dozen entries on a real project.
    deep_path_list: std.ArrayListUnmanaged(DeepPath) = .empty,
    /// The interning side of `deep_path_list` (path -> 1-based id, 0 = the
    /// table was full when this path was first seen, i.e. untracked).
    deep_path_ids: std.AutoHashMapUnmanaged(DeepPath, u16) = .empty,
    /// Declaration nodes (`file << 32 | node`) behind the object-binding-
    /// pattern pseudo-references of `narrowedPatternBinding`, indexed by
    /// `sym - pattern_root_base`. See `flow.zig`'s `pattern_root_base`.
    pattern_root_decls: std.ArrayListUnmanaged(u64) = .empty,
    /// The interning side of `pattern_root_decls` (decl -> index).
    pattern_root_ids: IntMap(u64, u32) = .empty,
    /// Re-entrancy guard for `narrowedPatternBinding` (tsc's
    /// `NodeCheckFlags.InCheckIdentifier`): the declarations whose pattern is
    /// having its narrowed parent type computed right now. Narrowing reads the
    /// guard expressions, which can name the pattern's own bindings.
    pattern_narrow_busy: IntMap(u64, void) = .empty,
    /// (flow << 32 | symbol) -> definitely-assigned (2 computing, 0/1 result).
    da_cache: IntMap(u64, u8) = .empty,
    /// Program-global flow id -> can control reach it (0 computing, 1 no,
    /// 2 yes). Consulted only when a flow query answered `never`, to tell a
    /// reference narrowed to nothing apart from one read in dead code — see
    /// `flowReachable`.
    flow_reach: IntMap(u32, u8) = .empty,
    /// containsTypeParam memo, a dense `TriMemo` (see it for why not a map).
    ctp_cache: std.ArrayList(u8) = .empty,
    /// containsMappedParam memo, dense like `ctp_cache`.
    cmp_cache: std.ArrayList(u8) = .empty,
    /// `(source << 32 | pattern) -> (generation << 1 | contra)`: the
    /// source/pattern pairs one `infer` match has already walked — tsc's
    /// `visited` map in `inferFromObjectTypes`. A repeat pair can only write
    /// the candidates it already wrote (every combine is idempotent in its own
    /// argument), so re-walking it is pure cost — and on a self-referential
    /// pattern (kysely's `SelectQueryBuilderExpression<infer O>`, an interface
    /// whose members are functions returning itself) that cost is exponential
    /// in the depth cap.
    infer_visited: IntMap(u64, u64) = .empty,
    /// Generation of the in-flight `inferFromExtends` root, so a nested root
    /// (reached through an `instantiate` inside the walk) gets a fresh key
    /// space and the outer one's entries survive its return. Monotonic and
    /// 64-bit wide, so a stale entry can never be mistaken for a live one.
    infer_gen: u64 = 0,
    infer_gen_next: u64 = 1,
    /// Did anything under the `inferFromExtends` frame being recorded hit the
    /// depth cut? A truncated walk is not a complete answer, so its
    /// `infer_visited` entry must never let a shallower repeat be skipped.
    infer_trunc: bool = false,
    /// Recursive `inferFromExtends` calls made by the in-flight inference root.
    /// Its guards arm only past `max_infer_steps` — see the escape hatch there.
    infer_steps: u64 = 0,
    /// `substThis` memo, keyed `(t << 32 | repl)`. Substituting a receiver into
    /// a member type is a pure function of the two interned ids, and the walk
    /// REBUILDS whole object shapes — drizzle's query builders declare `this`
    /// on nearly every member, so the same interface was rebuilt once per
    /// property access. Never populated for a result computed under a tripped
    /// instantiation limit (that answer is depth-dependent, not a function of
    /// the pair) — the same rule `inst_cache` follows.
    subst_this_cache: IntMap(u64, TypeId) = .empty,
    /// containsInfer memo, dense like `ctp_cache`. `inferFromExtends` now asks
    /// it at every step (the `couldContainTypeVariables` prune), and the walk
    /// itself is a full structural descent, so it has to be O(1) on a repeat.
    ci_cache: std.ArrayList(u8) = .empty,
    /// containsThisType memo, dense like `ctp_cache`. The walk descends into
    /// object members and deferred type operators, so it is not the cheap
    /// shallow test it once was; every `substThis` (i.e. every property
    /// access, once a program declares one `this` type) opens with it.
    ctt_cache: std.ArrayList(u8) = .empty,
    /// Numeric element type of a TUPLE or of a UNION of arrayish types —
    /// `numberIndexType`'s tuple arm and `elemOfArrayish`'s union arm, which
    /// are the same function of the same (immutable, interned) shape.
    ///
    /// The two are mutually recursive through a rest element (`[...T]` whose
    /// `T` is itself a tuple with a rest), so a nested variadic tuple —
    /// typebox's `TSchema` parameter packs are built from them — re-walks
    /// the whole nest once per element, and `tupleElemTypeAt` asks again per
    /// argument position on top of that. Both loops are self-time in the
    /// profile; the memo turns the repeated subtrees into one walk.
    /// Gated by `inst_cache_on` (`--no-inst-cache` is the oracle leg).
    arrayish_elem_cache: IntMap(TypeId, TypeId) = .empty,
    /// mentionsMappedParam memo, keyed `(t << 32 | key_id)`: 0 unknown/in
    /// progress, 1 no, 2 yes. Separate from `cmp_cache` because the answer
    /// depends on WHICH key parameter is asked about.
    mmp_cache: IntMap(u64, u8) = .empty,
    /// `substMappedKey` memo, keyed `(t, key_id, key_ty, homo_index_mode)`.
    ///
    /// Binding a mapped type's key is a second substitution walk, structurally
    /// parallel to `instantiate` but with its own recursion and — until this
    /// memo — no cache at all and no `inst_count` charge, so its cost is
    /// invisible in the node-visit counters every other experiment in
    /// `prof.zig` is scored on. `materializeMapped` runs one walk PER KEY over
    /// the same value template, and the templates that dominate this corpus
    /// (kysely's `Selection`/`UpdateObject`, vitest's `Mocked`) are large
    /// conditionals whose subterms mention the key in only one place, so the
    /// same `(subterm, key)` pair recurs across keys, across materializations
    /// of the same map, and across the many argument lists a builder chain
    /// applies it under.
    ///
    /// Sound for the same reason `inst_cache` is: the result is a pure
    /// function of the key, EXCEPT for the three pieces of live context the
    /// key or the guards account for — `cond_check_subst` (a per-constituent
    /// rebinding, so the memo is bypassed entirely while one is live),
    /// `homo_index_mode` (whether an optional property contributes
    /// `| undefined`, so it is in the key) and a truncated reduction (never
    /// published, the rule `inst_cache` follows). `key_name_types` can grow
    /// under a `keyof` in the template, so entries carry the generation they
    /// were computed under exactly as `keyof_obj_cache` does.
    smk_cache: IntMap(u128, KeyofEntry) = .empty,
    /// Instantiation memo: `(canonical_map_id << 32 | t) -> result`. A
    /// substitution is a pure function of `(t, map-contents)`; `map_id`
    /// canonically identifies the map's `(type-param, arg)` set (order- and
    /// slice-identity-independent, see `canonMapId`), so this is sound even
    /// though results are interned permanently. Gated by `inst_cache_on`
    /// (`--no-inst-cache` disables it — the correctness oracle / benchmark
    /// "before" leg). Never populated for a subtree whose computation tripped
    /// the depth/count limit (`inst_limit_tripped`).
    ///
    /// A BOUNDED direct-mapped cache, not an unbounded map: see
    /// `checker/memo.zig` for why (as a growable map it reached 104 MiB per
    /// instance at EVERY checker count — the largest single item in a
    /// checker's footprint, and 416 MB of immich's 1027 MiB peak at
    /// `--checkers=4`) and for why evicting an entry is sound.
    inst_cache: memo_zig.InstMemo = .{},
    /// Canonical substitution-map interning: packed sorted `(sym,arg)` pair
    /// bytes -> a small stable id. The byte keys are duped into the checker
    /// arena (scratch is reset per statement).
    inst_map_ids: std.StringHashMapUnmanaged(u32) = .empty,
    inst_map_next: u32 = 1,
    /// The inverse of `inst_map_ids`: `id - 1` indexes the SAME arena-owned
    /// packed bytes the key table holds, so a map id can be decoded back into
    /// a `[]TpMap` long after the slice it came from died. Needed by the
    /// deferred type-parameter bound (`FreshTp.pending_bound`), which records
    /// a map id at mint time and substitutes under it on first read, possibly
    /// in a different statement.
    inst_map_bytes: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `TypeId -> the set of type-param symbols it mentions` (`tpMentions`).
    /// Populated only for declared type-parameter constraints, which are few
    /// and small; see `boundMayMove`.
    tp_mentions: IntMap(TypeId, Mentions) = .empty,
    /// `SymbolId -> declared constraint TypeId` (`no_type` = unconstrained).
    /// Avoids re-resolving the constraint AST on every assignability check.
    tp_constraint_cache: IntMap(SymbolId, TypeId) = .empty,
    /// `eraseParamsOf` memo, keyed `(owner << 32 | sig)`. Erasing a
    /// signature's type parameters to their constraints (tsc's
    /// `getBaseSignature`, cached there on the signature's links) is a pure
    /// function of the `(sig, owner)` pair, and the signature relation asks
    /// for it on BOTH sides of every generic comparison — so a kysely builder
    /// chain re-derived the same erasure thousands of times, including the
    /// `tps.len - 1` constraint fixed-point rounds. It was the second-largest
    /// consumer of the per-statement instantiation budget in the
    /// `--inst-profile` measurement (1.2 M of 5.3 M node visits on the immich
    /// repro, over 11 k calls).
    ///
    /// Gated by `inst_cache_on` and, like `inst_cache`, never populated for a
    /// result whose computation tripped the depth/count limit — a truncated
    /// erasure is a function of the live depth, not of `(sig, owner)`.
    erase_cache: IntMap(u64, TypeId) = .empty,
    /// The same memo for the ERASE-TO-`any` half (tsc's `getErasedSignature`,
    /// cached on the signature as `erasedSignatureCache`), keyed the same way.
    erase_any_cache: IntMap(u64, TypeId) = .empty,
    /// tsc's `symbol.links.nameType`, for the one case ztsc cannot recover
    /// from a member table: a member declared with a computed ENUM-MEMBER key
    /// (`{ [E.A]: T }`). The table keys by the atom the key evaluates to
    /// (`"AV1"`), so `keyof` read back `"AV1" | …` and the enum's identity was
    /// gone — `T extends keyof M` no longer satisfied `T extends E`, which is
    /// immich's `src/utils/sync.ts:34` (`SyncItem` is keyed by
    /// `SyncEntityType`).
    ///
    /// Keyed by `(object type << 32) | atom`, recorded by
    /// `objectTypeFromMembers` once the object has been interned and read by
    /// `keyofObjectTable`. Attaching it to the TYPE rather than to `Prop`
    /// keeps the store's member layout — the hottest and most
    /// memory-sensitive structure in the checker — untouched, and the map
    /// stays empty on every program with no enum-keyed type.
    ///
    /// Object types are interned structurally, so a hand-written
    /// `{ 'AV1': T; … }` with the identical member shape shares the id and
    /// would read the same name types. That is the one imprecision, and it is
    /// the safe direction: the two spell the same key set, and the enum form
    /// is the more specific answer.
    key_name_types: IntMap(u64, TypeId) = .empty,
    /// `keyofObjectTable`'s answer for one interned member table.
    ///
    /// The key set of an OBJECT is a pure function of that object: the
    /// property names and their `private`/`protected` flags, the index
    /// signatures' presence, and the `key_name_types` entries — all of which
    /// are fixed when the object is interned (`objectTypeFromMembers` records
    /// the name types before anyone can hold the id). Recomputing it interns a
    /// string literal per property and builds a fresh union every time, and
    /// the mapped-type machinery asks the same table over and over: `keyof` is
    /// on half of immich's check-phase stacks, reached almost entirely through
    /// `substMappedKey`.
    ///
    /// Keyed by the OBJECT, not by the `keyof` operand, so the lazy route
    /// (`lazyShapeOf`'s generic table) and the eager one (`resolveStructural`'s
    /// substituted table) share entries whenever they land on the same table —
    /// which is the whole point of the lazy route.
    /// NOT a pure function of the object id, which is the trap: the answer
    /// reads `key_name_types`, a side table written against an object AFTER
    /// it is interned (`carryKeyNameTypes`, whose own `contains` guard shows
    /// it is built to accumulate). Objects are hash-consed, so one path can
    /// intern a table and have its `keyof` cached before a second path
    /// reaches the same TypeId and brings enum-member names along — the
    /// cached union would then be plain string literals forever. Entries
    /// therefore carry the `key_name_gen` they were computed under and are
    /// ignored once it moves. The counter is bumped only by a genuinely new
    /// `key_name_types` entry, which is rare (computed enum keys), so in
    /// practice the cache is never invalidated on corpora that have none.
    keyof_obj_cache: IntMap(TypeId, KeyofEntry) = .empty,
    /// Bumped by `putKeyNameType` on each new `key_name_types` entry; see
    /// `keyof_obj_cache`.
    key_name_gen: u32 = 0,
    /// Higher-order type-param rewrite. When an object's generic call/
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
    fresh_tp_ids: IntMap(u64, u32) = .empty,
    /// The same rewrite for the OTHER substitution that reaches a signature's
    /// own bounds — `substThis`, keyed by `(orig_param_sym, receiver TypeId)`.
    /// Separate table because a canonical map id and a `TypeId` are both `u32`
    /// and would collide in `fresh_tp_ids`; the records share `fresh_tp_info`.
    this_tp_ids: IntMap(u64, u32) = .empty,
    fresh_tp_info: std.ArrayListUnmanaged(FreshTp) = .empty,
    fresh_tp_base: u32 = 0,
    fresh_tp_next: u32 = 0,
    /// `(file << 32 | type-node) -> TypeId`. A type annotation resolves names
    /// against its (lexically fixed) enclosing scope and any enclosing
    /// interface's `this` type — both a deterministic function of the node's
    /// location — so a node's synthesized type is context-free and memoizable
    /// by node alone (unlike `node_types`, whose value is contextual). Gated by
    /// `inst_cache_on` so the oracle validates it.
    type_node_cache: IntMap(u64, TypeId) = .empty,
    /// Atom cache to avoid re-locking the shared interner.
    atom_cache: std.StringHashMapUnmanaged(Atom) = .empty,
    /// Recursion bound for the type-materializing fallback of qualified
    /// computed-key resolution (`constSymbolKeyAtom`): an adversarial alias
    /// cycle (`[A.k]` where `A`'s type materialization re-resolves the same
    /// key) degrades to the placeholder instead of recursing unboundedly.
    computed_key_depth: u32 = 0,
    /// `infer V` binder identity: (conditional nodeKey, name atom) -> a
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
    /// Mapped-type key parameter identity: mapped-type nodeKey -> a dense
    /// id for its `K` (stable across the memo-off re-evaluations of the node).
    mapped_key_ids: IntMap(u64, u32) = .empty,
    mapped_key_next: u32 = 1,
    /// Stack of the mapped key parameters currently in scope, outermost
    /// first. While building a mapped type's `as`/value branches, a bare
    /// reference to `K` resolves to that entry's `mapped_param` type; the
    /// constraint is evaluated with the entry not yet pushed. It is a STACK,
    /// not a single slot, because a mapped type nested in another mapped
    /// type's value must still see the ENCLOSING key: `{ [P in keyof S]: {
    /// [M in keyof S[P]]: S[P][M] } }` mentions `P` inside the inner map's
    /// value, and hono's `MergeSchemaPath` / ajv's `JTDSchemaType` do exactly
    /// that (a single slot reported TS2304 "Cannot find name 'P'" there).
    /// Lookup is innermost-out by name, so an inner key shadows a same-named
    /// outer one. See `lookupMappedKey` / the resolution site in
    /// `typeFromTypeNodeUncached`.
    mapped_key_scopes: std.ArrayListUnmanaged(MappedKeyScope) = .empty,
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
    /// Depth of "materializing a class field's type from its initializer"
    /// frames. While non-zero, `checkFunctionBody` queues the body onto
    /// `deferred_bodies` instead of walking it — see `DeferredBody`.
    defer_bodies: u32 = 0,
    /// Function bodies whose check was postponed out of a member-type
    /// materialization; drained once the enclosing class's instance type is
    /// complete. See `DeferredBody` / `drainDeferredBodies`.
    deferred_bodies: std.ArrayList(DeferredBody) = .empty,
    /// Written type-argument lists awaiting their TS2344 constraint check,
    /// drained after every owned file is checked. See `PendingTypeArgs`.
    pending_type_args: std.ArrayList(PendingTypeArgs) = .empty,
    /// One flat run of resolved arguments per `pending_type_args` entry, in
    /// queue order — the entries index it rather than each owning a slice, so
    /// the queue is one growable buffer instead of one allocation per
    /// reference. Cleared with the queue at the drain.
    pending_type_args_pool: std.ArrayList(TypeId) = .empty,
    /// `nodeKey`s already queued in `pending_type_args`, so a type node
    /// converted once per contextual variation queues its check once.
    pending_type_args_seen: IntMap(u64, void) = .empty,
    /// Per-generic-symbol memo of "declares a constrained type parameter"
    /// (see `symHasConstrainedTypeParam`) — the queue's admission test.
    tp_constrained_cache: IntMap(SymbolId, bool) = .empty,
    /// Depth of "checking a NON-STATIC class field's initializer" frames. Such
    /// an initializer runs at construction time, not at class-definition time,
    /// so a forward reference in it is not in the temporal dead zone — tsc's
    /// `isUsedInFunctionOrInstanceProperty` treats it exactly like a nested
    /// function body. A *static* field initializer does run at definition time
    /// and is deliberately not counted here. Read by `checkTdz`.
    instance_field_init_depth: u32 = 0,
    inst_depth: u32 = 0,
    /// Live recursion depth of alias-instance expansion (`aliasInstance`).
    /// `alias_state` already breaks *direct* self-recursion with a lazy ref, but
    /// a chain of mutually-referential generic aliases — especially conditional
    /// aliases whose type-argument *defaults* pull in the next alias — expands
    /// through a fresh sym at each step, so no single `alias_state` entry is ever
    /// "in progress". Bounded here against `max_alias_depth` so such a chain
    /// terminates (as `error_type`) instead of overflowing the worker stack.
    alias_depth: u32 = 0,
    /// Live nesting of `driveShrinkingAlias`, bounded by
    /// `max_eager_alias_depth` (see that constant).
    eager_alias_depth: u32 = 0,
    /// Live recursion depth of the structural assignability relation
    /// (`isAssignable`), checked against `max_relation_depth` to break the
    /// otherwise-unbounded walk over an undecidable recursive alias's
    /// expansions (see the constant's doc comment).
    rel_depth: u32 = 0,
    /// While a distributive conditional is being rebound per union
    /// constituent and its check is no longer a bare type parameter, the
    /// check EXPRESSION and the constituent standing in for it. `instantiateId`
    /// honours it at the top; see the `.conditional` arm.
    cond_check_subst: ?struct { from: TypeId, to: TypeId } = null,
    /// The `(type, receiver)` pairs `substThis` currently has open, innermost
    /// last. A pair that reappears on this stack is a cycle, not progress —
    /// see the guard in `substThis`. Sized by the nesting `substThis` can
    /// reach: it spends one `inst_depth` per frame and bails past
    /// `max_instantiation_depth`.
    this_subst_keys: [max_instantiation_depth + 2]u64 = @splat(0),
    /// The generic each open `substThis` frame is rewriting, when its subject
    /// is a reference — the growth test in `substThis` counts repeats of it.
    /// `no_symbol` for a frame whose subject is not a reference.
    this_subst_syms: [max_instantiation_depth + 2]SymbolId = @splat(binder.no_symbol),
    /// Live depth of `this_subst_keys`/`this_subst_syms`.
    this_subst_depth: u32 = 0,
    /// Bumped every time one of `substThis`'s guards (cycle pair, growth)
    /// answers with the unrewritten subject. A result computed while any cut
    /// fired underneath depends on the live stack, not on the `(t, repl)`
    /// pair alone, so `substThis` memoizes only when this counter is
    /// unchanged across the walk.
    this_subst_cuts: u64 = 0,
    /// The generic INSTANTIATION each live relation frame is comparing, one
    /// entry per side — the frame's origin ref (`refFacetOf`) and its symbol,
    /// pushed only for frames whose two sides are both generic instantiations.
    /// This is tsc's `sourceStack`/`targetStack`, and `relIdDeeplyNested` is
    /// its `isDeeplyNestedType`: a family of mutually recursive generics whose
    /// members return `Wrapper<this>` grows a new, strictly larger pair of
    /// instantiations at every level, so nothing ever repeats and neither the
    /// relation memo nor the expansion memo can close the walk. Seeing the
    /// same GENERIC re-entered as a strictly later instantiation is what
    /// closes it (see `max_relation_identity_repeats`).
    rel_src_ids: [max_relation_depth]RelId = @splat(.{ .sym = 0, .ref = 0 }),
    rel_tgt_ids: [max_relation_depth]RelId = @splat(.{ .sym = 0, .ref = 0 }),
    /// Live depth of `rel_src_ids`/`rel_tgt_ids`.
    rel_id_depth: u32 = 0,
    /// Index below which relation frames belong to an OUTER question and are
    /// invisible to the growing-instantiation test. Raised for the duration of
    /// a variance measurement, whose answer is cached per generic and so must
    /// not depend on the chain of frames that happened to demand it — see
    /// `measuredVariances`. The frames below the floor are still live and still
    /// pop themselves; only `relIdDeeplyNested`'s window moves.
    rel_id_floor: u32 = 0,
    /// Set whenever the growing-instantiation guard answered a pair from
    /// assumption rather than from its members. A relation run that consulted
    /// the guard is not evidence for a NEGATIVE verdict, so the two callers
    /// that build one out of a relation — variance MEASUREMENT
    /// (`measureOneVariance`) and the declared-variance check
    /// (`checkVarianceAnnotations`, TS2636) — clear it, run, and decline to
    /// conclude anything if it came back set. tsc's `VarianceFlags.Unmeasurable`
    /// / `Unreliable`, same purpose: a measurement whose relation was truncated
    /// must fall back to the structural walk, not silently answer "bivariant".
    rel_guard_tripped: bool = false,
    /// Nesting depth of an INTERSECTION-target decomposition. tsc relates a
    /// source to each constituent of an intersection target with
    /// `IntersectionState.Target`, which — among other things — turns the
    /// weak-type check off for those inner frames: only the intersection as a
    /// whole is judged weak (`isWeakType` requires *every* constituent to be),
    /// never one constituent on its own. Without that, `{a: 1}` against
    /// `{a: number} & {b?: string}` would be rejected for having nothing in
    /// common with `{b?: string}`. See `weakTypeMismatch`.
    rel_intersection_target: u16 = 0,
    /// Nesting depth of a SUBTYPE-REDUCTION probe (`reduceSubtypes`), where
    /// the weak-type check is not consulted. tsc reduces with
    /// `strictSubtypeRelation`, which does run the check — but what keeps
    /// tsc's answer clean for the shape this matters on is a different rule
    /// entirely: a union constituent that is an OBJECT LITERAL type and lacks
    /// the accessed property contributes `undefined` rather than making the
    /// property unreadable (`createUnionOrIntersectionProperty`'s
    /// WritePartial arm), so `let v = null; … v = { z: 1 }` reads `v?.y` as
    /// `number | undefined` even though `{ z: number }` survives the union.
    /// ztsc has no object-literal facet to carry that distinction (freshness
    /// is stripped by widening), and reaches the same answer by ABSORBING the
    /// constituent instead. Letting the weak rule block that absorption would
    /// turn a matched line into a phantom TS2339 (conformance flow/062);
    /// suppressing it here only ever makes a union smaller, so it can add no
    /// diagnostic. The residual divergence — an ANNOTATED sibling that tsc
    /// keeps and reports on — is pre-existing and unchanged.
    weak_rule_off: u16 = 0,
    /// Nesting depth of a UNION-target decomposition whose members include a
    /// CALLABLE one. Inside it a callable source is not weak-rejected: the
    /// callable constituent is the one that decides, and if it accepts (which
    /// is what tsc concludes for every such shape ztsc currently gets right)
    /// the weak constituent's verdict never mattered.
    ///
    /// The narrowing exists because the two verdicts are not independent in
    /// ztsc: a callable constituent ztsc wrongly rejects used to be rescued by
    /// the weak constituent accepting VACUOUSLY, and turning that vacuous
    /// acceptance into a rejection converts a silent miss into a phantom
    /// TS2769 plus uncontextualized-parameter TS7006s. kysely's
    /// `set(update: UpdateObject<…> | UpdateObjectFactory<…>)` is that shape:
    /// `UpdateObject` is an all-optional mapped type, and the factory's return
    /// type only checks once `fn<O>(…): ExpressionWrapper<DB, TB, O>` recovers
    /// `O` from a UNION contextual type — inference ztsc does not yet do (the
    /// gap is the builder-chain family, tracked with the rest of it). Skipping
    /// the rejection restores exactly the pre-rule behaviour on those shapes,
    /// so it can only ever LOSE a diagnostic tsc reports, never add one.
    ///
    /// `fs.watch(path, listener)` — the shape the weak rule exists for — is
    /// unaffected: its first overload's parameter is
    /// `WatchOptionsWithStringEncoding | BufferEncoding | null`, three
    /// constituents and not one of them callable.
    union_callable_sibling: u16 = 0,
    /// Memo for `isWeakType`: TypeId -> 1 weak / 0 not. The weak-type check
    /// runs on every relation frame with an object-ish target, and answering
    /// it means resolving the target's members, so the answer is kept.
    weak_types: IntMap(TypeId, u8) = .empty,
    /// **Symbols eagerly, types lazily** (tsc's `createInstantiatedSymbolTable`
    /// / `getTypeOfSymbol` split) — see `lazyTableOf`.
    ///
    /// `(ref << 32) | slot` -> the substituted type of one member of `ref`'s
    /// member table, where `slot` indexes the GENERIC table's properties (and
    /// the two slots past its end are the string / number index signatures).
    /// A member is materialized the first time some consumer asks for that
    /// member's TYPE — reading its NAME, optionality or readonly-ness costs
    /// nothing, because `instantiateId`'s `.object` arm carries all three
    /// through unchanged and substitutes only `Prop.ty`.
    ///
    /// Never holds a type computed while `inst_limit_tripped`: a truncated
    /// substitution is an artifact of the budget epoch that produced it, and
    /// publishing one would answer every later reader with it (the rule
    /// `eraseParamsOf` and `inst_cache` already follow).
    lazy_member: IntMap(u64, TypeId) = .empty,
    /// `ref` -> the type-parameter substitution its member table is read
    /// under, interned on the checker arena. Built once per reference rather
    /// than once per member: `buildInstMap` re-walks every declaration block's
    /// type-parameter list, which at 200 members would cost more than the
    /// substitutions it feeds.
    lazy_map: IntMap(TypeId, []@import("checker/enums.zig").TpMap) = .empty,
    /// Why the relation's lazy member route declined a pair, tallied per
    /// checker so the counters need no synchronization. Dumped at `seal` under
    /// `--lazy-stats`; pair with `--checkers=1`. See `LazyStat`.
    lazy_stats: [@typeInfo(LazyStat).@"enum".fields.len]u64 = @splat(0),
    /// Occupancy of the two stacks above, bucketed by the low bits of the
    /// symbol (`rel_id_bucket`). A bucket below `max_relation_identity_repeats`
    /// cannot hold that many occurrences of ANY symbol, so the scan the guard
    /// would otherwise run on every frame is skipped outright — which is the
    /// overwhelmingly common case (a generic pair met once).
    rel_src_buckets: [rel_id_buckets]u16 = @splat(0),
    rel_tgt_buckets: [rel_id_buckets]u16 = @splat(0),
    /// `instantiate` node-visits spent on the source element being checked
    /// (against `max_instantiation_count`); reset by `checkStatement`. Within
    /// a statement it is monotonic, with no exempt window — an exempt window
    /// would make the total depend on which side of it a memoized first visit
    /// happened to fall on, i.e. on traversal order (see
    /// `tagInstantiatedOrigin`).
    inst_count: u64 = 0,
    /// The cap `inst_count` is measured against for the window in flight:
    /// `max_instantiation_count` for a source element,
    /// `max_decl_instantiation_count` for the cross-file declaration
    /// materialization window `enterSymFile` opens. Saved and restored with
    /// the rest of the context, so a statement that demands a declaration
    /// gets its own cap back on the way out.
    inst_budget: u64 = max_instantiation_count,
    /// Identity of the budget window in flight. Bumped — never reused — every
    /// time `inst_count` starts over or is rolled back, i.e. at exactly the
    /// points where "how much budget is left" stops being comparable with what
    /// it was: a new source element (`checkStatement`), a declaration
    /// materialization (`enterSymFile`), a variance measurement, a queued
    /// type-argument check, and an overload candidate's refund. `restoreCtx`
    /// puts the OUTER window's id back, because it puts the outer
    /// `inst_count` back with it — the inner window is simply not part of the
    /// outer one's ledger.
    ///
    /// It exists so a result that is an artifact of a spent budget can be
    /// cached against the window that spent it instead of either being
    /// republished forever (which makes the whole run's answer a function of
    /// which element got there first — see `expandRef`) or recomputed from
    /// scratch on every ask (which is quadratic, and on drizzle-orm was
    /// 2 million re-derivations of one class table).
    budget_epoch: u64 = 0,
    /// Source of fresh `budget_epoch` ids. Monotonic per checker instance.
    budget_epoch_next: u64 = 0,
    /// Every node-visit this checker performed, never reset. The budget above
    /// is scoped to a statement; this is the work counter the `--memory`
    /// report and `bench/repeat_sweep.sh` compare across runs.
    inst_total: u64 = 0,
    /// PROFILER ONLY (`--inst-profile`): the symbol whose declaration
    /// materialization opened the live budget window — the innermost
    /// `enterSymFile` — or 0 while the window is a source element's own.
    ///
    /// `restoreCtx` puts `inst_count` back, so EVERY declaration frame, not
    /// just a cross-file one, is a window whose cost the requesting element is
    /// not charged for. This names the frame a budget trip actually belongs
    /// to, which is never the statement `instSpanHere` anchors its TS2589 at —
    /// the distinction that ruled out the whole "charge table construction
    /// elsewhere" family (see `src/checker/prof.zig`). Written only when the
    /// profiler is on, so it costs a predictable-false branch and one word in
    /// `SavedCtx` otherwise.
    epoch_sym: SymbolId = 0,
    /// The types on the live `instantiateId` stack, indexed by `inst_depth`.
    /// Read only by `chainRepeats`; a frame's ancestors are the same set
    /// whatever the memo did to its siblings, which is what makes a guard
    /// built on them cache-independent.
    inst_chain: [max_instantiation_depth + 2]TypeId = @splat(0),
    /// Set when the current top-level `instantiate` call tripped the depth or
    /// count limit; suppresses memoization of the (truncated) results for that
    /// call. Reset at each top-level entry (`inst_depth == 0`).
    inst_limit_tripped: bool = false,
    /// Diagnostic anchor used when the instantiation limit is hit (TS2589 /
    /// TS2590), tracked at expression / statement / assignability boundaries
    /// where materialization is triggered. `ast.Ast.span` walks the whole
    /// subtree and re-scans every token it covers, so the hot boundaries
    /// record just the node and pay for the span only if a diagnostic
    /// actually fires. The file is captured too: materializing a type can
    /// switch the current-file context (`enterSymFile`), so the anchor's
    /// offset is only a position in the file it was recorded in —
    /// `instLimitDiag` files the diagnostic under *that* file rather than
    /// reinterpreting the offset against `cur_file`'s line table.
    inst_anchor: InstAnchor = .{ .span = .{ .file = 0, .span = .{ .start = 0, .end = 0 } } },
    /// Master switch for the instantiation caching layer (`--no-inst-cache` clears it):
    /// the instantiate memo, map interning, constraint memo, and type-node
    /// memo. The depth/count limits are independent of it.
    inst_cache_on: bool = true,
    /// While set, `instantiateId`'s depth/count guard truncates silently
    /// (no TS2589) — used for origin-tag bookkeeping (`tagInstantiatedOrigin`).
    suppress_inst_diag: bool = false,
    /// Instantiation-demand profiler (`ZTSC_INST_PROFILE=1`; see
    /// `checker/prof.zig`). `prof.on` is false in every normal run and the
    /// instrumentation points are single predictable branches.
    prof: prof_zig.InstProf = .{},
    /// Declaration-window TIME profiler (`--decl-profile`; see the second
    /// half of `checker/prof.zig`). Off in every normal run.
    dprof: prof_zig.DeclProf = .{},
    /// Per-checker memory profiler (`--mem-profile`; see
    /// `checker/memprof.zig`). Off in every normal run.
    mprof: memprof_zig.MemProf = .{},
    /// Depth of an in-flight *side query*: a type looked up from inside the
    /// flow-narrowing walk, out of the checker's top-down order (see
    /// `declaredPathType`). While non-zero `diagFmt` drops diagnostics — the
    /// authoritative top-down check reports at the narrowed type, and a
    /// narrowing query must never be the thing that files an error.
    side_query_depth: u32 = 0,
    /// Nesting depth of a conditional type's TRUE branch, while its type
    /// nodes are being synthesized. tsc wraps every occurrence of the check
    /// type inside that branch in a *substitution type* constrained by the
    /// `extends` type (see `condTrueUnderExtends`); ztsc has none, so a
    /// `T["k"]` there still reads `T`'s declared constraint and would look
    /// unindexable even when the branch guarantees the key. The only reader
    /// is `checkIndexedAccessIndexType`, which stays silent while this is
    /// non-zero.
    cond_true_depth: u32 = 0,
    /// Depth of an in-flight *trial* check: the expression is checked exactly
    /// as the authoritative pass would — same relations, same inference, same
    /// diagnostics — but its answer must not be written to the `node_types`
    /// memo. Overload probing needs this and `side_query_depth` does not fit:
    /// a side query also turns `any` into an inference wildcard and swallows
    /// diagnostics, both of which change which overload is picked.
    no_publish_depth: u32 = 0,
    /// Contravariant inference candidates for the in-flight call, one per type
    /// parameter — tsc's `InferenceInfo.contraCandidates`. `contra_owner` is
    /// the identity of the covariant accumulator they belong to, so the many
    /// other arrays `unify` is handed (a reverse-mapped element, a speculative
    /// copy, a generic argument's own type params) simply do not participate.
    /// Saved and restored around a nested call's inference.
    contra_cands: []TypeId = &.{},
    contra_owner: ?[*]TypeId = null,
    /// Parameter-position nesting depth inside `unify`: odd means the current
    /// inference position is contravariant. tsc flips the same bit in
    /// `inferFromContravariantTypes` when it descends a signature's parameters.
    contra_pos: u32 = 0,
    /// tsc's `InferenceInfo.topLevel`, one flag per type parameter of the
    /// in-flight call: false once a candidate has been recorded from a position
    /// that is not at the top level of the parameter type it came from. Only a
    /// still-top-level parameter widens a fresh-literal candidate
    /// (`getCovariantInference`). Shares `contra_owner`'s identity check.
    top_flags: []bool = &.{},
    /// tsc's `InferencePriority.HomomorphicMappedType`, one flag per type
    /// parameter of the in-flight call: true while the only evidence recorded
    /// for it came from REVERSE-MAPPED inference (`Partial<T>`, `Readonly<T>`,
    /// a homomorphic mapped parameter). tsc keeps only the candidates at the
    /// best priority it saw, so a direct structural candidate replaces a
    /// reverse-mapped one outright and a reverse-mapped one arriving second is
    /// discarded. Shares `contra_owner`'s identity check.
    rev_flags: []bool = &.{},
    /// Non-zero while `unify` is running *inside* a homomorphic-mapped-parameter
    /// inference (the alias-identity pairing in `inferReverseMapped`), so the
    /// candidates it records carry the same `InferencePriority.
    /// HomomorphicMappedType` the reverse-mapped rebuild they replace does: they
    /// stand down for a direct structural match and are discarded when one
    /// already answered.
    rev_prio: u32 = 0,
    /// Nesting depth inside `unify` below a non-top-level constructor. Unions
    /// and intersections preserve top-level-ness (tsc's
    /// `isTypeParameterAtTopLevel` descends them); everything else does not.
    nontop_depth: u32 = 0,
    /// Non-zero while `unify` is running the contextual-RETURN pass
    /// (`fillFromReturnContext`), i.e. at tsc's `InferencePriority.ReturnType`.
    /// The distinction matters for the untargeted union-SOURCE rule, which
    /// lets several constituents each contribute a candidate: `ReturnType` is
    /// in tsc's `PriorityImpliesCombination`, so `getCovariantInference`
    /// UNIONS those candidates, while at ordinary priority it common-
    /// supertypes them — and a common supertype of two literal-ish candidates
    /// widens (excalidraw's `DropdownMenuItemContentRadio<T>` inferred `T =
    /// string` instead of `Theme | "system"`). ztsc has no priority ladder, so
    /// the rule is scoped to the pass where tsc's fold is the combining one.
    ret_ctx_prio: u32 = 0,
    /// Set while checking the operand of an `expr as const` const
    /// assertion: object/array literals produce readonly, non-widened,
    /// literal-typed members (recursively). Cleared at function bodies.
    const_ctx: bool = false,
    /// Type-parameter symbols of every `inferTypeArgs` call currently on the
    /// stack (innermost last). A symbol in here but *not* in the current call's
    /// `tp_syms` is an OUTER call's still-in-flight inference variable — tsc
    /// maps those to `silentNeverType` before running the contextual-return
    /// inference (`InferenceFlags.NoDefault`), so they must contribute no
    /// candidate. A generic function's own type parameters, seen while checking
    /// its body, are never on this stack, so inferring `U = T` from an enclosing
    /// signature's fixed `T` still works.
    infer_active: std.ArrayListUnmanaged(u32) = .empty,
    /// References an enclosing optional chain has already guarded, while the
    /// *sub*expression that the chain only evaluates on the non-nullish branch
    /// is being checked (see `pushChainGuards`). Empty everywhere else, so the
    /// narrowing hook costs one length test per reference read.
    chain_guards: std.ArrayListUnmanaged(RefKey) = .empty,
    /// Memo for `intersectionIsNever` (tsc's `getReducedType`), keyed by the
    /// intersection type.
    never_isect: IntMap(TypeId, bool) = .empty,
    stats: Stats = .{},

    // Well-known atoms (interned once in init).
    atom_length: Atom = 0,
    typeof_atoms: [8]Atom = @splat(0),
    typeof_union: TypeId = 0,
    // Names of the lib interfaces primitives/arrays bridge to.
    atom_Array: Atom = 0,
    atom_String: Atom = 0,
    atom_Number: Atom = 0,
    atom_Boolean: Atom = 0,
    atom_Function: Atom = 0,
    atom_Object: Atom = 0,
    /// The one member a class's constructor side gets that the global
    /// `Function` interface does not supply usefully — see `classValueProp`.
    atom_prototype: Atom = 0,
    /// Guard against `objectInterfaceProp` recursing through the `Object`
    /// interface's own member lookup.
    in_object_iface: bool = false,
    // Names of the lib interfaces async/await + generators bridge to.
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
    /// `default`, for the synthetic default an interop `import("m")` gets over
    /// an `export =` module (`importCallType`).
    atom_default: Atom = 0,
    atom_IntrinsicElements: Atom = 0,
    atom_Element: Atom = 0,
    atom_ElementAttributesProperty: Atom = 0,
    atom_ElementChildrenAttribute: Atom = 0,
    atom_IntrinsicAttributes: Atom = 0,
    atom_IntrinsicClassAttributes: Atom = 0,
    atom_children: Atom = 0,

    pub const typeof_names = [8][]const u8{
        "string", "number", "bigint", "boolean", "symbol", "undefined", "object", "function",
    };

    pub fn init(
        out: Allocator,
        io: Io,
        gpa: Allocator,
        interner: *Interner,
        prog: *const modules.Program,
        owned: []const FileId,
        /// Frozen shared base type store. When non-null, this
        /// checker's store is an overlay over it, so lib/`@types` types the
        /// base already holds are shared (not re-interned per checker). Null
        /// keeps the pre-frozen-base per-checker-expands-everything path
        /// (`--no-frozen-store`).
        base: ?*const types.Store,
        /// Enable the instantiation caching layer (`false` under
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
            .prof = .{ .on = prof_zig.enabled() },
            .dprof = .{ .on = prof_zig.declEnabled() },
            .mprof = .{ .on = memprof_zig.enabled() },
        };
        c.carena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.carena);
        c.carena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.carena.deinit();
        c.scratch_arena = try gpa.create(BumpArena);
        errdefer gpa.destroy(c.scratch_arena);
        c.scratch_arena.* = BumpArena.init(std.heap.page_allocator);
        errdefer c.scratch_arena.deinit();
        c.inst_arena = try gpa.create(BumpArena);
        errdefer gpa.destroy(c.inst_arena);
        c.inst_arena.* = BumpArena.init(std.heap.page_allocator);
        errdefer c.inst_arena.deinit();
        const arena_alloc = c.carena.allocator();
        // The store's SoA arrays are the checker's other big *growable*
        // containers (see `cm`): `extra` alone reaches ~6 MB and, at the
        // ArrayList 1.5× growth factor, strands ~2× that in abandoned
        // predecessors when it lives on the arena. Overlay stores therefore
        // grow on `cm()` and are `deinit`ed; the frozen *base* store keeps its
        // caller-supplied arena (built once, shared read-only, never freed).
        c.ts = if (base) |b| try Store.initOverlay(c.cm(), b) else try Store.init(arena_alloc);
        // Pre-size the hash-consing map. Growing it is not the usual amortized
        // O(1): every rehash re-derives each stored key's *shape* — the whole
        // `extra` payload of the type — and Wyhashes it, so the doubling
        // sequence costs ~2x one full pass over every type's payload. It
        // measured ~11% of the check phase on @sinclair/typebox.
        //
        // Half the owned AST node count is the estimate: types run ~0.25-0.5
        // per node across the benchmark packages, so this lands one doubling
        // short of the final size — the map ends at exactly the capacity it
        // would have reached anyway (peak RSS unchanged, measured on all five
        // packages), while the whole geometric tail of small rehashes is
        // skipped. Reserving the full node count removes the last rehash too
        // but overshoots the final capacity, and cost 1-2 MB of peak RSS on
        // zod/drizzle/hono for ~1% more wall — not the trade this project makes.
        //
        // The estimate is taken over the WHOLE program's nodes, not this
        // checker's own files, once the program is large enough for the
        // difference to matter. A checker's type population is a function of
        // the declarations it walks, and it walks the program: at
        // `--checkers=4` immich's four checkers intern 1.81-1.96 M types EACH
        // against a c1 total of 2.51 M, so per-checker demand is ~invariant in
        // the checker count while `owned` is not. Dividing the estimate by the
        // partition therefore made it 4x too small exactly where it is worth
        // the most — immich's reserve was ~142 k against 1.9 M actual, four
        // doublings short, and every one of those rehashes re-derives the full
        // shape of every type already interned.
        //
        // Gated on program size because the small-program side of this is a
        // peak-RSS question and the margins there are tight: all eight parity
        // packages are under the gate (21 k - 116 k nodes), so their reserve —
        // and their peak RSS, several rows of which sit within a few hundred
        // kilobytes of the 20%-of-tsgo bar — is byte-identical to before.
        {
            var owned_nodes: usize = 0;
            for (owned) |f| owned_nodes += prog.files[f].tree.nodes.len;
            var prog_nodes: usize = 0;
            for (prog.files) |*pf| prog_nodes += pf.tree.nodes.len;
            const est = if (prog_nodes > large_program_nodes) prog_nodes else owned_nodes;
            try c.ts.reserveTypes(est / 2);
        }
        // Sized to include the merged-symbol range (ids ≥ totalSymbols()),
        // so merged ids are valid sym_types/sym_state indices. These
        // are indexed by *global* SymbolId — a checker reads them for foreign
        // (lib/import/merged) symbols too, so they must span the whole space.
        // Right-sizing: a `ZeroPagedArray` maps them demand-zeroed, so the
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
        // Bounded instantiation memo (see `checker/memo.zig`): starts at
        // 12 KiB, doubles as it fills, and stops at 3 MiB however much the
        // program asks for.
        if (inst_cache_on) c.inst_cache = try memo_zig.InstMemo.alloc();
        errdefer c.inst_cache.free();
        c.owned_mask = try arena_alloc.alloc(bool, prog.files.len);
        @memset(c.owned_mask, false);
        for (owned) |f| c.owned_mask[f] = true;
        // Global flow-id bases (see `flow_base`). Flow nodes are strictly
        // fewer than symbols program-wide, so the same u32 prefix sum that
        // `Program.sym_base` uses is equally safe here.
        const fbase = try arena_alloc.alloc(u32, prog.files.len + 1);
        fbase[0] = 0;
        for (prog.files, 0..) |*pf, i| fbase[i + 1] = fbase[i] + @as(u32, @intCast(pf.bind.flow_tags.len));
        c.flow_base = fbase;
        c.cur_flow_base = fbase[first];
        // Global node-id bases (see `node_base`).
        const nbase = try arena_alloc.alloc(u32, prog.files.len + 1);
        nbase[0] = 0;
        for (prog.files, 0..) |*pf, i| nbase[i + 1] = nbase[i] + @as(u32, @intCast(pf.tree.nodes.len));
        c.node_base = nbase;
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
        c.atom_Object = try c.atom("Object");
        c.atom_prototype = try c.atom("prototype");
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
        c.atom_default = try c.atom("default");
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

    pub fn deinit(c: *Checker) void {
        c.sym_types.free();
        c.sym_state.free();
        c.inst_cache.free();
        c.diag_seen.deinit(c.gpa);
        c.diags.deinit(c.gpa);
        c.prof.deinit(c.gpa);
        c.dprof.deinit(c.gpa);
        c.mprof.deinit(c.gpa);
        inline for (map_containers) |n| @field(c, n).deinit(c.cm());
        if (c.ts.base != null) c.ts.deinit(); // overlay only; a base store is arena-owned
        c.carena.deinit();
        c.gpa.destroy(c.carena);
        c.scratch_arena.deinit();
        c.gpa.destroy(c.scratch_arena);
        c.inst_arena.deinit();
        c.gpa.destroy(c.inst_arena);
    }

    pub fn run(c: *Checker) Error!void {
        prof_zig.declRunStart(c);
        defer prof_zig.declRunEnd(c);
        memprof_zig.runStart(c);
        for (c.owned) |f| {
            c.setFile(f);
            c.cur_scope = binder.file_scope;
            c.fn_ctx = null;
            c.this_type = 0;
            // A declaration file is one big ambient context, and its top-level
            // declarations need `declare`/`export` (TS1046).
            c.ambient_ctx = parser.isDeclarationPath(c.prog.files[f].path);
            if (c.ambient_ctx) try stmts_zig.checkDeclFileTopLevel(c);
            for (c.tree.nodeRange(0)) |stmt| {
                if (stmt != null_node) try c.checkStatement(stmt);
                // Every class touched by this statement now has a complete
                // instance type, so the function bodies its field initializers
                // deferred can be walked (see `DeferredBody`).
                try c.drainDeferredBodies();
                c.noteScratch();
                _ = c.scratch_arena.reset(.{ .retain_with_limit = scratch_retain_limit });
                if (c.mprof.on) memprof_zig.sample(c);
            }
        }
        // Every class instance type is now complete, so the written type
        // arguments collected along the way can be judged against their
        // constraints (TS2344 — see `PendingTypeArgs`).
        try typenode_zig.drainTypeArgConstraints(c);
        _ = c.scratch_arena.reset(.{ .retain_with_limit = scratch_retain_limit });
        // TDZ / use-before-assign / 2304 come from the walk itself.
        // Debug-only soundness net over every composite interned this run: a
        // member id past the id space is the fingerprint of a use-after-realloc
        // escape into an interned type (compiled out in release).
        c.ts.debugValidateComposites();
    }

    pub fn seal(c: *Checker) Error!Check {
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
        c.stats.instantiations = c.inst_total;
        if (c.prof.on) prof_zig.report(c);
        if (c.dprof.on) prof_zig.declReport(c);
        if (c.mprof.on) memprof_zig.report(c);
        if (lazy_zig.stats_on) {
            var buf: [512]u8 = undefined;
            var used: usize = 0;
            inline for (@typeInfo(LazyStat).@"enum".fields) |f| {
                const line = std.fmt.bufPrint(buf[used..], "{s}={d} ", .{ f.name, c.lazy_stats[f.value] }) catch buf[used..used];
                used += line.len;
            }
            std.debug.print("lazy relation route: {s}\n", .{buf[0..used]});
        }
        return .{ .diagnostics = list, .stats = c.stats };
    }

    pub fn noteScratch(c: *Checker) void {
        const cap = c.scratch_arena.queryCapacity();
        if (cap > c.stats.scratch_high_water) c.stats.scratch_high_water = cap;
    }

    pub fn scratch(c: *Checker) Allocator {
        return c.scratch_arena.allocator();
    }

    /// Read a dense tri-state memo (`ctp_cache` / `cmp_cache`): 0 unknown or
    /// in progress, 1 no, 2 yes. Out of range reads as 0, so an entry that
    /// was never written is indistinguishable from "unknown" — the same
    /// contract the hash-map form had for an absent key.
    ///
    /// These are keyed by `TypeId`, and a `TypeId` is a dense counter: the
    /// frozen base holds only the 17 intrinsics, so every type a checker
    /// materializes is `base_len + local_index`. A byte per type is both
    /// smaller and faster than a hash entry — the maps were ~7% of the check
    /// phase on @sinclair/typebox, nearly all of it hashing and probing.
    pub fn triGet(_: *const Checker, v: *const std.ArrayList(u8), t: TypeId) u8 {
        return if (t < v.items.len) v.items[t] else 0;
    }

    pub fn triSet(c: *Checker, v: *std.ArrayList(u8), t: TypeId, val: u8) Error!void {
        if (t >= v.items.len) try v.appendNTimes(c.cm(), 0, t + 1 - v.items.len);
        v.items[t] = val;
    }
    /// Allocator for stable, one-shot checker payload (never individually
    /// freed): interned enum value arrays, canonical substitution-map key
    /// bytes, the per-file flag arrays. Bump-allocated out of `carena`.
    pub fn ca(c: *Checker) Allocator {
        return c.carena.allocator();
    }
    /// Allocator for the checker's *growable* containers (`map_containers`:
    /// every long-lived cache map / list below). These repeatedly realloc as
    /// they double, and an arena cannot reuse a realloc predecessor's bytes —
    /// it abandons them in place, still resident. On the dogfood project that dead tail was
    /// ~59 MB *per checker* (~236 MB at `--checkers=4`), more than half of
    /// every checker arena. Routing them to a freeing allocator instead makes
    /// each grow hand the predecessor straight back (`smp_allocator` serves
    /// anything ≥ 64 KiB — i.e. every one of these once it matters — directly
    /// from `PageAllocator`, so the old buffer is unmapped, not pooled).
    /// The arena keeps only what it is good at: payload that is written once
    /// and lives to the end of the check.
    ///
    /// The containers must therefore be `deinit`ed (see `deinit`) — losing one
    /// is a leak, which shows up as exactly the RSS this buys back. Safe by
    /// construction w.r.t. output: none of them is ever *iterated* (all are
    /// keyed point lookups) and no entry pointer is held across a later
    /// insertion, so no diagnostic can depend on where their storage lands.
    pub fn cm(c: *Checker) Allocator {
        _ = c;
        return std.heap.smp_allocator;
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

    pub fn setFile(c: *Checker, f: FileId) void {
        c.cur_file = f;
        const pf = &c.prog.files[f];
        c.tree = pf.tree;
        c.bind = pf.bind;
        c.src = pf.src;
        c.cur_flow_base = c.flow_base[f];
    }

    /// The ambient `this` *and* the instantiation budget travel with the
    /// file/scope context: a lazy demand that crosses into another file must
    /// not carry the demanding frame's `this` — nor spend the demanding
    /// frame's budget — with it (see `enterSymFile`).
    pub const SavedCtx = struct {
        file: FileId,
        scope: ScopeId,
        this_type: TypeId,
        inst_count: u64,
        inst_budget: u64,
        budget_epoch: u64,
        epoch_sym: SymbolId,
    };

    pub fn saveCtx(c: *const Checker) SavedCtx {
        return .{
            .file = c.cur_file,
            .scope = c.cur_scope,
            .this_type = c.this_type,
            .inst_count = c.inst_count,
            .inst_budget = c.inst_budget,
            .budget_epoch = c.budget_epoch,
            .epoch_sym = c.epoch_sym,
        };
    }

    pub fn restoreCtx(c: *Checker, s: SavedCtx) void {
        if (s.file != c.cur_file) c.setFile(s.file);
        c.cur_scope = s.scope;
        c.this_type = s.this_type;
        c.inst_count = s.inst_count;
        c.inst_budget = s.inst_budget;
        c.budget_epoch = s.budget_epoch;
        c.epoch_sym = s.epoch_sym;
    }

    /// Open a fresh instantiation-budget window (see `budget_epoch`). Called
    /// wherever `inst_count` restarts or is refunded, so nothing computed
    /// against the previous window's remaining budget is served to this one.
    pub fn newBudgetWindow(c: *Checker) void {
        c.budget_epoch_next += 1;
        c.budget_epoch = c.budget_epoch_next;
    }

    /// Switch to `sym`'s file (scope untouched; callers set it).
    ///
    /// Crossing a file boundary drops `this`. Symbol types are materialized on
    /// demand, so the frame that triggers the demand is arbitrary — it may be
    /// the middle of some class body — and `this_type` is a single mutable
    /// field, not part of the walk state. Without the reset a class body that
    /// demands a symbol from another file leaks its own `this` into whatever
    /// expression that file's materialization walks, which makes the answer a
    /// function of the file partition (`--checkers=N`) rather than of the
    /// program. Class-member resolvers set `this_type` *after* this call, so
    /// they are unaffected; `restoreCtx` puts the caller's `this` back.
    ///
    /// Crossing a file boundary opens a fresh instantiation budget
    /// (`max_instantiation_count`) for the same reason and with the same
    /// force. The budget is scoped to a source element — but materializing
    /// *another file's* declaration is not work the demanding element asked
    /// for, it is work the declaration costs, and which element pays it is
    /// whichever one reaches the declaration first with a cold cache. That
    /// order is a function of the partition: at `--checkers=8` the files that
    /// import a heavy library are spread over eight instances, and each
    /// instance re-materializes the library starting from whichever of its own
    /// files gets there first. On one app a single statement was charged
    /// 469,012 node visits for a component library's declarations, tripped the
    /// budget, and truncated that library's types to `error_type` — and a
    /// different file was the one to pay at every checker count, so the TS2589
    /// sites and the ~70-diagnostic cascade under them moved with `N`.
    /// Charging the declaration's own frame instead makes the answer a
    /// function of the program. The budget still bounds every single
    /// materialization — a runaway alias trips inside its own frame and is cut
    /// there, which is also where the truncation belongs — but no source
    /// element can be poisoned by the cost of a declaration it merely
    /// referenced.
    pub fn enterSymFile(c: *Checker, sym: SymbolId) SavedCtx {
        const saved = c.saveCtx();
        const f = c.symFile(sym);
        if (prof_zig.enabled()) c.epoch_sym = sym;
        if (f != c.cur_file) {
            c.setFile(f);
            c.this_type = 0;
        }
        c.inst_count = 0;
        c.inst_budget = max_decl_instantiation_count;
        c.newBudgetWindow();
        return saved;
    }

    /// Representative *real* constituent id for decl/scope/file operations on
    /// a (possibly merged) symbol. Non-merged ids pass through; a
    /// merged id resolves to a type-space contributor when one exists (so
    /// interface/class/alias decl walks land on real nodes), else its first
    /// part. Type materialization that must fold *all* constituents
    /// (`interfaceGeneric`, merged value type) does not go through here.
    pub fn reprSym(c: *const Checker, sym: SymbolId) SymbolId {
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
    pub fn symFile(c: *const Checker, sym0: SymbolId) FileId {
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
    pub fn symInDeclFile(c: *const Checker, sym: SymbolId) bool {
        return std.mem.endsWith(u8, c.prog.files[c.symFile(sym)].path, ".d.ts");
    }

    /// Local (per-file) id of a global symbol (via representative for merged).
    pub fn localOf(c: *const Checker, sym: SymbolId) SymbolId {
        const s = c.reprSym(sym);
        return s - c.prog.sym_base[c.symFile(s)];
    }

    /// Global id of a local symbol of the current file.
    pub fn toGlobal(c: *const Checker, local: SymbolId) SymbolId {
        if (local == binder.no_symbol) return binder.no_symbol;
        return c.prog.sym_base[c.cur_file] + local;
    }

    pub fn toGlobalIn(c: *const Checker, file: FileId, local: SymbolId) SymbolId {
        if (local == binder.no_symbol) return binder.no_symbol;
        return c.prog.sym_base[file] + local;
    }

    pub fn symBind(c: *const Checker, sym: SymbolId) *const Bind {
        return c.prog.files[c.symFile(sym)].bind;
    }

    /// Combined symbol flags. A merged symbol reports the OR of its
    /// constituents' flags.
    pub fn symFlags(c: *const Checker, sym: SymbolId) binder.SymbolFlags {
        if (c.prog.isMergedId(sym)) return c.prog.mergedSym(sym).flags;
        const f = c.symFile(sym);
        return c.prog.files[f].bind.symbol_flags[sym - c.prog.sym_base[f]];
    }

    pub fn symNameAtom(c: *const Checker, sym: SymbolId) Atom {
        if (c.isFreshTp(sym)) return c.freshTp(sym).name;
        if (c.prog.isMergedId(sym)) return c.prog.mergedSym(sym).name;
        const f = c.symFile(sym);
        return c.prog.files[f].bind.symbol_names[sym - c.prog.sym_base[f]];
    }

    /// Local scope id of `sym` within its own file (via representative for
    /// merged symbols).
    pub fn symScope(c: *const Checker, sym: SymbolId) ScopeId {
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
    pub fn symDeclaredInForHead(c: *const Checker, sym: SymbolId) bool {
        // Neither `this` nor a binding-pattern pseudo-root is a loop binding.
        if (flow_zig.isPseudoRoot(sym)) return false;
        const s = c.reprSym(sym);
        const f = c.symFile(s);
        const b = c.prog.files[f].bind;
        return b.scope_kinds[b.symbol_scopes[s - c.prog.sym_base[f]]] == .for_head;
    }

    /// Decl nodes of a global symbol (valid in `symFile(sym)`'s tree). For a
    /// merged symbol this is the representative constituent's decls; folding
    /// *all* constituents is done by the type materializers.
    pub fn declsOf(c: *const Checker, sym: SymbolId) []const Node {
        const s = c.reprSym(sym);
        const f = c.symFile(s);
        return c.prog.files[f].bind.declsOf(s - c.prog.sym_base[f]);
    }

    /// (file << 32 | node) cache key for the current file.
    pub fn nodeKey(c: *const Checker, node: Node) u64 {
        return (@as(u64, c.cur_file) << 32) | node;
    }

    /// Most-recent memoized type of `node` (ignoring which context produced
    /// it) — for node-only readers (narrowing, EPC, flow, error elaboration)
    /// that just want the type the node was last determined to have.
    pub fn nodeType(c: *const Checker, node: Node) ?TypeId {
        return if (c.node_types.get(c.nodeKey(node))) |e| e.ty else null;
    }

    /// Link target of an import-binding symbol (null in unlinked mode).
    pub fn importTarget(c: *const Checker, sym: SymbolId) ?modules.Target {
        if (c.prog.links.len == 0 or c.prog.isMergedId(sym)) return null;
        const f = c.symFile(sym);
        return c.prog.links[f].importTarget(sym - c.prog.sym_base[f]);
    }

    // =====================================================================
    // small helpers
    // =====================================================================

    pub fn atom(c: *Checker, text: []const u8) Error!Atom {
        const gop = try c.atom_cache.getOrPut(c.cm(), text);
        if (!gop.found_existing) {
            gop.value_ptr.* = try c.interner.intern(c.io, c.gpa, text);
        }
        return gop.value_ptr.*;
    }

    /// Intern text from a *transient* buffer (a scratch/stack slice). Goes
    /// straight to the interner (which copies the bytes) instead of `atom`,
    /// whose `atom_cache` would otherwise store the caller's slice as a key and
    /// dangle once the buffer is freed. Use for any computed/temporary string.
    pub fn internText(c: *Checker, text: []const u8) Error!Atom {
        return c.interner.intern(c.io, c.gpa, text);
    }

    pub fn atomText(c: *Checker, a: Atom) []const u8 {
        if (a == 0) return "";
        return c.interner.lookup(c.io, a);
    }

    pub fn tokenText(c: *const Checker, tok: TokenIndex) []const u8 {
        return c.tree.tokenSlice(c.src, tok);
    }

    pub fn atomOfToken(c: *Checker, tok: TokenIndex) Error!Atom {
        return c.atom(c.tokenText(tok));
    }

    /// Property-name atom: string keys lose quotes.
    pub fn memberAtom(c: *Checker, tok: TokenIndex) Error!Atom {
        const text = c.tokenText(tok);
        switch (c.tree.tokens.tag(tok)) {
            // `.jsx_string` is a JSX attribute's quoted value.
            .string_literal, .jsx_string => return c.atom(stripQuotes(text)),
            else => return c.atom(text),
        }
    }

    /// Member-name atom honoring a `[Symbol.iterator]` computed key (mirrors the
    /// binder's `memberKey`): with the `computed` flag set, `tok` names the
    /// well-known symbol and the member is keyed by a synthetic `__@name` atom.
    pub fn memberKey(c: *Checker, tok: TokenIndex, flags: u32) Error!Atom {
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
    /// `ann`. Identified by declaration site (`node_base[file] + node`) so every
    /// resolution of the same annotation — the declared type of the const, and
    /// thus every value reference to it — yields the identical nominal type.
    ///
    /// The id is NOT a mint-order counter: it leaks into the member name
    /// (`uniqueSymAtom` renders `__@u<id>`), which is printed in diagnostics, so
    /// a counter made the same property read `__@u67` under one `--checkers`
    /// value and `__@u65` under another — the counter advanced once per
    /// *first-encountered* annotation, and encounter order is a property of the
    /// partition. A global node id is a property of the program.
    pub fn uniqueSymType(c: *Checker, ann: Node) Error!TypeId {
        return c.ts.makeUniqueSymbol(c.node_base[c.cur_file] + ann);
    }

    /// Synthetic member atom for a value whose type is a `unique symbol`, so a
    /// computed key `{ [k]: … }` and an element access `o[k]` agree on the
    /// property name. `__@` cannot begin a real identifier, so it never
    /// collides with an ordinary member (mirrors `wellKnownSymbolKey`).
    pub fn uniqueSymAtom(c: *Checker, t: TypeId) Error!?Atom {
        const r = try c.ts.regular(t);
        if (c.ts.kind(r) != .unique_symbol) return null;
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "__@u{d}", .{c.ts.uniqueSymId(r)}) catch unreachable;
        return try c.internText(s); // stack buffer: copy, don't store as a cache key
    }

    /// Prefix of a computed-key placeholder atom (see `computedSymPlaceholder`).
    pub const computed_sym_prefix = "__@k$";

    /// The member name a computed key `[expr]` denotes when `expr`'s type is a
    /// LITERAL — tsc's late-bound name rule (`isLateBindableName`: a computed
    /// name is bindable when its type is a string literal, a numeric literal,
    /// or a unique symbol). A string enum member counts: `[E.A]` with
    /// `A = "a"` declares the property `"a"`, and `keyof` over such a map is
    /// the union of the VALUES, not of anything derived from how the keys were
    /// spelled.
    ///
    /// Sibling of `uniqueSymAtom`, which covers the third case. Without this
    /// one, every `{ [E.A]: T }` map kept the syntactic placeholder as its
    /// member name, so `m.a` was TS2339, `keyof M` printed the placeholders
    /// back at the user, and no `E`-typed key was assignable to it.
    pub fn literalKeyAtom(c: *Checker, ty: TypeId) Error!?Atom {
        const r = try c.ts.regular(ty);
        switch (c.ts.kind(r)) {
            .string_literal => return c.ts.literalAtom(r),
            .number_literal, .number_literal_fresh => {
                var buf: [32]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                print_zig.printNumber(&w, c.ts.numberValue(r)) catch return null;
                // Stack buffer: `internText` copies. `atom` would keep the
                // transient slice as an `atom_cache` key and dangle.
                return try c.internText(w.buffered());
            },
            // An enum MEMBER stands for its own constant value; a whole enum
            // type (or a computed member with no constant) does not.
            .enum_type => {
                if (!c.ts.isEnumMember(r)) return null;
                const v = (try c.enumMemberValue(c.ts.enumSymbol(r), c.ts.enumMemberAtom(r))) orelse return null;
                if (v == r) return null; // no self-recursion on an opaque member
                return c.literalKeyAtom(v);
            },
            else => return null,
        }
    }

    /// The nominal member atom a computed-key expression of type `ty` denotes:
    /// the `__@u<id>` of a `unique symbol`, else the literal name it spells
    /// out. Null when `ty` is neither, and the caller falls back to the
    /// syntactic placeholder.
    pub fn computedKeyAtomOfType(c: *Checker, ty: TypeId) Error!?Atom {
        if (try c.uniqueSymAtom(ty)) |a| return a;
        return c.literalKeyAtom(ty);
    }

    /// Placeholder member atom for a computed const-`unique symbol` key, keyed
    /// by the identifier text (matches the binder's `computedSymPlaceholder`).
    /// Used as a lenient fallback when the key identifier can't be resolved to
    /// a `unique symbol` (e.g. a plain `symbol`, or an unresolved import): the
    /// member still exists and is keyed by name, degrading nominal identity to
    /// same-name matching rather than emitting a spurious error.
    pub fn computedSymPlaceholder(c: *Checker, name: []const u8) Error!Atom {
        const s = try std.fmt.allocPrint(c.scratch(), "{s}{s}", .{ computed_sym_prefix, name });
        return c.internText(s); // scratch slice: copy, don't store as a cache key
    }

    /// Resolve a computed-key identifier `name` (a `[k]` key) in `scope` to the
    /// member atom it denotes: the nominal `__@u<id>` of a const `unique
    /// symbol`, or the literal name a string/number-literal constant spells out
    /// (`computedKeyAtomOfType`). Returns null when it is neither — the caller
    /// then falls back to the name placeholder. Resolution goes through the value
    /// space and `typeOfSymbol`, so an imported key resolves to the *declaring*
    /// site's nominal id, giving cross-file key identity for free.
    pub fn constSymbolKeyAtom(c: *Checker, name: []const u8, scope: ScopeId) Error!?Atom {
        const ty = (try c.constSymbolKeyType(name, scope)) orelse return null;
        return c.computedKeyAtomOfType(ty);
    }

    /// The TYPE a computed-key identifier denotes — the resolution half of
    /// `constSymbolKeyAtom`, split out because the key's type is also its
    /// tsc `nameType` (see `memberNameType`): `[E.A]` is keyed by the atom
    /// `"AV1"` but NAMED by the enum-member literal `E.A`, and `keyof` has to
    /// report the latter.
    pub fn constSymbolKeyType(c: *Checker, name: []const u8, scope: ScopeId) Error!?TypeId {
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
                return try c.typeOfSymbol(msym);
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
            return p.ty;
        }
        const a = try c.atom(name);
        const sym = switch (c.resolveSpace(a, scope, true)) {
            .sym => |s| s,
            else => return null,
        };
        return try c.typeOfSymbol(sym);
    }

    /// tsc's `symbol.links.nameType` for a member declared with a computed
    /// key: the ENUM-MEMBER literal type `[E.A]` denotes. A member table keys
    /// by atom, and an enum member's atom is its VALUE (`"AV1"`), so `keyof`
    /// read back a plain string-literal union and lost the enum's identity —
    /// `T extends keyof M` then did not satisfy `T extends E`. Returns
    /// `no_type` for every other key, which is every key that has no name
    /// type: an ordinary identifier or string key names itself.
    ///
    /// Only enum members are recorded. A `unique symbol` key is already
    /// nominal through its `__@u<id>` atom, and a string/number-literal const
    /// key names exactly the atom it produces, so neither needs the side
    /// table — and keeping it to the one case that needs it keeps the map
    /// empty on every program that has no enum-keyed type.
    pub fn memberNameType(c: *Checker, tok: TokenIndex, flags: u32) Error!TypeId {
        if (flags & ast.Flags.computed_sym == 0) return types.no_type;
        const name = if (flags & ast.Flags.computed_sym_qual != 0)
            try std.fmt.allocPrint(c.scratch(), "{s}.{s}", .{ c.tokenText(tok - 2), c.tokenText(tok) })
        else
            c.tokenText(tok);
        const ty = (try c.constSymbolKeyType(name, c.cur_scope)) orelse return types.no_type;
        const r = try c.ts.regular(ty);
        if (c.ts.kind(r) != .enum_type or !c.ts.isEnumMember(r)) return types.no_type;
        return r;
    }

    /// Member symbol `name` of `obj` for qualified computed-key resolution:
    /// a class's static (own class, or the class constituent of a merge), or
    /// a namespace export. Null when `obj` is neither, or the member is
    /// absent — the caller then falls back to type materialization.
    pub fn qualifiedKeyMemberSym(c: *Checker, obj: SymbolId, name: Atom) ?SymbolId {
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
    pub fn classStaticMemberSym(c: *Checker, cls: SymbolId, name: Atom) ?SymbolId {
        const cb = c.symBind(cls);
        const ss = cb.staticsScopeOf(c.localOf(cls)) orelse return null;
        const local = cb.lookupInScope(ss, name) orelse return null;
        return c.toGlobalIn(c.symFile(cls), local);
    }

    /// Final member atom for a computed const-symbol key token, resolved in
    /// `scope`: the nominal `__@u<id>` when the key denotes a `unique symbol`,
    /// else the name placeholder. For a qualified `[a.b]` key the object
    /// identifier sits two tokens before the member identifier (see parser).
    pub fn computedSymKey(c: *Checker, tok: TokenIndex, flags: u32, scope: ScopeId) Error!Atom {
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
    pub fn nominalizeComputedKey(c: *Checker, name: Atom, scope: ScopeId) Error!Atom {
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
    pub fn annTypeMaybeUnique(c: *Checker, ann: Node, valid: bool, code: u16, span: Span) Error!TypeId {
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
    pub fn isFreshSymbolCall(c: *Checker, node: Node) bool {
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
    pub fn wellKnownKeyOfExpr(c: *const Checker, node: Node) ?[]const u8 {
        if (node == null_node or c.nodeTag(node) != .member_expr) return null;
        const md = c.tree.nodeData(node);
        if (c.nodeTag(md.lhs) != .identifier) return null;
        if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(md.lhs)), "Symbol")) return null;
        return ast.wellKnownSymbolKey(c.tokenText(md.rhs));
    }

    pub fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
            if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
            return text[1..];
        }
        if (text.len >= 1 and (text[0] == '"' or text[0] == '\'')) return text[1..];
        return text;
    }

    pub fn tokSpan(c: *const Checker, tok: TokenIndex) Span {
        const start = c.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(c.src, c.tree.tokens.tag(tok), start) };
    }

    pub fn nodeSpan(c: *const Checker, node: Node) Span {
        return c.tree.span(c.src, node);
    }

    /// `nodeSpan(node).start` without the O(subtree) walk where the AST
    /// shape makes the start derivable from `main_token`. Debug builds
    /// cross-check every fast answer against the real span, so a wrong
    /// `Ast.spanStart` arm trips the conformance suite instead of silently
    /// moving a diagnostic.
    pub fn nodeSpanStart(c: *const Checker, node: Node) u32 {
        if (c.tree.spanStart(node)) |start| {
            if (std.debug.runtime_safety) std.debug.assert(start == c.nodeSpan(node).start);
            return start;
        }
        return c.nodeSpan(node).start;
    }

    /// Deferred `inst_span`: either a node (span computed on demand) or an
    /// explicit span pushed by a caller that has one in hand already. Both
    /// carry the file they were recorded in — a byte offset is only a
    /// position in the tree it came from.
    pub const InstAnchor = union(enum) {
        node: struct { file: FileId, node: Node },
        span: struct { file: FileId, span: Span },
    };

    /// The anchor resolved to the (file, span) pair it was recorded at.
    ///
    /// Materializing a type switches the current-file context
    /// (`enterSymFile`) without moving the anchor, so a limit tripped deep
    /// inside a foreign declaration still carries the *demand* site's node —
    /// and the demand site is the position to report. `cur_file` at the
    /// moment of the trip is not: whether the expansion happened to route
    /// through a foreign declaration, rather than meeting this checker's
    /// already-materialized copy of it, is a property of the partition.
    /// The anchor's own file is the only frame its byte offset means
    /// anything in, so the span is computed against that file's tree and
    /// source rather than `c.tree`/`c.src`, which follow `cur_file`.
    pub fn instSpanHere(c: *const Checker) struct { FileId, Span } {
        return switch (c.inst_anchor) {
            .span => |s| .{ s.file, s.span },
            .node => |n| .{ n.file, c.prog.files[n.file].tree.span(c.prog.files[n.file].src, n.node) },
        };
    }

    /// Whether an instantiation-budget trip happening *right now* is a
    /// user-facing TS2589, or a silent "no evidence" cut. Every guard site
    /// that would `instLimitDiag(2589, …)` asks this first.
    ///
    /// The two are different questions and tsc keeps them apart by WHERE the
    /// recursion is detected. At the CHECKING level — materializing an
    /// annotation, a cast, a call's return — tsc's `instantiateType` guard
    /// (`instantiationDepth`/`instantiationCount`) reports
    /// `Type_instantiation_is_excessively_deep_and_possibly_infinite` and
    /// hands back `errorType`. Inside the assignability RELATION it does not:
    /// `recursiveTypeRelatedTo` detects a same-symbol recursion with
    /// `isDeeplyNestedType` and answers `Ternary.Maybe` — the pair is assumed
    /// related, silently, with no diagnostic and nothing cached. A relation is
    /// a *question*, and running out of budget while answering it is an
    /// absence of evidence, not a property of the program.
    ///
    /// ztsc needs the separation more than tsc does, because its relation asks
    /// for orders of magnitude more instantiation than tsc's: ztsc substitutes
    /// eagerly and structurally where tsc defers. Relating one pair of kysely
    /// builder references — `ExpressionBuilder<DB & {sharedBy: UserTable},
    /// 'partner'|'sharedBy'>` against `ExpressionBuilder<DB, 'partner'>`,
    /// immich's shape, on which tsc is clean — walks a spine of
    /// `SelectQueryBuilder`/`ExpressionBuilder` frames that mints a fresh
    /// interned pair at every level. Nothing repeats, so neither the relation
    /// memo nor `relIdDeeplyNested`'s growth test closes it (the refs SHRINK
    /// down that spine, and the growth test counts only strictly later
    /// instantiations), and the walk was measured still running past
    /// 40,000,000 node visits at `max_instantiation_depth` 400. Whatever
    /// budget it is given it will exhaust, so the trip carries exactly one
    /// bit of information — "ztsc gave up" — which is what tsc answers
    /// `Maybe` to.
    ///
    /// Reporting it anyway is a false positive, and unlike the report the
    /// truncation itself is harmless here: `error_type` relates to everything,
    /// so the relation's answer with the cut is the assumed-YES it would have
    /// given at `max_relation_depth` one layer up. `inst_limit_tripped` still
    /// fires, so the truncated result is still kept out of every memo.
    ///
    /// The direction of the unsoundness is the one `max_relation_depth` and
    /// `max_relation_identity_repeats` already take, and the one tsc takes:
    /// assume-related can only DROP a diagnostic, never invent one. What it
    /// deliberately does NOT do is suppress TS2589 generally — a trip while
    /// materializing an annotation still reports (conformance
    /// instantiation/002), because that one is a property of the type.
    pub fn instDiagAllowed(c: *const Checker) bool {
        return !c.suppress_inst_diag and c.rel_depth == 0;
    }

    /// Report an instantiation-limit diagnostic (TS2589 / TS2590) at a
    /// canonical, partition-independent anchor: at most one per file and
    /// code, at the lexically-first anchor seen in that file.
    ///
    /// The record is filed under the *anchor's* file, never `cur_file`. The
    /// anchor is only ever set while walking a file this checker owns
    /// (`checkStatement`/`anchorInst` and the expression boundaries), so it
    /// always survives `seal`'s owned-file filter — and a trip that unwound
    /// through a foreign `.d.ts` is reported at the site that demanded it
    /// instead of dropped.
    ///
    /// The limit is a resource cap, not a property of a single expression:
    /// `instantiateId`'s memo short-circuits before the depth guard, so
    /// *which* of a file's several deep materializations actually trips
    /// depends on what this checker instance already had cached — i.e. on
    /// the partition. Collapsing a file's trips to their lexically-first
    /// anchor makes the reported position a function of the program alone.
    /// Costs one hash lookup per trip (a handful per run).
    pub fn instLimitDiag(c: *Checker, code: u16, msg: []const u8) Error!void {
        const file, const span = c.instSpanHere();
        const gop = try c.inst_diag_at.getOrPut(c.cm(), (@as(u64, file) << 32) | code);
        if (gop.found_existing) {
            const prev = &c.diags.items[gop.value_ptr.*];
            if (span.start < prev.span.start) prev.span = span;
            return;
        }
        gop.value_ptr.* = c.diags.items.len;
        try c.diags.append(c.gpa, .{ .code = code, .file = file, .span = span, .msg = try c.out.dupe(u8, msg) });
    }

    pub fn anchorInst(c: *Checker, node: Node) void {
        c.inst_anchor = .{ .node = .{ .file = c.cur_file, .node = node } };
    }

    pub fn nodeTag(c: *const Checker, node: Node) ast.Tag {
        return c.tree.nodeTag(node);
    }

    pub fn diagFmt(c: *Checker, code: u16, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
        // A side query re-checks an expression out of order to inspect its
        // type; the authoritative top-down check reports at the resolved type.
        if (c.side_query_depth > 0) return;
        const key = (@as(u128, c.cur_file) << 64) | (@as(u128, code) << 32) | span.start;
        const gop = try c.diag_seen.getOrPut(c.gpa, key);
        if (gop.found_existing) return;
        const msg = try std.fmt.allocPrint(c.out, fmt, args);
        try c.diags.append(c.gpa, .{ .code = code, .file = c.cur_file, .span = span, .msg = msg });
    }

    /// Has a diagnostic with this code already been filed at this span?
    /// (`diagFmt`'s dedupe key, asked without filing anything.)
    ///
    /// An elaboration that ran once has to keep answering "yes, I elaborated"
    /// on every re-check of the same expression, even when its own diagnostic
    /// would now be swallowed as a duplicate — otherwise the caller concludes
    /// nothing was reported and falls back to the whole-expression error,
    /// which lands *beside* the earlier nested one.
    pub fn diagAlreadyFiled(c: *Checker, code: u16, span: Span) bool {
        return c.diag_seen.contains((@as(u128, c.cur_file) << 64) | (@as(u128, code) << 32) | span.start);
    }

    /// The source region a speculative check is allowed to have spoken about:
    /// everything a rejected overload candidate says *inside* it is an artifact
    /// of that candidate and must be withdrawn; everything outside it is
    /// collateral from work the probe merely happened to trigger and must
    /// survive. `hi == 0` means "the whole file" (unused today, but it makes an
    /// empty region unrepresentable).
    pub const SpecRegion = struct { file: FileId, lo: u32, hi: u32 };

    /// Withdraw the diagnostics a speculative stretch of checking filed inside
    /// `spec`, restoring the state a *silent* probe would have left.
    ///
    /// Two things make this more than `diags.items.len = saved`.
    ///
    /// (1) `diagFmt` writes a second, permanent record: the (file, code,
    ///     span-start) key in `diag_seen`. Truncating the list alone erases the
    ///     diagnostic *and keeps its suppression*, so the next check of the same
    ///     expression is swallowed forever. A rejected overload candidate
    ///     contextually types an arrow argument, walks its body, files the body's
    ///     errors, and the truncation then poisons every one of those spans
    ///     against the WINNING candidate's re-walk: the body is checked twice
    ///     and reported zero times, which is indistinguishable from never being
    ///     checked at all.
    ///
    /// (2) The probe also drags in work that is not speculative at all. Checking
    ///     an argument materializes whatever symbols it mentions, and
    ///     materializing `const f = (…) => {…}` from another file walks that
    ///     arrow's body — under `no_publish_depth == 0`, so its type IS memoized.
    ///     Those diagnostics belong to the other file's own check, are produced
    ///     exactly once, and the blanket truncation deleted them with no second
    ///     chance: the memo makes sure the body is never walked again. That is
    ///     how whole top-level bodies (data/encryption.ts's `decryptData`, via a
    ///     `new Uint8Array(await decryptData(…))` overload probe in data/encode.ts)
    ///     went unreported. Restricting the withdrawal to `spec` keeps them.
    ///
    /// `instLimitDiag` stores *indices* into `diags`; any pointing into the
    /// window are dropped rather than remapped (the map is empty on nearly every
    /// run — hence the count guard — and a dropped anchor at worst lets a later
    /// trip re-file the file's single TS2589, where the previous code left the
    /// index dangling onto an unrelated diagnostic).
    ///
    /// KNOWN RESIDUAL. A withdrawal is only recoverable if the winning candidate
    /// re-walks the same expression. It does for the argument itself (the
    /// contextual type differs per candidate, so `node_types` misses) and for an
    /// argument that IS a function expression (`no_publish_depth`), but not for
    /// a function expression nested inside an argument and typed context-free —
    /// an IIFE, `promises.concat((async () => { … })())`. That body's answer is
    /// published, so the re-check hits the memo and its diagnostics stay
    /// withdrawn. One site in the excalidraw corpus (element/image.ts:54 of
    /// 4166 instrumented arrow bodies). Withholding the whole probed argument
    /// from `node_types` closes it and was measured TWICE:
    ///   - first pass: +3 excess keys — a duplicate whole-argument TS2345
    ///     beside its own nested elaboration, plus two partition-dependent keys
    ///     including a TS1308;
    ///   - re-measured after `diagAlreadyFiled` fixed the duplicate: +2 excess
    ///     keys, exactly `data/encryption.ts:86:5 TS2345` and
    ///     `packages/utils/export.ts:126:18 TS1308`, for zero matched keys and
    ///     zero under-reports closed on the oracle's key set.
    /// Still not worth taking: the one site it fixes is an under-report the
    /// oracle does not name, and it costs two false positives.
    pub fn rollbackDiags(c: *Checker, saved: usize, spec: SpecRegion) void {
        if (c.diags.items.len == saved) return;
        // `remove` invalidates the iterator, so restart after each hit.
        while (c.inst_diag_at.count() > 0) {
            var stale: ?u64 = null;
            var it = c.inst_diag_at.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* >= saved) {
                    stale = e.key_ptr.*;
                    break;
                }
            }
            _ = c.inst_diag_at.remove(stale orelse break);
        }
        var w = saved;
        for (c.diags.items[saved..]) |d| {
            if (d.file == spec.file and d.span.start >= spec.lo and
                (spec.hi == 0 or d.span.start < spec.hi))
            {
                _ = c.diag_seen.remove((@as(u128, d.file) << 64) | (@as(u128, d.code) << 32) | d.span.start);
                continue;
            }
            c.diags.items[w] = d;
            w += 1;
        }
        c.diags.items.len = w;
    }

    /// `rollbackDiags` for an overload probe: the speculative region is the
    /// argument list's own byte range in `file`. Computed here rather than by
    /// the caller because the span of the last argument is an O(subtree) walk
    /// and the overwhelmingly common rejection files no diagnostic at all.
    pub fn rollbackArgDiags(c: *Checker, saved: usize, file: FileId, arg_nodes: []const Node) void {
        if (c.diags.items.len == saved) return;
        // Arguments are in source order, so the region is [start of the first,
        // end of the last] — one cheap start and one subtree walk, not one per
        // argument.
        var first: Node = null_node;
        var last: Node = null_node;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            if (first == null_node) first = an;
            last = an;
        }
        // No arguments at all: nothing the candidate said can be about them.
        if (first == null_node) return;
        c.rollbackDiags(saved, .{ .file = file, .lo = c.nodeSpanStart(first), .hi = c.nodeSpan(last).end });
    }

    pub fn scopeOf(c: *Checker, node: Node) Error!?ScopeId {
        if (!c.scopes_faulted[c.cur_file]) try c.faultScopes(c.cur_file);
        return c.node_scopes.get((@as(u64, c.cur_file) << 32) | node);
    }

    /// Lazily map every scope-owner node of file `f` to its primary (lowest)
    /// scope id, the first time this checker reads a scope in that file (per-checker
    /// right-sizing). First scope wins because `scope_owners` is walked in
    /// ascending scope order and only unset keys are written.
    pub fn faultScopes(c: *Checker, f: FileId) Error!void {
        const map_alloc = c.cm();
        const b = c.prog.files[f].bind;
        for (b.scope_owners, 0..) |owner, s| {
            if (s == 0) continue;
            const key = (@as(u64, @intCast(f)) << 32) | owner;
            const gop = try c.node_scopes.getOrPut(map_alloc, key);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(s);
        }
        c.scopes_faulted[f] = true;
    }

    /// Is the function lexically enclosing the node now being checked
    /// `async`? Null at the top level of the file (no enclosing function).
    ///
    /// The SYNTACTIC answer — tsc's parser-assigned `NodeFlags.AwaitContext`
    /// — which is what `await`/`yield` legality is a property of. The dynamic
    /// `fn_ctx` cannot answer it: an expression is re-checked from wherever a
    /// later contextual type demands it, and the frame in flight then belongs
    /// to some unrelated function. Walks the scope chain, so a class-member
    /// or block scope in between is transparent.
    pub fn enclosingFnIsAsync(c: *const Checker) ?bool {
        var cur = c.cur_scope;
        while (cur != binder.file_scope) {
            if (c.bind.scope_kinds[cur] == .function) {
                const owner = c.bind.scope_owners[cur];
                if (owner == ast.null_node) return null;
                // Every `.function` scope is created by `bindFunctionLike`
                // (or `bindFunctionType`), whose owner node keeps its
                // modifiers in an `FnProto` at `lhs`.
                const flags = switch (c.tree.nodeTag(owner)) {
                    .arrow_fn, .function_expr, .function_decl, .class_method, .function_type => c.tree.extraData(ast.FnProto, c.tree.nodeData(owner).lhs).flags,
                    else => return null,
                };
                return flags & ast.Flags.async != 0;
            }
            cur = c.bind.scope_parents[cur];
        }
        return null;
    }

    /// Nearest enclosing function/file scope (for TDZ containment).
    pub fn containerOf(c: *const Checker, s: ScopeId) ScopeId {
        var cur = s;
        while (cur != binder.file_scope) {
            switch (c.bind.scope_kinds[cur]) {
                .function, .file => return cur,
                else => cur = c.bind.scope_parents[cur],
            }
        }
        return binder.file_scope;
    }

    // === decls relocated to src/checker/*.zig =============================

    const names_zig = @import("checker/names.zig");
    pub const hasValueMeaning = names_zig.hasValueMeaning;
    pub const hasTypeMeaning = names_zig.hasTypeMeaning;
    pub const resolveSpace = names_zig.resolveSpace;
    pub const suggestName = names_zig.suggestName;
    pub const reportNameNotFound = names_zig.reportNameNotFound;
    pub const reportModuleNotFound = names_zig.reportModuleNotFound;
    pub const suggestProp = names_zig.suggestProp;
    pub const editDistance = names_zig.editDistance;
    pub const toLower = names_zig.toLower;
    pub const literalBaseOf = names_zig.literalBaseOf;
    pub const widenLiteral = names_zig.widenLiteral;
    pub const isConstTypeVar = names_zig.isConstTypeVar;
    pub const normalizeFreshObjectSiblings = names_zig.normalizeFreshObjectSiblings;
    pub const widenReturnMember = names_zig.widenReturnMember;
    pub const finalizeInferredReturn = names_zig.finalizeInferredReturn;
    pub const widenToContext = names_zig.widenToContext;
    pub const Resolved = names_zig.Resolved;

    const print_zig = @import("checker/print.zig");
    pub const typeToString = print_zig.typeToString;
    pub const printType = print_zig.printType;
    pub const stringMappingName = print_zig.stringMappingName;
    pub const printSigMember = print_zig.printSigMember;
    pub const printTypeParen = print_zig.printTypeParen;
    pub const encodeF64Key = print_zig.encodeF64Key;
    pub const writeSortKey = print_zig.writeSortKey;
    pub const sortMembersStructural = print_zig.sortMembersStructural;
    pub const propDisplayOrder = print_zig.propDisplayOrder;
    pub const printNumber = print_zig.printNumber;
    pub const symbolName = print_zig.symbolName;
    pub const dumpTypes = print_zig.dumpTypes;
    pub const PrintErr = print_zig.PrintErr;
    pub const PrintPos = print_zig.PrintPos;
    pub const DisplayMember = print_zig.DisplayMember;

    const typenode_zig = @import("checker/typenode.zig");
    pub const typeFromTypeNode = typenode_zig.typeFromTypeNode;
    pub const typeNodeCacheable = typenode_zig.typeNodeCacheable;
    pub const typeFromTypeNodeUncached = typenode_zig.typeFromTypeNodeUncached;
    pub const typeFromTypeName = typenode_zig.typeFromTypeName;
    pub const typeFromTypeNameEx = typenode_zig.typeFromTypeNameEx;
    pub const lookupMappedKey = typenode_zig.lookupMappedKey;
    pub const materializeTypeRef = typenode_zig.materializeTypeRef;
    pub const augmentModuleTypeSym = typenode_zig.augmentModuleTypeSym;
    pub const namespaceMemberSym = typenode_zig.namespaceMemberSym;
    pub const mergedNsMemberOfScope = typenode_zig.mergedNsMemberOfScope;
    pub const resolveImportTypeModule = typenode_zig.resolveImportTypeModule;
    pub const ambientIndex = typenode_zig.ambientIndex;
    pub const moduleExportTarget = typenode_zig.moduleExportTarget;
    pub const exportEqualsMemberSym = typenode_zig.exportEqualsMemberSym;
    pub const targetTypeSym = typenode_zig.targetTypeSym;
    pub const typeMeaningTarget = typenode_zig.typeMeaningTarget;
    pub const importTypeMember = typenode_zig.importTypeMember;
    pub const typeFromQualifiedName = typenode_zig.typeFromQualifiedName;
    pub const enumSymOfQualifier = typenode_zig.enumSymOfQualifier;
    pub const enumSymFromImportTarget = typenode_zig.enumSymFromImportTarget;
    pub const resolveNsContainer = typenode_zig.resolveNsContainer;
    pub const containerFromImportTarget = typenode_zig.containerFromImportTarget;
    pub const nestNsContainer = typenode_zig.nestNsContainer;
    pub const containerMemberSym = typenode_zig.containerMemberSym;
    pub const qualifierText = typenode_zig.qualifierText;
    pub const namedTypeFromSymbol = typenode_zig.namedTypeFromSymbol;
    pub const regularizeTypeQuery = typenode_zig.regularizeTypeQuery;
    pub const typeofEntity = typenode_zig.typeofEntity;
    pub const typeParamsOf = typenode_zig.typeParamsOf;
    pub const canonicalizeClassTypeParams = typenode_zig.canonicalizeClassTypeParams;
    pub const declTypeParams = typenode_zig.declTypeParams;
    pub const typeParamSymsOfDecl = typenode_zig.typeParamSymsOfDecl;
    pub const buildInstMap = typenode_zig.buildInstMap;
    pub const fixTypeArgs = typenode_zig.fixTypeArgs;
    pub const symHasConstrainedTypeParam = typenode_zig.symHasConstrainedTypeParam;
    pub const queueTypeArgConstraints = typenode_zig.queueTypeArgConstraints;
    pub const drainTypeArgConstraints = typenode_zig.drainTypeArgConstraints;
    pub const checkTypeArgConstraints = typenode_zig.checkTypeArgConstraints;
    pub const undecidableType = typenode_zig.undecidableType;
    pub const decidableConstraintSet = typenode_zig.decidableConstraintSet;
    pub const keyofType = typenode_zig.keyofType;
    pub const intersectKeySets = typenode_zig.intersectKeySets;
    pub const keySetMembers = typenode_zig.keySetMembers;
    pub const keySetEnumerable = typenode_zig.keySetEnumerable;
    pub const keySetAllLiterals = typenode_zig.keySetAllLiterals;
    pub const keySetHas = typenode_zig.keySetHas;
    pub const isKeyLiteral = typenode_zig.isKeyLiteral;
    pub const isKeyAtom = typenode_zig.isKeyAtom;
    pub const keyofMapped = typenode_zig.keyofMapped;
    pub const indexedAccessType = typenode_zig.indexedAccessType;
    pub const checkIndexedAccessIndexType = typenode_zig.checkIndexedAccessIndexType;
    pub const typeIsNumberLike = typenode_zig.typeIsNumberLike;
    pub const numberIndexType = typenode_zig.numberIndexType;
    pub const unionIndexElemType = typenode_zig.unionIndexElemType;
    pub const indexableConstituent = typenode_zig.indexableConstituent;
    pub const elemOfArrayish = typenode_zig.elemOfArrayish;
    pub const restTupleOf = typenode_zig.restTupleOf;
    pub const sigRestTuple = typenode_zig.sigRestTuple;
    pub const sigRestUnion = typenode_zig.sigRestUnion;
    pub const sigNonArrayRest = typenode_zig.sigNonArrayRest;
    pub const restUnionOptionalAt = typenode_zig.restUnionOptionalAt;
    pub const restTupleAtPosition = typenode_zig.restTupleAtPosition;
    pub const memberList = typenode_zig.memberList;
    pub const refArgsList = typenode_zig.refArgsList;
    pub const makeUnion2 = typenode_zig.makeUnion2;
    pub const logicalUnion = typenode_zig.logicalUnion;
    pub const reduceSubtypes = typenode_zig.reduceSubtypes;
    pub const freshHasExcessProp = typenode_zig.freshHasExcessProp;
    pub const isEmptyAnonObject = typenode_zig.isEmptyAnonObject;
    pub const propertyKeyType = typenode_zig.propertyKeyType;
    pub const objectTypeFromMembers = typenode_zig.objectTypeFromMembers;
    pub const upsertProp = typenode_zig.upsertProp;
    pub const propByName = typenode_zig.propByName;
    pub const gatherSpreadProps = typenode_zig.gatherSpreadProps;
    pub const addSpreadProp = typenode_zig.addSpreadProp;
    pub const ModuleRef = typenode_zig.ModuleRef;
    pub const NsContainer = typenode_zig.NsContainer;
    pub const TypeParamInfo = typenode_zig.TypeParamInfo;
    pub const max_union_index_keys = typenode_zig.max_union_index_keys;

    const signatures_zig = @import("checker/signatures.zig");
    pub const signatureOfProto = signatures_zig.signatureOfProto;
    pub const signatureOfProtoCtx = signatures_zig.signatureOfProtoCtx;
    pub const inferredPredicate = signatures_zig.inferredPredicate;
    pub const narrowByGuardExpr = signatures_zig.narrowByGuardExpr;
    pub const typesOverlap = signatures_zig.typesOverlap;
    pub const thisParamAnn = signatures_zig.thisParamAnn;
    pub const predicateFromNode = signatures_zig.predicateFromNode;
    pub const optionalizePatternDefaults = signatures_zig.optionalizePatternDefaults;
    pub const patternDefaultsProp = signatures_zig.patternDefaultsProp;
    pub const paramInitCanBeUndefined = signatures_zig.paramInitCanBeUndefined;
    pub const paramInfo = signatures_zig.paramInfo;
    pub const inferReturnType = signatures_zig.inferReturnType;
    pub const inferGeneratorReturn = signatures_zig.inferGeneratorReturn;
    pub const collectYields = signatures_zig.collectYields;
    pub const collectReturns = signatures_zig.collectReturns;
    pub const typeOfSymbol = signatures_zig.typeOfSymbol;
    pub const setTypeOfSymbol = signatures_zig.setTypeOfSymbol;
    pub const computeTypeOfSymbol = signatures_zig.computeTypeOfSymbol;
    pub const withExpandoProps = signatures_zig.withExpandoProps;
    pub const callableClassValue = signatures_zig.callableClassValue;
    pub const expandoMemberType = signatures_zig.expandoMemberType;
    pub const mergedFunctionValue = signatures_zig.mergedFunctionValue;
    pub const appendOverloadCandidates = signatures_zig.appendOverloadCandidates;
    pub const lastCallSig = signatures_zig.lastCallSig;
    pub const variableSymbolType = signatures_zig.variableSymbolType;
    pub const importedSymbolType = signatures_zig.importedSymbolType;
    pub const targetValueType = signatures_zig.targetValueType;
    pub const dualValueType = signatures_zig.dualValueType;
    pub const dualHasValue = signatures_zig.dualHasValue;
    pub const namespaceObjectType = signatures_zig.namespaceObjectType;
    pub const appendAugmentedModuleExports = signatures_zig.appendAugmentedModuleExports;
    pub const ambientNamespaceType = signatures_zig.ambientNamespaceType;
    pub const isEvolvingVar = signatures_zig.isEvolvingVar;
    pub const widenInitializer = signatures_zig.widenInitializer;
    pub const forHeadBindingType = signatures_zig.forHeadBindingType;
    pub const declaratorType = signatures_zig.declaratorType;
    pub const pinPatternParamSyms = signatures_zig.pinPatternParamSyms;
    pub const pinBindingSym = signatures_zig.pinBindingSym;
    pub const bindingElementType = signatures_zig.bindingElementType;
    pub const bindingFlowBase = signatures_zig.bindingFlowBase;
    pub const extendRefKey = signatures_zig.extendRefKey;
    pub const findBindingType = signatures_zig.findBindingType;
    pub const objectRestType = signatures_zig.objectRestType;
    pub const functionSymbolType = signatures_zig.functionSymbolType;
    pub const memberTypeOf = signatures_zig.memberTypeOf;
    pub const BindFlow = signatures_zig.BindFlow;

    const instantiate_zig = @import("checker/instantiate.zig");
    pub const aliasInstance = instantiate_zig.aliasInstance;
    pub const aliasGeneric = instantiate_zig.aliasGeneric;
    pub const resolveStructural = instantiate_zig.resolveStructural;
    pub const expandRef = instantiate_zig.expandRef;
    pub const refExpandsToObject = instantiate_zig.refExpandsToObject;
    pub const lazyTableOf = instantiate_zig.lazyTableOf;
    pub const lazyShapeOf = instantiate_zig.lazyShapeOf;
    pub const lazyRefMap = instantiate_zig.lazyRefMap;
    pub const lazyMemberAt = instantiate_zig.lazyMemberAt;
    pub const lazyPropAt = instantiate_zig.lazyPropAt;
    pub const lazyPropNamed = instantiate_zig.lazyPropNamed;
    pub const lazyStringIndex = instantiate_zig.lazyStringIndex;
    pub const lazyNumberIndex = instantiate_zig.lazyNumberIndex;
    pub const originTaggable = instantiate_zig.originTaggable;
    pub const driveShrinkingAlias = instantiate_zig.driveShrinkingAlias;
    pub const refArgsSettled = instantiate_zig.refArgsSettled;
    pub const isEmptyObjectType = instantiate_zig.isEmptyObjectType;
    pub const globalThisType = instantiate_zig.globalThisType;
    pub const globalThisProp = instantiate_zig.globalThisProp;
    pub const globalThisHasValue = instantiate_zig.globalThisHasValue;
    pub const reduceForOriginEquiv = instantiate_zig.reduceForOriginEquiv;
    pub const originArgEquiv = instantiate_zig.originArgEquiv;
    pub const reexpandShrinking = instantiate_zig.reexpandShrinking;
    pub const refStrictlyShrinks = instantiate_zig.refStrictlyShrinks;
    pub const shrinkMetric = instantiate_zig.shrinkMetric;
    pub const emitBaseCycle = instantiate_zig.emitBaseCycle;
    pub const interfaceGeneric = instantiate_zig.interfaceGeneric;
    pub const setInterfaceThis = instantiate_zig.setInterfaceThis;
    pub const interfaceConstituentDirect = instantiate_zig.interfaceConstituentDirect;
    pub const interfaceConstituentApplyBases = instantiate_zig.interfaceConstituentApplyBases;
    pub const interfaceHeritageTypes = instantiate_zig.interfaceHeritageTypes;
    pub const classInterfaceHalfBases = instantiate_zig.classInterfaceHalfBases;
    pub const mergeBaseResolved = instantiate_zig.mergeBaseResolved;
    pub const arrayInterfaceObject = instantiate_zig.arrayInterfaceObject;
    pub const unionCallableSigs = instantiate_zig.unionCallableSigs;
    pub const mergeBaseObject = instantiate_zig.mergeBaseObject;
    pub const carryKeyNameTypes = instantiate_zig.carryKeyNameTypes;

    /// The one write path for `key_name_types`. Bumps `key_name_gen` on a
    /// genuinely new entry so `keyof_obj_cache` can tell that an object it
    /// already answered for may have gained enum-member names since — see
    /// that field. Never call `key_name_types.put` directly.
    pub fn putKeyNameType(c: *Checker, obj: TypeId, name: Atom, ty: TypeId) Error!void {
        const gop = try c.key_name_types.getOrPut(c.cm(), (@as(u64, obj) << 32) | name);
        if (gop.found_existing and gop.value_ptr.* == ty) return;
        gop.value_ptr.* = ty;
        c.key_name_gen += 1;
    }
    pub const classInstanceGeneric = instantiate_zig.classInstanceGeneric;
    pub const isCtorName = instantiate_zig.isCtorName;
    pub const refExpansionActive = instantiate_zig.refExpansionActive;
    pub const classGenericInProgress = instantiate_zig.classGenericInProgress;
    pub const classTableProvisional = instantiate_zig.classTableProvisional;
    pub const baseRefProvisional = instantiate_zig.baseRefProvisional;
    pub const lazyRefProp = instantiate_zig.lazyRefProp;
    pub const lazyThisProp = instantiate_zig.lazyThisProp;
    pub const ctorClassOwnsMember = instantiate_zig.ctorClassOwnsMember;
    pub const baseClassRef = instantiate_zig.baseClassRef;
    pub const baseClassSym = instantiate_zig.baseClassSym;
    pub const hasUnresolvedBase = instantiate_zig.hasUnresolvedBase;
    pub const classBaseEntitySym = instantiate_zig.classBaseEntitySym;
    pub const baseExprConstructType = instantiate_zig.baseExprConstructType;
    pub const importedContainerSym = instantiate_zig.importedContainerSym;
    pub const classIsAbstract = instantiate_zig.classIsAbstract;
    pub const memberIsAbstract = instantiate_zig.memberIsAbstract;
    pub const abstractSatisfiedElsewhere = instantiate_zig.abstractSatisfiedElsewhere;
    pub const classChainMemberIsAbstract = instantiate_zig.classChainMemberIsAbstract;
    pub const checkAbstractImplementation = instantiate_zig.checkAbstractImplementation;
    pub const collectClassMemberAtoms = instantiate_zig.collectClassMemberAtoms;
    pub const max_eager_alias_depth = instantiate_zig.max_eager_alias_depth;
    pub const origin_equiv_depth = instantiate_zig.origin_equiv_depth;
    pub const shrink_reexpand_ceiling = instantiate_zig.shrink_reexpand_ceiling;
    pub const lazy_base_depth = instantiate_zig.lazy_base_depth;

    const enums_zig = @import("checker/enums.zig");
    pub const classifyEnumInit = enums_zig.classifyEnumInit;
    pub const enumInitAtom = enums_zig.enumInitAtom;
    pub const aliasedEnumInitValue = enums_zig.aliasedEnumInitValue;
    pub const enumInfo = enums_zig.enumInfo;
    pub const eachEnumMember = enums_zig.eachEnumMember;
    pub const enumHasMemberNamed = enums_zig.enumHasMemberNamed;
    pub const enumMemberValue = enums_zig.enumMemberValue;
    pub const enumMemberTypeUnion = enums_zig.enumMemberTypeUnion;
    pub const enumMemberForValue = enums_zig.enumMemberForValue;
    pub const enumHasStringMember = enums_zig.enumHasStringMember;
    pub const enumValueType = enums_zig.enumValueType;
    pub const enumAssignable = enums_zig.enumAssignable;
    pub const enumsStructurallyRelated = enums_zig.enumsStructurallyRelated;
    pub const enumHasStringValue = enums_zig.enumHasStringValue;
    pub const enumIsStringValued = enums_zig.enumIsStringValued;
    pub const checkEnum = enums_zig.checkEnum;
    pub const ownStaticMemberProp = enums_zig.ownStaticMemberProp;
    pub const classStaticType = enums_zig.classStaticType;
    pub const classConstructType = enums_zig.classConstructType;
    pub const sigWithReturn = enums_zig.sigWithReturn;
    pub const ctorSignatures = enums_zig.ctorSignatures;
    pub const higherOrderSigEligible = enums_zig.higherOrderSigEligible;
    pub const boundHasReducerShape = enums_zig.boundHasReducerShape;
    pub const boundReducible = enums_zig.boundReducible;
    pub const sigReferencesOuterParam = enums_zig.sigReferencesOuterParam;
    pub const containsTypeParam = enums_zig.containsTypeParam;
    pub const containsTypeParamInner = enums_zig.containsTypeParamInner;
    pub const containsFreeTypeParam = enums_zig.containsFreeTypeParam;
    pub const tpLookup = enums_zig.tpLookup;
    pub const canonMapId = enums_zig.canonMapId;
    pub const mapForId = enums_zig.mapForId;
    pub const boundMayMove = enums_zig.boundMayMove;
    pub const tpMentions = enums_zig.tpMentions;
    pub const mintFreshTpDeferred = enums_zig.mintFreshTpDeferred;
    pub const resolveFreshBound = enums_zig.resolveFreshBound;
    pub const isFreshTp = enums_zig.isFreshTp;
    pub const isConstTypeParamSym = enums_zig.isConstTypeParamSym;
    pub const freshTp = enums_zig.freshTp;
    pub const tpOrigin = enums_zig.tpOrigin;
    pub const mintFreshTp = enums_zig.mintFreshTp;
    pub const mintThisTp = enums_zig.mintThisTp;
    pub const instantiate = enums_zig.instantiate;
    pub const tagInstantiatedOrigin = enums_zig.tagInstantiatedOrigin;
    pub const chainRepeats = enums_zig.chainRepeats;
    pub const instantiateId = enums_zig.instantiateId;
    pub const substThis = enums_zig.substThis;
    pub const containsThisType = enums_zig.containsThisType;
    pub const EnumInfo = enums_zig.EnumInfo;
    pub const EnumInitKind = enums_zig.EnumInitKind;
    pub const EnumMemberLookup = enums_zig.EnumMemberLookup;
    pub const EnumMemberCollect = enums_zig.EnumMemberCollect;
    pub const TpMap = enums_zig.TpMap;
    pub const InferKey = enums_zig.InferKey;

    const generics_zig = @import("checker/generics.zig");
    pub const mapWith = generics_zig.mapWith;
    pub const inferVarId = generics_zig.inferVarId;
    pub const inferVarFromNode = generics_zig.inferVarFromNode;
    pub const conditionalTypeFromNode = generics_zig.conditionalTypeFromNode;
    pub const reduceConditional = generics_zig.reduceConditional;
    pub const resolveConcreteConditional = generics_zig.resolveConcreteConditional;
    pub const planConditional = generics_zig.planConditional;
    pub const condDistributionDomain = generics_zig.condDistributionDomain;
    pub const planConcreteConditional = generics_zig.planConcreteConditional;
    pub const finishCondPlan = generics_zig.finishCondPlan;
    pub const condTrueBranch = generics_zig.condTrueBranch;
    pub const arrayDecidablyExtends = generics_zig.arrayDecidablyExtends;
    pub const isArrayShaped = generics_zig.isArrayShaped;
    pub const objectDecidablyNotExtends = generics_zig.objectDecidablyNotExtends;
    pub const indexOfId = generics_zig.indexOfId;
    pub const indexOfAtom = generics_zig.indexOfAtom;
    pub const collectInferVars = generics_zig.collectInferVars;
    pub const inferFromExtends = generics_zig.inferFromExtends;
    pub const inferFromObjectSigs = generics_zig.inferFromObjectSigs;
    pub const inferFromTemplate = generics_zig.inferFromTemplate;
    pub const bindTemplateInfer = generics_zig.bindTemplateInfer;
    pub const inferFromTemplateSource = generics_zig.inferFromTemplateSource;
    pub const matchTemplateParts = generics_zig.matchTemplateParts;
    pub const normalizeTextlessTemplate = generics_zig.normalizeTextlessTemplate;
    pub const containsInfer = generics_zig.containsInfer;
    pub const substInfer = generics_zig.substInfer;
    pub const mappedKeyId = generics_zig.mappedKeyId;
    pub const mappedTypeFromNode = generics_zig.mappedTypeFromNode;
    pub const reduceMapped = generics_zig.reduceMapped;
    pub const applyPropModifiers = generics_zig.applyPropModifiers;
    pub const applyElemModifiers = generics_zig.applyElemModifiers;
    pub const isPrimitiveForHomomorphicMap = generics_zig.isPrimitiveForHomomorphicMap;
    pub const materializeMapped = generics_zig.materializeMapped;
    pub const substHomoSource = generics_zig.substHomoSource;
    pub const collectHomoProps = generics_zig.collectHomoProps;
    pub const collectHomoIndex = generics_zig.collectHomoIndex;
    pub const collectMappedKeys = generics_zig.collectMappedKeys;
    pub const objectFromProps = generics_zig.objectFromProps;
    pub const remapKey = generics_zig.remapKey;
    pub const numberLiteralAtom = generics_zig.numberLiteralAtom;
    pub const reduceIndexedAccess = generics_zig.reduceIndexedAccess;
    pub const isGenericObjectForIndex = generics_zig.isGenericObjectForIndex;
    pub const containsMappedParam = generics_zig.containsMappedParam;
    pub const containsMappedParamInner = generics_zig.containsMappedParamInner;
    pub const mentionsMappedParam = generics_zig.mentionsMappedParam;
    pub const mentionsMappedParamInner = generics_zig.mentionsMappedParamInner;
    pub const substMappedKey = generics_zig.substMappedKey;
    pub const intrinsicStringMapping = generics_zig.intrinsicStringMapping;
    pub const aliasBodyIsIntrinsic = generics_zig.aliasBodyIsIntrinsic;
    pub const templateChunkText = generics_zig.templateChunkText;
    pub const templateHeadText = generics_zig.templateHeadText;
    pub const ctxWantsTemplate = generics_zig.ctxWantsTemplate;
    pub const typeIsStringLike = generics_zig.typeIsStringLike;
    pub const templateChunkTokAfter = generics_zig.templateChunkTokAfter;
    pub const templateExprType = generics_zig.templateExprType;
    pub const templateTypeFromNode = generics_zig.templateTypeFromNode;
    pub const reduceTemplate = generics_zig.reduceTemplate;
    pub const reduceTemplateChunks = generics_zig.reduceTemplateChunks;
    pub const evalTemplate = generics_zig.evalTemplate;
    pub const cloneBuilder = generics_zig.cloneBuilder;
    pub const freeBuilder = generics_zig.freeBuilder;
    pub const appendConcrete = generics_zig.appendConcrete;
    pub const enumerableForms = generics_zig.enumerableForms;
    pub const stringLiteralOf = generics_zig.stringLiteralOf;
    pub const applyStringMapping = generics_zig.applyStringMapping;
    pub const transformString = generics_zig.transformString;
    pub const matchTemplatePattern = generics_zig.matchTemplatePattern;
    pub const matchTplHole = generics_zig.matchTplHole;
    pub const holeAccepts = generics_zig.holeAccepts;
    pub const isNumericString = generics_zig.isNumericString;
    pub const TplBuilder = generics_zig.TplBuilder;

    const props_zig = @import("checker/props.zig");
    pub const propOfType = props_zig.propOfType;
    pub const propOfTypeEx = props_zig.propOfTypeEx;
    pub const functionInterfaceProp = props_zig.functionInterfaceProp;
    pub const objectInterfaceProp = props_zig.objectInterfaceProp;
    pub const primitiveInterfaceProp = props_zig.primitiveInterfaceProp;
    pub const makePromise = props_zig.makePromise;
    pub const isPromiseLikeOf = props_zig.isPromiseLikeOf;
    pub const awaitedType = props_zig.awaitedType;
    pub const awaitedTypeRec = props_zig.awaitedTypeRec;
    pub const generatorYieldType = props_zig.generatorYieldType;
    pub const asyncGeneratorYieldType = props_zig.asyncGeneratorYieldType;
    pub const tupleElementUnion = props_zig.tupleElementUnion;
    pub const typeParamFallback = props_zig.typeParamFallback;
    pub const typeParamConstraint = props_zig.typeParamConstraint;
    pub const typeParamConstraintUncached = props_zig.typeParamConstraintUncached;
    pub const typeParamDefault = props_zig.typeParamDefault;
    pub const typeParamHasDefault = props_zig.typeParamHasDefault;
    pub const sigMinTargs = props_zig.sigMinTargs;
    pub const sigTargArityOk = props_zig.sigTargArityOk;
    pub const removeUndefined = props_zig.removeUndefined;
    pub const nonNullable = props_zig.nonNullable;
    pub const nonNullableNullish = props_zig.nonNullableNullish;
    pub const nonNullableChain = props_zig.nonNullableChain;
    pub const filterUnion = props_zig.filterUnion;
    pub const containsNullish = props_zig.containsNullish;
    pub const containsNull = props_zig.containsNull;
    pub const containsUndefinedish = props_zig.containsUndefinedish;
    pub const unionAnyMember = props_zig.unionAnyMember;
    pub const getTruthyPart = props_zig.getTruthyPart;
    pub const getFalsyPart = props_zig.getFalsyPart;
    pub const canBeFalsy = props_zig.canBeFalsy;
    pub const canBeNullish = props_zig.canBeNullish;
    pub const isZeroBigInt = props_zig.isZeroBigInt;

    const assign_zig = @import("checker/assign.zig");
    pub const isComparable = assign_zig.isComparable;
    pub const maybeAssignable = assign_zig.maybeAssignable;
    pub const castComparable = assign_zig.castComparable;
    pub const castComparableRec = assign_zig.castComparableRec;
    pub const mappedCastPeer = assign_zig.mappedCastPeer;
    pub const lenientOverlap = assign_zig.lenientOverlap;
    pub const lenientComparable = assign_zig.lenientComparable;
    pub const typeParamOverlapOperand = assign_zig.typeParamOverlapOperand;
    pub const typesHaveOverlap = assign_zig.typesHaveOverlap;
    pub const typesHaveOverlapRec = assign_zig.typesHaveOverlapRec;
    pub const enumOverlapsStringLiteral = assign_zig.enumOverlapsStringLiteral;
    pub const stringEnumCastOverlap = assign_zig.stringEnumCastOverlap;
    pub const declaredVarianceOfTypeParam = assign_zig.declaredVarianceOfTypeParam;
    pub const declaredVariances = assign_zig.declaredVariances;
    pub const varianceVerdict = assign_zig.varianceVerdict;
    pub const measuredVariances = assign_zig.measuredVariances;
    pub const measuredVarianceVerdict = assign_zig.measuredVarianceVerdict;
    pub const varianceMarkers = assign_zig.varianceMarkers;
    pub const isVarianceMarkerRef = assign_zig.isVarianceMarkerRef;
    pub const varianceMeasurable = assign_zig.varianceMeasurable;
    pub const VarianceScan = assign_zig.VarianceScan;
    pub const varianceAnnotationSpan = assign_zig.varianceAnnotationSpan;
    pub const reportVarianceMismatch = assign_zig.reportVarianceMismatch;
    pub const checkVarianceAnnotations = assign_zig.checkVarianceAnnotations;
    pub const refFacetOf = assign_zig.refFacetOf;
    pub const relIdDeeplyNested = assign_zig.relIdDeeplyNested;
    pub const isAssignable = assign_zig.isAssignable;
    pub const isWeakType = assign_zig.isWeakType;
    pub const weakTypeMismatch = assign_zig.weakTypeMismatch;
    pub const weakTargetKnows = assign_zig.weakTargetKnows;
    pub const unionHasCallableMember = assign_zig.unionHasCallableMember;
    pub const isCallableSource = assign_zig.isCallableSource;
    pub const nominalHeritageRelated = assign_zig.nominalHeritageRelated;
    pub const declaredBaseRefs = assign_zig.declaredBaseRefs;
    pub const condTrueUnderExtends = assign_zig.condTrueUnderExtends;
    pub const isCompound = assign_zig.isCompound;
    pub const isAssignableInner = assign_zig.isAssignableInner;
    pub const mappedKeySet = assign_zig.mappedKeySet;
    pub const mappedAddsOptional = assign_zig.mappedAddsOptional;
    pub const mappedAssignable = assign_zig.mappedAssignable;
    pub const indexAccessTargetConstraint = assign_zig.indexAccessTargetConstraint;
    pub const indexKeyDeclared = assign_zig.indexKeyDeclared;
    pub const indexObjBaseConstraint = assign_zig.indexObjBaseConstraint;
    pub const transitiveBaseConstraint = assign_zig.transitiveBaseConstraint;
    pub const isNonPrimitiveKind = assign_zig.isNonPrimitiveKind;
    pub const isCallableForFunctionIface = assign_zig.isCallableForFunctionIface;
    pub const tupleAssignable = assign_zig.tupleAssignable;
    pub const paramOptionalAt = assign_zig.paramOptionalAt;
    pub const tupleElemTypeAt = assign_zig.tupleElemTypeAt;
    pub const structuralAssignable = assign_zig.structuralAssignable;
    pub const reduceNeverIntersections = assign_zig.reduceNeverIntersections;
    pub const intersectionIsNever = assign_zig.intersectionIsNever;
    pub const intersectionPairAssignable = assign_zig.intersectionPairAssignable;
    pub const hasNullishMember = assign_zig.hasNullishMember;
    pub const computeIntersectionIsNever = assign_zig.computeIntersectionIsNever;
    pub const isUnitLikeKind = assign_zig.isUnitLikeKind;
    pub const discriminatedUnionAssignable = assign_zig.discriminatedUnionAssignable;
    pub const collectPropNames = assign_zig.collectPropNames;
    pub const isUnitOrUnitUnion = assign_zig.isUnitOrUnitUnion;
    pub const nonDiscPropsAssignable = assign_zig.nonDiscPropsAssignable;
    pub const sourceSatisfiesSigs = assign_zig.sourceSatisfiesSigs;
    pub const isNumericPropName = assign_zig.isNumericPropName;
    pub const genericSourceRelatesByInference = assign_zig.genericSourceRelatesByInference;
    pub const instantiateSigInContextOf = assign_zig.instantiateSigInContextOf;
    pub const signatureAssignable = assign_zig.signatureAssignable;
    pub const signatureAssignableMode = assign_zig.signatureAssignableMode;
    pub const typeHasMapped = assign_zig.typeHasMapped;
    pub const eraseParamsToAny = assign_zig.eraseParamsToAny;
    pub const eraseParamsToAnyOf = assign_zig.eraseParamsToAnyOf;
    pub const signatureAssignableErased = assign_zig.signatureAssignableErased;
    pub const signatureAssignableModeErase = assign_zig.signatureAssignableModeErase;
    pub const signatureAssignableModeInner = assign_zig.signatureAssignableModeInner;
    pub const signatureAssignableModeInnerErase = assign_zig.signatureAssignableModeInnerErase;
    pub const callbackSigOf = assign_zig.callbackSigOf;
    pub const stripNullish = assign_zig.stripNullish;
    pub const includesNullish = assign_zig.includesNullish;
    pub const identityProbeCond = assign_zig.identityProbeCond;
    pub const identityProbeRelated = assign_zig.identityProbeRelated;
    pub const eraseTypeParams = assign_zig.eraseTypeParams;
    pub const eraseParamsOf = assign_zig.eraseParamsOf;
    pub const paramTypeAt = assign_zig.paramTypeAt;
    pub const paramTypeAtInferred = assign_zig.paramTypeAtInferred;
    pub const paramTotal = assign_zig.paramTotal;
    pub const effParamCount = assign_zig.effParamCount;
    pub const requiredParams = assign_zig.requiredParams;
    pub const paramAcceptsVoid = assign_zig.paramAcceptsVoid;
    pub const checkAssignable = assign_zig.checkAssignable;
    pub const inlineCondAnnRejects = assign_zig.inlineCondAnnRejects;
    pub const condStrictSourceRejects = assign_zig.condStrictSourceRejects;
    pub const checkSatisfies = assign_zig.checkSatisfies;
    pub const elaborateLiteralError = assign_zig.elaborateLiteralError;
    pub const freshLiteralUnionMismatch = assign_zig.freshLiteralUnionMismatch;
    pub const literalPropsKnownIn = assign_zig.literalPropsKnownIn;
    pub const elemTypeAt = assign_zig.elemTypeAt;
    pub const unionElemTypeAt = assign_zig.unionElemTypeAt;
    pub const bestMatchingUnionMember = assign_zig.bestMatchingUnionMember;
    pub const elaborateCallbackError = assign_zig.elaborateCallbackError;
    pub const callbackParamsCompatible = assign_zig.callbackParamsCompatible;
    pub const tryReportMissingProps = assign_zig.tryReportMissingProps;
    pub const reportNotAssignable = assign_zig.reportNotAssignable;
    pub const stringLiteralSuggestion = assign_zig.stringLiteralSuggestion;
    pub const isSourceObjecty = assign_zig.isSourceObjecty;
    pub const excessPropertyCheck = assign_zig.excessPropertyCheck;
    pub const excessPropertyScan = assign_zig.excessPropertyScan;
    pub const freshLiteralRejects = assign_zig.freshLiteralRejects;
    pub const targetIsEmptyish = assign_zig.targetIsEmptyish;
    pub const intersectionExcessCheckable = assign_zig.intersectionExcessCheckable;
    pub const targetKnowsProp = assign_zig.targetKnowsProp;
    pub const targetPropType = assign_zig.targetPropType;
    pub const Variance = assign_zig.Variance;
    pub const Measured = assign_zig.Measured;
    pub const SigMode = assign_zig.SigMode;

    const expr_zig = @import("checker/expr.zig");
    pub const checkExprCached = expr_zig.checkExprCached;
    pub const checkExpr = expr_zig.checkExpr;
    pub const checkJsxElement = expr_zig.checkJsxElement;
    pub const isIntrinsicJsxTag = expr_zig.isIntrinsicJsxTag;
    pub const jsxNamespaceType = expr_zig.jsxNamespaceType;
    pub const jsxNamespaceMember = expr_zig.jsxNamespaceMember;
    pub const jsxRuntimeNamespaceMember = expr_zig.jsxRuntimeNamespaceMember;
    pub const jsxComponentProps = expr_zig.jsxComponentProps;
    pub const typeParamAtTopLevel = expr_zig.typeParamAtTopLevel;
    pub const constraintIsPrimitive = expr_zig.constraintIsPrimitive;
    pub const typeHasPrimitive = expr_zig.typeHasPrimitive;
    pub const constraintIsAnyIndex = expr_zig.constraintIsAnyIndex;
    pub const inferJsxTargs = expr_zig.inferJsxTargs;
    pub const jsxClassComponentProps = expr_zig.jsxClassComponentProps;
    pub const jsxPropsMemberName = expr_zig.jsxPropsMemberName;
    pub const checkJsxAttributes = expr_zig.checkJsxAttributes;
    pub const jsxAttrsObject = expr_zig.jsxAttrsObject;
    pub const jsxTargetString = expr_zig.jsxTargetString;
    pub const providedHas = expr_zig.providedHas;
    pub const jsxSpreadInfo = expr_zig.jsxSpreadInfo;
    pub const jsxTargetShape = expr_zig.jsxTargetShape;
    pub const jsxIntrinsicAttrNames = expr_zig.jsxIntrinsicAttrNames;
    pub const jsxChildrenAttrName = expr_zig.jsxChildrenAttrName;
    pub const jsxChildrenPresent = expr_zig.jsxChildrenPresent;
    pub const containsAtom = expr_zig.containsAtom;
    pub const jsxAttributeValueType = expr_zig.jsxAttributeValueType;
    pub const checkIdentifier = expr_zig.checkIdentifier;
    pub const checkTdz = expr_zig.checkTdz;
    pub const checkUseBeforeAssigned = expr_zig.checkUseBeforeAssigned;
    pub const checkArrayLiteral = expr_zig.checkArrayLiteral;
    pub const checkTaggedTemplate = expr_zig.checkTaggedTemplate;
    pub const arrayLiteralElemType = expr_zig.arrayLiteralElemType;
    pub const contextualArrayElemType = expr_zig.contextualArrayElemType;
    pub const contextualElemTypeAt = expr_zig.contextualElemTypeAt;
    pub const multiArrayLikeBranches = expr_zig.multiArrayLikeBranches;
    pub const checkConstArrayLiteral = expr_zig.checkConstArrayLiteral;
    pub const ctxIsMutableArrayLike = expr_zig.ctxIsMutableArrayLike;
    pub const ctxIsMutableArrayLikeAt = expr_zig.ctxIsMutableArrayLikeAt;
    pub const collectTypeParamSyms = expr_zig.collectTypeParamSyms;
    pub const isInstantiableKind = expr_zig.isInstantiableKind;
    pub const deferredDefaultConstraint = expr_zig.deferredDefaultConstraint;
    pub const baseConstraintOf = expr_zig.baseConstraintOf;
    pub const isPrimitiveLiteralish = expr_zig.isPrimitiveLiteralish;
    pub const objLitIsContextSensitive = expr_zig.objLitIsContextSensitive;
    pub const objLitIsShallowContextSensitive = expr_zig.objLitIsShallowContextSensitive;
    pub const objLitIsContextSensitiveAt = expr_zig.objLitIsContextSensitiveAt;
    pub const literalOfContextualType = expr_zig.literalOfContextualType;
    pub const paramWantsLiteralCtx = expr_zig.paramWantsLiteralCtx;
    pub const paramWantsLiteralCtxAt = expr_zig.paramWantsLiteralCtxAt;
    pub const keepLiteral = expr_zig.keepLiteral;
    pub const contextAdmitsLiteral = expr_zig.contextAdmitsLiteral;
    pub const enumMemberLiteralKind = expr_zig.enumMemberLiteralKind;
    pub const constraintKeepsLiteralKind = expr_zig.constraintKeepsLiteralKind;
    pub const discriminantLiteralOf = expr_zig.discriminantLiteralOf;
    pub const discriminateCtxUnion = expr_zig.discriminateCtxUnion;
    pub const distributableSpreads = expr_zig.distributableSpreads;
    pub const checkObjectLiteral = expr_zig.checkObjectLiteral;
    pub const objectLiteralType = expr_zig.objectLiteralType;
    pub const unionNestedPropType = expr_zig.unionNestedPropType;
    pub const ctxIndexType = expr_zig.ctxIndexType;
    pub const ctxPropType = expr_zig.ctxPropType;
    pub const isOptionalChain = expr_zig.isOptionalChain;
    pub const chainObjType = expr_zig.chainObjType;
    pub const checkMemberExpr = expr_zig.checkMemberExpr;
    pub const memberChainInner = expr_zig.memberChainInner;
    pub const checkNullishAccess = expr_zig.checkNullishAccess;
    pub const entityNameOf = expr_zig.entityNameOf;
    pub const propertyTypeOf = expr_zig.propertyTypeOf;
    pub const checkIndexExpr = expr_zig.checkIndexExpr;
    pub const numericKeyProp = expr_zig.numericKeyProp;
    pub const indexChainInner = expr_zig.indexChainInner;
    pub const checkPrefixUnary = expr_zig.checkPrefixUnary;
    pub const isNumberish = expr_zig.isNumberish;
    pub const isBigintish = expr_zig.isBigintish;
    pub const isStringish = expr_zig.isStringish;
    pub const hasPrimitiveFacet = expr_zig.hasPrimitiveFacet;
    pub const isArithmeticOperand = expr_zig.isArithmeticOperand;
    pub const checkArithmeticOperand = expr_zig.checkArithmeticOperand;
    pub const instanceofRhsIsFunctionLike = expr_zig.instanceofRhsIsFunctionLike;
    pub const checkBinary = expr_zig.checkBinary;
    pub const checkAssignExpr = expr_zig.checkAssignExpr;
    pub const compoundTargetBase = expr_zig.compoundTargetBase;
    pub const compoundResultType = expr_zig.compoundResultType;
    pub const assignTargetIsEvolving = expr_zig.assignTargetIsEvolving;
    pub const checkAssignmentTarget = expr_zig.checkAssignmentTarget;
    pub const setterWriteType = expr_zig.setterWriteType;
    pub const interfaceSetterParam = expr_zig.interfaceSetterParam;
    pub const setterParamInMembers = expr_zig.setterParamInMembers;
    pub const classSetterParam = expr_zig.classSetterParam;
    pub const setterParamOfProto = expr_zig.setterParamOfProto;
    pub const checkDestructuringElement = expr_zig.checkDestructuringElement;
    pub const intersectedCallSignature = expr_zig.intersectedCallSignature;
    pub const contextualCallSig = expr_zig.contextualCallSig;
    pub const fnExprIsContextSensitive = expr_zig.fnExprIsContextSensitive;
    pub const checkFunctionLikeExpr = expr_zig.checkFunctionLikeExpr;
    pub const templateAtom = expr_zig.templateAtom;
    pub const numberTokenValue = expr_zig.numberTokenValue;
    pub const JsxAttr = expr_zig.JsxAttr;
    pub const JsxSpread = expr_zig.JsxSpread;
    pub const JsxTargetShape = expr_zig.JsxTargetShape;
    pub const max_spread_distribution = expr_zig.max_spread_distribution;
    pub const DistSpread = expr_zig.DistSpread;
    pub const Subst = expr_zig.Subst;

    const calls_zig = @import("checker/calls.zig");
    pub const callShape = calls_zig.callShape;
    pub const importCallType = calls_zig.importCallType;
    pub const checkCallExpr = calls_zig.checkCallExpr;
    pub const checkCallExprInner = calls_zig.checkCallExprInner;
    pub const checkThisArg = calls_zig.checkThisArg;
    pub const countArgs = calls_zig.countArgs;
    pub const resolveSignatureCall = calls_zig.resolveSignatureCall;
    pub const instantiateSigForCall = calls_zig.instantiateSigForCall;
    pub const instantiationExprType = calls_zig.instantiationExprType;
    pub const typeArgsSpan = calls_zig.typeArgsSpan;
    pub const fillFromReturnContext = calls_zig.fillFromReturnContext;
    pub const isOuterInferVar = calls_zig.isOuterInferVar;
    pub const mentionsActiveInferVar = calls_zig.mentionsActiveInferVar;
    pub const partialParamCtx = calls_zig.partialParamCtx;
    pub const instantiateKnownParams = calls_zig.instantiateKnownParams;
    pub const paramIsBareCallbackReturn = calls_zig.paramIsBareCallbackReturn;
    pub const isBareOrUnionMember = calls_zig.isBareOrUnionMember;
    pub const inferTypeArgs = calls_zig.inferTypeArgs;
    pub const tpIndex = calls_zig.tpIndex;
    pub const clampToConstraint = calls_zig.clampToConstraint;
    pub const covLiteralShape = calls_zig.covLiteralShape;
    pub const covLiteralBase = calls_zig.covLiteralBase;
    pub const covNullableFlags = calls_zig.covNullableFlags;
    pub const covStripNullable = calls_zig.covStripNullable;
    pub const covSubtypeOf = calls_zig.covSubtypeOf;
    pub const combineCovariant = calls_zig.combineCovariant;
    pub const combineContravariant = calls_zig.combineContravariant;
    pub const contraSlot = calls_zig.contraSlot;
    pub const topSlot = calls_zig.topSlot;
    pub const revSlot = calls_zig.revSlot;
    pub const unify = calls_zig.unify;
    pub const discriminatedConstituent = calls_zig.discriminatedConstituent;
    pub const intersectionMembersPair = calls_zig.intersectionMembersPair;
    pub const constituentRelatesTo = calls_zig.constituentRelatesTo;
    pub const constituentCarriesInference = calls_zig.constituentCarriesInference;
    pub const inferReverseMapped = calls_zig.inferReverseMapped;
    pub const inferMappedKeySet = calls_zig.inferMappedKeySet;
    pub const stripSourceParam = calls_zig.stripSourceParam;
    pub const mintReverseElemVar = calls_zig.mintReverseElemVar;
    pub const substElemAccess = calls_zig.substElemAccess;
    pub const bindAnyToTypeParams = calls_zig.bindAnyToTypeParams;
    pub const argumentsMatch = calls_zig.argumentsMatch;
    pub const checkCallArguments = calls_zig.checkCallArguments;
    pub const CallShape = calls_zig.CallShape;

    const flow_zig = @import("checker/flow.zig");
    pub const makeRefKey = flow_zig.makeRefKey;
    pub const refPath = flow_zig.refPath;
    pub const refKeyIndex = flow_zig.refKeyIndex;
    pub const constIndexOf = flow_zig.constIndexOf;
    pub const stableIndexSymbol = flow_zig.stableIndexSymbol;
    pub const buildRefKey = flow_zig.buildRefKey;
    pub const referenceCandidate = flow_zig.referenceCandidate;
    pub const refMatches = flow_zig.refMatches;
    pub const refMatchesPath = flow_zig.refMatchesPath;
    pub const refPrefixWritten = flow_zig.refPrefixWritten;
    pub const isNarrowable = flow_zig.isNarrowable;
    pub const flowTypeOfReference = flow_zig.flowTypeOfReference;
    pub const flowTypeOfKey = flow_zig.flowTypeOfKey;
    pub const narrowedPatternBinding = flow_zig.narrowedPatternBinding;
    pub const flowReachable = flow_zig.flowReachable;
    pub const callReturnsNever = flow_zig.callReturnsNever;
    pub const pushChainGuards = flow_zig.pushChainGuards;
    pub const applyChainGuards = flow_zig.applyChainGuards;
    pub const flowInFlight = flow_zig.flowInFlight;
    pub const flowType = flow_zig.flowType;
    pub const flowTypeInner = flow_zig.flowTypeInner;
    pub const assignmentRefines = flow_zig.assignmentRefines;
    pub const assignNarrows = flow_zig.assignNarrows;
    pub const isConstantRefSym = flow_zig.isConstantRefSym;
    pub const constAliasInit = flow_zig.constAliasInit;
    pub const narrowByCondition = flow_zig.narrowByCondition;
    pub const narrowByEqualityCond = flow_zig.narrowByEqualityCond;
    pub const optionalChainContainsRef = flow_zig.optionalChainContainsRef;
    pub const narrowByOptChainContainment = flow_zig.narrowByOptChainContainment;
    pub const optChainComparandRemovesNullable = flow_zig.optChainComparandRemovesNullable;
    pub const optChainComparandConstituentOk = flow_zig.optChainComparandConstituentOk;
    pub const typeofTargetOf = flow_zig.typeofTargetOf;
    pub const typeofChainContainsRef = flow_zig.typeofChainContainsRef;
    pub const narrowByTypeofChainContainment = flow_zig.narrowByTypeofChainContainment;
    pub const discriminantOfRef = flow_zig.discriminantOfRef;
    pub const identIsSym = flow_zig.identIsSym;
    pub const ensureReassignScan = flow_zig.ensureReassignScan;
    pub const recordReassign = flow_zig.recordReassign;
    pub const markReassignTarget = flow_zig.markReassignTarget;
    pub const markMemberWriteRoot = flow_zig.markMemberWriteRoot;
    pub const recordMemberWrite = flow_zig.recordMemberWrite;
    pub const destructuredAssignType = flow_zig.destructuredAssignType;
    pub const patternBindsSym = flow_zig.patternBindsSym;
    pub const varDeclBindsSym = flow_zig.varDeclBindsSym;
    pub const declaratorBindsSym = flow_zig.declaratorBindsSym;
    pub const reduceEvolvingJoin = flow_zig.reduceEvolvingJoin;
    pub const assignmentReduced = flow_zig.assignmentReduced;
    pub const narrowByLiteralEquality = flow_zig.narrowByLiteralEquality;
    pub const narrowToValue = flow_zig.narrowToValue;
    pub const unionHasKind = flow_zig.unionHasKind;
    pub const narrowExcludeValue = flow_zig.narrowExcludeValue;
    pub const narrowByTypeof = flow_zig.narrowByTypeof;
    pub const narrowByTypeofResolved = flow_zig.narrowByTypeofResolved;
    pub const typeofMatches = flow_zig.typeofMatches;
    pub const typeofMatchesFn = flow_zig.typeofMatchesFn;
    pub const enumTypeofDomain = flow_zig.enumTypeofDomain;
    pub const hasCallableShape = flow_zig.hasCallableShape;
    pub const narrowByDiscriminant = flow_zig.narrowByDiscriminant;
    pub const narrowByPropTruthiness = flow_zig.narrowByPropTruthiness;
    pub const isDiscriminantProp = flow_zig.isDiscriminantProp;
    pub const propDeclaredForIn = flow_zig.propDeclaredForIn;
    pub const narrowByInProp = flow_zig.narrowByInProp;
    pub const declaredPathType = flow_zig.declaredPathType;
    pub const symExplicitlyTyped = flow_zig.symExplicitlyTyped;
    pub const declaredPathTypeInner = flow_zig.declaredPathTypeInner;
    pub const classSideOnCycle = flow_zig.classSideOnCycle;
    pub const guardCallOf = flow_zig.guardCallOf;
    pub const calleeNeedsExplicitDecl = flow_zig.calleeNeedsExplicitDecl;
    pub const initReturnsPredicate = flow_zig.initReturnsPredicate;
    pub const narrowByGuardCall = flow_zig.narrowByGuardCall;
    pub const narrowByGuardArgChain = flow_zig.narrowByGuardArgChain;
    pub const narrowByAssertCall = flow_zig.narrowByAssertCall;
    pub const instanceTypeOfConstructor = flow_zig.instanceTypeOfConstructor;
    pub const instanceofInstanceType = flow_zig.instanceofInstanceType;
    pub const isNullishKind = flow_zig.isNullishKind;
    pub const admitsNullish = flow_zig.admitsNullish;
    pub const narrowByInstance = flow_zig.narrowByInstance;
    pub const narrowBySwitchClause = flow_zig.narrowBySwitchClause;
    pub const switchDefaultCovered = flow_zig.switchDefaultCovered;
    pub const discriminantCovered = flow_zig.discriminantCovered;
    pub const switchOfClause = flow_zig.switchOfClause;
    pub const definitelyAssigned = flow_zig.definitelyAssigned;
    pub const definitelyAssignedInner = flow_zig.definitelyAssignedInner;
    pub const assignTargetsSymForDa = flow_zig.assignTargetsSymForDa;
    pub const max_ref_depth = flow_zig.max_ref_depth;
    pub const max_deep_ref_depth = flow_zig.max_deep_ref_depth;
    pub const PathElem = flow_zig.PathElem;
    pub const RefKey = flow_zig.RefKey;
    pub const DeepPath = flow_zig.DeepPath;
    pub const this_flow_root = flow_zig.this_flow_root;
    pub const FlowQ = flow_zig.FlowQ;
    pub const RefQ = flow_zig.RefQ;
    pub const SymLoop = flow_zig.SymLoop;
    pub const LoopFrame = flow_zig.LoopFrame;
    pub const GuardCall = flow_zig.GuardCall;

    const stmts_zig = @import("checker/stmts.zig");
    pub const checkStatement = stmts_zig.checkStatement;
    pub const checkVarDeclStatement = stmts_zig.checkVarDeclStatement;
    pub const checkDeclarator = stmts_zig.checkDeclarator;
    pub const materializePatternTypes = stmts_zig.materializePatternTypes;
    pub const checkForInOf = stmts_zig.checkForInOf;
    pub const assignPatternFromType = stmts_zig.assignPatternFromType;
    pub const forOfElementType = stmts_zig.forOfElementType;
    pub const iterationElementType = stmts_zig.iterationElementType;
    pub const asyncIterationElementType = stmts_zig.asyncIterationElementType;
    pub const callableReturn = stmts_zig.callableReturn;
    pub const iteratorNextValue = stmts_zig.iteratorNextValue;
    pub const checkSwitch = stmts_zig.checkSwitch;
    pub const checkReturn = stmts_zig.checkReturn;
    pub const checkFunctionDecl = stmts_zig.checkFunctionDecl;
    pub const drainDeferredBodies = stmts_zig.drainDeferredBodies;
    pub const checkFunctionBody = stmts_zig.checkFunctionBody;
    pub const stmtListTerminal = stmts_zig.stmtListTerminal;
    pub const stmtTerminal = stmts_zig.stmtTerminal;
    pub const switchTerminal = stmts_zig.switchTerminal;
    pub const switchIsExhaustive = stmts_zig.switchIsExhaustive;
    pub const typeofSwitchIsExhaustive = stmts_zig.typeofSwitchIsExhaustive;
    pub const containsBreak = stmts_zig.containsBreak;
    pub const checkNamespace = stmts_zig.checkNamespace;
    pub const checkClass = stmts_zig.checkClass;
    pub const checkStaticSideExtends = stmts_zig.checkStaticSideExtends;
    pub const checkDecorator = stmts_zig.checkDecorator;
    pub const decoCode = stmts_zig.decoCode;
    pub const decoContextName = stmts_zig.decoContextName;
    pub const checkMemberDecoratorSig = stmts_zig.checkMemberDecoratorSig;
    pub const decoContextRef = stmts_zig.decoContextRef;
    pub const checkDecoratorSig = stmts_zig.checkDecoratorSig;
    pub const decoSigMatches = stmts_zig.decoSigMatches;
    pub const decoAcceptsValue = stmts_zig.decoAcceptsValue;
    pub const decoContextMismatch = stmts_zig.decoContextMismatch;
    pub const globalSymNamed = stmts_zig.globalSymNamed;
    pub const checkInterfaceDecl = stmts_zig.checkInterfaceDecl;
    pub const checkTypeAliasDecl = stmts_zig.checkTypeAliasDecl;
    pub const evalTypeParamDecls = stmts_zig.evalTypeParamDecls;
    pub const DecoPos = stmts_zig.DecoPos;
};

test {
    _ = @import("checker/tests.zig");
    _ = @import("checker/bump.zig");
}
