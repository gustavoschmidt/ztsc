//! Grammar validation of a regular-expression literal's BODY and FLAGS.
//!
//! tsc scans a regex twice: once to find where the literal ends (that is what
//! produces the token, and it is all `Scanner.scanRegex` does), and once more —
//! `scanRegularExpressionWorker`, reached from the checker's grammar pass — to
//! read the body as a PATTERN, with the flags already known. This file is that
//! second pass. Its diagnostics are therefore grammar-class, not syntactic: a
//! real parse error anywhere in the program suppresses every one of them,
//! exactly as it suppresses a TS2322 (measured — `let x = /a/gg` next to `let
//! y: = 3` reports only the TS1110).
//!
//! It is a walk over bytes with no allocation on the happy path and no state
//! beyond the cursor, the flag set and a nesting depth — it runs on every regex
//! token in every file, so anything else would be paid for on every build.
//!
//! SCOPE. The walk is complete (every construct is consumed structurally, so
//! nothing downstream is misread), but only the diagnostics whose position and
//! condition were verified against tsgo 7.0.2 are reported. Unicode property
//! NAMES (`\p{Script=Greek}`), the `v`-mode set operators (`--`, `&&`, `\q{}`),
//! character-class RANGE order, backreference numbering and the "this character
//! cannot be escaped" family are consumed and not judged: an under-report is a
//! missing key, while guessing at one of those manufactures a wrong key and a
//! wrong syntactic answer suppresses a whole program's semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diagnostics = @import("diagnostics.zig");
const scanner = @import("scanner.zig");
const span = @import("span.zig");

const Code = diagnostics.Code;
const Diagnostic = diagnostics.Diagnostic;
const Span = span.Span;

/// Deepest group/class nesting the walk follows. Past it the whole literal is
/// abandoned (no diagnostics at all), because a bail-out mid-walk would report
/// the unclosed constructs it never reached.
const max_depth: u16 = 64;

/// The regex flag letters, as bits. `Modifiers` is the subset a `(?ims-ims:…)`
/// subpattern may toggle; the rest answer TS1509 there.
const Flag = struct {
    const d: u8 = 1 << 0;
    const g: u8 = 1 << 1;
    const i: u8 = 1 << 2;
    const m: u8 = 1 << 3;
    const s: u8 = 1 << 4;
    const u: u8 = 1 << 5;
    const v: u8 = 1 << 6;
    const y: u8 = 1 << 7;
    const modifiers: u8 = i | m | s;
};

fn flagBit(c: u8) u8 {
    return switch (c) {
        'd' => Flag.d,
        'g' => Flag.g,
        'i' => Flag.i,
        'm' => Flag.m,
        's' => Flag.s,
        'u' => Flag.u,
        'v' => Flag.v,
        'y' => Flag.y,
        else => 0,
    };
}

/// Validate the regex literal that starts at `tok_start` and ends at `tok_end`
/// (the token's byte range, `/body/flags`), appending diagnostics to `out`.
/// A literal whose body has no terminating `/` is an unterminated regex, which
/// the parser has already answered with TS1161; nothing here applies to it.
pub fn validate(
    gpa: Allocator,
    src: []const u8,
    tok_start: u32,
    tok_end: u32,
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const body_end = bodyEnd(src, tok_start, tok_end) orelse return;
    var w: Walker = .{
        .gpa = gpa,
        .src = src,
        .out = out,
        .body_start = tok_start + 1,
        .pos = tok_start + 1,
        .end = body_end,
        .base_len = out.items.len,
    };
    const flags = try w.scanFlags(body_end + 1, tok_end);
    w.unicode = flags & (Flag.u | Flag.v) != 0;
    w.sets = flags & Flag.v != 0;
    try w.scanDisjunction(false);
}

/// Index of the `/` that closes the body, or null when there is none. The same
/// walk `Scanner.scanRegex` runs (a `[` opens a class in which `/` is literal),
/// re-run here because the token records only its own bounds.
fn bodyEnd(src: []const u8, tok_start: u32, tok_end: u32) ?u32 {
    var i = tok_start + 1;
    var in_class = false;
    while (i < tok_end) : (i += 1) {
        switch (src[i]) {
            '\\' => i += 1,
            '[' => in_class = true,
            ']' => in_class = false,
            '/' => if (!in_class) return i,
            else => {},
        }
    }
    return null;
}

const Walker = struct {
    gpa: Allocator,
    src: []const u8,
    out: *std.ArrayList(Diagnostic),
    /// First byte of the body (just past the opening `/`).
    body_start: u32,
    pos: u32,
    /// Index of the `/` that closes the body — the walk's end of text.
    end: u32,
    unicode: bool = false,
    sets: bool = false,
    depth: u16 = 0,
    /// `out.items.len` before this literal contributed anything, so `abandon`
    /// can put the list back exactly as it found it.
    base_len: usize,
    /// Set by `abandon`; every later emit is a no-op.
    bailed: bool = false,
    /// Where the last diagnostic of THIS literal landed. tsc answers a regex
    /// position once: `/(?/u` wants both "':' expected" (for the modifier run)
    /// and "')' expected" (for the group) at the same offset and reports only
    /// the first. Suppressing the second can only drop a key, never invent one.
    last_err: ?u32 = null,

    const Error = Allocator.Error;

    fn emit(w: *Walker, code: Code, start: u32, len: u32) Error!void {
        try w.emitArg(code, start, len, .{ .start = 0, .end = 0 });
    }

    fn emitArg(w: *Walker, code: Code, start: u32, len: u32, arg: Span) Error!void {
        if (w.bailed) return;
        if (w.last_err) |prev| if (prev == start) return;
        w.last_err = start;
        try w.out.append(w.gpa, .{
            .code = code,
            .span = .{ .start = start, .end = start + len },
            .arg = arg,
        });
    }

    /// TS1508, whose message names the offending character.
    fn emitChar(w: *Walker, i: u32) Error!void {
        const n = w.charLen(i);
        try w.emitArg(.regex_unexpected_char, i, n, .{ .start = i, .end = i + n });
    }

    /// Byte length of the character at `i` — one for ASCII, the UTF-8 sequence
    /// otherwise, so a non-BMP flag letter is one diagnostic and not four.
    fn charLen(w: *const Walker, i: u32) u32 {
        return scanner.charStepLen(w.src, i);
    }

    fn at(w: *const Walker, i: u32) u8 {
        return if (i < w.end) w.src[i] else 0;
    }

    // --- flags ---------------------------------------------------------------

    /// The `gimsuvyd` run after the closing `/`. Reported per CHARACTER: an
    /// unknown letter is TS1499, a repeat TS1500, and `u` with `v` already set
    /// (or the reverse) TS1502 — which, unlike TS1500, does NOT record the flag,
    /// so a second `u` after a `v` answers TS1502 again rather than "duplicate".
    fn scanFlags(w: *Walker, start: u32, tok_end: u32) Error!u8 {
        var flags: u8 = 0;
        var i = start;
        while (i < tok_end) {
            const n = w.charLen(i);
            const bit = if (n == 1) flagBit(w.src[i]) else 0;
            if (bit == 0) {
                try w.emit(.regex_unknown_flag, i, n);
            } else if (flags & bit != 0) {
                try w.emit(.regex_duplicate_flag, i, n);
            } else if ((bit == Flag.u and flags & Flag.v != 0) or
                (bit == Flag.v and flags & Flag.u != 0))
            {
                try w.emit(.regex_u_and_v_flags, i, n);
            } else {
                flags |= bit;
            }
            i += n;
        }
        // The flag run is scanned before the body, so a body diagnostic at the
        // same offset can never exist; reset so the first body error is kept.
        w.last_err = null;
        return flags;
    }

    // --- pattern -------------------------------------------------------------

    fn scanDisjunction(w: *Walker, in_group: bool) Error!void {
        while (true) {
            try w.scanAlternative(in_group);
            if (w.pos < w.end and w.src[w.pos] == '|') {
                w.pos += 1;
                continue;
            }
            return;
        }
    }

    fn scanAlternative(w: *Walker, in_group: bool) Error!void {
        // Whether a quantifier may follow what was just read (tsc's
        // `isPreviousTermQuantifiable`). Assertions are not quantifiable, and
        // neither is a quantifier itself — `a{2}{3}` answers TS1507.
        var quantifiable = false;
        while (w.pos < w.end) {
            const start = w.pos;
            switch (w.src[w.pos]) {
                '^', '$' => {
                    w.pos += 1;
                    quantifiable = false;
                },
                '\\' => {
                    w.pos += 1;
                    if (w.pos < w.end and (w.src[w.pos] == 'b' or w.src[w.pos] == 'B')) {
                        w.pos += 1;
                        quantifiable = false;
                    } else {
                        try w.scanEscape(start, false);
                        quantifiable = true;
                    }
                },
                '(' => quantifiable = try w.scanGroup(),
                '[' => {
                    try w.scanClass();
                    quantifiable = true;
                },
                ')' => {
                    if (in_group) return;
                    // The one stray closer tsc reports in BOTH modes: a `)` can
                    // never be a literal, where a `}` or `]` can (Annex B).
                    try w.emitChar(start);
                    w.pos += 1;
                    quantifiable = true;
                },
                ']', '}' => {
                    if (w.unicode) try w.emitChar(start);
                    w.pos += 1;
                    quantifiable = true;
                },
                '|' => return,
                '*', '+', '?', '{' => quantifiable = try w.scanQuantifier(quantifiable),
                else => {
                    w.pos += w.charLen(w.pos);
                    quantifiable = true;
                },
            }
        }
    }

    /// Reads the quantifier at `pos` and answers whether what it leaves behind
    /// is itself quantifiable — false for a real quantifier, true for a `{` that
    /// turned out to be a literal.
    fn scanQuantifier(w: *Walker, prev_quantifiable: bool) Error!bool {
        const q_start = w.pos;
        switch (w.src[w.pos]) {
            '*', '+', '?' => w.pos += 1,
            else => {
                // Annex B reads a brace run as a quantifier only when the whole
                // `{n}` / `{n,}` / `{n,m}` is there; short of that the `{` is a
                // literal character and the run answers nothing at all — `a{2,3`
                // and `a{}` are both silent.
                if (!w.unicode and !w.atCompleteQuantifier()) {
                    w.pos += 1;
                    return true;
                }
                w.pos += 1; // `{`
                const digits_start = w.pos;
                const min = w.scanDigits();
                if (min == null) {
                    // Unicode mode has no Annex B fallback. A missing minimum
                    // still reads as a quantifier — TS1505 — but only while what
                    // follows the comma could finish one: `a{,3}`, `a{,3x}` and
                    // `a{,}` all answer TS1505, and `a{,x}`, `a{,??}`, `a{, 3}`
                    // and `a{,,}` are all a stray brace instead (measured).
                    if (w.at(w.pos) != ',' or
                        !(isDigit(w.at(w.pos + 1)) or w.at(w.pos + 1) == '}'))
                    {
                        try w.emitChar(q_start);
                        w.pos = digits_start;
                        return true;
                    }
                    try w.emit(.regex_incomplete_quantifier, w.pos, 0);
                }
                var max = min;
                if (w.pos < w.end and w.src[w.pos] == ',') {
                    w.pos += 1;
                    max = w.scanDigits(); // null = unbounded
                }
                if (min != null and max != null and min.? > max.?) {
                    try w.emit(.regex_quantifier_out_of_order, digits_start, w.pos - digits_start);
                }
                if (w.pos < w.end and w.src[w.pos] == '}') {
                    w.pos += 1;
                } else {
                    // tsc consumes nothing here, so the rest of the run is read
                    // back as pattern characters (`a{0x1}` also answers TS1508
                    // for its `}`).
                    try w.emit(.regex_expected_r_brace, w.pos, 1);
                }
            },
        }
        if (w.pos < w.end and w.src[w.pos] == '?') w.pos += 1; // lazy
        if (!prev_quantifiable) try w.emit(.regex_nothing_to_repeat, q_start, w.pos - q_start);
        return false;
    }

    /// Whether the `{` at `pos` begins a complete `{n}` / `{n,}` / `{n,m}`.
    fn atCompleteQuantifier(w: *const Walker) bool {
        var i = w.pos + 1;
        const digits_start = i;
        while (i < w.end and isDigit(w.src[i])) i += 1;
        if (i == digits_start) return false;
        if (i < w.end and w.src[i] == ',') {
            i += 1;
            while (i < w.end and isDigit(w.src[i])) i += 1;
        }
        return i < w.end and w.src[i] == '}';
    }

    fn scanDigits(w: *Walker) ?u64 {
        const start = w.pos;
        var value: u64 = 0;
        while (w.pos < w.end and w.src[w.pos] >= '0' and w.src[w.pos] <= '9') : (w.pos += 1) {
            value = (value *| 10) +| (w.src[w.pos] - '0');
        }
        return if (w.pos == start) null else value;
    }

    /// `(…)`, `(?:…)`, the four lookarounds, `(?<name>…)` and the modifier form
    /// `(?ims-ims:…)`. Answers whether the group may carry a quantifier: only a
    /// LOOKAHEAD may, and only under Annex B.
    fn scanGroup(w: *Walker) Error!bool {
        w.pos += 1; // `(`
        var quantifiable = true;
        if (w.pos < w.end and w.src[w.pos] == '?') {
            w.pos += 1;
            switch (w.at(w.pos)) {
                '=', '!' => {
                    w.pos += 1;
                    quantifiable = !w.unicode;
                },
                '<' => {
                    w.pos += 1;
                    if (w.pos < w.end and (w.src[w.pos] == '=' or w.src[w.pos] == '!')) {
                        w.pos += 1;
                        quantifiable = false;
                    } else {
                        try w.scanGroupName(false);
                    }
                },
                else => {
                    try w.scanModifiers();
                    try w.expect(':', .regex_expected_colon);
                },
            }
        }
        if (w.depth >= max_depth) return w.abandon();
        w.depth += 1;
        try w.scanDisjunction(true);
        w.depth -= 1;
        try w.expect(')', .regex_expected_r_paren);
        return quantifiable;
    }

    /// The `ims-ims` run of a subpattern modifier. tsc reuses the FLAG
    /// diagnostics here — an unknown letter is TS1499 — and adds TS1509 for a
    /// letter that is a real flag but not one a subpattern may toggle.
    fn scanModifiers(w: *Walker) Error!void {
        const start = w.pos;
        const flags = try w.scanModifierRun(0);
        if (w.pos < w.end and w.src[w.pos] == '-') {
            w.pos += 1;
            _ = try w.scanModifierRun(flags);
            // TS1504 is about the TEXT, not the flag set: `(?z-z:a)` names two
            // letters that are no flags at all and is still silent, while
            // `(?-:a)` — a minus and nothing else — is not (measured).
            if (w.pos - start == 1) try w.emit(.regex_subpattern_flags_needed, start, 1);
        }
    }

    fn scanModifierRun(w: *Walker, in_flags: u8) Error!u8 {
        var flags = in_flags;
        while (w.pos < w.end) {
            const n = w.charLen(w.pos);
            if (n == 1 and !isIdentPart(w.src[w.pos])) break;
            const bit = if (n == 1) flagBit(w.src[w.pos]) else 0;
            if (bit == 0) {
                try w.emit(.regex_unknown_flag, w.pos, n);
            } else if (flags & bit != 0) {
                try w.emit(.regex_duplicate_flag, w.pos, n);
            } else if (bit & Flag.modifiers == 0) {
                try w.emit(.regex_flag_not_toggleable, w.pos, n);
            } else {
                flags |= bit;
            }
            w.pos += n;
        }
        return flags;
    }

    /// The name in `(?<name>…)` or `\k<name>`. A reference also has to name a
    /// group that the pattern declares (TS1532) — a question the pattern text
    /// answers, so no table of declared names has to be carried through.
    fn scanGroupName(w: *Walker, is_reference: bool) Error!void {
        const name_start = w.pos;
        if (w.pos < w.end and (w.src[w.pos] >= 0x80 or isIdentStart(w.src[w.pos]))) {
            while (w.pos < w.end and (w.src[w.pos] >= 0x80 or isIdentPart(w.src[w.pos]))) {
                w.pos += w.charLen(w.pos);
            }
        } else {
            try w.emit(.regex_expected_group_name, w.pos, 1);
            return;
        }
        const name = w.src[name_start..w.pos];
        if (is_reference and !declaresGroup(w.src[w.body_start..w.end], name)) {
            try w.emitArg(.regex_no_group_named, name_start, w.pos - name_start, .{
                .start = name_start,
                .end = w.pos,
            });
        }
        if (w.pos < w.end and w.src[w.pos] == '>') w.pos += 1;
    }

    /// `[…]`, including the `v`-mode nested classes. Range ORDER (TS1517) and
    /// the `v`-mode set operators are the part of tsc's class grammar this file
    /// does not model; a range BOUND is judged, because that needs no character
    /// values — only whether the bound is a character-class escape.
    fn scanClass(w: *Walker) Error!void {
        w.pos += 1; // `[`
        if (w.pos < w.end and w.src[w.pos] == '^') w.pos += 1;
        while (w.pos < w.end and w.src[w.pos] != ']') {
            if (w.sets and w.src[w.pos] == '[') {
                if (w.depth >= max_depth) {
                    _ = w.abandon();
                    return;
                }
                w.depth += 1;
                try w.scanClass();
                w.depth -= 1;
                continue;
            }
            const lhs_start = w.pos;
            const lhs_is_class = try w.scanClassAtom();
            // A `-` between two members is a RANGE — except under `v`, where
            // `--` is set difference and this file leaves the class alone.
            if (w.unicode and !w.sets and w.pos + 1 < w.end and
                w.src[w.pos] == '-' and w.src[w.pos + 1] != ']')
            {
                w.pos += 1;
                if (lhs_is_class) try w.emit(.regex_range_bounded_by_class, lhs_start, 1);
                const rhs_start = w.pos;
                if (try w.scanClassAtom()) {
                    try w.emit(.regex_range_bounded_by_class, rhs_start, 1);
                }
            }
        }
        try w.expect(']', .regex_expected_r_bracket);
    }

    /// One class member; answers whether it is a character-CLASS escape (`\d`,
    /// `\p{…}`, …), which is what may not bound a range.
    fn scanClassAtom(w: *Walker) Error!bool {
        if (w.src[w.pos] != '\\') {
            w.pos += w.charLen(w.pos);
            return false;
        }
        const escape_start = w.pos;
        const c = w.at(w.pos + 1);
        w.pos += 1;
        try w.scanEscape(escape_start, true);
        return switch (c) {
            'd', 'D', 's', 'S', 'w', 'W', 'p', 'P' => true,
            else => false,
        };
    }

    /// The escape after a `\` (`pos` is at the letter, `escape_start` at the
    /// backslash). Outside a class `\b`/`\B` never reach here — they are
    /// assertions, and the caller has to know that to get `\b*` right.
    fn scanEscape(w: *Walker, escape_start: u32, in_class: bool) Error!void {
        if (w.pos >= w.end) return;
        switch (w.src[w.pos]) {
            'u' => try w.scanUnicodeEscape(escape_start),
            'x' => {
                w.pos += 1;
                try w.scanHexDigits(2);
            },
            'c' => {
                w.pos += 1;
                if (w.pos < w.end and isAsciiLetter(w.src[w.pos])) {
                    w.pos += 1;
                } else if (w.unicode) {
                    // Annex B keeps a bare `\c` as the two literal characters.
                    try w.emit(.regex_c_needs_letter, escape_start, w.pos - escape_start);
                }
            },
            'p', 'P' => {
                w.pos += 1;
                if (w.pos < w.end and w.src[w.pos] == '{') {
                    if (!w.unicode) {
                        try w.emit(.regex_property_needs_unicode_flag, escape_start, w.pos - escape_start);
                    }
                    w.pos += 1;
                    // A property expression is `Name` or `Name=Value`, both
                    // `[A-Za-z0-9_]`. Stopping at the first character outside
                    // that is what keeps `[\P{]` from swallowing the rest of the
                    // pattern looking for a brace tsc never looks for either.
                    const name_start = w.pos;
                    while (w.pos < w.end and isPropertyChar(w.src[w.pos])) w.pos += 1;
                    // An EMPTY `\p{}` is a property-NAME failure (TS1527), which
                    // this file does not model, and tsc reports that instead of
                    // the missing brace — so only a non-empty one is judged here.
                    if (w.pos > name_start) {
                        try w.expect('}', .regex_expected_r_brace);
                    } else if (w.pos < w.end and w.src[w.pos] == '}') {
                        w.pos += 1;
                    }
                } else if (w.unicode) {
                    try w.emit(.regex_p_needs_braces, escape_start, w.pos - escape_start);
                }
            },
            'k' => {
                w.pos += 1;
                if (!in_class and w.pos < w.end and w.src[w.pos] == '<') {
                    w.pos += 1;
                    try w.scanGroupName(true);
                } else if (w.unicode) {
                    // Inside a class `\k` is no backreference at all, so it is
                    // the same nothing-to-escape answer any other letter gets.
                    try w.emit(
                        if (in_class) .regex_char_cannot_be_escaped else .regex_k_needs_group_name,
                        escape_start,
                        w.pos - escape_start,
                    );
                }
            },
            // The escapes that mean something: the control escapes, the NUL, and
            // the character-class shorthands. `\b` reaches here only inside a
            // class, where it is a backspace; `\B` is not legal there and falls
            // to the identity-escape arm below, as tsc has it.
            'f', 'n', 'r', 't', 'v', '0', 'b', 'd', 'D', 's', 'S', 'w', 'W' => w.pos += 1,
            else => {
                const c = w.src[w.pos];
                w.pos += w.charLen(w.pos);
                if (!w.unicode or w.escapable(c, in_class)) return;
                try w.emit(.regex_char_cannot_be_escaped, escape_start, w.pos - escape_start);
            },
        }
    }

    /// Whether `\c` is a legal escape in unicode mode — i.e. whether TS1535 has
    /// to stay silent for it. The syntax characters and `/` are the identity
    /// escapes; a class adds `-`, and a `v`-mode class the set notation's
    /// reserved punctuation; the decimal escapes are backreferences (and inside
    /// a class octal escapes), both of which this file leaves unjudged, as it
    /// does the `v`-mode `\q`.
    fn escapable(w: *const Walker, c: u8, in_class: bool) bool {
        return switch (c) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
            '-' => in_class,
            '1'...'9' => true,
            'q' => w.sets,
            // `v`-mode ClassSetReservedPunctuator: inside a class the escapable
            // set widens to the punctuation the set notation reserves, so
            // `[\`]` is silent under `v` and TS1535 under `u` (measured).
            '&', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~' => w.sets and in_class,
            else => false,
        };
    }

    /// `\uHHHH` or the extended `\u{H…}`. The extended form needs `u` or `v`
    /// (TS1538) but is still read — and still range-checked — without it.
    fn scanUnicodeEscape(w: *Walker, escape_start: u32) Error!void {
        w.pos += 1; // `u`
        if (w.pos >= w.end or w.src[w.pos] != '{') return w.scanHexDigits(4);
        if (!w.unicode) {
            try w.emit(.regex_unicode_escape_needs_flag, escape_start, w.pos - escape_start);
        }
        w.pos += 1; // `{`
        const digits_start = w.pos;
        var value: u64 = 0;
        while (w.pos < w.end and isHexDigit(w.src[w.pos])) : (w.pos += 1) {
            value = (value *| 16) +| hexValue(w.src[w.pos]);
        }
        if (w.pos == digits_start) {
            // With no digits tsc says only "hexadecimal digit expected", and
            // takes the `}` only if it is already there: `\u{r}` leaves the `r`
            // and the `}` to be read back as pattern characters.
            try w.emit(.regex_hex_digit_expected, w.pos, 1);
            if (w.pos < w.end and w.src[w.pos] == '}') w.pos += 1;
            return;
        }
        if (value > 0x10FFFF) {
            try w.emit(.regex_unicode_escape_out_of_range, digits_start, w.pos - digits_start);
        }
        if (w.pos >= w.end) {
            try w.emit(.regex_unexpected_end_of_text, w.pos, 0);
        } else if (w.src[w.pos] == '}') {
            w.pos += 1;
        } else {
            try w.emit(.regex_unterminated_unicode_escape, w.pos, 0);
        }
    }

    fn scanHexDigits(w: *Walker, count: u32) Error!void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (w.pos < w.end and isHexDigit(w.src[w.pos])) {
                w.pos += 1;
            } else {
                try w.emit(.regex_hex_digit_expected, w.pos, 1);
                return;
            }
        }
    }

    fn expect(w: *Walker, c: u8, code: Code) Error!void {
        if (w.pos < w.end and w.src[w.pos] == c) {
            w.pos += 1;
            return;
        }
        try w.emit(code, w.pos, 1);
    }

    /// Past `max_depth` the literal is dropped whole: every diagnostic recorded
    /// for it so far goes with it, because the ones still to come (the closers
    /// the walk will never reach) would be invented.
    fn abandon(w: *Walker) bool {
        w.out.shrinkRetainingCapacity(w.base_len);
        w.bailed = true;
        w.pos = w.end;
        return true;
    }
};

/// Whether `body` declares `(?<name>…)`. Escapes and character classes are
/// skipped so a `\(?<x>` or a `[(?<x>]` is not mistaken for a declaration.
fn declaresGroup(body: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < body.len) {
        switch (body[i]) {
            '\\' => i += 2,
            '[' => {
                i += 1;
                while (i < body.len and body[i] != ']') : (i += 1) {
                    if (body[i] == '\\') i += 1;
                }
                i += 1;
            },
            '(' => {
                if (i + 3 < body.len and body[i + 1] == '?' and body[i + 2] == '<' and
                    body[i + 3] != '=' and body[i + 3] != '!')
                {
                    const start = i + 3;
                    var j = start;
                    while (j < body.len and body[j] != '>') : (j += 1) {}
                    if (j < body.len and std.mem.eql(u8, body[start..j], name)) return true;
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return false;
}

fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentStart(c: u8) bool {
    return isAsciiLetter(c) or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// A character of a `\p{…}` property name or value, `=` included.
fn isPropertyChar(c: u8) bool {
    return isIdentPart(c) or c == '=';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexValue(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => c - 'A' + 10,
    };
}
