//! Termination heuristics for recursive generic aliases.
//!
//! Two questions live here, and both are answered from STRUCTURE alone —
//! never from assignability — so the verdict is a pure function of the types
//! involved and cannot depend on which checker asked, or in what order:
//!
//!   * **Is this hop making progress?** `shrinkMetric` scores an argument,
//!     `refStrictlyShrinks` compares two hops argument-wise, and
//!     `reexpandShrinking` / `driveShrinkingAlias` drive a recursive alias
//!     exactly as long as the score strictly decreases. A `Tail<"a.b.c">`
//!     chain reduces all the way to `"c"`; a `Grow<T> = … Grow<{deeper:T}>`
//!     chain is left lazy on its first non-decreasing hop, which is what
//!     makes the eager route terminate without a special case.
//!
//!   * **Are these two instantiations the same type?** `reduceForOriginEquiv`
//!     canonicalizes (resolve refs, drop `T & {}`) and `originArgEquiv`
//!     compares the results by identity, recursing through same-symbol refs
//!     and through the `origin` tags two materializations of one generic
//!     carry. Anything it cannot prove equal stays unequal, so a genuinely
//!     different instantiation still fails the relation.
//!
//! Both ceilings (`shrink_reexpand_ceiling`, `origin_equiv_depth`) are belts
//! on top of arguments that already terminate; hitting one keeps the lazy
//! ref, i.e. the conservative answer.

const std = @import("std");
const types = @import("../types.zig");

const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const originTaggable = @import("instantiate.zig").originTaggable;

/// Bound on nested eager expansion of a recursive alias reached through a
/// conditional's true branch (`driveShrinkingAlias`). The chains this
/// drives shrink and bottom out in a handful of hops; the bound is what
/// keeps a GROWING recursion from being driven forever, since the
/// enclosing-ref comparison `reexpandShrinking` uses is not available at
/// that call site.
const max_eager_alias_depth: u32 = 8;

/// A recursive alias reached through a resolved conditional's TRUE BRANCH
/// has no enclosing `.ref` for `expandRef` to re-expand from, so the
/// recursion stalls one hop in.
///
/// The lib's `FlatArray<Arr, Depth>` is the case: `arr.flat()`'s return
/// type is the alias body already materialized against the method's own
/// type parameters, i.e. a deferred indexed access — no `FlatArray<…>` ref
/// survives for `aliasInstance`/`expandRef` to drive. Substituting the call's
/// arguments resolves `Arr extends ReadonlyArray<infer I>` and hands back
/// the bare ref `FlatArray<Elem, 0>`, which then simply sits there. A
/// stalled ref is not a union, so `typeof x === "string"` narrowing and the
/// union relation arms never see the constituents.
///
/// Drive it the same way `aliasInstance` drives a source-written
/// `Alias<args>`, and only where `aliasInstance` itself would: a recursive
/// alias whose body is `originTaggable` (object/function/intersection)
/// deliberately keeps ONE ref spelling. Answers null — keep the lazy ref —
/// for everything else, including a chain that does not bottom out.
pub fn driveShrinkingAlias(c: *Checker, ref: TypeId) Error!?TypeId {
    if (c.ts.kind(ref) != .ref) return null;
    if (c.eager_alias_depth >= max_eager_alias_depth) return null;
    const sym = c.ts.refSymbol(ref);
    if (!c.symFlags(sym).type_alias) return null;
    if (!c.alias_recursive.contains(sym)) return null;
    if ((c.alias_state.get(sym) orelse 0) == 1) return null; // body still materializing
    // Not while an argument still carries an unbound `infer` binder (or a
    // deferred conditional / indexed access): expanding then resolves the
    // recursive step against the placeholder instead of against the value
    // the enclosing conditional is about to bind, which loses the
    // distribution and stalls the chain one hop EARLIER than leaving it
    // lazy would. A free outer type parameter is fine — the reduction is
    // the same for every substitution, which is exactly why the enclosing
    // conditional resolved at all (`arrayDecidablyExtends`).
    if (!try refArgsSettled(c, ref)) return null;
    if (originTaggable(c.ts.kind(try c.aliasGeneric(sym)))) return null;
    c.eager_alias_depth += 1;
    defer c.eager_alias_depth -= 1;
    const expanded = try c.expandRef(ref);
    if (expanded == types.error_type) return null;
    const reduced = try c.reexpandShrinking(ref, expanded);
    // Still a ref: the recursion did not bottom out (a non-shrinking hop, or
    // the ceiling). Keep the lazy spelling rather than a half-driven one.
    if (c.ts.kind(reduced) == .ref) return null;
    return reduced;
}

/// Nothing in `t` is a placeholder an enclosing conditional is still about
/// to fill: no `infer` binder, no deferred conditional / indexed access /
/// mapped type. A free type parameter IS settled — substituting it later
/// cannot change the reduction.
///
/// Only the type-forming shapes an `infer` binder can be handed back
/// through are walked; a materialized object/function is settled by
/// definition, and walking one would visit an app's whole element type on
/// every hop.
fn refArgsSettled(c: *Checker, t: TypeId) Error!bool {
    return refArgsSettledRec(c, t, 0);
}

fn refArgsSettledRec(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return false;
    const s = &c.ts;
    return switch (s.kind(t)) {
        .infer_var,
        .mapped_param,
        .mapped,
        .index_access,
        .conditional,
        .keyof_op,
        .string_mapping,
        .template_literal_type,
        => false,
        // Indexed walks: the recursion can intern and move `extra`.
        .union_type, .intersection, .overloads => blk: {
            for (0..s.memberCount(t)) |i| {
                if (!try refArgsSettledRec(c, s.memberAt(t, i), depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .array => refArgsSettledRec(c, s.arrayElem(t), depth + 1),
        .tuple => blk: {
            for (0..s.tupleLen(t)) |i| {
                if (!try refArgsSettledRec(c, s.tupleElem(t, @intCast(i)).ty, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .ref => blk: {
            for (0..s.refArgCount(t)) |i| {
                if (!try refArgsSettledRec(c, s.refArgAt(t, i), depth + 1)) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

/// Depth ceiling on the recursive origin-arg equivalence walk (see
/// `originArgEquiv`) — a belt on top of the structure-only reduction, which
/// already terminates (each hop peels a ref/intersection/tuple layer).
const origin_equiv_depth: u32 = 8;

/// Canonicalize a type for origin-arg equivalence: resolve refs to their
/// structural form, and drop empty-object members from an intersection
/// (`T & {} ≡ T` — `{}` adds no constraint to an object member, a SOUND
/// rewrite). Returns the interned TypeId so two structurally-identical
/// reductions compare equal by identity, never by assignability.
fn reduceForOriginEquiv(c: *Checker, t: TypeId) Error!TypeId {
    const r = try c.resolveStructural(t);
    if (c.ts.kind(r) != .intersection) return r;
    var non_empty: std.ArrayList(TypeId) = .empty;
    defer non_empty.deinit(c.scratch());
    for (try c.memberList(r)) |m| {
        const rm = try c.resolveStructural(m);
        if (!c.isEmptyObjectType(rm)) try non_empty.append(c.scratch(), rm);
    }
    if (non_empty.items.len == 1) return try reduceForOriginEquiv(c, non_empty.items[0]);
    return r;
}

/// Are two origin args EQUAL as types? Sound, identity-based (never mutual
/// assignability): exact TypeId equality, OR same-symbol refs whose args are
/// pairwise equivalent, OR same-shape tuples elementwise, OR one is the
/// `T & {}` form of the other, OR two materializations sharing a same-symbol
/// origin tag. Anything else — including `unknown`/`any` collapse against a
/// concrete type — is NOT equivalent, so a genuinely different instantiation
/// still fails the relation.
pub fn originArgEquiv(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
    if (a0 == b0) return true;
    if (depth > origin_equiv_depth) return false;
    const s = &c.ts;
    // Compare same-symbol refs structurally WITHOUT expanding (so the
    // recursion tracks arg identity, not the materialized objects).
    if (s.kind(a0) == .ref and s.kind(b0) == .ref and s.refSymbol(a0) == s.refSymbol(b0)) {
        const na = s.refArgCount(a0);
        if (na == s.refArgCount(b0)) {
            var all = true;
            for (0..na) |i| {
                if (!try c.originArgEquiv(s.refArgAt(a0, i), s.refArgAt(b0, i), depth + 1)) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
    }
    const a = try reduceForOriginEquiv(c, a0);
    const b = try reduceForOriginEquiv(c, b0);
    // Identity after reduction — but not for the trivial top/bottom types,
    // whose relation the normal walk already handles permissively (guards
    // against a cycle-truncated `error_type` on both sides reading as equal).
    if (a == b) {
        return switch (s.kind(a)) {
            .any, .err, .unknown, .never, .none => false,
            else => true,
        };
    }
    const ak = s.kind(a);
    if (ak != s.kind(b)) return false;
    if (ak == .tuple) {
        if (s.tupleLen(a) != s.tupleLen(b)) return false;
        for (0..s.tupleLen(a)) |i| {
            const ea = s.tupleElem(a, @intCast(i));
            const eb = s.tupleElem(b, @intCast(i));
            if (ea.flags != eb.flags) return false;
            if (!try c.originArgEquiv(ea.ty, eb.ty, depth + 1)) return false;
        }
        return true;
    }
    // Two distinct materializations of the same generic (each carrying an
    // origin tag): recurse on the origin refs.
    if (ak == .object or ak == .function or ak == .intersection) {
        if (c.origin.get(a)) |oa| {
            if (c.origin.get(b)) |ob| {
                if (oa == ob) return true;
                if (s.kind(oa) == .ref and s.kind(ob) == .ref and s.refSymbol(oa) == s.refSymbol(ob)) {
                    return try c.originArgEquiv(oa, ob, depth + 1);
                }
            }
        }
    }
    return false;
}

/// Ceiling on eager recursive re-expansion of a shrinking alias — a
/// belt-and-braces bound on top of the strict-decrease rule (which already
/// guarantees termination, since the metric is a non-negative integer that
/// strictly decreases each hop). Hitting it stops expanding and keeps the
/// lazy ref — exactly the pre-fix behavior.
const shrink_reexpand_ceiling: u32 = 100;

/// Eagerly reduce a recursive alias reference whose argument demonstrably
/// SHRINKS on each hop. `result0` is what `Alias<args>` (identified by
/// `orig_ref`) instantiated to. When that is a bare `.ref` back to a type
/// alias with a STRICTLY SMALLER structural argument metric, re-expand it —
/// this is what carries `Tail<"a.b.c">` → `Tail<"b.c">` → `Tail<"c">` → `"c"`
/// and tuple peels like `[H, ...infer R]` all the way down.
///
/// The strict-decrease test is precisely what keeps the unbounded `Grow<T> =
/// … Grow<{deeper:T}>` case (conformance instantiation/003 + the Grow-like
/// negative control) from ever eagerly expanding: its argument GROWS, so the
/// metric rises and we stop, leaving the lazy ref (the relation cap /
/// deliberate under-report handles it, unchanged). Mutual recursion (A→B→A)
/// re-expands whenever a hop strictly shrinks and is otherwise conservatively
/// left lazy (a non-decreasing hop stops the loop).
pub fn reexpandShrinking(c: *Checker, orig_ref: TypeId, result0: TypeId) Error!TypeId {
    var result = result0;
    // A DISTRIBUTED result is a union of one-step refs — the conditional's
    // naked-check distribution ran per union member, and each member came
    // back as `Alias<smaller-arg>`. Each of those would have been driven
    // had it been the whole result, so drive them member-wise under the
    // same strict-shrink rule. Without this, `Awaited<Promise<A> |
    // Promise<B>>` stalled at `Awaited<A> | Awaited<B>` while the
    // undistributed `Awaited<Promise<A>>` reduced to `A` — the property
    // accesses on a `Promise.all` result (whose element type is exactly
    // this shape) then all failed with TS2339.
    if (c.ts.kind(result) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        var changed = false;
        for (try c.memberList(result)) |m| {
            const r = if (c.ts.kind(m) == .ref) try c.reexpandShrinking(orig_ref, m) else m;
            if (r != m) changed = true;
            try parts.append(c.scratch(), r);
        }
        return if (changed) c.ts.makeUnion(c.scratch(), parts.items) else result;
    }
    if (c.ts.kind(result) != .ref) return result;
    var prev_ref = orig_ref;
    var iter: u32 = 0;
    while (c.ts.kind(result) == .ref and iter < shrink_reexpand_ceiling) : (iter += 1) {
        const rsym = c.ts.refSymbol(result);
        if (!c.symFlags(rsym).type_alias) break;
        // Cross-alias ENTRY on the first hop: when a NON-recursive wrapper
        // alias reduced to a bare ref of a *different*, self-recursive alias
        // (`ExtractStoreExtensions<…> → ExtractStoreExtensionsFromEnhancerTuple
        // <Tail, Acc>`), the `orig`/`result` symbols differ and the summed
        // metric — comparing two unrelated aliases — need not decrease, so
        // the argument-wise recursion would never start. Expand once to
        // "enter" the inner alias; every subsequent hop is same-alias and
        // must pass the strict argument-wise shrink test below. The growing-
        // argument guards (003/010) are self-recursive (same symbol as
        // `orig`) or reduce to a union (not a bare ref), so they never take
        // this entry — only the strict-shrink path, which correctly stops.
        const entry = iter == 0 and c.ts.refSymbol(prev_ref) != rsym;
        if (!entry and !refStrictlyShrinks(c, prev_ref, result)) break; // not shrinking → leave lazy
        prev_ref = result;
        result = try c.expandRef(result);
    }
    return result;
}

/// Decide whether the hop `prev_ref → cur_ref` strictly shrinks, i.e. the
/// recursion is making progress toward a base case and may be eagerly driven.
///
/// For a SELF-recursive hop (both refs name the same alias), the decision is
/// ARGUMENT-WISE: the hop shrinks iff at least one positional argument's
/// structural metric strictly decreases. This is what carries an accumulator
/// alias `Rec<Tup, Acc> = Tup extends [infer H, ...infer T] ? Rec<T, Acc &
/// F<H>> : Acc` down: the tuple argument strictly shrinks each hop even
/// though the growing accumulator would keep a *summed* metric flat or rising
/// (the RTK `ExtractStoreExtensionsFromEnhancerTuple` + `Acc` and RHF
/// `PathInternal<V, Tr|V>` shapes). The shrinking argument is a non-negative
/// integer bounded below, so a single always-decreasing argument terminates;
/// `shrink_reexpand_ceiling` backstops any pathological alternation. The
/// growing-argument guards (conformance 003/010) stay safe: their sole
/// argument GROWS, so no argument decreases and the hop is not driven.
///
/// For a CROSS-alias hop (mutual recursion A→B), no positional correspondence
/// holds, so fall back to the conservative SUMMED strict-decrease test.
fn refStrictlyShrinks(c: *Checker, prev_ref: TypeId, cur_ref: TypeId) bool {
    const s = &c.ts;
    if (s.kind(prev_ref) != .ref or s.kind(cur_ref) != .ref)
        return shrinkMetric(c, cur_ref) < shrinkMetric(c, prev_ref);
    if (s.refSymbol(prev_ref) == s.refSymbol(cur_ref)) {
        const pargs = s.refArgs(prev_ref);
        const cargs = s.refArgs(cur_ref);
        if (pargs.len == cargs.len and pargs.len > 0) {
            for (pargs, cargs) |p, q| {
                if (shrinkMetric(c, q) < shrinkMetric(c, p)) return true;
            }
            return false;
        }
    }
    return shrinkMetric(c, cur_ref) < shrinkMetric(c, prev_ref);
}

/// A conservative structural size metric used only to decide whether a
/// recursive alias argument is shrinking. It must (a) DECREASE for the
/// canonical peels — string-literal length for template peels, tuple arity
/// for tuple peels — and (b) INCREASE for `Grow`-style wrapping. String and
/// number literals contribute their text length; tuples/objects/refs charge
/// per element so arity is visible; everything else is a small constant.
/// Bounded by a depth cap so a pathological argument can't blow the stack.
fn shrinkMetric(c: *Checker, t: TypeId) u64 {
    return shrinkMetricRec(c, t, 0);
}

fn shrinkMetricRec(c: *Checker, t: TypeId, depth: u32) u64 {
    if (depth > 40) return 1;
    const s = &c.ts;
    return switch (s.kind(t)) {
        .string_literal, .bigint_literal => 1 + @as(u64, @intCast(c.atomText(s.literalAtom(t)).len)),
        .number_literal, .number_literal_fresh => 3,
        .tuple => blk: {
            var sum: u64 = 1;
            for (0..s.tupleLen(t)) |i| sum += 1 + shrinkMetricRec(c, s.tupleElem(t, @intCast(i)).ty, depth + 1);
            break :blk sum;
        },
        .array => 2 + shrinkMetricRec(c, s.arrayElem(t), depth + 1),
        .union_type, .intersection, .overloads => blk: {
            var sum: u64 = 1;
            for (s.members(t)) |m| sum += 1 + shrinkMetricRec(c, m, depth + 1);
            break :blk sum;
        },
        .object => blk: {
            var sum: u64 = 1;
            for (0..s.objectPropCount(t)) |i| sum += 2 + shrinkMetricRec(c, s.objectProp(t, @intCast(i)).ty, depth + 1);
            break :blk sum;
        },
        .ref => blk: {
            var sum: u64 = 1;
            for (s.refArgs(t)) |a| sum += shrinkMetricRec(c, a, depth + 1);
            break :blk sum;
        },
        else => 1,
    };
}
