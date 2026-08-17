//! Whether a parsed index signature is a legal one.
//!
//! tsc PARSES `[…]` in a type-member or class-member position as a full
//! PARAMETER LIST (`parseBracketedList(Parameters, parseParameter, …)`) and then
//! judges the result in the checker, in `checkGrammarIndexSignatureParameters`.
//! That split is the rule, not an implementation detail: `[key: string,]`,
//! `[p?: string]`, `[...rest: any[]]`, `[public k: string]` and `[a, b]` all
//! parse, so the file keeps its semantic pass and answers ONE grammar
//! diagnostic instead of a cascade of "']' expected" and "Property or signature
//! expected".
//!
//! One pure function over the parsed shape → the diagnostic, or null. tsc's
//! chain `return`s on its first hit, so the order below is load-bearing: a
//! two-parameter signature answers for its count and never mentions the `?` on
//! the second one.
//!
//! `duplicateKey` answers the one legality question a signature cannot answer
//! alone — whether a SIBLING already claimed its key domain (TS2374) — and is
//! likewise pure, over the list of key spellings.

const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const scanner = @import("scanner.zig");

const Code = diagnostics.Code;

/// What the parser found between the brackets, and whether a value type
/// followed them. Token indices, so the report can name one.
pub const Shape = struct {
    /// The `[`, which anchors the two diagnostics tsc blames on the whole node.
    bracket_token: u32,
    parameters: u32,
    /// Name token of the FIRST parameter — the anchor for most of the chain —
    /// or null when there is no parameter at all (`[]: string`).
    name_token: ?u32,
    /// The `,` of `[k: string,]`, when it is the last thing in the brackets.
    trailing_comma: ?u32,
    /// The `...` of a rest parameter.
    rest: ?u32,
    /// The first modifier on the parameter (`[public k: string]`).
    modifier: ?u32,
    /// The `?` of an optional parameter.
    question: ?u32,
    /// Whether the parameter has an `= …` initializer.
    initializer: bool,
    /// Whether the parameter has a `: T` annotation.
    parameter_type: bool,
    /// Whether that annotation is PROVABLY a legal index key type — the bare
    /// `string`, `number` or `symbol` keyword. tsc's TS1337 and TS1268 sit
    /// between the parameter-type check and the value-type one and need the type
    /// RESOLVED, so a parameter type this cannot vouch for makes the last arm
    /// (TS1021) stay silent rather than answer where tsc would have said TS1268:
    /// `[a: boolean]` and `[index: RegExp]` are TS1268 in tsgo, measured.
    parameter_type_indexable: bool,
    /// Whether a `: T` followed the `]`.
    value_type: bool,
};

pub const Report = struct { code: Code, token: u32 };

/// At most two, because the chain has one break in it.
pub const Reports = struct {
    /// tsc calls `checkGrammarForDisallowedTrailingComma` WITHOUT `return`, so a
    /// trailing comma does NOT stop the walk: `[k,]: string` answers TS1025 and
    /// then the TS1022 its untyped parameter earns (measured; `[key: string,]`
    /// looks like a one-diagnostic case only because the rest of the chain
    /// passes).
    trailing_comma: ?Report = null,
    /// The first hit of the return-chain proper.
    chain: ?Report = null,
};

/// What this index signature earns — nothing when it is well formed, or when
/// the rule that fails is one ztsc leaves to the checker (the parameter type
/// must be `string`/`number`/`symbol`/a template literal, tsc's TS1268, which
/// needs the type resolved).
pub fn check(s: Shape) Reports {
    if (s.parameters != 1) {
        // The count check `return`s ahead of the trailing-comma one, so a
        // multi-parameter list with a trailing comma answers for the count only.
        // tsc blames the first parameter's NAME, or the whole node when the
        // brackets are empty.
        return .{ .chain = .{
            .code = .index_sig_one_parameter,
            .token = s.name_token orelse s.bracket_token,
        } };
    }
    var out: Reports = .{};
    if (s.trailing_comma) |t| out.trailing_comma = .{ .code = .index_sig_trailing_comma, .token = t };
    out.chain = chainOf(s);
    return out;
}

fn chainOf(s: Shape) ?Report {
    if (s.rest) |t| return .{ .code = .index_sig_rest_parameter, .token = t };
    // The name is the anchor even though the `public` is what is wrong — tsc's
    // `grammarErrorOnNode(parameter.name, …)`, measured at column 13 of
    // `    [public x: string]: string;`.
    if (s.modifier != null) {
        return .{ .code = .index_sig_accessibility_modifier, .token = s.name_token.? };
    }
    if (s.question) |t| return .{ .code = .index_sig_question_mark, .token = t };
    if (s.initializer) return .{ .code = .index_sig_initializer, .token = s.name_token.? };
    if (!s.parameter_type) {
        return .{ .code = .index_sig_parameter_type_annotation, .token = s.name_token.? };
    }
    // TS1337 ("cannot be a literal type or generic type") and TS1268 ("must be
    // 'string', 'number', 'symbol', or a template literal type") go HERE, ahead
    // of the value-type check, and both need the parameter type RESOLVED. So the
    // last arm only fires for a parameter type that provably passes them; every
    // other spelling is an under-report rather than a wrong key. Getting this
    // order wrong is what the s2 sweep caught: `[a: boolean]`, `[index: any]`
    // and `[index: RegExp]` have no value type either, and tsgo answers TS1268
    // for all three.
    if (!s.parameter_type_indexable) return null;
    if (!s.value_type) return .{ .code = .index_sig_type_annotation, .token = s.bracket_token };
    return null;
}

/// tsc's `checkTypeForDuplicateIndexSignatures` (TS2374), as the pure question
/// about ONE member list: does `keys[i]`'s key domain also belong to another
/// signature in the list? Every one of a duplicated set is reported, so this is
/// asked per signature rather than returning "the extras".
///
/// `keys` is each index signature's key-type annotation as SOURCE TEXT, in
/// declaration order. Two spellings that are the same text are the same type;
/// two that are not may still be (`type S = string` beside `string`, or
/// `string` inside a `string | number` tsc splits into its constituents), and
/// those go unreported. That is the deliberate side to be wrong on: a text
/// match cannot manufacture a duplicate that is not one, so the rule
/// under-reports rather than inventing an error, and it stays a pure syntactic
/// rule the binder can run without resolving a single type.
pub fn duplicateKey(keys: []const []const u8, i: usize) bool {
    for (keys, 0..) |k, j| {
        if (j != i and std.mem.eql(u8, k, keys[i])) return true;
    }
    return false;
}

/// tsc's `isModifierKind`, the lookahead's "is this the start of a parameter
/// modifier" test. Wider than the modifiers an index signature could sensibly
/// carry, on purpose: the same predicate has to answer for
/// `isUnambiguouslyIndexSignature` and for the parse that follows it, or a
/// shape the lookahead claimed would then mis-parse.
pub fn isModifierKind(tag: scanner.Tag) bool {
    return switch (tag) {
        .keyword_abstract,
        .keyword_accessor,
        .keyword_async,
        .keyword_const,
        .keyword_declare,
        .keyword_default,
        .keyword_export,
        .keyword_in,
        .keyword_out,
        .keyword_override,
        .keyword_private,
        .keyword_protected,
        .keyword_public,
        .keyword_readonly,
        .keyword_static,
        => true,
        else => false,
    };
}

/// A well-formed signature, as the baseline every test below perturbs.
const ok: Shape = .{
    .bracket_token = 10,
    .parameters = 1,
    .name_token = 11,
    .trailing_comma = null,
    .rest = null,
    .modifier = null,
    .question = null,
    .initializer = false,
    .parameter_type = true,
    .parameter_type_indexable = true,
    .value_type = true,
};

test "a well-formed index signature answers nothing" {
    try std.testing.expectEqual(Reports{}, check(ok));
}

test "the count outranks everything the parameters could also be wrong about" {
    var s = ok;
    s.parameters = 2;
    s.question = 99;
    s.rest = 98;
    s.trailing_comma = 97;
    const out = check(s);
    try std.testing.expectEqual(@as(?Report, null), out.trailing_comma);
    try std.testing.expectEqual(Code.index_sig_one_parameter, out.chain.?.code);
    try std.testing.expectEqual(@as(u32, 11), out.chain.?.token); // the name, not the `[`
}

test "empty brackets are blamed on the node" {
    var s = ok;
    s.parameters = 0;
    s.name_token = null;
    const out = check(s);
    try std.testing.expectEqual(Code.index_sig_one_parameter, out.chain.?.code);
    try std.testing.expectEqual(@as(u32, 10), out.chain.?.token);
}

test "a trailing comma does not stop the walk" {
    // `[k,]: string` — TS1025 on the comma AND TS1022 on the untyped parameter.
    var s = ok;
    s.trailing_comma = 20;
    s.parameter_type = false;
    const out = check(s);
    try std.testing.expectEqual(Code.index_sig_trailing_comma, out.trailing_comma.?.code);
    try std.testing.expectEqual(@as(u32, 20), out.trailing_comma.?.token);
    try std.testing.expectEqual(Code.index_sig_parameter_type_annotation, out.chain.?.code);
    try std.testing.expectEqual(@as(u32, 11), out.chain.?.token);
    // `[key: string,]: string` is the same rule with the rest of the walk clean.
    s = ok;
    s.trailing_comma = 20;
    try std.testing.expectEqual(Code.index_sig_trailing_comma, check(s).trailing_comma.?.code);
    try std.testing.expectEqual(@as(?Report, null), check(s).chain);
}

test "each arm in tsc's order, and each on tsc's token" {
    var s = ok;
    s.rest = 21;
    s.modifier = 22;
    try std.testing.expectEqual(Code.index_sig_rest_parameter, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 21), check(s).chain.?.token);

    s = ok;
    s.modifier = 22;
    s.question = 23;
    try std.testing.expectEqual(Code.index_sig_accessibility_modifier, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 11), check(s).chain.?.token); // the NAME

    s = ok;
    s.question = 23;
    s.initializer = true;
    try std.testing.expectEqual(Code.index_sig_question_mark, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 23), check(s).chain.?.token);

    s = ok;
    s.initializer = true;
    s.parameter_type = false;
    try std.testing.expectEqual(Code.index_sig_initializer, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 11), check(s).chain.?.token);

    s = ok;
    s.parameter_type = false;
    s.value_type = false;
    try std.testing.expectEqual(Code.index_sig_parameter_type_annotation, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 11), check(s).chain.?.token);

    s = ok;
    s.value_type = false;
    try std.testing.expectEqual(Code.index_sig_type_annotation, check(s).chain.?.code);
    try std.testing.expectEqual(@as(u32, 10), check(s).chain.?.token); // the `[`
}

test "every signature of a duplicated key domain is reported, and only those" {
    const t = std.testing;
    const keys = [_][]const u8{ "string", "number", "string", "symbol", "string" };
    try t.expect(duplicateKey(&keys, 0));
    try t.expect(!duplicateKey(&keys, 1));
    try t.expect(duplicateKey(&keys, 2));
    try t.expect(!duplicateKey(&keys, 3));
    try t.expect(duplicateKey(&keys, 4));
    // A lone signature is never its own duplicate.
    try t.expect(!duplicateKey(&.{"string"}, 0));
    // A spelling difference is not resolved, so it goes unreported.
    const aliased = [_][]const u8{ "string", "S" };
    try t.expect(!duplicateKey(&aliased, 0));
    try t.expect(!duplicateKey(&aliased, 1));
}

test "no value type, but a key type TS1268 would have caught first, stays silent" {
    // `interface I { [a: boolean] }` is TS1268 in tsgo, not TS1021.
    var s = ok;
    s.value_type = false;
    s.parameter_type_indexable = false;
    try std.testing.expectEqual(Reports{}, check(s));
    // ...and a well-formed one is still silent, not suddenly reported.
    s = ok;
    s.parameter_type_indexable = false;
    try std.testing.expectEqual(Reports{}, check(s));
    // The arms AHEAD of TS1268 in the walk are unaffected by it.
    s = ok;
    s.parameter_type_indexable = false;
    s.question = 23;
    try std.testing.expectEqual(Code.index_sig_question_mark, check(s).chain.?.code);
}
