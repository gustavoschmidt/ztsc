//! TS2464: what a computed property NAME is allowed to be.
//!
//! A computed key has to name a property, and the three things that can name
//! one are a string, a number and a symbol — so tsc's
//! `checkComputedPropertyName` asks whether the key's type is assignable to
//! `string | number | symbol`, with `any` and `never` sliding through as they
//! do everywhere else.
//!
//! The admissible/inadmissible boundary was measured against tsgo 7.0.2 over
//! sixteen key types. Through: `string`, `number`, `symbol`, `any`, `never`, a
//! `unique symbol`, an enum, a template-literal type, `number | string`, and
//! `K extends keyof T`. Reported: `unknown`, `void`, `null`, `undefined`,
//! `boolean`, `bigint`, `object`, a function type, an array type, an
//! unconstrained `T`, `number | number[]`, `string | boolean`, and
//! `typeof Symbol` (the constructor object, not a symbol).
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Check a `.computed_name` node's key expression, reporting TS2464 when the
/// type it produces cannot name a property. Returns the key type so a caller
/// that also needs it (an object literal deciding what member the key
/// contributes) does not check the expression twice.
///
/// Safe to call on a non-`.computed_name` node, which is what lets a member
/// walk hand over whatever it has for a name.
pub fn checkComputedName(c: *Checker, name_node: Node) Error!TypeId {
    if (name_node == null_node or c.nodeTag(name_node) != .computed_name) return types.no_type;
    const kt = try c.checkExprCached(c.tree.nodeData(name_node).lhs, types.no_type);
    try report(c, name_node, kt);
    return kt;
}

/// TS2464 for a key whose type the caller already has. tsc anchors the report
/// on the whole `[…]` name, so the span starts at the `[`.
pub fn report(c: *Checker, name_node: Node, kt: TypeId) Error!void {
    if (try admissible(c, kt)) return;
    try c.diagFmt(
        2464,
        c.nodeSpan(name_node),
        "A computed property name must be of type 'string', 'number', 'symbol', or 'any'.",
        .{},
    );
}

/// Can a value of type `kt` name a property?
pub fn admissible(c: *Checker, kt: TypeId) Error!bool {
    // An unresolved key (`{ [nosuch]: 1 }`) is `error`, which is assignable to
    // everything — tsc reports the TS2304 and stops, with no TS2464 behind it.
    if (kt == types.error_type or kt == types.no_type) return true;
    // tsc tests `TypeFlags.Nullable` SEPARATELY from assignability, which is
    // what keeps a `null` or `undefined` key reported under
    // `strictNullChecks: false`, where it would otherwise be assignable to
    // `string`. `void` and `unknown` fail the assignability test anyway;
    // reading them here too only reaches the same answer sooner.
    if (c.containsNullish(kt)) return false;
    return c.isAssignable(kt, try stringNumberSymbol(c));
}

/// `string | number | symbol` — tsc's `stringNumberSymbolType`. Built on demand
/// rather than cached: the only callers are computed keys, which are rare, and
/// the union constructor interns.
fn stringNumberSymbol(c: *Checker) Error!TypeId {
    return c.makeUnion2(types.string_type, try c.makeUnion2(types.number_type, types.symbol_type));
}
