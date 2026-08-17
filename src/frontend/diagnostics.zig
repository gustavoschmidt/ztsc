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
    /// TS1124: `1e`, `1E-` — an exponent marker with no digits after it.
    digit_expected,
    /// TS6188: `10_`, `0b_1`, `0._0` — a numeric separator that is not between
    /// two digits. See `literals.SeparatorWalk` for the fragment rule.
    numeric_separator_not_allowed,
    /// TS6189: `1__0` — a numeric separator directly after another one.
    multiple_numeric_separators,
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
    /// TS1352: `3en` — a BigInt suffix on a literal in exponential notation.
    bigint_exponential,
    /// TS1353: `1.5n` — a BigInt suffix on a literal that is not an integer.
    bigint_not_integer,

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
    /// TS2462: `var [...a, x] = …` / `var { ...r, a } = …` — a rest element is
    /// the LAST element of a destructuring pattern or nothing. tsc blames the
    /// bound NAME, not the `...` (measured against tsgo 7.0.2). Grammar-class,
    /// so the rest of the file is still checked.
    rest_must_be_last,
    /// Line break not allowed here (e.g. after `throw`).
    line_break_not_allowed,
    /// Trailing comma or elision where the grammar forbids it.
    argument_expected,
    /// TS1011: `a[]` — an element access with nothing between the brackets.
    /// tsc's `parseElementAccessExpression` says so where the generic
    /// "Expression expected" would otherwise land, on the `]`. Syntactic.
    element_access_needs_argument,
    /// TS1185: a `git`-style merge conflict marker (`<<<<<<< HEAD`, `=======`,
    /// `|||||||`, `>>>>>>> branch`). Reported by the scanner over the seven
    /// marker bytes; the marker and the losing side of the conflict are trivia,
    /// so the file otherwise parses as the winning side alone.
    merge_conflict_marker,
    /// TS1206: a decorator in a position the grammar forbids — see
    /// `decorator_target.zig` for which positions those are.
    decorator_not_valid_here,
    /// TS1249: `@dec m(): void;` — a decorator on a method OVERLOAD, which tsc
    /// separates out of TS1206 with its own wording.
    decorator_on_method_overload,
    /// TS1207: `@a get x() {} @b set x(v) {}` — only ONE of a get/set pair may
    /// carry modifiers, and tsc reports on the second.
    decorator_on_second_accessor,
    /// TS1433: `m(@dec this: C) {}` — a decorator on a `this` parameter, which
    /// answers ahead of TS1206 in both decorator dialects.
    ///
    /// SYNTACTIC, not grammatical, unlike every other TS12xx decorator rule:
    /// tsc raises it from the PARSER (`parseErrorAtRange(modifiers, …)`), which
    /// shows in two ways measured against tsgo 7.0.2 — it is blamed on the
    /// parameter's FULL start, the offset just past the previous token with
    /// leading trivia included rather than the `@` itself
    /// (`m(a: C,    @dec this: C)` answers at the column right after the comma),
    /// and it silences every grammar diagnostic in the file behind it, since
    /// `grammarErrorOnNode` gives up once `hasParseDiagnostics(sourceFile)`.
    decorator_on_this_param,
    /// TS1344: `label: var x = 1` — a label on a DECLARATION. tsc's grammar
    /// pass, so it is gated rather than gating.
    label_not_allowed,
    /// TS1044: a class-member accessibility (or `static`) modifier on a
    /// statement-position DECLARATION — `public var x`, `static class C`,
    /// `export public import a = x.c`. One code per modifier because tsc's
    /// message names it and a Diagnostic is a code plus a span.
    public_not_on_module_element,
    private_not_on_module_element,
    protected_not_on_module_element,
    static_not_on_module_element,
    /// TS1024: `readonly` in the same position, which tsc words by where the
    /// modifier DOES belong rather than by where it does not.
    readonly_not_on_property,
    /// TS1184: the same modifiers, but on a declaration whose statement list is
    /// NOT a module body (a function body, a plain block, a method body) — tsc
    /// stops naming the modifier there and blames the position instead.
    modifiers_not_allowed_here,
    /// A MODULE ELEMENT in a statement list that is not a module body — tsc's
    /// `checkGrammarModuleElementContext`, which asks only whether the
    /// statement's parent is a SourceFile, a ModuleBlock or a ModuleDeclaration
    /// and reports on the statement's first token. See `Parser.module_body`;
    /// one code per element kind because tsc words each for its own rule.
    ///
    /// TS1232: any `import` declaration form (`import x from "m"`, `import a =
    /// require("m")`, `import a = N.M`, `export import a = N`).
    import_not_at_top_level,
    /// TS1233: any `export` declaration form (`export { … }`, `export * from`,
    /// and their `export type` variants).
    export_not_at_top_level,
    /// TS1234: `declare module "spec" { … }` — an AMBIENT module, which unlike a
    /// namespace is not allowed even at the top level of one.
    ambient_module_not_at_top_level,
    /// TS1235: a `namespace`/`module` declaration (including `export namespace`
    /// and `declare namespace`).
    namespace_not_at_top_level,
    /// TS1231: `export = X`.
    export_assign_not_at_top_level,
    /// TS1258: `export default <expression>` (the DECLARATION forms — `export
    /// default class`/`function`/`interface` — are TS1184 instead, because tsc
    /// models their `export default` as a modifier list on the declaration).
    export_default_not_at_top_level,
    /// TS1316: `export as namespace X` — a UMD global export.
    export_as_namespace_not_at_top_level,
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

    /// TS17019/TS17020: JSDoc's nullability markers written in a `.ts` file —
    /// `T?`, `?T`, `T!`, `!T`. tsc's parser ACCEPTS all four (they build the
    /// JSDoc type nodes) and its checker reports them, so the file's semantic
    /// pass still runs; ztsc desugars them in the parser and reports here.
    /// tsc's `{0}` is the corrected type, which a code-plus-span Diagnostic
    /// cannot interpolate — the invariant sentence is what is reported, the
    /// same policy the octal-literal and reserved-word messages follow. Four
    /// codes for two tsc numbers because the message names the punctuation.
    nullable_type_postfix,
    nullable_type_prefix,
    non_nullable_type_postfix,
    non_nullable_type_prefix,

    /// TS1034: `var x = super` — `super` with no `(`, `.` or `[` after it.
    /// tsc's `parseSuperExpression` reports at the token FOLLOWING `super`
    /// (`parseExpectedToken(DotToken, …)` blames the token that should have
    /// been the dot) and then builds `super.<missing>`.
    super_needs_call_or_member,
    /// TS2809: a `{ … }` read as a BLOCK with a `=` right after it — the
    /// destructuring assignment `{ a, b } = fn()` that needed parentheses. tsc
    /// reports it in `parseBlock`, right after the closing brace, and consumes
    /// the `=`; a 2xxx number on a PARSE diagnostic, so it is syntactic.
    destructuring_assignment_needs_parens,
    /// TS2657: `<a/><b/>` in expression position — tsc's
    /// `parseJsxElementOrSelfClosingElementOrFragment` speculatively parses the
    /// second element, reports over the whole run, and joins the two with a
    /// synthetic comma. A parse diagnostic, so syntactic.
    jsx_needs_one_parent,
    /// TS18007: `<div a={x, y}/>` — a JSX expression container holds an
    /// AssignmentExpression per the JSX grammar, but tsc's parser reads a full
    /// comma sequence so its `checkGrammarJsxExpression` can say this instead
    /// of "'}' expected". Reported on the expression; grammar-class.
    jsx_comma_operator,
    /// TS1381/TS1382: a bare `}` or `>` in JSX CHILD TEXT. tsc's `scanJsxToken`
    /// reports one per byte as it walks the text — a scanner diagnostic, so
    /// syntactic, and the text still becomes a child either way.
    jsx_text_rbrace,
    jsx_text_gt,
    /// TS2566: `const { ...a: b } = o` — tsc's `parseObjectBindingElement`
    /// reads a PropertyName before it knows whether a `:` follows, so a rest
    /// element with one PARSES and `checkGrammarBindingElement` reports on the
    /// bound NAME. Grammar-class.
    rest_element_property_name,
    /// TS1540: `module M { }` — the `module` keyword spelling of a NAMESPACE is
    /// deprecated, and only the `declare module "spec" { }` ambient form may
    /// still use it. Reported on the NAME, once per segment of a dotted one
    /// (`module not.ok {}` answers twice). Grammar-class.
    module_keyword_for_namespace,
    /// TS1035: `module "M" { }` with no `declare` and outside an ambient
    /// context — a QUOTED module name declares an external module, which only
    /// an ambient declaration may do. A `.d.ts` is ambient from its first token,
    /// so the same source is silent there. Reported on the name; grammar-class.
    quoted_module_name_needs_ambient,
    /// TS1437: `module { }` — a namespace declaration with no name at all.
    /// Reported on the `{`; grammar-class.
    namespace_needs_a_name,
    /// TS1107: `while (c) { function f() { break; } }` — a `break`/`continue`
    /// whose target lies outside the function it sits in. tsc walks out of the
    /// statement and answers as soon as it reaches a function-like, before it
    /// ever finds the loop, switch or label the jump names. Reported on the
    /// keyword; grammar-class.
    jump_crosses_function_boundary,
    /// TS1248: `class C { const x = 1 }` — `const` is not a class-member
    /// modifier. tsc's message names the keyword, and `const` is the only one
    /// that reaches it. Reported on the member NAME (measured against
    /// tsgo 7.0.2, which blames the `H` of `static const H = 1`);
    /// grammar-class.
    const_class_member,
    /// TS1443: ``declare module `M` { }`` — a module name is a `'`/`"` string,
    /// never a template. Reported on the template.
    ///
    /// SYNTACTIC, like TS1433 and unlike its TS1035 neighbour: tsc raises it
    /// from the PARSER, so it silences every grammar diagnostic in the file
    /// behind it. Measured — ``module "M" { }`` beside a templated one loses
    /// both its TS1035 and the TS1155 of an uninitialized `const` inside it.
    module_name_needs_quoted_string,

    // --- modifier order and repetition (tsc's `checkGrammarModifiers`) -------
    /// TS1030 `'{0}' modifier already seen.` — the same modifier twice on one
    /// declaration. One code per modifier because tsc's message NAMES it and a
    /// Diagnostic is a code plus a span; `see modifier_order.zig` for the walk
    /// that picks between these and the TS1029 pairs below. The accessibility
    /// trio is NOT here: tsc words a repeat of `public`/`private`/`protected`
    /// as TS1028 without naming which one, which is
    /// `accessibility_modifier_already_seen`.
    mod_seen_static,
    mod_seen_readonly,
    mod_seen_accessor,
    mod_seen_override,
    mod_seen_async,
    mod_seen_abstract,
    mod_seen_declare,
    /// `export export class C {}` — the one repeat a STATEMENT-level modifier
    /// run can spell. Reported by `parseExportStatement`, not by the class-member
    /// walk, because `export` is not a class-member modifier at all.
    mod_seen_export,
    /// TS1029 `'{0}' modifier must precede '{1}' modifier.` — two modifiers in
    /// the wrong order. tsc's walk reports the SECOND one and names both, so
    /// there is one code per ordered pair it can reach; the pairs below are the
    /// ones a class member or a parameter property can reach (the statement-level
    /// `export`/`declare`/`default` trio is a separate walk and still an
    /// under-report). `in_must_precede_out` is TS1029 too — the type-parameter
    /// pair, named for its own rule because it predates this table.
    mod_order_public_static,
    mod_order_private_static,
    mod_order_protected_static,
    mod_order_public_override,
    mod_order_private_override,
    mod_order_protected_override,
    mod_order_public_accessor,
    mod_order_private_accessor,
    mod_order_protected_accessor,
    mod_order_public_readonly,
    mod_order_private_readonly,
    mod_order_protected_readonly,
    mod_order_public_async,
    mod_order_private_async,
    mod_order_protected_async,
    mod_order_public_abstract,
    mod_order_protected_abstract,
    mod_order_static_readonly,
    mod_order_static_async,
    mod_order_static_accessor,
    mod_order_static_override,
    mod_order_override_readonly,
    mod_order_override_accessor,
    mod_order_override_async,
    mod_order_abstract_override,
    mod_order_abstract_accessor,
    /// `declare export const x` — the statement-level pair, reported by the
    /// `declare export` arm of `parseStatementUnchecked` on the `export`.
    mod_order_export_declare,

    /// TS1385/TS1386/TS1387/TS1388: `type U = string | () => void` — a function
    /// or constructor type written bare as a union or intersection CONSTITUENT,
    /// where the grammar wants parentheses. tsc's
    /// `parseFunctionOrConstructorTypeToError` parses it anyway ("we'll try to
    /// parse them gracefully and issue a helpful message") and reports over the
    /// whole constituent, which is why this is one diagnostic rather than the
    /// TS1110/TS1005/TS1109 cascade a refusal produces. Four codes because the
    /// message names both the notation and the operator.
    fn_type_in_union,
    ctor_type_in_union,
    fn_type_in_intersection,
    ctor_type_in_intersection,

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
    /// TS2395: two declarations of one name that DO merge, one `export`ed and
    /// one not, claiming a declaration space in common — tsc's
    /// `checkExportsOnMergedDeclarations`. Reported at the name of every
    /// declaration that contributed to the shared space. See `decl_spaces.zig`
    /// for the rule and for why the duplicate-identifier diagnostic that would
    /// otherwise cover the pair is deliberately absent.
    merged_decl_export_mismatch,
    /// TS2391: a function/method whose LAST non-ambient declaration has no
    /// body, so the overload set has no implementation. See
    /// `impl_expected.zig`.
    missing_function_implementation,
    /// TS2390: the same for a class CONSTRUCTOR, which tsc gives its own
    /// message.
    missing_constructor_implementation,
    /// TS2516: the same, for an ABSTRACT method — which is legally bodyless, so
    /// the only way its declarations can be wrong is by not being consecutive.
    /// Only the non-consecutive arm reaches it.
    abstract_decls_not_consecutive,
    /// TS2432: a second block of a merged `enum` whose first member omits its
    /// initializer. Reported on that member.
    enum_first_member_needs_initializer,
    /// TS2434: an instantiated namespace block written BEFORE the class or
    /// function it merges with. Reported on the namespace's name.
    namespace_prior_to_merge,
    /// TS2492: redeclaring a catch-clause parameter in the catch block.
    catch_redeclare,
    /// TS2389: the declaration immediately after an overload signature HAS a
    /// body but a different name, so the set never got its implementation and
    /// the body belongs to something else. tsc's message names the expected
    /// name; a Diagnostic here is a code plus a span, so the invariant half of
    /// the sentence is what is reported (the policy TS2300 already follows).
    /// Blamed on the misnamed implementation, not on the signature.
    overload_impl_name_mismatch,
    /// TS2387/TS2388: a mixed static/instance overload set — two same-named
    /// methods of one class, one `static` and one not, so neither side has an
    /// implementation. tsc words it as an instruction to the SECOND declaration
    /// and reports on its name.
    overload_must_be_static,
    overload_must_not_be_static,
    /// TS2369: an accessibility/`readonly`/`override` modifier on a parameter
    /// of anything other than a constructor WITH A BODY — an overload
    /// signature, an ambient `declare class` constructor, a method, an
    /// accessor, an arrow, or a bare function type. A parameter property
    /// declares a class member, so the one position that can honour it is the
    /// constructor whose body would do the assigning (tsc's `checkParameter`).
    /// Reported over the parameter's first token, which is the modifier.
    param_property_outside_ctor_impl,
    /// TS2398: a parameter property named `constructor`. The modifier turns the
    /// parameter into a class member, and `constructor` is the one member name
    /// a class cannot have — the constructor itself already owns that slot in
    /// the prototype (tsc keys it under the reserved `__constructor`, so the
    /// two never collide and the name is rejected outright instead). Reported
    /// on the parameter's NAME, not on its modifier.
    ctor_as_param_property_name,
    /// TS1341: `get constructor()` / `set constructor(v)` in a class. tsc's
    /// parser makes a method named `constructor` a ConstructorDeclaration but an
    /// ACCESSOR of that name an ordinary accessor, and then rejects it: the
    /// prototype's `constructor` slot is not a place an accessor can go.
    /// Reported on the name token, and NOT gated on `static` (`static get
    /// constructor` reports too — verified against tsgo 7.0.2).
    ctor_may_not_be_accessor,
    /// TS2528: two `export default`s that cannot share the slot. Not every pair
    /// collides — function overloads merge, and a function and an interface are
    /// legal side by side — so the rule is tsc's `declareSymbol` includes/
    /// excludes algebra on the reserved `default` export name, with only the
    /// MESSAGE special-cased (a collision on any other name is TS2300). See
    /// default_exports.zig. Reported on each colliding declaration's name, or on
    /// the whole `export default` statement when it declares no name.
    multiple_default_exports,
    /// TS17009: `this` reached in a derived class's constructor on a path that
    /// has not run `super(...)` yet — the base constructor is what brings the
    /// instance into existence. Reported on the `this` keyword. Flow-sensitive
    /// (tsc's `isPostSuperFlowNode`), so `if (c) { super() } this.x` reports
    /// even though the `super` call comes first in the text.
    super_before_this,
    /// TS17011: the same rule for `super.x` (or `super["x"]`) — a property of
    /// the base prototype reached before the base constructor has run. tsc's
    /// `checkSuperExpression`, which exempts the `super` that IS the call.
    super_before_super_property,

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
    /// TS1191: a modifier on an ES6 import declaration — `export import d from
    /// "m"`, which tsc parses as an ImportDeclaration carrying an `export` and
    /// then rejects in `checkGrammarModifiers`. Reported on the modifier.
    /// `export import A = B.C;` is a different declaration (an
    /// ImportEqualsDeclaration) and is legal.
    import_cannot_have_modifiers,

    /// tsc's `checkGrammarIndexSignatureParameters`, in its own order — see
    /// `src/frontend/index_signature.zig`, which decides which one fires. The
    /// brackets PARSE as a parameter list, so all of these sit next to whatever
    /// the file's semantic pass has to say.
    /// TS1096: `[a, b]: T` (or `[]: T`).
    index_sig_one_parameter,
    /// TS1025: `[key: string,]: T`.
    index_sig_trailing_comma,
    /// TS1017: `[...rest: any[]]: T`.
    index_sig_rest_parameter,
    /// TS1018: `[public k: string]: T`.
    index_sig_accessibility_modifier,
    /// TS1019: `[k?: string]: T`.
    index_sig_question_mark,
    /// TS1020: `[k: string = "a"]: T`.
    index_sig_initializer,
    /// TS1022: `[k]: T` reached as an index signature — only via a shape tsc's
    /// lookahead claims for one, e.g. `[k,]`.
    index_sig_parameter_type_annotation,
    /// TS1021: `[k: string]` with no value type. Reported on the whole node.
    index_sig_type_annotation,
    /// TS2452: `enum E { 1, 2 }` — a numeric literal as an enum member name.
    /// The grammar ACCEPTS it (it is a PropertyName), so this is a check on a
    /// parsed member, not a parse failure; rejecting it in the parser instead
    /// cost a false TS1003 plus the file's whole semantic pass.
    enum_member_numeric_name,
    /// TS1164: `enum E { [foo] = 1 }` — a computed enum member name that does not
    /// wrap a string, numeric or no-substitution-template literal. The literal
    /// forms ARE legal (`["4"]`, `[2]`, `` [`a`] ``, measured), and their name is
    /// the literal's own, so only the rest reach this.
    computed_name_in_enum,
    /// TS1166: `class C { ["a" + "b"]: number }` — a computed CLASS PROPERTY
    /// name that cannot name a property. See `computed_member.zig` for the rule
    /// and for why the four siblings below differ only in wording.
    computed_name_in_class_property,
    /// TS1168: `class C { ["a" + "b"](): void }` — the same key on a method
    /// with no body (an overload signature or an `abstract` method).
    computed_name_in_method_overload,
    /// TS1165: `declare class C { ["a" + "b"](): void }` — the same key on a
    /// method in an ambient context.
    computed_name_in_ambient_context,
    /// TS1169: `interface I { ["a" + "b"]: number }`.
    computed_name_in_interface,
    /// TS1170: `type T = { ["a" + "b"]: number }`.
    computed_name_in_type_literal,
    /// TS18024: `enum E { #x }` — a private identifier as an enum member name.
    enum_member_private_name,
    /// TS1539: `{ 1n: 123 }` — a BigInt literal as a property name. The grammar
    /// accepts it (a BigInt literal is a NumericLiteral-shaped PropertyName), so
    /// like TS2452 this is a check on a parsed member; tsc reports it in the
    /// three positions that DECLARE a member — an object literal, a type member
    /// and a class member — and NOT in a binding pattern, where `{ 0n: f }`
    /// parses and earns the semantic TS2538 instead (measured against tsgo).
    bigint_property_name,
    /// TS18016: `#x` as an OBJECT-LITERAL property name (`{ #x: 1 }`) or a TYPE
    /// member name (`interface I { #x: string }`) — the two property positions
    /// that are never inside a class body. tsc's `checkGrammarObjectLiteral…`
    /// and its type-member equivalent.
    private_name_outside_class,
    /// TS18029: `const #foo = 3` — a private identifier where a variable BINDING
    /// name belongs. tsc's parser reports and then reads the token as the name
    /// anyway (`createIdentifier`), which is why there is no cascade after it.
    private_name_in_var_decl,
    /// TS18009: `f(#foo: string)` — the same, in a PARAMETER list.
    private_name_as_param,
    /// TS1492: `using { a } = d` — an explicit-resource declaration binds one
    /// name, never a pattern. tsc's `checkGrammarVariableDeclaration`, reported
    /// on the pattern; two codes because the message names the declaration form
    /// and `await using` spells it differently.
    using_binding_pattern,
    await_using_binding_pattern,

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
    /// TS1359: a reserved word standing where a *BindingIdentifier* is required,
    /// which for ztsc means one thing — `await` inside an await context (an
    /// `async` function's parameters and body, or a class static block). tsc's
    /// `createIdentifier` prefers this wording over TS1003 whenever the token is
    /// a reserved word. Like the TS1212 family above, the message drops the word
    /// tsc names; like them, it is a GRAMMAR diagnostic (measured — see
    /// `class`), despite reading as parser code in tsc.
    reserved_word_here,

    // --- class static blocks (tsc's `checkGrammar*`, so all four are semantic)
    /// TS18037: `await x` inside a static block. The operator parses — a static
    /// block IS an await context — but a static initializer cannot await.
    await_in_static_block,
    /// TS18038: the same for `for await (… of …)`, worded for the loop.
    for_await_in_static_block,
    /// TS18041: `return` inside a static block. A block is a function-like
    /// container, so the parse is fine; there is just nothing to return to.
    return_in_static_block,
    /// TS1163: `yield` inside a static block — a container that is not a
    /// generator body. Outside one, a `yield` in non-generator code is the
    /// TS1212/TS1213 reserved-word family instead.
    yield_not_in_generator,
    /// TS1108: a `return` with no function body around it at all. A class field
    /// initializer counts as one (it runs as an implicit function), so this is
    /// only the file/namespace top level.
    return_outside_function,

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
            .merged_decl_export_mismatch,
            .missing_function_implementation,
            .missing_constructor_implementation,
            .abstract_decls_not_consecutive,
            .enum_first_member_needs_initializer,
            .namespace_prior_to_merge,
            .catch_redeclare,
            .overload_impl_name_mismatch,
            .overload_must_be_static,
            .overload_must_not_be_static,
            .param_property_outside_ctor_impl,
            .ctor_as_param_property_name,
            .multiple_default_exports,
            .super_before_this,
            .super_before_super_property,
            .decorator_not_valid_here,
            .decorator_on_method_overload,
            .decorator_on_second_accessor,
            .module_keyword_for_namespace,
            .quoted_module_name_needs_ambient,
            .namespace_needs_a_name,
            .const_class_member,
            .jump_crosses_function_boundary,
            .label_not_allowed,
            .public_not_on_module_element,
            .private_not_on_module_element,
            .protected_not_on_module_element,
            .static_not_on_module_element,
            .readonly_not_on_property,
            .modifiers_not_allowed_here,
            // Same funnel as TS1184: `{ import "m"; }` next to a sibling file's
            // TS2322 lets the TS2322 through, and `moduleElementsInWrongContext.ts`
            // reports its whole set with nothing suppressed — tsc's checker.
            .import_not_at_top_level,
            .export_not_at_top_level,
            .ambient_module_not_at_top_level,
            .namespace_not_at_top_level,
            .export_assign_not_at_top_level,
            .export_default_not_at_top_level,
            .export_as_namespace_not_at_top_level,
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
            // Same funnel as TS1184/TS1044 — `checkGrammarModifiers`.
            .import_cannot_have_modifiers,
            // `checkGrammarIndexSignatureParameters`, likewise the checker's:
            // `[public x: string]: string` answers TS1018 next to the TS2369 its
            // parameter property earns, and `[a: number = 1]: number` answers
            // TS1020 next to a TS2371 (measured).
            .index_sig_one_parameter,
            .index_sig_trailing_comma,
            .index_sig_rest_parameter,
            .index_sig_accessibility_modifier,
            .index_sig_question_mark,
            .index_sig_initializer,
            .index_sig_parameter_type_annotation,
            .index_sig_type_annotation,
            .enum_member_numeric_name,
            .enum_member_private_name,
            .computed_name_in_enum,
            // The TS116x family is `checkGrammarProperty`/`checkGrammarMethod`
            // in tsc's CHECKER, so a real parse error suppresses it exactly as
            // it suppresses a TS2322: `class C { ["a" + "b"]: number = 1 }`
            // next to `const q: string = 1` reports both, and adding
            // `let z = 1 + ;` leaves only the TS1109 (measured, `t/k6.ts`).
            .computed_name_in_class_property,
            .computed_name_in_method_overload,
            .computed_name_in_ambient_context,
            .computed_name_in_interface,
            .computed_name_in_type_literal,
            // `{ 1n: 123 }` reports TS1539 next to the TS2464/TS2538 its
            // siblings earn in the same file — tsc's checker.
            .bigint_property_name,
            .private_name_outside_class,
            // `using {a} = null` reports TS1492 and the TS2339 its pattern
            // earns in the same run — tsc's checker, not its parser.
            .using_binding_pattern,
            .await_using_binding_pattern,
            .strict_reserved_word,
            .strict_reserved_word_in_class,
            .strict_reserved_word_in_module,
            // The four static-block rules and TS1108 are `checkGrammar*` in
            // tsc's CHECKER (`checkAwaitExpression`, `checkForOfStatement`,
            // `checkClassStaticBlockDeclaration`, `checkYieldExpression`,
            // `checkReturnStatement`) — TS1xxx numbers on semantic
            // diagnostics, so a syntactic error anywhere suppresses them.
            // `classStaticBlock7.ts` reports its TS18037/TS1163/TS18041 set
            // with nothing else in the file, and adding a sibling TS2322
            // leaves both standing.
            //
            // TS1359 belongs here too, which is a MEASURED surprise: tsc's
            // `createIdentifier` is parser code, yet `class C { static { let
            // await = 1 } }` next to `const q: string = 1` reports the TS1359
            // AND the TS2322 AND a sibling function's TS1212 — so tsgo files
            // this one with the grammar pass, not with the parse diagnostics.
            .reserved_word_here,
            .await_in_static_block,
            .for_await_in_static_block,
            .return_in_static_block,
            .yield_not_in_generator,
            .return_outside_function,
            // Same pass as the TS1212 family: tsc's binder, so semantic.
            .eval_in_strict,
            .arguments_in_strict,
            .eval_in_class,
            .arguments_in_class,
            .eval_in_module,
            .arguments_in_module,
            // `let a: string?` next to a sibling file's TS2322 lets the TS2322
            // through, and `parseInvalidNullableTypes.ts` answers TS2322/TS2677
            // alongside its own TS17019s — tsc's checker, not its parser.
            .nullable_type_postfix,
            .nullable_type_prefix,
            .non_nullable_type_postfix,
            .non_nullable_type_prefix,
            // `<div a={x, y}/>` answers TS18007 *and* the TS2695 the comma
            // expression earns in the same run, and `const { ...a: b } = o`
            // answers TS2566 with nothing suppressed — both are
            // `checkGrammar*` in tsc's CHECKER. Their three siblings above
            // (TS1034/TS2809/TS2657) are `parseDiagnostics` and so stay
            // syntactic, which is why the same batch splits across the two
            // classes.
            .jsx_comma_operator,
            .rest_element_property_name,
            // `checkGrammarModifiers` is the same checker pass that already
            // owns TS1028 and TS1274 above: the m6 probe answers its whole
            // TS1030/TS1029 set next to a TS2515 and a TS4112 in the same file,
            // with nothing suppressed either way.
            .mod_seen_static,
            .mod_seen_readonly,
            .mod_seen_accessor,
            .mod_seen_override,
            .mod_seen_async,
            .mod_seen_abstract,
            .mod_seen_declare,
            .mod_seen_export,
            .mod_order_public_static,
            .mod_order_private_static,
            .mod_order_protected_static,
            .mod_order_public_override,
            .mod_order_private_override,
            .mod_order_protected_override,
            .mod_order_public_accessor,
            .mod_order_private_accessor,
            .mod_order_protected_accessor,
            .mod_order_public_readonly,
            .mod_order_private_readonly,
            .mod_order_protected_readonly,
            .mod_order_public_async,
            .mod_order_private_async,
            .mod_order_protected_async,
            .mod_order_public_abstract,
            .mod_order_protected_abstract,
            .mod_order_static_readonly,
            .mod_order_static_async,
            .mod_order_static_accessor,
            .mod_order_static_override,
            .mod_order_override_readonly,
            .mod_order_override_accessor,
            .mod_order_override_async,
            .mod_order_abstract_override,
            .mod_order_abstract_accessor,
            .mod_order_export_declare,
            .ctor_may_not_be_accessor,
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
            // Also the scanner's, and reported from the same place tsc does.
            .merge_conflict_marker => "Merge conflict marker encountered.",
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
            .digit_expected => "Digit expected.",
            .numeric_separator_not_allowed => "Numeric separators are not allowed here.",
            .multiple_numeric_separators => "Multiple consecutive numeric separators are not permitted.",
            .binary_digit_expected => "Binary digit expected.",
            .octal_digit_expected => "Octal digit expected.",
            .unicode_escape_out_of_range => "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.",
            .unterminated_unicode_escape => "Unterminated Unicode escape sequence.",
            .identifier_after_numeric_literal => "An identifier or keyword cannot immediately follow a numeric literal.",
            .bigint_exponential => "A bigint literal cannot use exponential notation.",
            .bigint_not_integer => "A bigint literal must be an integer.",
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
            .rest_must_be_last => "A rest element must be last in a destructuring pattern.",
            .line_break_not_allowed => "Line break not permitted here.",
            .argument_expected => "Argument expression expected.",
            .statement_not_allowed_in_ambient => "Statements are not allowed in ambient contexts.",
            .implementation_not_allowed_in_ambient => "An implementation cannot be declared in ambient contexts.",
            .accessibility_modifier_already_seen => "Accessibility modifier already seen.",
            .import_cannot_have_modifiers => "An import declaration cannot have modifiers.",
            .index_sig_one_parameter => "An index signature must have exactly one parameter.",
            .index_sig_trailing_comma => "An index signature cannot have a trailing comma.",
            .index_sig_rest_parameter => "An index signature cannot have a rest parameter.",
            .index_sig_accessibility_modifier => "An index signature parameter cannot have an accessibility modifier.",
            .index_sig_question_mark => "An index signature parameter cannot have a question mark.",
            .index_sig_initializer => "An index signature parameter cannot have an initializer.",
            .index_sig_parameter_type_annotation => "An index signature parameter must have a type annotation.",
            .index_sig_type_annotation => "An index signature must have a type annotation.",
            .enum_member_numeric_name => "An enum member cannot have a numeric name.",
            .enum_member_private_name => "An enum member cannot be named with a private identifier.",
            .computed_name_in_enum => "Computed property names are not allowed in enums.",
            .computed_name_in_class_property => "A computed property name in a class property declaration must have a simple literal type or a 'unique symbol' type.",
            .computed_name_in_method_overload => "A computed property name in a method overload must refer to an expression whose type is a literal type or a 'unique symbol' type.",
            .computed_name_in_ambient_context => "A computed property name in an ambient context must refer to an expression whose type is a literal type or a 'unique symbol' type.",
            .computed_name_in_interface => "A computed property name in an interface must refer to an expression whose type is a literal type or a 'unique symbol' type.",
            .computed_name_in_type_literal => "A computed property name in a type literal must refer to an expression whose type is a literal type or a 'unique symbol' type.",
            .bigint_property_name => "A 'bigint' literal cannot be used as a property name.",
            .private_name_outside_class => "Private identifiers are not allowed outside class bodies.",
            .private_name_in_var_decl => "Private identifiers are not allowed in variable declarations.",
            .private_name_as_param => "Private identifiers cannot be used as parameters.",
            .using_binding_pattern => "'using' declarations may not have binding patterns.",
            .await_using_binding_pattern => "'await using' declarations may not have binding patterns.",
            // tsc names the word (`'yield' is a reserved word...`); a Diagnostic
            // is a code plus a span, so the invariant sentence is reported.
            .strict_reserved_word => "Identifier expected. This is a reserved word in strict mode.",
            .strict_reserved_word_in_class => "Identifier expected. This is a reserved word in strict mode. Class definitions are automatically in strict mode.",
            .strict_reserved_word_in_module => "Identifier expected. This is a reserved word in strict mode. Modules are automatically in strict mode.",
            .reserved_word_here => "Identifier expected. This is a reserved word that cannot be used here.",
            .await_in_static_block => "'await' expression cannot be used inside a class static block.",
            .for_await_in_static_block => "'for await' loops cannot be used inside a class static block.",
            .return_in_static_block => "A 'return' statement cannot be used inside a class static block.",
            .yield_not_in_generator => "A 'yield' expression is only allowed in a generator body.",
            .return_outside_function => "A 'return' statement can only be used within a function body.",
            .eval_in_strict => evalStrictMessage("eval"),
            .arguments_in_strict => evalStrictMessage("arguments"),
            .eval_in_class => evalClassMessage("eval"),
            .arguments_in_class => evalClassMessage("arguments"),
            .eval_in_module => evalModuleMessage("eval"),
            .arguments_in_module => evalModuleMessage("arguments"),
            .decorator_not_valid_here => "Decorators are not valid here.",
            .decorator_on_method_overload => "A decorator can only decorate a method implementation, not an overload.",
            .decorator_on_second_accessor => "Decorators cannot be applied to multiple get/set accessors of the same name.",
            .decorator_on_this_param => "Neither decorators nor modifiers may be applied to 'this' parameters.",
            .label_not_allowed => "A label is not allowed here.",
            .public_not_on_module_element => moduleElementModifierMessage("public"),
            .private_not_on_module_element => moduleElementModifierMessage("private"),
            .protected_not_on_module_element => moduleElementModifierMessage("protected"),
            .static_not_on_module_element => moduleElementModifierMessage("static"),
            .readonly_not_on_property => "'readonly' modifier can only appear on a property declaration or index signature.",
            .modifiers_not_allowed_here => "Modifiers cannot appear here.",
            .import_not_at_top_level => "An import declaration can only be used at the top level of a namespace or module.",
            .export_not_at_top_level => "An export declaration can only be used at the top level of a namespace or module.",
            .ambient_module_not_at_top_level => "An ambient module declaration is only allowed at the top level in a file.",
            .namespace_not_at_top_level => "A namespace declaration is only allowed at the top level of a namespace or module.",
            .export_assign_not_at_top_level => "An export assignment must be at the top level of a file or module declaration.",
            .export_default_not_at_top_level => "A default export must be at the top level of a file or module declaration.",
            .export_as_namespace_not_at_top_level => "Global module exports may only appear at top level.",
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
            .nullable_type_postfix => jsdocMarkerMessage("?", "end"),
            .nullable_type_prefix => jsdocMarkerMessage("?", "start"),
            .non_nullable_type_postfix => jsdocMarkerMessage("!", "end"),
            .non_nullable_type_prefix => jsdocMarkerMessage("!", "start"),
            .super_needs_call_or_member => "'super' must be followed by an argument list or member access.",
            .destructuring_assignment_needs_parens => "Declaration or statement expected. This '=' follows a block of statements, so if you intended to write a destructuring assignment, you might need to wrap the whole assignment in parentheses.",
            .jsx_needs_one_parent => "JSX expressions must have one parent element.",
            .jsx_text_rbrace => "Unexpected token. Did you mean `{'}'}` or `&rbrace;`?",
            .jsx_text_gt => "Unexpected token. Did you mean `{'>'}` or `&gt;`?",
            .module_keyword_for_namespace => "A 'namespace' declaration should not be declared using the 'module' keyword. Please use the 'namespace' keyword instead.",
            .quoted_module_name_needs_ambient => "Only ambient modules can use quoted names.",
            .namespace_needs_a_name => "Namespace must be given a name.",
            .const_class_member => "A class member cannot have the 'const' keyword.",
            .jump_crosses_function_boundary => "Jump target cannot cross function boundary.",
            .element_access_needs_argument => "An element access expression should take an argument.",
            .module_name_needs_quoted_string => "Module declaration names may only use ' or \" quoted strings.",
            .jsx_comma_operator => "JSX expressions may not use the comma operator. Did you mean to write an array?",
            .rest_element_property_name => "A rest element cannot have a property name.",
            .mod_seen_static => modSeenMessage("static"),
            .mod_seen_readonly => modSeenMessage("readonly"),
            .mod_seen_accessor => modSeenMessage("accessor"),
            .mod_seen_override => modSeenMessage("override"),
            .mod_seen_async => modSeenMessage("async"),
            .mod_seen_abstract => modSeenMessage("abstract"),
            .mod_seen_declare => modSeenMessage("declare"),
            .mod_seen_export => modSeenMessage("export"),
            .mod_order_public_static => modOrderMessage("public", "static"),
            .mod_order_private_static => modOrderMessage("private", "static"),
            .mod_order_protected_static => modOrderMessage("protected", "static"),
            .mod_order_public_override => modOrderMessage("public", "override"),
            .mod_order_private_override => modOrderMessage("private", "override"),
            .mod_order_protected_override => modOrderMessage("protected", "override"),
            .mod_order_public_accessor => modOrderMessage("public", "accessor"),
            .mod_order_private_accessor => modOrderMessage("private", "accessor"),
            .mod_order_protected_accessor => modOrderMessage("protected", "accessor"),
            .mod_order_public_readonly => modOrderMessage("public", "readonly"),
            .mod_order_private_readonly => modOrderMessage("private", "readonly"),
            .mod_order_protected_readonly => modOrderMessage("protected", "readonly"),
            .mod_order_public_async => modOrderMessage("public", "async"),
            .mod_order_private_async => modOrderMessage("private", "async"),
            .mod_order_protected_async => modOrderMessage("protected", "async"),
            .mod_order_public_abstract => modOrderMessage("public", "abstract"),
            .mod_order_protected_abstract => modOrderMessage("protected", "abstract"),
            .mod_order_static_readonly => modOrderMessage("static", "readonly"),
            .mod_order_static_async => modOrderMessage("static", "async"),
            .mod_order_static_accessor => modOrderMessage("static", "accessor"),
            .mod_order_static_override => modOrderMessage("static", "override"),
            .mod_order_override_readonly => modOrderMessage("override", "readonly"),
            .mod_order_override_accessor => modOrderMessage("override", "accessor"),
            .mod_order_override_async => modOrderMessage("override", "async"),
            .mod_order_abstract_override => modOrderMessage("abstract", "override"),
            .mod_order_abstract_accessor => modOrderMessage("abstract", "accessor"),
            .mod_order_export_declare => modOrderMessage("export", "declare"),
            .fn_type_in_union => "Function type notation must be parenthesized when used in a union type.",
            .ctor_type_in_union => "Constructor type notation must be parenthesized when used in a union type.",
            .fn_type_in_intersection => "Function type notation must be parenthesized when used in an intersection type.",
            .ctor_type_in_intersection => "Constructor type notation must be parenthesized when used in an intersection type.",
            .duplicate_identifier => "duplicate identifier",
            .block_scoped_redeclare => "cannot redeclare block-scoped variable",
            .enum_merge_conflict => "Enum declarations can only merge with namespace or other enum declarations.",
            .duplicate_function_implementation => "duplicate function implementation",
            .duplicate_constructor_implementation => "Multiple constructor implementations are not allowed.",
            .class_cannot_implement_overloads => "Class declaration cannot implement overload list.",
            .function_merge_needs_ambient_class => "Function with bodies can only merge with classes that are ambient.",
            .import_conflict => "import declaration conflicts with local declaration",
            .merged_decl_export_mismatch => "Individual declarations in merged declaration must be all exported or all local.",
            .missing_function_implementation => "Function implementation is missing or not immediately following the declaration.",
            .missing_constructor_implementation => "Constructor implementation is missing.",
            .abstract_decls_not_consecutive => "All declarations of an abstract method must be consecutive.",
            .enum_first_member_needs_initializer => "In an enum with multiple declarations, only one declaration can omit an initializer for its first enum element.",
            .namespace_prior_to_merge => "A namespace declaration cannot be located prior to a class or function with which it is merged.",
            .catch_redeclare => "cannot redeclare identifier in catch clause",
            .overload_impl_name_mismatch => "function implementation name must match the overload it follows",
            .overload_must_be_static => "Function overload must be static.",
            .overload_must_not_be_static => "Function overload must not be static.",
            .param_property_outside_ctor_impl => "A parameter property is only allowed in a constructor implementation.",
            .ctor_as_param_property_name => "'constructor' cannot be used as a parameter property name.",
            .ctor_may_not_be_accessor => "Class constructor may not be an accessor.",
            .multiple_default_exports => "A module cannot have multiple default exports.",
            .super_before_this => "'super' must be called before accessing 'this' in the constructor of a derived class.",
            .super_before_super_property => "'super' must be called before accessing a property of 'super' in the constructor of a derived class.",
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
            .merge_conflict_marker => 1185,
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
            .digit_expected => 1124,
            .numeric_separator_not_allowed => 6188,
            .multiple_numeric_separators => 6189,
            .binary_digit_expected => 1177,
            .octal_digit_expected => 1178,
            .unicode_escape_out_of_range => 1198,
            .identifier_after_numeric_literal => 1351,
            .bigint_exponential => 1352,
            .bigint_not_integer => 1353,
            .unterminated_unicode_escape => 1199,
            .nullish_mixed_with_logical => 5076,
            .tagged_template_in_optional_chain => 1358,
            .newline_before_arrow => 1200,
            .multiple_default_clauses => 1113,
            .line_break_not_allowed => 1142,
            .statement_not_allowed_in_ambient => 1036,
            .implementation_not_allowed_in_ambient => 1183,
            .accessibility_modifier_already_seen => 1028,
            .import_cannot_have_modifiers => 1191,
            .index_sig_one_parameter => 1096,
            .index_sig_trailing_comma => 1025,
            .index_sig_rest_parameter => 1017,
            .index_sig_accessibility_modifier => 1018,
            .index_sig_question_mark => 1019,
            .index_sig_initializer => 1020,
            .index_sig_parameter_type_annotation => 1022,
            .index_sig_type_annotation => 1021,
            .enum_member_numeric_name => 2452,
            .enum_member_private_name => 18024,
            .computed_name_in_enum => 1164,
            .computed_name_in_class_property => 1166,
            .computed_name_in_method_overload => 1168,
            .computed_name_in_ambient_context => 1165,
            .computed_name_in_interface => 1169,
            .computed_name_in_type_literal => 1170,
            .bigint_property_name => 1539,
            .private_name_outside_class => 18016,
            .private_name_in_var_decl => 18029,
            .private_name_as_param => 18009,
            .using_binding_pattern, .await_using_binding_pattern => 1492,
            .strict_reserved_word => 1212,
            .strict_reserved_word_in_class => 1213,
            .strict_reserved_word_in_module => 1214,
            .reserved_word_here => 1359,
            .await_in_static_block => 18037,
            .for_await_in_static_block => 18038,
            .return_in_static_block => 18041,
            .yield_not_in_generator => 1163,
            .return_outside_function => 1108,
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
            .merged_decl_export_mismatch => 2395,
            .missing_function_implementation => 2391,
            .missing_constructor_implementation => 2390,
            .abstract_decls_not_consecutive => 2516,
            .enum_first_member_needs_initializer => 2432,
            .namespace_prior_to_merge => 2434,
            .catch_redeclare => 2492,
            .overload_impl_name_mismatch => 2389,
            .overload_must_be_static => 2387,
            .overload_must_not_be_static => 2388,
            .param_property_outside_ctor_impl => 2369,
            .ctor_as_param_property_name => 2398,
            .ctor_may_not_be_accessor => 1341,
            .multiple_default_exports => 2528,
            .super_before_this => 17009,
            .super_before_super_property => 17011,
            .decorator_not_valid_here => 1206,
            .decorator_on_method_overload => 1249,
            .decorator_on_second_accessor => 1207,
            .decorator_on_this_param => 1433,
            .label_not_allowed => 1344,
            .public_not_on_module_element,
            .private_not_on_module_element,
            .protected_not_on_module_element,
            .static_not_on_module_element,
            => 1044,
            .readonly_not_on_property => 1024,
            .modifiers_not_allowed_here => 1184,
            .import_not_at_top_level => 1232,
            .export_not_at_top_level => 1233,
            .ambient_module_not_at_top_level => 1234,
            .namespace_not_at_top_level => 1235,
            .export_assign_not_at_top_level => 1231,
            .export_default_not_at_top_level => 1258,
            .export_as_namespace_not_at_top_level => 1316,
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
            .nullable_type_postfix, .non_nullable_type_postfix => 17019,
            .nullable_type_prefix, .non_nullable_type_prefix => 17020,
            .super_needs_call_or_member => 1034,
            .destructuring_assignment_needs_parens => 2809,
            .jsx_needs_one_parent => 2657,
            .jsx_text_rbrace => 1381,
            .jsx_text_gt => 1382,
            .module_keyword_for_namespace => 1540,
            .quoted_module_name_needs_ambient => 1035,
            .namespace_needs_a_name => 1437,
            .const_class_member => 1248,
            .jump_crosses_function_boundary => 1107,
            .element_access_needs_argument => 1011,
            .rest_must_be_last => 2462,
            .module_name_needs_quoted_string => 1443,
            .jsx_comma_operator => 18007,
            .rest_element_property_name => 2566,
            .mod_seen_static,
            .mod_seen_readonly,
            .mod_seen_accessor,
            .mod_seen_override,
            .mod_seen_async,
            .mod_seen_abstract,
            .mod_seen_declare,
            .mod_seen_export,
            => 1030,
            .mod_order_public_static,
            .mod_order_private_static,
            .mod_order_protected_static,
            .mod_order_public_override,
            .mod_order_private_override,
            .mod_order_protected_override,
            .mod_order_public_accessor,
            .mod_order_private_accessor,
            .mod_order_protected_accessor,
            .mod_order_public_readonly,
            .mod_order_private_readonly,
            .mod_order_protected_readonly,
            .mod_order_public_async,
            .mod_order_private_async,
            .mod_order_protected_async,
            .mod_order_public_abstract,
            .mod_order_protected_abstract,
            .mod_order_static_readonly,
            .mod_order_static_async,
            .mod_order_static_accessor,
            .mod_order_static_override,
            .mod_order_override_readonly,
            .mod_order_override_accessor,
            .mod_order_override_async,
            .mod_order_abstract_override,
            .mod_order_abstract_accessor,
            .mod_order_export_declare,
            => 1029,
            .fn_type_in_union => 1385,
            .ctor_type_in_union => 1386,
            .fn_type_in_intersection => 1387,
            .ctor_type_in_intersection => 1388,
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

/// TS17019/TS17020 differ only in the punctuation and in which end of the type
/// it sat on, so the four arms share one comptime template.
fn jsdocMarkerMessage(comptime mark: []const u8, comptime end: []const u8) []const u8 {
    return "'" ++ mark ++ "' at the " ++ end ++ " of a type is not valid TypeScript syntax.";
}

/// TS1030 and TS1029 each have one sentence with the modifier word(s)
/// interpolated, so all 33 arms share these two comptime templates rather than
/// 33 hand-copied sentences that would drift.
fn modSeenMessage(comptime word: []const u8) []const u8 {
    return "'" ++ word ++ "' modifier already seen.";
}

fn modOrderMessage(comptime first: []const u8, comptime second: []const u8) []const u8 {
    return "'" ++ first ++ "' modifier must precede '" ++ second ++ "' modifier.";
}

/// TS1044's four modifiers share one sentence, differing only in the word.
fn moduleElementModifierMessage(comptime word: []const u8) []const u8 {
    return "'" ++ word ++ "' modifier cannot appear on a module or namespace element.";
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
