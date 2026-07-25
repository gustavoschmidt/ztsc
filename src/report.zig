//! Formatting for the `--timing`, `--memory` and `--census` reports.
//!
//! Pure formatting, no measurement: main.zig (the imperative shell) owns the
//! timers, the arenas, and the per-phase / per-checker counters, and hands
//! them here as plain values. Nothing in this file allocates, reads global
//! state, spawns anything, or touches anything but the writer — the same
//! inputs always render the same bytes.

const std = @import("std");
const Io = std.Io;

const ast = @import("ast.zig");
const Ast = ast.Ast;

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

// --- --timing ---------------------------------------------------------------

/// Per-phase nanosecond totals. load..bind are summed per-file worker times
/// (files stream through the pipeline, so the phases overlap); `discover` is
/// the front-end wall clock (spawn -> last completion resolved -> join).
pub const Phases = struct {
    load_ns: u64,
    scan_ns: u64,
    parse_ns: u64,
    bind_ns: u64,
    resolve_ns: u64,
    discover_ns: u64,
    link_ns: u64,
    check_ns: u64,
    total_ns: u64,
};

/// The work volume the per-phase rates are computed against. `repeat` is
/// `--repeat=N`: scan/parse/bind ran N times over the same input, so their
/// throughput counts the input N times.
pub const Volume = struct {
    lines: usize,
    bytes: usize,
    repeat: usize,
};

/// One checker instance's wall time and partition size.
pub const CheckerTime = struct {
    ns: u64,
    files: usize,
};

/// Resolution-cache scoreboard plus the filesystem-fact memos under it
/// (S1-lite). `probes` is FS syscalls issued (statFile + package.json reads);
/// `lookups`/`hits` show the memo collapsing repeated specifiers. Compare
/// probes with vs without `--no-resolve-cache` for the before/after number.
pub const ResolveStats = struct {
    probes: u64,
    lookups: u64,
    hits: u64,
    enabled: bool,
    nm_dirs: u32,
    pkg_json: u32,
    real_dirs: u32,
    fs_bytes: usize,
};

pub fn printTiming(
    out: *Io.Writer,
    phases: Phases,
    vol: Volume,
    checkers: []const CheckerTime,
    resolve: ResolveStats,
) !void {
    const total_ms = nsToMs(phases.total_ns);
    const lines_f: f64 = @floatFromInt(vol.lines);
    const bytes_f: f64 = @floatFromInt(vol.bytes);
    const scanned_lines = @as(f64, @floatFromInt(vol.lines * vol.repeat));
    const scanned_bytes = @as(f64, @floatFromInt(vol.bytes * vol.repeat));
    try out.print("\n--timing\n", .{});
    try out.print("  {s:<10} {s:>10} {s:>14} {s:>10}\n", .{ "phase", "ms", "lines/s", "MB/s" });
    try printPhase(out, "load", phases.load_ns, lines_f, bytes_f);
    try printPhase(out, "scan", phases.scan_ns, scanned_lines, scanned_bytes);
    try printPhase(out, "parse", phases.parse_ns, scanned_lines, scanned_bytes);
    try printPhase(out, "bind", phases.bind_ns, scanned_lines, scanned_bytes);
    try printPhase(out, "resolve", phases.resolve_ns, 0, 0);
    try printPhase(out, "discover", phases.discover_ns, lines_f, bytes_f);
    try printPhase(out, "link", phases.link_ns, 0, 0);
    try printPhase(out, "check", phases.check_ns, lines_f, bytes_f);
    try out.print("  {s:<10} {d:>10.3}\n", .{ "total", total_ms });
    try out.print("  per checker:\n", .{});
    for (checkers, 0..) |c, k| {
        try out.print("    checker[{d}] {d:>10.3} ms  {d} file(s)\n", .{ k, nsToMs(c.ns), c.files });
    }
    try out.print("  resolve cache: {d} probes, {d} lookups, {d} hits ({s})\n", .{
        resolve.probes,                                 resolve.lookups, resolve.hits,
        if (resolve.enabled) "enabled" else "disabled",
    });
    try out.print("  resolve fs memo: {d} node_modules dirs, {d} package.json, {d} realpath dirs, {d:.2} MiB\n", .{
        resolve.nm_dirs,   resolve.pkg_json,
        resolve.real_dirs, @as(f64, @floatFromInt(resolve.fs_bytes)) / (1024.0 * 1024.0),
    });
}

fn printPhase(out: *Io.Writer, name: []const u8, ns: u64, lines: f64, bytes: f64) !void {
    const s = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    const lines_per_s: f64 = if (s > 0 and lines > 0) lines / s else 0;
    const mb_per_s: f64 = if (s > 0 and bytes > 0) bytes / (1024.0 * 1024.0) / s else 0;
    try out.print("  {s:<10} {d:>10.3} {d:>14.0} {d:>10.1}\n", .{ name, nsToMs(ns), lines_per_s, mb_per_s });
}

// --- --memory ---------------------------------------------------------------

/// One checker instance's type-store totals. `index` is the checker's slot,
/// carried explicitly because instances that failed contribute no row.
pub const CheckerMem = struct {
    index: usize,
    types: usize,
    type_bytes: usize,
};

/// Everything the `--memory` table prints, gathered by the driver.
pub const Memory = struct {
    /// Per-worker arena capacity (front-end arena + `--repeat` scratch), in
    /// worker order.
    worker_arena_bytes: []const usize,
    interner_total: usize,
    interner_strings: usize,
    line_table_bytes: usize,
    token_bytes: usize,
    source_bytes: usize,
    pack_text: usize,
    pack_reserved: usize,
    tokens: usize,
    lines: usize,

    nodes: usize,
    node_bytes: usize,
    extra_bytes: usize,
    ast_token_bytes: usize,

    symbols: usize,
    scopes: usize,
    flows: usize,
    bind_symbol_bytes: usize,
    bind_scope_bytes: usize,
    bind_flow_bytes: usize,
    bind_record_bytes: usize,

    graph_bytes: usize,

    checkers: []const CheckerMem,
    check_types: usize,
    check_type_bytes: usize,
    rel_entries: usize,
    rel_bytes: usize,
    rel_hits: usize,
    rel_misses: usize,
    inst_hits: usize,
    inst_misses: usize,
    inst_maps: usize,
    nt_hits: usize,
    nt_misses: usize,
    scratch_high_water: usize,
    flow_queries: usize,
};

pub fn printMemory(out: *Io.Writer, m: Memory) !void {
    var worker_arena_bytes: usize = 0;
    try out.print("\n--memory\n", .{});
    try out.print("  {s:<24} {s:>12}\n", .{ "arena", "bytes" });
    for (m.worker_arena_bytes, 0..) |cap, i| {
        worker_arena_bytes += cap;
        try out.print("  worker[{d}] arena{s:<7} {d:>12}\n", .{ i, "", cap });
    }
    try out.print("  {s:<24} {d:>12}\n", .{ "interner (total)", m.interner_total });
    try out.print("  {s:<24} {d:>12}\n", .{ "  of which strings", m.interner_strings });
    try out.print("  {s:<24} {d:>12}\n", .{ "line tables (in arenas)", m.line_table_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "token arrays (in arenas)", m.token_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "source text (file)", m.source_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "  of which packed", m.pack_text });
    try out.print("  {s:<24} {d:>12}\n", .{ "  pack segments", m.pack_reserved });
    try out.print("  {s:<24} {d:>12}\n", .{ "tokens", m.tokens });
    const bytes_per_token: f64 = if (m.tokens > 0)
        @as(f64, @floatFromInt(m.token_bytes)) / @as(f64, @floatFromInt(m.tokens))
    else
        0;
    try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/token", bytes_per_token });

    // AST statistics (bytes/node is the key memory metric).
    try out.print("  {s:<24} {d:>12}\n", .{ "ast nodes", m.nodes });
    try out.print("  {s:<24} {d:>12}\n", .{ "ast node SoA bytes", m.node_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "ast extra_data bytes", m.extra_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "ast token bytes", m.ast_token_bytes });
    const bytes_per_node: f64 = if (m.nodes > 0)
        @as(f64, @floatFromInt(m.node_bytes + m.extra_bytes)) / @as(f64, @floatFromInt(m.nodes))
    else
        0;
    const nodes_per_line: f64 = if (m.lines > 0)
        @as(f64, @floatFromInt(m.nodes)) / @as(f64, @floatFromInt(m.lines))
    else
        0;
    try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/node (SoA+extra)", bytes_per_node });
    try out.print("  {s:<24} {d:>12.2}\n", .{ "nodes/line", nodes_per_line });

    // Binder statistics (binder bytes/line is the key metric).
    const bind_total_bytes = m.bind_symbol_bytes + m.bind_scope_bytes +
        m.bind_flow_bytes + m.bind_record_bytes;
    try out.print("  {s:<24} {d:>12}\n", .{ "bind symbols", m.symbols });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind scopes", m.scopes });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind flow nodes", m.flows });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind symbol bytes", m.bind_symbol_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind scope bytes", m.bind_scope_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind flow bytes", m.bind_flow_bytes });
    try out.print("  {s:<24} {d:>12}\n", .{ "bind record bytes", m.bind_record_bytes });
    const bind_bytes_per_line: f64 = if (m.lines > 0)
        @as(f64, @floatFromInt(bind_total_bytes)) / @as(f64, @floatFromInt(m.lines))
    else
        0;
    try out.print("  {s:<24} {d:>12.2}\n", .{ "bind bytes/line", bind_bytes_per_line });

    // Module graph.
    try out.print("  {s:<24} {d:>12}\n", .{ "module graph bytes", m.graph_bytes });

    // Checker statistics (bytes/type; per-checker breakdown).
    for (m.checkers) |c| {
        try out.print("  checker[{d}] types        {d:>12}\n", .{ c.index, c.types });
        try out.print("  checker[{d}] type bytes   {d:>12}\n", .{ c.index, c.type_bytes });
    }
    try out.print("  {s:<24} {d:>12}\n", .{ "check types (total)", m.check_types });
    try out.print("  {s:<24} {d:>12}\n", .{ "check type-arena bytes", m.check_type_bytes });
    const bytes_per_type: f64 = if (m.check_types > 0)
        @as(f64, @floatFromInt(m.check_type_bytes)) / @as(f64, @floatFromInt(m.check_types))
    else
        0;
    try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/type", bytes_per_type });
    const types_per_line: f64 = if (m.lines > 0)
        @as(f64, @floatFromInt(m.check_types)) / @as(f64, @floatFromInt(m.lines))
    else
        0;
    try out.print("  {s:<24} {d:>12.2}\n", .{ "types/line", types_per_line });
    try out.print("  {s:<24} {d:>12}\n", .{ "relation cache entries", m.rel_entries });
    try out.print("  {s:<24} {d:>12}\n", .{ "relation cache bytes", m.rel_bytes });
    const rel_total = m.rel_hits + m.rel_misses;
    const rel_hit_rate: f64 = if (rel_total > 0)
        100.0 * @as(f64, @floatFromInt(m.rel_hits)) / @as(f64, @floatFromInt(rel_total))
    else
        0;
    try out.print("  {s:<24} {d:>11.1}%\n", .{ "relation hit rate", rel_hit_rate });
    // Instantiation cache.
    try out.print("  {s:<24} {d:>12}\n", .{ "inst cache hits", m.inst_hits });
    try out.print("  {s:<24} {d:>12}\n", .{ "inst cache misses", m.inst_misses });
    try out.print("  {s:<24} {d:>12}\n", .{ "inst canonical maps", m.inst_maps });
    const inst_total = m.inst_hits + m.inst_misses;
    const inst_hit_rate: f64 = if (inst_total > 0)
        100.0 * @as(f64, @floatFromInt(m.inst_hits)) / @as(f64, @floatFromInt(inst_total))
    else
        0;
    try out.print("  {s:<24} {d:>11.1}%\n", .{ "inst hit rate", inst_hit_rate });
    try out.print("  {s:<24} {d:>12}\n", .{ "node_types hits", m.nt_hits });
    try out.print("  {s:<24} {d:>12}\n", .{ "node_types misses", m.nt_misses });
    const nt_total = m.nt_hits + m.nt_misses;
    const nt_hit_rate: f64 = if (nt_total > 0)
        100.0 * @as(f64, @floatFromInt(m.nt_hits)) / @as(f64, @floatFromInt(nt_total))
    else
        0;
    try out.print("  {s:<24} {d:>11.1}%\n", .{ "node_types hit rate", nt_hit_rate });
    try out.print("  {s:<24} {d:>12}\n", .{ "check scratch high-water", m.scratch_high_water });
    try out.print("  {s:<24} {d:>12}\n", .{ "check flow queries", m.flow_queries });

    const heap_total = worker_arena_bytes + m.interner_total;
    const bytes_per_line: f64 = if (m.lines > 0)
        @as(f64, @floatFromInt(heap_total)) / @as(f64, @floatFromInt(m.lines))
    else
        0;
    try out.print("  {s:<24} {d:>12}\n", .{ "heap total (arenas)", heap_total });
    try out.print("  {s:<24} {d:>12.2}\n", .{ "bytes/line (heap)", bytes_per_line });
}

// --- --census ---------------------------------------------------------------

/// The whole-run counters printed above the census histogram. The trees
/// themselves carry the per-construct data, so this is only the header line
/// material the driver already tallied.
pub const CensusTotals = struct {
    files: usize,
    lines: usize,
    parse_diags: usize,
    bind_diags: usize,
    check_diags: usize,
};

/// Census: a by-construct histogram of out-of-subset syntax across every
/// loaded file, sorted most-frequent first — the table that prioritizes
/// upcoming feature work over spec order. Each `.unsupported` AST node carries
/// its construct kind (classified at parse time), so this is a cheap read-only
/// whole-tree scan over the already-built trees, no re-parse and no allocation.
pub fn printCensus(out: *Io.Writer, trees: []const ?*Ast, totals: CensusTotals) !void {
    const Kind = ast.UnsupportedKind;
    const nkinds = @typeInfo(Kind).@"enum".fields.len;
    var counts = [_]u64{0} ** nkinds;
    var files_with: usize = 0;
    var total: u64 = 0;
    for (trees) |maybe_tree| {
        const tree = maybe_tree orelse continue;
        var file_has = false;
        var i: u32 = 0;
        const nc: u32 = @intCast(tree.nodeCount());
        while (i < nc) : (i += 1) {
            if (tree.nodeTag(i) == .unsupported) {
                counts[@intFromEnum(tree.unsupportedKind(i))] += 1;
                total += 1;
                file_has = true;
            }
        }
        if (file_has) files_with += 1;
    }

    try out.print("\n--census\n", .{});
    try out.print("  files: {d} scanned ({d} lines), {d} with out-of-subset syntax\n", .{ totals.files, totals.lines, files_with });
    try out.print("  diagnostics: {d} parse, {d} bind, {d} check\n", .{ totals.parse_diags, totals.bind_diags, totals.check_diags });
    try out.print("  out-of-subset constructs: {d} total\n", .{total});

    // Sort kind indices by descending count for the priority table.
    var order: [nkinds]usize = undefined;
    for (0..nkinds) |k| order[k] = k;
    std.mem.sort(usize, &order, @as(*const [nkinds]u64, &counts), struct {
        fn desc(c: *const [nkinds]u64, a: usize, b: usize) bool {
            return c[a] > c[b];
        }
    }.desc);

    try out.print("  {s:<32} {s:>9} {s:>7}\n", .{ "construct", "count", "share" });
    for (order) |k| {
        if (counts[k] == 0) continue;
        const kind: Kind = @enumFromInt(k);
        const share = @as(f64, @floatFromInt(counts[k])) * 100.0 /
            @as(f64, @floatFromInt(if (total == 0) 1 else total));
        try out.print("  {s:<32} {d:>9} {d:>6.1}%\n", .{ kind.label(), counts[k], share });
    }
}

test "printTiming renders one row per phase and per checker" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try printTiming(
        &out.writer,
        .{
            .load_ns = 1_000_000,
            .scan_ns = 2_000_000,
            .parse_ns = 3_000_000,
            .bind_ns = 4_000_000,
            .resolve_ns = 5_000_000,
            .discover_ns = 6_000_000,
            .link_ns = 7_000_000,
            .check_ns = 8_000_000,
            .total_ns = 9_000_000,
        },
        .{ .lines = 100, .bytes = 2048, .repeat = 1 },
        &.{ .{ .ns = 1_000_000, .files = 3 }, .{ .ns = 2_000_000, .files = 4 } },
        .{
            .probes = 11,
            .lookups = 22,
            .hits = 20,
            .enabled = true,
            .nm_dirs = 1,
            .pkg_json = 2,
            .real_dirs = 3,
            .fs_bytes = 1024,
        },
    );
    const s = out.written();
    try std.testing.expect(std.mem.startsWith(u8, s, "\n--timing\n"));
    try std.testing.expect(std.mem.indexOf(u8, s, "  load            1.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  total           9.000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "    checker[1]      2.000 ms  4 file(s)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "resolve cache: 11 probes, 22 lookups, 20 hits (enabled)\n") != null);
}

test "printMemory sums the worker arenas into the heap total" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const m: Memory = .{
        .worker_arena_bytes = &.{ 100, 200 },
        .interner_total = 50,
        .interner_strings = 0,
        .line_table_bytes = 0,
        .token_bytes = 0,
        .source_bytes = 0,
        .pack_text = 0,
        .pack_reserved = 0,
        .tokens = 0,
        .lines = 0,
        .nodes = 0,
        .node_bytes = 0,
        .extra_bytes = 0,
        .ast_token_bytes = 0,
        .symbols = 0,
        .scopes = 0,
        .flows = 0,
        .bind_symbol_bytes = 0,
        .bind_scope_bytes = 0,
        .bind_flow_bytes = 0,
        .bind_record_bytes = 0,
        .graph_bytes = 0,
        .checkers = &.{.{ .index = 0, .types = 7, .type_bytes = 700 }},
        .check_types = 0,
        .check_type_bytes = 0,
        .rel_entries = 0,
        .rel_bytes = 0,
        .rel_hits = 0,
        .rel_misses = 0,
        .inst_hits = 0,
        .inst_misses = 0,
        .inst_maps = 0,
        .nt_hits = 0,
        .nt_misses = 0,
        .scratch_high_water = 0,
        .flow_queries = 0,
    };
    try printMemory(&out.writer, m);
    const s = out.written();
    try std.testing.expect(std.mem.startsWith(u8, s, "\n--memory\n"));
    try std.testing.expect(std.mem.indexOf(u8, s, "  checker[0] types                   7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  heap total (arenas)               350\n") != null);
    // Every derived rate divides by zero-valued denominators safely.
    try std.testing.expect(std.mem.indexOf(u8, s, "  bytes/token                      0.00\n") != null);
}
