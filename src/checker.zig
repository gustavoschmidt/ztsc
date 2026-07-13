//! Checker core (M4/M5): structural assignability, inference, literal
//! widening, control-flow narrowing, tsc-coded diagnostics; multi-file
//! programs via the sealed module graph (M5).
//!
//! Scope & stance (documented deviations are intentional for the M6 subset):
//!
//! - **Multi-file (M5)**: a Checker instance checks a *partition* of the
//!   program's files (ROADMAP.md §2.3). Symbols are addressed globally
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
    return checkFiles(arena, io, gpa, interner, prog, &.{0});
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
) Error!Check {
    var c = try Checker.init(arena, io, gpa, interner, prog, owned);
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
    w: *std.Io.Writer,
) (Error || std.Io.Writer.Error)!Check {
    var c = try Checker.init(arena, io, gpa, interner, prog, owned);
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
    var c = try Checker.init(arena, io, gpa, interner, prog, &.{0});
    defer c.deinit();
    try c.run();
    try c.dumpTypes(w);
    return c.seal();
}

const max_instantiation_depth = 48;
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
    scratch_arena: *std.heap.ArenaAllocator,

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
    /// FileId -> module namespace object type (0 = in progress).
    ns_types: std.AutoHashMapUnmanaged(FileId, TypeId) = .empty,
    /// Ambient-module namespace-object cache, keyed by ambient_exports index.
    ambient_ns_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// (source << 32 | target) -> Relation.
    relation: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    /// ref TypeId -> expanded structural type.
    expansions: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty,
    /// Generic (uninstantiated) bodies per symbol: interface/class-instance/
    /// class-static/alias.
    iface_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    class_inst_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    class_static_cache: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Enum symbol -> value object type (the `typeof E` object with members).
    enum_value_cache: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    /// Enum symbol -> computed EnumInfo (const-ness, member values).
    enum_info_cache: std.AutoHashMapUnmanaged(SymbolId, EnumInfo) = .empty,
    alias_generic: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .empty,
    alias_state: std.AutoHashMapUnmanaged(SymbolId, u8) = .empty,
    /// Narrowed-type cache per (flow, reference, declared) query.
    flow_cache: std.AutoHashMapUnmanaged(FlowQ, TypeId) = .empty,
    /// Interned narrowing reference keys ((sym << 32 | prop) -> index).
    ref_keys: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// (flow << 32 | symbol) -> definitely-assigned (2 computing, 0/1 result).
    da_cache: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    /// containsTypeParam memo: 0 unknown, 1 no, 2 yes.
    ctp_cache: std.AutoHashMapUnmanaged(TypeId, u8) = .empty,
    /// Atom cache to avoid re-locking the shared interner.
    atom_cache: std.StringHashMapUnmanaged(Atom) = .empty,

    // --- context ------------------------------------------------------------
    cur_scope: ScopeId = binder.file_scope,
    /// Innermost enclosing function-ish return context.
    fn_ctx: ?FnCtx = null,
    /// `this` type inside class methods (0 = any).
    this_type: TypeId = 0,
    inst_depth: u32 = 0,
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
    // Names of the lib interfaces async/await + generators bridge to (M11).
    atom_Promise: Atom = 0,
    atom_Generator: Atom = 0,
    atom_Iterator: Atom = 0,
    atom_IterableIterator: Atom = 0,
    atom_sym_iterator: Atom = 0,
    atom_next: Atom = 0,
    atom_value: Atom = 0,
    atom_JSX: Atom = 0,
    atom_IntrinsicElements: Atom = 0,
    atom_Element: Atom = 0,

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
        };
        c.carena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.carena);
        c.carena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.carena.deinit();
        c.scratch_arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(c.scratch_arena);
        c.scratch_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer c.scratch_arena.deinit();
        const arena_alloc = c.carena.allocator();
        c.ts = try Store.init(arena_alloc);
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
        c.atom_length = try c.atom("length");
        c.atom_Array = try c.atom("Array");
        c.atom_String = try c.atom("String");
        c.atom_Number = try c.atom("Number");
        c.atom_Boolean = try c.atom("Boolean");
        c.atom_Promise = try c.atom("Promise");
        c.atom_Generator = try c.atom("Generator");
        c.atom_Iterator = try c.atom("Iterator");
        c.atom_IterableIterator = try c.atom("IterableIterator");
        c.atom_sym_iterator = try c.atom(ast.wellKnownSymbolKey("iterator").?);
        c.atom_next = try c.atom("next");
        c.atom_value = try c.atom("value");
        c.atom_JSX = try c.atom("JSX");
        c.atom_IntrinsicElements = try c.atom("IntrinsicElements");
        c.atom_Element = try c.atom("Element");
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
                _ = c.scratch_arena.reset(.retain_capacity);
            }
        }
        // TDZ / use-before-assign / 2304 come from the walk itself.
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
        if (flags & ast.Flags.computed != 0) {
            if (ast.wellKnownSymbolKey(c.tokenText(tok))) |k| return c.atom(k);
        }
        return c.memberAtom(tok);
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
            .object_keyword => try w.writeAll("object"),
            .bool_true => try w.writeAll("true"),
            .bool_false => try w.writeAll("false"),
            .string_literal => try w.print("\"{s}\"", .{c.atomText(s.literalAtom(t))}),
            .bigint_literal => try w.print("{s}", .{c.atomText(s.literalAtom(t))}),
            .number_literal, .number_literal_fresh => try printNumber(w, s.numberValue(t)),
            .union_type => {
                // tsc display order: null and undefined go last.
                var first = true;
                for (s.members(t)) |m| {
                    if (s.kind(m) == .null or s.kind(m) == .undefined) continue;
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try c.printTypeParen(w, m, depth + 1, true);
                }
                for (s.members(t)) |m| {
                    if (s.kind(m) != .null) continue;
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try w.writeAll("null");
                }
                for (s.members(t)) |m| {
                    if (s.kind(m) != .undefined) continue;
                    if (!first) try w.writeAll(" | ");
                    first = false;
                    try w.writeAll("undefined");
                }
            },
            .intersection => {
                for (s.members(t), 0..) |m, i| {
                    if (i > 0) try w.writeAll(" & ");
                    try c.printTypeParen(w, m, depth + 1, true);
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
                if (n == 0 and sidx == 0 and nidx == 0) return w.writeAll("{}");
                try w.writeAll("{ ");
                var first = true;
                for (0..n) |i| {
                    const p = s.objectProp(t, @intCast(i));
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
        }
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

    fn printNumber(w: *std.Io.Writer, v: f64) PrintErr!void {
        if (v == @floor(v) and @abs(v) < 1e15) {
            try w.print("{d}", .{@as(i64, @intFromFloat(v))});
        } else {
            try w.print("{d}", .{v});
        }
    }

    fn symbolName(c: *Checker, sym: u32) []const u8 {
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
            .object_type => return c.objectTypeFromMembers(c.tree.nodeRange(node), false),
            .function_type => return c.signatureOfProto(node, d.lhs, false, true),
            .keyof_type => return c.keyofType(try c.typeFromTypeNode(d.lhs)),
            .typeof_type => return c.typeofEntity(d.lhs),
            .readonly_type => return c.typeFromTypeNode(d.lhs), // readonly T[] ~ T[]
            .indexed_access_type => {
                const obj = try c.typeFromTypeNode(d.lhs);
                const idx = try c.typeFromTypeNode(d.rhs);
                return c.indexedAccessType(obj, idx);
            },
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
        if (c.nodeTag(name_node) == .qualified_name) return c.typeFromQualifiedName(name_node, args);
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
        switch (c.resolveSpace(a, c.cur_scope, false)) {
            .sym => |sym0| {
                var sym = sym0;
                var f = c.symFlags(sym);
                if (f.import_binding) {
                    const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
                    switch (tgt.kind) {
                        .binding => {
                            sym = c.toGlobalIn(tgt.file, tgt.payload);
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
                if (f.type_param) return c.ts.makeTypeParam(sym);
                if (f.enum_decl) return c.ts.makeEnumType(sym);
                if (f.type_alias) return c.aliasInstance(sym, args, tok);
                if (f.interface or f.class) {
                    const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
                    return c.ts.makeRef(sym, fixed);
                }
                return types.any_type;
            },
            .wrong_space => {
                try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
                return types.error_type;
            },
            .none => {
                if (c.suggestName(a, c.cur_scope, false)) |sugg| {
                    try c.diagFmt(2552, c.tokSpan(tok), "Cannot find name '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
                } else {
                    try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{c.tokenText(tok)});
                }
                return types.error_type;
            },
        }
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

    /// Resolve a qualified type name `A.B.T` (in type position) by walking
    /// namespace containers left-to-right, then building the final member's
    /// type. Missing/non-exported members report TS2694 like tsc.
    fn typeFromQualifiedName(c: *Checker, node: Node, args: []const TypeId) Error!TypeId {
        const d = c.tree.nodeData(node);
        const name_tok: TokenIndex = d.rhs;
        const name = try c.memberAtom(name_tok);
        const ns_sym = (try c.resolveTypeNamespace(d.lhs)) orelse return types.any_type;
        if (c.namespaceMemberSym(ns_sym, name)) |g| {
            const mf = c.symFlags(g);
            if (mf.exported and hasTypeMeaning(mf)) {
                return c.namedTypeFromSymbol(g, args, name_tok);
            }
        }
        try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ c.symbolName(ns_sym), c.atomText(name) });
        return types.error_type;
    }

    /// Resolve a namespace entity (identifier or nested qualified name) to its
    /// namespace symbol (global id), or null if it is not a namespace.
    fn resolveTypeNamespace(c: *Checker, node: Node) Error!?SymbolId {
        switch (c.nodeTag(node)) {
            .identifier => {
                const tok = c.tree.nodeMainToken(node);
                const a = try c.atomOfToken(tok);
                switch (c.resolveSpace(a, c.cur_scope, false)) {
                    .sym => |sym| {
                        if (c.symFlags(sym).namespace_decl) return sym;
                        return null;
                    },
                    else => return null,
                }
            },
            .qualified_name => {
                const d = c.tree.nodeData(node);
                const outer = (try c.resolveTypeNamespace(d.lhs)) orelse return null;
                const name = try c.memberAtom(d.rhs);
                if (c.namespaceMemberSym(outer, name)) |g| {
                    const mf = c.symFlags(g);
                    if (mf.exported and mf.namespace_decl) return g;
                }
                return null;
            },
            else => return null,
        }
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
        if (c.nodeTag(node) != .identifier) return types.any_type;
        const tok = c.tree.nodeMainToken(node);
        if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
        const a = try c.atomOfToken(tok);
        switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |sym| return c.typeOfSymbol(sym),
            .wrong_space => return types.any_type,
            .none => {
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
                try c.diagFmt(2315, c.tokSpan(tok), "Type '{s}' is not generic.", .{c.symbolName(sym)});
            } else {
                try c.diagFmt(2314, c.tokSpan(tok), "Generic type '{s}' requires {d} type argument(s).", .{ c.symbolName(sym), min });
            }
            return null;
        }
        var out = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| {
            if (i < args.len) {
                out[i] = args[i];
            } else if (tp.default != 0) {
                // Defaults are nodes of the declaring file; evaluate there.
                const saved = c.enterSymFile(sym);
                defer c.restoreCtx(saved);
                c.cur_scope = c.symScope(tp.sym);
                out[i] = try c.typeFromTypeNode(tp.default);
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
            else => return types.never_type,
        }
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
                    return if (p.optional()) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                }
                if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0) {
                    return c.ts.objectStringIndex(r);
                }
                return types.any_type;
            },
            .number, .number_literal => return c.numberIndexType(r),
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

    /// Object type from interface/object-literal-type member nodes.
    fn objectTypeFromMembers(c: *Checker, member_nodes: []const Node, fresh: bool) Error!TypeId {
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
                    const ty = if (md.lhs != 0) try c.typeFromTypeNode(md.lhs) else types.any_type;
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
                else => {},
            }
        }
        for (order.items) |name| {
            const sigs = methods.get(name).?;
            const ty = try c.ts.makeOverloads(sigs.items);
            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = ty, .flags = 0 });
        }
        // Get-only accessors are read-only properties.
        var git = getter_keys.keyIterator();
        while (git.next()) |k| {
            if (setter_keys.contains(k.*)) continue;
            if (prop_index.get(k.*)) |idx| props.items[idx].flags |= types.prop_flag_readonly;
        }
        return c.ts.makeObject(props.items, sindex, nindex, fresh);
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
        for (c.tree.extraRange(proto.tp_start, proto.tp_end)) |tp| {
            if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
            const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
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
        for (param_nodes) |pn| {
            if (pn == null_node) continue;
            const p = try c.paramInfo(pn, pi, ctx_sig, report_implicit);
            try params.append(c.scratch(), p);
            // Pin the parameter symbol's type so body checking sees the
            // contextual/inferred type (not a re-derivation without ctx).
            if (p.name != 0) {
                if (c.bind.lookupInScope(c.cur_scope, p.name)) |psym| {
                    if (c.bind.symbol_flags[psym].param) c.setTypeOfSymbol(c.toGlobal(psym), p.ty);
                }
            }
            pi += 1;
        }

        const is_async = proto.flags & ast.Flags.async != 0;
        const is_generator = proto.flags & ast.Flags.generator != 0;
        var ret: TypeId = types.any_type;
        var pred: ?types.Predicate = null;
        if (proto.return_type != 0 and c.nodeTag(proto.return_type) == .type_predicate) {
            // `x is T` / `asserts x[ is T]`: a plain guard returns boolean;
            // an assertion function returns void (no value required, so no
            // TS2355). The predicate rides along for call-site narrowing.
            const p = try c.predicateFromNode(proto.return_type, params.items);
            pred = p;
            ret = if (p.asserts) types.void_type else types.boolean_type;
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
                const payload = c.awaitedType(try c.inferReturnType(node, c.tree.nodeData(node).rhs));
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
            ret = try c.inferReturnType(node, c.tree.nodeData(node).rhs);
        } else if (proto.flags & (ast.Flags.get) != 0) {
            ret = types.any_type;
        } else if (c.tree.nodeData(node).rhs == 0 and c.nodeTag(node) != .function_type and c.nodeTag(node) != .method_signature) {
            ret = types.any_type; // overload signature without annotation
        }

        const sig = try c.ts.makeFunctionPred(params.items, ret, tps.items, if (is_method) types.fn_flag_method else 0, pred);
        try c.sig_cache.put(c.ca(), c.nodeKey(node), .{ .ty = sig, .ctx = ctx_sig });
        return sig;
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
            if (report_implicit and name != 0) {
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
    fn inferReturnType(c: *Checker, fn_node: Node, body: Node) Error!TypeId {
        if (body == 0) return types.any_type;
        if (c.nodeTag(body) != .block) {
            return c.widenLiteral(try c.checkExprCached(body, types.no_type));
        }
        var rets: std.ArrayList(Node) = .empty;
        defer rets.deinit(c.scratch());
        var bare_return = false;
        for (c.tree.nodeRange(body)) |stmt| {
            if (stmt != null_node) try c.collectReturns(stmt, &rets, &bare_return);
        }
        _ = fn_node;
        if (rets.items.len == 0) return types.void_type;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (rets.items) |r| {
            try parts.append(c.scratch(), try c.widenLiteral(try c.checkExprCached(r, types.no_type)));
        }
        if (bare_return or !c.stmtListTerminal(c.tree.nodeRange(body))) {
            try parts.append(c.scratch(), types.undefined_type);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }

    fn collectReturns(c: *Checker, node: Node, out: *std.ArrayList(Node), bare: *bool) Error!void {
        if (node == null_node) return;
        switch (c.nodeTag(node)) {
            .return_stmt => {
                const d = c.tree.nodeData(node);
                if (d.lhs != 0) try out.append(c.scratch(), d.lhs) else bare.* = true;
                return;
            },
            // Don't descend into nested functions/classes.
            .arrow_fn, .function_expr, .function_decl, .class_decl, .class_method => return,
            else => {},
        }
        var it = c.tree.childIterator(node);
        while (it.next()) |child| try c.collectReturns(child, out, bare);
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
                for (m.parts) |p| {
                    const pf = c.symFlags(p);
                    if (pf.function or pf.enum_decl or pf.class) {
                        ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.typeOfSymbol(p), ns_val });
                        break;
                    }
                }
                return ns_val;
            }
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
        if (f.var_decl or f.let_decl or f.const_decl) {
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
                const t = try c.declaratorType(sym, decl, f.const_decl);
                if (t != types.no_type) return t;
            }
            return types.any_type;
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
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        if (c.prog.links.len != 0) {
            const l = &c.prog.links[file];
            for (l.export_atoms, l.export_targets) |name, tgt| {
                if (tgt.type_only) continue;
                var ty: TypeId = types.any_type;
                switch (tgt.kind) {
                    .binding => {
                        const g = c.toGlobalIn(tgt.file, tgt.payload);
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
        const obj = try c.ts.makeObject(props.items, 0, 0, false);
        try c.ns_types.put(c.ca(), file, obj);
        return obj;
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
            if (tgt.type_only) continue;
            const ty = try c.targetValueType(tgt);
            try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
        }
        const obj = try c.ts.makeObject(props.items, 0, 0, false);
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
                    vt = try c.typeFromTypeNode(e.type_ann);
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
                            if (try c.findBindingType(ed.lhs, name, whole, out)) return true;
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
                    if (tag == .class_method and d.rhs != 0) return c.inferReturnType(decl, d.rhs);
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
                    if (e.type_ann != 0) return c.typeFromTypeNode(e.type_ann);
                    if (e.init != 0) return c.widenLiteral(try c.checkExprCached(e.init, types.no_type));
                    return types.any_type;
                },
                .property_signature => {
                    if (d.lhs != 0) return c.typeFromTypeNode(d.lhs);
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
        const state = c.alias_state.get(sym) orelse 0;
        if (state == 1) {
            // In-progress: recursive alias; leave a lazy ref.
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
        return c.instantiate(generic, map);
    }

    fn aliasGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
        if (c.alias_generic.get(sym)) |t| return t;
        try c.alias_state.put(c.ca(), sym, 1);
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
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
        var t = t0;
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
            const n = @min(tps.items.len, args.len);
            var map = try c.scratch().alloc(TpMap, tps.items.len);
            for (tps.items, 0..) |tp, i| {
                map[i] = .{ .sym = tp.sym, .ty = if (i < n) args[i] else types.any_type };
            }
            result = try c.instantiate(generic, map);
        }
        try c.expansions.put(c.ca(), ref, result);
        return result;
    }

    /// Generic (type-params-as-themselves) instance shape of an interface,
    /// with `extends` bases merged (derived members win).
    fn interfaceGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        if (c.iface_generic.get(sym)) |t| {
            if (t == types.no_type) {
                // Recursive base chain.
                const decls = c.declsOf(sym);
                if (decls.len > 0) {
                    const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decls[0]).lhs);
                    try c.diagFmt(2310, c.tokSpan(data.name_token), "Type '{s}' recursively references itself as a base type.", .{c.symbolName(sym)});
                }
                return types.error_type;
            }
            return t;
        }
        try c.iface_generic.put(c.ca(), sym, types.no_type);

        // Constituents: a within-file interface is one symbol carrying every
        // reopened block's decls; a cross-file merged interface (M11a) is a
        // list of per-file symbols. Each constituent's members must be
        // converted in *its own* file context (member type nodes resolve
        // against that file's scopes), so build one object type per
        // constituent and union them (earlier-file members win — disjoint in
        // the clean case; conflicting members are TS2717, deferred).
        var one = [_]SymbolId{sym};
        const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];

        var result: TypeId = types.no_type;
        for (parts) |csym| {
            if (!c.symFlags(csym).interface) continue;
            const own = try c.interfaceConstituentObject(csym);
            result = if (result == types.no_type) own else try c.mergeBaseObject(result, own);
        }
        if (result == types.no_type) result = types.empty_object_type;
        try c.iface_generic.put(c.ca(), sym, result);
        return result;
    }

    /// Object shape of a single interface symbol (one file): union of every
    /// reopened block's members plus `extends` bases. Runs entirely in the
    /// symbol's own file context.
    fn interfaceConstituentObject(c: *Checker, sym: SymbolId) Error!TypeId {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);

        var all_members: std.ArrayList(Node) = .empty;
        defer all_members.deinit(c.scratch());
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
        var own = try c.objectTypeFromMembers(all_members.items, false);
        for (bases.items) |base| {
            own = try c.mergeBaseObject(own, try c.resolveStructural(base));
        }
        return own;
    }

    /// Merge base-object members into `derived` (derived wins).
    fn mergeBaseObject(c: *Checker, derived: TypeId, base: TypeId) Error!TypeId {
        if (c.ts.kind(base) != .object or c.ts.kind(derived) != .object) return derived;
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        for (0..c.ts.objectPropCount(derived)) |i| {
            try props.append(c.scratch(), c.ts.objectProp(derived, @intCast(i)));
        }
        for (0..c.ts.objectPropCount(base)) |i| {
            const bp = c.ts.objectProp(base, @intCast(i));
            if (c.ts.objectPropByName(derived, bp.name) == null) {
                try props.append(c.scratch(), bp);
            }
        }
        const sidx = if (c.ts.objectStringIndex(derived) != 0) c.ts.objectStringIndex(derived) else c.ts.objectStringIndex(base);
        const nidx = if (c.ts.objectNumberIndex(derived) != 0) c.ts.objectNumberIndex(derived) else c.ts.objectNumberIndex(base);
        return c.ts.makeObject(props.items, sidx, nidx, false);
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
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        var result: TypeId = types.empty_object_type;
        if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                const msym = c.toGlobal(c.bind.member_syms[i]);
                const name = c.bind.member_atoms[i];
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
            result = try c.ts.makeObject(props.items, 0, 0, false);
        }
        // Merge base class instance.
        if (try c.baseClassRef(sym)) |base_ref| {
            result = try c.mergeBaseObject(result, try c.resolveStructural(base_ref));
        }
        try c.class_inst_generic.put(c.ca(), sym, result);
        return result;
    }

    fn isCtorName(c: *Checker, name: Atom) bool {
        return std.mem.eql(u8, c.atomText(name), "constructor");
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
            if (c.nodeTag(hd.lhs) != .identifier) return null;
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            const a = try c.atomOfToken(c.tree.nodeMainToken(hd.lhs));
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |base_sym0| {
                    var base_sym = base_sym0;
                    // Follow an imported base class to its declaration.
                    if (c.symFlags(base_sym).import_binding) {
                        const tgt = c.importTarget(base_sym) orelse return null;
                        if (tgt.kind != .binding) return null;
                        base_sym = c.toGlobalIn(tgt.file, tgt.payload);
                    }
                    if (!c.symFlags(base_sym).class) return null;
                    var targs: std.ArrayList(TypeId) = .empty;
                    defer targs.deinit(c.scratch());
                    if (hd.rhs != 0) {
                        const r = c.tree.extraData(ast.SubRange, hd.rhs);
                        for (c.tree.extraRange(r.start, r.end)) |an| {
                            if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                        }
                    }
                    const fixed = try c.fixTypeArgs(base_sym, targs.items, c.tree.nodeMainToken(hd.lhs)) orelse return null;
                    return try c.ts.makeRef(base_sym, fixed);
                },
                else => return null,
            }
        }
        return null;
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
                    for (lo..hi) |i| {
                        const name_atom = c.bind.member_atoms[i];
                        if (isCtorName(c, name_atom)) continue;
                        if (seen.contains(name_atom)) continue;
                        try seen.put(c.scratch(), name_atom, {});
                        const msym = c.toGlobal(c.bind.member_syms[i]);
                        if (c.memberIsAbstract(msym)) try unimpl.append(c.scratch(), name_atom);
                    }
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
            try c.diagFmt(2654, span, "Non-abstract class '{s}' is missing implementations for members of '{s}'.", .{
                class_name, base_name,
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
        const result = try c.ts.makeObject(props.items, 0, 0, false);
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
            const lo = c.bind.scope_members_start[ss];
            const hi = c.bind.scope_members_start[ss + 1];
            for (lo..hi) |i| {
                const msym = c.toGlobal(c.bind.member_syms[i]);
                const mf = c.symFlags(msym);
                var flags: u32 = 0;
                if (mf.readonly_member) flags |= types.prop_flag_readonly;
                if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
                try props.append(c.scratch(), .{
                    .name = c.bind.member_atoms[i],
                    .ty = try c.memberTypeOf(msym),
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
        const result = try c.ts.makeObject(props.items, 0, 0, false);
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
            const base = try c.baseClassRef(cur) orelse return;
            cur = c.ts.refSymbol(base);
        }
    }

    const TpMap = struct { sym: SymbolId, ty: TypeId };

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
                return false;
            },
            .function => {
                if (try c.containsTypeParam(s.fnReturn(t))) return true;
                for (0..s.fnParamCount(t)) |i| {
                    if (try c.containsTypeParam(s.fnParam(t, @intCast(i)).ty)) return true;
                }
                return false;
            },
            .ref => {
                for (s.refArgs(t)) |a| {
                    if (try c.containsTypeParam(a)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn tpLookup(map: []const TpMap, sym: SymbolId) ?TypeId {
        for (map) |m| {
            if (m.sym == sym) return m.ty;
        }
        return null;
    }

    fn instantiate(c: *Checker, t: TypeId, map: []const TpMap) Error!TypeId {
        if (map.len == 0) return t;
        if (!try c.containsTypeParam(t)) return t;
        if (c.inst_depth > max_instantiation_depth) return types.error_type;
        c.inst_depth += 1;
        defer c.inst_depth -= 1;
        const s = &c.ts;
        switch (s.kind(t)) {
            .type_param => return tpLookup(map, s.typeParamSymbol(t)) orelse t,
            .union_type => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiate(m, map));
                return s.makeUnion(c.scratch(), parts.items);
            },
            .intersection => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiate(m, map));
                return s.makeIntersection(c.scratch(), parts.items);
            },
            .overloads => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.instantiate(m, map));
                return s.makeOverloads(parts.items);
            },
            .array => return s.makeArray(try c.instantiate(s.arrayElem(t), map)),
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(t)) |i| {
                    const e = s.tupleElem(t, @intCast(i));
                    try elems.append(c.scratch(), .{ .ty = try c.instantiate(e.ty, map), .flags = e.flags });
                }
                return s.makeTuple(elems.items);
            },
            .object => {
                var props: std.ArrayList(types.Prop) = .empty;
                defer props.deinit(c.scratch());
                for (0..s.objectPropCount(t)) |i| {
                    const p = s.objectProp(t, @intCast(i));
                    try props.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiate(p.ty, map), .flags = p.flags });
                }
                const sidx = if (s.objectStringIndex(t) != 0) try c.instantiate(s.objectStringIndex(t), map) else 0;
                const nidx = if (s.objectNumberIndex(t) != 0) try c.instantiate(s.objectNumberIndex(t), map) else 0;
                return s.makeObject(props.items, sidx, nidx, s.objectFlags(t) & types.obj_flag_fresh != 0);
            },
            .function => {
                var params: std.ArrayList(types.Param) = .empty;
                defer params.deinit(c.scratch());
                // Inner type params shadowing the map are not filtered
                // (documented simplification; the subset has no
                // higher-order inference).
                for (0..s.fnParamCount(t)) |i| {
                    const p = s.fnParam(t, @intCast(i));
                    try params.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiate(p.ty, map), .flags = p.flags });
                }
                const ret = try c.instantiate(s.fnReturn(t), map);
                const tps = s.fnTypeParams(t);
                var kept: std.ArrayList(u32) = .empty;
                defer kept.deinit(c.scratch());
                for (tps) |tp| {
                    if (tpLookup(map, tp) == null) try kept.append(c.scratch(), tp);
                }
                return s.makeFunction(params.items, ret, kept.items, s.fnFlags(t));
            },
            .ref => {
                var args: std.ArrayList(TypeId) = .empty;
                defer args.deinit(c.scratch());
                for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.instantiate(a, map));
                return s.makeRef(s.refSymbol(t), args.items);
            },
            else => return t,
        }
    }

    // =====================================================================
    // properties & type parts
    // =====================================================================

    /// Property of a *structural* type (call resolveStructural first).
    /// Handles objects, intersections, arrays/tuples/strings (`length`),
    /// and type params (via constraint).
    fn propOfType(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
        const s = &c.ts;
        switch (s.kind(t)) {
            .object => {
                if (s.objectPropByName(t, name)) |p| return p;
                if (s.objectStringIndex(t) != 0) {
                    return .{ .name = name, .ty = s.objectStringIndex(t), .flags = 0 };
                }
                return null;
            },
            .intersection => {
                var found: ?types.Prop = null;
                for (try c.memberList(t)) |m| {
                    const r = try c.resolveStructural(m);
                    if (try c.propOfType(r, name)) |p| {
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
                    return .{ .name = name, .ty = types.number_type, .flags = types.prop_flag_readonly };
                }
                return c.primitiveInterfaceProp(t, name);
            },
            .number, .number_literal, .number_literal_fresh, .boolean, .bool_true, .bool_false => {
                return c.primitiveInterfaceProp(t, name);
            },
            .type_param => {
                const constraint = try c.typeParamConstraint(s.typeParamSymbol(t));
                if (constraint == types.no_type) return null;
                return c.propOfType(try c.resolveStructural(constraint), name);
            },
            .ref => return c.propOfType(try c.resolveStructural(t), name),
            .class_value => return c.propOfType(try c.classStaticType(s.classSymbol(t)), name),
            .enum_type => {
                // A value of enum type borrows its base primitive's members.
                const info = try c.enumInfo(s.enumSymbol(t));
                const base: TypeId = if (info.all_string) types.string_type else types.number_type;
                return c.propOfType(base, name);
            },
            else => return null,
        }
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

    /// Single-level `Awaited<T>`: unwrap a `Promise<T>` to `T`; any other type
    /// passes through (await on a non-thenable yields the value itself).
    /// Deeper `Awaited<T>` recursion (`Promise<Promise<T>>`) is a known gap.
    fn awaitedType(c: *Checker, t: TypeId) TypeId {
        if (c.ts.kind(t) == .ref) {
            const sym = c.prog.globals.lookup(c.atom_Promise) orelse return t;
            if (c.ts.refSymbol(t) == sym) {
                const args = c.ts.refArgs(t);
                if (args.len >= 1) return args[0];
            }
        }
        return t;
    }

    /// If `t` is a `Generator<T>`/`Iterator<T>`/`IterableIterator<T>` ref,
    /// return its yield element `T`; otherwise 0.
    fn generatorYieldType(c: *Checker, t: TypeId) TypeId {
        if (c.ts.kind(t) != .ref) return 0;
        const sym = c.ts.refSymbol(t);
        const g = c.prog.globals.lookup(c.atom_Generator);
        const it = c.prog.globals.lookup(c.atom_Iterator);
        const ii = c.prog.globals.lookup(c.atom_IterableIterator);
        if ((g != null and sym == g.?) or (it != null and sym == it.?) or (ii != null and sym == ii.?)) {
            const args = c.ts.refArgs(t);
            if (args.len >= 1) return args[0];
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

    fn typeParamConstraint(c: *Checker, sym: SymbolId) Error!TypeId {
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
        return c.isComparable(a, b);
    }

    fn isAssignable(c: *Checker, s0: TypeId, t0: TypeId) Error!bool {
        var s = try c.ts.regularLiteral(s0);
        var t = try c.ts.regularLiteral(t0);
        s = try c.ts.regular(s);
        t = try c.ts.regular(t);
        if (s == t) return true;
        const sk = c.ts.kind(s);
        const tk = c.ts.kind(t);
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
            .union_type, .intersection, .array, .tuple, .object, .function, .overloads, .ref, .class_value => true,
            else => false,
        };
    }

    fn isAssignableInner(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
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
        // {} accepts anything non-nullish.
        if (n == 0 and sidx == 0 and nidx == 0) {
            const k = c.ts.kind(s);
            return k != .null and k != .undefined and k != .void;
        }
        for (0..n) |i| {
            const tp = c.ts.objectProp(t, @intCast(i));
            const sp = (try c.propOfType(s, tp.name)) orelse {
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
        if (sidx != 0) {
            switch (c.ts.kind(s)) {
                .object => {
                    for (0..c.ts.objectPropCount(s)) |i| {
                        const sp = c.ts.objectProp(s, @intCast(i));
                        if (!try c.isAssignable(sp.ty, sidx)) return false;
                    }
                    if (c.ts.objectStringIndex(s) != 0 and !try c.isAssignable(c.ts.objectStringIndex(s), sidx)) return false;
                },
                else => {},
            }
        }
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
                .object => {
                    if (c.ts.objectNumberIndex(s) != 0 and !try c.isAssignable(c.ts.objectNumberIndex(s), nidx)) return false;
                },
                else => {},
            }
        }
        return true;
    }

    /// strictFunctionTypes: contravariant params for function types,
    /// bivariant for methods; covariant returns; `void` target returns
    /// accept anything.
    fn signatureAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
        const bivariant = (c.ts.fnFlags(s) & types.fn_flag_method != 0) or
            (c.ts.fnFlags(t) & types.fn_flag_method != 0);
        // Erase generics to their constraints (documented simplification).
        const se = try c.eraseTypeParams(s);
        const te = try c.eraseTypeParams(t);
        if (c.requiredParams(se) > c.paramTotal(te)) return false;
        const s_count = c.ts.fnParamCount(se);
        const t_count = c.ts.fnParamCount(te);
        const pairs = @min(c.paramTotal(se), @max(s_count, t_count));
        var i: u32 = 0;
        while (i < pairs) : (i += 1) {
            const sp = c.paramTypeAt(se, i) orelse break;
            const tp = c.paramTypeAt(te, i) orelse break;
            const contra = try c.isAssignable(tp, sp);
            if (!contra) {
                if (!bivariant) return false;
                if (!try c.isAssignable(sp, tp)) return false;
            }
        }
        const t_ret = c.ts.fnReturn(te);
        if (t_ret == types.void_type) return true;
        const s_ret = c.ts.fnReturn(se);
        if (s_ret == types.void_type) return t_ret == types.void_type or t_ret == types.any_type or t_ret == types.unknown_type;
        return c.isAssignable(s_ret, t_ret);
    }

    fn eraseTypeParams(c: *Checker, sig: TypeId) Error!TypeId {
        const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        if (tps.len == 0) return sig;
        var map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| {
            const constraint = try c.typeParamConstraint(tp);
            map[i] = .{ .sym = tp, .ty = if (constraint != types.no_type) constraint else types.any_type };
        }
        return c.instantiate(sig, map);
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

    fn requiredParams(c: *Checker, sig: TypeId) u32 {
        var n: u32 = 0;
        for (0..c.ts.fnParamCount(sig)) |i| {
            const p = c.ts.fnParam(sig, @intCast(i));
            if (p.optional() or p.rest()) break;
            n += 1;
        }
        return n;
    }

    // =====================================================================
    // diagnostic-emitting assignment check (2322 / 2739 / 2741 / 2353)
    // =====================================================================

    /// Check `source` (the type of `expr_node`, which may be 0) against
    /// `target`, reporting at `span`. Returns true when assignable.
    fn checkAssignable(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
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
                        try c.reportNotAssignable(2322, vt, tp.ty, c.nodeSpan(value_node));
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
        if (c.requiredParams(s) > c.paramTotal(t)) return false;
        const pairs = @min(c.paramTotal(s), @max(c.ts.fnParamCount(s), c.ts.fnParamCount(t)));
        var i: u32 = 0;
        while (i < pairs) : (i += 1) {
            const sp = c.paramTypeAt(s, i) orelse break;
            const tp = c.paramTypeAt(t, i) orelse break;
            if (!try c.isAssignable(tp, sp) and !try c.isAssignable(sp, tp)) return false;
        }
        return true;
    }

    fn reportNotAssignable(c: *Checker, code: u16, src_t: TypeId, target: TypeId, span: Span) Error!void {
        // Missing-property refinement (tsc: 2739 / 2741 instead of 2322).
        if (code == 2322) {
            const rs = try c.resolveStructural(src_t);
            const rt = try c.resolveStructural(target);
            if (isSourceObjecty(c.ts.kind(rs)) and c.ts.kind(rt) == .object) {
                var missing: std.ArrayList(Atom) = .empty;
                defer missing.deinit(c.scratch());
                for (0..c.ts.objectPropCount(rt)) |i| {
                    const tp = c.ts.objectProp(rt, @intCast(i));
                    if (tp.optional()) continue;
                    if ((try c.propOfType(rs, tp.name)) == null) {
                        try missing.append(c.scratch(), tp.name);
                    }
                }
                if (missing.items.len == 1) {
                    try c.diagFmt(2741, span, "Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{
                        c.atomText(missing.items[0]), try c.typeToString(src_t), try c.typeToString(target),
                    });
                    return;
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
                    return;
                }
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

    fn isSourceObjecty(k: types.Kind) bool {
        return k == .object or k == .intersection;
    }

    /// tsc's excess property check: only *fresh* object literals, checked
    /// against object-ish targets; recurses into nested literal properties.
    fn excessPropertyCheck(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!void {
        var node = expr_node;
        while (c.nodeTag(node) == .paren_expr) node = c.tree.nodeData(node).lhs;
        if (c.nodeTag(node) != .object_literal) return;
        if (!c.ts.objectIsFresh(src_t)) return;
        const rt = try c.resolveStructural(target);
        switch (c.ts.kind(rt)) {
            .object => {
                if (c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0) return;
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
            .call_expr, .call_expr_targs, .optional_call => return c.checkCallExpr(node, false),
            .new_expr, .new_expr_targs, .new_expr_bare => return c.checkCallExpr(node, true),
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
                if (!try c.isComparable(try c.widenLiteral(et), tt)) {
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
                const delegate = d.rhs != 0;
                if (d.lhs != 0) {
                    const vt = try c.checkExprCached(d.lhs, if (delegate) types.no_type else yt);
                    if (!delegate and yt != 0 and yt != types.no_type and yt != types.error_type and c.ts.kind(yt) != .any) {
                        _ = try c.checkAssignable(vt, yt, d.lhs, c.nodeSpan(d.lhs));
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
            const tag_ty = try c.checkExprCached(e.tag, types.no_type);
            props = (try c.jsxComponentProps(tag_ty)) orelse types.no_type;
        }
        try c.checkJsxAttributes(node, e, props);
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
        return try c.namedTypeFromSymbol(g, &.{}, 0);
    }

    /// Props type of a component tag: the first parameter of its call
    /// signature (function components). Null when it has no discernible props.
    fn jsxComponentProps(c: *Checker, tag_ty: TypeId) Error!?TypeId {
        const t = try c.resolveStructural(tag_ty);
        const sig = switch (c.ts.kind(t)) {
            .function => t,
            .overloads => blk: {
                const sigs = try c.memberList(t);
                break :blk if (sigs.len > 0) sigs[0] else return null;
            },
            else => return null,
        };
        if (c.ts.fnParamCount(sig) == 0) return types.empty_object_type;
        return c.ts.fnParam(sig, 0).ty;
    }

    /// Check a JSX element's attributes against its props type (`no_type` =
    /// unknown target, only value expressions are checked). Mirrors tsc's
    /// "attributes object assigned to props" model: per-attribute value
    /// mismatches report at the value; excess/missing report the whole object.
    fn checkJsxAttributes(c: *Checker, node: Node, e: ast.JsxElementData, props: TypeId) Error!void {
        const attrs = c.tree.extraRange(e.attrs_start, e.attrs_end);
        var built: std.ArrayList(types.Prop) = .empty;
        defer built.deinit(c.scratch());
        var has_spread = false;
        const rt: TypeId = if (props != types.no_type) try c.resolveStructural(props) else types.no_type;
        const target_open = rt != types.no_type and c.ts.kind(rt) == .object and c.ts.objectStringIndex(rt) == 0;
        var first_excess: Span = .{ .start = 0, .end = 0 };
        var have_excess = false;

        for (attrs) |attr| {
            if (c.nodeTag(attr) == .jsx_spread_attribute) {
                has_spread = true;
                const sd = c.tree.nodeData(attr);
                if (sd.lhs != null_node) _ = try c.checkExprCached(sd.lhs, types.no_type);
                continue;
            }
            const ad = c.tree.nodeData(attr);
            const name_tok = c.tree.nodeMainToken(attr);
            const name = try c.memberAtom(name_tok);
            const vty = try c.jsxAttributeValueType(ad.lhs);
            try built.append(c.scratch(), .{ .name = name, .ty = vty });
            if (rt == types.no_type) continue;
            if (try c.propOfType(rt, name)) |p| {
                const vspan = if (ad.lhs != null_node) c.nodeSpan(ad.lhs) else c.tokSpan(name_tok);
                _ = try c.checkAssignable(vty, p.ty, ad.lhs, vspan);
            } else if (target_open) {
                if (!have_excess) {
                    first_excess = c.tokSpan(name_tok);
                    have_excess = true;
                }
            }
        }
        if (rt == types.no_type or has_spread) return;
        const attrs_obj = try c.ts.makeObject(built.items, 0, 0, true);
        if (have_excess) {
            try c.reportNotAssignable(2322, attrs_obj, props, first_excess);
            return;
        }
        // Missing required props → TS2741/2739 at the tag (or `<`) position.
        for (0..c.ts.objectPropCount(rt)) |i| {
            const tp = c.ts.objectProp(rt, @intCast(i));
            if (tp.optional()) continue;
            if ((try c.propOfType(attrs_obj, tp.name)) == null) {
                const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
                try c.reportNotAssignable(2322, attrs_obj, props, span);
                return;
            }
        }
    }

    /// Widened type of a JSX attribute value: `name` → `true`, `name="s"` →
    /// `string`, `name={e}` → widened type of `e`, `name=<x/>` → JSX.Element.
    fn jsxAttributeValueType(c: *Checker, value: Node) Error!TypeId {
        if (value == null_node) return types.boolean_type; // boolean shorthand
        switch (c.nodeTag(value)) {
            .string_literal => return types.string_type,
            .jsx_expr_container => {
                const cd = c.tree.nodeData(value);
                if (cd.lhs == null_node) return types.undefined_type;
                return c.widenLiteral(try c.checkExprCached(cd.lhs, types.no_type));
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
        const ctx_tuple = rctx != types.no_type and c.ts.kind(rctx) == .tuple;
        const ctx_elem: TypeId = if (rctx != types.no_type and c.ts.kind(rctx) == .array)
            c.ts.arrayElem(rctx)
        else
            types.no_type;

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
                ectx = c.tupleElemTypeAt(rctx, i) orelse types.no_type;
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
            .type_param => {
                const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
                if (constraint == types.no_type) return false;
                return c.contextAdmitsLiteral(constraint, lit);
            },
            else => return false,
        }
    }

    fn checkObjectLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        const rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
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

        for (c.tree.nodeRange(node)) |prop| {
            if (prop == null_node) continue;
            const pd = c.tree.nodeData(prop);
            switch (c.nodeTag(prop)) {
                .object_property => {
                    if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                        _ = try c.checkExprCached(c.tree.nodeData(pd.lhs).lhs, types.no_type);
                        _ = try c.checkExprCached(pd.rhs, types.no_type);
                        continue; // computed names: no static member
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
                    if (c.ts.kind(st) == .object) {
                        for (0..c.ts.objectPropCount(st)) |i| {
                            const p = c.ts.objectProp(st, @intCast(i));
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = p.name, .ty = p.ty, .flags = p.flags & types.prop_flag_optional });
                        }
                    }
                },
                else => _ = try c.checkExprCached(prop, types.no_type),
            }
        }
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
        return c.ts.makeObject(props.items, 0, 0, true);
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
                    const rm = try c.resolveStructural(m);
                    if (try c.propOfType(rm, key)) |p| try parts.append(c.scratch(), p.ty);
                }
                if (parts.items.len == 0) return types.no_type;
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            else => {
                if (try c.propOfType(rctx, key)) |p| return p.ty;
                return types.no_type;
            },
        }
    }

    fn checkMemberExpr(c: *Checker, node: Node) Error!TypeId {
        const d = c.tree.nodeData(node);
        const optional = c.nodeTag(node) == .optional_member_expr;
        var obj_t = try c.checkExprCached(d.lhs, types.no_type);
        // Flow narrowing may apply to the property path itself (x.y as a
        // discriminated reference) — out of subset; the root is narrowed.
        const name_tok: TokenIndex = d.rhs;
        const name = try c.memberAtom(name_tok);
        var add_undefined = false;
        if (optional) {
            if (c.containsNullish(obj_t) or c.ts.kind(obj_t) == .null or c.ts.kind(obj_t) == .undefined) {
                add_undefined = true;
            }
            obj_t = try c.nonNullable(obj_t);
        } else {
            obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
        }
        var pt = try c.propertyTypeOf(obj_t, name, name_tok);
        // Property-path narrowing: `x.p` where x is an identifier.
        if (c.nodeTag(d.lhs) == .identifier) {
            const base_tok = c.tree.nodeMainToken(d.lhs);
            if (c.tree.tokens.tag(base_tok) != .keyword_undefined) {
                const a = try c.atomOfToken(base_tok);
                switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| pt = try c.flowTypeOfProp(node, sym, name, pt),
                    else => {},
                }
            }
        }
        if (add_undefined) return c.makeUnion2(pt, types.undefined_type);
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
        if (c.entityNameOf(obj_node)) |name| {
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
            .member_expr => {
                const d = c.tree.nodeData(node);
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
                    var pt = p.ty;
                    if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                    try parts.append(c.scratch(), pt);
                }
                return c.ts.makeUnion(c.scratch(), parts.items);
            },
            else => {
                const r = try c.resolveStructural(t);
                if (c.ts.kind(r) == .any or c.ts.kind(r) == .err) return types.any_type;
                if (try c.propOfType(r, name)) |p| {
                    var pt = p.ty;
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
        const d = c.tree.nodeData(node);
        const optional = c.nodeTag(node) == .optional_index_expr;
        var obj_t = try c.checkExprCached(d.lhs, types.no_type);
        const idx_t = try c.checkExprCached(d.rhs, types.no_type);
        var add_undefined = false;
        if (optional) {
            if (c.containsNullish(obj_t)) add_undefined = true;
            obj_t = try c.nonNullable(obj_t);
        } else {
            obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
        }
        const r = try c.resolveStructural(obj_t);
        const rk = c.ts.kind(r);
        if (rk == .any or rk == .err) return types.any_type;
        var result: TypeId = types.any_type;
        const ik = c.ts.kind(try c.ts.regularLiteral(idx_t));
        switch (ik) {
            .string_literal => {
                const key = c.ts.literalAtom(try c.ts.regularLiteral(idx_t));
                if (try c.propOfType(r, key)) |p| {
                    result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                } else if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                    result = c.ts.objectStringIndex(r);
                } else {
                    try c.diagFmt(2339, c.nodeSpan(d.rhs), "Property '{s}' does not exist on type '{s}'.", .{
                        c.atomText(key), try c.typeToString(obj_t),
                    });
                    result = types.error_type;
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
        if (add_undefined) return c.makeUnion2(result, types.undefined_type);
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
                return c.awaitedType(ot);
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

    fn checkBinary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
        const d = c.tree.nodeData(node);
        const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
        switch (op) {
            .amp_amp => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                const falsy = try c.getFalsyPart(lt, false);
                return c.makeUnion2(falsy, rt);
            },
            .pipe_pipe => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                const truthy = try c.getTruthyPart(lt);
                return c.makeUnion2(truthy, rt);
            },
            .question_question => {
                const lt = try c.checkExprCached(d.lhs, types.no_type);
                const rt = try c.checkExprCached(d.rhs, ctx);
                return c.makeUnion2(try c.nonNullable(lt), rt);
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
                const ok = (c.isNumberish(lt) and c.isNumberish(rt)) or
                    (c.isStringish(lt) and c.isStringish(rt)) or
                    (c.isBigintish(lt) and c.isBigintish(rt)) or
                    c.ts.kind(lt) == .any or c.ts.kind(rt) == .any or
                    c.ts.kind(lt) == .err or c.ts.kind(rt) == .err;
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
                const rk = c.ts.kind(rt);
                if (rk != .class_value and rk != .any and rk != .err and rk != .function and rk != .overloads) {
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
                    if (p.readonly()) {
                        try c.diagFmt(2540, c.tokSpan(d.rhs), "Cannot assign to '{s}' because it is a read-only property.", .{c.atomText(name)});
                        return types.error_type; // suppress cascading 2322
                    }
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

    fn checkCallExpr(c: *Checker, node: Node, is_new: bool) Error!TypeId {
        const shape = c.callShape(node);
        var callee_t = try c.checkExprCached(shape.callee, types.no_type);
        var add_undefined = false;
        if (shape.optional) {
            if (c.containsNullish(callee_t)) add_undefined = true;
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
                const usable = if (is_new) mk == .class_value else (mk == .function or mk == .overloads);
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
                        try c.inferTypeArgs(ctor, tp_syms, shape.arg_nodes, inst_args, tps.items);
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
            } else if (rk == .function or rk == .overloads) {
                try c.diagFmt(2351, c.nodeSpan(shape.callee), "This expression is not constructable.", .{});
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return types.error_type;
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
                else => {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.error_type;
                },
            }
        }

        const result = try c.resolveSignatureCall(node, sigs.items, targs.items, shape.arg_nodes, instance_ret);
        if (add_undefined) return c.makeUnion2(result, types.undefined_type);
        return result;
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
    ) Error!TypeId {
        if (sigs.len == 0) return types.any_type;
        const nargs = countArgs(arg_nodes);
        if (sigs.len == 1) {
            const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node);
            try c.checkCallArguments(node, inst, arg_nodes, true);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
        }
        // Overloads: first signature whose arity fits and whose args check.
        for (sigs) |sig| {
            const inst = try c.instantiateSigForCall(sig, explicit_targs, arg_nodes, node);
            if (nargs < c.requiredParams(inst) or nargs > c.paramTotal(inst)) continue;
            if (try c.argumentsMatch(inst, arg_nodes)) {
                try c.checkCallArguments(node, inst, arg_nodes, true);
                return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
            }
        }
        try c.diagFmt(2769, c.nodeSpan(c.callShape(node).callee), "No overload matches this call.", .{});
        // Continue with the first signature for downstream typing.
        const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node);
        for (arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
    }

    /// Instantiate a (possibly generic) signature for a call: explicit
    /// type args win; otherwise unify parameters against arguments
    /// (two-phase: plain args first, then context-sensitive function args).
    fn instantiateSigForCall(c: *Checker, sig: TypeId, explicit_targs: []const TypeId, arg_nodes: []const Node, node: Node) Error!TypeId {
        c.infer_fell_back = false;
        const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        if (tps.len == 0) return sig;
        var args_buf = try c.scratch().alloc(TypeId, tps.len);
        if (explicit_targs.len > 0) {
            if (explicit_targs.len != tps.len) {
                try c.diagFmt(2558, c.nodeSpan(node), "Expected {d} type arguments, but got {d}.", .{ tps.len, explicit_targs.len });
            }
            for (tps, 0..) |tp, i| {
                args_buf[i] = if (i < explicit_targs.len) explicit_targs[i] else types.any_type;
                _ = tp;
            }
        } else {
            var infos = try c.scratch().alloc(TypeParamInfo, tps.len);
            for (tps, 0..) |tp, i| infos[i] = .{ .sym = tp, .constraint = 0, .default = 0 };
            try c.inferTypeArgs(sig, tps, arg_nodes, args_buf, infos);
        }
        var map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
        return c.instantiate(sig, map);
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
        infos: []const TypeParamInfo,
    ) Error!void {
        const candidates = try c.scratch().alloc(TypeId, tp_syms.len);
        for (candidates) |*x| x.* = types.no_type;

        // Phase 1: non-function arguments.
        var ai: u32 = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            const tag = c.nodeTag(an);
            if (tag == .arrow_fn or tag == .function_expr) continue;
            const pt = c.paramTypeAt(sig, ai) orelse continue;
            const at = try c.checkExprCached(an, types.no_type);
            try c.unify(pt, at, tp_syms, candidates, 0);
        }
        // Phase 2: function arguments, contextually typed by the partial
        // instantiation.
        var partial = try c.scratch().alloc(TpMap, tp_syms.len);
        for (tp_syms, 0..) |tp, i| {
            partial[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
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
        for (tp_syms, 0..) |tp, i| {
            var constraint: TypeId = types.no_type;
            if (i < infos.len and infos[i].constraint != 0) {
                constraint = try c.typeFromTypeNode(infos[i].constraint);
            } else {
                constraint = try c.typeParamConstraint(tp);
            }
            if (candidates[i] != types.no_type) {
                out[i] = candidates[i];
                // Candidate violating the constraint falls back to the
                // constraint (tsc then re-checks args against it).
                if (constraint != types.no_type and !try c.isAssignable(candidates[i], constraint)) {
                    out[i] = constraint;
                    c.infer_fell_back = true;
                }
                continue;
            }
            out[i] = if (constraint != types.no_type) constraint else types.unknown_type;
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
                    else => {},
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
                for (try c.memberList(param)) |m| {
                    if (s.kind(m) == .type_param and tpIndex(tp_syms, s.typeParamSymbol(m)) != null) {
                        tp_member = m;
                        n_tp += 1;
                    } else if (try c.containsTypeParam(m)) {
                        try c.unify(m, arg, tp_syms, candidates, depth + 1);
                    }
                }
                if (n_tp == 1) {
                    var rest_ok = false;
                    for (try c.memberList(param)) |m| {
                        if (m == tp_member) continue;
                        if (try c.isAssignable(arg, m)) rest_ok = true;
                    }
                    if (!rest_ok) try c.unify(tp_member, arg, tp_syms, candidates, depth + 1);
                }
            },
            .object => {
                const ra = try c.resolveStructural(arg);
                if (s.kind(ra) != .object) return;
                for (0..s.objectPropCount(param)) |i| {
                    const pp = s.objectProp(param, @intCast(i));
                    if (s.objectPropByName(ra, pp.name)) |ap| {
                        try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                    }
                }
                if (s.objectStringIndex(param) != 0 and s.objectStringIndex(ra) != 0) {
                    try c.unify(s.objectStringIndex(param), s.objectStringIndex(ra), tp_syms, candidates, depth + 1);
                }
            },
            .function => {
                const ra = try c.resolveStructural(arg);
                if (s.kind(ra) != .function) return;
                const n = @min(s.fnParamCount(param), s.fnParamCount(ra));
                for (0..n) |i| {
                    try c.unify(s.fnParam(param, @intCast(i)).ty, s.fnParam(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
                try c.unify(s.fnReturn(param), s.fnReturn(ra), tp_syms, candidates, depth + 1);
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
                try c.unify(try c.resolveStructural(param), ra, tp_syms, candidates, depth + 1);
            },
            else => {},
        }
    }

    /// Would every argument check against `sig`? (Silent, for overload
    /// selection.)
    fn argumentsMatch(c: *Checker, sig: TypeId, arg_nodes: []const Node) Error!bool {
        var ai: u32 = 0;
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            defer ai += 1;
            if (c.nodeTag(an) == .spread_element) return true; // don't reject on spreads
            const pt = c.paramTypeAt(sig, ai) orelse return false;
            const tag = c.nodeTag(an);
            const at = if (tag == .arrow_fn or tag == .function_expr)
                try c.checkExprCached(an, pt)
            else
                try c.checkExprCached(an, types.no_type);
            if (!try c.isAssignable(at, pt)) return false;
        }
        return true;
    }

    fn checkCallArguments(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool) Error!void {
        const nargs = countArgs(arg_nodes);
        const required = c.requiredParams(sig);
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

    /// A narrowable reference: an identifier (`prop == 0`) or a
    /// single-level property path `sym.prop`.
    const RefKey = struct { sym: SymbolId, prop: Atom };

    const FlowQ = struct { file: FileId, flow: FlowId, key: u32, declared: TypeId };

    fn refKeyIndex(c: *Checker, key: RefKey) Error!u32 {
        const raw = (@as(u64, key.sym) << 32) | key.prop;
        const gop = try c.ref_keys.getOrPut(c.ca(), raw);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(c.ref_keys.count());
        return gop.value_ptr.*;
    }

    /// Does `node` denote exactly this reference?
    fn refMatches(c: *Checker, node: Node, key: RefKey) Error!bool {
        if (node == null_node) return false;
        var n = node;
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        if (key.prop == 0) return c.identIsSym(n, key.sym);
        const tag = c.nodeTag(n);
        if (tag != .member_expr and tag != .optional_member_expr) return false;
        const d = c.tree.nodeData(n);
        if (!try c.identIsSym(d.lhs, key.sym)) return false;
        return (try c.memberAtom(d.rhs)) == key.prop;
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
        return c.flowType(flow, .{ .sym = sym, .prop = 0 }, declared, 0);
    }

    fn flowTypeOfProp(c: *Checker, node: Node, sym: SymbolId, prop: Atom, declared: TypeId) Error!TypeId {
        if (!c.isNarrowable(declared)) return declared;
        const flow = c.bind.flowAt(node) orelse return declared;
        c.stats.flow_queries += 1;
        return c.flowType(flow, .{ .sym = sym, .prop = prop }, declared, 0);
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
            .none, .start => return declared,
            .unreachable_ => return types.never_type,
            .assign => {
                const target = b.flowNode(flow);
                const ante = b.flow_a[flow];
                if (try c.assignNarrows(target, key, declared)) |narrowed| {
                    return narrowed;
                }
                return c.flowType(ante, key, declared, depth + 1);
            },
            .cond_true, .cond_false => {
                const cond = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                const sense = b.flow_tags[flow] == .cond_true;
                return c.narrowByCondition(before, cond, sense, key);
            },
            .switch_clause => {
                const clause = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                return c.narrowBySwitchClause(before, clause, key);
            },
            .call_stmt => {
                const call = b.flowNode(flow);
                const ante = b.flow_a[flow];
                const before = try c.flowType(ante, key, declared, depth + 1);
                if (before == types.never_type) return before;
                return c.narrowByAssertCall(before, call, key);
            },
            .branch_label, .loop_label => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (b.flowAntecedents(flow)) |a| {
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
                if (key.prop != 0) return declared; // root re-init: reset path
                if (c.nodeTag(d.lhs) != .identifier) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                return try c.assignmentReduced(declared, vt);
            },
            .declarator_full => {
                const d = c.tree.nodeData(target);
                if (!try c.patternBindsSym(d.lhs, root_sym)) return null;
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (key.prop != 0) return declared;
                if (e.init == 0) return declared;
                if (c.nodeTag(d.lhs) != .identifier) return declared;
                const vt = c.nodeType(e.init) orelse try c.checkExprCached(e.init, types.no_type);
                return try c.assignmentReduced(declared, vt);
            },
            .assign => {
                const d = c.tree.nodeData(target);
                // Full path write: x.p = v narrows key (x, p).
                if (key.prop != 0 and try c.refMatches(d.lhs, key)) {
                    const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                    if (op != .eq) return declared;
                    const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                    return try c.assignmentReduced(declared, vt);
                }
                if (c.nodeTag(d.lhs) == .identifier) {
                    if (!try c.identIsSym(d.lhs, root_sym)) return null;
                    if (key.prop != 0) return declared; // root overwritten
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
                if (key.prop != 0 and try c.identIsSym(d.lhs, root_sym)) return declared;
                return null;
            },
            // for-of / for-in left (var decl or expression).
            .var_decl_one, .var_decl => {
                if (try c.varDeclBindsSym(target, root_sym)) {
                    if (key.prop != 0) return declared;
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
    fn narrowByCondition(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey) Error!TypeId {
        if (cond == null_node) return t;
        const d = c.tree.nodeData(cond);
        switch (c.nodeTag(cond)) {
            .paren_expr => return c.narrowByCondition(t, d.lhs, sense, key),
            .non_null => return c.narrowByCondition(t, d.lhs, sense, key),
            .identifier => {
                if (!try c.refMatches(cond, key)) return t;
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            },
            .member_expr, .optional_member_expr => {
                // The path itself is the condition.
                if (try c.refMatches(cond, key)) {
                    return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
                }
                // `if (x.p)` — discriminate the root by prop truthiness.
                if (key.prop != 0) return t;
                if (!try c.identIsSym(d.lhs, key.sym)) return t;
                var base = t;
                if (c.nodeTag(cond) == .optional_member_expr and sense) {
                    base = try c.nonNullable(base);
                }
                const prop = try c.memberAtom(d.rhs);
                return c.narrowByPropTruthiness(base, prop, sense);
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
                        if (c.ts.kind(rt) != .class_value) return t;
                        const cls = c.ts.classSymbol(rt);
                        var tps: std.ArrayList(TypeParamInfo) = .empty;
                        defer tps.deinit(c.scratch());
                        try c.typeParamsOf(cls, &tps);
                        const args = try c.scratch().alloc(TypeId, tps.items.len);
                        for (args) |*x| x.* = types.any_type;
                        const inst = try c.ts.makeRef(cls, args);
                        return c.narrowByInstance(t, inst, sense);
                    },
                    else => return t,
                }
            },
            .prefix_unary => return t, // `!` was decomposed by the binder
            .call_expr, .call_expr_targs, .optional_call => return c.narrowByGuardCall(t, cond, sense, key),
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
        // <ref> === <literal> / <literal> === <ref>
        if (try c.refMatches(lhs, key)) {
            return c.narrowByLiteralEquality(t, rhs, strict, sense);
        }
        if (try c.refMatches(rhs, key)) {
            return c.narrowByLiteralEquality(t, lhs, strict, sense);
        }
        // x.k === <literal> narrows x (discriminant).
        if (key.prop == 0) {
            if (c.discriminantOf(lhs, key.sym)) |prop_tok| {
                const other = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
                return c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense);
            }
            if (c.discriminantOf(rhs, key.sym)) |prop_tok| {
                const other = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
                return c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense);
            }
        }
        return t;
    }

    fn typeofTargetOf(c: *Checker, node: Node, key: RefKey) Error!bool {
        if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
        if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
        return c.refMatches(c.tree.nodeData(node).lhs, key);
    }

    fn discriminantOf(c: *Checker, node: Node, sym: SymbolId) ?TokenIndex {
        if (node == null_node) return null;
        if (c.nodeTag(node) != .member_expr and c.nodeTag(node) != .optional_member_expr) return null;
        const d = c.tree.nodeData(node);
        const is_sym = c.identIsSym(d.lhs, sym) catch return null;
        if (!is_sym) return null;
        return d.rhs;
    }

    fn identIsSym(c: *Checker, node: Node, sym: SymbolId) Error!bool {
        if (node == null_node or c.nodeTag(node) != .identifier) return false;
        const a = try c.atomOfToken(c.tree.nodeMainToken(node));
        if (a != c.symNameAtom(sym)) return false;
        return switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |s| s == sym,
            else => false,
        };
    }

    fn patternBindsSym(c: *Checker, pat: Node, sym: SymbolId) Error!bool {
        if (pat == null_node) return false;
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

    fn narrowByTypeof(c: *Checker, t: TypeId, str: Atom, sense: bool) Error!TypeId {
        var which: usize = typeof_names.len;
        for (c.typeof_atoms, 0..) |a, i| {
            if (a == str) which = i;
        }
        if (which == typeof_names.len) return t;
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
        const callee_t = try c.checkExprCached(shape.callee, types.no_type);
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
            return t;
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
        } else if (key.prop == 0) {
            if (c.discriminantOf(disc, key.sym)) |prop_tok| {
                prop = try c.memberAtom(prop_tok);
            }
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
        const d = c.tree.nodeData(node);
        switch (c.nodeTag(node)) {
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
        if (c.nodeTag(node) == .var_decl_one) {
            try c.checkDeclarator(d.lhs);
        } else {
            for (c.tree.nodeRange(node)) |decl| {
                if (decl != null_node) try c.checkDeclarator(decl);
            }
        }
    }

    fn checkDeclarator(c: *Checker, decl: Node) Error!void {
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
                const ann: TypeId = if (e.type_ann != 0) try c.typeFromTypeNode(e.type_ann) else types.no_type;
                if (e.init != 0) {
                    const it = try c.checkExprCached(e.init, ann);
                    if (ann != types.no_type and ann != types.error_type) {
                        const span = if (c.nodeTag(d.lhs) == .identifier)
                            c.tokSpan(c.tree.nodeMainToken(d.lhs))
                        else
                            c.nodeSpan(d.lhs);
                        _ = try c.checkAssignable(it, ann, e.init, span);
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
            elem_t = try c.forOfElementType(rt, e.right);
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
    fn forOfElementType(c: *Checker, rt: TypeId, right_node: Node) Error!TypeId {
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
                if (try c.iteratorNextValue(ret)) |v| return v;
            }
        }
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
    /// `next(): { value }` shape.
    fn iteratorNextValue(c: *Checker, iter: TypeId) Error!?TypeId {
        const r = try c.resolveStructural(iter);
        const nextp = (try c.propOfType(r, c.atom_next)) orelse return null;
        const ret = try c.callableReturn(nextp.ty);
        if (ret == 0) return null;
        const rr = try c.resolveStructural(ret);
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
            const eff_rt = if (ctx.is_async) c.awaitedType(rt) else rt;
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
        defer {
            c.cur_scope = saved_scope;
            c.fn_ctx = saved_ctx;
        }
        if (try c.scopeOf(node)) |s| c.cur_scope = s;
        const is_async = proto.flags & ast.Flags.async != 0;
        const is_generator = proto.flags & ast.Flags.generator != 0;
        const ann: TypeId = if (proto.return_type != 0) try c.typeFromTypeNode(proto.return_type) else types.no_type;
        // Effective return-check target. For async this is the awaited payload
        // `T` of the declared `Promise<T>`; a non-Promise annotation is TS1064.
        var eff_ann = ann;
        var yield_type: TypeId = 0;
        if (is_async and ann != types.no_type) {
            const k = c.ts.kind(ann);
            const is_promise = c.ts.kind(ann) == .ref and c.prog.globals.lookup(c.atom_Promise) != null and
                c.ts.refSymbol(ann) == c.prog.globals.lookup(c.atom_Promise).?;
            if (is_promise) {
                eff_ann = c.awaitedType(ann);
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
                        if (stmt != null_node) try c.collectReturns(stmt, &rets, &bare);
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
                const eff_rt = if (is_async) c.awaitedType(rt) else rt;
                _ = try c.checkAssignable(eff_rt, eff_ann, body, c.nodeSpan(body));
            }
        }
        _ = sig;
    }

    // --- syntactic reachability (2366/return-undefined inference) ---------

    fn stmtListTerminal(c: *Checker, stmts: []const Node) bool {
        var i = stmts.len;
        while (i > 0) {
            i -= 1;
            const s = stmts[i];
            if (s == null_node) continue;
            return c.stmtTerminal(s);
        }
        return false;
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
        for (c.tree.extraRange(data.members_start, data.members_end)) |member| {
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
                    if (e.type_ann != 0) ann = try c.typeFromTypeNode(e.type_ann);
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
                        try c.checkFunctionBody(member, md.lhs, md.rhs, sig);
                    }
                },
                else => {},
            }
        }
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
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &t.interner, tree, src);
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
        bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, buf[0..len]);
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
    bound.* = try binder.bind(alloc, testing.io, testing.allocator, &interner, tree, source_buf[0..len]);
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
