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
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Where a member's computed name sits, for the two rules that care whether a
/// reference in it is real EMITTED code evaluated at class-definition time.
///
///   * `Checker.in_type_space_name` — tsc's `markAliasReferenced` gate. An
///     interface's or a type literal's member name is type space, and an ambient
///     class body is emitted nowhere (the same reason `stmts.zig` skips checking
///     an ambient `extends` clause as a value), so neither is a value use.
///   * `Checker.defer_computed_key_tdz` — tsc's
///     `isInAmbientOrTypeNode || isUsedInFunctionOrInstanceProperty` inside
///     `isBlockScopedNameDeclaredBeforeUse`. A forward reference in a computed
///     name is legal in all of those, AND in a class METHOD's name, because
///     walking up from there hits a function-like node. What is left — the only
///     position that reports — is a non-ambient class FIELD's name.
pub const Home = enum { class_body, ambient_class_body, type_space };

/// Check a `.computed_name` node's key expression, reporting TS2464 when the
/// type it produces cannot name a property. Returns the key type so a caller
/// that also needs it (an object literal deciding what member the key
/// contributes) does not check the expression twice.
///
/// Safe to call on a non-`.computed_name` node, which is what lets a member
/// walk hand over whatever it has for a name.
pub fn checkComputedName(c: *Checker, name_node: Node) Error!TypeId {
    if (name_node == null_node or c.nodeTag(name_node) != .computed_name) return types.no_type;
    const expr = c.tree.nodeData(name_node).lhs;
    if (superInNameIsError(c)) try reportSuperInName(c, expr, 0);
    // A super CALL in the name is this file's TS2466, never the call site's
    // TS2337 — tsc's `checkSuperExpression` tests the computed name first.
    // (wave-20 A: `Checker.in_computed_key`.)
    const saved_key = c.in_computed_key;
    c.in_computed_key = true;
    defer c.in_computed_key = saved_key;
    const kt = try c.checkExprCached(expr, types.no_type);
    try report(c, name_node, kt);
    return kt;
}

/// TS2466: a `super` reference written inside a computed property NAME.
///
/// tsc's `getSuperContainer` steps OVER a ComputedPropertyName — it jumps
/// straight past the owning member and keeps walking — so a `super` in a
/// member's NAME never reaches a legal container, however ordinary the member
/// is: `class C extends B { [super.bar()]() {} }` is an error even though the
/// very same `super.bar()` in that method's BODY is fine.
/// `checkSuperExpression` then re-walks for an enclosing computed name and
/// reports this wording in place of the generic "super outside a constructor"
/// one.
///
/// What the skip LANDS ON is the whole question, and it is a question about
/// the member's surroundings, not about the name: `class C extends B { foo() {
/// var o = { [super.bar()]() {} } } }` skips the object method and finds
/// `C.foo`, which IS a legal container, so tsc is silent — as it is for the
/// same shape wrapped in a nested class expression or in an arrow. So the
/// report is confined to the case where the skip can find nothing at all: no
/// enclosing function-like SCOPE anywhere above the name, i.e. a member of a
/// top-level class. Everything nested stays silent, which under-reports the
/// one shape tsc still errors on (a super CALL inside an arrow,
/// `computedPropertyNames30`) and never invents one.
fn superInNameIsError(c: *Checker) bool {
    var s = c.cur_scope;
    while (true) {
        if (c.bind.scope_kinds[s] == .function) return false;
        if (s == binder.file_scope) return true;
        s = c.bind.scope_parents[s];
    }
}

/// Walk the name expression for a `super`, stopping at a nested
/// `function`/class boundary: such a node IS a super container, and
/// `getSuperContainer` returns it before the computed name is ever reached.
fn reportSuperInName(c: *Checker, node: Node, depth: u16) Error!void {
    if (node == null_node or depth > max_name_depth) return;
    switch (c.nodeTag(node)) {
        .super_expr => return c.diagFmt(
            2466,
            c.nodeSpan(node),
            "'super' cannot be referenced in a computed property name.",
            .{},
        ),
        // A `super` written inside one of these has IT as its container, so
        // the computed name never enters the answer.
        .function_expr,
        .function_decl,
        .class_decl,
        .class_method,
        .object_method,
        .class_field,
        => return,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try reportSuperInName(c, child, depth + 1);
}

/// Far above any hand-written key expression; the cap only ever under-reports.
const max_name_depth: u16 = 200;

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
    const saved_tdz = c.defer_computed_key_tdz;
    const saved_in_name = c.in_computed_member_name;
    defer {
        c.in_type_space_name = saved;
        c.defer_computed_key_tdz = saved_tdz;
        c.in_computed_member_name = saved_in_name;
    }
    c.in_type_space_name = home != .class_body;
    c.in_computed_member_name = true;
    for (members) |m| {
        if (m == null_node) continue;
        const key = c.tree.computedKey(m) orelse continue;
        if (c.node_types.contains(c.nodeKey(c.tree.nodeData(key).lhs))) continue;
        // Only a non-ambient class FIELD's name is a use that can be too early.
        c.defer_computed_key_tdz = home != .class_body or c.nodeTag(m) != .class_field;
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
