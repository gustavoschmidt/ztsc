//! Decorator checking, both dialects: the standard `(value, context)` call
//! shape and the legacy `experimentalDecorators`
//! `(target, propertyKey, descriptor)` one, plus the lib-interface lookups
//! (`Class*DecoratorContext`, `TypedPropertyDescriptor`) they resolve
//! against. Every failure here is a TS1238/1240/1241.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const elaborate = @import("elaborate.zig");
const indentChain = @import("stmts.zig").indentChain;
const contextSigForFnExpr = @import("signatures.zig").contextSigForFnExpr;

/// Type-check a decorator expression (`@expr`) against `ctx` and return its
/// type. Standard decorators name-resolve and type-check the expression: an
/// undefined name ⇒ TS2304, and the callee/args of a factory `@f(args)`
/// are checked. The returned type is the decorator function itself (for a
/// factory, the call's return type) — the value `checkDecoratorSig` relates
/// against the expected context-typed decorator signature.
///
/// `ctx` is the synthesized runtime call shape for the decorated position
/// (`decoratorCallSignature`). tsc contextually types the decorator
/// expression with it (`getContextualTypeForDecorator`), which is the ONLY
/// thing that gives an inline `@((target, context) => …)` parameter types
/// instead of implicit `any`.
fn checkDecorator(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const expr = c.tree.nodeData(node).lhs;
    if (expr == null_node) return types.any_type;
    return c.checkExprCached(expr, decoContextFor(c, expr, ctx));
}

/// The contextual type actually handed to a decorator expression: the
/// synthesized call shape, unless the expression is a function whose own
/// arity that shape cannot fill — tsc drops a too-narrow contextual signature
/// entirely (`isAritySmaller`), leaving every parameter implicit `any`, and a
/// legacy PROPERTY decorator written with three parameters against a
/// two-argument runtime shape is exactly that case.
///
/// Applied here rather than inside `contextualCallSig` because a decorator's
/// contextual signature is SYNTHESIZED from the decorated declaration and so
/// can be the wrong width by construction; see `contextSigForFnExpr`.
///
/// Parentheses are transparent to contextual typing, and `@(…)` is the only
/// way to spell an inline decorator function. Anything else — a name, a
/// factory call, a conditional — is handed the shape unchanged: it reaches no
/// proto of its own here, so no arity question arises.
fn decoContextFor(c: *Checker, expr: Node, ctx: TypeId) TypeId {
    if (ctx == types.no_type) return types.no_type;
    var e = expr;
    while (e != null_node and c.nodeTag(e) == .paren_expr) e = c.tree.nodeData(e).lhs;
    if (e == null_node) return ctx;
    switch (c.nodeTag(e)) {
        .arrow_fn, .function_expr => return contextSigForFnExpr(c, e, ctx),
        else => return ctx,
    }
}

/// Check a CLASS-position decorator (`@deco class C {}`) end to end: build the
/// call shape the runtime will invoke it with, check the expression against
/// it, then relate the resulting decorator type back to that shape.
///
/// One entry point rather than two calls at the use site because the ORDER is
/// load-bearing: the contextual type has to exist before the expression is
/// checked, and it is built from the same facts the signature check needs.
pub fn checkClassDecorator(c: *Checker, deco: Node, class_val: TypeId) Error!void {
    const ctx = try classDecoCallSignature(c, class_val);
    const dt = try checkDecorator(c, deco, ctx);
    if (c.prog.experimental_decorators) {
        return checkLegacyDecoratorSig(c, deco, dt, .class, .{
            .a = .{ class_val, types.any_type, types.any_type },
            .count = 1,
        });
    }
    return checkDecoratorSig(c, deco, dt, .class, class_val);
}

/// Check a class-MEMBER decorator end to end, in both dialects: classify the
/// decorated member, build the runtime call shape from it, check the
/// expression against that shape, then relate the decorator to it.
///
/// A member kind neither dialect models — a legacy constructor decorator,
/// which tsc has no head message for, and a trailing `@deco` the parser
/// recovered with no member after it (`target == null_node`) — still has its
/// EXPRESSION checked, so the names in it resolve and TS2304 is reported;
/// only the contextual type and the signature check are skipped.
pub fn checkMemberDecorator(c: *Checker, deco: Node, target: Node, this_t: TypeId, class_sym: SymbolId) Error!void {
    if (target == null_node) {
        _ = try checkDecorator(c, deco, types.no_type);
        return;
    }
    if (c.prog.experimental_decorators) {
        const shape = try legacyMemberShape(c, target, this_t, class_sym);
        const ctx = if (shape) |s| try legacyDecoCallSignature(c, s.pos, s.args) else types.no_type;
        const dt = try checkDecorator(c, deco, ctx);
        if (shape) |s| try checkLegacyDecoratorSig(c, deco, dt, s.pos, s.args);
        return;
    }
    const shape = try esMemberShape(c, target, this_t, class_sym);
    const ctx = if (shape) |s| try esDecoCallSignature(c, s) else types.no_type;
    const dt = try checkDecorator(c, deco, ctx);
    if (shape) |s| try checkDecoratorSig(c, deco, dt, s.pos, s.value);
}

/// Check every decorator written on the PARAMETERS of one class method or
/// constructor (`m(@dec x: T) {}`), in source order.
///
/// Parameter decorators exist in the LEGACY dialect only, so the whole walk is
/// gated on it: under standard decorators the parser reports TS1206 and
/// retains nothing (`ast.ParamDecos`), and there is no `(value, context)`
/// shape for the position to relate against.
///
/// tsc's `getLegacyDecoratorCallSignature` for a Parameter:
///
/// ```ts
/// const targetType = isConstructorDeclaration(node.parent) ?
///     getTypeOfSymbol(classSymbol) : getParentTypeOfClassElement(node.parent);
/// const keyType = isConstructorDeclaration(node.parent) ?
///     undefinedType : getClassElementPropertyKeyType(node.parent);
/// return createCallSignature(undefined,
///     [target: targetType, propertyKey: keyType, parameterIndex: numberType], voidType);
/// ```
///
/// A constructor's parameter decorator is therefore handed the CLASS VALUE and
/// `undefined` — the two facts `decoratorOnClassConstructorParameter1`'s
/// TS1239 ("Argument of type 'undefined' is not assignable to parameter of
/// type 'string | symbol'") rests on — while a method's gets the same
/// static/instance target and name-literal key a method decorator gets.
pub fn checkParamDecorators(c: *Checker, member: Node, this_t: TypeId, class_sym: SymbolId) Error!void {
    if (c.tree.param_decos.len == 0 or !c.prog.experimental_decorators) return;
    const proto_idx = c.tree.nodeData(member).lhs;
    const proto = c.tree.extraData(ast.FnProto, proto_idx);
    const is_ctor = c.isCtorMember(member, proto.flags);
    var args: LegacyDecoArgs = .{ .count = 3 };
    args.a[2] = types.number_type;
    var built = false;
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |param| {
        const decos = c.tree.paramDecorators(param);
        if (decos.len == 0) continue;
        if (!built) {
            built = true;
            args.a[0] = legacyDecoTarget(c, is_ctor or proto.flags & ast.Flags.static != 0, this_t, class_sym);
            args.a[1] = if (is_ctor)
                types.undefined_type
            else
                try legacyDecoKeyType(c, try memberKeyAtom(c, member, proto.flags));
        }
        const ctx = try legacyDecoCallSignature(c, .parameter, args);
        for (decos) |deco| {
            const dt = try checkDecorator(c, deco, ctx);
            try checkLegacyDecoratorSig(c, deco, dt, .parameter, args);
        }
    }
}

/// The position a decorator is applied to. Drives which TS12xx code and
/// which `Class*DecoratorContext` shape apply (tsc §checkDecorators).
/// `.parameter` exists in the LEGACY dialect only — the standard one has no
/// parameter decorators at all (the parser answers TS1206 and keeps nothing),
/// so it never reaches `esMemberShape`, `decoContextName` or `checkDecoratorSig`.
const DecoPos = enum { class, method, getter, setter, field, accessor, parameter };

fn decoCode(pos: DecoPos) u16 {
    return switch (pos) {
        .class => 1238, // class decorator
        .parameter => 1239, // parameter decorator
        .field, .accessor => 1240, // property decorator
        .method, .getter, .setter => 1241, // method decorator
    };
}

fn decoContextName(pos: DecoPos) []const u8 {
    return switch (pos) {
        .parameter => unreachable, // legacy-only position; see `DecoPos`
        .class => "ClassDecoratorContext",
        .method => "ClassMethodDecoratorContext",
        .getter => "ClassGetterDecoratorContext",
        .setter => "ClassSetterDecoratorContext",
        .field => "ClassFieldDecoratorContext",
        .accessor => "ClassAccessorDecoratorContext",
    };
}

/// What the STANDARD dialect needs from a decorated member. Computed as one
/// unit because the contextual type and the signature check read the same
/// facts and the contextual type has to be built first.
const EsShape = struct {
    pos: DecoPos,
    /// The `value` argument the runtime passes: the member's own function
    /// type for the method family, `undefined` for a field, a
    /// `ClassAccessorDecoratorTarget<This, V>` for an `accessor` field, and
    /// the class value for a class decorator.
    value: TypeId,
    /// tsc's `This` — the side the member is installed on.
    this_side: TypeId,
    /// The context type's `Value` type argument: the member's function type
    /// for a method, and the PROPERTY type (a getter's return, a setter's
    /// parameter, a field's declared type) for every other position.
    ctx_value: TypeId,
    /// The literal type of the member's NAME, or `no_type` for a name that has
    /// none to spell — a computed key, where the interface's own
    /// `string | symbol` is left to answer. `#x` spells as the string literal
    /// `"#x"`, as tsc's `getStringLiteralType(idText(node.name))` does.
    name_ty: TypeId,
    is_private: bool,
    is_static: bool,
};

/// Classify a decorated member for the standard dialect. Null for a member
/// kind the dialect does not model, which leaves the decorator expression
/// checked but unrelated.
fn esMemberShape(c: *Checker, target: Node, this_t: TypeId, class_sym: SymbolId) Error!?EsShape {
    const md = c.tree.nodeData(target);
    switch (c.nodeTag(target)) {
        .class_field => {
            const e = c.tree.extraData(ast.Field, md.lhs);
            const is_static = e.flags & ast.Flags.static != 0;
            const this_side = decoThisSide(c, is_static, this_t, class_sym);
            const prop = try memberPropType(c, this_side, try memberKeyAtom(c, target, e.flags));
            const nm = try memberNameType(c, target, e.flags);
            if (e.flags & ast.Flags.accessor != 0) {
                // `accessor x` decorators receive a
                // `ClassAccessorDecoratorTarget<This, Value>`.
                return .{
                    .pos = .accessor,
                    .value = decoFamilyRef(c, "ClassAccessorDecoratorTarget", &.{ this_side, prop }),
                    .this_side = this_side,
                    .ctx_value = prop,
                    .name_ty = nm.ty,
                    .is_private = nm.private,
                    .is_static = is_static,
                };
            }
            return .{
                // Field decorators receive `undefined` as the value.
                .pos = .field,
                .value = types.undefined_type,
                .this_side = this_side,
                .ctx_value = prop,
                .name_ty = nm.ty,
                .is_private = nm.private,
                .is_static = is_static,
            };
        },
        .class_method => {
            const proto = c.tree.extraData(ast.FnProto, md.lhs);
            const is_get = proto.flags & ast.Flags.get != 0;
            const is_set = proto.flags & ast.Flags.set != 0;
            const is_static = proto.flags & ast.Flags.static != 0;
            const this_side = decoThisSide(c, is_static, this_t, class_sym);
            const saved = c.this_type;
            c.this_type = this_side;
            // The value is the member's own function type. Suppress TS7006
            // here — the member's own pass reports implicit-any.
            const fn_ty = c.signatureOfProto(target, md.lhs, true, false) catch types.any_type;
            c.this_type = saved;
            const nm = try memberNameType(c, target, proto.flags);
            return .{
                .pos = if (is_get) .getter else if (is_set) .setter else .method,
                .value = fn_ty,
                .this_side = this_side,
                .ctx_value = memberValueType(c, fn_ty, is_get, is_set),
                .name_ty = nm.ty,
                .is_private = nm.private,
                .is_static = is_static,
            };
        },
        else => return null,
    }
}

/// tsc's `This` for a member's context type — and the `this` its own
/// signature is built under: the constructor function for a static member,
/// the instance type for an instance one. A class with no symbol has no
/// static side to name, so both sides fall back to the instance type.
///
/// Not `legacyDecoTarget`: that one answers with the `target` ARGUMENT the
/// legacy runtime passes, which is deliberately `any` where the class is
/// unknown so an incomplete relation cannot reject a decorator. This one
/// answers with a TYPE the context interface is instantiated with, where
/// `any` would erase every member of the context.
fn decoThisSide(c: *Checker, is_static: bool, this_t: TypeId, class_sym: SymbolId) TypeId {
    if (!is_static or class_sym == binder.no_symbol) return this_t;
    return c.ts.makeClassValue(class_sym) catch this_t;
}

/// The member's PROPERTY type, read off the class's own member table — which
/// the eager expansion at the top of the class walk has already materialized
/// — rather than out of the annotation, whose own diagnostics belong to the
/// member's pass and not the decorator's.
fn memberPropType(c: *Checker, this_side: TypeId, key: intern.Atom) Error!TypeId {
    if (key == 0) return types.any_type;
    const p = (try c.propOfType(this_side, key)) orelse return types.any_type;
    return p.ty;
}

/// The member's own type as the context interfaces and the legacy descriptor
/// both spell it: a getter's RETURN, a setter's PARAMETER, and a method's
/// whole function type (`ClassMethodDecoratorContext`'s `Value` *is* the
/// function, and `TypedPropertyDescriptor<T>` wraps the same choice).
fn memberValueType(c: *Checker, fn_ty: TypeId, is_get: bool, is_set: bool) TypeId {
    if (c.ts.kind(fn_ty) != .function) return fn_ty;
    if (is_get) return c.ts.fnReturn(fn_ty);
    if (is_set) return if (c.ts.fnParamCount(fn_ty) > 0) c.ts.fnParam(fn_ty, 0).ty else types.any_type;
    return fn_ty;
}

// =====================================================================
// the synthesized runtime call shape (tsc's `getDecoratorCallSignature`)
// =====================================================================

/// `(target: V, context: Ctx) => R | void` — the shape the standard runtime
/// invokes a member decorator with (tsc's `createESDecoratorCallSignature`).
/// Never asked for `.class`, which takes a one-type-argument context and has
/// its own builder.
fn esDecoCallSignature(c: *Checker, s: EsShape) Error!TypeId {
    return c.ts.makeFunction(&.{
        .{ .name = try c.atom("target"), .ty = s.value },
        .{ .name = try c.atom("context"), .ty = try esDecoContextType(c, s) },
    }, try esDecoReturnType(c, s), &.{}, 0);
}

/// tsc's `createClassMemberDecoratorContextTypeForNode`: the member's context
/// interface INTERSECTED with what the runtime actually knows about this
/// member —
///
/// ```ts
/// const overrideType = getDecoratorContextOverrideType(nameType, isPrivate, isStatic);
/// return getIntersectionType([contextType, overrideType]);
/// ```
///
/// — so `context.name` reads as the member's own literal name rather than the
/// interface's `string | symbol`, and `context.static` / `context.private` as
/// `true`/`false` rather than `boolean`. Anything that reads those, or
/// switches on them, sees a strictly more precise type than the interface
/// alone offers.
///
/// A degraded context (`any`, from `--noLib` or an unreadable member) is left
/// alone: intersecting `any` with the override would turn it into an object
/// that rejects the very reads the degradation exists to permit.
fn esDecoContextType(c: *Checker, s: EsShape) Error!TypeId {
    const ctx = decoFamilyRef(c, decoContextName(s.pos), &.{ s.this_side, s.ctx_value });
    if (ctx == types.any_type) return ctx;
    var props: [3]types.Prop = undefined;
    var n: usize = 0;
    if (s.name_ty != types.no_type) {
        props[n] = .{ .name = try c.atom("name"), .ty = s.name_ty };
        n += 1;
    }
    props[n] = .{
        .name = try c.atom("private"),
        .ty = if (s.is_private) types.true_type else types.false_type,
    };
    n += 1;
    props[n] = .{
        .name = try c.atom("static"),
        .ty = if (s.is_static) types.true_type else types.false_type,
    };
    n += 1;
    const override = try c.ts.makeObject(props[0..n], types.no_type, types.no_type, 0);
    return c.ts.makeIntersection(c.scratch(), &.{ ctx, override });
}

/// What a standard decorator may RETURN, per position — and so the contextual
/// type of every `return` in an inline decorator body:
///
/// * method / getter / setter → the member's own function type, replaced;
/// * field → an initializer mutator, `(this: This, value: V) => V`;
/// * `accessor` field → a `ClassAccessorDecoratorResult<This, V>`;
/// * class → the class value.
///
/// `| void` in every case: a decorator that returns nothing leaves the member
/// as it was. tsc reports a return type outside this union as its own TS1270
/// at the decorator, which ztsc does not implement — this models only the
/// CONTEXTUAL half, which is what an inline decorator's body is checked with.
fn esDecoReturnType(c: *Checker, s: EsShape) Error!TypeId {
    const r: TypeId = switch (s.pos) {
        .parameter => unreachable, // legacy-only position; see `DecoPos`
        .method, .getter, .setter, .class => s.value,
        .accessor => decoFamilyRef(c, "ClassAccessorDecoratorResult", &.{ s.this_side, s.ctx_value }),
        .field => try c.ts.makeFunctionThis(
            &.{.{ .name = try c.atom("value"), .ty = s.ctx_value }},
            s.ctx_value,
            &.{},
            0,
            null,
            s.this_side,
        ),
    };
    return c.makeUnion2(r, types.void_type);
}

/// The call shape for a CLASS decorator, in both dialects: the legacy runtime
/// hands it the constructor ALONE, the standard one the usual pair with a
/// `ClassDecoratorContext<typeof C>` over the class itself. Both may return
/// a replacement class or nothing.
fn classDecoCallSignature(c: *Checker, class_val: TypeId) Error!TypeId {
    const ret = try c.makeUnion2(class_val, types.void_type);
    const target: types.Param = .{ .name = try c.atom("target"), .ty = class_val };
    if (c.prog.experimental_decorators) return c.ts.makeFunction(&.{target}, ret, &.{}, 0);
    return c.ts.makeFunction(&.{
        target,
        .{
            .name = try c.atom("context"),
            .ty = decoFamilyRef(c, decoContextName(.class), &.{class_val}),
        },
    }, ret, &.{}, 0);
}

/// The call shape tsc synthesizes for a LEGACY member decorator
/// (`getLegacyDecoratorCallSignature`), built from the very tuple the
/// signature check resolves against: `(target, propertyKey)` returning `void`
/// for a plain property, and `(target, propertyKey, descriptor)` returning
/// `TypedPropertyDescriptor<T> | void` for the method family and for an
/// `accessor` field.
///
/// The full width is used here even for the method family, whose ARITY check
/// counts only two arguments against a two-parameter signature
/// (`LegacyDecoArgs.method_shape`): that narrowing is about which signatures
/// resolve, while contextual typing hands a three-parameter decorator all
/// three types — as tsgo does.
///
/// A PARAMETER decorator is the one three-argument position whose third
/// argument is not a descriptor: tsc names it `parameterIndex`, types it
/// `number`, and the signature returns plain `void` — nothing a parameter
/// decorator returns is used.
fn legacyDecoCallSignature(c: *Checker, pos: DecoPos, args: LegacyDecoArgs) Error!TypeId {
    const third: []const u8 = if (pos == .parameter) "parameterIndex" else "descriptor";
    const params: [3]types.Param = .{
        .{ .name = try c.atom("target"), .ty = args.a[0] },
        .{ .name = try c.atom("propertyKey"), .ty = args.a[1] },
        .{ .name = try c.atom(third), .ty = args.a[2] },
    };
    const n = @min(args.count, params.len);
    const ret = if (n == 3 and pos != .parameter)
        try c.makeUnion2(args.a[2], types.void_type)
    else
        types.void_type;
    return c.ts.makeFunction(params[0..n], ret, &.{}, 0);
}

/// Build a `.ref` to a decorator-family lib interface by name with the given
/// type arguments, or `any` when the lib does not declare it (`--noLib`).
/// An argument that could not be read off the declaration arrives as `any`
/// and stays `any`, so an unknown member type degrades the context type
/// instead of failing to build one.
fn decoFamilyRef(c: *Checker, name: []const u8, args: []const TypeId) TypeId {
    var buf: [2]TypeId = undefined;
    if (args.len > buf.len) return types.any_type;
    for (args, 0..) |t, i| {
        buf[i] = if (t == types.no_type or t == types.error_type) types.any_type else t;
    }
    const a = c.atom(name) catch return types.any_type;
    const sym = c.prog.globals.lookup(a) orelse return types.any_type;
    if (!c.symFlags(sym).interface) return types.any_type;
    return c.ts.makeRef(sym, buf[0..args.len]) catch types.any_type;
}

// =====================================================================
// legacy (`experimentalDecorators`) decorator signature resolution
// =====================================================================

/// The argument list tsc synthesizes for a LEGACY decorator call
/// (`getEffectiveDecoratorArguments`). `count` is how many arguments the
/// runtime actually hands over — 1 for a class, 2 for a property, 3 for an
/// `accessor` field or a method-family member — and is what the arity
/// message reports.
const LegacyDecoArgs = struct {
    /// `[target, propertyKey, descriptor]`, `any` where not modeled.
    a: [3]TypeId = .{ types.any_type, types.any_type, types.any_type },
    count: u32,
    /// Method-family position (method / get / set). tsc's
    /// `getLegacyDecoratorArgumentCount` hands the descriptor only to a
    /// signature that declares MORE than two parameters, so a two-parameter
    /// method decorator is arity-checked against two arguments even though
    /// the runtime passes three.
    method_shape: bool = false,
};

/// What the LEGACY dialect needs from a decorated member: its position and
/// the `(target, propertyKey, descriptor)` tuple the runtime passes.
const LegacyShape = struct { pos: DecoPos, args: LegacyDecoArgs };

/// Classify a decorated member for the legacy dialect and synthesize the
/// argument tuple the runtime passes it. Null for a member kind the dialect
/// does not model and for a CONSTRUCTOR — a constructor takes no decorator
/// (the grammar rejects it) and tsc has no head message for that position.
fn legacyMemberShape(c: *Checker, target: Node, this_t: TypeId, class_sym: SymbolId) Error!?LegacyShape {
    const md = c.tree.nodeData(target);
    var args: LegacyDecoArgs = .{ .count = 2 };
    var pos: DecoPos = .method;
    switch (c.nodeTag(target)) {
        .class_field => {
            const e = c.tree.extraData(ast.Field, md.lhs);
            const is_accessor = e.flags & ast.Flags.accessor != 0;
            pos = if (is_accessor) .accessor else .field;
            args.a[0] = legacyDecoTarget(c, e.flags & ast.Flags.static != 0, this_t, class_sym);
            const key = try memberKeyAtom(c, target, e.flags);
            args.a[1] = try legacyDecoKeyType(c, key);
            args.count = if (is_accessor) 3 else 2;
            // An `accessor` field is handed a descriptor too, over the
            // field's own type.
            if (is_accessor) {
                args.a[2] = legacyDescriptorType(c, try memberPropType(c, args.a[0], key));
            }
        },
        .class_method => {
            const proto = c.tree.extraData(ast.FnProto, md.lhs);
            // A constructor takes no decorator (the grammar rejects it) and
            // tsc has no head message for that position.
            if (c.isCtorMember(target, proto.flags)) return null;
            const is_get = proto.flags & ast.Flags.get != 0;
            const is_set = proto.flags & ast.Flags.set != 0;
            pos = if (is_get) .getter else if (is_set) .setter else .method;
            args.a[0] = legacyDecoTarget(c, proto.flags & ast.Flags.static != 0, this_t, class_sym);
            args.a[1] = try legacyDecoKeyType(c, try memberKeyAtom(c, target, proto.flags));
            args.count = 3;
            args.method_shape = true;
            // `TypedPropertyDescriptor<T>` over the member's own type: the
            // function type for a method, and the PROPERTY type — the
            // getter's return, the setter's parameter — for an accessor
            // (tsc's `getTypeOfNode` on the declaration).
            const saved = c.this_type;
            c.this_type = args.a[0];
            const fn_t = c.signatureOfProto(target, md.lhs, true, false) catch types.any_type;
            c.this_type = saved;
            args.a[2] = legacyDescriptorType(c, memberValueType(c, fn_t, is_get, is_set));
        },
        else => return null,
    }
    return .{ .pos = pos, .args = args };
}

/// The `target` argument: the constructor function for a static member (and
/// for a class decorator), the instance type — tsc's declared type, so a
/// generic class contributes its own type parameters — for an instance one.
fn legacyDecoTarget(c: *Checker, is_static: bool, this_t: TypeId, class_sym: SymbolId) TypeId {
    if (class_sym == binder.no_symbol) return types.any_type;
    if (!is_static) return this_t;
    return c.ts.makeClassValue(class_sym) catch types.any_type;
}

/// The member's name atom, or 0 for a name whose key tsc does not spell as a
/// string literal — a computed or private one, where it answers `string` or
/// the key's own symbol type and guessing either way could invent a
/// rejection.
fn memberKeyAtom(c: *Checker, target: Node, flags: u32) Error!intern.Atom {
    if (flags & (ast.Flags.computed | ast.Flags.computed_sym) != 0) return 0;
    const tok = c.tree.nodeMainToken(target);
    switch (c.tree.tokens.tag(tok)) {
        .identifier, .string_literal, .numeric_literal => {},
        // A keyword-spelled member name (`delete`, `default`, …) is an
        // identifier for this purpose; anything else (private names) is not.
        else => if (!scanner.Tag.isKeyword(c.tree.tokens.tag(tok))) return 0,
    }
    return c.memberAtom(tok);
}

/// The member's NAME as the standard context type spells it, plus whether it
/// is a private one — the two facts tsc reads in
/// `createClassMemberDecoratorContextTypeForNode`:
///
/// ```ts
/// const isPrivate = isPrivateIdentifier(node.name);
/// const nameType = isPrivate ? getStringLiteralType(idText(node.name)) : getLiteralTypeFromPropertyName(node.name);
/// ```
///
/// `#x` keeps its hash — `idText` of a private identifier includes it. A
/// COMPUTED key answers `no_type`: its literal type is whatever the key
/// expression evaluates to, and inventing one where the context interface
/// already declares `string | symbol` could only narrow it wrongly.
fn memberNameType(c: *Checker, target: Node, flags: u32) Error!struct { ty: TypeId, private: bool } {
    const tok = c.tree.nodeMainToken(target);
    if (c.tree.tokens.tag(tok) == .private_identifier) {
        return .{ .ty = try c.ts.makeStringLiteral(try c.atomOfToken(tok), false), .private = true };
    }
    // A NUMERIC name is a number literal type to tsc, not a string one, and
    // the member table spells it as text; leave it to the interface.
    if (c.tree.tokens.tag(tok) == .numeric_literal) return .{ .ty = types.no_type, .private = false };
    const key = try memberKeyAtom(c, target, flags);
    if (key == 0) return .{ .ty = types.no_type, .private = false };
    return .{ .ty = try c.ts.makeStringLiteral(key, false), .private = false };
}

/// The `propertyKey` argument: the string-literal type of the member's name
/// (tsc's `getClassElementPropertyKeyType`).
fn legacyDecoKeyType(c: *Checker, key: intern.Atom) Error!TypeId {
    if (key == 0) return types.any_type;
    return c.ts.makeStringLiteral(key, false);
}

/// `TypedPropertyDescriptor<T>`, or `any` when the lib does not declare it.
fn legacyDescriptorType(c: *Checker, t: TypeId) TypeId {
    if (t == types.no_type or t == types.error_type) return types.any_type;
    const a = c.atom("TypedPropertyDescriptor") catch return types.any_type;
    const sym = c.prog.globals.lookup(a) orelse return types.any_type;
    if (!c.symFlags(sym).interface) return types.any_type;
    return c.ts.makeRef(sym, &.{t}) catch types.any_type;
}

/// Resolve a LEGACY decorator against the argument tuple the runtime hands
/// it, and report tsc's TS1238/1240/1241 when no call signature accepts it
/// ("Unable to resolve signature of … decorator when called as an
/// expression.", with the argument or arity failure chained beneath).
///
/// tsc runs the ordinary call resolution here, so this mirrors
/// `resolveDecorator` → `chooseOverload`: a candidate is rejected on arity
/// first (`hasCorrectArity` counts the arguments tsc would actually pass a
/// signature of that shape) and on argument assignability second, and the
/// argument failure outranks the arity one in the report.
///
/// Deliberately narrower than tsc in two places, each an under-report and
/// never a false positive: an OVERLOADED decorator is left alone (tsc's
/// report there is a nested "No overload matches this call" chain) and a
/// GENERIC signature is left alone (its parameters are only judgeable after
/// inference). The decorator's RETURN type — tsc also requires `void`/`any`
/// for a property decorator and a descriptor for a method one, under the same
/// TS12xx codes — is not checked here either.
///
/// A CLASS used as a decorator is the one non-callable shape that is answered:
/// `@CtorDtor class C {}` cannot resolve, whatever `CtorDtor` declares,
/// because a class constructor is never callable as a function
/// (`constructableDecoratorOnClass01`). Every other non-callable type stays an
/// under-report — an `any`, an unresolved import or a shape ztsc modelled
/// incompletely must not turn into an invented diagnostic.
fn checkLegacyDecoratorSig(c: *Checker, deco: Node, dt: TypeId, pos: DecoPos, args: LegacyDecoArgs) Error!void {
    const r = try c.resolveStructural(dt);
    const sig = switch (c.ts.kind(r)) {
        .function => r,
        // A callable object with exactly one signature resolves like a plain
        // function; more than one is an overload set (skipped, above).
        .object => if (c.ts.objectCallSigCount(r) == 1) c.ts.objectCallSig(r, 0) else return,
        // tsc's `resolveCall` finds no call signature at all and reports the
        // decorator head with `getInvocationErrorDetails` chained beneath —
        // the two-level "not callable / no call signatures" chain, verified
        // byte-for-byte against tsgo 7.0.2.
        .class_value => return c.diagFmt(
            decoCode(pos),
            decoExprSpan(c, deco),
            "Unable to resolve signature of {s} decorator when called as an expression.\n  This expression is not callable.\n    Type '{s}' has no call signatures.",
            .{ decoPosWord(pos), try c.typeToString(dt) },
        ),
        else => return,
    };
    if (c.ts.fnTypeParams(sig).len > 0) return;
    const params = c.ts.fnParamCount(sig);
    const min = try c.requiredParams(sig);
    const max = try c.paramTotal(sig);
    // tsc's `hasEffectiveRestParameter` (a rest that does NOT expand to a
    // fixed parameter list) decides which arity wording applies;
    // `signatureHasRestParameter` (the declared `...`) decides whether the
    // decorator merely looks uncalled, and lives in `uncalledFactory`.
    const unbounded = max == std.math.maxInt(u32);
    // How many arguments tsc counts against THIS signature
    // (`getDecoratorArgumentCount`) — the method family drops the
    // descriptor for a signature of two parameters or fewer.
    const argc: u32 = if (args.method_shape) (if (params <= 2) 2 else 3) else args.count;

    // tsc's `isPotentiallyUncalledDecorator`: a signature that takes no
    // required argument and cannot absorb the ones the runtime passes is
    // reported as a decorator FACTORY someone forgot to call (TS1329, "Did
    // you mean to call it first"), not as a broken decorator. Only where the
    // decorator is written as a NAME, though — see `reportUncalledFactory`;
    // otherwise the arity failure below IS the answer.
    if (try uncalledFactory(c, sig, argc) and try reportUncalledFactory(c, deco)) return;

    if (argc < min or argc > max) {
        // "expects N" / "N-M" / "at least N", over the same three cases as
        // tsc's argument-arity error. The count blamed is the number of
        // arguments the RUNTIME passes (tsc reports `args.length`), which
        // for a small method decorator is not the `argc` above.
        var buf: [32]u8 = undefined;
        const expects: []const u8 = if (unbounded)
            std.fmt.bufPrint(&buf, "at least {d}", .{min}) catch unreachable
        else if (min != max)
            std.fmt.bufPrint(&buf, "{d}-{d}", .{ min, max }) catch unreachable
        else
            std.fmt.bufPrint(&buf, "{d}", .{min}) catch unreachable;
        // TOO FEW arguments is blamed on the whole call — the decorator, `@`
        // included; TOO MANY is blamed on the span of the surplus arguments,
        // and every synthesized argument's node is the decorator's own
        // expression, so that span is the expression (tsc's
        // `getArgumentArityError`: `getDiagnosticForCallNode` for the first
        // case, `createDiagnosticForNodeArray(args…)` for the second).
        const span = if (argc > max) decoExprSpan(c, deco) else c.nodeSpan(deco);
        try c.diagFmt(decoCode(pos), span, "Unable to resolve signature of {s} decorator when called as an expression.\n  The runtime will invoke the decorator with {d} arguments, but the decorator expects {s}.", .{
            decoPosWord(pos), args.count, expects,
        });
        return;
    }

    var i: u32 = 0;
    while (i < args.count) : (i += 1) {
        const at = args.a[i];
        if (at == types.no_type or at == types.any_type or at == types.error_type) continue;
        // Past the parameter list tsc relates the argument to `any`.
        const pt = (try c.paramTypeAt(sig, i)) orelse continue;
        if (try c.isAssignable(at, pt)) continue;
        const span = decoExprSpan(c, deco);
        // The derivation tsc prints under the argument line, shifted one
        // level deeper than it renders under a bare TS2345 headline.
        const chain = try indentChain(c, try elaborate.chainText(c, at, pt));
        try c.diagFmt(decoCode(pos), span, "Unable to resolve signature of {s} decorator when called as an expression.\n  Argument of type '{s}' is not assignable to parameter of type '{s}'.{s}", .{
            decoPosWord(pos), try c.typeToString(at), try c.typeToString(pt), chain,
        });
        return; // tsc reports the first failing argument only
    }
}

/// tsc's `isPotentiallyUncalledDecorator`, for ONE signature: it takes no
/// required argument, declares no rest parameter, and still has fewer
/// parameters than the runtime will hand it. Such a signature can never
/// resolve, but the reason is not a broken decorator — it is a decorator
/// FACTORY someone forgot to call.
///
/// `argc` is the caller's `getDecoratorArgumentCount`, which is the only
/// thing the two dialects disagree about here.
fn uncalledFactory(c: *Checker, sig: TypeId, argc: u32) Error!bool {
    if (try c.requiredParams(sig) != 0) return false;
    const params = c.ts.fnParamCount(sig);
    if (params > 0 and c.ts.fnParam(sig, params - 1).rest()) return false;
    return params < argc;
}

/// TS1329, tsc's answer for `uncalledFactory` — reported in place of the
/// arity failure it stands for. Returns false when the shape earns no TS1329
/// and the arity report is the right answer after all.
///
/// The suggestion needs a NAME to put a `()` after, and tsgo answers TS1329
/// only where the decorator expression IS one: an identifier or a dotted name.
/// `@(dec)`, `@(mk())` and `@(() => {})` all take the arity message instead,
/// measured in BOTH dialects — `@dec` is TS1329 while the parenthesized `@(dec)`
/// on the same declaration is TS1238 "expects 0".
///
/// The whole decorator NODE is blamed (`createDiagnosticForNode(node)`, so the
/// `@` is included), while the name quoted twice is the raw source text of its
/// EXPRESSION (`getTextOfNode`), not the type it resolved to — `@o.f` suggests
/// `@o.f()`.
fn reportUncalledFactory(c: *Checker, deco: Node) Error!bool {
    const expr = c.tree.nodeData(deco).lhs;
    if (expr == null_node) return false;
    switch (c.nodeTag(expr)) {
        .identifier, .member_expr => {},
        else => return false,
    }
    const s = c.nodeSpan(expr);
    const text = c.src[s.start..s.end];
    try c.diagFmt(
        1329,
        c.nodeSpan(deco),
        "'{s}' accepts too few arguments to be used as a decorator here. Did you mean to call it first and write '@{s}()'?",
        .{ text, text },
    );
    return true;
}

/// The span of a decorator's expression (`Field` in `@Field`) — where every
/// argument tsc synthesizes for the decorator call points, and so where an
/// argument-level failure is blamed. Falls back to the decorator itself for
/// the recovered `@` with nothing after it.
fn decoExprSpan(c: *Checker, deco: Node) source.Span {
    const expr = c.tree.nodeData(deco).lhs;
    return if (expr != null_node) c.nodeSpan(expr) else c.nodeSpan(deco);
}

/// The member word tsc names in the "Unable to resolve signature of …"
/// headline. An accessor (`get`/`set`) is a *method* decorator there; an
/// `accessor` field is a *property* one.
fn decoPosWord(pos: DecoPos) []const u8 {
    return switch (pos) {
        .class => "class",
        .parameter => "parameter",
        .field, .accessor => "property",
        .method, .getter, .setter => "method",
    };
}

/// Relate a decorator against the expected `(value, context) => …` shape
/// for its position and emit TS1238/1240/1241 when no call signature fits
/// (tsc: "Unable to resolve signature of … decorator when called as an
/// expression."). Policy: under-report freely, never a false positive —
/// generic decorators and any/unknown parameter types are always accepted,
/// and the `value`/`context` relations run only where a mismatch is
/// unambiguous.
fn checkDecoratorSig(c: *Checker, deco: Node, dt: TypeId, pos: DecoPos, value: TypeId) Error!void {
    // `experimentalDecorators` selects the LEGACY dialect, where the runtime
    // hands a decorator `(target, propertyKey, descriptorOrParameterIndex)` —
    // a different call shape from the standard `(value, context)` this
    // function models, and one whose own diagnostics are a different family
    // (TS1270/TS1271, not TS1238/1240/1241). Checking a legacy decorator
    // against the standard shape reports every one of them: Nest's
    // `@Column()`, `@WebSocketServer()`, `@ApiProperty()` and friends all
    // fail. Accept them all instead — an under-report, per the no-false-
    // positive rule. See `tsconfig.Config.experimental_decorators`.
    if (c.prog.experimental_decorators) return;
    const r = try c.resolveStructural(dt);
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    switch (c.ts.kind(r)) {
        .any, .unknown, .err => return, // permissive: no reliable shape
        .function => try sigs.append(c.scratch(), r),
        .overloads => {
            for (try c.memberList(r)) |m| try sigs.append(c.scratch(), m);
        },
        .object => {
            if (c.ts.objectCallSigCount(r) == 0) return; // non-callable: under-report
            for (0..c.ts.objectCallSigCount(r)) |i| {
                try sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
            }
        },
        else => return, // not callable in a shape we model: under-report
    }
    if (sigs.items.len == 0) return;

    // tsc's `isPotentiallyUncalledDecorator` runs over EVERY signature, ahead
    // of any relation: a decorator none of whose signatures can absorb the
    // arguments the runtime passes is a factory someone forgot to call
    // (TS1329), whatever its parameters would have accepted. In the standard
    // dialect `getDecoratorArgumentCount` is `min(max(paramCount, 1), 2)`, so
    // only a signature with NO parameters at all is short.
    var uncalled = true;
    for (sigs.items) |sig| {
        const argc = @min(@max(c.ts.fnParamCount(sig), 1), 2);
        if (!try uncalledFactory(c, sig, argc)) {
            uncalled = false;
            break;
        }
    }
    // Only a decorator written as a NAME earns TS1329; the standard dialect's
    // own arity report is not modelled here, so any other spelling falls
    // through to the relation below and stays the under-report it was.
    if (uncalled and try reportUncalledFactory(c, deco)) return;

    // Expected context interface for this position (null under --noLib →
    // context relation is skipped, value/arity relation still applies).
    const ctx_atom = c.atom(decoContextName(pos)) catch 0;
    const ctx_sym: ?SymbolId = if (ctx_atom != 0) c.prog.globals.lookup(ctx_atom) else null;

    for (sigs.items) |sig| {
        if (try decoSigMatches(c, sig, pos, value, ctx_sym)) return; // some overload fits
    }
    const expr = c.tree.nodeData(deco).lhs;
    const span = if (expr != null_node) c.nodeSpan(expr) else c.nodeSpan(deco);
    try c.diagFmt(decoCode(pos), span, "Unable to resolve signature of {s} decorator when called as an expression.", .{decoPosWord(pos)});
}

/// Does one decorator call signature accept the runtime `(value, context)`
/// call? Conservative: a generic signature or any indeterminate parameter
/// is treated as a match (under-report, never a false positive).
fn decoSigMatches(c: *Checker, sig: TypeId, pos: DecoPos, value: TypeId, ctx_sym: ?SymbolId) Error!bool {
    // Generic decorators need inference we don't model here — accept.
    if (c.ts.fnTypeParams(sig).len > 0) return true;
    // The runtime invokes a decorator with 2 arguments; a signature that
    // *requires* more can never resolve (tsc: "expects N").
    if (try c.requiredParams(sig) > 2) return false;
    // Value argument vs the first parameter.
    if (try c.paramTypeAt(sig, 0)) |p0| {
        if (!try decoAcceptsValue(c, pos, value, p0)) return false;
    }
    // Context argument vs the second parameter: fail only on an
    // unambiguous decorator-context kind mismatch.
    if (ctx_sym != null) {
        if (try c.paramTypeAt(sig, 1)) |p1| {
            if (decoContextMismatch(c, p1, ctx_sym.?)) return false;
        }
    }
    return true;
}

/// True if `value` is acceptable as the first decorator argument for `p0`.
/// Permissive supertypes (`any`/`unknown`/`object`/`Function`, a matching
/// context/target ref, or a constructor-typed parameter for a class
/// decorator) are accepted without an assignability probe so an incomplete
/// relation cannot produce a false positive.
fn decoAcceptsValue(c: *Checker, pos: DecoPos, value: TypeId, p0: TypeId) Error!bool {
    switch (c.ts.kind(p0)) {
        .any, .unknown, .err, .object_keyword => return true,
        .ref => {
            const psym = c.ts.refSymbol(p0);
            if (c.globalSymNamed(psym, "Function")) return true;
            if (pos == .accessor and c.globalSymNamed(psym, "ClassAccessorDecoratorTarget")) return true;
        },
        .object => {
            // A constructor-typed parameter accepts a class value.
            if (pos == .class and c.ts.objectConstructSigCount(p0) > 0) return true;
        },
        else => {},
    }
    if (value == 0 or value == types.error_type or value == types.any_type) return true;
    return c.isAssignable(value, p0);
}

/// True when `p1` is a ref to a *different* decorator-context interface
/// than expected (e.g. `ClassMethodDecoratorContext` where a class
/// decorator wants `ClassDecoratorContext`). Anything else (a union like
/// `DecoratorContext`, `any`, an unrelated type) is accepted.
fn decoContextMismatch(c: *Checker, p1: TypeId, ctx_sym: SymbolId) bool {
    if (c.ts.kind(p1) != .ref) return false;
    const psym = c.ts.refSymbol(p1);
    const family = [_][]const u8{
        "ClassDecoratorContext",       "ClassMethodDecoratorContext",
        "ClassGetterDecoratorContext", "ClassSetterDecoratorContext",
        "ClassFieldDecoratorContext",  "ClassAccessorDecoratorContext",
    };
    for (family) |name| {
        if (c.globalSymNamed(psym, name)) return psym != ctx_sym;
    }
    return false;
}

/// Is `sym` the global interface/type named `name`?
pub fn globalSymNamed(c: *Checker, sym: SymbolId, name: []const u8) bool {
    const a = c.atom(name) catch return false;
    const g = c.prog.globals.lookup(a) orelse return false;
    return g == sym;
}
