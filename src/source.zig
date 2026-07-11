//! File loading (mmap-backed), line-offset tables, and source spans.
//!
//! Source bytes are memory-mapped read-only where the platform allows it;
//! the AST will reference them by offset and we never copy source text
//! except into the string interner. Line/column information is computed
//! lazily from a line-offset table, never stored per token.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A half-open byte range [start, end) into a source file.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(s: Span) u32 {
        return s.end - s.start;
    }
};

/// Zero-based line/column position.
pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// How the source bytes are owned.
pub const Backing = union(enum) {
    /// Memory-mapped file; unmapped on deinit.
    mapped: Io.File.MemoryMap,
    /// Bytes allocated from the caller's arena (fallback path, tests).
    owned,
    /// Bytes borrowed from elsewhere (e.g. static test data).
    borrowed,
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
    pub fn load(io: Io, alloc: Allocator, path: []const u8) !Source {
        return loadInDir(io, Io.Dir.cwd(), alloc, path);
    }

    /// Load a file. Tries mmap first; falls back to reading the file into
    /// `alloc` (an arena) if mapping is unsupported. `line_starts` is always
    /// allocated from `alloc`.
    pub fn loadInDir(io: Io, dir: Io.Dir, alloc: Allocator, path: []const u8) !Source {
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
    /// fallback bytes) is released with the arena, not here.
    pub fn deinit(s: *Source, io: Io) void {
        switch (s.backing) {
            .mapped => |*map| map.destroy(io),
            .owned, .borrowed => {},
        }
        s.* = undefined;
    }

    /// Number of lines (a trailing newline does not start a new line unless
    /// followed by content; an empty file has 1 line).
    pub fn lineCount(s: *const Source) u32 {
        return @intCast(s.line_starts.len);
    }

    /// Map a byte offset to zero-based line/column via binary search.
    pub fn lineCol(s: *const Source, offset: u32) LineCol {
        const line = lineOfOffset(s.line_starts, offset);
        return .{ .line = line, .col = offset - s.line_starts[line] };
    }

    /// Bytes used by the line-offset table.
    pub fn lineTableBytes(s: *const Source) usize {
        return s.line_starts.len * @sizeOf(u32);
    }
};

/// Greatest index i such that line_starts[i] <= offset.
fn lineOfOffset(line_starts: []const u32, offset: u32) u32 {
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
pub fn computeLineStarts(alloc: Allocator, bytes: []const u8) Allocator.Error![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(alloc);
    try starts.append(alloc, 0);
    for (bytes, 0..) |b, i| {
        if (b == '\n' and i + 1 < bytes.len) {
            try starts.append(alloc, @intCast(i + 1));
        }
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

    var src = try Source.loadInDir(io, tmp.dir, arena.allocator(), "hello.ts");
    defer src.deinit(io);

    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", src.bytes);
    try std.testing.expectEqual(@as(u32, 2), src.lineCount());
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 6 }, src.lineCol(19));
}
