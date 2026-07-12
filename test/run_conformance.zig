//! Conformance suite runner (M4).
//!
//! Discovers cases under `test/conformance/` (recursively, one directory
//! level of area folders): each case is a `<name>.ts` source with an
//! expected-diagnostics snapshot `<name>.expected` next to it. Snapshots
//! are generated from real `tsc --strict --noEmit --target esnext` output
//! (see test/conformance/README.md) and hand-verified.
//!
//! Snapshot format: one diagnostic per line, `TS<code> <line>` (1-based
//! line of the error start). `#` lines are comments. An empty or absent
//! `.expected` file means the case must be diagnostic-free.
//!
//! Matching: the multiset of (code, line) pairs must match exactly.
//! Message text is informational and not compared (documented in PLAN §3
//! as code+span; we compare code+line so byte-offset drift in messages
//! doesn't churn snapshots).

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const ztsc = @import("ztsc");

const parser = ztsc.parser;
const binder = ztsc.binder;
const checker = ztsc.checker;
const Interner = ztsc.intern.Interner;

const Expected = struct { code: u16, line: u32 };

const Case = struct {
    /// Path relative to the conformance dir (area/name.ts).
    rel: []const u8,
};

fn discoverCases(io: Io, gpa: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(Case) {
    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |c| gpa.free(c.rel);
        cases.deinit(gpa);
    }

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return cases,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;
                try cases.append(gpa, .{ .rel = try gpa.dupe(u8, entry.name) });
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var sit = sub.iterate();
                while (try sit.next(io)) |sentry| {
                    if (sentry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, sentry.name, ".ts")) continue;
                    const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ entry.name, sentry.name });
                    try cases.append(gpa, .{ .rel = rel });
                }
            },
            else => {},
        }
    }
    std.mem.sort(Case, cases.items, {}, struct {
        fn lessThan(_: void, a: Case, b: Case) bool {
            return std.mem.order(u8, a.rel, b.rel) == .lt;
        }
    }.lessThan);
    return cases;
}

fn parseExpected(alloc: std.mem.Allocator, text: []const u8) !std.ArrayList(Expected) {
    var out: std.ArrayList(Expected) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trim(u8, line0, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // "TS2322 5"
        if (!std.mem.startsWith(u8, line, "TS")) return error.BadSnapshot;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadSnapshot;
        const code = try std.fmt.parseInt(u16, line[2..sp], 10);
        const lineno = try std.fmt.parseInt(u32, std.mem.trim(u8, line[sp + 1 ..], " \t"), 10);
        try out.append(alloc, .{ .code = code, .line = lineno });
    }
    return out;
}

/// Run the real pipeline on `src`, returning produced (code, line) pairs.
/// Includes binder diagnostics with tsc codes (2451, 2300, ...) — tsc
/// reports those too.
fn runCase(alloc: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, interner: *Interner, src: []const u8) !std.ArrayList(Expected) {
    var out: std.ArrayList(Expected) = .empty;
    errdefer out.deinit(alloc);

    const line_starts = try ztsc.source.computeLineStarts(alloc, src);
    const tree = try alloc.create(ztsc.ast.Ast);
    tree.* = try parser.parse(alloc, src);
    const bound = try alloc.create(binder.Bind);
    bound.* = try binder.bind(alloc, io, gpa, interner, tree, src);
    const result = try checker.check(alloc, io, gpa, interner, tree, bound, src);

    for (bound.diagnostics) |d| {
        const ts = d.code.tsCode();
        if (ts == 0) continue;
        try out.append(alloc, .{ .code = ts, .line = lineOf(line_starts, d.span.start) });
    }
    for (result.diagnostics) |d| {
        try out.append(alloc, .{ .code = d.code, .line = lineOf(line_starts, d.span.start) });
    }
    return out;
}

fn lineOf(line_starts: []const u32, offset: u32) u32 {
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo + 1); // 1-based
}

fn multisetEqual(alloc: std.mem.Allocator, a: []Expected, b: []Expected) !bool {
    if (a.len != b.len) return false;
    const lessThan = struct {
        fn f(_: void, x: Expected, y: Expected) bool {
            if (x.line != y.line) return x.line < y.line;
            return x.code < y.code;
        }
    }.f;
    const ac = try alloc.dupe(Expected, a);
    const bc = try alloc.dupe(Expected, b);
    std.mem.sort(Expected, ac, {}, lessThan);
    std.mem.sort(Expected, bc, {}, lessThan);
    for (ac, bc) |x, y| {
        if (x.code != y.code or x.line != y.line) return false;
    }
    return true;
}

test "conformance: discover and run cases" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var cases = try discoverCases(io, gpa, build_options.conformance_dir);
    defer {
        for (cases.items) |c| gpa.free(c.rel);
        cases.deinit(gpa);
    }

    var dir = try Io.Dir.cwd().openDir(io, build_options.conformance_dir, .{});
    defer dir.close(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(gpa);

    var failed: usize = 0;
    var ran: usize = 0;
    for (cases.items) |case| {
        const alloc = arena.allocator();
        const src = dir.readFileAlloc(io, case.rel, alloc, .limited(1 << 20)) catch |err| {
            std.debug.print("conformance: {s}: read failed: {s}\n", .{ case.rel, @errorName(err) });
            failed += 1;
            continue;
        };
        // Expected snapshot (absent/empty = clean).
        var expected: std.ArrayList(Expected) = .empty;
        const exp_path = try std.fmt.allocPrint(alloc, "{s}expected", .{case.rel[0 .. case.rel.len - 2]});
        if (dir.readFileAlloc(io, exp_path, alloc, .limited(1 << 20))) |exp_text| {
            expected = parseExpected(alloc, exp_text) catch {
                std.debug.print("conformance: {s}: bad snapshot format\n", .{case.rel});
                failed += 1;
                continue;
            };
        } else |_| {}

        const got = runCase(alloc, io, gpa, &interner, src) catch |err| {
            std.debug.print("conformance: {s}: pipeline failed: {s}\n", .{ case.rel, @errorName(err) });
            failed += 1;
            continue;
        };
        ran += 1;
        if (!try multisetEqual(alloc, got.items, expected.items)) {
            failed += 1;
            std.debug.print("conformance FAIL: {s}\n  expected:", .{case.rel});
            for (expected.items) |e| std.debug.print(" TS{d}@{d}", .{ e.code, e.line });
            std.debug.print("\n  got:     ", .{});
            for (got.items) |e| std.debug.print(" TS{d}@{d}", .{ e.code, e.line });
            std.debug.print("\n", .{});
        }
        _ = arena.reset(.retain_capacity);
    }

    if (ran > 0) {
        std.debug.print("conformance: {d}/{d} cases passed\n", .{ ran - failed, ran });
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
