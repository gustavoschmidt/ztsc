//! A bump-pointer arena with O(1) mark / restore.
//!
//! `std.heap.ArenaAllocator` can only rewind to empty: its chunk list node is
//! private, so there is no way to note a position and later release everything
//! allocated after it. The checker's substitution walk needs exactly that. Its
//! scratch traffic is strictly stack-shaped — every worklist, property buffer
//! and member-list dupe a subtree allocates is dead the moment that subtree
//! returns (the results are interned into the type store; anything that must
//! outlive the walk is copied into the checker or output arena). But ONE
//! non-LIFO allocation anywhere pins every byte below it in an arena that can
//! only reset wholesale, so the region grew to the *sum* of a statement's
//! substitutions rather than their maximum: 1.3 GB on immich, all of it dead
//! long before it was released.
//!
//! With a mark taken at each `instantiateId` frame and restored on exit, the
//! live region is bounded by the deepest path's own buffers instead. Freed
//! chunks are kept and re-bumped, so the steady state performs no allocator
//! traffic at all.
//!
//! Frames are taken at four grains, and together they define the contract:
//! the outermost `instantiate` (arena swap), `instantiateId`, `relate`, and
//! `checkExprCached`. The last is the binding one — **scratch is released per
//! EXPRESSION, not per statement.** The per-statement reset still exists, but
//! nothing may rely on it: a buffer allocated while checking an expression is
//! gone when that expression returns its `TypeId`. The looser rule cost 875 MB
//! of the 1.2 GB immich peak, all of it in one spec file's top-level
//! `describe`, because a statement that runs for seconds never reaches its
//! reset. Buffers that legitimately cross frames are allocated by an OUTER
//! frame and read by that same frame, so every inner mark sits above them.
//!
//! `free` is a no-op and `resize` grows only the most recent allocation, which
//! is what makes the mark stack sound: nothing an inner frame allocated can be
//! reachable once its mark is restored, so restoring can never strand a live
//! pointer that a *correct* caller still holds. Callers that violate the
//! stack discipline (holding a subtree's buffer past its return) would read
//! freed memory — the same contract the whole-arena swap already documented
//! and relied on, now enforced at a finer grain.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const BumpArena = struct {
    /// Where chunks come from. Page-granular, so chunk starts are
    /// page-aligned and satisfy any alignment a caller can request.
    backing: Allocator,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    /// Index of the chunk currently being bumped. `chunks[0..cur]` are full
    /// (in the sense of "already passed"); `chunks[cur+1..]` are retained
    /// empties waiting to be re-bumped.
    cur: usize = 0,
    /// Bump offset within `chunks[cur]`.
    off: usize = 0,

    /// Floor on a chunk; a request larger than this gets a chunk of its own
    /// size. Big enough that the small per-frame buffers never touch the
    /// backing allocator once the region has warmed up.
    const min_chunk: usize = 64 * 1024;

    pub const Mark = struct { chunk: usize, off: usize };

    pub fn init(backing: Allocator) BumpArena {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *BumpArena) void {
        for (self.chunks.items) |ch| self.backing.free(ch);
        self.chunks.deinit(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *BumpArena) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Current position. Cheap enough to take on every frame of a hot
    /// recursion (two loads).
    pub fn mark(self: *const BumpArena) Mark {
        return .{ .chunk = self.cur, .off = self.off };
    }

    /// Release everything allocated since `m`. Chunks are kept for reuse.
    pub fn restore(self: *BumpArena, m: Mark) void {
        self.cur = m.chunk;
        self.off = m.off;
    }

    /// Total bytes held, live or retained — the figure `--memory` reports as
    /// the scratch high-water.
    pub fn queryCapacity(self: *const BumpArena) usize {
        var n: usize = 0;
        for (self.chunks.items) |ch| n += ch.len;
        return n;
    }

    pub const ResetMode = union(enum) {
        free_all,
        retain_capacity,
        retain_with_limit: usize,
    };

    /// Rewind to empty, dropping chunks beyond `mode`'s retention budget.
    /// Mirrors `std.heap.ArenaAllocator.reset` closely enough to be a drop-in
    /// at the call sites that used it.
    pub fn reset(self: *BumpArena, mode: ResetMode) bool {
        const limit: usize = switch (mode) {
            .free_all => 0,
            .retain_capacity => std.math.maxInt(usize),
            .retain_with_limit => |n| n,
        };
        var kept: usize = 0;
        var w: usize = 0;
        for (self.chunks.items) |ch| {
            if (kept + ch.len <= limit) {
                kept += ch.len;
                self.chunks.items[w] = ch;
                w += 1;
            } else {
                self.backing.free(ch);
            }
        }
        self.chunks.items.len = w;
        self.cur = 0;
        self.off = 0;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *BumpArena = @ptrCast(@alignCast(ctx));
        const a = alignment.toByteUnits();
        if (self.chunks.items.len != 0) {
            const ch = self.chunks.items[self.cur];
            const start = std.mem.alignForward(usize, @intFromPtr(ch.ptr) + self.off, a) - @intFromPtr(ch.ptr);
            if (start + len <= ch.len) {
                self.off = start + len;
                return ch.ptr + start;
            }
        }
        // Move on to the next chunk. Everything from here up is empty (a
        // `Mark` never names a chunk above `cur`), so a retained one that is
        // too small is simply REPLACED rather than skipped — skipping it would
        // leave a permanent hole that every later pass allocates around, which
        // is how a naive retain policy grows the region without bound.
        const next = if (self.chunks.items.len == 0) 0 else self.cur + 1;
        if (next < self.chunks.items.len) {
            const nch = self.chunks.items[next];
            const nstart = std.mem.alignForward(usize, @intFromPtr(nch.ptr), a) - @intFromPtr(nch.ptr);
            if (nstart + len <= nch.len) {
                self.cur = next;
                self.off = nstart + len;
                return nch.ptr + nstart;
            }
            const ch = self.newChunk(len + a) orelse return null;
            self.backing.free(nch);
            self.chunks.items[next] = ch;
            self.cur = next;
            return self.bumpFresh(ch, len, a);
        }
        const ch = self.newChunk(len + a) orelse return null;
        self.chunks.append(self.backing, ch) catch {
            self.backing.free(ch);
            return null;
        };
        self.cur = next;
        return self.bumpFresh(ch, len, a);
    }

    /// First allocation in a freshly entered chunk.
    fn bumpFresh(self: *BumpArena, ch: []u8, len: usize, a: usize) [*]u8 {
        const start = std.mem.alignForward(usize, @intFromPtr(ch.ptr), a) - @intFromPtr(ch.ptr);
        self.off = start + len;
        return ch.ptr + start;
    }

    /// A page-aligned chunk of at least `need` bytes. Deliberately NOT
    /// geometric: chunks are retained and re-bumped after a restore, so the
    /// region converges on the peak live footprint, and doubling on every new
    /// chunk would overshoot that peak by up to 2x for no gain — the walk's
    /// buffers are large and few, not small and many.
    fn newChunk(self: *BumpArena, need: usize) ?[]u8 {
        return self.backing.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), @max(min_chunk, need)) catch null;
    }

    /// In place only, and only for the most recent allocation — growing
    /// anything else would have to move it.
    fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const self: *BumpArena = @ptrCast(@alignCast(ctx));
        if (self.chunks.items.len == 0) return false;
        const ch = self.chunks.items[self.cur];
        const start = self.offsetOfTop(ch, memory) orelse return new_len <= memory.len;
        if (start + new_len > ch.len) return false;
        self.off = start + new_len;
        return true;
    }

    /// `memory`'s offset in `ch`, but only if it really is that chunk's most
    /// recent allocation — i.e. it starts inside the chunk AND ends at the bump
    /// pointer. Both halves matter: chunks come from a page-granular backing
    /// allocator and are routinely handed out back to back, so a block filling
    /// the tail of chunk N-1 ends at exactly `chunks[N].ptr`, which the
    /// end-address test alone accepts whenever the current chunk's bump offset
    /// happens to be 0 (a fresh chunk, a restore, or the free of a block that
    /// started at the chunk base). Rewinding on that match subtracted a higher
    /// address from a lower one: `off` wrapped to ~2^64 and the next allocation
    /// handed back a pointer outside every chunk. Seen as a SIGBUS partway
    /// through checking outline; a debug build caught it as the subtraction.
    fn offsetOfTop(self: *const BumpArena, ch: []u8, memory: []u8) ?usize {
        const base = @intFromPtr(ch.ptr);
        const p = @intFromPtr(memory.ptr);
        if (p < base or p - base > self.off) return null;
        const start = p - base;
        return if (start + memory.len == self.off) start else null;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    /// A no-op, except that giving back the most recent allocation rewinds the
    /// bump pointer — which is what keeps a `defer scratch().free(buf)` in a
    /// tight loop from growing the region linearly.
    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *BumpArena = @ptrCast(@alignCast(ctx));
        if (self.chunks.items.len == 0) return;
        const ch = self.chunks.items[self.cur];
        self.off = self.offsetOfTop(ch, memory) orelse return;
    }
};

test "bump arena mark/restore reuses chunks" {
    var a = BumpArena.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();

    const outer = try al.alloc(u8, 100);
    @memset(outer, 1);
    const m = a.mark();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const inner = try al.alloc(u64, 512);
        @memset(inner, 7);
        a.restore(m);
    }
    // The outer allocation is untouched and the region never grew past the
    // deepest single frame.
    for (outer) |b| try std.testing.expectEqual(@as(u8, 1), b);
    try std.testing.expect(a.queryCapacity() <= 2 * BumpArena.min_chunk);
}

test "bump arena honours large and over-aligned requests" {
    var a = BumpArena.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const big = try al.alloc(u8, 3 * BumpArena.min_chunk);
    try std.testing.expectEqual(3 * BumpArena.min_chunk, big.len);
    const over = try al.alignedAlloc(u8, .@"64", 10);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(over.ptr) % 64);
    _ = a.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), a.queryCapacity());
}

/// Backing allocator for the adjacency test: page-aligned requests (the arena's
/// chunks) are carved back to back out of one region, the way an mmap-based
/// page allocator routinely hands out consecutive mappings. Everything else
/// (the chunk list itself) goes elsewhere so it cannot separate two chunks.
const PackedPages = struct {
    region: []u8,
    used: usize = 0,
    other: Allocator,

    fn allocator(self: *PackedPages) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = pAlloc, .resize = pResize, .remap = pRemap, .free = pFree } };
    }
    fn owns(self: *PackedPages, p: [*]u8) bool {
        return @intFromPtr(p) >= @intFromPtr(self.region.ptr) and
            @intFromPtr(p) < @intFromPtr(self.region.ptr) + self.region.len;
    }
    fn pAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *PackedPages = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() < std.heap.page_size_min) return self.other.rawAlloc(len, alignment, ra);
        const start = std.mem.alignForward(usize, self.used, alignment.toByteUnits());
        if (start + len > self.region.len) return null;
        self.used = start + len;
        return self.region.ptr + start;
    }
    fn pResize(ctx: *anyopaque, m: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *PackedPages = @ptrCast(@alignCast(ctx));
        if (self.owns(m.ptr)) return new_len <= m.len;
        return self.other.rawResize(m, alignment, new_len, ra);
    }
    fn pRemap(ctx: *anyopaque, m: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PackedPages = @ptrCast(@alignCast(ctx));
        if (self.owns(m.ptr)) return if (new_len <= m.len) m.ptr else null;
        return self.other.rawRemap(m, alignment, new_len, ra);
    }
    fn pFree(ctx: *anyopaque, m: []u8, alignment: Alignment, ra: usize) void {
        const self: *PackedPages = @ptrCast(@alignCast(ctx));
        if (self.owns(m.ptr)) return; // leaked into the region; freed wholesale
        self.other.rawFree(m, alignment, ra);
    }
};

test "bump arena ignores a free from an adjacent chunk" {
    // Chunks handed out back to back: a block filling the tail of chunk 0 ends
    // at exactly chunk 1's base, so the "ends at the bump pointer" test matches
    // it while chunk 1 sits at offset 0. Rewinding on that match used to
    // underflow `off`.
    const page = std.heap.page_size_min;
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), 4 * BumpArena.min_chunk);
    defer std.heap.page_allocator.free(region);
    var pages = PackedPages{ .region = region, .other = std.testing.allocator };

    var a = BumpArena.init(pages.allocator());
    defer a.deinit();
    const al = a.allocator();

    const half = BumpArena.min_chunk / 2;
    const lo = try al.alloc(u8, half);
    const tail = try al.alloc(u8, half); // ends exactly at chunk 0's end
    try std.testing.expectEqual(@as(usize, 1), a.chunks.items.len);
    const top = try al.alloc(u8, 8); // forces chunk 1, at its base
    try std.testing.expectEqual(@as(usize, 2), a.chunks.items.len);
    try std.testing.expectEqual(@intFromPtr(tail.ptr) + tail.len, @intFromPtr(top.ptr));

    al.free(top); // legitimate rewind: off back to 0 in chunk 1
    try std.testing.expectEqual(@as(usize, 0), a.off);
    al.free(tail); // must be ignored — `tail` belongs to chunk 0
    try std.testing.expectEqual(@as(usize, 0), a.off);
    try std.testing.expectEqual(@as(usize, 1), a.cur);

    // and the arena still hands out sane, in-chunk memory afterwards
    const after = try al.alloc(u8, 32);
    @memset(after, 0xAB);
    const ch1 = a.chunks.items[1];
    try std.testing.expect(@intFromPtr(after.ptr) >= @intFromPtr(ch1.ptr));
    try std.testing.expect(@intFromPtr(after.ptr) + after.len <= @intFromPtr(ch1.ptr) + ch1.len);
    for (lo) |*b| b.* = 1;
}

test "bump arena reset retains within the limit" {
    var a = BumpArena.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = try al.alloc(u8, BumpArena.min_chunk);
    try std.testing.expect(a.queryCapacity() >= 8 * BumpArena.min_chunk);
    _ = a.reset(.{ .retain_with_limit = 2 * BumpArena.min_chunk });
    try std.testing.expect(a.queryCapacity() <= 2 * BumpArena.min_chunk);
    // still usable afterwards
    const p = try al.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 16), p.len);
}
