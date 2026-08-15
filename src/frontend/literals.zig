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
// One predicate only: which non-ASCII byte sequences are WHITESPACE rather than
// identifier constituents. It is the scanner's, so the two cannot disagree about
// where a token ends.
const scanner = @import("scanner.zig");
// The canonical spelling of a numeric name, shared with the member-atom path so
// `isNumericName` and the atom a numeric name interns to cannot disagree.
const numeric_lit = @import("../numeric_lit.zig");

/// One finding, already in absolute file offsets.
pub const Finding = struct {
    code: Code,
    span: Span,
};

/// The leading-zero, empty-radix and empty-exponent rules for a numeric
/// literal. `text` is the token's exact source text and `start` its file offset.
///
/// tsc's scanner:
///   - `0` + an octal digit is a legacy octal literal — TS1121, at the literal.
///   - `0` + `8`/`9` is a decimal with a leading zero — TS1489, at the literal.
///   - `0x` / `0b` / `0o` with no digit after it is TS1125 / TS1177 / TS1178, at
///     the first character that should have been a digit.
///   - an `e`/`E` (with optional sign) and no digit after it is TS1124, at the
///     same place.
/// At most one applies, so this returns an optional rather than a list.
pub fn checkNumeric(text: []const u8, start: u32) ?Finding {
    if (text.len < 2) return null;
    // `0` is the only prefix the first three rules care about, and a numeric
    // literal that does not start with one is the overwhelming majority.
    if (text[0] == '0') {
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
            // No prefixed radix has an exponent form, so this is the only rule
            // that can apply to one — and `0xe` ends in an `e` that IS a digit.
            if (!empty) return null;
            return .{ .code = code, .span = .{ .start = start + 2, .end = start + 3 } };
        }
        // A leading zero followed by a digit. Which of the two rules applies is
        // decided by the FIRST digit only: tsc scans `0` + octal digits as a
        // legacy octal literal and stops at the first 8 or 9, and reaches the
        // leading-zero rule only when the very first digit is already out of
        // range.
        switch (text[1]) {
            '0'...'7' => return .{
                .code = .octal_literal_not_allowed,
                .span = .{ .start = start, .end = start + @as(u32, @intCast(text.len)) },
            },
            '8', '9' => return .{
                .code = .decimal_with_leading_zero,
                .span = .{ .start = start, .end = start + @as(u32, @intCast(text.len)) },
            },
            // `0e`, `0.5e` — fall through to the exponent rule.
            else => {},
        }
    }
    if (danglingExponentAt(text)) |off| {
        const at = start + off;
        return .{ .code = .digit_expected, .span = .{ .start = at, .end = at + 1 } };
    }
    return null;
}

/// Where an exponent digit should have been (`1e` → 2, `1e-` → 3), or null when
/// the exponent is well-formed or absent. The scanner consumes the marker and
/// its sign and then stops, folding a lone BigInt suffix in after that, so a
/// dangling exponent always sits at the end of the token modulo that `n` — a
/// test on the last byte or three, which for every well-formed literal is a
/// digit (or `n`, or the `.` of `1.`).
fn danglingExponentAt(text: []const u8) ?u32 {
    var i = text.len;
    if (text[i - 1] == 'n') {
        if (i < 2) return null;
        i -= 1;
    }
    const at = i;
    if (text[i - 1] == '+' or text[i - 1] == '-') {
        if (i < 2) return null;
        i -= 1;
    }
    if ((text[i - 1] | 0x20) != 'e') return null;
    return @intCast(at);
}

/// TS1352/TS1353: a BigInt suffix on a literal that cannot carry one. Only ever
/// asked of a token the scanner tagged NUMERIC — a well-formed BigInt is
/// `.bigint_literal` and never reaches here — so a trailing `n` is always this
/// error, and tsc words it by why: exponential notation, or simply not an
/// integer. tsc blames the literal together with its suffix.
pub fn bigintSuffixMisuse(lit: []const u8, lit_start: u32) ?Finding {
    if (lit.len < 2 or lit[lit.len - 1] != 'n') return null;
    return .{
        .code = if (isScientific(lit)) .bigint_exponential else .bigint_not_integer,
        .span = .{ .start = lit_start, .end = lit_start + @as(u32, @intCast(lit.len)) },
    };
}

/// The text between a quoted literal's quotes — a string literal, or a
/// no-substitution template. Tolerant of an UNTERMINATED literal (the scanner
/// still produced a token, and the parser has already reported it), and escapes
/// are left exactly as written: every caller keys or matches a NAME, and a name
/// spelled with an escape is a name spelled with an escape.
pub fn stripQuotes(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const q = text[0];
    if (q != '"' and q != '\'' and q != '`') return text;
    if (text.len >= 2 and text[text.len - 1] == q) return text[1 .. text.len - 1];
    return text[1..];
}

/// tsc's `isNumericLiteralName`: is this property NAME a number's canonical
/// spelling — `(+name).toString() === name`? The question a rule about numeric
/// names has to ask about a name that arrived as a STRING (`"3"`), where the
/// token tag says nothing: `"3"`, `"1.5"` and `"-1"` are numeric names, while
/// `"0x10"`, `"1e3"`, `"-0"` and `"bar"` are not — their values spell themselves
/// differently.
///
/// The NON-FINITE names are excluded, which is a deliberate divergence from
/// JavaScript and a match for the oracle: `String(+"Infinity")` is `"Infinity"`,
/// so tsc's own predicate accepts it, but tsgo — where the spelling comes from
/// Go's `-Inf`/`NaN` — rejects `"Infinity"` and `"-Infinity"`, and answers no
/// TS2452 for either (`enumWithNegativeInfinityProperty.ts` exists to say so).
/// `"NaN"` is rejected with them: tsgo answers no TS2452 there either.
///
/// The canonical spelling comes from `numeric_lit`, so this predicate cannot
/// disagree with the member atom a numeric name is keyed by.
pub fn isNumericName(text: []const u8) bool {
    if (text.len == 0 or text.len > numeric_lit.max_name) return false;
    const v = numeric_lit.value(text);
    if (std.math.isNan(v) or std.math.isInf(v)) return false;
    var buf: [numeric_lit.max_name]u8 = undefined;
    return std.mem.eql(u8, numeric_lit.name(&buf, text), text);
}

test "numeric property names are the ones that spell themselves" {
    const t = std.testing;
    for ([_][]const u8{ "0", "3", "1.5", "-1", "1000" }) |s| {
        try t.expect(isNumericName(s));
    }
    for ([_][]const u8{ "", "bar", "0x10", "1e3", "1_000", "0.0", " 1", "3n", "-0", "NaN", "Infinity", "-Infinity" }) |s| {
        try t.expect(!isNumericName(s));
    }
}

/// TS1351, tsc's `checkForIdentifierStartAfterNumericLiteral`: an identifier or
/// keyword directly abutting a numeric literal (`3a`, `123abc`, `3in[x]`). No
/// valid program has one, so an identifier-start byte just past the literal is
/// always an error; the span covers the whole identifier run, and tsc then
/// rescans that run as its own token, which is what ztsc's scanner already does.
///
/// A LONE `n` never reaches here: the scanner folds a BigInt suffix into the
/// token even where the literal cannot carry one, and `bigintSuffixMisuse`
/// answers that case with TS1352/TS1353. A longer run starting with `n`
/// (`1.5nfoo`) is an ordinary abutting identifier and does.
pub fn identifierAfterNumeric(src: []const u8, at: u32) ?Finding {
    if (at >= src.len) return null;
    const c = src[at];
    if (!(isIdentStart(c) or c >= 0x80)) return null;
    // A non-ASCII byte is an identifier constituent unless it spells WHITESPACE:
    // `1<NBSP>;` is `1` followed by trivia, and tsc — which asks
    // `isIdentifierStart` of the decoded character — reports nothing.
    if (c >= 0x80 and scanner.unicodeTrivia(src, at) != null) return null;
    var end: u32 = at;
    while (end < src.len and (isIdentPart(src[end]) or
        (src[end] >= 0x80 and scanner.unicodeTrivia(src, end) == null))) end += 1;
    return .{ .code = .identifier_after_numeric_literal, .span = .{ .start = at, .end = end } };
}

/// True when a decimal literal carries an exponent marker. Only ever asked of a
/// literal the scanner already refused a BigInt suffix, so a prefixed radix
/// (whose `e` would be a hex digit) cannot reach it — but the `0x` screen is
/// kept so the predicate is right on its own terms.
fn isScientific(lit: []const u8) bool {
    if (lit.len > 1 and lit[0] == '0' and (lit[1] | 0x20) == 'x') return false;
    for (lit) |ch| {
        if ((ch | 0x20) == 'e') return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return ((c | 0x20) >= 'a' and (c | 0x20) <= 'z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
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

test "numeric: an exponent with no digits blames the character after it" {
    // The scanner consumes the marker and the sign, so the blamed position is
    // one past the token — tsgo answers column 3 for `1e` and 4 for `1e+`.
    try expectNumeric("1e", .digit_expected, 2);
    try expectNumeric("1E", .digit_expected, 2);
    try expectNumeric("1e+", .digit_expected, 3);
    try expectNumeric("1e-", .digit_expected, 3);
    try expectNumeric("123e", .digit_expected, 4);
    try expectNumeric("0e", .digit_expected, 2);
    try expectNumeric("0.5e", .digit_expected, 4);
    try expectNumeric(".5e", .digit_expected, 3);
    // Well-formed exponents, and the `e` that is a HEX DIGIT rather than a
    // marker.
    try expectNumeric("1e9", null, 0);
    try expectNumeric("1e+9", null, 0);
    try expectNumeric("0xe", null, 0);
    try expectNumeric("0xE", null, 0);
    try expectNumeric("0x1e", null, 0);
    try expectNumeric("1.", null, 0);
    try expectNumeric("1n", null, 0);
}

test "numeric: a BigInt suffix on a literal that cannot carry one" {
    // `3e` is scientific, so the folded `n` is TS1352, blamed over the literal
    // AND its suffix. `1.5` is merely non-integer: TS1353.
    {
        const f = bigintSuffixMisuse("3en", 100).?;
        try testing.expectEqual(Code.bigint_exponential, f.code);
        try testing.expectEqual(@as(u32, 100), f.span.start);
        try testing.expectEqual(@as(u32, 103), f.span.end);
    }
    {
        const f = bigintSuffixMisuse("1.5n", 100).?;
        try testing.expectEqual(Code.bigint_not_integer, f.code);
        try testing.expectEqual(@as(u32, 100), f.span.start);
    }
    try testing.expect(bigintSuffixMisuse("1.5", 0) == null);
    try testing.expect(bigintSuffixMisuse("1e9", 0) == null);
    // An empty exponent is still reported alongside the suffix, at the
    // character that should have been a digit.
    try expectNumeric("3en", .digit_expected, 2);
    try expectNumeric("3e+n", .digit_expected, 3);
    try expectNumeric("1.5n", null, 0);
}

test "numeric: an abutting identifier" {
    const src = "3a 1e9 ";
    {
        const f = identifierAfterNumeric(src, 1).?;
        try testing.expectEqual(Code.identifier_after_numeric_literal, f.code);
        try testing.expectEqual(@as(u32, 1), f.span.start);
        try testing.expectEqual(@as(u32, 2), f.span.end);
    }
    // Nothing abuts a literal followed by a space, or one at end of input.
    try testing.expect(identifierAfterNumeric(src, 6) == null);
    try testing.expect(identifierAfterNumeric("1", 1) == null);
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
