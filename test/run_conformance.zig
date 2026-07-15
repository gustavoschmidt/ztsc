//! Conformance suite runner (M4 single-file + M5 multi-file).
//!
//! Discovers cases under `test/conformance/` (recursively, one directory
//! level of area folders). Two case shapes:
//!
//! - **Single file**: `<name>.ts` with an expected-diagnostics snapshot
//!   `<name>.expected` next to it. Snapshot lines: `TS<code> <line>`.
//! - **Directory (M5)**: a folder containing `entry.ts`; the whole module
//!   graph is discovered from the entry (relative imports, case-local
//!   `node_modules`). Snapshot file `expected` inside the folder with
//!   lines: `TS<code> <relative-file> <line>`.
//!
//! Snapshots are generated from real `tsc 5.5` output (`--strict --noEmit
//! --target esnext --module esnext --moduleResolution bundler
//! --allowImportingTsExtensions`; see test/conformance/README.md) and
//! hand-verified. `#` lines are comments; an empty or absent snapshot
//! means the case must be diagnostic-free.
//!
//! Matching: the multiset of (code, file, line) pairs must match exactly.
//! Message text is informational and not compared (documented in PLAN §3
//! as code+span; we compare code+line so byte-offset drift in messages
//! doesn't churn snapshots).
//!
//! This file also hosts the M5 determinism and cycle-stress tests:
//! checking a program partitioned across N ∈ {1, 2, 4, 8} checker
//! instances must render byte-identical diagnostics.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const ztsc = @import("ztsc");

const parser = ztsc.parser;
const binder = ztsc.binder;
const checker = ztsc.checker;
const modules = ztsc.modules;
const Interner = ztsc.intern.Interner;

const Expected = struct { code: u16, file: []const u8, line: u32 };

const Case = struct {
    /// Path relative to the conformance dir (area/name.ts or area/name).
    rel: []const u8,
    is_dir: bool,
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
                if (!std.mem.endsWith(u8, entry.name, ".ts") and !std.mem.endsWith(u8, entry.name, ".tsx")) continue;
                try cases.append(gpa, .{ .rel = try gpa.dupe(u8, entry.name), .is_dir = false });
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var sit = sub.iterate();
                while (try sit.next(io)) |sentry| {
                    switch (sentry.kind) {
                        .file => {
                            if (!std.mem.endsWith(u8, sentry.name, ".ts") and !std.mem.endsWith(u8, sentry.name, ".tsx")) continue;
                            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ entry.name, sentry.name });
                            try cases.append(gpa, .{ .rel = rel, .is_dir = false });
                        },
                        .directory => {
                            // A directory case iff it contains entry.ts.
                            var case_dir = sub.openDir(io, sentry.name, .{}) catch continue;
                            defer case_dir.close(io);
                            case_dir.access(io, "entry.ts", .{}) catch continue;
                            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ entry.name, sentry.name });
                            try cases.append(gpa, .{ .rel = rel, .is_dir = true });
                        },
                        else => {},
                    }
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

fn parseExpected(alloc: std.mem.Allocator, text: []const u8, multi_file: bool) !std.ArrayList(Expected) {
    var out: std.ArrayList(Expected) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trim(u8, line0, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // "TS2322 5" or "TS2322 entry.ts 5"
        if (!std.mem.startsWith(u8, line, "TS")) return error.BadSnapshot;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadSnapshot;
        const code = try std.fmt.parseInt(u16, line[2..sp], 10);
        const rest = std.mem.trim(u8, line[sp + 1 ..], " \t");
        if (multi_file) {
            const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.BadSnapshot;
            const file = std.mem.trim(u8, rest[0..sp2], " \t");
            const lineno = try std.fmt.parseInt(u32, std.mem.trim(u8, rest[sp2 + 1 ..], " \t"), 10);
            try out.append(alloc, .{ .code = code, .file = file, .line = lineno });
        } else {
            const lineno = try std.fmt.parseInt(u32, rest, 10);
            try out.append(alloc, .{ .code = code, .file = "", .line = lineno });
        }
    }
    return out;
}

/// Run the single-file pipeline on `src`, returning (code, line) pairs.
fn runCase(alloc: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, interner: *Interner, src: []const u8, jsx: bool) !std.ArrayList(Expected) {
    var out: std.ArrayList(Expected) = .empty;
    errdefer out.deinit(alloc);

    const line_starts = try ztsc.source.computeLineStarts(alloc, src);
    const tree = try alloc.create(ztsc.ast.Ast);
    tree.* = try parser.parseOpts(alloc, src, jsx);
    const bound = try alloc.create(binder.Bind);
    bound.* = try binder.bind(alloc, io, gpa, interner, tree, src);
    // Single-file cases run against the injected ES-core lib (file 0), just
    // like the CLI. Only the case file (id 1) is owned/reported.
    const prog = try alloc.create(modules.Program);
    prog.* = try modules.singleWithLibProgram(alloc, io, gpa, interner, "", src, tree, bound, false);
    const owned = try alloc.alloc(modules.FileId, 1);
    owned[0] = @intCast(prog.files.len - 1);
    // Exercise the shared frozen base type store (M14.5), like the CLI default.
    const base = try alloc.create(ztsc.types.Store);
    base.* = try checker.buildBaseStore(alloc, io, gpa, interner, prog);
    const result = try checker.checkFiles(alloc, io, gpa, interner, prog, owned, base, true);

    // Parser-surfaced diagnostics with a tsc analogue (e.g. TS1206 parameter
    // decorators); other parser codes map to tsCode 0 and are ignored.
    for (tree.diagnostics) |d| {
        const ts = d.code.tsCode();
        if (ts == 0) continue;
        try out.append(alloc, .{ .code = ts, .file = "", .line = lineOf(line_starts, d.span.start) });
    }
    for (bound.diagnostics) |d| {
        const ts = d.code.tsCode();
        if (ts == 0) continue;
        try out.append(alloc, .{ .code = ts, .file = "", .line = lineOf(line_starts, d.span.start) });
    }
    for (result.diagnostics) |d| {
        try out.append(alloc, .{ .code = d.code, .file = "", .line = lineOf(line_starts, d.span.start) });
    }
    return out;
}

/// Run the full multi-file pipeline on a directory case: discover from
/// entry.ts, link, check (single checker instance owns all files).
/// Returned file names are relative to the case directory.
fn runDirCase(
    alloc: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    interner: *Interner,
    conf_dir: Io.Dir,
    case_rel: []const u8,
) !std.ArrayList(Expected) {
    var out: std.ArrayList(Expected) = .empty;
    errdefer out.deinit(alloc);

    const entry = try std.fmt.allocPrint(alloc, "{s}/entry.ts", .{case_rel});
    const br = try modules.buildProgram(alloc, io, gpa, interner, conf_dir, &.{entry}, false);
    const prog = &br.program;

    const owned = try alloc.alloc(modules.FileId, prog.files.len);
    for (owned, 0..) |*f, i| f.* = @intCast(i);
    const base = try alloc.create(ztsc.types.Store);
    base.* = try checker.buildBaseStore(alloc, io, gpa, interner, prog);
    const result = try checker.checkFiles(alloc, io, gpa, interner, prog, owned, base, true);

    for (prog.files, 0..) |*pf, i| {
        // Skip the injected lib (file 0): tsc does not diagnose the default
        // lib, and neither does the CLI (main.zig print loop). The vendored
        // real 5.5.4 lib is census-clean but trips a few ztsc-incompleteness
        // diagnostics; suppress them here too so multi-file snapshots stay a
        // fair user-code differential.
        if (std.mem.eql(u8, pf.path, modules.lib_path)) continue;
        const rel = if (std.mem.startsWith(u8, pf.path, case_rel) and pf.path.len > case_rel.len + 1)
            pf.path[case_rel.len + 1 ..]
        else
            pf.path;
        const line_starts = try ztsc.source.computeLineStarts(alloc, pf.src);
        for (pf.tree.diagnostics) |d| {
            const ts = d.code.tsCode();
            if (ts == 0) continue;
            try out.append(alloc, .{ .code = ts, .file = rel, .line = lineOf(line_starts, d.span.start) });
        }
        for (pf.bind.diagnostics) |d| {
            const ts = d.code.tsCode();
            if (ts == 0) continue;
            try out.append(alloc, .{ .code = ts, .file = rel, .line = lineOf(line_starts, d.span.start) });
        }
        for (prog.links[i].diags) |d| {
            try out.append(alloc, .{ .code = d.code, .file = rel, .line = lineOf(line_starts, d.span.start) });
        }
        for (result.diagnostics) |d| {
            if (d.file != i) continue;
            try out.append(alloc, .{ .code = d.code, .file = rel, .line = lineOf(line_starts, d.span.start) });
        }
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

fn expectedLessThan(_: void, x: Expected, y: Expected) bool {
    switch (std.mem.order(u8, x.file, y.file)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (x.line != y.line) return x.line < y.line;
    return x.code < y.code;
}

fn multisetEqual(alloc: std.mem.Allocator, a: []Expected, b: []Expected) !bool {
    if (a.len != b.len) return false;
    const ac = try alloc.dupe(Expected, a);
    const bc = try alloc.dupe(Expected, b);
    std.mem.sort(Expected, ac, {}, expectedLessThan);
    std.mem.sort(Expected, bc, {}, expectedLessThan);
    for (ac, bc) |x, y| {
        if (x.code != y.code or x.line != y.line or !std.mem.eql(u8, x.file, y.file)) return false;
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
    var ran_multi: usize = 0;
    for (cases.items) |case| {
        const alloc = arena.allocator();

        // Expected snapshot (absent/empty = clean).
        var expected: std.ArrayList(Expected) = .empty;
        // `<name>.ts`/`<name>.tsx` -> `<name>.expected` (keep the dot).
        const stem = if (std.mem.endsWith(u8, case.rel, ".tsx"))
            case.rel[0 .. case.rel.len - 3]
        else
            case.rel[0 .. case.rel.len - 2];
        const exp_path = if (case.is_dir)
            try std.fmt.allocPrint(alloc, "{s}/expected", .{case.rel})
        else
            try std.fmt.allocPrint(alloc, "{s}expected", .{stem});
        if (dir.readFileAlloc(io, exp_path, alloc, .limited(1 << 20))) |exp_text| {
            expected = parseExpected(alloc, exp_text, case.is_dir) catch {
                std.debug.print("conformance: {s}: bad snapshot format\n", .{case.rel});
                failed += 1;
                continue;
            };
        } else |_| {}

        const got = blk: {
            if (case.is_dir) {
                ran_multi += 1;
                break :blk runDirCase(alloc, io, gpa, &interner, dir, case.rel) catch |err| {
                    std.debug.print("conformance: {s}: pipeline failed: {s}\n", .{ case.rel, @errorName(err) });
                    failed += 1;
                    continue;
                };
            }
            const src = dir.readFileAlloc(io, case.rel, alloc, .limited(1 << 20)) catch |err| {
                std.debug.print("conformance: {s}: read failed: {s}\n", .{ case.rel, @errorName(err) });
                failed += 1;
                continue;
            };
            break :blk runCase(alloc, io, gpa, &interner, src, parser.isJsxPath(case.rel)) catch |err| {
                std.debug.print("conformance: {s}: pipeline failed: {s}\n", .{ case.rel, @errorName(err) });
                failed += 1;
                continue;
            };
        };
        ran += 1;
        if (!try multisetEqual(alloc, got.items, expected.items)) {
            failed += 1;
            std.debug.print("conformance FAIL: {s}\n  expected:", .{case.rel});
            for (expected.items) |e| std.debug.print(" TS{d}@{s}:{d}", .{ e.code, e.file, e.line });
            std.debug.print("\n  got:     ", .{});
            for (got.items) |e| std.debug.print(" TS{d}@{s}:{d}", .{ e.code, e.file, e.line });
            std.debug.print("\n", .{});
        }
        _ = arena.reset(.retain_capacity);
    }

    if (ran > 0) {
        std.debug.print("conformance: {d}/{d} cases passed ({d} multi-file)\n", .{ ran - failed, ran, ran_multi });
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// ===========================================================================
// M5: determinism & cycle stress
// ===========================================================================

/// Render a program's full diagnostics (link + check) the way main.zig
/// does: per file in id order, (position, code)-sorted, one line each.
fn renderProgramDiags(
    alloc: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    interner: *Interner,
    prog: *const modules.Program,
    n_checkers: usize,
) ![]u8 {
    // One shared frozen base across all overlay checkers (M14.5): this is the
    // cross-N determinism oracle — independent overlays over one frozen base
    // must still yield byte-identical diagnostics.
    const base = try alloc.create(ztsc.types.Store);
    base.* = try checker.buildBaseStore(alloc, io, gpa, interner, prog);
    // Round-robin partition, one checkFiles call per checker instance.
    const results = try alloc.alloc(checker.Check, n_checkers);
    for (0..n_checkers) |k| {
        var owned: std.ArrayList(modules.FileId) = .empty;
        var i: usize = k;
        while (i < prog.files.len) : (i += n_checkers) {
            try owned.append(alloc, @intCast(i));
        }
        results[k] = try checker.checkFiles(alloc, io, gpa, interner, prog, owned.items, base, true);
    }

    const Line = struct { start: u32, code: u16, msg: []const u8 };
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (prog.files, 0..) |*pf, i| {
        var merged: std.ArrayList(Line) = .empty;
        for (prog.links[i].diags) |d| {
            try merged.append(alloc, .{ .start = d.span.start, .code = d.code, .msg = d.msg });
        }
        const owner = i % n_checkers;
        for (results[owner].diagnostics) |d| {
            if (d.file != i) continue;
            try merged.append(alloc, .{ .start = d.span.start, .code = d.code, .msg = d.msg });
        }
        std.mem.sort(Line, merged.items, {}, struct {
            fn lessThan(_: void, x: Line, y: Line) bool {
                if (x.start != y.start) return x.start < y.start;
                return x.code < y.code;
            }
        }.lessThan);
        for (merged.items) |d| {
            out.writer.print("{s}:{d}: TS{d}: {s}\n", .{ pf.path, d.start, d.code, d.msg }) catch
                return error.OutOfMemory;
        }
    }
    return alloc.dupe(u8, out.written());
}

test "determinism: diagnostics byte-identical for N = 1, 2, 4, 8 checkers" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // A program with errors sprinkled across many files, cross-imports,
    // re-exports, a missing module and a missing export.
    try d.writeFile(io, .{ .sub_path = "base.ts", .data =
        \\export interface Item { id: number; label: string; }
        \\export function mk(id: number, label: string): Item {
        \\  return { id: id, label: label };
        \\}
        \\export const seed: number = 1;
    });
    var name_buf: [64]u8 = undefined;
    var body_buf: [512]u8 = undefined;
    for (0..8) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.ts", .{i});
        const body = try std.fmt.bufPrint(&body_buf,
            \\import {{ mk, seed, Item }} from "./base";
            \\import {{ v{d} }} from "./f{d}";
            \\export const v{d}: number = seed + {d};
            \\const item: Item = mk(v{d}, {d});
            \\export const bad{d}: string = seed;
            \\const use = v{d};
        , .{ (i + 1) % 8, (i + 1) % 8, i, i, i, i, i, (i + 1) % 8 });
        try d.writeFile(io, .{ .sub_path = name, .data = body });
    }
    try d.writeFile(io, .{ .sub_path = "entry.ts", .data =
        \\import { v0 } from "./f0";
        \\import { v3 } from "./f3";
        \\import { ghost } from "./base";
        \\import { gone } from "./missing";
        \\export { v7 } from "./f7";
        \\const n: string = v0 + v3;
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(gpa);
    const alloc = arena.allocator();

    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, &.{"entry.ts"}, true);
    try std.testing.expectEqual(@as(usize, 10), br.program.files.len);

    const ref = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, 1);
    // The program must actually produce a healthy number of diagnostics
    // spread across files for this test to mean anything.
    try std.testing.expect(std.mem.count(u8, ref, "\n") >= 10);
    for ([_]usize{ 2, 4, 8 }) |n| {
        const got = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, n);
        try std.testing.expectEqualStrings(ref, got);
    }
}

test "cycle stress: N-file import ring + diamonds terminate cleanly" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // 48-file ring: each file imports the next one's export (type + value)
    // and re-exports its own; plus diamond edges to two "hub" files.
    const n_ring = 48;
    try d.writeFile(io, .{ .sub_path = "hub_a.ts", .data =
        \\export const ha: number = 1;
        \\export interface HA { tag: "a"; n: number; }
    });
    try d.writeFile(io, .{ .sub_path = "hub_b.ts", .data =
        \\export const hb: number = 2;
        \\export interface HB { tag: "b"; n: number; }
    });
    var name_buf: [64]u8 = undefined;
    var body_buf: [1024]u8 = undefined;
    for (0..n_ring) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "r{d}.ts", .{i});
        const body = try std.fmt.bufPrint(&body_buf,
            \\import {{ x{d}, T{d} }} from "./r{d}";
            \\import {{ ha, HA }} from "./hub_a";
            \\import {{ hb, HB }} from "./hub_b";
            \\export const x{d}: number = ha + hb;
            \\export interface T{d} {{ v: number; prev?: T{d}; }}
            \\export function probe{d}(t: T{d}, u: HA | HB): number {{
            \\  if (u.tag === "a") return t.v + u.n;
            \\  return x{d} + u.n;
            \\}}
            \\const back: number = x{d};
        , .{ (i + 1) % n_ring, (i + 1) % n_ring, (i + 1) % n_ring, i, i, (i + 1) % n_ring, i, i, i, (i + 1) % n_ring });
        try d.writeFile(io, .{ .sub_path = name, .data = body });
    }
    try d.writeFile(io, .{ .sub_path = "entry.ts", .data =
        \\import { x0 } from "./r0";
        \\import { probe7 } from "./r7";
        \\const n: number = probe7({ v: x0 }, { tag: "a", n: 3 });
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(gpa);
    const alloc = arena.allocator();

    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, &.{"entry.ts"}, true);
    try std.testing.expectEqual(@as(usize, n_ring + 3), br.program.files.len);

    // Clean at N=1, and byte-identical (still clean) at higher N — no
    // hangs, no duplicated diagnostics.
    const ref = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, 1);
    try std.testing.expectEqualStrings("", ref);
    for ([_]usize{ 2, 4, 8 }) |n| {
        const got = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, n);
        try std.testing.expectEqualStrings(ref, got);
    }
}

test "determinism: cross-file base cycles report identically for N = 1, 2, 4, 8" {
    // Regression for M17.2. Many mutually-unrelated "packages", each a pair of
    // files whose interfaces form a cross-file `extends` cycle (A extends B,
    // B extends A) plus a conflicting `declare global`. A base cycle is a
    // *content* diagnostic (TS2310), and the checker's cycle detection used to
    // report on only whichever member the resolution reached first — a set
    // that shifts with the checker partition, so `--checkers` changed the
    // diagnostics themselves, not just their order. Now every interface on the
    // cycle is reported (matching tsc), independent of order, so the output is
    // byte-identical across N.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    const clusters = 8;
    var name_buf: [64]u8 = undefined;
    var body_buf: [512]u8 = undefined;
    var entry_buf: [1024]u8 = undefined;
    var entry: std.ArrayListUnmanaged(u8) = .empty;
    defer entry.deinit(gpa);
    for (0..clusters) |i| {
        // a{i}.d.ts: interface A{i} extends B{i}; conflicting global.
        var name = try std.fmt.bufPrint(&name_buf, "a{d}.d.ts", .{i});
        var body = try std.fmt.bufPrint(&body_buf,
            \\import {{ B{d} }} from "./b{d}";
            \\export interface A{d} extends B{d} {{ a{d}: number; }}
            \\declare global {{ var conflict: {d}; }}
            \\export {{}};
        , .{ i, i, i, i, i, i });
        try d.writeFile(io, .{ .sub_path = name, .data = body });
        // b{i}.d.ts: interface B{i} extends A{i} — closes the cycle.
        name = try std.fmt.bufPrint(&name_buf, "b{d}.d.ts", .{i});
        body = try std.fmt.bufPrint(&body_buf,
            \\import {{ A{d} }} from "./a{d}";
            \\export interface B{d} extends A{d} {{ b{d}: string; }}
            \\export {{}};
        , .{ i, i, i, i, i });
        try d.writeFile(io, .{ .sub_path = name, .data = body });
        const line = try std.fmt.bufPrint(&entry_buf,
            \\import {{ A{d} }} from "./a{d}";
            \\import {{ B{d} }} from "./b{d}";
            \\
        , .{ i, i, i, i });
        try entry.appendSlice(gpa, line);
    }
    try d.writeFile(io, .{ .sub_path = "entry.d.ts", .data = entry.items });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(gpa);
    const alloc = arena.allocator();

    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, &.{"entry.d.ts"}, true);

    const ref = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, 1);
    // Every interface on every cycle is reported: 2 per cluster.
    try std.testing.expectEqual(@as(usize, 2 * clusters), std.mem.count(u8, ref, "TS2310"));
    for ([_]usize{ 2, 4, 8 }) |n| {
        const got = try renderProgramDiags(alloc, io, gpa, &interner, &br.program, n);
        try std.testing.expectEqualStrings(ref, got);
    }
}
