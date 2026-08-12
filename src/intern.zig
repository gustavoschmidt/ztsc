//! Thread-safe sharded string interner.
//!
//! Identifier/string-literal text is interned once, globally, into an `Atom`
//! (a `u32`). All later phases compare atoms, never bytes. The interner is
//! sharded by string hash: each shard has its own mutex, hash map, and bump
//! arena for string bytes, so concurrent interning from parser threads
//! contends only when two threads hash into the same shard.
//!
//! An `Atom` encodes its shard-local *insertion index*, so atom ids — and with
//! them every table the rest of the compiler sorts by atom — depend on the
//! order strings arrive in. Concurrent workers vary that order run to run,
//! which made the checker's traversal order (and the work counters that
//! measure it) run-to-run unstable. `freezePrefix` + `renumber` close that:
//! the front end interns as it likes, and once discovery is done the driver
//! replays the per-file first-touch lists in the program's deterministic file
//! order and reassigns every id to the one a single-threaded front end would
//! have produced. See `main.zig`'s renumbering block.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const spelling = @import("spelling.zig");

/// Interned string handle. Atoms are only meaningful within the interner
/// that produced them. Atom 0 is never produced — consumers (binder,
/// module records) use 0 as a "none" sentinel.
pub const Atom = u32;

pub const Interner = struct {
    shards: [shard_count]Shard,
    /// Per-shard local count at the moment the concurrent front end starts
    /// (`freezePrefix`). Locals below it were interned single-threaded — the
    /// lib front end runs before any worker — so their ids are already
    /// run-invariant and `renumber` leaves them exactly where they are.
    frozen: [shard_count]u32 = @splat(0),

    const shard_count = 16; // power of two
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

    /// Mark everything interned so far as already-deterministic. Called once,
    /// single-threaded, just before the worker pool starts: the lib front end
    /// and the CLI have already interned in a fixed order, and `renumber` must
    /// not disturb ids the rest of the run has no way to revisit (the lib's
    /// sealed binder output is kept, not re-bound).
    pub fn freezePrefix(self: *Interner) void {
        for (&self.shards, &self.frozen) |*shard, *n| n.* = @intCast(shard.strings.items.len);
    }

    /// True for an atom interned before `freezePrefix` — one `renumber` keeps
    /// exactly where it is, so recording it in a first-touch list is pointless.
    pub fn isFrozen(self: *const Interner, atom: Atom) bool {
        return localOf(atom) < self.frozen[shardOf(atom)];
    }

    /// The result of `renumber`: how to rewrite atoms the front end handed out.
    pub const Renumbering = struct {
        /// Old atom -> new atom, indexed by the old atom value (0 is unused
        /// and maps to 0, so the "none" sentinel maps through unchanged).
        map: []const Atom,
        /// True when every atom kept its id — the case a single-threaded front
        /// end produces, where the whole rewrite below is a no-op.
        identity: bool,
        /// Atoms `order` never mentioned. Always 0: every post-freeze intern
        /// goes through a binder (whose per-file first-touch list feeds
        /// `order`) or is a file path the driver records the same way. A
        /// nonzero count means an interning site was added without extending
        /// the order, and the driver reports it rather than silently shipping
        /// a scheduling-dependent id space.
        uncovered: u32,
    };

    /// Reassign every post-freeze atom id so that ids follow `order` — the
    /// concatenated per-file first-touch lists, walked in the program's
    /// deterministic file order. That is exactly the sequence a single-threaded
    /// front end interns in, so the ids it produces are the serial ones,
    /// whatever order the workers actually arrived in. Duplicates in `order`
    /// (a string touched by several files) keep their first occurrence.
    ///
    /// Ids stay in the shard-local encoding: a string's shard is a function of
    /// its bytes, so renumbering only permutes locals *within* a shard, and
    /// `lookup` keeps working unchanged. The caller must rewrite every atom it
    /// stored during the front end through `map` — see `binder.Bind.remapAtoms`.
    ///
    /// Ids handed out *after* this point continue past the renumbered ones.
    /// The link phase is serial, so its atoms are deterministic; names the
    /// checkers intern (mapped-type key remaps, template-literal results) are
    /// numbered as the parallel instances reach them, which is why the output
    /// boundary orders properties by text (`print.propDisplayOrder`).
    ///
    /// Single-threaded: call with the worker pool joined.
    pub fn renumber(
        self: *Interner,
        gpa: Allocator,
        map_alloc: Allocator,
        order: []const Atom,
    ) Allocator.Error!Renumbering {
        var max_id: Atom = 0;
        for (&self.shards, 0..) |*shard, si| {
            const n: u32 = @intCast(shard.strings.items.len);
            if (n != 0) max_id = @max(max_id, atomFrom(@intCast(si), n - 1));
        }
        const map = try map_alloc.alloc(Atom, @as(usize, max_id) + 1);
        @memset(map, 0);

        // The frozen prefix keeps its ids; `next` is where each shard's
        // renumbered locals start.
        var next: [shard_count]u32 = self.frozen;
        for (0..shard_count) |si| {
            for (0..self.frozen[si]) |l| {
                const a = atomFrom(@intCast(si), @intCast(l));
                map[a] = a;
            }
        }

        var identity = true;
        for (order) |old| {
            if (old == 0 or old > max_id) continue;
            if (map[old] != 0) continue; // frozen, or already assigned
            const si: u32 = shardOf(old);
            const new = atomFrom(si, next[si]);
            next[si] += 1;
            map[old] = new;
            if (new != old) identity = false;
        }

        // Anything `order` missed still needs an id; give it one in id order so
        // the result is a permutation either way, and report the count.
        var uncovered: u32 = 0;
        for (&self.shards, 0..) |*shard, si| {
            for (self.frozen[si]..shard.strings.items.len) |l| {
                const old = atomFrom(@intCast(si), @intCast(l));
                if (map[old] != 0) continue;
                uncovered += 1;
                const new = atomFrom(@intCast(si), next[si]);
                next[si] += 1;
                map[old] = new;
                if (new != old) identity = false;
            }
        }

        if (identity) return .{ .map = map, .identity = true, .uncovered = uncovered };

        // Permute each shard's reverse index, then repoint its map values.
        for (&self.shards, 0..) |*shard, si| {
            const n = shard.strings.items.len;
            const moved = try gpa.alloc([]const u8, n);
            for (0..n) |l| {
                const new = map[atomFrom(@intCast(si), @intCast(l))];
                moved[localOf(new)] = shard.strings.items[l];
            }
            @memcpy(shard.strings.items, moved);
            gpa.free(moved);
            var it = shard.map.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.* = localOf(map[atomFrom(@intCast(si), kv.value_ptr.*)]);
            }
        }
        return .{ .map = map, .identity = false, .uncovered = uncovered };
    }

    fn shardOf(atom: Atom) u32 {
        return @intCast((atom - 1) & shard_mask);
    }

    fn localOf(atom: Atom) u32 {
        return (atom - 1) >> shard_bits;
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

// tsc's `getSpellingSuggestion`, re-exported for the callers that reach for it
// through this module (the checker's name/property walks, the linker's export
// lookup). The implementation is pure string code with no interner state; it
// lives in `spelling.zig`.
pub const spellInitialCapTenths = spelling.spellInitialCapTenths;
pub const spellCandidateDistance = spelling.spellCandidateDistance;
pub const spellingSuggestion = spelling.spellingSuggestion;

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

test "renumber: replaying the serial order is the identity" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    var atoms: [64]Atom = undefined;
    for (&atoms, 0..) |*a, i| {
        var buf: [16]u8 = undefined;
        a.* = try interner.intern(io, gpa, try std.fmt.bufPrint(&buf, "n{d}", .{i}));
    }
    // Everything was interned in `atoms` order, so replaying it changes
    // nothing — and duplicates (a string several files touched) are ignored.
    var order: std.ArrayList(Atom) = .empty;
    defer order.deinit(gpa);
    for (atoms) |a| try order.appendSlice(gpa, &.{ a, a });
    const rn = try interner.renumber(gpa, gpa, order.items);
    defer gpa.free(rn.map);
    try std.testing.expect(rn.identity);
    try std.testing.expectEqual(@as(u32, 0), rn.uncovered);
    for (atoms) |a| try std.testing.expectEqual(a, rn.map[a]);
}

test "renumber: reversed order permutes ids, strings follow, prefix is pinned" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    // A frozen prefix: interned single-threaded, so it must not move.
    const pinned = try interner.intern(io, gpa, "pinned");
    const pinned2 = try interner.intern(io, gpa, "pinned2");
    interner.freezePrefix();

    var atoms: [64]Atom = undefined;
    for (&atoms, 0..) |*a, i| {
        var buf: [16]u8 = undefined;
        a.* = try interner.intern(io, gpa, try std.fmt.bufPrint(&buf, "n{d}", .{i}));
    }

    var order: std.ArrayList(Atom) = .empty;
    defer order.deinit(gpa);
    var i: usize = atoms.len;
    while (i > 0) : (i -= 1) try order.append(gpa, atoms[i - 1]);
    const rn = try interner.renumber(gpa, gpa, order.items);
    defer gpa.free(rn.map);
    try std.testing.expect(!rn.identity);
    try std.testing.expectEqual(@as(u32, 0), rn.uncovered);
    try std.testing.expectEqual(pinned, rn.map[pinned]);
    try std.testing.expectEqual(pinned2, rn.map[pinned2]);
    try std.testing.expectEqualStrings("pinned", interner.lookup(io, pinned));

    // Every atom still names its own string, and re-interning the string
    // returns the new id — the shard maps were repointed too.
    for (atoms, 0..) |old, k| {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "n{d}", .{k});
        const new = rn.map[old];
        try std.testing.expectEqualStrings(s, interner.lookup(io, new));
        try std.testing.expectEqual(new, try interner.intern(io, gpa, s));
    }
    // The map is a permutation: distinct atoms keep distinct ids.
    var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer seen.deinit(gpa);
    for (atoms) |old| try std.testing.expect((try seen.getOrPut(gpa, rn.map[old])).found_existing == false);

    // Ids handed out after a renumbering continue past the permuted ones.
    const fresh = try interner.intern(io, gpa, "fresh");
    try std.testing.expectEqualStrings("fresh", interner.lookup(io, fresh));
    try std.testing.expectEqual(@as(usize, 67), interner.count(io));
}

test "renumber: an atom the order forgot still gets an id, and is reported" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var interner = Interner.init();
    defer interner.deinit(gpa);

    const a = try interner.intern(io, gpa, "kept");
    const b = try interner.intern(io, gpa, "forgotten");
    const rn = try interner.renumber(gpa, gpa, &.{a});
    defer gpa.free(rn.map);
    try std.testing.expectEqual(@as(u32, 1), rn.uncovered);
    try std.testing.expect(rn.map[b] != 0);
    try std.testing.expectEqualStrings("forgotten", interner.lookup(io, rn.map[b]));
    try std.testing.expectEqualStrings("kept", interner.lookup(io, rn.map[a]));
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
