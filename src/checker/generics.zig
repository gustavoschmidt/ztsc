//! Conditional types and `infer`: the plan/execute split that reduces one
//! (`planConditional` -> `finishCondPlan`), inference of `infer` binders by
//! matching a source against an `extends` pattern, and substitution of the
//! bindings back into the branches.
//!
//! The other two type-level constructs that used to live here now have their
//! own files — mapped types in `mapped.zig`, template-literal types and the
//! string intrinsics in `template.zig`. Both are re-exported at the bottom so
//! `Checker`'s method aliases and other modules' direct imports keep resolving
//! through `generics.zig`.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_instantiation_depth = checker_zig.max_instantiation_depth;

const TpMap = @import("enums.zig").TpMap;

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
            const t = try substInfer(c, true_ty, b.ids, b.vals);
            return c.makeUnion2(t, false_ty);
        },
        .need_both => |rest| switch (rest) {
            .defer_symbolic => return s.makeConditional(chk, extends_ty, true_ty, false_ty, distributive),
            .distribute => {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                const domain = blk2: {
                    const d = try condDistributionDomain(c, chk, extends_ty);
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
    const tb = try substInfer(c, true_ty, b.ids, vals);
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
fn condDistributionDomain(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!TypeId {
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

/// tsc's `getSimplifiedConditionalType`, reached from `getNormalizedType` on
/// both sides of every relation frame: a DEFERRED conditional of the form
/// `T extends U ? T : never` or `T extends U ? never : T` denotes the same set
/// for every substitution of `T` whenever the test is decidable *without*
/// knowing it, so the relation looks straight through it at `T` (or `never`).
///
/// The two decidable tests are tsc's, and only tsc's:
///
///   * ALWAYS TRUE — the RESTRICTIVE instantiations relate. Restrictive means
///     every type parameter stripped of its constraint, so the only pairs that
///     survive are the ones a constraint could not have decided: the check and
///     the extends clause are the SAME type (`T extends T`, `keyof P extends
///     keyof P`), or the target is `any`/`unknown`, which everything satisfies.
///     Approximating it with ordinary assignability would consult constraints
///     and answer true where tsc answers false, so it is deliberately not.
///   * ALWAYS FALSE — `check & extends` is uninhabited. `never` on either side
///     is the whole of it here; anything richer is a concrete pair, which
///     `planConcreteConditional` already resolved before this could be asked.
///
/// This is what makes `Exclude<T, never>` and `Extract<T, T>` interchangeable
/// with `T` (`conditionalTypesSimplifyWhenTrivial`). It is NOT a reduction:
/// the type keeps its written form everywhere else, which is why tsc still
/// prints `Exclude<T, never>` in the very diagnostics this rule silences.
///
/// A conditional that is still deferred *for distribution* — the check is a
/// naked type parameter, so `instantiateId` will distribute it later — is
/// simplified all the same, exactly as tsc does: distributing `T extends T ?
/// T : never` over a union rebuilds that union member by member.
pub fn simplifyConditional(c: *const Checker, t0: TypeId) TypeId {
    const s = &c.ts;
    var t = t0;
    // A branch that is itself one of the two shapes simplifies in turn
    // (`getSimplifiedType` recurses); the loop is bounded because each step
    // strictly shrinks the type.
    var steps: u32 = 0;
    while (s.kind(t) == .conditional and steps < 8) : (steps += 1) {
        const chk = s.condCheck(t);
        const ext = s.condExtends(t);
        const tru = s.condTrue(t);
        const fls = s.condFalse(t);
        if (s.kind(fls) == .never and tru == chk) {
            if (condRestrictivelyTrue(c, chk, ext)) {
                t = tru;
            } else if (condIntersectionEmpty(c, chk, ext)) {
                return types.never_type;
            } else return t;
        } else if (s.kind(tru) == .never and fls == chk) {
            if (condRestrictivelyTrue(c, chk, ext)) {
                return types.never_type;
            } else if (condIntersectionEmpty(c, chk, ext)) {
                t = fls;
            } else return t;
        } else return t;
    }
    return t;
}

/// Does `chk extends ext` hold for EVERY substitution — tsc's
/// `isTypeAssignableTo` over the two restrictive instantiations? See
/// `simplifyConditional` for why this is an identity test and not the
/// ordinary relation.
fn condRestrictivelyTrue(c: *const Checker, chk: TypeId, ext: TypeId) bool {
    if (chk == ext) return true;
    return switch (c.ts.kind(ext)) {
        .any, .unknown => true,
        else => false,
    };
}

/// Is `chk & ext` uninhabited — tsc's `isIntersectionEmpty`? Only the `never`
/// operand is decidable here; see `simplifyConditional`.
fn condIntersectionEmpty(c: *const Checker, chk: TypeId, ext: TypeId) bool {
    return c.ts.kind(ext) == .never or c.ts.kind(chk) == .never;
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
    if (distributive and (try condDistributionDomain(c, chk, extends_ty)) != 0) {
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
        // `extends any` / `extends unknown` is decidably TRUE, whatever the
        // check turns out to be: tsc's `getConditionalType` short-circuits on
        // `inferredExtendsType.flags & AnyOrUnknown` and never asks the
        // relation at all. Its ONE precondition is that the check type is not
        // deferred — and tsc's deferral test (`isDeferredType` →
        // `isGenericObjectType || isGenericIndexType`) is *shallow*: a bare
        // type variable, `keyof T`, an indexed access, a conditional, a
        // generic mapped type. A concrete container that merely carries free
        // params inside it — `Box<T>`, `{ q: T }`, `T[]`, `Box<T> | string` —
        // is NOT generic there, so tsc resolves it now. ztsc's general test is
        // the DEEP `containsFreeTypeParam` scan, which called all of those
        // generic and deferred them.
        //
        // The idiom that forces it is react-query's `NoInfer`:
        //     type NoInfer<T> = [T][T extends any ? 0 : never];
        // Instantiated at `NoInfer<InfiniteData<T>>` the inner check is the
        // reference `InfiniteData<T>`, so tsc reads `0` and the index reduces
        // back to `InfiniteData<T>`. Deferring left the whole thing as an
        // unreduced `[InfiniteData<T>][InfiniteData<T> extends any ? 0 :
        // never]`, on which every property read raised a false TS2339.
        //
        // Only the any/unknown short-circuit is taken here, not tsc's general
        // non-generic-check resolution: the latter decides by relating the
        // PERMISSIVE and RESTRICTIVE instantiations of the two sides (which is
        // what keeps `{ a: T } extends { a: string }` deferred rather than
        // false), and ztsc has neither. An any/unknown target needs no
        // relation, so this arm is exact.
        const ext_k = s.kind(extends_ty);
        if ((ext_k == .any or ext_k == .unknown) and !try c.isGenericObjectForIndex(chk)) {
            return planConcreteConditional(c, chk, extends_ty);
        }
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
            if (s.kind(chk_shape) == .object and try objectDecidablyNotExtends(c, chk_shape, ext_d)) {
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
        //
        // "Harmlessly" is a property of the PATTERN, not of the check, and it
        // has to be tested (`functionCheckDecidable`): a pattern position that
        // is not `any` / `unknown` / a bare `infer` reads the free param, and
        // the answer then depends on what that param becomes.
        // `(() => X) extends (() => true)` is the case in point — it is TRUE
        // for `X = true` and false otherwise — and resolving it while `X` was
        // free baked the false branch in for good. That is the `Equal<X, Y>`
        // identity probe, which every HKT encoding switches on: drizzle's
        // `PreparedQueryKind<…, TAssume>` opens with `Equal<TAssume, true>
        // extends true ?`, so an `insert(…).execute` resolved through the
        // WRONG arm of it and did not relate to the `execute()` its base class
        // declares (a phantom TS2416).
        if (!ext_generic and s.kind(chk) == .function) {
            const ext_fn = try c.resolveStructural(extends_ty);
            if (s.kind(ext_fn) == .function and try functionCheckDecidable(c, chk, ext_fn)) {
                return planConcreteConditional(c, chk, extends_ty);
            }
        }
        // An array/tuple check against an array pattern whose element is a
        // bare `infer` — the lib's `FlatArray`, `Arr extends
        // ReadonlyArray<infer InnerArr>` — is decided by the check's
        // *shape*: an array is an array whatever its element type is, and
        // the infer var absorbs that element. Free params in the element
        // therefore cannot change the answer, so resolve instead of
        // deferring. Deferring left `arr.flat()` as an unreduced
        // conditional that related to nothing.
        if (!ext_generic and try arrayDecidablyExtends(c, chk, extends_ty)) {
            return planConcreteConditional(c, chk, extends_ty);
        }
        return .{ .need_both = .defer_symbolic };
    }
    return planConcreteConditional(c, chk, extends_ty);
}

pub fn resolveConcreteConditional(c: *Checker, chk: TypeId, extends_ty: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
    const plan = try planConcreteConditional(c, chk, extends_ty);
    return c.finishCondPlan(plan, chk, extends_ty, true_ty, false_ty, distributive);
}

/// tsc's `getUnmatchedProperty`, asked of a conditional's extends clause while
/// that clause is still an UNMATERIALIZED nominal reference: does the pattern's
/// member table declare a required property name the check type has not got?
///
/// When it does, `chk extends pattern` is false for every binding of the
/// pattern's `infer` variables — property NAMES and OPTIONALITY are carried
/// through a substitution untouched by `instantiateId`'s `.object` arm, so the
/// scan's answer cannot change once the arguments arrive — and the conditional
/// resolves to its FALSE branch, whose scope holds no binder. So the whole
/// inference walk and the relation under it are dead work, and the pattern's
/// member table need never be built at all.
///
/// `structuralAssignable` already opens with this same scan (see there, and
/// conformance `assignability/094`), against `propOfTypeEx(…, false)` — the
/// lookup used here, so the two answer alike. What it cannot do is run before
/// its two sides are resolved, which is where the cost is: materializing the
/// pattern is what `inferFromExtendsInner`'s `.ref` arm spends, and on a fluent
/// generic API the pair is usually dead on ONE name.
///
/// kysely's `ExtractRowFromCommonTableExpression<CTE>` is the case that forced
/// it. It asks a query builder against `Expression<infer QO>`,
/// `InsertQueryBuilder<any, any, infer QO>` and
/// `UpdateQueryBuilder<any, any, any, infer QO>` in turn; a `DeleteQueryBuilder`
/// source is dead on `expressionType`, `values` and `set` respectively, and each
/// pattern was being materialized in full first — ~35 members apiece, every one
/// a mapped or conditional type over every column of every table in the schema.
/// immich's `db.with('removed', (db) => db.deleteFrom('asset_face')…)` spent the
/// entire 250,000-node statement budget there, so whether the statement resolved
/// depended on how much of those tables the checker's own partition had already
/// paid for: the same statement was clean at `--checkers=1` and TS2589 (plus a
/// TS2769/TS7006 cascade) at `--checkers=3`. One statement, 250,001 node visits
/// down to 20,820.
///
/// This is the FREE half of the lazy-member split, not the losing one: it reads
/// a generic table's names and substitutes nothing, so no later reader inherits
/// a bill (prof.zig records the other half measured negative four times, the
/// fourth on this very arm — reading one pattern member per matching name
/// instead took the same repro from 2.5 M node visits to 7.2 M).
///
/// Deliberately narrow, because everything it declines keeps today's path:
///
///   * the pattern must be a nominal interface/class reference whose generic
///     member table is already memoized (`lazyShapeOf` — it never BUILDS one,
///     for the reason given there);
///   * the check type must resolve to a single object or an intersection. A
///     union, `any`, `unknown`, `never` or a type variable is decided by an arm
///     of the relation this scan does not model — `never` relates to
///     everything, so screening it would take the wrong branch;
///   * two references to the SAME generic are the variance question, which is
///     not a structural walk at all.
fn unmatchedPatternProperty(c: *Checker, chk: TypeId, pattern: TypeId) Error!bool {
    const s = &c.ts;
    const generic = (try c.lazyShapeOf(pattern)) orelse return false;
    // Cheap first: a table with no required property can never screen a pair
    // out, and this runs before the check type is resolved.
    const n = s.objectPropCount(generic);
    var required = false;
    for (0..n) |i| {
        if (!s.objectProp(generic, @intCast(i)).optional()) {
            required = true;
            break;
        }
    }
    if (!required) return false;
    const src = try c.resolveStructural(chk);
    switch (s.kind(src)) {
        .object => {
            if (c.refFacetOf(src, .object)) |os| {
                if (s.refSymbol(os) == s.refSymbol(pattern)) return false;
            }
        },
        .intersection => {},
        else => return false,
    }
    for (0..n) |i| {
        // Re-read per iteration: `propOfTypeEx` interns, which can move the
        // store's property arrays (see `memberAt`).
        const p = s.objectProp(generic, @intCast(i));
        if (p.optional()) continue;
        if ((try c.propOfTypeEx(src, p.name, false)) == null) return true;
    }
    return false;
}

/// Match `input` against the `pattern` that declares `ids`, filling `vals`
/// with what each binder inferred (`no_type` for one nothing matched) — one
/// `inferTypes` call with the inference bookkeeping saved and restored around
/// it.
///
/// The bookkeeping is what makes a NESTED match safe: `infer_gen` is a fresh
/// key space for this match's `infer_visited` entries, so an inference
/// re-entered from inside this one (through an `instantiate` in the walk)
/// cannot invalidate the outer one's; `infer_prio_of` is tsc's
/// `InferenceInfo.priority`, one per binder, seeded worse than every real
/// priority so the first candidate always takes over.
pub fn inferBinders(c: *Checker, input: TypeId, pattern: TypeId, ids: []const u32, vals: []TypeId) Error!void {
    const saved_gen = c.infer_gen;
    const saved_steps = c.infer_steps;
    c.infer_gen = c.infer_gen_next;
    c.infer_gen_next +%= 1;
    c.infer_steps = 0;
    const saved_prio_of = c.infer_prio_of;
    const saved_prio_owner = c.infer_prio_owner;
    const saved_prio = c.infer_prio;
    const prio_of = try c.scratch().alloc(u16, ids.len);
    for (prio_of) |*p| p.* = InferPrio.max_value;
    c.infer_prio_of = prio_of;
    c.infer_prio_owner = vals.ptr;
    c.infer_prio = InferPrio.none;
    defer {
        c.infer_gen = saved_gen;
        c.infer_steps = saved_steps;
        c.infer_prio_of = saved_prio_of;
        c.infer_prio_owner = saved_prio_owner;
        c.infer_prio = saved_prio;
    }
    try c.inferFromExtends(input, pattern, ids, vals, false, 0);
}

/// The source conditional's `extends` clause and TRUE branch, rewritten so its
/// own `infer` binders are the TARGET conditional's — tsc's "if the source has
/// infer type parameters, we instantiate them in the context of the target"
/// (`structuredTypeRelatedTo`, conditional vs conditional):
///
/// ```ts
/// const ctx = createInferenceContext(sourceParams, …);
/// inferTypes(ctx.inferences, target.extendsType, sourceExtends, …);
/// sourceExtends = instantiateType(sourceExtends, ctx.mapper);
/// ```
///
/// Two conditionals WRITTEN the same way but declared separately bind distinct
/// `infer` variables, so their extends clauses are distinct types and the
/// identity test below them fails on nothing but the binder identities. `type
/// Cond1 = X extends [infer A] ? A : never` and an identically written `Cond2`
/// were mutually unassignable for exactly that reason
/// (`identicalGenericConditionalsWithInferRelated`), and so was any interface
/// method whose return type is such a conditional — the implementing class
/// re-declares it, which re-declares its binders (TS2416 on the same case).
///
/// Null — the pair stands as written — when the source declares no binders, or
/// when the match leaves one unbound, which means the two extends clauses are
/// not the same pattern at all.
pub fn rebindCondInferVars(c: *Checker, src: TypeId, tgt: TypeId) Error!?struct { extends: TypeId, true_branch: TypeId } {
    const s = &c.ts;
    const s_ext = s.condExtends(src);
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(c.scratch());
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(c.scratch());
    try collectInferVars(c, s_ext, &ids, &refs);
    if (ids.items.len == 0) return null;
    const vals = try c.scratch().alloc(TypeId, ids.items.len);
    for (vals) |*v| v.* = types.no_type;
    try inferBinders(c, s.condExtends(tgt), s_ext, ids.items, vals);
    for (vals) |v| {
        if (v == types.no_type) return null;
    }
    // An `infer V` occurrence carries WHICH occurrence it is: the binder's
    // DECLARATION in the extends clause and every REFERENCE to it in the true
    // branch are distinct interned types with the same logical id (see
    // `infer_var_reference`). The values just inferred come from the target's
    // extends clause, so they are declarations; substituting them into the
    // true branch would leave a declaration where the target holds a
    // reference, and the two would not compare equal. So the branch gets the
    // reference form of the same binders.
    const ref_vals = try c.scratch().alloc(TypeId, vals.len);
    for (vals, ref_vals) |v, *rv| {
        rv.* = if (s.kind(v) == .infer_var and !s.inferVarIsRef(v))
            try s.makeInferVar(s.inferVarId(v), s.inferVarName(v), true)
        else
            v;
    }
    return .{
        .extends = try substInfer(c, s_ext, ids.items, vals),
        .true_branch = try substInfer(c, s.condTrue(src), ids.items, ref_vals),
    };
}

fn planConcreteConditional(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!CondPlan {
    // Kept in scratch, never freed here: `ids`/`vals` are handed back to
    // the caller, which substitutes them into a branch it has yet to
    // materialize. The enclosing substitution frame's arena mark releases
    // them (see `instantiateId`'s per-frame rewind).
    var ids: std.ArrayList(u32) = .empty;
    var refs: std.ArrayList(u32) = .empty;
    defer refs.deinit(c.scratch());
    try collectInferVars(c, extends_ty, &ids, &refs);
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
    try collectInferVars(c, chk, &chk_vars, &chk_vars);
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
    // tsc's `getUnmatchedProperty`, asked BEFORE the extends pattern is
    // materialized — see `unmatchedPatternProperty`. It settles the whole
    // conditional, so it runs ahead of both the inference walk and the
    // relation, neither of which can then pay for a member table whose types
    // the answer never depended on.
    if (try unmatchedPatternProperty(c, chk, extends_ty)) return .take_false;
    const vals = try c.scratch().alloc(TypeId, ids.items.len);
    for (vals) |*v| v.* = types.no_type;
    if (ids.items.len > 0) {
        try inferBinders(c, chk, extends_ty, ids.items, vals);
        for (vals) |*v| {
            if (v.* == types.no_type) v.* = types.unknown_type; // unmatched → unknown
        }
    }
    const resolved_extends = try substInfer(c, extends_ty, ids.items, vals);
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
    try collectInferVars(c, extends_ty, &ids, &refs);
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

/// Is a FUNCTION check's match against a FUNCTION pattern settled by its
/// shape alone — i.e. can no substitution of the free type parameters still
/// inside it change the answer?
///
/// It can only be settled where the pattern ABSORBS what those parameters
/// reach. `(value: infer V, ...args: infer _) => any` — Awaited's callback
/// pattern — absorbs every position, so a `then` method's own `T`/`TResult1`
/// cannot decide anything and the conditional is resolvable while they are
/// still free. `() => true` absorbs nothing, so `(() => X) extends (() => true)`
/// is decided by `X` and must stay deferred.
///
/// Position-wise, so a check whose free parameters sit only in the return is
/// still settled by a pattern with concrete parameter types. Deliberately
/// coarse on the parameter side — one free parameter anywhere in the check's
/// parameter list asks the whole pattern list to absorb — because a
/// position-by-position reading has to model rest elements and arity
/// differences to be sound, and the shapes that need this rule (a callback
/// pattern) absorb every position anyway.
fn functionCheckDecidable(c: *Checker, chk: TypeId, ext: TypeId) Error!bool {
    const s = &c.ts;
    // The check's OWN type parameters are bound inside it and cannot be
    // substituted from outside, so they are not what makes it undecidable.
    const own = s.fnTypeParams(chk);
    var params_free = false;
    for (0..s.fnParamCount(chk)) |i| {
        if (try c.containsFreeTypeParam(s.fnParam(chk, @intCast(i)).ty, own)) {
            params_free = true;
            break;
        }
    }
    if (params_free) {
        for (0..s.fnParamCount(ext)) |i| {
            if (!absorbingPatternType(c, s.fnParam(ext, @intCast(i)).ty)) return false;
        }
    }
    if (try c.containsFreeTypeParam(s.fnReturn(chk), own)) {
        if (!absorbingPatternType(c, s.fnReturn(ext))) return false;
    }
    return true;
}

/// A pattern position that matches anything at all: `any`, `unknown`, or an
/// UNCONSTRAINED `infer` binder. A constrained binder (`infer V extends C`)
/// judges what it captures, so it absorbs nothing.
fn absorbingPatternType(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .any, .unknown => true,
        .infer_var => !c.infer_constraints.contains(c.ts.inferVarId(t)),
        else => false,
    };
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
fn arrayDecidablyExtends(c: *Checker, chk: TypeId, extends_ty: TypeId) Error!bool {
    const s = &c.ts;
    if (!try isArrayShaped(c, chk)) return false;
    const ext = try c.resolveStructural(extends_ty);
    if (s.kind(ext) != .array) return false;
    return s.kind(s.arrayElem(ext)) == .infer_var;
}

/// `t` is an array/tuple whatever its free type parameters turn out to be.
/// A BRANDED tuple (`[P, P] & { _brand: "…" }`, the shape every geometry
/// type in a branded-primitive codebase has) is array-shaped through the
/// intersection: one constituent is the tuple, and an intersection's values
/// satisfy every constituent.
fn isArrayShaped(c: *Checker, t: TypeId) Error!bool {
    // An interface/class instance is an object for every argument list, and
    // an object is not array-shaped — so the whole member table need not be
    // materialized to say no. See `refExpandsToObject`.
    if (c.refExpandsToObject(t)) return false;
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .array, .tuple, .function => return true,
        .intersection => {
            for (0..c.ts.memberCount(r)) |i| {
                if (try isArrayShaped(c, c.ts.memberAt(r, i))) return true;
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
fn objectDecidablyNotExtends(c: *Checker, chk_obj: TypeId, extends_ty: TypeId) Error!bool {
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
                if (!try objectDecidablyNotExtends(c, chk_obj, m)) return false;
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
fn collectInferVars(c: *Checker, t: TypeId, out: *std.ArrayList(u32), refs: ?*std.ArrayList(u32)) Error!void {
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
        .array => try collectInferVars(c, s.arrayElem(t), out, refs),
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| try collectInferVars(c, s.memberAt(t, i), out, refs);
        },
        .tuple => {
            for (0..s.tupleLen(t)) |i| try collectInferVars(c, s.tupleElem(t, @intCast(i)).ty, out, refs);
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| try collectInferVars(c, s.objectProp(t, @intCast(i)).ty, out, refs);
            if (s.objectStringIndex(t) != 0) try collectInferVars(c, s.objectStringIndex(t), out, refs);
            if (s.objectNumberIndex(t) != 0) try collectInferVars(c, s.objectNumberIndex(t), out, refs);
            // Call/construct signatures carry infer vars too (`new (x: infer
            // P) => …`, a `JSXElementConstructor` construct constituent).
            for (0..s.objectCallSigCount(t)) |i| try collectInferVars(c, s.objectCallSig(t, @intCast(i)), out, refs);
            for (0..s.objectConstructSigCount(t)) |i| try collectInferVars(c, s.objectConstructSig(t, @intCast(i)), out, refs);
        },
        .function => {
            for (0..s.fnParamCount(t)) |i| try collectInferVars(c, s.fnParam(t, @intCast(i)).ty, out, refs);
            try collectInferVars(c, s.fnReturn(t), out, refs);
            // The `this` parameter is a position like any other: the lib's
            // `ThisParameterType<T>` declares its variable there and nowhere
            // else (`T extends (this: infer U, ...args: never) => any ? U :
            // unknown`).
            if (s.fnThisType(t) != 0) try collectInferVars(c, s.fnThisType(t), out, refs);
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| try collectInferVars(c, s.refArgAt(t, i), out, refs);
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| try collectInferVars(c, s.templateHole(t, @intCast(i)), out, refs);
        },
        .string_mapping => try collectInferVars(c, s.stringMappingArg(t), out, refs),
        .keyof_op => try collectInferVars(c, s.keyofOperand(t), out, refs),
        // A mapped type parked by `reduceMapped` because its key set is still
        // an `infer` var: `Record<infer K, V>` is `{ [P in K]: V }`, so the
        // binder `K` lives in the mapped node, not in any arm above. Missing it
        // meant the conditional collected NO binders, never ran the match, and
        // then related its check type against an extends clause that still
        // held a raw `infer` var — which relates to nothing, so every such
        // conditional took its FALSE branch.
        //
        // Only the shapes the MATCHER can bind are claimed here. Ownership is
        // not free: an owned binder that nothing matches resolves to `unknown`
        // (see `planConcreteConditional`'s "unmatched → unknown"), and an
        // extends clause full of `unknown` relates to almost anything, so the
        // conditional flips to its TRUE branch with a meaningless value. That
        // is strictly worse than not owning it. `mappedInferShape` is the one
        // place that decides, and `inferFromExtendsInner`'s `.mapped` arm
        // consumes the same answer.
        .mapped => switch (try mappedInferShape(c, t)) {
            .key_set => |con| {
                try collectInferVars(c, con, out, refs);
                if (s.mappedValue(t) != 0) try collectInferVars(c, s.mappedValue(t), out, refs);
            },
            .none => {},
        },
        else => {},
    }
}

/// How a mapped-type PATTERN can bind `infer` binders. tsc's
/// `inferToMappedType` has two branches, keyed on the mapped type's key set;
/// this models exactly ONE of them, and deliberately declines the other.
///
/// The single source of truth for both `collectInferVars` (which binders the
/// enclosing conditional OWNS) and `inferFromExtendsInner` (what they bind to).
/// The two must never disagree: a binder that is owned but never matched
/// resolves to `unknown`, and an extends clause full of `unknown` relates to
/// almost anything, so the conditional flips to its TRUE branch carrying a
/// meaningless value.
const MappedInferShape = union(enum) {
    /// tsc's `constraintType.flags & TypeFlags.TypeParameter` branch:
    /// `{ [P in K]: V }` with an inference target in the key set K
    /// (`Record<infer N, V>`). K binds `keyof source`, and V — if it holds a
    /// binder of its own — the union of the source's property types.
    key_set: TypeId,
    none,
};

fn mappedInferShape(c: *Checker, pattern: TypeId) Error!MappedInferShape {
    const s = &c.ts;
    // A key REMAPPING (`as`) rewrites the key set, so the rule does not
    // describe it.
    if (s.mappedAs(pattern) != 0) return .none;

    // tsc's OTHER branch — `constraintType.flags & TypeFlags.Index`, the
    // HOMOMORPHIC key set `{ [P in keyof U]: X }` (written that way, which
    // parks `U` in the mapped source, or left as a real `keyof U` constraint by
    // instantiating `Pick<U, keyof U>`) — is NOT claimed here. tsc answers it
    // with `inferTypeForHomomorphicMappedType`, which synthesizes a REVERSE
    // MAPPED TYPE; ztsc has no such type, and the honest approximations are
    // both wrong:
    //
    //   * bind `U` to the source anyway. Exact only when the template is the
    //     identity `U[P]`; for a modifier (`Partial<infer U>`) or a wrapped
    //     value it silently mis-binds. Worse, it is not free even when exact —
    //     on immich it turned `As<T>` from `never` into the real repository
    //     type, which made 47 casts that had been comparing against `never`
    //     start comparing for real, and ztsc's COMPARABLE relation then
    //     rejected all 47 (`Mocked<RepositoryInterface<X>> as X`) where tsc
    //     accepts them. Measured 2026-08-10: 0 -> 47 false TS2352.
    //   * own the binder without matching it, which is the `unknown` trap
    //     above — measured as 1 false TS2345 on the same app.
    //
    // So the homomorphic branch stays UNOWNED, exactly as it was before this
    // rule existed: the conditional keeps its false branch (`never`), a
    // deterministic under-report registered in DEFERRED against
    // `conditional/048`. Implementing it needs reverse mapped types AND the
    // comparable-relation gap those 47 casts expose — neither is this rule's
    // job, and guessing here manufactures false positives on correct code.
    const con = s.mappedConstraint(pattern);
    if (con == 0) return .none; // homomorphic: `U` lives in the mapped source
    if (s.kind(con) == .keyof_op) return .none; // `Pick<U, keyof U>` after instantiation
    if (!try c.containsInfer(con)) return .none;
    return .{ .key_set = con };
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
const max_infer_depth: u32 = 24;

/// Recursive `inferFromExtends` calls one inference may make before its guards
/// arm (see the escape hatch there). Chosen from measurement, not taste: over
/// the whole eight-package parity corpus plus excalidraw the busiest single
/// inference makes ~4.6k calls, while kysely's `ExpressionOrFactory` match
/// makes tens of millions. Anything in the wide gap between separates "walk it
/// all, exactly as before" from "this will not finish".
const max_infer_steps: u64 = 100_000;

/// How deep the `.conditional` pattern arm nests. A conditional target is
/// speculative evidence — at most ONE of its two branches is real — so a
/// candidate found inside a nested conditional's branch is a guess about a
/// guess, and tsc keeps it only until any better-priority candidate appears.
///
/// ztsc bounds the descent instead of resolving it at the end, because the
/// descent is where the cost is. Measured on immich (`--inst-profile`,
/// `--checkers=1`), instantiation node visits by ceiling:
///
///     no arm at all   6.66 M   (the pre-feature baseline)
///     depth 1         6.67 M   (+0.2%)
///     depth 2         8.55 M   (+28%)
///     unbounded       9.14 M   (+37%)
///
/// and every level past the first bound NOTHING that any gate can see —
/// social-app, excalidraw, immich and the eight parity packages report the
/// same key sets at depth 1 as unbounded. This is the same kind of ceiling as
/// `max_infer_depth` and `max_infer_steps`: not a change to what the walk
/// means, but a line past which exhaustiveness stops being affordable. Raise
/// it only with a case that needs it and a re-measurement.
const max_infer_cond_depth: u32 = 1;

/// tsc's `InferencePriority`, verbatim bit values. A candidate's priority is
/// the OR of every demotion on the path from the extends clause down to the
/// binder, and `getInferredType` keeps only the candidates recorded at the
/// LOWEST (best) priority a binder ever saw — a naked variable reached through
/// a conditional's branch is "less specific" evidence than a direct structural
/// match and stands down for one.
///
/// Only the bits ztsc's `inferFromExtends` can currently produce are named
/// here; the rest of tsc's ladder is listed for the record so the values do
/// not drift when another one is implemented.
const InferPrio = struct {
    pub const none: u16 = 0;
    /// Naked type variable in a union or intersection target.
    pub const naked_type_variable: u16 = 1 << 0;
    pub const speculative_tuple: u16 = 1 << 1;
    pub const substitute_source: u16 = 1 << 2;
    pub const homomorphic_mapped_type: u16 = 1 << 3;
    pub const partial_homomorphic_mapped_type: u16 = 1 << 4;
    pub const mapped_type_constraint: u16 = 1 << 5;
    /// Conditional type in a contravariant position.
    pub const contravariant_conditional: u16 = 1 << 6;
    pub const return_type: u16 = 1 << 7;
    pub const literal_keyof: u16 = 1 << 8;
    pub const no_constraints: u16 = 1 << 9;
    pub const always_strict: u16 = 1 << 10;
    /// Seed: worse than every real priority, so the first candidate always wins.
    pub const max_value: u16 = 1 << 11;
};

/// The best priority binder `idx` has recorded a candidate at, when `vals` is
/// the array the in-flight match registered (tsc's `InferenceInfo.priority`).
/// Null for every other accumulator handed to the walk.
fn inferPrioSlot(c: *Checker, vals: []TypeId, idx: usize) ?*u16 {
    if (c.infer_prio_owner != vals.ptr) return null;
    if (c.infer_prio_of.len != vals.len) return null;
    return &c.infer_prio_of[idx];
}

/// The generic instantiation a materialized type came from — tsc's
/// `aliasSymbol`/`aliasTypeArguments` for an alias and `symbol`/`typeArguments`
/// for an interface, both of which ztsc records as the `origin` ref
/// (`makeRef(sym, args)`). A `.ref` that has not been expanded answers for
/// itself.
fn originRefOf(c: *Checker, t: TypeId) ?TypeId {
    const s = &c.ts;
    if (s.kind(t) == .ref) return t;
    if (c.origin.get(t)) |o| {
        if (s.kind(o) == .ref) return o;
    }
    return null;
}

fn originGenericSymbol(c: *Checker, t: TypeId) ?u32 {
    const o = originRefOf(c, t) orelse return null;
    return c.ts.refSymbol(o);
}

/// tsc's `isTypeCloselyMatchedBy` — "s and t are two instantiations of the
/// same generic", by declaring symbol for an object type and by alias symbol
/// for an alias. It is the second of `inferFromMatchingTypes`'s two passes
/// over a union's constituents, and it is what pairs `RefCallback<X>` with
/// `RefCallback<infer M>` inside a multi-constituent union target instead of
/// offering each target the whole source union.
pub fn inferCloselyMatched(c: *Checker, src: TypeId, pat: TypeId) bool {
    const a = originGenericSymbol(c, src) orelse return false;
    const b = originGenericSymbol(c, pat) orelse return false;
    return a == b;
}

/// tsc's `getSignaturesOfType(intersection, kind)` — `resolveIntersectionTypeMembers`
/// builds an intersection's signature list by CONCATENATING its constituents'
/// lists in declaration order:
///
///     callSignatures = appendSignatures(callSignatures, getSignaturesOfType(t, Call));
///
/// and `getSignaturesOfType` on an interface reads its RESOLVED members, so a
/// signature a constituent only INHERITS is in the list too. `inferFromSignatures`
/// then pairs source and target lists from the END, so a single-signature pattern
/// — every `T extends (…) => infer R`, `T extends new (…) => infer R` and
/// `JSXElementConstructor<infer P>` — reads the LAST signature of the whole
/// concatenation: the last signature of the last constituent that has one.
///
/// Returns that signature (a `.function` TypeId, ready to hand to
/// `inferFromExtends`), or null when no constituent is callable of this kind.
///
/// Before this the two inference arms below only recognised a BARE `.function`
/// or `.overloads` constituent, so an intersection whose callable member is an
/// interface or type literal — the shape every `styled(X)` component has, and
/// every `Callable & {…}` value object — matched nothing, left the binder at
/// `unknown`, and dropped the conditional to its FALSE branch. It cost outline
/// ~90 keys on styled-components alone (`ComponentProps<typeof Styled>` fell to
/// `JSXElementConstructor`'s fallback, so every prop of every styled component
/// was an excess TS2322/TS7006).
fn intersectionLastSig(c: *Checker, isect: TypeId, is_construct: bool) Error!?TypeId {
    const s = &c.ts;
    // Duped: `resolveStructural` and the signature readers below intern, which
    // can move the store's member arrays (see `memberAt`).
    const members = try c.scratch().dupe(TypeId, try c.memberList(isect));
    defer c.scratch().free(members);
    var last: ?TypeId = null;
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        switch (s.kind(rm)) {
            // A bare function type has a call signature and no construct one.
            .function => if (!is_construct) {
                last = rm;
            },
            .overloads => if (!is_construct) {
                if (try c.lastCallSig(rm)) |sig| last = sig;
            },
            .object => {
                const n = if (is_construct) s.objectConstructSigCount(rm) else s.objectCallSigCount(rm);
                if (n > 0) last = if (is_construct) s.objectConstructSig(rm, n - 1) else s.objectCallSig(rm, n - 1);
            },
            else => {},
        }
    }
    return last;
}

/// tsc's `inferToMultipleTypes`, union form: every target constituent that
/// can bind receives the source, and the ones that ARE a binder receive it
/// last and at `InferencePriority.NakedTypeVariable` —
///
///     // Inferences directly to naked type variables are given lower priority
///     // as they are less specific.
///     if (typeVariableCount > 0) for (const t of targets)
///       if (getInferenceInfoForType(t)) inferWithPriority(source, t, NakedTypeVariable);
///
/// so a wrapper constituent that names the binder structurally
/// (`RefObject<M | null>`) outranks the bare `M | undefined` arm beside it.
fn inferToUnionTargets(c: *Checker, src0: TypeId, targets: []const TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    var naked = false;
    for (targets) |m| {
        if (!try c.containsInfer(m)) continue;
        if (s.kind(m) == .infer_var) {
            naked = true;
            continue;
        }
        try c.inferFromExtends(src0, m, ids, vals, contra, depth + 1);
    }
    if (!naked) return;
    const saved = c.infer_prio;
    c.infer_prio |= InferPrio.naked_type_variable;
    defer c.infer_prio = saved;
    for (targets) |m| {
        if (s.kind(m) != .infer_var) continue;
        if (!try c.containsInfer(m)) continue;
        try c.inferFromExtends(src0, m, ids, vals, contra, depth + 1);
    }
}

fn inferFromExtendsInner(c: *Checker, source0: TypeId, pattern: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    switch (s.kind(pattern)) {
        .infer_var => {
            const idx = indexOfId(ids, s.inferVarId(pattern)) orelse return;
            // tsc's `inferFromTypes` type-variable case:
            //
            //     if (inference.priority === undefined || priority < inference.priority) {
            //       inference.candidates = undefined; inference.priority = priority;
            //     }
            //     if (priority === inference.priority) { …record the candidate… }
            //
            // A better priority throws the whole candidate set away and starts
            // over; a worse one contributes nothing at all.
            if (inferPrioSlot(c, vals, idx)) |p| {
                if (c.infer_prio > p.*) return;
                if (c.infer_prio < p.*) {
                    p.* = c.infer_prio;
                    vals[idx] = source0;
                    return;
                }
            }
            if (vals[idx] == types.no_type) {
                vals[idx] = source0;
            } else if (contra) {
                // tsc's `getTypeFromInference` intersects the contravariant
                // candidates — which is what makes `UnionToIntersection<U>`
                // work once a union source distributes over the pattern.
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
        // `{ [P in K]: X }` with an `infer` var in its KEY SET — tsc's
        // `inferToMappedType`. `keyof source` is inferred for the key set and
        // the union of the source's property types for the template `X`, which
        // is what lets `T extends Record<infer K, V> ? K : never` name T's own
        // keys. Without an arm here the pattern matched nothing, the var stayed
        // unbound, and the whole conditional fell to its FALSE branch — expo's
        // `InferEventName<TEventsMap> = TEventsMap extends Record<infer N
        // extends keyof TEventsMap, AnyEventListener> ? N : never` resolved to
        // `never`, so every `useEvent(player, 'statusChange', …)` rejected its
        // own event name and the listener lost its contextual signature.
        //
        // `mappedInferShape` decides which binders this pattern owns, and
        // `collectInferVars` claims exactly those — the two must stay in step.
        .mapped => {
            const con = switch (try mappedInferShape(c, pattern)) {
                .key_set => |con| con,
                .none => return,
            };
            const src = try c.resolveStructural(source0);
            if (s.kind(src) != .object) return;
            try c.inferFromExtends(try c.keyofType(src), con, ids, vals, contra, depth + 1);
            const val = s.mappedValue(pattern);
            if (val != 0 and try c.containsInfer(val)) {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                for (0..s.objectPropCount(src)) |i| {
                    try parts.append(c.scratch(), s.objectProp(src, @intCast(i)).ty);
                }
                if (s.objectStringIndex(src) != 0) {
                    try parts.append(c.scratch(), s.objectStringIndex(src));
                }
                if (parts.items.len != 0) {
                    const u = try c.ts.makeUnion(c.scratch(), parts.items);
                    try c.inferFromExtends(u, val, ids, vals, contra, depth + 1);
                }
            }
        },
        .object => {
            var src = try c.resolveStructural(source0);
            // A construct-signature pattern (`abstract new (…args: any) =>
            // infer R`, the shape of `InstanceType`/`ConstructorParameters`)
            // against a class value: `.class_value` is nominal and carries
            // no structural signatures, so bridge it to its constructor
            // object first. Only for signature-bearing patterns — a plain
            // property pattern reads the statics directly, in the
            // `.class_value` arm below.
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
                // tsc's `inferFromObjectTypes` runs `inferFromSignatures` for
                // both signature kinds on an INTERSECTION source too — an
                // intersection's own signature list is the concatenation of its
                // constituents' (see `intersectionLastSig`), so the pattern's
                // last signature pairs with the last one in that list. This is
                // the construct-signature half of the styled-components /
                // `ComponentProps` failure: `JSXElementConstructor<infer P>`'s
                // class constituent is a `new (props: infer P) => …` OBJECT, so
                // it lands here and not in the `.function` arm.
                inline for (.{ false, true }) |is_construct| {
                    const pn = if (is_construct) s.objectConstructSigCount(pattern) else s.objectCallSigCount(pattern);
                    if (pn > 0) {
                        if (try intersectionLastSig(c, src, is_construct)) |ssig| {
                            const psig = if (is_construct) s.objectConstructSig(pattern, pn - 1) else s.objectCallSig(pattern, pn - 1);
                            try c.inferFromExtends(ssig, psig, ids, vals, contra, depth + 1);
                        }
                    }
                }
                return;
            }
            // A CLASS VALUE against a plain property pattern — `C extends {
            // defaultProps: infer D }`, which is every arm of JSX's
            // `LibraryManagedAttributes`. `.class_value` is nominal: its
            // statics and its `prototype` come from the class SYMBOL, not from
            // a member table, so the `!= .object` bail below left every infer
            // var of such a pattern unbound and it resolved to `unknown`.
            //
            // The failure was silent because the conditional still MATCHED —
            // the relation reads statics perfectly well — so `T extends {
            // defaultProps: infer X } ? X : "NO"` took the TRUE branch and
            // answered `unknown` rather than falling to `"NO"`.
            //
            // `propOfTypeEx` is the lookup that reads a class value's statics
            // (the same one `C.defaultProps` and the `extends` check use), so
            // this is the plain-object walk below with the source read through
            // it. `allow_index = false` for the reason that walk gives: an
            // apparent `Object`/`Function` member is not a declared property
            // and must not seed a candidate.
            if (s.kind(src) == .class_value) {
                for (0..s.objectPropCount(pattern)) |i| {
                    const pp = s.objectProp(pattern, @intCast(i));
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
            try inferFromObjectSigs(c, src, pattern, false, ids, vals, contra, depth);
            try inferFromObjectSigs(c, src, pattern, true, ids, vals, contra, depth);
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
            //     `unknown`;
            //   * a callable OBJECT (interface or type literal) member —
            //     React's `ForwardRefExoticComponent<P> & {…}` and every
            //     styled-components `StyledComponent`, whose call signature
            //     lives INSIDE an object member, and may be INHERITED by it,
            //     rather than sitting there as a bare `.function`.
            //
            // WHICH constituent, when more than one is callable, is the
            // end-aligned rule `intersectionLastSig` implements — the last
            // signature of the last callable constituent. Oracle-verified
            // against tsgo 7.0.2 in
            // `test/conformance/inference/intersection_infers_last_call_
            // signature.ts`: `(() => "x") & (() => "y")` infers `"y"`, a third
            // constituent wins over both, an object member in between changes
            // nothing, and `((...) => "plain") & typeof overloaded` infers the
            // OVERLOAD SET's last return while the reverse order infers
            // `"plain"`.
            if (s.kind(src) == .intersection) {
                src = (try intersectionLastSig(c, src, false)) orelse return;
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
            // A UNION source against a single-signature pattern infers from
            // each constituent (tsc's `inferFromTypes`: once the target is
            // neither a union nor a type variable, "source is a union type,
            // infer from each constituent type"). The candidates then combine
            // by position — `getTypeFromInference` unions covariant candidates
            // and INTERSECTS contravariant ones — which is the entire
            // mechanism behind the `UnionToIntersection<U>` idiom:
            //
            //     type UnionToIntersection<U> =
            //       (U extends any ? (k: U) => void : never) extends
            //         (k: infer I) => void ? I : never
            //
            // The distributive check type is a UNION of one-parameter
            // functions, so `I` collects one contravariant candidate per
            // constituent and comes out as their intersection. Without this
            // the whole pattern matched nothing and the conditional fell to
            // its `never` branch: tiptap's `UnionCommands`/`SingleCommands`/
            // `ChainedCommands` are built exactly this way, so social-app's
            // `TextInput.web.tsx` saw `editor.commands` and `editor.chain()`
            // as `never` and every command on them was a TS2339.
            //
            // This used to be limited to the TOP of the match (`depth == 0`).
            // Deeper, a union source reaching a signature pattern is one arm of
            // a multi-constituent union TARGET (`ref?: RefCallback<M> |
            // RefObject<M | null> | null`), and distributing there manufactured
            // candidates that flipped `TRef extends AnimatedComponentType<any,
            // infer Instance>` in react-native-reanimated to its false branch —
            // every `useAnimatedRef<Animated.View>()` stopped matching its own
            // component's `ref` (3 added keys on social-app).
            //
            // The restriction is gone because its cause is: a union target now
            // pairs its constituents by generic identity
            // (`isTypeCloselyMatchedBy`) instead of handing each of them the
            // whole union, and a conditional target infers into both branches
            // at a demoted priority — so `Instance` has a real candidate and no
            // junk one can displace it. Removing the guard is a no-op on every
            // gate (social-app, excalidraw, immich, the eight parity packages,
            // conformance) and on immich's instantiation node visits.
            if (s.kind(src) == .union_type) {
                const umembers = try c.scratch().dupe(TypeId, try c.memberList(src));
                defer c.scratch().free(umembers);
                // Same `depth`, not `depth + 1`: distributing a union over the
                // same target is not a structural descent (tsc recurses with no
                // notion of depth here), and charging it a level pushed deep
                // chains past `max_infer_depth` and truncated candidates that
                // used to bind.
                for (umembers) |m| try c.inferFromExtends(m, pattern, ids, vals, contra, depth);
                return;
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
            // A `this` parameter pairs CONTRAVARIANTLY, exactly as an ordinary
            // parameter does — tsc's `inferFromSignature` head, which runs the
            // pair through `inferFromContravariantTypes` before touching the
            // parameter list, and only when the SOURCE declares one (an absent
            // `this` leaves the pattern's variable unbound, which is precisely
            // what makes `ThisParameterType<() => void>` land on `unknown`).
            //
            // Without it the lib's
            //   `type ThisParameterType<T> =
            //        T extends (this: infer U, ...args: never) => any ? U : unknown`
            // left `U` unbound for EVERY `this`-annotated function, so the
            // conditional's own check (`this: unknown` against the source's
            // real receiver) failed and the answer was always `unknown`. That
            // in turn made `OmitThisParameter` the identity and let
            // `CallableFunction.bind`'s first overload accept any `thisArg`
            // at all.
            {
                const p_this = s.fnThisType(pattern);
                const s_this = s.fnThisType(src);
                if (p_this != 0 and s_this != 0) {
                    var st = s_this;
                    if (base_map.items.len != 0) st = try c.instantiate(st, base_map.items);
                    try c.inferFromExtends(st, p_this, ids, vals, !contra, depth + 1);
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
        // A CONDITIONAL pattern — tsc's `inferFromTypes`:
        //
        //     else if (target.flags & TypeFlags.Conditional) {
        //       invokeOnce(source, target, (source, target) => {
        //         const savePriority = priority;
        //         priority |= contravariant ? InferencePriority.ContravariantConditional : 0;
        //         const targetTypes = [getTrueTypeFromConditionalType(target),
        //                              getFalseTypeFromConditionalType(target)];
        //         inferToMultipleTypes(source, targetTypes, target.flags);
        //         priority = savePriority;
        //       });
        //     }
        //
        // The source is offered to BOTH branches, and everything it binds
        // there is demoted — `ContravariantConditional` in a contravariant
        // position, and `NakedTypeVariable` for a branch that IS the binder,
        // since `inferToMultipleTypes` treats the two branches as a union
        // target. Both demotions matter: this is the weakest evidence the walk
        // can produce (the conditional has not been decided, so at most one
        // branch is real), and the ladder is what lets a direct structural
        // match elsewhere throw it away.
        //
        // With no arm here, a binder reachable only through a conditional was
        // never inferred at all. react-native-reanimated's
        //     type ExtractElementRef<TRef> =
        //       TRef extends ElementType
        //         ? ComponentRef<TRef> extends never ? TRef : ComponentRef<TRef>
        //         : TRef
        // wraps every occurrence of `Instance` inside
        // `AnimatedComponentRef<Instance>`, so `TRef extends
        // AnimatedComponentType<any, infer Instance>` left `Instance` at
        // `unknown` and every `useAnimatedRef<Animated.X>().current` lost its
        // members.
        .conditional => {
            if (c.infer_cond_depth >= max_infer_cond_depth) return;
            c.infer_cond_depth += 1;
            defer c.infer_cond_depth -= 1;
            const saved = c.infer_prio;
            if (contra) c.infer_prio |= InferPrio.contravariant_conditional;
            defer c.infer_prio = saved;
            const branches = [2]TypeId{ s.condTrue(pattern), s.condFalse(pattern) };
            // `inferToMultipleTypes`, union form: the non-variable branches
            // first, then the naked ones at `NakedTypeVariable`.
            for (branches) |b| {
                if (s.kind(b) == .infer_var) continue;
                if (!try c.containsInfer(b)) continue;
                try c.inferFromExtends(source0, b, ids, vals, contra, depth + 1);
            }
            const inner = c.infer_prio;
            for (branches) |b| {
                if (s.kind(b) != .infer_var) continue;
                c.infer_prio = inner | InferPrio.naked_type_variable;
                try c.inferFromExtends(source0, b, ids, vals, contra, depth + 1);
                c.infer_prio = inner;
            }
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
            // tsc runs `inferFromMatchingTypes` TWICE over the two constituent
            // lists: once with `isTypeOrBaseIdenticalTo` (the subtraction
            // above) and then again with `isTypeCloselyMatchedBy`, which pairs
            // a source and a target constituent that are two instantiations of
            // the SAME generic — `s.symbol === t.symbol` for an object, or
            // `s.aliasSymbol === t.aliasSymbol` for an alias. Each such pair is
            // inferred on its own and BOTH sides are then removed, so a target
            // constituent never sees a source constituent that some other
            // target already accounts for.
            //
            // This is what makes a multi-constituent union target infer at all.
            // React 19's
            //     interface RefAttributes<T> {
            //       ref?: RefCallback<T> | RefObject<T | null> | null
            //     }
            //     type ComponentRef<T> =
            //       ComponentPropsWithRef<T> extends RefAttributes<infer M> ? M : never
            // reaches here with the whole source union
            // `RefCallback<ScrollView> | RefObject<ScrollView | null>` and two
            // wrapper targets. Handing that union to each target infers
            // nothing — a union is neither a function nor a `RefObject` — so
            // `M` stayed unbound, the extends check failed and the conditional
            // took its `never` branch. Every `useAnimatedRef<Animated.X>()`
            // in react-native-reanimated resolves its `.current` through this
            // conditional, so the ref's methods (`getScrollResponder`,
            // `getScrollableNode`) were all TS2339.
            //
            // Pairing by symbol is deliberately narrower than distributing
            // every source constituent into every target: it manufactures no
            // candidate from an unrelated pair, which is exactly the failure
            // mode that made the unrestricted distribution regress
            // reanimated's `AnimatedComponentRef<Instance>` union (see
            // `conditional/049`).
            var t_paired = try c.scratch().alloc(bool, pms.len);
            @memset(t_paired, false);
            var any_close = false;
            const rms: []const TypeId = if (s.kind(residual) == .union_type)
                try c.scratch().dupe(TypeId, try c.memberList(residual))
            else
                &.{residual};
            var s_paired = try c.scratch().alloc(bool, rms.len);
            @memset(s_paired, false);
            for (pms, 0..) |pm, ti| {
                if (!try c.containsInfer(pm)) continue;
                for (rms, 0..) |sm, si| {
                    if (!c.inferCloselyMatched(sm, pm)) continue;
                    try c.inferFromExtends(sm, pm, ids, vals, contra, depth + 1);
                    t_paired[ti] = true;
                    s_paired[si] = true;
                    any_close = true;
                }
            }
            if (!any_close) {
                try inferToUnionTargets(c, residual, pms, ids, vals, contra, depth);
                return;
            }
            // `if (targets.length === 0) return;` — every inference-bearing
            // target constituent has been accounted for by a pair.
            var left_t = false;
            for (pms, 0..) |m, ti| {
                if (t_paired[ti]) continue;
                if (try c.containsInfer(m)) left_t = true;
            }
            if (!left_t) return;
            var rest: std.ArrayList(TypeId) = .empty;
            defer rest.deinit(c.scratch());
            for (rms, 0..) |sm, si| {
                if (!s_paired[si]) try rest.append(c.scratch(), sm);
            }
            // `if (sources.length === 0)` — tsc still offers the source it
            // started with rather than nothing at all.
            const rest_src = if (rest.items.len == 0)
                residual
            else
                try s.makeUnion(c.scratch(), rest.items);
            var left: std.ArrayList(TypeId) = .empty;
            defer left.deinit(c.scratch());
            for (pms, 0..) |m, ti| {
                if (!t_paired[ti]) try left.append(c.scratch(), m);
            }
            try inferToUnionTargets(c, rest_src, left.items, ids, vals, contra, depth);
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
                try inferFromTemplate(c, c.atomText(atom_), pattern, ids, vals);
            } else if (s.kind(src) == .template_literal_type) {
                try inferFromTemplateSource(c, src, pattern, ids, vals, contra, depth);
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
fn inferFromObjectSigs(c: *Checker, src: TypeId, pattern: TypeId, is_construct: bool, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
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
            if (s.fnThisType(t) != 0 and try c.containsInfer(s.fnThisType(t))) break :blk true;
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
///
/// `pub` for `assign.zig`'s `condTrueSubstituted`, which needs the same
/// replacement over an `infer` binder used as a CHECK type — the shape a
/// constrained `infer T extends C` desugars into.
pub fn substInfer(c: *Checker, t: TypeId, ids: []const u32, vals: []const TypeId) Error!TypeId {
    if (ids.len == 0 or !try c.containsInfer(t)) return t;
    const s = &c.ts;
    switch (s.kind(t)) {
        .infer_var => {
            const idx = indexOfId(ids, s.inferVarId(t)) orelse return t;
            return vals[idx];
        },
        .array => return s.makeArrayLike(t, try substInfer(c, s.arrayElem(t), ids, vals)),
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try substInfer(c, m, ids, vals));
            return s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try substInfer(c, m, ids, vals));
            return s.makeIntersection(c.scratch(), parts.items);
        },
        .overloads => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try substInfer(c, m, ids, vals));
            return s.makeOverloads(parts.items);
        },
        .tuple => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try substInfer(c, e.ty, ids, vals), .flags = e.flags });
            }
            return s.makeTupleLike(t, elems.items);
        },
        .object => {
            var props: std.ArrayList(types.Prop) = .empty;
            defer props.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try props.append(c.scratch(), .{ .name = p.name, .ty = try substInfer(c, p.ty, ids, vals), .flags = p.flags });
            }
            const sidx = if (s.objectStringIndex(t) != 0) try substInfer(c, s.objectStringIndex(t), ids, vals) else 0;
            const nidx = if (s.objectNumberIndex(t) != 0) try substInfer(c, s.objectNumberIndex(t), ids, vals) else 0;
            // Preserve and substitute call/construct signatures — dropping
            // them (the old `makeObject` path) lost the inferred `new (props:
            // P) => …` shape needed to decide a construct-pattern conditional.
            if (s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0)
                return s.makeObject(props.items, sidx, nidx, s.objectFlags(t));
            var call_sigs: std.ArrayList(TypeId) = .empty;
            defer call_sigs.deinit(c.scratch());
            var construct_sigs: std.ArrayList(TypeId) = .empty;
            defer construct_sigs.deinit(c.scratch());
            for (0..s.objectCallSigCount(t)) |i| try call_sigs.append(c.scratch(), try substInfer(c, s.objectCallSig(t, @intCast(i)), ids, vals));
            for (0..s.objectConstructSigCount(t)) |i| try construct_sigs.append(c.scratch(), try substInfer(c, s.objectConstructSig(t, @intCast(i)), ids, vals));
            return s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
        },
        .function => {
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try substInfer(c, p.ty, ids, vals), .flags = p.flags });
            }
            const ret = try substInfer(c, s.fnReturn(t), ids, vals);
            const this_ty = s.fnThisType(t);
            return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), null, if (this_ty != 0) try substInfer(c, this_ty, ids, vals) else 0);
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try substInfer(c, a, ids, vals));
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
                            try parts.append(c.scratch(), try substInfer(c, t, ids, vals2));
                        }
                        return s.makeUnion(c.scratch(), parts.items);
                    }
                }
            }
            const chk = try substInfer(c, check0, ids, vals);
            const ext = try substInfer(c, s.condExtends(t), ids, vals);
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
                .take_false => return substInfer(c, s.condFalse(t), ids, vals),
                .take_true => |b| return c.condTrueBranch(b, try substInfer(c, s.condTrue(t), ids, vals)),
                .both_any, .need_both => {
                    const tru = try substInfer(c, s.condTrue(t), ids, vals);
                    const fls = try substInfer(c, s.condFalse(t), ids, vals);
                    return c.finishCondPlan(plan, chk, ext, tru, fls, s.condDistributive(t));
                },
            }
        },
        .index_access => {
            const obj = try substInfer(c, s.indexAccessObj(t), ids, vals);
            const idx = try substInfer(c, s.indexAccessIndex(t), ids, vals);
            return c.reduceIndexedAccess(obj, idx);
        },
        .template_literal_type => {
            var holes: std.ArrayList(TypeId) = .empty;
            defer holes.deinit(c.scratch());
            for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try substInfer(c, s.templateHole(t, @intCast(i)), ids, vals));
            return c.reduceTemplate(s.templateHead(t), holes.items, t);
        },
        .string_mapping => return c.applyStringMapping(s.stringMappingKind(t), try substInfer(c, s.stringMappingArg(t), ids, vals)),
        .keyof_op => return c.keyofType(try substInfer(c, s.keyofOperand(t), ids, vals)),
        // Re-enter `reduceMapped` with the branches' `infer` vars bound: a
        // mapped alias deferred while its key source was still an `infer` var
        // (see `reduceMapped`) now materializes its key set. Without this arm
        // the map falls through unchanged and stays `{}`.
        .mapped => {
            const kp = s.mappedKeyParam(t); // key param identity is stable
            const con = try substInfer(c, s.mappedConstraint(t), ids, vals);
            const val = try substInfer(c, s.mappedValue(t), ids, vals);
            const as_c = if (s.mappedAs(t) != 0) try substInfer(c, s.mappedAs(t), ids, vals) else 0;
            const src = if (s.mappedSource(t) != 0) try substInfer(c, s.mappedSource(t), ids, vals) else 0;
            return c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
        },
        else => return t,
    }
}

// =====================================================================
// re-exports: the two extracted concerns stay reachable as `generics.<name>`
// (`Checker`'s alias block and several modules import them from here).
// =====================================================================

const mapped_zig = @import("mapped.zig");
pub const mappedKeyId = mapped_zig.mappedKeyId;
pub const mappedTypeFromNode = mapped_zig.mappedTypeFromNode;
pub const reduceMapped = mapped_zig.reduceMapped;
pub const applyPropModifiers = mapped_zig.applyPropModifiers;
pub const applyElemModifiers = mapped_zig.applyElemModifiers;
pub const isPrimitiveForHomomorphicMap = mapped_zig.isPrimitiveForHomomorphicMap;
pub const materializeMapped = mapped_zig.materializeMapped;
pub const substHomoSource = mapped_zig.substHomoSource;
pub const collectHomoProps = mapped_zig.collectHomoProps;
pub const HomoIndex = mapped_zig.HomoIndex;
pub const collectHomoIndex = mapped_zig.collectHomoIndex;
pub const collectMappedKeys = mapped_zig.collectMappedKeys;
pub const objectFromProps = mapped_zig.objectFromProps;
pub const objectFromPropsFlags = mapped_zig.objectFromPropsFlags;
pub const remapKey = mapped_zig.remapKey;
pub const numberLiteralAtom = mapped_zig.numberLiteralAtom;
pub const reduceIndexedAccess = mapped_zig.reduceIndexedAccess;
pub const simplifyMappedIndexAccess = mapped_zig.simplifyMappedIndexAccess;
pub const isGenericObjectForIndex = mapped_zig.isGenericObjectForIndex;
pub const containsMappedParam = mapped_zig.containsMappedParam;
pub const containsMappedParamInner = mapped_zig.containsMappedParamInner;
pub const mentionsMappedParam = mapped_zig.mentionsMappedParam;
pub const mentionsMappedParamInner = mapped_zig.mentionsMappedParamInner;
pub const substMappedKey = mapped_zig.substMappedKey;

const template_zig = @import("template.zig");
pub const intrinsicStringMapping = template_zig.intrinsicStringMapping;
pub const aliasBodyIsIntrinsic = template_zig.aliasBodyIsIntrinsic;
pub const templateChunkText = template_zig.templateChunkText;
pub const templateHeadText = template_zig.templateHeadText;
pub const ctxWantsTemplate = template_zig.ctxWantsTemplate;
pub const typeIsStringLike = template_zig.typeIsStringLike;
pub const templateChunkTokAfter = template_zig.templateChunkTokAfter;
pub const templateExprType = template_zig.templateExprType;
pub const templateTypeFromNode = template_zig.templateTypeFromNode;
pub const reduceTemplate = template_zig.reduceTemplate;
pub const TplBuilder = template_zig.TplBuilder;
pub const reduceTemplateChunks = template_zig.reduceTemplateChunks;
pub const evalTemplate = template_zig.evalTemplate;
pub const cloneBuilder = template_zig.cloneBuilder;
pub const freeBuilder = template_zig.freeBuilder;
pub const appendConcrete = template_zig.appendConcrete;
pub const enumerableForms = template_zig.enumerableForms;
pub const stringLiteralOf = template_zig.stringLiteralOf;
pub const applyStringMapping = template_zig.applyStringMapping;
pub const transformString = template_zig.transformString;
pub const matchTemplatePattern = template_zig.matchTemplatePattern;
pub const matchTplHole = template_zig.matchTplHole;
pub const holeAccepts = template_zig.holeAccepts;
pub const isNumericString = template_zig.isNumericString;
const inferFromTemplate = template_zig.inferFromTemplate;
pub const bindTemplateInfer = template_zig.bindTemplateInfer;
const inferFromTemplateSource = template_zig.inferFromTemplateSource;
pub const matchTemplateParts = template_zig.matchTemplateParts;
pub const normalizeTextlessTemplate = template_zig.normalizeTextlessTemplate;
