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
const intern = @import("../intern.zig");
const numeric_lit = @import("../numeric_lit.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
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
/// `on_class` says the name belongs to a CLASS member — the one home in which
/// a `this` reference inside it is TS2465 (see `IllegalRefs`). An object
/// literal's name passes `false`, and so does an interface's or type literal's.
pub fn checkComputedName(c: *Checker, name_node: Node, on_class: bool) Error!TypeId {
    if (name_node == null_node or c.nodeTag(name_node) != .computed_name) return types.no_type;
    const expr = c.tree.nodeData(name_node).lhs;
    const want: IllegalRefs = .{ .super = superInNameIsError(c), .this = on_class };
    if (want.super or want.this) try reportIllegalRefs(c, expr, want, 0);
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

/// Which of the two keyword references a walk of the name expression should
/// refuse. They share one traversal because they share the boundary exactly:
/// both `getSuperContainer` and `getThisContainer` stop at the same set of
/// nodes on the way out, and step over the same ones.
const IllegalRefs = struct {
    /// TS2466 — see `superInNameIsError` for when this is on.
    super: bool,
    /// TS2465: `this` cannot be referenced in a computed property name.
    ///
    /// tsc's `getThisContainer(node, includeArrowFunctions: true,
    /// includeClassComputedPropertyName: true)` makes a ComputedPropertyName a
    /// `this` container in its own right — but ONLY when its grandparent is
    /// class-like. `checkThisExpression` then reports on that container instead
    /// of switching on the ordinary ones.
    ///
    /// So it is the class-ness of the home that decides, not the name: an
    /// interface's or a type literal's computed name steps over (its `this` is
    /// `typeof globalThis`, and the shape reports TS7017 instead), while an
    /// AMBIENT class body reports exactly like a concrete one.
    this: bool,
};

/// Walk the name expression for an illegal `super`/`this`, stopping at a nested
/// `function`/class boundary: such a node IS the reference's container, and the
/// `getSuperContainer` / `getThisContainer` walk returns it before the computed
/// name is ever reached.
///
/// An ARROW is deliberately absent from the boundary set — it has no `this` or
/// `super` of its own, so `class C { [(() => this.bar())()]() {} }` reports —
/// and so is the OBJECT LITERAL, which lets the walk reach a `this` nested in
/// an inner object literal's own computed name
/// (`[{ [this.bar()]: 1 }[0]]() {}`, `computedPropertyNames23`). A nested CLASS
/// is a boundary for the opposite reason: its members' names get their own
/// `checkMemberNames` pass, so descending would report them twice.
fn reportIllegalRefs(c: *Checker, node: Node, want: IllegalRefs, depth: u16) Error!void {
    if (node == null_node or depth > max_name_depth) return;
    switch (c.nodeTag(node)) {
        .super_expr => if (want.super) return c.diagFmt(
            2466,
            c.nodeSpan(node),
            "'super' cannot be referenced in a computed property name.",
            .{},
        ),
        .this_expr => if (want.this) return c.diagFmt(
            2465,
            c.nodeSpan(node),
            "'this' cannot be referenced in a computed property name.",
            .{},
        ),
        // A reference written inside one of these has IT as its container, so
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
    while (it.next()) |child| try reportIllegalRefs(c, child, want, depth + 1);
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
        _ = try checkComputedName(c, key, home != .type_space);
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

/// The static member name a computed key `[expr]` declares — tsc's
/// `isLateBindableName` followed by `getLateBoundNameFromType`. A computed name
/// is late-BINDABLE when its type is a string literal, a numeric literal or a
/// unique symbol; every other key (a `string`-typed one, a template type, an
/// `any`) is dynamic and declares no member at all.
///
/// Two of ztsc's spellings sit alongside the type test, because ztsc names the
/// member syntactically where tsc names it from a resolved symbol:
///
///   * `[Symbol.iterator]` is recognized from the SYNTAX (`wellKnownKeyOfExpr`)
///     and keyed `__@iterator`, the way the binder's `memberKey` and the
///     element access in `indexChainInner` both key it. That it is asked BEFORE
///     the general `unique symbol` spelling is load-bearing: in the real lib
///     `Symbol.iterator` IS a `unique symbol`, so keyed by its nominal
///     `__@u<id>` instead, `{ [Symbol.iterator]: 0 }` declared a member no
///     reader of `o[Symbol.iterator]` could find (`symbolProperty18`);
///   * a QUALIFIED enum-member key (`[Breed.X]`) has a value the checker leaves
///     unknown for a computed member, so it is keyed by the same text-derived
///     `__@k$<obj>.<member>` placeholder the binder gives the declaration side.
///
/// `key_type` is the key expression's already-checked type, passed in rather
/// than recomputed: a caller reading it out of the node-type memo then never
/// re-enters the expression walk, and so never re-reports TS2464 on the key.
pub fn lateBoundName(c: *Checker, key_expr: Node, key_type: TypeId) Error!?Atom {
    if (c.wellKnownKeyOfExpr(key_expr)) |wk| return try c.atom(wk);
    // The syntactic recognizer above needs no type, and is the only arm that
    // can answer for a key the checker never typed: a METHOD's computed name is
    // not an expression tsc checks (`symbolProperty1`), so a caller reading the
    // node-type memo has nothing for it. Everything below is a question about
    // the type, and has none to ask.
    if (key_type == types.no_type or key_type == types.error_type) return null;
    if (try c.uniqueSymAtom(key_type)) |a| return a;
    const rk = try c.resolveStructural(key_type);
    switch (c.ts.kind(rk)) {
        .string_literal => return c.ts.dataA(rk),
        .number_literal, .number_literal_fresh => {
            var buf: [numeric_lit.max_name]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            numeric_lit.write(&w, c.ts.numberValue(rk)) catch return null;
            // Stack buffer: intern a copy, never keep the slice.
            return try c.internText(w.buffered());
        },
        .enum_type => {
            if (c.nodeTag(key_expr) != .member_expr) return null;
            const member_tok = c.tree.nodeData(key_expr).rhs;
            return try c.computedSymKey(
                member_tok,
                ast.Flags.computed_sym | ast.Flags.computed_sym_qual,
                c.cur_scope,
            );
        },
        else => return null,
    }
}

/// A computed name AS WRITTEN, brackets included — tsc's `symbolToString` of a
/// late-bound property, which is `getTextOfNode` on the declaration's name
/// (`'[Symbol.toPrimitive]'`, `'["zzz"]'`, `'[E.A]'`), never the synthetic atom
/// the member is keyed by.
///
/// The node's own span ends at the key EXPRESSION, so the closing bracket is
/// scanned for. Bounded: a name node the parser recovered from may have no `]`
/// at all, and the un-terminated text is a better answer than a runaway slice.
pub fn nameText(c: *const Checker, name_node: Node) []const u8 {
    const sp = c.nodeSpan(name_node);
    const limit = @min(c.src.len, sp.end + max_bracket_scan);
    var end = sp.end;
    while (end < limit and c.src[end] != ']') end += 1;
    if (end < limit) end += 1 else return c.src[sp.start..sp.end];
    return c.src[sp.start..end];
}

/// How far past a computed name's key expression its `]` is looked for. Only
/// trivia can sit in between, and a comment is the only trivia with any length.
const max_bracket_scan = 4096;

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
