//! Diagnostic emission for assignability — TS2322 and everything that
//! stands in for it (2739 / 2741 / 2740 / 2559 / 2820 / 2353 / 1360), plus
//! the excess-property check and the literal elaborations that anchor a
//! failure on the offending element rather than on the whole expression.
//!
//! ## The invariant this file's existence is meant to enforce
//!
//! **The relation never reports, and the reporting never decides.**
//!
//! `assign.zig` answers one question — is `s` assignable to `t`? — as a bare
//! `bool`, memoized on the type pair and allocating nothing on the success
//! path. It files no diagnostic and builds no message, which is what lets it
//! be called millions of times (overload probing, variance measurement,
//! subtype reduction) at no cost. Everything in THIS file runs only after
//! that answer came back NO, and reconstructs the story post-hoc by
//! re-walking the failed pair (`elaborate.zig`).
//!
//! So: nothing here may feed a verdict back into the relation, and nothing in
//! `assign.zig` may reach across into here. The one-way dependency —
//! `assign_report` → `assign`, never the reverse — is the mechanical form of
//! that rule. The predicates that do live here (`freshLiteralRejects`,
//! `targetKnowsProp`, `excessPropertyScan`'s silent form) decide about the
//! EXPRESSION, not about the types: freshness is a property of the syntax the
//! type-pair-keyed relation deliberately cannot see.
//!
//! `assign.zig` re-exports every `pub` here so the `Checker` method aliases
//! and other modules' `c.<name>` calls keep resolving unchanged.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const assign = @import("assign.zig");
const computed_key = @import("computed_key.zig");
const elaborate = @import("elaborate.zig");
const tuple_zig = @import("tuple_relate.zig");

/// Check `source` (the type of `expr_node`, which may be 0) against
/// `target`, reporting at `span`. Returns true when assignable.
pub fn checkAssignable(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
    // Anchor any TS2589 raised while expanding either side (instantiation
    // limit) at the assignment site.
    c.inst_anchor = .{ .span = .{ .file = c.cur_file, .span = span } };
    if (try c.isAssignable(src_t, target)) {
        // Excess property check for fresh object literals.
        if (expr_node != 0) {
            // tsc's order: the whole-union excess check first (a reported
            // TS2353 ends the relation), then the per-constituent one.
            const before = c.diags.items.len;
            try c.excessPropertyCheck(expr_node, src_t, target);
            if (c.diags.items.len == before and
                try c.freshLiteralUnionMismatch(expr_node, src_t, target, 2322, span)) return false;
        }
        return true;
    }
    // tsc's `checkTypeRelatedTo` epilogue: a query the step budget ABANDONED
    // did not decide the pair, so there is no failure to elaborate — the
    // relation is reported as the thing that went wrong. Read once and
    // immediately: `typeToString` can itself ask a relation, which re-arms the
    // flag for its own query. See `assign.max_relation_steps`.
    //
    // The NAMES are the one part of this that will not match tsgo when a
    // witness for it appears. tsc prints `T1 & T2` and `T1 | null`, aliases
    // and all; `typeToString` can only name a type by symbol from a kept
    // `.ref` (print.zig's `.ref` arm is the sole site that does), and the
    // operands here have been distributed into their union expansion long
    // before the relation sees them — so this prints the expansion. Keeping
    // the ref instead was measured in wave 35 and is not shippable
    // (`--alias-refs`, flags-off). When a witness does turn up, the name to
    // print is the one written at the DIAGNOSTIC SITE — the declared type
    // node — not a spelling recovered from the type.
    if (c.rel_overflow) {
        try c.diagFmt(2859, span, "Excessive complexity comparing types '{s}' and '{s}'.", .{
            try c.typeToString(src_t), try c.typeToString(target),
        });
        return false;
    }
    // tsc elaborates object/array literal mismatches per member.
    if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
        return false;
    }
    if (expr_node != 0 and try c.excessPropertyFailure(expr_node, src_t, target)) return false;
    // `elaborateDidYouMeanToCallOrConstruct` moves the head onto the operand
    // when the source is a function the author forgot to call — see there.
    const anchor = if (expr_node != 0 and try didYouMeanToCall(c, src_t, target))
        c.nodeSpan(expr_node)
    else
        span;
    try c.reportNotAssignable(2322, src_t, target, anchor);
    return false;
}

/// The excess-property check on the FAILURE side of the relation.
///
/// tsc's `hasExcessProperties` runs at the top of `isRelatedTo`, so it decides
/// before the structural walk ever reports: a fresh literal carrying a name the
/// target does not know is diagnosed as TS2353/TS2561 **on the offending
/// property** and the whole-type TS2322/TS2345 is never filed, even when the
/// pair would also have failed for a missing or mistyped member. ztsc's
/// relation cannot see freshness (it is memoized on type pairs, and freshness
/// belongs to the expression), so the reporting paths ask separately — and
/// until this existed they only asked on the side where the relation SUCCEEDED,
/// which is why `var b: Book = { forword: "" }` came out as TS2741 "property
/// 'foreword' is missing" at the declaration instead of tsc's TS2561 on
/// `forword`.
///
/// Ordered after `elaborateLiteralError` to mirror
/// `checkTypeRelatedToAndOptionallyElaborate`, which runs `elaborateError`
/// first and only reaches `checkTypeRelatedTo` — the EPC's home — when the
/// per-member elaboration found nothing. Returns true when it reported, and
/// then the caller must not add its own whole-type error.
pub fn excessPropertyFailure(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!bool {
    const before = c.diags.items.len;
    try c.excessPropertyCheck(expr_node, src_t, target);
    return c.diags.items.len != before;
}

/// The conditional-TARGET leniency ("the source must satisfy whichever
/// branch the conditional resolves to, so require it against both") is not
/// universal in tsc. `structuredTypeRelatedTo` applies it only when the
/// conditional is not *distribution dependent*, and that predicate
/// (`isTypeParameterPossiblyReferenced`) is deliberately conservative about
/// SYNTAX: for a DISTRIBUTIVE conditional — a naked type-parameter check —
/// tsc answers "possibly referenced", hence "distribution dependent", for
/// any occurrence separated from the check parameter's own declaration by a
/// statement BLOCK. An inline `T extends … ? A : B` written as the
/// annotation of a `const` inside the generic function's body is exactly
/// that shape, so tsc rejects it; the same conditional spelled as the
/// function's RETURN annotation (or a parameter's, or a class property's, or
/// through a type ALIAS whose root lives in the alias declaration) is not
/// separated by a block, keeps the leniency, and is accepted.
///
/// Mirror the syntactic half of the rule where it is decidable: an inline
/// conditional TYPE NODE used as a declaration's annotation. `ann_node` is
/// that annotation node, so alias references (`Exclude<T, null>`, a custom
/// `PathValue<T, K>`) are untouched and keep today's leniency, as do
/// non-distributive checks (`[T] extends [true] ? A : B`), which tsc is
/// lenient about in every position.
///
/// Returns true when the assignment must be rejected despite `isAssignable`
/// having accepted it through the both-branches rule.
pub fn inlineCondAnnRejects(c: *Checker, ann_node: Node, src_t: TypeId, target: TypeId) Error!bool {
    if (ann_node == 0) return false;
    var n = ann_node;
    while (c.nodeTag(n) == .paren_type) n = c.tree.nodeData(n).lhs;
    if (c.nodeTag(n) != .conditional_type) return false;
    const t = try c.ts.regular(target);
    // Still a conditional ⇒ still deferred: a conditional whose check type
    // is known has already resolved to one of its branches, and normal
    // assignability decided the question.
    if (c.ts.kind(t) != .conditional) return false;
    // Only a DISTRIBUTIVE conditional — one whose check is a naked type
    // parameter — is treated as distribution dependent by tsc's syntactic
    // rule. An `infer`-var check is a different (enclosing-conditional)
    // shape; leave it lenient.
    if (!c.ts.condDistributive(t)) return false;
    if (c.ts.kind(c.ts.condCheck(t)) != .type_param) return false;
    return c.condStrictSourceRejects(src_t, 0);
}

/// Would `src` relate to a deferred conditional target only through the
/// both-branches leniency? True for a CONCRETE source (an object, a
/// primitive, an intersection of them …), false for every source that has
/// its own rule against a conditional target — the identical conditional, a
/// type parameter reaching it through its constraint, another still-deferred
/// form, and the universally-related `any`/`never`/error types. Deliberately
/// a conservative allow-list of the concrete kinds: anything unrecognized
/// answers "no rejection", which leaves the existing (lenient) verdict.
pub fn condStrictSourceRejects(c: *Checker, src_t: TypeId, depth: u32) Error!bool {
    if (depth > 4) return false;
    const s = try c.ts.regular(try c.ts.regularLiteral(src_t));
    switch (c.ts.kind(s)) {
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .object_keyword,
        .undefined,
        .null,
        .void,
        .bool_true,
        .bool_false,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .array,
        .tuple,
        .object,
        .function,
        .overloads,
        .class_value,
        .enum_type,
        .unique_symbol,
        .template_literal_type,
        .string_mapping,
        => return true,
        // Every constituent must be concrete: one that relates for its own
        // reasons (a type parameter, the conditional itself) keeps the
        // whole union lenient.
        .union_type, .intersection => {
            for (try c.memberList(s)) |m| {
                if (!try c.condStrictSourceRejects(m, depth + 1)) return false;
            }
            return c.ts.memberCount(s) > 0;
        },
        // A named reference is whatever it expands to (an alias for a
        // conditional must stay lenient).
        .ref => {
            const r = try c.resolveStructural(s);
            if (r == s) return false;
            return c.condStrictSourceRejects(r, depth + 1);
        },
        else => return false,
    }
}

/// `expr satisfies T`: same relation as `checkAssignable`, but a
/// top-level failure is reported as TS1360 ("does not satisfy the
/// expected type") rather than TS2322/2741. Nested member mismatches
/// and excess properties elaborate exactly like an assignment.
pub fn checkSatisfies(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
    if (try c.isAssignable(src_t, target)) {
        if (expr_node != 0) try c.excessPropertyCheck(expr_node, src_t, target);
        return true;
    }
    if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
        return false;
    }
    if (expr_node != 0 and try c.excessPropertyFailure(expr_node, src_t, target)) return false;
    // TS7 surfaces the specific missing-property error (TS2741/2739) in
    // place of the TS1360 wrapper when the operand is an object missing
    // required members; a primitive/non-object mismatch still gets TS1360.
    if (try c.tryReportMissingProps(src_t, target, span)) return false;
    try c.diagFmt(1360, span, "Type '{s}' does not satisfy the expected type '{s}'.", .{
        try c.typeToString(src_t), try c.typeToString(target),
    });
    return false;
}

/// The LAST member of the object literal `lit` that declares `key` — the one
/// whose value the literal's type actually carries. Null when the literal has
/// no ordinary member by that name (a spread, or a computed key).
fn lastDeclOfKey(c: *Checker, lit: Node, key: Atom) ?Node {
    var last: ?Node = null;
    for (c.tree.nodeRange(lit)) |m| {
        if (m == null_node) continue;
        const tag = c.nodeTag(m);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        const d = c.tree.nodeData(m);
        if ((tag == .object_property or tag == .object_method) and
            d.lhs != 0 and c.nodeTag(d.lhs) == .computed_name) continue;
        if (c.memberAtom(c.tree.nodeMainToken(m)) catch continue != key) continue;
        last = m;
    }
    return last;
}

/// Element/property-wise TS2322 elaboration for fresh literals (what
/// tsc reports instead of one top-level error). Returns true when at
/// least one narrower diagnostic was emitted.
pub fn elaborateLiteralError(c: *Checker, expr_node0: Node, src_t: TypeId, target: TypeId) Error!bool {
    var expr_node = expr_node0;
    // tsc's `elaborateError` starts with `skipOuterExpressions(node)` and then
    // unwraps a JSX expression container (`elaborateError` handles
    // `JsxExpression` by recursing on `node.expression`). A JSX attribute's
    // value node IS the container, so without this every `style={[…]}` /
    // `x={{…}}` attribute lost its element-wise elaboration and was reported
    // whole — at a span no `@ts-ignore` above the offending element covers.
    while (true) {
        switch (c.nodeTag(expr_node)) {
            .paren_expr, .jsx_expr_container => expr_node = c.tree.nodeData(expr_node).lhs,
            // tsc's `elaborateError`, `BinaryExpression` arm: a comma sequence
            // and a plain `=` assignment both elaborate through their RIGHT
            // operand, because that operand IS the value being related.
            //
            // ```ts
            // case SyntaxKind.BinaryExpression:
            //     switch (node.operatorToken.kind) {
            //         case SyntaxKind.EqualsToken:
            //         case SyntaxKind.CommaToken:
            //             return elaborateError(node.right, …);
            //     }
            // ```
            //
            // Without it `const x: Foo = (void 0, { a: q = { b: … } })` lost
            // the per-property walk at the very first step and was reported
            // whole at the declaration, ON TOP of the deep `d: 42` error the
            // contextual check found anyway
            // (`compiler/slightlyIndirectedDeepObjectLiteralElaborations`).
            // A COMPOUND assignment (`+=`, `&&=`, …) is not in tsc's list —
            // its right operand is not the assigned value.
            .seq_expr => expr_node = c.tree.nodeData(expr_node).rhs,
            .assign => {
                if (c.tree.tokens.tag(c.tree.nodeMainToken(expr_node)) != .eq) break;
                expr_node = c.tree.nodeData(expr_node).rhs;
            },
            else => break,
        }
        if (expr_node == null_node) return false;
    }
    const rt = try c.resolveStructural(target);
    // tsc's `getBestMatchIndexedAccessTypeOrUndefined`: an element/property
    // of a UNION target is first looked up on the union ITSELF, and only
    // when the union has no such member is the lookup redirected to the
    // single best-matching constituent (`getBestMatchingType`). That
    // two-step is what lets `BlobPart[] | undefined` elaborate as
    // `BlobPart[]` and `RequestInit | undefined` as `RequestInit`, while
    // `{ type: 'a'; … } | { type: 'b'; … }` — where the union does answer
    // `.type` — keeps elaborating against `'a' | 'b'` and so stays silent.
    // Without it a union target bailed out entirely and the whole literal
    // was reported at the argument/assignment span.
    const is_union = c.ts.kind(rt) == .union_type;
    // The best-matching constituent, resolved once; `no_type` when the
    // union has none (then only whole-union lookups can contribute).
    const alt: TypeId = if (!is_union) types.no_type else blk: {
        const b = (try c.bestMatchingUnionMember(src_t, rt)) orelse break :blk types.no_type;
        break :blk try c.resolveStructural(b);
    };
    switch (c.nodeTag(expr_node)) {
        .array_literal => {
            const rtk = c.ts.kind(rt);
            // `.object` with a numeric index signature is array-like — see
            // `elemTypeAt`. tsc's `elaborateArrayLiteral` bails only on a
            // PRIMITIVE target; the shapes it can actually index are these.
            const index_arraylike = rtk == .object and c.ts.objectNumberIndex(rt) != 0;
            if (rtk != .array and rtk != .tuple and !index_arraylike and !is_union) return false;
            // tsc re-checks the literal with `forceTuple` and elaborates
            // element-wise ONLY when the result is TUPLE-LIKE
            // (`elaborateArrayLiteral` → `generateLimitedTupleElements`).
            // Spreading an ARRAY contributes a VARIADIC element, and
            // `createNormalizedTupleType` collapses everything between the
            // FIRST and the LAST rest/variadic position into a single rest —
            // so a literal with TWO OR MORE array spreads normalizes to a
            // plain array type, which is not tuple-like, and the whole
            // literal is reported once at the assignment span instead of
            // once per offending element. outline's `richExtensions: Nodes =
            // [...inlineExtensions.filter(…), Image, CodeBlock, …,
            // ...listExtensions, ...tableExtensions]` is that shape: tsc
            // reports the declaration name once and ztsc reported ten
            // element positions. ONE array spread still leaves fixed
            // positions around it, so the literal stays a tuple and the
            // element-wise elaboration stands; a spread of a TUPLE expands
            // inline and contributes no variadic at all.
            var array_spreads: u32 = 0;
            for (c.tree.nodeRange(expr_node)) |el| {
                if (el == null_node or c.nodeTag(el) != .spread_element) continue;
                const op = c.tree.nodeData(el).lhs;
                if (op == null_node) return false;
                const ot = c.nodeType(op) orelse return false;
                if (c.ts.kind(try c.resolveStructural(ot)) != .tuple) array_spreads += 1;
            }
            if (array_spreads >= 2) return false;
            var reported = false;
            var i: u32 = 0;
            for (c.tree.nodeRange(expr_node)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted or c.nodeTag(el) == .spread_element) continue;
                // tsc's `generateLimitedTupleElements`: "skip elements which do
                // not exist in the target — a length error on the tuple overall
                // is likely better than an error on a mismatched index
                // signature". A tuple only has the numeric properties of its
                // FIXED leading elements, so a target with a rest or variadic
                // element elaborates up to that point and no further.
                //
                // Which target position an element lands on is not `i` at all
                // once a variable element precedes it: `['abc', 'def', 5, 6]`
                // against `[...string[], number]` has `6` at the `number` and
                // everything before it at `string`, and against
                // `[...string[], number, number]` the split moves again. tsc
                // reports the whole literal for exactly that reason, where
                // reading position `i` from the start blamed `'def'` for not
                // being a `number`.
                if (c.ts.kind(rt) == .tuple and i >= tuple_zig.fixedLength(c, rt)) continue;
                // A re-check of this same literal must still answer
                // "elaborated" (see `diagAlreadyFiled`).
                if (c.diagAlreadyFiled(2322, c.nodeSpan(el))) {
                    reported = true;
                    continue;
                }
                const tt = if (is_union)
                    ((try c.unionElemTypeAt(rt, i)) orelse (try c.elemTypeAt(alt, i)) orelse continue)
                else
                    ((try c.elemTypeAt(rt, i)) orelse continue);
                const et = c.nodeType(el) orelse continue;
                if (try c.isAssignable(et, tt)) continue;
                if (!try c.elaborateLiteralError(el, et, tt)) {
                    try c.reportNotAssignable(2322, et, tt, c.nodeSpan(el));
                }
                reported = true;
            }
            return reported;
        },
        .object_literal => {
            // tsc's `elaborateObjectLiteralError` bails only on a PRIMITIVE
            // or `never` target; every shape `getIndexedAccessTypeOrUndefined`
            // can name a property of elaborates, and that includes an
            // INTERSECTION (`getPropertyOfUnionOrIntersectionType`). Requiring
            // a lone object here meant a target as ordinary as `Big & { extra?:
            // 1 }` lost its per-property anchor: the whole literal was reported
            // once at the argument's `{`, which is neither tsc's code (TS2345
            // rather than the property's TS2322) nor tsc's line — so a
            // `@ts-expect-error` sitting on the offending PROPERTY suppressed
            // tsgo's report and not ztsc's. outline's
            // `server/middlewares/authentication.test.ts` mocks a koa context
            // against `{ body; response } & { state } & DefaultContext &
            // ExtendableContext` that way, fifteen times in one file.
            const is_isect = c.ts.kind(rt) == .intersection;
            if (c.ts.kind(rt) != .object and !is_union and !is_isect) return false;
            var reported = false;
            for (c.tree.nodeRange(expr_node)) |prop| {
                if (prop == null_node) continue;
                const pd = c.tree.nodeData(prop);
                const tag = c.nodeTag(prop);
                // A METHOD (and the accessor forms, which share the tag) is one
                // of tsc's elaboration elements too — `generateObjectLiteral
                // Elements` yields `MethodDeclaration` / `GetAccessor` /
                // `SetAccessor` beside `PropertyAssignment` and
                // `ShorthandPropertyAssignment`, with the property NAME as the
                // error node. Skipping it lost the one element of
                // `errorOnUnionVsObjectShouldDeeplyDisambiguate` that is written
                // as a method — `a() { return [123] }` against
                // `a?: () => Promise<number[]>` — while every sibling written
                // `b: () => "hello"` elaborated.
                if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
                if ((tag == .object_property or tag == .object_method) and
                    pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                // A re-check of this same literal must still answer
                // "elaborated" (see `diagAlreadyFiled`). The anchor is the
                // property NAME, which is where this arm reports.
                if (c.diagAlreadyFiled(2322, c.tokSpan(c.tree.nodeMainToken(prop)))) {
                    reported = true;
                    continue;
                }
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                const tp: types.Prop = if (is_union)
                    (if (try c.propOfType(rt, key)) |p|
                        p
                    else if (alt != types.no_type and c.ts.kind(alt) == .object)
                        (c.ts.objectPropByName(alt, key) orelse continue)
                    else
                        continue)
                else
                    ((try declaredPropOfTarget(c, rt, key)) orelse continue);
                // An OPTIONAL target property accepts `undefined` — the same
                // `| undefined` `structuralAssignable` folds in before it
                // compares. Without it this elaboration re-judged every
                // optional property on its own, stricter terms than the
                // relation that sent it here, and blamed each one fed a
                // `T | undefined` value for a failure somewhere else in the
                // literal (immich's `EnvData` return: three phantom TS2322 on
                // `host?`, `configFile?` and `logLevel?`).
                const tp_ty = if (tp.optional())
                    try c.makeUnion2(tp.ty, types.undefined_type)
                else
                    tp.ty;
                // tsc reads the source side off the source TYPE for every
                // element (`getIndexedAccessTypeOrUndefined(source, nameType)`
                // in `elaborateElementwise`), so a name DECLARED TWICE is
                // judged by its last declaration at BOTH of its declaration
                // nodes — the earlier one no longer describes the property the
                // literal has. `lastPropertyInLiteralWins`: `thunk: (str:
                // string) => {}` followed by `thunk: (num: number) => {}` is
                // TS2322 on both lines.
                //
                // Taken from the winning NODE rather than from `src_t` itself,
                // because a fresh literal's stored property type is already
                // widened here (`{ d20: 12 }` stores `number`) and judging
                // `d20: 12` against `1 | … | 20` on that would invent a
                // mismatch tsc does not have (`excessPropertyCheckWithUnions`).
                const decl = lastDeclOfKey(c, expr_node, key) orelse prop;
                const dd = c.tree.nodeData(decl);
                const dtag = c.nodeTag(decl);
                const value_node = if (dtag == .object_shorthand) dd.lhs else dd.rhs;
                // A method's value node is its `function_expr`, whose type is
                // the method's own — but for an ACCESSOR (same tag) that is the
                // accessor function, where the member's type is what it gets or
                // sets, so read those off the source type instead.
                const vt = if (dtag == .object_method)
                    (if (try c.propOfType(src_t, key)) |sp| sp.ty else c.nodeType(value_node) orelse continue)
                else
                    c.nodeType(value_node) orelse continue;
                if (try c.isAssignable(vt, tp_ty)) continue;
                if (!try c.elaborateLiteralError(value_node, vt, tp_ty)) {
                    // tsc anchors an object-literal member mismatch at the
                    // property NAME (for shorthand the name IS the value), not
                    // the value expression.
                    try c.reportNotAssignable(2322, vt, tp_ty, c.tokSpan(c.tree.nodeMainToken(prop)));
                }
                reported = true;
            }
            return reported;
        },
        .arrow_fn => return elaborateArrowBody(c, expr_node, src_t, rt),
        else => return false,
    }
}

/// tsc's `elaborateArrowFunction`: a concise-body arrow written with no
/// parameter annotations is blamed at its RETURN EXPRESSION rather than at the
/// arrow itself — and that expression is elaborated in turn, so
/// `{ m: () => ({ a: '' }) }` lands on the inner `a` rather than on `m`.
///
/// The bails are tsc's, in tsc's order: a block body (nothing to blame), any
/// annotated parameter (the writer stated the signature, so the signature is
/// the error), a source that is not a single call signature, and a target with
/// no call signature at all. Measured against tsgo 7.0.2: `(n: number) => 1`
/// and `() => { return 1 }` both keep the whole-arrow span, while `() => 1`
/// moves to the `1`.
fn elaborateArrowBody(c: *Checker, node: Node, src_t: TypeId, rt: TypeId) Error!bool {
    const body = c.tree.nodeData(node).rhs;
    if (body == null_node or c.nodeTag(body) == .block) return false;
    if (anyParamAnnotated(c, node)) return false;
    const s_sig = elaborate.singleSig(c, try c.resolveStructural(src_t), false) orelse return false;
    const t_ret = (try callSigReturnUnion(c, rt)) orelse return false;
    const s_ret = c.ts.fnReturn(s_sig);
    if (try c.isAssignable(s_ret, t_ret)) return false;
    if (try elaborateLiteralError(c, body, s_ret, t_ret)) return true;
    // A re-check of this same arrow must still answer "elaborated" (see
    // `diagAlreadyFiled`); the anchor is the body, which is where this arm
    // reports.
    if (!c.diagAlreadyFiled(2322, c.nodeSpan(body))) {
        try c.reportNotAssignable(2322, s_ret, t_ret, c.nodeSpan(body));
    }
    return true;
}

/// Does any parameter of the function-like `node` carry a type annotation?
/// tsc's `some(node.parameters, hasType)` — the `elaborateArrowFunction` bail.
fn anyParamAnnotated(c: *Checker, node: Node) bool {
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(node).lhs);
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node) continue;
        const pd = c.tree.nodeData(p);
        const ann: Node = switch (c.nodeTag(p)) {
            .param => pd.rhs,
            .param_full => c.tree.extraData(ast.ParamFull, pd.rhs).type_ann,
            else => 0,
        };
        if (ann != 0) return true;
    }
    return false;
}

/// tsc's `getUnionType(map(getSignaturesOfType(target, Call), getReturnTypeOfSignature))`:
/// the type an arrow's concise body is elaborated against. Null when the
/// target has no call signature. `rt` must already be `resolveStructural`ed.
fn callSigReturnUnion(c: *Checker, rt: TypeId) Error!?TypeId {
    switch (c.ts.kind(rt)) {
        .function => return c.ts.fnReturn(rt),
        .object => {
            const n = c.ts.objectCallSigCount(rt);
            if (n == 0) return null;
            var acc = c.ts.fnReturn(c.ts.objectCallSig(rt, 0));
            for (1..n) |i| {
                acc = try c.makeUnion2(acc, c.ts.fnReturn(c.ts.objectCallSig(rt, @intCast(i))));
            }
            return acc;
        },
        else => return null,
    }
}

/// tsc's split inside the weak-type headline: *"calls.length &&
/// isRelatedTo(getReturnTypeOfSignature(calls[0]), target) || constructs.length
/// && isRelatedTo(getReturnTypeOfSignature(constructs[0]), target)"*. A source
/// that is callable and whose FIRST signature returns something the weak
/// target would have accepted is a call the author forgot to write, and tsc
/// says so (TS2560) instead of the flat "no properties in common" (TS2559).
///
/// Only the first signature of each list is consulted, as in tsc — an overload
/// set whose later member happens to fit does not qualify.
fn forgottenCall(c: *Checker, src_t: TypeId, target: TypeId) Error!bool {
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var ctors: std.ArrayList(TypeId) = .empty;
    defer ctors.deinit(c.scratch());
    try signaturesOf(c, src_t, &calls, &ctors);
    if (calls.items.len != 0 and try c.isAssignable(c.ts.fnReturn(calls.items[0]), target)) return true;
    if (ctors.items.len != 0 and try c.isAssignable(c.ts.fnReturn(ctors.items[0]), target)) return true;
    return false;
}

/// tsc's `elaborateDidYouMeanToCallOrConstruct`: a source that is CALLABLE and
/// has SOME signature whose return type the target would have accepted is a
/// call the author forgot to write. tsc re-reports the head on the EXPRESSION
/// (and hangs "Did you mean to call this expression?" off it as related
/// information) rather than on the declaration name or the assignment target,
/// so `var d: I1 = i2.m1` blames `i2.m1` and `x = f` blames `f`.
///
/// `any` and `never` returns are excluded, as in tsc: they fit every target and
/// would move the blame on every failed assignment of an untyped function.
///
/// Sibling of `forgottenCall`, which is the WEAK-type branch's version of the
/// same idea and — this is tsc's own asymmetry, not a simplification — consults
/// only the FIRST signature of each list.
fn didYouMeanToCall(c: *Checker, src_t: TypeId, target: TypeId) Error!bool {
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var ctors: std.ArrayList(TypeId) = .empty;
    defer ctors.deinit(c.scratch());
    try signaturesOf(c, src_t, &calls, &ctors);
    for ([_][]const TypeId{ ctors.items, calls.items }) |list| {
        for (list) |sig| {
            const ret = c.ts.fnReturn(sig);
            switch (c.ts.kind(ret)) {
                .any, .err, .never => continue,
                else => {},
            }
            if (try c.isAssignable(ret, target)) return true;
        }
    }
    return false;
}

/// tsc's `getSignaturesOfType` on a source, split by kind. A bare function type
/// is its own single call signature; an overload set contributes each member.
fn signaturesOf(
    c: *Checker,
    src_t: TypeId,
    calls: *std.ArrayList(TypeId),
    ctors: *std.ArrayList(TypeId),
) Error!void {
    const rs = try c.resolveStructural(src_t);
    switch (c.ts.kind(rs)) {
        .function => try calls.append(c.scratch(), rs),
        .overloads => try calls.appendSlice(c.scratch(), try c.memberList(rs)),
        .object => {
            for (0..c.ts.objectCallSigCount(rs)) |i|
                try calls.append(c.scratch(), c.ts.objectCallSig(rs, @intCast(i)));
            for (0..c.ts.objectConstructSigCount(rs)) |i|
                try ctors.append(c.scratch(), c.ts.objectConstructSig(rs, @intCast(i)));
        },
        else => {},
    }
}

/// The DECLARED property `key` of an elaboration target, tsc's
/// `getPropertyOfType` restricted to what `getIndexedAccessTypeOrUndefined`'s
/// first step can see: a lone object's own member, or — over an INTERSECTION —
/// the intersection of the member as each constituent declares it
/// (`getPropertyOfUnionOrIntersectionType`; present when ANY constituent has
/// it, optional/readonly only when EVERY one of them says so, hence the `and`
/// on flags).
///
/// Deliberately narrower than `propOfType`: no index signature, no apparent
/// `Object`/`Function` member, and no `objectRelatesAsAny` stand-in. All three
/// answer for a name the target never declared, and this lookup exists to
/// decide whether the literal's property has a counterpart worth blaming — an
/// `any` from a sibling's `[k: string]: any` would swallow every real mismatch
/// next to it (`@types/koa`'s `DefaultContext` sits in exactly such an
/// intersection). A name found nowhere is left alone: it is either excess,
/// which the excess-property check owns, or index-covered, which the
/// lone-object arm has always skipped too.
fn declaredPropOfTarget(c: *Checker, rt: TypeId, key: Atom) Error!?types.Prop {
    switch (c.ts.kind(rt)) {
        .object => return c.ts.objectPropByName(rt, key),
        .intersection => {
            var out: ?types.Prop = null;
            for (try c.memberList(rt)) |m| {
                const p = (try declaredPropOfTarget(c, try c.resolveStructural(m), key)) orelse continue;
                if (out) |o| {
                    out = .{
                        .name = o.name,
                        .ty = try c.ts.makeIntersection(c.scratch(), &.{ o.ty, p.ty }),
                        .flags = o.flags & p.flags,
                    };
                } else {
                    out = p;
                }
            }
            return out;
        },
        else => return null,
    }
}

/// A FRESH object literal against a UNION target that `isAssignable`
/// accepted, but tsc does not.
///
/// tsc's excess-property check is not a separate pass: `hasExcessProperties`
/// runs at the top of every `isRelatedTo`, so when `typeRelatedToSomeType`
/// walks a union constituent-by-constituent it re-runs the check against
/// EACH constituent. A constituent that does not know one of the literal's
/// own properties therefore cannot satisfy the relation even though the
/// whole-union check (`excessPropertyCheck` here, which asks whether ANY
/// constituent knows the property) is happy. `crypto.subtle.decrypt`'s
/// `AlgorithmIdentifier | … | AesGcmParams` is the shape: `{ name, iv }`
/// relates structurally to the bare `Algorithm` arm, but `iv` is unknown
/// there, and the only arm that knows `iv` rejects its type — so tsc
/// reports and ztsc was silent.
///
/// Reports (elaborated when possible) and returns true in exactly that
/// case. Purely additive: it never suppresses an accepted relation that
/// some constituent genuinely satisfies.
pub fn freshLiteralUnionMismatch(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId, code: u16, span: Span) Error!bool {
    _ = code;
    _ = span;
    var node = expr_node;
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) != .union_type) return false;
    const ms = try c.memberList(rt);
    // A source whose DISCRIMINANT is a union legitimately matches no single
    // constituent — it spans several (tsc `typeRelatedToDiscriminatedType`),
    // and tsc's excess-property check is about property NAMES being known,
    // not about fitting one constituent whole.
    if (try c.discriminatedUnionAssignable(src_t, rt)) return false;
    // tsc's `hasExcessProperties` has a SECOND half, and it is the whole rule
    // for a union target. Having found the written property's name known
    // somewhere in the union, it compares the property's VALUE against
    // `getTypeOfPropertyInTypes(checkTypes, name)` — the union of that
    // property's type over EVERY constituent, with `undefined` standing in
    // for a constituent that does not have it — and fails the relation when
    // the value does not fit. Nothing else about the union is per-constituent:
    // `unionOrIntersectionRelatedTo` then relates the REGULARIZED (no longer
    // fresh) literal to some constituent, which never excess-checks again.
    //
    // Asking instead for one constituent that both knows every written
    // property AND takes the literal whole is stricter than tsc in exactly
    // the case where the properties are spread across arms: `@nestjs/swagger`'s
    // `ApiQuery({ name, type })` against `Common | ({ name: string } & Common
    // & Omit<SchemaObject, 'required'>)` — `name` is known only in the second
    // arm, which rejects on `type`, while the first arm takes the regularized
    // literal. It is not more lenient on the case this function exists for:
    // `crypto.subtle.decrypt({ name: 'AES-GCM', iv })`'s `iv` is `number` in
    // the one arm that has it and `undefined` in the rest, so a wrong `iv`
    // still fails here (conformance `assignability/070`).
    // tsc's `hasExcessProperties` bails wholesale on a target that is (or,
    // over a union, CONTAINS — `isEmptyObjectType` is `some` there) an empty
    // object type or `object`, so `T | {}` accepts anything (conformance
    // `assignability/071`). A constituent whose members ztsc cannot read here
    // is the same case: it can neither know nor refuse a property.
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .object => if (c.isEmptyObjectType(rm)) return false,
            .array, .tuple, .function, .overloads, .class_value, .intersection, .string_literal, .number_literal, .number_literal_fresh, .boolean, .bool_true, .bool_false, .string, .number, .bigint, .symbol, .enum_type, .null, .undefined, .void, .never, .template_literal_type => {},
            // `object`, `any`, `unknown`, a type variable, a deferred access:
            // not a shape this check can read.
            else => return false,
        }
    }
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        if (tag == .object_property) {
            const pd = c.tree.nodeData(prop);
            if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        }
        const key = try c.memberAtom(c.tree.nodeMainToken(prop));
        const sp = c.ts.objectPropByName(src_t, key) orelse continue; // (union half)
        var known = false;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (ms) |m| {
            const rm = try c.resolveStructural(m);
            if (try c.targetKnowsProp(rm, key)) known = true;
            const pt = (try c.targetPropType(rm, key)) orelse blk: {
                // WAVE-48 AGENT-C FLAGGED ARM (out-of-scope file; self-contained
                // — drop these three lines alone if they conflict).
                // tsc's `getTypeOfPropertyInTypes` falls back to
                // `getApplicableIndexInfoForName(type, name)`, not to the string
                // index alone: `isApplicableIndexType` admits a NUMERIC-literal
                // name to a `[k: number]` signature. Without it, `{ 0: 1 }`
                // against `{ 0: string } | { [a: number]: number }` computed
                // `want = string | undefined` and manufactured a TS2322 for a
                // pair the relation had just accepted
                // (contextualTypeWithUnionTypeIndexSignatures).
                if (c.ts.kind(rm) == .object) {
                    if (try c.numericNameIndexHit(rm, .object, c.atomText(key))) |nt| break :blk nt;
                }
                if (c.ts.kind(rm) == .object and c.ts.objectStringIndex(rm) != 0) {
                    break :blk c.ts.objectStringIndex(rm);
                }
                break :blk types.undefined_type;
            };
            try parts.append(c.scratch(), pt);
        }
        // Unknown everywhere is the plain excess-property error, which the
        // relation's own check already reports (TS2353).
        if (!known) return false;
        const want = try c.ts.makeUnion(c.scratch(), parts.items);
        if (try c.isAssignable(sp.ty, want)) continue;
        // tsc's report here is always `Types_of_property_0_are_incompatible`
        // — it names the property. When ztsc's elaboration cannot name one,
        // this finding disagrees with the relation walk that just ACCEPTED
        // the literal, and the walk is the one to believe: a whole-type
        // report there is a false positive on any pair whose property types
        // ztsc evaluates differently from tsc.
        if (try c.elaborateLiteralError(node, src_t, target)) return true;
        return false;
    }
    return false;
}

/// Every property WRITTEN in the object literal `node` is known in `rm`
/// (tsc's `isKnownProperty` over one union constituent, with the same
/// `isEmptyObjectType` / index-signature escapes `excessPropertyCheck`
/// applies to a non-union target).
pub fn literalPropsKnownIn(c: *Checker, node: Node, rm: TypeId) Error!bool {
    switch (c.ts.kind(rm)) {
        .object => {
            if (c.ts.objectStringIndex(rm) != 0 or c.ts.objectNumberIndex(rm) != 0) return true;
            if (c.isEmptyObjectType(rm)) return true;
        },
        .intersection => {},
        // A non-object constituent is never excess-checked (a fresh object
        // literal that reaches one is already assignable to it).
        else => return true,
    }
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        if (tag == .object_property) {
            const pd = c.tree.nodeData(prop);
            if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        }
        const key = try c.memberAtom(c.tree.nodeMainToken(prop));
        if (!try c.targetKnowsProp(rm, key)) return false;
    }
    return true;
}

/// The type an array literal's element `i` is checked against when the
/// target is `t` — tsc's `getIndexedAccessTypeOrUndefined(t, i)` restricted
/// to a numeric index. Null when `t` has no numeric element at all (the
/// caller then redirects to the best-matching union constituent).
pub fn elemTypeAt(c: *Checker, t: TypeId, i: u32) Error!?TypeId {
    if (t == types.no_type) return null;
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        .array => c.ts.arrayElem(r),
        .tuple => try c.tupleElemTypeAt(r, i),
        // An interface that DERIVES from `Array` (react-native's
        // `RecursiveArray<T> extends Array<T | ReadonlyArray<T> |
        // RecursiveArray<T>>`) is not `.array`-kinded here, but it carries
        // `Array`'s numeric index signature — and tsc's
        // `getIndexedAccessTypeOrUndefined(target, numberLiteral(i))` reads
        // exactly that. Without it every `style={[…]}` array literal against
        // `StyleProp<T>` lost its element-wise elaboration and was reported
        // whole, at a span no `@ts-ignore` above the offending element covers.
        .object => if (c.ts.objectNumberIndex(r) != 0) c.ts.objectNumberIndex(r) else null,
        // A string is indexable by number through `String`'s numeric index
        // signature (`("a" | "b" | ("a" | "b")[])[0]` is `string`, which is
        // exactly why tsc does NOT elaborate that union element-wise).
        .string, .string_literal, .template_literal_type => types.string_type,
        .any, .err, .unknown => r,
        else => null,
    };
}

/// `elemTypeAt` over a union: the union of every constituent's element
/// type, and null as soon as ONE constituent has none — matching tsc,
/// where `getIndexedAccessTypeOrUndefined` on a union needs the index to
/// resolve in every constituent.
pub fn unionElemTypeAt(c: *Checker, ut: TypeId, i: u32) Error!?TypeId {
    const ms = try c.memberList(ut);
    if (ms.len == 0) return null;
    const buf = try c.scratch().alloc(TypeId, ms.len);
    for (ms, 0..) |m, k| buf[k] = (try c.elemTypeAt(m, i)) orelse return null;
    return try c.ts.makeUnion(c.scratch(), buf);
}

/// tsc's `getBestMatchingType`: which constituent of a UNION target an
/// elaboration (and a fresh-literal member relation) is judged against.
/// tsc runs five probes in order; the three that carry the shapes a
/// literal elaboration reaches are mirrored here:
///
///  1. `findMatchingTypeReferenceOrTypeAliasReference` — same generic
///     reference on both sides. The only form that matters for a literal
///     source is `Array`/tuple, so an array/tuple source picks the
///     array/tuple constituent (`Uint8Array[]` vs `BlobPart[] | undefined`).
///  2. `findBestTypeForObjectLiteral` — an object literal against a union
///     that contains an array-like constituent picks a NON-array-like one.
///  3. `findMostOverlappyType` — otherwise the constituent sharing the most
///     property names with the source (`keyof S & keyof T`), ties going to
///     the LAST such constituent (tsc compares with `>=`). A constituent
///     sharing no name at all is never chosen, so `undefined` / `string`
///     arms drop out and `RequestInit` wins.
///
/// Returns null when no constituent matches, which leaves the caller with
/// its whole-union report.
/// tsc's `isArrayLikeType`: a real array/tuple, or any non-nullable type that
/// a `readonly any[]` accepts — which is every interface carrying a numeric
/// index signature, `ReadonlyArray<T>` above all. Both `getBestMatchingType`
/// probes that ask the question have to ask it the same way: reading only the
/// `.array`/`.tuple` KINDS made `StyleProp<T> = null | void | T | false | "" |
/// ReadonlyArray<StyleProp<T>>` look array-free, so probe (2) never fired and
/// an object literal against it elaborated per PROPERTY where tsc reports the
/// literal whole (social-app's `addStyle(style, {height: …})`, whose
/// `@ts-expect-error` sits on the call line and not on the property).
fn isArrayLikeMember(c: *Checker, m: TypeId) Error!bool {
    const rm = try c.resolveStructural(m);
    return switch (c.ts.kind(rm)) {
        .array, .tuple => true,
        .object => c.ts.objectNumberIndex(rm) != 0,
        else => false,
    };
}

pub fn bestMatchingUnionMember(c: *Checker, src_t: TypeId, ut: TypeId) Error!?TypeId {
    const ms = try c.memberList(ut);
    if (ms.len == 0) return null;
    const rs = try c.resolveStructural(src_t);
    const sk = c.ts.kind(rs);
    // (1) array/tuple source -> the array/tuple constituent. An interface
    // deriving from `Array` (`RecursiveArray<T>`) is array-like through its
    // inherited numeric index signature and counts here too: it is what
    // tsc's (5) `findMostOverlappyType` picks anyway, since `keyof` an
    // Array-derived interface overlaps `keyof` the source array on every
    // `Array` member while a sibling object constituent overlaps on none.
    if (sk == .array or sk == .tuple) {
        for (ms) |m| {
            if (try isArrayLikeMember(c, m)) return m;
        }
    }
    if (sk != .object) return null;
    // (2) object source, some array-like constituent -> the first that is not.
    var has_array_like = false;
    for (ms) |m| {
        if (try isArrayLikeMember(c, m)) has_array_like = true;
    }
    if (has_array_like) {
        for (ms) |m| {
            if (!try isArrayLikeMember(c, m)) return m;
        }
    }
    // (3) most shared property names.
    var best: ?TypeId = null;
    var best_n: u32 = 0;
    const nprops = c.ts.objectPropCount(rs);
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .object and c.ts.kind(rm) != .intersection) continue;
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < nprops) : (i += 1) {
            const name = c.ts.objectProp(rs, i).name;
            if ((try c.propOfType(rm, name)) != null) n += 1;
        }
        // `>=`, so the LAST constituent of a tie wins — tsc's
        // `findMostOverlappyType` writes `len >= matchingCount`. Load-bearing:
        // `Alg | { iv: number }` against `{ name, iv }` overlaps on one name in
        // each arm, and only the later arm can name the offending `iv`
        // (conformance `assignability/091_fresh_literal_union_property_types`).
        if (n > 0 and n >= best_n) {
            best_n = n;
            best = m;
        }
    }
    return best;
}

/// tsc reports contextually-typed callback return mismatches as TS2322
/// at the callback body, not TS2345 on the argument.
pub fn elaborateCallbackError(c: *Checker, arg_node: Node, at: TypeId, pt: TypeId) Error!bool {
    const tag = c.nodeTag(arg_node);
    if (tag != .arrow_fn and tag != .function_expr) return false;
    if (c.ts.kind(at) != .function) return false;
    const rpt = try c.resolveStructural(pt);
    if (c.ts.kind(rpt) != .function) return false;
    if (!try c.callbackParamsCompatible(at, rpt)) return false;
    const s_ret = c.ts.fnReturn(at);
    const t_ret = c.ts.fnReturn(rpt);
    if (t_ret == types.void_type) return false;
    if (try c.isAssignable(s_ret, t_ret)) return false;
    const body = c.tree.nodeData(arg_node).rhs;
    const span = if (body != 0 and c.nodeTag(body) != .block)
        c.nodeSpan(body)
    else
        c.nodeSpan(arg_node);
    try c.reportNotAssignable(2322, s_ret, t_ret, span);
    return true;
}

pub fn callbackParamsCompatible(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (try c.requiredParams(s) > try c.paramTotal(t)) return false;
    const pairs = @min(try c.paramTotal(s), @max(try c.effParamCount(s), try c.effParamCount(t)));
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        const sp = try c.paramTypeAt(s, i) orelse break;
        const tp = try c.paramTypeAt(t, i) orelse break;
        if (!try c.isAssignable(tp, sp) and !try c.isAssignable(sp, tp)) return false;
    }
    return true;
}

/// Required properties of the object `rt` that `rs` has not got, appended to
/// `out` in the target's stored order (the caller sorts).
fn collectMissingProps(c: *Checker, rs: TypeId, rt: TypeId, out: *std.ArrayList(Atom)) Error!void {
    for (0..c.ts.objectPropCount(rt)) |i| {
        const tp = c.ts.objectProp(rt, @intCast(i));
        if (tp.optional()) continue;
        // A source index signature does not supply a named property (see
        // structuralAssignable): keep the missing-property diagnostic in
        // step with the relation so `{ [k: string]: any }` → `Date` reports
        // the missing Date members (TS2740), not a bare TS2322.
        //
        // The apparent global-`Object` members DO count as present, for the
        // same reason (`relationSrcProp`): a source that fails on its own
        // missing `own` must not be reported as missing `toString` as well,
        // which is the difference between tsc's TS2741 (one name) and a
        // TS2739 listing two.
        if ((try assign.relationSrcProp(c, rs, tp.name)) == null) {
            try out.append(c.scratch(), tp.name);
        }
    }
}

/// The fixed element POSITIONS of the tuple `rt` that `rs` has not got, named
/// as tsc names them — `'0'`, `'1'`, … A rest or optional element is not
/// required, and neither is anything past the first rest.
fn collectMissingTupleIndices(c: *Checker, rs: TypeId, rt: TypeId, out: *std.ArrayList(Atom)) Error!void {
    var buf: [24]u8 = undefined;
    for (0..c.ts.tupleLen(rt)) |i| {
        const e = c.ts.tupleElem(rt, @intCast(i));
        if (e.rest()) break;
        if (e.optional()) continue;
        const name = try c.internText(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        if ((try assign.relationSrcProp(c, rs, name)) == null) {
            try out.append(c.scratch(), name);
        }
    }
}

/// tsc's `tryElaborateArrayLikeErrors(source, target, /*reportErrors*/ false)`,
/// which is what `reportUnmatchedProperty` consults before it renders a LIST of
/// missing names (TS2739/TS2740). Its readonly early-returns are `readonly
/// Mismatch` — they report TS4104 and answer false — and the two branches after
/// them say the same thing from either side: a list on one side and a non-list
/// on the other has no name list worth printing.
fn missingListElaborates(c: *Checker, s: TypeId, t: TypeId) bool {
    if (tuple_zig.readonlyMismatch(c, s, t)) return false;
    const tk = c.ts.kind(t);
    if (c.ts.kind(s) == .tuple) return tk == .array or tk == .tuple;
    if (tk == .tuple) return c.ts.kind(s) == .array;
    return true;
}

/// Missing-property refinement: when `src` is object-y and `target` is an
/// object type with required properties absent from `src`, report the
/// specific missing-property error (TS2741 for one, TS2739 for several) at
/// `span` and return true. Shared by the assignment check (in place of
/// TS2322), `satisfies` (in place of TS1360), and the `this`-receiver check
/// (in place of TS2684): TS7 surfaces this specific error where tsc 5.5
/// emitted the wrapper code.
pub fn tryReportMissingProps(c: *Checker, src_t: TypeId, target: TypeId, span: Span) Error!bool {
    var rs = try c.resolveStructural(src_t);
    // A class value's static side is the same object the relation compares
    // against (see the `.class_value` arm of `isAssignableInner`), so a
    // missing STATIC reports the same specific code a missing property does —
    // on EITHER side, since that arm materializes both. `const m: typeof Mid =
    // Base` is TS2741 on `extraStatic`, not the TS2322 wrapper.
    var rt = try c.resolveStructural(target);
    if (c.ts.kind(target) == .class_value) {
        rt = try c.instantiateOuter(target, try c.classConstructType(c.ts.classSymbol(target)));
        if (c.ts.kind(rs) == .class_value) rs = try c.instantiateOuter(rs, try c.classConstructType(c.ts.classSymbol(rs)));
    }
    // tsc's `shouldReportUnmatchedPropertyError` turns this off only for a
    // source that is all SIGNATURE and no property; an array or a tuple has
    // plenty of properties, so `number[]` against `{ x: number }` is TS2741 on
    // `x`, and against `interface Ext extends Array<number> { extra: string }`
    // TS2741 on `extra`.
    //
    // Kept to an OBJECT target: a list target is decided by ARITY first
    // (`tupleTypesRelatedTo`), and "Target requires 2 element(s) but source may
    // have fewer" REPLACES this report rather than following it.
    const sk = c.ts.kind(rs);
    if (!isSourceObjecty(sk) and
        !((sk == .array or sk == .tuple) and c.ts.kind(rt) == .object)) return false;
    var missing: std.ArrayList(Atom) = .empty;
    defer missing.deinit(c.scratch());
    switch (c.ts.kind(rt)) {
        .object => try collectMissingProps(c, rs, rt, &missing),
        // tsc relates an ARRAY-LIKE target through its apparent type, the
        // global `Array<T>` interface, so a plain object source is missing
        // every one of its members: `let a: any[] = {x: 1}` is TS2740, not a
        // bare TS2322. (A FUNCTION source is not — `isSourceObjecty` already
        // excludes it, which is tsc's `shouldReportUnmatchedPropertyError`
        // bailing on a source that is all signature and no property.)
        //
        // A TUPLE requires each fixed element position by NAME on top of
        // those, and for an array-like source that is the whole story:
        // `interface StrNum extends Array<string|number> { 0: string; 1:
        // number; length: 2 }` against `[number, number, number]` is TS2741
        // on '2'.
        .array, .tuple => {
            const app = (try c.arrayApparentObject(rt)) orelse return false;
            try collectMissingProps(c, rs, app, &missing);
            if (c.ts.kind(rt) == .tuple) try collectMissingTupleIndices(c, rs, rt, &missing);
        },
        else => return false,
    }
    // Emit the missing names in name-*text* order. They were gathered in
    // the target's stored (atom-sorted) prop order, which varies across
    // --workers/--checkers; text order is content-derived and stable
    // (determinism contract). Names are unique, so the order is total.
    std.mem.sort(Atom, missing.items, c, struct {
        fn less(cc: *Checker, a: Atom, b: Atom) bool {
            return std.mem.order(u8, cc.atomText(a), cc.atomText(b)) == .lt;
        }
    }.less);
    if (missing.items.len == 1) {
        try c.diagFmt(2741, span, "Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{
            c.atomText(missing.items[0]), try c.typeToString(src_t), try c.typeToString(target),
        });
        return true;
    }
    if (missing.items.len > 1) {
        // The LIST form is gated where tsc gates it. `reportUnmatchedProperty`
        // reaches its two multi-name messages only through
        // `tryElaborateArrayLikeErrors`, while the single-name TS2741 above
        // runs unconditionally — so a pair that mixes a list with a
        // non-list on the other side falls back to the plain TS2322 wrapper
        // once more than one name is missing. `{ 0: number; 1: number;
        // length: 2 }` against `[number, number]` is exactly that (ztsc used
        // to list all forty `Array` members), and so is a TUPLE source
        // against an ordinary object target.
        if (!missingListElaborates(c, rs, rt)) return false;
        // Past five names tsc abbreviates the list and reports TS2740 rather
        // than TS2739; the elaboration chain renders the same list, so both
        // share one formatter (`elaborate.missingList`).
        try c.diagFmt(
            elaborate.missingPropsCode(missing.items.len),
            span,
            "Type '{s}' is missing the following properties from type '{s}': {s}",
            .{
                try c.typeToString(src_t),
                try c.typeToString(target),
                try elaborate.missingList(c, missing.items),
            },
        );
        return true;
    }
    return false;
}

/// tsc's NULL-STRIPPED union target — `isRelatedTo`, before any structural
/// work:
///
/// ```ts
/// // Try to see if we're relating something like `Foo` -> `Bar | null | undefined`
/// if (relation !== identityRelation && target.flags & TypeFlags.Union &&
///     (target as UnionType).types.length <= 3 && maybeTypeOfKind(target, TypeFlags.Nullable)) {
///     const nullStrippedTarget = extractTypesOfKind(target, ~TypeFlags.Nullable);
///     if (!(nullStrippedTarget.flags & (TypeFlags.Union | TypeFlags.Never))) {
///         target = getNormalizedType(nullStrippedTarget, /*writing*/ true);
///     }
/// }
/// ```
///
/// So a target of at most three constituents that reduces to ONE non-nullish
/// type when `null` and `undefined` are dropped IS that type for the whole
/// relation — head message, elaboration chain and literal generalization
/// alike. `s.foo = 42` against a `T | undefined` setter is
/// `Type 'number' is not assignable to type 'string'`, not `Type '42' is not
/// assignable to type 'string | undefined'`: with the union gone, the target
/// can no longer hold a singleton, so `generalizedSourceForMessage` widens the
/// literal too — ONE substitution produces BOTH operand differences
/// (`divergentAccessorsTypes2`). Four constituents, or a residue that is still
/// a union, leave the target alone — oracle-pinned on `string | number |
/// undefined` and `void | string | null | undefined`, which tsgo names in full.
///
/// Applied HERE rather than in the relation, which is where tsc has it. The
/// pair reaching this function has already been rejected, so substituting the
/// target cannot change a verdict — and the guard that makes tsc's version
/// sound (a NULLISH source keeps the constituent that would have accepted it)
/// is kept anyway, so the two agree on which pairs get the substitution.
fn nullStrippedTarget(c: *Checker, src_t: TypeId, target: TypeId) Error!TypeId {
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) != .union_type) return target;
    const ms = try c.memberList(rt);
    if (ms.len == 0 or ms.len > 3) return target;
    var kept: TypeId = types.no_type;
    var had_nullish = false;
    for (ms) |m| {
        switch (c.ts.kind(m)) {
            .null, .undefined => {
                had_nullish = true;
                continue;
            },
            else => {},
        }
        if (kept != types.no_type) return target;
        kept = m;
    }
    if (!had_nullish or kept == types.no_type) return target;
    if (mentionsNullish(c, src_t)) return target;
    return kept;
}

/// Is `t` `null`/`undefined`, or a union with such a constituent? tsc's
/// `maybeTypeOfKind(t, TypeFlags.Nullable)` for the source side.
fn mentionsNullish(c: *Checker, t: TypeId) bool {
    switch (c.ts.kind(t)) {
        .null, .undefined => return true,
        .union_type => {
            for (0..c.ts.memberCount(t)) |i| {
                switch (c.ts.kind(c.ts.memberAt(t, @intCast(i)))) {
                    .null, .undefined => return true,
                    else => {},
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn reportNotAssignable(c: *Checker, code: u16, src_t: TypeId, target0: TypeId, span: Span) Error!void {
    const target = try nullStrippedTarget(c, src_t, target0);
    // Readonly-list headline (tsc TS4104). tsc's `tryElaborateArrayLikeErrors`
    // runs before the head message is chosen and REPLACES it — in argument
    // position too, where the diagnostic comes out as 4104 rather than 2345 —
    // and it discards the element/arity story under it, because the readonly
    // modifier is the whole reason the pair failed.
    if (code == 2322 or code == 2345) {
        const rs = try c.resolveStructural(src_t);
        const rt = try c.resolveStructural(target);
        if (tuple_zig.readonlyMismatch(c, rs, rt)) {
            try c.diagFmt(4104, span, "The type '{s}' is 'readonly' and cannot be assigned to the mutable type '{s}'.", .{
                try c.typeToString(src_t), try c.typeToString(target),
            });
            return;
        }
    }
    // Weak-type headline (tsc TS2559). The check that rejected the pair runs
    // at the top of the relation, ahead of the structural walk, so its message
    // REPLACES the assignability headline rather than elaborating under it —
    // including in argument position, where tsc's head message is skipped and
    // the diagnostic comes out as 2559 rather than 2345.
    if (code == 2322 or code == 2345) {
        if (try c.weakTypeMismatch(src_t, target, c.ts.kind(src_t), c.ts.kind(target), c.ts.objectIsFresh(src_t))) {
            // tsc splits the headline in two: a CALLABLE source whose first
            // call (or construct) signature RETURNS something the weak target
            // would have accepted is a forgotten call, and gets
            // `Value_of_type_0_has_no_properties_in_common_with_type_1_Did_you_mean_to_call_it`
            // instead. `doSomething(getDefaultSettings)` is the canonical one.
            if (try forgottenCall(c, src_t, target)) {
                try c.diagFmt(2560, span, "Value of type '{s}' has no properties in common with type '{s}'. Did you mean to call it?", .{
                    try c.typeToString(src_t), try c.typeToString(target),
                });
                return;
            }
            try c.diagFmt(2559, span, "Type '{s}' has no properties in common with type '{s}'.", .{
                try c.typeToString(src_t), try c.typeToString(target),
            });
            return;
        }
    }
    // Missing-property refinement (tsc: 2739 / 2741 instead of 2322 / 2345).
    //
    // tsc reaches `reportUnmatchedProperty` from inside `propertiesRelatedTo`,
    // i.e. only once the relation got as far as comparing MEMBERS, and there
    // `shouldSkipElaboration` makes that sentence REPLACE the head message —
    // in argument position too, where the head would have been TS2345.
    // `tryReportMissingProps` decides from the type pair alone, which at an
    // assignment agrees with tsc closely enough to stand on its own, but in
    // argument position does not: pairs that failed EARLIER in the walk (a
    // same-reference variance comparison, an intersection member) also present
    // as "target has properties the source lacks", and tsc keeps the TS2345
    // head for those. So the argument arm asks `elaborate`'s descent — the
    // same pre-property gauntlet the relation itself takes — whether the top
    // level really lands on an unmatched property.
    if (code == 2322 or (code == 2345 and try elaborate.reachesUnmatchedProperty(c, src_t, target))) {
        if (try c.tryReportMissingProps(src_t, target, span)) return;
    }
    if (code == 2322) {
        // Did-you-mean morph (tsc: TS2820): a string-literal source rejected
        // by a union of string literals with a close member. tsc's
        // getSuggestedTypeForNonexistentStringLiteralType.
        if (try c.stringLiteralSuggestion(src_t, target)) |sugg| {
            try c.diagFmt(2820, span, "Type '{s}' is not assignable to type '{s}'. Did you mean '\"{s}\"'?", .{
                try c.typeToString(src_t), try c.typeToString(target), c.atomText(sugg),
            });
            return;
        }
    }
    // The derivation chain tsc prints under the headline. Reconstructed by
    // re-walking the (already failed) relation — nothing runs on the success
    // path, so the relation stays allocation-free. Empty when the failure has
    // no structural story (`elaborate.zig`). Computed BEFORE `diagFmt` so the
    // whole message is one interpolation.
    const chain = if (c.diagAlreadyFiled(code, span)) "" else try elaborate.chainText(c, src_t, target);
    const named_src = try generalizedSourceForMessage(c, src_t, target);
    if (code == 2345) {
        try c.diagFmt(2345, span, "Argument of type '{s}' is not assignable to parameter of type '{s}'.{s}", .{
            try c.typeToString(named_src), try c.typeToString(target), chain,
        });
    } else {
        try c.diagFmt(code, span, "Type '{s}' is not assignable to type '{s}'.{s}", .{
            try c.typeToString(named_src), try c.typeToString(target), chain,
        });
    }
}

/// The type the HEADLINE names on the source side — tsc's `reportRelationError`:
///
/// ```ts
/// if (isLiteralType(source) && !typeCouldHaveTopLevelSingletonTypes(target)) {
///     generalizedSource = getBaseTypeOfLiteralType(source);
///     generalizedSourceType = getTypeNameForErrorDisplay(generalizedSource);
/// }
/// ```
///
/// A literal source is named by its BASE type unless the target is somewhere a
/// singleton could have landed — `const x: number = 1` cannot fail, so a pair
/// that DID fail against a non-singleton target failed on the primitive, and
/// saying `Type '1'` points at a distinction that is not the reason. Message
/// only: nothing here decides a relation.
fn generalizedSourceForMessage(c: *Checker, src_t: TypeId, target: TypeId) Error!TypeId {
    if (!try isLiteralTypeForMessage(c, src_t)) return src_t;
    if (try couldHaveTopLevelSingletons(c, target)) return src_t;
    return c.baseTypeOfLiteral(src_t);
}

/// tsc's `isUnitType`: one of the types a `===` can decide outright.
fn isUnitKind(k: types.Kind) bool {
    return switch (k) {
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .bool_true,
        .bool_false,
        .enum_type,
        .unique_symbol,
        .undefined,
        .null,
        => true,
        else => false,
    };
}

/// tsc's `isLiteralType`: `boolean` (the `true | false` union spelled as one
/// type), a union of unit types, or a unit type.
fn isLiteralTypeForMessage(c: *Checker, t: TypeId) Error!bool {
    const k = c.ts.kind(t);
    if (k == .boolean) return true;
    if (k == .union_type) {
        for (try c.memberList(t)) |m| {
            if (!isUnitKind(c.ts.kind(m))) return false;
        }
        return true;
    }
    return isUnitKind(k);
}

/// tsc's `typeCouldHaveTopLevelSingletonTypes`: is there a position in `t`
/// where a singleton could sit? `boolean` is deliberately NOT one, "yes,
/// 'boolean' is a union of 'true | false', but that's not useful here".
fn couldHaveTopLevelSingletons(c: *Checker, t: TypeId) Error!bool {
    const k = c.ts.kind(t);
    if (k == .boolean) return false;
    if (k == .union_type or k == .intersection) {
        for (try c.memberList(t)) |m| {
            if (try couldHaveTopLevelSingletons(c, m)) return true;
        }
        return false;
    }
    switch (k) {
        .type_param, .index_access, .conditional, .keyof_op => {
            const con = try c.transitiveBaseConstraint(t);
            if (con != types.no_type and con != t) return couldHaveTopLevelSingletons(c, con);
        },
        else => {},
    }
    return isUnitKind(k) or k == .template_literal_type or k == .string_mapping;
}

/// tsc's getSuggestedTypeForNonexistentStringLiteralType: when a string
/// literal is rejected by a union, suggest the closest string-literal member
/// (drives the TS2322 -> TS2820 morph). Returns the suggested member's value
/// atom, or null when the source is not a string literal, the target is not
/// a union of string literals, or nothing is close enough.
pub fn stringLiteralSuggestion(c: *Checker, src_t: TypeId, target: TypeId) Error!?Atom {
    const rs = try c.resolveStructural(src_t);
    if (c.ts.kind(rs) != .string_literal) return null;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) != .union_type) return null;
    var cand_atoms: std.ArrayList(Atom) = .empty;
    defer cand_atoms.deinit(c.scratch());
    var cand_names: std.ArrayList([]const u8) = .empty;
    defer cand_names.deinit(c.scratch());
    for (try c.memberList(rt)) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .string_literal) continue;
        const a = c.ts.literalAtom(rm);
        try cand_atoms.append(c.scratch(), a);
        try cand_names.append(c.scratch(), c.atomText(a));
    }
    if (cand_names.items.len == 0) return null;
    const name = c.atomText(c.ts.literalAtom(rs));
    const idx = intern.spellingSuggestion(c.scratch(), name, cand_names.items) orelse return null;
    return cand_atoms.items[idx];
}

pub fn isSourceObjecty(k: types.Kind) bool {
    return k == .object or k == .intersection;
}

/// Is `t` the global `Object` interface, or a union with it as a constituent?
/// tsc's `isTypeSubsetOf(globalObjectType, t)`, the excess-property check's
/// other wholesale bail beside `isEmptyObjectType`.
fn targetIsGlobalObjectIface(c: *Checker, t: TypeId) Error!bool {
    const k = c.ts.kind(t);
    if (k == .union_type) {
        for (try c.memberList(t)) |m| {
            if (try targetIsGlobalObjectIface(c, m)) return true;
        }
        return false;
    }
    if (k == .ref) return c.prog.globals.lookup(c.atom_Object) == c.ts.refSymbol(t);
    // A materialized `Object` still names the reference it came from (`origin`).
    if (c.refFacetOf(t, k)) |r| return c.prog.globals.lookup(c.atom_Object) == c.ts.refSymbol(r);
    return false;
}

/// The names tsc's spelling suggestion for an excess property may propose —
/// `getPropertiesOfType(errorTarget)`, appended to `out`:
///
///   * an object contributes its own property names;
///   * an INTERSECTION contributes every constituent's, since its property set
///     is the union of theirs (`collectPropNames`);
///   * a UNION contributes only names present in EVERY object-ish constituent,
///     because a union's property list is the INTERSECTION of its members'.
///     Non-object constituents drop out first, exactly as tsc filters
///     `reducedTarget` through `isExcessPropertyCheckTarget` before asking.
///
/// Getting this pool wrong is not cosmetic: a name found here files TS2561 and
/// a name not found files TS2353, so over-collecting swaps one code for the
/// other on the same finding.
fn targetSuggestionNames(c: *Checker, rt: TypeId, out: *std.ArrayList(Atom)) Error!void {
    if (c.ts.kind(rt) != .union_type) return c.collectPropNames(rt, out, 0);
    var first: std.ArrayList(Atom) = .empty;
    defer first.deinit(c.scratch());
    var objish: u32 = 0;
    for (try c.memberList(rt)) |m| {
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .object, .intersection => {},
            // An ARRAY or TUPLE constituent is an excess-check target for tsc,
            // so it stays in `errorTarget` and its (Array) members join the
            // intersection — which for any hand-written name leaves the pool
            // EMPTY. Offering the object arm's names instead invented a
            // suggestion, and with it TS2561 where tsc files TS2353
            // (`Book | Book[]`).
            .array, .tuple => return,
            else => continue,
        }
        objish += 1;
        if (objish == 1) {
            try c.collectPropNames(rm, &first, 0);
            continue;
        }
        var keep: usize = 0;
        for (first.items) |name| {
            if ((try c.propOfType(rm, name)) == null) continue;
            first.items[keep] = name;
            keep += 1;
        }
        first.shrinkRetainingCapacity(keep);
    }
    if (objish == 0) return;
    for (first.items) |name| try out.append(c.scratch(), name);
}

/// tsc's `getSuggestedSymbolForNonexistentProperty` for an excess property:
/// the target's own property name closest to the written one, or null when
/// nothing is close enough. Selects TS2561 over TS2353.
fn excessPropSuggestion(c: *Checker, rt: TypeId, key: Atom) Error!?Atom {
    const text = c.atomText(key);
    if (text.len == 0) return null;
    var names: std.ArrayList(Atom) = .empty;
    defer names.deinit(c.scratch());
    try targetSuggestionNames(c, rt, &names);
    if (names.items.len == 0) return null;
    var cand: std.ArrayList([]const u8) = .empty;
    defer cand.deinit(c.scratch());
    for (names.items) |a| try cand.append(c.scratch(), c.atomText(a));
    const idx = intern.spellingSuggestion(c.scratch(), text, cand.items) orelse return null;
    return names.items[idx];
}

/// tsc's excess property check: only *fresh* object literals, checked
/// against object-ish targets; recurses into nested literal properties.
pub fn excessPropertyCheck(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!void {
    _ = try c.excessPropertyScan(expr_node, src_t, target, true);
}

/// The excess-property check, with the diagnostic made optional: returns
/// whether the fresh literal `expr_node` carries a property `target` does
/// not know. `report = false` is the silent form overload probing needs
/// (`freshLiteralRejects`) — tsc folds this test into the assignability
/// relation itself (`hasExcessProperties` inside `isRelatedTo`), so a
/// candidate signature that only "fits" by ignoring an excess property is
/// not applicable there either.
/// Does the UNION `rt` have a constituent tsc's `isExcessPropertyCheckTarget`
/// accepts — an object type (an array, a tuple and a signature type are object
/// types there), the `object` keyword, or an intersection of them? A union of
/// nothing but primitives, nullish types and type VARIABLES has none, and the
/// excess-property error then has no target to name.
fn unionHasExcessCheckTarget(c: *Checker, rt: TypeId) Error!bool {
    for (try c.memberList(rt)) |m| {
        switch (c.ts.kind(try c.resolveStructural(m))) {
            .object,
            .array,
            .tuple,
            .function,
            .overloads,
            .class_value,
            .object_keyword,
            .mapped,
            .intersection,
            => return true,
            else => {},
        }
    }
    return false;
}

/// tsc's `findMatchingDiscriminantType`, as `hasExcessProperties` uses it: a
/// UNION target is first REDUCED to the constituents the source's discriminant
/// properties select, and only then asked which names it knows. Without the
/// reduction the check asks the whole union, so a name belonging to a *sibling*
/// arm counts as known and the error is lost:
///
/// ```ts
/// type ADT = { tag: "A", a1: string } | { tag: "T" };
/// const x: ADT = { tag: "T", a1: "" };   // TS2353 on `a1`: the `tag` picks
///                                       // `{ tag: "T" }`, which has no `a1`
/// ```
///
/// Which source properties count as discriminators is decided by the TARGET,
/// not by the source: `findDiscriminantProperties` walks the source's names but
/// asks `isDiscriminantProperty(target, name)` about each one, and that test
/// reads the union's synthesized property (`targetDiscriminates`). So a tag the
/// source types as plain `string` still reduces, as long as the target union
/// disagrees about it and at least one arm spells it as a literal.
///
/// Per discriminator, every still-included constituent that does not accept the
/// source's value drops out; a discriminator NO constituent accepts is discarded
/// wholesale (tsc's `!matched` restore), which is what keeps a literal with a
/// wrong tag reported as a plain mismatch rather than measured against an
/// arbitrary arm. Returns the original union when nothing was reduced away.
/// Does the source's discriminant value `sv` select the constituent whose
/// discriminant property has type `tv`?
///
/// A discriminant written as a UNION of units selects every constituent SOME of
/// its members reaches, not only the ones ALL of them do. The reduction is a
/// filter over the target ("which arms could this literal still be?"), so a
/// two-valued tag has to keep both arms in the running:
///
/// ```ts
/// type U = { k: "a"; aa: number } | { k: "b"; bb: number };
/// declare const ab: "a" | "b";
/// const x: U = { k: ab, aa: 1, bb: 1 };   // clean: `ab` keeps BOTH arms, so
///                                         // `aa` and `bb` are both known
/// ```
///
/// Asking plain assignability instead reduced that target to nothing it could
/// name — every arm disagreed with the *whole* union — and social-app's
/// `ageAssurance` config paid for it 34 times over: its `$type` is
/// `Record<string, AgeAssuranceRuleID>`'s value type, i.e. the union of all
/// seven rule tags, against a target union of the seven matching rule shapes
/// plus a `{ $type: string }` catch-all. Only the catch-all took the whole
/// union, so the reduction threw away every arm that had an `age`, a `date` or
/// an `access` to know.
///
/// The oracle keeps the "some member reaches it" reading exactly: `"a" | "c"`
/// against that same `U` keeps the `"a"` arm and drops the `"b"` one.
///
/// `boolean` is one of those unions for tsc — `booleanType` IS
/// `true | false` — so a `boolean`-typed tag reaches a `{ k: true }` arm
/// through its `true` member and keeps it in the running. ztsc keeps `boolean`
/// as one kind, so without the expansion `{ k: boolean; aa } | { k: true; bb }`
/// reduced to the first arm alone and reported `bb` as excess where tsgo is
/// silent. (Expanded here for the same reason, and in the same shape, as
/// `discriminatedUnionAssignable`'s own `bool_consts`.)
fn discriminantSelects(c: *Checker, sv: TypeId, tv: TypeId) Error!bool {
    if (c.ts.kind(sv) == .boolean) {
        return try c.isAssignable(types.true_type, tv) or
            try c.isAssignable(types.false_type, tv);
    }
    if (c.ts.kind(sv) != .union_type) return c.isAssignable(sv, tv);
    // `memberList` hands out a borrowed slice and `isAssignable` re-enters the
    // checker, which can invalidate it.
    const ms = try c.scratch().dupe(TypeId, try c.memberList(sv));
    defer c.scratch().free(ms);
    for (ms) |m| {
        if (try c.isAssignable(m, tv)) return true;
    }
    return false;
}

/// tsc's `isLiteralType` — does `t` consist of unit values only, so that a
/// target property of this type carries `CheckFlags.HasLiteralType`?
///
/// `boolean` counts: tsc has no `boolean` type, only the union `true | false`,
/// and `isLiteralType` short-circuits on `TypeFlags.Boolean`. A whole ENUM
/// counts for the same reason — tsc models it as the union of its member
/// literals (`TypeFlags.EnumLiteral`) — while ztsc keeps both nominal.
fn isLiteralLike(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .boolean, .enum_type => true,
        else => c.isUnitOrUnitUnion(t),
    };
}

/// tsc's `isDiscriminantProperty(target, name)`: does the union `ms` treat
/// `name` as a tag? Its synthesized property must carry
/// `CheckFlags.Discriminant` — `HasNonUniformType` (the constituents do not all
/// give the name the same type) AND `HasLiteralType` (at least one of them
/// gives it a unit-valued type).
///
/// Only constituents that HAVE the name are consulted: tsc's
/// `createUnionOrIntersectionProperty` records a missing one as `Partial` and
/// moves on, and `isDiscriminantProperty` reads the property through
/// `getUnionOrIntersectionProperty`, which does not filter partials out. The
/// caller's own loop then leaves such a constituent in the running.
fn targetDiscriminates(c: *Checker, ms: []const TypeId, name: Atom) Error!bool {
    var first: TypeId = 0;
    var non_uniform = false;
    var any_literal = false;
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        const pt = (try c.targetPropType(rm, name)) orelse continue;
        const rp = try c.resolveStructural(pt);
        if (first == 0) first = rp else if (rp != first) non_uniform = true;
        if (try isLiteralLike(c, rp)) any_literal = true;
    }
    return non_uniform and any_literal;
}

fn epcReducedUnion(c: *Checker, src_t: TypeId, rt: TypeId) Error!TypeId {
    // `memberList` hands out a borrowed slice and every probe below re-enters
    // the checker (`resolveStructural`, `propOfType`, `isAssignable`), any of
    // which can grow the store and move it — see `discriminantSelects`.
    const ms = try c.scratch().dupe(TypeId, try c.memberList(rt));
    defer c.scratch().free(ms);
    if (ms.len < 2) return rt;
    const rs = try c.resolveStructural(src_t);
    if (c.ts.kind(rs) != .object) return rt;
    const nprops = c.ts.objectPropCount(rs);
    if (nprops == 0) return rt;
    // tsc seeds `include` with FALSE for every primitive constituent, so a
    // reduced target never contains one.
    const include = try c.scratch().alloc(bool, ms.len);
    defer c.scratch().free(include);
    var any_objish = false;
    for (ms, 0..) |m, i| {
        const rm = try c.resolveStructural(m);
        include[i] = switch (c.ts.kind(rm)) {
            .object, .intersection, .array, .tuple, .ref => true,
            else => false,
        };
        if (include[i]) any_objish = true;
    }
    if (!any_objish) return rt;
    var reduced = false;
    for (0..nprops) |pi| {
        const sp = c.ts.objectProp(rs, @intCast(pi));
        if (!try targetDiscriminates(c, ms, sp.name)) continue;
        var matched = false;
        var maybe_out: usize = 0;
        const maybe = try c.scratch().alloc(bool, ms.len);
        defer c.scratch().free(maybe);
        for (ms, 0..) |m, i| {
            maybe[i] = false;
            if (!include[i]) continue;
            const rm = try c.resolveStructural(m);
            // A constituent that does not HAVE the property is not selected
            // against: only a constituent that has it and disagrees drops out.
            // This is tsc's partial-discriminant handling, and it is the whole
            // reason `{ str: "b", num: 1 }` is legal against
            // `{ str: "a", num: 0 } | { str: "b" } | { num: 1 }` — `str` keeps
            // `{ num: 1 }` in the running (it has no `str` to disagree with),
            // and `num` is then known there (`missingDiscriminants`).
            const tp = (try c.targetPropType(rm, sp.name)) orelse continue;
            if (try discriminantSelects(c, sp.ty, tp)) {
                matched = true;
            } else {
                maybe[i] = true;
                maybe_out += 1;
            }
        }
        // No arm accepts this value: not a discriminator that selects anything,
        // so it selects nothing away either.
        if (!matched or maybe_out == 0) continue;
        for (ms, 0..) |_, i| {
            if (maybe[i]) include[i] = false;
        }
        reduced = true;
    }
    if (!reduced) return rt;
    var keep: std.ArrayList(TypeId) = .empty;
    defer keep.deinit(c.scratch());
    for (ms, 0..) |m, i| {
        if (include[i]) try keep.append(c.scratch(), m);
    }
    if (keep.items.len == 0) return rt;
    return c.ts.makeUnion(c.scratch(), keep.items);
}

/// Does SOME constituent of a union target take this literal whole?
///
/// tsc relates a source to a union target with `typeRelatedToSomeType`: each
/// constituent is tried with errors off, and the first that relates ends the
/// relation clean. The excess-property check runs INSIDE that relation
/// (`hasExcessProperties` is `isRelatedTo`'s first act on a fresh literal), so
/// a constituent that accepts the literal accepts its excess check too — and
/// nothing is reported, whichever OTHER constituent a reporting heuristic
/// would have named.
///
/// ztsc keeps freshness out of `isAssignable` (the relation is memoized on
/// type pairs), so the two halves are asked separately: the ordinary relation,
/// then this scan re-run against that one constituent with reporting off.
///
/// The witness is a mapped target with a literal key set — react-native's
/// `Platform.select<T>(specifics: {[p in PlatformOSType]?: T})`. Inference
/// answers `T` with the UNION of the per-key array literals (which is what tsc
/// infers too), and `bestMatchingUnionMember` then measured the `web:` literal
/// against whichever array constituent came first in the union — `{gap: 4}[]`,
/// the `native:` one — and reported its every unshared property as excess.
/// Union member order is TypeId order, i.e. interning order, so the same
/// program disagreed with itself across checker partitions
/// (social-app's `StarterPackDialog.tsx` and `AppLanguageDropdown.tsx`).
fn someUnionMemberAccepts(c: *Checker, node: Node, src_t: TypeId, ut: TypeId) Error!bool {
    // `memberList` hands out a borrowed slice and the scan below re-enters the
    // checker, which can invalidate it.
    const ms = try c.scratch().dupe(TypeId, try c.memberList(ut));
    defer c.scratch().free(ms);
    for (ms) |m| {
        if (!try c.isAssignable(src_t, m)) continue;
        if (!try excessPropertyScan(c, node, src_t, m, false)) return true;
    }
    return false;
}

/// The excess-property check over an ARRAY literal's elements, against the
/// element type the target gives each position (`elemTypeAt`, so an array, a
/// tuple and a numerically-indexed interface all work). A UNION target is
/// resolved to the constituent the relation would have reported against
/// (`bestMatchingUnionMember`), which is how `Book | Book[]` reaches `Book`.
///
/// A SPREAD element makes the positions unknowable, so the whole literal is left
/// alone rather than measured against shifted element types.
fn arrayElemExcessScan(c: *Checker, node: Node, src_t: TypeId, target: TypeId, report: bool) Error!bool {
    var rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) == .union_type) {
        const ut = rt;
        const b = (try c.bestMatchingUnionMember(src_t, ut)) orelse return false;
        rt = try c.resolveStructural(b);
        // The chosen arm is only ONE reading of a union target. Ask the
        // expensive question — is there an arm that takes this literal whole?
        // — only once that arm has actually objected, so the clean case pays
        // nothing beyond the scan it already ran.
        if (!try arrayElemScanAgainst(c, node, rt, false)) return false;
        if (try someUnionMemberAccepts(c, node, src_t, ut)) return false;
    }
    return arrayElemScanAgainst(c, node, rt, report);
}

/// The element walk of `arrayElemExcessScan`, against one resolved target.
fn arrayElemScanAgainst(c: *Checker, node: Node, rt: TypeId, report: bool) Error!bool {
    for (c.tree.nodeRange(node)) |el| {
        if (el != null_node and c.nodeTag(el) == .spread_element) return false;
    }
    var any = false;
    var i: u32 = 0;
    for (c.tree.nodeRange(node)) |el| {
        if (el == null_node) continue;
        defer i += 1;
        const et = (try elemTypeAt(c, rt, i)) orelse continue;
        const en = c.nodeType(el) orelse continue;
        if (try excessPropertyScan(c, el, en, et, report)) any = true;
    }
    return any;
}

/// The type a nested literal is measured against for the name `key`.
///
/// The plain lookup is `targetPropType`, but a UNION target only answers a name
/// its EVERY constituent has. tsc's `hasExcessProperties` descends with
/// `getTypeOfPropertyInTypes(checkTypes, name)` — the UNION of the name's type
/// over every constituent of the (discriminant-reduced) target — so a union
/// that cannot answer as a whole is answered constituent by constituent and
/// the answers unioned. That is what lets a nested literal be measured against
/// every arm that could have accepted it, e.g.
/// `StatelessComponent<TestProps | { props2: … }>`, whose `icon` lives in one
/// arm and whose nested `INVALID_PROP_NAME` is still reported (no arm knows
/// it), while react-navigation's `LinkProps<AllNavigatorParams>` — a union of
/// `{ screen: R; params: ParamList[R] }` over every route — measures a
/// `params:` literal against the union of every route's params rather than
/// against one arbitrarily chosen route's.
///
/// Choosing ONE arm instead (`bestMatchingUnionMember`) was both wrong and
/// unstable: its tie-break keeps the LAST overlapping constituent, and union
/// member order is TypeId order — i.e. interning order — so the same program
/// disagreed with itself across checker partitions (social-app's
/// `FeedSourceCard.tsx`, whose `screen` is a two-literal union that selects no
/// single arm at all).
fn nestedTargetPropType(c: *Checker, rt: TypeId, key: Atom) Error!?TypeId {
    if (try c.targetPropType(rt, key)) |tp| return tp;
    if (c.ts.kind(rt) != .union_type) return null;
    // `memberList` hands out a borrowed slice and `targetPropType` re-enters
    // the checker, which can invalidate it.
    const ms = try c.scratch().dupe(TypeId, try c.memberList(rt));
    defer c.scratch().free(ms);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (ms) |m| {
        const tp = (try c.targetPropType(try c.resolveStructural(m), key)) orelse continue;
        try parts.append(c.scratch(), tp);
    }
    if (parts.items.len == 0) return null;
    return try c.ts.makeUnion(c.scratch(), parts.items);
}

/// tsc's `shouldCheckAsExcessProperty`: only a property whose symbol was
/// DECLARED by this very object literal is excess-checked
/// (`prop.valueDeclaration.parent === container.valueDeclaration`). A property
/// written before a spread that supplies the same name does not survive
/// `getSpreadType` — the result carries the SOURCE's symbol, declared
/// elsewhere — so tsc never measures it against the target:
///
///     f({ x: 1, extra: 5, ...req })   // silent (TS2783 only)
///     f({ x: 1, ...req, extra: 5 })   // TS2353: the spread is EARLIER
///
/// An OPTIONAL property on the spread source counts too, even though it leaves
/// the earlier value reachable and so files no TS2783: `getSpreadType`
/// synthesizes a fresh union symbol for that pair, and a synthesized symbol has
/// no `valueDeclaration` at all — which fails the same guard.
///
/// An INDEX SIGNATURE on the source does not count (`allow_index = false`):
/// index infos are spread separately and produce no property symbol to
/// overwrite with, so `{ a: 1, ...someRecord }` still reports `a`. Nor does a
/// source that names something else, and nor — because `propOfTypeEx` requires
/// a UNION source to carry the name in every constituent — does
/// `{ extra: number } | { zz: number }`.
///
/// A bare TYPE PARAMETER source resolves through its constraint here, unlike in
/// `checkSpreadPropOverrides`, where reading the constraint would have been a
/// false positive. The polarities are opposite: there the constraint would
/// invent an overwrite, here it suppresses a check tsc also suppresses.
///
/// Only ever called for a property BEFORE `lastSpreadIndex` — see there for why
/// the scan is not paid per property.
fn overriddenByLaterSpread(c: *Checker, members: []const Node, after: usize, key: Atom) Error!bool {
    for (members[after + 1 ..]) |el| {
        if (el == null_node or c.nodeTag(el) != .spread_element) continue;
        const raw = c.nodeType(c.tree.nodeData(el).lhs) orelse continue;
        const st = try c.resolveStructural(raw);
        switch (c.ts.kind(st)) {
            // Spreading one of these yields no members to overwrite with —
            // and an `any` source makes the whole literal `any`, which the
            // freshness gate above has already turned the scan away from.
            .any, .err, .unknown, .never => continue,
            else => {},
        }
        if ((try c.propOfTypeEx(st, key, false)) != null) return true;
    }
    return false;
}

/// One past the index of the LAST spread element, or 0 when the literal has
/// none — so `i < lastSpreadIndex(members)` is exactly "some spread follows
/// property `i`".
///
/// This single pass is what keeps `overriddenByLaterSpread` off the hot path.
/// Asking it per property would scan the remaining members each time, which is
/// quadratic in the literal's size — and the object literals that matter are
/// the big ones (excalidraw's element constructors run to dozens of members),
/// while the overwhelming majority carry no spread at all and answer 0 here.
fn lastSpreadIndex(c: *const Checker, members: []const Node) usize {
    var i = members.len;
    while (i > 0) {
        i -= 1;
        const el = members[i];
        if (el != null_node and c.nodeTag(el) == .spread_element) return i;
    }
    return 0;
}

/// The branches of an expression whose TYPE is a union of its operands'
/// types — `a || b`, `a ?? b`, `a && b`, `c ? a : b` — in source order, or
/// null for anything else.
///
/// These are the only expressions that put more than one FRESH object literal
/// behind a single node, which is what the excess-property check needs the
/// list for: it reports on a literal, and a union source is related one
/// constituent at a time.
fn sourceUnionBranches(c: *const Checker, node: Node) Error!?[2]Node {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .binary => switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
            .pipe_pipe, .amp_amp, .question_question => return .{ d.lhs, d.rhs },
            else => return null,
        },
        .cond_expr => {
            const e = c.tree.extraData(ast.CondExpr, d.rhs);
            return .{ e.then_expr, e.else_expr };
        },
        else => return null,
    }
}

/// The excess-property check over the branches of a union-valued expression,
/// in SOURCE order, stopping at the first that reports — see the call site.
///
/// A branch whose own type the union no longer contains is skipped: the union
/// is built with subtype reduction, so `{ a: '' } || { a: '', c: 2 }` has one
/// constituent and the second branch is never related to anything. Comparing
/// TypeIds is exactly the right test here — the constituents ARE the branches'
/// node types, freshness and all, because that is what the union was built
/// from.
fn branchExcessScan(c: *Checker, branches: [2]Node, src_t: TypeId, target: TypeId, report: bool) Error!bool {
    for (branches) |b| {
        if (b == null_node) continue;
        const bt = c.nodeType(b) orelse continue;
        if (bt != src_t and !unionHasConstituent(c, src_t, bt)) continue;
        if (try excessPropertyScan(c, b, bt, target, report)) return true;
    }
    return false;
}

fn unionHasConstituent(c: *const Checker, u: TypeId, m: TypeId) bool {
    if (c.ts.kind(u) != .union_type) return false;
    return assign.unionHasMember(c.ts.members(u), m);
}

pub fn excessPropertyScan(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId, report: bool) Error!bool {
    var node = expr_node;
    // Unwrap parens and a JSX expression container (`prop={{ … }}`): the
    // object literal inside a JSX attribute value is fresh and excess-checked
    // exactly like a call argument or assignment RHS.
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    // A source UNION written as `a || b`, `a ?? b`, `a && b` or `c ? a : b`
    // relates CONSTITUENT BY CONSTITUENT (tsc's `eachTypeRelatedToType`), and
    // each constituent that is a fresh literal gets its own excess check on the
    // way past. The first one that fails ends the relation — `eachTypeRelated
    // ToType` returns `Ternary.False` and the remaining constituents are never
    // asked — so `const x: T = { a: '', b: 1 } || { a: '', c: 2 }` is exactly
    // ONE TS2353, on `b`.
    //
    // Reached from the SYNTAX rather than from the union, because that is where
    // the literal to report on lives; `branchExcessScan` keeps the two in step
    // by skipping a branch whose own type the union no longer contains (subtype
    // reduction drops `{ a: string, c: number }` from `{ a: string } | { a:
    // string, c: number }` outright, which is why `{ a: '' } || { a: '', c: 2 }`
    // is clean in the oracle).
    if (try sourceUnionBranches(c, node)) |branches| {
        return branchExcessScan(c, branches, src_t, target, report);
    }
    // An ARRAY literal is not excess-checked itself — it has no property names
    // — but each ELEMENT is: tsc's relation recurses into the elements with each
    // one still fresh, so `var x: Action[] = [{ id: 2, trueness: false }]` is an
    // error on `trueness`, and one per offending element (the element walk does
    // not stop at the first).
    if (c.nodeTag(node) == .array_literal) return arrayElemExcessScan(c, node, src_t, target, report);
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    // tsc's `hasExcessProperties` bails outright when the target is the global
    // `Object` interface — `isTypeSubsetOf(globalObjectType, target)`, tested in
    // the same breath as the `isEmptyObjectType(target)` bail below — so
    // `const o: Object = { a: 1 }` is legal, and so is the `Object | number`
    // form (`isTypeSubsetOfUnion`). `Object` is not a shape a literal is
    // measured against: every object type already carries its apparent members
    // (see `relationSrcProp`), which is why the relation accepts the literal at
    // all. Latent until the relation started accepting it: the pair used to
    // fail with TS2740 before the excess check was ever consulted.
    if (try targetIsGlobalObjectIface(c, target)) return false;
    var rt = try c.resolveStructural(target);
    if (try targetIsGlobalObjectIface(c, rt)) return false;
    switch (c.ts.kind(rt)) {
        .object => {
            // An INDEX SIGNATURE is not a wholesale bail in tsc: `isKnownProperty`
            // consults it per name (`getApplicableIndexInfoForName`), which
            // `targetKnowsProp` already does — and the walk below still has to
            // descend into a NESTED literal, whose own target is the index type.
            // `var b: { [n: number]: Cover } = { 0: { colour: "blue" } }` is an
            // error on `colour` for exactly that reason.
            // The empty object type `{}` accepts any properties: tsc's
            // `hasExcessProperties` bails on `isEmptyObjectType(target)`
            // (e.g. react-i18next's `values?: {}`). No prop is ever excess.
            if (c.isEmptyObjectType(rt)) return false;
        },
        .union_type => {
            // Check against the union: a property is excess if no
            // object constituent knows it — unless SOME constituent is
            // itself an empty object type. tsc's `isEmptyObjectType` is
            // `some(types, isEmptyObjectType)` over a union, and
            // `hasExcessProperties` bails on it wholesale, so `T | {}`
            // (and `T | object`, and `T | <empty interface>`) accepts any
            // property exactly the way a bare `{}` target does. An empty
            // *index-signature* constituent like `Record<string, never>`
            // is not empty and does not bail — it elaborates instead.
            for (try c.memberList(rt)) |m| {
                if (try c.targetIsEmptyish(m)) return false;
            }
            // A union with NO object-ish constituent has nothing to name in the
            // message, and tsc declines to file the excess-property error at all
            // there: `errorTarget = filterType(reducedTarget,
            // isExcessPropertyCheckTarget)` comes back `never`, so the pair falls
            // through to the ordinary relation error instead —
            // `BigInt({ e: 1, m: 1 })` against `string | number | bigint |
            // boolean` is TS2345 on the ARGUMENT, not TS2353 on `e`.
            if (!try unionHasExcessCheckTarget(c, rt)) return false;
            // …and it is the DISCRIMINANT-REDUCED union the names are looked up
            // in (`epcReducedUnion`), not the whole one. Resolved again after
            // the reduction: a reduction down to ONE constituent yields that
            // constituent itself, and a named one (`Float`, a `.ref`) is a shape
            // `targetKnowsProp` cannot read — it would answer "knows every name"
            // and throw the reduction away.
            rt = try c.resolveStructural(try epcReducedUnion(c, src_t, rt));
        },
        // An intersection has no properties of its own, so the walk below
        // relies entirely on `targetKnowsProp`'s intersection arm (ANY
        // constituent knowing the name is enough — tsc's `isKnownProperty`
        // recursing through a `UnionOrIntersection`). Whether the target
        // participates at all is `intersectionExcessCheckable`.
        .intersection => if (!try c.intersectionExcessCheckable(rt)) return false,
        else => return false,
    }
    const members = c.tree.nodeRange(node);
    const last_spread = lastSpreadIndex(c, members);
    for (members, 0..) |prop, i| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        const key_tok = c.tree.nodeMainToken(prop);
        // A COMPUTED name is excess-checked under the name tsc LATE-BINDS it to
        // — `getPropertiesOfType(source)` hands `hasExcessProperties` the
        // late-bound symbol like any other, so `{ [Symbol.toPrimitive]: 0 }`
        // against a target without that member is TS2353. Three things about it
        // differ from an ordinary key, and all three are oracle-measured:
        //
        //   * the name is the LATE-BOUND one (`__@toPrimitive`, `"zzz"`, `"0"`,
        //     the `__@k$E.A` enum placeholder), which is what the target is
        //     asked about — `computed_key.lateBoundName`, the same answer the
        //     object-literal walk keys the member by;
        //   * a key that late-binds to NOTHING (a `string`-typed `[s]`) names no
        //     member and is skipped, exactly as tsc's `isLateBindableName`
        //     declines it;
        //   * the report anchors on the whole `[…]` and NAMES it as written —
        //     tsc's `symbolToString` of a late-bound symbol is its declaration's
        //     name text, so `'[Symbol.toPrimitive]'` and not `'__@toPrimitive'`.
        //
        // A method carries its computed name exactly where a property does
        // (`nodeData(prop).lhs`); reading the `[` token instead once reported an
        // excess property named "[" (`symbolProperty20`).
        //
        // The key TYPE comes from the node-type memo the object-literal walk
        // published, never from a fresh check: being the first to read a key
        // would report TS2464 on it a second time. An object METHOD's computed
        // key the walk never typed has no memo, and answers from the syntactic
        // `Symbol.<name>` recognizer alone — which is the one shape that needs
        // no type, and covers `{ [Symbol.toPrimitive]() {} }`.
        const pd = c.tree.nodeData(prop);
        const computed = (tag == .object_property or tag == .object_method) and
            pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name;
        var key_span = c.tokSpan(key_tok);
        var key: Atom = undefined;
        var key_text: []const u8 = undefined;
        if (computed) {
            const key_expr = c.tree.nodeData(pd.lhs).lhs;
            const kt = c.nodeType(key_expr) orelse types.no_type;
            key = (try computed_key.lateBoundName(c, key_expr, kt)) orelse continue;
            key_span = c.nodeSpan(pd.lhs);
            key_text = computed_key.nameText(c, pd.lhs);
        } else {
            key = try c.memberAtom(key_tok);
            key_text = c.atomText(key);
        }
        // A property a LATER spread also supplies is not this literal's to
        // answer for — see `overriddenByLaterSpread`. Skipped whole: the
        // nested-literal recursion below elaborates a value the spread throws
        // away, so it has nothing to say either.
        if (i < last_spread and try overriddenByLaterSpread(c, members, i, key)) continue;
        const known = try c.targetKnowsProp(rt, key);
        if (!known) {
            if (report) {
                // tsc's `hasExcessProperties` files the SUGGESTION form
                // (TS2561) whenever the unknown name is a near-miss of one the
                // target does have, and the plain TS2353 only otherwise — two
                // different codes for the same finding, so the choice has to be
                // made here rather than in a follow-up pass.
                if (try excessPropSuggestion(c, rt, key)) |sugg| {
                    try c.diagFmt(2561, key_span, "Object literal may only specify known properties, but '{s}' does not exist in type '{s}'. Did you mean to write '{s}'?", .{
                        key_text, try c.typeToString(target), c.atomText(sugg),
                    });
                } else {
                    try c.diagFmt(2353, key_span, "Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{
                        key_text, try c.typeToString(target),
                    });
                }
            }
            return true; // one excess error per literal, like tsc's early bail
        }
        // Recurse into nested fresh literals (and into a nested ARRAY literal,
        // whose elements the scan then walks).
        if (tag == .object_property) {
            const rhs_tag = c.nodeTag(pd.rhs);
            if (rhs_tag == .object_literal or rhs_tag == .array_literal) {
                if (c.nodeType(pd.rhs)) |nested_t| {
                    if (try nestedTargetPropType(c, rt, key)) |tp| {
                        if (try c.excessPropertyScan(pd.rhs, nested_t, tp, report)) return true;
                    }
                }
            }
        }
    }
    return false;
}

/// Would a fresh object-literal argument make this candidate signature
/// inapplicable? tsc runs the excess-property check *inside* the
/// assignability relation, and for a UNION target it runs it once per
/// constituent (`typeRelatedToSomeType` recurses with the source still
/// fresh) — so `throttle(fn, ms, { leading: false })` is not applicable to
/// the `ThrottleSettings & { leading: true } | Omit<ThrottleSettings,
/// "leading">` overload: the intersection arm rejects `false` and the
/// `Omit` arm does not know `leading`. ztsc keeps freshness out of
/// `isAssignable` (the relation is memoized on type pairs, and freshness
/// is a property of the *expression*), so overload probing consults this
/// predicate separately. It mirrors exactly what the reporting paths
/// (`excessPropertyCheck` / `freshLiteralUnionMismatch`) would file for
/// the same triple — the candidate is rejected iff the winning candidate
/// would have been diagnosed on this argument.
pub fn freshLiteralRejects(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!bool {
    var node = expr_node;
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) == .union_type) {
        for (try c.memberList(rt)) |m| {
            const rm = try c.resolveStructural(m);
            if (!try c.literalPropsKnownIn(node, rm)) continue;
            if (try c.isAssignable(src_t, m)) return false;
        }
        return !try c.discriminatedUnionAssignable(src_t, rt);
    }
    return try c.excessPropertyScan(node, src_t, target, false);
}

/// Does an INTERSECTION target take part in excess-property checking?
///
/// tsc gates the check on `isExcessPropertyCheckTarget`, whose intersection
/// arm requires EVERY constituent to be one, and then bails on
/// `isEmptyObjectType(target)`, whose intersection arm holds when EVERY
/// constituent is empty. Both are mirrored here, conservatively: a
/// constituent whose member set ztsc cannot enumerate up front — a type
/// parameter, a conditional/mapped/keyof node, a callable, a nested union —
/// disqualifies the whole intersection rather than risk a false TS2353.
/// That is what keeps the ubiquitous generic helpers quiet: `T & {}`
/// (non-nullish marker), `Props & Partial<T>`, `Base & TVariant`.
///
/// An index signature anywhere in the intersection also disqualifies it:
/// the intersection's index infos are the union of its constituents', so
/// one string/number index makes every name applicable (tsc's
/// `getApplicableIndexInfoForName` over the intersection).
pub fn intersectionExcessCheckable(c: *Checker, rt: TypeId) Error!bool {
    const ms = try c.memberList(rt);
    if (ms.len == 0) return false;
    var all_empty = true;
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .object => {
                if (c.ts.objectStringIndex(rm) != 0 or c.ts.objectNumberIndex(rm) != 0) return false;
                // A callable constituent carries members `targetKnowsProp`
                // does not consult (the apparent `Function` shape, plus
                // whatever the signature's own object side declares).
                if (c.ts.objectCallSigCount(rm) != 0 or c.ts.objectConstructSigCount(rm) != 0) return false;
                if (!c.isEmptyObjectType(rm)) all_empty = false;
            },
            // Canonical intersections are flattened, but an intersection
            // reached through a `ref` need not be.
            .intersection => {
                if (!try c.intersectionExcessCheckable(rm)) return false;
                all_empty = false;
            },
            // The `object` keyword qualifies as an excess-check target for tsc
            // (`isExcessPropertyCheckTarget` accepts `TypeFlags.NonPrimitive`)
            // and contributes no known name, so `object & { x: string }` is
            // checked exactly like `{ x: string }` alone — the case the
            // conformance corpus spells out as "the 'object' type has no effect
            // on intersections". It stays `isEmptyObjectType`, hence leaves
            // `all_empty` untouched.
            .object_keyword => {},
            else => return false,
        }
    }
    return !all_empty;
}

/// tsc's `isEmptyObjectType` as `hasExcessProperties` consults it: an
/// empty object literal type, the `object` keyword (`TypeFlags.NonPrimitive`
/// is unconditionally empty there), or a union with any such constituent.
pub fn targetIsEmptyish(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        .object => c.isEmptyObjectType(r),
        .object_keyword => true,
        .union_type => blk: {
            for (try c.memberList(r)) |m| {
                if (try c.targetIsEmptyish(m)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn targetKnowsProp(c: *Checker, rt: TypeId, key: Atom) Error!bool {
    switch (c.ts.kind(rt)) {
        .union_type => {
            for (try c.memberList(rt)) |m| {
                if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
            }
            return false;
        },
        .object => {
            if (c.ts.objectPropByName(rt, key) != null) return true;
            return c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0;
        },
        .intersection => {
            for (try c.memberList(rt)) |m| {
                if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
            }
            return false;
        },
        .any, .err, .unknown => return true,
        // tsc's `isKnownProperty` ends in `return false`: only an OBJECT (or
        // a union/intersection that recurses into one) can know a name. The
        // constituents below carry no members at all and are reached only
        // through the union/intersection recursion above — most often as the
        // `| undefined` an OPTIONAL parameter or property adds. Answering
        // "known" for them switched the excess-property check off for every
        // optional target: `cloneElement(child, { style: … })`, whose last
        // React overload takes `props?: Partial<P> & Attributes`, silently
        // accepted `style` where tsc reports TS2353 — and, in an OVERLOAD
        // set, the missing diagnostic also cost the TS2769 its ANCHOR (the
        // last candidate's re-check found nothing to point at, so the error
        // landed on the callee instead of on the offending property, out of
        // reach of the `@ts-expect-error` directly above it).
        //
        // The remaining `true` is the conservative answer for a target whose
        // members ztsc cannot enumerate here (a type parameter, a
        // conditional/mapped/keyof node, a callable): claiming a name is
        // excess in one of those risks a false TS2353.
        .undefined, .null, .void, .never => return false,
        // An ARRAY or TUPLE *is* an object type to tsc, so `isKnownProperty`
        // reads it like any other: its apparent members (`length`, `push`, …)
        // and, through `Array`'s numeric index signature, a numeric name — and
        // NOTHING else. The blanket `true` below made a union with an array
        // constituent unable to refuse any name at all, which is why
        // `var b: Book | Book[] = { forewarned: "" }` came out as a whole-type
        // TS2322 instead of tsc's TS2353 on `forewarned`.
        .array, .tuple => {
            if (assign.isNumericPropName(c.atomText(key))) return true;
            return (try c.propOfType(rt, key)) != null;
        },
        // A bare signature type is an object type to tsc as well, and one whose
        // resolved members are empty: it knows no written name at all. Reached as
        // a union constituent — `NoInfer<T> | NoInfer<() => T>` is the corpus
        // shape — where the blanket `true` silenced the check for the union.
        .function, .overloads => return (try c.propOfType(rt, key)) != null,
        // A PRIMITIVE carries no `TypeFlags.Object`, so tsc's `isKnownProperty`
        // is false for it whatever the name — `string`'s apparent `length`
        // included, since the test never looks at an apparent type. Reached as
        // a union constituent (`Book | string`), where answering "known"
        // switched the check off for the whole union. Same for the `object`
        // keyword, whose `NonPrimitive` flag has no members either (and which,
        // being `isEmptyObjectType`, bails the check out wholesale one level up
        // when it stands in a union — see `targetIsEmptyish`).
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .object_keyword,
        .bool_true,
        .bool_false,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .unique_symbol,
        .enum_type,
        .template_literal_type,
        .string_mapping,
        => return false,
        else => return true, // non-object targets: not our business here
    }
}

pub fn targetPropType(c: *Checker, rt: TypeId, key: Atom) Error!?TypeId {
    if (try c.propOfType(rt, key)) |p| return p.ty;
    return null;
}
