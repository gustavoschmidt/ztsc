//! Check-phase scheduling: how many checker instances a program runs, how its
//! files are split across them, and the task one instance performs.
//!
//! Everything here is a pure function of numbers the front end already
//! produced (per-file AST node counts) plus the CLI's explicit overrides — no
//! I/O, no allocation beyond the caller's arena, no globals. That is what
//! makes the split reproducible: the same node counts and the same
//! `--checkers=N` always yield the same partition, so diagnostics stay
//! byte-identical for any checker count (see the determinism tests).
//!
//! The `--partition-file` benchmark aid is parsed here too, but READ in
//! main.zig: this file never touches the filesystem.

const std = @import("std");
const Io = std.Io;
const driver = @import("driver.zig");
const modules = @import("link/modules.zig");
const checker = @import("checker.zig");
const types = @import("types.zig");
const intern = @import("intern.zig");

const Interner = intern.Interner;
const FileId = modules.FileId;
const Timer = driver.Timer;

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

pub fn defaultCheckers(
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
pub const CheckerTask = struct {
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    owned: []const FileId = &.{},
    /// Shared frozen base type store, or null under
    /// `--no-frozen-store`. Read-only; the same pointer is handed to every
    /// task so all overlays share one base.
    base: ?*const types.Store = null,
    /// Enable the instantiation caching layer (`false` under
    /// `--no-inst-cache`).
    inst_cache: bool = true,
    /// This run's checker options (instruments and bisect legs). The same
    /// value is copied into every task, so all instances see identical
    /// options — see `checker.Options`.
    opts: checker.Options = .{},
    /// Node count to size this instance's type-store reserve from, or 0 to
    /// size it from its own partition. Non-zero only for a program whose
    /// declaration surface is not divisible (`declaration_heavy_ratio`),
    /// where every instance interns roughly the whole program's types.
    type_reserve_hint: usize = 0,
    result: ?checker.Check = null,
    err: ?anyerror = null,
    ns: u64 = 0,

    pub fn run(
        t: *CheckerTask,
        io: Io,
        gpa: std.mem.Allocator,
        interner: *Interner,
        prog: *const modules.Program,
    ) void {
        const timer = Timer.start(io);
        t.result = checker.checkFiles(t.arena.allocator(), io, gpa, interner, prog, t.owned, t.base, t.inst_cache, t.type_reserve_hint, t.opts) catch |err| blk: {
            t.err = err;
            break :blk null;
        };
        t.ns = timer.readNs();
    }
};

/// One file's share of the check phase: its id and its weight.
pub const Item = struct { file: FileId, cost: u64 };

/// The program's check work, as the partition and the checker count see it.
pub const Work = struct {
    /// The files that will be walked, in file-id order, with their weights.
    items: []Item,
    /// Total weight of `items` — the work there is to spread.
    check_nodes: u64,
    /// Every parsed node, enqueued or not. The part that is NOT enqueued is
    /// the declaration surface (`.d.ts` under skipLibCheck, the embedded lib
    /// under skipDefaultLibCheck): never walked, but materialized on demand —
    /// once per checker instance that reaches it. See
    /// `declaration_heavy_ratio`.
    parsed_nodes: u64,
};

/// The cost model: per-file AST node count ≈ per-file check cost (known
/// post-parse). `skipped[i]` drops file `i` from the check phase entirely —
/// the embedded lib under `skipDefaultLibCheck`, a non-lib `.d.ts` under
/// `skipLibCheck` — but its nodes still count toward `parsed_nodes`, because
/// a skipped file's types are still materialized on demand.
pub fn costModel(
    arena: std.mem.Allocator,
    node_counts: []const u64,
    skipped: []const bool,
) !Work {
    std.debug.assert(node_counts.len == skipped.len);
    var items: std.ArrayList(Item) = .empty;
    try items.ensureTotalCapacity(arena, node_counts.len);
    var w: Work = .{ .items = &.{}, .check_nodes = 0, .parsed_nodes = 0 };
    for (node_counts, skipped, 0..) |cost, skip, i| {
        w.parsed_nodes += cost;
        if (skip) continue;
        w.check_nodes += cost;
        items.appendAssumeCapacity(.{ .file = @intCast(i), .cost = cost });
    }
    w.items = items.items;
    return w;
}

/// Split `items` across `n_checkers` instances, writing each file's owner into
/// `file_owner` (indexed by file id; files absent from `items` keep checker 0)
/// and returning each instance's owned list in walk order.
///
/// Locality-aware and balanced. File ids are BFS positions in the import graph
/// (see the renumbering in driver.zig), so a contiguous id range is
/// import-adjacent and its dependency closures largely overlap: checking that
/// range on one checker materializes each foreign type once instead of once
/// per checker that reaches it.
///
/// Pure contiguity (one range per checker) wins the locality but loses the
/// wall clock — node count mispredicts check time region by region, so one
/// checker straggles. Cutting the order into two equal-node-weight runs per
/// checker and dealing the runs longest-first onto the least-loaded checker
/// (LPT) keeps most of the locality and pairs an expensive region with a cheap
/// one. Measured on a 6.1k-file project at --checkers=4: check 265 -> 242 ms,
/// peak RSS 226 -> 218 MB. k = 1 leaves a straggler; k >= 3 fragments the
/// locality without buying the balance back, and both measured slower than
/// k = 2, as did a boustrophedon deal, a DFS (subtree-contiguous) order, and
/// re-weighting `.d.ts` nodes.
///
/// Deterministic: the order is the file ids, the weights are fixed post-parse,
/// and every tie breaks by run start / checker index, so any --checkers=N
/// still yields byte-identical diagnostics. `items` is reordered in place (the
/// walk order below), which no caller reads back.
pub fn partition(
    arena: std.mem.Allocator,
    items: []Item,
    n_checkers: usize,
    file_owner: []u32,
    /// `--partition-file` contents, already read by main.zig, or null.
    override: ?[]const u8,
) ![]const []const FileId {
    @memset(file_owner, 0);
    const owned_lists = try arena.alloc(std.ArrayList(FileId), n_checkers);
    for (owned_lists) |*l| l.* = .empty;

    const Run = struct { start: usize, end: usize, cost: u64 };
    var runs: std.ArrayList(Run) = .empty;
    {
        var total_cost: u64 = 0;
        for (items) |it| total_cost += it.cost;
        const n_runs = n_checkers * 2;
        var acc: u64 = 0;
        var run_base: u64 = 0;
        var start: usize = 0;
        var r: usize = 0;
        for (items, 0..) |it, idx| {
            acc += it.cost;
            // Cumulative target, so rounding never drifts across cuts.
            if (acc >= total_cost * (r + 1) / n_runs and r + 1 < n_runs) {
                try runs.append(arena, .{ .start = start, .end = idx + 1, .cost = acc - run_base });
                run_base = acc;
                start = idx + 1;
                r += 1;
            }
        }
        if (start < items.len)
            try runs.append(arena, .{ .start = start, .end = items.len, .cost = acc - run_base });
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
        const slice = items[run.start..run.end];
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
    if (override) |text| {
        for (owned_lists) |*l| l.* = .empty;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const fid_s = it.next() orelse continue;
            const ck_s = it.next() orelse continue;
            const fid = std.fmt.parseInt(u32, fid_s, 10) catch continue;
            const ck = std.fmt.parseInt(u32, ck_s, 10) catch continue;
            if (fid >= file_owner.len) continue;
            file_owner[fid] = @intCast(ck % n_checkers);
        }
        const cost_by_file = try arena.alloc(u64, file_owner.len);
        @memset(cost_by_file, 0);
        for (items) |it| cost_by_file[it.file] = it.cost;
        for (items) |it| try owned_lists[file_owner[it.file]].append(arena, it.file);
        for (owned_lists) |*l| std.mem.sort(FileId, l.items, cost_by_file, struct {
            fn lessThan(cost: []const u64, x: FileId, y: FileId) bool {
                if (cost[x] != cost[y]) return cost[x] > cost[y];
                return x < y;
            }
        }.lessThan);
    }

    const owned = try arena.alloc([]const FileId, n_checkers);
    for (owned_lists, owned) |l, *o| o.* = l.items;
    return owned;
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

test "costModel: skipped files count as surface, not as work" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const counts = [_]u64{ 100, 200, 300, 0 };
    const skipped = [_]bool{ false, true, false, false };
    const w = try costModel(a.allocator(), &counts, &skipped);
    try std.testing.expectEqual(@as(u64, 400), w.check_nodes);
    try std.testing.expectEqual(@as(u64, 600), w.parsed_nodes);
    // A zero-cost file is still checked; only `skipped` removes one.
    try std.testing.expectEqual(@as(usize, 3), w.items.len);
    try std.testing.expectEqual(@as(FileId, 0), w.items[0].file);
    try std.testing.expectEqual(@as(FileId, 2), w.items[1].file);
    try std.testing.expectEqual(@as(FileId, 3), w.items[2].file);
}

test "partition: balances, keeps every file, and is order-stable" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Eight files whose weights fall off sharply: the LPT deal must not put
    // the two heaviest runs on the same checker.
    const costs = [_]u64{ 800, 100, 400, 50, 300, 25, 200, 10 };
    const n = costs.len;
    const items = try arena.alloc(Item, n);
    for (items, costs, 0..) |*it, c, i| it.* = .{ .file = @intCast(i), .cost = c };
    const file_owner = try arena.alloc(u32, n);
    const owned = try partition(arena, items, 2, file_owner, null);

    try std.testing.expectEqual(@as(usize, 2), owned.len);
    var seen: u64 = 0;
    var per_checker: [2]u64 = .{ 0, 0 };
    for (owned, 0..) |list, k| {
        for (list) |f| {
            try std.testing.expectEqual(@as(u32, @intCast(k)), file_owner[f]);
            seen |= @as(u64, 1) << @intCast(f);
            per_checker[k] += costs[f];
        }
    }
    // Every file is owned exactly once (the bitset saw all 8 and the lists
    // hold 8 entries between them).
    try std.testing.expectEqual(@as(u64, (1 << n) - 1), seen);
    try std.testing.expectEqual(n, owned[0].len + owned[1].len);
    // Neither checker got the whole program.
    try std.testing.expect(per_checker[0] > 0 and per_checker[1] > 0);
    // Within a checker the walk is biggest-first inside each dealt run, so
    // the first file a checker walks is never lighter than the run's rest.
    for (owned) |list| {
        if (list.len > 1) try std.testing.expect(costs[list[0]] >= costs[list[1]]);
    }

    // Same inputs, same answer — the property the determinism gate rests on.
    const items2 = try arena.alloc(Item, n);
    for (items2, costs, 0..) |*it, c, i| it.* = .{ .file = @intCast(i), .cost = c };
    const owner2 = try arena.alloc(u32, n);
    const owned2 = try partition(arena, items2, 2, owner2, null);
    try std.testing.expectEqualSlices(u32, file_owner, owner2);
    for (owned, owned2) |x, y| try std.testing.expectEqualSlices(FileId, x, y);
}

test "partition: --partition-file override wins, unmentioned files keep theirs" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const costs = [_]u64{ 10, 20, 30, 40 };
    const items = try arena.alloc(Item, costs.len);
    for (items, costs, 0..) |*it, c, i| it.* = .{ .file = @intCast(i), .cost = c };
    const file_owner = try arena.alloc(u32, costs.len);
    // File 3 is out of range and ignored; `9` wraps modulo the checker count;
    // a junk line is skipped.
    const owned = try partition(arena, items, 2, file_owner, "0 1\n1 9\nnot a pair\n7 0\n");

    try std.testing.expectEqual(@as(u32, 1), file_owner[0]);
    try std.testing.expectEqual(@as(u32, 1), file_owner[1]); // 9 % 2
    var total: usize = 0;
    for (owned) |l| total += l.len;
    try std.testing.expectEqual(costs.len, total);
    // Each checker's list stays sorted biggest-cost-first.
    for (owned) |list| {
        for (1..list.len) |i| try std.testing.expect(costs[list[i - 1]] >= costs[list[i]]);
    }
}
