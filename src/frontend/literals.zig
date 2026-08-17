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
            // `0x` alone, `0xn` (the BigInt suffix is not a digit), and `0x_`
            // (separators are not digits either). tsc's
            // `scanBinaryOrOctalOrHexDigits` consumes the digits AND the
            // separators and then asks whether it collected any real digit, so
            // the blame lands past the separators: `0x_` is TS1125 on the
            // character after the `_`, not on the `_` (which earns its own
            // TS6188). No prefixed radix has an exponent form, so this is the
            // only rule that can apply to one — and `0xe` ends in an `e` that IS
            // a digit.
            const e = runEnd(text, 2, radixOf(text[1]).?);
            for (text[2..e]) |c| {
                if (c != '_') return null;
            }
            const at = start + @as(u32, @intCast(e));
            return .{ .code = code, .span = .{ .start = at, .end = at + 1 } };
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
    // Where the digit should have been: the END of the exponent's fragment,
    // which is past any separators it collected. A separator is not a digit, so
    // `1.0e_+10` scans as `1.0e_` and tsc's exponent fragment comes back empty
    // — TS1124 lands after the `_`, next to the TS6188 the `_` itself earns.
    const at = i;
    while (i > 1 and text[i - 1] == '_') i -= 1;
    if (text[i - 1] == '+' or text[i - 1] == '-') {
        if (i < 2) return null;
        i -= 1;
    }
    if ((text[i - 1] | 0x20) != 'e') return null;
    return @intCast(at);
}

/// TS6188/TS6189: where a numeric literal's `_` separators are allowed to sit.
///
/// ES2021 numeric separators may only sit BETWEEN two digits, and tsc's scanner
/// says so one separator at a time while it walks the literal's fragments —
/// which is why one literal can earn several findings, and why the wording
/// depends on the neighbour: a separator directly after another one is TS6189
/// ("Multiple consecutive numeric separators are not permitted"), anywhere else
/// it is TS6188 ("Numeric separators are not allowed here").
///
/// A literal has up to three separator FRAGMENTS, and each starts the rule over:
/// the integer part, the part after the `.`, and the part after `e`/`E` and its
/// optional sign (a prefixed-radix literal has exactly one, after `0x`/`0o`/`0b`).
/// `scanNumberFragment` reports a separator it cannot allow where it stands, and
/// then — after the loop — a TRAILING one, which is how `10_` earns a finding
/// even though the separator was consumed happily. tsc's one-diagnostic-per-
/// position rule collapses the two when they coincide, so `0.0__` is the TS6189
/// alone; this walk yields both, in position order, and `Parser.addDiag`
/// collapses them exactly as tsc's `parseErrorAtPosition` does.
///
/// One shape is special and had to be read off tsc rather than guessed:
/// `scanNumber` tests for a `_` immediately after a leading `0` BEFORE the
/// fragment walk, reports TS6188 there, and then re-scans the fragment from the
/// `0` — so `0__0` earns TS6188 on the first separator (which the fragment walk
/// would have allowed, it following a digit) and TS6189 on the second. Measured:
/// `t/n1.ts` runs all of it past tsgo 7.0.2 and every position agrees.
///
/// A leading zero followed by a DIGIT is left alone. There tsc uses `scanDigits`,
/// which knows nothing about separators and ends the token at the first one, so
/// `08_1` is a leading-zero literal `08` plus an identifier and earns no
/// separator finding at all — a tokenization difference, not a separator rule
/// (ztsc's scanner swallows the `_`), and it belongs with the leading-zero work.
pub const SeparatorWalk = struct {
    text: []const u8,
    base: u32,
    /// The fragments still to walk, in source order.
    frags: [3]Frag = undefined,
    n_frags: u8 = 0,
    frag: u8 = 0,
    i: usize = 0,
    allow_sep: bool = false,
    prev_sep: bool = false,
    /// The current fragment's trailing-separator finding, held back until the
    /// fragment's own loop has finished (tsc reports it after the loop).
    pending: ?Finding = null,
    /// `scanNumber`'s pre-fragment report for `0_`.
    leading: ?Finding = null,

    const Frag = struct { start: usize, end: usize };

    /// True when the token cannot contain a separator at all — the guard that
    /// keeps this off the hot path for the ~all numeric literals with none.
    pub fn any(text: []const u8) bool {
        return std.mem.indexOfScalar(u8, text, '_') != null;
    }

    pub fn init(text: []const u8, base: u32) SeparatorWalk {
        var w: SeparatorWalk = .{ .text = text, .base = base };
        w.plan();
        if (w.n_frags > 0) w.i = w.frags[0].start;
        return w;
    }

    pub fn next(w: *SeparatorWalk) ?Finding {
        if (w.leading) |f| {
            w.leading = null;
            return f;
        }
        while (w.frag < w.n_frags) {
            const end = w.frags[w.frag].end;
            while (w.i < end) {
                const c = w.text[w.i];
                if (c == '_') {
                    const off = w.i;
                    w.i += 1;
                    if (w.allow_sep) {
                        w.allow_sep = false;
                        w.prev_sep = true;
                        continue;
                    }
                    return w.at(if (w.prev_sep) .multiple_numeric_separators else .numeric_separator_not_allowed, off);
                }
                w.allow_sep = true;
                w.prev_sep = false;
                w.i += 1;
            }
            // Fragment done: its trailing separator, then start the next one.
            const done = w.frag;
            w.frag += 1;
            if (w.frag < w.n_frags) {
                w.i = w.frags[w.frag].start;
                w.allow_sep = false;
                w.prev_sep = false;
            }
            const fe = w.frags[done].end;
            if (fe > w.frags[done].start and w.text[fe - 1] == '_') {
                return w.at(.numeric_separator_not_allowed, fe - 1);
            }
        }
        return null;
    }

    fn at(w: *const SeparatorWalk, code: Code, off: usize) Finding {
        const s = w.base + @as(u32, @intCast(off));
        return .{ .code = code, .span = .{ .start = s, .end = s + 1 } };
    }

    /// Split the literal into the fragments tsc walks. Mirrors `scanNumber`'s
    /// control flow, which is the only way the positions can agree.
    fn plan(w: *SeparatorWalk) void {
        const t = w.text;
        if (t.len < 2) return;
        if (t[0] == '0') {
            if (radixOf(t[1])) |base| {
                w.push(2, runEnd(t, 2, base));
                return;
            }
            if (t[1] == '_') {
                // `scanNumber`'s own report, then `pos--` and walk the integer
                // fragment from the `0` again.
                w.leading = w.at(.numeric_separator_not_allowed, 1);
            } else if (isDigit(t[1])) {
                // `scanDigits` — separator-blind (see the doc comment).
                return;
            }
        }
        var i = runEnd(t, 0, .dec);
        w.push(0, i);
        if (i < t.len and t[i] == '.') {
            i += 1;
            const e = runEnd(t, i, .dec);
            w.push(i, e);
            i = e;
        }
        if (i < t.len and (t[i] | 0x20) == 'e') {
            i += 1;
            if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
            w.push(i, runEnd(t, i, .dec));
        }
    }

    fn push(w: *SeparatorWalk, start: usize, end: usize) void {
        w.frags[w.n_frags] = .{ .start = start, .end = end };
        w.n_frags += 1;
    }
};

/// The radix a `0x`/`0o`/`0b` prefix names, or null for anything else.
fn radixOf(c: u8) ?Radix {
    return switch (c) {
        'x', 'X' => .hex,
        'o', 'O' => .oct,
        'b', 'B' => .bin,
        else => null,
    };
}

const Radix = enum { bin, oct, dec, hex };

/// End of the run of digits-and-separators starting at `i`. The scanner has
/// already ended the token, so this only has to stop at the BigInt suffix and at
/// the `.`/`e` that begin the next fragment.
fn runEnd(text: []const u8, i: usize, radix: Radix) usize {
    var j = i;
    while (j < text.len) {
        const c = text[j];
        const ok = switch (radix) {
            .bin => c == '0' or c == '1',
            .oct => c >= '0' and c <= '7',
            .dec => isDigit(c),
            .hex => isHex(c),
        };
        if (!ok and c != '_') break;
        j += 1;
    }
    return j;
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

/// The FLAGS of a regular-expression literal — the tail of tsc's
/// `scanRegularExpressionWorker`, which walks the run after the closing `/` and
/// judges one character at a time.
///
/// `d g i m s u v y` are the flags. Anything else is TS1499, a repeat is
/// TS1500, and `u` with `v` is TS1502 reported on the SECOND of the pair —
/// each measured against tsgo 7.0.2 (`/x/a`, `/x/gg`, `/x/uv`, `/x/abc`, which
/// answers three times). tsc's remaining arm, "this flag is only available when
/// targeting ES2015 or later", cannot fire here: ztsc pins `esnext`, where
/// every flag is available.
///
/// Only the FLAGS. tsc validates the regex BODY too (TS1125 for a `\u{}` with
/// no hex digit, TS1508 for a bare `}`, and some forty more), which needs a
/// real body parse — quantifier braces, character classes, the `(?ims-ims:`
/// modifier group — and is deliberately left alone: a wrong error there is a
/// SYNTACTIC one, and a syntactic error suppresses every semantic diagnostic in
/// the whole program. A flag is a closed set of single letters, so this half
/// cannot fire on valid code.
///
/// The flags are found by walking BACK from the end of the token, not forward
/// through the body: the scanner defines them as exactly the maximal trailing
/// run of `scanner.isRegexFlagByte`, so re-deriving them the same way cannot
/// disagree with it — and re-walking the body here would be a second copy of
/// `scanRegex`.
pub const RegexFlagWalk = struct {
    text: []const u8,
    base: u32,
    i: usize,
    /// The flags accepted so far, one bit each. `u8` because there are eight.
    seen: u8 = 0,

    const d: u8 = 1 << 0;
    const g: u8 = 1 << 1;
    const i_flag: u8 = 1 << 2;
    const m: u8 = 1 << 3;
    const s: u8 = 1 << 4;
    const u: u8 = 1 << 5;
    const v: u8 = 1 << 6;
    const y: u8 = 1 << 7;
    /// `u` and `v` both select Unicode mode, and only one of them may.
    const unicode_mode = u | v;

    fn flagBit(c: u8) ?u8 {
        return switch (c) {
            'd' => d,
            'g' => g,
            'i' => i_flag,
            'm' => m,
            's' => s,
            'u' => u,
            'v' => v,
            'y' => y,
            else => null,
        };
    }

    /// `text` is the literal's exact source text (`/body/flags`) and `base` its
    /// file offset.
    pub fn init(text: []const u8, base: u32) RegexFlagWalk {
        var from = text.len;
        while (from > 0 and scanner.isRegexFlagByte(text[from - 1])) from -= 1;
        // The byte before the run has to be the closing `/`. When it is not,
        // the token is not a complete regex literal (an unterminated one has
        // its own tag) and there is nothing here to judge.
        if (from == 0 or text[from - 1] != '/') from = text.len;
        return .{ .text = text, .base = base, .i = from };
    }

    pub fn next(w: *RegexFlagWalk) ?Finding {
        while (w.i < w.text.len) {
            const from = w.i;
            // A flag is one ASCII letter; a non-ASCII code point is reported
            // whole, which is what puts the column on the character rather
            // than on one of its continuation bytes.
            const width = std.unicode.utf8ByteSequenceLength(w.text[from]) catch 1;
            w.i = @min(from + width, w.text.len);
            if (width != 1) return w.at(.regexp_unknown_flag, from);
            const bit = flagBit(w.text[from]) orelse return w.at(.regexp_unknown_flag, from);
            if (w.seen & bit != 0) return w.at(.regexp_duplicate_flag, from);
            const clash = bit & unicode_mode != 0 and w.seen & unicode_mode != 0;
            w.seen |= bit;
            if (clash) return w.at(.regexp_unicode_and_unicode_sets, from);
        }
        return null;
    }

    fn at(w: *const RegexFlagWalk, code: Code, from: usize) Finding {
        return .{ .code = code, .span = .{
            .start = w.base + @as(u32, @intCast(from)),
            .end = w.base + @as(u32, @intCast(w.i)),
        } };
    }
};

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

test "numeric separators: every finding, in tsc's order" {
    // Each expectation is `(text, [(code, offset)…])`, and every one of them is
    // a line of `t/n1.ts` measured against tsgo 7.0.2. Offsets are 0-based, so
    // add one for the column tsgo prints.
    const sep: Code = .numeric_separator_not_allowed;
    const mult: Code = .multiple_numeric_separators;
    const cases = [_]struct { text: []const u8, want: []const struct { Code, u32 } }{
        // Well-formed: between two digits, in every fragment.
        .{ .text = "1_000_000", .want = &.{} },
        .{ .text = "0b00_11", .want = &.{} },
        .{ .text = "0x1_2", .want = &.{} },
        .{ .text = "1_0.2_3e4_5", .want = &.{} },
        // A trailing separator, reported after the fragment's own loop.
        .{ .text = "10_", .want = &.{.{ sep, 2 }} },
        .{ .text = "0b00_", .want = &.{.{ sep, 4 }} },
        .{ .text = "0x1_", .want = &.{.{ sep, 3 }} },
        .{ .text = "0e0_", .want = &.{.{ sep, 3 }} },
        // A leading one, per fragment.
        .{ .text = "0b_110", .want = &.{.{ sep, 2 }} },
        .{ .text = "0._0", .want = &.{.{ sep, 2 }} },
        .{ .text = "0e_0", .want = &.{.{ sep, 2 }} },
        .{ .text = "0e+_0", .want = &.{.{ sep, 3 }} },
        // Consecutive.
        .{ .text = "1__0", .want = &.{.{ mult, 2 }} },
        .{ .text = "0b01__11", .want = &.{.{ mult, 5 }} },
        .{ .text = "0.0__0", .want = &.{.{ mult, 4 }} },
        // A trailing pair: the walk yields the TS6189 and then the trailing
        // TS6188 at the SAME offset, which `Parser.addDiag` collapses exactly as
        // tsc's one-diagnostic-per-position rule does.
        .{ .text = "0.0__", .want = &.{ .{ mult, 4 }, .{ sep, 4 } } },
        // `scanNumber`'s own pre-fragment report for a `_` right after a leading
        // `0`, which is why the second separator here is the CONSECUTIVE one.
        .{ .text = "0__0.0e0", .want = &.{ .{ sep, 1 }, .{ mult, 2 } } },
        // …and why `0_.0` is one finding: the pre-report and the fragment's
        // trailing one land on the same offset.
        .{ .text = "0_.0", .want = &.{ .{ sep, 1 }, .{ sep, 1 } } },
        // The error branch does not set "previous was a separator", so a run at
        // the start of a radix fragment is all TS6188.
        .{ .text = "0b___0111010_0101_1", .want = &.{ .{ sep, 2 }, .{ sep, 3 }, .{ sep, 4 } } },
        // A leading zero followed by a DIGIT is `scanDigits`, which is
        // separator-blind.
        .{ .text = "08_1", .want = &.{} },
        .{ .text = "01_2", .want = &.{} },
    };
    for (cases) |c| {
        var got: std.ArrayList(struct { Code, u32 }) = .empty;
        defer got.deinit(std.testing.allocator);
        if (SeparatorWalk.any(c.text)) {
            var w: SeparatorWalk = .init(c.text, 0);
            while (w.next()) |f| try got.append(std.testing.allocator, .{ f.code, f.span.start });
        }
        std.testing.expectEqualSlices(struct { Code, u32 }, c.want, got.items) catch |e| {
            std.debug.print("--- separators for: {s}\n", .{c.text});
            return e;
        };
    }
}

test "numeric separators: the cheap guard agrees with the walk" {
    for ([_][]const u8{ "1", "0x1f", "1.5e-3", "0b1011", "1n", "0" }) |t| {
        try std.testing.expect(!SeparatorWalk.any(t));
    }
}

test "numeric: a radix prefix whose digits are only separators" {
    // `scanBinaryOrOctalOrHexDigits` consumes the separators before asking
    // whether it saw a digit, so the blame is past them (and the separators earn
    // their own TS6188).
    try expectNumeric("0x_", .hex_digit_expected, 3);
    try expectNumeric("0x__", .hex_digit_expected, 4);
    try expectNumeric("0b_", .binary_digit_expected, 3);
    try expectNumeric("0o_", .octal_digit_expected, 3);
    try expectNumeric("0x_n", .hex_digit_expected, 3);
    try expectNumeric("0x_1", null, 0);
}

test "numeric: an exponent whose digits are only separators" {
    // `1.0e_+10` scans as `1.0e_` (a separator is not a sign), and the empty
    // exponent fragment is blamed past it — corpus `49.ts`/`50.ts`.
    try expectNumeric("1.0e_", .digit_expected, 5);
    try expectNumeric("1e_", .digit_expected, 3);
    try expectNumeric("1e-_", .digit_expected, 4);
    // A separator that is not in the exponent leaves it well-formed.
    try expectNumeric("0.0_", null, 0);
    try expectNumeric("1_e9", null, 0);
    try expectNumeric("0_", null, 0);
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

fn regexFlags(text: []const u8, buf: []Finding) []Finding {
    var w: RegexFlagWalk = .init(text, 0);
    var n: usize = 0;
    while (w.next()) |f| : (n += 1) buf[n] = f;
    return buf[0..n];
}

test "regex flags: the eight legal ones, in any order, answer nothing" {
    var buf: [8]Finding = undefined;
    try testing.expectEqual(@as(usize, 0), regexFlags("/x/dgimsuy", &buf).len);
    try testing.expectEqual(@as(usize, 0), regexFlags("/x/v", &buf).len);
    try testing.expectEqual(@as(usize, 0), regexFlags("/x/", &buf).len);
    // A body that ends in flag-shaped bytes is still body, not flags.
    try testing.expectEqual(@as(usize, 0), regexFlags("/abc/", &buf).len);
}

test "regex flags: one finding per offending character, at that character" {
    var buf: [8]Finding = undefined;
    {
        const got = regexFlags("/x/a", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.regexp_unknown_flag, got[0].code);
        try testing.expectEqual(@as(u32, 3), got[0].span.start);
    }
    // Three unknown flags are three findings, each one character wide.
    {
        const got = regexFlags("/x/abc", &buf);
        try testing.expectEqual(@as(usize, 3), got.len);
        try testing.expectEqual(@as(u32, 3), got[0].span.start);
        try testing.expectEqual(@as(u32, 4), got[1].span.start);
        try testing.expectEqual(@as(u32, 5), got[2].span.start);
    }
    {
        const got = regexFlags("/x/gg", &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.regexp_duplicate_flag, got[0].code);
        try testing.expectEqual(@as(u32, 4), got[0].span.start); // the SECOND `g`
    }
    // `u` and `v` clash, and the report is on whichever came second.
    for ([_][]const u8{ "/x/uv", "/x/vu" }) |text| {
        const got = regexFlags(text, &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(Code.regexp_unicode_and_unicode_sets, got[0].code);
        try testing.expectEqual(@as(u32, 4), got[0].span.start);
    }
}

test "regex flags: a non-ASCII flag is reported once, over the whole character" {
    var buf: [8]Finding = undefined;
    // U+1D667 MATHEMATICAL SANS-SERIF BOLD SMALL G, four bytes.
    const got = regexFlags("/x/\u{1D667}", &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Code.regexp_unknown_flag, got[0].code);
    try testing.expectEqual(@as(u32, 3), got[0].span.start);
    try testing.expectEqual(@as(u32, 7), got[0].span.end);
}

test "escapes: the cheap guard agrees with the walk" {
    var buf: [8]Finding = undefined;
    try testing.expect(!EscapeWalk.any("\"plain\""));
    try testing.expect(EscapeWalk.any("\"\\101\""));
    // A trailing lone backslash terminates instead of running off the end.
    try testing.expectEqual(@as(usize, 0), collect("\"abc\\", &buf).len);
}
