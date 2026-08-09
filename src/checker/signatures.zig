//! Signatures, symbol typing, and imported symbols.
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
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const FileId = checker_zig.FileId;
const check = checker_zig.check;
const DeferredBody = checker_zig.DeferredBody;

const PathElem = @import("flow.zig").PathElem;
const RefKey = @import("flow.zig").RefKey;
const argumentsMatch = @import("calls.zig").argumentsMatch;
const assignNarrows = @import("flow.zig").assignNarrows;
const checkDeclarator = @import("stmts.zig").checkDeclarator;
const checkExpr = @import("expr.zig").checkExpr;
const checkExprCached = @import("expr.zig").checkExprCached;
const checkForInOf = @import("stmts.zig").checkForInOf;
const checkFunctionBody = @import("stmts.zig").checkFunctionBody;
const checkFunctionLikeExpr = @import("expr.zig").checkFunctionLikeExpr;
const checkObjectLiteral = @import("expr.zig").checkObjectLiteral;
const classStaticType = @import("enums.zig").classStaticType;
const containsAtom = @import("expr.zig").containsAtom;
const containsTypeParam = @import("enums.zig").containsTypeParam;
const drainDeferredBodies = @import("stmts.zig").drainDeferredBodies;
const eraseTypeParams = @import("assign.zig").eraseTypeParams;
const expandRef = @import("instantiate.zig").expandRef;
const finalizeInferredReturn = @import("names.zig").finalizeInferredReturn;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const identIsSym = @import("flow.zig").identIsSym;
const interfaceGeneric = @import("instantiate.zig").interfaceGeneric;
const max_deep_ref_depth = @import("flow.zig").max_deep_ref_depth;
const narrowByCondition = @import("flow.zig").narrowByCondition;
const narrowByGuardCall = @import("flow.zig").narrowByGuardCall;
const run = Checker.run;
const this_flow_root = @import("flow.zig").this_flow_root;
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
            if (c.thisParamAnn(pn)) |ann_node| {
                this_ty = if (ann_node != 0) try c.typeFromTypeNode(ann_node) else types.any_type;
                if (this_ty == types.no_type) this_ty = types.any_type;
                continue;
            }
        }
        const p = try c.paramInfo(pn, pi, ctx_sig, report_implicit);
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
                !try c.paramInitCanBeUndefined(pn))
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
        const p = try c.predicateFromNode(proto.return_type, params.items);
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
            const payload = try c.awaitedType(try c.inferReturnType(node, c.tree.nodeData(node).rhs, if (ret_ctx != types.no_type) try c.awaitedType(ret_ctx) else types.no_type));
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
            ret = try c.inferGeneratorReturn(node, c.tree.nodeData(node).rhs);
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
        ret = try c.inferReturnType(node, c.tree.nodeData(node).rhs, ret_ctx);
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
        pred = try c.inferredPredicate(params.items, ret, c.tree.nodeData(node).rhs);
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
pub fn inferredPredicate(c: *Checker, params: []const types.Param, ret: TypeId, body: Node) Error!?types.Predicate {
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
        const true_ty = try c.narrowByGuardExpr(declared, guard, sense, key, 0, declared);
        if (true_ty == declared or c.ts.kind(true_ty) == .never) continue;
        const false_ty = try c.narrowByGuardExpr(declared, guard, !sense, key, 0, declared);
        // Soundness: the false branch must fully exclude the narrowed type.
        if (try c.typesOverlap(true_ty, false_ty)) continue;
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
pub fn narrowByGuardExpr(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey, depth: u32, decl: TypeId) Error!TypeId {
    if (cond == null_node or depth > 8) return t;
    const d = c.tree.nodeData(cond);
    switch (c.nodeTag(cond)) {
        .paren_expr => return c.narrowByGuardExpr(t, d.lhs, sense, key, depth + 1, decl),
        .prefix_unary => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(cond)) != .bang)
                return t;
            return c.narrowByGuardExpr(t, d.lhs, !sense, key, depth + 1, decl);
        },
        .binary => switch (c.tree.tokens.tag(c.tree.nodeMainToken(cond))) {
            .amp_amp => {
                const a_true = try c.narrowByGuardExpr(t, d.lhs, true, key, depth + 1, decl);
                if (sense) return c.narrowByGuardExpr(a_true, d.rhs, true, key, depth + 1, decl);
                const a_false = try c.narrowByGuardExpr(t, d.lhs, false, key, depth + 1, decl);
                const b_false = try c.narrowByGuardExpr(a_true, d.rhs, false, key, depth + 1, decl);
                return c.makeUnion2(a_false, b_false);
            },
            .pipe_pipe => {
                const a_false = try c.narrowByGuardExpr(t, d.lhs, false, key, depth + 1, decl);
                if (!sense) return c.narrowByGuardExpr(a_false, d.rhs, false, key, depth + 1, decl);
                const a_true = try c.narrowByGuardExpr(t, d.lhs, true, key, depth + 1, decl);
                const b_true = try c.narrowByGuardExpr(a_false, d.rhs, true, key, depth + 1, decl);
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
pub fn thisParamAnn(c: *Checker, pn: Node) ?Node {
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
pub fn predicateFromNode(c: *Checker, node: Node, params: []const types.Param) Error!types.Predicate {
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

/// Mark optional every property of `t` that the object binding pattern
/// `pat` destructures WITH A DEFAULT.
///
/// tsc arrives here from the other side: the initializer of a
/// binding-pattern declaration is contextually typed by the pattern's
/// implied type — in which a destructured-with-default name is optional —
/// and `checkObjectLiteral`'s `contextualTypeHasPattern` branch copies that
/// `Optional` flag onto each matching literal property. The part of that
/// which the parameter's *type* depends on is exactly this flag transfer,
/// so it is done directly. (The other half of tsc's branch, TS2353 for an
/// initializer property the pattern does not name, is a separate
/// diagnostic and is not synthesized here.)
///
/// Only a plain object type is rewritten: an initializer that is not an
/// object literal (a union, a callable) keeps whatever it has.
pub fn optionalizePatternDefaults(c: *Checker, t: TypeId, pat: Node) Error!TypeId {
    if (pat == null_node or c.nodeTag(pat) != .object_pattern) return t;
    if (c.ts.kind(t) != .object) return t;
    if (c.ts.objectCallSigCount(t) != 0 or c.ts.objectConstructSigCount(t) != 0) return t;
    const n = c.ts.objectPropCount(t);
    if (n == 0) return t;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var changed = false;
    for (0..n) |i| {
        var p = c.ts.objectProp(t, @intCast(i));
        if (p.flags & types.prop_flag_optional == 0 and try c.patternDefaultsProp(pat, p.name)) {
            p.flags |= types.prop_flag_optional;
            changed = true;
        }
        try props.append(c.scratch(), p);
    }
    if (!changed) return t;
    return c.ts.makeObject(props.items, c.ts.objectStringIndex(t), c.ts.objectNumberIndex(t), c.ts.objectFlags(t));
}

/// Does the object binding pattern `pat` destructure `name` with a default?
pub fn patternDefaultsProp(c: *Checker, pat: Node, name: Atom) Error!bool {
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node or c.nodeTag(el) != .binding_property) continue;
        const ed = c.tree.nodeData(el);
        if (ed.rhs == 0) continue; // no default
        if ((try c.memberAtom(c.tree.nodeMainToken(el))) == name) return true;
    }
    return false;
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
pub fn paramInitCanBeUndefined(c: *Checker, pn: Node) Error!bool {
    if (c.nodeTag(pn) != .param_full) return false;
    const e = c.tree.extraData(ast.ParamFull, c.tree.nodeData(pn).rhs);
    if (e.init == 0) return false;
    c.side_query_depth += 1;
    defer c.side_query_depth -= 1;
    const it = try c.checkExprCached(e.init, types.no_type);
    return (try c.removeUndefined(it)) != it;
}

pub fn paramInfo(c: *Checker, pn: Node, index: u32, ctx_sig: TypeId, report_implicit: bool) Error!types.Param {
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
    if (type_ann != 0) {
        ty = try c.typeFromTypeNode(type_ann);
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
        ty = try c.optionalizePatternDefaults(ty, name_node);
    } else if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function) {
        if (try c.paramTypeAt(ctx_sig, index)) |ct| ty = ct;
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
pub fn inferReturnType(c: *Checker, fn_node: Node, body: Node, ret_ctx: TypeId) Error!TypeId {
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
    if (c.nodeTag(body) != .block) {
        const raw = try c.checkExprCached(body, ret_ctx);
        if (ret_ctx != types.no_type) return c.widenToContext(raw, ret_ctx);
        return c.finalizeInferredReturn(try c.widenReturnMember(raw));
    }
    var rets: std.ArrayList(Node) = .empty;
    defer rets.deinit(c.scratch());
    var ret_scopes: std.ArrayList(ScopeId) = .empty;
    defer ret_scopes.deinit(c.scratch());
    var bare_return = false;
    // Base scope for the body: a function/arrow body block binds its
    // statements directly in the function scope (no separate block scope),
    // so start from the function's own scope.
    const base_scope = (try c.scopeOf(fn_node)) orelse c.cur_scope;
    for (c.tree.nodeRange(body)) |stmt| {
        if (stmt != null_node) try c.collectReturns(stmt, &rets, &ret_scopes, &bare_return, base_scope);
    }
    if (rets.items.len == 0) {
        // A block body with no `return` at all whose endpoint is
        // UNREACHABLE never produces a value: tsc infers `never`, not
        // `void` (`getReturnTypeFromBody` → `functionHasImplicitReturn`).
        // `() => { throw new Error(…); }` is therefore usable wherever a
        // `() => [number, string]` is wanted; typed `void` it was a
        // phantom TS2322/TS2345 at every such callback.
        if (c.stmtListTerminal(c.tree.nodeRange(body))) return types.never_type;
        return types.void_type;
    }
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    // Each return expression is resolved in the scope where its `return`
    // statement lives (a return inside a try/if/loop block sees that
    // block's locals), not the ambient scope of this type probe.
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    for (rets.items, ret_scopes.items) |r, sc| {
        c.cur_scope = sc;
        try parts.append(c.scratch(), try c.checkExprCached(r, ret_ctx));
    }
    if (bare_return or !c.stmtListTerminal(c.tree.nodeRange(body))) {
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
pub fn inferGeneratorReturn(c: *Checker, fn_node: Node, body: Node) Error!TypeId {
    const gen_sym = c.prog.globals.lookup(c.atom_Generator) orelse return types.any_type;
    if (!c.symFlags(gen_sym).interface) return types.any_type;
    if (c.nodeTag(body) != .block) return types.any_type;

    var yields: std.ArrayList(Node) = .empty;
    defer yields.deinit(c.scratch());
    var yield_scopes: std.ArrayList(ScopeId) = .empty;
    defer yield_scopes.deinit(c.scratch());
    var bare_yield = false;
    var delegated = false;
    const base_scope = (try c.scopeOf(fn_node)) orelse c.cur_scope;
    for (c.tree.nodeRange(body)) |stmt| {
        if (stmt != null_node) try c.collectYields(stmt, &yields, &yield_scopes, &bare_yield, &delegated, base_scope);
    }
    if (delegated) return types.any_type;

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
        for (yields.items, yield_scopes.items) |y, sc| {
            c.cur_scope = sc;
            try parts.append(c.scratch(), try c.widenLiteral(try c.checkExprCached(y, types.no_type)));
        }
        if (bare_yield) try parts.append(c.scratch(), types.undefined_type);
        yield_ty = try c.ts.makeUnion(c.scratch(), parts.items);
    }
    const ret_ty = try c.inferReturnType(fn_node, body, types.no_type);
    return c.ts.makeRef(gen_sym, &.{ yield_ty, ret_ty, types.unknown_type });
}

pub fn collectYields(c: *Checker, node: Node, out: *std.ArrayList(Node), out_scopes: *std.ArrayList(ScopeId), bare: *bool, delegated: *bool, scope: ScopeId) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        .yield_expr => {
            const d = c.tree.nodeData(node);
            if (d.rhs != 0) {
                delegated.* = true;
                return;
            }
            if (d.lhs != 0) {
                try out.append(c.scratch(), d.lhs);
                try out_scopes.append(c.scratch(), scope);
            } else bare.* = true;
        },
        // Don't descend into nested functions/classes: their yields belong
        // to them (and only a generator may contain one at all).
        .arrow_fn, .function_expr, .function_decl, .class_decl, .class_method => return,
        else => {},
    }
    const inner = (try c.scopeOf(node)) orelse scope;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try c.collectYields(child, out, out_scopes, bare, delegated, inner);
}

pub fn collectReturns(c: *Checker, node: Node, out: *std.ArrayList(Node), out_scopes: ?*std.ArrayList(ScopeId), bare: *bool, scope: ScopeId) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        .return_stmt => {
            const d = c.tree.nodeData(node);
            if (d.lhs != 0) {
                try out.append(c.scratch(), d.lhs);
                if (out_scopes) |os| try os.append(c.scratch(), scope);
            } else bare.* = true;
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
    while (it.next()) |child| try c.collectReturns(child, out, out_scopes, bare, inner);
}

// =====================================================================
// symbol typing
// =====================================================================

pub fn typeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return types.any_type;
    if (c.sym_state.items[sym] == .computed) return c.sym_types.items[sym];
    if (c.sym_state.items[sym] == .in_progress) return types.any_type; // circular
    c.sym_state.items[sym] = .in_progress;
    const t = c.computeTypeOfSymbol(sym) catch |err| {
        c.sym_state.items[sym] = .not_computed;
        return err;
    };
    c.sym_types.items[sym] = t;
    c.sym_state.items[sym] = .computed;
    return t;
}

pub fn setTypeOfSymbol(c: *Checker, sym: SymbolId, t: TypeId) void {
    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) return;
    if (c.sym_state.items[sym] == .computed) return;
    c.sym_types.items[sym] = t;
    c.sym_state.items[sym] = .computed;
}

pub fn computeTypeOfSymbol(c: *Checker, sym: SymbolId) Error!TypeId {
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
            if (try c.mergedFunctionValue(m.parts)) |ft| {
                return c.ts.makeIntersection(c.scratch(), &.{ ft, ns_val });
            }
            for (m.parts) |p| {
                const pf = c.symFlags(p);
                if (pf.function or pf.enum_decl or pf.class) {
                    ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.typeOfSymbol(p), ns_val });
                    break;
                }
                if (pf.var_decl or pf.let_decl or pf.const_decl) {
                    ns_val = try c.ts.makeIntersection(c.scratch(), &.{ try c.variableSymbolType(p), ns_val });
                    break;
                }
            }
            return ns_val;
        }
        // A global function declared in more than one file (lib.dom's
        // `setInterval(): number` + @types/node's `global{}`
        // `setInterval(): NodeJS.Timeout`) merges into one overload set,
        // node's signatures first — see `mergedFunctionValue`.
        if (try c.mergedFunctionValue(m.parts)) |ft| return ft;
        // A callable class split across files (`class C` here, `function C`
        // overloads there): keep both signature sets, call side first, the
        // same shape the same-file merge takes in `callableClassValue`.
        if (m.flags.class and m.flags.function) {
            var cls: TypeId = types.no_type;
            var fnv: TypeId = types.no_type;
            for (m.parts) |p| {
                const pf = c.symFlags(p);
                if (pf.class and cls == types.no_type) cls = try c.ts.makeClassValue(p);
                if (pf.function and fnv == types.no_type) fnv = try c.functionSymbolType(p);
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
    if (f.import_binding) return c.importedSymbolType(sym);
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
            return c.ts.makeIntersection(c.scratch(), &.{ try c.functionSymbolType(sym), ns_val });
        }
        if (f.function) return c.ts.makeIntersection(c.scratch(), &.{ try c.functionSymbolType(sym), ns_val });
        if (f.enum_decl) return c.ts.makeIntersection(c.scratch(), &.{ try c.enumValueType(sym), ns_val });
        // Same-file `var X: T` + `namespace X {…}` (a namespace merged onto a
        // typed global within one file): keep T's members.
        if (f.var_decl or f.let_decl or f.const_decl)
            return c.ts.makeIntersection(c.scratch(), &.{ try c.variableSymbolType(sym), ns_val });
        return ns_val;
    }
    if (f.enum_decl) return c.enumValueType(sym);
    if (f.class) return c.callableClassValue(sym, f);
    if (f.function) return c.withExpandoProps(sym, try c.functionSymbolType(sym));
    if (f.expando_member) return c.expandoMemberType(sym);
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
                    const p = try c.paramInfo(decl, 0, types.no_type, false);
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
        return c.withExpandoProps(sym, try c.variableSymbolType(sym));
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
pub fn callableClassValue(c: *Checker, sym: SymbolId, f: binder.SymbolFlags) Error!TypeId {
    const cls = try c.ts.makeClassValue(sym);
    if (!f.function) return cls;
    return c.ts.makeIntersection(c.scratch(), &.{ try c.functionSymbolType(sym), cls });
}

/// Fold a function value's *expando* properties into its type: the
/// callable base intersected with an object of the `fn.prop = value`
/// declarations the binder collected (TS 3.1 properties-on-functions).
/// A pass-through for the overwhelming majority of symbols, which have
/// none. tsc models this as one anonymous type carrying both the call
/// signatures and the members; the intersection is the same shape ztsc
/// already uses for a function merged with a namespace.
pub fn withExpandoProps(c: *Checker, sym: SymbolId, base: TypeId) Error!TypeId {
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
pub fn expandoMemberType(c: *Checker, sym: SymbolId) Error!TypeId {
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
/// one overload set — in DECLARATION order, with the split point recorded
/// in `overload_rotate` for the call path. Returns null when fewer than two
/// constituents are callable (the overwhelmingly common single-contributor
/// global keeps its type via the caller's existing first-value-constituent
/// path).
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
/// answer with the node signature).
///
/// Overload RESOLUTION does not use that order. `resolveCall` runs the list
/// through `reorderCandidates` first, which groups the signatures by
/// declaring parent and moves each later group ahead of the earlier ones,
/// keeping the order within a group. With two groups that is a swap: node's
/// signatures are tried first and lib.dom's last, which is why
/// `setTimeout(() => {}, 1)` is a `NodeJS.Timeout` while
/// `setTimeout(someString, 1)` — which only lib.dom accepts — is a `number`,
/// and why a call that matches NEITHER (`fetch(url, { body: aSharedBuffer })`)
/// is TS2769 rather than a bare argument error.
///
/// Keeping only the non-lib group, as this did before, got the call site
/// right and everything else wrong: one signature can never be an overload
/// set, so a call matching no signature reported the failing argument
/// instead of TS2769, and a call only the library signature accepts failed
/// outright.
pub fn mergedFunctionValue(c: *Checker, parts: []const u32) Error!?TypeId {
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
    // Declaration order: the library group, then the augmenting group.
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    for (lib.items) |o| {
        if (c.ts.kind(o) == .overloads) {
            for (c.ts.members(o)) |mm| try sigs.append(c.scratch(), mm);
        } else try sigs.append(c.scratch(), o);
    }
    const split: u32 = @intCast(sigs.items.len);
    for (nonlib.items) |o| {
        if (c.ts.kind(o) == .overloads) {
            for (c.ts.members(o)) |mm| try sigs.append(c.scratch(), mm);
        } else try sigs.append(c.scratch(), o);
    }
    if (sigs.items.len == 1) return sigs.items[0];
    const t = try c.ts.makeOverloads(sigs.items);
    if (split != 0 and split != sigs.items.len) {
        try c.overload_rotate.put(c.cm(), t, split);
    }
    return t;
}

/// Append `ov`'s call signatures in overload-RESOLUTION order — tsc's
/// `reorderCandidates`. Identical to the stored member order except for a
/// merged global function, where the last declaration group is tried
/// first (see `mergedFunctionValue`).
pub fn appendOverloadCandidates(c: *Checker, out: *std.ArrayList(TypeId), ov: TypeId) Error!void {
    const ms = try c.memberList(ov);
    const rot = c.overload_rotate.get(ov) orelse 0;
    if (rot == 0 or rot >= ms.len) {
        try out.appendSlice(c.scratch(), ms);
        return;
    }
    try out.appendSlice(c.scratch(), ms[rot..]);
    try out.appendSlice(c.scratch(), ms[0..rot]);
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
pub fn variableSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
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
        const t = try c.declaratorType(sym, decl, is_const);
        if (t != types.no_type) return t;
    }
    return types.any_type;
}

// =====================================================================
// imported symbols
// =====================================================================

/// Value type of an import binding, via the sealed link tables.
pub fn importedSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
    return c.targetValueType(tgt);
}

/// The VALUE half of a `.dual` binding: property `name` of the export-assigned
/// value's type, or null when that value's type has no such property (the
/// binding then has only the meanings its `type_tgt` carries).
pub fn dualValueType(c: *Checker, d: modules.DualTarget) Error!?TypeId {
    const v = d.value_tgt;
    const base = try c.typeOfSymbol(c.toGlobalIn(v.file, v.payload));
    const p = (try c.propOfType(base, v.name)) orelse return null;
    return p.ty;
}

/// True when a `.dual` binding really does have a value meaning through its
/// export-assigned value's type. Lets a value-position reference decide
/// between "both meanings" and "type meaning only" (TS2693).
pub fn dualHasValue(c: *Checker, tgt: modules.Target) Error!bool {
    if (tgt.kind != .dual) return false;
    return (try c.dualValueType(c.prog.dual_targets[tgt.payload])) != null;
}

pub fn targetValueType(c: *Checker, tgt: modules.Target) Error!TypeId {
    switch (tgt.kind) {
        .any => return types.any_type,
        .binding => return c.typeOfSymbol(c.toGlobalIn(tgt.file, tgt.payload)),
        .namespace => return c.namespaceObjectType(tgt.file),
        .ambient_ns => return c.ambientNamespaceType(tgt.payload),
        // `import { X } from "m"` where `m` is `export = <value>` and `X`
        // is a property of that value's TYPE. A missing property stays
        // `any` (the link phase could not have known, and the lenient
        // fallback it replaces was `any` too).
        .export_equals_prop => {
            const base = try c.typeOfSymbol(c.toGlobalIn(tgt.file, tgt.payload));
            const p = (try c.propOfType(base, tgt.name)) orelse return types.any_type;
            return p.ty;
        },
        // Both meanings available (tsc's `combineValueAndTypeSymbols`): the
        // VALUE meaning is the property of the export-assigned value's type.
        // The link phase could not check that the property exists, so a miss
        // falls back to the member's own value meaning — which is what the
        // binding resolved to before the dual existed.
        .dual => {
            const d = c.prog.dual_targets[tgt.payload];
            if (try c.dualValueType(d)) |t| return t;
            return c.targetValueType(d.type_tgt);
        },
        .default_expr => {
            const saved = c.saveCtx();
            defer c.restoreCtx(saved);
            c.setFile(tgt.file);
            c.cur_scope = binder.file_scope;
            const inner = c.tree.nodeData(tgt.payload).lhs;
            switch (c.nodeTag(inner)) {
                .function_decl => return c.signatureOfProto(inner, c.tree.nodeData(inner).lhs, false, true),
                // Unnamed `export default class`: documented cut.
                .class_decl => return types.any_type,
                else => return c.widenLiteral(try c.checkExprCached(inner, types.no_type)),
            }
        },
    }
}

/// The module namespace object of `file` (`import * as ns`): one
/// read-only property per value-space export. Type-space-only exports
/// (interfaces, aliases, `export type`) are omitted — accessing them
/// as values is a property error, close to tsc's behavior. Cycle-safe.
pub fn namespaceObjectType(c: *Checker, file: FileId) Error!TypeId {
    if (c.ns_types.get(file)) |t| {
        if (t == types.no_type) return types.any_type; // ns cycle
        return t;
    }
    try c.ns_types.put(c.cm(), file, types.no_type);
    // `export = X` module (e.g. `@types/react` `export = React`): the value
    // namespace object is the value type of the export-equals target, not an
    // empty object built from the (absent) named exports. `typeof
    // import("react").createContext` must reach React's members.
    if (c.prog.links.len != 0) {
        if (c.prog.links[file].exportTarget(c.prog.export_equals_atom)) |eq| {
            if (!eq.type_only) {
                const t = try c.targetValueType(eq);
                try c.ns_types.put(c.cm(), file, t);
                return t;
            }
        }
    }
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (c.prog.links.len != 0) {
        const l = &c.prog.links[file];
        for (l.export_atoms, l.export_targets) |name, tgt| {
            if (name == c.prog.export_equals_atom) continue; // reserved key
            if (tgt.type_only) continue;
            var ty: TypeId = types.any_type;
            switch (tgt.kind) {
                .binding => {
                    const g0 = c.toGlobalIn(tgt.file, tgt.payload);
                    // A cross-file `declare module` augmentation may have
                    // merged this export (`namespace control` + a plugin's
                    // `namespace control { sideBySide }`): use the merged
                    // view so `L.control.sideBySide` resolves.
                    const g = c.prog.mergedOf(g0) orelse g0;
                    const f = c.symFlags(g);
                    if (!hasValueMeaning(f)) continue;
                    ty = try c.typeOfSymbol(g);
                },
                .namespace => ty = try c.namespaceObjectType(tgt.file),
                .ambient_ns => ty = try c.ambientNamespaceType(tgt.payload),
                .default_expr, .export_equals_prop => ty = try c.targetValueType(tgt),
                // A re-exported dual contributes to the namespace object
                // through its value half. Without one it falls back to the
                // member, which — being a type-only interface in the shape
                // that motivates duals — is then omitted like any other.
                .dual => {
                    const d = c.prog.dual_targets[tgt.payload];
                    if (try c.dualValueType(d)) |vt| {
                        ty = vt;
                    } else if (c.targetTypeSym(d.type_tgt)) |g| {
                        if (!hasValueMeaning(c.symFlags(g))) continue;
                        ty = try c.typeOfSymbol(g);
                    } else {
                        ty = try c.targetValueType(d.type_tgt);
                    }
                },
                .any => {},
            }
            try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
        }
    }
    // Cross-package `declare module "M" { const drawLocal … }` value
    // augmentations add fresh exports to M's namespace object that have no
    // constituent in M's own export table (so no merge formed). Fold them
    // in: `import L from "leaflet"; L.drawLocal` (leaflet-draw augments
    // leaflet). Members already present as a real export are skipped (those
    // merge through the export-table path above).
    try c.appendAugmentedModuleExports(file, &props);
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.ns_types.put(c.cm(), file, obj);
    return obj;
}

/// Append value-space members contributed by cross-file `declare module`
/// augmentation blocks whose specifier resolves to `file`, for names not
/// already collected. Deterministic: files then block members in id order.
pub fn appendAugmentedModuleExports(c: *Checker, file: FileId, props: *std.ArrayList(types.Prop)) Error!void {
    for (c.prog.files, 0..) |*pf, fi| {
        const b = pf.bind;
        if (!b.is_module or b.ambient_modules.len == 0) continue;
        const base = c.prog.sym_base[fi];
        for (b.ambient_modules) |am| {
            const mfile = pf.specs.get(am.spec) orelse continue;
            if (mfile != file) continue;
            const lo = b.scope_members_start[am.scope];
            const hi = b.scope_members_start[am.scope + 1];
            for (lo..hi) |i| {
                const g = base + b.member_syms[i];
                const f = c.symFlags(g);
                if (!hasValueMeaning(f)) continue;
                const name = b.member_atoms[i];
                var dup = false;
                for (props.items) |p| {
                    if (p.name == name) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                var flags: u32 = types.prop_flag_readonly;
                if (!f.const_decl and !f.readonly_member) flags = 0;
                try props.append(c.scratch(), .{
                    .name = name,
                    .ty = try c.typeOfSymbol(c.prog.mergedOf(g) orelse g),
                    .flags = flags,
                });
            }
        }
    }
}

/// Namespace object of an ambient module (`import * as ns from "fs"`):
///  one read-only property per value-space export. Cycle-safe via
/// `ambient_ns_types`.
pub fn ambientNamespaceType(c: *Checker, idx: u32) Error!TypeId {
    if (c.ambient_ns_types.get(idx)) |t| {
        if (t == types.no_type) return types.any_type; // cycle
        return t;
    }
    try c.ambient_ns_types.put(c.cm(), idx, types.no_type);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    const ae = c.prog.ambient_exports[idx];
    for (ae.atoms, ae.targets) |name, tgt| {
        if (name == c.prog.export_equals_atom) continue; // reserved key
        if (tgt.type_only) continue;
        const ty = try c.targetValueType(tgt);
        try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
    }
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.ambient_ns_types.put(c.cm(), idx, obj);
    return obj;
}

/// Type of one variable declarator for `sym` (no_type if this decl
/// contributes none, e.g. bare `declarator` in a multi-decl symbol).
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
/// keeps its literal types (`regular`, not `widenLiteral`), but an
/// initializer that is a union of *fresh object literals* — `cond ? {a} :
/// {b}`, `x || {b}` — is still one widening context and gets the
/// sibling-`undefined` normalization either way.
pub fn widenInitializer(c: *Checker, init_t: TypeId, is_const: bool) Error!TypeId {
    const norm = try c.normalizeFreshObjectSiblings(init_t);
    return if (is_const) c.ts.regular(norm) else c.widenLiteral(norm);
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
pub fn forHeadBindingType(c: *Checker, sym: SymbolId) Error!?TypeId {
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

pub fn declaratorType(c: *Checker, sym: SymbolId, decl: Node, is_const: bool) Error!TypeId {
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
            const et = (try c.forHeadBindingType(sym)) orelse return types.any_type;
            if (c.nodeTag(d.lhs) == .identifier) return et;
            return c.bindingElementType(sym, decl, et);
        },
        .declarator_init => {
            if (try freshSymbolConstType(c, decl, d.lhs, d.rhs, is_const)) |u| return u;
            const init_t = try c.checkExprCached(d.rhs, types.no_type);
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

/// Pin every symbol bound by a destructured parameter's pattern to the type
/// the parameter (contextual or annotated) gives it. The counterpart of the
/// named-parameter pin in `signatureOfProtoCtx`: without it those symbols
/// have no pinned type and `computeTypeOfSymbol` re-derives them from the
/// declaration alone, with no contextual signature to read.
///
/// Each binding's type comes from `bindingElementType`, the same walk
/// `computeTypeOfSymbol` would use, so optional properties, defaults, and
/// object/array rests behave identically — only the starting `whole` is
/// better. `force` mirrors the named case: a contextual signature
/// overwrites, because the same arrow is materialized once per overload
/// candidate and the last materialization is the one the body is checked
/// under.
pub fn pinPatternParamSyms(c: *Checker, pn: Node, pat: Node, whole: TypeId, force: bool) Error!void {
    if (pat == null_node) return;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .identifier => try c.pinBindingSym(pn, try c.atomOfToken(c.tree.nodeMainToken(pat)), whole, force),
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    .binding_property => {
                        if (ed.lhs != 0) {
                            try c.pinPatternParamSyms(pn, ed.lhs, whole, force);
                        } else {
                            try c.pinBindingSym(pn, try c.memberAtom(c.tree.nodeMainToken(el)), whole, force);
                        }
                    },
                    .rest_element => try c.pinPatternParamSyms(pn, ed.lhs, whole, force),
                    else => {},
                }
            }
        },
        .array_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node or c.nodeTag(el) == .omitted) continue;
                try c.pinPatternParamSyms(pn, el, whole, force);
            }
        },
        .binding_default, .rest_element => try c.pinPatternParamSyms(pn, d.lhs, whole, force),
        else => {},
    }
}

pub fn pinBindingSym(c: *Checker, pn: Node, name: Atom, whole: TypeId, force: bool) Error!void {
    const psym = c.bind.lookupInScope(c.cur_scope, name) orelse return;
    if (!c.bind.symbol_flags[psym].param) return;
    const gsym = c.toGlobal(psym);
    if (gsym == binder.no_symbol or gsym >= c.sym_types.items.len) return;
    if (!force and c.sym_state.items[gsym] == .computed) return;
    // Re-entrancy: `bindingElementType` checks the pattern's defaults, which
    // can read this very symbol. Leave the slot alone while computing.
    if (c.sym_state.items[gsym] == .in_progress) return;
    const saved = c.sym_state.items[gsym];
    c.sym_state.items[gsym] = .in_progress;
    const t = c.bindingElementType(gsym, pn, whole) catch |err| {
        c.sym_state.items[gsym] = saved;
        return err;
    };
    c.sym_types.items[gsym] = t;
    c.sym_state.items[gsym] = .computed;
}

/// Type of `sym` when bound by a destructuring pattern whose whole
/// value has type `whole`: walk the pattern to the binding position.
pub fn bindingElementType(c: *Checker, sym: SymbolId, decl: Node, whole: TypeId) Error!TypeId {
    const d = c.tree.nodeData(decl);
    const pattern: Node = switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full, .param, .param_full => d.lhs,
        else => decl,
    };
    const name = c.symNameAtom(sym);
    var result: TypeId = types.any_type;
    _ = try c.findBindingType(pattern, name, whole, &result, try c.bindingFlowBase(sym, decl));
    return result;
}

/// A destructured binding inherits the NARROWING of the property it comes
/// from: `const { multiElement } = this.state` inside `if
/// (this.state.multiElement)` binds the narrowed, non-null type. tsc builds
/// a synthetic `<initializer>["prop"]` element access carrying the
/// declaration's flow node and asks `getFlowTypeOfReference` about it
/// (`getFlowTypeOfDestructuring`); the equivalent here is to extend the
/// initializer's reference key by each pattern link and query the flow graph
/// at the declaration.
///
/// Only when the initializer is itself a tracked reference and the
/// declaration lives in the file being checked — a cross-file symbol is
/// never flow-narrowed, and its flow ids belong to another graph.
pub const BindFlow = struct { node: Node, key: RefKey };

pub fn bindingFlowBase(c: *Checker, sym: SymbolId, decl: Node) Error!?BindFlow {
    if (c.symFile(sym) != c.cur_file) return null;
    const d = c.tree.nodeData(decl);
    const init_node: Node = switch (c.nodeTag(decl)) {
        .declarator_init => d.rhs,
        .declarator_full => c.tree.extraData(ast.DeclaratorFull, d.rhs).init,
        else => return null,
    };
    if (init_node == null_node) return null;
    const key = (try c.buildRefKey(init_node)) orelse return null;
    return .{ .node = init_node, .key = key };
}

/// The reference key one pattern link deeper, or null when the path would
/// exceed the tracked depth (sound under-narrowing).
pub fn extendRefKey(c: *Checker, base: RefKey, elem: PathElem) Error!?RefKey {
    if (base.len >= max_deep_ref_depth) return null;
    var elems: [max_deep_ref_depth]PathElem = undefined;
    var buf: [max_deep_ref_depth]PathElem = undefined;
    const path = c.refPath(&base, &buf);
    @memcpy(elems[0..path.len], path);
    elems[path.len] = elem;
    return c.makeRefKey(base.sym, elems[0 .. path.len + 1]);
}

pub fn findBindingType(c: *Checker, pat: Node, name: Atom, whole: TypeId, out: *TypeId, bf: ?BindFlow) Error!bool {
    if (pat == null_node) return false;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .identifier => {
            if ((try c.atomOfToken(c.tree.nodeMainToken(pat))) == name) {
                out.* = whole;
                return true;
            }
            return false;
        },
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    .binding_property => {
                        const key = try c.memberAtom(c.tree.nodeMainToken(el));
                        var pt: TypeId = types.any_type;
                        if (try c.propOfType(try c.resolveStructural(whole), key)) |p| {
                            pt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                        }
                        // Inherit the narrowing of `<initializer>.key` at the
                        // declaration (see `bindingFlowBase`).
                        var sub_bf: ?BindFlow = null;
                        if (bf) |b| {
                            if (PathElem.memberFits(key)) {
                                if (try c.extendRefKey(b.key, .member(key))) |k| {
                                    pt = try c.flowTypeOfKey(b.node, k, pt);
                                    sub_bf = .{ .node = b.node, .key = k };
                                }
                            }
                        }
                        if (ed.rhs != 0) pt = try c.removeUndefined(pt); // default strips undefined
                        if (ed.lhs != 0) {
                            if (try c.findBindingType(ed.lhs, name, pt, out, sub_bf)) return true;
                        } else if (key == name) {
                            out.* = pt;
                            return true;
                        }
                    },
                    .binding_property_computed => {
                        // `{[k]: v}` → `v: whole[typeof k]` (tsc's
                        // `getIndexedAccessType` over the computed key). A
                        // non-literal key lands on the index signature, which
                        // is what `Record<string, T>` destructuring wants.
                        var pt: TypeId = types.any_type;
                        if (ed.lhs != 0) {
                            const kt = try c.checkExprCached(ed.lhs, types.no_type);
                            pt = try c.indexedAccessType(try c.resolveStructural(whole), kt);
                        }
                        if (try c.findBindingType(ed.rhs, name, pt, out, null)) return true;
                    },
                    .rest_element => {
                        // `{a, b, ...rest}` → rest = `whole` minus the
                        // sibling-named keys (tsc's object rest type,
                        // `Omit<whole, "a"|"b">`). Binding it to the whole
                        // object wrongly kept the destructured props, which
                        // then read as duplicated by a later spread (TS2783).
                        const rest_ty = try c.objectRestType(whole, pat);
                        if (try c.findBindingType(ed.lhs, name, rest_ty, out, null)) return true;
                    },
                    else => {},
                }
            }
            return false;
        },
        .array_pattern => {
            const r = try c.resolveStructural(whole);
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted) continue;
                var et: TypeId = types.any_type;
                switch (c.ts.kind(r)) {
                    .array => et = c.ts.arrayElem(r),
                    .tuple => {
                        if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                    },
                    else => {},
                }
                if (c.nodeTag(el) == .rest_element) {
                    const ed = c.tree.nodeData(el);
                    const rest_t = try c.ts.makeArray(et);
                    if (try c.findBindingType(ed.lhs, name, rest_t, out, null)) return true;
                } else if (c.nodeTag(el) == .binding_default) {
                    const ed = c.tree.nodeData(el);
                    if (try c.findBindingType(ed.lhs, name, try c.removeUndefined(et), out, null)) return true;
                } else {
                    if (try c.findBindingType(el, name, et, out, null)) return true;
                }
            }
            return false;
        },
        .binding_default => return c.findBindingType(d.lhs, name, whole, out, bf),
        .rest_element => return c.findBindingType(d.lhs, name, whole, out, null),
        else => return false,
    }
}

/// Object binding-pattern rest type: `whole` with every key named by a
/// sibling `binding_property` in `pat` removed (tsc's `{a, ...rest}` →
/// `rest = Omit<whole, "a">`). Objects and intersections of objects are
/// filtered (index signatures preserved); anything else (unions, generics,
/// `any`) falls back to `whole` unchanged — lenient, matching how the rest
/// of the checker treats non-enumerable shapes.
pub fn objectRestType(c: *Checker, whole: TypeId, pat: Node) Error!TypeId {
    const r = try c.resolveStructural(whole);
    const kind = c.ts.kind(r);
    if (kind != .object and kind != .intersection) return whole;

    var excluded: std.ArrayList(Atom) = .empty;
    defer excluded.deinit(c.scratch());
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        if (c.nodeTag(el) == .binding_property) {
            try excluded.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(el)));
        }
    }

    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var sidx: TypeId = 0;
    var nidx: TypeId = 0;
    // Flatten one level: a plain object contributes its own props; an
    // intersection contributes each object member's props (later members
    // win on a name clash, mirroring intersection member order). A member
    // that is not a plain object makes the shape non-enumerable → bail to
    // `whole` rather than drop constraints.
    const members: []const TypeId = if (kind == .intersection) try c.memberList(r) else &.{r};
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .object) return whole;
        if (c.ts.objectStringIndex(rm) != 0) sidx = c.ts.objectStringIndex(rm);
        if (c.ts.objectNumberIndex(rm) != 0) nidx = c.ts.objectNumberIndex(rm);
        for (0..c.ts.objectPropCount(rm)) |i| {
            const p = c.ts.objectProp(rm, @intCast(i));
            if (containsAtom(excluded.items, p.name)) continue;
            var replaced = false;
            for (props.items) |*existing| {
                if (existing.name == p.name) {
                    existing.* = p;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try props.append(c.scratch(), p);
        }
    }
    return c.ts.makeObject(props.items, sidx, nidx, 0);
}

pub fn functionSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
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
fn reportMemberCycle(c: *Checker, cycle: []const SymbolId) Error!void {
    // A circle that only closed because an indexed access tsc defers was
    // taken eagerly is not tsc's circle — see `lazy_index_objs`.
    for (c.lazy_index_objs.items) |obj| {
        if (try c.containsTypeParam(obj)) return;
    }
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
    // reserved-signature slot, `p = this.p` through both. Every one of
    // those cuts the recursion *below* this frame (the caller's not-found
    // path / the placeholder signature) and stays silent; naming the circle
    // is this report. Detection only — the cut, and therefore termination,
    // is exactly as before.
    for (c.member_type_stack.items, 0..) |m, i| {
        if (m != sym) continue;
        try reportMemberCycle(c, c.member_type_stack.items[i..]);
        break;
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
                if (tag == .class_method and d.rhs != 0) return c.inferReturnType(decl, d.rhs, types.no_type);
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
                const p = try c.paramInfo(decl, 0, types.no_type, false);
                return p.ty;
            },
            else => {},
        }
    }
    return types.any_type;
}
