//! tsc's IDENTITY relation — a structural walk of its own, separate from
//! assignability and reachable only from the checks that need it.
//!
//! Identity is not "mutually assignable". `any` and `number` are mutually
//! assignable and are not identical; `<T, U>(x: T, y: U) => T` and
//! `<T, U>(x: any, y: any) => any` are mutually assignable and are not
//! identical. Both pairs are TS2403 in tsc and were silent here for exactly
//! that reason. What identity asks instead is: are these the SAME type, with
//! named references and the structures they stand for put on the same footing?
//!
//! tsc's `isTypeRelatedTo(source, target, identityRelation)` opens with
//! `source.flags !== target.flags → false` and then dispatches to
//! `propertiesIdenticalTo` / `signaturesIdenticalTo` /
//! `indexSignaturesIdenticalTo` for object types. This is that walk, with
//! ztsc's `Kind` standing in for the flags.
//!
//! ONE-SIDED BIAS. Every gap in this file must answer "identical", never
//! "different": the only consumer reports an error when the answer is
//! "different", so a missed difference is an under-report while an invented
//! one is a false error on legal code. The recursion depth cap, the
//! `undecidable` list, and the `.mapped`/`.conditional`/`.template_literal_type`
//! families ztsc cannot compare structurally all take that side.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const types = @import("../types.zig");

const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TpMap = @import("subst.zig").TpMap;
const tuple_relate = @import("tuple_relate.zig");

/// A generic signature pair is compared with the SOURCE's type parameters
/// mapped onto the target's (tsc's `compareSignaturesIdentical`, which builds
/// exactly that mapper and instantiates). The cap answers "identical", so a
/// runaway pair is an under-report.
///
/// Ten, not six: a MUTUALLY RECURSIVE interface pair spends four levels per
/// visible difference (property → signature → parameter → signature → nested
/// reference), so six ran out mid-signature. `promiseIdentity`'s
/// `IPromise2<string, number>` beside `Promise2<any, string>` differ in the
/// callback parameter of the `then` of the `then` — depth 6 exactly — and came
/// back identical. Only reached by the identity relation's three callers
/// (TS2403, contextual-signature agreement, discriminant contexts), all of
/// which are off the hot relation path.
const max_depth: u32 = 10;

/// tsc's `isTypeIdenticalTo`.
pub fn identical(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    return identicalAt(c, a, b, 0);
}

fn identicalAt(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
    if (a0 == b0) return true;
    if (depth >= max_depth) return true;
    if (undecidable(c, a0) or undecidable(c, b0)) return true;

    // Two materializations of the SAME generic reference are identical when
    // their type ARGUMENTS are, and an `any` argument is not evidence of a
    // difference: it is where ztsc's inference gave up. `var p2 =
    // shouldBeIdentity(p1)` infers `MyPromise<any, any>` here where tsc infers
    // `MyPromise<boolean, any>`, and reading that as the program declaring two
    // different types is a report about ztsc. Falls through to the structural
    // comparison when the arguments genuinely differ.
    if (c.ts.kind(a0) == .ref and c.ts.kind(b0) == .ref and
        c.ts.refSymbol(a0) == c.ts.refSymbol(b0))
    {
        const aa = c.ts.refArgs(a0);
        const ba = c.ts.refArgs(b0);
        if (aa.len == ba.len) {
            const args_a = try c.scratch().dupe(TypeId, aa);
            defer c.scratch().free(args_a);
            const args_b = try c.scratch().dupe(TypeId, ba);
            defer c.scratch().free(args_b);
            var all = true;
            for (args_a, args_b) |x, y| {
                // …but an `any` beside a free TYPE PARAMETER is a difference the
                // program wrote. A type parameter is never what a failed
                // inference leaves behind — that is `any` or `unknown` — so the
                // two declarations genuinely name two types, and the pair falls
                // through to the structural comparison below (which separates a
                // materialized map from a still-deferred one).
                // `noExcessiveStackDepthError`: `var x: FindConditions<any>;
                // var x: FindConditions<Entity>;` inside `function foo<Entity>()`.
                const inference_gave_up = (c.ts.kind(x) == .any or c.ts.kind(y) == .any) and
                    c.ts.kind(x) != .type_param and c.ts.kind(y) != .type_param;
                if (inference_gave_up) continue;
                if (!try identicalAt(c, x, y, depth + 1)) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
    }
    // A named reference and the structure it names are identical in tsc: an
    // `interface Point` IS the object type `{ x: number; y: number }`, and both
    // carry `TypeFlags.Object`. Resolving puts them on one footing, and a pair
    // of DIFFERENT references resolves to different structures, so nothing is
    // lost.
    const a = if (c.ts.kind(a0) == .ref) (c.resolveStructural(a0) catch return true) else a0;
    const b = if (c.ts.kind(b0) == .ref) (c.resolveStructural(b0) catch return true) else b0;
    if (a == b) return true;
    if (undecidable(c, a) or undecidable(c, b)) return true;

    // A one-call-signature object type and a function type are the same thing
    // written twice (`{ (s: string): number }` and `(s: string) => number`).
    const fa = asSingleSignature(c, a) orelse a;
    const fb = asSingleSignature(c, b) orelse b;
    if (fa == fb) return true;

    const ka = c.ts.kind(fa);
    const kb = c.ts.kind(fb);
    // tsc's `source.flags !== target.flags` gate. This is where `any` stops
    // being identical to `number` and `"a"` stops being identical to `string`
    // — the whole point of having the relation.
    if (ka != kb) return false;

    return switch (ka) {
        // Hash-consed leaves: reaching here with `fa != fb` means two DIFFERENT
        // literals, symbols, enums or type parameters, and tsc's identity
        // relation separates all of those.
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .bool_true,
        .bool_false,
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .null,
        .undefined,
        .never,
        .any,
        .object_keyword,
        .unique_symbol,
        .enum_type,
        .type_param,
        => false,
        .array => c.ts.arrayIsReadonly(fa) == c.ts.arrayIsReadonly(fb) and
            try identicalAt(c, c.ts.arrayElem(fa), c.ts.arrayElem(fb), depth + 1),
        .tuple => tupleIdentical(c, fa, fb, depth),
        .function => sigIdentical(c, fa, fb, depth),
        .object => objectIdentical(c, fa, fb, depth),
        .union_type, .intersection, .overloads => memberSetIdentical(c, fa, fb, depth),
        .keyof_op => identicalAt(c, c.ts.keyofOperand(fa), c.ts.keyofOperand(fb), depth + 1),
        .index_access => (try identicalAt(c, c.ts.indexAccessObj(fa), c.ts.indexAccessObj(fb), depth + 1)) and
            (try identicalAt(c, c.ts.indexAccessIndex(fa), c.ts.indexAccessIndex(fb), depth + 1)),
        .conditional => (try identicalAt(c, c.ts.condCheck(fa), c.ts.condCheck(fb), depth + 1)) and
            (try identicalAt(c, c.ts.condExtends(fa), c.ts.condExtends(fb), depth + 1)) and
            (try identicalAt(c, c.ts.condTrue(fa), c.ts.condTrue(fb), depth + 1)) and
            (try identicalAt(c, c.ts.condFalse(fa), c.ts.condFalse(fb), depth + 1)),
        // Families with no structural comparison here: answer "identical" so
        // the caller stays silent (see the one-sided bias in the module note).
        else => true,
    };
}

/// Types this relation refuses to judge, because ztsc reaches them by giving up
/// rather than by reading the program:
///
///   * `unknown` is what a failed inference leaves behind, `err` what a reported
///     error leaves, `void` what an unresolved value declaration leaves, and a
///     `class_value` is NOMINAL here so it never matches the structural type tsc
///     calls identical to it;
///   * a polymorphic `this` is resolved to its home class in some positions and
///     left standing in others, so `{ x: this }` and `{ x: MyClass }` are two
///     spellings of one type that ztsc cannot line up
///     (`thisInObjectLiterals.ts`);
///   * a template-literal pattern and a string mapping have no pattern-to-pattern
///     matcher here (the relation itself says so — see `isAssignableInner`'s
///     `.template_literal_type` arm), so the reductions that make `'0' &
///     \`${number}\`` just `'0'` and `` `${number}` | '0' `` just `` `${number}` ``
///     do not happen and the two declarations look different
///     (`templateLiteralTypesPatterns.ts`).
fn undecidable(c: *const Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .unknown, .void, .err, .class_value, .this_type, .template_literal_type, .string_mapping => true,
        .array => undecidable(c, c.ts.arrayElem(t)),
        // A union or intersection is refused when any CONSTITUENT is, because
        // the reduction that would have removed it is the missing piece: `'0' &
        // `${number}`` never collapses to `'0'`, so the pair does not even reach
        // the same kind, let alone the same members.
        .union_type, .intersection => blk: {
            for (0..c.ts.memberCount(t)) |i| {
                if (undecidable(c, c.ts.memberAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// The lone call signature of an object type that is nothing BUT that
/// signature — the object spelling of a function type.
fn asSingleSignature(c: *const Checker, t: TypeId) ?TypeId {
    if (c.ts.kind(t) != .object) return null;
    if (c.ts.objectCallSigCount(t) != 1) return null;
    if (c.ts.objectPropCount(t) != 0 or c.ts.objectConstructSigCount(t) != 0) return null;
    if (c.ts.objectStringIndex(t) != types.no_type or c.ts.objectNumberIndex(t) != types.no_type) return null;
    return c.ts.objectCallSig(t, 0);
}

fn tupleIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    const len = c.ts.tupleLen(a);
    if (len != c.ts.tupleLen(b)) return false;
    for (0..len) |i| {
        const ea = c.ts.tupleElem(a, @intCast(i));
        const eb = c.ts.tupleElem(b, @intCast(i));
        if (tuple_relate.elemKind(c, ea) != tuple_relate.elemKind(c, eb)) return false;
        // An OPTIONAL element's type has `| undefined` baked into it in tsc
        // (`addOptionality`), where ztsc keeps the bare type beside the flag —
        // so `[1, 2?]` and `[1, (2 | undefined)?]` are one type there and two
        // ids here. `optionalTupleElementsAndUndefined.ts` says so in a comment.
        const ta = if (ea.optional()) try c.makeUnion2(ea.ty, types.undefined_type) else ea.ty;
        const tb = if (eb.optional()) try c.makeUnion2(eb.ty, types.undefined_type) else eb.ty;
        if (!try identicalAt(c, ta, tb, depth + 1)) return false;
    }
    return true;
}

/// tsc's `propertiesIdenticalTo` + `signaturesIdenticalTo` +
/// `indexSignaturesIdenticalTo`. Properties are name-sorted by the store, so
/// the pairing is positional.
fn objectIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    // An optional property typed exactly `undefined` is an ABSENCE MARKER, not
    // a member: `getSpreadType` over a union writes `b?: undefined` into the arm
    // that has no `b`, and whether ztsc materializes those markers where tsc
    // does is a fact about the two spread implementations, not about the two
    // declarations being compared. So they are skipped on both sides —
    // `{ a: number } | { b: string }` beside `{ a: number; b?: undefined } |
    // { a?: undefined; b: string }` is one declaration written twice.
    if (!try propsIdentical(c, a, b, depth)) return false;
    const ncall = c.ts.objectCallSigCount(a);
    if (ncall != c.ts.objectCallSigCount(b)) return false;
    const nctor = c.ts.objectConstructSigCount(a);
    if (nctor != c.ts.objectConstructSigCount(b)) return false;
    for (0..ncall) |i| {
        if (!try sigIdentical(c, c.ts.objectCallSig(a, @intCast(i)), c.ts.objectCallSig(b, @intCast(i)), depth + 1)) return false;
    }
    for (0..nctor) |i| {
        if (!try sigIdentical(c, c.ts.objectConstructSig(a, @intCast(i)), c.ts.objectConstructSig(b, @intCast(i)), depth + 1)) return false;
    }
    if (!try indexIdentical(c, c.ts.objectStringIndex(a), c.ts.objectStringIndex(b), depth)) return false;
    if (!try indexIdentical(c, c.ts.objectNumberIndex(a), c.ts.objectNumberIndex(b), depth)) return false;
    return true;
}

/// Is `p` an absence MARKER rather than a member — an optional property whose
/// type is exactly `undefined`?
fn isAbsenceMarker(c: *const Checker, p: types.Prop) bool {
    return p.optional() and c.ts.kind(p.ty) == .undefined;
}

/// tsc's `propertiesIdenticalTo`, minus the absence markers (see
/// `objectIdentical`). Both sides are name-sorted by the store, so the surviving
/// properties pair up in order.
fn propsIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    var ia: u32 = 0;
    var ib: u32 = 0;
    const na = c.ts.objectPropCount(a);
    const nb = c.ts.objectPropCount(b);
    while (true) {
        while (ia < na and isAbsenceMarker(c, c.ts.objectProp(a, ia))) ia += 1;
        while (ib < nb and isAbsenceMarker(c, c.ts.objectProp(b, ib))) ib += 1;
        if (ia == na or ib == nb) return ia == na and ib == nb;
        const pa = c.ts.objectProp(a, ia);
        const pb = c.ts.objectProp(b, ib);
        if (pa.name != pb.name) return false;
        if (pa.optional() != pb.optional()) return false;
        if (!try identicalAt(c, pa.ty, pb.ty, depth + 1)) return false;
        ia += 1;
        ib += 1;
    }
}

fn indexIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    if (a == types.no_type or b == types.no_type) return a == b;
    return identicalAt(c, a, b, depth + 1);
}

/// Two unions (or intersections, or overload sets) are identical when each
/// constituent of one is identical to some constituent of the other, both ways
/// — tsc's `eachTypeRelatedToSomeType` in both directions under the identity
/// relation. The store already sorts and dedupes union members, so a pair that
/// differs only in written order is the same id and never reaches here; what
/// does reach here is a pair whose members differ through a NAMED reference on
/// one side.
fn memberSetIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    const na = c.ts.memberCount(a);
    const nb = c.ts.memberCount(b);
    if (na != nb) return false;
    for (0..na) |i| {
        const ma = c.ts.memberAt(a, @intCast(i));
        var found = false;
        for (0..nb) |j| {
            if (try identicalAt(c, ma, c.ts.memberAt(b, @intCast(j)), depth + 1)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// tsc's `compareSignaturesIdentical`: the same type-parameter COUNT, the same
/// parameter count and optionality, then the source's type parameters mapped
/// onto the target's before parameters and return types are compared. The
/// mapping is what makes two separately written `<T>(x: T) => T` annotations
/// identical even though each `T` is its own symbol.
/// tsc's `compareSignaturesIdentical(a, b, partialMatch: false,
/// ignoreThisTypes: true, ignoreReturnTypes: true, compareTypesIdentical)` —
/// the comparison `getContextualSignature` runs across a union's
/// constituents to decide whether they all offer the SAME signature. Only the
/// parameter lists are in question there: two constituents that differ in
/// what they RETURN still type the expression's parameters the same way.
pub fn signatureParamsIdentical(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (c.ts.kind(a) != .function or c.ts.kind(b) != .function) return a == b;
    return sigIdenticalAt(c, a, b, 0, true);
}

/// The bound a signature type parameter was DECLARED with, in the vocabulary of
/// the type being compared.
///
/// `typeParamConstraint` answers what the relation ENFORCES, and that is not the
/// same question. Instantiating a signature whose parameter has a BARE bound
/// (`<W extends V>`, the bound being another parameter) mints a fresh parameter
/// with NO enforced constraint on purpose — enforcing the substituted form would
/// erase a legitimate inference — and parks the substituted bound on
/// `FreshTp.widen_bound` instead (see `eagerBound`'s `fc`/`wb`).
///
/// Identity has to see it. `interface I<V> { then<W extends V>(cb: W): void }`
/// at `I<number>` and at `I<boolean>` differ in NOTHING else: `V` appears
/// nowhere in the signature's payload, so both `then`s instantiate to a function
/// type whose only distinguishing mark is that bound. Reading the enforced
/// constraint alone saw `no_type` on both sides, skipped the comparison, and
/// called the two declarations identical (`promiseIdentityWithConstraints`).
fn declaredBound(c: *Checker, sym: u32) Error!TypeId {
    // Asked first: for a fresh parameter this is what forces a DEFERRED bound,
    // so `widen_bound` below is only meaningful afterwards.
    const con = try c.typeParamConstraint(sym);
    if (con != types.no_type) return con;
    if (c.isFreshTp(sym)) return c.freshTp(sym).widen_bound;
    return types.no_type;
}

fn sigIdentical(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    return sigIdenticalAt(c, a, b, depth, false);
}

fn sigIdenticalAt(c: *Checker, a: TypeId, b: TypeId, depth: u32, ignore_return: bool) Error!bool {
    if (a == b) return true;
    const ntp = c.ts.fnTypeParamCount(a);
    if (ntp != c.ts.fnTypeParamCount(b)) return false;
    const pa = c.ts.fnParamCount(a);
    if (pa != c.ts.fnParamCount(b)) return false;
    for (0..pa) |i| {
        const x = c.ts.fnParam(a, @intCast(i));
        const y = c.ts.fnParam(b, @intCast(i));
        if (x.optional() != y.optional() or x.rest() != y.rest()) return false;
    }
    // Map the source's own type parameters onto the target's, then compare in
    // the target's vocabulary. Building the map costs an allocation, which is
    // why identity is a separate entry point and not a mode of the relation —
    // and why the three copies below live under the `ntp > 0` guard: the
    // overwhelming majority of signature pairs are non-generic and must not pay
    // an allocator call to find that out.
    // `fnTypeParams` is BORROWED from the store's `extra` and dies on the next
    // intern — and everything done with the two lists interns: `makeTypeParam`
    // mints a type, `typeParamConstraint` materializes a bound from the AST.
    // Walking the live slices read reallocated memory, so the symbols came back
    // garbage, `typeParamConstraint` answered `no_type` for both sides, and the
    // bound comparison was skipped outright — every pair whose ONLY difference
    // is a signature type parameter's bound came back "identical"
    // (`promiseIdentityWithConstraints`, where `IPromise<string, number>` and
    // `Promise<string, boolean>` differ in nothing else).
    var tpa: []u32 = &.{};
    defer if (tpa.len > 0) c.scratch().free(tpa);
    var tpb: []u32 = &.{};
    defer if (tpb.len > 0) c.scratch().free(tpb);
    var map: []TpMap = &.{};
    defer if (map.len > 0) c.scratch().free(map);
    if (ntp > 0) {
        tpa = try c.scratch().dupe(u32, c.ts.fnTypeParams(a));
        tpb = try c.scratch().dupe(u32, c.ts.fnTypeParams(b));
        map = try c.scratch().alloc(TpMap, tpa.len);
        for (map, tpa, tpb) |*m, sa, sb| {
            m.* = .{ .sym = sa, .ty = try c.ts.makeTypeParam(sb) };
        }
    }
    for (0..pa) |i| {
        const sp = if (map.len > 0)
            try c.instantiate(c.ts.fnParam(a, @intCast(i)).ty, map)
        else
            c.ts.fnParam(a, @intCast(i)).ty;
        if (!try identicalAt(c, sp, c.ts.fnParam(b, @intCast(i)).ty, depth + 1)) return false;
    }
    if (!ignore_return) {
        const ra = if (map.len > 0) try c.instantiate(c.ts.fnReturn(a), map) else c.ts.fnReturn(a);
        if (!try identicalAt(c, ra, c.ts.fnReturn(b), depth + 1)) return false;
    }
    // The bounds must agree in the same vocabulary (tsc compares them before it
    // accepts the mapping). Asked LAST, which the answer does not depend on —
    // any difference is decisive whichever check finds it — and the cost does:
    // reading a fresh parameter's bound FORCES the deferred substitution
    // `mintFreshTpDeferred` exists to avoid, and on drizzle a bound is a mapped
    // type over every column of every table in scope. Behind the payload
    // comparison it runs only for pairs that are identical everywhere else.
    for (tpa, tpb) |sa, sb| {
        // Two instantiations of the SAME declared signature: any bound
        // difference between them comes from the enclosing type arguments
        // alone, and that is the case tsc decides by VARIANCE rather than
        // structurally — a parameter witnessed nowhere but in a bound is
        // `VarianceFlags.Independent`, whose arguments `typeArgumentsRelatedTo`
        // ignores outright. `interface I<V> { then<W extends V>(cb: W): void }`
        // is one type at `I<number>` and at `I<boolean>` for exactly that
        // reason. A parameter the structure DOES witness shows its difference
        // in the parameter/return comparison above, so skipping the bound here
        // hides nothing.
        if (c.tpOrigin(sa) == c.tpOrigin(sb)) continue;
        const ca = try declaredBound(c, sa);
        const cb = try declaredBound(c, sb);
        if ((ca == types.no_type) != (cb == types.no_type)) return false;
        if (ca == types.no_type) continue;
        if (!try identicalAt(c, try c.instantiate(ca, map), cb, depth + 1)) return false;
    }
    return true;
}
