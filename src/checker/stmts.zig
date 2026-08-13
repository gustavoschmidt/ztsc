//! Statements & declarations: variable declarations, loops, switches,
//! function bodies, classes, interfaces, aliases. Functions take the
//! `Checker` context as their first parameter.
//!
//! Three concerns the statement walk drives were split out and are
//! re-exported below so `Checker`'s method aliases keep resolving here:
//! `reachability.zig` (endpoint analysis), `iteration.zig` (the `for..of`
//! protocol), and `decorators.zig`.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const implicit_any = @import("implicit_any.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const prof_zig = checker_zig.prof_zig;
const Error = checker_zig.Error;
const max_instantiation_count = checker_zig.max_instantiation_count;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const baseClassRef = @import("instantiate.zig").baseClassRef;
const checkExprCached = @import("expr.zig").checkExprCached;
const classStaticType = @import("enums.zig").classStaticType;
const decorators = @import("decorators.zig");
const diagFmt = Checker.diagFmt;
const elaborate = @import("elaborate.zig");
const heritage = @import("heritage.zig");
const isNonPrimitiveKind = @import("assign.zig").isNonPrimitiveKind;
const isNullishUnion = @import("flow.zig").isNullishUnion;
const iteration = @import("iteration.zig");
const reachability = @import("reachability.zig");
const typeOfSymbol = @import("signatures.zig").typeOfSymbol;

// =====================================================================
// statements & declarations
// =====================================================================

pub fn checkStatement(c: *Checker, node: Node) Error!void {
    if (node == null_node) return;
    if (c.dprof.on) prof_zig.noteStmtEntry(c);
    // Baseline anchor for any TS2589 raised while materializing types in
    // this statement (refined to finer spans at expression / assignment
    // boundaries), and the source element the instantiation budget is
    // scoped to (`max_instantiation_count` — tsc's `checkSourceElement`
    // resets `instantiationCount` at exactly this point).
    // Profiler: the budget the *previous* source element spent is final at
    // exactly this point, where the next one resets it.
    if (c.prof.on and c.inst_count > 0) {
        const f, const sp = c.instSpanHere();
        prof_zig.noteStatement(c, f, sp.start, c.inst_count);
    }
    c.anchorInst(node);
    c.inst_count = 0;
    c.inst_budget = max_instantiation_count;
    c.newBudgetWindow();
    c.epoch_sym = 0; // this element's own budget (see `Checker.epoch_sym`)
    const d = c.tree.nodeData(node);
    const stmt_tag = c.nodeTag(node);
    // A class-position decorator applies to the class that immediately
    // follows it in the statement list (possibly through an `export`
    // wrapper). Any other statement means a preceding decorator had no
    // class target — drop the pending set so it can't attach to a later
    // class. (`export_default` can also wrap the decorated class.)
    switch (stmt_tag) {
        .decorator, .class_decl, .export_decl, .export_default => {},
        else => c.pending_class_decos.clearRetainingCapacity(),
    }
    switch (stmt_tag) {
        .block => {
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(node)) |s| c.cur_scope = s;
            for (c.tree.nodeRange(node)) |stmt| try c.checkStatement(stmt);
        },
        .var_decl_one, .var_decl => try checkVarDeclStatement(c, node),
        .expr_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
        .empty_stmt, .debugger_stmt, .error_node, .unsupported, .omitted => {},
        .if_stmt => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            try c.checkStatement(d.rhs);
        },
        .if_else_stmt => {
            const e = c.tree.extraData(ast.IfElse, d.rhs);
            _ = try c.checkExprCached(d.lhs, types.no_type);
            try c.checkStatement(e.then_stmt);
            try c.checkStatement(e.else_stmt);
        },
        .while_stmt => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            try c.checkStatement(d.rhs);
        },
        .do_stmt => {
            try c.checkStatement(d.lhs);
            _ = try c.checkExprCached(d.rhs, types.no_type);
        },
        .for_stmt => {
            const e = c.tree.extraData(ast.For, d.lhs);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(node)) |s| c.cur_scope = s;
            if (e.init != 0) {
                switch (c.nodeTag(e.init)) {
                    .var_decl_one, .var_decl => try checkVarDeclStatement(c, e.init),
                    else => _ = try c.checkExprCached(e.init, types.no_type),
                }
            }
            if (e.cond != 0) _ = try c.checkExprCached(e.cond, types.no_type);
            if (e.update != 0) _ = try c.checkExprCached(e.update, types.no_type);
            try c.checkStatement(d.rhs);
        },
        .for_in_stmt, .for_of_stmt => try checkForInOf(c, node),
        .switch_stmt => try checkSwitch(c, node),
        .case_clause, .default_clause => {}, // handled by checkSwitch
        .try_stmt => {
            const e = c.tree.extraData(ast.Try, d.rhs);
            try c.checkStatement(d.lhs);
            if (e.catch_clause != 0) {
                const cd = c.tree.nodeData(e.catch_clause);
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                if (try c.scopeOf(e.catch_clause)) |s| c.cur_scope = s;
                if (cd.rhs != 0) {
                    if (c.nodeTag(cd.rhs) == .block) {
                        for (c.tree.nodeRange(cd.rhs)) |stmt| try c.checkStatement(stmt);
                    } else {
                        try c.checkStatement(cd.rhs);
                    }
                }
            }
            if (e.finally_block != 0) try c.checkStatement(e.finally_block);
        },
        .throw_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
        .return_stmt => try checkReturn(c, node),
        .break_stmt, .continue_stmt => {},
        .labeled_stmt => try c.checkStatement(d.lhs),
        .function_decl => try checkFunctionDecl(c, node),
        .decorator => try c.pending_class_decos.append(c.cm(), node),
        .class_decl => try c.checkClass(node),
        .interface_decl => try checkInterfaceDecl(c, node),
        .type_alias => try checkTypeAliasDecl(c, node),
        .enum_decl => try c.checkEnum(node),
        .namespace_decl => try checkNamespace(c, node),
        .import_decl => {}, // module graph
        .export_named, .export_all => {},
        .export_decl => try c.checkStatement(d.lhs),
        .export_default => {
            switch (c.nodeTag(d.lhs)) {
                .function_decl, .class_decl => try c.checkStatement(d.lhs),
                else => _ = try c.checkExprCached(d.lhs, types.no_type),
            }
        },
        else => _ = try c.checkExprCached(node, types.no_type),
    }
}

/// tsc's `checkGrammarTopLevelElementsForRequiredDeclareModifier`: inside a
/// `.d.ts`, every top-level DECLARATION (and every variable statement) must
/// start with `declare`, `export` or `default`. Interfaces, type aliases,
/// imports and exports are exempt, and anything that is not a declaration is
/// not this check's business. tsc stops at the FIRST offender, so a file
/// gets at most one TS1046.
pub fn checkDeclFileTopLevel(c: *Checker) Error!void {
    for (c.tree.nodeRange(0)) |stmt| {
        if (stmt == null_node) continue;
        const needs = switch (c.nodeTag(stmt)) {
            // A variable statement never carries the modifier on its own
            // node — the parser consumes `declare` and starts the statement
            // at `var`/`let`/`const` — so read it off the token stream.
            .var_decl_one, .var_decl => !precededByDeclare(c, stmt),
            .class_decl => !declFlagSet(c, ast.ClassData, stmt),
            .function_decl => !declFlagSet(c, ast.FnProto, stmt),
            .enum_decl => !declFlagSet(c, ast.EnumData, stmt),
            .namespace_decl => !declFlagSet(c, ast.NamespaceData, stmt),
            else => false,
        };
        if (!needs) continue;
        try c.diagFmt(1046, c.tokSpan(c.tree.nodeMainToken(stmt)), "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.", .{});
        return;
    }
}

fn declFlagSet(c: *Checker, comptime T: type, node: Node) bool {
    const data = c.tree.extraData(T, c.tree.nodeData(node).lhs);
    return data.flags & ast.Flags.declare != 0;
}

/// Is the token immediately before `node`'s main token a `declare` keyword?
/// The parser folds `declare` into a flag for every declaration form except
/// variable statements, where it simply bumps past it.
fn precededByDeclare(c: *Checker, node: Node) bool {
    const mt = c.tree.nodeMainToken(node);
    return mt > 0 and c.tree.tokens.tag(mt - 1) == .keyword_declare;
}

fn checkVarDeclStatement(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const is_const = c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .keyword_const;
    const ambient = c.ambient_ctx or precededByDeclare(c, node);
    if (c.nodeTag(node) == .var_decl_one) {
        if (ambient) try checkAmbientInitializer(c, d.lhs, is_const);
        try checkDeclarator(c, d.lhs, is_const);
    } else {
        for (c.tree.nodeRange(node)) |decl| {
            if (decl == null_node) continue;
            if (ambient) try checkAmbientInitializer(c, decl, is_const);
            try checkDeclarator(c, decl, is_const);
        }
    }
}

/// tsc's `checkAmbientInitializer` for a variable declarator: an initializer
/// is not allowed in an ambient context (TS1039) unless the declaration is a
/// `const` WITHOUT a type annotation — the one form that carries a literal
/// value into the declaration file. (tsc additionally requires that
/// exempted initializer to be a literal, TS1254; ztsc stays silent there, a
/// deliberate under-report rather than a guess at "literal enum reference".)
fn checkAmbientInitializer(c: *Checker, decl: Node, is_const: bool) Error!void {
    const d = c.tree.nodeData(decl);
    const init: Node, const has_ann: bool = switch (c.nodeTag(decl)) {
        .declarator_init => .{ d.rhs, false },
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            break :blk .{ e.init, e.type_ann != 0 };
        },
        else => return,
    };
    if (init == null_node) return;
    if (is_const and !has_ann) return;
    try c.diagFmt(1039, c.nodeSpan(init), "Initializers are not allowed in ambient contexts.", .{});
}

fn checkDeclarator(c: *Checker, decl: Node, is_const: bool) Error!void {
    // TS2403 — every declaration of a name after the first must have an
    // identical type. Runs before the initializer checks so the type demand
    // is the same one `typeOfSymbol` would make on its own.
    try c.checkSubsequentVarDecl(decl, is_const);
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        // `var [a], {b};` — no annotation and no initializer, so the pattern
        // is the only source of type information and every leaf it binds is
        // an implicit `any` (TS7031). Only a VAR STATEMENT reaches here; a
        // `for…of`/`for…in` head takes its declarator's type from the
        // iterable and is checked elsewhere.
        .declarator => try implicit_any.reportPatternImplicitAny(c, d.lhs),
        .declarator_init => {
            _ = try c.checkExprCached(d.rhs, types.no_type);
            // Materialize the symbol's type (infers + caches).
            try materializePatternTypes(c, d.lhs);
        },
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            const name_span = if (c.nodeTag(d.lhs) == .identifier)
                c.tokSpan(c.tree.nodeMainToken(d.lhs))
            else
                c.nodeSpan(d.lhs);
            const ann: TypeId = if (e.type_ann != 0) try c.annTypeMaybeUnique(e.type_ann, is_const, 1332, name_span) else types.no_type;
            // A `unique symbol` const accepts only a fresh `Symbol()` /
            // `Symbol.for()` initializer; the assignability check (a plain
            // `symbol` is not assignable to `unique symbol`) is skipped for
            // that one form, matching tsc.
            if (e.init != 0 and e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and c.isFreshSymbolCall(e.init)) {
                _ = try c.checkExprCached(e.init, ann);
                try materializePatternTypes(c, d.lhs);
                return;
            }
            if (e.init != 0) {
                const it = try c.checkExprCached(e.init, ann);
                if (ann != types.no_type and ann != types.error_type) {
                    // An INLINE deferred conditional annotation does not get
                    // the both-branches leniency here (see
                    // `inlineCondAnnRejects`): tsc treats a distributive
                    // conditional written inside the generic function's body
                    // as distribution dependent and rejects the write.
                    if (try c.checkAssignable(it, ann, e.init, name_span) and
                        try c.inlineCondAnnRejects(e.type_ann, it, ann))
                    {
                        try c.reportNotAssignable(2322, it, ann, name_span);
                    }
                }
            }
            try materializePatternTypes(c, d.lhs);
        },
        else => {},
    }
}

/// Force typeOfSymbol for every name bound by a pattern so inference
/// diagnostics fire deterministically at the declaration site.
fn materializePatternTypes(c: *Checker, pat: Node) Error!void {
    if (pat == null_node) return;
    switch (c.nodeTag(pat)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| _ = try c.typeOfSymbol(sym),
                else => {},
            }
        },
        .array_pattern, .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el != null_node) try materializePatternTypes(c, el);
            }
        },
        .binding_property => {
            const d = c.tree.nodeData(pat);
            if (d.lhs != 0) {
                try materializePatternTypes(c, d.lhs);
            } else {
                const a = try c.memberAtom(c.tree.nodeMainToken(pat));
                switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| _ = try c.typeOfSymbol(sym),
                    else => {},
                }
            }
            if (d.rhs != 0) _ = try c.checkExprCached(d.rhs, types.no_type);
        },
        .binding_property_computed => {
            const d = c.tree.nodeData(pat);
            if (d.lhs != 0) _ = try c.checkExprCached(d.lhs, types.no_type);
            if (d.rhs != 0) try materializePatternTypes(c, d.rhs);
        },
        .binding_default => {
            const d = c.tree.nodeData(pat);
            try materializePatternTypes(c, d.lhs);
            _ = try c.checkExprCached(d.rhs, types.no_type);
        },
        .rest_element => try materializePatternTypes(c, c.tree.nodeData(pat).lhs),
        else => {},
    }
}

fn checkForInOf(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const e = c.tree.extraData(ast.ForInOf, d.lhs);
    const is_of = c.nodeTag(node) == .for_of_stmt;
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    const rt = try c.checkExprCached(e.right, types.no_type);
    var elem_t: TypeId = types.any_type;
    if (is_of) {
        elem_t = try c.forOfElementType(rt, e.right, e.is_await != 0);
    } else {
        elem_t = types.string_type; // for..in keys
        // `for (const k in maybeUndefined)` is legal JS — enumerating
        // `null`/`undefined` produces no keys — so tsc's
        // `checkForInStatement` runs the right-hand side through
        // `getNonNullableTypeIfNeeded` before testing its kind, and prints
        // the STRIPPED type in the diagnostic. (The body's own view of the
        // subject is `forInSubjectNarrows`, the flow half of the same rule.)
        const rt_nn = if (isNullishUnion(c, rt)) try c.nonNullable(rt) else rt;
        const rk = c.ts.kind(try c.resolveStructural(rt_nn));
        if (!isNonPrimitiveKind(rk) and rk != .any and rk != .err and rk != .unknown and rk != .type_param) {
            try c.diagFmt(2407, c.nodeSpan(e.right), "The right-hand side of a 'for...in' statement must be of type 'any', an object type or a type parameter, but here has type '{s}'.", .{try c.typeToString(rt_nn)});
        }
    }
    // Bind the left side.
    switch (c.nodeTag(e.left)) {
        .var_decl_one, .var_decl => {
            const ld = c.tree.nodeData(e.left);
            const decl = if (c.nodeTag(e.left) == .var_decl_one) ld.lhs else blk: {
                const range = c.tree.nodeRange(e.left);
                break :blk if (range.len > 0) range[0] else null_node;
            };
            if (decl != null_node) {
                const dd = c.tree.nodeData(decl);
                switch (c.nodeTag(decl)) {
                    .declarator => {
                        if (c.nodeTag(dd.lhs) == .identifier) {
                            const a = try c.atomOfToken(c.tree.nodeMainToken(dd.lhs));
                            if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
                                c.setTypeOfSymbol(c.toGlobal(sym), elem_t);
                            }
                        } else {
                            try assignPatternFromType(c, dd.lhs, elem_t);
                        }
                    },
                    .declarator_full => {
                        const ee = c.tree.extraData(ast.DeclaratorFull, dd.rhs);
                        if (ee.type_ann != 0) {
                            const ann = try c.typeFromTypeNode(ee.type_ann);
                            _ = try c.checkAssignable(elem_t, ann, 0, c.nodeSpan(dd.lhs));
                        }
                        try materializePatternTypes(c, dd.lhs);
                    },
                    else => {},
                }
            }
        },
        else => _ = try c.checkExprCached(e.left, types.no_type),
    }
    try c.checkStatement(d.rhs);
}

/// Pre-set the types of identifiers bound in a destructuring pattern
/// from the element type (for-of patterns).
fn assignPatternFromType(c: *Checker, pat: Node, whole: TypeId) Error!void {
    if (pat == null_node) return;
    switch (c.nodeTag(pat)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
            if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), whole);
        },
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                if (c.nodeTag(el) == .binding_property) {
                    const key = try c.memberAtom(c.tree.nodeMainToken(el));
                    var pt: TypeId = types.any_type;
                    if (try c.propOfType(try c.resolveStructural(whole), key)) |p| pt = p.ty;
                    if (ed.lhs != 0) {
                        try assignPatternFromType(c, ed.lhs, pt);
                    } else {
                        const a = try c.memberAtom(c.tree.nodeMainToken(el));
                        if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), pt);
                    }
                } else if (c.nodeTag(el) == .binding_property_computed) {
                    // `{[k]: target}` → `target: whole[typeof k]`.
                    var pt: TypeId = types.any_type;
                    if (ed.lhs != 0) {
                        const kt = try c.checkExprCached(ed.lhs, types.no_type);
                        pt = try c.indexedAccessType(try c.resolveStructural(whole), kt);
                    }
                    if (ed.rhs != 0) try assignPatternFromType(c, ed.rhs, pt);
                }
            }
        },
        .array_pattern => {
            const r = try c.resolveStructural(whole);
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                var et: TypeId = types.any_type;
                switch (c.ts.kind(r)) {
                    .array => et = c.ts.arrayElem(r),
                    .tuple => {
                        if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                    },
                    else => {},
                }
                try assignPatternFromType(c, el, et);
            }
        },
        .binding_default => try assignPatternFromType(c, c.tree.nodeData(pat).lhs, whole),
        .rest_element => try assignPatternFromType(c, c.tree.nodeData(pat).lhs, try c.ts.makeArray(whole)),
        else => {},
    }
}

// The iteration protocol lives in `iteration.zig`, next to the `await`/yield
// half it shares a walk with; re-exported here because the `for..of` walk
// above drives it and `Checker`'s method aliases name this file.
pub const asyncIterationElementType = iteration.asyncIterationElementType;
pub const callableReturn = iteration.callableReturn;
pub const forOfElementType = iteration.forOfElementType;
pub const iterationElementType = iteration.iterationElementType;
pub const iteratorNextValue = iteration.iteratorNextValue;

fn checkSwitch(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const disc_t = try c.checkExprCached(d.lhs, types.no_type);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;
    const r = c.tree.extraData(ast.SubRange, d.rhs);
    for (c.tree.extraRange(r.start, r.end)) |clause| {
        if (clause == null_node) continue;
        const cd = c.tree.nodeData(clause);
        if (c.nodeTag(clause) == .case_clause and cd.lhs != 0) {
            const case_t = try c.checkExprCached(cd.lhs, types.no_type);
            // TS2678 is the same *comparable* relation as TS2367, so it
            // goes through the same union/intersection-distributing test:
            // a `case null:` on a non-nullable discriminant is clean in
            // tsc, and `case 1:` on a branded `number & { _brand }` relates
            // through the intersection's `number` constituent. Bare
            // `isComparable` (mutual assignability) reported both.
            if (!try c.typesHaveOverlap(case_t, disc_t)) {
                try c.diagFmt(2678, c.nodeSpan(cd.lhs), "Type '{s}' is not comparable to type '{s}'.", .{
                    try c.typeToString(case_t), try c.typeToString(disc_t),
                });
            }
        }
        const cr = c.tree.extraData(ast.SubRange, cd.rhs);
        for (c.tree.extraRange(cr.start, cr.end)) |stmt| try c.checkStatement(stmt);
    }
}

fn checkReturn(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const ctx = c.fn_ctx orelse {
        if (d.lhs != 0) _ = try c.checkExprCached(d.lhs, types.no_type);
        return;
    };
    if (d.lhs != 0) {
        // Contextual type of the return expression. For async, tsc's
        // `getContextualTypeForReturnExpression` yields `T | Promise<T>`
        // (awaited payload OR a promise of it), so a returned generic
        // call/`new` whose own return is `Promise<R>` infers `R` from the
        // promise arm (`return new Promise(()=>{})` → `Promise<T>`;
        // `return axios.delete(...)` → `Promise<R=T>`). The assignability
        // check below still relates the *awaited* value to `ctx.ret_ann`.
        // With no annotation, the contextual signature's return type takes
        // that role (`c.ret_ctx`) — it is what tsc's
        // `getContextualTypeForReturnExpression` yields for a contextually
        // typed function, and without it a `return { handler: (e) => … }`
        // inside such a function lost every nested contextual type.
        const base_ctx = if (ctx.ret_ann != types.no_type) ctx.ret_ann else ctx.ret_ctx;
        const expr_ctx = if (ctx.is_async and base_ctx != types.no_type and
            base_ctx != types.error_type and c.ts.kind(base_ctx) != .none)
            try c.makeUnion2(base_ctx, try c.makePromise(base_ctx))
        else
            base_ctx;
        const rt = try c.checkExprCached(d.lhs, expr_ctx);
        // async: `return v` in a `Promise<T>` relates the awaited `v` to the
        // payload `T` (so `return somePromise` is not double-wrapped).
        const eff_rt = if (ctx.is_async) try c.awaitedType(rt) else rt;
        if (ctx.ret_ann != types.no_type and ctx.ret_ann != types.error_type and
            ctx.ret_ann != types.any_type and c.ts.kind(ctx.ret_ann) != .none)
        {
            // Anchored at the RETURN STATEMENT, not the expression: tsc's
            // `checkReturnStatement` passes the statement as the error
            // node, so the column is `return`'s, seven characters to the
            // left of the expression's. (The expression node still goes in
            // as `expr_node`, so the literal elaboration below still
            // descends into it.) The bare-`return` arm below already
            // anchored this way.
            _ = try c.checkAssignable(eff_rt, ctx.ret_ann, d.lhs, c.nodeSpan(node));
        }
    } else if (ctx.ret_ann != types.no_type) {
        const k = c.ts.kind(ctx.ret_ann);
        const allows_bare = k == .void or k == .any or k == .unknown or k == .err or k == .none or
            c.containsUndefinedish(ctx.ret_ann);
        if (!allows_bare) {
            try c.diagFmt(2322, c.nodeSpan(node), "Type 'undefined' is not assignable to type '{s}'.", .{try c.typeToString(ctx.ret_ann)});
        }
    }
}

fn checkFunctionDecl(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    // Builds the signature (reports 7006 etc. once).
    _ = try c.signatureOfProto(node, d.lhs, false, true);
    if (d.rhs != 0) {
        const sig = try c.signatureOfProto(node, d.lhs, false, true);
        try c.checkFunctionBody(node, d.lhs, d.rhs, sig, types.no_type);
    }
}

/// Walk every function body postponed by `defer_bodies`, in queue order.
/// Each entry restores the file and `this` it was queued under; draining a
/// body may queue more (a nested class, another field), so the loop reads
/// the list by index until it stops growing.
pub fn drainDeferredBodies(c: *Checker) Error!void {
    if (c.deferred_bodies.items.len == 0) return;
    std.debug.assert(c.defer_bodies == 0);
    const saved_ctx = c.saveCtx();
    const saved_this = c.this_type;
    defer {
        c.restoreCtx(saved_ctx);
        c.this_type = saved_this;
    }
    var i: usize = 0;
    while (i < c.deferred_bodies.items.len) : (i += 1) {
        const d = c.deferred_bodies.items[i];
        if (d.file != c.cur_file) c.setFile(d.file);
        c.this_type = d.this_type;
        try c.checkFunctionBody(d.node, d.proto_idx, d.body, d.sig, d.ret_ctx);
    }
    c.deferred_bodies.clearRetainingCapacity();
}

/// `ret_ctx` is the contextual signature's return type when this function
/// has no return annotation (0 otherwise / when there is no context). It
/// only supplies a contextual type to the return expressions — the
/// assignability checks stay on the written annotation.
pub fn checkFunctionBody(c: *Checker, node: Node, proto_idx: u32, body: Node, sig: TypeId, ret_ctx: TypeId) Error!void {
    if (body == 0) return;
    // Owned-file guard (see `checkJsxElement`). This function returns
    // `void` — its *result* is input-independent by construction, so the
    // invariant the JSX guard needs holds trivially here. Everything it
    // does is diagnostics (TS2355/2366, parameter-initializer and return
    // assignability, and whatever the statement walk reports), and
    // `diagFmt` files each one under `cur_file`, which `seal` drops unless
    // this checker owns it.
    //
    // The obligation that is *not* trivial is side effects. The body walk
    // populates `node_types` and materializes symbol types, and a foreign
    // file is only ever entered by materializing a dependency's type — so
    // the question is whether any later answer depends on the cache state
    // this walk would have left behind:
    //
    //   * `node_types` is a memo, and every reader outside diagnostics
    //     re-derives on miss (`checkExprCached`). The three readers that
    //     branch on presence — `elaborateLiteralError`, `assignNarrows`'
    //     compound-assign arm, `guardCallOf`'s member callee — are
    //     either diagnostics-only (dropped here) or reached from
    //     `inferReturnType`, and `checkFunctionLikeExpr`/`checkFunctionDecl`
    //     run that probe BEFORE this body walk, so the probe already sees
    //     a cold cache today. Skipping the walk cannot change what it saw.
    //   * Symbol types are materialized lazily and re-entrantly by
    //     `typeOfSymbol`, never by the body walk being reached first: the
    //     inferred type of anything this file exports is reachable from the
    //     probe/`typeOfSymbol` path alone.
    //   * `reassign_scanned`/`scopes_faulted` are per-file syntactic scans
    //     driven by their own lazy faults, not by this walk.
    //
    // Byte-identity across `--checkers=N` is therefore preserved: the walk
    // interns fewer types in a foreign file, and type identity is already
    // required to be order-independent (that is the determinism contract
    // every `--checkers=N` split exercises).
    if (!c.owned_mask[c.cur_file]) return;
    // Reached while materializing a class field's type: postpone the walk
    // until the enclosing class's instance type exists (see `DeferredBody`).
    if (c.defer_bodies > 0) {
        try c.deferred_bodies.append(c.cm(), .{
            .file = c.cur_file,
            .node = node,
            .proto_idx = proto_idx,
            .body = body,
            .sig = sig,
            .ret_ctx = ret_ctx,
            .this_type = c.this_type,
        });
        return;
    }
    const proto = c.tree.extraData(ast.FnProto, proto_idx);
    const saved_scope = c.cur_scope;
    const saved_ctx = c.fn_ctx;
    const saved_this = c.this_type;
    defer {
        c.cur_scope = saved_scope;
        c.fn_ctx = saved_ctx;
        c.this_type = saved_this;
    }
    if (try c.scopeOf(node)) |s| c.cur_scope = s;
    // An explicit `this` parameter types `this` inside the body.
    if (c.ts.kind(sig) == .function) {
        const tt = c.ts.fnThisType(sig);
        if (tt != 0) c.this_type = tt;
    }
    const is_async = proto.flags & ast.Flags.async != 0;
    const is_generator = proto.flags & ast.Flags.generator != 0;
    const ann: TypeId = if (proto.return_type != 0) try c.typeFromTypeNode(proto.return_type) else types.no_type;
    // Effective return-check target. For async this is the awaited payload
    // `T` of the declared `Promise<T>`; a non-Promise annotation is TS1064.
    var eff_ann = ann;
    var yield_type: TypeId = 0;
    if (is_async and is_generator) {
        // `async function*`: annotated with an AsyncGenerator-family type,
        // not Promise — TS1064 does not apply. Relate `yield x` to its
        // first type arg (yielded promises are awaited at the yield site).
        yield_type = c.asyncGeneratorYieldType(ann);
        eff_ann = types.no_type;
    } else if (is_async and ann != types.no_type) {
        const k = c.ts.kind(ann);
        const is_promise = c.ts.kind(ann) == .ref and c.prog.globals.lookup(c.atom_Promise) != null and
            c.ts.refSymbol(ann) == c.prog.globals.lookup(c.atom_Promise).?;
        if (is_promise) {
            eff_ann = try c.awaitedType(ann);
        } else if (k != .err and k != .none) {
            try c.diagFmt(1064, c.nodeSpan(proto.return_type), "The return type of an async function or method must be the global Promise<T> type. Did you mean to write 'Promise<{s}>'?", .{try c.typeToString(ann)});
            eff_ann = types.no_type; // suppress payload assignability noise
        }
    } else if (is_generator) {
        // Generators: relate `yield x` to `T` from `Generator<T>`; return
        // values (→ TReturn) are unchecked (gap).
        yield_type = c.generatorYieldType(ann);
        eff_ann = types.no_type;
    }
    // Contextual return type: only meaningful when nothing was written and
    // the function is not a generator. Async unwraps to the payload, as
    // `eff_ann` does for a written `Promise<T>`.
    var eff_ret_ctx: TypeId = if (proto.return_type == 0 and !is_generator) ret_ctx else types.no_type;
    if (eff_ret_ctx != types.no_type and is_async) eff_ret_ctx = try c.awaitedType(eff_ret_ctx);
    c.fn_ctx = .{ .ret_ann = eff_ann, .ret_ctx = eff_ret_ctx, .is_async = is_async, .is_generator = is_generator, .yield_type = yield_type };

    // Check parameter initializers against annotations.
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        if (pn == null_node or c.nodeTag(pn) != .param_full) continue;
        const pd = c.tree.nodeData(pn);
        const e = c.tree.extraData(ast.ParamFull, pd.rhs);
        if (e.init != 0 and e.type_ann != 0) {
            const ann_t = try c.typeFromTypeNode(e.type_ann);
            const it = try c.checkExprCached(e.init, ann_t);
            // tsc's `checkVariableLikeDeclaration` anchors an initializer
            // mismatch at the DECLARATION (`errorNode = node`), not at the
            // initializer, and only descends into the initializer when the
            // elaboration finds something narrower to blame — exactly what a
            // `var`/`const` declarator already does here. A parameter's
            // declaration starts at its name, so `function f<T extends
            // Number>(x: T = 1)` reports on `x`, not on the `1`.
            _ = try c.checkAssignable(it, ann_t, e.init, c.nodeSpan(pn));
        } else if (e.init != 0) {
            _ = try c.checkExprCached(e.init, types.no_type);
        }
    }

    if (c.nodeTag(body) == .block) {
        for (c.tree.nodeRange(body)) |stmt| try c.checkStatement(stmt);
        // Ending-return analysis (TS2355/2366). For async the target is the
        // Promise payload; generators do not require an ending return.
        if (!is_generator and eff_ann != types.no_type and eff_ann != types.error_type) {
            const k = c.ts.kind(eff_ann);
            const exempt = k == .void or k == .any or k == .err or k == .unknown or k == .none or
                c.containsUndefinedish(eff_ann);
            if (!exempt) {
                // Only the presence of returns matters here, so the scope
                // handed over is irrelevant — nothing re-checks the operands.
                var rets = try c.collectReturns(c.tree.nodeRange(body), binder.file_scope);
                defer rets.deinit(c.scratch());
                const span = if (proto.name_token != 0) c.tokSpan(proto.name_token) else c.tokSpan(c.tree.nodeMainToken(node));
                if (!c.stmtListTerminal(c.tree.nodeRange(body))) {
                    if (rets.exprs.items.len == 0 and !rets.bare) {
                        try c.diagFmt(2355, span, "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.", .{});
                    } else {
                        try c.diagFmt(2366, span, "Function lacks ending return statement and return type does not include 'undefined'.", .{});
                    }
                }
            }
        }
    } else {
        // Arrow expression body. For async, relate the awaited body type to
        // the Promise payload (`async () => p` returns `Promise<T>`).
        const rt = try c.checkExprCached(body, if (eff_ann != types.no_type) eff_ann else eff_ret_ctx);
        if (eff_ann != types.no_type and eff_ann != types.error_type) {
            const eff_rt = if (is_async) try c.awaitedType(rt) else rt;
            _ = try c.checkAssignable(eff_rt, eff_ann, body, c.nodeSpan(body));
        }
    }
}

// Syntactic reachability lives in `reachability.zig`; re-exported here because
// the statement walk above drives it and `Checker`'s method aliases name this
// file.
pub const containsBreak = reachability.containsBreak;
pub const stmtListTerminal = reachability.stmtListTerminal;
pub const stmtTerminal = reachability.stmtTerminal;
pub const switchIsExhaustive = reachability.switchIsExhaustive;
pub const switchTerminal = reachability.switchTerminal;
pub const typeofSwitchIsExhaustive = reachability.typeofSwitchIsExhaustive;

// --- classes / interfaces / aliases ------------------------------------

/// Check a namespace body: enter the (merged) namespace scope and check
/// each body statement there. Member visibility/typing is materialized by
/// classStaticType (value) and typeFromQualifiedName (type).
fn checkNamespace(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.NamespaceData, d.lhs);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    // `declare namespace N`, `declare module "spec"` and `declare global`
    // all open an ambient context for their body (tsc's `NodeFlags.Ambient`),
    // and it stays open once opened.
    const saved_ambient = c.ambient_ctx;
    defer c.ambient_ctx = saved_ambient;
    if (data.flags & ast.Flags.declare != 0) c.ambient_ctx = true;
    // The body scope is the one owned by this node, or — for a merged
    // block whose scope is owned by an earlier block — the namespace
    // symbol's members scope.
    if (try c.scopeOf(node)) |s| {
        c.cur_scope = s;
    } else if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(saved, a)) |sym| {
            if (c.bind.namespaceScopeOf(sym)) |ns| c.cur_scope = ns;
        }
    }
    for (c.tree.extraRange(data.body_start, data.body_end)) |stmt| {
        if (stmt != null_node) try c.checkStatement(stmt);
    }
}

/// TS2415 / TS2416: the INSTANCE side of a derived class must extend its base
/// — `D` assignable to `B` — which is what makes a derived member that
/// redeclares an inherited one at an incompatible type an error rather than a
/// silent narrowing of the instance type.
///
/// tsc's `checkClassLikeDeclaration`:
///
/// ```ts
/// if (!checkTypeAssignableTo(typeWithThis, baseWithThis, /*errorNode*/ undefined)) {
///     issueMemberSpecificError(node, typeWithThis, baseWithThis,
///         Diagnostics.Class_0_incorrectly_extends_base_class_1);
/// } else {
///     // Report static side error only when instance type is assignable
///     checkTypeAssignableTo(staticType, getTypeWithoutSignatures(staticBaseType), …);
/// }
/// ```
///
/// Two properties of that shape are load-bearing and are reproduced here:
///
///   * the pair is related ONCE with no error node, and the diagnostic is
///     produced by a second, per-member pass (`issueMemberSpecificError`).
///     That pass walks the class's OWN instance members and, for each name the
///     derived and the base BOTH have, relates the two property types; every
///     failing member reports its own TS2416. Only when no member failed —
///     the mismatch is in an index signature, a call signature, or a member
///     the base does not declare — does the broad TS2415 fire, once, on the
///     class name;
///   * the STATIC side (TS2417, `checkStaticSideExtends`) is checked only when
///     the instance side passed, so a class whose members contradict the base
///     reports the member, not both halves of the same story.
///
/// Guarded exactly as the `implements` check next to it: nothing is concluded
/// about a class whose base ztsc could not resolve (`hasUnresolvedBase`), where
/// the instance type is missing whatever that base contributed and the verdict
/// would be about ztsc's gap rather than the code.
///
/// Returns whether the instance side is assignable, i.e. whether the caller
/// should go on to the static side.
fn checkInstanceSideExtends(c: *Checker, class_sym: SymbolId, members: []const Node, this_t: TypeId, name_token: ast.TokenIndex) Error!bool {
    const base_ref = try c.baseClassRef(class_sym) orelse return true;
    if (base_ref == types.error_type or base_ref == types.any_type or base_ref == this_t) return true;
    if (try c.hasUnresolvedBase(class_sym)) return true;
    if (try c.isAssignable(this_t, base_ref)) return true;

    const derived = try c.resolveStructural(this_t);
    const base = try c.resolveStructural(base_ref);
    var issued = false;
    // The per-member pass walks the SYNTAX members, in source order, exactly
    // as tsc's `for (const member of node.members)` does. That is not just a
    // convenient way to reach the names: it decides which members are
    // candidates at all. A CONSTRUCTOR PARAMETER PROPERTY (`constructor(public
    // a: string)`) declares `a` on the instance type but is not a member node,
    // so tsc never blames it and reports the broad TS2415 instead — walking
    // the member SCOPE, which does contain `a`, would report TS2416 where the
    // oracle reports TS2415.
    for (members) |member| {
        if (member == null_node) continue;
        const md = c.tree.nodeData(member);
        const flags: u32 = switch (c.nodeTag(member)) {
            .class_field => c.tree.extraData(ast.Field, md.lhs).flags,
            .class_method => c.tree.extraData(ast.FnProto, md.lhs).flags,
            // A decorator, an index signature, a static block, a `;` — none of
            // them is a named member (tsc's `member.name` is undefined and
            // `getPropertyOfType` finds nothing for the member's own symbol).
            else => continue,
        };
        // tsc's `if (isStatic(member)) continue;` — this is the INSTANCE side.
        if (flags & ast.Flags.static != 0) continue;
        const name_atom = try c.memberKey(c.tree.nodeMainToken(member), flags);
        if (c.isCtorName(name_atom)) continue;
        const prop = (try c.propOfTypeEx(derived, name_atom, false)) orelse continue;
        const base_prop = (try c.propOfTypeEx(base, name_atom, false)) orelse continue;
        if (prop.ty == base_prop.ty) continue;
        if (try c.isAssignable(prop.ty, base_prop.ty)) continue;
        issued = true;
        // tsc's `rootChain`: the TS2416 headline is the ROOT of the chain the
        // ordinary relation would have printed, so the "Type 'X' is not
        // assignable to type 'Y'." line the headline usually carries appears
        // one level in, with the structural derivation under it.
        try c.diagFmt(2416, c.tokSpan(c.tree.nodeMainToken(member)), "Property '{s}' in type '{s}' is not assignable to the same property in base type '{s}'.\n  Type '{s}' is not assignable to type '{s}'.{s}", .{
            c.atomText(name_atom),
            try c.typeToString(this_t),
            try c.typeToString(base_ref),
            try c.typeToString(prop.ty),
            try c.typeToString(base_prop.ty),
            try indentChain(c, try elaborate.chainText(c, prop.ty, base_prop.ty)),
        });
    }
    if (!issued and name_token != 0) {
        try c.diagFmt(2415, c.tokSpan(name_token), "Class '{s}' incorrectly extends base class '{s}'.{s}", .{
            c.symbolName(class_sym),
            try c.typeToString(base_ref),
            try elaborate.chainText(c, this_t, base_ref),
        });
    }
    return false;
}

/// One extra indentation level for a derivation chain nested under a headline
/// that already spent one (`checkInstanceSideExtends`, and `decorators.zig`'s
/// legacy argument failure). `chainText` renders from column 2; TS2416's chain
/// hangs off the relation line the headline pushed down, so every line moves
/// right by two.
pub fn indentChain(c: *Checker, chain: []const u8) Error![]const u8 {
    if (chain.len == 0) return chain;
    var out: std.Io.Writer.Allocating = .init(c.scratch());
    for (chain) |ch| {
        out.writer.writeByte(ch) catch return error.OutOfMemory;
        if (ch == '\n') out.writer.writeAll("  ") catch return error.OutOfMemory;
    }
    return out.written();
}

/// TS2417: the static side of a derived class must extend the static side
/// of its base — `typeof D` assignable to `typeof B`, which is what makes a
/// derived static that shadows a base static with an incompatible type an
/// error rather than a silent narrowing of the constructor object.
///
/// tsc relates `getTypeOfSymbol(class)` against
/// `getTypeWithoutSignatures(staticBaseType)`: construct signatures are
/// dropped (a derived ctor never has to match the base's), and `prototype`
/// is skipped by the `SymbolFlags.Prototype` filter in `propertiesRelatedTo`
/// (it is the instance side's job, TS2415). ztsc's `classStaticType` carries
/// neither signatures nor `prototype`, so relating the two objects directly
/// *is* the filtered relation.
///
/// The source object is the merged one — `classStaticType` already folds the
/// base's statics in with own members winning — so every base member the
/// derived does not shadow is present verbatim and relates trivially. Only a
/// genuine incompatible shadow can fail, which keeps this off valid code.
/// Reported on the class name, tsc's `node.name || node`.
fn checkStaticSideExtends(c: *Checker, class_sym: SymbolId, name_token: ast.TokenIndex) Error!void {
    if (name_token == 0) return;
    const base = try c.baseClassSym(class_sym) orelse return;
    const derived_static = try c.classStaticType(class_sym);
    const base_static = try c.classStaticType(base);
    if (derived_static == base_static) return;
    if (try c.isAssignable(derived_static, base_static)) return;
    try c.diagFmt(2417, c.tokSpan(name_token), "Class static side 'typeof {s}' incorrectly extends base class static side 'typeof {s}'.{s}", .{
        c.symbolName(class_sym),
        c.symbolName(base),
        try elaborate.chainText(c, derived_static, base_static),
    });
}

/// TS2729 for one instance field initializer: a `this.x` in it that names an
/// own instance field *not yet initialized* at that point — either a LATER
/// sibling (`f = this.g; g = 1`) or the field being initialized itself
/// (`p = this.p`). Both read `undefined` at construction time.
///
/// Syntactic, and deliberately so: tsc's rule (`isBlockScopedNameDeclaredBeforeUse`
/// → `isUsedInFunctionOrInstanceProperty`) is a walk from the use up to the
/// enclosing declaration, and the exemptions on that walk are all syntactic —
/// a use inside a nested function or class runs later, so it is fine, and an
/// access whose receiver is itself an access (`this.a.b`) is not a
/// declaration reference at all. Both fall out of the descent below. Members
/// other than plain instance fields are exempt: a method is on the prototype
/// before any initializer runs, and an optional field is allowed to be
/// missing.
fn checkFieldInitSelfRefs(c: *Checker, members: []const Node, field: Node, expr: Node) Error!void {
    switch (c.nodeTag(expr)) {
        // Deferred to call time — the field is initialized by then.
        .arrow_fn, .function_expr, .function_decl, .object_method, .class_decl => return,
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(expr);
            if (c.nodeTag(d.lhs) == .this_expr) {
                const name = c.tokenText(d.rhs);
                for (members) |m| {
                    if (m == null_node or c.nodeTag(m) != .class_field) continue;
                    const e = c.tree.extraData(ast.Field, c.tree.nodeData(m).lhs);
                    if (e.flags & (ast.Flags.static | ast.Flags.optional) != 0) continue;
                    if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(m)), name)) continue;
                    // Initialized already: a strictly earlier sibling.
                    if (m != field and c.nodeSpanStart(m) < c.nodeSpanStart(field)) break;
                    try c.diagFmt(2729, c.tokSpan(d.rhs), "Property '{s}' is used before its initialization.", .{name});
                    break;
                }
            }
        },
        else => {},
    }
    var it = c.tree.childIterator(expr);
    while (it.next()) |child| try checkFieldInitSelfRefs(c, members, field, child);
}

/// One instance property declaration that `strictPropertyInitialization` has
/// to judge: it has no initializer, no `!`, a type that cannot be `undefined`,
/// and a name the flow graph can key. Collected while the members are checked
/// (the annotation is typed exactly once, by the member walk) and judged after,
/// so the constructor's body has been checked before its flow is queried.
const InitCand = struct { member: Node, ty: TypeId };

/// tsc's `isPropertyWithoutInitializer` plus the surrounding filters in
/// `checkPropertyInitialization`, applied to one `class_field`:
///
///   * an initializer, a definite-assignment assertion (`x!:`), `abstract`, a
///     `declare` modifier or `static` all exempt the declaration outright
///     (`static` because TS2564 is an *instance* check — the outer loop tests
///     `!isStatic(member)`);
///   * `?` exempts it because the property type then includes `undefined`,
///     which is also what exempts an explicit `| undefined`, `any` and
///     `unknown` (`type.flags & AnyOrUnknown || containsUndefinedType(type)`);
///   * the name must be an identifier, a private name or a computed name —
///     tsc's `isIdentifier(propName) || isPrivateIdentifier(propName) ||
///     isComputedPropertyName(propName)` — so a QUOTED or numeric member name
///     (`"quoted": string`) is silently skipped, verified against the oracle.
///
/// A computed name is skipped here rather than reported: ztsc keys such a
/// member by a placeholder atom (`memberNameKey`) that a `this[k]` write does
/// not produce, so the flow query could not see the write and would invent a
/// TS2564. A documented under-report — the alternative manufactures errors.
fn initCandidate(c: *Checker, member: Node, e: ast.Field, ann: TypeId) bool {
    if (e.init != 0) return false;
    const exempt = ast.Flags.definite | ast.Flags.abstract | ast.Flags.declare |
        ast.Flags.static | ast.Flags.optional | ast.Flags.computed;
    if (e.flags & exempt != 0) return false;
    switch (c.tree.tokens.tag(c.tree.nodeMainToken(member))) {
        .string_literal, .numeric_literal => return false,
        else => {},
    }
    if (ann == types.no_type or ann == types.error_type) return false;
    switch (c.ts.kind(ann)) {
        .any, .unknown, .err => return false,
        else => {},
    }
    return !c.hasUndefinedMember(ann);
}

/// tsc's `findConstructorDeclaration`: the class's own constructor *with a
/// body* (an overload signature is not the implementation), or `null_node`.
/// A base class's constructor does not count — the check is per class.
fn constructorWithBody(c: *Checker, members: []const Node) Node {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const md = c.tree.nodeData(m);
        if (md.rhs == 0) continue;
        const proto = c.tree.extraData(ast.FnProto, md.lhs);
        if (proto.flags & ast.Flags.static != 0) continue;
        if (c.tree.tokens.tag(c.tree.nodeMainToken(m)) != .keyword_constructor) continue;
        return m;
    }
    return null_node;
}

/// Is `node` (a call expression) an IIFE — tsc's
/// `getImmediatelyInvokedFunctionExpression`, whose body the binder there folds
/// into the *containing* control flow (`isImmediatelyInvoked` in
/// `bindContainer`)? Async and generator functions are excluded, as they are
/// there: their bodies do not run to completion at the call.
fn iifeBody(c: *Checker, node: Node) Node {
    switch (c.nodeTag(node)) {
        .call_expr, .call_expr_targs => {},
        else => return null_node,
    }
    var callee = c.callShape(node).callee;
    while (c.nodeTag(callee) == .paren_expr) callee = c.tree.nodeData(callee).lhs;
    const cd = c.tree.nodeData(callee);
    switch (c.nodeTag(callee)) {
        .arrow_fn, .function_expr => {
            const proto = c.tree.extraData(ast.FnProto, cd.lhs);
            if (proto.flags & (ast.Flags.async | ast.Flags.generator) != 0) return null_node;
            return cd.rhs;
        },
        else => return null_node,
    }
}

/// Does the constructor body contain either construct whose flow ztsc models
/// more widely than tsc — an IIFE, or a `try` with a `finally`? Asked once per
/// constructor so that `writeHiddenFromFlow`, which is a walk per PROPERTY, is
/// only ever run for the constructors that can actually need it (a class with
/// forty uninitialized fields otherwise pays forty body walks for nothing).
fn ctorHasWidenedFlow(c: *Checker, node: Node) bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        .class_decl => return false,
        .arrow_fn, .function_expr, .function_decl, .object_method => return false,
        .try_stmt => {
            if (c.tree.extraData(ast.Try, c.tree.nodeData(node).rhs).finally_block != 0) return true;
        },
        else => {},
    }
    if (iifeBody(c, node) != null_node) return true;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (ctorHasWidenedFlow(c, child)) return true;
    }
    return false;
}

/// Does the constructor body write `this.<name>` somewhere ztsc's flow graph
/// cannot carry the write to the constructor's exit? Two constructs, both of
/// which tsc models more precisely:
///
///   * an IIFE — tsc binds its body into the containing flow, so
///     `(() => { this.x = v; })()` initializes `x`; ztsc gives every
///     function-like its own flow graph, and the write is invisible from
///     outside;
///   * the `try`/`catch` blocks of a `try … finally` — tsc's `FlowReduceLabel`
///     re-runs the finally body's flow restricted to the *normal exit* edges,
///     so `try { this.x = v; } finally {}` initializes `x`; ztsc has no reduce
///     label and joins the pre-`try` edge into the statement's exit, which
///     unions the write away.
///
/// Where the graph is too wide the flow verdict is "not assigned", so both would
/// manufacture a TS2564 on code tsc accepts. Suppressing on the syntactic write
/// is the under-reporting side of both — a write inside a *conditional* IIFE
/// (or one whose `try` sits in a branch) is a report tsc makes and ztsc does
/// not, which is the accepted direction.
fn writeHiddenFromFlow(c: *Checker, node: Node, name: intern.Atom, hidden: bool) Error!bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        // A nested class's members are not this constructor's writes, and a
        // non-invoked function body never runs at construction time.
        .class_decl => return false,
        .arrow_fn, .function_expr, .function_decl, .object_method => return false,
        .try_stmt => {
            const d = c.tree.nodeData(node);
            const e = c.tree.extraData(ast.Try, d.rhs);
            const lost = hidden or e.finally_block != 0;
            if (try writeHiddenFromFlow(c, d.lhs, name, lost)) return true;
            if (try writeHiddenFromFlow(c, e.catch_clause, name, lost)) return true;
            return writeHiddenFromFlow(c, e.finally_block, name, hidden);
        },
        .assign => {
            const d = c.tree.nodeData(node);
            // The same "initializes it" predicate `flow.definiteAssignOp` uses:
            // `&&=` is deliberately absent (its skipping branch keeps
            // `undefined`), so a hidden `this.x &&= v` suppresses nothing.
            const definite = switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                .eq, .pipe_pipe_eq, .question_question_eq => true,
                else => false,
            };
            if (hidden and definite and writesThisProp(c, d.lhs, name)) return true;
            if (try writeHiddenFromFlow(c, d.lhs, name, hidden)) return true;
            return writeHiddenFromFlow(c, d.rhs, name, hidden);
        },
        else => {},
    }
    const body = iifeBody(c, node);
    if (body != null_node and try writeHiddenFromFlow(c, body, name, true)) return true;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (try writeHiddenFromFlow(c, child, name, hidden)) return true;
    }
    return false;
}

/// Is `target` a write of `this.<name>` — either spelling (`this.name`,
/// `this["name"]`)? Used by `writeHiddenFromFlow`, which has no reference key
/// to hand and only needs the name.
fn writesThisProp(c: *Checker, target: Node, name: intern.Atom) bool {
    var n = target;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    const d = c.tree.nodeData(n);
    switch (c.nodeTag(n)) {
        .member_expr, .optional_member_expr => {
            if (c.nodeTag(d.lhs) != .this_expr) return false;
            return (c.memberAtom(d.rhs) catch return false) == name;
        },
        .index_expr, .optional_index_expr => {
            if (c.nodeTag(d.lhs) != .this_expr) return false;
            var idx = d.rhs;
            while (c.nodeTag(idx) == .paren_expr) idx = c.tree.nodeData(idx).lhs;
            if (c.nodeTag(idx) != .string_literal) return false;
            return (c.memberAtom(c.tree.nodeMainToken(idx)) catch return false) == name;
        },
        else => return false,
    }
}

/// TS2564 — tsc's `checkPropertyInitialization`, gated on
/// `strictNullChecks && strictPropertyInitialization` (both implied by
/// `strict`, which ztsc always runs) and on the class not being ambient.
///
/// For each candidate: with no constructor at all nothing can have been
/// assigned, so it reports; otherwise it asks the flow graph whether every path
/// out of the constructor wrote `this.<name>` — `thisPropUnassigned` at the
/// constructor's return join, tsc's `isPropertyInitializedInConstructor` over
/// `constructor.returnFlowNode`. Reported at the property NAME (tsc's
/// `member.name`), which is the field node's main token, so a modifier list
/// (`private readonly x: T`) does not move the column.
fn checkPropertyInit(c: *Checker, ctor: Node, widened: bool, cands: []const InitCand) Error!void {
    for (cands) |cand| {
        const tok = c.tree.nodeMainToken(cand.member);
        const name = try c.memberAtom(tok);
        if (try propAssignedInCtor(c, ctor, widened, name, cand.ty)) continue;
        try c.diagFmt(2564, c.tokSpan(tok), "Property '{s}' has no initializer and is not definitely assigned in the constructor.", .{c.tokenText(tok)});
    }
}

/// tsc's `isPropertyInitializedInConstructor`: does every path out of `ctor`
/// write `this.<name>`? With no constructor at all, nothing was assigned.
///
/// Shared by the two checks that ask it — TS2564 above and `heritage.zig`'s
/// TS2612 — because they must agree: a property the flow graph calls
/// initialized is exempt from both, and a divergence would report one class
/// of property twice and another not at all.
///
/// `widened` is `ctorHasWidenedFlow(body)`, hoisted by the caller so the
/// syntactic scan runs once per class rather than once per property.
pub fn propAssignedInCtor(c: *Checker, ctor: Node, widened: bool, name: intern.Atom, declared: TypeId) Error!bool {
    if (ctor == null_node) return false;
    const ret_flow = c.bind.flowAt(ctor) orelse return false;
    if (!try c.thisPropUnassigned(ret_flow, name, declared)) return true;
    // Writes ztsc's flow graph cannot see (an IIFE body, a `try` under a
    // `finally`) still initialize the property; see `writeHiddenFromFlow`.
    return widened and try writeHiddenFromFlow(c, c.tree.nodeData(ctor).rhs, name, false);
}

/// TS2565 — the `assumeUninitialized` half of tsc's
/// `getFlowTypeOfAccessExpression`: a `this.<name>` READ inside the constructor
/// of the class that declares `<name>`, reached on a path that has not written
/// it yet, is "used before being assigned".
///
/// tsc reaches it from the property-access checker, gated on
/// `getControlFlowContainer(node) === the constructor` and on the declaration
/// being a property with no `!` and no initializer — i.e. exactly the TS2564
/// candidate set (`abstract` differs, but an abstract member read in a
/// constructor is TS2715 there, not this). ztsc walks the constructor body for
/// those reads instead, which keeps the query off the property-access hot path:
/// the answer is a diagnostic only — the *type* of the read is the declared
/// type either way, which is already what ztsc's ordinary walk returns.
///
/// Writes are not reads: tsc's function returns before this check when the
/// access is a DEFINITE assignment target, so `this.x = v` is silent while the
/// read a compound `this.x += v` / `this.x++` performs is not.
fn checkPropertyUseBeforeAssigned(c: *Checker, body: Node, widened: bool, cands: []const InitCand) Error!void {
    if (!widened) return useBeforeAssignedWalk(c, body, cands, false);
    // A write ztsc's flow graph cannot carry (`writeHiddenFromFlow`) hides
    // itself from a read's query exactly as it does from the exit's, so the same
    // properties are dropped here.
    var live: std.ArrayList(InitCand) = .empty;
    defer live.deinit(c.scratch());
    for (cands) |cand| {
        const name = try c.memberAtom(c.tree.nodeMainToken(cand.member));
        if (try writeHiddenFromFlow(c, body, name, false)) continue;
        try live.append(c.scratch(), cand);
    }
    if (live.items.len == 0) return;
    try useBeforeAssignedWalk(c, body, live.items, false);
}

/// Walk one node of a constructor body looking for `this.<candidate>` reads.
/// `is_target` marks a subtree that is the left-hand side of a definite
/// assignment: the access at its root is a write (silent), but everything
/// *inside* it is still an ordinary read (`this.a.b = v` reads `this.a`), and a
/// destructuring pattern's element targets are writes in turn.
fn useBeforeAssignedWalk(c: *Checker, node: Node, cands: []const InitCand, is_target: bool) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        // A nested function or class is a different control-flow container, so
        // a `this.x` there is not this constructor's business (tsc's
        // `getControlFlowContainer`).
        .arrow_fn, .function_expr, .function_decl, .object_method, .class_decl => return,
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            if (!is_target and c.nodeTag(d.lhs) == .this_expr) {
                const name = try c.memberAtom(d.rhs);
                for (cands) |cand| {
                    if ((try c.memberAtom(c.tree.nodeMainToken(cand.member))) != name) continue;
                    if (c.bind.flowAt(node)) |flow| {
                        if (try c.thisPropUnassigned(flow, name, cand.ty)) {
                            try c.diagFmt(2565, c.tokSpan(d.rhs), "Property '{s}' is used before being assigned.", .{c.tokenText(d.rhs)});
                        }
                    }
                    break;
                }
            }
            return useBeforeAssignedWalk(c, d.lhs, cands, false);
        },
        .assign => {
            const d = c.tree.nodeData(node);
            // Here the predicate IS tsc's `getAssignmentTargetKind`, which puts
            // all three logical assignments in `Definite` and so returns from
            // `getFlowTypeOfAccessExpression` before the TS2565 check: the read
            // `this.x &&= v` performs is silent, even though the write does not
            // initialize `x` (see `flow.definiteAssignOp`).
            const definite = switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                .eq, .pipe_pipe_eq, .amp_amp_eq, .question_question_eq => true,
                else => false,
            };
            try useBeforeAssignedWalk(c, d.lhs, cands, definite);
            return useBeforeAssignedWalk(c, d.rhs, cands, false);
        },
        // Inside a destructuring target the element positions stay targets;
        // their defaults (the `.assign`/`binding_default` right side) do not,
        // which the arms above already separate.
        .object_literal, .array_literal, .object_property, .object_shorthand, .spread_element, .paren_expr => {
            if (is_target) {
                var it = c.tree.childIterator(node);
                while (it.next()) |child| try useBeforeAssignedWalk(c, child, cands, true);
                return;
            }
        },
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try useBeforeAssignedWalk(c, child, cands, false);
}

pub fn checkClass(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.ClassData, d.lhs);
    const saved_scope = c.cur_scope;
    const saved_this = c.this_type;
    defer {
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
    }
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    var class_sym: SymbolId = binder.no_symbol;
    if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(saved_scope, a)) |sym| {
            if (c.bind.symbol_flags[sym].class) class_sym = c.toGlobal(sym);
        }
    }

    // Instance type for `this` (generic: tp refs as args).
    var this_t: TypeId = types.any_type;
    if (class_sym != binder.no_symbol) {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(class_sym, &tps);
        var args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        this_t = try c.ts.makeRef(class_sym, args);
        // Eagerly expand so member diagnostics (7006, bad annotations)
        // fire even for unused classes.
        _ = try c.resolveStructural(this_t);
        _ = try c.classStaticType(class_sym);
        try evalTypeParamDecls(c, class_sym);
    }

    // Class-position decorators (`@deco class C {}`): evaluated in the
    // scope surrounding the class, with the enclosing `this`. Snapshot and
    // clear the pending set first so a nested decorated class inside a
    // member body cannot re-consume them.
    if (c.pending_class_decos.items.len > 0) {
        const decos = try c.scratch().dupe(Node, c.pending_class_decos.items);
        c.pending_class_decos.clearRetainingCapacity();
        const saved_ds = c.cur_scope;
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
        const class_val: TypeId = if (class_sym != binder.no_symbol)
            try c.ts.makeClassValue(class_sym)
        else
            types.any_type;
        for (decos) |deco| {
            const dt = try checkDecorator(c, deco);
            try decorators.checkClassDecoratorSig(c, deco, dt, class_val);
        }
        c.cur_scope = saved_ds;
    }

    // extends: base must be a class (checked in baseClassRef); type
    // args arity checked there too.
    if (class_sym != binder.no_symbol and data.extends != 0) {
        _ = try c.baseClassRef(class_sym);
        const hd = c.tree.nodeData(data.extends);
        // An AMBIENT class's `extends` clause is emitted nowhere, so tsc does
        // not treat it as a value reference: `import type { Base }` followed by
        // `declare class D extends Base<T>` is legal, and a `.d.ts` is ambient
        // throughout. Checking the heritage expression as a value there
        // reported a TS1361 tsc never issues — expo-modules-core's
        // `SharedObject.d.ts` (`import type { EventEmitter }` +
        // `declare class SharedObject … extends EventEmitter<TEventsMap>`) is
        // exactly that shape. A NON-ambient `class D extends Base` still checks
        // the expression, and still reports TS1361, because that clause is real
        // emitted code.
        if (!(c.ambient_ctx or data.flags & ast.Flags.declare != 0)) {
            _ = try c.checkExprCached(hd.lhs, types.no_type);
        }
        // tsc's order: the instance side first, and the static side only when
        // it passed (`checkClassLikeDeclaration`'s "Report static side error
        // only when instance type is assignable").
        const class_members = c.tree.extraRange(data.members_start, data.members_end);
        if (try checkInstanceSideExtends(c, class_sym, class_members, this_t, data.name_token)) {
            try checkStaticSideExtends(c, class_sym, data.name_token);
        }
    }

    // implements clauses: instance assignable to each interface. Skipped
    // entirely when the class inherits from a base ztsc could not resolve —
    // the instance type is then missing whatever that base contributed, and
    // the verdict would be about ztsc's gap, not the code.
    if (class_sym != binder.no_symbol and !try c.hasUnresolvedBase(class_sym)) {
        for (c.tree.extraRange(data.impl_start, data.impl_end)) |h| {
            if (h == null_node or c.nodeTag(h) != .heritage) continue;
            const hd = c.tree.nodeData(h);
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            if (hd.rhs != 0) {
                const rr = c.tree.extraData(ast.SubRange, hd.rhs);
                for (c.tree.extraRange(rr.start, rr.end)) |an| {
                    if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                }
            }
            const iface = try c.typeFromTypeName(hd.lhs, targs.items);
            if (iface != types.error_type and iface != types.any_type) {
                if (!try c.isAssignable(this_t, iface)) {
                    // tsc anchors the broad TS2420 at the class NAME
                    // (`issueMemberSpecificError`'s `node.name || node`),
                    // not at the heritage reference that failed — two
                    // failing `implements` clauses report twice on the
                    // same name.
                    try c.diagFmt(2420, c.tokSpan(data.name_token), "Class '{s}' incorrectly implements interface '{s}'.", .{
                        c.symbolName(class_sym), try c.typeToString(iface),
                    });
                }
            }
        }
    }

    // A concrete class must implement inherited abstract members.
    if (class_sym != binder.no_symbol) try c.checkAbstractImplementation(class_sym, node);

    const class_is_abstract = data.flags & ast.Flags.abstract != 0;

    // `strictPropertyInitialization` (implied by `strict`, and ztsc runs no
    // other mode) checks every instance property for a definite assignment.
    // tsc skips the whole check inside an AMBIENT class — a `declare class`, or
    // any class in a `.d.ts` or `declare namespace` body (`node.flags &
    // NodeFlags.Ambient`) — where there is no constructor body to analyze.
    // The candidates are collected as the members are checked and judged after
    // the loop, so the constructor's body is already checked when its flow is
    // queried. Foreign files are skipped for the same reason
    // `checkFunctionBody` skips them: `seal` drops their diagnostics, and their
    // bodies are never walked, so the query would have nothing to read.
    const check_prop_init = !(c.ambient_ctx or data.flags & ast.Flags.declare != 0) and
        c.owned_mask[c.cur_file];
    var init_cands: std.ArrayList(InitCand) = .empty;
    defer init_cands.deinit(c.scratch());

    // Members.
    const members = c.tree.extraRange(data.members_start, data.members_end);
    for (members, 0..) |member, mi| {
        if (member == null_node) continue;
        const md = c.tree.nodeData(member);
        switch (c.nodeTag(member)) {
            .class_field => {
                const e = c.tree.extraData(ast.Field, md.lhs);
                const is_static = e.flags & ast.Flags.static != 0;
                if (e.flags & ast.Flags.abstract != 0 and !class_is_abstract) {
                    try c.diagFmt(1244, c.tokSpan(c.tree.nodeMainToken(member)), "Abstract properties can only appear within an abstract class.", .{});
                }
                c.this_type = if (is_static and class_sym != binder.no_symbol)
                    try c.ts.makeClassValue(class_sym)
                else
                    this_t;
                var ann: TypeId = types.no_type;
                if (e.type_ann != 0) {
                    const ok = is_static and e.flags & ast.Flags.readonly != 0;
                    ann = try c.annTypeMaybeUnique(e.type_ann, ok, 1331, c.tokSpan(c.tree.nodeMainToken(member)));
                }
                if (check_prop_init and initCandidate(c, member, e, ann)) {
                    try init_cands.append(c.scratch(), .{ .member = member, .ty = ann });
                }
                // A `unique symbol` static-readonly field, like a const,
                // takes only a fresh `Symbol()` initializer without TS2322.
                if (e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and e.init != 0 and c.isFreshSymbolCall(e.init)) {
                    _ = try c.checkExprCached(e.init, ann);
                    continue;
                }
                if (e.init != 0) {
                    if (!is_static) try checkFieldInitSelfRefs(c, members, member, e.init);
                    // See `instance_field_init_depth`: an instance field's
                    // initializer runs at construction time, so a forward
                    // reference in it is not a TDZ use.
                    if (!is_static) c.instance_field_init_depth += 1;
                    defer if (!is_static) {
                        c.instance_field_init_depth -= 1;
                    };
                    const it = try c.checkExprCached(e.init, ann);
                    if (ann != types.no_type and ann != types.error_type) {
                        _ = try c.checkAssignable(it, ann, e.init, c.tokSpan(c.tree.nodeMainToken(member)));
                    }
                }
            },
            .class_method => {
                const proto = c.tree.extraData(ast.FnProto, md.lhs);
                const is_static = proto.flags & ast.Flags.static != 0;
                const is_abstract = proto.flags & ast.Flags.abstract != 0;
                if (is_abstract and !class_is_abstract) {
                    try c.diagFmt(1244, c.tokSpan(c.tree.nodeMainToken(member)), "Abstract methods can only appear within an abstract class.", .{});
                }
                if (is_abstract and md.rhs != 0) {
                    try c.diagFmt(1245, c.tokSpan(c.tree.nodeMainToken(member)), "Method '{s}' cannot have an implementation because it is marked abstract.", .{c.tokenText(c.tree.nodeMainToken(member))});
                }
                c.this_type = if (is_static and class_sym != binder.no_symbol)
                    try c.ts.makeClassValue(class_sym)
                else
                    this_t;
                const sig = try c.signatureOfProto(member, md.lhs, true, true);
                if (md.rhs != 0) {
                    const is_ctor = !is_static and c.isCtorName(try c.memberAtom(c.tree.nodeMainToken(member)));
                    const saved_ctor = c.ctor_class_sym;
                    if (is_ctor) c.ctor_class_sym = class_sym;
                    defer c.ctor_class_sym = saved_ctor;
                    try c.checkFunctionBody(member, md.lhs, md.rhs, sig, types.no_type);
                }
            },
            .decorator => {
                // A member decorator expression is evaluated in the scope
                // surrounding the class (at class-definition time), so its
                // `this` is the enclosing `this`, not the instance.
                c.this_type = saved_this;
                const dt = try checkDecorator(c, member);
                // The decorated member is the next non-decorator member.
                var target: Node = null_node;
                var k = mi + 1;
                while (k < members.len) : (k += 1) {
                    if (members[k] != null_node and c.nodeTag(members[k]) != .decorator) {
                        target = members[k];
                        break;
                    }
                }
                if (target != null_node) try checkMemberDecoratorSig(c, member, dt, target, this_t, class_sym);
            },
            else => {},
        }
    }

    // Both remaining checks read the constructor's FLOW, so they run after the
    // member walk has checked its body. `check_prop_init` is exactly "not
    // ambient, and this file is ours to report on" — the two conditions TS2612
    // needs as well, for the same two reasons (an ambient member emits no
    // field; a foreign file's flow is never built).
    const wants_2612 = class_sym != binder.no_symbol and check_prop_init and data.extends != 0;
    if (init_cands.items.len != 0 or wants_2612) {
        c.this_type = this_t;
        const ctor = constructorWithBody(c, members);
        const ctor_body = if (ctor == null_node) null_node else c.tree.nodeData(ctor).rhs;
        // One syntactic scan of the constructor body, shared by both checks.
        const widened = ctorHasWidenedFlow(c, ctor_body);
        if (init_cands.items.len != 0) {
            try checkPropertyInit(c, ctor, widened, init_cands.items);
            if (ctor != null_node) try checkPropertyUseBeforeAssigned(c, ctor_body, widened, init_cands.items);
        }
        if (wants_2612) {
            try heritage.checkBasePropertyOverwrites(c, class_sym, this_t, members, ctor, widened);
        }
    }
}

// Decorator checking lives in `decorators.zig`; re-exported here because the
// class walk above drives it and `Checker`'s method aliases name this file.
pub const DecoPos = decorators.DecoPos;
const checkDecorator = decorators.checkDecorator;
pub const checkDecoratorSig = decorators.checkDecoratorSig;
const checkMemberDecoratorSig = decorators.checkMemberDecoratorSig;
pub const decoAcceptsValue = decorators.decoAcceptsValue;
pub const decoCode = decorators.decoCode;
pub const decoContextMismatch = decorators.decoContextMismatch;
pub const decoContextName = decorators.decoContextName;
pub const decoContextRef = decorators.decoContextRef;
pub const decoSigMatches = decorators.decoSigMatches;
pub const globalSymNamed = decorators.globalSymNamed;

fn checkInterfaceDecl(c: *Checker, node: Node) Error!void {
    // Eagerly expand so member-type diagnostics (2304 in bodies, 7006 in
    // method signatures) fire even for unused interfaces.
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.InterfaceData, d.lhs);
    if (data.name_token == 0) return;
    const a = try c.atomOfToken(data.name_token);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
        if (c.bind.symbol_flags[sym].interface) {
            _ = try c.interfaceGeneric(c.toGlobal(sym));
            try evalTypeParamDecls(c, c.toGlobal(sym));
            try heritage.checkInterfaceExtends(c, c.toGlobal(sym), node, data.name_token);
        }
    }
}

fn checkTypeAliasDecl(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.TypeAlias, d.lhs);
    if (data.name_token == 0) return;
    const a = try c.atomOfToken(data.name_token);
    if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
        if (c.bind.symbol_flags[sym].type_alias) {
            _ = try c.aliasGeneric(c.toGlobal(sym));
            try evalTypeParamDecls(c, c.toGlobal(sym));
        }
    }
}

/// Eagerly evaluate type-parameter constraint/default annotations of a
/// generic declaration so their diagnostics fire during the owner's
/// file walk (partition-independent output; lazy paths only reach them
/// on instantiation). The declaration-site variance check (TS2636) rides
/// along here: its callers — class, interface and type alias — are exactly
/// the three declaration forms that HAVE declaration-site variance, and it
/// is the same "check what the type parameter list declares" pass.
fn evalTypeParamDecls(c: *Checker, sym: SymbolId) Error!void {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    for (tps.items) |tp| {
        // The constraint/default nodes belong to the *type parameter's*
        // declaring file, which for a merged interface need not be the
        // merged symbol's representative file (see `fixTypeArgs`).
        const saved = c.enterSymFile(tp.sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(tp.sym);
        if (tp.constraint != 0) _ = try c.typeFromTypeNode(tp.constraint);
        if (tp.default != 0) _ = try c.typeFromTypeNode(tp.default);
    }
    try c.checkVarianceAnnotations(sym);
}
