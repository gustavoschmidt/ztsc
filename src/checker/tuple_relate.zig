//! The tuple side of the assignability relation, including variadic tuples.
//!
//! A tuple element in ztsc is `{ ty, flags }` with three flags — optional,
//! rest, readonly — where tsc's tuple target carries four *element kinds*:
//! `Required`, `Optional`, `Rest` (`...T[]`, one array's worth of a single
//! element type) and `Variadic` (`...T`, a whole still-unknown array or tuple
//! spliced in at that position). The fourth is not a flag here because it is
//! not independent: `makeTuple` already splices a rest element whose type is a
//! TUPLE and collapses a lone rest element spelled as an ARRAY, so a rest
//! element whose type is *neither* is exactly tsc's `Variadic`. `elemKind`
//! is the one place that reads that off, and everything downstream speaks in
//! `ElemKind`.
//!
//! Three rules from tsc live here, all of them about variadic elements:
//!
//!   * `tupleAssignable` — tsc's `propertiesRelatedTo` tuple branch, which
//!     walks SOURCE positions and maps each to a target position, so a
//!     variadic middle can absorb a run of source elements while fixed
//!     prefixes and suffixes still line up positionally;
//!   * `singleElementBridge` — for a generic `T`, `[...T]` is assignable to
//!     `T`, `T` is assignable to `readonly [...T]`, and `T` is assignable to
//!     `[...T]` when `T` is constrained to a MUTABLE array or tuple
//!     (tsc's `isSingleElementGenericTupleType` pair in
//!     `structuredTypeRelatedTo`);
//!   * `constrainedGenericTuple` — a generic tuple source meeting a concrete
//!     tuple target retries under its variadic elements' constraints, so
//!     `[...T, ...T]` with `T extends [unknown]` reaches `[unknown, unknown]`
//!     (tsc's `getBaseConstraint` arm for `isGenericTupleType`).
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const types = @import("../types.zig");

const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's `ElementFlags`, reconstructed from ztsc's two positional flag bits
/// plus the element type's kind (see the module comment).
pub const ElemKind = enum {
    required,
    optional,
    /// `...T[]` — an unbounded run of ONE element type.
    rest,
    /// `...T` — a whole unresolved array/tuple spliced in at this position.
    variadic,

    /// tsc's `ElementFlags.Variable` (`Rest | Variadic`): the element does not
    /// occupy exactly one position.
    pub fn variable(k: ElemKind) bool {
        return k == .rest or k == .variadic;
    }

    /// tsc's `ElementFlags.NonRest` (`Required | Optional | Variadic`) — used
    /// by `startCount`/`endCount` to find the fixed head and tail around a
    /// target's rest element.
    pub fn nonRest(k: ElemKind) bool {
        return k != .rest;
    }
};

pub fn elemKind(c: *const Checker, e: types.TupleElem) ElemKind {
    if (!e.rest()) return if (e.optional()) .optional else .required;
    return switch (c.ts.kind(e.ty)) {
        .array => .rest,
        // An unreduced indexed access or conditional is NOT treated as a
        // variadic hole. tsc reaches these through `getNormalizedTupleType`,
        // which SIMPLIFIES a `Simplifiable` element before the relation looks
        // at it — `{ [S in SS]: [a: number] }[SS]` is the mapped type's
        // template `[a: number]`, spliced in, so `["AAA", ...that]` IS
        // `["AAA", number]`. ztsc has no `getSimplifiedIndexedAccessType` for
        // a generic mapped object, so calling the element variadic would
        // demand a variadic source element for a position that is in fact an
        // ordinary `number` — a false positive on every such annotation.
        // Reading it as an unbounded rest keeps the pre-variadic leniency for
        // exactly the elements ztsc cannot reduce.
        .index_access, .conditional => .rest,
        else => .variadic,
    };
}

fn elemKindAt(c: *const Checker, tup: TypeId, i: u32) ElemKind {
    return elemKind(c, c.ts.tupleElem(tup, i));
}

/// Does `tup` contain a variadic element (tsc's `isGenericTupleType`)?
pub fn isGenericTuple(c: *const Checker, tup: TypeId) bool {
    if (c.ts.kind(tup) != .tuple) return false;
    for (0..c.ts.tupleLen(tup)) |i| {
        if (elemKindAt(c, tup, @intCast(i)) == .variadic) return true;
    }
    return false;
}

/// tsc's `fixedLength`: how many LEADING elements occupy exactly one position
/// each — the index of the first rest or variadic element, or the arity when
/// there is none.
///
/// `createTupleTargetType` creates the numeric properties `"0"`, `"1"`, … only
/// for those, and stops at the first variable element, so `fixedLength` is
/// also the answer to "does this tuple have a property named `i`". Two callers
/// depend on that: the element-wise elaboration of an array literal
/// (`generateLimitedTupleElements` skips indices the target has no property
/// for) and `getEffectiveRestType` (which slices a rest parameter's tuple from
/// here on and hands the remainder to the whole-list check).
pub fn fixedLength(c: *const Checker, tup: TypeId) u32 {
    const len = c.ts.tupleLen(tup);
    for (0..len) |i| {
        if (elemKindAt(c, tup, @intCast(i)).variable()) return @intCast(i);
    }
    return len;
}

/// The lone variadic element's type, for a `[...T]` (tsc's
/// `isSingleElementGenericTupleType`).
fn soleVariadicElem(c: *const Checker, tup: TypeId) ?TypeId {
    if (c.ts.kind(tup) != .tuple or c.ts.tupleLen(tup) != 1) return null;
    const e = c.ts.tupleElem(tup, 0);
    return if (elemKind(c, e) == .variadic) e.ty else null;
}

/// tsc's `isMutableArrayOrTuple`. A readonly TUPLE is not representable in
/// ztsc (the modifier is dropped — see `typeFromTypeNode`'s `.readonly_type`),
/// so only the array half of the test can distinguish anything.
fn isMutableArrayOrTuple(c: *const Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .array => !c.ts.arrayIsReadonly(t),
        .tuple => true,
        else => false,
    };
}

/// tsc's `isSingleElementGenericTupleType` pair in `structuredTypeRelatedTo`.
/// Returns `true` when the pair is related through the bridge, `false` when
/// the bridge does not apply or its inner question said no — in which case the
/// caller carries on with the ordinary relation, exactly as tsc's `||` chain
/// falls through.
pub fn singleElementBridge(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (soleVariadicElem(c, s)) |arg| {
        // `[...T]` → anything: relate `T` itself. (tsc also requires the
        // source tuple not be `readonly`; ztsc cannot spell that.)
        if (try c.isAssignable(arg, t)) return true;
    }
    if (soleVariadicElem(c, t)) |arg| {
        // anything → `[...T]`: legal only when the source is (constrained to)
        // a MUTABLE array or tuple — a `readonly` one would gain `push`.
        if (isMutableArrayOrTuple(c, try c.transitiveBaseConstraint(s))) {
            if (try c.isAssignable(s, arg)) return true;
        }
    }
    return false;
}

/// tsc's `getBaseConstraint` arm for `isGenericTupleType`: replace each
/// variadic element by its constraint, but only when that constraint is
/// itself a plain (non-generic) array or tuple — otherwise the substitution
/// could recur without bound. Returns null when nothing changed.
pub fn constrainedGenericTuple(c: *Checker, tup: TypeId) Error!?TypeId {
    const len = c.ts.tupleLen(tup);
    var out: std.ArrayList(types.TupleElem) = .empty;
    defer out.deinit(c.scratch());
    var changed = false;
    for (0..len) |i| {
        const e = c.ts.tupleElem(tup, @intCast(i));
        var ty = e.ty;
        if (elemKind(c, e) == .variadic and c.ts.kind(e.ty) == .type_param) {
            const bc = try c.transitiveBaseConstraint(e.ty);
            if (bc != e.ty and (c.ts.kind(bc) == .array or
                (c.ts.kind(bc) == .tuple and !isGenericTuple(c, bc))))
            {
                ty = bc;
                changed = true;
            }
        }
        try out.append(c.scratch(), .{ .ty = ty, .flags = e.flags });
    }
    if (!changed) return null;
    return try c.ts.makeTuple(out.items);
}

/// tsc's `propertiesRelatedTo` tuple branch (checker.ts, TS 5.9).
///
/// The walk is over SOURCE positions, each mapped to a target position: a
/// target with a variable element has a fixed head of `startCount` elements
/// and a fixed tail of `endCount`, and every source position between them
/// maps onto the one variable element in the middle. That is what lets
/// `[a, b, c]` satisfy `[x, ...y[], z]` with `b` checked against `y`, and what
/// makes a variadic target element demand a variadic source element at the
/// same position (`[string, ...T]` is not satisfied by `[string, ...unknown[]]`
/// — `T` could be anything).
pub fn tupleAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    const s_len = c.ts.tupleLen(s);
    const t_len = c.ts.tupleLen(t);

    // tsc's `combinedFlags & Rest` / `minLength` (which counts Required AND
    // Variadic elements — a variadic element contributes at least nothing,
    // but the position must be matched by one).
    var s_rest = false;
    var s_min: u32 = 0;
    for (0..s_len) |i| switch (elemKindAt(c, s, @intCast(i))) {
        .rest => s_rest = true,
        .required, .variadic => s_min += 1,
        .optional => {},
    };
    var t_variable = false;
    var t_min: u32 = 0;
    for (0..t_len) |i| switch (elemKindAt(c, t, @intCast(i))) {
        .rest => t_variable = true,
        .variadic => {
            t_variable = true;
            t_min += 1;
        },
        .required => t_min += 1,
        .optional => {},
    };

    if (!s_rest and s_len < t_min) return false;
    if (!t_variable and t_len < s_min) return false;
    if (!t_variable and (s_rest or t_len < s_len)) return false;

    // tsc's `getStartElementCount`/`getEndElementCount` over `NonRest`: the
    // length of the target's fixed head and tail around its rest element.
    var t_start: u32 = t_len;
    for (0..t_len) |i| {
        if (!elemKindAt(c, t, @intCast(i)).nonRest()) {
            t_start = @intCast(i);
            break;
        }
    }
    var t_end: u32 = t_len;
    var i = t_len;
    while (i > 0) : (i -= 1) {
        if (!elemKindAt(c, t, i - 1).nonRest()) {
            t_end = t_len - i;
            break;
        }
    }

    for (0..s_len) |sp_| {
        const sp: u32 = @intCast(sp_);
        const se = c.ts.tupleElem(s, sp);
        const sf = elemKind(c, se);
        const sp_from_end = s_len - 1 - sp;
        const back = @min(sp_from_end, t_end);
        // A target whose EVERY element is non-rest (all fixed, or fixed around
        // a variadic) has `t_end == t_len`, and a source longer than the target
        // then walks past position 0 counting back from the end. tsc computes
        // the same negative index and reads `undefined` off the flags array;
        // there is no position for those source elements, so the pair is not
        // related. (`[...T, a, b]` against `[...T]` is the shape: position 0
        // pairs variadic-to-variadic, and `a` has nowhere left to go.)
        if (t_variable and sp >= t_start and back + 1 > t_len) return false;
        const tp = if (t_variable and sp >= t_start)
            t_len - 1 - back
        else
            sp;
        const te = c.ts.tupleElem(t, tp);
        const tf = elemKindAt(c, t, tp);
        // A variadic target element is a hole only another variadic element
        // can fill; a variadic source element needs a variable target element
        // to spread into; and a required target element needs a required
        // source element at that position.
        if (tf == .variadic and sf != .variadic) return false;
        if (sf == .variadic and !tf.variable()) return false;
        if (tf == .required and sf != .required) return false;

        const st = if (sf == .rest) try c.elemOfArrayish(se.ty) else se.ty;
        var tt = switch (tf) {
            // Spreading a whole array/tuple into a `...T[]` position compares
            // the two ARRAYS, not array-against-element (tsc's
            // `createArrayType(targetType)`).
            .rest => if (sf == .variadic) te.ty else try c.elemOfArrayish(te.ty),
            else => te.ty,
        };
        // An OPTIONAL target element admits `undefined` — tsc bakes it into
        // the element's own type (`[a?: T]`'s type argument is
        // `T | undefined`), where ztsc keeps the bare `T` beside the flag.
        // Reading only the bare type rejected `[string, O | undefined]`
        // against `[string, O?]`, which tsc accepts.
        if (tf == .optional) tt = try c.makeUnion2(tt, types.undefined_type);
        if (!try c.isAssignable(st, tt)) return false;
    }
    return true;
}
