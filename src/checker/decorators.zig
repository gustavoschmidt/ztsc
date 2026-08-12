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

/// Type-check a decorator expression (`@expr`) and return its type.
/// Standard decorators name-resolve and type-check the expression: an
/// undefined name ⇒ TS2304, and the callee/args of a factory `@f(args)`
/// are checked. The returned type is the decorator function itself (for a
/// factory, the call's return type) — the value `checkDecoratorSig` relates
/// against the expected context-typed decorator signature.
pub fn checkDecorator(c: *Checker, node: Node) Error!TypeId {
    const expr = c.tree.nodeData(node).lhs;
    if (expr == null_node) return types.any_type;
    return c.checkExprCached(expr, types.no_type);
}

/// The position a decorator is applied to. Drives which TS12xx code and
/// which `Class*DecoratorContext` shape apply (tsc §checkDecorators).
pub const DecoPos = enum { class, method, getter, setter, field, accessor };

pub fn decoCode(pos: DecoPos) u16 {
    return switch (pos) {
        .class => 1238, // class decorator
        .field, .accessor => 1240, // property decorator
        .method, .getter, .setter => 1241, // method decorator
    };
}

pub fn decoContextName(pos: DecoPos) []const u8 {
    return switch (pos) {
        .class => "ClassDecoratorContext",
        .method => "ClassMethodDecoratorContext",
        .getter => "ClassGetterDecoratorContext",
        .setter => "ClassSetterDecoratorContext",
        .field => "ClassFieldDecoratorContext",
        .accessor => "ClassAccessorDecoratorContext",
    };
}

/// Signature check for a class-member decorator: classify the member's
/// position, build the `value` argument type tsc synthesizes for it, and
/// relate the decorator against the expected context-typed signature.
pub fn checkMemberDecoratorSig(c: *Checker, deco: Node, dt: TypeId, target: Node, this_t: TypeId, class_sym: SymbolId) Error!void {
    if (c.prog.experimental_decorators) return checkLegacyMemberDeco(c, deco, dt, target, this_t, class_sym);
    const md = c.tree.nodeData(target);
    var pos: DecoPos = .method;
    var value: TypeId = types.any_type;
    switch (c.nodeTag(target)) {
        .class_field => {
            const e = c.tree.extraData(ast.Field, md.lhs);
            if (e.flags & ast.Flags.accessor != 0) {
                pos = .accessor;
                // `accessor x` decorators receive a
                // `ClassAccessorDecoratorTarget<This, Value>`.
                value = c.decoContextRef("ClassAccessorDecoratorTarget");
            } else {
                pos = .field;
                // Field decorators receive `undefined` as the value.
                value = types.undefined_type;
            }
        },
        .class_method => {
            const proto = c.tree.extraData(ast.FnProto, md.lhs);
            if (proto.flags & ast.Flags.get != 0) {
                pos = .getter;
            } else if (proto.flags & ast.Flags.set != 0) {
                pos = .setter;
            } else {
                pos = .method;
            }
            const is_static = proto.flags & ast.Flags.static != 0;
            const saved = c.this_type;
            c.this_type = if (is_static and class_sym != binder.no_symbol)
                try c.ts.makeClassValue(class_sym)
            else
                this_t;
            // The value is the member's own function type. Suppress TS7006
            // here — the member's own pass reports implicit-any.
            value = c.signatureOfProto(target, md.lhs, true, false) catch types.any_type;
            c.this_type = saved;
        },
        else => return,
    }
    try c.checkDecoratorSig(deco, dt, pos, value);
}

/// Signature check for a CLASS decorator, dispatching on the dialect the
/// same way `checkMemberDecoratorSig` does: the legacy runtime hands a class
/// decorator the constructor function ALONE, the standard one hands it the
/// usual `(value, context)` pair.
pub fn checkClassDecoratorSig(c: *Checker, deco: Node, dt: TypeId, class_val: TypeId) Error!void {
    if (c.prog.experimental_decorators) {
        return checkLegacyDecoratorSig(c, deco, dt, .class, .{
            .a = .{ class_val, types.any_type, types.any_type },
            .count = 1,
        });
    }
    return checkDecoratorSig(c, deco, dt, .class, class_val);
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

/// Legacy signature check for a class-member decorator: classify the member,
/// synthesize the `(target, propertyKey, descriptor)` tuple the runtime
/// passes it, and resolve the decorator call against it.
fn checkLegacyMemberDeco(c: *Checker, deco: Node, dt: TypeId, target: Node, this_t: TypeId, class_sym: SymbolId) Error!void {
    const md = c.tree.nodeData(target);
    var args: LegacyDecoArgs = .{ .count = 2 };
    var pos: DecoPos = .method;
    switch (c.nodeTag(target)) {
        .class_field => {
            const e = c.tree.extraData(ast.Field, md.lhs);
            const is_accessor = e.flags & ast.Flags.accessor != 0;
            pos = if (is_accessor) .accessor else .field;
            args.a[0] = legacyDecoTarget(c, e.flags & ast.Flags.static != 0, this_t, class_sym);
            const key = try legacyDecoKeyAtom(c, target, e.flags);
            args.a[1] = try legacyDecoKeyType(c, key);
            args.count = if (is_accessor) 3 else 2;
            // An `accessor` field is handed a descriptor too, over the
            // field's own type. Read off the class's member table — already
            // materialized by the eager expansion at the top of the class
            // walk — rather than out of the annotation, whose own
            // diagnostics belong to the member's pass, not the decorator's.
            if (is_accessor) {
                const pt: TypeId = if (key != 0) blk: {
                    const p = (try c.propOfType(args.a[0], key)) orelse break :blk types.any_type;
                    break :blk p.ty;
                } else types.any_type;
                args.a[2] = legacyDescriptorType(c, pt);
            }
        },
        .class_method => {
            const proto = c.tree.extraData(ast.FnProto, md.lhs);
            // A constructor takes no decorator (the grammar rejects it) and
            // tsc has no head message for that position.
            if (c.isCtorName(try c.memberAtom(c.tree.nodeMainToken(target)))) return;
            const is_get = proto.flags & ast.Flags.get != 0;
            const is_set = proto.flags & ast.Flags.set != 0;
            pos = if (is_get) .getter else if (is_set) .setter else .method;
            args.a[0] = legacyDecoTarget(c, proto.flags & ast.Flags.static != 0, this_t, class_sym);
            args.a[1] = try legacyDecoKeyType(c, try legacyDecoKeyAtom(c, target, proto.flags));
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
            var member_t = fn_t;
            if (c.ts.kind(fn_t) == .function) {
                if (is_get) {
                    member_t = c.ts.fnReturn(fn_t);
                } else if (is_set) {
                    member_t = if (c.ts.fnParamCount(fn_t) > 0) c.ts.fnParam(fn_t, 0).ty else types.any_type;
                }
            }
            args.a[2] = legacyDescriptorType(c, member_t);
        },
        else => return,
    }
    try checkLegacyDecoratorSig(c, deco, dt, pos, args);
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
fn legacyDecoKeyAtom(c: *Checker, target: Node, flags: u32) Error!intern.Atom {
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
/// Deliberately narrower than tsc in three places, each an under-report and
/// never a false positive: an OVERLOADED decorator is left alone (tsc's
/// report there is a nested "No overload matches this call" chain), a
/// GENERIC signature is left alone (its parameters are only judgeable after
/// inference), and a non-callable decorator is left alone (tsc's "This
/// expression is not callable"). The decorator's RETURN type — tsc also
/// requires `void`/`any` for a property decorator and a descriptor for a
/// method one, under the same TS12xx codes — is not checked here either.
fn checkLegacyDecoratorSig(c: *Checker, deco: Node, dt: TypeId, pos: DecoPos, args: LegacyDecoArgs) Error!void {
    const r = try c.resolveStructural(dt);
    const sig = switch (c.ts.kind(r)) {
        .function => r,
        // A callable object with exactly one signature resolves like a plain
        // function; more than one is an overload set (skipped, above).
        .object => if (c.ts.objectCallSigCount(r) == 1) c.ts.objectCallSig(r, 0) else return,
        else => return,
    };
    if (c.ts.fnTypeParams(sig).len > 0) return;
    const params = c.ts.fnParamCount(sig);
    const min = try c.requiredParams(sig);
    const max = try c.paramTotal(sig);
    // tsc's `signatureHasRestParameter` (the declared `...`) versus its
    // `hasEffectiveRestParameter` (a rest that does NOT expand to a fixed
    // parameter list): the first decides whether the decorator merely looks
    // uncalled, the second which arity wording applies.
    const has_rest = params > 0 and c.ts.fnParam(sig, params - 1).rest();
    const unbounded = max == std.math.maxInt(u32);
    // How many arguments tsc counts against THIS signature
    // (`getDecoratorArgumentCount`) — the method family drops the
    // descriptor for a signature of two parameters or fewer.
    const argc: u32 = if (args.method_shape) (if (params <= 2) 2 else 3) else args.count;

    // tsc's `isPotentiallyUncalledDecorator`: a signature that takes no
    // required argument and cannot absorb the ones the runtime passes is
    // reported as a decorator FACTORY someone forgot to call (TS1329,
    // "Did you mean to call it first"), not as a broken decorator. ztsc
    // under-reports that family — and must not report the arity failure in
    // its place.
    if (min == 0 and !has_rest and params < argc) return;

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
        .field, .accessor => "property",
        .method, .getter, .setter => "method",
    };
}

/// Build a `.ref` to a decorator-family lib interface by name (default
/// type args), or `any` when absent (e.g. `--noLib`).
pub fn decoContextRef(c: *Checker, name: []const u8) TypeId {
    const a = c.atom(name) catch return types.any_type;
    const sym = c.prog.globals.lookup(a) orelse return types.any_type;
    if (!c.symFlags(sym).interface) return types.any_type;
    return c.ts.makeRef(sym, &.{}) catch types.any_type;
}

/// Relate a decorator against the expected `(value, context) => …` shape
/// for its position and emit TS1238/1240/1241 when no call signature fits
/// (tsc: "Unable to resolve signature of … decorator when called as an
/// expression."). Policy: under-report freely, never a false positive —
/// generic decorators and any/unknown parameter types are always accepted,
/// and the `value`/`context` relations run only where a mismatch is
/// unambiguous.
pub fn checkDecoratorSig(c: *Checker, deco: Node, dt: TypeId, pos: DecoPos, value: TypeId) Error!void {
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

    // Expected context interface for this position (null under --noLib →
    // context relation is skipped, value/arity relation still applies).
    const ctx_atom = c.atom(decoContextName(pos)) catch 0;
    const ctx_sym: ?SymbolId = if (ctx_atom != 0) c.prog.globals.lookup(ctx_atom) else null;

    for (sigs.items) |sig| {
        if (try c.decoSigMatches(sig, pos, value, ctx_sym)) return; // some overload fits
    }
    const expr = c.tree.nodeData(deco).lhs;
    const span = if (expr != null_node) c.nodeSpan(expr) else c.nodeSpan(deco);
    try c.diagFmt(decoCode(pos), span, "Unable to resolve signature of {s} decorator when called as an expression.", .{switch (pos) {
        .class => "class",
        .field, .accessor => "property",
        .method, .getter, .setter => "method",
    }});
}

/// Does one decorator call signature accept the runtime `(value, context)`
/// call? Conservative: a generic signature or any indeterminate parameter
/// is treated as a match (under-report, never a false positive).
pub fn decoSigMatches(c: *Checker, sig: TypeId, pos: DecoPos, value: TypeId, ctx_sym: ?SymbolId) Error!bool {
    // Generic decorators need inference we don't model here — accept.
    if (c.ts.fnTypeParams(sig).len > 0) return true;
    // The runtime invokes a decorator with 2 arguments; a signature that
    // *requires* more can never resolve (tsc: "expects N").
    if (try c.requiredParams(sig) > 2) return false;
    // Value argument vs the first parameter.
    if (try c.paramTypeAt(sig, 0)) |p0| {
        if (!try c.decoAcceptsValue(pos, value, p0)) return false;
    }
    // Context argument vs the second parameter: fail only on an
    // unambiguous decorator-context kind mismatch.
    if (ctx_sym != null) {
        if (try c.paramTypeAt(sig, 1)) |p1| {
            if (c.decoContextMismatch(p1, ctx_sym.?)) return false;
        }
    }
    return true;
}

/// True if `value` is acceptable as the first decorator argument for `p0`.
/// Permissive supertypes (`any`/`unknown`/`object`/`Function`, a matching
/// context/target ref, or a constructor-typed parameter for a class
/// decorator) are accepted without an assignability probe so an incomplete
/// relation cannot produce a false positive.
pub fn decoAcceptsValue(c: *Checker, pos: DecoPos, value: TypeId, p0: TypeId) Error!bool {
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
pub fn decoContextMismatch(c: *Checker, p1: TypeId, ctx_sym: SymbolId) bool {
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
