//! Expression checking. JSX lives in `jsx.zig` (re-exported below).
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const numeric_lit = @import("../numeric_lit.zig");
const modules = @import("../link/modules.zig");
const paths = @import("../link/paths.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const prof_zig = checker_zig.prof_zig;
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const accessibility = @import("accessibility.zig");
const calls_zig = @import("calls.zig");
const classes = @import("classes.zig");
const comma = @import("comma.zig");
const computed_key = @import("computed_key.zig");
const conditions = @import("conditions.zig");
const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const buildRefKey = @import("flow.zig").buildRefKey;
const checkAssignPatternExcessProps = @import("destructure.zig").checkAssignPatternExcessProps;
const checkFunctionBody = @import("stmts.zig").checkFunctionBody;
const containerOf = Checker.containerOf;
const ctxWantsTemplate = @import("generics.zig").ctxWantsTemplate;
const diagFmt = Checker.diagFmt;
const discriminate_ctx = @import("discriminate_ctx.zig");
const flowContainerOf = @import("flow.zig").flowContainerOf;
const flowTypeOfReference = @import("flow.zig").flowTypeOfReference;
const this_flow_root = @import("flow.zig").this_flow_root;
const gatherSpreadProps = @import("typenode.zig").gatherSpreadProps;
const globalThisType = @import("instantiate.zig").globalThisType;
const inForHeadWriteTarget = @import("flow.zig").inForHeadWriteTarget;
const names_zig = @import("names.zig");
const narrowable = @import("narrowable.zig");
const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const identity = @import("identity.zig");
const indexableConstituent = @import("typenode.zig").indexableConstituent;
const negatedBigIntLiteral = @import("typenode.zig").negatedBigIntLiteral;
const init = Checker.init;
const instantiate = @import("enums.zig").instantiate;
const isNonPrimitiveKind = @import("assign.zig").isNonPrimitiveKind;
const modvalue = @import("modvalue.zig");
const props_zig = @import("props.zig");
const propOfType = props_zig.propOfType;
const pushChainGuards = @import("flow.zig").pushChainGuards;
const reduceSubtypes = @import("typenode.zig").reduceSubtypes;
const resolveStructural = @import("instantiate.zig").resolveStructural;
const scratch = Checker.scratch;
const sig_zig = @import("signatures.zig");
const signatureOfProtoCtx = sig_zig.signatureOfProtoCtx;
const sliceTuple = @import("typenode.zig").sliceTuple;
const templateExprType = @import("generics.zig").templateExprType;
const tuple_relate = @import("tuple_relate.zig");
const tupleElemTypeAt = @import("assign.zig").tupleElemTypeAt;
const unassignedVarType = @import("flow.zig").unassignedVarType;
const uniqueSymAtom = Checker.uniqueSymAtom;
const upsertProp = @import("typenode.zig").upsertProp;
const widenLiteral = @import("names.zig").widenLiteral;

// =====================================================================
// expressions
// =====================================================================

/// Does tsc's `checkMode` — and so `CheckMode.SkipContextSensitive` — reach
/// this node's own subexpressions? The set is exactly the one
/// `isContextSensitive` recurses through: the forms whose type is built out
/// of a subexpression's type, so a context-sensitive part makes the whole
/// context sensitive. Everything else (a call, a member access, a function
/// BODY) starts a fresh, ordinary check.
fn skipModePropagates(c: *Checker, node: Node, tag: ast.Tag) bool {
    return switch (tag) {
        .paren_expr, .object_literal, .array_literal, .cond_expr => true,
        .binary => switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
            .pipe_pipe, .question_question => true,
            else => false,
        },
        else => false,
    };
}

pub fn checkExprCached(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    if (node == null_node) return types.any_type;
    // tsc's `CheckMode.SkipContextSensitive`, the first of a generic call's
    // two inference rounds: a context-sensitive function expression is
    // typed as `anyFunctionType` rather than walked. Its parameters have no
    // contextual type yet — the type arguments that would supply one are
    // what this round exists to infer — so walking it would only publish
    // implicit-`any` readings of its body and feed `inferFromTypes` a
    // source tsc refuses outright. The second round re-checks it for real.
    const saved_skip = c.skip_ctx_sensitive;
    if (saved_skip) {
        const tag = c.nodeTag(node);
        if ((tag == .arrow_fn or tag == .function_expr) and c.fnExprIsContextSensitive(node)) {
            c.aft_seen = true;
            return types.any_function_type;
        }
        if (!skipModePropagates(c, node, tag)) c.skip_ctx_sensitive = false;
    }
    defer c.skip_ctx_sensitive = saved_skip;
    // Anchor any TS2589 raised while materializing this expression's type
    // (instantiation limit) at the expression's span.
    c.anchorInst(node);
    // The outermost side query has returned: drop every per-symbol type it
    // memoized before this expression is walked under the authoritative
    // state (see `Checker.spec_sym_types` and `dropSpeculativeSymTypes`).
    if (c.side_query_depth == 0 and c.spec_sym_types.items.len != 0) c.dropSpeculativeSymTypes();
    const key = c.nodeKey(node);
    // A node still under the skip flag has a PROVISIONAL type — the real one
    // depends on properties this round deliberately did not read — so it
    // neither trusts nor fills the memo.
    if (!c.skip_ctx_sensitive) if (c.node_types.get(key)) |e| {
        if (e.ctx == ctx) {
            c.stats.node_type_hits += 1;
            return e.ty;
        }
    };
    c.stats.node_type_misses += 1;
    // Release this expression's scratch on the way out, the way an
    // `instantiateId` frame and a `relate` frame already do. An expression's
    // answer is an interned `TypeId`; every worklist, property buffer and
    // template builder its subtree made is dead at this return, and the
    // scratch arena's only other rewind point is the per-statement reset —
    // so a single long statement (a spec file's whole `describe`) otherwise
    // holds every byte its body ever touched. Placed BELOW the `node_types`
    // probe so a cache hit costs no mark/restore.
    //
    // This TIGHTENS the arena's contract from per-statement to
    // per-expression: a buffer allocated while checking an expression may no
    // longer be parked for later in the same statement. Buffers that do
    // cross frames today are all allocated by an OUTER frame and read by
    // that same outer frame (`planConcreteConditional`'s ids/vals,
    // `inferTypeArgs`' candidate buffers, `flow_loop_stack`'s `parts`), so
    // this mark sits strictly above them and cannot reach them. Anything
    // added later that allocates in scratch inside an expression and reads
    // it after that expression returns is a use-after-free.
    //
    // The arena is captured rather than re-read because a nested top-level
    // `instantiate` swaps a different one in for its own duration; frames do
    // run with `inst_arena` swapped in, and the swap is `defer`-balanced, so
    // the arena in hand at exit is always the one the mark was taken on.
    //
    // Measured on immich: peak RSS 1.12 -> 0.36 GB at one checker and
    // 2.40 -> 1.01 GB at four, diagnostics byte-identical over 36
    // package/app x checker-count comparisons, including under a build that
    // poisons every reclaimed range on `restore`.
    const em_arena = c.scratch_arena;
    const em_mark = em_arena.mark();
    defer em_arena.restore(em_mark);
    const t = try checkExpr(c, node, ctx);
    // A side query is speculative — it runs out of the checker's top-down
    // order — so it must not publish its answer for the authoritative
    // check to read back.
    if (c.side_query_depth == 0 and c.no_publish_depth == 0 and !c.skip_ctx_sensitive)
        try c.node_types.put(c.cm(), key, .{ .ty = t, .ctx = ctx });
    return t;
}

/// Where a `this` expression's receiver comes from — tsc's `getThisContainer`
/// with arrow functions skipped, which is both the container `tryGetThisTypeAt`
/// asks for a type and the one `checkThisExpression` switches on to refuse the
/// reference outright.
const ThisFrame = struct {
    kind: union(enum) {
        /// The nearest enclosing NON-arrow function-like.
        function: Node,
        /// A class body — a field initializer, a static block, a computed key.
        class_body,
        /// A `namespace` / `module` body: TS2331.
        namespace,
        /// An `enum` body: TS2332.
        enum_body,
        /// The file itself.
        file,
    } = .file,
    /// Did the walk cross an arrow on the way out? tsc's
    /// `capturedByArrowFunction`, which turns the global `this` into TS7041.
    via_arrow: bool = false,
};

fn thisFrame(c: *const Checker) ThisFrame {
    var via_arrow = false;
    var cur = c.cur_scope;
    while (cur != binder.file_scope) {
        switch (c.bind.scope_kinds[cur]) {
            .function => {
                const owner = c.bind.scope_owners[cur];
                // An arrow has no `this` of its own; the search continues out.
                if (c.nodeTag(owner) != .arrow_fn) {
                    return .{ .kind = .{ .function = owner }, .via_arrow = via_arrow };
                }
                via_arrow = true;
            },
            .class, .class_members, .class_statics => return .{ .kind = .class_body, .via_arrow = via_arrow },
            .namespace => return .{ .kind = .namespace, .via_arrow = via_arrow },
            .enum_body => return .{ .kind = .enum_body, .via_arrow = via_arrow },
            else => {},
        }
        cur = c.bind.scope_parents[cur];
    }
    return .{ .kind = .file, .via_arrow = via_arrow };
}

/// Does the function `this` resolves against have a receiver at all? tsc's
/// `tryGetThisTypeAt`, reduced to the yes/no the diagnostic needs:
///
///   * a class member — method, accessor, constructor — always does (the
///     instance type, or the static side);
///   * a function-like written as an object-literal member does (the literal's
///     own type, contextual or inferred) — `getContainingObjectLiteral`;
///   * a function with a `this` parameter of its own does, and so does one that
///     takes one from its contextual signature (`assignContextualParameterTypes`
///     copies the context's `thisParameter` onto the signature).
///
/// Everything else — a plain `function` declaration or expression, however
/// deeply nested inside a class or another `this`-bearing frame — does not.
fn thisFrameOwnsThis(c: *Checker, fn_node: Node) bool {
    switch (c.nodeTag(fn_node)) {
        .function_expr, .function_decl => {},
        // A class member (and anything else a `.function` scope can own) has a
        // receiver installed by its own walk.
        else => return true,
    }
    if (c.this_bound_fns.contains(thisBoundKey(c, fn_node))) return true;
    return sig_zig.declaresThisParam(c, c.tree.nodeData(fn_node).lhs);
}

/// `Checker.this_bound_fns` key for a function node in the CURRENT file.
fn thisBoundKey(c: *const Checker, fn_node: Node) u64 {
    return (@as(u64, c.cur_file) << 32) | fn_node;
}

/// Record that `fn_node` has a receiver of its own — see
/// `Checker.this_bound_fns`.
fn markThisBound(c: *Checker, fn_node: Node) Error!void {
    try c.this_bound_fns.put(c.cm(), thisBoundKey(c, fn_node), {});
}

/// `this`, narrowed the way tsc's `checkThisExpression` narrows it: both arms
/// of `tryGetThisTypeAt` — the function-like container and the class-body one —
/// hand their answer to `getFlowTypeOfReference(node, thisType)`, so every
/// guard that refines a named reference refines `this` too. The one that needs
/// it most is the `this is T` predicate: `if (this.hasData()) { const d:
/// Dataful = this }`. `flow.predicateOfCall` already hands the `this` node back
/// as such a guard's subject, and `flow.identIsSym` already answers the `this`
/// sentinel root with "is a `this_expr`", so the empty path over that root —
/// the same root `buildRefKey` mints for `this.p` — is a reference the walk can
/// match as-is; the binder's `.this_expr` arm gives the keyword the flow node
/// to query it at.
fn narrowThis(c: *Checker, node: Node, t: TypeId) Error!TypeId {
    return c.flowTypeOfKey(node, .{ .sym = this_flow_root }, t);
}

/// The same narrowing for a property/element access whose RECEIVER is `this`,
/// queried at the ACCESS rather than at the keyword. The two are the same flow
/// node by construction — a member expression is bound before its own children,
/// so `this.p` and the `this` inside it record one and the same `currentFlow` —
/// and the access is where the receiver's type is wanted.
fn narrowThisReceiver(c: *Checker, recv: Node, site: Node, t: TypeId) Error!TypeId {
    if (c.nodeTag(recv) != .this_expr) return t;
    return narrowThis(c, site, t);
}

fn atFileTopLevel(c: *const Checker) bool {
    var cur = c.cur_scope;
    while (cur != binder.file_scope) {
        switch (c.bind.scope_kinds[cur]) {
            .function, .class, .class_members, .class_statics, .namespace, .enum_body => return false,
            else => {},
        }
        cur = c.bind.scope_parents[cur];
    }
    return true;
}

fn checkExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const ewin = if (c.dprof.on) prof_zig.exprEnter(c, node) else prof_zig.DeclWin{};
    defer if (c.dprof.on) prof_zig.exprExit(c, ewin);
    const d = c.tree.nodeData(node);
    const main_tok = c.tree.nodeMainToken(node);
    switch (c.nodeTag(node)) {
        .identifier => return checkIdentifier(c, node, ctx),
        .number_literal => return c.ts.makeNumberLiteral(c.numberTokenValue(main_tok), true),
        .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(main_tok), true),
        .bigint_literal => return c.ts.makeBigIntLiteral(try c.atomOfToken(main_tok), true),
        // A tag's own template is the call's synthesized strings-array
        // argument, and answers with that argument's type (see
        // `checkTaggedTemplate`); everywhere else a no-substitution template
        // is its own string literal.
        .template_literal => return if (node == c.tagged_tpl)
            templateStringsArrayType(c)
        else
            c.ts.makeStringLiteral(try c.templateAtom(main_tok), true),
        .true_literal => return c.ts.makeBooleanLiteral(true, true),
        .false_literal => return c.ts.makeBooleanLiteral(false, true),
        .null_literal => return types.null_type,
        // tsc's `checkExpression` for a regular-expression literal is
        // `globalRegExpType`. `any` erased every method the lib declares on
        // it: `/x/.exec(s)` came back `any`, so a match's groups were `any`,
        // and nothing about a regex was ever wrong — `re.foo`, `re * 2`,
        // `re` where a string is wanted all passed.
        .regex_literal => return globalInterfaceType(c, "RegExp"),
        .this_expr => {
            const frame = thisFrame(c);
            // tsc's `checkThisExpression` switches on the container FIRST: a
            // namespace or enum body has no `this` at all, and says so before
            // the implicit-`any` report — which then follows, since
            // `tryGetThisTypeAt` has nothing to answer for either container.
            switch (frame.kind) {
                .namespace => try c.diagFmt(2331, c.nodeSpan(node), "'this' cannot be referenced in a module or namespace body.", .{}),
                .enum_body => try c.diagFmt(2332, c.nodeSpan(node), "'this' cannot be referenced in current location.", .{}),
                else => {},
            }
            switch (frame.kind) {
                // The container is a FUNCTION. It owns `this`, and when it has
                // none of its own the reference is implicitly `any` — TS2683.
                // `c.this_type` is NOT the test: it is inherited by a nested
                // plain function from whatever frame encloses it, which is
                // exactly the shape tsc reports (`class C { m() { function
                // inner() { this } } }`).
                .function => |fn_node| {
                    if (thisFrameOwnsThis(c, fn_node)) return narrowThis(c, node, c.this_type);
                },
                .namespace, .enum_body => {},
                .class_body, .file => {
                    if (c.this_type != 0) return narrowThis(c, node, c.this_type);
                    // tsc's `tryGetThisTypeAt(node, /*includeGlobalThis*/
                    // true)`: at the TOP LEVEL of a plain script — no enclosing
                    // function, class or namespace to own a `this` — `this` is
                    // the global object, `typeof globalThis`. That is what
                    // makes `++this` an arithmetic error (TS2356) rather than a
                    // reference error.
                    //
                    // Reaching it through an ARROW is TS7041 instead: the arrow
                    // closes over the *global* `this`, which is almost never
                    // what was meant (tsc's `capturedByArrowFunction` arm,
                    // which fires before the TS2683 one).
                    //
                    // The top level of a MODULE is `undefined` instead; that
                    // stays `any` here (documented gap), as does a class body
                    // whose own `this` the walk did not install.
                    if (frame.kind == .file and c.bind.imports.len == 0 and c.bind.exports.len == 0) {
                        if (frame.via_arrow) {
                            try c.diagFmt(7041, c.nodeSpan(node), "The containing arrow function captures the global value of 'this'.", .{});
                        }
                        return c.globalThisType();
                    }
                    return types.any_type;
                },
            }
            try c.diagFmt(2683, c.nodeSpan(node), "'this' implicitly has type 'any' because it does not have a type annotation.", .{});
            return types.any_type;
        },
        .super_expr => return types.any_type,
        // `new.target`: tsc types it as the enclosing constructor's own
        // type (the class's static side in a constructor, `typeof f` in a
        // plain function). The checker has no enclosing-function *symbol*
        // in hand here, so this is a documented under-report: `any`.
        .new_target => return types.any_type,
        .import_expr => return types.any_type,
        .omitted, .error_node, .unsupported => return types.any_type,
        .paren_expr => return c.checkExprCached(d.lhs, ctx),
        .seq_expr => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            try comma.checkCommaOperand(c, d.lhs);
            return c.checkExprCached(d.rhs, ctx);
        },
        .template_expr => {
            // When the contextual type wants a template-literal type — or
            // the expression sits in a CONST context (`` `a${b}` as const ``,
            // tsc's `checkTemplateExpression`: `isConstContext(node) ||
            // isTemplateLiteralContextualType(...)`) — keep the expression's
            // template structure (checkExprCached on each substitution
            // happens inside templateExprType); otherwise a template
            // expression is just `string`. Without the const-context arm
            // `` `setUint${BITS[bytes]}` as const `` widened to `string`,
            // which cannot index a `DataView` — a TS7053 false positive on
            // the standard "compute the accessor name" idiom.
            // A TAG's template is the call's synthesized strings-array
            // argument (tsc's `getEffectiveCallArguments`), and answers with
            // that argument's type. Its substitutions are the call's OTHER
            // arguments — `checkTaggedTemplate` hands them to the argument
            // walk, which is what contextually types them — so they are
            // deliberately not walked from here: doing both would check each
            // one twice, once under a contextual type this arm cannot know.
            if (node == c.tagged_tpl) return templateStringsArrayType(c);
            for (c.tree.nodeRange(node)) |sub| {
                if (sub != null_node) _ = try c.checkExprCached(sub, types.no_type);
            }
            // tsc folds a template expression that is a compile-time CONSTANT
            // to a fresh string literal *before* either of those two tests
            // (`checkTemplateExpression`: `const evaluated = node.parent.kind
            // !== TaggedTemplateExpression && evaluate(node).value; if
            // (evaluated !== undefined) return
            // getFreshTypeOfLiteralType(getStringLiteralType(evaluated))`).
            // See `evalConstToString`.
            if (try c.constTemplateAtom(node)) |a| return c.ts.makeStringLiteral(a, true);
            if (c.const_ctx or c.isConstTypeVar(ctx) or try c.ctxWantsTemplate(ctx)) return c.templateExprType(node);
            return types.string_type;
        },
        .tagged_template => return checkTaggedTemplate(c, node, ctx),
        // An array/object literal whose CONTEXTUAL type is a `const` type
        // parameter is checked in a const context — tsc's `isConstContext`
        // arm `isValidConstAssertionArgument(node) &&
        // isConstTypeVariable(getContextualType(node))`. The flag then
        // propagates to nested literals on its own (the `as const` path is
        // the same machinery), which is how tsc's upward `isConstContext`
        // walk through property assignments and array elements is matched.
        .array_literal, .object_literal => {
            const enter = !c.const_ctx and c.isConstTypeVar(ctx);
            const prev = c.const_ctx;
            if (enter) c.const_ctx = true;
            defer if (enter) {
                c.const_ctx = prev;
            };
            return if (c.nodeTag(node) == .array_literal)
                checkArrayLiteral(c, node, ctx)
            else
                checkObjectLiteral(c, node, ctx);
        },
        .member_expr, .optional_member_expr => return checkMemberExpr(c, node, ctx),
        .index_expr, .optional_index_expr => return checkIndexExpr(c, node, true, ctx),
        // A call/`new` CALLEE is in a constraint position (its apparent type is
        // where the overload set comes from). Announced around the whole call
        // rather than around the callee's own check, which lives in
        // `calls.zig`; the argument walk it also spans cannot see the
        // announcement, whose `nodeKey` matches the callee alone. `d.lhs` is the
        // callee in every one of these shapes (`callShape`).
        .call_expr, .call_expr_targs, .optional_call => {
            const saved = enterConstraintPos(c, d.lhs, null_node);
            defer c.constraint_pos = saved;
            // An IIFE's body returns into THIS call's contextual type — see
            // `Checker.iife_ret_ctx`. Announced here rather than in `calls.zig`
            // because the synthetic contextual signature an IIFE callee is
            // checked against is built before `ctx` is in reach there.
            const saved_iife_callee = c.iife_ret_ctx_callee;
            const saved_iife_ctx = c.iife_ret_ctx;
            defer {
                c.iife_ret_ctx_callee = saved_iife_callee;
                c.iife_ret_ctx = saved_iife_ctx;
            }
            if (ctx != types.no_type and d.lhs != null_node) {
                c.iife_ret_ctx_callee = c.nodeKey(skipParens(c, d.lhs));
                c.iife_ret_ctx = ctx;
            }
            return c.checkCallExpr(node, false, ctx);
        },
        .new_expr, .new_expr_targs, .new_expr_bare => {
            const saved = enterConstraintPos(c, d.lhs, null_node);
            defer c.constraint_pos = saved;
            return c.checkCallExpr(node, true, ctx);
        },
        .instantiation_expr => {
            const base = try c.checkExprCached(d.lhs, types.no_type);
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            return c.instantiationExprType(base, c.tree.extraRange(r.start, r.end), node);
        },
        .binary => return checkBinary(c, node, ctx),
        .assign => return checkAssignExpr(c, node),
        .cond_expr => {
            const e = c.tree.extraData(ast.CondExpr, d.rhs);
            // `enterCondition` before the condition is walked: a `&&` inside it
            // is judged by `checkBinary`, which needs to know it guards
            // `then_expr` (see `conditions.CondWalk`).
            const saved = conditions.enterCondition(c, d.lhs, e.then_expr);
            const cond_t = try c.checkExprCached(d.lhs, types.no_type);
            conditions.leaveCondition(c, saved);
            try conditions.checkTruthiness(c, d.lhs, cond_t);
            try conditions.checkUncalledFunction(c, d.lhs, cond_t, e.then_expr, false);
            const then_t = try c.checkExprCached(e.then_expr, ctx);
            const else_t = try c.checkExprCached(e.else_expr, ctx);
            // The arms are subtype-reduced, exactly as `||`/`??` are
            // (tsc: `getUnionType([type1, type2], UnionReduction.Subtype)`).
            return c.logicalUnion(then_t, else_t);
        },
        .prefix_unary => return checkPrefixUnary(c, node, ctx),
        .postfix_unary => {
            const ot = try incrementOperandType(c, d.lhs);
            if (try checkArithmeticOperand(c, try checkNonNullType(c, ot, d.lhs), d.lhs)) {
                _ = try checkReferenceExpression(c, d.lhs, .increment);
            }
            return types.number_type;
        },
        .non_null => {
            // A non-null assertion is transparent to contextual typing:
            // tsc's `getContextualType` hands a `NonNullExpression` its
            // parent's contextual type straight through. It is what lets a
            // generic whose type parameter appears *only* in the return
            // type infer from the target — `queryByTestId(el.querySelector(
            // ".x")!)` needs the parameter's `HTMLElement` to reach
            // `querySelector<E extends Element = Element>` and pick `E`,
            // instead of falling back to the default `Element`.
            const ot = try c.checkExprCached(d.lhs, ctx);
            return c.nonNullable(ot);
        },
        .as_expr => {
            // `expr as const`: a const assertion. Check the operand in
            // const context (readonly/non-widened literals) and return
            // that type; there is no target to compare against.
            // The assertion does not stop contextual typing — `.satisfies_expr`
            // below is the model. For `as const` the operand's context is the
            // OUTER one (a const assertion names no target of its own); for
            // `as T` it is `T`. Dropping it left the operand of
            // `((event) => { … }) as TFunction` with no contextual signature,
            // so its parameters reported TS7006 while the parenthesized
            // assertion-free sibling was fine.
            if (c.nodeTag(d.rhs) == .const_type) {
                const prev = c.const_ctx;
                c.const_ctx = true;
                defer c.const_ctx = prev;
                const et = try c.checkExprCached(d.lhs, ctx);
                // De-fresh a bare primitive literal so it does not widen.
                return c.ts.regularLiteral(et);
            }
            // The target type first: it is the operand's contextual type.
            const tt = try c.typeFromTypeNode(d.rhs);
            const et = try c.checkExprCached(d.lhs, tt);
            if (tt == types.error_type) return et;
            // tsc's `checkAssertionWorker` compares the target against
            // `getRegularTypeOfObjectLiteral(getBaseTypeOfLiteralType(exprType))`
            // — the source's literal types stand for their BASE primitives,
            // whether or not they are fresh. That is what makes
            // `` `calc(100% - ${8}px)` as '100%' `` legal (the source is judged
            // `string`), along with the plain `x as "def"` / `1 as 2` forms.
            if (!try c.castComparable(try c.baseTypeOfLiteral(try c.widenLiteral(et)), tt)) {
                try c.diagFmt(2352, c.nodeSpan(node), "Conversion of type '{s}' to type '{s}' may be a mistake because neither type sufficiently overlaps with the other. If this was intentional, convert the expression to 'unknown' first.", .{
                    try c.typeToString(et), try c.typeToString(tt),
                });
            }
            return tt;
        },
        .satisfies_expr => {
            // `expr satisfies T`: validate assignability to T but keep
            // the operand's own (narrow) type as the result.
            const tt = try c.typeFromTypeNode(d.rhs);
            const et = try c.checkExprCached(d.lhs, tt);
            if (tt == types.error_type) return et;
            // The HEAD diagnostic (TS1360, and whatever replaces it —
            // TS2741/2739/2559) anchors on the `satisfies` KEYWORD, not on
            // the operand: `checkSatisfiesExpressionWorker` passes the TYPE
            // side as its error node, whose span tsgo 7.0.2 reports starting
            // at the keyword. Per-property elaboration still blames the
            // property inside the operand, which is why only this span moves.
            _ = try c.checkSatisfies(et, tt, d.lhs, c.tokSpan(c.tree.nodeMainToken(node)));
            return et;
        },
        .arrow_fn, .function_expr => return checkFunctionLikeExpr(c, node, ctx),
        .class_decl => {
            // A class EXPRESSION. Its type is its class value (`typeof C`),
            // exactly what a reference to a class DECLARATION's name resolves
            // to — `typeOfSymbol` is the shared path, so a mixin's
            // base-type-variable intersection comes along for free. The symbol
            // lives in the class's own scope (`classes.classSymbolOf`); before
            // there was one, every class expression was `any`.
            const sym = try c.classSymbolOf(node, c.cur_scope);
            if (sym == binder.no_symbol) {
                try c.checkClass(node);
                return types.any_type;
            }
            // Static fields are contextually typed by this expression's own
            // contextual type, and the seeding has to happen before anything
            // demands them — see `statics.seedStaticFieldContext`.
            try c.seedStaticFieldContext(node, sym, ctx);
            try c.checkClass(node);
            return c.typeOfSymbol(sym);
        },
        .yield_expr => {
            // `yield x`: relate `x` to the generator's yield type `T`
            // (`Generator<T>`). Delegation `yield* x` (rhs=1) is unchecked
            // (iterable-protocol; a gap). `yield`'s own value type is `any`
            // (the caller-supplied `.next(v)` value — TNext, out of subset).
            // …but only inside a generator. tsc's `checkYieldExpression`
            // bails to `any` the moment `getContainingFunction` yields
            // nothing or a non-generator, BEFORE it ever looks at the
            // operand — so `class C { foo() { yield foo } }` is TS1163 and
            // nothing else, where checking the operand would add a TS2304
            // tsgo never reports. The question is syntactic, so it takes the
            // scope walk rather than the dynamic `fn_ctx` (see
            // `enclosingFnIsGenerator`).
            if (!enclosingFnIsGenerator(c)) return types.any_type;
            const yt: TypeId = if (c.fn_ctx) |fc| fc.yield_type else 0;
            const in_async = if (c.fn_ctx) |fc| fc.is_async else false;
            const delegate = d.rhs != 0;
            if (d.lhs != 0) {
                // tsc's `getContextualTypeForYieldOperand`. A DELEGATION
                // yields what its operand yields, so `yield* xs` types `xs`
                // by the generator's whole contextual return type
                // (`FnCtx.gen_ret_ctx`); a plain `yield x` types `x` by the
                // yield element — the annotation's when there is one, else the
                // contextual signature's (`FnCtx.yield_ctx`). Both of the
                // latter two are CONTEXTS: only `yt`, below, is related to.
                const ctx_yt: TypeId = if (delegate)
                    (if (c.fn_ctx) |fc| fc.gen_ret_ctx else 0)
                else if (yt != 0 and yt != types.no_type)
                    yt
                else if (c.fn_ctx) |fc| fc.yield_ctx else 0;
                const vt = try c.checkExprCached(d.lhs, ctx_yt);
                if (!delegate and yt != 0 and yt != types.no_type and yt != types.error_type and c.ts.kind(yt) != .any) {
                    // Async generators may yield `T | PromiseLike<T>`:
                    // the yielded value is awaited before it is emitted.
                    const eff_vt = if (in_async) try c.awaitedType(vt) else vt;
                    _ = try c.checkAssignable(eff_vt, yt, d.lhs, c.nodeSpan(d.lhs));
                }
            } else if (yt != 0 and yt != types.no_type and yt != types.error_type and c.ts.kind(yt) != .any) {
                // A BARE `yield;` still yields a value: tsc's
                // `checkYieldExpression` types a missing operand as
                // `undefinedWideningType` and relates it to the signature's
                // yield type just like an operand — so `function*
                // g(): IterableIterator<Foo> { yield; }` is TS2322 "Type
                // 'undefined' is not assignable to type 'Foo'". The blame
                // node is `node.expression || node`, i.e. the whole `yield`
                // expression when there is no operand.
                _ = try c.checkAssignable(types.undefined_type, yt, node, c.nodeSpan(node));
            }
            try checkYieldImplicitAny(c, node, ctx, delegate);
            return types.any_type;
        },
        .spread_element => {
            return c.checkExprCached(d.lhs, types.no_type);
        },
        .jsx_element => return c.checkJsxElement(node),
        else => {
            // Recovery leftovers: visit children, type any.
            var it = c.tree.childIterator(node);
            while (it.next()) |child| _ = try c.checkExprCached(child, types.no_type);
            return types.any_type;
        },
    }
}

/// TS7057, the tail of tsc's `checkYieldExpression`: a plain `yield` whose
/// containing generator has neither a return-type ANNOTATION nor a contextual
/// return type has nothing to give the expression but `any`, so under
/// `noImplicitAny` reading that value is an error. Four guards come with it:
///
///   * a DELEGATION (`yield* xs`) takes its type from the operand's iterable,
///     never from the generator's own next type, so it never reports;
///   * the value has to be READ — `yield x;` discards it (`discarded_expr`),
///     while `f(yield x)` and `r = yield x` do not;
///   * a contextual type for the yield expression itself supplies the missing
///     type, unless it is `any` and so supplies nothing;
///   * the generator has to be a function DECLARATION.
///
/// That last one stands in for tsc's `getContextualIterationType(Next, func)`,
/// which ztsc is in no position to answer at this node: the return-type
/// INFERENCE probe (`signatures.zig`) walks these same yields with none of the
/// contextual types the body check installs, and MEMOIZES the answer, so
/// whichever of the two runs first would decide whether a context was
/// "missing". A declaration settles it syntactically — nothing contextually
/// types one, so its lack of an annotation really is a lack of any type at all
/// — and it is the shape every generator this diagnostic is about has. A
/// generator EXPRESSION keeps its silence, which is the safe half.
fn checkYieldImplicitAny(c: *Checker, node: Node, ctx: TypeId, delegate: bool) Error!void {
    if (delegate or !c.prog.no_implicit_any) return;
    if (node == c.discarded_expr) return;
    const fn_node = enclosingFnNode(c);
    if (fn_node == null_node or c.nodeTag(fn_node) != .function_decl) return;
    // `gen_ret_ctx` is the WRITTEN annotation when there is one, which is
    // tsc's `getReturnTypeFromAnnotation` — the other half of the same test.
    const gen_ret = if (c.fn_ctx) |fc| fc.gen_ret_ctx else 0;
    if (gen_ret != 0 and gen_ret != types.no_type) return;
    if (ctx != 0 and ctx != types.no_type and c.ts.kind(ctx) != .any) return;
    try c.diagFmt(7057, c.nodeSpan(node), "'yield' expression implicitly results in an 'any' type because its containing generator lacks a return-type annotation.", .{});
}

/// The function-like that lexically contains the node now being checked —
/// tsc's `getContainingFunction`, which an arrow is NOT transparent to.
/// `null_node` at the top level of a file.
fn enclosingFnNode(c: *const Checker) Node {
    var cur = c.cur_scope;
    while (cur != binder.file_scope) {
        if (c.bind.scope_kinds[cur] == .function) return c.bind.scope_owners[cur];
        cur = c.bind.scope_parents[cur];
    }
    return null_node;
}

/// Is the function lexically enclosing the node now being checked a
/// generator? False at the top level of the file (no enclosing function) —
/// the sibling of `Checker.enclosingFnIsAsync`, and syntactic for the same
/// reason: `yield`'s legality is a property of the parser's `YieldContext`,
/// while `fn_ctx` describes whichever frame happens to be in flight when a
/// contextual type re-checks the expression.
///
/// An arrow is not transparent: `function* g() { const f = () => yield 1 }`
/// has the ARROW as its containing function, which is exactly why the
/// `yield` there is not a yield at all.
fn enclosingFnIsGenerator(c: *const Checker) bool {
    const owner = enclosingFnNode(c);
    if (owner == null_node) return false;
    const flags = switch (c.tree.nodeTag(owner)) {
        .arrow_fn, .function_expr, .function_decl, .class_method, .function_type => c.tree.extraData(ast.FnProto, c.tree.nodeData(owner).lhs).flags,
        // A class `static { … }` block — the one `.function` scope owned by a
        // `.block` (see `bindClass`). It is function-like to tsc's
        // `getContainingFunction` and never a generator.
        else => return false,
    };
    return flags & ast.Flags.generator != 0;
}

// =====================================================================
// JSX (`.tsx`) lives in `jsx.zig`; entered from `checkExpr`'s `.jsx_*`
// arms. Re-exported here so the `Checker` aliases in `checker.zig` and
// other modules' `@import("expr.zig")` keep resolving.
// =====================================================================

const jsx_zig = @import("jsx.zig");

pub const checkJsxElement = jsx_zig.checkJsxElement;
pub const isIntrinsicJsxTag = jsx_zig.isIntrinsicJsxTag;
pub const jsxNamespaceType = jsx_zig.jsxNamespaceType;
pub const jsxNamespaceMember = jsx_zig.jsxNamespaceMember;
pub const jsxRuntimeNamespaceMember = jsx_zig.jsxRuntimeNamespaceMember;
pub const jsxComponentProps = jsx_zig.jsxComponentProps;
pub const inferJsxTargs = jsx_zig.inferJsxTargs;
pub const jsxClassComponentProps = jsx_zig.jsxClassComponentProps;
pub const withIntrinsicClassAttributes = jsx_zig.withIntrinsicClassAttributes;
pub const jsxPropsMemberName = jsx_zig.jsxPropsMemberName;
pub const JsxAttr = jsx_zig.JsxAttr;
pub const checkJsxAttributes = jsx_zig.checkJsxAttributes;
pub const jsxAttrsObject = jsx_zig.jsxAttrsObject;
pub const jsxTargetString = jsx_zig.jsxTargetString;
pub const providedHas = jsx_zig.providedHas;
pub const JsxSpread = jsx_zig.JsxSpread;
pub const jsxSpreadInfo = jsx_zig.jsxSpreadInfo;
pub const JsxTargetShape = jsx_zig.JsxTargetShape;
pub const jsxTargetShape = jsx_zig.jsxTargetShape;
pub const jsxIntrinsicAttrNames = jsx_zig.jsxIntrinsicAttrNames;
pub const jsxChildrenAttrName = jsx_zig.jsxChildrenAttrName;
pub const jsxChildrenPresent = jsx_zig.jsxChildrenPresent;
pub const jsxSemanticChildCount = jsx_zig.jsxSemanticChildCount;
pub const jsxChildIsSemantic = jsx_zig.jsxChildIsSemantic;
pub const jsxChildCtxAt = jsx_zig.jsxChildCtxAt;
pub const jsxAttributeValueType = jsx_zig.jsxAttributeValueType;

/// Whether the type param `sym` appears at the *top level* of a signature's
/// return type `ret`: it is the whole return, or a member of a top-level
/// union/intersection (recursively). Mirrors tsc's `isTypeParameterAtTopLevel`
/// — a tuple element, an object property, or an array element is NOT top-level.
/// tsc keeps a literal inference candidate when its param is top-level in the
/// return (`id<T>(x: T): T` → `id(false)` stays `false`) and widens it
/// otherwise (`useState<S>(x): [S, …]` → `useState(false)` widens `S` to
/// `boolean`). A top-level named alias (`type Foo<S> = S | undefined`) is
/// resolved once so `S` is still found.
pub fn typeParamAtTopLevel(c: *Checker, ret: TypeId, sym: u32) Error!bool {
    // An interface/class instance is an object for every argument list, and an
    // object is neither a type parameter nor a union/intersection of them — so
    // the member table need not be materialized to say no. See
    // `refExpandsToObject`.
    if (c.refExpandsToObject(ret)) return false;
    const t = if (c.ts.kind(ret) == .ref) try c.resolveStructural(ret) else ret;
    switch (c.ts.kind(t)) {
        .type_param => return c.ts.typeParamSymbol(t) == sym,
        .union_type, .intersection => {
            for (try c.memberList(t)) |m| {
                switch (c.ts.kind(m)) {
                    .type_param => if (c.ts.typeParamSymbol(m) == sym) return true,
                    .union_type, .intersection => if (try c.typeParamAtTopLevel(m, sym)) return true,
                    else => {},
                }
            }
            return false;
        },
        else => return false,
    }
}

/// Whether a type-parameter constraint is (or contains, through a union /
/// intersection) a primitive, literal, enum, template-literal, string-mapping
/// or `keyof` type — tsc's `hasPrimitiveConstraint`. Such a constraint makes
/// tsc KEEP a literal inference candidate (mapped through
/// `getRegularTypeOfLiteralType`, not widened): `f<T extends 'a' | 'b'>(x: T)`
/// called with `'a'` fixes `T` to `'a'`, and `h<T extends string>(x: T): T[]`
/// keeps the passed string literal. `no_type` (no constraint) is not primitive.
pub fn constraintIsPrimitive(c: *Checker, constraint: TypeId) Error!bool {
    if (constraint == types.no_type) return false;
    return typeHasPrimitive(c, try c.resolveStructural(constraint));
}

fn typeHasPrimitive(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .string, .number, .boolean, .bigint, .symbol, .undefined, .null, .void, .never, .unique_symbol, .enum_type, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .template_literal_type, .string_mapping, .keyof_op => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (try typeHasPrimitive(c, try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Whether `t` is (or resolves to) an object whose string index signature is
/// `any` and which carries no required named properties — the `Record<string,
/// any>` shape (react-hook-form `FieldValues`). Such a constraint imposes no
/// real requirement, so a JSX-inferred object candidate should not be clamped
/// to it. Deliberately narrow: a concrete-valued index (`Record<string,
/// string>`) or an index-plus-required-props shape returns false.
pub fn constraintIsAnyIndex(c: *Checker, t: TypeId) Error!bool {
    if (t == types.no_type) return false;
    const r = try c.resolveStructural(t);
    if (c.ts.kind(r) != .object) return false;
    const sidx = c.ts.objectStringIndex(r);
    if (sidx == 0 or c.ts.kind(try c.resolveStructural(sidx)) != .any) return false;
    for (0..c.ts.objectPropCount(r)) |i| {
        if (!c.ts.objectProp(r, @intCast(i)).optional()) return false;
    }
    return true;
}

pub fn containsAtom(list: []const Atom, name: Atom) bool {
    for (list) |a| if (a == name) return true;
    return false;
}

/// A bare private name — the left operand of the ergonomic brand check
/// `#x in obj`, the one expression position the grammar admits it in. It
/// names a member of an enclosing class, which is not in the lexical scope
/// chain, so it never goes through `resolveSpace`.
///
/// A name no enclosing class declares keeps the generic not-found message:
/// tsc reports TS2339 against the type of the RIGHT operand there, which is
/// the `in` operator's to give, not this expression's.
fn checkPrivateName(c: *Checker, tok: TokenIndex, a: Atom) Error!TypeId {
    switch (names_zig.resolvePrivateName(c, a, c.cur_scope)) {
        .member => |local| return c.typeOfSymbol(c.toGlobal(local)),
        .outside_class => {
            try c.diagFmt(18016, c.tokSpan(tok), "Private identifiers are not allowed outside class bodies.", .{});
            return types.error_type;
        },
        .no_such_member => {
            try c.reportNameNotFound(tok);
            return types.error_type;
        },
    }
}

/// TS2686 — a VALUE-position name that reaches its symbol only through a UMD
/// global (`export as namespace X`), read from a file that is itself a module.
///
/// tsc's rule, in `resolveNameHelper`'s lazy-diagnostic block:
///
/// ```ts
/// if (result && isInExternalModule && (meaning & Value) === Value && …) {
///     const merged = getMergedSymbol(result);
///     if (length(merged.declarations) && every(merged.declarations, d =>
///             isNamespaceExportDeclaration(d) || isSourceFile(d) && !!d.symbol.globalExports)) {
///         errorOrSuggestion(!allowUmdGlobalAccess, errorLocation, …);
///     }
/// }
/// ```
///
/// A module that wants the module's exports has to import them; the global name
/// exists for scripts. Only the VALUE meaning is refused — `declare let y: Foo`
/// and `Foo.SubThing` in a type position are legal, which is why this lives in
/// the value-expression identifier arm and nowhere else.
///
/// ztsc reaches the same verdict without tsc's alias symbol. A UMD name is
/// published by a declaration file that is a MODULE, and the only way another
/// file can see such a file's top-level name without importing it IS the UMD
/// entry the linker splices into `globals` — whether the linker modeled it as
/// the synthetic namespace (`umdNamespace`) or as the `export = <entity>`
/// symbol the binder harvested (`umd8`'s `export = Thing; export as namespace
/// Foo`). So "the resolved symbol lives in a declaration module that publishes
/// this very name" is the whole test: an import binding, a local shadow, and a
/// script's or lib's own global all live somewhere else and answer false.
///
/// tsc's `every(merged.declarations, …)` is what keeps a name that ALSO has a
/// non-UMD declaration legal: `declare global { const React: typeof
/// import("./module") }` beside `export as namespace React` gives the merged
/// symbol a real global `const`, and a module may read that like any other
/// global. So EVERY contributor has to be a publisher of this name.
///
/// Cost: the flag tests are free, and the `export as namespace` scan behind
/// them walks ONE file's top-level statement tags — reached only by a value
/// name that resolves across a file boundary into a declaration module, which
/// apart from this pattern means a `declare global { … }` contribution.
fn isUmdGlobalRef(c: *Checker, a: Atom, sym: SymbolId) bool {
    if (!c.bind.is_module) return false; // a script may use the global freely
    // Own-file symbols answer without `symFile`'s binary search — this runs on
    // every value-position identifier, and a name declared here is never a UMD
    // global.
    if (!c.prog.isMergedId(sym)) {
        const base = c.prog.sym_base;
        if (sym >= base[c.cur_file] and sym < base[c.cur_file + 1]) return false;
    }
    if (c.prog.isMergedId(sym)) {
        const parts = c.prog.mergedSym(sym).parts;
        if (parts.len == 0) return false;
        for (parts) |p| if (!publishesUmdName(c, c.symFile(p), a)) return false;
        return true;
    }
    return publishesUmdName(c, c.symFile(sym), a);
}

/// Does `file` — some file other than the one being checked — carry
/// `export as namespace <a>`?
fn publishesUmdName(c: *Checker, file: modules.FileId, a: Atom) bool {
    if (file == c.cur_file) return false;
    const f = &c.prog.files[file];
    if (!f.bind.is_module or !paths.isDeclarationPath(f.path)) return false;
    const want = c.atomText(a);
    for (f.tree.nodeRange(ast.root_node)) |stmt| {
        if (f.tree.nodeTag(stmt) != .export_as_ns) continue;
        const tok: TokenIndex = @intCast(f.tree.nodeData(stmt).lhs);
        if (std.mem.eql(u8, f.tree.tokenSlice(f.src, tok), want)) return true;
    }
    return false;
}

fn checkIdentifier(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const tok = c.tree.nodeMainToken(node);
    if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
    const a = try c.atomOfToken(tok);
    if (c.tree.tokens.tag(tok) == .private_identifier) return checkPrivateName(c, tok, a);
    switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| {
            const f = c.symFlags(sym);
            if (isUmdGlobalRef(c, a, sym)) {
                try c.diagFmt(
                    2686,
                    c.tokSpan(tok),
                    "'{s}' refers to a UMD global, but the current file is a module. Consider adding an import instead.",
                    .{c.tokenText(tok)},
                );
            }
            // A namespace with no value in it is not a value (tsc's
            // `checkAndReportErrorForUsingNamespaceAsTypeOrValue`).
            if (modvalue.interesting(f) and try modvalue.valuelessNamespaceRef(c, sym, f)) {
                try c.diagFmt(2708, c.tokSpan(tok), "Cannot use namespace '{s}' as a value.", .{c.tokenText(tok)});
                return types.error_type;
            }
            // The alias is consulted only when the merged symbol has no value
            // meaning OF ITS OWN. tsc resolves the name in the Value meaning
            // and stops at the symbol it finds: a local `const X` merged with
            // `import { X }` — where the imported `X` is a type — is a
            // perfectly good value `X`, and no alias is resolved to contradict
            // it (`symbolMergeValueAndImportedType`).
            switch (try modvalue.aliasValueVerdict(c, sym, f)) {
                .has_value => {},
                .type_target => {
                    try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                    return types.error_type;
                },
                .export_type => {
                    try c.diagFmt(1362, c.tokSpan(tok), "'{s}' cannot be used as a value because it was exported using 'export type'.", .{c.tokenText(tok)});
                    return types.error_type;
                },
            }
            // tsc's `getNarrowableTypeForReference`: a type variable with a
            // union constraint enters the flow walk AS that constraint where
            // the constraint is what decides the outcome anyway (see
            // `narrowable.zig`), so a guard has constituents to filter.
            const declared = try c.narrowableRefType(node, try c.typeOfSymbol(sym), ctx);
            // TDZ (TS2448) is `void` — it contributes nothing to this
            // identifier's type — so the owned-file guard (see
            // `checkJsxElement`) applies: in a file this checker does not own,
            // `seal` drops whatever it reports, and the only state it touches
            // is `da_cache`, a pure (flow, sym) memo that every reader
            // re-derives on miss.
            if (c.owned_mask[c.cur_file]) {
                if ((f.let_decl or f.const_decl or f.class or f.enum_decl) and !f.function and !f.var_decl and !f.param) {
                    try checkTdz(c, sym, node, tok);
                }
            }
            // Flow narrowing. A binding destructured out of a discriminated
            // union has no flow of its own that a guard on a SIBLING binding
            // touches, so its parent union is narrowed as a pseudo-reference
            // first (tsc's `getNarrowedTypeOfSymbol`); the ordinary walk still
            // runs on top of whatever that yields.
            const walk_from = (try c.narrowedPatternBinding(node, sym)) orelse declared;
            const narrowed = try c.flowTypeOfReference(node, sym, walk_from);
            // Definite assignment (TS2454) is NOT `void`: tsc returns the
            // DECLARED type for a reference it convicts, "to reduce follow-on
            // errors", so the narrowing that would otherwise apply is dropped
            // and the follow-on assignability errors survive. The VERDICT is
            // therefore part of this identifier's TYPE, and a type may not
            // depend on which checker got the file — so unlike the two `void`
            // diagnostics around it, the verdict cannot live under
            // `owned_mask`. Only the REPORT does.
            //
            // Outside the owning checker the walk is still skipped whenever
            // narrowing did not MOVE the type: `narrowed == declared` is the
            // answer either way then, convicted or not. That is what keeps the
            // cost off the ordinary reference — a `const x = f(); … x` under no
            // guard never reaches the definite-assignment walk in the three
            // checkers that only need its type (measured: without the gate,
            // social-app's peak RSS rose 4%).
            var unassigned = false;
            if ((f.let_decl or f.var_decl or f.const_decl) and !f.param and
                // A computed member name is evaluated outside its
                // container's flow, so nothing read there is "used before
                // being assigned" (`Checker.in_computed_member_name`).
                // (wave-10 A: one flagged guard.)
                !c.in_computed_member_name and
                (c.owned_mask[c.cur_file] or narrowed != declared))
            {
                // A `const` is asked too: its initializer is what makes it
                // definitely assigned, and a read in its TEMPORAL DEAD ZONE
                // has not run that initializer yet — tsc reports TS2448 and
                // TS2454 together there (`exportBinding`'s `export default
                // x` ahead of `const x = 'x'`).
                unassigned = try useBeforeAssignedVerdict(c, sym, node, declared);
                if (c.owned_mask[c.cur_file]) {
                    if (unassigned) {
                        try c.diagFmt(2454, c.tokSpan(tok), "Variable '{s}' is used before being assigned.", .{c.tokenText(tok)});
                    }
                    try checkEvolvingVarRead(c, sym, node, tok, declared);
                }
            }
            // "Return the declared type to reduce follow-on errors"
            // (`checkIdentifier`, right after the TS2454 `error()`).
            return if (unassigned) declared else narrowed;
        },
        .wrong_space => |sym| {
            const wf = c.symFlags(sym);
            if (wf.import_binding and wf.type_only) {
                // Not in a position that would be emitted (see
                // `Checker.in_type_space_name`) — tsc's `markAliasReferenced`
                // never runs there. (wave-10 A: one flagged guard.)
                if (!c.in_type_space_name) {
                    try c.diagFmt(1361, c.tokSpan(tok), "'{s}' cannot be used as a value because it was imported using 'import type'.", .{c.tokenText(tok)});
                }
                return types.error_type;
            }
            // The implicit `arguments` object outranks a declaration with no
            // value meaning. tsc's `resolveNameHelper` answers `arguments` at
            // the nearest function-like location, and it does so AFTER that
            // location's own locals have been filtered by meaning — so an
            // `interface arguments {}` is skipped at every level of the walk
            // and never reaches the name
            // (`functionDeclarationWithResolutionOfTypeNamedArguments01`).
            if (std.mem.eql(u8, c.atomText(a), "arguments")) {
                if (try c.implicitArgumentsType(c.nodeSpan(node))) |t| return t;
            }
            try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
            return types.error_type;
        },
        .none => {
            // `globalThis` is always in scope: the global-scope object,
            // whose members are the program's global value declarations
            // (see `globalThisType`).
            if (std.mem.eql(u8, c.atomText(a), "globalThis")) return c.globalThisType();
            // `arguments` is implicit in every non-arrow function body (tsc
            // has no symbol for it either — `checkIdentifier` answers
            // `getGlobalIArgumentsType()` once `isInsideFunction` holds).
            if (std.mem.eql(u8, c.atomText(a), "arguments")) {
                // The span is for the one boundary that answers with a
                // diagnostic instead of a type (TS2815 in a class static block).
                if (try c.implicitArgumentsType(c.nodeSpan(node))) |t| return t;
            }
            // A primitive TYPE name in a value position is TS2693, ahead of
            // both the suggestion and the not-found message (tsc's
            // `checkAndReportErrorForUsingTypeAsValue`).
            if (names_zig.primitiveTypeNameUsedAsValue(c.tokenText(tok))) {
                try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                return types.error_type;
            }
            if (c.suggestName(a, c.cur_scope, true)) |sugg| {
                try c.diagFmt(2552, c.tokSpan(tok), "Cannot find name '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
            } else {
                try c.reportNameNotFound(tok);
            }
            return types.error_type;
        },
    }
}

fn checkTdz(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex) Error!void {
    _ = node;
    if (c.symFile(sym) != c.cur_file) return; // cross-file: no TDZ
    const decls = c.declsOf(sym);
    if (decls.len == 0) return;
    const decl_start = c.nodeSpanStart(decls[0]);
    const use_start = c.tree.tokens.start(tok);
    if (use_start >= decl_start) return;
    // Uses inside a *nested function* run later — no TDZ error. So does a
    // use inside a NON-STATIC class field initializer, which runs at
    // construction time rather than at class-definition time; tsc's
    // `isUsedInFunctionOrInstanceProperty` puts the two in the same clause.
    // `containerOf` maps a field initializer back to the module scope, so
    // the container test alone cannot see it.
    if (c.instance_field_init_depth > 0) return;
    // …and so does a use inside a computed member NAME that tsc's
    // `isBlockScopedNameDeclaredBeforeUse` exempts — see
    // `Checker.defer_computed_key_tdz`. `forwardRefInTypeDeclaration.ts` is the
    // case: `interface Foo2 { [s2]: number }` before `const s2 = "x"` is legal,
    // and so is the same key in a type literal, a `declare class` and a class
    // method, while a non-ambient class FIELD still reports.
    // (wave-10 A: one flagged guard.)
    if (c.defer_computed_key_tdz) return;
    // …and so does the operand of `export = X`, which tsc's
    // `isBlockScopedNameDeclaredBeforeUse` exempts outright: the export
    // statement moves during emit, so `export = T` before `class T {}` has no
    // dead zone to be in. See `Checker.in_export_equals_target`.
    if (c.in_export_equals_target) return;
    const use_container = c.containerOf(c.cur_scope);
    const decl_container = c.containerOf(c.symScope(sym));
    if (use_container != decl_container) return;
    // tsc's `checkResolvedBlockScopedVariable` picks a DIFFERENT code per
    // symbol kind, not just a different noun: a block-scoped variable is
    // TS2448, a class TS2449, a (non-const) enum TS2450. A `const enum` is
    // exempt unless `preserveConstEnums` — nothing is emitted for it, so
    // there is no runtime binding to be in a temporal dead zone.
    const f = c.symFlags(sym);
    var code: u16 = 2448;
    var kindname: []const u8 = "Block-scoped variable";
    if (f.class) {
        code = 2449;
        kindname = "Class";
    } else if (f.enum_decl) {
        if (constEnumOnly(c, decls)) return;
        code = 2450;
        kindname = "Enum";
    }
    try c.diagFmt(code, c.tokSpan(tok), "{s} '{s}' used before its declaration.", .{ kindname, c.tokenText(tok) });
}

/// Every enum declaration of the symbol is `const enum` — a declaration merge
/// may mix them, and one non-const block gives the whole enum a runtime
/// binding. See `checkTdz`.
fn constEnumOnly(c: *Checker, decls: []const Node) bool {
    for (decls) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const e = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        if (e.flags & ast.Flags.const_enum == 0) return false;
    }
    return true;
}

/// tsc's `symbol.valueDeclaration` for a variable symbol: the FIRST
/// declarator among its declarations. Which one it is matters, because the
/// modifier rules below read that declaration alone and a merged symbol can
/// mix them — `var i: I; declare var i: I;` is an ordinary variable that
/// happens to also have an ambient declaration, and tsc still reports it
/// unassigned. A merge may also lead with a TYPE-space declaration
/// (`interface Array` beside `declare var Array: ArrayConstructor`), which is
/// not the value declaration and is skipped.
fn valueDeclarator(c: *Checker, decls: []const Node) ?Node {
    for (decls) |decl| switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full => return decl,
        else => {},
    };
    return null;
}

/// Was `decl` written in an ambient context? The parser records tsc's
/// `NodeFlags.Ambient` on the declarator itself (see `parseDeclarator`).
fn isAmbientDeclarator(c: *Checker, decl: Node) bool {
    if (c.nodeTag(decl) != .declarator_full) return false;
    const e = c.tree.extraData(ast.DeclaratorFull, c.tree.nodeData(decl).rhs);
    return e.flags & ast.Flags.declare != 0;
}

/// tsc's auto-type arm of `checkIdentifier`:
///
/// ```ts
/// if (!isEvolvingArrayOperationTarget(node) && (type === autoType || type === autoArrayType)) {
///     if (flowType === autoType || flowType === autoArrayType) {
///         if (noImplicitAny) { error(nameOfDeclaration, TS7034); error(node, TS7005); }
/// ```
///
/// An evolving (`auto`-typed) variable is one tsc control-flow types instead of
/// giving it a declared type: `var x;` / `let x = null;`, no annotation, not
/// `const`, not exported and not ambient. Inside its OWN flow container that
/// always resolves — the initial type there is `undefined`, so a read before any
/// assignment is TS2454's business and not this one. Read from a CLOSURE it does
/// not: tsc re-runs the flow from the closure's start with the auto type as the
/// initial type, so no assignment anywhere else can help, and a read that no
/// assignment inside the closure precedes really is an implicit `any`
/// (`var x; x = 1; function g() { x }` reports — oracle-verified against tsgo).
///
/// Both diagnostics are reported: TS7034 on the DECLARATION's name (once, by
/// `diagFmt`'s span dedupe, however many reads there are) and TS7005 on the read.
///
/// The evolving ARRAY half — `let x = []`, `const x = []`, and a `let x;` that
/// an `x = []` reaches — is the other spelling tsc's `type === autoType ||
/// type === autoArrayType` admits, and its test is the literal one: *is the
/// flow type at this read still the auto array*, i.e. did no `x.push(v)` /
/// `x[i] = v` / non-empty assignment ever reach it (`flow.evolvingArrayStillAuto`).
/// That is a strictly different question from the closure-crossing rule below,
/// which is what the plain auto type needs — a same-container read of a
/// never-pushed array reports, while a same-container read of a `let x;` is
/// TS2454's business — so the two are asked separately and the array half,
/// being the more specific, is asked first.
fn checkEvolvingVarRead(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex, declared: TypeId) Error!void {
    // The cheap type test gates the (syntactic, several-indirection) one, and
    // this runs for every `let`/`var`/`const` identifier read: ztsc types a
    // bare `[]` as `any[]`, so nothing but an `any[]` can be an evolving array.
    const array_var = c.ts.kind(declared) == .array and
        c.ts.arrayElem(declared) == types.any_type and c.isEvolvingArrayVar(sym);
    const f = c.symFlags(sym);
    // A `const` has only the array half to answer for; the plain auto type is
    // `let`/`var` only (`signatures.isEvolvingVar`).
    if (f.const_decl) {
        if (!array_var) return;
    } else if (!array_var and !c.isEvolvingVar(sym)) return;
    // tsc's `!(getCombinedModifierFlags(declaration) & Export) && !(declaration.flags & Ambient)`:
    // neither shape gets the auto type at all (an ambient `declare var x;` is
    // plain `any`, and reports its implicit `any` at the declaration instead).
    if (f.exported) return;
    const decls = c.declsOf(sym);
    if (decls.len == 0) return;
    if (c.ambient_ctx or isAmbientDeclarator(c, decls[0])) return;
    // A `for..in`/`for..of` HEAD declarator takes its type from the iterable, not
    // from the control flow — tsc's auto-type branch is reached only for a
    // declarator whose type has no other source. Recognized on the token after
    // the name, which is the whole of what distinguishes the two shapes
    // (`for (var v of xs)` vs `var v;`), and `isEvolvingVar` has already
    // restricted the declarator to a plain identifier binding.
    switch (c.tree.tokens.tag(c.tree.nodeMainToken(decls[0]) + 1)) {
        .keyword_of, .keyword_in => return,
        else => {},
    }
    if (try c.evolvingArrayStillAuto(node, sym, declared)) {
        const aname = c.tokenText(tok);
        try c.diagFmt(7034, c.tokSpan(c.tree.nodeMainToken(decls[0])), "Variable '{s}' implicitly has type 'any[]' in some locations where its type cannot be determined.", .{aname});
        try c.diagFmt(7005, c.tokSpan(tok), "Variable '{s}' implicitly has an 'any[]' type.", .{aname});
        return;
    }
    // An evolving ARRAY has no second question to ask: the closure-crossing
    // rule below is the plain auto type's, and tsc's array arm is the flow
    // type test alone. (A `const` never reaches it either — see the top.)
    if (array_var or f.const_decl) return;
    // tsc's `isParameterOrMutableLocalVariable(symbol) && isPastLastAssignment(…)`
    // arm of the flow-container walk that precedes the check: for a MUTABLE LOCAL
    // `let` the analysis is hoisted back out to the declaration's own container,
    // which makes the initial type `undefined` instead of the auto type — so the
    // pair is never reported for one. `isMutableLocalVariableDeclaration` reads
    // `NodeFlags.Let` (a `var` is not one, however local) and excludes an
    // exported binding and the top level of a SCRIPT, whose top level IS the
    // global scope. Oracle-verified in both directions: a module-level or
    // function-local `let` read from a closure is silent, while the same shapes
    // spelled `var`, and a script-global `let`, report.
    //
    // Leaving the `isPastLastAssignment` half out costs a `let` that IS assigned
    // somewhere (tsgo reports `let v; v = 1; function f() { v }`); reproducing it
    // needs tsc's per-container last-assignment scan, and under-reporting is the
    // safe half to keep.
    if (f.let_decl and !f.var_decl) {
        // tsc's exclusion is narrow: `declaration.parent.parent.kind ===
        // VariableStatement && isGlobalSourceFile(declaration.parent.parent.parent)`
        // — a `let` STATEMENT at the top level of a script, and nothing else. A
        // `let` in a `for` head or inside a block is a mutable local even there,
        // so the declaration's own SCOPE has to be the file scope, not merely its
        // function container (`for (let x;;) { () => x }` reports nothing).
        if (!(c.bind.scope_kinds[c.symScope(sym)] == .file and !c.bind.is_module)) return;
    }
    // Only a read from another flow container — see above.
    if (flowContainerOf(c, c.cur_scope) == flowContainerOf(c, c.symScope(sym))) return;
    const flow = c.bind.flowAt(node) orelse return;
    if (try c.someAssignmentReaches(flow, sym)) return;
    const name = c.tokenText(tok);
    try c.diagFmt(7034, c.tokSpan(c.tree.nodeMainToken(decls[0])), "Variable '{s}' implicitly has type 'any' in some locations where its type cannot be determined.", .{name});
    try c.diagFmt(7005, c.tokSpan(tok), "Variable '{s}' implicitly has an 'any' type.", .{name});
}

/// tsc's `assumeInitialized` chain, inverted: is this reference one tsc reports
/// TS2454 on? A VERDICT rather than a check, because tsc's answer is not only
/// the diagnostic — a convicted reference also takes the DECLARED type instead
/// of the narrowed one, so every checker has to reach the same conclusion
/// whether or not it owns the file (see the call site in `checkIdentifier`).
fn useBeforeAssignedVerdict(c: *Checker, sym: SymbolId, node: Node, declared: TypeId) Error!bool {
    // Only for declarations without initializer whose type excludes
    // undefined/any, used in the same function container.
    if (c.symFile(sym) != c.cur_file) return false; // cross-file: assigned
    const tok = c.tree.nodeMainToken(node);
    const decls = c.declsOf(sym);
    var has_init = false;
    var has_definite = false;
    for (decls) |decl| {
        switch (c.nodeTag(decl)) {
            .declarator_init => has_init = true,
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, c.tree.nodeData(decl).rhs);
                if (e.init != 0) has_init = true;
                if (e.flags & ast.Flags.definite != 0) has_definite = true;
            },
            .declarator => {},
            else => has_init = true, // params, for-of bindings, recovery
        }
    }
    // An AMBIENT declaration (`declare var x: T`, or any `var`/`let` in a
    // `.d.ts` / `declare namespace` / `declare global` body) has no
    // initializer to write, so the flow walk always reports it unassigned —
    // but it describes something the runtime already provides. tsc closes
    // `assumeInitialized` on `declaration.flags & NodeFlags.Ambient` before
    // any flow analysis and regardless of where the use sits, so a use even
    // ahead of the declaration is exempt too.
    if (valueDeclarator(c, decls)) |vd| {
        if (isAmbientDeclarator(c, vd)) return false;
    }
    // tsc's `isOuterVariable`, class-field half: `getControlFlowContainer`
    // stops at a PropertyDeclaration, so a field initializer is its own flow
    // region and anything declared outside it is OUTER — assumed initialized,
    // static field included (`field_init_depth`).
    //
    // Only for a reference the field initializer itself owns. A function
    // WRITTEN in that initializer is the innermost container of its own body,
    // and takes the region back: `x = <U>(a: U) => { var y: T; return y }`
    // still reports (`typeParametersAvailableInNestedScope`).
    if (c.field_init_depth > 0 and
        c.bind.scope_kinds[flowContainerOf(c, c.cur_scope)] != .function) return false;
    // tsc's `isOuterVariable`, namespace half. `getControlFlowContainer` stops
    // at a MODULE BLOCK, and two blocks of one `namespace N` are two blocks
    // with two flow graphs — while the binder folds their members into a
    // single scope, so the `flowContainerOf` comparison below sees one
    // container. A declaration in another block (or outside every block) is
    // OUTER, and an outer variable is assumed initialized whatever this
    // block's flow says: `namespace M { export var v = 10 } namespace M { v }`
    // is clean (`mergedModuleDeclarationWithSharedExportedVar`,
    // `moduleVariables`, `collisionCodeGenModuleWithModuleReopening`).
    //
    // "In another block" is asked of EVERY declaration, not just the first:
    // ztsc folds the merged blocks into one scope, so two blocks that each
    // write `var a` share one symbol where tsc has two (a non-exported member
    // is a local of its own block). A block that declares the name again is
    // that declaration's container, and the check applies normally
    // (`mergeTwoInterfaces2`).
    if (c.cur_ns_block != null_node and decls.len > 0) {
        const blk = c.nodeSpan(c.cur_ns_block);
        var in_block = false;
        for (decls) |dn| {
            const at = c.nodeSpanStart(dn);
            if (at >= blk.start and at < blk.end) {
                in_block = true;
                break;
            }
        }
        if (!in_block) return false;
    }
    // A use *before* the declaration (TDZ position) is also
    // definitely-unassigned even when the declarator has an
    // initializer (tsc reports 2448 + 2454 together).
    var before_decl = false;
    if (decls.len > 0) {
        if (c.tree.tokens.start(tok) < c.nodeSpanStart(decls[0])) before_decl = true;
        // tsc's `isSameScopedBindingElement`: a DESTRUCTURED binding read from
        // inside its own root declarator is assumed initialized. The default
        // initializers of one pattern run left to right, and tsc models that
        // as declaration order rather than as flow — `const { width = 512,
        // height = width } = opts` and `const [p = 1, q = p] = arr` are both
        // clean (oracle-verified). Only a pattern qualifies; `let z = z` on a
        // plain identifier keeps its TS2454.
        if (c.nodeTag(c.tree.nodeData(decls[0]).lhs) != .identifier) {
            const span = c.nodeSpan(decls[0]);
            const at = c.tree.tokens.start(tok);
            if (at >= span.start and at < span.end) return false;
        }
    }
    // An INITIALIZER is not an exemption: tsc's `assumeInitialized` never asks
    // whether the declarator has one, only whether the flow reaching this
    // reference passed it. `if (c) { var a = 1 } a;`, `try { var b = 1 } catch
    // {} b;` and `while (c) { var d = 1 } d;` are all TS2454, and so is every
    // read whose path bypasses the declaration statement
    // (`controlFlowDestructuringVariablesInTryCatch`, `parserUnicode1`).
    // `definitelyAssigned` below is what decides, and for the straight-line
    // `const x = 1; … x` that is one memoized walk back to the declarator's own
    // assign node. The `!` (definite assignment) modifier IS tsc's exemption
    // (`declaration.exclamationToken`), and stays one.
    if (has_definite and !before_decl) return false;
    const dk = c.ts.kind(declared);
    if (dk == .any or dk == .err or dk == .unknown or dk == .void or dk == .none) return false;
    if (c.containsUndefinedish(declared)) return false;
    // `for (x of xs)` / `for ({ a: x } of xs)`: the head's target is a WRITE.
    // After the type guards above, which are array reads — this one walks the
    // scope chain (and, on a name hit, one node span).
    if (try inForHeadWriteTarget(c, node, sym)) return false;
    // tsc's `isOuterVariable`: a reference whose control-flow container is not
    // the declaration's is assumed initialized — the enclosing function's flow
    // says nothing about when the closure runs. TS 5.0 carved one hole in
    // that (`isNeverInitialized`): if the variable is a mutable local `let`
    // with no initializer that is never DEFINITELY assigned anywhere in the
    // file, then no execution order can have written it, so the capture is
    // reported after all. A compound write inside the closure (`i++`,
    // `flags |= f`) does not rescue it; a plain `x = v` does, wherever it sits.
    //
    // The initializer test is tsc's `!declaration.initializer &&
    // !declaration.exclamationToken`, and it is asked HERE rather than at the
    // early return above because a use *before* the declaration still has to
    // reach the flow walk (TS2448 + TS2454 together) when it is in the same
    // container. `export function f(g = () => foo) { let foo = "in"; }` is the
    // shape that needs the difference.
    if (flowContainerOf(c, c.cur_scope) != flowContainerOf(c, c.symScope(sym))) {
        if (has_init or has_definite) return false;
        if (!try neverInitializedLocal(c, sym)) return false;
    }
    const flow = c.bind.flowAt(node) orelse return false;
    if (try c.definitelyAssigned(flow, sym)) return false;
    // The assignment walk alone is not tsc's answer. tsc runs the ordinary
    // narrowing walk over `declared | undefined` (`getOptionalType` is the
    // initial type whenever `assumeInitialized` is false) and reports only
    // when undefined SURVIVES it — `getFalsyFlags(flowType) & Undefined`.
    // So a guard that rules undefined out silences the diagnostic even
    // though nothing was ever assigned: `isC1(x) && x.p`, `if (x) …`,
    // `typeof x === "string" && …`. The narrowing walk answers that
    // directly, and it is asked only once the cheap walk has decided to
    // report — every clean reference still costs one boolean walk.
    const optional = try c.makeUnion2(declared, types.undefined_type);
    const narrowed = try unassignedVarType(c, node, sym, optional);
    return c.containsUndefinedish(narrowed);
}

/// tsc's `isMutableLocalVariableDeclaration && !isSymbolAssignedDefinitely`:
/// is `sym` a `let` local that NOTHING in its file ever plainly assigns?
///
/// `let` only — tsc's predicate reads `NodeFlags.Let`, so a `var` captured by
/// a closure is never reported however it is written (the `x10` of
/// `unusedLocalsInMethod4`). An EXPORTED variable, and a top-level variable of
/// a SCRIPT (whose top level is the global scope), are out for the same reason
/// the closure-crossing narrowing gate leaves them out: another file may
/// assign them.
fn neverInitializedLocal(c: *Checker, sym: SymbolId) Error!bool {
    const sf = c.symFlags(sym);
    if (!sf.let_decl or sf.const_decl or sf.param or sf.catch_param) return false;
    if (sf.exported) return false;
    if (c.bind.scope_kinds[containerOf(c, c.symScope(sym))] == .file and !c.bind.is_module) return false;
    try c.ensureReassignScan();
    return !c.definitely_assigned_syms.contains(sym);
}

/// ``tag`a${x}b` `` — a CALL of `tag` with the template's cooked-strings
/// array followed by each substitution (tsc's
/// `resolveTaggedTemplateExpression`). Before this the whole expression was
/// simply `any`, which erased every library that returns a typed builder from
/// a tag: kysely's ``sql<Row>`…` `` came back `any`, so the `rows` of its
/// result were `any[]` and every callback over them reported TS7006.
///
/// A tag with no call signature stays `any` and reports nothing; otherwise the
/// whole call goes through `resolveSignatureCall`, the ordinary call's
/// pipeline — overload selection, type-argument inference, arity,
/// per-argument assignability. tsc runs the two through the same
/// `resolveCall`, and the parts that only the shared pipeline has are exactly
/// what a hand-rolled "first signature whose arity fits" got wrong:
/// ``foo2`${1}` `` against `foo2(strs: string[], …)` / `foo2(strs:
/// TemplateStringsArray, …)` must pick the SECOND overload, because a
/// `TemplateStringsArray` is not a `string[]`.
///
/// The synthesized strings-array argument is the TEMPLATE NODE itself, whose
/// type is the global `TemplateStringsArray` for exactly as long as it is a
/// tag's template — see the `.template_expr` / `.template_literal` arms of
/// `checkExpr`, which also stop walking the substitutions there, since the
/// substitutions are arguments of this call and the argument walk is what
/// contextually types them.
fn checkTaggedTemplate(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const tag_ty = try c.checkExprCached(d.lhs, types.no_type);
    // tsc's constant folding of a template expression is explicitly skipped
    // when its parent is a tagged template (`node.parent.kind !==
    // SyntaxKind.TaggedTemplateExpression`); ztsc has no parent links, so the
    // tagged template marks its own template node for the duration.
    const prev_tagged = c.tagged_tpl;
    c.tagged_tpl = d.rhs;
    defer c.tagged_tpl = prev_tagged;
    // Argument nodes: the template stands in for the strings array, then one
    // per substitution.
    var args: std.ArrayList(Node) = .empty;
    defer args.deinit(c.scratch());
    try args.append(c.scratch(), d.rhs);
    if (c.nodeTag(d.rhs) == .template_expr) {
        for (c.tree.nodeRange(d.rhs)) |sub| {
            if (sub != null_node) try args.append(c.scratch(), sub);
        }
    }
    // The tag's APPARENT type carries the signatures: a tag whose type is a
    // type parameter is called through its base constraint, exactly as an
    // ordinary call's callee is (`checkCallExprInner`'s `.type_param` arm).
    var r = try c.resolveStructural(tag_ty);
    if (c.ts.kind(r) == .type_param) {
        const bc = try c.transitiveBaseConstraint(r);
        if (bc != r) r = try c.resolveStructural(bc);
    }
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    switch (c.ts.kind(r)) {
        .function => try sigs.append(c.scratch(), r),
        .overloads => for (try c.memberList(r)) |m| try sigs.append(c.scratch(), m),
        .object => for (0..c.ts.objectCallSigCount(r)) |i| {
            try sigs.append(c.scratch(), c.ts.objectCallSig(r, @intCast(i)));
        },
        else => {},
    }
    if (sigs.items.len == 0) {
        // Nothing to draw a contextual type from, but the substitutions are
        // still expressions and still have to be checked.
        for (args.items[1..]) |sub| _ = try c.checkExprCached(sub, types.no_type);
        if (try tagNotCallable(c, tag_ty, r)) {
            // ```ts
            // if (isArrayLiteralExpression(node.parent)) {
            //     const diagnostic = createDiagnosticForNode(node.tag,
            //         Diagnostics.It_is_likely_that_you_are_missing_a_comma_to_separate_these_two_template_literals_…);
            // ```
            //
            // Two template literals written on consecutive lines of an array
            // literal parse as ONE tagged template, and "you are missing a
            // comma" is the diagnosis that helps; "not callable" is a true
            // statement about a program nobody wrote on purpose.
            if (node == c.array_elem) {
                try c.diagFmt(2796, c.nodeSpan(d.lhs), "It is likely that you are missing a comma to separate these two template literals. They form a tagged template expression which cannot be invoked.", .{});
            } else {
                try c.diagFmt(2349, c.nodeSpan(d.lhs), "This expression is not callable.", .{});
            }
            return types.error_type;
        }
        return types.any_type;
    }
    return calls_zig.resolveSignatureCall(c, node, sigs.items, &.{}, args.items, types.no_type, ctx);
}

/// Is a tag with NO call signature one tsc rejects outright (TS2349), or one
/// it lets through as `any`?
///
/// tsc runs the same `resolveCall` for a tagged template as for a call, so the
/// answer is `resolveUntypedCall`'s: `any`/`error`, and anything assignable to
/// the global `Function` (`isUntypedFunctionCall`'s last disjunct — an
/// interface body with no call signature of its own), are silent; everything
/// else is "This expression is not callable".
///
/// Stated as a CLOSED SET of kinds rather than as its complement, because a
/// kind this file has not thought about is one whose signatures may simply not
/// have been gathered — and answering "not callable" there manufactures a
/// false positive on working code. The set is the shapes whose members are
/// fully materialized by `resolveStructural`: a class value (construct
/// signatures only — ``CtorTag`x` `` is tsc's TS2349), an object/interface with
/// no call signature, and every primitive and literal.
fn tagNotCallable(c: *Checker, tag_ty: TypeId, r: TypeId) Error!bool {
    switch (c.ts.kind(r)) {
        .class_value,
        .object,
        .ref,
        .string,
        .string_literal,
        .template_literal_type,
        .string_mapping,
        .number,
        .number_literal,
        .number_literal_fresh,
        .bigint,
        .bigint_literal,
        .boolean,
        .bool_true,
        .bool_false,
        .symbol,
        .unique_symbol,
        .enum_type,
        .array,
        .tuple,
        => {},
        else => return false,
    }
    // `isUntypedFunctionCall` opens its last disjunct with
    // `!numCallSignatures && !numConstructSignatures`: a value that CAN be
    // constructed but not called is rejected however assignable to `Function`
    // it is — every class value is (`taggedTemplateWithConstructableTag01`,
    // and the construct-signature-only interface of `…02`).
    if (c.ts.kind(r) == .class_value) return true;
    if (c.ts.kind(r) == .object and c.ts.objectConstructSigCount(r) != 0) return true;
    // `isUntypedFunctionCall`'s `isTypeAssignableTo(funcType, globalFunctionType)`.
    const sym = c.prog.globals.lookup(c.atom_Function) orelse return true;
    if (!c.symFlags(sym).interface) return true;
    return !try c.isAssignable(tag_ty, try c.ts.makeRef(sym, &.{}));
}

/// A lib-declared global INTERFACE, by name and with no type arguments — the
/// `globalXType` family tsc materializes once per program. `any` when the lib
/// declares no such interface (`--noLib`), which keeps whatever asked for it
/// silent rather than rejecting every use in the program.
fn globalInterfaceType(c: *Checker, comptime name: []const u8) Error!TypeId {
    const sym = c.prog.globals.lookup(try c.atom(name)) orelse return types.any_type;
    if (!c.symFlags(sym).interface) return types.any_type;
    return c.ts.makeRef(sym, &.{});
}

/// The global `TemplateStringsArray` — the type tsc gives the synthesized
/// first argument of every tagged-template call.
fn templateStringsArrayType(c: *Checker) Error!TypeId {
    return globalInterfaceType(c, "TemplateStringsArray");
}

fn checkArrayLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    // `[...] as const`: a readonly tuple of the (non-widened) element
    // types. Nested literals recurse because const_ctx stays set.
    //
    // tsc's `checkArrayLiteral` builds the tuple `readonly` only when the
    // contextual type is not mutable-array-like, so a const context under a
    // MUTABLE array target keeps a mutable tuple: `f<const T extends
    // unknown[]>([1, 2])` is `[1, 2]`, while an unconstrained `const T` and a
    // `readonly unknown[]` constraint both give `readonly [1, 2]`. ztsc's
    // readonly flag is invisible to the relation, so the difference is only
    // observable on an element WRITE — which is exactly where getting it
    // wrong would be a false TS2540.
    if (c.const_ctx) return checkConstArrayLiteral(c, node, !try ctxIsMutableArrayLike(c, ctx));
    const rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
    // Tuple context: a direct tuple contextual type, or an inference target
    // `T` whose constraint is tuple-like. `Promise.all([a, b])` infers into
    // `all<T extends readonly unknown[] | []>` — the `[]` member of the
    // constraint puts the array literal in tuple context (matching tsc), so
    // it becomes `[typeof a, typeof b]` and the tuple overload wins.
    var ctx_tuple_ty: TypeId = if (rctx != types.no_type and c.ts.kind(rctx) == .tuple) rctx else types.no_type;
    if (ctx_tuple_ty == types.no_type and rctx != types.no_type and c.ts.kind(rctx) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rctx));
        if (con != types.no_type) {
            const rcon = try c.resolveStructural(con);
            if (c.ts.kind(rcon) == .tuple) {
                ctx_tuple_ty = rcon;
            } else if (c.ts.kind(rcon) == .union_type) {
                for (try c.memberList(rcon)) |m| {
                    if (c.ts.kind(try c.resolveStructural(m)) == .tuple) {
                        ctx_tuple_ty = try c.resolveStructural(m);
                        break;
                    }
                }
            }
        }
    }
    // Union contextual type (`T[] | [A, B] | T`, or the react-hook-form
    // `Path<F> | Path<F>[]` shape): a tuple constituent puts the literal in
    // tuple context (matching tsc's `someType(ctx, isTupleLikeType)`).
    if (ctx_tuple_ty == types.no_type and rctx != types.no_type and c.ts.kind(rctx) == .union_type) {
        for (try c.memberList(rctx)) |m| {
            if (c.ts.kind(try c.resolveStructural(m)) == .tuple) {
                ctx_tuple_ty = try c.resolveStructural(m);
                break;
            }
        }
    }
    // tsc's `isTupleLikeType` has a third disjunct beyond "is a tuple" and
    // "has a property named `0`": an ARRAY-LIKE whose `length` type is
    // entirely number LITERALS is tuple-like. An INTERSECTION is where that
    // shape hides — `type fixed1 = [...number[]] & { length: 2 }` (the #29311
    // repro in `contextualTypeWithTuple`) is array-like from the tuple half
    // and pins `length` to `2` from the object half, so tsc contextually types
    // `[0, 0]` as `[number, number]`. ztsc read no tuple context, built
    // `number[]`, and `number[]`'s `length` is `number` — a false TS2322. The
    // pin also makes arity real: `[0, 0, 0]` is TS2322 `'3'` vs `'2'`
    // (tsgo-verified), which the array reading could never report.
    if (ctx_tuple_ty == types.no_type and rctx != types.no_type and
        c.ts.kind(rctx) == .intersection and try tupleLikeByLength(c, rctx))
    {
        ctx_tuple_ty = rctx;
    }
    const ctx_tuple = ctx_tuple_ty != types.no_type;
    // Contextual element type for a plain (non-tuple) array literal. A
    // direct array context yields its element; a union context contributes
    // the element type of each array-like constituent (so array-literal
    // elements are contextually typed — literals stay literal instead of
    // widening).
    var ctx_elem: TypeId = if (!ctx_tuple) try contextualArrayElemOrIterated(c, rctx) else types.no_type;
    // tsc's `getContextualTypeForElementExpression` ends in
    // `getIteratedTypeOrElementType(IterationUse.Element, t, …)`, so an
    // ITERABLE contextual type types the elements even when it is not
    // array-like. `function* g(): IterableIterator<(x: string) => number> {
    // yield *[x => x.length]; }` needs it — the delegation's contextual type
    // is the generator's return type, whose resolved object carries no numeric
    // index, so the arrow's parameter was an implicit any
    // (`generatorTypeCheck26`).
    //
    // Asked of the CONTEXTUAL TYPE AS WRITTEN and only of the lib
    // iterator-family references `generatorYieldType` names. The general
    // `iterationElementType` on the resolved type answers for `Map`, `Set` and
    // anything with an apparent `[Symbol.iterator]`, and offering that
    // alongside an array alternative widens real code: `readonly T[] |
    // Map<string, T>` contributed `T | [string, T]` to excalidraw's
    // `arrayToMap(xs || [])`, and `("images" | …)[] | MediaTypeOptions`
    // contributed the enum's apparent `string` to social-app's `mediaTypes:
    // ['images']`.
    if (ctx_elem == types.no_type and !ctx_tuple and ctx != types.no_type) {
        const y = c.generatorYieldType(ctx);
        if (y != 0) ctx_elem = y;
    }

    var elem_types: std.ArrayList(TypeId) = .empty;
    defer elem_types.deinit(c.scratch());
    // The same element types BEFORE literal widening, positionally aligned
    // with `elem_types`. Subtype reduction has to read object-literal
    // FRESHNESS, and `widenLiteral` regularizes it away (see the reduction
    // below).
    var raw_types: std.ArrayList(TypeId) = .empty;
    defer raw_types.deinit(c.scratch());
    var tuple_elems: std.ArrayList(types.TupleElem) = .empty;
    defer tuple_elems.deinit(c.scratch());
    // How many positions the literal occupies — the length a tuple context
    // with trailing fixed elements needs to place each one (see
    // `contextualElemTypeAt`). A SPREAD stands for an unknown number of them,
    // so from one on no position is knowable and there is no length to give;
    // tsc gives up the same way (`getContextualTypeForElementExpression`
    // threads the spread indices through and answers `undefined` past them).
    const lit_len: ?u32 = blk: {
        var n: u32 = 0;
        for (c.tree.nodeRange(node)) |el| {
            if (el == null_node) continue;
            if (c.nodeTag(el) == .spread_element) break :blk null;
            n += 1;
        }
        break :blk n;
    };
    var i: u32 = 0;
    for (c.tree.nodeRange(node)) |el| {
        if (el == null_node) continue;
        if (c.nodeTag(el) == .omitted) {
            try elem_types.append(c.scratch(), types.undefined_type);
            try raw_types.append(c.scratch(), types.undefined_type);
            try tuple_elems.append(c.scratch(), .{ .ty = types.undefined_type });
            i += 1;
            continue;
        }
        if (c.nodeTag(el) == .spread_element) {
            const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(el).lhs, types.no_type));
            switch (c.ts.kind(st)) {
                .array => {
                    try elem_types.append(c.scratch(), c.ts.arrayElem(st));
                    try raw_types.append(c.scratch(), c.ts.arrayElem(st));
                    try tuple_elems.append(c.scratch(), .{ .ty = st, .flags = types.elem_flag_rest });
                },
                .tuple => {
                    for (0..c.ts.tupleLen(st)) |j| {
                        const e = c.ts.tupleElem(st, @intCast(j));
                        try elem_types.append(c.scratch(), e.ty);
                        try raw_types.append(c.scratch(), e.ty);
                        try tuple_elems.append(c.scratch(), e);
                    }
                },
                else => {
                    // Spread of a non-array iterable (`[...set]`, `[...map]`):
                    // its element type via the `[Symbol.iterator]` protocol.
                    // A spread operand that carries NO such protocol is tsc's
                    // TS2488, reported at the operand (its
                    // `checkIteratedTypeOrElementType` under
                    // `IterationUse.Spread`) — swallowing the failure into
                    // `any` under-reported `[...new SymbolIterator]` for a
                    // class with only `next()` (`iteratorSpreadInArray8`) and
                    // for one whose `[Symbol.iterator]()` returns a `this`
                    // with no `next` (`iteratorSpreadInArray10`).
                    const elem = (try c.iterationElementType(st)) orelse blk: {
                        if (c.ts.kind(st) != .none) {
                            const operand = c.tree.nodeData(el).lhs;
                            try c.diagFmt(2488, c.nodeSpan(operand), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{
                                try c.typeToString(st),
                            });
                        }
                        break :blk types.any_type;
                    };
                    try elem_types.append(c.scratch(), elem);
                    try raw_types.append(c.scratch(), elem);
                    try tuple_elems.append(c.scratch(), .{ .ty = try c.ts.makeArray(elem), .flags = types.elem_flag_rest });
                },
            }
            i += 1;
            continue;
        }
        var ectx: TypeId = ctx_elem;
        var ectx_src: TypeId = types.no_type;
        if (ctx_tuple) {
            // A UNION contextual type contributes what EVERY constituent
            // holds at this index, not just the one tuple that put the
            // literal in tuple context — tsc's
            // `getContextualTypeForElementExpression` is
            // `getTypeOfPropertyOfContextualType(t, "" + index)`, and that
            // maps over the union. sharp's `affine([[a, b], [c, d]])` against
            // `[number, number, number, number] | [[number, number],
            // [number, number]]` is the case: reading only the first tuple
            // gives the inner literal a contextual `number`, so it widens to
            // `number[]` and matches neither branch.
            ectx_src = if (c.ts.kind(rctx) == .union_type) rctx else ctx_tuple_ty;
            ectx = try contextualElemTypeAt(c, ectx_src, i, lit_len);
        }
        // An element of an array literal is the one place a NON-CALLABLE tag
        // gets a different diagnostic (`checkTaggedTemplate`'s TS2796); ztsc
        // has no parent links, so the element marks itself for the duration,
        // exactly as a tagged template marks its own template node.
        const prev_elem = c.array_elem;
        c.array_elem = el;
        const raw = try c.checkExprCached(el, ectx);
        c.array_elem = prev_elem;
        var et = raw;
        // In TUPLE context the question goes to the un-reduced union — see
        // `elemCtxKeepsLiteral`. `ectx` itself is the reduced one, and stays
        // the type the element expression was checked against.
        const keeps = if (ctx_tuple)
            try elemCtxKeepsLiteral(c, ectx_src, i, lit_len, et)
        else
            try keepLiteral(c, et, ectx);
        if (!keeps) et = try c.widenLiteral(et);
        // tsc's `checkExpressionForMutableLocation` ends
        // `getWidenedLiteralLikeTypeForContextualType` with
        // `getRegularTypeOfLiteralType` on BOTH arms: an element whose literal
        // the contextual type KEEPS still loses its FRESHNESS. Freshness is a
        // property of an expression, not of a type an expression lands in, and
        // an element type is the latter — nothing about `['a', 'b']` should
        // still say "this `'a'` came from a literal and may widen".
        //
        // It escapes through inference. zod's
        // `z.enum<U extends string, T extends Readonly<[U, ...U[]]>>(values: T)`
        // infers `T` as the tuple, so a fresh element became a fresh member of
        // `ZodEnum<T>['_output'] = T[number]` — and social-app's
        // `useState(() => persisted.get('colorMode'))` then widened that union
        // to `string`, because `getCovariantInference`'s widening arm fires on
        // an unconstrained `S` and only fresh literals widen. The `U` half of
        // the same signature was already regular (`primitiveConstraint`'s arm
        // in `inferTypeArgs` does exactly this call); the tuple half was not.
        et = try c.ts.regularLiteral(et);
        try elem_types.append(c.scratch(), et);
        try raw_types.append(c.scratch(), raw);
        try tuple_elems.append(c.scratch(), .{ .ty = et });
        i += 1;
    }
    if (ctx_tuple) return c.ts.makeTuple(tuple_elems.items);
    if (elem_types.items.len == 0) {
        if (ctx_elem != types.no_type) {
            // Empty array literal under a union context with MULTIPLE
            // array-like branches of differing element types
            // (leaflet `polyline([], …)`: `LatLngExpression[] |
            // LatLngExpression[][]`): folding their elements into a union
            // element (`(E | E[])[]`) is assignable to NEITHER branch — a
            // false TS2345. An empty literal has no elements to
            // disambiguate, and `never[]` is assignable to every
            // array/tuple branch (tsc's empty-array typing). A single
            // array branch keeps its element type (display/inference).
            if (rctx != types.no_type and c.ts.kind(rctx) == .union_type and
                try multiArrayLikeBranches(c, rctx))
                return c.ts.makeArray(types.never_type);
            // The contextual element is a FREE inference variable of a call
            // in flight (`mk<T>(xs: T[])` called as `mk([])`): echoing it
            // back makes the argument its own evidence, so `T` infers `T` and
            // leaks a naked type parameter into the result (immich's
            // `asSet(v, [])` produced `Set<T>`, then `T | ImmichWorker`).
            // tsc never reads the contextual element type for an EMPTY
            // literal at all — `checkArrayLiteral` hands back
            // `implicitNeverType` regardless — and `never` is the right
            // evidence: it is what an array holding nothing contributes, and
            // it is assignable to every array target.
            if (try c.mentionsActiveInferVar(ctx_elem)) return c.ts.makeArray(types.never_type);
            return c.ts.makeArray(ctx_elem);
        }
        return c.ts.makeArray(types.any_type); // evolving arrays out of scope
    }
    return c.ts.makeArray(try arrayLiteralElemType(c, raw_types.items, elem_types.items, rctx == types.no_type));
}

/// tsc's `createArrayLiteralType`: an array literal's element type is
/// `getUnionType(elementTypes, UnionReduction.Subtype)` — the best common
/// supertype, not the plain union. Without the reduction an array holding two
/// instantiations of the same generic, one narrower than the other, keeps
/// both spellings, and a later generic call over the array can satisfy
/// neither: `[seg(r[0], ptFrom(…)), seg(ptFrom(…), r[1])]` infers
/// `Seg<Point>` for one element and `Seg<G | L>` for the other (tsc does
/// too — `ptFrom`'s return-only type parameter genuinely falls back to its
/// constraint), and tsc reduces the pair to `Seg<G | L>[]`.
///
/// `reduceSubtypes` carries the `strictSubtypeRelation` guards this needs —
/// a FRESH object literal never absorbs a sibling and is only absorbed when
/// it survives an excess-property check — but it can only apply them while
/// the literals are still fresh, and `widenLiteral` regularizes freshness
/// away per element. So reduce the RAW (pre-widening) types and use the
/// result only as a removal set: an element's widened type is dropped
/// exactly when the reduction removed its raw type. Reading it as a removal
/// set rather than as the answer also keeps a union-typed element safe — it
/// is flattened by `makeUnion` and so is never itself a member, hence never
/// "removed".
///
/// This is what keeps `[{ a: 1 }, { a: 1, b: 2 }]` a two-member union (both
/// fresh, neither absorbs) while `[a, ab]` of two DECLARED types reduces to
/// `A`, matching tsc on both.
fn arrayLiteralElemType(c: *Checker, raw: []const TypeId, widened0: []const TypeId, no_ctx: bool) Error!TypeId {
    std.debug.assert(raw.len == widened0.len);
    const widened = try siblingNormalized(c, raw, widened0, no_ctx);
    const plain = try c.ts.makeUnion(c.scratch(), widened);
    if (raw.len < 2) return plain;
    const raw_union = try c.ts.makeUnion(c.scratch(), raw);
    if (c.ts.kind(raw_union) != .union_type) return plain;
    const reduced = try c.reduceSubtypes(raw_union);
    if (reduced == raw_union) return plain;
    // Members of `raw_union` the reduction dropped.
    const survivors: []const TypeId = if (c.ts.kind(reduced) == .union_type)
        try c.memberList(reduced)
    else
        &.{reduced};
    var kept: std.ArrayList(TypeId) = .empty;
    defer kept.deinit(c.scratch());
    outer: for (raw, widened) |r, w| {
        for (try c.memberList(raw_union)) |m| {
            if (m != r) continue;
            // `r` IS a member of the raw union: keep it only if it survived.
            for (survivors) |sv| {
                if (sv == r) break;
            } else continue :outer;
            break;
        }
        try kept.append(c.scratch(), w);
    }
    if (kept.items.len == 0) return plain;
    return c.ts.makeUnion(c.scratch(), kept.items);
}

/// An array literal's elements share ONE widening context in tsc, so each
/// object-literal element gains its object-literal SIBLINGS' missing property
/// names as `name?: undefined` (`getWidenedTypeWithContext` →
/// `getPropertiesOfContext` + `getUndefinedProperty`): `[{ a: 1 }, { b: 2 }]`
/// is `({ a: number; b?: undefined } | { a?: undefined; b: number })[]`. Same
/// rule, same helper (`names.undefinedSiblingMembers`), as the arms of a `?:`
/// and the `return`s of one function.
///
/// Participation is read off the RAW element types: `widenLiteral` has already
/// dropped the object-literal ORIGIN flag from the widened ones, and it is the
/// raw element that says whether an `{ … }` was written there.
///
/// Only for a literal with NO contextual type. With one, tsc widens against
/// the CONTEXT's properties (`getWidenedTypeWithContext` walks the contextual
/// type, not the siblings); folding sibling names in as well makes a
/// self-referential context diverge — conformance `indexed/008_recursive_json.ts`
/// is the tripwire.
fn siblingNormalized(c: *Checker, raw: []const TypeId, widened: []const TypeId, no_ctx: bool) Error![]const TypeId {
    if (!no_ctx or widened.len < 2) return widened;
    const take = try c.scratch().alloc(bool, widened.len);
    defer c.scratch().free(take);
    for (raw, widened, take) |r, w, *t| {
        t.* = c.ts.objectIsLiteralOrigin(r) and c.ts.kind(w) == .object;
    }
    return (try names_zig.undefinedSiblingMembers(c, widened, take)) orelse widened;
}

/// The element type an array literal's elements should be contextually
/// typed against, given a (structurally resolved) contextual type. A direct
/// array yields its element type; a union contributes the element type of
/// every array-like constituent (mirrors tsc's per-element
/// `getContextualTypeForElementExpression` mapping over the union). Returns
/// `no_type` when nothing array-like is present.
fn contextualArrayElemType(c: *Checker, rctx: TypeId) Error!TypeId {
    if (rctx == types.no_type) return types.no_type;
    switch (c.ts.kind(rctx)) {
        .array => return c.ts.arrayElem(rctx),
        .union_type => {
            var elems: std.ArrayList(TypeId) = .empty;
            defer elems.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const e = try contextualArrayElemType(c, try c.resolveStructural(m));
                if (e != types.no_type) try elems.append(c.scratch(), e);
            }
            if (elems.items.len == 0) return types.no_type;
            return c.ts.makeUnion(c.scratch(), elems.items);
        },
        // tsc's `getApparentTypeOfContextualType`: a contextual type that is
        // still a type VARIABLE — the inference target of a call in flight —
        // contributes through its base CONSTRAINT, which is where the element
        // shape lives. The TUPLE branch of `checkArrayLiteral` already looks
        // through the constraint; the plain-array branch did not, so an array
        // literal passed to `f<T extends readonly Name[]>(xs: T)` was checked
        // with NO contextual element type at all and every element widened.
        //
        // kysely's `selectFrom<TE extends TableExpressionOrList<DB, TB>>(from:
        // TE)` is that shape: `db.selectFrom(['person'])` widened `'person'`
        // to `string`, so `TE` inferred `string[]`, `From<DB, string>`
        // collapsed the whole schema to `{ [x: string]: <one table> }` and the
        // builder came back as a 60-constituent union — immich's
        // `person.getByName` row type was `{}`. Writing `['person'] as const`
        // or the type argument by hand was already correct, which is the tell.
        //
        // One level only: the constraint's own type variables are not
        // re-followed, mirroring `getBaseConstraintOfType`'s fixed point being
        // reached at the first non-instantiable form here.
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rctx));
            if (con == types.no_type) return types.no_type;
            const rcon = try c.resolveStructural(con);
            if (c.ts.kind(rcon) == .type_param) return types.no_type;
            return contextualArrayElemType(c, rcon);
        },
        // An INTERFACE that extends `Array<T>` is array-like without being an
        // `.array`: it resolves to an object carrying Array's numeric index
        // signature. tsc reaches it through
        // `getIndexTypeOfContextualType(t, numberType)` (and, failing that,
        // `getIteratedTypeOrElementType`), so the elements of a literal in
        // that position ARE contextually typed; ztsc's kind-keyed arms fell
        // through to `no_type` and every element widened.
        //
        // React Native's `StyleProp<T>` is the shape that found it —
        // `interface RecursiveArray<T> extends Array<T | ReadonlyArray<T> |
        // RecursiveArray<T>> {}` — so `<Text style={[a.mt_sm, {fontWeight:
        // '600'}]}>` widened `'600'` to `string` and the whole style array
        // stopped being a `TextStyle`. The plain `Array<TextStyle>` spelling
        // of the same target was always fine, which is the tell.
        //
        // Only a NUMBER index signature counts. A string-index-only object
        // (`Record<string, X>`) is not an array-like position, and reading its
        // index here would contextually type array elements against a type
        // tsc never offers.
        .object => {
            const idx = c.ts.objectNumberIndex(rctx);
            return if (idx != 0) idx else types.no_type;
        },
        else => return types.no_type,
    }
}

/// `contextualArrayElemType` with tsc's LAST RESORT behind it:
///
/// ```ts
/// getTypeOfPropertyOfContextualType(arrayContextualType, "" + index) ||
///     mapType(arrayContextualType, t => getIteratedTypeOrElementType(IterationUse.Element, t, …))
/// ```
///
/// An `Iterable<T>` carries no numeric index at all — only
/// `[Symbol.iterator]()` — so `var xs: Iterable<(x: string) => number> = [s =>
/// s.length]` left its element with no contextual type and reported TS7006
/// inside it (`iterableContextualTyping1`).
///
/// The `||` is where the ORDER matters, and it is why this is not an arm of
/// `contextualArrayElemType`'s `.object` case: the two alternatives are tried
/// over the WHOLE contextual type, not per union constituent. `readonly T[] |
/// Map<K, V>` answers `T` from the first alternative and never reaches the
/// second — folding the `Map`'s `[K, V]` into the element context instead made
/// excalidraw's `[...boundElements, [id, el]]` shapes `(T | [K, V])[]`, three
/// false TS2345s.
fn contextualArrayElemOrIterated(c: *Checker, rctx: TypeId) Error!TypeId {
    if (rctx == types.no_type) return types.no_type;
    const direct = try contextualArrayElemType(c, rctx);
    if (direct != types.no_type) return direct;
    // `contextualIterationElementType`, not `iterationElementType`: tsc's
    // `mapType` here drops a non-iterable constituent instead of failing the
    // whole union, so an array literal under `Iterable<T> | null | undefined`
    // — every optional `iterable?: Iterable<T> | null` lib parameter — still
    // types its elements by `T`. Only reachable when the DIRECT read above
    // found nothing, so `readonly T[] | Map<K, V>` still answers `T` and
    // never folds in the map's `[K, V]`.
    return (try c.contextualIterationElementType(rctx)) orelse types.no_type;
}

/// The contextual type for the element at index `i` of an array literal in
/// TUPLE context, given a (structurally resolved) contextual type — tsc's
/// `getTypeOfPropertyOfContextualType(ctx, "" + i)`, which `mapType`s over a
/// union. A tuple constituent contributes the type at that position (its
/// rest element past the fixed part), an array constituent its element type,
/// and anything else nothing. Returns `no_type` when no constituent holds an
/// element there.
///
/// `length` is how many elements the literal has, or `null` when a spread
/// makes that unknowable. A tuple whose FIXED elements sit after a variable
/// one (`[...((a: number) => void)[], (a: string) => void]`) decides a
/// position by counting back from the END, which is a question only the
/// length can answer — `tuple_relate.contextualElemType`, the same reading
/// the CALL-argument path already uses for a non-array rest parameter. Read
/// from the start instead, `const a1: Funcs = [x => str(x)]` typed its lone
/// element by the leading `(a: number) => void` and reported inside its body.
/// Every other tuple shape keeps the positional read.
fn contextualElemTypeAt(c: *Checker, rctx: TypeId, i: u32, length: ?u32) Error!TypeId {
    switch (c.ts.kind(rctx)) {
        .tuple => {
            if (length) |n| {
                if (tuple_relate.fixedLength(c, rctx) < c.ts.tupleLen(rctx) and
                    tuple_relate.endFixedCount(c, rctx) > 0)
                {
                    return (try tuple_relate.contextualElemType(c, rctx, i, n)) orelse types.no_type;
                }
            }
            return try c.tupleElemTypeAt(rctx, i) orelse types.no_type;
        },
        .array => return c.ts.arrayElem(rctx),
        .union_type => {
            var elems: std.ArrayList(TypeId) = .empty;
            defer elems.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const e = try contextualElemTypeAt(c, try c.resolveStructural(m), i, length);
                if (e != types.no_type) try elems.append(c.scratch(), e);
            }
            if (elems.items.len == 0) return types.no_type;
            return c.ts.makeUnion(c.scratch(), elems.items);
        },
        // An `extends Array<T>` interface has no per-POSITION type, but its
        // numeric index signature types every position — the same arm
        // `contextualArrayElemType` grows above, for the tuple-context route.
        .object => {
            const idx = c.ts.objectNumberIndex(rctx);
            return if (idx != 0) idx else types.no_type;
        },
        // tsc reads the position off the WHOLE type
        // (`getTypeOfPropertyOfContextualType(t, "" + i)`), so an intersection
        // answers from whichever constituent declares it — the `[...number[]]`
        // half of `[...number[]] & { length: 2 }`, never the `{ length: 2 }`
        // half. Constituents that agree contribute an intersection, which is
        // what a property of an intersection type is; the NO-REDUCE spelling
        // because this is a contextual read, not a declared type.
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const e = try contextualElemTypeAt(c, try c.resolveStructural(m), i, length);
                if (e != types.no_type) try parts.append(c.scratch(), e);
            }
            if (parts.items.len == 0) return types.no_type;
            if (parts.items.len == 1) return parts.items[0];
            return c.ts.makeIntersectionNoReduce(c.scratch(), parts.items);
        },
        else => return types.no_type,
    }
}

/// tsc's `isTupleLikeType` third disjunct: `isArrayLikeType(type) &&
/// getTypeOfPropertyOfType(type, "length")` exists and is entirely number
/// LITERALS. Asked only of an INTERSECTION — the one form that can be
/// array-like without being a `.tuple` while still pinning `length` to a
/// literal. A bare `T[]` is array-like too, but its `length` is `number`, so
/// the disjunct could never fire for it; restricting the question keeps the
/// property lookup off the ordinary array-literal path entirely.
fn tupleLikeByLength(c: *Checker, r: TypeId) Error!bool {
    var array_like = false;
    for (try c.memberList(r)) |m| {
        switch (c.ts.kind(try c.resolveStructural(m))) {
            .array, .tuple => array_like = true,
            else => {},
        }
    }
    if (!array_like) return false;
    const len = (try c.propOfType(r, c.atom_length)) orelse return false;
    return allNumberLiterals(c, try c.resolveStructural(len.ty));
}

/// tsc's `everyType(lengthType, t => !!(t.flags & TypeFlags.NumberLiteral))`.
fn allNumberLiterals(c: *Checker, t: TypeId) Error!bool {
    if (c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (!try allNumberLiterals(c, try c.resolveStructural(m))) return false;
        }
        return true;
    }
    return switch (c.ts.kind(t)) {
        .number_literal, .number_literal_fresh => true,
        else => false,
    };
}

/// `keepLiteral` for an element position whose contextual type comes from
/// `contextualElemTypeAt`, asked of the UN-REDUCED union tsc would have built.
///
/// tsc reads a contextual element type through
/// `getTypeOfPropertyOfContextualType`, whose `mapType(…, /*noReductions*/
/// true)` ends in `getUnionType(mapped, UnionReduction.None)`. The
/// `AnyOrUnknown` early return that collapses `"a" | any` to `any` sits INSIDE
/// `if (unionReduction !== UnionReduction.None)`, so the union tsc hands the
/// element still HAS its literal constituents — and
/// `isLiteralOfContextualType` recurses through a union (`some(types, …)`) and
/// finds them.
///
/// `unionTypeWithIndexAndTuple` is the shape: `f(args: ["a"] | I)` where `I`
/// has `[index: number]: any`. Position 0 contributes `"a"` from the tuple and
/// `any` from the interface's numeric index; reduced, the element is typed by
/// `any`, `"a"` widens to `string`, the literal becomes `string[]` and matches
/// neither branch (a false TS2345).
///
/// ztsc's `makeUnion` always reduces and `internType` is private to the store,
/// so there is no unreduced union to hand back as `ectx`. But the only thing
/// the reduction destroys is this predicate's answer, and the predicate over a
/// union is a `some` — so ask it per CONSTITUENT, which is exactly what the
/// unreduced union would have answered. The contextual type flowing into the
/// element expression stays the reduced one, as it already was.
fn elemCtxKeepsLiteral(c: *Checker, rctx: TypeId, i: u32, length: ?u32, cand: TypeId) Error!bool {
    if (c.ts.kind(rctx) == .union_type) {
        for (try c.memberList(rctx)) |m| {
            if (try elemCtxKeepsLiteral(c, try c.resolveStructural(m), i, length, cand)) return true;
        }
        return false;
    }
    return keepLiteral(c, cand, try contextualElemTypeAt(c, rctx, i, length));
}

/// True when a (structurally resolved) union contextual type has two or
/// more array-like constituents (`E[] | E[][]`, `A[] | B[]`). Used to
/// detect the ambiguous empty-array-literal case where folding every
/// branch's element type would produce an array assignable to no branch.
fn multiArrayLikeBranches(c: *Checker, rctx: TypeId) Error!bool {
    if (c.ts.kind(rctx) != .union_type) return false;
    var n: usize = 0;
    for (try c.memberList(rctx)) |m| {
        if (c.ts.kind(try c.resolveStructural(m)) == .array) {
            n += 1;
            if (n >= 2) return true;
        }
    }
    return false;
}

/// `[...] as const` -> a readonly tuple. Elements keep their literal
/// types (de-freshened so they never widen); nested array/object
/// literals recurse via the still-set `const_ctx`.
///
/// `ro` is false only for the mutable-array-like contextual type described in
/// `checkArrayLiteral` — the elements are still non-widened, just writable.
fn checkConstArrayLiteral(c: *Checker, node: Node, ro: bool) Error!TypeId {
    const rof: u32 = if (ro) types.elem_flag_readonly else 0;
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    for (c.tree.nodeRange(node)) |el| {
        if (el == null_node) continue;
        switch (c.nodeTag(el)) {
            .omitted => try elems.append(c.scratch(), .{ .ty = types.undefined_type, .flags = rof }),
            .spread_element => {
                const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(el).lhs, types.no_type));
                switch (c.ts.kind(st)) {
                    .tuple => {
                        for (0..c.ts.tupleLen(st)) |j| {
                            const e = c.ts.tupleElem(st, @intCast(j));
                            try elems.append(c.scratch(), .{ .ty = e.ty, .flags = e.flags | rof });
                        }
                    },
                    // A REST element carries the whole array type, not its
                    // element type — that is what `tupleElemTypeAt` /
                    // `elemOfArrayish` and the non-`const` array-literal
                    // path both assume. Storing the element here made
                    // `typeof [a, b, ...vals] as const` index to nothing,
                    // so a mapped type keyed on it collapsed to `{}`.
                    .array => try elems.append(c.scratch(), .{ .ty = st, .flags = types.elem_flag_rest | rof }),
                    else => try elems.append(c.scratch(), .{ .ty = types.any_type, .flags = rof }),
                }
            },
            else => {
                const et = try c.ts.regularLiteral(try c.checkExprCached(el, types.no_type));
                try elems.append(c.scratch(), .{ .ty = et, .flags = rof });
            },
        }
    }
    return c.ts.makeTuple(elems.items);
}

/// tsc's `isMutableArrayLikeType` over every constituent of `ctx` (its
/// `someType(contextualType, …)`): a mutable `T[]`, a tuple whose elements
/// are writable, or a type parameter whose constraint is one. Only consulted
/// inside a const context, so it costs nothing on the ordinary path.
fn ctxIsMutableArrayLike(c: *Checker, ctx: TypeId) Error!bool {
    return ctxIsMutableArrayLikeAt(c, ctx, 0);
}

fn ctxIsMutableArrayLikeAt(c: *Checker, ctx: TypeId, depth: u32) Error!bool {
    if (ctx == types.no_type or depth > 3) return false;
    const t = try c.resolveStructural(ctx);
    switch (c.ts.kind(t)) {
        .array => return !c.ts.arrayIsReadonly(t),
        .tuple => {
            for (0..c.ts.tupleLen(t)) |i| {
                if (c.ts.tupleElem(t, @intCast(i)).readonly()) return false;
            }
            return true;
        },
        .union_type => {
            for (try c.memberList(t)) |m| {
                if (try ctxIsMutableArrayLikeAt(c, m, depth + 1)) return true;
            }
            return false;
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
            return ctxIsMutableArrayLikeAt(c, con, depth + 1);
        },
        else => return false,
    }
}

/// Collect the free type-param symbols reachable in `t` (structural walk,
/// no expansion — a `ref` contributes its args, not its resolved body).
fn collectTypeParamSyms(c: *Checker, t: TypeId, out: *std.ArrayList(u32)) Error!void {
    c.ctp_syms_seen.clearRetainingCapacity();
    return collectTypeParamSymsInner(c, t, out);
}

fn collectTypeParamSymsInner(c: *Checker, t: TypeId, out: *std.ArrayList(u32)) Error!void {
    const s = &c.ts;
    const k = s.kind(t);
    // Memoize the composite nodes. The walk builds a SET, so a node reached a
    // second time can contribute nothing the first visit did not — and the
    // store interns aggressively, so a big generic type is a DAG, not a tree.
    // Walking it as a tree was exponential in the sharing (a conditional
    // forks four ways per level), and outright non-terminating on a type
    // whose structure closes a cycle. Both are reachable from sequelize's
    // model types: outline spent minutes here, 1.9 GB deep, on a single call
    // whose base constraint this is. Leaves are left unmemoized — inserting
    // them would cost more than the visit it saves.
    const composite = switch (k) {
        .array, .union_type, .intersection, .overloads, .tuple, .object, .function, .ref, .template_literal_type, .string_mapping, .keyof_op, .conditional, .index_access, .mapped => true,
        else => false,
    };
    if (composite and (try c.ctp_syms_seen.getOrPut(c.cm(), t)).found_existing) return;
    switch (k) {
        .type_param => {
            const sym = s.typeParamSymbol(t);
            for (out.items) |x| if (x == sym) return;
            try out.append(c.scratch(), sym);
        },
        .array => try collectTypeParamSymsInner(c, s.arrayElem(t), out),
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| try collectTypeParamSymsInner(c, s.memberAt(t, i), out);
        },
        .tuple => {
            for (0..s.tupleLen(t)) |i| try collectTypeParamSymsInner(c, s.tupleElem(t, @intCast(i)).ty, out);
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| try collectTypeParamSymsInner(c, s.objectProp(t, @intCast(i)).ty, out);
            if (s.objectStringIndex(t) != 0) try collectTypeParamSymsInner(c, s.objectStringIndex(t), out);
            if (s.objectNumberIndex(t) != 0) try collectTypeParamSymsInner(c, s.objectNumberIndex(t), out);
        },
        .function => {
            for (0..s.fnParamCount(t)) |i| try collectTypeParamSymsInner(c, s.fnParam(t, @intCast(i)).ty, out);
            try collectTypeParamSymsInner(c, s.fnReturn(t), out);
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| try collectTypeParamSymsInner(c, s.refArgAt(t, i), out);
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| try collectTypeParamSymsInner(c, s.templateHole(t, @intCast(i)), out);
        },
        .string_mapping => try collectTypeParamSymsInner(c, s.stringMappingArg(t), out),
        .keyof_op => try collectTypeParamSymsInner(c, s.keyofOperand(t), out),
        .conditional => {
            try collectTypeParamSymsInner(c, s.condCheck(t), out);
            try collectTypeParamSymsInner(c, s.condExtends(t), out);
            try collectTypeParamSymsInner(c, s.condTrue(t), out);
            try collectTypeParamSymsInner(c, s.condFalse(t), out);
        },
        .index_access => {
            try collectTypeParamSymsInner(c, s.indexAccessObj(t), out);
            try collectTypeParamSymsInner(c, s.indexAccessIndex(t), out);
        },
        // A deferred mapped type mentions its outer params in any of its
        // four parts. Without this arm the base constraint of a map was
        // always the map itself, so a NON-homomorphic generic map
        // (`Omit`/`Pick`/`Record` over a type param), whose key set is the
        // constraint and not a source, had no apparent type at all.
        .mapped => {
            try collectTypeParamSymsInner(c, s.mappedConstraint(t), out);
            try collectTypeParamSymsInner(c, s.mappedValue(t), out);
            if (s.mappedAs(t) != 0) try collectTypeParamSymsInner(c, s.mappedAs(t), out);
            if (s.mappedSource(t) != 0) try collectTypeParamSymsInner(c, s.mappedSource(t), out);
        },
        else => {},
    }
}

/// Reduce a (possibly generic) type to its base constraint by substituting
/// every free type param with its own declared constraint, iterated to a
/// fixed point (tsc's `getBaseConstraintOfType`). Lets a deferred alias
/// like `FieldPath<TFieldValues>` collapse to its concrete `${string}`
/// template union once the abstract inner params are replaced by their
/// constraints, so constraint-sensitive tests can see through it.
/// tsc's `TypeFlags.Instantiable`: a type whose identity still depends on a
/// type argument, so its final shape is not decided yet.
pub fn isInstantiableKind(k: types.Kind) bool {
    return switch (k) {
        .type_param, .keyof_op, .index_access, .conditional, .template_literal_type, .string_mapping, .infer_var => true,
        else => false,
    };
}

/// tsc's `getDefaultConstraintOfConditionalType`: the union of a deferred
/// conditional's two branches (recursively through a nested conditional),
/// each reduced to its own base constraint.
///
/// Deliberately NOT `baseConstraintOf`, which instantiates the whole type
/// with every type parameter's constraint and therefore *evaluates* the
/// conditional — picking exactly one branch. What the callers here need is
/// the set of types the conditional can still produce, which is both.
/// `keyof T extends K[number] ? (K extends readonly (keyof T)[] ? K : E) : E`
/// evaluates to `E` under its constraints, but can still produce a `K`.
pub fn deferredDefaultConstraint(c: *Checker, t: TypeId, depth: u32) Error!TypeId {
    if (depth > 4) return t;
    if (c.ts.kind(t) != .conditional) return c.baseConstraintOf(t);
    const tr = try c.deferredDefaultConstraint(c.ts.condTrue(t), depth + 1);
    const fa = try c.deferredDefaultConstraint(c.ts.condFalse(t), depth + 1);
    return c.makeUnion2(tr, fa);
}

pub fn baseConstraintOf(c: *Checker, t: TypeId) Error!TypeId {
    // A polymorphic `this` is a type variable constrained by its home
    // instance (tsc's `thisType` is a TypeParameter whose constraint is the
    // class/interface type). Every constraint consumer — the deferred
    // indexed-access relation rules above all — needs that step, or a
    // `this["k"]` annotation inside the class body relates to nothing.
    if (c.ts.kind(t) == .this_type) return c.ts.thisTypeInstance(t);
    var syms: std.ArrayList(u32) = .empty;
    defer syms.deinit(c.scratch());
    try collectTypeParamSyms(c, t, &syms);
    if (syms.items.len == 0) return t;
    const map = try c.scratch().alloc(TpMap, syms.items.len);
    for (syms.items, 0..) |sym, i| {
        const con = try c.typeParamConstraint(sym);
        map[i] = .{ .sym = sym, .ty = if (con != types.no_type) con else types.unknown_type };
    }
    var cur = t;
    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        const ni = try c.instantiate(cur, map);
        if (ni == cur) break;
        cur = ni;
    }
    return cur;
}

/// Is `t` (resolved) a primitive / literal / template / enum type, or a
/// union of such — i.e. a context that keeps a matching fresh literal
/// (tsc's `maybeTypeOfKind(..., Literal-ish)`)?
pub fn isPrimitiveLiteralish(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        .string, .string_literal, .template_literal_type, .string_mapping, .number, .number_literal, .number_literal_fresh, .bigint, .bigint_literal, .boolean, .bool_true, .bool_false, .enum_type => true,
        .union_type => blk: {
            for (try c.memberList(r)) |m| {
                if (try c.isPrimitiveLiteralish(m)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Would contextually typing an object-literal argument by `pt` preserve a
/// property literal that would otherwise widen? True only when `pt` (an
/// object) has a property whose type is a *type variable* whose base
/// constraint is primitive-literal-ish — the `name: TFieldName` (`TFieldName
/// extends FieldPath<T>`) shape. This gates the object-literal contextual
/// pass so it fires for react-hook-form-style literal-key inference but not
/// for object literals whose params are plain callbacks (`openDB({ upgrade
/// }))`) or unions, which contextual typing would perturb without benefit.
/// Is object literal `node` CONTEXT SENSITIVE — does it carry a function
/// value with an un-annotated parameter (`{ onChange: (value) => … }`)?
/// tsc's `isContextSensitive` recurses into an object literal's properties
/// for exactly this reason: such a literal's type depends on the contextual
/// type it is checked against, so it must be handed one. Without it, an
/// object-literal argument of a GENERIC call was checked context-free (the
/// non-generic path types the argument by the parameter directly), and
/// every callback parameter inside it fell to implicit `any` — TS7006 at
/// call sites that are correct TypeScript.
pub fn objLitIsContextSensitive(c: *Checker, node: Node) bool {
    return objLitIsContextSensitiveAt(c, node, 0, false);
}

/// The same question restricted to the literal's OWN properties — no
/// recursion into a nested object literal. A shallow-sensitive literal is
/// one the single contextual read already handles: every un-annotated
/// callback parameter it carries is named directly by a property of the
/// parameter type, so reading the literal against that parameter types
/// them. Only a literal whose sensitivity is NESTED is read against a
/// property type that may itself still be a bare inference variable.
pub fn objLitIsShallowContextSensitive(c: *Checker, node: Node) bool {
    return objLitIsContextSensitiveAt(c, node, 0, true);
}

fn objLitIsContextSensitiveAt(c: *Checker, node: Node, depth: u8, shallow: bool) bool {
    for (c.tree.nodeRange(node)) |m| {
        if (m == null_node) continue;
        // tsc's `isContextSensitive` has an explicit ParenthesizedExpression
        // arm: `children: (({ x }) => { })` is exactly as context sensitive
        // as the arrow written bare. Reading the paren node's own tag here
        // made the whole literal look insensitive, so the two-round
        // inference never deferred it and the arrow reached the
        // authoritative pass with no contextual type at all — TS7031 on
        // every destructured parameter it declares.
        const val = switch (c.nodeTag(m)) {
            .object_property, .object_method => skipParens(c, c.tree.nodeData(m).rhs),
            else => continue,
        };
        if (val == null_node) continue;
        switch (c.nodeTag(val)) {
            .arrow_fn, .function_expr => {},
            // tsc's `isContextSensitive` RECURSES through a property
            // assignment into a nested object literal, so a bag of
            // un-annotated callbacks one level down makes the whole
            // argument context sensitive. redux-toolkit's
            // `createSlice({ name, initialState, reducers })` is that
            // shape — the sensitivity lives entirely inside `reducers`.
            .object_literal => {
                if (shallow) continue;
                if (depth < 4 and objLitIsContextSensitiveAt(c, val, depth + 1, false)) return true;
                continue;
            },
            else => continue,
        }
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(val).lhs);
        for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
            if (p == null_node) continue;
            const pd = c.tree.nodeData(p);
            const ann: Node = switch (c.nodeTag(p)) {
                .param => pd.rhs,
                .param_full => c.tree.extraData(ast.ParamFull, pd.rhs).type_ann,
                else => 0,
            };
            if (ann == 0) return true; // parameter has no type annotation
        }
    }
    return false;
}

/// tsc's `isLiteralOfContextualType`: does `ctx` name a literal domain that
/// the literal `cand` belongs to?
///
/// `checkExpressionWithContextualType` strips a contextually typed literal's
/// FRESHNESS on exactly this test, with the comment "such that contextually
/// typed literals always preserve their literal types (otherwise they might
/// widen during type inference)". That is the whole mechanism by which
/// `on(eventName: K | keyof T, …)` infers `K = "add"` while
/// `useState(initial: S | (() => S))` still widens `false` to `boolean`: the
/// first union has a string-literal constituent for `"add"` to match, the
/// second has nothing for `false` to match.
pub fn literalOfContextualType(c: *Checker, cand: TypeId, ctx: TypeId) Error!bool {
    return literalOfContextualTypeAt(c, cand, ctx, 0);
}

fn literalOfContextualTypeAt(c: *Checker, cand: TypeId, ctx: TypeId, depth: u8) Error!bool {
    if (depth > 4 or ctx == types.no_type) return false;
    const s = &c.ts;
    switch (s.kind(ctx)) {
        .union_type, .intersection => {
            for (try c.memberList(ctx)) |m| {
                if (try literalOfContextualTypeAt(c, cand, m, depth + 1)) return true;
            }
            return false;
        },
        // tsc's `InstantiableNonPrimitive`: a type variable constrained to a
        // primitive keeps the literal, and so does one whose constraint names
        // the literal domain outright.
        .type_param, .index_access, .conditional => {
            const con = if (s.kind(ctx) == .type_param)
                try c.typeParamConstraint(s.typeParamSymbol(ctx))
            else
                try c.transitiveBaseConstraint(ctx);
            if (con == types.no_type or con == ctx) return false;
            if (try maybeLiteralKind(c, cand, .string_literal) and try maybeKind(c, con, .string)) return true;
            if (try maybeLiteralKind(c, cand, .number_literal) and try maybeKind(c, con, .number)) return true;
            if (try maybeLiteralKind(c, cand, .bigint_literal) and try maybeKind(c, con, .bigint)) return true;
            return literalOfContextualTypeAt(c, cand, con, depth + 1);
        },
        // `Index` / `TemplateLiteral` / `StringMapping` name the string-literal
        // domain the same way a string literal does.
        .string_literal, .keyof_op, .template_literal_type, .string_mapping => return maybeLiteralKind(c, cand, .string_literal),
        .number_literal, .number_literal_fresh => return maybeLiteralKind(c, cand, .number_literal),
        .bigint_literal => return maybeLiteralKind(c, cand, .bigint_literal),
        .bool_true, .bool_false => return maybeLiteralKind(c, cand, .bool_true),
        .unique_symbol => return maybeLiteralKind(c, cand, .unique_symbol),
        .enum_type => return s.isEnumMember(ctx) and (try maybeLiteralKind(c, cand, .enum_type)),
        else => return false,
    }
}

/// tsc's `maybeTypeOfKind` for the literal kinds: any constituent of `t`
/// (which may be a union) is of the given literal kind. `.number_literal`
/// covers its fresh twin, and `.bool_true` stands for either boolean literal.
fn maybeLiteralKind(c: *Checker, t: TypeId, want: types.Kind) Error!bool {
    const s = &c.ts;
    if (s.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (try maybeLiteralKind(c, m, want)) return true;
        }
        return false;
    }
    const k = s.kind(t);
    return switch (want) {
        .string_literal => k == .string_literal,
        .number_literal => k == .number_literal or k == .number_literal_fresh,
        .bigint_literal => k == .bigint_literal,
        .bool_true => k == .bool_true or k == .bool_false,
        .unique_symbol => k == .unique_symbol,
        .enum_type => k == .enum_type,
        else => false,
    };
}

/// The primitive-domain half of the same test: does `t` (possibly a union)
/// have a constituent of primitive kind `want`?
fn maybeKind(c: *Checker, t: TypeId, want: types.Kind) Error!bool {
    const s = &c.ts;
    if (s.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (try maybeKind(c, m, want)) return true;
        }
        return false;
    }
    return s.kind(t) == want;
}

pub fn paramWantsLiteralCtx(c: *Checker, pt: TypeId) Error!bool {
    return paramWantsLiteralCtxAt(c, pt, 0);
}

fn paramWantsLiteralCtxAt(c: *Checker, pt: TypeId, depth: u8) Error!bool {
    const r = try c.resolveStructural(pt);
    // A `const` type parameter always wants the contextual read: that IS the
    // feature. Handing the parameter down is what puts the argument in a
    // const context (`checkExpr`'s array/object-literal arm), and an
    // unconstrained `const T` has no constraint for the literal-ish test
    // below to look at.
    if (c.isConstTypeVar(r)) return true;
    // An INTERSECTION parameter (`o: { elbowed?: T; … } & Opts`) wants the
    // same per-property contextual type as its object constituents do:
    // `ctxPropType` already has an `.intersection` arm that finds `T`, but
    // it is only reached when the argument is checked WITH the parameter as
    // its contextual type. Answering `false` here checks the object literal
    // context-free, so `elbowed: true` widens to `boolean` and the callee's
    // `T extends true ? … : …` return takes the wrong branch.
    if (c.ts.kind(r) == .intersection and depth < 2) {
        for (try c.memberList(r)) |m| {
            if (m == r) continue;
            if (try paramWantsLiteralCtxAt(c, m, depth + 1)) return true;
        }
        return false;
    }
    // A still-generic MAPPED parameter (`c: { [K in keyof T]: T[K] }`) has
    // no members for the property scan below to read, but it is exactly the
    // shape whose per-property contextual type must be handed down: it is
    // what tells a property value's fresh literal to stay a literal and a
    // property value's callback what its parameters are (see `ctxPropType`'s
    // `.mapped` arm). Without it every such argument is checked
    // context-free.
    if (c.ts.kind(r) == .mapped) return true;
    // An ARRAY parameter (`options: { value: T; label: string }[]`) wants the
    // same per-element contextual type its element type does: the elements
    // are object literals whose `value` property is the literal-constrained
    // inference target. Checked context-free, `{ value: Breed.Nellore }`
    // widens the enum member to the whole enum and `T` is inferred as `Breed`.
    if (c.ts.kind(r) == .array and depth < 2) return paramWantsLiteralCtxAt(c, c.ts.arrayElem(r), depth + 1);
    if (c.ts.kind(r) != .object) return false;
    for (0..c.ts.objectPropCount(r)) |i| {
        const p = c.ts.objectProp(r, @intCast(i));
        const pr = try c.resolveStructural(p.ty);
        // A `const` type parameter under a property (`x: { v: T }`) is the
        // nested half of the same rule: the property's contextual type is
        // what puts `{ v: [1, 2] }`'s element list in a const context.
        if (c.isConstTypeVar(pr)) return true;
        if (c.ts.kind(pr) != .type_param) continue;
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(pr));
        if (con == types.no_type) continue;
        const base = if (try c.containsTypeParam(con)) try c.baseConstraintOf(con) else con;
        if (try c.isPrimitiveLiteralish(base)) return true;
    }
    return false;
}

/// Does the contextual type admit literal types of `t`'s kind, so the
/// fresh literal should be kept instead of widened? (tsc's
/// isLiteralOfContextualType; contextual `boolean` counts because it
/// *is* `true | false` — our canonical form collapses that union.)
fn keepLiteral(c: *Checker, t: TypeId, ctx: TypeId) Error!bool {
    if (ctx == types.no_type) return false;
    if (!c.ts.isFreshLiteral(t)) return true;
    return c.contextAdmitsLiteral(ctx, t);
}

pub fn contextAdmitsLiteral(c: *Checker, ctx: TypeId, lit: TypeId) Error!bool {
    const r = try c.resolveStructural(ctx);
    const lk = c.ts.kind(lit);
    const lit_is_bool = lk == .bool_true or lk == .bool_false;
    // tsc carries BOTH flags on an enum member's type (`EnumLiteral |
    // StringLiteral`), so `maybeTypeOfKind(candidate, StringLiteral)` — the
    // candidate half of every arm below — is true for a string enum member as
    // much as for `"a"`. ztsc gives an enum member its own `.enum_type` kind,
    // so the candidate has to be mapped to the literal kind it stands for
    // before the arms compare. Without it a string-literal context (`keyof`
    // of an object with enum-computed keys) rejected an enum member and the
    // property value widened to the whole enum.
    const clk = try enumMemberLiteralKind(c, lit, lk);
    switch (c.ts.kind(r)) {
        .string_literal => return clk == .string_literal,
        .number_literal, .number_literal_fresh => return clk == .number_literal or clk == .number_literal_fresh,
        .bigint_literal => return clk == .bigint_literal,
        .bool_true, .bool_false, .boolean => return lit_is_bool,
        // An enum MEMBER context keeps a fresh member of the same enum
        // (`const a: WS.A[] = [WS.A]`). So does the WHOLE enum: tsc models
        // an enum type as the UNION of its members, and
        // `isLiteralOfContextualType` recurses through a union, so
        // `<T extends WS>(o: { k: T })` called with `{ k: WS.A }` infers
        // `T = WS.A`. A bare `const o = { k: WS.A }` still widens — it has no
        // contextual type at all, so it never reaches here.
        .enum_type => {
            if (!c.ts.isEnumMember(lit)) return false;
            if (c.ts.isEnumMember(r)) return true;
            return c.ts.enumSymbol(r) == c.ts.enumSymbol(lit);
        },
        // tsc's `isLiteralOfContextualType` treats a union and an
        // INTERSECTION alike (`contextualType.flags & UnionOrIntersection`
        // → `some(types, …)`). An intersection contextual type is exactly
        // what a property of `Settings & { leading: true }` gets — the
        // members are `boolean | undefined` and `true`, and only the second
        // admits the literal. Without the arm the fresh `true` widened to
        // `boolean`, which no longer matched the `{ leading: true }` arm of
        // the parameter union, so the whole overload was rejected.
        .union_type, .intersection => {
            for (try c.memberList(r)) |m| {
                if (try c.contextAdmitsLiteral(m, lit)) return true;
            }
            return false;
        },
        // A template-literal or string-mapping context is a string subtype
        // that admits any string literal *matching the pattern* (tsc
        // isLiteralOfContextualType final mask: TemplateLiteral/StringMapping
        // & isTypeAssignableTo). A generic call whose parameter is
        // constrained to such a type — react-hook-form's `name: FieldPath<T>`
        // (a `` `${string}` ``/dotted-path template union) — keeps the fresh
        // field-name literal so the type param infers to it rather than
        // widening to `string`.
        .template_literal_type, .string_mapping => return lk == .string_literal and try c.isAssignable(lit, r),
        // No `.keyof_op` arm, even though tsc's `isLiteralOfContextualType`
        // final mask lists `TypeFlags.Index` beside `StringLiteral`: every
        // shape that reaches it here arrives as the type PARAMETER whose
        // constraint is the `keyof` (`K extends readonly (keyof R)[]`), and
        // the `.type_param` arm below already keeps the literal for those.
        // Adding the arm changed no corpus or probe output, so it stays out
        // rather than being carried unexercised. What still clamps —
        // `...keys: [...K]` inferring `K` as its constraint instead of the
        // argument tuple — is a variadic-tuple inference gap, not this test.
        .type_param => {
            const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
            if (constraint == types.no_type) return false;
            if (try c.contextAdmitsLiteral(constraint, lit)) return true;
            // A generic constraint (`TFieldName extends FieldPath<
            // TFieldValues>`) stays deferred while its own type params are
            // abstract, so the resolved form is neither a literal nor a
            // template and the test above fails. Reduce it to its base
            // constraint (inner params → their constraints) so the alias
            // collapses to its concrete `${string}` template union and can
            // admit the field-name literal. Only the generic case retries —
            // a concrete constraint already had its full say above.
            // An enum MEMBER is a string/number literal too (tsc gives it
            // `TypeFlags.StringLiteral | EnumLiteral`), so the type-variable
            // rule below must judge it by the kind of its declared value.
            const elk = try enumMemberLiteralKind(c, lit, lk);
            if (try c.containsTypeParam(constraint)) {
                const base = try c.baseConstraintOf(constraint);
                if (base != constraint) {
                    if (try c.contextAdmitsLiteral(base, lit)) return true;
                    return constraintKeepsLiteralKind(c, base, elk);
                }
            }
            // tsc's `isLiteralOfContextualType` type-VARIABLE rule: a
            // constraint that merely *contains* the literal's primitive
            // (`T extends string`) is a literal context, even though the
            // primitive itself is a widening context in every other
            // position. That is what makes `isMemberOf<T extends string>(
            // coll: readonly T[], v)` called with `["a", "b"]` infer
            // `T = "a" | "b"` instead of `string`.
            return constraintKeepsLiteralKind(c, constraint, elk);
        },
        else => return false,
    }
}

/// The literal KIND an enum member stands for — the kind of its declared
/// value (`.string_literal` for a string enum, `.number_literal` for a
/// numeric one). Non-members answer with `fallback` (their own kind). tsc
/// carries both flags on one type; ztsc models an enum member as its own
/// `.enum_type` kind, so the mapping is explicit.
fn enumMemberLiteralKind(c: *Checker, lit: TypeId, fallback: types.Kind) Error!types.Kind {
    if (!c.ts.isEnumMember(lit)) return fallback;
    const v = try c.enumMemberValue(c.ts.enumSymbol(lit), c.ts.enumMemberAtom(lit)) orelse return fallback;
    return c.ts.kind(v);
}

/// tsc's `maybeTypeOfKind(constraint, <primitive of the literal>)` half of
/// `isLiteralOfContextualType`'s type-variable rule: does `constraint`
/// contain the primitive that `lk` is a literal of? Unions and
/// intersections are searched; a bare `string`/`number`/`bigint`/`boolean`
/// answers for its own literal kind.
fn constraintKeepsLiteralKind(c: *Checker, constraint: TypeId, lk: types.Kind) Error!bool {
    const r = try c.resolveStructural(constraint);
    switch (c.ts.kind(r)) {
        .union_type, .intersection => {
            for (try c.memberList(r)) |m| {
                if (try constraintKeepsLiteralKind(c, m, lk)) return true;
            }
            return false;
        },
        .string, .template_literal_type, .string_mapping => return lk == .string_literal,
        .number => return lk == .number_literal or lk == .number_literal_fresh,
        .bigint => return lk == .bigint_literal,
        .boolean => return lk == .bool_true or lk == .bool_false,
        else => return false,
    }
}

/// Upper bound on the constituents of a distributed union spread (see
/// `checkObjectLiteral`). The work is linear in this number, and the unions
/// that need it are hand-written discriminated unions an order of magnitude
/// below the bound; anything wider folds instead.
pub const max_spread_distribution = 16;

/// One distributable spread element: the element node and the constituents
/// of its union source.
pub const DistSpread = struct { node: Node, members: []const TypeId };

/// The spread elements of `node` whose sources are unions worth
/// distributing over. Empty when there are none, or when the cartesian
/// product of their constituents would exceed `max_spread_distribution` —
/// the work is linear in that product, so the bound is on the product, not
/// on any one union.
///
/// More than one is the common shape for a literal that re-tags a
/// discriminated union through a helper: `{ ...prevState.activeTool,
/// ...updateActiveTool(…), locked }` spreads two two-member unions, and
/// folding EITHER of them loses the property correlation that the target's
/// arms discriminate on. Distributing only one of the two left the other
/// folded, which is the same lost-correlation failure the single-spread
/// distribution was introduced to fix.
fn distributableSpreads(c: *Checker, node: Node, out: *std.ArrayList(DistSpread)) Error!void {
    var product: usize = 1;
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node or c.nodeTag(prop) != .spread_element) continue;
        const st = try c.resolveStructural(try c.checkExprCached(c.tree.nodeData(prop).lhs, types.no_type));
        if (c.ts.kind(st) != .union_type) continue;
        const ms = try c.memberList(st);
        if (ms.len < 2 or ms.len > max_spread_distribution) continue;
        var ok = true;
        var carriers: usize = 0;
        for (ms) |m| {
            const rm = try c.resolveStructural(m);
            switch (c.ts.kind(rm)) {
                .object => if (c.ts.objectPropCount(rm) > 0) {
                    carriers += 1;
                },
                .intersection => carriers += 1,
                .null, .undefined, .void => {},
                else => ok = false,
            }
        }
        // At least two constituents must actually carry properties. A
        // `T | undefined` (or `T | {}`) spread has one, and distributing it
        // says nothing the fold does not already say — `undefined` and `{}`
        // both spread the empty object, so every property is optional
        // either way — while turning the literal into a union that
        // perturbs inference at the use site.
        if (!ok or carriers < 2) continue;
        product *|= ms.len;
        if (product > max_spread_distribution) {
            out.clearRetainingCapacity();
            return;
        }
        try out.append(c.scratch(), .{ .node = prop, .members = try c.scratch().dupe(TypeId, ms) });
    }
}

fn checkObjectLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const t = try objectLiteralWhole(c, node, ctx);
    // Duplicate keys — tsc's `checkGrammarObjectLiteralExpression`. Run AFTER
    // the type walk (and exactly once per literal, however many constituents a
    // spread distributed it into) so that every computed key the walk typed is
    // already in the node-type memo: the check then needs no evaluation of its
    // own, and cannot introduce a diagnostic by being the first to read a key
    // the type walk never reads at all (an object METHOD's computed key).
    // A destructuring ASSIGNMENT pattern is exempt and never arrives here — it
    // goes through `checkDestructuringElement`.
    try c.checkObjectLiteralDups(node);
    try checkSpreadPropOverrides(c, node);
    try checkSpreadOperandTypes(c, node);
    return t;
}

/// tsc's `isValidSpreadType` gate on every `{ ...x }` element (TS2698).
///
/// Runs here, exactly once per literal, for the same reason
/// `checkSpreadPropOverrides` does: `objectLiteralWhole` re-enters
/// `objectLiteralType` once per constituent of a DISTRIBUTED union spread, and
/// each of those passes sees one member (`{ ...(Full | null) }` would ask about
/// `null` on its own and report where tsc, which judges the whole union, is
/// silent). The operand's type is read from the node-type memo the walk has
/// already published, so nothing is evaluated a second time.
fn checkSpreadOperandTypes(c: *Checker, node: Node) Error!void {
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node or c.nodeTag(prop) != .spread_element) continue;
        const raw = c.nodeType(c.tree.nodeData(prop).lhs) orelse continue;
        if (try validSpreadType(c, raw, 0)) continue;
        try c.diagFmt(2698, c.nodeSpan(prop), "Spread types may only be created from object types.", .{});
    }
}

/// tsc's `checkSpreadPropOverrides`: a property written BEFORE a spread whose
/// source declares the same name NON-optionally is dead code — the spread
/// always wins — so tsc reports TS2783 at the earlier property.
///
/// Only SYNTACTIC properties count, and only those written earlier: tsc keeps
/// them in a side table (`allPropertiesTable`) that a spread's own properties
/// never enter. That is what makes `{ ...ab, ...ab }` silent while
/// `{ b: 1, ...ab }` is not, and what makes a property written BETWEEN two
/// spreads count for the second one.
///
/// Reads the spread source out of the node-type memo (the type walk has
/// already published it) rather than re-checking, so this adds no evaluation
/// and cannot be the first to report anything inside the operand.
///
/// First landed in wave 11 and reverted the same wave: `pick(COLOR_PALETTE,
/// ["cyan", …]): Pick<R, K[number]>` inferred `K` as its CONSTRAINT, so the
/// spread source was the whole palette and excalidraw's `colors.ts` collected
/// ten false positives. That inference gap was fixed in wave 12 (`78e8321`) —
/// the check itself needed no change.
fn checkSpreadPropOverrides(c: *Checker, node: Node) Error!void {
    const members = c.tree.nodeRange(node);
    // The overwhelming majority of literals carry no spread at all.
    var has_spread = false;
    for (members) |prop| {
        if (prop != null_node and c.nodeTag(prop) == .spread_element) has_spread = true;
    }
    if (!has_spread) return;

    const Seen = struct { name: Atom, node: Node };
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(c.scratch());
    for (members) |prop| {
        if (prop == null_node) continue;
        const pd = c.tree.nodeData(prop);
        switch (c.nodeTag(prop)) {
            .spread_element => {
                if (seen.items.len == 0) continue;
                const raw = c.nodeType(pd.lhs) orelse continue;
                // A bare TYPE PARAMETER source is not evidence of an
                // overwrite here, even though tsc — reading its apparent
                // type — does report through one. ztsc's object-rest type
                // for a generic receiver is the receiver ITSELF:
                // `objectRestType` bails on a shape it cannot enumerate
                // instead of building tsc's `Omit<T, "a">`. So inside
                // `<T extends { a: string, b: string }>`, the `rest` of
                // `let { a, ...rest } = obj` still claims to have `a`, and
                // `{ a: 'hello', ...rest }` collected a false TS2783.
                // Re-report through type parameters once the rest type
                // learns to omit.
                if (c.ts.kind(raw) == .type_param) continue;
                const st = try c.resolveStructural(raw);
                switch (c.ts.kind(st)) {
                    .any, .err, .unknown, .never => continue,
                    else => {},
                }
                for (seen.items) |s| {
                    // `allow_index = false`: tsc compares against
                    // `getPropertiesOfType`, which an index signature is not a
                    // member of — `{ a: 1, ...someRecord }` overwrites nothing
                    // tsc can name.
                    const p = (try c.propOfTypeEx(st, s.name, false)) orelse continue;
                    if (p.optional()) continue;
                    try c.diagFmt(2783, c.nodeSpan(s.node), "'{s}' is specified more than once, so this usage will be overwritten.", .{
                        c.atomText(s.name),
                    });
                }
            },
            // A computed key names no property tsc can compare against the
            // spread's, so only the statically-keyed forms are tracked.
            .object_property, .object_method, .object_shorthand => {
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                try seen.append(c.scratch(), .{ .name = try c.memberAtom(c.tree.nodeMainToken(prop)), .node = prop });
            },
            else => {},
        }
    }
}

fn objectLiteralWhole(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    // tsc's `getSpreadType` DISTRIBUTES over a union spread source:
    // `{ ...(A | B), x }` is `{ ...A, x } | { ...B, x }`, and each
    // constituent keeps the correlation between the properties that came
    // from one union member. Folding the union into a single object (what
    // `gatherSpreadProps` does when the distribution does not apply) loses
    // that correlation — every property only some member declares becomes
    // optional — so the literal then matches no arm of a discriminated
    // target. Distribute here, where the literal's type can be a union.
    var dist: std.ArrayList(DistSpread) = .empty;
    defer dist.deinit(c.scratch());
    try distributableSpreads(c, node, &dist);
    if (dist.items.len > 0) {
        // Cartesian product over the distributable spreads, `max_spread_
        // distribution` constituents at most. `pick[i]` selects the member
        // of `dist.items[i]` this constituent uses.
        var pick: [max_spread_distribution]usize = @splat(0);
        var outs: std.ArrayList(TypeId) = .empty;
        defer outs.deinit(c.scratch());
        var subst: std.ArrayList(Subst) = .empty;
        defer subst.deinit(c.scratch());
        while (true) {
            subst.clearRetainingCapacity();
            for (dist.items, 0..) |d, i| {
                try subst.append(c.scratch(), .{ .node = d.node, .ty = d.members[pick[i]] });
            }
            try outs.append(c.scratch(), try objectLiteralType(c, node, ctx, subst.items));
            // Odometer step, least-significant spread first.
            var i = dist.items.len;
            while (i > 0) {
                i -= 1;
                pick[i] += 1;
                if (pick[i] < dist.items[i].members.len) break;
                pick[i] = 0;
                if (i == 0) return c.ts.makeUnion(c.scratch(), outs.items);
            }
        }
    }
    return objectLiteralType(c, node, ctx, &.{});
}

/// A spread element whose source type is replaced by `ty` for one
/// constituent of a distributed object literal (see `checkObjectLiteral`).
pub const Subst = struct { node: Node, ty: TypeId };

/// tsc's `instantiateContextualType(…, ContextFlags.Signature)`: before a
/// nested expression reads a still-generic contextual type, tsc re-instantiates
/// it with the inferences made SO FAR (`inferenceContext.nonFixingMapper`), so
/// `Props<C> = { as?: C } & Elements[C]` is already `Props<"bar">` by the time
/// the `callback` property asks for its contextual signature.
///
/// ztsc has no inference context in hand here, so this recovers the one shape
/// that matters and nothing else: a property of the literal whose contextual
/// type is a BARE type parameter binds that parameter to the property's own
/// (context-free) value type. Only the value forms discrimination already
/// trusts are read, and only a value satisfying the parameter's constraint
/// binds it — an unconstrained guess would substitute a type tsc's inference
/// would have widened or discarded.
///
/// Without it the contextual type stays generic, ztsc reads `Elements[C]`
/// through its base constraint — a union of every element's props — and the
/// callback's contextual signature is a disagreeing union: TS7006.
fn resolveCtxTypeParams(c: *Checker, node: Node, rctx: TypeId) Error!TypeId {
    if (!try c.containsFreeTypeParam(rctx, &.{})) return rctx;
    var map: std.ArrayList(TpMap) = .empty;
    defer map.deinit(c.scratch());
    props: for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const pd = c.tree.nodeData(prop);
        const value: Node = switch (c.nodeTag(prop)) {
            .object_property => if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue else pd.rhs,
            .object_shorthand => pd.lhs,
            else => continue,
        };
        if (!discriminate_ctx.possiblyDiscriminantValue(c, value)) continue;
        const key = try c.memberAtom(c.tree.nodeMainToken(prop));
        const pctx = try c.ctxPropType(rctx, rctx, key);
        if (pctx == types.no_type or c.ts.kind(pctx) != .type_param) continue;
        const sym = c.ts.typeParamSymbol(pctx);
        // First binding wins, as tsc's first inference candidate does.
        for (map.items) |m| if (m.sym == sym) continue :props;
        // An UNCONSTRAINED parameter is not bound at all — the doc's "an
        // unconstrained guess would substitute a type tsc's inference would
        // have widened or discarded", now that an object-literal argument
        // reaches here with the parameter as its contextual type at all.
        // `boxed<T>(x: { v: T })` called with `{ v: true }` infers `T =
        // boolean`, because `isLiteralOfContextualType`'s type-variable rule
        // reads the CONSTRAINT and a bare `T` has none; binding the fresh
        // `true` made the substituted context `{ v: true }`, which then
        // admitted itself and pinned `T` at `true`. Substituting the WIDENED
        // value does not help either — `{ v: boolean }` is a literal context
        // for `true` in its own right. Leaving `T` free is what tsc does, and
        // the widening rule then applies to it directly
        // (`inference/088_top_level_param_still_widens`,
        // `inference/return_context_keeps_object_prop_literal`).
        const con = try c.typeParamConstraint(sym);
        if (con == types.no_type) continue;
        const vt = try c.checkExprCached(value, types.no_type);
        if (!try c.isAssignable(vt, con)) continue;
        try map.append(c.scratch(), .{ .sym = sym, .ty = vt });
    }
    if (map.items.len == 0) return rctx;
    return c.resolveStructural(try c.instantiate(rctx, map.items));
}

/// tsc's `isValidSpreadType`, the gate on `{ ...x }` (TS2698). It reads
///
///     const t = removeDefinitelyFalsyTypes(mapType(type, getBaseConstraintOrType));
///     return !!(t.flags & (Any | NonPrimitive | Object | InstantiableNonPrimitive)
///         || t.flags & UnionOrIntersection && every(t.types, isValidSpreadType));
///
/// The ORDER of the two rewrites is the whole subtlety: a type parameter is
/// replaced by its CONSTRAINT first (an unconstrained one stays a type
/// variable and passes), and only then are the definitely-falsy constituents
/// dropped. That is why `T | (T & undefined)` and `object | T` for `T extends
/// undefined` both spread fine — the falsy half disappears — while a bare
/// `undefined`, reduced to `never`, does not (`spreadObjectOrFalsy`). Both
/// rewrites re-run at every recursion, exactly as tsc's own recursive call
/// does.
///
/// Measured against the pinned oracle across `undefined | null | void |
/// unknown | never | boolean | symbol | number | string | bigint | enum | true
/// | 0 | ""` (all rejected) and `object | () => void | number[] |
/// { a: 1 } | undefined | { a: 1 } | null` (all accepted).
///
/// `depth` bounds the constraint chase; unmodelled kinds answer VALID, so a
/// shape ztsc types loosely stays silent rather than earning a false TS2698.
fn validSpreadType(c: *Checker, t: TypeId, depth: u8) Error!bool {
    if (depth > 8) return true;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    try collectSpreadParts(c, t, depth, &parts);
    // Everything dropped: `removeDefinitelyFalsyTypes` left `never`, which is
    // not an object type (`spreadUnion3`'s `{ ...nullAndUndefinedUnion }`).
    if (parts.items.len == 0) return false;
    for (parts.items) |p| {
        switch (c.ts.kind(p)) {
            // `every(t.types, isValidSpreadType)` — and the recursion re-runs
            // the constraint mapping, so `(T | undefined) & T` for
            // `T extends {}` passes through `{} | undefined` -> `{}`.
            .intersection => for (try c.memberList(p)) |m| {
                if (!try validSpreadType(c, m, depth + 1)) return false;
            },
            // Primitives, literals and the INSTANTIABLE-PRIMITIVE deferrals
            // (`keyof T`, a template-literal type, `Uppercase<T>`): the whole
            // point of the diagnostic. A type parameter that survived the
            // mapping is unconstrained, hence a valid type VARIABLE.
            .unknown,
            .string,
            .number,
            .boolean,
            .bigint,
            .symbol,
            .bool_true,
            .string_literal,
            .number_literal,
            .number_literal_fresh,
            .bigint_literal,
            .enum_type,
            .unique_symbol,
            .keyof_op,
            .template_literal_type,
            .string_mapping,
            => return false,
            else => {},
        }
    }
    return true;
}

/// `removeDefinitelyFalsyTypes(mapType(t, getBaseConstraintOrType))`, flattened
/// into the surviving constituents. A union distributes (and a constraint that
/// is itself a union flattens into the same list, which is what `getUnionType`
/// does after `mapType`).
fn collectSpreadParts(c: *Checker, t: TypeId, depth: u8, out: *std.ArrayList(TypeId)) Error!void {
    if (depth > 8) {
        // Give up chasing: `any` is the constituent that keeps the caller quiet.
        try out.append(c.scratch(), types.any_type);
        return;
    }
    var r = try c.resolveStructural(t);
    if (c.ts.kind(r) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
        // An unconstrained type parameter maps to ITSELF (tsc's
        // `getBaseConstraintOrType`), and is a valid type variable.
        if (con == types.no_type) {
            try out.append(c.scratch(), r);
            return;
        }
        r = try c.resolveStructural(con);
    }
    if (c.ts.kind(r) == .union_type) {
        for (try c.memberList(r)) |m| try collectSpreadParts(c, m, depth + 1, out);
        return;
    }
    if (try definitelyFalsySpread(c, r)) return;
    try out.append(c.scratch(), r);
}

/// tsc's `hasTypeFacts(t, TypeFacts.Truthy)` complement — the constituents
/// `removeDefinitelyFalsyTypes` drops before `isValidSpreadType` looks at what
/// is left. An INTERSECTION ands its constituents' facts
/// (`getIntersectionTypeFacts`), so one falsy member makes the whole of
/// `T & undefined` falsy — which is exactly what keeps `T | (T & undefined)`
/// spreadable.
fn definitelyFalsySpread(c: *Checker, r: TypeId) Error!bool {
    return switch (c.ts.kind(r)) {
        .undefined, .null, .void, .never, .bool_false => true,
        .string_literal => c.atomText(c.ts.literalAtom(r)).len == 0,
        .number_literal, .number_literal_fresh => c.ts.numberValue(r) == 0,
        .intersection => blk: {
            for (try c.memberList(r)) |m| {
                if (try definitelyFalsySpread(c, try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// The `this` a function-like member of an object literal sees, from the
/// literal's already-resolved contextual type (`rctx`, `no_type` when there is
/// none) — tsc's `getContextualThisParameterType` for an object-literal method.
///
/// `ThisType<T>` comes FIRST and unconditionally: the lib's empty marker
/// interface exists only to say "the members of whatever I am intersected with
/// run on a `T`", and tsc reads it before anything else
/// (`getThisTypeFromContextualType`, whose result short-circuits the whole
/// rest of the function). Without it a Vue-style
/// `Component<D, M & ThisType<D & M>>` gave every method the OPTIONS object as
/// its receiver, so `this.dataField` inside a method was a TS2339 for a field
/// the marker had just promised (`vueLikeDataAndPropsInference`,
/// `thisTypeInObjectLiterals2`).
///
/// Failing a marker it is the contextual type itself, taken NON-NULLABLE —
/// tsc's `getWidenedType(getNonNullableType(contextualType))`. A nullable
/// annotation is a statement about the VARIABLE, not about the literal being
/// written into it: every method of `let p: Point | null = { x: 10, moveBy() {
/// this.x += dx } }` runs on a real `Point`, and reading `this.x` through the
/// union reported "possibly null" at every member access.
fn objectLiteralThis(c: *Checker, rctx: TypeId, marker: TypeId) Error!TypeId {
    // The `ThisType<T>` marker wins wherever the outward walk found it — this
    // literal's own contextual type first, then an enclosing literal's (see
    // `Checker.ctx_this_marker`).
    //
    // Either answer is REFUSED while it still names a free type variable.
    // tsc's line is
    //
    // ```ts
    // return instantiateType(thisType, getMapperFromContext(getInferenceContext(containingLiteral)));
    // ```
    //
    // — the marker is instantiated through the enclosing call's inference
    // context, which by then has every candidate, because tsc DEFERS an
    // object-literal method's body (`checkNodeDeferred`) until the call it is
    // an argument of has finished inferring. ztsc walks the body inline, while
    // this argument is still the thing being inferred FROM, so the variables
    // are all it could read: vue's `ThisType<Data & Readonly<Props> &
    // Instance>` would answer `this.bar` against a free `Data`
    // (`vueLikeDataAndPropsInference`, `multipleInferenceContexts`,
    // `mappedTypeInferenceErrors`). An unresolved `this` — tsc's own fallback
    // shape, `any` at every read — is an under-report; the uninstantiated type
    // is a false positive.
    if (marker != types.no_type) {
        return if (try c.containsFreeTypeParam(marker, &.{})) 0 else marker;
    }
    if (rctx == types.no_type) return 0;
    if (try c.containsFreeTypeParam(rctx, &.{})) return 0;
    return c.nonNullable(rctx);
}

/// tsc's `getThisTypeFromContextualType`: the argument of a `ThisType<T>`
/// reference anywhere in the contextual type, unions mapped and intersections
/// searched member-wise. Null when the type names no marker.
fn thisTypeMarker(c: *Checker, t: TypeId) Error!?TypeId {
    switch (c.ts.kind(t)) {
        .union_type, .intersection => {
            for (try c.memberList(t)) |m| {
                if (try thisTypeMarker(c, m)) |x| return x;
            }
            return null;
        },
        .ref => {
            const args = c.ts.refArgs(t);
            if (args.len == 0) return null;
            const sym = c.prog.globals.lookup(try c.atom("ThisType")) orelse return null;
            if (c.ts.refSymbol(t) != sym) return null;
            return args[0];
        },
        else => return null,
    }
}

/// Check an object-literal property VALUE, handing an object literal written
/// DIRECTLY there the `ThisType<T>` marker in scope. tsc's outward walk steps
/// through a property assignment and nothing else, so every other value — a
/// call whose argument happens to be a literal, an array, a function — is
/// checked with the marker cleared (see `Checker.ctx_this_marker`).
fn checkPropValue(c: *Checker, value: Node, pctx: TypeId, marker: TypeId) Error!TypeId {
    if (marker == types.no_type or value == null_node or c.nodeTag(value) != .object_literal) {
        return c.checkExprCached(value, pctx);
    }
    c.ctx_this_marker = marker;
    defer c.ctx_this_marker = types.no_type;
    return c.checkExprCached(value, pctx);
}

/// tsc's `getUnionIndexInfos`, which is what decides an object literal's
/// index signatures once the literal SPREADS.
///
/// `getSpreadType` folds the literal left to right, and its parts are the
/// spread sources interleaved with the runs of own properties between them
/// (`checkObjectLiteral` flushes `propertiesArray` into a part before each
/// spread and once more at the end). An index signature survives only when
/// EVERY part declares one: `getUnionIndexInfos` seeds its candidate list
/// from the accumulated left and drops any key type `every(types, …)` does
/// not answer for. The first fold is the exception that makes part 0 a SEED
/// rather than a filter — `left === emptyObjectType` takes the right's infos
/// verbatim.
///
/// So `{ ...indexed1, b: 11 }` has no index signature at all, because the
/// `{ b: 11 }` part has none, and `i[101]` on the result is TS7053
/// (`objectSpreadIndexSignature`). Carrying one anyway silences exactly the
/// reads tsc refuses. `{ ...indexed1, ...indexed2 }` keeps one, with the
/// UNION of the two value types.
///
/// A literal with no spread never reaches `getSpreadType`: its index
/// signatures come from its computed keys alone
/// (`getObjectLiteralIndexInfo`), which is the `!started` case.
const SpreadIndexFold = struct {
    /// Has any part been folded in? While false there is nothing to filter,
    /// and the literal's own computed-key indexes stand unchanged.
    started: bool = false,
    /// Does EVERY part so far declare this index kind? Once false the kind is
    /// gone: `getUnionIndexInfos` never re-seeds.
    str_all: bool = true,
    num_all: bool = true,
    /// One value type per part, unioned into the result. Meaningful only
    /// while the matching `*_all` still holds.
    str: std.ArrayList(TypeId) = .empty,
    num: std.ArrayList(TypeId) = .empty,

    fn deinit(f: *SpreadIndexFold, c: *Checker) void {
        f.str.deinit(c.scratch());
        f.num.deinit(c.scratch());
    }

    /// Fold one part in. `str`/`num` are its own index value types, `0` where
    /// the part declares no index of that kind.
    fn part(f: *SpreadIndexFold, c: *Checker, str: TypeId, num: TypeId) Error!void {
        f.started = true;
        if (str == 0) f.str_all = false else if (f.str_all) try f.str.append(c.scratch(), str);
        if (num == 0) f.num_all = false else if (f.num_all) try f.num.append(c.scratch(), num);
    }

    fn result(f: *const SpreadIndexFold, c: *Checker, comptime numeric: bool) Error!TypeId {
        const live = if (numeric) f.num_all else f.str_all;
        const vals = if (numeric) f.num.items else f.str.items;
        if (!live or vals.len == 0) return 0;
        return c.ts.makeUnion(c.scratch(), vals);
    }
};

/// Fold the run of own properties accumulated since the last spread in as one
/// part — tsc's `spread = getSpreadType(spread, createObjectLiteralType())`,
/// which `checkObjectLiteral` runs before each spread and once at the end,
/// guarded on `propertiesArray.length > 0`. The run's own index signatures
/// are whatever its computed keys contributed.
fn flushOwnIndexPart(
    c: *Checker,
    fold: *SpreadIndexFold,
    pending: *bool,
    str_vals: *std.ArrayList(TypeId),
    num_vals: *std.ArrayList(TypeId),
) Error!void {
    if (!pending.*) return;
    pending.* = false;
    const s = if (str_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), str_vals.items) else 0;
    const n = if (num_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), num_vals.items) else 0;
    str_vals.clearRetainingCapacity();
    num_vals.clearRetainingCapacity();
    try fold.part(c, s, n);
}

/// Fold a spread SOURCE's gathered index signatures in as one part. A source
/// can contribute several (an intersection is walked constituent by
/// constituent), and they are one operand of the spread between them, so they
/// union into a single part rather than filtering each other.
fn foldSpreadPart(
    c: *Checker,
    fold: *SpreadIndexFold,
    str_vals: *std.ArrayList(TypeId),
    num_vals: *std.ArrayList(TypeId),
) Error!void {
    const s = if (str_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), str_vals.items) else 0;
    const n = if (num_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), num_vals.items) else 0;
    try fold.part(c, s, n);
}

/// One constituent of an object literal's type. `dist` names the spread
/// elements whose source types are replaced for this constituent (see
/// `checkObjectLiteral`); it is empty for an undistributed literal.
fn objectLiteralType(c: *Checker, node: Node, ctx: TypeId, dist: []const Subst) Error!TypeId {
    var rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
    if (rctx != types.no_type) rctx = try resolveCtxTypeParams(c, node, rctx);
    if (rctx != types.no_type and c.ts.kind(rctx) == .union_type) {
        rctx = try discriminate_ctx.byObjectMembers(c, node, rctx);
    }
    // The `ThisType<T>` in scope for this literal's function members: its own
    // contextual type's marker, else the one an enclosing literal handed down.
    // Cleared for the rest of this frame so only the property VALUES that are
    // themselves object literals see it (`Checker.ctx_this_marker`); the
    // caller's value is restored on the way out, because a distributed spread
    // walks the same literal once per constituent.
    const inherited_marker = c.ctx_this_marker;
    defer c.ctx_this_marker = inherited_marker;
    c.ctx_this_marker = types.no_type;
    const this_marker: TypeId = if (rctx == types.no_type)
        inherited_marker
    else
        (try thisTypeMarker(c, rctx)) orelse inherited_marker;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer prop_index.deinit(c.scratch());
    // Accessor keys, to type a get/set pair as one property and mark a
    // get-only accessor read-only.
    var getter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer getter_keys.deinit(c.scratch());
    var setter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer setter_keys.deinit(c.scratch());
    // Value types of computed keys that widen to `string`/`number` — they
    // become the object's index signatures (`{ [layer]: v }` → `{ [x:
    // string]: v }`), matching tsc. Multiple such keys union their values.
    var str_index_vals: std.ArrayList(TypeId) = .empty;
    defer str_index_vals.deinit(c.scratch());
    var num_index_vals: std.ArrayList(TypeId) = .empty;
    defer num_index_vals.deinit(c.scratch());
    // …and, once the literal spreads, one PART of `getSpreadType`'s fold (see
    // `SpreadIndexFold`): the two lists above accumulate the run of own
    // properties since the last spread, and `idx_fold` folds each completed
    // run and each spread source in turn.
    var idx_fold: SpreadIndexFold = .{};
    defer idx_fold.deinit(c);
    // Is there an own-property run to flush? tsc's `propertiesArray.length >
    // 0` guard on the flush, so a spread that directly follows another one
    // contributes no empty part between them.
    var own_pending = false;
    var saw_spread = false;
    // Spreading an `any`-typed source poisons the whole object literal to
    // `any` (tsc: `{ ...anyVal, x }` has type `any`), so member access on
    // it is unchecked. Tracked here and short-circuited after the loop.
    var spread_any = false;
    // Spreading a bare type parameter (`{ ...data, extra }` with `data: T`)
    // keeps `T` as a spread member in tsc's spread type — the whole literal
    // is then assignable back to `T`. ztsc has no props to fold for a
    // type-param source, so it is retained here and the result becomes
    // `T & { own props }` (an intersection is assignable to any member, so
    // `→ T` holds), matching tsc's generic-spread behavior.
    var generic_spreads: std.ArrayList(TypeId) = .empty;
    defer generic_spreads.deinit(c.scratch());

    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const pd = c.tree.nodeData(prop);
        // Every non-spread member joins tsc's `propertiesArray`, and so the
        // own-property part waiting to be folded (see `SpreadIndexFold`).
        if (c.nodeTag(prop) != .spread_element) own_pending = true;
        // tsc's `getContainingObjectLiteral`: a function-like written as an
        // object-literal MEMBER — a `m() {}` shorthand (whose body the parser
        // hangs off it as a `function_expr`) or a `function () {}` property
        // VALUE — takes `this` from the literal, so a `this` inside it is never
        // TS2683. Deliberately not through parentheses: tsc asks whether the
        // function expression's PARENT is the property assignment, which
        // `{ a: (function () {}) }` fails.
        switch (c.nodeTag(prop)) {
            .object_method => try markThisBound(c, pd.rhs),
            .object_property => {
                if (pd.rhs != null_node and c.nodeTag(pd.rhs) == .function_expr) try markThisBound(c, pd.rhs);
            },
            else => {},
        }
        switch (c.nodeTag(prop)) {
            .object_property => {
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                    const key_expr = c.tree.nodeData(pd.lhs).lhs;
                    const kt = try c.checkExprCached(key_expr, types.no_type);
                    // TS2464. (wave-8 D: one flagged call into `computed_key.zig`.)
                    try computed_key.report(c, pd.lhs, kt);
                    const rk = try c.resolveStructural(kt);
                    const key_kind = c.ts.kind(rk);
                    // A key of the WIDE `number` type is dynamic — it names no
                    // one member, so it contributes a number index signature.
                    // A numeric LITERAL key is late-bound exactly like a string
                    // literal one: tsc names `[0]` the member `"0"`, so
                    // `{ [an]: 5 }` with `const an = 0` satisfies
                    // `{ 0: number }` instead of being a bare index signature
                    // that is missing it (`objectLiteralEnumPropertyNames`).
                    // Everything else late-bindable — a well-known symbol, a
                    // `unique symbol` const, a string literal, a qualified enum
                    // member — names a real property too.
                    const named: ?Atom = switch (key_kind) {
                        .number => null,
                        else => try computed_key.lateBoundName(c, key_expr, kt),
                    };
                    if (named) |key| {
                        const pctx = try c.ctxPropType(rctx, ctx, key);
                        var vt = try checkPropValue(c, pd.rhs, pctx, this_marker);
                        if (c.const_ctx) {
                            vt = try c.ts.regularLiteral(vt);
                        } else if (!try propCtxKeepsLiteral(c, rctx, ctx, key, vt)) vt = try c.widenPropValue(vt);
                        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                        continue;
                    }
                    // A DYNAMIC computed key (`{ [expr]: v }`): a `string`- or
                    // `number`-widening key contributes an index signature and
                    // anything else contributes nothing. The value is still
                    // contextually typed by the target's matching index (so
                    // `value: STATUS` under a `Record<…>` context keeps its
                    // literal instead of widening).
                    const pctx: TypeId = if (rctx == types.no_type) types.no_type else switch (key_kind) {
                        .string, .template_literal_type, .string_mapping => try ctxIndexType(c, rctx, false),
                        .number, .number_literal, .number_literal_fresh => try ctxIndexType(c, rctx, true),
                        else => types.no_type,
                    };
                    var vt = try checkPropValue(c, pd.rhs, pctx, this_marker);
                    if (c.const_ctx) {
                        vt = try c.ts.regularLiteral(vt);
                    } else if (!try keepLiteral(c, vt, pctx)) vt = try c.widenPropValue(vt);
                    switch (key_kind) {
                        .string, .template_literal_type, .string_mapping => try str_index_vals.append(c.scratch(), vt),
                        .number, .number_literal, .number_literal_fresh => try num_index_vals.append(c.scratch(), vt),
                        else => {}, // symbol/unknown/other: no static member
                    }
                    continue;
                }
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                const pctx = try c.ctxPropType(rctx, ctx, key);
                var vt = try checkPropValue(c, pd.rhs, pctx, this_marker);
                if (c.const_ctx) {
                    vt = try c.ts.regularLiteral(vt);
                } else if (!try propCtxKeepsLiteral(c, rctx, ctx, key, vt)) vt = try c.widenPropValue(vt);
                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
            },
            .object_shorthand => {
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                var vt = try c.checkExprCached(pd.lhs, types.no_type);
                if (c.const_ctx) {
                    vt = try c.ts.regularLiteral(vt);
                } else if (!try propCtxKeepsLiteral(c, rctx, ctx, key, vt)) vt = try c.widenPropValue(vt);
                if (pd.rhs != 0) _ = try c.checkExprCached(pd.rhs, types.no_type);
                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
            },
            .object_method => {
                // `this` inside an object-literal method is the literal's
                // own `this`, never the enclosing frame's. tsc
                // (`getContextualThisParameterType`): with a contextual
                // type for the literal, `this` is that contextual type —
                // which is what makes `{ perform() { this.checked!(…) } }`
                // passed to `register(action: Action)` legal, `checked`
                // being a member of `Action`. With no contextual type it is
                // the literal's own type, which is only known after this
                // walk; that case falls back to `any` (an under-report:
                // `{ m() { return this.nope; } }` goes unreported) rather
                // than to the ambient `this`, which would be wrong.
                //
                // The contextual type is taken NON-NULLABLE, which is tsc's
                // own `getWidenedType(getNonNullableType(contextualType))`. A
                // nullable annotation is a statement about the VARIABLE, not
                // about the literal being written into it: every method of
                // `let p: Point | null = { x: 10, moveBy() { this.x += dx } }`
                // runs on a real `Point`, and reading `this.x` through the
                // union reported "possibly null" at every member access
                // (`thisTypeInObjectLiterals2`, 12 keys across the `| null`,
                // `| undefined` and `| null | undefined` spellings).
                const saved_this = c.this_type;
                defer c.this_type = saved_this;
                c.this_type = try objectLiteralThis(c, rctx, this_marker);
                // A SYMBOL-keyed method or accessor shorthand
                // (`{ [Symbol.toStringTag]() {…} }`,
                // `{ set [Symbol.toPrimitive](p) {…} }`) declares a real,
                // nominally-keyed member — the same one the `key: value` form
                // above declares, so it takes the same key and then the same
                // accessor/method path. Contributing nothing at all left
                // `i[Symbol.toStringTag]()` reading a property the literal
                // was known to have (`symbolProperty18`).
                //
                // Only the SYNTACTIC recognizer runs here. A method's computed
                // key is not an expression tsc checks — `var s: symbol; ({ [s]:
                // 0, [s]() {} })` is "used before being assigned" at the first
                // key and not at the second (`symbolProperty1`) — so asking for
                // the key's TYPE, which is what the general `unique symbol`
                // path needs, would report where tsc is silent. A
                // const-`unique symbol`-keyed method therefore still declares
                // no member, exactly as before: an under-report, not a new one.
                var key: Atom = undefined;
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                    const wk = c.wellKnownKeyOfExpr(c.tree.nodeData(pd.lhs).lhs) orelse {
                        // Any other computed key stays dynamic: the body is
                        // still checked, and no static member is declared —
                        // but tsc still checks the key EXPRESSION, which is
                        // where a TS2464 (and any diagnostic the key earns in
                        // its own right) comes from.
                        //
                        // Checked in the METHOD's scope, because tsc's
                        // `getControlFlowContainer` stops at any function-like
                        // and a method is one: the key's identifiers are
                        // therefore OUTER variables to the definite-assignment
                        // rule and assume initialization, where a plain
                        // property's are not. Measured: `var s: string;
                        // ({ [s]: 0 })` reports TS2454 and `({ [s]() {} })`
                        // reports nothing (`symbolProperty1.ts` answers only
                        // its property key; `computedPropertyNames10`, all
                        // methods, answers nothing at all).
                        // (wave-8 D: one flagged call into `computed_key.zig`.)
                        const kt = blk: {
                            const saved_scope = c.cur_scope;
                            defer c.cur_scope = saved_scope;
                            if (try c.scopeOf(pd.rhs)) |s| c.cur_scope = s;
                            // `on_class = false`: an OBJECT LITERAL's computed
                            // name is not a `this` container (tsc's
                            // `getThisContainer` steps over it), so a `this`
                            // inside it resolves outward and is not TS2465.
                            break :blk try computed_key.checkComputedName(c, pd.lhs, false);
                        };
                        // tsc's `getContextualTypeForObjectLiteralElement`
                        // ends with the arm for a member whose name is NOT
                        // bindable: `mapType(type, t =>
                        // findApplicableIndexInfo(getIndexInfosOfStructuredType(t),
                        // getLiteralTypeFromPropertyName(element.name))?.type)`
                        // — the contextual type's INDEX SIGNATURE that this
                        // key applies to, exactly as the `key: value` form
                        // above uses it. `var o: I = { ["" + 0](y) {…} }` with
                        // `I`'s `[s: string]: (x: string) => number` is what
                        // gives `y` its type instead of a TS7006.
                        //
                        // Gated on the literal HAVING a contextual type, which
                        // is also why reading the key's type here reports
                        // nothing tsc does not: `getApparentTypeOfContextualType`
                        // returns undefined without one, so tsc never reaches
                        // `getLiteralTypeFromPropertyName` and never evaluates
                        // a method's key at all (the measurement in the note
                        // above).
                        const mctx: TypeId = if (rctx == types.no_type) types.no_type else switch (c.ts.kind(try c.resolveStructural(kt))) {
                            .string, .string_literal, .template_literal_type, .string_mapping => try ctxIndexType(c, rctx, false),
                            .number, .number_literal, .number_literal_fresh => try ctxIndexType(c, rctx, true),
                            else => types.no_type,
                        };
                        _ = try c.checkExprCached(pd.rhs, mctx);
                        continue;
                    };
                    key = try c.atom(wk);
                } else {
                    key = try c.memberAtom(c.tree.nodeMainToken(prop));
                }
                // Accessor shorthand (`get x() {}` / `set x(v) {}`): the
                // property type is the getter's return type (or the
                // setter's parameter type when there's no getter). A
                // get-only accessor is read-only.
                const fproto = c.tree.extraData(ast.FnProto, c.tree.nodeData(pd.rhs).lhs);
                const is_get = fproto.flags & ast.Flags.get != 0;
                const is_set = fproto.flags & ast.Flags.set != 0;
                if (is_get or is_set) {
                    const sig = try c.checkExprCached(pd.rhs, types.no_type);
                    if (is_get) {
                        try getter_keys.put(c.scratch(), key, {});
                        const gt = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.any_type;
                        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = gt });
                    } else {
                        try setter_keys.put(c.scratch(), key, {});
                        // A getter, if present, wins the property type.
                        if (!getter_keys.contains(key)) {
                            const st = if (c.ts.kind(sig) == .function and c.ts.fnParamCount(sig) > 0)
                                c.ts.fnParam(sig, 0).ty
                            else
                                types.any_type;
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = st });
                        }
                    }
                    continue;
                }
                const pctx = try c.ctxPropType(rctx, ctx, key);
                const mt = try c.checkExprCached(pd.rhs, pctx);
                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = mt });
            },
            .spread_element => {
                const raw = try c.checkExprCached(pd.lhs, types.no_type);
                var src = raw;
                for (dist) |d| {
                    if (d.node == prop) {
                        src = d.ty;
                        break;
                    }
                }
                const st = try c.resolveStructural(src);
                if (c.ts.kind(st) == .any or c.ts.kind(st) == .err) spread_any = true;
                // The own-property run this spread ends is a part of
                // `getSpreadType`'s fold, and the spread's source is the next
                // one (see `SpreadIndexFold`). The source's index signatures
                // are gathered into lists of their own so they can be folded
                // as ONE part rather than merged into the running union.
                saw_spread = true;
                try flushOwnIndexPart(c, &idx_fold, &own_pending, &str_index_vals, &num_index_vals);
                var sp_str: std.ArrayList(TypeId) = .empty;
                defer sp_str.deinit(c.scratch());
                var sp_num: std.ArrayList(TypeId) = .empty;
                defer sp_num.deinit(c.scratch());
                // tsc's `getSpreadType`: when either side `isGenericObject
                // Type` the spread is an INTERSECTION, not a flattened
                // object — the generic half has no members to copy yet, and
                // keeping its identity is what makes `{ ...updates, x }`
                // assignable back to `updates`'s own (still deferred) type.
                // A bare type parameter was already handled this way; a
                // deferred mapped type / indexed access / conditional
                // contributed NOTHING at all, so the literal lost every
                // property the spread carried.
                switch (c.ts.kind(st)) {
                    // A generic source is folded as no part at all: tsc leaves
                    // `getUnionIndexInfos` behind entirely here and answers
                    // `getIntersectionType([left, right])`, so the left half
                    // keeps whatever index signatures it had.
                    .type_param, .mapped, .index_access, .conditional => {
                        try generic_spreads.append(c.scratch(), st);
                        continue;
                    },
                    // An INTERSECTION that mixes concrete constituents with
                    // generic ones (`{ [ORIG]?: string } & { selected?: true }
                    // & Partial<Record<T, any>>`) is tsc's intersection
                    // branch of `getSpreadType`: the concrete half is
                    // flattened into the literal and the generic half is
                    // kept by identity. Flattening the whole thing dropped
                    // the deferred constituent, so `{ ...el, id }` was no
                    // longer assignable to `typeof el & { id: string }`.
                    .intersection => {
                        var any_generic = false;
                        for (try c.memberList(st)) |m| {
                            const rm = try c.resolveStructural(m);
                            switch (c.ts.kind(rm)) {
                                .type_param, .mapped, .index_access, .conditional => {
                                    try generic_spreads.append(c.scratch(), rm);
                                    any_generic = true;
                                },
                                else => {},
                            }
                        }
                        if (any_generic) {
                            // The concrete constituents are ONE part between
                            // them: they are one operand of tsc's spread.
                            for (try c.memberList(st)) |m| {
                                const rm = try c.resolveStructural(m);
                                switch (c.ts.kind(rm)) {
                                    .type_param, .mapped, .index_access, .conditional => {},
                                    else => try c.gatherSpreadProps(rm, &props, &prop_index, &sp_str, &sp_num),
                                }
                            }
                            try foldSpreadPart(c, &idx_fold, &sp_str, &sp_num);
                            continue;
                        }
                    },
                    else => {},
                }
                try c.gatherSpreadProps(st, &props, &prop_index, &sp_str, &sp_num);
                // A nullish or primitive source is `getSpreadType`'s `return
                // left`: not a part of the fold at all, so it neither supplies
                // an index signature nor filters one out. Those are exactly
                // the sources `gatherSpreadProps` walks nothing for.
                switch (c.ts.kind(st)) {
                    .object, .intersection, .union_type => try foldSpreadPart(c, &idx_fold, &sp_str, &sp_num),
                    else => {},
                }
            },
            else => _ = try c.checkExprCached(prop, types.no_type),
        }
    }
    if (spread_any) return types.any_type;
    // Get-only accessors are read-only properties.
    var git = getter_keys.keyIterator();
    while (git.next()) |k| {
        if (setter_keys.contains(k.*)) continue;
        if (prop_index.get(k.*)) |idx| props.items[idx].flags |= types.prop_flag_readonly;
    }
    // `{...} as const`: every property is readonly.
    if (c.const_ctx) {
        for (props.items) |*p| p.flags |= types.prop_flag_readonly;
    }
    // A literal that SPREADS takes its index signatures from the fold — every
    // part has to declare one (`SpreadIndexFold`). One that does not spread
    // never reaches `getSpreadType` and keeps whatever its computed keys gave
    // it.
    if (saw_spread) try flushOwnIndexPart(c, &idx_fold, &own_pending, &str_index_vals, &num_index_vals);
    const sidx = if (saw_spread)
        try idx_fold.result(c, false)
    else if (str_index_vals.items.len > 0)
        try c.ts.makeUnion(c.scratch(), str_index_vals.items)
    else
        0;
    const nidx = if (saw_spread)
        try idx_fold.result(c, true)
    else if (num_index_vals.items.len > 0)
        try c.ts.makeUnion(c.scratch(), num_index_vals.items)
    else
        0;
    const obj = try c.ts.makeObject(props.items, sidx, nidx, types.obj_flag_fresh | types.obj_flag_literal_origin);
    // A type-parameter spread (`{ ...data, extra }`, `data: T`) yields
    // `T & { extra }` so the literal stays assignable to `T`.
    if (generic_spreads.items.len > 0) {
        try generic_spreads.append(c.scratch(), obj);
        return c.ts.makeIntersection(c.scratch(), generic_spreads.items);
    }
    return obj;
}

/// The type of a property that `propOfType` cannot see because it lives in
/// only SOME constituents of a union (or of a union nested in an
/// intersection — `Base & (VariantA | VariantB)`, the discriminated-props
/// idiom): the union of the constituents that do declare it. Null for
/// every other shape, so a target `propOfType` already handles keeps the
/// exact behaviour it had.
pub fn unionNestedPropType(c: *Checker, rt: TypeId, key: Atom) Error!?TypeId {
    switch (c.ts.kind(rt)) {
        .intersection, .union_type => {},
        else => return null,
    }
    const t = try c.ctxPropType(rt, rt, key);
    return if (t == types.no_type) null else t;
}

/// Contextual INDEX-SIGNATURE type for a computed-key member — tsc's
/// `getIndexTypeOfContextualType`, which maps over the contextual type
/// rather than requiring one object.
///
/// Only a bare `.object` used to be consulted, and an *optional*
/// contextual property offers `{ [id: string]: true } | undefined`, so
/// `{ [k]: true }` written under one got no contextual type at all and its
/// value widened to `boolean`. That is a confluence hazard, not just a
/// precision loss: the same literal is typed once with the declared
/// contextual type and again with the inferred one (the argument re-check
/// of a generic call), and only the second pass saw the union — so the two
/// passes disagreed and the later one clobbered the first's cached node
/// type, surfacing as a whole-function TS2322 whose two printed types were
/// identical but for this one index signature.
fn ctxIndexType(c: *Checker, rctx: TypeId, want_number: bool) Error!TypeId {
    switch (c.ts.kind(rctx)) {
        .object => {
            const idx = if (want_number) c.ts.objectNumberIndex(rctx) else c.ts.objectStringIndex(rctx);
            return if (idx != 0) idx else types.no_type;
        },
        // A constituent with no index signature contributes nothing (tsc's
        // `mapType` drops it), so `T | undefined` answers `T`'s index.
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const it = try ctxIndexType(c, try c.resolveStructural(m), want_number);
                if (it != types.no_type) try parts.append(c.scratch(), it);
            }
            if (parts.items.len == 0) return types.no_type;
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        // First constituent that carries one, matching how the relation
        // reads an intersection's index signatures.
        .intersection => {
            for (try c.memberList(rctx)) |m| {
                const it = try ctxIndexType(c, try c.resolveStructural(m), want_number);
                if (it != types.no_type) return it;
            }
            return types.no_type;
        },
        else => return types.no_type,
    }
}

/// Contextual type for property `key` of an object literal typed by
/// `ctx` (unions: union of the property across constituents).
/// `keepLiteral` for an object-literal PROPERTY whose contextual type comes
/// from `ctxPropType`, asked of the UN-REDUCED union tsc would have built —
/// the object-literal twin of `elemCtxKeepsLiteral`, and the same mechanic for
/// the same reason: `getTypeOfPropertyOfContextualType` maps over the union
/// with `UnionReduction.None`, so the `AnyOrUnknown` collapse never runs and
/// `isLiteralOfContextualType` still finds a literal constituent beside an
/// `any` one.
///
/// `f(p: { a: "x" } | I)` where `I` has `[k: string]: any` is the live shape:
/// property `a` contributes `"x"` from one constituent and `any` from the
/// other's index signature, reduced to `any`, so `f({ a: "x" })` widened to
/// `{ a: string }` and matched neither arm — a false TS2345 (and a false
/// TS2322 for the same literal nested in an array).
///
/// Only the union arm can differ: for every other kind this is exactly
/// `keepLiteral(cand, ctxPropType(…))`, which is what it calls.
fn propCtxKeepsLiteral(c: *Checker, rctx: TypeId, ctx: TypeId, key: Atom, cand: TypeId) Error!bool {
    if (c.ts.kind(rctx) == .union_type) {
        for (try c.memberList(rctx)) |m| {
            if (try propCtxKeepsLiteral(c, try c.resolveStructural(m), ctx, key, cand)) return true;
        }
        return false;
    }
    return keepLiteral(c, cand, try ctxPropType(c, rctx, ctx, key));
}

pub fn ctxPropType(c: *Checker, rctx: TypeId, ctx: TypeId, key: Atom) Error!TypeId {
    if (ctx == types.no_type) return types.no_type;
    switch (c.ts.kind(rctx)) {
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                // Recurse (not a bare `propOfType`) so a union member that
                // is itself an intersection — an *optional* parameter typed
                // `RegisterOptions | undefined` where RegisterOptions is
                // `Partial<C> & (A | B | C)` — routes through the
                // intersection arm below and finds the union-nested prop.
                const pt = try c.ctxPropType(try c.resolveStructural(m), ctx, key);
                if (pt != types.no_type) try parts.append(c.scratch(), pt);
            }
            if (parts.items.len == 0) return types.no_type;
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        // A still-generic mapped type (`c: { [K in keyof T]: T[K] }`) has
        // no members to look up, so an object literal written for it got no
        // contextual type at all: its property values widened (a fresh
        // `true` to `boolean`, a fresh `'x'` to the whole union) and a
        // callback value's parameters fell to implicit `any` (TS7006).
        // tsc's `getTypeOfPropertyOfContextualType` answers with the value
        // template, the key bound to this property's name
        // (`substituteIndexedMappedType`), so property `a` of the map above
        // is contextually `T['a']`.
        // A deferred type variable offers the contextual members of its
        // APPARENT type — tsc's `getApparentTypeOfContextualType` maps
        // `getApparentType` over the contextual type. This is the other half
        // of the mapped arm below: property `a` of `{ [K in keyof T]: T[K] }`
        // is contextually `T['a']`, and only through the base constraint does
        // that offer `{ b: boolean }` to the nested literal.
        .index_access, .conditional => {
            const ap = try c.transitiveBaseConstraint(rctx);
            if (ap == rctx or ap == types.no_type) return types.no_type;
            return c.ctxPropType(try c.resolveStructural(ap), ctx, key);
        },
        .mapped => {
            // An `as` clause remaps the key, so the property name does not
            // identify the template instance — not modelled (as elsewhere).
            if (c.ts.mappedAs(rctx) != 0) return types.no_type;
            const key_lit = try c.ts.makeStringLiteral(key, false);
            // tsc's guard: the name must satisfy the map's key set, taken
            // through its base constraint (`keyof T` for `T extends
            // Record<string, …>` bottoms out at `string | number`).
            const con = try c.transitiveBaseConstraint(c.ts.mappedConstraint(rctx));
            if (con != types.no_type and !try c.isAssignable(key_lit, con)) return types.no_type;
            return c.substMappedKey(
                c.ts.mappedValue(rctx),
                c.ts.mappedParamId(c.ts.mappedKeyParam(rctx)),
                key_lit,
            );
        },
        // A contextual property inside an intersection (`Partial<C> & (A |
        // B | C)`) may live in a *union* member. `propOfType` has no union
        // arm, so the intersection lookup below would miss it and the
        // property would widen (react-hook-form's RegisterOptions:
        // `valueAsNumber?: false | true`, so a fresh `valueAsNumber: true`
        // widened to `boolean` and matched no union arm → TS2345). Recurse
        // per member — a union member is handled by the arm above — and
        // intersect the per-member contextual types, mirroring tsc's
        // `getTypeOfPropertyOfContextualType` over an intersection.
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const pt = try c.ctxPropType(try c.resolveStructural(m), ctx, key);
                if (pt != types.no_type) try parts.append(c.scratch(), pt);
            }
            if (parts.items.len == 0) return types.no_type;
            if (parts.items.len == 1) return parts.items[0];
            return c.ts.makeIntersection(c.scratch(), parts.items);
        },
        else => {
            // `ctxPropOfType`, not `propOfType`: tsc looks a contextual
            // property up with `skipObjectFunctionPropertyAugment`, so the
            // members `Function` and `Object` lend every value never become
            // one — see `ctxPropOfType`.
            if (try c.ctxPropOfType(rctx, key)) |p| return p.ty;
            return types.no_type;
        },
    }
}

/// Does `node` denote an optional chain — i.e. does its object/callee
/// spine contain a `?.` link (without crossing parentheses, `!`, or `new`,
/// which all break the chain)? A member/element/call access whose object is
/// such a chain *continues* it: it short-circuits on a nullish object
/// rather than erroring, and propagates `undefined` to the chain's result
/// (tsc's `OptionalChain` node flag / optional-type marker).
pub fn isOptionalChain(c: *Checker, node: Node) bool {
    return switch (c.nodeTag(node)) {
        .optional_member_expr, .optional_index_expr, .optional_call => true,
        .member_expr, .index_expr, .call_expr, .call_expr_targs => c.isOptionalChain(c.tree.nodeData(node).lhs),
        else => false,
    };
}

/// One link of an optional chain: the link's type WITHOUT the chain's
/// short-circuit `undefined`, plus whether this link — or an earlier one in
/// its object spine — short-circuited on a nullish object. The outermost
/// link's caller is the one that folds `undefined` back in.
pub const ChainLink = struct { ty: TypeId, chained: bool };

/// Type of a chain link's object/callee, WITHOUT the chain's short-circuit
/// `undefined` (that is tracked in the link's `chained`). Only called when
/// `node` is itself an optional chain, so downstream declared-nullish still
/// reports.
pub fn chainObjType(c: *Checker, node: Node) Error!ChainLink {
    return switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr => memberChainInner(c, node, types.no_type),
        .index_expr, .optional_index_expr => indexChainInner(c, node, true, types.no_type),
        .call_expr, .call_expr_targs, .optional_call => c.checkCallExprInner(node, false, types.no_type),
        else => .{ .ty = try c.checkExprCached(node, types.no_type), .chained = false },
    };
}

fn checkMemberExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const link = try memberChainInner(c, node, ctx);
    if (link.chained) return c.makeUnion2(link.ty, types.undefined_type);
    return link.ty;
}

/// Announce `ref` as a CONSTRAINT POSITION for the duration of its own check
/// (`index_expr` = the element-access exception's index, `null_node` for a
/// property access or callee). Restores the previous announcement, so a nested
/// access inside `ref`'s own subtree makes its own — see `ConstraintPos`.
fn enterConstraintPos(c: *Checker, ref: Node, index_expr: Node) narrowable.ConstraintPos {
    const saved = c.constraint_pos;
    c.constraint_pos = .{ .node = c.nodeKey(ref), .index_expr = index_expr };
    return saved;
}

/// Property access, treated as a link in a (possibly single-element)
/// optional chain. Returns the property type WITHOUT the chain's
/// short-circuit `undefined`, and `chained` when this `?.` link — or an
/// earlier one in the object spine — short-circuits on a nullish object. A
/// non-`?.` continuation whose object is *declared* nullish still reports
/// TS2532/18047-9 via `checkNonNullType` (the marker distinguishes the
/// chain's own undefined from an inherently-nullable intermediate).
/// The type of a `super` RECEIVER — the object half of `super.x` — or null
/// when `recv` is not `super` (or the enclosing receiver is not a class
/// instance, in which case the old `any` stands).
///
/// tsc's `checkSuperExpression` answers `getTypeWithThisArgument(baseClass
/// Type, classType.thisType)` here: the base class's INSTANCE type, which is
/// what makes `super.foo({ method(p) {…} })` contextually type `p` from the
/// base's parameter (`superCallParameterContextualTyping3`) instead of
/// leaving it an implicit any.
///
/// A super CALL is deliberately NOT this, which is why the `.super_expr` arm
/// of `checkExpr` still answers `any`: tsc's `resolveCallExpression` never
/// types `super` as a value in call position at all, resolving instead against
/// the base's CONSTRUCT signatures (`calls.superCtorSigs`). Typing the keyword
/// itself would hand `super(…)` a non-callable object type on every shape that
/// path declines.
///
/// Null for a STATIC member too: `super` there is the base's static side,
/// which ztsc does not model — `c.this_type` is a `.class_value`, not a `.ref`.
fn superReceiverType(c: *Checker, recv: Node) Error!?TypeId {
    if (c.nodeTag(recv) != .super_expr) return null;
    const t = c.this_type;
    if (t == 0) return null;
    // Inside a method the receiver is the POLYMORPHIC `this` (see
    // `signatureOfProtoCtx`); the class it stands for is what has the base.
    const inst = if (c.ts.kind(t) == .this_type) c.ts.thisTypeInstance(t) else t;
    if (c.ts.kind(inst) != .ref) return null;
    return c.baseClassRef(c.ts.refSymbol(inst));
}

fn memberChainInner(c: *Checker, node: Node, ctx: TypeId) Error!ChainLink {
    const d = c.tree.nodeData(node);
    const own_optional = c.nodeTag(node) == .optional_member_expr;
    var chained = false;
    var obj_t = obj: {
        // A property-access receiver is in a constraint position (its apparent
        // type is what the lookup below uses either way).
        const saved = enterConstraintPos(c, d.lhs, null_node);
        defer c.constraint_pos = saved;
        if (c.isOptionalChain(d.lhs)) {
            const link = try c.chainObjType(d.lhs);
            if (link.chained) chained = true;
            break :obj link.ty;
        }
        if (try superReceiverType(c, d.lhs)) |st| break :obj st;
        const base = try c.checkExprCached(d.lhs, types.no_type);
        break :obj try narrowThisReceiver(c, d.lhs, node, base);
    };
    const name_tok: TokenIndex = d.rhs;
    const name = try c.memberAtom(name_tok);
    if (own_optional) {
        if (c.containsNullish(obj_t) or c.ts.kind(obj_t) == .null or c.ts.kind(obj_t) == .undefined) {
            chained = true;
        }
        obj_t = try c.nonNullableChain(obj_t);
    } else {
        // `checkNonNullExpression`'s unknown arm, ahead of its nullish one:
        // `u.foo` is TS18046 at the RECEIVER, not TS2339 at the name. Only
        // the non-optional spelling — `u?.foo` reaches
        // `getOptionalExpressionType` first, which answers `{}` for `unknown`,
        // so tsc reports the missing property on `{}` there (oracle-verified).
        if (c.nodeTag(d.lhs) != .super_expr and try reportUnknownOperand(c, obj_t, d.lhs)) {
            return .{ .ty = types.error_type, .chained = chained };
        }
        obj_t = try checkNullishOperand(c, obj_t, d.lhs);
    }
    // A compound assignment's target is re-read as an expression after
    // `checkAssignmentTarget` has already judged it as a WRITE; tsc runs one
    // accessibility check per access node, so the re-read must not run a
    // second one in the opposite direction (`accessibility.Dir`).
    var site: accessibility.Site = .{
        .dir = if (c.write_target_node != 0 and c.nodeKey(node) == c.write_target_node) .none else .read,
        .recv_node = d.lhs,
    };
    // `super.x` on a base-class FIELD is TS2855, and it is a question about the
    // DECLARATION rather than about the receiver's type. `.none` is the
    // compound-assignment re-read, whose write half already ran this (see
    // `checkAssignmentTarget`). Reporting it is tsc's early return out of
    // `checkPropertyAccessibility`, so the `private`/`protected` rules are
    // skipped for this access — which `.none` is exactly the spelling of.
    if (c.nodeTag(d.lhs) == .super_expr and site.dir != .none) {
        if (try accessibility.checkSuperField(c, name, name_tok)) site.dir = .none;
    }
    var pt = try propertyTypeOf(c, obj_t, name, name_tok, site);
    // A `#name` is resolved lexically before it is looked up, so an access
    // from outside the declaring class is TS18013 even though the member
    // table answered (`accessibility.checkPrivateName`). Asked only once the
    // lookup HAS answered: a `#name` no type carries keeps its TS2339.
    if (c.tree.tokens.tag(name_tok) == .private_identifier and pt != types.error_type) {
        if (try accessibility.checkPrivateName(c, obj_t, name, name_tok, site)) {
            return .{ .ty = types.error_type, .chained = chained };
        }
    }
    // tsc's `getNarrowableTypeForReference`, the property-access arm: this
    // access is itself a reference, so a union-constrained type variable it
    // reads enters the flow walk as its constraint (see `narrowable.zig`).
    pt = try c.narrowableRefType(node, pt, ctx);
    // Property-path narrowing: peel the whole access spine into a member
    // path (`x.p`, `this.p`, `x.a.b`, …) capped at `max_deep_ref_depth`.
    if (try c.buildRefKey(node)) |key| {
        pt = try c.flowTypeOfKey(node, key, pt);
    }
    return .{ .ty = pt, .chained = chained };
}

/// tsc's `checkNonNullType` (`checkNonNullTypeWithReporter` +
/// `reportObjectPossiblyNullOrUndefinedError`): the gate every position that
/// may not hold `null`/`undefined` runs its operand through — a non-optional
/// property-access or element-access receiver, an arithmetic / relational /
/// `in` operand, a `++`/`--` operand. It reports the diagnostic tsc picks for
/// the SYNTACTIC shape of the operand and returns the non-nullable remainder
/// to continue checking with:
///
///   * the `null` keyword, or the identifier `undefined`
///       → TS18050 "The value 'null' / 'undefined' cannot be used here."
///   * any other entity name (`a`, `a.b`, `a?.b`)
///       → TS18047/18048/18049 "'a' is possibly 'null'/'undefined'/…"
///   * anything else (a parenthesized expression, a call, `this.x`, …)
///       → TS2531/2532/2533 "Object is possibly 'null'/'undefined'/…"
///
/// TS18050 is a test on the NODE, not on the type: `(null) * 1` and
/// `[null][0] * 1` carry the very same `null` type and still get TS2531,
/// because neither node is the keyword itself.
///
/// An `unknown` operand is rejected here too, AHEAD of the nullish test —
/// TS18046 for an entity name, TS2571 otherwise (`reportUnknownOperand`) —
/// and the position continues on the error type, which every arithmetic and
/// relational classification accepts. So `u >= 0`, `u + 1`, `u * 2`, `-u`,
/// `+u`, `~u`, `u++`, `u in o` and `n in u` are each ONE TS18046 on the
/// operand rather than a TS2362/TS2365 on the operator (oracle-verified).
///
/// `void` is deliberately NOT nullish here: tsc masks the operand's falsy
/// flags with `TypeFlags.Nullable`, which is `Undefined | Null` only, so
/// `v.toString()` on a `void` receiver reports the missing property rather
/// than "possibly 'undefined'".
fn checkNonNullType(c: *Checker, t: TypeId, obj_node: Node) Error!TypeId {
    if (try reportUnknownOperand(c, t, obj_node)) return types.error_type;
    return checkNullishOperand(c, t, obj_node);
}

/// The nullish half of `checkNonNullType` alone, for the two receiver
/// positions that have ALREADY run the `unknown` probe and taken their own
/// early return out of it — a property access and an element access, each of
/// which has a lookup to skip rather than an error type to carry on with.
/// Splitting it keeps `reportUnknownOperand`'s `resolveStructural` off the
/// hottest path in the checker: every non-optional property access reaches
/// here, and probing twice for a type just proven not to be `unknown` is
/// pure waste.
fn checkNullishOperand(c: *Checker, t: TypeId, obj_node: Node) Error!TypeId {
    const has_null = c.containsNull(t);
    const has_undef = c.hasUndefinedMember(t);
    if (!has_null and !has_undef) return t;
    const span = c.nodeSpan(obj_node);
    if (nullishKeywordOf(c, obj_node)) |kw| {
        try c.diagFmt(18050, span, "The value '{s}' cannot be used here.", .{kw});
        return nonNullRemainder(c, t);
    }
    // tsc's entity-name codes (18047-49) apply to identifier-rooted
    // paths only; a `this`-rooted path gets the expression codes
    // (2531-33, "Object is possibly ...").
    const this_rooted = blk: {
        var n = obj_node;
        while (c.nodeTag(n) == .member_expr or c.nodeTag(n) == .optional_member_expr or c.nodeTag(n) == .paren_expr) {
            n = c.tree.nodeData(n).lhs;
        }
        break :blk c.nodeTag(n) == .this_expr;
    };
    const name_opt: ?[]const u8 = if (this_rooted) null else entityNameOf(c, obj_node);
    if (name_opt) |name| {
        if (has_null and has_undef) {
            try c.diagFmt(18049, span, "'{s}' is possibly 'null' or 'undefined'.", .{name});
        } else if (has_null) {
            try c.diagFmt(18047, span, "'{s}' is possibly 'null'.", .{name});
        } else {
            try c.diagFmt(18048, span, "'{s}' is possibly 'undefined'.", .{name});
        }
    } else {
        if (has_null and has_undef) {
            try c.diagFmt(2533, span, "Object is possibly 'null' or 'undefined'.", .{});
        } else if (has_null) {
            try c.diagFmt(2531, span, "Object is possibly 'null'.", .{});
        } else {
            try c.diagFmt(2532, span, "Object is possibly 'undefined'.", .{});
        }
    }
    return nonNullRemainder(c, t);
}

/// The literal `null` keyword / identifier `undefined` that tsc names in
/// TS18050, or null when the operand is any other expression. Written
/// syntactically, with no paren-stripping, because that is exactly how tsc
/// asks (`node.kind === NullKeyword`, `isIdentifier(node) && text ===
/// "undefined"`).
fn nullishKeywordOf(c: *Checker, node: Node) ?[]const u8 {
    return switch (c.nodeTag(node)) {
        .null_literal => "null",
        .identifier => if (std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(node)), "undefined")) "undefined" else null,
        else => null,
    };
}

/// tsc's `checkNonNullTypeWithReporter` tail: once the nullish operand has
/// been reported, a remainder that is `never` (the operand was *only*
/// nullish — `null`, `undefined`, or a reference the flow narrowed to
/// nothing else) degrades to the error type, not to `never`. That keeps the
/// single "possibly null/undefined" diagnostic from being doubled by a
/// TS2339 from the member lookup — or a TS2362/TS2365 from the operator —
/// that follows.
fn nonNullRemainder(c: *Checker, t: TypeId) Error!TypeId {
    const nn = try c.nonNullable(t);
    if (c.ts.kind(nn) == .never) return types.error_type;
    return nn;
}

/// Render an entity-name-ish expression (a, a.b, a.b.c) or null.
/// The HEAD of tsc's `checkNonNullTypeWithReporter`, which runs ahead of the
/// nullish test above: an `unknown` operand is rejected outright, and the
/// position continues on the error type rather than reaching its own verdict.
/// tsc names the operand when it is an entity name and the name is short
/// enough to print (TS18046 "'x' is of type 'unknown'.") and says "Object"
/// otherwise (TS2571). `false` — nothing reported — for every other type.
///
/// `checkNonNullType` calls it first thing, which covers every non-nullable
/// position at once. The positions that must ask BEFORE reaching there —
/// a property-access receiver, an element-access receiver, a call's callee —
/// do so themselves, because each has its own early return to take (the
/// member lookup, the index walk, the signature resolution must all be
/// skipped) and none of them reaches `checkNonNullType` afterwards.
pub fn reportUnknownOperand(c: *Checker, t: TypeId, node: Node) Error!bool {
    if (c.ts.kind(try c.resolveStructural(t)) != .unknown) return false;
    // `this` is not an `isEntityNameExpression`, so it takes the object form
    // even though `entityNameOf` can spell it (the same split
    // `checkNonNullType` makes for TS2531-3 vs TS18047-9).
    const name_opt: ?[]const u8 = if (c.nodeTag(node) == .this_expr) null else entityNameOf(c, node);
    if (name_opt) |name| {
        try c.diagFmt(18046, c.nodeSpan(node), "'{s}' is of type 'unknown'.", .{name});
    } else {
        try c.diagFmt(2571, c.nodeSpan(node), "Object is of type 'unknown'.", .{});
    }
    return true;
}

fn entityNameOf(c: *Checker, node: Node) ?[]const u8 {
    switch (c.nodeTag(node)) {
        .identifier => return c.tokenText(c.tree.nodeMainToken(node)),
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            // A `?.` link still roots an entity-name path, so tsc uses the
            // named codes (18047-9) rather than the object codes (2531-3)
            // for a nullish access on `a?.b`.
            const base = entityNameOf(c, d.lhs) orelse return null;
            _ = base;
            // Rebuild from source bytes: span of the whole node.
            const span = c.nodeSpan(node);
            if (span.end <= c.src.len and span.start < span.end) {
                const text = c.src[span.start..span.end];
                if (text.len <= 64 and std.mem.indexOfAny(u8, text, " \t\n(") == null) return text;
            }
            return null;
        },
        .this_expr => return "this",
        else => return null,
    }
}

/// Property `name` on `t`, with TS2339/TS2551 on failure.
///
/// `dir` is the access direction the ACCESSIBILITY check reads its modifiers
/// for (`accessibility.check`); every arm that finds a property runs it, and
/// the screen is the `prop_flag_non_public` bit already loaded on that
/// property, so a public member costs one branch.
fn propertyTypeOf(c: *Checker, t: TypeId, name: Atom, name_tok: TokenIndex, site: accessibility.Site) Error!TypeId {
    const k = c.ts.kind(t);
    // tsc's `getReducedApparentType`, which every property access runs its
    // receiver through: an intersection with a CONFLICTING PRIVATE property is
    // uninhabited, and `never` has no members whatever name was asked for — so
    // even a public member of one constituent is TS2339 (see
    // `accessibility.intersectionPrivateConflict`).
    if (k == .intersection and try accessibility.intersectionPrivateConflict(c, t)) {
        try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type 'never'.", .{
            c.atomText(name),
        });
        return types.error_type;
    }
    switch (k) {
        .any, .err, .none => return types.any_type,
        // `never` has no members, so tsc's `getPropertyOfType` finds nothing
        // and `checkPropertyAccessExpression` reports. The two `never`s that
        // must NOT arrive here are handled where tsc handles them: a read in
        // unreachable code answers with the DECLARED type (`flowTypeOfKey`),
        // and the empty remainder of a nullish access degrades to the error
        // type after its own diagnostic (`checkNonNullType`).
        .never => {
            try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type 'never'.", .{
                c.atomText(name),
            });
            return types.error_type;
        },
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            // The constituents' own answers, kept so the ACCESSIBILITY rule can
            // judge the set as a whole — see `props.unionPropertyDropped`.
            var found: std.ArrayList(types.Prop) = .empty;
            defer found.deinit(c.scratch());
            // The first constituent contributing a non-public member. The
            // per-access accessibility check runs against it only AFTER the
            // whole set has been judged: a union whose constituents contribute
            // DIFFERENT declarations has no such property at all (TS2339 below),
            // and reporting per constituent named each class in turn where tsc
            // names none (`unionTypePropertyAccessibility`).
            var non_public_of: TypeId = types.no_type;
            for (try c.memberList(t)) |m| {
                const rm = try c.resolveStructural(m);
                if (c.ts.kind(rm) == .any or c.ts.kind(rm) == .err) {
                    try parts.append(c.scratch(), types.any_type);
                    continue;
                }
                const p = (try c.propOfType(rm, name)) orelse {
                    try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'.", .{
                        c.atomText(name), try c.typeToString(t),
                    });
                    return types.error_type;
                };
                try found.append(c.scratch(), p);
                if (p.nonPublic() and non_public_of == types.no_type) non_public_of = m;
                var pt = try c.substThis(p.ty, m);
                if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                try parts.append(c.scratch(), pt);
            }
            if (props_zig.unionPropertyDropped(found.items)) {
                try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'.", .{
                    c.atomText(name), try c.typeToString(t),
                });
                return types.error_type;
            }
            if (non_public_of != types.no_type) {
                try accessibility.check(c, non_public_of, name, name_tok, site);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        else => {
            // `this.f` read from a member whose own type is being computed
            // *as part of* the class's instance materialization: an
            // unannotated method's return type is inferred by checking its
            // body, and that body runs while `classInstanceGeneric` still
            // holds the member table open. `resolveStructural` can only
            // answer `error_type` there → `any`, which then memoizes into
            // the method's signature, so every later caller of `c.m()` sees
            // `any` too. The single member can be resolved on its own —
            // see `lazyRefProp`, already used for the `C["f"]` type
            // position.
            if (try c.lazyThisProp(t, name)) |p| {
                if (p.nonPublic()) try accessibility.check(c, t, name, name_tok, site);
                var pt = try c.substThis(p.ty, t);
                if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                return pt;
            }
            // A VALUE-position read of ONE member of a generic reference,
            // substituted on its own — tsc's `getTypeOfPropertyOfType`, which
            // asks `getPropertyOfType` for a single symbol out of the
            // instantiated table `createInstantiatedSymbolTable` built from
            // `(target, mapper)` pairs, and only then runs `getTypeOfSymbol` on
            // that one symbol. ztsc materializes the whole table instead.
            //
            // Gated exactly as the type-position twin is (`lazyIndexedProp`):
            // only once THIS checker has already hit the instantiation ceiling,
            // which is the one condition under which the eager table is not a
            // prepayment but a loss. prof.zig records this conversion as a
            // large regression on immich twice — the mechanism being that the
            // whole-table expansion runs early, completes, and is memoized for
            // every later reader — and both of those measurements were taken
            // when immich still tripped the ceiling thousands of times. It
            // trips ZERO times today, as do excalidraw and every package in
            // `bench/corpus/real`, so the healthy corpus never takes this route
            // and pays one predictable-false branch for it. social-app's
            // `z.object({…40 props})` does trip, and there `schema.safeParse`
            // spends the entire 250,000-node statement budget materializing
            // `ZodObject`'s ~40-member table — of which it reads exactly one
            // member — because `required(): ZodObject<{[k in keyof T]:
            // deoptional<T[k]>}, …>` and the `ZodOptional<this>` /
            // `ZodEffects<this, …>` fluent tail behind it drag in a thousand
            // more expansions.
            if (k == .ref) {
                if (try c.lazyIndexedProp(t, name)) |p| {
                    if (p.nonPublic()) try accessibility.check(c, t, name, name_tok, site);
                    var pt = try c.substThis(p.ty, t);
                    if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                    return pt;
                }
            }
            const r = try c.resolveStructural(t);
            if (c.ts.kind(r) == .any or c.ts.kind(r) == .err) {
                // …unless the receiver is a class whose table is open further
                // down this stack, where the error type is the WINDOW and not
                // an answer: the declarations can still say the member is
                // absent (`inProgressMemberAbsent`).
                if (try classes.inProgressMemberAbsent(c, t, name)) {
                    // Named the way tsc names it: the report prints
                    // `getApparentType(leftType)`, and the apparent type of a
                    // polymorphic `this` is the class instance — "does not
                    // exist on type 'Bar'", not "on type 'this'".
                    const shown = if (c.ts.kind(t) == .this_type) c.ts.thisTypeInstance(t) else t;
                    return reportMissingProp(c, shown, r, name, name_tok);
                }
                return types.any_type;
            }
            if (try c.propOfType(r, name)) |p| {
                if (p.nonPublic()) try accessibility.check(c, t, name, name_tok, site);
                var pt = try c.substThis(p.ty, t);
                if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                return pt;
            }
            // Instance access to a static member (TS2576).
            if (k == .ref) {
                const cls = c.ts.refSymbol(t);
                const cls_bind = c.symBind(cls);
                if (c.symFlags(cls).class) {
                    if (cls_bind.staticsScopeOf(c.localOf(cls))) |ss| {
                        if (cls_bind.lookupInScope(ss, name) != null) {
                            try c.diagFmt(2576, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'. Did you mean to access the static member '{s}.{s}' instead?", .{
                                c.atomText(name), try c.typeToString(t), c.symbolName(cls), c.atomText(name),
                            });
                            return types.error_type;
                        }
                    }
                }
            }
            // An unknown member of the global scope object is, for tsc, an
            // implicit-'any' index (TS7017) — not a missing property. Only
            // a name that has no global VALUE meaning at all takes this
            // path: a block-scoped global (`const`/`let`/`class`/`enum`) is
            // in scope but not a property, and stays TS2339 below.
            // Suppressed under `noImplicitAny: false`, like its siblings.
            if (c.ts.kind(r) == .object and c.ts.objectFlags(r) & types.obj_flag_global_this != 0 and
                !c.globalThisHasValue(name))
            {
                if (c.prog.no_implicit_any) {
                    try c.diagFmt(7017, c.tokSpan(name_tok), "Element implicitly has an 'any' type because type '{s}' has no index signature.", .{
                        try c.typeToString(t),
                    });
                }
                return types.any_type;
            }
            return reportMissingProp(c, t, r, name, name_tok);
        },
    }
}

/// The not-found verdict of a property access: TS2339, or TS2551 when a
/// near-miss member suggests itself (tsc's
/// `getSuggestionForNonexistentProperty`). `t` is the receiver AS WRITTEN —
/// what the message names — and `r` its resolved structure, which is what the
/// suggestion searches.
fn reportMissingProp(c: *Checker, t: TypeId, r: TypeId, name: Atom, name_tok: TokenIndex) Error!TypeId {
    if (c.suggestProp(name, r)) |sugg| {
        try c.diagFmt(2551, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'. Did you mean '{s}'?", .{
            c.atomText(name), try c.typeToString(t), c.atomText(sugg),
        });
    } else {
        try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type '{s}'.", .{
            c.atomText(name), try c.typeToString(t),
        });
    }
    return types.error_type;
}

/// The member a NUMBER-LITERAL key names, if `r` declares one. tsc's
/// `getPropertyNameFromIndex` renders the literal the way JavaScript does
/// (`String(2)` is `"2"`) and looks that name up before any index signature.
/// Only integral values in the range where that rendering is exact are
/// handled; anything else (fractional, exponential, huge) falls through to
/// the index signature, which is the pre-existing behaviour.
pub fn numericKeyProp(c: *Checker, r: TypeId, lit: TypeId) Error!?types.Prop {
    const v = c.ts.numberValue(lit);
    if (v != @floor(v) or @abs(v) >= 9007199254740992.0) return null;
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch return null;
    const name = try c.internText(txt);
    var via_index = false;
    const p = (try c.propOfTypeViaIndex(r, name, &via_index)) orelse return null;
    // A declared member wins outright. An answer that came from the STRING
    // index signature does not: for a NUMERIC key tsc's
    // `findApplicableIndexInfo` consults the string signature "only when no
    // other index signature applies", so a receiver carrying both answers from
    // its number one. `class C { static [s: string]: number; static
    // [s: number]: 42 }` read `C[2]` as `number` without this.
    if (via_index) {
        const ni = try numberIndexSlot(c, r);
        if (ni != 0) return .{ .name = name, .ty = ni, .flags = 0 };
    }
    return p;
}

/// The receiver's NUMBER index-signature value type, or 0 when it has none.
/// Unlike `numberIndexType` this never falls back to the string signature —
/// the caller is deciding WHICH signature applies.
fn numberIndexSlot(c: *Checker, r: TypeId) Error!TypeId {
    return switch (c.ts.kind(r)) {
        .object => c.ts.objectNumberIndex(r),
        .class_value => numberIndexSlot(c, try c.classStaticType(c.ts.classSymbol(r))),
        else => 0,
    };
}

/// tsc's `isNumericLiteralName`: a property name that is *exactly* how
/// JavaScript renders a number (`(+name).toString() === name`). Such a name
/// reaches the same member — and the same NUMBER index signature — as the
/// numeric key does, which is `isApplicableIndexType`'s third disjunct:
///
///     target === numberType && source.flags & StringLiteral &&
///         isNumericLiteralName(source.value)
///
/// Only the integral spellings are recognised. A fractional or exponential
/// one (`"1.5"`, `"1e+21"`) is a numeric name for tsc too, but no test in
/// the corpus needs it and the round-trip rule is subtle, so those keep the
/// plain string-key behaviour (an under-report, never a false positive).
fn numericLiteralNameValue(text: []const u8) ?f64 {
    // 15 digits is the widest decimal integer f64 renders back exactly.
    if (text.len == 0 or text.len > 16) return null;
    const neg = text[0] == '-';
    const digits = if (neg) text[1..] else text;
    if (digits.len == 0) return null;
    // `"01"` renders as `"1"` and `"-0"` as `"0"`, so neither is a numeric name.
    if (digits[0] == '0' and (digits.len > 1 or neg)) return null;
    if (digits.len > 15) return null;
    var v: f64 = 0;
    for (digits) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + @as(f64, @floatFromInt(ch - '0'));
    }
    return if (neg) -v else v;
}

/// The type a NUMERIC index resolves to when the receiver really carries a
/// numeric domain: a tuple element, an array element, or a declared `number`
/// index signature. `null` when none applies, so a string-literal key that
/// merely *looks* numeric keeps the TS7053 it reports today.
fn numericIndexHit(c: *Checker, r: TypeId, rk: types.Kind, v: f64) Error!?TypeId {
    // A branded tuple/array (`[X, Y] & { _brand }`) indexes through its
    // indexable constituent — see `indexableConstituent`.
    const rt = if (rk == .intersection) (try c.indexableConstituent(r)) orelse r else r;
    switch (c.ts.kind(rt)) {
        .tuple => {
            // Out of the addressable domain (negative, fractional, huge) is
            // the same "past the end" answer a too-large index gets: the
            // tuple's REST element if it has one, else `null` (TS2493).
            const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
            if (iv < c.ts.tupleLen(rt)) {
                const e = c.ts.tupleElem(rt, iv);
                // A REST element's stored type is the ARRAY, and it occupies
                // every position from its own slot onward: the element type of
                // `[number, number, ...number[]]` at index 2 is `number`, not
                // `number[]`. Reading `e.ty` straight made `v[2]` the whole
                // rest array — the out-of-fixed-range path below already asks
                // `tupleElemTypeAt`, which is the rule.
                if (e.rest()) return c.tupleElemTypeAt(rt, iv);
                return if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
            }
            return c.tupleElemTypeAt(rt, iv);
        },
        .array => return c.ts.arrayElem(rt),
        .object => {
            const ni = c.ts.objectNumberIndex(rt);
            return if (ni != 0) ni else null;
        },
        // A STRING carries a numeric domain through its apparent type: the
        // lib's `interface String { readonly [index: number]: string }`. tsc
        // reaches it the same way it reaches any other — `getPropertyName-
        // FromIndex` turns the numeric name into a number index and
        // `findApplicableIndexInfo` picks that signature off the apparent
        // type. Without the arm, `s["0"]` was a TS7053 false positive while
        // `s[0]` (which goes through `numberIndexType`) was silent
        // (`templateStringInIndexExpression`).
        .string, .string_literal, .template_literal_type, .string_mapping => return types.string_type,
        else => return null,
    }
}

/// `numericIndexHit` for a key given as TEXT: the numeric-name test and the
/// numeric resolution together, so the caller pays neither unless a
/// string-literal key actually misses as a property name.
pub fn numericNameIndexHit(c: *Checker, r: TypeId, rk: types.Kind, text: []const u8) Error!?TypeId {
    const v = numericLiteralNameValue(text) orelse return null;
    return numericIndexHit(c, r, rk, v);
}

fn checkIndexExpr(c: *Checker, node: Node, narrow: bool, ctx: TypeId) Error!TypeId {
    const link = try indexChainInner(c, node, narrow, ctx);
    if (link.chained) return c.makeUnion2(link.ty, types.undefined_type);
    return link.ty;
}

/// tsc's `isGenericIndexType` — the `IsGenericIndexType` bit of
/// `getGenericObjectFlags` — asked of the INDEX of an element access: an
/// instantiable non-primitive (a type variable, a deferred access, a
/// conditional), a `keyof`, a template-literal pattern or a string mapping.
///
/// A generic MAPPED type is deliberately absent: it carries the *object*-side
/// bit only, and the object side of an element-access expression does not
/// defer (see `indexChainInner`). A union or intersection is generic when any
/// constituent is, which is what `getGenericObjectFlags` ORs over — and what
/// keeps a BRANDED key (`string & { _brand }`, both constituents concrete)
/// on the eager path it has always taken.
fn indexTypeIsGeneric(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    return switch (s.kind(t)) {
        .type_param,
        .infer_var,
        .mapped_param,
        .index_access,
        .conditional,
        .keyof_op,
        .template_literal_type,
        .string_mapping,
        => true,
        .union_type, .intersection => blk: {
            for (0..s.memberCount(t)) |i| {
                if (try indexTypeIsGeneric(c, s.memberAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// tsc's `checkIndexedAccessIndexType` for the access an element-access
/// EXPRESSION just deferred: "is every constituent of the index assignable to
/// `keyof` the object" — or, failing that, applicable to a number index
/// signature the object has. Answers whether it reported TS2536, in which case
/// the caller substitutes `error_type` exactly as tsc does.
///
/// `keyof.checkIndexedAccessIndexType` is the same tsc function reached from a
/// type NODE, where ztsc deliberately restricts itself to a decidable
/// literal-key shape (see there). The two do not overlap: the object side of an
/// element-access expression never defers, so an access that gets here always
/// has a GENERIC index — the case that check declines to look at — and one
/// that gets there never does.
///
/// tsc's `AccessFlags.Writing` arm of the same function — TS2542 through a
/// `Readonly<T>` — is `readonlyIndexWriteAt`'s here instead: a mapped receiver
/// is one of the shapes `indexChainInner` declines to defer, so the write has
/// no deferred access to hang the check on.
fn checkDeferredIndexType(c: *Checker, acc: TypeId, node: Node) Error!bool {
    const s = &c.ts;
    const obj = s.indexAccessObj(acc);
    const idx = s.indexAccessIndex(acc);
    const keys = try c.keyofType(obj);
    // tsc's `getIndexInfoOfType(objectType, numberType)`, asked of the
    // apparent type: a numeric key reaches a number index signature even
    // when `keyof` does not spell it out.
    const apparent = try c.resolveStructural(try c.indexObjBaseConstraint(obj));
    const has_number_index = switch (s.kind(apparent)) {
        .array, .tuple => true,
        .object => s.objectNumberIndex(apparent) != 0,
        else => false,
    };
    var one = [_]TypeId{idx};
    const parts: []const TypeId = if (s.kind(idx) == .union_type) try c.memberList(idx) else one[0..];
    for (parts) |p| {
        if (try c.isAssignable(p, keys)) continue;
        if (has_number_index and try c.typeIsNumberLike(try c.resolveStructural(p))) continue;
        try c.diagFmt(2536, c.nodeSpan(node), "Type '{s}' cannot be used to index type '{s}'.", .{
            try c.typeToString(idx), try c.typeToString(obj),
        });
        return true;
    }
    return false;
}

/// Is `obj` an element-access receiver ztsc is willing to DEFER over?
///
/// tsc defers on a generic INDEX whatever the object is
/// (`getIndexedAccessTypeOrUndefined`); this is narrower on purpose, and each
/// exclusion names a place where ztsc's *relation* cannot read a deferred
/// access back, so deferring would turn silence into a false positive:
///
///   * a NON-generic object. `assign.zig`'s indexed-access source rule takes
///     both sides' base constraints at once, which for a concrete receiver is
///     the receiver with its type ARGUMENTS substituted — excalidraw's
///     `{ [key: string]: E; [key: number]: E }[E["id"]]` came back keyed by
///     `Entity`, not by `E`, and stopped being an `E`
///     (`keyofAndIndexedAccess2` f50/f51's callers). tsc constrains ONE side
///     at a time and keeps the other; ztsc does not, so the eager answer —
///     which is what a concrete receiver has always given — stays.
///   * a MAPPED object, or a type parameter CONSTRAINED by a generic mapped
///     type. `Partial<T>[K]` and `Record<keyof T, number>[K]` are exactly the
///     accesses whose meaning lives in `getSimplifiedIndexedAccessType`, and
///     the relation reaches that simplification only when the map is the
///     access's own object — never through a constraint. A generic mapped
///     receiver still gets its write-side TS2542 (`readonlyIndexWriteAt`),
///     which needs the receiver, not the deferred type.
///
/// Both are UNDER-deferrals: the access falls back to the eager answer it gave
/// before deferral existed, so nothing that reports today stops reporting.
fn indexDeferrableObject(c: *Checker, obj: TypeId) Error!bool {
    if (!try c.isGenericObjectForIndex(obj)) return false;
    if (c.ts.kind(try c.resolveStructural(obj)) == .mapped) return false;
    const bc = try c.indexObjBaseConstraint(obj);
    return bc == obj or c.ts.kind(try c.resolveStructural(bc)) != .mapped;
}

/// Element access as an optional-chain link (see `memberChainInner`).
fn indexChainInner(c: *Checker, node: Node, narrow: bool, ctx: TypeId) Error!ChainLink {
    const d = c.tree.nodeData(node);
    const own_optional = c.nodeTag(node) == .optional_index_expr;
    var chained = false;
    var obj_t = obj: {
        // An element-access receiver is in a constraint position too, except
        // for the `T[K]` case the index expression decides (`ConstraintPos`).
        const saved = enterConstraintPos(c, d.lhs, d.rhs);
        defer c.constraint_pos = saved;
        if (c.isOptionalChain(d.lhs)) {
            const link = try c.chainObjType(d.lhs);
            if (link.chained) chained = true;
            break :obj link.ty;
        }
        const base = try c.checkExprCached(d.lhs, types.no_type);
        break :obj try narrowThisReceiver(c, d.lhs, node, base);
    };
    // The index expression runs only on the chain's non-nullish branch, so
    // it sees the chain's own guards (`pushChainGuards`).
    const idx_t = idx: {
        const saved = c.chain_guards.items.len;
        defer c.chain_guards.shrinkRetainingCapacity(saved);
        try c.pushChainGuards(node);
        break :idx try c.checkExprCached(d.rhs, types.no_type);
    };
    if (own_optional) {
        if (c.containsNullish(obj_t)) chained = true;
        obj_t = try c.nonNullableChain(obj_t);
    } else {
        // The same unknown-receiver gate a property access runs — `u["k"]`
        // is TS18046 at `u`, where the index walk below reaches TS7053.
        if (try reportUnknownOperand(c, obj_t, d.lhs)) {
            return .{ .ty = types.error_type, .chained = chained };
        }
        obj_t = try checkNullishOperand(c, obj_t, d.lhs);
    }
    const r = try c.resolveStructural(obj_t);
    const rk = c.ts.kind(r);
    if (rk == .any or rk == .err) return .{ .ty = types.any_type, .chained = chained };
    var result: TypeId = types.any_type;
    // `o[Symbol.iterator]` (and the other well-known symbols): the member
    // is keyed syntactically by `__@iterator` on the declaration side
    // (`wellKnownSymbolKey`), so the access side must key it the same way.
    // In the real lib `Symbol.iterator` is typed `unique symbol`, so this
    // must run *before* the generic `unique symbol` (`__@uN`) path below,
    // which would otherwise look up a mismatched nominal key.
    if (c.wellKnownKeyOfExpr(d.rhs)) |wk| {
        const key = try c.atom(wk);
        if (try c.propOfType(r, key)) |p| {
            result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        } else {
            try c.diagFmt(2339, c.nodeSpan(d.rhs), "Property '{s}' does not exist on type '{s}'.", .{
                c.atomText(key), try c.typeToString(obj_t),
            });
            result = types.error_type;
        }
        return .{ .ty = result, .chained = chained };
    }
    // `o[k]` where `k` is a `unique symbol`: resolve the nominally-keyed
    // property (see `uniqueSymAtom`).
    if (try c.uniqueSymAtom(idx_t)) |key| {
        if (try c.propOfType(r, key)) |p| {
            result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        } else {
            // A `unique symbol` that does not key a member of the target:
            // tsc reports TS7053 (implicit-any index) rather than TS2339,
            // since the key is a symbol, not a named property. Suppressed
            // under `noImplicitAny: false` (implicit-'any' family).
            if (c.prog.no_implicit_any) {
                try c.diagFmt(7053, c.nodeSpan(d.rhs), "Element implicitly has an 'any' type because expression of type 'unique symbol' can't be used to index type '{s}'.", .{
                    try c.typeToString(obj_t),
                });
            }
            result = types.error_type;
        }
        // A symbol-keyed element access is a TRACKED reference like any other
        // constant-keyed one (`PathElem.elementSym`), so it takes the same
        // narrowing step the tail of this function applies — this arm's early
        // return was skipping it, which is why `if (page[SYM]) { page[SYM]
        // .total }` stayed optional and reported TS2532.
        if (narrow) {
            if (try c.buildRefKey(node)) |ref| {
                result = try c.flowTypeOfKey(node, ref, result);
            }
        }
        return .{ .ty = result, .chained = chained };
    }
    const ik = c.ts.kind(try c.ts.regularLiteral(idx_t));
    // tsc's `getIndexedAccessTypeOrUndefined`, element-access-EXPRESSION arm:
    // a GENERIC index — a type variable, `keyof T`, another deferred access,
    // a conditional — makes the access DEFERRED, `Obj[Idx]`, instead of being
    // resolved against a member table that does not exist yet. `x[k]` under
    // `<T, K extends keyof T>` is `T[K]`, and `let n: number = x[k]` is the
    // TS2322 tsc reports; classifying `k` by `typeIsStringLike` instead
    // (the `else` arm below) answered `any` and said nothing at all.
    //
    // The index side is tsc's whole test; the object side is `indexDeferrable-
    // Object`'s narrower one, which names the receivers whose deferred access
    // ztsc's relation cannot read back. A concrete key never defers either
    // way, so `x["a"]` under `T extends { a: string }` is still `string`.
    //
    // `reduceIndexedAccess` is the shared builder, so a key that reduces
    // anyway (a concrete template pattern, a `never` key set) takes the
    // ordinary arms below unchanged — only an access that actually stayed
    // deferred is adopted here.
    const deferred: ?TypeId = def: {
        if (!try indexTypeIsGeneric(c, idx_t)) break :def null;
        if (!try indexDeferrableObject(c, obj_t)) break :def null;
        const acc = try c.reduceIndexedAccess(obj_t, idx_t);
        break :def if (c.ts.kind(acc) == .index_access) acc else null;
    };
    // tsc's `getIndexedAccessType` distributes over a UNION index type:
    // `o[k]` with `k: "a" | "b"` is `o["a"] | o["b"]`. Without this arm a
    // union key matched none of the kinds below and fell through to the
    // string-like `else`, where an object with no string index signature
    // yields `any` — so every read through a `Record<SomeUnion, T>` lost
    // its type, and with it the contextual signature of any callback the
    // read fed (`map[dir].map((c) => c)`).
    // A key set that did NOT distribute is still reported on: tsc's
    // `getIndexedAccessType` errors on the offending constituent and the
    // access falls back to `any` (TS7053) or to the receiver's numeric index
    // signature (TS2493, out-of-range tuple constituent). Only the two
    // certain shapes reach here (see `UnionIndexMiss`); the fallback type
    // below is unchanged either way, so whatever the access already reported
    // downstream still reports.
    const distributed: ?TypeId = if (deferred != null) null else switch (try c.unionIndexElemType(r, idx_t)) {
        .resolved => |ut| ut,
        .miss => |m| blk: {
            switch (m) {
                .none => {},
                .absent_key => try reportIndexImplicitAny(c, node, d.lhs, idx_t, obj_t),
                .tuple_range => |tr| try c.diagFmt(2493, c.nodeSpan(d.rhs), "Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{
                    try c.typeToString(tr.tuple), c.ts.tupleLen(tr.tuple), tr.index,
                }),
            }
            break :blk null;
        },
    };
    if (deferred) |acc| {
        // tsc's `checkIndexedAccessIndexType`, which `checkElementAccess-
        // Expression` runs on the access it just built.
        result = if (try checkDeferredIndexType(c, acc, node)) types.error_type else acc;
    } else if (distributed) |ut| {
        result = ut;
    } else switch (ik) {
        .string_literal => {
            const key = c.ts.literalAtom(try c.ts.regularLiteral(idx_t));
            // A key that is a NUMERIC NAME (`o["0"]`, `t["1"]`) reaches the
            // receiver's numeric domain, and reaches it *before* a `string`
            // index signature: tsc's `findApplicableIndexInfo` considers the
            // string signature "only when no other index signatures apply".
            // Without this, `[string, number]["0"]`, `{ [x: number]: string
            // }["3"]` and every `c['1']` on a numerically-keyed class were
            // TS7053 false positives.
            if (try c.propOfType(r, key)) |p| {
                result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            } else if (try numericNameIndexHit(c, r, rk, c.atomText(key))) |nt| {
                result = nt;
            } else if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                result = c.ts.objectStringIndex(r);
            } else {
                // Element access `o['k']` with a string-literal key that is
                // neither a known property nor covered by a string index is,
                // for tsc, an implicit-'any' element access (TS7053) — NOT a
                // missing-property TS2339 (which is reserved for dotted `o.k`).
                // Suppressed under `noImplicitAny: false`; the result is `any`
                // either way.
                try reportIndexImplicitAny(c, node, d.lhs, idx_t, obj_t);
                result = types.any_type;
            }
        },
        .number_literal => {
            const rl = try c.ts.regularLiteral(idx_t);
            // A branded tuple (`[X, Y] & { _brand }`) indexes through its
            // tuple constituent — see `indexableConstituent`.
            const rt = if (rk == .intersection)
                (try c.indexableConstituent(r)) orelse r
            else
                r;
            if (c.ts.kind(rt) == .tuple) {
                const v = c.ts.numberValue(rl);
                if (try numericIndexHit(c, r, rk, v)) |et| {
                    result = et;
                } else {
                    const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                    try c.diagFmt(2493, c.nodeSpan(d.rhs), "Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{
                        try c.typeToString(rt), c.ts.tupleLen(rt), iv,
                    });
                    result = types.error_type;
                }
            } else if (try c.numericKeyProp(r, rl)) |p| {
                // tsc's `getPropertyNameFromIndex`: a NUMERIC-literal key
                // names a property exactly as a string-literal one does —
                // `{ 1: 8, 2: 16, 4: 32 } as const` declares members `"1"`,
                // `"2"`, `"4"`, and `BITS[2]` reads that member. Going
                // straight to `numberIndexType` instead meant an object
                // without a numeric index signature answered `any`, so every
                // number-keyed lookup table lost its element type.
                result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            } else {
                // No property of that numeric name and no index signature to
                // reach through: the numeric-literal counterpart of the
                // string-literal arm above, and the same implicit-'any'
                // element access for tsc (TS7053). It is what makes
                // `{ ...indexed, b: 11 }[101]` an error once the spread has
                // dropped the index signature (`SpreadIndexFold`).
                //
                // Only for a plain object receiver: an array/tuple/string has
                // its own numeric domain (answered above), and `globalThis`
                // has its own code (TS7017), exactly as in the `string` arm.
                //
                // And only where the miss is CERTAIN, because two of ztsc's
                // approximations show up right here:
                //
                //   * a key `numericKeyProp` declines — a fraction, or a
                //     magnitude past the safe-integer range — still names a
                //     property for tsc, whose `getPropertyNameFromIndex`
                //     renders the literal the way JS does. `class C { 1.1:
                //     string }` indexed `c[1.1]` reads that member;
                //   * a FRESH object literal's own index signatures come from
                //     its computed keys, which ztsc types more coarsely than
                //     tsc (a `this` inside a class computed name has no type
                //     at all, so `{ [this.bar()]: 1 }` loses the numeric index
                //     tsc gives it).
                //
                // Both stay silent — an under-report rather than an invention.
                const v = c.ts.numberValue(rl);
                if (rk == .object and c.ts.objectNumberIndex(r) == 0 and c.ts.objectStringIndex(r) == 0 and
                    c.ts.objectFlags(r) & types.obj_flag_global_this == 0 and
                    !c.ts.objectIsLiteralOrigin(r) and
                    v == @floor(v) and @abs(v) < 9007199254740992.0)
                {
                    try reportIndexImplicitAny(c, node, d.lhs, idx_t, obj_t);
                }
                result = try c.numberIndexType(r);
            }
        },
        .number => result = try c.numberIndexType(r),
        .string => {
            if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                result = c.ts.objectStringIndex(r);
            } else if (rk == .array or rk == .tuple or rk == .string) {
                result = types.any_type;
            } else if (rk == .object and c.ts.objectIsLiteralOrigin(r)) {
                // An OBJECT LITERAL indexed by the whole `string` domain is
                // not an implicit-any access for tsc: `getPropertyTypeForIndexType`
                // answers `getUnionType(append(map(getPropertiesOfType(objectType),
                // getTypeOfSymbol), undefinedType))` for
                // `isObjectLiteralType(objectType) && indexType.flags &
                // (Number | String)`, with no diagnostic. That is what types
                // the "inline lookup table" idiom —
                // `({400: 'Inter-Regular', …})[String(weight)] || 'Inter-Regular'`
                // — which ztsc reported as TS7053.
                var vals: std.ArrayList(TypeId) = .empty;
                defer vals.deinit(c.scratch());
                for (0..c.ts.objectPropCount(r)) |i| {
                    try vals.append(c.scratch(), c.ts.objectProp(r, @intCast(i)).ty);
                }
                try vals.append(c.scratch(), types.undefined_type);
                result = try c.ts.makeUnion(c.scratch(), vals.items);
            } else {
                // A plain `string` key into an object with no string index
                // signature is, for tsc, an implicit-'any' element access
                // (TS7053) — the whole-domain counterpart of the
                // string-literal arm above. `globalThis` has its own code
                // (TS7017, on the property path); an array/tuple/string
                // receiver has TS7015 ("index expression is not of type
                // 'number'"), which ztsc does not implement, so those stay
                // silent above. Suppressed under `noImplicitAny: false`; the
                // result is `any` either way.
                if (rk == .object and c.ts.objectFlags(r) & types.obj_flag_global_this == 0) {
                    try reportIndexImplicitAny(c, node, d.lhs, idx_t, obj_t);
                }
                result = types.any_type;
            }
        },
        // A BRANDED key (`FontString = string & { _brand }`) is an
        // intersection, none of the kinds above, and fell straight through
        // to `any` — so every read through `{ [key: FontString]: T }` lost
        // its type. tsc classifies the index by `TypeFlags.StringLike` /
        // `NumberLike`, so reduce it to its base primitive.
        else => {
            const ri = try c.resolveStructural(try c.ts.regularLiteral(idx_t));
            // A whole ENUM as the key (`handlers[name as JobName]`). ztsc
            // models an enum as ONE nominal type while tsc models it as the
            // UNION of its member types, so neither the string-like nor the
            // number-like arm can answer for it: a string enum fell through
            // to `any`, and a numeric one asked for a number index signature
            // the table does not have. tsc computes
            // `getIndexedAccessType(objectType, indexType)`, which
            // distributes over that union and answers the union of the named
            // members' types — `{ [K in JobName]?: Item }` indexed by
            // `JobName` is `Item | undefined`, not `any`. Before this, every
            // read off the result and the inferred return type of the
            // function holding it were `any`.
            const enum_key = c.ts.kind(ri) == .enum_type and !c.ts.isEnumMember(ri);
            const ia: TypeId = if (enum_key) try c.indexedAccessType(r, ri) else types.no_type;
            if (ia != types.no_type and ia != types.error_type) {
                result = ia;
            } else if (try c.typeIsStringLike(ri)) {
                result = if (rk == .object and c.ts.objectStringIndex(r) != 0)
                    c.ts.objectStringIndex(r)
                else
                    types.any_type;
            } else if (try c.typeIsNumberLike(ri)) {
                result = try c.numberIndexType(r);
            } else {
                // tsc's `getPropertyTypeForIndexType`, last arm: an index
                // whose type is neither string-, number- nor symbol-like
                // names no property at all, so the access is TS2538 at the
                // INDEX rather than the implicit-`any` element access a
                // key-shaped miss earns.
                if (indexKindUnusable(c.ts.kind(ri))) {
                    try c.diagFmt(2538, c.nodeSpan(d.rhs), "Type '{s}' cannot be used as an index type.", .{try c.typeToString(idx_t)});
                }
                result = types.any_type;
            }
        },
    }
    // A member reached by ELEMENT access (`o["~standard"]`) resolves its
    // polymorphic `this` against the receiver exactly as the dotted form
    // does — the two spellings name the same member, so they must answer
    // the same type. A no-op (one `has_this_types` test) otherwise.
    result = try c.substThis(result, obj_t);
    // Element-access narrowing, the counterpart of `memberChainInner`'s
    // property-path step: `arr[0]` with a CONSTANT index is a tracked
    // reference (`buildRefKey` rejects a variable index), so a guard written
    // on it — `if (isImageElement(elements[0]))` — must narrow the reads of
    // the same access. `narrow` is false for an assignment TARGET, whose
    // type is the declared element type: narrowing it would reject
    // `arr[0] = other` inside a guard on `arr[0]` (the dotted-member write
    // path reads the declared property type for the same reason).
    if (narrow) {
        // tsc's `getNarrowableTypeForReference`, element-access arm.
        result = try c.narrowableRefType(node, result, ctx);
        if (try c.buildRefKey(node)) |key| {
            result = try c.flowTypeOfKey(node, key, result);
        }
    }
    return .{ .ty = result, .chained = chained };
}

/// Is an index of this kind one tsc reports TS2538 for — a type that can name
/// no property at all?
///
/// An allow-list rather than the complement of "key-like", because two of the
/// kinds tsc would also report on are ztsc's own fallbacks and would turn a
/// gap into a false error: `unknown` is what a failed inference leaves and
/// `void` what an unresolved value declaration leaves. The other exclusions
/// are tsc's own: `any`, `symbol` and an enum key are the implicit-`any`
/// element access (TS7053), a type variable is TS2536, and `never` is silent.
fn indexKindUnusable(k: types.Kind) bool {
    return switch (k) {
        .function, .overloads, .object, .array, .tuple, .class_value, .boolean, .bool_true, .bool_false, .null, .undefined => true,
        else => false,
    };
}

/// The write sites tsc runs `checkReferenceExpression` for. Each carries its
/// own pair of diagnostics — "must be a variable or a property access" and
/// "may not be an optional property access".
pub const RefSite = enum {
    assignment,
    object_rest,
    increment,
    for_in,
    for_of,

    fn invalidCode(self: RefSite) u16 {
        return switch (self) {
            .assignment => 2364,
            .object_rest => 2701,
            .increment => 2357,
            .for_in => 2406,
            .for_of => 2487,
        };
    }

    fn invalidText(self: RefSite) []const u8 {
        return switch (self) {
            .assignment => "The left-hand side of an assignment expression must be a variable or a property access.",
            .object_rest => "The target of an object rest assignment must be a variable or a property access.",
            .increment => "The operand of an increment or decrement operator must be a variable or a property access.",
            .for_in => "The left-hand side of a 'for...in' statement must be a variable or a property access.",
            .for_of => "The left-hand side of a 'for...of' statement must be a variable or a property access.",
        };
    }

    fn optionalCode(self: RefSite) u16 {
        return switch (self) {
            .assignment => 2779,
            .object_rest => 2778,
            .increment => 2777,
            .for_in => 2780,
            .for_of => 2781,
        };
    }

    fn optionalText(self: RefSite) []const u8 {
        return switch (self) {
            .assignment => "The left-hand side of an assignment expression may not be an optional property access.",
            .object_rest => "The target of an object rest assignment may not be an optional property access.",
            .increment => "The operand of an increment or decrement operator may not be an optional property access.",
            .for_in => "The left-hand side of a 'for...in' statement may not be an optional property access.",
            .for_of => "The left-hand side of a 'for...of' statement may not be an optional property access.",
        };
    }
};

/// tsc's `checkReferenceExpression`: a write target has to be *classified as a
/// reference* — an identifier or a property/element access, once parentheses
/// and assertions are skipped — and it may not be an optional chain, because a
/// short-circuited chain has nowhere to write to.
///
/// Both diagnostics are reported on the expression AS WRITTEN (tsc's `error
/// (expr, …)`), not on the skipped-through node, so `(1 + 2) = 3` points at the
/// parenthesized expression.
///
/// The answer is load-bearing beyond the diagnostic: every caller runs its own
/// assignability / element-type check only when this returns true, which is how
/// tsc keeps an invalid target from also reporting a TS2322 cascade.
pub fn checkReferenceExpression(c: *Checker, expr: Node, site: RefSite) Error!bool {
    var node = expr;
    // `skipOuterExpressions(Parentheses | Assertions)`: `(x) = 1`, `(<T>x) = 1`
    // and `x! = 1` all name the reference `x`.
    while (true) switch (c.nodeTag(node)) {
        .paren_expr, .as_expr, .satisfies_expr, .non_null => node = c.tree.nodeData(node).lhs,
        else => break,
    };
    switch (c.nodeTag(node)) {
        .identifier, .member_expr, .index_expr, .optional_member_expr, .optional_index_expr => {},
        // A target the parser could not build is already reported as a syntax
        // error; tsc suppresses every semantic diagnostic in such a file, so
        // saying "not a reference" about it would be a pure false positive.
        .error_node, .unsupported => return false,
        else => {
            try c.diagFmt(site.invalidCode(), c.nodeSpan(expr), "{s}", .{site.invalidText()});
            return false;
        },
    }
    if (c.isOptionalChain(node)) {
        try c.diagFmt(site.optionalCode(), c.nodeSpan(expr), "{s}", .{site.optionalText()});
        return false;
    }
    return true;
}

/// `x++` / `--x` WRITES its operand, and tsc types it through `checkExpression`
/// with the node's assignment kind set — so writing an enum/class/function/
/// namespace name, a `const`, an import or a read-only property is refused
/// here exactly as `x = v` refuses it. Answers whether the target was refused.
///
/// The refusal's `errorType` matters twice over: it is what keeps the
/// arithmetic check from piling a TS2356 on top of `E++`, and what keeps the
/// write-back from reporting an unassignable result.
pub fn checkWriteTargetRefused(c: *Checker, target: Node) Error!bool {
    return (try writeTargetType(c, target)) == types.error_type;
}

/// The type a WRITE to `target` stores into, with the refusals above reported:
/// tsc's `checkExpression` on a target whose `getAssignmentTargetKind` is
/// `Definite`, which answers `getTypeOfSymbol` and skips narrowing entirely.
/// That is the difference between `let x: string | number; x = true; for (x of
/// numbers)` reporting nothing (the declared union accepts `number`) and
/// reporting TS2322 against the `boolean` the flow says is there.
///
/// `no_type` when the target is not a reference at all — a pattern or a call
/// — which is somebody else's diagnostic (`checkReferenceExpression`,
/// `checkDestructuringPattern`).
pub fn writeTargetType(c: *Checker, target: Node) Error!TypeId {
    var n = target;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .identifier, .member_expr, .index_expr => {},
        else => return types.no_type,
    }
    return checkAssignmentTarget(c, n);
}

fn incrementOperandType(c: *Checker, operand: Node) Error!TypeId {
    if (try checkWriteTargetRefused(c, operand)) return types.error_type;
    // Otherwise the operand's own value is the READ type, exactly as a
    // compound assignment reads its target before writing it.
    return c.checkExprCached(operand, types.no_type);
}

/// tsc's `checkDeleteExpression` (plus `checkGrammarDeleteExpression`) on an
/// already-checked operand:
///
///   * a bare identifier operand → TS1102, "'delete' cannot be called on an
///     identifier in strict mode". Unconditional here: ztsc is a strict-only
///     checker, so `alwaysStrict` is always in force and tsc's
///     `isEffectiveStrictModeSourceFile` test has one answer. Judged on the
///     operand as WRITTEN, before parentheses are skipped — `delete (x)` is not
///     an identifier operand for tsc either.
///   * anything but a property or element access → TS2703, "must be a property
///     reference", and no further check (tsc returns right there).
///   * a READONLY property → TS2704, "cannot be a read-only property", and not
///     also TS2790: an enum member, `Function.name` and `Symbol.iterator` are
///     each one diagnostic in tsc.
///   * an access whose property is not optional → TS2790, "must be optional".
///     tsc reads the DECLARED type of the resolved property symbol, not the
///     access's narrowed type, so the property is looked up on the receiver
///     rather than taken from the operand's own type. A receiver whose type is
///     not in the node memo is skipped rather than re-checked: re-checking would
///     re-report every diagnostic in its subtree (a `?.` spine's links are typed
///     through `chainObjType`, which does not publish). Sound under-report.
///
/// Both property checks need a property SYMBOL, which is what tsc keys them off
/// (`links.resolvedSymbol`): an index signature standing in for the name is not
/// one, so `delete a.anything` on `{ [s: string]: number }` is silent.
fn checkDeleteOperand(c: *Checker, operand: Node) Error!void {
    if (c.nodeTag(operand) == .identifier) {
        try c.diagFmt(1102, c.nodeSpan(operand), "'delete' cannot be called on an identifier in strict mode.", .{});
    }
    var expr = operand;
    while (c.nodeTag(expr) == .paren_expr) expr = c.tree.nodeData(expr).lhs;
    const tag = c.nodeTag(expr);
    switch (tag) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {},
        else => {
            try c.diagFmt(2703, c.nodeSpan(expr), "The operand of a 'delete' operator must be a property reference.", .{});
            return;
        },
    }
    const ed = c.tree.nodeData(expr);
    // `delete t[i]` on a readonly list is the same write-site refusal as
    // `t[i] = …` (tsc's `checkDeleteExpression` → `checkReferenceExpression`):
    // TS2540 / TS2542.
    if (tag == .index_expr) {
        const recv = try c.resolveStructural(try c.checkExprCached(ed.lhs, types.no_type));
        _ = try readonlyIndexWriteAt(c, recv, expr, ed.rhs);
    }
    const name = (try deleteTargetName(c, expr, tag)) orelse return;
    // `delete i.a` where the name resolves through a readonly string index is
    // the same TS2542 the assignment is — tsc's `checkDeleteExpression` runs
    // `checkReferenceExpression` on the operator's operand whatever its
    // spelling. (The element-access spelling went through the branch above.)
    if (tag == .member_expr) {
        if (c.nodeType(ed.lhs)) |ot| {
            const rt = try c.resolveStructural(try c.nonNullableChain(ot));
            var via_index = false;
            if (try c.propOfTypeViaIndex(rt, name, &via_index)) |_| {
                if (via_index) try reportReadonlyIndexWrite(c, rt, expr, false);
            }
        }
    }
    // A link INSIDE a `?.` spine publishes no node type — `chainObjType` is what
    // types it, and it does not write the memo — so ask that instead of giving
    // up. `delete o.b?.c.d?.e` needs it: the receiver `o.b?.c.d` is two links
    // down a chain. Re-checking cannot double-report; `diagFmt` dedupes on
    // (file, code, span).
    const recv0 = c.nodeType(ed.lhs) orelse
        if (c.isOptionalChain(ed.lhs)) (try chainObjType(c, ed.lhs)).ty else return;
    const recv = try c.resolveStructural(try c.nonNullableChain(recv0));
    // `allow_index = false`: a string INDEX SIGNATURE standing in for the name is
    // not a property symbol, and tsc's checks here are all keyed off
    // `links.resolvedSymbol` — `delete a.anything` on a `{ [s: string]: number }`
    // is silent.
    const p = (try c.propOfTypeEx(recv, name, false)) orelse return;
    // A readonly property is TS2704 INSTEAD of TS2790, not as well as: an enum
    // member, `Function.name`, `Symbol.iterator` are each one diagnostic in tsc.
    if (p.readonly()) {
        try c.diagFmt(2704, c.nodeSpan(expr), "The operand of a 'delete' operator cannot be a read-only property.", .{});
        return;
    }
    if (p.optional()) return;
    // tsc exempts `any`/`unknown`/`never` — nothing is known about whether the
    // property is there to remove.
    switch (c.ts.kind(try c.resolveStructural(p.ty))) {
        .any, .unknown, .never, .err => return,
        else => {},
    }
    if (c.hasUndefinedMember(p.ty)) return;
    try c.diagFmt(2790, c.nodeSpan(expr), "The operand of a 'delete' operator must be optional.", .{});
}

/// The property name a `delete` operand names, or null when it names none tsc
/// resolves a symbol for (a computed or numeric element access — `delete a[i]`
/// carries no property symbol, so tsc runs neither the readonly nor the
/// optionality check on it).
fn deleteTargetName(c: *Checker, expr: Node, tag: ast.Tag) Error!?Atom {
    const ed = c.tree.nodeData(expr);
    if (tag == .member_expr or tag == .optional_member_expr) {
        if (c.tree.tokens.tag(ed.rhs) == .private_identifier) return null;
        return try c.memberAtom(ed.rhs);
    }
    if (c.nodeTag(ed.rhs) != .string_literal) return null;
    return try c.memberAtom(c.tree.nodeMainToken(ed.rhs));
}

/// tsc's `checkPrefixUnaryExpression` opens with a switch on the operand's
/// SYNTAX, not on its type: a numeric literal written directly under `+` or `-`
/// folds to a FRESH literal type of the signed value, and everything else falls
/// through to plain `number`.
///
/// Syntactic is the entire point of the rule, and the reason it cannot be
/// phrased over the operand's type: `let a: 1 = +1` is legal, while `+(1)`,
/// `-(-1)` and `-n` (with `n: 1`) are all `number` and all report. Reading the
/// type instead made the last two silent.
///
/// `-0` normalizes to `0`. tsc interns literal types through a JS `Map`, whose
/// SameValueZero keys do not tell the two apart; ztsc's f64 key does, so
/// `let l: 0 = -0` reported "Type '0' is not assignable to type '0'".
fn signedNumberLiteral(c: *Checker, operand: Node, negate: bool) Error!?TypeId {
    if (c.nodeTag(operand) != .number_literal) return null;
    var v = c.numberTokenValue(c.tree.nodeMainToken(operand));
    if (negate) v = -v;
    if (v == 0) v = 0;
    return try c.ts.makeNumberLiteral(v, true);
}

fn checkPrefixUnary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    switch (op) {
        .keyword_typeof => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return c.typeof_union;
        },
        .bang => {
            const operand_t = try c.checkExprCached(d.lhs, types.no_type);
            try conditions.checkTruthiness(c, d.lhs, operand_t);
            return types.boolean_type;
        },
        .keyword_void => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.undefined_type;
        },
        .keyword_delete => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            try checkDeleteOperand(c, d.lhs);
            return types.boolean_type;
        },
        .keyword_await => {
            // `await` legality: inside a non-async function → TS1308; at the
            // top level of a non-module file → TS1375 (top-level await is
            // otherwise allowed under module: esnext).
            //
            // Judged SYNTACTICALLY, off the enclosing function scope, not off
            // the dynamic `fn_ctx`. tsc reads a parser-assigned
            // `NodeFlags.AwaitContext`, and it has to be a property of where
            // the node is WRITTEN, because an expression can be re-checked
            // from anywhere: resolving `counts` inside `[…].map(t =>
            // counts.length)` re-enters the initializer of
            // `const counts = await db` (a different contextual type, so a
            // different `checkExprCached` key) while `fn_ctx` still describes
            // the ARROW — which is not async, so a correct `await` in the
            // enclosing async method reported TS1308.
            if (c.enclosingFnIsAsync()) |is_async| {
                if (!is_async) {
                    try c.diagFmt(1308, c.nodeSpan(node), "'await' expressions are only allowed within async functions and at the top levels of modules.", .{});
                }
            } else if (c.bind.imports.len == 0 and c.bind.exports.len == 0) {
                try c.diagFmt(1375, c.nodeSpan(node), "'await' expressions are only allowed at the top level of a file when that file is a module, but this file has no imports or exports. Consider adding an empty 'export {{}}' to make this file a module.", .{});
            }
            // `await e`: unwrap `Promise<T>` to `T`; a non-thenable passes
            // through. Single-level only (deeper `Awaited<T>` is a gap).
            //
            // The operand is contextually typed by `T | Promise<T>` — tsc's
            // contextual type for an await operand, the same convention the
            // async-return arm already uses. Checking it context-free left
            // a GENERIC operand's type parameter with no candidate at all,
            // so `const orig: Object = await importOriginal()` (vitest's
            // `<T extends M = M>() => Promise<T>`) took `T`'s DEFAULT
            // rather than `Object`.
            const await_ctx = if (ctx != types.no_type and ctx != types.error_type and
                c.ts.kind(ctx) != .none)
                try c.makeUnion2(ctx, try c.makePromise(ctx))
            else
                types.no_type;
            const ot = try c.checkExprCached(d.lhs, await_ctx);
            return try c.awaitedType(ot);
        },
        .minus => {
            // Unary `-`/`+`/`~` are coercion operators: tsc accepts ANY
            // operand (`-"5"`, `+({})`, `~sn`) — TS2356 is emitted only for
            // `++`/`--` and binary arithmetic, never here (oracle-verified
            // clean for string / string|number / {} operands). Emitting it
            // for `.map((v: string | number) => +v)` was a false positive.
            //
            // A NULLISH operand is still rejected — tsc runs the operand
            // through `checkNonNullType` here (TS18050 / TS18047-9 / TS2531-3)
            // and then computes the result from the ORIGINAL type, so the
            // screen contributes a diagnostic and nothing else.
            const ot = try c.checkExprCached(d.lhs, types.no_type);
            _ = try checkNonNullType(c, ot, d.lhs);
            _ = try reportSymbolOperand(c, node, d.lhs, d.lhs, ot, ot);
            if (try signedNumberLiteral(c, d.lhs, true)) |lit| return lit;
            // tsc's `checkPrefixUnaryExpression` folds a MINUS over a bigint
            // literal into a fresh literal type of its own
            // (`getFreshTypeOfLiteralType(getBigIntLiteralType({ negative:
            // true, … }))`), exactly as it folds one over a numeric literal
            // just above. Without it `let x: -1n = -1n` failed on its own
            // spelling: `-1n` coerced to plain `bigint`.
            if (c.nodeTag(d.lhs) == .bigint_literal) {
                return negatedBigIntLiteral(c, c.tree.nodeMainToken(d.lhs), true);
            }
            // `bigint` only when the operand actually CARRIES a bigint
            // constituent: tsc's getUnaryResultType tests
            // `maybeTypeOfKind(t, BigIntLike)`, not assignability, so the
            // types that are vacuously assignable to bigint — `never`
            // (no constituents) and `any` — coerce to `number` like every
            // other non-bigint operand. `isBigintish` is the assignability
            // test, so exclude the operands that are equally numberish;
            // this mirrors the binary `-`/`*` arm below.
            if (try isBigintish(c, ot) and !try isNumberish(c, ot)) return types.bigint_type;
            return types.number_type;
        },
        .plus, .tilde => {
            const ot = try c.checkExprCached(d.lhs, types.no_type);
            _ = try checkNonNullType(c, ot, d.lhs);
            _ = try reportSymbolOperand(c, node, d.lhs, d.lhs, ot, ot);
            // `~` coerces unconditionally; unary `+` folds a literal operand
            // exactly as `-` does.
            if (op == .plus) {
                if (try signedNumberLiteral(c, d.lhs, false)) |lit| return lit;
            }
            return types.number_type;
        },
        .plus_plus, .minus_minus => {
            const ot = try incrementOperandType(c, d.lhs);
            // tsc runs the reference check only when the operand TYPED as a
            // valid arithmetic operand, to avoid cascading off one operand.
            if (try checkArithmeticOperand(c, try checkNonNullType(c, ot, d.lhs), d.lhs)) {
                _ = try checkReferenceExpression(c, d.lhs, .increment);
            }
            return types.number_type;
        },
        else => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.any_type;
        },
    }
}

fn isNumberish(c: *Checker, t: TypeId) Error!bool {
    return hasPrimitiveFacet(c, t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return switch (ch.ts.kind(m)) {
                .number, .number_literal, .number_literal_fresh, .any, .err, .never => true,
                .enum_type => !ch.enumHasStringMember(ch.ts.enumSymbol(m)),
                else => false,
            };
        }
    }.f, 0);
}

fn isBigintish(c: *Checker, t: TypeId) Error!bool {
    return hasPrimitiveFacet(c, t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return switch (ch.ts.kind(m)) {
                .bigint, .bigint_literal, .any, .err, .never => true,
                else => false,
            };
        }
    }.f, 0);
}

fn isStringish(c: *Checker, t: TypeId) Error!bool {
    return hasPrimitiveFacet(c, t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return switch (ch.ts.kind(m)) {
                .string, .string_literal, .any, .err, .never => true,
                .enum_type => ch.enumHasStringMember(ch.ts.enumSymbol(m)),
                else => false,
            };
        }
    }.f, 0);
}

/// Does `t` carry the primitive facet tested by `f`? tsc classifies
/// operands of arithmetic / relational / `+` expressions by assignability
/// to the primitive (`isTypeAssignableToKind`), so the test looks through
/// exactly what assignability looks through: a union qualifies when EVERY
/// constituent does, an intersection when ANY constituent does — a branded
/// `number & { _brand: "radian" }` IS a number for arithmetic — an alias
/// `.ref` through its expansion, and a type parameter through its
/// constraint. Each composite is first scanned with the leaf test alone —
/// that settles the common shapes (`number | number`, `number & {brand}`)
/// without touching the allocator; only the recursive fallback copies the
/// members to scratch, because expanding a ref mid-iteration can intern a
/// type and invalidate the store slice.
fn hasPrimitiveFacet(c: *Checker, t: TypeId, comptime f: fn (*Checker, TypeId) bool, depth: u32) Error!bool {
    if (f(c, t)) return true;
    if (depth > 8) return false;
    switch (c.ts.kind(t)) {
        .union_type => {
            const n = c.ts.memberCount(t);
            if (n == 0) return false;
            var all = true;
            for (0..n) |i| {
                if (!f(c, c.ts.memberAt(t, i))) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
            for (try c.memberList(t)) |m| {
                if (!try hasPrimitiveFacet(c, m, f, depth + 1)) return false;
            }
            return true;
        },
        .intersection => {
            for (0..c.ts.memberCount(t)) |i| {
                if (f(c, c.ts.memberAt(t, i))) return true;
            }
            for (try c.memberList(t)) |m| {
                if (try hasPrimitiveFacet(c, m, f, depth + 1)) return true;
            }
            return false;
        },
        .ref => {
            const rs = try c.resolveStructural(t);
            if (rs == t) return false;
            return hasPrimitiveFacet(c, rs, f, depth + 1);
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
            if (con == types.no_type or con == t) return false;
            return hasPrimitiveFacet(c, con, f, depth + 1);
        },
        // …and a deferred indexed access through its apparent type, the same
        // step one kind over. `this.testy[key] += 1` inside `class Test<T
        // extends Record<string, number>>` is `T[keyof T] += 1`, whose
        // apparent type is `number`: tsc types the operands fine and reports
        // only the write-back (TS2322). Without the arm the access matched
        // nothing and the operand itself was a phantom TS2365.
        .index_access => {
            const bc = (try props_zig.indexAccessApparent(c, t)) orelse return false;
            return hasPrimitiveFacet(c, bc, f, depth + 1);
        },
        else => return false,
    }
}

fn isArithmeticOperand(c: *Checker, t: TypeId) Error!bool {
    return (try isNumberish(c, t)) or (try isBigintish(c, t));
}

/// tsc's `maybeTypeOfKindConsideringBaseConstraint(t, ESSymbolLike)`: does ANY
/// constituent of `t` — or of its base constraint, which is what catches
/// `S extends symbol` — carry `symbol` or a `unique symbol`?
fn maybeSymbolish(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return false;
    switch (c.ts.kind(t)) {
        .symbol, .unique_symbol => return true,
        .union_type, .intersection => {},
        .ref => {
            const rs = try c.resolveStructural(t);
            if (rs == t) return false;
            return maybeSymbolish(c, rs, depth + 1);
        },
        .type_param => {
            const con = try c.baseConstraintOf(t);
            if (con == t or con == types.no_type) return false;
            return maybeSymbolish(c, con, depth + 1);
        },
        else => return false,
    }
    // This runs on EVERY `+`, `+=` and relational comparison, so the composite
    // arm scans its members with the leaf test alone first — that settles
    // `string | undefined` and friends without copying the member slice to
    // scratch, exactly as `hasPrimitiveFacet` does.
    var nested = false;
    for (0..c.ts.memberCount(t)) |i| {
        switch (c.ts.kind(c.ts.memberAt(t, i))) {
            .symbol, .unique_symbol => return true,
            .union_type, .intersection, .ref, .type_param => nested = true,
            else => {},
        }
    }
    if (!nested) return false;
    for (try c.memberList(t)) |m| {
        if (try maybeSymbolish(c, m, depth + 1)) return true;
    }
    return false;
}

/// tsc's `checkForDisallowedESSymbolOperand`: "symbols are not allowed at all
/// in arithmetic expressions" — TS2469, reported at the FIRST offending
/// operand and naming the operator as written (`+=`, not `+`). Answers whether
/// it reported, which is what stops the caller from also running its own
/// comparability check or a compound assignment's write-back.
fn reportSymbolOperand(c: *Checker, node: Node, lhs: Node, rhs: Node, lt: TypeId, rt: TypeId) Error!bool {
    const offending: Node = if (try maybeSymbolish(c, lt, 0))
        lhs
    else if (try maybeSymbolish(c, rt, 0))
        rhs
    else
        return false;
    try c.diagFmt(2469, c.nodeSpan(offending), "The '{s}' operator cannot be applied to type 'symbol'.", .{
        c.tokenText(c.tree.nodeMainToken(node)),
    });
    return true;
}

/// Answers whether the operand passed — tsc's `checkArithmeticOperandType`
/// return value gates the reference check that follows it.
fn checkArithmeticOperand(c: *Checker, t: TypeId, node: Node) Error!bool {
    if (try isArithmeticOperand(c, t)) return true;
    try c.diagFmt(2356, c.nodeSpan(node), "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.", .{});
    return false;
}

/// TS2358 gate: tsc refuses an `instanceof` left operand every constituent of
/// which is a PRIMITIVE (`allTypesAssignableToKind(leftType, TypeFlags.
/// Primitive)`) — nothing that is not an object can be an instance of
/// anything. `any` and `unknown` are exempt (the related error was already
/// reported elsewhere), and so is `never`, which tsc technically refuses via
/// vacuous assignability but which only ever arrives here already reported.
///
/// A type parameter answers through its CONSTRAINT — tsc's kind test is
/// assignability-based, so `T extends string` is refused while a bare `T` is
/// not — a union iff every constituent is primitive, and an intersection iff
/// ANY is (a branded `number & { _brand }` is still a number).
fn instanceofLhsIsPrimitive(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return false; // give up conservatively — never over-report
    switch (c.ts.kind(t)) {
        .void,
        .undefined,
        .null,
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .bool_true,
        .bool_false,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .enum_type,
        .unique_symbol,
        .template_literal_type,
        .string_mapping,
        => return true,
        .union_type => {
            for (try c.memberList(t)) |m| {
                if (!try instanceofLhsIsPrimitive(c, m, depth + 1)) return false;
            }
            return c.ts.memberCount(t) != 0;
        },
        .intersection => {
            for (try c.memberList(t)) |m| {
                if (try instanceofLhsIsPrimitive(c, m, depth + 1)) return true;
            }
            return false;
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
            if (con == types.no_type or con == t) return false;
            return instanceofLhsIsPrimitive(c, con, depth + 1);
        },
        .ref => {
            const rs = try c.resolveStructural(t);
            if (rs == t) return false;
            return instanceofLhsIsPrimitive(c, rs, depth + 1);
        },
        else => return false,
    }
}

/// TS2359 gate: is `t` a valid `instanceof` right-hand side — i.e. `any`,
/// or a type assignable to the `Function` interface? tsc accepts any type
/// that carries a call or construct signature (constructor interfaces like
/// `ErrorConstructor`/`RegExpConstructor` behind the `Error`/`RegExp`
/// value globals, plain function types, class constructors), or that
/// declares a `[Symbol.hasInstance]` method. Refs are resolved structurally
/// so a value typed as a constructor interface is recognized; a union is
/// valid iff every constituent is, an intersection iff any is, and a
/// type-parameter defers to its constraint.
fn instanceofRhsIsFunctionLike(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true; // give up conservatively — never over-report
    switch (c.ts.kind(t)) {
        .any, .err, .function, .overloads, .class_value => return true,
        else => {},
    }
    const rs = try c.resolveStructural(t);
    switch (c.ts.kind(rs)) {
        .any, .err, .function, .overloads, .class_value => return true,
        .object => {
            if (c.ts.objectHasSigs(rs)) return true;
            // A plain object with a `[Symbol.hasInstance]` method is a
            // legal RHS (tsc), even without call/construct signatures.
            if (c.ts.objectPropByName(rs, try c.atom("__@hasInstance")) != null) return true;
            return false;
        },
        .union_type => {
            for (try c.memberList(rs)) |m| {
                if (!try instanceofRhsIsFunctionLike(c, m, depth + 1)) return false;
            }
            return true;
        },
        .intersection => {
            for (try c.memberList(rs)) |m| {
                if (try instanceofRhsIsFunctionLike(c, m, depth + 1)) return true;
            }
            return false;
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rs));
            if (con == types.no_type or con == rs or con == t) return false;
            return instanceofRhsIsFunctionLike(c, con, depth + 1);
        },
        else => return false,
    }
}

fn checkBinary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    switch (op) {
        // A guard that cannot fail contributes no union: tsc consults
        // `getTypeFacts` on the left operand first and returns its type
        // outright when the right operand is unreachable. `x || {}` where
        // `x` is an object type is `x` — not `x | {}`, which is how a
        // fallback written for a nullable case that no longer exists ends
        // up in the type of every use of the result.
        .amp_amp => {
            // The right operand joins the enclosing `&&` chain for the whole of
            // the left operand's walk: it is what excuses `f && f()` and, one
            // level up, `f && 1 && f()` (see `conditions.CondWalk`).
            const body = conditions.bodyFor(c, node);
            const saved = try conditions.enterLogical(c, node, true);
            defer conditions.leaveLogical(c, saved);
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            try conditions.checkTruthiness(c, d.lhs, lt);
            // tsc checks the LEFT operand of every `&&` for the always-defined
            // mistakes, wherever the expression sits — `f && log()` as a bare
            // statement is the shape the check was written for.
            try conditions.checkUncalledFunction(c, d.lhs, lt, body, true);
            conditions.leaveLeftOperand(c, node, saved);
            const rt = try c.checkExprCached(d.rhs, ctx);
            const falsy = try c.getFalsyPart(lt, false);
            if (try c.getTruthyPart(lt) == types.never_type) return lt;
            return c.logicalUnion(falsy, rt);
        },
        // `||` and `??` hand their RIGHT operand the LEFT operand's type as
        // its contextual type when the expression has none of its own
        // (tsc's `getContextualTypeForBinaryOperand`). A fallback is written
        // to stand in for the thing on the left, so the thing on the left is
        // what shapes it: `last || { type: "selection" }` keeps the literal
        // `"selection"` because `last`'s `type` admits it. Without the
        // context the property widens to `string`, the fallback becomes a
        // SUPERTYPE of the left operand, and the union reduction that
        // follows collapses the whole expression into it — losing every
        // property the left operand had. `&&` is asymmetric here (tsc
        // forwards only an outer contextual type to its right operand)
        // because its right operand is not a stand-in for its left.
        // `||` and `??` do not judge their own operands (tsc hooks only `&&`),
        // but they still take part in the bookkeeping: a chain BARRIER for the
        // left operand's subtree, and a link in the guarded body's closure.
        .pipe_pipe => {
            const saved = try conditions.enterLogical(c, node, false);
            defer conditions.leaveLogical(c, saved);
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            try conditions.checkTruthiness(c, d.lhs, lt);
            conditions.leaveLeftOperand(c, node, saved);
            const rt = try c.checkExprCached(d.rhs, if (ctx == types.no_type) lt else ctx);
            const truthy = try c.getTruthyPart(lt);
            if (!try c.canBeFalsy(lt, 0)) return lt;
            return c.logicalUnion(truthy, rt);
        },
        .question_question => {
            const saved = try conditions.enterLogical(c, node, false);
            defer conditions.leaveLogical(c, saved);
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            try conditions.checkNeverNullish(c, d.lhs);
            conditions.leaveLeftOperand(c, node, saved);
            const rt = try c.checkExprCached(d.rhs, if (ctx == types.no_type) lt else ctx);
            if (!try c.canBeNullish(lt, 0)) return lt;
            return c.logicalUnion(try c.nonNullableNullish(lt), rt);
        },
        .plus => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            return (try checkPlusOperands(c, node, lt, rt, d.lhs, d.rhs)).ty;
        },
        .minus, .asterisk, .slash, .percent, .asterisk_asterisk, .lt_lt, .gt_gt, .gt_gt_gt, .amp, .pipe, .caret => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            return (try checkArithmeticOperands(c, node, op, lt, rt, d.lhs, d.rhs)).ty;
        },
        .lt, .gt, .lt_eq, .gt_eq => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            // A `symbol` operand is refused outright, and tsc runs NONE of the
            // comparison checks below when it reports.
            if (try reportSymbolOperand(c, node, d.lhs, d.rhs, lt, rt)) return types.boolean_type;
            // tsc's relational rule (checkBinaryLikeExpressionWorker): strip
            // null/undefined (checkNonNullType), then the pair is legal iff
            // BOTH sides are number/bigint-like, OR NEITHER side is
            // number-like and one is comparable to the other. The
            // "neither number-like" guard is essential: it rejects
            // `{valueOf():number} > number` even though `number` is
            // assignable to `{valueOf():number}` (oracle-verified), while
            // still admitting `Date > Date`, `string > string`, and any two
            // structurally-comparable object types.
            //
            // The strip is the REPORTING `checkNonNullType` — `null < 1` is a
            // TS18050 on the operand, not a TS2365 on the pair — and what
            // survives it is widened with `getBaseTypeOfLiteralType`, which
            // is both the classification tsc applies and the type it NAMES:
            // `"a" > 1` reads "types 'string' and 'number'", never
            // "types '\"a\"' and 'number'".
            // A bare type parameter is left EXACTLY as it is: tsc names it
            // `T` in the message (never `{} & T`) and `relationalComparable`
            // relates it through its constraint the way tsc's comparable
            // relation does, so nothing here has to synthesize an apparent
            // type for it.
            const ls = try baseOfLiteralType(c, try checkNonNullType(c, lt, d.lhs));
            const rs = try baseOfLiteralType(c, try checkNonNullType(c, rt, d.rhs));
            const lk = c.ts.kind(ls);
            const rk = c.ts.kind(rs);
            const ok = lk == .any or rk == .any or lk == .err or rk == .err or blk: {
                const lnum = try isNumberish(c, ls) or try isBigintish(c, ls);
                const rnum = try isNumberish(c, rs) or try isBigintish(c, rs);
                if (lnum and rnum) break :blk true;
                if (!lnum and !rnum) break :blk (try c.relationalComparable(ls, rs));
                break :blk false;
            };
            if (!ok) {
                try c.diagFmt(2365, c.nodeSpan(node), "Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{
                    c.tokenText(c.tree.nodeMainToken(node)), try c.typeToString(ls), try c.typeToString(rs),
                });
            }
            return types.boolean_type;
        },
        .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            try conditions.checkNaNEquality(c, node, d.lhs, d.rhs);
            // TS2367: no overlap (any union constituents comparable).
            if (!try c.typesHaveOverlap(lt, rt)) {
                try c.diagFmt(2367, c.nodeSpan(node), "This comparison appears to be unintentional because the types '{s}' and '{s}' have no overlap.", .{
                    try c.typeToString(lt), try c.typeToString(rt),
                });
            }
            return types.boolean_type;
        },
        .keyword_instanceof => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            if (try instanceofLhsIsPrimitive(c, lt, 0)) {
                try c.diagFmt(2358, c.nodeSpan(d.lhs), "The left-hand side of an 'instanceof' expression must be of type 'any', an object type or a type parameter.", .{});
            }
            if (!try instanceofRhsIsFunctionLike(c, rt, 0)) {
                try c.diagFmt(2359, c.nodeSpan(d.rhs), "The right-hand side of an 'instanceof' expression must be of type 'any' or of a type assignable to the 'Function' interface type.", .{});
            }
            return types.boolean_type;
        },
        .keyword_in => {
            const lt0 = try c.checkExprCached(d.lhs, types.no_type);
            const rt0 = try c.checkExprCached(d.rhs, types.no_type);
            // Both operands are screened for `null`/`undefined` first, like
            // every other non-nullable position (tsc's `checkInExpression`).
            const lt = try checkNonNullType(c, lt0, d.lhs);
            const rt = try checkNonNullType(c, rt0, d.rhs);
            // tsc's `checkInExpression` relates the left operand to
            // `string | number | symbol` as a WHOLE, rather than asking
            // whether it carries one primitive facet. The difference is a
            // key type that is only collectively key-like: a deferred
            // `keyof R`, or a `K[number]` over `K extends readonly
            // (keyof R)[]`, is assignable to that union while matching no
            // single facet. The relation also carries the diagnostic —
            // TS2322 naming both types, not the old flat TS2360.
            const key_union = try c.ts.makeUnion(c.scratch(), &.{ types.string_type, types.number_type, types.symbol_type });
            _ = try c.checkAssignable(lt, key_union, d.lhs, c.nodeSpan(d.lhs));
            // …and the RIGHT operand is related to `object` the same way,
            // which is the whole of tsc's test: `isTypeAssignableTo(rightType,
            // nonPrimitiveType)`, carrying its own TS2322 rather than the flat
            // TS2361 an older tsc reported. Relating instead of testing KINDS
            // is what reaches the generic operands — `<T>(t: T) => "k" in t` is
            // an error because `T`'s constraint admits primitives, and
            // `<T extends object>` is not — and what makes `never` (which
            // ordinary narrowing produces: social-app's `typeof icon ===
            // 'object' && icon && 'render' in icon` over `ComponentType<any> |
            // ReactElement` reaches it) silent for free.
            _ = try c.checkAssignable(rt, types.object_keyword_type, d.rhs, c.nodeSpan(d.rhs));
            return types.boolean_type;
        },
        else => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            _ = try c.checkExprCached(d.rhs, types.no_type);
            return types.any_type;
        },
    }
}

/// An `obj.m = function () {…}` assignment, whose value tsc's
/// `getContextualThisParameterType` lends `obj` as its `this` — the idiom that
/// makes `Element.prototype.remove ??= function () { this.parentNode }` legal
/// instead of TS2683. Null when the shape does not match: the target must be a
/// property/element ACCESS and the value a plain function expression, since an
/// arrow has no `this` of its own. Parentheses around the value are walked
/// through, as tsc's `walkUpParenthesizedExpressions` does.
///
/// The `this_bound_fns` marking is why this is `pub`: it has to run wherever
/// the right-hand side is TYPED, not only where the assignment is checked. The
/// EXPANDO member pass walks the same function on its own
/// (`signatures.expandoMemberType`), and the node-type memo means whichever
/// route gets there first is the one the body's `this` saw.
///
/// Only the "has a receiver" fact is recorded, not the receiver's TYPE: asking
/// for it is what tsc does, but `F.m = function () { return this }` would then
/// resolve `this` through the very symbol whose expando type is being built,
/// and the cycle answers `never`. `this` stays `any` — an under-report on the
/// type, never a diagnostic.
pub fn markAssignedMethodFn(c: *Checker, target: Node, value0: Node) Error!void {
    var value = value0;
    while (value != null_node and c.nodeTag(value) == .paren_expr) value = c.tree.nodeData(value).lhs;
    if (value == null_node or c.nodeTag(value) != .function_expr) return;
    switch (c.nodeTag(target)) {
        .member_expr, .index_expr => {},
        else => return,
    }
    if (c.tree.nodeData(target).lhs == null_node) return;
    try markThisBound(c, value);
}

/// A compound assignment's left operand as tsc's `checkExpression(left)` sees
/// it: the target READ, not the target WRITE. The two differ wherever a
/// property has a wider setter than getter (`get x(): number` / `set x(v:
/// number | undefined)`) and wherever the flow has narrowed the target (`if
/// (this.z) this.z += dz`), and reading the write type there rejected code tsc
/// accepts. Re-checking `target` as an expression cannot double-report:
/// `diagFmt` dedupes on (file, code, span).
fn readOfAssignTarget(c: *Checker, target: Node) Error!TypeId {
    const saved_write_target = c.write_target_node;
    c.write_target_node = c.nodeKey(target);
    defer c.write_target_node = saved_write_target;
    return c.checkExprCached(target, types.no_type);
}

fn checkAssignExpr(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    // A destructuring assignment is not an ordinary one: tsc's
    // `checkBinaryLikeExpression` diverts `=` with a pattern on the left to
    // `checkDestructuringAssignment`, which checks the RIGHT side first and
    // with NO contextual type (the pattern is not a type), resolves every
    // element against that source type, and answers the source type as the
    // expression's own. No whole-pattern assignability check runs — the
    // per-element lookups are the check.
    if (op == .eq and isDestructuringPattern(c, d.lhs)) {
        const src = try c.checkExprCached(d.rhs, types.no_type);
        // …with one thing the pattern IS a type for: it is the right
        // operand's contextual type (`getContextualTypeForBinaryOperand`
        // answers `getTypeOfExpression(left)`), and a pattern-shaped
        // contextual type makes every member of the right-hand literal it
        // does not name TS2353. Raised here rather than from inside the
        // literal's own check, since ztsc does not hand the pattern down as a
        // contextual type — nothing else about the right side depends on it.
        try checkAssignPatternExcessProps(c, d.lhs, d.rhs);
        try checkDestructuringPattern(c, d.lhs, src);
        return src;
    }
    const target_t = try checkAssignmentTarget(c, d.lhs);
    // tsc's `checkAssignmentOperator` runs `checkReferenceExpression` on the
    // target and only checks assignability when it passes, so an illegal
    // target (`f() = 1`, `a?.b = 1`) reports ONE diagnostic, not a TS2322 on
    // top of it.
    const is_ref = try checkReferenceExpression(c, d.lhs, .assignment);
    // Writing an evolving (`auto`-typed) variable is unchecked: its
    // `null`/`undefined` declared type is where the flow type starts, not
    // a constraint on what may be stored (tsc's autoType). The type itself
    // is still what `checkAssignmentTarget` returned, so `+=` classifies
    // the operand the same way it would for any other declared type.
    const unchecked = assignTargetIsEvolving(c, d.lhs);
    var rhs_ctx: TypeId = if (op == .eq) target_t else types.no_type;
    if (target_t == types.error_type or unchecked) rhs_ctx = types.no_type;
    // `&&=`, `||=`, `??=` are the LOGICAL assignments: unlike `+=` they do not
    // synthesize a value from both operands, they answer one operand or the
    // other, so tsc's `checkBinaryLikeExpressionWorker` computes their result
    // from the very code `&&`/`||`/`??` use. That needs the left operand's
    // READ type up front — before the right operand, which it also
    // contextually types (`getContextualTypeForAssignmentDeclaration` answers
    // `getTypeOfExpression(left)` for an ordinary target, which is why
    // `f ??= (a => a)` infers `a: number` from `f`'s signature instead of
    // reporting TS7006).
    const logical_lt: TypeId = switch (op) {
        .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => if (target_t == types.error_type)
            types.error_type
        else
            try readOfAssignTarget(c, d.lhs),
        else => types.no_type,
    };
    if (logical_lt != types.no_type and logical_lt != types.error_type) rhs_ctx = logical_lt;
    // tsc's `getContextualThisParameterType`, last arm: in `obj.m = function
    // () {…}` (any assignment operator) the function has a receiver — `obj` —
    // so a `this` in its body is not TS2683. A contextual signature with a
    // `this` parameter of its own already won inside `checkFunctionLikeExpr`.
    try markAssignedMethodFn(c, d.lhs, d.rhs);
    const rt = try c.checkExprCached(d.rhs, rhs_ctx);
    switch (op) {
        .eq => {
            if (is_ref and !unchecked and target_t != types.error_type and target_t != types.any_type) {
                _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
            }
            return rt;
        },
        .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => {
            // tsc's `checkAssignmentOperator(rightType)`: the RIGHT operand is
            // what gets stored, so it alone is related to the write type.
            if (is_ref and !unchecked and target_t != types.error_type and target_t != types.any_type) {
                _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
            }
            if (logical_lt == types.error_type) return rt;
            // …but the expression's VALUE is the operator's, computed exactly
            // as `&&`/`||`/`??` compute theirs. `results &&= xs` therefore
            // still admits `undefined` (the left operand's falsy part
            // survives — TS2532 on `(results &&= xs).push(…)`), while
            // `x ??= 1` over `0 | 1 | 2 | 3` answers the whole union rather
            // than the literal `1` that the right operand alone would give.
            switch (op) {
                .pipe_pipe_eq => {
                    if (!try c.canBeFalsy(logical_lt, 0)) return logical_lt;
                    return c.logicalUnion(try c.getTruthyPart(logical_lt), rt);
                },
                .amp_amp_eq => {
                    const falsy = try c.getFalsyPart(logical_lt, false);
                    if (try c.getTruthyPart(logical_lt) == types.never_type) return logical_lt;
                    return c.logicalUnion(falsy, rt);
                },
                else => {
                    if (!try c.canBeNullish(logical_lt, 0)) return logical_lt;
                    return c.logicalUnion(try c.nonNullableNullish(logical_lt), rt);
                },
            }
        },
        // `+=`, `-=`, `*=`, … : the operation's RESULT is what gets stored,
        // so tsc runs the same assignability check `=` runs, with the
        // operator's result type as the source (`checkAssignmentOperator`
        // with the value type computed by `checkBinaryLikeExpressionWorker`).
        // `x += 1` on a branded `number & { _brand }` therefore fails the
        // same way `x = x + 1` does: the operation widens to `number`.
        //
        // The operation itself is checked by the very code its binary form
        // uses (tsc runs one `checkBinaryLikeExpressionWorker` for `*` and
        // `*=` alike), so `x1 *= {}` reports the same TS2362/TS2363 on its
        // operands that `x1 * {}` does, and `b |= b` the same TS2447.
        else => {
            const read_t = if (target_t == types.error_type)
                types.error_type
            else
                try readOfAssignTarget(c, d.lhs);
            const lt = try baseOfLiteralType(c, read_t);
            const res = if (op == .plus_eq)
                try checkPlusOperands(c, node, lt, rt, d.lhs, d.rhs)
            else
                try checkArithmeticOperands(c, node, op, lt, rt, d.lhs, d.rhs);
            // A reported operand means tsc never reaches the write-back
            // (`if (leftOk && rightOk) checkAssignmentOperator(resultType)`),
            // so the operand diagnostic is never doubled by a TS2322.
            if (res.ok and is_ref and !unchecked and target_t != types.error_type and target_t != types.any_type) {
                // No expression node: the source type is synthesized by the
                // operator, so there is no literal to elaborate or excess-check.
                _ = try c.checkAssignable(res.ty, try baseOfLiteralType(c, target_t), null_node, c.nodeSpan(d.lhs));
            }
            return res.ty;
        },
    }
}

/// What an operator arm computed: the expression's type, and whether both
/// operands passed. A compound assignment needs the second half — tsc runs
/// its write-back assignability check only when neither operand was
/// reported.
const OperandCheck = struct { ty: TypeId, ok: bool };

/// tsc's `checkBinaryLikeExpressionWorker` for `+` / `+=`.
///
/// The nullish screen runs only when NEITHER side is string-like: `null +
/// "a"` is a legal concatenation, so the null operand is never reported
/// there, while `null + 1` is TS18050 on the operand rather than TS2365 on
/// the pair.
fn checkPlusOperands(c: *Checker, node: Node, lt0: TypeId, rt0: TypeId, lhs: Node, rhs: Node) Error!OperandCheck {
    var lt = lt0;
    var rt = rt0;
    if (!try isStringish(c, lt) and !try isStringish(c, rt)) {
        lt = try checkNonNullType(c, lt, lhs);
        rt = try checkNonNullType(c, rt, rhs);
    }
    const lk = c.ts.kind(lt);
    const rk = c.ts.kind(rt);
    // `any` first: tsc reaches its string result through STRICT
    // assignability (`isTypeAssignableToKind(t, StringLike, true)`), which
    // `any` fails, and lands on the `isTypeAny` arm instead. Reading `any`
    // as string-like retyped every evolving `var a; a += n` as `string`, and
    // every later `a << 1` became a spurious TS2362.
    // Whichever arm answers, tsc screens the pair for a `symbol` operand
    // (TS2469) before handing the result back — the RESULT type still stands,
    // but a `+=`'s write-back is skipped, which is what `ok` carries.
    if (lk == .any or rk == .any or lk == .err or rk == .err)
        return .{ .ty = types.any_type, .ok = !try reportSymbolOperand(c, node, lhs, rhs, lt, rt) };
    // string + anything stringifiable
    if (try isStringish(c, lt) or try isStringish(c, rt))
        return .{ .ty = types.string_type, .ok = !try reportSymbolOperand(c, node, lhs, rhs, lt, rt) };
    if (try isNumberish(c, lt) and try isNumberish(c, rt))
        return .{ .ty = types.number_type, .ok = !try reportSymbolOperand(c, node, lhs, rhs, lt, rt) };
    if (try isBigintish(c, lt) and try isBigintish(c, rt))
        return .{ .ty = types.bigint_type, .ok = !try reportSymbolOperand(c, node, lhs, rhs, lt, rt) };
    try c.diagFmt(2365, c.nodeSpan(node), "Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{
        c.tokenText(c.tree.nodeMainToken(node)), try c.typeToString(lt), try c.typeToString(rt),
    });
    return .{ .ty = types.error_type, .ok = false };
}

/// tsc's `checkBinaryLikeExpressionWorker` for the arithmetic operators
/// (`- * / % ** << >> >>> & | ^`) and their compound forms. Both operands
/// are screened for `null`/`undefined` first, and the screen REPLACES the
/// operand diagnostic: a purely nullish operand degrades to the error type,
/// which every arithmetic classification accepts, so `null * 1` is one
/// TS18050 rather than a TS2362.
fn checkArithmeticOperands(c: *Checker, node: Node, op: scanner.Tag, lt0: TypeId, rt0: TypeId, lhs: Node, rhs: Node) Error!OperandCheck {
    const lt = try checkNonNullType(c, lt0, lhs);
    const rt = try checkNonNullType(c, rt0, rhs);
    // `|`, `&`, `^` (and `|=`, `&=`, `^=`) between two booleans is almost
    // always a typo for the logical operator, and tsc says so INSTEAD of
    // rejecting the operands: one TS2447 on the operator token, no
    // TS2362/TS2363, and a `number` result.
    if (suggestedBooleanOperator(op)) |suggested| {
        if (isBooleanLike(c, lt) and isBooleanLike(c, rt)) {
            const tok = c.tree.nodeMainToken(node);
            try c.diagFmt(2447, c.tokSpan(tok), "The '{s}' operator is not allowed for boolean types. Consider using '{s}' instead.", .{
                c.tokenText(tok), suggested,
            });
            return .{ .ty = types.number_type, .ok = false };
        }
    }
    var ok = true;
    if (!try isArithmeticOperand(c, lt)) {
        ok = false;
        try c.diagFmt(2362, c.nodeSpan(lhs), "The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
    }
    if (!try isArithmeticOperand(c, rt)) {
        ok = false;
        try c.diagFmt(2363, c.nodeSpan(rhs), "The right-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
    }
    // tsc's bigint dispatch (`checkBinaryLikeExpressionWorker`): `bigint` when
    // both sides are bigint-like, `number` when neither could be — and when
    // EXACTLY ONE is, the operator itself is the error
    // (`reportOperatorError(bothAreBigIntLike)`), with `errorType` as the
    // result so no write-back check runs. Without that arm `bigInt -= 2`
    // silently produced `number` and the write-back reported a TS2322 where
    // tsgo reports the TS2365 on the pair — ten of them in
    // `numberVsBigIntOperations`. `any`/`err`/`never` answer true to BOTH
    // predicates, so requiring `!num` on the bigint side and `!big` on the
    // other keeps them out of the error arm entirely.
    const l_big = try isBigintish(c, lt);
    const r_big = try isBigintish(c, rt);
    // Neither side could be a bigint — every ordinary arithmetic expression —
    // so nothing below can change the answer and the two `isNumberish` walks
    // are never paid for.
    if (!l_big and !r_big) return .{ .ty = types.number_type, .ok = ok };
    const l_num = try isNumberish(c, lt);
    const r_num = try isNumberish(c, rt);
    if (l_big and r_big and !l_num and !r_num) return .{ .ty = types.bigint_type, .ok = ok };
    if (ok and ((l_big and !l_num and r_num and !r_big) or (r_big and !r_num and l_num and !l_big))) {
        try c.diagFmt(2365, c.nodeSpan(node), "Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{
            c.tokenText(c.tree.nodeMainToken(node)), try c.typeToString(lt), try c.typeToString(rt),
        });
        return .{ .ty = types.error_type, .ok = false };
    }
    return .{ .ty = types.number_type, .ok = ok };
}

/// The logical operator tsc suggests in TS2447 for a bitwise operator
/// applied to two booleans (`getSuggestedBooleanOperator`), or null for
/// every other operator.
fn suggestedBooleanOperator(op: scanner.Tag) ?[]const u8 {
    return switch (op) {
        .pipe, .pipe_eq => "||",
        .amp, .amp_eq => "&&",
        .caret, .caret_eq => "!==",
        else => null,
    };
}

/// tsc's `TypeFlags.BooleanLike` — a flag test, not assignability, so a
/// union like `boolean | undefined` is deliberately not boolean-like here.
fn isBooleanLike(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .boolean, .bool_true, .bool_false => true,
        else => false,
    };
}

/// tsc's `getBaseTypeOfLiteralType`, mapped over a union. Only literal,
/// enum-member and boolean-literal types widen; a branded
/// `number & { _brand }` is not a literal type and stays exactly as
/// declared.
///
/// Two positions need it. A compound assignment's TARGET reads (and is
/// written back) as its base type — `checkIdentifier` returns
/// `getBaseTypeOfLiteralType(flowType)` for a reference in assignment-target
/// position — which is what makes `let d: -1 | 1 = 1; d *= -1` and
/// `let s: "a" | "b"; s += "x"` legal while `mv += 1` on a branded number
/// still fails. A relational operand is widened the same way, so `"a" > 1`
/// is classified as (and REPORTED as) `string` against `number`.
fn baseOfLiteralType(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var list: std.ArrayList(TypeId) = .empty;
        defer list.deinit(c.scratch());
        var changed = false;
        for (try c.memberList(t)) |m| {
            const b = try baseOfLiteralType(c, m);
            if (b != m) changed = true;
            try list.append(c.scratch(), b);
        }
        if (!changed) return t;
        return c.ts.makeUnion(c.scratch(), list.items);
    }
    const base = try c.literalBaseOf(t);
    return if (base != types.no_type) base else t;
}

/// One implicit-'any' ELEMENT ACCESS report, TS7052 or TS7053.
///
/// tsc's `getSuggestionForNonexistentIndexSignature`: an object that carries a
/// `get`/`set` METHOD taking this very key is a map-like meant to be CALLED,
/// not indexed, and tsc says so with its own code —
/// "Element implicitly has an 'any' type because type 'T' has no index
/// signature. Did you mean to call 'x.get'?" (TS7052). Everything else is the
/// generic TS7053. Both are gated on `noImplicitAny`; the access types as
/// `any` either way.
pub fn reportIndexImplicitAny(c: *Checker, node: Node, recv: Node, idx_t: TypeId, obj_t: TypeId) Error!void {
    if (!c.prog.no_implicit_any) return;
    const r = try c.resolveStructural(obj_t);
    // tsc picks `set` for an assignment target and `get` otherwise. ztsc has
    // no write context at this site, so it asks for `get` only: an object
    // carrying BOTH (the map-like shape this diagnostic exists for) reports
    // TS7052 in either position, and a `get`-less object correctly falls
    // through to TS7053 on a read. The one documented gap is a `set`-only
    // object in WRITE position, which tsc calls TS7052 and this calls TS7053.
    if (try c.propOfType(r, try c.atom("get"))) |prop| accessor: {
        const sig = try c.contextualCallSig(prop.ty, null_node);
        if (sig == types.no_type or c.ts.kind(sig) != .function) break :accessor;
        if (c.ts.fnParamCount(sig) == 0) break :accessor;
        if (!try c.isAssignable(idx_t, c.ts.fnParam(sig, 0).ty)) break :accessor;
        // tsc spells the suggestion as `<receiver>.get` when the receiver is
        // a plain name, and as the bare method otherwise.
        const base = skipParens(c, recv);
        if (base != null_node and c.nodeTag(base) == .identifier) {
            try c.diagFmt(7052, c.nodeSpan(node), "Element implicitly has an 'any' type because type '{s}' has no index signature. Did you mean to call '{s}.get'?", .{ try c.typeToString(obj_t), c.tokenText(c.tree.nodeMainToken(base)) });
        } else {
            try c.diagFmt(7052, c.nodeSpan(node), "Element implicitly has an 'any' type because type '{s}' has no index signature. Did you mean to call 'get'?", .{try c.typeToString(obj_t)});
        }
        return;
    }
    // A FRESH OBJECT-LITERAL receiver indexed by a string/number LITERAL is
    // the missing-property TS2339, not an implicit-any report at all: tsc's
    // `getPropertyTypeForIndexType` object-literal arm
    // (`isObjectLiteralType(objectType) && noImplicitAny && indexType.flags &
    // (StringLiteral | NumberLiteral)`). It is placed AFTER the `get`/`set`
    // suggestion above, which is where the oracle puts it: an object carrying
    // a matching accessor keeps TS7052 in both read and write position
    // (`({ get, set }).foo['k']`), and only a receiver with no suggestion to
    // make reaches this. Freshness is the other half of the discriminator: a literal held in a
    // variable — whose type is WIDENED, dropping the literal origin exactly as tsc's
    // `getWidenedTypeOfObjectLiteral` drops `ObjectFlags.ObjectLiteral` — is
    // TS7052/TS7053.
    if (c.ts.objectIsLiteralOrigin(r)) {
        const lit = try c.ts.regularLiteral(idx_t);
        // The property NAME, unquoted — `typeToString` of a string literal
        // carries its quotes, which this message must not.
        const name: ?[]const u8 = switch (c.ts.kind(lit)) {
            .string_literal => c.atomText(c.ts.literalAtom(lit)),
            .number_literal => try c.typeToString(lit),
            else => null,
        };
        if (name) |n| {
            try c.diagFmt(2339, c.nodeSpan(node), "Property '{s}' does not exist on type '{s}'.", .{
                n, try c.typeToString(obj_t),
            });
            return;
        }
    }
    try c.diagFmt(7053, c.nodeSpan(node), "Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{
        try c.typeToString(idx_t), try c.typeToString(obj_t),
    });
}

/// The expression inside any number of parentheses. tsc's `skipParentheses`:
/// a parenthesized expression is transparent to every syntactic question
/// about the value it wraps (is it an arrow? an identifier? an array
/// literal?), so anything that switches on an expression's SHAPE has to look
/// through it first.
pub fn skipParens(c: *const Checker, node: Node) Node {
    var n = node;
    while (n != null_node and c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    return n;
}

/// tsc's `skipOuterExpressions` at its default `OuterExpressionKinds.All`:
/// parentheses AND the assertions that change only the TYPE of what they wrap.
/// The syntactic question underneath — "what expression is really here" — is
/// unchanged by any of them, which is why `getThisArgumentOfCall` reads the
/// callee through this and not through `skipParens`: `o.test!()` and
/// `(o.test!)()` have the receiver `o` exactly as `o.test()` does.
pub fn skipOuterExprs(c: *const Checker, node: Node) Node {
    var n = node;
    while (n != null_node) {
        switch (c.nodeTag(n)) {
            .paren_expr, .non_null, .as_expr, .satisfies_expr => n = c.tree.nodeData(n).lhs,
            else => return n,
        }
    }
    return n;
}

/// Does this assignment target name an evolving (`auto`-typed) variable?
pub fn assignTargetIsEvolving(c: *Checker, target0: Node) bool {
    const n = skipParens(c, target0);
    if (n == null_node or c.nodeTag(n) != .identifier) return false;
    const a = c.atomOfToken(c.tree.nodeMainToken(n)) catch return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| c.isEvolvingVar(sym),
        else => false,
    };
}

/// tsc's `findApplicableIndexInfo` reduced to the one question a WRITE asks:
/// is the index signature the write lands on declared `readonly`?
///
/// A numeric key prefers the number signature and falls back to the string one
/// ("the string index signature applies only when no other index signature
/// does"); a string key sees the string signature alone. A UNION has an index
/// signature only when every constituent does, and it is readonly when any of
/// them is (`getUnionIndexInfos`' `isReadonly: some(...)`); an INTERSECTION
/// carries every constituent's signatures, so one readonly member is enough.
const IndexWrite = enum { none, mutable, readonly };

fn indexWriteVerdict(c: *Checker, t: TypeId, numeric: bool) Error!IndexWrite {
    const s = &c.ts;
    switch (s.kind(t)) {
        .object => {
            if (numeric and s.objectNumberIndex(t) != 0)
                return if (s.numberIndexIsReadonly(t)) .readonly else .mutable;
            if (s.objectStringIndex(t) == 0) return .none;
            return if (s.stringIndexIsReadonly(t)) .readonly else .mutable;
        },
        // `C.foo = 1` / `C[42] = 42` on `class C { static readonly [s: string]:
        // number }`: the class VALUE's index signatures live on its static-side
        // object, which `resolveStructural` does not unwrap to.
        .class_value => return indexWriteVerdict(c, try c.classStaticType(s.classSymbol(t)), numeric),
        .union_type => {
            var v: IndexWrite = .none;
            for (try c.memberList(t)) |m| {
                switch (try indexWriteVerdict(c, try c.resolveStructural(m), numeric)) {
                    .none => return .none,
                    .readonly => v = .readonly,
                    .mutable => if (v == .none) {
                        v = .mutable;
                    },
                }
            }
            return v;
        },
        .intersection => {
            var v: IndexWrite = .none;
            for (try c.memberList(t)) |m| {
                switch (try indexWriteVerdict(c, try c.resolveStructural(m), numeric)) {
                    .none => {},
                    .readonly => return .readonly,
                    .mutable => v = .mutable,
                }
            }
            return v;
        },
        else => return .none,
    }
}

/// TS2542 at a write that lands on a readonly index signature. tsc's
/// `checkReferenceExpression` reports it and CARRIES ON — unlike the readonly
/// *property* refusal (TS2540) it does not suppress the assignability check, so
/// `xs[k] = "s"` on a `readonly [k: string]: number` says both TS2542 and
/// TS2322. Hence nothing to answer: the caller keeps the real target type.
fn reportReadonlyIndexWrite(c: *Checker, obj: TypeId, node: Node, numeric: bool) Error!void {
    if (try indexWriteVerdict(c, obj, numeric) != .readonly) return;
    try c.diagFmt(2542, c.nodeSpan(node), "Index signature in type '{s}' only permits reading.", .{
        try c.typeToString(obj),
    });
}

/// A write through `obj[idx]` — an assignment target or a `delete` operand.
/// Reports TS2540 on a readonly list's fixed element and TS2542 on a readonly
/// index signature (a readonly list's, or a declared `readonly [k: …]`), and
/// answers whether the TS2540 arm fired, in which case the caller hands back
/// `error_type` to suppress the cascading TS2322.
///
/// The index expression is checked here rather than by the caller so the
/// literal-index question can be asked; `checkExprCached` makes the second
/// check on the ordinary path free.
fn readonlyIndexWriteAt(c: *Checker, obj: TypeId, node: Node, idx_node: Node) Error!bool {
    const idx_t = try c.ts.regularLiteral(try c.checkExprCached(idx_node, types.no_type));
    if (c.ts.kind(obj) == .tuple or c.ts.kind(obj) == .array) {
        switch (tuple_relate.readonlyIndexWrite(c, obj, idx_t) orelse return false) {
            .element => |iv| {
                try c.diagFmt(2540, c.nodeSpan(idx_node), "Cannot assign to '{d}' because it is a read-only property.", .{iv});
                return true;
            },
            .index_signature => {
                try c.diagFmt(2542, c.nodeSpan(node), "Index signature in type '{s}' only permits reading.", .{
                    try c.typeToString(obj),
                });
                return false;
            },
        }
    }
    // tsc's `checkIndexedAccessIndexType`, `AccessFlags.Writing` arm: a write
    // through a generic MAPPED receiver that ADDS `readonly` is TS2542 —
    // `y[k] = x[k]` on a `Readonly<T>`. Gated on a GENERIC index because that
    // is the only way tsc reaches the check: it runs on a deferred access, and
    // only a generic index defers an element access. A concrete key on the same
    // receiver resolves to a named member and is TS2540 instead.
    //
    // The map's own `readonly` is asked, not `indexWriteVerdict` — a deferred
    // map has no index signatures yet, which is why the verdict below answers
    // `.none` for it.
    if (c.ts.kind(obj) == .mapped and c.ts.mappedFlags(obj) & types.mapped_flag_readonly_add != 0 and
        try indexTypeIsGeneric(c, idx_t))
    {
        try c.diagFmt(2542, c.nodeSpan(node), "Index signature in type '{s}' only permits reading.", .{
            try c.typeToString(obj),
        });
        return false;
    }
    // A key that NAMES a declared member writes that member, whose own
    // `readonly` is the member-access path's TS2540 — the index signature is
    // never consulted (tsc's `getPropertyNameFromIndex` runs first).
    if (try c.literalKeyAtom(idx_t)) |key| {
        if (try c.propOfTypeEx(obj, key, false)) |_| return false;
    }
    // An `any` (or already-errored) key is applicable to EVERY index signature
    // — tsc's `isApplicableIndexType` is an assignability test, which `any`
    // passes — so `findApplicableIndexInfo` answers the number one, the string
    // signature being its last resort. That is what makes `E[bogus]--` on an
    // enum's readonly reverse-mapping signature TS2542.
    const ik = c.ts.kind(idx_t);
    const numeric = ik == .any or ik == .err or try c.typeIsNumberLike(idx_t);
    try reportReadonlyIndexWrite(c, obj, node, numeric);
    return false;
}

/// tsc's `left.kind === ObjectLiteralExpression || ArrayLiteralExpression`
/// test on the left of `=`. The pattern-shaped tags are in the set too: a
/// `for (…of…)` head can hand one to the expression walker.
fn isDestructuringPattern(c: *Checker, node: Node) bool {
    return switch (c.nodeTag(node)) {
        .array_literal, .object_literal, .array_pattern, .object_pattern => true,
        else => false,
    };
}

/// Type of an assignment target; reports TS2588 (const) and TS2540
/// (readonly property).
fn checkAssignmentTarget(c: *Checker, node: Node) Error!TypeId {
    switch (c.nodeTag(node)) {
        // `(x) = v` writes `x`: tsc's `getAssignmentTargetKind` walks up
        // through parentheses (and array literals, spreads and `!`), so the
        // refusals below apply to a parenthesized target unchanged.
        .paren_expr => return checkAssignmentTarget(c, c.tree.nodeData(node).lhs),
        .identifier => {
            const tok = c.tree.nodeMainToken(node);
            const a = try c.atomOfToken(tok);
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| {
                    const sf = c.symFlags(sym);
                    if (sf.const_decl) {
                        try c.diagFmt(2588, c.tokSpan(tok), "Cannot assign to '{s}' because it is a constant.", .{c.tokenText(tok)});
                        return types.error_type; // suppress cascading 2322
                    }
                    if (sf.import_binding) {
                        try c.diagFmt(2632, c.tokSpan(tok), "Cannot assign to '{s}' because it is an import.", .{c.tokenText(tok)});
                        return types.error_type;
                    }
                    // Assigning to a name that is not a VARIABLE at all is
                    // refused by tsc's `checkIdentifier` by WHAT IT IS, in
                    // this order (enum before class before namespace before
                    // function — a merged declaration reports the first that
                    // fits), and answers `errorType`. The type answer is
                    // load-bearing on its own: it is what stops
                    // `class f {}; f -= 1` from ALSO reporting the operand as
                    // non-arithmetic and the result as unassignable, neither
                    // of which tsc says.
                    if (!sf.var_decl and !sf.let_decl and !sf.param and !sf.catch_param and
                        (sf.enum_decl or sf.class or sf.namespace_decl or sf.function))
                    {
                        // A namespace whose every block declares only types
                        // emits no runtime object, so tsc never gets as far as
                        // "cannot assign to a namespace": the name does not
                        // resolve in value space at all, and the verdict is
                        // TS2708 ("cannot use as a value") instead.
                        const what: struct { code: u16, text: []const u8 } = if (sf.enum_decl)
                            .{ .code = 2628, .text = "an enum" }
                        else if (sf.class)
                            .{ .code = 2629, .text = "a class" }
                        else if (sf.namespace_decl) blk: {
                            if (try modvalue.valuelessNamespaceRef(c, sym, sf)) {
                                try c.diagFmt(2708, c.tokSpan(tok), "Cannot use namespace '{s}' as a value.", .{c.tokenText(tok)});
                                return types.error_type;
                            }
                            break :blk .{ .code = 2631, .text = "a namespace" };
                        } else .{ .code = 2630, .text = "a function" };
                        try c.diagFmt(what.code, c.tokSpan(tok), "Cannot assign to '{s}' because it is {s}.", .{ c.tokenText(tok), what.text });
                        return types.error_type;
                    }
                    return c.typeOfSymbol(sym);
                },
                .wrong_space => return types.error_type,
                .none => {
                    try c.reportNameNotFound(tok);
                    return types.error_type;
                },
            }
        },
        .member_expr => {
            const d = c.tree.nodeData(node);
            var obj_t = (try superReceiverType(c, d.lhs)) orelse
                try c.checkExprCached(d.lhs, types.no_type);
            obj_t = try checkNonNullType(c, obj_t, d.lhs);
            const name = try c.memberAtom(d.rhs);
            // `super.field = v` is TS2855 like the read is — tsc's
            // `checkPropertyAccessibility` runs on both directions, and its
            // early return means the `private`/`protected` rules are skipped
            // once it fires. See the read site in `memberChainInner`.
            var super_field = false;
            if (c.nodeTag(d.lhs) == .super_expr) {
                super_field = try accessibility.checkSuperField(c, name, d.rhs);
            }
            const r = try c.resolveStructural(obj_t);
            // A dotted write that resolves through a string INDEX SIGNATURE
            // rather than a declared member (`i.a = 1` on
            // `{ readonly [s: string]: number }`) is TS2542, not TS2540 — and
            // it does not suppress the assignability check.
            var via_index = false;
            if (try c.propOfTypeViaIndex(r, name, &via_index)) |p| {
                const wsite: accessibility.Site = .{
                    .dir = if (super_field) .none else .write,
                    .recv_node = d.lhs,
                };
                // A `#name` write from outside the declaring class is the same
                // TS18013 the read is (`Base.#prop = 10` in a derived class).
                if (c.tree.tokens.tag(d.rhs) == .private_identifier) {
                    if (try accessibility.checkPrivateName(c, obj_t, name, d.rhs, wsite)) return types.error_type;
                }
                if (p.nonPublic()) try accessibility.check(c, obj_t, name, d.rhs, wsite);
                // A readonly property may be assigned via `this.x` inside the
                // constructor of the class that OWNS the declaration (tsc:
                // `checkReferenceExpression`). An inherited readonly still
                // errors, so the property must be an OWN member of the
                // constructor's class.
                const ctor_ok = c.nodeTag(d.lhs) == .this_expr and c.ctorClassOwnsMember(name);
                if (via_index) try reportReadonlyIndexWrite(c, r, node, false);
                if (p.readonly() and !ctor_ok) {
                    try c.diagFmt(2540, c.tokSpan(d.rhs), "Cannot assign to '{s}' because it is a read-only property.", .{c.atomText(name)});
                    return types.error_type; // suppress cascading 2322
                }
                // TS 4.3 split accessors (`get x(): A; set x(v: B)`): the
                // WRITE type is the setter's parameter, not the property's
                // (getter's) type. See `setterWriteType`.
                const wt = (try setterWriteType(c, obj_t, name, 0)) orelse p.ty;
                // An optional property accepts `undefined` as a write target
                // (exactOptionalPropertyTypes is off): `x.opt = undefined` is
                // legal. Fold `| undefined` in exactly as the read path does,
                // so the write-target type is not narrower than the read type.
                if (p.optional()) return c.makeUnion2(wt, types.undefined_type);
                return wt;
            }
            return propertyTypeOf(c, obj_t, name, d.rhs, .{ .dir = .write, .recv_node = d.lhs });
        },
        .index_expr => {
            // Writing through a readonly list's index is TS2540 (a fixed
            // element, which is a readonly property) or TS2542 (the readonly
            // index signature) — see `readonlyIndexWriteAt`.
            const d = c.tree.nodeData(node);
            const obj_t = try c.checkExprCached(d.lhs, types.no_type);
            // `o["p"] = v` writes at the setter's parameter type when `p` is
            // a TS 4.3 split accessor, exactly as `o.p = v` does. Keyed off
            // the *syntactic* string literal so no extra expression is
            // checked on the ordinary element-write path.
            if (c.nodeTag(d.rhs) == .string_literal) {
                const key = try c.memberAtom(c.tree.nodeMainToken(d.rhs));
                if (try setterWriteType(c, obj_t, key, 0)) |wt| return wt;
            }
            const r = try c.resolveStructural(obj_t);
            if (try readonlyIndexWriteAt(c, r, node, d.rhs)) return types.error_type;
            return checkIndexExpr(c, node, false, types.no_type);
        },
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            // Destructuring-assignment pattern in the expression cover
            // grammar (`[a, b] = …`, `({ p: a } = …)`). Reached here only
            // where no SOURCE type is available — an operator other than
            // `=`, which is not a legal destructuring assignment anyway;
            // `checkAssignExpr` takes the `=` case straight to
            // `checkDestructuringPattern` with the source in hand.
            try checkDestructuringPattern(c, node, types.no_type);
            return types.any_type;
        },
        else => return c.checkExprCached(node, types.no_type),
    }
}

/// Since TS 4.3 a get/set pair may declare DIFFERENT types
/// (`get x(): A; set x(v: B)`), and the DOM lib uses it — `Window.location`
/// reads as `Location` and writes as `string`. `types.Prop` carries a single
/// `ty`, which is the getter's (the read type, per the "a getter, if present,
/// wins the property type" rule the member builders state), so a write site
/// would check the right-hand side against the READ type and reject
/// `w.location = url`.
///
/// The full design is tsc's `getWriteTypeOfSymbol`: a second, *write* type
/// carried per property — a field on `types.Prop`, threaded through
/// interning, every member-list builder, instantiation, mapped types and
/// both directions of the assignability relation. This is the bounded form:
/// it answers only at a WRITE site, and only from the DECLARATION, so no
/// type-store layout changes and nothing on the read path moves.
///
/// Reaches a declaration through interface and class references — the
/// shapes that stay a `.ref` — and through unions/intersections of them.
/// Answers null (keep the getter type, i.e. the pre-existing behaviour) for
/// everything that has already materialized to a bare `.object`: a type
/// literal annotation, a non-generic alias naming one, a mapped or spread
/// shape. An interned object carries no back-link to the member nodes it
/// was built from, and a side table filled *while building* one would be
/// order-dependent — two structurally identical literals intern to a single
/// `TypeId`, and a type may be built by one checker and read by another.
/// The answer has to stay a pure function of the program; closing that gap
/// is the full design's job, not a memo's.
fn setterWriteType(c: *Checker, t0: TypeId, name: Atom, depth: u32) Error!?TypeId {
    if (depth > 8) return null;
    const t = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    switch (c.ts.kind(t)) {
        .union_type, .intersection => {
            for (c.ts.members(t)) |m| {
                if (try setterWriteType(c, m, name, depth + 1)) |wt| return wt;
            }
            return null;
        },
        .ref => {
            const sym = c.ts.refSymbol(t);
            const f = c.symFlags(sym);
            const raw: ?TypeId = if (f.interface)
                try interfaceSetterParam(c, sym, name, depth)
            else if (f.class)
                try classSetterParam(c, sym, name, depth)
            else
                null;
            const wt = raw orelse return null;
            // The declaration's parameter type is written in the declaring
            // symbol's own type-parameter space; substitute the reference's
            // arguments exactly as `expandRef` does for the member list.
            const args = c.ts.refArgs(t);
            if (args.len == 0) return wt;
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(sym, &tps);
            if (tps.items.len == 0) return wt;
            var map_list: std.ArrayList(TpMap) = .empty;
            defer map_list.deinit(c.scratch());
            try c.buildInstMap(sym, try c.scratch().dupe(TypeId, args), &map_list);
            return try c.instantiate(wt, map_list.items);
        },
        else => return null,
    }
}

/// The parameter type of `set <name>(v)` declared on interface `sym` (any
/// reopened block), else on one of its `extends` bases. Converted in the
/// interface's own file context with its `this` bound, exactly as
/// `interfaceConstituentDirect` converts the member the getter came from.
fn interfaceSetterParam(c: *Checker, sym: SymbolId, name: Atom, depth: u32) Error!?TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    try c.setInterfaceThis(sym);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
        const members = c.tree.extraRange(data.members_start, data.members_end);
        if (try setterParamInMembers(c, members, name)) |wt| return wt;
    }
    // Inherited: walk `extends`. The bases are already materialized (the
    // property was found on the resolved shape), so this is a cache hit.
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.extends_start, data.extends_end)) |h| {
            if (h == null_node or c.nodeTag(h) != .heritage) continue;
            const hd = c.tree.nodeData(h);
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            if (hd.rhs != 0) {
                const r = c.tree.extraData(ast.SubRange, hd.rhs);
                for (c.tree.extraRange(r.start, r.end)) |an| {
                    if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                }
            }
            const base = try c.typeFromTypeName(hd.lhs, targs.items);
            if (try setterWriteType(c, base, name, depth + 1)) |wt| return wt;
        }
    }
    return null;
}

/// Scan a member-node list for `set <name>(v)` and answer its parameter
/// type.
fn setterParamInMembers(c: *Checker, members: []const Node, name: Atom) Error!?TypeId {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .method_signature) continue;
        const md = c.tree.nodeData(m);
        if (md.rhs & ast.Flags.set == 0) continue;
        if (try c.memberKey(c.tree.nodeMainToken(m), md.rhs) != name) continue;
        return try setterParamOfProto(c, m, md.lhs);
    }
    return null;
}

/// The parameter type of `set <name>(v)` declared on class `sym`, else on
/// its base class. `this` is the class instance, as `classInstanceGeneric`
/// binds it while converting the members.
fn classSetterParam(c: *Checker, sym: SymbolId, name: Atom, depth: u32) Error!?TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        const args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        c.this_type = try c.ts.makeRef(sym, args);
    }
    if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
        const kscope = c.symScope(sym);
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            if (try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope) != name) continue;
            const msym = c.toGlobal(c.bind.member_syms[i]);
            const mf = c.symFlags(msym);
            if (!mf.setter) return null;
            for (c.declsOf(msym)) |decl| {
                if (c.nodeTag(decl) != .class_method) continue;
                const d = c.tree.nodeData(decl);
                const proto = c.tree.extraData(ast.FnProto, d.lhs);
                if (proto.flags & ast.Flags.set == 0) continue;
                return try setterParamOfProto(c, decl, d.lhs);
            }
            return null;
        }
    }
    if (try c.baseClassRef(sym)) |base_ref| {
        return setterWriteType(c, base_ref, name, depth + 1);
    }
    return null;
}

/// The declared type of a set accessor's single parameter. A setter with no
/// parameter (an error elsewhere) has no write type.
fn setterParamOfProto(c: *Checker, decl: Node, proto_idx: u32) Error!?TypeId {
    const sig = try c.signatureOfProto(decl, proto_idx, true, false);
    if (c.ts.kind(sig) != .function or c.ts.fnParamCount(sig) == 0) return null;
    return c.ts.fnParam(sig, 0).ty;
}

/// A destructuring-assignment pattern in the expression cover grammar the
/// parser keeps (`{ p: a }` is an `object_literal` of `object_property`, not
/// an `object_pattern`), resolved against the type of the value being
/// destructured.
///
/// tsc's `checkObjectLiteralAssignment` / `checkArrayLiteralAssignment`: a
/// pattern element is not a value to be typed, it is a WRITE whose target is
/// reached THROUGH the source — the property its key names, or the element
/// its index names. That lookup is where the accessibility rules and TS2339
/// live, so a pattern walked with no source at all (as this was) reported
/// neither: `([{ a: { x } }] = [{ a: new C() }])` on a `private x` said
/// nothing where tsc says TS2341 (`destructuringAssignment_private`).
///
/// `src` is `no_type` where the source is unknown — an operator other than
/// `=`, a rest element, an index the source carries no numeric domain for.
/// Every lookup below is a no-op on `no_type` (`propertyTypeOf` answers
/// `any` for kind `.none`), so an unknown source degrades to exactly the
/// element walk this used to be.
/// What one destructuring position reads out of the value being destructured.
///
/// `exact` says whether `ty` is the type that position REALLY holds, as
/// opposed to a stand-in ztsc fell back to. Only an exact reading may be
/// related to the target (TS2322, tsc's `checkReferenceAssignment`): tsc
/// contextually types the right-hand side of `[a, [b]] = [1, [2]]` by the
/// pattern's implied tuple and reads `number` and `number[]` out of it, while
/// ztsc types the literal with no context at all and reads the widened
/// `number | number[]` out of an ARRAY — a type no position holds, and one
/// that would report against every target. The lookups the position drives
/// (TS2339, member accessibility, nested patterns) are unaffected: those ask
/// what is THERE, and the stand-in answers that well enough.
const DestructSrc = struct {
    ty: TypeId = types.no_type,
    exact: bool = false,
};

pub fn checkDestructuringPattern(c: *Checker, node: Node, src: TypeId) Error!void {
    switch (c.nodeTag(node)) {
        .object_literal, .object_pattern => {
            for (c.tree.nodeRange(node)) |el| try checkObjectDestructuringProperty(c, el, src);
        },
        else => {
            const iterated = try arrayPatternIteratedType(c, node, src);
            var index: u32 = 0;
            for (c.tree.nodeRange(node)) |el| {
                defer index += 1;
                try checkArrayDestructuringElement(c, el, src, iterated, index);
            }
        },
    }
}

/// The element type an ARRAY destructuring-assignment pattern reads its
/// positions through when the source carries no numeric domain of its own —
/// tsc's `checkArrayLiteralAssignment` computes it once for the whole pattern
/// (`checkIteratedTypeOrElementType`) and falls back to it for every element
/// that `isArrayLikeType` did not answer.
///
/// A source that is neither array-like nor iterable is TS2488 at the pattern,
/// which is the ONLY diagnostic tsc reports for `[a, b] = { 0: "", 1: true }`
/// (`iterableArrayPattern23`/`24`). `no_type` afterwards, so the element walk
/// stays exactly as unconstrained as tsc's `errorType` makes it.
fn arrayPatternIteratedType(c: *Checker, pat: Node, src: TypeId) Error!TypeId {
    if (src == types.no_type) return types.no_type;
    const r = try c.resolveStructural(src);
    switch (c.ts.kind(r)) {
        .any, .err, .none => return types.any_type,
        else => {},
    }
    if (try c.iterationElementType(r)) |e| return e;
    // A PARTLY iterable union is ztsc's own gap, not the code's: tsc types the
    // right-hand side by the pattern's implied TUPLE, so a nested position
    // reads its own element, while ztsc types the literal with no contextual
    // type at all and hands the nested pattern the widened element UNION.
    // `[this.#field, [this.#field]] = [1, [2]]` is that shape — the inner
    // pattern's source is `number | number[]` here and `number[]` in tsc — so
    // a union with any iterable constituent stays silent.
    if (c.ts.kind(r) == .union_type) {
        for (try c.memberList(r)) |m| {
            if ((try c.iterationElementType(m)) != null) return types.no_type;
        }
    }
    try c.diagFmt(2488, c.nodeSpan(pat), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{
        try c.typeToString(src),
    });
    return types.no_type;
}

/// The property an object-destructuring element names, and the token tsc
/// reports its accessibility/TS2339 diagnostic at (`property.name`, which
/// for a computed key starts at the `[`). Null when the element names no
/// static property: a computed key whose type is not usable as one (tsc's
/// `isTypeUsableAsPropertyName`).
const DestructKey = struct { name: Atom, tok: TokenIndex };

fn destructuringKey(c: *Checker, prop: Node, key_node: Node) Error!?DestructKey {
    if (key_node != null_node and c.nodeTag(key_node) == .computed_name) {
        const kt = try c.checkExprCached(c.tree.nodeData(key_node).lhs, types.no_type);
        const name = (try c.uniqueSymAtom(kt)) orelse (try c.literalKeyAtom(kt)) orelse return null;
        return .{ .name = name, .tok = c.tree.nodeMainToken(key_node) };
    }
    const tok = c.tree.nodeMainToken(prop);
    return .{ .name = try c.memberAtom(tok), .tok = tok };
}

/// The type a named destructuring position receives, with the member rules
/// of an ordinary property access run at the key: tsc reaches it through
/// `getIndexedAccessType(source, key, AccessFlags.ExpressionPosition)` plus a
/// `checkPropertyAccessibility(…, /*writing*/ true)` on the resolved symbol,
/// which is what `propertyTypeOf` with a `.write` site already does.
///
/// `has_default` is tsc's `AccessFlags.AllowMissing`, which it sets for
/// exactly the elements that carry `= init`: a missing property is then no
/// error, because the default is the value the target takes. The declaration
/// side has the same rule (`getBindingElementTypeFromParentType`, which ztsc
/// already matches — `var { x = 1 } = {}` reports nothing), and without it
/// every `({ x = 1 } = {})` in the corpus reported a property tsc is silent
/// about. The ACCESSIBILITY check is not suppressed: tsc gates it on the
/// lookup succeeding, not on the flag.
/// A NUMERIC key is the other divergence: tsc indexes with the key TYPE, so
/// `({ [1]: b } = [9, 8] as const)` reads tuple element 1 — a name lookup
/// finds nothing there and would report a property the tuple has.
fn destructuringMemberType(c: *Checker, src: TypeId, key: ?DestructKey, has_default: bool) Error!TypeId {
    if (src == types.no_type) return types.no_type;
    const k = key orelse return types.no_type;
    // Only the MISS is intercepted; a property that resolves keeps every rule
    // `propertyTypeOf` runs on it (the intersection-private reduction, the
    // per-constituent union accessibility, the lazy single-member paths).
    const r = try c.resolveStructural(src);
    const rk = c.ts.kind(r);
    if (rk != .any and rk != .err and (try c.propOfType(r, k.name)) == null) {
        if (try numericNameIndexHit(c, r, rk, c.atomText(k.name))) |t| return t;
        if (has_default) return types.no_type;
    }
    return propertyTypeOf(c, src, k.name, k.tok, .{ .dir = .write });
}

/// tsc's `hasDefaultValue`, over the shapes the expression cover grammar
/// produces for a pattern element's target: `[a = 1]` parses as a plain
/// assignment, a declaration-shaped pattern as a `binding_default`.
fn destructuringHasDefault(c: *Checker, el0: Node) bool {
    const el = skipParens(c, el0);
    if (el == null_node) return false;
    return switch (c.nodeTag(el)) {
        .binding_default => true,
        .assign => c.tree.tokens.tag(c.tree.nodeMainToken(el)) == .eq,
        else => false,
    };
}

/// The element a NUMERIC destructuring position names. `iterated` is what the
/// whole pattern's `arrayPatternIteratedType` answered: tsc reaches a position
/// by indexed access only where `isArrayLikeType(source)` holds and otherwise
/// hands every element that one iterated type, so a source with no numeric
/// domain (a `Set`, a `Generator`) still types its positions.
fn destructuringElementType(c: *Checker, src: TypeId, iterated: TypeId, index: u32) Error!DestructSrc {
    if (src == types.no_type) return .{};
    const r = try c.resolveStructural(src);
    const rk = c.ts.kind(r);
    if (rk == .any or rk == .err) return .{ .ty = types.any_type };
    // Only a TUPLE position is exact. tsc types the right-hand side of a
    // destructuring assignment by the pattern's implied tuple, so it reaches
    // every position through one; ztsc types it with no contextual type at
    // all, so `[a, [b]] = [1, [2]]` has an ARRAY source whose element is the
    // widened `number | number[]` union — a type no position really holds.
    if (try numericIndexHit(c, r, rk, @floatFromInt(index))) |t| {
        return .{ .ty = t, .exact = rk == .tuple };
    }
    return .{ .ty = iterated };
}

/// One property of an object destructuring pattern. A property KEY is a
/// name, not a reference — without this peel the generic expression walker
/// checked it as one (TS2304 on `({ width: dx } = …)`).
fn checkObjectDestructuringProperty(c: *Checker, prop: Node, src: TypeId) Error!void {
    if (prop == null_node) return;
    const d = c.tree.nodeData(prop);
    switch (c.nodeTag(prop)) {
        // `{ key: target }` / `{ [key]: target }` — only a computed key is
        // evaluated, and `destructuringKey` is what evaluates it.
        .object_property => {
            const key = try destructuringKey(c, prop, d.lhs);
            const elem = try destructuringMemberType(c, src, key, destructuringHasDefault(c, d.rhs));
            try checkDestructuringTarget(c, d.rhs, namedSource(elem), .assignment);
        },
        // `{ a }` / `{ a = init }` — the name is both key and target; lhs is
        // the target identifier, rhs the default. tsc's
        // `checkDestructuringAssignment` runs `checkBinaryLikeExpression(name,
        // =, objectAssignmentInitializer)` on the shorthand default, so the
        // initializer is related to the TARGET just as `a = init` would be,
        // and the source then loses `undefined`.
        .object_shorthand => {
            const key = try destructuringKey(c, prop, null_node);
            var elem = namedSource(try destructuringMemberType(c, src, key, d.rhs != null_node));
            if (d.rhs != null_node) {
                const target_t = try checkAssignmentTarget(c, d.lhs);
                const init_t = try c.checkExprCached(d.rhs, target_t);
                if (target_t != types.any_type and target_t != types.error_type)
                    _ = try c.checkAssignable(init_t, target_t, d.rhs, c.nodeSpan(d.lhs));
                elem = try defaultedSource(c, elem);
            }
            try checkDestructuringTarget(c, d.lhs, elem, .assignment);
        },
        // Declaration-shaped pattern nodes (a `for (…of…)` head can carry
        // one): main_token is the key, lhs the target (0 when shorthand).
        // A real binding pattern's types come from the declaration path
        // (`destructure.zig`), so no source lookup runs here.
        .binding_property => {
            if (d.rhs != null_node) _ = try c.checkExprCached(d.rhs, types.no_type);
            if (d.lhs != null_node) try checkDestructuringTarget(c, d.lhs, .{}, .assignment);
        },
        // `{[k]: target}` — the key IS evaluated; lhs is it, rhs the target.
        .binding_property_computed => {
            if (d.lhs != null_node) _ = try c.checkExprCached(d.lhs, types.no_type);
            if (d.rhs != null_node) try checkDestructuringTarget(c, d.rhs, .{}, .assignment);
        },
        // `{ ...rest } = src`: the rest object is `src` minus the names its
        // siblings take (tsc's `getRestType`), which is not computed here.
        // An object rest target has its OWN pair of reference diagnostics.
        .spread_element, .rest_element => try checkDestructuringTarget(c, d.lhs, .{}, .object_rest),
        .omitted, .error_node, .unsupported => {},
        else => _ = try checkAssignmentTarget(c, prop),
    }
}

/// One element of an array destructuring pattern, at position `index`.
fn checkArrayDestructuringElement(c: *Checker, el: Node, src: TypeId, iterated: TypeId, index: u32) Error!void {
    if (el == null_node) return;
    switch (c.nodeTag(el)) {
        .omitted, .error_node, .unsupported => {},
        // `[a, ...rest] = src`: the rest is the remaining elements, not the
        // element at `index`.
        .spread_element, .rest_element => try checkDestructuringTarget(c, c.tree.nodeData(el).lhs, try arrayRestSourceType(c, src, iterated, index), .assignment),
        else => try checkDestructuringTarget(c, el, try destructuringElementType(c, src, iterated, index), .assignment),
    }
}

/// The type an array-pattern REST position reads, tsc's
/// `checkArrayLiteralDestructuringElementAssignment`:
/// `everyType(sourceType, isTupleType) ? sliceTupleType(t, elementIndex) :
/// createArrayType(elementType)`. A tuple source keeps its remaining
/// positions — which is what tells `[...{ 0: a, b }] = tuple` that
/// `[string, number]` has no `b` — and anything else is an array of the
/// iterated element type.
///
/// `no_type` where the source is unknown, which is what every rest position
/// used to read: a nested pattern under one then resolves nothing, exactly
/// as it did before. Only the TUPLE slice is exact (`DestructSrc`) — the
/// array fallback is built from the same widened element the numeric
/// positions get.
fn arrayRestSourceType(c: *Checker, src: TypeId, iterated: TypeId, index: u32) Error!DestructSrc {
    if (src == types.no_type) return .{};
    const r = try c.resolveStructural(src);
    if (c.ts.kind(r) == .tuple) return .{ .ty = try sliceTuple(c, r, index, 0), .exact = true };
    if (iterated == types.no_type) return .{};
    return .{ .ty = try c.ts.makeArray(iterated) };
}

/// The assignment target of one pattern element, peeled through its default
/// initializer: a nested pattern recurses with the element type, anything
/// else is an ordinary assignment target. Without the peel the generic
/// expression walker checked the target identifier as a *read*, so writing a
/// not-yet-assigned `let` through a destructuring assignment reported TS2454
/// at the write site itself.
///
/// `src` is what the position reads out of the value being destructured; its
/// `ty` is `no_type` where that could not be resolved, which is tsc's
/// `errorType` and relates to anything.
fn checkDestructuringTarget(c: *Checker, el0: Node, src: DestructSrc, site: RefSite) Error!void {
    const el = skipParens(c, el0);
    if (el == null_node) return;
    const d = c.tree.nodeData(el);
    switch (c.nodeTag(el)) {
        .binding_default => {
            if (d.rhs != null_node) _ = try c.checkExprCached(d.rhs, types.no_type);
            try checkDestructuringTarget(c, d.lhs, try defaultedSource(c, src), site);
        },
        // `[a = init] = …`: the cover grammar parses the default as a plain
        // assignment expression, and tsc checks it AS one
        // (`checkDestructuringAssignment` runs the whole
        // `checkBinaryExpression` before peeling to `target.left`) — that is
        // where `[a = 1] = ["x"]` gets its "number is not assignable to
        // string" at `a`. The default having run, the source can no longer be
        // `undefined` at the target.
        .assign => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(el)) == .eq) {
                _ = try c.checkExprCached(el, types.no_type);
                try checkDestructuringTarget(c, d.lhs, try defaultedSource(c, src), site);
            } else {
                _ = try c.checkExprCached(el, types.no_type);
            }
        },
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            try checkDestructuringPattern(c, el, src.ty);
        },
        .omitted, .error_node, .unsupported => {},
        // tsc's `checkReferenceAssignment`: a leaf pattern element is a write,
        // and the same reference rules apply to it as to `x = v` — reported at
        // the element AS WRITTEN, parentheses included…
        else => {
            const target_t = try checkAssignmentTarget(c, el);
            const is_ref = try checkReferenceExpression(c, el0, site);
            // …and the value written is the position's source type, related
            // to the target exactly as `x = v` relates `v`. Gated on the
            // reference check, so an illegal target reports once, and on the
            // reading being EXACT (`DestructSrc`).
            if (is_ref and src.exact and
                src.ty != types.no_type and src.ty != types.any_type and src.ty != types.error_type and
                target_t != types.any_type and target_t != types.error_type)
            {
                _ = try c.checkAssignable(src.ty, target_t, el, c.nodeSpan(el));
            }
        },
    }
}

/// The source type a destructuring position hands its target once a DEFAULT
/// initializer stands between them — tsc's `getTypeWithFacts(sourceType,
/// TypeFacts.NEUndefined)`. The default is precisely what the target receives
/// when the position holds `undefined`, so `undefined` never reaches it.
fn defaultedSource(c: *Checker, src: DestructSrc) Error!DestructSrc {
    if (src.ty == types.no_type) return src;
    return .{ .ty = try c.removeUndefined(src.ty), .exact = src.exact };
}

/// A position reached by NAME — an object pattern's property. tsc looks the
/// property up on the source type itself, exactly as ztsc's
/// `destructuringMemberType` does, so the reading is exact whenever it
/// resolved at all.
fn namedSource(ty: TypeId) DestructSrc {
    return .{ .ty = ty, .exact = ty != types.no_type };
}

/// tsc's `getContextualCallSignature` for an INTERSECTION contextual type:
/// the constituents' call signatures concatenate, and either the sole one
/// answers or they are COMBINED (`getIntersectedSignatures` ->
/// `combineSignaturesOfIntersectionMembers`), which unions the parameter
/// types position-wise and intersects the return types. `no_type` when the
/// intersection carries no usable call signature.
///
/// The same combination answers an OVERLOAD SET, which is the other way a
/// contextual type ends up with several call signatures — `getSignaturesOfType`
/// makes no distinction between the two. `Console.trace` is declared once in
/// `lib.dom` and once by `@types/node`, and `globalThis.fetch` likewise; an
/// object literal written `as Console`, or an arrow assigned to
/// `globalThis.fetch`, therefore had NO contextual signature at all and every
/// parameter it declared was reported implicitly `any`.
///
/// Deliberately conservative: a constituent with its own type parameters or a
/// `this` type makes the combination ambiguous, so the whole set answers
/// `no_type` and the arrow keeps its context-free check (the prior behaviour
/// for every intersection).
/// tsc's `getSignaturesOfType(type, SignatureKind.Call)`, appended to `out`:
/// a lone function type is its own signature, an overload set and a callable
/// object hand over each of theirs, and an INTERSECTION concatenates its
/// constituents'.
fn collectCallSigs(c: *Checker, rctx: TypeId, out: *std.ArrayList(TypeId)) Error!void {
    const s = &c.ts;
    switch (s.kind(rctx)) {
        .function => try out.append(c.scratch(), rctx),
        .overloads => for (try c.memberList(rctx)) |ov| {
            try out.append(c.scratch(), ov);
        },
        .object => {
            for (0..s.objectCallSigCount(rctx)) |i| {
                try out.append(c.scratch(), s.objectCallSig(rctx, @intCast(i)));
            }
        },
        .intersection => for (try c.memberList(rctx)) |m| {
            try collectCallSigs(c, try c.resolveStructural(m), out);
        },
        else => {},
    }
}

/// tsc's `getContextualCallSignature`: the signatures a NON-union contextual
/// type offers, minus the ones too narrow for the function expression they
/// would type (`isAritySmaller`), reduced to the sole survivor or their
/// combination.
///
/// ```ts
/// const signatures = getSignaturesOfType(type, SignatureKind.Call);
/// const applicableByArity = filter(signatures, s => !isAritySmaller(s, node));
/// return applicableByArity.length === 1 ? applicableByArity[0] : getIntersectedSignatures(applicableByArity);
/// ```
///
/// `required` is the expression's syntactic required-parameter count, or null
/// when the caller has no function expression in hand and the arity question
/// therefore does not arise.
///
/// The filter runs HERE, before the combination — not on the combined result.
/// `TFunction extends ((event: any) => void) | (() => void)` (excalidraw's
/// `withBatchedUpdates`) is the witness: the one-parameter constituent is the
/// contextual signature for `(event) => …`, and filtering afterwards would
/// have thrown it away along with the zero-parameter one and reported TS7006.
fn contextualCallSigOfType(c: *Checker, rctx: TypeId, required: ?u32) Error!TypeId {
    // A contextual type with AT MOST ONE call signature — a function type, or
    // an object with zero or one — is the overwhelmingly common shape, and it
    // is answered without a list: this runs once per contextually typed
    // function expression in the program, and the list path allocates.
    switch (c.ts.kind(rctx)) {
        .function => return arityFiltered(c, rctx, required),
        .object => {
            const n = c.ts.objectCallSigCount(rctx);
            if (n == 0) return types.no_type;
            if (n == 1) return arityFiltered(c, c.ts.objectCallSig(rctx, 0), required);
        },
        .overloads, .intersection => {},
        else => return types.no_type,
    }
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    try collectCallSigs(c, rctx, &sigs);
    if (required) |n| {
        var kept: usize = 0;
        for (sigs.items) |sig| {
            if (sig_zig.arityIsSmaller(c, sig, n)) continue;
            sigs.items[kept] = sig;
            kept += 1;
        }
        sigs.shrinkRetainingCapacity(kept);
    }
    if (sigs.items.len == 0) return types.no_type;
    if (sigs.items.len == 1) return sigs.items[0];
    return combineCallSignatures(c, sigs.items);
}

/// `isAritySmaller` as a filter over a single signature: the signature, or
/// `no_type` when it is too narrow for the expression.
fn arityFiltered(c: *Checker, sig: TypeId, required: ?u32) TypeId {
    const n = required orelse return sig;
    return if (sig_zig.arityIsSmaller(c, sig, n)) types.no_type else sig;
}

/// tsc's `getIntersectedSignatures` ->
/// `combineSignaturesOfIntersectionMembers`: union the parameter types
/// position-wise, intersect the return types.
///
/// Deliberately conservative: a signature with its own type parameters or a
/// `this` type makes the combination ambiguous, so the whole set answers
/// `no_type` and the expression keeps its context-free check.
fn combineCallSignatures(c: *Checker, sigs: []const TypeId) Error!TypeId {
    const s = &c.ts;
    // Per signature: how many POSITIONS it declares, and whether its trailing
    // rest is open-ended. Both are the shared `getParameterCount` /
    // `hasEffectiveRestParameter` pair, so a rest typed by a FIXED TUPLE
    // spreads into its own elements instead of aborting the combination —
    // `(a: number, ...args: []) => void` declares exactly one position, which
    // is what lets it combine with `(b: string) => void` and
    // `(c: boolean) => void` (`signatureCombiningRestParameters1`).
    const positions = try c.scratch().alloc(u32, sigs.len);
    defer c.scratch().free(positions);
    const open_rest = try c.scratch().alloc(bool, sigs.len);
    defer c.scratch().free(open_rest);
    var max_pos: u32 = 0;
    var any_rest = false;
    for (sigs, 0..) |sig, si| {
        if (s.fnTypeParams(sig).len != 0 or s.fnThisType(sig) != 0) return types.no_type;
        // A rest typed by a UNION OF TUPLES has no single positional
        // expansion at all (`sigRestUnion`), so there is nothing to combine.
        if (try c.sigRestUnion(sig) != null) return types.no_type;
        positions[si] = try c.effParamCount(sig);
        const n = s.fnParamCount(sig);
        open_rest[si] = n > 0 and s.fnParam(sig, n - 1).rest() and (try c.sigRestTuple(sig)) == null;
        if (open_rest[si]) any_rest = true;
        max_pos = @max(max_pos, positions[si]);
    }
    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (0..max_pos) |i| {
        const pos: u32 = @intCast(i);
        parts.clearRetainingCapacity();
        var name: Atom = 0;
        var opt = false;
        for (sigs, 0..) |sig, si| {
            // tsc's `tryGetTypeAtPosition` answers a rest parameter's element
            // type for every position it covers — the reason
            // `(...data: any[]) => void` combines with
            // `(message?: any, …rest) => void`. A position past a signature's
            // list, and a rest position, are both optional.
            if (pos >= try c.requiredParams(sig)) opt = true;
            const pt = (try c.paramTypeAt(sig, pos)) orelse continue;
            if (pos < positions[si] and pos < s.fnParamCount(sig) and name == 0) {
                name = s.fnParam(sig, pos).name;
            }
            try parts.append(c.scratch(), pt);
        }
        if (parts.items.len == 0) return types.no_type;
        try params.append(c.scratch(), .{
            .name = name,
            .ty = try s.makeUnion(c.scratch(), parts.items),
            .flags = if (opt) types.param_flag_optional else 0,
        });
    }
    if (any_rest) {
        parts.clearRetainingCapacity();
        for (sigs, 0..) |sig, si| {
            if (!open_rest[si]) continue;
            try parts.append(c.scratch(), try c.elemOfArrayish(s.fnParam(sig, s.fnParamCount(sig) - 1).ty));
        }
        try params.append(c.scratch(), .{
            .name = 0,
            .ty = try s.makeArray(try s.makeUnion(c.scratch(), parts.items)),
            .flags = types.param_flag_rest,
        });
    }
    parts.clearRetainingCapacity();
    for (sigs) |sig| try parts.append(c.scratch(), s.fnReturn(sig));
    const ret = try s.makeIntersection(c.scratch(), parts.items);
    return s.makeFunction(params.items, ret, &.{}, 0);
}

/// tsc's `getContextualSignature`: the single call signature a contextual type
/// hands to a function expression written against it, or `no_type` when it
/// hands none — in which case the function's un-annotated parameters are
/// implicit `any`. Split out so a caller can ask the question WITHOUT walking
/// the function: `instantiateSigForCall` needs to know whether an overload
/// candidate is about to type a callback's parameters as `any` before it lets
/// that walk happen at all.
pub fn contextualCallSig(c: *Checker, ctx: TypeId, fn_node: Node) Error!TypeId {
    var ctx_sig: TypeId = types.no_type;
    // tsc's `isAritySmaller` compares every candidate against the arity the
    // function expression REQUIRES; with no expression in hand — a caller
    // asking what shape a contextual type has, not typing one — there is
    // nothing to compare and no filtering happens.
    const required: ?u32 = if (fn_node == null_node)
        null
    else switch (c.nodeTag(fn_node)) {
        .arrow_fn, .function_expr => sig_zig.syntacticRequiredParams(c, fn_node),
        else => null,
    };
    if (ctx != types.no_type) {
        var rctx = try c.resolveStructural(ctx);
        // tsc's `getContextualSignature` reads the contextual type's
        // APPARENT type, so a still-deferred type variable answers with its
        // base constraint. That is what a mapped parameter hands down —
        // property `a` of `{ [K in keyof T]: T[K] }` is contextually
        // `T['a']` — and leaving it deferred lost the signature entirely,
        // so the callback written there reported TS7006 on every parameter.
        switch (c.ts.kind(rctx)) {
            .type_param, .index_access, .conditional => {
                const ap = try c.transitiveBaseConstraint(rctx);
                if (ap != rctx and ap != types.no_type) rctx = try c.resolveStructural(ap);
            },
            else => {},
        }
        // A UNION asks each constituent separately — `getContextualSignature`
        // maps `getContextualCallSignature` over `(type as UnionType).types`
        // — so a constituent whose signatures are all too narrow drops out
        // and the NEXT one still answers. That per-constituent order is the
        // whole point of the arity filter living in
        // `contextualCallSigOfType`: `((event: any) => void) | (() => void)`
        // must answer with the one-parameter constituent for `(event) => …`.
        //
        // Everything else — a lone function type, a callable INTERFACE
        // (`FunctionComponent<P>` with its `displayName?`), an OVERLOAD SET
        // (`fetch` declared by both `lib.dom` and `@types/node`), an
        // INTERSECTION of callables (a JSX attribute of a component whose
        // props are `Omit<TriggerProps, "name"> & React.HTMLAttributes<…>`)
        // — is one signature list, and answers with its sole survivor or
        // their combination.
        if (c.ts.kind(rctx) == .union_type) {
            // Every constituent that offers a signature must offer the SAME
            // one; a union whose constituents disagree hands over NOTHING and
            // the expression's parameters are implicit `any`:
            //
            // ```ts
            // else if (!compareSignaturesIdentical(signatureList[0], signature, …)) {
            //     return undefined;  // Signatures aren't identical, do not use
            // }
            // ```
            //
            // Taking the first that answers instead typed a callback from
            // whichever constituent came first: an object literal written
            // against `string | FullRule` took its `normalize` property from
            // `String.prototype.normalize` and cascaded three errors out of a
            // parameter tsc simply reports as implicitly `any`.
            for (try c.memberList(rctx)) |m| {
                const sig = try contextualCallSigOfType(c, try c.resolveStructural(m), required);
                if (sig == types.no_type) continue;
                if (ctx_sig == types.no_type) {
                    ctx_sig = sig;
                } else if (!try identity.signatureParamsIdentical(c, ctx_sig, sig)) {
                    ctx_sig = types.no_type;
                    break;
                }
            }
        } else {
            ctx_sig = try contextualCallSigOfType(c, rctx, required);
        }
    }
    return ctx_sig;
}

/// tsc's `isContextSensitive` for a function expression / arrow: does its TYPE
/// depend on the contextual type it is checked against? It does exactly when
/// some parameter carries no annotation — such a parameter takes its type from
/// the contextual signature, and with no contextual signature it is implicit
/// `any`, which makes the whole function tsc's `anyFunctionType`.
pub fn fnExprIsContextSensitive(c: *Checker, node: Node) bool {
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(node).lhs);
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node) continue;
        const pd = c.tree.nodeData(p);
        const ann: Node = switch (c.nodeTag(p)) {
            .param => pd.rhs,
            .param_full => c.tree.extraData(ast.ParamFull, pd.rhs).type_ann,
            else => 0,
        };
        if (ann == 0) return true;
    }
    return false;
}

fn checkFunctionLikeExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    // A const assertion does not propagate into function bodies.
    const prev_cc = c.const_ctx;
    c.const_ctx = false;
    defer c.const_ctx = prev_cc;
    const d = c.tree.nodeData(node);
    const ctx_sig = try c.contextualCallSig(ctx, node);
    // tsc's `getContextualThisParameterType`: a contextually typed function
    // EXPRESSION whose own proto declares no `this` parameter takes `this`
    // from the contextual signature's. An arrow is excluded there and here —
    // it keeps the enclosing `this`. Only the body sees it; the type this
    // expression *has* is still built from its own proto, which is what tsc
    // reports for it too.
    //
    // This has to be in place before the signature is built, not just before
    // the body walk: an inner callback is contextually typed while its
    // enclosing call's type arguments are inferred, and that inference runs
    // from `signatureOfProtoCtx`. Setting it later left `this.xs.map((x) =>
    // …)` reporting `x` implicitly `any` even though `this` read correctly
    // on the line above.
    //
    // Without it `reduce._create_blob = function (env) { return
    // this.pica.toBlob(…).then((blob) => …) }` — whose contextual type
    // declares `(this: Reduce, env: Env)` — read `this` as the ambient one,
    // so `this.pica` was `any` and `blob` was reported implicitly `any`. The
    // contextual PARAMETERS were being adopted all along; only `this` was
    // dropped.
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    if (c.nodeTag(node) == .function_expr and
        ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function)
    {
        const ctx_this = c.ts.fnThisType(ctx_sig);
        if (ctx_this != 0) {
            c.this_type = ctx_this;
            // Recorded so a `this` in the body knows the receiver is THIS
            // function's and not an outer frame's — see `thisFrameOwnsThis`.
            try markThisBound(c, node);
        }
    }
    const sig = try c.signatureOfProtoCtx(node, d.lhs, false, ctx_sig == types.no_type, ctx_sig);
    // An own `this` parameter wins; `checkFunctionBody` installs it.
    if (c.ts.kind(sig) == .function and c.ts.fnThisType(sig) != 0) c.this_type = saved_this;
    // Check the body. The contextual signature's return type is the
    // contextual type of the body's return expressions, exactly as its
    // parameters are the contextual types of this function's parameters —
    // `signatureOfProtoCtx` already used it to *infer* the return, but the
    // body walk re-checked the same expressions context-free, so anything
    // nested in a returned object literal (a handler, a callback) lost its
    // contextual type and its parameters went implicit-`any`.
    try c.checkFunctionBody(node, d.lhs, d.rhs, sig, contextualReturnType(c, node, ctx_sig));
    return sig;
}

/// tsc's `getContextualReturnType` for a function-like with no return
/// annotation: the contextual signature's return, and failing that the arm for
/// an IMMEDIATELY-INVOKED function expression, whose body returns into the
/// call's own contextual type (`Checker.iife_ret_ctx`).
///
/// Read in both places a body's return expressions are typed — the return-type
/// PROBE in `signatures.zig` and the body walk here — because the walk re-checks
/// the same expressions and a context missing from either one is a context the
/// nested callbacks never see.
pub fn contextualReturnType(c: *const Checker, node: Node, ctx_sig: TypeId) TypeId {
    if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function) {
        const r = c.ts.fnReturn(ctx_sig);
        if (r != types.no_type) return r;
    }
    if (node != 0 and c.iife_ret_ctx_callee == c.nodeKey(node)) return c.iife_ret_ctx;
    return types.no_type;
}

pub fn templateAtom(c: *Checker, tok: TokenIndex) Error!Atom {
    const text = c.tokenText(tok);
    if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
        return c.atom(text[1 .. text.len - 1]);
    }
    return c.atom(text);
}

pub fn numberTokenValue(c: *const Checker, tok: TokenIndex) f64 {
    return numeric_lit.value(c.tokenText(tok));
}
