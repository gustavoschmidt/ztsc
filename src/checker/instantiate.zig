//! Named-type expansion and generic instantiation: `Alias<args>` reduced to
//! its body (`aliasInstance` / `aliasGeneric`), `ref(sym, args)` materialized
//! into a structural shape (`expandRef` / `resolveStructural`), and the LAZY
//! per-member tables that answer one slot of a `.ref` — one property, one
//! index signature — without materializing the whole object.
//!
//! Two neighbours were split out and are re-exported at the bottom of this
//! file, because `Checker`'s alias block names them here: `classes.zig` (the
//! nominal `interface` / `class` shapes this file expands references TO) and
//! `shrink.zig` (the structural termination heuristics that decide how far a
//! recursive alias may be driven eagerly).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_alias_depth = checker_zig.max_alias_depth;
const prof_zig = checker_zig.prof_zig;

const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;

// =====================================================================
// named-type expansion & instantiation
// =====================================================================

/// Record every alias on the cycle a reference to the in-progress `sym` just
/// closed: the `alias_stack` suffix from `sym`'s own frame up to the innermost
/// one. `aliasGeneric` pushes a frame per body it materializes, so that suffix
/// is exactly the chain of aliases whose bodies name each other back around to
/// `sym`.
///
/// THE SUFFIX, NOT `sym` ALONE, IS WHAT MAKES THE ANSWER DETERMINISTIC.
/// Marking only `sym` names whichever member of a mutually recursive cluster
/// this checker instance entered FIRST, which is a function of the file order
/// and the cost partition — the confirmed root cause of social-app's
/// `Navigation.tsx:778` printing `NativeStackNavigationProp<{…}>` under one
/// partition and the expanded 40-member object under another. The suffix is a
/// property of the alias GRAPH instead: `aliasGeneric` walks the same body from
/// every entry point, so whichever member is entered first, the same set comes
/// back marked.
///
/// Scanning from the top and stopping at the FIRST `sym` found is right even if
/// a frame for `sym` could appear twice — the innermost occurrence is the one
/// this reference closed against.
fn markCycle(c: *Checker, sym: SymbolId) Error!void {
    var i = c.alias_stack.items.len;
    // A cut against the INNERMOST frame is a cycle of length one: the body
    // being materialized is `sym`'s own and it names `sym` back directly.
    if (i > 0 and c.alias_stack.items[i - 1] == sym) {
        try c.alias_self_recursive.put(c.cm(), sym, {});
    }
    while (i > 0) {
        i -= 1;
        const frame = c.alias_stack.items[i];
        try c.alias_recursive.put(c.cm(), frame, {});
        if (frame == sym) return;
    }
    // `sym` is in progress but owns no frame: it is being materialized by
    // something other than `aliasGeneric` (a merged declaration walked from
    // `typespace`, say). Mark it alone — the same answer the pre-cycle rule
    // gave, and still a function of `sym` only.
    try c.alias_recursive.put(c.cm(), sym, {});
}

pub fn aliasInstance(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!TypeId {
    // Crash guard for pathological mutually-recursive generic alias chains
    // (see `max_alias_depth`). `alias_state` only breaks direct self-
    // recursion; a chain through distinct syms is bounded here.
    if (c.alias_depth >= max_alias_depth) {
        // Depth-dependent, so it must suppress memoization of every enclosing
        // substitution the same way the instantiation depth cap does — see
        // `substThis`.
        c.inst_limit_tripped = true;
        return types.error_type;
    }
    c.alias_depth += 1;
    defer c.alias_depth -= 1;
    const state = c.alias_state.get(sym) orelse 0;
    if (state == 1) {
        // In-progress: recursive alias; leave a lazy ref, and record the whole
        // cycle this reference just closed.
        try markCycle(c, sym);
        const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
        return c.ts.makeRef(sym, fixed);
    }
    // BODY FIRST, THEN THE DEFAULTS. `fixTypeArgs` reads whether `sym` is on a
    // cycle (`alias_recursive`, below) to decide how far it may thread a
    // supplied argument into a type parameter's DEFAULT. Reading that from
    // inside `fixTypeArgs` used to mean forcing `aliasGeneric` from there,
    // which re-enters `fixTypeArgs` through the body's own references and
    // overflows the stack on react-navigation. Materializing the body here
    // instead answers the question before the defaults are filled, off the
    // recursive path. Measured neutral on excalidraw and social-app.
    const generic = try c.aliasGeneric(sym);
    const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
    // ONE SPELLING for an alias that lies on a materialization CYCLE.
    //
    // The cycle-cut arm above leaves a lazy `.ref` for every reference taken
    // while the body was still materializing; a reference taken afterwards
    // gets a separately interned structural materialization. Both denote the
    // same type, but they are distinct `TypeId`s, so `makeUnion` /
    // `makeIntersection` cannot dedupe them and a union can carry the same
    // type under both spellings — and WHICH references fall inside the cycle
    // depends on the order files are visited, i.e. on the checker count.
    // Answering with the ref in BOTH cases makes the spelling one thing.
    //
    // The keying is `markCycle`'s: the WHOLE cycle, read off the `alias_stack`
    // suffix, which is a property of the alias GRAPH. The predecessor marked
    // only the member a checker instance entered FIRST, and that is what made
    // social-app's `Navigation.tsx:778` print `NativeStackNavigationProp<{…}>`
    // under one partition and the expanded 40-member object under another —
    // @react-navigation's `NativeStackNavigationProp` reaches
    // `NativeStackHeaderProps` through its options and `NativeStackHeaderProps`
    // declares `navigation: NativeStackNavigationProp<…>` straight back, so
    // entering at either end marked that end. See `markCycle`.
    //
    // TWO ARMS, TWO PURPOSES. They are not one rule with a widened scope:
    //
    //   * SELF-recursive (cycle length one) over an `originTaggable` body —
    //     object, function, intersection or mapped, exactly the set the
    //     `origin` machinery already treats as "a ref and its materialization
    //     are interchangeable". This arm exists for VARIANCE.
    //     `compiler/varianceMeasurement.ts` pins it. tsc never materializes
    //     `Foo3<unknown>` at all — it keeps an object carrying `aliasSymbol` /
    //     `aliasTypeArguments` and relates two of them by `getAliasVariances`,
    //     so the body is never walked. ztsc interns structurally, so the `.ref`
    //     is the only spelling that survives interning as "alias A at these
    //     arguments", and `assign.relate` asks for variance only on a declared
    //     `.ref`/`.ref` pair (an `origin` tag cannot stand in — a hand-written
    //     structural type interns equal to an alias's expansion and would
    //     inherit its variance; see the `Record<string, unknown>` note there).
    //     Materialize a self-recursive alias and the top-level pair stops being
    //     refs, the variance shortcut is skipped, and the walk descends into a
    //     body that names the alias one level down, where the arguments are a
    //     contravariant hop further in and no longer relate: `Foo3<unknown> =
    //     Foo3<string>` at varianceMeasurement.ts:37 becomes a fresh TS2322.
    //
    //   * ANY cycle member whose body is an `.intersection`. This arm exists
    //     for MIXING — for the defect in the first paragraph. Excalidraw's
    //     `BoundElement` ↔ `ExcalidrawLinearElement` pair is the measured case:
    //     with only one member keeping the ref, both spellings land in one
    //     union and print as `readonly { id: string; type: "arrow" | "text"; }[]
    //     | readonly BoundElement[] | null`, after which `Mutable<NonNullable
    //     <…>>` over it reduces to `{}` and four diagnostics follow
    //     (restore.ts:404/417, newElement.ts:749/756). Marking the whole cycle
    //     is what lets BOTH members keep it.
    //
    // A UNION body must stay materialized under either arm: a `.ref` standing
    // in for a union is NOT interchangeable, because discriminant narrowing and
    // the union-source relation arms switch on `.union_type` directly.
    //
    // WHY THE INTERSECTION ARM IS NOT WIDENED TO `originTaggable`. Measured on
    // social-app: it costs five fresh tsgo-clean false positives, all one
    // family. `AnimatedRef<T>`'s `current` comes back `unknown`, because
    // `AnimatedRefCurrent<TRef> = ExtractElementRef<TRef extends
    // AnimatedComponentType<any, infer Instance> ? Instance : TRef>` no longer
    // recovers `Instance` once `AnimatedComponentType` — a cycle member with an
    // OBJECT body — keeps its ref (DraggableList/index.tsx:195,
    // ImageItem.ios.tsx:111, SavedFeeds.tsx:129, Composer.tsx:1367 and :1473).
    // The fix for those belongs in `infer.zig`'s `.ref` PARAMETER arm, which
    // pairs a UNION argument by identity but has no such arm for an
    // INTERSECTION argument; until it lands, the narrow arm is the shipping one
    // and it is enough, because neither app needs more.
    // =======================================================================
    if ((c.alias_self_recursive.contains(sym) and originTaggable(c.ts.kind(generic))) or
        (c.alias_recursive.contains(sym) and c.ts.kind(generic) == .intersection) or
        (c.opts.alias_refs and fixed.len > 0 and aliasIdentityKeepable(c, generic)))
    {
        return c.ts.makeRef(sym, fixed);
    }
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) {
        // A NON-generic alias over a kept alias ref (`type C = T<A>`) takes the
        // inner alias's IDENTITY when it keeps the inner spelling, and that is
        // the wrong identity: tsc gives `C` its own `aliasSymbol` with NO
        // `aliasTypeArguments`, and the variance shortcut is guarded on
        // `source.aliasTypeArguments` being present — so `c = d` over
        // `type C = T<A>` / `type D = T<B>` is compared STRUCTURALLY while
        // `b = a` over `T<A>` / `T<B>` is not (oracle: tsgo 7.0.2 reports only
        // the latter). ztsc cannot spell "identity C, no arguments" — a
        // zero-argument ref would just defer the same wrong comparison one hop
        // down — so drop to the structure, which is what this arm answered
        // before the alias-ref policy existed.
        if (c.opts.alias_refs and keptAliasRef(c, generic)) return resolveStructural(c, generic);
        return generic;
    }
    var map = try c.scratch().alloc(TpMap, tps.items.len);
    for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = fixed[i] };
    const result = try c.instantiate(generic, map);
    // Same recursive shrinking-argument reduction as `expandRef` — applied
    // here so a materialized annotation (`type A = Tail<"a.b.c">`) reduces
    // all the way to `"c"` rather than stalling at the one-step `Tail<"b.c">`
    // ref, keeping the displayed type and the declared type in step with the
    // structural reduction the relation check performs.
    const orig = try c.ts.makeRef(sym, fixed);
    const reduced = try c.reexpandShrinking(orig, result);
    // Origin tag (see `origin`): a one-step alias instantiation carries the
    // canonical `makeRef(sym, fixed)` so the reflexive fast-path can match
    // it against a two-step re-instantiation of the same alias object.
    if (originTaggable(c.ts.kind(reduced))) try c.origin.put(c.cm(), reduced, orig);
    return reduced;
}

/// Is `generic` an alias body whose instantiation can carry the alias's own
/// identity as `ref(alias, args)` — the `--alias-refs` policy's admission test?
///
/// `originTaggable` is the set the `origin` machinery already treats as "a ref
/// and its materialization are interchangeable" (object / function /
/// intersection / mapped). A UNION body is deliberately not in it: a `.ref`
/// standing in for a union is NOT interchangeable, because discriminant
/// narrowing and the union-source relation arms switch on `.union_type`
/// directly. Nor is a CONDITIONAL: deferring a conditional body behind a ref is
/// the shape wave 30 measured at +12.8% on drizzle.
///
/// The one addition is a body that is ITSELF a kept alias ref — `type T<X> =
/// Pick<X, 'x'>`, whose body materializes to `ref(Pick, [X, 'x'])` under this
/// same policy. Without it the chain breaks at the first wrapper: `T<A>` would
/// instantiate to `ref(Pick, [A, 'x'])` and compare against `ref(Pick, [B,
/// 'x'])` under `Pick`'s variance, which reports the same failure one alias too
/// low — and would then also fire on `type C = T<A>` / `type D = T<B>`, where
/// the oracle reports nothing.
fn aliasIdentityKeepable(c: *Checker, generic: TypeId) bool {
    return originTaggable(c.ts.kind(generic)) or keptAliasRef(c, generic);
}

/// Is `t` a `ref` to a type ALIAS — i.e. a spelling only the alias-ref policy
/// (or the cycle arms) can have produced?
fn keptAliasRef(c: *Checker, t: TypeId) bool {
    return c.ts.kind(t) == .ref and c.symFlags(c.ts.refSymbol(t)).type_alias;
}

pub fn aliasGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
    prof_zig.declAsk(c, sym, .alias, sym);
    if (c.alias_generic.get(sym)) |t| return t;
    try c.alias_state.put(c.cm(), sym, 1);
    // One frame per body being materialized — `markCycle` reads the suffix.
    try c.alias_stack.append(c.cm(), sym);
    defer _ = c.alias_stack.pop();
    const dwin = prof_zig.declEnter(c, sym, .alias, prof_zig.dupKey(.alias, sym));
    defer prof_zig.declExit(c, dwin);
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    // The alias body is a separate lexical declaration: its own type params
    // shadow any same-named `infer`/mapped binder of the referencing site
    // (see `tp_shadow`). Build the shadow name set for the duration of the
    // body materialization.
    var shadow_buf: std.ArrayList(Atom) = .empty;
    defer shadow_buf.deinit(c.scratch());
    {
        var body_tps: std.ArrayList(TypeParamInfo) = .empty;
        defer body_tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &body_tps);
        for (body_tps.items) |tp| try shadow_buf.append(c.scratch(), c.symNameAtom(tp.sym));
    }
    const saved_shadow = c.tp_shadow;
    c.tp_shadow = shadow_buf.items;
    defer c.tp_shadow = saved_shadow;
    const decls = c.declsOf(sym);
    var result: TypeId = types.any_type;
    for (decls) |decl| {
        if (c.nodeTag(decl) != .type_alias) continue;
        const d = c.tree.nodeData(decl);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s else c.cur_scope = c.symScope(sym);
        result = try c.typeFromTypeNode(d.rhs);
        break;
    }
    // `type T = T` (any cycle collapsing to a self-ref) is circular.
    if (c.ts.kind(result) == .ref and c.ts.refSymbol(result) == sym) {
        const decls2 = c.declsOf(sym);
        if (decls2.len > 0) {
            const data = c.tree.extraData(ast.TypeAlias, c.tree.nodeData(decls2[0]).lhs);
            try c.diagFmt(2456, c.tokSpan(data.name_token), "Type alias '{s}' circularly references itself.", .{c.symbolName(sym)});
        }
        result = types.error_type;
    }
    try c.alias_generic.put(c.cm(), sym, result);
    try c.alias_state.put(c.cm(), sym, 2);
    return result;
}

/// Resolve `.ref` chains to a structural type (object/function/...).
pub fn resolveStructural(c: *Checker, t0: TypeId) Error!TypeId {
    // A polymorphic `this` type has the apparent structure of its home
    // class instance.
    var t = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    var i: u32 = 0;
    const prof_before = c.inst_total;
    while (c.ts.kind(t) == .ref) : (i += 1) {
        if (i > 16) return types.error_type;
        t = try c.expandRef(t);
    }
    if (c.prof.on and c.inst_total != prof_before) {
        prof_zig.noteExpandSite(c, @returnAddress(), c.inst_total - prof_before);
    }
    return t;
}

/// Is `t` a reference whose expansion is an OBJECT whatever its type
/// arguments are — answerable without expanding it?
///
/// An interface's and a class's member table is `.object` before and after
/// substitution: `interfaceGeneric`/`classInstanceGeneric` build an object
/// (or `error_type` on a base cycle), `instantiateId`'s `.object` arm
/// rebuilds an object, and the two interfaces that would break the rule —
/// `Array`/`ReadonlyArray` — never become refs at all, because
/// `typeFromTypeRef` lowers them to `.array` at construction.
///
/// So a predicate that only reads the KIND of the expansion is a function
/// of the ref's SYMBOL, and can skip materializing a member table that a
/// generic builder interface makes enormous. Type ALIASES are excluded on
/// purpose: an alias body REDUCES when instantiated — a conditional picks a
/// branch, an indexed access resolves, a mapped type materializes — so its
/// kind genuinely depends on the arguments and only the expansion can say.
pub fn refExpandsToObject(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) != .ref) return false;
    const f = c.symFlags(c.ts.refSymbol(t));
    return f.interface or f.class;
}

/// Profiler-only: which `DeclKind` an `expandRef` window of `sym` is.
fn refDeclKind(c: *Checker, sym: SymbolId) prof_zig.DeclKind {
    const sf = c.symFlags(sym);
    if (sf.class) return .expand_class;
    if (sf.interface) return .expand_iface;
    if (sf.type_alias) return .expand_alias;
    return .expand_other;
}

pub fn expandRef(c: *Checker, ref: TypeId) Error!TypeId {
    if (c.opts.dup_prof) prof_zig.declAsk(c, c.ts.refSymbol(ref), refDeclKind(c, c.ts.refSymbol(ref)), ref);
    if (c.expansions.get(ref)) |t| {
        if (t == types.no_type) return types.error_type; // cycle
        if (c.prof.on) prof_zig.noteExpandHit(c, ref);
        return t;
    }
    // A truncation already established for THIS budget window (below) is
    // served from here. It is not a published answer — the entry dies with
    // the window — but within the window it is the same answer re-derivation
    // would produce, and re-deriving it is not cheap: the prologue below runs
    // `typeParamsOf` (which re-reads the declaration's type-parameter list
    // out of the AST, re-interning every name) and `buildInstMap` before
    // `instantiate` can even reach the guard that truncates. drizzle-orm's
    // `relate` walk over `PgSelectBase` / `SQLiteSelectBase` asks the same
    // handful of references 3.0 M times inside ONE statement's window; without
    // this it re-derived each one, which is 3.6 s and 1.69 GB of never-freed
    // expansion prologue against 0.04 s and 21 MB with the repeat elided.
    if (c.trunc_expansions.get(ref)) |epoch| {
        if (epoch == c.budget_epoch) {
            // The mark the real path would leave: a caller must not memoize
            // anything built on a truncated subtree.
            c.inst_limit_tripped = true;
            return types.error_type;
        }
    }
    try c.expansions.put(c.cm(), ref, types.no_type); // in-progress
    const sym = c.ts.refSymbol(ref);
    const dwin = if (c.dprof.on)
        prof_zig.declEnter(c, sym, refDeclKind(c, sym), prof_zig.dupKey(.expand_other, ref))
    else
        prof_zig.DeclWin{};
    defer prof_zig.declExit(c, dwin);
    const prof_before = c.inst_total;
    // Self-cost bookkeeping: this frame's children charge into
    // `expand_child_visits`, which is zeroed on entry and folded back into the
    // parent's on exit (see `InstProf.expand_child_visits`).
    const child_before = c.prof.expand_child_visits;
    if (c.prof.on) c.prof.expand_child_visits = 0;
    defer if (c.prof.on) {
        const incl = c.inst_total - prof_before;
        prof_zig.noteExpand(c, sym, incl);
        prof_zig.noteExpandBuild(c, ref, incl);
        prof_zig.noteExpandSelf(c, sym, incl - @min(incl, c.prof.expand_child_visits));
        c.prof.expand_child_visits = child_before + incl;
    };
    const args = try c.scratch().dupe(TypeId, c.ts.refArgs(ref));
    const f = c.symFlags(sym);
    var generic: TypeId = types.any_type;
    // A class's generic table is PROVISIONAL when some class on the way was
    // still materializing (`classTableProvisional`); such a table is never
    // memoized, and neither is any expansion built on it — see the invariant
    // on `classTableProvisional`.
    var provisional = false;
    if (f.class) {
        generic = try c.classInstanceGeneric(sym);
        provisional = c.classTableProvisional(sym);
    } else if (f.interface) {
        generic = try c.interfaceGeneric(sym);
    } else if (f.type_alias) {
        generic = try c.aliasGeneric(sym);
        if (c.ts.kind(generic) == .ref and c.ts.refSymbol(generic) == sym) {
            generic = types.error_type;
        }
    }
    var result = generic;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len > 0) {
        // Map every declaration block's positional type params (reopened /
        // merged interfaces bind a distinct symbol per block) to args.
        var map_list: std.ArrayList(TpMap) = .empty;
        defer map_list.deinit(c.scratch());
        try c.buildInstMap(sym, args, &map_list);
        const saved_generic = c.prof.expand_generic;
        const saved_esym = c.prof.expand_sym;
        if (c.prof.on) {
            c.prof.expand_generic = generic;
            c.prof.expand_sym = sym;
        }
        result = try c.instantiate(generic, map_list.items);
        if (c.prof.on) {
            c.prof.expand_generic = saved_generic;
            c.prof.expand_sym = saved_esym;
        }
        // Recursive-reduction of a shrinking alias (see `reexpandShrinking`):
        // `Tail<"a.b.c">` instantiates its conditional body to the bare ref
        // `Tail<"b.c">`; eagerly re-expand while the argument metric strictly
        // decreases so it fully reduces to `"c"`. A growing recursion
        // (`Grow<{deeper:T}>`) never re-expands — its metric increases.
        if (f.type_alias) result = try c.reexpandShrinking(ref, result);
    }
    // Withdraw the in-progress mark rather than memoizing an expansion of a
    // provisional table: the answer is only true for the duration of the
    // cycle that produced it, and the first reader outside that cycle must
    // recompute it. Nor is it origin-tagged — an incomplete object must not
    // become the identity other materializations of `ref` relate to.
    if (provisional) {
        _ = c.expansions.remove(ref);
        return result;
    }
    // A TRUNCATION IS NOT AN ANSWER. When the generic table exists and the
    // substitution over it still came back `error_type`, the substitution ran
    // out of budget (or depth) — `instantiateId`'s guard collapses the whole
    // term — and nothing about `ref` says so. Publishing it makes the WHOLE
    // RUN's view of that reference a function of which source element reached
    // it first with a cold cache: immich's `DynamicModule<DB>` was expanded
    // once, from the single statement in the package that reaches the 250 k
    // statement cap (`ocr.repository.ts`), and every later reader got `any` —
    // `const { table, ref } = this.db.dynamic` bound both names to `any`, and
    // twelve kysely callbacks in `sync.repository.ts` lost their contextual
    // type behind it.
    //
    // So withdraw the mark and let the next reader recompute, exactly as the
    // provisional case above does. This is narrower than the
    // `inst_limit_tripped`-scoped withdrawal measured (and reverted) before
    // the budget split: that one re-expanded on any trip anywhere in the
    // subtree and cost 26 keys and 0.8 s; this one fires only on the definite
    // marker, which after the split is rare — no declaration materialization
    // in immich truncates at all, and only one statement reaches its cap.
    //
    // Withdrawn from `expansions`, but RECORDED against the budget window that
    // produced it (`budget_epoch`): a truncation is not a fact about `ref`,
    // yet it is a fact about this window, and every later ask inside the same
    // window would spend the whole prologue above to arrive at it again. See
    // the lookup at the top.
    if (c.ts.kind(result) == .err and c.ts.kind(generic) != .err) {
        _ = c.expansions.remove(ref);
        try c.trunc_expansions.put(c.cm(), ref, c.budget_epoch);
        return result;
    }
    // Origin tag: this object is the materialization of `ref =
    // makeRef(sym, canonical-args)` (interface refs carry default-filled
    // args from `fixTypeArgs`). Record it so a structurally-divergent
    // re-materialization of the SAME `ref` relates by identity. Only
    // objects are tagged — a ref that resolved to a union/primitive/etc.
    // is already compared by its own rules.
    if (originTaggable(c.ts.kind(result))) try c.origin.put(c.cm(), result, ref);
    try c.expansions.put(c.cm(), ref, result);
    return result;
}

// =====================================================================
// lazy member tables — "symbols eagerly, types lazily"
// =====================================================================

// The lazy member route's switch (`--eager-members` turns it off) is
// `checker.Options.lazy_members`, read as `c.opts.lazy_members`. It exists so
// any diagnostic movement can be bisected against the eager path in the same
// binary. It was a process global until it became a per-run option.

/// The GENERIC member table `ref`'s expansion substitutes, when that table
/// can be read member-by-member instead of materialized whole — else null,
/// and the caller expands eagerly exactly as before.
///
/// tsc resolves an interface/class reference to a member table that holds
/// member SYMBOLS (names, flags, declarations) and computes each member's
/// TYPE on first access. ztsc's `expandRef` instead substitutes the whole
/// table up front, so a relation that fails on a builder's first property
/// still pays for the other two hundred — the ~100x demand gap kysely's
/// chains open up. The table this returns is the same one `expandRef` would
/// substitute, and `instantiateId`'s `.object` arm carries `Prop.name` and
/// `Prop.flags` through untouched, so every question that reads only a
/// member's NAME or FLAGS — "is this target weak?", "does the source have a
/// property called `x`?", "is `x` optional?" — is answerable off the generic
/// with no substitution at all.
///
/// Eligibility is deliberately narrow; everything it excludes keeps today's
/// eager path, so a member read through this route is byte-identical to the
/// one the expansion would have held:
///
///   * interfaces and classes only — an ALIAS body reduces when instantiated
///     (a conditional picks a branch, a mapped type materializes), so its
///     members are not a substitution of the generic's members;
///   * the generic must already be an `.object`: a base cycle answers
///     `error_type`, and `Array`/`ReadonlyArray` are lowered elsewhere;
///   * no call or construct signatures — `instantiateId` DROPS a
///     higher-order signature it cannot instantiate (`higherOrderSigEligible`),
///     so a signature count is not carried through and may not be read off
///     the generic;
///   * an expansion already memoized (or in progress) stays on the eager
///     path: the finished table is free, and an in-progress one must take
///     `expandRef`'s cycle cut;
///   * a PROVISIONAL class table (`classTableProvisional`) is true only for
///     the duration of the cycle that produced it, and `expandRef` refuses to
///     memoize an expansion built on one — so nothing built on it may be
///     memoized here either;
///   * a reference with no type parameters expands to the generic itself, so
///     there is nothing to defer.
pub fn lazyTableOf(c: *Checker, ref: TypeId) Error!?TypeId {
    return switch (try lazyTableOutcome(c, ref)) {
        .table => |g| g,
        .no => null,
    };
}

/// `lazyTableOf`'s answer WITH the reason it declined, so `--lazy-stats` can
/// aim the next conversion without a second copy of the eligibility rules
/// drifting out of step with these.
pub const TableOutcome = union(enum) {
    table: TypeId,
    no: checker_zig.LazyStat,
};

pub fn lazyTableOutcome(c: *Checker, ref: TypeId) Error!TableOutcome {
    const generic = switch (try lazyShapeOutcome(c, ref)) {
        .table => |g| g,
        .no => |why| return .{ .no = why },
    };
    // Already materialized: the eager path is free, and it is the one that
    // owns the object's `origin` tag.
    if (c.expansions.get(ref) != null) return .{ .no = .tbl_already_expanded };
    // `instantiateId` DROPS a higher-order signature it cannot instantiate
    // (`higherOrderSigEligible`), so a signature count is not carried through
    // and a member table that has any may not be read off the generic.
    if (c.ts.objectCallSigCount(generic) != 0 or c.ts.objectConstructSigCount(generic) != 0) {
        return .{ .no = .tbl_has_sigs };
    }
    if (try lazyRefMap(c, ref)) |_| return .{ .table = generic };
    return .{ .no = .tbl_no_type_params };
}

/// The member table whose NAMES, FLAGS and COUNTS `ref`'s expansion carries
/// unchanged — or null when `ref` is not a reference whose expansion is a
/// substitution of a fixed table.
///
/// This is the weaker half of `lazyTableOf`, for consumers that read no member
/// TYPE at all: `keyof` enumerates names, `isCallableSource` asks whether the
/// shape has properties, `isWeakType` asks whether every property is optional.
/// None of them needs the substitution map, and none of them cares that the
/// table may already have been materialized elsewhere — so none of the
/// restrictions `lazyTableOf` adds for materialization apply.
///
/// Aliases are excluded for the reason `refExpandsToObject` excludes them: an
/// alias BODY reduces when instantiated, so its members are not a
/// substitution of the generic's members. An in-progress or provisional class
/// table is excluded because `expandRef` refuses to publish either, so what
/// the eager path answers for one is not this table at all.
///
/// **It never BUILDS a table, only reads one already memoized.** Materializing
/// a generic member table is not a pure function of the symbol — it runs the
/// declaration walk under `enterSymFile`, folds `extends` bases, resolves
/// every member's annotation and can re-enter this very reference — so WHEN it
/// first runs is observable. `expandRef` marks `expansions[ref]` in progress
/// before it builds, and building from anywhere else steps outside that mark;
/// measured on excalidraw, hoisting the construction into `keyofType` alone
/// took the sweep from 17 diagnostics to 279. Reading a table some earlier
/// `expandRef` already built has no such effect, and it is the case that
/// matters: a generic interface is materialized once and read thousands of
/// times, so the second and every later reader takes this route.
pub fn lazyShapeOf(c: *Checker, ref: TypeId) Error!?TypeId {
    return switch (try lazyShapeOutcome(c, ref)) {
        .table => |g| g,
        .no => null,
    };
}

pub fn lazyShapeOutcome(c: *Checker, ref: TypeId) Error!TableOutcome {
    if (!c.opts.lazy_members) return .{ .no = .tbl_disabled };
    if (c.ts.kind(ref) != .ref) return .{ .no = .tgt_not_ref };
    const sym = c.ts.refSymbol(ref);
    const f = c.symFlags(sym);
    if (!f.interface and !f.class) return .{ .no = .tbl_not_nominal };
    if (c.expansions.get(ref)) |e| {
        if (e == types.no_type) return .{ .no = .tbl_in_progress }; // `expandRef` cuts
    }
    const generic = if (f.class) blk: {
        if (c.classGenericInProgress(sym)) return .{ .no = .tbl_in_progress };
        if (c.classTableProvisional(sym)) return .{ .no = .tbl_provisional };
        break :blk c.class_inst_generic.get(sym) orelse return .{ .no = .tbl_unbuilt };
    } else c.iface_generic.get(sym) orelse return .{ .no = .tbl_unbuilt };
    if (generic == types.no_type) return .{ .no = .tbl_in_progress }; // still materializing
    if (c.ts.kind(generic) != .object) return .{ .no = .tbl_not_object };
    return .{ .table = generic };
}

/// The substitution `ref`'s member table is read under, built once per
/// reference and kept on the checker arena. Null when the reference's symbol
/// declares no type parameters — `expandRef` hands back the generic itself in
/// that case, so there is nothing to substitute and nothing to defer.
fn lazyRefMap(c: *Checker, ref: TypeId) Error!?[]const TpMap {
    if (c.lazy_map.get(ref)) |m| return if (m.len == 0) null else m;
    const sym = c.ts.refSymbol(ref);
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) {
        try c.lazy_map.put(c.cm(), ref, &.{});
        return null;
    }
    var map_list: std.ArrayList(TpMap) = .empty;
    defer map_list.deinit(c.scratch());
    const args = try c.scratch().dupe(TypeId, c.ts.refArgs(ref));
    try c.buildInstMap(sym, args, &map_list);
    const owned = try c.cm().dupe(TpMap, map_list.items);
    try c.lazy_map.put(c.cm(), ref, owned);
    return if (owned.len == 0) null else owned;
}

/// Slot numbering for `lazy_member`: property `i` is slot `i`, and the two
/// index signatures follow the properties.
fn lazySlotStringIndex(c: *Checker, generic: TypeId) u32 {
    return c.ts.objectPropCount(generic);
}

fn lazySlotNumberIndex(c: *Checker, generic: TypeId) u32 {
    return c.ts.objectPropCount(generic) + 1;
}

/// Substitute ONE member of `ref`'s table — tsc's `getTypeOfSymbol` on an
/// instantiated symbol. `generic_ty` is that member's type as written on the
/// generic table; `slot` identifies it for the memo.
///
/// The result is cached per `(ref, slot)` for the whole run, so the
/// amortization the whole-table expansion provided survives at member
/// granularity — EXCEPT when the substitution truncated, which is never
/// published (see `lazy_member`).
///
/// A truncated member falls back to the WHOLE-table expansion and reads the
/// member out of that. Without the fallback a truncation is unrecoverable:
/// nothing is memoized, so the next reader re-substitutes under a budget that
/// is no less spent and truncates again, forever — the failure mode
/// `expandRef`'s truncated-withdrawal experiment ran into from the other
/// direction (see prof.zig). `expandRef` memoizes whatever it gets, truncated
/// or not, so one fallback moves this reference to the eager regime for the
/// rest of the run and every later reader sees the same answer the checker
/// would have given with no lazy layer at all. The lazy route can therefore
/// only win: it either substitutes one member instead of two hundred, or it
/// pays exactly what the eager path paid.
///
/// …except that "pays exactly what the eager path paid" was per ASK, not once:
/// the fallback answer was not remembered either, so a spent window re-ran the
/// whole prologue — `lazyRefMap` plus a top-level `instantiate` that exists
/// only to truncate — on every repeat. `trunc_lazy_member` remembers it for the
/// window, which is what `trunc_expansions` already does one grain up.
pub fn lazyMemberAt(c: *Checker, ref: TypeId, generic_ty: TypeId, slot: u32) Error!TypeId {
    const key = (@as(u64, ref) << 32) | slot;
    if (c.lazy_member.get(key)) |t| return t;
    // A member that already truncated in THIS budget window (see
    // `trunc_lazy_member`). Serving it from here is not a published answer —
    // the entry dies with the epoch — but within the window it is the answer
    // the work below would reach, and reaching it is not cheap: `lazyRefMap`
    // interns the reference's substitution and `instantiate` re-enters the
    // top-level frame before it can even see that the ceiling is spent.
    if (c.trunc_lazy_member.get(key)) |e| {
        if (e.epoch == c.budget_epoch) {
            // The mark the real path would leave: a caller must not memoize
            // anything built on a truncated subtree.
            c.inst_limit_tripped = true;
            return e.ty;
        }
    }
    const map = (try lazyRefMap(c, ref)) orelse return generic_ty;
    const result = try c.instantiate(generic_ty, map);
    if (!c.inst_limit_tripped) {
        try c.lazy_member.put(c.cm(), key, result);
        return result;
    }
    const answer = blk: {
        const whole = try c.expandRef(ref);
        if (c.ts.kind(whole) != .object) break :blk result;
        const n = c.ts.objectPropCount(whole);
        if (slot < n) break :blk c.ts.objectProp(whole, slot).ty;
        if (slot == n) break :blk c.ts.objectStringIndex(whole);
        if (slot == n + 1) break :blk c.ts.objectNumberIndex(whole);
        break :blk result;
    };
    try c.trunc_lazy_member.put(c.cm(), key, .{ .ty = answer, .epoch = c.budget_epoch });
    return answer;
}

/// Property `i` of `ref`'s table, its type substituted on demand.
pub fn lazyPropAt(c: *Checker, ref: TypeId, generic: TypeId, i: u32) Error!types.Prop {
    const p = c.ts.objectProp(generic, i);
    return .{ .name = p.name, .flags = p.flags, .ty = try lazyMemberAt(c, ref, p.ty, i) };
}

/// The named property of `ref`'s table, or null when the table has no member
/// of that name. Costs one binary search and — only on a hit — one member
/// substitution.
pub fn lazyPropNamed(c: *Checker, ref: TypeId, generic: TypeId, name: Atom) Error!?types.Prop {
    const n = c.ts.objectPropCount(generic);
    var lo: u32 = 0;
    var hi: u32 = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const p = c.ts.objectProp(generic, mid);
        if (p.name == name) return try lazyPropAt(c, ref, generic, mid);
        if (p.name < name) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// `ref`'s string index signature type (0 when it has none), substituted on
/// demand. `instantiateId` maps a non-zero index type to a non-zero one, so
/// the PRESENCE of an index signature is readable off the generic.
pub fn lazyStringIndex(c: *Checker, ref: TypeId, generic: TypeId) Error!TypeId {
    const g = c.ts.objectStringIndex(generic);
    if (g == 0) return 0;
    return lazyMemberAt(c, ref, g, lazySlotStringIndex(c, generic));
}

pub fn lazyNumberIndex(c: *Checker, ref: TypeId, generic: TypeId) Error!TypeId {
    const g = c.ts.objectNumberIndex(generic);
    if (g == 0) return 0;
    return lazyMemberAt(c, ref, g, lazySlotNumberIndex(c, generic));
}

/// A TYPE-LEVEL indexed access `Ref["name"]` answered by substituting ONE
/// member of `ref`'s table — tsc's own shape for `getIndexedAccessType`, which
/// asks `getPropertyOfType` for one symbol and lets `getTypeOfSymbol`
/// instantiate that member alone. Null whenever the eager path is the right
/// one (see `lazyTableOf`'s eligibility rules; an already-materialized table is
/// one of them, and is why this never re-derives what is already free).
///
/// The shape it exists for is zod's. `z.infer<typeof schema>` is
/// `(typeof schema)['_output']`; `_output` is a bare type parameter on
/// `ZodType`'s generic table, so substituting it is one map lookup — while the
/// ~60-member table around it is not, because `ZodType`'s fluent API returns
/// `ZodOptional<this>`, `ZodEffects<this, …>`, `ZodPipeline<this, …>` and
/// eleven more wrappers, each of which drags its own member table in behind it.
/// On social-app's ~40-property `z.object({…})` that table costs the whole 5 M
/// declaration budget, so `type Schema = z.infer<typeof schema>` resolved to
/// `any` and took twelve implicit-any-parameter reports across nine files with
/// it. The isolated repro (that schema, real zod, 28 files) goes from 0.98 s
/// user and two diagnostics to 0.14 s and none.
///
/// **`indexedAccessType` asks only once `inst_ceiling_trips != 0` — once this
/// checker has run out of instantiation room at least once — and that gate is
/// the design, not a safety belt.** Three measurements on drizzle-orm at
/// `--checkers=1`, whose `relate` walk asks `indexedAccessType` for the same
/// handful of builder references millions of times inside ONE statement:
///
///   * Answering EVERY nominal `Ref["name"]` this way costs 446 -> 800 ms and
///     34.9 -> 132.6 MB, node visits 338 k -> 584 k, budget trips 0 -> 540.
///     That is precisely the mechanism prof.zig records for the
///     `propertyTypeOf` conversion: the eager expansion runs early, completes,
///     and is memoized under the ref for every later reader; substitute one
///     member instead and each reader re-derives what the table prepaid for.
///   * Restricting it to references whose expansion already FAILED
///     (`trunc_expansions`) does not help: drizzle fills that table with
///     ordinary `extends`-cycle cuts, half a million asks land on them, and it
///     is 315 -> 480 ms.
///   * Even a gate tight enough never to fire at all is not free if it is asked
///     per access: two hash lookups per ask, zero hits, node visits within 4 of
///     the baseline — and still 333 -> 538 ms.
///
/// A one-word counter read is the only gate cheap enough, and it is exactly the
/// right question: nothing in `bench/corpus/real` trips the ceiling even once
/// (all eight packages are byte-identical, node visit for node visit, with this
/// route compiled in), so the route costs the healthy corpus nothing and turns
/// on only where the eager path has already proven it cannot finish.
pub fn lazyIndexedProp(c: *Checker, obj: TypeId, name: Atom) Error!?types.Prop {
    if (c.inst_ceiling_trips == 0) return null;
    if (c.ts.kind(obj) != .ref) return null;
    const generic = (try lazyTableOf(c, obj)) orelse return null;
    return lazyPropNamed(c, obj, generic, name);
}

/// A materialized generic instantiation carries an origin tag (see `origin`)
/// only when it lands on a structural shape whose identity the reflexive /
/// equivalence fast-path can exploit: an object, a function, or an
/// intersection (a callable-object `Callable & {…}` alias such as RTK's
/// `AsyncThunk<…>` materializes to a kept intersection, and its two
/// route-divergent instantiations must relate by origin). Unions/primitives
/// are compared by their own rules and are never tagged.
pub fn originTaggable(k: types.Kind) bool {
    // `.mapped` is tagged too: a still-generic alias instantiation
    // (`WeakValidationMap<P>` with `P` free) never materializes into an
    // object, and inference needs its alias identity to pair with a
    // concrete `WeakValidationMap<X>` argument — tsc's same-alias rule (see
    // `inferReverseMapped`).
    return k == .object or k == .function or k == .intersection or k == .mapped;
}

/// tsc's `isEmptyObjectType` for a single object: no members of any kind, so
/// it constrains nothing. Kept here beside the expansion machinery because
/// every asker reaches it through a resolved `.ref`.
pub fn isEmptyObjectType(c: *Checker, t: TypeId) bool {
    const s = &c.ts;
    return s.kind(t) == .object and s.objectPropCount(t) == 0 and
        s.objectStringIndex(t) == 0 and s.objectNumberIndex(t) == 0 and
        s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0 and
        // `typeof globalThis` stores no properties but is NOT `{}` — its
        // members live in the linker's globals table. Treating it as the
        // empty-object marker would let `Window & typeof globalThis`
        // reduce away the global half (and mislead the `T & {}`
        // non-nullish marker).
        s.objectFlags(t) & types.obj_flag_global_this == 0;
}

// =====================================================================
// re-exports
//
// `Checker`'s alias block and several sibling modules name these through
// `instantiate.zig`; the definitions live in the files below.
// =====================================================================

const classes = @import("classes.zig");
const modvalue = @import("modvalue.zig");
const shrink = @import("shrink.zig");

pub const driveShrinkingAlias = shrink.driveShrinkingAlias;
pub const originArgEquiv = shrink.originArgEquiv;
pub const reexpandShrinking = shrink.reexpandShrinking;

pub const globalThisType = modvalue.globalThisType;
pub const globalThisProp = modvalue.globalThisProp;
pub const globalThisHasValue = modvalue.globalThisHasValue;

pub const lazy_base_depth = classes.lazy_base_depth;
pub const emitBaseCycle = classes.emitBaseCycle;
pub const interfaceGeneric = classes.interfaceGeneric;
pub const setInterfaceThis = classes.setInterfaceThis;
pub const interfaceConstituentDirect = classes.interfaceConstituentDirect;
pub const interfaceConstituentApplyBases = classes.interfaceConstituentApplyBases;
pub const interfaceHeritageTypes = classes.interfaceHeritageTypes;
pub const mergeBaseResolved = classes.mergeBaseResolved;
pub const arrayInterfaceObject = classes.arrayInterfaceObject;
pub const unionCallableSigs = classes.unionCallableSigs;
pub const mergeBaseObjectPlain = classes.mergeBaseObjectPlain;
pub const carryKeyNameTypes = classes.carryKeyNameTypes;
pub const classInstanceGeneric = classes.classInstanceGeneric;
pub const classTableProvisional = classes.classTableProvisional;
pub const baseRefProvisional = classes.baseRefProvisional;
pub const baseRefCut = classes.baseRefCut;
pub const classInterfaceHalfBases = classes.classInterfaceHalfBases;
pub const classSymbolOf = classes.classSymbolOf;
pub const isCtorName = classes.isCtorName;
pub const isCtorMember = classes.isCtorMember;
pub const classGenericInProgress = classes.classGenericInProgress;
pub const refExpansionActive = classes.refExpansionActive;
pub const lazyRefProp = classes.lazyRefProp;
pub const lazyThisProp = classes.lazyThisProp;
pub const ctorClassOwnsMember = classes.ctorClassOwnsMember;
pub const keyofInProgressRef = classes.keyofInProgressRef;
pub const declaredKeyUnion = classes.declaredKeyUnion;
pub const baseClassRef = classes.baseClassRef;
pub const hasUnresolvedBase = classes.hasUnresolvedBase;
pub const baseClassSym = classes.baseClassSym;
pub const classBaseEntitySym = classes.classBaseEntitySym;
pub const baseExprConstructType = classes.baseExprConstructType;
pub const importedContainerSym = classes.importedContainerSym;
/// `classes.classIsAbstract`, memoized per class symbol. The answer is one
/// modifier bit on one declaration, but reading it brackets the walk in
/// `enterSymFile`/`restoreCtx`, and the relation's abstract-constructor screen
/// (`assign.sourceSatisfiesSigs`) asks it on EVERY `class_value` source
/// related to a construct signature. See `Checker.class_abstract_cache` for
/// the measurement. A pure function of the program, so the memo cannot make an
/// answer depend on which checker asked first.
pub fn classIsAbstract(c: *Checker, sym: SymbolId) Error!bool {
    if (c.class_abstract_cache.get(sym)) |v| return v;
    const v = try classes.classIsAbstract(c, sym);
    try c.class_abstract_cache.put(c.cm(), sym, v);
    return v;
}
pub const abstractSatisfiedElsewhere = classes.abstractSatisfiedElsewhere;
pub const classChainMemberIsAbstract = classes.classChainMemberIsAbstract;
pub const classChainMemberType = classes.classChainMemberType;
pub const memberIsAbstract = classes.memberIsAbstract;
pub const checkAbstractImplementation = classes.checkAbstractImplementation;
pub const collectClassMemberAtoms = classes.collectClassMemberAtoms;
