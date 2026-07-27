//! Comment directives. Currently the `@ts-nocheck` / `@ts-check` file pragmas.
//!
//! `// @ts-nocheck` is a *pragma*, so — mirroring tsc — it only counts in the
//! leading comment block (before the first token) and only in a `//` comment.
//! Whitespace and other comments may precede it, and arbitrary prose may follow
//! it on the same line. It suppresses every *semantic* diagnostic in the file
//! (bind + link + check) while leaving syntax errors alone, which is exactly
//! the set tsc drops for a `@ts-nocheck` file. `// @ts-check` is the inverse;
//! the last of the two in the leading block wins.
//!
//! Scanning is gated on the file containing the byte sequence `@ts-` at all
//! (one vectorised `@` sweep), so files without directives — effectively all
//! of them — pay a single memchr pass and allocate nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// The directive state of one file, sealed into the per-file arena.
pub const File = struct {
    /// `@ts-nocheck` won in the leading comment block: every semantic
    /// diagnostic in this file is suppressed.
    nocheck: bool = false,

    pub const none: File = .{};

    /// True if this file carries any directive at all (fast path guard).
    pub fn any(f: File) bool {
        return f.nocheck;
    }

    /// True if a *semantic* diagnostic starting at byte offset `pos` is
    /// suppressed. Syntax diagnostics must not be routed through here.
    pub fn suppresses(f: File, pos: u32) bool {
        _ = pos;
        return f.nocheck;
    }
};

/// Scan `src` for comment directives. Output lives in `alloc` (a per-file
/// arena); nothing is freed individually.
pub fn scan(alloc: Allocator, src: []const u8) Error!File {
    _ = alloc;
    if (!mayHaveDirective(src)) return .none;

    // The last `@ts-nocheck`/`@ts-check` in the leading block wins (tsc's
    // `checkJsDirective` keeps whichever has the greater position).
    var nocheck = false;
    var it: CommentIter = .{ .src = src };
    while (it.next()) |c| {
        // File pragmas: leading `//` comments only, before the first token.
        if (!c.leading) break;
        if (!c.line) continue;
        if (pragmaKind(src[c.start..c.end])) |on| nocheck = !on;
    }
    return .{ .nocheck = nocheck };
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
/// `"// @ts-nocheck"` inside a string is not mistaken for one. Regular
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

/// Strip `//` or `///` plus following whitespace. Null when `text` is not a
/// line comment.
fn stripLinePrefix(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "//")) return null;
    var s = text[2..];
    if (s.len > 0 and s[0] == '/') s = s[1..];
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

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

/// Scan into a caller-owned arena: a `File`'s payload lives in `alloc`, so
/// tests hand it an arena rather than freeing by hand.
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

test "@ts-nocheck inside a string literal is not a pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanTest(&arena, "const s = \"// @ts-nocheck\";\nconst x: string = 1;\n");
    try testing.expect(!f.nocheck);
}
