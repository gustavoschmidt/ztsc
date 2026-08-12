//! Per-checker memory profiler — a diagnostic instrument, off unless
//! `--mem-profile` is passed.
//!
//! `--memory` already reports the LOGICAL size of a few things (`typeBytes`
//! sums `kinds.items.len` and `extra.items.len`, `relation bytes` multiplies
//! `capacity()` by an entry size). That is not what the RSS bar is stated in.
//! This instrument reports, per checker instance, the CAPACITY every container
//! holds, so the sum can be subtracted from the process peak and the remainder
//! named honestly as allocator retention.
//!
//! Three axes:
//!
//!   * **by container** — every `map_containers` entry plus the type store's
//!     six SoA arrays and its hash-consing map, at `capacity`, not `len`;
//!   * **resident vs mapped** for the demand-zeroed per-symbol arrays
//!     (`sym_types`/`sym_state`), via `mincore` — the number that says whether
//!     an array sized by the whole program's symbol space is actually being
//!     paid for N times;
//!   * **a timeline** — every top-level statement records
//!     `(elapsed_ns, own_bytes)`, so a run at `--checkers=4` says whether the
//!     four instances reach their maxima together or in sequence. Peak RSS is
//!     a high-water mark of the SUM, so staggered peaks and simultaneous ones
//!     are different problems.

const std = @import("std");
const builtin = @import("builtin");
const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;

/// Process-global switch, set once by `main` from `--mem-profile` before any
/// checker thread starts, and read once per `Checker.init`. Write-once before
/// the pool spawns, so no synchronization is needed.
pub var mem_prof_on: bool = false;

pub fn enabled() bool {
    return mem_prof_on;
}

/// One sample of a checker's own footprint, taken at a top-level statement
/// boundary.
const Sample = struct { ns: u64, bytes: u64 };

/// Hands each instance a stable printable id, in spawn order.
var next_index: std.atomic.Value(u32) = .init(0);

pub const MemProf = struct {
    on: bool = false,
    index: u32 = 0,
    timer_start: u64 = 0,
    samples: std.ArrayListUnmanaged(Sample) = .empty,
    /// Largest `ownBytes()` ever sampled, and when.
    peak_bytes: u64 = 0,
    peak_ns: u64 = 0,

    pub fn deinit(m: *MemProf, gpa: std.mem.Allocator) void {
        m.samples.deinit(gpa);
    }
};

/// Bytes a growable container holds, at capacity. Array lists report
/// `capacity * @sizeOf(elem)`; hash maps report `capacity * (key + value + 1)`,
/// the metadata byte included, which is std's own layout to within its
/// alignment padding.
fn bytesOf(v: anytype) u64 {
    const T = @TypeOf(v);
    if (@hasField(T, "items")) {
        const Elem = @typeInfo(@TypeOf(v.items)).pointer.child;
        return @as(u64, v.capacity) * @sizeOf(Elem);
    }
    const KV = T.KV;
    const K = @FieldType(KV, "key");
    const V = @FieldType(KV, "value");
    return @as(u64, v.capacity()) * (@sizeOf(K) + @sizeOf(V) + 1);
}

fn entriesOf(v: anytype) u64 {
    const T = @TypeOf(v);
    if (@hasField(T, "items")) return v.items.len;
    return v.count();
}

/// Bytes the type store's own arrays hold, at capacity (overlay only — a
/// frozen base is shared by every checker and counted once).
fn storeBytes(c: *const Checker) u64 {
    const s = &c.ts;
    return bytesOf(s.kinds) + bytesOf(s.data_a) + bytesOf(s.data_b) +
        bytesOf(s.extra) + bytesOf(s.shape_hash) + bytesOf(s.pending) + bytesOf(s.map);
}

/// Everything this checker instance holds that it can name, at capacity.
/// Deliberately cheap (a few dozen `capacity` reads), so it can be sampled at
/// every top-level statement.
fn ownBytes(c: *const Checker) u64 {
    var n: u64 = storeBytes(c);
    inline for (checker_zig.map_containers) |f| n += bytesOf(@field(c, f));
    n += c.carena.queryCapacity();
    n += c.scratch_arena.queryCapacity();
    if (c.inst_arena != c.scratch_arena) n += c.inst_arena.queryCapacity();
    n += @as(u64, c.sym_types.mapping.len) + @as(u64, c.sym_state.mapping.len);
    n += c.inst_cache.mappedBytes();
    return n;
}

/// Called at every top-level statement boundary when the profiler is on.
pub fn sample(c: *Checker) void {
    const n = ownBytes(c);
    const ns: u64 = nowNs(c) -| c.mprof.timer_start;
    if (n > c.mprof.peak_bytes) {
        c.mprof.peak_bytes = n;
        c.mprof.peak_ns = ns;
    }
    c.mprof.samples.append(c.gpa, .{ .ns = ns, .bytes = n }) catch {};
}

pub fn runStart(c: *Checker) void {
    if (!c.mprof.on) return;
    c.mprof.index = next_index.fetchAdd(1, .monotonic);
    c.mprof.timer_start = nowNs(c);
}

/// Monotonic nanoseconds, the same clock `prof.zig` and `main.zig` read.
fn nowNs(c: *const Checker) u64 {
    const ts = std.Io.Clock.now(.awake, c.io);
    const ns = ts.nanoseconds;
    return if (ns > 0) @intCast(ns) else 0;
}

// --- resident-page accounting -------------------------------------------

extern "c" fn mincore(addr: *anyopaque, len: usize, vec: [*]u8) c_int;

/// `mincore(2)`, however this target can reach it. Linux goes through the raw
/// syscall so a libc-free build still compiles AND still measures; everywhere
/// else the symbol comes from libc, and referencing it at all is gated on
/// `link_libc` because linking it is the caller's build-time choice. Both
/// branches are comptime-known, so exactly one survives.
fn mincoreAvailable(ptr: [*]u8, len: usize, vec: [*]u8) bool {
    if (comptime builtin.os.tag == .linux) {
        return @as(isize, @bitCast(std.os.linux.mincore(ptr, len, vec))) == 0;
    }
    if (comptime builtin.link_libc) {
        return mincore(@ptrCast(ptr), len, vec) == 0;
    }
    return false;
}

/// Resident bytes of a mapping, via `mincore`. Returns null where the call is
/// unavailable or fails (Linux's `vec` semantics match Darwin's for bit 0).
fn residentBytes(mapping: []align(std.heap.page_size_min) u8) ?u64 {
    if (mapping.len == 0) return 0;
    if (builtin.os.tag == .windows) return null;
    const page = std.heap.page_size_min;
    const pages = (mapping.len + page - 1) / page;
    const vec = std.heap.page_allocator.alloc(u8, pages) catch return null;
    defer std.heap.page_allocator.free(vec);
    if (!mincoreAvailable(mapping.ptr, mapping.len, vec.ptr)) return null;
    var n: u64 = 0;
    for (vec) |b| n += (b & 1);
    return n * page;
}

// --- the report ----------------------------------------------------------

const Row = struct { name: []const u8, bytes: u64, entries: u64 };

/// Dump this checker's breakdown to stderr. Called from `seal`, so every
/// container still holds what it held at the end of the run.
pub fn report(c: *Checker) void {
    var rows: [checker_zig.map_containers.len + 8]Row = undefined;
    var n: usize = 0;
    const s = &c.ts;
    rows[n] = .{ .name = "ts.kinds", .bytes = bytesOf(s.kinds), .entries = s.kinds.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.data_a", .bytes = bytesOf(s.data_a), .entries = s.data_a.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.data_b", .bytes = bytesOf(s.data_b), .entries = s.data_b.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.extra", .bytes = bytesOf(s.extra), .entries = s.extra.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.shape_hash", .bytes = bytesOf(s.shape_hash), .entries = s.shape_hash.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.pending", .bytes = bytesOf(s.pending), .entries = s.pending.items.len };
    n += 1;
    rows[n] = .{ .name = "ts.map", .bytes = bytesOf(s.map), .entries = s.map.count() };
    n += 1;
    inline for (checker_zig.map_containers) |f| {
        rows[n] = .{ .name = f, .bytes = bytesOf(@field(c, f)), .entries = entriesOf(@field(c, f)) };
        n += 1;
    }
    const used = rows[0..n];
    std.mem.sort(Row, used, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return x.bytes > y.bytes;
        }
    }.lt);

    var buf: [1 << 16]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), c.io, &buf);
    const o = &w.interface;
    const idx = c.mprof.index;
    o.print("\n=== checker[{d}] memory breakdown (capacity, bytes) ===\n", .{idx}) catch {};
    var container_total: u64 = 0;
    for (used) |r| {
        container_total += r.bytes;
        if (r.bytes >= 64 * 1024)
            o.print("  {s:<26} {d:>12}  ({d} entries)\n", .{ r.name, r.bytes, r.entries }) catch {};
    }
    const carena = c.carena.queryCapacity();
    const scr = c.scratch_arena.queryCapacity();
    const inst = if (c.inst_arena != c.scratch_arena) c.inst_arena.queryCapacity() else 0;
    const st_map = @as(u64, c.sym_types.mapping.len) + @as(u64, c.sym_state.mapping.len);
    const st_res = (residentBytes(c.sym_types.mapping) orelse 0) + (residentBytes(c.sym_state.mapping) orelse 0);
    o.print("  {s:<26} {d:>12}\n", .{ "-- containers total --", container_total }) catch {};
    o.print("  {s:<26} {d:>12}\n", .{ "carena (queryCapacity)", carena }) catch {};
    o.print("  {s:<26} {d:>12}\n", .{ "scratch_arena", scr }) catch {};
    o.print("  {s:<26} {d:>12}\n", .{ "inst_arena", inst }) catch {};
    o.print("  {s:<26} {d:>12}\n", .{ "scratch high-water", c.stats.scratch_high_water }) catch {};
    o.print("  {s:<26} {d:>12}  (resident {d})\n", .{ "sym_types+sym_state mapped", st_map, st_res }) catch {};
    const memo_map = c.inst_cache.mappedBytes();
    const memo_res = residentBytes(c.inst_cache.slots.mapping) orelse 0;
    o.print("  {s:<26} {d:>12}  (resident {d}, {d} slots used)\n", .{ "inst_cache mapped", memo_map, memo_res, c.inst_cache.count() }) catch {};
    o.print("  {s:<26} {d:>12}\n", .{ "== named total ==", container_total + carena + scr + inst + st_map + memo_map }) catch {};
    o.print("  {s:<26} {d:>12}  at {d} ms\n", .{ "own peak (sampled)", c.mprof.peak_bytes, c.mprof.peak_ns / 1_000_000 }) catch {};

    // Timeline, decimated to at most 40 rows so four checkers stay readable.
    const sm = c.mprof.samples.items;
    if (sm.len > 1) {
        o.print("  -- timeline (ms, MB) --\n   ", .{}) catch {};
        const step = @max(1, sm.len / 40);
        var i: usize = 0;
        while (i < sm.len) : (i += step) {
            o.print(" {d}:{d}", .{ sm[i].ns / 1_000_000, sm[i].bytes / (1 << 20) }) catch {};
        }
        o.print(" | end {d}:{d}\n", .{ sm[sm.len - 1].ns / 1_000_000, sm[sm.len - 1].bytes / (1 << 20) }) catch {};
    }
    o.flush() catch {};
}
