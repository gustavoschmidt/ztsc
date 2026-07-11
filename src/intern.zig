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
/// that produced them.
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
        const shard = &self.shards[atom & shard_mask];
        const local = atom >> shard_bits;
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
        std.debug.assert(local < (@as(u64, 1) << (32 - @as(u6, shard_bits))));
        return (local << shard_bits) | shard_idx;
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
