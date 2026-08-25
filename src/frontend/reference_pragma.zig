//! The `/// <reference … />` triple-slash pragma — tsc's
//! `commentPragmas.reference`, read straight out of a file's leading comment
//! block.
//!
//! One grammar, two readers, so the grammar lives here rather than in either:
//!
//!   * **`link/references.zig`** wants the `path=` / `types=` directives, which
//!     pull extra files into the program.
//!   * **the parser** wants the ones that are `<reference …>` and yet name none
//!     of the arguments tsc knows — TS1084, "Invalid 'reference' directive
//!     syntax", which tsc files in `processPragmasIntoFields` and lands in the
//!     file's PARSE diagnostics (measured: it suppresses a sibling TS2322).
//!
//! Nothing here allocates: a spec slices the source it was read from, and the
//! comment walk is an iterator. Files whose first character is code leave
//! `leading` after one comparison.

const std = @import("std");

/// A `///` comment in the leading trivia, with its byte range in the source.
/// `body` is the text after the three slashes — what `read` parses.
pub const Comment = struct {
    start: u32,
    end: u32,
    body: []const u8,
};

/// What one `///` comment says, in tsc's own order of decision
/// (`processPragmasIntoFields`'s `reference` arm).
pub const Verdict = union(enum) {
    /// Not a `<reference …>` pragma at all — ordinary prose, or some other
    /// triple-slash tag. Silent either way.
    not_a_pragma,
    /// `no-default-lib="true"` or `lib=…`: understood, and names no program
    /// input ztsc has to resolve (the built-in libs are configured, not
    /// referenced).
    understood,
    /// `<reference …>` carrying none of `no-default-lib="true"`, `types`,
    /// `lib` or `path`. tsc's `else` arm: TS1084, reported over the WHOLE
    /// comment.
    invalid,
    /// A directive naming a file (`path=`) or a package (`types=`).
    directive: Directive,
};

pub const Kind = enum { path, types };

/// `spec` slices the comment body, so its byte offset in the source is a
/// pointer difference — see `link/references.zig`, which needs it to anchor
/// TS2688/TS6053 on the name.
pub const Directive = struct {
    kind: Kind,
    spec: []const u8,
};

/// Read the body of a `///` comment (the text after the three slashes).
///
/// tsc's gate is `tripleSlashXMLCommentStartRegEx = /^\/\/\/\s*<(\S+)\s/` with
/// the captured tag name lowercased and looked up in `commentPragmas` — so the
/// tag must be followed by whitespace, which is what keeps `<reference/>` and
/// `<references path="x"/>` out (neither is a pragma, and neither is TS1084).
pub fn read(body: []const u8) Verdict {
    var s = body;
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    if (s.len == 0 or s[0] != '<') return .not_a_pragma;
    const tag_start: usize = 1;
    var i: usize = tag_start;
    while (i < s.len and !isSpace(s[i])) i += 1;
    if (i >= s.len) return .not_a_pragma; // no `\s` after the tag name
    if (!std.ascii.eqlIgnoreCase(s[tag_start..i], "reference")) return .not_a_pragma;

    // tsc's decision order. `no-default-lib` is a boolean flag rather than a
    // name, and only the literal `"true"` counts.
    if (attrValue(s, "no-default-lib")) |v| {
        if (std.mem.eql(u8, v, "true")) return .understood;
    }
    if (attrValue(s, "types")) |v| return .{ .directive = .{ .kind = .types, .spec = v } };
    if (attrValue(s, "lib")) |_| return .understood;
    if (attrValue(s, "path")) |v| return .{ .directive = .{ .kind = .path, .spec = v } };
    return .invalid;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Value of a `key="…"` / `key='…'` attribute in `s`, or null. tsc's
/// `getNamedArgRegEx(name)` is `/(\s${name}\s*=\s*)(?:'([^']*)'|"([^"]*)")/im`:
/// an unterminated quote matches nothing (which is exactly how
/// `/// <reference path="missingquote.ts />` earns its TS1084), and the leading
/// `\s` is what stops `lib` from reading the tail of `no-default-lib`.
fn attrValue(s: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, key)) |at| {
        if (at == 0 or !isSpace(s[at - 1])) {
            from = at + key.len;
            continue;
        }
        var k = at + key.len;
        while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
        if (k < s.len and s[k] == '=') {
            k += 1;
            while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
            if (k < s.len and (s[k] == '"' or s[k] == '\'')) {
                const q = s[k];
                k += 1;
                const vstart = k;
                while (k < s.len and s[k] != q) k += 1;
                if (k < s.len) return s[vstart..k];
            }
        }
        from = at + key.len;
    }
    return null;
}

/// Iterator over the `///` comments of `src`'s leading trivia — tsc's
/// `getLeadingCommentRanges(sourceText, 0)`, narrowed to the single-line kind.
/// It stops at the first real token, because that is where a pragma stops
/// counting.
pub const Comments = struct {
    src: []const u8,
    i: usize = 0,

    pub fn next(c: *Comments) ?Comment {
        while (c.i < c.src.len) {
            while (c.i < c.src.len and isSpace(c.src[c.i])) c.i += 1;
            if (c.i + 1 < c.src.len and c.src[c.i] == '/' and c.src[c.i + 1] == '/') {
                const start = c.i;
                while (c.i < c.src.len and c.src[c.i] != '\n') c.i += 1;
                const line = c.src[start..c.i];
                if (line.len >= 3 and line[2] == '/') {
                    return .{
                        .start = @intCast(start),
                        .end = @intCast(c.i),
                        .body = line[3..],
                    };
                }
                continue;
            }
            if (c.i + 1 < c.src.len and c.src[c.i] == '/' and c.src[c.i + 1] == '*') {
                c.i += 2;
                while (c.i + 1 < c.src.len and !(c.src[c.i] == '*' and c.src[c.i + 1] == '/')) c.i += 1;
                c.i = if (c.i + 1 < c.src.len) c.i + 2 else c.src.len;
                continue;
            }
            break; // first real token — pragmas must precede it
        }
        return null;
    }
};

pub fn leading(src: []const u8) Comments {
    return .{ .src = src };
}

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "read: the four understood arguments, and the residue" {
    try testing.expect(read(" <reference path=\"a.ts\" />").directive.kind == .path);
    try testing.expect(read(" <reference types='node' />").directive.kind == .types);
    try testing.expectEqual(Verdict.understood, read(" <reference lib=\"es2015\" />"));
    try testing.expectEqual(Verdict.understood, read(" <reference no-default-lib=\"true\" />"));
    // An unterminated quote reads as no argument at all.
    try testing.expectEqual(Verdict.invalid, read(" <reference path=\"missing.ts />"));
    try testing.expectEqual(Verdict.invalid, read(" <reference />"));
    try testing.expectEqual(Verdict.invalid, read(" <reference blah=\"x\" />"));
    try testing.expectEqual(Verdict.invalid, read(" <reference resolution-mode=\"import\" />"));
    // Not pragmas: no tag, no whitespace after the tag, another tag entirely.
    try testing.expectEqual(Verdict.not_a_pragma, read(" just a comment"));
    try testing.expectEqual(Verdict.not_a_pragma, read(" <reference/>"));
    try testing.expectEqual(Verdict.not_a_pragma, read(" <amd-module name=\"x\" />"));
}

test "leading: triple-slash comments before the first token" {
    const src =
        \\/// <reference types="a" />
        \\// not triple slash
        \\/* block */
        \\   /// <reference path="b.ts" />
        \\const x = 1;
        \\/// <reference types="too-late" />
        \\
    ;
    var it = leading(src);
    const c0 = it.next().?;
    try testing.expectEqual(Kind.types, read(c0.body).directive.kind);
    try testing.expectEqualStrings("/// <reference types=\"a\" />", src[c0.start..c0.end]);
    const c1 = it.next().?;
    try testing.expectEqualStrings("b.ts", read(c1.body).directive.spec);
    try testing.expectEqual(@as(?Comment, null), it.next());
}
