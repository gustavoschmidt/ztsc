//! tsc's `getNarrowableTypeForReference`: the *declared* type a reference hands
//! to control-flow analysis.
//!
//! A reference whose type is (or contains) an instantiable type with a UNION
//! constraint is handed to the flow walk as its constraint instead of as the
//! bare type variable, so that a guard has union constituents to filter:
//!
//!     type X = { kind: 'a', a: string } | { kind: 'b', b: string };
//!     function f<T extends X>(v: T) {
//!         if (v.kind === 'a') v.a;   // `v` narrows to `{ kind:'a', a:string }`
//!     }
//!
//! Without the substitution `v` stays `T` through the guard, the narrowers have
//! nothing to filter, and every discriminated read on it misses (TS2339).
//!
//! tsc only substitutes where the constraint is what decides the outcome
//! anyway: a CONSTRAINT POSITION (the apparent type is taken there regardless —
//! a property-access or element-access receiver, or a call/`new` callee), or a
//! reference with a non-generic contextual type (assignability is then decided
//! against the constraint). `isConstraintPosition` is a question about the
//! reference's PARENT, and ztsc's AST has no parent links, so the enclosing
//! expression *announces* it on `Checker.constraint_pos` before it types the
//! reference — see `ConstraintPos`.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const assign = @import("assign.zig");
const isInstantiableKind = @import("expr.zig").isInstantiableKind;

/// The reference the *enclosing* expression has put in a constraint position,
/// as a `nodeKey` (0 = none), announced by that expression around the check of
/// the reference itself. This is an INPUT pushed down one level, not a result
/// smuggled back up: the answer is a pure function of the node's parent, so it
/// is stable for the node and the per-node type memo cannot hold a reading
/// taken under a different one.
///
/// `index_expr` is the element-access exception: in `obj[k]`, `obj` is NOT in a
/// constraint position when `obj` is generic with a non-nullable constraint and
/// `k` is a generic index type, because the access is then meant to stay
/// `T[K]`. The test needs `k`'s type, which the enclosing access has not
/// computed yet when it announces, so the node travels instead and only the
/// receivers that reach the exception pay for typing it.
pub const ConstraintPos = struct {
    node: u64 = 0,
    index_expr: Node = null_node,
};

/// tsc's `getNarrowableTypeForReference`. `node` is the reference (an
/// identifier, property access or element access), `declared` the type it would
/// hand the flow walk, `ctx` its contextual type (`no_type` = none).
pub fn narrowableRefType(c: *Checker, node: Node, declared: TypeId, ctx: TypeId) Error!TypeId {
    // The cheap syntactic screen first: nothing to substitute unless the type
    // really does carry an instantiable with a union constraint, and that walk
    // is itself gated on the type having an instantiable part at all.
    if (!try someType(c, declared, genericWithUnionConstraint)) return declared;
    if (!try substitutes(c, node, declared, ctx)) return declared;
    return substituteConstraints(c, declared);
}

fn substitutes(c: *Checker, node: Node, declared: TypeId, ctx: TypeId) Error!bool {
    if (try inConstraintPosition(c, node, declared)) return true;
    return contextualTypeIsConcrete(c, ctx);
}

/// tsc's `isConstraintPosition`, answered from the enclosing expression's
/// announcement rather than from a parent pointer (see `ConstraintPos`).
fn inConstraintPosition(c: *Checker, node: Node, declared: TypeId) Error!bool {
    const cp = c.constraint_pos;
    if (cp.node == 0 or cp.node != c.nodeKey(node)) return false;
    if (cp.index_expr == null_node) return true;
    if (!try someType(c, declared, genericWithoutNullableConstraint)) return true;
    const idx_t = try c.checkExprCached(cp.index_expr, types.no_type);
    return !try isGenericType(c, idx_t);
}

/// tsc's `hasContextualTypeWithNoGenericTypes` minus the node-kind test, which
/// every caller already satisfies: the reference has a contextual type, and
/// that type contains no top-level instantiable — so assignability against it
/// is decided by the constraint, and narrowing the constraint is what tsc's
/// comment calls "an opportunity to narrow it further".
fn contextualTypeIsConcrete(c: *Checker, ctx: TypeId) Error!bool {
    if (ctx == types.no_type) return false;
    // tsc's `!(checkMode & CheckMode.Inferential)`: while a call is inferring
    // its type arguments, an argument must keep its type VARIABLE — handing the
    // constraint to `inferTypeArgs` instead would infer the constraint. ztsc's
    // marker for "some call is inferring right now" is `infer_active`.
    if (c.infer_active.items.len != 0) return false;
    return !try isGenericType(c, ctx);
}

/// tsc's `someType(type, pred)`: `pred` on each constituent of a union, or on
/// the type itself.
fn someType(c: *Checker, t: TypeId, comptime pred: fn (*Checker, TypeId) Error!bool) Error!bool {
    if (c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| if (try pred(c, m)) return true;
        return false;
    }
    return pred(c, t);
}

/// tsc's `isGenericTypeWithUnionConstraint`.
fn genericWithUnionConstraint(c: *Checker, t: TypeId) Error!bool {
    if (c.ts.kind(t) == .intersection) {
        for (try c.memberList(t)) |m| if (try genericWithUnionConstraint(c, m)) return true;
        return false;
    }
    if (!isInstantiableKind(c.ts.kind(t))) return false;
    return switch (c.ts.kind(try constraintOrSelf(c, t))) {
        // tsc: `getBaseConstraintOrType(t).flags & (Nullable | Union)`.
        .union_type, .undefined, .null => true,
        else => false,
    };
}

/// tsc's `isGenericTypeWithoutNullableConstraint`.
fn genericWithoutNullableConstraint(c: *Checker, t: TypeId) Error!bool {
    if (c.ts.kind(t) == .intersection) {
        for (try c.memberList(t)) |m| if (try genericWithoutNullableConstraint(c, m)) return true;
        return false;
    }
    if (!isInstantiableKind(c.ts.kind(t))) return false;
    return !c.containsNullish(try constraintOrSelf(c, t));
}

/// tsc's `isGenericType` (`IsGenericObjectType | IsGenericIndexType`): does `t`
/// contain a type the checker must keep deferred — an instantiable, or a
/// mapped type over one? A contextual type that does decides nothing about
/// assignability yet, so a reference under it keeps its type variable.
fn isGenericType(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .union_type, .intersection => {
            for (try c.memberList(t)) |m| if (try isGenericType(c, m)) return true;
            return false;
        },
        // tsc's `isGenericMappedType`: a mapped type is deferred until its
        // constraint is known. ztsc keeps an unresolved one as `.mapped`.
        .mapped, .mapped_param, .this_type => true,
        else => isInstantiableKind(c.ts.kind(t)),
    };
}

/// tsc's `mapType(t, getBaseConstraintOrType)`: the type seen through type-
/// parameter constraints, distributed over a union, so
///
///     function f<T extends { kind: 'A', payload: number }
///                        | { kind: 'B', payload: string }>({ kind, payload }: T)
///
/// destructures the CONSTRAINT's union and a guard on `kind` still narrows
/// `payload`. Without it the type is the bare `T`, "not a union", and every
/// rule that needs constituents declines (`dependentDestructuredVariables`
/// f13/f14).
///
/// Only an INSTANTIABLE constituent is replaced — tsc's
/// `getBaseConstraintOfType` answers `undefined` for a plain object type, and
/// ztsc's `baseConstraintOf` would otherwise substitute the type parameters
/// nested INSIDE one (`A<T> | B<T>` becoming `A<con> | B<con>`), which is a
/// different type than the reference is written against.
pub fn substituteConstraints(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return constraintOrSelf(c, t);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    var changed = false;
    for (try c.memberList(t)) |m| {
        const cm = try constraintOrSelf(c, m);
        if (cm != m) changed = true;
        try parts.append(c.scratch(), cm);
    }
    if (!changed) return t;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// tsc's `getBaseConstraintOrType`, resolved for structural inspection.
///
/// A deferred CONDITIONAL goes through `deferredDefaultConstraint` (tsc's
/// `getDefaultConstraintOfConditionalType`), not `baseConstraintOf`: the latter
/// instantiates the whole type with every parameter's constraint and therefore
/// *evaluates* the conditional, picking one branch. tsc's base constraint of a
/// conditional is the union of BOTH branches, which is what decides whether the
/// reference has union constituents to filter at all —
/// `T["type"] extends keyof S ? S[T["type"]] | undefined : unknown` is
/// `unknown` under that reading (nothing to substitute) and a `… | undefined`
/// union under the evaluating one, which invented a TS18048 on every read of it
/// (`narrowing/084`).
///
/// tsc's `computeBaseConstraint` for a conditional asks
/// `getConstraintOfDistributiveConditionalType` FIRST and only falls back to the
/// branch union. The distributive reading is the branch union with the branches
/// the check parameter's own bound rules out dropped, so
/// `ZeroOf<T>` (`T extends null ? null : … : never`) under `T extends {}` is
/// `"" | 0 | false` and not `"" | 0 | false | null | undefined` — the wider
/// reading manufactured a TS2322 on every `let t: "" | 0 | false = x`
/// (`distributiveConditionalTypeConstraints`, `conditionalTypes1` f21).
fn constraintOrSelf(c: *Checker, t: TypeId) Error!TypeId {
    if (!isInstantiableKind(c.ts.kind(t))) return t;
    if (c.ts.kind(t) == .conditional) {
        if (try assign.distributiveConstraint(c, t)) |dc| return c.resolveStructural(dc);
    }
    // tsc's `computeBaseConstraint` answers `keyofConstraintType` — `string |
    // number | symbol` — for an INDEX type, not `keyof <constraint>`: the keys
    // of an unknown object are only known to be property keys. It is what makes
    // `function f<T, K extends keyof T>(k: K) { k.toUpperCase() }` the TS2339
    // tsc reports, and `keyof U` (`U extends Obs`) unassignable to `keyof Obs`
    // (`indexed/025`). ztsc's `baseConstraintOf` instead instantiates `U` with
    // its constraint and answers the much narrower `keyof Obs`.
    if (c.ts.kind(t) == .keyof_op) return c.propertyKeyType();
    return c.resolveStructural(try c.deferredDefaultConstraint(t, 0));
}
