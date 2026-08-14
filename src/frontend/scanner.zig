//! TypeScript tokenizer.
//!
//! Scans the FULL TypeScript token set (we check only a subset, but we scan
//! everything so later phases can degrade gracefully on unsupported syntax).
//!
//! Design decisions:
//!
//! - **Token storage is struct-of-arrays**: `tags: []Tag` (1 byte)
//!   + `starts: []u32`. The preceded-by-newline flag (for ASI) is packed into
//!   bit 31 of the start word, so sources are limited to 2 GiB
//!   (`max_source_len`). Net: **5 bytes per token**. Token end offsets are not
//!   stored; they are recomputed on demand by re-scanning a single token
//!   (`tokenEnd`), and line/col comes lazily from source.zig line tables.
//! - **Comments and shebang are trivia** and are skipped (not preserved as
//!   tokens). A line break inside skipped trivia (including inside a block
//!   comment) sets the following token's preceded-by-newline flag, exactly
//!   like tsc's `precededByLineBreak`.
//! - **Keywords**: all reserved words, strict-mode reserved words, and
//!   contextual keywords get distinct tags; the parser treats contextual (and,
//!   where the grammar allows, strict-reserved) keyword tokens as identifiers
//!   via `Tag.isContextualKeyword` / `Tag.isStrictReservedKeyword`.
//! - **Regex vs. division is parser-context dependent**, so like tsc the
//!   low-level `Scanner` scans `/` as `slash`/`slash_eq` and exposes
//!   `reScanSlashAsRegex` (tsc: `reScanSlashToken`). Similarly a `}` closing a
//!   template substitution is rescanned via `reScanTemplateToken`
//!   (tsc: `reScanTemplateToken`). There is deliberately NO whole-file driver
//!   here: the parser pulls tokens itself and calls the rescan entry points
//!   with real grammar context, since any standalone previous-token heuristic
//!   mislabels forms like `if (x) /re/.test(y)`. The scanner's own tests drive
//!   `Scanner.next()` in a loop with such a heuristic (`tokenizeForTest`), and
//!   that loop is the only place it exists.
//! - **Maximal munch for `>` sequences**: `>>`, `>>>`, `>>=`, `>>>=`, `>=` are
//!   single tokens (unlike tsc, which scans lone `>` and rescans on demand).
//!   The parser splits `>>` when closing nested generics — trivial with
//!   SoA tokens since the pieces are byte-adjacent.
//! - **Unicode, pragmatically**: ASCII has a fast path; any byte >= 0x80 is
//!   accepted as an identifier constituent without ID_Start/ID_Continue table
//!   validation. This over-accepts (e.g. U+00A0 NBSP or U+2028 LS become
//!   identifier bytes rather than whitespace/line terminators) but never
//!   mis-tokenizes ASCII-only code and never crashes on invalid UTF-8. `\u`
//!   escapes in identifiers are consumed (`\uXXXX` and `\u{...}`); escaped
//!   keywords are always plain identifiers. A UTF-8 BOM is skipped.
//! - **Numeric literals**: decimal (incl. `.5`, `1.`, exponents), hex, octal,
//!   binary, bigint `n` suffix (only on integer forms: `1.5n` scans as `1.5`
//!   + identifier `n`; hex-float `0x1p3` is not TS and scans as `0x1` +
//!   identifier `p3`). Numeric separators `_` are consumed liberally;
//!   placement validation (no `1__2`, `_1`, `1_`) is deferred to the parser.
//! - **Errors never crash or hang**: unterminated strings/templates/regexes/
//!   block comments and stray bytes produce dedicated error tags with spans,
//!   and every non-eof token consumes at least one byte (fuzz-asserted).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sources are limited to 2 GiB - 1 so bit 31 of a token start can carry the
/// preceded-by-newline flag.
pub const max_source_len: usize = (1 << 31) - 1;

/// Scan a JSX name starting at `at` (must be an identifier-start byte): an
/// identifier run that also spans `-` (`data-foo`, `aria-label`, custom
/// elements `my-widget`). Returns the byte offset just past the name.
/// Used only by the parser's `rescanJsxName` — plain scanning still lexes
/// `-` as subtraction, so non-JSX code is untouched.
///
/// Spans exactly what `identifierRest` spans, plus `-`: an identifier may
/// carry `\uXXXX` / `\u{H+}` escapes and non-ASCII bytes, and a name whose
/// FIRST character is one of those (`<\u{0061}-b>`) must still advance. A
/// plain `isIdentCont` loop stops dead on the leading backslash and returns
/// `at_index`, which handed the parser a zero-length token and rewound the
/// scanner onto it — an infinite loop, not a diagnostic.
pub fn scanJsxName(src: []const u8, at_index: u32) u32 {
    var s = Scanner{ .src = src, .index = at_index };
    // A JsxNamespacedName (`<svg:path>`, `xlink:href=`) is `ns ':' name` — at
    // most ONE colon, and only with a name right after it, so an attribute
    // value's `:` or a conditional's cannot be swallowed. Keeping it inside the
    // token is what makes the NAME `svg:path`, which is the key tsc looks up in
    // `JSX.IntrinsicElements`.
    var colon_used = false;
    while (s.index < src.len) {
        const c = src[s.index];
        if (isIdentCont(c) or c >= 0x80 or c == '-') {
            s.index += 1;
        } else if (c == ':' and !colon_used and s.index > at_index and
            (isIdentStart(s.at(s.index + 1)) or s.at(s.index + 1) >= 0x80))
        {
            colon_used = true;
            s.index += 1;
        } else if (c == '\\') {
            if (!s.consumeIdentifierEscape()) break;
        } else break;
    }
    return s.index;
}

/// The NAME an identifier token spells, with its `\uXXXX` / `\u{H+}` escapes
/// resolved to UTF-8 — tsc's `escapedText`, which is what every symbol table
/// is keyed by: `var А = 1;` declares `А`, and a later plain `А` is the
/// same name. Returns null when `text` carries no escape (the overwhelmingly
/// common case) so callers keep the zero-copy source slice, and also when the
/// decoded name would not fit `buf` or an escape is malformed — a name is
/// then filed under its raw spelling, which is exactly today's behavior.
///
/// A decoded name is never longer than its source (`\uXXXX` is six bytes and
/// yields at most four), so `buf.len >= text.len` always suffices. The
/// `\` probe is a single scan of a short slice on a path that already
/// rescans the token to find its end.
///
/// `max_unescaped_ident` is the stack buffer every caller uses: an escaped
/// identifier longer than that keeps its raw spelling.
pub const max_unescaped_ident = 512;

pub fn unescapeIdentifier(text: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return null;
    if (buf.len < text.len) return null;
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\') {
            buf[out] = text[i];
            out += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= text.len or text[i + 1] != 'u') return null;
        var j = i + 2;
        var cp: u32 = 0;
        if (j < text.len and text[j] == '{') {
            j += 1;
            var digits: u32 = 0;
            while (j < text.len and isHexDigit(text[j])) : (j += 1) {
                cp = cp *% 16 + hexValue(text[j]);
                digits += 1;
            }
            if (digits == 0 or j >= text.len or text[j] != '}') return null;
            j += 1;
        } else {
            if (j + 4 > text.len) return null;
            for (text[j .. j + 4]) |h| {
                if (!isHexDigit(h)) return null;
                cp = cp * 16 + hexValue(h);
            }
            j += 4;
        }
        // A lone surrogate or an out-of-range code point has no UTF-8 form;
        // leave the whole name raw rather than inventing bytes for it.
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
        const n = std.unicode.utf8Encode(@intCast(cp), buf[out..]) catch return null;
        out += n;
        i = j;
    }
    return buf[0..out];
}

fn hexValue(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    return (c | 0x20) - 'a' + 10;
}

/// Scan a JSX attribute's quoted value starting at the quote at `at`,
/// returning the offset just past the closing quote (or end of file if
/// there is none). A JSX attribute string runs to the matching quote and
/// nothing else: raw line breaks are content, and `\` is a literal byte,
/// not an escape (tsc: `scanString(/*jsxAttributeString*/ true)`).
/// Null when there is no closing quote before end of file — the caller
/// leaves the token alone so the ordinary unterminated-string diagnostic
/// still fires. Used only by the parser's `rescanJsxAttributeString`.
pub fn scanJsxString(src: []const u8, at_index: u32) ?u32 {
    if (at_index >= src.len) return null;
    const quote = src[at_index];
    var i = at_index + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == quote) return i + 1;
    }
    return null;
}

/// Recompute a token's end offset by rescanning it from its start.
/// O(token length); used for lazy spans so we never store ends.
pub fn tokenEnd(src: []const u8, tag: Tag, start: u32) u32 {
    switch (tag) {
        .eof => return start,
        // Identifiers are the overwhelming majority of the rescans the checker
        // asks for (`atomOfToken` reaches every name through `tokenSlice`), and
        // the general `next()` path pays two things they cannot need: the
        // leading-trivia loop — a token start is never trivia — and the
        // `keyword_map` probe, whose answer is already known to be "no keyword"
        // because the token was tagged `.identifier` at scan time. Consuming
        // identifier-continue bytes directly is the whole job.
        .identifier => {
            var s = Scanner{ .src = src, .index = start };
            if (start < src.len and src[start] == '\\') {
                // A `\uXXXX`-introduced identifier: consume the escape exactly
                // as `next()` does, then fall into the same rest loop.
                if (!s.consumeIdentifierEscape()) return s.next().end;
            } else if (start < src.len) {
                s.index +|= identStepLen(src, start);
            } else {
                s.index +|= 1;
            }
            _ = s.identifierRest();
            return s.index;
        },
        // These consume to end of file by construction.
        .binary_content, .unterminated_template, .unterminated_comment => {
            // A middle/tail rescan can also produce unterminated_template
            // starting at `}`; either way it ends at EOF.
            return @intCast(src.len);
        },
        .template_middle, .template_tail => {
            var s = Scanner{ .src = src, .index = start };
            _ = s.scanTemplate(false);
            return s.index;
        },
        .regexp_literal, .unterminated_regexp_literal => {
            var s = Scanner{ .src = src, .index = start };
            _ = s.scanRegex();
            return s.index;
        },
        .jsx_text => {
            var s = Scanner{ .src = src, .index = start };
            return s.scanJsxChild(start).end;
        },
        .jsx_name => return scanJsxName(src, start),
        // Only ever produced for a terminated string (see the parser's
        // `rescanJsxAttributeString`); the fallback keeps this total.
        .jsx_string => return scanJsxString(src, start) orelse @as(u32, @intCast(src.len)),
        else => {
            var s = Scanner{ .src = src, .index = start };
            return s.next().end;
        },
    }
}

/// Struct-of-arrays token store: 1-byte tag + 4-byte start per
/// token; the preceded-by-newline flag lives in bit 31 of the start word.
/// The stream always ends with a `.eof` token.
pub const Tokens = struct {
    tags: []const Tag,
    starts: []const u32,

    pub const newline_flag: u32 = 1 << 31;
    pub const start_mask: u32 = newline_flag - 1;

    pub fn len(t: *const Tokens) usize {
        return t.tags.len;
    }

    pub fn tag(t: *const Tokens, i: usize) Tag {
        return t.tags[i];
    }

    pub fn start(t: *const Tokens, i: usize) u32 {
        return t.starts[i] & start_mask;
    }

    /// Only the scanner's own ASI test reads this; the parser keeps the flag
    /// in its own token store and unpacks it there.
    fn precededByNewline(t: *const Tokens, i: usize) bool {
        return t.starts[i] & newline_flag != 0;
    }

    /// Recompute the end offset of token `i` by rescanning it in `src`.
    pub fn end(t: *const Tokens, src: []const u8, i: usize) u32 {
        return tokenEnd(src, t.tags[i], t.start(i));
    }

    /// Exact bytes held by the token arrays (5 bytes/token).
    pub fn byteSize(t: *const Tokens) usize {
        return t.tags.len * @sizeOf(Tag) + t.starts.len * @sizeOf(u32);
    }

    /// The parser owns its token arrays in its own arena; only the scanner's
    /// tests allocate a `Tokens` that has to be freed.
    fn deinit(t: *Tokens, alloc: Allocator) void {
        alloc.free(t.tags);
        alloc.free(t.starts);
        t.* = undefined;
    }
};

pub const Tag = enum(u8) {
    // --- sentinels & error tokens ---------------------------------------
    eof,
    /// Byte(s) that start no token (e.g. stray `\` or control chars).
    unknown,
    /// `#!` anywhere but the very first line, where it is shebang trivia
    /// (`Scanner.init` consumes that one). tsc's scanner has the same special
    /// case and answers TS18026 rather than the generic invalid-character.
    hash_bang,
    /// A byte that begins no valid UTF-8 sequence, i.e. the file is not text.
    /// Consumes the whole rest of the file, exactly as tsc does: tsc decodes
    /// the source up front, so a malformed sequence becomes U+FFFD, and the
    /// scanner answers `File appears to be binary.` once and stops.
    binary_content,
    unterminated_string_literal,
    /// Unterminated template literal (head, middle/tail, or no-substitution).
    unterminated_template,
    unterminated_regexp_literal,
    /// Unterminated block comment; consumes to end of file.
    unterminated_comment,

    // --- literals --------------------------------------------------------
    numeric_literal,
    bigint_literal,
    string_literal,
    regexp_literal,
    no_substitution_template_literal,
    /// `` `text${ ``
    template_head,
    /// `}text${`
    template_middle,
    /// `` }text` ``
    template_tail,

    identifier,
    /// `#name`
    private_identifier,
    /// JSX children text between tags (`<a>THIS<b/></a>`). Scanned only in
    /// `.tsx` files, by the parser-driven `scanJsxChild` path.
    jsx_text,
    /// A hyphenated JSX name (`data-foo`, `aria-label`, `<my-elem>`): an
    /// identifier run spanning `-`. Produced only by the parser's
    /// `rescanJsxName` entry point in `.tsx` files, never by `next`.
    jsx_name,
    /// A JSX attribute's quoted value (`title="a\nb"`). Unlike an ordinary
    /// string it may contain raw line breaks and treats `\` as a literal
    /// byte. Produced only by the parser's `rescanJsxAttributeString` entry
    /// point in `.tsx` files, never by `next`.
    jsx_string,

    // --- punctuation -------------------------------------------------------
    l_brace,
    r_brace,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    dot,
    dot_dot_dot,
    semicolon,
    comma,
    lt,
    gt,
    lt_eq,
    gt_eq,
    eq_eq,
    bang_eq,
    eq_eq_eq,
    bang_eq_eq,
    arrow,
    plus,
    minus,
    asterisk,
    asterisk_asterisk,
    slash,
    percent,
    plus_plus,
    minus_minus,
    lt_lt,
    gt_gt,
    gt_gt_gt,
    amp,
    pipe,
    caret,
    bang,
    tilde,
    amp_amp,
    pipe_pipe,
    question_question,
    question,
    question_dot,
    colon,
    at,
    eq,
    plus_eq,
    minus_eq,
    asterisk_eq,
    asterisk_asterisk_eq,
    slash_eq,
    percent_eq,
    lt_lt_eq,
    gt_gt_eq,
    gt_gt_gt_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    amp_amp_eq,
    pipe_pipe_eq,
    question_question_eq,

    // --- reserved keywords (always keywords) -------------------------------
    keyword_break,
    keyword_case,
    keyword_catch,
    keyword_class,
    keyword_const,
    keyword_continue,
    keyword_debugger,
    keyword_default,
    keyword_delete,
    keyword_do,
    keyword_else,
    keyword_enum,
    keyword_export,
    keyword_extends,
    keyword_false,
    keyword_finally,
    keyword_for,
    keyword_function,
    keyword_if,
    keyword_import,
    keyword_in,
    keyword_instanceof,
    keyword_new,
    keyword_null,
    keyword_return,
    keyword_super,
    keyword_switch,
    keyword_this,
    keyword_throw,
    keyword_true,
    keyword_try,
    keyword_typeof,
    keyword_var,
    keyword_void,
    keyword_while,
    keyword_with,

    // --- strict-mode reserved words ----------------------------------------
    keyword_implements,
    keyword_interface,
    keyword_let,
    keyword_package,
    keyword_private,
    keyword_protected,
    keyword_public,
    keyword_static,
    keyword_yield,

    // --- contextual keywords (identifiers unless grammar says otherwise) ----
    keyword_abstract,
    keyword_accessor,
    keyword_any,
    keyword_as,
    keyword_assert,
    keyword_asserts,
    keyword_async,
    keyword_await,
    keyword_bigint,
    keyword_boolean,
    keyword_constructor,
    keyword_declare,
    keyword_from,
    keyword_get,
    keyword_global,
    keyword_infer,
    keyword_intrinsic,
    keyword_is,
    keyword_keyof,
    keyword_module,
    keyword_namespace,
    keyword_never,
    keyword_number,
    keyword_object,
    keyword_of,
    keyword_out,
    keyword_override,
    keyword_readonly,
    keyword_require,
    keyword_satisfies,
    keyword_set,
    keyword_string,
    keyword_symbol,
    keyword_type,
    keyword_undefined,
    keyword_unique,
    keyword_unknown,
    keyword_using,

    /// Any keyword tag (reserved, strict-reserved, or contextual).
    pub fn isKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_break) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_using);
    }

    /// Reserved words that can never be identifiers. (Classification kept for
    /// symmetry with the other three predicates; only the tests read it.)
    fn isReservedKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_break) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_with);
    }

    /// Reserved only in strict mode (ztsc is always-strict, but these are
    /// still legal as e.g. property names).
    pub fn isStrictReservedKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_implements) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_yield);
    }

    /// Contextual keywords: the parser treats these as identifiers unless the
    /// grammar position says otherwise (`type`, `readonly`, `satisfies`, ...).
    pub fn isContextualKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_abstract) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_using);
    }
};

/// A scanned token. The SoA store (`Tokens`) keeps only `tag` and
/// `start`+newline flag; `end` is available here at scan time for free and
/// recomputable later via `tokenEnd`.
pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,
    /// True if a line break occurred in the trivia before this token
    /// (drives automatic semicolon insertion in the parser).
    newline_before: bool,
};

/// Low-level pull scanner (tsc-scanner-shaped: `next` plus rescan entry
/// points for the parser-context-dependent tokens).
pub const Scanner = struct {
    src: []const u8,
    index: u32 = 0,

    /// Skips a UTF-8 BOM and a `#!` shebang line (only at the very start).
    pub fn init(src: []const u8) Scanner {
        std.debug.assert(src.len <= max_source_len);
        var s: Scanner = .{ .src = src };
        if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) {
            s.index = 3;
        }
        if (s.at(s.index) == '#' and s.at(s.index + 1) == '!') {
            while (s.index < src.len and src[s.index] != '\n' and src[s.index] != '\r') {
                s.index += 1;
            }
        }
        return s;
    }

    /// Scan the next token, skipping trivia (whitespace, comments).
    /// Always terminates; every non-eof token consumes at least one byte.
    pub fn next(s: *Scanner) Token {
        var nl = false;
        // Trivia loop.
        while (s.index < s.src.len) {
            switch (s.src[s.index]) {
                ' ', '\t', 0x0B, 0x0C => s.index += 1,
                '\n', '\r' => {
                    nl = true;
                    s.index += 1;
                },
                '/' => {
                    const c1 = s.at(s.index + 1);
                    if (c1 == '/') {
                        s.index += 2;
                        // A line comment ends at any LineTerminator, U+2028 and
                        // U+2029 included — reading past one swallows the rest
                        // of the file. ASCII keeps its two compares; only a byte
                        // >= 0x80 pays for the question.
                        while (s.index < s.src.len) {
                            const c = s.src[s.index];
                            if (c == '\n' or c == '\r') break;
                            if (c >= 0x80) {
                                if (unicodeTrivia(s.src, s.index)) |t| {
                                    if (t.line_break) break;
                                    s.index += t.len;
                                    continue;
                                }
                            }
                            s.index += 1;
                        }
                    } else if (c1 == '*') {
                        const comment_start = s.index;
                        s.index += 2;
                        var closed = false;
                        while (s.index < s.src.len) : (s.index += 1) {
                            const c = s.src[s.index];
                            if (c == '\n' or c == '\r') {
                                nl = true;
                            } else if (c == '*' and s.at(s.index + 1) == '/') {
                                s.index += 2;
                                closed = true;
                                break;
                            }
                        }
                        if (!closed) return .{
                            .tag = .unterminated_comment,
                            .start = comment_start,
                            .end = s.index,
                            .newline_before = nl,
                        };
                    } else break;
                },
                else => {
                    // Non-ASCII trivia: NBSP, the EN/EM space family, U+3000, a
                    // stray BOM (horizontal space), U+2028/U+2029 (line
                    // terminators). Every other byte >= 0x80 starts a token.
                    if (s.src[s.index] < 0x80) break;
                    const t = unicodeTrivia(s.src, s.index) orelse break;
                    if (t.line_break) nl = true;
                    s.index += t.len;
                },
            }
        }
        const start = s.index;
        if (start >= s.src.len) {
            return .{ .tag = .eof, .start = start, .end = start, .newline_before = nl };
        }
        const tag = s.scanToken();
        std.debug.assert(s.index > start); // progress guarantee
        return .{ .tag = tag, .start = start, .end = s.index, .newline_before = nl };
    }

    /// Rescan a `/` or `/=` token as a regular expression literal. The parser
    /// calls this when the grammar expects an expression (tsc:
    /// `reScanSlashToken`). Resets the scanner to just after the regex.
    pub fn reScanSlashAsRegex(s: *Scanner, slash: Token) Token {
        std.debug.assert(slash.tag == .slash or slash.tag == .slash_eq);
        s.index = slash.start;
        const tag = s.scanRegex();
        return .{ .tag = tag, .start = slash.start, .end = s.index, .newline_before = slash.newline_before };
    }

    /// Rescan a `}` token as a template middle/tail part. The parser calls
    /// this when the `}` closes a template substitution (tsc:
    /// `reScanTemplateToken`).
    pub fn reScanTemplateToken(s: *Scanner, rbrace: Token) Token {
        std.debug.assert(rbrace.tag == .r_brace);
        s.index = rbrace.start;
        const tag = s.scanTemplate(false);
        return .{ .tag = tag, .start = rbrace.start, .end = s.index, .newline_before = rbrace.newline_before };
    }

    /// Scan one JSX child starting at `at`: a `<` (`.lt`) or `{` (`.l_brace`)
    /// delimiter, `.eof`, or otherwise the run of children text up to the next
    /// delimiter as a single `.jsx_text` token (tsc: `scanJsxToken`). The
    /// parser drives this directly (not through `next`), resetting `s.index`
    /// to the position after the last consumed token first — JSX text is not
    /// trivia-skipped, so lookahead scanned in normal mode must be dropped.
    pub fn scanJsxChild(s: *Scanner, at_index: u32) Token {
        s.index = at_index;
        if (s.index >= s.src.len) {
            return .{ .tag = .eof, .start = s.index, .end = s.index, .newline_before = false };
        }
        switch (s.src[s.index]) {
            '<' => return .{ .tag = .lt, .start = s.index, .end = s.punctEnd(1), .newline_before = false },
            '{' => return .{ .tag = .l_brace, .start = s.index, .end = s.punctEnd(1), .newline_before = false },
            else => {},
        }
        const start = s.index;
        while (s.index < s.src.len and s.src[s.index] != '<' and s.src[s.index] != '{') {
            s.index += 1;
        }
        return .{ .tag = .jsx_text, .start = start, .end = s.index, .newline_before = false };
    }

    inline fn punctEnd(s: *Scanner, len: u32) u32 {
        s.index += len;
        return s.index;
    }

    // --- internals -----------------------------------------------------

    /// Byte at absolute offset `i`, or 0 past the end. Only used for
    /// lookahead comparisons, never to drive loop progress on its own.
    inline fn at(s: *const Scanner, i: u32) u8 {
        return if (i < s.src.len) s.src[i] else 0;
    }

    inline fn punct(s: *Scanner, len: u32, tag: Tag) Tag {
        s.index += len;
        return tag;
    }

    /// Scan one non-trivia token; s.index is at its (in-bounds) first byte.
    fn scanToken(s: *Scanner) Tag {
        const c = s.src[s.index];
        switch (c) {
            '{' => return s.punct(1, .l_brace),
            '}' => return s.punct(1, .r_brace),
            '(' => return s.punct(1, .l_paren),
            ')' => return s.punct(1, .r_paren),
            '[' => return s.punct(1, .l_bracket),
            ']' => return s.punct(1, .r_bracket),
            ';' => return s.punct(1, .semicolon),
            ',' => return s.punct(1, .comma),
            ':' => return s.punct(1, .colon),
            '@' => return s.punct(1, .at),
            '~' => return s.punct(1, .tilde),
            '.' => {
                if (isDigit(s.at(s.index + 1))) return s.scanNumber();
                if (s.at(s.index + 1) == '.' and s.at(s.index + 2) == '.') {
                    return s.punct(3, .dot_dot_dot);
                }
                return s.punct(1, .dot);
            },
            '<' => {
                if (s.at(s.index + 1) == '<') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .lt_lt_eq);
                    return s.punct(2, .lt_lt);
                }
                if (s.at(s.index + 1) == '=') return s.punct(2, .lt_eq);
                return s.punct(1, .lt);
            },
            '>' => {
                if (s.at(s.index + 1) == '>') {
                    if (s.at(s.index + 2) == '>') {
                        if (s.at(s.index + 3) == '=') return s.punct(4, .gt_gt_gt_eq);
                        return s.punct(3, .gt_gt_gt);
                    }
                    if (s.at(s.index + 2) == '=') return s.punct(3, .gt_gt_eq);
                    return s.punct(2, .gt_gt);
                }
                if (s.at(s.index + 1) == '=') return s.punct(2, .gt_eq);
                return s.punct(1, .gt);
            },
            '=' => {
                if (s.at(s.index + 1) == '=') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .eq_eq_eq);
                    return s.punct(2, .eq_eq);
                }
                if (s.at(s.index + 1) == '>') return s.punct(2, .arrow);
                return s.punct(1, .eq);
            },
            '!' => {
                if (s.at(s.index + 1) == '=') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .bang_eq_eq);
                    return s.punct(2, .bang_eq);
                }
                return s.punct(1, .bang);
            },
            '+' => {
                if (s.at(s.index + 1) == '+') return s.punct(2, .plus_plus);
                if (s.at(s.index + 1) == '=') return s.punct(2, .plus_eq);
                return s.punct(1, .plus);
            },
            '-' => {
                if (s.at(s.index + 1) == '-') return s.punct(2, .minus_minus);
                if (s.at(s.index + 1) == '=') return s.punct(2, .minus_eq);
                return s.punct(1, .minus);
            },
            '*' => {
                if (s.at(s.index + 1) == '*') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .asterisk_asterisk_eq);
                    return s.punct(2, .asterisk_asterisk);
                }
                if (s.at(s.index + 1) == '=') return s.punct(2, .asterisk_eq);
                return s.punct(1, .asterisk);
            },
            '/' => {
                // Comments were consumed as trivia; this is an operator.
                if (s.at(s.index + 1) == '=') return s.punct(2, .slash_eq);
                return s.punct(1, .slash);
            },
            '%' => {
                if (s.at(s.index + 1) == '=') return s.punct(2, .percent_eq);
                return s.punct(1, .percent);
            },
            '&' => {
                if (s.at(s.index + 1) == '&') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .amp_amp_eq);
                    return s.punct(2, .amp_amp);
                }
                if (s.at(s.index + 1) == '=') return s.punct(2, .amp_eq);
                return s.punct(1, .amp);
            },
            '|' => {
                if (s.at(s.index + 1) == '|') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .pipe_pipe_eq);
                    return s.punct(2, .pipe_pipe);
                }
                if (s.at(s.index + 1) == '=') return s.punct(2, .pipe_eq);
                return s.punct(1, .pipe);
            },
            '^' => {
                if (s.at(s.index + 1) == '=') return s.punct(2, .caret_eq);
                return s.punct(1, .caret);
            },
            '?' => {
                // `?.` — but `a?.5:b` is a conditional, so `?.<digit>` stays `?`.
                if (s.at(s.index + 1) == '.' and !isDigit(s.at(s.index + 2))) {
                    return s.punct(2, .question_dot);
                }
                if (s.at(s.index + 1) == '?') {
                    if (s.at(s.index + 2) == '=') return s.punct(3, .question_question_eq);
                    return s.punct(2, .question_question);
                }
                return s.punct(1, .question);
            },
            '\'', '"' => return s.scanString(c),
            '`' => return s.scanTemplate(true),
            '0'...'9' => return s.scanNumber(),
            'a'...'z', 'A'...'Z', '_', '$' => return s.scanIdentifierOrKeyword(),
            '#' => {
                const c1 = s.at(s.index + 1);
                if (isIdentStart(c1) or c1 >= 0x80 or c1 == '\\') {
                    s.index += 1;
                    _ = s.identifierRest();
                    return .private_identifier;
                }
                if (c1 == '!') return s.punct(2, .hash_bang);
                return s.punct(1, .unknown);
            },
            '\\' => {
                if (s.consumeIdentifierEscape()) {
                    _ = s.identifierRest();
                    return .identifier; // escaped text never matches a keyword
                }
                return s.punct(1, .unknown);
            },
            else => {
                if (c >= 0x80) {
                    if (isBinaryContent(s.src, s.index)) {
                        s.index = @intCast(s.src.len);
                        return .binary_content;
                    }
                    return s.scanIdentifierOrKeyword();
                }
                return s.punct(1, .unknown);
            },
        }
    }

    fn scanIdentifierOrKeyword(s: *Scanner) Tag {
        const start = s.index;
        // First byte validated by the caller. A non-ASCII one carries its whole
        // UTF-8 sequence: `identifierRest` validates the byte it lands on, so
        // stepping one byte into a multi-byte character would leave it on a
        // continuation byte and end the identifier there.
        s.index += identStepLen(s.src, s.index);
        const has_escape = s.identifierRest();
        if (!has_escape) {
            if (keyword_map.get(s.src[start..s.index])) |kw| return kw;
        }
        return .identifier;
    }

    /// Consume identifier-continue bytes (ASCII fast path; any byte >= 0x80;
    /// `\u` escapes). Returns whether an escape was consumed.
    fn identifierRest(s: *Scanner) bool {
        var has_escape = false;
        while (s.index < s.src.len) {
            const c = s.src[s.index];
            if (c >= 0x80) {
                // Any well-formed non-ASCII sequence continues the name (ztsc
                // does not table ID_Continue); binary content ends it, so the
                // next `next()` reaches the `binary_content` arm and the file
                // gets tsc's single "appears to be binary" answer. Trivia ends
                // it too — otherwise `x<NBSP>= 1` is one identifier.
                if (isBinaryContent(s.src, s.index)) break;
                if (unicodeTrivia(s.src, s.index) != null) break;
                s.index += utf8SeqLen(s.src, s.index);
            } else if (isIdentCont(c)) {
                s.index += 1;
            } else if (c == '\\') {
                if (!s.consumeIdentifierEscape()) break;
                has_escape = true;
            } else break;
        }
        return has_escape;
    }

    /// At a `\`: consume a well-formed `\uXXXX` or `\u{H+}` escape and return
    /// true, or leave the index on the backslash and return false.
    fn consumeIdentifierEscape(s: *Scanner) bool {
        if (s.at(s.index + 1) != 'u') return false;
        var i = s.index + 2;
        if (s.at(i) == '{') {
            i += 1;
            var digits: u32 = 0;
            while (isHexDigit(s.at(i))) : (i += 1) digits += 1;
            if (digits == 0 or s.at(i) != '}') return false;
            s.index = i + 1;
            return true;
        }
        var k: u32 = 0;
        while (k < 4) : (k += 1) {
            if (!isHexDigit(s.at(i + k))) return false;
        }
        s.index = i + 4;
        return true;
    }

    fn scanString(s: *Scanner, quote: u8) Tag {
        s.index += 1;
        while (s.index < s.src.len) {
            const c = s.src[s.index];
            if (c == quote) {
                s.index += 1;
                return .string_literal;
            }
            if (c == '\\') {
                s.index += 1;
                if (s.index < s.src.len) {
                    // Line continuation: \<CR><LF> is one escape.
                    if (s.src[s.index] == '\r' and s.at(s.index + 1) == '\n') {
                        s.index += 2;
                    } else {
                        s.index += 1;
                    }
                }
                continue;
            }
            if (c == '\n' or c == '\r') return .unterminated_string_literal;
            s.index += 1;
        }
        return .unterminated_string_literal;
    }

    /// Scan a template part. `from_backtick` selects head/no-substitution
    /// (index at `` ` ``) vs middle/tail (index at `}`, rescan path).
    fn scanTemplate(s: *Scanner, from_backtick: bool) Tag {
        s.index += 1; // past ` or }
        while (s.index < s.src.len) {
            const c = s.src[s.index];
            if (c == '`') {
                s.index += 1;
                return if (from_backtick) .no_substitution_template_literal else .template_tail;
            }
            if (c == '$' and s.at(s.index + 1) == '{') {
                s.index += 2;
                return if (from_backtick) .template_head else .template_middle;
            }
            if (c == '\\') {
                s.index += 1;
                if (s.index < s.src.len) s.index += 1;
                continue;
            }
            s.index += 1; // newlines are legal inside templates
        }
        return .unterminated_template;
    }

    /// Scan a regex literal; index is at the opening `/`.
    fn scanRegex(s: *Scanner) Tag {
        s.index += 1;
        var in_class = false;
        while (s.index < s.src.len) {
            const c = s.src[s.index];
            if (c == '\n' or c == '\r') return .unterminated_regexp_literal;
            switch (c) {
                '\\' => {
                    s.index += 1;
                    if (s.index < s.src.len and s.src[s.index] != '\n' and s.src[s.index] != '\r') {
                        s.index += 1;
                    }
                },
                '[' => {
                    in_class = true;
                    s.index += 1;
                },
                ']' => {
                    in_class = false;
                    s.index += 1;
                },
                '/' => {
                    s.index += 1;
                    if (!in_class) {
                        // Flags: identifier-continue characters.
                        while (s.index < s.src.len and
                            (isIdentCont(s.src[s.index]) or s.src[s.index] >= 0x80))
                        {
                            s.index += 1;
                        }
                        return .regexp_literal;
                    }
                },
                else => s.index += 1,
            }
        }
        return .unterminated_regexp_literal;
    }

    const DigitBase = enum { bin, oct, dec, hex };

    fn skipDigits(s: *Scanner, base: DigitBase) void {
        while (s.index < s.src.len) {
            const c = s.src[s.index];
            const ok = switch (base) {
                .bin => c == '0' or c == '1',
                .oct => c >= '0' and c <= '7',
                .dec => isDigit(c),
                .hex => isHexDigit(c),
            };
            // Separators are consumed liberally; placement is validated later.
            if (!ok and c != '_') break;
            s.index += 1;
        }
    }

    fn bigintSuffix(s: *Scanner) Tag {
        if (s.at(s.index) == 'n') {
            s.index += 1;
            return .bigint_literal;
        }
        return .numeric_literal;
    }

    /// Scan a numeric literal; index is at a digit, or at `.` with a digit
    /// following.
    fn scanNumber(s: *Scanner) Tag {
        if (s.src[s.index] == '0') {
            switch (s.at(s.index + 1)) {
                'x', 'X' => {
                    s.index += 2;
                    s.skipDigits(.hex);
                    return s.bigintSuffix();
                },
                'o', 'O' => {
                    s.index += 2;
                    s.skipDigits(.oct);
                    return s.bigintSuffix();
                },
                'b', 'B' => {
                    s.index += 2;
                    s.skipDigits(.bin);
                    return s.bigintSuffix();
                },
                else => {},
            }
        }
        var integer = true;
        s.skipDigits(.dec); // no-op when starting at '.'
        if (s.at(s.index) == '.') {
            integer = false;
            s.index += 1;
            s.skipDigits(.dec);
        }
        if (s.at(s.index) == 'e' or s.at(s.index) == 'E') {
            var i = s.index + 1;
            if (s.at(i) == '+' or s.at(i) == '-') i += 1;
            // The marker and its sign belong to the LITERAL whether or not a
            // digit follows: tsc's `scanNumber` consumes both unconditionally
            // and, when `scanExponentDigits` comes back empty, reports
            // "Digit expected" (TS1124 — `literals.checkNumeric`) at the
            // character that should have been one, keeping the value it had
            // before the `e`. Stopping the token short instead made `1e` scan
            // as `1` plus an identifier `e` and answer TS1351 one column early.
            s.index = i;
            // Scientific notation is never an integer form, so `3en` is `3e`
            // followed by an identifier rather than a BigInt.
            integer = false;
            s.skipDigits(.dec);
        }
        // A BigInt suffix is only VALID on an integer form, but tsc consumes a
        // lone one either way: `checkForIdentifierStartAfterNumericLiteral`
        // reports TS1353 (`1.5n`) or TS1352 (`3en`) and, unlike the abutting-
        // identifier case, does not rewind — so the `n` belongs to this token
        // and `1.5n[x]` reads as one element access rather than two statements.
        // A longer run (`1.5nfoo`) is an abutting identifier and stays its own
        // token. `literals.checkNumeric` reports off the resulting text.
        if (integer) return s.bigintSuffix();
        if (s.at(s.index) == 'n' and !isIdentCont(s.at(s.index + 1))) s.index += 1;
        return .numeric_literal;
    }
};

// ---------------------------------------------------------------------------
// private implementation
// ---------------------------------------------------------------------------

const keyword_map = std.StaticStringMap(Tag).initComptime(.{
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "catch", .keyword_catch },
    .{ "class", .keyword_class },
    .{ "const", .keyword_const },
    .{ "continue", .keyword_continue },
    .{ "debugger", .keyword_debugger },
    .{ "default", .keyword_default },
    .{ "delete", .keyword_delete },
    .{ "do", .keyword_do },
    .{ "else", .keyword_else },
    .{ "enum", .keyword_enum },
    .{ "export", .keyword_export },
    .{ "extends", .keyword_extends },
    .{ "false", .keyword_false },
    .{ "finally", .keyword_finally },
    .{ "for", .keyword_for },
    .{ "function", .keyword_function },
    .{ "if", .keyword_if },
    .{ "import", .keyword_import },
    .{ "in", .keyword_in },
    .{ "instanceof", .keyword_instanceof },
    .{ "new", .keyword_new },
    .{ "null", .keyword_null },
    .{ "return", .keyword_return },
    .{ "super", .keyword_super },
    .{ "switch", .keyword_switch },
    .{ "this", .keyword_this },
    .{ "throw", .keyword_throw },
    .{ "true", .keyword_true },
    .{ "try", .keyword_try },
    .{ "typeof", .keyword_typeof },
    .{ "var", .keyword_var },
    .{ "void", .keyword_void },
    .{ "while", .keyword_while },
    .{ "with", .keyword_with },
    .{ "implements", .keyword_implements },
    .{ "interface", .keyword_interface },
    .{ "let", .keyword_let },
    .{ "package", .keyword_package },
    .{ "private", .keyword_private },
    .{ "protected", .keyword_protected },
    .{ "public", .keyword_public },
    .{ "static", .keyword_static },
    .{ "yield", .keyword_yield },
    .{ "abstract", .keyword_abstract },
    .{ "accessor", .keyword_accessor },
    .{ "any", .keyword_any },
    .{ "as", .keyword_as },
    .{ "assert", .keyword_assert },
    .{ "asserts", .keyword_asserts },
    .{ "async", .keyword_async },
    .{ "await", .keyword_await },
    .{ "bigint", .keyword_bigint },
    .{ "boolean", .keyword_boolean },
    .{ "constructor", .keyword_constructor },
    .{ "declare", .keyword_declare },
    .{ "from", .keyword_from },
    .{ "get", .keyword_get },
    .{ "global", .keyword_global },
    .{ "infer", .keyword_infer },
    .{ "intrinsic", .keyword_intrinsic },
    .{ "is", .keyword_is },
    .{ "keyof", .keyword_keyof },
    .{ "module", .keyword_module },
    .{ "namespace", .keyword_namespace },
    .{ "never", .keyword_never },
    .{ "number", .keyword_number },
    .{ "object", .keyword_object },
    .{ "of", .keyword_of },
    .{ "out", .keyword_out },
    .{ "override", .keyword_override },
    .{ "readonly", .keyword_readonly },
    .{ "require", .keyword_require },
    .{ "satisfies", .keyword_satisfies },
    .{ "set", .keyword_set },
    .{ "string", .keyword_string },
    .{ "symbol", .keyword_symbol },
    .{ "type", .keyword_type },
    .{ "undefined", .keyword_undefined },
    .{ "unique", .keyword_unique },
    .{ "unknown", .keyword_unknown },
    .{ "using", .keyword_using },
});

// ---------------------------------------------------------------------------
// character classes
// ---------------------------------------------------------------------------

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Whether the character at `i` (a byte >= 0x80) means "this file is not text".
///
/// tsc decodes the whole source before scanning, so its condition is on the
/// decoded CHARACTER: `U+FFFD`. That is reachable two ways, and both count —
/// bytes that begin no valid UTF-8 sequence (tsc's decoder substitutes U+FFFD
/// for them), and a well-formed `EF BF BD` that spells U+FFFD outright. The
/// second is not hypothetical: the corpus harness decodes each case with
/// replacement, so `compiler/TransportStream.ts` — 550 bytes of binary junk —
/// arrives as valid UTF-8 containing one U+FFFD, and tsc answers TS1490 for it.
fn isBinaryContent(src: []const u8, i: u32) bool {
    if (utf8SeqLen(src, i) == 0) return true;
    return src[i] == 0xEF and @as(usize, i) + 2 < src.len and
        src[i + 1] == 0xBF and src[i + 2] == 0xBD;
}

/// How far to step over the FIRST character of an identifier: one byte for
/// ASCII, the whole UTF-8 sequence for anything else, and one byte for a
/// malformed sequence (so the caller still makes progress; `identifierRest`
/// then ends the name and `next` reaches the binary-content arm).
fn identStepLen(src: []const u8, i: u32) u32 {
    if (src[i] < 0x80) return 1;
    const n = utf8SeqLen(src, i);
    return if (n == 0) 1 else n;
}

/// Length of the UTF-8 sequence starting at `i`, or 0 when the bytes there are
/// not a well-formed one (bad lead byte, missing/!0b10 continuation, truncated
/// at end of input, overlong, surrogate, or above U+10FFFF).
///
/// Only ever called on a byte >= 0x80, so the ASCII scanning path pays nothing.
/// tsc gets this for free by decoding the whole file into UTF-16 up front; ztsc
/// scans the bytes, so the one place that needs to know text from binary asks
/// here.
fn utf8SeqLen(src: []const u8, i: u32) u3 {
    const c0 = src[i];
    const n: u3 = switch (c0) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return 0, // continuation byte, overlong C0/C1, or >= 0xF5
    };
    if (@as(usize, i) + n > src.len) return 0;
    for (src[i + 1 ..][0 .. n - 1]) |c| {
        if (c & 0xC0 != 0x80) return 0;
    }
    // Reject the ranges a bare lead-byte test lets through: overlong 3-byte
    // forms, the UTF-16 surrogate block, and code points past U+10FFFF.
    const c1 = src[i + 1];
    switch (c0) {
        0xE0 => if (c1 < 0xA0) return 0,
        0xED => if (c1 >= 0xA0) return 0,
        0xF0 => if (c1 < 0x90) return 0,
        0xF4 => if (c1 >= 0x90) return 0,
        else => {},
    }
    return n;
}

inline fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c | 0x20) >= 'a' and (c | 0x20) <= 'f';
}

/// One non-ASCII TRIVIA character: how many bytes it spans, and whether it is a
/// LINE TERMINATOR (which ends a line comment and arms ASI) rather than
/// horizontal space.
const UnicodeTrivia = struct { len: u3, line_break: bool };

/// The non-ASCII trivia character at `i` (a byte >= 0x80), or null when the
/// bytes there are part of a token. tsc's `isWhiteSpaceSingleLine` and
/// `isLineBreak` operate on a decoded UTF-16 file; ztsc scans bytes, so the two
/// sets are spelled out here as UTF-8 sequences:
///
///   - U+0085 NEL and U+00A0 NBSP                     `C2 85` / `C2 A0`
///   - U+1680 OGHAM SPACE MARK                        `E1 9A 80`
///   - U+2000..U+200A the EN/EM/THIN space family     `E2 80 80..8A`
///   - U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEP    `E2 80 A8` / `E2 80 A9`
///   - U+202F NARROW NBSP, U+205F MEDIUM MATH SPACE   `E2 80 AF` / `E2 81 9F`
///   - U+3000 IDEOGRAPHIC SPACE                       `E3 80 80`
///   - U+FEFF ZWNBSP (a BOM anywhere, not just first) `EF BB BF`
///
/// Only U+2028/U+2029 are line terminators — NEL is horizontal space to tsc, so
/// `return<NEL>0` is NOT subject to ASI (`compiler/fileWithNextLine3.ts`).
///
/// Without this the scanner read every one of these as an identifier byte, which
/// glued `<NBSP>var x<NBSP>= 1` into one name and answered TS1434/TS1351 where
/// tsc answers nothing at all. Called only for bytes >= 0x80, so ASCII scanning
/// pays a single compare that the existing `c >= 0x80` test already made.
pub fn unicodeTrivia(src: []const u8, i: u32) ?UnicodeTrivia {
    const rest = src[i..];
    if (rest.len < 2) return null;
    switch (rest[0]) {
        0xC2 => if (rest[1] == 0x85 or rest[1] == 0xA0) return .{ .len = 2, .line_break = false },
        0xE1 => if (rest.len >= 3 and rest[1] == 0x9A and rest[2] == 0x80) {
            return .{ .len = 3, .line_break = false };
        },
        0xE2 => {
            if (rest.len < 3) return null;
            if (rest[1] == 0x80) switch (rest[2]) {
                0x80...0x8A, 0xAF => return .{ .len = 3, .line_break = false },
                0xA8, 0xA9 => return .{ .len = 3, .line_break = true },
                else => {},
            };
            if (rest[1] == 0x81 and rest[2] == 0x9F) return .{ .len = 3, .line_break = false };
        },
        0xE3 => if (rest.len >= 3 and rest[1] == 0x80 and rest[2] == 0x80) {
            return .{ .len = 3, .line_break = false };
        },
        0xEF => if (rest.len >= 3 and rest[1] == 0xBB and rest[2] == 0xBF) {
            return .{ .len = 3, .line_break = false };
        },
        else => {},
    }
    return null;
}

inline fn isIdentStart(c: u8) bool {
    return ((c | 0x20) >= 'a' and (c | 0x20) <= 'z') or c == '_' or c == '$';
}

inline fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test-only whole-file driver: pull `Scanner.next()` in a loop into a
/// `Tokens` store, tracking template brace depth exactly and picking
/// regex-vs-division with the classic previous-token heuristic (division after
/// identifier-like tokens, literals, `)`, `]`, `++`, `--`; regex otherwise).
/// The parser does none of this — it asks for the rescans with real grammar
/// context — so the heuristic lives here, with the tests that need a stream.
fn tokenizeForTest(alloc: Allocator, src: []const u8) error{ OutOfMemory, SourceTooLarge }!Tokens {
    if (src.len > max_source_len) return error.SourceTooLarge;

    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(alloc);
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(alloc);

    // One entry per open template substitution: the count of unmatched `{`
    // inside it. A `}` at count 0 closes the substitution itself.
    var template_stack: std.ArrayList(u32) = .empty;
    defer template_stack.deinit(alloc);

    var s = Scanner.init(src);
    var prev_tag: Tag = .eof; // regex allowed at stream start
    while (true) {
        var tok = s.next();
        switch (tok.tag) {
            .slash, .slash_eq => {
                if (!endsExpression(prev_tag)) tok = s.reScanSlashAsRegex(tok);
            },
            .l_brace => {
                if (template_stack.items.len > 0) {
                    template_stack.items[template_stack.items.len - 1] += 1;
                }
            },
            .r_brace => {
                if (template_stack.items.len > 0) {
                    const depth = &template_stack.items[template_stack.items.len - 1];
                    if (depth.* == 0) {
                        tok = s.reScanTemplateToken(tok);
                        switch (tok.tag) {
                            .template_middle => {}, // substitution list continues
                            .template_tail, .unterminated_template => _ = template_stack.pop(),
                            else => unreachable,
                        }
                    } else {
                        depth.* -= 1;
                    }
                }
            },
            .template_head => try template_stack.append(alloc, 0),
            else => {},
        }

        try tags.append(alloc, tok.tag);
        try starts.append(alloc, tok.start | @as(u32, if (tok.newline_before) Tokens.newline_flag else 0));
        if (tok.tag == .eof) break;
        prev_tag = tok.tag;
    }

    return .{
        .tags = try tags.toOwnedSlice(alloc),
        .starts = try starts.toOwnedSlice(alloc),
    };
}

/// True for tags that behave like an expression end for `tokenizeForTest`'s
/// regex-vs-division heuristic (division preferred after these).
fn endsExpression(tag: Tag) bool {
    return switch (tag) {
        .identifier,
        .private_identifier,
        .numeric_literal,
        .bigint_literal,
        .string_literal,
        .regexp_literal,
        .no_substitution_template_literal,
        .template_tail,
        .r_paren,
        .r_bracket,
        .plus_plus,
        .minus_minus,
        .keyword_this,
        .keyword_true,
        .keyword_false,
        .keyword_null,
        .keyword_super,
        => true,
        else => tag.isContextualKeyword(),
    };
}

fn expectTokens(src: []const u8, expected: []const Tag) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenizeForTest(arena.allocator(), src);
    try testing.expectEqualSlices(Tag, expected, toks.tags);
}

test "golden: simple declaration" {
    try expectTokens("const x = 1;", &.{
        .keyword_const, .identifier, .eq, .numeric_literal, .semicolon, .eof,
    });
}

test "golden: empty and trivia-only sources" {
    try expectTokens("", &.{.eof});
    try expectTokens("  // just a comment\n\t/* block */ ", &.{.eof});
}

test "golden: full operator soup" {
    try expectTokens(
        "?. ?? ??= **= <<= >>= >>>= &&= ||= ... => === !== == != <= >= << >> >>> ++ -- ** @ ~ ^ ^= &= |= %= a / b",
        &.{
            .question_dot,         .question_question, .question_question_eq,
            .asterisk_asterisk_eq, .lt_lt_eq,          .gt_gt_eq,
            .gt_gt_gt_eq,          .amp_amp_eq,        .pipe_pipe_eq,
            .dot_dot_dot,          .arrow,             .eq_eq_eq,
            .bang_eq_eq,           .eq_eq,             .bang_eq,
            .lt_eq,                .gt_eq,             .lt_lt,
            .gt_gt,                .gt_gt_gt,          .plus_plus,
            .minus_minus,          .asterisk_asterisk, .at,
            .tilde,                .caret,             .caret_eq,
            .amp_eq,               .pipe_eq,           .percent_eq,
            .identifier,           .slash,             .identifier,
            .eof,
        },
    );
}

test "golden: optional chaining vs conditional with numeric" {
    try expectTokens("a?.b", &.{ .identifier, .question_dot, .identifier, .eof });
    // `a?.5:b` is `a ? .5 : b`, not optional chaining.
    try expectTokens("a?.5:b", &.{
        .identifier, .question, .numeric_literal, .colon, .identifier, .eof,
    });
}

test "golden: template literals" {
    try expectTokens("`plain`", &.{ .no_substitution_template_literal, .eof });
    try expectTokens("`a${b}c${d}e`", &.{
        .template_head, .identifier, .template_middle, .identifier, .template_tail, .eof,
    });
    // Nested template inside a substitution.
    try expectTokens("`x${`y${z}`}w`", &.{
        .template_head, .template_head, .identifier, .template_tail, .template_tail, .eof,
    });
    // Object literals inside substitutions: brace-depth tracking.
    try expectTokens("`a${ {b:{c:1}} }d`", &.{
        .template_head, .l_brace,         .identifier, .colon,   .l_brace,       .identifier,
        .colon,         .numeric_literal, .r_brace,    .r_brace, .template_tail, .eof,
    });
    // Multi-line template is a single token.
    try expectTokens("`line1\nline2`", &.{ .no_substitution_template_literal, .eof });
}

test "golden: regex vs division heuristic" {
    // Regex after `=`, at statement start, after `typeof`, after `(` and `,`.
    try expectTokens("x = /ab[/]c/g;", &.{
        .identifier, .eq, .regexp_literal, .semicolon, .eof,
    });
    try expectTokens("typeof /re/;", &.{ .keyword_typeof, .regexp_literal, .semicolon, .eof });
    try expectTokens("f(/a/, /b/i)", &.{
        .identifier, .l_paren, .regexp_literal, .comma, .regexp_literal, .r_paren, .eof,
    });
    try expectTokens("return /x/;", &.{ .keyword_return, .regexp_literal, .semicolon, .eof });
    // Division after identifiers, literals, `)`, `]`.
    try expectTokens("b / c / d", &.{
        .identifier, .slash, .identifier, .slash, .identifier, .eof,
    });
    try expectTokens("(a) / 2", &.{
        .l_paren, .identifier, .r_paren, .slash, .numeric_literal, .eof,
    });
    try expectTokens("a[0] / 2", &.{
        .identifier, .l_bracket, .numeric_literal, .r_bracket, .slash, .numeric_literal, .eof,
    });
    try expectTokens("a /= b", &.{ .identifier, .slash_eq, .identifier, .eof });
    // Regex inside a template substitution.
    try expectTokens("`r${/x/}`", &.{
        .template_head, .regexp_literal, .template_tail, .eof,
    });
}

test "golden: contextual keywords get keyword tags, classified as contextual" {
    try expectTokens("type T = readonly string[];", &.{
        .keyword_type, .identifier, .eq,        .keyword_readonly, .keyword_string,
        .l_bracket,    .r_bracket,  .semicolon, .eof,
    });
    try expectTokens("declare namespace N { }", &.{
        .keyword_declare, .keyword_namespace, .identifier, .l_brace, .r_brace, .eof,
    });
    try expectTokens("x satisfies keyof infer is asserts", &.{
        .identifier, .keyword_satisfies, .keyword_keyof, .keyword_infer,
        .keyword_is, .keyword_asserts,   .eof,
    });

    try testing.expect(Tag.isContextualKeyword(.keyword_type));
    try testing.expect(Tag.isContextualKeyword(.keyword_satisfies));
    try testing.expect(Tag.isContextualKeyword(.keyword_using));
    try testing.expect(!Tag.isContextualKeyword(.keyword_const));
    try testing.expect(Tag.isReservedKeyword(.keyword_const));
    try testing.expect(!Tag.isReservedKeyword(.keyword_type));
    try testing.expect(Tag.isStrictReservedKeyword(.keyword_interface));
    try testing.expect(Tag.isKeyword(.keyword_break));
    try testing.expect(Tag.isKeyword(.keyword_using));
    try testing.expect(!Tag.isKeyword(.identifier));
}

test "golden: ASI newline flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "a\nb c/*\n*/d //x\ne";
    const toks = try tokenizeForTest(arena.allocator(), src);
    try testing.expectEqualSlices(Tag, &.{
        .identifier, .identifier, .identifier, .identifier, .identifier, .eof,
    }, toks.tags);
    try testing.expect(!toks.precededByNewline(0)); // a
    try testing.expect(toks.precededByNewline(1)); // b (after \n)
    try testing.expect(!toks.precededByNewline(2)); // c (space only)
    try testing.expect(toks.precededByNewline(3)); // d (newline inside block comment)
    try testing.expect(toks.precededByNewline(4)); // e (after line comment + \n)
}

test "golden: numeric literals" {
    try expectTokens(".5 1_000n 0xDEAD_BEEF 0b10_1 0o777 1e10 1.5e-3 42 1.", &.{
        .numeric_literal, .bigint_literal,  .numeric_literal, .numeric_literal,
        .numeric_literal, .numeric_literal, .numeric_literal, .numeric_literal,
        .numeric_literal, .eof,
    });
    try expectTokens("0xFFn 0b11n 0o7n 0n", &.{
        .bigint_literal, .bigint_literal, .bigint_literal, .bigint_literal, .eof,
    });
    // Hex floats are not TypeScript: `0x1p3` is `0x1` then identifier `p3`.
    try expectTokens("0x1p3", &.{ .numeric_literal, .identifier, .eof });
    // A BigInt suffix is INVALID on a non-integer, but tsc still folds a lone
    // one into the token (its `checkForIdentifierStartAfterNumericLiteral`
    // reports TS1353/TS1352 and does not rewind), so `1.5n[x]` is one element
    // access. A longer run is an abutting identifier and its own token.
    try expectTokens("1.5n", &.{ .numeric_literal, .eof });
    try expectTokens("1e2n", &.{ .numeric_literal, .eof });
    try expectTokens("1.5nfoo", &.{ .numeric_literal, .identifier, .eof });
    // An exponent marker and its sign belong to the literal even with no digits
    // after them (tsc's `scanNumber`, which then reports TS1124).
    try expectTokens("1e", &.{ .numeric_literal, .eof });
    try expectTokens("1e+", &.{ .numeric_literal, .eof });
    try expectTokens("1ee", &.{ .numeric_literal, .identifier, .eof });
    try expectTokens("1e[x]", &.{ .numeric_literal, .l_bracket, .identifier, .r_bracket, .eof });
    // `1..toString` is numeric `1.` then `.` then identifier.
    try expectTokens("1..toString", &.{ .numeric_literal, .dot, .identifier, .eof });
}

test "golden: strings and escapes" {
    try expectTokens(
        \\'a\'b' "c\"d" '\u{1F600}' "\n\t\\"
    , &.{
        .string_literal, .string_literal, .string_literal, .string_literal, .eof,
    });
    // Line continuation keeps the string alive across a newline.
    try expectTokens("'a\\\nb'", &.{ .string_literal, .eof });
}

test "golden: shebang and BOM" {
    try expectTokens("#!/usr/bin/env node\nlet x", &.{ .keyword_let, .identifier, .eof });
    try expectTokens("\xEF\xBB\xBFconst a", &.{ .keyword_const, .identifier, .eof });
    try expectTokens("\xEF\xBB\xBF#!x\nvar b", &.{ .keyword_var, .identifier, .eof });
    // `#!` not at the start is not a shebang: one two-byte `hash_bang` token,
    // which the parser answers with TS18026 rather than the generic TS1127.
    try expectTokens("a #! b", &.{ .identifier, .hash_bang, .identifier, .eof });
    // A `#` that is neither a shebang nor a private name is still `unknown`.
    try expectTokens("a # b", &.{ .identifier, .unknown, .identifier, .eof });
}

test "golden: a byte that starts no UTF-8 sequence is binary content to end of file" {
    try expectTokens("var a\n\x88 var b = 1;", &.{ .keyword_var, .identifier, .binary_content, .eof });
    // Well-formed non-ASCII is an ordinary identifier, whatever plane it is in.
    try expectTokens("var \xC3\xA9\xC3\xA8 = 1;", &.{ .keyword_var, .identifier, .eq, .numeric_literal, .semicolon, .eof });
    try expectTokens("var \xF0\x9D\x92\x9C = 1;", &.{ .keyword_var, .identifier, .eq, .numeric_literal, .semicolon, .eof });
    // A malformed sequence INSIDE a name ends the name, and the next token is
    // the binary one — never a silently-truncated identifier.
    try expectTokens("ab\x88cd", &.{ .identifier, .binary_content, .eof });
    // A well-formed U+FFFD counts too: it is the character tsc's decoder would
    // have produced, and the only reason to see one is binary content.
    try expectTokens("var a\n\xEF\xBF\xBD var b = 1;", &.{ .keyword_var, .identifier, .binary_content, .eof });
    try expectTokens("ab\xEF\xBF\xBDcd", &.{ .identifier, .binary_content, .eof });
}

test "golden: private identifiers and decorators" {
    try expectTokens("class A { #x = 1; @dec m() {} }", &.{
        .keyword_class,   .identifier, .l_brace, .private_identifier, .eq,
        .numeric_literal, .semicolon,  .at,      .identifier,         .identifier,
        .l_paren,         .r_paren,    .l_brace, .r_brace,            .r_brace,
        .eof,
    });
}

test "golden: unicode and escaped identifiers" {
    // Non-ASCII bytes are identifier constituents (pragmatic fast path).
    try expectTokens("const caf\xC3\xA9 = 1;", &.{
        .keyword_const, .identifier, .eq, .numeric_literal, .semicolon, .eof,
    });
    // `Abc` is one identifier; escaped text never matches keywords.
    try expectTokens("\\u0041bc = 1", &.{ .identifier, .eq, .numeric_literal, .eof });
    try expectTokens("\\u{74}ype", &.{ .identifier, .eof });
    // Malformed escape: `\` alone is an error token.
    try expectTokens("\\zx", &.{ .unknown, .identifier, .eof });
}

test "golden: non-ASCII whitespace and line terminators are trivia" {
    // U+00A0 NBSP separates tokens; it does NOT extend the identifier.
    try expectTokens("\xC2\xA0var x\xC2\xA0= 1\xC2\xA0;", &.{
        .keyword_var, .identifier, .eq, .numeric_literal, .semicolon, .eof,
    });
    // U+0085 NEL, U+1680, U+2000, U+202F, U+205F, U+3000 and a stray U+FEFF.
    try expectTokens("a\xC2\x85b\xE1\x9A\x80c\xE2\x80\x80d\xE2\x80\xAFe\xE2\x81\x9Ff\xE3\x80\x80g\xEF\xBB\xBFh", &.{
        .identifier, .identifier, .identifier, .identifier,
        .identifier, .identifier, .identifier, .identifier,
        .eof,
    });
    // U+2028 / U+2029 are LINE TERMINATORS; NEL is horizontal space, so the
    // token after it is not preceded by a newline (`fileWithNextLine3.ts`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenizeForTest(arena.allocator(), "a\xE2\x80\xA8b\xE2\x80\xA9c\xC2\x85d");
    try testing.expectEqualSlices(Tag, &.{
        .identifier, .identifier, .identifier, .identifier, .eof,
    }, toks.tags);
    try testing.expect(toks.precededByNewline(1)); // after U+2028
    try testing.expect(toks.precededByNewline(2)); // after U+2029
    try testing.expect(!toks.precededByNewline(3)); // after U+0085
    // A line comment ends at U+2028, so the code after it is scanned.
    try expectTokens("//c\xE2\x80\xA8x", &.{ .identifier, .eof });
    // A neighbour of NBSP in the same lead byte is NOT trivia: U+00A1 continues
    // the identifier, so the table is read to the last byte and not guessed from
    // the lead one. (A truncated `C2` is invalid UTF-8 and keeps its own
    // pre-existing answer, `binary_content`.)
    try expectTokens("a\xC2\xA1b", &.{ .identifier, .eof });
}

test "errors: unterminated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "\"abc";
    const toks = try tokenizeForTest(arena.allocator(), src);
    try testing.expectEqualSlices(Tag, &.{ .unterminated_string_literal, .eof }, toks.tags);
    try testing.expectEqual(@as(u32, 0), toks.start(0));
    try testing.expectEqual(@as(u32, 4), toks.end(src, 0));
}

test "errors: string stops at newline, scanning continues" {
    try expectTokens("\"a\nb\"", &.{
        .unterminated_string_literal, .identifier, .unterminated_string_literal, .eof,
    });
}

test "errors: unterminated template forms" {
    // unterminated_template consumes to EOF; the eof token still follows.
    try expectTokens("`ab", &.{ .unterminated_template, .eof });
    try expectTokens("`a${b", &.{ .template_head, .identifier, .eof });
    try expectTokens("`a${b}", &.{ .template_head, .identifier, .unterminated_template, .eof });
}

test "errors: unterminated comment and regex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "x = 1; /* trailing";
    const toks = try tokenizeForTest(arena.allocator(), src);
    try testing.expectEqualSlices(Tag, &.{
        .identifier, .eq, .numeric_literal, .semicolon, .unterminated_comment, .eof,
    }, toks.tags);
    try testing.expectEqual(@as(u32, 7), toks.start(4));
    try testing.expectEqual(@as(u32, src.len), toks.end(src, 4));

    try expectTokens("x = /ab", &.{ .identifier, .eq, .unterminated_regexp_literal, .eof });
    try expectTokens("x = /ab\n1", &.{
        .identifier, .eq, .unterminated_regexp_literal, .numeric_literal, .eof,
    });
}

test "token ends: recomputed ends are consistent with starts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "`a${ x / 2 }b${y}c`; foo(/re/g, 1_2n) // c\n'str' ??= .5";
    const toks = try tokenizeForTest(arena.allocator(), src);
    var i: usize = 0;
    while (i < toks.len()) : (i += 1) {
        const start = toks.start(i);
        const end = toks.end(src, i);
        if (toks.tag(i) == .eof) {
            try testing.expectEqual(start, end);
        } else {
            try testing.expect(end > start);
            try testing.expect(end <= src.len);
        }
        if (i + 1 < toks.len()) {
            try testing.expect(toks.start(i + 1) >= end); // no overlap
        }
    }
}

test "tokens: SoA store is 5 bytes per token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenizeForTest(arena.allocator(), "let x = 1 + 2;");
    try testing.expectEqual(@as(usize, 8), toks.len()); // incl. eof
    try testing.expectEqual(@as(usize, 8 * 5), toks.byteSize());
}

test "token stream with a non-arena allocator frees cleanly" {
    var toks = try tokenizeForTest(testing.allocator, "let x = `a${b}c`;");
    defer toks.deinit(testing.allocator);
    try testing.expectEqual(Tag.template_head, toks.tag(3));
}

/// Shared fuzz/stress oracle: scanning must terminate, always make progress,
/// and produce a bounded number of tokens; rescan entry points must also make
/// progress. Also runs the test-only whole-file driver end to end.
fn checkScannerOnArbitraryBytes(alloc: Allocator, input: []const u8) !void {
    var s = Scanner.init(input);
    var count: usize = 0;
    while (true) {
        const before = s.index;
        const tok = s.next();
        if (tok.tag == .eof) break;
        // Progress: every non-eof token consumes at least one byte.
        try testing.expect(s.index > before);
        try testing.expect(tok.end > tok.start);
        try testing.expect(tok.end <= input.len);
        count += 1;
        try testing.expect(count <= input.len);
        // Exercise rescan entry points on a scanner copy.
        switch (tok.tag) {
            .slash, .slash_eq => {
                var s2 = s;
                const r = s2.reScanSlashAsRegex(tok);
                try testing.expect(r.end > r.start);
            },
            .r_brace => {
                var s2 = s;
                const r = s2.reScanTemplateToken(tok);
                try testing.expect(r.end > r.start);
            },
            else => {},
        }
    }
    var toks = try tokenizeForTest(alloc, input);
    defer toks.deinit(alloc);
    try testing.expect(toks.len() >= 1);
    try testing.expectEqual(Tag.eof, toks.tag(toks.len() - 1));
}

test "stress: deterministic random byte soup never crashes or stalls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const random = prng.random();

    var buf: [512]u8 = undefined;

    // Pure random bytes, including invalid UTF-8 and NUL.
    for (0..1500) |_| {
        const n = random.uintLessThan(usize, buf.len + 1);
        random.bytes(buf[0..n]);
        try checkScannerOnArbitraryBytes(arena.allocator(), buf[0..n]);
        _ = arena.reset(.retain_capacity);
    }

    // Random concatenations of nasty fragments (tokens cut mid-way, template
    // and regex openers, escapes, BOM/shebang bytes, invalid UTF-8 tails).
    const fragments = [_][]const u8{
        "`${",      "${",   "}",    "`",    "/",  "/*",   "*/", "//", "\"", "'",
        "\\",       "\\u",  "\\u{", "0x",   "0b", "1_0n", ".5", "1.", "e5", "?.",
        "??=",      ">>>=", "...",  "a",    "#",  "#!",   "@",  "\n", "\r", " ",
        "\xEF\xBB", "\xFF", "\xC2", "\x00", "$",  "_",    "n",  "=",  "[",  "]",
    };
    for (0..800) |_| {
        var len: usize = 0;
        while (len < buf.len - 8) {
            const frag = fragments[random.uintLessThan(usize, fragments.len)];
            if (len + frag.len > buf.len) break;
            @memcpy(buf[len..][0..frag.len], frag);
            len += frag.len;
            if (random.uintLessThan(u8, 8) == 0) break;
        }
        try checkScannerOnArbitraryBytes(arena.allocator(), buf[0..len]);
        _ = arena.reset(.retain_capacity);
    }
}

fn fuzzScannerOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [512]u8 = undefined;
    // Bias toward printable ASCII and scanner-relevant bytes, but allow the
    // full byte range (invalid UTF-8, NUL, control chars).
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 6),
        .value(u8, '`', 4),
        .value(u8, '$', 4),
        .value(u8, '{', 4),
        .value(u8, '}', 4),
        .value(u8, '/', 4),
        .value(u8, '\\', 4),
        .value(u8, '"', 3),
        .value(u8, '\'', 3),
        .value(u8, '\n', 4),
        .value(u8, '\r', 2),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try checkScannerOnArbitraryBytes(arena.allocator(), source_buf[0..len]);
}

test "fuzz: scanner on arbitrary bytes" {
    try testing.fuzz({}, fuzzScannerOne, .{});
}
