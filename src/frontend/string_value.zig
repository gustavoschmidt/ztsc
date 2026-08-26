//! The VALUE a quoted literal spells — escapes decoded — and how to spell that
//! value back out again.
//!
//! A string literal's *text* and its *value* are different things, and every
//! place a literal names something is about the value: `{'te\<newline>xt': 1}`
//! declares the member `text`, `{"\x41": 1}` declares `A`, and the type
//! `"A"` IS the type `"A"`. ztsc used to key those off the raw source
//! slice, so an escaped name was a different name from the one it spells and
//! `o.text` came back TS2339.
//!
//! Two halves, inverse to each other and kept in one file so they cannot drift:
//!
//!   * `cook` — tsc's `scanEscapeSequence`, run over the body between the
//!     quotes. `needsCook` is the screen in front of it: a body with no `\`
//!     (the overwhelmingly common case) is its own value, so the caller keeps
//!     the zero-copy source slice and nothing is allocated.
//!   * `writeEscaped` / `needsEscape` — tsc's `escapeString` with `"` as the
//!     quote character, which is how a cooked value is printed back in a
//!     diagnostic. `needsEscape` is the matching screen: a value with nothing
//!     to escape prints as itself.
//!
//! Both are pure functions over bytes, with no allocator and no context.

const std = @import("std");

/// Which quoted-literal grammar the body came from. A no-substitution template
/// decodes the same escapes as a string literal but additionally normalizes
/// its RAW line endings — tsc's `scanTemplateAndSetTokenValue` turns `<CR><LF>`
/// and a lone `<CR>` into `<LF>` before the value is used.
pub const Kind = enum { string, template };

/// Does this body (the text BETWEEN the quotes) differ from its value at all?
/// False is the fast path every caller wants: the body is the value, verbatim.
pub fn needsCook(body: []const u8, kind: Kind) bool {
    if (std.mem.indexOfScalar(u8, body, '\\') != null) return true;
    return kind == .template and std.mem.indexOfScalar(u8, body, '\r') != null;
}

/// Decode `body` into `buf`, returning the value it spells. Null when the
/// value cannot be produced — `buf` is too small, or an escape names a LONE
/// surrogate, which has no UTF-8 form (`unescapeIdentifier` bails the same way
/// and for the same reason). The caller then falls back to the raw body, which
/// is exactly the behavior that predates cooking.
///
/// A decoded value is never longer than its body — every escape is at least
/// two source bytes and yields at most four output bytes, and the longest
/// output (a 4-byte astral character) needs at least `\u{10000}`, ten — so
/// `buf.len >= body.len` always suffices.
///
/// Malformed escapes are NOT diagnosed here: the parser has already reported
/// them (`\8`, an octal escape, a truncated `\x`), and tsc still gives the
/// literal a value. An escape whose digits are missing degrades to the
/// character it introduced, which is tsc's own fallback.
pub fn cook(body: []const u8, kind: Kind, buf: []u8) ?[]const u8 {
    if (buf.len < body.len) return null;
    var out: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\r' and kind == .template) {
            // Raw line-ending normalization, template only.
            buf[out] = '\n';
            out += 1;
            i += if (i + 1 < body.len and body[i + 1] == '\n') 2 else 1;
            continue;
        }
        if (c != '\\') {
            buf[out] = c;
            out += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) break; // trailing `\` of an unterminated literal
        const e = body[i];
        i += 1;
        switch (e) {
            'b' => buf[out] = 0x08,
            't' => buf[out] = 0x09,
            'n' => buf[out] = 0x0A,
            'v' => buf[out] = 0x0B,
            'f' => buf[out] = 0x0C,
            'r' => buf[out] = 0x0D,
            '\n' => continue, // line continuation
            '\r' => {
                if (i < body.len and body[i] == '\n') i += 1;
                continue;
            },
            '0'...'7' => {
                // `\0` alone is NUL; anything else in this range is a legacy
                // octal escape (TS1487, already reported), and tsc still
                // evaluates it: up to three digits, `\0`-`\3` for a third one.
                var v: u32 = e - '0';
                var digits: u32 = 1;
                const max: u32 = if (e <= '3') 3 else 2;
                while (digits < max and i < body.len and body[i] >= '0' and body[i] <= '7') : (digits += 1) {
                    v = v * 8 + (body[i] - '0');
                    i += 1;
                }
                out += encode(v, buf[out..]) orelse return null;
                continue;
            },
            'x' => {
                // A MALFORMED `\x` / `\u` (missing or non-hex digits) is
                // already TS1125 from the parser and has no value tsc and
                // ztsc would agree on: leave the whole literal raw.
                if (i + 2 > body.len) return null;
                const hi = hexValue(body[i]) orelse return null;
                const lo = hexValue(body[i + 1]) orelse return null;
                i += 2;
                out += encode(hi * 16 + lo, buf[out..]) orelse return null;
                continue;
            },
            'u' => {
                var cp = scanUnicodeEscape(body, &i) orelse return null;
                if (cp >= 0xD800 and cp <= 0xDBFF) {
                    // A surrogate PAIR spells one astral character; the two
                    // halves arrive as two escapes (`😀`).
                    var j = i;
                    if (j + 1 < body.len and body[j] == '\\' and body[j + 1] == 'u') {
                        j += 2;
                        var k = j;
                        if (scanUnicodeEscape(body, &k)) |lo| {
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                i = k;
                            }
                        }
                    }
                }
                // A LONE surrogate has no UTF-8 form: leave the whole literal
                // raw rather than inventing bytes for it.
                if (cp >= 0xD800 and cp <= 0xDFFF) return null;
                out += encode(cp, buf[out..]) orelse return null;
                continue;
            },
            // U+2028 / U+2029 after a `\` are line continuations too; every
            // other character stands for itself (`\q` is `q`, `\'` is `'`).
            0xE2 => {
                if (i + 1 < body.len and body[i] == 0x80 and (body[i + 1] == 0xA8 or body[i + 1] == 0xA9)) {
                    i += 2;
                    continue;
                }
                buf[out] = e;
            },
            else => buf[out] = e,
        }
        out += 1;
    }
    return buf[0..out];
}

/// At the digits of a `\u` escape (`i` points just past the `u`): consume
/// `XXXX` or `{H+}` and return the code point, leaving `i` past the escape.
/// Null — with `i` untouched — when the escape is malformed or names a code
/// point outside Unicode.
fn scanUnicodeEscape(body: []const u8, i: *usize) ?u32 {
    var j = i.*;
    var cp: u32 = 0;
    if (j < body.len and body[j] == '{') {
        j += 1;
        var digits: u32 = 0;
        while (j < body.len) : (j += 1) {
            const h = hexValue(body[j]) orelse break;
            cp = cp *% 16 +% h;
            digits += 1;
        }
        if (digits == 0 or j >= body.len or body[j] != '}') return null;
        j += 1;
        if (cp > 0x10FFFF) return null;
    } else {
        if (j + 4 > body.len) return null;
        for (body[j .. j + 4]) |h| {
            cp = cp * 16 + (hexValue(h) orelse return null);
        }
        j += 4;
    }
    i.* = j;
    return cp;
}

/// UTF-8 encode one code point, or null when it has no encoding (a surrogate)
/// or `buf` cannot hold it.
fn encode(cp: u32, buf: []u8) ?usize {
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
    return std.unicode.utf8Encode(@intCast(cp), buf) catch null;
}

fn hexValue(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    const l = c | 0x20;
    if (l >= 'a' and l <= 'f') return l - 'a' + 10;
    return null;
}

/// Does this value carry a character a diagnostic cannot print BARE — one that
/// only survives inside quotes, escaped? False is the fast path: the value
/// prints as itself. This is the screen in front of `writeEscaped`, and the
/// trigger for quoting a member NAME (see `print.writeMemberName`).
///
/// A lone `'` is not one of them: `quoteFor` would wrap the name in `"` and
/// print it verbatim, so quoting would change nothing but the quotes.
pub fn needsEscape(value: []const u8) bool {
    for (value, 0..) |c, i| {
        if (c < 0x20 or c == '"' or c == '\\') return true;
        // U+0085, U+2028, U+2029 — the three non-ASCII characters tsc escapes.
        if (c == 0xC2 and i + 1 < value.len and value[i + 1] == 0x85) return true;
        if (c == 0xE2 and i + 2 < value.len and value[i + 1] == 0x80 and
            (value[i + 2] == 0xA8 or value[i + 2] == 0xA9)) return true;
    }
    return false;
}

/// The quote character tsc wraps `value` in: `"`, unless the value itself
/// contains one and `'` would spare an escape. Type-literal VALUES are always
/// double-quoted (tsc's printer renders `"q's"` and `"a\"b"` alike); only a
/// synthesized member NAME picks — `factory.createStringLiteral(name,
/// /*isSingleQuote*/ name.includes('"'))`.
pub fn quoteFor(value: []const u8) u8 {
    return if (std.mem.indexOfScalar(u8, value, '"') != null) '\'' else '"';
}

/// Write `value` the way tsc's `escapeString` does — the body of the literal a
/// diagnostic prints, WITHOUT the surrounding quotes. `quote` is the character
/// it will be wrapped in, and the only quote character escaped.
///
/// Verified against the oracle rather than read off its source: the named
/// escapes come back as themselves (`\t`, `\n`, `\r`, `\v`, `\b`, `\f`), NUL
/// as `\0`, every other C0 control as `\uXXXX` with UPPERCASE hex digits, and
/// U+0085 / U+2028 / U+2029 likewise; DEL (0x7F) and every astral character
/// print raw.
pub fn writeEscaped(w: *std.Io.Writer, value: []const u8, quote: u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    var run: usize = 0; // start of the pending verbatim run
    while (i < value.len) {
        const c = value[i];
        var esc: []const u8 = "";
        var width: usize = 1;
        var hex: ?u32 = null;
        switch (c) {
            '"', '\'' => if (c == quote) {
                esc = if (c == '"') "\\\"" else "\\'";
            },
            '\\' => esc = "\\\\",
            0x08 => esc = "\\b",
            0x09 => esc = "\\t",
            0x0A => esc = "\\n",
            0x0B => esc = "\\v",
            0x0C => esc = "\\f",
            0x0D => esc = "\\r",
            // tsc writes `\0` unless a DIGIT follows, which would re-read as a
            // longer octal escape; then it writes `\x00`.
            0x00 => esc = if (i + 1 < value.len and value[i + 1] >= '0' and value[i + 1] <= '9') "\\x00" else "\\0",
            0xC2 => {
                if (i + 1 < value.len and value[i + 1] == 0x85) {
                    hex = 0x85;
                    width = 2;
                }
            },
            0xE2 => {
                if (i + 2 < value.len and value[i + 1] == 0x80 and
                    (value[i + 2] == 0xA8 or value[i + 2] == 0xA9))
                {
                    hex = if (value[i + 2] == 0xA8) 0x2028 else 0x2029;
                    width = 3;
                }
            },
            else => if (c < 0x20) {
                hex = c;
            },
        }
        if (esc.len == 0 and hex == null) {
            i += 1;
            continue;
        }
        if (run < i) try w.writeAll(value[run..i]);
        if (hex) |h| try w.print("\\u{X:0>4}", .{h}) else try w.writeAll(esc);
        i += width;
        run = i;
    }
    if (run < value.len) try w.writeAll(value[run..]);
}

const testing = std.testing;

fn cooked(body: []const u8, kind: Kind) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    if (!needsCook(body, kind)) return body;
    return cook(body, kind, &S.buf) orelse body;
}

test "escapes decode to the value they spell" {
    try testing.expectEqualStrings("A", cooked("\\x41", .string));
    try testing.expectEqualStrings("A", cooked("\\u0041", .string));
    try testing.expectEqualStrings("A", cooked("\\u{41}", .string));
    try testing.expectEqualStrings("text", cooked("te\\\r\nxt", .string));
    try testing.expectEqualStrings("text", cooked("te\\\nxt", .string));
    try testing.expectEqualStrings("a\nb", cooked("a\\nb", .string));
    try testing.expectEqualStrings("a\tb", cooked("a\\tb", .string));
    try testing.expectEqualStrings("q'\"\\", cooked("\\q\\'\\\"\\\\", .string));
    try testing.expectEqualStrings("\x00z", cooked("\\0z", .string));
    try testing.expectEqualStrings("Az", cooked("\\101z", .string));
    try testing.expectEqualStrings("\u{1F600}", cooked("\\u{1F600}", .string));
    try testing.expectEqualStrings("\u{1F600}", cooked("\\uD83D\\uDE00", .string));
    // A lone surrogate has no UTF-8 form: the body stays raw.
    try testing.expectEqualStrings("\\uD800", cooked("\\uD800", .string));
    // Templates normalize raw line endings; strings have none to normalize.
    try testing.expectEqualStrings("a\nb", cooked("a\r\nb", .template));
    try testing.expectEqualStrings("a\nb", cooked("a\rb", .template));
    try testing.expectEqualStrings("B", cooked("\\x42", .template));
    // No escape at all: the body is its own value, byte-identical.
    try testing.expect(!needsCook("plain", .string));
    try testing.expect(!needsCook("a\r\nb", .string));
}

fn escaped(value: []const u8, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeEscaped(&w, value, '"') catch unreachable;
    return w.buffered();
}

test "values print back the way tsc escapes them" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("plain", escaped("plain", &buf));
    try testing.expectEqualStrings("a\\nb", escaped("a\nb", &buf));
    try testing.expectEqualStrings("t\\tv\\vb\\bf\\fr\\r", escaped("t\tv\x0Bb\x08f\x0Cr\r", &buf));
    try testing.expectEqualStrings("\\\"q'\\\\", escaped("\"q'\\", &buf));
    try testing.expectEqualStrings("\\0z", escaped("\x00z", &buf));
    try testing.expectEqualStrings("\\x000", escaped("\x000", &buf));
    try testing.expectEqualStrings("\\u0001\\u001F", escaped("\x01\x1F", &buf));
    try testing.expectEqualStrings("\x7F", escaped("\x7F", &buf));
    try testing.expectEqualStrings("\\u0085\\u2028\\u2029", escaped("\u{85}\u{2028}\u{2029}", &buf));
    try testing.expectEqualStrings("\u{1F600}", escaped("\u{1F600}", &buf));
    try testing.expect(!needsEscape("plain"));
    try testing.expect(needsEscape("a\nb"));
    try testing.expect(needsEscape("\u{2028}"));
    // The quote character is the one that spares an escape.
    try testing.expectEqual(@as(u8, '"'), quoteFor("d'e"));
    try testing.expectEqual(@as(u8, '\''), quoteFor("f\"g"));
    try testing.expect(!needsEscape("d'e"));
    var w = std.Io.Writer.fixed(&buf);
    try writeEscaped(&w, "f\"g'h", '\'');
    try testing.expectEqualStrings("f\"g\\'h", w.buffered());
}

test "cooking round-trips through escaping for the named escapes" {
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ "a\\nb", "a\\tb", "x\\\\y", "x\\\"y" }) |body| {
        try testing.expectEqualStrings(body, escaped(cooked(body, .string), &buf));
    }
}
