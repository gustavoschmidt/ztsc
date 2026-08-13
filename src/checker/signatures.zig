//! Signatures and symbol typing: what a declaration's parameters, return
//! type, and symbol resolve to. Functions take the `Checker` context as
//! their first parameter.
//!
//! Two concerns symbol typing drives were split out and are re-exported
//! below so `Checker`'s method aliases keep resolving here:
//! `destructure.zig` (what a binding pattern gives each name) and
//! `modvalue.zig` (the value meaning of a module reference).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const libs = @import("../libs.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const RefKey = @import("flow.zig").RefKey;
const checkExprCached = @import("expr.zig").checkExprCached;
const containsTypeParam = @import("enums.zig").containsTypeParam;
const destructure = @import("destructure.zig");
const finalizeInferredReturn = @import("names.zig").finalizeInferredReturn;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const modvalue = @import("modvalue.zig");
const narrowByCondition = @import("flow.zig").narrowByCondition;
const widenLiteral = @import("names.zig").widenLiteral;
const widenReturnMember = @import("names.zig").widenReturnMember;
const widenToContext = @import("names.zig").widenToContext;

// =====================================================================
// signatures
// =====================================================================

/// Build the signature type for a FnProto (function decl/expr, arrow,
/// method, function type). `report_implicit` controls TS7006.
/// `ctx_sig` supplies contextual parameter types (arrow inference).
pub fn signatureOfProto(c: *Checker, node: Node, proto_idx: u32, is_method: bool, report_implicit: bool) Error!TypeId {
    return c.signatureOfProtoCtx(node, proto_idx, is_method, report_implicit, types.no_type);
}

pub fn signatureOfProtoCtx(
    c: *Checker,
    node: Node,
    proto_idx: u32,
    is_method: bool,
    report_implicit: bool,
    ctx_sig: TypeId,
) Error!TypeId {
    if (c.sig_cache.get(c.nodeKey(node))) |cached| {
        if (cached.ctx == ctx_sig) return cached.ty;
    }
    const proto = c.tree.extraData(ast.FnProto, proto_idx);
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    // Type parameters (global symbol ids in the signature type).
    var tps: std.ArrayList(u32) = .empty;
    defer tps.deinit(c.scratch());
    // A signature's own type parameter shadows an enclosing mapped-type key
    // of the same name (tsc lexical scoping): while materializing this
    // sig's params/return, a bare `K` that names an own type param must
    // resolve to that param, not the outer mapped key. Without this, a
    // generic method declared inside a mapped-type value branch (e.g.
    // `addEventListener<K extends keyof ElementEventMap>` materialized while
    // some `{[K in …]: …}` is being expanded) has its own `K` mis-bound to a
    // `mapped_param`, which `containsTypeParam` misses — so `eraseTypeParams`
    // silently no-ops and the sig never relates (order-dependent, since it
    // only triggers when the mapped key happens to be in scope at
    // materialization time). Hidden for the whole body via defer, by pushing
    // a SHADOW entry (`ty == 0`) per colliding name onto the mapped-key
    // stack — only that name is hidden, so an enclosing map's differently
    // named key stays visible to the sig.
    const saved_keys = c.mapped_key_scopes.items.len;
    defer c.mapped_key_scopes.shrinkRetainingCapacity(saved_keys);
    for (c.tree.extraRange(proto.tp_start, proto.tp_end)) |tp| {
        if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
        const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
        if (c.lookupMappedKey(a) != null) {
            try c.mapped_key_scopes.append(c.cm(), .{ .name = a, .ty = 0, .infer_depth = c.infer_scopes.items.len });
        }
        if (c.bind.lookupInScope(c.cur_scope, a)) |tp_sym| {
            try tps.append(c.scratch(), c.toGlobal(tp_sym));
        }
        // Evaluate constraints eagerly so their diagnostics are
        // partition-independent (owners always see them).
        const td = c.tree.nodeData(tp);
        if (td.lhs != 0) _ = try c.typeFromTypeNode(td.lhs);
    }

    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    const param_nodes = c.tree.extraRange(proto.params_start, proto.params_end);
    var pi: u32 = 0;
    // A leading `this` parameter is a receiver *annotation*, not a real
    // parameter: excluded from the param list (so it never counts toward
    // arity) and stored on the signature for the receiver check / body.
    var this_ty: TypeId = 0;
    var seen_param = false;
    for (param_nodes) |pn| {
        if (pn == null_node) continue;
        if (!seen_param) {
            seen_param = true;
            if (thisParamAnn(c, pn)) |ann_node| {
                this_ty = if (ann_node != 0) try c.typeFromTypeNode(ann_node) else types.any_type;
                if (this_ty == types.no_type) this_ty = types.any_type;
                continue;
            }
        }
        const p = try paramInfo(c, pn, pi, ctx_sig, report_implicit);
        // A parameter with an initializer (`x = 'grey'`) is optional at the
        // call site and accepts `undefined` — passing `undefined` triggers
        // the default (tsc's `getTypeOfParameter` adds the optional type).
        // The body symbol, however, keeps the non-undefined type (the
        // default fills the gap), so widen ONLY the signature copy here and
        // leave the body pin below on the original `p.ty`. Explicit `?`
        // params were already unioned with undefined in `paramInfo`.
        var sig_p = p;
        if (p.flags & types.param_flag_initializer != 0 and
            p.flags & types.param_flag_optional == 0)
        {
            sig_p.ty = try c.makeUnion2(p.ty, types.undefined_type);
        }
        try params.append(c.scratch(), sig_p);
        // tsc's `removeOptionalityFromDeclaredType`, the mirror image of the
        // widening just above: inside the BODY a parameter with an
        // initializer never observes `undefined`, because passing
        // `undefined` is exactly what runs the default. So strip it from the
        // declared type here even when the ANNOTATION itself spells it —
        // which an alias routinely does (`ImportedDataState["libraryItems"]`
        // is `readonly LibraryItem[] | undefined`, and `(xs = [])` then still
        // read as possibly-undefined in the body). tsc's one carve-out is an
        // initializer that can itself be `undefined`, which leaves the
        // parameter genuinely undefined-able.
        var body_ty = p.ty;
        if (p.flags & types.param_flag_initializer != 0 and
            p.flags & types.param_flag_optional == 0)
        {
            const stripped = try c.removeUndefined(p.ty);
            if (stripped != p.ty and stripped != types.never_type and
                !try paramInitCanBeUndefined(c, pn))
            {
                body_ty = stripped;
            }
        }
        // Pin the parameter symbol's type so body checking sees the
        // contextual/inferred type (not a re-derivation without ctx). When a
        // contextual signature is supplied (`ctx_sig`), FORCE-overwrite any
        // previously-pinned value: the same arrow is materialized once per
        // overload candidate during resolution (`argumentsMatch` trials), and
        // `setTypeOfSymbol` is first-writer-wins — so a rejected candidate's
        // param types (e.g. reduce's non-generic `(prev:T,cur:T)=>T` pinning
        // `acc:T`) would otherwise freeze and block the SELECTED overload's
        // correct `acc:U` types. The last materialization is the one the body
        // is actually checked under, so it must win.
        if (p.name != 0) {
            if (c.bind.lookupInScope(c.cur_scope, p.name)) |psym| {
                if (c.bind.symbol_flags[psym].param) {
                    const gsym = c.toGlobal(psym);
                    if (ctx_sig != types.no_type and gsym != binder.no_symbol and gsym < c.sym_types.items.len) {
                        c.sym_types.items[gsym] = body_ty;
                        c.sym_state.items[gsym] = .computed;
                        markSpeculativePin(c, gsym);
                    } else {
                        c.setTypeOfSymbol(gsym, body_ty);
                    }
                }
            }
        } else {
            // A DESTRUCTURED parameter (`({ a, b }) => …`) names no symbol,
            // so the pin above never ran and each binding fell back to
            // `computeTypeOfSymbol`, which re-derives the parameter with no
            // contextual signature — i.e. `any` for an unannotated one.
            // Every read of such a binding was therefore unchecked, and the
            // `any` spread outward: a generic call taking one of them
            // inferred its type parameter as `any`, which absorbed the
            // union parameter beside it, so an arrow argument written for
            // that parameter lost its contextual signature and reported
            // TS7006 on every parameter.
            try c.pinPatternParamSyms(pn, c.tree.nodeData(pn).lhs, body_ty, ctx_sig != types.no_type);
        }
        pi += 1;
    }

    const is_async = proto.flags & ast.Flags.async != 0;
    const is_generator = proto.flags & ast.Flags.generator != 0;
    // Contextual return type: the return of the contextual signature this
    // arrow/function expression is checked against (annotation, argument, or
    // property position). Threaded into the body's return-type probe so
    // return expressions are contextually typed. An async body's returns are
    // typed by the *awaited* contextual type (`Promise<T>` context → `T`).
    const ret_ctx: TypeId = if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function)
        c.ts.fnReturn(ctx_sig)
    else
        types.no_type;
    var ret: TypeId = types.any_type;
    var pred: ?types.Predicate = null;
    if (proto.return_type != 0 and c.nodeTag(proto.return_type) == .type_predicate) {
        // `x is T` / `asserts x[ is T]`: a plain guard returns boolean;
        // an assertion function returns void (no value required, so no
        // TS2355). The predicate rides along for call-site narrowing.
        const p = try predicateFromNode(c, proto.return_type, params.items);
        pred = p;
        ret = if (p.asserts) types.void_type else types.boolean_type;
    } else if (proto.return_type != 0 and c.nodeTag(proto.return_type) == .this_expr and
        is_method and c.ts.kind(c.this_type) == .ref)
    {
        // Polymorphic `this` return (`foo(): this`). Kept as a marker so a
        // call through a subclass receiver types as the subclass.
        ret = try c.ts.makeThisType(c.this_type);
        c.has_this_types = true;
    } else if (proto.return_type != 0) {
        ret = try c.typeFromTypeNode(proto.return_type);
    } else if (is_async and !is_generator) {
        // async without annotation → infer the payload from the body
        // (flattening a single returned `Promise` level), wrap in the
        // global `Promise<T>`. `async g() {}` → `Promise<void>`.
        if (node != 0 and c.tree.nodeData(node).rhs != 0 and
            (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr or
                c.nodeTag(node) == .function_decl or c.nodeTag(node) == .class_method))
        {
            try c.sig_cache.put(c.cm(), c.nodeKey(node), .{ .ty = try c.ts.makeFunction(params.items, try c.makePromise(types.any_type), tps.items, if (is_method) types.fn_flag_method else 0), .ctx = ctx_sig });
            const payload = try c.awaitedType(try inferReturnType(c, node, c.tree.nodeData(node).rhs, if (ret_ctx != types.no_type) try c.awaitedType(ret_ctx) else types.no_type));
            ret = try c.makePromise(payload);
        } else {
            ret = try c.makePromise(types.void_type);
        }
    } else if (is_generator) {
        if (!is_async and node != 0 and c.tree.nodeData(node).rhs != 0 and
            (c.nodeTag(node) == .function_expr or c.nodeTag(node) == .function_decl or
                c.nodeTag(node) == .class_method))
        {
            // Reserve the cache slot to break recursion, as the ordinary
            // inferred-return path does.
            try c.sig_cache.put(c.cm(), c.nodeKey(node), .{ .ty = try c.ts.makeFunction(params.items, types.any_type, tps.items, if (is_method) types.fn_flag_method else 0), .ctx = ctx_sig });
            ret = try inferGeneratorReturn(c, node, c.tree.nodeData(node).rhs);
        } else {
            // `async function*` and generator shapes with no body keep the
            // old `any`.
            ret = types.any_type;
        }
    } else if (node != 0 and c.tree.nodeData(node).rhs != 0 and
        (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr or
            c.nodeTag(node) == .function_decl or c.nodeTag(node) == .class_method))
    {
        // Reserve the cache slot to break recursion (self-recursive
        // unannotated functions infer any, TS7023-adjacent).
        try c.sig_cache.put(c.cm(), c.nodeKey(node), .{ .ty = try c.ts.makeFunction(params.items, types.any_type, tps.items, if (is_method) types.fn_flag_method else 0), .ctx = ctx_sig });
        ret = try inferReturnType(c, node, c.tree.nodeData(node).rhs, ret_ctx);
    } else if (proto.flags & (ast.Flags.get) != 0) {
        ret = types.any_type;
    } else if (c.tree.nodeData(node).rhs == 0 and c.nodeTag(node) != .function_type and c.nodeTag(node) != .method_signature) {
        ret = types.any_type; // overload signature without annotation
    }

    // TS 5.5 inferred type predicate: a boolean-returning single-param
    // callback whose body narrows that param synthesizes an implicit
    // `x is T` guard, so `arr.filter(x => x !== null)` picks the
    // `filter<S extends T>(…): S[]` overload. Only when no explicit
    // predicate was written and the param has a real (contextual) type.
    if (pred == null and tps.items.len == 0 and
        (c.nodeTag(node) == .arrow_fn or c.nodeTag(node) == .function_expr))
    {
        pred = try inferredPredicate(c, params.items, ret, c.tree.nodeData(node).rhs);
    }

    const sig = try c.ts.makeFunctionThis(params.items, ret, tps.items, if (is_method) types.fn_flag_method else 0, pred, this_ty);
    try c.sig_cache.put(c.cm(), c.nodeKey(node), .{ .ty = sig, .ctx = ctx_sig });
    return sig;
}

/// TS 5.5 inferred type predicate. Returns an implicit `x is T` guard for a
/// boolean-returning single-parameter arrow/function whose body narrows
/// that parameter, or null (the old under-reporting behavior) when the
/// shape is anything we are not certain about. Conservative on purpose:
/// only equality / `typeof` / `instanceof` / `in` guards (optionally under
/// `!`), gated by tsc's own soundness rule — the true-branch narrowing
/// must differ from the declared type AND the false branch must exclude the
/// narrowed type entirely. That gate rejects truthiness (`!!x`, `x => !!x`)
/// exactly as tsc does: the falsy branch of `number | null` keeps `number`.
fn inferredPredicate(c: *Checker, params: []const types.Param, ret: TypeId, body: Node) Error!?types.Predicate {
    if (body == null_node) return null;
    switch (c.ts.kind(ret)) {
        .boolean, .bool_true, .bool_false => {},
        else => return null,
    }
    if (params.len == 0) return null;

    // The single guard expression: an expression body, or a block whose
    // only statement is `return <expr>`.
    var guard = body;
    if (c.nodeTag(body) == .block) {
        var expr: Node = null_node;
        var count: usize = 0;
        for (c.tree.nodeRange(body)) |st| {
            if (st == null_node) continue;
            count += 1;
            if (c.nodeTag(st) == .return_stmt and c.tree.nodeData(st).lhs != 0) {
                expr = c.tree.nodeData(st).lhs;
            } else return null;
        }
        if (count != 1 or expr == null_node) return null;
        guard = expr;
    }

    // Unwrap parens and leading `!` (each `!` flips the narrowing sense).
    var sense = true;
    unwrap: while (guard != null_node) {
        switch (c.nodeTag(guard)) {
            .paren_expr => guard = c.tree.nodeData(guard).lhs,
            .prefix_unary => {
                if (c.tree.tokens.tag(c.tree.nodeMainToken(guard)) != .bang) break :unwrap;
                sense = !sense;
                guard = c.tree.nodeData(guard).lhs;
            },
            else => break :unwrap,
        }
    }
    if (guard == null_node) return null;
    // Only shapes `narrowByGuardExpr`/`narrowByCondition` handle soundly
    // (a bare identifier is allowed so truthiness reaches — and is
    // rejected by — the gate; calls reach `narrowByGuardCall`, i.e. a
    // callback that merely wraps a user-defined guard).
    switch (c.nodeTag(guard)) {
        .binary, .identifier, .member_expr, .optional_member_expr => {},
        .call_expr, .call_expr_targs, .optional_call => {},
        else => return null,
    }

    // tsc 5.5 narrows one parameter of a possibly multi-parameter callback
    // (`arr.filter((x, i) => x !== null)` guards `x`; `i` is untouched).
    // Try each parameter; synthesize only when *exactly one* passes the
    // gate — an ambiguous guard (two params both narrowed) has no clear
    // oracle semantics, so it keeps the old (no-predicate) behavior.
    var found: ?types.Predicate = null;
    for (params, 0..) |p, pi| {
        if (p.name == 0) continue;
        const declared = p.ty;
        if (!c.isNarrowable(declared)) continue;
        // The guarded parameter's symbol, resolved exactly as `identIsSym`
        // will resolve the references inside the body.
        const psym: SymbolId = switch (c.resolveSpace(p.name, c.cur_scope, true)) {
            .sym => |s| s,
            else => continue,
        };
        const key = RefKey{ .sym = psym };
        const true_ty = try narrowByGuardExpr(c, declared, guard, sense, key, 0, declared);
        if (true_ty == declared or c.ts.kind(true_ty) == .never) continue;
        // Soundness, exactly as `checkIfExpressionRefinesParameter` states it:
        //
        //     const falseSubtype = getFlowTypeOfReference(
        //         param.name, initType, trueType, func, falseCondition);
        //     return falseSubtype.flags & TypeFlags.Never ? trueType : undefined;
        //
        // The false condition narrows the TRUE TYPE (with the parameter's
        // declared type still the declared type) and must reach `never`. ztsc
        // narrowed the DECLARED type instead and rejected on any overlap with
        // `true_ty`, which is a strictly stronger test and fails whenever the
        // declared union has a constituent that is a SUPERTYPE of the narrowed
        // type: `@atproto/api`'s `Preferences` ends in a bare `{$type: string}`,
        // which survives the false branch and is trivially overlapped by
        // `Preferences & LiveEventPreferences`, so `updated.find(p =>
        // asPredicate(validate…)(p))` got no predicate at all and `find` fell to
        // its non-guard overload — TS2339 on the result and TS2322 on the
        // enclosing `mutationFn`.
        const false_ty = try narrowByGuardExpr(c, true_ty, guard, !sense, key, 0, declared);
        if (c.ts.kind(false_ty) != .never) continue;
        if (found != null) return null; // ambiguous: two params narrowed
        found = types.Predicate{ .param = @intCast(pi), .ty = true_ty, .asserts = false };
    }
    return found;
}

/// Narrow `t` by a *guard expression* for inferred-predicate synthesis
/// only. Unlike flow narrowing (where the binder decomposes `&&`/`||`/`!`
/// into branch conditions), the whole callback body is one expression
/// here, so the logical operators are recursed structurally with the
/// exact branch semantics tsc's flow analysis produces:
///   true(A && B)  = true(B) over true(A)
///   false(A && B) = false(A) | false(B) over true(A)
/// (and the De Morgan dual for `||`). Leaves delegate to
/// `narrowByCondition`; unhandled shapes return `t`, which the caller's
/// `true_ty == declared` gate then rejects (no predicate — old behavior).
fn narrowByGuardExpr(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey, depth: u32, decl: TypeId) Error!TypeId {
    if (cond == null_node or depth > 8) return t;
    const d = c.tree.nodeData(cond);
    switch (c.nodeTag(cond)) {
        .paren_expr => return narrowByGuardExpr(c, t, d.lhs, sense, key, depth + 1, decl),
        .prefix_unary => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(cond)) != .bang)
                return t;
            return narrowByGuardExpr(c, t, d.lhs, !sense, key, depth + 1, decl);
        },
        .binary => switch (c.tree.tokens.tag(c.tree.nodeMainToken(cond))) {
            .amp_amp => {
                const a_true = try narrowByGuardExpr(c, t, d.lhs, true, key, depth + 1, decl);
                if (sense) return narrowByGuardExpr(c, a_true, d.rhs, true, key, depth + 1, decl);
                const a_false = try narrowByGuardExpr(c, t, d.lhs, false, key, depth + 1, decl);
                const b_false = try narrowByGuardExpr(c, a_true, d.rhs, false, key, depth + 1, decl);
                return c.makeUnion2(a_false, b_false);
            },
            .pipe_pipe => {
                const a_false = try narrowByGuardExpr(c, t, d.lhs, false, key, depth + 1, decl);
                if (!sense) return narrowByGuardExpr(c, a_false, d.rhs, false, key, depth + 1, decl);
                const a_true = try narrowByGuardExpr(c, t, d.lhs, true, key, depth + 1, decl);
                const b_true = try narrowByGuardExpr(c, a_false, d.rhs, true, key, depth + 1, decl);
                return c.makeUnion2(a_true, b_true);
            },
            else => return c.narrowByCondition(t, cond, sense, key, decl),
        },
        else => return c.narrowByCondition(t, cond, sense, key, decl),
    }
}

/// True when some constituent of `a` is assignable into `b` (a non-empty
/// overlap). Used to reject an inferred predicate whose true and false
/// branches are not disjoint.
pub fn typesOverlap(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (c.ts.kind(a) == .union_type) {
        for (try c.memberList(a)) |m| {
            if (try c.isAssignable(m, b)) return true;
        }
        return false;
    }
    return c.isAssignable(a, b);
}

/// If `pn` is a leading `this` parameter (`this: T`), return its type
/// annotation node (0 when unannotated); otherwise null.
fn thisParamAnn(c: *Checker, pn: Node) ?Node {
    const d = c.tree.nodeData(pn);
    const name_node: Node = switch (c.nodeTag(pn)) {
        .param, .param_full => d.lhs,
        else => pn,
    };
    if (name_node == 0 or c.nodeTag(name_node) != .this_expr) return null;
    return switch (c.nodeTag(pn)) {
        .param => d.rhs,
        .param_full => c.tree.extraData(ast.ParamFull, d.rhs).type_ann,
        else => 0,
    };
}

/// Resolve a `.type_predicate` return-type node into a `Predicate`:
/// map the guarded name to a parameter index and evaluate the target
/// type. `this is T` uses the `this_param` sentinel.
fn predicateFromNode(c: *Checker, node: Node, params: []const types.Param) Error!types.Predicate {
    const d = c.tree.nodeData(node);
    const asserts = d.rhs != 0;
    const target: TypeId = if (d.lhs != 0) try c.typeFromTypeNode(d.lhs) else types.no_type;
    const name_tok = c.tree.nodeMainToken(node);
    var param: u32 = types.Predicate.this_param;
    if (c.tree.tokens.tag(name_tok) != .keyword_this) {
        const a = try c.atomOfToken(name_tok);
        for (params, 0..) |p, i| {
            if (p.name == a) {
                param = @intCast(i);
                break;
            }
        }
    }
    return .{ .param = param, .ty = target, .asserts = asserts };
}

/// tsc's `parameterInitializerContainsUndefined`: can the parameter's
/// default expression itself produce `undefined`? If it can, the parameter
/// really is undefined-able inside the body and
/// `removeOptionalityFromDeclaredType` leaves the declared type alone.
///
/// Run as a side query: it publishes no `node_types` entry and reports no
/// diagnostic, so the authoritative check of the same initializer — which
/// happens later, under the annotation as its contextual type — is
/// unaffected.
fn paramInitCanBeUndefined(c: *Checker, pn: Node) Error!bool {
    if (c.nodeTag(pn) != .param_full) return false;
    const e = c.tree.extraData(ast.ParamFull, c.tree.nodeData(pn).rhs);
    if (e.init == 0) return false;
    c.side_query_depth += 1;
    defer c.side_query_depth -= 1;
    const it = try c.checkExprCached(e.init, types.no_type);
    return (try c.removeUndefined(it)) != it;
}

fn paramInfo(c: *Checker, pn: Node, index: u32, ctx_sig: TypeId, report_implicit: bool) Error!types.Param {
    const d = c.tree.nodeData(pn);
    var name_node: Node = 0;
    var type_ann: Node = 0;
    var init_node: Node = 0;
    var flags_word: u32 = 0;
    switch (c.nodeTag(pn)) {
        .param => {
            name_node = d.lhs;
            type_ann = d.rhs;
        },
        .param_full => {
            const e = c.tree.extraData(ast.ParamFull, d.rhs);
            name_node = d.lhs;
            type_ann = e.type_ann;
            init_node = e.init;
            flags_word = e.flags;
        },
        else => {
            name_node = pn;
        },
    }
    var flags: u32 = 0;
    if (flags_word & ast.Flags.optional != 0) flags |= types.param_flag_optional;
    if (flags_word & ast.Flags.rest != 0) flags |= types.param_flag_rest;
    if (init_node != 0) flags |= types.param_flag_initializer;

    const name: Atom = if (name_node != 0 and c.nodeTag(name_node) == .identifier)
        try c.atomOfToken(c.tree.nodeMainToken(name_node))
    else
        0;

    var ty: TypeId = types.no_type;
    // tsc's `getTypeForVariableLikeDeclaration` order for a PARAMETER: the
    // type annotation, then the CONTEXTUAL parameter type, and only then the
    // initializer. ztsc had the last two the other way round, so a default
    // erased the contextual type it was a default FOR — social-app's
    // `build(params = {})`, written against
    // `build: (params?: Record<string, any>) => string`, typed `params` as
    // `{}` and every `params[name]` was a false TS7053.
    var ctx_ty: TypeId = types.no_type;
    if (type_ann == 0 and ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function) {
        if (try c.paramTypeAt(ctx_sig, index)) |ct| ctx_ty = ct;
    }
    if (type_ann != 0) {
        ty = try c.typeFromTypeNode(type_ann);
    } else if (ctx_ty != types.no_type) {
        // tsc's `removeOptionalityFromDeclaredType`: a parameter WITH an
        // initializer cannot be `undefined` at the point its body reads it,
        // so `undefined` comes off the declared type.
        ty = if (init_node != 0) try c.removeUndefined(ctx_ty) else ctx_ty;
        // The initializer is still checked — for its own diagnostics —
        // against the type it is a default for.
        if (init_node != 0) _ = try c.checkExprCached(init_node, ty);
    } else if (init_node != 0) {
        ty = try c.widenLiteral(try c.checkExprCached(init_node, types.no_type));
        // A parameter whose NAME is an object binding pattern takes its
        // type from the initializer, but each property the pattern
        // destructures WITH A DEFAULT is optional there — the default
        // supplies it, so a caller need not. tsc reaches the same place
        // from the other side: it contextually types the initializer with
        // the pattern's implied type and copies that type's `Optional` flag
        // onto each matching literal property
        // (`checkObjectLiteral`/`contextualTypeHasPattern`). Without it
        // every property of `({ w = 1, h = 2 } = { w: 0, h: 0 })` came out
        // REQUIRED and `f({ w: 5 })` reported TS2345.
        ty = try optionalizePatternDefaults(c, ty, name_node);
    }
    if (ty == types.no_type) {
        // `noImplicitAny: false` suppresses TS7006 — the parameter still
        // types as `any` below, only the diagnostic is gone.
        if (report_implicit and name != 0 and c.prog.no_implicit_any) {
            const tok = c.tree.nodeMainToken(name_node);
            try c.diagFmt(7006, c.tokSpan(tok), "Parameter '{s}' implicitly has an 'any' type.", .{c.tokenText(tok)});
        }
        ty = types.any_type;
    }
    // `x?: T` reads as T | undefined.
    if (flags & types.param_flag_optional != 0) {
        ty = try c.makeUnion2(ty, types.undefined_type);
    }
    return .{ .name = name, .ty = ty, .flags = flags };
}

/// Union of return expression types (widened), plus undefined when the
/// body can complete normally alongside value returns.
///
/// `ret_ctx` is the *contextual return type* — the return type of the
/// contextual signature this function expression/arrow is being checked
/// against (from a variable annotation, argument position, or property
/// position). When present it becomes the contextual type of every return
/// expression, so object literals keep the literal discriminants the
/// context expects (`{ type: 'Polygon' }` under `() => Polygon` keeps
/// `type: "Polygon"` instead of widening to `string`), unions distribute,
/// and nested arrows inherit both param and return context via
/// `checkExprCached` → `checkFunctionLikeExpr`. With no context it is
/// `types.no_type`, and normal widening applies (tsc's
/// isLiteralOfContextualType).
/// tsc's `mayReturnNever`: may a function-like whose body only throws infer
/// `never` rather than `void`? Only an arrow and a function expression — and an
/// object-literal method, which the parser models as an `object_method` holding
/// a `function_expr`, so it is already covered by that arm.
fn mayReturnNever(c: *Checker, fn_node: Node) bool {
    return switch (c.nodeTag(fn_node)) {
        .arrow_fn, .function_expr => true,
        else => false,
    };
}

fn inferReturnType(c: *Checker, fn_node: Node, body: Node, ret_ctx: TypeId) Error!TypeId {
    if (body == 0) return types.any_type;
    // Establish *this* function's async/generator context while checking
    // its body: `await`/`yield` legality (TS1308/TS1163…) must be judged
    // against the function being inferred, not the enclosing one. Without
    // this, an `await` in an async arrow probed for its return type is
    // checked under the outer (possibly non-async) `fn_ctx`, emitting a
    // TS1308 false positive that then caches — and whether this probe or
    // the full `checkFunctionBody` reaches the node first is cache-order
    // dependent, so the error moved across files with --workers/--checkers.
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fn_node).lhs);
    const saved_ctx = c.fn_ctx;
    defer c.fn_ctx = saved_ctx;
    c.fn_ctx = .{
        .ret_ann = types.no_type,
        .is_async = proto.flags & ast.Flags.async != 0,
        .is_generator = proto.flags & ast.Flags.generator != 0,
        .yield_type = 0,
    };
    // …and *this* function's receiver, for exactly the same reason.
    // `checkFunctionBody` installs the explicit `this` parameter's type
    // before walking the body; this probe walks the same expressions and
    // did not, so a `this.x` inside it resolved against the ambient
    // receiver — the enclosing class's instance or static side — and then
    // MEMOIZED that answer in `node_types`, which the real body walk
    // afterwards reads back. The divergence is therefore invisible unless
    // the enclosing class happens to declare the same member name, which
    // is precisely the case for a static helper that forwards to a
    // same-named inherited static.
    //
    // sequelize's `ModelStatic<M>` is that shape:
    //
    // ```ts
    // static createWithCtx<M extends Model>(this: ModelStatic<M>, …) {
    //   return this.create(values, hookContext);   // Model.create<M2>
    // }
    // ```
    //
    // `create` resolved on `typeof Model` instead of on `ModelStatic<M>`,
    // so its own `this: ModelStatic<M2>` was inferred from the class value
    // and `M2` came out as the class's instance type rather than `M`. The
    // helper's inferred return type became a CONCRETE `Promise<Model<any,
    // any>>` — no longer mentioning `M` — so every caller got it, and
    // outline reported 39 `Property 'x' does not exist on type
    // 'Model<any, any>'` keys against it.
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    // Tracked as its own flag, not as `c.this_type != saved_this`: an
    // annotation naming the enclosing class itself (`pinned(this: Base)` inside
    // `class Base`) resolves to the type already there, and it must still count
    // as WRITTEN — it is what pins the receiver against the polymorphic form
    // installed below.
    var this_annotated = false;
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        if (pn == null_node) continue;
        // A `this` annotation is only a receiver annotation in LEADING
        // position, which is where `signatureOfProto` reads it too.
        if (thisParamAnn(c, pn)) |ann_node| {
            this_annotated = true;
            if (ann_node != 0) {
                const tt = try c.typeFromTypeNode(ann_node);
                if (tt != types.no_type) c.this_type = tt;
            }
        }
        break;
    }
    // A class INSTANCE method's receiver is POLYMORPHIC. tsc types the `this`
    // EXPRESSION inside such a method as the class's *this-type* (a marker
    // standing for "whatever the receiver turns out to be"), not as the class's
    // own instance type — so a return type DERIVED from `this` stays
    // parameterized on the receiver and resolves per call site.
    //
    // `signatureOfProtoCtx` already builds that marker for an explicit
    // `foo(): this` annotation. The INFERRED path did not, so a method that
    // merely FORWARDS a `this`-returning one collapsed at its declaration:
    //
    // ```ts
    // save(): Promise<this> { … }
    // saveWithCtx(ctx) { return this.save({ …ctx }); }   // inferred
    // ```
    //
    // came out `Promise<Base>` for every caller instead of `Promise<Sub>`.
    // sequelize's `save(options?): Promise<this>` behind outline's model base
    // class is exactly that, and it cost 15 keys across four files
    // (`server/models/Document.ts:1200` printed the mismatch against `this`
    // verbatim). `return this` and `return { me: this }` are the same bug one
    // step smaller, and both are covered by the fixture.
    //
    // Deliberately narrow:
    //
    //   * an explicit `this` parameter is a written override of the receiver,
    //     and the loop above has already installed it (`this_annotated`);
    //   * a STATIC's receiver is the class VALUE — `this` there is the
    //     constructor, whose polymorphic form ztsc does not model;
    //   * an object-literal method (a `function_expr` here) has no polymorphic
    //     `this` at all, only a contextual `ThisType<T>`;
    //   * the ambient receiver must be the class's instance REFERENCE, the
    //     same guard the explicit-annotation path uses.
    if (!this_annotated and c.nodeTag(fn_node) == .class_method and
        proto.flags & ast.Flags.static == 0 and c.ts.kind(c.this_type) == .ref)
    {
        c.this_type = try c.ts.makeThisType(c.this_type);
        c.has_this_types = true;
    }
    if (c.nodeTag(body) != .block) {
        const raw = try c.checkExprCached(body, ret_ctx);
        if (ret_ctx != types.no_type) return c.widenToContext(raw, ret_ctx);
        return c.finalizeInferredReturn(try c.widenReturnMember(raw));
    }
    // Base scope for the body: a function/arrow body block binds its
    // statements directly in the function scope (no separate block scope),
    // so start from the function's own scope.
    const base_scope = (try c.scopeOf(fn_node)) orelse c.cur_scope;
    var rets = try c.collectReturns(c.tree.nodeRange(body), base_scope);
    defer rets.deinit(c.scratch());
    if (rets.exprs.items.len == 0) {
        // A block body with no `return` at all whose endpoint is
        // UNREACHABLE never produces a value: tsc infers `never`, not
        // `void` (`getReturnTypeFromBody` → `functionHasImplicitReturn`).
        // `() => { throw new Error(…); }` is therefore usable wherever a
        // `() => [number, string]` is wanted; typed `void` it was a
        // phantom TS2322/TS2345 at every such callback.
        //
        // …but only where tsc's `mayReturnNever` says so, and that is a
        // syntactic test on the function itself: an ARROW, a function
        // EXPRESSION, or an OBJECT-LITERAL method (whose body is a
        // `function_expr` here). A function DECLARATION and a CLASS member —
        // method, accessor, static — infer `void` from the same body, on the
        // grounds that a throwing declaration is a stub someone means to fill
        // in, not a `never`-returning contract for every caller.
        //
        // The distinction is load-bearing for an abstract-base-class hierarchy,
        // which is the shape it was found on:
        //
        // ```ts
        // class Node { toMarkdown(s: string) { throw new Error("nope"); } }
        // class Paragraph extends Node { toMarkdown(s: string) { … } }
        // ```
        //
        // `never` for the base makes every subclass that actually implements
        // the method unassignable to its own base (`void` ⊄ `never`) — 26
        // phantom TS2322s on outline's editor-node registry once the heritage
        // fast path stopped hiding the pair.
        if (c.stmtListTerminal(c.tree.nodeRange(body)) and mayReturnNever(c, fn_node)) {
            return types.never_type;
        }
        return types.void_type;
    }
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    // Each return expression is resolved in the scope where its `return`
    // statement lives (a return inside a try/if/loop block sees that
    // block's locals), not the ambient scope of this type probe.
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    for (rets.exprs.items, rets.scopes.items) |r, sc| {
        c.cur_scope = sc;
        try parts.append(c.scratch(), try c.checkExprCached(r, ret_ctx));
    }
    if (rets.bare or !c.stmtListTerminal(c.tree.nodeRange(body))) {
        try parts.append(c.scratch(), types.undefined_type);
    }
    // The several `return` statements of one function are ONE widening
    // context, so widening is decided on the union rather than per return
    // expression: both `widenReturnMember` and `widenToContext` distribute
    // over a union, so that part is the same computation — what is new is
    // the sibling-`undefined` normalization, which needs every member at
    // once. It applies with or without a contextual return type (a
    // contextual type fixes primitive-literal freshness, not object-literal
    // widening; and where the context is concrete the caller sees the
    // annotated type anyway, so it is invisible there).
    const raw = try c.normalizeFreshObjectSiblings(try c.ts.makeUnion(c.scratch(), parts.items));
    // No-context inference unions the *un-widened* fresh literals and
    // widens only the collapsed result (finalizeInferredReturn); a
    // contextual return keeps the widenToContext behaviour.
    if (ret_ctx == types.no_type) return c.finalizeInferredReturn(try c.widenReturnMember(raw));
    return c.widenToContext(raw, ret_ctx);
}

/// Inferred return type of an unannotated `function*`: tsc's
/// `Generator<Y, R, N>`, where `Y` unions every yielded value (widened —
/// `yield "a"` gives `string`, a bare `yield` gives `undefined`, no yields
/// at all give `never`), `R` is the ordinary inferred return type of the
/// body, and `N` is `unknown` — the value a caller hands to `.next()`,
/// which nothing in the body can pin down.
///
/// A `yield*` delegation is deliberately NOT inferred: its yield type is
/// the delegated iterable's element type, which needs the iterator
/// protocol, and guessing it would be inventing. Such a body keeps the old
/// `any`, so this narrows the gap rather than trading it for a wrong
/// answer. Same for `async function*` (`AsyncGenerator`'s own shape) and
/// for a generator without a body.
fn inferGeneratorReturn(c: *Checker, fn_node: Node, body: Node) Error!TypeId {
    const gen_sym = c.prog.globals.lookup(c.atom_Generator) orelse return types.any_type;
    if (!c.symFlags(gen_sym).interface) return types.any_type;
    if (c.nodeTag(body) != .block) return types.any_type;

    const base_scope = (try c.scopeOf(fn_node)) orelse c.cur_scope;
    var yields = try collectYields(c, c.tree.nodeRange(body), base_scope);
    defer yields.deinit(c.scratch());
    if (yields.delegated) return types.any_type;

    var yield_ty: TypeId = types.never_type;
    {
        // Same body context `inferReturnType` establishes: a `yield`
        // operand must be judged inside *this* generator.
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fn_node).lhs);
        const saved_fn_ctx = c.fn_ctx;
        defer c.fn_ctx = saved_fn_ctx;
        c.fn_ctx = .{
            .ret_ann = types.no_type,
            .is_async = proto.flags & ast.Flags.async != 0,
            .is_generator = true,
            .yield_type = 0,
        };
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (yields.exprs.items, yields.scopes.items) |y, sc| {
            c.cur_scope = sc;
            try parts.append(c.scratch(), try c.widenLiteral(try c.checkExprCached(y, types.no_type)));
        }
        if (yields.bare) try parts.append(c.scratch(), types.undefined_type);
        yield_ty = try c.ts.makeUnion(c.scratch(), parts.items);
    }
    const ret_ty = try inferReturnType(c, fn_node, body, types.no_type);
    return c.ts.makeRef(gen_sym, &.{ yield_ty, ret_ty, types.unknown_type });
}

/// The `yield` operands of one generator body: each yielded expression with
/// the scope it resolves in, whether a BARE `yield` (which contributes
/// `undefined`) occurred, and whether a `yield*` delegation did — the last
/// abandons inference entirely, so it is a property of the whole body rather
/// than of any one site.
pub const YieldSites = struct {
    exprs: std.ArrayList(Node) = .empty,
    scopes: std.ArrayList(ScopeId) = .empty,
    bare: bool = false,
    delegated: bool = false,

    pub fn deinit(self: *YieldSites, gpa: std.mem.Allocator) void {
        self.exprs.deinit(gpa);
        self.scopes.deinit(gpa);
    }
};

/// The `return` sites of one function body: each returned expression with the
/// scope it resolves in, plus whether a bare `return;` occurred.
pub const ReturnSites = struct {
    exprs: std.ArrayList(Node) = .empty,
    scopes: std.ArrayList(ScopeId) = .empty,
    bare: bool = false,

    pub fn deinit(self: *ReturnSites, gpa: std.mem.Allocator) void {
        self.exprs.deinit(gpa);
        self.scopes.deinit(gpa);
    }
};

/// Collect the `yield` sites of the body statements `stmts`, which bind in
/// `scope`. The caller owns the result (`deinit` with `c.scratch()`).
fn collectYields(c: *Checker, stmts: []const Node, scope: ScopeId) Error!YieldSites {
    var sites: YieldSites = .{};
    errdefer sites.deinit(c.scratch());
    for (stmts) |stmt| {
        if (stmt != null_node) try walkYields(c, stmt, &sites, scope);
    }
    return sites;
}

fn walkYields(c: *Checker, node: Node, sites: *YieldSites, scope: ScopeId) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        .yield_expr => {
            const d = c.tree.nodeData(node);
            if (d.rhs != 0) {
                sites.delegated = true;
                return;
            }
            if (d.lhs != 0) {
                try sites.exprs.append(c.scratch(), d.lhs);
                try sites.scopes.append(c.scratch(), scope);
            } else sites.bare = true;
        },
        // Don't descend into nested functions/classes: their yields belong
        // to them (and only a generator may contain one at all).
        .arrow_fn, .function_expr, .function_decl, .class_decl, .class_method => return,
        else => {},
    }
    const inner = (try c.scopeOf(node)) orelse scope;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try walkYields(c, child, sites, inner);
}

/// Collect the `return` sites of the body statements `stmts`, which bind in
/// `scope`. The caller owns the result (`deinit` with `c.scratch()`).
pub fn collectReturns(c: *Checker, stmts: []const Node, scope: ScopeId) Error!ReturnSites {
    var sites: ReturnSites = .{};
    errdefer sites.deinit(c.scratch());
    for (stmts) |stmt| {
        if (stmt != null_node) try walkReturns(c, stmt, &sites, scope);
    }
    return sites;
}

fn walkReturns(c: *Checker, node: Node, sites: *ReturnSites, scope: ScopeId) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        .return_stmt => {
            const d = c.tree.nodeData(node);
            if (d.lhs != 0) {
                try sites.exprs.append(c.scratch(), d.lhs);
                try sites.scopes.append(c.scratch(), scope);
            } else sites.bare = true;
            return;
        },
        // Don't descend into nested functions/classes.
        .arrow_fn, .function_expr, .function_decl, .class_decl, .class_method => return,
        else => {},
    }
    // A return nested in a block/try/loop/switch resolves its expression in
    // that construct's scope; track it as we descend.
    const inner = (try c.scopeOf(node)) orelse scope;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try walkReturns(c, child, sites, inner);
}

// =====================================================================
// symbol typing
// =====================================================================

pub fn typeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return types.any_type;
    if (c.sym_state.items[sym] == .computed) {
        // Reading a tainted memo taints whatever is being computed around it
        // (see `Checker.spec_sym_types`).
        if (c.spec_tainted.count() != 0 and c.spec_tainted.contains(sym)) c.spec_taint_reads += 1;
        return c.sym_types.items[sym];
    }
    if (c.sym_state.items[sym] == .in_progress) return types.any_type; // circular
    c.sym_state.items[sym] = .in_progress;
    const before = c.spec_taint_reads;
    const t = computeTypeOfSymbol(c, sym) catch |err| {
        c.sym_state.items[sym] = .not_computed;
        return err;
    };
    c.sym_types.items[sym] = t;
    c.sym_state.items[sym] = .computed;
    // Tainted only if this computation actually read a speculative pin. A side
    // query that materializes an unrelated declaration keeps its memo.
    if (c.side_query_depth != 0 and c.spec_taint_reads != before) try markSpeculative(c, sym);
    return t;
}

pub fn setTypeOfSymbol(c: *Checker, sym: SymbolId, t: TypeId) void {
    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return;
    if (c.sym_state.items[sym] == .computed) return;
    c.sym_types.items[sym] = t;
    c.sym_state.items[sym] = .computed;
    markSpeculativePin(c, sym);
}

/// Seed the taint from a parameter pin made while a side query is on the
/// stack: the value is whatever contextual signature the probe was running
/// with, and every local the probe derives from it inherits that.
///
/// A PARAMETER pin is tainted but never dropped. It is re-made from scratch on
/// every materialization of the function, so the authoritative pass overwrites
/// the probe's value on its own; dropping it instead leaves the parameter to
/// `computeTypeOfSymbol`, which re-derives an un-annotated parameter with no
/// contextual signature at all — measured as four fresh TS7006s on social-app
/// and three more on immich at `--checkers=3`, every one of them "Parameter
/// 'eb' implicitly has an 'any' type". Everything else this pins IS dropped:
/// a `for (const post of draft.posts)` binding is pinned once and never again,
/// which is exactly the entry the probe poisons.
///
/// Best-effort: an OOM here costs the taint, which is what the old code lacked
/// entirely.
pub fn markSpeculativePin(c: *Checker, sym: SymbolId) void {
    if (c.side_query_depth == 0) return;
    if (c.symFlags(sym).param) {
        _ = c.spec_tainted.getOrPut(c.cm(), sym) catch return;
        return;
    }
    markSpeculative(c, sym) catch {};
}

fn markSpeculative(c: *Checker, sym: SymbolId) Error!void {
    _ = try c.spec_tainted.getOrPut(c.cm(), sym);
    try c.spec_sym_types.append(c.cm(), sym);
}

/// Undo every tainted `sym_types` entry. Run from the top of
/// `checkExprCached` — i.e. before the authoritative pass walks anything, and
/// in particular before it re-pins the callback parameters it is about to
/// check the body under. Draining any later undoes those pins too, and
/// `computeTypeOfSymbol` re-derives an un-annotated parameter with no
/// contextual signature at all, i.e. as `any`.
pub fn dropSpeculativeSymTypes(c: *Checker) void {
    for (c.spec_sym_types.items) |s| {
        if (s < c.sym_state.items.len) c.sym_state.items[s] = .not_computed;
    }
    c.spec_sym_types.clearRetainingCapacity();
    c.spec_tainted.clearRetainingCapacity();
}

fn computeTypeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
    // A merged symbol's value type. For a merged *namespace* the
    // value object is anchored to the merged id — `classStaticType` walks
    // the merged member index; a cross-file kind combination
    // (function/enum/class + namespace) intersects the non-namespace
    // constituent's value. Otherwise (var/function) it is the first
    // value-space constituent's type. Type space is materialized via
    // `expandRef`/`interfaceGeneric`, which fold every constituent.
    if (c.prog.isMergedId(sym)) {
        const m = c.prog.mergedSym(sym);
        if (m.flags.namespace_decl) {
            var ns_val = try c.ts.makeClassValue(sym);
            // Intersect the first value-space constituent (a function/class/
            // enum callable base, *or* a `var console: Console`-style
            // variable) so a namespace merged onto a typed global keeps that
            // global's members. Without this a `var X: T` + `namespace X {…}`
            // merge drops `T` and every `X.member` is a phantom TS2339.
            // A callable base that is itself declared across lib + node
            // (`function setTimeout(): number` + node's `global{}`
            // `setTimeout(): NodeJS.Timeout`, plus `namespace setTimeout`)
            // folds every overload node-first, so `typeof setTimeout` stays
            // callable with the node return type.
            if (try mergedFunctionValue(c, m.parts)) |ft| {
                return c.ts.makeIntersection(c.scratch(), &.{ ft, ns_val });
            }
            for (m.parts) |p| {
                const pf = c.symFlags(p);
                if (pf.function or pf.enum_decl or pf.class) {
                    ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.typeOfSymbol(p), ns_val });
                    break;
                }
                if (pf.var_decl or pf.let_decl or pf.const_decl) {
                    ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try variableSymbolType(c, p), ns_val });
                    break;
                }
            }
            return ns_val;
        }
        // A global function declared in more than one file (lib.dom's
        // `setInterval(): number` + @types/node's `global{}`
        // `setInterval(): NodeJS.Timeout`) merges into one overload set,
        // node's signatures first — see `mergedFunctionValue`.
        if (try mergedFunctionValue(c, m.parts)) |ft| return ft;
        // A callable class split across files (`class C` here, `function C`
        // overloads there): keep both signature sets, call side first, the
        // same shape the same-file merge takes in `callableClassValue`.
        if (m.flags.class and m.flags.function) {
            var cls: TypeId = types.no_type;
            var fnv: TypeId = types.no_type;
            for (m.parts) |p| {
                const pf = c.symFlags(p);
                if (pf.class and cls == types.no_type) cls = try c.ts.makeClassValue(p);
                if (pf.function and fnv == types.no_type) fnv = try functionSymbolType(c, p);
            }
            if (cls != types.no_type and fnv != types.no_type)
                return c.ts.makeIntersection(c.scratch(), &.{ fnv, cls });
        }
        for (m.parts) |p| {
            if (hasValueMeaning(c.symFlags(p))) return c.typeOfSymbol(p);
        }
        return types.any_type;
    }
    const f = c.symFlags(sym);
    if (f.import_binding) return importedSymbolType(c, sym);
    // A namespace is a value object of its exported members, modeled as a
    // `class_value` anchored to the namespace symbol (so it prints
    // `typeof N` and resolves members via classStaticType). When merged
    // with a class the class_value already carries the namespace members;
    // with a function/enum the callable/base value is intersected with
    // the namespace object.
    if (f.namespace_decl) {
        const ns_val = try c.ts.makeClassValue(sym);
        if (f.class) {
            // `class_value` already carries the namespace's static members;
            // a callable class still needs its call signatures folded in.
            if (!f.function) return ns_val;
            return c.ts.makeIntersection(c.scratch(), &.{ try functionSymbolType(c, sym), ns_val });
        }
        if (f.function) return c.ts.makeIntersection(c.scratch(), &.{ try functionSymbolType(c, sym), ns_val });
        if (f.enum_decl) return c.ts.makeIntersection(c.scratch(), &.{ try c.enumValueType(sym), ns_val });
        // Same-file `var X: T` + `namespace X {…}` (a namespace merged onto a
        // typed global within one file): keep T's members.
        if (f.var_decl or f.let_decl or f.const_decl)
            return c.ts.makeIntersection(c.scratch(), &.{ try variableSymbolType(c, sym), ns_val });
        return ns_val;
    }
    if (f.enum_decl) return c.enumValueType(sym);
    if (f.class) return callableClassValue(c, sym, f);
    if (f.function) return withExpandoProps(c, sym, try functionSymbolType(c, sym));
    if (f.expando_member) return expandoMemberType(c, sym);
    if (f.property or f.method or f.getter or f.setter) return c.memberTypeOf(sym);

    // The remaining cases traverse decl nodes: switch to the symbol's
    // file and declaring scope.
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);

    if (f.catch_param) {
        const decls = c.declsOf(sym);
        if (decls.len > 0 and c.nodeTag(decls[0]) == .declarator_full) {
            const dd = c.tree.nodeData(decls[0]);
            const e = c.tree.extraData(ast.DeclaratorFull, dd.rhs);
            if (e.type_ann != 0) return c.typeFromTypeNode(e.type_ann);
        }
        return types.unknown_type; // useUnknownInCatchVariables (strict)
    }
    if (f.param) {
        const decls = c.declsOf(sym);
        for (decls) |decl| {
            switch (c.nodeTag(decl)) {
                .param, .param_full => {
                    const p = try paramInfo(c, decl, 0, types.no_type, false);
                    // Pattern params: paramInfo names only identifiers;
                    // for destructured params fall through to any.
                    if (p.name != 0 and p.name == c.symNameAtom(sym)) return p.ty;
                    return c.bindingElementType(sym, decl, p.ty);
                },
                else => {},
            }
        }
        return types.any_type;
    }
    if (f.var_decl or f.let_decl or f.const_decl)
        return withExpandoProps(c, sym, try variableSymbolType(c, sym));
    return types.any_type;
}

/// The value (`typeof C`) side of a class symbol. Normally just the
/// `class_value` — construct signatures, statics, and the namespace members
/// of anything merged onto it.
///
/// A class that ALSO carries `function` declarations is tsc's *callable
/// class*: `ClassExcludes` omits `Function` (and `FunctionExcludes` omits
/// `Class`), so a `.d.ts` may declare call signatures next to the class to
/// describe a constructor that also works without `new` — ua-parser-js's
/// `function UAParser(…): IResult` overloads next to `class UAParser`, then
/// `export = UAParser`. tsc's `resolveAnonymousTypeMembers` gives the merged
/// symbol both signature sets; here the callable half is intersected in, the
/// same shape a function merged with a namespace already uses. Call
/// signatures come first so overload resolution sees them in declaration
/// order.
fn callableClassValue(c: *Checker, sym: SymbolId, f: binder.SymbolFlags) Error!TypeId {
    const cls = try c.ts.makeClassValue(sym);
    if (!f.function) return cls;
    return c.ts.makeIntersection(c.scratch(), &.{ try functionSymbolType(c, sym), cls });
}

/// Fold a function value's *expando* properties into its type: the
/// callable base intersected with an object of the `fn.prop = value`
/// declarations the binder collected (TS 3.1 properties-on-functions).
/// A pass-through for the overwhelming majority of symbols, which have
/// none. tsc models this as one anonymous type carrying both the call
/// signatures and the members; the intersection is the same shape ztsc
/// already uses for a function merged with a namespace.
fn withExpandoProps(c: *Checker, sym: SymbolId, base: TypeId) Error!TypeId {
    if (!c.symFlags(sym).expando) return base;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    const xs = c.bind.expandoScopeOf(c.localOf(sym)) orelse return base;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    const lo = c.bind.scope_members_start[xs];
    const hi = c.bind.scope_members_start[xs + 1];
    for (lo..hi) |i| {
        const msym = c.toGlobal(c.bind.member_syms[i]);
        try props.append(c.scratch(), .{
            .name = c.bind.member_atoms[i],
            .ty = try c.typeOfSymbol(msym),
            .flags = 0,
        });
    }
    if (props.items.len == 0) return base;
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    return c.ts.makeIntersection(c.scratch(), &.{ base, obj });
}

/// Type of one expando property: the widened type of the assigned
/// expression, unioned over every `fn.prop = value` statement that
/// declares it (tsc widens each assignment and unions them).
fn expandoMemberType(c: *Checker, sym: SymbolId) Error!TypeId {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .assign) continue;
        const rhs = c.tree.nodeData(decl).rhs;
        if (rhs == ast.null_node) continue;
        const t = try c.widenLiteral(try c.checkExprCached(rhs, types.no_type));
        try parts.append(c.scratch(), t);
    }
    if (parts.items.len == 0) return types.any_type;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// Fold every callable constituent of a merged global function symbol into
/// one overload set — in DECLARATION order, with one group boundary per
/// contributing declaration recorded in `overload_groups` for the call path.
/// Returns null when fewer than two constituents are callable (the
/// overwhelmingly common single-contributor global keeps its type via the
/// caller's existing first-value-constituent path).
///
/// The two orders are tsc's, and they differ. A merged symbol's signatures
/// are `getSignaturesOfSymbol`'s — the symbol's declarations in the order
/// they were merged. The default library is bound first and a module's
/// `declare global { … }` block is a global-scope *augmentation*, merged
/// after every plain global file, so lib.dom's
/// `setTimeout(handler: TimerHandler, …): number` comes first and
/// @types/node's `setTimeout(…): NodeJS.Timeout` last. That is the order
/// `getSignaturesOfType` reports, hence the order the printer shows and the
/// order `ReturnType`/`Parameters` see (they align from the END, so they
/// answer with the LAST group's signature).
///
/// Overload RESOLUTION does not use that order. `resolveCall` runs the list
/// through `reorderCandidates` first, which groups the signatures by
/// declaring parent and splices each new group in at the front, keeping the
/// order within a group — i.e. it visits the groups back-to-front, so the
/// LAST declaration group is tried first. That is why
/// `setTimeout(() => {}, 1)` is a `NodeJS.Timeout` while
/// `setTimeout(someString, 1)` — which only lib.dom accepts — is a `number`,
/// and why a call that matches NEITHER (`fetch(url, { body: aSharedBuffer })`)
/// is TS2769 rather than a bare argument error.
///
/// Back-to-front is not the same as one rotation of a lib/non-lib split, and
/// the difference is observable the moment a THIRD group appears. social-app
/// merges `setTimeout` from lib.dom (`number`), @types/node's `declare global`
/// (`NodeJS.Timeout`) and react-native's `declare global` (`number`); a single
/// rotation yields `[node, react-native, lib]`, so the CALL answered
/// `Timeout` while `ReturnType<typeof setTimeout>` — which aligns from the end
/// of declaration order — answered `number`, and every
/// `slot = setTimeout(…)` was a phantom TS2322. Reversing the groups puts
/// react-native first, and both paths land on the same last group. With
/// exactly two groups a rotation and a reversal coincide, which is why this
/// only ever showed up with three.
///
/// The library counts as ONE group however many shards it was split into:
/// `src/lib/gen_lib.js` shards lib.dom/lib.esnext at top-level declaration
/// boundaries purely so the front end parallelizes, and tsc sees each
/// `lib.*.d.ts` as a single SourceFile — a single parent, a single group.
/// Grouping per shard would reverse overloads of one name that happen to
/// straddle a shard boundary.
///
/// Keeping only the non-lib group, as this did before, got the call site
/// right and everything else wrong: one signature can never be an overload
/// set, so a call matching no signature reported the failing argument
/// instead of TS2769, and a call only the library signature accepts failed
/// outright.
fn mergedFunctionValue(c: *Checker, parts: []const u32) Error!?TypeId {
    var nonlib: std.ArrayList(TypeId) = .empty;
    defer nonlib.deinit(c.scratch());
    var lib: std.ArrayList(TypeId) = .empty;
    defer lib.deinit(c.scratch());
    for (parts) |p| {
        if (!c.symFlags(p).function) continue;
        var t = try c.typeOfSymbol(p);
        // A constituent that also carries a namespace (node's `setTimeout`
        // is `function setTimeout` + `namespace setTimeout`) materializes as
        // `overloads & class_value`; unwrap the callable part so its
        // signatures still fold in.
        if (c.ts.kind(t) == .intersection) {
            for (try c.memberList(t)) |m| {
                const rm = try c.resolveStructural(m);
                if (c.ts.kind(rm) == .function or c.ts.kind(rm) == .overloads) {
                    t = rm;
                    break;
                }
            }
        }
        const k = c.ts.kind(t);
        if (k != .function and k != .overloads) continue;
        if (libs.isLibPath(c.prog.files[c.symFile(p)].path))
            try lib.append(c.scratch(), t)
        else
            try nonlib.append(c.scratch(), t);
    }
    if (nonlib.items.len + lib.items.len < 2) return null;
    // Declaration order: the library (one group, however many shards it came
    // from), then one group per augmenting contributor, in merge order.
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(c.scratch());
    const appendSigs = struct {
        fn f(ck: *Checker, dst: *std.ArrayList(TypeId), o: TypeId) Error!void {
            if (ck.ts.kind(o) == .overloads) {
                for (ck.ts.members(o)) |mm| try dst.append(ck.scratch(), mm);
            } else try dst.append(ck.scratch(), o);
        }
    }.f;
    if (lib.items.len != 0) {
        try starts.append(c.scratch(), 0);
        for (lib.items) |o| try appendSigs(c, &sigs, o);
    }
    for (nonlib.items) |o| {
        try starts.append(c.scratch(), @intCast(sigs.items.len));
        try appendSigs(c, &sigs, o);
    }
    if (sigs.items.len == 1) return sigs.items[0];
    const t = try c.ts.makeOverloads(sigs.items);
    if (starts.items.len > 1) {
        const at: u32 = @intCast(c.overload_group_pool.items.len);
        try c.overload_group_pool.appendSlice(c.cm(), starts.items);
        try c.overload_groups.put(c.cm(), t, .{ .start = at, .len = @intCast(starts.items.len) });
    }
    return t;
}

/// Append `ov`'s call signatures in overload-RESOLUTION order — tsc's
/// `reorderCandidates`. Identical to the stored member order except for a
/// merged global function, whose declaration groups are visited back-to-front
/// (order preserved within a group), so the LAST group is tried first — see
/// `mergedFunctionValue`.
pub fn appendOverloadCandidates(c: *Checker, out: *std.ArrayList(TypeId), ov: TypeId) Error!void {
    const ms = try c.memberList(ov);
    const span = c.overload_groups.get(ov) orelse {
        try out.appendSlice(c.scratch(), ms);
        return;
    };
    const starts = c.overload_group_pool.items[span.start..][0..span.len];
    // The recorded boundaries index the member list this set was interned
    // with; a mismatch can only mean the interner handed back a different
    // set, so fall back to the stored order rather than drop signatures.
    if (starts.len < 2 or starts[0] != 0 or starts[starts.len - 1] >= ms.len) {
        try out.appendSlice(c.scratch(), ms);
        return;
    }
    var i = starts.len;
    while (i > 0) {
        i -= 1;
        const lo = starts[i];
        const hi = if (i + 1 < starts.len) starts[i + 1] else @as(u32, @intCast(ms.len));
        try out.appendSlice(c.scratch(), ms[lo..hi]);
    }
}

/// Append the call signatures of a callable OBJECT in overload-RESOLUTION
/// order — tsc's `reorderCandidates` again, this time for the shape it
/// actually shows up in most often: an interface declared more than once,
/// each declaration carrying its own call signature.
///
/// tsc groups a candidate list by `signature.declaration.parent` and splices
/// each new group in at the FRONT, so the groups are visited back-to-front
/// with the order inside a group preserved. `getSignaturesOfType` keeps
/// declaration order, and everything that is not a call site reads it that
/// way — `ReturnType`/`Parameters` and `inferFromSignatures` align from the
/// END, the printer prints in order — so the reversal must stay here, at the
/// call site, and must never be baked into the stored table.
///
/// tippy.js is the canonical case:
///
///     interface Tippy<TProps = Props> extends TippyStatics {
///       (targets: SingleTarget, …): Instance<TProps>;
///     }
///     interface Tippy<TProps = Props> extends TippyStatics {
///       (targets: MultipleTargets, …): Instance<TProps>[];
///     }
///
/// Resolution order is `[MultipleTargets, SingleTarget]`, so the LAST
/// candidate — the one a failed overload resolution reports against — is the
/// `SingleTarget` one, and its error lands on argument 0.
///
/// `Tippy` reaches a call site as a fresh instantiated object, which carries
/// no boundaries of its own; it is routed back to the generic table the
/// boundaries were recorded against through its `origin` ref (`expandRef`
/// tags every materialization of `G<A…>` with the canonical ref, generic
/// arguments included). Anything that route cannot resolve — a plain object
/// type literal, a class instance, an inherited-only signature list — keeps
/// the stored order.
pub fn appendObjectCallCandidates(c: *Checker, out: *std.ArrayList(TypeId), obj: TypeId) Error!void {
    const n = c.ts.objectCallSigCount(obj);
    const appendAll = struct {
        fn f(ck: *Checker, dst: *std.ArrayList(TypeId), o: TypeId, cnt: u32) Error!void {
            for (0..cnt) |i| try dst.append(ck.scratch(), ck.ts.objectCallSig(o, @intCast(i)));
        }
    }.f;
    if (n < 2) return appendAll(c, out, obj, n);
    const span = callSigGroupsOf(c, obj) orelse return appendAll(c, out, obj, n);
    // `bounds` is `groups + 1` ascending offsets: group `i` is
    // `[bounds[i], bounds[i + 1])` and `bounds[len - 1]` is the end of the
    // declarations' own (non-inherited) prefix. The boundaries index the
    // GENERIC table's call-signature list; instantiation copies that list
    // position for position, so a mismatch can only mean this object is not
    // that table's instance after all — fall back to the stored order rather
    // than drop or duplicate a signature.
    const bounds = c.overload_group_pool.items[span.start..][0..span.len];
    if (bounds.len < 3 or bounds[0] != 0 or bounds[bounds.len - 1] > n) {
        return appendAll(c, out, obj, n);
    }
    var i = bounds.len - 1;
    while (i > 0) {
        i -= 1;
        for (bounds[i]..bounds[i + 1]) |k| try out.append(c.scratch(), c.ts.objectCallSig(obj, @intCast(k)));
    }
    // Anything past the prefix is INHERITED. tsc restarts its grouping at the
    // end of the result list whenever the declaring symbol changes, so those
    // stay after the reversed groups, in order.
    for (bounds[bounds.len - 1]..n) |k| try out.append(c.scratch(), c.ts.objectCallSig(obj, @intCast(k)));
}

/// The declaration-group boundaries recorded for `obj`'s call signatures:
/// `obj` itself when it IS the generic table, else the table its `origin` ref
/// names (`interfaceGeneric`'s memo, read without materializing anything).
fn callSigGroupsOf(c: *Checker, obj: TypeId) ?checker_zig.BaseSpan {
    if (c.overload_groups.get(obj)) |s| return s;
    const orig = c.origin.get(obj) orelse return null;
    if (c.ts.kind(orig) != .ref) return null;
    const generic = c.iface_generic.get(c.ts.refSymbol(orig)) orelse return null;
    return c.overload_groups.get(generic);
}

/// The last call signature (a `.function` TypeId) reachable from any
/// callable shape: a bare function, an overload set (tsc's
/// `inferFromSignatures` aligns from the end, so the last wins), a
/// callable object carrying call signatures, or an intersection that wraps
/// one (`overloads & namespaceObject`). Null when nothing is callable.
pub fn lastCallSig(c: *Checker, t0: TypeId) Error!?TypeId {
    const s = &c.ts;
    const t = try c.resolveStructural(t0);
    switch (s.kind(t)) {
        .function => return t,
        .overloads => {
            const ms = try c.memberList(t);
            return if (ms.len > 0) ms[ms.len - 1] else null;
        },
        .object => {
            const n = s.objectCallSigCount(t);
            return if (n > 0) s.objectCallSig(t, n - 1) else null;
        },
        .intersection => {
            var found: ?TypeId = null;
            for (try c.memberList(t)) |m| {
                if (try c.lastCallSig(m)) |sig| found = sig;
            }
            return found;
        },
        else => return null,
    }
}

/// The declared value type of a `var`/`let`/`const` symbol. Self-contained
/// (switches to the symbol's file/scope) so it can also be called for a
/// symbol that additionally carries a `namespace` meaning (e.g. `@types/node`
/// declares `var console: Console` alongside `namespace console { … }`).
fn variableSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    const is_const = c.symFlags(sym).const_decl;
    const decls = c.declsOf(sym);
    for (decls) |decl| {
        // A symbol can merge a value declaration with a type-only one
        // (e.g. lib's `interface Object {}` + `declare var Object: {…}`).
        // Only the variable declarators carry the value type; skip the
        // type-space decls so they don't short-circuit to `any`.
        switch (c.nodeTag(decl)) {
            .declarator, .declarator_init, .declarator_full => {},
            else => continue,
        }
        const t = try declaratorType(c, sym, decl, is_const);
        if (t != types.no_type) return t;
    }
    return types.any_type;
}

// The value meaning of a module reference lives in `modvalue.zig`;
// re-exported here because symbol typing above drives it and `Checker`'s
// method aliases — plus calls.zig's direct import of `ambientNamespaceType` —
// name this file.
pub const ambientNamespaceType = modvalue.ambientNamespaceType;
pub const appendAugmentedModuleExports = modvalue.appendAugmentedModuleExports;
pub const dualHasValue = modvalue.dualHasValue;
pub const dualValueType = modvalue.dualValueType;
const importedSymbolType = modvalue.importedSymbolType;
pub const namespaceObjectType = modvalue.namespaceObjectType;
pub const targetValueType = modvalue.targetValueType;

/// Is `sym` an *evolving* variable — tsc's "auto" type? A `let`/`var` with
/// no type annotation and either no initializer at all or one that is
/// literally `null` or `undefined` gets a declared type that does not
/// constrain later writes: the write is unchecked and a read's type is
/// whatever the flow last assigned (`getTypeAtFlowAssignment`'s
/// `declaredType === autoType` branch, which returns the assigned type
/// instead of reducing it against the declared one). Without this
/// `let match = null; while ((match = exec(s)) !== null)` pins `match` to
/// `null` and reports the assignment plus every use.
///
/// The initializer-less form is tsc's primary one — `let x;` IS the auto
/// type, and `= null` / `= undefined` merely join it. Excluding it left a
/// bare `let x;` reading as a plain `any` for the whole function, so every
/// callback it fed lost its contextual signature:
/// `let target; … target = xs.filter(…); return target.map((item) => …)`
/// reported `item` as an implicit `any`.
///
/// Purely syntactic — it never re-enters `checkExpr`, so it is safe to ask
/// from inside `typeOfSymbol`'s own callers. Restricted to the current file
/// (a cross-file reference is never flow-narrowed anyway) and to a single
/// declarator binding a plain identifier.
pub fn isEvolvingVar(c: *Checker, sym: SymbolId) bool {
    if (@import("flow.zig").isPseudoRoot(sym) or sym == binder.no_symbol) return false;
    const f = c.symFlags(sym);
    if (!(f.let_decl or f.var_decl)) return false;
    if (f.const_decl or f.param or f.catch_param) return false;
    if (c.symFile(sym) != c.cur_file) return false;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return false;
    const decl = decls[0];
    const d = c.tree.nodeData(decl);
    const init_node: Node = switch (c.nodeTag(decl)) {
        // `let x;` — no annotation, no initializer.
        .declarator => null_node,
        .declarator_init => d.rhs,
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann != 0) return false;
            break :blk e.init;
        },
        else => return false,
    };
    if (c.nodeTag(d.lhs) != .identifier) return false;
    if (init_node == null_node) return c.nodeTag(decl) == .declarator;
    return switch (c.nodeTag(init_node)) {
        .null_literal => true,
        .identifier => c.tree.tokens.tag(c.tree.nodeMainToken(init_node)) == .keyword_undefined,
        else => false,
    };
}

/// The declared type of an un-annotated declarator's initializer. A `const`
/// keeps its literal types (`widenObjectLiterals`, not `widenLiteral`), but an
/// initializer that is a union of *fresh object literals* — `cond ? {a} :
/// {b}`, `x || {b}` — is still one widening context and gets the
/// sibling-`undefined` normalization either way.
///
/// `const` changes nothing for an OBJECT literal: tsc widens every mutable
/// location with `getWidenedType`, and `const` only keeps `getWidenedLiteralType`
/// from running over the primitive literals. So the object is widened in both
/// branches — losing its literal origin — and a later generic call no longer
/// treats the variable as an object-literal inference candidate.
pub fn widenInitializer(c: *Checker, init_t: TypeId, is_const: bool) Error!TypeId {
    const norm = try c.normalizeFreshObjectSiblings(init_t);
    return if (is_const) c.widenObjectLiterals(norm) else c.widenLiteral(norm);
}

/// The element type a `for..of` / `for..in` head gives the binding `sym`,
/// or null when `sym` is not such a binding.
///
/// `checkForInOf` pins the same type as it walks the loop, but the binding
/// can be *demanded* long before that statement is reached: a flow query
/// crossing the loop's back edge re-checks an assignment in the body
/// (`assignNarrows`), and anything that assignment's right-hand side reads
/// resolves through `typeOfSymbol` right there. Return-type inference for
/// an enclosing arrow is enough to trigger it — the `return` after the loop
/// is checked first, its flow walk reaches the loop-carried assignment, and
/// the loop variable is asked for its type before the loop head has run.
///
/// Without this the declarator falls through to `any`, and because
/// `typeOfSymbol` marks what it computes as final, that `any` *wins* over
/// the element type `checkForInOf` later tries to set — every use of the
/// loop variable in the body silently becomes `any`, taking with it the
/// narrowings and the contextual types that would have come from it.
fn forHeadBindingType(c: *Checker, sym: SymbolId) Error!?TypeId {
    const scope = c.symScope(sym);
    if (c.bind.scope_kinds[scope] != .for_head) return null;
    const owner = c.bind.scope_owners[scope];
    if (owner == null_node) return null;
    const is_of = switch (c.nodeTag(owner)) {
        .for_of_stmt => true,
        .for_in_stmt => false,
        else => return null, // plain `for (let i = 0; …)`
    };
    if (!is_of) return types.string_type; // for..in keys
    const e = c.tree.extraData(ast.ForInOf, c.tree.nodeData(owner).lhs);
    const rt = try c.checkExprCached(e.right, types.no_type);
    // No `right_node`: a non-iterable right-hand side is diagnosed once, by
    // `checkForInOf`, in source order — not from whatever demanded the
    // binding first.
    return try c.forOfElementType(rt, null_node, e.is_await != 0);
}

/// tsc's `getESSymbolLikeTypeForNode` / `isValidESSymbolDeclaration`: a
/// `Symbol()` or `Symbol.for()` call typed for a CONST variable declaration
/// with a plain identifier name yields a fresh `unique symbol` keyed to that
/// declaration, not the lib's plain `symbol` return. Without it
/// `const TOMB = Symbol('t')` types as `symbol`, so `typeof TOMB` is `symbol`
/// too and `x === TOMB` cannot narrow the `Post | typeof TOMB` union — the
/// `symbol` constituent survives into the else branch (6 TS2322 on
/// social-app's post-shadow tombstone). Keyed on the declarator node, which
/// is distinct from the annotation node an explicit `: unique symbol` uses.
/// Null when the shape does not qualify, so the caller widens as before.
fn inferredUniqueSymbol(c: *Checker, decl: Node, name: Node, init: Node, is_const: bool, init_t: TypeId) Error!?TypeId {
    if (!is_const or c.nodeTag(name) != .identifier) return null;
    if (c.ts.kind(init_t) != .symbol) return null;
    if (!c.isFreshSymbolCall(init)) return null;
    return try c.uniqueSymType(decl);
}

/// Type of one variable declarator for `sym` (no_type if this decl
/// contributes none, e.g. bare `declarator` in a multi-decl symbol).
fn declaratorType(c: *Checker, sym: SymbolId, decl: Node, is_const: bool) Error!TypeId {
    // The initializer is being typed to *build* this variable's type, so
    // any function body inside it must not be walked yet — the same rule
    // the class-field arm of `computeTypeOfSymbol` already applies (see
    // `DeferredBody`), and tsc's own: `checkFunctionExpressionOrObject-
    // LiteralMethod` resolves the signature and then `checkNodeDeferred`s
    // the body, which runs at the end of the enclosing file's check.
    //
    // `declaratorType` is only ever reached from `typeOfSymbol`, i.e. from
    // a *demand* — the file's own walk checks a declarator's initializer
    // directly (`checkDeclarator`), where `defer_bodies` is 0 and nothing
    // changes. What changes is the demand path: `const f = (…) => {…}` is
    // no longer body-walked from the middle of whatever asked for `f`'s
    // type. That walk is arbitrary work with arbitrary type demands of its
    // own, and when the demand came from another module in an import cycle
    // it reached back into a symbol still marked in-progress, which answers
    // `any` (`typeOfSymbol`'s cycle break). Two unannotated functions in a
    // module cycle then resolved differently depending on which side was
    // entered first — and which side that is depends on the `--checkers=N`
    // partition, so the resulting report came and went with it.
    //
    // Nothing is lost: `drainDeferredBodies` walks the queued body at the
    // next top-level statement boundary, by which time the symbol whose
    // demand queued it is sealed.
    c.defer_bodies += 1;
    defer c.defer_bodies -= 1;
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .declarator => {
            // No initializer and no annotation: either a loop head binding
            // (typed by what is iterated) or a bare `let x;`.
            const et = (try forHeadBindingType(c, sym)) orelse return types.any_type;
            if (c.nodeTag(d.lhs) == .identifier) return et;
            return c.bindingElementType(sym, decl, et);
        },
        .declarator_init => {
            if (try freshSymbolConstType(c, decl, d.lhs, d.rhs, is_const)) |u| return u;
            const init_t = try c.checkExprCached(d.rhs, types.no_type);
            if (try inferredUniqueSymbol(c, decl, d.lhs, d.rhs, is_const, init_t)) |u| return u;
            const vt = try c.widenInitializer(init_t, is_const);
            if (c.nodeTag(d.lhs) == .identifier) return vt;
            return c.bindingElementType(sym, decl, vt);
        },
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            var vt: TypeId = types.any_type;
            if (e.type_ann != 0) {
                vt = try c.annTypeMaybeUnique(e.type_ann, is_const, 1332, c.nodeSpan(d.lhs));
            } else if (e.init != 0) {
                if (try freshSymbolConstType(c, decl, d.lhs, e.init, is_const)) |u| return u;
                const init_t = try c.checkExprCached(e.init, types.no_type);
                if (try inferredUniqueSymbol(c, decl, d.lhs, e.init, is_const, init_t)) |u| return u;
                vt = try c.widenInitializer(init_t, is_const);
            }
            if (c.nodeTag(d.lhs) == .identifier) return vt;
            return c.bindingElementType(sym, decl, vt);
        },
        else => return types.any_type,
    }
}

/// tsc's `getESSymbolLikeTypeForNode`: a call to the global `Symbol` /
/// `Symbol.for` produces a FRESH `unique symbol` type — not the plain
/// `symbol` its signature returns — when it initializes a declaration that
/// can hold one (`isValidESSymbolDeclaration`: a `const` variable with an
/// identifier name, a `readonly static` field, a `readonly` property
/// signature). The type is nominal, keyed by the declaration, so every
/// reference to the const shares it.
///
/// The consequence is narrowing. `export const POST_TOMBSTONE =
/// Symbol('PostTombstone')` is the sentinel a post-shadow cache returns, and
/// `if (postShadowed === POST_TOMBSTONE) return null` only subtracts it from
/// the union when the sentinel is a UNIT type. Left as `symbol`, `===`
/// narrowed nothing and the whole `symbol | Shadow<PostView>` union survived
/// into the code below the guard — a false TS2339 on every field of the post.
///
/// `null` when the declaration is not that shape, in which case the caller
/// takes the ordinary widened-initializer path.
fn freshSymbolConstType(c: *Checker, decl: Node, name: Node, init: Node, is_const: bool) Error!?TypeId {
    if (!is_const) return null;
    if (name == null_node or c.nodeTag(name) != .identifier) return null;
    if (!c.isFreshSymbolCall(init)) return null;
    // Checked for its own diagnostics; the type is the declaration's, not
    // the call's.
    _ = try c.checkExprCached(init, types.no_type);
    return try c.uniqueSymType(decl);
}

// Destructuring lives in `destructure.zig`; re-exported here because symbol
// typing above drives it and `Checker`'s method aliases — plus flow.zig's
// direct import of `findBindingType` — name this file.
pub const BindFlow = destructure.BindFlow;
pub const bindingElementType = destructure.bindingElementType;
pub const bindingFlowBase = destructure.bindingFlowBase;
pub const extendRefKey = destructure.extendRefKey;
pub const findBindingType = destructure.findBindingType;
pub const objectRestType = destructure.objectRestType;
const optionalizePatternDefaults = destructure.optionalizePatternDefaults;
pub const patternDefaultsProp = destructure.patternDefaultsProp;
pub const pinBindingSym = destructure.pinBindingSym;
pub const pinPatternParamSyms = destructure.pinPatternParamSyms;

fn functionSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    const decls = c.declsOf(sym);
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    var impl_sig: TypeId = types.no_type;
    for (decls) |decl| {
        // `function_expr` is here for the SELF-NAME of a named function
        // expression (`const f = function recur(n) { … recur(…) … }`), which
        // the binder declares in the expression's own scope. It never carries
        // overloads, so it takes the implementation-signature path below.
        switch (c.nodeTag(decl)) {
            .function_decl, .function_expr => {},
            else => continue,
        }
        const d = c.tree.nodeData(decl);
        const sig = try c.signatureOfProto(decl, d.lhs, false, true);
        if (d.rhs == 0) {
            try sigs.append(c.scratch(), sig); // overload signature
        } else {
            impl_sig = sig;
        }
    }
    if (sigs.items.len == 0) {
        return if (impl_sig != types.no_type) impl_sig else types.any_type;
    }
    return c.ts.makeOverloads(sigs.items);
}

/// The three circularity reports for a member whose own type turned out to
/// need itself. `cycle` is the slice of the member-resolution stack from the
/// re-entered member to the top — every member on the circle, so the report
/// set is a function of the circle and not of whichever member the traversal
/// happened to demand first (tsc reports on all of them likewise).
///
/// Which of the three a member takes is decided by its *own* declaration,
/// because that is what the circle runs through:
///
///   - a member with a type ANNOTATION can only be circular through that
///     annotation (`a: A["a"]`) → TS2502;
///   - an unannotated method/accessor is circular through its inferred
///     RETURN type (`m() { return this.m(); }`) → TS7023;
///   - an unannotated field is circular through its INITIALIZER
///     (`p = this.p`) → TS7022.
///
/// The last two are implicit-`any` reports, so they follow `noImplicitAny`
/// like their siblings. Anything else (a parameter property, a member with
/// no declaration node of a shape handled here) reports nothing: the cut
/// itself is unchanged, so silence is the pre-existing behaviour.
/// Whether the circle currently on `member_type_stack` closed only because
/// ztsc took eagerly an indexed access that tsc defers — see `lazy_index_objs`.
/// Not tsc's circle: it must neither be reported nor cut, or the deferred
/// access loses the type it would have resolved to.
fn spuriousIndexCycle(c: *Checker) Error!bool {
    for (c.lazy_index_objs.items) |obj| {
        if (try c.containsTypeParam(obj)) return true;
    }
    return false;
}

fn reportMemberCycle(c: *Checker, cycle: []const SymbolId) Error!void {
    for (cycle) |msym| {
        const saved = c.enterSymFile(msym);
        defer c.restoreCtx(saved);
        const decls = c.declsOf(msym);
        if (decls.len == 0) continue;
        const decl = decls[0];
        const d = c.tree.nodeData(decl);
        const name_span = c.tokSpan(c.tree.nodeMainToken(decl));
        const name = c.tokenText(c.tree.nodeMainToken(decl));
        switch (c.nodeTag(decl)) {
            .class_field => {
                const e = c.tree.extraData(ast.Field, d.lhs);
                if (e.type_ann != 0) {
                    try c.diagFmt(2502, name_span, "'{s}' is referenced directly or indirectly in its own type annotation.", .{name});
                } else if (c.prog.no_implicit_any) {
                    try c.diagFmt(7022, name_span, "'{s}' implicitly has type 'any' because it does not have a type annotation and is referenced directly or indirectly in its own initializer.", .{name});
                }
            },
            .property_signature => {
                if (d.lhs != 0) {
                    try c.diagFmt(2502, name_span, "'{s}' is referenced directly or indirectly in its own type annotation.", .{name});
                }
            },
            .class_method, .method_signature => {
                const proto = c.tree.extraData(ast.FnProto, d.lhs);
                if (proto.return_type != 0) {
                    try c.diagFmt(2502, name_span, "'{s}' is referenced directly or indirectly in its own type annotation.", .{name});
                } else if (c.prog.no_implicit_any) {
                    try c.diagFmt(7023, name_span, "'{s}' implicitly has return type 'any' because it does not have a return type annotation and is referenced directly or indirectly in one of its return expressions.", .{name});
                }
            },
            else => {},
        }
    }
}

/// Type of a class/interface member symbol (unsubstituted).
pub fn memberTypeOf(c: *Checker, sym: SymbolId) Error!TypeId {
    // A member whose type demands itself: `a: A["a"]` through the lazy
    // single-member lookup, `m() { return this.m(); }` through the
    // reserved-signature slot, `p = this.p` through both, and a getter
    // annotated `get foo(): typeof this.foo` straight through this frame.
    // Only the first three cut the recursion *below* here; the getter has no
    // such cut and used to recurse until the stack died. This is tsc's
    // `pushTypeResolution` cut instead: a symbol already being resolved
    // answers `any`, and naming the circle is the report.
    for (c.member_type_stack.items, 0..) |m, i| {
        if (m != sym) continue;
        if (try spuriousIndexCycle(c)) break;
        try reportMemberCycle(c, c.member_type_stack.items[i..]);
        return types.any_type;
    }
    try c.member_type_stack.append(c.cm(), sym);
    defer _ = c.member_type_stack.pop();
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    const f = c.symFlags(sym);
    const decls = c.declsOf(sym);
    if (f.method) {
        var sigs: std.ArrayList(TypeId) = .empty;
        defer sigs.deinit(c.scratch());
        var impl_sig: TypeId = types.no_type;
        for (decls) |decl| {
            const tag = c.nodeTag(decl);
            if (tag != .class_method and tag != .method_signature) continue;
            const d = c.tree.nodeData(decl);
            const sig = try c.signatureOfProto(decl, d.lhs, true, true);
            if (tag == .class_method and d.rhs != 0) impl_sig = sig else try sigs.append(c.scratch(), sig);
        }
        if (sigs.items.len == 0) {
            return if (impl_sig != types.no_type) impl_sig else types.any_type;
        }
        return c.ts.makeOverloads(sigs.items);
    }
    if (f.getter or f.setter) {
        // Getter return type wins; setter-only uses its param type.
        for (decls) |decl| {
            const tag = c.nodeTag(decl);
            if (tag != .class_method and tag != .method_signature) continue;
            const d = c.tree.nodeData(decl);
            const proto = c.tree.extraData(ast.FnProto, d.lhs);
            if (proto.flags & ast.Flags.get != 0) {
                if (proto.return_type != 0) return c.typeFromTypeNode(proto.return_type);
                if (tag == .class_method and d.rhs != 0) return inferReturnType(c, decl, d.rhs, types.no_type);
            }
        }
        for (decls) |decl| {
            const tag = c.nodeTag(decl);
            if (tag != .class_method and tag != .method_signature) continue;
            const d = c.tree.nodeData(decl);
            const sig = try c.signatureOfProto(decl, d.lhs, true, false);
            if (c.ts.fnParamCount(sig) > 0) return c.ts.fnParam(sig, 0).ty;
        }
        return types.any_type;
    }
    // Property: class_field / property_signature / ctor param property.
    for (decls) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .class_field => {
                const e = c.tree.extraData(ast.Field, d.lhs);
                if (e.type_ann != 0) {
                    const ok = e.flags & ast.Flags.static != 0 and e.flags & ast.Flags.readonly != 0;
                    return c.annTypeMaybeUnique(e.type_ann, ok, 1331, c.tokSpan(c.tree.nodeMainToken(decl)));
                }
                if (e.init != 0) {
                    // The initializer is being typed to *build* the class's
                    // instance type; any function body inside it must not be
                    // walked until that type exists (see `DeferredBody`).
                    c.defer_bodies += 1;
                    defer c.defer_bodies -= 1;
                    const instance = e.flags & ast.Flags.static == 0;
                    if (instance) c.instance_field_init_depth += 1;
                    defer if (instance) {
                        c.instance_field_init_depth -= 1;
                    };
                    return c.widenLiteral(try c.checkExprCached(e.init, types.no_type));
                }
                return types.any_type;
            },
            .property_signature => {
                if (d.lhs != 0) {
                    const ok = d.rhs & ast.Flags.readonly != 0;
                    return c.annTypeMaybeUnique(d.lhs, ok, 1330, c.tokSpan(c.tree.nodeMainToken(decl)));
                }
                return types.any_type;
            },
            .param, .param_full => {
                const p = try paramInfo(c, decl, 0, types.no_type, false);
                return p.ty;
            },
            else => {},
        }
    }
    return types.any_type;
}
