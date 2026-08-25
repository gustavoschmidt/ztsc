//! Call checking: a call's shape, overload resolution, argument matching and
//! the diagnostics that come out of it. The type-argument inference such a
//! call needs lives in `infer.zig` and is re-exported below.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const paths = @import("../link/paths.zig");
const modules = @import("../link/modules.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const Span = source.Span;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const ModuleRef = @import("typenode.zig").ModuleRef;
const identity = @import("identity.zig");
const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const NonArrayRest = @import("typenode.zig").NonArrayRest;
const tuple_relate = @import("tuple_relate.zig");
const accessibility = @import("accessibility.zig");
const classes = @import("classes.zig");
const ambientNamespaceType = @import("signatures.zig").ambientNamespaceType;
const ChainLink = @import("expr.zig").ChainLink;
const checkExprCached = @import("expr.zig").checkExprCached;
const expr_zig = @import("expr.zig");
const freshLiteralRejects = @import("assign.zig").freshLiteralRejects;
const instantiate = @import("enums.zig").instantiate;
const isAssignable = @import("assign.zig").isAssignable;
const memberList = @import("typenode.zig").memberList;
const resolveStructural = @import("instantiate.zig").resolveStructural;
const rollbackDiags = Checker.rollbackDiags;
const scratch = Checker.scratch;
const transitiveBaseConstraint = @import("assign.zig").transitiveBaseConstraint;

// =====================================================================
// calls
// =====================================================================

pub const CallShape = struct {
    callee: Node,
    targ_nodes: []const Node = &.{},
    arg_nodes: []const Node = &.{},
    optional: bool = false,
};

pub fn callShape(c: *Checker, node: Node) CallShape {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .call_expr, .new_expr => {
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            return .{ .callee = d.lhs, .arg_nodes = c.tree.extraRange(r.start, r.end) };
        },
        .call_expr_targs, .new_expr_targs, .optional_call => {
            const info = c.tree.extraData(ast.CallInfo, d.rhs);
            return .{
                .callee = d.lhs,
                .targ_nodes = c.tree.extraRange(info.targs_start, info.targs_end),
                .arg_nodes = c.tree.extraRange(info.args_start, info.args_end),
                .optional = c.nodeTag(node) == .optional_call,
            };
        },
        .new_expr_bare => return .{ .callee = d.lhs },
        else => return .{ .callee = d.lhs },
    }
}

/// The function expression a call IMMEDIATELY INVOKES, or `null_node` — tsc's
/// `getImmediatelyInvokedFunctionExpression`, read from the call side.
///
/// tsc walks UP from the parameter (`parameter.parent.parent`, through
/// parentheses); ztsc records no parent pointers, so the fact has to be
/// established here, where the call and its arguments are in hand, and handed
/// down as the callee's contextual type (`iifeContextualSig`).
///
/// Parenthesized both ways: `(function (x) {} ("!"))` parenthesizes the CALL —
/// so the callee is the function expression itself — while
/// `((((function (y) {}))))("-")` parenthesizes the CALLEE, and every
/// syntactic question about a value looks through those (`skipParens`).
fn iifeCallee(c: *Checker, callee: Node) Node {
    const f = expr_zig.skipParens(c, callee);
    if (f == null_node) return null_node;
    return switch (c.nodeTag(f)) {
        .arrow_fn, .function_expr => f,
        else => null_node,
    };
}

/// tsc's `getContextuallyTypedParameterType`, IIFE arm — packaged as a
/// synthetic contextual SIGNATURE so the ordinary contextual-parameter
/// machinery (`paramInfo` → `paramTypeAt` / `restTupleAtPosition`) reads it:
///
/// ```ts
/// const iife = getImmediatelyInvokedFunctionExpression(func);
/// if (iife && iife.arguments) {
///     const args = getEffectiveCallArguments(iife);
///     const indexOfParameter = func.parameters.indexOf(parameter);
///     if (parameter.dotDotDotToken) {
///         return getSpreadArgumentType(args, indexOfParameter, args.length, anyType, undefined, CheckMode.Normal);
///     }
///     const type = indexOfParameter < args.length ?
///         getWidenedLiteralType(checkExpression(args[indexOfParameter])) :
///         parameter.initializer ? undefined : undefinedWideningType;
///     return type;
/// }
/// ```
///
/// An IIFE's parameters are therefore NEVER implicit `any`: each one takes the
/// widened type of the argument at its position, a trailing rest takes the
/// remaining arguments as a tuple, and a parameter past the last argument is
/// `undefined` (unless it has an initializer, which then supplies it). ztsc had
/// no IIFE rule at all, so every unannotated parameter of one fell to implicit
/// `any` — the whole of `contextuallyTypedIifeStrict` and three quarters of
/// `restTuplesFromContextualTypes`.
///
/// The signature is built as a single rest parameter typed by the ARGUMENT
/// TUPLE, which is what makes the two readings fall out of the existing
/// helpers: `paramTypeAt` indexes the tuple for a positional parameter and
/// `restTupleAtPosition` slices its tail for a rest one — the latter being
/// exactly `getSpreadArgumentType(args, i, args.length, …)`. A SPREAD argument
/// contributes its tuple's elements (or rides as one variadic element when its
/// type has no fixed shape), which is `getEffectiveCallArguments` expanding a
/// spread into synthetic expressions.
///
/// `no_type` for anything that is not an IIFE — including every `new` — and
/// the return type is deliberately `no_type` too: an IIFE has no contextual
/// RETURN type in tsc, and `checkFunctionLikeExpr` reads the contextual
/// signature's return as one.
fn iifeContextualSig(c: *Checker, shape: CallShape) Error!TypeId {
    const fnode = iifeCallee(c, shape.callee);
    if (fnode == null_node) return types.no_type;
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    // The arguments are typed OUT of the checker's top-down order here — the
    // authoritative walk types each of them again, against the parameter this
    // very signature is about to give the callee — so the pre-pass runs as a
    // side query: no diagnostic, no `node_types` entry. tsc reaches the same
    // place by parking `anySignature` on the call's node links while it types
    // one argument, so the resolution it is nested inside cannot recurse.
    c.side_query_depth += 1;
    defer c.side_query_depth -= 1;
    for (shape.arg_nodes) |an| {
        if (an == null_node) continue;
        if (c.nodeTag(an) == .spread_element) {
            const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(an).lhs, types.no_type));
            if (c.ts.kind(st) == .tuple) {
                for (0..c.ts.tupleLen(st)) |i| try elems.append(c.scratch(), c.ts.tupleElem(st, @intCast(i)));
            } else {
                // No fixed shape (an array, a bare type parameter): one
                // variadic element standing for the whole spread, which is
                // `getSpreadArgumentType`'s `ElementFlags.Variadic` push.
                try elems.append(c.scratch(), .{ .ty = st, .flags = types.elem_flag_rest });
            }
            continue;
        }
        try elems.append(c.scratch(), .{
            .ty = try c.widenLiteral(try c.checkExprCached(an, types.no_type)),
        });
    }
    // `undefinedWideningType` for each parameter past the last argument. The
    // padding stops at the first parameter that has an INITIALIZER, which tsc
    // hands no contextual type at all so its default supplies the type
    // (`((n = 10) => n + 1)()` is `number`, not `never`), and at a rest
    // parameter, whose empty tail `restTupleAtPosition` already answers.
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fnode).lhs);
    const argc = elems.items.len;
    var pi: usize = 0;
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        if (pn == null_node) continue;
        defer pi += 1;
        if (pi < argc) continue;
        if (c.nodeTag(pn) == .param_full) {
            const e = c.tree.extraData(ast.ParamFull, c.tree.nodeData(pn).rhs);
            if (e.init != 0 or e.flags & ast.Flags.rest != 0) break;
        }
        try elems.append(c.scratch(), .{ .ty = types.undefined_type });
    }
    const tup = try c.ts.makeTuple(elems.items);
    return c.ts.makeFunction(
        &.{.{ .name = 0, .ty = tup, .flags = types.param_flag_rest }},
        types.no_type,
        &.{},
        0,
    );
}

/// `import("m")` in *expression* position: `Promise<<namespace object of
/// m>>`, tsc's `getTypeOfImportCall`. The specifier resolves through the
/// same two registries the type-position `import("m")` uses — the current
/// file's specifier map, then the ambient `declare module` registry — and
/// the namespace object is the same one `import * as ns from "m"` gets, so
/// an `export =` module reaches its export-assigned entity.
///
/// Everything else is `Promise<any>` — a missing argument, a non-literal
/// specifier (tsc cannot resolve it either), and an unresolved module
/// (already TS2307 at the statement level, or deliberately opaque). Every
/// exit from tsc's `checkImportCallExpression` goes through
/// `createPromiseReturnType(node, …)`, so the payload degrades but the
/// promise does not: `import(getSpecifier()).then(zero => …)` still types
/// `zero` from `Promise<any>.then`, where a bare `any` callee leaves the
/// callback's parameters implicitly `any`
/// (`importCallExpressionReturnPromiseOfAny`, `dynamicImportDefer`,
/// `importCallExpressionShouldNotGetParen`). A program with no lib has no
/// global `Promise` to wrap with and stays `any` (`makePromise`). No
/// diagnostic is reported here — resolution failures belong to the resolver.
fn importCallType(c: *Checker, arg_nodes: []const Node) Error!TypeId {
    if (arg_nodes.len == 0) return c.makePromise(types.any_type);
    const spec_node = arg_nodes[0];
    // A no-substitution template literal is a literal specifier too, and the
    // binder registers it as a dependency (`bindDynamicImport`); `memberAtom`
    // only strips quotes, so the backticked form needs `templateAtom`.
    const spec = switch (c.nodeTag(spec_node)) {
        .string_literal => try c.memberAtom(c.tree.nodeMainToken(spec_node)),
        .template_literal => try c.templateAtom(c.tree.nodeMainToken(spec_node)),
        else => return c.makePromise(types.any_type),
    };
    var m: ModuleRef = blk: {
        if (c.prog.files.len != 0) {
            if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| break :blk .{ .file = mfile };
        }
        break :blk .{ .ambient = c.ambientIndex(spec) orelse return c.makePromise(types.any_type) };
    };
    // A JS-only dependency resolves to a file ztsc loads as a synthetic
    // opaque `any` module. An ambient `declare module "m"` that describes it
    // wins — the same precedence `linkImports` gives a named import, which
    // falls through to the ambient registry when the resolved file has
    // nothing to offer. `image-blob-reduce` ships no types and is declared
    // in the app's `global.d.ts`.
    if (m == .file and (try c.namespaceObjectType(m.file)) == types.any_type) {
        if (c.ambientIndex(spec)) |idx| m = .{ .ambient = idx };
    }
    var inner: TypeId = switch (m) {
        .file => |f| try c.namespaceObjectType(f),
        .ambient => |idx| try c.ambientNamespaceType(idx),
    };
    // A CommonJS module (`export = x`) has no `default` of its own, and the
    // namespace object ztsc builds for one *is* the export-assigned entity.
    // Under module interop tsc still hands `import("m")` a `default` — that
    // is how `import("pica").then((res) => res.default)` reaches pica. tsc
    // spreads `{ default: T }` over the module type; the intersection has
    // the same members.
    var wrapped = false;
    if (c.prog.export_equals_atom != 0) {
        if (c.moduleExportTarget(m, c.prog.export_equals_atom)) |eq| {
            if (!eq.type_only) {
                // An ambient `export =` never reached `ambientNamespaceType`
                // (it skips the reserved key), so take the entity here.
                const entity = switch (m) {
                    .file => inner,
                    .ambient => try c.targetValueType(eq),
                };
                const wrapper = try c.ts.makeObject(&.{.{ .name = c.atom_default, .ty = entity, .flags = types.prop_flag_readonly }}, 0, 0, 0);
                inner = try c.ts.makeIntersection(c.scratch(), &.{ entity, wrapper });
                wrapped = true;
            }
        }
    }
    // tsc's `getTypeWithSyntheticDefaultImportType`: under
    // allowSyntheticDefaultImports a module that declares no `default` of its
    // own still hands `import("m")` one — the module namespace object itself
    // — spread over the module type. Same rule `linkImports` applies to a
    // STATIC default import, and gated the same way: only a DECLARATION file
    // (or an ambient `declare module` block, which only ever appears in one)
    // qualifies, because a real source file carrying ES-module syntax is
    // known not to have a default and tsc reports TS1192 there.
    //
    // `(await import('@emoji-mart/data')).default` is the shape: an
    // `index.d.ts` of nothing but interfaces, whose `default` was a false
    // TS2339 on the empty namespace object.
    if (!wrapped and c.prog.allow_synthetic_default and c.atom_default != 0 and
        c.moduleExportTarget(m, c.atom_default) == null)
    {
        const eligible = switch (m) {
            .file => |f| paths.isDeclarationPath(c.prog.files[f].path),
            .ambient => true,
        };
        if (eligible) {
            const wrapper = try c.ts.makeObject(&.{.{ .name = c.atom_default, .ty = inner, .flags = types.prop_flag_readonly }}, 0, 0, 0);
            inner = try c.ts.makeIntersection(c.scratch(), &.{ inner, wrapper });
        }
    }
    return c.makePromise(inner);
}

/// The construct signatures a `super(…)` call resolves against, appended to
/// `out`; false when there is no base class to read them off (the call is then
/// left as untyped as it was before).
///
/// tsc's `resolveCallExpression` never treats `super` as a value in call
/// position: it takes the containing class's base constructor type and resolves
/// against `getInstantiatedConstructorsForTypeArguments(superType,
/// baseTypeNode.typeArguments)`. ztsc types the `super` KEYWORD as `any`
/// (`checkExpr`'s `.super_expr` arm), which made every `super(…)` an UNTYPED
/// call — its arguments checked with no contextual type at all.
///
/// social-app's `class BskyAppAgent extends AtpAgent { constructor({service}) {
/// super({ service, async fetch(...args) {…} }) } }` is the cost: the object
/// literal never saw `AtpAgentOptions`, so the `fetch` method never saw
/// `typeof globalThis.fetch` and its rest parameter was an implicit any.
///
/// The return type is replaced with `void` — a super call is a statement, and
/// the base constructor's declared return (the instance) is not its value.
fn superCtorSigs(c: *Checker, out: *std.ArrayList(TypeId)) Error!bool {
    const cls = c.ctor_class_sym;
    if (cls == binder.no_symbol) return false;
    const base_ref = (try c.baseClassRef(cls)) orelse return false;
    const base_sym = c.ts.refSymbol(base_ref);
    var raw: std.ArrayList(TypeId) = .empty;
    defer raw.deinit(c.scratch());
    try c.ctorSignatures(base_sym, &raw);
    if (raw.items.len == 0) return false;
    // The heritage arguments the `extends` clause wrote, exactly as
    // `ctorSignatures` composes them one level down.
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(base_sym, &tps);
    const map = try c.scratch().alloc(TpMap, tps.items.len);
    for (tps.items, 0..) |tp, i| map[i] = .{
        .sym = tp.sym,
        .ty = if (i < c.ts.refArgCount(base_ref)) c.ts.refArgAt(base_ref, i) else types.any_type,
    };
    for (raw.items) |sig0| {
        const sig = if (map.len > 0) try c.instantiate(sig0, map) else sig0;
        try out.append(c.scratch(), try c.sigWithReturn(sig, types.void_type));
    }
    return true;
}

pub fn checkCallExpr(c: *Checker, node: Node, is_new: bool, ctx: TypeId) Error!TypeId {
    const link = try c.checkCallExprInner(node, is_new, ctx);
    if (link.chained) return c.makeUnion2(link.ty, types.undefined_type);
    return link.ty;
}

/// TS2347 — the one thing an UNTYPED call may not do. tsc's
/// `resolveCallExpression` guards every route into `resolveUntypedCall` with
/// it:
///
///     if (node.typeArguments) {
///         error(node, Diagnostics.Untyped_function_calls_may_not_accept_type_arguments);
///     }
///     return resolveUntypedCall(node);
///
/// so it fires on all three shapes that reach `resolveUntypedCall` — an `any`
/// callee, a callee whose type IS the global `Function`, and one that merely
/// relates to it (`untypedFunctionCall`) — and nowhere else. The error node is
/// the whole call, which is why `new x<any>(x)` is blamed on `new` and not on
/// `x` (`anyAsConstructor`).
///
/// `declared_any` is tsc's `funcType !== errorType` guard, which only the `any`
/// route needs: see `anyCalleeIsDeclared`. The two `Function` routes cannot
/// reach an error type at all — a callee that RELATES to `Function` has a real
/// type by construction.
fn reportUntypedTypeArgs(c: *Checker, node: Node, shape: CallShape, declared_any: bool) Error!void {
    if (shape.targ_nodes.len == 0) return;
    if (declared_any and !try anyCalleeIsDeclared(c, shape.callee)) return;
    try c.diagFmt(2347, c.nodeSpan(node), "Untyped function calls may not accept type arguments.", .{});
}

/// tsc's guard on the diagnostic above: `funcType !== errorType`. tsc reaches
/// `resolveUntypedCall` for the error type as well as for a real `any`, and
/// reports TS2347 only for the latter — the error type means something has
/// already been said about this callee, and a second complaint would be a
/// cascade.
///
/// ztsc has no such split: an unresolved name, an unlinked import binding and
/// a `const` still being inferred all answer `any`, because `error_type`
/// suppresses far more of the checker than tsc's does. So the distinction is
/// re-derived SYNTACTICALLY, from the callee's own declaration:
///
///   * a plain name is a declared `any` when its declaration WRITES a type
///     (`declare var anyVar: any`, `var x: any`). An unresolved name, an
///     import binding whose module did not link (social-app's `new
///     Kysely<DbSchema>(…)`, where tsgo also fails to resolve `kysely` and
///     reports only the TS2307) and an un-annotated `const` mid-inference
///     (`declarationsWithRecursiveInternalTypesProduceUniqueTypeParams`'s
///     recursive `reduce<Value<K, U>>(…)`) all write none;
///   * a property access is a declared `any` when its RECEIVER has a real
///     member table to have read the property off — `Foo.Bar<T>()` on an
///     undeclared `Foo` does not (`parserMemberAccessExpression1`), while
///     `this.foo<string>()` against `private foo: any` does.
///
/// Anything else — `super<T>()`, a call result, an element access — answers
/// false: the shapes that reach here with a genuine declared `any` are these
/// two, and silence is the side that invents nothing.
fn anyCalleeIsDeclared(c: *Checker, callee: Node) Error!bool {
    var n = callee;
    while (c.nodeTag(n) == .paren_expr or c.nodeTag(n) == .non_null) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(n));
            // `resolveSpace` already answers with a GLOBAL id (merged where the
            // name is a cross-file merge constituent) — no `toGlobal` here.
            const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sy| sy,
                else => return false,
            };
            return symWritesTypeAnnotation(c, sym);
        },
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(n);
            const recv = try c.resolveStructural(try c.checkExprCached(d.lhs, types.no_type));
            switch (c.ts.kind(recv)) {
                .any, .err, .unknown, .never => return false,
                else => {},
            }
            return (try c.propOfType(recv, try c.memberAtom(d.rhs))) != null;
        },
        else => return false,
    }
}

/// Does any declaration of `sym` WRITE a type? The three shapes that can carry
/// one and also produce a callable `any`; every other declaration form (an
/// import specifier, an un-annotated declarator, a binding element) writes
/// none, which is the answer this needs.
fn symWritesTypeAnnotation(c: *Checker, sym: SymbolId) bool {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        switch (c.nodeTag(decl)) {
            .declarator_full => return true,
            .class_field => {
                if (c.tree.extraData(ast.Field, c.tree.nodeData(decl).lhs).type_ann != 0) return true;
            },
            .property_signature => {
                if (c.tree.nodeData(decl).lhs != 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// tsc's `resolveCallExpression` when the callee carries no CALL signatures:
///
///     if (!callSignatures.length) {
///         if (numConstructSignatures) {
///             error(node, Diagnostics.Value_of_type_0_is_not_callable_Did_you_mean_to_include_new,
///                   typeToString(funcType));
///         }
///         else { error(node, Diagnostics.This_expression_is_not_callable); }
///     }
///
/// A value that CONSTRUCTS and does not call is a forgotten `new`, and tsc
/// says so: `C()` on a class, `Tools.NullLogger()` (`forgottenNew`), and
/// `v2(args)` on a `new (arg: T) => Date` read out of an index signature
/// (`genericConstructorFunction1`) are all TS2348 where ztsc had the generic
/// TS2349. The message names the callee's OWN type — tsc prints `funcType`,
/// not its resolved structure, so `typeof C` and `I1<T>` rather than the
/// member tables they expand to.
fn reportNotCallable(c: *Checker, shape: CallShape, callee_t: TypeId, r: TypeId) Error!void {
    const constructs = switch (c.ts.kind(r)) {
        .object => c.ts.objectConstructSigCount(r) != 0,
        // A CLASS value is `numConstructSignatures > 0` by construction — the
        // declared constructor, or the implicit one every class has. A
        // NAMESPACE object is a `.class_value` here too (that is how ztsc
        // models `typeof N`), and it constructs nothing: calling one is the
        // plain TS2349 (`typeOnlyMerge3`, `valuesMergingAcrossModules`).
        .class_value => c.symFlags(c.ts.classSymbol(r)).class,
        else => false,
    };
    if (constructs) {
        try c.diagFmt(2348, c.nodeSpan(shape.callee), "Value of type '{s}' is not callable. Did you mean to include 'new'?", .{
            try c.typeToString(callee_t),
        });
        return;
    }
    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
}

/// tsc's `isUntypedFunctionCall`, minus its two `any` disjuncts:
///
///     !numCallSignatures && !numConstructSignatures &&
///     !(apparentFuncType.flags & TypeFlags.Union) &&
///     !(getReducedType(apparentFuncType).flags & TypeFlags.Never) &&
///     isTypeAssignableTo(funcType, globalFunctionType)
///
/// A callee that carries no signatures of its own but IS assignable to the
/// global `Function` is an untyped call: `resolveCallExpression` hands it to
/// `resolveUntypedCall`, which types it `any` and reports nothing. The named
/// fast path above catches a callee whose type is literally the `Function`
/// reference; this catches everything that only *relates* to it — a type
/// parameter constrained by `Function` (React's `useEvent` idiom) or by an
/// interface that extends it.
///
/// Only reached on the paths that were about to report TS2349, so the
/// assignability probe costs nothing on a well-typed call. The construct-side
/// exclusions are tsc's `!numConstructSignatures`: a class value (`typeof C`)
/// is assignable to `Function` but calling it is TS2348, not an untyped call.
fn untypedFunctionCall(c: *Checker, callee_t: TypeId, apparent: TypeId, ak: types.Kind) Error!bool {
    if (ak == .union_type or ak == .never or ak == .class_value) return false;
    if (ak == .object and c.ts.objectConstructSigCount(apparent) != 0) return false;
    const sym = c.prog.globals.lookup(c.atom_Function) orelse return false;
    if (!c.symFlags(sym).interface) return false;
    return c.isAssignable(callee_t, try c.ts.makeRef(sym, &.{}));
}

/// Does a `new` target that carries no CONSTRUCT signature carry a CALL one?
/// tsc's `resolveNewExpression` falls back to those, which turns TS2351 into
/// TS7009 — see the arm in the `new` dispatch, its only caller. An INTERSECTION
/// is deliberately absent: its call signatures are gathered separately
/// (`isect_sigs`) and the construct arm above already consumed the shape.
fn newTargetIsCallable(c: *const Checker, apparent: TypeId) bool {
    return switch (c.ts.kind(apparent)) {
        .function, .overloads => true,
        .object => c.ts.objectCallSigCount(apparent) > 0,
        else => false,
    };
}

/// Is the callee a NAME whose declared type is `never`, as opposed to a name
/// the flow narrowed to `never`? See the `.never` arm of the call dispatch,
/// which is the only caller.
fn declaredNeverCallee(c: *Checker, callee: Node) Error!bool {
    if (callee == null_node or c.nodeTag(callee) != .identifier) return false;
    const sym = switch (c.resolveSpace(try c.atomOfToken(c.tree.nodeMainToken(callee)), c.cur_scope, true)) {
        .sym => |s| s,
        else => return false,
    };
    return c.ts.kind(try c.resolveStructural(try c.typeOfSymbol(sym))) == .never;
}

/// Which of tsc's three "cannot invoke a possibly-nullish object" diagnostics a
/// callee type earns, or null when it is not nullish at all.
const NullishCallee = enum {
    null_only,
    undefined_only,
    both,

    fn number(k: NullishCallee) u16 {
        return switch (k) {
            .null_only => 2721,
            .undefined_only => 2722,
            .both => 2723,
        };
    }
    fn text(k: NullishCallee) []const u8 {
        return switch (k) {
            .null_only => "'null'",
            .undefined_only => "'undefined'",
            .both => "'null' or 'undefined'",
        };
    }
};

/// tsc's `getFalsyFlags(type) & TypeFlags.Nullable` for a callee.
///
/// `void` is deliberately NOT nullish here: `TypeFlags.Nullable` is
/// `Undefined | Null` and nothing else, so `let e: (() => void) | void; e()`
/// is the ordinary TS2349 with a "Type 'void' has no call signatures."
/// elaboration — oracled both ways. That is why this cannot reuse
/// `containsUndefinedish`, which folds `void` in for the member-access rules.
fn nullishCallee(c: *Checker, t: TypeId) ?NullishCallee {
    const has_null = c.containsNull(t);
    const has_undef = c.unionAnyMember(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) == .undefined;
        }
    }.f);
    if (has_null and has_undef) return .both;
    if (has_null) return .null_only;
    if (has_undef) return .undefined_only;
    return null;
}

/// Call/new as an optional-chain link (see `memberChainInner`). Answers the
/// return type WITHOUT the chain's short-circuit `undefined`, plus `chained`
/// when this `?.()` — or an earlier link in the callee spine — short-circuits
/// on a nullish callee.
pub fn checkCallExprInner(c: *Checker, node: Node, is_new: bool, ctx: TypeId) Error!ChainLink {
    var chained = false;
    const shape = c.callShape(node);
    // tsc answers an INACCESSIBLE constructor with `return
    // resolveErrorCall(node)`, so nothing the resolution would have said
    // about the call survives — no arity, no per-argument diagnostic. The
    // oracle keeps the RESULT type though (see `constructorCheck`'s call
    // site), so ztsc resolves the call as usual and withdraws only the
    // resolution's own verdicts about it, filed anywhere inside the call.
    var ctor_denied_at: ?usize = null;
    defer if (ctor_denied_at) |saved| {
        const call_span = c.nodeSpan(node);
        c.rollbackDiags(saved, .{
            .file = c.cur_file,
            .lo = call_span.start,
            .hi = call_span.end,
            .codes = &resolve_verdict_codes,
        });
    };
    // `import("m")` is not an ordinary call — `import` has no type of its
    // own. tsc's `getTypeOfImportCall`: the module's namespace object,
    // wrapped in `Promise`.
    if (!is_new and c.nodeTag(shape.callee) == .import_expr) {
        return .{ .ty = try importCallType(c, shape.arg_nodes), .chained = chained };
    }
    // A super CALL's callee is never typed as a value (tsc's
    // `resolveCallExpression` resolves against the base's construct signatures
    // instead — see below), and `checkExpr`'s `.super_expr` arm — which would
    // answer `any` here anyway — carries the TS2335 that a super call's own
    // TS2337 supersedes. Routing past it keeps the two mutually exclusive, as
    // `checkSuperExpression`'s early return does.
    const super_call = !is_new and c.nodeTag(shape.callee) == .super_expr;
    var callee_t = if (super_call)
        types.any_type
    else if (c.isOptionalChain(shape.callee)) blk: {
        const link = try c.chainObjType(shape.callee);
        if (link.chained) chained = true;
        break :blk link.ty;
    } else try c.checkExprCached(shape.callee, if (is_new)
        types.no_type
    else
        try iifeContextualSig(c, shape));
    if (shape.optional) {
        if (c.containsNullish(callee_t)) chained = true;
        callee_t = try c.nonNullableChain(callee_t);
    }
    // tsc's `resolveCallExpression`, before anything is resolved:
    //
    //     funcType = checkNonNullTypeWithReporter(funcType, node.expression,
    //         reportCannotInvokePossiblyNullOrUndefinedError);
    //
    // A possibly-nullish CALLEE has its own three diagnostics rather than the
    // generic "not callable", and the call stops right there: the reporter's
    // `getNonNullableType` answers `errorType` when nothing is left, and
    // `resolveCallExpression` returns `resolveErrorCall(node)` for it. Without
    // this every `a()` on `(() => void) | undefined` was a TS2349.
    // …and `checkNonNullTypeWithReporter`'s own head runs ahead of that, for
    // `new` as much as for a call: an `unknown` callee is TS18046 naming it
    // (TS2571 when it has no name to print), not the generic "not
    // callable"/"not constructable" the resolve below would reach. Both are
    // reported today, so this only re-codes a diagnostic that already exists
    // — see `reportUnknownOperand` for why the general gate stays out.
    if (c.nodeTag(shape.callee) != .super_expr and try expr_zig.reportUnknownOperand(c, callee_t, shape.callee)) {
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return .{ .ty = types.error_type, .chained = chained };
    }
    if (!is_new and !shape.optional and c.nodeTag(shape.callee) != .super_expr) {
        if (nullishCallee(c, callee_t)) |code| {
            try c.diagFmt(code.number(), c.nodeSpan(shape.callee), "Cannot invoke an object which is possibly {s}.", .{code.text()});
            callee_t = try c.nonNullable(callee_t);
            if (c.ts.kind(callee_t) == .never or c.containsNullish(callee_t)) {
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return .{ .ty = types.error_type, .chained = chained };
            }
        }
    }
    var r = try c.resolveStructural(callee_t);
    var rk = c.ts.kind(r);
    // Calling a naked type parameter resolves against its APPARENT type.
    // `resolveStructural` deliberately leaves a `.type_param` alone (that
    // is `transitiveBaseConstraint`'s job), so every
    // `<T extends (…) => R>(fn: T) => fn(…)` — the useStableCallback shape
    // — fell to the switch's `else` and reported TS2349. tsc's
    // `resolveCallExpression` calls `getApparentType` on the callee first.
    // The callee's APPARENT type, before `resolveStructural` expands an
    // interface reference into its member table — the only form in which the
    // global `Function` is still recognisable by name (see the untyped-call
    // special case below).
    var apparent_t = callee_t;
    if (rk == .type_param) {
        const bc = try c.transitiveBaseConstraint(r);
        if (bc != r) {
            apparent_t = bc;
            r = try c.resolveStructural(bc);
            rk = c.ts.kind(r);
        }
    }
    // `super(…)` is not a call on a value. tsc's `resolveCallExpression`
    // special-cases it and resolves against the BASE class's construct
    // signatures (`getInstantiatedConstructorsForTypeArguments(superType,
    // baseTypeNode.typeArguments)`) — see `superCtorSigs`.
    var super_sigs: std.ArrayList(TypeId) = .empty;
    defer super_sigs.deinit(c.scratch());
    if (super_call) {
        // TS2337 — tsc's `checkSuperExpression`: a super CALL is permitted only
        // when its container (`getSuperContainer(node, /*stopOnFunctions*/
        // true)`, so arrows count) is a constructor. A `super()` in a field
        // initializer, in a static field, in an arrow or function expression
        // inside the constructor, or in an object-literal accessor there is
        // this error — except inside a computed property NAME, where
        // `getSuperContainer` steps over the owning member entirely and TS2466
        // is the answer instead (`computedPropertyNames30`; see
        // `Checker.in_computed_key`).
        //
        // The arguments are still resolved against the base constructor below,
        // which is where any further diagnostic about them comes from.
        //
        // A WRITTEN type-argument list takes BOTH of these checks out
        // entirely: `super<T>(0)` is TS2754 and nothing else — not the TS2337
        // its container earns, not the TS2335 its class earns, and not even
        // the TS2304 an unresolvable `T` would earn anywhere else
        // (tsgo-verified on `parserSuperExpression2`, whose `T` is undeclared
        // and unreported).
        if (!c.in_computed_key) {
            if (shape.targ_nodes.len != 0) {
                try c.diagFmt(2754, typeArgListSpan(c, shape.targ_nodes, node), "'super' may not use type arguments.", .{});
            } else if (!c.in_ctor_body) {
                try c.diagFmt(2337, c.nodeSpan(shape.callee), "Super calls are not permitted outside constructors or in nested functions inside constructors.", .{});
            } else {
                // …and TS2335 once the container IS legal: a class that writes
                // no `extends` has no `super` to call. tsc's
                // `checkSuperExpression` returns `errorType` at either one, so
                // exactly one of the two is ever reported.
                _ = try classes.reportSuperWithoutBase(c, shape.callee);
            }
        }
        if (try superCtorSigs(c, &super_sigs)) {
            r = if (super_sigs.items.len == 1)
                super_sigs.items[0]
            else
                try c.ts.makeOverloads(super_sigs.items);
            rk = c.ts.kind(r);
        }
    }
    // An INTERSECTION callee is one OVERLOAD SET. tsc's
    // `resolveIntersectionTypeMembers` concatenates every constituent's
    // call signatures, in member order, into a single list that the call
    // then resolves against — first match wins. Taking one constituent's
    // signatures and discarding the rest silently halved the overload set
    // wherever two constituents are both callable: `window.clearTimeout`
    // (`Window & typeof globalThis`, where the global half carries
    // @types/node's `Timeout`-accepting overload and the `Window` half
    // only lib.dom's `number` one), or a class intersected with an object
    // literal that re-declares a method with a narrower signature.
    //
    // `new` keeps the pick-one rule: a `.class_value` constituent needs
    // the class-value path below (class type-argument inference and the
    // `instance_ret` override), which is not a signature list.
    var isect_sigs: std.ArrayList(TypeId) = .empty;
    defer isect_sigs.deinit(c.scratch());
    var isect_any = false;
    // Whether `isect_sigs` already holds the intersection's construct signatures
    // under tsc's MIXIN rule (see `mixinCtorSigs`), in which case the pick-one
    // gather below is skipped and the `is_new` dispatch resolves against them.
    var mixin_new = false;
    var mixin_abstract = false;
    if (rk == .intersection and is_new) {
        mixin_new = try mixinCtorSigs(c, r, &isect_sigs, &mixin_abstract);
    }
    if (rk == .intersection and !mixin_new) {
        for (try c.memberList(r)) |m| {
            const rm = try c.resolveStructural(m);
            const mk = c.ts.kind(rm);
            if (is_new) {
                // A merged/curried callable can present its construct
                // signatures on an OBJECT member (an interface with
                // call/construct sigs), not only as a `.class_value`.
                if (mk == .class_value or (mk == .object and c.ts.objectConstructSigCount(rm) > 0)) {
                    r = rm;
                    rk = mk;
                    break;
                }
                continue;
            }
            switch (mk) {
                .any, .err => isect_any = true,
                .function => try isect_sigs.append(c.scratch(), rm),
                .overloads => try c.appendOverloadCandidates(&isect_sigs, rm),
                // An object member carrying call signatures — e.g. RTK's
                // `createAsyncThunk: CreateAsyncThunkFunction<C> & { withTypes }`,
                // whose callable arm is an interface with a call signature.
                .object => try c.appendObjectCallCandidates(&isect_sigs, rm),
                else => {},
            }
        }
    }
    // …unless the `err` is only ztsc's in-progress marker for a class whose
    // member table is being built further down this stack. Nothing has been
    // reported there, and the DECLARATIONS still settle this particular
    // question: a class body has no call-signature syntax, so unless an
    // `interface` half supplies one the instance is not callable
    // (`classes.inProgressCallSigless`). Without it `class D { m() { return
    // this(); } }` said nothing while the annotated `m(): void` form reported
    // TS2349 — the same call, and the difference was only whether the return
    // type was inferred, which is what held the table open.
    if (rk == .err and !is_new and !super_call and try classes.inProgressCallSigless(c, callee_t)) {
        try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return .{ .ty = types.error_type, .chained = chained };
    }
    if (rk == .any or rk == .err or isect_any) {
        // The `any` route into `resolveUntypedCall` (see there): an `err`
        // callee has already been reported on, and a super CALL's written
        // type-argument list is TS2754's business, not this one.
        if (rk == .any and !super_call) try reportUntypedTypeArgs(c, node, shape, true);
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return .{ .ty = if (rk == .err) types.error_type else types.any_type, .chained = chained };
    }
    // Calling a value of the global `Function` type: tsc treats `Function`
    // as callable, accepting any arguments and yielding `any` (the interface
    // body carries no call signature, so a structural resolve would report
    // TS2349). This is tsc's `isUntypedFunctionCall`'s last disjunct —
    // `!numCallSignatures && !numConstructSignatures && … &&
    // isTypeAssignableTo(funcType, globalFunctionType)` — which
    // `resolveCallExpression` answers with `resolveUntypedCall` (type `any`,
    // no diagnostic). Only for calls — `new (x: Function)` stays unmodeled.
    //
    // The APPARENT type carries it too: `<T extends Function>(fn?: T)` then
    // `fn(...args)` is a call on a type parameter whose base constraint is
    // `Function`, and `T` is assignable to `Function`, so tsc takes the same
    // untyped-call route. Testing only `callee_t` left every such body
    // (React's `useNonReactiveCallback`/`useEvent` idiom) at TS2349.
    if (!is_new and c.ts.kind(apparent_t) == .ref and
        c.globalSymNamed(c.ts.refSymbol(apparent_t), "Function"))
    {
        try reportUntypedTypeArgs(c, node, shape, false);
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return .{ .ty = types.any_type, .chained = chained };
    }

    // Explicit type arguments.
    var targs: std.ArrayList(TypeId) = .empty;
    defer targs.deinit(c.scratch());
    for (shape.targ_nodes) |tn| {
        if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
    }

    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    var instance_ret: TypeId = types.no_type; // for `new C(...)`

    if (is_new) {
        if (mixin_new) {
            // The mixin-resolved overload set, whose returns are already the
            // intersections tsc computes — so no `instance_ret` override.
            if (mixin_abstract) {
                try c.diagFmt(2511, c.nodeSpan(node), "Cannot create an instance of an abstract class.", .{});
            }
            try sigs.appendSlice(c.scratch(), isect_sigs.items);
        } else if (rk == .class_value) {
            const cls = c.ts.classSymbol(r);
            // tsc asks `isConstructorAccessible(node, constructSignatures[0])`
            // ahead of the abstract screen below, and answers a failure with
            // `return resolveErrorCall(node)`. The ORACLE does not follow it
            // all the way: `var c = new C()` on a private constructor still
            // types `c` as `C` there — `c.zzz` is TS2339 on `C` and
            // `var q: number = c` is TS2322 from `C`, neither of which an
            // error type produces. So the report stands alone and the
            // resolution continues for its TYPE — but every VERDICT the
            // resolution reaches about the call is withdrawn afterwards
            // (`ctor_denied_at`), which is the rest of tsgo's behaviour: it
            // files no arity error on top, where ztsc's TS2554 for `new C2()`
            // against `private constructor(x: number)` was an excess key.
            if (!try accessibility.constructorCheck(c, cls, node)) {
                ctor_denied_at = c.diags.items.len;
            }
            if (try c.classIsAbstract(cls)) {
                // tsc's `resolveNewExpression` reports TS2511 and then
                // `return resolveErrorCall(node)`: the arguments are checked
                // with NO contextual type and the call resolves to the error
                // signature, so no arity (TS2554) or per-argument (TS2345)
                // diagnostic follows and the expression's type is the error
                // type. Reporting the arity on top of TS2511 was a false
                // positive wherever an abstract class is `new`-ed with
                // arguments its (often implicit) constructor does not take.
                try c.diagFmt(2511, c.nodeSpan(node), "Cannot create an instance of an abstract class.", .{});
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return .{ .ty = types.error_type, .chained = chained };
            }
            var ctor_sigs: std.ArrayList(TypeId) = .empty;
            defer ctor_sigs.deinit(c.scratch());
            try c.ctorSignatures(cls, &ctor_sigs);
            // Class type params (not the ctor's own).
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(cls, &tps);
            var tp_syms = try c.scratch().alloc(u32, tps.items.len);
            for (tps.items, 0..) |tp, i| tp_syms[i] = tp.sym;
            const inst_args = try c.scratch().alloc(TypeId, tps.items.len);
            if (targs.items.len > 0) {
                // `new G<Bad>(…)`'s list belongs to the CLASS, so it is gated
                // on the class's own type-parameter constraints — the same
                // written-list question as `G<Bad>` in a type position.
                try c.queueTypeArgConstraints(node, cls, targs.items);
                // …but the ARITY question is answered differently here than in
                // a type position. tsc resolves `new C<A, B>(…)` through
                // `getInstantiatedConstructorsForTypeArguments` →
                // `checkTypeArguments`, whose complaint is TS2558 at the
                // type-argument LIST ("Expected 1 type arguments, but got 2"),
                // where the same written list under `var c: C<A, B>` is
                // TS2314/TS2315/TS2707 at the NAME. `fixTypeArgs` answers the
                // type-position question, so the count is checked here first
                // (`tooManyTypeParameters1`,
                // `constructorInvocationWithTooFewTypeArgs`).
                if (targArityMismatch(tps.items, targs.items.len)) |exp| {
                    const span = typeArgsSpan(c, shape.targ_nodes, node);
                    if (exp.min == exp.max) {
                        try c.diagFmt(2558, span, "Expected {d} type arguments, but got {d}.", .{ exp.max, targs.items.len });
                    } else {
                        try c.diagFmt(2558, span, "Expected {d}-{d} type arguments, but got {d}.", .{ exp.min, exp.max, targs.items.len });
                    }
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                }
                const fixed = try c.fixTypeArgs(cls, targs.items, c.tree.nodeMainToken(node)) orelse return .{ .ty = types.error_type, .chained = chained };
                @memcpy(inst_args, fixed);
            } else if (tps.items.len > 0) {
                // Infer class type args from ctor arguments.
                const ctor = if (ctor_sigs.items.len > 0) ctor_sigs.items[0] else types.no_type;
                {
                    // …and from the CONTEXTUAL TYPE, which for a class value
                    // has to be matched against the instance type: a
                    // constructor's own declared return is not it. tsc adds
                    // exactly this inference (`InferencePriority.ReturnType`,
                    // from the contextual type to the signature's return),
                    // so `const s: SubjectLike<T> = new ReplaySubject(1)` is
                    // a `ReplaySubject<T>` and not a `ReplaySubject<unknown>`
                    // that then fails to be assignable. Handing
                    // `inferTypeArgs` the ctor signature with the instance
                    // type as its return puts the inference in both the
                    // places that need it: the pre-argument seed (so an
                    // argument's own contextual type is instantiated with
                    // it) and the post-argument fill, which only reaches a
                    // param no ARGUMENT constrained — argument evidence
                    // still wins, as it does in tsc.
                    const self_args = try c.scratch().alloc(TypeId, tps.items.len);
                    for (tps.items, 0..) |tp, i| self_args[i] = try c.ts.makeTypeParam(tp.sym);
                    const self_ty = try c.ts.makeRef(cls, self_args);
                    // A class with NO declared constructor still has the
                    // implicit `constructor()`, and it goes through the very
                    // same path: no parameters to infer from, so every class
                    // parameter falls to `inferTypeArgs`'s no-candidate answer
                    // (its default, else its constraint, else `unknown`) —
                    // where filling `any` instead made `new C()` a `C<any>`
                    // that swallowed its own errors
                    // (`getAndSetNotIdenticalType2`) — while the CONTEXTUAL
                    // inference above still reaches the instance return, which
                    // is what keeps `function asList<T>(a: T): List<T> {
                    // return new List(); }` a `List<T>`
                    // (`enumLiteralUnionNotWidened`).
                    const self_sig = if (ctor != types.no_type)
                        try c.sigWithReturn(ctor, self_ty)
                    else
                        try c.ts.makeFunction(&.{}, self_ty, &.{}, 0);
                    // A `new` expression's result is the instance, never a
                    // signature, so there is nothing to generalize a minted
                    // parameter onto: the list is discarded (and `unify`'s
                    // `ho_result_fn` gate keeps it empty anyway).
                    _ = try inferTypeArgs(c, self_sig, tp_syms, shape.arg_nodes, inst_args, ctx, types.no_type);
                }
            }
            instance_ret = try c.ts.makeRef(cls, inst_args);
            if (ctor_sigs.items.len == 0) {
                // Default constructor: no args allowed beyond none? tsc
                // allows zero args (inherited default). Check arity 0.
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                const nargs = countArgs(shape.arg_nodes);
                if (nargs > 0) {
                    // Same span rule as every other arity error: too MANY
                    // arguments blames the surplus ARGUMENTS, not the callee
                    // (`getArgumentArityError`'s `args.slice(maxCount)` node
                    // array) — see `reportArityError`.
                    var eff: std.ArrayList(EffArg) = .empty;
                    defer eff.deinit(c.scratch());
                    _ = try effectiveArgs(c, shape.arg_nodes, &eff);
                    try reportArityError(c, node, eff.items, eff.items.len, 0, 0, false);
                }
                return .{ .ty = instance_ret, .chained = chained };
            }
            // Instantiate ctor sigs with the class args.
            var map = try c.scratch().alloc(TpMap, tps.items.len);
            for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = inst_args[i] };
            for (ctor_sigs.items) |sig| {
                try sigs.append(c.scratch(), try c.instantiate(sig, map));
            }
        } else if (rk == .object and c.ts.objectConstructSigCount(r) > 0) {
            // Callable object with construct signatures, e.g.
            // `declare var Array: ArrayConstructor` then `new Array()`.
            // The signature's own return type is the instance type, so no
            // `instance_ret` override is needed (unlike a class value).
            //
            // In `reorderCandidates` order: a `…Constructor` interface that
            // several lib files reopen resolves its LAST declaration group
            // first (`MapConstructor` + lib.es2015.iterable's `iterable`
            // overload) — see `appendObjectConstructCandidates`.
            try c.appendObjectConstructCandidates(&sigs, r);
        } else if (rk == .union_type) {
            // `new (typeof A | typeof B)()`. tsc resolves a union callee's
            // signatures with `getUnionSignatures` over the constituents'
            // CONSTRUCT lists, the same combination the call side gets
            // (`combinedUnionSignature`): the union is constructable iff every
            // constituent is, and the result type is the union of the
            // constituents' instance types. Without this arm every
            // `new cls()` on a union of class values — the
            // `[A, B].map(c => new c())` idiom — was a false TS2351.
            var ctor_starts: std.ArrayList(u32) = .empty;
            defer ctor_starts.deinit(c.scratch());
            switch (try unionCtorSigs(c, r, &sigs, &ctor_starts)) {
                .ok => |u| {
                    // tsc's `resolveNewExpression` reports TS2511 when ANY
                    // selected construct signature is abstract; a union
                    // carries no `symbol` of its own, so the flag has to come
                    // from the constituents.
                    if (u.abstract) {
                        try c.diagFmt(2511, c.nodeSpan(node), "Cannot create an instance of an abstract class.", .{});
                    }
                    if (u.any or sigs.items.len == 0) {
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return .{ .ty = types.any_type, .chained = chained };
                    }
                    if (ctor_starts.items.len > 1) {
                        try resolveUnionSignatures(c, &sigs, ctor_starts.items);
                    }
                },
                // A shape this arm does not model (a GENERIC class value,
                // whose construct signatures would have to carry the class's
                // own type parameters). `any`, silently: an under-report,
                // where the TS2351 it replaces was a false positive.
                .unmodeled => {
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.any_type, .chained = chained };
                },
                .not_constructable => {
                    try c.diagFmt(2351, c.nodeSpan(shape.callee), "This expression is not constructable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                },
            }
        } else if (newTargetIsCallable(c, r)) {
            // No construct signature, but CALL signatures: tsc's
            // `resolveNewExpression` falls back to them
            // ("the expression is processed as a function call"), and
            // `checkNewExpression` then sees that the resolved declaration is
            // not a constructor and answers `any` — reporting TS7009 on the
            // whole `new` expression rather than TS2351 on the callee.
            // `new Test()` on a plain `function Test() {}` is the shape, and
            // `new Symbol` on `SymbolConstructor` (call signature, no
            // construct signature) is the other. TS2351 is left to a target
            // with neither kind of signature.
            //
            // The fallback call is NOT resolved: its only remaining product
            // would be an arity or argument diagnostic, and inventing one on a
            // path that already reports is the wrong direction to be wrong in.
            if (c.prog.no_implicit_any) {
                try c.diagFmt(7009, c.nodeSpan(node), "'new' expression, whose target lacks a construct signature, implicitly has an 'any' type.", .{});
            }
            for (shape.arg_nodes) |an| {
                if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
            }
            return .{ .ty = types.any_type, .chained = chained };
        } else {
            try c.diagFmt(2351, c.nodeSpan(shape.callee), "This expression is not constructable.", .{});
            for (shape.arg_nodes) |an| {
                if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
            }
            return .{ .ty = types.error_type, .chained = chained };
        }
    } else {
        switch (rk) {
            // The concatenated overload set gathered above.
            .intersection => {
                if (isect_sigs.items.len == 0) {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                }
                try sigs.appendSlice(c.scratch(), isect_sigs.items);
            },
            .function => try sigs.append(c.scratch(), r),
            .overloads => try c.appendOverloadCandidates(&sigs, r),
            // A `never` callee is a TS2349 to tsc — `never` has no call
            // signatures — but here it is USUALLY ztsc's flow answer for a
            // reference in UNREACHABLE code: `return assertNever(x)` after an
            // exhaustive switch narrows the callee `assertNever` itself to
            // `never`, and the oracle reports nothing on any of the eight
            // suite cases written that way. So the diagnostic is gated on the
            // callee's own DECLARED type being `never` (`let x: never; x()`,
            // `declare const n: never; n()`), which is the case the flow
            // cannot have invented. A narrowed-to-never callee in REACHABLE
            // code (a `typeof x === "number"` branch on a `string`) is the
            // under-report that gate costs.
            .never => {
                if (try declaredNeverCallee(c, shape.callee)) {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                }
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return .{ .ty = types.never_type, .chained = chained };
            },
            // Callable object with call signatures.
            .object => {
                if (c.ts.objectCallSigCount(r) == 0) {
                    if (try untypedFunctionCall(c, callee_t, r, rk)) {
                        try reportUntypedTypeArgs(c, node, shape, false);
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return .{ .ty = types.any_type, .chained = chained };
                    }
                    try reportNotCallable(c, shape, callee_t, r);
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                }
                try c.appendObjectCallCandidates(&sigs, r);
            },
            // Calling a union (e.g. `(A[] | B[]).map(...)`, where the member
            // access yields a union of the constituents' call-signature
            // functions). tsc: the union is callable iff EVERY constituent is
            // callable; the call resolves against the gathered signatures
            // (overload-style). A single `any`/`err` member makes the whole
            // call `any` (its signatures are unconstrained). A `never` member
            // contributes nothing (callable). Any non-callable member keeps
            // the TS2349.
            .union_type => {
                var all_callable = true;
                var saw_any = false;
                // Where each union constituent's own signature list starts in
                // `sigs`. tsc does NOT concatenate the lists into one overload
                // set — `getUnionSignatures` COMBINES them position-wise — so
                // the boundaries have to survive the gather.
                var starts: std.ArrayList(u32) = .empty;
                defer starts.deinit(c.scratch());
                for (try c.memberList(r)) |m| {
                    const before: u32 = @intCast(sigs.items.len);
                    // The global `Function` is callable HERE too, even though
                    // `isUntypedFunctionCall`'s last disjunct above excludes a
                    // union outright (`!(funcType.flags & TypeFlags.Union)`).
                    // tsc puts it in `resolveUnionTypeMembers` instead:
                    //
                    //     getUnionSignatures(map(type.types, t =>
                    //         t === globalFunctionType ? [unknownSignature]
                    //                                  : getSignaturesOfType(t, Call)))
                    //
                    // so a `Function` constituent contributes a wildcard rather
                    // than the empty list that would make the union
                    // non-callable. `Function | (() => object)` is the case
                    // (`unionOfFunctionAndSignatureIsCallable`): the interface
                    // body has no call signature, so the structural arm below
                    // reported TS2349 where tsc calls it and yields the
                    // error/`any` a wildcard signature resolves to. Tested on
                    // the DECLARED constituent, which is tsc's own reference
                    // identity check.
                    if (c.ts.kind(m) == .ref and c.globalSymNamed(c.ts.refSymbol(m), "Function")) {
                        saw_any = true;
                        continue;
                    }
                    const rm = try c.resolveStructural(m);
                    switch (c.ts.kind(rm)) {
                        .any, .err => saw_any = true,
                        .never => {},
                        .function => try sigs.append(c.scratch(), rm),
                        .overloads => try c.appendOverloadCandidates(&sigs, rm),
                        .object => {
                            if (c.ts.objectCallSigCount(rm) == 0) {
                                all_callable = false;
                            } else {
                                try c.appendObjectCallCandidates(&sigs, rm);
                            }
                        },
                        // A union member that is itself an INTERSECTION —
                        // `Window & typeof globalThis` is the canonical one
                        // — is callable when one of ITS members is, exactly
                        // as the top-level intersection walk above decides.
                        // Without this arm `(Document | (Window & typeof
                        // globalThis)).addEventListener` was judged
                        // non-callable and the whole optional call reported
                        // TS2349. Its signatures are the CONCATENATION of
                        // its constituents', same rule as the top-level
                        // intersection above.
                        .intersection => {
                            var member_callable = false;
                            for (try c.memberList(rm)) |im| {
                                const ri = try c.resolveStructural(im);
                                switch (c.ts.kind(ri)) {
                                    .function => {
                                        try sigs.append(c.scratch(), ri);
                                        member_callable = true;
                                    },
                                    .overloads => {
                                        try c.appendOverloadCandidates(&sigs, ri);
                                        member_callable = true;
                                    },
                                    .object => {
                                        if (c.ts.objectCallSigCount(ri) != 0) {
                                            try c.appendObjectCallCandidates(&sigs, ri);
                                            member_callable = true;
                                        }
                                    },
                                    else => {},
                                }
                            }
                            if (!member_callable) all_callable = false;
                        },
                        else => all_callable = false,
                    }
                    if (@as(u32, @intCast(sigs.items.len)) != before) {
                        try starts.append(c.scratch(), before);
                    }
                }
                if (all_callable and !saw_any and starts.items.len > 1) {
                    try resolveUnionSignatures(c, &sigs, starts.items);
                }
                if (!all_callable) {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.error_type, .chained = chained };
                }
                if (saw_any or sigs.items.len == 0) {
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.any_type, .chained = chained };
                }
            },
            else => {
                if (try untypedFunctionCall(c, callee_t, r, rk)) {
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return .{ .ty = types.any_type, .chained = chained };
                }
                try reportNotCallable(c, shape, callee_t, r);
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return .{ .ty = types.error_type, .chained = chained };
            },
        }
    }

    // For `new`, thread the contextual type only when the construct sig's
    // own return drives inference (a construct-sig object like
    // `PromiseConstructor`/`ArrayConstructor`, `instance_ret == no_type`).
    // A class-value `new` already inferred its class type args and overrides
    // the return via `instance_ret`, so contextual return inference there is
    // both moot and a needless perturbation.
    const call_ctx = if (is_new and instance_ret != types.no_type) types.no_type else ctx;
    // `new C<A>(…)`'s type arguments belong to the CLASS, and the class-value
    // path above has already spent them: `fixTypeArgs` checked their arity,
    // `inst_args` built the instance type, and every constructor signature was
    // instantiated with them. Handing them on as the SIGNATURE's own explicit
    // type arguments then measures them against the constructor's own type
    // parameters — normally none — and every candidate is rejected on arity.
    // tsc has no such double-spend because the construct signatures of
    // `typeof C` carry the class's parameters as their own; ztsc substitutes
    // instead, so the list has to stop here. Visible only with an OVERLOADED
    // constructor (a lone candidate is not dropped for it): every
    // `new Kysely<DB>(config)` in immich was TS2769.
    const sig_targs: []const TypeId = if (is_new and instance_ret != types.no_type) &.{} else targs.items;
    const result = try resolveSignatureCall(c, node, sigs.items, sig_targs, shape.arg_nodes, instance_ret, call_ctx);
    return .{ .ty = result, .chained = chained };
}

/// tsc's `getThisArgumentType`: what a call's receiver contributes as the
/// `this` argument, for BOTH the `this`-parameter inference and the TS2684
/// receiver check — the two must agree, and reading the receiver twice is how
/// they drift.
///
/// ```ts
/// function getThisArgumentType(thisArgumentNode) {
///     if (!thisArgumentNode) return voidType;
///     const thisArgumentType = checkExpression(thisArgumentNode);
///     return isOptionalChainRoot(thisArgumentNode.parent) ? getNonNullableType(thisArgumentType) :
///         isOptionalChain(thisArgumentNode.parent) ? removeOptionalTypeMarker(thisArgumentType) :
///         thisArgumentType;
/// }
/// ```
///
/// `null` when the callee is not an access expression — a bare call has no
/// receiver, and each caller has its own answer for that (`void` for the
/// check, "no inference" for the inference).
///
/// The optional-link strip is what `callChainInference` (the #42404 repro)
/// needs: `interface Y { foo<T>(this: T, arg: keyof T): void }` called as
/// `value?.foo("a")` on a `Y | undefined` inferred `T = Y | undefined`, whose
/// `keyof` is `never`, so the argument was a false TS2345 — and the receiver's
/// own nullability is reported by the chain, not by this call.
fn thisArgumentType(c: *Checker, callee: Node) Error!?TypeId {
    const optional = switch (c.nodeTag(callee)) {
        .member_expr, .index_expr => false,
        .optional_member_expr, .optional_index_expr => true,
        else => return null,
    };
    const recv = try c.checkExprCached(c.tree.nodeData(callee).lhs, types.no_type);
    return if (optional) try c.nonNullableChain(recv) else recv;
}

/// Receiver check for a signature with an explicit `this` parameter
/// (`f(this: T, …)`): the call's receiver must be assignable to `T`
/// (TS2684). A member call `obj.m()` uses `obj`'s type; a bare call uses
/// `void` (no receiver).
fn checkThisArg(c: *Checker, node: Node, sig: TypeId) Error!void {
    // Owned-file guard (see `checkJsxElement`): `void`, and its only
    // payload is TS2684/TS2739 on the call's receiver — dropped by `seal`
    // in a foreign file. The receiver `checkExprCached` it skips is a memo
    // fill; `isAssignable` is a pure relation query.
    if (!c.owned_mask[c.cur_file]) return;
    const this_ty = c.ts.fnThisType(sig);
    if (this_ty == 0) return;
    // Parentheses and type-only assertions do not change a call's receiver:
    // `(o.test!)()` is `o.test()`, and tsc's `getThisArgumentOfCall` reads the
    // callee through `skipOuterExpressions` before asking for an access
    // expression. Read without the skip, every such form had no receiver at
    // all, so `this` came out `void` and the call was a false TS2684
    // (`thisTypeSyntacticContext`'s `o.test!()`, `o.test!!!()`, `(o.test!)()`).
    const callee = expr_zig.skipOuterExprs(c, c.callShape(node).callee);
    const recv = try thisArgumentType(c, callee) orelse types.void_type;
    if (!try c.isAssignable(recv, this_ty)) {
        // TS7 reports the specific missing-property error (TS2741/2739) when
        // the receiver simply lacks required members; a member present with
        // an incompatible type still yields the TS2684 wrapper.
        if (try c.tryReportMissingProps(recv, this_ty, c.nodeSpan(callee))) return;
        try c.diagFmt(2684, c.nodeSpan(callee), "The 'this' context of type '{s}' is not assignable to method's 'this' of type '{s}'.", .{
            try c.typeToString(recv), try c.typeToString(this_ty),
        });
    }
}

/// Where an overload failure that is really a RECEIVER failure belongs: the
/// `this` argument's own span, when `sig` declares a `this` parameter the
/// call's receiver does not satisfy. Null when the signature has no `this`
/// parameter, when the call has no receiver expression to blame (tsc falls back
/// to the call node there, which is this caller's default anchor anyway), or
/// when the receiver does satisfy it.
///
/// The relation here is exactly `checkThisArg`'s — the same pair, asked of a
/// candidate rather than of the one resolved signature — so it answers out of
/// the relation memo and costs a `checkExprCached` hit on the receiver.
fn thisArgMismatchSpan(c: *Checker, node: Node, sig: TypeId) Error!?Span {
    const this_ty = c.ts.fnThisType(sig);
    if (this_ty == 0 or this_ty == types.void_type or this_ty == types.any_type) return null;
    const callee = expr_zig.skipOuterExprs(c, c.callShape(node).callee);
    const recv_node = switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.tree.nodeData(callee).lhs,
        else => return null,
    };
    if (recv_node == null_node) return null;
    const recv = try c.checkExprCached(recv_node, types.no_type);
    if (try c.isAssignable(recv, this_ty)) return null;
    return c.nodeSpan(recv_node);
}

/// Whether `node` is a call/`new` that WROTE a type-argument list — i.e. one
/// whose type arguments `writtenTypeArgNodes` can read back at the TS2344
/// drain. `resolveSignatureCall` also serves synthesized call sites (`super(…)`,
/// tagged templates, decorators) whose nodes carry no list of their own.
fn writesTypeArgs(c: *const Checker, node: Node) bool {
    return switch (c.nodeTag(node)) {
        .call_expr_targs, .new_expr_targs, .optional_call => true,
        else => false,
    };
}

pub fn countArgs(arg_nodes: []const Node) usize {
    var n: usize = 0;
    for (arg_nodes) |a| {
        if (a != null_node) n += 1;
    }
    return n;
}

/// The parameter counts of every candidate an overload set rejected on ARITY,
/// folded together the way tsc's `getArgumentArityError` folds them: the
/// smallest minimum, the largest maximum, whether any candidate takes a rest
/// parameter, and — for the "no overload expects N arguments" form — the
/// closest counts on either side of the call's own argument count.
const ArityTally = struct {
    seen: bool = false,
    min: u32 = std.math.maxInt(u32),
    max: u32 = 0,
    rest: bool = false,
    below: ?u32 = null, // largest minimum still BELOW the argument count
    above: ?u32 = null, // smallest maximum still ABOVE it

    fn note(a: *ArityTally, required: u32, total: u32, nargs: usize) void {
        a.seen = true;
        if (required < a.min) a.min = required;
        if (total == std.math.maxInt(u32)) {
            a.rest = true;
        } else if (total > a.max) {
            a.max = total;
        }
        if (required < nargs and (a.below == null or required > a.below.?)) a.below = required;
        if (total != std.math.maxInt(u32) and total > nargs and (a.above == null or total < a.above.?)) a.above = total;
    }
};

/// Pick a signature (first match for overloads, like tsc), infer type
/// arguments, check arguments, and return the (instantiated) return
/// type; `instance_ret` overrides the return for `new`.
/// Resolve one call against a candidate signature list: overload selection,
/// type-argument inference, the argument check and every diagnostic those
/// raise. Shared with `expr.zig`'s tagged template, whose argument list is the
/// synthesized strings array followed by the substitutions — tsc resolves the
/// two through the same `resolveCall`.
pub fn resolveSignatureCall(
    c: *Checker,
    node: Node,
    sigs: []const TypeId,
    explicit_targs: []const TypeId,
    arg_nodes: []const Node,
    instance_ret: TypeId,
    ret_ctx: TypeId,
) Error!TypeId {
    if (sigs.len == 0) return types.any_type;
    if (sigs.len == 1) {
        // An explicit list on a call is one of the four sites tsc gates on the
        // type parameters' constraints (TS2344 — see
        // `checkSigTypeArgConstraints`). Only for a LONE candidate: with an
        // overload set tsc's failure is TS2769 about the whole set, and a
        // per-candidate constraint verdict there would be a diagnostic about
        // the candidate ztsc happened to look at.
        if (explicit_targs.len > 0 and writesTypeArgs(c, node)) {
            try c.queueSigTypeArgConstraints(node, sigs[0], explicit_targs);
        }
        // A candidate that declares NO type parameters cannot accept a written
        // list at all: tsc's `hasCorrectTypeArgumentArity` rejects it before an
        // argument is looked at, and `reportCallResolutionErrors` then reports
        // out of `candidateForTypeArgumentError` alone. So `f<number>(1)` on
        // `f: (v: T) => U` is "Expected 0 type arguments, but got 1" at the
        // list, and NOT an argument error on top
        // (`typeArgumentsOnFunctionsWithNoTypeParameters`,
        // `genericWithOpenTypeParameters1`). The arguments are still typed for
        // downstream consumers, silently — tsc's
        // `pickLongestCandidateSignature` returns the candidate without ever
        // running `checkApplicableSignature`.
        if (explicit_targs.len > 0 and c.ts.kind(sigs[0]) == .function and
            c.ts.fnTypeParams(sigs[0]).len == 0)
        {
            try c.diagFmt(2558, typeArgsSpan(c, c.callShape(node).targ_nodes, node), "Expected 0 type arguments, but got {d}.", .{explicit_targs.len});
            try checkCallArguments(c, node, sigs[0], arg_nodes, false);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(sigs[0]);
        }
        // …and a list whose LENGTH does not fit the type-parameter list is the
        // same verdict one step up: `hasCorrectTypeArgumentArity` rejects the
        // candidate, so `map<number>([1, ""], x => x.toString())` is
        // "Expected 2 type arguments, but got 1" and NOTHING about the
        // arguments (`mismatchedExplicitTypeParameterAndArgumentType`). The
        // TS2558 itself is `instantiateSigForCall`'s, which fills the missing
        // slots and carries on; only the argument verdict is withdrawn here.
        const targ_count_ok = c.ts.kind(sigs[0]) != .function or
            explicit_targs.len == 0 or
            c.sigTargArityOk(sigs[0], explicit_targs.len);
        const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        if (instance_ret == types.no_type) try checkThisArg(c, node, inst);
        try checkCallArguments(c, node, inst, arg_nodes, targ_count_ok);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
    }
    // Overloads: first signature whose arity fits and whose args check.
    //
    // ARITY is counted over the EFFECTIVE argument list, tsc's
    // `getEffectiveCallArguments` — a spread of a tuple spends one position
    // per element. Counting the written arguments instead made a spread ONE
    // position, so `pli(...[reads, writes, writes] as const)` matched the
    // one-parameter overload and never reached the three-position one
    // (`callWithSpread4`).
    var eff: std.ArrayList(EffArg) = .empty;
    defer eff.deinit(c.scratch());
    const spread_at = try effectiveArgs(c, arg_nodes, &eff);
    const eff_n = eff.items.len;
    //
    // tsc's `resolveCall` keeps two rejection piles: `candidatesForArgumentError`
    // (arity fit, arguments did not) and `candidatesForArgumentArityError`. Only
    // the first pile decides how the failure is REPORTED, and how many are in it
    // decides where the report lands — so count them here.
    var arg_err_count: usize = 0;
    var last_arg_err: TypeId = types.no_type;
    var arity: ArityTally = .{};
    // …and a written TYPE-ARGUMENT list has a pile of its own, which
    // `reportCallResolutionErrors` reports out of only when both the others
    // are empty (`signaturesWithCorrectTypeArgumentArity.length === 0`).
    var targ_arity_ok: usize = 0;
    for (sigs) |sig| {
        // With explicit type arguments, only a signature with the matching
        // type-parameter count is a candidate (tsc). Skips e.g. the
        // non-generic `new (): Map<any, any>` when `new Map<K, V>()` names
        // two type args, so the generic overload is chosen instead.
        if (explicit_targs.len > 0) {
            if (!c.sigTargArityOk(sig, explicit_targs.len)) continue;
            targ_arity_ok += 1;
        }
        // A candidate's TYPE-ARGUMENT INFERENCE is as speculative as the
        // argument check that follows it. Inference contextually types every
        // function argument by this candidate's parameter (`partialParamCtx`
        // → `checkExprCached`), so a candidate whose parameter is not callable
        // — `select(selections: ReadonlyArray<SE>)`, tried before the callback
        // overload beside it — walks the arrow with no contextual signature
        // and reports TS7006 on each of its parameters. `argumentsMatch`
        // already withdraws what a rejected candidate says about the
        // arguments; it just started counting too late, at its own entry,
        // leaving everything inference had already said standing. tsc runs the
        // whole of `chooseOverload` — inference included — with diagnostics
        // off and reports only for the signature it settles on.
        //
        // The accepted candidate keeps its inference diagnostics, exactly as
        // before: only the `continue` paths withdraw.
        //
        // The candidate's INSTANTIATION BUDGET is speculative for the same
        // reason, and this is the half that decides which overload wins. A
        // rejected candidate's substitutions are thrown away with its
        // diagnostics — but their cost stayed on `inst_count`, so a candidate
        // tried EARLIER could spend the statement's whole budget probing an
        // argument it then declines, and every candidate after it
        // instantiated to `error_type` (the truncation marker), read as
        // arity 0, and was rejected without ever being compared. That is how
        // kysely's `select(selections: ReadonlyArray<SE>)` — a wide union
        // constraint, tried first — bankrupts the `select(callback: CB)`
        // overload beside it and turns a call tsc resolves into TS2769: the
        // budget made overload resolution depend on candidate ORDER, and on
        // how much of the budget the enclosing statement had already spent,
        // which is why the same call diverged between checker partitions.
        //
        // So roll the counter back with the diagnostics. The accepted
        // candidate keeps its charge (its substitutions are the ones the
        // statement actually uses); only the `continue` paths refund.
        // `inst_limit_tripped` travels with it — it is the "do not memoize,
        // this subtree truncated" mark for the frames the refund unwinds, and
        // those frames are gone by the time it is restored.
        const saved_infer = c.diags.items.len;
        const infer_file = c.cur_file;
        const saved_inst_count = c.inst_count;
        const saved_inst_trip = c.inst_limit_tripped;
        const inst = try c.instantiateSigForCall(sig, explicit_targs, arg_nodes, node, ret_ctx);
        const req = try c.requiredParams(inst);
        const tot = try c.paramTotal(inst);
        // `hasCorrectArity` over the effective list: a list that still holds
        // an UNBOUNDED entry asks only whether that entry's position is one
        // the signature can reach, since its length is not known statically.
        const fits = if (spread_at) |si|
            si >= req and (tot == std.math.maxInt(u32) or si < tot)
        else
            eff_n >= req and eff_n <= tot;
        if (!fits) {
            // Fold this candidate into the set-wide arity picture tsc reports
            // when NO candidate ever reaches argument checking. A truncated
            // instantiation has no arity to contribute (see `checkCallArguments`).
            if (c.ts.kind(inst) == .function) arity.note(req, tot, eff_n);
            rollbackArgProbe(c, saved_infer, infer_file, arg_nodes, .fn_args);
            c.inst_count = saved_inst_count;
            c.newBudgetWindow();
            c.inst_limit_tripped = saved_inst_trip;
            continue;
        }
        if (try c.argumentsMatch(inst, arg_nodes)) {
            try checkCallArguments(c, node, inst, arg_nodes, true);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
        }
        rollbackArgProbe(c, saved_infer, infer_file, arg_nodes, .fn_args);
        c.inst_count = saved_inst_count;
        c.newBudgetWindow();
        c.inst_limit_tripped = saved_inst_trip;
        arg_err_count += 1;
        last_arg_err = sig;
    }
    // NO candidate reached argument checking: every one of them was rejected on
    // ARITY. tsc's `reportCallResolutionErrors` then has an empty
    // `candidatesForArgumentError` pile and reports out of the other one —
    // `getArgumentArityError` over the whole set — with no TS2769 at all. Twelve
    // of the suite's TS2769/TS2554 divergences are exactly this pile mix-up.
    //
    // A call whose effective list still holds an UNBOUNDED spread has no
    // argument count to talk about, so `getArgumentArityError` answers about
    // the SPREAD instead and never reaches its counting arms:
    //
    // ```ts
    // const spreadIndex = getSpreadArgumentIndex(args);
    // if (spreadIndex > -1) {
    //     return createDiagnosticForNode(args[spreadIndex], Diagnostics.A_spread_argument_must_either_have_a_tuple_type_or_be_passed_to_a_rest_parameter);
    // }
    // ```
    // …but a written TYPE-ARGUMENT list that fits NO overload is answered
    // before the argument count is ever discussed. tsc's
    // `reportCallResolutionErrors` reaches its last `else` with both rejection
    // piles empty and asks the type-argument question first:
    //
    // ```
    // const signaturesWithCorrectTypeArgumentArity =
    //     filter(signatures, s => hasCorrectTypeArgumentArity(s, typeArguments));
    // if (signaturesWithCorrectTypeArgumentArity.length === 0) {
    //     diagnostics.add(getTypeArgumentArityError(node, signatures, typeArguments, headMessage));
    // }
    // ```
    //
    // `new Map<string>()` is the case (`newMap`): every `MapConstructor`
    // overload takes 0 or 2 type parameters, so nothing reaches argument
    // checking and ztsc fell through to a TS2769 about arguments that were
    // never the problem.
    if (arg_err_count == 0 and explicit_targs.len > 0 and targ_arity_ok == 0) {
        try reportTargArityError(c, node, sigs, explicit_targs.len);
        const inst_one = try instantiateFallbackSig(c, sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        try typeArgsAfterFailure(c, inst_one, arg_nodes);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst_one);
    }
    if (arg_err_count == 0 and arity.seen) {
        if (spread_at) |si| {
            try c.diagFmt(2556, argErrorSpan(c, eff.items[si].node), "A spread argument must either have a tuple type or be passed to a rest parameter.", .{});
        } else if (eff_n > arity.min and eff_n < arity.max and !arity.rest) {
            try c.diagFmt(2575, calleeErrorSpan(c, node), "No overload expects {d} arguments, but overloads do exist that expect either {d} or {d} arguments.", .{
                eff_n, arity.below orelse arity.min, arity.above orelse arity.max,
            });
        } else {
            try reportArityError(c, node, eff.items, eff_n, arity.min, arity.max, arity.rest);
        }
        // Type the arguments (no report) and carry on with the first candidate,
        // exactly as the TS2769 path below does.
        const inst_one = try instantiateFallbackSig(c, sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        try typeArgsAfterFailure(c, inst_one, arg_nodes);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst_one);
    }
    // No candidate matched. tsc does not report at the callee: it re-checks
    // the LAST candidate with error reporting on and files the TS2769 where
    // that check would have reported — the offending argument, or, when the
    // argument is an object literal, the offending PROPERTY of it
    // (`fetch(url, { body: aSharedArrayBuffer })` is TS2769 on `body`).
    // So run that check, take the span of the first diagnostic it filed
    // inside this call, withdraw them all, and anchor the TS2769 there.
    //
    // "The LAST candidate" is the last one that got as far as ARGUMENT
    // checking, not the last declared signature: tsc re-reports out of
    // `candidatesForArgumentError`, which a signature rejected on arity never
    // joins. Taking `sigs[len - 1]` blindly re-checked, e.g., `useState`'s
    // zero-parameter overload against a one-argument call, whose only
    // complaint is an arity error nowhere near the argument at fault.
    //
    // How MANY candidates reached argument checking decides whether there is a
    // TS2769 at all. With exactly ONE there is no overload set left to talk
    // about, so tsc files that candidate's own applicability diagnostics
    // verbatim (TS2345 / TS2353 / …) at their own spans and no TS2769 —
    // `useState<S>(x)` beside `useState<S = undefined>()` reports the plain
    // argument error. With two or more it heads them with "No overload matches
    // this call. The last overload gave the following error." and files the
    // result at that last candidate's own anchor, whatever the candidate count
    // (verified against tsgo 7.0.2 at two, three and four candidates).
    const call_span = c.nodeSpan(node);
    const saved = c.diags.items.len;
    const report_sig = if (last_arg_err != types.no_type) last_arg_err else sigs[sigs.len - 1];
    const inst_last = try c.instantiateSigForCall(report_sig, explicit_targs, arg_nodes, node, ret_ctx);
    var arg_anchor: ?Span = null;
    try checkCallArgumentsAnchored(c, node, inst_last, arg_nodes, true, &arg_anchor);
    if (arg_err_count == 1) {
        // Keep the candidate's own diagnostics; tsc files no TS2769 here.
        const inst_one = try instantiateFallbackSig(c, sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        try typeArgsAfterFailure(c, inst_last, arg_nodes);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst_one);
    }
    // WHICH diagnostic marks the spot. tsc's `reportCallResolutionErrors`
    // re-runs `getSignatureApplicabilityError` on the last candidate, and that
    // function's error node is the ARGUMENT it stopped at (moved onto an inner
    // property/element only by `elaborateError`). Everything else the re-check
    // says is incidental: `checkCallArguments` type-checks each argument
    // expression before relating it, and an argument that is itself a failing
    // call — `router.post("x", validate(Schema), handler)`, outline's shape —
    // files its OWN diagnostic first, deeper inside. Taking the first
    // diagnostic in source range therefore anchored the TS2769 on the inner
    // call's argument (`Schema`, col 12) where tsc anchors it on the outer
    // call's argument (`validate(…)`, col 3) — 167 of outline's TS2769/TS2345
    // keys were the right diagnostic at the wrong column, counted twice:
    // once as excess here, once as under-report there. So ask the argument
    // walk directly where it blamed, and keep the "first diagnostic in range"
    // scan only as the fallback for a candidate whose failure is not an
    // argument relation at all.
    var anchor = c.nodeSpan(c.callShape(node).callee);
    // …with the THIS ARGUMENT ahead of every one of them.
    // `getSignatureApplicabilityError` relates the receiver to the signature's
    // `this` parameter first and RETURNS as soon as that fails, so a candidate
    // the receiver itself does not satisfy blames the receiver — tsc's
    // `errorNode = thisArgumentNode || node` — and never gets as far as an
    // argument. `callback.bind(2)` over `strictBindCallApply`'s
    // `bind<T, AX, R>(this: (this: T, ...args: AX[]) => R, …)` is that shape:
    // a `(this: 1, ...args: T) => void` with a GENERIC rest cannot be the
    // `this` of any of them, and the `2` ztsc blamed is incidental.
    if (try thisArgMismatchSpan(c, node, inst_last)) |a| {
        anchor = a;
    } else if (arg_anchor) |a| {
        anchor = a;
    } else for (c.diags.items[saved..]) |d| {
        if (d.file != c.cur_file) continue;
        if (d.span.start < call_span.start or d.span.start >= call_span.end) continue;
        anchor = d.span;
        // Map it up to the ARGUMENT that contains it. Reaching this fallback
        // means the re-check related every argument cleanly even though
        // `argumentsMatch` rejected them all — the two are not the same test
        // (freshness and the excess-property gate reject only in the first) —
        // so the only diagnostics in range are incidental ones from inside an
        // argument. tsc's error node is an argument either way.
        for (arg_nodes) |an| {
            if (an == null_node) continue;
            const full = c.nodeSpan(an);
            if (d.span.start < full.start or d.span.start >= full.end) continue;
            anchor = argErrorSpan(c, an);
            break;
        }
        break;
    }
    c.rollbackDiags(saved, .{ .file = c.cur_file, .lo = call_span.start, .hi = call_span.end });
    try c.diagFmt(2769, anchor, "No overload matches this call.", .{});
    // Continue with the first signature for downstream typing.
    const inst = try instantiateFallbackSig(c, sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
    try typeArgsAfterFailure(c, inst_last, arg_nodes);
    return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
}

/// The implicit-`any` family a CONTEXTUAL parameter type would have prevented:
/// a parameter's own type (TS7006), a rest parameter's (TS7019), and a
/// destructured parameter's leaves (TS7031). Nothing else in the 70xx range
/// depends on the contextual signature.
const contextual_implicit_any = [_]u16{ 7006, 7019, 7031 };

/// "Expected N type arguments, but got M" — the one code
/// `instantiateFallbackSig` withdraws.
const targ_arity_code = [_]u16{2558};

/// Everything signature RESOLUTION can say about a call, as opposed to what
/// checking an argument's own subexpressions says: the arity complaints, the
/// per-argument mismatch, and the overload-set failure. `resolveErrorCall`
/// reaches none of them, so a call tsc diverts there (an inaccessible
/// constructor) withdraws exactly this set and keeps the rest — a TS2304 for
/// an undeclared name written as an argument is still an error.
const resolve_verdict_codes = [_]u16{ 2345, 2554, 2555, 2556, 2557, 2558, 2769 };

/// tsc's `getTypeArgumentArityError`, for an overload set no written
/// type-argument list fits. It straddles the SET rather than any one
/// candidate: the two counts are the largest arity still BELOW the written
/// one and the smallest still ABOVE it, and only when both exist is there a
/// pair to name (TS2743). With just one side there is a single number to
/// expect, and the message degrades to the ordinary TS2558.
///
/// Reported at the type-argument LIST, tsc's
/// `createDiagnosticForNodeArray(… node.typeArguments …)`.
fn reportTargArityError(c: *Checker, node: Node, sigs: []const TypeId, written: usize) Error!void {
    var below: ?usize = null;
    var above: ?usize = null;
    for (sigs) |sig| {
        if (c.ts.kind(sig) != .function) continue;
        const tps = c.ts.fnTypeParams(sig);
        const min = c.sigMinTargs(tps);
        if (min > written) {
            if (above == null or min < above.?) above = min;
        } else if (tps.len < written) {
            if (below == null or tps.len > below.?) below = tps.len;
        }
    }
    const span = typeArgsSpan(c, c.callShape(node).targ_nodes, node);
    if (below != null and above != null) {
        try c.diagFmt(2743, span, "No overload expects {d} type arguments, but overloads do exist that expect either {d} or {d} type arguments.", .{ written, below.?, above.? });
        return;
    }
    const expected = below orelse above orelse return;
    try c.diagFmt(2558, span, "Expected {d} type arguments, but got {d}.", .{ expected, written });
}

/// The type-parameter list's accepted arity RANGE when `written` is outside it,
/// else null. `min` counts the parameters with no default, tsc's
/// `getMinTypeArgumentCount`; `max` is the whole list. A non-generic target
/// answers `0..0`, which is a real answer here — `new NonGeneric<T>()` is
/// "Expected 0 type arguments, but got 1".
fn targArityMismatch(tps: []const TypeParamInfo, written: usize) ?struct { min: usize, max: usize } {
    var min: usize = 0;
    for (tps) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (written >= min and written <= tps.len) return null;
    return .{ .min = min, .max = tps.len };
}

/// `instantiateSigForCall` for the candidate the call is TYPED with once
/// resolution has failed. tsc's `pickLongestCandidateSignature` instantiates
/// such a candidate for its return type alone and never re-reports against it.
/// ztsc's pick is `sigs[0]`, which may be an overload the written type-argument
/// list does not fit — and TS2558 for THAT is a complaint about the signature
/// ztsc happened to pick, not about the call: `_.map<number, string, Date>(c2,
/// rf1)` over a two-overload `Combinators` reported "Expected 2 type arguments,
/// but got 3" against the first overload, which `hasCorrectTypeArgumentArity`
/// had already dropped from the candidate list (`genericCombinators2`).
///
/// Only that code is withdrawn. A type-argument-arity error the call really
/// does have is reported from the candidate list — the lone-candidate arm of
/// `resolveSignatureCall`, or `instantiateSigForCall` on the report signature —
/// before this ever runs.
fn instantiateFallbackSig(
    c: *Checker,
    sig: TypeId,
    explicit_targs: []const TypeId,
    arg_nodes: []const Node,
    node: Node,
    ret_ctx: TypeId,
) Error!TypeId {
    const saved = c.diags.items.len;
    const inst = try c.instantiateSigForCall(sig, explicit_targs, arg_nodes, node, ret_ctx);
    c.rollbackDiags(saved, .{ .file = c.cur_file, .lo = 0, .hi = 0, .codes = &targ_arity_code });
    return inst;
}

/// Type every argument for downstream consumers once overload resolution has
/// FAILED. There is no signature left to offer as a contextual type, so the
/// walk is context-free — but tsc checks each argument exactly ONCE, against
/// the candidate it reports out of, and its node-links cache makes every later
/// visit a no-op. A function-expression argument that DID receive a contextual
/// signature during resolution must therefore not acquire implicit-`any`
/// parameters from this second, context-free walk:
/// ``tempTag2 `${ x => { … } }${ undefined }${ "hello" }` `` reported TS7006 on
/// `x` where tsc reports the TS2769 alone
/// (`taggedTemplateContextualTyping2`).
///
/// `report_sig` is the signature the failure was reported against. An argument
/// whose parameter there is CALLABLE is one contextual typing reached, so the
/// family above is withdrawn over that argument's span. Everything else the
/// walk says stands — this walk is also what republishes the diagnostics
/// inside argument subtrees that the failure report withdrew.
fn typeArgsAfterFailure(c: *Checker, report_sig: TypeId, arg_nodes: []const Node) Error!void {
    const has_params = c.ts.kind(report_sig) == .function;
    for (arg_nodes, 0..) |an, i| {
        if (an == null_node) continue;
        const contextual = has_params and try paramIsCallable(c, report_sig, @intCast(i));
        const before = c.diags.items.len;
        _ = try c.checkExprCached(an, types.no_type);
        if (!contextual) continue;
        const span = c.nodeSpan(an);
        c.rollbackDiags(before, .{
            .file = c.cur_file,
            .lo = span.start,
            .hi = span.end,
            .codes = &contextual_implicit_any,
        });
    }
}

/// Does `sig`'s `i`-th effective parameter carry a call signature — i.e. would
/// an argument written there have been contextually typed as a function?
/// A union counts when any constituent does, which is how
/// `f: FuncType | undefined` still types its argument's parameters.
fn paramIsCallable(c: *Checker, sig: TypeId, i: u32) Error!bool {
    const pt = try c.paramTypeAt(sig, i) orelse return false;
    return typeIsCallable(c, pt);
}

fn typeIsCallable(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .function, .overloads => return true,
        .object => return c.ts.objectCallSigCount(r) != 0,
        .union_type, .intersection => {
            for (try c.memberList(r)) |m| {
                if (try typeIsCallable(c, m)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Instantiate a (possibly generic) signature for a call: explicit
/// type args win; otherwise unify parameters against arguments
/// (two-phase: plain args first, then context-sensitive function args).
pub fn instantiateSigForCall(c: *Checker, sig: TypeId, explicit_targs: []const TypeId, arg_nodes: []const Node, node: Node, ret_ctx: TypeId) Error!TypeId {
    const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
    if (tps.len == 0) return sig;
    var args_buf = try c.scratch().alloc(TypeId, tps.len);
    // The unique type parameters inference minted for a generic function
    // argument (see `infer.generalizeCallResult`). Empty for an explicitly
    // instantiated call, which does no inference at all.
    var minted: []const u32 = &.{};
    if (explicit_targs.len > 0) {
        const min = c.sigMinTargs(tps);
        if (explicit_targs.len < min or explicit_targs.len > tps.len) {
            // tsc's error node is the type-argument node ARRAY
            // (`createDiagnosticForNodeArray(… node.typeArguments …)`), not the
            // call: `[1,2,3].map<any,any>(…)` is blamed on `any,any`, not on the
            // array literal the call chains off. Falls back to the whole node
            // for a callee shape that carries no written list.
            const span = typeArgsSpan(c, c.callShape(node).targ_nodes, node);
            if (min == tps.len) {
                try c.diagFmt(2558, span, "Expected {d} type arguments, but got {d}.", .{ tps.len, explicit_targs.len });
            } else {
                try c.diagFmt(2558, span, "Expected {d}-{d} type arguments, but got {d}.", .{ min, tps.len, explicit_targs.len });
            }
        }
        // tsc's `fillMissingTypeArguments`. A missing trailing argument takes
        // its default, instantiated under the arguments resolved SO FAR — so
        // `B = A` sees the supplied `A` and `C = B` sees the defaulted `B`.
        //
        // The mapper spans EVERY type parameter, not just the earlier ones,
        // and the not-yet-filled slots are seeded with `errorType`:
        //
        // ```ts
        // for (let i = numTypeArguments; i < numTypeParameters; i++) result[i] = errorType;
        // for (let i = numTypeArguments; i < numTypeParameters; i++) {
        //     const defaultType = getDefaultFromTypeParameter(typeParameters[i]);
        //     result[i] = defaultType ? instantiateType(defaultType, createTypeMapper(typeParameters, result)) : baseDefaultType;
        // }
        // ```
        //
        // That seed is what DEGRADES a default that names a LATER parameter —
        // the forward reference TS2744 reports on. `declare function f14<T, U =
        // V, V = C>(a?: T, b?: U, c?: V)` called as `f14<A>(a, b)` gives `U`
        // the `errorType`, which relates to everything, so tsc reports nothing;
        // mapping only the earlier parameters left `V` standing in `U`'s
        // default, resolved it to `C`, and made `b` a false TS2345 (nine keys
        // in `genericDefaults`). Leaving the slot behind as the raw parameter
        // is not a third option: an escaped type parameter is worse than either.
        const pmap = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| {
            args_buf[i] = if (i < explicit_targs.len) explicit_targs[i] else types.error_type;
            pmap[i] = .{ .sym = tp, .ty = args_buf[i] };
        }
        for (tps, 0..) |tp, i| {
            if (i < explicit_targs.len) continue;
            args_buf[i] = if (c.typeParamHasDefault(tp))
                try c.instantiate(try c.typeParamDefault(tp), pmap)
            else
                types.any_type;
            // `createTypeMapper(typeParameters, result)` reads the array this
            // loop is filling, so each resolved default is visible to the next.
            pmap[i].ty = args_buf[i];
        }
    } else {
        // The receiver type feeds inference of a `this`-parameter type
        // param (recomputed only when the signature declares one, since
        // `checkExprCached` on the member object is otherwise wasted work).
        var recv_ty: TypeId = types.no_type;
        if (c.ts.fnThisType(sig) != 0) {
            recv_ty = try thisArgumentType(c, c.callShape(node).callee) orelse types.no_type;
        }
        minted = try inferTypeArgs(c, sig, tps, arg_nodes, args_buf, ret_ctx, recv_ty);
    }
    var map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
    // tsc's `getSignatureInstantiation` tail: a type parameter this call's
    // inference MINTED for a generic function argument is re-attached to the
    // single signature the call returns. `&.{}` on every other call, which is
    // all but a combinator.
    return infer_zig.generalizeCallResult(c, try c.instantiate(sig, map), minted);
}

/// tsc's `getUnionSignatures`: calling a UNION does not resolve against the
/// constituents' signatures as if they were an overload set — the lists are
/// COMBINED into one signature (`combineSignaturesOfUnionMembers`), whose
/// parameters are the position-wise INTERSECTION of the constituents' and
/// whose return type is their UNION.
///
/// That intersection is what makes a callback argument work. `(A[] | B[])
/// .map(x => …)` hands the arrow `((x: A, …) => U) & ((x: B, …) => U)`, an
/// intersection of two call signatures, which `contextualCallSigOfType`
/// then turns back into one parameter typed `A | B`. Resolving the lists as
/// overloads instead picked the FIRST constituent's signature and typed `x`
/// as `A` alone — every use of a `B`-only property was a false TS2339, and a
/// `Promise<null> | Promise<T>` (the shape an `if (…) return
/// Promise.resolve(null)` early exit produces) typed its `.then` callback
/// `null`, so the body's null guard narrowed it to `never`.
///
/// `null` when the lists are not shaped for the combination — more than one
/// signature in a constituent, a `this` type, mismatched type-parameter
/// arity, or a rest parameter — in which case the caller keeps the gathered
/// overload set, the prior behaviour.
/// What `unionCtorSigs` found: either a gathered signature set (with the two
/// facts the caller must act on before resolving it) or a reason not to
/// resolve one at all.
const UnionCtors = union(enum) {
    ok: struct {
        /// A constituent is an abstract class value → TS2511.
        abstract: bool,
        /// A constituent is `any`/`err`, so the whole `new` is `any`.
        any: bool,
    },
    /// A constituent this arm does not model: caller answers `any` silently.
    unmodeled,
    /// A constituent carries no construct signature → TS2351.
    not_constructable,
};

/// Construct signatures of a UNION callee, gathered per constituent (tsc's
/// `getUnionSignatures` input lists). `starts` records where each
/// constituent's own list begins in `sigs`, which is what lets
/// `combinedUnionSignature` combine them position-wise instead of treating
/// the concatenation as one overload set.
///
/// A class-value constituent contributes its constructor signatures with the
/// return type rewritten to the INSTANCE type — a `.class_value`'s own
/// signature returns are not the instance (the single-class path overrides
/// them with `instance_ret`). A class with no declared constructor
/// contributes the default zero-argument one.
fn unionCtorSigs(
    c: *Checker,
    r: TypeId,
    sigs: *std.ArrayList(TypeId),
    starts: *std.ArrayList(u32),
) Error!UnionCtors {
    var abstract = false;
    var any = false;
    for (try c.memberList(r)) |m| {
        const before: u32 = @intCast(sigs.items.len);
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .any, .err => any = true,
            // A `never` constituent contributes nothing and blocks nothing —
            // the same rule the union CALL arm applies.
            .never => {},
            .class_value => {
                const cls = c.ts.classSymbol(rm);
                var tps: std.ArrayList(TypeParamInfo) = .empty;
                defer tps.deinit(c.scratch());
                try c.typeParamsOf(cls, &tps);
                // A GENERIC class value would need its construct signatures
                // to carry the class's own type parameters (tsc's
                // `typeof C` does; ztsc substitutes instead — see the
                // single-class path's `inst_args`), which this gather has no
                // way to express.
                if (tps.items.len != 0) return .unmodeled;
                if (try c.classIsAbstract(cls)) abstract = true;
                const inst = try c.ts.makeRef(cls, &.{});
                var cs: std.ArrayList(TypeId) = .empty;
                defer cs.deinit(c.scratch());
                try c.ctorSignatures(cls, &cs);
                if (cs.items.len == 0) {
                    try sigs.append(c.scratch(), try c.ts.makeFunction(&.{}, inst, &.{}, 0));
                } else for (cs.items) |sig| {
                    try sigs.append(c.scratch(), try c.sigWithReturn(sig, inst));
                }
            },
            .object => {
                const n = c.ts.objectConstructSigCount(rm);
                if (n == 0) return .not_constructable;
                for (0..n) |i| {
                    try sigs.append(c.scratch(), c.ts.objectConstructSig(rm, @intCast(i)));
                }
            },
            else => return .not_constructable,
        }
        if (@as(u32, @intCast(sigs.items.len)) != before) {
            try starts.append(c.scratch(), before);
        }
    }
    return .{ .ok = .{ .abstract = abstract, .any = any } };
}

/// Beyond this an intersection is not a mixin stack and the per-constituent
/// bookkeeping below is not worth its quadratic term. tsc has no bound; every
/// real mixin expression is two or three constituents deep.
const max_mixin_constituents = 8;

/// tsc's `resolveIntersectionTypeMembers` for CONSTRUCT signatures — the rule
/// that makes `new (typeof M & typeof C)(…)` an `M & C`.
///
/// A MIXIN constructor type is one whose whole construct surface is
/// `new (...args: any[])` — `isMixinConstructorType`: exactly one construct
/// signature, no type parameters, exactly one parameter, that parameter a REST
/// whose type is `any` or `any[]`. Such a constituent contributes NO signatures
/// of its own; instead its instance type is intersected into every OTHER
/// constituent's construct return:
///
///     const mixinFlags = findMixins(types);
///     if (!mixinFlags[i]) {
///         let signatures = getSignaturesOfType(t, SignatureKind.Construct);
///         if (signatures.length && mixinCount > 0)
///             signatures = map(signatures, s => { … clone.resolvedReturnType =
///                 includeMixinType(getReturnTypeOfSignature(s), types, mixinFlags, i); … });
///         constructSignatures = appendSignatures(constructSignatures, signatures);
///     }
///
/// So `{ new(...args: any[]): A } & { new(s: string): B }` has the single
/// signature `new (s: string) => A & B` — the mixin's `(...args: any[])` is
/// discarded and its `A` survives only in the return.
///
/// `findMixins` has one wrinkle that is load-bearing: when EVERY constructable
/// constituent is a mixin (`typeof M1 & typeof M2`), the FIRST one is un-flagged
/// so that some signature survives at all.
///
/// Answers `false` for every shape it does not model, and the caller then keeps
/// the pick-the-first-constructable-constituent rule it had. Two shapes are
/// deliberately declined: an intersection with no mixin constituent (nothing to
/// do, and today's rule is already right for it) and a GENERIC class value,
/// whose construct signatures would have to carry the class's own type
/// parameters — the same limit `unionCtorSigs` draws, and for the same reason.
fn mixinCtorSigs(c: *Checker, r: TypeId, sigs: *std.ArrayList(TypeId), abstract: *bool) Error!bool {
    const members = try c.memberList(r);
    if (members.len < 2 or members.len > max_mixin_constituents) return false;
    // Per constituent: where its construct signatures start/end in `own`, its
    // single signature's return when it is a mixin, and the mixin flag itself.
    var own: std.ArrayList(TypeId) = .empty;
    defer own.deinit(c.scratch());
    var start: [max_mixin_constituents]u32 = undefined;
    var len: [max_mixin_constituents]u32 = undefined;
    var is_mixin: [max_mixin_constituents]bool = undefined;
    var ctor_types: u32 = 0;
    var mixin_count: u32 = 0;
    for (members, 0..) |m, i| {
        start[i] = @intCast(own.items.len);
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .class_value => {
                const cls = c.ts.classSymbol(rm);
                var tps: std.ArrayList(TypeParamInfo) = .empty;
                defer tps.deinit(c.scratch());
                try c.typeParamsOf(cls, &tps);
                if (tps.items.len != 0) return false;
                // tsc's `resolveNewExpression` reports TS2511 when ANY selected
                // construct signature is abstract; an intersection carries no
                // `symbol` of its own, so the flag has to come from the
                // constituents — exactly as the union path does it.
                if (try c.classIsAbstract(cls)) abstract.* = true;
                // The construct return of a class VALUE is its instance type;
                // a constructor's own declared return is not it.
                const inst = try c.ts.makeRef(cls, &.{});
                var cs: std.ArrayList(TypeId) = .empty;
                defer cs.deinit(c.scratch());
                try c.ctorSignatures(cls, &cs);
                if (cs.items.len == 0) {
                    try own.append(c.scratch(), try c.ts.makeFunction(&.{}, inst, &.{}, 0));
                } else for (cs.items) |sig| {
                    try own.append(c.scratch(), try c.sigWithReturn(sig, inst));
                }
            },
            .object => {
                for (0..c.ts.objectConstructSigCount(rm)) |k| {
                    try own.append(c.scratch(), c.ts.objectConstructSig(rm, @intCast(k)));
                }
            },
            // A constituent with no construct surface at all — a plain object
            // literal intersected onto a class value, a primitive brand — is
            // simply not part of this rule. tsc's loop appends nothing for it.
            else => {},
        }
        len[i] = @as(u32, @intCast(own.items.len)) - start[i];
        if (len[i] > 0) ctor_types += 1;
        is_mixin[i] = len[i] == 1 and isMixinCtorSig(c, own.items[start[i]]);
        if (is_mixin[i]) mixin_count += 1;
    }
    if (ctor_types == 0) return false;
    // `findMixins`: keep one signature alive when every constructable
    // constituent is a mixin.
    if (mixin_count == ctor_types) {
        for (members, 0..) |_, i| {
            if (!is_mixin[i]) continue;
            is_mixin[i] = false;
            mixin_count -= 1;
            break;
        }
    }
    if (mixin_count == 0) return false;
    for (members, 0..) |_, i| {
        if (is_mixin[i] or len[i] == 0) continue;
        for (own.items[start[i]..][0..len[i]]) |sig| {
            // `includeMixinType`: this signature's own return, intersected with
            // every MIXIN constituent's instance type, in constituent order.
            var mixed: std.ArrayList(TypeId) = .empty;
            defer mixed.deinit(c.scratch());
            for (members, 0..) |_, j| {
                if (j == i) {
                    try mixed.append(c.scratch(), c.ts.fnReturn(sig));
                } else if (is_mixin[j]) {
                    try mixed.append(c.scratch(), c.ts.fnReturn(own.items[start[j]]));
                }
            }
            try sigs.append(c.scratch(), try c.sigWithReturn(sig, try c.ts.makeIntersection(c.scratch(), mixed.items)));
        }
    }
    return sigs.items.len > 0;
}

/// `isMixinConstructorType`, on one already-materialized construct signature:
/// no type parameters, exactly one parameter, that parameter a REST whose type
/// is `any` or `any[]`.
fn isMixinCtorSig(c: *Checker, sig: TypeId) bool {
    const s = &c.ts;
    if (s.kind(sig) != .function) return false;
    if (s.fnTypeParamCount(sig) != 0) return false;
    if (s.fnParamCount(sig) != 1) return false;
    const p = s.fnParam(sig, 0);
    if (!p.rest()) return false;
    return switch (s.kind(p.ty)) {
        .any => true,
        .array => s.kind(s.arrayElem(p.ty)) == .any,
        else => false,
    };
}

/// The signature list of constituent `i` inside the flattened `sigs`.
fn unionSigList(sigs: []const TypeId, starts: []const u32, i: usize) []const TypeId {
    const lo = starts[i];
    const hi = if (i + 1 < starts.len) starts[i + 1] else @as(u32, @intCast(sigs.len));
    return sigs[lo..hi];
}

/// tsc's `findMatchingSignature`: the first member of `list` that
/// `compareSignaturesIdentical` accepts against `probe`.
fn findMatchingSignature(
    c: *Checker,
    list: []const TypeId,
    probe: TypeId,
    partial: bool,
    ignore_ret: bool,
) Error!?TypeId {
    for (list) |s| {
        if (try compareSignaturesIdentical(c, s, probe, partial, ignore_ret)) return s;
    }
    return null;
}

/// tsc's `compareSignaturesIdentical`, restricted to the NON-GENERIC pairs the
/// union pass below admits (see `unionSignatures`), so the type-parameter
/// mapping and constraint/default comparison have nothing to do.
///
/// `compareTypes` is tsc's `partialMatch ? compareTypesSubtypeOf :
/// compareTypesIdentical`; ztsc has no separate subtype relation, so
/// assignability stands in for the subtype half — a widening that can only
/// make two signatures match, never split them.
fn compareSignaturesIdentical(
    c: *Checker,
    source_sig: TypeId,
    target: TypeId,
    partial: bool,
    ignore_ret: bool,
) Error!bool {
    if (source_sig == target) return true;
    if (!try isMatchingSignature(c, source_sig, target, partial)) return false;
    // `this` types are compared with `ignoreThisTypes: false`; a signature
    // that declares one is rare enough that requiring equality is the
    // conservative reading.
    if (c.ts.fnThisType(source_sig) != c.ts.fnThisType(target)) return false;
    const target_len = try unionSigPositions(c, target);
    for (0..target_len) |i| {
        const idx: u32 = @intCast(i);
        const s: TypeId = (try c.paramTypeAt(source_sig, idx)) orelse types.any_type;
        const t: TypeId = (try c.paramTypeAt(target, idx)) orelse types.any_type;
        const ok = if (partial) try c.isAssignable(t, s) else try identity.identical(c, t, s);
        if (!ok) return false;
    }
    if (!ignore_ret) {
        const sr = c.ts.fnReturn(source_sig);
        const tr = c.ts.fnReturn(target);
        const ok = if (partial) try c.isAssignable(sr, tr) else try identity.identical(c, sr, tr);
        if (!ok) return false;
    }
    return true;
}

/// tsc's `isMatchingSignature`: same position count, same required count and
/// the same effective-rest answer — or, for a PARTIAL match, merely a source
/// that requires no more arguments than the target does.
fn isMatchingSignature(c: *Checker, source_sig: TypeId, target: TypeId, partial: bool) Error!bool {
    const s_min = try c.requiredParams(source_sig);
    const t_min = try c.requiredParams(target);
    if ((try unionSigPositions(c, source_sig)) == (try unionSigPositions(c, target)) and
        s_min == t_min and
        (try unionSigEffectiveRest(c, source_sig)) == (try unionSigEffectiveRest(c, target)))
    {
        return true;
    }
    return partial and s_min <= t_min;
}

/// tsc's `getUnionSignatures`, FIRST pass: a signature survives into the
/// union's call list when every constituent has one that partially matches it
/// (same-or-fewer required parameters, its own positions all supertypes), and
/// the survivor's return type is the union of the matched signatures' returns.
///
/// Without it, `(F1 | F2 | F3 | F4 | F5)("a")` fell through to the
/// position-wise `combineSignaturesOfUnionMembers` fold, which turns a
/// rest-carrying constituent into a rest-carrying combined signature and so
/// answered TS2555 ("Expected at least 2 arguments") where tsc's first pass
/// picks `F5`'s BOUNDED list and answers TS2554 ("Expected 2 arguments").
///
/// Restricted to non-generic candidates: tsc's generic path demands an exact
/// match in every other list, and approximating the type-parameter mapping
/// wrongly would silently re-resolve calls that are correct today. A generic
/// candidate anywhere falls back to the fold, which is the status quo.
fn unionSignatures(
    c: *Checker,
    sigs: []const TypeId,
    starts: []const u32,
    out: *std.ArrayList(TypeId),
) Error!bool {
    for (sigs) |sig| {
        if (c.ts.kind(sig) != .function) return false;
        if (c.ts.fnTypeParamCount(sig) != 0) return false;
    }
    // The matched-signature scratch is reused across probes; a union's
    // constituent count is small, so one allocation covers the whole pass.
    var matched: std.ArrayList(TypeId) = .empty;
    defer matched.deinit(c.scratch());
    for (0..starts.len) |i| {
        for (unionSigList(sigs, starts, i)) |probe| {
            // "Only process signatures with parameter lists that aren't
            // already in the result list."
            if (out.items.len != 0 and
                (try findMatchingSignature(c, out.items, probe, false, true)) != null) continue;
            matched.clearRetainingCapacity();
            var all = true;
            for (0..starts.len) |j| {
                const m = if (j == i)
                    probe
                else
                    (try findMatchingSignature(c, unionSigList(sigs, starts, j), probe, true, true)) orelse {
                        all = false;
                        break;
                    };
                // `appendIfUnique`.
                for (matched.items) |x| {
                    if (x == m) break;
                } else try matched.append(c.scratch(), m);
            }
            if (!all) continue;
            if (matched.items.len <= 1) {
                try out.append(c.scratch(), probe);
                continue;
            }
            // `createUnionSignature`: the probe's own parameter list, with the
            // matched signatures' returns unioned (`getReturnTypeOfSignature`
            // on a composite signature).
            var rets = try c.scratch().alloc(TypeId, matched.items.len);
            defer c.scratch().free(rets);
            for (matched.items, 0..) |m, k| rets[k] = c.ts.fnReturn(m);
            try out.append(c.scratch(), try c.sigWithReturn(probe, try c.ts.makeUnion(c.scratch(), rets)));
        }
    }
    return out.items.len != 0;
}

/// tsc's `getUnionSignatures` over a union callee's per-constituent signature
/// lists: the MATCHING pass first, and its position-wise
/// `combineSignaturesOfUnionMembers` fold only when the matching pass came up
/// empty — which is the order tsc runs them in. Rewrites `sigs` in place;
/// leaving it untouched (both passes declining) keeps the concatenated
/// candidate list callers resolved against before either pass existed.
fn resolveUnionSignatures(c: *Checker, sigs: *std.ArrayList(TypeId), starts: []const u32) Error!void {
    var picked: std.ArrayList(TypeId) = .empty;
    defer picked.deinit(c.scratch());
    if (try unionSignatures(c, sigs.items, starts, &picked)) {
        sigs.clearRetainingCapacity();
        try sigs.appendSlice(c.scratch(), picked.items);
        return;
    }
    if (try combinedUnionSignature(c, sigs.items, starts)) |combined| {
        sigs.clearRetainingCapacity();
        try sigs.append(c.scratch(), combined);
    }
}

fn combinedUnionSignature(c: *Checker, sigs: []const TypeId, starts: []const u32) Error!?TypeId {
    // Only the one-signature-per-constituent shape: tsc's `getUnionSignatures`
    // has a whole matching pass for the rest, and guessing it wrong would
    // change calls that resolve correctly today.
    if (sigs.len != starts.len) return null;
    var acc = sigs[0];
    for (sigs[1..]) |right| {
        acc = try combineTwoUnionSignatures(c, acc, right) orelse return null;
    }
    return acc;
}

/// One fold step of `combinedUnionSignature` (tsc's
/// `combineSignaturesOfUnionMembers` -> `combineUnionParameters`).
fn combineTwoUnionSignatures(c: *Checker, left: TypeId, right0: TypeId) Error!?TypeId {
    const s = &c.ts;
    if (s.kind(left) != .function or s.kind(right0) != .function) return null;
    if (s.fnThisType(left) != 0 or s.fnThisType(right0) != 0) return null;
    // The store may grow under `instantiate`/`makeUnion`, so the type-parameter
    // list has to be copied out before anything else touches it.
    const ltp = try c.scratch().dupe(u32, s.fnTypeParams(left));
    defer c.scratch().free(ltp);
    const rtp = try c.scratch().dupe(u32, s.fnTypeParams(right0));
    defer c.scratch().free(rtp);
    if (ltp.len != rtp.len) return null;
    // tsc maps the right signature's type parameters onto the left's and keeps
    // the left's list, so both sides speak the same parameters.
    var right = right0;
    if (rtp.len != 0) {
        const map = try c.scratch().alloc(TpMap, rtp.len);
        defer c.scratch().free(map);
        for (rtp, 0..) |sym, i| map[i] = .{ .sym = sym, .ty = try s.makeTypeParam(ltp[i]) };
        right = try c.instantiate(right0, map);
        if (s.kind(right) != .function) return null;
    }
    const lc = try unionSigPositions(c, left);
    const rc = try unionSigPositions(c, right);
    // tsc's `combineSignaturesOfUnionMembers` takes `Math.max(left
    // .minArgumentCount, right.minArgumentCount)` — the signatures' RAW
    // minimums, counted off the declared parameter list, not
    // `getMinArgumentCount`'s tuple-rest expansion. A signature whose only
    // parameter is a rest declares NO required argument however the tuple
    // typing it is shaped, so `((...a: [string]) => void) | ((...a: []) =>
    // void)` combines to a signature callable with none. Reading the expanded
    // minimum made the combined position REQUIRED and `fn(...args)` over
    // `signatureCombiningRestParameters1`'s mapped bag came out TS2556
    // instead of tsc's TS2345 about the `never` the positions intersect to.
    const lreq = rawMinArgs(c, left);
    const rreq = rawMinArgs(c, right);
    const n = @max(lc, rc);
    // tsc's `combineUnionParameters` rest bookkeeping: the combined signature
    // keeps a rest at its LAST position when either side has an effective one
    // and the longer side is the one that has it; when only the SHORTER side
    // does, the extra rest is appended as one more position instead. Without
    // it, a union of `push(...items: number[])` and `push(...items: string[])`
    // was left as a two-candidate overload set, the first candidate accepted
    // the argument, and tsc's `never` parameter never appeared
    // (`controlFlowArrayErrors`' `(boolean[] | (string | number)[]).push(99)`).
    const either_rest = (try unionSigEffectiveRest(c, left)) or (try unionSigEffectiveRest(c, right));
    const longest = if (lc >= rc) left else right;
    const shorter = if (lc >= rc) right else left;
    const needs_extra_rest = either_rest and !try unionSigEffectiveRest(c, longest);
    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    for (0..n) |i| {
        const idx: u32 = @intCast(i);
        // `tryGetTypeAtPosition` answers `unknown` for a position the shorter
        // signature does not declare, and `unknown` is the intersection's
        // identity — the longer signature's type survives.
        const lp: TypeId = (try c.paramTypeAt(left, idx)) orelse types.unknown_type;
        const rp: TypeId = (try c.paramTypeAt(right, idx)) orelse types.unknown_type;
        const name: Atom = paramNameAt(c, left, idx) orelse paramNameAt(c, right, idx) orelse 0;
        const is_rest = either_rest and !needs_extra_rest and idx + 1 == n;
        const optional = !is_rest and idx >= lreq and idx >= rreq;
        const ty = try s.makeIntersection(c.scratch(), &.{ lp, rp });
        try params.append(c.scratch(), .{
            .name = name,
            .ty = if (is_rest) try s.makeArray(ty) else ty,
            .flags = if (is_rest) types.param_flag_rest else if (optional) types.param_flag_optional else 0,
        });
    }
    if (needs_extra_rest) {
        const et = (try c.paramTypeAt(shorter, n)) orelse types.unknown_type;
        try params.append(c.scratch(), .{
            .name = 0,
            .ty = try s.makeArray(et),
            .flags = types.param_flag_rest,
        });
    }
    const ret = try s.makeUnion(c.scratch(), &.{ s.fnReturn(left), s.fnReturn(right) });
    return try s.makeFunction(params.items, ret, ltp, 0);
}

/// A signature's RAW `minArgumentCount`: the declared parameters before the
/// first optional or rest one. tsc records this on the signature at creation;
/// `getMinArgumentCount` is the expanded reading built on top of it.
fn rawMinArgs(c: *const Checker, sig: TypeId) u32 {
    const count = c.ts.fnParamCount(sig);
    for (0..count) |i| {
        const p = c.ts.fnParam(sig, @intCast(i));
        if (p.optional() or p.rest()) return @intCast(i);
    }
    return count;
}

/// tsc's `getParameterCount`: how many POSITIONS a signature declares. A
/// trailing rest is one position unless it is typed by a tuple, which spreads
/// into its own elements.
fn unionSigPositions(c: *Checker, sig: TypeId) Error!u32 {
    const n = c.ts.fnParamCount(sig);
    if (n == 0 or !c.ts.fnParam(sig, n - 1).rest()) return n;
    if (try c.sigRestTuple(sig)) |tup| return n - 1 + c.ts.tupleLen(tup);
    return n;
}

/// tsc's `hasEffectiveRestParameter`: a trailing rest that really is
/// open-ended — a rest typed by a FIXED tuple declares a bounded parameter
/// list and is not one.
fn unionSigEffectiveRest(c: *Checker, sig: TypeId) Error!bool {
    const n = c.ts.fnParamCount(sig);
    if (n == 0 or !c.ts.fnParam(sig, n - 1).rest()) return false;
    if (try c.sigRestTuple(sig)) |tup| {
        const len = c.ts.tupleLen(tup);
        return len > 0 and c.ts.tupleElem(tup, len - 1).rest();
    }
    return true;
}

/// The declared name at a position, or null past the signature's own list.
/// A rest position reuses the rest parameter's name, which is what tsc's
/// `getParameterNameAtPosition` synthesizes from too.
fn paramNameAt(c: *Checker, sig: TypeId, i: u32) ?Atom {
    const n = c.ts.fnParamCount(sig);
    if (n == 0) return null;
    if (i < n) return c.ts.fnParam(sig, i).name;
    const last = c.ts.fnParam(sig, n - 1);
    return if (last.rest()) last.name else null;
}

/// A TS 4.7 instantiation expression: `f<T>` in value position and
/// `typeof f<T>` in type position both specialize the *signatures* of the
/// referenced value without calling it. Every signature that accepts this
/// many type arguments is instantiated; the rest are dropped, and a
/// reference left with no applicable signature is TS2635.
///
/// Deferred, as an under-report (never a false positive): a class value.
/// `typeof C<T>` keeps `typeof C`, because a `.class_value` carries no
/// type-argument slot — tsc answers with the class's whole materialized
/// static side (`{ new (…): C<T>; …statics }`), which is a different type
/// shape, not a specialization of this one. Same for a type parameter or
/// a union of callables.
pub fn instantiationExprType(c: *Checker, base: TypeId, targ_nodes: []const Node, node: Node) Error!TypeId {
    var targs: std.ArrayList(TypeId) = .empty;
    defer targs.deinit(c.scratch());
    for (targ_nodes) |tn| {
        if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
    }
    if (targs.items.len == 0) return base;

    const r = try c.resolveStructural(base);
    var call_sigs: std.ArrayList(TypeId) = .empty;
    defer call_sigs.deinit(c.scratch());
    var construct_sigs: std.ArrayList(TypeId) = .empty;
    defer construct_sigs.deinit(c.scratch());
    var rebuild_object = false;
    switch (c.ts.kind(r)) {
        .function => try call_sigs.append(c.scratch(), r),
        .overloads => for (try c.memberList(r)) |m| try call_sigs.append(c.scratch(), m),
        .object => {
            rebuild_object = true;
            for (0..c.ts.objectCallSigCount(r)) |i| {
                try call_sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
            }
            for (0..c.ts.objectConstructSigCount(r)) |i| {
                try construct_sigs.append(c.scratch(), c.ts.objectConstructSig(r, @intCast(i)));
            }
        },
        // `any`/`err` swallow the type arguments; everything else is the
        // deferred set above — the base type stands unchanged.
        else => return base,
    }

    var inst_call: std.ArrayList(TypeId) = .empty;
    defer inst_call.deinit(c.scratch());
    var inst_construct: std.ArrayList(TypeId) = .empty;
    defer inst_construct.deinit(c.scratch());
    for (call_sigs.items) |sig| {
        if (!c.sigTargArityOk(sig, targs.items.len)) continue;
        try inst_call.append(c.scratch(), try c.instantiateSigForCall(sig, targs.items, &.{}, node, types.no_type));
    }
    for (construct_sigs.items) |sig| {
        if (!c.sigTargArityOk(sig, targs.items.len)) continue;
        try inst_construct.append(c.scratch(), try c.instantiateSigForCall(sig, targs.items, &.{}, node, types.no_type));
    }

    if (inst_call.items.len == 0 and inst_construct.items.len == 0) {
        try c.diagFmt(2635, typeArgsSpan(c, targ_nodes, node), "Type '{s}' has no signatures for which the type argument list is applicable.", .{try c.typeToString(base)});
        return types.error_type;
    }
    if (!rebuild_object) {
        if (inst_call.items.len == 1) return inst_call.items[0];
        return c.ts.makeOverloads(inst_call.items);
    }
    // A callable object keeps its properties and index signatures; only
    // the signature lists are replaced by their applicable instantiations.
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    for (0..c.ts.objectPropCount(r)) |i| {
        try props.append(c.scratch(), c.ts.objectProp(r, @intCast(i)));
    }
    return c.ts.makeObjectSigs(
        props.items,
        c.ts.objectStringIndex(r),
        c.ts.objectNumberIndex(r),
        c.ts.objectFlags(r),
        inst_call.items,
        inst_construct.items,
    );
}

/// The span of a type-argument list INCLUDING its angle brackets — tsc's
/// `node.typeArguments` NodeList, whose own `pos`/`end` are the `<` and the
/// `>`. TS2754 is anchored on that list, where TS2558 and its neighbours are
/// anchored on the arguments alone (`typeArgsSpan`).
///
/// The brackets are found in the SOURCE rather than in the token stream: a
/// type node carries a byte span, not a token index, and the two brackets are
/// the nearest non-space characters on either side of the arguments. Anything
/// else in between (a comment) falls back to the arguments' own span, which
/// costs a column on a shape no one writes.
fn typeArgListSpan(c: *Checker, targ_nodes: []const Node, node: Node) Span {
    const args = typeArgsSpan(c, targ_nodes, node);
    var lo = args.start;
    while (lo > 0 and std.ascii.isWhitespace(c.src[lo - 1])) lo -= 1;
    var hi = args.end;
    while (hi < c.src.len and std.ascii.isWhitespace(c.src[hi])) hi += 1;
    if (lo == 0 or c.src[lo - 1] != '<') return args;
    if (hi >= c.src.len or c.src[hi] != '>') return args;
    return .{ .start = lo - 1, .end = hi + 1 };
}

/// The span of a type-argument list `<A, B>`, for the diagnostics tsc
/// anchors there rather than on the whole expression. Falls back to the
/// node when the list is empty or malformed.
fn typeArgsSpan(c: *Checker, targ_nodes: []const Node, node: Node) Span {
    if (targ_nodes.len == 0) return c.nodeSpan(node);
    const first = c.nodeSpan(targ_nodes[0]);
    const last = c.nodeSpan(targ_nodes[targ_nodes.len - 1]);
    if (first.end == 0 or last.end == 0) return c.nodeSpan(node);
    return .{ .start = first.start, .end = last.end };
}

/// The type-argument inference half of a call lives in `infer.zig`.
/// Re-exported here so `checker.zig`'s alias block and the submodules that
/// import these by name keep resolving them under their old home.
const infer_zig = @import("infer.zig");
pub const fillFromReturnContext = infer_zig.fillFromReturnContext;
pub const isOuterInferVar = infer_zig.isOuterInferVar;
pub const mentionsActiveInferVar = infer_zig.mentionsActiveInferVar;
pub const partialParamCtx = infer_zig.partialParamCtx;
pub const instantiateKnownParams = infer_zig.instantiateKnownParams;
pub const paramIsBareCallbackReturn = infer_zig.paramIsBareCallbackReturn;
pub const isBareOrUnionMember = infer_zig.isBareOrUnionMember;
pub const InferCtx = infer_zig.InferCtx;
const inferTypeArgs = infer_zig.inferTypeArgs;
pub const tpIndex = infer_zig.tpIndex;
pub const clampToConstraint = infer_zig.clampToConstraint;
pub const covLiteralShape = infer_zig.covLiteralShape;
pub const covLiteralBase = infer_zig.covLiteralBase;
pub const covNullableFlags = infer_zig.covNullableFlags;
pub const covStripNullable = infer_zig.covStripNullable;
pub const covSubtypeOf = infer_zig.covSubtypeOf;
pub const combineCovariant = infer_zig.combineCovariant;
pub const combineContravariant = infer_zig.combineContravariant;
pub const contraSlot = infer_zig.contraSlot;
pub const noteContraCandidate = infer_zig.noteContraCandidate;
pub const topSlot = infer_zig.topSlot;
pub const revSlot = infer_zig.revSlot;
pub const unify = infer_zig.unify;
pub const discriminatedConstituent = infer_zig.discriminatedConstituent;
pub const intersectionMembersPair = infer_zig.intersectionMembersPair;
pub const constituentCarriesInference = infer_zig.constituentCarriesInference;
pub const constituentRelatesTo = infer_zig.constituentRelatesTo;
pub const inferReverseMapped = infer_zig.inferReverseMapped;
pub const inferMappedKeySet = infer_zig.inferMappedKeySet;
pub const stripSourceParam = infer_zig.stripSourceParam;
pub const mintReverseElemVar = infer_zig.mintReverseElemVar;
pub const substElemAccess = infer_zig.substElemAccess;
pub const bindAnyToTypeParams = infer_zig.bindAnyToTypeParams;

/// Which of a rejected candidate's argument readings the rollback withdraws.
const ProbeScope = enum {
    /// Every argument. `argumentsMatch` types each one under this candidate's
    /// own parameter, so everything it published is this candidate's reading
    /// and none of it survives the candidate.
    all_args,
    /// Function-expression arguments only. This is the scope
    /// `no_publish_depth` already withholds INSIDE `argumentsMatch`, applied
    /// one frame earlier to the type-argument inference that walks the same
    /// callback and does not withhold anything.
    ///
    /// Widening it to every argument is a measured regression, not a
    /// conservatism: social-app's `useInfiniteQuery({queryKey, queryFn: async
    /// ({pageParam}) => …})` loses `TPageParam` (a false TS2322 on `cursor:
    /// pageParam`) once the declined `DefinedInitialDataInfiniteOptions`
    /// overload's inference readings are dropped. An OBJECT-LITERAL argument
    /// is not re-derived the way a re-walked callback body is: inference over
    /// one runs tsc's two rounds (`markCtxSensitiveFixed`, the
    /// `skip_ctx_sensitive` pre-pass), and those rounds read each other's
    /// published answers. That is a real fragility in `inferTypeArgs` and it
    /// is not this function's to fix — what this function must not do is walk
    /// into it.
    fn_args,
};

/// Withdraw a rejected overload candidate's diagnostics AND the `node_types`
/// entries its probe published under the arguments.
///
/// `rollbackArgDiags` alone is not enough, and the gap is a silent one.
/// `diagFmt`'s suppression key is withdrawn with the diagnostic, so the
/// winning candidate is *allowed* to re-file — but only if it actually
/// re-walks the expression, and `node_types` is exactly what stops it. The
/// probe walks an argument under this candidate's contextual type and
/// publishes every subexpression's answer; the inner reads are published under
/// the CONTEXT-FREE key (`no_type`), which is the key the next candidate's
/// walk asks with, so the re-walk cache-hits and the withdrawn diagnostic is
/// never re-filed. The expression is checked twice and reported zero times,
/// which is indistinguishable from never being checked at all.
///
/// Two shapes in the suite:
///   * `two(y.find(" "))` over `two(c: string)` / `two(c: JQuery)` — the
///     string candidate types `y.find(" ")`, files TS2454 on `y`, is rejected,
///     and the JQuery candidate reads `y`'s type back out of the memo
///     (dottedSymbolResolution1). `.all_args`, from `argumentsMatch`.
///   * `this.data.find(function (d) { … this … })` — `find`'s generic
///     type-predicate overload runs INFERENCE over the callback, which
///     publishes (only `argumentsMatch` withholds a function argument, via
///     `no_publish_depth`), files TS2683 and is rejected; the plain overload
///     re-walks the body and hits the memo (thisInFunctionCall). `.fn_args`,
///     from the candidate loop.
///
/// Gated on the candidate having filed anything at all — the same test
/// `rollbackArgDiags` early-returns on. With no diagnostic to lose there is
/// nothing for a stale entry to swallow, so the overwhelmingly common
/// rejection pays one comparison.
///
/// The entries are removed rather than withheld (a `no_publish_depth` over the
/// whole probe) because withholding makes EVERY candidate re-walk every
/// argument from scratch, the winner included, whose answers `node_types`
/// would then have to be re-taught by `checkCallArguments`. Removal charges
/// only the candidates that actually poisoned something.
fn rollbackArgProbe(c: *Checker, saved: usize, file: modules.FileId, arg_nodes: []const Node, scope: ProbeScope) void {
    if (c.diags.items.len == saved) return;
    const mark = c.scratch_arena.mark();
    defer c.scratch_arena.restore(mark);
    // Where the candidate spoke. A diagnostic filed OUTSIDE the argument range
    // is not withdrawn at all — it is collateral from work the probe merely
    // triggered, see `rollbackDiags` — and it lands inside no argument node, so
    // the list needs no region test of its own.
    var spots: std.ArrayList(u32) = .empty;
    for (c.diags.items[saved..]) |d| {
        if (d.file == file) spots.append(c.scratch(), d.span.start) catch return;
    }
    c.rollbackArgDiags(saved, file, arg_nodes);
    if (spots.items.len == 0) return;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        if (scope == .fn_args) switch (c.prog.files[file].tree.nodeTag(an)) {
            .arrow_fn, .function_expr => {},
            else => continue,
        };
        forgetNodeTypesCovering(c, file, an, spots.items);
    }
}

/// Drop from `node_types` every node in `root`'s subtree whose span COVERS one
/// of `spots` — the positions the withdrawn diagnostics were filed at.
///
/// That set is exactly the blockers and nothing else. Re-filing at position `s`
/// needs the walk to reach the node that files it, and the only entries that
/// can short-circuit that descent are the ones on the path from `root` down to
/// it — every one of which covers `s`. Everything else in the subtree is an
/// answer the probe got right and the winner would only recompute.
///
/// It is also what bounds the cost. `Ast.span` is an O(subtree) walk, so a
/// blanket sweep would be one span per node; descending only into children that
/// cover a spot visits one root-to-blame path plus its immediate siblings.
///
/// Iterative (an explicit worklist in scratch) rather than recursive: an
/// argument is arbitrary user syntax and this runs on whatever stack the call
/// chain has left. Spans are taken against `file`'s own tree and source, which
/// `cur_file` need not still be.
fn forgetNodeTypesCovering(c: *Checker, file: modules.FileId, root: Node, spots: []const u32) void {
    const mark = c.scratch_arena.mark();
    defer c.scratch_arena.restore(mark);
    const f = &c.prog.files[file];
    var stack: std.ArrayList(Node) = .empty;
    stack.append(c.scratch(), root) catch return;
    while (stack.pop()) |n| {
        const sp = f.tree.span(f.src, n);
        var covers = false;
        for (spots) |s| {
            if (s >= sp.start and s < sp.end) {
                covers = true;
                break;
            }
        }
        if (!covers) continue;
        _ = c.node_types.remove((@as(u64, file) << 32) | n);
        var it = f.tree.childIterator(n);
        while (it.next()) |child| stack.append(c.scratch(), child) catch return;
    }
}

/// `getSignatureApplicabilityError`'s REST half, asked silently: does the
/// spread argument list, packed as one type, satisfy `sig`'s non-array rest?
///
/// Answers "yes" for everything it cannot pack faithfully — a signature with
/// no non-array rest, and any window `checkCallArguments` also declines to
/// pack — so this only ever WITHDRAWS the unconditional pass a spread used to
/// get, never adds one.
fn spreadRestMatches(c: *Checker, rest: ?NonArrayRest, arg_nodes: []const Node) Error!bool {
    const w = rest orelse return true;
    var eff: std.ArrayList(EffArg) = .empty;
    defer eff.deinit(c.scratch());
    const spread_at = try effectiveArgs(c, arg_nodes, &eff);
    if (w.from > eff.items.len) return true;
    const whole = wholeSpreadPack(eff.items, spread_at, w.from);
    if (whole != types.no_type) return try c.isAssignable(whole, w.ty);
    // A spread that expanded to a FIXED list leaves no unbounded entry, so
    // the pack is just those entries — but only when the expansion typed
    // every one of them: an argument WRITTEN at the call site is typed
    // against its parameter, which is a question this silent probe is not
    // the place to answer.
    if (spread_at != null) return true;
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    for (eff.items[w.from..]) |ea| {
        if (ea.ty == types.no_type) return true;
        try elems.append(c.scratch(), .{ .ty = ea.ty });
    }
    return try c.isAssignable(try c.ts.makeTuple(elems.items), w.ty);
}

/// Would every argument check against `sig`? (Silent, for overload
/// selection.)
pub fn argumentsMatch(c: *Checker, sig: TypeId, arg_nodes: []const Node) Error!bool {
    // Overload probing: contextually type each argument by this candidate's
    // parameter and test assignability. Checking a context-sensitive
    // argument (an arrow/function body) under a *rejected* candidate's
    // parameter can emit spurious diagnostics — e.g. `arr.reduce((sum, x) =>
    // sum + x.weight_kg, 0)` probes the non-generic `reduce(cb: (T, T) => T,
    // init: T)` overload before the generic `reduce<U>(…, init: U)`; that
    // overload types `sum` as the element `T` (an object), so the body's `+`
    // reports TS2365 — then the overload is rejected on `0` (not a `T`) and
    // the generic overload wins with `sum: number`. Roll the diagnostic list
    // back on every rejecting return so only the ACCEPTED candidate's
    // argument diagnostics survive (emitted once here; `checkCallArguments`
    // then cache-hits the same (node, ctx) check without duplicating them).
    // The rollback goes through `rollbackDiags`, which is scoped to the
    // argument list's own source range: the entries it drops also have to
    // lose their `diag_seen` keys (or the winning candidate's re-check of
    // the same spans is swallowed), and the entries it must NOT drop are
    // the ones a probe merely triggered — a symbol materialization walking
    // some other declaration's body. Both were "whole function bodies are
    // never checked".
    const saved_diags = c.diags.items.len;
    const spec_file = c.cur_file;
    // tsc's `getSignatureApplicabilityError` stops the positional walk at a
    // NON-ARRAY rest and relates the arguments from there on, PACKED into one
    // tuple, to the rest type. Overload selection runs that same check — it
    // *is* `getSignatureApplicabilityError` — so a candidate whose rest no
    // argument list of this shape satisfies has to be rejected HERE, or it
    // wins and `checkCallArguments` reports the failure moments later, which
    // is exactly the error overload resolution exists to avoid.
    //
    // `navigation.navigate('Feeds' as never)` is the case: `never` for the
    // screen name collapses the first overload's rest to `never`, which no
    // list — not even the empty one — satisfies, so the OPTIONS-bag overload
    // is the one that takes the call (social-app's `ProfileFeedgens`).
    const whole_rest = try c.sigNonArrayRest(sig);
    const whole_from: u32 = if (whole_rest) |w| w.from else std.math.maxInt(u32);
    const nargs = countArgs(arg_nodes);
    var packed_elems: std.ArrayList(types.TupleElem) = .empty;
    defer packed_elems.deinit(c.scratch());
    var ai: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        if (c.nodeTag(an) == .spread_element) {
            // A spread is not an automatic pass. tsc runs
            // `getSignatureApplicabilityError` on every candidate, and a
            // candidate with a NON-ARRAY rest type has the whole argument
            // list packed and related to that rest — so an overload whose
            // rest no spread of this shape can satisfy is REJECTED here, and
            // the next one gets its turn.
            //
            // react-navigation's `navigate` is the case: its first overload
            // takes `...args: [screen, params?, options?] | …` and its second
            // a single `{ name; params; … }` options bag, and
            // `Parameters<typeof navigation.navigate>` is the SECOND one's
            // list. `navigate(...args)` therefore has to fall through to the
            // second overload; accepting the first left `checkCallArguments`
            // to report a TS2345 tsc never sees (social-app's
            // `useNavigationDeduped`).
            //
            // Only the packs `checkCallArguments` itself spells exactly are
            // judged (`wholeSpreadPack`, and a spread that expanded to a
            // FIXED list) — every other spread keeps the unconditional pass.
            if (try spreadRestMatches(c, whole_rest, arg_nodes)) return true;
            rollbackArgProbe(c, saved_diags, spec_file, arg_nodes, .all_args);
            return false;
        }
        var pt = try c.paramTypeAt(sig, ai) orelse {
            rollbackArgProbe(c, saved_diags, spec_file, arg_nodes, .all_args);
            return false;
        };
        // The same end-relative read `checkCallArguments` uses inside the
        // window (`getContextualTypeForElementExpression`). The two have to
        // type an in-window argument identically, or this walk packs a type
        // the argument check never builds and rejects a candidate that check
        // would have accepted.
        if (whole_rest) |w| {
            if (ai >= w.from and c.ts.kind(w.ty) == .tuple) {
                if (try tuple_relate.contextualElemType(c, w.ty, ai - w.from, @intCast(nargs -| w.from))) |ct| pt = ct;
            }
        }
        const tag = c.nodeTag(an);
        // Array literals are contextually typed by the (already-inferred)
        // parameter, so a tuple parameter sees a tuple — otherwise the
        // `Promise.all` tuple overload's `values: [A, B]` would be tested
        // against a widened `(A | B)[]` and spuriously rejected. Object
        // literals likewise: without the contextual parameter a fresh
        // `{ month: 'short' }` widens its string-literal properties to
        // `string`, so an overload whose options type has literal-union
        // members (`Intl.DateTimeFormat`'s `month?: "short" | …`) is
        // spuriously rejected — the single-signature path already types
        // args by `pt`, so overload probing must match it. A nested generic
        // *call* argument is contextually typed too: `new Map(rows.map(r =>
        // [r.id, r.n]))` needs the constructor's `Iterable<readonly [K,V]>`
        // parameter to thread into `.map`'s callback so the returned array
        // literal forms a tuple — without the context the callback widens
        // to `(string|number)[]` and every Map overload is rejected.
        // A template expression needs the context for the same reason: probed
        // context-free it widens to `string`, so an overload whose inferred
        // parameter is a template-literal type (`watch(`contacts.${index}.type`)`
        // against `N extends FieldPath<T>`) is spuriously rejected — again, the
        // single-signature path already types it by `pt`.
        // A CONDITIONAL expression forwards the contextual type to both of
        // its branches (tsc's `getContextualType` → `ContextFlags` pass-
        // through for `ConditionalExpression`), so it is context-typed for
        // exactly the reason an object literal is: probed context-free, the
        // literal in a branch widens its discriminant and every candidate is
        // rejected. `useState<MessageEmbedState | undefined>(p ? {type:
        // 'post', uri: p} : undefined)` came out `{ type: string; uri: string
        // } | undefined` and fell out TS2769 — while the *single*-signature
        // form of the same call, which goes straight to `checkCallArguments`
        // with `pt`, was accepted. tsc has no allowlist here at all:
        // `checkApplicableSignature` runs `checkExpressionWithContextualType`
        // on every argument.
        // A PARENTHESIZED argument forwards the contextual type to what it
        // wraps (`checkExpr`'s `.paren_expr` arm), so it belongs on this list
        // for whatever reason its content does — and a parenthesized CALLBACK
        // needs it most: probed context-free, every un-annotated parameter of
        // it is a published TS7006 that the accepted candidate's re-check
        // cannot withdraw (`f((x => x), 10)`, `parenthesizedContexualTyping3`).
        const ctx_typed = switch (tag) {
            .arrow_fn, .function_expr, .array_literal, .object_literal, .template_expr, .cond_expr, .paren_expr, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => true,
            else => false,
        };
        // A function argument is probed on TRIAL. Its parameters take their
        // types from this candidate's contextual signature, but the body's
        // identifier reads are memoized under the (node, no-context) key —
        // so publishing them pins every read of a parameter to the type a
        // possibly-REJECTED candidate gave it, and the next candidate's
        // re-check silently reads it back. `reduce`'s non-generic overload
        // types `acc` as the element type; its leftovers turned the generic
        // overload's `acc.concat(…)` into `String.prototype.concat`'s
        // `string`, a candidate the argument never carried. The winning
        // candidate's arguments are checked — published and diagnosed — by
        // `checkCallArguments` right after this returns true, so the memo
        // still ends up holding exactly the accepted candidate's answer.
        // Parentheses included: the trial and the no-publish window are about
        // the FUNCTION being walked, which `(x => x)` still is.
        const fn_arg = switch (c.nodeTag(expr_zig.skipParens(c, an))) {
            .arrow_fn, .function_expr => true,
            else => false,
        };
        if (fn_arg) c.no_publish_depth += 1;
        const at = blk: {
            errdefer if (fn_arg) {
                c.no_publish_depth -= 1;
            };
            break :blk if (ctx_typed)
                try c.checkExprCached(an, pt)
            else
                try c.checkExprCached(an, types.no_type);
        };
        if (fn_arg) c.no_publish_depth -= 1;
        // Inside the whole-list window the PACKED relation below is the
        // verdict; position `ai` of a union rest relates to no single arm and
        // could only reject a candidate tsc accepts.
        if (ai >= whole_from) {
            try packed_elems.append(c.scratch(), .{ .ty = at });
            continue;
        }
        if (!try c.isAssignable(at, pt)) {
            rollbackArgProbe(c, saved_diags, spec_file, arg_nodes, .all_args);
            return false;
        }
        // Freshness is not part of `isAssignable` here (see
        // `freshLiteralRejects`), so an excess property on a fresh object
        // literal has to reject the candidate explicitly — otherwise the
        // first overload "matches", wins, and is then diagnosed by
        // `checkCallArguments`, which is exactly the error tsc avoids by
        // moving on to the next overload.
        if (try c.freshLiteralRejects(an, at, pt)) {
            rollbackArgProbe(c, saved_diags, spec_file, arg_nodes, .all_args);
            return false;
        }
    }
    if (whole_rest) |w| {
        if (!try c.isAssignable(try c.ts.makeTuple(packed_elems.items), w.ty)) {
            rollbackArgProbe(c, saved_diags, spec_file, arg_nodes, .all_args);
            return false;
        }
    }
    return true;
}

fn checkCallArguments(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool) Error!void {
    return checkCallArgumentsAnchored(c, node, sig, arg_nodes, report, null);
}

/// One entry of tsc's *effective* argument list — the list a spread has
/// already been expanded into.
///
/// `ty` is `no_type` for an argument written at the call site, which is typed
/// against its parameter the ordinary way. Anything else is one of tsc's
/// `SyntheticExpression`s: the type is already known (it came out of the
/// spread's tuple) and `node` is only the spread element it is blamed on.
pub const EffArg = struct {
    node: Node,
    ty: TypeId = types.no_type,
    /// The spread's OWN type, for an entry that stands for a spread the
    /// expansion left WHOLE (an array, an iterable, a union of tuples). `ty`
    /// is then only what one position of it yields, which is all the
    /// positional walk can use; the PACKED whole-list relation
    /// (`getSpreadArgumentType`) needs the un-iterated type instead.
    /// `no_type` on every entry that came out of a tuple expansion or was
    /// written at the call site.
    whole: TypeId = types.no_type,
};

/// `getSpreadArgumentType`'s FAST PATH: the type a spread the expansion left
/// WHOLE contributes to the packed rest relation, when it fills the whole-list
/// window by itself.
///
/// ```ts
/// if (index >= argCount - 1) {
///     const arg = args[argCount - 1];
///     if (isSpreadArgument(arg)) return getMutableArrayOrTupleType(…);
/// }
/// ```
///
/// `no_type` for every other window: with fixed arguments beside the spread
/// the pack needs a VARIADIC tuple element, which the tuple representation has
/// no flag for, and guessing one can only invent a rejection.
fn wholeSpreadPack(eff: []const EffArg, spread_at: ?u32, from: u32) TypeId {
    const si = spread_at orelse return types.no_type;
    if (si != from or si + 1 != eff.len) return types.no_type;
    return eff[si].whole;
}

/// tsc's `getEffectiveCallArguments`, spread half.
///
/// ```ts
/// if (spreadType && isTupleType(spreadType)) {
///     forEach(getElementTypes(spreadType), (t, i) => {
///         const flags = spreadType.target.elementFlags[i];
///         effectiveArgs.push(createSyntheticExpression(arg, t, !!(flags & ElementFlags.Variable), ...));
///     });
/// } else {
///     effectiveArgs.push(arg);
/// }
/// ```
///
/// A spread of a TUPLE contributes one entry per element; a spread of
/// anything else (an array, an iterable, a bare type parameter) stays a
/// single entry typed by what iterating it yields, which is what tsc's
/// `checkSpreadExpression` answers for the `SpreadElement` it leaves in
/// place. `[a?: T]` contributes `T | undefined`, tsc's optionality on a tuple
/// element (`h4(...t)` against `(a: string, b: number)` is
/// "'string | undefined' is not assignable to 'number'").
///
/// Returns the index of the first entry standing for an UNBOUNDED tail —
/// tsc's `getSpreadArgumentIndex` over the effective list — since from there
/// on the list's length is not known statically.
fn effectiveArgs(c: *Checker, arg_nodes: []const Node, out: *std.ArrayList(EffArg)) Error!?u32 {
    var spread_at: ?u32 = null;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        if (c.nodeTag(an) != .spread_element) {
            try out.append(c.scratch(), .{ .node = an });
            continue;
        }
        const at = try expandSpread(c, an, out);
        if (spread_at == null) spread_at = at;
    }
    return spread_at;
}

/// One spread argument's contribution to the effective list. Returns the index
/// (in `out`) of the first entry it appended that stands for an UNBOUNDED tail
/// — tsc's `SyntheticExpression.isSpread`, which is what
/// `getSpreadArgumentIndex` looks for.
pub fn expandSpread(c: *Checker, an: Node, out: *std.ArrayList(EffArg)) Error!?u32 {
    // Types the spread element itself, exactly as the pre-expansion walk did:
    // `checkExpr`'s `.spread_element` arm answers with the spread OPERAND's
    // type, so this both fills the node's memo and gives the type to expand.
    var st = try c.resolveStructural(try c.checkExprCached(an, types.no_type));
    // tsc's `isSpreadIntoCallOrNew`: an ARRAY LITERAL spread into a call is
    // re-read as a TUPLE (`checkArrayLiteral`'s `inTupleContext`), so
    // `f(1, 2, 3, 4, ...[5, 6])` spends exactly two more positions rather than
    // an unbounded tail. ztsc's `checkArrayLiteral` has no call context to see
    // that from, so rebuild the tuple here out of the literal's own elements.
    // A literal that itself holds a spread or an elision has no fixed shape and
    // keeps the array reading.
    if (c.ts.kind(st) != .tuple) tupleize: {
        const lit = expr_zig.skipParens(c, c.tree.nodeData(an).lhs);
        if (lit == null_node or c.nodeTag(lit) != .array_literal) break :tupleize;
        var elems: std.ArrayList(types.TupleElem) = .empty;
        defer elems.deinit(c.scratch());
        for (c.tree.nodeRange(lit)) |el| {
            if (el == null_node or c.nodeTag(el) == .omitted or
                c.nodeTag(el) == .spread_element) break :tupleize;
            const et = c.nodeType(el) orelse break :tupleize;
            try elems.append(c.scratch(), .{ .ty = try c.widenLiteral(et) });
        }
        st = try c.ts.makeTuple(elems.items);
    }
    if (c.ts.kind(st) == .tuple) {
        var unbounded: ?u32 = null;
        for (0..c.ts.tupleLen(st)) |i| {
            const e = c.ts.tupleElem(st, @intCast(i));
            var ty = e.ty;
            if (e.rest()) {
                ty = try c.elemOfArrayish(e.ty);
                if (unbounded == null) unbounded = @intCast(out.items.len);
            } else if (e.optional()) {
                ty = try c.makeUnion2(e.ty, types.undefined_type);
            }
            try out.append(c.scratch(), .{ .node = an, .ty = ty });
        }
        return unbounded;
    }
    const at: u32 = @intCast(out.items.len);
    const elem = (try c.iterationElementType(st)) orelse {
        // Not iterable (already its own diagnostic elsewhere): one opaque
        // entry, so the positions after it still line up.
        try out.append(c.scratch(), .{ .node = an, .ty = types.error_type });
        return at;
    };
    try out.append(c.scratch(), .{ .node = an, .ty = elem, .whole = st });
    return at;
}

/// TS2488 for a spread ARGUMENT whose operand carries no `[Symbol.iterator]()`
/// protocol — tsc's `checkSpreadExpression`, which ends in
/// `checkIteratedTypeOrElementType(IterationUse.Spread, …, node.expression)`
/// and so blames the OPERAND, exactly as the array-literal spread arm in
/// `expr.zig` already does. `iter = { *[Symbol.iterator](_: number) {…} }` has
/// a `[Symbol.iterator]` that is not callable with zero arguments, and
/// `g(...iter)` was the one of its four uses ztsc left silent
/// (`iteratorExtraParameters`).
///
/// Not in `expandSpread`: that also runs for inference (`infer.zig`) and for
/// the silent rest-pack probe (`spreadRestMatches`), neither of which is a
/// place to file a diagnostic. This walk is over the WRITTEN arguments and
/// runs once the expansion has filled each operand's type memo.
fn reportNonIterableSpreads(c: *Checker, arg_nodes: []const Node) Error!void {
    for (arg_nodes) |an| {
        if (an == null_node or c.nodeTag(an) != .spread_element) continue;
        const operand = c.tree.nodeData(an).lhs;
        if (operand == null_node) continue;
        const raw = c.nodeType(operand) orelse continue;
        const st = try c.resolveStructural(raw);
        // Arrays and tuples never reach the protocol, and `none` is the
        // "nothing was typed" answer — the same guards the array-literal arm
        // carries.
        switch (c.ts.kind(st)) {
            .array, .tuple, .none => continue,
            else => {},
        }
        if (try c.iterationElementType(st) != null) continue;
        // A DEFERRED type is not a shape the protocol can be read off, and
        // tsc's `getIteratedTypeOrElementType` asks its base constraint
        // instead: `T extends (...args: any[]) => any` makes `Parameters<T>`
        // an `any[]`, so `cb(...args)` on one is fine (social-app's
        // `useRequireEmailVerification`). An unconstrained type parameter
        // still reports — its constraint is `unknown`, which is not iterable
        // either, and tsgo agrees.
        const con = try c.baseConstraintOf(st);
        if (con != st and try c.iterationElementType(try c.resolveStructural(con)) != null) continue;
        try c.diagFmt(2488, c.nodeSpan(operand), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{
            try c.typeToString(st),
        });
    }
}

/// `checkCallArguments`, reporting back WHERE it blamed the arguments.
///
/// `anchor_out`, when given, receives the span of the first diagnostic this
/// walk files *about an argument* — the argument's own span, or the inner
/// property/element span an elaboration moved it to. It stays null when the
/// arguments are fine (or when the only complaint is arity, which is not a
/// per-argument blame). Overload-failure reporting needs exactly that span
/// for its TS2769 and cannot recover it from the diagnostic list, which also
/// holds whatever the argument expressions said about themselves.
fn checkCallArgumentsAnchored(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool, anchor_out: ?*?Span) Error!void {
    // Owned-file guard (see `checkJsxElement`). `void` result, and the
    // call's *type* is settled before this runs: `resolveSignatureCall`
    // returns `fnReturn(inst)`, where `inst` comes from
    // `instantiateSigForCall` (which does its own argument unification),
    // and overload selection uses `argumentsMatch`, not this. So arity
    // (TS2554/2555), per-argument assignability (TS2345) and the excess
    // property check are the entire payload here, and `seal` drops all of
    // them in a file this checker does not own. The `checkExprCached` calls
    // this skips only fill a memo other readers re-derive on miss.
    if (!c.owned_mask[c.cur_file]) return;
    const nargs = countArgs(arg_nodes);
    const required = @min(try c.requiredParams(sig), iifeMinArgs(c, node, nargs));
    const total = try c.paramTotal(sig);
    // A TRUNCATION IS NOT AN ARITY. `instantiateId`'s depth/count guard fires
    // *before* the `.function` arm runs and collapses the whole signature to
    // `error_type`, and every `fn*` accessor then reads that as a signature
    // with ZERO parameters — so a call whose substitution merely ran out of
    // budget was reported "Expected 0 arguments, but got 1". tsc cannot reach
    // that state: `instantiateSignature` clones the signature and
    // instantiates each parameter lazily and independently, so a limit hit
    // degrades a component to `errorType` while the shape — arity,
    // optionality, `this` — always survives.
    //
    // The types are deliberately left alone (`error_type` is a suppressing
    // type and short-circuits the rest of the walk, which is what keeps the
    // truncated statement cheap); only the ARITY CLAIM is withdrawn, because
    // it is the one thing a truncation cannot have an opinion about.
    // Rebuilding the shape instead — arity kept, every component
    // `error_type` — was measured on immich and is worse: 190 -> 194, with
    // TS7006 74 -> 107, because an `error_type` parameter then overwrites
    // each callback argument's contextual type with one that types its
    // parameters `any`.
    const arity_known = c.ts.kind(sig) == .function;
    // tsc's `getEffectiveCallArguments`: a spread of a TUPLE stands for its
    // elements, one argument each, so every argument after it lands on the
    // position it really occupies. Without the expansion a spread was ONE
    // opaque argument and everything it carried went unrelated
    // (`callWithSpread2`, `callWithSpread3`).
    var eff: std.ArrayList(EffArg) = .empty;
    defer eff.deinit(c.scratch());
    const spread_at = try effectiveArgs(c, arg_nodes, &eff);
    try reportNonIterableSpreads(c, arg_nodes);
    // tsc's `hasCorrectArity` for a list that still holds an UNBOUNDED spread:
    // the position it starts at must be one the signature can reach, and the
    // tail it stands for must land in a rest parameter.
    //
    // ```ts
    // if (spreadArgIndex >= 0) {
    //     return spreadArgIndex >= getMinArgumentCount(signature) &&
    //         (hasEffectiveRestParameter(signature) || spreadArgIndex < getParameterCount(signature));
    // }
    // ```
    //
    // When it does not fit, tsc's whole answer about the call is TS2556 on
    // that spread — no argument is related at all, so the expanded entries
    // stay silent rather than inventing a rejection out of a list whose
    // length is not known statically.
    const spread_fits = if (spread_at) |si|
        si >= required and (total == std.math.maxInt(u32) or si < total)
    else
        true;
    var arity_failed = false;
    if (report and arity_known) {
        if (spread_at) |si| {
            // An IIFE is exempt: tsc's `isOptionalParameter` makes every
            // un-annotated parameter of one optional from the effective
            // argument count on, so its declared arity is never what the
            // spread failed to satisfy — `(function (a, b, c) {})(...t)` with
            // `t: [number, ...number[]]` is silent where the same call on a
            // NAMED `(a: number, b: number, c: number)` is TS2556.
            if (!spread_fits and iifeCallee(c, c.callShape(node).callee) == null_node) {
                try c.diagFmt(2556, argErrorSpan(c, eff.items[si].node), "A spread argument must either have a tuple type or be passed to a rest parameter.", .{});
            }
        } else {
            // No unbounded entry left, so the argument COUNT is known — even
            // when the call was written with a spread, because every one of
            // them expanded to a fixed list. tsc counts the EFFECTIVE
            // arguments, an optional tuple element included: `f(...t)` with
            // `t: [string, string?]` against `(a: string)` is
            // "Expected 1 arguments, but got 2".
            const n = eff.items.len;
            if (n < required or n > total) {
                try reportArityError(c, node, eff.items, n, required, total, total == std.math.maxInt(u32));
                arity_failed = true;
            }
        }
    }
    // An ARITY failure is the whole verdict: tsc's `chooseOverload` rejects a
    // candidate `hasCorrectArity` refuses BEFORE `getSignatureApplicability-
    // Error` ever runs, so it joins `candidateForArgumentArityError` and never
    // `candidatesForArgumentError` — and `reportCallResolutionErrors` reports
    // out of exactly one pile. `new Derived2(1)` against `(y: string, z:
    // string)` is TS2554 alone, where ztsc also blamed `1` for not being a
    // `string` (`derivedClassWithoutExplicitConstructor3`). The arguments are
    // still TYPED below — that is what contextually types a callback and fills
    // the node memo — only their verdict is withdrawn.
    const report_args = report and !arity_failed;
    // tsc reports at most ONE argument error per call. `checkApplicableSignature`
    // walks the arguments in order and returns as soon as one fails, so the
    // arguments after it are never related to their parameters at all — and
    // with a generic signature they could not be judged fairly anyway, since
    // the failing argument is often what mis-inferred the type argument the
    // rest are checked against. `two("x", 1)` against `two(a: number, b:
    // string)` is one TS2345, not two.
    //
    // tsc's `getSignatureApplicabilityError`: a signature with a NON-ARRAY
    // rest type stops the positional walk at the rest position and relates
    // the arguments from there on, packed into ONE tuple, to the rest type —
    // so exactly one arm of a union rest has to accept the whole list. Below
    // `whole_from` the walk is positional, exactly as before.
    //
    // Per-position typing still runs for those arguments (that is what
    // contextually types a callback argument and what gives an optional
    // position its `| undefined`); only the REPORT moves to the packed
    // relation, which subsumes it — a per-position failure fails the packed
    // one too, so the two never both fire.
    //
    // A spread does not by itself put the packed relation out of reach — it
    // only decides what goes INTO the tuple:
    //
    //   * a spread the expansion turned into a FIXED list (`spread_at` null)
    //     contributes exactly those entries, so the pack is the same one the
    //     no-spread walk builds;
    //   * a spread left WHOLE that fills the window BY ITSELF is
    //     `getSpreadArgumentType`'s fast path — the packed type IS the
    //     spread's own type, no positional guess involved:
    //
    //     ```ts
    //     if (index >= argCount - 1) {
    //         const arg = args[argCount - 1];
    //         if (isSpreadArgument(arg)) return getMutableArrayOrTupleType(…);
    //     }
    //     ```
    //
    //     so `h(...u)` with `u: [number] | [number, number]` against
    //     `(...rest: [string] | [string, number])` relates the two unions
    //     directly — the shape social-app's `navigate(...args)` is written in,
    //     where `Parameters<typeof navigate>` is a union of tuples and NO
    //     per-position reading of it relates to any single arm.
    //
    // Anything else — a whole spread with fixed arguments beside it in the
    // window — would need a VARIADIC tuple element to pack faithfully, which
    // the tuple representation has no flag for, so it keeps the drop: the
    // packed tuple would be a guess, and guessing here can only invent a
    // rejection.
    var packed_whole: TypeId = types.no_type;
    const whole_rest: ?NonArrayRest = wr: {
        const w = try c.sigNonArrayRest(sig) orelse break :wr null;
        if (spread_at == null) break :wr w;
        if (!spread_fits) break :wr null;
        packed_whole = wholeSpreadPack(eff.items, spread_at, w.from);
        break :wr if (packed_whole == types.no_type) null else w;
    };
    const whole_from: u32 = if (whole_rest) |w| w.from else std.math.maxInt(u32);
    var packed_elems: std.ArrayList(types.TupleElem) = .empty;
    defer packed_elems.deinit(c.scratch());
    var packed_first: Node = null_node;
    var reported_arg = false;
    var ai: u32 = 0;
    for (eff.items) |ea| {
        const an = ea.node;
        // An entry the spread expansion typed itself: there is no expression
        // to check against a contextual type, and none of the elaborations
        // below (each keyed on the argument's own syntax) applies to it.
        const synthetic = ea.ty != types.no_type;
        defer ai += 1;
        var pt = try c.paramTypeAt(sig, ai) orelse {
            if (!synthetic) _ = try c.checkExprCached(an, types.no_type);
            continue;
        };
        // Inside the whole-list window, `paramTypeAt` has no answer: the target
        // position an argument lands on is decided by counting back from the
        // END of the list (tsc's `getContextualTypeForElementExpression`, which
        // `getSpreadArgumentType` uses for exactly this). Reading position `ai`
        // from the start gave every callback the union of the tuple's element
        // types, so `f1(x => str(x))` against
        // `(...args: [...((a: number) => void)[], (a: string) => void])` typed
        // `x` as `number | string` and reported inside the callback's own body.
        if (whole_rest) |w| {
            if (ai >= w.from and c.ts.kind(w.ty) == .tuple) {
                if (try tuple_relate.contextualElemType(c, w.ty, ai - w.from, @intCast(nargs -| w.from))) |ct| pt = ct;
            }
        }
        const at = if (synthetic) ea.ty else try c.checkExprCached(an, pt);
        if (ai >= whole_from) {
            if (packed_first == null_node) packed_first = an;
            try packed_elems.append(c.scratch(), .{ .ty = at });
            continue;
        }
        if (report_args and (spread_fits or !synthetic) and !try c.isAssignable(at, pt)) {
            if (reported_arg) continue;
            const before = c.diags.items.len;
            if (synthetic) {
                try c.reportNotAssignable(2345, at, pt, argErrorSpan(c, an));
            } else if (!(callbackElaborates(c, an) and try c.elaborateCallbackError(an, at, pt)) and
                !try c.elaborateLiteralError(an, at, pt) and
                // A fresh object-literal argument with an unknown property is
                // tsc's TS2353/TS2561 on that property, not a TS2345 on the
                // argument — `hasExcessProperties` decides inside the relation,
                // so it wins over the whole-argument report here too
                // (`excessPropertyFailure`).
                !try c.excessPropertyFailure(an, at, pt))
            {
                // `reportNotAssignable` owns the TS2741/2739/2740
                // missing-property refinement, which tsc applies in argument
                // position too; its 2345 arm gates it on `elaborate`'s descent
                // reaching an unmatched property, so a pair that failed
                // EARLIER in the walk — assignability/094 (`Opt<T>`'s base
                // type argument) and narrowing/085 (a `T & string` source) are
                // both that shape — keeps the TS2345 head.
                try c.reportNotAssignable(2345, at, pt, argErrorSpan(c, an));
            }
            noteArgBlame(c, anchor_out, before, c.nodeSpan(an), argErrorSpan(c, an));
            reported_arg = true;
        } else if (report_args and !synthetic and !reported_arg) {
            // The excess-property check is part of the same walk tsc stops
            // at the first failure, so a later argument's excess property
            // is not reported either.
            const before = c.diags.items.len;
            try c.excessPropertyCheck(an, at, pt);
            if (c.diags.items.len == before and
                try c.freshLiteralUnionMismatch(an, at, pt, 2345, argErrorSpan(c, an)))
            {
                reported_arg = true;
            } else if (c.diags.items.len != before) {
                reported_arg = true;
            }
            if (reported_arg) noteArgBlame(c, anchor_out, before, c.nodeSpan(an), argErrorSpan(c, an));
        }
    }
    if (report_args and !reported_arg and whole_rest != null) {
        const rest_ty = whole_rest.?.ty;
        const packed_ty = if (packed_whole != types.no_type)
            packed_whole
        else
            try c.ts.makeTuple(packed_elems.items);
        if (!try c.isAssignable(packed_ty, rest_ty)) {
            // tsc's error node: the single rest argument, or the range from
            // the first to the last of them; with none at all, the call.
            const span = if (packed_first != null_node) argErrorSpan(c, packed_first) else c.nodeSpan(node);
            const before = c.diags.items.len;
            try c.reportNotAssignable(2345, packed_ty, rest_ty, span);
            noteArgBlame(c, anchor_out, before, span, span);
        }
    }
}

/// Does tsc's `elaborateError` descend into this argument's RETURN, moving the
/// blame off the whole argument and onto the returned expression?
///
/// Only for the shape its switch dispatches to `elaborateArrowFunction`, and
/// only past that function's own two opening guards:
///
/// ```ts
/// case SyntaxKind.ArrowFunction: return elaborateArrowFunction(…);
/// …
/// function elaborateArrowFunction(node, …) {
///     // Don't elaborate blocks
///     if (isBlock(node.body)) return false;
///     // Or functions with annotated parameter types
///     if (some(node.parameters, hasType)) return false;
/// ```
///
/// So a CONCISE-bodied arrow with no annotated parameter reports on its body
/// (`foo3(n => 'a')` is TS2322 at `'a'`), and a block-bodied arrow, an arrow
/// with an annotated parameter, and a `function` expression are all the plain
/// whole-argument TS2345 — all four tsgo-verified. ztsc offered the
/// elaboration for every function-shaped argument, which turned each of the
/// other three into a TS2322 at a span tsc does not report at all.
fn callbackElaborates(c: *Checker, arg_node: Node) bool {
    if (c.nodeTag(arg_node) != .arrow_fn) return false;
    const d = c.tree.nodeData(arg_node);
    if (d.rhs == 0 or c.nodeTag(d.rhs) == .block) return false;
    const proto = c.tree.extraData(ast.FnProto, d.lhs);
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node) continue;
        const pd = c.tree.nodeData(p);
        const ann: Node = switch (c.nodeTag(p)) {
            .param => pd.rhs,
            .param_full => c.tree.extraData(ast.ParamFull, pd.rhs).type_ann,
            else => 0,
        };
        if (ann != 0) return false;
    }
    return true;
}

/// Record where an argument report landed, for `resolveSignatureCall`'s TS2769.
///
/// The span taken is the first diagnostic the report just filed that lies
/// INSIDE the argument — `elaborateLiteralError` and the excess-property check
/// legitimately move the blame onto a property of an object-literal argument,
/// exactly as tsc's `elaborateError` does, and that inner node is then also
/// tsc's TS2769 anchor. A diagnostic filed outside `arg_span` is something the
/// report merely triggered; `fallback` (the argument's own error span) stands in
/// for it, as it does when the report was swallowed as a duplicate of one
/// already filed.
fn noteArgBlame(c: *Checker, anchor_out: ?*?Span, before: usize, arg_span: Span, fallback: Span) void {
    const out = anchor_out orelse return;
    if (out.* != null) return;
    for (c.diags.items[before..]) |d| {
        if (d.file != c.cur_file) continue;
        if (d.span.start < arg_span.start or d.span.start >= arg_span.end) continue;
        out.* = d.span;
        return;
    }
    out.* = fallback;
}

/// tsc's `getErrorSpanForNode` for an argument expression.
///
/// ztsc's `nodeSpan` is the span of a node's whole token subtree, which is what
/// tsc's `node.pos`/`node.end` give for most expressions — but not for the two
/// FUNCTION forms, and a function is what a callback argument usually is:
///
///   * a FUNCTION EXPRESSION errors on its NAME (`errorNode = node.name`), so
///     `React.forwardRef(function Layout_(props, ref) {…})` blames `Layout_`,
///     not the `function` keyword nine columns to its left. Anonymous ones fall
///     back to the first token, which is what the subtree span already gives.
///   * an ARROW FUNCTION errors from `skipTrivia(node.pos)`
///     (`getErrorSpanForArrowFunction`) — the leftmost token of the whole arrow,
///     including the `async` modifier and the parameter list's `(`. Neither is a
///     token of any child node, so the subtree span starts at the first
///     PARAMETER instead: `useEventListener("keydown", (event: KeyboardEvent)
///     => {…})` blamed `event`, one column right of tsc's `(`, and
///     `router.post("x", async (ctx) => {…})` blamed `ctx`, seven right of
///     tsc's `async`.
///
/// The arrow's opening tokens are recovered from the source text rather than the
/// token array (the AST records only the `=>`); an intervening comment stops the
/// walk, leaving the span where it already was.
/// The other half of tsc's IIFE rule (`iifeContextualSig` is the first): the
/// smallest argument count the callee of `node` demands, once tsc's
/// `isOptionalParameter` has been applied to it.
///
/// ```ts
/// const iife = getImmediatelyInvokedFunctionExpression(node.parent);
/// if (iife) {
///     return !node.type && !node.dotDotDotToken &&
///         node.parent.parameters.indexOf(node) >= getEffectiveCallArguments(iife).length;
/// }
/// ```
///
/// An unannotated, non-rest parameter of an IIFE past the last argument is
/// OPTIONAL — which is what makes `((x, y, z) => 42)()` and
/// `(function (x, undefined) { return x; })(42)` legal in tsgo where ztsc
/// reported TS2554. It is the arity counterpart of the `undefined` those
/// parameters are typed as: a parameter tsc gives a type to unconditionally
/// cannot also be one the caller has to supply.
///
/// `maxInt` — no constraint — for a callee that is not an IIFE, so the caller's
/// `@min` leaves the ordinary count alone. Only the too-FEW direction moves;
/// the maximum still comes from the parameter list, since a surplus argument
/// has no parameter to be optional at.
fn iifeMinArgs(c: *Checker, node: Node, nargs: usize) u32 {
    const fnode = iifeCallee(c, c.callShape(node).callee);
    if (fnode == null_node) return std.math.maxInt(u32);
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fnode).lhs);
    var pi: u32 = 0;
    var min: u32 = 0;
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        if (pn == null_node) continue;
        defer pi += 1;
        const d = c.tree.nodeData(pn);
        const ann: Node = switch (c.nodeTag(pn)) {
            .param => d.rhs,
            .param_full => c.tree.extraData(ast.ParamFull, d.rhs).type_ann,
            else => 0,
        };
        const rest = c.nodeTag(pn) == .param_full and
            c.tree.extraData(ast.ParamFull, d.rhs).flags & ast.Flags.rest != 0;
        if (pi >= nargs and ann == 0 and !rest) continue;
        min = pi + 1;
    }
    return min;
}

/// tsc's `getArgumentArityError`, message and SPAN both. `min`/`max` are the
/// parameter counts over the whole candidate set (a lone signature is a set of
/// one) and `has_rest` says some candidate takes a rest parameter — which is
/// what turns "Expected N" into "Expected at least N", and what makes the
/// too-many branch unreachable (a rest candidate accepts any surplus).
///
/// Verified against tsgo 7.0.2, whose three spans are all different:
/// too FEW arguments blames the callee (the member NAME for `o.m()`, the whole
/// node for `new`), too MANY blames the surplus ARGUMENTS, and the
/// "no overload expects N" form blames the callee again.
fn reportArityError(
    c: *Checker,
    node: Node,
    eff: []const EffArg,
    nargs: usize,
    min: u32,
    max: u32,
    has_rest: bool,
) Error!void {
    if (has_rest) {
        try c.diagFmt(2555, calleeErrorSpan(c, node), "Expected at least {d} arguments, but got {d}.", .{ min, nargs });
        return;
    }
    const span = if (nargs > max)
        extraArgsSpan(c, eff, max) orelse calleeErrorSpan(c, node)
    else
        calleeErrorSpan(c, node);
    if (min != max) {
        try c.diagFmt(2554, span, "Expected {d}-{d} arguments, but got {d}.", .{ min, max, nargs });
    } else {
        try c.diagFmt(2554, span, "Expected {d} arguments, but got {d}.", .{ max, nargs });
    }
}

/// Where tsc's `getDiagnosticForCallNode` puts a call-level diagnostic: only a
/// CALL narrows to its callee — and to the member NAME when the callee is a
/// member access — while `new`, a tagged template and a decorator all report
/// on the whole node.
fn calleeErrorSpan(c: *Checker, node: Node) Span {
    switch (c.nodeTag(node)) {
        .call_expr, .call_expr_targs, .optional_call => {},
        else => return c.nodeSpan(node),
    }
    const callee = c.callShape(node).callee;
    return switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr => c.tokSpan(c.tree.nodeData(callee).rhs),
        else => c.nodeSpan(callee),
    };
}

/// `args[max].pos` through the last argument's end — tsc's span for a call
/// with too many arguments. Null when there is no argument at that position
/// (nothing to blame, so the caller falls back to the callee).
fn extraArgsSpan(c: *Checker, eff: []const EffArg, from: u32) ?Span {
    var i: u32 = 0;
    var start: ?u32 = null;
    var end: u32 = 0;
    for (eff) |ea| {
        const an = ea.node;
        defer i += 1;
        if (i < from) continue;
        const sp = c.nodeSpan(an);
        if (start == null) start = sp.start;
        end = sp.end;
    }
    const s = start orelse return null;
    return .{ .start = s, .end = if (end > s) end else s + 1 };
}

fn argErrorSpan(c: *Checker, n: Node) Span {
    const span = c.nodeSpan(n);
    switch (c.nodeTag(n)) {
        .function_expr => {
            const name_tok = c.tree.extraData(ast.FnProto, c.tree.nodeData(n).lhs).name_token;
            if (name_tok == 0) return span;
            return .{
                .start = c.tree.tokens.start(name_tok),
                .end = c.tree.tokens.end(c.src, name_tok),
            };
        },
        .arrow_fn => {
            var start = span.start;
            // `(params)` — the parameter list's own parens. With no parameters
            // the subtree starts at the `=>`, so the empty pair `()` is
            // stepped over as a unit.
            var i = skipTriviaBack(c.src, start);
            if (i > 0 and c.src[i - 1] == ')') {
                const j = skipTriviaBack(c.src, i - 1);
                if (j > 0 and c.src[j - 1] == '(') i = j;
            }
            if (i > 0 and c.src[i - 1] == '(') {
                start = i - 1;
                i = skipTriviaBack(c.src, start);
            }
            // `async` — a modifier, part of the arrow's `pos` in tsc.
            if (i >= 5 and std.mem.eql(u8, c.src[i - 5 .. i], "async") and
                (i == 5 or !isIdentByte(c.src[i - 6])))
            {
                start = i - 5;
            }
            return .{ .start = start, .end = span.end };
        },
        else => return span,
    }
}

/// The offset of the first non-whitespace byte at or before `at`, exclusive of
/// `at` itself. Comments are NOT skipped: a `//` run cannot be recognized
/// scanning backwards, and stopping at one only leaves the span unmoved.
fn skipTriviaBack(src: []const u8, at: u32) u32 {
    var i = at;
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t' or
        src[i - 1] == '\n' or src[i - 1] == '\r')) : (i -= 1)
    {}
    return i;
}

fn isIdentByte(ch: u8) bool {
    return ch == '_' or ch == '$' or std.ascii.isAlphanumeric(ch);
}
