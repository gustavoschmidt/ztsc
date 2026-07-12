//! ZTSC CLI driver: argument parsing, thread pool, phase orchestration.
//!
//! M3 scope: load files in parallel (mmap + line tables), scan them in
//! parallel (M1 benchmark path), parse them in parallel into sealed
//! data-oriented ASTs, then bind them in parallel into sealed symbol
//! tables/scope trees/flow graphs. `--timing` reports per-phase wall clock,
//! `--memory` reports arena/token/AST/binder statistics (bytes/node,
//! binder bytes/line), `--dump-ast` prints S-expression parse trees, and
//! `--dump-symbols` prints the binder's scope/symbol dump. Checking arrives
//! in M4+.

const std = @import("std");
const Io = std.Io;
const ztsc = @import("ztsc");
const Source = ztsc.source.Source;
const Interner = ztsc.intern.Interner;
const scanner = ztsc.scanner;
const parser = ztsc.parser;
const binder = ztsc.binder;
const checker = ztsc.checker;
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
        trees: []?Ast,
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
            trees[i] = parser.parse(w.arena.allocator(), src.bytes) catch |err| {
                errs[i] = err;
                continue;
            };
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
        trees: []const ?Ast,
        repeat: usize,
        next: *std.atomic.Value(usize),
        binds: []?Bind,
        errs: []?anyerror,
    ) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= sources.len) break;
            const src = sources[i] orelse continue;
            const tree = &(trees[i] orelse continue);
            var r: usize = 1;
            while (r < repeat) : (r += 1) {
                var b = binder.bind(w.scratch.allocator(), io, gpa, interner, tree, src.bytes) catch break;
                std.mem.doNotOptimizeAway(&b);
                _ = w.scratch.reset(.retain_capacity);
            }
            binds[i] = binder.bind(w.arena.allocator(), io, gpa, interner, tree, src.bytes) catch |err| {
                errs[i] = err;
                continue;
            };
        }
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

    // --- Phase: load (parallel) -------------------------------------------
    const load_timer = Timer.start(io);

    var interner = Interner.init();
    defer interner.deinit(gpa);
    const results = try arena.alloc(?Source, cli.paths.len);
    @memset(results, null);
    const errs = try arena.alloc(?anyerror, cli.paths.len);
    @memset(errs, null);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @max(1, @min(cli.workers orelse cpu_count, cli.paths.len));
    const workers = try arena.alloc(Worker, n_workers);
    for (workers) |*w| w.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };

    var next = std.atomic.Value(usize).init(0);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.run, .{
            w, io, gpa, &interner, cli.paths, &next, results, errs,
        });
    }
    for (workers) |*w| w.thread.join();

    const load_ns = load_timer.readNs();

    // --- Phase: scan (parallel) -------------------------------------------
    const scan_timer = Timer.start(io);

    const token_lists = try arena.alloc(?scanner.Tokens, cli.paths.len);
    @memset(token_lists, null);
    next.store(0, .monotonic);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.scanRun, .{
            w, results, cli.repeat, &next, token_lists, errs,
        });
    }
    for (workers) |*w| w.thread.join();

    const scan_ns = scan_timer.readNs();

    // --- Phase: parse (parallel) ---------------------------------------------
    const parse_timer = Timer.start(io);

    const trees = try arena.alloc(?Ast, cli.paths.len);
    @memset(trees, null);
    next.store(0, .monotonic);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.parseRun, .{
            w, results, cli.repeat, &next, trees, errs,
        });
    }
    for (workers) |*w| w.thread.join();

    const parse_ns = parse_timer.readNs();

    // --- Phase: bind (parallel) ---------------------------------------------
    const bind_timer = Timer.start(io);

    const binds = try arena.alloc(?Bind, cli.paths.len);
    @memset(binds, null);
    next.store(0, .monotonic);
    for (workers) |*w| {
        w.thread = try std.Thread.spawn(.{}, Worker.bindRun, .{
            w, io, gpa, &interner, results, trees, cli.repeat, &next, binds, errs,
        });
    }
    for (workers) |*w| w.thread.join();

    const bind_ns = bind_timer.readNs();

    // --- Phase: check (single-threaded in M4; M5 partitions) ---------------
    const check_timer = Timer.start(io);

    const checks = try arena.alloc(?checker.Check, cli.paths.len);
    @memset(checks, null);
    var check_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer check_arena.deinit();
    for (binds, trees, results, 0..) |maybe_bind, maybe_tree, maybe_src, i| {
        const b = &(maybe_bind orelse continue);
        const tree = &(maybe_tree orelse continue);
        const src = maybe_src orelse continue;
        var r: usize = 1;
        while (r < cli.repeat) : (r += 1) {
            var scratch_check = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch_check.deinit();
            var res = checker.check(scratch_check.allocator(), io, gpa, &interner, tree, b, src.bytes) catch break;
            std.mem.doNotOptimizeAway(&res);
        }
        checks[i] = checker.check(check_arena.allocator(), io, gpa, &interner, tree, b, src.bytes) catch |err| blk: {
            errs[i] = err;
            break :blk null;
        };
    }

    const check_ns = check_timer.readNs();

    // --- Aggregate statistics ----------------------------------------------
    var files_ok: usize = 0;
    var total_bytes: usize = 0;
    var total_lines: usize = 0;
    var line_table_bytes: usize = 0;
    for (results) |maybe_src| {
        const src = maybe_src orelse continue;
        files_ok += 1;
        total_bytes += src.bytes.len;
        total_lines += src.lineCount();
        line_table_bytes += src.lineTableBytes();
    }

    var total_tokens: usize = 0;
    var token_bytes: usize = 0;
    for (token_lists) |maybe_toks| {
        const toks = maybe_toks orelse continue;
        total_tokens += toks.len();
        token_bytes += toks.byteSize();
    }

    var total_nodes: usize = 0;
    var node_bytes: usize = 0;
    var extra_bytes: usize = 0;
    var ast_token_bytes: usize = 0;
    var parse_diags: usize = 0;
    for (trees) |maybe_tree| {
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
    for (binds) |maybe_bind| {
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

    var check_diags: usize = 0;
    var check_types: usize = 0;
    var check_type_bytes: usize = 0;
    var check_rel_entries: usize = 0;
    var check_rel_bytes: usize = 0;
    var check_rel_hits: usize = 0;
    var check_rel_misses: usize = 0;
    var check_scratch_hw: usize = 0;
    var check_flow_queries: usize = 0;
    for (checks) |maybe_check| {
        const ck = maybe_check orelse continue;
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
    for (errs, cli.paths) |maybe_err, path| {
        if (maybe_err) |err| {
            failed += 1;
            std.debug.print("ztsc: {s}: {s}\n", .{ path, @errorName(err) });
        }
    }

    const total_ns = total_timer.readNs();

    // --- Parse + bind diagnostics ---------------------------------------------
    for (trees, results, cli.paths) |maybe_tree, maybe_src, path| {
        const tree = maybe_tree orelse continue;
        const src = maybe_src orelse continue;
        for (tree.diagnostics) |d| {
            const lc = src.lineCol(@min(d.span.start, @as(u32, @intCast(src.bytes.len))));
            try out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.message() });
        }
    }
    for (binds, results, cli.paths) |maybe_bind, maybe_src, path| {
        const b = maybe_bind orelse continue;
        const src = maybe_src orelse continue;
        for (b.diagnostics) |d| {
            const lc = src.lineCol(@min(d.span.start, @as(u32, @intCast(src.bytes.len))));
            const ts = d.code.tsCode();
            if (ts != 0) {
                try out.print("{s}:{d}:{d}: error TS{d}: {s}\n", .{ path, lc.line + 1, lc.col + 1, ts, d.message() });
            } else {
                try out.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.message() });
            }
        }
    }

    for (checks, results, cli.paths) |maybe_check, maybe_src, path| {
        const ck = maybe_check orelse continue;
        const src = maybe_src orelse continue;
        for (ck.diagnostics) |d| {
            const lc = src.lineCol(@min(d.span.start, @as(u32, @intCast(src.bytes.len))));
            try out.print("{s}:{d}:{d}: error TS{d}: {s}\n", .{ path, lc.line + 1, lc.col + 1, d.code, d.msg });
        }
    }

    // --- AST dump (--dump-ast) ---------------------------------------------
    if (cli.dump_ast) {
        for (trees, results, cli.paths) |maybe_tree, maybe_src, path| {
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

    // --- Symbol dump (--dump-symbols) ------------------------------------------
    if (cli.dump_symbols) {
        for (binds, trees, results, cli.paths) |maybe_bind, maybe_tree, maybe_src, path| {
            const b = maybe_bind orelse continue;
            const tree = maybe_tree orelse continue;
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            try b.dump(io, &interner, &tree, src.bytes, out);
        }
    }

    if (cli.dump_types) {
        for (binds, trees, results, cli.paths) |maybe_bind, maybe_tree, maybe_src, path| {
            const b = &(maybe_bind orelse continue);
            const tree = &(maybe_tree orelse continue);
            const src = maybe_src orelse continue;
            try out.print(";; {s}\n", .{path});
            var dump_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer dump_arena.deinit();
            _ = checker.checkAndDump(dump_arena.allocator(), io, gpa, &interner, tree, b, src.bytes, out) catch {};
        }
    }

    try out.print("ztsc: loaded {d} file(s), {d} lines, {d} bytes, {d} tokens, {d} nodes, {d} symbols, {d} parse error(s), {d} bind error(s), {d} check error(s) ({d} worker(s))\n", .{
        files_ok, total_lines, total_bytes, total_tokens, total_nodes, total_symbols, parse_diags, bind_diags, check_diags, n_workers,
    });

    if (cli.timing) {
        const load_ms = nsToMs(load_ns);
        const scan_ms = nsToMs(scan_ns);
        const total_ms = nsToMs(total_ns);
        const load_s = @as(f64, @floatFromInt(load_ns)) / std.time.ns_per_s;
        const scan_s = @as(f64, @floatFromInt(scan_ns)) / std.time.ns_per_s;
        // --repeat multiplies the work done in the scan phase.
        const scanned_lines = @as(f64, @floatFromInt(total_lines * cli.repeat));
        const scanned_bytes = @as(f64, @floatFromInt(total_bytes * cli.repeat));
        const load_lines_per_s: f64 = if (load_s > 0) @as(f64, @floatFromInt(total_lines)) / load_s else 0;
        const load_mb_per_s: f64 = if (load_s > 0)
            @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0) / load_s
        else
            0;
        const scan_lines_per_s: f64 = if (scan_s > 0) scanned_lines / scan_s else 0;
        const scan_mb_per_s: f64 = if (scan_s > 0) scanned_bytes / (1024.0 * 1024.0) / scan_s else 0;
        const parse_ms = nsToMs(parse_ns);
        const parse_s = @as(f64, @floatFromInt(parse_ns)) / std.time.ns_per_s;
        const parse_lines_per_s: f64 = if (parse_s > 0) scanned_lines / parse_s else 0;
        const parse_mb_per_s: f64 = if (parse_s > 0) scanned_bytes / (1024.0 * 1024.0) / parse_s else 0;
        const bind_ms = nsToMs(bind_ns);
        const bind_s = @as(f64, @floatFromInt(bind_ns)) / std.time.ns_per_s;
        const bind_lines_per_s: f64 = if (bind_s > 0) scanned_lines / bind_s else 0;
        const bind_mb_per_s: f64 = if (bind_s > 0) scanned_bytes / (1024.0 * 1024.0) / bind_s else 0;
        try out.print("\n--timing\n", .{});
        try out.print("  {s:<10} {s:>10} {s:>14} {s:>10}\n", .{ "phase", "ms", "lines/s", "MB/s" });
        try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ "load", load_ms, load_lines_per_s, load_mb_per_s });
        try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ "scan", scan_ms, scan_lines_per_s, scan_mb_per_s });
        try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ "parse", parse_ms, parse_lines_per_s, parse_mb_per_s });
        try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ "bind", bind_ms, bind_lines_per_s, bind_mb_per_s });
        const check_ms = nsToMs(check_ns);
        const check_s = @as(f64, @floatFromInt(check_ns)) / std.time.ns_per_s;
        const check_lines_per_s: f64 = if (check_s > 0) scanned_lines / check_s else 0;
        const check_mb_per_s: f64 = if (check_s > 0) scanned_bytes / (1024.0 * 1024.0) / check_s else 0;
        try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ "check", check_ms, check_lines_per_s, check_mb_per_s });
        try out.print("  {s:<10} {d:>10.3}\n", .{ "total", total_ms });
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

        // Checker statistics (PLAN M4: bytes/type is the key memory metric).
        try out.print("  {s:<24} {d:>12}\n", .{ "check types", check_types });
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
    if (failed > 0 or parse_diags > 0 or bind_diags > 0 or check_diags > 0) std.process.exit(1);
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

test "parseArgs workers and repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "ztsc", "--workers=4", "--repeat=10", "a.ts" };
    const cli = try parseArgs(arena.allocator(), &args);
    try std.testing.expectEqual(@as(?usize, 4), cli.workers);
    try std.testing.expectEqual(@as(usize, 10), cli.repeat);

    const bad_workers = [_][:0]const u8{ "ztsc", "--workers=0" };
    try std.testing.expectError(error.BadFlagValue, parseArgs(arena.allocator(), &bad_workers));
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
