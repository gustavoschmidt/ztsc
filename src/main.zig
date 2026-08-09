//! ZTSC CLI driver: argument parsing, thread pool, phase orchestration.
//!
//! The built-in lib runs its own front end first (`libs.frontEndLibs`):
//! the shards are parsed on a small thread budget and then bound
//! single-threaded in fixed order, which is what pins the interner's atoms
//! before any concurrent user-file work. Its output enters discovery as
//! ready-made completions, so the lib is never queued to the pool.
//!
//! Atoms the *concurrent* front end hands out are pinned differently: they
//! are reassigned once discovery is done, replaying each file's first-touch
//! list in graph order so the ids are the ones a single-threaded front end
//! would have produced (`Interner.renumber`, the renumbering block below).
//! Atoms are sort keys — scope member tables, merged namespace members,
//! object property records — so without it the checker's traversal order,
//! and the work it did, moved with worker scheduling.
//!
//! Module discovery is single-owner with a completion queue: the main
//! thread is the sole owner of
//! the module graph and seen-set (no locks on graph state); workers run
//! the whole per-file front end (load/parse/bind) and push per-file
//! completion messages `(file, import specifiers)`; the main thread
//! resolves each completion's module specifiers (bundler-style, see
//! modules.zig) as it arrives and enqueues newly discovered files
//! immediately — no wave barrier, so already-discovered work never waits
//! on an unrelated slow file. After discovery, files are renumbered into
//! a deterministic graph-derived order (BFS from the entry files,
//! tie-break = specifier order within the importing file — the same order
//! the old wavefront discovery produced). A serial `link` phase then
//! builds sealed per-file import/export tables; the check phase
//! partitions the program's files across N independent checker instances
//! (`--checkers=N`; the default is min(4, cores), dropped to 2 when there
//! is less than `small_program_nodes` of check work to spread), each with its own type
//! store/caches, reading the shared immutable AST/binder/link data without
//! locks.
//!
//! Output determinism: the file order is derived from the graph, never
//! from scheduling; every diagnostic is tagged with its file; each file's
//! check diagnostics come from exactly the checker that owns it, and the
//! final print is per file (in graph order), position-sorted —
//! byte-identical for any --workers/--checkers combination. `--timing`
//! reports the per-phase split (`config` is tsconfig loading and its
//! `include` walk; load/parse/bind are summed per-file worker times,
//! since files stream through the pipeline; `discover` is the front-end
//! wall clock) plus a per-checker breakdown; `--memory`
//! reports arena/token/AST/binder statistics plus per-checker type-store
//! bytes and module-graph bytes.

const std = @import("std");
const Io = std.Io;
const ztsc = @import("ztsc");
const Source = ztsc.source.Source;
const Interner = ztsc.intern.Interner;
const parser = ztsc.parser;
const binder = ztsc.binder;
const checker = ztsc.checker;
const libs = ztsc.libs;
const modules = ztsc.modules;
const resolve = ztsc.resolve;
const types = ztsc.types;
const Ast = ztsc.ast.Ast;
const Bind = binder.Bind;

const usage =
    \\usage: ztsc [options] [files...]
    \\
    \\With no files, ztsc looks for tsconfig.json in the current directory
    \\and its parents (or uses --project). See the README for the checked
    \\TypeScript subset.
    \\
    \\options:
    \\  -p, --project <path>   use the tsconfig.json at <path> (file or dir)
    \\  --pretty[=true|false]  tsc-style colored diagnostics with source
    \\                         excerpts (default: on when stderr is a TTY)
    \\  --verbose              print notes about accepted-but-ignored
    \\                         tsconfig options
    \\  --timing               print per-phase wall-clock timings
    \\  --memory               print arena / memory statistics
    \\  --dump-ast             print S-expression parse trees (golden-test format)
    \\  --dump-symbols         print binder scope/symbol dumps (golden-test format)
    \\  --dump-types           print per-declaration checked types (golden-test format)
    \\  --noLib                skip the built-in ES-core lib (no globals,
    \\                         no primitive/array methods; matches tsc)
    \\  --lib=a,b,c            select built-in libs (es*, dom); overrides the
    \\                         tsconfig 'lib' field. Default: es-core + dom
    \\                         (matches tsgo's target-esnext default)
    \\  --skip-default-lib-check
    \\                         do NOT type-check the embedded lib files
    \\                         themselves (checked by default, matching tsc/
    \\                         tsgo; tsc's skipDefaultLibCheck). tsconfig
    \\                         skipDefaultLibCheck does the same; tsconfig
    \\                         skipLibCheck is the superset — it suppresses all
    \\                         diagnostics in every .d.ts (their types still flow)
    \\  --workers=N            number of worker threads (default: CPU count)
    \\  --checkers=N           number of checker instances (default:
    \\                         min(4, CPUs), or 2 on a small program —
    \\                         each instance costs fixed state that little
    \\                         checking does not repay)
    \\  --repeat=N             parse/bind each file N times (benchmark aid;
    \\                         does not cover the built-in lib, which is
    \\                         front-ended once before the pool starts)
    \\  --no-resolve-cache     disable the module-resolution memos — the
    \\                         specifier memo and the filesystem-fact caches
    \\                         under it (benchmark aid / correctness oracle)
    \\  --no-frozen-store      disable the shared frozen base type store; each
    \\                         checker re-expands lib types (benchmark aid / oracle)
    \\  --no-inst-cache        disable the instantiation caching layer; re-run
    \\                         every substitution (benchmark aid / oracle)
    \\  --census               tally out-of-subset constructs by frequency
    \\  --inst-profile         dump the instantiation-demand profile (where a
    \\                         statement's instantiation budget goes) to stderr;
    \\                         pair with --checkers=1
    \\  --inst-focus=ID        restrict that profile's per-type histogram to
    \\                         one substitution root (a #id from its report)
    \\  --decl-profile         dump the declaration-window TIME profile (what
    \\                         share of the check phase materializes
    \\                         declarations) to stderr; pair with --checkers=1
    \\  --mem-profile          dump each checker's per-container byte
    \\                         breakdown and footprint timeline to stderr
    \\  --inst-memo-bits=N     log2 of the per-checker instantiation memo's
    \\                         slot count (12 bytes a slot; measurement aid)
    \\  --dup-profile          implies --decl-profile and adds the raw
    \\                         (declaration unit, cost, demanding files) table
    \\                         the cross-checker duplication analysis reads;
    \\                         pair with --checkers=1
    \\  --eager-members        materialize every interface/class member table
    \\                         whole, instead of member-by-member on demand
    \\                         (bisect leg / oracle)
    \\  -h, --help             print this help and exit
    \\  --version              print version and exit
    \\
    \\exit codes: 0 no errors; 1 type/syntax errors reported; 2 usage,
    \\config, or file-system errors.
    \\
;

/// Minimal monotonic wall-clock timer over std.Io's clock API.
const Timer = struct {
    io: Io,
    start_ts: Io.Clock.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .start_ts = .now(io, .awake) };
    }

    fn readNs(t: *const Timer) u64 {
        const d = t.start_ts.untilNow(t.io);
        const ns = d.raw.nanoseconds;
        return if (ns > 0) @intCast(ns) else 0;
    }
};

const Cli = struct {
    timing: bool = false,
    memory: bool = false,
    dump_ast: bool = false,
    dump_symbols: bool = false,
    dump_types: bool = false,
    version: bool = false,
    help: bool = false,
    verbose: bool = false,
    /// Skip lib injection (globals/primitive methods); matches tsc --noLib.
    no_lib: bool = false,
    /// Opt out of type-checking the embedded lib files themselves. By default
    /// they are parsed/bound/linked (globals, lazy type expansion) AND walked
    /// by the checkers, matching tsc/tsgo, which check their default lib at
    /// their defaults. `--skip-default-lib-check` (or the tsconfig
    /// `skipLibCheck`/`skipDefaultLibCheck` keys) reverts to skipping them —
    /// the shipped lib is pre-verified, so skipping only saves time.
    /// Diagnostics are identical either way: lib-file diagnostics are never
    /// surfaced. null = not specified on the CLI (tsconfig value, else check).
    skip_default_lib_check: ?bool = null,
    /// `--lib=a,b,c`: override the built-in lib selection (else the tsconfig
    /// `lib` field, else the default ES-core + DOM). null = not specified.
    lib: ?[]const []const u8 = null,
    /// Disable the module-resolution memo — the "before" leg of the
    /// resolution-cache benchmark; resolution then re-walks node_modules per
    /// importer. Diagnostics are identical either way.
    no_resolve_cache: bool = false,
    /// Disable the shared frozen base type store — the "before" leg of
    /// the frozen-store benchmark and the correctness oracle: every checker
    /// falls back to expanding lib types into its own store. Diagnostics are
    /// byte-identical either way and across `--checkers=N`.
    no_frozen_store: bool = false,
    /// Disable the instantiation caching layer (memoized `instantiate`,
    /// map interning, constraint + type-node memos) — the correctness oracle
    /// and benchmark "before" leg. Diagnostics are byte-identical either way
    /// and across `--checkers=N`; the depth/count limits stay active.
    no_inst_cache: bool = false,
    /// Print a by-construct histogram of out-of-subset syntax (census) —
    /// the frequency table that prioritizes upcoming feature work.
    census: bool = false,
    /// Dump the instantiation-demand profile (`src/checker/prof.zig`) to
    /// stderr at the end of each checker: where a statement's instantiation
    /// budget goes, by call site / root type / type kind / expanded symbol.
    /// A diagnostic instrument; pair with `--checkers=1`.
    inst_profile: bool = false,
    /// `--inst-focus=<type-id>`: restrict the profile's per-type histogram to
    /// one top-level substitution root (see `prof.focus_root`). Implies
    /// `--inst-profile`.
    inst_focus: u32 = 0,
    /// `--eager-members`: materialize an interface/class reference's whole
    /// member table at every consumer, the way the checker did before the lazy
    /// member route landed (see `lazyTableOf`). A bisect leg — any diagnostic
    /// movement the route causes is visible as a key-set diff against this
    /// flag in the same binary.
    eager_members: bool = false,
    /// `--lazy-stats`: dump the lazy relation route.s hit/bail tally to stderr
    /// at seal. A diagnostic instrument; pair with `--checkers=1`.
    lazy_stats: bool = false,
    /// `--decl-profile`: dump the declaration-window time split to stderr at
    /// seal (see the second half of `checker/prof.zig`). A diagnostic
    /// instrument; pair with `--checkers=1`.
    decl_profile: bool = false,
    /// `--mem-profile`: dump each checker instance's per-container capacity
    /// breakdown, its demand-zeroed arrays' resident share, and its footprint
    /// timeline to stderr at seal (see `checker/memprof.zig`).
    mem_profile: bool = false,
    /// `--inst-memo-bits=N`: override the instantiation memo's slot count
    /// (`checker/memo.zig`'s `default_bits`). 0 = leave the default alone. A
    /// measurement aid — the memo's size is the per-checker footprint's single
    /// largest tunable.
    inst_memo_bits: u6 = 0,
    /// `--dup-profile`: implies `--decl-profile` and additionally records,
    /// per memoizable declaration unit, the set of OWNED files that demand
    /// it — the input to the partition-quality question. Pair with
    /// `--checkers=1`; see the cross-checker duplication section of
    /// `checker/prof.zig`.
    dup_profile: bool = false,
    /// `--partition-file=<path>`: benchmark aid; override the file->checker
    /// partition with an externally computed one (see the read site).
    partition_file: ?[]const u8 = null,
    /// null = auto (pretty iff stderr is a TTY).
    pretty: ?bool = null,
    project: ?[]const u8 = null,
    workers: ?usize = null,
    checkers: ?usize = null,
    repeat: usize = 1,
    paths: []const []const u8 = &.{},
};

/// Routes diagnostics to the plain machine format or the pretty renderer,
/// tracking totals for the tsc-style summary line.
const Emitter = struct {
    out: *Io.Writer,
    pretty: bool,
    total: usize = 0,
    files_with: usize = 0,
    cur_file_had: bool = false,
    first_path: []const u8 = "",
    first_line: u32 = 0,

    fn beginFile(e: *Emitter) void {
        e.cur_file_had = false;
    }

    fn emit(
        e: *Emitter,
        path: []const u8,
        src: *const Source,
        span: ztsc.source.Span,
        ts_code: u16,
        msg: []const u8,
    ) !void {
        const lc = src.lineCol(@min(span.start, @as(u32, @intCast(src.bytes.len))));
        if (e.total == 0) {
            e.first_path = path;
            e.first_line = lc.line + 1;
        }
        e.total += 1;
        if (!e.cur_file_had) {
            e.cur_file_had = true;
            e.files_with += 1;
        }
        if (e.pretty) {
            try ztsc.render.renderPretty(e.out, true, path, src.bytes, src.line_starts, span, ts_code, msg);
        } else if (ts_code != 0) {
            try e.out.print("{s}:{d}:{d}: error TS{d}: {s}\n", .{ path, lc.line + 1, lc.col + 1, ts_code, msg });
        } else {
            try e.out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, msg });
        }
    }
};

/// A unit of discovery work handed to a worker: one file to front-end.
/// The path slice lives in the main arena and is stable for the run.
const WorkItem = struct {
    file: modules.FileId,
    path: []const u8,
};

/// Per-file completion message a worker sends back to the main thread:
/// the sealed front-end outputs plus per-phase timings. Payloads live in
/// the worker's arena and are read-only once the message is pushed.
const Completion = struct {
    file: modules.FileId,
    src: ?Source = null,
    tree: ?*Ast = null,
    bind: ?*Bind = null,
    err: ?anyerror = null,
    /// The file's own path, interned before it is parsed — the first string
    /// this file contributes to the program-wide interning order (see the
    /// renumbering block below). 0 for the lib shards, whose atoms are already
    /// pinned, and for a file that never loaded.
    path_atom: ztsc.intern.Atom = 0,
    load_ns: u64 = 0,
    parse_ns: u64 = 0,
    bind_ns: u64 = 0,
};

/// Unbounded FIFO channel (mutex + condition). Buffer memory comes from
/// the channel's own arena and is only touched under the lock, so the
/// channel is safe with any number of producers and consumers. Message
/// passing is the only worker<->main communication during discovery; the
/// module graph itself stays main-thread-owned with no locks.
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
const Worker = struct {
    arena: std.heap.ArenaAllocator,
    /// Scratch space for benchmark re-runs (`--repeat`); reset between runs.
    scratch: std.heap.ArenaAllocator,
    /// Segments the worker's small source files are packed into, so the
    /// front end pays no per-file page rounding. Private to the worker,
    /// which is what makes the pack's bump cursor lock-free.
    pack: ztsc.source.Pack = .{},
    thread: std.Thread = undefined,
    files_loaded: usize = 0,
    /// The grammar options every file this worker parses is parsed under
    /// (`jsx` is per-file and filled in at the call site). Settled from the
    /// tsconfig before any worker is spawned, so it needs no synchronization.
    parse_opts: parser.Opts = .{},

    fn discoverRun(
        w: *Worker,
        io: Io,
        gpa: std.mem.Allocator,
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
        gpa: std.mem.Allocator,
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
        else if (ztsc.paths.anyModuleSourceFor(path)) |any_bytes|
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
        w.files_loaded += 1;
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

/// Check-work (AST nodes to walk) below which a run drops to two checkers.
///
/// A checker instance is not free. Each carries its own type-store overlay,
/// per-symbol state arrays, scratch/instantiation arenas, relation and
/// instantiation caches, thread, and its thread's share of the general
/// allocator's size-class slabs — measured at ~0.35 MB of fixed state per
/// instance on ajv, against ~90 KB of types the instance actually interns.
/// Adding instances also re-materializes lib types once per instance that
/// reaches them.
///
/// That fixed cost is worth paying when there is enough work to spread, and
/// the corpus shows the trade inverting sharply around this size. Going from
/// four checkers to two (median of 11 runs / 5 runs):
///
///   chalk       21.1k nodes   RSS -7.8%   wall +8.1%
///   @types/prop-types 21.0k   RSS -7.4%   wall +6.9%
///   ajv         28.0k nodes   RSS -11.4%  wall +1.7%
///   ---- threshold ----
///   date-fns    36.8k nodes   RSS -2.2%   wall +7.6%
///   typebox     37.0k nodes   RSS -0.3%   wall +14.8%
///   @types/react 101.6k       RSS -7.7%   wall +14.9%
///   zod         98.2k nodes   RSS -6.8%   wall +21.9%
///
/// Below the line the memory saved is large and the wall cost small; above
/// it the wall cost multiplies while the memory saving collapses. An
/// explicit `--checkers=N` always wins over this.
///
/// Diagnostics are unaffected: output is byte-identical for any checker
/// count (see the determinism tests), so this only moves the resource
/// trade-off, never the result.
const small_program_nodes: u64 = 32_000;

/// Check-work above which a program is large enough for the
/// declaration-surface test below to apply at all.
const large_program_nodes: u64 = 256_000;

/// Parsed-to-checked node ratio above which a large program drops to two
/// checkers: how much declaration surface each instance must re-materialize
/// per unit of code it actually walks.
///
/// A checker instance does NOT split declaration work. Measured on immich, the
/// set of distinct canonical types the program needs is invariant in checker
/// count (2.51 M at one checker, ~2.5 M at four), but four checkers BUILD
/// 7.64 M of them — 3.05x redundancy, with 87-93% of each instance's types
/// also present in another's arena. The reason is structural rather than a bad
/// partition: a checker's demand closure grows LOGARITHMICALLY in the files it
/// owns (1 file 1.437 M types, 4 files 1.519 M, 16 files 1.740 M, 500 files
/// 1.918 M), so splitting the files four ways splits the work ~1.3 ways. Four
/// maximally different partitions — the shipped one, contiguous BFS ranges,
/// random, and a demand-closure-optimized search — span 1.8% in total types,
/// and the random one is not the worst.
///
/// What that redundancy costs tracks the declaration surface, because that is
/// what each instance re-materializes. `check_nodes` alone cannot see it —
/// immich (437,226) and excalidraw (409,224) are 7% apart and want DIFFERENT
/// checker counts. The ratio does see it (median of 5, this host):
///
///   immich      2.61 ratio   c2 1.611 s / 384 MB   c4 1.844 s / 520 MB
///   excalidraw  1.78 ratio   c2 0.398 s / 112 MB   c4 0.308 s / 120 MB
///   8 packages  1.00 ratio   c4 faster than c2 on every one
///
/// immich at four checkers is strictly dominated — slower AND 136 MB heavier
/// than at two — so this is not a memory-for-time trade, it is a bad operating
/// point. excalidraw, nearly the same size, still pays off at four.
///
/// Both conditions are deliberately narrow: small and mid-size programs are
/// untouched, and a large program with an ordinary dependency surface keeps
/// four. Diagnostics are unaffected — output is byte-identical for any checker
/// count (the determinism tests), so this only moves the resource trade-off.
///
/// **Evidentiary limit, stated because this moves a shipped default:** the
/// threshold separates exactly two applications. The axis is mechanistic
/// rather than fitted, but the boundary (1.78 vs 2.61) rests on one inversion.
/// A large program whose declaration surface is bulky but cheap to materialize
/// would be misclassified and would lose wall. Re-validate against outline,
/// social-app and vscode when those checkouts are restored.
const declaration_heavy_ratio: u64 = 220; // hundredths, i.e. 2.20x

/// Whether extra checker instances would RE-MATERIALIZE this program's
/// declaration surface rather than split it — large, and carrying much more
/// parsed surface than it walks. Integer-only, so the answer cannot drift
/// with floating-point rounding across hosts.
///
/// Two independent decisions key on this, for the same reason: how many
/// checkers to run, and whether an instance should size its type-store
/// reserve from the whole program or from its own partition.
pub fn declarationHeavy(check_nodes: u64, parsed_nodes: u64) bool {
    return check_nodes >= large_program_nodes and
        parsed_nodes * 100 >= check_nodes * declaration_heavy_ratio;
}

fn defaultCheckers(
    explicit: ?usize,
    cpu_count: usize,
    check_nodes: u64,
    parsed_nodes: u64,
) usize {
    if (explicit) |n| return n;
    const wide = @min(4, cpu_count);
    // Too little work to repay a second instance's fixed state.
    if (check_nodes < small_program_nodes) return @min(wide, 2);
    // Extra instances would duplicate the declaration work, not divide it.
    if (declarationHeavy(check_nodes, parsed_nodes)) return @min(wide, 2);
    return wide;
}

/// One checker instance: checks its partition on its own thread.
const CheckerTask = struct {
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    owned: []const modules.FileId = &.{},
    /// Shared frozen base type store, or null under
    /// `--no-frozen-store`. Read-only; the same pointer is handed to every
    /// task so all overlays share one base.
    base: ?*const types.Store = null,
    /// Enable the instantiation caching layer (`false` under
    /// `--no-inst-cache`).
    inst_cache: bool = true,
    /// Node count to size this instance's type-store reserve from, or 0 to
    /// size it from its own partition. Non-zero only for a program whose
    /// declaration surface is not divisible (`declaration_heavy_ratio`),
    /// where every instance interns roughly the whole program's types.
    type_reserve_hint: usize = 0,
    result: ?checker.Check = null,
    err: ?anyerror = null,
    ns: u64 = 0,

    fn run(
        t: *CheckerTask,
        io: Io,
        gpa: std.mem.Allocator,
        interner: *Interner,
        prog: *const modules.Program,
    ) void {
        const timer = Timer.start(io);
        t.result = checker.checkFiles(t.arena.allocator(), io, gpa, interner, prog, t.owned, t.base, t.inst_cache, t.type_reserve_hint) catch |err| blk: {
            t.err = err;
            break :blk null;
        };
        t.ns = timer.readNs();
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var bad_arg: []const u8 = "";
    const cli = parseArgs(arena, args, &bad_arg) catch |err| {
        switch (err) {
            error.UnknownFlag => std.debug.print("ztsc: unknown option '{s}'\n", .{bad_arg}),
            error.BadFlagValue => std.debug.print("ztsc: bad value for option '{s}'\n", .{bad_arg}),
            error.MissingFlagValue => std.debug.print("ztsc: option '{s}' needs a value\n", .{bad_arg}),
            else => return err,
        }
        std.debug.print("try 'ztsc --help'\n", .{});
        std.process.exit(2);
    };

    // Write-once, before any checker thread exists (see `prof.profile_on`).
    checker.prof_zig.profile_on = cli.inst_profile;
    checker.prof_zig.focus_root = cli.inst_focus;
    checker.lazy_zig.lazy_members_on = !cli.eager_members;
    checker.lazy_zig.stats_on = cli.lazy_stats;
    checker.prof_zig.decl_prof_on = cli.decl_profile or cli.dup_profile;
    checker.prof_zig.dup_prof_on = cli.dup_profile;
    checker.memprof_zig.mem_prof_on = cli.mem_profile;
    checker.memo_zig.bits_override = cli.inst_memo_bits;

    if (cli.help) {
        try out.print("{s}", .{usage});
        try out.flush();
        return;
    }
    if (cli.version) {
        try out.print("ztsc {s}\n", .{ztsc.version});
        try out.flush();
        return;
    }
    if (cli.paths.len != 0 and cli.project != null) {
        std.debug.print("ztsc: option '--project' cannot be mixed with source files on the command line\n", .{});
        std.process.exit(2);
    }

    // Everything from here on is real work, so `total` starts here rather than
    // after config loading: reading and expanding a tsconfig walks the project
    // tree, which on a large repo costs more than any single later phase and
    // must not hide outside the measured window.
    const total_timer = Timer.start(io);

    // With no file arguments, drive the run from a tsconfig.json.
    var entry_paths = cli.paths;
    // The `config` phase: discovery, `extends` chasing, the `include` walk and
    // `collectAutoTypes`. Stays 0 when the run is driven by CLI file arguments.
    var config_ns: u64 = 0;
    var paths_map: ?ztsc.tsconfig.Paths = null;
    // The tsconfig `lib` field (null when no config / no field), consulted below
    // to pick the built-in lib blobs.
    var config_lib: ?[]const []const u8 = null;
    // tsconfig skipLibCheck/skipDefaultLibCheck (false when no config / unset).
    var config_skip_lib = false;
    // tsconfig skipLibCheck only (superset: skips ALL .d.ts, not just the lib).
    var config_skip_all_lib = false;
    // tsconfig resolveJsonModule + baseUrl (for `*.json` module resolution).
    var config_resolve_json = false;
    var config_base_url: ?[]const u8 = null;
    // tsconfig allowJs (resolve JS-only deps as `any`) + effective noImplicitAny.
    var config_allow_js = false;
    var config_no_implicit_any = true;
    // tsconfig experimentalDecorators (legacy decorator dialect; grammar + the
    // decorator signature check both change). See `tsconfig.Config`.
    var config_experimental_decorators = false;
    // tsconfig noUncheckedSideEffectImports (tsc's default is off).
    var config_no_unchecked_side_effect_imports = false;
    // tsconfig `types: [… "*" …]` — TS2580 instead of TS2591 (see LinkOpts).
    var config_types_wildcard = false;
    // Effective allowSyntheticDefaultImports. With no tsconfig (bare file
    // arguments) ztsc still resolves with the bundler algorithm, and tsc's rule
    // makes the flag default to true under bundler resolution.
    var config_allow_synthetic_default = true;
    // `<jsxImportSource>/jsx-runtime` under the automatic JSX runtime; null
    // under the classic runtime (global `JSX` namespace only).
    var config_jsx_runtime_module: ?[]const u8 = null;
    if (cli.paths.len == 0) {
        const config_timer = Timer.start(io);
        const config_path: []const u8 = blk: {
            if (cli.project) |p| {
                // Accept either the config file or its directory.
                if (Io.Dir.cwd().openDir(io, p, .{})) |d| {
                    var dir = d;
                    dir.close(io);
                    const trimmed = std.mem.trimEnd(u8, p, "/");
                    break :blk try std.fmt.allocPrint(arena, "{s}/tsconfig.json", .{trimmed});
                } else |_| {
                    break :blk p;
                }
            }
            break :blk (try ztsc.tsconfig.findUpward(io, arena)) orelse {
                std.debug.print("ztsc: no input files and no tsconfig.json found\ntry 'ztsc --help'\n", .{});
                std.process.exit(2);
            };
        };
        const cfg = ztsc.tsconfig.load(io, arena, config_path) catch |err| {
            switch (err) {
                error.NotFound => std.debug.print("ztsc: cannot read '{s}'\n", .{config_path}),
                error.SyntaxError => std.debug.print("ztsc: '{s}' is not valid JSON\n", .{config_path}),
                error.StrictFalse => std.debug.print(
                    "ztsc: '{s}' sets \"strict\": false, but ztsc only implements strict-mode semantics.\n" ++
                        "Please remove the option (or set it to true) to check this project with ztsc.\n",
                    .{config_path},
                ),
                error.OutOfMemory => return error.OutOfMemory,
            }
            std.process.exit(2);
        };
        for (cfg.warnings) |w| std.debug.print("ztsc: warning: {s}\n", .{w});
        if (cli.verbose) {
            for (cfg.notes) |n| std.debug.print("ztsc: note: {s}\n", .{n});
        }
        if (cfg.root_files.len == 0) {
            std.debug.print("ztsc: no inputs were found in config file '{s}'\n", .{config_path});
            std.process.exit(2);
        }
        // Real sources first (their order/emptiness drove the check above), then
        // the auto-included `@types/*` ambient roots (tsc's default typeRoots).
        if (cfg.auto_type_files.len == 0) {
            entry_paths = cfg.root_files;
        } else {
            const combined = try arena.alloc([]const u8, cfg.root_files.len + cfg.auto_type_files.len);
            @memcpy(combined[0..cfg.root_files.len], cfg.root_files);
            @memcpy(combined[cfg.root_files.len..], cfg.auto_type_files);
            entry_paths = combined;
        }
        paths_map = cfg.paths;
        config_lib = cfg.lib;
        config_skip_lib = cfg.skip_lib_check;
        config_skip_all_lib = cfg.skip_all_lib_check;
        config_resolve_json = cfg.resolve_json_module;
        config_base_url = cfg.base_url;
        config_allow_js = cfg.allow_js;
        config_no_implicit_any = cfg.no_implicit_any;
        config_experimental_decorators = cfg.experimental_decorators;
        config_no_unchecked_side_effect_imports = cfg.no_unchecked_side_effect_imports;
        config_types_wildcard = cfg.types_wildcard;
        config_allow_synthetic_default = cfg.allow_synthetic_default_imports;
        config_jsx_runtime_module = cfg.jsx_runtime_module;
        config_ns = config_timer.readNs();
    }

    // Effective decision: skip type-checking the embedded pre-verified lib?
    // Default is to check it (matching tsc/tsgo). The CLI flag, when given,
    // overrides the tsconfig `skipLibCheck`/`skipDefaultLibCheck` value.
    const skip_default_lib_check = cli.skip_default_lib_check orelse config_skip_lib;

    // Effective decision: honor `skipLibCheck` (the superset of
    // `skipDefaultLibCheck`)? When set, no diagnostic located in ANY `.d.ts`
    // file is surfaced — the default lib, dependency `.d.ts`, and project-local
    // `.d.ts` alike — so ztsc's output matches tsc's on valid `.d.ts`. Those
    // files are still parsed/bound/linked so their types flow into `.ts`/`.tsx`
    // checking. Only the tsconfig drives this; the `--skip-default-lib-check`
    // CLI flag stays default-lib-only (tsc's `--skipDefaultLibCheck`).
    const skip_all_dts_check = config_skip_all_lib;

    // Which built-in lib blobs to inject. Precedence: --noLib wins (nothing),
    // then an explicit --lib flag, then the tsconfig `lib` field, else the
    // default set (ES-core + DOM — tsgo's target-esnext default includes DOM).
    const lib_set: libs.LibSet = if (cli.no_lib)
        .none
    else
        libs.resolveLibSet(cli.lib orelse config_lib);

    // Pretty diagnostics: tsc-style excerpts + colors; default follows the
    // terminal, --pretty / --pretty=false forces.
    const pretty = cli.pretty orelse (Io.File.stderr().isTty(io) catch false);

    var interner = Interner.init();
    defer interner.deinit(gpa);

    // Not capped by the entry count: discovery finds more files.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @max(1, cli.workers orelse cpu_count);
    const workers = try arena.alloc(Worker, n_workers);
    for (workers) |*w| w.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .parse_opts = .{ .experimental_decorators = config_experimental_decorators },
    };

    // Transient allocator for module resolution: candidate path strings and
    // package.json bodies are discarded after each file's specifiers
    // resolve. Mirrors the serial buildProgram path (modules.zig). Reset per
    // file so it never grows past one file's resolution working set.
    var resolve_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer resolve_scratch.deinit();

    // Resolution memo: the same specifier imported from many files
    // resolves once. Lives in `arena` (spans the whole discovery run). Created
    // before the program roots are seeded because they, too, go through its
    // canonical-path step (see below).
    var rcache = resolve.ResolveCache.init(arena, !cli.no_resolve_cache, .{
        .resolve_json = config_resolve_json,
        .base_url = config_base_url,
        .allow_js = config_allow_js,
    });

    // --- Single-owner discovery (no wave barrier) --------------------------
    // The main thread is the sole owner of the module graph and seen-set;
    // workers front-end one file at a time and push completions; the main
    // thread resolves each completion as it arrives and enqueues newly
    // discovered files immediately.
    var paths: std.ArrayList([]const u8) = .empty;
    var path_ids: std.StringHashMapUnmanaged(u32) = .empty;
    // Inject the selected built-in lib blobs as the first entries (files 0..).
    // Their synthetic paths route to the embedded sources in the worker front
    // end; their top-level decls become the program globals. Empty under
    // --noLib / lib:[].
    var lib_buf: [libs.max_lib_files]libs.LibFile = undefined;
    for (libs.libFiles(lib_set, &lib_buf)) |lf| {
        try path_ids.put(arena, lf.path, @intCast(paths.items.len));
        try paths.append(arena, lf.path);
    }
    // Program roots. A root under `node_modules` — in practice the auto-included
    // `@types/*` ambient roots, which pnpm exposes as symlinks into its store —
    // is keyed by its canonical path, the same identity the module resolver
    // gives the very same file when an `import` reaches it. Without that step
    // `node_modules/@types/react/index.d.ts` and the store path behind the
    // symlink are two files with two symbol universes. Outside `node_modules`
    // the call is a no-op, so project roots keep the path the user typed (and
    // pay no realpath syscall).
    for (entry_paths) |p| {
        const norm = try ztsc.paths.normalizePath(arena, p);
        const key = try rcache.canonicalPath(io, resolve_scratch.allocator(), Io.Dir.cwd(), norm);
        const gop = try path_ids.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(paths.items.len);
            try paths.append(arena, key);
        }
    }
    _ = resolve_scratch.reset(.retain_capacity);
    const n_entries = paths.items.len;

    var results: std.ArrayList(?Source) = .empty;
    var trees: std.ArrayList(?*Ast) = .empty;
    var binds: std.ArrayList(?*Bind) = .empty;
    var errs: std.ArrayList(?anyerror) = .empty;
    // Per-file path atom, in the order the front end interned it (first for
    // the file); feeds the deterministic renumbering after discovery.
    var path_atoms: std.ArrayList(ztsc.intern.Atom) = .empty;
    var spec_atoms_all: std.ArrayList([]ztsc.intern.Atom) = .empty;
    var spec_files_all: std.ArrayList([]modules.FileId) = .empty;
    // Per-file resolved FileIds in first-occurrence specifier order
    // (unresolved skipped) — the edges of the deterministic BFS below.
    var edge_lists: std.ArrayList([]const modules.FileId) = .empty;
    // Per-file `/// <reference types="X" />` directives that resolved to
    // nothing; the linker replays them as TS2688.
    var type_ref_misses_all: std.ArrayList([]const modules.TypeRefMiss) = .empty;

    var load_ns: u64 = 0;
    var parse_ns: u64 = 0;
    var bind_ns: u64 = 0;
    var resolve_ns: u64 = 0;
    var renumber_ns: u64 = 0;

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
    // output are program data — so they are only released at the end.
    var lib_fe = try libs.frontEndLibs(arena, io, gpa, &interner, lib_set, n_workers);
    defer lib_fe.deinit();
    const lib_units = lib_fe.units;

    // Everything interned up to here came from a single-threaded phase, so its
    // ids are already the same on every run and the lib's sealed binder output
    // (which is kept, never re-bound) can keep pointing at them. Ids handed out
    // past this point are scheduling-dependent and get reassigned once
    // discovery is done — see the renumbering block below.
    interner.freezePrefix();

    const discover_timer = Timer.start(io);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.discoverRun, .{
            w, io, gpa, &interner, cli.repeat, &work, &done,
        });
    }

    var outstanding: usize = 0;
    try growPerFile(arena, paths.items.len, &results, &trees, &binds, &errs, &path_atoms, &spec_atoms_all, &spec_files_all, &edge_lists, &type_ref_misses_all);
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
    for (paths.items[lib_units.len..], lib_units.len..) |p, i| {
        try work.push(.{ .file = @intCast(i), .path = p });
        outstanding += 1;
    }

    // FileId of the auto-injected `@types/node` (null until the first Node
    // built-in import pulls it in); see the discovery loop below.
    var node_types_fid: ?u32 = null;
    // FileId of the auto-injected `<jsxImportSource>/jsx-runtime` (null until
    // the first `.tsx` file pulls it in); see the discovery loop below.
    var jsx_runtime_fid: ?u32 = null;
    resolve.resetFsProbeCount();

    while (outstanding > 0) {
        // The done channel is never closed while work is outstanding.
        const c = done.pop().?;
        outstanding -= 1;
        const i = c.file;
        results.items[i] = c.src;
        trees.items[i] = c.tree;
        binds.items[i] = c.bind;
        errs.items[i] = c.err;
        path_atoms.items[i] = c.path_atom;
        load_ns += c.load_ns;
        parse_ns += c.parse_ns;
        bind_ns += c.bind_ns;

        // Resolve this file's module specifiers (main thread only;
        // discovers files).
        const resolve_timer = Timer.start(io);
        var atoms: std.ArrayList(ztsc.intern.Atom) = .empty;
        var files: std.ArrayList(modules.FileId) = .empty;
        var ref_files: std.ArrayList(modules.FileId) = .empty;
        const known_before = paths.items.len;
        if (binds.items[i]) |b| {
            const scratch = resolve_scratch.allocator();
            var seen: std.AutoHashMapUnmanaged(ztsc.intern.Atom, void) = .empty;
            defer seen.deinit(gpa);
            for (b.imports) |rec| {
                try resolveSpecInto(arena, scratch, gpa, io, &interner, &rcache, paths_map, config_resolve_json, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
            }
            for (b.exports) |rec| {
                if (rec.module != 0) {
                    try resolveSpecInto(arena, scratch, gpa, io, &interner, &rcache, paths_map, config_resolve_json, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
                }
            }
            // Pull @types/node into the program on the first Node built-in
            // import (`node:fs`, `path`, …), like tsc auto-including @types: its
            // ambient `declare module "fs"` / `declare module "node:fs"` blocks
            // then resolve those specifiers. Injected once, discovered like a
            // triple-slash reference so the deterministic BFS reaches it (and,
            // via its own `/// <reference>` refs, every submodule .d.ts).
            if (node_types_fid == null) {
                for (b.imports) |rec| {
                    if (!ztsc.paths.isNodeBuiltin(interner.lookup(io, rec.module))) continue;
                    if (try rcache.resolve(io, scratch, Io.Dir.cwd(), paths.items[i], "@types/node")) |np| {
                        const pgop = try path_ids.getOrPut(arena, np);
                        if (pgop.found_existing) {
                            node_types_fid = pgop.value_ptr.*;
                        } else {
                            const stable = try arena.dupe(u8, np);
                            pgop.key_ptr.* = stable;
                            node_types_fid = @intCast(paths.items.len);
                            pgop.value_ptr.* = node_types_fid.?;
                            try paths.append(arena, stable);
                        }
                        try ref_files.append(arena, node_types_fid.?);
                    }
                    break;
                }
            }
            // Under the automatic JSX runtime the `JSX` namespace is an export
            // of `<jsxImportSource>/jsx-runtime`, not a global — @types/react 19
            // ships no `declare global { namespace JSX }` at all. tsc puts that
            // module in the program for every JSX file; do the same on the first
            // `.tsx` we see, discovered like a triple-slash reference so the
            // deterministic BFS reaches it. Its FileId is handed to the checker
            // (`Program.jsx_runtime_file`) as the JSX-namespace fallback.
            if (jsx_runtime_fid == null and config_jsx_runtime_module != null and
                std.mem.endsWith(u8, paths.items[i], ".tsx"))
            {
                if (try rcache.resolve(io, scratch, Io.Dir.cwd(), paths.items[i], config_jsx_runtime_module.?)) |jp| {
                    const pgop = try path_ids.getOrPut(arena, jp);
                    if (pgop.found_existing) {
                        jsx_runtime_fid = pgop.value_ptr.*;
                    } else {
                        const stable = try arena.dupe(u8, jp);
                        pgop.key_ptr.* = stable;
                        jsx_runtime_fid = @intCast(paths.items.len);
                        pgop.value_ptr.* = jsx_runtime_fid.?;
                        try paths.append(arena, stable);
                    }
                    try ref_files.append(arena, jsx_runtime_fid.?);
                }
            }
            // Triple-slash `/// <reference>` directives pull extra files into
            // the program — program inputs, not import bindings. Their
            // resolved ids join the discovery edge list so the deterministic
            // BFS renumbering below reaches them.
            if (results.items[i]) |src| {
                var misses: std.ArrayList(modules.TypeRefMiss) = .empty;
                for (try resolve.scanReferences(scratch, src.bytes)) |ref| {
                    const rfid = try discoverReferenceInto(arena, scratch, io, &rcache, paths.items[i], ref, &path_ids, &paths);
                    try ref_files.append(arena, rfid);
                    // An unresolvable `types=` directive is tsc's TS2688; the
                    // linker reports it, since only this loop knows resolution
                    // failed. `path=` misses are TS6053, not implemented.
                    if (rfid == modules.no_file and ref.kind == .types) {
                        try misses.append(arena, modules.typeRefMiss(ref));
                    }
                }
                type_ref_misses_all.items[i] = misses.items;
            }
            _ = resolve_scratch.reset(.retain_capacity);
        }
        var edges: std.ArrayList(modules.FileId) = .empty;
        for (files.items) |fid| {
            if (fid != modules.no_file) try edges.append(arena, fid);
        }
        for (ref_files.items) |fid| {
            if (fid != modules.no_file) try edges.append(arena, fid);
        }
        edge_lists.items[i] = edges.items;
        sortSpecPairs(atoms.items, files.items);
        spec_atoms_all.items[i] = atoms.items;
        spec_files_all.items[i] = files.items;

        // Enqueue newly discovered files right away.
        try growPerFile(arena, paths.items.len, &results, &trees, &binds, &errs, &path_atoms, &spec_atoms_all, &spec_files_all, &edge_lists, &type_ref_misses_all);
        for (known_before..paths.items.len) |nf| {
            try work.push(.{ .file = @intCast(nf), .path = paths.items[nf] });
            outstanding += 1;
        }
        resolve_ns += resolve_timer.readNs();
    }
    work.close();
    for (workers) |*w| w.thread.join();
    const discover_ns = discover_timer.readNs();
    const n_files = paths.items.len;

    // --- Deterministic file order (graph-derived, not scheduling-derived) --
    // Completion order depends on scheduling; output order must not. BFS
    // from the entry files, tie-break = specifier order within each
    // importing file (the exact order wavefront discovery produced), then
    // permute every per-file table into that order. Everything downstream
    // (link, checker partition, printing) sees only the renumbered ids, so
    // output is byte-identical for any --workers/--checkers combination.
    {
        const order = try arena.alloc(u32, n_files); // BFS position -> discovery id
        const new_ids = try arena.alloc(u32, n_files); // discovery id -> BFS position
        @memset(new_ids, modules.no_file);
        var tail: usize = 0;
        for (0..n_entries) |i| {
            new_ids[i] = @intCast(tail);
            order[tail] = @intCast(i);
            tail += 1;
        }
        var head: usize = 0;
        while (head < tail) : (head += 1) {
            for (edge_lists.items[order[head]]) |fid| {
                if (new_ids[fid] != modules.no_file) continue;
                new_ids[fid] = @intCast(tail);
                order[tail] = fid;
                tail += 1;
            }
        }
        // Every discovered file was discovered through a recorded edge,
        // so the BFS reaches all of them.
        std.debug.assert(tail == n_files);

        try permuteInPlace([]const u8, arena, paths.items, order);
        try permuteInPlace(?Source, arena, results.items, order);
        try permuteInPlace(?*Ast, arena, trees.items, order);
        try permuteInPlace(?*Bind, arena, binds.items, order);
        try permuteInPlace(?anyerror, arena, errs.items, order);
        try permuteInPlace(ztsc.intern.Atom, arena, path_atoms.items, order);
        try permuteInPlace([]ztsc.intern.Atom, arena, spec_atoms_all.items, order);
        try permuteInPlace([]modules.FileId, arena, spec_files_all.items, order);
        try permuteInPlace([]const modules.TypeRefMiss, arena, type_ref_misses_all.items, order);
        if (jsx_runtime_fid) |f| jsx_runtime_fid = new_ids[f];
        // Remap the resolved FileIds inside the spec maps.
        for (spec_files_all.items) |spec_files| {
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
        var order: std.ArrayList(ztsc.intern.Atom) = .empty;
        defer order.deinit(gpa);
        // The lib shards are bound before the pool starts; their atoms are in
        // the frozen prefix and never move.
        for (lib_units.len..n_files) |i| {
            if (path_atoms.items[i] != 0) try order.append(gpa, path_atoms.items[i]);
            if (binds.items[i]) |b| try order.appendSlice(gpa, b.first_touch);
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
            for (binds.items[lib_units.len..]) |maybe_bind| {
                if (maybe_bind) |b| try b.remapAtoms(gpa, rn.map);
            }
            for (spec_atoms_all.items, spec_files_all.items) |spec_atoms, spec_files| {
                for (spec_atoms) |*a| a.* = rn.map[a.*];
                sortSpecPairs(spec_atoms, spec_files);
            }
        }
        renumber_ns = renumber_timer.readNs();
    }

    // --- Link (serial): program assembly + import/export tables ----------
    const link_timer = Timer.start(io);
    const prog_files = try arena.alloc(modules.ProgFile, n_files);
    var empty_tree: ?*Ast = null;
    var empty_bind: ?*Bind = null;
    for (0..n_files) |i| {
        // Substitute an empty file for load/parse failures so ids stay
        // dense (the error is reported below).
        var tree = trees.items[i];
        var bnd = binds.items[i];
        const src_bytes: []const u8 = if (results.items[i]) |s| s.bytes else "";
        if (tree == null or bnd == null) {
            if (empty_tree == null) {
                empty_tree = try arena.create(Ast);
                empty_tree.?.* = try parser.parse(arena, "");
                empty_bind = try arena.create(Bind);
                empty_bind.?.* = try binder.bind(arena, io, gpa, &interner, empty_tree.?, "", false);
            }
            tree = empty_tree;
            bnd = empty_bind;
        }
        prog_files[i] = .{
            .path = paths.items[i],
            .src = if (trees.items[i] == null) "" else src_bytes,
            .tree = tree.?,
            .bind = bnd.?,
            .specs = .{ .atoms = spec_atoms_all.items[i], .files = spec_files_all.items[i] },
            .type_ref_misses = type_ref_misses_all.items[i],
        };
    }
    const lr = try modules.link(arena, gpa, io, &interner, prog_files, .{
        .allow_synthetic_default = config_allow_synthetic_default,
        .no_implicit_any = config_no_implicit_any,
        .no_unchecked_side_effect_imports = config_no_unchecked_side_effect_imports,
        .types_wildcard = config_types_wildcard,
    });
    const links = lr.links;
    const prog = try arena.create(modules.Program);
    prog.* = .{
        .files = prog_files,
        .sym_base = lr.sym_base,
        .links = links,
        .globals = lr.globals,
        .merged = lr.merged,
        .ambient_exports = lr.ambient_exports,
        .ambient_specs = lr.ambient_specs,
        .constit_keys = lr.constit_keys,
        .constit_vals = lr.constit_vals,
        .export_equals_atom = lr.export_equals_atom,
        .dual_targets = lr.dual_targets,
        .no_implicit_any = config_no_implicit_any,
        .types_wildcard = config_types_wildcard,
        .experimental_decorators = config_experimental_decorators,
        .jsx_runtime_file = jsx_runtime_fid orelse modules.no_file,
    };
    const link_ns = link_timer.readNs();

    // --- Check (N independent checker instances) --------------------------------
    const check_timer = Timer.start(io);
    // File id -> owning checker, so per-file diagnostics can be reassembled
    // from the right checker below (replaces the old `i % n_checkers`).
    const file_owner = try arena.alloc(u32, n_files);

    // Cost-based partition, weighted by per-file AST node count
    // (≈ check cost, known post-parse) — see the run split below for how
    // the weights are spent. Built before the checker count is chosen,
    // because the total is what chooses it.
    const Item = struct { file: u32, cost: u64 };
    var items: std.ArrayList(Item) = .empty;
    try items.ensureTotalCapacity(arena, n_files);
    @memset(file_owner, 0);
    var check_nodes: u64 = 0;
    // Every parsed node, enqueued or not. The part that is NOT enqueued is the
    // declaration surface (`.d.ts` under skipLibCheck, the embedded lib under
    // skipDefaultLibCheck): never walked, but materialized on demand — once
    // per checker instance that reaches it. See `declaration_heavy_ratio`.
    var parsed_nodes: u64 = 0;
    for (0..n_files) |i| {
        if (trees.items[i]) |tree| parsed_nodes += tree.nodes.len;
        // Embedded lib files are parsed/bound/linked (globals, lazy type
        // expansion) and, by default, also enqueued to a checker so the
        // pre-verified lib is walked just like tsc/tsgo at their defaults.
        // `--skip-default-lib-check` (or tsconfig skipLibCheck/
        // skipDefaultLibCheck) drops them — pure time savings, since lib
        // diagnostics are never surfaced (tsc's skipDefaultLibCheck).
        if (skip_default_lib_check and libs.isLibPath(paths.items[i])) continue;
        // skipLibCheck: a non-lib `.d.ts` produces no surfaced check
        // diagnostics, and its types are resolved lazily on demand from
        // `.ts` files (not by walking it), so its check pass is dead work —
        // don't enqueue it. Pure time savings, deterministic (path-based).
        if (skip_all_dts_check and ztsc.paths.isDeclarationPath(paths.items[i])) continue;
        const cost: u64 = if (trees.items[i]) |tree| tree.nodes.len else 0;
        check_nodes += cost;
        items.appendAssumeCapacity(.{ .file = @intCast(i), .cost = cost });
    }

    const n_checkers: usize = @max(1, @min(defaultCheckers(cli.checkers, cpu_count, check_nodes, parsed_nodes), n_files));
    const tasks = try arena.alloc(CheckerTask, n_checkers);
    {
        const owned_lists = try arena.alloc(std.ArrayList(modules.FileId), n_checkers);
        for (owned_lists) |*l| l.* = .empty;
        // Locality-aware, balanced partition. File ids are BFS positions in
        // the import graph (see the renumbering above), so a contiguous id
        // range is import-adjacent and its dependency closures largely
        // overlap: checking that range on one checker materializes each
        // foreign type once instead of once per checker that reaches it.
        //
        // Pure contiguity (one range per checker) wins the locality but
        // loses the wall clock — node count mispredicts check time region by
        // region, so one checker straggles. Cutting the order into two
        // equal-node-weight runs per checker and dealing the runs
        // longest-first onto the least-loaded checker (LPT) keeps most of the
        // locality and pairs an expensive region with a cheap one. Measured
        // on a 6.1k-file project at --checkers=4: check 265 -> 242 ms, peak
        // RSS 226 -> 218 MB. k = 1 leaves a straggler; k >= 3 fragments the
        // locality without buying the balance back, and both measured slower
        // than k = 2, as did a boustrophedon deal, a DFS (subtree-contiguous)
        // order, and re-weighting `.d.ts` nodes.
        //
        // Deterministic: the order is the file ids, the weights are fixed
        // post-parse, and every tie breaks by run start / checker index, so
        // any --checkers=N still yields byte-identical diagnostics.
        const Run = struct { start: usize, end: usize, cost: u64 };
        var runs: std.ArrayList(Run) = .empty;
        {
            var total_cost: u64 = 0;
            for (items.items) |it| total_cost += it.cost;
            const n_runs = n_checkers * 2;
            var acc: u64 = 0;
            var run_base: u64 = 0;
            var start: usize = 0;
            var r: usize = 0;
            for (items.items, 0..) |it, idx| {
                acc += it.cost;
                // Cumulative target, so rounding never drifts across cuts.
                if (acc >= total_cost * (r + 1) / n_runs and r + 1 < n_runs) {
                    try runs.append(arena, .{ .start = start, .end = idx + 1, .cost = acc - run_base });
                    run_base = acc;
                    start = idx + 1;
                    r += 1;
                }
            }
            if (start < items.items.len)
                try runs.append(arena, .{ .start = start, .end = items.items.len, .cost = acc - run_base });
        }
        std.mem.sort(Run, runs.items, {}, struct {
            fn lessThan(_: void, x: Run, y: Run) bool {
                if (x.cost != y.cost) return x.cost > y.cost; // biggest first
                return x.start < y.start; // deterministic tie-break
            }
        }.lessThan);

        const loads = try arena.alloc(u64, n_checkers);
        @memset(loads, 0);
        for (runs.items) |run| {
            // Least-loaded checker; ties resolve to the lowest index.
            var best: usize = 0;
            for (loads[1..], 1..) |l, k| {
                if (l < loads[best]) best = k;
            }
            // Inside a run, walk biggest-first (the cost-partition order). Only the
            // run permutes, so every other run's [start,end) is untouched and
            // `run.cost` — an order-independent sum — still holds. Walk order
            // does not move ownership, but it does move peak RSS: leading with
            // the big files keeps their scratch peaks off the tail of a grown
            // arena, worth ~20 MB at --checkers=1 on a 6.1k-file project.
            const slice = items.items[run.start..run.end];
            std.mem.sort(Item, slice, {}, struct {
                fn lessThan(_: void, x: Item, y: Item) bool {
                    if (x.cost != y.cost) return x.cost > y.cost; // biggest first
                    return x.file < y.file; // deterministic tie-break
                }
            }.lessThan);
            for (slice) |it| {
                try owned_lists[best].append(arena, it.file);
                file_owner[it.file] = @intCast(best);
            }
            loads[best] += run.cost;
        }

        // BENCHMARK AID (`--partition-file=<path>`): replace the partition
        // above with an externally computed one — one `<file-id> <checker>`
        // pair per line, file ids as `--dup-profile` prints them. It exists
        // so a candidate partition can be MEASURED (total instantiate visits,
        // peak RSS) instead of modelled; see the cross-checker duplication
        // section of `src/checker/prof.zig`. Files the file does not mention
        // keep the partition's own assignment. Within a checker the walk stays
        // biggest-first, as above.
        if (cli.partition_file) |pf| {
            const text = Io.Dir.cwd().readFileAlloc(io, pf, arena, .limited(64 << 20)) catch |e| {
                std.debug.print("ztsc: cannot read --partition-file '{s}': {s}\n", .{ pf, @errorName(e) });
                std.process.exit(1);
            };
            for (owned_lists) |*l| l.* = .empty;
            var lines = std.mem.tokenizeAny(u8, text, "\r\n");
            while (lines.next()) |line| {
                var it = std.mem.tokenizeScalar(u8, line, ' ');
                const fid_s = it.next() orelse continue;
                const ck_s = it.next() orelse continue;
                const fid = std.fmt.parseInt(u32, fid_s, 10) catch continue;
                const ck = std.fmt.parseInt(u32, ck_s, 10) catch continue;
                if (fid >= n_files) continue;
                file_owner[fid] = @intCast(ck % n_checkers);
            }
            const cost_by_file = try arena.alloc(u64, n_files);
            @memset(cost_by_file, 0);
            for (items.items) |it| cost_by_file[it.file] = it.cost;
            for (items.items) |it| try owned_lists[file_owner[it.file]].append(arena, it.file);
            for (owned_lists) |*l| std.mem.sort(modules.FileId, l.items, cost_by_file, struct {
                fn lessThan(cost: []const u64, x: modules.FileId, y: modules.FileId) bool {
                    if (cost[x] != cost[y]) return cost[x] > cost[y];
                    return x < y;
                }
            }.lessThan);
        }

        // Shared frozen base type store (frozen-base piece 2): built
        // once, single-threaded here before any checker spawns, then handed to
        // every task read-only. Under `--no-frozen-store` each checker instead
        // expands lib types into its own store (the old path / oracle leg).
        // Lives in the top-level `arena` so it outlives all overlays.
        const base_store: ?*const types.Store = if (cli.no_frozen_store) null else blk: {
            const bs = try arena.create(types.Store);
            bs.* = try checker.buildBaseStore(arena);
            break :blk bs;
        };
        for (tasks, 0..) |*t, k| {
            t.* = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .owned = owned_lists[k].items,
                .base = base_store,
                .inst_cache = !cli.no_inst_cache,
                // Only when the surface is not divisible. On a program whose
                // work DOES partition (the `multi` corpus, ratio 1.00), the
                // whole-program estimate over-reserves ~4x and costs peak RSS
                // for nothing: 41.2 -> 45.0 MiB measured.
                .type_reserve_hint = if (declarationHeavy(check_nodes, parsed_nodes))
                    @intCast(parsed_nodes)
                else
                    0,
            };
        }
    }
    if (n_checkers == 1) {
        tasks[0].run(io, gpa, &interner, prog);
    } else {
        for (tasks) |*t| {
            t.thread = try std.Thread.spawn(.{}, CheckerTask.run, .{ t, io, gpa, &interner, prog });
        }
        for (tasks) |*t| t.thread.join();
    }
    const check_ns = check_timer.readNs();

    // --- Aggregate statistics ----------------------------------------------
    var files_ok: usize = 0;
    var total_bytes: usize = 0;
    var total_lines: usize = 0;
    var line_table_bytes: usize = 0;
    for (results.items) |maybe_src| {
        const src = maybe_src orelse continue;
        files_ok += 1;
        total_bytes += src.bytes.len;
        total_lines += src.lineCount();
        line_table_bytes += src.lineTableBytes();
    }

    // Token stats come from the retained `tree.tokens` (the only token
    // array the front end builds per file).
    var total_tokens: usize = 0;
    var token_bytes: usize = 0;
    var total_nodes: usize = 0;
    var node_bytes: usize = 0;
    var extra_bytes: usize = 0;
    var ast_token_bytes: usize = 0;
    // The injected libs' own diagnostics are never reported (the print
    // loop below skips them, matching tsc, which does not diagnose the
    // default lib), so they must not count toward the summary line or
    // the exit code either — otherwise a clean project exits 1 with
    // nothing printed. There may be several lib files (ES-core, DOM, the
    // console shim); `is_lib[i]` flags each by its synthetic path.
    const is_lib = try arena.alloc(bool, paths.items.len);
    for (paths.items, 0..) |p, i| is_lib[i] = libs.isLibPath(p);

    // Non-lib `.d.ts` files whose diagnostics are fully suppressed by
    // `skipLibCheck` (parse + bind + link + check), mirroring how the built-in
    // lib is suppressed. See the emit loop for why parser diagnostics are
    // dropped too (ztsc can't distinguish a genuine syntax error from a
    // parser-subset-gap cascade, and valid published `.d.ts` have neither).
    // Path-based, so identical for any --workers/--checkers count (determinism).
    const dts_skipped = try arena.alloc(bool, paths.items.len);
    for (paths.items, 0..) |p, i|
        dts_skipped[i] = skip_all_dts_check and !is_lib[i] and ztsc.paths.isDeclarationPath(p);

    // `@ts-nocheck` / `@ts-ignore` / `@ts-expect-error` suppression, scanned
    // from each file's comment trivia at parse time. Unlike `dts_skipped` this
    // only covers *semantic* diagnostics (bind + link + check); syntax errors
    // still report, as in tsc. Content-derived, so identical for any
    // --workers/--checkers count.
    const cdirs = try arena.alloc(ztsc.directives.File, paths.items.len);
    for (trees.items, 0..) |maybe_tree, i|
        cdirs[i] = if (maybe_tree) |tree| tree.comment_directives else .none;

    var parse_diags: usize = 0;
    for (trees.items, 0..) |maybe_tree, i| {
        const tree = maybe_tree orelse continue;
        total_tokens += tree.tokens.len();
        token_bytes += tree.tokens.byteSize();
        total_nodes += tree.nodes.len;
        node_bytes += tree.nodeBytes();
        extra_bytes += tree.extraBytes();
        ast_token_bytes += tree.tokens.byteSize();
        if (!is_lib[i] and !dts_skipped[i]) parse_diags += tree.diagnostics.len;
    }

    var total_symbols: usize = 0;
    var total_scopes: usize = 0;
    var total_flows: usize = 0;
    var bind_symbol_bytes: usize = 0;
    var bind_scope_bytes: usize = 0;
    var bind_flow_bytes: usize = 0;
    var bind_record_bytes: usize = 0;
    var bind_diags: usize = 0;
    for (binds.items, 0..) |maybe_bind, i| {
        const b = maybe_bind orelse continue;
        total_symbols += b.symbolCount();
        total_scopes += b.scopeCount();
        total_flows += b.flowCount();
        bind_symbol_bytes += b.symbolBytes();
        bind_scope_bytes += b.scopeBytes();
        bind_flow_bytes += b.flowBytes();
        bind_record_bytes += b.recordBytes();
        if (is_lib[i] or dts_skipped[i]) continue;
        for (b.diagnostics) |d| {
            if (!cdirs[i].suppresses(d.span.start)) bind_diags += 1;
        }
    }

    var link_diags: usize = 0;
    for (links, 0..) |*l, i| {
        if (is_lib[i] or dts_skipped[i]) continue;
        for (l.diags) |d| {
            if (!cdirs[i].suppresses(d.span.start)) link_diags += 1;
        }
    }

    var check_diags: usize = 0;
    var check_types: usize = 0;
    var check_type_bytes: usize = 0;
    var check_rel_entries: usize = 0;
    var check_rel_bytes: usize = 0;
    var check_rel_hits: usize = 0;
    var check_rel_misses: usize = 0;
    var check_nt_hits: usize = 0;
    var check_nt_misses: usize = 0;
    var check_scratch_hw: usize = 0;
    var check_flow_queries: usize = 0;
    var check_inst_hits: usize = 0;
    var check_inst_misses: usize = 0;
    var check_inst_maps: usize = 0;
    var check_instantiations: usize = 0;
    for (tasks) |*t| {
        const ck = t.result orelse continue;
        for (ck.diagnostics) |d| {
            if (is_lib[d.file] or dts_skipped[d.file]) continue;
            if (cdirs[d.file].suppresses(d.span.start)) continue;
            check_diags += 1;
        }
        check_types += ck.stats.types_created;
        check_type_bytes += ck.stats.type_bytes;
        check_rel_entries += ck.stats.relation_entries;
        check_rel_bytes += ck.stats.relation_bytes;
        check_rel_hits += ck.stats.relation_hits;
        check_rel_misses += ck.stats.relation_misses;
        check_nt_hits += ck.stats.node_type_hits;
        check_nt_misses += ck.stats.node_type_misses;
        if (ck.stats.scratch_high_water > check_scratch_hw) check_scratch_hw = ck.stats.scratch_high_water;
        check_flow_queries += ck.stats.flow_queries;
        check_inst_hits += ck.stats.inst_hits;
        check_inst_misses += ck.stats.inst_misses;
        check_inst_maps += ck.stats.inst_maps;
        check_instantiations += ck.stats.instantiations;
    }

    var failed: usize = 0;
    for (errs.items, paths.items) |maybe_err, path| {
        if (maybe_err) |err| {
            failed += 1;
            std.debug.print("ztsc: {s}: {s}\n", .{ path, @errorName(err) });
        }
    }
    for (tasks) |*t| {
        if (t.err) |err| {
            failed += 1;
            std.debug.print("ztsc: checker: {s}\n", .{@errorName(err)});
        }
    }

    const total_ns = total_timer.readNs();

    // --- Diagnostics: per file (discovery order), position-sorted ----------
    // Parse diagnostics first (message-only), then bind + link + check
    // merged by (position, code). Byte-identical for any --checkers=N.
    // Non-pretty output is the stable machine format; --pretty renders
    // tsc-style excerpts plus the final summary line.
    const cursors = try arena.alloc(usize, n_checkers);
    @memset(cursors, 0);

    var emitter: Emitter = .{ .out = out, .pretty = pretty };
    const Merged = struct {
        code: u16,
        start: u32,
        end: u32,
        msg: []const u8,
    };
    for (0..n_files) |i| {
        const path = paths.items[i];
        const src = results.items[i] orelse continue;
        const tree = trees.items[i] orelse continue;
        // Never surface diagnostics from the built-in lib itself, matching
        // tsc, which does not diagnose the default lib. The vendored real
        // 7.0.2 lib is census-clean but trips a few ztsc-incompleteness
        // diagnostics (`intrinsic`, `globalThis`, merged-interface duplicate
        // members); those degrade the affected lib types to `any` rather than
        // leaking spurious errors onto every user run. Diagnostic cursor for
        // the lib's owning checker is still advanced below so later files stay
        // aligned. Libs are the first files 0.. (see the injection site).
        //
        // Under `skipLibCheck`, `dts_skipped[i]` extends the same full
        // suppression to every non-lib `.d.ts`. tsc keeps *syntactic* errors in
        // `.d.ts` but suppresses semantic ones; ztsc cannot tell a genuine
        // syntax error from a parser-subset-gap cascade (both are parser
        // diagnostics), and real published `.d.ts` are syntactically valid, so
        // any parser diagnostic there is overwhelmingly a ztsc false positive.
        // The no-false-positives constraint + the under-report policy make
        // suppressing the whole file the correct call: zero surfaced `.d.ts`
        // diagnostics, matching tsc's observable output on valid `.d.ts`. Their
        // types still flow into `.ts` checking (they are parsed/bound/linked).
        if (is_lib[i] or dts_skipped[i]) {
            const owner = file_owner[i];
            if (tasks[owner].result) |ck| {
                var cur = cursors[owner];
                while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {}
                cursors[owner] = cur;
            }
            continue;
        }
        emitter.beginFile();

        var merged: std.ArrayList(Merged) = .empty;
        defer merged.deinit(gpa);
        // Parser diagnostics: those with a tsc analogue (e.g. TS1206) render
        // with their code and sort into the merged stream; the rest keep their
        // own messages.
        for (tree.diagnostics) |d| {
            const ts = d.code.tsCode();
            if (ts != 0) {
                try merged.append(gpa, .{ .code = ts, .start = d.span.start, .end = d.span.end, .msg = d.message() });
            } else {
                try emitter.emit(path, &src, d.span, 0, d.message());
            }
        }
        // Bind, link and check diagnostics are *semantic*, so a `@ts-nocheck`
        // file pragma or a preceding `@ts-ignore`/`@ts-expect-error` drops
        // them (tsc excludes exactly these three from a `@ts-nocheck` file and
        // filters the same set through the comment-directive map). Parser
        // diagnostics above are syntactic and always survive.
        const cd = cdirs[i];
        if (binds.items[i]) |b| {
            for (b.diagnostics) |d| {
                if (cd.suppresses(d.span.start)) continue;
                const ts = d.code.tsCode();
                if (ts != 0) {
                    try merged.append(gpa, .{ .code = ts, .start = d.span.start, .end = d.span.end, .msg = d.message() });
                } else {
                    try emitter.emit(path, &src, d.span, 0, d.message());
                }
            }
        }
        for (links[i].diags) |d| {
            if (cd.suppresses(d.span.start)) continue;
            try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .end = d.span.end, .msg = d.msg });
        }
        const owner = file_owner[i];
        if (tasks[owner].result) |ck| {
            var cur = cursors[owner];
            while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {
                const d = ck.diagnostics[cur];
                if (cd.suppresses(d.span.start)) continue;
                try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .end = d.span.end, .msg = d.msg });
            }
            cursors[owner] = cur;
        }
        std.mem.sort(Merged, merged.items, {}, struct {
            fn lessThan(_: void, x: Merged, y: Merged) bool {
                if (x.start != y.start) return x.start < y.start;
                return x.code < y.code;
            }
        }.lessThan);
        for (merged.items) |d| {
            try emitter.emit(path, &src, .{ .start = d.start, .end = d.end }, d.code, d.msg);
        }
    }
    if (pretty) {
        try ztsc.render.renderSummary(out, true, emitter.total, emitter.files_with, emitter.first_path, emitter.first_line);
    }

    // --- AST dump (--dump-ast) ---------------------------------------------
    if (cli.dump_ast) {
        for (trees.items, results.items, paths.items) |maybe_tree, maybe_src, path| {
            const tree = maybe_tree orelse continue;
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            var it = tree.childIterator(0);
            while (it.next()) |child| {
                try tree.dump(src.bytes, out, child);
                try out.writeAll("\n");
            }
        }
    }

    // --- Symbol dump (--dump-symbols) ---------------------------------------
    if (cli.dump_symbols) {
        for (binds.items, trees.items, results.items, paths.items) |maybe_bind, maybe_tree, maybe_src, path| {
            const b = maybe_bind orelse continue;
            const tree = maybe_tree orelse continue;
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            try b.dump(io, &interner, tree, src.bytes, out);
        }
    }

    if (cli.dump_types) {
        var dump_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer dump_arena.deinit();
        const all_files = try dump_arena.allocator().alloc(modules.FileId, n_files);
        for (all_files, 0..) |*f, i| f.* = @intCast(i);
        _ = checker.checkFilesAndDump(dump_arena.allocator(), io, gpa, &interner, prog, all_files, null, true, 0, out) catch {};
    }

    try out.print("ztsc: loaded {d} file(s) ({d} from CLI), {d} lines, {d} bytes, {d} tokens, {d} nodes, {d} symbols, {d} parse error(s), {d} bind error(s), {d} link error(s), {d} check error(s) ({d} worker(s), {d} checker(s))\n", .{
        files_ok,    n_entries,  total_lines, total_bytes, total_tokens, total_nodes, total_symbols,
        parse_diags, bind_diags, link_diags,  check_diags, n_workers,    n_checkers,
    });

    if (cli.census) {
        try ztsc.report.printCensus(out, trees.items, .{
            .files = n_files,
            .lines = total_lines,
            .parse_diags = parse_diags,
            .bind_diags = bind_diags,
            .check_diags = check_diags,
        });
    }

    if (cli.timing) {
        const checker_times = try arena.alloc(ztsc.report.CheckerTime, tasks.len);
        for (tasks, checker_times) |*t, *ct| ct.* = .{ .ns = t.ns, .files = t.owned.len };
        const fs_counts = rcache.fs.entryCounts();
        try ztsc.report.printTiming(out, .{
            .config_ns = config_ns,
            .load_ns = load_ns,
            .parse_ns = parse_ns,
            .bind_ns = bind_ns,
            .resolve_ns = resolve_ns,
            .discover_ns = discover_ns,
            .renumber_ns = renumber_ns,
            .link_ns = link_ns,
            .check_ns = check_ns,
            .total_ns = total_ns,
        }, .{
            .lines = total_lines,
            .bytes = total_bytes,
            .repeat = cli.repeat,
            .check_nodes = check_nodes,
        }, checker_times, .{
            .probes = resolve.fsProbeCount(),
            .lookups = rcache.lookups,
            .hits = rcache.hits,
            .enabled = !cli.no_resolve_cache,
            .nm_dirs = fs_counts.nm_dirs,
            .pkg_json = fs_counts.pkg_json,
            .real_dirs = fs_counts.real_dirs,
            .stat_files = fs_counts.stat_files,
            .pkg_exports = fs_counts.pkg_exports,
            .stat_lookups = rcache.fs.stat_lookups,
            .stat_hits = rcache.fs.stat_hits,
            .exports_lookups = rcache.fs.exports_lookups,
            .exports_hits = rcache.fs.exports_hits,
            .fs_bytes = rcache.fs.bytes,
        });
    }

    if (cli.memory) {
        // The shell measures; report.zig only formats. Every number below is
        // read here, in main, and handed over as a value.
        const worker_arena_bytes = try arena.alloc(usize, workers.len);
        for (workers, worker_arena_bytes) |*w, *cap| {
            cap.* = w.arena.queryCapacity() + w.scratch.queryCapacity();
        }
        const istats = interner.bytesUsed(io);
        var pack_text: usize = 0;
        var pack_reserved: usize = 0;
        for (workers) |*w| {
            pack_text += w.pack.text_bytes;
            pack_reserved += w.pack.reserved_bytes;
        }
        var checker_mem: std.ArrayList(ztsc.report.CheckerMem) = .empty;
        for (tasks, 0..) |*t, k| {
            const ck = t.result orelse continue;
            try checker_mem.append(arena, .{
                .index = k,
                .types = ck.stats.types_created,
                .type_bytes = ck.stats.type_bytes,
            });
        }
        try ztsc.report.printMemory(out, .{
            .worker_arena_bytes = worker_arena_bytes,
            .interner_total = istats.total(),
            .interner_strings = istats.string_bytes,
            .line_table_bytes = line_table_bytes,
            .token_bytes = token_bytes,
            .source_bytes = total_bytes,
            .pack_text = pack_text,
            .pack_reserved = pack_reserved,
            .tokens = total_tokens,
            .lines = total_lines,
            .nodes = total_nodes,
            .node_bytes = node_bytes,
            .extra_bytes = extra_bytes,
            .ast_token_bytes = ast_token_bytes,
            .symbols = total_symbols,
            .scopes = total_scopes,
            .flows = total_flows,
            .bind_symbol_bytes = bind_symbol_bytes,
            .bind_scope_bytes = bind_scope_bytes,
            .bind_flow_bytes = bind_flow_bytes,
            .bind_record_bytes = bind_record_bytes,
            .graph_bytes = prog.graphBytes(),
            .checkers = checker_mem.items,
            .check_types = check_types,
            .check_type_bytes = check_type_bytes,
            .rel_entries = check_rel_entries,
            .rel_bytes = check_rel_bytes,
            .rel_hits = check_rel_hits,
            .rel_misses = check_rel_misses,
            .inst_hits = check_inst_hits,
            .inst_misses = check_inst_misses,
            .inst_maps = check_inst_maps,
            .instantiations = check_instantiations,
            .nt_hits = check_nt_hits,
            .nt_misses = check_nt_misses,
            .scratch_high_water = check_scratch_hw,
            .flow_queries = check_flow_queries,
        });
    }

    try out.flush();
    for (tasks) |*t| t.arena.deinit();
    // Exit codes (documented in --help / README): 2 for environment
    // failures (unloadable files, internal checker errors), 1 when any
    // diagnostics were reported, 0 for a clean check.
    if (failed > 0) std.process.exit(2);
    if (parse_diags > 0 or bind_diags > 0 or link_diags > 0 or check_diags > 0) std.process.exit(1);
}

/// Grow every per-file table to `n` slots (null/empty defaults). Only the
/// main thread touches these tables; workers communicate exclusively
/// through the channels.
fn growPerFile(
    arena: std.mem.Allocator,
    n: usize,
    results: *std.ArrayList(?Source),
    trees: *std.ArrayList(?*Ast),
    binds: *std.ArrayList(?*Bind),
    errs: *std.ArrayList(?anyerror),
    path_atoms: *std.ArrayList(ztsc.intern.Atom),
    spec_atoms_all: *std.ArrayList([]ztsc.intern.Atom),
    spec_files_all: *std.ArrayList([]modules.FileId),
    edge_lists: *std.ArrayList([]const modules.FileId),
    type_ref_misses_all: *std.ArrayList([]const modules.TypeRefMiss),
) !void {
    while (results.items.len < n) {
        try results.append(arena, null);
        try trees.append(arena, null);
        try binds.append(arena, null);
        try errs.append(arena, null);
        try path_atoms.append(arena, 0);
        try spec_atoms_all.append(arena, &.{});
        try spec_files_all.append(arena, &.{});
        try edge_lists.append(arena, &.{});
        try type_ref_misses_all.append(arena, &.{});
    }
}

/// Reorder `items` so that items[k] becomes the old items[order[k]].
fn permuteInPlace(comptime T: type, arena: std.mem.Allocator, items: []T, order: []const u32) !void {
    const copy = try arena.dupe(T, items);
    for (order, 0..) |old, k| items[k] = copy[old];
}

/// Resolve one module specifier of `importer`; appends to the spec map and
/// discovers new files into `paths`.
fn resolveSpecInto(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    interner: *Interner,
    rcache: *resolve.ResolveCache,
    paths_map: ?ztsc.tsconfig.Paths,
    resolve_json: bool,
    importer: []const u8,
    module_atom: ztsc.intern.Atom,
    seen: *std.AutoHashMapUnmanaged(ztsc.intern.Atom, void),
    path_ids: *std.StringHashMapUnmanaged(u32),
    paths: *std.ArrayList([]const u8),
    atoms: *std.ArrayList(ztsc.intern.Atom),
    files: *std.ArrayList(modules.FileId),
) !void {
    if (module_atom == 0) return;
    const gop = try seen.getOrPut(gpa, module_atom);
    if (gop.found_existing) return;
    const spec = interner.lookup(io, module_atom);
    var fid: modules.FileId = modules.no_file;
    // All candidate paths and package.json bodies are transient — build
    // them in `scratch` (reset per file by the caller). Only the resolved
    // path is retained, duped into `arena` below.
    //
    // tsconfig `paths` mapping applies to bare specifiers first;
    // unmatched or unresolved candidates fall through to normal
    // resolution, like tsc.
    var mapped: ?[]const u8 = null;
    if (paths_map) |pm| {
        if (spec.len > 0 and spec[0] != '.' and spec[0] != '/') {
            // A `paths`-mapped `*.json` (`@fixtures/apis/x.json`) resolves to the
            // JSON file directly — `resolveStem` only probes TS/declaration
            // extensions and would miss it.
            const is_json = resolve_json and std.mem.endsWith(u8, spec, ".json");
            for (try pm.mapSpecifier(scratch, spec)) |cand| {
                const r = if (is_json)
                    try resolve.resolveJsonFile(io, scratch, Io.Dir.cwd(), cand)
                else
                    try resolve.resolveStem(io, scratch, Io.Dir.cwd(), cand);
                if (r) |rr| {
                    mapped = rr;
                    break;
                }
            }
        }
    }
    // `paths`-mapped bare specifiers bypass the cache: their resolution is a
    // different decision (a tsconfig remap), rare, and one `resolveStem` call.
    // Everything else — the common case — goes through the memo.
    if (mapped orelse try rcache.resolve(io, scratch, Io.Dir.cwd(), importer, spec)) |resolved| {
        const pgop = try path_ids.getOrPut(arena, resolved);
        if (pgop.found_existing) {
            fid = pgop.value_ptr.*;
        } else {
            // Give the map a stable key and `paths` a stable slice: the
            // scratch-owned `resolved` is about to be reset away.
            const stable = try arena.dupe(u8, resolved);
            pgop.key_ptr.* = stable;
            fid = @intCast(paths.items.len);
            pgop.value_ptr.* = fid;
            try paths.append(arena, stable);
        }
    }
    try atoms.append(arena, module_atom);
    try files.append(arena, fid);
}

/// Discover a triple-slash reference target as a program input: resolve
/// it and, if new, append it to `paths`/`path_ids` so the scheduler enqueues
/// it. Unlike `resolveSpecInto`, it records no import-specifier binding.
/// Resolution goes through `ResolveCache.resolveRef`, so the target is keyed by
/// its canonical path — the same identity an `import` of that file would get.
fn discoverReferenceInto(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: Io,
    rcache: *resolve.ResolveCache,
    importer: []const u8,
    ref: resolve.RefDirective,
    path_ids: *std.StringHashMapUnmanaged(u32),
    paths: *std.ArrayList([]const u8),
) !modules.FileId {
    if (try rcache.resolveRef(io, scratch, Io.Dir.cwd(), importer, ref)) |resolved| {
        const pgop = try path_ids.getOrPut(arena, resolved);
        if (pgop.found_existing) return pgop.value_ptr.*;
        const stable = try arena.dupe(u8, resolved);
        pgop.key_ptr.* = stable;
        const fid: modules.FileId = @intCast(paths.items.len);
        pgop.value_ptr.* = fid;
        try paths.append(arena, stable);
        return fid;
    }
    return modules.no_file;
}

fn sortSpecPairs(atoms: []ztsc.intern.Atom, files: []modules.FileId) void {
    var i: usize = 1;
    while (i < atoms.len) : (i += 1) {
        var j = i;
        while (j > 0 and atoms[j - 1] > atoms[j]) : (j -= 1) {
            std.mem.swap(ztsc.intern.Atom, &atoms[j - 1], &atoms[j]);
            std.mem.swap(modules.FileId, &files[j - 1], &files[j]);
        }
    }
}

/// Parse argv. On error, `bad_arg` names the offending argument.
fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8, bad_arg: *[]const u8) !Cli {
    var cli: Cli = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        bad_arg.* = arg;
        if (std.mem.eql(u8, arg, "--timing")) {
            cli.timing = true;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            cli.memory = true;
        } else if (std.mem.eql(u8, arg, "--dump-ast")) {
            cli.dump_ast = true;
        } else if (std.mem.eql(u8, arg, "--dump-symbols")) {
            cli.dump_symbols = true;
        } else if (std.mem.eql(u8, arg, "--dump-types")) {
            cli.dump_types = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            cli.version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.help = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cli.verbose = true;
        } else if (std.mem.eql(u8, arg, "--noLib")) {
            cli.no_lib = true;
        } else if (std.mem.eql(u8, arg, "--skip-default-lib-check")) {
            cli.skip_default_lib_check = true;
        } else if (std.mem.startsWith(u8, arg, "--lib=")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, arg["--lib=".len..], ',');
            while (it.next()) |name| {
                const t = std.mem.trim(u8, name, " \t");
                if (t.len > 0) try list.append(arena, t);
            }
            cli.lib = try list.toOwnedSlice(arena);
        } else if (std.mem.eql(u8, arg, "--no-resolve-cache")) {
            cli.no_resolve_cache = true;
        } else if (std.mem.eql(u8, arg, "--no-frozen-store")) {
            cli.no_frozen_store = true;
        } else if (std.mem.eql(u8, arg, "--no-inst-cache")) {
            cli.no_inst_cache = true;
        } else if (std.mem.eql(u8, arg, "--census")) {
            cli.census = true;
        } else if (std.mem.eql(u8, arg, "--inst-profile")) {
            cli.inst_profile = true;
        } else if (std.mem.eql(u8, arg, "--eager-members")) {
            cli.eager_members = true;
        } else if (std.mem.eql(u8, arg, "--decl-profile")) {
            cli.decl_profile = true;
        } else if (std.mem.eql(u8, arg, "--mem-profile")) {
            cli.mem_profile = true;
        } else if (std.mem.startsWith(u8, arg, "--inst-memo-bits=")) {
            cli.inst_memo_bits = std.fmt.parseInt(u6, arg["--inst-memo-bits=".len..], 10) catch
                return error.BadFlagValue;
        } else if (std.mem.eql(u8, arg, "--dup-profile")) {
            cli.dup_profile = true;
        } else if (std.mem.startsWith(u8, arg, "--partition-file=")) {
            cli.partition_file = arg["--partition-file=".len..];
        } else if (std.mem.eql(u8, arg, "--lazy-stats")) {
            cli.lazy_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--inst-focus=")) {
            cli.inst_focus = std.fmt.parseInt(u32, arg["--inst-focus=".len..], 10) catch
                return error.BadFlagValue;
            cli.inst_profile = true;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            cli.pretty = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            const v = arg["--pretty=".len..];
            if (std.mem.eql(u8, v, "true")) {
                cli.pretty = true;
            } else if (std.mem.eql(u8, v, "false")) {
                cli.pretty = false;
            } else {
                return error.BadFlagValue;
            }
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            cli.project = args[i];
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            cli.project = arg["--project=".len..];
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            const n = std.fmt.parseInt(usize, arg["--workers=".len..], 10) catch
                return error.BadFlagValue;
            if (n == 0) return error.BadFlagValue;
            cli.workers = n;
        } else if (std.mem.startsWith(u8, arg, "--checkers=")) {
            const n = std.fmt.parseInt(usize, arg["--checkers=".len..], 10) catch
                return error.BadFlagValue;
            if (n == 0) return error.BadFlagValue;
            cli.checkers = n;
        } else if (std.mem.startsWith(u8, arg, "--repeat=")) {
            cli.repeat = std.fmt.parseInt(usize, arg["--repeat=".len..], 10) catch
                return error.BadFlagValue;
            if (cli.repeat == 0) return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return error.UnknownFlag;
        } else {
            try paths.append(arena, arg);
        }
    }
    cli.paths = paths.items;
    return cli;
}

test "parseArgs flags and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";
    const args = [_][:0]const u8{ "ztsc", "--timing", "a.ts", "--memory", "b.ts" };
    const cli = try parseArgs(arena.allocator(), &args, &bad);
    try std.testing.expect(cli.timing);
    try std.testing.expect(cli.memory);
    try std.testing.expect(!cli.version);
    try std.testing.expectEqual(@as(usize, 2), cli.paths.len);
    try std.testing.expectEqualStrings("a.ts", cli.paths[0]);
    try std.testing.expectEqualStrings("b.ts", cli.paths[1]);
}

test "defaultCheckers: size and declaration-surface thresholds" {
    const eq = std.testing.expectEqual;
    // An explicit --checkers=N always wins, whatever the shape.
    try eq(@as(usize, 7), defaultCheckers(7, 10, 1, 1));
    try eq(@as(usize, 1), defaultCheckers(1, 10, 5_000_000, 20_000_000));
    // Never more instances than cores.
    try eq(@as(usize, 2), defaultCheckers(null, 2, 100_000, 100_000));

    // Small program: two, whatever the surface (chalk, ajv).
    try eq(@as(usize, 2), defaultCheckers(null, 10, 21_106, 21_106));
    try eq(@as(usize, 2), defaultCheckers(null, 10, 27_991, 27_991));
    // Mid-size, self-contained: four. The eight parity packages are all
    // ratio 1.00 because a vendored `.d.ts` corpus is checked directly.
    try eq(@as(usize, 4), defaultCheckers(null, 10, 37_004, 37_004)); // typebox
    try eq(@as(usize, 4), defaultCheckers(null, 10, 66_444, 66_444)); // drizzle
    try eq(@as(usize, 4), defaultCheckers(null, 10, 115_808, 115_808)); // hono

    // The measured inversion, and the reason `check_nodes` alone cannot
    // decide it: these two differ by 7% in check work and want different
    // counts. immich 2.61x declaration surface -> two; excalidraw 1.78x -> four.
    try eq(@as(usize, 2), defaultCheckers(null, 10, 437_226, 1_141_165));
    try eq(@as(usize, 4), defaultCheckers(null, 10, 409_224, 727_326));

    // Large but self-contained stays wide; declaration-heavy but small stays
    // out of the new rule (the size gate is what keeps it narrow).
    try eq(@as(usize, 4), defaultCheckers(null, 10, 900_000, 900_000));
    try eq(@as(usize, 4), defaultCheckers(null, 10, 100_000, 900_000));

    // Exactly at each boundary: the ratio test is `>=`, the size test `>=`.
    try eq(@as(usize, 2), defaultCheckers(null, 10, large_program_nodes, large_program_nodes * 22 / 10));
    try eq(@as(usize, 4), defaultCheckers(null, 10, large_program_nodes - 1, large_program_nodes * 22 / 10));
}

test "parseArgs workers, checkers and repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";
    const args = [_][:0]const u8{ "ztsc", "--workers=4", "--checkers=2", "--repeat=10", "a.ts" };
    const cli = try parseArgs(arena.allocator(), &args, &bad);
    try std.testing.expectEqual(@as(?usize, 4), cli.workers);
    try std.testing.expectEqual(@as(?usize, 2), cli.checkers);
    try std.testing.expectEqual(@as(usize, 10), cli.repeat);

    const bad_workers = [_][:0]const u8{ "ztsc", "--workers=0" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_workers, &bad));
    const bad_checkers = [_][:0]const u8{ "ztsc", "--checkers=0" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_checkers, &bad));
    const bad_repeat = [_][:0]const u8{ "ztsc", "--repeat=x" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_repeat, &bad));
    try std.testing.expectEqualStrings("--repeat=x", bad);
}

test "parseArgs rejects unknown flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";
    const args = [_][:0]const u8{ "ztsc", "--nope" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(arena.allocator(), &args, &bad));
    try std.testing.expectEqualStrings("--nope", bad);
    const short = [_][:0]const u8{ "ztsc", "-x" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(arena.allocator(), &short, &bad));
}

test "parseArgs tsconfig flags: pretty, project, help, verbose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";

    const a1 = [_][:0]const u8{ "ztsc", "--pretty", "--verbose", "a.ts" };
    const c1 = try parseArgs(arena.allocator(), &a1, &bad);
    try std.testing.expectEqual(@as(?bool, true), c1.pretty);
    try std.testing.expect(c1.verbose);

    const a2 = [_][:0]const u8{ "ztsc", "--pretty=false" };
    const c2 = try parseArgs(arena.allocator(), &a2, &bad);
    try std.testing.expectEqual(@as(?bool, false), c2.pretty);

    const a3 = [_][:0]const u8{"ztsc"};
    const c3 = try parseArgs(arena.allocator(), &a3, &bad);
    try std.testing.expectEqual(@as(?bool, null), c3.pretty);

    const a4 = [_][:0]const u8{ "ztsc", "-p", "proj/dir" };
    const c4 = try parseArgs(arena.allocator(), &a4, &bad);
    try std.testing.expectEqualStrings("proj/dir", c4.project.?);

    const a5 = [_][:0]const u8{ "ztsc", "--project=x/tsconfig.json" };
    const c5 = try parseArgs(arena.allocator(), &a5, &bad);
    try std.testing.expectEqualStrings("x/tsconfig.json", c5.project.?);

    const a6 = [_][:0]const u8{ "ztsc", "-p" };
    try std.testing.expectError(error.MissingFlagValue, parseArgs(arena.allocator(), &a6, &bad));

    const a7 = [_][:0]const u8{ "ztsc", "--pretty=maybe" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &a7, &bad));

    const a8 = [_][:0]const u8{ "ztsc", "-h" };
    const c8 = try parseArgs(arena.allocator(), &a8, &bad);
    try std.testing.expect(c8.help);
}

test "arena accounting sanity: capacity grows with allocations and covers usage" {
    var a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 0), a.queryCapacity());
    var total: usize = 0;
    for (0..100) |i| {
        const n = 128 + i;
        _ = try a.allocator().alloc(u8, n);
        total += n;
    }
    try std.testing.expect(a.queryCapacity() >= total);
}
