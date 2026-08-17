//! File loading, line-offset tables, and source spans.
//!
//! Small files (the overwhelming majority: the mean TypeScript source in a
//! real project is a few KB) are read into shared, never-moving `Pack`
//! segments. One mmap per file would round every file up to a whole page,
//! and the scanner touches every page it maps — on a 6.2k-file project that
//! padding costs more resident memory than the text itself. Large files are
//! still mapped read-only, where rounding is a rounding error and mapping
//! saves the copy.
//!
//! Either way the bytes stay at a fixed address for the whole run: the AST
//! references them by offset, diagnostics re-slice them when rendering
//! excerpts, and we never copy source text except into the string interner.
//! Line/column information is computed lazily from a line-offset table,
//! never stored per token.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// Position types live in span.zig (no file-loading dependency); re-exported
// here so every existing `source.Span` / `source.LineCol` keeps working.
pub const Span = @import("span.zig").Span;
pub const LineCol = @import("span.zig").LineCol;

/// How the source bytes are owned.
pub const Backing = union(enum) {
    /// Memory-mapped file; unmapped on deinit.
    mapped: Io.File.MemoryMap,
    /// Bytes bump-allocated out of a shared `Pack` segment; released with
    /// the pack, not with the source.
    pooled,
    /// Bytes allocated from the caller's arena (fallback path, tests).
    owned,
    /// Bytes borrowed from elsewhere (e.g. static test data).
    borrowed,
};

/// Bump allocator for source text: many small files packed end to end into
/// a few large segments instead of one page-rounded mapping each.
///
/// Segments are fixed-size and never resized or moved, so every slice handed
/// out stays valid until `deinit` — which the front end relies on, since the
/// AST, the binder and diagnostic rendering all keep offsets into the text
/// for the whole run.
///
/// Not thread-safe by design: give each loader thread its own pack. Packing
/// is content- and address-independent, so output stays byte-identical for
/// any worker count.
pub const Pack = struct {
    /// Head of the segment list; the bump cursor points into this one.
    first: ?*Segment = null,
    /// Bytes of the head segment's payload already handed out.
    used: usize = 0,
    /// Payload bytes handed out to sources.
    text_bytes: usize = 0,
    /// Bytes requested from the OS for segments (a page multiple).
    reserved_bytes: usize = 0,

    /// Files this size or larger keep a private mapping instead.
    const mmap_threshold: usize = 128 << 10;
    /// Size of one segment, header included. A page multiple, so a segment
    /// pays no rounding of its own. The tail abandoned when a file does not
    /// fit is at most one file's worth (< `mmap_threshold`, ~5 KB typical).
    const segment_size: usize = 1 << 20;

    const Segment = struct {
        next: ?*Segment,
        /// Size of this allocation, header included.
        size: usize,

        fn payload(seg: *Segment) []u8 {
            const base: [*]align(@alignOf(Segment)) u8 = @ptrCast(seg);
            return base[@sizeOf(Segment)..seg.size];
        }
    };

    /// Reserve `n` bytes that keep their address for the life of the pack.
    pub fn reserve(p: *Pack, n: usize) Allocator.Error![]u8 {
        const need_segment = if (p.first) |seg| p.used + n > seg.payload().len else true;
        if (need_segment) {
            const size = @max(segment_size, @sizeOf(Segment) + n);
            const raw = try std.heap.page_allocator.alignedAlloc(u8, .of(Segment), size);
            const seg: *Segment = @ptrCast(raw.ptr);
            seg.* = .{ .next = p.first, .size = size };
            p.first = seg;
            p.used = 0;
            p.reserved_bytes += size;
        }
        const buf = p.first.?.payload()[p.used..][0..n];
        p.used += n;
        p.text_bytes += n;
        return buf;
    }

    /// Frees every segment. Invalidates all source text handed out.
    pub fn deinit(p: *Pack) void {
        var it = p.first;
        while (it) |seg| {
            it = seg.next;
            const raw: [*]align(@alignOf(Segment)) u8 = @ptrCast(seg);
            std.heap.page_allocator.free(raw[0..seg.size]);
        }
        p.* = .{};
    }
};

pub const Source = struct {
    /// Path as given on the command line (not owned).
    path: []const u8,
    /// The raw file bytes, read-only.
    bytes: []const u8,
    /// Byte offset of the start of each line. line_starts[0] == 0 always.
    line_starts: []const u32,
    backing: Backing,

    /// Build a Source from bytes already in memory (no file involved).
    pub fn fromBytes(alloc: Allocator, path: []const u8, bytes: []const u8) Allocator.Error!Source {
        return .{
            .path = path,
            .bytes = bytes,
            .line_starts = try computeLineStarts(alloc, bytes),
            .backing = .borrowed,
        };
    }

    /// Load a file relative to the current working directory.
    pub fn load(io: Io, alloc: Allocator, path: []const u8, pack: ?*Pack) !Source {
        return loadInDir(io, Io.Dir.cwd(), alloc, path, pack);
    }

    /// Load a file. Small files are read into `pack` (see `Pack`); larger
    /// ones are mapped, falling back to reading into `alloc` (an arena) if
    /// mapping is unsupported. `line_starts` is always allocated from
    /// `alloc`. A null `pack` maps every file, as before.
    pub fn loadInDir(io: Io, dir: Io.Dir, alloc: Allocator, path: []const u8, pack: ?*Pack) !Source {
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotFile;
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;

        if (size == 0) {
            return .{
                .path = path,
                .bytes = &.{},
                .line_starts = try computeLineStarts(alloc, &.{}),
                .backing = .owned,
            };
        }

        if (size < Pack.mmap_threshold) {
            if (pack) |p| {
                const buf = try p.reserve(size);
                // A short read means the file shrank under us; keep what we
                // got rather than exposing uninitialized segment bytes.
                const n = try file.readPositionalAll(io, buf, 0);
                const bytes = buf[0..n];
                return .{
                    .path = path,
                    .bytes = bytes,
                    .line_starts = try computeLineStarts(alloc, bytes),
                    .backing = .pooled,
                };
            }
        }

        if (Io.File.MemoryMap.create(io, file, .{
            .len = size,
            .protection = .{ .read = true, .write = false },
        })) |map| {
            return .{
                .path = path,
                .bytes = map.memory[0..size],
                .line_starts = try computeLineStarts(alloc, map.memory[0..size]),
                .backing = .{ .mapped = map },
            };
        } else |_| {
            // Fallback: plain read into the arena.
            const bytes = try dir.readFileAlloc(io, path, alloc, .limited(size + 1));
            return .{
                .path = path,
                .bytes = bytes,
                .line_starts = try computeLineStarts(alloc, bytes),
                .backing = .owned,
            };
        }
    }

    /// Releases the mapping if any. Arena-allocated memory (line table,
    /// fallback bytes) is released with the arena, and packed text with the
    /// `Pack`, not here.
    pub fn deinit(s: *Source, io: Io) void {
        switch (s.backing) {
            .mapped => |*map| map.destroy(io),
            .pooled, .owned, .borrowed => {},
        }
        s.* = undefined;
    }

    /// Number of lines (a trailing newline does not start a new line unless
    /// followed by content; an empty file has 1 line).
    pub fn lineCount(s: *const Source) u32 {
        return @intCast(s.line_starts.len);
    }

    /// Map a byte offset to zero-based line/column via binary search.
    /// tsc's `getLineAndCharacterOfPosition`. A file ending in a line break has
    /// one more LINE START than it has lines of text: tsc's `computeLineStarts`
    /// records the offset after every break unconditionally, so the end-of-file
    /// offset lands on a final empty line. `line_starts` deliberately omits that
    /// entry (`lineCount` is a count of lines with text, which is what the
    /// throughput reports mean), so the EOF offset is special-cased here instead
    /// — otherwise every diagnostic anchored at EOF (`'}' expected`,
    /// `'catch' or 'finally' expected`, an unterminated comment) reports one
    /// line short of where tsc puts it.
    pub fn lineCol(s: *const Source, offset: u32) LineCol {
        const ends_in_break = s.bytes.len > 0 and
            (s.bytes[s.bytes.len - 1] == '\n' or s.bytes[s.bytes.len - 1] == '\r');
        if (offset >= s.bytes.len and ends_in_break) {
            return .{ .line = @intCast(s.line_starts.len), .col = offset - @as(u32, @intCast(s.bytes.len)) };
        }
        const line = lineOfOffset(s.line_starts, offset);
        return .{ .line = line, .col = offset - s.line_starts[line] };
    }

    /// Bytes used by the line-offset table.
    pub fn lineTableBytes(s: *const Source) usize {
        return s.line_starts.len * @sizeOf(u32);
    }
};

/// Greatest index i such that line_starts[i] <= offset. Public because
/// diagnostic rendering walks a line table it holds directly, without a
/// `Source` around it.
pub fn lineOfOffset(line_starts: []const u32, offset: u32) u32 {
    std.debug.assert(line_starts.len > 0);
    var lo: usize = 0;
    var hi: usize = line_starts.len; // exclusive
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

/// Compute byte offsets of line starts. Always contains at least offset 0.
///
/// The line terminators are tsc's `computeLineStarts`: LF, CRLF, and a LONE CR
/// — the last one matters because the test corpus is CRLF and the harness
/// splits its multi-file cases on `\n`, leaving a trailing `\r` as the final
/// line of nearly every unit. Counting it (as tsc's `case carriageReturn:`
/// falling through to `case lineFeed:` does) is what puts an end-of-file
/// diagnostic on the same line tsc puts it on. The scanner has always treated
/// a lone CR as a break; only this table did not.
/// This runs over every byte of every source file, so the fast path — the
/// ~98% of bytes that end no line — is kept to the single comparison it was
/// before CR joined LF: every line terminator is `<= '\r'`, so one test
/// rejects the whole printable range before either of them is looked at.
pub fn computeLineStarts(alloc: Allocator, bytes: []const u8) Allocator.Error![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(alloc);
    try starts.append(alloc, 0);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c > '\r') continue;
        if (c == '\r') {
            // CRLF is one break, not two.
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
        } else if (c != '\n') continue;
        // The offset after a break that ENDS the file is the trailing empty
        // line, which this table deliberately omits — see `lineCol`.
        if (i + 1 < bytes.len) try starts.append(alloc, @intCast(i + 1));
    }
    return starts.toOwnedSlice(alloc);
}

test "line table: empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var src = try Source.fromBytes(arena.allocator(), "empty.ts", "");
    try std.testing.expectEqual(@as(u32, 1), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 0 }, src.lineCol(0));
}

test "line table: offsets and columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "let a = 1;\nlet b = 2;\n\nconst c = a + b;\n";
    var src = try Source.fromBytes(arena.allocator(), "t.ts", text);

    // Lines: 0:"let a = 1;" 1:"let b = 2;" 2:"" 3:"const c = a + b;"
    try std.testing.expectEqual(@as(u32, 4), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 0 }, src.lineCol(0));
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 4 }, src.lineCol(4)); // 'a'
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 10 }, src.lineCol(10)); // '\n'
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, src.lineCol(11)); // 'l' of second let
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 0 }, src.lineCol(22)); // empty line
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 0 }, src.lineCol(23)); // 'c' of const
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 6 }, src.lineCol(29)); // 'c' ident
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(u32)), src.lineTableBytes());
}

test "line table: no trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "a\nb";
    var src = try Source.fromBytes(arena.allocator(), "t.ts", text);
    try std.testing.expectEqual(@as(u32, 2), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, src.lineCol(2));
}

test "line table: the EOF offset of a newline-terminated file is its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // tsc reports `try { }\n` + EOF as 2:1, not 1:9 — the file has one line of
    // text but two line STARTS, and the diagnostic sits on the second.
    var src = try Source.fromBytes(arena.allocator(), "t.ts", "try { }\n");
    try std.testing.expectEqual(@as(u32, 1), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 7 }, src.lineCol(7));
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, src.lineCol(8));
    // Several trailing breaks each open a line; the last one holds EOF.
    var two = try Source.fromBytes(arena.allocator(), "t.ts", "a\n\n");
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, two.lineCol(2));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 0 }, two.lineCol(3));
    // Without a trailing break EOF stays on the last line of text.
    var bare = try Source.fromBytes(arena.allocator(), "t.ts", "a\nb");
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, bare.lineCol(3));
    // An empty file has no break to open a line.
    var empty = try Source.fromBytes(arena.allocator(), "t.ts", "");
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 0 }, empty.lineCol(0));
}

test "span length" {
    const s: Span = .{ .start = 3, .end = 10 };
    try std.testing.expectEqual(@as(u32, 7), s.len());
}

test "load via mmap round-trips file contents" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.ts", .data = "const x = 1;\nconst y = 2;\n" });

    var src = try Source.loadInDir(io, tmp.dir, arena.allocator(), "hello.ts", null);
    defer src.deinit(io);

    try std.testing.expect(src.backing == .mapped);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", src.bytes);
    try std.testing.expectEqual(@as(u32, 2), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 6 }, src.lineCol(19));
}

test "packed load: small files share a segment, big ones stay mapped" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data = "const b = 2;\nconst c = 3;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.ts", .data = "" });

    const big = try std.testing.allocator.alloc(u8, Pack.mmap_threshold + 7);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    big[big.len - 1] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "big.ts", .data = big });

    var pack: Pack = .{};
    defer pack.deinit();

    const a = try Source.loadInDir(io, tmp.dir, arena.allocator(), "a.ts", &pack);
    const b = try Source.loadInDir(io, tmp.dir, arena.allocator(), "b.ts", &pack);
    const e = try Source.loadInDir(io, tmp.dir, arena.allocator(), "empty.ts", &pack);
    var h = try Source.loadInDir(io, tmp.dir, arena.allocator(), "big.ts", &pack);
    defer h.deinit(io);

    try std.testing.expect(a.backing == .pooled);
    try std.testing.expect(b.backing == .pooled);
    try std.testing.expect(h.backing == .mapped); // over the threshold
    try std.testing.expectEqualStrings("const a = 1;\n", a.bytes);
    try std.testing.expectEqualStrings("const b = 2;\nconst c = 3;\n", b.bytes);
    try std.testing.expectEqualStrings("", e.bytes);
    try std.testing.expectEqualStrings(big, h.bytes);

    // Packed end to end in one segment, no padding between files.
    try std.testing.expectEqual(@as(usize, 1), pack.reserved_bytes / Pack.segment_size);
    try std.testing.expectEqual(a.bytes.len + b.bytes.len, pack.text_bytes);
    try std.testing.expectEqual(@intFromPtr(a.bytes.ptr) + a.bytes.len, @intFromPtr(b.bytes.ptr));

    // Earlier text keeps its address once a later segment is added.
    const a_ptr = a.bytes.ptr;
    var i: usize = 0;
    while (i < 2 * Pack.segment_size / Pack.mmap_threshold) : (i += 1) {
        _ = try pack.reserve(Pack.mmap_threshold - 1);
    }
    try std.testing.expect(pack.reserved_bytes > 2 * Pack.segment_size);
    try std.testing.expectEqual(a_ptr, a.bytes.ptr);
    try std.testing.expectEqualStrings("const a = 1;\n", a.bytes);
}
