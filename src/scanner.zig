//! TypeScript tokenizer (M1).
//!
//! Scans the FULL TypeScript token set (we check only a subset, but we scan
//! everything so later phases can degrade gracefully on unsupported syntax).
//!
//! Design decisions (documented per PLAN.md M1):
//!
//! - **Token storage is struct-of-arrays** (PLAN §2.1): `tags: []Tag` (1 byte)
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
//!   (tsc: `reScanTemplateToken`). The whole-file driver `tokenize` applies
//!   template brace-depth tracking (exact) and a previous-token heuristic for
//!   regex-vs-division (the classic lexer approximation: division after
//!   identifier-like tokens, literals, `)`, `]`, `++`, `--`; regex otherwise).
//!   The heuristic mislabels rare forms like `if (x) /re/.test(y)`; the M2
//!   parser will use the rescan API with real grammar context instead.
//! - **Maximal munch for `>` sequences**: `>>`, `>>>`, `>>=`, `>>>=`, `>=` are
//!   single tokens (unlike tsc, which scans lone `>` and rescans on demand).
//!   The M2 parser splits `>>` when closing nested generics — trivial with
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

pub const Tag = enum(u8) {
    // --- sentinels & error tokens ---------------------------------------
    eof,
    /// Byte(s) that start no token (e.g. stray `\` or control chars).
    unknown,
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

    /// Reserved words that can never be identifiers.
    pub fn isReservedKeyword(tag: Tag) bool {
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

    /// True for tags that behave like an expression end for the tokenize()
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
};

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
                        while (s.index < s.src.len and
                            s.src[s.index] != '\n' and s.src[s.index] != '\r')
                        {
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
                else => break,
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
                if (c >= 0x80) return s.scanIdentifierOrKeyword();
                return s.punct(1, .unknown);
            },
        }
    }

    fn scanIdentifierOrKeyword(s: *Scanner) Tag {
        const start = s.index;
        s.index += 1; // first byte validated by caller
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
            if (isIdentCont(c) or c >= 0x80) {
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
            if (isDigit(s.at(i))) {
                integer = false;
                s.index = i;
                s.skipDigits(.dec);
            }
        }
        // BigInt suffix is only valid on integer forms; `1.5n` scans as
        // numeric `1.5` followed by identifier `n`.
        if (integer) return s.bigintSuffix();
        return .numeric_literal;
    }
};

/// Struct-of-arrays token store (PLAN §2.1): 1-byte tag + 4-byte start per
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

    pub fn precededByNewline(t: *const Tokens, i: usize) bool {
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

    pub fn deinit(t: *Tokens, alloc: Allocator) void {
        alloc.free(t.tags);
        alloc.free(t.starts);
        t.* = undefined;
    }
};

/// Tokenize a whole source file into a SoA token stream (ends with `.eof`).
///
/// Applies exact template brace-depth tracking (so `}` tokens that close a
/// `${...}` substitution are rescanned into template middle/tail parts) and
/// the previous-token heuristic for regex-vs-division described in the module
/// docs. Never fails on malformed input — only on OOM / oversized source.
pub fn tokenize(alloc: Allocator, src: []const u8) error{ OutOfMemory, SourceTooLarge }!Tokens {
    if (src.len > max_source_len) return error.SourceTooLarge;

    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(alloc);
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(alloc);
    // ~4.5 source bytes per token empirically; reserve conservatively.
    try tags.ensureTotalCapacityPrecise(alloc, src.len / 4 + 4);
    try starts.ensureTotalCapacityPrecise(alloc, src.len / 4 + 4);

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
                if (!prev_tag.endsExpression()) tok = s.reScanSlashAsRegex(tok);
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

/// Recompute a token's end offset by rescanning it from its start.
/// O(token length); used for lazy spans so we never store ends.
pub fn tokenEnd(src: []const u8, tag: Tag, start: u32) u32 {
    switch (tag) {
        .eof => return start,
        // These consume to end of file by construction.
        .unterminated_template, .unterminated_comment => {
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
        else => {
            var s = Scanner{ .src = src, .index = start };
            return s.next().end;
        },
    }
}

// ---------------------------------------------------------------------------
// character classes
// ---------------------------------------------------------------------------

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

inline fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c | 0x20) >= 'a' and (c | 0x20) <= 'f';
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

fn expectTokens(src: []const u8, expected: []const Tag) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), src);
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
    const toks = try tokenize(arena.allocator(), src);
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
    // BigInt suffix is invalid on non-integers: `1.5n` is `1.5` + `n`.
    try expectTokens("1.5n", &.{ .numeric_literal, .identifier, .eof });
    try expectTokens("1e2n", &.{ .numeric_literal, .identifier, .eof });
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
    // `#!` not at the start is not a shebang.
    try expectTokens("a #! b", &.{ .identifier, .unknown, .bang, .identifier, .eof });
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

test "errors: unterminated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "\"abc";
    const toks = try tokenize(arena.allocator(), src);
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
    const toks = try tokenize(arena.allocator(), src);
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
    const toks = try tokenize(arena.allocator(), src);
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
    const toks = try tokenize(arena.allocator(), "let x = 1 + 2;");
    try testing.expectEqual(@as(usize, 8), toks.len()); // incl. eof
    try testing.expectEqual(@as(usize, 8 * 5), toks.byteSize());
}

test "tokenize with non-arena allocator frees cleanly" {
    var toks = try tokenize(testing.allocator, "let x = `a${b}c`;");
    defer toks.deinit(testing.allocator);
    try testing.expectEqual(Tag.template_head, toks.tag(3));
}

/// Shared fuzz/stress oracle: scanning must terminate, always make progress,
/// and produce a bounded number of tokens; rescan entry points must also make
/// progress. Also runs the tokenize() driver end to end.
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
    var toks = try tokenize(alloc, input);
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
