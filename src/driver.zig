//! The front-end driver: everything between "here are the root paths" and
//! "here is a linked `Program`".
//!
//! The built-in lib runs its own front end first (`libs.frontEndLibs`):
//! the shards are parsed on a small thread budget and then bound
//! single-threaded in fixed order, which is what pins the interner's atoms
//! before any concurrent user-file work. Its output enters discovery as
//! ready-made completions, so the lib is never queued to the pool.
//!
//! Module discovery is single-owner with a completion queue: this thread is
//! the sole owner of the module graph and seen-set (no locks on graph state);
//! workers run the whole per-file front end (load/parse/bind) and push per-file
//! completion messages `(file, import specifiers)`; the owner resolves each
//! completion's module specifiers (bundler-style, see modules.zig) as it
//! arrives and enqueues newly discovered files immediately — no wave barrier,
//! so already-discovered work never waits on an unrelated slow file.
//!
//! After discovery, files are renumbered into a deterministic graph-derived
//! order (BFS from the entry files, tie-break = specifier order within the
//! importing file — the same order the old wavefront discovery produced), and
//! the atoms the *concurrent* front end handed out are reassigned by replaying
//! each file's first-touch list in that order, so the ids are the ones a
//! single-threaded front end would have produced (`Interner.renumber`). Atoms
//! are sort keys — scope member tables, merged namespace members, object
//! property records — so without it the checker's traversal order, and the
//! work it did, moved with worker scheduling.
//!
//! A serial `link` phase then builds the sealed per-file import/export tables
//! and the `Program` this returns. Everything downstream (check, printing)
//! sees only the renumbered ids, so output is byte-identical for any
//! --workers count.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const source = @import("frontend/source.zig");
const ast = @import("frontend/ast.zig");
const parser = @import("frontend/parser.zig");
const binder = @import("frontend/binder.zig");
const intern = @import("intern.zig");
const libs = @import("libs.zig");
const package_id = @import("link/package_id.zig");
const paths_mod = @import("link/paths.zig");
const resolve = @import("link/resolve.zig");
const modules = @import("link/modules.zig");
const tsconfig = @import("tsconfig.zig");

const Source = source.Source;
const Ast = ast.Ast;
const Bind = binder.Bind;
const Atom = intern.Atom;
const Interner = intern.Interner;
const FileId = modules.FileId;

/// Minimal monotonic wall-clock timer over std.Io's clock API. Every phase
/// this driver reports, and every checker instance (schedule.zig), measures
/// itself with one.
pub const Timer = struct {
    io: Io,
    start_ts: Io.Clock.Timestamp,

    pub fn start(io: Io) Timer {
        return .{ .io = io, .start_ts = .now(io, .awake) };
    }

    pub fn readNs(t: *const Timer) u64 {
        const d = t.start_ts.untilNow(t.io);
        const ns = d.raw.nanoseconds;
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// How the program's root file list is ordered before it is seeded. The
/// order is supposed to be unobservable — this exists so a gate can prove it.
pub const FileOrder = union(enum) {
    /// As the tsconfig `include` walk (or the command line) produced it.
    source: void,
    /// Exactly reversed. The cheapest permutation that moves every file.
    reverse: void,
    /// A seeded Fisher-Yates deal, so a failing order is reproducible from
    /// the seed alone.
    shuffle: u64,
};

/// A unit of discovery work handed to a worker: one file to front-end.
/// The path slice lives in the main arena and is stable for the run.
const WorkItem = struct {
    file: FileId,
    path: []const u8,
};

/// Per-file completion message a worker sends back to the owner thread:
/// the sealed front-end outputs plus per-phase timings. Payloads live in
/// the worker's arena and are read-only once the message is pushed.
const Completion = struct {
    file: FileId,
    src: ?Source = null,
    tree: ?*Ast = null,
    bind: ?*Bind = null,
    err: ?anyerror = null,
    /// The file's own path, interned before it is parsed — the first string
    /// this file contributes to the program-wide interning order (see the
    /// renumbering block below). 0 for the lib shards, whose atoms are already
    /// pinned, and for a file that never loaded.
    path_atom: Atom = 0,
    load_ns: u64 = 0,
    parse_ns: u64 = 0,
    bind_ns: u64 = 0,
};

/// Unbounded FIFO channel (mutex + condition). Buffer memory comes from
/// the channel's own arena and is only touched under the lock, so the
/// channel is safe with any number of producers and consumers. Message
/// passing is the only worker<->owner communication during discovery; the
/// module graph itself stays owner-thread-owned with no locks.
fn Channel(comptime T: type) type {
    return struct {
        io: Io,
        arena: std.heap.ArenaAllocator,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        buf: std.ArrayList(T) = .empty,
        head: usize = 0,
        closed: bool = false,

        const Self = @This();

        fn init(io: Io) Self {
            return .{ .io = io, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        }

        fn deinit(c: *Self) void {
            c.arena.deinit();
        }

        fn push(c: *Self, item: T) error{OutOfMemory}!void {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            try c.buf.append(c.arena.allocator(), item);
            c.cond.signal(c.io);
        }

        /// Blocks until an item is available; null after close() once the
        /// buffer is drained.
        fn pop(c: *Self) ?T {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            while (c.head == c.buf.items.len) {
                if (c.closed) return null;
                c.cond.waitUncancelable(c.io, &c.mutex);
            }
            const item = c.buf.items[c.head];
            c.head += 1;
            return item;
        }

        fn close(c: *Self) void {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.closed = true;
            c.cond.broadcast(c.io);
        }
    };
}

/// One pool worker. Each worker owns an arena allocator; everything a worker
/// allocates while processing files (line tables, tokens, ASTs, binder
/// output) lives in its arena and is never individually freed. Workers pull
/// one file at a time from the work channel, run the whole per-file front
/// end on it, and push a completion — no phase or wave barriers.
pub const Worker = struct {
    arena: std.heap.ArenaAllocator,
    /// Scratch space for benchmark re-runs (`--repeat`); reset between runs.
    scratch: std.heap.ArenaAllocator,
    /// Segments the worker's small source files are packed into, so the
    /// front end pays no per-file page rounding. Private to the worker,
    /// which is what makes the pack's bump cursor lock-free.
    pack: source.Pack = .{},
    thread: std.Thread = undefined,
    /// The grammar options every file this worker parses is parsed under
    /// (`jsx` is per-file and filled in at the call site). Settled from the
    /// tsconfig before any worker is spawned, so it needs no synchronization.
    parse_opts: parser.Opts = .{},

    fn discoverRun(
        w: *Worker,
        io: Io,
        gpa: Allocator,
        interner: *Interner,
        repeat: usize,
        work: *Channel(WorkItem),
        done: *Channel(Completion),
    ) void {
        while (work.pop()) |item| {
            var c: Completion = .{ .file = item.file };
            w.processFile(io, gpa, interner, item.path, repeat, &c);
            done.push(c) catch @panic("ztsc: out of memory (completion queue)");
        }
    }

    /// The whole per-file front end: load -> parse (which tokenizes) -> bind.
    /// Outputs and per-phase timings land in `c`; on the first error the
    /// remaining phases are skipped (same per-phase skip behavior the
    /// wavefront scheduler had). `repeat > 1` re-runs each phase into
    /// scratch (benchmarks).
    fn processFile(
        w: *Worker,
        io: Io,
        gpa: Allocator,
        interner: *Interner,
        path: []const u8,
        repeat: usize,
        c: *Completion,
    ) void {
        const alloc = w.arena.allocator();

        var timer = Timer.start(io);
        const src = if (libs.libSourceFor(path)) |lib_bytes|
            Source.fromBytes(alloc, path, lib_bytes) catch |err| {
                c.err = err;
                return;
            }
        else if (paths_mod.anyModuleSourceFor(path)) |any_bytes|
            // A resolved JSON module (resolveJsonModule) or JS module (allowJs):
            // type it opaquely as `any` from a synthetic body instead of parsing
            // the raw JSON/JS as TypeScript.
            Source.fromBytes(alloc, path, any_bytes) catch |err| {
                c.err = err;
                return;
            }
        else
            Source.load(io, alloc, path, &w.pack) catch |err| {
                c.err = err;
                return;
            };
        c.src = src;
        // Exercise the shared interner from every worker thread.
        c.path_atom = interner.intern(io, gpa, path) catch |err| {
            c.err = err;
            return;
        };
        c.load_ns = timer.readNs();

        // No standalone tokenize pass: the parser tokenizes internally
        // into `tree.tokens` (what the binder reads), so a separate scan
        // would be pure throwaway work (~5.8% of front-end CPU). Token
        // stats are derived from `tree.tokens`.
        timer = Timer.start(io);
        var r: usize = 1;
        while (r < repeat) : (r += 1) {
            var opts = w.parse_opts;
            opts.jsx = parser.isJsxPath(path);
            opts.dts = parser.isDeclarationPath(path);
            var tree = parser.parseOpts(w.scratch.allocator(), src.bytes, opts) catch break;
            std.mem.doNotOptimizeAway(&tree);
            _ = w.scratch.reset(.retain_capacity);
        }
        const tree = alloc.create(Ast) catch |err| {
            c.err = err;
            return;
        };
        var file_opts = w.parse_opts;
        file_opts.jsx = parser.isJsxPath(path);
        file_opts.dts = parser.isDeclarationPath(path);
        tree.* = parser.parseOpts(alloc, src.bytes, file_opts) catch |err| {
            c.err = err;
            return;
        };
        c.tree = tree;
        c.parse_ns = timer.readNs();

        timer = Timer.start(io);
        r = 1;
        while (r < repeat) : (r += 1) {
            var b = binder.bind(w.scratch.allocator(), io, gpa, interner, tree, src.bytes, parser.isDeclarationPath(path)) catch break;
            std.mem.doNotOptimizeAway(&b);
            _ = w.scratch.reset(.retain_capacity);
        }
        const b = alloc.create(Bind) catch |err| {
            c.err = err;
            return;
        };
        b.* = binder.bind(alloc, io, gpa, interner, tree, src.bytes, parser.isDeclarationPath(path)) catch |err| {
            c.err = err;
            return;
        };
        c.bind = b;
        c.bind_ns = timer.readNs();
    }
};

/// Every table the driver keeps one entry of per file, in one place.
///
/// They are grown together (`ensure`) and permuted together (`permute`) —
/// which is the point: a tenth table added as a field is grown and permuted
/// with the other nine, where ten loose `ArrayList`s wired through a
/// nine-argument helper only had to miss one call site to corrupt the file
/// order silently.
///
/// Only the owner thread touches these; workers communicate exclusively
/// through the channels.
pub const FileTables = struct {
    /// Discovery order: `paths.items[i]` is file `i`'s path. This one is
    /// grown by discovery itself (`modules.Discovery.fileFor` appends as it
    /// resolves), and is what `ensure` grows all the others UP TO — so it
    /// takes no part in `ensure`, only in `permute`.
    paths: std.ArrayList([]const u8) = .empty,
    results: std.ArrayList(?Source) = .empty,
    trees: std.ArrayList(?*Ast) = .empty,
    binds: std.ArrayList(?*Bind) = .empty,
    errs: std.ArrayList(?anyerror) = .empty,
    /// Per-file path atom, in the order the front end interned it (first for
    /// the file); feeds the deterministic renumbering after discovery.
    path_atoms: std.ArrayList(Atom) = .empty,
    spec_atoms: std.ArrayList([]Atom) = .empty,
    spec_files: std.ArrayList([]FileId) = .empty,
    /// Per-file resolved FileIds in first-occurrence specifier order
    /// (unresolved skipped) — the edges of the deterministic BFS.
    edges: std.ArrayList([]const FileId) = .empty,
    /// Per-file `/// <reference types="X" />` directives that resolved to
    /// nothing; the linker replays them as TS2688.
    type_ref_misses: std.ArrayList([]const modules.TypeRefMiss) = .empty,

    /// Give every table a slot for every discovered file (null/empty
    /// defaults). Called after each round of discovery, since resolving one
    /// file's specifiers can append to `paths`.
    pub fn ensure(t: *FileTables, arena: Allocator) !void {
        const n = t.paths.items.len;
        while (t.results.items.len < n) try t.results.append(arena, null);
        while (t.trees.items.len < n) try t.trees.append(arena, null);
        while (t.binds.items.len < n) try t.binds.append(arena, null);
        while (t.errs.items.len < n) try t.errs.append(arena, null);
        while (t.path_atoms.items.len < n) try t.path_atoms.append(arena, 0);
        while (t.spec_atoms.items.len < n) try t.spec_atoms.append(arena, &.{});
        while (t.spec_files.items.len < n) try t.spec_files.append(arena, &.{});
        while (t.edges.items.len < n) try t.edges.append(arena, &.{});
        while (t.type_ref_misses.items.len < n) try t.type_ref_misses.append(arena, &.{});
    }

    /// Reorder every table so that entry `k` becomes the old entry
    /// `order[k]`. `edges` is the exception: the BFS that produced `order`
    /// consumed it, and its payload is old ids, so it is dropped here rather
    /// than left half-updated for someone to read.
    pub fn permute(t: *FileTables, arena: Allocator, order: []const u32) !void {
        try permuteInPlace([]const u8, arena, t.paths.items, order);
        try permuteInPlace(?Source, arena, t.results.items, order);
        try permuteInPlace(?*Ast, arena, t.trees.items, order);
        try permuteInPlace(?*Bind, arena, t.binds.items, order);
        try permuteInPlace(?anyerror, arena, t.errs.items, order);
        try permuteInPlace(Atom, arena, t.path_atoms.items, order);
        try permuteInPlace([]Atom, arena, t.spec_atoms.items, order);
        try permuteInPlace([]FileId, arena, t.spec_files.items, order);
        try permuteInPlace([]const modules.TypeRefMiss, arena, t.type_ref_misses.items, order);
        t.edges.clearRetainingCapacity();
    }
};

/// Reorder `items` so that items[k] becomes the old items[order[k]].
fn permuteInPlace(comptime T: type, arena: Allocator, items: []T, order: []const u32) !void {
    const copy = try arena.dupe(T, items);
    for (order, 0..) |old, k| items[k] = copy[old];
}

/// What the CLI settled before any file was touched. Everything here is an
/// input; the driver reads no globals and no config of its own.
pub const Options = struct {
    /// The program roots: the real roots first, then the auto-included
    /// `@types/*` ambient roots (`n_real_roots` splits the two).
    entry_paths: []const []const u8,
    /// How many of `entry_paths` are REAL roots. The rest are ordered as a
    /// second BFS wave — see the renumbering block. Every root is real when
    /// the run is driven by CLI file arguments.
    n_real_roots: usize,
    file_order: FileOrder = .{ .source = {} },
    lib_set: libs.LibSet,
    n_workers: usize,
    /// `--repeat=N`: re-run each file's parse/bind N times (benchmark aid).
    repeat: usize = 1,
    /// Whether the module-resolution memos are live (`--no-resolve-cache`).
    resolve_cache: bool = true,
    resolve_opts: resolve.ResolveOpts = .{},
    /// tsconfig `paths`, or null when the run has no config.
    paths_map: ?tsconfig.Paths = null,
    /// `<jsxImportSource>/jsx-runtime` under the automatic JSX runtime; null
    /// under the classic runtime (global `JSX` namespace only).
    jsx_runtime_module: ?[]const u8 = null,
    link_opts: modules.LinkOpts = .{},
};

/// Per-phase wall clock, in the order the phases run. Load/parse/bind are
/// summed per-file worker times, since files stream through the pipeline;
/// `discover` is the front-end wall clock.
pub const Timings = struct {
    load_ns: u64 = 0,
    parse_ns: u64 = 0,
    bind_ns: u64 = 0,
    resolve_ns: u64 = 0,
    discover_ns: u64 = 0,
    renumber_ns: u64 = 0,
    link_ns: u64 = 0,
};

/// A built program plus everything the CLI still needs to report on it.
pub const Result = struct {
    prog: *modules.Program,
    /// The per-file front-end products, in final (renumbered) file order.
    files: FileTables,
    /// How many files the roots themselves account for (the lib shards and
    /// the entry paths), for the "N from CLI" line.
    n_entries: usize,
    /// The pool, kept alive: every `Source`/`Ast`/`Bind` above lives in a
    /// worker arena. Read afterwards for the memory report.
    workers: []Worker,
    /// The resolution memo, for the timing report's cache statistics.
    rcache: *resolve.ResolveCache,
    /// The built-in lib's front end. The caller owns it — its arenas hold the
    /// lib ASTs the checkers read, so it must outlive the check phase.
    lib_fe: libs.LibFrontEnd,
    timings: Timings = .{},
};

/// Discover, front-end and link the whole program.
///
/// `arena` holds everything that outlives the call (the program, the file
/// tables, the resolution memo); worker arenas hold the per-file front-end
/// products and are owned by `Result.workers`.
pub fn build(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    opts: Options,
) !Result {
    const workers = try arena.alloc(Worker, opts.n_workers);
    for (workers) |*w| w.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .parse_opts = .{ .experimental_decorators = opts.link_opts.experimental_decorators },
    };

    // Transient allocator for module resolution: candidate path strings and
    // package.json bodies are discarded after each file's specifiers
    // resolve. Mirrors the serial buildProgram path (modules.zig). Reset per
    // file so it never grows past one file's resolution working set.
    var resolve_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer resolve_scratch.deinit();

    // Resolution memo: the same specifier imported from many files
    // resolves once. Lives in `arena` (spans the whole run, and is read back
    // for the timing report). Created before the program roots are seeded
    // because they, too, go through its canonical-path step (see below).
    const rcache = try arena.create(resolve.ResolveCache);
    rcache.* = resolve.ResolveCache.init(arena, opts.resolve_cache, opts.resolve_opts);

    var tables: FileTables = .{};
    var path_ids: std.StringHashMapUnmanaged(FileId) = .empty;

    // The per-file half of discovery, shared verbatim with the serial builder
    // in modules.zig.
    const disco: modules.Discovery = .{
        .arena = arena,
        .store = arena,
        .seen_alloc = gpa,
        .scratch = resolve_scratch.allocator(),
        .io = io,
        .dir = Io.Dir.cwd(),
        .interner = interner,
        .rcache = rcache,
        .paths_map = opts.paths_map,
        .resolve_json = opts.resolve_opts.resolve_json,
        .paths = &tables.paths,
        .path_ids = &path_ids,
    };

    const entries = try seedRoots(arena, &disco, &resolve_scratch, opts);

    var work = Channel(WorkItem).init(io);
    defer work.deinit();
    var done = Channel(Completion).init(io);
    defer done.deinit();

    // The lib's front end: parse and bind the injected shards single-threaded,
    // before any worker runs, and *keep* the results. Single-threaded is what
    // pins the atoms (an `Atom` encodes shard-local insertion order, so the
    // lib's strings must be interned in a fixed order ahead of the concurrent
    // user-file work). Keeping the products is what makes the pass pay for
    // itself: the shards never enter the work queue, so the lib is parsed and
    // bound once per run instead of once here and again on a worker.
    //
    // Per-shard arenas, not the process arena: `init.arena` is thread-safe, so
    // every allocation there takes a lock, and this is one of the
    // allocation-heaviest stretches of the run (and its parse pass is
    // concurrent). They live as long as the program — the AST and binder
    // output are program data — so they are only released at the end (the
    // caller owns `Result.lib_fe`).
    var lib_fe = try libs.frontEndLibs(arena, io, gpa, interner, opts.lib_set, opts.n_workers);
    errdefer lib_fe.deinit();
    const lib_units = lib_fe.units;

    // Everything interned up to here came from a single-threaded phase, so its
    // ids are already the same on every run and the lib's sealed binder output
    // (which is kept, never re-bound) can keep pointing at them. Ids handed out
    // past this point are scheduling-dependent and get reassigned once
    // discovery is done — see the renumbering block below.
    interner.freezePrefix();

    var timings: Timings = .{};
    const discover_timer = Timer.start(io);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.discoverRun, .{
            w, io, gpa, interner, opts.repeat, &work, &done,
        });
    }

    var outstanding: usize = 0;
    try tables.ensure(arena);
    // The lib shards hold file ids 0..lib_units.len and are already
    // front-ended, so they enter the discovery loop as ready-made completions
    // instead of as work. Everything downstream — specifier resolution,
    // `/// <reference>` scanning, the BFS renumbering — sees an ordinary
    // completion and cannot tell the difference.
    for (lib_units, 0..) |*u, i| {
        try done.push(.{
            .file = @intCast(i),
            .src = u.src,
            .tree = u.tree,
            .bind = u.bind,
            .parse_ns = u.parse_ns,
            .bind_ns = u.bind_ns,
        });
        outstanding += 1;
    }
    for (tables.paths.items[lib_units.len..], lib_units.len..) |p, i| {
        try work.push(.{ .file = @intCast(i), .path = p });
        outstanding += 1;
    }

    // FileId of the auto-injected `@types/node` (null until the first Node
    // built-in import pulls it in); see the discovery loop below.
    var node_types_fid: ?FileId = null;
    // FileId of the auto-injected `<jsxImportSource>/jsx-runtime` (null until
    // the first `.tsx` file pulls it in); see the discovery loop below.
    var jsx_runtime_fid: ?FileId = null;
    resolve.resetFsProbeCount();

    while (outstanding > 0) {
        // The done channel is never closed while work is outstanding.
        const c = done.pop().?;
        outstanding -= 1;
        const i = c.file;
        tables.results.items[i] = c.src;
        tables.trees.items[i] = c.tree;
        tables.binds.items[i] = c.bind;
        tables.errs.items[i] = c.err;
        tables.path_atoms.items[i] = c.path_atom;
        timings.load_ns += c.load_ns;
        timings.parse_ns += c.parse_ns;
        timings.bind_ns += c.bind_ns;

        // Resolve this file's module specifiers (owner thread only;
        // discovers files).
        const resolve_timer = Timer.start(io);
        var atoms: std.ArrayList(Atom) = .empty;
        var files: std.ArrayList(FileId) = .empty;
        var ref_files: std.ArrayList(FileId) = .empty;
        const known_before = tables.paths.items.len;
        if (tables.binds.items[i]) |b| {
            const importer = tables.paths.items[i];
            var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
            defer seen.deinit(gpa);
            try disco.fileSpecs(importer, b, &seen, &atoms, &files);
            // Pull @types/node into the program on the first Node built-in
            // import (`node:fs`, `path`, …), like tsc auto-including @types
            // (`Discovery.discoverNodeTypes`, shared with the serial builder).
            // Injected once, discovered like a triple-slash reference so the
            // deterministic BFS reaches it (and, via its own `/// <reference>`
            // refs, every submodule .d.ts).
            if (node_types_fid == null) {
                if (try disco.discoverNodeTypes(importer, b)) |nf| {
                    node_types_fid = nf;
                    try ref_files.append(arena, nf);
                }
            }
            // Under the automatic JSX runtime the `JSX` namespace is an export
            // of `<jsxImportSource>/jsx-runtime`, not a global — @types/react 19
            // ships no `declare global { namespace JSX }` at all. tsc puts that
            // module in the program for every JSX file; do the same on the first
            // `.tsx` we see, discovered like a triple-slash reference so the
            // deterministic BFS reaches it. Its FileId is handed to the checker
            // (`Program.jsx_runtime_file`) as the JSX-namespace fallback.
            if (jsx_runtime_fid == null and opts.jsx_runtime_module != null and
                std.mem.endsWith(u8, importer, ".tsx"))
            {
                if (try disco.discoverModule(importer, opts.jsx_runtime_module.?)) |jf| {
                    jsx_runtime_fid = jf;
                    try ref_files.append(arena, jf);
                }
            }
            // Triple-slash `/// <reference>` directives pull extra files into
            // the program — program inputs, not import bindings. Their
            // resolved ids join the discovery edge list so the deterministic
            // BFS renumbering below reaches them.
            if (tables.results.items[i]) |src| {
                var misses: std.ArrayList(modules.TypeRefMiss) = .empty;
                for (try resolve.scanReferences(resolve_scratch.allocator(), src.bytes)) |ref| {
                    const rfid = try disco.discoverReference(importer, ref);
                    try ref_files.append(arena, rfid);
                    // An unresolvable directive is tsc's TS2688 (`types=`) or
                    // TS6053 (`path=`); the linker reports it, since only this
                    // loop knows resolution failed.
                    if (rfid == modules.no_file) try misses.append(arena, modules.typeRefMiss(ref));
                }
                tables.type_ref_misses.items[i] = misses.items;
            }
            _ = resolve_scratch.reset(.retain_capacity);
        }
        var edges: std.ArrayList(FileId) = .empty;
        for (files.items) |fid| {
            if (fid != modules.no_file) try edges.append(arena, fid);
        }
        for (ref_files.items) |fid| {
            if (fid != modules.no_file) try edges.append(arena, fid);
        }
        tables.edges.items[i] = edges.items;
        modules.sortSpecPairs(atoms.items, files.items);
        tables.spec_atoms.items[i] = atoms.items;
        tables.spec_files.items[i] = files.items;

        // Enqueue newly discovered files right away.
        try tables.ensure(arena);
        for (known_before..tables.paths.items.len) |nf| {
            try work.push(.{ .file = @intCast(nf), .path = tables.paths.items[nf] });
            outstanding += 1;
        }
        timings.resolve_ns += resolve_timer.readNs();
    }
    work.close();
    for (workers) |*w| w.thread.join();
    timings.discover_ns = discover_timer.readNs();

    jsx_runtime_fid = try renumber(
        arena,
        gpa,
        io,
        interner,
        &tables,
        .{ .lib_files = lib_units.len, .root_end = entries.root_end, .entry_end = entries.total },
        jsx_runtime_fid,
        &timings,
    );

    // Package-identity dedup, shared with the serial builder: two on-disk
    // copies of one package version are ONE module, so every specifier that
    // resolved to a later copy is re-pointed at the first (package_id.zig).
    // Runs AFTER the renumbering: the winner is "lowest file id", and only the
    // renumbered ids are graph-derived — the discovery order this loop handed
    // out depends on worker completion order, so deciding it earlier would make
    // the answer scheduling-dependent.
    if (try package_id.redirects(arena, resolve_scratch.allocator(), rcache, io, Io.Dir.cwd(), tables.paths.items)) |map| {
        for (tables.spec_files.items) |spec_files| package_id.applyTo(map, spec_files);
    }
    _ = resolve_scratch.reset(.retain_capacity);

    const link_timer = Timer.start(io);
    const prog = try linkProgram(arena, gpa, io, interner, &tables, opts.link_opts, jsx_runtime_fid orelse modules.no_file, opts.jsx_runtime_module);
    timings.link_ns = link_timer.readNs();

    return .{
        .prog = prog,
        .files = tables,
        .n_entries = entries.total,
        .workers = workers,
        .rcache = rcache,
        .lib_fe = lib_fe,
        .timings = timings,
    };
}

/// Where the seeded entries end: `root_end` is the first auto-included
/// `@types/*` root, `total` the first file only discovery can reach.
const Entries = struct { root_end: usize, total: usize };

/// Seed the file table with the built-in lib shards and the program roots.
/// Both seeding steps are `modules.Discovery`'s, shared with the serial
/// `buildProgram`, so the two pipelines cannot disagree about which files a
/// program starts from.
fn seedRoots(
    arena: Allocator,
    disco: *const modules.Discovery,
    resolve_scratch: *std.heap.ArenaAllocator,
    opts: Options,
) !Entries {
    try disco.seedLibs(opts.lib_set);

    // `--file-order`: permute the roots before a single id is handed out.
    // Everything downstream — file ids, the BFS discovery order, the cost
    // partition and its tie-breaks — is a function of this list, so this is
    // the one place that can vary the axis. tsc's answer does not depend on
    // root order; `bench/order_sweep.sh` is the gate that says ztsc's does
    // not either. Only the REAL roots permute: the auto-included `@types/*`
    // tail is not a user-visible ordering, and tsc always processes it after
    // the roots' closure however the roots were listed.
    var entry_paths = opts.entry_paths;
    switch (opts.file_order) {
        .source => {},
        .reverse => {
            const permuted = try arena.dupe([]const u8, entry_paths);
            std.mem.reverse([]const u8, permuted[0..opts.n_real_roots]);
            entry_paths = permuted;
        },
        .shuffle => |seed| {
            const permuted = try arena.dupe([]const u8, entry_paths);
            var prng: std.Random.DefaultPrng = .init(seed);
            prng.random().shuffle([]const u8, permuted[0..opts.n_real_roots]);
            entry_paths = permuted;
        },
    }

    // Program roots (canonicalized — see `Discovery.seedEntry`).
    //
    // `root_end` is where the auto-included `@types/*` roots start in `paths`
    // — the second BFS wave in the renumbering block. A `@types/*` path
    // already seen as a real root keeps its first position.
    var root_end: usize = 0;
    const waves = [2][]const []const u8{ entry_paths[0..opts.n_real_roots], entry_paths[opts.n_real_roots..] };
    for (waves, 0..) |wave, wi| {
        if (wi == 1) root_end = disco.paths.items.len;
        for (wave) |p| _ = try disco.seedEntry(p);
    }
    _ = resolve_scratch.reset(.retain_capacity);
    return .{ .root_end = root_end, .total = disco.paths.items.len };
}

/// The seeded prefix of the file table: the lib shards, then the real roots,
/// then the auto-included `@types/*` roots.
const Seeded = struct { lib_files: usize, root_end: usize, entry_end: usize };

/// Give the program its deterministic file order and its deterministic atom
/// ids, and return the remapped `jsx_runtime_fid`.
fn renumber(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    tables: *FileTables,
    seeded: Seeded,
    jsx_runtime_fid: ?FileId,
    timings: *Timings,
) !?FileId {
    const n_files = tables.paths.items.len;
    var jsx_fid = jsx_runtime_fid;

    // --- Deterministic file order (graph-derived, not scheduling-derived) --
    // Completion order depends on scheduling; output order must not. BFS
    // from the entry files, tie-break = specifier order within each
    // importing file (the exact order wavefront discovery produced), then
    // permute every per-file table into that order. Everything downstream
    // (link, checker partition, printing) sees only the renumbered ids, so
    // output is byte-identical for any --workers/--checkers combination.
    //
    // TWO waves: the libs and the real roots with their whole import closure,
    // and only then the auto-included `@types/*` ambient roots with theirs.
    // That is `createProgram`'s order — root files first, automatic type
    // reference directives after — and file order is the merge order a
    // `declare global` augmentation of an existing global gets, so it decides
    // which declaration group of `setTimeout` is last. See the seeding site.
    {
        const order = try arena.alloc(u32, n_files); // BFS position -> discovery id
        const new_ids = try arena.alloc(u32, n_files); // discovery id -> BFS position
        @memset(new_ids, modules.no_file);
        var tail: usize = 0;
        var head: usize = 0;
        for ([2][2]usize{ .{ 0, seeded.root_end }, .{ seeded.root_end, seeded.entry_end } }) |wave| {
            for (wave[0]..wave[1]) |i| {
                if (new_ids[i] != modules.no_file) continue;
                new_ids[i] = @intCast(tail);
                order[tail] = @intCast(i);
                tail += 1;
            }
            while (head < tail) : (head += 1) {
                for (tables.edges.items[order[head]]) |fid| {
                    if (new_ids[fid] != modules.no_file) continue;
                    new_ids[fid] = @intCast(tail);
                    order[tail] = fid;
                    tail += 1;
                }
            }
        }
        // Every discovered file was discovered through a recorded edge,
        // so the BFS reaches all of them.
        std.debug.assert(tail == n_files);

        try tables.permute(arena, order);
        if (jsx_fid) |f| jsx_fid = new_ids[f];
        // Remap the resolved FileIds inside the spec maps.
        for (tables.spec_files.items) |spec_files| {
            for (spec_files) |*fid| {
                if (fid.* != modules.no_file) fid.* = new_ids[fid.*];
            }
        }
    }

    // --- Deterministic atom ids (file order, not scheduling order) --------
    // An `Atom` encodes its shard-local insertion index, and the front end
    // interns from every worker at once, so the ids a run hands out depend on
    // which worker got there first. Atoms are sort keys downstream — a scope's
    // member table, a merged namespace's member index, an object type's
    // property records — so that scheduling noise reached the checker as a
    // different *traversal order*, and (through the assignability memo's
    // in-progress marks) a different set of walked subtrees. Diagnostics never
    // moved, but the work counters did, and a program sitting on the
    // instantiation budget could have tipped either way.
    //
    // The fix is to assign the ids a single-threaded front end would have.
    // Each file recorded the atoms it touched in first-touch order
    // (`Bind.first_touch`, preceded by its own path); replaying those lists in
    // the program's graph-derived file order is exactly the sequence a serial
    // run interns in, so `Interner.renumber` can hand out the serial ids and
    // every table sorted by atom lands where the serial run put it. Serial
    // runs get an identity permutation and skip the rewrite entirely.
    {
        const renumber_timer = Timer.start(io);
        var order: std.ArrayList(Atom) = .empty;
        defer order.deinit(gpa);
        // The lib shards are bound before the pool starts; their atoms are in
        // the frozen prefix and never move.
        for (seeded.lib_files..n_files) |i| {
            if (tables.path_atoms.items[i] != 0) try order.append(gpa, tables.path_atoms.items[i]);
            if (tables.binds.items[i]) |b| try order.appendSlice(gpa, b.first_touch);
        }
        const rn = try interner.renumber(gpa, gpa, order.items);
        defer gpa.free(rn.map);
        if (rn.uncovered != 0) {
            // An interning site the replay does not know about: the id space is
            // scheduling-dependent again. Loud, because nothing downstream can
            // detect it.
            std.debug.print(
                "ztsc: internal: {d} atom(s) outside the recorded interning order\n",
                .{rn.uncovered},
            );
        }
        if (!rn.identity) {
            for (tables.binds.items[seeded.lib_files..]) |maybe_bind| {
                if (maybe_bind) |b| try b.remapAtoms(gpa, rn.map);
            }
            for (tables.spec_atoms.items, tables.spec_files.items) |spec_atoms, spec_files| {
                for (spec_atoms) |*a| a.* = rn.map[a.*];
                modules.sortSpecPairs(spec_atoms, spec_files);
            }
        }
        timings.renumber_ns = renumber_timer.readNs();
    }
    return jsx_fid;
}

/// Assemble the `ProgFile` table and run the serial link phase.
fn linkProgram(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    tables: *const FileTables,
    link_opts: modules.LinkOpts,
    jsx_runtime_file: FileId,
    jsx_runtime_module: ?[]const u8,
) !*modules.Program {
    const n_files = tables.paths.items.len;
    const prog_files = try arena.alloc(modules.ProgFile, n_files);
    var empty_tree: ?*Ast = null;
    var empty_bind: ?*Bind = null;
    for (0..n_files) |i| {
        // Substitute an empty file for load/parse failures so ids stay
        // dense (the error is reported by the caller).
        var tree = tables.trees.items[i];
        var bnd = tables.binds.items[i];
        const src_bytes: []const u8 = if (tables.results.items[i]) |s| s.bytes else "";
        if (tree == null or bnd == null) {
            if (empty_tree == null) {
                empty_tree = try arena.create(Ast);
                empty_tree.?.* = try parser.parse(arena, "");
                empty_bind = try arena.create(Bind);
                empty_bind.?.* = try binder.bind(arena, io, gpa, interner, empty_tree.?, "", false);
            }
            tree = empty_tree;
            bnd = empty_bind;
        }
        prog_files[i] = .{
            .path = tables.paths.items[i],
            .src = if (tables.trees.items[i] == null) "" else src_bytes,
            .tree = tree.?,
            .bind = bnd.?,
            .specs = .{ .atoms = tables.spec_atoms.items[i], .files = tables.spec_files.items[i] },
            .type_ref_misses = tables.type_ref_misses.items[i],
        };
    }
    const lr = try modules.link(arena, gpa, io, interner, prog_files, link_opts);
    const prog = try arena.create(modules.Program);
    prog.* = .{
        .files = prog_files,
        .sym_base = lr.sym_base,
        .links = lr.links,
        .globals = lr.globals,
        .merged = lr.merged,
        .ambient_exports = lr.ambient_exports,
        .ambient_specs = lr.ambient_specs,
        .constit_keys = lr.constit_keys,
        .constit_vals = lr.constit_vals,
        .export_equals_atom = lr.export_equals_atom,
        .dual_targets = lr.dual_targets,
        .no_implicit_any = link_opts.no_implicit_any,
        .allow_synthetic_default = link_opts.allow_synthetic_default,
        .types_wildcard = link_opts.types_wildcard,
        .experimental_decorators = link_opts.experimental_decorators,
        .jsx_runtime_file = jsx_runtime_file,
        .jsx_runtime_module = jsx_runtime_module,
        .jsx_factory_ns = link_opts.jsx_factory_ns,
    };
    return prog;
}
