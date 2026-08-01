//! Structural assignability and the diagnostic-emitting assignment check.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../ast.zig");
const scanner = @import("../scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../binder.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const libs = @import("../libs.zig");
const modules = @import("../modules.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Io = std.Io;
const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const Check = checker_zig.Check;
const check = checker_zig.check;
const max_relation_depth = checker_zig.max_relation_depth;

const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const aliasInstance = @import("instantiate.zig").aliasInstance;
const atom = Checker.atom;
const baseConstraintOf = @import("expr.zig").baseConstraintOf;
const diagAlreadyFiled = Checker.diagAlreadyFiled;
const enumAssignable = @import("enums.zig").enumAssignable;
const indexedAccessType = @import("typenode.zig").indexedAccessType;
const instantiate = @import("enums.zig").instantiate;
const isEmptyObjectType = @import("instantiate.zig").isEmptyObjectType;
const originTaggable = @import("instantiate.zig").originTaggable;
const propOfType = @import("props.zig").propOfType;
const resolveStructural = @import("instantiate.zig").resolveStructural;
const restUnionOptionalAt = @import("typenode.zig").restUnionOptionalAt;
const run = Checker.run;

// =====================================================================
// assignability
// =====================================================================

pub fn isComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    return (try c.isAssignable(a, b)) or (try c.isAssignable(b, a));
}

/// tsc's `typeMaybeAssignableTo`: like `isAssignable`, except a UNION
/// source only has to have SOME constituent assignable to the target. Used
/// where the question is "could this value have come from that slot" rather
/// than "does this value fit that slot".
pub fn maybeAssignable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (c.ts.kind(a) != .union_type) return c.isAssignable(a, b);
    for (try c.memberList(a)) |m| {
        if (try c.isAssignable(m, b)) return true;
    }
    return false;
}

/// The `as`-cast overlap test (TS2352). tsc uses its *comparable* relation
/// here, which is strictly more lenient than mutual assignability: an
/// optional source property may satisfy a required target property
/// (`{ legends?: X[] }` overlaps `{ legends: X[] }`). ztsc's isComparable
/// (assignable either way) misses exactly that case, so after the two
/// assignability probes fail, retry each direction with the optional→
/// required leniency. Kept to the cast site only — narrowing/discriminant
/// uses of isComparable are unchanged.
pub fn castComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    return c.castComparableRec(a, b, 0);
}

/// tsc's *comparable* relation distributes over unions existentially and
/// resolves a type parameter to its constraint. A cast `x as T` where `T`
/// is a type parameter is legal iff `x` is comparable to `T`'s constraint —
/// and an unconstrained parameter (constraint `unknown`/`any`) is
/// comparable to anything, since it could be instantiated to `x`'s type.
/// Likewise a union on either side is comparable iff SOME constituent is
/// (`{full_name} as ({full_name; id} | null)` overlaps the non-null branch).
/// Oracle-verified: a *constrained* parameter still rejects a
/// non-overlapping cast (`T extends {a} as {b}`), and a union rejects only
/// when NO constituent overlaps (`{q} as (number | boolean)`).
pub fn castComparableRec(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true; // under-report over false-reject, per policy
    const a = try c.resolveStructural(a0);
    const b = try c.resolveStructural(b0);
    // Type parameter on either side → defer to its constraint; unconstrained
    // (or unknown/any constraint) overlaps everything.
    if (c.ts.kind(a) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(a));
        if (con == types.no_type or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any or con == a) return true;
        return c.castComparableRec(con, b0, depth + 1);
    }
    if (c.ts.kind(b) == .type_param) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(b));
        if (con == types.no_type or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any or con == b) return true;
        return c.castComparableRec(a0, con, depth + 1);
    }
    // A deferred `keyof T` compares through the key domain. tsc relates an
    // `Index` operand via `keyofConstraintType` — `string | number |
    // symbol` — never through `keyof <constraint>`, and the comparable
    // relation then distributes over that union existentially. Without it
    // the `Object.keys(o).forEach((k) => o[k as keyof T])` idiom reported
    // TS2352: `string` is not assignable *into* `keyof T`, and the
    // whole key union is not assignable to `string`.
    if (c.ts.kind(a) == .keyof_op) return c.castComparableRec(try c.propertyKeyType(), b0, depth + 1);
    if (c.ts.kind(b) == .keyof_op) return c.castComparableRec(a0, try c.propertyKeyType(), depth + 1);
    // A DEFERRED indexed access (`T[K]`) overlaps everything, like an
    // unconstrained type parameter. tsc only rejects a cast through one when
    // `getBaseConstraintOfType` fully reduces it — which needs the object
    // constraint to answer for EVERY key the index constraint admits, i.e.
    // an index signature or a mapped template (`T extends Record<keyof T,
    // number>`). Substituting the constraints structurally instead reduces
    // shapes tsc leaves deferred (`T extends { a: number; b: number }`,
    // where tsc accepts `s as T[K]` for any `s`), which would be a false
    // rejection — the one thing policy forbids. So the whole family is
    // conceded: comparing the two operands' *members* here reported
    // `result as T[K]` on a numeric record, which tsc accepts, and four
    // more shapes besides. The residual under-report is registered against
    // the negatives case.
    if (c.ts.kind(a) == .index_access or c.ts.kind(b) == .index_access) return true;
    // A DEFERRED mapped type (`{ [K in keyof R]: … }` with `R` still free)
    // is in the same family: a mapped type only survives to here when its
    // key constraint is generic, so its member set is unknown and no
    // member-based verdict is available. tsc's comparable relation asks
    // whether the target's key domain relates to the source's, which a
    // generic domain answers affirmatively for the one key the other side
    // happens to name. Concede the family rather than false-reject — this
    // is redux-toolkit's `slice as Omit<typeof slice, 'actions'> & {
    // actions: { success: ActionCreatorWithPayload<T, string> } }`, where
    // the slice's own `actions` is `CaseReducerActions<Reducers, …>`.
    // Scoped to an object-shaped counterpart: a mapped type IS an object
    // type whatever its keys turn out to be, so `T[K] as string` under
    // `T extends Record<keyof T, number>` is still decided (and rejected)
    // on the shapes alone.
    if ((c.ts.kind(a) == .mapped and mappedCastPeer(c.ts.kind(b))) or
        (c.ts.kind(b) == .mapped and mappedCastPeer(c.ts.kind(a)))) return true;
    // A DEFERRED conditional (`T extends E[] ? E[] : E | null`, the return
    // type of a generic overload written as one function) has no resolved
    // form here. tsc compares against its *default constraint* — the union
    // of the two branches — and the comparable relation then distributes
    // over that union existentially, exactly like the union arms below.
    // Without it, the standard idiom of casting the computed result to the
    // declared conditional return type is a spurious TS2352.
    if (c.ts.kind(a) == .conditional) {
        return (try c.castComparableRec(c.ts.condTrue(a), b0, depth + 1)) or
            (try c.castComparableRec(c.ts.condFalse(a), b0, depth + 1));
    }
    if (c.ts.kind(b) == .conditional) {
        return (try c.castComparableRec(a0, c.ts.condTrue(b), depth + 1)) or
            (try c.castComparableRec(a0, c.ts.condFalse(b), depth + 1));
    }
    // Existential union distribution on either side.
    if (c.ts.kind(a) == .union_type) {
        for (try c.memberList(a)) |m| {
            if (try c.castComparableRec(m, b0, depth + 1)) return true;
        }
        return false;
    }
    if (c.ts.kind(b) == .union_type) {
        for (try c.memberList(b)) |m| {
            if (try c.castComparableRec(a0, m, depth + 1)) return true;
        }
        return false;
    }
    if (try c.isComparable(a0, b0)) return true;
    return (try c.lenientOverlap(a0, b0, depth)) or (try c.lenientOverlap(b0, a0, depth));
}

/// The shapes a still-generic mapped type may overlap in the cast test: an
/// object type is the only thing a mapped type can ever instantiate to.
pub fn mappedCastPeer(k: types.Kind) bool {
    return k == .object or k == .intersection or k == .mapped;
}

/// One direction of the lenient comparable relation: does source `s0`
/// overlap target `t0` when optional source props may satisfy required
/// target props? Only the object/object and array/array shapes get the
/// leniency (the shapes where optionality lives); anything else defers to
/// the ordinary comparable check. Depth-capped at 8 — beyond that it
/// answers `true` (under-report, per policy: a cast that deep is not worth
/// a false rejection).
pub fn lenientOverlap(c: *Checker, s0: TypeId, t0: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true;
    const s = try c.resolveStructural(s0);
    const t = try c.resolveStructural(t0);
    const sk = c.ts.kind(s);
    const tk = c.ts.kind(t);
    if (sk == .array and tk == .array) {
        return c.lenientComparable(c.ts.arrayElem(s), c.ts.arrayElem(t), depth + 1);
    }
    // Comparability distributes over a target intersection: the source must
    // overlap EACH constituent (tsc `typeRelatedToEachType`). The dogfood
    // cast `{…} as (A & { id: string })` overlaps in the `comparable(target,
    // source)` direction — the relation *source* is then the intersection,
    // so the object arm below reaches its members via `propOfType`.
    if (tk == .intersection) {
        for (try c.memberList(t)) |m| {
            if (!try c.lenientOverlap(s0, m, depth)) return false;
        }
        return true;
    }
    if (tk == .object) {
        for (0..c.ts.objectPropCount(t)) |i| {
            const tp = c.ts.objectProp(t, @intCast(i));
            // `propOfType` (unlike `objectPropByName`) reaches through a
            // source intersection / ref / string index signature, so the
            // winning direction — where the intersection being cast to is
            // the relation *source* — resolves each target member. Optional
            // target props may be absent (the optional→required leniency);
            // present props need only be comparable (either direction).
            const sp = (try c.propOfType(s, tp.name)) orelse {
                if (tp.optional()) continue;
                return false; // required target member absent from source
            };
            if (!try c.lenientComparable(sp.ty, tp.ty, depth + 1)) return false;
        }
        return true;
    }
    return false; // non-object shapes: the isComparable probes already ruled
}

pub fn lenientComparable(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    // Nested comparability (array elements, object props) distributes over
    // unions and resolves type-parameter constraints exactly like the
    // top-level cast — an array of a union of literals overlaps an array of
    // an intersection element when SOME source constituent overlaps.
    return c.castComparableRec(a, b, depth);
}

/// If `t` is a type parameter, the operand the overlap test should use in
/// its place: its constraint, or `0` for "overlaps everything" (no
/// constraint, or one that is `unknown`/`any`/itself). Returns `t`
/// unchanged when it is not a type parameter.
pub fn typeParamOverlapOperand(c: *Checker, t: TypeId) Error!TypeId {
    const r = try c.resolveStructural(t);
    if (c.ts.kind(r) != .type_param) return t;
    const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
    if (con == types.no_type or con == r or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any) return 0;
    return con;
}

/// Union-distributing overlap test for TS2367/TS2678: some pair of
/// constituents must be comparable.
pub fn typesHaveOverlap(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    return c.typesHaveOverlapRec(a, b, 0);
}

pub fn typesHaveOverlapRec(c: *Checker, a: TypeId, b: TypeId, depth: u32) Error!bool {
    // Under-report over false-reject (project policy): a composite this
    // deep is not worth a phantom TS2367.
    if (depth > 8) return true;
    if (c.ts.kind(a) == .union_type) {
        for (try c.memberList(a)) |m| {
            if (try c.typesHaveOverlapRec(m, b, depth + 1)) return true;
        }
        return false;
    }
    if (c.ts.kind(b) == .union_type) {
        for (try c.memberList(b)) |m| {
            if (try c.typesHaveOverlapRec(a, m, depth + 1)) return true;
        }
        return false;
    }
    // A type parameter compares through its constraint, exactly as in the
    // cast overlap test (`castComparableRec`) — tsc's comparable relation
    // resolves the parameter to its constraint on either side, and an
    // unconstrained parameter overlaps everything because it could be
    // instantiated to the other operand's type. Without this,
    // `t === "text"` inside `function f<T extends Kind>(t: T)` reported a
    // phantom TS2367 (and every `case` of a switch on `t` a phantom
    // TS2678): `isComparable` asks assignability both ways, and neither
    // holds — a literal is not assignable *into* an unresolved `T`, and
    // `T`'s union constraint is not assignable to one literal. The
    // constraint keeps the real negatives (`T extends "a" | "b"` vs
    // `"zzz"` still has no overlap).
    const pa = try c.typeParamOverlapOperand(a);
    if (pa != a) return if (pa == 0) true else c.typesHaveOverlapRec(pa, b, depth + 1);
    const pb = try c.typeParamOverlapOperand(b);
    if (pb != b) return if (pb == 0) true else c.typesHaveOverlapRec(a, pb, depth + 1);
    // tsc's comparable relation: `null` / `undefined` are comparable to
    // every type, so an equality test against (or of) a nullish operand is
    // never TS2367 — `x === null` is the idiomatic guard even when `x`'s
    // declared type can't be null (oracle-verified: `number === null`,
    // `string === undefined`, `null === undefined` are all clean).
    const ka = c.ts.kind(a);
    const kb = c.ts.kind(b);
    if (ka == .null or ka == .undefined or kb == .null or kb == .undefined) return true;
    // tsc's *comparable* relation: a string enum overlaps a string literal
    // equal to one of its member values (`x === 'FEMALE'` where `enum
    // CattleSex { Female = 'FEMALE' }`), even though the plain literal is not
    // *assignable* into the nominal string enum. Only a member-value match
    // overlaps — a non-member literal (`x === 'ZEBRA'`) stays TS2367. (The
    // numeric-enum ↔ number-literal case already overlaps via `isComparable`
    // → `enumAssignable`.)
    const ra = try c.ts.regularLiteral(a);
    const rb = try c.ts.regularLiteral(b);
    if (try c.enumOverlapsStringLiteral(ra, rb)) return true;
    if (try c.enumOverlapsStringLiteral(rb, ra)) return true;
    if (try c.isComparable(a, b)) return true;
    // tsc's *comparable* relation distributes EXISTENTIALLY over an
    // intersection (`someTypeRelatedToType`): the relation holds as soon as
    // ONE constituent relates. A branded primitive therefore overlaps a
    // literal of its own domain through the primitive facet —
    // `number & { _brand: "normalizedZoom" } === 1` and
    // `string & { _brand: "SearchQuery" } === ""` are both clean in tsc,
    // while ztsc's mutual-assignability `isComparable` saw no overlap and
    // reported a phantom TS2367. Kept as a fallback (after the ordinary
    // comparable probes) and existential rather than facet-based, so the
    // real negatives survive: `number & {…} === "x"` and
    // `("a" | "b") & {…} === "z"` still have no comparable constituent.
    const ia = try c.resolveStructural(a);
    if (c.ts.kind(ia) == .intersection) {
        for (try c.memberList(ia)) |m| {
            if (try c.typesHaveOverlapRec(m, b, depth + 1)) return true;
        }
        return false;
    }
    const ib = try c.resolveStructural(b);
    if (c.ts.kind(ib) == .intersection) {
        for (try c.memberList(ib)) |m| {
            if (try c.typesHaveOverlapRec(a, m, depth + 1)) return true;
        }
        return false;
    }
    return false;
}

/// tsc's *comparable* relation for the enum/string-literal pair: a string
/// enum overlaps a string literal equal to one of its member values
/// (`x === 'FEMALE'` where `enum CattleSex { Female = 'FEMALE' }`), even
/// though the plain literal is not *assignable* into the nominal enum. For
/// a MEMBER type only its own value counts, so `E.A === "b"` is still
/// TS2367. (The numeric-enum ↔ number-literal case already overlaps via
/// `isComparable` → `enumAssignable`.) Both arguments are regularized.
pub fn enumOverlapsStringLiteral(c: *Checker, e: TypeId, lit: TypeId) Error!bool {
    if (c.ts.kind(e) != .enum_type or c.ts.kind(lit) != .string_literal) return false;
    if (c.ts.isEnumMember(e)) {
        const v = (try c.enumMemberValue(c.ts.enumSymbol(e), c.ts.enumMemberAtom(e))) orelse return true;
        return v == lit;
    }
    return c.enumHasStringValue(c.ts.enumSymbol(e), c.ts.literalAtom(lit));
}

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
            .none => if (!try c.originArgEquiv(sa, ta, 0)) {
                decisive = false;
            },
            .covariant => if (!try c.isAssignable(sa, ta)) return false,
            .contravariant => if (!try c.isAssignable(ta, sa)) return false,
            .invariant => if (!(try c.isAssignable(sa, ta)) or !(try c.isAssignable(ta, sa))) return false,
        }
    }
    return if (decisive) true else null;
}

/// The generic reference a type denotes: itself when it IS one, otherwise
/// the canonical origin ref of a materialized instantiation (see `origin`).
pub fn refFacetOf(c: *Checker, ty: TypeId, k: types.Kind) ?TypeId {
    if (k == .ref) return ty;
    if (!originTaggable(k)) return null;
    const o = c.origin.get(ty) orelse return null;
    return if (c.ts.kind(o) == .ref) o else null;
}

pub fn isAssignable(c: *Checker, s0: TypeId, t0: TypeId) Error!bool {
    // Structural-relation recursion guard (see `max_relation_depth`). Past
    // the cap, assume the pair related — this only drops diagnostics, never
    // adds a false positive. Returns before the `(s,t)` relation memo below,
    // so the capped result is never cached and a shallower re-encounter of
    // the same pair still computes the real answer.
    if (c.rel_depth > max_relation_depth) return true;
    c.rel_depth += 1;
    defer c.rel_depth -= 1;
    // A polymorphic `this` relates through its apparent instance type. This
    // is a subset simplification (true `this` is nominally narrower than
    // the base), but sound for the fluent/builder patterns we support.
    const s1 = if (c.ts.kind(s0) == .this_type) c.ts.thisTypeInstance(s0) else s0;
    const t1 = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    var s = try c.ts.regularLiteral(s1);
    var t = try c.ts.regularLiteral(t1);
    s = try c.ts.regular(s);
    t = try c.ts.regular(t);
    if (s == t) return true;
    const sk = c.ts.kind(s);
    const tk = c.ts.kind(t);
    // Reflexive origin fast-path (see `origin`): two distinct materialized
    // types (object or function member) that both denote the same generic
    // instantiation `G<A…>` — identical symbol AND element-wise-equal args,
    // so identical interned origin refs — are mutually assignable by
    // identity. This short-circuits the structural walk that would otherwise
    // fail on non-confluent one-step vs two-step reductions of the same
    // type. Identity-only: no variance, it fires solely when the origin refs
    // are equal.
    if (originTaggable(sk) and sk == tk) {
        if (c.origin.get(s)) |os| {
            if (c.origin.get(t)) |ot| {
                // Reflexive identity: same interned origin ref (see `origin`).
                if (os == ot) return true;
                // Variance-free EQUIVALENCE: both denote `G<…>` for the same
                // `G`, and each arg pair is equal — by TypeId identity or by a
                // SOUND reduction (`T & {} ≡ T`; interned structural forms
                // compared by identity, never by mutual assignability). Two
                // args that are equal types make the two instantiations the
                // SAME type regardless of `G`'s variance, so the relation is
                // reflexive. This closes the RTK non-confluence where one
                // instantiation carries an unreduced config `C1 = P & Omit<…>`
                // and the other the concrete reduction `C2 = P`.
                if (c.ts.kind(os) == .ref and c.ts.kind(ot) == .ref and
                    c.ts.refSymbol(os) == c.ts.refSymbol(ot))
                {
                    if (try c.originArgEquiv(os, ot, 0)) return true;
                }
            }
        }
    }
    // A lazy alias `.ref` and the materialization tagged with that very ref
    // denote one type (see `origin`), so the relation between them is
    // reflexive in both directions.
    if (sk == .ref and originTaggable(tk)) {
        if (c.origin.get(t)) |ot| {
            if (ot == s) return true;
            if (c.ts.kind(ot) == .ref and c.ts.refSymbol(ot) == c.ts.refSymbol(s) and
                try c.originArgEquiv(ot, s, 0)) return true;
        }
    }
    if (tk == .ref and originTaggable(sk)) {
        if (c.origin.get(s)) |os| {
            if (os == t) return true;
            if (c.ts.kind(os) == .ref and c.ts.refSymbol(os) == c.ts.refSymbol(t) and
                try c.originArgEquiv(os, t, 0)) return true;
        }
    }
    // Declared variance (`interface Box<in T>`/`<out T>`): two references
    // to the same generic symbol relate by their type ARGUMENTS, not by
    // their members (see `varianceVerdict`). Runs after the identity
    // fast-paths above — an equal pair never reaches here — and yields to
    // the structural walk whenever the annotations are not decisive.
    if (c.refFacetOf(s, sk)) |sr| {
        if (c.refFacetOf(t, tk)) |tr| {
            if (sr != tr and c.ts.refSymbol(sr) == c.ts.refSymbol(tr)) {
                if (try c.varianceVerdict(sr, tr)) |verdict| return verdict;
            }
        }
    }
    // Trivial targets/sources.
    switch (tk) {
        .any, .err, .unknown, .none => return true,
        else => {},
    }
    if (tk == .never) return sk == .never; // even `any` is not assignable to never
    // An uninhabited intersection source denotes `never`, which relates to
    // everything (tsc's `getReducedType`). See `intersectionIsNever`.
    if (sk == .intersection and try c.intersectionIsNever(s)) return true;
    switch (sk) {
        .any, .err, .never, .none => return true,
        else => {},
    }
    if (tk == .void) return sk == .undefined or sk == .void;

    // Literal -> base primitive.
    const base = try c.literalBaseOf(s);
    if (base != types.no_type and base == t) return true;

    // Cache compound comparisons (recursion termination for refs).
    const cacheable = isCompound(sk) or isCompound(tk);
    const key = (@as(u64, s) << 32) | t;
    if (cacheable) {
        if (c.relation.get(key)) |v| {
            c.stats.relation_hits += 1;
            if (v == 2) return true; // in progress: assume (recursive types)
            return v == 1;
        }
        c.stats.relation_misses += 1;
        try c.relation.put(c.cm(), key, 2);
    }
    const result = try c.isAssignableInner(s, t, sk, tk);
    if (cacheable) try c.relation.put(c.cm(), key, @intFromBool(result));
    return result;
}

/// The true branch of a deferred conditional, read with the knowledge that
/// on that branch the check type is a subtype of the extends type.
///
/// tsc wraps every occurrence of the check type inside a conditional's true
/// branch in a *substitution type* constrained by the extends type
/// (`getConditionalFlowTypeOfType`), so `K extends keyof O ? O[K] : D`
/// reads its true branch as `O[K & keyof O]` — which resolves even when
/// `K`'s own constraint is wider than `keyof O`. ztsc has no substitution
/// types, and without them the branch stays `O[K]`, whose constraint index
/// contains keys `O` does not have, so a generic
/// `set(shape: T["type"] extends keyof Shapes ? Shapes[T["type"]] : D)`
/// could not be passed on (TS2345/TS2322).
///
/// Cover the shape that needs it — the branch IS the indexed access
/// `O[check]` — by indexing with the extends type instead. Sound for a
/// SOURCE position, which is the only caller: every instantiation has
/// `K <: extends`, and `O[A | B]` is `O[A] | O[B]`, so `O[K] <: O[extends]`.
pub fn condTrueUnderExtends(c: *Checker, cond: TypeId) Error!TypeId {
    const s = &c.ts;
    const tru = s.condTrue(cond);
    if (s.kind(tru) != .index_access) return tru;
    if (s.indexAccessIndex(tru) != s.condCheck(cond)) return tru;
    return c.reduceIndexedAccess(s.indexAccessObj(tru), s.condExtends(cond));
}

pub fn isCompound(k: types.Kind) bool {
    return switch (k) {
        .union_type, .intersection, .array, .tuple, .object, .function, .overloads, .ref, .class_value, .conditional, .mapped, .index_access, .template_literal_type, .keyof_op => true,
        else => false,
    };
}

pub fn isAssignableInner(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
    // Deferred conditional *source* is handled first (before union
    // distribution): it resolves to one of its branches, so it is
    // assignable to `t` exactly when *both* branches are — even when `t`
    // is a union. Identity is already caught by `s == t` (hash-consed).
    if (sk == .conditional) {
        if (tk == .conditional and c.ts.condCheck(s) == c.ts.condCheck(t) and c.ts.condExtends(s) == c.ts.condExtends(t)) {
            return (try c.isAssignable(c.ts.condTrue(s), c.ts.condTrue(t))) and
                (try c.isAssignable(c.ts.condFalse(s), c.ts.condFalse(t)));
        }
        // A UNION target may contain the matching conditional
        // (`T[] | (M extends X ? T : T[])`, the shape a function that
        // widens its own conditional return type has). Apply the same
        // branch-wise rule to each member first: the fallback below asks
        // each branch to relate to the whole union, and a branch generally
        // relates only to its counterpart *inside* the conditional member.
        if (tk == .union_type) {
            for (try c.memberList(t)) |m| {
                const rm = try c.resolveStructural(m);
                if (c.ts.kind(rm) != .conditional) continue;
                if (c.ts.condCheck(s) != c.ts.condCheck(rm) or c.ts.condExtends(s) != c.ts.condExtends(rm)) continue;
                if ((try c.isAssignable(c.ts.condTrue(s), c.ts.condTrue(rm))) and
                    (try c.isAssignable(c.ts.condFalse(s), c.ts.condFalse(rm)))) return true;
            }
        }
        return (try c.isAssignable(try c.condTrueUnderExtends(s), t)) and
            (try c.isAssignable(c.ts.condFalse(s), t));
    }
    // A deferred `keyof T` source relates through its apparent
    // constraint `string | number | symbol`; handled before union-target
    // distribution because `keyof T` is assignable to the whole key union,
    // not to any single member. Identity (`keyof T <: keyof T`) is caught
    // by the `s == t` fast path.
    // Deferred `keyof T` TARGET (tsc `structuredTypeRelatedTo`, Index as
    // target). Two rules, both purely additive:
    //   - `keyof S` is assignable to `keyof T` exactly when T is assignable
    //     to S (fewer members ⇒ more keys), and
    //   - any S is assignable to `keyof T` when it is assignable to
    //     `keyof C`, C being T's constraint. That is what makes
    //     `pick(o, "id")` legal for `pick<T, K extends keyof T>` called with
    //     an `o: Partial<U>` where `U extends { id: … }`: without it the
    //     literal met the still-deferred `keyof T` and was rejected, and the
    //     inferred `K` collapsed to `never`.
    if (tk == .keyof_op) {
        const t_op = c.ts.keyofOperand(t);
        if (sk == .keyof_op and try c.isAssignable(t_op, c.ts.keyofOperand(s))) return true;
        const bc = try c.transitiveBaseConstraint(t_op);
        if (bc != t_op) {
            const keys = try c.keyofType(bc);
            if (keys != t and try c.isAssignable(s, keys)) return true;
        }
    }
    if (sk == .keyof_op) {
        // A deferred indexed-access TARGET is reduced FIRST. Widening the
        // source to `string | number | symbol` and handing that to the
        // target rule loses the relation: the widened union distributes,
        // and `string` alone does not meet a `K[number]` whose constraint
        // reduces to `keyof R`. tsc reduces an IndexedAccess target before
        // it reaches the source's apparent type, so `keyof R` meets
        // `K[number]` (`K extends readonly (keyof R)[]`) by identity.
        if (tk == .index_access) {
            if (try c.indexAccessTargetConstraint(t)) |bc| {
                if (try c.isAssignable(s, bc)) return true;
            }
        }
        return c.isAssignable(try c.propertyKeyType(), t);
    }
    // Enum *source* against a non-enum target. Handled before union-target
    // distribution, because what an enum relates to is a whole union, not
    // any single member of it.
    //
    // A MEMBER is a subtype of exactly the literal it is initialized with
    // (tsc): `const k: "keydown" = EVENT.KEYDOWN` is legal,
    // `const k: "paste" = EVENT.KEYDOWN` is not, and `EVENT.KEYDOWN` can
    // infer `K extends keyof DocumentEventMap` in an `addEventListener`
    // overload. The WHOLE enum is the union of its members, so it reaches
    // `"keydown" | "paste"` but not `"keydown"` alone.
    //
    // Falls through to the nominal `enumAssignable` when a member's value
    // is computed (the enum is opaque) so `string`/`number` widening still
    // works.
    if (sk == .enum_type and tk != .enum_type) {
        if (c.ts.isEnumMember(s)) {
            if (try c.enumMemberValue(c.ts.enumSymbol(s), c.ts.enumMemberAtom(s))) |v| {
                if (try c.isAssignable(v, t)) return true;
            }
        } else if (try c.enumMemberTypeUnion(c.ts.enumSymbol(s), 0)) |mu| {
            if (try c.isAssignable(mu, t)) return true;
        }
    }
    // Source union distributes first.
    if (sk == .union_type) {
        for (try c.memberList(s)) |m| {
            if (!try c.isAssignable(m, t)) return false;
        }
        return true;
    }
    // A `.ref` SOURCE that resolves to a union must distribute as a source
    // union BEFORE the target-union branch below. A lazy alias
    // self-reference (`ref(Geom)` captured while the recursive alias
    // `Geom = … | GeometryCollection` was still in progress, and later
    // surfaced as the element type of a narrowed `GeometryCollection`'s
    // `geometries: G[]`) has kind `.ref`, not `.union_type`, so without this
    // it is treated as one opaque source and wrongly required to fit a
    // SINGLE target-union member — a spurious TS2345/TS2322. Resolving here
    // lets the source-union distribution above run on re-entry. Scoped to
    // ref-source + union-target + resolves-to-a-union so nothing else moves.
    if (sk == .ref and tk == .union_type) {
        const rs = try c.resolveStructural(s);
        if (rs != s and c.ts.kind(rs) == .union_type) return c.isAssignable(rs, t);
    }
    // Deferred indexed-access *source*, the mirror of the `tk ==
    // .index_access` rule below: `T[K]` relates to a target when its
    // BASE-CONSTRAINT instantiation does (tsc `structuredTypeRelatedTo`,
    // IndexedAccess-as-source). Inside `<T extends { groupIds: string[] }>`
    // a value of type `T["groupIds"]` is usable wherever a `string[]` is.
    //
    // Ahead of the union/intersection target arms, because they answer for
    // the whole target and would otherwise reject the source before it is
    // ever resolved (`T["a"]` against `number | string`). Purely additive:
    // a source whose constraint resolves to nothing better than itself, or
    // does not relate, falls through unchanged.
    if (sk == .index_access) {
        const obj_bc = try c.indexObjBaseConstraint(c.ts.indexAccessObj(s));
        // Same two guards as the target rule: neither side may still be
        // generic after taking base constraints.
        const idx_bc = try c.baseConstraintOf(c.ts.indexAccessIndex(s));
        if (!try c.isGenericObjectForIndex(obj_bc) and !try c.containsFreeTypeParam(idx_bc, &.{})) {
            const bc = try c.reduceIndexedAccess(obj_bc, idx_bc);
            if (bc != s and c.ts.kind(bc) != .unknown and try c.isAssignable(bc, t)) return true;
        }
    }
    if (tk == .union_type) {
        for (try c.memberList(t)) |m| {
            if (try c.isAssignable(s, m)) return true;
        }
        // A type-parameter source relates to a union target through its
        // constraint as a WHOLE, not member-by-member: the loop above tries
        // `T` against each member (which already consults the constraint)
        // and misses the case where the constraint spans the target union
        // without fitting any single member — the
        // `<T extends AllGeoJSON>(f: T): T` residue where `T` flows into a
        // generic call parameter typed by the same union constraint, and
        // `<T, K extends keyof T>(k: K)` into a `PropertyKey` parameter,
        // where the constraint is a deferred `keyof T` whose apparent type
        // is the whole `string | number | symbol` union. Purely a fallback,
        // after single-member matching, and exactly tsc's rule (relate the
        // constraint), so it only ever accepts more.
        if (sk == .type_param) {
            const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(s));
            if (constraint != types.no_type and constraint != s and
                try c.isAssignable(constraint, t)) return true;
        }
        // Discriminated-union normalization: a source object whose
        // discriminant property is a union may still be assignable to a
        // union target that splits that discriminant across members, even
        // though it matched no single member above. An INTERSECTION source
        // qualifies too: `Merge<U, { type: K }>` is
        // `Omit<U, "type"> & { type: K }`, the shape of every helper that
        // re-tags a discriminated union.
        if (sk == .object or sk == .ref or sk == .intersection) {
            if (try c.discriminatedUnionAssignable(s, t)) return true;
        }
        return false;
    }
    if (tk == .intersection) {
        // An intersection SOURCE that still carries a `null`/`undefined`
        // constituent — i.e. one the nullish rule could not reduce to
        // `never`, because its other constituent is instantiable
        // (`null & T`) — does not satisfy an intersection TARGET. tsc
        // relates a source to each constituent of an intersection target
        // with `IntersectionState.Target`, which stops the source
        // intersection from being accepted through a single constituent;
        // the nullish half contributes no members, so the target's members
        // go unmatched (TS2740). A plain object target is NOT affected —
        // tsc accepts `null & T` there, reaching `T`'s constraint — and
        // neither is a source whose nullish half made it `never`, which the
        // fast path above already accepted.
        if (sk == .intersection) {
            if (try c.hasNullishMember(s)) return false;
            if (try c.intersectionPairAssignable(s, t)) |r| return r;
        }
        for (try c.memberList(t)) |m| {
            if (!try c.isAssignable(s, m)) return false;
        }
        return true;
    }
    // The indexed-access-TARGET rule runs before the intersection-SOURCE arm
    // below: that arm ends in `return false` for every non-object target, so
    // with it first the rule was never reachable from an intersection
    // source. Branded scalars (`number & { _brand: "rad" }`) are exactly
    // that shape, and writing one through a `T["angle"]` annotation is the
    // most common way to meet an indexed-access target — every such write
    // was a phantom TS2322. The rule recurses on the reduced target, so an
    // intersection source still reaches the member-wise arm one level down;
    // when its guards do not hold it returns false, which is what the
    // intersection arm did anyway. (The conditional-target arm stays BELOW
    // the intersection source on purpose — tsc rejects a branded scalar
    // against a deferred `T extends 0 ? Radians : Radians`, and hoisting
    // that one too would accept it.)
    //
    // Deferred indexed-access *target*: `S → T[K]` holds when `S` relates to
    // the BASE-CONSTRAINT instantiation of `T[K]` (tsc
    // `structuredTypeRelatedTo`, IndexedAccess-as-target). Inside
    // `<T extends { version: number }>`, `const v: T["version"] = 1` is legal
    // because `T["version"]` is constrained to `number`; without this the
    // access stayed opaque and every write through one was a phantom
    // TS2322/TS2345. When the object side is still generic after
    // substitution the constraint reduces back to the same deferred access
    // (`bc == t`) and the relation stays rejected, as before.
    if (tk == .index_access) {
        if (try c.indexAccessTargetConstraint(t)) |bc| return c.isAssignable(s, bc);
        return false;
    }
    // Deferred (still generic) mapped types. Self-contained: every shape it
    // does not recognize returns null and falls through unchanged.
    if (sk == .mapped or tk == .mapped) {
        if (try c.mappedAssignable(s, t, sk, tk)) |r| return r;
    }
    if (sk == .intersection) {
        for (try c.memberList(s)) |m| {
            if (try c.isAssignable(m, t)) return true;
        }
        // Fall through: merged-members structural check for object targets.
        if (tk == .object or tk == .ref) {
            const rt = try c.resolveStructural(t);
            // A RECURSIVE alias whose body is an intersection is spelled as a
            // lazy `.ref` in every position (see `aliasInstance`), so an
            // intersection TARGET can arrive here disguised as `.ref` and
            // never reach the `tk == .intersection` arm above. Handing its
            // expansion to `structuralAssignable` is an outright rejection —
            // that helper's first line requires an `.object` target — which
            // made `{…} & T` unassignable to `Node<T> = T & {prev: Node<T> |
            // null}` even though the same relation succeeds when the target
            // is spelled out. Re-dispatch so the intersection-target rule
            // (each constituent must be met) runs.
            if (rt != t and c.ts.kind(rt) == .intersection) return c.isAssignable(s, rt);
            return c.structuralAssignable(s, rt);
        }
        // A deferred CONDITIONAL target is answered by the arm just below,
        // not here. tsc's `someTypeRelatedToType` failing on an intersection
        // source does not end the relation — it falls through to
        // `structuredTypeRelatedTo`, which applies the both-branches rule.
        // Answering `false` here made an intersection unable to meet
        // `T extends X ? S : S` even when both branches ARE the source: no
        // single constituent (`number`, `{ _brand }`) relates to the whole
        // conditional, so the loop above always fails. That is why a UNION
        // OF INTERSECTIONS did not relate to a conditional whose branches
        // were spelled with that very union — the source union distributes
        // to its intersection members first, and each one died here — while
        // a union of plain objects was fine.
        if (tk != .conditional) return false;
    }
    // Deferred conditional *target*: the source must satisfy whichever
    // branch the conditional resolves to, so require it against both.
    if (tk == .conditional) {
        return (try c.isAssignable(s, c.ts.condTrue(t))) and (try c.isAssignable(s, c.ts.condFalse(t)));
    }
    // Template-literal pattern *target*: a concrete string literal is
    // assignable iff its text matches the pattern; `string` and non-string
    // sources are not. (Identical patterns / `string` already resolved via
    // `s == t` / `literalBase`.)
    if (tk == .template_literal_type) {
        if (try c.stringLiteralOf(s)) |atom_| return c.matchTemplatePattern(c.atomText(atom_), t);
        // A template-pattern / string-mapping *source* against a pattern
        // target (both subtypes of `string`): ztsc has no pattern↔pattern
        // matcher, so rather than reject valid assignments — a false
        // positive, e.g. `` `a${string}` `` → `` `${string}` `` or
        // `` `hi-${string}` `` → `` `${string}-${string}` `` — it accepts
        // leniently. This under-reports genuine pattern mismatches, which
        // is policy-acceptable for v0.0.1 (identical patterns already
        // resolved via `s == t`). Was a release-blocking FP.
        if (sk == .template_literal_type or sk == .string_mapping) return true;
        return false;
    }
    // Template-literal pattern *source*: assignable only to `string` (fast
    // path via `literalBase`) or an identical pattern (`s == t`). Reaching
    // here means neither — so no.
    if (sk == .template_literal_type or sk == .string_mapping) return false;
    // Any callable value — arrow/normal functions, overload sets, classes
    // used as values, and callable object/interface types — is assignable
    // to the global `Function` interface. tsc models this via the apparent
    // members a function inherits from `Function`; we special-case the
    // target so an incomplete structural relation against the `Function`
    // interface body can't reject valid code (e.g. `TimerHandler =
    // string | Function` for setInterval/setTimeout). Plain (non-callable)
    // objects are intentionally excluded.
    if (tk == .ref and c.globalSymNamed(c.ts.refSymbol(t), "Function") and try c.isCallableForFunctionIface(s, sk)) return true;
    // Refs: expand and recurse (cache on the ref pair terminates cycles).
    if (sk == .ref or tk == .ref) {
        const rs = try c.resolveStructural(s);
        const rt = try c.resolveStructural(t);
        if (rs == s and rt == t) return false;
        return c.isAssignable(rs, rt);
    }
    // Enum types are nominal (identical enums caught by s == t earlier).
    if (sk == .enum_type or tk == .enum_type) return c.enumAssignable(s, t, sk, tk);
    // Type parameters.
    if (sk == .type_param) {
        const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(s));
        if (constraint != types.no_type) return c.isAssignable(constraint, t);
        return false;
    }
    if (tk == .type_param) return false;

    switch (tk) {
        .boolean => return sk == .bool_true or sk == .bool_false,
        // A `unique symbol` widens to `symbol`; the reverse and cross-decl
        // (distinct `unique symbol`s) are caught by the `s == t` fast path
        // failing above, so nothing else is assignable here.
        .symbol => return sk == .unique_symbol,
        .object_keyword => return isNonPrimitiveKind(sk),
        .array => {
            if (sk == .array) return c.isAssignable(c.ts.arrayElem(s), c.ts.arrayElem(t));
            if (sk == .tuple) {
                const elem = c.ts.arrayElem(t);
                for (0..c.ts.tupleLen(s)) |i| {
                    const e = c.ts.tupleElem(s, @intCast(i));
                    const et = if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
                    if (!try c.isAssignable(et, elem)) return false;
                }
                return true;
            }
            return false;
        },
        .tuple => {
            if (sk != .tuple) return false;
            return c.tupleAssignable(s, t);
        },
        .function => {
            if (sk == .function) return c.signatureAssignable(s, t);
            if (sk == .overloads) {
                for (try c.memberList(s)) |m| {
                    if (try c.signatureAssignable(m, t)) return true;
                }
                return false;
            }
            // Callable object → function type: some call signature
            // of the object must be assignable to the target function.
            if (sk == .object) {
                for (0..c.ts.objectCallSigCount(s)) |i| {
                    if (try c.signatureAssignable(c.ts.objectCallSig(s, @intCast(i)), t)) return true;
                }
                return false;
            }
            return false;
        },
        .overloads => {
            for (try c.memberList(t)) |m| {
                if (!try c.isAssignable(s, m)) return false;
            }
            return true;
        },
        .object => return c.structuralAssignable(s, t),
        .class_value => return false,
        else => return false,
    }
}

/// The key set a mapped type iterates: `keyof <source>` for a homomorphic
/// map (`[P in keyof T]`), the written constraint otherwise.
pub fn mappedKeySet(c: *Checker, m: TypeId) Error!TypeId {
    if (c.ts.mappedHomomorphic(m)) return c.keyofType(c.ts.mappedSource(m));
    return c.ts.mappedConstraint(m);
}

pub fn mappedAddsOptional(c: *Checker, m: TypeId) bool {
    return c.ts.mappedFlags(m) & types.mapped_flag_optional_add != 0;
}

/// Assignability for a DEFERRED mapped type — one whose key set is still
/// generic, so it has no members to walk. Without these rules such a type
/// is opaque: `Mutable<T>` was not assignable to `Readonly<T>`, to another
/// alias with identical text, or to `T` itself, and every generic helper
/// written against one reported a phantom TS2322/TS2345.
///
/// PURELY ADDITIVE: every path that does not establish the relation returns
/// null, so the caller falls through to exactly what it did before (a
/// deferred mapped type is still an `object`, still a `for…in` operand).
/// Readonly-ness is ignored throughout, exactly as it is for object
/// properties; optionality is not — a map that ADDS `?` (`Partial<T>`) is
/// not related to one that does not.
pub fn mappedAssignable(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!?bool {
    if (sk == .mapped and tk == .mapped) {
        // tsc's `mappedTypeRelatedTo`: the modifiers must be compatible,
        // the TARGET's key set must be related to the source's (contra-
        // variant — the target iterates no more keys than the source), and
        // the templates must relate with the two key parameters identified.
        if (c.mappedAddsOptional(s) and !c.mappedAddsOptional(t)) return null;
        if (c.ts.mappedAs(s) != 0 or c.ts.mappedAs(t) != 0) return null; // key remapping: not modelled
        if (!try c.isAssignable(try c.mappedKeySet(t), try c.mappedKeySet(s))) return null;
        const sv = try c.substMappedKey(
            c.ts.mappedValue(s),
            c.ts.mappedParamId(c.ts.mappedKeyParam(s)),
            c.ts.mappedKeyParam(t),
        );
        return if (try c.isAssignable(sv, c.ts.mappedValue(t))) true else null;
    }
    if (tk == .mapped) {
        // tsc `structuredTypeRelatedTo`, verbatim: "An empty object type is
        // related to any mapped type that includes a '?' modifier." Every
        // key such a map produces is optional, so a source with no members
        // satisfies all of them — whatever key set the map is still
        // deferred on. This is what makes `Delta.empty()`, which returns
        // `Delta<unknown>` (`deleted: Partial<unknown>` = `{}`), a legal
        // `Delta<T>` inside `Delta.calculate<T>`.
        if (c.mappedAddsOptional(t) and c.isEmptyObjectType(try c.resolveStructural(s))) return true;
        // tsc `structuredTypeRelatedTo`: `S` is related to `{ [P in C]: X }`
        // when `keyof S` is related to `C` and `S[P]` is related to `X`.
        // Guarded, as tsc guards it, on the target not adding `?` — that
        // direction (`S` → `Partial<S>`) is a different rule.
        if (c.mappedAddsOptional(t) or c.ts.mappedAs(t) != 0) return null;
        if (!try c.isAssignable(try c.keyofType(s), try c.mappedKeySet(t))) return null;
        const access = try c.reduceIndexedAccess(s, c.ts.mappedKeyParam(t));
        return if (try c.isAssignable(access, c.ts.mappedValue(t))) true else null;
    }
    // A homomorphic identity map with only modifier changes IS its source
    // (`Readonly<P>` → `P`). A map that adds `?` is not, and one that
    // rewrites the template is not.
    if (c.ts.mappedHomomorphic(s) and !c.mappedAddsOptional(s) and c.ts.mappedAs(s) == 0) {
        const src = c.ts.mappedSource(s);
        const v = c.ts.mappedValue(s);
        if (c.ts.kind(v) == .index_access and
            c.ts.indexAccessObj(v) == src and
            c.ts.indexAccessIndex(v) == c.ts.mappedKeyParam(s))
        {
            return if (try c.isAssignable(src, t)) true else null;
        }
    }
    return null;
}

/// The base-constraint reduction of a deferred indexed-access TARGET `T[K]`
/// (tsc `structuredTypeRelatedTo`, IndexedAccess-as-target): a source is
/// related to `T[K]` when it is related to this. Null when the access has
/// no meaningful constraint — either side still generic after taking base
/// constraints, or a reduction that lands back on the same deferred access
/// or on `unknown` (what `indexedAccessType` yields for a property that is
/// genuinely absent, where tsc's `getIndexedAccessTypeOrUndefined` returns
/// nothing and the rule does not apply).
pub fn indexAccessTargetConstraint(c: *Checker, t: TypeId) Error!?TypeId {
    const obj_bc = try c.indexObjBaseConstraint(c.ts.indexAccessObj(t));
    // The INDEX takes a single constraint step, not a fixpoint: for
    // `K extends keyof T` that step lands on the deferred `keyof T`, which
    // is still generic and (correctly) blocks the rule. Iterating would
    // collapse it through `keyof unknown` to `never` and make the access
    // look resolvable — silently accepting anything as `T[K]`.
    const idx_bc = try c.baseConstraintOf(c.ts.indexAccessIndex(t));
    if (try c.isGenericObjectForIndex(obj_bc) or try c.containsFreeTypeParam(idx_bc, &.{})) return null;
    const bc = try c.reduceIndexedAccess(obj_bc, idx_bc);
    if (bc == t or c.ts.kind(bc) == .unknown) return null;
    return bc;
}

/// The OBJECT side of a deferred indexed access, reduced the way tsc's
/// `computeBaseConstraint` reduces it: follow a type parameter's constraint
/// chain, and STOP at the first type that is not itself a type parameter.
///
/// `transitiveBaseConstraint` cannot be used here. It re-runs
/// `baseConstraintOf` on whatever the chain lands on, and that substitutes
/// every free param *nested inside* it — so `K extends readonly (keyof R)[]`
/// does not stop at `readonly (keyof R)[]` but goes on to
/// `readonly (keyof Record<string, any>)[]`, i.e. `readonly (string |
/// number)[]`. `K[number]` then reduced to `string | number` instead of
/// `keyof R`: writing a `keyof R` through a `K[number]` slot was a phantom
/// TS2322, and writing a bare `number` was wrongly accepted. tsc's
/// `computeBaseConstraint` returns an object/array type unchanged; it never
/// descends into its type arguments.
pub fn indexObjBaseConstraint(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .type_param) return c.transitiveBaseConstraint(t);
    var cur = t;
    var i: u32 = 0;
    while (i < 8 and c.ts.kind(cur) == .type_param) : (i += 1) {
        const next = try c.baseConstraintOf(cur);
        if (next == cur) break;
        cur = next;
    }
    return cur;
}

/// tsc's `getBaseConstraintOfType`: follow constraints all the way down.
/// `baseConstraintOf` substitutes each type param in `t` with its
/// *immediate* constraint from a fixed map, so `U extends T extends Base`
/// only reaches `T`; re-running it to a fixpoint reaches `Base`.
pub fn transitiveBaseConstraint(c: *Checker, t: TypeId) Error!TypeId {
    var cur = t;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const next = try c.baseConstraintOf(cur);
        if (next == cur) break;
        cur = next;
    }
    return cur;
}

/// Is `k` one of the *non-primitive* type kinds — what the `object` keyword
/// admits, and what a `for…in` right-hand side must be?
///
/// `.mapped` belongs here: a mapped type is an object type by construction,
/// whether or not its key set is still generic. A `Partial<T>` parameter
/// stays deferred as `{ [P in keyof T]: T[P] }` while `T` is a type param,
/// and without this arm every such value was rejected as a `object`
/// argument (TS2345) and as a `for…in` operand (TS2407) — a whole-family
/// false positive on any generic helper that takes a mapped type.
pub fn isNonPrimitiveKind(k: types.Kind) bool {
    return switch (k) {
        .object, .array, .tuple, .function, .overloads, .ref, .class_value, .intersection, .object_keyword, .mapped => true,
        else => false,
    };
}

/// Does `s` carry a call or construct signature — i.e. is it assignable to
/// the global `Function` interface? Functions, overload sets and classes
/// used as values always qualify; object/interface types only if they
/// declare at least one call or construct signature (plain objects do not).
pub fn isCallableForFunctionIface(c: *Checker, s: TypeId, sk: types.Kind) Error!bool {
    switch (sk) {
        .function, .overloads, .class_value => return true,
        .object => return c.ts.objectCallSigCount(s) > 0 or c.ts.objectConstructSigCount(s) > 0,
        .ref => {
            const r = try c.resolveStructural(s);
            if (c.ts.kind(r) == .object) return c.ts.objectCallSigCount(r) > 0 or c.ts.objectConstructSigCount(r) > 0;
            return false;
        },
        else => return false,
    }
}

pub fn tupleAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    const s_len = c.ts.tupleLen(s);
    const t_len = c.ts.tupleLen(t);
    var t_required: u32 = 0;
    var t_has_rest = false;
    for (0..t_len) |i| {
        const e = c.ts.tupleElem(t, @intCast(i));
        if (e.rest()) t_has_rest = true else if (!e.optional()) t_required += 1;
    }
    var s_min: u32 = 0;
    var s_has_rest = false;
    for (0..s_len) |i| {
        const e = c.ts.tupleElem(s, @intCast(i));
        if (e.rest()) s_has_rest = true else if (!e.optional()) s_min += 1;
    }
    if (s_min < t_required) return false;
    if (!t_has_rest and (s_len > t_len or s_has_rest)) return false;
    for (0..s_len) |i| {
        const se = c.ts.tupleElem(s, @intCast(i));
        const st = if (se.rest()) try c.elemOfArrayish(se.ty) else se.ty;
        var tt = try c.tupleElemTypeAt(t, @intCast(i)) orelse return false;
        // An OPTIONAL target element admits `undefined` — tsc bakes it into
        // the element's own type (`[a?: T]`'s type argument is
        // `T | undefined`), where ztsc keeps the bare `T` beside the flag.
        // Reading only the bare type rejected `[string, O | undefined]`
        // against `[string, O?]`, which tsc accepts.
        if (i < t_len and c.ts.tupleElem(t, @intCast(i)).optional()) {
            tt = try c.makeUnion2(tt, types.undefined_type);
        }
        if (!try c.isAssignable(st, tt)) return false;
    }
    return true;
}

/// Is the parameter at position `i` optional? A trailing rest typed by a
/// fixed TUPLE *is* the parameter list, so the optional marker can live on
/// the tuple element rather than on a `Param` — `(...args: [key: string,
/// options?: Opts])` has an optional second parameter exactly as
/// `(key: string, options?: Opts)` does. Reading only the `Param` flags
/// missed that, so the position's type stayed the bare `Opts` where tsc's
/// `getTypeAtPosition` gives `Opts | undefined`.
pub fn paramOptionalAt(c: *Checker, sig: TypeId, i: u32) Error!bool {
    const count = c.ts.fnParamCount(sig);
    if (count > 0) {
        if (try c.sigRestTuple(sig)) |tup| {
            if (i >= count - 1) {
                const k = i - (count - 1);
                if (k >= c.ts.tupleLen(tup)) return false;
                const e = c.ts.tupleElem(tup, k);
                return e.optional() and !e.rest();
            }
        }
    }
    if (i >= count) return false;
    const p = c.ts.fnParam(sig, i);
    return p.optional() and !p.rest();
}

pub fn tupleElemTypeAt(c: *Checker, t: TypeId, i: u32) Error!?TypeId {
    const len = c.ts.tupleLen(t);
    if (i < len) {
        const e = c.ts.tupleElem(t, i);
        return if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
    }
    if (len > 0) {
        const last = c.ts.tupleElem(t, len - 1);
        if (last.rest()) return try c.elemOfArrayish(last.ty);
    }
    return null;
}

/// Object-target structural check. `s` is any structural source
/// (object, array/tuple/string via length lookup, function, ...).
pub fn structuralAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (c.ts.kind(t) != .object) return false;
    // `undefined` / `null` / `void` are not object values. The empty-object
    // fast path below said so, but a target with members reached the
    // property loop instead, where every property of a nullish source is
    // simply absent — so an ALL-OPTIONAL target (`{ a?: string }`,
    // `Partial<T>`) fell through the loop and returned true. Under
    // strictNullChecks tsc rejects all of these (TS2322), whatever the
    // target's optionality.
    switch (c.ts.kind(s)) {
        .null, .undefined, .void => return false,
        else => {},
    }
    const n = c.ts.objectPropCount(t);
    const sidx = c.ts.objectStringIndex(t);
    const nidx = c.ts.objectNumberIndex(t);
    const t_calls = c.ts.objectCallSigCount(t);
    const t_constructs = c.ts.objectConstructSigCount(t);
    // {} accepts anything non-nullish — but a callable/constructable
    // target with no members is not empty: its signatures must be checked.
    if (n == 0 and sidx == 0 and nidx == 0 and t_calls == 0 and t_constructs == 0) {
        const k = c.ts.kind(s);
        return k != .null and k != .undefined and k != .void;
    }
    for (0..n) |i| {
        const tp = c.ts.objectProp(t, @intCast(i));
        // A source string index signature does NOT satisfy a required named
        // target property (tsc TS2741/TS2740); it is related separately as an
        // index signature below. So `{ [k: string]: any }` is not assignable
        // to `Date`/`{ x: number }`.
        const sp = (try c.propOfTypeEx(s, tp.name, false)) orelse {
            if (tp.optional()) continue;
            return false;
        };
        if (sp.optional() and !tp.optional()) return false;
        var st = sp.ty;
        if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
        var tt = tp.ty;
        if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
        if (!try c.isAssignable(st, tt)) return false;
    }
    // Target string index signature. tsc: the source satisfies it via
    // (a) a compatible *source* string index signature, or (b) being an
    // object with an *implied* index (object/type literal, not an
    // interface / class-instance / array / tuple / function / primitive)
    // whose every known property conforms. A source with neither — a bare
    // primitive, function, class instance, or interface without an index —
    // fails vacuously no longer: it fails, period.
    if (sidx != 0) {
        switch (c.ts.kind(s)) {
            .object => {
                if (c.ts.objectStringIndex(s) != 0) {
                    if (!try c.isAssignable(c.ts.objectStringIndex(s), sidx)) return false;
                } else if (c.ts.objectHasImpliedIndex(s)) {
                    for (0..c.ts.objectPropCount(s)) |i| {
                        const sp = c.ts.objectProp(s, @intCast(i));
                        if (!try c.isAssignable(sp.ty, sidx)) return false;
                    }
                } else return false; // interface / class instance, no index sig
            },
            // An array/tuple has no *string* index signature of its own, so
            // tsc rejects it against a target string index ("Index signature
            // for type 'string' is missing in type 'T[]'") — with one
            // exception: a target string index whose type is exactly `any`
            // short-circuits the whole index-signature relation. `unknown`
            // does NOT get that exemption — it is not `any` (verified
            // against the oracle: conformance assignability/058). Decisive
            // for
            // `[…] → { [k: string]: any; …optional }`, the shape of a real
            // project's `{ …optional; [key: string]: any }` catch-all.
            .array, .tuple => {
                if (c.ts.kind(try c.resolveStructural(sidx)) != .any) return false;
            },
            else => return false,
        }
    }
    // Target number index signature. Arrays and tuples always carry a
    // numeric index; a source `string` indexes numerically to `string`; an
    // object satisfies via a source number index, a source string index
    // (string keys subsume numeric ones), or — when it has an implied index
    // — its *numerically named* properties.
    if (nidx != 0) {
        switch (c.ts.kind(s)) {
            .array => {
                if (!try c.isAssignable(c.ts.arrayElem(s), nidx)) return false;
            },
            .tuple => {
                for (0..c.ts.tupleLen(s)) |i| {
                    if (!try c.isAssignable(c.ts.tupleElem(s, @intCast(i)).ty, nidx)) return false;
                }
            },
            .string => {
                if (!try c.isAssignable(types.string_type, nidx)) return false;
            },
            .object => {
                if (c.ts.objectNumberIndex(s) != 0) {
                    if (!try c.isAssignable(c.ts.objectNumberIndex(s), nidx)) return false;
                } else if (c.ts.objectStringIndex(s) != 0) {
                    if (!try c.isAssignable(c.ts.objectStringIndex(s), nidx)) return false;
                } else if (c.ts.objectHasImpliedIndex(s)) {
                    for (0..c.ts.objectPropCount(s)) |i| {
                        const sp = c.ts.objectProp(s, @intCast(i));
                        if (!isNumericPropName(c.atomText(sp.name))) continue;
                        if (!try c.isAssignable(sp.ty, nidx)) return false;
                    }
                } else return false; // interface / class instance, no index sig
            },
            else => return false,
        }
    }
    // Target call / construct signatures: the source must supply a
    // matching signature for each. A source that cannot be called (or
    // constructed) provides none and fails a non-empty requirement.
    if (t_calls > 0 and !try c.sourceSatisfiesSigs(s, t, false)) return false;
    if (t_constructs > 0 and !try c.sourceSatisfiesSigs(s, t, true)) return false;
    return true;
}

/// tsc's `getReducedType` for an intersection (`isDiscriminantWithNeverType`):
/// an intersection is UNINHABITED when two of its constituents declare the
/// same required property with unit types that cannot both hold — the
/// intersected property type is `never`, so no value can have it.
///
/// `distinctUnitIntersectionIsEmpty` (types.zig) is the same rule one level
/// down, for an intersection *of* unit types (`"line" & "arrow"`); this is
/// the rule for an intersection of OBJECTS that carry such a property.
/// `ExcalidrawArrowElement & ExcalidrawTextElement` — what narrowing a
/// generic `T extends A | B` by an `x is B` predicate produces — is
/// `{ type: "arrow" } & { type: "text" }` and denotes nothing; tsc drops it
/// from the union it appears in, so a call passing that union sees only the
/// inhabited member. ztsc kept the dead constituent and rejected the call.
///
/// Only consulted as a SOURCE (`never` is assignable to everything), so it
/// can only remove false positives.
/// tsc's `getReducedType` for a UNION (`getReducedUnionType`): a union
/// constituent that is an uninhabited intersection denotes nothing, so tsc
/// removes it outright rather than carrying it along. ztsc only consulted
/// `intersectionIsNever` from the relation, where a dead constituent is
/// harmless; every other consumer (object spread, `.map` return inference,
/// property lookup) saw the dead constituents and produced garbage.
pub fn reduceNeverIntersections(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .intersection)
        return if (try c.intersectionIsNever(t)) types.never_type else t;
    if (c.ts.kind(t) != .union_type) return t;
    const members = try c.scratch().dupe(TypeId, try c.memberList(t));
    defer c.scratch().free(members);
    var kept: std.ArrayList(TypeId) = .empty;
    defer kept.deinit(c.scratch());
    var dropped = false;
    for (members) |m| {
        if (c.ts.kind(m) == .intersection and try c.intersectionIsNever(m)) {
            dropped = true;
            continue;
        }
        try kept.append(c.scratch(), m);
    }
    if (!dropped) return t;
    return try c.ts.makeUnion(c.scratch(), kept.items);
}

pub fn intersectionIsNever(c: *Checker, t: TypeId) Error!bool {
    if (c.never_isect.get(t)) |v| return v;
    // Mark in progress as "inhabited": a property type that recurses back
    // into this very intersection is not what makes it empty.
    try c.never_isect.put(c.cm(), t, false);
    const result = try c.computeIntersectionIsNever(t);
    try c.never_isect.put(c.cm(), t, result);
    return result;
}

/// An intersection SOURCE against an intersection TARGET: tsc compares the
/// two MERGED (apparent) property sets, so a name declared by more than one
/// target constituent is demanded at the INTERSECTION of its declarations —
/// `Event & { target: HTMLElement }` demands `target: (EventTarget | null) &
/// HTMLElement`, not merely `HTMLElement`. Decomposing the target
/// constituent by constituent loses exactly that: the source's `{ target: T }`
/// half satisfies the `{ target: HTMLElement }` half on its own, and the
/// nullish part of `Event.target` is never confronted.
///
/// Applies only when every target constituent is a plain property bag whose
/// names overlap; anything with index/call/construct signatures, or a target
/// whose constituents share no name at all (where merging changes nothing),
/// returns null and keeps the per-constituent route.
pub fn intersectionPairAssignable(c: *Checker, s: TypeId, t: TypeId) Error!?bool {
    var objs: std.ArrayList(TypeId) = .empty;
    defer objs.deinit(c.scratch());
    {
        const members = try c.scratch().dupe(TypeId, try c.memberList(t));
        defer c.scratch().free(members);
        for (members) |m| {
            const rm = try c.resolveStructural(m);
            if (c.ts.kind(rm) != .object) return null;
            if (c.ts.objectStringIndex(rm) != 0 or c.ts.objectNumberIndex(rm) != 0) return null;
            if (c.ts.objectCallSigCount(rm) != 0 or c.ts.objectConstructSigCount(rm) != 0) return null;
            try objs.append(c.scratch(), rm);
        }
    }
    var names: std.ArrayList(Atom) = .empty;
    defer names.deinit(c.scratch());
    var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer seen.deinit(c.scratch());
    var shared = false;
    for (objs.items) |o| {
        for (0..c.ts.objectPropCount(o)) |i| {
            const p = c.ts.objectProp(o, @intCast(i));
            if ((try seen.getOrPut(c.scratch(), p.name)).found_existing) {
                shared = true;
            } else try names.append(c.scratch(), p.name);
        }
    }
    if (!shared) return null;
    for (names.items) |nm| {
        const tp = (try c.propOfTypeEx(t, nm, false)) orelse continue;
        const sp = (try c.propOfTypeEx(s, nm, false)) orelse {
            if (tp.optional()) continue;
            return false;
        };
        if (sp.optional() and !tp.optional()) return false;
        var st = sp.ty;
        if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
        var tt = tp.ty;
        if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
        if (!try c.isAssignable(st, tt)) return false;
    }
    return true;
}

/// Does this intersection still carry a `null`/`undefined` constituent?
pub fn hasNullishMember(c: *Checker, t: TypeId) Error!bool {
    for (try c.memberList(t)) |m| {
        switch (c.ts.kind(try c.resolveStructural(m))) {
            .null, .undefined => return true,
            else => {},
        }
    }
    return false;
}

pub fn computeIntersectionIsNever(c: *Checker, t: TypeId) Error!bool {
    // The store's nullish rule (`nullishIntersectionIsEmpty`) is deliberately
    // syntactic: it cannot resolve a `.ref`, so `null & HTMLElement` survives
    // interning even though tsc reduces it to `never`. Re-run the rule here,
    // where the members CAN be resolved — an intersection of `null`/
    // `undefined` with anything from a provably disjoint domain has no
    // inhabitants. A member that is still instantiable (a type parameter, a
    // deferred conditional/mapped/indexed access) is left alone, exactly as
    // the store leaves it: `null & T` stays a real, non-empty type.
    {
        var nullish = false;
        var other_domain = false;
        for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            switch (c.ts.kind(rm)) {
                .null, .undefined => nullish = true,
                .object, .array, .tuple, .function, .overloads, .class_value, .object_keyword, .void, .string, .number, .boolean, .bigint, .symbol, .bool_true, .bool_false, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .enum_type, .unique_symbol, .template_literal_type, .string_mapping => other_domain = true,
                else => {},
            }
        }
        if (nullish and other_domain) return true;
    }
    var mem: std.ArrayList(TypeId) = .empty;
    defer mem.deinit(c.scratch());
    var n_obj: usize = 0;
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .object => {
                n_obj += 1;
                try mem.append(c.scratch(), rm);
            },
            // A type parameter's members come from its constraint, which is
            // exactly what makes `T & B` (the branch type of an `x is B`
            // predicate on a `T extends A`) empty.
            .type_param, .union_type => try mem.append(c.scratch(), rm),
            // Anything still unresolved could contribute anything; do not
            // judge the intersection empty.
            .mapped, .conditional, .index_access, .err, .any, .unknown => return false,
            else => {},
        }
    }
    if (mem.items.len < 2 or n_obj == 0) return false;
    var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer seen.deinit(c.scratch());
    for (mem.items) |o| {
        if (c.ts.kind(o) != .object) continue; // candidate names come from real objects
        for (0..c.ts.objectPropCount(o)) |i| {
            const p = c.ts.objectProp(o, @intCast(i));
            // tsc requires the property to be a DISCRIMINANT: at least one
            // constituent gives it a unit type.
            if (!isUnitLikeKind(c.ts.kind(try c.ts.regularLiteral(p.ty)))) continue;
            if ((try seen.getOrPut(c.scratch(), p.name)).found_existing) continue;
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            var n_decl: usize = 0;
            // tsc's `getUnionOrIntersectionProperty`: the synthesized
            // property of an INTERSECTION is optional only when every
            // declaring constituent declares it optional. `{ type?: "a" } &
            // { type: "b" }` therefore has a REQUIRED `never` property and
            // is empty just the same.
            var all_optional = true;
            for (mem.items) |o2| {
                const p2 = (try c.propOfTypeEx(o2, p.name, false)) orelse continue;
                if (p2.flags & types.prop_flag_optional == 0) all_optional = false;
                n_decl += 1;
                try parts.append(c.scratch(), try c.ts.regularLiteral(p2.ty));
            }
            if (all_optional or n_decl < 2) continue;
            const merged = try c.ts.makeIntersection(c.scratch(), parts.items);
            if (c.ts.kind(merged) == .never) return true;
        }
    }
    return false;
}

/// A single literal / null / undefined / unique-symbol — a "unit" type that
/// can serve as a discriminant value (tsc `isUnitType`).
pub fn isUnitLikeKind(k: types.Kind) bool {
    return switch (k) {
        .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .null, .undefined, .unique_symbol => true,
        else => false,
    };
}

/// tsc `typeRelatedToDiscriminatedType`: a source object with a union-typed
/// discriminant property can be assignable to a union of object members
/// that split that discriminant across members (differing only in the
/// discriminant), even when it is assignable to no single member. Each
/// discriminant constituent must be covered by some member, and the
/// source's remaining properties must be assignable to every matched
/// member. Handles a SINGLE discriminant property (the overwhelmingly
/// common shape); a multi-discriminant grid falls through to the plain
/// single-member path (a sound under-accept, never a false accept).
pub fn discriminatedUnionAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    const sr = try c.resolveStructural(s);
    // The source may be a plain object or an INTERSECTION of objects.
    // `Merge<U, { type: K }>` is `Omit<U, "type"> & { type: K }`, which is
    // exactly the shape a helper that re-tags a discriminated union
    // returns — and the discriminant then lives in a different constituent
    // from the payload, so the whole intersection has to be consulted.
    switch (c.ts.kind(sr)) {
        .object, .intersection => {},
        else => return false,
    }
    const members = try c.memberList(t);
    if (members.len < 2) return false;
    var dnames: std.ArrayList(Atom) = .empty;
    defer dnames.deinit(c.scratch());
    try c.collectPropNames(sr, &dnames, 0);
    for (dnames.items) |dname| {
        const dprop = (try c.propOfTypeEx(sr, dname, false)) orelse continue;
        // Candidate discriminant: present on every member as a unit — or a
        // union of units, which is how a target constituent that already
        // covers several tags spells it — with at least two distinct
        // member values.
        var first_val: TypeId = 0;
        var differs = false;
        var ok = true;
        for (members) |m| {
            const mp = (try c.propOfType(m, dprop.name)) orelse {
                ok = false;
                break;
            };
            const mr = try c.resolveStructural(mp.ty);
            if (!try c.isUnitOrUnitUnion(mr)) {
                ok = false;
                break;
            }
            if (first_val == 0) first_val = mr else if (mr != first_val) differs = true;
        }
        if (!ok or !differs) continue;
        // Every source discriminant constituent must be covered by ≥1
        // member, and every matched member's non-discriminant props must
        // accept the source.
        const src_disc = try c.resolveStructural(dprop.ty);
        const singleton = [_]TypeId{src_disc};
        const src_consts: []const TypeId = if (c.ts.kind(src_disc) == .union_type)
            try c.memberList(src_disc)
        else
            &singleton;
        var all_ok = true;
        for (src_consts) |lv| {
            var covered = false;
            for (members) |m| {
                const mp = (try c.propOfType(m, dprop.name)) orelse continue;
                if (!try c.isAssignable(lv, mp.ty)) continue;
                covered = true;
                if (!try c.nonDiscPropsAssignable(sr, m, dprop.name)) {
                    all_ok = false;
                }
            }
            if (!covered) {
                all_ok = false;
                break;
            }
        }
        if (all_ok) return true;
    }
    return false;
}

/// Every named property an object — or an intersection of objects — has,
/// with duplicates dropped. Only the shapes `discriminatedUnionAssignable`
/// accepts as a source are walked; anything else contributes nothing.
pub fn collectPropNames(c: *Checker, t: TypeId, out: *std.ArrayList(Atom), depth: u32) Error!void {
    if (depth > 4) return;
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => {
            outer: for (0..c.ts.objectPropCount(r)) |i| {
                const name = c.ts.objectProp(r, @intCast(i)).name;
                for (out.items) |seen| {
                    if (seen == name) continue :outer;
                }
                try out.append(c.scratch(), name);
            }
        },
        .intersection => {
            for (try c.memberList(r)) |m| try c.collectPropNames(m, out, depth + 1);
        },
        else => {},
    }
}

/// A unit type, or a union of nothing but unit types.
pub fn isUnitOrUnitUnion(c: *Checker, t: TypeId) Error!bool {
    if (c.ts.kind(t) != .union_type) return isUnitLikeKind(c.ts.kind(t));
    for (0..c.ts.memberCount(t)) |i| {
        const m = try c.resolveStructural(c.ts.memberAt(t, i));
        if (!isUnitLikeKind(c.ts.kind(m))) return false;
    }
    return true;
}

/// Every named property of object `member` other than the discriminant
/// `excl` must be present on `s` and assignable. Members carrying index or
/// call/construct signatures are declined (return false) — the focused
/// check covers only named properties, so bailing keeps the relation sound.
pub fn nonDiscPropsAssignable(c: *Checker, s: TypeId, member: TypeId, excl: Atom) Error!bool {
    const m = try c.resolveStructural(member);
    // An intersection requires every constituent, so relate to each. This
    // is the shape a branded/composed element union has — `{ isDeleted:
    // false } & { type: "diamond" } & Base` — where the discriminant lives
    // in one constituent and the payload in another.
    if (c.ts.kind(m) == .intersection) {
        for (try c.memberList(m)) |part| {
            if (!try c.nonDiscPropsAssignable(s, part, excl)) return false;
        }
        return true;
    }
    if (c.ts.kind(m) != .object) return false;
    if (c.ts.objectStringIndex(m) != 0 or c.ts.objectNumberIndex(m) != 0 or
        c.ts.objectCallSigCount(m) != 0 or c.ts.objectConstructSigCount(m) != 0) return false;
    for (0..c.ts.objectPropCount(m)) |i| {
        const tp = c.ts.objectProp(m, @intCast(i));
        if (tp.name == excl) continue;
        const sp = (try c.propOfTypeEx(s, tp.name, false)) orelse {
            if (tp.optional()) continue;
            return false;
        };
        if (sp.optional() and !tp.optional()) return false;
        var st = sp.ty;
        if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
        var tt = tp.ty;
        if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
        if (!try c.isAssignable(st, tt)) return false;
    }
    return true;
}

/// Whether `s` provides a signature assignable to each of `t`'s call
/// (`is_construct == false`) or construct (`true`) signatures.
/// Function ↔ callable-object relate in both directions; a `class_value`
/// satisfies construct signatures (constructable) — under-reporting exact
/// shape mismatches rather than spuriously rejecting a valid class value.
pub fn sourceSatisfiesSigs(c: *Checker, s: TypeId, t: TypeId, is_construct: bool) Error!bool {
    const sk = c.ts.kind(s);
    if (sk == .any or sk == .err) return true;
    if (is_construct and sk == .class_value) return true;
    var src: std.ArrayList(TypeId) = .empty;
    defer src.deinit(c.scratch());
    switch (sk) {
        .function => if (!is_construct) try src.append(c.scratch(), s),
        .overloads => if (!is_construct) {
            for (try c.memberList(s)) |m| try src.append(c.scratch(), m);
        },
        .object => {
            const cnt = if (is_construct) c.ts.objectConstructSigCount(s) else c.ts.objectCallSigCount(s);
            for (0..cnt) |i| {
                try src.append(c.scratch(), if (is_construct) c.ts.objectConstructSig(s, @intCast(i)) else c.ts.objectCallSig(s, @intCast(i)));
            }
        },
        else => {},
    }
    const t_cnt = if (is_construct) c.ts.objectConstructSigCount(t) else c.ts.objectCallSigCount(t);
    for (0..t_cnt) |i| {
        const tsig = if (is_construct) c.ts.objectConstructSig(t, @intCast(i)) else c.ts.objectCallSig(t, @intCast(i));
        var matched = false;
        for (src.items) |ssig| {
            if (try c.signatureAssignable(ssig, tsig)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

/// A property name that a *number* index signature constrains: a canonical
/// non-negative integer string (`"0"`, `"1"`, `"42"` — not `"01"`, `"1.5"`,
/// `"-1"`, or any non-digit name). Conservative on purpose: a name we do not
/// recognise as numeric is treated as string-keyed and skipped for a number
/// index (an under-report, never a false rejection).
pub fn isNumericPropName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > 1 and text[0] == '0') return false; // no leading zeros
    for (text) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Attempt to relate a generic *source* signature to a concrete target by
/// inferring the source's own type params from the target signature and
/// relating the instantiation. Returns true only when a legal instantiation
/// (inferred args satisfy their constraints) relates in full; false
/// otherwise, so the caller falls through to the erase-to-constraint path.
/// Mirrors tsc's `compareSignaturesRelated`, which instantiates rather than
/// erases a generic source. Only fires for a generic function source against
/// a concrete (non-generic) function target.
pub fn genericSourceRelatesByInference(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (c.ts.kind(s) != .function or c.ts.kind(t) != .function) return false;
    const tps = c.ts.fnTypeParams(s);
    if (tps.len == 0) return false; // source not generic
    if (c.ts.fnTypeParams(t).len != 0) return false; // target still generic
    const tp_syms = try c.scratch().dupe(u32, tps);
    const cand = try c.scratch().alloc(TypeId, tp_syms.len);
    for (cand) |*x| x.* = types.no_type;
    // Infer the source's params from the aligned target params (and the
    // returns), pinning each type param to the concrete shape the target
    // demands.
    const n = @min(c.ts.fnParamCount(s), c.ts.fnParamCount(t));
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try c.unify(c.ts.fnParam(s, i).ty, c.ts.fnParam(t, i).ty, tp_syms, cand, 0);
    }
    try c.unify(c.ts.fnReturn(s), c.ts.fnReturn(t), tp_syms, cand, 0);
    // Build the substitution: an inferred arg must satisfy its constraint
    // (else the instantiation is illegal — tsc rejects); an unbound param
    // falls back to its constraint (or `unknown`).
    const map = try c.scratch().alloc(TpMap, tp_syms.len);
    for (tp_syms, 0..) |tp, k| {
        const con = try c.typeParamConstraint(tp);
        var val = cand[k];
        if (val == types.no_type) {
            val = if (con != types.no_type) con else types.unknown_type;
        } else if (con != types.no_type and !try c.isAssignable(val, con)) {
            return false;
        }
        map[k] = .{ .sym = tp, .ty = val };
    }
    const inst = try c.instantiate(s, map);
    // A full map over the source's own params yields a non-generic sig; if
    // anything remains generic, bail rather than risk recursion.
    if (c.ts.kind(inst) != .function or c.ts.fnTypeParams(inst).len != 0) return false;
    return c.signatureAssignable(inst, t);
}

/// tsc's `SignatureCheckMode` (the subset ztsc models). A signature-valued
/// PARAMETER is related as a *callback*: because a callback parameter is an
/// output position, its own parameters relate in the same direction as the
/// outer relation (covariantly, not bivariantly), and — when the outer
/// relation was bivariant to begin with (a method) — its RETURN relates
/// bivariantly. Inside a callback comparison no further callback is
/// recognized, exactly as tsc suppresses `getSingleCallSignature` there.
pub const SigMode = enum {
    /// Top-level signature relation.
    none,
    /// tsc `SignatureCheckMode.BivariantCallback` — the outer relation was
    /// a method (bivariant), so the callback's return relates either way.
    bivariant_callback,
    /// tsc `SignatureCheckMode.StrictCallback` — the outer relation was a
    /// plain function type under strictFunctionTypes; the callback's return
    /// stays covariant.
    strict_callback,
};

/// strictFunctionTypes: contravariant params for function types,
/// bivariant for methods; covariant returns; `void` target returns
/// accept anything.
pub fn signatureAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    return c.signatureAssignableMode(s, t, .none);
}

pub fn signatureAssignableMode(c: *Checker, s: TypeId, t: TypeId, mode: SigMode) Error!bool {
    if (try c.signatureAssignableModeInner(s, t, mode)) return true;
    // tsc's `getErasedSignature` retry. The main path erases a signature's
    // own type parameters to their CONSTRAINTS (`getBaseSignature`), which
    // keeps a `Pick<S, K>` deferred; tsc's erasure maps them to `any`, and a
    // mapped type over `any` demands nothing. That is what makes
    // `Comp<Full>["setState"]` assignable to `Comp<Ui>["setState"]` — the
    // `Pick<S, K>` member of the `state` union absorbs the callback member
    // the constraint erasure could not place. Purely additive: it runs only
    // after the precise relation has already failed, and only when a
    // signature actually has type parameters to erase.
    //
    // Narrow on purpose. `any` is bivalent, so a blanket retry would accept
    // every generic relation the constraint erasure soundly rejects (the
    // negative controls in assignability/043 and inference/
    // generic_source_to_concrete_cb, and the `IsEqual` identity probe in
    // assignability/045, all regress under one). It therefore runs only when
    // a MAPPED type is what the constraint erasure left deferred — the shape
    // whose `any` instantiation is what tsc's acceptance actually rests on —
    // and never when the identity probe has already decided the pair.
    if (c.ts.fnTypeParams(s).len == 0 and c.ts.fnTypeParams(t).len == 0) return false;
    if (try c.identityProbeRelated(s, t)) |_| return false;
    if (!try c.typeHasMapped(s, 0) and !try c.typeHasMapped(t, 0)) return false;
    const sa = try c.eraseParamsToAny(s);
    const ta = try c.eraseParamsToAny(t);
    if (sa == s and ta == t) return false;
    return c.signatureAssignableModeInner(sa, ta, mode);
}

/// Does a deferred mapped type occur within `t0`, shallowly? Depth-bounded:
/// only used to gate the `any`-erasure retry above, where the mapped type
/// sits directly in a parameter's union.
pub fn typeHasMapped(c: *Checker, t0: TypeId, depth: u8) Error!bool {
    if (depth > 4) return false;
    const t = try c.resolveStructural(t0);
    switch (c.ts.kind(t)) {
        .mapped => return true,
        .union_type, .intersection => {
            const ms = try c.scratch().dupe(TypeId, try c.memberList(t));
            defer c.scratch().free(ms);
            for (ms) |m| {
                if (try c.typeHasMapped(m, depth + 1)) return true;
            }
            return false;
        },
        .function => {
            const n = c.ts.fnParamCount(t);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const pt = c.ts.fnParam(t, i).ty;
                if (try c.typeHasMapped(pt, depth + 1)) return true;
            }
            return c.typeHasMapped(c.ts.fnReturn(t), depth + 1);
        },
        .array => return c.typeHasMapped(c.ts.arrayElem(t), depth + 1),
        else => return false,
    }
}

/// Instantiate a signature's own type parameters with `any` (tsc's
/// `createTypeEraser`).
pub fn eraseParamsToAny(c: *Checker, sig: TypeId) Error!TypeId {
    const sig_tps = c.ts.fnTypeParams(sig);
    if (sig_tps.len == 0) return sig;
    const tps = try c.scratch().dupe(u32, sig_tps);
    defer c.scratch().free(tps);
    const map = try c.scratch().alloc(TpMap, tps.len);
    defer c.scratch().free(map);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = types.any_type };
    return c.instantiate(sig, map);
}

pub fn signatureAssignableModeInner(c: *Checker, s: TypeId, t: TypeId, mode: SigMode) Error!bool {
    // tsc's canonical type-IDENTITY probe `(<G>() => G extends X ? A : B)`
    // (react-hook-form's `IsEqual`, and other libraries) compares two types
    // for identity: `IsEqual<X,Y>` reduces to `(<G>()=>G extends X?1:2)
    // extends (<G>()=>G extends Y?1:2)`, which tsc accepts iff X and Y are
    // identical. The general `eraseTypeParams` path below erases the lone
    // `G` to `any`, collapsing both conditional returns to `1|2` — so the
    // probe wrongly reported *any* two sigs assignable and `IsEqual<X,Y>`
    // was always `true` (making RHF `Path`/`PathValue` over an `any`-valued
    // field, `AnyIsEqual<T,Record<string,any>>`, take the wrong branch and
    // drop the deep `` `${K}.${…}` `` members). Recognize the exact shape and
    // relate by extends/branch identity — leaving the lenient erasure every
    // other generic-signature relation relies on untouched (a general
    // abstract-param relation here regresses jest/mock generic sigs).
    if (try c.identityProbeRelated(s, t)) |res| return res;
    // A generic *source* signature may relate to a concrete target by
    // instantiating its own type params — inferred from the target's
    // parameters/return — instead of erasing them to their (possibly far
    // wider) constraints. `<T extends AllGeoJSON>(f: T) => T` relates to
    // `(v: Feature) => Feature` by inferring T = Feature; the erase-to-
    // constraint path below instead over-widens the covariant return
    // (`=> AllGeoJSON` ⊄ `=> Feature`) and wrongly rejects. Purely additive:
    // only returns true, and only after verifying the inferred args satisfy
    // their constraints and the instantiated (non-generic) source relates in
    // full — so it never accepts what the erasure path would soundly reject.
    if (try c.genericSourceRelatesByInference(s, t)) return true;
    const bivariant = (c.ts.fnFlags(s) & types.fn_flag_method != 0) or
        (c.ts.fnFlags(t) & types.fn_flag_method != 0);
    // Erase generics to their constraints (documented simplification).
    var se = try c.eraseTypeParams(s);
    const te = try c.eraseTypeParams(t);
    // The source may be an arrow contextually typed by the generic target:
    // its param/return types then reference the TARGET's type-param symbols
    // as free params (the arrow itself carries no type params, so
    // `eraseTypeParams(s)` left them intact). Erase those against the
    // target's constraints too, so both sides collapse the shared params
    // consistently — the `renderHook`/`typeof base` higher-order wrapper.
    if (c.ts.fnTypeParams(s).len == 0 and c.ts.fnTypeParams(t).len > 0) {
        se = try c.eraseParamsOf(se, t);
    }
    if (try c.requiredParams(se) > try c.paramTotal(te)) return false;
    const s_count = try c.effParamCount(se);
    const t_count = try c.effParamCount(te);
    // tsc's `compareSignaturesRelated` stops the pairwise walk where either
    // side's rest parameter is typed by something that is not one tuple
    // (`getNonArrayRestType`) and compares the two sides' REMAINING
    // parameter lists, each packed into a tuple, at that one position. For
    // a rest typed by a union of tuples that is the whole point: the
    // target's parameter list has to satisfy one ARM, which is what makes
    // i18next's `TFunction` — `(...args: [k, o?] | [k, d, o?])` —
    // assignable to a plain `(key: string, options?: O) => string`, where
    // the per-position union `o | d` in the options slot rejects it.
    const rest_pair: ?u32 = blk: {
        const both = @min(s_count, t_count);
        if (both == 0) break :blk null;
        if ((try c.sigRestUnion(se)) == null and (try c.sigRestUnion(te)) == null) break :blk null;
        break :blk both - 1;
    };
    const pairs = if (rest_pair) |r| r + 1 else @min(try c.paramTotal(se), @max(s_count, t_count));
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        if (rest_pair) |r| {
            if (i == r) {
                const st = try c.restTupleAtPosition(se, i);
                const tt = try c.restTupleAtPosition(te, i);
                if (try c.isAssignable(tt, st)) continue;
                if (mode != .none or !bivariant) return false;
                if (!try c.isAssignable(st, tt)) return false;
                continue;
            }
        }
        var sp = try c.paramTypeAt(se, i) orelse break;
        const tp = try c.paramTypeAt(te, i) orelse break;
        // An optional *source* parameter admits `undefined` at the call
        // site, so its effective type for the contravariant relation is
        // `T | undefined` — exactly as an explicit `?` target param already
        // has undefined baked into its stored type. Without this, a
        // default-valued source param (`b: boolean = false`, whose stored
        // type stays the bare `boolean`) fails against an optional target
        // param `b?: boolean` (`boolean | undefined`), a phantom TS2322 tsc
        // does not report. A *required* source param is untouched, so it
        // still (correctly) fails that target.
        // Both parameters are themselves single-call-signature function
        // types: they are CALLBACKS, and tsc relates them as one signature
        // pair in the *contravariant* direction rather than relating the
        // two parameter types independently (`compareSignaturesRelated`,
        // `SignatureCheckMode.Callback`). Because a callback parameter is
        // an output position, that makes the callback's own parameters
        // relate covariantly with the outer relation — which is what keeps
        // `Map<K, Big>` assignable to `Map<K, Small>` through `forEach`,
        // where whole-signature bivariance is not enough (the callback's
        // return would have to relate the wrong way). Detected on the RAW
        // parameter types, before the optional widening below, and only at
        // the top level: inside a callback comparison tsc suppresses
        // `getSingleCallSignature`, so a callback nested one level deeper
        // relates strictly.
        //
        // ADDITIVE: where tsc makes the callback relation the *only* test
        // for such a pair, ztsc falls through to the pre-existing
        // contravariant/bivariant check when it fails. tsc's exclusivity
        // would also start REJECTING pairs whole-signature bivariance used
        // to accept, and every such case measured in the corpus turned out
        // to be an unrelated inference gap surfacing (`Observable<unknown>`
        // where tsc infers `Observable<number>`) rather than a real error —
        // so the strict form would trade this fix for a batch of new false
        // positives. The consequence is a documented under-report: a
        // callback-parameter mismatch in the *contravariant* direction, and
        // one nested a level deeper, are accepted (conformance
        // assignability/065 + DEFERRED).
        if (mode == .none) {
            if (try c.callbackSigOf(sp)) |s_cb| {
                if (try c.callbackSigOf(tp)) |t_cb| {
                    // tsc also requires matching undefined/null facts.
                    if ((try c.includesNullish(sp)) == (try c.includesNullish(tp))) {
                        const inner: SigMode = if (bivariant) .bivariant_callback else .strict_callback;
                        if (try c.signatureAssignableMode(t_cb, s_cb, inner)) continue;
                    }
                }
            }
        }
        if (try c.paramOptionalAt(se, i)) sp = try c.makeUnion2(sp, types.undefined_type);
        const contra = try c.isAssignable(tp, sp);
        if (!contra) {
            // A callback comparison never falls back to bivariance — its
            // own parameters are already related in the outer direction.
            if (mode != .none or !bivariant) return false;
            if (!try c.isAssignable(sp, tp)) return false;
        }
    }
    const t_ret = c.ts.fnReturn(te);
    // A void-returning target accepts any source return (tsc's early-out).
    // An `asserts x[ is T]` predicate always returns void, so any target
    // assertion predicate lands here and is accepted regardless of source
    // — matching tsc, which compares predicates only after this gate.
    if (t_ret == types.void_type) return true;
    // Type-predicate relation. Once the target return type is
    // non-void, a target type predicate (`x is T`, return boolean)
    // constrains the source per tsc's `compareTypePredicateRelatedTo`:
    //   - the source must also be a type predicate (else TS2322,
    //     "Signature '…' must be a type predicate") — but only when the
    //     target guards an *identifier* (`this is T` targets do not force
    //     the source to be a predicate);
    //   - the predicate kinds must match: same asserts-ness and the same
    //     guarded position (`this` vs a parameter index);
    //   - the asserted type is covariant — source type assignable to
    //     target type.
    // A plain-boolean source → predicate target therefore *fails* (tsc
    // rejects it), and a predicate source → boolean target is fine (the
    // target has no predicate, so this block is skipped).
    if (c.ts.fnHasPredicate(te)) {
        const tp = c.ts.fnPredicate(te);
        if (!c.ts.fnHasPredicate(se)) {
            if (tp.param != types.Predicate.this_param) return false;
        } else {
            const spd = c.ts.fnPredicate(se);
            if (spd.asserts != tp.asserts) return false;
            if (spd.param != tp.param) return false;
            if (tp.ty != types.no_type) {
                if (spd.ty == types.no_type) return false;
                if (!try c.isAssignable(spd.ty, tp.ty)) return false;
            }
        }
    }
    const s_ret = c.ts.fnReturn(se);
    // Covariant return relation. A `void` source return was previously
    // special-cased to accept only `void`/`any`/`unknown` targets — but
    // that manual enumeration rejected union targets containing `void`
    // (e.g. `() => void` vs `() => void | undefined`), which tsc accepts
    // via the union's `void` member. The general relation already gets
    // every case right (`void <: void|undefined` true, `void <: undefined`
    // false, `void <: number` false, `void <: any/unknown` trivially
    // true), so defer to it unconditionally.
    if (try c.isAssignable(s_ret, t_ret)) return true;
    // A BivariantCallback comparison relates the RETURN bivariantly too
    // (tsc: `checkMode & BivariantCallback && compareTypes(targetReturn,
    // sourceReturn) || compareTypes(sourceReturn, targetReturn)`). This is
    // the half that whole-signature bivariance could not express, and it is
    // what makes `L1<{a,b}>` — `interface L1<X> { r(cb: (v: X) => X): void }`
    // — assignable to `L1<{a}>`.
    if (mode == .bivariant_callback) return c.isAssignable(t_ret, s_ret);
    return false;
}

/// tsc `getSingleCallSignature(getNonNullableType(t))`: the lone call
/// signature of a type that is nothing BUT that signature — no properties,
/// no index signatures, no construct signatures, no overloads. A type
/// predicate disqualifies it (tsc excludes predicate signatures from the
/// callback relation).
pub fn callbackSigOf(c: *Checker, t: TypeId) Error!?TypeId {
    const r = try c.resolveStructural(try c.stripNullish(t));
    switch (c.ts.kind(r)) {
        .function => return if (c.ts.fnHasPredicate(r)) null else r,
        .object => {
            if (c.ts.objectPropCount(r) != 0) return null;
            if (c.ts.objectStringIndex(r) != 0 or c.ts.objectNumberIndex(r) != 0) return null;
            if (c.ts.objectConstructSigCount(r) != 0) return null;
            if (c.ts.objectCallSigCount(r) != 1) return null;
            const sig = c.ts.objectCallSig(r, 0);
            return if (c.ts.fnHasPredicate(sig)) null else sig;
        },
        else => return null,
    }
}

/// tsc `getNonNullableType`: drop `null`/`undefined` union constituents.
pub fn stripNullish(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return t;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        switch (c.ts.kind(m)) {
            .null, .undefined => {},
            else => try parts.append(c.scratch(), m),
        }
    }
    if (parts.items.len == 0) return t;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// Does `t` admit `null`/`undefined`? tsc gates the callback relation on
/// the two parameter types agreeing here (`getTypeFacts(…,
/// IsUndefinedOrNull)`), so an optional callback parameter is only related
/// as a callback against another optional one.
pub fn includesNullish(c: *Checker, t: TypeId) Error!bool {
    switch (c.ts.kind(t)) {
        .null, .undefined, .any, .unknown => return true,
        .union_type => {
            for (try c.memberList(t)) |m| {
                switch (c.ts.kind(m)) {
                    .null, .undefined => return true,
                    else => {},
                }
            }
            return false;
        },
        else => return false,
    }
}

/// If `sig` is the type-identity probe `<G>() => (G extends X ? A : B)` — a
/// single type param, no value params, a conditional return checked on that
/// param — return its conditional; else null.
pub fn identityProbeCond(c: *Checker, sig: TypeId) ?TypeId {
    if (c.ts.kind(sig) != .function) return null;
    const tps = c.ts.fnTypeParams(sig);
    if (tps.len != 1) return null;
    if (c.ts.fnParamCount(sig) != 0) return null;
    const ret = c.ts.fnReturn(sig);
    if (c.ts.kind(ret) != .conditional) return null;
    const chk = c.ts.condCheck(ret);
    if (c.ts.kind(chk) != .type_param) return null;
    if (c.ts.typeParamSymbol(chk) != tps[0]) return null;
    return ret;
}

/// When BOTH `s` and `t` are the identity probe `<G>()=>G extends _?_:_`,
/// relate them by IDENTITY of the extends types and branches (tsc's rule),
/// returning the result; otherwise null (fall through to the normal
/// signature relation).
pub fn identityProbeRelated(c: *Checker, s: TypeId, t: TypeId) Error!?bool {
    const cs = c.identityProbeCond(s) orelse return null;
    const ct = c.identityProbeCond(t) orelse return null;
    const xs = try c.resolveStructural(c.ts.condExtends(cs));
    const xt = try c.resolveStructural(c.ts.condExtends(ct));
    // Only decide when BOTH extends types are GROUND. While either is still
    // abstract (`IsEqual<TraversedTypes, infer V>` mid-reduction) the probe
    // must stay deferred, so leave the pre-existing erasure path untouched
    // — this keeps the change strictly additive (it alters only the
    // concrete `IsEqual<A,B>` case, which is the bug).
    if (try c.containsTypeParam(xs) or try c.containsInfer(xs) or
        try c.containsTypeParam(xt) or try c.containsInfer(xt)) return null;
    // Structural IDENTITY (not mutual assignability): the probe holds only
    // when the two extends types and the two branches are the SAME type.
    // ztsc interns objects/unions/etc. structurally, so identity is TypeId
    // equality after `resolveStructural`. Mutual assignability is too loose
    // — an `any`-valued index signature (`Record<string,any>`) is mutually
    // assignable to a distinct object shape yet is not identical, which is
    // exactly the case `IsEqual` must separate.
    const ident = struct {
        fn eq(cc: *Checker, a: TypeId, b: TypeId) Error!bool {
            return (try cc.resolveStructural(a)) == (try cc.resolveStructural(b));
        }
    }.eq;
    if (xs != xt) return false;
    if (!try ident(c, c.ts.condTrue(cs), c.ts.condTrue(ct))) return false;
    if (!try ident(c, c.ts.condFalse(cs), c.ts.condFalse(ct))) return false;
    return true;
}

pub fn eraseTypeParams(c: *Checker, sig: TypeId) Error!TypeId {
    return c.eraseParamsOf(sig, sig);
}

/// Erase `sig`'s free references to the type parameters OWNED BY `owner`
/// (usually `sig` itself). Split out so a signature can also be erased
/// against ANOTHER signature's type params: an arrow contextually typed by
/// a generic target references the TARGET's type-param symbols as free
/// params (the arrow itself is non-generic), and both sides must collapse
/// those shared params to the same constraints to relate — tsc generalizes
/// the arrow over the contextual signature's type params, then erases both.
pub fn eraseParamsOf(c: *Checker, sig: TypeId, owner: TypeId) Error!TypeId {
    // Non-generic early-out before the dupe (the common case).
    const sig_tps = c.ts.fnTypeParams(owner);
    if (sig_tps.len == 0) return sig;
    const tps = try c.scratch().dupe(u32, sig_tps);
    // Fixed base-constraint mapper: each type param → its declared
    // constraint (or `any`). Kept immutable so it can be re-applied.
    const base_map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| {
        const constraint = try c.typeParamConstraint(tp);
        base_map[i] = .{ .sym = tp, .ty = if (constraint != types.no_type) constraint else types.any_type };
    }
    // Resolve nested type-param references inside constraints to a fixed
    // point (tsc `getBaseSignature`): a constraint like
    // `Ret extends TOpt['returnObjects'] extends true ? object : string`
    // still mentions `TOpt`, so a single substitution leaves a deferred
    // conditional that never reduces. Re-applying the *same* base mapper
    // `tps.len - 1` times drives `TOpt` down to its own constraint, letting
    // the conditional collapse (here to `string`). Without this, the erased
    // return type stays an unresolved conditional and a perfectly valid
    // signature (react-i18next `TFunction`) fails to relate to a plain
    // `(key: string) => string`.
    const resolved = try c.scratch().alloc(TpMap, tps.len);
    @memcpy(resolved, base_map);
    const rounds: usize = if (tps.len > 1) tps.len - 1 else 0;
    var iter: usize = 0;
    while (iter < rounds) : (iter += 1) {
        var changed = false;
        for (resolved) |*r| {
            const ni = try c.instantiate(r.ty, base_map);
            if (ni != r.ty) changed = true;
            r.ty = ni;
        }
        if (!changed) break;
    }
    return c.instantiate(sig, resolved);
}

/// i-th effective parameter type (expanding a trailing rest).
pub fn paramTypeAt(c: *Checker, sig: TypeId, i: u32) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    // A trailing rest typed by a fixed tuple *is* that parameter list.
    if (count > 0) {
        if (try c.sigRestTuple(sig)) |tup| {
            if (i < count - 1) return c.ts.fnParam(sig, i).ty;
            return c.tupleElemTypeAt(tup, i - (count - 1));
        }
        // A rest typed by a union of tuples has no single expanded list,
        // but its positions still carry OPTIONALITY: an arm that marks the
        // position `?`, or that is too short to reach it, means a call may
        // omit the argument, so the position admits `undefined`
        // (`restUnionOptionalAt`). The element type itself stays the rest's
        // whole element type — see that helper for what tsc computes.
        if (i + 1 >= count) {
            if (try c.sigRestUnion(sig)) |u| {
                const t = try c.elemOfArrayish(u);
                if (try c.restUnionOptionalAt(u, i - (count - 1))) {
                    return try c.makeUnion2(t, types.undefined_type);
                }
                return t;
            }
        }
    }
    if (i < count) {
        const p = c.ts.fnParam(sig, i);
        return if (p.rest()) try c.elemOfArrayish(p.ty) else p.ty;
    }
    if (count > 0) {
        const last = c.ts.fnParam(sig, count - 1);
        if (last.rest()) return try c.elemOfArrayish(last.ty);
    }
    return null;
}

/// `paramTypeAt`, retried through what the call has already inferred when
/// the trailing rest parameter is typed by a bare type PARAMETER
/// (`...args: Args`). Such a signature has no positional expansion on its
/// own, so the plain lookup answers the rest's array element type — nothing
/// at all for a bare `Args` — and a function argument written for it got no
/// contextual type, leaving its parameters implicit `any`. tsc expands the
/// parameters of the INSTANTIATED signature, by which point `Args` is the
/// tuple an earlier argument supplied (`store.set(atom, (s) => …)` with
/// `atom: WritableAtom<V, [SetStateAction<V>], R>`).
pub fn paramTypeAtInferred(c: *Checker, sig: TypeId, i: u32, map: []const TpMap) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    expand: {
        if (count == 0 or i < count - 1) break :expand;
        const last = c.ts.fnParam(sig, count - 1);
        if (!last.rest() or c.ts.kind(last.ty) != .type_param) break :expand;
        const inst = try c.instantiate(last.ty, map);
        if (inst == last.ty) break :expand;
        const r = try c.resolveStructural(inst);
        if (c.ts.kind(r) != .tuple) break :expand;
        if (try c.tupleElemTypeAt(r, i - (count - 1))) |t| return t;
    }
    return c.paramTypeAt(sig, i);
}

/// Highest accepted argument count (`maxInt` = unbounded).
pub fn paramTotal(c: *Checker, sig: TypeId) Error!u32 {
    const count = c.ts.fnParamCount(sig);
    if (count == 0 or !c.ts.fnParam(sig, count - 1).rest()) return count;
    if (try c.sigRestTuple(sig)) |tup| {
        const len = c.ts.tupleLen(tup);
        if (len > 0 and c.ts.tupleElem(tup, len - 1).rest()) return std.math.maxInt(u32);
        return count - 1 + len;
    }
    return std.math.maxInt(u32);
}

/// Number of effective parameter *positions* — `paramTotal` without the
/// unbounded-rest saturation, so it can bound a pairwise loop.
pub fn effParamCount(c: *Checker, sig: TypeId) Error!u32 {
    const total = try c.paramTotal(sig);
    if (total != std.math.maxInt(u32)) return total;
    const count = c.ts.fnParamCount(sig);
    if (try c.sigRestTuple(sig)) |tup| return count - 1 + c.ts.tupleLen(tup);
    return count;
}

pub fn requiredParams(c: *Checker, sig: TypeId) Error!u32 {
    var n: u32 = 0;
    const count = c.ts.fnParamCount(sig);
    for (0..count) |i| {
        const p = c.ts.fnParam(sig, @intCast(i));
        if (p.optional()) break;
        if (p.rest()) {
            // Expanded rest tuple: its leading non-optional, non-rest
            // elements are required parameters too.
            if (try c.restTupleOf(p)) |tup| {
                for (0..c.ts.tupleLen(tup)) |j| {
                    const e = c.ts.tupleElem(tup, @intCast(j));
                    if (e.optional() or e.rest()) break;
                    n += 1;
                }
            }
            break;
        }
        n += 1;
    }
    // tsc's `getMinArgumentCount` walks back from the last required
    // parameter and drops any trailing parameter whose type accepts
    // `void` — the `(x: void) => T` idiom (e.g. redux-toolkit's
    // `ActionCreatorWithoutPayload`, `(noArgument: void) => …`) is thus
    // callable with zero arguments and assignable to `() => T`.
    while (n > 0) {
        const pt = (try c.paramTypeAt(sig, n - 1)) orelse break;
        if (!try c.paramAcceptsVoid(pt)) break;
        n -= 1;
    }
    return n;
}

/// A parameter type "accepts void" when it is `void`, or a union with a
/// `void` member — tsc writes this as `filterType(type, acceptsVoid)` and
/// tests whether the *result* is `never`, so ANY void member is enough, not
/// every one. `Promise`'s executor takes
/// `(value: T | PromiseLike<T>) => void`, which at `T = void` is
/// `void | PromiseLike<void>`: requiring every member to be void made
/// `new Promise<void>((resolve) => … resolve())` report TS2554.
pub fn paramAcceptsVoid(c: *Checker, ty: TypeId) Error!bool {
    if (ty == types.void_type) return true;
    const r = try c.resolveStructural(ty);
    if (r == types.void_type) return true;
    if (c.ts.kind(r) == .union_type) {
        for (try c.memberList(r)) |m| {
            if (try c.paramAcceptsVoid(m)) return true;
        }
    }
    return false;
}

// =====================================================================
// diagnostic-emitting assignment check (2322 / 2739 / 2741 / 2353)
// =====================================================================

/// Check `source` (the type of `expr_node`, which may be 0) against
/// `target`, reporting at `span`. Returns true when assignable.
pub fn checkAssignable(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
    // Anchor any TS2589 raised while expanding either side (instantiation
    // limit) at the assignment site.
    c.inst_anchor = .{ .span = .{ .file = c.cur_file, .span = span } };
    if (try c.isAssignable(src_t, target)) {
        // Excess property check for fresh object literals.
        if (expr_node != 0) {
            // tsc's order: the whole-union excess check first (a reported
            // TS2353 ends the relation), then the per-constituent one.
            const before = c.diags.items.len;
            try c.excessPropertyCheck(expr_node, src_t, target);
            if (c.diags.items.len == before and
                try c.freshLiteralUnionMismatch(expr_node, src_t, target, 2322, span)) return false;
        }
        return true;
    }
    // tsc elaborates object/array literal mismatches per member.
    if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
        return false;
    }
    try c.reportNotAssignable(2322, src_t, target, span);
    return false;
}

/// `expr satisfies T`: same relation as `checkAssignable`, but a
/// top-level failure is reported as TS1360 ("does not satisfy the
/// expected type") rather than TS2322/2741. Nested member mismatches
/// and excess properties elaborate exactly like an assignment.
pub fn checkSatisfies(c: *Checker, src_t: TypeId, target: TypeId, expr_node: Node, span: Span) Error!bool {
    if (try c.isAssignable(src_t, target)) {
        if (expr_node != 0) try c.excessPropertyCheck(expr_node, src_t, target);
        return true;
    }
    if (expr_node != 0 and try c.elaborateLiteralError(expr_node, src_t, target)) {
        return false;
    }
    // TS7 surfaces the specific missing-property error (TS2741/2739) in
    // place of the TS1360 wrapper when the operand is an object missing
    // required members; a primitive/non-object mismatch still gets TS1360.
    if (try c.tryReportMissingProps(src_t, target, span)) return false;
    try c.diagFmt(1360, span, "Type '{s}' does not satisfy the expected type '{s}'.", .{
        try c.typeToString(src_t), try c.typeToString(target),
    });
    return false;
}

/// Element/property-wise TS2322 elaboration for fresh literals (what
/// tsc reports instead of one top-level error). Returns true when at
/// least one narrower diagnostic was emitted.
pub fn elaborateLiteralError(c: *Checker, expr_node0: Node, src_t: TypeId, target: TypeId) Error!bool {
    var expr_node = expr_node0;
    while (c.nodeTag(expr_node) == .paren_expr) expr_node = c.tree.nodeData(expr_node).lhs;
    const rt = try c.resolveStructural(target);
    // tsc's `getBestMatchIndexedAccessTypeOrUndefined`: an element/property
    // of a UNION target is first looked up on the union ITSELF, and only
    // when the union has no such member is the lookup redirected to the
    // single best-matching constituent (`getBestMatchingType`). That
    // two-step is what lets `BlobPart[] | undefined` elaborate as
    // `BlobPart[]` and `RequestInit | undefined` as `RequestInit`, while
    // `{ type: 'a'; … } | { type: 'b'; … }` — where the union does answer
    // `.type` — keeps elaborating against `'a' | 'b'` and so stays silent.
    // Without it a union target bailed out entirely and the whole literal
    // was reported at the argument/assignment span.
    const is_union = c.ts.kind(rt) == .union_type;
    // The best-matching constituent, resolved once; `no_type` when the
    // union has none (then only whole-union lookups can contribute).
    const alt: TypeId = if (!is_union) types.no_type else blk: {
        const b = (try c.bestMatchingUnionMember(src_t, rt)) orelse break :blk types.no_type;
        break :blk try c.resolveStructural(b);
    };
    switch (c.nodeTag(expr_node)) {
        .array_literal => {
            const rtk = c.ts.kind(rt);
            if (rtk != .array and rtk != .tuple and !is_union) return false;
            var reported = false;
            var i: u32 = 0;
            for (c.tree.nodeRange(expr_node)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted or c.nodeTag(el) == .spread_element) continue;
                // A re-check of this same literal must still answer
                // "elaborated" (see `diagAlreadyFiled`).
                if (c.diagAlreadyFiled(2322, c.nodeSpan(el))) {
                    reported = true;
                    continue;
                }
                const tt = if (is_union)
                    ((try c.unionElemTypeAt(rt, i)) orelse (try c.elemTypeAt(alt, i)) orelse continue)
                else if (rtk == .array) c.ts.arrayElem(rt) else (try c.tupleElemTypeAt(rt, i) orelse continue);
                const et = c.nodeType(el) orelse continue;
                if (try c.isAssignable(et, tt)) continue;
                if (!try c.elaborateLiteralError(el, et, tt)) {
                    try c.reportNotAssignable(2322, et, tt, c.nodeSpan(el));
                }
                reported = true;
            }
            return reported;
        },
        .object_literal => {
            if (c.ts.kind(rt) != .object and !is_union) return false;
            var reported = false;
            for (c.tree.nodeRange(expr_node)) |prop| {
                if (prop == null_node) continue;
                const pd = c.tree.nodeData(prop);
                const tag = c.nodeTag(prop);
                if (tag != .object_property and tag != .object_shorthand) continue;
                if (tag == .object_property and pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                // A re-check of this same literal must still answer
                // "elaborated" (see `diagAlreadyFiled`). The anchor is the
                // property NAME, which is where this arm reports.
                if (c.diagAlreadyFiled(2322, c.tokSpan(c.tree.nodeMainToken(prop)))) {
                    reported = true;
                    continue;
                }
                const key = try c.memberAtom(c.tree.nodeMainToken(prop));
                const tp_ty = if (is_union)
                    (if (try c.propOfType(rt, key)) |p|
                        p.ty
                    else if (alt != types.no_type and c.ts.kind(alt) == .object)
                        ((c.ts.objectPropByName(alt, key) orelse continue).ty)
                    else
                        continue)
                else
                    (c.ts.objectPropByName(rt, key) orelse continue).ty;
                const value_node = if (tag == .object_property) pd.rhs else pd.lhs;
                const vt = c.nodeType(value_node) orelse continue;
                if (try c.isAssignable(vt, tp_ty)) continue;
                if (!try c.elaborateLiteralError(value_node, vt, tp_ty)) {
                    // tsc anchors an object-literal member mismatch at the
                    // property NAME (for shorthand the name IS the value), not
                    // the value expression.
                    try c.reportNotAssignable(2322, vt, tp_ty, c.tokSpan(c.tree.nodeMainToken(prop)));
                }
                reported = true;
            }
            return reported;
        },
        else => return false,
    }
}

/// A FRESH object literal against a UNION target that `isAssignable`
/// accepted, but tsc does not.
///
/// tsc's excess-property check is not a separate pass: `hasExcessProperties`
/// runs at the top of every `isRelatedTo`, so when `typeRelatedToSomeType`
/// walks a union constituent-by-constituent it re-runs the check against
/// EACH constituent. A constituent that does not know one of the literal's
/// own properties therefore cannot satisfy the relation even though the
/// whole-union check (`excessPropertyCheck` here, which asks whether ANY
/// constituent knows the property) is happy. `crypto.subtle.decrypt`'s
/// `AlgorithmIdentifier | … | AesGcmParams` is the shape: `{ name, iv }`
/// relates structurally to the bare `Algorithm` arm, but `iv` is unknown
/// there, and the only arm that knows `iv` rejects its type — so tsc
/// reports and ztsc was silent.
///
/// Reports (elaborated when possible) and returns true in exactly that
/// case. Purely additive: it never suppresses an accepted relation that
/// some constituent genuinely satisfies.
pub fn freshLiteralUnionMismatch(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId, code: u16, span: Span) Error!bool {
    var node = expr_node;
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) != .union_type) return false;
    const ms = try c.memberList(rt);
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        if (!try c.literalPropsKnownIn(node, rm)) continue;
        if (try c.isAssignable(src_t, m)) return false;
    }
    // A source whose DISCRIMINANT is a union legitimately matches no single
    // constituent — it spans several (tsc `typeRelatedToDiscriminatedType`),
    // and tsc's excess-property check is about property NAMES being known,
    // not about fitting one constituent whole.
    if (try c.discriminatedUnionAssignable(src_t, rt)) return false;
    if (try c.elaborateLiteralError(node, src_t, target)) return true;
    try c.reportNotAssignable(code, src_t, target, span);
    return true;
}

/// Every property WRITTEN in the object literal `node` is known in `rm`
/// (tsc's `isKnownProperty` over one union constituent, with the same
/// `isEmptyObjectType` / index-signature escapes `excessPropertyCheck`
/// applies to a non-union target).
pub fn literalPropsKnownIn(c: *Checker, node: Node, rm: TypeId) Error!bool {
    switch (c.ts.kind(rm)) {
        .object => {
            if (c.ts.objectStringIndex(rm) != 0 or c.ts.objectNumberIndex(rm) != 0) return true;
            if (c.isEmptyObjectType(rm)) return true;
        },
        .intersection => {},
        // A non-object constituent is never excess-checked (a fresh object
        // literal that reaches one is already assignable to it).
        else => return true,
    }
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        if (tag == .object_property) {
            const pd = c.tree.nodeData(prop);
            if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        }
        const key = try c.memberAtom(c.tree.nodeMainToken(prop));
        if (!try c.targetKnowsProp(rm, key)) return false;
    }
    return true;
}

/// The type an array literal's element `i` is checked against when the
/// target is `t` — tsc's `getIndexedAccessTypeOrUndefined(t, i)` restricted
/// to a numeric index. Null when `t` has no numeric element at all (the
/// caller then redirects to the best-matching union constituent).
pub fn elemTypeAt(c: *Checker, t: TypeId, i: u32) Error!?TypeId {
    if (t == types.no_type) return null;
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        .array => c.ts.arrayElem(r),
        .tuple => try c.tupleElemTypeAt(r, i),
        // A string is indexable by number through `String`'s numeric index
        // signature (`("a" | "b" | ("a" | "b")[])[0]` is `string`, which is
        // exactly why tsc does NOT elaborate that union element-wise).
        .string, .string_literal, .template_literal_type => types.string_type,
        .any, .err, .unknown => r,
        else => null,
    };
}

/// `elemTypeAt` over a union: the union of every constituent's element
/// type, and null as soon as ONE constituent has none — matching tsc,
/// where `getIndexedAccessTypeOrUndefined` on a union needs the index to
/// resolve in every constituent.
pub fn unionElemTypeAt(c: *Checker, ut: TypeId, i: u32) Error!?TypeId {
    const ms = try c.memberList(ut);
    if (ms.len == 0) return null;
    const buf = try c.scratch().alloc(TypeId, ms.len);
    for (ms, 0..) |m, k| buf[k] = (try c.elemTypeAt(m, i)) orelse return null;
    return try c.ts.makeUnion(c.scratch(), buf);
}

/// tsc's `getBestMatchingType`: which constituent of a UNION target an
/// elaboration (and a fresh-literal member relation) is judged against.
/// tsc runs five probes in order; the three that carry the shapes a
/// literal elaboration reaches are mirrored here:
///
///  1. `findMatchingTypeReferenceOrTypeAliasReference` — same generic
///     reference on both sides. The only form that matters for a literal
///     source is `Array`/tuple, so an array/tuple source picks the
///     array/tuple constituent (`Uint8Array[]` vs `BlobPart[] | undefined`).
///  2. `findBestTypeForObjectLiteral` — an object literal against a union
///     that contains an array-like constituent picks a NON-array-like one.
///  3. `findMostOverlappyType` — otherwise the constituent sharing the most
///     property names with the source (`keyof S & keyof T`), ties going to
///     the LAST such constituent (tsc compares with `>=`). A constituent
///     sharing no name at all is never chosen, so `undefined` / `string`
///     arms drop out and `RequestInit` wins.
///
/// Returns null when no constituent matches, which leaves the caller with
/// its whole-union report.
pub fn bestMatchingUnionMember(c: *Checker, src_t: TypeId, ut: TypeId) Error!?TypeId {
    const ms = try c.memberList(ut);
    if (ms.len == 0) return null;
    const rs = try c.resolveStructural(src_t);
    const sk = c.ts.kind(rs);
    // (1) array/tuple source -> the array/tuple constituent.
    if (sk == .array or sk == .tuple) {
        for (ms) |m| {
            const mk = c.ts.kind(try c.resolveStructural(m));
            if (mk == .array or mk == .tuple) return m;
        }
    }
    if (sk != .object) return null;
    // (2) object source, some array-like constituent -> the first that is not.
    var has_array_like = false;
    for (ms) |m| {
        const mk = c.ts.kind(try c.resolveStructural(m));
        if (mk == .array or mk == .tuple) has_array_like = true;
    }
    if (has_array_like) {
        for (ms) |m| {
            const mk = c.ts.kind(try c.resolveStructural(m));
            if (mk != .array and mk != .tuple) return m;
        }
    }
    // (3) most shared property names.
    var best: ?TypeId = null;
    var best_n: u32 = 0;
    const nprops = c.ts.objectPropCount(rs);
    for (ms) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .object and c.ts.kind(rm) != .intersection) continue;
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < nprops) : (i += 1) {
            const name = c.ts.objectProp(rs, i).name;
            if ((try c.propOfType(rm, name)) != null) n += 1;
        }
        if (n > 0 and n >= best_n) {
            best_n = n;
            best = m;
        }
    }
    return best;
}

/// tsc reports contextually-typed callback return mismatches as TS2322
/// at the callback body, not TS2345 on the argument.
pub fn elaborateCallbackError(c: *Checker, arg_node: Node, at: TypeId, pt: TypeId) Error!bool {
    const tag = c.nodeTag(arg_node);
    if (tag != .arrow_fn and tag != .function_expr) return false;
    if (c.ts.kind(at) != .function) return false;
    const rpt = try c.resolveStructural(pt);
    if (c.ts.kind(rpt) != .function) return false;
    if (!try c.callbackParamsCompatible(at, rpt)) return false;
    const s_ret = c.ts.fnReturn(at);
    const t_ret = c.ts.fnReturn(rpt);
    if (t_ret == types.void_type) return false;
    if (try c.isAssignable(s_ret, t_ret)) return false;
    const body = c.tree.nodeData(arg_node).rhs;
    const span = if (body != 0 and c.nodeTag(body) != .block)
        c.nodeSpan(body)
    else
        c.nodeSpan(arg_node);
    try c.reportNotAssignable(2322, s_ret, t_ret, span);
    return true;
}

pub fn callbackParamsCompatible(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (try c.requiredParams(s) > try c.paramTotal(t)) return false;
    const pairs = @min(try c.paramTotal(s), @max(try c.effParamCount(s), try c.effParamCount(t)));
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        const sp = try c.paramTypeAt(s, i) orelse break;
        const tp = try c.paramTypeAt(t, i) orelse break;
        if (!try c.isAssignable(tp, sp) and !try c.isAssignable(sp, tp)) return false;
    }
    return true;
}

/// Missing-property refinement: when `src` is object-y and `target` is an
/// object type with required properties absent from `src`, report the
/// specific missing-property error (TS2741 for one, TS2739 for several) at
/// `span` and return true. Shared by the assignment check (in place of
/// TS2322), `satisfies` (in place of TS1360), and the `this`-receiver check
/// (in place of TS2684): TS7 surfaces this specific error where tsc 5.5
/// emitted the wrapper code.
pub fn tryReportMissingProps(c: *Checker, src_t: TypeId, target: TypeId, span: Span) Error!bool {
    const rs = try c.resolveStructural(src_t);
    const rt = try c.resolveStructural(target);
    if (!isSourceObjecty(c.ts.kind(rs)) or c.ts.kind(rt) != .object) return false;
    var missing: std.ArrayList(Atom) = .empty;
    defer missing.deinit(c.scratch());
    for (0..c.ts.objectPropCount(rt)) |i| {
        const tp = c.ts.objectProp(rt, @intCast(i));
        if (tp.optional()) continue;
        // A source index signature does not supply a named property (see
        // structuralAssignable): keep the missing-property diagnostic in
        // step with the relation so `{ [k: string]: any }` → `Date` reports
        // the missing Date members (TS2740), not a bare TS2322.
        if ((try c.propOfTypeEx(rs, tp.name, false)) == null) {
            try missing.append(c.scratch(), tp.name);
        }
    }
    // Emit the missing names in name-*text* order. They were gathered in
    // the target's stored (atom-sorted) prop order, which varies across
    // --workers/--checkers; text order is content-derived and stable
    // (determinism contract). Names are unique, so the order is total.
    std.mem.sort(Atom, missing.items, c, struct {
        fn less(cc: *Checker, a: Atom, b: Atom) bool {
            return std.mem.order(u8, cc.atomText(a), cc.atomText(b)) == .lt;
        }
    }.less);
    if (missing.items.len == 1) {
        try c.diagFmt(2741, span, "Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{
            c.atomText(missing.items[0]), try c.typeToString(src_t), try c.typeToString(target),
        });
        return true;
    }
    if (missing.items.len > 1) {
        var names: std.Io.Writer.Allocating = .init(c.scratch());
        defer names.deinit();
        for (missing.items, 0..) |m, i| {
            if (i > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
            names.writer.print("{s}", .{c.atomText(m)}) catch return error.OutOfMemory;
        }
        try c.diagFmt(2739, span, "Type '{s}' is missing the following properties from type '{s}': {s}", .{
            try c.typeToString(src_t), try c.typeToString(target), names.written(),
        });
        return true;
    }
    return false;
}

pub fn reportNotAssignable(c: *Checker, code: u16, src_t: TypeId, target: TypeId, span: Span) Error!void {
    // Missing-property refinement (tsc: 2739 / 2741 instead of 2322).
    if (code == 2322) {
        if (try c.tryReportMissingProps(src_t, target, span)) return;
        // Did-you-mean morph (tsc: TS2820): a string-literal source rejected
        // by a union of string literals with a close member. tsc's
        // getSuggestedTypeForNonexistentStringLiteralType.
        if (try c.stringLiteralSuggestion(src_t, target)) |sugg| {
            try c.diagFmt(2820, span, "Type '{s}' is not assignable to type '{s}'. Did you mean '\"{s}\"'?", .{
                try c.typeToString(src_t), try c.typeToString(target), c.atomText(sugg),
            });
            return;
        }
    }
    const msg_fmt = "Type '{s}' is not assignable to type '{s}'.";
    if (code == 2345) {
        try c.diagFmt(2345, span, "Argument of type '{s}' is not assignable to parameter of type '{s}'.", .{
            try c.typeToString(src_t), try c.typeToString(target),
        });
    } else {
        try c.diagFmt(code, span, msg_fmt, .{ try c.typeToString(src_t), try c.typeToString(target) });
    }
}

/// tsc's getSuggestedTypeForNonexistentStringLiteralType: when a string
/// literal is rejected by a union, suggest the closest string-literal member
/// (drives the TS2322 -> TS2820 morph). Returns the suggested member's value
/// atom, or null when the source is not a string literal, the target is not
/// a union of string literals, or nothing is close enough.
pub fn stringLiteralSuggestion(c: *Checker, src_t: TypeId, target: TypeId) Error!?Atom {
    const rs = try c.resolveStructural(src_t);
    if (c.ts.kind(rs) != .string_literal) return null;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) != .union_type) return null;
    var cand_atoms: std.ArrayList(Atom) = .empty;
    defer cand_atoms.deinit(c.scratch());
    var cand_names: std.ArrayList([]const u8) = .empty;
    defer cand_names.deinit(c.scratch());
    for (try c.memberList(rt)) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .string_literal) continue;
        const a = c.ts.literalAtom(rm);
        try cand_atoms.append(c.scratch(), a);
        try cand_names.append(c.scratch(), c.atomText(a));
    }
    if (cand_names.items.len == 0) return null;
    const name = c.atomText(c.ts.literalAtom(rs));
    const idx = intern.spellingSuggestion(c.scratch(), name, cand_names.items) orelse return null;
    return cand_atoms.items[idx];
}

pub fn isSourceObjecty(k: types.Kind) bool {
    return k == .object or k == .intersection;
}

/// tsc's excess property check: only *fresh* object literals, checked
/// against object-ish targets; recurses into nested literal properties.
pub fn excessPropertyCheck(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!void {
    _ = try c.excessPropertyScan(expr_node, src_t, target, true);
}

/// The excess-property check, with the diagnostic made optional: returns
/// whether the fresh literal `expr_node` carries a property `target` does
/// not know. `report = false` is the silent form overload probing needs
/// (`freshLiteralRejects`) — tsc folds this test into the assignability
/// relation itself (`hasExcessProperties` inside `isRelatedTo`), so a
/// candidate signature that only "fits" by ignoring an excess property is
/// not applicable there either.
pub fn excessPropertyScan(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId, report: bool) Error!bool {
    var node = expr_node;
    // Unwrap parens and a JSX expression container (`prop={{ … }}`): the
    // object literal inside a JSX attribute value is fresh and excess-checked
    // exactly like a call argument or assignment RHS.
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    const rt = try c.resolveStructural(target);
    switch (c.ts.kind(rt)) {
        .object => {
            if (c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0) return false;
            // The empty object type `{}` accepts any properties: tsc's
            // `hasExcessProperties` bails on `isEmptyObjectType(target)`
            // (e.g. react-i18next's `values?: {}`). No prop is ever excess.
            if (c.isEmptyObjectType(rt)) return false;
        },
        .union_type => {
            // Check against the union: a property is excess if no
            // object constituent knows it — unless SOME constituent is
            // itself an empty object type. tsc's `isEmptyObjectType` is
            // `some(types, isEmptyObjectType)` over a union, and
            // `hasExcessProperties` bails on it wholesale, so `T | {}`
            // (and `T | object`, and `T | <empty interface>`) accepts any
            // property exactly the way a bare `{}` target does. An empty
            // *index-signature* constituent like `Record<string, never>`
            // is not empty and does not bail — it elaborates instead.
            for (try c.memberList(rt)) |m| {
                if (try c.targetIsEmptyish(m)) return false;
            }
        },
        else => return false,
    }
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        if (tag != .object_property and tag != .object_shorthand and tag != .object_method) continue;
        const key_tok = c.tree.nodeMainToken(prop);
        if (tag == .object_property) {
            const pd = c.tree.nodeData(prop);
            if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        }
        const key = try c.memberAtom(key_tok);
        const known = try c.targetKnowsProp(rt, key);
        if (!known) {
            if (report) {
                try c.diagFmt(2353, c.tokSpan(key_tok), "Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{
                    c.atomText(key), try c.typeToString(target),
                });
            }
            return true; // one excess error per literal, like tsc's early bail
        }
        // Recurse into nested fresh literals.
        if (tag == .object_property) {
            const pd = c.tree.nodeData(prop);
            if (c.nodeTag(pd.rhs) == .object_literal) {
                if (c.nodeType(pd.rhs)) |nested_t| {
                    if (try c.targetPropType(rt, key)) |tp| {
                        if (try c.excessPropertyScan(pd.rhs, nested_t, tp, report)) return true;
                    }
                }
            }
        }
    }
    return false;
}

/// Would a fresh object-literal argument make this candidate signature
/// inapplicable? tsc runs the excess-property check *inside* the
/// assignability relation, and for a UNION target it runs it once per
/// constituent (`typeRelatedToSomeType` recurses with the source still
/// fresh) — so `throttle(fn, ms, { leading: false })` is not applicable to
/// the `ThrottleSettings & { leading: true } | Omit<ThrottleSettings,
/// "leading">` overload: the intersection arm rejects `false` and the
/// `Omit` arm does not know `leading`. ztsc keeps freshness out of
/// `isAssignable` (the relation is memoized on type pairs, and freshness
/// is a property of the *expression*), so overload probing consults this
/// predicate separately. It mirrors exactly what the reporting paths
/// (`excessPropertyCheck` / `freshLiteralUnionMismatch`) would file for
/// the same triple — the candidate is rejected iff the winning candidate
/// would have been diagnosed on this argument.
pub fn freshLiteralRejects(c: *Checker, expr_node: Node, src_t: TypeId, target: TypeId) Error!bool {
    var node = expr_node;
    while (true) {
        switch (c.nodeTag(node)) {
            .paren_expr, .jsx_expr_container => node = c.tree.nodeData(node).lhs,
            else => break,
        }
        if (node == null_node) return false;
    }
    if (c.nodeTag(node) != .object_literal) return false;
    if (!c.ts.objectIsFresh(src_t)) return false;
    const rt = try c.resolveStructural(target);
    if (c.ts.kind(rt) == .union_type) {
        for (try c.memberList(rt)) |m| {
            const rm = try c.resolveStructural(m);
            if (!try c.literalPropsKnownIn(node, rm)) continue;
            if (try c.isAssignable(src_t, m)) return false;
        }
        return !try c.discriminatedUnionAssignable(src_t, rt);
    }
    return try c.excessPropertyScan(node, src_t, target, false);
}

/// tsc's `isEmptyObjectType` as `hasExcessProperties` consults it: an
/// empty object literal type, the `object` keyword (`TypeFlags.NonPrimitive`
/// is unconditionally empty there), or a union with any such constituent.
pub fn targetIsEmptyish(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        .object => c.isEmptyObjectType(r),
        .object_keyword => true,
        .union_type => blk: {
            for (try c.memberList(r)) |m| {
                if (try c.targetIsEmptyish(m)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn targetKnowsProp(c: *Checker, rt: TypeId, key: Atom) Error!bool {
    switch (c.ts.kind(rt)) {
        .union_type => {
            for (try c.memberList(rt)) |m| {
                if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
            }
            return false;
        },
        .object => {
            if (c.ts.objectPropByName(rt, key) != null) return true;
            return c.ts.objectStringIndex(rt) != 0 or c.ts.objectNumberIndex(rt) != 0;
        },
        .intersection => {
            for (try c.memberList(rt)) |m| {
                if (try c.targetKnowsProp(try c.resolveStructural(m), key)) return true;
            }
            return false;
        },
        .any, .err, .unknown => return true,
        else => return true, // non-object targets: not our business here
    }
}

pub fn targetPropType(c: *Checker, rt: TypeId, key: Atom) Error!?TypeId {
    if (try c.propOfType(rt, key)) |p| return p.ty;
    return null;
}
