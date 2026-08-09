//! Call checking: overloads, generic inference, argument matching.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const modules = @import("../link/modules.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const Bind = binder.Bind;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const Check = checker_zig.Check;
const check = checker_zig.check;

const ModuleRef = @import("typenode.zig").ModuleRef;
const Resolved = @import("names.zig").Resolved;
const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const ambientNamespaceType = @import("signatures.zig").ambientNamespaceType;
const atom = Checker.atom;
const checkConstArrayLiteral = @import("expr.zig").checkConstArrayLiteral;
const checkExprCached = @import("expr.zig").checkExprCached;
const checkJsxElement = @import("expr.zig").checkJsxElement;
const containsTypeParamInner = @import("enums.zig").containsTypeParamInner;
const ctxWantsTemplate = @import("generics.zig").ctxWantsTemplate;
const enterSymFile = Checker.enterSymFile;
const freshLiteralRejects = @import("assign.zig").freshLiteralRejects;
const inferFromExtends = @import("generics.zig").inferFromExtends;
const init = Checker.init;
const instantiate = @import("enums.zig").instantiate;
const isAssignable = @import("assign.zig").isAssignable;
const isUnitLikeKind = @import("assign.zig").isUnitLikeKind;
const keyofType = @import("typenode.zig").keyofType;
const memberChainInner = @import("expr.zig").memberChainInner;
const memberList = @import("typenode.zig").memberList;
const numberIndexType = @import("typenode.zig").numberIndexType;
const propOfType = @import("props.zig").propOfType;
const resolveStructural = @import("instantiate.zig").resolveStructural;
const rollbackDiags = Checker.rollbackDiags;
const run = Checker.run;
const scratch = Checker.scratch;
const seal = Checker.seal;
const symScope = Checker.symScope;
const transitiveBaseConstraint = @import("assign.zig").transitiveBaseConstraint;
const tupleElementUnion = @import("props.zig").tupleElementUnion;
const typeParamConstraint = @import("props.zig").typeParamConstraint;

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
pub fn importCallType(c: *Checker, arg_nodes: []const Node) Error!TypeId {
    if (arg_nodes.len == 0) return types.any_type;
    const spec_node = arg_nodes[0];
    if (c.nodeTag(spec_node) != .string_literal) return types.any_type;
    const spec = try c.memberAtom(c.tree.nodeMainToken(spec_node));
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
            }
        }
    }
    return c.makePromise(inner);
}

pub fn checkCallExpr(c: *Checker, node: Node, is_new: bool, ctx: TypeId) Error!TypeId {
    var chained = false;
    const result = try c.checkCallExprInner(node, is_new, &chained, ctx);
    if (chained) return c.makeUnion2(result, types.undefined_type);
    return result;
}

/// Call/new as an optional-chain link (see `memberChainInner`). Returns the
/// return type WITHOUT the chain's short-circuit `undefined`; sets
/// `chained.*` when this `?.()` — or an earlier link in the callee spine —
/// short-circuits on a nullish callee.
pub fn checkCallExprInner(c: *Checker, node: Node, is_new: bool, chained: *bool, ctx: TypeId) Error!TypeId {
    const shape = c.callShape(node);
    // `import("m")` is not an ordinary call — `import` has no type of its
    // own. tsc's `getTypeOfImportCall`: the module's namespace object,
    // wrapped in `Promise`.
    if (!is_new and c.nodeTag(shape.callee) == .import_expr) return c.importCallType(shape.arg_nodes);
    var callee_t = if (c.isOptionalChain(shape.callee))
        try c.chainObjType(shape.callee, chained)
    else
        try c.checkExprCached(shape.callee, types.no_type);
    if (shape.optional) {
        if (c.containsNullish(callee_t)) chained.* = true;
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
    if (rk == .type_param) {
        const bc = try c.transitiveBaseConstraint(r);
        if (bc != r) {
            r = try c.resolveStructural(bc);
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
                .object => for (0..c.ts.objectCallSigCount(rm)) |i| {
                    try isect_sigs.append(c.scratch(), c.ts.objectCallSig(rm, @intCast(i)));
                },
                else => {},
            }
        }
    }
    if (rk == .any or rk == .err or isect_any) {
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return if (rk == .err) types.error_type else types.any_type;
    }
    // Calling a value of the global `Function` type: tsc treats `Function`
    // as callable, accepting any arguments and yielding `any` (the interface
    // body carries no call signature, so a structural resolve would report
    // TS2349). Mirrors the assignable-to-`Function` special-case in the
    // relation. Only for calls — `new (x: Function)` stays unmodeled.
    if (!is_new and c.ts.kind(callee_t) == .ref and
        c.globalSymNamed(c.ts.refSymbol(callee_t), "Function"))
    {
        for (shape.arg_nodes) |an| {
            if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
        }
        return types.any_type;
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
                const fixed = try c.fixTypeArgs(cls, targs.items, c.tree.nodeMainToken(node)) orelse return types.error_type;
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
                    try c.inferTypeArgs(self_sig, tp_syms, shape.arg_nodes, inst_args, ctx, types.no_type);
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
                return instance_ret;
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
        } else {
            try c.diagFmt(2351, c.nodeSpan(shape.callee), "This expression is not constructable.", .{});
            for (shape.arg_nodes) |an| {
                if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
            }
            return types.error_type;
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
                    return types.error_type;
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
                return types.never_type;
            },
            // Callable object with call signatures.
            .object => {
                if (c.ts.objectCallSigCount(r) == 0) {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.error_type;
                }
                for (0..c.ts.objectCallSigCount(r)) |i| {
                    try sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
                }
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
                for (try c.memberList(r)) |m| {
                    const rm = try c.resolveStructural(m);
                    switch (c.ts.kind(rm)) {
                        .any, .err => saw_any = true,
                        .never => {},
                        .function => try sigs.append(c.scratch(), rm),
                        .overloads => try c.appendOverloadCandidates(&sigs, rm),
                        .object => {
                            const n = c.ts.objectCallSigCount(rm);
                            if (n == 0) {
                                all_callable = false;
                            } else {
                                for (0..n) |i| try sigs.append(c.scratch(), c.ts.objectCallSig(rm, @intCast(i)));
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
                                        const n = c.ts.objectCallSigCount(ri);
                                        if (n != 0) {
                                            for (0..n) |i| try sigs.append(c.scratch(), c.ts.objectCallSig(ri, @intCast(i)));
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
                }
                if (!all_callable) {
                    try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.error_type;
                }
                if (saw_any or sigs.items.len == 0) {
                    for (shape.arg_nodes) |an| {
                        if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                    }
                    return types.any_type;
                }
            },
            else => {
                try c.diagFmt(2349, c.nodeSpan(shape.callee), "This expression is not callable.", .{});
                for (shape.arg_nodes) |an| {
                    if (an != null_node) _ = try c.checkExprCached(an, types.no_type);
                }
                return types.error_type;
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
    const result = try c.resolveSignatureCall(node, sigs.items, sig_targs, shape.arg_nodes, instance_ret, call_ctx);
    return result;
}

/// Receiver check for a signature with an explicit `this` parameter
/// (`f(this: T, …)`): the call's receiver must be assignable to `T`
/// (TS2684). A member call `obj.m()` uses `obj`'s type; a bare call uses
/// `void` (no receiver).
pub fn checkThisArg(c: *Checker, node: Node, sig: TypeId) Error!void {
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

pub fn countArgs(arg_nodes: []const Node) usize {
    var n: usize = 0;
    for (arg_nodes) |a| {
        if (a != null_node) n += 1;
    }
    return n;
}

/// Pick a signature (first match for overloads, like tsc), infer type
/// arguments, check arguments, and return the (instantiated) return
/// type; `instance_ret` overrides the return for `new`.
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
    const nargs = countArgs(arg_nodes);
    if (sigs.len == 1) {
        const inst = try c.instantiateSigForCall(sigs[0], explicit_targs, arg_nodes, node, ret_ctx);
        if (instance_ret == types.no_type) try c.checkThisArg(node, inst);
        try c.checkCallArguments(node, inst, arg_nodes, true);
        return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
    }
    // Overloads: first signature whose arity fits and whose args check.
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
        if (nargs < try c.requiredParams(inst) or nargs > try c.paramTotal(inst)) {
            c.rollbackArgDiags(saved_infer, infer_file, arg_nodes);
            c.inst_count = saved_inst_count;
            c.newBudgetWindow();
            c.inst_limit_tripped = saved_inst_trip;
            continue;
        }
        if (try c.argumentsMatch(inst, arg_nodes)) {
            try c.checkCallArguments(node, inst, arg_nodes, true);
            return if (instance_ret != types.no_type) instance_ret else c.ts.fnReturn(inst);
        }
        c.rollbackArgDiags(saved_infer, infer_file, arg_nodes);
        c.inst_count = saved_inst_count;
        c.newBudgetWindow();
        c.inst_limit_tripped = saved_inst_trip;
    }
    // No candidate matched. tsc does not report at the callee: it re-checks
    // the LAST candidate with error reporting on and files the TS2769 where
    // that check would have reported — the offending argument, or, when the
    // argument is an object literal, the offending PROPERTY of it
    // (`fetch(url, { body: aSharedArrayBuffer })` is TS2769 on `body`).
    // So run that check, take the span of the first diagnostic it filed
    // inside this call, withdraw them all, and anchor the TS2769 there.
    const call_span = c.nodeSpan(node);
    const saved = c.diags.items.len;
    const inst_last = try c.instantiateSigForCall(sigs[sigs.len - 1], explicit_targs, arg_nodes, node, ret_ctx);
    try c.checkCallArguments(node, inst_last, arg_nodes, true);
    var anchor = c.nodeSpan(c.callShape(node).callee);
    for (c.diags.items[saved..]) |d| {
        if (d.file != c.cur_file) continue;
        if (d.span.start < call_span.start or d.span.start >= call_span.end) continue;
        anchor = d.span;
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
        try c.inferTypeArgs(sig, tps, arg_nodes, args_buf, ret_ctx, recv_ty);
    }
    var map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
    return c.instantiate(sig, map);
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
        try c.diagFmt(2635, c.typeArgsSpan(targ_nodes, node), "Type '{s}' has no signatures for which the type argument list is applicable.", .{try c.typeToString(base)});
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
pub fn typeArgsSpan(c: *Checker, targ_nodes: []const Node, node: Node) Span {
    if (targ_nodes.len == 0) return c.nodeSpan(node);
    const first = c.nodeSpan(targ_nodes[0]);
    const last = c.nodeSpan(targ_nodes[targ_nodes.len - 1]);
    if (first.end == 0 or last.end == 0) return c.nodeSpan(node);
    return .{ .start = first.start, .end = last.end };
}

/// tsc's `InferencePriority.ReturnType`: infer still-unbound type params by
/// unifying the signature's return type against the structurally-resolved
/// contextual return type `ret_ctx`, writing into `target` only where it is
/// currently `no_type`. Used both to *seed* callback contextual typing
/// (before argument inference) and to *fill* leftover params (after it).
/// No-op when nothing is unbound or the context is `any`/`unknown`/error.
pub fn fillFromReturnContext(c: *Checker, sig: TypeId, tp_syms: []const u32, ret_ctx: TypeId, target: []TypeId, bare_callback_only: bool, seed_only: bool) Error!void {
    if (ret_ctx == types.no_type or c.ts.kind(sig) != .function) return;
    var any_empty = false;
    for (target) |t| {
        if (t == types.no_type) any_empty = true;
    }
    if (!any_empty) return;
    const rctx = try c.resolveStructural(ret_ctx);
    const rk = c.ts.kind(rctx);
    if (rk == .any or rk == .unknown or rk == .err) return;
    const ret = c.ts.fnReturn(sig);
    const rc = try c.scratch().alloc(TypeId, tp_syms.len);
    for (rc) |*x| x.* = types.no_type;
    c.ret_ctx_prio += 1;
    defer c.ret_ctx_prio -= 1;
    try c.unify(ret, rctx, tp_syms, rc, 0);
    for (target, 0..) |*t, i| {
        if (t.* != types.no_type or rc[i] == types.no_type) continue;
        // Seed path (`bare_callback_only`): only fill a param that is the
        // *bare* return type of some callback parameter — `map<U>(cb: (…) =>
        // U)`, where seeding `U` cleanly propagates a literal-keeping
        // contextual return into the callback body. A param buried in a
        // union callback return (`flatMap<U>(cb: (…) => U | readonly U[])`)
        // is left to the ordinary post-argument fill (Phase 3), so seeding
        // never perturbs the callback's contextual type into a spurious
        // self-mismatch on already-hard flatMap inferences.
        if (bare_callback_only and !c.paramIsBareCallbackReturn(sig, tp_syms[i])) continue;
        // The final resolution loop only clamps a candidate to its
        // constraint when that constraint is *retrievable and concrete*;
        // otherwise it trusts the candidate outright. A low-priority
        // contextual guess must not exploit that trust to override a param's
        // default. Skip when the constraint is a bare outer type param, or
        // is unretrievable while the param has a default — the higher-order
        // `<AD extends TBase = TBase>` (redux `useDispatch`) shape, whose
        // minted param keeps only the substituted default.
        // `featureCollection`'s `G` keeps a concrete `Geometry` constraint,
        // so it is still filled.
        const con = try c.typeParamConstraint(tp_syms[i]);
        const bare_outer_con = con != types.no_type and
            c.ts.kind(con) == .type_param and
            tpIndex(tp_syms, c.ts.typeParamSymbol(con)) == null;
        // …but only when this fill IS the answer. A SEED never is: it is
        // superseded by argument evidence and exists only to give the
        // arguments a contextual type. Blocking it there cost the shape
        // `Object.fromEntries<T = any>(e: Iterable<readonly [PropertyKey,
        // T]>)`: with no seed the callback's array literal had no
        // contextual type, its `true` widened to `boolean`, and the result
        // no longer satisfied `{ [k: string]: true }` — while the same
        // declaration written without the `= any` default worked.
        //
        // Restricted to a param that IS the whole return type. There the
        // "inference" is content-free — `unify(AD, ctx)` just echoes the
        // expected type back, which is exactly the override the guard is
        // about. A param BURIED in the return (`(): Promise<T>` against a
        // contextual `Promise<Object>` — vitest's `importOriginal:
        // <T extends M = M>() => Promise<T>`, whose minted param has the
        // same unretrievable-constraint-plus-default shape) matched
        // structurally, so it is real evidence and outranks the default,
        // as it does in tsc (a default is used only when NO candidate was
        // found).
        const ret_is_bare_param = blk: {
            const r = try c.resolveStructural(c.ts.fnReturn(sig));
            break :blk c.ts.kind(r) == .type_param and c.ts.typeParamSymbol(r) == tp_syms[i];
        };
        const undefendable_default = !seed_only and ret_is_bare_param and
            con == types.no_type and c.typeParamHasDefault(tp_syms[i]);
        if (bare_outer_con or undefendable_default) continue;
        // A candidate that IS an outer call's in-flight inference variable
        // carries no information (see `isOuterInferVar`).
        if (c.isOuterInferVar(rc[i], tp_syms)) continue;
        t.* = rc[i];
    }
}

/// Is `t` a bare type parameter that some ENCLOSING `inferTypeArgs` is
/// still inferring? tsc instantiates a nested call's contextual type with
/// `InferenceFlags.NoDefault`, mapping every unresolved outer inference
/// variable to `silentNeverType` — which infers nothing. Without the
/// equivalent guard, `pf(1, 2)` inside `pair(pf(1, 2), pf(3, 4))` adopts
/// `pair`'s own `Q` as its `P`, the outer call then infers `Q` from `Q`,
/// and the printed return type literally contains the type parameter
/// (`[Q, Q]`). A generic function's own type params, seen while checking
/// its body, are not on the stack, so `const b: Box<T> = makeBox()` still
/// infers `U = T` from the enclosing signature's fixed `T`.
pub fn isOuterInferVar(c: *Checker, t: TypeId, tp_syms: []const u32) bool {
    if (c.ts.kind(t) != .type_param) return false;
    const sym = c.ts.typeParamSymbol(t);
    if (tpIndex(tp_syms, sym) != null) return false;
    for (c.infer_active.items) |s| {
        if (s == sym) return true;
    }
    return false;
}

/// Does `t` mention a type parameter that some call currently resolving its
/// type arguments is still inferring? Any type built out of one is evidence
/// about itself, which is never evidence at all (see the empty-array-literal
/// arm of `checkArrayLiteral`). A bare parameter and the parameter under one
/// array/reference layer are what the callers see, so the walk is shallow —
/// deeper occurrences simply read as "no free variable", i.e. the old
/// behavior.
pub fn mentionsActiveInferVar(c: *Checker, t0: TypeId) Error!bool {
    if (c.infer_active.items.len == 0) return false;
    return mentionsActiveInferVarAt(c, t0, 0);
}

fn mentionsActiveInferVarAt(c: *Checker, t0: TypeId, depth: u32) Error!bool {
    if (depth > 4) return false;
    // Deliberately NOT `resolveStructural`: this runs in the middle of a
    // call's argument check, and forcing a reference's expansion here is
    // arbitrary work — and, on a self-referential alias, unbounded.
    switch (c.ts.kind(t0)) {
        .type_param => {
            const sym = c.ts.typeParamSymbol(t0);
            for (c.infer_active.items) |s| {
                if (s == sym) return true;
            }
            return false;
        },
        .array => return mentionsActiveInferVarAt(c, c.ts.arrayElem(t0), depth + 1),
        .union_type, .intersection => {
            for (try c.memberList(t0)) |m| {
                if (try mentionsActiveInferVarAt(c, m, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Substitute the type params of this call that already have a value —
/// `candidates` (arguments seen so far) falling back to `seed` (the
/// contextual-return pass) — leaving the rest free. tsc's
/// `instantiateContextualType` / `nonFixingMapper`.
pub fn partialParamCtx(c: *Checker, pt0: TypeId, partial: []const TpMap) Error!TypeId {
    const full = try c.instantiate(pt0, partial);
    if (c.ts.kind(full) != .any) return full;
    const r = try c.resolveStructural(pt0);
    // A parameter that IS a still-un-inferred type variable (`e: E`)
    // contextually types its argument by the variable's CONSTRAINT, not by the
    // `any` placeholder standing in for it — tsc's
    // `getApparentTypeOfContextualType`, which takes the base constraint of a
    // type variable before looking for a call signature. Without it the
    // callback form of every builder API — kysely's
    // `where<E extends ExpressionOrFactory<DB, TB, SqlBool>>(e: E)` — gave its
    // arrow no contextual signature and reported TS7006 on every parameter.
    // The placeholder still wins when the constraint says no more than it does.
    if (c.ts.kind(r) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
        if (con == types.no_type) return full;
        const ci = try c.instantiate(con, partial);
        return if (c.ts.kind(ci) == .any) full else ci;
    }
    if (c.ts.kind(r) != .union_type) return full;
    const members = try c.memberList(r);
    var kept: std.ArrayList(TypeId) = .empty;
    defer kept.deinit(c.scratch());
    var dropped = false;
    for (members) |m| {
        const mi = try c.instantiate(m, partial);
        if (c.ts.kind(m) == .type_param and c.ts.kind(mi) == .any) {
            // Same rule as the bare-type-variable case above, one level down:
            // an OPTIONAL parameter `impl?: T` is `T | undefined` here, so the
            // variable arrives as a union member. Dropping it outright left
            // `undefined` as the whole contextual type — no call signature, so
            // a callback argument's parameters got none either and every one
            // was a TS7006 (vitest's `fn<T extends Procedure = Procedure>(
            // implementation?: T)`, which immich's test doubles are built on).
            // Substitute the constraint when it says more than the placeholder.
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(m));
            if (con != types.no_type) {
                const ci = try c.instantiate(con, partial);
                if (c.ts.kind(ci) != .any) {
                    try kept.append(c.scratch(), ci);
                    dropped = true;
                    continue;
                }
            }
            dropped = true;
            continue;
        }
        try kept.append(c.scratch(), mi);
    }
    if (!dropped or kept.items.len == 0) return full;
    return c.ts.makeUnion(c.scratch(), kept.items);
}

pub fn instantiateKnownParams(
    c: *Checker,
    t: TypeId,
    tp_syms: []const u32,
    candidates: []const TypeId,
    seed: []const TypeId,
) Error!TypeId {
    var map_list: std.ArrayList(TpMap) = .empty;
    defer map_list.deinit(c.scratch());
    for (tp_syms, 0..) |sym, i| {
        const v = if (candidates[i] != types.no_type) candidates[i] else seed[i];
        if (v == types.no_type) continue;
        try map_list.append(c.scratch(), .{ .sym = sym, .ty = v });
    }
    if (map_list.items.len == 0) return t;
    return c.instantiate(t, map_list.items);
}

/// May `tp_sym` be fixed from the call's contextual return type BEFORE the
/// arguments are contextually typed (tsc's `InferencePriority.ReturnType`
/// seed)? Two shapes qualify:
///
///   • the return type of some function-typed parameter, either bare or as
///     one constituent of a union — the `map<U>(cb: (…) => U)` shape and
///     the `promiseTry<T>(fn: (…) => PromiseLike<T> | T)` shape, where
///     seeding cleanly makes the callback body keep literal discriminants
///     and tuple/array contexts. A param that only appears WRAPPED
///     (`flatMap`'s `readonly U[]` constituent, `Promise<U>`) does not
///     qualify on that constituent's account;
///   • the signature's own bare return type — the identity-wrapper shape
///     (`wrap<F extends (…) => void>(f: F): F`, `withBatchedUpdates`). The
///     contextual return type determines `F` outright, and seeding it is
///     what gives the arrow ARGUMENT a contextual signature at all: without
///     it `F` is `any` while the argument is checked, so every parameter of
///     the arrow is an implicit `any`. `map`/`flatMap` return `U[]`, not a
///     bare `U`, so this second rule does not reach them.
///
/// The seed only builds contextual types; argument evidence still owns the
/// committed inference.
pub fn paramIsBareCallbackReturn(c: *Checker, sig: TypeId, tp_sym: u32) bool {
    const sr = c.ts.fnReturn(sig);
    if (c.ts.kind(sr) == .type_param and c.ts.typeParamSymbol(sr) == tp_sym) return true;
    const n = c.ts.fnParamCount(sig);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const pt = c.ts.fnParam(sig, i).ty;
        if (c.ts.kind(pt) != .function) continue;
        const r = c.ts.fnReturn(pt);
        if (c.isBareOrUnionMember(r, tp_sym)) return true;
        // …or a bare PARAMETER of the callback, or of a callback the
        // callback itself takes: `new Promise<T>(executor: (resolve:
        // (value: T | PromiseLike<T>) => void, …) => void)`. Without the
        // seed `resolve` is handed the `any` placeholder, so `resolve()` on
        // a `Promise<void>` reports TS2554 (a `void` parameter may be
        // omitted, but only once the parameter IS `void`) and every
        // `resolve(x)` goes unchecked.
        //
        // This is a CONTRAVARIANT occurrence, which is why it is safe where
        // the covariant `flatMap<U>(cb: (…) => U | readonly U[])` shape is
        // not: the seed becomes the callback parameter's declared type
        // rather than the type its body's `return` is checked against, so it
        // cannot make the callback's own inference disagree with itself.
        if (callbackParamMentions(c, pt, tp_sym, 0)) return true;
    }
    return false;
}

/// Does a callback parameter's own PARAMETER list mention `tp_sym`, bare or
/// as a union constituent, at this level or one callback deeper?
fn callbackParamMentions(c: *Checker, cb: TypeId, tp_sym: u32, depth: u32) bool {
    if (depth > 2 or c.ts.kind(cb) != .function) return false;
    const n = c.ts.fnParamCount(cb);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const pt = c.ts.fnParam(cb, i).ty;
        if (c.isBareOrUnionMember(pt, tp_sym)) return true;
        if (callbackParamMentions(c, pt, tp_sym, depth + 1)) return true;
    }
    return false;
}

/// Is `t` the type param `tp_sym` itself, or a UNION with it as one of its
/// constituents? A param that only appears wrapped inside a constituent
/// (`readonly U[]`, `Promise<U>`) is not matched: the seed exists to hand a
/// callback body a contextual type, and only a bare occurrence gives the
/// body's `return` one directly.
pub fn isBareOrUnionMember(c: *Checker, t: TypeId, tp_sym: u32) bool {
    if (c.ts.kind(t) == .type_param) return c.ts.typeParamSymbol(t) == tp_sym;
    if (c.ts.kind(t) != .union_type) return false;
    for (c.ts.members(t)) |m| {
        if (c.ts.kind(m) == .type_param and c.ts.typeParamSymbol(m) == tp_sym) return true;
    }
    return false;
}

/// Basic unification: gather candidates for each type parameter from
/// argument types matched against parameter positions; default to the
/// constraint or `unknown`.
pub fn inferTypeArgs(
    c: *Checker,
    sig: TypeId,
    tp_syms: []const u32,
    arg_nodes: []const Node,
    out: []TypeId,
    ret_ctx: TypeId,
    recv_ty: TypeId,
) Error!void {
    const candidates = try c.scratch().alloc(TypeId, tp_syms.len);
    for (candidates) |*x| x.* = types.no_type;

    // The contravariant half of the candidate set (tsc's
    // `InferenceInfo.contraCandidates`), registered against `candidates` so
    // `unify` can find it and every other accumulator it is handed cannot.
    // A nested call's inference gets its own, and starts at variance zero.
    const contra = try c.scratch().alloc(TypeId, tp_syms.len);
    for (contra) |*x| x.* = types.no_type;
    // tsc's `InferenceInfo.topLevel`, registered the same way.
    const top_flags = try c.scratch().alloc(bool, tp_syms.len);
    for (top_flags) |*x| x.* = true;
    // tsc's `InferencePriority.HomomorphicMappedType`, registered the same way.
    const rev_flags = try c.scratch().alloc(bool, tp_syms.len);
    for (rev_flags) |*x| x.* = false;
    const saved_contra_cands = c.contra_cands;
    const saved_contra_owner = c.contra_owner;
    const saved_contra_pos = c.contra_pos;
    const saved_top_flags = c.top_flags;
    const saved_rev_flags = c.rev_flags;
    const saved_rev_prio = c.rev_prio;
    const saved_nontop_depth = c.nontop_depth;
    c.contra_cands = contra;
    c.contra_owner = candidates.ptr;
    c.contra_pos = 0;
    c.top_flags = top_flags;
    c.rev_flags = rev_flags;
    c.rev_prio = 0;
    c.nontop_depth = 0;
    defer {
        c.contra_cands = saved_contra_cands;
        c.contra_owner = saved_contra_owner;
        c.contra_pos = saved_contra_pos;
        c.top_flags = saved_top_flags;
        c.rev_flags = saved_rev_flags;
        c.rev_prio = saved_rev_prio;
        c.nontop_depth = saved_nontop_depth;
    }

    // This call's inference variables are in flight for the whole of it —
    // see `infer_active`. A NESTED call's contextual-return inference must
    // not adopt one of them as a candidate.
    const active_base = c.infer_active.items.len;
    try c.infer_active.appendSlice(c.cm(), tp_syms);
    defer c.infer_active.shrinkRetainingCapacity(active_base);

    // Infer type parameters that appear in an explicit `this` parameter
    // (`flat<A, D extends number = 1>(this: A, depth?: D)`) from the call's
    // receiver — tsc treats the receiver as the `this` argument. Without it
    // `A` stays unbound and `arr.flat()`'s `FlatArray<A, D>[]` return
    // collapses to `unknown[]` (spurious TS2339 on every element access).
    // Gated on a signature that actually declares a `this` type, so the
    // common array/iterator methods (whose element type already flows from
    // the receiver's `Array<T>` interface, no `this` param) are untouched.
    const this_ty = c.ts.fnThisType(sig);
    if (this_ty != 0 and recv_ty != types.no_type) {
        try c.unify(this_ty, recv_ty, tp_syms, candidates, 0);
    }

    // Phase 0: contextual-return inference. tsc runs its
    // `InferencePriority.ReturnType` pass BEFORE checking any argument, and
    // the result (`context.returnMapper`) is what every argument's
    // contextual type is instantiated with (`instantiateContextualType`).
    // Kept out of `candidates` — argument evidence still owns the committed
    // inference (Phase 3 fills only what no argument constrained); this
    // exists so a nested generic call is contextually typed by the
    // *resolved* parameter type instead of a bare, still-free inference
    // variable of this very call.
    const ret_seed = try c.scratch().alloc(TypeId, tp_syms.len);
    for (ret_seed) |*x| x.* = types.no_type;
    if (ret_ctx != types.no_type) {
        try c.fillFromReturnContext(sig, tp_syms, ret_ctx, ret_seed, false, true);
    }

    // Empty-array-literal candidates, demoted to a fallback (see below).
    const empty_seed = try c.scratch().alloc(TypeId, tp_syms.len);
    for (empty_seed) |*x| x.* = types.no_type;
    const pre_seed = try c.scratch().alloc(TypeId, tp_syms.len);
    // Phase 1: non-function arguments.
    var ai: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        const tag = c.nodeTag(an);
        if (tag == .arrow_fn or tag == .function_expr) continue;
        const pt = try c.paramTypeAt(sig, ai) orelse continue;
        // Contextually type an array literal by the parameter so a
        // tuple-constrained target (`T extends readonly unknown[] | []`)
        // infers a tuple, not a widened array — the crux of picking the
        // tuple `Promise.all` overload. Other argument shapes keep the
        // context-free inference to avoid perturbing literal widening.
        // A nested generic *call* argument is also contextually typed by
        // `pt` (the still-uninstantiated parameter, whose free type params
        // act as the inference variables): `new Map(rows.map(r => [r.id,
        // r.n]))` threads `Iterable<readonly [K,V]>` into `.map`'s callback
        // so the array literal forms a tuple, and the outer `K`/`V` then
        // infer `string`/`number` from `[string, number][]` instead of
        // collapsing to `unknown`.
        var arg_ctx = switch (tag) {
            .array_literal, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => pt,
            // A template expression is contextually typed by the parameter
            // so `ctxWantsTemplate` can see a string-like-constrained type
            // param and keep the template-literal type (tsc keeps
            // `` `x.${number}` `` for `kS<N extends string>(`x.${i}`)`;
            // context-free checking widens it to `string` before
            // unification ever sees it).
            .template_expr => pt,
            // Contextually type an object-literal argument by the parameter
            // so a property whose parameter type is a literal-constrained
            // inference target (`name: TFieldName`, `TFieldName extends
            // FieldPath<T>` — a string-literal union) keeps its literal
            // instead of widening to `string`. Without it, `useWatch({
            // control, name: 'selectedActions' })` widens `'selectedActions'`
            // → `string`, which fails the `FieldPath` constraint, so
            // `TFieldName` falls back to the whole path union and the return
            // `FieldPathValue<T, TFieldName>` collapses. Mirrors tsc's
            // `getContextualTypeForArgument`. Gated to params that actually
            // have a literal-keeping type-variable property so unrelated
            // object-literal arguments (callback bags like `openDB({ upgrade
            // })`) keep their context-free check.
            .object_literal => if (try c.paramWantsLiteralCtx(pt)) pt else types.no_type,
            else => types.no_type,
        };
        // Fresh object literal into a bare type-param parameter (`truncate<T
        // extends AllGeoJSON>(v: T)` called with `{ type: 'Feature', … }`):
        // contextually type it by the type param's instantiated constraint,
        // so a discriminant property whose constraint type is a literal
        // (`type: 'Feature'`) keeps its literal instead of widening. Without
        // it the widened `{ type: string }` fails `T extends AllGeoJSON`, so
        // `T` is clamped to the whole constraint union → the argument's real
        // shape is lost. Mirrors tsc's `getContextualTypeForArgument`
        // falling back to the instantiated constraint. A non-fresh variable
        // argument is not an object-literal node, so it never reaches here —
        // its already-widened type still fails the constraint (unchanged).
        //
        // NOT for a `const` type parameter: substituting the constraint is
        // exactly what would hide the const-ness from the literal, and the
        // reason for the substitution — keeping a literal that would
        // otherwise widen — is what `const` already guarantees. tsc's own
        // contextual type for an argument is the parameter, never its
        // constraint (`instantiateContextualType` does no such widening), so
        // `q<const T extends { a: number }>({ a: 1 })` must see `T`.
        if (tag == .object_literal and c.ts.kind(try c.resolveStructural(pt)) == .type_param and
            !c.isConstTypeVar(try c.resolveStructural(pt)))
        {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(try c.resolveStructural(pt)));
            if (con != types.no_type) arg_ctx = con;
        }
        // tsc's `instantiateContextualType`: substitute what this call
        // already knows — the Phase-0 return-context inferences plus the
        // arguments inferred to the left — into the contextual type. A param
        // with no candidate yet stays FREE, so the shapes that deliberately
        // rely on a free inference variable in the contextual type (a
        // tuple-constrained `T`, a nested `Iterable<readonly [K, V]>`) are
        // untouched; only the ones we can actually resolve are resolved.
        if (arg_ctx != types.no_type) {
            arg_ctx = try c.instantiateKnownParams(arg_ctx, tp_syms, candidates, ret_seed);
        }
        // A CONTEXT-SENSITIVE object literal (`{ v: x, onChange: (value) =>
        // … }`) needs two passes, exactly as tsc runs them. Its callback
        // properties can only be typed once the type parameters are known,
        // but the type parameters are inferred from this very argument — so
        // pass one checks it context-free purely to collect candidates
        // (quietly: every implicit-`any` it sees is an artifact of running
        // early), and pass two re-checks it against the parameter with
        // those candidates substituted, which is the authoritative check.
        // Without it the callback's parameters were left implicit `any`
        // (TS7006) at call sites that are correct TypeScript, while the
        // NON-generic form of the same call — which types the argument by
        // the parameter directly — was fine.
        // Pass one's inferences are PROVISIONAL — the callback properties it
        // saw had implicit-`any` parameters, and `any` absorbs the union it
        // is combined with, so committing them would fix the very type
        // parameter this argument is meant to determine. They live in a
        // scratch copy that only builds pass two's contextual type; pass
        // two re-derives every candidate this argument really carries.
        //
        // A literal-keeping contextual type normally REPLACES the two
        // passes, and rightly so: every un-annotated callback such a
        // literal carries at its OWN top level is named directly by a
        // property of the parameter type, so the single contextual read
        // types them and is the better reading.
        //
        // That reasoning does not reach a callback one level DOWN, inside a
        // nested object literal. The nested bag is read against the
        // parameter's property type, which is routinely a bare inference
        // variable of this very call — the variable the bag is meant to
        // determine — so what comes back still names this call's own
        // parameters. RTK's `createSlice({ name, initialState, reducers })`
        // is that shape: `name: Name` (`Name extends string`) asks for the
        // literal-keeping read, while `reducers` is a bag of un-annotated
        // case reducers read against `ValidateSliceCaseReducers<State, CR>`
        // with `State` still free. `CaseReducers` came out as
        // `{ … (state: State) => void … }`, failed its own
        // `CR extends SliceCaseReducers<State>` check, and was clamped to
        // that constraint — whose `keyof` is `string`, which collapsed
        // `slice.actions`' `{ [Type in keyof CaseReducers]: … }` to `{}`.
        // The two passes fix `State` between them, which is exactly the
        // missing step, so they run for a NESTED-only sensitivity.
        if (tag == .object_literal and c.objLitIsContextSensitive(an) and
            (arg_ctx == types.no_type or !c.objLitIsShallowContextSensitive(an)))
        {
            const probe_cands = try c.scratch().alloc(TypeId, tp_syms.len);
            for (candidates, 0..) |cd, i| probe_cands[i] = cd;
            c.side_query_depth += 1;
            const ctx2 = blk: {
                errdefer c.side_query_depth -= 1;
                const probe = try c.checkExprCached(an, arg_ctx);
                try c.unify(pt, probe, tp_syms, probe_cands, 0);
                // Every type parameter is FIXED for pass two: one the probe
                // could not infer takes its default/constraint (tsc fixes a
                // type parameter before instantiating the contextual type of
                // a context-sensitive argument). Leaving it free would hand
                // the callback a bare type variable — `key: K` compared
                // against a literal is then a spurious TS2367, where the
                // constraint `keyof T` is exactly the domain tsc uses.
                // Resolved in declaration order so a later parameter's
                // constraint sees the earlier ones (`K extends keyof T`).
                var map2: std.ArrayList(TpMap) = .empty;
                defer map2.deinit(c.scratch());
                for (tp_syms, 0..) |sym, i| {
                    var v = if (probe_cands[i] != types.no_type) probe_cands[i] else ret_seed[i];
                    if (v == types.no_type) {
                        // Default, else constraint, else the `any`
                        // placeholder the contextual pass over function
                        // ARGUMENTS already uses for an unresolved
                        // parameter — `unknown` would be a stricter type
                        // than the call can justify and would turn every
                        // use of the callback's parameter into an error.
                        v = try c.typeParamDefault(sym);
                        if (v == types.no_type) v = try c.typeParamConstraint(sym);
                        if (v == types.no_type) v = types.any_type;
                    }
                    // Declaration order applies to a probe CANDIDATE too,
                    // not only to a fallback: the probe read the argument
                    // while the earlier parameters were still free, so its
                    // candidate can carry them (`reducers`' inferred
                    // `{ a: (state: State) => void }` still naming the
                    // `State` that `initialState` has since pinned).
                    // Handing that to pass two left the free variable in
                    // the contextual type, so pass two re-derived the same
                    // half-open candidate and the constraint check
                    // (`CR extends SliceCaseReducers<State>`) rejected it —
                    // clamping the parameter to its constraint, whose
                    // `keyof` is `string`, which is how RTK's
                    // `slice.actions` became `{}`.
                    if (map2.items.len > 0) v = try c.instantiate(v, map2.items);
                    try map2.append(c.scratch(), .{ .sym = sym, .ty = v });
                }
                break :blk try c.instantiate(pt, map2.items);
            };
            c.side_query_depth -= 1;
            const at2 = try c.checkExprCached(an, ctx2);
            try c.unify(pt, at2, tp_syms, candidates, 0);
            continue;
        }
        var at = try c.checkExprCached(an, arg_ctx);
        // tsc's `checkExpressionWithContextualType` strips a contextually
        // typed literal's FRESHNESS before handing it to `inferTypes` —
        // "such that contextually typed literals always preserve their
        // literal types (otherwise they might widen during type inference)".
        // The parameter is the contextual type here, so the test is whether
        // it names a literal domain this argument belongs to.
        //
        // It is the whole difference between two shapes that look alike:
        // `on(eventName: K | keyof T, …)` infers `K = "add"` because the
        // union has a string-literal constituent for `"add"` to match — and
        // it must, or the dependent `Listener<K, T>` conditional reduces to
        // `never` and the listener's parameters are implicit `any`. Whereas
        // `useState(initial: S | (() => S))` still widens `false` to
        // `boolean`, because nothing in that union is a literal.
        //
        // The node's own cached type is untouched: only the evidence this
        // call infers from is regularized, which is where tsc applies it too.
        if (c.ts.isFreshLiteral(at) and try c.literalOfContextualType(at, pt)) {
            at = try c.ts.regularLiteral(at);
        }
        // An EMPTY array literal is the accumulator seed of a fold
        // (`arr.reduce((acc: T[], el) => …, [])`). It carries no element
        // evidence, and its type here is `any[]`, so unioning it into the
        // parameter's candidates buries whatever the real evidence — the
        // callback's annotated accumulator, a sibling argument — says:
        // `T[]` became `any[] | T[]`. tsc reaches `T[]` because it takes
        // the common SUPERTYPE of a parameter's covariant candidates and
        // the seed's `never[]` is a subtype of every array; ztsc unions, so
        // instead the seed is demoted the same way a placeholder echo is —
        // it fills the parameter only when nothing else constrained it, so
        // `f<U>(seed: U)` called with `[]` still infers the empty array.
        if (tag == .array_literal and c.tree.nodeRange(an).len == 0) {
            for (candidates, 0..) |cd, i| pre_seed[i] = cd;
            try c.unify(pt, at, tp_syms, candidates, 0);
            for (candidates, 0..) |*cd, i| {
                if (cd.* == pre_seed[i]) continue;
                if (empty_seed[i] == types.no_type) empty_seed[i] = cd.*;
                cd.* = pre_seed[i];
            }
            continue;
        }
        try c.unify(pt, at, tp_syms, candidates, 0);
    }
    // Phase 1.75: a NON-ARRAY rest parameter takes the trailing arguments as
    // a TUPLE. tsc's `getNonArrayRestType` / `getSpreadArgumentType`: when
    // the rest's declared type is not a plain array — a bare type parameter,
    // `...paths: K` with `K extends PropertyName[]` — the arguments from the
    // rest position on are packed into a tuple and the WHOLE tuple is
    // inferred against it. `paramTypeAt` answers the rest's array ELEMENT
    // instead, which mentions no inference variable, so `K` got no candidate
    // at all and fell back to its constraint: lodash's
    // `omit<T, K extends PropertyName[]>(o, ...paths: K):
    //  Pick<T, Exclude<keyof T, K[number]>>` then reduced to `Pick<T, never>`
    // — `{}` — for every call.
    //
    // Each element keeps its literal when the rest's element type is
    // PRIMITIVE (tsc's `hasPrimitiveContextualType` branch of the same
    // function, which is what makes `omit(o, 'a')` infer `['a']` and not
    // `[string]`); otherwise it widens, exactly as an unannotated position
    // does.
    if (c.ts.fnParamCount(sig) > 0) restTuple: {
        const pcount = c.ts.fnParamCount(sig);
        const last = c.ts.fnParam(sig, pcount - 1);
        if (!last.rest()) break :restTuple;
        if (c.ts.kind(last.ty) != .type_param) break :restTuple;
        if (tpIndex(tp_syms, c.ts.typeParamSymbol(last.ty)) == null) break :restTuple;
        const fixed = pcount - 1;
        if (arg_nodes.len < fixed) break :restTuple;
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(last.ty));
        const elem = if (con == types.no_type) types.no_type else try c.elemOfArrayish(con);
        const keep_literal = elem != types.no_type and try c.isPrimitiveLiteralish(elem);
        var elems: std.ArrayList(types.TupleElem) = .empty;
        defer elems.deinit(c.scratch());
        for (arg_nodes[fixed..]) |an| {
            if (an == null_node) break :restTuple; // an elided argument: no tuple
            switch (c.nodeTag(an)) {
                // A spread has no positional expansion here, and a
                // CONTEXT-SENSITIVE function argument must not contribute:
                // tsc checks it under `SkipContextSensitive` in this pass,
                // gets `anyFunctionType`, and the tuple built around it
                // propagates `ObjectFlags.NonInferrableType`, so the whole
                // inference is skipped. Without the skip, `store.set(atom,
                // (s) => …)` infers `Args` from the un-contextualized arrow
                // instead of from the `WritableAtom` argument that carries
                // it, and the callback's parameters go implicit `any`
                // (conformance `inference/092`).
                .spread_element, .arrow_fn, .function_expr => break :restTuple,
                else => {},
            }
            const at = try c.checkExprCached(an, types.no_type);
            try elems.append(c.scratch(), .{ .ty = if (keep_literal)
                try c.ts.regularLiteral(at)
            else
                try c.widenLiteral(at) });
        }
        try c.unify(last.ty, try c.ts.makeTuple(elems.items), tp_syms, candidates, 0);
    }
    // Phase 1.5: contextual return-type *seed* (tsc's ReturnType-priority
    // inference happens *before* callback arguments are contextually
    // typed). A type param appearing only in a callback's return position
    // and in the signature's return type — `Array.map<U>(cb: (…) => U):
    // U[]` under an expected `Polygon[]` — is fixed to `Polygon` from the
    // outer context, so the callback body is typed against `Polygon` and
    // keeps its literal discriminants (`{ type: 'Polygon' }`) instead of
    // widening `U` to `any` and inferring `{ type: string }`. The seed only
    // feeds the contextual `partial` below; argument inference still writes
    // the committed `candidates` (so argument evidence wins the final args).
    // Allocated only when there is a contextual return to seed from — the
    // overwhelmingly common uncontextual call keeps the original (no extra
    // scratch) path, using `candidates` directly as the partial source.
    const seed: []const TypeId = if (ret_ctx != types.no_type) blk: {
        const s = try c.scratch().alloc(TypeId, tp_syms.len);
        for (s, 0..) |*x, i| x.* = candidates[i];
        try c.fillFromReturnContext(sig, tp_syms, ret_ctx, s, true, true);
        break :blk s;
    } else candidates;
    // Phase 2: function arguments, contextually typed by the partial
    // instantiation (seeded with the return-context inferences above).
    var partial = try c.scratch().alloc(TpMap, tp_syms.len);
    // Which params the seed already fixed. Snapshotted because `seed`
    // ALIASES `candidates` in the uncontextual case, so it cannot be
    // consulted again once argument inference starts writing candidates.
    const seeded = try c.scratch().alloc(bool, tp_syms.len);
    for (tp_syms, 0..) |tp, i| {
        seeded[i] = seed[i] != types.no_type;
        partial[i] = .{ .sym = tp, .ty = if (seeded[i]) seed[i] else types.any_type };
    }
    // Placeholder-echo candidates, demoted to a fallback (see below).
    const echo_any = try c.scratch().alloc(TypeId, tp_syms.len);
    for (echo_any) |*x| x.* = types.no_type;
    const placeheld = try c.scratch().alloc(bool, tp_syms.len);
    const before = try c.scratch().alloc(TypeId, tp_syms.len);
    // The contravariant twin of the placeholder echo. The callback's
    // parameters are typed from `partial`, so its parameter types come back
    // as whatever we just put in — and a parameter position is exactly
    // where a contravariant candidate is read. `reduce((acc, x) => acc + x,
    // 0)` would hand `acc` the seed's `0`, read `0` straight back as a
    // contravariant candidate, and then reject the covariant `number` for
    // not being a subtype of it. A candidate identical to the type we fed
    // the argument is our own guess coming home, not evidence.
    const fed = try c.scratch().alloc(TypeId, tp_syms.len);
    const before_contra = try c.scratch().alloc(TypeId, tp_syms.len);
    ai = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        const tag = c.nodeTag(an);
        if (tag != .arrow_fn and tag != .function_expr) continue;
        const pt0 = try c.paramTypeAtInferred(sig, ai, partial) orelse continue;
        for (partial, 0..) |p, i| {
            placeheld[i] = !seeded[i] and p.ty == types.any_type;
            before[i] = candidates[i];
            fed[i] = p.ty;
            before_contra[i] = contra[i];
        }
        const pt_partial = try c.partialParamCtx(pt0, partial);
        // A CONTEXT-SENSITIVE function argument this candidate hands NO
        // contextual signature is not an inference source, and walking it is
        // worse than useless. Its un-annotated parameters become implicit
        // `any`, so what it yields is tsc's `anyFunctionType` — which
        // `inferFromTypes` refuses outright — and the walk PUBLISHES its body:
        // the arrow's own node key carries the contextual type, so a later
        // walk misses that memo and re-derives, but every identifier read
        // INSIDE is memoized under (node, no-context). A walk that saw
        // `eb: any` publishes `eb.ref('x'): any`, and the overload candidate
        // that finally gives `eb` its real type reads that `any` straight
        // back. tsc reaches the same place from the other side:
        // `chooseOverload` runs its first inference pass with
        // `SkipContextSensitive`, which types such an argument as
        // `anyFunctionType` and infers nothing from it.
        //
        // An ANNOTATED function argument is not context sensitive — its type
        // is the same whatever it is handed — so it stays an inference source.
        if (try c.contextualCallSig(pt_partial) == types.no_type and
            c.fnExprIsContextSensitive(an)) continue;
        const at = try c.checkExprCached(an, pt_partial);
        try c.unify(pt0, at, tp_syms, candidates, 0);
        for (contra, 0..) |*cc, i| {
            if (cc.* != before_contra[i] and cc.* == fed[i]) cc.* = before_contra[i];
        }
        // Placeholder echo. A parameter with no candidate yet stands in as
        // `any` in this argument's contextual type, so a callback that
        // merely passes that value through infers `any` straight back —
        // evidence the argument does not actually carry. tsc never sees it:
        // it leaves the variable FREE, and `inferFromTypes` ignores an
        // inference from a type to itself. The echo poisons every LATER use
        // of the parameter: `getFormValue`'s `T` came out `any` from its
        // `(element) => element.attr` argument, and the union parameter
        // after it then collapsed, so its arrow lost every contextual
        // parameter type. Demoted, not dropped — it fills the parameter
        // after Phase 2 when nothing else constrained it, so a callback that
        // genuinely returns `any` still infers `any`.
        for (candidates, 0..) |*cd, i| {
            if (!placeheld[i] or cd.* == before[i]) continue;
            if (c.ts.kind(cd.*) != .any) continue;
            echo_any[i] = types.any_type;
            cd.* = before[i];
        }
        // Feed what this argument taught us into the contextual type of the
        // function arguments to its RIGHT — tsc's `instantiateContextualType`
        // uses the inferences made so far, and Phase 1 already does this for
        // non-function arguments. Without it an unresolved param stays the
        // `any` placeholder, and `any` absorbs the union it sits in:
        // `defaultValue: T | ((selected: boolean) => T)` became plain `any`
        // whenever `T` was learned from an earlier CALLBACK argument, so the
        // arrow written for it got no contextual signature and every
        // parameter went implicit-`any`. Seeded params keep their seed (the
        // contextual return still owns those).
        for (partial, 0..) |*p, i| {
            if (!seeded[i] and candidates[i] != types.no_type) p.ty = candidates[i];
        }
    }
    // Demoted candidates fill what nothing else constrained.
    for (candidates, 0..) |*cd, i| {
        if (cd.* != types.no_type) continue;
        if (empty_seed[i] != types.no_type) cd.* = empty_seed[i];
        if (cd.* == types.no_type and echo_any[i] != types.no_type) cd.* = echo_any[i];
    }
    // Phase 3: contextual return-type inference for any params still
    // unbound after argument inference (argument inference always wins —
    // this only *fills* params that no argument constrained) — so
    // `union(featureCollection(xs))` recovers `featureCollection`'s `G`
    // from the expected `FeatureCollection<Polygon | MultiPolygon>` instead
    // of falling back to `G`'s constraint (the whole `Geometry` union).
    try c.fillFromReturnContext(sig, tp_syms, ret_ctx, candidates, false, false);
    // Contravariant candidates outrank covariant ones (tsc's
    // `getInferredType`): the covariant inference survives only when it is
    // not `never` AND is a subtype of the contravariant one — that is, when
    // every parameter position the type variable appears in would still
    // accept it. Otherwise the parameter takes the contravariant candidates'
    // common subtype, which is the narrowest type all of those positions
    // can be fed. Without the split, a callback's parameter type was
    // unioned into the same accumulator as the value the call actually
    // produces, and the union then satisfied neither.
    for (candidates, 0..) |*cd, i| {
        const ct = contra[i];
        if (ct == types.no_type) continue;
        if (cd.* != types.no_type and c.ts.kind(cd.*) != .never and
            try c.covSubtypeOf(cd.*, ct)) continue;
        cd.* = ct;
    }
    // A provisional map over the raw candidates, so an inter-dependent
    // constraint (`K extends keyof T`) is checked with the *other*
    // params already substituted — `keyof T` becomes `keyof {…}` before the
    // satisfaction test, instead of staying a deferred `keyof T` that no
    // literal is assignable to.
    var prov = try c.scratch().alloc(TpMap, tp_syms.len);
    for (tp_syms, 0..) |tp, i| {
        prov[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
    }
    // `infos[i].constraint` is an AST node id in the type param's
    // *declaring* file (e.g. a foreign generic's `.d.ts`), not in `c.tree`
    // (the call site). It is resolved via the symbol below so the
    // constraint is evaluated in its declaring file + declaration scope
    // (`enterSymFile` + `symScope`, per `typeParamConstraint`); evaluating
    // the raw node against `c.tree` reads out of bounds when the two files
    // differ. `tp == infos[i].sym`, and the symbol's type_param decl is the
    // very node the constraint field came from, so this is equivalent.
    // Resolve in declaration order, feeding each resolved arg back into
    // `prov` so a later param's constraint that references an earlier one
    // sees the *resolved* value, not the `any` placeholder. tsc's
    // `getInferredTypes` works this way; without it an un-inferred `TOpt`
    // stayed `any` inside `Ret extends TReturn<TOpt>`, so
    // `any['returnObjects'] extends true` wrongly took the true branch
    // (i18next `t()` → `$SpecialObject` instead of `string`).
    // Signature return type (for the literal-widening top-level test below);
    // `no_type` when `sig` is not a plain function (an overload set never
    // reaches per-signature inference here).
    const sig_ret: TypeId = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.no_type;
    for (tp_syms, 0..) |tp, i| {
        var constraint: TypeId = try c.typeParamConstraint(tp);
        if (constraint != types.no_type) constraint = try c.instantiate(constraint, prov);
        if (candidates[i] != types.no_type) {
            out[i] = candidates[i];
            // tsc's `getCovariantInference` widens a fresh-literal inference
            // candidate (`getWidenedLiteralType`) before fixing the param —
            // UNLESS the param has a primitive/literal constraint (which
            // keeps the literal) or it appears at the top level of the
            // signature's return type. `useState<S>(x): [S, …]` → `S` is a
            // tuple element (not top-level), no constraint → `useState(false)`
            // widens `S` to `boolean`, so `setX(true)` no longer spuriously
            // fails; `id<T>(x: T): T` keeps `T` (top-level return);
            // `f<T extends 'a' | 'b'>` keeps the literal (primitive
            // constraint). Only fresh literals widen, so `x as const` and a
            // `null` candidate stay narrow. An explicit type argument never
            // reaches here (it fills `out` directly upstream).
            //
            // The third condition is tsc's `InferenceInfo.topLevel`: the
            // candidate must have come from a top-level occurrence of the
            // param in the PARAMETER type too. `Object.fromEntries<T>(e:
            // Iterable<readonly [PropertyKey, T]>)` buries `T` two levels
            // down, so `fromEntries(xs.map(x => [x.id, true]))` keeps `true`
            // and the result still satisfies `{ [k: string]: true }`;
            // widening it gave `boolean`.
            //
            // A `const` type parameter never widens: tsc's
            // `getCovariantInference` folds `isConstTypeVariable` into the
            // same `primitiveConstraint` test this mirrors, so `f<const T>`
            // keeps `"a"` for `f("a")` exactly as an `extends string`
            // constraint would.
            // A fresh higher-order param whose bound was a bare OUTER param
            // carries that bound only for this test (`FreshTp.widen_bound`):
            // it is not enforced, but `<T extends TB>` under `TB := "asset"`
            // is a primitive constraint as far as tsc's widening rule is
            // concerned, and treating it as unconstrained widened kysely's
            // `selectAll("asset")` key to `string` — which then indexed the
            // schema to nothing and made the whole row type `{}`.
            // `typeParamConstraint` above has already forced any deferred
            // bound (`FreshTp.pending_bound`), which is what fills this in;
            // the guard is here so the invariant is local rather than an
            // ordering accident.
            if (c.isFreshTp(tp) and c.freshTp(tp).pending_bound != types.no_type) try c.resolveFreshBound(tp);
            const widen_bound: TypeId = if (c.isFreshTp(tp)) c.freshTp(tp).widen_bound else types.no_type;
            const primitive_constraint = c.isConstTypeParamSym(tp) or
                try c.constraintIsPrimitive(constraint) or
                try c.constraintIsPrimitive(widen_bound);
            if (sig_ret != types.no_type and
                top_flags[i] and
                !primitive_constraint and
                !try c.typeParamAtTopLevel(sig_ret, tp))
            {
                out[i] = try c.widenLiteral(out[i]);
            } else if (primitive_constraint) {
                // tsc's `getCovariantInference` is a three-way choice, and the
                // arm above is only its middle one:
                //     primitiveConstraint ? sameMap(candidates, getRegularTypeOfLiteralType)
                //   : widenLiteralTypes  ? sameMap(candidates, getWidenedLiteralType)
                //   : candidates
                // A param whose constraint KEEPS the literal still loses its
                // FRESHNESS. Both variants intern separately here, so a fresh
                // `"album"` inferred for `<T extends keyof DB>` is a different
                // TypeId from the `"album"` inside `keyof DB` — and a union of
                // the two (kysely's `From<DB, TE>` maps over `keyof DB |
                // ExtractAlias<DB, TE>`) failed to dedupe, materializing the
                // same key twice. Only the un-widened arm needs this: widening
                // already yields the regular base primitive.
                out[i] = try c.ts.regularLiteral(out[i]);
            }
            // Candidate violating the constraint falls back to the
            // constraint (tsc then re-checks args against it). But skip
            // the fallback when the constraint — after substituting the
            // params inferred so far — still references an *outer* type
            // param we cannot resolve here: e.g. a generic-interface
            // method `filter<S extends T>` accessed on an instantiated
            // `Array<number|null>`, whose receiver `T` is not part of this
            // call's inference set. The constraint stays a bare `T`, so
            // `isAssignable(number, T)` always fails and would erase the
            // legitimately-inferred `S=number` back to `T` (`S[]` → `T[]`).
            // tsc has the substituted bound (`S extends number|null`) and
            // keeps `number`; we cannot recover it, so trust the candidate.
            // The skip is deliberately narrow — only a *bare* outer type
            // param (`S extends T`, `T` being the receiver's param). A
            // complex constraint that merely mentions an outer param
            // (`K extends keyof T`) still falls back, so RHF-style deep
            // generics keep their prior (permissive) behavior.
            const bare_outer = constraint != types.no_type and
                c.ts.kind(constraint) == .type_param and
                tpIndex(tp_syms, c.ts.typeParamSymbol(constraint)) == null;
            if (constraint != types.no_type and !bare_outer and
                !try c.isAssignable(candidates[i], constraint))
            {
                var fell_back = false;
                out[i] = try c.clampToConstraint(out[i], constraint, &fell_back);
            }
        } else if (c.typeParamHasDefault(tp)) {
            // Uninferable param with a default takes it, instantiated under
            // the params resolved so far (`B = A` sees the inferred `A`).
            const def = try c.typeParamDefault(tp);
            out[i] = try c.instantiate(def, prov);
        } else {
            out[i] = if (constraint != types.no_type) constraint else types.unknown_type;
        }
        prov[i].ty = out[i];
    }
}

pub fn tpIndex(tp_syms: []const u32, sym: u32) ?usize {
    for (tp_syms, 0..) |s, i| {
        if (s == sym) return i;
    }
    return null;
}

/// A candidate that violates its param's constraint is normally clamped to
/// the constraint. When the candidate is a UNION, prefer the
/// constraint-satisfying members over erasing the whole inference — this
/// drops contravariant-inference pollution such as a function type inferred
/// from a callback's PARAMETER position (`onChange: (v: T) => void` fed a
/// `Dispatch<SetStateAction<E>>`, contributing `E | ((p:E)=>E)` to `T`),
/// which the covariant candidate (`E` from `value`) should win over. tsc
/// keeps covariant and contravariant candidates separate and prefers
/// covariant; this approximates that at the resolution seam. `fell_back` is
/// set only when the full constraint clamp is used.
pub fn clampToConstraint(c: *Checker, cand: TypeId, constraint: TypeId, fell_back: *bool) Error!TypeId {
    if (c.ts.kind(cand) == .union_type) {
        const members = try c.memberList(cand);
        var keep: std.ArrayList(TypeId) = .empty;
        defer keep.deinit(c.scratch());
        for (members) |m| {
            if (try c.isAssignable(m, constraint)) try keep.append(c.scratch(), m);
        }
        if (keep.items.len > 0 and keep.items.len < members.len) {
            const filtered = try c.ts.makeUnion(c.scratch(), keep.items);
            if (try c.isAssignable(filtered, constraint)) return filtered;
        }
    }
    fell_back.* = true;
    return constraint;
}

/// Is this candidate one of the *literal* shapes tsc's
/// `unionObjectAndArrayLiteralCandidates` pulls out of the covariant set —
/// an object literal or an array literal? Freshness answers it exactly for
/// objects (ztsc's fresh bit is tsc's `ObjectFlags.ObjectLiteral`). Arrays
/// and tuples carry no such bit: their types are interned structurally, so
/// a `string[]` written as a literal and a declared `string[]` are the same
/// id. They are therefore all treated as literal-shaped, which keeps the
/// union tsc forms between two array literals; the price is that a declared
/// array folded against an array literal also unions instead of taking the
/// supertype (which is what happened to every candidate pair before this
/// rule existed, so nothing regresses).
pub fn covLiteralShape(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .array, .tuple => true,
        .object => c.ts.objectIsFresh(t),
        else => false,
    };
}

/// The common base of a literal type, or of a union whose members are all
/// literals sharing one base (tsc's `getBaseTypeOfLiteralType`, including
/// its union branch). `no_type` when the type is not literal-only — which
/// is also the answer for a base primitive itself, since tsc's
/// `literalTypesWithSameBaseType` rejects a candidate that *is* its own base.
pub fn covLiteralBase(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return c.literalBaseOf(t);
    var base: TypeId = types.no_type;
    for (try c.memberList(t)) |m| {
        const b = try c.literalBaseOf(m);
        if (b == types.no_type) return types.no_type;
        if (base == types.no_type) base = b else if (base != b) return types.no_type;
    }
    return base;
}

/// 1 = has an `undefined` constituent, 2 = has a `null` one (tsc's
/// `TypeFlags.Nullable`; `void` is deliberately not one of them).
pub fn covNullableFlags(c: *Checker, t: TypeId) u2 {
    var f: u2 = 0;
    const members: []const TypeId = if (c.ts.kind(t) == .union_type) c.ts.members(t) else &.{t};
    for (members) |m| switch (c.ts.kind(m)) {
        .undefined => f |= 1,
        .null => f |= 2,
        else => {},
    };
    return f;
}

pub fn covStripNullable(c: *Checker, t: TypeId) Error!TypeId {
    return c.filterUnion(t, struct {
        fn keep(ch: *Checker, m: TypeId) bool {
            const k = ch.ts.kind(m);
            return k != .undefined and k != .null;
        }
    }.keep);
}

/// `isTypeSubtypeOf` as far as the supertype fold needs it: assignability
/// plus the one place the subtype relation is strictly stronger and the
/// difference is observable here — a source that omits an OPTIONAL property
/// of the target is assignable to it but is not a subtype of it, so
/// `{ a: number }` folded against `{ a: number; b?: string }` keeps the
/// former (tsc's answer) instead of climbing to the latter.
pub fn covSubtypeOf(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (!try c.isAssignable(a, b)) return false;
    const rb = try c.resolveStructural(b);
    if (c.ts.kind(rb) != .object) return true;
    for (0..c.ts.objectPropCount(rb)) |i| {
        const p = c.ts.objectProp(rb, @intCast(i));
        if (p.flags & types.prop_flag_optional == 0) continue;
        if (try c.propOfType(a, p.name) == null) return false;
    }
    return true;
}

/// Combine two covariant inference candidates for the same type parameter.
///
/// tsc's `getCovariantInference` resolves a parameter's candidate set with
/// `getCommonSupertype`, never with a union: the candidates are folded left
/// to right by `reduceLeft((s, t) => isTypeSubtypeOf(s, t) ? t : s)`, so
/// unrelated candidates keep the LEFTMOST one and the call then reports the
/// argument that does not fit. A union is formed in exactly two places —
/// when the candidates are literals over one base (`f("a", "b")` gives
/// `"a" | "b"`), and among the object/array literal candidates, whose union
/// is folded in last. Nullable constituents are stripped from every
/// candidate before the fold and added back after it.
///
/// ztsc has no candidate *list* — `unify` keeps one accumulator per
/// parameter — so the fold runs incrementally. That is exact for
/// `reduceLeft`; the one place it is not is a literal candidate arriving
/// after the fold has already taken a mismatched-base step (`f(1, "a", 2)`
/// yields `1 | 2` where tsc yields `1`), since the accumulator no longer
/// records that the run of same-base literals was already broken.
pub fn combineCovariant(c: *Checker, prev: TypeId, cand: TypeId) Error!TypeId {
    if (prev == cand) return prev;
    const s = &c.ts;
    // `any` is a supertype of everything and a subtype of nothing in tsc's
    // subtype relation, so it wins the fold from either side.
    if (s.kind(prev) == .any or s.kind(cand) == .any) return types.any_type;
    // A bare type variable as a candidate is the weakest evidence there is
    // — it says the argument's shape MENTIONS the variable, not that the
    // parameter is it. tsc files such an inference at a lower
    // `InferencePriority` and never folds it against a structural
    // candidate; ztsc has no priorities, so the pair keeps the union it
    // formed before the supertype rule existed rather than letting an
    // arbitrary arrival order decide (`argsOrArgArray<T>((T | T[])[])` fed
    // `(ObservableInput<T> | ObservableInput<T>[])[]` collects both a bare
    // `T`, via `ArrayLike<T>`'s iteration element, and the real union).
    if (s.kind(prev) == .type_param or s.kind(cand) == .type_param) return c.makeUnion2(prev, cand);
    if (c.covLiteralShape(prev) and c.covLiteralShape(cand)) return c.makeUnion2(prev, cand);
    // The literal candidates' union is folded in LAST, so a literal never
    // sits on the left of the pair. Only a FRESH OBJECT triggers the
    // reorder: it is the one shape ztsc can positively identify as written
    // at the call site, whereas an array's type is the same whether it was
    // written as a literal or declared — reordering on that guess would
    // turn `red<U>(cb, [] as string[])`'s `string[]` seed into the loser of
    // a fold against a stray `string`.
    const flip = s.kind(prev) == .object and s.objectIsFresh(prev);
    var a = if (flip) cand else prev;
    var b = if (flip) prev else cand;
    const nulls = c.covNullableFlags(a) | c.covNullableFlags(b);
    if (nulls != 0) {
        a = try c.covStripNullable(a);
        b = try c.covStripNullable(b);
    }
    var res: TypeId = undefined;
    if (s.kind(a) == .never) {
        res = b;
    } else if (s.kind(b) == .never) {
        res = a;
    } else blk: {
        const ab = try c.covLiteralBase(a);
        if (ab != types.no_type and ab == try c.covLiteralBase(b)) {
            res = try c.makeUnion2(a, b);
            break :blk;
        }
        res = if (try c.covSubtypeOf(a, b)) b else a;
    }
    if (nulls & 1 != 0) res = try c.makeUnion2(res, types.undefined_type);
    if (nulls & 2 != 0) res = try c.makeUnion2(res, types.null_type);
    return res;
}

/// Combine two contravariant inference candidates: tsc's
/// `getCommonSubtype`, `reduceLeft((s, t) => isTypeSubtypeOf(t, s) ? t : s)`
/// — the mirror of the covariant fold, keeping the leftmost candidate that
/// nothing to its right is a subtype of.
pub fn combineContravariant(c: *Checker, prev: TypeId, cand: TypeId) Error!TypeId {
    if (prev == cand) return prev;
    return if (try c.covSubtypeOf(cand, prev)) cand else prev;
}

/// The contravariant candidate slot for type parameter `i`, when the
/// current inference position is a parameter position AND `candidates` is
/// the accumulator the in-flight call registered.
pub fn contraSlot(c: *Checker, candidates: []TypeId, i: usize) ?*TypeId {
    if (c.contra_pos % 2 == 0) return null;
    if (c.contra_owner != candidates.ptr) return null;
    if (c.contra_cands.len != candidates.len) return null;
    return &c.contra_cands[i];
}

/// The `topLevel` flag for type parameter `i`, when `candidates` is the
/// accumulator the in-flight call registered (same identity rule as
/// `contraSlot`).
pub fn topSlot(c: *Checker, candidates: []TypeId, i: usize) ?*bool {
    if (c.contra_owner != candidates.ptr) return null;
    if (c.top_flags.len != candidates.len) return null;
    return &c.top_flags[i];
}

/// The reverse-mapped-priority flag for type parameter `i` (same identity
/// rule as `contraSlot`).
pub fn revSlot(c: *Checker, candidates: []TypeId, i: usize) ?*bool {
    if (c.contra_owner != candidates.ptr) return null;
    if (c.rev_flags.len != candidates.len) return null;
    return &c.rev_flags[i];
}

pub fn unify(c: *Checker, param: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
    if (depth > 16) return;
    // tsc's `inferFromTypes` opens with `if (!couldContainTypeVariables(target))
    // return;` and ztsc had no equivalent. Nothing below can record a candidate
    // unless the PATTERN reaches a type parameter — every writer of
    // `candidates` is under the `.type_param` arm or one of the reverse-mapped
    // helpers, all of which require one — so a pattern with none in it is a
    // pure structural walk with no result. And the walk is not cheap: its arms
    // `resolveStructural` BOTH sides, so pairing two unrelated generic
    // interfaces materializes both member tables and every substituted method
    // signature under them.
    //
    // kysely's `TransactionBuilder.execute<T>(cb: (trx: Transaction<DB>) =>
    // Promise<T>)` is the shape immich trips on. `T` lives only in the return,
    // but inferring it walks the parameter position too, and there the pattern
    // `Transaction<DB>` — no `T` anywhere in it — was unified against the
    // written `Kysely<DB>`, expanding both classes over immich's 60-table `DB`.
    // One such statement, `ocr.repository.ts`'s `deleteAll`, spent the entire
    // 250,000-node statement budget and reported TS2589 where tsc is clean;
    // with the gate it costs under a thousand.
    //
    // `containsTypeParam` is the conservative form (ANY type parameter, not
    // just one of `tp_syms`) and is memoized per type, so the gate is a hash
    // lookup on the hot path.
    if (!try c.containsTypeParam(param)) return;
    const s = &c.ts;
    // An `any` source infers `any` for every inference position in the
    // pattern (tsc's inferFromTypes). Without this, `any` slips past the
    // structural cases (it matches nothing and everything), leaving params
    // unbound — e.g. `then`'s `TResult1 | PromiseLike<TResult1>` against an
    // `any` callback return would bind nothing because `any` is assignable
    // to the union's other members.
    if (s.kind(arg) == .any) {
        // Inside a speculative inference probe an `any` is a WILDCARD, not
        // evidence: the probe runs before the contextual type exists, so
        // the `any` is the artifact it is trying to resolve (a callback
        // parameter with no contextual type yet), and `any` absorbs the
        // union it is combined with. tsc's first inference pass substitutes
        // a wildcard for exactly these and `inferFromTypes` ignores it. The
        // authoritative pass re-derives every candidate.
        if (c.side_query_depth > 0) return;
        try c.bindAnyToTypeParams(param, tp_syms, candidates, depth);
        return;
    }
    // tsc's `inferFromTypes` apparent-source rule: when the target is NOT
    // itself an inference position, a source that is a type VARIABLE
    // contributes through its constraint, not as an opaque `T`. Only the
    // naked inference variable gets the original source — which is why the
    // union/intersection arms are excluded here: they hand the ORIGINAL arg
    // to their naked member and re-enter `unify` for the wrapper members,
    // where this rule then applies (tsc's `inferToMultipleTypes` does the
    // same split). Without it, `castArray(el)` with `el: T extends El |
    // El[]` against `(value: U | U[]) => U[]` inferred `U = T` instead of
    // `U = El`, so every downstream element stayed the opaque `T` and
    // `El`-typed uses of it were rejected.
    // `getApparentType` covers every INSTANTIABLE source, not just a bare
    // type variable: a deferred `T["boundElements"]` contributes through
    // `readonly Bound[] | null` too, which is what lets the array literal
    // written for it be formed as an array of `{ type: "arrow" }` instead
    // of widening its discriminant to `string`.
    const arg_instantiable = switch (s.kind(arg)) {
        .type_param, .index_access, .conditional => true,
        else => false,
    };
    if (arg_instantiable) switch (s.kind(param)) {
        .type_param, .union_type, .intersection => {},
        else => {
            const con = if (s.kind(arg) == .type_param)
                try c.typeParamConstraint(s.typeParamSymbol(arg))
            else
                try c.transitiveBaseConstraint(arg);
            if (con != types.no_type and con != arg) {
                return c.unify(param, con, tp_syms, candidates, depth + 1);
            }
        },
    };
    // tsc's `isTypeParameterAtTopLevel`: a union or an intersection keeps
    // its members at the top level of the pattern; every other constructor
    // buries what it contains. Track the descent so the `.type_param` arm
    // below can tell whether the candidate it records came from a top-level
    // occurrence — only a still-top-level parameter widens a fresh literal.
    const buries = switch (s.kind(param)) {
        .type_param, .union_type, .intersection => false,
        else => true,
    };
    if (buries) c.nontop_depth += 1;
    defer if (buries) {
        c.nontop_depth -= 1;
    };
    switch (s.kind(param)) {
        .type_param => {
            if (tpIndex(tp_syms, s.typeParamSymbol(param))) |i| {
                const cand = arg;
                if (c.nontop_depth > 0) {
                    if (c.topSlot(candidates, i)) |f| f.* = false;
                }
                // A candidate found in a PARAMETER position is
                // contravariant evidence and is kept apart from the
                // covariant set (tsc's `inferFromContravariantTypes`).
                if (c.contraSlot(candidates, i)) |slot| {
                    slot.* = if (slot.* == types.no_type) cand else try c.combineContravariant(slot.*, cand);
                    return;
                }
                // A DIRECT structural match outranks a reverse-mapped one
                // (tsc keeps only the best-priority candidates), so an
                // incumbent that came solely from a `Partial<T>`-shaped
                // parameter is dropped rather than combined — and,
                // symmetrically, evidence recorded from INSIDE a
                // homomorphic-mapped parameter stands down for a direct
                // incumbent.
                if (c.revSlot(candidates, i)) |rf| {
                    if (c.rev_prio > 0) {
                        if (candidates[i] != types.no_type and !rf.*) return;
                        rf.* = true;
                    } else if (rf.*) {
                        rf.* = false;
                        candidates[i] = types.no_type;
                    }
                }
                if (candidates[i] == types.no_type) {
                    candidates[i] = cand;
                } else {
                    candidates[i] = try c.combineCovariant(candidates[i], cand);
                }
            }
        },
        .array => {
            const ra = try c.resolveStructural(arg);
            switch (s.kind(ra)) {
                .array => try c.unify(s.arrayElem(param), s.arrayElem(ra), tp_syms, candidates, depth + 1),
                .tuple => {
                    for (0..s.tupleLen(ra)) |i| {
                        // A REST element carries the whole ARRAY type (see
                        // `checkConstArrayLiteral`), so `[a, b, ...vals]`
                        // must contribute `vals`' element type here, not
                        // `vals` itself — otherwise `T` gets an array
                        // candidate beside its literal ones and the two
                        // cannot combine.
                        const e = s.tupleElem(ra, @intCast(i));
                        const et = if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
                        try c.unify(s.arrayElem(param), et, tp_syms, candidates, depth + 1);
                    }
                },
                .union_type => {
                    // A nullable/union iterable context (`Iterable<E> |
                    // null` — the Map/Set constructor parameter shape):
                    // infer from each constituent, ignoring the members
                    // (`null`/`undefined`) that yield no iteration element.
                    // Mirrors tsc's `getContextualType` mapping over union
                    // constituents.
                    for (try c.memberList(ra)) |m| {
                        try c.unify(param, m, tp_syms, candidates, depth + 1);
                    }
                },
                else => {
                    // Array param (`U[]`) against an iterable-shaped arg
                    // (`Iterable<E>`, `Set<E>`, `Map<K,V>`): infer `U` from
                    // the iteration element, matching tsc's member-based
                    // `inferFromTypes` (Array's `[Symbol.iterator]` vs the
                    // source's). This lets a tuple contextual type thread
                    // from `new Map(...)`'s `Iterable<readonly [K, V]>`
                    // parameter through `.map`'s `U[]` return into the
                    // callback body, so the returned array literal is formed
                    // as a tuple instead of widening.
                    //
                    // A `string` source is iterable but is NOT array-like
                    // for inference: tsc only walks members when the source
                    // is an object/intersection, so `castArray(s)` with
                    // `s: string` must infer nothing here and leave the
                    // naked union member to answer.
                    switch (s.kind(ra)) {
                        .string, .string_literal, .template_literal_type, .string_mapping => return,
                        else => {},
                    }
                    if (try c.iterationElementType(ra)) |elem| {
                        try c.unify(s.arrayElem(param), elem, tp_syms, candidates, depth + 1);
                    }
                },
            }
        },
        .tuple => {
            const ra = try c.resolveStructural(arg);
            // A UNION argument against a tuple parameter — the shape a
            // union parameter hands down, since the `.union_type` arm
            // passes the whole argument to each of its type-parameter-
            // bearing members. `void | readonly [number, T]` matched
            // against `void | readonly [number, string[]]` therefore
            // arrives here as (tuple, union) and inferred nothing, so `T`
            // collapsed to its fallback. tsc's `inferFromTypes` pairs the
            // constituents; distribute over them exactly as the `.array`
            // arm already does (the non-tuple constituents no-op below).
            if (s.kind(ra) == .union_type) {
                for (try c.memberList(ra)) |m| {
                    try c.unify(param, m, tp_syms, candidates, depth + 1);
                }
                return;
            }
            if (s.kind(ra) == .tuple) {
                const n = @min(s.tupleLen(param), s.tupleLen(ra));
                for (0..n) |i| {
                    try c.unify(s.tupleElem(param, @intCast(i)).ty, s.tupleElem(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
            }
        },
        .union_type => {
            // Same-origin fast path for a generic UNION alias — the
            // discriminated-union shape (`GeometricShape<P>`), whose
            // constituents are anonymous object literals and so carry no
            // origin of their own. Member-by-member pairing can only match
            // them structurally, which the branded tuple members defeat, so
            // nothing was inferred and the callee's parameter fell back to
            // its constraint. The union itself does carry the origin: pair
            // the two materializations' type arguments positionally, the
            // same identity rule the `.object`, `.intersection` and `.ref`
            // arms already apply.
            if (c.origin.get(param)) |po| {
                if (s.kind(po) == .ref) {
                    const ra0 = try c.resolveStructural(arg);
                    const ao_opt = c.origin.get(arg) orelse c.origin.get(ra0);
                    if (ao_opt) |ao| {
                        if (s.kind(ao) == .ref and s.refSymbol(ao) == s.refSymbol(po)) {
                            const pa = try c.scratch().dupe(TypeId, s.refArgs(po));
                            const aa = try c.scratch().dupe(TypeId, s.refArgs(ao));
                            const n0 = @min(pa.len, aa.len);
                            for (0..n0) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                            return;
                        }
                    }
                }
            }
            // Unify against the single type-param member if the rest
            // doesn't already accept the arg (common: T | undefined).
            var tp_member: TypeId = types.no_type;
            var n_tp: usize = 0;
            // `T | PromiseLike<T>` (the `.then` onfulfilled return shape):
            // a promise-typed arg should infer `T` from the *awaited* value,
            // not the whole promise — otherwise `p.then(async d => …)`
            // infers `Promise<Promise<X>>` (tsc uses `Awaited` here). This
            // pairs with type-parameter defaults: `then<R1 = T, …>` now
            // fills/threads `R1`, surfacing the promise-nesting that the
            // awaited unwrap corrects.
            var promise_of_tp = false;
            // Identify the single naked type-param member first so we can
            // tell whether a *wrapper* member (`ReadonlyArray<T>` in
            // `T | ReadonlyArray<T>`) already infers T — in which case the
            // naked fallback must stand down (tsc infers a naked union
            // member last, only when no other member supplied a candidate).
            for (try c.memberList(param)) |m| {
                if (s.kind(m) == .type_param and tpIndex(tp_syms, s.typeParamSymbol(m)) != null) {
                    tp_member = m;
                    n_tp += 1;
                }
            }
            const tp_idx: ?usize = if (tp_member != types.no_type) tpIndex(tp_syms, s.typeParamSymbol(tp_member)) else null;
            const before: TypeId = if (tp_idx) |ix| candidates[ix] else types.no_type;
            // tsc's `inferFromTypes` union rule: "first infer between
            // identically matching source and target constituents and
            // remove the matched types". Only the RESIDUAL source is then
            // offered to the inference-bearing members. Without it,
            // `setState(s => cond ? {b:1} : null)` handed the whole
            // `{b:number} | null` return to the `Pick<S, K>` member, which
            // sees a union rather than an object, infers nothing, and lets
            // `K` fall back to `keyof S` — i.e. the full state, which
            // rejects every partial update. Identity is TypeId equality on
            // interned types, so this only fires on an exact match.
            const arg_residual: TypeId = blk: {
                if (s.kind(arg) != .union_type) break :blk arg;
                const ams = try c.memberList(arg);
                var rem: std.ArrayList(TypeId) = .empty;
                defer rem.deinit(c.scratch());
                for (ams) |am| {
                    var paired = false;
                    for (try c.memberList(param)) |pm| {
                        if (pm == am) {
                            paired = true;
                            break;
                        }
                    }
                    if (!paired) try rem.append(c.scratch(), am);
                }
                if (rem.items.len == 0 or rem.items.len == ams.len) break :blk arg;
                break :blk try s.makeUnion(c.scratch(), rem.items);
            };
            // tsc's `inferToMultipleTypes` runs each non-variable target
            // constituent against each SOURCE constituent on its own, and
            // records which sources produced an inference (`matched[i]`). The
            // naked variable then receives the union of the UNMATCHED sources
            // — handing the whole union to the wrapper and then standing the
            // variable down because the wrapper inferred loses every source
            // constituent the wrapper did not account for. `T | T[]` against
            // `string | string[] | undefined` must infer `string | undefined`;
            // matching the wrapper alone gives `string`.
            //
            // Scoped to the shape the bookkeeping is FOR: exactly one naked
            // type-param member, which is also the only case tsc's `matched`
            // array is consulted in (`typeVariableCount === 1`). With no naked
            // member the wrapper keeps the whole union, because splitting it
            // there changes what a wrapper INFERS rather than what is left
            // over — `Pick<T, K> | T | null` against a forwarded `state`
            // union then takes its key set from a single constituent instead
            // of the whole source (conformance `inference/085`).
            const per_constituent = n_tp == 1 and s.kind(arg_residual) == .union_type;
            const src_members: []const TypeId = if (per_constituent)
                try c.memberList(arg_residual)
            else
                &.{arg_residual};
            const matched = try c.scratch().alloc(bool, src_members.len);
            @memset(matched, false);
            for (try c.memberList(param)) |m| {
                if (m == tp_member) continue;
                if (!try c.containsTypeParam(m)) continue;
                for (src_members, 0..) |sm, i| {
                    const snap = try c.scratch().dupe(TypeId, candidates);
                    try c.unify(m, sm, tp_syms, candidates, depth + 1);
                    if (!std.mem.eql(TypeId, snap, candidates)) matched[i] = true;
                }
            }
            // A wrapper member contributed a candidate for the naked var.
            const wrapper_inferred = if (tp_idx) |ix| candidates[ix] != before else false;
            if (n_tp == 1) {
                for (try c.memberList(param)) |m| {
                    if (m == tp_member) continue;
                    if (c.isPromiseLikeOf(m, s.typeParamSymbol(tp_member))) promise_of_tp = true;
                }
                // "Some other member of the union already accounts for the
                // argument, so the variable stands down."
                //
                // Only a member that can INFER may say that. tsc's
                // `inferToMultipleTypes` marks a source constituent matched
                // when inferring it to a non-variable target actually produced
                // an inference, and a target constituent with no inference
                // sites in it never does — `T | { a: number }` still infers
                // `T` from a `{ a: number; b: string }` argument even though
                // that argument satisfies the second member outright.
                //
                // Asking assignability instead let any concrete member veto
                // the whole inference, and the variable then fell back to its
                // own constraint. zod's
                // `pipe<T extends $ZodType<any, output<this>>>(target: T |
                // $ZodType<any, output<this>>)` is that shape exactly: every
                // schema argument satisfies the second member, so `T` was
                // never inferred and every `.pipe(…)` produced
                // `ZodPipe<this, $ZodType<any, output<this>>>` — a type whose
                // unsubstituted `this` makes every later conditional over the
                // schema (`z.output<S>`, `ReturnType<S['parse']>`) defer
                // forever, which is how a `createZodDto` class ended up with
                // no properties at all.
                var rest_ok = false;
                for (try c.memberList(param)) |m| {
                    if (m == tp_member) continue;
                    if (!try c.containsTypeParam(m)) continue;
                    if (try c.isAssignable(arg, m)) rest_ok = true;
                }
                if (promise_of_tp) {
                    const awaited = try c.awaitedType(arg);
                    if (awaited != arg) {
                        try c.unify(tp_member, awaited, tp_syms, candidates, depth + 1);
                    } else if (!rest_ok) {
                        try c.unify(tp_member, arg, tp_syms, candidates, depth + 1);
                    }
                } else {
                    // Naked fallback: infer `T` from the arg. When the param's
                    // OTHER members are concrete (`T | undefined`) and the arg
                    // is a union sharing some of them, infer `T` from the
                    // REMAINDER (`X | undefined` → `T = X`), matching tsc's
                    // union inference (identical members pair off, `T` takes
                    // the rest). Without this, a reducer parameter
                    // `state: S[K] | undefined` would pollute the inferred
                    // element with a spurious `| undefined`. Falls back to the
                    // whole arg when nothing subtracts (and infers nothing
                    // when the whole arg is already covered — `rest_ok`), so
                    // the `T | ReadonlyArray<T>` (flatMap) path is unchanged.
                    //
                    // A constituent an inference-BEARING member already
                    // matched (`matched[i]`, tsc's `inferToMultipleTypes`
                    // bookkeeping) subtracts the same way: what is left of the
                    // source after both filters is what the naked variable
                    // gets. Only when NOTHING is left does the wrapper's
                    // inference stand the variable down entirely — tsc infers
                    // the whole source there at `NakedTypeVariable` priority,
                    // which any candidate the wrapper already recorded beats.
                    var rem: std.ArrayList(TypeId) = .empty;
                    defer rem.deinit(c.scratch());
                    const arg_members: []const TypeId = if (s.kind(arg) == .union_type) try c.memberList(arg) else &.{arg};
                    for (src_members, 0..) |am, i| {
                        if (matched[i]) continue;
                        var covered = false;
                        for (try c.memberList(param)) |m| {
                            if (m == tp_member) continue;
                            if (try c.containsTypeParam(m)) continue;
                            if (try c.isAssignable(am, m)) {
                                covered = true;
                                break;
                            }
                        }
                        if (!covered) try rem.append(c.scratch(), am);
                    }
                    if (rem.items.len > 0 and rem.items.len < arg_members.len) {
                        try c.unify(tp_member, try s.makeUnion(c.scratch(), rem.items), tp_syms, candidates, depth + 1);
                    } else if (!rest_ok and !(rem.items.len == 0 and wrapper_inferred)) {
                        try c.unify(tp_member, arg, tp_syms, candidates, depth + 1);
                    }
                }
            }
        },
        .object => {
            const ra = try c.resolveStructural(arg);
            // A CLASS VALUE (`typeof C`) against a parameter carrying CONSTRUCT
            // signatures — `ClassConstructor<T>`, Nest's `Type<T>`, or a bare
            // `new (...args: any[]) => T`. A class value is not an `.object`
            // (its statics and its constructor are derived from the symbol, not
            // stored as members), so the structural walk below skipped it
            // entirely and `T` was left to its constraint or to `unknown`.
            // Every `get(UserRepository)` / `BaseService.create(AlbumService,
            // …)` / `getMock<T, R = Mocked<T>>(key: ClassConstructor<T>)` in a
            // DI-shaped program then returned `unknown` or the bare base, and
            // each use of the result was a TS2339 — the single largest family
            // on immich's server package.
            //
            // Infer through the construct signature's RETURN type only, paired
            // against the class's instance type at `any` (tsc's
            // `getInstanceType`, and the same instantiation `instanceof`
            // narrowing uses). The signature's PARAMETERS are deliberately not
            // paired: a class's constructor arity is unrelated to the pattern's
            // (`...args: any[]` is what these interfaces universally write), so
            // pairing them could only manufacture candidates.
            if (s.kind(ra) == .class_value and s.objectConstructSigCount(param) > 0) {
                if (try c.instanceofInstanceType(ra)) |inst| {
                    for (0..s.objectConstructSigCount(param)) |i| {
                        const psig = s.objectConstructSig(param, @intCast(i));
                        try c.unify(s.fnReturn(psig), inst, tp_syms, candidates, depth + 1);
                    }
                }
                return;
            }
            if (s.kind(ra) == .object) {
                // Same-origin fast path (tsc's `inferFromTypes` same-reference
                // rule). A generic interface/alias parameter whose type args
                // include the signature's fresh type params is materialized as
                // an *expanded object* (instantiated at its own defaults via
                // the higher-order-sig machinery), yet its origin tag still
                // records the pre-default ref — e.g. `Control<TFieldValues,
                // any, TTransformedValues>`. When the argument is an expansion
                // of the SAME generic (`Control<Payload, …>`), walking the two
                // objects prop-by-prop cannot invert `TFieldValues` through
                // Control's deeply nested mapped/conditional members
                // (`FieldErrors<T>`, `Subjects<T>`, …). Instead pair the origin
                // type args positionally and infer from them — this is how
                // `useWatch({ control, name })` recovers `TFieldValues` from
                // the `control: Control<TFieldValues>` property. Identity-only:
                // it fires solely when both origins are refs to the SAME
                // symbol (a different generic falls through to the structural
                // walk below). Mirrors the `.ref` arm's identity pairing.
                if (c.origin.get(param)) |po| {
                    if (c.origin.get(ra)) |ao| {
                        if (s.kind(po) == .ref and s.kind(ao) == .ref and
                            s.refSymbol(po) == s.refSymbol(ao))
                        {
                            const pa = try c.scratch().dupe(TypeId, s.refArgs(po));
                            const aa = try c.scratch().dupe(TypeId, s.refArgs(ao));
                            const n = @min(pa.len, aa.len);
                            for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                            return;
                        }
                    }
                }
                for (0..s.objectPropCount(param)) |i| {
                    const pp = s.objectProp(param, @intCast(i));
                    if (s.objectPropByName(ra, pp.name)) |ap| {
                        try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                    }
                }
                const pidx = s.objectStringIndex(param);
                if (pidx != 0) {
                    // Reverse index-signature inference (tsc's
                    // `inferFromIndexTypes`): a target string index
                    // `{ [s: string]: T }` — the `Object.values`/`entries`
                    // parameter — infers `T` from a named-property source
                    // (`{ x: {...} }`), since the source has no index
                    // signature to pair with. Without it
                    // `Object.values({x:{s:1}})` leaves `T` unbound and the
                    // result collapses to `unknown[]`.
                    //
                    // tsc collects EVERY applicable source member — each
                    // string-keyed property plus the source's own string
                    // index — and infers their UNION as ONE candidate.
                    // Feeding them one at a time instead made each its own
                    // candidate, and the covariant fold
                    // (`getCommonSupertype`) then keeps only the leftmost of
                    // any two with unrelated bases: `Object.entries({a:
                    // string, b: number})` inferred `string`, the argument
                    // stopped fitting, and the call fell to the
                    // `entries(o: {}): [string, any][]` overload.
                    var parts: std.ArrayList(TypeId) = .empty;
                    defer parts.deinit(c.scratch());
                    for (0..s.objectPropCount(ra)) |i| {
                        try parts.append(c.scratch(), s.objectProp(ra, @intCast(i)).ty);
                    }
                    if (s.objectStringIndex(ra) != 0) {
                        try parts.append(c.scratch(), s.objectStringIndex(ra));
                    }
                    if (parts.items.len != 0) {
                        const one = try s.makeUnion(c.scratch(), parts.items);
                        try c.unify(pidx, one, tp_syms, candidates, depth + 1);
                    }
                }
                if (s.objectNumberIndex(param) != 0 and s.objectNumberIndex(ra) != 0) {
                    try c.unify(s.objectNumberIndex(param), s.objectNumberIndex(ra), tp_syms, candidates, depth + 1);
                }
                // Call / construct signatures on a *callable interface* param
                // (`FunctionComponent<P>`, whose only `P` lives in its call
                // signature `(props: P, …) => …`) against a callable-object
                // arg (`ProviderExoticComponent<ProviderProps<Data>>`): pair
                // sigs from the END (tsc's `inferFromSignatures`) and infer
                // through each — the `.function` param arm below handles the
                // per-signature param/return unify. Without this,
                // `createElement(Ctx.Provider, { value })` leaves the props
                // type param at its default `{}` and the call is rejected.
                for ([_]bool{ false, true }) |is_ctor| {
                    const pn = if (is_ctor) s.objectConstructSigCount(param) else s.objectCallSigCount(param);
                    const an = if (is_ctor) s.objectConstructSigCount(ra) else s.objectCallSigCount(ra);
                    if (pn == 0 or an == 0) continue;
                    const len = @min(pn, an);
                    for (0..len) |i| {
                        const psig = if (is_ctor) s.objectConstructSig(param, @intCast(pn - len + i)) else s.objectCallSig(param, @intCast(pn - len + i));
                        const asig = if (is_ctor) s.objectConstructSig(ra, @intCast(an - len + i)) else s.objectCallSig(ra, @intCast(an - len + i));
                        try c.unify(psig, asig, tp_syms, candidates, depth + 1);
                    }
                }
                return;
            }
            // An INTERSECTION argument against an object-shaped param —
            // tsc's `inferFromTypes` reduces an intersection source to its
            // apparent members and then runs the ordinary structural
            // inference, so each constituent that actually relates to the
            // param contributes candidates. Without this the whole arm fell
            // through (object-vs-intersection matches nothing) and every
            // param stayed unbound: jotai's `useAtom(atom(null))` passes a
            // `PrimitiveAtom<V> & WithInitialValue<V>` to a
            // `WritableAtom<V, A, R>` parameter, so `V` collapsed to
            // `unknown` and every use of the returned value was a spurious
            // TS2339.
            //
            // Constituents are tried one at a time rather than merged into a
            // bag of members: a merge lets an unrelated constituent's
            // same-named property overwrite the matching one, and it also
            // destroys the origin tag that the `.object` arm above needs for
            // its same-generic positional pairing (which is what recovers
            // `V` here — walking `WritableAtom`'s members structurally
            // cannot invert its `read`/`write` signatures as reliably).
            // `constituentRelatesTo` keeps the pass conservative: only a
            // constituent that shares the param's generic origin, one of its
            // property names, or its callability is an inference source, so
            // a companion member such as `{ init: V }` is skipped instead of
            // contributing a wrong candidate that would union into the
            // right one.
            if (s.kind(ra) == .intersection) {
                for (try c.memberList(ra)) |m| {
                    if (try c.constituentRelatesTo(param, m)) {
                        try c.unify(param, m, tp_syms, candidates, depth + 1);
                    }
                }
                return;
            }
            // A UNION argument: pair by generic ORIGIN, the same identity
            // rule the `.ref` arm already applies to a union. A contextual
            // return type that is a union (`A<P> | B<P>`, `A<P> | null`)
            // reaches here whenever its constituents are type ALIASES,
            // which materialize as objects carrying an origin tag rather
            // than staying refs. Walking the whole union structurally binds
            // nothing, so the callee's own parameter fell back to its
            // constraint and the return was rejected against the very type
            // that provided the context. Interfaces never took this path —
            // they stay refs — which is why the same code with `interface`
            // instead of `type` already worked.
            if (s.kind(ra) == .union_type) {
                // Constituents that share the param's generic origin are
                // the authoritative pairing (the `.ref` arm's identity
                // rule); when some match, only they infer.
                if (c.origin.get(param)) |po| {
                    if (s.kind(po) == .ref) {
                        var matched = false;
                        for (try c.memberList(ra)) |m| {
                            const mo = if (s.kind(m) == .ref)
                                m
                            else blk: {
                                const rm = try c.resolveStructural(m);
                                break :blk c.origin.get(rm) orelse continue;
                            };
                            if (s.kind(mo) == .ref and s.refSymbol(mo) == s.refSymbol(po)) {
                                try c.unify(param, m, tp_syms, candidates, depth + 1);
                                matched = true;
                            }
                        }
                        if (matched) return;
                    }
                }
                // Otherwise pick the constituent the param's own
                // DISCRIMINANT selects (tsc's
                // `getMatchingUnionConstituentForType`). A discriminated
                // union built out of anonymous object literals
                // (`GeometricShape<P>`) carries no origin on its members,
                // so the discriminant is the only identity there is — and
                // without it the callee's own parameter fell back to its
                // constraint and the return was rejected against the very
                // type that provided the context. Inferring from EVERY
                // constituent instead (tsc's untargeted union-source rule)
                // is not safe here: a union of sibling object literals with
                // no discriminant then contributes each of its literal
                // property types as a candidate, which collapses to the
                // widened primitive.
                if (try c.discriminatedConstituent(param, ra)) |m| {
                    try c.unify(param, m, tp_syms, candidates, depth + 1);
                    return;
                }
                // An INDEX-SHAPED param (`{ [s: string]: T }` and nothing
                // else — the `Object.entries`/`Object.values`/`Object.keys`
                // parameter) has no property to pair by name, no origin and
                // no discriminant, so the constituents are the only
                // inference sites there are. Here tsc's plain union-source
                // rule applies: `inferFromTypes` recurses constituent by
                // constituent, each contributing ONE candidate (its own
                // members' union, above), and `getCommonSupertype` folds
                // them — keeping the LEFTMOST of two with unrelated bases,
                // which is what makes the call fall to the
                // `entries(o: {}): [string, any][]` overload for a union
                // whose constituents disagree. Leaving `T` unbound instead
                // silently selected the generic overload with `T = unknown`,
                // and a callback annotated with the real element type was
                // then rejected against `[string, unknown]`.
                if (s.objectPropCount(param) == 0 and s.objectCallSigCount(param) == 0 and
                    s.objectConstructSigCount(param) == 0 and s.objectStringIndex(param) != 0)
                {
                    const ms = try c.scratch().dupe(TypeId, try c.memberList(ra));
                    defer c.scratch().free(ms);
                    for (ms) |m| try c.unify(param, m, tp_syms, candidates, depth + 1);
                    return;
                }
                // Otherwise tsc's plain union-source rule, which is the last
                // arm of `inferFromTypes`: when the TARGET is not itself a
                // union/type variable, a union SOURCE infers constituent by
                // constituent (`for (const sourceType of sourceTypes)
                // inferFromTypes(sourceType, target)`). ztsc reached it only
                // through the three identity rules above, so a contextual
                // type that is a union of UNRELATED named types — kysely's
                // `OperandExpression<V> = Expression<V> |
                // SelectQueryBuilderExpression<Record<string, V>>`, the
                // return context `where(expr)` gives its factory argument —
                // inferred nothing, and `sql`'s `<T = unknown>` fell back to
                // its default: `Expression<unknown>` is not an
                // `Expression<SqlBool>` and the call was TS2769.
                //
                // Scoped to the contextual-RETURN pass (`ret_ctx_prio`, tsc's
                // `InferencePriority.ReturnType`) because that is the priority
                // whose several candidates tsc COMBINES — see `ret_ctx_prio`.
                //
                // Gated by `constituentCarriesInference`, which is stricter
                // than the INTERSECTION arm's `constituentRelatesTo`: a
                // constituent qualifies only when it has a property NAMED by
                // one of the param's inference positions. Two reasons.
                // Correctness: a constituent with nothing to say can only
                // manufacture a candidate the covariant fold then has to
                // combine with the right one — which is the sibling-object-
                // literal collapse this arm's comment above warns about.
                // Cost: the untargeted rule takes immich from 3.9 s to
                // 16.2 s, because kysely's contextual types are unions of
                // builder interfaces that all pair with each other on
                // callability alone, and the extra walks spend enough budget
                // to trip it (a fresh TS2589/TS7006 cascade in
                // `duplicate.repository.ts` and `asset.repository.ts`). The
                // narrow filter keeps the wall flat and still finds the one
                // pairing that carries information.
                if (c.ret_ctx_prio > 0) {
                    const ms = try c.scratch().dupe(TypeId, try c.memberList(ra));
                    defer c.scratch().free(ms);
                    for (ms) |m| {
                        if (try c.constituentCarriesInference(param, m, tp_syms)) {
                            try c.unify(param, m, tp_syms, candidates, depth + 1);
                        }
                    }
                }
                return;
            }
            // A plain FUNCTION argument against a callable-interface param —
            // the mirror image of the `.function` arm's callable-object
            // *argument* handling. `ForwardRefRenderFunction<T, P>` is an
            // interface (a call signature plus a `displayName?` property), so
            // every inference position for `forwardRef((props: Props, ref) =>
            // …)` lives in that signature; the object-vs-function mismatch
            // made the whole arm fall through and bind nothing, leaving
            // `ForwardRefExoticComponent<{} & RefAttributes<unknown>>`. tsc's
            // `inferFromSignatures` pairs signatures from the END, so a
            // function source infers against the param's LAST call signature.
            if (s.kind(ra) == .function and s.objectCallSigCount(param) > 0) {
                const psig = s.objectCallSig(param, s.objectCallSigCount(param) - 1);
                return c.unify(psig, ra, tp_syms, candidates, depth + 1);
            }
            // Array/tuple/string arg against an object-shaped param
            // (`ArrayLike<T>`, `Iterable<T>`, `{ length: number }`):
            // the param's number index matches the element type, and
            // its props resolve on the arg via `propOfType` (which
            // covers the element-instantiated `Array<T>`/primitive
            // interface members, e.g. `[Symbol.iterator]`). Fixes
            // `Array.from(xs)` inferring `unknown[]` from an array.
            const elem: TypeId = switch (s.kind(ra)) {
                .array => s.arrayElem(ra),
                // `numberIndexType`, not `tupleElementUnion`: the latter
                // takes a REST element's `.ty` verbatim, which is the whole
                // ARRAY type, so `[a, b, ...vals] as const` contributed an
                // array beside its literals and the combination collapsed.
                .tuple => try c.numberIndexType(ra),
                .string, .string_literal => types.string_type,
                else => return,
            };
            if (s.objectNumberIndex(param) != 0) {
                // Array-like param (`Array<T>`/`ReadonlyArray<T>`/`ArrayLike<T>`):
                // the element type is fully determined by the number index.
                // Scraping the methods too would pull `T` from partial
                // shapes like `at(i): T | undefined` / `find(): T | undefined`,
                // polluting the inference with a spurious `| undefined`
                // (and, for `flatMap`'s `U | ReadonlyArray<U>`, corrupting U).
                try c.unify(s.objectNumberIndex(param), elem, tp_syms, candidates, depth + 1);
            } else if (try c.iterationElementType(param)) |pelem| {
                // No number index but the param IS iterable (`Iterable<T>`,
                // `Set<T>`, `Map<K,V>`): the element type is fully
                // determined by the `[Symbol.iterator]` protocol, so infer
                // through it alone.
                //
                // Scraping every same-named property instead pairs members
                // that have nothing to do with the element: an array's
                // `keys(): ArrayIterator<number>` against `Set<T>`'s
                // `keys(): SetIterator<T>` infers `T = number`, which then
                // wins over the `readonly T[]` member of the same union
                // parameter (`Set<T> | readonly T[] | Record<T, any> |
                // Map<T, any>` — the `isMemberOf` guard shape) and, under a
                // `T extends string` constraint, clamps the whole inference
                // back to `string`.
                try c.unify(pelem, elem, tp_syms, candidates, depth + 1);
            } else {
                // Not iterable either (`{ length: number }` and friends):
                // fall back to matching the param's props on the arg.
                for (0..s.objectPropCount(param)) |i| {
                    const pp = s.objectProp(param, @intCast(i));
                    if (try c.propOfType(ra, pp.name)) |ap| {
                        try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
                    }
                }
            }
        },
        .function => {
            var ra = try c.resolveStructural(arg);
            // A callable intersection (`Reducer<S> & { … }` — RTK's
            // `ReducerWithInitialState`): infer against its function
            // constituent. Without this a reducer passed as a slice value
            // would infer nothing (the reverse-mapped element stalls at
            // `unknown`).
            if (s.kind(ra) == .intersection) {
                for (try c.memberList(ra)) |m| {
                    const rm = try c.resolveStructural(m);
                    if (s.kind(rm) == .function) {
                        ra = rm;
                        break;
                    }
                }
            }
            // A callable OBJECT argument (an interface carrying call
            // signatures rather than a bare function — e.g. `Number`, whose
            // `NumberConstructor` has `(value?: any): number`, passed as
            // `arr.map(Number)`) stands in for a function. Sibling of the
            // inferFromExtends `.function` arm (da9cc33): tsc's
            // inferFromSignatures aligns source/target sigs from the END, so
            // a single-signature function param infers from the source's
            // LAST call signature (the overload picked for the most-general
            // shape). Extract it and fall through to the function inference.
            if (s.kind(ra) == .object) {
                const ncall = s.objectCallSigCount(ra);
                if (ncall == 0) return;
                ra = s.objectCallSig(ra, ncall - 1);
            }
            if (s.kind(ra) != .function) return;
            // A *generic function value* passed where a function is
            // expected (`.then(getProjectTransform)`): first instantiate
            // its own type params from the expected parameter types
            // (tsc's contextual signature instantiation), so its return
            // contributes `ProjectResponse`, not a foreign free `T`.
            const own = s.fnTypeParams(ra);
            if (own.len > 0) {
                const own_syms = try c.scratch().dupe(u32, own);
                const own_cands = try c.scratch().alloc(TypeId, own.len);
                for (own_cands) |*v| v.* = types.no_type;
                const np = @min(s.fnParamCount(param), s.fnParamCount(ra));
                for (0..np) |i| {
                    // Reversed roles: the arg's param types are the pattern,
                    // the expected param types the source.
                    try c.unify(s.fnParam(ra, @intCast(i)).ty, s.fnParam(param, @intCast(i)).ty, own_syms, own_cands, depth + 1);
                }
                var map_list: std.ArrayList(TpMap) = .empty;
                defer map_list.deinit(c.scratch());
                var all_unbound = true;
                var erased_self = false;
                for (own_syms, own_cands) |sym, cand0| {
                    // A candidate that IS one of the parameters this call is
                    // still solving carries no information: it would leave
                    // the argument's signature mentioning the very variable
                    // being inferred, and since parameters are contravariant
                    // that self-candidate then outranks the real covariant
                    // evidence and the signature stays uninstantiated. tsc
                    // erases a generic argument signature's own parameters
                    // to their base constraints (`getBaseSignature`) before
                    // inferring from it, which is what the fallback does.
                    const self_ref = cand0 != types.no_type and
                        s.kind(cand0) == .type_param and
                        tpIndex(tp_syms, s.typeParamSymbol(cand0)) != null;
                    if (self_ref) erased_self = true;
                    const cand = if (self_ref) types.no_type else cand0;
                    if (cand != types.no_type) all_unbound = false;
                    const v = if (cand != types.no_type) cand else try c.typeParamFallback(sym);
                    try map_list.append(c.scratch(), .{ .sym = sym, .ty = v });
                }
                // Only substitute when something was actually inferred —
                // an unbound-everything map would erase params to their
                // fallbacks and *lose* inference the caller could still do.
                // An erased self-reference counts: leaving the argument's
                // own parameter free is exactly the case that misinfers.
                if (!all_unbound or erased_self) {
                    ra = try c.instantiate(ra, map_list.items);
                    if (s.kind(ra) != .function) return;
                }
            }
            // A trailing rest param in the *pattern* (`(...args: T)` with
            // `T extends any[]` — the `debounce`/`withBatchedUpdates`
            // wrapper shape) must bind `T` to the TUPLE of ALL residual
            // source params, not 1:1 onto the single source param sitting
            // in that slot. The positional loop below made `T` a candidate
            // of the FIRST residual param's type, so every later argument
            // was then checked against it. Same rule as the conditional
            // `infer` path (`inferFromExtends`, the `pat_has_rest` block),
            // mirroring tsc's `inferFromParameters` + `getRestTypeAtPosition`.
            const pat_count = s.fnParamCount(param);
            const src_count = s.fnParamCount(ra);
            const pat_has_rest = pat_count != 0 and s.fnParam(param, pat_count - 1).rest();
            const pat_fixed = if (pat_has_rest) pat_count - 1 else pat_count;
            const n = @min(src_count, pat_fixed);
            {
                // Parameters are a contravariant position — unless the
                // signature was written as a METHOD, whose parameters tsc
                // relates bivariantly and infers from covariantly.
                const bivariant = s.fnFlags(param) & types.fn_flag_method != 0;
                if (!bivariant) c.contra_pos += 1;
                defer if (!bivariant) {
                    c.contra_pos -= 1;
                };
                for (0..n) |i| {
                    try c.unify(s.fnParam(param, @intCast(i)).ty, s.fnParam(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
                }
                if (pat_has_rest and src_count >= pat_fixed) {
                    const rest_pat = s.fnParam(param, pat_count - 1).ty;
                    // tsc's `getRestTypeAtPosition` shortcut: when the
                    // residual is exactly the source's own trailing rest
                    // param, hand over its array type unchanged rather than
                    // wrapping it in a one-element tuple.
                    if (src_count == pat_fixed + 1 and s.fnParam(ra, src_count - 1).rest()) {
                        try c.unify(rest_pat, s.fnParam(ra, src_count - 1).ty, tp_syms, candidates, depth + 1);
                    } else {
                        var elems: std.ArrayList(types.TupleElem) = .empty;
                        defer elems.deinit(c.scratch());
                        var i: u32 = pat_fixed;
                        while (i < src_count) : (i += 1) {
                            const sp = s.fnParam(ra, i);
                            var eflags: u32 = 0;
                            if (sp.rest()) eflags |= types.elem_flag_rest;
                            if (sp.optional()) eflags |= types.elem_flag_optional;
                            try elems.append(c.scratch(), .{ .ty = sp.ty, .flags = eflags });
                        }
                        try c.unify(rest_pat, try s.makeTuple(elems.items), tp_syms, candidates, depth + 1);
                    }
                }
            }
            try c.unify(s.fnReturn(param), s.fnReturn(ra), tp_syms, candidates, depth + 1);
            // Infer type params from the *predicate guard* too:
            // `filter<S extends T>(p: (x: T) => x is S)` gets `S` from an
            // argument `(x): x is number`. Only plain guards (not
            // `asserts`) with concrete guard types on both sides.
            if (s.fnHasPredicate(param) and s.fnHasPredicate(ra)) {
                const pp = s.fnPredicate(param);
                const ap = s.fnPredicate(ra);
                if (!pp.asserts and !ap.asserts and pp.ty != 0 and ap.ty != 0)
                    try c.unify(pp.ty, ap.ty, tp_syms, candidates, depth + 1);
            }
        },
        .ref => {
            const ra = try c.resolveStructural(arg);
            if (s.kind(arg) == .ref and s.refSymbol(arg) == s.refSymbol(param)) {
                const pa = try c.scratch().dupe(TypeId, s.refArgs(param));
                const aa = try c.scratch().dupe(TypeId, s.refArgs(arg));
                const n = @min(pa.len, aa.len);
                for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                return;
            }
            // A union argument paired against a named-type param: match the
            // union member sharing the param's symbol and infer from *that*
            // member's type args (tsc's `inferFromTypes` pairs union members
            // by identity before falling back to structural inference).
            // Crux of `Array.from(map.values())` element recovery: the
            // iterator's `next(): IteratorResult<T, TReturn>` return is the
            // union alias `IteratorYieldResult<T> | IteratorReturnResult<
            // TReturn>`; without identity pairing, unifying `IteratorYield
            // Result<T>` against that union falls to the structural arm
            // (object-vs-union) and binds nothing, collapsing the element
            // to `unknown`.
            const uni: TypeId = if (s.kind(arg) == .union_type) arg else if (s.kind(ra) == .union_type) ra else 0;
            if (uni != 0) {
                var matched = false;
                for (try c.memberList(uni)) |am| {
                    if (s.kind(am) == .ref and s.refSymbol(am) == s.refSymbol(param)) {
                        try c.unify(param, am, tp_syms, candidates, depth + 1);
                        matched = true;
                    }
                }
                if (matched) return;
            }
            try c.unify(try c.resolveStructural(param), ra, tp_syms, candidates, depth + 1);
        },
        .conditional => {
            // A generic conditional target (`ReducersMapObject<S> = keyof P
            // extends keyof S ? { [K in keyof S]: … } : never`) carries its
            // inference positions in the branches. tsc's `inferFromTypes`
            // recurses into both; the `: never` false branch contributes
            // nothing, while the true branch reaches the reverse-mapped
            // inference below. This is how `configureStore({ reducer: {…} })`
            // recovers `S` from the object-literal reducer map.
            try c.unify(s.condTrue(param), arg, tp_syms, candidates, depth + 1);
            try c.unify(s.condFalse(param), arg, tp_syms, candidates, depth + 1);
        },
        .intersection => {
            // A branded alias — `LineSegment<P> = [P, P] & { _brand: … }`,
            // the shape excalidraw's geometry layer is built out of —
            // materializes to an INTERSECTION, so it is the *parameter*
            // (here: the signature's return type, matched against the call's
            // contextual type) that is an intersection. There was no arm for
            // that, so the inference was thrown away and `P` fell back to its
            // whole `GlobalPoint | LocalPoint` constraint.
            //
            // tsc's `inferFromTypes` pairs the constituents that match and
            // infers through each pair. Same-generic origins pair
            // positionally first (the `.object` arm's rule, which the
            // intersection origin tag exists for); otherwise a parameter
            // constituent infers only from an argument constituent of the
            // same structural kind — a brand object never pairs with the
            // tuple that carries the type variable.
            const ra = try c.resolveStructural(arg);
            if (c.origin.get(param)) |po| {
                if (c.origin.get(ra)) |ao| {
                    if (s.kind(po) == .ref and s.kind(ao) == .ref and
                        s.refSymbol(po) == s.refSymbol(ao))
                    {
                        const pa = try c.scratch().dupe(TypeId, s.refArgs(po));
                        const aa = try c.scratch().dupe(TypeId, s.refArgs(ao));
                        const n = @min(pa.len, aa.len);
                        for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                        return;
                    }
                }
            }
            const ams: []const TypeId = if (s.kind(ra) == .intersection)
                try c.memberList(ra)
            else
                try c.scratch().dupe(TypeId, &.{ra});
            // Scanned before any re-entry: `memberList` hands out a
            // borrowed slice, and the pairing pass below can invalidate it.
            var naked: TypeId = types.no_type;
            var naked_n: usize = 0;
            for (try c.memberList(param)) |pm| {
                if (s.kind(pm) != .type_param) continue;
                if (tpIndex(tp_syms, s.typeParamSymbol(pm)) == null) continue;
                naked = pm;
                naked_n += 1;
            }
            for (try c.memberList(param)) |pm| {
                if (!try c.containsTypeParam(pm)) continue;
                for (ams) |am| {
                    if (try c.intersectionMembersPair(pm, am)) {
                        try c.unify(pm, am, tp_syms, candidates, depth + 1);
                    }
                }
            }
            // tsc's `inferToMultipleTypes` naked-type-variable rule: when
            // the intersection parameter has EXACTLY ONE constituent that
            // is a bare inference variable, the WHOLE source infers to it
            // once the non-variable constituents have been inferred
            // through. This is *not* the constituent pairing the helper
            // above deliberately refuses — nothing gets swallowed, the
            // variable simply receives the argument as written, which is
            // the only reading available when the rest of the intersection
            // is a decoration over that same variable.
            //
            // RTK's `createSlice({ reducers })` types its parameter as
            // `ValidateSliceCaseReducers<S, ACR> = ACR & { [T in keyof
            // ACR]: … }`. Neither constituent paired (a naked variable is
            // no pair, and a mapped parameter never pairs with an object
            // argument), so `ACR` took no candidate at all and fell back to
            // its `SliceCaseReducers<State>` constraint — whose `keyof` is
            // `string`, collapsing `Slice.actions`'
            // `{ [Type in keyof CaseReducers]: … }` to `{}` and rejecting
            // every annotated `slice.actions` binding.
            //
            // tsc skips this path entirely when the source is a union
            // (`inferFromTypes`' `!(source.flags & TypeFlags.Union)`).
            if (naked_n == 1 and s.kind(arg) != .union_type) {
                try c.unify(naked, arg, tp_syms, candidates, depth + 1);
            }
        },
        .mapped => try c.inferReverseMapped(param, arg, tp_syms, candidates, depth),
        else => {},
    }
}

/// The one constituent of the union `uni` that the object parameter's own
/// DISCRIMINANT selects — tsc's `getMatchingUnionConstituentForType`.
///
/// A discriminant is a property of `param` whose type is a single unit
/// literal (`type: "polycurve"`). A constituent qualifies when it agrees on
/// EVERY such property; the answer is that constituent only when exactly
/// one does. Returns null whenever the param has no discriminant or the
/// match is ambiguous, which is what keeps this from degenerating into
/// "infer from every constituent" — a union of sibling object literals
/// with no discriminant would otherwise contribute each of its literal
/// property types as a candidate, and the merged candidate widens to the
/// primitive.
pub fn discriminatedConstituent(c: *Checker, param: TypeId, uni: TypeId) Error!?TypeId {
    const s = &c.ts;
    var have_disc = false;
    var found: TypeId = types.no_type;
    var n_found: usize = 0;
    for (try c.memberList(uni)) |m| {
        const rm = try c.resolveStructural(m);
        if (s.kind(rm) != .object) continue;
        var agrees = true;
        var saw_disc = false;
        for (0..s.objectPropCount(param)) |i| {
            const pp = s.objectProp(param, @intCast(i));
            if (!isUnitLikeKind(s.kind(pp.ty))) continue;
            saw_disc = true;
            const ap = s.objectPropByName(rm, pp.name) orelse {
                agrees = false;
                break;
            };
            if (!try c.isAssignable(pp.ty, ap.ty)) {
                agrees = false;
                break;
            }
        }
        if (saw_disc) have_disc = true;
        if (saw_disc and agrees) {
            found = m;
            n_found += 1;
        }
    }
    if (!have_disc or n_found != 1) return null;
    return found;
}

/// Do an intersection PARAMETER constituent and an argument constituent
/// describe the same part of the value? Only same-kind pairs qualify, so
/// `[P, P] & { _brand: "seg" }` matched against `[GP, GP] & { _brand:
/// "seg" }` infers `P` from the tuple and never from the brand. A naked
/// type-parameter constituent (`T & {}`) is deliberately not a pair: it
/// would swallow whichever constituent came first.
pub fn intersectionMembersPair(c: *Checker, pm: TypeId, am: TypeId) Error!bool {
    const s = &c.ts;
    const rp = try c.resolveStructural(pm);
    const ra = try c.resolveStructural(am);
    const pk = s.kind(rp);
    if (pk != s.kind(ra)) return false;
    return switch (pk) {
        .object => try c.constituentRelatesTo(rp, ra),
        .tuple, .array, .function, .mapped => true,
        else => false,
    };
}

/// Is intersection constituent `m` a plausible inference source for the
/// object-shaped parameter `param`? True when the two are materializations
/// of the same generic (their origin tags name the same symbol), when `m`
/// carries one of `param`'s own property names, or when both sides agree on
/// callability / an index signature. Everything else — a companion member
/// bolted onto the argument (`WithInitialValue<V>`'s `{ init: V }`, a brand
/// object) — knows nothing about `param`'s type variables, and letting it
/// infer would union a wrong candidate into the right one.
/// Can the union constituent `m` supply an inference for one of `tp_syms`
/// against the object parameter `param`? True only when `m` is an object with
/// a property NAMED by one of the param's own properties whose type mentions a
/// type parameter being inferred — the single pairing that carries
/// information. Deliberately narrower than `constituentRelatesTo`: shared
/// callability or a shared index signature makes any two builder interfaces
/// look related without either one saying anything about a type parameter,
/// and on a kysely-shaped corpus that is most of the union.
pub fn constituentCarriesInference(c: *Checker, param: TypeId, m: TypeId, tp_syms: []const u32) Error!bool {
    const s = &c.ts;
    if (s.objectPropCount(param) == 0) return false;
    const rm = try c.resolveStructural(m);
    if (s.kind(rm) != .object or s.objectPropCount(rm) == 0) return false;
    for (0..s.objectPropCount(param)) |i| {
        const pp = s.objectProp(param, @intCast(i));
        if (s.objectPropByName(rm, pp.name) == null) continue;
        if (try mentionsAnyTypeParam(c, pp.ty, tp_syms)) return true;
    }
    return false;
}

/// Does `t` mention any of `tp_syms` within a shallow walk? A conservative
/// screen for `constituentCarriesInference` — the deeper the occurrence, the
/// less a structural pairing can invert it, and a false negative only leaves
/// the prior behaviour.
fn mentionsAnyTypeParam(c: *Checker, t: TypeId, tp_syms: []const u32) Error!bool {
    return mentionsAnyTypeParamAt(c, t, tp_syms, 0);
}

fn mentionsAnyTypeParamAt(c: *Checker, t: TypeId, tp_syms: []const u32, depth: u32) Error!bool {
    if (depth > 3) return false;
    const s = &c.ts;
    switch (s.kind(t)) {
        .type_param => return tpIndex(tp_syms, s.typeParamSymbol(t)) != null,
        .array => return mentionsAnyTypeParamAt(c, s.arrayElem(t), tp_syms, depth + 1),
        .union_type, .intersection => {
            const ms = try c.scratch().dupe(TypeId, try c.memberList(t));
            defer c.scratch().free(ms);
            for (ms) |m| {
                if (try mentionsAnyTypeParamAt(c, m, tp_syms, depth + 1)) return true;
            }
            return false;
        },
        .ref => {
            const args = try c.scratch().dupe(TypeId, s.refArgs(t));
            defer c.scratch().free(args);
            for (args) |a| {
                if (try mentionsAnyTypeParamAt(c, a, tp_syms, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn constituentRelatesTo(c: *Checker, param: TypeId, m: TypeId) Error!bool {
    const s = &c.ts;
    const rm = try c.resolveStructural(m);
    if (s.kind(rm) == .function) return s.objectCallSigCount(param) > 0;
    if (s.kind(rm) != .object) return false;
    if (c.origin.get(param)) |po| {
        if (c.origin.get(rm)) |ao| {
            if (s.kind(po) == .ref and s.kind(ao) == .ref and
                s.refSymbol(po) == s.refSymbol(ao)) return true;
        }
    }
    for (0..s.objectPropCount(param)) |i| {
        if (s.objectPropByName(rm, s.objectProp(param, @intCast(i)).name) != null) return true;
    }
    if (s.objectCallSigCount(param) > 0 and s.objectCallSigCount(rm) > 0) return true;
    if (s.objectConstructSigCount(param) > 0 and s.objectConstructSigCount(rm) > 0) return true;
    if (s.objectStringIndex(param) != 0 and s.objectStringIndex(rm) != 0) return true;
    if (s.objectNumberIndex(param) != 0 and s.objectNumberIndex(rm) != 0) return true;
    return false;
}

/// Reverse-mapped-type inference (tsc's `inferReverseMappedType`): infer the
/// source `S` of a HOMOMORPHIC mapped target `{ [K in keyof S]: F<S[K]> }`
/// from an object-literal argument. For each source property `k`, infer the
/// element `S[k]` by matching the argument's `k`-typed property against the
/// value template with `S[K]` replaced by a fresh element variable, then
/// reassemble `S` as `{ k: inferred, … }`. Deliberately conservative — bails
/// (leaving prior behavior) on any non-vanilla shape (`as`-clause rename,
/// non-`keyof` constraint, a source that isn't a bare inference-target type
/// param, a non-object argument) so it can only ADD inferences where the
/// param would otherwise stay unbound.
pub fn inferReverseMapped(c: *Checker, m: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
    const s = &c.ts;
    // Same generic ALIAS on both sides (tsc's `inferFromTypes`: "source and
    // target are types originating in the same generic type alias
    // declaration — simply infer from source type arguments to target type
    // arguments"). It sits ABOVE the reverse-mapping rule in tsc for a
    // reason: rebuilding `P` out of `WeakValidationMap<P>`'s members is a
    // strictly worse answer than reading it off the alias, and the rebuild
    // loses whatever the template could not invert. `FunctionComponent<P>`'s
    // `propTypes?: WeakValidationMap<P>` against a `ProviderExoticComponent`
    // argument's `propTypes?: WeakValidationMap<ProviderProps<T>>` inferred
    // a rebuilt `{ children: …; value: … }` with every property REQUIRED
    // (the map adds `?`, so the inversion drops it), and that covariant
    // candidate then beat the call signature's contravariant `ProviderProps<T>`
    // — `React.createElement(Ctx.Provider, { value })` became TS2769.
    if (c.origin.get(m)) |po| {
        if (s.kind(po) == .ref) {
            const ao_opt = c.origin.get(arg) orelse c.origin.get(try c.resolveStructural(arg));
            if (ao_opt) |ao| {
                if (s.kind(ao) == .ref and s.refSymbol(ao) == s.refSymbol(po)) {
                    const pa = try c.scratch().dupe(TypeId, s.refArgs(po));
                    defer c.scratch().free(pa);
                    const aa = try c.scratch().dupe(TypeId, s.refArgs(ao));
                    defer c.scratch().free(aa);
                    const n = @min(pa.len, aa.len);
                    // Same priority as the rebuild this replaces: a DIRECT
                    // structural match elsewhere in the call still wins
                    // (`inference/084`, where `calculate(prev, next,
                    // postProcess)` must answer the `S` its first two
                    // arguments supply, not the `Observed` that
                    // `postProcess`'s erased `Partial<Observed>` names).
                    c.rev_prio += 1;
                    defer c.rev_prio -= 1;
                    for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                    return;
                }
            }
        }
    }
    if (s.mappedAs(m) != 0) return; // no key remap
    // `{ [P in K]: … }` with `K` itself an inference target (`Pick<S, K>`):
    // the key set is what the argument tells us. Handled separately below.
    if (!s.mappedHomomorphic(m)) return c.inferMappedKeySet(m, arg, tp_syms, candidates);
    const src = s.mappedSource(m);
    if (s.kind(src) != .type_param) return; // source must be a bare param
    const src_sym = s.typeParamSymbol(src);
    const idx = tpIndex(tp_syms, src_sym) orelse return; // …that we're inferring
    const ra = try c.resolveStructural(arg);
    // Mapped against mapped (tsc's `inferFromObjectTypes` rule for two
    // generic mapped types: infer constraint from constraint). A DEFERRED
    // `Partial<T>` argument has no members to reverse-map, but it does name
    // its own source: `Delta.create(deleted, inserted)` with both arguments
    // typed `Partial<T>` must infer `create`'s own `T2 = T`, not leave it
    // unbound and fall to `unknown`. Homomorphic on both sides only — the
    // `Pick<S, K>`-shaped argument goes through `inferMappedKeySet`.
    if (s.kind(ra) == .mapped and s.mappedAs(ra) == 0 and s.mappedHomomorphic(ra)) {
        return c.unify(src, s.mappedSource(ra), tp_syms, candidates, depth + 1);
    }
    if (s.kind(ra) != .object) return;
    const key_param = s.mappedKeyParam(m);
    const key_id = s.mappedParamId(key_param);
    const value = s.mappedValue(m);
    // Element inference variable standing in for `S[K]` throughout the value
    // template. A single fresh var suffices — the template is the same for
    // every key, only the matched argument property differs.
    const fp_sym = try c.mintReverseElemVar(s.mappedParamName(key_param));
    const fp_ty = try s.makeTypeParam(fp_sym);
    const template = try c.substElemAccess(value, src_sym, key_id, fp_ty, 0);
    // Modifier inversion (tsc's `resolveReverseMappedTypeMembers`): the
    // reverse-mapped property keeps the ARGUMENT's `?`/`readonly` except
    // where the mapping itself *added* that modifier — a modifier the map
    // adds carries no information about the source, so it is masked off.
    // `Readonly<P>` (adds `readonly`) therefore keeps the argument's
    // optionality and drops its readonly-ness; `Partial<P>` (adds `?`)
    // keeps readonly and drops optionality; a plain `{ [K in keyof S]: … }`
    // keeps both. Dropping the optional flag unconditionally (the previous
    // behavior) made every prop of the inferred `P` REQUIRED, so
    // `memo(Base, areEqual)` — whose comparator parameter is `Readonly<P>`
    // — turned an all-optional props type into an all-required one and
    // every use of the memoized component reported TS2739/TS2741.
    const mflags = s.mappedFlags(m);
    var keep_mask: u32 = types.prop_flag_optional | types.prop_flag_readonly;
    if (mflags & types.mapped_flag_optional_add != 0) keep_mask &= ~types.prop_flag_optional;
    if (mflags & types.mapped_flag_readonly_add != 0) keep_mask &= ~types.prop_flag_readonly;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    const local_syms = [_]u32{fp_sym};
    for (0..s.objectPropCount(ra)) |i| {
        const p = s.objectProp(ra, @intCast(i));
        var elem = [_]TypeId{types.no_type};
        try c.unify(template, p.ty, &local_syms, &elem, depth + 1);
        // The inferred element is `S[k]`, which can never legitimately BE
        // `S` itself. A bare `S` appearing in the candidate is a
        // contextual-feedback artifact (the object literal was
        // contextually typed with a partially-resolved `S`, injecting it
        // into the reducer's `state:` parameter); strip it so the inferred
        // state is the reducer's own state, not a self-referential union.
        const et = try c.stripSourceParam(if (elem[0] != types.no_type) elem[0] else types.unknown_type, src_sym);
        try props.append(c.scratch(), .{ .name = p.name, .ty = et, .flags = p.flags & keep_mask });
    }
    if (props.items.len == 0) return;
    const obj = try c.objectFromProps(props.items, 0, 0);
    // A reverse-mapped object found in a PARAMETER position is
    // contravariant evidence, exactly like the `.type_param` arm's
    // candidate. Writing it into the covariant accumulator let a callback
    // parameter's rebuilt shape displace the type the call actually
    // produces — `calculate(prev, next, postProcess)` took the erased
    // `{ tag: string }` from `postProcess`'s `Partial<T>` over the `S` its
    // first two arguments supply.
    if (c.contraSlot(candidates, idx)) |slot| {
        slot.* = if (slot.* == types.no_type) obj else try c.combineContravariant(slot.*, obj);
        return;
    }
    // The reverse-mapped object is the authoritative inference for a
    // homomorphic mapped target; it wins over an uninformative `any` that a
    // sibling union member (`Reducer<S, A, P>`) may have bound first.
    if (candidates[idx] == types.no_type or candidates[idx] == types.any_type) {
        candidates[idx] = obj;
        if (c.revSlot(candidates, idx)) |rf| rf.* = true;
        return;
    }
    // A DIRECT structural candidate already answered for this parameter.
    // tsc gives a reverse-mapped inference `InferencePriority.
    // HomomorphicMappedType` and keeps only the best-priority candidates,
    // so this one is discarded outright — `updateObject<T extends
    // Record<string, any>>(obj: T, updates: Partial<T>)` must answer the
    // `T` its FIRST argument supplies, not a union of that with the
    // rebuilt `{ docked: boolean | undefined; … }` of its second.
    if (c.revSlot(candidates, idx)) |rf| {
        if (!rf.*) return;
    }
    // Two genuine candidates for the same parameter. tsc resolves a
    // covariant inference set with `getCommonSupertype`, never a union, and
    // gives a reverse-mapped candidate a WORSE `InferencePriority` than a
    // plain structural match — so a direct match's candidate is kept and the
    // reverse-mapped one discarded. Approximate that by collapsing to
    // whichever candidate subsumes the other (preferring the incumbent when
    // they are mutually assignable, since it is the one a nominal alias came
    // through), and union only genuinely unrelated candidates.
    //
    // Unioning here is not merely imprecise, it is lossy: `memo(Base,
    // areEqual)` infers `P` twice — once from `FunctionComponent<P>`'s call
    // signature (giving the props ALIAS) and once from the comparator's
    // `Readonly<P>` (giving a structurally equal rebuild) — and the union of
    // the two is a type whose properties nothing can look up, so every
    // contextual type derived from the memoized component's props
    // disappeared.
    if (try c.isAssignable(obj, candidates[idx])) return;
    // A TYPE-VARIABLE incumbent is always a direct match — an argument was
    // literally of that type — and every rebuild of a constraint-shaped
    // object strictly subsumes it, so the subsumption approximation gets
    // this one case backwards. `calculate(prev, next, postProcess)` would
    // answer `postProcess`'s erased `{ tag: string }` instead of the `S`
    // that `prev` supplies. Priority, not subsumption, decides here.
    if (s.kind(candidates[idx]) == .type_param) return;
    if (try c.isAssignable(candidates[idx], obj)) {
        candidates[idx] = obj;
        return;
    }
    candidates[idx] = try c.makeUnion2(candidates[idx], obj);
}

/// Key-set inference into a NON-homomorphic mapped target whose constraint is
/// a bare type parameter we are inferring — tsc's `inferToMappedType`
/// TypeParameter branch: "We're inferring from some source type S to a mapped
/// type `{ [P in K]: X }`, where K is a type parameter. First infer from
/// `keyof S` to K." This is the `Pick<S, K>` shape, and the reason
/// `this.setState({ a: 1 })` type-checks: `setState<K extends keyof S>(state:
/// Pick<S, K> | S | null)` recovers `K = "a"` from the argument's own keys.
/// Without it `K` stayed unbound, fell back to its `keyof S` constraint, and
/// `Pick<S, keyof S>` — the FULL state — rejected every partial update
/// (TS2345).
///
/// Deliberately narrow: the argument must be an object (so `keyof` is its
/// literal key union, never a primitive's approximated member set) and the
/// constraint must be a bare in-scope param. tsc's further fallbacks (recurse
/// into K's own constraint, then infer the source's property-type union into
/// the value template) are not implemented — they can only add inferences,
/// and the `Pick` shape needs neither.
pub fn inferMappedKeySet(c: *Checker, m: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId) Error!void {
    const s = &c.ts;
    const con = s.mappedConstraint(m);
    if (s.kind(con) != .type_param) return;
    const ki = tpIndex(tp_syms, s.typeParamSymbol(con)) orelse return;
    const ra = try c.resolveStructural(arg);
    // An EMPTY object argument is informative, not a miss: `Pick<S, K>` with
    // no keys means `K = never` (`Pick<S, never>` = `{}`), which is what tsc
    // infers for `setState({})`. Bailing out left `K` to its `keyof S`
    // constraint, so the target became the whole state and `{}` failed with
    // every property reported missing.
    //
    // A DEFERRED MAPPED argument has no members to take `keyof` of, but it
    // does carry its own key set: forwarding an already-`Pick<S, K2>`-typed
    // value into `setState` must infer `K = K2` rather than leave `K` at its
    // constraint. tsc reaches the same place through `inferFromTypes`'
    // mapped-to-mapped rule (infer the source's constraint into the
    // target's).
    // tsc's `inferToMappedType` runs `getIndexType(source)` for ANY source,
    // not just an object. A FUNCTION source (an updater arrow with no
    // return statement) and a UNION source (a forwarded `state` parameter,
    // whose key set is the intersection of its members') both come out
    // `never`, so `Pick<S, never>` is `{}` and the argument is trivially
    // assignable. Returning silently instead left `K` to its `keyof S`
    // constraint, making the target the FULL state and rejecting every
    // forwarded or void-returning update.
    //
    // A PRIMITIVE source is excluded: its key set is its apparent type's
    // members, which are not modelled here, so `keyofType` would answer a
    // spurious `never` — and unlike the real answer, `never` satisfies
    // `K extends keyof S`, silently accepting `setState(123)`.
    switch (s.kind(ra)) {
        .object, .mapped, .union_type, .intersection, .function, .overloads, .class_value, .type_param, .index_access, .conditional, .keyof_op, .infer_var, .this_type => {},
        else => return,
    }
    const keys = switch (s.kind(ra)) {
        .mapped => if (s.mappedAs(ra) == 0) try c.mappedKeySet(ra) else return,
        // A source union that CONTAINS a mapped type of the same shape pairs
        // with the mapped target constituent-wise, and that constituent's
        // key set is the inference — tsc's `inferFromTypes` matches union
        // constituents to each other before inferring, so `Pick<S, K2>`
        // inside the source lands on `Pick<S, K>` in the target and gives
        // `K = K2`. Taking `keyof` of the WHOLE union instead intersects
        // every member's key set, and a member with no enumerable keys (the
        // updater callback of a forwarded `setState`) turns that into a
        // symbolic `K2 & keyof (…)`, which does not satisfy `K extends
        // keyof S` — so `K` fell back to its constraint, the target became
        // the FULL state, and every forwarded update was rejected.
        //
        // Only when such a constituent is there: a union with no mapped
        // member keeps the whole-union key set, which is what makes a
        // void-returning or `null`-returning updater infer `never`.
        .union_type => blk: {
            var acc: TypeId = types.no_type;
            for (try c.memberList(ra)) |um| {
                const rm = try c.resolveStructural(um);
                if (s.kind(rm) != .mapped or s.mappedAs(rm) != 0) continue;
                const ks = try c.mappedKeySet(rm);
                acc = if (acc == types.no_type) ks else try c.makeUnion2(acc, ks);
            }
            break :blk if (acc != types.no_type) acc else try c.keyofType(ra);
        },
        else => try c.keyofType(ra),
    };
    // A key set is authoritative for its own param: an uninformative `any`
    // bound by a sibling union member (`Pick<S, K> | S | null`, where the
    // whole-`S` member matched first) must not survive next to it.
    candidates[ki] = if (candidates[ki] == types.no_type or candidates[ki] == types.any_type)
        keys
    else
        try c.makeUnion2(candidates[ki], keys);
}

/// Drop bare `type_param` members from a reverse-mapped element inference.
/// The element is `S[k]` — the reducer's concrete state — so any free type
/// param surviving in it is a contextual-feedback artifact (the object
/// literal was contextually typed with a still-unresolved param, injecting
/// it into the reducer's `state:`/`PreloadedState` position). A union sheds
/// those members; a type that IS exactly a bare param degrades to `unknown`.
pub fn stripSourceParam(c: *Checker, t: TypeId, sym: u32) Error!TypeId {
    _ = sym;
    const s = &c.ts;
    if (s.kind(t) == .type_param) return types.unknown_type;
    if (s.kind(t) != .union_type) return t;
    var kept: std.ArrayList(TypeId) = .empty;
    defer kept.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        if (s.kind(m) == .type_param) continue;
        try kept.append(c.scratch(), m);
    }
    if (kept.items.len == 0) return types.unknown_type;
    return s.makeUnion(c.scratch(), kept.items);
}

/// Mint a throwaway element inference variable for `inferReverseMapped`.
/// Reuses the fresh higher-order type-param id pool (ids `>= fresh_tp_base`)
/// so `makeTypeParam` accepts it and name/constraint lookups stay in bounds;
/// the var never escapes into a result (only the concrete inferred element
/// does), so it needs no constraint.
pub fn mintReverseElemVar(c: *Checker, name: Atom) Error!u32 {
    const id = c.fresh_tp_next;
    c.fresh_tp_next += 1;
    try c.fresh_tp_info.append(c.cm(), .{ .name = name, .constraint = types.no_type, .default = types.no_type, .has_default = false });
    return id;
}

/// Replace every `S[K]` (an index access whose object is the type param
/// `src_sym` and whose index is this map's key param `key_id`) with `fp`.
/// A homomorphic mapped value references its source only through `S[K]`, so
/// this yields the per-element template `F<fp>`.
pub fn substElemAccess(c: *Checker, t: TypeId, src_sym: u32, key_id: u32, fp: TypeId, depth: u32) Error!TypeId {
    if (depth > 16) return t;
    const s = &c.ts;
    switch (s.kind(t)) {
        .index_access => {
            const obj = s.indexAccessObj(t);
            const ix = s.indexAccessIndex(t);
            if (s.kind(obj) == .type_param and s.typeParamSymbol(obj) == src_sym and
                s.kind(ix) == .mapped_param and s.mappedParamId(ix) == key_id)
            {
                return fp;
            }
            return s.makeIndexAccess(try c.substElemAccess(obj, src_sym, key_id, fp, depth + 1), try c.substElemAccess(ix, src_sym, key_id, fp, depth + 1));
        },
        .array => return s.makeArrayLike(t, try c.substElemAccess(s.arrayElem(t), src_sym, key_id, fp, depth + 1)),
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |mm| try parts.append(c.scratch(), try c.substElemAccess(mm, src_sym, key_id, fp, depth + 1));
            return s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |mm| try parts.append(c.scratch(), try c.substElemAccess(mm, src_sym, key_id, fp, depth + 1));
            return s.makeIntersection(c.scratch(), parts.items);
        },
        .tuple => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try c.substElemAccess(e.ty, src_sym, key_id, fp, depth + 1), .flags = e.flags });
            }
            return s.makeTuple(elems.items);
        },
        .object => {
            var oprops: std.ArrayList(types.Prop) = .empty;
            defer oprops.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try oprops.append(c.scratch(), .{ .name = p.name, .ty = try c.substElemAccess(p.ty, src_sym, key_id, fp, depth + 1), .flags = p.flags });
            }
            return s.makeObject(oprops.items, 0, 0, 0);
        },
        .function => {
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substElemAccess(p.ty, src_sym, key_id, fp, depth + 1), .flags = p.flags });
            }
            const ret = try c.substElemAccess(s.fnReturn(t), src_sym, key_id, fp, depth + 1);
            return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, s.fnThisType(t));
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substElemAccess(a, src_sym, key_id, fp, depth + 1));
            return s.makeRef(s.refSymbol(t), args.items);
        },
        .conditional => {
            const chk = try c.substElemAccess(s.condCheck(t), src_sym, key_id, fp, depth + 1);
            const ext = try c.substElemAccess(s.condExtends(t), src_sym, key_id, fp, depth + 1);
            const tru = try c.substElemAccess(s.condTrue(t), src_sym, key_id, fp, depth + 1);
            const fls = try c.substElemAccess(s.condFalse(t), src_sym, key_id, fp, depth + 1);
            return s.makeConditional(chk, ext, tru, fls, s.condDistributive(t));
        },
        else => return t,
    }
}

/// Bind `any` to every in-scope type param mentioned in `pattern` (tsc:
/// inference from an `any` source assigns `any` to all inference
/// positions). Structure mirrors `containsTypeParamInner`; depth-capped
/// like `unify` (recursive refs terminate on the cap; re-binding is
/// idempotent since `any | any` folds).
pub fn bindAnyToTypeParams(c: *Checker, pattern: TypeId, tp_syms: []const u32, candidates: []TypeId, depth: u32) Error!void {
    if (depth > 16) return;
    const s = &c.ts;
    switch (s.kind(pattern)) {
        .type_param => {
            if (tpIndex(tp_syms, s.typeParamSymbol(pattern))) |i| {
                candidates[i] = if (candidates[i] == types.no_type)
                    types.any_type
                else
                    try c.makeUnion2(candidates[i], types.any_type);
            }
        },
        .union_type, .intersection, .overloads => {
            for (try c.memberList(pattern)) |m| try c.bindAnyToTypeParams(m, tp_syms, candidates, depth + 1);
        },
        .array => try c.bindAnyToTypeParams(s.arrayElem(pattern), tp_syms, candidates, depth + 1),
        .tuple => {
            for (0..s.tupleLen(pattern)) |i| {
                try c.bindAnyToTypeParams(s.tupleElem(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
            }
        },
        .object => {
            for (0..s.objectPropCount(pattern)) |i| {
                try c.bindAnyToTypeParams(s.objectProp(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
            }
            if (s.objectStringIndex(pattern) != 0) try c.bindAnyToTypeParams(s.objectStringIndex(pattern), tp_syms, candidates, depth + 1);
            if (s.objectNumberIndex(pattern) != 0) try c.bindAnyToTypeParams(s.objectNumberIndex(pattern), tp_syms, candidates, depth + 1);
        },
        .function => {
            for (0..s.fnParamCount(pattern)) |i| {
                try c.bindAnyToTypeParams(s.fnParam(pattern, @intCast(i)).ty, tp_syms, candidates, depth + 1);
            }
            try c.bindAnyToTypeParams(s.fnReturn(pattern), tp_syms, candidates, depth + 1);
        },
        .ref => {
            for (0..s.refArgCount(pattern)) |i| try c.bindAnyToTypeParams(s.refArgAt(pattern, i), tp_syms, candidates, depth + 1);
        },
        else => {},
    }
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
        const ctx_typed = switch (tag) {
            .arrow_fn, .function_expr, .array_literal, .object_literal, .template_expr, .call_expr, .call_expr_targs, .optional_call, .new_expr, .new_expr_bare, .new_expr_targs => true,
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

pub fn checkCallArguments(c: *Checker, node: Node, sig: TypeId, arg_nodes: []const Node, report: bool) Error!void {
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
    var has_spread = false;
    for (arg_nodes) |an| {
        if (an != null_node and c.nodeTag(an) == .spread_element) has_spread = true;
    }
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
        if (nargs < required) {
            if (total == std.math.maxInt(u32)) {
                try c.diagFmt(2555, c.nodeSpan(node), "Expected at least {d} arguments, but got {d}.", .{ required, nargs });
            } else if (required != total) {
                try c.diagFmt(2554, c.nodeSpan(node), "Expected {d}-{d} arguments, but got {d}.", .{ required, total, nargs });
            } else {
                try c.diagFmt(2554, c.nodeSpan(node), "Expected {d} arguments, but got {d}.", .{ required, nargs });
            }
        } else if (nargs > total) {
            if (required != total) {
                try c.diagFmt(2554, c.nodeSpan(node), "Expected {d}-{d} arguments, but got {d}.", .{ required, total, nargs });
            } else {
                try c.diagFmt(2554, c.nodeSpan(node), "Expected {d} arguments, but got {d}.", .{ total, nargs });
            }
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
            if (!try c.elaborateCallbackError(an, at, pt) and
                !try c.elaborateLiteralError(an, at, pt))
            {
                try c.reportNotAssignable(2345, at, pt, c.nodeSpan(an));
            }
            reported_arg = true;
        } else if (report and !reported_arg) {
            // The excess-property check is part of the same walk tsc stops
            // at the first failure, so a later argument's excess property
            // is not reported either.
            const before = c.diags.items.len;
            try c.excessPropertyCheck(an, at, pt);
            if (c.diags.items.len == before and
                try c.freshLiteralUnionMismatch(an, at, pt, 2345, c.nodeSpan(an)))
            {
                reported_arg = true;
            } else if (c.diags.items.len != before) {
                reported_arg = true;
            }
        }
    }
    if (report and !reported_arg and rest_union != null) {
        const rest_ty = rest_union.?;
        const packed_ty = try c.ts.makeTuple(packed_elems.items);
        if (!try c.isAssignable(packed_ty, rest_ty)) {
            // tsc's error node: the single rest argument, or the range from
            // the first to the last of them; with none at all, the call.
            const span = if (packed_first != null_node) c.nodeSpan(packed_first) else c.nodeSpan(node);
            try c.reportNotAssignable(2345, packed_ty, rest_ty, span);
        }
    }
}
