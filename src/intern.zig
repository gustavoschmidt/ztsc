//! Thread-safe sharded string interner.
//!
//! Identifier/string-literal text is interned once, globally, into an `Atom`
//! (a `u32`). All later phases compare atoms, never bytes. The interner is
//! sharded by string hash: each shard has its own mutex, hash map, and bump
//! arena for string bytes, so concurrent interning from parser threads
//! contends only when two threads hash into the same shard.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Interned string handle. Atoms are only meaningful within the interner
/// that produced them. Atom 0 is never produced — consumers (binder,
/// module records) use 0 as a "none" sentinel.
pub const Atom = u32;

pub const Interner = struct {
    shards: [shard_count]Shard,

    pub const shard_count = 16; // power of two
    const shard_mask: u64 = shard_count - 1;
    const shard_bits = std.math.log2_int(u32, shard_count);

    const Shard = struct {
        mutex: Io.Mutex = .init,
        /// Map from string bytes (owned by `arena`) to local index.
        map: std.StringHashMapUnmanaged(u32) = .empty,
        /// Local index -> string bytes, for reverse lookup.
        strings: std.ArrayList([]const u8) = .empty,
        /// Owns the copied string bytes.
        arena: std.heap.ArenaAllocator,
        /// Total length of interned string bytes in this shard.
        string_bytes: usize = 0,
    };

    /// Hash maps and index lists allocate lazily from the `gpa` passed to
    /// `intern`; string bytes go into per-shard arenas backed by the page
    /// allocator.
    pub fn init() Interner {
        var self: Interner = .{ .shards = undefined };
        for (&self.shards) |*shard| {
            shard.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        }
        return self;
    }

    pub fn deinit(self: *Interner, gpa: Allocator) void {
        for (&self.shards) |*shard| {
            shard.map.deinit(gpa);
            shard.strings.deinit(gpa);
            shard.arena.deinit();
        }
        self.* = undefined;
    }

    /// Intern `str`, returning a stable Atom. The same bytes always return
    /// the same Atom. Thread-safe.
    pub fn intern(self: *Interner, io: Io, gpa: Allocator, str: []const u8) Allocator.Error!Atom {
        const hash = std.hash.Wyhash.hash(0, str);
        const shard_idx: u32 = @intCast(hash & shard_mask);
        const shard = &self.shards[shard_idx];

        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        const gop = try shard.map.getOrPut(gpa, str);
        if (gop.found_existing) {
            return atomFrom(shard_idx, gop.value_ptr.*);
        }
        errdefer shard.map.removeByPtr(gop.key_ptr);

        const local: u32 = @intCast(shard.strings.items.len);
        const copy = try shard.arena.allocator().dupe(u8, str);
        try shard.strings.append(gpa, copy);
        gop.key_ptr.* = copy; // key must point at owned bytes, not caller's
        gop.value_ptr.* = local;
        shard.string_bytes += copy.len;
        return atomFrom(shard_idx, local);
    }

    /// Return the bytes for an atom. Thread-safe (takes the shard lock,
    /// since writers may grow the index list concurrently). The returned
    /// slice itself is stable for the interner's lifetime.
    pub fn lookup(self: *Interner, io: Io, atom: Atom) []const u8 {
        const raw = atom - 1; // undo the +1 that keeps 0 free as a sentinel
        const shard = &self.shards[raw & shard_mask];
        const local = raw >> shard_bits;
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);
        return shard.strings.items[local];
    }

    /// Number of distinct strings interned.
    pub fn count(self: *Interner, io: Io) usize {
        var n: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            n += shard.strings.items.len;
        }
        return n;
    }

    /// Approximate bytes used: interned string bytes plus arena capacity and
    /// index/map structural overhead.
    pub fn bytesUsed(self: *Interner, io: Io) InternerStats {
        var stats: InternerStats = .{};
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            stats.string_bytes += shard.string_bytes;
            stats.arena_capacity += shard.arena.queryCapacity();
            stats.index_bytes += shard.strings.capacity * @sizeOf([]const u8);
            stats.map_bytes += shard.map.capacity() * (@sizeOf([]const u8) + @sizeOf(u32) + 1);
        }
        return stats;
    }

    fn atomFrom(shard_idx: u32, local: u32) Atom {
        std.debug.assert(local < (@as(u64, 1) << (32 - @as(u6, shard_bits))) - 1);
        // +1 so that Atom 0 is never a real string ("none" sentinel).
        return ((local << shard_bits) | shard_idx) + 1;
    }
};

pub const InternerStats = struct {
    /// Sum of lengths of all interned strings.
    string_bytes: usize = 0,
    /// Capacity reserved by the string-byte arenas.
    arena_capacity: usize = 0,
    /// Bytes in the atom -> string index lists.
    index_bytes: usize = 0,
    /// Approximate bytes in the hash maps.
    map_bytes: usize = 0,

    pub fn total(s: InternerStats) usize {
        return s.arena_capacity + s.index_bytes + s.map_bytes;
    }
};

fn asciiLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (asciiLower(x) != asciiLower(y)) return false;
    return true;
}

/// Weighted Levenshtein in tenths (fixed-point ×10), replicating tsc's
/// `levenshteinWithMax` costs: exact (case-sensitive) match 0, case-insensitive
/// substitution 1, other substitution 20, insert/delete 10. Full DP (no
/// diagonal banding): for any true distance within `cap_tenths` the banded and
/// unbanded results are identical, so this is exact where it matters. Returns
/// the distance, or null when it exceeds `cap_tenths`. `scratch` must hold at
/// least `2 * (b.len + 1)` usize slots.
fn weightedLevTenths(a: []const u8, b: []const u8, cap_tenths: usize, scratch: []usize) ?usize {
    var prev = scratch[0 .. b.len + 1];
    var cur = scratch[b.len + 1 .. 2 * (b.len + 1)];
    for (0..b.len + 1) |j| prev[j] = j * 10;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        cur[0] = i * 10;
        var col_min = cur[0];
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const dist = if (a[i - 1] == b[j - 1]) prev[j - 1] else blk: {
                const sub = if (asciiLower(a[i - 1]) == asciiLower(b[j - 1])) prev[j - 1] + 1 else prev[j - 1] + 20;
                break :blk @min(@min(prev[j] + 10, cur[j - 1] + 10), sub);
            };
            cur[j] = dist;
            col_min = @min(col_min, dist);
        }
        if (col_min > cap_tenths) return null;
        const tmp = prev;
        prev = cur;
        cur = tmp;
    }
    const res = prev[b.len];
    return if (res > cap_tenths) null else res;
}

/// tsc's `getSpellingSuggestion` (core.ts): pick the closest candidate name to
/// `name` under the weighted edit distance, or null when none is close enough.
/// Thresholds match tsc exactly — `maximumLengthDifference = max(2,
/// floor(len*0.34))` (a length pre-filter) and an initial best distance of
/// `floor(len*0.4)+1`. Ties on distance are broken toward the
/// lexicographically-smaller name so the choice is stable across --workers
/// (the determinism contract), where tsc would take iteration order.
/// Returns the winning index into `candidates`, or null.
pub fn spellingSuggestion(gpa: Allocator, name: []const u8, candidates: []const []const u8) ?usize {
    if (name.len == 0) return null;
    const max_len_diff: usize = @max(2, name.len * 34 / 100);
    // Initial threshold (tenths): (floor(len*0.4)+1)*10. A candidate is
    // accepted when its distance is strictly below the current threshold, i.e.
    // distance_tenths <= threshold_tenths - 1 (tsc's `bestDistance - 0.1`).
    // Acceptance threshold (tenths): a candidate qualifies when its distance is
    // strictly below `floor(len*0.4)+1` (tsc's `bestDistance - 0.1`), i.e.
    // distance_tenths <= threshold_tenths - 1. The threshold is FIXED here (not
    // lowered as tsc does) so every qualifying candidate competes; the global
    // minimum is then chosen with a deterministic lexicographic tie-break. This
    // yields tsc's global-minimum pick while staying byte-identical across
    // --workers regardless of candidate iteration order.
    const cap: usize = (name.len * 40 / 100 + 1) * 10 - 1;
    var best: ?usize = null;
    var best_d: usize = undefined;
    // DP scratch sized for the longest candidate.
    var max_cand: usize = 0;
    for (candidates) |c| max_cand = @max(max_cand, c.len);
    const scratch = gpa.alloc(usize, 2 * (max_cand + 1)) catch return null;
    defer gpa.free(scratch);
    for (candidates, 0..) |cand, i| {
        const diff = if (cand.len > name.len) cand.len - name.len else name.len - cand.len;
        if (diff > max_len_diff) continue;
        if (std.mem.eql(u8, cand, name)) continue;
        if (cand.len < 3 and !eqlIgnoreCase(cand, name)) continue;
        const d = weightedLevTenths(name, cand, cap, scratch) orelse continue;
        if (best == null or d < best_d or
            (d == best_d and std.mem.order(u8, cand, candidates[best.?]) == .lt))
        {
            best_d = d;
            best = i;
        }
    }
    return best;
}

test "spellingSuggestion: matches tsc getSpellingSuggestion verdicts" {
    const gpa = std.testing.allocator;
    // String-literal union suggestion (TS2820 path): the close member wins.
    try std.testing.expectEqual(
        @as(?usize, 2),
        spellingSuggestion(gpa, "assignment-late", &.{ "account-balance", "add", "assignment" }),
    );
    // No near match -> null (plain TS2322/TS2305, no "Did you mean").
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "upload-file", &.{ "account-balance", "add", "assignment" }),
    );
    // A single-character export typo is within threshold (TS2724 path).
    try std.testing.expectEqual(
        @as(?usize, 0),
        spellingSuggestion(gpa, "CattleHealthStatusBadge", &.{"CattleHealthStatusBadgeX"}),
    );
    // A distant export name is rejected — matches tsc emitting plain TS2305
    // for `CattleHealthStatusBadge` vs only `CattleWeighingStatusBadge`.
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "CattleHealthStatusBadge", &.{"CattleWeighingStatusBadge"}),
    );
    // Candidates shorter than 3 chars only match on case.
    try std.testing.expectEqual(
        @as(?usize, null),
        spellingSuggestion(gpa, "ab", &.{"xy"}),
    );
    // Empty candidate set.
    try std.testing.expectEqual(@as(?usize, null), spellingSuggestion(gpa, "foo", &.{}));
}

test "intern: same string same atom, different strings different atoms" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    const a1 = try interner.intern(io, gpa, "foo");
    const a2 = try interner.intern(io, gpa, "bar");
    const a3 = try interner.intern(io, gpa, "foo");
    try std.testing.expectEqual(a1, a3);
    try std.testing.expect(a1 != a2);
    try std.testing.expectEqualStrings("foo", interner.lookup(io, a1));
    try std.testing.expectEqualStrings("bar", interner.lookup(io, a2));
    try std.testing.expectEqual(@as(usize, 2), interner.count(io));
}

test "intern: does not alias caller memory" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    const atom = try interner.intern(io, gpa, buf[0..5]);
    @memcpy(buf[0..5], "XXXXX"); // clobber caller memory
    try std.testing.expectEqualStrings("hello", interner.lookup(io, atom));
}

test "intern: many strings, atoms stay distinct and stable" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    var atoms: [1000]Atom = undefined;
    for (&atoms, 0..) |*atom, i| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "sym_{d}", .{i});
        atom.* = try interner.intern(io, gpa, s);
    }
    // Re-intern: must return identical atoms.
    for (&atoms, 0..) |atom, i| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "sym_{d}", .{i});
        try std.testing.expectEqual(atom, try interner.intern(io, gpa, s));
        try std.testing.expectEqualStrings(s, interner.lookup(io, atom));
    }
    try std.testing.expectEqual(@as(usize, 1000), interner.count(io));
    const stats = interner.bytesUsed(io);
    try std.testing.expect(stats.string_bytes > 0);
    try std.testing.expect(stats.arena_capacity >= stats.string_bytes);
}

test "intern: multi-threaded stress" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    const n_threads = 8;
    const n_strings = 500;

    const Worker = struct {
        fn run(tio: Io, itn: *Interner, alloc: Allocator, seed: usize, out: *[n_strings]Atom) void {
            // Each thread interns the same set of strings, in a different order.
            for (0..n_strings) |k| {
                const i = (k * 7 + seed * 13) % n_strings;
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "ident_{d}", .{i}) catch unreachable;
                out[i] = itn.intern(tio, alloc, s) catch @panic("intern failed");
                // Interleave lookups to stress concurrent readers.
                const got = itn.lookup(tio, out[i]);
                std.debug.assert(std.mem.eql(u8, got, s));
            }
        }
    };

    var results: [n_threads][n_strings]Atom = undefined;
    var threads: [n_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, ti| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ io, &interner, gpa, ti, &results[ti] });
    }
    for (&threads) |t| t.join();

    // All threads must agree on every atom.
    for (1..n_threads) |ti| {
        try std.testing.expectEqualSlices(Atom, &results[0], &results[ti]);
    }
    // Exactly n_strings distinct atoms.
    try std.testing.expectEqual(@as(usize, n_strings), interner.count(io));
    for (results[0], 0..) |atom, i| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "ident_{d}", .{i});
        try std.testing.expectEqualStrings(s, interner.lookup(io, atom));
    }
}
