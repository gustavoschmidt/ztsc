//! Conditional types + `infer`, mapped types, template-literal types + string intrinsics.
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

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Bind = binder.Bind;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;
const Store = types.Store;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const check = checker_zig.check;
const max_instantiation_depth = checker_zig.max_instantiation_depth;
const max_instantiation_count = checker_zig.max_instantiation_count;

const TpMap = @import("enums.zig").TpMap;
const atom = Checker.atom;
const containsFreeTypeParam = @import("enums.zig").containsFreeTypeParam;
const containsTypeParam = @import("enums.zig").containsTypeParam;
const EnumMemberCollect = @import("enums.zig").EnumMemberCollect;
const instantiateId = @import("enums.zig").instantiateId;
const keyofType = @import("typenode.zig").keyofType;
const nodeKey = Checker.nodeKey;
const propOfTypeEx = @import("props.zig").propOfTypeEx;
const resolveStructural = @import("instantiate.zig").resolveStructural;

// =====================================================================
// conditional types + `infer`
// =====================================================================

pub fn mapWith(c: *Checker, map: []const TpMap, sym: SymbolId, ty: TypeId) Error![]TpMap {
    var list: std.ArrayList(TpMap) = .empty;
    var found = false;
    for (map) |m| {
        if (m.sym == sym) {
            try list.append(c.scratch(), .{ .sym = sym, .ty = ty });
            found = true;
        } else try list.append(c.scratch(), m);
    }
    if (!found) try list.append(c.scratch(), .{ .sym = sym, .ty = ty });
    return list.items;
}

/// Dense, stable id for an `infer V` binder in conditional `cond`
/// (a nodeKey). Same (conditional, name) → same id.
pub fn inferVarId(c: *Checker, cond: u64, name: Atom) Error!u32 {
    const gop = try c.infer_ids.getOrPut(c.cm(), .{ .cond = cond, .name = name });
    if (!gop.found_existing) {
        gop.value_ptr.* = c.infer_next;
        c.infer_next += 1;
    }
    return gop.value_ptr.*;
}

pub fn inferVarFromNode(c: *Checker, node: Node) Error!TypeId {
    const name = try c.atomOfToken(c.tree.nodeData(node).lhs);
    if (c.infer_scopes.items.len == 0) {
        try c.diagFmt(1338, c.nodeSpan(node), "'infer' declarations are only permitted in the 'extends' clause of a conditional type.", .{});
        return types.any_type;
    }
    // An `infer V` binder belongs to the immediately-enclosing conditional
    // (top of the scope stack) — its extends clause is where it is declared.
    const id = try c.inferVarId(c.infer_scopes.items[c.infer_scopes.items.len - 1], name);
    // TS 4.8 `infer V extends C`. Recorded rather than baked into the type —
    // the binder's identity is (conditional, name) and a two-word `infer_var`
    // has no room for a third payload — and consumed by
    // `conditionalTypeFromNode`, which turns it into an ordinary conditional.
    const cn = c.tree.nodeData(node).rhs;
    if (cn != null_node) {
        const ct = try c.typeFromTypeNode(cn);
        try c.infer_constraints.put(c.cm(), id, .{ .ty = ct, .name = name });
    }
    return c.ts.makeInferVar(id, name, false);
}

pub fn conditionalTypeFromNode(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const e = c.tree.extraData(ast.ConditionalType, d.rhs);
    const chk = try c.typeFromTypeNode(d.lhs);
    // The extends + true branches share this conditional's infer scope; the
    // false branch does not (infer binders are scoped to the true branch).
    // Push onto the scope stack (rather than overwrite) so a nested
    // conditional inside the true branch still resolves this conditional's
    // infer vars — the check clause above was already evaluated under the
    // enclosing scopes only.
    try c.infer_scopes.append(c.cm(), c.nodeKey(node));
    const extends_ty = try c.typeFromTypeNode(e.extends_type);
    // The true branch is read under tsc's substitution-type narrowing (the
    // check type is a subtype of `extends` there); ztsc models none, so the
    // "can this key index that object" check stays quiet inside it — see
    // `Checker.cond_true_depth`.
    c.cond_true_depth += 1;
    const true_ty0 = try c.typeFromTypeNode(e.true_type);
    c.cond_true_depth -= 1;
    _ = c.infer_scopes.pop();
    const false_ty = try c.typeFromTypeNode(e.false_type);
    const true_ty = try constrainInferBinders(c, extends_ty, true_ty0, false_ty);
    // Distributivity is a property of a *naked type-parameter* check. A
    // naked `infer` var (e.g. `F extends (...)=>any` inside Awaited, where
    // F is captured by an enclosing conditional) behaves the same way: once
    // F resolves to a union like `fn | undefined | null`, the branches must
    // reflect each member.
    const chk_k = c.ts.kind(chk);
    const distributive = chk_k == .type_param or chk_k == .infer_var;
    return c.reduceConditional(chk, extends_ty, true_ty, false_ty, distributive);
}

/// What a conditional's check/extends pair decides — computed WITHOUT
/// either branch.
///
/// A conditional's branches are two whole type subtrees, and a resolution
/// keeps exactly one of them. Substituting both and then throwing one away
/// is not merely wasted work: the discarded walk still charges the
/// per-statement instantiation budget and still raises TS2589 when it runs
/// past the depth cap, so a branch nobody asked for can be the reason a
/// statement truncates — and a truncated type is what turns into a cascade
/// of TS7006 / TS2554 / TS2769 at the call sites downstream.
/// `conditional/042` is that shape reduced to eight lines.
///
/// tsc never pays it: `getConditionalType` resolves the check first and
/// instantiates only the branch it selects. `planConditional` is that
/// split — the caller substitutes the branch the plan asks for, and
/// nothing else. Measured on immich's kysely query builders (the corpus
/// that motivated it): total node visits 12.36 M → 12.00 M at
/// `--checkers=1`, wall 3.83 s → 3.52 s, and five false positives gone,
/// including a whole repository helper that had collapsed to `any`.
pub const CondPlan = union(enum) {
    /// Fully determined; neither branch is needed.
    value: TypeId,
    /// The true branch, with these `infer` bindings substituted into it.
    take_true: Bindings,
    /// The false branch, verbatim (an `infer` binder is out of scope there).
    take_false,
    /// An `any` check takes BOTH branches (see `planConcreteConditional`).
    both_any: Bindings,
    /// Undecided: the caller materializes both branches and calls
    /// `finishCondPlan`.
    need_both: Rest,

    /// Slices into the caller's scratch, valid until the enclosing
    /// substitution frame unwinds — which is exactly as long as the branch
    /// the caller is about to substitute them into lives.
    pub const Bindings = struct { ids: []const u32, vals: []const TypeId };
    pub const Rest = enum { defer_symbolic, distribute };
};

/// The single evaluation point for a conditional, used at build time and
/// on each instantiation: defer while a check/extends is still generic,
/// otherwise resolve concretely. Distribution over a naked-param union is
/// handled by `instantiateId` (it holds the substitution map needed to
/// re-bind the param per member). Counts against the TS2589 depth/count
/// budget so a self-referential conditional terminates.
///
/// The eager form: both branches are already materialized. A caller that
/// can defer materializing them — every substitution walk — should run
/// `planConditional` and materialize only what the plan names.
pub fn reduceConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
    const plan = try c.planConditional(chk, extends_ty, distributive);
    return c.finishCondPlan(plan, chk, extends_ty, true_ty, false_ty, distributive);
}

/// Apply a plan once both branches exist. `take_true`/`take_false` readers
/// that materialize lazily inline the two cheap arms themselves and only
/// come here for `need_both`.
pub fn finishCondPlan(c: *Checker, plan: CondPlan, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
    const s = &c.ts;
    switch (plan) {
        .value => |v| return v,
        .take_false => return false_ty,
        .take_true => |b| return c.condTrueBranch(b, true_ty),
        .both_any => |b| {
            const t = try c.substInfer(true_ty, b.ids, b.vals);
            return c.makeUnion2(t, false_ty);
        },
        .need_both => |rest| switch (rest) {
            .defer_symbolic => return s.makeConditional(chk, extends_ty, true_ty, false_ty, distributive),
            .distribute => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                const domain = blk2: {
                    const d = try c.condDistributionDomain(chk, extends_ty);
                    break :blk2 if (d == 0) chk else d;
                };
                for (try c.memberList(domain)) |m| {
                    // A distributive conditional's true/false branch may BE
                    // the check type (`T extends U ? never : T` = Exclude,
                    // `? T : never` = Extract). When the naked-type-param
                    // distribution in `instantiateId` was bypassed — because
                    // the instantiated check is not a naked param but a
                    // `keyof X` / indexed access that resolved to this union
                    // (the `Omit`/`Exclude<keyof T, K>` composition) — the
                    // branch was baked to the WHOLE union instead of the
                    // per-member value. Rebind a branch that IS the check to
                    // the current member so `Omit<T, K>` actually strips the
                    // excluded keys. A branch that doesn't reference the
                    // check (e.g. `never`) is untouched, so ordinary
                    // distributions (Awaited) are unchanged.
                    const tru_m = if (true_ty == chk) m else true_ty;
                    const fls_m = if (false_ty == chk) m else false_ty;
                    try parts.append(c.scratch(), try c.reduceConditional(m, extends_ty, tru_m, fls_m, false));
                }
                return s.makeUnion(c.scratch(), parts.items);
            },
        },
    }
}

/// The true branch of a resolved conditional: bind this conditional's own
/// `infer` variables into it, then drive a recursive alias the branch
/// handed back (see `driveShrinkingAlias`).
pub fn condTrueBranch(c: *Checker, b: CondPlan.Bindings, true_ty: TypeId) Error!TypeId {
    const vals = try inferConstraintFallback(c, b, true_ty);
    const tb = try c.substInfer(true_ty, b.ids, vals);
    if (try c.driveShrinkingAlias(tb)) |reduced| return reduced;
    return tb;
}

/// tsc's `getInferredType` constraint fallback. A binder that collected no
/// candidate infers `unknown`; `getInferredType` then measures that against
/// the binder's own constraint and, when it does not satisfy it — `unknown`
/// satisfies nothing but `unknown`/`any` — REPLACES it with the constraint.
///
/// The case that needs it is an `infer` inside an OPTIONAL property, where a
/// check type without that property matches the pattern and leaves the binder
/// with nothing to infer from. atproto's `$TypedObject` is exactly that:
///
///     V extends { $type?: infer T extends $Type<Id, Hash> } ? V & { $type: T } : never
///
/// A `PostView["record"]` (`{ [_ in string]: unknown }`) declares no `$type`,
/// so `T` inferred `unknown`, the constrained-binder rewrite read `unknown
/// extends "app.bsky.feed.post"` as false, and every `isRecord(post.record)`
/// in the atproto SDK narrowed its argument to `never` — a false TS2339 on
/// every property read that followed.
///
/// The constraint is read back off the rewrite `constrainInferBinders` put in
/// front of the true branch (`T extends C ? True : False`), because that copy
/// — unlike the one in `Checker.infer_constraints`, which is recorded once at
/// declaration time — has been instantiated along with the conditional and so
/// names this use site's `Id`/`Hash`.
fn inferConstraintFallback(c: *Checker, b: CondPlan.Bindings, true_ty: TypeId) Error![]const TypeId {
    const s = &c.ts;
    var any_unmatched = false;
    for (b.vals) |v| {
        if (v == types.unknown_type) any_unmatched = true;
    }
    if (!any_unmatched) return b.vals;
    // The rewrite nests exactly one conditional per CONSTRAINED binder, each
    // one's true branch holding the next — so that many levels off the front
    // of the branch are wrappers, and anything deeper is the author's own
    // conditional (which may well test the same binder) and is left alone.
    var remaining: usize = 0;
    for (b.ids) |id| {
        if (c.infer_constraints.contains(id)) remaining += 1;
    }
    if (remaining == 0) return b.vals;
    var t = true_ty;
    var out: ?[]TypeId = null;
    while (remaining > 0 and s.kind(t) == .conditional) {
        const chk = s.condCheck(t);
        if (s.kind(chk) != .infer_var) break;
        const id = s.inferVarId(chk);
        if (!c.infer_constraints.contains(id)) break;
        if (indexOfId(b.ids, id)) |i| {
            if (b.vals[i] == types.unknown_type) {
                if (out == null) out = try c.scratch().dupe(TypeId, b.vals);
                out.?[i] = s.condExtends(t);
            }
        }
        remaining -= 1;
        t = s.condTrue(t);
    }
    return out orelse b.vals;
}

/// The union a distributive conditional's check distributes over, or 0 when
/// it does not distribute. A union check distributes over itself.
///
/// A WHOLE ENUM check distributes over its MEMBER types when the extends
/// clause names members of that same enum. tsc's declared type of `E` IS
/// `E.A | E.B | …`, so `Exclude<E, E.A>` subtracts a member there. ztsc keeps
/// an enum as one nominal type, so `E extends E.A` simply answered false and
/// `Exclude` handed back the whole enum — immich's
/// `ConcurrentQueueName = Exclude<QueueName, QueueName.StorageTemplateMigration
/// | …>` still carried all four excluded queues, which was invisible while
/// `Record<E, V>` materialized an index signature and became four missing
/// properties the moment it materialized named ones.
///
/// Gated on the extends clause mentioning the same enum so that nothing else
/// changes shape: an unrelated test (`E extends string ? … : …`) answers the
/// same for the enum and for every member, and leaving it undistributed keeps
/// the result spelled `E` rather than as a member union.
pub fn condDistributionDomain(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!TypeId {
    const s = &c.ts;
    if (s.kind(chk) == .union_type) return chk;
    if (s.kind(chk) != .enum_type or s.isEnumMember(chk)) return 0;
    if (!try mentionsEnumMemberOf(c, extends_ty, s.enumSymbol(chk))) return 0;
    const mu = (try c.enumMemberTypeUnion(s.enumSymbol(chk), 0)) orelse return 0;
    return if (s.kind(mu) == .union_type) mu else 0;
}

/// Whether `t` is — or is a union containing — a member type of enum `sym`.
fn mentionsEnumMemberOf(c: *Checker, t: TypeId, sym: SymbolId) Error!bool {
    const s = &c.ts;
    if (s.kind(t) == .enum_type) return s.isEnumMember(t) and s.enumSymbol(t) == sym;
    if (s.kind(t) != .union_type) return false;
    for (try c.memberList(t)) |m| {
        if (s.kind(m) == .enum_type and s.isEnumMember(m) and s.enumSymbol(m) == sym) return true;
    }
    return false;
}

pub fn planConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, distributive: bool) Error!CondPlan {
    if (c.inst_depth > max_instantiation_depth or c.inst_count > c.inst_budget) {
        c.inst_limit_tripped = true;
        if (c.instDiagAllowed()) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return .{ .value = types.error_type };
    }
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    const s = &c.ts;
    // A naked `infer`-var check belongs to an *enclosing* conditional's
    // inference (`F extends (...)=>any` inside Awaited, where F is captured
    // by the outer `then(onfulfilled: infer F,...)` conditional). It is not
    // yet bound during instantiateId of the enclosing true branch; keep it
    // symbolic so substInfer re-enters here once F resolves. Without this,
    // it would relate against an unbound infer var and collapse to `never`.
    if (s.kind(chk) == .infer_var) {
        return .{ .need_both = .defer_symbolic };
    }
    // Distribute a distributive conditional over a concrete union check
    // member-wise (the naked check resolved, via substInfer, to a union
    // like `fn | undefined | null`). Each member is inferred independently
    // and the results unioned — this is what lets Awaited pick the callable
    // `then` argument out of its `| undefined | null`. Each member may pick
    // a different branch, so both are wanted.
    if (distributive and (try c.condDistributionDomain(chk, extends_ty)) != 0) {
        return .{ .need_both = .distribute };
    }
    // Defer while a mapped key parameter is still unbound: a
    // conditional in a mapped type's `as`/value branch (`P extends K ?
    // never : P`) must stay symbolic until each key is materialized, or it
    // would resolve against the still-abstract `mapped_param`.
    // A check/extends type whose only type variables are bound within a
    // member signature (`{ f: <T>() => T } extends ...`) is concrete for
    // resolution purposes, so the *free* type-param test gates deferral.
    // A polymorphic `this` in the check is a type variable too (tsc's
    // thisType is a TypeParameter), so `F<this>` stays deferred until the
    // access site substitutes a receiver — see the `.this_expr` arm of
    // `typeFromTypeNode`. Resolving it early against the home instance both
    // re-enters that instance's still-open member table and loses the
    // subclass receiver a later `substThis` would supply.
    const ext_generic = try c.containsFreeTypeParam(extends_ty, &.{}) or try c.containsMappedParam(extends_ty) or try c.containsThisType(extends_ty);
    const chk_generic = try c.containsFreeTypeParam(chk, &.{}) or try c.containsMappedParam(chk) or try c.containsThisType(chk);
    if (chk_generic or ext_generic) {
        // Narrow decidability carve-out (see objectDecidablyNotExtends): a
        // concrete-shaped object check whose free params live only in
        // property values has a fixed shape. When the target is decidable
        // from that shape alone, the false branch holds for every
        // substitution, so resolve rather than defer into a conditional
        // that can never relate (e.g. Awaited<{ data: P }> → { data: P }).
        // An interface / class-instance REFERENCE (`GenericState<T, E>`)
        // has the same fixed member NAMES as an inline object literal —
        // the type arguments only reach property values — so expand the
        // reference before asking the shape question. Without this, immer's
        // `Draft<GenericState<T, E>>` stalled on its `extends
        // ReadonlyMap<…>` / `ReadonlySet<…>` / `WeakReferences` arms and
        // stayed an unreduced conditional whose default constraint (a union
        // including `Map<…>`) exposes none of the state's own members.
        // `[X] extends [Y]` — the idiom that switches distributivity off —
        // wraps both sides in a one-element tuple. Tuples relate
        // element-wise, so the decidability question is EXACTLY the
        // element's; unwrap both before asking it, or every wrapped test
        // (kysely's whole `SelectFrom` chain opens with `[TE] extends
        // [keyof DB]`) is undecidable by construction and defers.
        // Asked on the WRITTEN kinds — the idiom writes both sides as literal
        // tuple type nodes, so no structural resolution is spent here; this
        // runs on the deferral path of every generic conditional.
        var chk_d = chk;
        var ext_d = extends_ty;
        if (s.kind(chk) == .tuple and s.kind(extends_ty) == .tuple and
            s.tupleLen(chk) == 1 and s.tupleLen(extends_ty) == 1)
        {
            const a = s.tupleElem(chk, 0);
            const b = s.tupleElem(extends_ty, 0);
            if (a.flags == 0 and b.flags == 0) {
                chk_d = a.ty;
                ext_d = b.ty;
            }
        }
        if (!ext_generic) {
            const chk_shape = if (s.kind(chk_d) == .ref) try c.resolveStructural(chk_d) else chk_d;
            if (s.kind(chk_shape) == .object and try c.objectDecidablyNotExtends(chk_shape, ext_d)) {
                return .take_false;
            }
        }
        // A concrete *function* check (`(value: number) => Promise<R> | R`
        // with a free `R` only in the return) is likewise non-instantiable:
        // its relation to a function pattern is decided by its parameter
        // shape, and free params in the return flow into the pattern's
        // (`… => any`) return harmlessly. Resolve it rather than deferring —
        // this is what lets Awaited unwrap a real Promise's `then` callback
        // without erasing the method's own `TResult` params.
        if (!ext_generic and s.kind(chk) == .function and s.kind(try c.resolveStructural(extends_ty)) == .function) {
            return c.planConcreteConditional(chk, extends_ty);
        }
        // An array/tuple check against an array pattern whose element is a
        // bare `infer` — the lib's `FlatArray`, `Arr extends
        // ReadonlyArray<infer InnerArr>` — is decided by the check's
        // *shape*: an array is an array whatever its element type is, and
        // the infer var absorbs that element. Free params in the element
        // therefore cannot change the answer, so resolve instead of
        // deferring. Deferring left `arr.flat()` as an unreduced
        // conditional that related to nothing.
        if (!ext_generic and try c.arrayDecidablyExtends(chk, extends_ty)) {
            return c.planConcreteConditional(chk, extends_ty);
        }
        return .{ .need_both = .defer_symbolic };
    }
    return c.planConcreteConditional(chk, extends_ty);
}

pub fn resolveConcreteConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
    const plan = try c.planConcreteConditional(chk, extends_ty);
    return c.finishCondPlan(plan, chk, extends_ty, true_ty, false_ty, distributive);
}

pub fn planConcreteConditional(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!CondPlan {
    // Kept in scratch, never freed here: `ids`/`vals` are handed back to
    // the caller, which substitutes them into a branch it has yet to
    // materialize. The enclosing substitution frame's arena mark releases
    // them (see `instantiateId`'s per-frame rewind).
    var ids: std.ArrayList(u32) = .empty;
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(c.scratch());
    try c.collectInferVars(extends_ty, &ids, &refs);
    // A conditional binds exactly the `infer V` DECLARATIONS in its own
    // extends clause. A bare mention of a binder owned by an ENCLOSING
    // conditional is a free type variable — not this conditional's to bind
    // — so the conditional stays symbolic until the enclosing `substInfer`
    // supplies a value and re-enters here.
    //
    // React's `PropsWithRef` is exactly that shape:
    //     P extends { ref?: infer R | undefined }
    //       ? string extends R
    //           ? PropsWithoutRef<P> & { ref?: Exclude<R, string> | undefined }
    //           : P
    //       : P
    // The inner `string extends R` has a concrete check and an extends made
    // entirely of the OUTER R, so it used to resolve at build time, collect
    // R as its own binder and bind `R := string`. `Exclude<string, string>`
    // is `never`, so every intrinsic element's `ref` prop collapsed to
    // `undefined`; intersecting that dead prop with a live `Ref<T>` is what
    // produced the malformed `undefined & RefObject<unknown>`.
    for (refs.items) |r| {
        if (indexOfId(ids.items, r) == null)
            return .{ .need_both = .defer_symbolic };
    }
    // The same rule applies to a binder mentioned inside the CHECK type. A
    // naked `M` check is caught earlier (`reduceConditional`'s `.infer_var`
    // fast path), but a WRAPPED one is not: `[M] extends [string]` — the
    // idiom for turning distributivity off — hands us a concrete-looking
    // tuple whose element is still an unbound binder owned by an enclosing
    // conditional. `containsFreeTypeParam` doesn't count infer vars, so the
    // whole conditional looked decidable and resolved at BUILD time: the
    // unbound `M` relates to nothing, so `[M] extends [string]` baked the
    // FALSE branch into the enclosing true branch, and no later
    // instantiation could undo it. Defer instead, so the enclosing
    // `substInfer` supplies `M` and re-enters here with a real tuple.
    var chk_vars: std.ArrayList(u32) = .empty;
    defer chk_vars.deinit(c.scratch());
    try c.collectInferVars(chk, &chk_vars, &chk_vars);
    for (chk_vars.items) |v| {
        if (indexOfId(ids.items, v) == null)
            return .{ .need_both = .defer_symbolic };
    }
    // `any` as the check type takes *both* branches (tsc): infer vars bind
    // `any`, and the result is trueBranch | falseBranch. This is what makes
    // `Awaited<any>` collapse to `any` instead of surviving as a deferred
    // conditional that poisons downstream inference.
    if (c.ts.kind(chk) == .any) {
        const any_vals = try c.scratch().alloc(TypeId, ids.items.len);
        for (any_vals) |*v| v.* = types.any_type;
        return .{ .both_any = .{ .ids = ids.items, .vals = any_vals } };
    }
    const vals = try c.scratch().alloc(TypeId, ids.items.len);
    for (vals) |*v| v.* = types.no_type;
    if (ids.items.len > 0) {
        // A fresh key space for this match's `infer_visited` entries, restored
        // on exit so an inference re-entered from inside this one (through an
        // `instantiate` in the walk) cannot invalidate the outer one's.
        const saved_gen = c.infer_gen;
        const saved_steps = c.infer_steps;
        c.infer_gen = c.infer_gen_next;
        c.infer_gen_next +%= 1;
        c.infer_steps = 0;
        defer {
            c.infer_gen = saved_gen;
            c.infer_steps = saved_steps;
        }
        try c.inferFromExtends(chk, extends_ty, ids.items, vals, false, 0);
        for (vals) |*v| {
            if (v.* == types.no_type) v.* = types.unknown_type; // unmatched → unknown
        }
    }
    const resolved_extends = try c.substInfer(extends_ty, ids.items, vals);
    if (try c.isAssignable(chk, resolved_extends)) {
        return .{ .take_true = .{ .ids = ids.items, .vals = vals } };
    }
    return .take_false; // infer binders are out of scope in the false branch
}

/// TS 4.8 constrained `infer`: a binder written `infer V extends C` only
/// matches when the value inferred for it satisfies `C`; otherwise the whole
/// conditional resolves to its FALSE branch.
///
/// Expressed as a rewrite of the true branch rather than as a check at
/// reduction time, because a check there cannot SUBSTITUTE the constraint.
/// atproto's `$TypedObject<V, Id, Hash>` is the case that forces it:
///
///     V extends { $type?: infer T extends $Type<Id, Hash> } ? V & { $type: T } : never
///
/// The binder is declared once, while `Id`/`Hash` are still the alias's own
/// type parameters, so a stored constraint is the generic `$Type<Id, Hash>`
/// and says nothing until the use site supplies the lexicon id. Written into
/// the branch as `T extends $Type<Id, Hash> ? True : False`, the ordinary
/// `instantiateId` substitutes it along with everything else, the inner
/// conditional stays deferred while `T` is unbound (`planConditional`'s
/// `.infer_var` fast path) and reduces the moment `substInfer` binds it.
///
/// This is what discriminates `chat.bsky.group.defs#joinLinkPreviewView` from
/// every sibling lexicon type; without it `isJoinLinkPreviewView(x)` and every
/// other generated atproto predicate narrowed to the union it started from.
///
/// Nests innermost-last so several constrained binders in one extends clause
/// all have to hold; returns `true_ty` untouched — the overwhelmingly common
/// case — when this conditional declares none.
fn constrainInferBinders(c: *Checker, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId) Error!TypeId {
    if (c.infer_constraints.count() == 0) return true_ty;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(c.scratch());
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(c.scratch());
    try c.collectInferVars(extends_ty, &ids, &refs);
    var out = true_ty;
    for (ids.items) |id| {
        const cons = c.infer_constraints.get(id) orelse continue;
        // Not distributive: the constraint judges the type inferred for the
        // binder as a whole, it does not split a union inference into the
        // members that pass and the members that fail.
        out = try c.ts.makeConditional(try c.ts.makeInferVar(id, cons.name, true), cons.ty, out, false_ty, false);
    }
    return out;
}

/// Decidability rule for a check against an array pattern whose element is
/// a bare `infer` var (`Arr extends ReadonlyArray<infer I>` — the lib's
/// `FlatArray`). An unconstrained `infer` accepts every element type, so
/// the only thing the pattern asks is "is the check an array?", and that is
/// settled by the check's own shape: an array/tuple always matches, a
/// function never does, whatever free params sit inside them. A pattern
/// with a *constrained* element (`ReadonlyArray<string>`) decides nothing —
/// whether `T[]` matches it depends on `T` — so that still defers, as does
/// a check whose top-level shape is itself a variable.
pub fn arrayDecidablyExtends(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!bool {
    const s = &c.ts;
    if (!try c.isArrayShaped(chk)) return false;
    const ext = try c.resolveStructural(extends_ty);
    if (s.kind(ext) != .array) return false;
    return s.kind(s.arrayElem(ext)) == .infer_var;
}

/// `t` is an array/tuple whatever its free type parameters turn out to be.
/// A BRANDED tuple (`[P, P] & { _brand: "…" }`, the shape every geometry
/// type in a branded-primitive codebase has) is array-shaped through the
/// intersection: one constituent is the tuple, and an intersection's values
/// satisfy every constituent.
pub fn isArrayShaped(c: *Checker, t: TypeId) Error!bool {
    // An interface/class instance is an object for every argument list, and
    // an object is not array-shaped — so the whole member table need not be
    // materialized to say no. See `refExpandsToObject`.
    if (c.refExpandsToObject(t)) return false;
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .array, .tuple, .function => return true,
        .intersection => {
            for (0..c.ts.memberCount(r)) |i| {
                if (try c.isArrayShaped(c.ts.memberAt(r, i))) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Narrow decidability rule for a deferred conditional whose *check* is a
/// concrete-shaped object literal (`{ data: P }`) carrying free type params
/// only in property VALUES. Such a check has a fixed shape, so some
/// `extends` targets are decidable for every substitution of those params.
/// Returns true when the object *definitely does not* satisfy `extends_ty`
/// (the conditional then takes its false branch) — the only direction we
/// resolve, since a "true" match could hinge on a value type that depends
/// on the free params. Kept deliberately shape-only:
///   * an object is never `null`/`undefined` (Awaited's outer branch);
///   * an object lacking a required member NAME is not assignable to a
///     structural target that requires it (Awaited's `then` branch).
/// Anything else stays deferred (return false).
pub fn objectDecidablyNotExtends(c: *Checker, chk_obj: TypeId, extends_ty: TypeId) Error!bool {
    const s = &c.ts;
    const ext = try c.resolveStructural(extends_ty);
    switch (s.kind(ext)) {
        .null, .undefined => return true,
        // No object type is assignable to a PRIMITIVE, whatever its free
        // params turn out to be — a value with members is not a string, a
        // number, a literal, a template pattern or an enum member. (`any`,
        // `unknown`, `object` and `{}` are deliberately absent: an object
        // does satisfy those.) This is what decides kysely's `[TE] extends
        // [keyof DB]` and `[TE] extends [`${infer T} as ${infer A}`]` for a
        // class-instance table expression, so the chain reaches its real
        // last arm instead of stalling and later having a branch picked for
        // it by an apparent-type lookup.
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .bool_true,
        .bool_false,
        .unique_symbol,
        .template_literal_type,
        .string_mapping,
        .enum_type,
        .never,
        .void,
        => return true,
        .union_type => {
            // A union is out of reach exactly when every constituent is.
            for (try c.memberList(ext)) |m| {
                if (!try c.objectDecidablyNotExtends(chk_obj, m)) return false;
            }
            return true;
        },
        .object, .intersection => {
            // A missing required member name is decidable regardless of the
            // free params — but only when no index signature could supply
            // it. If every required name is present, the value types may
            // depend on the params, so stay deferred.
            if (s.objectStringIndex(chk_obj) != 0 or s.objectNumberIndex(chk_obj) != 0) return false;
            const members: []const TypeId = if (s.kind(ext) == .intersection) try c.memberList(ext) else &.{ext};
            for (members) |mem| {
                if (s.kind(mem) != .object) continue;
                for (0..s.objectPropCount(mem)) |i| {
                    const p = s.objectProp(mem, @intCast(i));
                    if (p.optional()) continue;
                    if (s.objectPropByName(chk_obj, p.name) == null) return true; // required name absent
                }
            }
            return false;
        },
        .array, .tuple => {
            // An object type carrying neither a `length` member nor a
            // numeric index signature is not an array/tuple for ANY
            // substitution of its free params — array-ness is settled by
            // the check's own shape. (immer 11's `WritableDraft` opens with
            // `T extends any[] ? …`; without this the whole `Draft<…>`
            // chain stayed deferred.)
            if (s.objectNumberIndex(chk_obj) != 0) return false;
            return s.objectPropByName(chk_obj, c.atom_length) == null;
        },
        else => return false,
    }
}

pub fn indexOfId(ids: []const u32, id: u32) ?usize {
    for (ids, 0..) |x, i| {
        if (x == id) return i;
    }
    return null;
}

pub fn indexOfAtom(atoms: []const Atom, needle: Atom) ?usize {
    for (atoms, 0..) |x, i| {
        if (x == needle) return i;
    }
    return null;
}

/// Gather the `infer` binders a conditional's extends clause mentions.
/// DECLARATIONS (`infer V`) land in `out` — those are the binders the
/// conditional owns; bare REFERENCES to a binder declared by an enclosing
/// conditional land in `refs` (see `types.infer_var_reference`). One walk
/// serves both so the hot conditional path pays for a single traversal.
pub fn collectInferVars(c: *Checker, t: TypeId, out: *std.ArrayList(u32), refs: ?*std.ArrayList(u32)) Error!void {
    // The only arm that writes is `.infer_var`, and this walk's arms are a
    // strict SUBSET of `containsInfer`'s — so a subtree that holds no binder
    // can be skipped whole. `containsInfer` is memoized per interned type, so
    // this turns the repeat descent of a conditional's extends clause (asked
    // once per instantiation) into one map probe.
    if (!try c.containsInfer(t)) return;
    const s = &c.ts;
    switch (s.kind(t)) {
        .infer_var => {
            const id = s.inferVarId(t);
            const bucket = if (s.inferVarIsRef(t)) (refs orelse return) else out;
            if (indexOfId(bucket.items, id) == null) try bucket.append(c.scratch(), id);
        },
        .array => try c.collectInferVars(s.arrayElem(t), out, refs),
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| try c.collectInferVars(s.memberAt(t, i), out, refs);
        },
        .tuple => {
            for (0..s.tupleLen(t)) |i| try c.collectInferVars(s.tupleElem(t, @intCast(i)).ty, out, refs);
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| try c.collectInferVars(s.objectProp(t, @intCast(i)).ty, out, refs);
            if (s.objectStringIndex(t) != 0) try c.collectInferVars(s.objectStringIndex(t), out, refs);
            if (s.objectNumberIndex(t) != 0) try c.collectInferVars(s.objectNumberIndex(t), out, refs);
            // Call/construct signatures carry infer vars too (`new (x: infer
            // P) => …`, a `JSXElementConstructor` construct constituent).
            for (0..s.objectCallSigCount(t)) |i| try c.collectInferVars(s.objectCallSig(t, @intCast(i)), out, refs);
            for (0..s.objectConstructSigCount(t)) |i| try c.collectInferVars(s.objectConstructSig(t, @intCast(i)), out, refs);
        },
        .function => {
            for (0..s.fnParamCount(t)) |i| try c.collectInferVars(s.fnParam(t, @intCast(i)).ty, out, refs);
            try c.collectInferVars(s.fnReturn(t), out, refs);
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| try c.collectInferVars(s.refArgAt(t, i), out, refs);
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| try c.collectInferVars(s.templateHole(t, @intCast(i)), out, refs);
        },
        .string_mapping => try c.collectInferVars(s.stringMappingArg(t), out, refs),
        .keyof_op => try c.collectInferVars(s.keyofOperand(t), out, refs),
        else => {},
    }
}

/// Infer `infer` binders by structurally matching a concrete `source`
/// against the `pattern` (the extends clause). `contra` flips the
/// same-name combine rule (union in covariant positions, intersection in
/// contravariant/function-parameter positions).
pub fn inferFromExtends(c: *Checker, source0: TypeId, pattern: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    if (depth > max_infer_depth) {
        c.infer_trunc = true;
        return;
    }
    // RUNAWAY ESCAPE HATCH. Both guards below are sound in isolation — neither
    // can lose a candidate — but they are not INERT: skipping a subtree changes
    // the order in which types are first expanded, and several memos here
    // (`alias_generic`, `iface_generic`, the relation memo) permanently record
    // whatever a cycle cut answered at that moment. Enabling them everywhere
    // moved drizzle-orm's parity by 46 keys (45 TS2344 + a TS2589) with no
    // candidate lost anywhere — and drizzle is ratcheted at absolute zero.
    //
    // So they arm only once ONE inference has already made
    // `max_infer_steps` recursive calls. Below that line every walk is
    // byte-identical to what it was; above it the alternative is not a
    // different answer but no answer at all (kysely's `ExpressionOrFactory`
    // match ran for minutes and took 77 GB of instantiation scratch). This is
    // the same shape as `max_infer_depth` right above: a ceiling on a walk that
    // has left the range where exhaustiveness is affordable, not a change to
    // what the walk means.
    c.infer_steps +%= 1;
    const runaway = c.infer_steps > max_infer_steps;
    // tsc's `inferFromTypes` opens with `if (!couldContainTypeVariables(target))
    // return;` — a walk into a target that holds no inference variable can only
    // recurse and find nothing, since the ONLY arm that writes a candidate is
    // `.infer_var` (and `bindTemplateInfer`, which needs one too). `ids` itself
    // is built by `collectInferVars`, whose arms are a strict SUBSET of
    // `containsInfer`'s, so a pattern this rejects can bind nothing.
    if (runaway and !try c.containsInfer(pattern)) return;
    const s = &c.ts;
    // tsc's `visited` guard (`inferFromObjectTypes`): a `(source, pattern)`
    // pair already walked in this inference writes nothing new — every combine
    // (`vals[idx] = union/intersection(vals[idx], source0)`) is idempotent in
    // its own argument — so the repeat is pure cost. `contra` rides in the
    // value because it changes how a candidate combines. The prune above is
    // powerless against a SELF-REFERENTIAL pattern like kysely's
    // `SelectQueryBuilderExpression<infer O>`, an interface whose members are
    // functions returning it: `infer O` is reachable everywhere, so the walk
    // branches once per member at every one of the 24 allowed levels.
    // Cheap leaves are excluded: they cost less than the map probe.
    const memoize = runaway and switch (s.kind(pattern)) {
        .object, .function, .ref, .intersection, .union_type, .overloads, .conditional, .mapped => true,
        else => false,
    };
    if (!memoize) return inferFromExtendsInner(c, source0, pattern, ids, vals, contra, depth);
    // Skipping on pair identity ALONE is not result-preserving, because the
    // walk is cut at `max_infer_depth`: a pair first met deep may have been
    // TRUNCATED where the same pair met shallower would still reach the binder
    // below it. So the record carries both the depth it started at and whether
    // anything under it was cut, and a repeat is skipped only when the earlier
    // visit started no deeper AND ran to completion. (Identity alone moved
    // three keys on immich; this moves none.)
    const key = (@as(u64, source0) << 32) | pattern;
    const tag: u64 = (c.infer_gen << 1) | @intFromBool(contra);
    if (c.infer_visited.get(key)) |v| {
        if (v >> 33 == tag and v & (1 << 32) == 0 and @as(u32, @truncate(v)) <= depth) return;
    }
    // Published BEFORE recursing — blocking the repeats *inside* this walk is
    // the whole win — with the truncated bit clear, so a nested repeat deeper
    // than this one is skipped and a shallower one cannot occur (depth only
    // grows). The real bit is written back below.
    try c.infer_visited.put(c.cm(), key, (tag << 33) | depth);
    const outer_trunc = c.infer_trunc;
    c.infer_trunc = false;
    defer c.infer_trunc = outer_trunc or c.infer_trunc;
    try inferFromExtendsInner(c, source0, pattern, ids, vals, contra, depth);
    try c.infer_visited.put(c.cm(), key, (tag << 33) | (@as(u64, @intFromBool(c.infer_trunc)) << 32) | depth);
}

/// Ceiling on `inferFromExtends`'s structural descent. A cut here is what makes
/// the visited guard depth-sensitive — see there.
pub const max_infer_depth: u32 = 24;

/// Recursive `inferFromExtends` calls one inference may make before its guards
/// arm (see the escape hatch there). Chosen from measurement, not taste: over
/// the whole eight-package parity corpus plus excalidraw the busiest single
/// inference makes ~4.6k calls, while kysely's `ExpressionOrFactory` match
/// makes tens of millions. Anything in the wide gap between separates "walk it
/// all, exactly as before" from "this will not finish".
pub const max_infer_steps: u64 = 100_000;

fn inferFromExtendsInner(c: *Checker, source0: TypeId, pattern: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    switch (s.kind(pattern)) {
        .infer_var => {
            const idx = indexOfId(ids, s.inferVarId(pattern)) orelse return;
            if (vals[idx] == types.no_type) {
                vals[idx] = source0;
            } else if (contra) {
                vals[idx] = try c.ts.makeIntersection(c.scratch(), &.{ vals[idx], source0 });
            } else {
                vals[idx] = try c.makeUnion2(vals[idx], source0);
            }
        },
        .array => {
            const src = try c.resolveStructural(source0);
            switch (s.kind(src)) {
                .array => try c.inferFromExtends(s.arrayElem(src), s.arrayElem(pattern), ids, vals, contra, depth + 1),
                .tuple => {
                    for (0..s.tupleLen(src)) |i|
                        try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.arrayElem(pattern), ids, vals, contra, depth + 1);
                },
                // A *branded* array — `[Point, Point] & { _brand: "seg" }`,
                // the standard nominal-tuple idiom — is still an array, and
                // its element type lives in the array constituent. Without
                // this the pattern matched nothing and the infer var fell
                // back to `unknown`, so `segs.flat()` came back
                // `unknown[]`. Non-arrayish constituents (the brand object)
                // contribute nothing, exactly as they do here at top level.
                .intersection => {
                    for (try c.memberList(src)) |m| {
                        switch (s.kind(try c.resolveStructural(m))) {
                            .array, .tuple => try c.inferFromExtends(m, pattern, ids, vals, contra, depth + 1),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        },
        .tuple => {
            const src = try c.resolveStructural(source0);
            if (s.kind(src) != .tuple) return;
            const plen = s.tupleLen(pattern);
            const slen = s.tupleLen(src);
            // Locate the (at most one, per the TS grammar) rest element in
            // the pattern. `[infer H, ...infer R]` must bind R to the rest
            // *tuple* — not to the first rest element (the pre-fix bug):
            // positional `@min` matching aliased `...infer R` onto src[k].
            var rest_idx: ?u32 = null;
            for (0..plen) |i| {
                if (s.tupleElem(pattern, @intCast(i)).rest()) {
                    rest_idx = @intCast(i);
                    break;
                }
            }
            if (rest_idx == null) {
                const n = @min(slen, plen);
                for (0..n) |i|
                    try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.tupleElem(pattern, @intCast(i)).ty, ids, vals, contra, depth + 1);
                return;
            }
            const ri = rest_idx.?;
            const suffix = plen - ri - 1; // fixed pattern elements after the rest
            if (slen < ri + suffix) return; // source too short: no valid match
            // Prefix: pattern[0..ri] positionally against src[0..ri].
            for (0..ri) |i|
                try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, s.tupleElem(pattern, @intCast(i)).ty, ids, vals, contra, depth + 1);
            // Suffix: pattern[ri+1..] positionally against the src tail.
            for (0..suffix) |j|
                try c.inferFromExtends(s.tupleElem(src, @intCast(slen - suffix + j)).ty, s.tupleElem(pattern, @intCast(ri + 1 + j)).ty, ids, vals, contra, depth + 1);
            // Rest: pattern[ri] captures the middle src[ri..slen-suffix] as a
            // tuple. `...infer R` stores the infer var directly as the
            // element type → bind R to that middle tuple; `...(infer U)[]`
            // binds U from each middle element; anything else recurses
            // structurally against the reconstructed middle tuple.
            const rest_pat = s.tupleElem(pattern, ri).ty;
            var mid: std.ArrayList(types.TupleElem) = .empty;
            defer mid.deinit(c.scratch());
            var k: u32 = ri;
            while (k < slen - suffix) : (k += 1) {
                const e = s.tupleElem(src, k);
                try mid.append(c.scratch(), .{ .ty = e.ty, .flags = e.flags });
            }
            const mid_tuple = try s.makeTuple(mid.items);
            if (s.kind(rest_pat) == .array) {
                for (mid.items) |me|
                    try c.inferFromExtends(me.ty, s.arrayElem(rest_pat), ids, vals, contra, depth + 1);
            } else {
                try c.inferFromExtends(mid_tuple, rest_pat, ids, vals, contra, depth + 1);
            }
        },
        .ref => {
            // Identity pairing infers from the two references' type ARGUMENTS
            // and reads no member, so it runs before the source is resolved
            // (the same ordering `unify`'s `.ref` arm takes).
            if (s.kind(source0) == .ref and s.refSymbol(source0) == s.refSymbol(pattern)) {
                const pa = try c.scratch().dupe(TypeId, s.refArgs(pattern));
                const aa = try c.scratch().dupe(TypeId, s.refArgs(source0));
                const n = @min(pa.len, aa.len);
                for (0..n) |i| try c.inferFromExtends(aa[i], pa[i], ids, vals, contra, depth + 1);
                return;
            }
            const src = try c.resolveStructural(source0);
            // `Array<infer U>` (and other single-arg generics) vs an
            // array/tuple source: bind the arg from the element type.
            const pa = try c.scratch().dupe(TypeId, s.refArgs(pattern));
            if (pa.len == 1) {
                switch (s.kind(src)) {
                    .array => return c.inferFromExtends(s.arrayElem(src), pa[0], ids, vals, contra, depth + 1),
                    .tuple => {
                        for (0..s.tupleLen(src)) |i|
                            try c.inferFromExtends(s.tupleElem(src, @intCast(i)).ty, pa[0], ids, vals, contra, depth + 1);
                        return;
                    },
                    else => {},
                }
            }
            const rp = try c.resolveStructural(pattern);
            if (rp != pattern) try c.inferFromExtends(src, rp, ids, vals, contra, depth + 1);
        },
        .object => {
            var src = try c.resolveStructural(source0);
            // A construct-signature pattern (`abstract new (…args: any) =>
            // infer R`, the shape of `InstanceType`/`ConstructorParameters`)
            // against a class value: `.class_value` is nominal and carries
            // no structural signatures, so bridge it to its constructor
            // object first. Only for signature-bearing patterns — a plain
            // property pattern reads a class value's statics through the
            // ordinary `propOfTypeEx` route.
            if (s.kind(src) == .class_value and
                (s.objectConstructSigCount(pattern) > 0 or s.objectCallSigCount(pattern) > 0))
            {
                src = try c.classConstructType(s.classSymbol(src));
            }
            // An INTERSECTION source still has the pattern's properties —
            // tsc's `inferFromProperties` reads each target property off
            // the source with `getTypeOfPropertyOfType`, and
            // `getUnionOrIntersectionProperty` synthesises an
            // intersection's property from the constituents that declare
            // it. Bailing out here (the pre-fix `!= .object` return) left
            // every infer var of a property pattern unbound, so it
            // resolved to `unknown`: React's
            // `PropsWithRef<P> = "ref" extends keyof P ? P extends { ref?:
            // infer R | undefined } ? …` inferred `R = unknown` for every
            // intrinsic element, because `ComponentProps<'div'>` is
            // `ClassAttributes<HTMLDivElement> & HTMLAttributes<…>` — an
            // intersection.
            //
            // Signature inference below still needs a single object, so
            // the intersection only feeds the property loop.
            if (s.kind(src) == .intersection) {
                for (0..s.objectPropCount(pattern)) |i| {
                    const pp = s.objectProp(pattern, @intCast(i));
                    // `allow_index = false`: an index signature or an
                    // apparent `Object`/`Function` member is not a
                    // declared property and must not seed a candidate,
                    // matching the plain-object branch below.
                    if (try c.propOfTypeEx(src, pp.name, false)) |sp| {
                        try c.inferFromExtends(sp.ty, pp.ty, ids, vals, contra, depth + 1);
                    }
                }
                return;
            }
            if (s.kind(src) != .object) return;
            for (0..s.objectPropCount(pattern)) |i| {
                const pp = s.objectProp(pattern, @intCast(i));
                if (s.objectPropByName(src, pp.name)) |sp| {
                    try c.inferFromExtends(sp.ty, pp.ty, ids, vals, contra, depth + 1);
                }
            }
            // A construct-signature pattern (`new (props: infer P) => …`,
            // e.g. `JSXElementConstructor`'s class constituent) is an object
            // carrying a construct signature; a call-signature pattern object
            // (a function type with extra members) carries call sigs. Infer
            // through both signature kinds, aligning source→pattern sigs from
            // the end like tsc's `inferFromSignatures`.
            try c.inferFromObjectSigs(src, pattern, false, ids, vals, contra, depth);
            try c.inferFromObjectSigs(src, pattern, true, ids, vals, contra, depth);
        },
        .function => {
            var src = try c.resolveStructural(source0);
            // A callable-object source (an interface/type literal carrying
            // call signatures — e.g. React's `ForwardRefExoticComponent<P>`,
            // whose `(props: P): ReactNode` sig makes it a component) stands
            // in for a bare function when matched against a function-type
            // pattern. tsc's `inferFromSignatures` aligns source/target sigs
            // from the end, so a single-signature pattern infers from the
            // source's LAST call signature (the overload picked for the
            // most-general shape). Extract it and recurse.
            if (s.kind(src) == .object) {
                const ncall = s.objectCallSigCount(src);
                if (ncall > 0)
                    try c.inferFromExtends(s.objectCallSig(src, ncall - 1), pattern, ids, vals, contra, depth + 1);
                return;
            }
            // A callable intersection stands in for a bare function against a
            // function-type pattern:
            //   * OVERLOAD SET intersected with a namespace value object
            //     (`typeof setTimeout` = `overloads & namespaceObject` after
            //     the lib+node timer merge) → infer through its last call
            //     signature so `ReturnType<typeof setTimeout>` reads the node
            //     return type instead of collapsing to `unknown`;
            //   * a plain function intersected with its statics
            //     (`typeof Icon` = `((props) => JSX) & typeof Icon`, a
            //     `declare function` value carrying own properties) → infer
            //     through that bare call-signature member, so
            //     `ComponentProps<typeof Icon>` = its props type, not
            //     `unknown`. (A callable OBJECT member — React's
            //     `ForwardRefExoticComponent<P> & {…}`, whose call sig lives
            //     INSIDE an object member rather than as a bare `.function` —
            //     is still left to the object/construct-signature path below.)
            if (s.kind(src) == .intersection) {
                var callable: TypeId = types.no_type; // overload set
                var fn_member: TypeId = types.no_type; // bare call signature
                for (try c.memberList(src)) |m| {
                    const rm = try c.resolveStructural(m);
                    if (s.kind(rm) == .overloads) {
                        callable = rm;
                    } else if (s.kind(rm) == .function and fn_member == types.no_type) {
                        fn_member = rm;
                    }
                }
                if (callable != types.no_type) {
                    if (try c.lastCallSig(callable)) |sig| src = sig else return;
                } else if (fn_member != types.no_type) {
                    src = fn_member;
                } else return;
            }
            // A plain overload set — the type of a multiply-declared method
            // reached through property/indexed access (`S['m']`, e.g. jest's
            // `Service.patch` with two overload signatures) — infers through
            // its LAST call signature, the same end-aligned rule tsc's
            // `inferFromSignatures` applies to the callable-object and
            // overload-intersection cases above. Without this the `.function`
            // guard below drops it and `ReturnType<S['m']>` collapses to
            // `unknown` (then jest's `ResolvedValue<unknown>` → `never`,
            // wrongly rejecting `mockResolvedValueOnce(null)` as TS2769).
            if (s.kind(src) == .overloads) {
                if (try c.lastCallSig(src)) |sig| src = sig else return;
            }
            if (s.kind(src) != .function) return;
            // A generic *source* signature must be reduced to its base
            // signature before we infer *through* it: each of the source's
            // own type params is erased to its constraint (or `unknown`
            // when unconstrained), matching tsc's `getBaseSignature`.
            // Otherwise those bound params leak into the infer results, e.g.
            // `(<T>(x: T) => T) extends (x: infer A) => infer B` must yield
            // `unknown, unknown` (not `T, T`), and `<T extends string>`
            // yields `string, string`. Defaults are ignored (only the
            // constraint erases). This only touches the source's *own*
            // params; outer/free params still flow through untouched.
            var base_map: std.ArrayList(TpMap) = .empty;
            defer base_map.deinit(c.scratch());
            // Index: resolving a constraint interns (see `memberAt`).
            for (0..s.fnTypeParamCount(src)) |i| {
                const p = s.fnTypeParamAt(src, i);
                const con = try c.typeParamConstraint(p);
                const bt = if (con != types.no_type) con else types.unknown_type;
                try base_map.append(c.scratch(), .{ .sym = p, .ty = bt });
            }
            // A trailing rest param in the *pattern* (`(...args: infer P)`,
            // the shape `Parameters` / `ConstructorParameters` use) must
            // bind its infer var to the TUPLE of ALL remaining source
            // params — not 1:1 onto the single source param at that slot.
            // Positionally aligning `...args: infer P` with `src[i]` (the
            // pre-fix `@min` loop) made P a 1-element tuple, so
            // `Parameters<typeof F>[1]`/`[2]` fell through to index 0's
            // type. Mirror tsc's `inferFromParameters` + `getRestTypeAtPosition`:
            // fixed positions infer 1:1, then the rest slot gathers the
            // residual source params into a tuple (optional source params →
            // optional elements, a trailing source rest param → a rest
            // element) and infers that against the pattern's rest type.
            //
            // The SOURCE's parameter list is the *expanded* one: tsc's
            // `getExpandedParameters` turns a trailing rest typed by a fixed
            // tuple (`(...args: Parameters<F>)` — what every
            // `BoundFunction`-style helper produces) into that positional
            // list before any parameter is paired up. Unexpanded, the whole
            // tuple was matched against the pattern's FIRST parameter and
            // `(container: Elem, ...args: infer P)` bound `P` to the empty
            // tuple; the conditional's own check then failed and the type
            // fell to the `never` branch — a TS2339 on every use.
            var exp: std.ArrayList(types.Param) = .empty;
            defer exp.deinit(c.scratch());
            {
                const raw = s.fnParamCount(src);
                const tup = if (raw > 0) try c.sigRestTuple(src) else null;
                if (tup) |tt| {
                    for (0..raw - 1) |i| try exp.append(c.scratch(), s.fnParam(src, @intCast(i)));
                    for (0..s.tupleLen(tt)) |i| {
                        const e = s.tupleElem(tt, @intCast(i));
                        var pf: u32 = 0;
                        if (e.optional()) pf |= types.param_flag_optional;
                        if (e.rest()) pf |= types.param_flag_rest;
                        try exp.append(c.scratch(), .{ .name = 0, .ty = e.ty, .flags = pf });
                    }
                } else {
                    for (0..raw) |i| try exp.append(c.scratch(), s.fnParam(src, @intCast(i)));
                }
            }
            const src_count: u32 = @intCast(exp.items.len);
            const pat_count = s.fnParamCount(pattern);
            const pat_has_rest = pat_count != 0 and s.fnParam(pattern, pat_count - 1).rest();
            const pat_fixed = if (pat_has_rest) pat_count - 1 else pat_count;
            const n = @min(src_count, pat_fixed);
            for (0..n) |i| {
                var sp = exp.items[i].ty;
                if (base_map.items.len != 0) sp = try c.instantiate(sp, base_map.items);
                try c.inferFromExtends(sp, s.fnParam(pattern, @intCast(i)).ty, ids, vals, !contra, depth + 1);
            }
            if (pat_has_rest) {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                var i: u32 = pat_fixed;
                while (i < src_count) : (i += 1) {
                    const sp = exp.items[i];
                    var pty = sp.ty;
                    if (base_map.items.len != 0) pty = try c.instantiate(pty, base_map.items);
                    var eflags: u32 = 0;
                    if (sp.rest()) eflags |= types.elem_flag_rest;
                    if (sp.optional()) eflags |= types.elem_flag_optional;
                    try elems.append(c.scratch(), .{ .ty = pty, .flags = eflags });
                }
                const src_tuple = try s.makeTuple(elems.items);
                try c.inferFromExtends(src_tuple, s.fnParam(pattern, pat_count - 1).ty, ids, vals, !contra, depth + 1);
            }
            var sr = s.fnReturn(src);
            if (base_map.items.len != 0) sr = try c.instantiate(sr, base_map.items);
            try c.inferFromExtends(sr, s.fnReturn(pattern), ids, vals, contra, depth + 1);
        },
        .union_type => {
            // tsc's `inferFromTypes` union rule, the same one `unify`'s
            // `.union_type` arm already applies to a call's arguments: "first
            // infer between identically matching source and target
            // constituents and remove the matched types from
            // consideration"; only the RESIDUAL source is then offered to
            // the infer-bearing members. Identity is TypeId equality on
            // interned types, so this only fires on an exact match.
            //
            // kysely's `AliasedExpression<T, A>` declares `alias: A |
            // Expression<unknown>`, so `X extends AliasedExpression<any,
            // infer EA>` infers `EA` from `"foo" | Expression<unknown>`
            // against `EA | Expression<unknown>`. Without the subtraction
            // `EA` came out as the whole union, which is not a property name
            // — so `Selection`'s key remap dropped the column and every
            // later read of it was a TS2339.
            const pms = try c.scratch().dupe(TypeId, try c.memberList(pattern));
            const rsrc = try c.resolveStructural(source0);
            const residual: TypeId = blk: {
                if (s.kind(rsrc) != .union_type) break :blk source0;
                const sms = try c.scratch().dupe(TypeId, try c.memberList(rsrc));
                var rem: std.ArrayList(TypeId) = .empty;
                defer rem.deinit(c.scratch());
                for (sms) |sm| {
                    var paired = false;
                    for (pms) |pm| {
                        if (pm == sm) {
                            paired = true;
                            break;
                        }
                    }
                    if (!paired) try rem.append(c.scratch(), sm);
                }
                // Nothing subtracted, or everything did (tsc still offers the
                // whole source when the residual is empty): leave it alone.
                if (rem.items.len == 0 or rem.items.len == sms.len) break :blk source0;
                break :blk try s.makeUnion(c.scratch(), rem.items);
            };
            for (pms) |m| {
                if (try c.containsInfer(m)) try c.inferFromExtends(residual, m, ids, vals, contra, depth + 1);
            }
        },
        // Intersection pattern (`object & { then(onfulfilled: infer F, …) }`
        // for Awaited; `NextExt & infer Ext` for a redux StoreEnhancer).
        // tsc's rule: first cancel constituents that are *identical* between
        // source and pattern, then infer the residual source into the
        // pattern's infer-bearing constituents. A pattern constituent that is
        // a *foreign type variable* (a signature-local / free type param, not
        // one of our infer ids) with no identical match in the source
        // POISONS the inference — tsc attributes no candidate to the infer
        // var, which then resolves to its constraint. This is what makes
        // `StoreEnhancer<{dispatch}> extends StoreEnhancer<infer E>` yield
        // `{}` (E's constraint) instead of dragging the whole
        // function-return intersection (incl. `Store<unknown, …>`) into E,
        // while an ordinary `string & infer X` still residuals to X.
        .intersection => {
            const isrc = try c.resolveStructural(source0);
            const src_members: []const TypeId = if (s.kind(isrc) == .intersection)
                try c.memberList(isrc)
            else
                &.{isrc};
            const matched = try c.scratch().alloc(bool, src_members.len);
            for (matched) |*mm| mm.* = false;
            for (try c.memberList(pattern)) |m| {
                if (try c.containsInfer(m)) continue;
                var found = false;
                for (src_members, 0..) |sm, i| {
                    if (!matched[i] and sm == m) {
                        matched[i] = true;
                        found = true;
                        break;
                    }
                }
                if (found) continue;
                // Unmatched foreign type variable → poison the whole
                // intersection: leave its infer vars unbound.
                if (s.kind(m) == .type_param or s.kind(try c.resolveStructural(m)) == .type_param) return;
            }
            // Residual source: the un-cancelled constituents. When nothing
            // cancelled, reuse `source0` verbatim (preserves the Awaited path
            // and its display exactly); otherwise rebuild from the residue.
            var n_matched: usize = 0;
            for (matched) |mm| {
                if (mm) n_matched += 1;
            }
            var residual_src = source0;
            if (n_matched != 0) {
                var residue: std.ArrayList(TypeId) = .empty;
                defer residue.deinit(c.scratch());
                for (src_members, 0..) |sm, i| {
                    if (!matched[i]) try residue.append(c.scratch(), sm);
                }
                residual_src = if (residue.items.len == 0)
                    types.unknown_type
                else
                    try c.ts.makeIntersection(c.scratch(), residue.items);
            }
            for (try c.memberList(pattern)) |m| {
                if (try c.containsInfer(m)) try c.inferFromExtends(residual_src, m, ids, vals, contra, depth + 1);
            }
        },
        // `S extends `${infer H}-${infer R}`` — pattern-match the source
        // against the template, binding each hole's infer var. A concrete
        // string source walks the text; a template-literal *type* source
        // (`` `owners.${number}.status` ``) matches its fixed text parts and
        // placeholder types against the target's spans (tsc's
        // `inferFromLiteralPartsToTemplateLiteral`).
        .template_literal_type => {
            const src = try c.resolveStructural(source0);
            if (try c.stringLiteralOf(src)) |atom_| {
                try c.inferFromTemplate(c.atomText(atom_), pattern, ids, vals);
            } else if (s.kind(src) == .template_literal_type) {
                try c.inferFromTemplateSource(src, pattern, ids, vals, contra, depth);
            }
        },
        else => {},
    }
}

/// Infer through the call (`is_construct == false`) or construct signatures
/// shared by a source object and a signature-bearing pattern object. tsc's
/// `inferFromSignatures` pairs source/target signatures aligned from the END
/// of each list, so an N-signature source and a 1-signature pattern infer
/// from the source's last signature. Each paired signature is a `.function`
/// TypeId, so the recursion lands back in the `.function` arm (params
/// contravariant, return covariant).
pub fn inferFromObjectSigs(c: *Checker, src: TypeId, pattern: TypeId, is_construct: bool, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    const scount = if (is_construct) s.objectConstructSigCount(src) else s.objectCallSigCount(src);
    const pcount = if (is_construct) s.objectConstructSigCount(pattern) else s.objectCallSigCount(pattern);
    if (scount == 0 or pcount == 0) return;
    const len = @min(scount, pcount);
    for (0..len) |i| {
        const ssig = if (is_construct) s.objectConstructSig(src, scount - len + @as(u32, @intCast(i))) else s.objectCallSig(src, scount - len + @as(u32, @intCast(i)));
        const psig = if (is_construct) s.objectConstructSig(pattern, pcount - len + @as(u32, @intCast(i))) else s.objectCallSig(pattern, pcount - len + @as(u32, @intCast(i)));
        try c.inferFromExtends(ssig, psig, ids, vals, contra, depth + 1);
    }
}

/// Greedy pattern-match a concrete string against a template-literal
/// pattern, binding each `infer` hole (tsc's rules: a non-empty following
/// literal captures up to its *first* occurrence — lazy; the last hole
/// takes the remainder; two adjacent holes split one character to the
/// first). No backtracking (a documented simplification, exact for
/// the single-delimiter forms tsc users rely on).
pub fn inferFromTemplate(c: *Checker, text: []const u8, tpl: TypeId, ids: []const u32, vals: []TypeId) Error!void {
    const s = &c.ts;
    const head = c.atomText(s.templateHead(tpl));
    if (!std.mem.startsWith(u8, text, head)) return;
    const n = s.templateHoleCount(tpl);
    var pos: usize = head.len;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const hole = s.templateHole(tpl, i);
        const chunk = c.atomText(s.templateChunk(tpl, i));
        var cap_end: usize = undefined;
        if (i + 1 == n) {
            // Last hole: `chunk` is the tail literal; text must end with it.
            if (!std.mem.endsWith(u8, text[pos..], chunk)) return;
            cap_end = text.len - chunk.len;
        } else if (chunk.len == 0) {
            // Adjacent holes with no separator: capture one char.
            cap_end = @min(pos + 1, text.len);
        } else {
            const rel = std.mem.indexOf(u8, text[pos..], chunk) orelse return;
            cap_end = pos + rel;
        }
        const captured = text[pos..cap_end];
        try c.bindTemplateInfer(hole, captured, ids, vals);
        pos = cap_end + (if (i + 1 == n) chunk.len else if (chunk.len == 0) @as(usize, 0) else chunk.len);
    }
}

/// Bind the infer var(s) in a template hole to a captured substring. The
/// common case is a bare `infer X` (→ the string-literal of the capture);
/// a `string`/`number` typed hole binds nothing.
pub fn bindTemplateInfer(c: *Checker, hole: TypeId, captured: []const u8, ids: []const u32, vals: []TypeId) Error!void {
    const s = &c.ts;
    if (s.kind(hole) != .infer_var) return;
    const idx = indexOfId(ids, s.inferVarId(hole)) orelse return;
    const lit = try c.ts.makeStringLiteral(try c.internText(captured), false);
    if (vals[idx] == types.no_type) {
        vals[idx] = lit;
    } else {
        vals[idx] = try c.makeUnion2(vals[idx], lit);
    }
}

/// Infer from a template-literal *type* source into a template-literal
/// pattern — tsc's `inferTypesFromTemplateLiteralType` +
/// `inferFromLiteralPartsToTemplateLiteral`. The source contributes its fixed
/// text parts (`texts[0]` = head, `texts[i+1]` = the chunk after hole `i`)
/// and its placeholder types; `matchTemplateParts` produces one match type
/// per TARGET hole, and each is then inferred into that hole exactly as tsc
/// pairs `matches[i]` with `target.types[i]`. So
/// `` `owners.${number}.status` extends `${infer K}.${infer R}` `` binds
/// `K = "owners"` and `` R = `${number}.status` ``, and the recursive path
/// walk keeps going instead of collapsing to `never`.
pub fn inferFromTemplateSource(c: *Checker, src: TypeId, tpl: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    const gpa = c.scratch();
    const n = s.templateHoleCount(src);
    // Interned atom bytes are stable for the interner's lifetime, so the
    // text slices survive the atom-table growth `addMatch` triggers.
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(gpa);
    try texts.append(gpa, c.atomText(s.templateHead(src)));
    for (0..n) |i| {
        try holes.append(gpa, s.templateHole(src, @intCast(i)));
        try texts.append(gpa, c.atomText(s.templateChunk(src, @intCast(i))));
    }
    var matches: std.ArrayList(TypeId) = .empty;
    defer matches.deinit(gpa);
    if (!try c.matchTemplateParts(texts.items, holes.items, tpl, &matches)) return;
    for (matches.items, 0..) |m, i| {
        try c.inferFromExtends(m, s.templateHole(tpl, @intCast(i)), ids, vals, contra, depth + 1);
    }
}

/// The scan half of tsc's `inferFromLiteralPartsToTemplateLiteral`. Anchors
/// the target's leading/trailing fixed text, then walks the target's interior
/// delimiters left-to-right over the source's parts. A delimiter is only ever
/// found in source TEXT — a source placeholder (`${number}`) is opaque and
/// cannot be split by it, so a hole that spans one absorbs it whole and the
/// match is rebuilt as a template-literal type. Appends one match type per
/// target hole to `out`; returns false (inferring nothing) when the source
/// cannot match, matching tsc's `undefined`.
pub fn matchTemplateParts(c: *Checker, source_texts: []const []const u8, source_types: []const TypeId, tpl: TypeId, out: *std.ArrayList(TypeId)) Error!bool {
    const s = &c.ts;
    std.debug.assert(source_texts.len == source_types.len + 1);
    const m = s.templateHoleCount(tpl);
    if (m == 0) return false;
    const last_source = source_texts.len - 1;
    const target_start = c.atomText(s.templateHead(tpl));
    const target_end = c.atomText(s.templateChunk(tpl, m - 1));
    const source_start = source_texts[0];
    const source_end = source_texts[last_source];
    if (last_source == 0 and source_start.len < target_start.len + target_end.len) return false;
    if (!std.mem.startsWith(u8, source_start, target_start)) return false;
    if (!std.mem.endsWith(u8, source_end, target_end)) return false;

    var w: PartWalk = .{
        .c = c,
        .texts = source_texts,
        .types = source_types,
        .last = last_source,
        .remaining_end = source_end[0 .. source_end.len - target_end.len],
        .pos = target_start.len,
        .out = out,
    };
    var j: u32 = 0;
    while (j + 1 < m) : (j += 1) {
        const delim = c.atomText(s.templateChunk(tpl, j));
        if (delim.len > 0) {
            var si = w.seg;
            var p = w.pos;
            while (true) {
                const txt = w.sourceText(si);
                if (p <= txt.len) {
                    if (std.mem.indexOf(u8, txt[p..], delim)) |rel| {
                        p += rel;
                        break;
                    }
                }
                si += 1;
                if (si == source_texts.len) return false;
                p = 0;
            }
            try w.addMatch(si, p);
            w.pos += delim.len;
        } else if (w.pos < w.sourceText(w.seg).len) {
            // Adjacent target holes, source text left to split: one char.
            try w.addMatch(w.seg, w.pos + 1);
        } else if (w.seg < last_source) {
            // …otherwise the next hole absorbs the source's placeholder.
            try w.addMatch(w.seg + 1, 0);
        } else return false;
    }
    try w.addMatch(last_source, w.sourceText(last_source).len);
    return true;
}

/// tsc's tail of `getTemplateLiteralType`: a template whose text parts are
/// ALL empty is not a pattern at all, it is its hole. `` `${string}` `` (any
/// number of `string` holes) is exactly `string`, and a lone hole that is
/// itself a pattern (`` `${`a${number}`}` ``, `` `${Uppercase<T>}` ``) is
/// that pattern. Applied only to the types `matchTemplateParts` recombines,
/// so the shared `reduceTemplateChunks` evaluation point is untouched —
/// without it an `infer` hole would bind `` `${string}` `` where tsc binds
/// `string`, and the extra pattern wrapper would reject a plain `string`
/// downstream (a false positive).
pub fn normalizeTextlessTemplate(c: *Checker, t: TypeId) Error!TypeId {
    const s = &c.ts;
    if (s.kind(t) != .template_literal_type) return t;
    const n = s.templateHoleCount(t);
    if (c.atomText(s.templateHead(t)).len != 0) return t;
    for (0..n) |i| {
        if (c.atomText(s.templateChunk(t, @intCast(i))).len != 0) return t;
    }
    var all_string = true;
    for (0..n) |i| {
        if (s.kind(try c.resolveStructural(s.templateHole(t, @intCast(i)))) != .string) all_string = false;
    }
    if (all_string) return types.string_type;
    if (n == 1) {
        const hole = s.templateHole(t, 0);
        switch (s.kind(hole)) {
            .template_literal_type, .string_mapping => return hole,
            else => {},
        }
    }
    return t;
}

/// Cursor over a source template's (texts, types) parts: `seg` is the text
/// part the cursor sits in and `pos` the offset within it.
const PartWalk = struct {
    c: *Checker,
    texts: []const []const u8,
    types: []const TypeId,
    last: usize,
    /// The last text part with the target's trailing literal stripped; it is
    /// what `sourceText` reports for the final segment.
    remaining_end: []const u8,
    seg: usize = 0,
    pos: usize,
    out: *std.ArrayList(TypeId),

    fn sourceText(w: *const PartWalk, i: usize) []const u8 {
        return if (i < w.last) w.texts[i] else w.remaining_end;
    }

    /// Commit the span from (`seg`, `pos`) up to (`si`, `p`) as one target
    /// hole's match: a string literal when it stays inside one text part,
    /// otherwise a template-literal type recombining the crossed text and
    /// placeholder parts.
    fn addMatch(w: *PartWalk, si: usize, p: usize) Error!void {
        const c = w.c;
        const gpa = c.scratch();
        var match: TypeId = undefined;
        if (si == w.seg) {
            match = try c.ts.makeStringLiteral(try c.internText(w.sourceText(si)[w.pos..p]), false);
        } else {
            var chunks: std.ArrayList(Atom) = .empty;
            defer chunks.deinit(gpa);
            var k = w.seg + 1;
            while (k < si) : (k += 1) try chunks.append(gpa, try c.internText(w.texts[k]));
            try chunks.append(gpa, try c.internText(w.sourceText(si)[0..p]));
            const head = try c.internText(w.texts[w.seg][w.pos..]);
            match = try c.normalizeTextlessTemplate(try c.reduceTemplateChunks(head, w.types[w.seg..si], chunks.items));
        }
        try w.out.append(gpa, match);
        w.seg = si;
        w.pos = p;
    }
};

/// Does `t` hold an unbound `infer` binder — tsc's `couldContainTypeVariables`
/// for the inference target. Memoized in the dense `ci_cache`: types are
/// immutable and the walk is a pure structural descent, and `inferFromExtends`
/// asks it once per step.
pub fn containsInfer(c: *Checker, t: TypeId) Error!bool {
    const v = c.triGet(&c.ci_cache, t);
    if (v != 0) return v == 2;
    const r = try containsInferInner(c, t);
    try c.triSet(&c.ci_cache, t, if (r) 2 else 1);
    return r;
}

fn containsInferInner(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    return switch (s.kind(t)) {
        .infer_var => true,
        .array => c.containsInfer(s.arrayElem(t)),
        .union_type, .intersection, .overloads => blk: {
            for (0..s.memberCount(t)) |i| {
                if (try c.containsInfer(s.memberAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        .tuple => blk: {
            for (0..s.tupleLen(t)) |i| {
                if (try c.containsInfer(s.tupleElem(t, @intCast(i)).ty)) break :blk true;
            }
            break :blk false;
        },
        .object => blk: {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.containsInfer(s.objectProp(t, @intCast(i)).ty)) break :blk true;
            }
            if (s.objectStringIndex(t) != 0 and try c.containsInfer(s.objectStringIndex(t))) break :blk true;
            if (s.objectNumberIndex(t) != 0 and try c.containsInfer(s.objectNumberIndex(t))) break :blk true;
            for (0..s.objectCallSigCount(t)) |i| {
                if (try c.containsInfer(s.objectCallSig(t, @intCast(i)))) break :blk true;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (try c.containsInfer(s.objectConstructSig(t, @intCast(i)))) break :blk true;
            }
            break :blk false;
        },
        .function => blk: {
            if (try c.containsInfer(s.fnReturn(t))) break :blk true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.containsInfer(s.fnParam(t, @intCast(i)).ty)) break :blk true;
            }
            break :blk false;
        },
        .ref => blk: {
            for (0..s.refArgCount(t)) |i| {
                if (try c.containsInfer(s.refArgAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        .conditional => blk: {
            if (try c.containsInfer(s.condCheck(t))) break :blk true;
            if (try c.containsInfer(s.condExtends(t))) break :blk true;
            if (try c.containsInfer(s.condTrue(t))) break :blk true;
            if (try c.containsInfer(s.condFalse(t))) break :blk true;
            break :blk false;
        },
        .template_literal_type => blk: {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.containsInfer(s.templateHole(t, @intCast(i)))) break :blk true;
            }
            break :blk false;
        },
        .string_mapping => c.containsInfer(s.stringMappingArg(t)),
        .keyof_op => c.containsInfer(s.keyofOperand(t)),
        // A deferred mapped type / indexed access may carry an `infer` var in
        // its key source or value; `substInfer` descends into both (their
        // `.mapped` / `.index_access` arms), so this predicate must see them.
        .mapped => blk: {
            if (try c.containsInfer(s.mappedConstraint(t))) break :blk true;
            if (try c.containsInfer(s.mappedValue(t))) break :blk true;
            if (s.mappedAs(t) != 0 and try c.containsInfer(s.mappedAs(t))) break :blk true;
            if (s.mappedSource(t) != 0 and try c.containsInfer(s.mappedSource(t))) break :blk true;
            break :blk false;
        },
        .index_access => blk: {
            if (try c.containsInfer(s.indexAccessObj(t))) break :blk true;
            if (try c.containsInfer(s.indexAccessIndex(t))) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Replace `infer` binders (`ids[i]`) with their inferred `vals[i]`.
pub fn substInfer(c: *Checker, t: TypeId, ids: []const u32, vals: []const TypeId) Error!TypeId {
    if (ids.len == 0 or !try c.containsInfer(t)) return t;
    const s = &c.ts;
    switch (s.kind(t)) {
        .infer_var => {
            const idx = indexOfId(ids, s.inferVarId(t)) orelse return t;
            return vals[idx];
        },
        .array => return s.makeArrayLike(t, try c.substInfer(s.arrayElem(t), ids, vals)),
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
            return s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
            return s.makeIntersection(c.scratch(), parts.items);
        },
        .overloads => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substInfer(m, ids, vals));
            return s.makeOverloads(parts.items);
        },
        .tuple => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try c.substInfer(e.ty, ids, vals), .flags = e.flags });
            }
            return s.makeTuple(elems.items);
        },
        .object => {
            var props: std.ArrayList(types.Prop) = .empty;
            defer props.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try props.append(c.scratch(), .{ .name = p.name, .ty = try c.substInfer(p.ty, ids, vals), .flags = p.flags });
            }
            const sidx = if (s.objectStringIndex(t) != 0) try c.substInfer(s.objectStringIndex(t), ids, vals) else 0;
            const nidx = if (s.objectNumberIndex(t) != 0) try c.substInfer(s.objectNumberIndex(t), ids, vals) else 0;
            // Preserve and substitute call/construct signatures — dropping
            // them (the old `makeObject` path) lost the inferred `new (props:
            // P) => …` shape needed to decide a construct-pattern conditional.
            if (s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0)
                return s.makeObject(props.items, sidx, nidx, s.objectFlags(t));
            var call_sigs: std.ArrayList(TypeId) = .empty;
            defer call_sigs.deinit(c.scratch());
            var construct_sigs: std.ArrayList(TypeId) = .empty;
            defer construct_sigs.deinit(c.scratch());
            for (0..s.objectCallSigCount(t)) |i| try call_sigs.append(c.scratch(), try c.substInfer(s.objectCallSig(t, @intCast(i)), ids, vals));
            for (0..s.objectConstructSigCount(t)) |i| try construct_sigs.append(c.scratch(), try c.substInfer(s.objectConstructSig(t, @intCast(i)), ids, vals));
            return s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
        },
        .function => {
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substInfer(p.ty, ids, vals), .flags = p.flags });
            }
            const ret = try c.substInfer(s.fnReturn(t), ids, vals);
            const this_ty = s.fnThisType(t);
            return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, if (this_ty != 0) try c.substInfer(this_ty, ids, vals) else 0);
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substInfer(a, ids, vals));
            return s.makeRef(s.refSymbol(t), args.items);
        },
        .conditional => {
            // Distribution over an `infer`-var check that resolves to a
            // union (mirrors the naked type-param path in `instantiateId`):
            // a distributive conditional whose check *is* one of the infer
            // vars being substituted must re-bind that var per union member
            // so the true/false branches reflect each member — not the whole
            // union. Substituting the branches with the whole union first
            // (the general path below) bakes `Draft<V>` into
            // `Draft<Error | null>` before it can distribute, which is what
            // broke immer's `WritableNonArrayDraft` value type
            // (`T[K] extends infer V ? V extends object ? Draft<V> : V
            // : never`): the inner `V extends object` is a distributive
            // infer-var check.
            const check0 = s.condCheck(t);
            if (s.condDistributive(t) and s.kind(check0) == .infer_var) {
                if (indexOfId(ids, s.inferVarId(check0))) |vi| {
                    const cv = vals[vi];
                    if (s.kind(cv) == .union_type) {
                        var parts: std.ArrayList(TypeId) = .empty;
                        defer parts.deinit(c.scratch());
                        const vals2 = try c.scratch().dupe(TypeId, vals);
                        for (try c.memberList(cv)) |m| {
                            vals2[vi] = m;
                            try parts.append(c.scratch(), try c.substInfer(t, ids, vals2));
                        }
                        return s.makeUnion(c.scratch(), parts.items);
                    }
                }
            }
            const chk = try c.substInfer(check0, ids, vals);
            const ext = try c.substInfer(s.condExtends(t), ids, vals);
            // Decide FIRST, substitute the winning branch only — the same
            // split `instantiateId`'s `.conditional` arm makes, and for the
            // same reason. This arm is reached with a whole FALL-THROUGH
            // CHAIN under it: an enclosing conditional bound an `infer` var
            // (`CTE extends (creator: …) => infer Q ? <chain> : never`), and
            // the chain's branches were built while `Q` was still unbound, so
            // every level deferred symbolically and the chain is one
            // conditional nested in the next one's FALSE branch. Substituting
            // both branches before reducing evaluates that chain
            // bottom-up — the LAST alternative's relation runs first and every
            // alternative runs, even though the answer is the first one that
            // matches.
            //
            // kysely's `ExtractRowFromCommonTableExpression<CTE>` is four
            // alternatives deep (`Expression`, then the Insert/Update/Delete
            // builders), and an INSERT-shaped CTE — which matches the second —
            // still paid for the third and the fourth: 204 expansions of
            // `DeleteQueryBuilder` over a 60-table schema in a program with no
            // `deleteFrom` in it, 195,201 node visits of a single
            // `instantiateSigForCall` of `QueryCreator.with<N, E>` that
            // charged 272,523 against a 250,000 budget. A SELECT-shaped CTE
            // matches the FIRST alternative and never showed it.
            const plan = try c.planConditional(chk, ext, s.condDistributive(t));
            switch (plan) {
                .value => |v| return v,
                .take_false => return c.substInfer(s.condFalse(t), ids, vals),
                .take_true => |b| return c.condTrueBranch(b, try c.substInfer(s.condTrue(t), ids, vals)),
                .both_any, .need_both => {
                    const tru = try c.substInfer(s.condTrue(t), ids, vals);
                    const fls = try c.substInfer(s.condFalse(t), ids, vals);
                    return c.finishCondPlan(plan, chk, ext, tru, fls, s.condDistributive(t));
                },
            }
        },
        .index_access => {
            const obj = try c.substInfer(s.indexAccessObj(t), ids, vals);
            const idx = try c.substInfer(s.indexAccessIndex(t), ids, vals);
            return c.reduceIndexedAccess(obj, idx);
        },
        .template_literal_type => {
            var holes: std.ArrayList(TypeId) = .empty;
            defer holes.deinit(c.scratch());
            for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.substInfer(s.templateHole(t, @intCast(i)), ids, vals));
            return c.reduceTemplate(s.templateHead(t), holes.items, t);
        },
        .string_mapping => return c.applyStringMapping(s.stringMappingKind(t), try c.substInfer(s.stringMappingArg(t), ids, vals)),
        .keyof_op => return c.keyofType(try c.substInfer(s.keyofOperand(t), ids, vals)),
        // Re-enter `reduceMapped` with the branches' `infer` vars bound: a
        // mapped alias deferred while its key source was still an `infer` var
        // (see `reduceMapped`) now materializes its key set. Without this arm
        // the map falls through unchanged and stays `{}`.
        .mapped => {
            const kp = s.mappedKeyParam(t); // key param identity is stable
            const con = try c.substInfer(s.mappedConstraint(t), ids, vals);
            const val = try c.substInfer(s.mappedValue(t), ids, vals);
            const as_c = if (s.mappedAs(t) != 0) try c.substInfer(s.mappedAs(t), ids, vals) else 0;
            const src = if (s.mappedSource(t) != 0) try c.substInfer(s.mappedSource(t), ids, vals) else 0;
            return c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
        },
        else => return t,
    }
}

// =====================================================================
// mapped types
// =====================================================================

/// Dense, stable id for a mapped type's key parameter `K`, keyed by the
/// mapped-type nodeKey. Mapped nodes are excluded from the type-node memo,
/// so the node may be re-evaluated — the id must be stable across calls.
pub fn mappedKeyId(c: *Checker, node: Node) Error!u32 {
    const gop = try c.mapped_key_ids.getOrPut(c.cm(), c.nodeKey(node));
    if (!gop.found_existing) {
        gop.value_ptr.* = c.mapped_key_next;
        c.mapped_key_next += 1;
    }
    return gop.value_ptr.*;
}

pub fn mappedTypeFromNode(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const m = c.tree.extraData(ast.MappedTypeData, d.lhs);
    const key_name = try c.atomOfToken(m.key_name_token);
    const key_id = try c.mappedKeyId(node);
    const key_param = try c.ts.makeMappedParam(key_id, key_name);

    var flags: u32 = m.flags;
    // Homomorphic detection: the constraint is syntactically `keyof X`.
    // Store `X` as the src_type (so its per-prop modifiers and array/tuple-
    // ness can be preserved) rather than pre-evaluating `keyof X`, which
    // would collapse to `never` while `X` is a generic parameter.
    var src_type: TypeId = 0;
    var constraint: TypeId = 0;
    if (c.nodeTag(m.constraint) == .keyof_type) {
        flags |= types.mapped_flag_homomorphic;
        src_type = try c.typeFromTypeNode(c.tree.nodeData(m.constraint).lhs);
    } else {
        constraint = try c.typeFromTypeNode(m.constraint);
    }

    // The key parameter is in scope in the `as` and value branches only
    // (never in the constraint), so evaluate those with it PUSHED. Pushing
    // rather than overwriting is what lets a mapped type nested in this
    // one's value still see `key_name` (see `Checker.mapped_key_scopes`).
    const saved_keys = c.mapped_key_scopes.items.len;
    try c.mapped_key_scopes.append(c.cm(), .{
        .name = key_name,
        .ty = key_param,
        .infer_depth = c.infer_scopes.items.len,
    });
    const as_clause = if (m.as_type != null_node) try c.typeFromTypeNode(m.as_type) else 0;
    const value = if (m.value != null_node) try c.typeFromTypeNode(m.value) else types.any_type;
    c.mapped_key_scopes.shrinkRetainingCapacity(saved_keys);

    return c.reduceMapped(key_param, constraint, value, as_clause, src_type, flags);
}

/// The single evaluation point for a mapped type (build time + each
/// instantiation): defer while the key set is still generic, else
/// materialize. Counted against the TS2589 depth/count budget.
pub fn reduceMapped(c: *Checker, key_param: TypeId, constraint: TypeId, value: TypeId, as_clause: TypeId, src_type: TypeId, flags: u32) Error!TypeId {
    if (c.inst_depth > max_instantiation_depth or c.inst_count > c.inst_budget) {
        c.inst_limit_tripped = true;
        if (c.instDiagAllowed()) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return types.error_type;
    }
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    const homomorphic = flags & types.mapped_flag_homomorphic != 0;
    // Deferral is decided by the *key set* only: the value/`as` branches may
    // still be generic (they materialize into generic-typed props). The key
    // set of a homomorphic map is literally `keyof src` — NOT `src` itself.
    // A concrete-keyed source with still-generic *values* (e.g.
    // `Partial<Impl<T>>` where `Impl<T>`'s props are as-yet-unreduced
    // conditionals from a recursive `Merge<…>`) has a fully concrete key set
    // and MUST materialize; testing `src` directly saw the free type params
    // buried in those value branches and stranded the whole map deferred as
    // `{ [P in keyof {…}]: … }`, dropping every member (react-hook-form
    // `FieldErrors<Form>` collapsing to just its `{form?;root?}` constituent).
    // `keyofType` yields a concrete literal union for an object/array/tuple
    // source and a deferred `keyof T` (which the tests below still flag) for a
    // naked type param / index / conditional — so genericness is judged on the
    // keys alone. The non-homomorphic key source is the constraint directly.
    // The map stays deferred while its key set mentions a free type param OR
    // an as-yet-unbound `infer` var. The `infer`-var case arises when a mapped
    // alias is applied to an infer var of an enclosing conditional
    // (`Rec<…> = … ? Acc & F<Head> : Acc`, F a mapped alias): `keyof (Acc &
    // F<Head>)` carries `keyof Head`, so `containsInfer` keeps it deferred and
    // `substInfer` (its `.mapped` arm) re-enters here once `Head` binds.
    const key_src = if (homomorphic) try c.keyofType(src_type) else constraint;
    // …and while it still mentions an ENCLOSING mapped type's key parameter.
    // `K` is not a free type param (it is locally bound, like an `infer`
    // var), so a nested map whose source is the outer map's `T[K]`
    // (`{ [K in keyof T]: { [J in keyof T[K]]: … } }` — react-hook-form's
    // `DeepRequired<T>` recursing through `DeepRequired<T[K]>`) looked
    // concrete: `keyof T[K]` is a deferred `keyof` over a deferred indexed
    // access with no free param in it, so the map materialized against an
    // unresolvable source and collapsed to `{}` before `K` was ever bound.
    // Deferring here parks it until `substMappedKey`'s `.mapped` arm binds
    // `K` and re-enters with a concrete source.
    const key_generic = try c.containsFreeTypeParam(key_src, &.{}) or
        try c.containsInfer(key_src) or
        try c.containsMappedParam(key_src);
    // …and while the `as` REMAP cannot be decided. The key set is only half of
    // what materialization needs: `remapKey` evaluates the remap once per key
    // and DROPS any key whose remap does not reduce to a literal or `never`,
    // so an `as` clause that still mentions a free type param — `{ [K in keyof
    // A as K extends keyof B ? never : K]: A[K] }` with `B` not yet bound, the
    // `Omit`-by-another-shape idiom — deletes EVERY key instead of deferring.
    // The key set is concrete there (`A` is bound), so nothing above catches
    // it. zod's `util.Extend` is written exactly that way and is applied inside
    // `ZodObject.extend<U>(shape: U): ZodObject<Extend<Shape, U>>`, where
    // `Shape` is bound at the receiver and `U` only at the call: every property
    // an overriding `.extend({…})` did NOT redeclare vanished from the schema
    // (immich's `LargeAssetSearchDto` lost `visibility` and `withDeleted`,
    // while its sibling `RandomSearchDto` — whose extension adds only NEW keys,
    // taking `Extend`'s `A & B` branch — kept them).
    //
    // Only FREE TYPE PARAMS count. The map's own key parameter is a
    // `.mapped_param` and is bound here; an `infer` binder written INSIDE the
    // remap (`{ [E in SE as E extends A<infer X> ? X : never]: … }`,
    // conformance mapped/061) binds per key when the remap is evaluated, so
    // neither is a reason to defer — only a parameter nothing here can supply.
    const as_generic = as_clause != 0 and try c.containsFreeTypeParam(as_clause, &.{});
    if (key_generic or as_generic) {
        return c.ts.makeMapped(key_param, constraint, value, as_clause, src_type, flags);
    }
    return c.materializeMapped(key_param, constraint, value, as_clause, src_type, flags);
}

pub fn applyPropModifiers(base: u32, flags: u32) u32 {
    var f = base;
    if (flags & types.mapped_flag_readonly_add != 0) f |= types.prop_flag_readonly;
    if (flags & types.mapped_flag_readonly_remove != 0) f &= ~types.prop_flag_readonly;
    if (flags & types.mapped_flag_optional_add != 0) f |= types.prop_flag_optional;
    if (flags & types.mapped_flag_optional_remove != 0) f &= ~types.prop_flag_optional;
    return f;
}

pub fn applyElemModifiers(base: u32, flags: u32) u32 {
    var f = base;
    if (flags & types.mapped_flag_readonly_add != 0) f |= types.elem_flag_readonly;
    if (flags & types.mapped_flag_readonly_remove != 0) f &= ~types.elem_flag_readonly;
    if (flags & types.mapped_flag_optional_add != 0) f |= types.elem_flag_optional;
    if (flags & types.mapped_flag_optional_remove != 0) f &= ~types.elem_flag_optional;
    return f;
}

/// Kinds a homomorphic mapped type maps to THEMSELVES (tsc: everything
/// outside `AnyOrUnknown | InstantiableNonPrimitive | Object |
/// Intersection` is returned unchanged by `instantiateMappedType`).
/// The `object` keyword (`NonPrimitive`) and the string-flavoured
/// instantiables `string_mapping` / `template_literal_type`
/// (`InstantiablePrimitive`, not `…NonPrimitive`) are on this side of
/// tsc's test too, so they pass through as well. Modifiers (`?`, `-?`,
/// `readonly`) are irrelevant: there are no properties to modify.
pub fn isPrimitiveForHomomorphicMap(k: types.Kind) bool {
    return switch (k) {
        .never,
        .void,
        .undefined,
        .null,
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .object_keyword,
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
        => true,
        else => false,
    };
}

/// Materialize a concrete mapped type (its key set is known). Homomorphic
/// maps iterate the src_type's own members (preserving modifiers and
/// array/tuple-ness); others iterate the constraint's literal members.
pub fn materializeMapped(c: *Checker, key_param: TypeId, constraint: TypeId, value: TypeId, as_clause: TypeId, src_type: TypeId, flags: u32) Error!TypeId {
    const s = &c.ts;
    const key_id = s.mappedParamId(key_param);
    const homomorphic = flags & types.mapped_flag_homomorphic != 0;

    if (homomorphic) {
        const saved_hi = c.homo_index_mode;
        c.homo_index_mode = true;
        defer c.homo_index_mode = saved_hi;
        const src = try c.resolveStructural(src_type);
        // tsc's `instantiateMappedType`: a homomorphic map over a
        // *primitive* performs NO mapping — the result is simply the
        // source. Its rule is a positive test on the instantiated type
        // variable (`AnyOrUnknown | InstantiableNonPrimitive | Object |
        // Intersection` materializes, everything else is returned
        // unchanged), so `Partial<string>`/`Required<string>` are `string`,
        // not `{}`. ztsc used to fall through to `{}` here, which flipped
        // `T[K] extends object` from false to TRUE one level up:
        // react-hook-form's `DeepRequired<T>` (`T extends BrowserNativeObject
        // ? T : { [K in keyof T]-?: NonNullable<DeepRequired<T[K]>> }`) turned
        // every `string`/`number` form field into `{}`, so `FieldErrorsImpl`
        // picked its `Merge<FieldError, FieldErrorsImpl<{}>>` arm instead of
        // plain `FieldError` and every `FieldErrors<Form>` value printed as
        // `{ message?: unknown; ref?: unknown; … }`.
        if (isPrimitiveForHomomorphicMap(s.kind(src))) return src;
        switch (s.kind(src)) {
            .any, .err => return types.any_type,
            .array => {
                // A homomorphic map over an array yields an array; the
                // element is the value with `K` bound to the number index.
                const elem = try c.substMappedKey(value, key_id, types.number_type);
                return s.makeArray(elem);
            },
            .tuple => {
                var elems: std.ArrayList(types.TupleElem) = .empty;
                defer elems.deinit(c.scratch());
                for (0..s.tupleLen(src)) |i| {
                    const e = s.tupleElem(src, @intCast(i));
                    const key_lit = try s.makeNumberLiteral(@floatFromInt(i), false);
                    var et = try c.substMappedKey(value, key_id, key_lit);
                    // A REST slot stores its ARRAY type (`...string[]` holds
                    // `string[]`; every reader — `tupleElemTypeAt`,
                    // `indexedAccessType`'s numeric arm — unwraps it with
                    // `elemOfArrayish`). `T[i]` therefore hands back the
                    // ELEMENT type, which is the right thing to run the value
                    // template over (tsc's `instantiateMappedTupleType` maps a
                    // rest element's element type too) but the wrong thing to
                    // store back: dropping the wrapper made `Readonly<[U,
                    // ...U[]]>` come out `readonly [U, ...U]`, and every reader
                    // then unwrapped a non-array to nothing. Concretely, zod's
                    // `z.enum(['a','b','c'])` — whose `create` constrains its
                    // tuple by `Readonly<[U, ...U[]]>` — lost the contextual
                    // `U` for every element past the first, so the literals
                    // widened to `string` and `z.infer` gave `string` where the
                    // schema says `'a' | 'b' | 'c'`.
                    if (e.rest() and s.kind(e.ty) == .array) et = try s.makeArrayLike(e.ty, et);
                    try elems.append(c.scratch(), .{ .ty = et, .flags = applyElemModifiers(e.flags, flags) });
                }
                return s.makeTuple(elems.items);
            },
            .union_type => {
                // A homomorphic map distributes over a union source: tsc's
                // `mapType` yields `M<A> | M<B>` for `M<A | B>` (a homomorphic
                // mapped type — `{ [P in keyof T]: … }` — is applied to each
                // constituent). Without this a union source fell through to
                // `{}`, so `Readonly<A | B>` (react-pdf's `ImageProps =
                // ImageWithSrcProp | ImageWithSourceProp` read off a class
                // component's `props: Readonly<P>`) collapsed to `{}` and every
                // attribute read as excess against `IntrinsicAttributes & {}`.
                // Restricted to a union whose every constituent is a plain,
                // named-property object (no index signature): that is the
                // props-union case we need (react-pdf `ImageProps`), and it
                // keeps the map well-defined. A union of pure index-signature
                // objects (`Record<string,A> | Record<string,B>` — redux's
                // `SliceCaseReducers<State>` default, reached only when
                // `createSlice`'s reducer inference falls back to the
                // constraint) keeps the prior `{}` fallback: distributing it
                // would materialize a spurious `{ [x:string]: … }` that fails a
                // named-property target (a separate, pre-existing inference
                // gap). Under-report over a false positive.
                // Snapshot the members: the per-member recursion below
                // materializes new types, which may reallocate the type
                // store's member backing and invalidate a live `members(src)`
                // slice.
                const umembers = try c.scratch().dupe(TypeId, c.ts.members(src));
                var all_obj = true;
                for (umembers) |m| {
                    const rm = try c.resolveStructural(m);
                    // An intersection member (`PropsWithChildren<TextProps>` =
                    // `TextProps & {children?}`) is fine — its per-member map is
                    // the `.intersection` arm below. A plain object member must
                    // carry named props and NO index signature; a pure
                    // index-signature object (`Record<string,V>`) is the redux
                    // `SliceCaseReducers` fallback and must not distribute.
                    // A PRIMITIVE constituent is mapped to itself (tsc's rule,
                    // `isPrimitiveForHomomorphicMap`), so it neither needs nor
                    // prevents distribution — the recursion below returns it
                    // unchanged. Without this arm a single `null` in the union
                    // sank the whole map to `{}`: kysely's
                    // `Simplify<ShallowDehydrateObject<O>>` over an
                    // `O = AudioStreamInfo | null` (immich's
                    // `withAudioStream`, whose `$castTo` nullable row every
                    // `jsonObjectFrom` produces) came back `{} | null`.
                    const ok = s.kind(rm) == .intersection or
                        isPrimitiveForHomomorphicMap(s.kind(rm)) or
                        (s.kind(rm) == .object and
                            s.objectPropCount(rm) > 0 and
                            s.objectStringIndex(rm) == 0 and
                            s.objectNumberIndex(rm) == 0);
                    if (!ok) {
                        all_obj = false;
                        break;
                    }
                }
                if (all_obj) {
                    var parts: std.ArrayList(TypeId) = .empty;
                    defer parts.deinit(c.scratch());
                    for (umembers) |m| {
                        // Re-bind the source inside the value template per
                        // constituent. tsc distributes by instantiating the
                        // whole mapped type with `T := A`, so `T[P]` becomes
                        // `A[P]`; ztsc has already substituted `T`, so the
                        // union is baked into the value and passing it
                        // through unchanged resolves every property against
                        // the WHOLE union — `(A|B)["ax"]` is `unknown` and
                        // the discriminant widens to `"a" | "b"` on both
                        // constituents, so no discriminant / `in` narrowing
                        // can ever select a member.
                        const v = try c.substHomoSource(value, src_type, src, m);
                        try parts.append(c.scratch(), try c.materializeMapped(key_param, constraint, v, as_clause, m, flags));
                    }
                    return c.ts.makeUnion(c.scratch(), parts.items);
                }
                return types.empty_object_type;
            },
            .object, .intersection => {
                // A homomorphic map iterates the source's own members. An
                // intersection source (`{ [K in keyof (A & B)]: … }`) has
                // key set `keyof A | keyof B`; flatten every object
                // constituent's props so members of both survive — without
                // this the intersection fell through to `{}` and dropped
                // them all (e.g. `WithBaseUIEvent<ComponentPropsWithRef<'img'>>`,
                // whose argument is `ClassAttributes & ImgHTMLAttributes`).
                // An intersection constituent may be an ARRAY or a TUPLE
                // (`readonly [number, number] & { _brand }` — a branded
                // point). `collectHomoProps` only collects named props, so
                // the array half was dropped outright and `Mutable<Point>`
                // came out as just `{ _brand }`: no `length`, no element
                // access, not assignable to the tuple. Map each array-ish
                // constituent by its own rule and intersect the results
                // with the mapped named props. tsc instead materializes the
                // full apparent member set of the intersection (a numeric
                // index signature plus every `Array.prototype` member);
                // keeping the tuple/array shape is the same relation with a
                // far smaller type, and it prints as the source does.
                // The member slice is duplicated first: the per-constituent
                // recursion materializes new types and may reallocate the
                // store's member backing.
                var arrayish: std.ArrayList(TypeId) = .empty;
                defer arrayish.deinit(c.scratch());
                if (s.kind(src) == .intersection) {
                    const imembers = try c.scratch().dupe(TypeId, try c.memberList(src));
                    for (imembers) |m| {
                        const rm = try c.resolveStructural(m);
                        if (s.kind(rm) != .array and s.kind(rm) != .tuple) continue;
                        try arrayish.append(c.scratch(), try c.materializeMapped(key_param, constraint, value, as_clause, rm, flags));
                    }
                }
                var srcprops: std.ArrayList(types.Prop) = .empty;
                defer srcprops.deinit(c.scratch());
                try c.collectHomoProps(src, &srcprops);
                var props: std.ArrayList(types.Prop) = .empty;
                defer props.deinit(c.scratch());
                for (srcprops.items) |p| {
                    // A homomorphic map's key set IS `keyof src`, which
                    // excludes `private`/`protected` members — so a mapped
                    // type over a class has only its public surface, and
                    // nothing about the source's non-public members carries
                    // into it (see `prop_flag_non_public`).
                    if (p.nonPublic()) continue;
                    const key_lit = try s.makeStringLiteral(p.name, false);
                    const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                    const pt = try c.substMappedKey(value, key_id, key_lit);
                    try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(p.flags, flags) });
                }
                // Preserve the source's index signatures: a homomorphic map
                // over `Record<string, V>` / any index-signatured source
                // yields `{ [k: string]: mapped(V) }`, not `{}`. `keyof T`
                // for such a source includes `string`/`number`, so the value
                // `T[K]` is remapped with K bound to that primitive. An `as`
                // clause with no string-literal filter passes index keys
                // through unchanged (tsc keeps the signature). The optional
                // (`+?`) modifier bakes `| undefined` into the value type
                // (tsc's addOptionality for a mapped index info).
                var sindex: TypeId = 0;
                var nindex: TypeId = 0;
                if (as_clause == 0) {
                    var src_sidx: TypeId = 0;
                    var src_nidx: TypeId = 0;
                    try c.collectHomoIndex(src, &src_sidx, &src_nidx);
                    if (src_sidx != 0) {
                        var v = try c.substMappedKey(value, key_id, types.string_type);
                        if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                        sindex = v;
                    }
                    if (src_nidx != 0) {
                        var v = try c.substMappedKey(value, key_id, types.number_type);
                        if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                        nindex = v;
                    }
                }
                const empty = props.items.len == 0 and sindex == 0 and nindex == 0;
                if (arrayish.items.len == 0) {
                    const mapped = try c.objectFromProps(props.items, sindex, nindex);
                    // An enum-keyed member is NAMED by the enum only in a side
                    // table (see `carryKeyNameTypes`), so a homomorphic map
                    // over such a source — `Partial<Record<E, V>>` — has to
                    // bring the names across or `keyof` loses the enum. Only
                    // an un-remapped map keeps the key: an `as` clause names
                    // the property itself.
                    if (as_clause == 0) try c.carryKeyNameTypes(mapped, &.{src});
                    return mapped;
                }
                if (!empty) try arrayish.append(c.scratch(), try c.objectFromProps(props.items, sindex, nindex));
                return s.makeIntersection(c.scratch(), arrayish.items);
            },
            else => return types.empty_object_type,
        }
    }

    // Non-homomorphic: the key set is the constraint's members. An
    // intersection constraint (`keyof T & string` — the string-key filter
    // idiom) is simplified to the surviving literal members here; without
    // it the intersection fell through to `{}` (spurious TS2353/TS2339 on
    // legitimately-remapped keys — a false-positive fix).
    var keyset: std.ArrayList(TypeId) = .empty;
    defer keyset.deinit(c.scratch());
    try c.collectMappedKeys(constraint, &keyset);
    const keys = keyset.items;

    // Modifiers-type preservation for the `Pick`/`Omit` shape. When the
    // mapped value is `T[K]` (an indexed access whose index is this map's
    // key parameter), `T` is the modifiers type: a source prop's
    // optional/readonly modifier carries onto the mapped prop, mirroring how
    // tsc copies modifiers from a mapped type's modifiers type even for a
    // non-homomorphic `{ [P in K]: T[P] }` (`K extends keyof T`). Only ADDS
    // a base modifier (the map's own `+/-` still applies on top via
    // `applyPropModifiers`), so it can only relax an over-strict required
    // prop — never a new false positive. Without it, `Pick`/`Omit` props
    // read as required (spurious TS2739/TS2741).
    var mod_src: TypeId = 0;
    if (s.kind(value) == .index_access and s.kind(s.indexAccessIndex(value)) == .mapped_param) {
        var o = try c.resolveStructural(s.indexAccessObj(value));
        // tsc reads the modifiers type through `getApparentType`, so a still
        // GENERIC `T` answers from its constraint. That is the `Pick<T,
        // keyof Base>` written inside `<T extends Required<Omit<Base, "k">> &
        // { k?: … }>`: the key set is concrete (`keyof Base`) so the map
        // materializes, but the modifiers type is the bare type parameter and
        // failed the composite gate below — every picked prop read as
        // required, including the one the constraint declares optional
        // (spurious TS2741).
        if (s.kind(o) == .type_param) {
            const bc = try c.transitiveBaseConstraint(o);
            if (bc != o) o = try c.resolveStructural(bc);
        }
        // The modifiers type may be an object, an intersection of objects,
        // or a union of those (`Omit<Partial<Base> & (A|B|C), K>` —
        // react-hook-form `RegisterOptions` — whose intersection distributes
        // into a union). `propOfTypeEx` merges each constituent's
        // optional/readonly flags (required wins across an intersection,
        // optional wins across a union), so a source prop that is optional in
        // the `Partial<…>` constituent and absent elsewhere stays optional.
        // Without this the composite failed the `.object` gate, `mod_src`
        // stayed 0, and every Pick/Omit prop read as required (spurious
        // TS2739/TS2741 on `{ required }` → `RegisterOptions`).
        switch (s.kind(o)) {
            .object, .intersection, .union_type => mod_src = o,
            else => {},
        }
    }
    const mod_mask = types.prop_flag_optional | types.prop_flag_readonly;

    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    // Members whose NAME type is not the plain string literal of their atom —
    // an enum-keyed property, see the `.enum_type` arm below and
    // `Checker.key_name_types`.
    var name_types: std.ArrayList(types.Prop) = .empty;
    defer name_types.deinit(c.scratch());
    var sindex: TypeId = 0;
    var nindex: TypeId = 0;
    for (keys) |key_lit| {
        switch (s.kind(key_lit)) {
            .string => sindex = try c.substMappedKey(value, key_id, key_lit),
            .number => nindex = try c.substMappedKey(value, key_id, key_lit),
            // An enum MEMBER key (`collectMappedKeys`' `.enum_type` arm).
            // Keyed by the member's constant value, named by the member type
            // itself so `keyof` answers `E.A` and not `"a"`. A remap (`as`)
            // computes its own name and replaces the enum name outright, as
            // it does for every other key.
            .enum_type => {
                if (!s.isEnumMember(key_lit)) continue;
                const vname = (try c.literalKeyAtom(key_lit)) orelse continue;
                const name = if (as_clause == 0)
                    vname
                else
                    (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                const pt = try c.substMappedKey(value, key_id, key_lit);
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, name, false)) |sp| base = sp.flags & mod_mask;
                }
                try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) });
                if (as_clause == 0) try name_types.append(c.scratch(), .{ .name = name, .ty = key_lit });
            },
            .string_literal => {
                const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                const pt = try c.substMappedKey(value, key_id, key_lit);
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, s.literalAtom(key_lit), false)) |sp| base = sp.flags & mod_mask;
                }
                try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) });
            },
            .number_literal, .number_literal_fresh => {
                const nm = try c.numberLiteralAtom(key_lit);
                const pt = try c.substMappedKey(value, key_id, key_lit);
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, nm, false)) |sp| base = sp.flags & mod_mask;
                }
                try props.append(c.scratch(), .{ .name = nm, .ty = pt, .flags = applyPropModifiers(base, flags) });
            },
            // A key that is not usable as a property name on its own. With
            // an `as` clause it still names a property: tsc's
            // `addMemberForKeyType` computes the name by instantiating the
            // name type with the key and only then asks whether the RESULT
            // is usable, so the key itself may be any type at all.
            //
            // kysely's `Selection<DB, TB, SE> = { [E in SE as
            // ExtractAliasFromSelectExpression<E>]: … }` iterates SELECT
            // EXPRESSIONS — column strings, aliased-expression objects, and
            // `(eb) => …` callbacks — and reads each one's column alias out
            // of it with a conditional. Skipping every non-literal key
            // dropped the object and callback forms outright, so
            // `.select((eb) => ….as('stack'))` contributed nothing to the
            // row type and every later read of that column was a TS2339.
            // Without an `as` clause there is nothing to derive a name
            // from, and a non-key member (a symbol, an object) is skipped
            // as before.
            else => {
                if (as_clause == 0) continue;
                const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                const pt = try c.substMappedKey(value, key_id, key_lit);
                try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(0, flags) });
            },
        }
    }
    if (props.items.len == 0 and sindex == 0 and nindex == 0) return types.empty_object_type;
    const obj = try s.makeObject(props.items, sindex, nindex, 0);
    for (name_types.items) |nt| {
        try c.putKeyNameType(obj, nt.name, nt.ty);
    }
    return obj;
}

/// Re-bind a homomorphic mapped type's SOURCE inside its value template
/// when the map distributes over a union source: replace `from` (the source
/// as written, e.g. a `ref` to the alias) and `from_res` (its structural
/// resolution, the union itself) with the single constituent `to`.
///
/// Deliberately narrow — only the type forms a mapped value template
/// actually takes are rewritten (`T[P]`, and that wrapped in
/// array/union/intersection/ref-arg/conditional/`keyof`). Anything else is
/// returned untouched, which is exactly the behaviour before this existed.
pub fn substHomoSource(c: *Checker, t: TypeId, from: TypeId, from_res: TypeId, to: TypeId) Error!TypeId {
    if (t == from or t == from_res) return to;
    const s = &c.ts;
    switch (s.kind(t)) {
        .index_access => {
            const obj = try c.substHomoSource(s.indexAccessObj(t), from, from_res, to);
            const idx = try c.substHomoSource(s.indexAccessIndex(t), from, from_res, to);
            if (obj == s.indexAccessObj(t) and idx == s.indexAccessIndex(t)) return t;
            return c.reduceIndexedAccess(obj, idx);
        },
        .array => {
            const e = try c.substHomoSource(s.arrayElem(t), from, from_res, to);
            return if (e == s.arrayElem(t)) t else s.makeArrayLike(t, e);
        },
        .union_type, .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            var changed = false;
            for (try c.memberList(t)) |m| {
                const nm = try c.substHomoSource(m, from, from_res, to);
                if (nm != m) changed = true;
                try parts.append(c.scratch(), nm);
            }
            if (!changed) return t;
            return if (s.kind(t) == .union_type)
                s.makeUnion(c.scratch(), parts.items)
            else
                s.makeIntersection(c.scratch(), parts.items);
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            var changed = false;
            for (try c.refArgsList(t)) |a| {
                const na = try c.substHomoSource(a, from, from_res, to);
                if (na != a) changed = true;
                try args.append(c.scratch(), na);
            }
            if (!changed) return t;
            return s.makeRef(s.refSymbol(t), args.items);
        },
        .conditional => {
            const chk = try c.substHomoSource(s.condCheck(t), from, from_res, to);
            const ext = try c.substHomoSource(s.condExtends(t), from, from_res, to);
            const tru = try c.substHomoSource(s.condTrue(t), from, from_res, to);
            const fls = try c.substHomoSource(s.condFalse(t), from, from_res, to);
            if (chk == s.condCheck(t) and ext == s.condExtends(t) and
                tru == s.condTrue(t) and fls == s.condFalse(t)) return t;
            return c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
        },
        .keyof_op => {
            const o = try c.substHomoSource(s.keyofOperand(t), from, from_res, to);
            return if (o == s.keyofOperand(t)) t else c.keyofType(o);
        },
        else => return t,
    }
}

/// Collect the distinct own props of an objectish source (object, or an
/// intersection of objects) for a homomorphic mapped type's key iteration.
/// The first occurrence of each name wins its modifier flags; the mapped
/// value is recomputed per key against the whole source, so a colliding
/// name's property type stays correct regardless of which flags are kept.
pub fn collectHomoProps(c: *Checker, t: TypeId, out: *std.ArrayList(types.Prop)) Error!void {
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => {
            for (0..c.ts.objectPropCount(r)) |i| {
                const p = c.ts.objectProp(r, @intCast(i));
                for (out.items) |*o| {
                    if (o.name == p.name) break;
                } else try out.append(c.scratch(), p);
            }
        },
        .intersection => {
            for (try c.memberList(r)) |m| try c.collectHomoProps(m, out);
        },
        else => {},
    }
}

/// Collect the string/number index-signature value types of a homomorphic
/// mapped source (object, or an intersection of objects). Sets `*sidx` /
/// `*nidx` to the source's index value type when present (first constituent
/// wins — intersection index-value merging is a rare edge left to the
/// source shape). Used so a homomorphic map preserves index signatures.
pub fn collectHomoIndex(c: *Checker, t: TypeId, sidx: *TypeId, nidx: *TypeId) Error!void {
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => {
            if (sidx.* == 0) sidx.* = c.ts.objectStringIndex(r);
            if (nidx.* == 0) nidx.* = c.ts.objectNumberIndex(r);
        },
        .intersection => {
            for (try c.memberList(r)) |m| try c.collectHomoIndex(m, sidx, nidx);
        },
        else => {},
    }
}

/// Flatten a non-homomorphic mapped-type constraint into its concrete key
/// members for `materializeMapped`'s prop loop. A union contributes each
/// member; a bare `string`/`number`/literal contributes itself; an
/// intersection `(K1|K2|…) & string` (the `keyof T & string` idiom that
/// filters `keyof T` to its string-named keys) contributes the union
/// literals that survive the primitive filter — string literals pass a
/// `string` filter, number literals a `number` filter. This mirrors tsc's
/// simplification of `("a"|"b") & string` to `"a"|"b"`.
pub fn collectMappedKeys(c: *Checker, constraint0: TypeId, out: *std.ArrayList(TypeId)) Error!void {
    const s = &c.ts;
    const constraint = try c.resolveStructural(constraint0);
    switch (s.kind(constraint)) {
        .union_type => for (try c.memberList(constraint)) |m| try c.collectMappedKeys(m, out),
        .intersection => {
            var want_string = false;
            var want_number = false;
            var want_symbol = false;
            var cands: std.ArrayList(TypeId) = .empty;
            defer cands.deinit(c.scratch());
            for (try c.memberList(constraint)) |m0| {
                const m = try c.resolveStructural(m0);
                switch (s.kind(m)) {
                    .string => want_string = true,
                    .number => want_number = true,
                    .symbol => want_symbol = true,
                    .union_type => for (try c.memberList(m)) |lm| try cands.append(c.scratch(), lm),
                    else => try cands.append(c.scratch(), m),
                }
            }
            for (cands.items) |cand| {
                const keep = switch (s.kind(try c.resolveStructural(cand))) {
                    .string_literal => !want_number and !want_symbol,
                    .number_literal, .number_literal_fresh => !want_string and !want_symbol,
                    else => false,
                };
                if (keep) try out.append(c.scratch(), cand);
            }
        },
        // An enum key domain (`{ [P in E]: V }` / `Record<E, V>`) enumerates
        // the enum's MEMBER types, one key each — tsc's own reading, where a
        // whole enum simply IS the union of its members. `materializeMapped`
        // then keys each property by the member's constant VALUE (the atom
        // `literalKeyAtom` gives, which is what a computed enum key
        // `[E.A]` is keyed by everywhere else) and NAMES it with the member
        // type through `key_name_types`, so `keyof Record<E, V>` reports
        // `E.A | E.B`.
        //
        // This used to emit a single INDEX signature (`string` for a string
        // enum, `number` for a numeric one) on the reasoning that a computed
        // enum key was keyed by a text-derived placeholder rather than by
        // member value. It is not — `constSymbolKeyAtom` resolves it to the
        // value — and the index signature cost `keyof` the enum: `keyof M`
        // for an `interface M extends Record<E, …>` came back
        // `string | number`, so a `<T extends keyof M>` parameter no longer
        // satisfied `T extends E` and every kysely column typed by such a key
        // was rejected (immich `user.repository.ts`'s `upsertMetadata`).
        //
        // A member whose value is COMPUTED has no key atom at all, so an enum
        // carrying one keeps the index-signature fallback rather than
        // silently dropping keys.
        .enum_type => {
            if (s.isEnumMember(constraint)) {
                try out.append(c.scratch(), constraint);
                return;
            }
            const sym = s.enumSymbol(constraint);
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            var collect: EnumMemberCollect = .{ .c = c, .list = &list, .sym = sym };
            try c.eachEnumMember(sym, &collect, EnumMemberCollect.visit);
            var all_named = list.items.len > 0;
            for (list.items) |m| {
                if ((try c.literalKeyAtom(m)) == null) {
                    all_named = false;
                    break;
                }
            }
            if (all_named) {
                try out.appendSlice(c.scratch(), list.items);
                return;
            }
            const info = try c.enumInfo(sym);
            try out.append(c.scratch(), if (info.all_string) types.string_type else types.number_type);
        },
        else => try out.append(c.scratch(), constraint),
    }
}

/// Build an object from possibly-duplicate-named props (later wins), then
/// intern. `as` remapping can collide keys, so dedup by name here.
/// `sindex`/`nindex` carry the string/number index-signature value types
/// (0 = none) — a homomorphic mapped type over an index-signatured source
/// must preserve those signatures, not just the named props.
pub fn objectFromProps(c: *Checker, props: []const types.Prop, sindex: TypeId, nindex: TypeId) Error!TypeId {
    var index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer index.deinit(c.scratch());
    var out: std.ArrayList(types.Prop) = .empty;
    defer out.deinit(c.scratch());
    for (props) |p| {
        if (index.get(p.name)) |i| {
            out.items[i] = p;
        } else {
            try index.put(c.scratch(), p.name, @intCast(out.items.len));
            try out.append(c.scratch(), p);
        }
    }
    return c.ts.makeObject(out.items, sindex, nindex, 0);
}

/// Resolve a mapped type's `as` remap for one src_type key. Returns the new
/// property-name atom, or `null` when the key should be filtered out (the
/// remap evaluates to `never` — the `Omit`/key-filter idiom). With no `as`
/// clause the original key name is kept. A template-literal `as` clause
/// (`` as `get${Capitalize<K & string>}` ``) reduces through
/// `substMappedKey` to a concrete string-literal before reaching here.
pub fn remapKey(c: *Checker, as_clause: TypeId, key_id: u32, key_lit: TypeId) Error!?Atom {
    if (as_clause == 0) return c.ts.literalAtom(key_lit);
    const nk0 = try c.substMappedKey(as_clause, key_id, key_lit);
    const nk = try c.resolveStructural(nk0);
    return switch (c.ts.kind(nk)) {
        .never => null, // filtered
        .string_literal => c.ts.literalAtom(nk),
        .number_literal, .number_literal_fresh => try c.numberLiteralAtom(nk),
        else => null, // non-static key (union/template pattern/string) — dropped
    };
}

pub fn numberLiteralAtom(c: *Checker, lit: TypeId) Error!Atom {
    var buf: [32]u8 = undefined;
    const v = c.ts.numberValue(lit);
    const txt = if (v == @floor(v) and std.math.isFinite(v))
        std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch return c.atom("0")
    else
        std.fmt.bufPrint(&buf, "{d}", .{v}) catch return c.atom("0");
    // `txt` is a stack-buffer slice — intern (copy) rather than caching the
    // transient slice as an `atom_cache` key.
    return c.internText(txt);
}

/// `Obj[Idx]`: defer while the index is still a mapped key parameter (or
/// either side still mentions one), so a mapped value `T[K]` stays symbolic
/// until each key is materialized; otherwise resolve concretely.
pub fn reduceIndexedAccess(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
    // Mapped-internal `T[K]`: stays symbolic until each key is
    // materialized. Checked first because a `mapped_param` is not a free
    // type param (so `containsTypeParam` would miss it).
    if (try c.containsMappedParam(idx) or try c.containsMappedParam(obj)) {
        return c.ts.makeIndexAccess(obj, idx);
    }
    // An as-yet-unbound `infer` var in the index is the same situation: in
    // tsc an `infer` binder IS a TypeParameter, so `isGenericIndexType` is
    // true and `T[K]` stays deferred until `getInferredType` substitutes the
    // binder. ztsc models `infer` as its own kind, which `containsFreeTypeParam`
    // deliberately does not report — so `Form[infer K]` resolved eagerly to
    // `any` and baked that in before `substInfer` could bind `K`. That is the
    // react-hook-form `PathValueImpl` shape (`P extends \`${infer K}.${infer R}\`
    // ? K extends keyof T ? T[K] : …`): every field path collapsed to `any`.
    if (try c.containsInfer(idx)) {
        return c.ts.makeIndexAccess(obj, idx);
    }
    // Distribute over a union index: `Obj[A | B]` === `Obj[A] |
    // Obj[B]`. Holds whether or not `Obj` is generic, and is how a
    // `keyof`-derived index expands once the key union is known.
    if (c.ts.kind(idx) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(idx)) |m| try parts.append(c.scratch(), try c.reduceIndexedAccess(obj, m));
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    // Generic object and/or index: defer as `T[K]`; resolved in
    // `instantiateId`'s `.index_access` arm once the operands are concrete.
    //
    // The index uses the deep *free* type-param test (tsc `isGenericIndexType`):
    // a member that is itself a generic signature (`{ f: <T>() => T }`) does
    // not make the index generic, so the access resolves now instead of
    // stranding the member as `Obj["f"]`.
    //
    // The OBJECT uses a *shallow* generic test (tsc `isGenericObjectType`),
    // NOT the deep free-type-param scan: a plain intersection/tuple/object is
    // not a generic object type merely because a deeply-nested member type
    // (e.g. a tuple element's complex generic signature) mentions a type
    // variable. Property PRESENCE is instantiation-invariant, so a concrete
    // literal key resolves to the same property now as after instantiation.
    // Deferring on the deep scan stranded `([TFn,i18n,boolean] & {t;i18n})['i18n']`
    // as an unreduced `.index_access`, on which member access (`.t`) then
    // wrongly reported TS2339. Only defer when a top-level constituent is
    // itself instantiable (a bare type variable, mapped/conditional/keyof, …).
    if (try c.isGenericObjectForIndex(obj) or try c.containsFreeTypeParam(idx, &.{})) {
        return c.ts.makeIndexAccess(obj, idx);
    }
    return c.indexedAccessType(obj, idx);
}

/// Shallow analogue of tsc's `isGenericObjectType` for the object side of an
/// indexed access: is `t` (or a union/intersection constituent of it) an
/// *instantiable* type whose indexed property genuinely depends on later
/// instantiation? Plain object/tuple/array containers are NOT generic here
/// even when their members mention free type params — indexing them by a
/// concrete key resolves the same before and after instantiation.
pub fn isGenericObjectForIndex(c: *Checker, t0: TypeId) Error!bool {
    const s = &c.ts;
    // A polymorphic `this` is a type VARIABLE (tsc's thisType), so `this[K]`
    // defers until a receiver substitutes it. Asked before `resolveStructural`,
    // which would otherwise unwrap the marker to its home instance and resolve
    // the access against a member table that may still be materializing.
    if (s.kind(t0) == .this_type) return true;
    // An interface/class instance is an object for every argument list, and
    // an object is not an instantiable type here (the doc comment above) —
    // so the member table need not be materialized to say no. See
    // `refExpandsToObject`.
    if (c.refExpandsToObject(t0)) return false;
    const t = try c.resolveStructural(t0);
    return switch (s.kind(t)) {
        .type_param, .infer_var, .mapped_param, .mapped, .index_access, .conditional, .keyof_op, .string_mapping, .template_literal_type => true,
        // Indexed walk: `resolveStructural` in the recursion can intern.
        .union_type, .intersection => blk: {
            for (0..s.memberCount(t)) |i| {
                if (try c.isGenericObjectForIndex(s.memberAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn containsMappedParam(c: *Checker, t: TypeId) Error!bool {
    const v = c.triGet(&c.cmp_cache, t);
    if (v != 0) return v == 2;
    try c.triSet(&c.cmp_cache, t, 1);
    const r = try c.containsMappedParamInner(t);
    try c.triSet(&c.cmp_cache, t, if (r) 2 else 1);
    return r;
}

pub fn containsMappedParamInner(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    return switch (s.kind(t)) {
        .mapped_param => true,
        .array => c.containsMappedParam(s.arrayElem(t)),
        .index_access => (try c.containsMappedParam(s.indexAccessObj(t))) or (try c.containsMappedParam(s.indexAccessIndex(t))),
        .union_type, .intersection, .overloads => blk: {
            for (0..s.memberCount(t)) |i| {
                if (try c.containsMappedParam(s.memberAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        .tuple => blk: {
            for (0..s.tupleLen(t)) |i| {
                if (try c.containsMappedParam(s.tupleElem(t, @intCast(i)).ty)) break :blk true;
            }
            break :blk false;
        },
        .object => blk: {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.containsMappedParam(s.objectProp(t, @intCast(i)).ty)) break :blk true;
            }
            break :blk false;
        },
        .function => blk: {
            if (try c.containsMappedParam(s.fnReturn(t))) break :blk true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.containsMappedParam(s.fnParam(t, @intCast(i)).ty)) break :blk true;
            }
            break :blk false;
        },
        .ref => blk: {
            for (0..s.refArgCount(t)) |i| {
                if (try c.containsMappedParam(s.refArgAt(t, i))) break :blk true;
            }
            break :blk false;
        },
        .conditional => blk: {
            if (try c.containsMappedParam(s.condCheck(t))) break :blk true;
            if (try c.containsMappedParam(s.condExtends(t))) break :blk true;
            if (try c.containsMappedParam(s.condTrue(t))) break :blk true;
            if (try c.containsMappedParam(s.condFalse(t))) break :blk true;
            break :blk false;
        },
        .template_literal_type => blk: {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.containsMappedParam(s.templateHole(t, @intCast(i)))) break :blk true;
            }
            break :blk false;
        },
        .string_mapping => c.containsMappedParam(s.stringMappingArg(t)),
        .keyof_op => c.containsMappedParam(s.keyofOperand(t)),
        // A DEFERRED mapped type parked by `reduceMapped` because its KEY
        // SET mentions an enclosing map's key parameter. Only the key set
        // (constraint / homomorphic source) is inspected: both are
        // evaluated with this map's own `K` still unbound, so a hit there
        // is necessarily a FOREIGN key parameter. The value and the `as`
        // clause are where this map's own `K` lives — reading them would
        // answer `true` for every deferred map and drag `substMappedKey`
        // through maps that have nothing to substitute (measured: +181
        // diagnostics on the dogfood app, from re-reducing maps whose key
        // set was already concrete).
        .mapped => blk: {
            if (s.mappedConstraint(t) != 0 and try c.containsMappedParam(s.mappedConstraint(t))) break :blk true;
            break :blk s.mappedSource(t) != 0 and try c.containsMappedParam(s.mappedSource(t));
        },
        else => false,
    };
}

/// Does `t` mention the mapped key parameter `key_id`? The EXACT-id
/// counterpart of `containsMappedParam` (which answers "any mapped key"),
/// and what gates `substMappedKey`.
///
/// The distinction matters for a DEFERRED nested map. `containsMappedParam`
/// deliberately reads only a `.mapped`'s key set, because its value/`as`
/// always mention its OWN key and reading them would answer `true` for every
/// deferred map. But then `{ [P in "a"|"b"]: { [M in keyof T]: [P, M] } }`
/// — inner map deferred on the free `T`, outer key `P` only in its VALUE —
/// answered `false`, so `substMappedKey` returned it untouched and `P` was
/// never bound (the tuple stayed `[P, "q"]`). Testing one specific id lets
/// the value/`as` be walked without that false positive.
pub fn mentionsMappedParam(c: *Checker, t: TypeId, key_id: u32) Error!bool {
    const k = (@as(u64, t) << 32) | key_id;
    if (c.mmp_cache.get(k)) |v| {
        if (v != 0) return v == 2;
    }
    try c.mmp_cache.put(c.cm(), k, 1);
    const r = try c.mentionsMappedParamInner(t, key_id);
    try c.mmp_cache.put(c.cm(), k, if (r) 2 else 1);
    return r;
}

pub fn mentionsMappedParamInner(c: *Checker, t: TypeId, key_id: u32) Error!bool {
    const s = &c.ts;
    return switch (s.kind(t)) {
        .mapped_param => s.mappedParamId(t) == key_id,
        .array => c.mentionsMappedParam(s.arrayElem(t), key_id),
        .index_access => (try c.mentionsMappedParam(s.indexAccessObj(t), key_id)) or
            (try c.mentionsMappedParam(s.indexAccessIndex(t), key_id)),
        .union_type, .intersection, .overloads => blk: {
            for (0..s.memberCount(t)) |i| {
                if (try c.mentionsMappedParam(s.memberAt(t, i), key_id)) break :blk true;
            }
            break :blk false;
        },
        .tuple => blk: {
            for (0..s.tupleLen(t)) |i| {
                if (try c.mentionsMappedParam(s.tupleElem(t, @intCast(i)).ty, key_id)) break :blk true;
            }
            break :blk false;
        },
        // Every slot `substMappedKey`'s `.object` arm rewrites has to be
        // asked about here, or the early-out returns the object untouched
        // and the key is never bound in it. The INDEX SIGNATURE is the one
        // that mattered: `Record<string, V>` materializes to `{ [x: string]:
        // V }`, so a mapped type whose value is `Record<string, F<M[C]>>`
        // (kysely's `SelectQueryBuilderExpression<Record<string,
        // UpdateType<DB[T][C]>>>` inside `UpdateObject`) kept `C` free
        // forever and related to nothing.
        .object => blk: {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.mentionsMappedParam(s.objectProp(t, @intCast(i)).ty, key_id)) break :blk true;
            }
            if (s.objectStringIndex(t) != 0 and try c.mentionsMappedParam(s.objectStringIndex(t), key_id)) break :blk true;
            if (s.objectNumberIndex(t) != 0 and try c.mentionsMappedParam(s.objectNumberIndex(t), key_id)) break :blk true;
            for (0..s.objectCallSigCount(t)) |i| {
                if (try c.mentionsMappedParam(s.objectCallSig(t, @intCast(i)), key_id)) break :blk true;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (try c.mentionsMappedParam(s.objectConstructSig(t, @intCast(i)), key_id)) break :blk true;
            }
            break :blk false;
        },
        .function => blk: {
            if (try c.mentionsMappedParam(s.fnReturn(t), key_id)) break :blk true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.mentionsMappedParam(s.fnParam(t, @intCast(i)).ty, key_id)) break :blk true;
            }
            break :blk false;
        },
        .ref => blk: {
            for (0..s.refArgCount(t)) |i| {
                if (try c.mentionsMappedParam(s.refArgAt(t, i), key_id)) break :blk true;
            }
            break :blk false;
        },
        .conditional => blk: {
            if (try c.mentionsMappedParam(s.condCheck(t), key_id)) break :blk true;
            if (try c.mentionsMappedParam(s.condExtends(t), key_id)) break :blk true;
            if (try c.mentionsMappedParam(s.condTrue(t), key_id)) break :blk true;
            if (try c.mentionsMappedParam(s.condFalse(t), key_id)) break :blk true;
            break :blk false;
        },
        .template_literal_type => blk: {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.mentionsMappedParam(s.templateHole(t, @intCast(i)), key_id)) break :blk true;
            }
            break :blk false;
        },
        .string_mapping => c.mentionsMappedParam(s.stringMappingArg(t), key_id),
        .keyof_op => c.mentionsMappedParam(s.keyofOperand(t), key_id),
        .mapped => blk: {
            // Key set first: it is evaluated OUTSIDE this map's own binder,
            // so `key_id` there is always the enclosing one.
            if (s.mappedConstraint(t) != 0 and try c.mentionsMappedParam(s.mappedConstraint(t), key_id)) break :blk true;
            if (s.mappedSource(t) != 0 and try c.mentionsMappedParam(s.mappedSource(t), key_id)) break :blk true;
            // The value/`as` branches are inside this map's binder. A
            // recursive alias (`type R<T> = { [K in keyof T]: R<T[K]> }`)
            // re-enters the SAME mapped node, so the inner instance can
            // carry the same key id — there its own binder shadows the
            // enclosing one and nothing inside is substitutable.
            if (mappedBindsKey(s, t, key_id)) break :blk false;
            if (try c.mentionsMappedParam(s.mappedValue(t), key_id)) break :blk true;
            break :blk s.mappedAs(t) != 0 and try c.mentionsMappedParam(s.mappedAs(t), key_id);
        },
        else => false,
    };
}

/// Does mapped type `t` bind `key_id` as its OWN key parameter (so a
/// reference to it inside `t`'s value/`as` is `t`'s, not an enclosing map's)?
fn mappedBindsKey(s: *const types.Store, t: TypeId, key_id: u32) bool {
    const kp = s.mappedKeyParam(t);
    return kp != 0 and s.kind(kp) == .mapped_param and s.mappedParamId(kp) == key_id;
}

/// Replace the mapped key parameter (`key_id`) with a concrete key type
/// throughout `t`, reducing any `Obj[Idx]` that becomes concrete.
pub fn substMappedKey(c: *Checker, t: TypeId, key_id: u32, key_ty: TypeId) Error!TypeId {
    // Per-constituent rebinding of a distributive conditional (see the
    // `.conditional` arm below and `instantiateId`'s). Asked first: the check
    // being rebound need not mention the key at all once it has been
    // substituted.
    if (c.cond_check_subst) |cs| {
        if (t == cs.from) return cs.to;
        // A rebinding is live, so nothing below is a function of the key
        // alone — take the uncached path (see `Checker.smk_cache`).
        if (!try c.mentionsMappedParam(t, key_id)) return t;
        return substMappedKeyInner(c, t, key_id, key_ty);
    }
    if (!try c.mentionsMappedParam(t, key_id)) return t;
    if (!c.inst_cache_on or !smkWorthMemoizing(c.ts.kind(t))) {
        return substMappedKeyInner(c, t, key_id, key_ty);
    }
    const memo_key = (@as(u128, @intFromBool(c.homo_index_mode)) << 96) |
        (@as(u128, t) << 64) | (@as(u128, key_id) << 32) | key_ty;
    if (c.smk_cache.get(memo_key)) |e| {
        if (e.gen == c.key_name_gen) return e.ty;
    }
    const visits_before = c.inst_total;
    const result = try substMappedKeyInner(c, t, key_id, key_ty);
    // A truncated reduction is a fact about the live budget, not about the
    // key — the rule `inst_cache` and `erase_cache` follow.
    //
    // …and only a walk that actually reached `instantiate` is worth an entry.
    // A conditional that binds the key and then decides without substituting
    // anything is free to recompute, and drizzle-orm's `.d.ts` aliases are
    // millions of those: publishing them anyway costs it 14% of its
    // instructions at `--checkers=1` (4.20 G against 3.69 G) for four saved
    // node visits, and costs immich 6% of its peak RSS. The subtrees this
    // memo is FOR — kysely's `Selection`/`UpdateObject`, vitest's `Mocked` —
    // reduce an indexed access or instantiate a reference on every key, so
    // they always charge at least one node visit.
    if (!c.inst_limit_tripped and c.inst_total != visits_before) {
        try c.smk_cache.put(c.cm(), memo_key, .{ .ty = result, .gen = c.key_name_gen });
    }
    return result;
}

/// Which `substMappedKey` arms carry a memo (`Checker.smk_cache`). Every other
/// arm either answers in a couple of instructions or is a pure structural
/// rebuild whose CHILDREN carry the reductions, so the probe costs more than
/// the walk it saves and the sharing is picked up one level down anyway.
///
/// The set is measured, not reasoned (immich `--checkers=4` instructions
/// retired / drizzle-orm `-p <dir>` at `--checkers=4`, against 100.4 G /
/// 3.620 G):
///
///   | memoized kinds | immich | drizzle |
///   |---|---:|---:|
///   | every arm | 65.9 G | 3.876 G (+7.1%) |
///   | composites + reducers | 67.7 G | 3.859 G (+6.6%) |
///   | the four reducing kinds | 69.4 G | 3.856 G (+6.5%) |
///   | **`.conditional` + `.mapped`** | **69.5 G** | **3.755 G (+3.7%)** |
///
/// `.index_access` and `.keyof_op` are drizzle's hot arms — its whole
/// `reduceMapped -> substMappedKey -> reduceIndexedAccess` spine is unique
/// keys, so it pays the probe and never reads one back — and they are worth
/// exactly nothing on immich (byte-identical node visits with and without).
/// The composite arms are worth 1.8 G on immich and 0.1 G against on drizzle;
/// they are left out because drizzle-orm's `-p <dir>` row is the tightest
/// wall margin in the corpus (46% of tsgo against a 50% bar).
fn smkWorthMemoizing(k: types.Kind) bool {
    return switch (k) {
        .conditional, .mapped => true,
        else => false,
    };
}

fn substMappedKeyInner(c: *Checker, t: TypeId, key_id: u32, key_ty: TypeId) Error!TypeId {
    const s = &c.ts;
    switch (s.kind(t)) {
        .mapped_param => return if (s.mappedParamId(t) == key_id) key_ty else t,
        .index_access => {
            const obj = try c.substMappedKey(s.indexAccessObj(t), key_id, key_ty);
            const idx = try c.substMappedKey(s.indexAccessIndex(t), key_id, key_ty);
            return c.reduceIndexedAccess(obj, idx);
        },
        .array => return s.makeArrayLike(t, try c.substMappedKey(s.arrayElem(t), key_id, key_ty)),
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substMappedKey(m, key_id, key_ty));
            return s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substMappedKey(m, key_id, key_ty));
            return s.makeIntersection(c.scratch(), parts.items);
        },
        .tuple => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try c.substMappedKey(e.ty, key_id, key_ty), .flags = e.flags });
            }
            return s.makeTuple(elems.items);
        },
        // The whole shape has to survive, not just the properties: this arm
        // used to rebuild the object from its property list alone, dropping
        // both index signatures, the object flags and every call/construct
        // signature. It was invisible while `mentionsMappedParam` did not
        // look at those slots either (the early-out returned `t` untouched),
        // and the moment it does, dropping them would be a much worse bug
        // than the one it fixes. Mirrors `instantiateId`'s `.object` arm.
        .object => {
            var props: std.ArrayList(types.Prop) = .empty;
            defer props.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try props.append(c.scratch(), .{ .name = p.name, .ty = try c.substMappedKey(p.ty, key_id, key_ty), .flags = p.flags });
            }
            const sidx = if (s.objectStringIndex(t) != 0) try c.substMappedKey(s.objectStringIndex(t), key_id, key_ty) else 0;
            const nidx = if (s.objectNumberIndex(t) != 0) try c.substMappedKey(s.objectNumberIndex(t), key_id, key_ty) else 0;
            var call_sigs: std.ArrayList(TypeId) = .empty;
            defer call_sigs.deinit(c.scratch());
            for (0..s.objectCallSigCount(t)) |i| {
                try call_sigs.append(c.scratch(), try c.substMappedKey(s.objectCallSig(t, @intCast(i)), key_id, key_ty));
            }
            var ctor_sigs: std.ArrayList(TypeId) = .empty;
            defer ctor_sigs.deinit(c.scratch());
            for (0..s.objectConstructSigCount(t)) |i| {
                try ctor_sigs.append(c.scratch(), try c.substMappedKey(s.objectConstructSig(t, @intCast(i)), key_id, key_ty));
            }
            return s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, ctor_sigs.items);
        },
        .function => {
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substMappedKey(p.ty, key_id, key_ty), .flags = p.flags });
            }
            const ret = try c.substMappedKey(s.fnReturn(t), key_id, key_ty);
            return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, s.fnThisType(t));
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substMappedKey(a, key_id, key_ty));
            return s.makeRef(s.refSymbol(t), args.items);
        },
        .conditional => {
            const check0 = s.condCheck(t);
            const chk = try c.substMappedKey(check0, key_id, key_ty);
            // Distribution, rebinding the branches per constituent. Binding
            // the key turns the check (`O[K]`) into the column's union, and
            // instantiating the branches against that union rather than
            // against each constituent lets a conditional nested in a branch
            // answer for the whole union — see `instantiateId`'s copy of this
            // rule for the kysely shape it was written for.
            if (s.condDistributive(t) and chk != check0 and s.kind(chk) == .union_type) {
                const saved_subst = c.cond_check_subst;
                defer c.cond_check_subst = saved_subst;
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (try c.memberList(chk)) |m| {
                    c.cond_check_subst = .{ .from = check0, .to = m };
                    const ext_m = try c.substMappedKey(s.condExtends(t), key_id, key_ty);
                    const tru_m = try c.substMappedKey(s.condTrue(t), key_id, key_ty);
                    const fls_m = try c.substMappedKey(s.condFalse(t), key_id, key_ty);
                    c.cond_check_subst = saved_subst;
                    try parts.append(c.scratch(), try c.reduceConditional(m, ext_m, tru_m, fls_m, false));
                }
                return s.makeUnion(c.scratch(), parts.items);
            }
            const ext = try c.substMappedKey(s.condExtends(t), key_id, key_ty);
            const tru = try c.substMappedKey(s.condTrue(t), key_id, key_ty);
            const fls = try c.substMappedKey(s.condFalse(t), key_id, key_ty);
            return c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
        },
        .template_literal_type => {
            var holes: std.ArrayList(TypeId) = .empty;
            defer holes.deinit(c.scratch());
            for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.substMappedKey(s.templateHole(t, @intCast(i)), key_id, key_ty));
            return c.reduceTemplate(s.templateHead(t), holes.items, t);
        },
        .string_mapping => return c.applyStringMapping(s.stringMappingKind(t), try c.substMappedKey(s.stringMappingArg(t), key_id, key_ty)),
        .keyof_op => return c.keyofType(try c.substMappedKey(s.keyofOperand(t), key_id, key_ty)),
        // Re-enter `reduceMapped` with the enclosing map's key bound — the
        // mirror of `substInfer`'s `.mapped` arm, for a map deferred by the
        // `containsMappedParam` test in `reduceMapped`. The inner map's own
        // key param keeps its identity (normally a different id), so only
        // the outer `key_id` is rewritten. When the ids DO coincide (a
        // recursive alias re-entering the same mapped node) this map's own
        // binder shadows the enclosing one, so its value/`as` are left alone.
        .mapped => {
            const kp = s.mappedKeyParam(t);
            const shadowed = mappedBindsKey(s, t, key_id);
            const con = if (s.mappedConstraint(t) != 0) try c.substMappedKey(s.mappedConstraint(t), key_id, key_ty) else 0;
            const src = if (s.mappedSource(t) != 0) try c.substMappedKey(s.mappedSource(t), key_id, key_ty) else 0;
            const val = if (shadowed) s.mappedValue(t) else try c.substMappedKey(s.mappedValue(t), key_id, key_ty);
            const as_c = if (s.mappedAs(t) == 0 or shadowed) s.mappedAs(t) else try c.substMappedKey(s.mappedAs(t), key_id, key_ty);
            return c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
        },
        else => return t,
    }
}

// =====================================================================
// template-literal types + string intrinsics
// =====================================================================

pub fn intrinsicStringMapping(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Uppercase")) return types.string_mapping_uppercase;
    if (std.mem.eql(u8, name, "Lowercase")) return types.string_mapping_lowercase;
    if (std.mem.eql(u8, name, "Capitalize")) return types.string_mapping_capitalize;
    if (std.mem.eql(u8, name, "Uncapitalize")) return types.string_mapping_uncapitalize;
    return null;
}

/// Whether type alias `sym`'s body is the bare `intrinsic` keyword-identifier
/// (`type Uppercase<S extends string> = intrinsic;`), the marker the real lib
/// uses for its magic string transforms. Distinguishes them from a user alias
/// that merely shares the name.
pub fn aliasBodyIsIntrinsic(c: *Checker, sym: SymbolId) bool {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .type_alias) continue;
        const body = c.tree.nodeData(decl).rhs;
        if (body == null_node or c.nodeTag(body) != .identifier) return false;
        return std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(body)), "intrinsic");
    }
    return false;
}

/// The literal text following template hole `i` in a template-literal type
/// node: strip the `template_middle` (`}…${`) or `template_tail` (`}…\``)
/// delimiters. No unescaping (a documented simplification — escapes in
/// template *types* are rare).
pub fn templateChunkText(c: *Checker, tok: TokenIndex) []const u8 {
    const text = c.tokenText(tok);
    // middle: `}...${` (drop 1 leading `}`, 2 trailing `${`);
    // tail:   `}...\`` (drop 1 leading `}`, 1 trailing backtick).
    return switch (c.tree.tokens.tag(tok)) {
        .template_middle => if (text.len >= 3) text[1 .. text.len - 2] else "",
        .template_tail => if (text.len >= 2) text[1 .. text.len - 1] else "",
        else => text,
    };
}

/// Head literal text of a template-literal type node's main token: strip
/// the `template_head` (`` `…${ ``) or `no_substitution` (`` `…` ``) delims.
pub fn templateHeadText(c: *Checker, tok: TokenIndex) []const u8 {
    const text = c.tokenText(tok);
    return switch (c.tree.tokens.tag(tok)) {
        .template_head => if (text.len >= 3) text[1 .. text.len - 2] else "",
        .no_substitution_template_literal => if (text.len >= 2) text[1 .. text.len - 1] else "",
        else => text,
    };
}

/// Does the contextual type want a template-literal-typed value? True when
/// `ctx` is (or a union contains) a template-literal type — the only case
/// in which a template *expression* should keep a template-literal type
/// instead of widening to `string`. Gating on this keeps every other
/// template expression at `string` (zero blast radius).
pub fn ctxWantsTemplate(c: *Checker, ctx: TypeId) Error!bool {
    if (ctx == types.no_type) return false;
    const r = try c.resolveStructural(ctx);
    switch (c.ts.kind(r)) {
        .template_literal_type => return true,
        .union_type => {
            for (try c.memberList(r)) |m| if (try c.ctxWantsTemplate(m)) return true;
            return false;
        },
        // tsc's `isTemplateLiteralContextualType` also admits an
        // instantiable type whose base constraint is string-like: a
        // template expression inferred into `watch<N extends
        // FieldPath<T>>` must keep `` `contacts.${number}.type` ``
        // (widening to `string` fails the constraint, erasing `N` and
        // rejecting the overload).
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
            if (con == types.no_type) return false;
            // tsc reads the BASE constraint here (`getBaseConstraintOfType`),
            // which is what makes a constraint that is itself parameterised
            // string-like: `TName extends FieldPath<TFieldValues>` is a
            // deferred alias reference while `TFieldValues` is free, so the
            // resolved-structural test alone answered "not string-like" and
            // the template expression widened to `string`.
            const base = if (try c.containsTypeParam(con)) try c.baseConstraintOf(con) else con;
            return c.typeIsStringLike(try c.resolveStructural(base));
        },
        else => return false,
    }
}

/// tsc's `TypeFlags.StringLike` over a resolved constraint (plus a
/// union/intersection scan, as in `maybeTypeOfKind`).
pub fn typeIsStringLike(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .string, .string_literal, .template_literal_type, .string_mapping => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (try c.typeIsStringLike(try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// The `template_middle` / `template_tail` chunk token immediately following
/// a substitution that ends at byte `after`. Robust under nested template
/// substitutions: an inner template's tokens all start before `after`, so
/// the first middle/tail token at or past `after` is this template's chunk.
pub fn templateChunkTokAfter(c: *Checker, head_tok: TokenIndex, after: u32) TokenIndex {
    const n = c.tree.tokens.len();
    var t: usize = @as(usize, head_tok) + 1;
    while (t < n) : (t += 1) {
        const tg = c.tree.tokens.tag(@intCast(t));
        if ((tg == .template_middle or tg == .template_tail) and c.tree.tokens.start(@intCast(t)) >= after)
            return @intCast(t);
    }
    return head_tok;
}

/// A template-literal *expression* (`` `head${e0}c0${e1}…` ``) contextually
/// typed by a template-literal type: build the corresponding template-literal
/// *type* (`` `head${T0}c0${T1}…` ``) from the head/chunk texts and the
/// substitution types, rather than widening to `string`. This lets
/// `` `material-symbols:${status.icon}` `` (`status.icon: string`) satisfy a
/// `` `${string}:${string}` `` target — matching tsc's contextual typing.
pub fn templateExprType(c: *Checker, node: Node) Error!TypeId {
    const main_tok = c.tree.nodeMainToken(node);
    const head = try c.atom(c.templateHeadText(main_tok));
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(c.scratch());
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (c.tree.nodeRange(node)) |sub| {
        const st = if (sub != null_node) try c.checkExprCached(sub, types.no_type) else types.string_type;
        try holes.append(c.scratch(), st);
        const ctok = c.templateChunkTokAfter(main_tok, c.nodeSpan(sub).end);
        try chunks.append(c.scratch(), try c.atom(c.templateChunkText(ctok)));
    }
    if (holes.items.len == 0) return c.ts.makeStringLiteral(head, false);
    return c.reduceTemplateChunks(head, holes.items, chunks.items);
}

pub fn templateTypeFromNode(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const e = c.tree.extraData(ast.TemplateLitType, d.lhs);
    const head = try c.atom(c.templateHeadText(c.tree.nodeMainToken(node)));
    const hole_nodes = c.tree.extraRange(e.holes_start, e.holes_end);
    const chunk_toks = c.tree.extraRange(e.chunks_start, e.chunks_end);
    if (hole_nodes.len == 0) return c.ts.makeStringLiteral(head, false);
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(c.scratch());
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (hole_nodes, 0..) |hn, i| {
        try holes.append(c.scratch(), try c.typeFromTypeNode(hn));
        const ct = if (i < chunk_toks.len) try c.atom(c.templateChunkText(chunk_toks[i])) else try c.atom("");
        try chunks.append(c.scratch(), ct);
    }
    return c.reduceTemplateChunks(head, holes.items, chunks.items);
}

/// Re-evaluate a template from an existing template-literal `tpl` (reuses
/// its stored chunk atoms) with fresh `holes` (post-substitution).
pub fn reduceTemplate(c: *Checker, head: Atom, holes: []const TypeId, tpl: TypeId) Error!TypeId {
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (0..c.ts.templateHoleCount(tpl)) |i| try chunks.append(c.scratch(), c.ts.templateChunk(tpl, @intCast(i)));
    return c.reduceTemplateChunks(head, holes, chunks.items);
}

/// A partially-evaluated template builder: a concrete `head` string plus a
/// list of committed *pattern* holes (a non-enumerable hole type and the
/// literal text that follows it). Concrete/enumerable text is folded into
/// `head` (no pattern holes yet) or into the last hole's `chunk`.
pub const TplBuilder = struct {
    head: std.ArrayList(u8),
    holes: std.ArrayList(TypeId),
    chunks: std.ArrayList(std.ArrayList(u8)),
};

/// The single evaluation point for a template-literal type (build time +
/// each instantiation). Defers (keeps the template symbolic) while any hole
/// is still generic; otherwise cross-products the enumerable holes and
/// keeps non-enumerable (`string`/`number`) holes as a pattern. Counted
/// against the TS2589 depth/count budget.
pub fn reduceTemplateChunks(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
    if (c.inst_depth > max_instantiation_depth or c.inst_count > c.inst_budget) {
        c.inst_limit_tripped = true;
        if (c.instDiagAllowed()) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return types.error_type;
    }
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    // Release this evaluation's scratch on the way out, the way a `relate`
    // frame does. `evalTemplate` cross-products its builder list hole by
    // hole, cloning every builder each round and "freeing" the previous
    // generation — but `BumpArena.free` is a no-op for anything but the most
    // recent block, and an `ArrayList` growing abandons each predecessor, so
    // a wide cross product leaves the whole intermediate generation sequence
    // live. Nothing it allocates outlives this call: both return paths hand
    // back an interned `TypeId` (`makeTemplateLiteral` copies `holes`/`chunks`
    // into store memory, `makeUnion` uses the scratch only for its flatten
    // worklist), and `holes`/`chunks` themselves were bumped by the caller
    // before this mark. The arena is captured rather than re-read because a
    // nested top-level `instantiate` swaps a different one in for its own
    // duration.
    //
    // Measured on immich: `check scratch high-water` 874,668,264 -> 237,658,344
    // and peak RSS 1.201 -> 0.564 GB at one checker (2.554 -> 1.402 GB at
    // four), diagnostics byte-identical.
    const tpl_arena = c.scratch_arena;
    const tpl_mark = tpl_arena.mark();
    defer tpl_arena.restore(tpl_mark);
    // Still generic in any hole → defer (keep the deferred template type).
    for (holes) |h| {
        if (try c.containsTypeParam(h) or try c.containsMappedParam(h) or try c.containsInfer(h)) {
            return c.ts.makeTemplateLiteral(head, holes, chunks);
        }
    }
    return c.evalTemplate(head, holes, chunks);
}

/// Concrete cross-product evaluation. Produces a union of string-literal
/// types (all holes enumerable) and/or template-literal *pattern* types
/// (some hole is a bare `string`/`number`). Bounds the working set by the
/// instantiation count limit; on explosion trips TS2589 (bounded, never hangs).
pub fn evalTemplate(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
    const gpa = c.scratch();
    var builders: std.ArrayList(TplBuilder) = .empty;
    defer {
        for (builders.items) |*b| freeBuilder(gpa, b);
        builders.deinit(gpa);
    }
    {
        var b0: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
        try b0.head.appendSlice(gpa, c.atomText(head));
        try builders.append(gpa, b0);
    }
    // tsc caps a template-literal union at 100000 members, emitting TS2590
    // past it. Match that so a `${D}${D}${D}${D}${D}` (10^5) blowup trips
    // gracefully instead of materializing millions of string literals.
    const cap: usize = 100_000;
    for (holes, 0..) |hole, i| {
        const chunk_text = c.atomText(chunks[i]);
        var forms: std.ArrayList(Atom) = .empty;
        defer forms.deinit(gpa);
        const enumerable = try c.enumerableForms(hole, &forms);
        var next: std.ArrayList(TplBuilder) = .empty;
        if (enumerable) {
            for (builders.items) |*b| {
                for (forms.items) |f| {
                    var nb = try cloneBuilder(gpa, b);
                    try appendConcrete(gpa, &nb, c.atomText(f));
                    try appendConcrete(gpa, &nb, chunk_text);
                    try next.append(gpa, nb);
                }
                freeBuilder(gpa, b);
            }
        } else {
            for (builders.items) |*b| {
                var nb = try cloneBuilder(gpa, b);
                try nb.holes.append(gpa, hole);
                var ch: std.ArrayList(u8) = .empty;
                try ch.appendSlice(gpa, chunk_text);
                try nb.chunks.append(gpa, ch);
                try next.append(gpa, nb);
                freeBuilder(gpa, b);
            }
        }
        builders.deinit(gpa);
        builders = next;
        if (builders.items.len >= cap) {
            c.inst_limit_tripped = true;
            try c.instLimitDiag(2590, "Expression produces a union type that is too complex to represent.");
            return types.string_type;
        }
    }
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(gpa);
    for (builders.items) |*b| {
        const bhead = try c.internText(b.head.items);
        if (b.holes.items.len == 0) {
            try parts.append(gpa, try c.ts.makeStringLiteral(bhead, false));
        } else {
            var chunk_atoms: std.ArrayList(Atom) = .empty;
            defer chunk_atoms.deinit(gpa);
            for (b.chunks.items) |ch| try chunk_atoms.append(gpa, try c.internText(ch.items));
            try parts.append(gpa, try c.ts.makeTemplateLiteral(bhead, b.holes.items, chunk_atoms.items));
        }
    }
    return c.ts.makeUnion(gpa, parts.items);
}

pub fn cloneBuilder(gpa: std.mem.Allocator, b: *const TplBuilder) Error!TplBuilder {
    var nb: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
    try nb.head.appendSlice(gpa, b.head.items);
    try nb.holes.appendSlice(gpa, b.holes.items);
    for (b.chunks.items) |ch| {
        var c2: std.ArrayList(u8) = .empty;
        try c2.appendSlice(gpa, ch.items);
        try nb.chunks.append(gpa, c2);
    }
    return nb;
}

pub fn freeBuilder(gpa: std.mem.Allocator, b: *TplBuilder) void {
    b.head.deinit(gpa);
    b.holes.deinit(gpa);
    for (b.chunks.items) |*ch| ch.deinit(gpa);
    b.chunks.deinit(gpa);
}

/// Append concrete text: into the running `head` while no pattern hole has
/// been committed, otherwise onto the last committed hole's chunk.
pub fn appendConcrete(gpa: std.mem.Allocator, b: *TplBuilder, text: []const u8) Error!void {
    if (b.chunks.items.len == 0) {
        try b.head.appendSlice(gpa, text);
    } else {
        try b.chunks.items[b.chunks.items.len - 1].appendSlice(gpa, text);
    }
}

/// If `hole` enumerates to a finite set of concrete strings, append them to
/// `out` and return true; otherwise (bare `string`/`number`, deferred
/// intrinsic, …) return false — the hole must stay a pattern.
pub fn enumerableForms(c: *Checker, hole0: TypeId, out: *std.ArrayList(Atom)) Error!bool {
    const s = &c.ts;
    const hole = try c.resolveStructural(hole0);
    switch (s.kind(hole)) {
        .string_literal => {
            try out.append(c.scratch(), s.literalAtom(hole));
            return true;
        },
        .number_literal, .number_literal_fresh => {
            try out.append(c.scratch(), try c.numberLiteralAtom(hole));
            return true;
        },
        .bigint_literal => {
            try out.append(c.scratch(), s.literalAtom(hole));
            return true;
        },
        .bool_true => {
            try out.append(c.scratch(), try c.atom("true"));
            return true;
        },
        .bool_false => {
            try out.append(c.scratch(), try c.atom("false"));
            return true;
        },
        // `boolean` interpolates as the union `"false" | "true"`.
        .boolean => {
            try out.append(c.scratch(), try c.atom("false"));
            try out.append(c.scratch(), try c.atom("true"));
            return true;
        },
        .null => {
            try out.append(c.scratch(), try c.atom("null"));
            return true;
        },
        .undefined => {
            try out.append(c.scratch(), try c.atom("undefined"));
            return true;
        },
        .union_type => {
            for (try c.memberList(hole)) |m| {
                if (!try c.enumerableForms(m, out)) return false;
            }
            return true;
        },
        // An enum interpolates as its constant VALUES. tsc needs no special
        // case: a member type carries `StringLiteral | EnumLiteral` (so
        // `addSpans` reads its `value` straight off) and a WHOLE enum IS the
        // union of its members, which the union arm above distributes over.
        // ztsc keeps the enum as one `.enum_type`, so both forms are spelled
        // out here — without it `` `${AppLanguage}` `` stayed a symbolic
        // pattern that no member string was comparable to (5 TS2678 on
        // social-app's `switch (lang as `${AppLanguage}`)`).
        .enum_type => {
            const esym = s.enumSymbol(hole);
            if (s.isEnumMember(hole)) {
                const v = (try c.enumMemberValue(esym, s.enumMemberAtom(hole))) orelse return false;
                return c.enumerableForms(v, out);
            }
            const members = try c.enumMembersOf(esym);
            if (members.len == 0) return false;
            for (members) |m| {
                if (m.value == types.no_type) return false;
                if (!try c.enumerableForms(m.value, out)) return false;
            }
            return true;
        },
        // The `Core & string` template-hole idiom, generalized: `"a" & string`
        // (a single literal), `("a"|"b") & string` (a literal UNION, which the
        // single-literal `stringLiteralOf` path missed — it left the hole a
        // malformed pattern), and — the load-bearing case for recursive
        // path builders — `PathInternal<V, …> & string` where the non-primitive
        // member is an alias `.ref` inside the hole. Each member is resolved
        // structurally, which DRIVES such a ref home (e.g. `PInt<{deep}>` →
        // `"deep"`) under the ordinary shrinking discipline; the string/number
        // primitive constraint is absorbed and the sole literal core enumerates.
        // Two non-primitive members (a genuine literal-vs-literal intersection)
        // or a non-enumerable core fall back to keeping the hole a pattern.
        .intersection => {
            var core: TypeId = types.no_type;
            for (try c.memberList(hole)) |m0| {
                const m = try c.resolveStructural(m0);
                switch (s.kind(m)) {
                    // primitive supertypes absorbed by a string/number literal
                    .string, .number, .bigint => {},
                    else => {
                        if (core != types.no_type) return false;
                        core = m;
                    },
                }
            }
            if (core != types.no_type) return c.enumerableForms(core, out);
            return false;
        },
        else => return false, // string / number / pattern / mapping → keep as pattern
    }
}

/// The single concrete string-literal atom `t` denotes, seeing through a
/// `literal & primitive` intersection (`"a" & string` → `"a"`). Null when
/// `t` is not a single concrete string.
pub fn stringLiteralOf(c: *Checker, t0: TypeId) Error!?Atom {
    const s = &c.ts;
    const t = try c.resolveStructural(t0);
    return switch (s.kind(t)) {
        .string_literal => s.literalAtom(t),
        .number_literal, .number_literal_fresh => try c.numberLiteralAtom(t),
        .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (s.kind(m) == .string_literal) break :blk s.literalAtom(m);
            }
            break :blk null;
        },
        else => null,
    };
}

/// Apply a string-transform intrinsic. Concrete string → transformed
/// string-literal; union → distribute; still-generic arg → defer as a
/// `string_mapping` type. `string` itself maps to `string`.
pub fn applyStringMapping(c: *Checker, kind_idx: u32, arg0: TypeId) Error!TypeId {
    const s = &c.ts;
    const arg = try c.resolveStructural(arg0);
    switch (s.kind(arg)) {
        .string => return types.string_type,
        .any, .err => return arg,
        .never => return types.never_type,
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(arg)) |m| try parts.append(c.scratch(), try c.applyStringMapping(kind_idx, m));
            return s.makeUnion(c.scratch(), parts.items);
        },
        else => {},
    }
    if (try c.stringLiteralOf(arg)) |atom_| {
        const src = c.atomText(atom_);
        const buf = try c.scratch().alloc(u8, src.len);
        defer c.scratch().free(buf);
        transformString(kind_idx, src, buf);
        return s.makeStringLiteral(try c.internText(buf), false);
    }
    // Still generic (type param / mapped_param / infer / nested template
    // pattern / another mapping) → defer.
    return s.makeStringMapping(kind_idx, arg);
}

pub fn transformString(kind_idx: u32, src: []const u8, dst: []u8) void {
    for (src, 0..) |ch, i| dst[i] = ch;
    switch (kind_idx) {
        types.string_mapping_uppercase => for (dst) |*ch| {
            ch.* = std.ascii.toUpper(ch.*);
        },
        types.string_mapping_lowercase => for (dst) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        },
        types.string_mapping_capitalize => if (dst.len > 0) {
            dst[0] = std.ascii.toUpper(dst[0]);
        },
        types.string_mapping_uncapitalize => if (dst.len > 0) {
            dst[0] = std.ascii.toLower(dst[0]);
        },
        else => {},
    }
}

/// Does concrete `text` match template-literal pattern `tpl`? Used for
/// `"axb"`-assignable-to-`` `a${string}b` ``. Backtracks over occurrences of
/// each hole's following literal so multi-hole patterns match soundly.
pub fn matchTemplatePattern(c: *Checker, text: []const u8, tpl: TypeId) Error!bool {
    const head = c.atomText(c.ts.templateHead(tpl));
    if (!std.mem.startsWith(u8, text, head)) return false;
    return c.matchTplHole(text[head.len..], tpl, 0);
}

pub fn matchTplHole(c: *Checker, rest: []const u8, tpl: TypeId, i: u32) Error!bool {
    const s = &c.ts;
    const n = s.templateHoleCount(tpl);
    if (i == n) return rest.len == 0;
    const hole = s.templateHole(tpl, i);
    const chunk = c.atomText(s.templateChunk(tpl, i));
    if (i + 1 == n) {
        if (!std.mem.endsWith(u8, rest, chunk)) return false;
        return c.holeAccepts(hole, rest[0 .. rest.len - chunk.len]);
    }
    if (chunk.len == 0) {
        var split: usize = 0;
        while (split <= rest.len) : (split += 1) {
            if ((try c.holeAccepts(hole, rest[0..split])) and try c.matchTplHole(rest[split..], tpl, i + 1)) return true;
        }
        return false;
    }
    var from: usize = 0;
    while (std.mem.indexOf(u8, rest[from..], chunk)) |rel| {
        const pos = from + rel;
        if ((try c.holeAccepts(hole, rest[0..pos])) and try c.matchTplHole(rest[pos + chunk.len ..], tpl, i + 1)) return true;
        from = pos + 1;
    }
    return false;
}

/// Whether a template pattern hole type admits the substring `str`.
pub fn holeAccepts(c: *Checker, hole0: TypeId, str: []const u8) Error!bool {
    const s = &c.ts;
    const hole = try c.resolveStructural(hole0);
    switch (s.kind(hole)) {
        .string, .any, .err => return true,
        .number => return isNumericString(str),
        .bigint => return isNumericString(str),
        .boolean => return std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "false"),
        .bool_true => return std.mem.eql(u8, str, "true"),
        .bool_false => return std.mem.eql(u8, str, "false"),
        .string_literal => return std.mem.eql(u8, str, c.atomText(s.literalAtom(hole))),
        .number_literal, .number_literal_fresh => return std.mem.eql(u8, str, c.atomText(try c.numberLiteralAtom(hole))),
        .union_type => {
            for (try c.memberList(hole)) |m| {
                if (try c.holeAccepts(m, str)) return true;
            }
            return false;
        },
        .template_literal_type => return c.matchTemplatePattern(str, hole),
        else => return false,
    }
}

pub fn isNumericString(str: []const u8) bool {
    if (str.len == 0) return false;
    _ = std.fmt.parseFloat(f64, str) catch return false;
    return true;
}
