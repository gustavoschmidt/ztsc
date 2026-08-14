//! Literal grammar checks: the rules about a numeric or string literal's TEXT
//! that the tokenizer deliberately does not enforce.
//!
//! tsc reports these from its scanner, so they are SYNTACTIC (`parseDiagnostics`
//! — measured, see `diagnostics.Class`) even though nothing about them stops the
//! token from being recognized. ztsc's scanner stays a pure tokenizer: it decides
//! token boundaries and nothing else, so the checks live here as pure functions
//! over the token's text plus its start offset, and the parser runs them as it
//! consumes the token.
//!
//! Every position below is tsc's, taken from a paired run of both compilers over
//! one snippet per rule rather than from reading tsc's source: the codes are only
//! worth carrying if they land on the same character.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const Code = diagnostics.Code;
const Span = @import("span.zig").Span;

/// One finding, already in absolute file offsets.
pub const Finding = struct {
    code: Code,
    span: Span,
};

/// The leading-zero and empty-radix rules for a numeric literal. `text` is the
/// token's exact source text and `start` its file offset.
///
/// tsc's scanner:
///   - `0` + an octal digit is a legacy octal literal — TS1121, at the literal.
///   - `0` + `8`/`9` is a decimal with a leading zero — TS1489, at the literal.
///   - `0x` / `0b` / `0o` with no digit after it is TS1125 / TS1177 / TS1178, at
///     the first character that should have been a digit.
/// At most one applies, so this returns an optional rather than a list.
pub fn checkNumeric(text: []const u8, start: u32) ?Finding {
    // `0` is the only prefix any of these rules cares about, and a numeric
    // literal that does not start with one is the overwhelming majority.
    if (text.len < 2 or text[0] != '0') return null;
    const radix: ?Code = switch (text[1]) {
        'x', 'X' => .hex_digit_expected,
        'b', 'B' => .binary_digit_expected,
        'o', 'O' => .octal_digit_expected,
        else => null,
    };
    if (radix) |code| {
        // `0x` alone, or `0xn` (the BigInt suffix is not a digit).
        const digits = text[2..];
        const empty = digits.len == 0 or (digits.len == 1 and (digits[0] == 'n' or digits[0] == 'N'));
        if (!empty) return null;
        return .{ .code = code, .span = .{ .start = start + 2, .end = start + 3 } };
    }
    // A leading zero followed by a digit. Which of the two rules applies is
    // decided by the FIRST digit only: tsc scans `0` + octal digits as a legacy
    // octal literal and stops at the first 8 or 9, and reaches the
    // leading-zero rule only when the very first digit is already out of range.
    switch (text[1]) {
        '0'...'7' => return .{
            .code = .octal_literal_not_allowed,
            .span = .{ .start = start, .end = start + @as(u32, @intCast(text.len)) },
        },
        '8', '9' => return .{
            .code = .decimal_with_leading_zero,
            .span = .{ .start = start, .end = start + @as(u32, @intCast(text.len)) },
        },
        else => return null,
    }
}

/// Walks a string literal's escape sequences, yielding tsc's scanner errors.
///
/// Only the escapes tsc validates are checked — a `\p` or `\n` is a perfectly
/// legal (if unremarkable) escape and never reported. Deliberately NOT applied
/// to template literals: tsc allows every one of these inside a TAGGED template
/// (the raw text is handed to the tag function), and a scan of the token cannot
/// see the tag, so validating templates here would invent diagnostics on valid
/// code. Nor to JSX attribute strings, where `\` is a literal byte.
pub const EscapeWalk = struct {
    text: []const u8,
    base: u32,
    i: usize = 0,

    /// `text` is the token's exact source text (quotes included) and `base` its
    /// file offset.
    pub fn init(text: []const u8, base: u32) EscapeWalk {
        return .{ .text = text, .base = base };
    }

    /// True when the token cannot contain an escape at all — the guard that
    /// keeps this off the hot path for the ~all string literals that have none.
    pub fn any(text: []const u8) bool {
        return std.mem.indexOfScalar(u8, text, '\\') != null;
    }

    pub fn next(w: *EscapeWalk) ?Finding {
        while (w.i < w.text.len) {
            if (w.text[w.i] != '\\') {
                w.i += 1;
                continue;
            }
            const esc = w.i; // the backslash
            w.i += 1;
            if (w.i >= w.text.len) return null;
            const c = w.text[w.i];
            w.i += 1;
            switch (c) {
                // `\0` is the NUL escape and legal on its own; `\0` followed by
                // a digit is a legacy octal escape, as `\1`..`\7` always are.
                '0' => {
                    if (w.i < w.text.len and isDigit(w.text[w.i])) {
                        w.skipOctal();
                        return w.at(.octal_escape_not_allowed, esc);
                    }
                },
                '1'...'7' => {
                    w.skipOctal();
                    return w.at(.octal_escape_not_allowed, esc);
                },
                // `\8` and `\9` are not escapes at all in any mode.
                '8', '9' => return w.at(.escape_sequence_not_allowed, esc),
                // `\xHH` — exactly two hex digits, and tsc blames the first
                // character that is not one, not the backslash.
                'x' => if (w.needHex(2)) |f| return f,
                'u' => {
                    if (w.i < w.text.len and w.text[w.i] == '{') {
                        if (w.extendedUnicode()) |f| return f;
                    } else if (w.needHex(4)) |f| return f;
                },
                else => {},
            }
        }
        return null;
    }

    fn at(w: *const EscapeWalk, code: Code, from: usize) Finding {
        return .{ .code = code, .span = .{
            .start = w.base + @as(u32, @intCast(from)),
            .end = w.base + @as(u32, @intCast(w.i)),
        } };
    }

    fn one(w: *const EscapeWalk, code: Code, at_i: usize) Finding {
        const s = w.base + @as(u32, @intCast(at_i));
        return .{ .code = code, .span = .{ .start = s, .end = s + 1 } };
    }

    /// A legacy octal escape is up to three octal digits (`\101`); the first was
    /// already consumed.
    fn skipOctal(w: *EscapeWalk) void {
        var n: usize = 1;
        while (n < 3 and w.i < w.text.len and w.text[w.i] >= '0' and w.text[w.i] <= '7') : (n += 1) {
            w.i += 1;
        }
    }

    /// Consume exactly `n` hex digits, or report TS1125 at the first character
    /// that is not one (tsc: `error(Hexadecimal_digit_expected, pos, 1)`).
    fn needHex(w: *EscapeWalk, n: usize) ?Finding {
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (w.i >= w.text.len or !isHex(w.text[w.i])) {
                return w.one(.hex_digit_expected, w.i);
            }
            w.i += 1;
        }
        return null;
    }

    /// `\u{H+}`. The `{` is at `w.i`.
    fn extendedUnicode(w: *EscapeWalk) ?Finding {
        w.i += 1; // '{'
        const digits_at = w.i;
        var value: u32 = 0;
        var over = false;
        while (w.i < w.text.len and isHex(w.text[w.i])) : (w.i += 1) {
            value = value *% 16 +% hexValue(w.text[w.i]);
            if (value > 0x10FFFF) over = true;
        }
        if (w.i == digits_at) return w.one(.hex_digit_expected, w.i);
        if (over) {
            return .{ .code = .unicode_escape_out_of_range, .span = .{
                .start = w.base + @as(u32, @intCast(digits_at)),
                .end = w.base + @as(u32, @intCast(w.i)),
            } };
        }
        if (w.i >= w.text.len or w.text[w.i] != '}') {
            return w.one(.unterminated_unicode_escape, w.i);
        }
        w.i += 1; // '}'
        return null;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDigit(c) or ((c | 0x20) >= 'a' and (c | 0x20) <= 'f');
}

fn hexValue(c: u8) u32 {
    if (isDigit(c)) return c - '0';
    return (c | 0x20) - 'a' + 10;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNumeric(text: []const u8, code: ?Code, start_off: u32) !void {
    const got = checkNumeric(text, 100);
    if (code) |want| {
        try testing.expect(got != null);
        try testing.expectEqual(want, got.?.code);
        try testing.expectEqual(@as(u32, 100 + start_off), got.?.span.start);
    } else {
        try testing.expect(got == null);
    }
}

test "numeric: legacy octal and leading zeros" {
    try expectNumeric("010", .octal_literal_not_allowed, 0);
    try expectNumeric("00", .octal_literal_not_allowed, 0);
    try expectNumeric("0777", .octal_literal_not_allowed, 0);
    try expectNumeric("08", .decimal_with_leading_zero, 0);
    try expectNumeric("0900", .decimal_with_leading_zero, 0);
    // Clean forms: a bare zero, a fraction, an exponent, a BigInt, and every
    // prefixed radix with at least one digit.
    try expectNumeric("0", null, 0);
    try expectNumeric("0.5", null, 0);
    try expectNumeric("0e1", null, 0);
    try expectNumeric("0n", null, 0);
    try expectNumeric("0x1F", null, 0);
    try expectNumeric("0o17", null, 0);
    try expectNumeric("0b101", null, 0);
    try expectNumeric("42", null, 0);
    try expectNumeric("1.5e-3", null, 0);
}

test "numeric: a radix prefix with no digits blames the character after it" {
    try expectNumeric("0x", .hex_digit_expected, 2);
    try expectNumeric("0X", .hex_digit_expected, 2);
    try expectNumeric("0b", .binary_digit_expected, 2);
    try expectNumeric("0o", .octal_digit_expected, 2);
    // The BigInt suffix is not a digit.
    try expectNumeric("0xn", .hex_digit_expected, 2);
}

fn collect(text: []const u8, buf: []Finding) []Finding {
    var w: EscapeWalk = .init(text, 100);
    var n: usize = 0;
    while (w.next()) |f| : (n += 1) {
        if (n == buf.len) break;
        buf[n] = f;
    }
    return buf[0..n];
}

test "escapes: octal, \\8 and \\9" {
    var buf: [8]Finding = undefined;
    // `"\101"`: the backslash is at index 1 of the token.
    {
        const got = collect("\"\\101\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.octal_escape_not_allowed, got[0].code);
        try testing.expectEqual(@as(u32, 101), got[0].span.start);
    }
    // `"\0"` alone is the NUL escape; `"\08"` is a legacy octal one.
    try testing.expectEqual(@as(usize, 0), collect("\"\\0\"", &buf).len);
    try testing.expectEqual(@as(usize, 1), collect("\"\\08\"", &buf).len);
    {
        const got = collect("\"\\8\\9\"", &buf);
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqual(Code.escape_sequence_not_allowed, got[0].code);
        try testing.expectEqual(Code.escape_sequence_not_allowed, got[1].code);
    }
    // Ordinary and unrecognized escapes are never reported.
    try testing.expectEqual(@as(usize, 0), collect("\"a\\nb\\tc\\\\d\\pe\\\"f\"", &buf).len);
}

test "escapes: hex and unicode digit counts" {
    var buf: [8]Finding = undefined;
    // `"\x1"`: two hex digits required, the closing quote is blamed (index 4).
    {
        const got = collect("\"\\x1\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.hex_digit_expected, got[0].code);
        try testing.expectEqual(@as(u32, 104), got[0].span.start);
    }
    // `"\u12"`: four required, index 5 blamed.
    {
        const got = collect("\"\\u12\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.hex_digit_expected, got[0].code);
        try testing.expectEqual(@as(u32, 105), got[0].span.start);
    }
    try testing.expectEqual(@as(usize, 0), collect("\"\\x41\\u0041\"", &buf).len);
}

test "escapes: extended unicode range and termination" {
    var buf: [8]Finding = undefined;
    // `"\u{110000}"`: reported at the first digit (index 4).
    {
        const got = collect("\"\\u{110000}\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.unicode_escape_out_of_range, got[0].code);
        try testing.expectEqual(@as(u32, 104), got[0].span.start);
    }
    try testing.expectEqual(@as(usize, 0), collect("\"\\u{10FFFF}\\u{0}\"", &buf).len);
    {
        const got = collect("\"\\u{12\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.unterminated_unicode_escape, got[0].code);
    }
    {
        const got = collect("\"\\u{}\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.hex_digit_expected, got[0].code);
    }
    // A very long run of digits must not wrap the accumulator into range.
    {
        const got = collect("\"\\u{FFFFFFFFFFFF}\"", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.unicode_escape_out_of_range, got[0].code);
    }
}

test "escapes: the cheap guard agrees with the walk" {
    var buf: [8]Finding = undefined;
    try testing.expect(!EscapeWalk.any("\"plain\""));
    try testing.expect(EscapeWalk.any("\"\\101\""));
    // A trailing lone backslash terminates instead of running off the end.
    try testing.expectEqual(@as(usize, 0), collect("\"abc\\", &buf).len);
}
