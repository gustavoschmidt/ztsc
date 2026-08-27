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
//! The READONLY question also lives here, for both spellings of a list
//! (`isReadonlyArrayOrTuple` / `isMutableArrayOrTuple` / `readonlyMismatch`,
//! plus the `instanceof` and write-site variants): tsc gets the same answers
//! structurally, because its `ReadonlyArray` interface has no `push` and its
//! tuple target carries the modifier, while ztsc's readonly array shares
//! `Array`'s member table and its readonly tuple is a flag — so the relation
//! needs one explicit screen instead.
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
const Atom = types.Atom;

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

/// The member `createTupleTargetType` declares for a numeric NAME — the thing
/// `fixedLength`'s doc comment describes, handed back as a `Prop`.
///
/// A tuple in tsc is an ordinary object type whose members are `"0"`, `"1"`, …
/// one per FIXED element, plus `length`. Nothing about the relation is
/// tuple-aware once those exist: `[number[], string[]]` meets
/// `interface Tup { 0: number[]; 1: string[] }` because the source genuinely
/// *has* properties by those names. ztsc stores a tuple as a positional
/// element list instead, so the names had no answer at all and every such
/// target was a spurious TS2322 — including `Record<"0" | "1", …>`,
/// `T extends { 0: number }`, and an interface that adds a numeric member to
/// `Array<T>`.
///
/// Deliberately NOT wired into `propOfType`: the members tsc synthesizes here
/// are the tuple's own, so they are visible to the relation and to `keyof`,
/// but ztsc answers element ACCESS (`t[0]`) positionally through
/// `tupleElemTypeAt` and answers `keyof` in `keyof.zig`, both of which already
/// agree with tsc. The relation is the one caller that was missing them, and
/// it reaches them through `assign.relationSrcProp`.
///
/// Only the fixed prefix: past the first rest or variadic element a position
/// is not a fixed name, so `[...number[], string]` has NO property `"0"` and
/// tsc says so (TS2741, oracle-verified). Optionality and readonly-ness come
/// from the element and the tuple, matching `createTupleTargetType`'s
/// `ElementFlags.Optional` and `readonly` modifier.
pub fn numericProp(c: *Checker, tup: TypeId, name: Atom) ?types.Prop {
    if (c.ts.kind(tup) != .tuple) return null;
    const text = c.atomText(name);
    // Canonical decimal spelling only — `"+1"`, `"007"` and `"1e0"` name no
    // tuple member (and `parseInt` would accept the first two).
    if (!Checker.isNumericPropName(text)) return null;
    const idx = std.fmt.parseInt(u32, text, 10) catch return null;
    if (idx >= fixedLength(c, tup)) return null;
    const e = c.ts.tupleElem(tup, idx);
    var flags: u32 = 0;
    // The element type already carries `| undefined` for an optional element
    // (`makeTuple` adds it), so the flag alone is what is left to report.
    if (e.optional()) flags |= types.prop_flag_optional;
    if (e.readonly()) flags |= types.prop_flag_readonly;
    return .{ .name = name, .ty = e.ty, .flags = flags };
}

/// tsc's `getEndElementCount(t, ElementFlags.Fixed)`: how many TRAILING
/// elements occupy exactly one position each.
pub fn endFixedCount(c: *const Checker, tup: TypeId) u32 {
    const len = c.ts.tupleLen(tup);
    var n: u32 = 0;
    while (n < len) : (n += 1) {
        if (elemKindAt(c, tup, len - 1 - n).variable()) break;
    }
    return n;
}

/// tsc's `getContextualTypeForElementExpression`: which element of `tup`
/// contextually types the expression at position `index` of a list `length`
/// long.
///
/// This is the question `tupleElemTypeAt` cannot answer, and it needs the
/// LENGTH to answer it: once a variable element precedes `index`, the position
/// is decided by counting back from the END. `[...((a: number) => void)[],
/// (a: string) => void]` gives position 0 of a ONE-element list the
/// `(a: string) => void`, position 0 of a THREE-element list the
/// `(a: number) => void`, and anything in the middle the union of the two. Read
/// from the start instead, every such callback got the union — so `f1(x =>
/// str(x))` typed `x` as `number | string` and reported inside its own body.
///
/// A spread in the list makes the positions unknowable; callers must not use
/// this then (tsc threads the spread indices through and gives up the same way).
pub fn contextualElemType(c: *Checker, tup: TypeId, index: u32, length: u32) Error!?TypeId {
    const arity = c.ts.tupleLen(tup);
    const fixed = fixedLength(c, tup);
    if (index < fixed) {
        const e = c.ts.tupleElem(tup, index);
        return if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
    }
    // Positions from the end, 1-based: the last element of the list is 1.
    const offset = if (length > index) length - index else 0;
    const end_fixed = if (offset > 0 and fixed < arity) endFixedCount(c, tup) else 0;
    if (offset > 0 and offset <= end_fixed) return c.ts.tupleElem(tup, arity - offset).ty;
    // The middle: the union of everything the variable element could stand for.
    if (fixed + end_fixed >= arity) return null;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (fixed..arity - end_fixed) |i| {
        const e = c.ts.tupleElem(tup, @intCast(i));
        try parts.append(c.scratch(), if (elemKind(c, e) == .required or elemKind(c, e) == .optional)
            e.ty
        else
            try c.elemOfArrayish(e.ty));
    }
    if (parts.items.len == 0) return null;
    return try c.ts.makeUnion(c.scratch(), parts.items);
}

/// The lone variadic element's type, for a `[...T]` (tsc's
/// `isSingleElementGenericTupleType`).
fn soleVariadicElem(c: *const Checker, tup: TypeId) ?TypeId {
    if (c.ts.kind(tup) != .tuple or c.ts.tupleLen(tup) != 1) return null;
    const e = c.ts.tupleElem(tup, 0);
    return if (elemKind(c, e) == .variadic) e.ty else null;
}

/// tsc's `isMutableArrayOrTuple`.
pub fn isMutableArrayOrTuple(c: *const Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .array => !c.ts.arrayIsReadonly(t),
        .tuple => !isReadonlyTuple(c, t),
        else => false,
    };
}

/// A readonly tuple, from either of its two provenances: the tuple-level
/// `readonly [...]` modifier, or an every-element `elem_flag_readonly` marking
/// (`as const`, `Readonly<[A, B]>`). An EMPTY tuple is only readonly through
/// the flag — `[]` has no elements to mark, so the all-elements test would
/// call it readonly and `const t: [] = readonlyOne` would report TS4104 where
/// tsc reports the arity mismatch.
fn isReadonlyTuple(c: *const Checker, t: TypeId) bool {
    if (c.ts.tupleIsReadonly(t)) return true;
    const len = c.ts.tupleLen(t);
    if (len == 0) return false;
    for (0..len) |i| {
        if (!c.ts.tupleElem(t, @intCast(i)).readonly()) return false;
    }
    return true;
}

/// tsc's `isReadonlyArrayType(source) || isTupleType(source) &&
/// source.target.readonly` — the source half of the readonly screen in
/// `propertiesRelatedTo`.
pub fn isReadonlyArrayOrTuple(c: *const Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .array => c.ts.arrayIsReadonly(t),
        .tuple => isReadonlyTuple(c, t),
        else => false,
    };
}

/// tsc's readonly screen in `propertiesRelatedTo`: *"if (!target.target.readonly
/// && (isReadonlyArrayType(source) || isTupleType(source) &&
/// source.target.readonly)) return Ternary.False"*, generalized to a mutable
/// ARRAY target as well — where tsc gets the same answer structurally, because
/// its `ReadonlyArray` interface has no `push`/`pop` and ztsc's readonly array
/// shares Array's member table.
///
/// Reported as TS4104 rather than TS2322/TS2345 (`reportNotAssignable`), which
/// is tsc's `tryElaborateArrayLikeErrors` replacing the head message.
pub fn readonlyMismatch(c: *const Checker, s: TypeId, t: TypeId) bool {
    return isReadonlyArrayOrTuple(c, s) and isMutableArrayOrTuple(c, t);
}

/// What a WRITE through an index (`t[i] = …`, `delete t[i]`) hits when the
/// receiver is a readonly list.
pub const ReadonlyWrite = union(enum) {
    /// A fixed element position, which is a readonly PROPERTY named by its
    /// index: tsc's TS2540 ("Cannot assign to '0' because it is a read-only
    /// property.").
    element: u32,
    /// The readonly numeric INDEX SIGNATURE — a readonly array, or a position
    /// inside a readonly tuple's variable part, or a non-literal index: tsc's
    /// TS2542 ("Index signature in type '…' only permits reading.").
    index_signature,
};

/// The write-site verdict for `obj[idx]`, or null when the receiver is not a
/// readonly list and the write is fine. Mirrors how tsc resolves the write:
/// a numeric literal index inside the fixed part names a readonly property,
/// everything else goes through the readonly index signature.
pub fn readonlyIndexWrite(c: *const Checker, obj: TypeId, idx: TypeId) ?ReadonlyWrite {
    switch (c.ts.kind(obj)) {
        .array => return if (c.ts.arrayIsReadonly(obj)) .index_signature else null,
        .tuple => {
            if (!isReadonlyTuple(c, obj)) return null;
            if (c.ts.kind(idx) == .number_literal) {
                const v = c.ts.numberValue(idx);
                if (v >= 0 and v == @floor(v) and v < 4096) {
                    const iv: u32 = @intFromFloat(v);
                    if (iv < fixedLength(c, obj)) return .{ .element = iv };
                }
            }
            return .index_signature;
        },
        else => return null,
    }
}

/// The tail of tsc's `isTypeDerivedFrom`: *"isArrayType(target) &&
/// !isReadonlyArrayType(target) && isTypeDerivedFrom(source,
/// globalReadonlyArrayType)"* — the NOMINAL `instanceof` test counts a readonly
/// list as derived from a mutable array, where the assignability relation
/// (correctly) refuses it. Answers true only for a pair the readonly screen is
/// the sole objection to.
pub fn readonlyDerivedFrom(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (!readonlyMismatch(c, s, t)) return false;
    const mut = switch (c.ts.kind(s)) {
        .array => try c.ts.makeArray(c.ts.arrayElem(s)),
        .tuple => blk: {
            const len = c.ts.tupleLen(s);
            const elems = try c.scratch().alloc(types.TupleElem, len);
            defer c.scratch().free(elems);
            for (elems, 0..) |*e, i| {
                const src = c.ts.tupleElem(s, @intCast(i));
                e.* = .{ .ty = src.ty, .flags = src.flags & ~types.elem_flag_readonly };
            }
            break :blk try c.ts.makeTupleFlags(elems, c.ts.tupleFlags(s) & ~types.tuple_flag_readonly);
        },
        else => return false,
    };
    return c.isAssignable(mut, t);
}

/// tsc's `isSingleElementGenericTupleType` pair in `structuredTypeRelatedTo`.
/// Returns `true` when the pair is related through the bridge, `false` when
/// the bridge does not apply or its inner question said no — in which case the
/// caller carries on with the ordinary relation, exactly as tsc's `||` chain
/// falls through.
pub fn singleElementBridge(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (soleVariadicElem(c, s)) |arg| {
        // `[...T]` → anything: relate `T` itself, provided the source tuple is
        // not `readonly` (tsc's `isSingleElementGenericTupleType(source) &&
        // !source.target.readonly`) — a `readonly [...T]` would hand out `T`'s
        // mutating members.
        if (!isReadonlyArrayOrTuple(c, s) and try c.isAssignable(arg, t)) return true;
    }
    if (soleVariadicElem(c, t)) |arg| {
        // anything → `[...T]`: legal when the source is (constrained to) a
        // MUTABLE array or tuple — a `readonly` one would gain `push` — OR
        // when the TARGET is itself `readonly`, in which case there is no
        // mutating member to gain and tsc bridges unconditionally
        // (`target.target.readonly || isMutableArrayOrTuple(…)`). The missing
        // disjunct made `r = t` inside `<T extends readonly unknown[]>(t: T, r:
        // readonly [...T])` a spurious TS2322: `T`'s constraint is a READONLY
        // array, so the mutability test declined, and no arm below relates a
        // type parameter to the tuple spelling of itself (`variadicTuples1`).
        if (isReadonlyArrayOrTuple(c, t) or
            isMutableArrayOrTuple(c, try c.transitiveBaseConstraint(s)))
        {
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
    return try c.ts.makeTupleLike(tup, out.items);
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

    // tsc's `combinedFlags & Rest` and `minLength`. `minLength` counts Required
    // AND Variadic elements: a variadic element may stand for zero positions,
    // but the POSITION itself still has to be matched by another variadic, so
    // it costs one against the other side's arity.
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
