//! Which grammar diagnostic a `@dec` earns from WHAT it decorates.
//!
//! This is tsc's `nodeCanBeDecorated` plus the two wordings `checkGrammarModifiers`
//! special-cases around it. The whole rule is syntactic — it never asks a type
//! question — so it belongs in the parser, next to the decorator run it judges.
//!
//! The shape of the rule is that a decorator is only ever valid on a CLASS or on
//! a member of one, and that the two decorator dialects disagree about which
//! classes and which members:
//!
//!   * legacy (`experimentalDecorators: true`) decorates a class DECLARATION and
//!     the members of one — never a class expression, never a `#private` name —
//!     and it alone decorates parameters;
//!   * TC39 standard decorators decorate any class-like, including an
//!     expression, and reject an `abstract` or `declare` field and every
//!     parameter.
//!
//! Both reject a constructor, a static block, an index signature, and every
//! declaration that is not a class at all (`@dec var x`, `@dec interface I`,
//! `@dec import X = M.X`, …) — the seven `decoratorOn*` conformance cases.
//!
//! Measured against tsgo 7.0.2 rather than read off the source: `@dec export
//! class C {}` and `@dec declare class C {}` are both silent (the decorator
//! attaches to the ClassDeclaration behind the modifiers), a run of several
//! decorators reports ONCE on the first `@`, and a `this` parameter answers
//! TS1433 even where TS1206 would otherwise apply.

const Code = @import("diagnostics.zig").Code;

/// What sits behind the decorator run.
pub const Kind = enum {
    /// `@dec class C {}` in statement position, modifiers and all.
    class_decl,
    /// `@dec class {}` in expression position.
    class_expr,
    /// A class field, including an `accessor` one.
    property,
    /// A class method. `has_body` separates an implementation from an overload
    /// signature / an `abstract` or ambient method.
    method,
    /// `get x()` / `set x(v)`.
    accessor,
    /// `constructor() {}` — decoratable in neither dialect.
    constructor,
    /// A parameter of a function-like.
    parameter,
    /// Everything else a decorator may syntactically precede: `var`, `enum`,
    /// `interface`, `type`, `namespace`, `import X = …`, `function`, a
    /// `static {}` block, a class index signature.
    other,
};

/// Everything `nodeCanBeDecorated` asks about the decorated node and its
/// parent, and nothing else.
pub const Site = struct {
    kind: Kind,
    /// tsc's `isNamedDeclaration(node) && isPrivateIdentifier(node.name)`: a
    /// `#x` member. Legacy decorators reject it whatever the member is.
    private_name: bool = false,
    /// The `abstract` modifier on a field (standard decorators only).
    abstract: bool = false,
    /// The `declare` modifier on a field (standard decorators only) — tsc's
    /// `hasAmbientModifier`, the modifier itself and not an ambient context.
    declare: bool = false,
    /// Does the method / accessor have a body? For a `.parameter`, does its
    /// OWNER have one.
    has_body: bool = false,
    /// Is the enclosing class a class DECLARATION? False inside a class
    /// expression, which legacy decorators reject member by member.
    in_class_decl: bool = false,
    /// `.parameter` only: the owner is a constructor, a method or a set
    /// accessor — tsc's list of parameter-decorator hosts.
    param_owner_decoratable: bool = false,
    /// `.parameter` only: the parameter is `this`.
    this_param: bool = false,
    /// An accessor that is the SECOND of its name in the class body, where the
    /// first carries modifiers or decorators of its own (legacy only).
    second_accessor_of_modified_pair: bool = false,
};

/// The diagnostic the run earns, reported on its FIRST `@`, or null when the
/// decorator is legal there.
pub fn diagnose(legacy: bool, s: Site) ?Code {
    // A `this` parameter answers first, and with its own wording, even in the
    // dialect that rejects every parameter decorator outright.
    if (s.kind == .parameter and s.this_param) return .decorator_on_this_param;
    if (!canBeDecorated(legacy, s)) {
        // A method with no body is an overload, and tsc says so instead of the
        // generic wording.
        return if (s.kind == .method and !s.has_body)
            .decorator_on_method_overload
        else
            .decorator_not_valid_here;
    }
    if (legacy and s.kind == .accessor and s.second_accessor_of_modified_pair)
        return .decorator_on_second_accessor;
    return null;
}

fn canBeDecorated(legacy: bool, s: Site) bool {
    if (legacy and s.private_name) return false;
    return switch (s.kind) {
        .class_decl => true,
        .class_expr => !legacy,
        .property => if (legacy) s.in_class_decl else !s.abstract and !s.declare,
        .method, .accessor => s.has_body and (!legacy or s.in_class_decl),
        .parameter => legacy and s.param_owner_decoratable and s.has_body and
            !s.this_param and s.in_class_decl,
        .constructor, .other => false,
    };
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;

test "a decorator is only ever valid on a class or a member of one" {
    for ([_]bool{ false, true }) |legacy| {
        try expectEqual(@as(?Code, null), diagnose(legacy, .{ .kind = .class_decl }));
        try expectEqual(
            @as(?Code, .decorator_not_valid_here),
            diagnose(legacy, .{ .kind = .other }),
        );
        try expectEqual(
            @as(?Code, .decorator_not_valid_here),
            diagnose(legacy, .{ .kind = .constructor, .has_body = true, .in_class_decl = true }),
        );
    }
}

test "legacy decorators reject a class expression and everything inside one" {
    const expr_field: Site = .{ .kind = .property, .in_class_decl = false };
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(true, expr_field));
    try expectEqual(@as(?Code, null), diagnose(false, expr_field));

    const expr_method: Site = .{ .kind = .method, .has_body = true, .in_class_decl = false };
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(true, expr_method));
    try expectEqual(@as(?Code, null), diagnose(false, expr_method));

    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(true, .{ .kind = .class_expr }));
    try expectEqual(@as(?Code, null), diagnose(false, .{ .kind = .class_expr }));
}

test "standard decorators reject an abstract or declare field, legacy does not" {
    const abstract_field: Site = .{ .kind = .property, .abstract = true, .in_class_decl = true };
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(false, abstract_field));
    try expectEqual(@as(?Code, null), diagnose(true, abstract_field));

    const declared_field: Site = .{ .kind = .property, .declare = true, .in_class_decl = true };
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(false, declared_field));
    try expectEqual(@as(?Code, null), diagnose(true, declared_field));
}

test "a bodiless method is an overload, and says so" {
    const overload: Site = .{ .kind = .method, .has_body = false, .in_class_decl = true };
    try expectEqual(@as(?Code, .decorator_on_method_overload), diagnose(false, overload));
    try expectEqual(@as(?Code, .decorator_on_method_overload), diagnose(true, overload));
    // An accessor with no body keeps the generic wording.
    try expectEqual(
        @as(?Code, .decorator_not_valid_here),
        diagnose(false, .{ .kind = .accessor, .has_body = false, .in_class_decl = true }),
    );
}

test "a private name is legal under standard decorators only" {
    const priv: Site = .{ .kind = .property, .private_name = true, .in_class_decl = true };
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(true, priv));
    try expectEqual(@as(?Code, null), diagnose(false, priv));
}

test "a this parameter answers TS1433 in both dialects" {
    const this_param: Site = .{
        .kind = .parameter,
        .this_param = true,
        .param_owner_decoratable = true,
        .has_body = true,
        .in_class_decl = true,
    };
    try expectEqual(@as(?Code, .decorator_on_this_param), diagnose(true, this_param));
    try expectEqual(@as(?Code, .decorator_on_this_param), diagnose(false, this_param));
}

test "a parameter decorator belongs to legacy decorators alone" {
    const ok: Site = .{
        .kind = .parameter,
        .param_owner_decoratable = true,
        .has_body = true,
        .in_class_decl = true,
    };
    try expectEqual(@as(?Code, null), diagnose(true, ok));
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(false, ok));
    // A plain function's parameter has no decoratable owner.
    var free = ok;
    free.param_owner_decoratable = false;
    try expectEqual(@as(?Code, .decorator_not_valid_here), diagnose(true, free));
}

test "the second of a decorated get/set pair is TS1207 under legacy decorators" {
    const second: Site = .{
        .kind = .accessor,
        .has_body = true,
        .in_class_decl = true,
        .second_accessor_of_modified_pair = true,
    };
    try expectEqual(@as(?Code, .decorator_on_second_accessor), diagnose(true, second));
    try expectEqual(@as(?Code, null), diagnose(false, second));
}
