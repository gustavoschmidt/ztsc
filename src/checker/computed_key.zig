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

/// Is a member's computed name emitted code (a class body, an object literal)
/// or type space only (an interface, a type literal)? The distinction is
/// `Checker.in_type_space_name`'s.
pub const Home = enum { emitted, type_space };

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

/// The computed NAMES of a class body's or an interface's members — tsc's
/// `checkComputedPropertyName`, reached from the declaration walk so it runs in
/// the file that owns the declaration and for an unreferenced container too.
///
/// The key expression is where a computed member's own diagnostics live: an
/// unresolved key is TS2304 (`class C { [nosuch]: number }`), and a key whose
/// type cannot name a property is TS2464. Neither was reachable before the
/// parser retained the expression — the key was a token, resolved by TEXT, and a
/// failed resolution fell back to a name placeholder in silence.
///
/// tsc guards the whole thing on `getNodeLinks(node.expression).resolvedType`
/// being unset, i.e. on the expression not having been checked yet; ztsc's
/// equivalent is the node-type memo, which keeps a second walk over the same
/// members from doubling the reports.
///
/// `home` says whether the member name is EMITTED code — see
/// `Checker.in_type_space_name` for the one diagnostic that turns on.
pub fn checkMemberNames(c: *Checker, members: []const Node, home: Home) Error!void {
    // Almost every file has no computed member name at all.
    if (c.tree.computed_keys.len == 0) return;
    const saved = c.in_type_space_name;
    defer c.in_type_space_name = saved;
    c.in_type_space_name = home == .type_space;
    for (members) |m| {
        if (m == null_node) continue;
        const key = c.tree.computedKey(m) orelse continue;
        if (c.node_types.contains(c.nodeKey(c.tree.nodeData(key).lhs))) continue;
        _ = try checkComputedName(c, key);
    }
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
