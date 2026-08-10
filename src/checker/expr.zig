//! Expression checking, including JSX.
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
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Bind = binder.Bind;
const SymbolId = binder.SymbolId;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const prof_zig = checker_zig.prof_zig;
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const FileId = checker_zig.FileId;
const Check = checker_zig.Check;
const check = checker_zig.check;

const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const UnionIndexMiss = @import("typenode.zig").UnionIndexMiss;
const buildRefKey = @import("flow.zig").buildRefKey;
const checkFunctionBody = @import("stmts.zig").checkFunctionBody;
const classInstanceGeneric = @import("instantiate.zig").classInstanceGeneric;
const computeTypeOfSymbol = @import("signatures.zig").computeTypeOfSymbol;
const containerOf = Checker.containerOf;
const ctxWantsTemplate = @import("generics.zig").ctxWantsTemplate;
const diagFmt = Checker.diagFmt;
const elemOfArrayish = @import("typenode.zig").elemOfArrayish;
const expandRef = @import("instantiate.zig").expandRef;
const flowTypeOfReference = @import("flow.zig").flowTypeOfReference;
const gatherSpreadProps = @import("typenode.zig").gatherSpreadProps;
const globalThisType = @import("instantiate.zig").globalThisType;
const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const indexableConstituent = @import("typenode.zig").indexableConstituent;
const inferTypeArgs = @import("calls.zig").inferTypeArgs;
const init = Checker.init;
const instantiate = @import("enums.zig").instantiate;
const interfaceConstituentDirect = @import("instantiate.zig").interfaceConstituentDirect;
const isNonPrimitiveKind = @import("assign.zig").isNonPrimitiveKind;
const lazyRefProp = @import("instantiate.zig").lazyRefProp;
const max_deep_ref_depth = @import("flow.zig").max_deep_ref_depth;
const namespaceMemberSym = @import("typenode.zig").namespaceMemberSym;
const propOfType = @import("props.zig").propOfType;
const pushChainGuards = @import("flow.zig").pushChainGuards;
const reduceSubtypes = @import("typenode.zig").reduceSubtypes;
const resolveStructural = @import("instantiate.zig").resolveStructural;
const run = Checker.run;
const scratch = Checker.scratch;
const seal = Checker.seal;
const signatureOfProtoCtx = @import("signatures.zig").signatureOfProtoCtx;
const templateExprType = @import("generics.zig").templateExprType;
const tpIndex = @import("calls.zig").tpIndex;
const tupleElemTypeAt = @import("assign.zig").tupleElemTypeAt;
const unify = @import("calls.zig").unify;
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
    const t = try c.checkExpr(node, ctx);
    // A side query is speculative — it runs out of the checker's top-down
    // order — so it must not publish its answer for the authoritative
    // check to read back.
    if (c.side_query_depth == 0 and c.no_publish_depth == 0 and !c.skip_ctx_sensitive)
        try c.node_types.put(c.cm(), key, .{ .ty = t, .ctx = ctx });
    return t;
}

pub fn checkExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const ewin = if (c.dprof.on) prof_zig.exprEnter(c, node) else prof_zig.DeclWin{};
    defer if (c.dprof.on) prof_zig.exprExit(c, ewin);
    const d = c.tree.nodeData(node);
    const main_tok = c.tree.nodeMainToken(node);
    switch (c.nodeTag(node)) {
        .identifier => return c.checkIdentifier(node),
        .number_literal => return c.ts.makeNumberLiteral(c.numberTokenValue(main_tok), true),
        .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(main_tok), true),
        .bigint_literal => return c.ts.makeBigIntLiteral(try c.atomOfToken(main_tok), true),
        .template_literal => return c.ts.makeStringLiteral(try c.templateAtom(main_tok), true),
        .true_literal => return c.ts.makeBooleanLiteral(true, true),
        .false_literal => return c.ts.makeBooleanLiteral(false, true),
        .null_literal => return types.null_type,
        .regex_literal => return types.any_type, // RegExp needs lib (documented)
        .this_expr => return if (c.this_type != 0) c.this_type else types.any_type,
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
            if (c.const_ctx or c.isConstTypeVar(ctx) or try c.ctxWantsTemplate(ctx)) return c.templateExprType(node);
            for (c.tree.nodeRange(node)) |sub| {
                if (sub != null_node) _ = try c.checkExprCached(sub, types.no_type);
            }
            return types.string_type;
        },
        .tagged_template => return c.checkTaggedTemplate(node, ctx),
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
                c.checkArrayLiteral(node, ctx)
            else
                c.checkObjectLiteral(node, ctx);
        },
        .member_expr, .optional_member_expr => return c.checkMemberExpr(node),
        .index_expr, .optional_index_expr => return c.checkIndexExpr(node, true),
        .call_expr, .call_expr_targs, .optional_call => return c.checkCallExpr(node, false, ctx),
        .new_expr, .new_expr_targs, .new_expr_bare => return c.checkCallExpr(node, true, ctx),
        .instantiation_expr => {
            const base = try c.checkExprCached(d.lhs, types.no_type);
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            return c.instantiationExprType(base, c.tree.extraRange(r.start, r.end), node);
        },
        .binary => return c.checkBinary(node, ctx),
        .assign => return c.checkAssignExpr(node),
        .cond_expr => {
            const e = c.tree.extraData(ast.CondExpr, d.rhs);
            _ = try c.checkExprCached(d.lhs, types.no_type);
            const then_t = try c.checkExprCached(e.then_expr, ctx);
            const else_t = try c.checkExprCached(e.else_expr, ctx);
            // The arms are subtype-reduced, exactly as `||`/`??` are
            // (tsc: `getUnionType([type1, type2], UnionReduction.Subtype)`).
            return c.logicalUnion(then_t, else_t);
        },
        .prefix_unary => return c.checkPrefixUnary(node, ctx),
        .postfix_unary => {
            const ot = try c.checkExprCached(d.lhs, types.no_type);
            try c.checkArithmeticOperand(ot, d.lhs);
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
            if (!try c.castComparable(try c.widenLiteral(et), tt)) {
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
            _ = try c.checkSatisfies(et, tt, d.lhs, c.nodeSpan(d.lhs));
            return et;
        },
        .arrow_fn, .function_expr => return c.checkFunctionLikeExpr(node, ctx),
        .class_decl => {
            try c.checkClass(node);
            return types.any_type; // class expressions: minimal support
        },
        .yield_expr => {
            // `yield x`: relate `x` to the generator's yield type `T`
            // (`Generator<T>`). Delegation `yield* x` (rhs=1) is unchecked
            // (iterable-protocol; a gap). `yield`'s own value type is `any`
            // (the caller-supplied `.next(v)` value — TNext, out of subset).
            const yt: TypeId = if (c.fn_ctx) |fc| fc.yield_type else 0;
            const in_async = if (c.fn_ctx) |fc| fc.is_async else false;
            const delegate = d.rhs != 0;
            if (d.lhs != 0) {
                const vt = try c.checkExprCached(d.lhs, if (delegate) types.no_type else yt);
                if (!delegate and yt != 0 and yt != types.no_type and yt != types.error_type and c.ts.kind(yt) != .any) {
                    // Async generators may yield `T | PromiseLike<T>`:
                    // the yielded value is awaited before it is emitted.
                    const eff_vt = if (in_async) try c.awaitedType(vt) else vt;
                    _ = try c.checkAssignable(eff_vt, yt, d.lhs, c.nodeSpan(d.lhs));
                }
            }
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

// =====================================================================
// JSX (`.tsx`): elements type as `JSX.Element`; attributes are checked
// like an object literal assigned to the element's props type — intrinsic
// (`<div>`) props come from `JSX.IntrinsicElements[tag]`, component
// (`<Foo>`) props from the component's first parameter.
// =====================================================================

pub fn checkJsxElement(c: *Checker, node: Node) Error!TypeId {
    // A JSX element's *type* is unconditionally `JSX.Element` (see the
    // return below): it does not depend on the tag's props, the attribute
    // values, or the children. Everything between here and that return
    // exists solely to raise diagnostics — and `diagFmt` files every
    // diagnostic under `cur_file`, which `seal` drops unless this checker
    // owns it. So in a file this checker does not own (reached only by
    // materializing a dependency's inferred type) the whole body is dead
    // work: same answer, discarded diagnostics.
    //
    // This is where the check phase's cross-checker duplication
    // concentrated: at `--checkers=4` each checker walked the JSX trees of
    // ~450 files it did not own, re-running props resolution and generic
    // component inference (`inferJsxTargs`) that another checker was
    // running anyway. Output is byte-identical for any `--checkers=N`
    // because the value produced here is `JSX.Element` either way.
    if (!c.owned_mask[c.cur_file]) return (try c.jsxNamespaceType(c.atom_Element)) orelse types.any_type;
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    var props: TypeId = types.no_type; // no_type = unknown target (skip attr typing)
    var is_component = false;
    if (e.tag == null_node) {
        // Fragment `<>…</>`: no attributes, no props.
    } else if (c.isIntrinsicJsxTag(e.tag)) {
        const tag_atom = try c.atomOfToken(c.tree.nodeMainToken(e.tag));
        if (try c.jsxNamespaceType(c.atom_IntrinsicElements)) |ie| {
            if (try c.propOfType(try c.resolveStructural(ie), tag_atom)) |p| {
                props = p.ty;
            } else {
                try c.diagFmt(2339, c.nodeSpan(e.tag), "Property '{s}' does not exist on type 'JSX.IntrinsicElements'.", .{c.atomText(tag_atom)});
            }
        }
    } else {
        is_component = true;
        const tag_ty = try c.checkExprCached(e.tag, types.no_type);
        // Explicit type arguments on the tag (`<Select<string> …>`): resolve
        // them and instantiate the component signature so props (and the
        // contextual types of attribute handlers) become concrete.
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        for (c.tree.extraRange(e.targs_start, e.targs_end)) |tn| {
            if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
        }
        props = (try c.jsxComponentProps(tag_ty, targs.items, node)) orelse types.no_type;
    }
    try c.checkJsxAttributes(node, e, props, is_component, c.jsxChildrenPresent(e));
    // tsc's `getContextualTypeForChildJsxExpression`: a JSX child EXPRESSION is
    // contextually typed by the `JSX.ElementChildrenAttribute` prop (usually
    // `children`) of the tag's attributes type — the same type the identical
    // value written as an explicit `children={…}` attribute would get.
    // ztsc typed children at no context at all, so the RENDER-PROP idiom
    // (`children: Node | ((state: State) => Node)`, which every social-app
    // `Link`/`Button`/`Toggle.Item` is written with) left the arrow's
    // parameters implicit `any` — TS7006 at each one.
    //
    // Scoped to the single-semantic-child case, which is what the idiom is:
    // tsc maps a multi-child list through the field type's array-like element
    // (indexed at the child's position), and typing every child at the whole
    // field type instead would be wrong.
    const child_ctx: TypeId = blk: {
        if (!is_component or props == types.no_type) break :blk types.no_type;
        if (c.jsxSemanticChildCount(e) != 1) break :blk types.no_type;
        const rt = try c.resolveStructural(props);
        if (rt == types.no_type) break :blk types.no_type;
        break :blk try c.ctxPropType(rt, rt, try c.jsxChildrenAttrName());
    };
    for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
        switch (c.nodeTag(ch)) {
            .jsx_expr_container => {
                const cd = c.tree.nodeData(ch);
                if (cd.lhs != null_node) _ = try c.checkExprCached(cd.lhs, child_ctx);
            },
            .jsx_element => _ = try c.checkJsxElement(ch),
            else => {}, // jsx_text
        }
    }
    return (try c.jsxNamespaceType(c.atom_Element)) orelse types.any_type;
}

/// Whether a JSX tag node is an intrinsic element (simple lowercase-initial
/// identifier). Uppercase or dotted names are component values.
pub fn isIntrinsicJsxTag(c: *Checker, tag: Node) bool {
    if (c.nodeTag(tag) != .identifier) return false;
    const text = c.tokenText(c.tree.nodeMainToken(tag));
    return text.len > 0 and text[0] >= 'a' and text[0] <= 'z';
}

/// Resolve the type `JSX.<member>` (e.g. `JSX.Element`,
/// `JSX.IntrinsicElements`) from the global `JSX` namespace, or null when
/// no such namespace/member exists.
pub fn jsxNamespaceType(c: *Checker, member: Atom) Error!?TypeId {
    const g = c.jsxNamespaceMember(member) orelse return null;
    return try c.namedTypeFromSymbol(g, &.{}, 0);
}

/// The (global) symbol for `JSX.<member>`, or null when the namespace or
/// member is absent. Existence checks use this directly so generic members
/// (e.g. `IntrinsicClassAttributes<T>`) are never instantiated bare.
pub fn jsxNamespaceMember(c: *Checker, member: Atom) ?SymbolId {
    const jsx_sym = switch (c.resolveSpace(c.atom_JSX, c.cur_scope, false)) {
        .sym => |s| if (c.symFlags(s).namespace_decl) s else return c.jsxRuntimeNamespaceMember(member),
        else => return c.jsxRuntimeNamespaceMember(member),
    };
    // Through `namespaceMemberSym`, so a `JSX` namespace declared in more
    // than one file is looked up in its MERGED member index. Reaching into
    // one declaration's body scope directly (`namespaceScopeOf` on the
    // merged symbol's representative constituent) saw only that file's
    // members: a project that adds its own custom elements with a script
    // `declare namespace JSX { interface IntrinsicElements { "em-emoji":
    // any } }` shadowed the whole React/preact `IntrinsicElements`, and
    // every `<div>` in the project became TS2339.
    const g = c.namespaceMemberSym(jsx_sym, member) orelse return c.jsxRuntimeNamespaceMember(member);
    const mf = c.symFlags(g);
    if (!(mf.exported and hasTypeMeaning(mf))) return c.jsxRuntimeNamespaceMember(member);
    return g;
}

/// The automatic-JSX-runtime fallback for `JSX.<member>`: under
/// `jsx: "react-jsx"` the namespace is an *export* of the
/// `<jsxImportSource>/jsx-runtime` module rather than a global — @types/react
/// 19 dropped `declare global { namespace JSX }` entirely, so the global
/// lookup above finds nothing and every intrinsic element would type its
/// props as "unknown target" (no contextual type for `onChange={(e) => …}`,
/// no TS2339 for a bogus tag). The driver puts that module in the program
/// and hands its FileId over as `Program.jsx_runtime_file`.
pub fn jsxRuntimeNamespaceMember(c: *Checker, member: Atom) ?SymbolId {
    const f = c.prog.jsx_runtime_file;
    if (f == modules.no_file or c.prog.links.len == 0) return null;
    const ns_tgt = c.prog.links[f].exportTarget(c.atom_JSX) orelse return null;
    const ns_sym = c.targetTypeSym(ns_tgt) orelse return null;
    if (!c.symFlags(ns_sym).namespace_decl) return null;
    const g = c.namespaceMemberSym(ns_sym, member) orelse return null;
    const mf = c.symFlags(g);
    if (!(mf.exported and hasTypeMeaning(mf))) return null;
    return g;
}

/// Props type of a component tag. Function components: the first parameter
/// of the call signature. Class components (`class C extends Component<P>`):
/// the member of the instance type named by `JSX.ElementAttributesProperty`
/// (typically `props`). Null when it has no discernible props (so attribute
/// typing is skipped).
pub fn jsxComponentProps(c: *Checker, tag_ty: TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
    const t = try c.resolveStructural(tag_ty);
    var sig = switch (c.ts.kind(t)) {
        .function => t,
        .overloads => blk: {
            const sigs = try c.memberList(t);
            break :blk if (sigs.len > 0) sigs[0] else return null;
        },
        .class_value => return c.jsxClassComponentProps(t),
        // A callable *object* — a call/construct-signature-bearing interface
        // used as a component — takes its first call signature.
        .object => if (c.ts.objectCallSigCount(t) > 0)
            c.ts.objectCallSig(t, 0)
        else
            return null,
        // A function merged with a namespace
        // (`declare function Icon(…); declare namespace Icon { … }`) types as
        // an *intersection* of the function value and the namespace object
        // (`computeTypeOfSymbol`). Pull the props from the callable
        // constituent; without this the whole props target is dropped and
        // every attribute goes unchecked (missing/excess/value all silently
        // pass — e.g. a bad `<Icon name>` slips through).
        .intersection => blk: {
            for (try c.memberList(t)) |m| {
                const rm = try c.resolveStructural(m);
                switch (c.ts.kind(rm)) {
                    .function => break :blk rm,
                    .overloads => {
                        const sigs = try c.memberList(rm);
                        if (sigs.len > 0) break :blk sigs[0];
                    },
                    .object => if (c.ts.objectCallSigCount(rm) > 0) break :blk c.ts.objectCallSig(rm, 0),
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    };
    // Bind explicit type arguments (`<Select<string> …>`) into the signature
    // so the props type is concrete. Mirrors the explicit-targ path of a
    // generic call; a count mismatch reports TS2558 there. With no explicit
    // args, a *generic* component's type params are inferred from the
    // attributes (tsc's "attributes object as the sole argument" model) —
    // without this `<Controller name control render>` keeps its props type
    // generic, so `control={control}` relates `Control<Form>` against the
    // still-free `Control<TFieldValues>` and its deferred `_defaultValues`
    // mapped-over-conditional spuriously fails (TS2322).
    if (explicit_targs.len > 0) {
        sig = try c.instantiateSigForCall(sig, explicit_targs, &.{}, node, types.no_type);
    } else if (c.ts.fnTypeParams(sig).len > 0) {
        const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        sig = try c.inferJsxTargs(sig, tps, e);
    }
    if (c.ts.fnParamCount(sig) == 0) return types.empty_object_type;
    // A props parameter that is OPTIONAL at the call site (`p?: Props`, or
    // `{ a }: Props = {}` — the "usable with no props at all" component
    // shape) carries `| undefined` in the signature, exactly as tsc's
    // `getTypeOfParameter` adds it. tsc then folds that union through
    // `intersectTypes(IntrinsicAttributes, props)`, whose `extractIrreducible`
    // pulls the `undefined` back OUT of the intersection: the props target
    // is `(IntrinsicAttributes & Props) | undefined`, and since a JSX
    // attributes object is never `undefined`, every check lands on the
    // object constituent. ztsc has no intersection step here, so strip the
    // nullish constituents directly. Leaving them in made the target a
    // UNION, which `checkJsxAttributes` treats as a lenient shape: the
    // missing/excess checks were skipped outright, and `propOfType` on the
    // union lost each prop's OPTIONAL flag, so passing a possibly-undefined
    // value to an optional prop was rejected (TS2322).
    const p0 = c.ts.fnParam(sig, 0).ty;
    const stripped = try c.nonNullableNullish(p0);
    return if (stripped == types.never_type) p0 else stripped;
}

/// Infer a generic component's type arguments from its JSX attributes,
/// mirroring tsc's "attributes object as the sole argument" model, then
/// return the signature instantiated with them. Only non-function attribute
/// values drive inference (a `render` callback is contextually typed, not a
/// Phase-1 inference source). A param no attribute constrains falls back to
/// its default, else its constraint, else `unknown` — so an un-inferred
/// `Controller<TFieldValues, TName>` resolves to concrete
/// `ControllerProps<Form, FieldPath<Form>, …>` whose props relate reflexively.
/// Whether `t` is (or resolves to) an object whose string index signature is
/// `any` and which carries no required named properties — the `Record<string,
/// any>` shape (react-hook-form `FieldValues`). Such a constraint imposes no
/// real requirement, so a JSX-inferred object candidate should not be clamped
/// to it. Deliberately narrow: a concrete-valued index (`Record<string,
/// string>`) or an index-plus-required-props shape returns false.
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
    return c.typeHasPrimitive(try c.resolveStructural(constraint));
}

pub fn typeHasPrimitive(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .string, .number, .boolean, .bigint, .symbol, .undefined, .null, .void, .never, .unique_symbol, .enum_type, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .template_literal_type, .string_mapping, .keyof_op => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (try c.typeHasPrimitive(try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

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

pub fn inferJsxTargs(c: *Checker, sig: TypeId, tps: []const u32, e: ast.JsxElementData) Error!TypeId {
    if (c.ts.fnParamCount(sig) == 0) return sig;
    const rp0 = try c.resolveStructural(c.ts.fnParam(sig, 0).ty);
    const candidates = try c.scratch().alloc(TypeId, tps.len);
    for (candidates) |*x| x.* = types.no_type;
    // Phase 1: unify each non-function attribute value against its target prop.
    for (c.tree.extraRange(e.attrs_start, e.attrs_end)) |attr| {
        if (c.nodeTag(attr) == .jsx_spread_attribute) continue;
        const name_tok = c.tree.nodeMainToken(attr);
        if (c.tree.tokens.tag(name_tok) == .jsx_name) continue; // hyphenated data-*/aria-*
        const ad = c.tree.nodeData(attr);
        // Skip a function-valued attribute (`render={() => …}`): a callback is
        // contextually typed, not a raw inference source, and typing it here
        // context-free would pollute the candidates.
        if (ad.lhs != null_node and c.nodeTag(ad.lhs) == .jsx_expr_container) {
            const cd = c.tree.nodeData(ad.lhs);
            if (cd.lhs != null_node and (c.nodeTag(cd.lhs) == .arrow_fn or c.nodeTag(cd.lhs) == .function_expr)) continue;
        }
        const pt = (try c.propOfType(rp0, try c.memberAtom(name_tok))) orelse continue;
        // A TEMPLATE-LITERAL attribute value is contextually typed by the
        // target prop, exactly as `inferTypeArgs`' Phase 1 does for a
        // template-expression argument: `ctxWantsTemplate` needs to see the
        // string-like-constrained type param to keep `` `owners.${number}.status` ``
        // a template-literal type. Checked context-free it widens to `string`,
        // which fails `TName extends FieldPath<TFieldValues>`, so `TName` fell
        // back to its default — the whole path union — and react-hook-form's
        // `<Controller name={`a.${i}.b`} …/>` typed `field.value` as the union
        // of EVERY field's value. Every other attribute shape keeps its
        // context-free inference (its contextual pass is `checkJsxAttributes`').
        const vctx: TypeId = blk: {
            if (ad.lhs == null_node or c.nodeTag(ad.lhs) != .jsx_expr_container) break :blk types.no_type;
            const cd = c.tree.nodeData(ad.lhs);
            if (cd.lhs == null_node) break :blk types.no_type;
            break :blk switch (c.nodeTag(cd.lhs)) {
                .template_expr => pt.ty,
                // An object/array-literal attribute whose target prop carries
                // a literal-constrained inference target keeps its literals —
                // the same gate `inferTypeArgs`' Phase 1 applies to an
                // object-literal ARGUMENT (`paramWantsLiteralCtx`). Without it
                // `options={[{ value: Breed.Nellore }, …]}` is checked
                // context-free, the enum members widen to the whole enum and
                // `T extends string` is inferred as `Breed`.
                .object_literal, .array_literal => if (try c.paramWantsLiteralCtx(pt.ty)) pt.ty else types.no_type,
                else => types.no_type,
            };
        };
        const vty = try c.jsxAttributeValueType(ad.lhs, vctx);
        try c.unify(pt.ty, vty, tps, candidates, 0);
    }
    // Resolve each param: inferred candidate (clamped to its constraint when
    // it violates it), else default, else constraint, else `unknown`. Mirrors
    // the final resolution loop of `inferTypeArgs`, threading each resolved
    // arg into `prov` so a later param's constraint (`TName extends
    // FieldPath<TFieldValues>`) sees the earlier one substituted.
    const args_buf = try c.scratch().alloc(TypeId, tps.len);
    const prov = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| prov[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
    for (tps, 0..) |tp, i| {
        var constraint: TypeId = try c.typeParamConstraint(tp);
        if (constraint != types.no_type) constraint = try c.instantiate(constraint, prov);
        if (candidates[i] != types.no_type) {
            args_buf[i] = candidates[i];
            const bare_outer = constraint != types.no_type and
                c.ts.kind(constraint) == .type_param and
                tpIndex(tps, c.ts.typeParamSymbol(constraint)) == null;
            // An `any`-valued index-signature constraint (`TFieldValues
            // extends FieldValues`, `FieldValues = Record<string, any>`) is
            // satisfied by any object candidate: tsc admits a named interface
            // there (every member is trivially assignable to `any`), so the
            // attribute-derived candidate must NOT be clamped down to
            // `FieldValues`. ztsc's general object→`{[x:string]:any}` relation
            // still rejects a named interface (a separate, unrelated gap), so
            // the clamp is bypassed explicitly here. Without this, `Controller`
            // resolves `TFieldValues` to `FieldValues`, its `_defaultValues`
            // stays `{[x:string]:any}`, and `control={control}` fails (TS2322).
            const any_index_ok = try c.constraintIsAnyIndex(constraint) and
                c.ts.kind(try c.resolveStructural(candidates[i])) == .object;
            if (constraint != types.no_type and !bare_outer and !any_index_ok and
                !try c.isAssignable(candidates[i], constraint))
            {
                var fell_back = false;
                args_buf[i] = try c.clampToConstraint(candidates[i], constraint, &fell_back);
            }
        } else if (c.typeParamHasDefault(tp)) {
            args_buf[i] = try c.instantiate(try c.typeParamDefault(tp), prov);
        } else {
            args_buf[i] = if (constraint != types.no_type) constraint else types.unknown_type;
        }
        prov[i].ty = args_buf[i];
    }
    const map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
    return c.instantiate(sig, map);
}

/// Props of a class component: read the member named by
/// `JSX.ElementAttributesProperty` (its single member's name, e.g. `props`)
/// off the class instance type. Null when the selector namespace is absent
/// (tsc leaves such attributes unchecked) or the class is generic (own type
/// params — an uncommon shape we do not model here).
pub fn jsxClassComponentProps(c: *Checker, class_val: TypeId) Error!?TypeId {
    const name = (try c.jsxPropsMemberName()) orelse return null;
    const cls = c.ts.classSymbol(class_val);
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(cls, &tps);
    if (tps.items.len != 0) return null; // generic class component: unmodeled
    const inst = try c.ts.makeRef(cls, &.{});
    const rinst = try c.resolveStructural(inst);
    if (try c.propOfType(rinst, name)) |p| return try c.withIntrinsicClassAttributes(p.ty, inst);
    // No resolvable props member — a modeling gap, not a genuinely
    // props-less component (an empty `Component<{}>` still yields a `props`
    // member above). This surfaces for class components whose base is a
    // class+interface declaration merge we don't fully fold (`@types/react`
    // `Component<P>` merges `interface Component extends ComponentLifecycle`
    // with `class Component { readonly props: Readonly<P> }`). Leave the
    // attributes unchecked (tsc's behavior for an unknown props target)
    // rather than reject every attribute against `{}` — under-report over a
    // false positive.
    return null;
}

/// tsc's `getJsxPropsTypeFromClassType`: a CLASS component's attributes
/// target is `IntrinsicClassAttributes<Instance> & Props` (the
/// `IntrinsicAttributes &` part is added by the shared JSX path). In
/// @types/react that interface is `{ ref?: Ref<T> }`, so without it every
/// `<ClassComp ref={…}>` read `ref` as an EXCESS attribute and the whole
/// element failed with TS2322 — 40+ hits on a React Native codebase, where
/// `View`/`Text`/`ScrollView` are all class components. Returns `props`
/// unchanged when the JSX namespace declares no such interface.
pub fn withIntrinsicClassAttributes(c: *Checker, props: TypeId, inst: TypeId) Error!TypeId {
    const sym = c.jsxNamespaceMember(c.atom_IntrinsicClassAttributes) orelse return props;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    // tsc fills the single type parameter with the host class instance type;
    // a non-generic declaration is used bare.
    const args: []const TypeId = if (tps.items.len == 1) &.{inst} else &.{};
    if (tps.items.len > 1) return props;
    const ica = try c.namedTypeFromSymbol(sym, args, 0);
    if (ica == types.error_type or ica == types.any_type) return props;
    return c.ts.makeIntersection(c.scratch(), &.{ ica, props });
}

/// Name of the props member per `JSX.ElementAttributesProperty` — the name
/// of that interface's single property (React uses `props`). Null when the
/// interface is absent or empty.
pub fn jsxPropsMemberName(c: *Checker) Error!?Atom {
    const t = (try c.jsxNamespaceType(c.atom_ElementAttributesProperty)) orelse return null;
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return null;
    return c.ts.objectProp(rt, 0).name;
}

/// One explicit (literal) JSX attribute gathered during the first pass.
pub const JsxAttr = struct {
    name: Atom,
    ty: TypeId,
    value: Node,
    name_tok: TokenIndex,
    overwritten: bool = false, // shadowed by a later `{...spread}` (TS2783)
};

/// Check a JSX element's attributes against its props type (`no_type` =
/// unknown target, only value expressions are checked). Mirrors tsc's
/// "attributes object assigned to props" model: per-attribute value
/// mismatches report at the value; excess/missing report the whole object.
///
/// Spread attributes (`<C {...p} />`) fold their object's properties into
/// the attribute set (later wins). A spread's props count toward
/// required-prop satisfaction, an explicit attribute overwritten by a later
/// spread's REQUIRED member is TS2783 (an OPTIONAL spread member does not
/// overwrite — tsc's checkSpreadPropOverrides rule), and a non-object
/// spread is TS2698. Where a spread's
/// contents cannot be confidently enumerated (`any`, generics, unions,
/// index signatures) the missing-prop check is skipped rather than risk a
/// false positive — tsc reports fewer such cases than it would with full
/// generic inference, which is out of scope here.
///
/// For component tags the allowed-attribute set is widened by
/// `JSX.IntrinsicAttributes` (so `key`/`ref`-style props do not read as
/// excess), and JSX children satisfy the `JSX.ElementChildrenAttribute`
/// prop (so a required `children` is not spuriously reported missing). We
/// do not type-check children values (lenient; documented).
pub fn checkJsxAttributes(c: *Checker, node: Node, e: ast.JsxElementData, props: TypeId, is_component: bool, has_children: bool) Error!void {
    const attrs = c.tree.extraRange(e.attrs_start, e.attrs_end);
    const rt: TypeId = if (props != types.no_type) try c.resolveStructural(props) else types.no_type;
    // Missing/excess checks run against object targets and intersections
    // of objects (real React's `DetailedHTMLProps<...> = ClassAttributes &
    // P`); anything else (unions, generics, `any`) is handled leniently —
    // only per-attribute value assignability there. `target_props` is the
    // flattened view used by the missing/weak checks.
    var target_props: std.ArrayList(types.Prop) = .empty;
    defer target_props.deinit(c.scratch());
    const shape: JsxTargetShape = if (rt == types.no_type)
        .not_objecty
    else
        try c.jsxTargetShape(rt, &target_props);
    const is_obj_target = shape != .not_objecty;
    const target_open = shape == .open_object;

    // Names allowed but not required on a component via IntrinsicAttributes,
    // plus whether that selector interface exists at all. When it does, a
    // component's effective props target is `IntrinsicAttributes & Props`
    // (an intersection), for which tsc reports missing/excess as plain
    // TS2322 rather than the single-object TS2741/2739 refinement.
    var ia_names: std.ArrayList(Atom) = .empty;
    defer ia_names.deinit(c.scratch());
    var has_intrinsic_attrs = false;
    if (is_component) {
        if (c.jsxNamespaceMember(c.atom_IntrinsicAttributes) != null) {
            has_intrinsic_attrs = true;
            try c.jsxIntrinsicAttrNames(&ia_names);
        }
    }

    var built: std.ArrayList(JsxAttr) = .empty;
    defer built.deinit(c.scratch());
    // Props known to be provided, in source order (explicit attrs +
    // enumerable spread contents + JSX children) — the missing-required
    // check reads the names, the whole-object diagnostics build the
    // combined "attributes object" from it (later wins on duplicates).
    var provided: std.ArrayList(types.Prop) = .empty;
    defer provided.deinit(c.scratch());
    var has_spread = false;
    var spread_opaque = false; // a spread whose props we could not enumerate
    var spread_non_object = false; // saw a primitive spread (TS2698)
    var last_spread_ty: TypeId = types.no_type; // for the TS2559 message

    for (attrs) |attr| {
        if (c.nodeTag(attr) == .jsx_spread_attribute) {
            has_spread = true;
            const sd = c.tree.nodeData(attr);
            if (sd.lhs == null_node) continue;
            const sty = try c.resolveStructural(try c.checkExprCached(sd.lhs, types.no_type));
            last_spread_ty = sty;
            switch (try c.jsxSpreadInfo(sty, &provided)) {
                .non_object => {
                    spread_non_object = true;
                    try c.diagFmt(2698, c.nodeSpan(sd.lhs), "Spread types may only be created from object types.", .{});
                },
                .unknown_shape => spread_opaque = true,
                .names => |names| {
                    // A prior explicit attr re-provided by this spread is
                    // overwritten → TS2783 (this usage will be overwritten).
                    for (built.items) |*b| {
                        if (b.overwritten) continue;
                        if (containsAtom(names, b.name)) {
                            b.overwritten = true;
                            try c.diagFmt(2783, c.tokSpan(b.name_tok), "'{s}' is specified more than once, so this usage will be overwritten.", .{c.atomText(b.name)});
                        }
                    }
                },
            }
            continue;
        }
        const ad = c.tree.nodeData(attr);
        const name_tok = c.tree.nodeMainToken(attr);
        // Contextual type for the value = the target prop's type (used only
        // for a template-literal expression value; see jsxAttributeValueType).
        // A HYPHENATED name (`data-*`, `aria-*`, `connect-link`) is exempt
        // from the excess-property and assignability checks further down,
        // but not from contextual typing: tsc looks it up in the attributes
        // type like any other name, which for a props type carrying a string
        // index signature yields the index VALUE. Skipping the lookup here
        // left a callback written as a hyphenated attribute with no
        // contextual signature, so its parameters went implicit-any.
        const vctx: TypeId = if (rt != types.no_type) blk: {
            const nm = try c.memberAtom(name_tok);
            // `ctxPropType`, not a bare `propOfType`: a component's props
            // are routinely `Base & (VariantA | VariantB)` (the
            // discriminated-props idiom), and `propOfType` has no union
            // arm, so a prop living in one variant was not found and the
            // attribute value went unctx-typed — a callback attribute's
            // parameters then fell to implicit `any` (TS7006). Object
            // literals already read their contextual property this way.
            break :blk try c.ctxPropType(rt, rt, nm);
        } else types.no_type;
        const vty = try c.jsxAttributeValueType(ad.lhs, vctx);
        // Hyphenated names (`data-*`, `aria-*`) are exempt from excess and
        // assignability checks (tsc), but their value expressions are still
        // checked — `jsxAttributeValueType` above did that.
        if (c.tree.tokens.tag(name_tok) == .jsx_name) continue;
        const name = try c.memberAtom(name_tok);
        try built.append(c.scratch(), .{ .name = name, .ty = vty, .value = ad.lhs, .name_tok = name_tok });
        try provided.append(c.scratch(), .{ .name = name, .ty = vty });
    }

    if (rt == types.no_type) return;

    // JSX children satisfy the ElementChildrenAttribute prop (usually
    // `children`) on component tags — count it as provided.
    if (is_component and has_children) {
        try provided.append(c.scratch(), .{ .name = try c.jsxChildrenAttrName(), .ty = types.any_type });
    }

    // Per-attribute value assignability + excess, for explicit attrs.
    var first_excess: Span = .{ .start = 0, .end = 0 };
    var have_excess = false;
    for (built.items) |b| {
        if (b.overwritten) continue; // shadowed by a later spread (TS2783)
        if (try c.propOfType(rt, b.name)) |p| {
            // tsc anchors a JSX attribute value mismatch at the attribute
            // NAME node (not the value), matching the excess-property anchor
            // above. Per-member elaboration for object/array-literal values
            // still points at the offending member via `b.value` below.
            const vspan = c.tokSpan(b.name_tok);
            // An optional prop (`date?: Date`) admits `undefined`, so an
            // explicit `date={maybeUndefined}` is not an error — mirrors the
            // structural object relation and the optional indexed-access path
            // (src/checker.zig:2864). Widen the target to `p.ty | undefined`
            // ONLY when the value can actually be undefined: a value that
            // never yields `undefined` (e.g. a fresh object literal) gets the
            // identical verdict from bare `p.ty`, and keeping it off the
            // object-to-union path avoids a distinct union-relation gap. A
            // required prop keeps `p.ty`, so an explicit `undefined` on it
            // still rejects.
            const target = if (p.optional() and c.containsUndefinedish(try c.resolveStructural(b.ty)))
                try c.makeUnion2(p.ty, types.undefined_type)
            else
                p.ty;
            _ = try c.checkAssignable(b.ty, target, b.value, vspan);
        } else if (try c.unionNestedPropType(rt, b.name)) |nested| {
            // A prop that lives in a UNION member of an intersection props
            // type (`Base & (VariantA | VariantB)`) is not found by
            // `propOfType`, so its value used to go unchecked — and, since
            // the excess arm below only fires for an open target, silently.
            // Check it against the union of the arms that declare it, the
            // same type the attribute's contextual lookup above uses.
            _ = try c.checkAssignable(b.ty, nested, b.value, c.tokSpan(b.name_tok));
        } else if (target_open and !containsAtom(ia_names.items, b.name)) {
            if (!have_excess) {
                first_excess = c.tokSpan(b.name_tok);
                have_excess = true;
            }
        }
    }

    if (!is_obj_target) return; // lenient target: value checks only

    // When `JSX.IntrinsicAttributes` exists, a component's effective props
    // target is the intersection `IntrinsicAttributes & Props`, for which
    // tsgo reports missing props as plain TS2322 — UNLESS the namespace
    // also declares `IntrinsicClassAttributes` (as @types/react does), in
    // which case tsgo surfaces the refined TS2741/2739 against the plain
    // props type. Empirically bisected against tsgo 7.0.2; matched as
    // observed. Excess is always the plain TS2322 form.
    const raw_2322 = has_intrinsic_attrs and
        c.jsxNamespaceMember(c.atom_IntrinsicClassAttributes) == null;

    if (have_excess) {
        // Excess wins over missing and is never refined to a
        // missing-property code (tsc's message is the excess flavor).
        try c.diagFmt(2322, first_excess, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(try c.jsxAttrsObject(provided.items)),
            try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }

    // Missing required props. When a spread's contents are opaque, any
    // required prop might come from it — skip to avoid a false positive.
    if (has_spread and spread_opaque) return;

    // Weak-type check (TS2559): the target has only optional props and the
    // (spread-provided) attributes share none of them. Fires only for
    // fully-enumerated spread sources — explicit-attr mismatches are excess
    // (TS2322, above), and opaque spreads were already skipped.
    if (has_spread and target_open) {
        var target_weak = target_props.items.len > 0 or ia_names.items.len > 0;
        for (target_props.items) |tp| {
            if (!tp.optional()) {
                target_weak = false;
                break;
            }
        }
        if (target_weak and (spread_non_object or provided.items.len > 0)) {
            var common = false;
            for (provided.items) |pp| {
                if ((try c.propOfType(rt, pp.name)) != null or containsAtom(ia_names.items, pp.name)) {
                    common = true;
                    break;
                }
            }
            if (!common) {
                const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
                const src_ty = if (last_spread_ty != types.no_type) last_spread_ty else try c.jsxAttrsObject(provided.items);
                try c.diagFmt(2559, span, "Type '{s}' has no properties in common with type '{s}'.", .{
                    try c.typeToString(src_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
                });
                return;
            }
        }
    }

    var any_missing = false;
    for (target_props.items) |tp| {
        if (tp.optional()) continue;
        if (!providedHas(provided.items, tp.name)) {
            any_missing = true;
            break;
        }
    }
    if (!any_missing) return;
    const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
    if (spread_non_object) {
        // The attributes' source type is the primitive spread itself —
        // plain TS2322 (a primitive never gets the missing-prop codes).
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(last_spread_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }
    const combined = try c.jsxAttrsObject(provided.items);
    if (raw_2322) {
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(combined), try c.jsxTargetString(props, true),
        });
    } else {
        try c.reportNotAssignable(2322, combined, props, span);
    }
}

/// Build the fresh object type standing in for the written attributes — the
/// combined explicit + spread-provided props, later occurrence winning.
/// Source type of the whole-object TS2322/2741/2739 messages.
pub fn jsxAttrsObject(c: *Checker, provided: []const types.Prop) Error!TypeId {
    var out: std.ArrayList(types.Prop) = .empty;
    defer out.deinit(c.scratch());
    for (provided) |p| {
        // Widened for display (`label="x"` prints as `label: string`,
        // matching tsc's messages); assignability used the fresh types.
        const wty = try c.widenLiteral(p.ty);
        var replaced = false;
        for (out.items) |*o| {
            if (o.name == p.name) {
                o.ty = wty; // later wins
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(c.scratch(), .{ .name = p.name, .ty = wty });
    }
    return c.ts.makeObject(out.items, 0, 0, types.obj_flag_fresh);
}

/// Display string for the props target: `IntrinsicAttributes & <Props>`
/// when the selector interface participates, else just the props type.
pub fn jsxTargetString(c: *Checker, props: TypeId, with_intrinsic: bool) Error![]const u8 {
    const s = try c.typeToString(props);
    if (!with_intrinsic) return s;
    return std.fmt.allocPrint(c.scratch(), "IntrinsicAttributes & {s}", .{s});
}

pub fn providedHas(list: []const types.Prop, name: Atom) bool {
    for (list) |p| if (p.name == name) return true;
    return false;
}

pub const JsxSpread = union(enum) { non_object, unknown_shape, names: []const Atom };

/// Classify a spread attribute's (resolved) type. `.names` are the prop
/// names it definitely contributes (their full props appended to
/// `provided` too); `.unknown_shape` means "unknown contents, could
/// provide anything" (any/union/generic/index-signature); `.non_object`
/// is a primitive (→ TS2698).
pub fn jsxSpreadInfo(c: *Checker, rst: TypeId, provided: *std.ArrayList(types.Prop)) Error!JsxSpread {
    switch (c.ts.kind(rst)) {
        .object => {
            if (c.ts.objectStringIndex(rst) != 0 or c.ts.objectNumberIndex(rst) != 0) return .unknown_shape;
            var names: std.ArrayList(Atom) = .empty;
            for (0..c.ts.objectPropCount(rst)) |i| {
                const p = c.ts.objectProp(rst, @intCast(i));
                // `names` drives the TS2783 overwrite check, which tsc
                // (checkSpreadPropOverrides) fires only for a REQUIRED
                // spread member — an optional prop in the spread does not
                // overwrite a prior explicit attribute. `provided` still
                // gets every prop (required-satisfaction reads all).
                if (!p.optional()) try names.append(c.scratch(), p.name);
                try provided.append(c.scratch(), p);
            }
            return .{ .names = try names.toOwnedSlice(c.scratch()) };
        },
        .intersection => {
            var names: std.ArrayList(Atom) = .empty;
            for (try c.memberList(rst)) |m| {
                const r = try c.resolveStructural(m);
                if (c.ts.kind(r) != .object or c.ts.objectStringIndex(r) != 0 or c.ts.objectNumberIndex(r) != 0) {
                    names.deinit(c.scratch());
                    return .unknown_shape;
                }
                for (0..c.ts.objectPropCount(r)) |i| {
                    const p = c.ts.objectProp(r, @intCast(i));
                    if (!p.optional()) try names.append(c.scratch(), p.name);
                    try provided.append(c.scratch(), p);
                }
            }
            return .{ .names = try names.toOwnedSlice(c.scratch()) };
        },
        .number, .number_literal, .number_literal_fresh, .string, .string_literal, .boolean, .bool_true, .bool_false, .bigint, .bigint_literal => return .non_object,
        else => return .unknown_shape, // any/unknown/union/type_param/mapped/…
    }
}

pub const JsxTargetShape = enum { not_objecty, open_object, closed_object };

/// Classify a (resolved) props target and flatten its properties into
/// `out`. Objects and intersections of objects are checkable (`open` when
/// no constituent has an index signature — tsc only excess-checks open
/// targets); anything else is `.not_objecty` (checked leniently).
pub fn jsxTargetShape(c: *Checker, rt: TypeId, out: *std.ArrayList(types.Prop)) Error!JsxTargetShape {
    switch (c.ts.kind(rt)) {
        .object => {
            for (0..c.ts.objectPropCount(rt)) |i| {
                try out.append(c.scratch(), c.ts.objectProp(rt, @intCast(i)));
            }
            const open = c.ts.objectStringIndex(rt) == 0 and c.ts.objectNumberIndex(rt) == 0;
            return if (open) .open_object else .closed_object;
        },
        .intersection => {
            var shape: JsxTargetShape = .open_object;
            for (try c.memberList(rt)) |m| {
                switch (try c.jsxTargetShape(try c.resolveStructural(m), out)) {
                    .not_objecty => return .not_objecty,
                    .closed_object => shape = .closed_object,
                    .open_object => {},
                }
            }
            return shape;
        },
        else => return .not_objecty,
    }
}

/// Names declared on `JSX.IntrinsicAttributes` (React: `key`, inherited
/// from `React.Attributes`) — allowed on any component tag without being
/// required.
pub fn jsxIntrinsicAttrNames(c: *Checker, out: *std.ArrayList(Atom)) Error!void {
    const t = (try c.jsxNamespaceType(c.atom_IntrinsicAttributes)) orelse return;
    const rt = try c.resolveStructural(t);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (try c.jsxTargetShape(rt, &props) == .not_objecty) return;
    for (props.items) |p| try out.append(c.scratch(), p.name);
}

/// The prop name JSX children flow into, per `JSX.ElementChildrenAttribute`
/// (its single member's name — React uses `children`). Defaults to
/// `children` when the selector interface is absent/empty.
pub fn jsxChildrenAttrName(c: *Checker) Error!Atom {
    const t = (try c.jsxNamespaceType(c.atom_ElementChildrenAttribute)) orelse return c.atom_children;
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return c.atom_children;
    return c.ts.objectProp(rt, 0).name;
}

/// Whether a JSX element has meaningful children (any element/expression,
/// or non-whitespace text) — whitespace-only text does not count.
pub fn jsxChildrenPresent(c: *Checker, e: ast.JsxElementData) bool {
    return c.jsxSemanticChildCount(e) != 0;
}

/// How many of a JSX element's children are SEMANTIC (tsc's
/// `getSemanticJsxChildren`) — the count that decides whether the
/// `children` prop type types one child directly or is spread across a list.
/// Stops at two: no caller distinguishes higher counts.
pub fn jsxSemanticChildCount(c: *Checker, e: ast.JsxElementData) u32 {
    var n: u32 = 0;
    for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
        switch (c.nodeTag(ch)) {
            .jsx_element => {
                n += 1;
                if (n == 2) return n;
            },
            .jsx_expr_container => {
                if (c.tree.nodeData(ch).lhs != null_node) {
                    n += 1;
                    if (n == 2) return n;
                }
            },
            else => { // jsx_text
                // tsc ignores text that is whitespace-only AND spans a
                // newline (trivia between lines); same-line whitespace is
                // a meaningful space child.
                const span = c.nodeSpan(ch);
                if (span.end <= c.src.len and span.start < span.end) {
                    var has_newline = false;
                    var non_ws = false;
                    for (c.src[span.start..span.end]) |ch2| {
                        if (ch2 == '\n' or ch2 == '\r') {
                            has_newline = true;
                        } else if (ch2 != ' ' and ch2 != '\t') {
                            non_ws = true;
                            break;
                        }
                    }
                    if (non_ws or !has_newline) {
                        n += 1;
                        if (n == 2) return n;
                    }
                }
            },
        }
    }
    return n;
}

pub fn containsAtom(list: []const Atom, name: Atom) bool {
    for (list) |a| if (a == name) return true;
    return false;
}

/// Type of a JSX attribute value: `name` → `true`, `name="s"` → fresh
/// `"s"` literal, `name={e}` → type of `e` (literals kept fresh, so
/// literal-union props accept them; widening is display-only), `name=<x/>`
/// → JSX.Element.
pub fn jsxAttributeValueType(c: *Checker, value: Node, ctx: TypeId) Error!TypeId {
    if (value == null_node) return types.true_type; // boolean shorthand
    switch (c.nodeTag(value)) {
        .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(value)), true),
        .jsx_expr_container => {
            const cd = c.tree.nodeData(value);
            if (cd.lhs == null_node) return types.undefined_type;
            // Contextually type the value by the target prop type for a
            // template-literal expression (so it keeps its template structure
            // instead of widening to `string`, e.g. `<Icon name={`ns:${s}`} />`
            // against a `` `${string}:${string}` `` prop), for an object
            // literal (so its properties are typed by the target — e.g.
            // `style={{ position: 'absolute' }}` against `CSSProperties`, whose
            // `position` is a union of string literals: without the context the
            // literal widens to `string` and rejects), and for an array literal
            // (so a fixed-length target picks the tuple member of a union —
            // e.g. `radius={[8, 8, 8, 8]}` against `number | [number, number,
            // number, number]`: without the context it widens to `number[]`
            // and fails the tuple). A conditional expression forwards the
            // context to both branches (`extraItems={cond ? [{…}] : []}`
            // against `Item[]`: each branch's array/object literal must be
            // contextually typed so its literal props don't widen — without
            // it `icon: 'link'` widens to `string` and rejects the `IconName`
            // prop). A function value (arrow or function expression) is
            // contextually typed by the target prop's signature, so its
            // parameters get their types from the callback type instead of
            // going implicit-any (`onPick={(v) => …}` against
            // `onPick?: (v: number) => void` — without the context every such
            // parameter raises TS7006). Other value kinds are checked
            // context-free.
            // A CALL is contextually typed too, so the callee's generic
            // inference gets tsc's `InferencePriority.ReturnType` seed: RN's
            // `size={platform({web: 'tiny', native: 'small'})}`
            // (`select<T>(spec: {[p in OS]?: T}): T | undefined`) keeps both
            // literals only because the attribute's `ButtonSize | undefined`
            // reaches the call — checked context-free every property widens
            // to `string` and `T` infers `string`.
            const vctx = switch (c.nodeTag(cd.lhs)) {
                .template_expr, .object_literal, .array_literal, .cond_expr, .arrow_fn, .function_expr => ctx,
                .call_expr, .call_expr_targs, .optional_call => ctx,
                else => types.no_type,
            };
            return c.checkExprCached(cd.lhs, vctx);
        },
        .jsx_element => return c.checkJsxElement(value),
        else => return types.any_type,
    }
}

pub fn checkIdentifier(c: *Checker, node: Node) Error!TypeId {
    const tok = c.tree.nodeMainToken(node);
    if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
    const a = try c.atomOfToken(tok);
    switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| {
            const f = c.symFlags(sym);
            if (f.import_binding) {
                if (c.importTarget(sym)) |tgt0| {
                    // A dual binding (tsc's combined value-and-type symbol)
                    // has a value meaning as long as the export-assigned
                    // value's type really does carry the property; when it
                    // does not, only the member's meanings are left and the
                    // type-only verdict below applies to it.
                    const tgt = if (try c.dualHasValue(tgt0)) tgt0 else c.typeMeaningTarget(tgt0);
                    if (tgt.kind == .binding) {
                        const tf = c.symFlags(c.toGlobalIn(tgt.file, tgt.payload));
                        // A pure type target is 2693 (matches tsc even
                        // through `export type` chains); a value target
                        // reached through `export type` is 1362.
                        if (!hasValueMeaning(tf) and hasTypeMeaning(tf)) {
                            try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                            return types.error_type;
                        }
                    }
                    if (tgt.type_only) {
                        try c.diagFmt(1362, c.tokSpan(tok), "'{s}' cannot be used as a value because it was exported using 'export type'.", .{c.tokenText(tok)});
                        return types.error_type;
                    }
                }
            }
            const declared = try c.typeOfSymbol(sym);
            // TDZ (TS2448) and definite assignment (TS2454). Both are
            // `void` — they contribute nothing to this identifier's type,
            // which is `flowTypeOfReference(declared)` below either way —
            // so the owned-file guard (see `checkJsxElement`) applies: in a
            // file this checker does not own, `seal` drops whatever they
            // report, and the only state they touch is `da_cache`, a pure
            // (flow, sym) memo that every reader re-derives on miss.
            if (c.owned_mask[c.cur_file]) {
                if ((f.let_decl or f.const_decl or f.class) and !f.function and !f.var_decl and !f.param) {
                    try c.checkTdz(sym, node, tok);
                }
                if ((f.let_decl or f.var_decl) and !f.param and !f.const_decl) {
                    try c.checkUseBeforeAssigned(sym, node, tok, declared);
                }
            }
            // Flow narrowing. A binding destructured out of a discriminated
            // union has no flow of its own that a guard on a SIBLING binding
            // touches, so its parent union is narrowed as a pseudo-reference
            // first (tsc's `getNarrowedTypeOfSymbol`); the ordinary walk still
            // runs on top of whatever that yields.
            if (try c.narrowedPatternBinding(node, sym)) |t| {
                return c.flowTypeOfReference(node, sym, t);
            }
            return c.flowTypeOfReference(node, sym, declared);
        },
        .wrong_space => |sym| {
            const wf = c.symFlags(sym);
            if (wf.import_binding and wf.type_only) {
                try c.diagFmt(1361, c.tokSpan(tok), "'{s}' cannot be used as a value because it was imported using 'import type'.", .{c.tokenText(tok)});
                return types.error_type;
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
                if (try c.implicitArgumentsType()) |t| return t;
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

pub fn checkTdz(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex) Error!void {
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
    const use_container = c.containerOf(c.cur_scope);
    const decl_container = c.containerOf(c.symScope(sym));
    if (use_container != decl_container) return;
    const kindname = if (c.symFlags(sym).class) "Class" else "Block-scoped variable";
    try c.diagFmt(2448, c.tokSpan(tok), "{s} '{s}' used before its declaration.", .{ kindname, c.tokenText(tok) });
}

pub fn checkUseBeforeAssigned(c: *Checker, sym: SymbolId, node: Node, tok: TokenIndex, declared: TypeId) Error!void {
    // Only for declarations without initializer whose type excludes
    // undefined/any, used in the same function container.
    if (c.symFile(sym) != c.cur_file) return; // cross-file: assigned
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
    // A use *before* the declaration (TDZ position) is also
    // definitely-unassigned even when the declarator has an
    // initializer (tsc reports 2448 + 2454 together).
    var before_decl = false;
    if (decls.len > 0) {
        if (c.tree.tokens.start(tok) < c.nodeSpanStart(decls[0])) before_decl = true;
    }
    if ((has_init or has_definite) and !before_decl) return;
    const dk = c.ts.kind(declared);
    if (dk == .any or dk == .err or dk == .unknown or dk == .void or dk == .none) return;
    if (c.containsUndefinedish(declared)) return;
    if (c.containerOf(c.cur_scope) != c.containerOf(c.symScope(sym))) return;
    const flow = c.bind.flowAt(node) orelse return;
    if (!try c.definitelyAssigned(flow, sym)) {
        try c.diagFmt(2454, c.tokSpan(tok), "Variable '{s}' is used before being assigned.", .{c.tokenText(tok)});
    }
}

/// ``tag`a${x}b` `` — a CALL of `tag` with the template's cooked-strings
/// array followed by each substitution (tsc's
/// `resolveTaggedTemplateExpression`). Before this the whole expression was
/// simply `any`, which erased every library that returns a typed builder from
/// a tag: kysely's ``sql<Row>`…` `` came back `any`, so the `rows` of its
/// result were `any[]` and every callback over them reported TS7006.
///
/// Deliberately TYPE-ONLY, not a full call check: the return type is
/// computed (with type-argument inference from the substitutions, and with
/// explicit type arguments already applied by the `instantiation_expr` the
/// parser builds for ``tag<T>`…` ``), but no argument diagnostic is reported
/// and a tag with no call signature stays `any`. Reporting would need the
/// synthesized `TemplateStringsArray` argument to relate exactly as tsc
/// builds it, and getting that subtly wrong is a false positive on every
/// tagged template in a program; answering with the return type is pure gain.
pub fn checkTaggedTemplate(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const tag_ty = try c.checkExprCached(d.lhs, types.no_type);
    // The substitutions are checked by the template node itself; do it first
    // so their diagnostics land whatever the tag turns out to be.
    _ = try c.checkExprCached(d.rhs, types.no_type);
    const r = try c.resolveStructural(tag_ty);
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
    if (sigs.items.len == 0) return types.any_type;
    // Argument nodes: the template stands in for the strings array (its own
    // parameter is `TemplateStringsArray`, which carries no type parameter in
    // any real tag, so what it contributes to inference is nothing), then one
    // per substitution.
    var args: std.ArrayList(Node) = .empty;
    defer args.deinit(c.scratch());
    try args.append(c.scratch(), d.rhs);
    if (c.nodeTag(d.rhs) == .template_expr) {
        for (c.tree.nodeRange(d.rhs)) |sub| {
            if (sub != null_node) try args.append(c.scratch(), sub);
        }
    }
    // Overloads: the first signature whose arity fits, mirroring
    // `resolveSignatureCall`'s order without its argument check.
    var chosen = sigs.items[0];
    if (sigs.items.len > 1) {
        for (sigs.items) |sig| {
            const n = args.items.len;
            if (n >= try c.requiredParams(sig) and n <= try c.paramTotal(sig)) {
                chosen = sig;
                break;
            }
        }
    }
    const inst = try c.instantiateSigForCall(chosen, &.{}, args.items, node, ctx);
    return c.ts.fnReturn(inst);
}

pub fn checkArrayLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
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
    if (c.const_ctx) return c.checkConstArrayLiteral(node, !try c.ctxIsMutableArrayLike(ctx));
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
    const ctx_tuple = ctx_tuple_ty != types.no_type;
    // Contextual element type for a plain (non-tuple) array literal. A
    // direct array context yields its element; a union context contributes
    // the element type of each array-like constituent (so array-literal
    // elements are contextually typed — literals stay literal instead of
    // widening).
    const ctx_elem: TypeId = if (!ctx_tuple) try c.contextualArrayElemType(rctx) else types.no_type;

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
                    const elem = (try c.iterationElementType(st)) orelse types.any_type;
                    try elem_types.append(c.scratch(), elem);
                    try raw_types.append(c.scratch(), elem);
                    try tuple_elems.append(c.scratch(), .{ .ty = try c.ts.makeArray(elem), .flags = types.elem_flag_rest });
                },
            }
            i += 1;
            continue;
        }
        var ectx: TypeId = ctx_elem;
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
            ectx = if (c.ts.kind(rctx) == .union_type)
                try c.contextualElemTypeAt(rctx, i)
            else
                try c.tupleElemTypeAt(ctx_tuple_ty, i) orelse types.no_type;
        }
        const raw = try c.checkExprCached(el, ectx);
        var et = raw;
        if (!try c.keepLiteral(et, ectx)) et = try c.widenLiteral(et);
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
                try c.multiArrayLikeBranches(rctx))
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
    return c.ts.makeArray(try c.arrayLiteralElemType(raw_types.items, elem_types.items));
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
pub fn arrayLiteralElemType(c: *Checker, raw: []const TypeId, widened: []const TypeId) Error!TypeId {
    std.debug.assert(raw.len == widened.len);
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

/// The element type an array literal's elements should be contextually
/// typed against, given a (structurally resolved) contextual type. A direct
/// array yields its element type; a union contributes the element type of
/// every array-like constituent (mirrors tsc's per-element
/// `getContextualTypeForElementExpression` mapping over the union). Returns
/// `no_type` when nothing array-like is present.
pub fn contextualArrayElemType(c: *Checker, rctx: TypeId) Error!TypeId {
    if (rctx == types.no_type) return types.no_type;
    switch (c.ts.kind(rctx)) {
        .array => return c.ts.arrayElem(rctx),
        .union_type => {
            var elems: std.ArrayList(TypeId) = .empty;
            defer elems.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const e = try c.contextualArrayElemType(try c.resolveStructural(m));
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
            return c.contextualArrayElemType(rcon);
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

/// The contextual type for the element at index `i` of an array literal in
/// TUPLE context, given a (structurally resolved) contextual type — tsc's
/// `getTypeOfPropertyOfContextualType(ctx, "" + i)`, which `mapType`s over a
/// union. A tuple constituent contributes the type at that position (its
/// rest element past the fixed part), an array constituent its element type,
/// and anything else nothing. Returns `no_type` when no constituent holds an
/// element there.
pub fn contextualElemTypeAt(c: *Checker, rctx: TypeId, i: u32) Error!TypeId {
    switch (c.ts.kind(rctx)) {
        .tuple => return try c.tupleElemTypeAt(rctx, i) orelse types.no_type,
        .array => return c.ts.arrayElem(rctx),
        .union_type => {
            var elems: std.ArrayList(TypeId) = .empty;
            defer elems.deinit(c.scratch());
            for (try c.memberList(rctx)) |m| {
                const e = try c.contextualElemTypeAt(try c.resolveStructural(m), i);
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
        else => return types.no_type,
    }
}

/// True when a (structurally resolved) union contextual type has two or
/// more array-like constituents (`E[] | E[][]`, `A[] | B[]`). Used to
/// detect the ambiguous empty-array-literal case where folding every
/// branch's element type would produce an array assignable to no branch.
pub fn multiArrayLikeBranches(c: *Checker, rctx: TypeId) Error!bool {
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
pub fn checkConstArrayLiteral(c: *Checker, node: Node, ro: bool) Error!TypeId {
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
pub fn ctxIsMutableArrayLike(c: *Checker, ctx: TypeId) Error!bool {
    return c.ctxIsMutableArrayLikeAt(ctx, 0);
}

pub fn ctxIsMutableArrayLikeAt(c: *Checker, ctx: TypeId, depth: u32) Error!bool {
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
                if (try c.ctxIsMutableArrayLikeAt(m, depth + 1)) return true;
            }
            return false;
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
            return c.ctxIsMutableArrayLikeAt(con, depth + 1);
        },
        else => return false,
    }
}

/// Collect the free type-param symbols reachable in `t` (structural walk,
/// no expansion — a `ref` contributes its args, not its resolved body).
pub fn collectTypeParamSyms(c: *Checker, t: TypeId, out: *std.ArrayList(u32)) Error!void {
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
    try c.collectTypeParamSyms(t, &syms);
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
    return c.objLitIsContextSensitiveAt(node, 0, false);
}

/// The same question restricted to the literal's OWN properties — no
/// recursion into a nested object literal. A shallow-sensitive literal is
/// one the single contextual read already handles: every un-annotated
/// callback parameter it carries is named directly by a property of the
/// parameter type, so reading the literal against that parameter types
/// them. Only a literal whose sensitivity is NESTED is read against a
/// property type that may itself still be a bare inference variable.
pub fn objLitIsShallowContextSensitive(c: *Checker, node: Node) bool {
    return c.objLitIsContextSensitiveAt(node, 0, true);
}

pub fn objLitIsContextSensitiveAt(c: *Checker, node: Node, depth: u8, shallow: bool) bool {
    for (c.tree.nodeRange(node)) |m| {
        if (m == null_node) continue;
        const val = switch (c.nodeTag(m)) {
            .object_property, .object_method => c.tree.nodeData(m).rhs,
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
                if (depth < 4 and c.objLitIsContextSensitiveAt(val, depth + 1, false)) return true;
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
    return c.paramWantsLiteralCtxAt(pt, 0);
}

pub fn paramWantsLiteralCtxAt(c: *Checker, pt: TypeId, depth: u8) Error!bool {
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
            if (try c.paramWantsLiteralCtxAt(m, depth + 1)) return true;
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
    if (c.ts.kind(r) == .array and depth < 2) return c.paramWantsLiteralCtxAt(c.ts.arrayElem(r), depth + 1);
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
pub fn keepLiteral(c: *Checker, t: TypeId, ctx: TypeId) Error!bool {
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
    const clk = try c.enumMemberLiteralKind(lit, lk);
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
            const elk = try c.enumMemberLiteralKind(lit, lk);
            if (try c.containsTypeParam(constraint)) {
                const base = try c.baseConstraintOf(constraint);
                if (base != constraint) {
                    if (try c.contextAdmitsLiteral(base, lit)) return true;
                    return c.constraintKeepsLiteralKind(base, elk);
                }
            }
            // tsc's `isLiteralOfContextualType` type-VARIABLE rule: a
            // constraint that merely *contains* the literal's primitive
            // (`T extends string`) is a literal context, even though the
            // primitive itself is a widening context in every other
            // position. That is what makes `isMemberOf<T extends string>(
            // coll: readonly T[], v)` called with `["a", "b"]` infer
            // `T = "a" | "b"` instead of `string`.
            return c.constraintKeepsLiteralKind(constraint, elk);
        },
        else => return false,
    }
}

/// The literal KIND an enum member stands for — the kind of its declared
/// value (`.string_literal` for a string enum, `.number_literal` for a
/// numeric one). Non-members answer with `fallback` (their own kind). tsc
/// carries both flags on one type; ztsc models an enum member as its own
/// `.enum_type` kind, so the mapping is explicit.
pub fn enumMemberLiteralKind(c: *Checker, lit: TypeId, fallback: types.Kind) Error!types.Kind {
    if (!c.ts.isEnumMember(lit)) return fallback;
    const v = try c.enumMemberValue(c.ts.enumSymbol(lit), c.ts.enumMemberAtom(lit)) orelse return fallback;
    return c.ts.kind(v);
}

/// tsc's `maybeTypeOfKind(constraint, <primitive of the literal>)` half of
/// `isLiteralOfContextualType`'s type-variable rule: does `constraint`
/// contain the primitive that `lk` is a literal of? Unions and
/// intersections are searched; a bare `string`/`number`/`bigint`/`boolean`
/// answers for its own literal kind.
pub fn constraintKeepsLiteralKind(c: *Checker, constraint: TypeId, lk: types.Kind) Error!bool {
    const r = try c.resolveStructural(constraint);
    switch (c.ts.kind(r)) {
        .union_type, .intersection => {
            for (try c.memberList(r)) |m| {
                if (try c.constraintKeepsLiteralKind(m, lk)) return true;
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

/// The literal type an object-literal property value denotes *syntactically*
/// — a string/number/boolean literal — for use as a discriminant when the
/// contextual type is a union. `no_type` for anything else (no full check).
pub fn discriminantLiteralOf(c: *Checker, node: Node) Error!TypeId {
    if (node == null_node) return types.no_type;
    return switch (c.nodeTag(node)) {
        .string_literal => try c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(node)), false),
        .number_literal => try c.ts.makeNumberLiteral(c.numberTokenValue(c.tree.nodeMainToken(node)), false),
        .true_literal => types.true_type,
        .false_literal => types.false_type,
        else => types.no_type,
    };
}

/// Discriminant-guided contextual typing: when an object literal is typed by
/// a union, filter the union to the constituents whose properties accept the
/// literal-valued properties of the source (tsc's
/// `discriminateTypeByDiscriminantProperties`). Typing each property against
/// the surviving constituent(s) keeps its literal discriminant instead of
/// widening it against a union-wide property type (`'X' | string` = `string`)
/// that no arm's literal discriminant would then match. Only ever *narrows*
/// the union (each removed member has a discriminant that rejects the source
/// literal, so it can never be the target) — an empty result means no arm
/// matched, so the original union stands and the mismatch is reported.
pub fn discriminateCtxUnion(c: *Checker, node: Node, rctx: TypeId) Error!TypeId {
    var surviving = try c.memberList(rctx);
    var narrowed = false;
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node or c.nodeTag(prop) != .object_property) continue;
        const pd = c.tree.nodeData(prop);
        if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        const lit = try c.discriminantLiteralOf(pd.rhs);
        if (lit == types.no_type) continue;
        const key = try c.memberAtom(c.tree.nodeMainToken(prop));
        var keep: std.ArrayList(TypeId) = .empty;
        defer keep.deinit(c.scratch());
        for (surviving) |m| {
            if (try c.propOfType(try c.resolveStructural(m), key)) |p| {
                if (try c.isAssignable(lit, p.ty)) try keep.append(c.scratch(), m);
            } else {
                try keep.append(c.scratch(), m); // member does not constrain `key`
            }
        }
        if (keep.items.len > 0 and keep.items.len < surviving.len) {
            surviving = try c.scratch().dupe(TypeId, keep.items);
            narrowed = true;
        }
    }
    if (!narrowed) return rctx;
    return c.ts.makeUnion(c.scratch(), surviving);
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
pub fn distributableSpreads(c: *Checker, node: Node, out: *std.ArrayList(DistSpread)) Error!void {
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

pub fn checkObjectLiteral(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
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
    try c.distributableSpreads(node, &dist);
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
            try outs.append(c.scratch(), try c.objectLiteralType(node, ctx, subst.items));
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
    return c.objectLiteralType(node, ctx, &.{});
}

/// A spread element whose source type is replaced by `ty` for one
/// constituent of a distributed object literal (see `checkObjectLiteral`).
pub const Subst = struct { node: Node, ty: TypeId };

/// One constituent of an object literal's type. `dist` names the spread
/// elements whose source types are replaced for this constituent (see
/// `checkObjectLiteral`); it is empty for an undistributed literal.
pub fn objectLiteralType(c: *Checker, node: Node, ctx: TypeId, dist: []const Subst) Error!TypeId {
    var rctx = if (ctx != types.no_type) try c.resolveStructural(ctx) else types.no_type;
    if (rctx != types.no_type and c.ts.kind(rctx) == .union_type) {
        rctx = try c.discriminateCtxUnion(node, rctx);
    }
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
        switch (c.nodeTag(prop)) {
            .object_property => {
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                    const key_expr = c.tree.nodeData(pd.lhs).lhs;
                    const kt = try c.checkExprCached(key_expr, types.no_type);
                    // A `unique symbol` key names a real, nominally-keyed
                    // property (`{ [k]: v }`); any other computed key stays
                    // dynamic (no static member).
                    if (try c.uniqueSymAtom(kt)) |key| {
                        const pctx = try c.ctxPropType(rctx, ctx, key);
                        var vt = try c.checkExprCached(pd.rhs, pctx);
                        if (c.const_ctx) {
                            vt = try c.ts.regularLiteral(vt);
                        } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                        continue;
                    }
                    // A qualified enum-member computed key (`{ [Breed.X]: v
                    // }`): the key is the member's *value*, which a computed
                    // member leaves unknown, so — exactly like the
                    // type-literal/interface member — key it by the
                    // text-derived `__@k$<obj>.<member>` placeholder. This
                    // makes the literal match a `{ [Breed.X]: … }` target
                    // (whose members the binder keys the same way) instead of
                    // dropping the property and collapsing to `{}`.
                    if (c.ts.kind(try c.resolveStructural(kt)) == .enum_type and
                        c.nodeTag(key_expr) == .member_expr)
                    {
                        const member_tok = c.tree.nodeData(key_expr).rhs;
                        const key = try c.computedSymKey(member_tok, ast.Flags.computed_sym | ast.Flags.computed_sym_qual, c.cur_scope);
                        const pctx = try c.ctxPropType(rctx, ctx, key);
                        var vt = try c.checkExprCached(pd.rhs, pctx);
                        if (c.const_ctx) {
                            vt = try c.ts.regularLiteral(vt);
                        } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
                        continue;
                    }
                    // Non-symbol computed key (`{ [expr]: v }`): a `string`-
                    // or `number`-widening key contributes an index
                    // signature; a literal key names a real property. The
                    // value is contextually typed by the target's matching
                    // property/index (so `value: STATUS` under a `Record<…>`
                    // context keeps its literal instead of widening).
                    const rk = try c.resolveStructural(kt);
                    const key_kind = c.ts.kind(rk);
                    const pctx: TypeId = if (rctx == types.no_type) types.no_type else switch (key_kind) {
                        .string_literal => try c.ctxPropType(rctx, ctx, c.ts.dataA(rk)),
                        .string, .template_literal_type, .string_mapping => try c.ctxIndexType(rctx, false),
                        .number, .number_literal, .number_literal_fresh => try c.ctxIndexType(rctx, true),
                        else => types.no_type,
                    };
                    var vt = try c.checkExprCached(pd.rhs, pctx);
                    if (c.const_ctx) {
                        vt = try c.ts.regularLiteral(vt);
                    } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                    switch (key_kind) {
                        .string_literal => {
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = c.ts.dataA(rk), .ty = vt });
                        },
                        .string, .template_literal_type, .string_mapping => try str_index_vals.append(c.scratch(), vt),
                        .number, .number_literal, .number_literal_fresh => try num_index_vals.append(c.scratch(), vt),
                        else => {}, // symbol/unknown/other: no static member
                    }
                    continue;
                }
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                const pctx = try c.ctxPropType(rctx, ctx, key);
                var vt = try c.checkExprCached(pd.rhs, pctx);
                if (c.const_ctx) {
                    vt = try c.ts.regularLiteral(vt);
                } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = key, .ty = vt });
            },
            .object_shorthand => {
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                var vt = try c.checkExprCached(pd.lhs, types.no_type);
                const pctx = try c.ctxPropType(rctx, ctx, key);
                if (c.const_ctx) {
                    vt = try c.ts.regularLiteral(vt);
                } else if (!try c.keepLiteral(vt, pctx)) vt = try c.widenLiteral(vt);
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
                const saved_this = c.this_type;
                defer c.this_type = saved_this;
                c.this_type = if (rctx != types.no_type) rctx else 0;
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) {
                    _ = try c.checkExprCached(pd.rhs, types.no_type);
                    continue;
                }
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
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
                            for (try c.memberList(st)) |m| {
                                const rm = try c.resolveStructural(m);
                                switch (c.ts.kind(rm)) {
                                    .type_param, .mapped, .index_access, .conditional => {},
                                    else => try c.gatherSpreadProps(rm, &props, &prop_index, &str_index_vals, &num_index_vals),
                                }
                            }
                            continue;
                        }
                    },
                    else => {},
                }
                try c.gatherSpreadProps(st, &props, &prop_index, &str_index_vals, &num_index_vals);
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
    const sidx = if (str_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), str_index_vals.items) else 0;
    const nidx = if (num_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), num_index_vals.items) else 0;
    const obj = try c.ts.makeObject(props.items, sidx, nidx, types.obj_flag_fresh);
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
pub fn ctxIndexType(c: *Checker, rctx: TypeId, want_number: bool) Error!TypeId {
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
                const it = try c.ctxIndexType(try c.resolveStructural(m), want_number);
                if (it != types.no_type) try parts.append(c.scratch(), it);
            }
            if (parts.items.len == 0) return types.no_type;
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        // First constituent that carries one, matching how the relation
        // reads an intersection's index signatures.
        .intersection => {
            for (try c.memberList(rctx)) |m| {
                const it = try c.ctxIndexType(try c.resolveStructural(m), want_number);
                if (it != types.no_type) return it;
            }
            return types.no_type;
        },
        else => return types.no_type,
    }
}

/// Contextual type for property `key` of an object literal typed by
/// `ctx` (unions: union of the property across constituents).
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
            if (try c.propOfType(rctx, key)) |p| return p.ty;
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

/// Type of a chain link's object/callee, WITHOUT the chain's short-circuit
/// `undefined` (that is tracked in `chained`). Only called when `node` is
/// itself an optional chain, so downstream declared-nullish still reports.
pub fn chainObjType(c: *Checker, node: Node, chained: *bool) Error!TypeId {
    return switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr => c.memberChainInner(node, chained),
        .index_expr, .optional_index_expr => c.indexChainInner(node, chained, true),
        .call_expr, .call_expr_targs, .optional_call => c.checkCallExprInner(node, false, chained, types.no_type),
        else => c.checkExprCached(node, types.no_type),
    };
}

pub fn checkMemberExpr(c: *Checker, node: Node) Error!TypeId {
    var chained = false;
    const pt = try c.memberChainInner(node, &chained);
    if (chained) return c.makeUnion2(pt, types.undefined_type);
    return pt;
}

/// Property access, treated as a link in a (possibly single-element)
/// optional chain. Returns the property type WITHOUT the chain's
/// short-circuit `undefined`; sets `chained.*` when this `?.` link — or an
/// earlier one in the object spine — short-circuits on a nullish object. A
/// non-`?.` continuation whose object is *declared* nullish still reports
/// TS2532/18047-9 via `checkNullishAccess` (the marker distinguishes the
/// chain's own undefined from an inherently-nullable intermediate).
pub fn memberChainInner(c: *Checker, node: Node, chained: *bool) Error!TypeId {
    const d = c.tree.nodeData(node);
    const own_optional = c.nodeTag(node) == .optional_member_expr;
    var obj_t = if (c.isOptionalChain(d.lhs))
        try c.chainObjType(d.lhs, chained)
    else
        try c.checkExprCached(d.lhs, types.no_type);
    const name_tok: TokenIndex = d.rhs;
    const name = try c.memberAtom(name_tok);
    if (own_optional) {
        if (c.containsNullish(obj_t) or c.ts.kind(obj_t) == .null or c.ts.kind(obj_t) == .undefined) {
            chained.* = true;
        }
        obj_t = try c.nonNullableChain(obj_t);
    } else {
        obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
    }
    var pt = try c.propertyTypeOf(obj_t, name, name_tok);
    // Property-path narrowing: peel the whole access spine into a member
    // path (`x.p`, `this.p`, `x.a.b`, …) capped at `max_deep_ref_depth`.
    if (try c.buildRefKey(node)) |key| {
        pt = try c.flowTypeOfKey(node, key, pt);
    }
    return pt;
}

/// TS18047/18048/18049 (entity names) / TS2531/2532/2533 (expressions)
/// for non-optional access on possibly-nullish objects. Returns the
/// non-nullable remainder to continue checking with.
pub fn checkNullishAccess(c: *Checker, t: TypeId, obj_node: Node, access_node: Node) Error!TypeId {
    const k = c.ts.kind(t);
    const has_null = c.containsNull(t) or k == .null;
    const has_undef = c.containsUndefinedish(t) or k == .undefined or k == .void;
    if (!has_null and !has_undef) return t;
    _ = access_node;
    const span = c.nodeSpan(obj_node);
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
    const name_opt: ?[]const u8 = if (this_rooted) null else c.entityNameOf(obj_node);
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
    // tsc's `checkNonNullTypeWithReporter`: once the nullish access has been
    // reported, a remainder that is `never` (the object was *only* nullish —
    // `null`, `undefined`, or a reference the flow narrowed to nothing else)
    // degrades to the error type, not to `never`. That keeps the single
    // "possibly null/undefined" diagnostic from being doubled by a TS2339 on
    // `never` from the member lookup that follows.
    const nn = try c.nonNullable(t);
    if (c.ts.kind(nn) == .never) return types.error_type;
    return nn;
}

/// Render an entity-name-ish expression (a, a.b, a.b.c) or null.
pub fn entityNameOf(c: *Checker, node: Node) ?[]const u8 {
    switch (c.nodeTag(node)) {
        .identifier => return c.tokenText(c.tree.nodeMainToken(node)),
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            // A `?.` link still roots an entity-name path, so tsc uses the
            // named codes (18047-9) rather than the object codes (2531-3)
            // for a nullish access on `a?.b`.
            const base = c.entityNameOf(d.lhs) orelse return null;
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
pub fn propertyTypeOf(c: *Checker, t: TypeId, name: Atom, name_tok: TokenIndex) Error!TypeId {
    const k = c.ts.kind(t);
    switch (k) {
        .any, .err, .none => return types.any_type,
        // `never` has no members, so tsc's `getPropertyOfType` finds nothing
        // and `checkPropertyAccessExpression` reports. The two `never`s that
        // must NOT arrive here are handled where tsc handles them: a read in
        // unreachable code answers with the DECLARED type (`flowTypeOfKey`),
        // and the empty remainder of a nullish access degrades to the error
        // type after its own diagnostic (`checkNullishAccess`).
        .never => {
            try c.diagFmt(2339, c.tokSpan(name_tok), "Property '{s}' does not exist on type 'never'.", .{
                c.atomText(name),
            });
            return types.error_type;
        },
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
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
                var pt = try c.substThis(p.ty, m);
                if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                try parts.append(c.scratch(), pt);
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
                var pt = try c.substThis(p.ty, t);
                if (p.optional()) pt = try c.makeUnion2(pt, types.undefined_type);
                return pt;
            }
            const r = try c.resolveStructural(t);
            if (c.ts.kind(r) == .any or c.ts.kind(r) == .err) return types.any_type;
            if (try c.propOfType(r, name)) |p| {
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
        },
    }
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
    return c.propOfType(r, try c.internText(txt));
}

pub fn checkIndexExpr(c: *Checker, node: Node, narrow: bool) Error!TypeId {
    var chained = false;
    const r = try c.indexChainInner(node, &chained, narrow);
    if (chained) return c.makeUnion2(r, types.undefined_type);
    return r;
}

/// Element access as an optional-chain link (see `memberChainInner`).
pub fn indexChainInner(c: *Checker, node: Node, chained: *bool, narrow: bool) Error!TypeId {
    const d = c.tree.nodeData(node);
    const own_optional = c.nodeTag(node) == .optional_index_expr;
    var obj_t = if (c.isOptionalChain(d.lhs))
        try c.chainObjType(d.lhs, chained)
    else
        try c.checkExprCached(d.lhs, types.no_type);
    // The index expression runs only on the chain's non-nullish branch, so
    // it sees the chain's own guards (`pushChainGuards`).
    const idx_t = idx: {
        const saved = c.chain_guards.items.len;
        defer c.chain_guards.shrinkRetainingCapacity(saved);
        try c.pushChainGuards(node);
        break :idx try c.checkExprCached(d.rhs, types.no_type);
    };
    if (own_optional) {
        if (c.containsNullish(obj_t)) chained.* = true;
        obj_t = try c.nonNullableChain(obj_t);
    } else {
        obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
    }
    const r = try c.resolveStructural(obj_t);
    const rk = c.ts.kind(r);
    if (rk == .any or rk == .err) return types.any_type;
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
        return result;
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
        return result;
    }
    const ik = c.ts.kind(try c.ts.regularLiteral(idx_t));
    // tsc's `getIndexedAccessType` distributes over a UNION index type:
    // `o[k]` with `k: "a" | "b"` is `o["a"] | o["b"]`. Without this arm a
    // union key matched none of the kinds below and fell through to the
    // string-like `else`, where an object with no string index signature
    // yields `any` — so every read through a `Record<SomeUnion, T>` lost
    // its type, and with it the contextual signature of any callback the
    // read fed (`map[dir].map((c) => c)`).
    var miss: UnionIndexMiss = .none;
    const distributed = try c.unionIndexElemType(r, idx_t, &miss);
    // A key set that did NOT distribute is still reported on: tsc's
    // `getIndexedAccessType` errors on the offending constituent and the
    // access falls back to `any` (TS7053) or to the receiver's numeric index
    // signature (TS2493, out-of-range tuple constituent). Only the two
    // certain shapes reach here (see `UnionIndexMiss`); the fallback type
    // below is unchanged either way, so whatever the access already reported
    // downstream still reports.
    switch (miss) {
        .none => {},
        .absent_key => if (c.prog.no_implicit_any) {
            try c.diagFmt(7053, c.nodeSpan(node), "Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{
                try c.typeToString(idx_t), try c.typeToString(obj_t),
            });
        },
        .tuple_range => |tr| try c.diagFmt(2493, c.nodeSpan(d.rhs), "Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{
            try c.typeToString(tr.tuple), c.ts.tupleLen(tr.tuple), tr.index,
        }),
    }
    if (distributed) |ut| {
        result = ut;
    } else switch (ik) {
        .string_literal => {
            const key = c.ts.literalAtom(try c.ts.regularLiteral(idx_t));
            if (try c.propOfType(r, key)) |p| {
                result = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            } else if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                result = c.ts.objectStringIndex(r);
            } else {
                // Element access `o['k']` with a string-literal key that is
                // neither a known property nor covered by a string index is,
                // for tsc, an implicit-'any' element access (TS7053) — NOT a
                // missing-property TS2339 (which is reserved for dotted `o.k`).
                // Suppressed under `noImplicitAny: false`; the result is `any`
                // either way.
                if (c.prog.no_implicit_any) {
                    try c.diagFmt(7053, c.nodeSpan(node), "Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{
                        try c.typeToString(idx_t), try c.typeToString(obj_t),
                    });
                }
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
                const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                if (iv < c.ts.tupleLen(rt)) {
                    const e = c.ts.tupleElem(rt, iv);
                    result = if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
                } else if (try c.tupleElemTypeAt(rt, iv)) |et| {
                    result = et;
                } else {
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
                result = try c.numberIndexType(r);
            }
        },
        .number => result = try c.numberIndexType(r),
        .string => {
            if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                result = c.ts.objectStringIndex(r);
            } else if (rk == .array or rk == .tuple or rk == .string) {
                result = types.any_type;
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
                if (rk == .object and c.prog.no_implicit_any and
                    c.ts.objectFlags(r) & types.obj_flag_global_this == 0)
                {
                    try c.diagFmt(7053, c.nodeSpan(node), "Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{
                        try c.typeToString(idx_t), try c.typeToString(obj_t),
                    });
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
        if (try c.buildRefKey(node)) |key| {
            result = try c.flowTypeOfKey(node, key, result);
        }
    }
    return result;
}

pub fn checkPrefixUnary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    switch (op) {
        .keyword_typeof => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return c.typeof_union;
        },
        .bang => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.boolean_type;
        },
        .keyword_void => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.undefined_type;
        },
        .keyword_delete => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
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
            const ot = try c.checkExprCached(d.lhs, types.no_type);
            const rl = try c.ts.regularLiteral(ot);
            if (c.ts.kind(rl) == .number_literal) {
                return c.ts.makeNumberLiteral(-c.ts.numberValue(rl), c.ts.isFreshLiteral(ot));
            }
            // `bigint` only when the operand actually CARRIES a bigint
            // constituent: tsc's getUnaryResultType tests
            // `maybeTypeOfKind(t, BigIntLike)`, not assignability, so the
            // types that are vacuously assignable to bigint — `never`
            // (no constituents) and `any` — coerce to `number` like every
            // other non-bigint operand. `isBigintish` is the assignability
            // test, so exclude the operands that are equally numberish;
            // this mirrors the binary `-`/`*` arm below.
            if (try c.isBigintish(ot) and !try c.isNumberish(ot)) return types.bigint_type;
            return types.number_type;
        },
        .plus, .tilde => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.number_type;
        },
        .plus_plus, .minus_minus => {
            const ot = try c.checkExprCached(d.lhs, types.no_type);
            try c.checkArithmeticOperand(ot, d.lhs);
            return types.number_type;
        },
        else => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            return types.any_type;
        },
    }
}

pub fn isNumberish(c: *Checker, t: TypeId) Error!bool {
    return c.hasPrimitiveFacet(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return switch (ch.ts.kind(m)) {
                .number, .number_literal, .number_literal_fresh, .any, .err, .never => true,
                .enum_type => !ch.enumHasStringMember(ch.ts.enumSymbol(m)),
                else => false,
            };
        }
    }.f, 0);
}

pub fn isBigintish(c: *Checker, t: TypeId) Error!bool {
    return c.hasPrimitiveFacet(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return switch (ch.ts.kind(m)) {
                .bigint, .bigint_literal, .any, .err, .never => true,
                else => false,
            };
        }
    }.f, 0);
}

pub fn isStringish(c: *Checker, t: TypeId) Error!bool {
    return c.hasPrimitiveFacet(t, struct {
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
pub fn hasPrimitiveFacet(c: *Checker, t: TypeId, comptime f: fn (*Checker, TypeId) bool, depth: u32) Error!bool {
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
                if (!try c.hasPrimitiveFacet(m, f, depth + 1)) return false;
            }
            return true;
        },
        .intersection => {
            for (0..c.ts.memberCount(t)) |i| {
                if (f(c, c.ts.memberAt(t, i))) return true;
            }
            for (try c.memberList(t)) |m| {
                if (try c.hasPrimitiveFacet(m, f, depth + 1)) return true;
            }
            return false;
        },
        .ref => {
            const rs = try c.resolveStructural(t);
            if (rs == t) return false;
            return c.hasPrimitiveFacet(rs, f, depth + 1);
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
            if (con == types.no_type or con == t) return false;
            return c.hasPrimitiveFacet(con, f, depth + 1);
        },
        else => return false,
    }
}

pub fn isArithmeticOperand(c: *Checker, t: TypeId) Error!bool {
    return (try c.isNumberish(t)) or (try c.isBigintish(t));
}

pub fn checkArithmeticOperand(c: *Checker, t: TypeId, node: Node) Error!void {
    if (try c.isArithmeticOperand(t)) return;
    try c.diagFmt(2356, c.nodeSpan(node), "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.", .{});
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
pub fn instanceofRhsIsFunctionLike(c: *Checker, t: TypeId, depth: u32) Error!bool {
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
                if (!try c.instanceofRhsIsFunctionLike(m, depth + 1)) return false;
            }
            return true;
        },
        .intersection => {
            for (try c.memberList(rs)) |m| {
                if (try c.instanceofRhsIsFunctionLike(m, depth + 1)) return true;
            }
            return false;
        },
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rs));
            if (con == types.no_type or con == rs or con == t) return false;
            return c.instanceofRhsIsFunctionLike(con, depth + 1);
        },
        else => return false,
    }
}

pub fn checkBinary(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
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
            const lt = try c.checkExprCached(d.lhs, types.no_type);
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
        .pipe_pipe => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, if (ctx == types.no_type) lt else ctx);
            const truthy = try c.getTruthyPart(lt);
            if (!try c.canBeFalsy(lt, 0)) return lt;
            return c.logicalUnion(truthy, rt);
        },
        .question_question => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, if (ctx == types.no_type) lt else ctx);
            if (!try c.canBeNullish(lt, 0)) return lt;
            return c.logicalUnion(try c.nonNullableNullish(lt), rt);
        },
        .plus => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            const lk = c.ts.kind(lt);
            const rk = c.ts.kind(rt);
            if (lk == .any or rk == .any or lk == .err or rk == .err) return types.any_type;
            if (try c.isStringish(lt) or try c.isStringish(rt)) {
                // string + anything stringifiable
                return types.string_type;
            }
            if (try c.isNumberish(lt) and try c.isNumberish(rt)) return types.number_type;
            if (try c.isBigintish(lt) and try c.isBigintish(rt)) return types.bigint_type;
            try c.diagFmt(2365, c.nodeSpan(node), "Operator '+' cannot be applied to types '{s}' and '{s}'.", .{
                try c.typeToString(lt), try c.typeToString(rt),
            });
            return types.error_type;
        },
        .minus, .asterisk, .slash, .percent, .asterisk_asterisk, .lt_lt, .gt_gt, .gt_gt_gt, .amp, .pipe, .caret => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            if (!try c.isArithmeticOperand(lt)) {
                try c.diagFmt(2362, c.nodeSpan(d.lhs), "The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
            }
            if (!try c.isArithmeticOperand(rt)) {
                try c.diagFmt(2363, c.nodeSpan(d.rhs), "The right-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.", .{});
            }
            if (try c.isBigintish(lt) and try c.isBigintish(rt) and
                !try c.isNumberish(lt) and !try c.isNumberish(rt)) return types.bigint_type;
            return types.number_type;
        },
        .lt, .gt, .lt_eq, .gt_eq => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            // tsc's relational rule (checkBinaryLikeExpressionWorker): strip
            // null/undefined (checkNonNullType), then the pair is legal iff
            // BOTH sides are number/bigint-like, OR NEITHER side is
            // number-like and one is comparable to the other. The
            // "neither number-like" guard is essential: it rejects
            // `{valueOf():number} > number` even though `number` is
            // assignable to `{valueOf():number}` (oracle-verified), while
            // still admitting `Date > Date`, `string > string`, and any two
            // structurally-comparable object types.
            const ls = try c.nonNullable(lt);
            const rs = try c.nonNullable(rt);
            const lk = c.ts.kind(ls);
            const rk = c.ts.kind(rs);
            const ok = lk == .any or rk == .any or lk == .err or rk == .err or blk: {
                const lnum = try c.isNumberish(ls) or try c.isBigintish(ls);
                const rnum = try c.isNumberish(rs) or try c.isBigintish(rs);
                if (lnum and rnum) break :blk true;
                if (!lnum and !rnum) break :blk (try c.isComparable(ls, rs));
                break :blk false;
            };
            if (!ok) {
                try c.diagFmt(2365, c.nodeSpan(node), "Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{
                    c.tokenText(c.tree.nodeMainToken(node)), try c.typeToString(lt), try c.typeToString(rt),
                });
            }
            return types.boolean_type;
        },
        .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            // TS2367: no overlap (any union constituents comparable).
            if (!try c.typesHaveOverlap(lt, rt)) {
                try c.diagFmt(2367, c.nodeSpan(node), "This comparison appears to be unintentional because the types '{s}' and '{s}' have no overlap.", .{
                    try c.typeToString(lt), try c.typeToString(rt),
                });
            }
            return types.boolean_type;
        },
        .keyword_instanceof => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
            if (!try c.instanceofRhsIsFunctionLike(rt, 0)) {
                try c.diagFmt(2359, c.nodeSpan(d.rhs), "The right-hand side of an 'instanceof' expression must be of type 'any' or of a type assignable to the 'Function' interface type.", .{});
            }
            return types.boolean_type;
        },
        .keyword_in => {
            const lt = try c.checkExprCached(d.lhs, types.no_type);
            const rt = try c.checkExprCached(d.rhs, types.no_type);
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
            const rk = c.ts.kind(try c.resolveStructural(rt));
            if (!isNonPrimitiveKind(rk) and rk != .any and rk != .err and rk != .type_param and rk != .union_type and rk != .unknown) {
                try c.diagFmt(2361, c.nodeSpan(d.rhs), "The right-hand side of an 'in' expression must not be a primitive.", .{});
            }
            return types.boolean_type;
        },
        else => {
            _ = try c.checkExprCached(d.lhs, types.no_type);
            _ = try c.checkExprCached(d.rhs, types.no_type);
            return types.any_type;
        },
    }
}

pub fn checkAssignExpr(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    const target_t = try c.checkAssignmentTarget(d.lhs);
    // Writing an evolving (`auto`-typed) variable is unchecked: its
    // `null`/`undefined` declared type is where the flow type starts, not
    // a constraint on what may be stored (tsc's autoType). The type itself
    // is still what `checkAssignmentTarget` returned, so `+=` classifies
    // the operand the same way it would for any other declared type.
    const unchecked = c.assignTargetIsEvolving(d.lhs);
    var rhs_ctx: TypeId = if (op == .eq) target_t else types.no_type;
    if (target_t == types.error_type or unchecked) rhs_ctx = types.no_type;
    const rt = try c.checkExprCached(d.rhs, rhs_ctx);
    switch (op) {
        .eq => {
            if (!unchecked and target_t != types.error_type and target_t != types.any_type) {
                _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
            }
            return rt;
        },
        .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => {
            if (!unchecked and target_t != types.error_type and target_t != types.any_type) {
                _ = try c.checkAssignable(rt, target_t, d.rhs, c.nodeSpan(d.lhs));
            }
            return rt;
        },
        // `+=`, `-=`, `*=`, … : the operation's RESULT is what gets stored,
        // so tsc runs the same assignability check `=` runs, with the
        // operator's result type as the source (`checkAssignmentOperator`
        // with the value type computed by `checkBinaryLikeExpressionWorker`).
        // `x += 1` on a branded `number & { _brand }` therefore fails the
        // same way `x = x + 1` does: the operation widens to `number`.
        else => {
            const lt = try c.compoundTargetBase(target_t);
            const res = try c.compoundResultType(op, lt, rt);
            if (res == types.no_type) {
                // Operands too coarse to classify (`any`/error, or not
                // arithmetic at all — where tsc reports TS2362/TS2363/TS2365
                // and skips the assignment check). Keep the old, unchecked
                // approximation of the expression's type.
                if (op == .plus_eq and try c.isStringish(lt)) return types.string_type;
                return types.number_type;
            }
            if (!unchecked and lt != types.error_type and lt != types.any_type) {
                // No expression node: the source type is synthesized by the
                // operator, so there is no literal to elaborate or excess-check.
                _ = try c.checkAssignable(res, lt, null_node, c.nodeSpan(d.lhs));
            }
            return res;
        },
    }
}

/// The type a compound assignment's TARGET reads (and is written back) as:
/// tsc's `checkIdentifier` returns `getBaseTypeOfLiteralType(flowType)` for
/// a reference in assignment-target position, so a literal type widens to
/// its base before either the operand classification or the write-back
/// check sees it. That is what makes `let d: -1 | 1 = 1; d *= -1` and
/// `let s: "a" | "b"; s += "x"` legal — the target reads as `number` /
/// `string` there. Only literal, enum-member and boolean-literal types
/// widen; a branded `number & { _brand }` is not a literal type and stays
/// exactly as declared, which is why `mv += 1` on it still fails.
pub fn compoundTargetBase(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var list: std.ArrayList(TypeId) = .empty;
        defer list.deinit(c.scratch());
        var changed = false;
        for (try c.memberList(t)) |m| {
            const b = try c.compoundTargetBase(m);
            if (b != m) changed = true;
            try list.append(c.scratch(), b);
        }
        if (!changed) return t;
        return c.ts.makeUnion(c.scratch(), list.items);
    }
    const base = try c.literalBaseOf(t);
    return if (base != types.no_type) base else t;
}

/// Result type of a compound assignment's operation (`+=`, `-=`, `*=`, …),
/// mirroring what `checkBinaryExpr` computes for the plain operator — or
/// `no_type` when the operands are not classified sharply enough for the
/// back-assignability check to be sound. That "give up" case covers `any`
/// and error operands (tsc's result is `any`, which never fails the check)
/// and operands that are not arithmetic at all, where tsc reports the
/// operand diagnostic and skips the assignment check entirely.
pub fn compoundResultType(c: *Checker, op: scanner.Tag, lt: TypeId, rt: TypeId) Error!TypeId {
    const lk = c.ts.kind(lt);
    const rk = c.ts.kind(rt);
    if (lk == .any or rk == .any or lk == .err or rk == .err) return types.no_type;
    if (op == .plus_eq) {
        if (try c.isStringish(lt) or try c.isStringish(rt)) return types.string_type;
        if (try c.isNumberish(lt) and try c.isNumberish(rt)) return types.number_type;
        if (try c.isBigintish(lt) and try c.isBigintish(rt)) return types.bigint_type;
        return types.no_type;
    }
    if (!try c.isArithmeticOperand(lt) or !try c.isArithmeticOperand(rt)) return types.no_type;
    if (try c.isBigintish(lt) and try c.isBigintish(rt) and
        !try c.isNumberish(lt) and !try c.isNumberish(rt)) return types.bigint_type;
    return types.number_type;
}

/// Does this assignment target name an evolving (`auto`-typed) variable?
pub fn assignTargetIsEvolving(c: *Checker, target0: Node) bool {
    var n = target0;
    while (n != null_node and c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    if (n == null_node or c.nodeTag(n) != .identifier) return false;
    const a = c.atomOfToken(c.tree.nodeMainToken(n)) catch return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| c.isEvolvingVar(sym),
        else => false,
    };
}

/// Type of an assignment target; reports TS2588 (const) and TS2540
/// (readonly property).
pub fn checkAssignmentTarget(c: *Checker, node: Node) Error!TypeId {
    switch (c.nodeTag(node)) {
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
            var obj_t = try c.checkExprCached(d.lhs, types.no_type);
            obj_t = try c.checkNullishAccess(obj_t, d.lhs, node);
            const name = try c.memberAtom(d.rhs);
            const r = try c.resolveStructural(obj_t);
            if (try c.propOfType(r, name)) |p| {
                // A readonly property may be assigned via `this.x` inside the
                // constructor of the class that OWNS the declaration (tsc:
                // `checkReferenceExpression`). An inherited readonly still
                // errors, so the property must be an OWN member of the
                // constructor's class.
                const ctor_ok = c.nodeTag(d.lhs) == .this_expr and c.ctorClassOwnsMember(name);
                if (p.readonly() and !ctor_ok) {
                    try c.diagFmt(2540, c.tokSpan(d.rhs), "Cannot assign to '{s}' because it is a read-only property.", .{c.atomText(name)});
                    return types.error_type; // suppress cascading 2322
                }
                // TS 4.3 split accessors (`get x(): A; set x(v: B)`): the
                // WRITE type is the setter's parameter, not the property's
                // (getter's) type. See `setterWriteType`.
                const wt = (try c.setterWriteType(obj_t, name, 0)) orelse p.ty;
                // An optional property accepts `undefined` as a write target
                // (exactOptionalPropertyTypes is off): `x.opt = undefined` is
                // legal. Fold `| undefined` in exactly as the read path does,
                // so the write-target type is not narrower than the read type.
                if (p.optional()) return c.makeUnion2(wt, types.undefined_type);
                return wt;
            }
            return c.propertyTypeOf(obj_t, name, d.rhs);
        },
        .index_expr => {
            // Writing to a readonly tuple element (from `as const`) is
            // TS2540, like a readonly property.
            const d = c.tree.nodeData(node);
            const obj_t = try c.checkExprCached(d.lhs, types.no_type);
            // `o["p"] = v` writes at the setter's parameter type when `p` is
            // a TS 4.3 split accessor, exactly as `o.p = v` does. Keyed off
            // the *syntactic* string literal so no extra expression is
            // checked on the ordinary element-write path.
            if (c.nodeTag(d.rhs) == .string_literal) {
                const key = try c.memberAtom(c.tree.nodeMainToken(d.rhs));
                if (try c.setterWriteType(obj_t, key, 0)) |wt| return wt;
            }
            const r = try c.resolveStructural(obj_t);
            if (c.ts.kind(r) == .tuple) {
                const idx_t = try c.ts.regularLiteral(try c.checkExprCached(d.rhs, types.no_type));
                if (c.ts.kind(idx_t) == .number_literal) {
                    const v = c.ts.numberValue(idx_t);
                    const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                    if (iv < c.ts.tupleLen(r) and c.ts.tupleElem(r, iv).readonly()) {
                        try c.diagFmt(2540, c.nodeSpan(d.rhs), "Cannot assign to '{d}' because it is a read-only property.", .{iv});
                        return types.error_type;
                    }
                }
            }
            return c.checkIndexExpr(node, false);
        },
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            // Destructuring-assignment pattern in the expression cover
            // grammar (`[a, b] = …`, `({ p: a } = …)`). Every element is a
            // WRITE, so it goes through `checkDestructuringElement`, not
            // `checkExprCached`: an element identifier must resolve as an
            // assignment target (no TDZ / definite-assignment read check)
            // and a property KEY is a name, not a reference.
            for (c.tree.nodeRange(node)) |el| try c.checkDestructuringElement(el);
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
pub fn setterWriteType(c: *Checker, t0: TypeId, name: Atom, depth: u32) Error!?TypeId {
    if (depth > 8) return null;
    const t = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    switch (c.ts.kind(t)) {
        .union_type, .intersection => {
            for (c.ts.members(t)) |m| {
                if (try c.setterWriteType(m, name, depth + 1)) |wt| return wt;
            }
            return null;
        },
        .ref => {
            const sym = c.ts.refSymbol(t);
            const f = c.symFlags(sym);
            const raw: ?TypeId = if (f.interface)
                try c.interfaceSetterParam(sym, name, depth)
            else if (f.class)
                try c.classSetterParam(sym, name, depth)
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
pub fn interfaceSetterParam(c: *Checker, sym: SymbolId, name: Atom, depth: u32) Error!?TypeId {
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
        if (try c.setterParamInMembers(members, name)) |wt| return wt;
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
            if (try c.setterWriteType(base, name, depth + 1)) |wt| return wt;
        }
    }
    return null;
}

/// Scan a member-node list for `set <name>(v)` and answer its parameter
/// type.
pub fn setterParamInMembers(c: *Checker, members: []const Node, name: Atom) Error!?TypeId {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .method_signature) continue;
        const md = c.tree.nodeData(m);
        if (md.rhs & ast.Flags.set == 0) continue;
        if (try c.memberKey(c.tree.nodeMainToken(m), md.rhs) != name) continue;
        return try c.setterParamOfProto(m, md.lhs);
    }
    return null;
}

/// The parameter type of `set <name>(v)` declared on class `sym`, else on
/// its base class. `this` is the class instance, as `classInstanceGeneric`
/// binds it while converting the members.
pub fn classSetterParam(c: *Checker, sym: SymbolId, name: Atom, depth: u32) Error!?TypeId {
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
                return try c.setterParamOfProto(decl, d.lhs);
            }
            return null;
        }
    }
    if (try c.baseClassRef(sym)) |base_ref| {
        return c.setterWriteType(base_ref, name, depth + 1);
    }
    return null;
}

/// The declared type of a set accessor's single parameter. A setter with no
/// parameter (an error elsewhere) has no write type.
pub fn setterParamOfProto(c: *Checker, decl: Node, proto_idx: u32) Error!?TypeId {
    const sig = try c.signatureOfProto(decl, proto_idx, true, false);
    if (c.ts.kind(sig) != .function or c.ts.fnParamCount(sig) == 0) return null;
    return c.ts.fnParam(sig, 0).ty;
}

/// One element of a destructuring-assignment pattern, in the expression
/// cover grammar the parser keeps (`{ p: a }` is an `object_literal` of
/// `object_property`, not an `object_pattern`). Peels the element to its
/// assignment target and hands that to `checkAssignmentTarget`; default
/// initializers and computed keys are ordinary reads. Without the peel the
/// generic expression walker checked the property KEY as a reference
/// (TS2304 on `({ width: dx } = …)`) and the target identifier as a *read*,
/// so writing a not-yet-assigned `let` through a destructuring assignment
/// reported TS2454 at the write site itself.
pub fn checkDestructuringElement(c: *Checker, el0: Node) Error!void {
    var el = el0;
    while (el != null_node and c.nodeTag(el) == .paren_expr) el = c.tree.nodeData(el).lhs;
    if (el == null_node) return;
    const d = c.tree.nodeData(el);
    switch (c.nodeTag(el)) {
        // `{ key: target }` — `key` names a property, it is not a
        // reference; only a computed key is evaluated.
        .object_property => {
            if (d.lhs != null_node and c.nodeTag(d.lhs) == .computed_name)
                _ = try c.checkExprCached(c.tree.nodeData(d.lhs).lhs, types.no_type);
            try c.checkDestructuringElement(d.rhs);
        },
        // `{ a }` / `{ a = init }` — lhs is the target identifier, rhs the
        // default.
        .object_shorthand => {
            if (d.rhs != null_node) _ = try c.checkExprCached(d.rhs, types.no_type);
            try c.checkDestructuringElement(d.lhs);
        },
        // Declaration-shaped pattern nodes (a `for (…of…)` head can carry
        // one): main_token is the key, lhs the target (0 when shorthand).
        .binding_property => {
            if (d.rhs != null_node) _ = try c.checkExprCached(d.rhs, types.no_type);
            if (d.lhs != null_node) try c.checkDestructuringElement(d.lhs);
        },
        // `{[k]: target}` — the key IS evaluated; lhs is it, rhs the target.
        .binding_property_computed => {
            if (d.lhs != null_node) _ = try c.checkExprCached(d.lhs, types.no_type);
            if (d.rhs != null_node) try c.checkDestructuringElement(d.rhs);
        },
        .binding_default => {
            if (d.rhs != null_node) _ = try c.checkExprCached(d.rhs, types.no_type);
            try c.checkDestructuringElement(d.lhs);
        },
        // `[a = init] = …`: the cover grammar parses the default as a plain
        // assignment expression.
        .assign => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(el)) == .eq) {
                _ = try c.checkExprCached(d.rhs, types.no_type);
                try c.checkDestructuringElement(d.lhs);
            } else {
                _ = try c.checkExprCached(el, types.no_type);
            }
        },
        .spread_element, .rest_element => try c.checkDestructuringElement(d.lhs),
        .omitted, .error_node, .unsupported => {},
        else => _ = try c.checkAssignmentTarget(el),
    }
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
pub fn intersectedCallSignature(c: *Checker, rctx: TypeId) Error!TypeId {
    const s = &c.ts;
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    switch (s.kind(rctx)) {
        .function => try sigs.append(c.scratch(), rctx),
        .overloads => for (try c.memberList(rctx)) |ov| {
            try sigs.append(c.scratch(), ov);
        },
        .object => {
            for (0..s.objectCallSigCount(rctx)) |i| {
                try sigs.append(c.scratch(), s.objectCallSig(rctx, @intCast(i)));
            }
        },
        else => for (try c.memberList(rctx)) |m| {
            const rm = try c.resolveStructural(m);
            switch (s.kind(rm)) {
                .function => try sigs.append(c.scratch(), rm),
                .overloads => for (try c.memberList(rm)) |ov| {
                    try sigs.append(c.scratch(), ov);
                },
                // Every call signature of the constituent, including an
                // overload set's: `getSignaturesOfType` concatenates them all
                // and the combination below is what tsc applies to the result.
                .object => {
                    for (0..s.objectCallSigCount(rm)) |i| {
                        try sigs.append(c.scratch(), s.objectCallSig(rm, @intCast(i)));
                    }
                },
                else => {},
            }
        },
    }
    if (sigs.items.len == 0) return types.no_type;
    if (sigs.items.len == 1) return sigs.items[0];
    // Per signature: how many LEADING fixed parameters it declares, and the
    // element type of its trailing rest parameter (`no_type` when it has
    // none). tsc's `combineIntersectionParameters` reads a position through
    // `tryGetTypeAtPosition`, which answers a rest parameter's element type
    // for every position it covers — the reason `(...data: any[]) => void`
    // combines with `(message?: any, …rest) => void` instead of aborting.
    const fixed = try c.scratch().alloc(usize, sigs.items.len);
    defer c.scratch().free(fixed);
    const rest_elem = try c.scratch().alloc(TypeId, sigs.items.len);
    defer c.scratch().free(rest_elem);
    var max_fixed: usize = 0;
    var any_rest = false;
    for (sigs.items, 0..) |sig, si| {
        if (s.fnTypeParams(sig).len != 0 or s.fnThisType(sig) != 0) return types.no_type;
        fixed[si] = s.fnParamCount(sig);
        rest_elem[si] = types.no_type;
        for (0..s.fnParamCount(sig)) |i| {
            const p = s.fnParam(sig, @intCast(i));
            if (!p.rest()) continue;
            // Only a trailing rest with an array-shaped type is understood;
            // a tuple rest would need positional expansion.
            const rt = try c.resolveStructural(p.ty);
            if (i + 1 != s.fnParamCount(sig) or s.kind(rt) != .array) return types.no_type;
            fixed[si] = i;
            rest_elem[si] = s.arrayElem(rt);
            any_rest = true;
        }
        max_fixed = @max(max_fixed, fixed[si]);
    }
    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (0..max_fixed) |i| {
        parts.clearRetainingCapacity();
        var name: Atom = 0;
        var opt = false;
        for (sigs.items, 0..) |sig, si| {
            if (i >= fixed[si]) {
                if (rest_elem[si] != types.no_type) {
                    // Covered by the rest parameter, and a rest position is
                    // always optional.
                    opt = true;
                    try parts.append(c.scratch(), rest_elem[si]);
                    continue;
                }
                // A signature that does not declare this position leaves it
                // optional, matching tsc's `combineSignatures` arity rule.
                opt = true;
                continue;
            }
            const p = s.fnParam(sig, @intCast(i));
            if (name == 0) name = p.name;
            if (p.optional()) opt = true;
            try parts.append(c.scratch(), p.ty);
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
        for (sigs.items, 0..) |sig, si| {
            _ = sig;
            if (rest_elem[si] != types.no_type) try parts.append(c.scratch(), rest_elem[si]);
        }
        try params.append(c.scratch(), .{
            .name = 0,
            .ty = try s.makeArray(try s.makeUnion(c.scratch(), parts.items)),
            .flags = types.param_flag_rest,
        });
    }
    parts.clearRetainingCapacity();
    for (sigs.items) |sig| try parts.append(c.scratch(), s.fnReturn(sig));
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
pub fn contextualCallSig(c: *Checker, ctx: TypeId) Error!TypeId {
    var ctx_sig: TypeId = types.no_type;
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
        switch (c.ts.kind(rctx)) {
            .function => ctx_sig = rctx,
            // A callable-INTERFACE contextual type — a call signature plus
            // ordinary properties (`FunctionComponent<P>` with its
            // `displayName?`, `ForwardRefRenderFunction<T, P>`). tsc's
            // `getContextualSignature` reads the type's call signatures and
            // uses the SOLE one; SEVERAL are combined the same way an
            // intersection's are (`getIntersectedSignatures`). Without this an
            // arrow annotated with such an interface (`const Base: FC<Props> =
            // (props) => …`) got no contextual parameter types and reported
            // TS7006.
            .object => {
                if (c.ts.objectCallSigCount(rctx) == 1) {
                    ctx_sig = c.ts.objectCallSig(rctx, 0);
                } else if (c.ts.objectCallSigCount(rctx) > 1) {
                    ctx_sig = try c.intersectedCallSignature(rctx);
                }
            },
            // An OVERLOAD SET. `getSignaturesOfType` treats it exactly as it
            // treats an intersection of callables — several signatures — and
            // `getContextualCallSignature` combines them. A name declared by
            // both `lib.dom` and `@types/node` (`fetch`, `Console.trace`)
            // arrives here, and leaving it alone reported TS7006 on every
            // parameter of the arrow written for it.
            .overloads => ctx_sig = try c.intersectedCallSignature(rctx),
            .union_type => {
                for (try c.memberList(rctx)) |m| {
                    const rm = try c.resolveStructural(m);
                    if (c.ts.kind(rm) == .function) {
                        ctx_sig = rm;
                        break;
                    }
                    if (c.ts.kind(rm) == .object and c.ts.objectCallSigCount(rm) == 1) {
                        ctx_sig = c.ts.objectCallSig(rm, 0);
                        break;
                    }
                    // An optional property whose declared type is an
                    // intersection of callables arrives as
                    // `(A & B) | undefined`.
                    if (c.ts.kind(rm) == .intersection) {
                        const isig = try c.intersectedCallSignature(rm);
                        if (isig != types.no_type) {
                            ctx_sig = isig;
                            break;
                        }
                    }
                }
            },
            // An INTERSECTION of callables. `getSignaturesOfType` on an
            // intersection is the concatenation of its constituents', and
            // `getContextualCallSignature` then either takes the sole one
            // or COMBINES them (tsc's `getIntersectedSignatures`). A JSX
            // attribute of a component whose props are
            // `Omit<TriggerProps, "name"> & React.HTMLAttributes<…>` is
            // exactly this: both constituents declare `onToggle`, so the
            // attribute value's contextual type is
            // `((open: boolean) => void) & ReactEventHandler<…>` and the
            // arrow written for it reported TS7006 on every parameter.
            .intersection => ctx_sig = try c.intersectedCallSignature(rctx),
            else => {},
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

pub fn checkFunctionLikeExpr(c: *Checker, node: Node, ctx: TypeId) Error!TypeId {
    // A const assertion does not propagate into function bodies.
    const prev_cc = c.const_ctx;
    c.const_ctx = false;
    defer c.const_ctx = prev_cc;
    const d = c.tree.nodeData(node);
    const ctx_sig = try c.contextualCallSig(ctx);
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
        if (ctx_this != 0) c.this_type = ctx_this;
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
    const ctx_ret: TypeId = if (ctx_sig != types.no_type and c.ts.kind(ctx_sig) == .function)
        c.ts.fnReturn(ctx_sig)
    else
        types.no_type;
    try c.checkFunctionBody(node, d.lhs, d.rhs, sig, ctx_ret);
    return sig;
}

pub fn templateAtom(c: *Checker, tok: TokenIndex) Error!Atom {
    const text = c.tokenText(tok);
    if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
        return c.atom(text[1 .. text.len - 1]);
    }
    return c.atom(text);
}

pub fn numberTokenValue(c: *const Checker, tok: TokenIndex) f64 {
    const raw = c.tokenText(tok);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        if (n >= buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    const text = buf[0..n];
    if (text.len > 2 and text[0] == '0') {
        const radix: ?u8 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            const v = std.fmt.parseInt(u64, text[2..], r) catch return 0;
            return @floatFromInt(v);
        }
    }
    return std.fmt.parseFloat(f64, text) catch 0;
}
