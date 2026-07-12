//! ZTSC CLI driver: argument parsing, thread pool, phase orchestration.
//!
//! M5 scope: the module graph is discovered wavefront-style from the CLI
//! entry files — each wave loads/scans/parses/binds in parallel with the
//! worker pool, then a cheap serial step resolves the wave's module
//! specifiers (bundler-style, see modules.zig) and queues newly discovered
//! files for the next wave. After binding, a serial `link` phase builds
//! sealed per-file import/export tables; the check phase then partitions
//! the program's files across N independent checker instances
//! (`--checkers=N`, default min(4, cores)), each with its own type
//! store/caches, reading the shared immutable AST/binder/link data without
//! locks (PLAN §2.3).
//!
//! Output determinism: every diagnostic is tagged with its file; each
//! file's check diagnostics come from exactly the checker that owns it,
//! and the final print is per file (in discovery order), position-sorted —
//! byte-identical for any N. `--timing` reports per-phase wall clock plus
//! a per-checker breakdown; `--memory` reports arena/token/AST/binder
//! statistics plus per-checker type-store bytes and module-graph bytes.

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
    \\usage: ztsc [options] <files...>
    \\
    \\options:
    \\  --timing        print per-phase wall-clock timings
    \\  --memory        print arena / memory statistics
    \\  --dump-ast      print S-expression parse trees (golden-test format)
    \\  --dump-symbols  print binder scope/symbol dumps (golden-test format)
    \\  --dump-types    print per-declaration checked types (golden-test format)
    \\  --workers=N     number of worker threads (default: CPU count)
    \\  --checkers=N    number of checker instances (default: min(4, CPUs))
    \\  --repeat=N      scan/parse/bind each file N times (benchmark aid)
    \\  --version       print version and exit
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
    workers: ?usize = null,
    checkers: ?usize = null,
    repeat: usize = 1,
    paths: []const []const u8 = &.{},
};

/// One pool worker. Each worker owns an arena allocator; everything a worker
/// allocates while loading files (line tables, read fallbacks) lives in its
/// arena and is never individually freed.
const Worker = struct {
    arena: std.heap.ArenaAllocator,
    /// Scratch space for benchmark re-scans (`--repeat`); reset between runs.
    scratch: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    files_loaded: usize = 0,

    fn run(
        w: *Worker,
        io: Io,
        gpa: std.mem.Allocator,
        interner: *Interner,
        paths: []const []const u8,
        next: *std.atomic.Value(usize),
        results: []?Source,
        errs: []?anyerror,
    ) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= paths.len) break;
            const src = Source.load(io, w.arena.allocator(), paths[i]) catch |err| {
                errs[i] = err;
                continue;
            };
            results[i] = src;
            w.files_loaded += 1;
            // Exercise the shared interner from every worker thread.
            _ = interner.intern(io, gpa, paths[i]) catch |err| {
                errs[i] = err;
            };
        }
    }

    /// Scan phase: tokenize loaded sources into SoA token streams held in
    /// the worker's arena. `repeat > 1` re-scans into scratch (benchmarks).
    fn scanRun(
        w: *Worker,
        sources: []const ?Source,
        repeat: usize,
        next: *std.atomic.Value(usize),
        tokens: []?scanner.Tokens,
        errs: []?anyerror,
    ) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= sources.len) break;
            const src = sources[i] orelse continue;
            var r: usize = 1;
            while (r < repeat) : (r += 1) {
                var toks = scanner.tokenize(w.scratch.allocator(), src.bytes) catch break;
                std.mem.doNotOptimizeAway(&toks);
                _ = w.scratch.reset(.retain_capacity);
            }
            tokens[i] = scanner.tokenize(w.arena.allocator(), src.bytes) catch |err| {
                errs[i] = err;
                continue;
            };
        }
    }

    /// Parse phase: recursive descent into sealed per-file ASTs held in the
    /// worker's arena. `repeat > 1` re-parses into scratch (benchmarks).
    fn parseRun(
        w: *Worker,
        sources: []const ?Source,
        repeat: usize,
        next: *std.atomic.Value(usize),
        trees: []?*Ast,
        errs: []?anyerror,
    ) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= sources.len) break;
            const src = sources[i] orelse continue;
            var r: usize = 1;
            while (r < repeat) : (r += 1) {
                var tree = parser.parse(w.scratch.allocator(), src.bytes) catch break;
                std.mem.doNotOptimizeAway(&tree);
                _ = w.scratch.reset(.retain_capacity);
            }
            const tree = w.arena.allocator().create(Ast) catch |err| {
                errs[i] = err;
                continue;
            };
            tree.* = parser.parse(w.arena.allocator(), src.bytes) catch |err| {
                errs[i] = err;
                continue;
            };
            trees[i] = tree;
        }
    }

    /// Bind phase: per-file binding into sealed symbol/scope/flow output
    /// held in the worker's arena. `repeat > 1` re-binds into scratch.
    fn bindRun(
        w: *Worker,
        io: Io,
        gpa: std.mem.Allocator,
        interner: *Interner,
        sources: []const ?Source,
        trees: []const ?*Ast,
        repeat: usize,
        next: *std.atomic.Value(usize),
        binds: []?*Bind,
        errs: []?anyerror,
    ) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= sources.len) break;
            const src = sources[i] orelse continue;
            const tree = trees[i] orelse continue;
            var r: usize = 1;
            while (r < repeat) : (r += 1) {
                var b = binder.bind(w.scratch.allocator(), io, gpa, interner, tree, src.bytes) catch break;
                std.mem.doNotOptimizeAway(&b);
                _ = w.scratch.reset(.retain_capacity);
            }
            const b = w.arena.allocator().create(Bind) catch |err| {
                errs[i] = err;
                continue;
            };
            b.* = binder.bind(w.arena.allocator(), io, gpa, interner, tree, src.bytes) catch |err| {
                errs[i] = err;
                continue;
            };
            binds[i] = b;
        }
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
    const cli = parseArgs(arena, args) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };

    if (cli.version) {
        try out.print("ztsc {s}\n", .{ztsc.version});
        try out.flush();
        return;
    }
    if (cli.paths.len == 0) {
        std.debug.print("ztsc: no input files\n{s}", .{usage});
        std.process.exit(2);
    }

    const total_timer = Timer.start(io);

    var interner = Interner.init();
    defer interner.deinit(gpa);

    // Not capped by the entry count: waves discover more files (M5).
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @max(1, cli.workers orelse cpu_count);
    const workers = try arena.alloc(Worker, n_workers);
    for (workers) |*w| w.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };

    // --- Wavefront discovery: load/scan/parse/bind + resolve, per wave ----
    var paths: std.ArrayList([]const u8) = .empty;
    var path_ids: std.StringHashMapUnmanaged(u32) = .empty;
    for (cli.paths) |p| {
        const norm = try modules.normalizePath(arena, p);
        const gop = try path_ids.getOrPut(arena, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(paths.items.len);
            try paths.append(arena, norm);
        }
    }
    const n_entries = paths.items.len;

    var results: std.ArrayList(?Source) = .empty;
    var token_lists: std.ArrayList(?scanner.Tokens) = .empty;
    var trees: std.ArrayList(?*Ast) = .empty;
    var binds: std.ArrayList(?*Bind) = .empty;
    var errs: std.ArrayList(?anyerror) = .empty;
    var spec_maps: std.ArrayList(modules.SpecMap) = .empty;

    var load_ns: u64 = 0;
    var scan_ns: u64 = 0;
    var parse_ns: u64 = 0;
    var bind_ns: u64 = 0;
    var resolve_ns: u64 = 0;

    var wave_start: usize = 0;
    while (wave_start < paths.items.len) {
        const wave_end = paths.items.len;
        const n = wave_end - wave_start;
        try results.appendNTimes(arena, null, n);
        try token_lists.appendNTimes(arena, null, n);
        try trees.appendNTimes(arena, null, n);
        try binds.appendNTimes(arena, null, n);
        try errs.appendNTimes(arena, null, n);

        const wave_paths = paths.items[wave_start..wave_end];
        const wave_results = results.items[wave_start..wave_end];
        const wave_tokens = token_lists.items[wave_start..wave_end];
        const wave_trees = trees.items[wave_start..wave_end];
        const wave_binds = binds.items[wave_start..wave_end];
        const wave_errs = errs.items[wave_start..wave_end];

        var next = std.atomic.Value(usize).init(0);

        // Load (parallel).
        const load_timer = Timer.start(io);
        for (workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.run, .{
                w, io, gpa, &interner, wave_paths, &next, wave_results, wave_errs,
            });
        }
        for (workers) |*w| w.thread.join();
        load_ns += load_timer.readNs();

        // Scan (parallel).
        const scan_timer = Timer.start(io);
        next.store(0, .monotonic);
        for (workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.scanRun, .{
                w, wave_results, cli.repeat, &next, wave_tokens, wave_errs,
            });
        }
        for (workers) |*w| w.thread.join();
        scan_ns += scan_timer.readNs();

        // Parse (parallel).
        const parse_timer = Timer.start(io);
        next.store(0, .monotonic);
        for (workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.parseRun, .{
                w, wave_results, cli.repeat, &next, wave_trees, wave_errs,
            });
        }
        for (workers) |*w| w.thread.join();
        parse_ns += parse_timer.readNs();

        // Bind (parallel).
        const bind_timer = Timer.start(io);
        next.store(0, .monotonic);
        for (workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.bindRun, .{
                w, io, gpa, &interner, wave_results, wave_trees, cli.repeat, &next, wave_binds, wave_errs,
            });
        }
        for (workers) |*w| w.thread.join();
        bind_ns += bind_timer.readNs();

        // Resolve this wave's module specifiers (serial; discovers files).
        const resolve_timer = Timer.start(io);
        for (wave_start..wave_end) |i| {
            var atoms: std.ArrayList(ztsc.intern.Atom) = .empty;
            var files: std.ArrayList(modules.FileId) = .empty;
            if (binds.items[i]) |b| {
                var seen: std.AutoHashMapUnmanaged(ztsc.intern.Atom, void) = .empty;
                defer seen.deinit(gpa);
                for (b.imports) |rec| {
                    try resolveSpecInto(arena, gpa, io, &interner, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
                }
                for (b.exports) |rec| {
                    if (rec.module != 0) {
                        try resolveSpecInto(arena, gpa, io, &interner, paths.items[i], rec.module, &seen, &path_ids, &paths, &atoms, &files);
                    }
                }
            }
            sortSpecPairs(atoms.items, files.items);
            try spec_maps.append(arena, .{ .atoms = atoms.items, .files = files.items });
        }
        resolve_ns += resolve_timer.readNs();

        wave_start = wave_end;
    }
    const n_files = paths.items.len;

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
            .specs = spec_maps.items[i],
        };
    }
    const links = try modules.link(arena, gpa, io, &interner, prog_files);
    const prog = try arena.create(modules.Program);
    prog.* = .{
        .files = prog_files,
        .sym_base = try modules.computeSymBase(arena, prog_files),
        .links = links,
    };
    const link_ns = link_timer.readNs();

    // --- Check (N independent checker instances, PLAN §2.3) ---------------
    const check_timer = Timer.start(io);
    const n_checkers: usize = @max(1, @min(cli.checkers orelse @min(4, cpu_count), n_files));
    const tasks = try arena.alloc(CheckerTask, n_checkers);
    {
        // Round-robin partition (deterministic).
        const owned_lists = try arena.alloc(std.ArrayList(modules.FileId), n_checkers);
        for (owned_lists) |*l| l.* = .empty;
        for (0..n_files) |i| {
            try owned_lists[i % n_checkers].append(arena, @intCast(i));
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

    var total_tokens: usize = 0;
    var token_bytes: usize = 0;
    for (token_lists.items) |maybe_toks| {
        const toks = maybe_toks orelse continue;
        total_tokens += toks.len();
        token_bytes += toks.byteSize();
    }

    var total_nodes: usize = 0;
    var node_bytes: usize = 0;
    var extra_bytes: usize = 0;
    var ast_token_bytes: usize = 0;
    var parse_diags: usize = 0;
    for (trees.items) |maybe_tree| {
        const tree = maybe_tree orelse continue;
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
    const cursors = try arena.alloc(usize, n_checkers);
    @memset(cursors, 0);

    const Merged = struct {
        code: u16,
        start: u32,
        msg: []const u8,
    };
    for (0..n_files) |i| {
        const path = paths.items[i];
        const src = results.items[i] orelse continue;
        const tree = trees.items[i] orelse continue;
        for (tree.diagnostics) |d| {
            const lc = src.lineCol(@min(d.span.start, @as(u32, @intCast(src.bytes.len))));
            try out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.message() });
        }

        var merged: std.ArrayList(Merged) = .empty;
        defer merged.deinit(gpa);
        if (binds.items[i]) |b| {
            for (b.diagnostics) |d| {
                const ts = d.code.tsCode();
                if (ts != 0) {
                    try merged.append(gpa, .{ .code = ts, .start = d.span.start, .msg = d.message() });
                } else {
                    const lc = src.lineCol(@min(d.span.start, @as(u32, @intCast(src.bytes.len))));
                    try out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.message() });
                }
            }
        }
        for (links[i].diags) |d| {
            try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .msg = d.msg });
        }
        const owner = i % n_checkers;
        if (tasks[owner].result) |ck| {
            var cur = cursors[owner];
            while (cur < ck.diagnostics.len and ck.diagnostics[cur].file == i) : (cur += 1) {
                const d = ck.diagnostics[cur];
                try merged.append(gpa, .{ .code = d.code, .start = d.span.start, .msg = d.msg });
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
            const lc = src.lineCol(@min(d.start, @as(u32, @intCast(src.bytes.len))));
            try out.print("{s}:{d}:{d}: error TS{d}: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.code, d.msg });
        }
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
        try printPhase(out, "load", load_ns, @floatFromInt(total_lines), @floatFromInt(total_bytes));
        try printPhase(out, "scan", scan_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "parse", parse_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "bind", bind_ns, scanned_lines, scanned_bytes);
        try printPhase(out, "resolve", resolve_ns, 0, 0);
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

        // AST statistics (PLAN M2: bytes/node is the key memory metric).
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

        // Binder statistics (PLAN M3: binder bytes/line is the key metric).
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
    if (failed > 0 or parse_diags > 0 or bind_diags > 0 or link_diags > 0 or check_diags > 0) std.process.exit(1);
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
    gpa: std.mem.Allocator,
    io: Io,
    interner: *Interner,
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
    if (try modules.resolveSpecifier(io, arena, Io.Dir.cwd(), importer, spec)) |resolved| {
        const pgop = try path_ids.getOrPut(arena, resolved);
        if (pgop.found_existing) {
            fid = pgop.value_ptr.*;
        } else {
            fid = @intCast(paths.items.len);
            pgop.value_ptr.* = fid;
            try paths.append(arena, resolved);
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

fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Cli {
    var cli: Cli = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
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
        } else if (std.mem.startsWith(u8, arg, "--")) {
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
    const args = [_][:0]const u8{ "ztsc", "--timing", "a.ts", "--memory", "b.ts" };
    const cli = try parseArgs(arena.allocator(), &args);
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
    const args = [_][:0]const u8{ "ztsc", "--workers=4", "--checkers=2", "--repeat=10", "a.ts" };
    const cli = try parseArgs(arena.allocator(), &args);
    try std.testing.expectEqual(@as(?usize, 4), cli.workers);
    try std.testing.expectEqual(@as(?usize, 2), cli.checkers);
    try std.testing.expectEqual(@as(usize, 10), cli.repeat);

    const bad_workers = [_][:0]const u8{ "ztsc", "--workers=0" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_workers));
    const bad_checkers = [_][:0]const u8{ "ztsc", "--checkers=0" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_checkers));
    const bad_repeat = [_][:0]const u8{ "ztsc", "--repeat=x" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_repeat));
}

test "parseArgs rejects unknown flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "ztsc", "--nope" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(arena.allocator(), &args));
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
