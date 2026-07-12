//! Shared diagnostic type (M2).
//!
//! The parser reports parse errors as `Diagnostic { code, span }`; message
//! text is a static string per code (no allocation). The checker will extend
//! this in M4 (severity levels, related spans, argument interpolation) — for
//! now a diagnostic is 12 bytes and lives in the per-file arena.

const std = @import("std");
const source = @import("source.zig");

pub const Span = source.Span;

pub const Code = enum(u16) {
    // --- scanner-surfaced errors -----------------------------------------
    unterminated_string,
    unterminated_template,
    unterminated_regexp,
    unterminated_comment,
    unexpected_character,

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
    expected_property_name,
    expected_binding,
    expected_string_literal,
    expected_from,
    expected_import_clause,
    expected_export_clause,
    expected_while,
    expected_case_or_default,
    expected_catch_or_finally,
    expected_declaration,
    expected_eq,
    expected_of_or_in,
    unexpected_token,
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

    // --- subset boundary (PLAN §5: explicit, never a wrong answer) ---------
    unsupported_syntax,
    unsupported_satisfies,

    pub fn message(code: Code) []const u8 {
        return switch (code) {
            .unterminated_string => "unterminated string literal",
            .unterminated_template => "unterminated template literal",
            .unterminated_regexp => "unterminated regular expression literal",
            .unterminated_comment => "unterminated block comment",
            .unexpected_character => "unexpected character",
            .expected_expression => "expected an expression",
            .expected_identifier => "expected an identifier",
            .expected_semicolon => "expected ';'",
            .expected_comma => "expected ','",
            .expected_colon => "expected ':'",
            .expected_arrow => "expected '=>'",
            .expected_l_paren => "expected '('",
            .expected_r_paren => "expected ')'",
            .expected_l_brace => "expected '{'",
            .expected_r_brace => "expected '}'",
            .expected_r_bracket => "expected ']'",
            .expected_gt => "expected '>'",
            .expected_lt => "expected '<'",
            .expected_type => "expected a type",
            .expected_type_member => "expected a property, method, or index signature",
            .expected_class_member => "expected a class member",
            .expected_property_name => "expected a property name",
            .expected_binding => "expected a variable name or binding pattern",
            .expected_string_literal => "expected a string literal",
            .expected_from => "expected 'from'",
            .expected_import_clause => "expected an import clause",
            .expected_export_clause => "expected an export clause",
            .expected_while => "expected 'while'",
            .expected_case_or_default => "expected 'case' or 'default'",
            .expected_catch_or_finally => "expected 'catch' or 'finally'",
            .expected_declaration => "expected a declaration",
            .expected_eq => "expected '='",
            .expected_of_or_in => "expected 'of' or 'in'",
            .unexpected_token => "unexpected token",
            .nullish_mixed_with_logical => "'??' cannot be mixed with '||' or '&&' without parentheses",
            .tagged_template_in_optional_chain => "tagged template expressions are not permitted in an optional chain",
            .newline_before_arrow => "line break not permitted before '=>'",
            .multiple_default_clauses => "a 'default' clause cannot appear more than once in a 'switch' statement",
            .rest_must_be_last => "a rest element must be last",
            .line_break_not_allowed => "line break not permitted here",
            .argument_expected => "argument expression expected",
            .unsupported_syntax => "syntax not supported in ztsc v0.0.1",
            .unsupported_satisfies => "'satisfies' is not supported in ztsc v0.0.1",
        };
    }
};

/// A single diagnostic: error code plus source span. 8 bytes of span +
/// 2 bytes of code (padded to 12 in arrays; fine for M2 volumes).
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
    try std.testing.expectEqualStrings("expected ';'", d.message());
    try std.testing.expectEqual(@as(u32, 1), d.span.len());
}
