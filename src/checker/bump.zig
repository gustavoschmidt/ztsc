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
        const end = @intFromPtr(memory.ptr) + memory.len;
        if (end != @intFromPtr(ch.ptr) + self.off) return new_len <= memory.len;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(ch.ptr);
        if (start + new_len > ch.len) return false;
        self.off = start + new_len;
        return true;
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
        if (@intFromPtr(memory.ptr) + memory.len == @intFromPtr(ch.ptr) + self.off) {
            self.off = @intFromPtr(memory.ptr) - @intFromPtr(ch.ptr);
        }
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
