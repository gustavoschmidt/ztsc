//! ZTSC CLI driver: argument parsing, thread pool, phase orchestration.
//!
//! Module discovery is single-owner with a completion queue (ROADMAP
//! "single-owner module discovery"): the main thread is the sole owner of
//! the module graph and seen-set (no locks on graph state); workers run
//! the whole per-file front end (load/scan/parse/bind) and push per-file
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
//! (`--checkers=N`, default min(4, cores)), each with its own type
//! store/caches, reading the shared immutable AST/binder/link data without
//! locks (ROADMAP.md §2.3).
//!
//! Output determinism: the file order is derived from the graph, never
//! from scheduling; every diagnostic is tagged with its file; each file's
//! check diagnostics come from exactly the checker that owns it, and the
//! final print is per file (in graph order), position-sorted —
//! byte-identical for any --workers/--checkers combination. `--timing`
//! reports the per-phase split (load/scan/parse/bind are summed per-file
//! worker times, since files stream through the pipeline; `discover` is
//! the front-end wall clock) plus a per-checker breakdown; `--memory`
//! reports arena/token/AST/binder statistics plus per-checker type-store
//! bytes and module-graph bytes.

const std = @import("std");
const Io = std.Io;
const ztsc = @import("ztsc");
const Source = ztsc.source.Source;
const Interner = ztsc.intern.Interner;
const scanner = ztsc.scanner;
const parser = ztsc.parser;
const binder = ztsc.binder;
const checker = ztsc.checker;
const modules = ztsc.modules;
const Ast = ztsc.ast.Ast;
const Bind = binder.Bind;

const usage =
    \\usage: ztsc [options] [files...]
    \\
    \\With no files, ztsc looks for tsconfig.json in the current directory
    \\and its parents (or uses --project). See ROADMAP.md §6 for the checked
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
    \\  --workers=N            number of worker threads (default: CPU count)
    \\  --checkers=N           number of checker instances (default: min(4, CPUs))
    \\  --repeat=N             scan/parse/bind each file N times (benchmark aid)
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
    load_ns: u64 = 0,
    scan_ns: u64 = 0,
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
    thread: std.Thread = undefined,
    files_loaded: usize = 0,

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

    /// The whole per-file front end: load -> scan -> parse -> bind.
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
        const src = if (std.mem.eql(u8, path, modules.lib_path))
            Source.fromBytes(alloc, path, modules.lib_source) catch |err| {
                c.err = err;
                return;
            }
        else Source.load(io, alloc, path) catch |err| {
            c.err = err;
            return;
        };
        c.src = src;
        w.files_loaded += 1;
        // Exercise the shared interner from every worker thread.
        _ = interner.intern(io, gpa, path) catch |err| {
            c.err = err;
            return;
        };
        c.load_ns = timer.readNs();

        // Standalone tokenize, timed but not retained: the parser
        // re-tokenizes internally into `tree.tokens` (what the binder
        // reads), so keeping a second copy in the per-file arena only
        // wasted ~5 B/token. Token stats are derived from `tree.tokens`.
        timer = Timer.start(io);
        var r: usize = 1;
        while (r < repeat) : (r += 1) {
            var toks = scanner.tokenize(w.scratch.allocator(), src.bytes) catch break;
            std.mem.doNotOptimizeAway(&toks);
            _ = w.scratch.reset(.retain_capacity);
        }
        {
            var toks = scanner.tokenize(w.scratch.allocator(), src.bytes) catch |err| {
                c.err = err;
                return;
            };
            std.mem.doNotOptimizeAway(&toks);
            _ = w.scratch.reset(.retain_capacity);
        }
        c.scan_ns = timer.readNs();

        timer = Timer.start(io);
        r = 1;
        while (r < repeat) : (r += 1) {
            var tree = parser.parse(w.scratch.allocator(), src.bytes) catch break;
            std.mem.doNotOptimizeAway(&tree);
            _ = w.scratch.reset(.retain_capacity);
        }
        const tree = alloc.create(Ast) catch |err| {
            c.err = err;
            return;
        };
        tree.* = parser.parse(alloc, src.bytes) catch |err| {
            c.err = err;
            return;
        };
        c.tree = tree;
        c.parse_ns = timer.readNs();

        timer = Timer.start(io);
        r = 1;
        while (r < repeat) : (r += 1) {
            var b = binder.bind(w.scratch.allocator(), io, gpa, interner, tree, src.bytes) catch break;
            std.mem.doNotOptimizeAway(&b);
            _ = w.scratch.reset(.retain_capacity);
        }
        const b = alloc.create(Bind) catch |err| {
            c.err = err;
            return;
        };
        b.* = binder.bind(alloc, io, gpa, interner, tree, src.bytes) catch |err| {
            c.err = err;
            return;
        };
        c.bind = b;
        c.bind_ns = timer.readNs();
    }
};

/// One checker instance: checks its partition on its own thread.
const CheckerTask = struct {
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    owned: []const modules.FileId = &.{},
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
        t.result = checker.checkFiles(t.arena.allocator(), io, gpa, interner, prog, t.owned) catch |err| blk: {
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

    // With no file arguments, drive the run from a tsconfig.json (M6).
    var entry_paths = cli.paths;
    var paths_map: ?ztsc.tsconfig.Paths = null;
    if (cli.paths.len == 0) {
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
        entry_paths = cfg.root_files;
        paths_map = cfg.paths;
    }

    // Pretty diagnostics: tsc-style excerpts + colors; default follows the
    // terminal, --pretty / --pretty=false forces.
    const pretty = cli.pretty orelse (Io.File.stderr().isTty(io) catch false);

    const total_timer = Timer.start(io);

    var interner = Interner.init();
    defer interner.deinit(gpa);

    // Not capped by the entry count: discovery finds more files (M5).
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @max(1, cli.workers orelse cpu_count);
    const workers = try arena.alloc(Worker, n_workers);
    for (workers) |*w| w.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };

    // --- Single-owner discovery (no wave barrier) --------------------------
    // The main thread is the sole owner of the module graph and seen-set;
    // workers front-end one file at a time and push completions; the main
    // thread resolves each completion as it arrives and enqueues newly
    // discovered files immediately.
    var paths: std.ArrayList([]const u8) = .empty;
    var path_ids: std.StringHashMapUnmanaged(u32) = .empty;
    // Inject the ES-core lib as the first entry (root, file 0) unless
    // --noLib. Its synthetic path routes to the embedded source in the
    // worker front end; its top-level decls become the program globals.
    if (!cli.no_lib) {
        try path_ids.put(arena, modules.lib_path, 0);
        try paths.append(arena, modules.lib_path);
    }
    for (entry_paths) |p| {
        const norm = try modules.normalizePath(arena, p);
        const gop = try path_ids.getOrPut(arena, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(paths.items.len);
            try paths.append(arena, norm);
        }
    }
    const n_entries = paths.items.len;

    var results: std.ArrayList(?Source) = .empty;
    var trees: std.ArrayList(?*Ast) = .empty;
    var binds: std.ArrayList(?*Bind) = .empty;
    var errs: std.ArrayList(?anyerror) = .empty;
    var spec_atoms_all: std.ArrayList([]ztsc.intern.Atom) = .empty;
    var spec_files_all: std.ArrayList([]modules.FileId) = .empty;
    // Per-file resolved FileIds in first-occurrence specifier order
    // (unresolved skipped) — the edges of the deterministic BFS below.
    var edge_lists: std.ArrayList([]const modules.FileId) = .empty;

    var load_ns: u64 = 0;
    var scan_ns: u64 = 0;
    var parse_ns: u64 = 0;
    var bind_ns: u64 = 0;
    var resolve_ns: u64 = 0;

    var work = Channel(WorkItem).init(io);
    defer work.deinit();
    var done = Channel(Completion).init(io);
    defer done.deinit();

    const discover_timer = Timer.start(io);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.discoverRun, .{
            w, io, gpa, &interner, cli.repeat, &work, &done,
        });
    }

    var outstanding: usize = 0;
    try growPerFile(arena, paths.items.len, &results, &trees, &binds, &errs, &spec_atoms_all, &spec_files_all, &edge_lists);
    for (paths.items, 0..) |p, i| {
        try work.push(.{ .file = @intCast(i), .path = p });
        outstanding += 1;
    }

    // Transient allocator for module resolution: candidate path strings and
    // package.json bodies are discarded after each file's specifiers
    // resolve. Mirrors the serial buildProgram path (modules.zig). Reset per
    // file so it never grows past one file's resolution working set.
    var resolve_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer resolve_scratch.deinit();

    while (outstanding > 0) {
        // The done channel is never closed while work is outstanding.
        const c = done.pop().?;
        outstanding -= 1;
        const i = c.file;
        results.items[i] = c.src;
        trees.items[i] = c.tree;
        binds.items[i] = c.bind;
        errs.items[i] = c.err;
        load_ns += c.load_ns;
        scan_ns += c.scan_ns;
        parse_ns += c.parse_ns;
        bind_ns += c.bind_ns;

        // Resolve this file's module specifiers (main thread only;
        // discovers files).
        const resolve_timer = Timer.start(io);
        var atoms: std.ArrayList(ztsc.intern.Atom) = .empty;
        var files: std.ArrayList(modules.FileId) = .empty;
        const known_before = paths.items.len;
        if (binds.items[i]) |b| {
            const scratch = resolve_scratch.allocator();
            var seen: std.AutoHashMapUnmanaged(ztsc.intern.Atom, void) = .empty;
            defer seen.deinit(gpa);
            for (b.imports) |rec| {
                try resolveSpecInto(arena, scratch, gpa, io, &interner, paths_map, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
            }
            for (b.exports) |rec| {
                if (rec.module != 0) {
                    try resolveSpecInto(arena, scratch, gpa, io, &interner, paths_map, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
                }
            }
            _ = resolve_scratch.reset(.retain_capacity);
        }
        var edges: std.ArrayList(modules.FileId) = .empty;
        for (files.items) |fid| {
            if (fid != modules.no_file) try edges.append(arena, fid);
        }
        edge_lists.items[i] = edges.items;
        sortSpecPairs(atoms.items, files.items);
        spec_atoms_all.items[i] = atoms.items;
        spec_files_all.items[i] = files.items;

        // Enqueue newly discovered files right away.
        try growPerFile(arena, paths.items.len, &results, &trees, &binds, &errs, &spec_atoms_all, &spec_files_all, &edge_lists);
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
        try permuteInPlace([]ztsc.intern.Atom, arena, spec_atoms_all.items, order);
        try permuteInPlace([]modules.FileId, arena, spec_files_all.items, order);
        // Remap the resolved FileIds inside the spec maps.
        for (spec_files_all.items) |spec_files| {
            for (spec_files) |*fid| {
                if (fid.* != modules.no_file) fid.* = new_ids[fid.*];
            }
        }
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
                empty_bind.?.* = try binder.bind(arena, io, gpa, &interner, empty_tree.?, "");
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
        };
    }
    const links = try modules.link(arena, gpa, io, &interner, prog_files);
    const sym_base = try modules.computeSymBase(arena, prog_files);
    const prog = try arena.create(modules.Program);
    prog.* = .{
        .files = prog_files,
        .sym_base = sym_base,
        .links = links,
        .globals = try modules.collectGlobals(arena, prog_files, sym_base, modules.libFileId(prog_files)),
    };
    const link_ns = link_timer.readNs();

    // --- Check (N independent checker instances, ROADMAP.md §2.3) ---------------
    const check_timer = Timer.start(io);
    const n_checkers: usize = @max(1, @min(cli.checkers orelse @min(4, cpu_count), n_files));
    const tasks = try arena.alloc(CheckerTask, n_checkers);
    // File id -> owning checker, so per-file diagnostics can be reassembled
    // from the right checker below (replaces the old `i % n_checkers`).
    const file_owner = try arena.alloc(u32, n_files);
    {
        // Cost-based partition (ROADMAP.md §5, M10): greedy longest-
        // processing-time by per-file AST node count (≈ check cost, known
        // post-parse). Round-robin (`i % n_checkers`) ignores file size and
        // clumps large files whose ids share a residue mod N onto one
        // checker; sorting files big-first and dropping each onto the
        // currently least-loaded checker isolates a lone huge file and
        // spreads the rest evenly. Fully deterministic: node counts are
        // fixed post-parse and every tie breaks by file id / checker index,
        // so any --checkers=N still yields byte-identical diagnostics.
        const owned_lists = try arena.alloc(std.ArrayList(modules.FileId), n_checkers);
        for (owned_lists) |*l| l.* = .empty;

        const Item = struct { file: u32, cost: u64 };
        const items = try arena.alloc(Item, n_files);
        for (0..n_files) |i| {
            const cost: u64 = if (trees.items[i]) |tree| tree.nodes.len else 0;
            items[i] = .{ .file = @intCast(i), .cost = cost };
        }
        std.mem.sort(Item, items, {}, struct {
            fn lessThan(_: void, x: Item, y: Item) bool {
                if (x.cost != y.cost) return x.cost > y.cost; // biggest first
                return x.file < y.file; // deterministic tie-break
            }
        }.lessThan);

        const loads = try arena.alloc(u64, n_checkers);
        @memset(loads, 0);
        for (items) |it| {
            // Least-loaded checker; ties resolve to the lowest index.
            var best: usize = 0;
            for (loads[1..], 1..) |l, k| {
                if (l < loads[best]) best = k;
            }
            try owned_lists[best].append(arena, it.file);
            loads[best] += it.cost;
            file_owner[it.file] = @intCast(best);
        }

        for (tasks, 0..) |*t, k| {
            t.* = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .owned = owned_lists[k].items,
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
    // array kept per file now that the standalone scan is discarded).
    var total_tokens: usize = 0;
    var token_bytes: usize = 0;
    var total_nodes: usize = 0;
    var node_bytes: usize = 0;
    var extra_bytes: usize = 0;
    var ast_token_bytes: usize = 0;
    var parse_diags: usize = 0;
    for (trees.items) |maybe_tree| {
        const tree = maybe_tree orelse continue;
        total_tokens += tree.tokens.len();
        token_bytes += tree.tokens.byteSize();
        total_nodes += tree.nodes.len;
        node_bytes += tree.nodeBytes();
        extra_bytes += tree.extraBytes();
        ast_token_bytes += tree.tokens.byteSize();
        parse_diags += tree.diagnostics.len;
    }

    var total_symbols: usize = 0;
    var total_scopes: usize = 0;
    var total_flows: usize = 0;
    var bind_symbol_bytes: usize = 0;
    var bind_scope_bytes: usize = 0;
    var bind_flow_bytes: usize = 0;
    var bind_record_bytes: usize = 0;
    var bind_diags: usize = 0;
    for (binds.items) |maybe_bind| {
        const b = maybe_bind orelse continue;
        total_symbols += b.symbolCount();
        total_scopes += b.scopeCount();
        total_flows += b.flowCount();
        bind_symbol_bytes += b.symbolBytes();
        bind_scope_bytes += b.scopeBytes();
        bind_flow_bytes += b.flowBytes();
        bind_record_bytes += b.recordBytes();
        bind_diags += b.diagnostics.len;
    }

    var link_diags: usize = 0;
    for (links) |*l| link_diags += l.diags.len;

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
    for (tasks) |*t| {
        const ck = t.result orelse continue;
        check_diags += ck.diagnostics.len;
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
    // tsc-style excerpts plus the final summary line (M6).
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
        emitter.beginFile();
        for (tree.diagnostics) |d| {
            try emitter.emit(path, &src, d.span, 0, d.message());
        }

        var merged: std.ArrayList(Merged) = .empty;
        defer merged.deinit(gpa);
        if (binds.items[i]) |b| {
            for (b.diagnostics) |d| {
                const ts = d.code.tsCode();
                if (ts != 0) {
                    try merged.append(gpa, .{ .code = ts, .start = d.span.start, .end = d.span.end, .msg = d.message() });
                } else {
                    try emitter.emit(path, &src, d.span, 0, d.message());
                }
            }
        }
        for (links[i].diags) |d| {
            try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .end = d.span.end, .msg = d.msg });
        }
        const owner = file_owner[i];
        if (tasks[owner].result) |ck| {
            var cur = cursors[owner];
            while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {
                const d = ck.diagnostics[cur];
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
        _ = checker.checkFilesAndDump(dump_arena.allocator(), io, gpa, &interner, prog, all_files, out) catch {};
    }

    try out.print("ztsc: loaded {d} file(s) ({d} from CLI), {d} lines, {d} bytes, {d} tokens, {d} nodes, {d} symbols, {d} parse error(s), {d} bind error(s), {d} link error(s), {d} check error(s) ({d} worker(s), {d} checker(s))\n", .{
        files_ok,    n_entries,  total_lines, total_bytes, total_tokens, total_nodes, total_symbols,
        parse_diags, bind_diags, link_diags,  check_diags, n_workers,    n_checkers,
    });

    if (cli.timing) {
        const total_ms = nsToMs(total_ns);
        const scanned_lines = @as(f64, @floatFromInt(total_lines * cli.repeat));
        const scanned_bytes = @as(f64, @floatFromInt(total_bytes * cli.repeat));
        try out.print("\n--timing\n", .{});
        try out.print("  {s:<10} {s:>10} {s:>14} {s:>10}\n", .{ "phase", "ms", "lines/s", "MB/s" });
        // load..bind are summed per-file worker times (files stream through
        // the pipeline, so the phases overlap); discover is the front-end
        // wall clock (spawn -> last completion resolved -> join).
        try printPhase(out, "load", load_ns, @floatFromInt(total_lines), @floatFromInt(total_bytes));
        try printPhase(out, "scan", scan_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "parse", parse_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "bind", bind_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "resolve", resolve_ns, 0, 0);
        try printPhase(out, "discover", discover_ns, @floatFromInt(total_lines), @floatFromInt(total_bytes));
        try printPhase(out, "link", link_ns, 0, 0);
        try printPhase(out, "check", check_ns, @floatFromInt(total_lines), @floatFromInt(total_bytes));
        try out.print("  {s:<10} {d:>10.3}\n", .{ "total", total_ms });
        try out.print("  per checker:\n", .{});
        for (tasks, 0..) |*t, k| {
            try out.print("    checker[{d}] {d:>10.3} ms  {d} file(s)\n", .{ k, nsToMs(t.ns), t.owned.len });
        }
    }

    if (cli.memory) {
        var worker_arena_bytes: usize = 0;
        try out.print("\n--memory\n", .{});
        try out.print("  {s:<24} {s:>12}\n", .{ "arena", "bytes" });
        for (workers, 0..) |*w, i| {
            const cap = w.arena.queryCapacity() + w.scratch.queryCapacity();
            worker_arena_bytes += cap;
            try out.print("  worker[{d}] arena{s:<7} {d:>12}\n", .{ i, "", cap });
        }
        const istats = interner.bytesUsed(io);
        try out.print("  {s:<24} {d:>12}\n", .{ "interner (total)", istats.total() });
        try out.print("  {s:<24} {d:>12}\n", .{ "  of which strings", istats.string_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "line tables (in arenas)", line_table_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "token arrays (in arenas)", token_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "mmapped source (file)", total_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "tokens", total_tokens });
        const bytes_per_token: f64 = if (total_tokens > 0)
            @as(f64, @floatFromInt(token_bytes)) / @as(f64, @floatFromInt(total_tokens))
        else
            0;
        try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/token", bytes_per_token });

        // AST statistics (ROADMAP §4 M2: bytes/node is the key memory metric).
        try out.print("  {s:<24} {d:>12}\n", .{ "ast nodes", total_nodes });
        try out.print("  {s:<24} {d:>12}\n", .{ "ast node SoA bytes", node_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "ast extra_data bytes", extra_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "ast token bytes", ast_token_bytes });
        const bytes_per_node: f64 = if (total_nodes > 0)
            @as(f64, @floatFromInt(node_bytes + extra_bytes)) / @as(f64, @floatFromInt(total_nodes))
        else
            0;
        const nodes_per_line: f64 = if (total_lines > 0)
            @as(f64, @floatFromInt(total_nodes)) / @as(f64, @floatFromInt(total_lines))
        else
            0;
        try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/node (SoA+extra)", bytes_per_node });
        try out.print("  {s:<24} {d:>12.2}\n", .{ "nodes/line", nodes_per_line });

        // Binder statistics (ROADMAP §4 M3: binder bytes/line is the key metric).
        const bind_total_bytes = bind_symbol_bytes + bind_scope_bytes +
            bind_flow_bytes + bind_record_bytes;
        try out.print("  {s:<24} {d:>12}\n", .{ "bind symbols", total_symbols });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind scopes", total_scopes });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind flow nodes", total_flows });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind symbol bytes", bind_symbol_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind scope bytes", bind_scope_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind flow bytes", bind_flow_bytes });
        try out.print("  {s:<24} {d:>12}\n", .{ "bind record bytes", bind_record_bytes });
        const bind_bytes_per_line: f64 = if (total_lines > 0)
            @as(f64, @floatFromInt(bind_total_bytes)) / @as(f64, @floatFromInt(total_lines))
        else
            0;
        try out.print("  {s:<24} {d:>12.2}\n", .{ "bind bytes/line", bind_bytes_per_line });

        // Module graph (M5).
        try out.print("  {s:<24} {d:>12}\n", .{ "module graph bytes", prog.graphBytes() });

        // Checker statistics (M4 bytes/type; M5 per-checker breakdown).
        for (tasks, 0..) |*t, k| {
            const ck = t.result orelse continue;
            try out.print("  checker[{d}] types        {d:>12}\n", .{ k, ck.stats.types_created });
            try out.print("  checker[{d}] type bytes   {d:>12}\n", .{ k, ck.stats.type_bytes });
        }
        try out.print("  {s:<24} {d:>12}\n", .{ "check types (total)", check_types });
        try out.print("  {s:<24} {d:>12}\n", .{ "check type-arena bytes", check_type_bytes });
        const bytes_per_type: f64 = if (check_types > 0)
            @as(f64, @floatFromInt(check_type_bytes)) / @as(f64, @floatFromInt(check_types))
        else
            0;
        try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/type", bytes_per_type });
        const types_per_line: f64 = if (total_lines > 0)
            @as(f64, @floatFromInt(check_types)) / @as(f64, @floatFromInt(total_lines))
        else
            0;
        try out.print("  {s:<24} {d:>12.2}\n", .{ "types/line", types_per_line });
        try out.print("  {s:<24} {d:>12}\n", .{ "relation cache entries", check_rel_entries });
        try out.print("  {s:<24} {d:>12}\n", .{ "relation cache bytes", check_rel_bytes });
        const rel_total = check_rel_hits + check_rel_misses;
        const rel_hit_rate: f64 = if (rel_total > 0)
            100.0 * @as(f64, @floatFromInt(check_rel_hits)) / @as(f64, @floatFromInt(rel_total))
        else
            0;
        try out.print("  {s:<24} {d:>11.1}%\n", .{ "relation hit rate", rel_hit_rate });
        try out.print("  {s:<24} {d:>12}\n", .{ "node_types hits", check_nt_hits });
        try out.print("  {s:<24} {d:>12}\n", .{ "node_types misses", check_nt_misses });
        const nt_total = check_nt_hits + check_nt_misses;
        const nt_hit_rate: f64 = if (nt_total > 0)
            100.0 * @as(f64, @floatFromInt(check_nt_hits)) / @as(f64, @floatFromInt(nt_total))
        else
            0;
        try out.print("  {s:<24} {d:>11.1}%\n", .{ "node_types hit rate", nt_hit_rate });
        try out.print("  {s:<24} {d:>12}\n", .{ "check scratch high-water", check_scratch_hw });
        try out.print("  {s:<24} {d:>12}\n", .{ "check flow queries", check_flow_queries });

        const heap_total = worker_arena_bytes + istats.total();
        const bytes_per_line: f64 = if (total_lines > 0)
            @as(f64, @floatFromInt(heap_total)) / @as(f64, @floatFromInt(total_lines))
        else
            0;
        try out.print("  {s:<24} {d:>12}\n", .{ "heap total (arenas)", heap_total });
        try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/line (heap)", bytes_per_line });
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
    spec_atoms_all: *std.ArrayList([]ztsc.intern.Atom),
    spec_files_all: *std.ArrayList([]modules.FileId),
    edge_lists: *std.ArrayList([]const modules.FileId),
) !void {
    while (results.items.len < n) {
        try results.append(arena, null);
        try trees.append(arena, null);
        try binds.append(arena, null);
        try errs.append(arena, null);
        try spec_atoms_all.append(arena, &.{});
        try spec_files_all.append(arena, &.{});
        try edge_lists.append(arena, &.{});
    }
}

/// Reorder `items` so that items[k] becomes the old items[order[k]].
fn permuteInPlace(comptime T: type, arena: std.mem.Allocator, items: []T, order: []const u32) !void {
    const copy = try arena.dupe(T, items);
    for (order, 0..) |old, k| items[k] = copy[old];
}

fn printPhase(out: *Io.Writer, name: []const u8, ns: u64, lines: f64, bytes: f64) !void {
    const s = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    const lines_per_s: f64 = if (s > 0 and lines > 0) lines / s else 0;
    const mb_per_s: f64 = if (s > 0 and bytes > 0) bytes / (1024.0 * 1024.0) / s else 0;
    try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ name, nsToMs(ns), lines_per_s, mb_per_s });
}

/// Resolve one module specifier of `importer`; appends to the spec map and
/// discovers new files into `paths`.
fn resolveSpecInto(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    interner: *Interner,
    paths_map: ?ztsc.tsconfig.Paths,
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
    // tsconfig `paths` mapping applies to bare specifiers first (M6);
    // unmatched or unresolved candidates fall through to normal
    // resolution, like tsc.
    var mapped: ?[]u8 = null;
    if (paths_map) |pm| {
        if (spec.len > 0 and spec[0] != '.' and spec[0] != '/') {
            for (try pm.mapSpecifier(scratch, spec)) |cand| {
                if (try modules.resolveStem(io, scratch, Io.Dir.cwd(), cand)) |r| {
                    mapped = r;
                    break;
                }
            }
        }
    }
    if (mapped orelse try modules.resolveSpecifier(io, scratch, Io.Dir.cwd(), importer, spec)) |resolved| {
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

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
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

test "parseArgs M6 flags: pretty, project, help, verbose" {
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
