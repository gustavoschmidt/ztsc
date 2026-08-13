//! A bounded, direct-mapped memo for the instantiation cache.
//!
//! ## Why this is not a hash map
//!
//! `inst_cache` was an `IntMap(u64, TypeId)` — a growable open-addressing table
//! at std's 80% load factor. On immich it ends the run holding 4.5–5.7 M
//! entries, which puts it at 2^23 slots x 13 bytes = **104 MiB per checker
//! instance, and it is 104 MiB at `--checkers=1` and at `--checkers=4` alike**:
//! the table sizes itself to the DISTINCT `(map_id, type)` pairs one instance
//! meets, and partitioning the files barely moves that number. It was the
//! single largest line item in a checker's footprint (36% at c1) and, at c4,
//! 416 MB of a 1016 MB peak — the clearest example there is of a per-checker
//! cost that partitioning multiplies instead of dividing.
//!
//! A growable table is also the wrong shape for the job twice over:
//!
//!   * **it never gives anything back.** Nothing about this memo wants every
//!     pair the run ever produced kept to the end; the substitution walk's
//!     re-asks are overwhelmingly local (the same subterm under the same map,
//!     within one declaration window). A table that only grows pays for the
//!     whole history to serve the recent past.
//!   * **doubling costs a transient of 1.5x the final size** — the old table
//!     is live while the new one is filled — on top of rehashing every key.
//!
//! So it is a CACHE, and it is now written as one: one probe, and a write that
//! simply overwrites whatever was there. It starts at 12 KiB, doubles while it
//! fills, and **stops at 3 MiB whatever the program asks for**, so a checker's
//! memo footprint is bounded by a constant rather than by the run's history.
//! `--inst-memo-bits=N` pins it at 2^N slots for measurement.
//!
//! Measured, interleaved medians of three on immich (peak RSS is the metric
//! this change is about; the wall column was taken on a shared machine and is
//! indicative only):
//!
//!     config    peak RSS before -> after      wall before -> after
//!     c1              381.5 -> 280.4 MiB        4.08 -> 3.77 s
//!     c2              618.4 -> 416.2 MiB        3.63 -> 2.94 s
//!     c4 (default)   1027.5 -> 608.6 MiB        4.05 -> 3.58 s
//!     c8             1600.7 -> 907.6 MiB        4.69 -> 3.92 s
//!
//! The eight benchmark packages and the `multi` corpus move by less than
//! 0.5 MB either way, which is what the growth-from-small start is for: a
//! table pinned at the ceiling cost `multi` 6 MB of peak RSS to hold three
//! thousand live entries, because a scattered write pattern makes every page
//! of a direct-mapped table resident whatever its occupancy.
//!
//! ## Why dropping entries is safe
//!
//! `inst_cache` is a pure memo over a pure function: `instantiateId(t, map)` is
//! recomputed identically on a miss, and the project already ships
//! `--no-inst-cache`, which turns the whole layer off and is documented as the
//! correctness ORACLE for it. An eviction is that flag applied to one entry.
//! The one rule the layer does carry — never publish a result computed under a
//! tripped budget — lives at the call site (`instantiateId`'s `put` is guarded
//! by `!inst_limit_tripped`) and is untouched here.
//!
//! ## Layout
//!
//! One array of 12-byte entries (`mid`, `ty`, `val`), so a probe touches ONE
//! cache line instead of the two a split key/value pair would. The backing is a
//! demand-zeroed anonymous mapping (`ZeroPagedArray`), so a table that has just
//! doubled costs only the pages the next entries write.
//!
//! `ty == 0` marks a free slot. A key's `ty` is never 0: `instantiate` returns
//! early for a type that contains no type parameter, and type id 0 is the
//! store's `none` sentinel, which contains none.

const std = @import("std");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

/// One memoized substitution. `extern` to pin the layout at 12 bytes — a
/// non-extern struct is free to pad to 16, which is a third more memory for
/// nothing.
pub const Entry = extern struct { mid: u32, ty: u32, val: u32 };

comptime {
    std.debug.assert(@sizeOf(Entry) == 12);
}

/// The ceiling, and it is set from a measurement rather than a guess. Pinning
/// the table at each size in turn (`--inst-memo-bits`) on immich at
/// `--checkers=4` moves the memo's HIT RATE by a tenth of a point and the total
/// substitution work by a fraction of a percent, while it moves peak RSS by
/// 390 MB:
///
///     bits   memo/checker   immich c4 peak RSS   instantiations
///       23        100 MiB           1038 MB        35,252,370
///       22         50 MiB            843 MB        35,258,484
///       21         25 MiB            745 MB        35,271,707
///       20       12.6 MiB            683 MB        35,308,798
///       19        6.3 MiB            665 MB        35,362,747
///       18        3.1 MiB            648 MB        35,417,712
///       16        786 KiB              —           35,522,489
///       12         48 KiB              —           35,957,663
///        1              —              —           124,150,740
///
/// The last row is the control, and it is what says the memo is genuinely
/// load-bearing: with it effectively off the substitution walk does 3.5x the
/// work. Between 4,096 slots and 8.4 M slots it does 2% more. **The re-asks
/// this memo serves are local** — the same subterm under the same map, inside
/// one declaration window — so a table sized to the run's whole history was
/// paying for five million entries to serve a few hundred.
///
/// 2^18 is chosen with headroom over the measured working set rather than at
/// the knee, because the knee is a property of immich and this ceiling has to
/// hold for every corpus. Anything from 2^14 up would serve immich as well.
pub const max_bits: u6 = 18;
/// Starting size (12 KiB). The table doubles from here as it fills, so the
/// eight benchmark packages never allocate more than they use — a FIXED 2^18
/// table costs the `multi` corpus 6 MB of peak RSS for three thousand live
/// entries, because a scattered write pattern makes every page of it resident
/// whatever the occupancy.
pub const min_bits: u6 = 10;
/// Grow when this fraction of the slots is occupied (1/2). Higher is denser
/// but a direct-mapped table's conflict rate is its occupancy.
const grow_at_num: u32 = 1;
const grow_at_den: u32 = 2;

pub const InstMemo = struct {
    slots: ZeroPagedArray(Entry) = .{},
    mask: u32 = 0,
    /// Occupied slots — the growth trigger, not an entry count anyone reads.
    used: u32 = 0,
    /// Log2 of the current slot count, and the ceiling it may double to.
    bits: u6 = 0,
    cap_bits: u6 = 0,

    /// A memo that starts at `min_bits` slots and doubles up to `max_bits`.
    /// A non-zero `bits_override` (`checker.Options.inst_memo_bits`, from
    /// `--inst-memo-bits=N`) instead pins it at 2^N with no growth — a
    /// measurement aid.
    pub fn alloc(bits_override: u6) error{OutOfMemory}!InstMemo {
        const pinned = bits_override != 0;
        const start: u6 = if (pinned) bits_override else min_bits;
        const n_slots = @as(usize, 1) << start;
        return .{
            .slots = try ZeroPagedArray(Entry).alloc(n_slots),
            .mask = @intCast(n_slots - 1),
            .bits = start,
            .cap_bits = if (pinned) start else max_bits,
        };
    }

    pub fn free(m: *InstMemo) void {
        m.slots.free();
        m.* = .{};
    }

    /// Double the table and re-place every live entry. Cold: it runs at most
    /// `max_bits - min_bits` times per checker, over a table that is never
    /// larger than 3 MiB. A collision during re-placement simply drops the
    /// older entry, which is the same thing an ordinary write does.
    fn grow(m: *InstMemo) void {
        const old = m.slots;
        const n_slots = @as(usize, 1) << (m.bits + 1);
        const fresh = ZeroPagedArray(Entry).alloc(n_slots) catch return;
        m.slots = fresh;
        m.mask = @intCast(n_slots - 1);
        m.bits += 1;
        m.used = 0;
        for (old.items) |e| {
            if (e.ty == 0) continue;
            const i = m.slot(e.mid, e.ty);
            if (m.slots.items[i].ty == 0) m.used += 1;
            m.slots.items[i] = e;
        }
        var stale = old;
        stale.free();
    }

    /// Bytes MAPPED. Residency tracks the slots actually written, so a small
    /// program pays a small fraction of this.
    pub fn mappedBytes(m: *const InstMemo) usize {
        return m.slots.mapping.len;
    }

    /// The same MurmurHash3 finalizer `IntCtx` uses, over the packed key. Both
    /// halves must reach the low bits: a `map_id` and a `TypeId` are each dense
    /// counters, so the raw packed value's low bits are the type alone.
    inline fn slot(m: *const InstMemo, mid: u32, ty: u32) u32 {
        var x: u64 = (@as(u64, mid) << 32) | ty;
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return @as(u32, @truncate(x)) & m.mask;
    }

    pub inline fn get(m: *const InstMemo, mid: u32, ty: u32) ?u32 {
        if (m.mask == 0) return null;
        const e = m.slots.items[m.slot(mid, ty)];
        return if (e.ty == ty and e.mid == mid) e.val else null;
    }

    pub fn put(m: *InstMemo, mid: u32, ty: u32, val: u32) void {
        if (m.slots.items.len == 0) return;
        const i = m.slot(mid, ty);
        if (m.slots.items[i].ty == 0) {
            m.used += 1;
            if (m.bits < m.cap_bits and m.used * grow_at_den >= (m.mask + 1) * grow_at_num) {
                m.grow();
                m.putGrown(mid, ty, val);
                return;
            }
        }
        m.slots.items[i] = .{ .mid = mid, .ty = ty, .val = val };
    }

    fn putGrown(m: *InstMemo, mid: u32, ty: u32, val: u32) void {
        const i = m.slot(mid, ty);
        if (m.slots.items[i].ty == 0) m.used += 1;
        m.slots.items[i] = .{ .mid = mid, .ty = ty, .val = val };
    }

    /// Occupied slots — what `--mem-profile` prints.
    pub fn count(m: *const InstMemo) usize {
        return m.used;
    }
};

test "InstMemo: stores, reads back, and never reports a free slot as a hit" {
    var m = try InstMemo.alloc(8);
    defer m.free();
    try std.testing.expectEqual(@as(?u32, null), m.get(1, 2));
    m.put(1, 2, 42);
    try std.testing.expectEqual(@as(?u32, 42), m.get(1, 2));
    // A different key that happens to share a slot must MISS, not return the
    // resident value.
    try std.testing.expectEqual(@as(?u32, null), m.get(1, 3));
    try std.testing.expectEqual(@as(?u32, null), m.get(2, 2));
    try std.testing.expectEqual(@as(usize, 1), m.count());
}

test "InstMemo: a colliding write evicts, and the evicted key reads as absent" {
    // Pinned, so the growth path cannot rescue the collision this is about.
    var m = try InstMemo.alloc(4);
    defer m.free();
    var i: u32 = 1;
    var first: u32 = 0;
    var second: u32 = 0;
    outer: while (i < 10_000) : (i += 1) {
        var j: u32 = i + 1;
        while (j < 10_000) : (j += 1) {
            if (m.slot(0, i) == m.slot(0, j)) {
                first = i;
                second = j;
                break :outer;
            }
        }
    }
    try std.testing.expect(first != 0 and second != 0);
    m.put(0, first, 7);
    try std.testing.expectEqual(@as(?u32, 7), m.get(0, first));
    m.put(0, second, 9);
    try std.testing.expectEqual(@as(?u32, 9), m.get(0, second));
    try std.testing.expectEqual(@as(?u32, null), m.get(0, first));
}

test "InstMemo: grows up to the cap, then stops and evicts instead" {
    var m = try InstMemo.alloc(0);
    defer m.free();
    try std.testing.expectEqual(min_bits, m.bits);
    // Fill well past the starting size: the table must double rather than
    // thrash, and every one of the last few keys must still read back.
    var i: u32 = 1;
    while (i <= 4096) : (i += 1) m.put(1, i, i + 1000);
    try std.testing.expect(m.bits > min_bits);
    try std.testing.expect(m.used * 2 < m.mask + 1);
    try std.testing.expectEqual(@as(?u32, 5096), m.get(1, 4096));
    // Mapped bytes must stay proportional to what is live, not to the cap.
    try std.testing.expect(m.mappedBytes() < (@as(usize, 1) << max_bits) * @sizeOf(Entry));

    // At the cap the table stops growing.
    var pinned = try InstMemo.alloc(min_bits);
    defer pinned.free();
    const cap_slots = pinned.mask + 1;
    i = 1;
    while (i <= 100_000) : (i += 1) pinned.put(1, i, i);
    try std.testing.expectEqual(min_bits, pinned.bits);
    try std.testing.expectEqual(cap_slots, pinned.mask + 1);
    try std.testing.expect(pinned.used <= cap_slots);
}

test "InstMemo: an unallocated memo is inert" {
    var m: InstMemo = .{};
    defer m.free();
    m.put(1, 2, 3);
    try std.testing.expectEqual(@as(?u32, null), m.get(1, 2));
    try std.testing.expectEqual(@as(usize, 0), m.mappedBytes());
}
