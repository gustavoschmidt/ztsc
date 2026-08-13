//! Type-parameter VARIANCE, both halves of it.
//!
//!   * DECLARED variance — the TS 4.7 `in`/`out` annotations, read straight
//!     off the token stream (`declaredVariances`), used by the relation
//!     (`varianceVerdict`) and checked against the body (TS2636,
//!     `checkVarianceAnnotations`);
//!   * MEASURED variance — tsc's `getVariances`: how a generic actually USES
//!     each parameter, measured by substituting an opaque `sub`/`super`
//!     marker pair and asking the ordinary relation which way the two
//!     instantiations go (`measuredVariances` / `measuredVarianceVerdict`).
//!
//! The caches these answers live in (`variance_cache`, `measured_variance`,
//! `measuring_variance`, `marker_refs`, `variance_marker_refs`) are fields of
//! `Checker`; everything here is a pure function of a checker plus a symbol.
//!
//! Two seams into the relation, both in `assign.relate`: `varianceVerdict`
//! and `measuredVarianceVerdict`. `assign.zig` re-exports every `pub` here so
//! the `Checker` method aliases keep resolving.

const std = @import("std");
const binder = @import("../frontend/binder.zig");
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const SymbolId = binder.SymbolId;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;

/// Declaration-site variance (TS 4.7 `in`/`out`) of one type parameter.
pub const Variance = enum(u2) {
    none = 0,
    /// `in T` — contravariant: `G<Super>` is assignable to `G<Sub>`.
    contravariant = 1,
    /// `out T` — covariant: `G<Sub>` is assignable to `G<Super>`.
    covariant = 2,
    /// `in out T` — invariant: the arguments must be mutually assignable.
    invariant = 3,
};

/// The `in`/`out` annotation on a type parameter, read back off the tokens
/// that precede its name. The parser consumes the modifiers without
/// storing them and the token stream already holds the answer, so an
/// annotation costs no node, symbol, or type-store memory. Only `in`,
/// `out` and the name itself can occupy those slots (a `const` or the
/// opening `<`/`,` ends the walk), so the scan cannot run past its
/// parameter.
pub fn declaredVarianceOfTypeParam(c: *Checker, tp_sym: SymbolId) Variance {
    const saved = c.enterSymFile(tp_sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(tp_sym)) |decl| {
        if (c.nodeTag(decl) != .type_param) continue;
        var tok = c.tree.nodeMainToken(decl);
        var bits: u2 = 0;
        while (tok > 0) {
            tok -= 1;
            switch (c.tree.tokens.tag(tok)) {
                .keyword_in => bits |= 1,
                .keyword_out => bits |= 2,
                else => break,
            }
        }
        return @enumFromInt(bits);
    }
    return .none;
}

/// Declared variances of `owner`'s type parameters, packed 2 bits each
/// (see `variance_cache`). 0 means no parameter is annotated.
pub fn declaredVariances(c: *Checker, owner: SymbolId) Error!u32 {
    if (c.variance_cache.get(owner)) |v| return v;
    var bits: u32 = 0;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(owner, &tps);
    for (tps.items, 0..) |tp, i| {
        if (i >= 16) break;
        bits |= @as(u32, @intFromEnum(c.declaredVarianceOfTypeParam(tp.sym))) << @intCast(2 * i);
    }
    try c.variance_cache.put(c.cm(), owner, bits);
    return bits;
}

/// tsc's variance-directed comparison (`relateVariances`) of two
/// references to the SAME generic symbol, restricted to type parameters
/// that carry an explicit `in`/`out` annotation.
///
/// An annotation is a DECLARATION, not a hint: where it holds the two
/// instantiations relate however their members compare — for
/// `interface Getter<in T> { get(): T }`, `Getter<unknown>` IS assignable
/// to `Getter<string>`, which the structural walk rejects on the return
/// type — and where it fails they do not relate even when the members
/// would have matched bivariantly.
///
/// Returns null whenever the annotations say nothing decisive — none
/// present, mismatched arity, or an UNANNOTATED parameter whose two
/// arguments are not already equal — leaving every relation ztsc decided
/// before this existed to the structural walk, unchanged.
pub fn varianceVerdict(c: *Checker, s_ref: TypeId, t_ref: TypeId) Error!?bool {
    const st = &c.ts;
    const n = st.refArgCount(s_ref);
    if (n == 0 or n != st.refArgCount(t_ref)) return null;
    const bits = try c.declaredVariances(st.refSymbol(s_ref));
    if (bits == 0) return null;
    var decisive = true;
    for (0..n) |i| {
        const sa = st.refArgAt(s_ref, i);
        const ta = st.refArgAt(t_ref, i);
        const v: Variance = if (i >= 16) .none else @enumFromInt(@as(u2, @truncate(bits >> @intCast(2 * i))));
        switch (v) {
            // Unannotated: equal arguments hold under ANY variance, so
            // they stay decidable here; anything else defers the whole
            // pair to the structural walk.
            .none => if (!try c.originArgEquiv(sa, ta)) {
                decisive = false;
            },
            .covariant => if (!try c.isAssignable(sa, ta)) return false,
            .contravariant => if (!try c.isAssignable(ta, sa)) return false,
            .invariant => if (!(try c.isAssignable(sa, ta)) or !(try c.isAssignable(ta, sa))) return false,
        }
    }
    return if (decisive) true else null;
}

// =====================================================================
// measured (structural) variance — tsc's `getVariances`
// =====================================================================

/// How a generic actually USES one of its type parameters, measured from its
/// body rather than read off an `in`/`out` annotation — tsc's
/// `VarianceFlags`. Packed 3 bits per parameter in `measured_variance`, so
/// `unmeasured` must stay 0: an all-zero cache entry is "this generic told us
/// nothing", the answer for every non-generic and every shape below.
pub const Measured = enum(u3) {
    /// No verdict. The parameter list is too long to pack, the body is not a
    /// materializable generic, or the measurement was declined. The relation
    /// falls back to the structural walk, exactly as before this existed.
    unmeasured = 0,
    /// `G<sub>` relates to `G<super>` but not the reverse: the parameter is
    /// read (returns, property types), never written.
    covariant = 1,
    /// The reverse: the parameter is only written (function-property
    /// parameters under `strictFunctionTypes`).
    contravariant = 2,
    /// Both directions relate and the parameter IS witnessed — a method
    /// parameter, which TypeScript compares bivariantly. Either argument
    /// direction satisfies the pair.
    bivariant = 3,
    /// Neither direction relates: the parameter is read AND written, so two
    /// instantiations relate only when the arguments relate both ways.
    invariant = 4,
    /// Both directions relate and so does a marker unrelated to either: the
    /// parameter is not witnessed anywhere in the body, so its arguments do
    /// not participate in the relation at all.
    independent = 5,
};

/// Type parameters one generic may have and still be measured. Three bits
/// each have to fit in the `measured_variance` word; a longer list is read as
/// unmeasured and keeps the structural walk.
const max_measured_params = 10;

/// Measurements that may be on the stack at once. A measurement walks the
/// generic's body, and every OTHER generic it meets there wants measuring
/// too, so the nest is bounded by the size of the mutually-referencing family
/// — zod's `ZodType` and its ~20 wrappers are the shape that sets the bar. It
/// cannot loop (a generic already on the stack short-circuits, see
/// `measuring_variance`), and the relation's own `max_relation_depth` is not
/// reset per measurement, so the native stack stays bounded by that.
///
/// The cap has to clear the family, not merely bound it: past it the generic
/// is left unmeasured and the structural walk answers — which for exactly
/// these recursive `this`-typed families is the exponential walk measurement
/// exists to avoid. A cap of 4 left zod's `ZodNumber` check running for
/// minutes; 32 clears it with room to spare.
pub const max_variance_measure_depth = 32;

fn measuredAt(bits: u32, i: usize) Measured {
    if (i >= max_measured_params) return .unmeasured;
    return @enumFromInt(@as(u3, @truncate(bits >> @intCast(3 * i))));
}

/// Structurally measured variance of every type parameter of `owner`, packed
/// (see `measured_variance`). Null means "declined" — `owner` is not a
/// generic the checker can materialize, or the nest cap
/// (`max_variance_measure_depth`) is reached — and nothing is cached, so a
/// later shallower demand still measures.
///
/// tsc's `getVariancesWorker`: substitute an opaque `sub`/`super` marker pair
/// for the parameter, and ask the ordinary relation which way the two
/// instantiations go. A parameter carrying an explicit `in`/`out` annotation
/// is not measured — the annotation IS the declared answer, and whether the
/// body agrees is TS2636's business (`checkVarianceAnnotations`), not the
/// relation's.
pub fn measuredVariances(c: *Checker, owner: SymbolId) Error!?u32 {
    if (c.measured_variance.get(owner)) |v| return v;
    if (c.variance_measure_depth >= max_variance_measure_depth) return null;
    const f = c.symFlags(owner);
    if (!f.interface and !f.class and !f.type_alias) return null;

    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(owner, &tps);
    if (tps.items.len == 0 or tps.items.len > max_measured_params) {
        try c.measured_variance.put(c.cm(), owner, 0);
        return 0;
    }

    try c.measuring_variance.put(c.cm(), owner, {});
    c.variance_measure_depth += 1;
    // Instantiation and expansion are bookkeeping here, exactly as in
    // `checkVarianceAnnotations`: a depth/count trip measuring a type the
    // user never wrote must neither be reported nor charged to the statement
    // whose relation happened to demand the measurement.
    const saved_suppress = c.suppress_inst_diag;
    const saved_count = c.inst_count;
    const saved_epoch = c.budget_epoch;
    const saved_tripped = c.inst_limit_tripped;
    c.suppress_inst_diag = true;
    // …and the budget is a WINDOW here, not just an unbilled charge. The
    // restore below already keeps the measurement off the demanding
    // statement's ledger, but leaving `inst_count` where the demander left it
    // means a measurement asked for late in a spent statement runs with no
    // budget at all: every `instantiate` under it returns `error_type`, so
    // the generic's member table comes back empty, NO member witnesses the
    // parameter, and `measureOneVariance`'s third-marker test reports
    // `independent` — "these arguments do not participate in the relation".
    // That verdict is then cached under the symbol for the whole run, and
    // every later pair of instantiations relates by nothing.
    //
    // kysely's `AliasedRawBuilder<O, A>` is the shape that showed it:
    // `AliasedRawBuilder<string, 'a2'>` was assignable to
    // `AliasedRawBuilder<number, 'a1'>` iff immich's `asset.repository.ts`
    // was also in the program, which collapsed every `sql`…`.as(name)` in a
    // `.select([…])` array to ONE union constituent (subtype reduction) and
    // dropped the rest of the columns from the row type.
    //
    // This is the same argument the `rel_id_floor` comment above makes, on
    // the one axis it did not cover: the answer is cached under the generic
    // alone, so it must be computed as a function of the generic alone.
    // Bounded work — one window per generic per checker, and the window is
    // still capped by `max_instantiation_count` from zero.
    c.inst_count = 0;
    c.newBudgetWindow();
    c.inst_limit_tripped = false;
    // The relation stack is bookkeeping here too, and for a stronger reason
    // than the counters above: a measurement is a question about the GENERIC,
    // and its answer is cached under the generic alone. Left on top of
    // whatever chain of frames happened to demand it, the growing-instantiation
    // guard would read those frames as part of the measurement's own spine and
    // cut it early — turning a real verdict into `unmeasured`, which then
    // stands for every later user of the generic. That makes the measured
    // variance depend on which reference asked first, i.e. on file order and
    // on how work was split across checkers.
    //
    // Hide them behind a FLOOR rather than clearing the stack: the frames
    // below are still live and will pop themselves (their bucket counts have
    // to survive), so only the growth test's window moves. The guard therefore
    // still bounds the measurement, it just bounds it by the measurement's own
    // spine, which is what makes the answer a pure function of the generic —
    // tsc measures in its own `getVariances` context for the same reason.
    const saved_rel_id_floor = c.rel_id_floor;
    c.rel_id_floor = c.rel_id_depth;
    // The expanding flags are read from the same stack the floor hides, so they
    // are part of the same isolation: a bit inherited from the demanding walk
    // would make the measurement's cut depend on that walk.
    const saved_rel_expanding = c.rel_expanding;
    c.rel_expanding = 0;
    // The relation's IN-PROGRESS MARKS are the same story on the last axis the
    // two isolations above do not cover, and it is the one that decides which
    // overload a call resolves to.
    //
    // Every frame the demanding walk has open holds a `2` in `relation`
    // ("assume related", the cycle cut). Those marks are facts about THAT
    // walk, and a measurement running under them can read one — the marker
    // instantiations it mints are references to the very generic whose members
    // the demander is halfway through relating — and take an assumed YES where
    // a measurement of the generic alone would have done the work and answered
    // NO. The verdict is then cached under the symbol for the whole run, so a
    // pair of instantiations relates by whatever the first demander happened to
    // have on its stack: `Object.entries(description)` in social-app's
    // `router.ts` picked the generic `entries<T>` overload under one partition
    // and the `entries(o: {}): [string, any][]` overload under another, which
    // is a `TS2339` on `unknown` that appears at `--checkers=2..8` and not at
    // `--checkers=1`.
    //
    // So withdraw them for the duration and put them back after, exactly as
    // `rel_id_floor` hides the growth stack. `rel_maybe` is precisely the set
    // of keys standing at `2` right now (see `Checker.rel_maybe`), and it is a
    // handful of entries deep on real programs, so the save/restore is cheap.
    // Anything the measurement leaves standing itself is dropped first — a
    // measurement publishes no assumptions either.
    const saved_maybe = try c.scratch().dupe(u64, c.rel_maybe.items);
    for (saved_maybe) |k| _ = c.relation.remove(k);
    c.rel_maybe.clearRetainingCapacity();
    const saved_rel_assumed = c.rel_assumed;
    c.rel_assumed = false;
    defer {
        for (c.rel_maybe.items) |k| _ = c.relation.remove(k);
        c.rel_maybe.clearRetainingCapacity();
        c.rel_maybe.appendSlice(c.cm(), saved_maybe) catch {};
        for (saved_maybe) |k| c.relation.put(c.cm(), k, 2) catch {};
        c.scratch().free(saved_maybe);
        c.rel_assumed = saved_rel_assumed;
        c.rel_id_floor = saved_rel_id_floor;
        c.rel_expanding = saved_rel_expanding;
        c.suppress_inst_diag = saved_suppress;
        c.inst_count = saved_count;
        c.budget_epoch = saved_epoch;
        c.inst_limit_tripped = saved_tripped;
        c.variance_measure_depth -= 1;
        _ = c.measuring_variance.remove(owner);
    }

    const declared = try c.declaredVariances(owner);
    var bits: u32 = 0;
    for (tps.items, 0..) |_, i| {
        const dv: Variance = if (i >= 16) .none else @enumFromInt(@as(u2, @truncate(declared >> @intCast(2 * i))));
        const m: Measured = switch (dv) {
            .covariant => .covariant,
            .contravariant => .contravariant,
            .invariant => .invariant,
            .none => try measureOneVariance(c, owner, tps.items, i),
        };
        bits |= @as(u32, @intFromEnum(m)) << @intCast(3 * i);
    }
    // Cached unconditionally, even when the relation gave up on depth
    // somewhere inside (`max_relation_depth`, "assume related"): a
    // measurement is answered ONCE per generic per checker, and re-running an
    // expensive one on every reference — which is what declining to cache
    // amounts to — costs more than the precision it buys. A verdict skewed by
    // the depth guard is skewed towards "related", and only POSITIVE verdicts
    // are believed (see `measuredVarianceVerdict`), so the cost is an
    // under-report, never a false positive.
    try c.measured_variance.put(c.cm(), owner, bits);
    return bits;
}

/// One parameter's measurement: build the two instantiations that differ only
/// at position `i` — one carrying the `sub` marker, one the `super` — and ask
/// the relation which way they go.
fn measureOneVariance(c: *Checker, owner: SymbolId, tps: []const TypeParamInfo, i: usize) Error!Measured {
    const args = try c.scratch().alloc(TypeId, tps.len);
    defer c.scratch().free(args);
    for (tps, 0..) |tp, j| args[j] = try c.ts.makeTypeParam(tp.sym);
    const markers = try c.varianceMarkers(c.symbolName(tps[i].sym));
    args[i] = markers[0];
    const sub_ref = try c.ts.makeRef(owner, args);
    args[i] = markers[1];
    const super_ref = try c.ts.makeRef(owner, args);
    // The parameter is not part of the reference's identity at all (a
    // defaulted tail that `makeRef` dropped): nothing to measure.
    if (sub_ref == super_ref) return .independent;
    try c.marker_refs.put(c.cm(), sub_ref, {});
    try c.marker_refs.put(c.cm(), super_ref, {});
    // A measurement is only as good as the relation that answered it, and the
    // growing-instantiation guard answers "related" from assumption
    // (`rel_guard_tripped`). That can only turn a NO into a YES, so the one
    // verdict it can manufacture is the vacuous both-ways one: a parameter
    // that is really read-and-written reads as bivariant, and every user of
    // the generic then relates by nothing at all. Distrust exactly that case
    // and report the parameter UNMEASURED, so the structural walk decides
    // (tsc's `VarianceFlags.Unmeasurable`). A one-directional verdict stands:
    // its NO half was reached without assuming anything, and its YES half
    // erring towards related is the same under-report the depth cap already
    // accepts (see `measuredVariances`).
    const saved_trip = c.rel_guard_tripped;
    c.rel_guard_tripped = false;
    defer c.rel_guard_tripped = saved_trip;
    // The instantiation budget manufactures the same vacuous verdict, one
    // layer down: a truncated substitution is `error_type`, a member table
    // built out of `error_type` witnesses nothing, and a parameter no member
    // witnesses reads `independent` — "these arguments do not participate in
    // the relation at all", which is the strongest claim this function can
    // make and the one it is least entitled to from a walk that never
    // finished. `measuredVariances` gives the measurement its own budget
    // window so this is rare; when the window itself runs out, distrust the
    // both-ways verdict exactly as above and let the structural walk decide.
    const saved_inst_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or saved_inst_trip;
    const co = try c.isAssignable(sub_ref, super_ref);
    const contra = try c.isAssignable(super_ref, sub_ref);
    if ((c.rel_guard_tripped or c.inst_limit_tripped) and co and contra) return .unmeasured;
    if (co and contra) {
        // Bivariant may just mean the parameter is never witnessed. tsc
        // settles it with a THIRD marker related to neither of the first two
        // (`markerOtherType`): if that one relates as well, no member reads
        // the parameter. A second `varianceMarkers` mint supplies it — its
        // UNCONSTRAINED half is by construction related to nothing but
        // itself, which is exactly the marker wanted.
        const other = (try c.varianceMarkers(c.symbolName(tps[i].sym)))[1];
        args[i] = other;
        const other_ref = try c.ts.makeRef(owner, args);
        try c.marker_refs.put(c.cm(), other_ref, {});
        if (other_ref != super_ref and try c.isAssignable(other_ref, super_ref)) return .independent;
        return .bivariant;
    }
    if (co) return .covariant;
    if (contra) return .contravariant;
    return .invariant;
}

/// What a measured-variance comparison of two references to the same generic
/// concluded. See `measuredVarianceVerdict`.
const VarianceOutcome = enum {
    /// The arguments relate as the parameters are used: the pair is related.
    related,
    /// They do not, and the measurement that says so is complete — tsc returns
    /// `Ternary.False` from `relateVariances` here and never consults the
    /// members. DECISIVE.
    unrelated,
    /// Nothing was concluded: some parameter is unmeasured, the generic is
    /// measuring itself, or the `void` exemption applies. The structural walk
    /// answers, exactly as it did before this existed.
    undecided,
};

/// tsc's `relateVariances` over MEASURED variance: two references to the same
/// generic relate by their type ARGUMENTS, which is what keeps the relation
/// off a body that instantiates the generic again one level deeper.
///
/// A COMPLETE measurement is decisive in BOTH directions, which is tsc's rule
/// and not a strengthening of it: `relateVariances` returns `Ternary.False`
/// when the arguments do not relate, and `structuredTypeRelatedTo` returns
/// that verdict without looking at a single member. (tsc does re-run the
/// structural walk for an *invariant* parameter when it is reporting errors —
/// purely to elaborate WHICH member makes the generic invariant — and then
/// discards a success: "use variance error (there is no structural one) and
/// return false".)
///
/// Believing only the positive half is not a conservative simplification, it
/// is a different type system, because the structural walk is CO-INDUCTIVE: a
/// recursive pair on the stack answers "assume related" (`Checker.rel_assumed`),
/// so a mutually-recursive family whose arguments are genuinely unrelated walks
/// in a circle and comes back YES. outline's models layer is that shape —
///
/// ```ts
/// class Store<T extends Base> { add = (i: T | Partial<T>): T => i as T; }
/// class Base { store: Store<Base>; id = ""; }
/// class Collection extends Base { store: CollectionsStore; name = ""; }
/// ```
///
/// `T` is invariant in `Store` (a parameter of an arrow-initialised FIELD, so
/// contravariant, and the return, so covariant), and `Base` is not assignable
/// to `Collection`, so `Store<Collection>` is not assignable to `Store<Base>`
/// and `Collection` is not assignable to `Base`. The structural walk instead
/// reaches `Collection → Base` again through `Partial<Collection>`, assumes it,
/// and confirms the assumption it started from — ~290 diagnostics tsc reports
/// and ztsc did not, plus the whole TS1240 decorator family downstream of them.
///
/// Two exemptions, both tsc's:
///
///   * a generic measuring ITSELF (`measuring_variance`) is related, tsc's
///     `Ternary.Unknown` for a recursive `getVariances`. Variance is therefore
///     measured only from occurrences that are not nested inside a recursive
///     instantiation of the same generic — and that assumption is what
///     terminates `ZodOptional<this>` inside `ZodType`;
///   * `hasCovariantVoidArgument`: a `void` argument at a COVARIANT parameter
///     means the parameter is only ever returned, and a caller that asked for
///     `void` accepts anything back, so the pair gets the structural walk
///     rather than a verdict.
///
/// Anything the measurement could not settle — an `unmeasured` parameter, or a
/// generic the measurement declined (`measuredVariances` → null, which is
/// tsc's `Unmeasurable`/`Unreliable` and its `AllowsStructuralFallback`) —
/// stays `undecided` and is left to the members as before.
pub fn measuredVarianceVerdict(c: *Checker, s_ref: TypeId, t_ref: TypeId) Error!VarianceOutcome {
    const st = &c.ts;
    const n = st.refArgCount(s_ref);
    if (n == 0 or n != st.refArgCount(t_ref)) return .undecided;
    const owner = st.refSymbol(s_ref);
    if (c.measuring_variance.contains(owner)) return .related;
    if (n > max_measured_params) return .undecided;
    const bits = (try c.measuredVariances(owner)) orelse return .undecided;
    if (bits == 0) return .undecided;
    // Pass 1, over the WHOLE list and relating nothing: does the measurement
    // license a verdict at all? tsc asks the same two questions of the whole
    // variance array before it trusts a failure — `some(variances, v => v &
    // AllowsStructuralFallback)` for an unmeasurable/unreliable parameter, and
    // `hasCovariantVoidArgument` for a `void` argument at a covariant one (the
    // parameter is then only ever returned, and a caller who asked for `void`
    // accepts anything back).
    var decisive = true;
    for (0..n) |i| {
        const v = measuredAt(bits, i);
        if (v == .unmeasured or (v == .covariant and st.kind(st.refArgAt(t_ref, i)) == .void)) {
            decisive = false;
            break;
        }
    }
    // Pass 2: relate the arguments as the parameters are used, stopping at the
    // first one that does not — tsc's `typeArgumentsRelatedTo`.
    for (0..n) |i| {
        const sa = st.refArgAt(s_ref, i);
        const ta = st.refArgAt(t_ref, i);
        if (sa == ta) continue;
        const ok = switch (measuredAt(bits, i)) {
            .unmeasured => false,
            .independent => true,
            .covariant => try c.isAssignable(sa, ta),
            .contravariant => try c.isAssignable(ta, sa),
            .bivariant => (try c.isAssignable(sa, ta)) or (try c.isAssignable(ta, sa)),
            .invariant => (try c.isAssignable(sa, ta)) and (try c.isAssignable(ta, sa)),
        };
        if (!ok) return if (decisive) .unrelated else .undecided;
    }
    return .related;
}

// =====================================================================
// declaration-site variance (TS2636)
// =====================================================================

/// The opaque MARKER pair a declaration-site variance measurement runs
/// against: two type parameters, `sub` constrained by `super`, so `sub` is
/// assignable to `super` and nothing else relates them in either direction
/// (`isAssignable` follows a source parameter's constraint and rejects every
/// non-identical target parameter). Substituting them for the measured
/// parameter turns "how is `T` used?" into one ordinary relation question —
/// exactly how tsc measures variance (`markerSubTypeForCheck` /
/// `markerSuperTypeForCheck`).
///
/// Minted per measured parameter and named after it (`sub-T` / `super-T`,
/// tsc's own display names, so the reported message names the same two types
/// the oracle's does), above the real + merged symbol space like every other
/// fresh type-param symbol (see `fresh_tp_base`). Only a program that
/// actually declares a variance annotation mints any.
pub fn varianceMarkers(c: *Checker, param_name: []const u8) Error![2]TypeId {
    const super_sym = c.fresh_tp_next;
    c.fresh_tp_next += 1;
    try c.fresh_tp_info.append(c.cm(), .{
        // `internText`, not `atom`: the printed name lives in scratch, and
        // `atom` would store the transient slice as an `atom_cache` key —
        // a dangling key that segfaults the next cache rehash.
        .name = try c.internText(try std.fmt.allocPrint(c.scratch(), "super-{s}", .{param_name})),
        .constraint = types.no_type,
        .default = types.no_type,
        .has_default = false,
    });
    const super_ty = try c.ts.makeTypeParam(super_sym);
    const sub_sym = c.fresh_tp_next;
    c.fresh_tp_next += 1;
    try c.fresh_tp_info.append(c.cm(), .{
        .name = try c.internText(try std.fmt.allocPrint(c.scratch(), "sub-{s}", .{param_name})),
        .constraint = super_ty,
        .default = types.no_type,
        .has_default = false,
    });
    return .{ try c.ts.makeTypeParam(sub_sym), super_ty };
}

/// Is `r` one of the two marker references the measurement in flight is
/// relating? Those two must be compared structurally — see
/// `variance_marker_refs`.
pub fn isVarianceMarkerRef(c: *const Checker, r: TypeId) bool {
    return r == c.variance_marker_refs[0] or r == c.variance_marker_refs[1];
}

/// Types a single measurability scan may visit before giving up. Each visit
/// is a distinct type (the `seen` set), so this bounds the walk's recursion
/// depth as well as its width.
const variance_scan_budget: u32 = 4096;

/// The walk `varianceMeasurable` performs over one generic's parametric
/// spine, and the two facts it collects on the way.
pub const VarianceScan = struct {
    /// The generic being measured.
    owner: SymbolId,
    seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    budget: u32 = variance_scan_budget,
    /// The spine loops back to `owner`.
    cyclic: bool = false,
    /// The spine passes through a DIFFERENT generic that carries its own
    /// `in`/`out` annotations.
    via_annotated: bool = false,

    pub fn deinit(sc: *VarianceScan, gpa: std.mem.Allocator) void {
        sc.seen.deinit(gpa);
    }

    /// Both together mean the measurement is order-dependent in tsc — see
    /// `varianceMeasurable`.
    pub fn entangled(sc: *const VarianceScan) bool {
        return sc.cyclic and sc.via_annotated;
    }
};

/// Is the parametric spine of `t` simple enough that relating two marker
/// instantiations of it MEASURES the parameter's variance, rather than
/// probing a corner of the relation where ztsc and tsc need not agree?
///
/// tsc has no such gate — `checkTypeParameterDeferred` reports whatever its
/// relation says — so this is a deliberate under-report, and the reason is
/// the no-false-positive rule: a marker substituted into a `keyof` /
/// conditional / mapped / indexed-access / template position asks the
/// relation about a deferred type with a free parameter in it, which is
/// precisely where ztsc's answers are approximations. A wrong "not
/// assignable" there would invent a TS2636 the oracle never reports, on a
/// declaration that is perfectly fine.
///
/// The scan is cheap because it prunes on `containsTypeParam`: a subtree
/// with no type parameter in it is IDENTICAL in both instantiations, so the
/// relation short-circuits on it (`s == t`) and it cannot influence the
/// measurement. What is left to walk is the spine the parameter flows down.
pub fn varianceMeasurable(c: *Checker, t: TypeId, sc: *VarianceScan) Error!bool {
    if (!try c.containsTypeParam(t)) return true;
    if (sc.budget == 0) return false;
    sc.budget -= 1;
    if ((try sc.seen.getOrPut(c.scratch(), t)).found_existing) return true;
    const s = &c.ts;
    switch (s.kind(t)) {
        .type_param => return true,
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| {
                if (!try c.varianceMeasurable(s.memberAt(t, i), sc)) return false;
            }
            return true;
        },
        .array => return c.varianceMeasurable(s.arrayElem(t), sc),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (!try c.varianceMeasurable(s.tupleElem(t, @intCast(i)).ty, sc)) return false;
            }
            return true;
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (!try c.varianceMeasurable(s.objectProp(t, @intCast(i)).ty, sc)) return false;
            }
            const si = s.objectStringIndex(t);
            if (si != 0 and !try c.varianceMeasurable(si, sc)) return false;
            const ni = s.objectNumberIndex(t);
            if (ni != 0 and !try c.varianceMeasurable(ni, sc)) return false;
            for (0..s.objectCallSigCount(t)) |i| {
                if (!try c.varianceMeasurable(s.objectCallSig(t, @intCast(i)), sc)) return false;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (!try c.varianceMeasurable(s.objectConstructSig(t, @intCast(i)), sc)) return false;
            }
            return true;
        },
        .function => {
            // A type predicate or a `this` parameter carrying the measured
            // parameter is out of scope for the measurement.
            if (s.fnHasPredicate(t)) return false;
            if (s.fnThisType(t) != 0 and try c.containsTypeParam(s.fnThisType(t))) return false;
            if (!try c.varianceMeasurable(s.fnReturn(t), sc)) return false;
            for (0..s.fnParamCount(t)) |i| {
                if (!try c.varianceMeasurable(s.fnParam(t, @intCast(i)).ty, sc)) return false;
            }
            return true;
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| {
                if (!try c.varianceMeasurable(s.refArgAt(t, i), sc)) return false;
            }
            const sym = s.refSymbol(t);
            if (sym == sc.owner) {
                sc.cyclic = true;
            } else if (try c.declaredVariances(sym) != 0) {
                sc.via_annotated = true;
            }
            // The parameter flows INTO another generic: the relation will
            // walk that generic's body with the marker inside it, so the
            // body has to be measurable too. Expansion is memoized and
            // `seen` cuts a self-referential ref.
            const body = try c.expandRef(t);
            if (body == types.error_type or body == t) return false;
            return c.varianceMeasurable(body, sc);
        },
        else => return false,
    }
}

/// The span tsc reports TS2636 at: the `in`/`out` modifier itself (the first
/// of the two for an `in out`), falling back to the parameter's name. Read
/// off the token stream the way `declaredVarianceOfTypeParam` reads the
/// annotation; the caller must already be in the parameter's file.
pub fn varianceAnnotationSpan(c: *Checker, tp_sym: SymbolId) ?Span {
    for (c.declsOf(tp_sym)) |decl| {
        if (c.nodeTag(decl) != .type_param) continue;
        var tok = c.tree.nodeMainToken(decl);
        var first = tok;
        while (tok > 0) {
            tok -= 1;
            switch (c.tree.tokens.tag(tok)) {
                .keyword_in, .keyword_out => first = tok,
                else => break,
            }
        }
        return c.tokSpan(first);
    }
    return null;
}

/// TS2636 at one parameter's annotation, in the parameter's own file (a
/// merged declaration can declare its parameters in a different file from
/// the one being walked — the same rule `evalTypeParamDecls` follows).
pub fn reportVarianceMismatch(c: *Checker, tp_sym: SymbolId, src: TypeId, tgt: TypeId) Error!void {
    const saved = c.enterSymFile(tp_sym);
    defer c.restoreCtx(saved);
    const span = c.varianceAnnotationSpan(tp_sym) orelse return;
    try c.diagFmt(2636, span, "Type '{s}' is not assignable to type '{s}' as implied by variance annotation.", .{
        try c.typeToString(src),
        try c.typeToString(tgt),
    });
}

/// TS2636 — the DECLARATION-site half of TS 4.7 variance: does an `in`/`out`
/// annotation match how the parameter is actually USED?
///
/// tsc's `checkTypeParameterDeferred`: build the two instantiations of the
/// annotated generic that differ only in the measured parameter — one
/// carrying the `sub` marker, one the `super` marker — and ask the ordinary
/// relation whether the direction the annotation promises holds. `out T`
/// promises `G<sub>` is assignable to `G<super>`; `in T` promises the
/// reverse. A parameter used the other way round (`interface Getter<in T> {
/// get(): T }`) fails that one relation, and the failure IS the diagnostic.
///
/// Only pure `in` and pure `out` are measured, exactly as tsc does: `in out`
/// declares invariance, which no use can contradict.
pub fn checkVarianceAnnotations(c: *Checker, owner: SymbolId) Error!void {
    const bits = try c.declaredVariances(owner);
    if (bits == 0) return;
    const f = c.symFlags(owner);
    const generic = if (f.class)
        try c.classInstanceGeneric(owner)
    else if (f.interface)
        try c.interfaceGeneric(owner)
    else if (f.type_alias)
        try c.aliasGeneric(owner)
    else
        return;
    switch (c.ts.kind(generic)) {
        // An annotated ALIAS must resolve to an object/function shape: tsc
        // rejects every other alias body outright, with a different
        // diagnostic (TS2637) that ztsc does not implement. An interface or
        // class-instance body is always one of these anyway; anything else
        // here (a `ref`, an error) is a body that did not resolve.
        .object, .function => {},
        else => return,
    }
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(owner, &tps);
    if (tps.items.len == 0) return;

    // Instantiation and expansion are bookkeeping here: a depth/count trip
    // measuring a type the user never wrote must not spend the program's
    // TS2589 budget on it.
    const saved_suppress = c.suppress_inst_diag;
    c.suppress_inst_diag = true;
    defer c.suppress_inst_diag = saved_suppress;

    var sc: VarianceScan = .{ .owner = owner };
    defer sc.deinit(c.scratch());
    if (!try c.varianceMeasurable(generic, &sc)) return;
    // A cycle back to `owner` that runs THROUGH another annotated generic
    // makes tsc's own answer a function of declaration order, so there is no
    // stable oracle to match: relating the cycle's other member seeds tsc's
    // relation cache with the pair `owner`'s own check then asks about, and
    // the cached answer came from that member's *declared* variance rather
    // than from the structure. Two mutually recursive `in` interfaces are
    // reported only if the offending one is declared FIRST. Measuring here
    // would report both, so measure neither — an under-report, and the only
    // order-independent choice.
    if (sc.entangled()) return;

    const args = try c.scratch().alloc(TypeId, tps.items.len);
    for (tps.items, 0..) |tp, j| args[j] = try c.ts.makeTypeParam(tp.sym);
    for (tps.items, 0..) |tp, i| {
        if (i >= 16) break;
        const v: Variance = @enumFromInt(@as(u2, @truncate(bits >> @intCast(2 * i))));
        if (v != .covariant and v != .contravariant) continue;
        const markers = try c.varianceMarkers(c.symbolName(tp.sym));
        const saved_arg = args[i];
        args[i] = markers[0];
        const sub_ref = try c.ts.makeRef(owner, args);
        args[i] = markers[1];
        const super_ref = try c.ts.makeRef(owner, args);
        args[i] = saved_arg;
        if (sub_ref == super_ref) continue;
        // Same exemption the MEASURED verdict needs (tsc's `markerTypes`):
        // a variance verdict on the very pair a measurement is relating
        // would make every measurement vacuously true.
        try c.marker_refs.put(c.cm(), sub_ref, {});
        try c.marker_refs.put(c.cm(), super_ref, {});
        // `out T` promises sub -> super; `in T` promises the reverse.
        const src = if (v == .covariant) sub_ref else super_ref;
        const tgt = if (v == .covariant) super_ref else sub_ref;
        const saved_refs = c.variance_marker_refs;
        const saved_trip = c.rel_guard_tripped;
        c.variance_marker_refs = .{ sub_ref, super_ref };
        c.rel_guard_tripped = false;
        const ok = c.isAssignable(src, tgt);
        c.variance_marker_refs = saved_refs;
        const tripped = c.rel_guard_tripped;
        c.rel_guard_tripped = saved_trip;
        if (try ok) continue;
        // A relation the growing-instantiation guard had to truncate is not
        // evidence that the annotation is wrong (see `rel_guard_tripped`).
        if (tripped) continue;
        try c.reportVarianceMismatch(tp.sym, src, tgt);
    }
}
