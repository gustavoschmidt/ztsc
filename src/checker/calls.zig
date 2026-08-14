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

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const ModuleRef = @import("typenode.zig").ModuleRef;
const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const ambientNamespaceType = @import("signatures.zig").ambientNamespaceType;
const ChainLink = @import("expr.zig").ChainLink;
const checkExprCached = @import("expr.zig").checkExprCached;
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

/// `import("m")` in *expression* position: `Promise<<namespace object of
/// m>>`, tsc's `getTypeOfImportCall`. The specifier resolves through the
/// same two registries the type-position `import("m")` uses — the current
/// file's specifier map, then the ambient `declare module` registry — and
/// the namespace object is the same one `import * as ns from "m"` gets, so
/// an `export =` module reaches its export-assigned entity.
///
/// Everything else stays `any`: a non-literal specifier (tsc cannot
/// resolve it either), an unresolved module (already TS2307 at the
/// statement level, or deliberately opaque), and a program with no lib
/// (no global `Promise` to wrap with). No diagnostic is reported here —
/// resolution failures belong to the resolver.
fn importCallType(c: *Checker, arg_nodes: []const Node) Error!TypeId {
    if (arg_nodes.len == 0) return types.any_type;
    const spec_node = arg_nodes[0];
    // A no-substitution template literal is a literal specifier too, and the
    // binder registers it as a dependency (`bindDynamicImport`); `memberAtom`
    // only strips quotes, so the backticked form needs `templateAtom`.
    const spec = switch (c.nodeTag(spec_node)) {
        .string_literal => try c.memberAtom(c.tree.nodeMainToken(spec_node)),
        .template_literal => try c.templateAtom(c.tree.nodeMainToken(spec_node)),
        else => return types.any_type,
    };
    var m: ModuleRef = blk: {
        if (c.prog.files.len != 0) {
            if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| break :blk .{ .file = mfile };
        }
        break :blk .{ .ambient = c.ambientIndex(spec) orelse return types.any_type };
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

/// Call/new as an optional-chain link (see `memberChainInner`). Answers the
/// return type WITHOUT the chain's short-circuit `undefined`, plus `chained`
/// when this `?.()` — or an earlier link in the callee spine — short-circuits
/// on a nullish callee.
pub fn checkCallExprInner(c: *Checker, node: Node, is_new: bool, ctx: TypeId) Error!ChainLink {
    var chained = false;
    const shape = c.callShape(node);
    // `import("m")` is not an ordinary call — `import` has no type of its
    // own. tsc's `getTypeOfImportCall`: the module's namespace object,
    // wrapped in `Promise`.
    if (!is_new and c.nodeTag(shape.callee) == .import_expr) {
        return .{ .ty = try importCallType(c, shape.arg_nodes), .chained = chained };
    }
    var callee_t = if (c.isOptionalChain(shape.callee)) blk: {
        const link = try c.chainObjType(shape.callee);
        if (link.chained) chained = true;
        break :blk link.ty;
    } else try c.checkExprCached(shape.callee, types.no_type);
    if (shape.optional) {
        if (c.containsNullish(callee_t)) chained = true;
        callee_t = try c.nonNullableChain(callee_t);
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
    if (!is_new and c.nodeTag(shape.callee) == .super_expr) {
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
    if (rk == .intersection) {
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
    if (rk == .any or rk == .err or isect_any) {
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
        if (rk == .class_value) {
            const cls = c.ts.classSymbol(r);
            if (try c.classIsAbstract(cls)) {
                try c.diagFmt(2511, c.nodeSpan(node), "Cannot create an instance of an abstract class.", .{});
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
                const fixed = try c.fixTypeArgs(cls, targs.items, c.tree.nodeMainToken(node)) orelse return .{ .ty = types.error_type, .chained = chained };
                @memcpy(inst_args, fixed);
            } else if (tps.items.len > 0) {
                // Infer class type args from ctor arguments.
                const ctor = if (ctor_sigs.items.len > 0) ctor_sigs.items[0] else types.no_type;
                if (ctor != types.no_type) {
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
                    const self_sig = try c.sigWithReturn(ctor, try c.ts.makeRef(cls, self_args));
                    try inferTypeArgs(c, self_sig, tp_syms, shape.arg_nodes, inst_args, ctx, types.no_type);
                } else {
                    for (inst_args) |*x| x.* = types.any_type;
                }
            }
            instance_ret = try c.ts.makeRef(cls, inst_args);
            if (ctor_sigs.items.len == 0) {
                // Default constructor: no args allowed beyond none? tsc
                // allows zero args (inherited default). Check arity 0.
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                if (countArgs(shape.arg_nodes) > 0) {
                    try c.diagFmt(2554, c.nodeSpan(node), "Expected 0 arguments, but got {d}.", .{countArgs(shape.arg_nodes)});
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
            for (0..c.ts.objectConstructSigCount(r)) |i| {
                try sigs.append(c.scratch(), c.ts.objectConstructSig(r, @intCast(i)));
            }
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
                        if (try combinedUnionSignature(c, sigs.items, ctor_starts.items)) |combined| {
                            sigs.clearRetainingCapacity();
                            try sigs.append(c.scratch(), combined);
                        }
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
            // Calling `never` is silently `never` (tsc; typically the
            // non-nullable remainder of a null-narrowed reference).
            .never => {
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return .{ .ty = types.never_type, .chained = chained };
            },
            // Callable object with call signatures.
            .object => {
                if (c.ts.objectCallSigCount(r) == 0) {
                    if (try untypedFunctionCall(c, callee_t, r, rk)) {
                        for (shape.arg_nodes) |an| {
                            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                        }
                        return .{ .ty = types.any_type, .chained = chained };
                    }
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
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
                    if (try combinedUnionSignature(c, sigs.items, starts.items)) |combined| {
                        sigs.clearRetainingCapacity();
                        try sigs.append(c.scratch(), combined);
                    }
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
                try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
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
    const callee = c.callShape(node).callee;
    var recv: TypeId = types.void_type;
    switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {
            recv = try c.checkExprCached(c.tree.nodeData(callee).lhs, types.no_type);
        },
        else => {},
    }
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
fn resolveSignatureCall(
    c: *Checker,
    node: Node,
    sigs: []const TypeId,
    explicit_targs: []const TypeId,
    arg_nodes: []const Node,
    instance_ret: TypeId,
    ret_ctx: TypeId,
) Error!TypeId {
    if (sigs.len == 0) return types.any_type;
    const nargs = countArgs(arg_nodes);
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
        const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        if (instance_ret == types.no_type) try checkThisArg(c, node, inst);
        try checkCallArguments(c, node, inst, arg_nodes, true);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
    }
    // Overloads: first signature whose arity fits and whose args check.
    //
    // tsc's `resolveCall` keeps two rejection piles: `candidatesForArgumentError`
    // (arity fit, arguments did not) and `candidatesForArgumentArityError`. Only
    // the first pile decides how the failure is REPORTED, and how many are in it
    // decides where the report lands — so count them here.
    var arg_err_count: usize = 0;
    var last_arg_err: TypeId = types.no_type;
    var arity: ArityTally = .{};
    for (sigs) |sig| {
        // With explicit type arguments, only a signature with the matching
        // type-parameter count is a candidate (tsc). Skips e.g. the
        // non-generic `new (): Map<any, any>` when `new Map<K, V>()` names
        // two type args, so the generic overload is chosen instead.
        if (explicit_targs.len > 0 and !c.sigTargArityOk(sig, explicit_targs.len)) continue;
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
        if (nargs < req or nargs > tot) {
            // Fold this candidate into the set-wide arity picture tsc reports
            // when NO candidate ever reaches argument checking. A truncated
            // instantiation has no arity to contribute (see `checkCallArguments`).
            if (c.ts.kind(inst) == .function) arity.note(req, tot, nargs);
            c.rollbackArgDiags(saved_infer, infer_file, arg_nodes);
            c.inst_count = saved_inst_count;
            c.newBudgetWindow();
            c.inst_limit_tripped = saved_inst_trip;
            continue;
        }
        if (try c.argumentsMatch(inst, arg_nodes)) {
            try checkCallArguments(c, node, inst, arg_nodes, true);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
        }
        c.rollbackArgDiags(saved_infer, infer_file, arg_nodes);
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
    // A call carrying a SPREAD argument is left alone: its argument count is not
    // known statically, so tsc answers with TS2556 about the spread instead, and
    // guessing a count here could only invent an arity claim.
    if (arg_err_count == 0 and arity.seen and !hasSpreadArg(c, arg_nodes)) {
        if (nargs > arity.min and nargs < arity.max and !arity.rest) {
            try c.diagFmt(2575, calleeErrorSpan(c, node), "No overload expects {d} arguments, but overloads do exist that expect either {d} or {d} arguments.", .{
                nargs, arity.below orelse arity.min, arity.above orelse arity.max,
            });
        } else {
            try reportArityError(c, node, arg_nodes, nargs, arity.min, arity.max, arity.rest);
        }
        // Type the arguments (no report) and carry on with the first candidate,
        // exactly as the TS2769 path below does.
        const inst_one = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        for (arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
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
        const inst_one = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        for (arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
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
    if (arg_anchor) |a| {
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
    const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
    for (arg_nodes) |an| {
        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
    }
    return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
}

/// Instantiate a (possibly generic) signature for a call: explicit
/// type args win; otherwise unify parameters against arguments
/// (two-phase: plain args first, then context-sensitive function args).
pub fn instantiateSigForCall(c: *Checker, sig: TypeId, explicit_targs: []const TypeId, arg_nodes: []const Node, node: Node, ret_ctx: TypeId) Error!TypeId {
    const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
    if (tps.len == 0) return sig;
    var args_buf = try c.scratch().alloc(TypeId, tps.len);
    if (explicit_targs.len > 0) {
        const min = c.sigMinTargs(tps);
        if (explicit_targs.len < min or explicit_targs.len > tps.len) {
            if (min == tps.len) {
                try c.diagFmt(2558, c.nodeSpan(node), "Expected {d} type arguments, but got {d}.", .{ tps.len, explicit_targs.len });
            } else {
                try c.diagFmt(2558, c.nodeSpan(node), "Expected {d}-{d} type arguments, but got {d}.", .{ min, tps.len, explicit_targs.len });
            }
        }
        for (tps, 0..) |tp, i| {
            if (i < explicit_targs.len) {
                args_buf[i] = explicit_targs[i];
            } else if (c.typeParamHasDefault(tp)) {
                // A missing trailing arg takes its default, instantiated
                // under the args resolved so far (so `B = A` sees the
                // supplied `A`, `C = B` sees the defaulted `B`).
                const def = try c.typeParamDefault(tp);
                const pmap = try c.scratch().alloc(TpMap, i);
                for (tps[0..i], 0..) |ptp, j| pmap[j] = .{ .sym = ptp, .ty = args_buf[j] };
                args_buf[i] = try c.instantiate(def, pmap);
            } else {
                args_buf[i] = types.any_type;
            }
        }
    } else {
        // The receiver type feeds inference of a `this`-parameter type
        // param (recomputed only when the signature declares one, since
        // `checkExprCached` on the member object is otherwise wasted work).
        var recv_ty: TypeId = types.no_type;
        if (c.ts.fnThisType(sig) != 0) {
            const callee = c.callShape(node).callee;
            switch (c.nodeTag(callee)) {
                .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {
                    recv_ty = try c.checkExprCached(c.tree.nodeData(callee).lhs, types.no_type);
                },
                else => {},
            }
        }
        try inferTypeArgs(c, sig, tps, arg_nodes, args_buf, ret_ctx, recv_ty);
    }
    var map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
    return c.instantiate(sig, map);
}

/// tsc's `getUnionSignatures`: calling a UNION does not resolve against the
/// constituents' signatures as if they were an overload set — the lists are
/// COMBINED into one signature (`combineSignaturesOfUnionMembers`), whose
/// parameters are the position-wise INTERSECTION of the constituents' and
/// whose return type is their UNION.
///
/// That intersection is what makes a callback argument work. `(A[] | B[])
/// .map(x => …)` hands the arrow `((x: A, …) => U) & ((x: B, …) => U)`, an
/// intersection of two call signatures, which `intersectedCallSignature`
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
    for ([2]TypeId{ left, right0 }) |sig| {
        for (0..s.fnParamCount(sig)) |i| {
            if (s.fnParam(sig, @intCast(i)).rest()) return null;
        }
    }
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
    const lc = s.fnParamCount(left);
    const rc = s.fnParamCount(right);
    const lreq = try c.requiredParams(left);
    const rreq = try c.requiredParams(right);
    const n = @max(lc, rc);
    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    for (0..n) |i| {
        const idx: u32 = @intCast(i);
        // `tryGetTypeAtPosition` answers `unknown` for a position the shorter
        // signature does not declare, and `unknown` is the intersection's
        // identity — the longer signature's type survives.
        const lp: TypeId = if (idx < lc) s.fnParam(left, idx).ty else types.unknown_type;
        const rp: TypeId = if (idx < rc) s.fnParam(right, idx).ty else types.unknown_type;
        const name: Atom = if (idx < lc) s.fnParam(left, idx).name else s.fnParam(right, idx).name;
        const optional = idx >= lreq and idx >= rreq;
        const ty = try s.makeIntersection(c.scratch(), &.{ lp, rp });
        try params.append(c.scratch(), .{
            .name = name,
            .ty = ty,
            .flags = if (optional) types.param_flag_optional else 0,
        });
    }
    const ret = try s.makeUnion(c.scratch(), &.{ s.fnReturn(left), s.fnReturn(right) });
    return try s.makeFunction(params.items, ret, ltp, 0);
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
    var ai: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        if (c.nodeTag(an) == .spread_element) return true; // don't reject on spreads
        const pt = try c.paramTypeAt(sig, ai) orelse {
            c.rollbackArgDiags(saved_diags, spec_file, arg_nodes);
            return false;
        };
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
        const ctx_typed = switch (tag) {
            .arrow_fn, .function_expr, .array_literal, .object_literal, .template_expr, .cond_expr, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => true,
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
        const fn_arg = tag == .arrow_fn or tag == .function_expr;
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
        if (!try c.isAssignable(at, pt)) {
            c.rollbackArgDiags(saved_diags, spec_file, arg_nodes);
            return false;
        }
        // Freshness is not part of `isAssignable` here (see
        // `freshLiteralRejects`), so an excess property on a fresh object
        // literal has to reject the candidate explicitly — otherwise the
        // first overload "matches", wins, and is then diagnosed by
        // `checkCallArguments`, which is exactly the error tsc avoids by
        // moving on to the next overload.
        if (try c.freshLiteralRejects(an, at, pt)) {
            c.rollbackArgDiags(saved_diags, spec_file, arg_nodes);
            return false;
        }
    }
    return true;
}

fn checkCallArguments(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool) Error!void {
    return checkCallArgumentsAnchored(c, node, sig, arg_nodes, report, null);
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
    const required = try c.requiredParams(sig);
    const total = try c.paramTotal(sig);
    const has_spread = hasSpreadArg(c, arg_nodes);
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
    if (report and !has_spread and arity_known) {
        if (nargs < required or nargs > total) {
            try reportArityError(c, node, arg_nodes, nargs, required, total, total == std.math.maxInt(u32));
        }
    }
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
    // Skipped when the call has a spread argument: the packed tuple would be
    // a guess, and guessing here can only invent a rejection.
    const rest_union: ?TypeId = if (has_spread) null else try c.sigNonArrayRest(sig);
    const whole_from: u32 = if (rest_union == null)
        std.math.maxInt(u32)
    else
        c.ts.fnParamCount(sig) - 1;
    var packed_elems: std.ArrayList(types.TupleElem) = .empty;
    defer packed_elems.deinit(c.scratch());
    var packed_first: Node = null_node;
    var reported_arg = false;
    var ai: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        if (c.nodeTag(an) == .spread_element) {
            _ = try c.checkExprCached(an, types.no_type);
            continue;
        }
        const pt = try c.paramTypeAt(sig, ai) orelse {
            _ = try c.checkExprCached(an, types.no_type);
            continue;
        };
        const at = try c.checkExprCached(an, pt);
        if (ai >= whole_from) {
            if (packed_first == null_node) packed_first = an;
            try packed_elems.append(c.scratch(), .{ .ty = at });
            continue;
        }
        if (report and !try c.isAssignable(at, pt)) {
            if (reported_arg) continue;
            const before = c.diags.items.len;
            if (!try c.elaborateCallbackError(an, at, pt) and
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
        } else if (report and !reported_arg) {
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
    if (report and !reported_arg and rest_union != null) {
        const rest_ty = rest_union.?;
        const packed_ty = try c.ts.makeTuple(packed_elems.items);
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
    arg_nodes: []const Node,
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
        extraArgsSpan(c, arg_nodes, max) orelse calleeErrorSpan(c, node)
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

fn hasSpreadArg(c: *Checker, arg_nodes: []const Node) bool {
    for (arg_nodes) |an| {
        if (an != null_node and c.nodeTag(an) == .spread_element) return true;
    }
    return false;
}

/// `args[max].pos` through the last argument's end — tsc's span for a call
/// with too many arguments. Null when there is no argument at that position
/// (nothing to blame, so the caller falls back to the callee).
fn extraArgsSpan(c: *Checker, arg_nodes: []const Node, from: u32) ?Span {
    var i: u32 = 0;
    var start: ?u32 = null;
    var end: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
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
