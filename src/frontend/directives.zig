//! Comment directives: `@ts-nocheck` / `@ts-check` (file pragmas) and
//! `@ts-ignore` / `@ts-expect-error` (next-line suppression).
//!
//! Semantics mirror tsc:
//!
//! - **`// @ts-nocheck`** is a *pragma*, so it only counts in the leading
//!   comment block (before the first token) and only in a `//` comment.
//!   Whitespace and other comments may precede it, and arbitrary prose may
//!   follow it on the same line. It suppresses every *semantic* diagnostic in
//!   the file (bind + link + check) while leaving syntax errors alone.
//!   `// @ts-check` is the inverse; the last of the two in the leading block
//!   wins.
//!
//! - **`// @ts-ignore`** / **`// @ts-expect-error`** are *comment directives*,
//!   valid anywhere. They suppress the semantic diagnostics of the next line
//!   that is neither blank nor a `//`-comment-only line, so a run of stacked
//!   `//` comments between the directive and the code it guards is transparent
//!   (tsc's `markPrecedingCommentDirectiveLine` walks backwards over exactly
//!   those lines — a *block* comment line is opaque and stops the walk).
//!
//! Directive matching is per *line of a comment*, and the line a directive is
//! found on is the one it guards the successor of. That is why a directive in
//! a block comment spanning several lines is inert in practice: the line it
//! guards is another line of the same comment (`*/`, or more comment text),
//! never the code below. All of this is pinned against the oracle in
//! `test/conformance/directives/`.
//!
//! `TS2578` ("Unused '@ts-expect-error' directive") is deliberately *not*
//! implemented: ztsc under-reports relative to tsc, so a directive tsc
//! considers used can look unused here, and emitting TS2578 on that basis
//! would manufacture a false positive on real code. Suppression is
//! implemented for both spellings; the unused-directive report is an accepted
//! under-report.
//!
//! Scanning is gated on the file containing the byte sequence `@ts-` at all
//! (one vectorised `@` sweep), so files without directives — effectively all
//! of them — pay a single memchr pass and allocate nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// In-file alias for the scan error set.
const Error = error{OutOfMemory};

/// A half-open byte range of a source line whose semantic diagnostics are
/// suppressed. Ranges are disjoint and sorted ascending.
pub const LineRange = struct {
    start: u32,
    end: u32,
};

/// The directive state of one file, sealed into the per-file arena.
pub const File = struct {
    /// `@ts-nocheck` won in the leading comment block: every semantic
    /// diagnostic in this file is suppressed.
    nocheck: bool = false,
    /// Lines guarded by a preceding `@ts-ignore` / `@ts-expect-error`.
    ignored: []const LineRange = &.{},

    pub const none: File = .{};

    /// True if this file carries any directive at all (fast path guard).
    /// Only the directive tests ask; real fast paths test `nocheck` and
    /// `ignored.len` where they already hold the fields.
    fn any(f: File) bool {
        return f.nocheck or f.ignored.len > 0;
    }

    /// True if a *semantic* diagnostic starting at byte offset `pos` is
    /// suppressed. Syntax diagnostics must not be routed through here.
    pub fn suppresses(f: File, pos: u32) bool {
        if (f.nocheck) return true;
        // Binary search the disjoint, ascending ranges.
        var lo: usize = 0;
        var hi: usize = f.ignored.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = f.ignored[mid];
            if (pos < r.start) {
                hi = mid;
            } else if (pos >= r.end) {
                lo = mid + 1;
            } else return true;
        }
        return false;
    }
};

/// Scan `src` for comment directives. Output lives in `alloc` (a per-file
/// arena); nothing is freed individually.
pub fn scan(alloc: Allocator, src: []const u8) Error!File {
    if (!mayHaveDirective(src)) return .none;

    // The last `@ts-nocheck`/`@ts-check` in the leading block wins (tsc's
    // `checkJsDirective` keeps whichever has the greater position).
    var nocheck = false;
    var ignored: std.ArrayList(LineRange) = .empty;
    defer ignored.deinit(alloc);

    var it: CommentIter = .{ .src = src };
    while (it.next()) |c| {
        // File pragmas: leading `//` comments only, before the first token.
        if (c.leading and c.line) {
            if (pragmaKind(src[c.start..c.end])) |on| nocheck = !on;
        }
        // Directives match line by line within the comment, and each match
        // guards the successor of *its own* line.
        var pos: u32 = c.start;
        while (pos < c.end) {
            const nl: u32 = @intCast(std.mem.indexOfScalarPos(u8, src[0..c.end], pos, '\n') orelse c.end);
            if (isDirectiveLine(src[pos..nl], c.line)) {
                if (targetLine(src, nl)) |r| {
                    // Stacked directives collapse onto the same guarded line.
                    if (ignored.items.len == 0 or ignored.items[ignored.items.len - 1].start != r.start) {
                        try ignored.append(alloc, r);
                    }
                }
            }
            if (nl == c.end) break;
            pos = nl + 1;
        }
    }
    if (!nocheck and ignored.items.len == 0) return .none;
    return .{ .nocheck = nocheck, .ignored = try alloc.dupe(LineRange, ignored.items) };
}

/// One `@` sweep: a file with no `@ts-` sequence has no directive, and that is
/// the overwhelmingly common case. `std.mem.indexOfScalarPos` is vectorised,
/// so this costs a memchr pass and no allocation.
fn mayHaveDirective(src: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '@')) |at| {
        if (std.mem.startsWith(u8, src[at + 1 ..], "ts-")) return true;
        i = at + 1;
    }
    return false;
}

const Comment = struct {
    /// Offset of the opening `/`.
    start: u32,
    /// Offset just past the comment (past `*/`, or at the line terminator).
    end: u32,
    /// `//`-style (as opposed to `/* */`).
    line: bool,
    /// Nothing but whitespace and other comments precedes it — i.e. it is part
    /// of the file's leading comment block, where pragmas live.
    leading: bool,
};

/// Enumerates comments, skipping over string and template literals so that a
/// `"// @ts-ignore"` inside a string is not mistaken for one. Regular
/// expression literals are not tracked (`/` is only treated as a comment start
/// when followed by `/` or `*`, and a directive never follows a regex on the
/// same line), which keeps this independent of the parser's regex/division
/// disambiguation.
const CommentIter = struct {
    src: []const u8,
    i: usize = 0,
    saw_code: bool = false,

    fn next(it: *CommentIter) ?Comment {
        const src = it.src;
        while (it.i < src.len) {
            const ch = src[it.i];
            switch (ch) {
                ' ', '\t', '\r', '\n', 0x0B, 0x0C => it.i += 1,
                '/' => {
                    const c1: u8 = if (it.i + 1 < src.len) src[it.i + 1] else 0;
                    if (c1 == '/') {
                        const start = it.i;
                        it.i += 2;
                        while (it.i < src.len and src[it.i] != '\n' and src[it.i] != '\r') it.i += 1;
                        return .{
                            .start = @intCast(start),
                            .end = @intCast(it.i),
                            .line = true,
                            .leading = !it.saw_code,
                        };
                    }
                    if (c1 == '*') {
                        const start = it.i;
                        it.i += 2;
                        while (it.i + 1 < src.len and !(src[it.i] == '*' and src[it.i + 1] == '/')) it.i += 1;
                        it.i = if (it.i + 1 < src.len) it.i + 2 else src.len;
                        return .{
                            .start = @intCast(start),
                            .end = @intCast(it.i),
                            .line = false,
                            .leading = !it.saw_code,
                        };
                    }
                    it.saw_code = true;
                    it.i += 1;
                },
                '"', '\'', '`' => {
                    it.saw_code = true;
                    it.i = skipQuoted(src, it.i);
                },
                else => {
                    it.saw_code = true;
                    it.i += 1;
                },
            }
        }
        return null;
    }
};

/// Skip a string or template literal starting at `open`. Returns the offset
/// just past it. Template substitutions are skipped by brace counting, which
/// is enough to stay out of the literal's text.
fn skipQuoted(src: []const u8, open: usize) usize {
    const q = src[open];
    var i = open + 1;
    var depth: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '\\') {
            i += 2;
            continue;
        }
        if (q != '`' and (ch == '\n' or ch == '\r')) return i; // unterminated
        if (q == '`' and depth == 0 and ch == '$' and i + 1 < src.len and src[i + 1] == '{') {
            depth = 1;
            i += 2;
            continue;
        }
        if (depth > 0) {
            if (ch == '{') depth += 1;
            if (ch == '}') depth -= 1;
            i += 1;
            continue;
        }
        if (ch == q) return i + 1;
        i += 1;
    }
    return src.len;
}

/// `// @ts-nocheck` / `// @ts-check` as a file pragma. Returns whether
/// checking is enabled (`true` for `@ts-check`), or null if `text` is not one.
/// tsc's single-line pragma form is `/^\/\/\/?\s*@([^\s:]+)...(.*)$/i`: the
/// name runs to the next whitespace or colon and must equal the pragma's, but
/// anything may follow it on the line (`// @ts-nocheck (emscripten output)`).
fn pragmaKind(text: []const u8) ?bool {
    var s = stripLinePrefix(text) orelse return null;
    if (s.len == 0 or s[0] != '@') return null;
    s = s[1..];
    var n: usize = 0;
    while (n < s.len and !isSpace(s[n]) and s[n] != ':') n += 1;
    const name = s[0..n];
    if (std.ascii.eqlIgnoreCase(name, "ts-nocheck")) return false;
    if (std.ascii.eqlIgnoreCase(name, "ts-check")) return true;
    return null;
}

/// One line of a comment carrying `@ts-ignore` / `@ts-expect-error`, matching
/// the oracle's two directive patterns
///
///     line comment:       ^///?\s*@(ts-expect-error|ts-ignore)
///     block-comment line: ^(?:/|\*)*\s*@(ts-expect-error|ts-ignore)
///
/// Both are *prefix* matches with no trailing anchor, so `// @ts-ignore why`
/// and `// @ts-ignore-me` are both directives while `// see @ts-ignore` is
/// not (verified against the pinned oracle; see
/// `test/conformance/directives/`).
fn isDirectiveLine(text: []const u8, line: bool) bool {
    var s = if (line) (stripLinePrefix(text) orelse return false) else stripBlockPrefix(text);
    if (s.len == 0 or s[0] != '@') return false;
    s = s[1..];
    return std.mem.startsWith(u8, s, "ts-expect-error") or std.mem.startsWith(u8, s, "ts-ignore");
}

/// Strip `//` or `///` plus following whitespace. Null when `text` is not a
/// line comment.
fn stripLinePrefix(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "//")) return null;
    var s = text[2..];
    if (s.len > 0 and s[0] == '/') s = s[1..];
    return trimLeadingSpace(s);
}

/// Strip a block comment's leading run of `/` and `*` plus whitespace, tsc's
/// `^(?:\/|\*)*\s*` — so `/* @ts-ignore */` and `/** @ts-ignore */` both count.
fn stripBlockPrefix(text: []const u8) []const u8 {
    var s = text;
    while (s.len > 0 and (s[0] == '/' or s[0] == '*')) s = s[1..];
    return trimLeadingSpace(s);
}

fn trimLeadingSpace(text: []const u8) []const u8 {
    var s = text;
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    return s;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == 0x0B or ch == 0x0C;
}

/// The line a directive ending at `end` guards: the first line after it that
/// is neither blank nor a `//`-comment-only line. Null when there is none
/// (the directive trails a run of comments to end of file).
fn targetLine(src: []const u8, end: u32) ?LineRange {
    var line_start = nextLineStart(src, end) orelse return null;
    while (true) {
        const line_end = nextLineStart(src, line_start) orelse src.len;
        const body = std.mem.trim(u8, src[line_start..line_end], " \t\r\n\x0B\x0C");
        if (body.len != 0 and !std.mem.startsWith(u8, body, "//")) {
            return .{ .start = @intCast(line_start), .end = @intCast(line_end) };
        }
        if (line_end == src.len) return null;
        line_start = line_end;
    }
}

/// Offset of the first character of the line following the one containing
/// `pos`, or null at end of file.
fn nextLineStart(src: []const u8, pos: usize) ?usize {
    const nl = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse return null;
    if (nl + 1 >= src.len) return null;
    return nl + 1;
}

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

/// Scan into a caller-owned arena: `File.ignored` lives in `alloc`, so tests
/// hand it an arena rather than freeing the slice by hand.
fn scanTest(arena: *std.heap.ArenaAllocator, src: []const u8) Error!File {
    return scan(arena.allocator(), src);
}

test "no directive: zero-cost path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "const x: number = 1;\n// a plain comment\n");
    try testing.expect(!f.any());
    try testing.expect(!f.suppresses(0));
}

test "@ts-nocheck in the leading comment block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "/* eslint-disable */\n// @ts-nocheck\nconst x: string = 1;\n";
    const f = try scanTest(&arena, src);
    try testing.expect(f.nocheck);
    try testing.expect(f.suppresses(0));
    try testing.expect(f.suppresses(@intCast(src.len - 1)));
}

test "@ts-nocheck after code is not a pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "const x = 1;\n// @ts-nocheck\nconst y: string = 2;\n");
    try testing.expect(!f.nocheck);
}

test "@ts-check wins when it comes last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "// @ts-nocheck\n// @ts-check\nconst x = 1;\n");
    try testing.expect(!f.nocheck);
}

test "@ts-nocheck: the pragma name must match exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "// @ts-nocheckplease\nconst x = 1;\n");
    try testing.expect(!f.nocheck);
}

test "@ts-nocheck: prose may follow on the same line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "// @ts-nocheck generated file\nconst x: string = 1;\n");
    try testing.expect(f.nocheck);
}

test "@ts-nocheck in a block comment is not a pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "/* @ts-nocheck */\nconst x = 1;\n");
    try testing.expect(!f.nocheck);
}

test "@ts-ignore guards the next line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        "const a = 1;\n" ++ // line 1
        "// @ts-ignore\n" ++ // line 2
        "const b: string = 2;\n" ++ // line 3 (guarded)
        "const c: string = 3;\n"; // line 4
    const f = try scanTest(&arena, src);
    try testing.expect(!f.nocheck);
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
    const guarded = std.mem.indexOf(u8, src, "const b").?;
    const after = std.mem.indexOf(u8, src, "const c").?;
    try testing.expect(f.suppresses(@intCast(guarded)));
    try testing.expect(!f.suppresses(@intCast(after)));
    try testing.expect(!f.suppresses(0));
}

test "@ts-ignore skips intervening blank and comment lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        "// @ts-expect-error\n" ++
        "\n" ++
        "// explanatory note\n" ++
        "   \n" ++
        "const b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
}

test "trailing @ts-ignore guards the following line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "const a = 1; // @ts-ignore\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
    try testing.expect(!f.suppresses(0));
}

test "single-line block comment directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "/* @ts-ignore */\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
}

test "a directive inside a multi-line block guards only the comment's own next line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "/*\n@ts-ignore\n*/\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    // The guarded line is `*/`, not the code below it.
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "*/").?)));
    try testing.expect(!f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
}

test "a block-comment line is opaque to the backward walk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "// @ts-ignore\n/* note */\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expect(!f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
}

test "directive text inside a string literal is not a directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "const s = \"// @ts-ignore\";\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expect(!f.any());
}

test "directive text inside a template literal is not a directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "const s = `x ${1} // @ts-ignore`;\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expect(!f.any());
}

test "the directive name is a prefix match, but must start the comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The oracle's patterns have no trailing anchor, so a name run together
    // with more text still counts...
    const run_on = try scanTest(&arena, "// @ts-ignoreme\nconst b: string = 2;\n");
    try testing.expectEqual(@as(usize, 1), run_on.ignored.len);
    // ...but the directive has to be the first thing in the comment.
    const prose = try scanTest(&arena, "// see @ts-ignore\nconst b: string = 2;\n");
    try testing.expect(!prose.any());
}

test "stacked directives collapse onto one guarded line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "// @ts-ignore\n// @ts-expect-error\nconst b: string = 2;\n";
    const f = try scanTest(&arena, src);
    try testing.expectEqual(@as(usize, 1), f.ignored.len);
}

test "directive at end of file guards nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "const a = 1;\n// @ts-ignore\n");
    try testing.expect(!f.any());
}

test "ranges stay sorted and searchable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        "// @ts-ignore\n" ++
        "const a: string = 1;\n" ++
        "const b = 2;\n" ++
        "// @ts-ignore\n" ++
        "const c: string = 3;\n";
    const f = try scanTest(&arena, src);
    try testing.expectEqual(@as(usize, 2), f.ignored.len);
    try testing.expect(f.ignored[0].end <= f.ignored[1].start);
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "const a").?)));
    try testing.expect(!f.suppresses(@intCast(std.mem.indexOf(u8, src, "const b").?)));
    try testing.expect(f.suppresses(@intCast(std.mem.indexOf(u8, src, "const c").?)));
}
