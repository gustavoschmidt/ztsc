//! Type-argument inference: what each of a generic signature's type
//! parameters must be, given the call's arguments and its contextual return
//! type. tsc's `inferTypeArguments` / `inferFromTypes` / `getInferredType`,
//! including the reverse-mapped (`Partial<T>`-shaped parameter) subsystem and
//! the candidate-combination folds. The in-flight state of one such inference
//! is `InferCtx`, published as `Checker.infer_ctx` for the duration.
//!
//! Split out of `calls.zig`, which owns the rest of a call: shape, overload
//! resolution, argument checking and reporting. It calls in here through
//! `Checker`'s method aliases, and re-exports these entry points so the
//! `checker.zig` alias block and the other submodules keep resolving them
//! under their old home.

const std = @import("std");
const types = @import("../types.zig");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TpMap = @import("enums.zig").TpMap;
const calls = @import("calls.zig");
const isUnitLikeKind = @import("assign.zig").isUnitLikeKind;
const skipParens = @import("expr.zig").skipParens;
const tuple_relate = @import("tuple_relate.zig");
const typenode = @import("typenode.zig");

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

/// The contextual-RETURN half of tsc's `instantiateContextualType`: an
/// object-literal argument is checked against its parameter instantiated
/// with `context.returnMapper` — the `InferencePriority.ReturnType`
/// inferences made before any argument is looked at. When a parameter
/// property is typed by a still-free type parameter whose return-seed names
/// a literal domain, that seed IS the property's literal context, so the
/// fresh literal survives (`isLiteralOfContextualType`).
///
/// `platform: Platform["select"]` (`select<T>(spec: { web?: T; native?: T }):
/// T`) is the shape: `size={platform({web: 'tiny', native: 'small'})}` under
/// a contextual `"large" | "medium" | "small" | "tiny" | undefined` keeps
/// both literals in tsc, while a context-free check widens each property to
/// `string` and infers `T = string`. Without a contextual return there is no
/// seed and the widening is correct (tsc widens there too).
///
/// The test is simply whether the seed RESOLVES anything in the parameter:
/// `instantiateInstantiableTypes(contextualType, returnMapper)` is what tsc
/// hands down, and a parameter the mapper does not touch is handed down
/// unchanged. Nothing about the seed's own shape enters it — a seed that is a
/// literal domain keeps a fresh property literal, and a seed that is an
/// ordinary object (`style={platform({web: {minHeight: '100%'}, default: …})}`
/// under `StyleProp<ViewStyle>`) contextually types the property's own nested
/// literal, which is where its `` `${number}%` `` member keeps `'100%'` from
/// widening to `string`.
fn seedResolvesParam(c: *Checker, pt: TypeId, tp_syms: []const u32, seed: []const TypeId) Error!bool {
    return (try c.instantiateKnownParams(pt, tp_syms, seed, seed)) != pt;
}

/// tsc's `ObjectFlags.NonInferrableType`, recomputed on demand: does `t`
/// carry a `types.any_function_type` anywhere a propagating flag would have
/// reached — an object literal's property, an array or tuple element, a
/// union or intersection member? Only asked while `Checker.aft_seen` says one
/// was minted, so the ordinary inference path never runs it.
fn containsAnyFunctionType(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (t == types.any_function_type) return true;
    if (depth > 4) return false;
    const s = &c.ts;
    switch (s.kind(t)) {
        .array => return containsAnyFunctionType(c, s.arrayElem(t), depth + 1),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try containsAnyFunctionType(c, s.tupleElem(t, @intCast(i)).ty, depth + 1)) return true;
            }
            return false;
        },
        .union_type, .intersection => {
            const ms = try c.scratch().dupe(TypeId, try c.memberList(t));
            defer c.scratch().free(ms);
            for (ms) |m| {
                if (try containsAnyFunctionType(c, m, depth + 1)) return true;
            }
            return false;
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (try containsAnyFunctionType(c, s.objectProp(t, @intCast(i)).ty, depth + 1)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Would the pass-two contextual type `ctx2` leave one of `node`'s
/// context-sensitive function properties with NO call signature? That is the
/// one outcome the skipped round cannot be allowed to produce: the property's
/// parameters would go implicit `any` in the AUTHORITATIVE pass, which is a
/// diagnostic tsc does not report and the context-free reading did not
/// produce either.
fn ctxSensitiveLosesSignature(c: *Checker, node: Node, ctx2: TypeId, depth: u8) Error!bool {
    if (depth > 4) return false;
    const rp = try c.resolveStructural(ctx2);
    switch (c.ts.kind(rp)) {
        .object, .union_type, .intersection => {},
        else => return false,
    }
    for (c.tree.nodeRange(node)) |m| {
        if (m == null_node) continue;
        switch (c.nodeTag(m)) {
            .object_property, .object_method => {},
            else => continue,
        }
        // Through `skipParens`: a parenthesized callback (`children: (({ x })
        // => { })`) is the same context-sensitive property as an unwrapped
        // one, and reading the paren node's tag instead put it in the
        // `else` arm — the fallback never fired and its parameters stayed
        // implicit `any` in the authoritative pass (TS7006/TS7031).
        const val = skipParens(c, c.tree.nodeData(m).rhs);
        if (val == null_node) continue;
        const key = try c.memberAtom(c.tree.nodeMainToken(m));
        const prop_ty = try c.ctxPropType(rp, ctx2, key);
        switch (c.nodeTag(val)) {
            .arrow_fn, .function_expr => {
                if (!c.fnExprIsContextSensitive(val)) continue;
                if (prop_ty == types.no_type) return true;
                if (try c.contextualCallSig(prop_ty, val) == types.no_type) return true;
            },
            .object_literal => {
                if (prop_ty == types.no_type) continue;
                if (try ctxSensitiveLosesSignature(c, val, prop_ty, depth + 1)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Mark every one of `tp_syms` that `t` mentions. The walk mirrors
/// `instantiateSignature`'s: it visits what the mapper would visit.
fn markMentionedTps(c: *Checker, t: TypeId, tp_syms: []const u32, fixed: []bool, depth: u32) Error!void {
    if (depth > 6) return;
    const s = &c.ts;
    switch (s.kind(t)) {
        .type_param => {
            if (tpIndex(tp_syms, s.typeParamSymbol(t))) |i| fixed[i] = true;
        },
        .array => try markMentionedTps(c, s.arrayElem(t), tp_syms, fixed, depth + 1),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                try markMentionedTps(c, s.tupleElem(t, @intCast(i)).ty, tp_syms, fixed, depth + 1);
            }
        },
        .union_type, .intersection => {
            const ms = try c.scratch().dupe(TypeId, try c.memberList(t));
            defer c.scratch().free(ms);
            for (ms) |m| try markMentionedTps(c, m, tp_syms, fixed, depth + 1);
        },
        .ref => {
            const args = try c.scratch().dupe(TypeId, s.refArgs(t));
            defer c.scratch().free(args);
            for (args) |a| try markMentionedTps(c, a, tp_syms, fixed, depth + 1);
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                try markMentionedTps(c, s.objectProp(t, @intCast(i)).ty, tp_syms, fixed, depth + 1);
            }
        },
        .function => {
            for (0..s.fnParamCount(t)) |i| {
                try markMentionedTps(c, s.fnParam(t, @intCast(i)).ty, tp_syms, fixed, depth + 1);
            }
            try markMentionedTps(c, s.fnReturn(t), tp_syms, fixed, depth + 1);
        },
        .conditional => {
            try markMentionedTps(c, s.condCheck(t), tp_syms, fixed, depth + 1);
            try markMentionedTps(c, s.condExtends(t), tp_syms, fixed, depth + 1);
            try markMentionedTps(c, s.condTrue(t), tp_syms, fixed, depth + 1);
            try markMentionedTps(c, s.condFalse(t), tp_syms, fixed, depth + 1);
        },
        .index_access => try markMentionedTps(c, s.indexAccessObj(t), tp_syms, fixed, depth + 1),
        .keyof_op => try markMentionedTps(c, s.keyofOperand(t), tp_syms, fixed, depth + 1),
        .mapped => {
            try markMentionedTps(c, s.mappedConstraint(t), tp_syms, fixed, depth + 1);
            try markMentionedTps(c, s.mappedValue(t), tp_syms, fixed, depth + 1);
        },
        else => {},
    }
}

/// Which type parameters will the SECOND inference round fix when it
/// contextually types the context-sensitive function properties of the
/// object literal `node` against the parameter type `pt`?
///
/// tsc's `contextuallyCheckFunctionExpressionOrObjectLiteralMethod` gives a
/// context-sensitive function expression its parameter types from
/// `instantiateSignature(contextualSignature, inferenceContext.mapper)` —
/// the FIXING mapper — so every type parameter that signature mentions is
/// pinned at the value inference has reached, and `inferFromTypes` records
/// no further candidate for it (`if (!inference.isFixed)`).
///
/// Crucially that is the PARAMETER positions only. `instantiateSignature`
/// leaves `resolvedReturnType` undefined and instantiates the return type
/// lazily, off a mapper stored on the signature, and `instantiateSymbol` is
/// lazy the same way — so what actually runs the fixing mapper is
/// `assignContextualParameterTypes` reading one contextual parameter type
/// per parameter the callback declares. A type parameter named only in the
/// contextual RETURN is never asked for, so it is never fixed.
///
/// That asymmetry is exactly what react-query needs. `useQuery`'s
/// `placeholderData: (prev: TData | undefined) => TData | undefined` names
/// `TData` in a PARAMETER, so the callback contributes nothing and `TData`
/// keeps the value `queryFn` gave it. `useMutation`'s
/// `onMutate: (vars: TVars) => TContext | undefined` names `TContext` only
/// in its return, so `onMutate` still determines `TContext` — even though
/// the sibling `onError`'s `ctx: TContext | undefined` parameter fixes it,
/// because by then `onMutate`'s candidate is already in hand.
///
/// `param_pos` collects the first case, `ret_only` the second: a parameter
/// some context-sensitive property names in its contextual RETURN and not in
/// that same property's own parameters. A parameter in `param_pos` records
/// no CONTRAVARIANT candidate from this pass (what comes back from a fixed
/// parameter position is the substitution, not evidence); one that is also
/// in `ret_only` still records the covariant candidate that other property's
/// return carries.
///
/// "The parameter positions" is `markFixedByParams`, not every position the
/// contextual signature declares: `assignContextualParameterTypes` asks for one
/// contextual type per parameter the CALLBACK writes, so a position past the
/// callback's own arity is never read and fixes nothing.
///
/// The one thing this does not model is tsc's ORDER sensitivity — there the
/// fixing happens as each property is checked, so a `T`-fixing property
/// written BEFORE the property whose return supplies `T` pins `T` at its
/// pre-argument value. Property order is otherwise irrelevant to inference,
/// and the shapes that rely on it are pathological, so both marks are
/// gathered over the whole literal.
fn markCtxSensitiveFixed(
    c: *Checker,
    node: Node,
    pt: TypeId,
    tp_syms: []const u32,
    param_pos: []bool,
    ret_only: []bool,
    depth: u8,
) Error!void {
    if (depth > 4) return;
    const rp = try c.resolveStructural(pt);
    // Only a materialized member table can name a property. A parameter type
    // that is still a bare type variable or a generic mapped type has none,
    // and asking for one drags the key-domain walk through a self-referential
    // constraint (`T extends Record<keyof T, number>`) — a question with no
    // answer and no bearing on which parameters get fixed.
    switch (c.ts.kind(rp)) {
        .object, .union_type, .intersection => {},
        else => return,
    }
    for (c.tree.nodeRange(node)) |m| {
        if (m == null_node) continue;
        switch (c.nodeTag(m)) {
            .object_property, .object_method => {},
            else => continue,
        }
        // Parens are transparent here, exactly as in
        // `ctxSensitiveLosesSignature`: `(({ x }) => { })` is the same
        // context-sensitive property as the arrow written bare.
        const val = skipParens(c, c.tree.nodeData(m).rhs);
        if (val == null_node) continue;
        const key = try c.memberAtom(c.tree.nodeMainToken(m));
        const prop_ty = try c.ctxPropType(rp, pt, key);
        if (prop_ty == types.no_type) continue;
        switch (c.nodeTag(val)) {
            .arrow_fn, .function_expr => {
                if (!c.fnExprIsContextSensitive(val)) continue;
                const sig = try c.contextualCallSig(prop_ty, val);
                if (sig == types.no_type or c.ts.kind(sig) != .function) continue;
                const mine = try c.scratch().alloc(bool, tp_syms.len);
                defer c.scratch().free(mine);
                for (mine) |*x| x.* = false;
                const th = c.ts.fnThisType(sig);
                if (th != 0) try markMentionedTps(c, th, tp_syms, mine, 0);
                try markFixedByParams(c, val, sig, tp_syms, mine);
                const rets = try c.scratch().alloc(bool, tp_syms.len);
                defer c.scratch().free(rets);
                for (rets) |*x| x.* = false;
                try markMentionedTps(c, c.ts.fnReturn(sig), tp_syms, rets, 0);
                for (0..tp_syms.len) |i| {
                    if (mine[i]) param_pos[i] = true else if (rets[i]) ret_only[i] = true;
                }
            },
            .object_literal => try markCtxSensitiveFixed(c, val, prop_ty, tp_syms, param_pos, ret_only, depth + 1),
            else => {},
        }
    }
}

/// Mark every type parameter the FIXING mapper actually runs over when `fn_node`
/// adopts `sig` as its contextual signature.
///
/// tsc's `assignContextualParameterTypes` decides that, and it reads the
/// contextual signature BY POSITION, one position per parameter the callback
/// itself declares:
///
/// ```ts
/// const len = signature.parameters.length - (signatureHasRestParameter(signature) ? 1 : 0);
/// for (let i = 0; i < len; i++) {
///     const parameter = signature.parameters[i];
///     if (!getEffectiveTypeAnnotationNode(parameter.valueDeclaration)) {
///         assignParameterType(parameter, tryGetTypeAtPosition(context, i));
///     }
/// }
/// if (signatureHasRestParameter(signature)) assignParameterType(parameter, getRestTypeAtPosition(context, len));
/// ```
///
/// So a contextual parameter position the callback never DECLARES is never
/// asked for, and the fixing mapper never touches the type parameters that live
/// there. react-query's `getNextPageParam: lastPage => lastPage.cursor` is that
/// shape: the contextual `GetNextPageParamFunction<TPageParam, TQueryFnData>`
/// names `TPageParam` at positions 2 and 3, the arrow declares ONE parameter,
/// so only position 0 (`TQueryFnData`) is read and `TPageParam` stays free —
/// which is how its covariant set picks up the `string | undefined` the arrow's
/// RETURN supplies, on top of the `undefined` that `initialPageParam` gave it.
/// Marking every position instead pinned `TPageParam` at `undefined` and every
/// `useInfiniteQuery` in social-app failed to resolve.
///
/// A parameter that carries its OWN annotation is skipped for the same reason
/// tsc skips it: nothing is assigned to it, so nothing is fixed. A REST
/// parameter is the one position that reads the whole tail (`getRestTypeAtPosition`).
fn markFixedByParams(c: *Checker, fn_node: Node, sig: TypeId, tp_syms: []const u32, mine: []bool) Error!void {
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fn_node).lhs);
    const n_ctx = c.ts.fnParamCount(sig);
    var i: usize = 0;
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node) continue;
        const pd = c.tree.nodeData(p);
        var ann: Node = 0;
        var rest = false;
        switch (c.nodeTag(p)) {
            .param => ann = pd.rhs,
            .param_full => {
                const pf = c.tree.extraData(ast.ParamFull, pd.rhs);
                ann = pf.type_ann;
                rest = pf.flags & ast.Flags.rest != 0;
            },
            else => {},
        }
        if (rest) {
            // The tail: every remaining contextual position feeds this one.
            while (i < n_ctx) : (i += 1) {
                try markMentionedTps(c, c.ts.fnParam(sig, @intCast(i)).ty, tp_syms, mine, 0);
            }
            return;
        }
        if (i >= n_ctx) return;
        if (ann == 0) try markMentionedTps(c, c.ts.fnParam(sig, @intCast(i)).ty, tp_syms, mine, 0);
        i += 1;
    }
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

/// The in-flight type-argument inference of one call — tsc's
/// `InferenceContext`, whose per-type-parameter rows are its `InferenceInfo`s.
/// `inferTypeArgs` builds one, publishes it as `Checker.infer_ctx` for the
/// duration of that call's inference and restores the enclosing one on the way
/// out (a nested call gets its own, starting at variance zero); `unify` and the
/// reverse-mapped subsystem reach it through the `contraSlot`, `topSlot` and
/// `revSlot` accessors.
///
/// `unify`'s signature carries only the covariant `candidates` array, and many
/// of the arrays it is handed are NOT this context's: a reverse-mapped
/// element's own accumulator, a speculative copy, a generic argument's own type
/// parameters. `owner` is what tells them apart — the accessors compare it
/// against the `candidates.ptr` they were handed, so a foreign array gets
/// `null` back and the walk runs without side tables.
pub const InferCtx = struct {
    /// Identity of the covariant accumulator that `contra`, `contra_sup` and
    /// `top_flags` belong to: `inferTypeArgs`'s own `candidates.ptr`.
    owner: ?[*]TypeId = null,
    /// Contravariant inference candidates, one per type parameter — tsc's
    /// `InferenceInfo.contraCandidates`.
    contra: []TypeId = &.{},
    /// The UNION of every contravariant candidate recorded for each type
    /// parameter, alongside `contra`'s common-subtype fold. tsc keeps the
    /// candidates as a LIST and `getInferredType` asks
    /// `some(inference.contraCandidates, t => isTypeSubtypeOf(inferredCovariantType, t))`
    /// — whether ANY ONE of them still accepts the covariant answer — which the
    /// folded common subtype alone cannot answer.
    contra_sup: []TypeId = &.{},
    /// The `InferencePriority.LiteralKeyof` candidate set, one entry per type
    /// parameter — the object types synthesized when a `keyof T` PATTERN met a
    /// literal argument (`unify`'s `.keyof_op` arm). Kept apart from `contra`
    /// for two reasons, both tsc's:
    ///
    ///   * `LiteralKeyof` is in `PriorityImpliesCombination`, so
    ///     `getContravariantInference` folds this set with `getIntersectionType`
    ///     rather than the common-subtype `reduceLeft` every other
    ///     contravariant candidate takes — `bar('a', 'b')` on
    ///     `<T>(x: keyof T, y: keyof T) => T` is `{ a: any } & { b: any }`;
    ///   * it is a LOW priority, and tsc drops a whole candidate list the
    ///     moment a higher-priority (numerically smaller) one arrives. Any
    ///     ordinary candidate, covariant or contravariant, therefore wipes it —
    ///     which is why `<T>(x: keyof T, y: T) => T` fed `('a', {a: 1, q: 2})`
    ///     answers `{ a: number; q: number }` in either argument order.
    keyof_contra: []TypeId = &.{},
    /// tsc's `InferenceInfo.topLevel`, one flag per type parameter: false once a
    /// candidate has been recorded from a position that is not at the top level
    /// of the parameter type it came from. Only a still-top-level parameter
    /// widens a fresh-literal candidate (`getCovariantInference`).
    top_flags: []bool = &.{},
    /// The priority tier. Registered SEPARATELY from `owner` — see `Rev`.
    rev: Rev = .{},
    /// Parameter-position nesting depth inside `unify`: odd means the current
    /// inference position is contravariant. tsc flips the same bit in
    /// `inferFromContravariantTypes` when it descends a signature's parameters.
    contra_pos: u32 = 0,
    /// Non-zero while `unify` is running *inside* a homomorphic-mapped-parameter
    /// inference (the alias-identity pairing in `inferReverseMapped`), so the
    /// candidates it records carry the same `InferencePriority.
    /// HomomorphicMappedType` the reverse-mapped rebuild they replace does: they
    /// stand down for a direct structural match and are discarded when one
    /// already answered.
    rev_prio: u32 = 0,
    /// Nesting depth inside `unify` below a non-top-level constructor. Unions
    /// and intersections preserve top-level-ness (tsc's
    /// `isTypeParameterAtTopLevel` descends them); everything else does not.
    nontop_depth: u32 = 0,
    /// Non-zero while `unify` is answering for `instantiateSigInContextOf` —
    /// tsc's `instantiateSignatureInContextOf`, the SIGNATURE-vs-SIGNATURE
    /// inference the relation runs, as opposed to the CALL-SITE inference
    /// `inferTypeArgs` runs.
    ///
    /// The two want opposite answers for one candidate: a generic ARGUMENT's
    /// own type parameter bound to a variable of the call being solved. At a
    /// call site that is noise (`map([1,2,3], identity)` must not leave `U`
    /// standing as `identity`'s own `A`), and `unify`'s `.function` arm erases
    /// it to the fallback. In a signature relation it is the ANSWER — tsc's
    /// `getCanonicalSignature` exists precisely so the target's parameters can
    /// be inferred into the source's — and erasing it to `unknown` poisons the
    /// outer inference. See the `bare_self` branch there.
    sig_ctx: u32 = 0,
    /// tsc's `instantiateTypeWithSingleGenericCallSignature` gate: this call
    /// RETURNS a single non-generic call signature, so a type parameter minted
    /// for a generic function argument has somewhere to be generalized to.
    ///
    /// ```ts
    /// const returnType = context.signature && getReturnTypeOfSignature(context.signature);
    /// const returnSignature = returnType && getSingleCallOrConstructSignature(returnType);
    /// if (returnSignature && !returnSignature.typeParameters && …)
    /// ```
    ///
    /// Without it a minted parameter would end up inside a result that has no
    /// signature to carry it and would print as a free, unbindable name.
    ho_result_fn: bool = false,
    /// The signature's RETURN type, for the one mid-walk decision that needs it:
    /// a candidate handed to a generic function argument (tsc's
    /// `instantiateSignatureInContextOf` reading `context.mapper`) is the
    /// parameter's INFERRED type, which `getInferredType` has already widened —
    /// and `getCovariantInference`'s widening test asks whether the parameter
    /// occurs at the top level of this return. `no_type` outside a call-site
    /// inference.
    sig_ret: TypeId = types.no_type,
    /// The unique type parameters minted for this call's generic function
    /// arguments — tsc's `InferenceContext.inferredTypeParameters`, which
    /// `getSignatureInstantiation` re-attaches to the returned signature.
    ///
    /// An ACCUMULATOR, owned by `inferTypeArgs` for the duration of one call's
    /// inference and read once on the way out; null in every context that is
    /// not a call-site inference (a signature relation, a reverse-mapped
    /// element), which is also what disables the minting.
    ho_minted: ?*std.ArrayList(u32) = null,
    /// tsc's `InferenceInfo.impliedArity`, one entry per type parameter
    /// (`no_arity` for "not implied"): how many list elements the CALL SITE
    /// implies for a type parameter that is the signature's own rest parameter.
    /// Set once per call by `inferTypeArgs`; read only by
    /// `inferFromTupleTypes`, which needs it to split `[...T, ...U]` — a
    /// pattern with two adjacent variadic elements has no structural split of
    /// its own, so without the call's trailing-argument count there is nothing
    /// to infer either half from.
    implied_arity: []u32 = &.{},

    /// `implied_arity`'s "unset" marker. Zero is a real arity (`curry(fn)`
    /// implies `T := []`).
    pub const no_arity: u32 = std.math.maxInt(u32);

    /// tsc's `InferencePriority.HomomorphicMappedType`, one flag per type
    /// parameter: true while the only evidence recorded for it came from
    /// REVERSE-MAPPED inference (`Partial<T>`, `Readonly<T>`, a homomorphic
    /// mapped parameter). tsc keeps only the candidates at the best priority it
    /// saw, so a direct structural candidate replaces a reverse-mapped one
    /// outright and a reverse-mapped one arriving second is discarded. Also
    /// carries tsc's `InferencePriority.NakedTypeVariable` — an inference made
    /// directly to a bare type variable reached through a conditional's branch,
    /// which is "less specific" the same way and loses to a direct candidate by
    /// the same rule.
    ///
    /// It carries its OWN `owner`, deliberately: the two-round context-sensitive
    /// probe in `inferTypeArgs` infers this very call into a SCRATCH copy of the
    /// candidate array, and the priority tier has to hold there too — the
    /// probe's answer is what pins each context-sensitive callback's parameter
    /// types for the authoritative pass. So the probe re-points this half at its
    /// scratch array while the rest of the context keeps pointing at the real
    /// accumulator: `revSlot` answers for the probe, `contraSlot` and `topSlot`
    /// do not. Contravariant candidates and the top-level flags must NOT follow
    /// it there — those are read back after the walk, and the probe's copy is
    /// discarded.
    pub const Rev = struct {
        owner: ?[*]TypeId = null,
        flags: []bool = &.{},
    };
};

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
) Error![]const u32 {
    const candidates = try c.scratch().alloc(TypeId, tp_syms.len);
    for (candidates) |*x| x.* = types.no_type;

    // The contravariant half of the candidate set (tsc's
    // `InferenceInfo.contraCandidates`), registered against `candidates` so
    // `unify` can find it and every other accumulator it is handed cannot.
    // A nested call's inference gets its own, and starts at variance zero.
    const contra = try c.scratch().alloc(TypeId, tp_syms.len);
    for (contra) |*x| x.* = types.no_type;
    // Its per-candidate half (see `InferCtx.contra_sup`).
    const contra_sup = try c.scratch().alloc(TypeId, tp_syms.len);
    for (contra_sup) |*x| x.* = types.no_type;
    // tsc's `InferencePriority.LiteralKeyof` set (see `InferCtx.keyof_contra`).
    const keyof_contra = try c.scratch().alloc(TypeId, tp_syms.len);
    for (keyof_contra) |*x| x.* = types.no_type;
    // tsc's `InferenceInfo.topLevel`, registered the same way.
    const top_flags = try c.scratch().alloc(bool, tp_syms.len);
    for (top_flags) |*x| x.* = true;
    // tsc's `InferencePriority.HomomorphicMappedType`, registered the same way.
    const rev_flags = try c.scratch().alloc(bool, tp_syms.len);
    for (rev_flags) |*x| x.* = false;
    // tsc's `InferenceInfo.impliedArity`, read off THIS call's argument list.
    const arity = try c.scratch().alloc(u32, tp_syms.len);
    for (arity) |*x| x.* = InferCtx.no_arity;
    try fillImpliedArity(c, sig, tp_syms, arg_nodes, arity);
    // tsc's `instantiateTypeWithSingleGenericCallSignature` gate and the
    // accumulator its type-parameter-propagating half writes into — see
    // `InferCtx.ho_result_fn` / `InferCtx.ho_minted` and the `.function` arm of
    // `unify`. The gate is a two-field read on a signature this function
    // already has in hand; the list stays empty on every call that is not a
    // combinator, which is all but a handful.
    var ho_minted: std.ArrayList(u32) = .empty;
    defer ho_minted.deinit(c.scratch());
    const ho_result_fn = blk: {
        if (c.ts.kind(sig) != .function) break :blk false;
        const r = try c.resolveStructural(c.ts.fnReturn(sig));
        break :blk c.ts.kind(r) == .function and c.ts.fnTypeParamCount(r) == 0;
    };
    // Publish the whole context at once, and put the enclosing call's back
    // when this one is done.
    const saved_ctx = c.infer_ctx;
    c.infer_ctx = .{
        .owner = candidates.ptr,
        .contra = contra,
        .contra_sup = contra_sup,
        .keyof_contra = keyof_contra,
        .top_flags = top_flags,
        .implied_arity = arity,
        .rev = .{ .owner = candidates.ptr, .flags = rev_flags },
        .ho_result_fn = ho_result_fn,
        .ho_minted = &ho_minted,
        .sig_ret = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.no_type,
    };
    defer c.infer_ctx = saved_ctx;

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
        // Phase 2 owns every FUNCTION argument, parentheses and all: tsc's
        // `isContextSensitive` opens with
        // `case SyntaxKind.ParenthesizedExpression: return
        // isContextSensitive(node.expression)`, so `f((x => x), 10)` is as
        // context sensitive as `f(x => x, 10)` and takes its parameter types
        // from the same pass. Read without the skip, a parenthesized callback
        // fell through to this phase's context-free `checkExprCached(an,
        // no_type)` — walked with no contextual signature at all, so every
        // parameter of it was TS7006, and Phase 2 then skipped it too.
        // (`isContextSensitive`'s parenthesis arm is already what the
        // object-literal property walk above goes through `skipParens` for.)
        if (isFunctionArg(c, an)) continue;
        // A SPREAD stands for the positions its type expands to. tsc runs
        // `getEffectiveCallArguments` once, before `inferTypeArguments`, so
        // inference sees the expansion too; unifying the spread's own
        // CONTAINER type against the position's parameter inferred the
        // container where tsc infers an element — `foo<T>(...s: T[])` called
        // `foo(...new SymbolIterator)` gave `T = SymbolIterator` instead of
        // `T = symbol`, and every argument after a tuple spread was paired
        // with the wrong parameter.
        if (tag == .spread_element) {
            var eff: std.ArrayList(calls.EffArg) = .empty;
            defer eff.deinit(c.scratch());
            _ = try calls.expandSpread(c, an, &eff);
            for (eff.items, 0..) |ea, j| {
                const ept = try c.paramTypeAt(sig, ai + @as(u32, @intCast(j))) orelse break;
                try c.unify(ept, ea.ty, tp_syms, candidates, 0);
            }
            ai = (ai + @as(u32, @intCast(eff.items.len))) -| 1;
            continue;
        }
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
        // Does this parameter have a literal-keeping type-variable property —
        // the shape whose contextual read must reach an object-literal
        // argument even when handing it down costs the two-round pass below?
        const lit_ctx_wanted = tag == .object_literal and
            ((try c.paramWantsLiteralCtx(pt)) or (try seedResolvesParam(c, pt, tp_syms, ret_seed)));
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
            // A literal that carries no un-annotated function at all has no
            // second round to lose, so it takes the parameter unconditionally
            // — see `lit_ctx_wanted` below for the literal-keeping half.
            .object_literal => if (lit_ctx_wanted or !c.objLitIsContextSensitive(an))
                pt
            else
                types.no_type,
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
        // The same substitution for an ARRAY-literal argument, but only when
        // the parameter's constraint DEPENDS on a type parameter inferred to
        // the left. tsc reaches it through `getInferredType`: reading a
        // still-candidate-free inference variable answers `unknown`, which the
        // variable's constraint — `instantiateType(constraint,
        // context.nonFixingMapper)`, so the earlier parameters are already
        // substituted — then clamps, and that clamped type is what
        // `instantiateContextualType` hands the argument.
        //
        // `pick<R, K extends readonly (keyof R)[]>(source: R, keys: K)` is the
        // shape (excalidraw's `colors.ts`). Contextually typing `["cyan",
        // "blue"]` by the bare `K` leaves `isLiteralOfContextualType` reading
        // an UNINSTANTIATED `readonly (keyof R)[]`, whose `keyof R` is still
        // deferred over a free variable and so admits no literal: both keys
        // widened to `string`, `string[]` failed the constraint, and `K` fell
        // back to the whole `readonly (keyof R)[]` — making `Pick<R,
        // K[number]>` the entire palette instead of the two keys asked for.
        // Substituting `R` first turns the constraint into `readonly ("blue" |
        // "cyan" | …)[]`, which keeps both literals.
        //
        // Gated on the substitution CHANGING the constraint so a self-contained
        // one (`T extends readonly unknown[] | []`, the tuple-inferring shape
        // the array-literal context exists for) still sees the bare parameter.
        if (tag == .array_literal) {
            const rp = try c.resolveStructural(pt);
            if (c.ts.kind(rp) == .type_param) {
                if (tpIndex(tp_syms, c.ts.typeParamSymbol(rp))) |pi| {
                    if (candidates[pi] == types.no_type) {
                        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(rp));
                        if (con != types.no_type) {
                            const inst = try c.instantiateKnownParams(con, tp_syms, candidates, ret_seed);
                            if (inst != con) arg_ctx = inst;
                        }
                    }
                }
            }
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
            // The probe's OWN co-/contravariant split. It is this call's
            // inference run into a scratch accumulator, so it needs the whole
            // side-table set, not just the priority tier: `contraSlot` and
            // friends key on `InferCtx.owner`, and leaving that pointed at the
            // real accumulator makes every side table decline for the probe —
            // which quietly WIDENS a parameter-position candidate into the
            // probe's covariant array, the one place a contravariant candidate
            // must never land.
            const probe_contra = try c.scratch().alloc(TypeId, tp_syms.len);
            const probe_contra_sup = try c.scratch().alloc(TypeId, tp_syms.len);
            const probe_keyof = try c.scratch().alloc(TypeId, tp_syms.len);
            const probe_top = try c.scratch().alloc(bool, tp_syms.len);
            // What pass two FEEDS each parameter, plus the pre-pass state —
            // read by the contravariant echo guard after the re-check.
            const fed2 = try c.scratch().alloc(TypeId, tp_syms.len);
            const before2 = try c.scratch().alloc(TypeId, tp_syms.len);
            const before_contra2 = try c.scratch().alloc(TypeId, tp_syms.len);
            // Which parameters pass two FIXES by handing a context-sensitive
            // property its parameter types — see `markCtxSensitiveFixed`.
            const cs_param = try c.scratch().alloc(bool, tp_syms.len);
            const cs_ret_only = try c.scratch().alloc(bool, tp_syms.len);
            for (tp_syms, 0..) |_, i| {
                fed2[i] = types.no_type;
                before2[i] = candidates[i];
                before_contra2[i] = contra[i];
                cs_param[i] = false;
                cs_ret_only[i] = false;
            }
            try markCtxSensitiveFixed(c, an, pt, tp_syms, cs_param, cs_ret_only, 0);
            c.side_query_depth += 1;
            const ctx2 = blk: {
                errdefer c.side_query_depth -= 1;
                const saved_aft = c.aft_seen;
                defer c.aft_seen = saved_aft;
                var map2: std.ArrayList(TpMap) = .empty;
                defer map2.deinit(c.scratch());
                var result: TypeId = types.no_type;
                // Attempt 0 is tsc's round one, under
                // `CheckMode.SkipContextSensitive` (`resolveCall` sets it
                // whenever some argument is context sensitive, and
                // `chooseOverload` clears it for round two). Every
                // context-sensitive property of this literal reads as
                // `anyFunctionType`, which `inferFromTypes` refuses, so the
                // round leaves exactly the type parameters those properties
                // would have determined UNCONSTRAINED — and the ones the
                // literal's other properties determine are inferred for
                // real. Without it a callback property was walked with no
                // contextual type at all, and the implicit-`any` reading of
                // its body became a candidate: react-query's
                // `useQuery({queryKey, queryFn, placeholderData: prev =>
                // prev || {…}})` fixed the query's data type from the
                // FALLBACK object instead of from `queryFn`.
                //
                // Attempt 1 is the pre-two-round CONTEXT-FREE reading, taken
                // only when round one left so little that pass two would hand
                // a context-sensitive property no call signature at all. tsc
                // never needs it because a parameter round one cannot reach
                // is one another ARGUMENT supplies — jotai's
                // `store.set(atom, { onSelect: (color, event) => … })` takes
                // `Value` from the atom. ztsc infers that parameter from this
                // very literal, so refusing the literal leaves the callback's
                // parameters implicit `any` for real. The provisional reading
                // is worse than tsc's answer and better than none, and it is
                // reached only when the faithful round yields nothing usable.
                var attempt: u8 = 0;
                while (true) : (attempt += 1) {
                    for (candidates, 0..) |cd, i| probe_cands[i] = cd;
                    for (0..tp_syms.len) |i| {
                        probe_contra[i] = types.no_type;
                        probe_contra_sup[i] = types.no_type;
                        probe_keyof[i] = types.no_type;
                        probe_top[i] = true;
                    }
                    map2.clearRetainingCapacity();
                    {
                        const saved_skip = c.skip_ctx_sensitive;
                        // tsc's `inferTypeArguments` only checks an argument
                        // under the round's check mode when
                        // `couldContainTypeVariables(paramType)`. A parameter
                        // type with no type variable in it has nothing for two
                        // rounds to decide, and skipping the callback there
                        // only costs: `store.set(atom, …)`'s rest element
                        // resolves to `any` here (the `Args[number]` tsc keeps
                        // is instantiated through the inference context, which
                        // ztsc has no equivalent of), so the literal is its own
                        // only reading either way.
                        c.skip_ctx_sensitive = attempt == 0 and try c.containsTypeParam(pt);
                        c.aft_seen = false;
                        defer c.skip_ctx_sensitive = saved_skip;
                        // The probe is THIS call's inference, just accumulated
                        // into a scratch array, so the WHOLE inference context
                        // is re-registered against it: the priority tier
                        // (`rev`), the co-/contravariant split (`contra`,
                        // `contra_sup`), the `LiteralKeyof` set and the
                        // top-level flags. Every one of those side tables keys
                        // on `InferCtx.owner` and declines for a foreign array,
                        // so leaving `owner` pointed at the real accumulator was
                        // not "no side tables" — it QUIETLY WIDENED: a candidate
                        // found in a parameter position, which `contraSlot`
                        // should have caught, fell through into the probe's
                        // COVARIANT array instead, and a candidate tsc records
                        // at `NakedTypeVariable` priority landed at full
                        // priority and pinned the very parameter the probe's
                        // answer hands every context-sensitive callback.
                        //
                        // Splitting it took seven earlier attempts, because the
                        // split alone is not the whole rule — three other things
                        // have to be true at the same time, all of them tsc's:
                        //
                        //  1. The probe's ANSWER is `getInferredType` over the
                        //     pair, not its covariant array (the fold below).
                        //     `useMutation({mutationFn: async ({id}: {id:
                        //     string}) => …})` names `TVars` nowhere but that
                        //     annotated callback's parameter, so the covariant
                        //     array has nothing for it at all.
                        //  2. `anyFunctionType` infers NOTHING, on every arm.
                        //     tsc builds it with zero properties, zero
                        //     signatures and zero index infos, so its descent
                        //     yields nothing; ztsc only refused it at the
                        //     inference-position arm, and the reverse-mapped
                        //     walk and the union arm's naked-variable fallback
                        //     reach a candidate slot without passing there. Once
                        //     the probe keeps its own contravariant set, such a
                        //     candidate is no longer harmless — it is preferred
                        //     over the type parameter's DEFAULT (`useQuery`'s
                        //     `placeholderData: (prev) => prev || {…}` came out
                        //     `undefined`). Guarded at the top of `unify`.
                        //  3. Only the contextual parameter positions the
                        //     callback actually DECLARES are fixed
                        //     (`markFixedByParams`), and an OPTIONAL source
                        //     property contributes `| undefined` just as tsc's
                        //     `getTypeOfSymbol` does. Both are needed by
                        //     react-query's `useInfiniteQuery({queryFn:
                        //     ({pageParam}: {pageParam?: string}) => …,
                        //     initialPageParam: undefined, getNextPageParam:
                        //     lastPage => …})`: `TPageParam` must stay free
                        //     through `getNextPageParam` (which declares one
                        //     parameter and names `TPageParam` at positions 2
                        //     and 3) so its RETURN can widen the covariant
                        //     `undefined` to `string | undefined`, and the
                        //     contravariant candidate must be `string |
                        //     undefined` rather than `string` or nothing is a
                        //     subtype of it.
                        const probe_rev = try c.scratch().alloc(bool, tp_syms.len);
                        for (probe_rev) |*x| x.* = false;
                        const outer_rev = c.infer_ctx.rev;
                        c.infer_ctx.rev = .{ .owner = probe_cands.ptr, .flags = probe_rev };
                        defer c.infer_ctx.rev = outer_rev;
                        const sv_owner = c.infer_ctx.owner;
                        const sv_contra = c.infer_ctx.contra;
                        const sv_sup = c.infer_ctx.contra_sup;
                        const sv_keyof = c.infer_ctx.keyof_contra;
                        const sv_top = c.infer_ctx.top_flags;
                        c.infer_ctx.owner = probe_cands.ptr;
                        c.infer_ctx.contra = probe_contra;
                        c.infer_ctx.contra_sup = probe_contra_sup;
                        c.infer_ctx.keyof_contra = probe_keyof;
                        c.infer_ctx.top_flags = probe_top;
                        defer {
                            c.infer_ctx.owner = sv_owner;
                            c.infer_ctx.contra = sv_contra;
                            c.infer_ctx.contra_sup = sv_sup;
                            c.infer_ctx.keyof_contra = sv_keyof;
                            c.infer_ctx.top_flags = sv_top;
                        }
                        const probe = try c.checkExprCached(an, arg_ctx);
                        try c.unify(pt, probe, tp_syms, probe_cands, 0);
                    }
                    // The properties EARLIER in the literal have already
                    // contributed by the time tsc instantiates a later
                    // context-sensitive property's contextual signature — the
                    // fixing mapper pins each parameter at what inference has
                    // reached *at that point*, not at what round one alone
                    // reached. react-query's `useMutation({mutationFn,
                    // onMutate, onError})` is the shape that needs it:
                    // `onMutate` determines `TOnMutateResult` through its
                    // RETURN and `onError` names it in a PARAMETER, so tsc
                    // fixes it at `onMutate`'s answer and `onError`'s
                    // `context` is the real thing. Round one cannot see it —
                    // `onMutate` is context sensitive, so round one skipped
                    // it — and feeding `unknown` to pass two is not a
                    // provisional reading that some later pass corrects: pass
                    // two IS the authoritative walk, so it reported
                    // `context.prevConvo` against `{}`.
                    //
                    // So a parameter that some context-sensitive property
                    // determines through its return, and that round one left
                    // open, is re-derived from a second speculative read with
                    // the skip OFF. Nothing else takes a candidate from it —
                    // in particular not a parameter the callback names in its
                    // own PARAMETERS, which is the placeholder echo round one
                    // exists to refuse.
                    if (attempt == 0) {
                        var want_ret_only = false;
                        for (0..tp_syms.len) |i| {
                            if (cs_ret_only[i] and probe_cands[i] == types.no_type) want_ret_only = true;
                        }
                        if (want_ret_only) {
                            const ro_cands = try c.scratch().alloc(TypeId, tp_syms.len);
                            for (candidates, 0..) |cd, i| ro_cands[i] = cd;
                            const saved_aft2 = c.aft_seen;
                            c.aft_seen = false;
                            const ro_probe = try c.checkExprCached(an, arg_ctx);
                            try c.unify(pt, ro_probe, tp_syms, ro_cands, 0);
                            c.aft_seen = saved_aft2;
                            for (0..tp_syms.len) |i| {
                                if (!cs_ret_only[i] or probe_cands[i] != types.no_type) continue;
                                probe_cands[i] = ro_cands[i];
                            }
                        }
                    }
                    // The probe's ANSWER is `getInferredType` over its own
                    // pair, not its covariant array: a parameter whose only
                    // evidence in round one is contravariant — react-query's
                    // `useMutation({mutationFn: async ({id}: {id: string}) =>
                    // …})`, where `TVars` appears nowhere but that annotated
                    // callback's parameter — is absent from the covariant array
                    // entirely, and reading that array alone fed pass two the
                    // `unknown` default and reported TS2322 on the callback.
                    // Same choice as the authoritative fold below, including
                    // the `LiteralKeyof` fallback.
                    for (0..tp_syms.len) |i| {
                        if (probe_cands[i] == types.no_type and probe_contra[i] == types.no_type and
                            probe_keyof[i] != types.no_type)
                        {
                            probe_cands[i] = probe_keyof[i];
                            continue;
                        }
                        probe_cands[i] = try preferContravariant(c, probe_cands[i], probe_contra[i], probe_contra_sup[i]);
                    }
                    // Every type parameter is FIXED for pass two: one the
                    // probe could not infer takes its default/constraint (tsc
                    // fixes a type parameter before instantiating the
                    // contextual type of a context-sensitive argument).
                    // Leaving it free would hand the callback a bare type
                    // variable — `key: K` compared against a literal is then a
                    // spurious TS2367, where the constraint `keyof T` is
                    // exactly the domain tsc uses. Resolved in declaration
                    // order so a later parameter's constraint sees the earlier
                    // ones (`K extends keyof T`).
                    for (tp_syms, 0..) |sym, i| {
                        var v = if (probe_cands[i] != types.no_type) probe_cands[i] else ret_seed[i];
                        if (v == types.no_type) {
                            // Default, else constraint, else `unknown` — tsc's
                            // `getInferredType` exactly: no candidate takes the
                            // type parameter's default, and with no default
                            // `getDefaultTypeArgumentType()` answers `unknown`,
                            // which the constraint check that follows then
                            // narrows to the constraint if there is one.
                            //
                            // NOT `any`. Round one now leaves a parameter that
                            // only a context-sensitive property could have
                            // determined genuinely unconstrained, so this
                            // fallback is reached for parameters that DO come
                            // back in pass two — and an `any` fed into a
                            // callback's parameter position is read straight
                            // back as an `any` candidate, which absorbs the
                            // real one a sibling property's return carries.
                            // react-query's `useInfiniteQuery({queryFn,
                            // getNextPageParam})` is the shape:
                            // `getNextPageParam(lastPage: TQueryFnData, …)`
                            // handed the `any` back and buried the page type
                            // `queryFn` had just supplied.
                            v = try c.typeParamDefault(sym);
                            if (v == types.no_type) v = try c.typeParamConstraint(sym);
                            if (v == types.no_type) v = types.unknown_type;
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
                        fed2[i] = v;
                        try map2.append(c.scratch(), .{ .sym = sym, .ty = v });
                    }
                    result = try c.instantiate(pt, map2.items);
                    if (attempt > 0) break;
                    if (!c.aft_seen) break; // nothing was skipped
                    // The one outcome the skipped round must not produce: a
                    // pass-two contextual type that gives a context-sensitive
                    // property NO call signature. Its parameters would then be
                    // implicit `any` in the AUTHORITATIVE pass — a diagnostic
                    // tsc does not report, because a parameter its round one
                    // cannot reach is one another ARGUMENT supplies. Where
                    // ztsc has no other source, the provisional CONTEXT-FREE
                    // reading is kept: worse than tsc's answer, better than
                    // none.
                    if (!try ctxSensitiveLosesSignature(c, an, result, 0)) break;
                }
                break :blk result;
            };
            c.side_query_depth -= 1;
            const at2 = try c.checkExprCached(an, ctx2);
            try c.unify(pt, at2, tp_syms, candidates, 0);
            // A parameter this pass FIXED takes no candidate from this pass.
            // tsc's `inferFromTypes` opens the type-variable arm with
            // `if (!inference.isFixed)`, and fixing is what
            // `instantiateSignature(contextualSignature,
            // inferenceContext.mapper)` did to every parameter named in a
            // context-sensitive property's contextual PARAMETER positions —
            // see `markCtxSensitiveFixed`. The value it is fixed AT is the
            // one this pass fed, so pass one's reading stands and pass two
            // adds nothing: what comes back from such a position is the
            // substitution itself, not evidence.
            for (0..tp_syms.len) |i| {
                if (!cs_param[i]) continue;
                contra[i] = before_contra2[i];
                if (cs_ret_only[i]) continue;
                candidates[i] = before2[i];
                if (candidates[i] == types.no_type and probe_cands[i] != types.no_type)
                    candidates[i] = probe_cands[i];
            }
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
                // …EXCEPT a `never` candidate, which the demotion does not
                // need and which the arguments to its RIGHT do. `never` is the
                // identity of ztsc's union fold, so leaving it in place buries
                // nothing — any later covariant candidate simply absorbs it —
                // while demoting it hides the seed from the contextual type
                // those later arguments are checked against. tsc reads it
                // exactly there: `context.mapper` FIXES a type parameter that
                // already has a candidate before the next argument is
                // contextually typed, so `_.all([], _.identity)` types
                // `identity` against `Iterator<never, boolean>` and answers
                // `T = never`. Demoted, `identity` saw a free `T`, was erased
                // to `(value: unknown) => unknown`, and its CONTRAVARIANT
                // `unknown` then outranked the seed outright — the covariant
                // `never` loses that comparison by tsc's own rule
                // (`genericTypeArgumentInference1`).
                if (c.ts.kind(cd.*) == .never) continue;
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
    // A callback argument's contextual type must carry the CONSTRAINT CLAMP the
    // final answer carries. tsc reaches every inference variable in a
    // contextual type through `getInferredType`, whose last act is "if the
    // inferred type does not satisfy the constraint, use the constraint
    // instead" — so the callback is handed the clamped type, and its body is
    // checked against THAT. ztsc applied the clamp only at the end, after
    // Phase 2 had already published the callback body's memos under the
    // violating inference, and those memos are what the authoritative check
    // reads back (see the note on the walk below): outline's
    // `everyActiveModel(context, Document, (d) => d.isStarred)` typed `d` as
    // `Document` and lost the whole `Property 'x' does not exist on type
    // 'Model'` family that tsc reports once `T` clamps to `Model`.
    //
    // Only where Phase 2 has something to feed, and only against a constraint
    // this call has fully resolved — see `clampSeedToConstraint`.
    const clamp_seed = anyFunctionArg(c, arg_nodes);
    for (tp_syms, 0..) |tp, i| {
        seeded[i] = seed[i] != types.no_type;
        var ty: TypeId = if (seeded[i]) seed[i] else types.any_type;
        if (clamp_seed and seeded[i]) {
            ty = try clampSeedToConstraint(c, tp, tp_syms, partial[0..i], ty);
        }
        partial[i] = .{ .sym = tp, .ty = ty };
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
    // tsc's `nonFixingMapper` leaves an un-inferred type parameter FREE in the
    // contextual type, and every contextual READ then takes its apparent type
    // (`getApparentTypeOfContextualType`). ztsc substitutes the `any`
    // placeholder, which erases the parameter wherever it is NESTED — the
    // RETURN type of a callback parameter above all — so the object literal
    // returned from `useAnimatedStyle<Style extends ViewStyle | ImageStyle |
    // TextStyle>(updater: () => Style)` saw no contextual type at all and every
    // fresh literal in it widened (`pointerEvents: 'box-none' | 'none'` →
    // `string`). Feed the apparent type — the instantiated constraint — which
    // is what the contextual read would have produced anyway.
    // `partialParamCtx` already does exactly this for a parameter that IS a
    // bare type variable; this is the same rule one level in.
    //
    // Restricted to type parameters that occur ONLY in the callback's RETURN
    // position. A contextual PARAMETER type is where the `any` placeholder is
    // load-bearing — the placeholder-echo guard below reads it straight back,
    // and tsc's own contextual parameter type is the still-free variable,
    // which infers nothing either — so substituting the constraint there
    // manufactures inference evidence the argument does not carry (measured:
    // excalidraw 15 -> 45, immich 0 -> 1).
    const partial_ctx = try c.scratch().alloc(TpMap, tp_syms.len);
    const param_mentioned = try c.scratch().alloc(bool, tp_syms.len);
    ai = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        // Parentheses included, exactly as Phase 1's skip excludes them. The
        // node handed to `checkExprCached` below stays the WRITTEN argument —
        // `checkExpr`'s parenthesis arm forwards the contextual type through —
        // so the parenthesized expression keeps its own memo entry; only the
        // questions about the function itself look inside.
        const fn_node = skipParens(c, an);
        const tag = c.nodeTag(fn_node);
        if (tag != .arrow_fn and tag != .function_expr) continue;
        const pt0 = try c.paramTypeAtInferred(sig, ai, partial) orelse continue;
        const rp0 = try c.resolveStructural(pt0);
        const ret_only = c.ts.kind(rp0) == .function;
        if (ret_only) {
            for (param_mentioned) |*m| m.* = false;
            var pi: u32 = 0;
            while (pi < c.ts.fnParamCount(rp0)) : (pi += 1) {
                const pty = c.ts.fnParam(rp0, pi).ty;
                try markMentionedTps(c, pty, tp_syms, param_mentioned, 0);
            }
        }
        for (partial, 0..) |p, i| {
            partial_ctx[i] = p;
            if (!ret_only or param_mentioned[i]) continue;
            if (seeded[i] or p.ty != types.any_type) continue;
            const con = try c.typeParamConstraint(tp_syms[i]);
            if (con == types.no_type) continue;
            const ci = try c.instantiate(con, partial);
            if (c.ts.kind(ci) != .any) partial_ctx[i] = .{ .sym = tp_syms[i], .ty = ci };
        }
        for (partial, 0..) |p, i| {
            placeheld[i] = !seeded[i] and p.ty == types.any_type;
            before[i] = candidates[i];
            fed[i] = partial_ctx[i].ty;
            before_contra[i] = contra[i];
        }
        const pt_partial = try c.partialParamCtx(pt0, partial_ctx);
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
        if (try c.contextualCallSig(pt_partial, fn_node) == types.no_type and
            c.fnExprIsContextSensitive(fn_node)) continue;
        const at = try c.checkExprCached(an, pt_partial);
        try c.unify(pt0, at, tp_syms, candidates, 0);
        // The contravariant echo, widened. A context-sensitive callback's
        // parameter types ARE the contextual type we just fed it, so anything
        // a parameter position of it yields for a variable we resolved is our
        // own guess coming home — not evidence. Identity is too narrow a test
        // for that: `useAnimatedReaction<P>(prepare: () => P, react: (prepared:
        // P, previous: P | null) => void)` feeds `previous` the contextual
        // `string | null`, and `P | null` against it infers `P = string` by
        // union subtraction — a DIFFERENT type, which then outranked the
        // covariant `string | null` that `() => hoveredItemSV.get()` supplies
        // and reported TS2322 on the first argument. tsc never re-decides the
        // variable here either: reading it for this argument's contextual type
        // memoizes `inference.inferredType`, and nothing short of FIXING
        // (`clearCachedInferences`) reopens it. An argument we fed nothing for
        // (the parameter was still the `any` placeholder) is untouched, and so
        // is a non-context-sensitive argument — an annotated callback carries
        // real contravariant evidence, which is why tsc rejects
        // `f7(() => sv.get(), sink)` for `sink: (p: string | null) => void`.
        const ctx_sensitive = c.fnExprIsContextSensitive(fn_node);
        for (contra, 0..) |*cc, i| {
            if (cc.* == before_contra[i]) continue;
            if (cc.* == fed[i] or (ctx_sensitive and fed[i] != types.any_type))
                cc.* = before_contra[i];
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
    //
    // tsc asks that of the candidate LIST — `some(inference.contraCandidates,
    // t => isTypeSubtypeOf(inferredCovariantType, t))` — not of the folded
    // common subtype, so ONE parameter position that still accepts the
    // covariant answer is enough. `useAnimatedReaction<P>(prepare: () => P,
    // react: (prepared: P, previous: P | null) => void)` needs the difference:
    // `prepared: P` contributes the contravariant candidate `string | null`
    // and `previous: P | null` contributes `string` (union subtraction), whose
    // common subtype is `string` — so testing the fold alone rejected the
    // covariant `string | null` that `() => hoveredItemSV.get()` supplies and
    // reported TS2322 on the FIRST argument. `contra_sup` is the union of the
    // candidates, standing in for the `some` (see `InferCtx.contra_sup`).
    for (candidates, 0..) |*cd, i| {
        // The `LiteralKeyof` set is the lowest-priority evidence there is: it
        // only ever says "the argument was a key of this parameter", so tsc
        // discards it outright once any ordinary candidate exists (see
        // `InferCtx.keyof_contra`). When it is all there is, it IS the
        // contravariant answer — already folded by intersection.
        if (cd.* == types.no_type and contra[i] == types.no_type and
            keyof_contra[i] != types.no_type)
        {
            cd.* = keyof_contra[i];
            continue;
        }
        cd.* = try preferContravariant(c, cd.*, contra[i], contra_sup[i]);
    }
    // A provisional map over the raw candidates, so an inter-dependent
    // constraint (`K extends keyof T`) is checked with the *other*
    // params already substituted — `keyof T` becomes `keyof {…}` before the
    // satisfaction test, instead of staying a deferred `keyof T` that no
    // literal is assignable to.
    //
    // A parameter that instantiation FRESHENED (`FreshTp`, minted when the
    // receiver's substitution moved its constraint or default) answers to a
    // new symbol, but a SIBLING's constraint that names it was only rewritten
    // when the sibling comes later in the list: the rewrite map is built as
    // the loop walks the parameters, so a bound naming a parameter declared
    // AFTER it still points at the original declaration symbol. Both symbols
    // therefore have to resolve to the same value here, which the alias
    // entries appended after the parameters' own do — `prov[n_tp..]` shadow
    // nothing (an original whose fresh copy is in this very list is skipped)
    // and are kept in step with their parameter by `setProv`.
    //
    // i18next's `t()` is the shape:
    //
    //     interface TFunction<N, TKPrefix, ActualNS = …> {
    //       <TKeys extends TFuncKey<UsedNS, TKPrefix>, …,
    //        UsedNS extends Namespace = … : ActualNS | DefaultNamespace>
    //         (key: TKeys | TKeys[], options: PassedOpt): …
    //     }
    //
    // `UsedNS`'s default names the INTERFACE parameter `ActualNS`, so reading
    // `t` off an instantiated `TFunction` freshens `UsedNS` — while `TKeys`,
    // whose own bound moves not at all, keeps its symbol and its bound keeps
    // naming the ORIGINAL `UsedNS`. `TFuncKey<UsedNS, …>` then never reduced,
    // no argument was assignable to the unreduced conditional, and every
    // two-argument `t(key, {opts})` in outline was a TS2769.
    // The alias is minted only where the reference is genuinely dangling: a
    // bound at position `i` naming the original of a parameter freshened at
    // position `j > i`. A bound naming an EARLIER sibling was rewritten to the
    // fresh symbol when it was minted (the rewrite map grows as that loop
    // walks), so aliasing there binds a symbol that is already bound — and
    // doing it anyway perturbs unrelated overload sets: es-toolkit's
    // `filter<T extends object, U extends T[keyof T]>` is a forward reference,
    // and `filter(users.all, (u) => …)` lost its callback's contextual type
    // (a TS7006 on `u`) when the alias did not distinguish the two directions.
    //
    // Nothing here runs unless some parameter WAS freshened: the bounds are
    // read up front to answer the gate, and reading them forces every
    // deferred one (`FreshTp.pending_bound`) earlier than the resolution loop
    // below would have. On a signature with no fresh parameter there is
    // nothing to alias, so that cost — and that reordering — is skipped.
    var cons: []TypeId = &.{};
    var n_alias: usize = 0;
    for (tp_syms) |tp| {
        if (origTpSym(c, tp) == null) continue;
        cons = try c.scratch().alloc(TypeId, tp_syms.len);
        for (tp_syms, 0..) |t2, i| cons[i] = try c.typeParamConstraint(t2);
        break;
    }
    for (tp_syms, 0..) |tp, j| {
        const orig = origTpSym(c, tp) orelse continue;
        if (tpIndex(tp_syms, orig) == null and try boundsName(c, cons[0..j], orig)) n_alias += 1;
    }
    var prov = try c.scratch().alloc(TpMap, tp_syms.len + n_alias);
    // `alias_slot[i]` is the index in `prov` of the alias entry mirroring
    // parameter `i`, or `prov.len` when it has none.
    const alias_slot = try c.scratch().alloc(usize, tp_syms.len);
    {
        var next = tp_syms.len;
        for (tp_syms, 0..) |tp, i| {
            const seed_ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type;
            prov[i] = .{ .sym = tp, .ty = seed_ty };
            alias_slot[i] = prov.len;
            const orig = origTpSym(c, tp) orelse continue;
            if (tpIndex(tp_syms, orig) != null) continue;
            if (!try boundsName(c, cons[0..i], orig)) continue;
            prov[next] = .{ .sym = orig, .ty = seed_ty };
            alias_slot[i] = next;
            next += 1;
        }
    }
    // Only the bound that actually names a dangling original is read under
    // the aliased map; every other bound keeps the exact map it saw before,
    // so the repair cannot reach a signature it has no business in.
    const aliased = try c.scratch().alloc(bool, tp_syms.len);
    @memset(aliased, false);
    if (n_alias != 0) {
        for (cons, 0..) |con, i| {
            if (con == types.no_type) continue;
            if (!try c.containsTypeParam(con)) continue;
            const m = try c.tpMentions(con);
            if (m.saturated) continue;
            for (m.syms) |sym| {
                for (prov[tp_syms.len..]) |al| {
                    if (al.sym == sym) aliased[i] = true;
                }
            }
        }
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
        var constraint: TypeId = if (cons.len != 0) cons[i] else try c.typeParamConstraint(tp);
        if (constraint != types.no_type) {
            constraint = try c.instantiate(constraint, if (aliased[i]) prov else prov[0..tp_syms.len]);
        }
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
            // `getCovariantInference` ends with `return getWidenedType(
            // unwidenedType)` UNCONDITIONALLY — the three-way choice above is
            // only about the CANDIDATES' literal types. That final widening is
            // where an object-literal candidate union is normalized against its
            // siblings (`{a: 1} | {b: 2}` ⇒ `{a: number; b?: undefined} |
            // {a?: undefined; b: number}`) and where the literal origin is
            // dropped, so it must run even when the literal-widening arm did
            // not (a type parameter at the top level of the return type).
            out[i] = try c.widenObjectLiterals(out[i]);
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
                out[i] = (try c.clampToConstraint(out[i], constraint)).ty;
            }
        } else if (c.typeParamHasDefault(tp)) {
            // Uninferable param with a default takes it, instantiated under
            // the params resolved so far (`B = A` sees the inferred `A`).
            const def = try c.typeParamDefault(tp);
            out[i] = try c.instantiate(def, prov[0..tp_syms.len]);
        } else {
            out[i] = if (constraint != types.no_type) constraint else types.unknown_type;
        }
        prov[i].ty = out[i];
        if (alias_slot[i] != prov.len) prov[alias_slot[i]].ty = out[i];
    }
    // Only the minted parameters that SURVIVED the folds above are worth
    // generalizing over: a slot the constraint clamp or the widening replaced
    // no longer names one.
    //
    // "Names one" is a MENTION, not an identity. A rest-tuple combinator answers
    // `A := [T']`, `B := T'[]` — the minted parameter is buried one constructor
    // deep in every slot — and an identity test read that as "did not survive",
    // dropped the whole list, and left `pipe(list)` printing the non-generic
    // `(...args: [T]) => T[]` where tsc answers `<T>(x: T) => T[]`. The probe is
    // the same occurs check `generalizeCallResult` runs on the result.
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(c.scratch());
    for (ho_minted.items) |m| {
        const probe = [1]TpMap{.{ .sym = m, .ty = types.unknown_type }};
        for (out) |o| {
            if ((try c.instantiate(o, &probe)) != o) {
                try kept.append(c.scratch(), m);
                break;
            }
        }
    }
    return c.scratch().dupe(u32, kept.items);
}

/// tsc's `getSignatureInstantiation` tail: re-attach the type parameters the
/// call's inference MINTED (`InferenceContext.inferredTypeParameters`) to the
/// single call signature the call returns.
///
/// ```ts
/// const returnSignature = getSingleCallOrConstructSignature(getReturnTypeOfSignature(instantiatedSignature));
/// if (returnSignature) {
///     const newReturnSignature = cloneSignature(returnSignature);
///     newReturnSignature.typeParameters = inferredTypeParameters;
///     …
/// }
/// ```
///
/// This is what makes `compose(list, box)` a GENERIC `<T>(a: T) => Box<T[]>`
/// rather than the `(a: unknown) => Box<unknown>` an erasing inference gives.
/// `inst` unchanged whenever there is nothing to attach — no minted parameter,
/// a non-function result, or a result that mentions none of them.
pub fn generalizeCallResult(c: *Checker, inst: TypeId, minted: []const u32) Error!TypeId {
    const s = &c.ts;
    if (minted.len == 0) return inst;
    if (s.kind(inst) != .function) return inst;
    const ret = s.fnReturn(inst);
    if (s.kind(ret) != .function or s.fnTypeParamCount(ret) != 0) return inst;
    // Which of them the result actually mentions. `instantiate` is the occurs
    // check ztsc already has: a term that CHANGES under `m := unknown` names
    // `m` (assign.zig's `instantiateSigInContextOf` uses the same probe).
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(c.scratch());
    for (minted) |m| {
        const probe = [1]TpMap{.{ .sym = m, .ty = types.unknown_type }};
        if ((try c.instantiate(ret, &probe)) != ret) try kept.append(c.scratch(), m);
    }
    if (kept.items.len == 0) return inst;
    const params = try c.scratch().alloc(types.Param, s.fnParamCount(ret));
    defer c.scratch().free(params);
    for (params, 0..) |*p, i| p.* = s.fnParam(ret, @intCast(i));
    const gen = try s.makeFunctionThis(
        params,
        s.fnReturn(ret),
        kept.items,
        s.fnFlags(ret),
        if (s.fnHasPredicate(ret)) s.fnPredicate(ret) else null,
        s.fnThisType(ret),
    );
    const outer = try c.scratch().alloc(types.Param, s.fnParamCount(inst));
    defer c.scratch().free(outer);
    for (outer, 0..) |*p, i| p.* = s.fnParam(inst, @intCast(i));
    return s.makeFunctionThis(
        outer,
        gen,
        s.fnTypeParams(inst),
        s.fnFlags(inst),
        if (s.fnHasPredicate(inst)) s.fnPredicate(inst) else null,
        s.fnThisType(inst),
    );
}

/// Does any of these (raw, unsubstituted) type-parameter bounds mention `sym`?
/// A bound that gave up on the question (`Mentions.saturated` — it nests a
/// signature binding its own parameters) answers NO: the alias it would gate
/// is a repair for a dangling reference we can actually see, and guessing at
/// one only risks binding a parameter that is legitimately free.
fn boundsName(c: *Checker, cons: []const TypeId, sym: u32) Error!bool {
    for (cons) |con| {
        if (con == types.no_type) continue;
        if (!try c.containsTypeParam(con)) continue;
        const m = try c.tpMentions(con);
        if (m.saturated) continue;
        for (m.syms) |s| {
            if (s == sym) return true;
        }
    }
    return false;
}

/// The DECLARATION symbol a signature type parameter stands for: itself, or —
/// when instantiation freshened it (`FreshTp`) — the original it was minted
/// from. Null when there is no distinct original.
fn origTpSym(c: *Checker, tp: u32) ?u32 {
    if (!c.isFreshTp(tp)) return null;
    const orig = c.freshTp(tp).orig;
    if (orig == 0 or orig == tp) return null;
    return orig;
}

pub fn tpIndex(tp_syms: []const u32, sym: u32) ?usize {
    for (tp_syms, 0..) |s, i| {
        if (s == sym) return i;
    }
    return null;
}

/// Is `t` a BARE inference variable of the call being solved — tsc's
/// "naked type variable" (`getInferenceInfoForType` answering for the type
/// itself, not for something wrapping it)?
fn isNakedInferVar(c: *Checker, t: TypeId, tp_syms: []const u32) bool {
    if (c.ts.kind(t) != .type_param) return false;
    return tpIndex(tp_syms, c.ts.typeParamSymbol(t)) != null;
}

/// Does `t` name any of `tp_syms` anywhere inside it? Answers the question
/// "is this candidate really evidence, or does it just echo a variable the
/// call has not solved yet".
///
/// Gated on `containsTypeParam` — a memoized bit — so a candidate with no
/// type parameter at all costs one lookup and never reaches the member walk
/// behind `tpMentions`. A signature that binds its OWN parameters saturates
/// there, which reads here as "mentions", and erring that way is the safe
/// direction: it falls back to the base-constraint erasure that is tsc's
/// unconditional behaviour for a generic argument signature.
fn echoesInferVar(c: *Checker, t: TypeId, tp_syms: []const u32) Error!bool {
    if (tp_syms.len == 0) return false;
    if (!try c.containsTypeParam(t)) return false;
    const m = try c.tpMentions(t);
    if (m.saturated) return true;
    for (m.syms) |sym| {
        if (tpIndex(tp_syms, sym) != null) return true;
    }
    return false;
}

/// The one construct-signature shape whose PARAMETERS carry inference
/// information when the source is a class value: a pattern written
/// `new (...args: P) => …` whose single rest parameter's type `P` mentions a
/// variable this call is solving.
///
/// That is exactly `NewableFunction`'s `strictBindCallApply` trio —
/// `call<T, A extends any[]>(this: new (...args: A) => T, …)` and
/// `bind<A, B, R>(this: new (...args: [...A, ...B]) => R, …)` — and binding
/// `A` to the class's own constructor parameter list is what turns
/// `C.call(c, 10)` into "Expected 3 arguments, but got 2" rather than a
/// TS2684 on `C` itself.
///
/// Deliberately narrow. The general rule (`inferFromSignature` pairing every
/// parameter) is wrong here because a class value's constructor arity is
/// unrelated to the arity of the `new (…) => T` interfaces that pattern is
/// otherwise written for; requiring a lone rest parameter typed by a live
/// variable leaves `new (...args: any[]) => T` — what those interfaces
/// universally write — pairing nothing, exactly as before.
///
/// Contravariant, as parameter positions are: the candidate it records must
/// outrank the covariant one the call's own `...args: A` supplies, or
/// `C.call(c, 10)` would bind `A` to the short argument list and report
/// nothing at all.
fn inferFromClassCtorParams(
    c: *Checker,
    param: TypeId,
    class_value: TypeId,
    tp_syms: []const u32,
    candidates: []TypeId,
    depth: u32,
) Error!void {
    const s = &c.ts;
    var rest_pat: TypeId = types.no_type;
    for (0..s.objectConstructSigCount(param)) |i| {
        const psig = s.objectConstructSig(param, @intCast(i));
        if (s.fnParamCount(psig) != 1) return;
        const p0 = s.fnParam(psig, 0);
        if (!p0.rest()) return;
        if (!try echoesInferVar(c, p0.ty, tp_syms)) return;
        // More than one candidate pattern signature: no basis to pick.
        if (rest_pat != types.no_type) return;
        rest_pat = p0.ty;
    }
    if (rest_pat == types.no_type) return;

    const cls = s.classSymbol(class_value);
    var ctor_sigs: std.ArrayList(TypeId) = .empty;
    defer ctor_sigs.deinit(c.scratch());
    try c.ctorSignatures(cls, &ctor_sigs);
    // An overloaded constructor gives no single parameter list to bind.
    if (ctor_sigs.items.len != 1) return;
    const csig = ctor_sigs.items[0];
    if (s.kind(csig) != .function) return;

    // The class's OWN type parameters are free in that signature (`declare
    // class Bag<T> { constructor(...args: T[]) }`), and a candidate mentioning
    // them is worse than none: `asFunction(Bag)` would bind `A` to `[...T[]]`
    // and every later `newBag('a', 'b', 'c')` becomes TS2345. tsc erases them
    // to their base constraints before inferring (`getBaseSignature`), which
    // is what makes `A` land on `unknown[]` there. `instanceofInstanceType`
    // above does the same thing on the return side, at `any`.
    var erase: std.ArrayList(TpMap) = .empty;
    defer erase.deinit(c.scratch());
    {
        var tps: std.ArrayList(checker_zig.Checker.TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(cls, &tps);
        for (tps.items) |tp| {
            try erase.append(c.scratch(), .{ .sym = tp.sym, .ty = try c.typeParamFallback(tp.sym) });
        }
    }

    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    for (0..s.fnParamCount(csig)) |i| {
        var sp = s.fnParam(csig, @intCast(i));
        if (erase.items.len != 0) sp.ty = try c.instantiate(sp.ty, erase.items);
        var eflags: u32 = 0;
        if (sp.rest()) eflags |= types.elem_flag_rest;
        if (sp.optional()) eflags |= types.elem_flag_optional;
        try elems.append(c.scratch(), .{ .ty = sp.ty, .flags = eflags });
    }
    c.infer_ctx.contra_pos += 1;
    defer c.infer_ctx.contra_pos -= 1;
    try c.unify(rest_pat, try s.makeTuple(elems.items), tp_syms, candidates, depth + 1);
}

/// Whether any argument is a function EXPRESSION — the only thing Phase 2 of
/// `inferTypeArgs` contextually types, and so the only reason to pay for the
/// seed's constraint clamp.
fn anyFunctionArg(c: *const Checker, arg_nodes: []const Node) bool {
    for (arg_nodes) |an| {
        if (an != null_node and isFunctionArg(c, an)) return true;
    }
    return false;
}

/// Is `an` an argument Phase 2 owns — an arrow or function expression, through
/// however many parentheses were written around it? tsc's `isContextSensitive`
/// looks through them (`case SyntaxKind.ParenthesizedExpression`), so both
/// phases must agree on which arguments are functions or a parenthesized
/// callback falls between them.
fn isFunctionArg(c: *const Checker, an: Node) bool {
    return switch (c.nodeTag(skipParens(c, an))) {
        .arrow_fn, .function_expr => true,
        else => false,
    };
}
/// The constraint clamp, applied to a Phase-2 SEED rather than to the final
/// answer (see the call site). `sofar` is the partial map built for the
/// parameters before this one, so an inter-dependent constraint
/// (`K extends keyof T`) is judged with `T` already substituted — the same
/// ordering the final loop uses.
///
/// Deliberately narrower than the final clamp, because this one decides what a
/// callback body is CHECKED against and a wrong answer here publishes wrong
/// diagnostics rather than merely losing an inference:
///
///   * `any` / `unknown` constraints admit everything, so there is nothing to
///     clamp to,
///   * a constraint still mentioning a free type parameter is one this call has
///     not resolved (a later sibling, or the receiver's own parameter — see the
///     `bare_outer` note at the final clamp): `isAssignable` against it always
///     fails, and clamping would erase a legitimate inference,
///   * and an argument that already satisfies its constraint is untouched,
///     which is the overwhelming majority.
fn clampSeedToConstraint(c: *Checker, tp: u32, tp_syms: []const u32, sofar: []const TpMap, cand: TypeId) Error!TypeId {
    _ = tp_syms;
    var con = try c.typeParamConstraint(tp);
    if (con == types.no_type) return cand;
    if (sofar.len != 0) con = try c.instantiate(con, sofar);
    switch (c.ts.kind(con)) {
        .any, .unknown, .err => return cand,
        else => {},
    }
    if (try c.containsFreeTypeParam(con, &.{})) return cand;
    if (try c.isAssignable(cand, con)) return cand;
    return (try c.clampToConstraint(cand, con)).ty;
}

/// What `clampToConstraint` answered: the type to use for the inference, and
/// whether the FULL constraint clamp was taken rather than the
/// constraint-satisfying subset of a union candidate.
pub const Clamped = struct { ty: TypeId, fell_back: bool };

/// A candidate that violates its param's constraint is normally clamped to
/// the constraint. When the candidate is a UNION, prefer the
/// constraint-satisfying members over erasing the whole inference — this
/// drops contravariant-inference pollution such as a function type inferred
/// from a callback's PARAMETER position (`onChange: (v: T) => void` fed a
/// `Dispatch<SetStateAction<E>>`, contributing `E | ((p:E)=>E)` to `T`),
/// which the covariant candidate (`E` from `value`) should win over. tsc
/// keeps covariant and contravariant candidates separate and prefers
/// covariant; this approximates that at the resolution seam. The answer's
/// `fell_back` is set only when the full constraint clamp is used.
pub fn clampToConstraint(c: *Checker, cand: TypeId, constraint: TypeId) Error!Clamped {
    if (c.ts.kind(cand) == .union_type) {
        const members = try c.memberList(cand);
        var keep: std.ArrayList(TypeId) = .empty;
        defer keep.deinit(c.scratch());
        for (members) |m| {
            if (try c.isAssignable(m, constraint)) try keep.append(c.scratch(), m);
        }
        if (keep.items.len > 0 and keep.items.len < members.len) {
            const filtered = try c.ts.makeUnion(c.scratch(), keep.items);
            if (try c.isAssignable(filtered, constraint)) return .{ .ty = filtered, .fell_back = false };
        }
    }
    return .{ .ty = constraint, .fell_back = true };
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
        // tsc's `isObjectOrArrayLiteralType` tests `ObjectFlags.ObjectLiteral`,
        // which is the literal's ORIGIN, not its freshness: a literal written
        // as the property of another literal has already lost freshness by the
        // time it becomes a candidate, and testing that instead made
        // `f({x: {a: 1}, y: {b: 2}})` keep only the leftmost candidate.
        .object => c.ts.objectIsLiteralOrigin(t),
        // The ACCUMULATED union of literal candidates is still the literal
        // candidate set. tsc does not fold literals pairwise at all —
        // `unionObjectAndArrayLiteralCandidates` pulls every object/array
        // literal out of the candidate list in one pass and replaces them
        // with a single `getUnionType(…, Subtype)` — so a third literal joins
        // the same union rather than meeting a union on the supertype rule.
        // Without this the pairwise fold answered `covSubtypeOf(a, b) ? b : a`
        // for `union-so-far` vs `third literal`, which are unrelated, and
        // DROPPED the third: `sel({a: {x: 1}, b: {y: 2}, c: {z: 3}})` inferred
        // `{x} | {y}` and reported `{z}` as unassignable. It also made the
        // answer depend on the order the candidates arrived in — object member
        // order is atom-derived and atoms are numbered in file order — so the
        // same program disagreed with itself under `--file-order`
        // (bench/order_sweep.sh). A set union has neither defect.
        .union_type => {
            const ms = c.ts.members(t);
            if (ms.len == 0) return false;
            for (ms) |m| if (!c.covLiteralShape(m)) return false;
            return true;
        },
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

/// One type parameter's answer, given its covariant candidate `cov` and the
/// contravariant pair (`con`, the common-subtype fold; `con_sup`, the union
/// standing in for the candidate LIST — see `InferCtx.contra_sup`).
///
/// tsc's `getInferredType`:
///
/// ```ts
/// inferredType = inferredCovariantType && !(inferredCovariantType.flags & TypeFlags.Never) &&
///     some(inference.contraCandidates, t => isTypeSubtypeOf(inferredCovariantType, t)) ?
///     inferredCovariantType : getContravariantInference(inference);
/// ```
///
/// Shared by the outer resolution and the two-round object-literal probe,
/// which runs the same choice over its own scratch candidate arrays.
fn preferContravariant(c: *Checker, cov: TypeId, con: TypeId, con_sup: TypeId) Error!TypeId {
    if (con == types.no_type) return cov;
    if (cov == types.no_type or c.ts.kind(cov) == .never) return con;
    if (try c.covSubtypeOf(cov, con)) return cov;
    if (con_sup != types.no_type and try c.covSubtypeOf(cov, con_sup)) return cov;
    return con;
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
    const ra = try c.resolveStructural(a);
    // …EXCEPT when the source was written as an object literal (or is a
    // tuple). tsc gates the whole optional-property demand on
    // `requireOptionalProperties = (relation === subtypeRelation ||
    // relation === strictSubtypeRelation) && !isObjectLiteralType(source) &&
    // !isEmptyArrayLiteralType(source) && !isTupleType(source)`, and a
    // covariant inference candidate is an object literal exactly as often as
    // not: `route({ pre: (a: { query?: unknown; body?: unknown }) => {},
    // schema: { query: "" } })` contributes the covariant `{ query: string }`
    // and the contravariant `{ query?: unknown; body?: unknown }`, and
    // demanding `body` of the literal rejected the covariant answer, so
    // `TSchema["query"]` came out `unknown` (`coAndContraVariantInferences7`).
    const require_optional = !c.ts.objectIsLiteralOrigin(ra) and c.ts.kind(ra) != .tuple;
    if (require_optional) {
        for (0..c.ts.objectPropCount(rb)) |i| {
            const p = c.ts.objectProp(rb, @intCast(i));
            if (p.flags & types.prop_flag_optional == 0) continue;
            if (try c.propOfType(a, p.name) == null) return false;
        }
    }
    // An INDEX SIGNATURE on the target must be present on the source. This
    // is the assignable/subtype gap that decides `reduce`: assignability
    // gives an object literal an *implicit* index signature (`const r:
    // Record<string, true> = {}` is legal), so `{}` — the covariant
    // candidate the seed argument contributes — came back assignable to the
    // callback accumulator's declared `Record<string, true>` and the
    // covariant inference was kept. tsc runs this test under the SUBTYPE
    // relation, where `getImplicitIndexInfoOfType` does not apply, so `{}`
    // is not a subtype of `Record<string, true>` and the CONTRAVARIANT
    // candidate — the annotated accumulator — wins, which is the whole
    // point of keeping the two candidate sets apart.
    //
    // `arr.reduce((acc: Record<string, true>, e) => …, {})` inferred `{}`
    // for the accumulator; every later read of the result was then an
    // implicit-any element access (TS7053).
    inline for (.{ types.Store.objectStringIndex, types.Store.objectNumberIndex }) |idx| {
        if (idx(&c.ts, rb) != 0) {
            if (c.ts.kind(ra) != .object) return false;
            if (idx(&c.ts, ra) == 0) return false;
        }
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
    //
    // "Weakest evidence" is a statement about a bare variable STANDING BESIDE
    // a structural candidate, so it only applies when exactly one side is one.
    // Two bare variables are peers — neither is the weaker reading of the
    // other — and tsc folds them with the ordinary `getCommonSupertype`
    // (`reduceLeft((s, t) => isTypeSubtypeOf(s, t) ? t : s)`), which keeps the
    // LEFTMOST of two unrelated parameters. That pair is the signature
    // relation's normal case, where the "concrete" types are the target's own
    // free parameters: `<T>(x: {foo: T}, y: {foo: T; bar: T}) => number`
    // against `<T, U>(x: {foo: T}, y: {foo: U; bar: U}) => number` collects
    // `T` and `U` for the source's single parameter. Unioning them made the
    // instantiated source `{foo: T|U; bar: T|U}`, which absorbs both of the
    // target's parameters and relates; tsc keeps `T`, so `y` fails
    // contravariantly and the pair is a TS2322
    // (`assignmentCompatWith{Call,Construct}Signatures5`/`6`).
    if ((s.kind(prev) == .type_param) != (s.kind(cand) == .type_param)) return c.makeUnion2(prev, cand);
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
    const ctx = &c.infer_ctx;
    if (ctx.contra_pos % 2 == 0) return null;
    if (ctx.owner != candidates.ptr) return null;
    if (ctx.contra.len != candidates.len) return null;
    return &ctx.contra[i];
}

/// Record `cand` in the union half of the contravariant candidate set (see
/// `InferCtx.contra_sup`). Called wherever `contraSlot` is written — which is
/// where the ownership check has already been made, so this only has to agree
/// on the shape.
pub fn noteContraCandidate(c: *Checker, candidates: []TypeId, i: usize, cand: TypeId) Error!void {
    const ctx = &c.infer_ctx;
    if (ctx.contra_sup.len != candidates.len) return;
    ctx.contra_sup[i] = if (ctx.contra_sup[i] == types.no_type)
        cand
    else
        try c.ts.makeUnion(c.scratch(), &.{ ctx.contra_sup[i], cand });
}

/// tsc's `impliedArity` bookkeeping in `inferTypeArguments`:
///
/// ```ts
/// const restType = getNonArrayRestType(signature);
/// const argCount = restType ? Math.min(getParameterCount(signature) - 1, args.length) : args.length;
/// if (restType && restType.flags & TypeFlags.TypeParameter) {
///     const info = find(context.inferences, info => info.typeParameter === restType);
///     if (info) info.impliedArity = findIndex(args, isSpreadArgument, argCount) < 0 ? args.length - argCount : undefined;
/// }
/// ```
///
/// The signature's rest parameter must be a BARE type parameter (`...a: T`):
/// then the arguments past the fixed ones are exactly `T`'s elements, so their
/// count is `T`'s arity even before anything is inferred. A SPREAD argument in
/// that tail spends an unknown number of positions and leaves the arity unknown.
fn fillImpliedArity(
    c: *Checker,
    sig: TypeId,
    tp_syms: []const u32,
    arg_nodes: []const Node,
    out: []u32,
) Error!void {
    const pc = c.ts.fnParamCount(sig);
    if (pc == 0) return;
    const rest = c.ts.fnParam(sig, pc - 1);
    if (!rest.rest() or c.ts.kind(rest.ty) != .type_param) return;
    const idx = for (tp_syms, 0..) |sym, i| {
        if (sym == c.ts.typeParamSymbol(rest.ty)) break i;
    } else return;
    var n: u32 = 0;
    for (arg_nodes) |an| {
        if (an != null_node) n += 1;
    }
    const arg_count = @min(pc - 1, n);
    var seen: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer seen += 1;
        if (seen >= arg_count and c.nodeTag(an) == .spread_element) return;
    }
    out[idx] = n - arg_count;
}

/// The arity the call site implied for type parameter `i` (see
/// `InferCtx.implied_arity`), or null when there is none — including when
/// `candidates` is not the accumulator the in-flight call registered.
fn impliedArity(c: *Checker, candidates: []TypeId, i: usize) ?u32 {
    const ctx = &c.infer_ctx;
    if (ctx.owner != candidates.ptr) return null;
    if (ctx.implied_arity.len != candidates.len) return null;
    const a = ctx.implied_arity[i];
    return if (a == InferCtx.no_arity) null else a;
}

/// The `topLevel` flag for type parameter `i`, when `candidates` is the
/// accumulator the in-flight call registered (same identity rule as
/// `contraSlot`).
pub fn topSlot(c: *Checker, candidates: []TypeId, i: usize) ?*bool {
    const ctx = &c.infer_ctx;
    if (ctx.owner != candidates.ptr) return null;
    if (ctx.top_flags.len != candidates.len) return null;
    return &ctx.top_flags[i];
}

/// The lower-priority flag for type parameter `i`. Identity is the priority
/// half's OWN owner rather than the context's, so the two-round probe's
/// scratch accumulator can register for the priority tier alone (see
/// `InferCtx.Rev`).
pub fn revSlot(c: *Checker, candidates: []TypeId, i: usize) ?*bool {
    const rev = &c.infer_ctx.rev;
    if (rev.owner != candidates.ptr) return null;
    if (rev.flags.len != candidates.len) return null;
    return &rev.flags[i];
}

/// tsc's `inferFromTupleTypes`: how an array-or-tuple ARGUMENT pairs with a
/// tuple PATTERN.
///
/// The pairing is not index-for-index. tsc computes a `startLength` — the fixed
/// elements before the pattern's first variable element — and an `endLength` —
/// the fixed elements after its last one — pairs the prefix from the START,
/// pairs the suffix from the END, and gives everything between them to the one
/// variable element in the middle. Index-for-index pairing is what that reduces
/// to when neither side has a variable element, which is why every fully fixed
/// pair walks exactly as it did before.
///
/// Three middles are handled, all of them tsc's:
///
///   * the ARGUMENT is a plain array, or one rest element covers its whole
///     middle: every pattern element in the middle infers from that element
///     type (a *variadic* pattern element infers from the whole array — it
///     stands for a list, not a member of one);
///   * one VARIADIC pattern element: it infers from the argument's middle
///     packed back into a tuple, which is what that element denotes;
///   * one REST pattern element: it infers from an array over the union of the
///     argument's middle.
///
/// tsc has a fourth for TWO adjacent variadic pattern elements
/// (`[...T, ...U]`), split by the arity a call site's trailing arguments imply;
/// that needs the call's `impliedArity` threaded into inference and is not
/// modelled — those patterns infer from the prefix and suffix only.
///
/// social-app's storage layer is the prefix/suffix shape: `useStorage<Store,
/// Key extends keyof StorageSchema<Store>>(storage: Store, scopes:
/// [...StorageScopes<Store>, Key])` called as `useStorage(device, ['themeKey'])`,
/// where `StorageScopes<device>` reduces to `[]`. Paired from index 0,
/// `...Scopes` swallowed `'themeKey'`, `Key` was never inferred and fell back to
/// its constraint `keyof Device` — so every read came back as the union of every
/// value type in the schema, and the write side rejected every value.
fn inferFromTupleTypes(
    c: *Checker,
    param: TypeId,
    ra: TypeId,
    tp_syms: []const u32,
    candidates: []TypeId,
    depth: u32,
) Error!void {
    const s = &c.ts;
    const src_tuple = s.kind(ra) == .tuple;
    const p_arity = s.tupleLen(param);
    const s_arity: u32 = if (src_tuple) s.tupleLen(ra) else 1;
    const p_fixed = tuple_relate.fixedLength(c, param);
    const p_variable = p_fixed < p_arity;
    const start = @min(if (src_tuple) tuple_relate.fixedLength(c, ra) else 0, p_fixed);
    const end = @min(
        if (src_tuple) endFixedCount(c, ra) else 0,
        if (p_variable) endFixedCount(c, param) else 0,
    );
    // The argument must be long enough to fill both fixed ends; if it is not,
    // there is no consistent split and nothing here can be trusted.
    if (start + end > s_arity or start + end > p_arity) return;

    for (0..start) |i| {
        try c.unify(s.tupleElem(param, @intCast(i)).ty, s.tupleElem(ra, @intCast(i)).ty, tp_syms, candidates, depth + 1);
    }

    const mid_src = s_arity - start - end;
    const one_rest_middle = !src_tuple or
        (mid_src == 1 and tuple_relate.elemKind(c, s.tupleElem(ra, start)) == .rest);
    if (one_rest_middle) {
        // `rest_arr` is the ARRAY the middle spans; `rest_elem` one member of
        // it. ztsc stores the array on a rest element where tsc stores the
        // element type and rebuilds the array with `createArrayType`.
        const rest_arr = if (src_tuple) s.tupleElem(ra, start).ty else ra;
        const rest_elem = try c.elemOfArrayish(rest_arr);
        var i = start;
        while (i < p_arity - end) : (i += 1) {
            const pe = s.tupleElem(param, i);
            const arg_ty = if (tuple_relate.elemKind(c, pe) == .variadic) rest_arr else rest_elem;
            try c.unify(pe.ty, arg_ty, tp_syms, candidates, depth + 1);
        }
    } else if (p_arity - start - end == 1) {
        const pe = s.tupleElem(param, start);
        switch (tuple_relate.elemKind(c, pe)) {
            .variadic => try c.unify(pe.ty, try typenode.sliceTuple(c, ra, start, end), tp_syms, candidates, depth + 1),
            // The run the pattern's single rest element spans, as one array —
            // tsc's `getElementTypeOfSliceOfTupleType` + `createArrayType`,
            // which `typenode.tupleSliceElemArray` is.
            .rest => {
                if (try typenode.tupleSliceElemArray(c, ra, start, end)) |arr| {
                    try c.unify(pe.ty, arr, tp_syms, candidates, depth + 1);
                }
            },
            // A FIXED pattern element cannot absorb a run of argument
            // elements; tsc has no arm for it either.
            .required, .optional => {},
        }
    } else if (src_tuple and p_arity - start - end == 2) {
        // tsc's fourth middle: TWO ADJACENT VARIADIC pattern elements
        // (`[...T, ...U]`). The pattern offers no split of its own, so the one
        // the CALL SITE implies is used — `impliedArity(T)` is how many
        // arguments were passed past the fixed parameters, i.e. how many
        // elements `T` stands for:
        //
        // ```ts
        // inferFromTypes(sliceTupleType(source, startLength, endLength + sourceArity - impliedArity), elementTypes[startLength]);
        // inferFromTypes(sliceTupleType(source, startLength + impliedArity, endLength), elementTypes[startLength + 1]);
        // ```
        //
        // `curry<T extends unknown[], U extends unknown[], R>(f: (...args:
        // [...T, ...U]) => R, ...a: T)` is the shape: `curry(fn1, 1, 'abc')`
        // implies `T`'s arity 2, so `fn1`'s parameter list splits into
        // `T := [number, string]` and `U := [boolean, string[]]`. With no
        // split at all both fell back to their `unknown[]` constraint and
        // every `curry` call site was a TS2345 (`variadicTuples1`).
        const e0 = s.tupleElem(param, start);
        const e1 = s.tupleElem(param, start + 1);
        if (tuple_relate.elemKind(c, e0) == .variadic and tuple_relate.elemKind(c, e1) == .variadic and
            s.kind(e0.ty) == .type_param)
        {
            const tp_idx = for (tp_syms, 0..) |sym, i| {
                if (sym == s.typeParamSymbol(e0.ty)) break i;
            } else tp_syms.len;
            if (tp_idx < tp_syms.len) {
                if (impliedArity(c, candidates, tp_idx)) |ia| {
                    // `T` takes the `ia` elements right after the prefix, `U`
                    // everything from there to the suffix. (tsc spells the
                    // first skip `endLength + sourceArity - impliedArity`,
                    // which is this with its own `startLength`/`endLength` of
                    // zero — the only values a bare `[...T, ...U]` pattern can
                    // have.)
                    //
                    // An implied arity PAST the source's own positions is not a
                    // dead end: tsc has no guard here, and both slices stay
                    // meaningful because `sliceTupleType` answers the rest
                    // ARRAY once the index runs past the fixed part. That is
                    // `curry(fn2, 1, true, 'abc', 'def')` — implied arity 4
                    // over `[number, boolean, ...string[]]`'s 3 positions —
                    // where the head saturates to the whole tuple and the tail
                    // is `string[]`.
                    const head_skip = (s_arity - start) -| ia;
                    const head = try typenode.sliceTuple(c, ra, start, head_skip);
                    const tail = try typenode.sliceTuple(c, ra, start + ia, end);
                    try c.unify(e0.ty, head, tp_syms, candidates, depth + 1);
                    try c.unify(e1.ty, tail, tp_syms, candidates, depth + 1);
                }
            }
        }
    }

    for (0..end) |i| {
        const pi: u32 = @intCast(p_arity - 1 - i);
        const ai: u32 = @intCast(s_arity - 1 - i);
        try c.unify(s.tupleElem(param, pi).ty, s.tupleElem(ra, ai).ty, tp_syms, candidates, depth + 1);
    }
}

/// tsc's `getEndElementCount(t, ElementFlags.Fixed)`: how many TRAILING
/// elements occupy exactly one position each.
fn endFixedCount(c: *const Checker, tup: TypeId) u32 {
    const len = c.ts.tupleLen(tup);
    var n: u32 = 0;
    while (n < len) : (n += 1) {
        if (tuple_relate.elemKind(c, c.ts.tupleElem(tup, len - 1 - n)).variable()) break;
    }
    return n;
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
    // tsc's `anyFunctionType` is `createAnonymousType(undefined, emptySymbols,
    // emptyArray, emptyArray, emptyArray)`: zero properties, zero call and
    // construct signatures, zero index infos. So however `inferFromTypes`
    // descends into it — signature pairing, property pairing, index pairing,
    // the reverse-mapped walk — it finds nothing to pair and records nothing.
    // The only arm that would have spoken, the inference-position one, refuses
    // it outright on `ObjectFlags.NonInferrableType`.
    //
    // The `.type_param` arm's `containsAnyFunctionType` covers the case where a
    // placeholder is BURIED in the source (an object literal carrying one);
    // this covers the source that IS one, on every other arm — the reverse-
    // mapped walk and the union arm's naked-variable fallback among them, which
    // reach a candidate slot without passing through that check.
    if (arg == types.any_function_type) return;
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
    // tsc's `inferFromTypes` indexed-access pair: `O[K]` against `O2[K2]`
    // infers object against object and index against index, and does it
    // BEFORE either side is read through a constraint. It has to sit ahead of
    // the apparent-source rule below, which replaces `NMap[T2]` with its base
    // constraint `"A" | "B"` and leaves the pattern's `T` nothing structural
    // to bind — so `<T extends 1|2|3>(x: `${T}`) => NMap[T]` did not relate to
    // `<T2 extends 1|2>(x: `${T2}`) => NMap[T2]`: `instantiateSigInContextOf`
    // came back with no candidate for `T`, `T` was clamped to its own
    // constraint, and the instantiated return no longer matched
    // (`templateLiteralTypes7` g3). The parameter positions cannot answer for
    // it either — a template-literal pattern binds nothing at all.
    if (s.kind(param) == .index_access and s.kind(arg) == .index_access) {
        try c.unify(s.indexAccessObj(param), s.indexAccessObj(arg), tp_syms, candidates, depth + 1);
        try c.unify(s.indexAccessIndex(param), s.indexAccessIndex(arg), tp_syms, candidates, depth + 1);
        return;
    }
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
    if (buries) c.infer_ctx.nontop_depth += 1;
    defer if (buries) {
        c.infer_ctx.nontop_depth -= 1;
    };
    switch (s.kind(param)) {
        .type_param => {
            if (tpIndex(tp_syms, s.typeParamSymbol(param))) |i| {
                // tsc's `inferFromTypes` refuses a source carrying
                // `ObjectFlags.NonInferrableType` as a candidate for a type
                // variable, and `anyFunctionType` is the archetype: it is
                // what a context-sensitive function argument reads as while
                // the first inference round runs, so recording it would fix
                // the very parameter that round exists to leave open. The
                // flag PROPAGATES, so an object literal that merely carries
                // one is refused whole — which is what leaves redux-toolkit's
                // `CR` free after round one instead of pinned to a bag of
                // placeholders.
                if (c.aft_seen and try containsAnyFunctionType(c, arg, 0)) return;
                const cand = arg;
                // An inference was MADE here, whatever it does to the slot —
                // see `Checker.infer_writes`.
                c.infer_writes +%= 1;
                if (c.infer_ctx.nontop_depth > 0) {
                    if (c.topSlot(candidates, i)) |f| f.* = false;
                }
                // A candidate found in a PARAMETER position is
                // contravariant evidence and is kept apart from the
                // covariant set (tsc's `inferFromContravariantTypes`).
                if (c.contraSlot(candidates, i)) |slot| {
                    slot.* = if (slot.* == types.no_type) cand else try c.combineContravariant(slot.*, cand);
                    try c.noteContraCandidate(candidates, i, cand);
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
                    if (c.infer_ctx.rev_prio > 0) {
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
                    // tsc's `inferFromIndexTypes`, in the direction the
                    // object-param arm below already covers the reverse of.
                    // `U[]` is a reference to `Array<U>`, whose apparent
                    // members include `[n: number]: U`; a source object that
                    // declares a number index (`ConcatArray<T>`,
                    // `ArrayLike<T>`, `readonly [n: number]: T` interfaces)
                    // pairs with it and fixes `U` outright. This is the only
                    // route for a source that is array-LIKE without being
                    // iterable — `ConcatArray<T>` has no `[Symbol.iterator]`,
                    // so the iteration probe below sees nothing.
                    //
                    // It matters most for CONTEXTUAL-RETURN inference: the
                    // contextual type of `xs.concat(ys.map(f))`'s argument is
                    // `ConcatArray<Slice>`, and without this `U` in `map`'s
                    // `U[]` return stayed unbound, so the arrow's body got no
                    // contextual type, its object literal widened
                    // (`type: string` instead of `type: "b"`), and every
                    // `concat` overload rejected it — TS2769.
                    if (s.kind(ra) == .object and s.objectNumberIndex(ra) != 0) {
                        try c.unify(s.arrayElem(param), s.objectNumberIndex(ra), tp_syms, candidates, depth + 1);
                        return;
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
            if (s.kind(ra) == .tuple or s.kind(ra) == .array) {
                try inferFromTupleTypes(c, param, ra, tp_syms, candidates, depth);
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
            // PART of this arm is `typesDefinitelyUnrelated`, and part of it
            // is a discriminant filter after all. Waves 21, 22 and 28 each
            // re-derived a piece; the whole answer, from the oracle:
            //
            // With `src: {kind:'b', p:string, q:number}`, tsgo 7.0.2 answers
            // each constituent ALONE (the control wave 21 was missing):
            //
            //   {kind:'a',p:T}                                   -> unknown
            //   {kind:'a',p:T,q:number}                          -> string
            //   {kind:'b',q:T}                                   -> number
            //   {p:T}                                            -> string
            //   {p:T,z:boolean}                                  -> unknown
            //
            // Rows 1 and 5 infer NOTHING even standing alone, so those two
            // rows are not a union rule: they are `typesDefinitelyUnrelated`
            // gating `inferFromObjectTypes` (see the `.object` arm). Row 1 is
            // unrelated because `kind` disagrees AND the target is missing
            // `q`; row 2 differs only in covering `q`, which is why it infers
            // despite the same discriminant mismatch. ztsc reproduces all five
            // exactly, so that half is faithful and needs nothing here.
            //
            // What wave 22 then concluded — that feeding those solo answers
            // into the leftmost supertype fold reproduces every union row, so
            // there is no filter at all — is FALSE, and the control that
            // settles it is below: `Item<T> = {kind:'a',data:T} |
            // {kind:'b',data:T[]}` fed `{kind:'b',data:[1,2]}` answers
            // `number` for the union while its 'a' constituent answers
            // `number[]` ALONE and 'a' is leftmost. A discriminant filter runs
            // over the union, and it is the block immediately below.
            //
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
            // A DISCRIMINATED union PARAMETER fed a single object argument
            // infers from the constituent the argument's own discriminant
            // selects, and from that one ALONE. The union-ARGUMENT arm below
            // already applies this rule (`discriminatedConstituent`, tsc's
            // `getMatchingUnionConstituentForType`); the union-PARAMETER side
            // did not, and `inferToMultipleTypes`' per-constituent fold then
            // took the leftmost candidate.
            //
            // `discriminatedUnionInference` (the #28862 repro) is the case:
            // `Item<T> = {kind:'a',data:T} | {kind:'b',data:T[]}` fed
            // `{kind:'b',data:[1,2]}` answered `T = number[]` where tsgo 7.0.2
            // answers `number`, so the argument was a false TS2345 against the
            // 'a' constituent.
            //
            // A wave-22 note here concluded the opposite — that no union rule
            // is involved and `typesDefinitelyUnrelated` explains everything.
            // The SOLO controls it was missing settle it (tsgo 7.0.2, each
            // constituent standing alone, no contextual return type on the
            // call so the seed cannot fix `T`):
            //
            //   {kind:'a',data:T}      <- {kind:'b',data:[1,2]}   -> number[]
            //   {kind:'a',p:T,q:number}<- {kind:'b',p:'str',q:1}  -> string
            //   {kind:'a',p:T}         <- {kind:'b',p:'str',q:1}  -> unknown
            //   Item<T> (the UNION)    <- {kind:'b',data:[1,2]}   -> number
            //
            // ztsc reproduces the first three exactly, so its
            // `typesDefinitelyUnrelated` is faithful — and the fourth row is
            // NOT the fold of the first two. The non-matching constituent does
            // infer on its own and is dropped by the union.
            //
            // Only for a bare object argument with no naked type-param member
            // in the union (`T | {kind:'a'}` still owes its variable the whole
            // source), and only when exactly one constituent agrees on every
            // unit-literal property of the argument — `discriminatedConstituent`
            // answers null otherwise, which leaves the walk below untouched.
            if (n_tp == 0 and s.kind(arg) != .union_type) {
                const arg_obj = try c.resolveStructural(arg);
                if (s.kind(arg_obj) == .object and s.objectPropCount(arg_obj) != 0) {
                    if (try c.discriminatedConstituent(arg_obj, param, .unit_on_both)) |m| {
                        try c.unify(m, arg, tp_syms, candidates, depth + 1);
                        return;
                    }
                }
            }
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
            // The `matched` bookkeeping is only CONSULTED when there is
            // exactly one naked type-param member (tsc's `typeVariableCount
            // === 1`), but the SPLIT itself is unconditional in tsc, so a
            // target union with no naked member at all splits too. It has to:
            // a wrapper cannot invert a union — the `.function` arm bails
            // because a union is not a function, and the `.object` arm has no
            // properties to pair — so handing it the whole argument yields no
            // candidate whatsoever.
            //
            // @types/react 17's `forwardRef<T, P>(render: RenderFn<T, P>)` is
            // that shape: the only mention of `T` is the render function's
            // `ref` parameter, `ForwardedRef<T> = ((instance: T | null) =>
            // void) | MutableRefObject<T | null> | null`, and the argument's
            // `Ref<Div> = RefCallback<Div> | RefObject<Div> | null` pairs off
            // by symbol on neither arm (`RefObject` and `MutableRefObject` are
            // different interfaces; `RefCallback` is an indexed access with no
            // counterpart alias). `T` fell to `unknown` and every
            // `React.forwardRef((props, ref) => …)` was rejected against
            // `ForwardRefRenderFunction<unknown, P>` — 18 keys on outline,
            // conformance `inference/123`.
            //
            // Splitting is safe here only BECAUSE the by-symbol pass below
            // runs first: without it, offering every source constituent to
            // every target constituent manufactures candidates from unrelated
            // pairs (`IteratorReturnResult<void>` into `IteratorYieldResult
            // <T>` pairs their `value` members and turns every
            // `Array.from(gen)` into `void[]`).
            //
            // …and tsc runs `inferFromMatchingTypes` a SECOND time over what
            // the identity pass above left, with `isTypeCloselyMatchedBy`: a
            // source and a target constituent that are two instantiations of
            // the same generic (`s.symbol === t.symbol`, or the same alias
            // symbol) are inferred as a PAIR and both sides are then struck
            // from the lists. Only the residual of THAT reaches
            // `inferToMultipleTypes`. `inferFromExtends` already does this
            // for the conditional-`infer` path (`inferCloselyMatched`); the
            // call-inference path did not, and handed every target
            // constituent the whole union instead.
            //
            // React 19's `Ref<T> = RefCallback<T> | RefObject<T | null> |
            // null` is the shape that needs it. `mergeRefs([scrollEdgeRef,
            // ref])` hands `((node: any) => void) | RefObject<Props>` to it;
            // the `RefObject<T | null>` member pairs off by symbol, leaving
            // the bare callback for `RefCallback<T>` — which is a `.function`
            // pattern and bails on a union argument outright (`if (kind(ra)
            // != .function) return`). Without the pairing the callback's
            // `any` parameter was never seen at all, so `T` collapsed to the
            // object ref's `Props` where tsc common-supertypes the two
            // candidates to `any`, and the JSX `ref=` attribute was rejected.
            //
            // Pairing by SYMBOL is what keeps this from being the blunt
            // "offer every source constituent to every target": that
            // manufactures candidates from unrelated pairs. `Iterator.next()`
            // returns `IteratorYieldResult<T> | IteratorReturnResult<TReturn>`,
            // and offering `IteratorReturnResult<void>` to
            // `IteratorYieldResult<T>` pairs their `value` properties and
            // infers `T = void` — which is what turns every `Array.from(gen)`
            // into `void[]`.
            const pms = try c.scratch().dupe(TypeId, try c.memberList(param));
            const rms: []const TypeId = if (s.kind(arg_residual) == .union_type)
                try c.scratch().dupe(TypeId, try c.memberList(arg_residual))
            else
                &.{arg_residual};
            const tgt_paired = try c.scratch().alloc(bool, pms.len);
            @memset(tgt_paired, false);
            const src_paired = try c.scratch().alloc(bool, rms.len);
            @memset(src_paired, false);
            var any_close = false;
            if (s.kind(arg_residual) == .union_type) {
                for (pms, 0..) |pm, ti| {
                    if (pm == tp_member) continue;
                    if (!try c.containsTypeParam(pm)) continue;
                    for (rms, 0..) |sm, si| {
                        if (!c.inferCloselyMatched(sm, pm)) continue;
                        try c.unify(pm, sm, tp_syms, candidates, depth + 1);
                        tgt_paired[ti] = true;
                        src_paired[si] = true;
                        any_close = true;
                    }
                }
            }
            // `sources` after both passes. tsc returns outright when nothing
            // is left on either side (`if (targets.length === 0) return;`,
            // and the `sources.length === 0` arm re-offers the whole source
            // at `NakedTypeVariable` priority); ztsc keeps offering what it
            // started with, so a still-unpaired target is no worse off than
            // it was before the pass existed.
            const rest_src: TypeId = if (!any_close) arg_residual else blk2: {
                var rest: std.ArrayList(TypeId) = .empty;
                defer rest.deinit(c.scratch());
                for (rms, 0..) |sm, si| {
                    if (!src_paired[si]) try rest.append(c.scratch(), sm);
                }
                if (rest.items.len == 0) break :blk2 arg_residual;
                break :blk2 try s.makeUnion(c.scratch(), rest.items);
            };
            const per_constituent = n_tp <= 1 and s.kind(rest_src) == .union_type;
            const src_members: []const TypeId = if (per_constituent)
                try c.memberList(rest_src)
            else
                &.{rest_src};
            const matched = try c.scratch().alloc(bool, src_members.len);
            @memset(matched, false);
            for (pms, 0..) |m, ti| {
                if (m == tp_member) continue;
                if (tgt_paired[ti]) continue;
                if (!try c.containsTypeParam(m)) continue;
                for (src_members, 0..) |sm, i| {
                    // "Was an inference MADE from this source constituent" —
                    // tsc watches `inferencePriority`, not the recorded
                    // answer. A constituent that re-proposes a candidate the
                    // set ALREADY holds still counts as matched: comparing the
                    // candidate array instead left it unmatched, and it then
                    // rode into the naked variable a second time. An
                    // intersection argument is where that bites, because every
                    // constituent walks the same target property — `QueryOptions
                    // <Link, Link> & {initialData?: …}` inferred `TData` from
                    // the ref by origin pairing first, so the override object's
                    // `InitialDataFunction<Link>` re-inference looked like a
                    // no-op and the whole union became the answer.
                    const writes_before = c.infer_writes;
                    try c.unify(m, sm, tp_syms, candidates, depth + 1);
                    if (c.infer_writes != writes_before) matched[i] = true;
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
                try inferFromClassCtorParams(c, param, ra, tp_syms, candidates, depth);
                return;
            }
            // A still-generic MAPPED source against an index-signature
            // pattern. tsc's `inferFromIndexTypes` reads
            // `getIndexInfosOfType(source)`, and `resolveMappedTypeMembers`
            // gives `{[P in keyof T]: V}` a string index of `V` whenever the
            // key set's lower bound covers the string key space — see
            // `mappedApparentStringIndex`. Without it `Object.entries(d)` on a
            // `Record<keyof T, V>` left `V` uninferred and fell to the
            // `entries(o: {}): [string, any][]` overload.
            if (s.kind(ra) == .mapped and s.objectStringIndex(param) != 0) {
                if (try c.mappedApparentStringIndex(ra)) |tmpl| {
                    try c.unify(s.objectStringIndex(param), tmpl, tp_syms, candidates, depth + 1);
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
                            // …UNLESS the application is an IDENTITY on that
                            // argument. `Omit<X, K>` where `K` names no key of
                            // `X` expands to a member table identical to `X`'s,
                            // and interning hands back `X` itself — so the
                            // origin's first type argument IS the type we are
                            // standing on, on both sides. Pairing it re-enters
                            // `unify` with the very pair that got here, which
                            // spins to the depth limit and returns having paired
                            // nothing, while the `return` below suppresses the
                            // structural walk that would have answered.
                            //
                            // That is the whole of `FeedPage.tsx:101`: the
                            // parameter `Omit<Helpers<T, NavState<T>>,
                            // 'getParent'> & {…}` and its argument both carry an
                            // `Omit` origin whose expansion is its own first
                            // argument, `T` took no candidate, and its
                            // `Extract<keyof T, string>` positions collapsed to
                            // `never`. Falling through to the property walk
                            // reaches `NavState<T>` vs `NavState<AllParams>`,
                            // where this same rule fires on a REAL
                            // decomposition and binds `T`.
                            var identity_app = false;
                            for (0..n) |i| {
                                if (pa[i] == param and (aa[i] == arg or aa[i] == ra)) identity_app = true;
                            }
                            if (!identity_app) {
                                for (0..n) |i| try c.unify(pa[i], aa[i], tp_syms, candidates, depth + 1);
                                return;
                            }
                        }
                    }
                }
                // tsc gates the whole structural block —
                // `inferFromProperties`, `inferFromSignatures`,
                // `inferFromIndexTypes` — on `!typesDefinitelyUnrelated`. Two
                // shapes that each require something the other lacks are not
                // an inference site at all: the candidates such a pair yields
                // are noise that then wins or loses the covariant fold by
                // accident. It is also the whole of the discriminated-union
                // story (see `typesDefinitelyUnrelated`) — `foo<T>(item:
                // {kind:'a',data:T} | {kind:'b',data:T[]})` fed
                // `{kind:'b',data:[1,2]}` stops collecting `T = number[]`
                // from the constituent whose `kind` cannot match, which is
                // what `discriminatedUnionInference` asks for.
                if (try typesDefinitelyUnrelated(c, ra, param)) return;
                for (0..s.objectPropCount(param)) |i| {
                    const pp = s.objectProp(param, @intCast(i));
                    if (s.objectPropByName(ra, pp.name)) |ap| {
                        // tsc's `inferFromProperties` pairs `getTypeOfSymbol`
                        // on both sides, and under `strictNullChecks` an
                        // OPTIONAL property's type carries `| undefined`. That
                        // matters for union-to-union inference: the source's
                        // `undefined` constituent pairs off identically with
                        // the target's and is REMOVED, so only the residual
                        // reaches the naked type variable. Dropping the
                        // implicit `| undefined` left it unpaired, and it then
                        // rode into every inferred argument —
                        // `queryOptions({queryFn: () => link})` fed to
                        // `fetchQuery<TQueryFnData, TData = TQueryFnData>`
                        // (whose `initialData?: TData | InitialDataFunction<
                        // TData>` is exactly this shape) inferred `TData =
                        // ResolvedLink | undefined`, and every use of the
                        // awaited result was a spurious TS18048.
                        //
                        // Only added when the source actually has an
                        // `undefined` to pair with: an absent one cannot
                        // subtract anything, and the extra union member would
                        // only cost interning.
                        // The SOURCE side of the same rule. `queryFn: ({
                        // pageParam }: { pageParam?: string }) => …` handed
                        // react-query's `QueryFunctionContext<TPageParam>`
                        // (whose `pageParam` is REQUIRED) contributed the
                        // contravariant `string`, so the covariant `undefined`
                        // that `initialPageParam: undefined` supplies was not a
                        // subtype of it and `getInferredType` took the
                        // contravariant answer — `initialPageParam` then failed
                        // against its own inference.
                        const at = if (ap.optional())
                            try c.makeUnion2(ap.ty, types.undefined_type)
                        else
                            ap.ty;
                        var pt = pp.ty;
                        if (pp.optional() and c.unionAnyMember(at, struct {
                            fn f(ch: *Checker, m: TypeId) bool {
                                return ch.ts.kind(m) == .undefined;
                            }
                        }.f)) {
                            pt = try c.makeUnion2(pt, types.undefined_type);
                        }
                        try c.unify(pt, at, tp_syms, candidates, depth + 1);
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
                if (try c.discriminatedConstituent(param, ra, .unit_on_source)) |m| {
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
            // tsc's `InferenceInfo.isFixed`, for the one place ztsc needs it —
            // the spec paragraph `contextualSignatureInstantiation.ts` opens
            // with: "any inferences made for type parameters referenced by the
            // PARAMETERS of T's call signature are FIXED, and e's type is
            // changed to a function type with e's call signature instantiated
            // in the context of T's call signature".
            //
            // The instantiation below hands the argument's signature what this
            // call has already inferred, so everything the ensuing walk reads
            // out of a PARAMETER position of it is our own guess coming home.
            // `bar<T, U, V>(x: T, y: U, cb: (x: T, y: U) => V)` fed
            // `bar(1, "one", g)` with `g: <W>(x: W, y: W) => W` is the shape:
            // `W` takes `T`'s `1`, the instantiated `(x: 1, y: 1) => 1` is
            // walked against `(x: T, y: U) => V`, and `U` — already `"one"` —
            // reads `1` back out of the second parameter.
            //
            // So the slots the contextual signature's parameters mention are
            // snapshotted and restored on the way out, EXCEPT the one the
            // instantiation itself just determined. Armed only when that
            // instantiation actually substituted something (`FixedSlots.arm`
            // is never called otherwise), so every argument that does not
            // reach it keeps its prior behaviour exactly.
            var ho_fix: FixedSlots = .{};
            defer ho_fix.restore(c, candidates);
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
            // An OVERLOAD SET argument — merged `declare function`
            // declarations, which is what `console.error` becomes once
            // @types/node's three signatures merge. Same rule as the callable
            // object just above and for the same reason (`inferFromSignatures`
            // pairs `sourceSignatures[sourceLen - len + i]` with
            // `targetSignatures[targetLen - len + i]`, so a one-signature
            // parameter takes the source's LAST overload) — but ztsc had no
            // `.overloads` arm here at all and simply bailed. `Promise.catch`'s
            // `TResult` was then left at its DEFAULT `never`, the parameter
            // printed as `((reason: any) => PromiseLike<never>) | null |
            // undefined`, and every `.catch(console.error)` was TS2345.
            if (s.kind(ra) == .overloads) {
                const ms = try c.memberList(ra);
                if (ms.len == 0) return;
                ra = ms[ms.len - 1];
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
                // Positions, not declared parameters — see `restTupleOf`. A
                // combinator's own result is spelled `(...args: [V]) => …`, and
                // reading `fnParam(ra, 0).ty` raw handed the pattern the
                // one-element TUPLE where the position holds `V`, so the
                // pairing found nothing and `pipe(list, pipe(box))` minted a
                // fresh parameter instead of adopting what its first argument
                // had already inferred.
                const own_rest_tuple = try restTupleOf(c, ra);
                const pat_rest_tuple = try restTupleOf(c, param);
                const np = @min(
                    paramPositions(c, param, pat_rest_tuple),
                    paramPositions(c, ra, own_rest_tuple),
                );
                for (0..np) |i| {
                    // Reversed roles: the arg's param types are the pattern,
                    // the expected param types the source.
                    try c.unify(
                        paramTypeAt(c, ra, own_rest_tuple, @intCast(i)),
                        paramTypeAt(c, param, pat_rest_tuple, @intCast(i)),
                        own_syms,
                        own_cands,
                        depth + 1,
                    );
                }
                var map_list: std.ArrayList(TpMap) = .empty;
                defer map_list.deinit(c.scratch());
                var all_unbound = true;
                var erased_self = false;
                for (own_syms, own_cands) |sym, cand0| {
                    // A candidate that MENTIONS one of the parameters this
                    // call is still solving carries no information: it would
                    // leave the argument's signature naming the very variable
                    // being inferred, and since parameters are contravariant
                    // that self-candidate then outranks the real covariant
                    // evidence and the signature stays uninstantiated. tsc
                    // erases a generic argument signature's own parameters
                    // to their base constraints (`getBaseSignature`) before
                    // inferring from it, which is what the fallback does.
                    //
                    // The mention need not be the whole candidate. react-query
                    // declares `placeholderData?: NonFunctionGuard<TQueryData>
                    // | PlaceholderDataFunction<NonFunctionGuard<TQueryData>>`
                    // and `keepPreviousData` is `<T>(prev: T | undefined) => T
                    // | undefined`, so `T`'s candidate is the CONDITIONAL
                    // `NonFunctionGuard<TQueryData>` — not a bare parameter,
                    // but every bit as self-referential. Substituted, it made
                    // the query's own data type infer to a type mentioning
                    // itself, and every consumer of the result read the
                    // unreduced conditional instead of the queried shape.
                    //
                    // Only THIS call's variables disqualify a candidate: an
                    // enclosing function's parameter is an ordinary type here
                    // and must keep flowing (`xs.map(identity)` inside
                    // `<T>(xs: T[])` still infers through `T`).
                    const self_ref = cand0 != types.no_type and
                        try echoesInferVar(c, cand0, tp_syms);
                    // …with one exception, and only in a SIGNATURE relation
                    // (`InferCtx.sig_ctx`): a candidate that IS one of the
                    // variables being solved, BARE, is the identity mapping
                    // between the two signatures' own parameters — exactly what
                    // tsc's `getCanonicalSignature` + `instantiateSignatureIn
                    // ContextOf` produce — not a self-referential type.
                    // Clamping it to the fallback does not merely lose it, it
                    // POISONS the outer inference: the argument signature then
                    // presents `unknown` in the very position whose pattern is
                    // the variable, and the outer walk records `unknown` for it.
                    // Leaving the argument's parameter FREE lets that walk pair
                    // the two variables directly.
                    //
                    // A recursive class hierarchy that redeclares a generic
                    // method is where it shows: `class D<Q> extends B<Q>` with
                    // `transaction<T>(cb: (tx: D<Q>) => Promise<T>)` over the
                    // base's `(tx: B<Q>) => Promise<T>` walked `D<Q>` against
                    // `B<Q>`, met the two `transaction`s again, erased the
                    // base's `T` to `unknown`, and came back with `T := unknown`
                    // for the whole instantiation. drizzle-orm's session /
                    // transaction chain is 8 such overrides on main, and the
                    // callback relation turns each into a TS2416 the oracle does
                    // not report.
                    //
                    // At a CALL SITE the same candidate is noise and the erasure
                    // stands: `map([1, 2, 3], identity)` must not leave `U`
                    // standing as `identity`'s own `A` (the
                    // `inferentialTypingWithFunctionType` /
                    // `contextualSignatureInstantiation` /
                    // `genericCallWithFunctionTypedArguments` families, 12 cases
                    // measured).
                    const bare_self = self_ref and c.infer_ctx.sig_ctx > 0 and
                        c.ts.kind(cand0) == .type_param and
                        tpIndex(tp_syms, c.ts.typeParamSymbol(cand0)) != null;
                    if (bare_self) continue;
                    // …and at a CALL SITE the same bare candidate is tsc's
                    // `instantiateTypeWithSingleGenericCallSignature`, not
                    // noise, whenever the call RETURNS a single non-generic
                    // signature (`InferCtx.ho_result_fn`). The argument is a
                    // generic function handed a contextual signature whose
                    // parameter IS one of the variables being solved:
                    // `compose<A, B, C>(f: (a: A) => B, g: (b: B) => C)` fed
                    // `compose(list, box)`.
                    //
                    // Two answers, and which one applies is decided by whether
                    // the outer variable already has a candidate — tsc's
                    // `hasOverlappingInferences` / `mergeInferences` pair, read
                    // one slot at a time:
                    //
                    //   * ALREADY DETERMINED — substitute what this call has
                    //     already inferred, which is `instantiateSignatureIn
                    //     ContextOf` reading the contextual type through
                    //     `context.nonFixingMapper`. `box`'s `V` takes `B`'s
                    //     `T'[]`, so its return contributes `Box<T'[]>` instead
                    //     of the `Box<unknown>` the erasure gives.
                    //   * STILL FREE — mint a UNIQUE type parameter (tsc's
                    //     `getUniqueTypeParameters`) and record it as the outer
                    //     variable's candidate. `list`'s `T` becomes `T'`, `A`
                    //     takes `T'`, and the parameter walk below then reads
                    //     `B := T'[]` off the instantiated `(a: T') => T'[]`.
                    //     `generalizeCallResult` re-attaches `T'` to the
                    //     returned signature, so `compose(list, box)` is
                    //     `<T'>(a: T') => Box<T'[]>` — assignable to the
                    //     `<T>(x: T) => Box<T[]>` the annotation asks for,
                    //     where the erasing answer was not.
                    //
                    // The erasure still stands wherever this does not apply: a
                    // call whose result is not a signature has nowhere to carry
                    // a minted parameter, and `map([1, 2, 3], identity)` — whose
                    // `T` is already `number` by the time `identity` is read —
                    // takes the first branch, not the mint.
                    //
                    // A REST-TUPLE contextual parameter mints but does NOT
                    // adopt. tsc pairs positions through `getTypeAtPosition`,
                    // which reads a rest parameter's ELEMENT; this arm pairs
                    // `fnParam(param, i).ty` raw, so `pipe<A extends any[], B>(
                    // ab: (...args: A) => B)` hands `list`'s `T` the whole
                    // TUPLE variable `A` as its candidate. Recording `A := T'`
                    // would bind a rest-tuple parameter to a scalar and every
                    // `pipe` overload would stop resolving.
                    //
                    // The MINT is still right, and it is the whole of what tsc
                    // does here: `getUniqueTypeParameters` renames `list`'s `T`
                    // to `T'` unconditionally, and the ensuing walk infers the
                    // call's own variables from the INSTANTIATED signature
                    // `(a: T') => T'[]`. That walk already reads a rest pattern
                    // through `getRestTypeAtPosition` (the `pat_has_rest` block
                    // below), so it answers `A := [T']`, `B := T'[]` — where
                    // erasing `T` to its `unknown` fallback answered `A :=
                    // [unknown]` and `pipe(list)` printed `(...args: [unknown])
                    // => unknown[]` instead of `<T>(x: T) => T[]`.
                    //
                    // Nothing of THIS call's own inference was substituted into
                    // `ra`, so there is no fix set to arm either: a minted
                    // parameter is not our guess coming home.
                    const pcount0 = s.fnParamCount(param);
                    const param_rest = pcount0 != 0 and s.fnParam(param, pcount0 - 1).rest();
                    if (self_ref and c.infer_ctx.sig_ctx == 0 and
                        c.ts.kind(cand0) == .type_param and
                        s.fnTypeParamCount(param) == 0)
                    {
                        if (tpIndex(tp_syms, c.ts.typeParamSymbol(cand0))) |oi| {
                            // The SUBSTITUTING half is not gated on
                            // `ho_result_fn`. tsc reaches
                            // `instantiateSignatureInContextOf(signature,
                            // contextualSignature, context)` for EVERY generic
                            // argument under a non-generic contextual signature
                            // — the single-non-generic-return test only decides
                            // between merging a separate inference set and this
                            // fallback, and the fallback's mapper is the FIXING
                            // one, which is exactly "hand the argument what we
                            // have already inferred". `_.all<T>(list: T[],
                            // iterator?: Iterator<T, boolean>)` fed
                            // `_.all([], _.identity)` needs it: with `T` already
                            // `never` from the empty array, `identity`
                            // instantiates to `(value: never) => never` and `T`
                            // stays `never`. Erased instead, it presented
                            // `(value: unknown) => unknown`, whose CONTRAVARIANT
                            // `unknown` then outranked the covariant `never`
                            // (`genericTypeArgumentInference1`).
                            if (!param_rest and candidates[oi] != types.no_type) {
                                try ho_fix.arm(c, param, tp_syms, candidates);
                                all_unbound = false;
                                try map_list.append(c.scratch(), .{
                                    .sym = sym,
                                    .ty = try fixedInference(c, tp_syms[oi], candidates[oi]),
                                });
                                continue;
                            }
                            if (c.infer_ctx.ho_result_fn) if (c.infer_ctx.ho_minted) |list| {
                                if (!param_rest) try ho_fix.arm(c, param, tp_syms, candidates);
                                const ft = try s.makeTypeParam(try uniqueTypeParam(c, sym, list));
                                if (!param_rest) {
                                    candidates[oi] = ft;
                                    // The slot this instantiation DETERMINED is
                                    // not fixed — it is the answer, and
                                    // restoring it would undo the adoption.
                                    ho_fix.release(oi);
                                }
                                all_unbound = false;
                                try map_list.append(c.scratch(), .{ .sym = sym, .ty = ft });
                                continue;
                            };
                        }
                    }
                    // The same adoption for an own parameter the contextual
                    // signature said NOTHING about. tsc mints unique parameters
                    // for ALL of a generic argument's own parameters, not only
                    // the ones a variable of this call happened to pair with,
                    // and infers from the whole instantiated signature —
                    // `compose(unbox, unlist)` with `unbox<W>(x: Box<W>): W`
                    // has nothing to pair `W` with (`Box<W>` against the bare
                    // `A` yields no candidate), yet the answer tsc reaches is
                    // `A := Box<W'>`, `B := W'`, which is what makes the result
                    // relate to `<T>(x: Box<T[]>) => T`. Erasing `W` to
                    // `unknown` instead leaves `A := Box<unknown>`.
                    //
                    // No slot to release from the fix set here: the minted
                    // parameter is the one thing the walk below legitimately
                    // teaches this call.
                    if (cand0 == types.no_type and c.infer_ctx.sig_ctx == 0 and
                        c.infer_ctx.ho_result_fn and s.fnTypeParamCount(param) == 0)
                    {
                        if (c.infer_ctx.ho_minted) |list| {
                            const ft = try s.makeTypeParam(try uniqueTypeParam(c, sym, list));
                            all_unbound = false;
                            try map_list.append(c.scratch(), .{ .sym = sym, .ty = ft });
                            continue;
                        }
                    }
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
            // tsc's `inferFromSignature` head, which runs BEFORE the
            // parameters: a `this` type on both sides infers CONTRAVARIANTLY,
            // exactly as an ordinary parameter does
            // (`inferFromContravariantTypes(sourceThisType, targetThisType)`).
            //
            // This is what makes `strictBindCallApply` resolve. The lib's
            // `CallableFunction.call<T, A extends any[], R>(this: (this: T,
            // ...args: A) => R, thisArg: T, ...args: A): R` takes `T` from the
            // RECEIVER's own `this` type, and `thisArg: T` supplies a
            // competing COVARIANT candidate from the actual argument. tsc
            // prefers the contravariant one unless the covariant one is a
            // subtype of it, so `c.foo.call(undefined, 10, "hello")` keeps
            // `T = C` and reports the bad `undefined` argument — where a
            // covariant-only walk inferred `T = undefined` and reported a
            // TS2684 on the receiver that tsc never emits.
            {
                const p_this = s.fnThisType(param);
                const a_this = s.fnThisType(ra);
                if (p_this != 0 and a_this != 0) {
                    c.infer_ctx.contra_pos += 1;
                    defer c.infer_ctx.contra_pos -= 1;
                    try c.unify(p_this, a_this, tp_syms, candidates, depth + 1);
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
            // …and a trailing rest in the SOURCE whose type is a FIXED tuple is
            // not a rest at all as far as position pairing goes: tsc's
            // `getParameterCount` counts it as that tuple's arity and
            // `getTypeAtPosition` hands out its ELEMENTS one at a time
            // (`getEffectiveRestType` answers `undefined` for it).
            //
            // A combinator's own result is exactly that shape. `pipe(box)` is
            // `(...args: [V]) => { value: V }`, and pairing the pattern's `b: B`
            // against the raw rest type gave `B := [V]` — a one-element TUPLE
            // where the answer is `V` — so `pipe(list, pipe(box))` then rejected
            // its FIRST argument against `(...args: [T]) => [V]`.
            const src_rest_tuple = try restTupleOf(c, ra);
            const n = @min(paramPositions(c, ra, src_rest_tuple), pat_fixed);
            {
                // Parameters are a contravariant position — unless the
                // signature was written as a METHOD, whose parameters tsc
                // relates bivariantly and infers from covariantly.
                const bivariant = s.fnFlags(param) & types.fn_flag_method != 0;
                if (!bivariant) c.infer_ctx.contra_pos += 1;
                defer if (!bivariant) {
                    c.infer_ctx.contra_pos -= 1;
                };
                for (0..n) |i| {
                    const at = paramTypeAt(c, ra, src_rest_tuple, @intCast(i));
                    try c.unify(s.fnParam(param, @intCast(i)).ty, at, tp_syms, candidates, depth + 1);
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
            //
            // A branch that is a NAKED inference variable is inferred LAST and
            // at lower priority — tsc's `inferToMultipleTypes`, reached
            // through `inferToConditionalType`: "inferences directly to naked
            // type variables are given lower priority as they are less
            // specific". Any candidate an ordinary position supplies
            // therefore REPLACES what the branch offers.
            //
            // react-query's `placeholderData?: NonFunctionGuard<TQueryData> |
            // PlaceholderDataFunction<NonFunctionGuard<TQueryData>>` is the
            // shape that needs it: `NonFunctionGuard<T> = T extends Function ?
            // never : T`, so every candidate that property can offer reaches
            // the query's data type only through the false branch. At full
            // priority the erased `unknown` it yields outranked nothing and
            // was folded into the real data type `queryFn` supplies, so
            // `useQuery({queryKey, queryFn, placeholderData: keepPreviousData})`
            // came back `unknown` and every read off `data` was a TS2339.
            const t_naked = isNakedInferVar(c, s.condTrue(param), tp_syms);
            const f_naked = isNakedInferVar(c, s.condFalse(param), tp_syms);
            if (!t_naked) try c.unify(s.condTrue(param), arg, tp_syms, candidates, depth + 1);
            if (!f_naked) try c.unify(s.condFalse(param), arg, tp_syms, candidates, depth + 1);
            if (t_naked or f_naked) {
                c.infer_ctx.rev_prio += 1;
                defer c.infer_ctx.rev_prio -= 1;
                if (t_naked) try c.unify(s.condTrue(param), arg, tp_syms, candidates, depth + 1);
                if (f_naked) try c.unify(s.condFalse(param), arg, tp_syms, candidates, depth + 1);
            }
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
        .keyof_op => try inferToKeyof(c, param, arg, tp_syms, candidates),
        else => {},
    }
}

/// What tsc's `context.mapper` answers for a type parameter that already has a
/// candidate: `getInferredType`, whose covariant half WIDENS a fresh literal
/// unless the parameter has a primitive constraint or occurs at the top level of
/// the signature's return type (`getCovariantInference`'s three-way choice, the
/// same test the resolution loop runs at the end of `inferTypeArgs`).
///
/// Handing the RAW candidate over instead is what made `bar<T, U, V>(x: T, y: U,
/// cb: (x: T, y: U) => V)` fed `bar(1, "one", h)` instantiate its generic
/// argument against `(x: 1, y: "one") => …` — so `V` came back `1[] | "one"[]`
/// where tsc answers `number[] | string[]` (`contextualSignatureInstantiation`).
fn fixedInference(c: *Checker, tp: u32, cand: TypeId) Error!TypeId {
    if (!c.ts.isFreshLiteral(cand) and c.ts.kind(cand) != .union_type) return cand;
    if (c.isConstTypeParamSym(tp)) return cand;
    if (try c.constraintIsPrimitive(try c.typeParamConstraint(tp))) return cand;
    const sr = c.infer_ctx.sig_ret;
    if (sr != types.no_type and try c.typeParamAtTopLevel(sr, tp)) return cand;
    return c.widenLiteral(cand);
}

/// The FIXED tuple a signature's trailing rest parameter is spelled with, if it
/// is one — tsc's `getEffectiveRestType` answering `undefined`, read from the
/// other side: `(...args: [T, U])` declares two ordinary positions, and only a
/// rest element (`[T, ...U[]]`) or a non-tuple rest type is a rest for
/// position-pairing purposes. Null for every signature with no rest parameter,
/// which is the overwhelming majority — the resolve only runs past that check.
fn restTupleOf(c: *Checker, sig: TypeId) Error!?TypeId {
    const s = &c.ts;
    const n = s.fnParamCount(sig);
    if (n == 0 or !s.fnParam(sig, n - 1).rest()) return null;
    const rt = try c.resolveStructural(s.fnParam(sig, n - 1).ty);
    if (s.kind(rt) != .tuple) return null;
    var i: u32 = 0;
    while (i < s.tupleLen(rt)) : (i += 1) {
        const e = s.tupleElem(rt, i);
        if (e.flags & (types.elem_flag_rest | types.elem_flag_optional) != 0) return null;
    }
    return rt;
}

/// How many positions a signature offers once `restTupleOf` has been read —
/// tsc's `getParameterCount`.
fn paramPositions(c: *Checker, sig: TypeId, rest_tuple: ?TypeId) u32 {
    const n = c.ts.fnParamCount(sig);
    return if (rest_tuple) |t| n - 1 + c.ts.tupleLen(t) else n;
}

/// tsc's `getTypeAtPosition`, restricted to what `restTupleOf` recognises:
/// positions past the last declared parameter read the rest tuple's elements.
fn paramTypeAt(c: *Checker, sig: TypeId, rest_tuple: ?TypeId, i: u32) TypeId {
    const n = c.ts.fnParamCount(sig);
    const t = rest_tuple orelse return c.ts.fnParam(sig, i).ty;
    if (i + 1 < n) return c.ts.fnParam(sig, i).ty;
    return c.ts.tupleElem(t, i - (n - 1)).ty;
}

/// tsc's `inferFromTypes` literal-keyof arm:
///
/// ```ts
/// else if ((isLiteralType(source) || source.flags & TypeFlags.String) && target.flags & TypeFlags.Index) {
///     const empty = createEmptyObjectTypeFromStringLiteral(source);
///     inferWithPriority(empty, (target as IndexType).type, InferencePriority.LiteralKeyof);
/// }
/// ```
///
/// A `keyof T` PATTERN met by a literal argument says nothing about `T`'s
/// shape except that the literal names one of its keys — so tsc SYNTHESIZES
/// the smallest object that would have that key (`{ a: any }`) and offers it
/// as evidence. Without it, `bar<T>(x: keyof T, y: keyof T): T` called as
/// `bar('a', 'b')` recorded nothing at all, `T` fell back to `unknown`, and
/// `keyof unknown` — `never` — rejected both arguments (TS2345 where tsc is
/// clean; `keyofInferenceIntersectsResults`).
///
/// The candidates go to the `LiteralKeyof` set, not to `candidates`: see
/// `InferCtx.keyof_contra` for the two rules (intersect, lowest priority)
/// that set exists to carry.
fn inferToKeyof(c: *Checker, param: TypeId, arg: TypeId, tp_syms: []const u32, candidates: []TypeId) Error!void {
    const s = &c.ts;
    // Only a BARE inference variable under the `keyof`. `keyof T[K]` and
    // friends have no key set to hand the synthesized object to, and tsc's
    // recursion into `inferFromTypes` would find no inference position
    // either.
    const operand = s.keyofOperand(param);
    if (s.kind(operand) != .type_param) return;
    const i = tpIndex(tp_syms, s.typeParamSymbol(operand)) orelse return;
    const slot = keyofContraSlot(c, candidates, i) orelse return;
    const empty = try emptyObjectFromLiteralKeys(c, arg) orelse return;
    slot.* = if (slot.* == types.no_type)
        empty
    else
        try s.makeIntersection(c.scratch(), &.{ slot.*, empty });
}

/// The `LiteralKeyof` candidate slot for type parameter `i`, when
/// `candidates` is the accumulator the in-flight call registered (the same
/// ownership rule as `contraSlot`, minus its parameter-position test — tsc
/// files this candidate from wherever the `keyof` pattern sits).
fn keyofContraSlot(c: *Checker, candidates: []TypeId, i: usize) ?*TypeId {
    const ctx = &c.infer_ctx;
    if (ctx.owner != candidates.ptr) return null;
    if (ctx.keyof_contra.len != candidates.len) return null;
    return &ctx.keyof_contra[i];
}

/// tsc's `createEmptyObjectTypeFromStringLiteral`: an anonymous object with
/// one `any` property per STRING-LITERAL constituent of `t`, plus a
/// `[x: string]: {}` index when `t` is `string` itself. Returns null when `t`
/// is not a literal type at all — a non-unit source says nothing about the
/// key set and tsc's guard (`isLiteralType(source) || source.flags & String`)
/// skips the arm entirely.
///
/// A unit source with no string literal in it still produces `{}` (tsc builds
/// the table by filtering for `StringLiteral` after the guard passed), which
/// is why `num<T>(x: keyof T)` fed `1` answers `T = {}` and then rejects the
/// argument against `keyof {}` — `never`.
fn emptyObjectFromLiteralKeys(c: *Checker, t0: TypeId) Error!?TypeId {
    const s = &c.ts;
    const t = try c.resolveStructural(t0);
    if (s.kind(t) == .string) {
        const empty = try s.makeObject(&.{}, types.no_type, types.no_type, 0);
        return try s.makeObject(&.{}, empty, types.no_type, 0);
    }
    if (!isUnitLikeUnion(c, t)) return null;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    switch (s.kind(t)) {
        .string_literal => try props.append(c.scratch(), .{ .name = s.literalAtom(t), .ty = types.any_type }),
        .union_type => for (try c.memberList(t)) |m| {
            if (s.kind(m) != .string_literal) continue;
            const name = s.literalAtom(m);
            for (props.items) |p| {
                if (p.name == name) break;
            } else try props.append(c.scratch(), .{ .name = name, .ty = types.any_type });
        },
        else => {},
    }
    return try s.makeObject(props.items, types.no_type, types.no_type, 0);
}

/// tsc's `isLiteralType`: a unit type, or a union whose every constituent is
/// one. (`boolean` counts in tsc because it IS the `true | false` union.)
fn isUnitLikeUnion(c: *Checker, t: TypeId) bool {
    const s = &c.ts;
    if (s.kind(t) == .union_type) {
        for (c.memberList(t) catch return false) |m| {
            if (!isUnitLikeKind(s.kind(m))) return false;
        }
        return true;
    }
    return isUnitLikeKind(s.kind(t));
}

/// tsc's `getUnmatchedProperty(source, target, /*requireOptionalProperties*/
/// false, match_discriminants)` reduced to a yes/no: does `target` declare a
/// REQUIRED property that `source` either lacks outright or — only when
/// `match_discriminants` — carries at a *different* unit value?
///
/// Optional properties on either side are skipped: an absent optional cannot
/// prove two shapes apart. `any` on the source side always matches, since it
/// is compatible with every discriminant value.
fn hasUnmatchedProp(c: *Checker, source: TypeId, target: TypeId, match_discriminants: bool) Error!bool {
    const s = &c.ts;
    for (0..s.objectPropCount(target)) |i| {
        const tp = s.objectProp(target, @intCast(i));
        if (tp.optional()) continue;
        const sp = s.objectPropByName(source, tp.name) orelse return true;
        if (!match_discriminants) continue;
        // Only a SINGLE unit literal is a discriminant. `'a' | 'c'`,
        // `boolean` and `string` are not (tsc tests `TypeFlags.Unit`, which
        // a union never carries), so a target property typed that way can
        // never make the two shapes "definitely unrelated".
        if (!isUnitLikeKind(s.kind(tp.ty))) continue;
        if (s.kind(sp.ty) == .any) continue;
        if ((try s.regularLiteral(sp.ty)) != (try s.regularLiteral(tp.ty))) return true;
    }
    return false;
}

/// tsc's `typesDefinitelyUnrelated`: two object types that EACH have a
/// required property unmatched in the other cannot possibly be related, and
/// `inferFromObjectTypes` skips property/signature/index inference between
/// them entirely.
///
/// This is what stops a discriminated union's non-selected constituents from
/// contributing candidates — but note that it is not a discriminant filter,
/// and the difference is exactly what the union arm's oracle matrix records:
/// with `src: {kind:'b', p:string, q:number}`,
///
///   `{kind:'a', p:T}`            is unrelated (`kind` differs AND `q` is
///                                 missing from the target) — no candidate;
///   `{kind:'a', p:T, q:number}`  is NOT unrelated (`kind` differs, but the
///                                 target covers every source property) —
///                                 it contributes `T = string` even though
///                                 the argument can never satisfy it.
///
/// So the asymmetry that made rows 1-2 of that matrix look order-independent
/// while row 3 took the leftmost is a *property coverage* test, not a
/// discriminant one. Both directions are required; the discriminant
/// comparison runs only in the source→target direction, matching tsc's
/// argument order.
fn typesDefinitelyUnrelated(c: *Checker, source: TypeId, target: TypeId) Error!bool {
    return (try hasUnmatchedProp(c, source, target, true)) and
        (try hasUnmatchedProp(c, target, source, false));
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
///
/// `mode` says which of `param`'s properties count as discriminants — see
/// `DiscMode`; the two call sites drive the choice from opposite sides of the
/// pair and need different answers.
pub fn discriminatedConstituent(c: *Checker, param: TypeId, uni: TypeId, mode: DiscMode) Error!?TypeId {
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
            const ap = s.objectPropByName(rm, pp.name) orelse {
                if (mode == .unit_on_source) {
                    saw_disc = true;
                    agrees = false;
                    break;
                }
                continue;
            };
            if (mode == .unit_on_both and !isUnitLikeKind(s.kind(ap.ty))) continue;
            saw_disc = true;
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

/// Which properties count as a DISCRIMINANT for `discriminatedConstituent`.
pub const DiscMode = enum {
    /// A unit-literal property of the driving object, whatever the
    /// constituent's own property is. The union-ARGUMENT arm's contract: the
    /// driver is the PARAMETER, whose literal-typed properties are written by
    /// the declaration and so are discriminants by construction.
    unit_on_source,
    /// A property that is a unit literal on BOTH sides. The union-PARAMETER
    /// arm's contract: there the driver is the ARGUMENT, and an object literal
    /// is full of incidental fresh literals that discriminate nothing.
    /// React's `setState({ b: 1, c: true })` against `Pick<SS, K> | SS | null`
    /// is the case — `b` and `c` are unit in the argument and `number` /
    /// `boolean` in `SS`, and reading them as discriminants selected `SS` and
    /// starved `Pick<SS, K>` of the key set (conformance `inference/046`).
    unit_on_both,
};

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
    // A CLASS VALUE (`typeof C`) argument against a constituent that carries a
    // CONSTRUCT signature. `.class_value` is a nominal shortcut with no
    // structure of its own, so the kind test below can never match it — yet a
    // construct-signature constituent is precisely the part of an intersection
    // a class value answers, and the `.object` arm of `unify` already infers
    // through it when the parameter is that object on its own (`this: { new ():
    // M }` binds `M` from the receiver).
    //
    // sequelize's `ModelStatic<M> = NonConstructor<typeof Model> & { new (): M
    // }` is written as an intersection, and it is a `this` parameter — so with
    // no pair, `M` took no candidate at all and fell back to its `Model`
    // constraint: every `User.findOne()` / `.findAll()` result was a bare
    // `Model`, and every property read off one a TS2339 (12.5 K of them on
    // outline, unmasked the moment the map over the static side stopped
    // collapsing to `{}` — see `materializeMapped`'s `.class_value` arm).
    //
    // `inferFromExtends`' `.object` arm bridges the same nominal/structural gap
    // for a conditional's construct-signature pattern (`InstanceType<T>`).
    if (pk == .object and s.kind(ra) == .class_value and s.objectConstructSigCount(rp) > 0) return true;
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
                    c.infer_ctx.rev_prio += 1;
                    defer c.infer_ctx.rev_prio -= 1;
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
    // HANDOFF (wave 31 B, built and measured, REVERTED on the app gate). Three
    // changes turn this into tsc's `inferToMappedType` + `createReverseMappedType`
    // and are worth +3 exact on the corpus (`reverseMappedTupleContext`,
    // `objectFromEntries`, `reverseMappedTypeLimitedConstraint`), zero corpus
    // regressions — but EACH of them, alone or together, moves social-app:
    //
    //   1. a COMPOSITE key set. tsc walks a union/intersection constraint
    //      constituent by constituent (`result ||= inferToMappedType(source,
    //      target, type)`) and takes the homomorphic path for any `keyof T` it
    //      finds, so `{ [K in keyof T & keyof CompilerOptions]: … }` infers `T`.
    //      The walk must descend BOTH connectives to any depth — ztsc's
    //      intersection normalizer distributes over a union, storing that
    //      constraint as `("allowUnreachableCode" & keyof T) | …`. Split this
    //      function so the source is a parameter and call it with the operand.
    //   2. `substElemAccess` needs a `.mapped` arm (rebuild constraint / value /
    //      `as` / source), or a mapped type NESTED in the template keeps its
    //      `S[K]` and the element variable never enters the template at all.
    //   3. the rebuild must cover ARRAY and TUPLE sources, not just `.object`
    //      ("for arrays and tuples we infer new arrays and tuples where the
    //      reverse mapping has been applied to the element type(s)") — which is
    //      what a nested map resolves to once (2) puts the element variable in
    //      its source.
    //
    // MEASURED on social-app at the committed baseline (87 check errors):
    //   * 1+2+3 -> 93: six fresh FPs in Composer.tsx (a react-query
    //     `QueryBehavior<{…}>` vs `QueryBehavior<unknown>` variance failure plus
    //     five `Property … does not exist on type '{}'`).
    //   * 1 alone -> 98: eleven fresh FPs in ageAssurance/data.tsx instead.
    //   * 2+3 without 1 -> 193. (2) is destructive without (3) to complete the
    //     inversion; they are one change, not two.
    // So (3) does not merely add — it also MASKS what (1) breaks. tsc's guard
    // that ztsc does not have is `isPartiallyInferableType` /
    // `getIndexInfoOfType(source, stringType)` at the head of
    // `createReverseMappedType`; the next attempt should start there, and
    // should treat social-app's `useInfiniteQuery` options object as the
    // witness rather than the corpus.
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
    c.infer_writes +%= 1;
    // A reverse-mapped object found in a PARAMETER position is
    // contravariant evidence, exactly like the `.type_param` arm's
    // candidate. Writing it into the covariant accumulator let a callback
    // parameter's rebuilt shape displace the type the call actually
    // produces — `calculate(prev, next, postProcess)` took the erased
    // `{ tag: string }` from `postProcess`'s `Partial<T>` over the `S` its
    // first two arguments supply.
    if (c.contraSlot(candidates, idx)) |slot| {
        slot.* = if (slot.* == types.no_type) obj else try c.combineContravariant(slot.*, obj);
        try c.noteContraCandidate(candidates, idx, obj);
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
    c.infer_writes +%= 1;
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

/// tsc's `InferenceInfo.isFixed`, scoped to one argument: the inference state
/// of the slots a contextual signature's PARAMETERS mention, snapshotted before
/// `unify`'s `.function` arm instantiates the argument's signature with this
/// call's own answers and restored after it walks the result. See the comment
/// at the `.function` arm for why.
///
/// `arm` is idempotent (the second firing within one argument keeps the first
/// snapshot) and `restore` is a no-op until it has run, so an argument that
/// never reaches the instantiation is untouched.
///
/// Only the covariant candidate and its contravariant twin are restored. The
/// `contra_sup` union and the `top_level` flags are NOT: restoring those too
/// was measured and is strictly worse (`contextualSignatureInstantiation`'s
/// `bar`/`baz` family went from four keys to thirteen) — the walk's own
/// top-level bookkeeping is legitimate even when its candidate is an echo.
const FixedSlots = struct {
    mask: []bool = &.{},
    cand: []TypeId = &.{},
    contra: []TypeId = &.{},

    fn arm(f: *FixedSlots, c: *Checker, param: TypeId, tp_syms: []const u32, candidates: []TypeId) Error!void {
        if (f.mask.len != 0) return;
        const mask = try c.scratch().alloc(bool, tp_syms.len);
        for (mask) |*x| x.* = false;
        var pi: u32 = 0;
        while (pi < c.ts.fnParamCount(param)) : (pi += 1) {
            try markMentionedTps(c, c.ts.fnParam(param, pi).ty, tp_syms, mask, 0);
        }
        f.cand = try c.scratch().alloc(TypeId, tp_syms.len);
        f.contra = try c.scratch().alloc(TypeId, tp_syms.len);
        const owns = c.infer_ctx.owner == candidates.ptr;
        for (0..tp_syms.len) |i| {
            f.cand[i] = candidates[i];
            f.contra[i] = if (owns) c.infer_ctx.contra[i] else types.no_type;
        }
        f.mask = mask;
    }

    /// This slot is the instantiation's ANSWER, not one of its echoes.
    fn release(f: *FixedSlots, i: usize) void {
        if (i < f.mask.len) f.mask[i] = false;
    }

    fn restore(f: *const FixedSlots, c: *Checker, candidates: []TypeId) void {
        const owns = c.infer_ctx.owner == candidates.ptr;
        for (f.mask, 0..) |m, i| {
            if (!m) continue;
            candidates[i] = f.cand[i];
            if (!owns) continue;
            c.infer_ctx.contra[i] = f.contra[i];
        }
    }
};

/// tsc's `getUniqueTypeParameters`: which type parameter this call ADOPTS for a
/// generic function argument's own parameter `src`, appending it to `adopted`
/// (tsc's `InferenceContext.inferredTypeParameters`) the first time.
///
/// ```ts
/// const name = tp.symbol.escapedName;
/// if (hasTypeParameterByName(context.inferredTypeParameters, name) || hasTypeParameterByName(result, name)) {
///     … create a renamed clone …
/// } else {
///     result.push(tp);
/// }
/// ```
///
/// ztsc departs from tsc's `else` branch and ALWAYS clones. tsc can reuse the
/// argument's own parameter because it instantiates a generic method's
/// parameters with fresh clones whenever the declaring type is instantiated
/// (`createCanonicalSignature`); ztsc keys a type parameter by its DECLARATION
/// symbol and does not clone, so reusing `list`'s own `T` as the answer for
/// `A` makes the source and the target of the ensuing relation name ONE symbol
/// — `instantiateSigInContextOf`'s occurs check then declines the pair and
/// `<T>(x: T) => T` stopped relating to `(a: T) => T` (`genericFunctionInference1`,
/// `pipe2(foo, foo)`, measured at +14 keys).
///
/// The clone must nevertheless be STABLE. One call's inference runs more than
/// once (the return-context seed, the post-argument fill, an overload retry),
/// and a fresh clone per run would leave the seed's answer and the committed one
/// naming two different parameters: `compose(a => list(a), b => box(b))` then
/// typed its second callback against the first run's clone and reported `T[]`
/// not assignable to `T[]`. So an already-adopted clone is recognised by its
/// ORIGIN and reused.
fn uniqueTypeParam(c: *Checker, src: u32, adopted: *std.ArrayList(u32)) Error!u32 {
    const origin = c.tpOrigin(src);
    for (adopted.items) |m| {
        if (c.tpOrigin(m) == origin) return m;
    }
    const use = try mintUniqueTypeParam(c, src);
    try adopted.append(c.scratch(), use);
    return use;
}

/// A clone of a generic argument's own type parameter. Carries the source's
/// name — it is what the result prints — and its (renamed) constraint; the
/// default is dropped, exactly as the instantiated signature tsc builds has no
/// type arguments to default.
fn mintUniqueTypeParam(c: *Checker, src: u32) Error!u32 {
    const id = c.fresh_tp_next;
    c.fresh_tp_next += 1;
    // The bound is RENAMED onto the clone. `foo<T extends { value: T }>` is
    // self-referential, and a clone carrying the bound verbatim is constrained
    // by the ORIGINAL `T` — a parameter nothing in the instantiated signature
    // binds, so every argument fails it.
    const con0 = try c.typeParamConstraint(src);
    try c.fresh_tp_info.append(c.cm(), .{
        .name = c.symNameAtom(src),
        .constraint = con0,
        .default = types.no_type,
        .has_default = false,
        // The declaration this clone stands in for (`FreshTp.orig`). Without
        // it every mint would answer `tpOrigin == 0`, and `sameSigTypeParams`
        // would read two UNRELATED minted signatures as two instantiations of
        // one declaration and erase the pair to `any`.
        .orig = c.tpOrigin(src),
    });
    if (con0 != types.no_type) {
        const ren = [1]TpMap{.{ .sym = src, .ty = try c.ts.makeTypeParam(id) }};
        c.fresh_tp_info.items[id - c.fresh_tp_base].constraint = try c.instantiate(con0, &ren);
    }
    return id;
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
            return s.makeTupleLike(t, elems.items);
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
                c.infer_writes +%= 1;
                // `any` is evidence like any other, so it obeys the same
                // co-/contra-variant split `unify`'s `.type_param` arm does.
                // tsc records every candidate through the one `contravariant
                // && !bivariant ? contraCandidates : candidates` test in
                // `inferFromTypes` — there is no `any` fast path there at
                // all. Writing it to the covariant set from a PARAMETER
                // position lets a plain `(instance: T | null) => void`
                // pattern handed a `(node: any) => void` argument pin `T` to
                // `any` outright, where tsc keeps `any` as a contravariant
                // candidate and `getInferredType` then prefers the covariant
                // answer because it is a subtype of it. Only a METHOD
                // pattern — React's bivariance-hacked `RefCallback<T>` —
                // infers its parameters covariantly, and there `contraSlot`
                // declines and `any` wins the covariant fold.
                if (c.contraSlot(candidates, i)) |slot| {
                    slot.* = if (slot.* == types.no_type)
                        types.any_type
                    else
                        try c.combineContravariant(slot.*, types.any_type);
                    try c.noteContraCandidate(candidates, i, types.any_type);
                    return;
                }
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
