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
    /// The other side of the same question: whether the annotation is PROVABLY
    /// an illegal index key type — a bare `boolean`/`any`/`void`/`unknown`/
    /// `never`/`object`/`bigint`/`undefined`/`null` keyword, none of which
    /// `isValidIndexKeyType` accepts and none of which needs resolving to
    /// recognize. The two flags are not complements: an annotation this cannot
    /// vouch for either way (`RegExp`, `string[]`, an alias) sets neither, and
    /// stays the under-report it already was.
    parameter_type_bad_key: bool,
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
    /// tsc's `checkParameter` contributes TS2371 INDEPENDENTLY of everything
    /// below — it is the general "a parameter initializer is only allowed in an
    /// implementation" rule, not an index-signature rule at all, so it survives
    /// whatever the chain answers. Measured against tsgo: `[a: string = 'x']`
    /// answers TS1020 AND TS2371; `[a: string = 'x', b: number]` answers
    /// TS1096 and still TS2371; `[public a: string = 'x']` answers TS1018 and
    /// still TS2371. Always on the first parameter's NAME.
    initializer_outside_impl: ?Report = null,
    /// The first hit of the return-chain proper.
    chain: ?Report = null,
};

/// What this index signature earns — nothing when it is well formed, or when
/// the rule that fails is one ztsc leaves to the checker (the parameter type
/// must be `string`/`number`/`symbol`/a template literal, tsc's TS1268, which
/// needs the type resolved).
pub fn check(s: Shape) Reports {
    // Outside the chain entirely, and outside the one-parameter gate with it.
    // Blamed on the whole PARAMETER (tsc's `error(parameter, …)`), so it starts
    // at the `...` or the first modifier when there is one, not at the name:
    // `[...a: string = 'x']` answers at the `...`, measured.
    const init_report: ?Report = if (s.initializer)
        .{
            .code = .param_initializer_outside_impl,
            .token = s.rest orelse s.modifier orelse s.name_token orelse s.bracket_token,
        }
    else
        null;
    if (s.parameters != 1) {
        // The count check `return`s ahead of the trailing-comma one, so a
        // multi-parameter list with a trailing comma answers for the count only.
        // tsc blames the first parameter's NAME, or the whole node when the
        // brackets are empty.
        return .{ .initializer_outside_impl = init_report, .chain = .{
            .code = .index_sig_one_parameter,
            .token = s.name_token orelse s.bracket_token,
        } };
    }
    var out: Reports = .{ .initializer_outside_impl = init_report };
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
    // of the value-type check, and both need the parameter type RESOLVED — so
    // only the spellings that need no resolution are answered: a bare non-key
    // KEYWORD is TS1268 (`[a: boolean]`, `[index: any]`), a bare
    // `string`/`number`/`symbol` clears both and reaches the value-type arm,
    // and everything in between (`RegExp`, `string[]`, an alias) stays an
    // under-report rather than a wrong key. Getting this order wrong is what
    // the s2 sweep caught: `[a: boolean]` and `[index: any]` have no value type
    // either, and tsgo still answers TS1268 for both.
    if (s.parameter_type_bad_key) {
        return .{ .code = .index_sig_key_type, .token = s.name_token.? };
    }
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

/// The first token of a class or type MEMBER — its `main_token` walked back
/// over the modifier keywords the parser folded into the member's flag word.
///
/// That is where tsc's declaration node starts, and so where every diagnostic
/// blamed on the whole member goes: `readonly [x: string]: T` answers TS2374
/// and TS2413 at the `readonly`, not at the `[`. Modifiers leave no token in
/// the node, so the only way back to them is the token stream — and
/// `isModifierKind` is the same predicate the parser's own lookahead used to
/// decide these tokens were modifiers of this member, so the two cannot drift.
pub fn memberStartToken(tokens: *const scanner.Tokens, main_token: u32) u32 {
    return memberStartTokenIn(tokens.tags, main_token);
}

/// `memberStartToken` over a bare tag slice, for the PARSER — which reports
/// TS1071 while it is still building the token arrays and has no
/// `scanner.Tokens` to hand. One walk, so the two callers cannot drift.
pub fn memberStartTokenIn(tags: []const scanner.Tag, main_token: u32) u32 {
    var tok = main_token;
    while (tok > 0 and isModifierKind(tags[tok - 1])) tok -= 1;
    return tok;
}

/// The first modifier an index signature may NOT carry, as an index into
/// `tags`, or null when every modifier in `tags[first..sig]` is allowed.
///
/// tsc decides this per modifier, in `checkGrammarModifiers`, and returns on
/// its first hit — so `readonly public [x: string]` answers for the `public`.
/// Measured against tsgo for all eleven modifier keywords in a class and in an
/// interface: `readonly` is always fine (an index signature is one of the four
/// positions its arm allows), `static` is fine on a CLASS index signature and
/// TS1071 on an interface's (tsc's arm asks `isClassLike(node.parent)`), and
/// every other modifier is TS1071 wherever it appears.
pub fn firstBadModifier(tags: []const scanner.Tag, first: u32, sig: u32, in_class: bool) ?u32 {
    var tok = first;
    while (tok < sig) : (tok += 1) {
        const allowed = switch (tags[tok]) {
            .keyword_readonly => true,
            .keyword_static => in_class,
            else => false,
        };
        if (!allowed) return tok;
    }
    return null;
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
    .parameter_type_bad_key = false,
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

test "an initializer earns TS2371 whatever else the chain answers" {
    var s = ok;
    s.initializer = true;
    // Alongside the chain's own TS1020, on the same token.
    try std.testing.expectEqual(Code.param_initializer_outside_impl, check(s).initializer_outside_impl.?.code);
    try std.testing.expectEqual(@as(u32, 11), check(s).initializer_outside_impl.?.token); // the NAME

    // And it outlives the two `return`s that cut the chain short: the count
    // check and the arms above `initializer` in `chainOf`.
    s = ok;
    s.initializer = true;
    s.parameters = 2;
    try std.testing.expectEqual(Code.index_sig_one_parameter, check(s).chain.?.code);
    try std.testing.expectEqual(Code.param_initializer_outside_impl, check(s).initializer_outside_impl.?.code);

    s = ok;
    s.initializer = true;
    s.question = 23;
    try std.testing.expectEqual(Code.index_sig_question_mark, check(s).chain.?.code);
    try std.testing.expectEqual(Code.param_initializer_outside_impl, check(s).initializer_outside_impl.?.code);

    // No initializer, nothing to say.
    try std.testing.expectEqual(@as(?Report, null), check(ok).initializer_outside_impl);
}

test "the modifiers an index signature may carry" {
    const T = scanner.Tag;
    const tags = [_]T{ .keyword_readonly, .keyword_static, .keyword_public, .l_bracket };
    // `readonly` alone: fine anywhere.
    try std.testing.expectEqual(@as(?u32, null), firstBadModifier(&tags, 0, 1, false));
    // `static` is fine on a CLASS index signature and TS1071 on a type
    // member's, which is the one verdict that depends on where it sits.
    try std.testing.expectEqual(@as(?u32, null), firstBadModifier(&tags, 0, 2, true));
    try std.testing.expectEqual(@as(?u32, 1), firstBadModifier(&tags, 0, 2, false));
    // The walk stops at the FIRST offender, skipping the allowed ones before
    // it: `readonly static public [x: string]` in a class answers for `public`.
    try std.testing.expectEqual(@as(?u32, 2), firstBadModifier(&tags, 0, 3, true));
    // No modifiers at all.
    try std.testing.expectEqual(@as(?u32, null), firstBadModifier(&tags, 3, 3, false));
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

test "an unvouched-for key type answers nothing, in place of the TS1268 tsc resolves" {
    // `interface I { [a: RegExp] }` is TS1268 in tsgo; ztsc cannot resolve
    // `RegExp`, so it under-reports rather than answering TS1021 for the
    // missing value type — the arm TS1268 sits in front of.
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

test "a provably illegal key type is TS1268, on the name, ahead of TS1021" {
    // `interface I { [a: boolean] }` — tsgo reports TS1268 and not the TS1021
    // the missing value type would otherwise earn.
    var s = ok;
    s.value_type = false;
    s.parameter_type_indexable = false;
    s.parameter_type_bad_key = true;
    const r = check(s).chain.?;
    try std.testing.expectEqual(Code.index_sig_key_type, r.code);
    try std.testing.expectEqual(@as(u32, 11), r.token); // the parameter NAME
    // A value type changes nothing: the key is still wrong.
    s = ok;
    s.parameter_type_indexable = false;
    s.parameter_type_bad_key = true;
    try std.testing.expectEqual(Code.index_sig_key_type, check(s).chain.?.code);
    // Everything ahead of it in the chain still outranks it.
    s.initializer = true;
    try std.testing.expectEqual(Code.index_sig_initializer, check(s).chain.?.code);
}
