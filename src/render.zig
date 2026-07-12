//! Pretty (tsc-style) diagnostic rendering (M6).
//!
//! `--pretty` output: a tsc-shaped header line, the offending source line
//! with a grey line-number gutter, and a caret (`^`, single-character
//! spans) or tilde (`~~~`) underline in red. Colors: cyan file path,
//! yellow line/column, red `error`, grey error code and gutter. The
//! renderer writes to any `std.Io.Writer` and takes `color` explicitly so
//! tests can capture plain strings; the non-pretty CLI format is untouched
//! (stable for tooling and the conformance harness).

const std = @import("std");
const Io = std.Io;
const source = @import("source.zig");

pub const Span = source.Span;

const reset = "\x1b[0m";
const red = "\x1b[31m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const grey = "\x1b[90m";

fn lineOfOffset(line_starts: []const u32, offset: u32) u32 {
    std.debug.assert(line_starts.len > 0);
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

/// Render one diagnostic tsc-style. `ts_code` 0 means "no tsc code"
/// (scanner/parser diagnostics): the header shows plain `error:`.
pub fn renderPretty(
    w: *Io.Writer,
    color: bool,
    path: []const u8,
    src: []const u8,
    line_starts: []const u32,
    span: Span,
    ts_code: u16,
    msg: []const u8,
) Io.Writer.Error!void {
    const start: u32 = @min(span.start, @as(u32, @intCast(src.len)));
    const line = lineOfOffset(line_starts, start);
    const line_start = line_starts[line];
    var line_end: u32 = if (line + 1 < line_starts.len)
        line_starts[line + 1] - 1 // strip the '\n'
    else
        @intCast(src.len);
    // The last line of the file keeps its trailing newline in `src`; strip
    // it (and any '\r') so the excerpt never prints a line break.
    while (line_end > line_start and
        (src[line_end - 1] == '\n' or src[line_end - 1] == '\r')) line_end -= 1;
    const col = start - line_start;

    // Header: path:line:col - error TScode: message
    if (color) {
        try w.print("{s}{s}{s}:{s}{d}{s}:{s}{d}{s} - {s}error{s}", .{
            cyan,   path,    reset, yellow, line + 1, reset,
            yellow, col + 1, reset, red,    reset,
        });
        if (ts_code != 0) {
            try w.print(" {s}TS{d}:{s} {s}\n", .{ grey, ts_code, reset, msg });
        } else {
            try w.print("{s}:{s} {s}\n", .{ grey, reset, msg });
        }
    } else {
        if (ts_code != 0) {
            try w.print("{s}:{d}:{d} - error TS{d}: {s}\n", .{ path, line + 1, col + 1, ts_code, msg });
        } else {
            try w.print("{s}:{d}:{d} - error: {s}\n", .{ path, line + 1, col + 1, msg });
        }
    }
    try w.writeAll("\n");

    // Source excerpt with line-number gutter (tabs render as one space so
    // the underline stays aligned).
    var num_buf: [12]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch unreachable;
    if (color) {
        try w.print("{s}{s}{s} ", .{ grey, num, reset });
    } else {
        try w.print("{s} ", .{num});
    }
    for (src[line_start..line_end]) |c| {
        try w.writeByte(if (c == '\t') ' ' else c);
    }
    try w.writeAll("\n");

    // Underline row: spaces under the gutter and the leading columns, then
    // '^' (length 1) or '~'s.
    try w.splatByteAll(' ', num.len + 1);
    try w.splatByteAll(' ', col);
    const avail: u32 = if (start < line_end) line_end - start else 0;
    const span_len: u32 = if (span.end > start) span.end - start else 1;
    const ul_len: u32 = @max(1, @min(span_len, @max(avail, 1)));
    if (color) try w.writeAll(red);
    try w.splatByteAll(if (ul_len == 1) '^' else '~', ul_len);
    if (color) try w.writeAll(reset);
    try w.writeAll("\n\n");
}

/// tsc's final summary line. No-op when there are no errors.
/// `first_path`/`first_line` locate the first reported error.
pub fn renderSummary(
    w: *Io.Writer,
    color: bool,
    total: usize,
    files_with_errors: usize,
    first_path: []const u8,
    first_line: u32,
) Io.Writer.Error!void {
    if (total == 0) return;
    if (total == 1) {
        if (color) {
            try w.print("Found 1 error in {s}{s}{s}:{s}{d}{s}\n", .{
                cyan, first_path, reset, yellow, first_line, reset,
            });
        } else {
            try w.print("Found 1 error in {s}:{d}\n", .{ first_path, first_line });
        }
        return;
    }
    if (files_with_errors == 1) {
        if (color) {
            try w.print("Found {d} errors in the same file, starting at: {s}{s}{s}:{s}{d}{s}\n", .{
                total, cyan, first_path, reset, yellow, first_line, reset,
            });
        } else {
            try w.print("Found {d} errors in the same file, starting at: {s}:{d}\n", .{
                total, first_path, first_line,
            });
        }
        return;
    }
    try w.print("Found {d} errors in {d} files.\n", .{ total, files_with_errors });
}

// ===========================================================================
// tests (captured string output; no TTY needed)
// ===========================================================================

const testing = std.testing;

fn renderToString(
    alloc: std.mem.Allocator,
    color: bool,
    src: []const u8,
    span: Span,
    ts_code: u16,
    msg: []const u8,
) ![]u8 {
    const line_starts = try source.computeLineStarts(alloc, src);
    defer alloc.free(line_starts);
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try renderPretty(&out.writer, color, "demo.ts", src, line_starts, span, ts_code, msg);
    return alloc.dupe(u8, out.written());
}

test "pretty: tilde underline, gutter, tsc header" {
    const alloc = testing.allocator;
    const src = "let a = 1;\nconst x: number = \"hi\";\nlet b = 2;\n";
    // Span of "\"hi\"" on line 2: col 19, length 4.
    const got = try renderToString(alloc, false, src, .{ .start = 29, .end = 33 }, 2322, "Type 'string' is not assignable to type 'number'.");
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\demo.ts:2:19 - error TS2322: Type 'string' is not assignable to type 'number'.
        \\
        \\2 const x: number = "hi";
        \\                    ~~~~
        \\
        \\
    , got);
}

test "pretty: caret for single-character span, no tsc code" {
    const alloc = testing.allocator;
    const src = "let x = ;\n";
    const got = try renderToString(alloc, false, src, .{ .start = 8, .end = 9 }, 0, "expected an expression");
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\demo.ts:1:9 - error: expected an expression
        \\
        \\1 let x = ;
        \\          ^
        \\
        \\
    , got);
}

test "pretty: span clamped to line end, offset at EOF" {
    const alloc = testing.allocator;
    const src = "const a: number = fn(\n  1,\n  2);\n";
    // Multi-line span starting at "fn(": underline clamps to line 1's end.
    const got = try renderToString(alloc, false, src, .{ .start = 18, .end = 32 }, 2769, "No overload matches this call.");
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\demo.ts:1:19 - error TS2769: No overload matches this call.
        \\
        \\1 const a: number = fn(
        \\                    ~~~
        \\
        \\
    , got);

    // Offset exactly at EOF must not crash and points one past the line.
    const src2 = "let q = 1";
    const got2 = try renderToString(alloc, false, src2, .{ .start = 9, .end = 9 }, 0, "expected ';'");
    defer alloc.free(got2);
    try testing.expectEqualStrings(
        \\demo.ts:1:10 - error: expected ';'
        \\
        \\1 let q = 1
        \\           ^
        \\
        \\
    , got2);
}

test "pretty: tabs render as spaces so the underline aligns" {
    const alloc = testing.allocator;
    const src = "\tlet y: string = 5;\n";
    const got = try renderToString(alloc, false, src, .{ .start = 5, .end = 6 }, 2322, "nope");
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\demo.ts:1:6 - error TS2322: nope
        \\
        \\1  let y: string = 5;
        \\       ^
        \\
        \\
    , got);
}

test "pretty: ANSI colors present when enabled" {
    const alloc = testing.allocator;
    const src = "const x: number = \"hi\";\n";
    const got = try renderToString(alloc, true, src, .{ .start = 18, .end = 22 }, 2322, "msg");
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, cyan) != null); // file
    try testing.expect(std.mem.indexOf(u8, got, red) != null); // error + squiggle
    try testing.expect(std.mem.indexOf(u8, got, grey) != null); // code + gutter
    try testing.expect(std.mem.indexOf(u8, got, "TS2322") != null);
    try testing.expect(std.mem.endsWith(u8, got, reset ++ "\n\n"));
}

test "summary phrasing matches tsc" {
    const alloc = testing.allocator;
    var out: Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try renderSummary(&out.writer, false, 0, 0, "", 0);
    try testing.expectEqualStrings("", out.written());

    try renderSummary(&out.writer, false, 1, 1, "a.ts", 3);
    try testing.expectEqualStrings("Found 1 error in a.ts:3\n", out.written());

    out.clearRetainingCapacity();
    try renderSummary(&out.writer, false, 4, 1, "a.ts", 3);
    try testing.expectEqualStrings(
        "Found 4 errors in the same file, starting at: a.ts:3\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try renderSummary(&out.writer, false, 5, 2, "a.ts", 3);
    try testing.expectEqualStrings("Found 5 errors in 2 files.\n", out.written());
}
