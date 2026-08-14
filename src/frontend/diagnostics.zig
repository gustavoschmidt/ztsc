//! Shared diagnostic type.
//!
//! The parser reports parse errors as `Diagnostic { code, span }`; message
//! text is a static string per code (no allocation). The checker will extend
//! later (severity levels, related spans, argument interpolation) — for
//! now a diagnostic is 12 bytes and lives in the per-file arena.

const std = @import("std");
const source = @import("source.zig");

/// In-file alias only; consumers name `source.Span` / `span.Span`.
const Span = source.Span;

pub const Code = enum(u16) {
    // --- scanner-surfaced errors -----------------------------------------
    unterminated_string,
    unterminated_template,
    unterminated_regexp,
    unterminated_comment,
    unexpected_character,
    /// TS18026: `#!` anywhere but the first line of the file.
    shebang_not_at_start,
    /// TS1490: the file holds a byte sequence that is not text at all. tsc
    /// reports it once, at the start of the file, and stops scanning there.
    file_appears_binary,

    // --- literal grammar (src/frontend/literals.zig) -----------------------
    /// TS1121: `010` — a legacy octal literal.
    octal_literal_not_allowed,
    /// TS1489: `08` — a decimal that starts with a zero.
    decimal_with_leading_zero,
    /// TS1487: `"\101"` — a legacy octal escape.
    octal_escape_not_allowed,
    /// TS1488: `"\8"` — not an escape sequence in any mode.
    escape_sequence_not_allowed,
    /// TS1125: `0x`, `"\x1"`, `"\u12"` — a hex digit was required here.
    hex_digit_expected,
    /// TS1177: `0b` with no digits.
    binary_digit_expected,
    /// TS1178: `0o` with no digits.
    octal_digit_expected,
    /// TS1198: `"\u{110000}"` — outside the Unicode range.
    unicode_escape_out_of_range,
    /// TS1199: `"\u{12"` — no closing brace.
    unterminated_unicode_escape,
    /// TS1351: `3a` — an identifier or keyword abutting a numeric literal.
    identifier_after_numeric_literal,

    // --- parse errors ------------------------------------------------------
    expected_expression,
    expected_identifier,
    expected_semicolon,
    expected_comma,
    expected_colon,
    expected_arrow,
    expected_l_paren,
    expected_r_paren,
    expected_l_brace,
    expected_r_brace,
    expected_r_bracket,
    expected_gt,
    expected_lt,
    expected_type,
    expected_type_member,
    expected_class_member,
    /// TS1136: a key the grammar cannot start an object-LITERAL property with.
    expected_property_name,
    /// TS1180: the same in an object BINDING pattern (`var { + } = o`) — tsc
    /// words and numbers that one separately.
    expected_binding_pattern_property,
    expected_binding,
    expected_string_literal,
    expected_from,
    expected_import_clause,
    expected_export_clause,
    expected_while,
    expected_case_or_default,
    expected_catch_or_finally,
    expected_declaration,
    /// TS1128: the token starts no statement AND no declaration, in a
    /// statement list. tsc's `parsingContextErrors(SourceElements)` /
    /// `(BlockStatements)`.
    expected_declaration_or_statement,
    /// TS1129: the same, in the statement list of a `case`/`default` clause —
    /// tsc's `parsingContextErrors(SwitchClauseStatements)`.
    expected_statement,
    /// TS1005 with `export` as the token: tsc's answer for a top-level
    /// `default`, which is only ever `export default`.
    expected_export,
    expected_eq,
    expected_of_or_in,
    unexpected_token,
    /// TS1434: a missing `;` after an expression statement that is nothing but
    /// a bare identifier — tsc's `parseErrorForMissingSemicolonAfter` blames
    /// the WORD (over its whole span) instead of answering "';' expected" at
    /// the token after it, on the theory that `foo bar` is a misspelled keyword
    /// rather than a forgotten semicolon.
    unexpected_keyword_or_identifier,
    /// `a ?? b || c` without parentheses (TS(5076)-style grammar error).
    nullish_mixed_with_logical,
    /// Tagged template in an optional chain: `a?.b`c`` is a syntax error.
    tagged_template_in_optional_chain,
    /// `=>` on a new line after the parameter list.
    newline_before_arrow,
    /// Multiple default clauses, default in wrong place, etc.
    multiple_default_clauses,
    /// Rest parameter/element not in last position.
    rest_must_be_last,
    /// Line break not allowed here (e.g. after `throw`).
    line_break_not_allowed,
    /// Trailing comma or elision where the grammar forbids it.
    argument_expected,
    /// TS1206: a decorator in a position the grammar forbids (parameter
    /// decorator under TC39 standard decorators).
    decorator_not_valid_here,
    /// TS1274: an `in` variance annotation outside a class/interface/type
    /// alias type parameter (a function, method, or function/constructor type
    /// has no declaration-site variance).
    in_modifier_not_valid_here,
    /// TS1274: an `out` variance annotation in the same forbidden positions.
    out_modifier_not_valid_here,
    /// TS1029: `<out in T>` — the two variance annotations are in the wrong
    /// order.
    in_must_precede_out,
    /// TS1277: a `const` type-parameter modifier (TS 5.0) on an interface or
    /// type-alias type parameter — the two declaration forms that have no
    /// call site to infer from, so `const` inference has nothing to mean.
    const_modifier_not_valid_here,
    /// TS17006: `ExponentiationExpression : UpdateExpression ** Exponentiation`
    /// — the left operand of `**` may not be a *unary* expression, because
    /// `-a ** b` reads as `-(a ** b)` in some languages and `(-a) ** b` in
    /// others and ES2016 refused to pick. One code per operator so that
    /// `message()` stays a table of static strings (the text names the
    /// operator, tsc's `{0}`).
    exp_lhs_plus,
    exp_lhs_minus,
    exp_lhs_tilde,
    exp_lhs_bang,
    exp_lhs_delete,
    exp_lhs_void,
    exp_lhs_typeof,
    exp_lhs_await,
    /// TS17007: the same grammar rule, reached through the angle-bracket type
    /// assertion `<T>x ** 2`, which tsc words differently.
    exp_lhs_type_assertion,

    // --- bind errors, tsc-compatible codes via tsCode() ---------------
    /// TS2300: two declarations of the same name that cannot merge
    /// (class+class, function+var, duplicate params, type+interface, ...).
    duplicate_identifier,
    /// TS2451: block-scoped (`let`/`const`) redeclaration. tsc picks this
    /// over `duplicate_identifier` on the EXISTING symbol's flags only, and a
    /// `class` is not a `BlockScopedVariable` there — see `dupCode`.
    block_scoped_redeclare,
    /// TS2567: a failed merge with an `enum` on either side. tsc gives the
    /// enum its own message ahead of both the block-scoped and the plain
    /// duplicate one (`enum E {} var E;`, `var E; enum E {}`,
    /// `enum E {} class E {}`).
    enum_merge_conflict,
    /// TS2393: two function (or method) declarations with bodies.
    duplicate_function_implementation,
    /// TS2392: the same, for a class CONSTRUCTOR — tsc gives it its own
    /// message.
    duplicate_constructor_implementation,
    /// TS2813: a class declaration merged with function declarations of the
    /// same name, and the class is not ambient. Reported on the class.
    class_cannot_implement_overloads,
    /// TS2814: the function half of that same merge. Reported on each
    /// function declaration.
    function_merge_needs_ambient_class,
    /// TS2440: import binding clashes with a local declaration.
    import_conflict,
    /// TS2492: redeclaring a catch-clause parameter in the catch block.
    catch_redeclare,

    // --- ambient-context and modifier grammar (checked in the parser) ------
    /// TS1036: an executable statement in an ambient context (`declare
    /// namespace N { a; }`, or anything non-declarative in a `.d.ts`). tsc
    /// reports it once per containing block, on the statement's first token.
    statement_not_allowed_in_ambient,
    /// TS1183: a function, method, accessor or constructor with a BODY in an
    /// ambient context. Reported on the body's `{`.
    implementation_not_allowed_in_ambient,
    /// TS1028: a second accessibility modifier on one member or parameter
    /// (`public private x`), reported on the second one.
    accessibility_modifier_already_seen,
    /// TS2452: `enum E { 1, 2 }` — a numeric literal as an enum member name.
    /// The grammar ACCEPTS it (it is a PropertyName), so this is a check on a
    /// parsed member, not a parse failure; rejecting it in the parser instead
    /// cost a false TS1003 plus the file's whole semantic pass.
    enum_member_numeric_name,
    /// TS18024: `enum E { #x }` — a private identifier as an enum member name.
    enum_member_private_name,

    // --- strict-mode reserved words (tsc's binder, `checkStrictModeIdentifier`)
    /// TS1212: a future-reserved word (`yield`, `let`, `static`, `public`,
    /// `private`, `protected`, `implements`, `interface`, `package`) used as an
    /// Identifier. ztsc is always-strict, and so is every corpus case, so the
    /// condition is simply "this word is here".
    strict_reserved_word,
    /// TS1213: the same, inside a class — tsc says so, because a class body is
    /// strict whatever the file is.
    strict_reserved_word_in_class,
    /// TS1214: the same, in a file that is an external module — likewise strict
    /// for a reason the reader may not have chosen.
    strict_reserved_word_in_module,

    // --- `eval`/`arguments` as a declared name (tsc's `checkStrictModeEvalOrArguments`)
    /// TS1100/TS1210/TS1215: `eval` or `arguments` DECLARED — a variable, a
    /// binding element, a parameter, a function name, a catch parameter — or
    /// ASSIGNED to (`eval = 1`, `eval++`). A plain read is fine, which is why
    /// this is a different funnel from `strict_reserved_word`. The three codes
    /// are the same condition worded for its reason: plain strict mode, a class
    /// body, or an external module (chosen exactly as TS1212/1213/1214 are).
    /// Two words × three reasons, spelled out so every message is tsc's own.
    eval_in_strict,
    arguments_in_strict,
    eval_in_class,
    arguments_in_class,
    eval_in_module,
    arguments_in_module,

    // --- subset boundary (explicit, never a wrong answer) ------------------------
    unsupported_syntax,
    unsupported_satisfies,

    /// How tsc surfaces the condition — which decides both what a diagnostic
    /// suppresses and what suppresses it. Established empirically against tsgo
    /// 7.0.2: each candidate was compiled next to a second root file holding one
    /// guaranteed TS2322, and the TS2322's survival says which pass produced the
    /// diagnostic (see `Class.syntactic`).
    pub const Class = enum {
        /// tsc's PARSER recorded it in `sourceFile.parseDiagnostics`. tsc's
        /// driver reports the whole program's syntactic diagnostics and, when
        /// there is even one, never runs the semantic pass at all:
        ///
        ///     addRange(allDiagnostics, program.getSyntacticDiagnostics(...));
        ///     if (allDiagnostics.length === configFileParsingDiagnosticsLength) {
        ///         ... getSemanticDiagnostics ...
        ///     }
        ///
        /// So one of these anywhere in the program suppresses every semantic
        /// diagnostic everywhere in it, and nothing suppresses one of these.
        syntactic,
        /// tsc's GRAMMAR-CHECK pass: `checkGrammar*` in the checker and the
        /// `checkStrictMode*` family in the binder. These carry TS1xxx codes but
        /// live in the file's bind-and-check diagnostics, so they are semantic —
        /// a `@ts-ignore` hides one, and a syntactic error anywhere in the
        /// program suppresses one.
        grammar,
        /// ztsc's own subset boundary: tsc parses the construct without
        /// complaining, so there is no gate of tsc's to mirror. Reporting one
        /// must NOT suppress the rest of the program (that would trade one
        /// honest "not supported yet" for a silently unchecked project), and it
        /// has no TS code to report under.
        subset,
    };

    pub fn class(code: Code) Class {
        return switch (code) {
            .unsupported_syntax, .unsupported_satisfies => .subset,

            // Every bind diagnostic is semantic by construction, and the
            // grammar-pass parse diagnostics join them. Each of the TS1xxx ones
            // below was probed: `function f<in T>()` (TS1274), `<out in T>`
            // (TS1029), `interface I<const T>` (TS1277), `@d var x` (TS1206),
            // `a ?? b || c` (TS5076), two `default:` clauses (TS1113), `=>` on
            // the next line (TS1200), `throw` then a line break (TS1142),
            // `a?.b`x`` (TS1358) and `import x from y` (TS1141) all let a
            // sibling file's TS2322 through.
            .duplicate_identifier,
            .block_scoped_redeclare,
            .enum_merge_conflict,
            .duplicate_function_implementation,
            .duplicate_constructor_implementation,
            .class_cannot_implement_overloads,
            .function_merge_needs_ambient_class,
            .import_conflict,
            .catch_redeclare,
            .decorator_not_valid_here,
            .in_modifier_not_valid_here,
            .out_modifier_not_valid_here,
            .in_must_precede_out,
            .const_modifier_not_valid_here,
            .nullish_mixed_with_logical,
            .tagged_template_in_optional_chain,
            .newline_before_arrow,
            .multiple_default_clauses,
            .line_break_not_allowed,
            .rest_must_be_last,
            .expected_string_literal,
            .statement_not_allowed_in_ambient,
            .implementation_not_allowed_in_ambient,
            .accessibility_modifier_already_seen,
            .enum_member_numeric_name,
            .enum_member_private_name,
            .strict_reserved_word,
            .strict_reserved_word_in_class,
            .strict_reserved_word_in_module,
            // Same pass as the TS1212 family: tsc's binder, so semantic.
            .eval_in_strict,
            .arguments_in_strict,
            .eval_in_class,
            .arguments_in_class,
            .eval_in_module,
            .arguments_in_module,
            => .grammar,

            else => .syntactic,
        };
    }

    pub fn message(code: Code) []const u8 {
        return switch (code) {
            // Wherever `tsCode` names a tsc diagnostic, the text is tsc's own
            // wording for that number — a report reads the same as tsc's and a
            // reader can look the number up. The still-uncoded ones keep ztsc's
            // lowercase phrasing so the two groups stay visibly distinct.
            .unterminated_string => "Unterminated string literal.",
            .unterminated_template => "Unterminated template literal.",
            .unterminated_regexp => "Unterminated regular expression literal.",
            .unterminated_comment => "'*/' expected.",
            .unexpected_character => "Invalid character.",
            .shebang_not_at_start => "'#!' can only be used at the start of a file.",
            .file_appears_binary => "File appears to be binary.",
            // tsc appends the corrected spelling (`Use the syntax '0o10'.`) to
            // the first two; a Diagnostic here is a code plus a span with no
            // room to interpolate, so the invariant half of the sentence is what
            // is reported — the same policy the bind diagnostics already follow.
            .octal_literal_not_allowed => "Octal literals are not allowed.",
            .decimal_with_leading_zero => "Decimals with leading zeros are not allowed.",
            .octal_escape_not_allowed => "Octal escape sequences are not allowed.",
            .escape_sequence_not_allowed => "This escape sequence is not allowed.",
            .hex_digit_expected => "Hexadecimal digit expected.",
            .binary_digit_expected => "Binary digit expected.",
            .octal_digit_expected => "Octal digit expected.",
            .unicode_escape_out_of_range => "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.",
            .unterminated_unicode_escape => "Unterminated Unicode escape sequence.",
            .identifier_after_numeric_literal => "An identifier or keyword cannot immediately follow a numeric literal.",
            .expected_expression => "Expression expected.",
            .expected_identifier => "Identifier expected.",
            .expected_semicolon => "';' expected.",
            .expected_comma => "',' expected.",
            .expected_colon => "':' expected.",
            .expected_arrow => "'=>' expected.",
            .expected_l_paren => "'(' expected.",
            .expected_r_paren => "')' expected.",
            .expected_l_brace => "'{' expected.",
            .expected_r_brace => "'}' expected.",
            .expected_r_bracket => "']' expected.",
            .expected_gt => "'>' expected.",
            .expected_lt => "'<' expected.",
            .expected_type => "Type expected.",
            .expected_type_member => "Property or signature expected.",
            .expected_class_member => "Unexpected token. A constructor, method, accessor, or property was expected.",
            .expected_property_name => "Property assignment expected.",
            .expected_binding_pattern_property => "Property destructuring pattern expected.",
            .expected_binding => "Variable declaration expected.",
            .expected_string_literal => "String literal expected.",
            .expected_from => "'from' expected.",
            .expected_import_clause => "expected an import clause",
            .expected_export_clause => "expected an export clause",
            .expected_while => "'while' expected.",
            .expected_case_or_default => "'case' or 'default' expected.",
            .expected_catch_or_finally => "'catch' or 'finally' expected.",
            .expected_declaration => "Declaration expected.",
            .expected_declaration_or_statement => "Declaration or statement expected.",
            .expected_statement => "Statement expected.",
            .expected_export => "'export' expected.",
            .expected_eq => "'=' expected.",
            .expected_of_or_in => "expected 'of' or 'in'",
            .unexpected_token => "unexpected token",
            .unexpected_keyword_or_identifier => "Unexpected keyword or identifier.",
            .nullish_mixed_with_logical => "'??' and '||' operations cannot be mixed without parentheses.",
            .tagged_template_in_optional_chain => "Tagged template expressions are not permitted in an optional chain.",
            .newline_before_arrow => "Line terminator not permitted before arrow.",
            .multiple_default_clauses => "A 'default' clause cannot appear more than once in a 'switch' statement.",
            .rest_must_be_last => "a rest element must be last",
            .line_break_not_allowed => "Line break not permitted here.",
            .argument_expected => "Argument expression expected.",
            .statement_not_allowed_in_ambient => "Statements are not allowed in ambient contexts.",
            .implementation_not_allowed_in_ambient => "An implementation cannot be declared in ambient contexts.",
            .accessibility_modifier_already_seen => "Accessibility modifier already seen.",
            .enum_member_numeric_name => "An enum member cannot have a numeric name.",
            .enum_member_private_name => "An enum member cannot be named with a private identifier.",
            // tsc names the word (`'yield' is a reserved word...`); a Diagnostic
            // is a code plus a span, so the invariant sentence is reported.
            .strict_reserved_word => "Identifier expected. This is a reserved word in strict mode.",
            .strict_reserved_word_in_class => "Identifier expected. This is a reserved word in strict mode. Class definitions are automatically in strict mode.",
            .strict_reserved_word_in_module => "Identifier expected. This is a reserved word in strict mode. Modules are automatically in strict mode.",
            .eval_in_strict => evalStrictMessage("eval"),
            .arguments_in_strict => evalStrictMessage("arguments"),
            .eval_in_class => evalClassMessage("eval"),
            .arguments_in_class => evalClassMessage("arguments"),
            .eval_in_module => evalModuleMessage("eval"),
            .arguments_in_module => evalModuleMessage("arguments"),
            .decorator_not_valid_here => "Decorators are not valid here.",
            .in_modifier_not_valid_here => "'in' modifier can only appear on a type parameter of a class, interface or type alias",
            .out_modifier_not_valid_here => "'out' modifier can only appear on a type parameter of a class, interface or type alias",
            .in_must_precede_out => "'in' modifier must precede 'out' modifier.",
            .const_modifier_not_valid_here => "'const' modifier can only appear on a type parameter of a function, method or class",
            .exp_lhs_plus => expLhsMessage("+"),
            .exp_lhs_minus => expLhsMessage("-"),
            .exp_lhs_tilde => expLhsMessage("~"),
            .exp_lhs_bang => expLhsMessage("!"),
            .exp_lhs_delete => expLhsMessage("delete"),
            .exp_lhs_void => expLhsMessage("void"),
            .exp_lhs_typeof => expLhsMessage("typeof"),
            .exp_lhs_await => expLhsMessage("await"),
            .exp_lhs_type_assertion => "A type assertion expression is not allowed in the left-hand side of an exponentiation expression. Consider enclosing the expression in parentheses.",
            .duplicate_identifier => "duplicate identifier",
            .block_scoped_redeclare => "cannot redeclare block-scoped variable",
            .enum_merge_conflict => "Enum declarations can only merge with namespace or other enum declarations.",
            .duplicate_function_implementation => "duplicate function implementation",
            .duplicate_constructor_implementation => "Multiple constructor implementations are not allowed.",
            .class_cannot_implement_overloads => "Class declaration cannot implement overload list.",
            .function_merge_needs_ambient_class => "Function with bodies can only merge with classes that are ambient.",
            .import_conflict => "import declaration conflicts with local declaration",
            .catch_redeclare => "cannot redeclare identifier in catch clause",
            .unsupported_syntax => "syntax not yet supported by ztsc",
            .unsupported_satisfies => "'satisfies' is not yet supported by ztsc",
        };
    }

    /// The matching tsc error number, or 0 where we have no tsc analogue.
    ///
    /// The parse/scanner half of this table was derived by running both
    /// compilers over one snippet per code and keeping only the pairs where tsc
    /// answers with a single, stable code (bench-side script; see the `Class`
    /// doc comment for the method). A handful of ztsc codes are deliberately
    /// left at 0 because tsc's answer depends on context in a way one code
    /// cannot express — `unexpected_token` (a recovery catch-all tsc reaches
    /// through half a dozen different messages), `expected_export_clause`,
    /// `expected_of_or_in`, and `expected_import_clause`. Reporting a guess
    /// there would manufacture a wrong code where reporting none only costs a
    /// missing one.
    pub fn tsCode(code: Code) u16 {
        return switch (code) {
            // tsc's `_0_expected`, one code for every "I wanted this token"
            // failure. tsc's `parseExpected` reports at the CURRENT token, which
            // is where `Parser.errAtCur` reports too.
            .expected_semicolon,
            .expected_comma,
            .expected_colon,
            .expected_arrow,
            .expected_l_paren,
            .expected_r_paren,
            .expected_l_brace,
            .expected_r_brace,
            .expected_r_bracket,
            .expected_gt,
            .expected_lt,
            .expected_from,
            .expected_while,
            .expected_eq,
            .expected_export,
            => 1005,
            .expected_declaration_or_statement => 1128,
            .unexpected_keyword_or_identifier => 1434,
            .expected_statement => 1129,
            .expected_expression => 1109,
            .expected_identifier => 1003,
            .expected_type => 1110,
            .expected_type_member => 1131,
            .expected_class_member => 1068,
            .expected_property_name => 1136,
            .expected_binding_pattern_property => 1180,
            .expected_binding => 1134,
            .expected_declaration => 1146,
            .expected_case_or_default => 1130,
            .expected_catch_or_finally => 1472,
            .expected_string_literal => 1141,
            .argument_expected => 1135,
            .unterminated_string => 1002,
            .unterminated_template => 1160,
            .unterminated_regexp => 1161,
            .unterminated_comment => 1010,
            .unexpected_character => 1127,
            .shebang_not_at_start => 18026,
            .file_appears_binary => 1490,
            .octal_literal_not_allowed => 1121,
            .decimal_with_leading_zero => 1489,
            .octal_escape_not_allowed => 1487,
            .escape_sequence_not_allowed => 1488,
            .hex_digit_expected => 1125,
            .binary_digit_expected => 1177,
            .octal_digit_expected => 1178,
            .unicode_escape_out_of_range => 1198,
            .identifier_after_numeric_literal => 1351,
            .unterminated_unicode_escape => 1199,
            .nullish_mixed_with_logical => 5076,
            .tagged_template_in_optional_chain => 1358,
            .newline_before_arrow => 1200,
            .multiple_default_clauses => 1113,
            .line_break_not_allowed => 1142,
            .statement_not_allowed_in_ambient => 1036,
            .implementation_not_allowed_in_ambient => 1183,
            .accessibility_modifier_already_seen => 1028,
            .enum_member_numeric_name => 2452,
            .enum_member_private_name => 18024,
            .strict_reserved_word => 1212,
            .strict_reserved_word_in_class => 1213,
            .strict_reserved_word_in_module => 1214,
            .eval_in_strict, .arguments_in_strict => 1100,
            .eval_in_class, .arguments_in_class => 1210,
            .eval_in_module, .arguments_in_module => 1215,

            .duplicate_identifier => 2300,
            .block_scoped_redeclare => 2451,
            .enum_merge_conflict => 2567,
            .duplicate_function_implementation => 2393,
            .duplicate_constructor_implementation => 2392,
            .class_cannot_implement_overloads => 2813,
            .function_merge_needs_ambient_class => 2814,
            .import_conflict => 2440,
            .catch_redeclare => 2492,
            .decorator_not_valid_here => 1206,
            .in_modifier_not_valid_here, .out_modifier_not_valid_here => 1274,
            .in_must_precede_out => 1029,
            .const_modifier_not_valid_here => 1277,
            .exp_lhs_plus,
            .exp_lhs_minus,
            .exp_lhs_tilde,
            .exp_lhs_bang,
            .exp_lhs_delete,
            .exp_lhs_void,
            .exp_lhs_typeof,
            .exp_lhs_await,
            => 17006,
            .exp_lhs_type_assertion => 17007,
            else => 0,
        };
    }
};

/// TS17006's text differs between operators only in the quoted operator, so
/// the nine `exp_lhs_*` arms share one comptime template instead of nine
/// hand-copied sentences that would drift.
/// The three `checkStrictModeEvalOrArguments` sentences, parameterized on the
/// word so that `eval` and `arguments` share one copy of each.
fn evalStrictMessage(comptime word: []const u8) []const u8 {
    return "Invalid use of '" ++ word ++ "' in strict mode.";
}

fn evalClassMessage(comptime word: []const u8) []const u8 {
    return "Code contained in a class is evaluated in JavaScript's strict mode which does not allow this use of '" ++ word ++ "'. For more information, see https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode.";
}

fn evalModuleMessage(comptime word: []const u8) []const u8 {
    return "Invalid use of '" ++ word ++ "'. Modules are automatically in strict mode.";
}

fn expLhsMessage(comptime op: []const u8) []const u8 {
    return "An unary expression with the '" ++ op ++ "' operator is not allowed in the left-hand side of an exponentiation expression. Consider enclosing the expression in parentheses.";
}

/// A single diagnostic: error code plus source span. 8 bytes of span +
/// 2 bytes of code (padded to 12 in arrays; fine for current volumes).
pub const Diagnostic = struct {
    code: Code,
    span: Span,

    pub fn message(d: Diagnostic) []const u8 {
        return d.code.message();
    }
};

test "diagnostic messages are non-empty" {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const code: Code = @enumFromInt(f.value);
        try std.testing.expect(code.message().len > 0);
    }
}

test "diagnostic carries code and span" {
    const d: Diagnostic = .{ .code = .expected_semicolon, .span = .{ .start = 3, .end = 4 } };
    try std.testing.expectEqualStrings("';' expected.", d.message());
    try std.testing.expectEqual(@as(u32, 1), d.span.len());
}
