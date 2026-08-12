//! Nullish and truthiness facts: tsc's `getTypeFacts` / `getTypeWithFacts`
//! family. Stripping `null`/`undefined`/`void` from a type (`!`, `??`, an
//! optional chain link), splitting it into its truthy and falsy parts, and
//! the two "can it be…" queries that decide whether a `||`/`??` result needs
//! a union at all.
//!
//! Every walk here is a union filter, so two comptime-parameterized
//! combinators — `filterUnion` (build the kept constituents) and
//! `unionAnyMember` (does any constituent satisfy…) — carry the union/scalar
//! distinction once, and each predicate is the small function passed to them.

const std = @import("std");
const types = @import("../types.zig");

const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

pub fn removeUndefined(c: *Checker, t: TypeId) Error!TypeId {
    return c.filterUnion(t, struct {
        fn keep(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) != .undefined;
        }
    }.keep);
}

pub fn nonNullable(c: *Checker, t: TypeId) Error!TypeId {
    return nonNullableInner(c, t, false);
}

/// tsc's `getAdjustedTypeWithFacts(t, NEUndefinedOrNull)` is a `mapType`: the
/// `NonNullable<…>` instantiation is applied CONSTITUENT BY CONSTITUENT, not
/// only to a union as a whole. A bare TYPE PARAMETER therefore has to be
/// reachable from inside a union too — a `T` narrowed by
/// `typeof value === 'number'` is `number & T | T`, and stripping nullish from
/// that has to leave the `T` arm as `T & {}`. Filtering the union by KIND
/// alone left it as `T`, so immich's
/// `validate<T>(value: T): NonNullable<T> | null` reported TS2322 on its own
/// `return value ?? null` — but only once a guard had turned the bare
/// parameter into a union.
///
/// The DEFERRED conditional / indexed-access arm deliberately does NOT come
/// along. It marks a whole type whose nullish arm is hidden inside its
/// constraint, and a union has already separated its nullish arms out:
/// marking a constituent there stops the conditional from reducing for every
/// later reader. excalidraw's
/// `rest.startBinding: (T extends "arrow" ? Binding : never) | undefined`
/// read through `?? null` is the shape — five fresh TS2322/TS2345 spelled
/// `{} & T extends "arrow" ? …`.
fn nonNullableInner(c: *Checker, t: TypeId, drop_void: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const k = c.ts.kind(m);
            if (k == .undefined or k == .null or (drop_void and k == .void)) continue;
            const nm = if (k == .type_param) try nonNullableScalar(c, m) else m;
            if (nm != types.never_type) try parts.append(c.scratch(), nm);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const scalar = try nonNullableScalar(c, t);
    if (drop_void and c.ts.kind(scalar) == .void) return types.never_type;
    return scalar;
}

fn nonNullableScalar(c: *Checker, t: TypeId) Error!TypeId {
    // Under strictNullChecks tsc narrows `unknown` as if it were
    // `undefined | null | {}` (`unknownUnionType`), so stripping the nullish
    // arms leaves `{}` — `getNonNullableType(unknown)` is `{}`.
    if (c.ts.kind(t) == .unknown) return types.empty_object_type;
    // A bare type parameter whose constraint may be nullish becomes `T & {}`
    // (tsc's `getNonNullableType` / `NonNullable<T>`). The `& {}` marker
    // keeps the value assignable back to a `T` slot while exposing the
    // constraint's non-nullish apparent members (see the intersection arm of
    // `propOfTypeEx`). A type param already known non-nullish is unchanged.
    if (c.ts.kind(t) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
        if (con == types.no_type or c.containsNullish(con)) {
            return c.ts.makeIntersection(c.scratch(), &.{ t, types.empty_object_type });
        }
        return t;
    }
    // A DEFERRED conditional or indexed access is not a union, so filtering
    // leaves it whole and the nullish constituent hiding in its constraint
    // survives the guard. tsc's `getAdjustedTypeWithFacts` handles exactly
    // this: for `NEUndefined` it maps each constituent that *could* be
    // undefined onto its BASE CONSTRAINT and re-applies the fact there. So
    // `K extends keyof M ? M[K] | undefined : never` guarded by
    // `!== undefined` becomes `M[K]`'s constraint without `undefined`,
    // instead of staying the whole conditional — which is what made
    // `ShapeCache.generateElementShape`'s inferred return keep an
    // `undefined` arm past its own `if (cachedShape !== undefined) return`,
    // and every `.forEach` on the result report an implicit `any`.
    // The `& {}` marker used for a bare type parameter is deliberately not
    // used here: there is no `T` slot to stay assignable to.
    switch (c.ts.kind(t)) {
        .conditional, .index_access => {
            const base = try c.transitiveBaseConstraint(t);
            if (base != t and base != types.no_type and c.containsNullish(base)) {
                return c.ts.makeIntersection(c.scratch(), &.{ t, types.empty_object_type });
            }
        },
        else => {},
    }
    return c.filterUnion(t, struct {
        fn keep(ch: *Checker, m: TypeId) bool {
            const k = ch.ts.kind(m);
            return k != .undefined and k != .null;
        }
    }.keep);
}

/// `??`'s left operand. tsc's `getNonNullableType` is
/// `getTypeWithFacts(t, NEUndefinedOrNull)`, and `VoidFacts` does not carry
/// `NEUndefinedOrNull` — so `void` is filtered out alongside `undefined`
/// and `null`, and `(boolean | void) ?? false` is `boolean`. Scoped to
/// `??`: the same strip inside the general `nonNullable` (which also serves
/// `!` and comparison narrowing) regressed a `void` receiver.
pub fn nonNullableNullish(c: *Checker, t: TypeId) Error!TypeId {
    return nonNullableInner(c, t, true);
}

/// Receiver narrowing for an optional-chain link (`a?.b`, `a?.[i]`, `a?.()`).
/// Beyond null/undefined it also drops `void`: a `.catch(() => {})` /
/// `.then(…)` tail types a promise `T | void`, and tsc lets `x?.prop` reach
/// through the `void` constituent to `T`'s members (the whole chain already
/// yields `… | undefined`). Scoped to the chain sites so the general
/// `nonNullable` used by `??`, `!`, and comparison narrowing is unaffected.
/// A receiver that is *only* nullish/void keeps the plain `nonNullable`
/// result so a bare-`void` access still behaves as before.
pub fn nonNullableChain(c: *Checker, t: TypeId) Error!TypeId {
    const nn = try c.nonNullable(t);
    const dropped = try c.filterUnion(nn, struct {
        fn keep(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) != .void;
        }
    }.keep);
    return if (c.ts.kind(dropped) == .never) nn else dropped;
}

pub fn filterUnion(c: *Checker, t: TypeId, comptime keep: fn (*Checker, TypeId) bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            if (keep(c, m)) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    return if (keep(c, t)) t else types.never_type;
}

pub fn containsNullish(c: *Checker, t: TypeId) bool {
    return c.unionAnyMember(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            const k = ch.ts.kind(m);
            return k == .null or k == .undefined or k == .void or k == .unknown;
        }
    }.f);
}

pub fn containsNull(c: *Checker, t: TypeId) bool {
    return c.unionAnyMember(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) == .null;
        }
    }.f);
}

pub fn containsUndefinedish(c: *Checker, t: TypeId) bool {
    return c.unionAnyMember(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            const k = ch.ts.kind(m);
            return k == .undefined or k == .void;
        }
    }.f);
}

pub fn unionAnyMember(c: *Checker, t: TypeId, comptime f: fn (*Checker, TypeId) bool) bool {
    if (c.ts.kind(t) == .union_type) {
        for (0..c.ts.memberCount(t)) |i| {
            if (f(c, c.ts.memberAt(t, i))) return true;
        }
        return false;
    }
    return f(c, t);
}

/// The definitely-truthy part of `t` (removes null/undefined/false/
/// falsy literals; boolean -> true; object types kept).
pub fn getTruthyPart(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const p = try c.getTruthyPart(m);
            if (p != types.never_type) try parts.append(c.scratch(), p);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const s = &c.ts;
    return switch (s.kind(t)) {
        .null, .undefined, .void, .bool_false => types.never_type,
        .boolean => types.true_type,
        // Under strictNullChecks tsc narrows `unknown` as if it were
        // `undefined | null | {}` (`unknownUnionType`) and re-spells the full
        // union `unknown` afterwards, so a guard that removes the nullish
        // arms leaves `{}` — which carries `Object`'s apparent members.
        // `if (!e) return; e.toString()` on an `unknown` catch value is the
        // idiom that needs it.
        .unknown => types.empty_object_type,
        // A truthy naked type parameter is `T & {}` — tsc's
        // `getAdjustedTypeWithFacts` maps the `Truthy` facts over the type
        // and replaces any constituent that can be nullish with
        // `NonNullable<…>`. Without it `<T extends P | null>(p: T)` guarded
        // by `if (p)` still sees the nullish constraint and reports every
        // member access on it. `nonNullable` builds the same marker the
        // intersection arm of `propOfTypeEx` already consumes.
        .type_param => try c.nonNullable(t),
        .string_literal => if (c.atomText(s.literalAtom(t)).len == 0) types.never_type else t,
        .number_literal, .number_literal_fresh => if (s.numberValue(t) == 0) types.never_type else t,
        .bigint_literal => blk: {
            const text = c.atomText(s.literalAtom(t));
            break :blk if (isZeroBigInt(text)) types.never_type else t;
        },
        else => t,
    };
}

/// The definitely-falsy part of `t` (tsc's `A && B` left contribution
/// and falsy-branch narrowing): string -> "", number -> 0, boolean ->
/// false, bigint -> 0n; object types contribute nothing.
pub fn getFalsyPart(c: *Checker, t: TypeId, for_narrowing: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const p = try c.getFalsyPart(m, for_narrowing);
            if (p != types.never_type) try parts.append(c.scratch(), p);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const s = &c.ts;
    return switch (s.kind(t)) {
        .null, .undefined, .void, .bool_false => t,
        .boolean => types.false_type,
        .bool_true => types.never_type,
        .any, .err => types.any_type,
        .unknown => types.unknown_type,
        .string => if (for_narrowing) types.string_type else try s.makeStringLiteral(try c.atom(""), false),
        .number => if (for_narrowing) types.number_type else try s.makeNumberLiteral(0, false),
        .bigint => if (for_narrowing) types.bigint_type else try s.makeBigIntLiteral(try c.atom("0n"), false),
        .string_literal => if (c.atomText(s.literalAtom(t)).len == 0) t else types.never_type,
        .number_literal, .number_literal_fresh => if (s.numberValue(t) == 0) t else types.never_type,
        .bigint_literal => if (isZeroBigInt(c.atomText(s.literalAtom(t)))) t else types.never_type,
        else => types.never_type, // objects, functions, tuples, refs...
    };
}

/// Can a value of `t` be falsy? tsc asks this (`getTypeFacts(left,
/// TypeFacts.Falsy)`) before building the `||` result: when the answer is
/// no the right operand is unreachable and the result is just the left
/// operand's type, with no union and no reduction. Undecidable shapes —
/// `any`, a bare type parameter, an unresolved conditional — answer "yes",
/// which keeps the union ztsc built before.
pub fn canBeFalsy(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true;
    const s = &c.ts;
    switch (s.kind(t)) {
        .union_type => {
            for (try c.memberList(t)) |m| {
                if (try c.canBeFalsy(m, depth + 1)) return true;
            }
            return false;
        },
        // One always-truthy constituent makes the whole intersection so.
        .intersection => {
            for (try c.memberList(t)) |m| {
                if (!try c.canBeFalsy(m, depth + 1)) return false;
            }
            return true;
        },
        .object, .array, .tuple, .function, .overloads, .class_value, .bool_true, .symbol, .unique_symbol, .object_keyword => return false,
        .string_literal => return c.atomText(s.literalAtom(t)).len == 0,
        .number_literal, .number_literal_fresh => return s.numberValue(t) == 0,
        .bigint_literal => return isZeroBigInt(c.atomText(s.literalAtom(t))),
        .ref, .this_type => {
            const r = try c.resolveStructural(t);
            if (r == t) return true;
            return c.canBeFalsy(r, depth + 1);
        },
        else => return true,
    }
}

/// Can a value of `t` be `null` or `undefined`? The `??` counterpart of
/// `canBeFalsy` (tsc's `getTypeFacts(left, TypeFacts.EQUndefinedOrNull)`):
/// `a ?? b` is just `a`'s type when the answer is no. `void` counts — it
/// admits `undefined` — and undecidable shapes again answer "yes".
pub fn canBeNullish(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true;
    switch (c.ts.kind(t)) {
        .null, .undefined, .void, .any, .unknown, .err, .type_param => return true,
        .union_type, .intersection => {
            for (try c.memberList(t)) |m| {
                if (try c.canBeNullish(m, depth + 1)) return true;
            }
            return false;
        },
        .ref, .this_type => {
            const r = try c.resolveStructural(t);
            if (r == t) return true;
            return c.canBeNullish(r, depth + 1);
        },
        .conditional, .infer_var, .mapped_param => return true,
        else => return false,
    }
}

pub fn isZeroBigInt(text: []const u8) bool {
    for (text) |ch| {
        if (ch >= '1' and ch <= '9') return false;
    }
    return true;
}
