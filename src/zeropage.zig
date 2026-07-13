//! Demand-zeroed, fixed-length arrays backed by a private anonymous mapping.
//!
//! The checker's per-symbol state (`sym_types`/`sym_state`) is indexed by
//! *global* `SymbolId`, so each array must span the whole symbol space — but a
//! checker only ever touches its working set (its owned files' symbols plus
//! the foreign ones it resolves on demand). Two properties must hold at once:
//!
//!   1. **Every entry starts at all-zero bytes.** The zero state is
//!      load-bearing — a `sym_state` of `0` *means* `.not_computed`, and a
//!      `sym_type` of `0` means "no type yet". Nothing writes an entry before
//!      first reading it, so the backing memory must already be zero.
//!   2. **Untouched pages must not count toward RSS.** Eagerly zeroing (a
//!      `@memset`) would fault every page resident up front, defeating the
//!      whole point; residency must track the working set.
//!
//! A fresh `MAP_ANONYMOUS` mapping is the one place where the kernel zero-fill
//! is a *documented* guarantee, and demand paging gives (2) for free. This
//! type owns its mapping and cannot be constructed from a general `Allocator`,
//! so no caller can accidentally substitute a source that recycles dirty
//! memory (a plain arena/`page_allocator` would satisfy (1) only by accident
//! of never-recycling, which is exactly the fragility this type removes). See
//! `test "ZeroPagedArray: fresh entries read as zero"` for the guard.

const std = @import("std");
const builtin = @import("builtin");
const page_size_min = std.heap.page_size_min;

/// Fixed-length array of `T` whose backing store is a demand-zeroed anonymous
/// mapping. `T` must be a plain value type whose all-zero bit pattern is a
/// valid, meaningful value (e.g. an `enum(u8)` with a `= 0` variant, or an
/// integer whose `0` is a sentinel).
pub fn ZeroPagedArray(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Element view; `items.len == 0` for the empty/unmapped array.
        items: []T = &.{},
        /// The raw page-aligned mapping backing `items`, retained for
        /// `munmap`. Kept separate because `munmap` needs the page-aligned
        /// base and byte length, not the typed view.
        mapping: []align(page_size_min) u8 = &.{},

        /// Map `n` zero-filled elements. The mapping is private and anonymous,
        /// so the kernel guarantees the bytes are zero and only touched pages
        /// become resident. Callers must `free` it.
        pub fn alloc(n: usize) error{OutOfMemory}!Self {
            if (n == 0) return .{};
            if (builtin.os.tag == .windows) @compileError(
                "ZeroPagedArray: Windows port not implemented. VirtualAlloc(null, " ++
                    "bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) likewise returns " ++
                    "zero-initialized, demand-paged memory — wire it in here (and a " ++
                    "matching VirtualFree in `free`) when a Windows target is added.",
            );
            const bytes = n * @sizeOf(T);
            const mapping = std.posix.mmap(
                null,
                bytes,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            // Page alignment (≥ any scalar's alignment) makes the reinterpret safe.
            const ptr: [*]T = @ptrCast(mapping.ptr);
            return .{ .items = ptr[0..n], .mapping = mapping };
        }

        pub fn free(self: *Self) void {
            if (self.mapping.len != 0) std.posix.munmap(self.mapping);
            self.* = .{};
        }
    };
}

test "ZeroPagedArray: fresh entries read as zero (demand-zero invariant)" {
    // Large enough to span several pages, so this really exercises the
    // mapping rather than a single fault.
    const n = 100_000;

    // Enum case: a fresh entry must read as the `= 0` variant. If the backing
    // memory were ever non-zero, either this comparison fails or (for a byte
    // outside the enum's variants) the enum read trips a safety panic — either
    // way the guarantee breaks loudly instead of silently corrupting state.
    const State = enum(u8) { not_computed = 0, in_progress = 1, computed = 2 };
    var states = try ZeroPagedArray(State).alloc(n);
    defer states.free();
    try std.testing.expectEqual(@as(usize, n), states.items.len);
    for (states.items) |s| try std.testing.expectEqual(State.not_computed, s);

    // Integer case: mirrors `sym_types`, whose `0` means "no type yet".
    var nums = try ZeroPagedArray(u32).alloc(n);
    defer nums.free();
    for (nums.items) |v| try std.testing.expectEqual(@as(u32, 0), v);

    // Writes stick, and a subsequent free/realloc hands back a fresh zero map.
    states.items[7] = .computed;
    try std.testing.expectEqual(State.computed, states.items[7]);
    states.free();
    try std.testing.expectEqual(@as(usize, 0), states.items.len);
}

test "ZeroPagedArray: zero-length alloc is empty and safe to free" {
    var empty = try ZeroPagedArray(u32).alloc(0);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    empty.free(); // no-op, must not munmap a null mapping
}
