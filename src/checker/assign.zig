//! Structural assignability: the RELATION. Given two types, is the first
//! assignable to the second? Answered as a bare `bool`, memoized on the type
//! pair, allocating nothing on the success path — which is what lets it be
//! asked millions of times per run.
//!
//! It files no diagnostic and builds no message. Reporting an assignment
//! failure is `assign_report.zig`, which reconstructs the story afterwards by
//! re-walking the pair that already answered NO (`elaborate.zig`); variance,
//! declared and measured, is `variance.zig`. Both are re-exported at the
//! bottom of this file, so `Checker`'s method aliases and other modules'
//! imports resolve here regardless of which file a function lives in.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_relation_depth = checker_zig.max_relation_depth;

const TpMap = @import("enums.zig").TpMap;
const this_apparent = @import("enums.zig").this_apparent;
const baseConstraintOf = @import("expr.zig").baseConstraintOf;
const enumAssignable = @import("enums.zig").enumAssignable;
const instantiate = @import("enums.zig").instantiate;
const isEmptyObjectType = @import("instantiate.zig").isEmptyObjectType;
const originTaggable = @import("instantiate.zig").originTaggable;
const propOfType = @import("props.zig").propOfType;
const lazy_zig = @import("instantiate.zig");
const resolveStructural = @import("instantiate.zig").resolveStructural;
const restUnionOptionalAt = @import("typenode.zig").restUnionOptionalAt;
const sliceTuple = @import("typenode.zig").sliceTuple;
const generics_zig = @import("generics.zig");
const simplifyIndexAccess = @import("mapped.zig").simplifyIndexAccess;
const simplifyMappedIndexAccessRead = @import("mapped.zig").simplifyMappedIndexAccessRead;
const infer_zig = @import("infer.zig");
const tuple_zig = @import("tuple_relate.zig");
const variance_zig = @import("variance.zig");
const report_zig = @import("assign_report.zig");
const nominal_members = @import("nominal_members.zig");
const template_zig = @import("template.zig");

// =====================================================================
// assignability
// =====================================================================

/// tsc's `relationCount` budget: how many memo-missing structural comparisons
/// ONE top-level relation query may spend before the checker gives up on it
/// and reports TS2859 ("Excessive complexity comparing types …") instead of an
/// answer.
///
/// This exists because assignability over unions is multiplicative and tsc's
/// own guards — the depth cap, the growing-instantiation test, the pair memo —
/// are all about TERMINATION, not about cost. A query can terminate and still
/// be hopeless: `('0'|…|'7')⁴ & ({a:string}|{b:number})` against the same
/// 4096-member union plus `null` is finite, decidable, and takes seconds. tsc
/// stops counting and reports; without this ztsc answered it, correctly, after
/// 4.4 seconds (`compiler/relationComplexityError.ts`, the corpus's only
/// >10s case).
///
/// CALIBRATION, not transcription. tsc's constant counts tsc's frames, and its
/// budget additionally shrinks as its relation cache fills — neither number
/// means anything against a different frame decomposition. What has to match is
/// which PROGRAMS overflow, so the value is measured: it sits far above the
/// most expensive query in the corpus, the conformance suite and both
/// benchmark apps, and far below the one query tsc rejects. `debug_rel_steps`
/// below is the hook that measured it, and re-measures it.
pub const max_relation_steps: u32 = 4_000_000;

/// Calibration hook for `max_relation_steps`: print every top-level relation
/// query costing at least this many steps. 0 disables it, and compiles the
/// print — and the `s0`/`t0` reads feeding it — away entirely.
///
/// The measurement behind the constant above, reproducible by setting this to
/// `50_000` and rebuilding: no query in either benchmark app (excalidraw,
/// social-app) or anywhere in the TypeScript corpus reaches even that, while
/// the shapes tsc gives up on are two orders of magnitude past it.
const debug_rel_steps: u32 = 0;

/// WHICH relation a `relate` walk is answering — tsc's `relation` parameter,
/// which every one of its relation functions carries and which selects both the
/// rule set and the pair cache (`assignableRelation` / `comparableRelation` /
/// `identityRelation`, each with its own `Map`).
///
/// ztsc answered every question with assignability and bolted the comparable
/// relation's leniencies on as retries at the sites that ask for it
/// (`relationalComparable`, `typesHaveOverlap`, `castComparable`). That works
/// for a leniency the OUTERMOST pair needs and cannot work for one a pair two
/// levels down needs, which is where the whole
/// `comparisonOperatorWithNoRelationship*` family lives:
///
/// ```ts
/// declare var a5: { fn(a?: Base): void };
/// declare var b5: { fn(a?: C): void };
/// a5 < b5;   // tsgo: legal
/// ```
///
/// `Base` and `C` are unrelated in both directions, so nothing the outer
/// retry can do makes the pair comparable — but the PARAMETERS are
/// `Base | undefined` and `C | undefined`, and a union SOURCE under the
/// comparable relation only needs SOME constituent related (`undefined` is),
/// so the parameter comparison two frames down succeeds. The flag has to ride
/// the walk.
///
/// Carried on the `Checker` rather than as a parameter for the same reason
/// `rel_assumed` is: a frame's descendants are reached through
/// `isAssignableInner` and through helpers spread over half a dozen files,
/// none of which thread relation state. It is per-frame context that children
/// inherit, saved and restored at the three entry points — the pattern
/// `rel_expanding` and `fn_ctx` already use — and it is folded into the pair
/// memo's key (`relate`), so the two relations never read each other's
/// verdicts.
pub const Relation = enum {
    /// tsc's `assignableRelation`. Every relation question in the checker
    /// except the three comparable entry points below.
    assignable,
    /// tsc's `comparableRelation`: "is there any overlap between these two
    /// types" rather than "does every value of the first fit the second".
    /// Strictly more lenient than assignability, by three documented rules —
    /// a union source distributes EXISTENTIALLY (`someTypeRelatedToType`
    /// where assignability uses `eachTypeRelatedToType`), a generic signature
    /// is ERASED to `any` rather than instantiated in the target's context
    /// (`eraseGenerics = relation === comparableRelation`), and an optional
    /// source property may satisfy a required target one.
    comparable,
};

/// Switch the live relation to `kind` and hand back the one it replaced, for the
/// caller to `defer`-restore. Three entry points need the identical two lines,
/// and a missed restore would silently answer the REST of the program's
/// assignability questions with the lenient rule set — so the pairing is worth
/// naming even though it saves no code.
///
/// `isComparable` is deliberately NOT one of them. It is the narrowing /
/// discriminant / `switch`-case overlap probe as much as a comparable one, and
/// the sites tsc actually reaches through `isTypeComparableTo` are the three
/// below; switching it would loosen every narrowing in the checker at once.
fn enterRelation(c: *Checker, kind: Relation) Relation {
    const saved = c.rel_kind;
    c.rel_kind = kind;
    return saved;
}

pub fn isComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    return (try c.isAssignable(a, b)) or (try c.isAssignable(b, a));
}

/// The domain of tsc's `isSimpleTypeRelatedTo` — the primitives, literals and
/// enums it decides on flags alone. It matters because the comparable relation
/// retries a failed pair REVERSED through that function and nothing else
/// (`isRelatedTo`: `relation === comparableRelation && … isSimpleTypeRelatedTo(
/// target, source, relation) || isSimpleTypeRelatedTo(source, target, …)`), so
/// `number` is comparable to `1` while `{}` is NOT comparable to `{ z }`.
fn simpleRelationKind(k: types.Kind) bool {
    return switch (k) {
        .any,
        .unknown,
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
        // tsc's `StringLike` covers these two as well (`TemplateLiteral` and
        // `StringMapping`), instantiable though they are.
        .template_literal_type,
        .string_mapping,
        => true,
        else => false,
    };
}

/// The relational operators' legality test (`<`, `>`, `<=`, `>=`), which tsc
/// spells `isTypeComparableTo(l, r) || isTypeComparableTo(r, l)`. Mutual
/// assignability answers that for every concrete pair; the one place the
/// *comparable* relation is observably different here is a TYPE PARAMETER:
///
///   * a parameter source is related THROUGH ITS CONSTRAINT, and an
///     unconstrained one (tsc reads its constraint as `unknown`) is
///     comparable to every target — because for the comparable relation
///     `isSimpleTypeRelatedTo` is tried in REVERSE first, and every type is
///     related to `unknown`. So `t < someBoolean` is legal for a bare `T`;
///   * except against ANOTHER type parameter, where tsc carves the leniency
///     back out on purpose ("forbid comparing a type parameter with another
///     type parameter unless one extends the other") by walking the source's
///     constraint chain and requiring a hit. So `t < u` IS an error.
///
/// Oracle-verified against tsgo 7.0.2 on the whole
/// `comparisonOperatorWithNoRelationship*` family: `T < boolean|string|void|
/// {a:string}|any[]|Date|{}|object|T` legal, `T < U` and `T < number|bigint|E`
/// (the numeric screen at the call site) rejected, `V extends U < U` legal.
pub fn relationalComparable(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    // tsc's `isTypeComparableTo` is the COMPARABLE relation, not assignability
    // with patches: the leniencies it needs (`Relation.comparable`) fire
    // wherever the walk reaches them, and the type-parameter rules below are
    // the ones tsc keeps ON TOP of the relation, in
    // `isTypeRelatedTo`/`isSimpleTypeRelatedTo`.
    const saved = enterRelation(c, .comparable);
    defer c.rel_kind = saved;
    return (try comparableOneWay(c, a, b, 0)) or (try comparableOneWay(c, b, a, 0));
}

fn comparableOneWay(c: *Checker, s0: TypeId, t0: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true; // under-report over false-reject, per policy
    const s = try c.resolveStructural(s0);
    if (c.ts.kind(s) != .type_param) return c.isAssignable(s0, t0);
    const t = try c.resolveStructural(t0);
    if (c.ts.kind(t) == .type_param) return constraintChainReaches(c, s, t);
    const con = try c.typeParamConstraint(c.ts.typeParamSymbol(s));
    if (con == types.no_type or con == s or c.ts.kind(con) == .unknown or c.ts.kind(con) == .any) return true;
    return comparableOneWay(c, con, t0, depth + 1);
}

/// tsc's type-parameter-vs-type-parameter carve-out: walk `s`'s constraint
/// chain while it still mentions a parameter and ask assignability at each
/// step. `V extends U` reaches `U`; two siblings reach nothing. The SAME
/// parameter is related to itself before the carve-out is ever consulted
/// (`isTypeRelatedTo`'s `source === target`), which is what keeps `t < t`
/// legal for a bare `T`.
fn constraintChainReaches(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (s == t) return true;
    var cur = s;
    var steps: u32 = 0;
    while (c.ts.kind(cur) == .type_param and steps < 8) : (steps += 1) {
        const con = try c.typeParamConstraint(c.ts.typeParamSymbol(cur));
        if (con == types.no_type or con == cur) return false;
        if (try c.isAssignable(con, t)) return true;
        cur = try c.resolveStructural(con);
    }
    return false;
}

/// tsc's `directlyRelated` pick inside `getNarrowedTypeWorker`, for a TYPE
/// PREDICATE guard (`checkDerived` false):
///
///     t => isTypeStrictSubtypeOf(t, c) ? t : isTypeStrictSubtypeOf(c, t) ? c
///        : isTypeSubtypeOf(t, c) ? t : isTypeSubtypeOf(c, t) ? c : neverType
///
/// "When `t` and `c` are related in both directions we prefer `c`, because that
/// is the asserted type" — but only once the STRICT direction has been tried
/// both ways, which is what keeps a proper subtype constituent winning over the
/// candidate it refines.
///
/// Both of tsc's subtype relations are `infer.covSubtypeOf` here — ztsc has one
/// subtype APPROXIMATION (assignability plus the rules where the subtype
/// relations are strictly stronger: the target's optional properties and index
/// signatures must be present on the source), and it is the same approximation
/// the inference fold needs, so the two share it rather than drifting apart.
/// That rule is the whole of what this pick observes: `{}` is only VACUOUSLY
/// assignable to a `Partial<User>` whose every property is optional, so it is
/// not a subtype of it, while `Partial<User>` IS a subtype of `{}`.
///
/// Called only for a constituent the caller has already found related to the
/// candidate, so the two trailing subtype clauses collapse into "keep `t`":
/// the answer is the candidate exactly when `t` is not a subtype of it and it
/// IS a subtype of `t`.
pub fn narrowedPick(c: *Checker, t: TypeId, cand: TypeId) Error!TypeId {
    if (t == cand) return t;
    if (try c.covSubtypeOf(t, cand)) return t;
    if (try c.covSubtypeOf(cand, t)) return cand;
    return t;
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
    // Same relation as `relationalComparable` — `checkAssertionWorker` asks
    // `isTypeComparableTo(exprType, targetType) || isTypeComparableTo(targetType,
    // exprType)`. The ad-hoc retries below are what the relation itself now
    // covers for a nested pair; they stay because each also encodes a rule tsc
    // applies OUTSIDE the relation (a type parameter read through its
    // constraint, a deferred conditional peeled to its branches).
    const saved = enterRelation(c, .comparable);
    defer c.rel_kind = saved;
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
    return castComparableDir(c, a0, b0, depth, .either);
}

/// Which way a comparable question is asked.
///
/// tsc's comparable relation is a RELATION — one-way, like assignability. The
/// SYMMETRY belongs to the cast site alone: `checkAssertionWorker` asks
/// `isTypeComparableTo(expr, target) || isTypeComparableTo(target, expr)`, and
/// each of those two calls then runs one-way all the way down. Asking a nested
/// PROPERTY both ways accepts casts tsc rejects — `{ x: T1, y: any }` to
/// `{ x: T2 }` is TS2352 in tsgo (`T1` lacks `T2`'s members, and the reverse
/// whole-object direction fails on the absent `y`), but the symmetric property
/// reading found `T2` assignable to `T1` and took that as overlap
/// (`objectTypesIdentityWithPrivates3`).
pub const CompareDir = enum {
    /// The cast site's own question: either direction may carry it.
    either,
    /// Inside one direction of that question: `a` is the relation SOURCE.
    source_first,
};

fn castComparableDir(c: *Checker, a0: TypeId, b0: TypeId, depth: u32, dir: CompareDir) Error!bool {
    if (depth > 8) return true; // under-report over false-reject, per policy
    const a = try c.resolveStructural(a0);
    const b = try c.resolveStructural(b0);
    // Type parameter on either side. tsc's comparable relation treats one
    // ASYMMETRICALLY: a parameter is related through its constraint only where
    // it is the relation's SOURCE, and in TARGET position it relates to
    // nothing but itself (and a parameter whose constraint chain reaches it).
    // `checkAssertionWorker`'s `isTypeComparableTo(expr, target) ||
    // isTypeComparableTo(target, expr)` therefore comes down to "the
    // parameter's CONSTRAINT, as the source, relates to the other operand" —
    // which is exactly `comparableOneWay`, carve-outs included.
    //
    // Swapping the constraint in and then asking the SYMMETRIC question
    // accepted every cast whose operand merely extends the constraint:
    // `<T>b` for `T extends A` and `b: B extends A` is TS2352 in tsgo
    // ("'B' is assignable to the constraint of type 'T', but 'T' could be
    // instantiated with a different subtype of constraint 'A'"), because `A`
    // relates to `A` but not to `B`. Same for `{} as T` under
    // `T extends null | undefined`.
    //
    // Held back from the DEFERRED families below — a `keyof`, an indexed
    // access, a still-generic mapped type or an unresolved conditional next to
    // a type parameter has no member set to decide on, and those arms concede
    // the pair on purpose rather than risk a false rejection.
    if ((c.ts.kind(a) == .type_param and !deferredCastPeer(c.ts.kind(b))) or
        (c.ts.kind(b) == .type_param and !deferredCastPeer(c.ts.kind(a))))
    {
        if (try comparableOneWay(c, a0, b0, depth)) return true;
        return dir == .either and try comparableOneWay(c, b0, a0, depth);
    }
    // A deferred `keyof T` compares through the key domain. tsc relates an
    // `Index` operand via `keyofConstraintType` — `string | number |
    // symbol` — never through `keyof <constraint>`, and the comparable
    // relation then distributes over that union existentially. Without it
    // the `Object.keys(o).forEach((k) => o[k as keyof T])` idiom reported
    // TS2352: `string` is not assignable *into* `keyof T`, and the
    // whole key union is not assignable to `string`.
    if (c.ts.kind(a) == .keyof_op) return castComparableDir(c, try c.propertyKeyType(), b0, depth + 1, dir);
    if (c.ts.kind(b) == .keyof_op) return castComparableDir(c, a0, try c.propertyKeyType(), depth + 1, dir);
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
    // `result as T[K]` on a numeric record, which tsc accepts, and six
    // more shapes besides (measured 2026-08-02 on indexed/031). The residual under-report is registered against
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
        return (try castComparableDir(c, c.ts.condTrue(a), b0, depth + 1, dir)) or
            (try castComparableDir(c, c.ts.condFalse(a), b0, depth + 1, dir));
    }
    if (c.ts.kind(b) == .conditional) {
        return (try castComparableDir(c, a0, c.ts.condTrue(b), depth + 1, dir)) or
            (try castComparableDir(c, a0, c.ts.condFalse(b), depth + 1, dir));
    }
    // Existential union distribution on either side.
    if (c.ts.kind(a) == .union_type) {
        for (try c.memberList(a)) |m| {
            if (try castComparableDir(c, m, b0, depth + 1, dir)) return true;
        }
        return false;
    }
    if (c.ts.kind(b) == .union_type) {
        for (try c.memberList(b)) |m| {
            if (try castComparableDir(c, a0, m, depth + 1, dir)) return true;
        }
        return false;
    }
    if (try c.isAssignable(a0, b0)) return true;
    // The reverse probe. At the cast site it is the OTHER half of
    // `checkAssertionWorker`'s two calls; one level down it is tsc's
    // `isRelatedTo`, which under the comparable relation retries the pair
    // reversed through `isSimpleTypeRelatedTo` ALONE — primitives, literals and
    // enums, never an object shape. `{ a: number }` stays castable to
    // `{ a: 1 }`; `{ x: {} }` stops being castable to `{ x: { z } }` just
    // because `{ z }` fits `{}`.
    if (dir == .either or (simpleRelationKind(c.ts.kind(a)) and simpleRelationKind(c.ts.kind(b)))) {
        if (try c.isAssignable(b0, a0)) return true;
    }
    if (try c.stringEnumCastOverlap(a, b)) return true;
    if (try c.lenientOverlap(a0, b0, depth)) return true;
    return dir == .either and try c.lenientOverlap(b0, a0, depth);
}

/// The two string-enum shapes tsc's assertion check accepts and mutual
/// assignability does not. A string enum is NOMINAL — a plain string literal
/// is not assignable into it and it is not assignable to a plain literal — but
/// `checkAssertionWorker` compares the target against the WIDENED source, and
/// widening turns a string literal into `string`, which every string enum is
/// assignable to. Verified against tsgo 7.0.2 in both directions:
///
///   * `str as E` / `"nope" as E` / `"nope" as E.Major` — accepted, whatever
///     the literal is, because the widened source is `string`;
///   * `E.Major as "minor"` — accepted: a single member widens to itself and
///     the plain literal target is comparable to it;
///   * `E as "nope"` — REJECTED: the whole enum is a union of members and no
///     member is that literal (`enumOverlapsStringLiteral` already answers the
///     member-value case, which is what `===` overlap uses);
///   * everything numeric, and enum-to-different-enum, unchanged.
///
/// `a` is the cast's SOURCE and `b` its target — the direction matters here,
/// which is why this sits next to the symmetric `lenientOverlap` rather than
/// inside it.
pub fn stringEnumCastOverlap(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    const s = &c.ts;
    // Source is string-like (but NOT an enum of its own), target is a string
    // enum or one of its members.
    if (s.kind(b) == .enum_type and try c.enumIsStringValued(s.enumSymbol(b))) {
        switch (s.kind(a)) {
            .string, .string_literal, .template_literal_type, .string_mapping => return true,
            else => {},
        }
    }
    // Source is a single string-enum MEMBER, target is a plain string literal.
    if (s.kind(a) == .enum_type and s.isEnumMember(a) and s.kind(b) == .string_literal and
        try c.enumIsStringValued(s.enumSymbol(a))) return true;
    // Source is a WHOLE string enum and the target literal is one of its
    // member values — the same overlap `===` narrowing already uses.
    if (try c.enumOverlapsStringLiteral(a, b)) return true;
    return false;
}

/// The shapes a still-generic mapped type may overlap in the cast test: the
/// object-ish types are the only things a mapped type can ever instantiate to.
///
/// An ARRAY or TUPLE counterpart is one of them. A HOMOMORPHIC mapped type
/// distributes over an array or tuple modifiers type — `{ [P in keyof T]: … }`
/// with `T extends [number] | [string]` instantiates to a TUPLE, never to a
/// plain object — so a mapped type and an array-like are exactly as able to
/// overlap as a mapped type and an object literal, and just as undecidable
/// here while the key constraint is still generic. Without the two kinds,
/// `[] as HomomorphicMappedType<T>` was four false TS2352s
/// (`mappedTypeUnionConstrainTupleTreatedAsArrayLike`), which tsgo accepts —
/// it reports only the TS2322 on the `readonly`-constrained assignment below
/// the cast, i.e. the CAST is fine and the assignment is what fails.
pub fn mappedCastPeer(k: types.Kind) bool {
    return k == .object or k == .intersection or k == .mapped or
        k == .array or k == .tuple;
}

/// The kinds `castComparableRec` concedes outright rather than decide on
/// members: a `keyof`, an indexed access, a still-generic mapped type and an
/// unresolved conditional each stand for a member set that is not known here
/// (see the arms below for the measurements behind each). A type parameter
/// paired with one of them keeps that concession instead of taking the strict
/// constraint rule, which would turn "no verdict available" into a rejection.
fn deferredCastPeer(k: types.Kind) bool {
    return k == .keyof_op or k == .index_access or k == .mapped or k == .conditional;
}

/// One direction of the lenient comparable relation: does source `s0`
/// overlap target `t0` when optional source props may satisfy required
/// target props? Depth-capped at 8 — beyond that it answers `true`
/// (under-report, per policy: a cast that deep is not worth a false
/// rejection).
///
/// Every composite shape needs an arm here, not just the ones that carry
/// optionality. `castComparableRec` peels unions, conditionals and type
/// parameters off its two operands before it ever calls this function, so it
/// is tempting to assume they cannot arrive — but the intersection and
/// object-property arms below RE-ENTER this walk with a constituent or a
/// member type, which can be any shape at all. A shape with no arm falls off
/// the end of the function and answers "no overlap", which fails the whole
/// cast: that is a false positive, the one outcome this file's policy
/// forbids. react-navigation's `TypedNavigator` alone reached three such
/// holes — tuple, conditional and mapped — on a single cast, and all three
/// had to close before that cast stopped reporting.
pub fn lenientOverlap(c: *Checker, s0: TypeId, t0: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true;
    const s = try c.resolveStructural(s0);
    const t = try c.resolveStructural(t0);
    const sk = c.ts.kind(s);
    const tk = c.ts.kind(t);
    if (sk == .array and tk == .array) {
        return c.lenientComparable(c.ts.arrayElem(s), c.ts.arrayElem(t), depth + 1);
    }
    // A tuple overlaps a tuple element by element, exactly as an array does
    // by its element type. Only the arity guards are borrowed from
    // `tupleAssignable` — the elements themselves need only OVERLAP, so a
    // pair that differs in one position the other way round still overlaps.
    // Both react-navigation shapes reach it: `PrivateValueStore<T>`'s whole
    // variance brand is one tuple-typed property (`[ParamList,
    // NavigationList, unknown]`), and `router.matchPath(href) as
    // [keyof ParamList, Params?]` casts a `[string, …]` to a route-name tuple.
    if (sk == .tuple and tk == .tuple) {
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
            const tt = try c.tupleElemTypeAt(t, @intCast(i)) orelse return false;
            if (!try c.lenientComparable(st, tt, depth + 1)) return false;
        }
        return true;
    }
    // `castComparableRec` peels a deferred conditional off both operands
    // before it ever calls here — but the intersection arm below re-enters
    // this function with a CONSTITUENT, and react-navigation's
    // `TypedNavigator` is
    // `(undefined extends Config ? Internal : Static) & PrivateValueStore<…>`,
    // so the constituent handed back IS a conditional. With no arm it fell off
    // the end of the function and answered "no overlap", failing the cast.
    // It distributes existentially, in this direction, exactly as at the top.
    //
    // (A union constituent is the same hole in principle and the same two
    // lines to close, but no case in the corpus reaches it — measured, not
    // assumed — so it is left out rather than added on speculation.)
    if (tk == .conditional) {
        return (try c.lenientOverlap(s0, c.ts.condTrue(t), depth)) or
            (try c.lenientOverlap(s0, c.ts.condFalse(t), depth));
    }
    if (sk == .conditional) {
        return (try c.lenientOverlap(c.ts.condTrue(s), t0, depth)) or
            (try c.lenientOverlap(c.ts.condFalse(s), t0, depth));
    }
    // A still-generic mapped type is conceded against an object-shaped
    // counterpart, the same concession `castComparableRec` already makes and
    // for the same reason: its member set is unknown, so no member-based
    // verdict exists. It reaches here only as an intersection constituent —
    // `Omit<ComponentProps<Nav>, …> & DefaultNavigatorOptions<ParamList, …>`
    // is every react-navigation navigator's prop type — and answering "no
    // overlap" there is the false rejection the concession exists to avoid.
    if ((tk == .mapped and mappedCastPeer(sk)) or (sk == .mapped and mappedCastPeer(tk))) return true;
    // `null` and `undefined` have no members, no signatures and no index of any
    // kind, so they overlap NOTHING object-shaped. tsc never gets as far as
    // asking: its relation settles the pair in `isSimpleTypeRelatedTo`, which
    // relates `null`/`undefined` only to themselves and to `any`/`unknown`
    // under `strictNullChecks`. A NULLABLE target is a union, and
    // `castComparableRec` peeled it before this walk saw it.
    //
    // Without this the walk reached the object arm and conceded twice over: an
    // EMPTY target (`interface I {}`, `{}`, `{ [x: number]: number }`) has no
    // member to fail on, and `Record<string, any>` is waved through by
    // `indexInfoOverlap`'s `any` exemption. All three are TS2352 in tsc —
    // `null as I` is `declarationEmitExpandoPropertyPrivateName`, and
    // `<{[x:number]: number}>null` is the last missing key of `parseTypes`.
    if ((sk == .null or sk == .undefined) and isNonPrimitiveKind(tk)) return false;
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
    // tsc's comparable relation is a RELATION: it is threaded through
    // `signatureRelatedTo` exactly like assignability, so its two laxnesses
    // (a union source needs only SOME constituent related; an optional source
    // property satisfies a required target one) apply inside a signature's
    // parameters and return type as well as at the top. ztsc's walk stopped
    // at the first signature it met and answered "no overlap", so a union
    // that a *property* position resolves (`{g: A|B} as {g: C|D}`) was a
    // spurious TS2352 one step deeper (`{g: () => A|B} as {g: () => C|D}`).
    // react-navigation's `TypedNavigator` is exactly that shape: the two
    // navigator types differ only in their ParamList, and the constituent
    // that overlaps — `FunctionComponent`, contravariant in its props — sits
    // under `getComponent`'s return type.
    // A CALLABLE OBJECT reaches a function target through its call
    // signatures, exactly as `isAssignable`'s own `.function` target arm
    // does — `memo(forwardRef(ListImpl)) as <ItemT>(props: …) => ReactElement`
    // casts a `NamedExoticComponent` (a call signature plus `$$typeof`) to a
    // bare generic function type, and only this direction can succeed: the
    // reverse fails on the `$$typeof` the function does not have.
    if (tk == .function) return c.sigListOverlap(s, t, false, depth);
    if (tk == .object) {
        for (0..c.ts.objectPropCount(t)) |i| {
            const tp = c.ts.objectProp(t, @intCast(i));
            // `relationSrcProp` (unlike `objectPropByName`) reaches through a
            // source intersection / ref, so the winning direction — where the
            // intersection being cast to is the relation *source* — resolves
            // each target member. Optional target props may be absent (the
            // optional→required leniency); present props need only be
            // comparable (either direction).
            //
            // It is the RELATION's lookup and not the member-access one for
            // the reason it exists: a string INDEX SIGNATURE does not answer a
            // named property. `{ [k: string]: number } as { foo: string }` is
            // TS2352 in tsgo, and the plain lookup handed this walk a synthetic
            // `foo: number` — comparable to `string` neither way, so that one
            // still failed, but `{ [k: string]: unknown }` handed it `unknown`,
            // which overlaps everything. That is the same distinction
            // `structuralAssignable` already draws one relation over.
            const sp = (try relationSrcProp(c, s, tp.name)) orelse {
                if (tp.optional()) continue;
                return false; // required target member absent from source
            };
            // An OPTIONAL property's type INCLUDES `undefined` — tsc's
            // `getTypeOfSymbol` under `strictNullChecks`, and the same two
            // lines the assignable walk runs (`structuralAssignable`). Without
            // them this walk judged the pair on stricter terms than the
            // relation that sent it here, and a source property that is only
            // ever absent (`strokeColor?: undefined`, which is what the
            // shared-widening-context rule writes onto an object literal whose
            // SIBLINGS declare the name) overlapped no optional target
            // property at all. excalidraw's `elements as
            // ExcalidrawElementSkeleton[]` is that cast.
            var st = sp.ty;
            if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
            var tt = tp.ty;
            if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
            // ONE-WAY, in this walk's own direction: `s` is the relation
            // source here, so its property is the source property. See
            // `CompareDir` — the other whole-object direction is a separate
            // `lenientOverlap(t, s)` call at the cast site, not a second
            // reading of each property.
            if (!try castComparableDir(c, st, tt, depth + 1, .source_first)) return false;
        }
        // A callable/constructable target is decided on its signatures too,
        // not on its (often empty) property table: `{ new (p: A): X }` and
        // `{ new (p: B): Y }` have no properties at all, so the property walk
        // alone answered "overlap" for every pair of construct-signature
        // types. tsc's `signaturesRelatedTo` requires each target signature
        // to be met by SOME source signature; a target that asks for a
        // signature the source cannot supply does not overlap.
        if (!try c.sigListOverlap(s, t, false, depth)) return false;
        if (!try c.sigListOverlap(s, t, true, depth)) return false;
        return indexInfoOverlap(c, s, t, depth);
    }
    return false; // non-object shapes: the isComparable probes already ruled
}

/// tsc's `typeRelatedToIndexInfo` under the COMPARABLE relation — the target's
/// STRING index signature, which this walk used to ignore entirely, so
/// `Record<string, unknown>` (no named members at all) was overlapped by every
/// object in the language.
///
/// ```ts
/// function typeRelatedToIndexInfo(source, targetInfo, …) {
///     const sourceInfo = getApplicableIndexInfo(source, targetInfo.keyType);
///     if (sourceInfo) return indexInfoRelatedTo(sourceInfo, targetInfo, …);
///     if (… isObjectTypeWithInferableIndex(source)) {
///         return membersRelatedToIndexInfo(source, targetInfo, …);
///     }
///     return Ternary.False;
/// }
/// ```
///
/// `isObjectTypeWithInferableIndex` is the load-bearing half: an object or type
/// literal, an enum or a value module has its members read as an implicit index
/// signature; a CLASS INSTANCE or an INTERFACE does not, and a class merged
/// with a namespace still does not (`!(type.symbol.flags & SymbolFlags.Class)`
/// is a separate conjunct from the ValueModule test). ztsc already carries that
/// bit as `obj_flag_not_inferable`, and the assignable walk already consults it
/// — this is the same rule on the comparable side, and it is the whole of
/// `mergedClassNamespaceRecordCast`: `new C1() as Record<string, unknown>` and
/// `new C2() as Record<string, unknown>` are TS2352 while `C3 as Record<string,
/// unknown>` (a bare namespace) is not.
///
/// The `any`-valued exemption is the one from `indexSignaturesRelatedTo` and is
/// what keeps `x as Record<string, any>` the escape hatch it is in practice; it
/// is spelled the same way it is on the assignable side, and `unknown` does not
/// get it.
///
/// NUMBER index signatures are deliberately not asked about. The assignable
/// walk needs them because a target may be spelled `{ [x: number]: T }` alone;
/// the shapes this walk exists for reach it through a cast, and no corpus or
/// app case needs the numeric half — adding it on speculation would only widen
/// the surface of a rule whose whole risk is false REJECTION.
fn indexInfoOverlap(c: *Checker, s: TypeId, t: TypeId, depth: u32) Error!bool {
    const sidx = c.ts.objectStringIndex(t);
    if (sidx == 0) return true;
    if (isNonPrimitiveKind(c.ts.kind(s)) and
        c.ts.kind(try c.resolveStructural(sidx)) == .any) return true;
    // Only an object side can be judged on members; everything else keeps the
    // walk's standing concession (see `lenientOverlap`'s doc comment: a shape
    // with no verdict must not answer "no overlap").
    if (c.ts.kind(s) != .object) return true;
    if (c.ts.objectStringIndex(s) != 0) {
        return c.lenientComparable(c.ts.objectStringIndex(s), sidx, depth + 1);
    }
    if (!c.ts.objectHasImpliedIndex(s)) return false; // interface / class instance
    for (0..c.ts.objectPropCount(s)) |i| {
        const sp = c.ts.objectProp(s, @intCast(i));
        if (!try c.lenientComparable(sp.ty, sidx, depth + 1)) return false;
    }
    return true;
}

/// How many call (or construct) signatures a type offers the overlap walk.
/// A bare `.function` type is its own single call signature.
fn overlapSigCount(c: *Checker, t: TypeId, is_construct: bool) u32 {
    return switch (c.ts.kind(t)) {
        .function => if (is_construct) 0 else 1,
        .object => if (is_construct) c.ts.objectConstructSigCount(t) else c.ts.objectCallSigCount(t),
        else => 0,
    };
}

fn overlapSigAt(c: *Checker, t: TypeId, is_construct: bool, i: u32) TypeId {
    if (c.ts.kind(t) == .function) return t;
    return if (is_construct) c.ts.objectConstructSig(t, i) else c.ts.objectCallSig(t, i);
}

/// tsc's `signaturesRelatedTo` under the comparable relation: every target
/// signature must overlap SOME source signature. A target with no signatures
/// of this kind demands nothing.
pub fn sigListOverlap(c: *Checker, s0: TypeId, t0: TypeId, is_construct: bool, depth: u32) Error!bool {
    // A class value's construct signatures are nominal shortcuts, not stored
    // on an object table — materialize them here exactly as
    // `sourceSatisfiesSigs` does for assignability, or `typeof C` offers the
    // overlap walk no constructor at all and every `x === SomeClass` against
    // a `{ new (…): …ic }`-typed operand reads as a non-overlapping TS2367.
    const s = if (is_construct and c.ts.kind(s0) == .class_value)
        try c.classConstructType(c.ts.classSymbol(s0))
    else
        s0;
    const t = if (is_construct and c.ts.kind(t0) == .class_value)
        try c.classConstructType(c.ts.classSymbol(t0))
    else
        t0;
    const t_count = overlapSigCount(c, t, is_construct);
    if (t_count == 0) return true;
    const s_count = overlapSigCount(c, s, is_construct);
    if (s_count == 0) return false;
    var ti: u32 = 0;
    while (ti < t_count) : (ti += 1) {
        const t_sig = overlapSigAt(c, t, is_construct, ti);
        var matched = false;
        var si: u32 = 0;
        while (si < s_count) : (si += 1) {
            if (try c.sigOverlap(overlapSigAt(c, s, is_construct, si), t_sig, depth)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

/// Two signatures overlap when their arities are compatible and every paired
/// parameter and the return type overlap. Parameters are compared with the
/// same symmetric overlap test as everything else, which is tsc's *bivariant*
/// parameter comparison — the comparable relation never gets to reject a cast
/// on parameter variance alone. A `void` target return accepts any source
/// return, exactly as in the assignability path.
pub fn sigOverlap(c: *Checker, s: TypeId, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return true;
    if (c.ts.kind(s) != .function or c.ts.kind(t) != .function) return false;
    // tsc's `compareSignaturesRelated` arity guard: a source that demands
    // more arguments than the target can ever supply is not related.
    if (try c.requiredParams(s) > try c.paramTotal(t)) return false;
    const pairs = @min(try c.paramTotal(s), try c.paramTotal(t));
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        const sp = try c.paramTypeAt(s, i) orelse break;
        const tp = try c.paramTypeAt(t, i) orelse break;
        if (!try c.lenientComparable(sp, tp, depth + 1)) return false;
    }
    const t_ret = c.ts.fnReturn(t);
    if (t_ret == types.void_type) return true;
    return c.lenientComparable(c.ts.fnReturn(s), t_ret, depth + 1);
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
    // The third comparable entry point, and the same relation as the other two:
    // tsc's equality operators ask
    // `isTypeEqualityComparableTo(left, right) || isTypeEqualityComparableTo(right, left)`,
    // whose body is `target.flags & Nullable || isTypeComparableTo(source, target)`.
    // Without the relation kind the `==`/`===` half of every
    // `comparisonOperator…` case stayed a false TS2367 while its `<`/`>` half
    // (`relationalComparable`) had already been fixed — sixteen keys per case,
    // the exact same pairs.
    const saved = enterRelation(c, .comparable);
    defer c.rel_kind = saved;
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
    //
    // …with the carve-out tsc puts back on purpose, and which the RELATIONAL
    // operators already had (`constraintChainReaches`): "forbid comparing a
    // type parameter with another type parameter unless one extends the
    // other". The leniency above exists because a parameter COULD be
    // instantiated to the other operand's type; when both sides are
    // parameters that reasoning is available to each of them and tsc declines
    // it, so `t === u` over `<T, U>` is a TS2367 in tsgo while `t < u` already
    // was one in ztsc. Sixteen keys in `comparisonOperatorWithTypeParameter`
    // and four in `…NoRelationshipTypeParameter` were exactly that asymmetry.
    const tpa = try c.resolveStructural(a);
    const tpb = try c.resolveStructural(b);
    if (c.ts.kind(tpa) == .type_param and c.ts.kind(tpb) == .type_param) {
        return (try constraintChainReaches(c, tpa, tpb)) or (try constraintChainReaches(c, tpb, tpa));
    }
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
    // A CLASS VALUE reaches the comparable relation through its
    // CONSTRUCTORS, which the mutual-assignability probe above cannot use:
    // tsc threads the comparable relation through `signatureRelatedTo`, so a
    // construct signature's parameters compare bivariantly and its return
    // distributes existentially over a union target. `typeof SimpleImage`
    // therefore overlaps `{ new (…args: any[]): Extension<any> | Mark<any> |
    // Node<any> }` even though it is not ASSIGNABLE to it — outline's
    // `inlineExtensions.filter((n) => n !== SimpleImage)`, where every
    // element is that constructor type. `castComparableRec` is ztsc's
    // rendering of the same relation (it is what TS2352 already asks), and
    // the fallback is scoped to the shape that needs it rather than
    // re-deciding every TS2367 on the looser relation.
    if (ka == .class_value or kb == .class_value) {
        if (try c.castComparableRec(a, b, depth)) return true;
    }
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
    // Two instantiations of ONE generic — tsc's `relateVariances`, which
    // pairs the type arguments instead of walking the members. Here it is the
    // step that lets the type-parameter leniency above reach an argument
    // POSITION: `switch (key)` on a `ClassConstructor<T>` with a
    // `case LoggingRepository as ClassConstructor<LoggingRepository>` asks
    // whether `ClassConstructor<LoggingRepository>` overlaps
    // `ClassConstructor<T>`, and neither direction is assignable because `T`
    // is a bare unconstrained parameter buried one layer down. The
    // constituents `T` could be instantiated to include the other argument,
    // so the pair overlaps — the same reasoning `typeParamOverlapOperand`
    // already applies at the top level (immich `test/medium.factory.ts:493`).
    //
    // Argument-wise rather than blanket: `Box<T>` against a `number` still
    // has no overlap, and `Box<"a" | "b">` against `Box<"z">` still has none,
    // because each pair is asked recursively.
    if (try sameGenericArgs(c, a, b)) |pairs| {
        defer c.scratch().free(pairs);
        for (pairs) |p| {
            if (!try c.typesHaveOverlapRec(p[0], p[1], depth + 1)) return false;
        }
        return pairs.len > 0;
    }
    return false;
}

/// The positionally paired type arguments of two references to the SAME
/// generic symbol, or null when the pair is not that shape. Reads the origin
/// tag as well as a live `.ref`, so an alias that materialized into an object
/// still pairs (the rule `unify`'s `.object` arm already relies on).
fn sameGenericArgs(c: *Checker, a: TypeId, b: TypeId) Error!?[][2]TypeId {
    const s = &c.ts;
    const ra = if (s.kind(a) == .ref) a else (c.origin.get(a) orelse c.origin.get(try c.resolveStructural(a)) orelse return null);
    const rb = if (s.kind(b) == .ref) b else (c.origin.get(b) orelse c.origin.get(try c.resolveStructural(b)) orelse return null);
    if (s.kind(ra) != .ref or s.kind(rb) != .ref) return null;
    if (s.refSymbol(ra) != s.refSymbol(rb)) return null;
    const aa = s.refArgs(ra);
    const ba = s.refArgs(rb);
    const n = @min(aa.len, ba.len);
    if (n == 0) return null;
    const out = try c.scratch().alloc([2]TypeId, n);
    for (0..n) |i| out[i] = .{ aa[i], ba[i] };
    return out;
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

// Variance (declared `in`/`out` + measured) lives in `variance.zig`.
// Re-exported so `Checker`'s method aliases and other modules' imports keep
// resolving through `assign.zig`.
pub const Variance = variance_zig.Variance;
pub const Measured = variance_zig.Measured;
pub const VarianceScan = variance_zig.VarianceScan;
pub const max_variance_measure_depth = variance_zig.max_variance_measure_depth;
pub const declaredVarianceOfTypeParam = variance_zig.declaredVarianceOfTypeParam;
pub const declaredVariances = variance_zig.declaredVariances;
pub const varianceVerdict = variance_zig.varianceVerdict;
pub const measuredVariances = variance_zig.measuredVariances;
pub const measuredVarianceVerdict = variance_zig.measuredVarianceVerdict;
pub const varianceMarkers = variance_zig.varianceMarkers;
pub const isVarianceMarkerRef = variance_zig.isVarianceMarkerRef;
pub const varianceMeasurable = variance_zig.varianceMeasurable;
pub const varianceAnnotationSpan = variance_zig.varianceAnnotationSpan;
pub const reportVarianceMismatch = variance_zig.reportVarianceMismatch;
pub const checkVarianceAnnotations = variance_zig.checkVarianceAnnotations;

/// The generic reference a type denotes: itself when it IS one, otherwise
/// the canonical origin ref of a materialized instantiation (see `origin`).
/// The constraint the RELATION may read off type parameter `tp`, or `no_type`
/// when it may read none.
///
/// The one case where a written constraint is not one is the CIRCULAR one
/// (TS2313): in `<T extends T>`, or `<T extends U, U extends T>`, the chain of
/// bare parameter-to-parameter constraints closes on the parameter it started
/// from, and a parameter constrained by itself says nothing about its values.
/// tsc resolves that chain to its `circularConstraintType` marker, whose
/// apparent type is `unknown` — so `function foo<T extends T>(x: T): number {
/// return x }` is a TS2322 there (`compiler/typeParameterHasSelfAsConstraint`).
///
/// Without the check the relation reads `T`'s constraint as `T`, re-asks its
/// own question, and the in-progress mark answers YES (the co-inductive cycle
/// cut — see `RelAnswer`), so `T` came out assignable to `number`, to
/// `string`, and to everything else. The cut is right for a recursive TYPE,
/// whose members really do close the circle one level down; here there is no
/// second constituent to close it with, so the circle is the whole answer.
///
/// Walks the chain rather than testing `constraint == tp` alone so the mutual
/// form is caught too, and bounds the walk: `typeParamConstraint` breaks its
/// own re-entry with `no_type`, but only for a parameter already being
/// RESOLVED, which a fully-resolved chain read from here is not.
fn relationConstraintOf(c: *Checker, tp: TypeId) Error!TypeId {
    const constraint = try c.typeParamConstraint(c.ts.typeParamSymbol(tp));
    if (constraint == types.no_type) return types.no_type;
    var cur = constraint;
    var steps: u32 = 0;
    while (c.ts.kind(cur) == .type_param and steps < max_tp_constraint_chain) : (steps += 1) {
        if (cur == tp) return types.no_type;
        const next = try c.typeParamConstraint(c.ts.typeParamSymbol(cur));
        if (next == types.no_type) break;
        cur = next;
    }
    return constraint;
}

/// How far `relationConstraintOf` follows a parameter-to-parameter constraint
/// chain looking for the parameter it started from. A written type-parameter
/// list is what bounds the real chains; the constant only keeps a malformed
/// one from spinning.
const max_tp_constraint_chain: u32 = 64;

/// Is `m` one of `union_members` — tsc's `containsType`, and O(log n) for the
/// same reason: a union's constituent list is canonical, so it is sorted by
/// `TypeId` (`Store.makeUnion`) and membership is a binary search rather than
/// a scan. Takes the SLICE, not the union, so it can be hoisted out of a loop
/// over a second type's constituents (`isAssignableInner`'s intersection-source
/// fast path does exactly that).
pub fn unionHasMember(union_members: []const TypeId, m: TypeId) bool {
    return std.sort.binarySearch(TypeId, union_members, m, struct {
        fn cmp(key: TypeId, mid: TypeId) std.math.Order {
            return std.math.order(key, mid);
        }
    }.cmp) != null;
}

pub fn refFacetOf(c: *Checker, ty: TypeId, k: types.Kind) ?TypeId {
    if (k == .ref) return ty;
    if (!originTaggable(k)) return null;
    const o = c.origin.get(ty) orelse return null;
    return if (c.ts.kind(o) == .ref) o else null;
}

pub fn isAssignable(c: *Checker, s0: TypeId, t0: TypeId) Error!bool {
    return relateFolded(c, s0, t0, true);
}

/// One relation frame, run for its BOOLEAN only: whether the answer rests on an
/// assumption is folded into the caller's ambient accumulator
/// (`Checker.rel_assumed`) on the way out.
///
/// This is the seam between the two halves of the `Ternary.Maybe` protocol.
/// `relate` RETURNS its provisional-ness (`RelAnswer`), so no frame can answer
/// optimistically without saying so; but a frame's DESCENDANTS are reached
/// through `isAssignableInner` and through helpers spread over several files,
/// none of which thread a verdict, so they still report back through the field.
/// Every path that leaves the returned protocol goes through here, which is
/// what keeps the two halves in step — see `Checker.rel_assumed`.
fn relateFolded(c: *Checker, s0: TypeId, t0: TypeId, memoize: bool) Error!bool {
    const answer = try relate(c, s0, t0, memoize);
    if (answer.assumed()) c.rel_assumed = true;
    return answer.related();
}

/// tsc's `isWeakType`: an object type with at least one property, EVERY
/// property optional, and no call signatures, no construct signatures and no
/// index signatures. An intersection is weak when every constituent is.
///
/// A weak type is one nothing structurally fails to satisfy — `{ a?: X }`
/// accepts `{}`, and so accepts any object at all — which is why TypeScript
/// added a separate rule for it (TS2559 / "has no properties in common with").
/// The rule is what picks the right `fs.watch` overload: the first takes
/// `options?: WatchOptionsWithStringEncoding | …`, whose object constituent is
/// weak, and a `(event, filename) => …` listener passed as the second argument
/// would otherwise land there and leave the callback's parameters
/// uncontextualized (two phantom TS7006 in immich's transcoding service).
pub fn isWeakType(c: *Checker, t0: TypeId) Error!bool {
    if (c.weak_types.get(t0)) |v| return v == 1;
    const answer = try computeIsWeakType(c, t0);
    try c.weak_types.put(c.cm(), t0, @intFromBool(answer));
    return answer;
}

fn computeIsWeakType(c: *Checker, t0: TypeId) Error!bool {
    const k0 = c.ts.kind(t0);
    if (k0 == .intersection) {
        const ms = try c.memberList(t0);
        if (ms.len == 0) return false;
        for (ms) |m| {
            if (!try c.isWeakType(m)) return false;
        }
        return true;
    }
    // Only a materialized object shape can be weak; everything else
    // (primitives, unions, type parameters, deferred operators) is not.
    if (k0 != .object and k0 != .ref) return false;
    // Weakness is a question about member NAMES, FLAGS and COUNTS, and
    // `instantiateId`'s `.object` arm carries all three through unchanged —
    // so an interface/class reference answers it off its generic table
    // without substituting a single member (see `lazyTableOf`). This is the
    // hottest forcing site in the checker: `weakTypeMismatch` runs on every
    // relation frame with an object-ish target, ahead of the memo and the
    // structural walk, and it used to materialize that target's whole table
    // before the walk had asked for anything.
    if (try c.lazyShapeOf(t0)) |generic| {
        // A generic that carries signatures stays eager: `instantiateId` may
        // drop a higher-order one, so a non-zero signature count is not
        // evidence the instantiation has any.
        if (c.ts.objectCallSigCount(generic) == 0 and c.ts.objectConstructSigCount(generic) == 0) {
            const gn = c.ts.objectPropCount(generic);
            if (gn == 0) return false;
            if (c.ts.objectStringIndex(generic) != 0 or c.ts.objectNumberIndex(generic) != 0) return false;
            for (0..gn) |i| {
                if (!c.ts.objectProp(generic, @intCast(i)).optional()) return false;
            }
            return true;
        }
    }
    const t = try c.resolveStructural(t0);
    if (c.ts.kind(t) == .intersection) return c.isWeakType(t);
    if (c.ts.kind(t) != .object) return false;
    const n = c.ts.objectPropCount(t);
    if (n == 0) return false;
    if (c.ts.objectStringIndex(t) != 0 or c.ts.objectNumberIndex(t) != 0) return false;
    if (c.ts.objectCallSigCount(t) != 0 or c.ts.objectConstructSigCount(t) != 0) return false;
    for (0..n) |i| {
        if (!c.ts.objectProp(t, @intCast(i)).optional()) return false;
    }
    return true;
}

/// tsc's `isKnownProperty` for a weak-type target: does `t` declare `name`,
/// or an index signature that would cover it?
///
/// `getPropertyOfObjectType`, so the global `Object`/`Function` members every
/// value apparently carries do NOT count as declared — `ctxPropOfType` is the
/// lookup that skips them. With the ordinary lookup, `toString` (which the
/// apparent `Object` lends the target too) was a property in common with every
/// source that has one, which is every PRIMITIVE source: `doSomething(12)`
/// against a weak `Settings` found `toString` on both sides and passed.
pub fn weakTargetKnows(c: *Checker, t: TypeId, name: Atom) Error!bool {
    if (c.ts.kind(t) == .intersection or c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (try c.weakTargetKnows(m, name)) return true;
        }
        return false;
    }
    return (try c.ctxPropOfType(t, name)) != null;
}

/// tsc's common-property check for a weak target: the source and the target
/// must share at least one property name, otherwise the two are unrelated
/// however vacuously the structural walk would succeed.
///
/// Returns true when the pair must be REJECTED. Gated exactly as tsc gates it
/// (`isPerformingCommonPropertyChecks`): the source is a primitive, an object
/// or an intersection — never a union or a type variable — and carries at
/// least one property or a call/construct signature; the target is an object
/// or intersection and is weak; and the frame is not one of the constituent
/// frames an intersection TARGET decomposes into.
/// Is `s` a callable source, and does the union `t` offer a callable
/// constituent to judge it? See `Checker.union_callable_sibling`.
pub fn unionHasCallableMember(c: *Checker, s: TypeId, sk: types.Kind, t: TypeId) Error!bool {
    if (!try c.isCallableSource(s, sk)) return false;
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        switch (c.ts.kind(rm)) {
            .function, .overloads => return true,
            .object => if (c.ts.objectCallSigCount(rm) != 0) return true,
            else => {},
        }
    }
    return false;
}

/// A source that carries call signatures and no properties of its own — a
/// function value, in other words, however it happens to be materialized.
pub fn isCallableSource(c: *Checker, s: TypeId, sk: types.Kind) Error!bool {
    if (sk == .function or sk == .overloads) return true;
    if (sk != .object and sk != .ref) return false;
    // A reference whose generic table has properties of its own, or no call
    // signature at all, cannot be a bare callable however it is instantiated:
    // property counts carry through a substitution unchanged, and a table with
    // no signature to instantiate gains none. Both are outright NOs read off
    // the generic (see `lazyShapeOf`) — the one shape that has to materialize
    // is a property-free table that does carry signatures, since
    // `instantiateId` may drop a higher-order one.
    if (try c.lazyShapeOf(s)) |generic| {
        if (c.ts.objectPropCount(generic) != 0) return false;
        if (c.ts.objectCallSigCount(generic) == 0) return false;
    }
    const rs = try c.resolveStructural(s);
    if (c.ts.kind(rs) != .object) return false;
    return c.ts.objectCallSigCount(rs) != 0 and c.ts.objectPropCount(rs) == 0;
}

/// tsc's `source !== globalObjectType`: is this the lib's `Object` interface
/// referenced with no arguments? Identity, not structure — a user type that
/// happens to have the same members is not it.
///
/// Asked of the MATERIALIZED form too (through `refFacetOf`, the origin ref
/// each materialization carries): the relation's `.ref` arm resolves an
/// interface reference and re-enters with the object, so a check that only
/// knew the reference would miss every frame that matters.
fn isGlobalObjectType(c: *Checker, s: TypeId) Error!bool {
    const sym = c.prog.globals.lookup(c.atom_Object) orelse return false;
    if (!c.symFlags(sym).interface) return false;
    const ref = c.refFacetOf(s, c.ts.kind(s)) orelse return false;
    return c.ts.refSymbol(ref) == sym and c.ts.refArgs(ref).len == 0;
}

pub fn weakTypeMismatch(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind, src_fresh: bool) Error!bool {
    if (c.rel_intersection_target != 0 or c.weak_rule_off != 0) return false;
    if (c.union_callable_sibling != 0 and try c.isCallableSource(s, sk)) return false;
    switch (tk) {
        .object, .ref, .intersection => {},
        else => return false,
    }
    switch (sk) {
        // tsc's `Primitive | Object | Intersection`. `.ref` and `.class_value`
        // are object types; `.function`/`.overloads` are the callable object
        // types the rule most often fires on. Unions and type variables are
        // deliberately absent — a union source distributes, and a type
        // variable is judged through its constraint elsewhere.
        .object, .ref, .intersection, .function, .overloads, .class_value, .array, .tuple => {},
        .string, .number, .boolean, .bigint, .symbol, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .enum_type, .unique_symbol => {},
        else => return false,
    }
    // tsc's gate excludes the global `Object` type BY IDENTITY
    // (`source !== globalObjectType`). Its members are the ones every value
    // apparently has, so it shares none with a weak target by construction —
    // and rejecting the pair made `hasWings(beast)` for `beast: Object` a
    // false TS2559 against the guard's `x is Winged` parameter.
    if (try isGlobalObjectType(c, s)) return false;
    // A FRESH object literal is the excess-property check's business, not this
    // one. tsc runs `isPerformingExcessPropertyChecks` first and it answers
    // for every fresh source — a literal with a property the weak target does
    // not know is excess (TS2353), and one whose properties are all known has
    // a property in common by construction — so the weak rule can never be
    // what a fresh literal is rejected by. ztsc runs the excess check at the
    // syntactic site rather than inside the relation, so rejecting here would
    // pre-empt it: the site would never see the literal reach its target. It
    // would also make an evolving `let v = null; … v = { z: 1 }` keep a
    // constituent tsc's subtype reduction drops (conformance flow/062).
    if (src_fresh) return false;
    if (!try c.isWeakType(t)) return false;
    // Source side: properties, or (for the callable case) a signature.
    const rs = try c.resolveStructural(s);
    var has_sig = false;
    var props: []const Atom = &.{};
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(c.scratch());
    switch (c.ts.kind(rs)) {
        .object => {
            if (c.ts.objectCallSigCount(rs) != 0 or c.ts.objectConstructSigCount(rs) != 0) has_sig = true;
            for (0..c.ts.objectPropCount(rs)) |i|
                try buf.append(c.scratch(), c.ts.objectProp(rs, @intCast(i)).name);
            props = buf.items;
        },
        .function, .overloads => has_sig = true,
        .intersection => {
            for (try c.memberList(rs)) |m| {
                const rm = try c.resolveStructural(m);
                switch (c.ts.kind(rm)) {
                    .function, .overloads => has_sig = true,
                    .object => {
                        if (c.ts.objectCallSigCount(rm) != 0 or c.ts.objectConstructSigCount(rm) != 0) has_sig = true;
                        for (0..c.ts.objectPropCount(rm)) |i|
                            try buf.append(c.scratch(), c.ts.objectProp(rm, @intCast(i)).name);
                    },
                    else => {},
                }
            }
            props = buf.items;
        },
        // An ARRAY or TUPLE source relates through the `Array<T>` interface's
        // members — `length`, `push`, … — which is exactly what tsc's
        // `getPropertiesOfType(source)` hands `hasCommonProperties`. Without
        // this arm the source fell out of the switch entirely and every array
        // was silently accepted by a weak target: `AOrArrA<{x?: "ok"}>` then
        // kept BOTH constituents through `assignmentReduced`, and `arr.push`
        // on the unreduced `{x?:"ok"} | {x?:"ok"}[]` was a phantom TS2339
        // (`assignmentTypeNarrowing`, tsgo's TS2559 for the direct call).
        .array, .tuple => {
            const ap = (try c.arrayApparentObject(rs)) orelse return false;
            for (0..c.ts.objectPropCount(ap)) |i|
                try buf.append(c.scratch(), c.ts.objectProp(ap, @intCast(i)).name);
            props = buf.items;
        },
        // A PRIMITIVE (or enum) source relates through its wrapper interface's
        // apparent members, and tsc's gate admits it explicitly
        // (`source.flags & (Primitive | Object | Intersection)`). The
        // structural walk does NOT reject the pair on its own: a weak target's
        // properties are all optional, so every one of them is vacuously
        // satisfied and `doSomething(12)` against `Settings` passed silently
        // where tsc answers TS2559. Reading the wrapper's members rather than
        // assuming they never overlap keeps the one case that does — a weak
        // type whose optional property is named after an `Object`/`String`/…
        // member — accepted, as tsc accepts it.
        .string, .number, .boolean, .bigint, .symbol, .unique_symbol, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false, .enum_type, .template_literal_type, .string_mapping => {
            // No lib: the value apparently has no members, and tsc's
            // "source has at least one property" gate then declines.
            const ap = (try c.primitiveApparentObject(rs)) orelse return false;
            for (0..c.ts.objectPropCount(ap)) |i|
                try buf.append(c.scratch(), c.ts.objectProp(ap, @intCast(i)).name);
            props = buf.items;
        },
        else => return false,
    }
    if (props.len == 0 and !has_sig) return false;
    for (props) |p| {
        if (try c.weakTargetKnows(t, p)) return false;
    }
    return true;
}

/// Second reading of a pair whose `this` markers the home-instance rewrite
/// (`this_apparent`) could not relate: bind each side's markers to that side's
/// own RECEIVER instead — tsc's `getTypeWithThisArgument(type, type)`.
///
/// A class or interface INSTANCE binds `this` to itself, including in the
/// members it INHERITED: tsc resolves a type reference's members with the
/// reference as `thisArgument` (`resolveTypeReferenceMembers` pads the type
/// argument list with the reference), so `class D extends RB` reads `RB`'s
/// `destroy(): this` as `destroy(): D` and not as `destroy(): RB`. Reading it
/// as `RB` is a FALSE POSITIVE generator: `class Duplex extends ReadableBase`
/// inherits `destroy(): this`, so relating `Duplex` to `Writable` compared
/// `ReadableBase` against `WritableBase` — two unrelated halves of a stream —
/// and @types/node's `interface DuplexOptions extends WritableOptions` was a
/// phantom TS2430 on the `construct?(this: Duplex, …)` member that hangs off
/// that pair.
///
/// A RETRY, not the first reading, and that is a perf decision with a
/// diagnostic consequence, both worth stating:
///
///   * Cost. The rewrite is per RECEIVER, so a base's member types are
///     re-substituted once per subclass instead of once for the whole family.
///     Done eagerly it cost zod +53% types created (52.7 K → 80.6 K) and +70%
///     instantiations for a wall-clock +14%; done here it is paid only by pairs
///     that have already failed, which no clean program has many of.
///   * Direction. This can only turn a NO into a YES, so it removes false
///     positives and never adds one. The symmetric FALSE NEGATIVE — a TARGET
///     `class W extends WB { extra() }` asks for `destroy(): W` where the
///     home-instance reading only asked for `destroy(): WB`, so a source
///     returning a bare `WB` is accepted — is NOT fixed by a retry, and stays
///     the under-report it already was.
///
/// `prior` is the home-instance reading's answer, returned unchanged when the
/// retry does not apply or does not settle the pair.
fn receiverBoundRetry(c: *Checker, s: TypeId, t: TypeId, prior: RelAnswer) Error!RelAnswer {
    const s_recv = try thisReceiverOf(c, s);
    const t_recv = try thisReceiverOf(c, t);
    if (s_recv == this_apparent and t_recv == this_apparent) return prior;
    const sb = try c.substThis(s, s_recv);
    const tb = try c.substThis(t, t_recv);
    if (sb == s and tb == t) return prior;
    const answer = try relate(c, sb, tb, true);
    return if (answer.related()) answer else prior;
}

/// The receiver a `this` marker inside `ty`'s members denotes, or
/// `this_apparent` when `ty` is not a receiver at all: an anonymous object
/// shape, a deferred operator and a bare marker have no reference their
/// members could have been resolved against. A reference whose ARGUMENTS still
/// mention `this` (`Wrapper<this>`) is not a receiver either — its members'
/// markers belong to the enclosing declaration, not to the instantiation.
fn thisReceiverOf(c: *Checker, ty: TypeId) Error!TypeId {
    const k = c.ts.kind(ty);
    if (k != .object) return this_apparent;
    const ref = refFacetOf(c, ty, k) orelse return this_apparent;
    return if (try c.containsThisType(ref)) this_apparent else ref;
}

/// One relation frame. `memoize` is false for the single caller that
/// DELEGATES its own frame's question unchanged — the `.ref` arm of
/// `isAssignableInner`, which resolves a lazy reference to the very
/// materialization the memo key already canonicalizes it to (see the key
/// below). Both frames then carry the same key, so letting the inner one
/// consult the memo would read the outer one's own in-progress mark and
/// answer "related" without doing any work at all.
fn relate(c: *Checker, s0: TypeId, t0: TypeId, memoize: bool) Error!RelAnswer {
    // Structural-relation recursion guard (see `max_relation_depth`). Past
    // the cap, assume the pair related — this only drops diagnostics, never
    // adds a false positive. Returns before the `(s,t)` relation memo below,
    // so the capped result is never cached and a shallower re-encounter of
    // the same pair still computes the real answer.
    if (c.rel_depth > max_relation_depth) return .assumed_yes;
    // tsc's `checkTypeRelatedTo` prologue: the step budget belongs to the
    // QUERY, not to the checker, so it is (re)armed by whichever frame is
    // outermost and spent by everything under it. Per-query rather than
    // running-total is what keeps the verdict independent of how many files
    // this checker instance happened to check first — see `rel_steps`.
    if (c.rel_depth == 0) {
        c.rel_steps = 0;
        c.rel_overflow = false;
    } else if (c.rel_overflow) {
        // Sticky: once the budget is gone the query has no answer left to
        // give, and tsc unwinds the whole walk with `Ternary.False`. Marked
        // ASSUMED so nothing derived from the abort reaches the memo.
        return .assumed_no;
    }
    c.rel_depth += 1;
    defer {
        c.rel_depth -= 1;
        if (comptime debug_rel_steps > 0) {
            if (c.rel_depth == 0 and c.rel_steps >= debug_rel_steps) {
                std.debug.print("[relsteps] {d} s={d}/{s} t={d}/{s}\n", .{
                    c.rel_steps, s0, @tagName(c.ts.kind(s0)), t0, @tagName(c.ts.kind(t0)),
                });
                if (c.ts.kind(s0) == .intersection) {
                    if (c.memberList(s0)) |ms| {
                        for (ms) |m| std.debug.print("   member {d}/{s}\n", .{ m, @tagName(c.ts.kind(m)) });
                    } else |_| {}
                }
            }
        }
        // Outermost frame: nothing may outlive the query on assumption alone.
        // See `Checker.rel_maybe`.
        if (c.rel_depth == 0 and c.rel_maybe.items.len != 0) {
            for (c.rel_maybe.items) |k| _ = c.relation.remove(k);
            c.rel_maybe.clearRetainingCapacity();
            c.rel_assumed = false;
        }
    }
    // Release this frame's scratch on the way out, the same way an
    // `instantiateId` frame does (see `BumpArena`). The relation is the other
    // deep recursive walk, and the other big scratch consumer: it dupes a
    // member list and builds property worklists per frame, millions of times
    // within a single statement, and none of it outlives the `RelAnswer` the
    // frame answers with — the memo lives on the checker arena and elaboration
    // is a separate re-walk of the failing path (`elaborate.zig`), not a record
    // kept from this one. The arena is captured rather than re-read because a
    // nested top-level `instantiate` swaps a different one in for its own
    // duration.
    const rel_arena = c.scratch_arena;
    const rel_mark = rel_arena.mark();
    defer rel_arena.restore(rel_mark);
    // A polymorphic `this` relates through its apparent instance type. This
    // is a subset simplification (true `this` is nominally narrower than
    // the base), but sound for the fluent/builder patterns we support.
    const s1 = if (c.ts.kind(s0) == .this_type) c.ts.thisTypeInstance(s0) else s0;
    const t1 = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    var s = try c.ts.regularLiteral(s1);
    var t = try c.ts.regularLiteral(t1);
    s = try c.ts.regular(s);
    t = try c.ts.regular(t);
    // tsc's `getNormalizedType`, which runs `getSimplifiedType` over both
    // operands before the relation looks at either: a conditional that is
    // trivially its own check type (`T extends T ? T : never`) is the check
    // type here, however deferred it stays everywhere else. Two kind reads on
    // a pair that already failed the identity test — see `simplifyConditional`.
    s = c.simplifyConditional(s);
    t = c.simplifyConditional(t);
    if (s == t) return .yes;
    // The substitution arm of the same `getNormalizedType`, and the ONE place
    // a substitution's implied constraint enters a relation. tsc runs the two
    // operands through it with opposite `writing` flags:
    //
    //   * SOURCE (`writing = false`) -> `getSubstitutionIntersection`, i.e.
    //     `base & constraint`. A value PRODUCED at a guarded position really
    //     is both, which is what lets the `n` of `number extends T ?
    //     (cb: (n: number) => void) => void : never` be handed to a
    //     `(x: T) => void`.
    //   * TARGET (`writing = true`) -> the BASE alone. A value flowing INTO
    //     the position only has to be a `base`; demanding the constraint too
    //     would reject the very values the guard supplies.
    //
    // Folded into the `sk`/`tk` reads below rather than run here, so a program
    // that writes no conditional true branch pays NOTHING for it: the kinds
    // are read once either way, and the rewrite only re-reads them on the pair
    // that actually carries a wrapper. Placed after the `this` block because
    // that block may delegate the whole frame.
    // The same simplification, one level down: a `this` NESTED inside a
    // deferred operator (`this extends {_zod:…} ? this["_zod"]["output"] :
    // unknown`, zod's `output<this>`) relates through its apparent instance
    // too. tsc never sees this pair — it resolves an interface reference's
    // members with the reference itself as `thisArgument`, so both sides are
    // already concrete by the time they are compared — whereas ztsc keeps
    // the marker until the access site. Two such operands that differ only
    // in WHICH instance they were declared against are not identical ids and
    // have no structural rule that could relate them, so without this every
    // schema-vs-schema comparison in zod failed on a pair that prints the
    // same on both sides. Costs one memoized `containsThisType` lookup on a
    // pair that already failed the identity test.
    if (c.has_this_types and ((try c.containsThisType(s)) or (try c.containsThisType(t)))) {
        const sa = try c.substThis(s, this_apparent);
        const ta = try c.substThis(t, this_apparent);
        // Delegated wholesale, answer and all: the rewritten pair IS this
        // frame's question, so its provisional-ness is this frame's too.
        if (sa != s or ta != t) {
            const answer = try relate(c, sa, ta, true);
            if (answer.related()) return answer;
            return receiverBoundRetry(c, s, t, answer);
        }
    }
    var sk = c.ts.kind(s);
    var tk = c.ts.kind(t);
    if (sk == .substitution or tk == .substitution) {
        s = try c.substitutionIntersection(s);
        t = c.ts.substitutionBase(t);
        if (s == t) return .yes;
        sk = c.ts.kind(s);
        tk = c.ts.kind(t);
    }
    // The generic reference each side denotes (`refFacetOf`), read ONCE: the
    // origin fast-paths, the variance probe and the relation memo key all
    // want it, and each used to pay its own `origin` lookup.
    const sr = c.refFacetOf(s, sk);
    const tr = c.refFacetOf(t, tk);
    // Reflexive origin fast-path (see `origin`): two distinct materialized
    // types (object or function member) that both denote the same generic
    // instantiation `G<A…>` — identical symbol AND element-wise-equal args,
    // so identical interned origin refs — are mutually assignable by
    // identity. This short-circuits the structural walk that would otherwise
    // fail on non-confluent one-step vs two-step reductions of the same
    // type. Identity-only: no variance, it fires solely when the origin refs
    // are equal.
    if (originTaggable(sk) and sk == tk) {
        if (sr) |os| {
            if (tr) |ot| {
                // Reflexive identity: same interned origin ref (see `origin`).
                if (os == ot) return .yes;
                // Variance-free EQUIVALENCE: both denote `G<…>` for the same
                // `G`, and each arg pair is equal — by TypeId identity or by a
                // SOUND reduction (`T & {} ≡ T`; interned structural forms
                // compared by identity, never by mutual assignability). Two
                // args that are equal types make the two instantiations the
                // SAME type regardless of `G`'s variance, so the relation is
                // reflexive. This closes the RTK non-confluence where one
                // instantiation carries an unreduced config `C1 = P & Omit<…>`
                // and the other the concrete reduction `C2 = P`.
                if (c.ts.refSymbol(os) == c.ts.refSymbol(ot)) {
                    if (try c.originArgEquiv(os, ot)) return .yes;
                }
            }
        }
    }
    // A lazy alias `.ref` and the materialization tagged with that very ref
    // denote one type (see `origin`), so the relation between them is
    // reflexive in both directions.
    if (sk == .ref and originTaggable(tk)) {
        if (tr) |ot| {
            if (ot == s) return .yes;
            if (c.ts.refSymbol(ot) == c.ts.refSymbol(s) and
                try c.originArgEquiv(ot, s)) return .yes;
        }
    }
    if (tk == .ref and originTaggable(sk)) {
        if (sr) |os| {
            if (os == t) return .yes;
            if (c.ts.refSymbol(os) == c.ts.refSymbol(t) and
                try c.originArgEquiv(os, t)) return .yes;
        }
    }
    // Trivial targets/sources.
    switch (tk) {
        .any, .err, .unknown, .none => return .yes,
        else => {},
    }
    // even `any` is not assignable to never
    if (tk == .never) return if (sk == .never) .yes else .no;
    // An uninhabited intersection source denotes `never`, which relates to
    // everything (tsc's `getReducedType`). See `intersectionIsNever`.
    if (sk == .intersection and try c.intersectionIsNever(s)) return .yes;
    switch (sk) {
        .any, .err, .never, .none => return .yes,
        else => {},
    }
    // `void` accepts `undefined` and itself (tsc `isSimpleTypeRelatedTo`:
    // `s & Undefined && t & (Undefined | Void)`), and nothing else — but this
    // arm ran ahead of the SOURCE-UNION distribution in `isAssignableInner`
    // and so answered for `void | undefined` as one opaque source. tsc has no
    // such arm: it relates a union source constituent-wise, and each of those
    // two constituents is related to `void`, so the union is. `void |
    // undefined` is what a `.then(…)` callback or an optional-void return
    // annotation produces, and it was rejected by the very type it came from.
    // Falling THROUGH for a union source is the whole fix — every constituent
    // comes back to this arm one frame down. A lazy alias `.ref` that stands
    // for such a union (`type MaybeVoid = void | undefined`) is resolved here,
    // the same way the union-target arm resolves one.
    if (tk == .void) {
        if (sk == .undefined or sk == .void) return .yes;
        // A TYPE PARAMETER is not a "simple" type either: tsc never reaches
        // `isSimpleTypeRelatedTo` with one, it reaches
        // `structuredTypeRelatedTo`'s type-variable arm and relates the
        // CONSTRAINT. `<W extends void>` IS assignable to `void`; the
        // `sk == .type_param` arm further down is what says so, and this arm
        // only has to stop answering ahead of it. `inferTypes1`'s
        // `type C2<S, U extends void> = S extends A2<infer T, U> ? …` is the
        // witness — a false TS2344 on `U` against `A2<T, U extends void>`.
        if (sk != .union_type and sk != .type_param) {
            if (sk == .ref and !c.refExpandsToObject(s)) {
                const rs = try c.resolveStructural(s);
                // Delegated wholesale, as the `this` rewrite above is.
                if (rs != s and c.ts.kind(rs) == .union_type) return relate(c, rs, t, true);
            }
            return .no;
        }
    }

    // Literal -> base primitive.
    const base = try c.literalBaseOf(s);
    if (base != types.no_type and base == t) return .yes;

    // The weak-type rule (tsc's `isPerformingCommonPropertyChecks`), ahead of
    // the memo and the structural walk: a WEAK target — all-optional, no
    // signatures, no index — is satisfied vacuously by anything, so tsc adds
    // the requirement that the two share a property name. Placed here rather
    // than inside the structural walk because a union target reaches its
    // constituents through `isAssignableInner`, and tsc runs the check on each
    // of those frames (which is what makes an overload whose parameter is
    // `WeakOptions | BufferEncoding | null` reject a callback argument).
    // A FRESH object literal source turns the rule off for this frame AND
    // everything under it. tsc answers for a fresh literal with the
    // excess-property check, which runs ahead of the weak check inside its
    // relation; ztsc runs that check at the syntactic site instead, so the
    // relation has to let the literal through for the site to see it — and
    // "the literal" includes the re-materialized, regular-ized copies the
    // frames below this one work with, which no longer carry the flag.
    const src_fresh = c.ts.objectIsFresh(s1);
    if (src_fresh) c.weak_rule_off += 1;
    defer if (src_fresh) {
        c.weak_rule_off -= 1;
    };
    if (try c.weakTypeMismatch(s, t, sk, tk, src_fresh)) return .no;

    // Cache compound comparisons (recursion termination for refs), keyed on
    // what each side DENOTES rather than on the TypeId it happens to be: a
    // materialized instantiation is keyed by its origin ref (`relKeyOf`).
    //
    // Two objects carrying the same origin ref denote the same nominal
    // instantiation `G<A…>` — identical symbol AND element-wise-equal args,
    // since `makeRef` interns — so they pose the SAME relation question, and
    // the re-materialization a `this`-substituting member hands back (a fresh
    // TypeId, since it does not intern back to the object the walk started
    // from) now hits the in-progress mark instead of restarting the walk.
    // Sound for exactly the reason the reflexive fast-path above is.
    const cacheable = memoize and (isCompound(sk) or isCompound(tk));
    // WHICH relation is asking is part of the question, so it is part of the
    // key — tsc gives each relation its own `Map` for the same reason. The two
    // TypeIds occupy 31 bits each at the very most (a `TypeId` indexes the type
    // store, and a program with 2^31 types cannot be loaded), so the top bit is
    // free to carry the relation and the assignable relation's keys — every key
    // the checker used before this — are unchanged.
    const key = (@as(u64, relKeyOf(s, sk, sr)) << 32) | relKeyOf(t, tk, tr) |
        @as(u64, @intFromBool(c.rel_kind == .comparable)) << 63;
    if (cacheable) {
        if (c.relation.get(key)) |v| {
            c.stats.relation_hits += 1;
            if (v == 2) {
                // In progress: assume (recursive types). The assumption rides
                // out on the answer — see `RelAnswer`.
                return .assumed_yes;
            }
            return if (v == 1) .yes else .no;
        }
    }
    // The memo did not know this pair, so answering it costs a structural
    // walk: charge it to the query's budget (tsc's `relationCount--`, at the
    // same place — past the memo probe, ahead of the in-progress mark). Past
    // the budget the query is abandoned rather than answered; see
    // `max_relation_steps`.
    c.rel_steps += 1;
    if (c.rel_steps > max_relation_steps) {
        c.rel_overflow = true;
        return .assumed_no;
    }
    // Growing-instantiation guard (tsc's `isDeeplyNestedType`, see
    // `max_relation_identity_repeats`). Runs BEFORE the in-progress mark is
    // written: an assumed answer must leave no trace in the memo, or the
    // `2` would answer every later reader of the pair.
    //
    // Pushed FIRST, then tested with this frame included — the growth test
    // reads the chain, and this frame is its last link. Either side growing is
    // enough: one runaway spine is all it takes for the walk not to terminate,
    // and the growth test is precise enough that it does not fire on the
    // ordinary recursive types tsc's both-sides rule exists to protect.
    var pushed = false;
    if (sr) |sref| {
        if (tr) |tref| {
            if (c.rel_id_depth >= max_relation_depth) {
                c.rel_guard_tripped = true;
                return .assumed_yes;
            }
            c.rel_src_ids[c.rel_id_depth] = .{ .sym = c.ts.refSymbol(sref), .ref = sref };
            c.rel_tgt_ids[c.rel_id_depth] = .{ .sym = c.ts.refSymbol(tref), .ref = tref };
            c.rel_src_buckets[relIdBucket(c.rel_src_ids[c.rel_id_depth].sym)] += 1;
            c.rel_tgt_buckets[relIdBucket(c.rel_tgt_ids[c.rel_id_depth].sym)] += 1;
            c.rel_id_depth += 1;
            pushed = true;
        }
    }
    defer if (pushed) {
        c.rel_id_depth -= 1;
        c.rel_src_buckets[relIdBucket(c.rel_src_ids[c.rel_id_depth].sym)] -= 1;
        c.rel_tgt_buckets[relIdBucket(c.rel_tgt_ids[c.rel_id_depth].sym)] -= 1;
    };
    // The expanding flags are per-FRAME state that children inherit, so the
    // save/restore is function-scoped even though only tsc's rule reads them.
    const saved_expanding = c.rel_expanding;
    defer c.rel_expanding = saved_expanding;
    if (pushed) {
        if (comptime checker_zig.relation_guard_both_sides) {
            if (c.rel_expanding & 1 == 0 and c.relIdDeeplyNested(true)) c.rel_expanding |= 1;
            if (c.rel_expanding & 2 == 0 and c.relIdDeeplyNested(false)) c.rel_expanding |= 2;
            if (c.rel_expanding == 3) {
                c.rel_guard_tripped = true;
                return .assumed_yes;
            }
        } else if (c.relIdDeeplyNested(true) or c.relIdDeeplyNested(false)) {
            c.rel_guard_tripped = true;
            return .assumed_yes;
        }
    }
    const maybe_start = c.rel_maybe.items.len;
    if (cacheable) {
        c.stats.relation_misses += 1;
        try c.relation.put(c.cm(), key, 2);
        try c.rel_maybe.append(c.cm(), key);
    }
    // tsc's `Ternary.Maybe` bookkeeping: this frame's own verdict starts out
    // resting on nothing, and the field becomes the window in which the walk
    // below reports what IT assumed. Everything the walk reaches through
    // `isAssignableInner` and through the helpers in other files answers with a
    // bare `bool`, so the field is how their assumptions get back here; a
    // nested `relate` returns its own (`RelAnswer`) and `relateFolded` deposits
    // it here on arrival. Restored — not OR-ed — on the way out: this frame's
    // answer is RETURNED, and its own caller's `relateFolded` folds it in.
    // See `Checker.rel_assumed`.
    const saved_assumed = c.rel_assumed;
    c.rel_assumed = false;
    // Declared variance (`interface Box<in T>`/`<out T>`): two references
    // to the same generic symbol relate by their type ARGUMENTS, not by
    // their members (see `varianceVerdict`). Runs after the identity
    // fast-paths above — an equal pair never reaches here — and yields to
    // the structural walk whenever the annotations are not decisive.
    //
    // Both probes sit HERE, below the memo lookup, the growing-instantiation
    // guard and the in-progress mark, which is where tsc runs its own
    // variance comparison (`relateVariances`, reached from
    // `structuredTypeRelatedTo` — i.e. past `recursiveTypeRelatedTo`'s
    // `maybeKeys` push and its `isDeeplyNestedType` test). The placement is
    // load-bearing, not cosmetic: what a variance verdict relates is the two
    // sides' ARGUMENTS, and those are very often references to the same
    // generic one level down. A probe running ABOVE the three guards
    // therefore recurses through itself with no memo to answer a pair already
    // decided, no in-progress mark to cut a cycle, and — because the guard
    // frame is pushed further down and so never reached — no growth test to
    // cut a runaway spine like `G<A>` → `G<G<A>>` → … Nothing bounded it but
    // `max_relation_depth`, and with a branch per type argument that bound is
    // exponential: immich's server package hung for tens of minutes inside
    // `relate` → `measuredVarianceVerdict` → `relate`. Down here the probe
    // inherits all three protections, and a verdict is CACHED rather than
    // re-derived at every reference.
    //
    // The one exemption is the marker pair a declaration-site MEASUREMENT is
    // relating (`isVarianceMarkerRef`): answering those from the declared
    // variance is what the measurement exists to verify, so it would make
    // every annotation vacuously true. tsc exempts its `markerTypes` here
    // for the same reason.
    //
    // Inside a measurement a NEGATIVE verdict on some *other* generic in the
    // spine is not decisive either, and falls through to the structural walk:
    // tsc's variance comparison keeps a structural fallback, so an inner
    // generic whose own annotation contradicts its members (already reported
    // on its own line) must not make its every USER a second report.
    // …and one further restriction, which is a CONVERGENCE rule rather than a
    // typing one: the probe runs only when both sides are DECLARED references
    // (`.ref`), never when a side's reference facet was recovered from the
    // `origin` side table.
    //
    // `origin` is written by `expandRef` and grows as the run proceeds, so
    // "this interned object is the materialization of `G<A…>`" is a fact about
    // what this checker has already expanded, not a fact about the object. A
    // rule that DECIDES on it answers differently depending on whether some
    // earlier file in the same partition happened to expand `G<A…>` first —
    // and the variance probe decides: it answers YES where the structural walk
    // below answers NO.
    //
    // social-app's `src/lib/routes/router.ts` is the case.
    // `Object.entries(description)` with
    // `description: Record<keyof T, string | string[]>` relates that mapped
    // type to the generic overload's `{ [s: string]: U }` at `U = unknown`.
    // Both sides are bare structural types; the target is the expansion of
    // `Record<string, unknown>`, so it carries that origin ref IF AND ONLY IF
    // this checker has already expanded `Record<string, unknown>` for some
    // other file. Where it had, the probe matched `Record` on both sides,
    // related the arguments by measured variance and answered YES — the
    // generic overload won with `U` uninferred, so `pattern` came out
    // `unknown` and `pattern.forEach` reported TS2339. Where it had not, the
    // same call fell to `entries(o: {}): [string, any][]` and reported
    // nothing. That is the diagnostic `bench/convergence.sh` saw at
    // `--checkers=2..8` and not at `--checkers=1`.
    //
    // The reflexive origin fast-path above is deliberately NOT restricted: it
    // fires only when the two origins are EQUAL, i.e. when both sides denote
    // one and the same instantiation, where the answer is YES either way and
    // the tag only saves a walk that non-confluent materializations would
    // fail. The variance probe is the one that turns a structural NO into a
    // YES on a pair whose arguments differ.
    const declared_refs = sk == .ref and tk == .ref;
    const verdict: RelVerdict = blk: {
        if (sr) |sref| {
            if (tr) |tref| {
                if (declared_refs and sref != tref and c.ts.refSymbol(sref) == c.ts.refSymbol(tref) and
                    !c.isVarianceMarkerRef(sref) and !c.isVarianceMarkerRef(tref))
                {
                    if (try c.varianceVerdict(sref, tref)) |verdict| {
                        if (verdict) break :blk .yes;
                        if (c.variance_marker_refs[0] == 0) {
                            // A negative declared verdict is decisive only
                            // while no measurement is in flight, so it must NOT
                            // be memoized: the very same pair may be asked
                            // again from inside a measurement, where the rule
                            // above says to fall through to the structural
                            // walk. Leave no trace either way.
                            break :blk .no_nocache;
                        }
                    }
                    // Nothing declared, or nothing decisive: MEASURE how the
                    // generic uses its parameters and relate the arguments by
                    // that (see `measuredVarianceVerdict`). A COMPLETE
                    // measurement decides the pair either way — tsc's
                    // `relateVariances` returns `Ternary.False` without looking
                    // at a member — and anything it could not settle falls
                    // through to the structural walk below.
                    //
                    // `marker_refs` is tsc's `markerTypes`: a pair some
                    // measurement minted is the question, not something to answer
                    // from a verdict. (The DECLARED verdict above needs no such
                    // guard for a measured pair: a mixed `<in A, B>` measuring `B`
                    // leaves `A` identical on both sides and `B` unannotated, so
                    // `varianceVerdict` is never decisive on it.)
                    if (!c.marker_refs.contains(sref) and !c.marker_refs.contains(tref)) {
                        switch (try c.measuredVarianceVerdict(sref, tref)) {
                            .related => break :blk .yes,
                            // ALIAS-REF BISECT LEG (see
                            // `checker.Options.alias_variance_decides`): tsc runs
                            // the decisive comparison over an alias pair from a
                            // DIFFERENT site than over a type-reference pair — the
                            // `source.aliasSymbol === target.aliasSymbol` shortcut
                            // at the top of `structuredTypeRelatedTo`, ahead of
                            // every structural arm — and ztsc's own measurement is
                            // trustworthy on the alias population in a way
                            // 60f4287 measured it is not on the interface/class
                            // one (zod v4's `ZodType` family). So the two are
                            // separately switchable.
                            .unrelated => if (measured_variance_decides or c.opts.variance_decides or
                                (c.opts.alias_variance_decides and c.symFlags(c.ts.refSymbol(sref)).type_alias))
                            {
                                break :blk .no;
                            },
                            .undecided => {},
                        }
                    }
                }
            }
        }
        // Nominal heritage fast path (see `nominalHeritageRelated`): a class or
        // interface reaches a DECLARED base of itself without walking members.
        // Positive-only; anything it cannot settle falls through to the
        // structural walk below, so it never invents a "not related".
        if (sr) |sref| {
            if (tr) |tref| {
                if (try c.nominalHeritageRelated(sref, tref)) break :blk .yes;
            }
        }
        if (try c.isAssignableInner(s, t, sk, tk)) break :blk .yes;
        // tsc's comparable-relation retry, in `isRelatedTo` and therefore at
        // EVERY level of the walk, not just the top:
        //
        // ```ts
        // if (relation === comparableRelation && !(targetFlags & TypeFlags.Never) &&
        //     isSimpleTypeRelatedTo(target, source, relation) ||
        //     isSimpleTypeRelatedTo(source, target, relation, …)) return Ternary.True;
        // ```
        //
        // `isSimpleTypeRelatedTo` alone — primitives, literals and enums,
        // decided on flags (`simpleRelationKind`), never an object shape — so
        // `{ a: 1, b: string }` and `{ a: number, b: "a" }` overlap (each
        // PROPERTY is comparable in one direction or the other, independently
        // of the others: `conformance/…/comparable/independentPropertyVariance`)
        // while `{ x: {} }` does not become comparable to `{ x: { z } }` just
        // because `{ z }` fits `{}`.
        //
        // The reversed probe runs under the ASSIGNABLE relation: it is a full
        // `relate` (the literal→base-primitive and trivial-target fast paths
        // that decide most simple pairs live there, not in
        // `isAssignableInner`), and a both-simple pair asked under `.comparable`
        // would re-enter this same rule with the operands swapped and bounce
        // forever. The two relations agree on everything `simpleRelationKind`
        // admits except tsc's numeric-enum clause, which is the direction the
        // forward probe already took.
        if (c.rel_kind == .comparable and tk != .never and
            simpleRelationKind(sk) and simpleRelationKind(tk))
        {
            const saved_rk = enterRelation(c, .assignable);
            defer c.rel_kind = saved_rk;
            if (try relateFolded(c, t, s, true)) break :blk .yes;
        }
        break :blk .no;
    };
    // tsc's `Ternary.Maybe`: a verdict the walk could only reach by ASSUMING
    // an in-progress pair (or by taking a growth/depth cut) is not published.
    // See `RelAnswer` — publishing such a verdict is what made a pair's answer
    // a function of which walk reached it first, i.e. of the file order and the
    // `--checkers=N` partition. THE MEMO WRITES BELOW DECIDE FROM `answer`, so
    // the provisional bit cannot be forgotten the way an ambient flag can.
    const answer = RelAnswer.of(verdict == .yes, c.rel_assumed);
    c.rel_assumed = saved_assumed;
    // An ABANDONED query learned nothing. Every verdict unwinding under
    // `rel_overflow` is a fact about the budget, not about the pair, so the
    // marks this frame stood on are withdrawn and nothing is published —
    // otherwise the next query would read a "not related" that only means
    // "the previous question ran out of steps first". (tsc does publish here,
    // and that is a known wart: it makes the answer depend on which query got
    // there first, which is exactly what the `--checkers=N` grid forbids.)
    if (cacheable and c.rel_overflow) {
        for (c.rel_maybe.items[maybe_start..]) |k| _ = c.relation.remove(k);
        c.rel_maybe.shrinkRetainingCapacity(maybe_start);
    } else if (cacheable) {
        if (answer.related()) {
            // Definite YES, or the outermost frame of the query: the walk
            // closed without contradicting anything it assumed, so the whole
            // group is published together. A YES that still rests on marks an
            // ANCESTOR wrote stays pending for that ancestor to settle.
            if (!answer.assumed() or (commit_at_root and c.rel_depth == 1)) {
                for (c.rel_maybe.items[maybe_start..]) |k| try c.relation.put(c.cm(), k, 1);
                c.rel_maybe.shrinkRetainingCapacity(maybe_start);
            }
        } else {
            // NO withdraws every mark the walk stood on — they were assumed to
            // reach a verdict that contradicts them.
            for (c.rel_maybe.items[maybe_start..]) |k| _ = c.relation.remove(k);
            c.rel_maybe.shrinkRetainingCapacity(maybe_start);
            if (verdict == .no and (!answer.assumed() or commit_at_root)) {
                try c.relation.put(c.cm(), key, 0);
            }
        }
    }
    return answer;
}

/// What ONE relation frame answered, and whether that answer is EVIDENCE or an
/// ASSUMPTION — tsc's `Ternary.Maybe`, RETURNED rather than smuggled through a
/// context field the caller has to remember to read.
///
/// A frame answers from assumption when it met the pair already in progress
/// (the co-inductive cycle cut), when it hit the depth cap
/// (`max_relation_depth`), or when the growing-instantiation guard cut it
/// (`relIdDeeplyNested`). Such an answer is a fact about the WALK that reached
/// the pair, not about the pair, so it must never reach the `relation` memo —
/// which is why the memo writes above read `answer` and not a flag: a new
/// optimistic early return in `relate` cannot be added without naming an
/// `assumed_*` case, whereas it could always be added without setting a field.
///
/// The NO half carries the bit too. A negative verdict the walk reached while
/// standing on an assumption is provisional in exactly the same way, and the
/// caller's own verdict inherits it (`relateFolded`).
const RelAnswer = enum {
    no,
    yes,
    assumed_no,
    assumed_yes,

    fn of(is_related: bool, on_assumption: bool) RelAnswer {
        if (on_assumption) return if (is_related) .assumed_yes else .assumed_no;
        return if (is_related) .yes else .no;
    }
    fn related(a: RelAnswer) bool {
        return a == .yes or a == .assumed_yes;
    }
    fn assumed(a: RelAnswer) bool {
        return a == .assumed_no or a == .assumed_yes;
    }
};

/// The three ways one frame's own `relation` entry can go: publish related,
/// publish not-related, and not related *and not memoizable* (a negative
/// declared-variance verdict, decisive only while no variance measurement is in
/// flight). Orthogonal to `RelAnswer`, which is what the frame hands its
/// CALLER; this is only about the write.
const RelVerdict = enum { yes, no, no_nocache };

/// A/B leg: tsc commits a still-pending maybe group at its outermost relation
/// frame; with this off nothing derived from an assumption is ever published.
const commit_at_root = true;

/// A COMPLETE measured-variance comparison that fails DECIDES the pair — tsc's
/// `relateVariances` returns `Ternary.False` and `structuredTypeRelatedTo`
/// hands that back without looking at a member. Believing only the positive
/// half is not a conservative simplification but a different type system: the
/// structural walk is co-inductive, so a mutually-recursive family whose
/// arguments are genuinely unrelated walks in a circle and comes back YES (see
/// `measuredVarianceVerdict` for the `outline` shape that showed it).
///
/// "Complete" is doing the work here, and it is why this was off from 60f4287
/// until wave 36: a measurement ztsc could not fully take used to read as an
/// ordinary verdict, so a decisive NO could be manufactured out of a walk that
/// never finished. `measuredVariances` now carries tsc's `Unmeasurable` /
/// `Unreliable` marks (`AllowsStructuralFallback`) beside each parameter's
/// verdict, and `measuredVarianceVerdict` refuses to decide on a flagged one —
/// which is exactly the set of pairs the earlier attempts got wrong. With the
/// marks in, the `--variance-decides` leg is 0 regressions / +1 exact over the
/// whole ts-suite, both apps byte-identical and the `--checkers` grid stable;
/// the four cases wave 35 recorded as blockers
/// (`varianceRepeatedlyPropegatesWithUnreliableFlag`,
/// `nongenericPartialInstantiationsRelatedInBothDirections`,
/// `unionTypeInference`) are clean.
///
/// `checker.Options.variance_decides` stays as the RUN-TIME leg, so a binary
/// can still be asked the old question; it is now the default rather than the
/// experiment.
const measured_variance_decides = true;

/// How many references the nominal heritage walk holds before giving up (and
/// the size of its stack-allocated queue). A declared `extends` graph is a
/// handful of links wide in practice; past the cap the structural walk
/// answers, as it did before the fast path.
const max_heritage_walk: usize = 64;

/// Is the source RELATED TO the target because the target IS one of the
/// source's declared bases?
///
/// `class HTMLDivElement extends HTMLElement` (and `interface
/// DataHTMLAttributes<T> extends HTMLAttributes<T>`) makes the derived type a
/// subtype of the base whenever it only ADDS to it: the base's members are
/// literally the base's members, so the structural walk was re-deriving —
/// once per pair, over the several hundred members of a lib interface — a
/// verdict that type identity settles. B1's TS2344 gate made that walk the
/// dominant cost of the check phase on `.d.ts` corpora that write nominal
/// constraints (`T extends HTMLElement` appears 119 times in @types/react),
/// which is what this path is for.
///
/// "Only adds to it" is the load-bearing qualifier and is CHECKED, not assumed
/// — see `heritageInheritsUnchanged`. An `extends` clause is not a guarantee
/// that the relation holds; a derived declaration that redeclares an inherited
/// member at an incompatible type is reported (TS2415/TS2416) and is still not
/// assignable to its base.
///
/// Both sides must denote a generic reference (`refFacetOf`) and the target's
/// symbol must be a class or an interface — a nominal declaration is the only
/// thing an `extends` clause can name and the only thing this may conclude
/// about. The walk follows `declaredBaseRefs` transitively, instantiating each
/// base through the reference's own arguments, and answers only when it lands
/// on a base instantiation of the TARGET's symbol whose arguments make the two
/// the same type:
///
///   * argument-wise IDENTICAL (`Base<T>` reached from `Derived<T>` against
///     the written `Base<T>`) — the same type, so related under any variance;
///   * or the target's argument is `any` (`ZodString`'s base `ZodType<string,
///     ZodStringDef, string>` against the written `ZodType<any, any, any>`) —
///     `any` relates to everything in both directions, so it is related under
///     any variance too.
///
/// `unknown` is deliberately NOT in that list: it swallows a covariant
/// argument but not a contravariant one, so it needs the variance machinery
/// the structural path already has. Everything else — a base instantiation
/// whose arguments merely *relate* — falls through untouched. `implements` is
/// not heritage for this purpose either: it is a constraint the class is
/// separately checked against (TS2420), not a declaration that the relation
/// holds.
pub fn nominalHeritageRelated(c: *Checker, src_ref: TypeId, tgt_ref: TypeId) Error!bool {
    const s = &c.ts;
    const tsym = s.refSymbol(tgt_ref);
    // The same symbol on both sides is the variance question, already asked
    // above; a non-nominal target has no `extends` clause naming it.
    if (s.refSymbol(src_ref) == tsym) return false;
    const tf = c.symFlags(tsym);
    if (!tf.interface and !tf.class) return false;
    // The overwhelmingly common case — a source that declares no heritage at
    // all — costs one hash probe and no allocation. The queue is a fixed
    // stack buffer for the same reason: this runs on every ref-against-ref
    // relation frame in the program, most of which end right here.
    if ((try c.declaredBaseRefs(s.refSymbol(src_ref))).len == 0) return false;
    var queue: [max_heritage_walk]TypeId = undefined;
    queue[0] = src_ref;
    var qlen: usize = 1;
    var head: usize = 0;
    while (head < qlen) : (head += 1) {
        const cur = queue[head];
        const csym = s.refSymbol(cur);
        // Copied out: `declaredBaseRefs` may grow the pool the slice points
        // into while this loop instantiates.
        var buf: [8]TypeId = undefined;
        const bases = try c.declaredBaseRefs(csym);
        if (bases.len == 0) continue;
        const n = @min(bases.len, buf.len);
        @memcpy(buf[0..n], bases[0..n]);
        var map_list: std.ArrayList(TpMap) = .empty;
        defer map_list.deinit(c.scratch());
        if (s.refArgs(cur).len > 0) try c.buildInstMap(csym, s.refArgs(cur), &map_list);
        for (buf[0..n]) |b0| {
            const b = if (map_list.items.len > 0) try c.instantiate(b0, map_list.items) else b0;
            if (s.kind(b) != .ref) continue;
            if (s.refSymbol(b) == tsym and heritageArgsIdentical(c, b, tgt_ref)) {
                // The `extends` edge is not by itself proof: a derived
                // declaration may REDECLARE an inherited member at a type the
                // base's does not accept (tsc reports TS2415/TS2416 on the
                // declaration and still answers "not related" at every use).
                // Verify the inherited members came through untouched — see
                // `heritageInheritsUnchanged`. Anything else falls through to
                // the structural walk, which decides it properly.
                return heritageInheritsUnchanged(c, src_ref, b);
            }
            if (qlen == queue.len) return false;
            var dup = false;
            for (queue[0..qlen]) |q| {
                if (q == b) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                queue[qlen] = b;
                qlen += 1;
            }
        }
    }
    return false;
}

/// Did `src_ref` inherit `base`'s members WITHOUT redeclaring any of them?
///
/// This is the premise `nominalHeritageRelated` needs and an `extends` clause
/// alone does not supply. TypeScript's heritage check is not a guarantee that
/// the derived type is assignable to the base — it is a DIAGNOSTIC (TS2415, and
/// TS2416 per offending member) about the case where it is not. A class that
/// redeclares an inherited member at an unrelated type is reported *there* and
/// stays unassignable to its own base everywhere else:
///
/// ```ts
/// class Store<T> { add = (i: T): T => i; }     // T invariant
/// class Base { store!: Store<Base>; id = ""; }
/// class Sub extends Base { store!: Store<Sub>; name = ""; }
/// declare const s: Sub;
/// const b: Base = s;                            // tsc: TS2322
/// ```
///
/// Taking `extends Base` as given answers YES here, and answers it for the
/// whole cascade that rests on it — outline's `Collection`/`Model` pair, whose
/// `store` fields are two instantiations of an invariant `Store<T>`, is exactly
/// this shape at scale (~290 missing diagnostics).
///
/// The test is deliberately by TYPE IDENTITY, not by relating: an inherited
/// member that was not redeclared IS the base's member, instantiated through
/// the same arguments, so the two sides hold the very same `TypeId` and the
/// pair is related for free. A redeclared member — even one that is perfectly
/// compatible — fails the test and hands the pair to the structural walk,
/// which is the answer it would have had before the fast path existed. So this
/// only ever costs a walk, never an answer.
///
/// The comparison runs against the base instantiation the heritage walk
/// REACHED, not against the written target: when the target's argument is `any`
/// (`ZodType<any, any, any>` vs `ZodString`'s written `ZodType<string,
/// ZodStringDef, string>`) the two differ, and it is the reached one whose
/// members `src_ref` actually inherited. `any` on the target relates to the
/// reached base under any variance, so the second leg needs nothing checked.
fn heritageInheritsUnchanged(c: *Checker, src_ref: TypeId, base: TypeId) Error!bool {
    const st = try c.expandRef(src_ref);
    const bt = try c.expandRef(base);
    const s = &c.ts;
    if (s.kind(st) != .object or s.kind(bt) != .object) return false;
    const n = s.objectPropCount(bt);
    for (0..n) |i| {
        const bp = s.objectProp(bt, @intCast(i));
        const sp = (try c.propOfTypeEx(st, bp.name, false)) orelse return false;
        if (sp.ty != bp.ty) return false;
        if (sp.optional() != bp.optional()) return false;
        // A NON-PUBLIC member is inherited only when the derived declaration IS
        // the base's. Type identity does not settle that: `class R extends A {
        // private a: string }` redeclares A's `private a: string` at the very
        // same type, and the two declarations are still unrelated (tsc reports
        // TS2415 on the `extends` clause and answers "not related" at every
        // use). See `nominal_members.zig`.
        if ((sp.nonPublic() or bp.nonPublic()) and
            !try nominal_members.nonPublicPropRelated(c, src_ref, base, bp.name, sp.nonPublic(), bp.nonPublic())) return false;
    }
    // Index signatures and call/construct signatures are inherited the same
    // way and compared the same way. A base that has none demands nothing.
    if (s.objectStringIndex(bt) != 0 and s.objectStringIndex(st) != s.objectStringIndex(bt)) return false;
    if (s.objectNumberIndex(bt) != 0 and s.objectNumberIndex(st) != s.objectNumberIndex(bt)) return false;
    if (s.objectCallSigCount(bt) != 0) {
        if (s.objectCallSigCount(st) != s.objectCallSigCount(bt)) return false;
        for (0..s.objectCallSigCount(bt)) |i| {
            if (s.objectCallSig(st, @intCast(i)) != s.objectCallSig(bt, @intCast(i))) return false;
        }
    }
    if (s.objectConstructSigCount(bt) != 0) {
        if (s.objectConstructSigCount(st) != s.objectConstructSigCount(bt)) return false;
        for (0..s.objectConstructSigCount(bt)) |i| {
            if (s.objectConstructSig(st, @intCast(i)) != s.objectConstructSig(bt, @intCast(i))) return false;
        }
    }
    return true;
}

/// Do two references to the SAME generic carry arguments that make them the
/// same type — variance not consulted, and none needed? See
/// `nominalHeritageRelated` for why `any` counts and `unknown` does not.
fn heritageArgsIdentical(c: *const Checker, a: TypeId, b: TypeId) bool {
    if (a == b) return true;
    const s = &c.ts;
    const aa = s.refArgs(a);
    const ba = s.refArgs(b);
    if (aa.len != ba.len) return false;
    for (aa, ba) |x, y| {
        if (x == y) continue;
        switch (s.kind(y)) {
            .any, .err => {},
            else => return false,
        }
    }
    return true;
}

/// The `extends` heritage `sym` DECLARES, as references written in terms of
/// `sym`'s own type parameters, memoized per symbol.
///
/// A class contributes its single `extends` base; an interface contributes
/// every `extends` clause of every reopened block; a merged class+interface
/// symbol contributes both, which is how drizzle's `declare class Table` /
/// `interface Table extends SQLWrapper {}` pair reaches `SQLWrapper`. Anything
/// that is not a plain reference (a mixin expression, an `extends Array<T>`
/// that models as `.array`) is dropped — the fast path has nothing to say
/// about it and the structural walk still does.
///
/// Storage is per SYMBOL, not per type: a `BaseSpan` (8 bytes) in
/// `nominal_bases` plus four bytes per declared clause in
/// `nominal_base_pool`. Symbols with no heritage still take the map entry, so
/// the negative answer is a hash probe rather than a re-walk of the
/// declaration list.
pub fn declaredBaseRefs(c: *Checker, sym: SymbolId) Error![]const TypeId {
    if (c.nominal_bases.get(sym)) |e| return c.nominal_base_pool.items[e.start..][0..e.len];
    // Mark empty first: a heritage clause that resolves back through this
    // symbol reads "no bases" instead of recursing.
    try c.nominal_bases.put(c.cm(), sym, .{ .start = 0, .len = 0 });
    var out: std.ArrayList(TypeId) = .empty;
    defer out.deinit(c.scratch());
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |p| {
        const f = c.symFlags(p);
        if (f.class) {
            if (try c.baseClassRef(p)) |b| {
                if (c.ts.kind(b) == .ref) try out.append(c.scratch(), b);
            }
        }
        if (f.interface) {
            const saved_ctx = c.enterSymFile(p);
            defer c.restoreCtx(saved_ctx);
            const saved_this = c.this_type;
            defer c.this_type = saved_this;
            try c.setInterfaceThis(sym);
            var bases: std.ArrayList(TypeId) = .empty;
            defer bases.deinit(c.scratch());
            try c.interfaceHeritageTypes(p, &bases);
            for (bases.items) |b| {
                if (c.ts.kind(b) == .ref) try out.append(c.scratch(), b);
            }
        }
    }
    const start: u32 = @intCast(c.nominal_base_pool.items.len);
    try c.nominal_base_pool.appendSlice(c.cm(), out.items);
    const span: checker_zig.BaseSpan = .{ .start = start, .len = @intCast(out.items.len) };
    try c.nominal_bases.put(c.cm(), sym, span);
    return c.nominal_base_pool.items[span.start..][0..span.len];
}

/// One side's relation-memo key: the generic reference an OBJECT
/// materialization denotes (`refFacetOf`), the TypeId itself otherwise.
///
/// Restricted to `.object` on purpose. An interface/class instantiation is
/// fully determined by its origin ref, so two route-divergent materializations
/// of `G<A…>` pose one question and share one memo entry. The other
/// origin-tagged kinds are not: a recursive alias whose body is an
/// INTERSECTION is tagged with a ref that also stands for the lazy, unexpanded
/// spelling of itself, so keying the intersection by that ref makes the
/// expansion's own question indistinguishable from the ref's and answers it
/// from the in-progress mark (assignability/074 pins the resulting
/// under-report).
fn relKeyOf(ty: TypeId, k: types.Kind, facet: ?TypeId) TypeId {
    if (k != .object) return ty;
    return facet orelse ty;
}

fn relIdBucket(sym: SymbolId) usize {
    return @as(usize, sym) & (checker_zig.rel_id_buckets - 1);
}

/// Is the generic on the top of the live source (`src`) or target relation
/// stack GROWING — has it re-entered `max_relation_identity_repeats` times,
/// each time as a strictly LATER instantiation than the one before?
///
/// The "strictly later" half is what tells a runaway apart from an ordinary
/// recursive type, and it is tsc's own test (`isDeeplyNestedType`: "we only
/// count occurrences with a higher type id than the previous occurrence,
/// since otherwise we could infinitely recurse on types that are structurally
/// identical"). Types are interned in creation order, so a chain that keeps
/// building a bigger argument — zod's `Base<string, …>` → `Isec<Base<string,
/// …>, Any>` → `Base<any, IsecDef<…>, any>` → … — has a strictly increasing
/// ref id, while `Uint8Array<ArrayBufferLike>` meeting itself through its own
/// members does not, and neither does the second frame a lazy `.ref` and its
/// materialization occupy (they carry the SAME ref). Only the first is
/// unbounded; assuming the other two related loses real diagnostics
/// (excalidraw's `new Blob([…, new Uint8Array(…)])` TS2322 is the one that
/// caught it).
///
/// The bucket counter is an exact upper bound on the occurrences of any one
/// symbol in its bucket, so the scan runs only for a symbol that could
/// possibly qualify.
pub fn relIdDeeplyNested(c: *const Checker, src: bool) bool {
    const ids = if (src) &c.rel_src_ids else &c.rel_tgt_ids;
    const top = ids[c.rel_id_depth - 1];
    const buckets = if (src) &c.rel_src_buckets else &c.rel_tgt_buckets;
    const limit = checker_zig.max_relation_identity_repeats;
    // The bucket filter counts the WHOLE live stack, floor included, so it
    // stays a conservative pre-filter when a floor is set: it can only let
    // through a scan that then finds nothing, never skip one that would have
    // found something.
    if (buckets[relIdBucket(top.sym)] < limit) return false;
    var seen: u32 = 0;
    var last: TypeId = 0;
    for (ids[c.rel_id_floor..c.rel_id_depth]) |id| {
        if (id.sym != top.sym) continue;
        if (id.ref > last) {
            seen += 1;
            if (seen >= limit) return true;
        }
        last = id.ref;
    }
    return false;
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
/// Two shapes are covered, both sound for a SOURCE position — which is what
/// both callers are (the relation's source arm, and the APPARENT-TYPE read in
/// `props.zig`; tsc's substitution type reads as its intersection and writes as
/// its base type, so a read is exactly where the widening is legal).
///
///   * the branch IS the indexed access `O[check]` — index with the extends
///     type instead. Every instantiation has `K <: extends`, and `O[A | B]` is
///     `O[A] | O[B]`, so `O[K] <: O[extends]`.
///   * the branch IS the check type — `Extract<X, U>` (`X extends U ? X :
///     never`) and everything shaped like it — so the substituted branch is
///     just `X & U`. That is what gives a deferred `Extract` the members of the
///     type it extracts TO: `deeplyNestedConstraints`' `Extract<M[K],
///     ArrayLike<any>>` reads `array.length` off the `ArrayLike` half, where
///     the bare `M[K]` (apparent type `number | boolean | string | number[]`,
///     through `TypeMap<E>`'s template) has no `length` and was a TS2339.
///     The intersection is the whole answer — no exploration of the five
///     constraint levels the test's own comment mentions is needed for the
///     member lookup, because the extends type already names what survives.
///
/// `condTrueSubstituted` is the general form of the same reading and delegates
/// this case here, so the two cannot drift.
pub fn condTrueUnderExtends(c: *Checker, cond: TypeId) Error!TypeId {
    const s = &c.ts;
    const tru = s.condTrue(cond);
    const chk = s.condCheck(cond);
    const ext = s.condExtends(cond);
    // The same two declines `condTrueSubstituted` opens with: a check that IS
    // the extends type, and an `any`/`unknown` bound, both intersect to
    // nothing new.
    if (ext != chk and tru == chk) {
        switch (s.kind(ext)) {
            .any, .unknown => {},
            else => {
                const sub = try s.makeIntersection(c.scratch(), &.{ chk, ext });
                if (sub != chk) return sub;
            },
        }
    }
    if (s.kind(tru) != .index_access) return tru;
    if (s.indexAccessIndex(tru) != chk) return tru;
    return c.reduceIndexedAccess(s.indexAccessObj(tru), ext);
}

/// The same reading of a true branch as `condTrueUnderExtends`, for the other
/// place the check type occurs: as the OBJECT of an indexed access (or
/// anywhere else), rather than as its index. `T extends { _zod: { input: any
/// } } ? T["_zod"]["input"] : unknown` — zod's `core.input<T>` — is that
/// shape, and tsc reads its true branch as `(T & { _zod: … })["_zod"]["input"]`,
/// whose base constraint is the `any` the extends type declares.
///
/// Substituting the check type with the EXTENDS type is the same widening
/// `condTrueUnderExtends` performs, so it is likewise sound for a SOURCE
/// position only: on the true branch every instantiation has `check <:
/// extends`, and an indexed access is covariant in its object type.
///
/// Returns the branch unchanged unless the check type is a bare type
/// parameter (the only case a substitution can express), so a caller pays one
/// `instantiate` and only where the substitution can matter.
fn condTrueOverExtends(c: *Checker, cond: TypeId) Error!TypeId {
    const s = &c.ts;
    const chk = s.condCheck(cond);
    const tru = s.condTrue(cond);
    if (s.kind(chk) != .type_param) return tru;
    const map = [_]TpMap{.{ .sym = s.typeParamSymbol(chk), .ty = s.condExtends(cond) }};
    return c.instantiate(tru, &map);
}

/// The general form of the same reading, and the one tsc actually implements.
/// Every reference to the check type inside a conditional's TRUE branch is
/// wrapped in a *substitution type* whose constraint is the extends type
/// (`getConditionalFlowTypeOfType` → `getImpliedConstraint`), and a
/// substitution type READ — a source position — is its intersection:
///
/// ```ts
/// type.flags & TypeFlags.Substitution ? writing ? (type as SubstitutionType).baseType
///                                              : getSubstitutionIntersection(type)
/// // getSubstitutionIntersection = getIntersectionType([constraint, baseType])
/// ```
///
/// So `V extends { a: 1 } ? V : …` reads its true branch as `V & { a: 1 }`, not
/// as the bare `V`. That is what makes a generic signature relate to ITSELF
/// through such a branch: `<V>(v: V) => V extends {a: 1} ? V : V & {a: 1}` is
/// assignable to `<V>(v: V) => V & {a: 1}` in tsgo 7.0.2, and once the source
/// has been instantiated in the target's context the two `V`s are ONE, so the
/// return relation is exactly `(V extends {a: 1} ? V : V & {a: 1}) → V & {a: 1}`
/// — the true branch's bare `V` is the only half that does not relate.
///
/// The INTERSECTION is load-bearing, which is why this is not
/// `condTrueOverExtends`: substituting the extends type ALONE loses the check
/// type, and tsgo accepts the same conditional against a bare `V` target
/// (`{a: 1}` does not relate to `V`, `V & {a: 1}` does). Both readings are
/// sound only in a SOURCE position — on the true branch every instantiation
/// has `check <: extends`, so `check` and `check & extends` have the same
/// inhabitants there.
///
/// An `infer` binder used as a check type gets the same treatment — tsc's
/// `getImpliedConstraint` reads the check type through `getActualTypeVariable`,
/// which unwraps an infer binder to the type variable it declares. That is not
/// an exotic shape: a CONSTRAINED `infer T extends C` desugars into exactly one
/// nested conditional per binder (`inferConstraintFallback` in `generics.zig`
/// walks the same wrappers), so `V extends {p?: infer T extends "x"} ? V & {p:
/// T} : never` carries `T extends "x" ? V & {p: T} : never` as its true branch
/// and needs `T` there to read as `T & "x"`. atproto's `$TypedObject<V, Id,
/// Hash>` — the social-app's 51 false positives — bottoms out in that binder.
///
/// Returns the branch unchanged where tsc's `getSubstitutionType` declines to
/// build one at all: a check type that is no type variable (no reference to
/// substitute), a constraint that IS the base type, and an `any`/`unknown`
/// constraint — which intersects to nothing new. And in one place tsc does not
/// need to decline, because a substitution type is a WRAPPER it can strip
/// (`getRestrictiveInstantiation`) while ztsc has to instantiate eagerly: a
/// true branch that carries deferred machinery of its own. See
/// `substitutableBranch`.
/// tsc's `getInferredTrueTypeFromConditionalType`, the DEFERRED case — the
/// third reading of a true branch, and the one that decides `Awaited<T>`.
///
/// ```ts
/// return type.combinedMapper
///     ? instantiateType(getTypeFromTypeNode(type.root.node.trueType), type.combinedMapper)
///     : getTrueTypeFromConditionalType(type);
/// ```
///
/// `combinedMapper` binds the conditional's own `infer` binders. When the
/// check type is DEFERRED, `getConditionalType` never runs `inferTypes` at
/// all, so every binder comes out of `getInferredType` with no candidate and
/// no default — `unknown`. The true branch is then read with `unknown` in each
/// binder's place, which frequently RESOLVES a nested conditional that tests
/// one of them, and that resolution is the whole point:
///
/// ```ts
/// type Awaited<T> = T extends null | undefined ? T
///     : T extends object & { then(onfulfilled: infer F, ...args: infer _): any }
///         ? F extends (value: infer V, ...args: infer _) => any ? Awaited<V> : never
///         : T;
/// ```
///
/// The middle conditional's true branch tests `F`. With `F := unknown`,
/// `unknown extends (value: …) => any` is FALSE, so that whole branch is
/// `never` — and the branch union of `Awaited<T>` collapses to `T | never |
/// T` = `T`. That is why tsgo accepts `Awaited<T>` as a `T` (oracle-pinned for
/// a bare `T`, a constrained one, `T[K]` and `T["p"]` alike), and why ztsc —
/// which kept `F` symbolic and therefore kept `Awaited<V>` in the union —
/// invented a TS2322 on every async function that returns a
/// `Promise.resolve<T[K]>(…)` into a `Promise<T[K]>` (`asyncFunctionReturnType`
/// lines 51 / 71 / 75).
///
/// Only the one shape that pays for itself is read, and it is read WITHOUT
/// building a type. The general form — `substInfer` every binder with
/// `unknown` and let the substitution re-reduce whatever it lands on — is the
/// blow-up `substitutableBranch` already documents, and TypeBox is again the
/// measurement: `@sinclair/typebox` went from 449M to 12.4G instructions and
/// 15.8MB to 73.5MB peak RSS (+2660% / +366%), because its accumulator
/// conditionals desugar a CONSTRAINED binder into one nested conditional per
/// binder and each rewrite re-enters a recursive alias with a fresh argument.
///
/// So: the true branch must ITSELF be a conditional whose CHECK is a binder
/// (the only place `unknown` can decide anything), the branch that `unknown`
/// selects is read straight off that conditional, and it is used only when it
/// mentions no binder at all — which is what makes it a complete answer rather
/// than a half-substituted one. `unknown extends X` is true only for an
/// `unknown` or `any` `X`, so the decision is two integer comparisons; the
/// selected branch is an existing interned type, so nothing is constructed.
/// Awaited's `never` is exactly this shape, and TypeBox's is not — it bails on
/// the `containsInfer` test and the relation behaves as it did before
/// (re-measured: typebox back to +0.2% instructions, within noise).
///
/// Additive, like the other two readings: the branch is returned untouched
/// unless all three tests pass, and a branch it does replace can only make the
/// relation succeed where the bare branch already failed.
fn condTrueInferBound(c: *Checker, cond: TypeId) Error!TypeId {
    const s = &c.ts;
    const tru = s.condTrue(cond);
    if (s.kind(tru) != .conditional) return tru;
    if (s.kind(s.condCheck(tru)) != .infer_var) return tru;
    const ext_kind = s.kind(s.condExtends(tru));
    const picked = if (ext_kind == .unknown or ext_kind == .any)
        s.condTrue(tru)
    else
        s.condFalse(tru);
    if (try c.containsInfer(picked)) return tru;
    return picked;
}

fn condTrueSubstituted(c: *Checker, cond: TypeId) Error!TypeId {
    const s = &c.ts;
    const chk = s.condCheck(cond);
    const tru = s.condTrue(cond);
    const chk_kind = s.kind(chk);
    const ext = s.condExtends(cond);
    if (ext == chk) return tru;
    switch (s.kind(ext)) {
        .any, .unknown => return tru,
        else => {},
    }
    // The check type need not be a type VARIABLE. tsc runs every type node
    // through `getTypeFromTypeNode` → `getConditionalFlowTypeOfType`, and
    // `getImpliedConstraint` compares the branch's type against the CHECK
    // NODE's type — so a true branch that IS the check type is substituted
    // whatever kind that type is. `Extract<any[], T>` (`any[] extends T ?
    // any[] : never`, `inlineConditionalHasSimilarAssignability`) is that
    // shape with a concrete check: its true branch reads as `any[] & T`,
    // which IS assignable to `T`, while the bare `any[]` is not.
    //
    // Answered by `condTrueUnderExtends` rather than in the type-variable path
    // below because it needs no rewrite at all — the branch is the check type,
    // so the substituted branch is the intersection itself, and that is the
    // one case the two readings share.
    if (tru == chk) return condTrueUnderExtends(c, cond);
    if (chk_kind != .type_param and chk_kind != .infer_var) return tru;
    if (!try substitutableBranch(c, tru, 0)) return tru;
    const sub = try s.makeIntersection(c.scratch(), &.{ chk, ext });
    if (sub == chk) return tru;
    if (chk_kind == .infer_var) {
        return generics_zig.substInfer(c, tru, &.{s.inferVarId(chk)}, &.{sub});
    }
    const map = [_]TpMap{.{ .sym = s.typeParamSymbol(chk), .ty = sub }};
    return c.instantiate(tru, &map);
}

/// How far the false-branch chain below is followed. `ZeroOf<T>` (five nested
/// conditionals) is the shape that needs more than one step; beyond this the
/// walk gives the constraint up and the branch-union reading stands.
const max_cond_constraint_steps: u32 = 16;

/// tsc's `getConstraintOfDistributiveConditionalType`: the constraint you get
/// by putting the check parameter's own constraint in the check position,
/// or `null` when the parameter's bound settles nothing the branch union did
/// not already say.
///
/// ```ts
/// type IsArray<T> = T extends unknown[] ? true : false;
/// function f<T extends unknown[]>(x: IsArray<T>) { const t: true = x; }  // ok
/// ```
///
/// Every instantiation of `T` is a subtype of `unknown[]`, so every
/// instantiation of `IsArray<T>` is `true` — a fact the branch-union reading
/// (`true | false`) cannot see. tsc computes it by re-evaluating the
/// conditional with `T := constraint`.
///
/// The re-evaluation is NOT the ordinary one. `object extends unknown[]` is
/// `false` as a type of its own, but `IsArray<T>` under `T extends object`
/// stays `boolean` in tsgo, because an `object` may still BE an array: the
/// constraint bounds `T` from above and settles the conditional only when the
/// bound settles EVERY instantiation. So each level decides three ways:
///
///   * `constraint` is assignable to the extends type — every `T` takes the
///     true branch;
///   * no constituent of the extends type is assignable to `constraint` — no
///     `T` can satisfy it, so every `T` takes the false branch (and a false
///     branch that is another conditional on the same parameter is walked, the
///     `ZeroOf<T>` chain);
///   * otherwise undecided — no distributive constraint at all, and the caller's
///     branch-union answer stands.
///
/// Purely additive wherever it is consumed: `null` means "the branch union is
/// still the answer", and a type means the branch union with branches no
/// instantiation can reach dropped — never a wider reading.
pub fn distributiveConstraint(c: *Checker, cond: TypeId) Error!?TypeId {
    const s = &c.ts;
    if (!s.condDistributive(cond)) return null;
    const chk = s.condCheck(cond);
    if (s.kind(chk) != .type_param) return null;
    const con = try c.typeParamConstraint(s.typeParamSymbol(chk));
    if (con == types.no_type or con == chk or con == types.error_type) return null;
    switch (s.kind(con)) {
        // An `unknown`/`any` bound settles nothing the branch union did not.
        .unknown, .any => return null,
        // tsc's `instantiateConditionalType`: a DISTRIBUTIVE conditional whose
        // check parameter is replaced by a UNION is re-evaluated once per
        // constituent and the results unioned (`mapTypeWithAlias`). Asking the
        // walk about `number | string` whole settles nothing — no single branch
        // of `T extends number ? 0 : T extends string ? "" : false` covers it —
        // while per constituent it settles completely, which is why `ZeroOf<T>`
        // under `T extends number | string` is `0 | ""` and `let z2: 0 | "" = y`
        // is legal (`conditionalTypes1` f21, oracle-verified).
        //
        // All or nothing: one undecided constituent leaves the whole reading
        // undecided, and the caller's branch union — which is what an undecided
        // constituent would contribute anyway — stands for every constituent.
        .union_type => {
            const parts_in = try c.memberList(con);
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (parts_in) |m| {
                const r = (try constraintWalk(c, cond, chk, m)) orelse return null;
                try parts.append(c.scratch(), r);
            }
            return try s.makeUnion(c.scratch(), parts.items);
        },
        else => {},
    }
    return constraintWalk(c, cond, chk, con);
}

/// tsc's `isDistributionDependent`, the ONE guard on the both-branches reading
/// of a conditional TARGET (`structuredTypeRelatedTo`'s `Conditional` arm):
///
/// ```ts
/// return root.isDistributive && (
///     isTypeParameterPossiblyReferenced(root.checkType, root.node.trueType) ||
///     isTypeParameterPossiblyReferenced(root.checkType, root.node.falseType));
/// ```
///
/// A DISTRIBUTIVE conditional whose branches name the check parameter is not
/// the union of its two branches — it is a union with one member per
/// constituent of whatever the parameter turns out to be, and each of those
/// members has that constituent substituted INTO the branch. So `S` satisfying
/// both branches as WRITTEN says nothing about `S` satisfying the result, and
/// answering yes there is a false negative on the assignment.
///
/// `Stuff<T> = T extends keyof JSX.IntrinsicElements ? JSX.IntrinsicElements[T]
/// : any` is the witness (`conditionalTypeVarianceBigArrayConstraints
/// Performance`): `p1 = p2` between `Stuff<T>` and `Stuff<U>` for two unrelated
/// parameters is an error, and the `any` false branch made the both-branches
/// rule accept it.
///
/// `tpMentions` saturates rather than enumerate a signature's own parameters,
/// and a saturated set answers TRUE here — which is the conservative direction:
/// tsc's own test is "POSSIBLY referenced".
fn distributionDependent(c: *Checker, cond: TypeId) Error!bool {
    const s = &c.ts;
    // tsc's `root.isDistributive` is exactly "the check type is a naked type
    // parameter"; ztsc records the flag at construction and the kind test is
    // what tells a naked parameter from a substituted one.
    if (!s.condDistributive(cond)) return false;
    const chk = s.condCheck(cond);
    if (s.kind(chk) != .type_param) return false;
    const sym = s.typeParamSymbol(chk);
    return (try branchMentionsParam(c, s.condTrue(cond), sym)) or
        (try branchMentionsParam(c, s.condFalse(cond), sym));
}

fn branchMentionsParam(c: *Checker, branch: TypeId, sym: u32) Error!bool {
    const m = try c.tpMentions(branch);
    if (m.saturated) return true;
    return std.mem.indexOfScalar(u32, m.syms, sym) != null;
}

/// One pass of `distributiveConstraint`'s three-way decision down the
/// false-branch chain, with `sub` — the whole constraint, or one constituent of
/// it — standing in for the check parameter `chk`. `null` = undecided.
fn constraintWalk(c: *Checker, cond: TypeId, chk: TypeId, sub: TypeId) Error!?TypeId {
    const s = &c.ts;
    const map = [_]TpMap{.{ .sym = s.typeParamSymbol(chk), .ty = sub }};
    var cur = cond;
    var steps: u32 = 0;
    while (steps < max_cond_constraint_steps) : (steps += 1) {
        const ext = try c.instantiate(s.condExtends(cur), &map);
        if (try c.isAssignable(sub, ext)) return try c.instantiate(s.condTrue(cur), &map);
        if (try extendsReachableFrom(c, ext, sub)) {
            // Undecided. What is left of the chain is a deferred conditional
            // again, and a deferred conditional's constraint is the union of
            // its branches — the caller's own reading, but over the branches
            // the levels ABOVE have already ruled out. With nothing ruled out
            // it is the caller's answer verbatim, so there is nothing to add.
            if (steps == 0) return null;
            return try remainingBranchUnion(c, cur, &map);
        }
        const fls = s.condFalse(cur);
        if (s.kind(fls) == .conditional and s.condCheck(fls) == chk and s.condDistributive(fls)) {
            cur = fls;
            continue;
        }
        return try c.instantiate(fls, &map);
    }
    return null;
}

/// The branch union of a conditional whose check the constraint did not settle
/// — tsc's `getDefaultConstraintOfConditionalType`, applied down the false-branch
/// chain because each nested conditional's own default constraint is again its
/// branch union.
///
/// Walks the chain instead of instantiating it: substituting the constraint into
/// a nested conditional would RESOLVE it (its check is concrete by then) and
/// throw away branches tsc keeps.
fn remainingBranchUnion(c: *Checker, cond: TypeId, map: []const TpMap) Error!TypeId {
    const s = &c.ts;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    var cur = cond;
    var steps: u32 = 0;
    while (steps < max_cond_constraint_steps) : (steps += 1) {
        try parts.append(c.scratch(), try c.instantiate(s.condTrue(cur), map));
        const fls = s.condFalse(cur);
        if (s.kind(fls) != .conditional) {
            try parts.append(c.scratch(), try c.instantiate(fls, map));
            break;
        }
        cur = fls;
    }
    return s.makeUnion(c.scratch(), parts.items);
}

/// Could some instantiation of a parameter bounded by `con` satisfy `extends
/// ext`? tsc's approximation, and the one its own results pin: yes exactly when
/// some CONSTITUENT of `ext` is assignable to `con`.
///
/// `T extends string` against `extends "abc" | 42` is the case that needs the
/// union split — `"abc" | 42` is not assignable to `string`, but `"abc"` is, so
/// a `T` of `"abc"` takes the true branch and the conditional stays undecided
/// (tsgo reports `boolean` there, not `false`).
fn extendsReachableFrom(c: *Checker, ext: TypeId, con: TypeId) Error!bool {
    if (c.ts.kind(ext) == .union_type) {
        for (try c.memberList(ext)) |m| {
            if (try c.isAssignable(m, con)) return true;
        }
        return false;
    }
    return c.isAssignable(ext, con);
}

/// Whether a true branch is cheap to rewrite: an ALLOWLIST of type shapes that
/// an `instantiate` finishes in one pass over what is already materialized.
///
/// tsc pays nothing to substitute, because its substitution type is a wrapper
/// around the check type that every consumer can strip; ztsc has no such node
/// and must build the rewritten branch. Rewriting a branch that re-enters
/// DEFERRED machinery is where that stops being a constant: TypeBox's
/// accumulator conditionals are all
///
///     T extends [infer L extends S, ...infer R extends S[]]
///         ? TFilterNever<R, [...Acc, L]>
///         : Acc
///
/// so the branch is a recursive alias applied to the very binder being
/// substituted. `TFilterNever<R & S[], …>` is a type the memos have never seen,
/// its expansion re-enters with another fresh argument, and the recursion
/// re-runs from scratch at every level — measured at 0.19s/17MB -> 5.6s/222MB on
/// `@sinclair/typebox` with a TS2589 at the end of it.
///
/// The shapes the substitution is FOR are all on this list: a bare check type
/// (`V extends X ? V : …`), and an intersection of one with an object literal
/// (`V & {$type: T}`, atproto's `$TypedObject` after its constrained `infer`
/// desugars). A branch that is itself a conditional does not need substituting
/// — its own check type gets the treatment when the relation reaches it.
fn substitutableBranch(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 3) return false;
    const s = &c.ts;
    return switch (s.kind(t)) {
        .type_param, .infer_var => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (!try substitutableBranch(c, m, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (s.objectHasSigs(t)) break :blk false;
            if (s.objectStringIndex(t) != types.no_type) break :blk false;
            if (s.objectNumberIndex(t) != types.no_type) break :blk false;
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                if (!try substitutableBranch(c, p.ty, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .array => substitutableBranch(c, s.arrayElem(t), depth + 1),
        // Primitives and literals carry nothing to substitute, so a branch
        // built only out of them (with the check type somewhere among them)
        // rewrites in one pass.
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
        .unique_symbol,
        .null,
        .undefined,
        .void,
        .never,
        .any,
        .unknown,
        .object_keyword,
        => true,
        else => false,
    };
}

/// tsc's `structuredTypeRelatedTo`, conditional source against conditional
/// target: the two `extends` types have to be identical, but the two CHECK
/// types need only be related in EITHER direction
/// (`isRelatedTo(source.checkType, target.checkType) ||
/// isRelatedTo(target.checkType, source.checkType)`). Both conditionals then
/// resolve the same way for any substitution that makes either check type
/// concrete, so the pair relates branch-wise.
///
/// ztsc used to require the check types to be EQUAL, which is what made a
/// DECLARATION-SITE VARIANCE MEASUREMENT of a parameter used behind such a
/// conditional come out INVARIANT. The measurement substitutes the
/// `sub`/`super` marker pair for the parameter (`measureOneVariance`) — a
/// pair of check types related in exactly one direction — so neither
/// `G<sub> → G<super>` nor its reverse could get past the conditional, and
/// two instantiations of the generic then had to agree exactly.
///
/// zod v4 is built on that shape: `$ZodPipeDef<A, B>` carries
/// `transform?: (…) => util.MaybeAsync<core.input<B>>` and
/// `reverseTransform?: (value: core.input<B>, …) => util.MaybeAsync<core.output<A>>`,
/// and `core.input<T>` is the deferred conditional
/// `T extends { _zod: { input: any } } ? T["_zod"]["input"] : unknown`. With
/// `A`/`B` measured invariant rather than bivariant, every
/// `ZodObject<…> → ZodType<Record<string, unknown>>` — the
/// `validate(Schema)` middleware signature all over outline's routes — failed
/// structurally on the `ZodPipe<…>` that `transform` returns.
///
/// Additive: every caller falls through to its previous rule on `false`.
fn condBranchwiseRelated(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    const st = &c.ts;
    // The source's own `infer` binders are re-bound to the target's first, so
    // that two conditionals written the same way but DECLARED separately still
    // meet the identity test below — see `rebindCondInferVars`.
    var s_ext = st.condExtends(s);
    var s_tru = st.condTrue(s);
    if (s_ext != st.condExtends(t)) {
        if (try c.rebindCondInferVars(s, t)) |r| {
            s_ext = r.extends;
            s_tru = r.true_branch;
        }
    }
    if (s_ext != st.condExtends(t)) return false;
    const s_chk = st.condCheck(s);
    const t_chk = st.condCheck(t);
    if (s_chk != t_chk) {
        if (!(try c.isAssignable(s_chk, t_chk)) and !(try c.isAssignable(t_chk, s_chk))) return false;
    }
    const tru_ok = (try c.isAssignable(s_tru, st.condTrue(t))) or
        (try c.isAssignable(try condTrueOverExtends(c, s), st.condTrue(t)));
    return tru_ok and try c.isAssignable(st.condFalse(s), st.condFalse(t));
}

pub fn isCompound(k: types.Kind) bool {
    return switch (k) {
        .union_type, .intersection, .array, .tuple, .object, .function, .overloads, .ref, .class_value, .conditional, .mapped, .index_access, .template_literal_type, .keyof_op => true,
        else => false,
    };
}

/// A target NO object type can ever be assignable to — tsc's non-
/// `StructuredOrInstantiable` targets, minus the ones an object DOES reach
/// (`object`, `Function`, an enum's nominal rule, `any`/`unknown`, which are
/// all settled before this is consulted). Used to answer an interface/class
/// reference against a primitive without expanding it.
fn primitiveOnlyTarget(k: types.Kind) bool {
    return switch (k) {
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
        .unique_symbol,
        .null,
        .undefined,
        => true,
        else => false,
    };
}

pub fn isAssignableInner(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
    // A TARGET that is a lazy alias self-reference, the twin of the `.ref`
    // SOURCE rule further down. `aliasInstance`'s cycle cut leaves `ref(A, args)` for every
    // reference taken while `A`'s body was still materializing, so a MUTUALLY
    // recursive pair spells one type two ways: the reference the user writes
    // expands to the union, the one inside the partner alias's body stays the
    // ref. The two must still meet.
    //
    //     type Cond<T> = T extends unknown[] ? never : { q: T };
    //     type R2<T>   = Cond<T> | Tup<T>;
    //     type Tup<T>  = ["marker", ...R2<T>[]];
    //
    // `Tup<T>`'s rest element is `ref(R2, [T])`, so relating a written
    // `["marker", ...R2<T>[]]` to `Tup<T>` compares the EXPANSION of `R2<T>`
    // against that ref element-wise, and the target-union branch below — the
    // one that would have found the matching constituent — never runs because
    // the target's kind is `.ref` (`recursiveReverseMappedType`, and the b1 /
    // b4 / b6 shapes of the wave-48 repro).
    //
    // Scoped to a ref whose symbol is a type ALIAS ON A CYCLE, which is
    // exactly the set the cut produces: an interface or class instance is an
    // object for every argument list and can never be the union this is
    // looking for, and a non-cyclic alias reference was already materialized
    // by `aliasInstance` rather than left as a ref.
    if (tk == .ref and c.symFlags(c.ts.refSymbol(t)).type_alias and
        c.alias_recursive.contains(c.ts.refSymbol(t)))
    {
        const rt = try c.resolveStructural(t);
        if (rt != t and c.ts.kind(rt) == .union_type) return c.isAssignable(s, rt);
    }
    // Deferred conditional *source* is handled first (before union
    // distribution): it resolves to one of its branches, so it is
    // assignable to `t` exactly when *both* branches are — even when `t`
    // is a union. Identity is already caught by `s == t` (hash-consed).
    if (sk == .conditional) {
        if (tk == .conditional and c.ts.condCheck(s) == c.ts.condCheck(t) and c.ts.condExtends(s) == c.ts.condExtends(t)) {
            return (try c.isAssignable(c.ts.condTrue(s), c.ts.condTrue(t))) and
                (try c.isAssignable(c.ts.condFalse(s), c.ts.condFalse(t)));
        }
        if (tk == .conditional and try condBranchwiseRelated(c, s, t)) return true;
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
                if (try condBranchwiseRelated(c, s, rm)) return true;
            }
        }
        // Everything below asks the TARGET to accept a reading of the source —
        // a branch, or the distributive constraint — and a target that
        // DISTRIBUTES over its check parameter and names it in a branch has no
        // such answer to give (`distributionDependent`, tsc's guard on its own
        // conditional-target arm). Placed after the two rules that compare the
        // two conditionals AS conditionals, which do not consult the target's
        // branches in isolation.
        if (tk == .conditional and try distributionDependent(c, t)) return false;
        // Both readings of the true branch under the extends assumption, the
        // cheap special case first (`condTrueUnderExtends` rewrites one index
        // without instantiating anything). Additive: the substitution can only
        // make a branch relate that the bare branch did not.
        const tru_ok = (try c.isAssignable(try c.condTrueUnderExtends(s), t)) or
            (try c.isAssignable(try condTrueSubstituted(c, s), t)) or
            (try c.isAssignable(try condTrueInferBound(c, s), t));
        if (tru_ok and (try c.isAssignable(c.ts.condFalse(s), t))) return true;
        // Only now — with the both-branches reading already refused — is the
        // narrower DISTRIBUTIVE constraint worth computing. tsc tries it first
        // and falls back to the branch union; the two are alternatives for a
        // single boolean, so running the cheap one first costs a clean program
        // nothing.
        if (try distributiveConstraint(c, s)) |dc| return c.isAssignable(dc, t);
        return false;
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
        // A UNION target is decided member-by-member before the source is
        // widened, for exactly the same reason: tsc's
        // `unionOrIntersectionRelatedTo` runs ahead of the source-Index arm
        // in `structuredTypeRelatedTo`, so `keyof T` meets a union that
        // CONTAINS `keyof T` by identity. Widened first, the answer is
        // `string | number | symbol` against a union of key literals plus
        // that very `keyof T` — no. `keyof (A & B)` distributes to
        // `keyof A | keyof B`, so this is every relation between two
        // intersections that share a generic constituent
        // (`homomorphicMappedTypeIntersectionAssignability`).
        if (tk == .union_type) {
            for (try c.memberList(t)) |m| {
                if (try c.isAssignable(s, m)) return true;
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
    // Source union distributes first — and HOW it distributes is the relation's
    // first difference. tsc:
    //
    // ```ts
    // if (source.flags & TypeFlags.Union) {
    //     result = relation === comparableRelation ?
    //         someTypeRelatedToType(source as UnionType, target, …) :
    //         eachTypeRelatedToType(source as UnionType, target, …);
    // }
    // ```
    //
    // Assignability needs EVERY constituent to fit (a value of the union type
    // may be any of them); comparability asks only whether the two types
    // OVERLAP, so one constituent that fits is a witness. That is what makes
    // `{ fn(a?: Base): void } < { fn(a?: C): void }` legal in tsgo with `Base`
    // and `C` unrelated: the parameters are `Base | undefined` and
    // `C | undefined`, and `undefined` is the overlap. Sixteen keys in
    // `comparisonOperatorWithNoRelationshipObjectsOnOptionalProperty` and the
    // optional-parameter half of `…OnCallSignature`/`…OnConstructorSignature`.
    if (sk == .union_type) {
        if (c.rel_kind == .comparable) {
            for (try c.memberList(s)) |m| {
                if (try c.isAssignable(m, t)) return true;
            }
            return false;
        }
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
    // An interface/class instance is an object for every argument list, so it
    // is never the union this rule is looking for and its member table need
    // not be materialized to say so (see `refExpandsToObject`).
    if (sk == .ref and tk == .union_type and !c.refExpandsToObject(s)) {
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
        // tsc's `getSimplifiedIndexedAccessType` runs BEFORE the constraint
        // route (`getSimplifiedTypeOrConstraint` asks for it first): an
        // access whose object is a generic MAP is the map's template with
        // the key substituted, no constraint needed. `Readonly<Partial<T>>`'s
        // `Partial<T>[P]` is `T[P]`, which is what makes it a `Partial<T>`.
        //
        // The READ reading of the simplification: this is a VALUE of type
        // `M[K]` being handed to a `T`, so the map's `+?` is part of what it
        // may hold (`simplifyMappedIndexAccessRead`). `y: Partial<T>` makes
        // `y[k]` a `T[k] | undefined`, which is not a `T[k]`.
        if (try simplifyMappedIndexAccessRead(c, s)) |sim| {
            if (try c.isAssignable(sim, t)) return true;
        }
        // An access whose OBJECT is a conditional distributes over the two
        // branches — tsc's `getSimplifiedIndexedAccessType` rewrites
        // `(T extends U ? X : Y)[K]` as `T extends U ? X[K] : Y[K]` — and a
        // conditional source relates when BOTH its branches do (the rule the
        // `.conditional` arm above applies directly). The true branch is read
        // under the extends assumption, exactly as that arm reads it.
        //
        // `Assume<T, U> = T extends U ? T : U` indexed by a property name is
        // the shape: drizzle's `PreparedQueryKind<…, true>["execute"]` asserts
        // an HKT application down to `MySqlPreparedQuery<TConfig>` and then
        // reads its `execute` off it, and without the distribution the whole
        // access could only go through its base constraint — which substitutes
        // the free parameters nested inside it and loses `TConfig` entirely.
        //
        // Both rewrites must land somewhere new: a branch that reduces back to
        // this very access would re-ask this frame's own question and read its
        // in-progress mark as a yes.
        //
        // Runs AFTER the constraint route below, not before it as tsc's own
        // simplification does: the two are alternatives for one boolean, both
        // purely additive, and the constraint route answers the overwhelming
        // majority of accesses without materializing two branches. Ordering it
        // first cost drizzle measurably and bought nothing.
        const obj_bc = try relationIndexObjConstraint(c, c.ts.indexAccessObj(s));
        // Same two guards as the target rule: neither side may still be
        // generic after taking base constraints.
        const idx_bc = try relationIndexKeyConstraint(c, c.ts.indexAccessIndex(s));
        if (!try c.isGenericObjectForIndex(obj_bc) and !try c.containsFreeTypeParam(idx_bc.ty, &.{}) and
            try keyDomainAnswerable(c, obj_bc, idx_bc.from_keyof))
        {
            const bc = try c.reduceIndexedAccess(obj_bc, idx_bc.ty);
            if (bc != s and c.ts.kind(bc) != .unknown and try c.isAssignable(bc, t)) return true;
        }
        if (c.ts.kind(c.ts.indexAccessObj(s)) == .conditional) {
            const cond = c.ts.indexAccessObj(s);
            const idx = c.ts.indexAccessIndex(s);
            const tru = try c.reduceIndexedAccess(try condTrueSubstituted(c, cond), idx);
            const fls = try c.reduceIndexedAccess(c.ts.condFalse(cond), idx);
            if (tru != s and fls != s and
                try c.isAssignable(tru, t) and try c.isAssignable(fls, t)) return true;
        }
    }
    // A generic TEMPLATE-LITERAL source, the same rule one kind over: a
    // template whose hole is a type variable relates through its base
    // constraint (tsc's `structuredTypeRelatedTo` reaches
    // `getBaseConstraintOfType` for every `TypeFlags.Instantiable` source).
    // `` `excluded.${T}` `` with `T extends keyof AssetExifTable` instantiates
    // to `` `excluded.${'assetId' | 'description' | …}` ``, which expands to
    // exactly the union of column references kysely's `eb.ref` wants.
    //
    // Ahead of the union-target arm for the reason the indexed-access rule is
    // (it would answer for the whole target first), and purely additive: a
    // template whose base constraint is itself, or does not relate, falls
    // through unchanged.
    if (sk == .template_literal_type) {
        const bc = try c.baseConstraintOf(s);
        if (bc != s and try c.isAssignable(bc, t)) return true;
    }
    // An intersection SOURCE one of whose constituents IS the target, or is a
    // CONSTITUENT of a union target: `A & B` is related to `A`, and to
    // anything `A` alone is a constituent of, by construction — for any `A`.
    //
    // The general rule lives further down (`sk == .intersection`: some
    // constituent RELATES to the target, `someTypeRelatedToType`), and this is
    // just its identity case — but the identity case has to be hoisted above
    // the target-union arm below, because that arm decomposes the target
    // first: it asks `A & B` against each of the union's members in turn, and
    // the general rule then asks `A` against each member in turn, for a walk
    // quadratic in the union's size over a question two integer comparisons
    // answer. tsc never has to hoist anything, because its identity case IS
    // `isRelatedTo`'s `source === target` line and its union membership test
    // is `typeRelatedToSomeType`'s `containsType` — both reached before the
    // per-member loop, and both O(1)/O(log n).
    //
    // `compiler/relationComplexityError.ts` is what this costs: `Digits⁴` is
    // a 4096-member union, `T1 & T2` distributes to an 8192-member union of
    // intersections (`Store.makeIntersection`, tsc's
    // `getCrossProductIntersections`), and relating the two spent 33.5M
    // relation steps and 4.4 seconds on a pair whose every constituent is
    // `lit & { a: string }` against a union that literally contains `lit`.
    //
    // Sound in one line: `s <: m` for every constituent `m` of an
    // intersection, and `m <: t` whenever `t` is a union with `m` among its
    // constituents, so `s <: t`. It can only ever turn a NO into a YES, and
    // only for a pair that was already relatable through the general rule.
    //
    // Both member lists are read BORROWED (`ts.members`) rather than through
    // `memberList`, which dupes into the scratch arena: nothing in this loop
    // calls back into the checker, so neither slice can move under it, and an
    // allocation per intersection-source frame is not what a fast path is for.
    if (sk == .intersection) {
        const tms: []const TypeId = if (tk == .union_type) c.ts.members(t) else &.{};
        for (c.ts.members(s)) |m| {
            if (m == t) return true;
            if (unionHasMember(tms, m)) return true;
        }
        // tsc's `getNormalizedUnionOrIntersectionType`, whose own comment names
        // this exact shape:
        //
        // ```ts
        // if (type.flags & TypeFlags.Intersection && shouldNormalizeIntersection(type as IntersectionType)) {
        //     // Normalization handles cases like Partial<T>[K] & ({} | null) ==> Partial<T>[K] & {} | Partial<T>[K] & null
        //     return getIntersectionType(sameMap((type as IntersectionType).types, t => getNormalizedType(t, writing)));
        // }
        // ```
        //
        // ztsc interns `Partial<T>[K] & ({} | null)` already distributed, so
        // what arrives here is `{} & Partial<T>[K]`. The `undefined` that
        // access CARRIES (`simplifyMappedIndexAccessRead`) is invisible until
        // the access is simplified, and once it is, re-forming the
        // intersection lets the `{}` cancel it: `{} & (T[K] | undefined)`
        // distributes to `({} & T[K]) | ({} & undefined)`, whose second half
        // is an empty intersection. That is the whole of why
        // `NonNullable<Partial<T>[K]>` is a `T[K]`
        // (`indexedAccessAndNullableNarrowing` f3).
        //
        // Gated exactly as `shouldNormalizeIntersection` gates it — an
        // instantiable constituent AND a nullable-or-empty-object one — so an
        // ordinary branded intersection pays one scan of a short member list
        // and nothing else. Purely additive.
        if (try normalizedIntersection(c, s)) |ns| {
            if (try c.isAssignable(ns, t)) return true;
        }
    }
    if (tk == .union_type) {
        // A callable constituent decides for a callable source — see
        // `Checker.union_callable_sibling`. Only consulted while the weak-type
        // rule could fire (a callable source), so the scan costs nothing on
        // the overwhelming majority of union targets.
        const callable_sibling = try c.unionHasCallableMember(s, sk, t);
        if (callable_sibling) c.union_callable_sibling += 1;
        defer if (callable_sibling) {
            c.union_callable_sibling -= 1;
        };
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
            const constraint = try relationConstraintOf(c, s);
            if (constraint != types.no_type and try c.isAssignable(constraint, t)) return true;
        }
        // An INTERSECTION source whose constituent spans the union the same
        // way — tsc's `someTypeRelatedToType(source, target, …,
        // IntersectionState.Source)`, "any constituent of the intersection is
        // immediately related to the TARGET". The general intersection-source
        // arm below is never reached for a union target (this arm ends in
        // `return false`), and the per-member loop above asks the whole
        // intersection against one member at a time, which is a different
        // question: `<T extends string | number, U extends string | number>`
        // gives `x: T & U` a constituent constrained to exactly the target
        // union, and neither `T & U → string` nor `T & U → number` holds
        // (`intersectionWithUnionConstraint`, five false TS2322).
        //
        // Sound for any constituent — `A & B` is a subtype of `A` — but
        // restricted to INSTANTIABLE ones, which is where the gap actually is:
        // a concrete constituent spanning a union without fitting a member
        // would itself have to be a union, and `makeIntersection` distributes
        // those away. Keeping it narrow also keeps the failure path cheap; the
        // per-member loop above is already the expensive half of a union
        // target (see the identity-case hoist further up).
        //
        // …and failing that, the intersection's COMBINED constraint, which is
        // the `sk == .type_param` fallback above one kind out: tsc's
        // `getBaseConstraintOfType` of an intersection intersects the
        // constituents' constraints, and `getIntersectionType` distributes the
        // unions among them into their cross product, so
        // `T & U` for `T extends string | number | undefined` and
        // `U extends string | null | undefined` is constrained to exactly
        // `string | undefined` — a target no single constituent's constraint
        // fits. `baseConstraintOf` builds that same cross product through
        // `makeIntersection`.
        //
        // An intersection that still carries a `null`/`undefined` constituent
        // is excluded, exactly as the intersection-TARGET arm below excludes
        // it: `null & T` contributes no members and tsc refuses it, so
        // reaching `T`'s constraint through it would accept a value that has
        // none of them. excalidraw's `useOutsideClick` is the live case — the
        // `target` of `Event & { target: T }` is `(EventTarget | null) & T`,
        // whose `null` half is what tsc's TS2345 is about.
        if (sk == .intersection and !try c.hasNullishMember(s)) {
            var bare_param = false;
            for (try c.memberList(s)) |m| {
                const mk = c.ts.kind(m);
                if (mk == .type_param) bare_param = true;
                if (!isInstantiableKind(mk)) continue;
                if (try c.isAssignable(m, t)) return true;
            }
            // The cross product is only built for an intersection that names a
            // BARE type parameter — the shape whose constraint is a union in
            // the first place. A deferred access/conditional/map constituent
            // reduces to a constraint the per-constituent pass above has
            // already asked about, and drizzle's intersections are all of that
            // second kind (measured: the unrestricted call cost it ~1%).
            if (bare_param) {
                const bc = try c.baseConstraintOf(s);
                if (bc != s and try c.isAssignable(bc, t)) return true;
            }
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
        // The same rule for a TUPLE source. A tuple is an ordinary object
        // type in tsc — its elements are the properties `"0"`, `"1"`, … — so
        // `typeRelatedToDiscriminatedType` applies to it unchanged, and the
        // shape it decides is every "overloaded" argument list spelled as a
        // union of tuples. react-navigation's `navigate` is exactly that:
        // `navigate(...args: ["Home", undefined?, Opts?] | ["Search", …] | …)`,
        // and a call whose first argument is a route-name UNION builds the
        // spread tuple `["HomeTab" | "SearchTab"]` (tsc's
        // `getSpreadArgumentType`), which fits no single constituent.
        if (sk == .tuple) {
            if (try c.discriminatedTupleAssignable(s, t)) return true;
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
        // tsc's `IntersectionState.Target` for the weak-type check: the
        // intersection is judged weak as a WHOLE (above, in `relate`), never
        // one constituent at a time — `{a: 1}` meets `{a: number} & {b?: X}`.
        c.rel_intersection_target += 1;
        defer c.rel_intersection_target -= 1;
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
        // `S[K]` relates to `T[J]` when S relates to T and K relates to J
        // (tsc `structuredTypeRelatedTo`, IndexedAccess on BOTH sides). The
        // constraint route below cannot answer this pair: neither side
        // reduces while its object is still a type parameter, so
        // `T["_output"]` under two different arguments compared as nothing
        // at all — which is what made a generic whose members read their
        // parameter through an indexed access (`ZodOptional<T> extends
        // ZodType<T["_output"] | undefined, …>`) measure INVARIANT instead
        // of covariant.
        if (sk == .index_access and
            try c.isAssignable(c.ts.indexAccessObj(s), c.ts.indexAccessObj(t)) and
            try c.isAssignable(c.ts.indexAccessIndex(s), c.ts.indexAccessIndex(t))) return true;
        // The mirror of the source rule above: a TARGET access over a
        // generic map is the map's substituted template, and it is the READ
        // reading on this side too — tsc's `getNormalizedType` runs
        // `getSimplifiedType` on both operands of a relation, and the
        // simplification of `Partial<T>[P]` carries the `?` either way.
        // `Readonly<Partial<T>>`'s template IS a `Partial<T>[P]`, so a
        // `Partial<T>` source only fits it because both sides admit
        // `undefined` (`mappedTypes5` `d1`).
        if (try simplifyMappedIndexAccessRead(c, t)) |sim| return c.isAssignable(s, sim);
        // The other half of `getSimplifiedIndexedAccessType`, and it must be
        // asked AHEAD of the constraint route because it is a normalization,
        // not a widening: `(S & State<T>)["a"]` IS `S["a"] & (T | undefined)`,
        // so its constraint is the intersection's, and answering from the
        // constraint alone drops `S["a"]`'s half of the requirement.
        // `indexedAccessRelation`'s `setState({ a: a })` is the case — a `T`
        // satisfies `State<T>["a"]` but nothing is known about `S["a"]`.
        if (try simplifyIndexAccess(c, t, .relation)) |dist| return c.isAssignable(s, dist);
        if (try c.indexAccessTargetConstraint(t)) |bc| return c.isAssignable(s, bc);
        // An INTERSECTION source still gets tsc's "some constituent is
        // immediately related to the target" test
        // (`unionOrIntersectionRelatedTo`, which runs ahead of every
        // target-flag branch). ztsc hoisted this arm above the
        // intersection-source arm for branded scalars, and its unconditional
        // `return false` then took that test away from every intersection
        // whose target is a deferred access: `NonNullable<T[P]>` — the lib's
        // `T[P] & {}` — stopped relating to `T[P]` itself (`mappedTypes6`
        // `Denullified<T>` → `Required<T>`/`T`/`Partial<T>`). Last, not
        // first, so the constraint route above keeps deciding the pairs it
        // already decided.
        if (sk == .intersection) {
            for (try c.memberList(s)) |m| {
                if (try c.isAssignable(m, t)) return true;
            }
        }
        return false;
    }
    // Deferred (still generic) mapped types. Self-contained: every shape it
    // does not recognize returns null and falls through unchanged.
    if (sk == .mapped or tk == .mapped) {
        if (try c.mappedAssignable(s, t, sk, tk)) |r| return r;
    }
    if (sk == .intersection) {
        for (try c.memberList(s)) |m| {
            if (try c.isAssignable(m, t)) return intersectionOptionalsRelated(c, s, t);
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
            //
            // A UNION body is the same case with the same cure, and it is not
            // hypothetical: an alias in a CYCLE is spelled as the lazy `.ref`
            // everywhere it is reached while its own body still resolves, so
            // the ref itself ends up as a MEMBER of some other union — and
            // `typeRelatedToSomeType`'s member loop then hands this pair every
            // intersection-shaped source it is given. outline's action tree is
            // that shape: `ActionVariant = Action | … | ActionWithChildren`,
            // and `ActionWithChildren` spells `children: (ActionVariant |
            // ActionGroup | ActionSeparator)[]`, so the element union keeps
            // `ActionVariant` as a ref while each of its four constituents is
            // an intersection (`BaseAction & { variant: "action" }`). All four
            // died here, which made a REFLEXIVE `(ActionVariant | ActionGroup
            // | ActionSeparator)[]` write fail — while the same union spelled
            // out, or rebuilt by a distributive conditional (which
            // re-normalizes it), succeeded.
            if (rt != t and (c.ts.kind(rt) == .intersection or c.ts.kind(rt) == .union_type)) {
                return c.isAssignable(s, rt);
            }
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
    //
    // tsc guards this arm with `isDistributionDependent` (see
    // `distributionDependent`) and ztsc applies that guard only where BOTH
    // sides are conditionals, in `isAssignableInner`'s source arm. Applying it
    // here too was measured and costs `recursiveReverseMappedType`: the target
    // there is `(T extends unknown[] ? {} : {…}) | ['marker', ...Recur<T>[]]`,
    // and it is the CONDITIONAL member — whose `{}` true branch accepts
    // anything — that carries the tuple, because ztsc's tuple-vs-variadic-tuple
    // rule does not. Refusing the branch reading turned a clean case into a
    // false TS2322, which the no-false-positive rule outranks the missing
    // diagnostic it would have bought.
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
        //
        // The one half of the comparison that IS sound is tsc's
        // `templateLiteralTypesDefinitelyUnrelated` (`template.zig`): fixed
        // text that diverges at the head or the tail rules the pair out no
        // matter what the holes hold. Applying it here narrows the leniency
        // to the cases that actually need a matcher.
        if (sk == .template_literal_type) {
            // tsc, at exactly this arm: "Report unreliable variance for type
            // variables referenced in template literal type placeholders. For
            // example, `foo-${number}` is related to `foo-${string}` even
            // though number isn't related to string." A measurement whose
            // marker sits in a placeholder therefore measured nothing.
            try variance_zig.noteVarianceMarker(c, s, false);
            if (template_zig.definitelyUnrelated(c, s, t)) return false;
            // …and the other half tsc decides cheaply: two patterns with the
            // SAME fixed text relate exactly when each source placeholder is
            // valid for the target's (`sameTextPatternRelated`). `null` keeps
            // the leniency above for the texts that do not line up.
            if (try template_zig.sameTextPatternRelated(c, s, t)) |v| return v;
            return true;
        }
        // A string-transform intrinsic gets no such concession: tsc's
        // `isTypeMatchedByTemplateLiteralType` infers nothing from a
        // `StringMapping` source, and the base constraint it falls back on is
        // plain `string`, which no pattern accepts. `Capitalize<string>` is
        // NOT a `` `A${string}` `` (the empty string is capitalized and has no
        // `A`), and the conformance case says so.
        return false;
    }
    // String-transform intrinsic TARGET. `Uppercase<string>` is not `string`:
    // it denotes the strings that ARE their own uppercase, so membership is
    // decided by re-applying the intrinsic stack and asking whether the source
    // came back unchanged (`isMemberOfStringMapping`). Two intrinsics relate
    // only when they are the SAME intrinsic over related arguments — tsc
    // returns outright false for `Lowercase<X>` against `Uppercase<Y>`,
    // because `Uppercase<Lowercase<string>>` and `Uppercase<string>` really
    // are different sets (the German sharp s lowercases to `ss`).
    if (tk == .string_mapping) {
        if (sk == .string_mapping) {
            if (c.ts.stringMappingKind(s) != c.ts.stringMappingKind(t)) return false;
            return c.isAssignable(c.ts.stringMappingArg(s), c.ts.stringMappingArg(t));
        }
        return template_zig.isMemberOfStringMapping(c, s, t);
    }
    // Template-literal pattern / string-mapping *source* against anything
    // else: `string` answers for it. Both are SUBTYPES of `string` — that is
    // what `literalBase` says two frames up — and tsc reaches an object target
    // through `getApparentType`, which hands a template literal the very same
    // global `String` interface it hands `string`. So `string <: T` implies
    // `template <: T`, and delegating is sound in the only direction that
    // matters: it can never accept more than `string` does.
    //
    // A flat `return false` here was a false positive on every object-ish
    // target `string` itself satisfies — `{}` above all, which is how
    // `Property.Transform = Globals | (string & {})` is spelled: a
    // `` `translate(${number}px)` `` reaching that intersection met `string`
    // and then failed `{}`. (The string-literal and pattern targets are
    // already answered above; what is left here is the object/primitive tail.)
    if (sk == .template_literal_type or sk == .string_mapping) return c.isAssignable(types.string_type, t);
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
    //
    // The recursion does NOT memoize: the expansion of a ref canonicalizes to
    // that very ref (`refFacetOf`), so the inner frame's key is this frame's
    // key, and consulting the memo would read our own in-progress mark and
    // answer "related" without expanding anything. See `relate`.
    if (sk == .ref or tk == .ref) {
        // tsc's `recursiveTypeRelatedTo` gate: it recurses into a source's
        // structure only when BOTH sides are `StructuredOrInstantiable`. A
        // PRIMITIVE target is not, so `isSimpleTypeRelatedTo` answers the pair
        // (no) and the source's members are never resolved. ztsc expanded the
        // reference first and asked afterwards — the same "no", at the cost of
        // materializing a whole member table to reach it.
        //
        // That cost is not the reason this gate exists: the expansion can be
        // *wrong*. An interface/class reference expanded while its own table is
        // still materializing answers `error_type` (`classInstanceGeneric`'s
        // in-progress mark), and `error_type` relates to EVERYTHING — so the
        // pair came back "assignable" and the relation memo published it under
        // the reference's key, where every later reader inherited it.
        //
        // react-native-gesture-handler is exactly that shape: `BaseGesture<T>`
        // declares `simultaneousWithExternalGesture(...g: Exclude<GestureRef,
        // number>[])`, and `GestureRef` is a union over `BaseGesture<…>` — so
        // materializing the class's own member table asks whether each
        // `BaseGesture<…>` extends `number`, re-entering the table that is
        // being built. Every constituent answered "yes" off `error_type`, so
        // `Exclude<GestureRef, number>` reduced to just its `RefObject` arms
        // and every `.blocksExternalGesture(gesture)` in the app was a
        // phantom TS2345.
        //
        // `refExpandsToObject` is the no-expansion half of the gate: an
        // interface or class reference is an object type for every argument
        // list, whatever its members turn out to be (aliases are excluded —
        // their bodies reduce, so a `.ref` alias may well BE a primitive).
        if (sk == .ref and c.refExpandsToObject(s) and primitiveOnlyTarget(tk)) return false;
        // Lazy member route (see `lazyRefRelate`): decide the pair by reading
        // member names and flags off the generic tables, substituting only the
        // members the comparison actually reaches. Answers null for every
        // shape it does not model, which then takes the eager path below.
        if (try lazyRefRelate(c, s, t, sk, tk)) |r| return r;
        const rs = try c.resolveStructural(s);
        const rt = try c.resolveStructural(t);
        if (rs == s and rt == t) return false;
        // One hash-consed table for two distinct references is where the
        // nominal `private`/`protected` rule has to be asked, because no
        // property walk follows (see `nominal_members.identicalTableRelated`).
        if (rs == rt) return nominal_members.identicalTableRelated(c, s, t, rs);
        return relateFolded(c, rs, rt, false);
    }
    // The single-element variadic-tuple bridge: for a generic `T`, `[...T]`
    // and `T` are two spellings of the same list, and tsc relates them
    // directly rather than structurally (`structuredTypeRelatedTo`'s
    // `isSingleElementGenericTupleType` pair). Placed here for the same reason
    // tsc places it before its type-parameter arms: both directions have a
    // type PARAMETER on one side, which the arms below answer only through its
    // constraint — and a constraint of `unknown[]` neither satisfies nor is
    // satisfied by the tuple form. Falls through when the bridge's own inner
    // question says no, exactly as tsc's `||` chain does.
    if ((sk == .tuple or tk == .tuple) and try tuple_zig.singleElementBridge(c, s, t)) return true;
    // Enum types are nominal (identical enums caught by s == t earlier).
    //
    // A generic SOURCE is not one of them. `<T extends E>` is a `.type_param`,
    // so `enumAssignable` saw a non-enum source and rejected `T` against the
    // very enum it is constrained to — `<T extends E>(t: T): E => t` was
    // TS2322, and so was every `T extends keyof M` over an enum-keyed table
    // (immich `src/utils/sync.ts:34`). The nominal question is about the
    // CONSTRAINT, which is what the type-parameter arm below asks; this arm
    // only ever ran first because it is written on kinds, not on roles.
    if ((sk == .enum_type or tk == .enum_type) and sk != .type_param) {
        return c.enumAssignable(s, t, sk, tk);
    }
    // Type parameters.
    if (sk == .type_param) {
        const constraint = try relationConstraintOf(c, s);
        if (constraint != types.no_type) return c.isAssignable(constraint, t);
        return false;
    }
    if (tk == .type_param) return false;
    // A still-deferred `T[K]` SOURCE never reaches the structural comparison.
    // tsc's `structuredTypeRelatedToWorker` puts the type-variable arm and
    // the structural arm in one `else if` chain, so an indexed access relates
    // through its constraint or not at all — everything above this line is
    // that constraint route. Falling through instead handed the target a
    // source with NO members, which every members-of-the-target walk accepts
    // vacuously: `T[K]` satisfied `{}` (and therefore `NonNullable<T[K]>`,
    // the lib's `T[K] & {}`) and every all-optional object, for an
    // unconstrained `T` whose values may well be `null`
    // (`mappedTypes6` f2 `w = x`).
    if (sk == .index_access) return false;

    switch (tk) {
        .boolean => return sk == .bool_true or sk == .bool_false,
        // A `unique symbol` widens to `symbol`; the reverse and cross-decl
        // (distinct `unique symbol`s) are caught by the `s == t` fast path
        // failing above, so nothing else is assignable here.
        .symbol => return sk == .unique_symbol,
        .object_keyword => return isNonPrimitiveKind(sk),
        .array => {
            // tsc's readonly screen (`tuple_zig.readonlyMismatch`): a readonly
            // list never satisfies a mutable one, whichever spelling each side
            // uses. Ahead of the element comparison because tsc reports the
            // readonly failure (TS4104) *instead of* the element story.
            if (tuple_zig.readonlyMismatch(c, s, t)) return false;
            if (sk == .array) return c.isAssignable(c.ts.arrayElem(s), c.ts.arrayElem(t));
            if (sk == .tuple) {
                const elem = c.ts.arrayElem(t);
                // A tuple has no element list in tsc: it is an object whose
                // NUMERIC INDEX type is the union of its element types, and
                // `indexSignaturesRelatedTo` relates that union to the array's
                // element type. Under the comparable relation a union source
                // only needs SOME constituent to relate
                // (`someTypeRelatedToType`), which is why
                // `<number[]>someNumStrTuple` is not a TS2352 in tsgo
                // (`conformance/types/tuple/castingTuple`) even though the
                // `string` position fits nothing in `number[]`. Assignability
                // keeps needing every element.
                const some = c.rel_kind == .comparable;
                const n_elems = c.ts.tupleLen(s);
                for (0..n_elems) |i| {
                    const e = c.ts.tupleElem(s, @intCast(i));
                    const et = if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
                    const rel = try c.isAssignable(et, elem);
                    if (some) {
                        if (rel) return true;
                    } else if (!rel) return false;
                }
                // An empty tuple has no numeric index type to disagree with.
                return !some or n_elems == 0;
            }
            return false;
        },
        .tuple => {
            if (tuple_zig.readonlyMismatch(c, s, t)) return false;
            if (sk != .tuple) return false;
            if (try c.tupleAssignable(s, t)) return true;
            // tsc's `isGenericTupleType(source) && isTupleType(target) &&
            // !isGenericTupleType(target)` arm: a variadic source element is a
            // hole no concrete target element can match, so the pair is retried
            // with each variadic element replaced by its constraint. That is
            // what makes `[...T, ...T]` with `T extends [unknown]` a
            // `[unknown, unknown]`.
            if (!tuple_zig.isGenericTuple(c, t) and tuple_zig.isGenericTuple(c, s)) {
                if (try tuple_zig.constrainedGenericTuple(c, s)) |cs| {
                    if (cs != s) return c.isAssignable(cs, t);
                }
            }
            return false;
        },
        .function => {
            if (sk == .function) return c.signatureAssignable(s, t);
            if (sk == .overloads) {
                // An overload SET on the source side is tsc's cross-matching
                // `else` arm, which erases both sides to `any`.
                for (try c.memberList(s)) |m| {
                    if (try c.signatureAssignableErased(m, t)) return true;
                }
                return false;
            }
            // Callable object → function type: some call signature
            // of the object must be assignable to the target function.
            if (sk == .object) {
                const n = c.ts.objectCallSigCount(s);
                for (0..n) |i| {
                    const ss = c.ts.objectCallSig(s, @intCast(i));
                    const ok = if (n == 1)
                        try c.signatureAssignable(ss, t)
                    else
                        try c.signatureAssignableErased(ss, t);
                    if (ok) return true;
                }
                return false;
            }
            return false;
        },
        .overloads => {
            // tsc's `signaturesRelatedTo` arm 3: an overload SET on EITHER side
            // is cross-matched with both sides erased to `any`
            // (`getErasedSignature`), and only the one-signature-per-side case
            // is compared with the type parameters left standing. Recursing
            // into `isAssignable` per target signature answered the second
            // question for a pair that is in the first: each target signature
            // met a single source signature and was compared through
            // `signatureAssignable`, i.e. erased to its CONSTRAINTS.
            //
            // A source whose one generic signature covers the whole overload
            // set is then rejected on the overloads it covers only via `any` —
            // kysely's `SelectQueryBuilder.as<A extends string>(alias: A)`
            // against `AliasableExpression.as`, whose second overload takes an
            // `Expression<any>`: constraint-erased, the source parameter is
            // `string` and does not accept it, so a builder stopped being an
            // `AliasableExpression` at all. That is the whole `.where(ref, 'in',
            // (eb) => …)` family — the callback's return no longer matched the
            // `ExpressionFactory` constituent, the argument was rejected, and
            // the call fell out TS2769 with the callback's parameters
            // implicitly `any`.
            for (try c.memberList(t)) |m| {
                const matched = switch (sk) {
                    .function => try c.signatureAssignableErased(s, m),
                    .overloads => blk: {
                        for (try c.memberList(s)) |sm| {
                            if (try c.signatureAssignableErased(sm, m)) break :blk true;
                        }
                        break :blk false;
                    },
                    else => try c.isAssignable(s, m),
                };
                if (!matched) return false;
            }
            return true;
        },
        .object => return c.structuralAssignable(s, t),
        // A class's STATIC side is an ordinary object type in tsc — the
        // statics, plus one construct signature per constructor overload — so
        // any object carrying a matching construct signature is assignable to
        // `typeof C`. ztsc's `.class_value` is a nominal shortcut (`new C()`
        // and `C.staticMember` read the symbol directly), and this arm simply
        // said no, so `ClassConstructor<T> = { new (…args: any[]): T }` was
        // not a `typeof SomeRepository` — immich's whole DI factory
        // (`deps.includes(dep)`, `BASE_SERVICE_DEPENDENCIES.indexOf(key)`)
        // was rejected against the union of its repository class values.
        //
        // `classConstructType` is exactly that materialization and already
        // exists for `InstanceType<T>`-style pattern matching.
        //
        // A `.class_value` SOURCE materializes too, and it has to: the
        // identity fast path answers only the SAME symbol, and the heritage
        // walk above relates INSTANCE sides (`Sub` → `Base`), never static
        // ones — so `typeof Sub` was not assignable to `typeof Base` for any
        // pair of distinct classes, not even `class Sub extends Base {}`. On
        // react-native-reanimated that is the whole TS2684 family: every
        // `FadeIn.duration(90)` calls `static duration<T extends typeof
        // BaseAnimationBuilder>(this: T, …)`, and with the receiver rejected
        // against the constraint, `T` fell back to the constraint itself and
        // the `this` check reported the fallback.
        //
        // Materializing both sides is what tsc does, and it is not the
        // nominal shortcut a subclass rule would be: a derived class whose
        // constructor demands MORE arguments than the base's is genuinely not
        // assignable to the base's static side, and a structural comparison
        // still says so.
        .class_value => {
            // The abstract-constructor rule (see `sourceSatisfiesSigs`) between
            // two class VALUES, where materializing both sides would have lost
            // the bit: `typeof AbstractB` is not a `typeof ConcreteA`, however
            // well their statics and constructors line up, because the target
            // can be `new`ed. The reverse stays legal.
            if (sk == .class_value and
                try c.classIsAbstract(c.ts.classSymbol(s)) and
                !try c.classIsAbstract(c.ts.classSymbol(t))) return false;
            // …and the constructor-VISIBILITY rule, here for the same reason:
            // `private` / `protected` live on the constructor DECLARATION,
            // and materializing both sides into construct signatures loses
            // them (ztsc's signatures carry no accessibility bit).
            if (sk == .class_value and
                !try nominal_members.ctorVisibilityCompatible(c, c.ts.classSymbol(s), c.ts.classSymbol(t))) return false;
            const tgt_static = try c.classConstructType(c.ts.classSymbol(t));
            if (sk != .class_value) return c.structuralAssignable(s, tgt_static);
            return c.structuralAssignable(try c.classConstructType(c.ts.classSymbol(s)), tgt_static);
        },
        else => return false,
    }
}

/// tsc's INTERSECTION PROPERTY CHECK — the `inPropertyCheck` block of
/// `isRelatedTo`:
///
/// ```ts
/// if (result && !inPropertyCheck && (
///     target.flags & TypeFlags.Intersection && … ||
///     isNonGenericObjectType(target) && !isArrayOrTupleType(target) &&
///     source.flags & TypeFlags.Intersection && …
/// )) {
///     inPropertyCheck = true;
///     result &= recursiveTypeRelatedTo(source, target, reportErrors, IntersectionState.PropertyCheck, …);
///     inPropertyCheck = false;
/// }
/// ```
///
/// `IntersectionState.PropertyCheck` re-runs `propertiesRelatedTo` with
/// `optionalsOnly`, so it says exactly this: an intersection source that got in
/// through the "SOME constituent is related to the target" shortcut still owes
/// the target's OPTIONAL properties a comparison against the intersection's own
/// synthesized member.
///
/// The shortcut is what makes the extra pass necessary. `{ a: null } & { b:
/// string }` against `{ a?: number, b: string }` passes it on the strength of
/// `{ b: string }` alone — an object with no `a` at all satisfies an optional
/// `a?`, and tsgo agrees when that object is written on its own — while the
/// intersection as a whole plainly has `a: null`. Oracle-pinned: the same pair
/// with `a: number` is accepted, and `{ z: boolean } & { b: string }` (no `a`
/// anywhere) is accepted, so it is the SYNTHESIZED property that decides, not
/// the presence of a second constituent.
///
/// The array/tuple exclusion is tsc's and it is load-bearing: `number[] &
/// [number, ...number[]]` is a legal source for `[number, ...number[]]`.
///
/// Shallow where tsc recurses: only the target's own optional properties are
/// re-compared, not a full second relation. A nested failure is still reported
/// by the ordinary walk whenever the shortcut does not fire, so this is the
/// under-reporting direction.
///
/// And COMPARABLE, not assignable — a deliberate weakening of tsc's rule,
/// bounded by a witness. tsc's version is a full relation re-run, so it sees
/// the property pair in the same state the ordinary walk would; this one asks
/// the relation cold, and re-deciding a pair the shortcut had already stepped
/// around turns any residual imprecision in the relation into a NEW false
/// positive rather than a missing one. social-app's
/// `queryClient.fetchQuery(queryOptions({…}))` is that witness: the source is
/// `Opts & { queryKey: DataTag<…> }`, the second constituent alone satisfies
/// `FetchQueryOptions` (every other member is optional), and asking cold about
/// `persister` — a `QueryPersister` whose callback context differs only in
/// `direction?: unknown` vs `direction: "backward" | "forward"` — fails one way
/// and succeeds the other, where tsgo accepts. Requiring the pair to be
/// unrelated in BOTH directions keeps every case this check is for (`null` vs
/// `number | undefined`, `boolean` vs `string | undefined` — primitives that
/// are unrelated either way) and drops that one.
///
/// WAVE 39 ROOT-CAUSED that witness, and it is NOT a relation defect: the two
/// `persister` types genuinely differ, because the call's `TPageParam` is
/// INFERRED WRONG. `fetchQuery<…, TPageParam = never>` gets `unknown` where
/// tsgo gets `never`, so the target's persister is the conditional's FALSE
/// branch (`direction: FetchDirection`) while the source's is the true one
/// (`direction?: unknown`). Oracle-pinned reduction (tsgo silent on the first,
/// erroring on the second — ztsc errors on both):
///
/// ```ts
/// type QFC<K, P = never> = [P] extends [never]
///     ? { k: K; pageParam?: unknown; direction?: unknown }
///     : { k: K; pageParam: P; direction: "f" | "b" };
/// type QF<T, K, P = never> = (c: QFC<K, P>) => T;
/// interface B<T, K, P = never> { k: K; queryFn?: QF<T, K, P> }
/// declare function g<T, K, P = never>(o: B<T, K, P>): P;
/// interface Aliased { k: string[]; queryFn?: QF<R, string[], never> }
/// interface Raw     { k: string[]; queryFn?: (c: { k: string[]; pageParam?: unknown; direction?: unknown }) => R }
/// declare const a: Aliased & { extra: 1 };  // tsgo: P = never
/// declare const b: Raw & { extra: 1 };      // tsgo: P = unknown
/// ```
///
/// The only difference is whether the source member is SPELLED with the same
/// generic type ALIAS as the target member. That is tsc's `inferFromTypes`
/// shortcut — "source and target are types originating in the same generic
/// type alias declaration … simply infer from source type arguments to target
/// type arguments" (`source.aliasSymbol === target.aliasSymbol` →
/// `inferFromTypeArguments(…, getAliasVariances(…))`) — which stops the walk
/// before it ever descends into the resolved branch. ztsc has the machinery
/// on one side only: `instantiate.aliasInstantiation` origin-tags the source's
/// resolved FUNCTION body with `ref(QF, [R, string[], never])`, but the
/// target's `QF<T, K, P>` stays a `.conditional`, which `originTaggable`
/// excludes, so `infer.unify` has nothing to pair and walks structurally into
/// the false branch (`pageParam: P` ← `pageParam?: unknown` = `unknown`).
///
/// The intersection source is only what EXPOSES it: with a plain (non-
/// intersection) argument `infer.unify`'s `.ref` arm pairs the whole
/// `B<…>` positionally and never reaches the members at all. So the fix is
/// origin-tagging a deferred conditional's alias identity plus an alias-args
/// pairing arm in `infer.unify` — `instantiate.zig` / `infer.zig`, neither of
/// them this file. WAVE 39 C LANDED that inference fix (the same-alias
/// pairing arm), and the merge re-tightened this check to plain
/// assignability with the social-app gate re-run to confirm.
fn intersectionOptionalsRelated(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    // `.object` is also where tsc's array/tuple exclusion lands: neither kind
    // resolves to one, so both answer "nothing owed" here.
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object) return true;
    for (0..c.ts.objectPropCount(rt)) |i| {
        const tp = c.ts.objectProp(rt, @intCast(i));
        if (!tp.optional()) continue;
        // `relationSrcProp`, not `propOfType`: the relation's own source
        // lookup, which refuses to answer a NAMED property out of a string
        // index signature. ztsc uses an `any`-valued index as its stand-in for
        // a constituent it could not reduce, so the plain lookup hands this
        // check synthetic members the structural walk would never compare.
        const sp = (try relationSrcProp(c, s, tp.name)) orelse continue;
        const want = try c.makeUnion2(tp.ty, types.undefined_type);
        const have = if (sp.optional()) try c.makeUnion2(sp.ty, types.undefined_type) else sp.ty;
        if (!try c.isAssignable(have, want)) return false;
    }
    return true;
}

/// The key set a mapped type iterates: `keyof <source>` for a homomorphic
/// map (`[P in keyof T]`), the written constraint otherwise.
/// One side of the structural walk, read WITHOUT materializing it when it can
/// be: `table` is the member table to read names, flags and counts out of, and
/// `ref` is the reference whose substitution a member's TYPE is computed under
/// (0 when `table` is already the materialized object). See `lazyTableOf`.
const ObjSide = struct {
    table: TypeId,
    ref: TypeId = 0,

    fn propCount(v: ObjSide, c: *const Checker) u32 {
        return c.ts.objectPropCount(v.table);
    }

    /// The slot of `name` in this side's table, or null — a binary search over
    /// stored (atom-sorted) names, substituting nothing.
    fn slotOf(v: ObjSide, c: *const Checker, name: Atom) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = c.ts.objectPropCount(v.table);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const p = c.ts.objectProp(v.table, mid);
            if (p.name == name) return mid;
            if (p.name < name) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn flagsAt(v: ObjSide, c: *const Checker, i: u32) u32 {
        return c.ts.objectProp(v.table, i).flags;
    }

    /// This side as the NOMINAL screen wants it: the reference whose symbol
    /// names the declaring class, or the materialized table when there is none
    /// (whose `origin` `refFacetOf` still consults). See `nominal_members.zig`.
    fn nominal(v: ObjSide) TypeId {
        return if (v.ref != 0) v.ref else v.table;
    }

    fn nameAt(v: ObjSide, c: *const Checker, i: u32) Atom {
        return c.ts.objectProp(v.table, i).name;
    }

    /// The member's TYPE — the one operation that can cost a substitution.
    fn typeAt(v: ObjSide, c: *Checker, i: u32) Error!TypeId {
        const g = c.ts.objectProp(v.table, i).ty;
        if (v.ref == 0) return g;
        return c.lazyMemberAt(v.ref, g, i);
    }

    fn stringIndex(v: ObjSide, c: *Checker) Error!TypeId {
        if (v.ref == 0) return c.ts.objectStringIndex(v.table);
        return c.lazyStringIndex(v.ref, v.table);
    }

    fn numberIndex(v: ObjSide, c: *Checker) Error!TypeId {
        if (v.ref == 0) return c.ts.objectNumberIndex(v.table);
        return c.lazyNumberIndex(v.ref, v.table);
    }

    /// Presence of an index signature, readable off the generic:
    /// `instantiateId` maps a non-zero index type to a non-zero one.
    fn hasStringIndex(v: ObjSide, c: *const Checker) bool {
        return c.ts.objectStringIndex(v.table) != 0;
    }

    fn hasNumberIndex(v: ObjSide, c: *const Checker) bool {
        return c.ts.objectNumberIndex(v.table) != 0;
    }

    fn hasImpliedIndex(v: ObjSide, c: *const Checker) bool {
        return c.ts.objectHasImpliedIndex(v.table);
    }
};

/// Tally one declined pair and answer "not this route's question" (see
/// `LazyStat`). Costs a predictable-false branch when `--lazy-stats` is off.
fn note(c: *Checker, why: checker_zig.LazyStat) ?bool {
    if (c.opts.lazy_stats) c.lazy_stats[@intFromEnum(why)] += 1;
    return null;
}

/// The structural relation between two object sides, at most one member of
/// each substituted per property compared — tsc's `propertiesRelatedTo`
/// calling `getTypeOfSymbol` on the instantiated member symbols rather than
/// resolving the whole instantiated table first.
///
/// Answers null when the pair is not one this route may decide, in which case
/// the caller expands both sides and takes the eager path exactly as before.
///
/// What makes it faithful is that everything read before a member type is
/// materialized — the target's property NAMES and OPTIONALITY, the source's
/// property names, the presence of index signatures, the object flags — is
/// carried through `instantiateId`'s `.object` arm unchanged. The short
/// circuits are therefore the same short circuits the eager walk takes; they
/// just take them before paying for the two hundred members the answer never
/// depended on. A relation that fails on a builder's first property now
/// substitutes nothing at all.
fn lazyRefRelate(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!?bool {
    if (tk != .ref) return note(c, .tgt_not_ref);
    const t_table = switch (try lazy_zig.lazyTableOutcome(c, t)) {
        .table => |g| g,
        .no => |why| return note(c, why),
    };
    const tsym = c.ts.refSymbol(t);
    var sv: ObjSide = undefined;
    switch (sk) {
        .ref => {
            // The SAME generic on both sides is the variance question and the
            // origin-equivalence fast path; both live on the eager frame the
            // `.ref` arm delegates to, and neither is a structural walk.
            if (c.ts.refSymbol(s) == tsym) return note(c, .same_symbol);
            const s_table = switch (try lazy_zig.lazyTableOutcome(c, s)) {
                .table => |g| g,
                .no => |why| return note(c, why),
            };
            sv = .{ .table = s_table, .ref = s };
        },
        .object => {
            // An already-materialized source saves nothing on its own side but
            // keeps the target lazy. A callable one inherits the global
            // `Function` members through `propOfTypeEx`, which this loop does
            // not model, and a fresh literal is the excess-property check's
            // business — both stay eager.
            if (c.ts.objectCallSigCount(s) != 0 or c.ts.objectConstructSigCount(s) != 0) return note(c, .src_object_shape);
            if (c.ts.objectIsFresh(s)) return note(c, .src_object_shape);
            if (c.refFacetOf(s, sk)) |os| {
                if (c.ts.refSymbol(os) == tsym) return note(c, .same_symbol);
            }
            sv = .{ .table = s };
        },
        else => return note(c, .src_kind),
    }
    const tv: ObjSide = .{ .table = t_table, .ref = t };
    // A `this` type on either side is re-related through its apparent instance
    // by the frame this route replaces (`relate`'s `substThis` step), which
    // rewrites member types wholesale. Leave those pairs eager.
    if (c.has_this_types) {
        if ((try c.containsThisType(s)) or (try c.containsThisType(t)) or
            (try c.containsThisType(sv.table)) or (try c.containsThisType(tv.table))) return note(c, .this_types);
    }
    if (c.opts.lazy_stats) c.lazy_stats[@intFromEnum(checker_zig.LazyStat.hit)] += 1;
    // The frame this replaces pushed the same two references onto the
    // growing-instantiation stack a second time (its own `refFacetOf` of each
    // materialization is the very reference this frame holds). Push them here
    // too, so the guard trips at the same depth it does today.
    //
    // Both guard cuts on this route — here and the `relIdDeeplyNested` one
    // below — answer "related" from ASSUMPTION, exactly as `relate`'s own two
    // do, so both raise `rel_assumed` next to `rel_guard_tripped`. This route
    // returns a bare `bool` to `isAssignableInner` and so cannot say
    // `.assumed_yes` itself (see `RelAnswer`), but it does not have to: it runs
    // INSIDE the demanding `relate` frame's walk, and `rel_assumed` is the
    // half of the protocol that carries exactly this — what the bare-`bool`
    // descendants assumed — back to the frame that cleared it (see
    // `Checker.rel_assumed`). `relate` folds the field into its own
    // `RelAnswer`, so a verdict resting on a cut here is withheld from the
    // `relation` memo instead of being published as evidence. Raising only
    // `rel_guard_tripped` was the memo poisoning the returned protocol exists
    // to prevent; the two variance consumers of `rel_guard_tripped`
    // (`measureOneVariance`, `checkVarianceAnnotations`) are unaffected, and
    // `measuredVariances` already saves and restores `rel_assumed` around its
    // whole measurement.
    if (c.rel_id_depth >= max_relation_depth) {
        c.rel_guard_tripped = true;
        c.rel_assumed = true;
        return true;
    }
    const ssrc = if (sv.ref != 0) sv.ref else (c.refFacetOf(s, sk) orelse 0);
    if (ssrc != 0) {
        c.rel_src_ids[c.rel_id_depth] = .{ .sym = c.ts.refSymbol(ssrc), .ref = ssrc };
        c.rel_tgt_ids[c.rel_id_depth] = .{ .sym = tsym, .ref = t };
        c.rel_src_buckets[relIdBucket(c.rel_src_ids[c.rel_id_depth].sym)] += 1;
        c.rel_tgt_buckets[relIdBucket(tsym)] += 1;
        c.rel_id_depth += 1;
    }
    defer if (ssrc != 0) {
        c.rel_id_depth -= 1;
        c.rel_src_buckets[relIdBucket(c.rel_src_ids[c.rel_id_depth].sym)] -= 1;
        c.rel_tgt_buckets[relIdBucket(c.rel_tgt_ids[c.rel_id_depth].sym)] -= 1;
    };
    if (ssrc != 0 and (c.relIdDeeplyNested(true) or c.relIdDeeplyNested(false))) {
        c.rel_guard_tripped = true;
        c.rel_assumed = true;
        return true;
    }
    return try lazyStructural(c, sv, tv);
}

fn lazyStructural(c: *Checker, sv: ObjSide, tv: ObjSide) Error!bool {
    const n = tv.propCount(c);
    // `{}` accepts anything non-nullish, and both sides here are object
    // shapes. A target with no members and no index signature is that case
    // (neither side can carry signatures — `lazyTableOf` excludes them).
    if (n == 0 and !tv.hasStringIndex(c) and !tv.hasNumberIndex(c)) return true;
    for (0..n) |i| {
        const ti: u32 = @intCast(i);
        const t_opt = tv.flagsAt(c, ti) & types.prop_flag_optional != 0;
        var st: TypeId = undefined;
        if (sv.slotOf(c, tv.nameAt(c, ti))) |si| {
            const s_opt = sv.flagsAt(c, si) & types.prop_flag_optional != 0;
            if (s_opt and !t_opt) return false;
            // The nominal screen, on the same flag bit the eager walk reads —
            // carried through `instantiateId`'s `.object` arm, so it is
            // readable off the un-substituted table (see `nominal_members.zig`
            // and `structuralAssignable`, the eager form of this walk).
            const s_np = sv.flagsAt(c, si) & types.prop_flag_non_public != 0;
            const t_np = tv.flagsAt(c, ti) & types.prop_flag_non_public != 0;
            if ((s_np or t_np) and
                !try nominal_members.nonPublicPropRelated(c, sv.nominal(), tv.nominal(), tv.nameAt(c, ti), s_np, t_np)) return false;
            st = try sv.typeAt(c, si);
            if (s_opt) st = try c.makeUnion2(st, types.undefined_type);
        } else if (try c.objectInterfaceProp(tv.nameAt(c, ti))) |op| {
            // The apparent global-`Object` member of that name — both sides
            // here are object shapes, so the augment applies (see
            // `relationSrcProp`, the eager walk's form of this).
            st = op.ty;
        } else {
            // The source has no member of that name — the eager walk's
            // `propOfTypeEx` miss, reached without substituting anything on
            // either side. This is the short circuit the whole conversion is
            // for: the answer never depended on the other members' types.
            if (t_opt) continue;
            return false;
        }
        var tt = try tv.typeAt(c, ti);
        if (t_opt) tt = try c.makeUnion2(tt, types.undefined_type);
        if (!try c.isAssignable(st, tt)) return false;
    }
    if (tv.hasStringIndex(c)) {
        const sidx = try tv.stringIndex(c);
        const sidx_any = c.ts.kind(try c.resolveStructural(sidx)) == .any;
        if (!sidx_any) {
            if (sv.hasStringIndex(c)) {
                if (!try c.isAssignable(try sv.stringIndex(c), sidx)) return false;
            } else if (sv.hasImpliedIndex(c)) {
                for (0..sv.propCount(c)) |i| {
                    if (!try c.isAssignable(try sv.typeAt(c, @intCast(i)), sidx)) return false;
                }
            } else return false; // interface / class instance, no index sig
        }
    }
    if (tv.hasNumberIndex(c)) {
        const nidx = try tv.numberIndex(c);
        // The `any`-valued exemption applies to EVERY index info of the
        // target, the number one included, whenever the target also has a
        // string index signature — see `structuralAssignable`, which is the
        // eager form of this walk.
        const nidx_any = tv.hasStringIndex(c) and c.ts.kind(try c.resolveStructural(nidx)) == .any;
        if (nidx_any) {
            // vacuously related
        } else if (sv.hasNumberIndex(c)) {
            if (!try c.isAssignable(try sv.numberIndex(c), nidx)) return false;
        } else if (sv.hasStringIndex(c)) {
            if (!try c.isAssignable(try sv.stringIndex(c), nidx)) return false;
        } else if (sv.hasImpliedIndex(c)) {
            for (0..sv.propCount(c)) |i| {
                if (!isNumericPropName(c.atomText(sv.nameAt(c, @intCast(i))))) continue;
                if (!try c.isAssignable(try sv.typeAt(c, @intCast(i)), nidx)) return false;
            }
        } else return false;
    }
    return true;
}

pub fn mappedKeySet(c: *Checker, m: TypeId) Error!TypeId {
    if (c.ts.mappedHomomorphic(m)) return c.keyofType(c.ts.mappedSource(m));
    return c.ts.mappedConstraint(m);
}

pub fn mappedAddsOptional(c: *Checker, m: TypeId) bool {
    return c.ts.mappedFlags(m) & types.mapped_flag_optional_add != 0;
}

/// tsc's `getCombinedMappedTypeOptionality`: `+?` is 1, `-?` is -1, and a map
/// that says NOTHING about optionality inherits the answer from its modifiers
/// type — the source a homomorphic map is written over.
///
/// ```ts
/// function getCombinedMappedTypeOptionality(type: MappedType): number {
///     const optionality = getMappedTypeOptionality(type);
///     const modifiersType = getModifiersTypeFromMappedType(type);
///     return optionality || (isGenericMappedType(modifiersType) ? getCombinedMappedTypeOptionality(modifiersType as MappedType) : 0);
/// }
/// ```
///
/// This is the whole of what `mappedTypeRelatedTo` checks about modifiers
/// (`readonly` is not compared at all), and reading only the map's OWN flag
/// got `Readonly<Partial<T>>` wrong in both directions: `Partial<T>` was
/// refused as one (the outer map adds nothing, the inner adds `?`), and it was
/// accepted as a `Readonly<T>`, which it is not (`mappedTypes5`).
///
/// Iterative with a depth cap rather than recursive: the modifiers chain is a
/// `Readonly<Partial<…>>` nesting, a handful deep at most, and a source that
/// somehow cycled would otherwise not terminate.
fn mappedCombinedOptionality(c: *Checker, m: TypeId) Error!i32 {
    var cur = m;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        const f = c.ts.mappedFlags(cur);
        if (f & types.mapped_flag_optional_remove != 0) return -1;
        if (f & types.mapped_flag_optional_add != 0) return 1;
        // Only a HOMOMORPHIC map has a modifiers type ztsc can name: it is the
        // `T` of `keyof T`, which `mappedSource` stores. tsc reaches one for
        // `{ [P in K]: T[P] }` too, through `K`'s constraint; that shape says
        // nothing about optionality here that the template comparison does not.
        if (!c.ts.mappedHomomorphic(cur)) return 0;
        const src = c.ts.mappedSource(cur);
        if (src == 0) return 0;
        const rs = try c.resolveStructural(src);
        if (c.ts.kind(rs) != .mapped) return 0;
        cur = rs;
    }
    return 0;
}

/// tsc's `shouldNormalizeIntersection` + the re-forming step that follows it:
/// an intersection that mixes an INSTANTIABLE constituent with a nullable or
/// empty-anonymous-object one, re-interned out of its constituents' SIMPLIFIED
/// forms. Null when the gate does not fire or nothing actually simplified —
/// see the caller for what it is for.
///
/// Only `.index_access` constituents are simplified, because
/// `simplifyMappedIndexAccessRead` is the only simplification ztsc has that
/// can introduce the `undefined` this exists to cancel; every other
/// constituent goes through unchanged, which is what keeps the re-intern equal
/// to `s` (and so `null`) in the common case.
fn normalizedIntersection(c: *Checker, s: TypeId) Error!?TypeId {
    var instantiable = false;
    var nullable_or_empty = false;
    for (c.ts.members(s)) |m| {
        switch (c.ts.kind(m)) {
            .index_access => instantiable = true,
            .null, .undefined => nullable_or_empty = true,
            .object => nullable_or_empty = nullable_or_empty or isEmptyObjectType(c, m),
            else => {},
        }
    }
    if (!instantiable or !nullable_or_empty) return null;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    var changed = false;
    for (try c.memberList(s)) |m| {
        const n = if (c.ts.kind(m) == .index_access)
            (try simplifyMappedIndexAccessRead(c, m)) orelse m
        else
            m;
        if (n != m) changed = true;
        try parts.append(c.scratch(), n);
    }
    if (!changed) return null;
    const ns = try c.ts.makeIntersection(c.scratch(), parts.items);
    return if (ns == s) null else ns;
}

/// tsc's `getTemplateTypeFromMappedType`, the `addOptionality` half: a map's
/// template carries the map's OWN `+?` as a `| undefined`.
///
/// ztsc keeps `mappedValue` the template AS WRITTEN and judges `?` separately
/// (`mappedCombinedOptionality`), which is enough while both sides of a
/// template comparison are written the same way. They are not once one side's
/// template is itself an access into a `+?` map: `Readonly<Partial<T>>`'s
/// template is `Partial<T>[P]`, whose READ value is `T[P] | undefined`
/// (`mapped.simplifyMappedIndexAccessRead`), and `Partial<T>`'s written
/// template is a bare `T[P]`. Spelling each side's own `+?` back onto its
/// template is what lines the two up — it is what tsc compares, and it is the
/// only reason the two are interchangeable (`mappedTypes5` a4/c4).
///
/// The map's OWN flag, not the combined one: the modifiers CHAIN is already
/// compared by `mappedCombinedOptionality` above, and an inherited `?` is
/// spelled out by the template's own simplification rather than here.
fn mappedTemplateOptionality(c: *Checker, m: TypeId, tmpl: TypeId) Error!TypeId {
    if (c.ts.mappedFlags(m) & types.mapped_flag_optional_add == 0) return tmpl;
    return c.makeUnion2(tmpl, types.undefined_type);
}

/// The keys a mapped TARGET actually produces, which is what a source has to
/// supply — tsc's
///
/// ```ts
/// // If target has shape `{ [P in Q as R]: T }`, then its keys have type `R`.
/// // If target has shape `{ [P in Q]: T }`, then its keys have type `Q`.
/// const targetKeys = keysRemapped ? getNameTypeFromMappedType(target)! : getConstraintTypeFromMappedType(target);
/// ```
///
/// An `as` clause REPLACES the key set rather than filtering it, so reading
/// the constraint for a remapped map asks about keys the map never emits.
/// Before this existed the whole source-to-mapped-target family simply bailed
/// on `mappedAs(t) != 0`, which made every `{ [P in keyof T as …]: … }` target
/// unreachable from any source (`mappedTypeAsClauseRelationships`).
fn mappedTargetKeys(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.mappedAs(t) == 0) return c.mappedKeySet(t);
    return mappedBindKeyParam(c, t, c.ts.mappedAs(t));
}

/// The template a mapped TARGET's values have, with its key parameter bound
/// the way `mappedTargetKeys` binds it — see there.
fn mappedTargetTemplate(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.mappedAs(t) == 0) return c.ts.mappedValue(t);
    return mappedBindKeyParam(c, t, c.ts.mappedValue(t));
}

/// Replace a mapped type's key parameter `P` with its CONSTRAINT — the key set
/// the map iterates.
///
/// tsc's `getTypeParameterFromMappedType` hands back a `P` that carries
/// `getConstraintTypeFromMappedType` as its constraint, so its relation
/// questions (`R <: keyof S`, and the `S[R]` vs `T[P]` comparison that follows)
/// are answered through that constraint. ztsc's `.mapped_param` carries none,
/// so a free `P` relates to nothing and every remapped target was unreachable.
/// Substituting the key set for `P` is the same information, spelled where
/// ztsc can read it — and it is applied to BOTH sides of the comparison, so
/// the two line up exactly as tsc's constrained `P` makes them.
fn mappedBindKeyParam(c: *Checker, t: TypeId, ty: TypeId) Error!TypeId {
    const kp = c.ts.mappedKeyParam(t);
    if (c.ts.kind(kp) != .mapped_param) return ty;
    return c.substMappedKey(ty, c.ts.mappedParamId(kp), try c.mappedKeySet(t));
}

/// The STRING INDEX SIGNATURE a still-generic mapped type apparently has, or
/// null when it has none.
///
/// tsc's `resolveMappedTypeMembers` does not leave `{[P in K]: V}` memberless
/// just because `K` is generic: it runs `forEachType(getLowerBoundOfKeyType(K),
/// addMemberForKeyType)`, and `getLowerBoundOfKeyType` reduces `keyof T` to
/// `getIndexType(getApparentType(T))`. A key type that is not a literal name
/// then becomes an INDEX signature of the template rather than a property. So
/// under `T extends Record<string, any>`, `Record<keyof T, V>` really does have
/// `[x: string]: V`.
///
/// social-app's router is the shape that needs it: `constructor(description:
/// Record<keyof T, string | string[]>)` then `Object.entries(description)`.
/// Without the index signature nothing pairs with `entries<V>(o: {[s: string]:
/// V})`'s parameter — neither the inference nor the assignability — so the call
/// fell to the `entries(o: {}): [string, any][]` overload, `pattern` was `any`,
/// and `pattern.forEach(subPattern => …)` reported TS7006.
///
/// Deliberately narrow: a `k as …` remapping is not modelled, and a key set
/// whose lower bound is a set of literal names materializes as PROPERTIES and
/// is not this route's question.
pub fn mappedApparentStringIndex(c: *Checker, m: TypeId) Error!?TypeId {
    const s = &c.ts;
    if (s.mappedAs(m) != 0) return null;
    const lower = try mappedKeyLowerBound(c, try c.mappedKeySet(m));
    var covers_string = false;
    const parts: []const TypeId = if (s.kind(lower) == .union_type) try c.memberList(lower) else &.{lower};
    for (parts) |p| {
        switch (s.kind(p)) {
            .string, .number => covers_string = true,
            else => {},
        }
    }
    if (!covers_string) return null;
    return mappedTemplateAtString(c, m);
}

/// The map's value template with its key bound to `string` — tsc's
/// `getTemplateTypeFromMappedType`, which is what an index signature's value
/// type is compared against and does not depend on the map's key set at all.
/// Null for a REMAPPED map, whose produced key is not `P`.
fn mappedTemplateAtString(c: *Checker, m: TypeId) Error!?TypeId {
    const s = &c.ts;
    if (s.mappedAs(m) != 0) return null;
    return try c.substMappedKey(s.mappedValue(m), s.mappedParamId(s.mappedKeyParam(m)), types.string_type);
}

/// tsc's `getLowerBoundOfKeyType`, restricted to the arm that matters here:
/// `keyof T` reduces to `keyof (apparent T)`, so a type parameter's CONSTRAINT
/// is what says which keys the map can iterate. Anything else is its own lower
/// bound.
fn mappedKeyLowerBound(c: *Checker, ks: TypeId) Error!TypeId {
    if (c.ts.kind(ks) != .keyof_op) return ks;
    const operand = c.ts.keyofOperand(ks);
    const apparent = if (c.ts.kind(operand) == .type_param)
        try c.transitiveBaseConstraint(operand)
    else
        operand;
    if (apparent == operand) return ks;
    return c.keyofType(try c.resolveStructural(apparent));
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
        if (try mappedCombinedOptionality(c, s) > try mappedCombinedOptionality(c, t)) return null;
        if (c.ts.mappedAs(s) != 0 or c.ts.mappedAs(t) != 0) return null; // key remapping: not modelled
        const s_keys = try c.mappedKeySet(s);
        // tsc's `mappedTypeRelatedTo` instantiates the SOURCE's constraint
        // through `reportUnmeasurableMapper`/`reportUnreliableMapper` here: a
        // variance measurement whose marker is inside that constraint learns
        // nothing usable from this arm, because two mapped types relate by
        // their KEY SETS and not by what the marker stands for. A source that
        // REMOVES optionality is outright nonlinear (`Unmeasurable`), the rest
        // merely `Unreliable` — see `variance.noteVarianceMarker`.
        try variance_zig.noteVarianceMarker(
            c,
            s_keys,
            c.ts.mappedFlags(s) & types.mapped_flag_optional_remove != 0,
        );
        if (!try c.isAssignable(try c.mappedKeySet(t), s_keys)) return null;
        const sv = try mappedTemplateOptionality(c, s, try c.substMappedKey(
            c.ts.mappedValue(s),
            c.ts.mappedParamId(c.ts.mappedKeyParam(s)),
            c.ts.mappedKeyParam(t),
        ));
        const tv = try mappedTemplateOptionality(c, t, c.ts.mappedValue(t));
        return if (try c.isAssignable(sv, tv)) true else null;
    }
    if (tk == .mapped) {
        // tsc `structuredTypeRelatedTo`, verbatim: a homomorphic map whose
        // TEMPLATE is the source indexed by the map's OWN key parameter —
        // `{ [P in keyof S]: S[P] }` — is the identity on `S`, and the
        // relation says so on the syntax alone ("if the mapped type has shape
        // `{ [P in Q]: T[P] }` and `T` is the source, they are related").
        // Reached before the general `keyof S`-vs-key-set walk below, which
        // has to reduce `S[P]` and compare it against itself and does not
        // always get there for a still-generic `S`.
        // Gated exactly as tsc gates it: on the map not REMOVING `?`
        // (`!(modifiers & ExcludeOptional)`) and not remapping keys. ADDING
        // `?` is fine — every member the map produces is still `S`'s own,
        // merely optional, which is what makes `T` a `Partial<T>`.
        if (c.ts.mappedFlags(t) & types.mapped_flag_optional_remove == 0 and c.ts.mappedAs(t) == 0) {
            const val = c.ts.mappedValue(t);
            if (c.ts.kind(val) == .index_access and
                c.ts.indexAccessObj(val) == s and
                c.ts.indexAccessIndex(val) == c.ts.mappedKeyParam(t)) return true;
            // The same shape indexed by the map's whole KEY SET rather than
            // its key parameter — `{ [P in keyof S]: S[keyof S] }`. Every key
            // the map produces is a key of `S`, and the value it gives that
            // key is the union of ALL of `S`'s values, which each one is a
            // member of. tsc reaches this through the key parameter's own
            // constraint (`getTypeParameterFromMappedType` carries
            // `getConstraintTypeFromMappedType`), which ztsc's `.mapped_param`
            // does not have — so `function f<U>(a: U): MyMap<U> { return a; }`
            // was a phantom TS2322.
            //
            // Gated on the map iterating no key `S` has not got: a key set
            // written WIDER than `keyof S` (`{ [P in "a" | "b"]: S["a" | "b"] }`
            // over `S = { a: string }`) produces a required `b` the source
            // cannot supply.
            if (c.ts.kind(val) == .index_access and
                c.ts.indexAccessObj(val) == s and
                c.ts.indexAccessIndex(val) == try c.mappedKeySet(t) and
                try c.isAssignable(try c.mappedKeySet(t), try c.keyofType(s))) return true;
        }
        // tsc `structuredTypeRelatedTo`, verbatim: "An empty object type is
        // related to any mapped type that includes a '?' modifier." Every
        // key such a map produces is optional, so a source with no members
        // satisfies all of them — whatever key set the map is still
        // deferred on. This is what makes `Delta.empty()`, which returns
        // `Delta<unknown>` (`deleted: Partial<unknown>` = `{}`), a legal
        // `Delta<T>` inside `Delta.calculate<T>`.
        if (c.mappedAddsOptional(t) and c.isEmptyObjectType(try c.resolveStructural(s))) return true;
        // tsc `structuredTypeRelatedTo`, the `includeOptional` half: "A source
        // type `T` is related to a target type `{ [P in Q]?: X }` if SOME
        // constituent `Q'` of `Q` is related to `keyof T` and `T[Q']` is
        // related to `X`." tsc spells the "some constituent" test as
        // `intersectTypes(targetKeys, sourceKeys)` not being `never`, and then
        // indexes the SOURCE by that filtered key set rather than by the map's
        // whole (still-deferred) one.
        //
        // Every key the map produces is optional, so the keys `S` does not
        // have are simply absent — only the ones it DOES have have to match
        // the template. `Errors<D> = { readonly [K in keyof D | "base"]?:
        // string[] }` returned from `getErrors()` as `{ base: ["…"] }` is the
        // shape: `keyof D` is deferred, so the required-key rule below
        // rejected it outright even though `base` is the only key involved.
        if (c.mappedAddsOptional(t)) {
            const skeys = try c.keyofType(try c.resolveStructural(s));
            var applicable: std.ArrayList(TypeId) = .empty;
            defer applicable.deinit(c.scratch());
            const tkeys = try mappedTargetKeys(c, t);
            const tk_res = try c.resolveStructural(tkeys);
            const constituents: []const TypeId = if (c.ts.kind(tk_res) == .union_type)
                try c.memberList(tk_res)
            else
                &.{tkeys};
            for (constituents) |q| {
                if (try c.isAssignable(q, skeys)) try applicable.append(c.scratch(), q);
            }
            // …and the same intersection taken from the SOURCE side, for a
            // target key set that is still DEFERRED. tsc writes this test as
            // `intersectTypes(targetKeys, sourceKeys)` not being `never`, and
            // an intersection with a deferred `keyof T` is never `never` — so
            // `{ [K in keyof T]?: number }` (`T extends { x: number }`)
            // accepts `{ x: 1 }`, indexing the source by `keyof T & "x"`.
            // Asking "is `q` a key of the source" cannot see that: the
            // deferred `keyof T` widens to `string | number | symbol` and
            // matches nothing. Asking the mirror question — "is this SOURCE
            // key one the map produces" — reaches the constraint route on
            // `keyof T` and answers `"x"`, which is the key set to index by
            // (`mappedTypeRelationships` f90).
            if (applicable.items.len == 0) {
                const sk_res = try c.resolveStructural(skeys);
                const s_parts: []const TypeId = if (c.ts.kind(sk_res) == .union_type)
                    try c.memberList(sk_res)
                else
                    &.{skeys};
                for (s_parts) |q| {
                    if (try c.isAssignable(q, tkeys)) try applicable.append(c.scratch(), q);
                }
            }
            if (applicable.items.len == 0) return null;
            const filtered = try c.ts.makeUnion(c.scratch(), applicable.items);
            const access = try c.reduceIndexedAccess(s, filtered);
            return if (try c.isAssignable(access, try mappedTargetTemplate(c, t))) true else null;
        }
        // tsc `structuredTypeRelatedTo`: `S` is related to `{ [P in C]: X }`
        // when `keyof S` is related to `C` and `S[P]` is related to `X`.
        // Guarded, as tsc guards it, on the target not adding `?` — that
        // direction (`S` → `Partial<S>`) is a different rule.
        //
        // …and on the target not REMOVING `?`. tsc's `!(modifiers &
        // MappedTypeModifiers.ExcludeOptional)` wraps this whole family of
        // source-to-mapped-target rules, not just the identity fast path
        // above: a `-?` map REQUIRES every key its source may have declared
        // optional, so `Required<T>` is not something a bare `T` (or an
        // `{}`) satisfies. Without the gate the general rule below saw a
        // matching key set and a template of `T[P]` and said yes — the
        // `Required<T>`/`Denullified<T>` half of `mappedTypes6`.
        if (c.ts.mappedFlags(t) & types.mapped_flag_optional_remove != 0) return null;
        if (c.mappedAddsOptional(t)) return null;
        // tsc relates the TARGET's key set to the SOURCE's, not the other way
        // round (`isRelatedTo(targetKeys, sourceKeys)`), and the direction is
        // the whole rule: every key the map PRODUCES has to be one the source
        // supplies. Asked backwards, a source with the wrong keys passed
        // whenever its own keys happened to fit — `Readonly<Thing>` met
        // `Readonly<T>` for a `T extends Thing`, because `"a" | "b"` reaches
        // `keyof T` through `T`'s constraint while `keyof T` reaches nothing
        // (`mappedTypeRelationships` f41).
        const tkeys = try mappedTargetKeys(c, t);
        if (!try c.isAssignable(tkeys, try c.keyofType(s))) return null;
        // tsc indexes the source by the map's own key PARAMETER (`S[P]` against
        // the template `T[P]`, which is then free), except when the keys are
        // REMAPPED: an `as` clause means the produced keys are `R`, not `P`, so
        // the source is indexed by `R` — tsc's `indexingType = keysRemapped ?
        // (filteredByApplicability || targetKeys) : …typeParameter`.
        const idx = if (c.ts.mappedAs(t) != 0) tkeys else c.ts.mappedKeyParam(t);
        const access = try c.reduceIndexedAccess(s, idx);
        return if (try c.isAssignable(access, try mappedTargetTemplate(c, t))) true else null;
    }
    // A still-generic map relates to a pure index-signature target when its
    // TEMPLATE relates to the index value — `Object.entries`' `{[s: string]:
    // V}`. Restricted to a target with no NAMED members: a deferred map
    // declares no property this side could satisfy one with.
    if (sk == .mapped) {
        const rt = try c.resolveStructural(t);
        if (c.ts.kind(rt) == .object and
            c.ts.objectPropCount(rt) == 0 and
            c.ts.objectCallSigCount(rt) == 0 and
            c.ts.objectConstructSigCount(rt) == 0 and
            c.ts.objectStringIndex(rt) != 0)
        {
            // The map's own key set is NOT consulted: tsc's
            // `indexSignaturesRelatedTo` reads
            //
            //     isGenericMappedType(source) && targetHasStringIndex
            //         ? isRelatedTo(getTemplateTypeFromMappedType(source), targetInfo.type)
            //         : typeRelatedToIndexInfo(source, targetInfo, …)
            //
            // — for a still-generic map the TEMPLATE alone answers, whatever
            // keys the map will end up producing. `WeakValidationMap<P>` over
            // an unconstrained `P` produces no keys this side can name, and
            // refusing it made every React `ComponentClass<P>` fail its
            // `ComponentClass<any>` constraint once `WeakValidationMap<any>`
            // stopped being `any` (`propTypes?: WeakValidationMap<P>` is the
            // member that carries it).
            //
            // A template that does NOT relate falls through to the arms below
            // rather than answering `null` for the whole function: with the
            // key-set guard gone this arm is reached by maps it used to skip
            // outright, and swallowing them cost the ones a later arm answers
            // (`spuriousCircularityOnTypeImport`, whose `FuncMap extends
            // SelectorMap<FuncMap>` is decided by the identity-map rule).
            if (try mappedTemplateAtString(c, s)) |tmpl| {
                if (try c.isAssignable(tmpl, c.ts.objectStringIndex(rt))) {
                    const nidx = c.ts.objectNumberIndex(rt);
                    if (nidx == 0 or try c.isAssignable(tmpl, nidx)) return true;
                }
            }
        }
    }
    // tsc `structuredTypeRelatedTo`, the SOURCE-mapped arm: "a source type
    // `{ [P in Q]: X }` is related to a target type `T` if `keyof T` is
    // related to `Q` and `X` is related to `T[P]`." Narrowed to the shape
    // where `X` IS `T[P]` — the identity map written over an explicit key set
    // rather than over `keyof T` — so the second half is free and the first
    // (a `keyof` of the target) is only computed for a template that already
    // names the target. `Pick<Params, keyof Params>` is the case: it is not
    // homomorphic in ztsc's sense (its key set is a written `Q`, not
    // `keyof Params`), so the identity arm below never saw it.
    //
    // The `keyof T <: Q` gate is what tsc's rule turns on and is not
    // optional: `Pick<T, "a">` and `Pick<T, K>` produce FEWER keys than `T`
    // requires, and tsgo rejects both.
    // A template that WRAPS `T[P]` in an intersection is the same rule with
    // the second half no longer free: `Denullified<T> = { [P in keyof T]-?:
    // NonNullable<T[P]> }` has the template `T[P] & {}` (the lib spells
    // `NonNullable<X>` as `X & {}`), which relates to `T[P]` through its own
    // constituent. The syntactic screen still costs one kind read on a
    // template that does not name the target at all.
    if (sk == .mapped and !c.mappedAddsOptional(s) and c.ts.mappedAs(s) == 0) {
        const val = c.ts.mappedValue(s);
        const exact = isTargetKeyAccess(c, val, t, c.ts.mappedKeyParam(s));
        var names_target = exact;
        if (!names_target and c.ts.kind(val) == .intersection) {
            for (try c.memberList(val)) |m| {
                if (isTargetKeyAccess(c, m, t, c.ts.mappedKeyParam(s))) {
                    names_target = true;
                    break;
                }
            }
        }
        if (names_target and try c.isAssignable(try c.keyofType(t), try c.mappedKeySet(s))) {
            if (exact) return true;
            const acc = try c.reduceIndexedAccess(t, c.ts.mappedKeyParam(s));
            if (try c.isAssignable(val, acc)) return true;
        }
    }
    // tsc's `getBaseConstraintOfType` for a still-generic HOMOMORPHIC map,
    // asked of an ARRAY-ish target: `{ [P in keyof T]: X }` over a `T` bounded
    // by an array or tuple type is an array for EVERY instantiation —
    // `instantiateMappedType` maps an array source to an array and a tuple
    // source element-wise — so the base constraint (the map applied to `T`'s
    // own constraint) is what says whether the family fits.
    //
    // It is also what carries the READONLY-ness through:
    // `mappedTypeUnionConstrainTupleTreatedAsArrayLike` is a map over
    // `T extends [number] | [string]`, which is a legal `any[]`, beside one
    // over `T extends [number] | readonly [string]`, which is only a
    // `readonly any[]` — and tsgo reports exactly that one line.
    //
    // Restricted to an array-ish target and a bare type-parameter source, so
    // an ordinary object-shaped map pays nothing: two kind reads on a pair
    // that has already failed every rule above.
    if (sk == .mapped and (tk == .array or tk == .tuple) and c.ts.mappedHomomorphic(s)) {
        if (try homomorphicConstraintInstantiation(c, s)) |inst| {
            if (try c.isAssignable(inst, t)) return true;
        }
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

/// Is `v` exactly the access `obj[key]` — the mapped template that reads its
/// relation target at the map's own key parameter?
fn isTargetKeyAccess(c: *Checker, v: TypeId, obj: TypeId, key: TypeId) bool {
    return c.ts.kind(v) == .index_access and
        c.ts.indexAccessObj(v) == obj and
        c.ts.indexAccessIndex(v) == key;
}

/// A still-generic HOMOMORPHIC map applied to its source parameter's own
/// CONSTRAINT — tsc's `getBaseConstraintOfType` for a mapped type. Null when
/// the source is not a bare constrained parameter, or when the map does not
/// materialize into something new.
///
/// A UNION constraint is distributed member-wise, because that is what
/// `instantiateMappedType` does ("if T is a union type we distribute the
/// mapped type over the union") and ztsc's `materializeMapped` does not: it
/// would otherwise fold the whole union into one object and lose the very
/// array-ness the caller is asking about.
fn homomorphicConstraintInstantiation(c: *Checker, m: TypeId) Error!?TypeId {
    const s = &c.ts;
    const src = s.mappedSource(m);
    if (s.kind(src) != .type_param) return null;
    const sym = s.typeParamSymbol(src);
    const cons = try c.typeParamConstraint(sym);
    if (cons == types.no_type or cons == src) return null;
    if (s.kind(cons) != .union_type) {
        const map = [_]TpMap{.{ .sym = sym, .ty = cons }};
        const inst = try c.instantiate(m, &map);
        return if (inst == m) null else inst;
    }
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(cons)) |member| {
        const map = [_]TpMap{.{ .sym = sym, .ty = member }};
        const inst = try c.instantiate(m, &map);
        if (inst == m) return null;
        try parts.append(c.scratch(), inst);
    }
    return try s.makeUnion(c.scratch(), parts.items);
}

/// The base-constraint reduction of a deferred indexed-access TARGET `T[K]`
/// (tsc `structuredTypeRelatedTo`, IndexedAccess-as-target): a source is
/// related to `T[K]` when it is related to this. Null when the access has
/// no meaningful constraint — either side still generic after taking base
/// constraints, or a reduction that lands back on the same deferred access
/// or on an `unknown` that stands for a property the constraint does not
/// have (`indexedAccessType`'s absent-property answer, where tsc's
/// `getIndexedAccessTypeOrUndefined` returns nothing and the rule does not
/// apply). A key the constraint DOES declare as `unknown` is a real
/// reduction and does apply — drizzle's `Column` writes `(value: unknown)
/// => unknown` through `DriverValueMapper<T["data"], T["driverParam"]>`
/// where the constraint's `data`/`driverParam` are declared `unknown`.
pub fn indexAccessTargetConstraint(c: *Checker, t: TypeId) Error!?TypeId {
    const obj_bc = try relationIndexObjConstraint(c, c.ts.indexAccessObj(t));
    // The INDEX takes a single constraint step, not a fixpoint: for
    // `K extends keyof T` that step lands on the deferred `keyof T`, which
    // is still generic and (correctly) blocks the rule. Iterating would
    // collapse it through `keyof unknown` to `never` and make the access
    // look resolvable — silently accepting anything as `T[K]`.
    const idx_bc = try c.baseConstraintOf(c.ts.indexAccessIndex(t));
    if (try c.isGenericObjectForIndex(obj_bc) or try c.containsFreeTypeParam(idx_bc, &.{})) return null;
    const bc = try writingIndexedAccess(c, obj_bc, idx_bc) orelse return null;
    if (bc == t) return null;
    return bc;
}

/// `getIndexedAccessTypeOrUndefined(obj, idx, AccessFlags.Writing)` — the
/// indexed access as a WRITE target, which is the flag tsc's
/// `structuredTypeRelatedTo` passes when it reduces an IndexedAccess TARGET.
///
/// The difference from the read-side `reduceIndexedAccess` is the union key:
///
///     accessFlags & AccessFlags.Writing ? getIntersectionType(propTypes)
///                                       : getUnionType(propTypes)
///
/// A value written through `Obj[K]` where `K` could be any of several keys has
/// to satisfy EVERY one of those keys, not just one of them — so the constraint
/// is the intersection. Unioning instead let a value that only fits one key
/// through: `JSX.IntrinsicElements[T1]` (the union over `T1`'s constraint) was
/// accepted as `JSX.IntrinsicElements[T2]`, because every constituent of the
/// source union is also a constituent of the target union
/// (`errorInfoForRelatedIndexTypesNoConstraintElaboration`). Intersected, only a
/// value good for all of them — `{}`, since every intrinsic element's props are
/// optional — gets through, which is exactly the pair tsc accepts.
///
/// Null is "no constraint, the rule does not apply", tsc's `undefined` return:
/// either a reduction that lands on an `unknown` standing for a property the
/// constraint does not have (`indexedAccessType`'s absent-property answer,
/// `wasMissingProp` upstream — and upstream one missing key voids the WHOLE
/// union, so the screen runs per constituent), or, for the caller, a reduction
/// back onto the same deferred access. A key the constraint DOES declare as
/// `unknown` is a real reduction and does apply — drizzle's `Column` writes
/// `(value: unknown) => unknown` through `DriverValueMapper<T["data"],
/// T["driverParam"]>` where the constraint's `data`/`driverParam` are declared
/// `unknown`.
fn writingIndexedAccess(c: *Checker, obj: TypeId, idx: TypeId) Error!?TypeId {
    // A union key only distributes once the access is actually resolvable;
    // while either side still carries a mapped-key parameter or an unbound
    // `infer` binder, `reduceIndexedAccess` defers the whole access and there
    // are no per-key types to intersect. (`boolean` needs no special case:
    // ztsc gives it its own kind rather than tsc's `true | false` union, so
    // upstream's `!(indexType.flags & TypeFlags.Boolean)` guard is implicit.)
    const distributes = c.ts.kind(idx) == .union_type and
        !try c.containsMappedParam(idx) and
        !try c.containsMappedParam(obj) and
        !try c.containsInfer(idx);
    if (!distributes) return keyedIndexedAccess(c, obj, idx);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(idx)) |m| {
        const p = try keyedIndexedAccess(c, obj, m) orelse return null;
        try parts.append(c.scratch(), p);
    }
    return try c.ts.makeIntersection(c.scratch(), parts.items);
}

/// One key's write type, or null when the key is absent from `obj` (see
/// `writingIndexedAccess`).
fn keyedIndexedAccess(c: *Checker, obj: TypeId, key: TypeId) Error!?TypeId {
    const p = try c.reduceIndexedAccess(obj, key);
    if (c.ts.kind(p) == .unknown and !try c.indexKeyDeclared(obj, key)) return null;
    return p;
}

/// Does `obj` actually declare the single literal key `idx`? Used to tell
/// `indexedAccessType`'s two `unknown` answers apart — a declared
/// `unknown`-typed property from an absent one.
pub fn indexKeyDeclared(c: *Checker, obj: TypeId, idx: TypeId) Error!bool {
    if (c.ts.kind(idx) != .string_literal) return false;
    const r = try c.resolveStructural(obj);
    return (try c.propOfType(r, c.ts.literalAtom(idx))) != null;
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
    // …and the same rule at the TOP, for a LIST object: `computeBaseConstraint`
    // ends in `return t` for anything that is not itself instantiable, so a
    // container is its own base constraint and its element types are left
    // alone. `transitiveBaseConstraint` substitutes them, and both
    // indexed-access rules then decline: the object of `NoInfer<T>`'s encoding
    // (`[T][T extends any ? 0 : never]`, the shape `noInferWrapper` builds)
    // came back `[unknown]`, so the access reduced to `unknown` and `return
    // this._value` inside a `class C<T>` was a false TS2322 against `T`
    // (`noInfer.ts:80`, `narrowingNoInfer1`). Left alone, the object is `[T]`,
    // the index's own base constraint is `0`, and the access is exactly `T`.
    //
    // Tuples and arrays ONLY, not tsc's whole `return t` fallthrough: widening
    // it to every non-instantiable kind takes the substitution away from an
    // OBJECT object too, and zod's `flatten<addQuestionMarks<
    // baseObjectOutputType<Shape>>>` then stops relating to the mapped shape
    // it is asserted to (`declarationEmitMappedTypePreservesTypeParameter-
    // Constraint`, a false TS2352). A list is the shape the deferred access
    // needs and the one whose positional read is unambiguous.
    const k = c.ts.kind(t);
    if (k == .tuple or k == .array) return t;
    if (k != .type_param) return c.transitiveBaseConstraint(t);
    var cur = t;
    var i: u32 = 0;
    while (i < 8 and c.ts.kind(cur) == .type_param) : (i += 1) {
        // An UNCONSTRAINED parameter is its own base constraint. tsc's
        // `computeBaseConstraint` returns `undefined` for it, and both
        // callers then keep the parameter and see a generic object, which
        // stops the rule. `baseConstraintOf` instead substitutes it with
        // `unknown` — and `unknown[never]` (the index side of `T[keyof T]`
        // collapses the same way) reduces to `never`, a source assignable
        // to absolutely everything. That is what made `T[keyof T]` and
        // `U[keyof T]` interchangeable, and `T[keyof T]` assignable to any
        // annotation at all (`mappedTypeRelationships` f3–f13,
        // `keyofAndIndexedAccess2`).
        if (try c.typeParamConstraint(c.ts.typeParamSymbol(cur)) == types.no_type) break;
        const next = try c.baseConstraintOf(cur);
        if (next == cur) break;
        cur = next;
    }
    return cur;
}

/// The object side of a deferred indexed access, for the RELATION's two rules
/// (`indexAccessTargetConstraint` and the `.index_access` source arm) — which
/// is `indexObjBaseConstraint` plus tsc's constituent-wise reading of an
/// INTERSECTION.
///
/// Falling through to `transitiveBaseConstraint` there substituted the
/// constituents' members instead, so the object half of `(Y & { a: T })` came
/// back `{ a: unknown }` and the access reduced to `unknown` — which both rules
/// read as "no constraint" and decline on. That is a family of false positives,
/// all of it the HKT encoding: `(THKT & { readonly config: TConfig })["type"]`
/// is how drizzle's `PreparedQueryKind` applies a type-level function, and the
/// `execute:` member built from it did not relate to the `execute()` its base
/// class declares (`mysql-core/query-builders/insert.d.ts`, a phantom TS2416).
/// The constituent-wise reading keeps `{ a: T }` intact, so the access is `T` —
/// exactly what tsc computes.
///
/// The RELATION only, not `indexObjBaseConstraint` itself: its other callers
/// ask a different question — what apparent members does `T[K]` have, and is
/// this receiver one to defer over (`indexDeferrableObject`) — and the answer
/// they want for `T & { [k in keyof T]: Spy }` is the whole substituted shape,
/// not the mapped constituent alone (`spyComparisonChecking`, where dropping
/// the unconstrained `T` half left a bare mapped type and stopped the access
/// deferring at all).
fn relationIndexObjConstraint(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .intersection)
        return (try intersectionBaseConstraint(c, t, 0)) orelse t;
    return indexObjBaseConstraint(c, t);
}

/// The KEY side of a deferred indexed access, for the same rule — tsc's
/// `computeBaseConstraint`, `TypeFlags.Index` case:
///
/// ```ts
/// if (t.flags & TypeFlags.Index) {
///     return keyofConstraintType;   // string | number | symbol
/// }
/// ```
///
/// A `keyof X` answers the PROPERTY-KEY domain, never `keyof <constraint of
/// X>`: the keys of an object known only by a constraint are known only to be
/// property keys, because a subtype may declare more of them. `baseConstraintOf`
/// instead instantiates `X` with its constraint and answers the much narrower
/// `keyof <constraint>`, which is a strictly smaller key set than `T[keyof T]`
/// actually ranges over.
///
/// It is what decides `T[keyof T]` under `T extends object`: tsc reads the key
/// as `string | number | symbol`, finds `object` has no index signature that
/// answers it, and therefore gives the access NO base constraint at all — so
/// `let b: number = a` is the TS2322 `indexedAccessConstraints:6:9` asks for.
/// ztsc reduced `keyof object` to `never`, made the access `never`, and
/// silently accepted every target. The same reading is why `T extends { a:
/// number; b: number }` still errors (oracle-pinned): the constraint declares
/// two NAMED keys and no index signature, so it cannot answer the key domain
/// either. `T extends Record<string, number>` does answer it, and keeps
/// reducing to `number`.
///
/// `narrowable.constraintOrSelf` carries the same rule for the narrowing side;
/// this is the relation's copy of it, over the one operand the relation asks
/// about (extracting a shared helper would mean exporting one of the two
/// modules' notion of "resolved for inspection", which differs).
///
/// TRANSITIVE, as `getBaseConstraint` is — and the `keyof` rule applies at
/// every step, not only the first. `K extends keyof T` takes two: `K` to the
/// deferred `keyof T`, and that to the property-key domain. Stopping after one
/// left `keyof T` — still generic — and the caller's free-parameter guard then
/// declined every `T[K]` written that way, so `obj[key]` under
/// `<T extends ItemMap, K extends keyof T>` had no constraint at all and could
/// not be read as an `Item` (`mappedTypeRelationships` `f51`, which is exactly
/// `f50`'s `T[keyof T]` one alias further out).
///
/// The extra step is not the collapse the TARGET rule refuses
/// (`indexAccessTargetConstraint`): that one is about iterating
/// `baseConstraintOf`, which instantiates `T := unknown` and reduces
/// `keyof unknown` to `never`. Answering the property-key DOMAIN is the
/// opposite move — the widest key set, not the narrowest — and it is guarded
/// by `keyDomainAnswerable`, which is why it cannot make an unresolvable
/// access accept everything.
const IndexKeyConstraint = struct {
    ty: TypeId,
    /// The chain ended in the property-key domain, so the object side has to
    /// be able to answer that whole domain for the reduction to stand.
    from_keyof: bool,
};

fn relationIndexKeyConstraint(c: *Checker, idx: TypeId) Error!IndexKeyConstraint {
    var cur = idx;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        if (c.ts.kind(cur) == .keyof_op) return .{ .ty = try c.propertyKeyType(), .from_keyof = true };
        const next = try c.baseConstraintOf(cur);
        if (next == cur) break;
        cur = next;
    }
    return .{ .ty = cur, .from_keyof = false };
}

/// tsc's `getIndexedAccessTypeOrUndefined` answering UNDEFINED — the other
/// half of the `keyof` rule above, and the reason widening the key is not
/// enough on its own.
///
/// `computeBaseConstraint` only keeps the reduction when the object side can
/// answer the WHOLE key domain:
///
/// ```ts
/// const baseIndexedAccess = baseObjectType && baseIndexType &&
///     getIndexedAccessTypeOrUndefined(baseObjectType, baseIndexType, t.accessFlags);
/// return baseIndexedAccess && getBaseConstraint(baseIndexedAccess);
/// ```
///
/// ztsc's `indexedAccessType` has no "undefined": an absent NAMED property
/// answers `unknown` (which the caller already screens out) but an absent
/// INDEX SIGNATURE answers `any`, deliberately — every ordinary read through
/// a `string` key wants the permissive answer. Handed `string | number |
/// symbol` that `any` says "relates to everything", so the widened key alone
/// changed nothing: `object[string | number | symbol]` came back `any` where
/// it used to come back `never`, and both accept every target.
///
/// So the domain question is asked separately, and only when the key's
/// constraint chain BOTTOMED OUT in the property-key domain
/// (`IndexKeyConstraint.from_keyof`) — every other key shape reduces to a
/// concrete member and keeps its existing answer. A string index signature is
/// the one thing that answers a key known only to be a property key; a table
/// of NAMED members does not, which is exactly why tsc still errors under
/// `T extends { a: number; b: number }` (oracle-pinned,
/// `indexedAccessConstraints`). An `any`/error object answers everything by
/// definition.
fn keyDomainAnswerable(c: *Checker, obj_bc: TypeId, from_keyof: bool) Error!bool {
    if (!from_keyof) return true;
    const r = try c.resolveStructural(obj_bc);
    return switch (c.ts.kind(r)) {
        .any, .err => true,
        .object => c.ts.objectStringIndex(r) != 0,
        else => false,
    };
}

/// The base constraint of an INTERSECTION object, tsc's `computeBaseConstraint`
/// for a `UnionOrIntersection`:
///
/// ```ts
/// for (const type of types) {
///     const baseType = getBaseConstraint(type);
///     if (baseType) { if (baseType !== type) different = true; baseTypes.push(baseType); }
///     else { different = true; }
/// }
/// if (!different) return t;
/// return … getIntersectionType(baseTypes) …
/// ```
///
/// `null` is tsc's `undefined` — every constituent was dropped, so the
/// intersection has no constraint at all and the caller's rule declines.
/// A constituent keeps its own shape: only a type PARAMETER moves (to its
/// constraint chain's end), and an unconstrained one disappears, which is what
/// makes `Y & { a: T }` read as `{ a: T }` rather than as `{ a: unknown }`.
fn intersectionBaseConstraint(c: *Checker, t: TypeId, depth: u32) Error!?TypeId {
    if (depth > max_intersection_constraint_depth) return t;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    var different = false;
    // Indexed rather than held as a slice: the recursive calls below intern
    // types, and the member list aliases store memory.
    for (0..c.ts.memberCount(t)) |i| {
        const m = c.ts.memberAt(t, i);
        if (try intersectionMemberBaseConstraint(c, m, depth)) |bc| {
            if (bc != m) different = true;
            try parts.append(c.scratch(), bc);
        } else different = true;
    }
    if (!different) return t;
    if (parts.items.len == 0) return null;
    return try c.ts.makeIntersection(c.scratch(), parts.items);
}

/// How deep the constituent walk follows nested intersections and indexed
/// accesses. Each step is a strictly smaller type in practice; the cap is
/// there so a pathological constraint cycle cannot spin.
const max_intersection_constraint_depth: u32 = 8;

/// One constituent's contribution to `intersectionBaseConstraint`. `null` when
/// the constituent has no base constraint of its own — tsc's `undefined`, the
/// answer `computeBaseConstraint` gives an unconstrained type parameter.
fn intersectionMemberBaseConstraint(c: *Checker, m: TypeId, depth: u32) Error!?TypeId {
    return switch (c.ts.kind(m)) {
        .type_param => blk: {
            if (try c.typeParamConstraint(c.ts.typeParamSymbol(m)) == types.no_type) break :blk null;
            break :blk try indexObjBaseConstraint(c, m);
        },
        .this_type => c.ts.thisTypeInstance(m),
        .intersection => try intersectionBaseConstraint(c, m, depth + 1),
        // An indexed access is instantiable too, and `computeBaseConstraint`
        // reduces it the same way the relation's own rules do: constrain both
        // operands, then index. This is the constituent the HKT encoding
        // actually produces — `Assume<(THKT & { config: C })["type"], PQ<C>>`
        // reads its true branch as `X & PQ<C>` with `X` that access — so
        // without this arm the intersection stays generic and the rule declines.
        .index_access => blk: {
            const obj_bc = try relationIndexObjConstraint(c, c.ts.indexAccessObj(m));
            const idx_bc = try c.baseConstraintOf(c.ts.indexAccessIndex(m));
            if (try c.isGenericObjectForIndex(obj_bc)) break :blk m;
            if (try c.containsFreeTypeParam(idx_bc, &.{})) break :blk m;
            const bc = try c.reduceIndexedAccess(obj_bc, idx_bc);
            break :blk if (c.ts.kind(bc) == .unknown) m else bc;
        },
        // Not instantiable: `computeBaseConstraint` ends in `return t`.
        else => m,
    };
}

/// tsc's `getBaseConstraintOfType`: follow constraints all the way down.
/// `baseConstraintOf` substitutes each type param in `t` with its
/// *immediate* constraint from a fixed map, so `U extends T extends Base`
/// only reaches `T`; re-running it to a fixpoint reaches `Base`.
/// tsc's `TypeFlags.Instantiable`: a type variable, or one of the deferred
/// operators over one, whose meaning is still pending a substitution.
///
/// Two callers ask it, for the two reasons tsc asks it. Against a UNION target
/// such a type answers from a constraint that can itself be a union, so asking
/// it one union member at a time can only under-answer. As the INDEX of an
/// indexed access it may still instantiate to a union and re-trigger index
/// distribution, which is why `getSimplifiedIndexedAccessType` refuses to
/// distribute over the object until the index is not one
/// (`mapped.IndexSimplify.relation`).
///
/// A union OF instantiables is not itself instantiable, so the shallow kind
/// test is the whole test — matching tsc, where the flag is a leaf property.
pub fn isInstantiableKind(k: types.Kind) bool {
    return switch (k) {
        .type_param, .this_type, .index_access, .conditional, .keyof_op, .mapped, .string_mapping, .template_literal_type => true,
        else => false,
    };
}

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

/// The RELATION's source-side property lookup: tsc's `getPropertyOfType`,
/// including the tail `propOfTypeEx(…, false)` deliberately stops before —
/// `return getPropertyOfObjectType(globalObjectType, name)`. Every object type
/// also carries the apparent members of the global `Object` interface
/// (`toString`, `valueOf`, `hasOwnProperty`, `constructor`, `isPrototypeOf`,
/// `propertyIsEnumerable`, `toLocaleString`), so a source that declares none of
/// them still satisfies a target that asks for one. That is what makes
/// `object`, `{}`, and any interface or class instance assignable to `Object` —
/// the target every `Object`-typed parameter in a lib, and in every hand-written
/// API that predates `unknown`, is spelled with. Without it those pairs were
/// TS2740 ("missing the following properties from type 'Object'"), and so was
/// `{ toString(): string }`, `Object | number`, and `{ constructor: Function }`.
///
/// Member access already had the augment (`propOfTypeEx` with `allow_index`);
/// what it stops short of is the RELATION, on the grounds that the
/// excess-property check must not consult the global object type. That much is
/// right — `isKnownProperty` does not, and neither may a *target*'s own
/// property list — but `propertiesRelatedTo` and `getUnmatchedProperty` both
/// call the augmenting `getPropertyOfType` on the SOURCE, so the relation does
/// get it.
///
/// Consulted for an OPTIONAL target property too, exactly where tsc consults
/// it: `getUnmatchedProperty` skips optional names, but the loop after it
/// relates every target property the source *has*, and with the augment the
/// source has these. `{ toString?: () => number }` is therefore a failure for
/// every object rather than a vacuously satisfied weak type (oracle-verified,
/// `assignability/object_interface_apparent_members`).
///
/// Restricted to sources whose apparent type is an object type: `object` maps
/// to `{}` (tsc `getApparentType`, `TypeFlags.NonPrimitive → emptyObjectType`),
/// while a primitive maps to its own lib interface, which declares these
/// members itself and reaches them through `propOfTypeEx`.
///
/// `pub` for `assign_report.tryReportMissingProps`, which has to name a
/// property "missing" by exactly the rule the relation used to reject it.
pub fn relationSrcProp(c: *Checker, s: TypeId, name: Atom) Error!?types.Prop {
    if (try c.propOfTypeEx(s, name, false)) |p| return p;
    // A tuple's own numeric members. tsc's tuple IS an object type carrying
    // `"0"`, `"1"`, … for its fixed elements, so no rule of the relation has to
    // know it is a tuple; ztsc stores elements positionally, so the names need
    // synthesizing here — see `tuple_relate.numericProp`.
    if (tuple_zig.numericProp(c, s, name)) |p| return p;
    if (!isNonPrimitiveKind(c.ts.kind(s))) return null;
    return c.objectInterfaceProp(name);
}

/// Object-target structural check. `s` is any structural source
/// (object, array/tuple/string via length lookup, function, ...).
pub fn structuralAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (c.ts.kind(t) != .object) return false;
    // tsc's `IntersectionState.Target` is an ARGUMENT to one relation frame,
    // not a mode that hangs over the subtree. `typeRelatedToEachType` hands it
    // to `isRelatedTo(source, constituent)` — which is where it suspends the
    // weak-type rule, so `{ a: 1 }` may meet `{ a: number } & { b?: X }` — and
    // `propertiesRelatedTo` then recurses into each property with
    // `IntersectionState.None`. So the rule resumes ONE LEVEL DOWN:
    //
    // ```ts
    // type Weak = { a?: number, properties?: { b?: number } };
    // let w: Weak & { nope?: string } = { properties: { wrong: "" } };
    // //  TS2322: `{ wrong: string }` has no properties in common with
    // //  `{ b?: number }` — the NESTED target is weak on its own terms
    // ```
    //
    // ztsc held the flag for the whole subtree, so every weak target under an
    // intersection target went unchecked (`weakType.ts:63`).
    //
    // No memo hazard: `weakTypeMismatch` runs AHEAD of the relation memo (see
    // `relate`), so no cached verdict ever encoded the flag's value — and the
    // frames below this one are now computed in the state they would be
    // computed in anywhere else, which is strictly better than before.
    const saved_intersection_target = c.rel_intersection_target;
    c.rel_intersection_target = 0;
    defer c.rel_intersection_target = saved_intersection_target;
    // `undefined` / `null` / `void` are not object values. The empty-object
    // fast path below said so, but a target with members reached the
    // property loop instead, where every property of a nullish source is
    // simply absent — so an ALL-OPTIONAL target (`{ a?: string }`,
    // `Partial<T>`) fell through the loop and returned true. Under
    // strictNullChecks tsc rejects all of these (TS2322), whatever the
    // target's optionality.
    //
    // `unknown` is the same hole one step up: tsc relates the top type to
    // `any` and `unknown` and to nothing else, where here it would reach both
    // the empty-object fast path ("anything non-nullish") and the all-optional
    // fall-through — so it was assignable to `{}`, to `{ a?: number }` and to
    // every `Partial<T>`.
    switch (c.ts.kind(s)) {
        .null, .undefined, .void, .unknown => return false,
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
    // tsc's `getUnmatchedProperty`, which `propertiesRelatedTo` runs to
    // completion BEFORE it relates a single property type. The loop below
    // already fails on a required target property the source lacks — but it
    // finds out in property order, so a pair that is unrelated for a name the
    // walk reaches late pays a full recursive relation for every name before
    // it. Answering the presence question over the whole table first is a
    // strict fast path: it returns `false` exactly where the loop already
    // does, only sooner.
    //
    // The cost of NOT having it is not marginal on a fluent generic API.
    // zod's `deoptional<T>` asks `ZodString extends ZodOptional<infer U>`;
    // `ZodOptional` declares `unwrap()`, which `ZodString` has not got, so
    // the pair is dead — but `unwrap` sorts late among ~60 members, and every
    // earlier one (`and`, `array`, `brand`, `catch`, `default`, `optional`,
    // `pipe`, `refine`, …) hands back a `Wrapper<this>` whose relation
    // recurses into another instantiation of the same family. One
    // `deoptional<ZodString>` cost 4.46 M node visits before this pre-pass.
    //
    // Name-only: `propOfTypeEx` is the same lookup the loop performs and its
    // answer is memoized, so the pre-pass does no work the loop would not
    // have done anyway — it only reorders when the work happens.
    for (0..n) |i| {
        const tp = c.ts.objectProp(t, @intCast(i));
        if (tp.optional()) continue;
        if ((try relationSrcProp(c, s, tp.name)) == null) return false;
    }
    for (0..n) |i| {
        const tp = c.ts.objectProp(t, @intCast(i));
        // A source string index signature does NOT satisfy a required named
        // target property (tsc TS2741/TS2740); it is related separately as an
        // index signature below. So `{ [k: string]: any }` is not assignable
        // to `Date`/`{ x: number }`.
        const sp = (try relationSrcProp(c, s, tp.name)) orelse {
            if (tp.optional()) continue;
            return false;
        };
        if (sp.optional() and !tp.optional()) return false;
        // tsc's `private`/`protected` screen, ahead of relating the member
        // types exactly as `propertiesRelatedTo` runs it. Gated on the flag
        // already loaded on both `Prop`s — see `nominal_members.zig`.
        if ((sp.nonPublic() or tp.nonPublic()) and
            !try nominal_members.nonPublicPropRelated(c, s, t, tp.name, sp.nonPublic(), tp.nonPublic())) return false;
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
    // A target string index whose type is exactly `any` short-circuits the
    // whole index-signature relation for any NON-PRIMITIVE source (tsc
    // `indexSignaturesRelatedTo`: `targetHasStringIndex && targetInfo.type
    // & TypeFlags.Any` → `Ternary.True`, guarded by `!sourceIsPrimitive`).
    // This is what makes `Record<string, any>` the "any object" escape hatch
    // it is in practice: an interface or class instance, which has no index
    // signature of its own and no implied one, still satisfies it — and it
    // is why `T extends Record<string, any>` (react-hook-form's
    // `FieldValues`, the shape `instantiation/025` and `jsx/017` are built
    // on) accepts a plain `interface Form`. `unknown` does NOT get the
    // exemption — it is not `any` (verified against the oracle:
    // conformance `assignability/058`).
    const sidx_any = sidx != 0 and isNonPrimitiveKind(c.ts.kind(s)) and
        c.ts.kind(try c.resolveStructural(sidx)) == .any;
    if (sidx != 0 and !sidx_any) {
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
            else => return false,
        }
    }
    // Target number index signature. Arrays and tuples always carry a
    // numeric index; a source `string` indexes numerically to `string`; an
    // object satisfies via a source number index, a source string index
    // (string keys subsume numeric ones), or — when it has an implied index
    // — its *numerically named* properties.
    //
    // The `any`-valued exemption above is a rule about the index info being
    // related, not about the string one: tsc runs the SAME test for every
    // info of the target (`for (const targetInfo of indexInfos)`), and its
    // condition is `!sourceIsPrimitive && targetHasStringIndex &&
    // targetInfo.type & TypeFlags.Any` — "the target has a string index
    // signature *somewhere*" AND "*this* info's value type is `any`". So a
    // target spelled `{ [x: string]: any; [x: number]: any }` is satisfied by
    // any non-primitive source through both of its infos, while
    // `{ [x: number]: any }` alone (no string index) and
    // `{ [x: string]: any; [x: number]: string }` (this info not `any`) are
    // satisfied by neither — all three oracle-verified.
    //
    // Leaving the number arm unguarded cost an interface/class/function
    // source that whole target, and that target is `NonReactStatics<any>` —
    // a member of styled-components' `StyledComponent<C,T,O,A> = string &
    // StyledComponentBase<…> & NonReactStatics<…>`, i.e. of
    // `AnyStyledComponent`. So `typeof SomeStyled` failed
    // `C extends AnyStyledComponent`, every `styled(SomeStyled)` fell to the
    // second overload, and every prop of every such element was checked
    // against `StyledComponentPropsWithAs<…>` instead of the inner
    // component's own props.
    const nidx_any = nidx != 0 and sidx != 0 and isNonPrimitiveKind(c.ts.kind(s)) and
        c.ts.kind(try c.resolveStructural(nidx)) == .any;
    if (nidx != 0 and !nidx_any) {
        switch (c.ts.kind(s)) {
            .array => {
                if (!try c.isAssignable(c.ts.arrayElem(s), nidx)) return false;
            },
            .tuple => {
                for (0..c.ts.tupleLen(s)) |i| {
                    // Through `tupleElemTypeAt`, because a REST element stores
                    // its ARRAY type: `[string, ...number[]]` reaches a
                    // `[k: number]` signature with `number`, not `number[]`.
                    // Reading `.ty` straight rejected every rest tuple against
                    // every number index signature it actually satisfies.
                    const et = (try tupleElemTypeAt(c, s, @intCast(i))) orelse continue;
                    if (!try c.isAssignable(et, nidx)) return false;
                }
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
                        // An OPTIONAL property keeps its `| undefined` against a
                        // NUMBER index signature. tsc's `membersRelatedToIndexInfo`
                        // strips the `undefined` an optional property carries
                        // (`getTypeWithFacts(propType, NEUndefined)`) — but not
                        // when `keyType === numberType`, which is a separate
                        // clause of the same condition. So `{ [k: string]: string }`
                        // accepts `{ k1?: string }` and `{ [k: number]: string }`
                        // refuses `{ 1?: string }`
                        // (`optionalPropertyAssignableToStringIndexSignature`).
                        // ztsc keeps the `| undefined` out of the stored property
                        // type and unions it in at read time, so the string arm
                        // above already reads as tsc's stripped form and only this
                        // one has to put it back.
                        const spt = if (sp.optional())
                            try c.makeUnion2(sp.ty, types.undefined_type)
                        else
                            sp.ty;
                        if (!try c.isAssignable(spt, nidx)) return false;
                    }
                } else return false; // interface / class instance, no index sig
            },
            // tsc reads the SOURCE's own index infos here
            // (`indexSignaturesRelatedTo` → `getIndexInfoOfType(source, …)`),
            // and those come off its APPARENT type: every string-like
            // primitive's is `String`, whose one index signature is
            // `readonly [index: number]: string`. Covering only the `string`
            // type itself missed the type a string expression actually HAS —
            // a string literal — and with it `` `a${string}` `` and
            // `Uppercase<T>`. `var s: String = "x"` was TS2322 on that
            // account, and so was `z = "foo"` for
            // `z: { [index: number]: any }`.
            else => {
                if (c.ts.kind(s) != .string and c.ts.literalBase(s) != types.string_type) return false;
                if (!try c.isAssignable(types.string_type, nidx)) return false;
            },
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
    // The same rule with the ENUM domains filled in. `types.Store.disjoint
    // Domain` gives an enum no bit — a member's domain follows its VALUE,
    // which the store cannot read — so the interning check leaves every
    // enum-bearing intersection live, and `string & Tag` survived where tsc
    // reduces it. tsc gets there for free: a whole enum IS the union of its
    // member types there, each carrying `StringLiteral`/`NumberLiteral`
    // alongside `EnumLiteral`, and the bare `TypeFlags.Enum` it keeps for the
    // member-less case sits in `NumberLike`. `enums.enumDisjointDomain` is
    // that classification, and it declines to answer for a MIXED enum, whose
    // distribution is neither empty nor one domain.
    //
    // `intersectionReductionStrict`'s enums leg is the shape: `string & Tag1`
    // and `string & Tag2` over two EMPTY const enums are both `never` in tsgo,
    // so assigning either to the other is fine — four false TS2322s without
    // this.
    {
        var mask: u32 = 0;
        var empty = false;
        for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            var d = types.Store.disjointDomain(&c.ts, rm);
            if (d == 0) d = try c.enumDisjointDomain(rm);
            if (d == 0) continue;
            if (mask != 0 and mask != d) empty = true;
            mask |= d;
        }
        if (empty) return true;
    }
    // tsc's disjoint-domain rule (`getIntersectionType`: *"a string-like type
    // and a type known to be non-string-like, a number-like type and a type
    // known to be non-number-like, …"*), one CONSTRAINT step further than the
    // store's syntactic `disjointDomainIntersectionIsEmpty`.
    //
    // A member that is still INSTANTIABLE has no domain of its own, but its
    // base constraint can have nothing BUT domains the concrete members
    // exclude. `T & object` under `<T extends string | number>` is the shape:
    // `object` is `NonPrimitive`, every constituent of `T`'s constraint is
    // string-like or number-like, and no value inhabits both. tsc gets there
    // by cross-producting the constraint — `(string | number) & object` is
    // `string & object | number & object` is `never` — which the store does
    // only over what it can SEE at intern time, and a bare `T` shows it
    // nothing (`intersectionWithUnionConstraint` f4).
    //
    // One domain only: two different CONCRETE domains never reach here (the
    // store already reduced that pair), so `fixed` carrying more than one bit
    // means a member resolved into something the store could not see, and the
    // conservative answer is to say nothing.
    {
        var fixed: u32 = 0;
        for (try c.memberList(t)) |m| fixed |= types.Store.disjointDomain(&c.ts, try c.resolveStructural(m));
        if (@popCount(fixed) == 1) {
            for (try c.memberList(t)) |m| {
                switch (c.ts.kind(m)) {
                    .type_param, .index_access, .conditional, .keyof_op => {},
                    else => continue,
                }
                const bc = try c.transitiveBaseConstraint(m);
                if (bc == m) continue;
                const rbc = try c.resolveStructural(bc);
                const parts: []const TypeId = if (c.ts.kind(rbc) == .union_type) try c.memberList(rbc) else &.{rbc};
                if (parts.len == 0) continue;
                var all_disjoint = true;
                for (parts) |p| {
                    const d = types.Store.disjointDomain(&c.ts, try c.resolveStructural(p));
                    if (d == 0 or d == fixed) {
                        all_disjoint = false;
                        break;
                    }
                }
                if (all_disjoint) return true;
            }
        }
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
            // A constituent that was a lazy alias `.ref` when the intersection
            // was interned is ONE member then and an intersection now, because
            // `makeIntersection` could only flatten what it could SEE. It is
            // still a member whose properties count, and reading it through
            // `propOfTypeEx` below intersects its own constituents' — so it
            // joins `mem` rather than being skipped, WITHOUT contributing
            // candidate names (the `kind != .object` guard below) and without
            // being second-guessed for deferred insides.
            //
            // Excalidraw is the measured case: `{ type: "arrow" } &
            // ExcalidrawLinearElement & ExcalidrawTextElement`, where both
            // aliases have INTERSECTION bodies (`_ExcalidrawElementBase &
            // Readonly<{ type: "text"; … }>`). The `"arrow"` / `"text"`
            // conflict that makes the whole thing uninhabited lived one level
            // below what this scan looked at, and five TS2345 followed in
            // `resize.test.tsx` — a `never` source that tsc drops from the
            // union it appears in.
            .intersection => try mem.append(c.scratch(), rm),
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
/// The unit (or unit-union) value a union constituent gives a candidate
/// discriminant property, or null when it gives none.
///
/// Looks THROUGH an intersection: tsc's `getPropertyOfType` on an
/// intersection intersects the constituents' property types, and
/// `getIntersectionType` then drops a base primitive that a literal of the
/// same primitive is intersected with (`removeRedundantPrimitiveTypes`), so
/// `{id: string} & {id: Nux.A}` has `id: Nux.A`. ztsc's store deliberately
/// leaves an ENUM member out of that reduction — its primitive domain follows
/// its value, which the store cannot read — so the pair stays live as
/// `string & Nux.A` and the discriminant scan rejected it as non-unit.
fn discriminantUnitOf(c: *Checker, t: TypeId) Error!?TypeId {
    const r = try c.resolveStructural(t);
    if (try c.isUnitOrUnitUnion(r)) return r;
    if (c.ts.kind(r) != .intersection) return null;
    var found: TypeId = types.no_type;
    for (try c.memberList(r)) |m| {
        const rm = try c.resolveStructural(m);
        if (!try c.isUnitOrUnitUnion(rm)) continue;
        // Two different unit constituents make the intersection uninhabited,
        // not a discriminant this scan can read.
        if (found != types.no_type and found != rm) return null;
        found = rm;
    }
    return if (found == types.no_type) null else found;
}

/// Collects one enum-MEMBER type per member of an enum symbol — the
/// constituents tsc's union model of an enum type has.
const EnumMemberTypes = struct {
    c: *Checker,
    sym: SymbolId,
    out: *std.ArrayList(TypeId),

    pub fn visit(self: *EnumMemberTypes, name: Atom, value: TypeId) Error!void {
        _ = value;
        try self.out.append(self.c.scratch(), try self.c.ts.makeEnumMember(self.sym, name, false));
    }
};

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
    // tsc runs this on `extractTypesOfKind(target, Object | Intersection |
    // Substitution)`, not on the whole union: a PRIMITIVE constituent has no
    // properties, so leaving it in makes every candidate discriminant fail the
    // "present on every member" test and the split never runs at all.
    // react-navigation's `to` prop is `LinkProps<ParamList> | string`, and
    // that lone `string` is what stopped
    // `to={{screen: cond ? 'CustomFeed' : 'ProfileList', params}}` — a source
    // whose `screen` is a two-literal union — from ever being split.
    var obj_members: std.ArrayList(TypeId) = .empty;
    defer obj_members.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        switch (c.ts.kind(try c.resolveStructural(m))) {
            .object, .intersection => try obj_members.append(c.scratch(), m),
            else => {},
        }
    }
    const members = obj_members.items;
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
        var any_unit = false;
        var ok = true;
        for (members) |m| {
            const mp = (try c.propOfType(m, dprop.name)) orelse {
                ok = false;
                break;
            };
            // Read the member's discriminant THROUGH an intersection (a target
            // constituent spells it as `string & Nux.X`, and only the unit
            // constituent is the tag), but a member that has no unit here does
            // not disqualify the candidate — `isDiscriminantProperty` wants one
            // non-uniform property with at least ONE literal constituent, not a
            // literal in every constituent.
            const mr = (try discriminantUnitOf(c, mp.ty)) orelse
                try c.resolveStructural(mp.ty);
            if (try c.isUnitOrUnitUnion(mr)) any_unit = true;
            if (first_val == 0) first_val = mr else if (mr != first_val) differs = true;
        }
        // tsc's `isDiscriminantProperty`: the union's synthesized property
        // must carry BOTH `CheckFlags.HasNonUniformType` (the constituents do
        // not all give it the same type) and `CheckFlags.HasLiteralType` (at
        // least ONE of them gives it a unit type) — not "every constituent is
        // a unit", which is what this loop used to demand. A union that splits
        // an optional key into "present as `T`" and "absent" is the common
        // shape that requirement excluded: react-navigation's
        // `NavigatorID extends string ? {id: NavigatorID} : {id?: undefined}`
        // instantiated at `string | undefined` is
        // `{id: string} | {id?: undefined}`, and an `id: string | undefined`
        // read back out of it fits neither constituent alone — only the
        // by-cases split, which is exactly what this function computes.
        if (!ok or !differs or !any_unit) continue;
        // Every source discriminant constituent must be covered by ≥1
        // member, and every matched member's non-discriminant props must
        // accept the source.
        const src_disc = try c.resolveStructural(dprop.ty);
        const singleton = [_]TypeId{src_disc};
        // tsc has no `boolean` type: `booleanType` IS the union
        // `true | false` (`getUnionType([regularFalseType, regularTrueType])`),
        // so a `boolean` discriminant reaches
        // `typeRelatedToDiscriminatedType`'s cross product already split in
        // two. ztsc keeps `boolean` as one kind, so the product had a single
        // element that matched neither `{ flag: true }` nor `{ flag: false }`
        // and the whole split never ran — `class B extends A<Model>` where
        // `A<T extends {flag: true} | {flag: false}>` and `Model` declares
        // `flag: boolean` was a phantom TS2344
        // (`compiler/relatedViaDiscriminatedTypeNoError`). Expanded here only,
        // exactly where the enum expansion below is, and for the same reason.
        const bool_consts = [_]TypeId{ types.true_type, types.false_type };
        var src_consts: []const TypeId = if (c.ts.kind(src_disc) == .union_type)
            try c.memberList(src_disc)
        else if (c.ts.kind(src_disc) == .boolean)
            &bool_consts
        else
            &singleton;
        // tsc models an enum TYPE as the UNION of its member literal types, so
        // `typeRelatedToDiscriminatedType`'s cross product
        // (`sourcePropertyType.flags & TypeFlags.Union ? types : [type]`)
        // splits a whole-enum discriminant across the target's per-member
        // constituents. ztsc models an enum as one nominal type, so the
        // cross product had a single element that matched no constituent:
        // bluesky's `saveNux({id, completed: true, data: undefined})` — `id:
        // Nux`, target a union of `… & {id: Nux.ActivitySubscriptions}` and
        // fifteen siblings — was TS2345. Expanded only here, where tsc's own
        // algorithm asks for the constituents.
        var enum_members: std.ArrayList(TypeId) = .empty;
        defer enum_members.deinit(c.scratch());
        if (c.ts.kind(src_disc) == .enum_type and !c.ts.isEnumMember(src_disc)) {
            const esym = c.ts.enumSymbol(src_disc);
            var collect: EnumMemberTypes = .{ .c = c, .sym = esym, .out = &enum_members };
            try c.eachEnumMember(esym, &collect, EnumMemberTypes.visit);
            if (enum_members.items.len > 1) src_consts = enum_members.items;
        }
        var all_ok = true;
        for (src_consts) |lv| {
            var covered = false;
            for (members) |m| {
                const mp = (try c.propOfType(m, dprop.name)) orelse continue;
                // Prefer the unit read out of an intersection (`string & Nux.X`
                // covers `Nux.X`, not every string), but a member whose
                // discriminant is a plain non-unit still covers what it
                // accepts — `{id: string} | {id?: undefined}` splits an
                // `id: string | undefined` only because the `string` member
                // covers the `string` case.
                var mv = (try discriminantUnitOf(c, mp.ty)) orelse mp.ty;
                // An OPTIONAL member property accepts `undefined` on top of
                // its declared type: tsc's `typeRelatedToDiscriminatedType`
                // does not compare against the raw property type but calls
                // `propertyRelatedTo`, whose target side is
                // `addOptionality(getNonMissingTypeOfSymbol(targetProp),
                // /*isProperty*/ false, targetIsOptional)`. Without it the
                // `undefined` constituent that an all-optional source's own
                // discriminant carries is covered by no member and the split
                // never runs — `Partial<Omit<Partial<Ordered<Element>>, …>>`
                // → `Partial<Ordered<ExcalidrawElement>>` (excalidraw's
                // `Delta.create(deleted, inserted, stripIrrelevantProps)`),
                // where the source is the single `Omit`-of-the-union object
                // whose `type` is the whole tag union and the target is the
                // union that splits that tag across thirteen members.
                if (mp.optional()) mv = try c.makeUnion2(mv, types.undefined_type);
                if (!try c.isAssignable(lv, mv)) continue;
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

/// `discriminatedUnionAssignable` for a TUPLE source against a union of
/// tuples — tsc's `typeRelatedToDiscriminatedType` with the element positions
/// standing in for the properties `"0"`, `"1"`, … that a tuple's members
/// actually are.
///
/// One position is split (the first eligible), which is the same
/// single-discriminant simplification the object form makes: a position whose
/// SOURCE type is a union, whose member types are not all the same, and at
/// least one of which is a unit (tsc's `isDiscriminantProperty`,
/// `HasNonUniformType | HasLiteralType`). Each case is then re-related to the
/// whole union, which is sound in the direction that matters: a value of
/// `[A | B, X]` is a value of `[A, X]` or of `[B, X]`, so if both reach the
/// union so does every value of the original.
pub fn discriminatedTupleAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    const sr = try c.resolveStructural(s);
    if (c.ts.kind(sr) != .tuple) return false;
    const members = try c.memberList(t);
    if (members.len < 2) return false;
    const s_len = c.ts.tupleLen(sr);
    for (0..s_len) |pos| {
        const i: u32 = @intCast(pos);
        const se = c.ts.tupleElem(sr, i);
        if (se.rest()) continue;
        const src_el = try c.resolveStructural(se.ty);
        if (c.ts.kind(src_el) != .union_type) continue;
        // The target side has to look like a discriminant at this position.
        var first_val: TypeId = 0;
        var differs = false;
        var any_unit = false;
        var ok = true;
        for (members) |m| {
            const mr = try c.resolveStructural(m);
            if (c.ts.kind(mr) != .tuple or c.ts.tupleLen(mr) <= i) {
                ok = false;
                break;
            }
            const me = c.ts.tupleElem(mr, i);
            if (me.rest()) {
                ok = false;
                break;
            }
            const mt = try c.resolveStructural(me.ty);
            if (try c.isUnitOrUnitUnion(mt)) any_unit = true;
            if (first_val == 0) first_val = mt else if (mt != first_val) differs = true;
        }
        if (!ok or !differs or !any_unit) continue;
        // Split: every case of the source's element must reach the union.
        var elems: std.ArrayList(types.TupleElem) = .empty;
        defer elems.deinit(c.scratch());
        var all_ok = true;
        for (try c.memberList(src_el)) |lv| {
            elems.clearRetainingCapacity();
            for (0..s_len) |j| {
                const e = c.ts.tupleElem(sr, @intCast(j));
                try elems.append(c.scratch(), if (j == pos) .{ .ty = lv, .flags = e.flags } else e);
            }
            const one = try c.ts.makeTupleLike(sr, elems.items);
            if (one == sr or !try c.isAssignable(one, t)) {
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
    if (c.ts.kind(t) != .union_type) return isUnitType(c, t);
    for (0..c.ts.memberCount(t)) |i| {
        const m = try c.resolveStructural(c.ts.memberAt(t, i));
        if (!isUnitType(c, m)) return false;
    }
    return true;
}

/// tsc's `isUnitType` — a type denoting a single value. An enum MEMBER is one
/// (tsc's "enum literal"); a whole enum is not, so the test needs the type and
/// not just its kind. Enum-tagged discriminated unions are ordinary in
/// application code — excalidraw's `SocketUpdateDataSource` is keyed by
/// `WS_SUBTYPES` members — and without the member arm
/// `discriminatedUnionAssignable` declined every one of them.
pub fn isUnitType(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) == .enum_type) return c.ts.isEnumMember(t);
    return isUnitLikeKind(c.ts.kind(t));
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
///
/// The under-report is load-bearing for ~24 of outline's keys — `typeof
/// Collection` satisfies `new (...args: never[]) => Model` here even though
/// `Collection` is not assignable to `Model` — and MATERIALIZING the class
/// value instead (`classConstructType`, as the `.class_value` target arm of
/// `isAssignableInner` does) fixes exactly those 24. It also makes the pair's
/// answer depend on WHEN it is first asked: in one program `typeof Notice`
/// against `{ new (...args: any[]): Extension<any> | Mark<any> | Node<any> }`
/// answers YES from one file and NO from another (outline
/// `shared/editor/nodes/index.ts` vs a probe file added to the same run) —
/// i.e. something under `classConstructType` / `classStaticType` is being
/// memoized from a provisional class table. Left as-is until that is found;
/// the fix is not safe without it.
pub fn sourceSatisfiesSigs(c: *Checker, s: TypeId, t: TypeId, is_construct: bool) Error!bool {
    const sk = c.ts.kind(s);
    if (sk == .any or sk == .err) return true;
    // tsc's `signaturesRelatedTo`, construct half, ahead of every signature
    // comparison:
    //
    //     const sourceIsAbstract = !!(sourceSignatures[0].flags & SignatureFlags.Abstract);
    //     const targetIsAbstract = !!(targetSignatures[0].flags & SignatureFlags.Abstract);
    //     if (sourceIsAbstract && !targetIsAbstract) {
    //         …Cannot_assign_an_abstract_constructor_type_to_a_non_abstract_constructor_type…
    //         return Ternary.False;
    //     }
    //
    // An abstract class's constructor cannot be CALLED, so letting `typeof A`
    // through a `new () => A` target would hand the caller a `new` on a class
    // with unimplemented members. The reverse direction stays legal — a
    // concrete constructor satisfies an abstract-constructor target — which is
    // why the test is one-sided.
    //
    // The source side is recognized by its `.class_value` kind (ztsc carries
    // the `abstract` bit on the class DECLARATION there). WAVE36-A: the TARGET
    // side now reads `types.fn_flag_abstract` off the signature itself, which
    // `typenode` sets for `abstract new (…) => R` — so the screen is tsc's
    // exact test instead of the old "the target cannot have been written
    // either way" proxy, which stood down for a target spelled `new () => A`
    // on its own (`classAbstractAssignabilityConstructorFunction`).
    if (is_construct and sk == .class_value and
        c.ts.objectConstructSigCount(t) > 0 and
        !c.ts.fnIsAbstract(c.ts.objectConstructSig(t, 0)) and
        try c.classIsAbstract(c.ts.classSymbol(s))) return false;
    var src: std.ArrayList(TypeId) = .empty;
    defer src.deinit(c.scratch());
    switch (sk) {
        .function => if (!is_construct) try src.append(c.scratch(), s),
        .overloads => if (!is_construct) {
            for (try c.memberList(s)) |m| try src.append(c.scratch(), m);
        },
        .class_value => if (is_construct) {
            const mat = try c.classConstructType(c.ts.classSymbol(s));
            for (0..c.ts.objectConstructSigCount(mat)) |i| {
                try src.append(c.scratch(), c.ts.objectConstructSig(mat, @intCast(i)));
            }
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
    // tsc's `signaturesRelatedTo` splits here: ONE signature on each side is
    // compared un-erased (the source's type params are instantiated in the
    // target's context — `genericSourceRelatesByInference` here); anything
    // else is the cross-matching `else` arm, which erases both sides to `any`
    // (`getErasedSignature`). Erasing an overload set to its CONSTRAINTS
    // instead is where a kysely builder's demand comes from: the constraints
    // are `ReferenceExpression<DB, TB>`-shaped unions over every column of
    // every table, so one comparison substitutes the whole schema.
    const erase: Erase = if (src.items.len == 1 and t_cnt == 1) .constraints else .any;
    for (0..t_cnt) |i| {
        const tsig = if (is_construct) c.ts.objectConstructSig(t, @intCast(i)) else c.ts.objectCallSig(t, @intCast(i));
        var matched = false;
        for (src.items) |ssig| {
            if (try c.signatureAssignableModeErase(ssig, tsig, .none, erase)) {
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

/// Relate a generic *source* signature to a target by inferring the source's
/// own type params from the target signature and relating the instantiation.
/// `null` — no verdict — when there is no instantiation to relate: a
/// non-generic source, a non-function on either side, a pair that shares its
/// type parameters, or an inferred argument that violates its constraint. The
/// caller then falls through to the erase-to-constraint path.
///
/// Mirrors tsc's `compareSignaturesRelated`, which instantiates rather than
/// erases a generic source:
///
/// ```ts
/// if (source.typeParameters && source.typeParameters !== target.typeParameters) {
///     target = getCanonicalSignature(target);
///     source = instantiateSignatureInContextOf(source, target, /*inferenceContext*/ undefined, compareTypes);
/// }
/// ```
///
/// The TARGET is never erased there — its own type parameters stay FREE, and
/// the instantiated source references whichever of them the inference bound.
/// That is why the comparison runs in `.free` mode: erasing both sides to
/// their constraints instead collapses `(x: T_target) => …` against
/// `(x: T_outer) => …` into `any` versus `any` and accepts every such pair
/// (`subtypingWithConstructSignatures6`'s `I4`/`I5`/`I7`, where the derived
/// member's `<U>` is bound to the base member's own `U` and the two
/// interfaces' `T`s are then unrelated).
pub fn genericSourceRelatesByInference(c: *Checker, s: TypeId, t: TypeId) Error!?bool {
    // tsc's `source.typeParameters !== target.typeParameters` half of the guard:
    // two instantiations of the SAME generic declaration are compared as they
    // are (and, in ztsc, erased to `any` below — see `sameSigTypeParams`).
    // Inferring one side's parameters from the other's would only rediscover
    // the identity, and it is not free: this is the kysely/drizzle builder
    // shape, whose constraints span every column of every table.
    if (sameSigTypeParams(c, s, t)) return null;
    const inst = (try c.instantiateSigInContextOf(s, t)) orelse return null;
    return try c.signatureAssignableModeInnerErase(inst, t, .none, .free);
}

/// tsc's `instantiateSignatureInContextOf`: infer `s`'s OWN type parameters
/// from `t`'s parameters and return type and hand back the instantiation.
/// `null` when `s` is not a generic function signature — there is then no
/// instantiation to relate. `t`'s own type parameters, if any, stay free and
/// are legitimate inference results: that is how `<TE>(from: TE) => X<TE>`
/// relates to `<TE2>(from: TE2) => X<TE2>` without either side being collapsed.
pub fn instantiateSigInContextOf(c: *Checker, s: TypeId, t: TypeId) Error!?TypeId {
    if (c.ts.kind(s) != .function or c.ts.kind(t) != .function) return null;
    const tps = c.ts.fnTypeParams(s);
    if (tps.len == 0) return null; // source not generic
    const tp_syms = try c.scratch().dupe(u32, tps);
    // tsc instantiates a generic method's own type parameters with a fresh
    // CLONE whenever the type that declares it is instantiated
    // (`createCanonicalSignature`: "when a generic class or interface is
    // instantiated, each generic method in the class or interface is
    // instantiated with a fresh set of cloned type parameters"), so a
    // signature's own parameter can never also occur free in the pair being
    // related. ztsc keys a type parameter by its DECLARATION symbol and does
    // not clone, so `new Cons<U>()` written inside `Cons.map<U>` hands back a
    // member whose own `U` IS the enclosing method's: the inference variable
    // and the concrete type it must not capture are one symbol. Inferring
    // through that capture solved `U := D` against `Nil<U>.map<D>` and then
    // rejected a pair tsc accepts (`typeInferenceReturnTypeCallback`).
    //
    // Detected by substituting the source's own parameters in the TARGET — a
    // target that CHANGES mentions one of them, so the capture is real and
    // there is no trustworthy instantiation to relate. (`instantiate` is the
    // occurs-check ztsc already has; a truncated substitution also answers
    // "changed", which lands on the same safe side.)
    {
        const probe = try c.scratch().alloc(TpMap, tp_syms.len);
        for (tp_syms, 0..) |tp, k| probe[k] = .{ .sym = tp, .ty = types.unknown_type };
        if ((try c.instantiate(t, probe)) != t) return null;
    }
    const cand = try c.scratch().alloc(TypeId, tp_syms.len);
    for (cand) |*x| x.* = types.no_type;
    // Everything below infers for a SIGNATURE RELATION, not for a call — the
    // one place where a generic argument signature's own parameter bound to a
    // variable of this inference is the answer rather than noise. See
    // `InferCtx.sig_ctx`.
    c.infer_ctx.sig_ctx += 1;
    defer c.infer_ctx.sig_ctx -= 1;
    try applyToParameterTypes(c, s, t, tp_syms, cand);
    // The return position infers at tsc's `InferencePriority.ReturnType`, and a
    // priority is a *filter*, not a weight: `inferFromTypes` DISCARDS every
    // candidate of a worse priority than the best one seen
    //
    //     if (inference.priority === undefined || priority < inference.priority) {
    //         inference.candidates = undefined;          // ← the return's are dropped
    //         inference.priority = priority;
    //     }
    //     if (priority === inference.priority) inference.candidates.push(candidate);
    //
    // so a type parameter a PARAMETER position already bound keeps that binding
    // alone. Unioning the two positions' candidates instead — which is what a
    // single `unify` accumulator does — makes a signature reject ITSELF:
    // `<V>(v: V) => V extends {a: 1} ? V : V & {a: 1}` against
    // `<V>(v: V) => V & {a: 1}` bound the source's `V` to `V_t | V_t & {a: 1}`
    // (the parameter's `V_t` unioned with the candidate the return's two
    // branches contribute), and the instantiated source then had a WIDER
    // parameter and a distributed return that no longer related. 51 such
    // false positives on the social-app, all of atproto's
    // `dangerousIsType(record, isRecord)`, whose `<V>(v: V) => v is
    // $TypedObject<V, …>` predicate is exactly this shape.
    const ret_cand = try c.scratch().alloc(TypeId, tp_syms.len);
    for (ret_cand) |*x| x.* = types.no_type;
    try c.unify(c.ts.fnReturn(s), c.ts.fnReturn(t), tp_syms, ret_cand, 0);
    // Which position each candidate came from — `applyToParameterTypes` runs
    // contravariantly and `applyToReturnTypes` covariantly, and the constraint
    // clamp below reads that (see `infer.clampSigInference`).
    const pos = try c.scratch().alloc(infer_zig.SigInferPos, tp_syms.len);
    for (cand, ret_cand, pos) |*x, r, *p| {
        p.* = if (x.* != types.no_type) .parameter else .ret;
        if (x.* == types.no_type) x.* = r;
    }
    // Build the substitution. tsc's `getInferredType` closes with
    //
    //     const constraint = getConstraintOfTypeParameter(inference.typeParameter);
    //     if (constraint) {
    //         const instantiatedConstraint = instantiateType(constraint, context.nonFixingMapper);
    //         if (!inferredType || context.compareTypes(inferredType, …) === Ternary.False) {
    //             inference.inferredType = inferredType = instantiatedConstraint;
    //         }
    //     }
    //
    // so a parameter with NO candidate comes out as its CONSTRAINT.
    // `callSignatureAssignabilityInInheritance3`'s `I3` rests on exactly that
    // ("no inferences for `V` so it defaults to `Derived2`", its declared
    // constraint). What ztsc does differently for a candidate that FAILS its
    // constraint is measured, not deduced — see the loop below.
    const map = try c.scratch().alloc(TpMap, tp_syms.len);
    for (tp_syms, 0..) |tp, k| {
        const con = try c.typeParamConstraint(tp);
        map[k] = .{
            .sym = tp,
            .ty = if (cand[k] != types.no_type)
                cand[k]
            else if (con != types.no_type)
                con
            else
                types.unknown_type,
        };
    }
    // `nonFixingMapper` is the whole context's mapper, so a constraint standing
    // in for an unbound parameter is read with every OTHER parameter already
    // substituted. `Ret extends (TOpt['returnObjects'] extends true ? object :
    // string)` needs it twice over: `TOpt` has to become `Opts` before the
    // indexed access resolves, and only then does the conditional reduce to
    // `string`. Driven to a fixed point for the same reason `eraseParamsOf` is
    // (`test/conformance/assignability/043_generic_sig_nested_constraint_erase`,
    // react-i18next's `TFunction` against `(key: string) => string`).
    var iter: usize = 0;
    while (iter + 1 < map.len) : (iter += 1) {
        var changed = false;
        for (map) |*m| {
            const ni = try c.instantiate(m.ty, map);
            if (ni != m.ty) {
                changed = true;
                m.ty = ni;
            }
        }
        if (!changed) break;
    }
    // Now the constraint clamp, against the RESOLVED constraint —
    // `infer.clampSigInference`, which carries the tsgo battery that fixes what
    // an offending candidate is replaced with. A clamped entry no longer
    // mentions any of `tp_syms` (the fixed point above already substituted them
    // out of both the candidate and the constraint), so no second fixed-point
    // pass is needed. `assignmentStricterConstraints` is the witness: `S extends
    // T` infers the target's `S2`, which the clamp replaces with the target's
    // `T2`, and the instantiated `(x: T2, y: T2) => void` then rejects the
    // target's `y: S2` exactly as tsc does.
    const t_tps = c.ts.fnTypeParams(t);
    const bound = try c.scratch().alloc(u32, tp_syms.len + t_tps.len);
    @memcpy(bound[0..tp_syms.len], tp_syms);
    @memcpy(bound[tp_syms.len..], t_tps);
    for (tp_syms, 0..) |tp, k| {
        if (cand[k] == types.no_type) continue; // already the constraint
        const con = try c.typeParamConstraint(tp);
        if (con == types.no_type) continue;
        map[k].ty = try infer_zig.clampSigInference(c, map[k].ty, try c.instantiate(con, map), pos[k], bound) orelse return null;
    }
    const inst = try c.instantiate(s, map);
    // A full map over the source's own params yields a non-generic sig; if
    // anything remains generic, bail rather than risk recursion.
    if (c.ts.kind(inst) != .function or c.ts.fnTypeParams(inst).len != 0) return null;
    return inst;
}

/// tsc's `applyToParameterTypes`, which pairs the CONTEXTUAL signature's
/// parameter positions with the signature being instantiated:
///
/// ```ts
/// const sourceRestType = getEffectiveRestType(source);   // the contextual sig
/// const targetRestType = getEffectiveRestType(target);   // the sig being instantiated
/// const targetNonRestCount = targetRestType ? targetCount - 1 : targetCount;
/// const paramCount = sourceRestType ? targetNonRestCount : Math.min(sourceCount, targetNonRestCount);
/// if (sourceThisType) { const targetThisType = getThisTypeOfSignature(target); if (targetThisType) callback(sourceThisType, targetThisType); }
/// for (let i = 0; i < paramCount; i++) callback(getTypeAtPosition(source, i), getTypeAtPosition(target, i));
/// if (targetRestType) callback(getRestTypeAtPosition(source, paramCount), targetRestType);
/// ```
///
/// Positions, not stored parameters: a contextual `(...s: string[])` supplies
/// `string` to EVERY position the instantiated signature has, and its rest
/// count does not cap the pairing. Walking the two stored lists instead unified
/// the source's first type parameter against the whole `string[]`, so
/// `var sig: typeof contextual = toInstantiate` — `<A, B>(a?: A, b?: B) => B`
/// against `(...s: string[]) => string` — solved `A := string[]` and rejected a
/// pair tsc accepts (`contextualSigInstantiationRestParams`).
///
/// The `this` pairing is tsc's too, and it is what makes a `this`-parameter
/// overload like `CallableFunction.call<T, A extends any[], R>(this: (this: T,
/// ...args: A) => R, …)` infer anything at all.
fn applyToParameterTypes(c: *Checker, s: TypeId, t: TypeId, tp_syms: []const u32, cand: []TypeId) Error!void {
    const s_rest = try effectiveRestType(c, s);
    const t_rest = try effectiveRestType(c, t);
    const s_count = try c.effParamCount(s);
    const s_non_rest = if (s_rest != null) s_count - 1 else s_count;
    const pair_count = if (t_rest != null) s_non_rest else @min(try c.effParamCount(t), s_non_rest);

    const s_this = c.ts.fnThisType(s);
    const t_this = c.ts.fnThisType(t);
    if (t_this != 0 and s_this != 0) try c.unify(s_this, t_this, tp_syms, cand, 0);

    var i: u32 = 0;
    while (i < pair_count) : (i += 1) {
        const sp = (try c.paramTypeAt(s, i)) orelse break;
        const tp = (try c.paramTypeAt(t, i)) orelse break;
        try c.unify(sp, tp, tp_syms, cand, 0);
        try pairTemplateHoles(c, sp, tp, tp_syms, cand);
    }
    if (s_rest) |sr| try c.unify(sr, try c.restTupleAtPosition(t, pair_count), tp_syms, cand, 0);
}

/// tsc's `inferTypesFromTemplateLiteralType` short-circuit, for the one
/// position `instantiateSigInContextOf` needs it:
///
/// ```ts
/// arraysEqual(source.texts, target.texts) ? map(source.types, getStringLikeTypeForType) : …
/// ```
///
/// Two patterns whose fixed text is identical have their placeholders paired
/// one-to-one, and each pair is inferred straight through — no text scan, no
/// template wrapper around the match. So `` `${T2}` `` against `` `${T0}` ``
/// binds `T0 := T2` (oracle-verified: `inf(x: `${T0}`): [T0]` called with a
/// `` `${T2}` `` argument answers `[T2]`, not ``[`${T2}`]``).
///
/// `unify` itself binds NOTHING from a template-literal pattern, and here that
/// silence is not merely a missed inference — it hands the decision to the
/// RETURN position, which is a strictly worse answer. tsc's return-position
/// inferences run at `InferencePriority.ReturnType` and are DISCARDED wherever
/// a parameter already bound the variable; ztsc's `instantiateSigInContextOf`
/// applies the same precedence, so an empty parameter candidate let
/// `TypeMap[T0]` against ``TypeMap[`${T2}`]`` bind `` T0 := `${T2}` `` from the
/// return, making the instantiated return IDENTICAL to the target's and
/// accepting a pair tsc rejects (`templateLiteralTypes5`, where `T2` is not
/// assignable to `` `${T2}` ``).
///
/// Parameters only. The general arm belongs in `infer.unify`, where it would
/// serve calls and return positions too; this is the signature relation's own
/// half, added where the precedence rule makes it decisive.
fn pairTemplateHoles(c: *Checker, sp: TypeId, tp: TypeId, tp_syms: []const u32, cand: []TypeId) Error!void {
    if (c.ts.kind(sp) != .template_literal_type or c.ts.kind(tp) != .template_literal_type) return;
    if (!template_zig.sameTemplateTexts(c, sp, tp)) return;
    for (0..c.ts.templateHoleCount(sp)) |h| {
        const hs = c.ts.templateHole(sp, @intCast(h));
        const ht = c.ts.templateHole(tp, @intCast(h));
        // `map(source.types, getStringLikeTypeForType)`: a placeholder that is
        // NOT already string-like is wrapped in its own `` `${t}` `` before it
        // becomes the match, so `` `${number}` `` binds `` `${number}` `` and
        // not `number`. Those holes are left to the rest of the inference
        // rather than paired wrongly.
        if (!template_zig.templateHolePairsDirectly(c, ht)) continue;
        try c.unify(hs, ht, tp_syms, cand, 0);
    }
}

/// tsc's `getEffectiveRestType`: what a signature's rest parameter types the
/// positions from its own index onward, collectively. `null` when there is no
/// rest parameter, or when its type is a fully FIXED tuple — such a rest has a
/// positional expansion, so every position is an ordinary parameter.
///
/// ```ts
/// if (signatureHasRestParameter(signature)) {
///     const restType = getTypeOfSymbol(signature.parameters[signature.parameters.length - 1]);
///     if (!isTupleType(restType)) return isTypeAny(restType) ? anyArrayType : restType;
///     if (restType.target.hasRestElement) return sliceTupleType(restType, restType.target.fixedLength);
/// }
/// return undefined;
/// ```
fn effectiveRestType(c: *Checker, sig: TypeId) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    const p = c.ts.fnParam(sig, count - 1);
    if (!p.rest()) return null;
    const r = try c.resolveStructural(p.ty);
    if (c.ts.kind(r) != .tuple) {
        return if (c.ts.kind(r) == .any) try c.ts.makeArray(types.any_type) else p.ty;
    }
    const fixed = tuple_zig.fixedLength(c, r);
    if (fixed >= c.ts.tupleLen(r)) return null;
    return try sliceTuple(c, r, fixed, 0);
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

/// tsc's `signatureRelatedTo(…, erase = true)` — the two positions where the
/// relation erases a generic signature's type parameters to `any` instead of
/// comparing them: an overload SET on either side (`signaturesRelatedTo`'s
/// `else` arm, which cross-matches), and two instantiations of the SAME
/// generic type compared pairwise. The 1-vs-1 case is the one tsc leaves
/// un-erased, and it is the one `genericSourceRelatesByInference` covers.
pub fn signatureAssignableErased(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    return c.signatureAssignableModeErase(s, t, .none, .any);
}

pub fn signatureAssignableMode(c: *Checker, s: TypeId, t: TypeId, mode: SigMode) Error!bool {
    return c.signatureAssignableModeErase(s, t, mode, .constraints);
}

/// How a generic signature's own type parameters are collapsed before the
/// pair is compared — see `signatureAssignableErased`.
pub const Erase = enum {
    /// tsc's `getBaseSignature`: each own type parameter → its constraint.
    /// ztsc's stand-in for the 1-vs-1 case tsc handles by instantiating the
    /// source in the target's context.
    constraints,
    /// tsc's `getErasedSignature`: each own type parameter → `any`.
    any,
    /// Neither side is collapsed. tsc's *actual* 1-vs-1 comparison, reached
    /// once the source has been instantiated in the target's context: the
    /// target's own type parameters stay free, so only a source that works for
    /// every instantiation of them relates. See
    /// `genericSourceRelatesByInference`, its only caller.
    free,
};

pub fn signatureAssignableModeErase(c: *Checker, s: TypeId, t: TypeId, mode: SigMode, erase: Erase) Error!bool {
    if (try c.signatureAssignableModeInnerErase(s, t, mode, erase)) return true;
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
    if (erase == .any) return false; // the main path already erased to `any`
    if (c.ts.fnTypeParams(s).len == 0 and c.ts.fnTypeParams(t).len == 0) return false;
    if (try c.identityProbeRelated(s, t)) |_| return false;
    if (!try c.typeHasMapped(s, 0) and !try c.typeHasMapped(t, 0)) return false;
    const sa = try c.eraseParamsToAny(s);
    const ta = try c.eraseParamsToAny(t);
    if (sa == s and ta == t) return false;
    // …and never when the pair was already decided by INSTANTIATING the source
    // in the target's context. tsc's `compareSignaturesRelated` replaces the
    // source with that instantiation and has no fallback afterwards — "where
    // an instantiation EXISTS its verdict is final", the same rule the inner
    // function states for its own erasure fallthrough. Reaching here means
    // that verdict was NO (a YES returned two frames up), so an `any` erasure
    // that says yes is overturning a decision tsc never revisits.
    //
    // `<T>(target: { [K in keyof T]: T[K] }) => void` against
    // `<U extends string[]>(source: { [K in keyof U]: Obj[K] }) => void` is
    // exactly that: the inference binds `T := U`, the instantiated parameter
    // `{ [K in keyof U]: U[K] }` correctly refuses `Obj[K]` ("`U` could be
    // instantiated with an arbitrary type"), and erasing both `U`s to `any`
    // then accepted the pair anyway (`mappedTypeInferenceFromApparentType`).
    //
    // The `Comp<Full>["setState"]` pair the retry exists for is untouched: its
    // two `setState<K extends keyof S>` share ONE declaration symbol, so
    // `sameSigTypeParams` holds, the inference route declines (null), and the
    // retry still runs.
    if ((try c.genericSourceRelatesByInference(s, t)) != null) return false;
    return c.signatureAssignableModeInner(sa, ta, mode);
}

/// Does a deferred mapped type occur within `t0`, shallowly? Depth-bounded:
/// only used to gate the `any`-erasure retry above, where the mapped type
/// sits directly in a parameter's union.
pub fn typeHasMapped(c: *Checker, t0: TypeId, depth: u8) Error!bool {
    if (depth > 4) return false;
    // An interface/class instance is an object for every argument list, and
    // this walk stops at an object (it looks for a mapped type sitting
    // directly in a parameter's union) — so the member table need not be
    // materialized to say no. See `refExpandsToObject`.
    if (c.refExpandsToObject(t0)) return false;
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
    return c.eraseParamsToAnyOf(sig, sig);
}

/// tsc's `getErasedSignature`: every type parameter OWNED BY `owner` mapped
/// to `any`. The `owner`-relative form exists for the same reason
/// `eraseParamsOf` has one — an arrow contextually typed by a generic target
/// carries the TARGET's type-param symbols free, and both sides must collapse
/// them the same way.
///
/// Memoized (`erase_any_cache`), which is what tsc's per-signature
/// `erasedSignatureCache` does; the signature relation asks for it on both
/// sides of every generic comparison.
pub fn eraseParamsToAnyOf(c: *Checker, sig: TypeId, owner: TypeId) Error!TypeId {
    const sig_tps = c.ts.fnTypeParams(owner);
    if (sig_tps.len == 0) return sig;
    const memo_key = (@as(u64, owner) << 32) | sig;
    if (c.inst_cache_on) {
        if (c.erase_any_cache.get(memo_key)) |r| return r;
    }
    const tps = try c.scratch().dupe(u32, sig_tps);
    defer c.scratch().free(tps);
    const map = try c.scratch().alloc(TpMap, tps.len);
    defer c.scratch().free(map);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = types.any_type };
    // Scope the truncation flag exactly as `eraseParamsOf` does: the memo
    // must ask "was MY result truncated", not "did anything earlier trip".
    const outer_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or outer_trip;
    const result = try c.instantiate(sig, map);
    if (c.inst_cache_on and !c.inst_limit_tripped) try c.erase_any_cache.put(c.cm(), memo_key, result);
    return result;
}

/// Whether two signatures carry the SAME type parameters — which, because
/// ztsc keys a type parameter by its declaration symbol, means they are two
/// instantiations of one generic declaration (tsc's `source.symbol ===
/// target.symbol` on an `Instantiated` pair).
fn sameSigTypeParams(c: *Checker, s: TypeId, t: TypeId) bool {
    const n = c.ts.fnTypeParamCount(s);
    if (n == 0 or n != c.ts.fnTypeParamCount(t)) return false;
    for (0..n) |i| {
        const x = c.ts.fnTypeParamAt(s, i);
        const y = c.ts.fnTypeParamAt(t, i);
        if (x != y and c.tpOrigin(x) != c.tpOrigin(y)) return false;
    }
    return true;
}

pub fn signatureAssignableModeInner(c: *Checker, s: TypeId, t: TypeId, mode: SigMode) Error!bool {
    return c.signatureAssignableModeInnerErase(s, t, mode, .constraints);
}

/// tsc's `getNonArrayRestType`: the type of `sig`'s rest parameter when it is
/// neither an array nor `any` — i.e. a TUPLE (or something still generic),
/// which the relation unrolls rather than relates. Null for every other
/// signature.
fn nonArrayRestType(c: *Checker, sig: TypeId) ?TypeId {
    const n = c.ts.fnParamCount(sig);
    if (n == 0) return null;
    const last = c.ts.fnParam(sig, @intCast(n - 1));
    if (!last.rest()) return null;
    return switch (c.ts.kind(last.ty)) {
        .array, .any, .err => null,
        else => last.ty,
    };
}

pub fn signatureAssignableModeInnerErase(c: *Checker, s: TypeId, t: TypeId, mode: SigMode, erase_in0: Erase) Error!bool {
    // The relation's second difference, and tsc says so in a comment of its
    // own at the one place that decides it (`signaturesRelatedTo`):
    //
    // ```ts
    // // For simple functions (functions with a single signature) we only erase type parameters for
    // // the comparable relation. Otherwise, if the source signature is generic, we instantiate it
    // // in the context of the target signature before checking the relationship.
    // const eraseGenerics = relation === comparableRelation || !!compilerOptions.noStrictGenericChecks;
    // ```
    //
    // So `{ fn<T>(t: T): T }` and `{ fn<T>(t: T[]): T }` are COMPARABLE — both
    // erase to `fn(t: any)`-shaped signatures, and `any` overlaps everything —
    // while neither is ASSIGNABLE to the other, which tsgo confirms in both
    // directions. Instantiating the source in the target's context instead
    // (the assignable rule, made authoritative in 82f2209) answered the
    // comparable question with the strict verdict, and every
    // `a7 < b7` / `a7 == b7` in the family became a false TS2365/TS2367.
    //
    // Forcing the erasure here rather than at the caller keeps it out of the
    // hot path: the assignable relation reads one already-loaded byte and is
    // otherwise untouched.
    const erase_in: Erase = if (c.rel_kind == .comparable) .any else erase_in0;
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
    // A generic *source* signature relates by instantiating its own type
    // params — inferred from the target's parameters/return — instead of
    // erasing them to their (possibly far wider) constraints.
    // `<T extends AllGeoJSON>(f: T) => T` relates to `(v: Feature) => Feature`
    // by inferring T = Feature; the erase-to-constraint path below instead
    // over-widens the covariant return (`=> AllGeoJSON` ⊄ `=> Feature`) and
    // wrongly rejects.
    //
    // Where an instantiation EXISTS its verdict is final, exactly as tsc's
    // `compareSignaturesRelated` has no fallback once it has replaced the
    // source. Falling through to the erasure on a negative answer is what let
    // `interface I4<T> extends A { a4: new <U>(x: T, y: U) => string }` past
    // `a4: new <T, U>(x: T, y: U) => string`: erasing the TARGET's
    // unconstrained `T` to `any` made it assignable to `I4`'s own `T`, so the
    // whole `subtypingWith{Call,Construct}Signatures` "class type parameter
    // instead of a generic signature" family stayed silent.
    //
    // Only in the un-erased (`.constraints`) position. tsc's `erase = true`
    // callers run `getErasedSignature` on BOTH sides *before*
    // `compareSignaturesRelated`, so a source reaching those has no type
    // parameters left to instantiate and the question never arises; ztsc
    // erases inside this function instead, so the inference stays purely
    // additive there.
    if (try c.genericSourceRelatesByInference(s, t)) |ok| {
        if (ok or erase_in == .constraints) return ok;
    }
    // tsc decides bivariance from the TARGET's declaration kind ALONE:
    // `compareSignaturesRelated` reads `strictVariance` off
    // `target.declaration.kind` (`MethodDeclaration` / `MethodSignature` /
    // `Constructor`) and never looks at the source's. Taking either side's
    // flag let a class METHOD launder itself past `strictFunctionTypes` into
    // a function-typed PROPERTY, so a method source related its parameters
    // bivariantly no matter what it was assigned to — oracle-verified in
    // `test/conformance/assignability/method_source_property_target_strict_
    // variance.ts`, four lines of which used to be registered as
    // under-reports in `test/conformance/DEFERRED`.
    //
    // Both blockers the DEFERRED block named are closed: excalidraw's
    // `Delta.create` pair by `discriminatedUnionAssignable` (a member's
    // discriminant carries the optionality tsc's `propertyRelatedTo` adds),
    // and the rest-parameter packing gap by `anyRestFrom` below — source-side
    // bivariance was the only thing hiding
    // `(event: string, ...args: [number] | [string]) => void` against
    // `(...args: any[]) => any`, which is immich's `EventRepository.emit`
    // through vitest's `Mocked<T>`.
    const bivariant = c.ts.fnFlags(t) & types.fn_flag_method != 0;
    // Erase generics: to `any` in tsc's `erase = true` positions, to their
    // constraints otherwise (the documented simplification of the 1-vs-1 case
    // tsc handles by instantiating the source in the target's context).
    var erase: Erase = erase_in;
    // tsc's OTHER `erase = true` position: two instantiations of the SAME
    // generic declaration, compared signature-by-signature
    // (`sourceObjectFlags & Instantiated && targetObjectFlags & Instantiated
    // && source.symbol === target.symbol`). ztsc keeps a signature's type
    // parameters as their DECLARATION symbols, so "same declaration" is just
    // "same type-param list" — and a pair that shares its type parameters is
    // also the pair tsc declines to instantiate in context, for the same
    // reason. This is the kysely builder case: `SelectQueryBuilder<A>.where`
    // against `SelectQueryBuilder<B>.where`, whose constraints are unions
    // over every column of every table in the schema.
    if (erase == .constraints and sameSigTypeParams(c, s, t)) erase = .any;
    var se = switch (erase) {
        .any => try c.eraseParamsToAny(s),
        .constraints => try c.eraseTypeParams(s),
        .free => s,
    };
    var te = switch (erase) {
        .any => try c.eraseParamsToAny(t),
        .constraints => try c.eraseTypeParams(t),
        .free => t,
    };
    // The source may be an arrow contextually typed by the generic target:
    // its param/return types then reference the TARGET's type-param symbols
    // as free params (the arrow itself carries no type params, so
    // `eraseTypeParams(s)` left them intact). Erase those against the
    // target's constraints too, so both sides collapse the shared params
    // consistently — the `renderHook`/`typeof base` higher-order wrapper.
    if (erase != .free and c.ts.fnTypeParams(s).len == 0 and c.ts.fnTypeParams(t).len > 0) {
        const shared = if (erase == .any) try c.eraseParamsToAnyOf(se, t) else try c.eraseParamsOf(se, t);
        if (shared != se) {
            se = shared;
        } else if (erase == .constraints) {
            // A NON-generic source that does not mention the target's type
            // parameters at all (the erasure above changed nothing) is tsc's
            // one un-erased case: `compareSignaturesRelated` instantiates a
            // generic SOURCE in the target's context and never touches a
            // generic TARGET, so its parameters stay FREE and only a source
            // that works for *every* instantiation relates. Erasing them to
            // their constraints (`any` for an unconstrained `<T>`) instead
            // made every concrete signature satisfy every generic one:
            // `interface I<T> extends Base2 { a: () => T }` over `a: <T>() =>
            // T` was silently accepted, and with it the TS2430 families
            // `subtypingWithGeneric{Call,Construct}SignaturesWithOptional
            // Parameters` and `callSignatureAssignabilityInInheritance6`.
            //
            // This used to be restricted to a source mentioning some OUTER
            // type parameter, because a fully CONCRETE source is the shape tsc
            // reaches with a source whose generic-ness came from higher-order
            // inference (`const f: <A>(x: A) => A[] = wrap(list)`, where tsc
            // infers `wrap(list): <A>(x: A) => A[]` and instantiates that
            // generic SOURCE in the target's context) while ztsc's inference
            // hands back an already-instantiated signature — so the
            // free-parameter comparison reported on code tsc accepts.
            //
            // Re-measured in wave 25, after the wave 20-24 inference work: the
            // three named blockers no longer bite. The
            // `comparisonOperator{WithNoRelationshipObjects,WithSubtypeObject}
            // OnInstantiatedCallSignature` pair — where both directions
            // failing would turn into a false TS2365/TS2367 — still matches
            // the oracle exactly (195/195 and 194/194), and
            // `genericContextualTypes1` / `genericFunctionInference1` are
            // unchanged (both already diverge for unrelated reasons). Dropping
            // the restriction is what makes the whole "concrete source against
            // a generic target" direction report:
            // `assignmentCompatWith{Call,Construct}Signatures3` and `…4` and
            // `genericSpecializations1` all became exact, with zero
            // baseline-exact regressions across the suite and both apps
            // byte-identical.
            te = t;
        }
    }
    // The same rule for a GENERIC source: tsc instantiates it in the target's
    // context and leaves the target's own parameters standing, so what the
    // source has to satisfy is `<T2>(x: { a: T2 }) => T2[]` with `T2` free,
    // not that signature erased to `any`. Erased, `<T extends Base>(x: {a: T})
    // => T[]` passed it — `Base[]` is an `any[]` — where tsc reports that
    // `Base` is not the caller's `T2`
    // (`assignmentCompatWith{Call,Construct}Signatures5`/`6`).
    //
    // The SOURCE stays erased to its CONSTRAINTS, which is ztsc's standing
    // stand-in for the instantiation: tsc's inference maps the source's
    // parameter to the target's and then clamps it to the source's own
    // constraint, and the clamp is what decides these pairs.
    //
    // Restricted to lists of the SAME LENGTH, because that is exactly when
    // the stand-in lines up. `<V, K>(key: K, defaultValue: V) => V extends
    // string ? … : V` against `<T>(feature: Features, defaultValue: T) => T
    // extends string ? … : T` is tsc-legal — inference gives `K := Features`
    // and `V := T`, making the two signatures identical — but the erasure
    // sends `V` to `any` instead of to `T`, and a conditional over `any` does
    // not satisfy the target's still-deferred conditional over `T`. With both
    // sides erased that pair matched; with only the source erased it would be
    // a false TS2322 (social-app's `analytics/index.tsx`). Where the lists do
    // line up, the erased constraint IS the value inference would clamp to.
    //
    // …and to a target whose own parameters MENTION its type variables,
    // which is what the source's erased parameters have to meet and
    // therefore what pins them. `<T extends string>() => T` overriding
    // `<T extends string>() => T | Promise<T>` mentions its variable only in
    // the RETURN — there tsc infers `T_source := T_target | Promise<T_target>`
    // and the erasure has nothing to line up with, so a free target return
    // is a false TS2416 (`inferenceContextualReturnTypeUnion4`).
    if (erase == .constraints and c.ts.fnTypeParams(s).len > 0 and
        c.ts.fnTypeParams(s).len <= c.ts.fnTypeParams(t).len and
        try sigParamsMentionOwnTypeParams(c, t))
    {
        te = t;
    }
    // The erasure runs `instantiate`, so it is subject to the instantiation
    // budget, and a trip hands back `error_type` in place of the signature —
    // not a wider signature, no signature at all. Every step below then reads
    // a non-function through the `fn*` accessors (zero parameters, a garbage
    // return) and the pair falls out "not related", which is the WRONG
    // polarity: a truncation inside the relation is `Ternary.Maybe`, the same
    // rule `instDiagAllowed` applies to the diagnostic (see `Checker`). It is
    // also silent — the budget is spent, so no TS2589 marks the spot, and the
    // only trace is a TS2322/TS2769 on a pair tsc accepts.
    //
    // Assume related, as the relation already does for a truncated type that
    // reaches it as a VALUE (`.err` relates to everything at the top of
    // `relate`). This is an under-report by construction, never a false
    // positive: the pair could not be decided, so nothing is reported.
    if (c.ts.kind(se) != .function or c.ts.kind(te) != .function) return true;
    // tsc's `compareSignaturesRelated`, first thing it does with the two
    // parameter lists:
    //
    // ```ts
    // const sourceRestType = getNonArrayRestType(source);
    // const targetRestType = getNonArrayRestType(target);
    // if (sourceRestType || targetRestType) void instantiateType(sourceRestType || targetRestType, reportUnreliableMarkers);
    // ```
    //
    // A rest parameter typed by a TUPLE (or a still-generic type) is UNROLLED
    // against the other signature's fixed parameters rather than related as a
    // type, so a variance measurement whose marker is in that tuple learns
    // nothing from the comparison. Marked `Unreliable`.
    if (c.variance_probe_markers[0] != 0) {
        const rest = nonArrayRestType(c, se) orelse nonArrayRestType(c, te);
        if (rest) |r| try variance_zig.noteVarianceMarker(c, r, false);
    }
    // tsc's `compareSignaturesRelated`: an explicit `this` parameter is part
    // of the relation and behaves like an ordinary parameter —
    // contravariant in a strict function position, bivariant for methods
    // (and inside a callback comparison, where tsc clears `strictVariance`).
    // Both guards are tsc's: a source that declares no `this` — or declares
    // `this: void`, the "never uses it" marker — imposes nothing, and a
    // target that declares no `this` demands nothing, so an annotated source
    // stays compatible with every unannotated target.
    const s_this = c.ts.fnThisType(se);
    if (s_this != 0 and s_this != types.void_type) {
        const t_this = c.ts.fnThisType(te);
        if (t_this != 0) {
            const this_bivariant = bivariant or mode != .none;
            var this_ok = try c.isAssignable(t_this, s_this);
            if (!this_ok and this_bivariant) this_ok = try c.isAssignable(s_this, t_this);
            if (!this_ok) return false;
        }
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
        // …but only when ONE side has it. Two signatures that each declare a
        // generic rest (`(…, ...args: Args) => R` on both sides, jotai's
        // `WritableAtom`'s `set`) are two instantiations of one shape, and
        // ztsc relates their type parameters as the DISTINCT parameters they
        // are: `Args` against `Args` is not `Args` here, so comparing the two
        // rests as whole types rejects a signature that is its own equal. The
        // element-wise reading, which erases both to the same thing, is the
        // one that gets that pair right — and the rule is only ever needed
        // where the OTHER side is concrete enough to say something the
        // elements cannot.
        if (sigInstantiableRest(c, se) != sigInstantiableRest(c, te)) break :blk both - 1;
        if ((try c.sigRestUnion(se)) == null and (try c.sigRestUnion(te)) == null) break :blk null;
        break :blk both - 1;
    };
    const pairs = if (rest_pair) |r| r + 1 else @min(try c.paramTotal(se), @max(s_count, t_count));
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        if (rest_pair) |r| {
            if (i == r) {
                // A TARGET that packs to a bare `any[]` here imposes nothing:
                // see `anyRestFrom`. The packed comparison below would reject
                // it, because `any[]` is not assignable to a tuple with a
                // required element.
                if (try anyRestFrom(c, te, i)) continue;
                const st = try restTypeAtPosition(c, se, i);
                const tt = try restTypeAtPosition(c, te, i);
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
        // EXCLUSIVE, exactly as tsc's `callbacks ? … : …` ternary is: where a
        // pair IS recognized as two callbacks, the callback comparison is the
        // ONLY test, and its failure is the pair's failure. That is what
        // reports `BList1 = AList1` (`forEach(cb: (item: B) => void)` against
        // `(item: A) => void`) and, through the variance MEASUREMENT that runs
        // on the same rule, what makes `P<T>`/`Promise<T>` come out COVARIANT
        // in `T` rather than bivariant (covariantCallbacks f1/f2/f11/f12/f13).
        //
        // The guard is tsc's `isInstantiatedGenericParameter`
        // (`param_flag_inst_generic`), and without it exclusivity is a false
        // positive machine: `type Bivar<T> = { set(value: T): void }` at
        // `T = (x: unknown) => void` has a parameter that only LOOKS like a
        // declared callback, because the function shape arrived as the type
        // ARGUMENT. tsc suppresses `getSingleCallSignature` for such a
        // parameter — per SIDE, so one instantiated side is enough to sink
        // the pair back to the plain bivariant comparison — and the whole
        // `#51620` half of covariantCallbacks (lines 81-95, 102, 110) is
        // exactly that shape. `then(cb: (value: T) => void)` is NOT that
        // shape: its declared parameter type is a function type, generic or
        // not, so the rule still applies there.
        //
        // Exclusivity is what makes ztsc's stand-in for
        // `instantiateSignatureInContextOf` load-bearing: a source signature
        // whose own type parameter the inference could not bind arrives with
        // that parameter clamped, and the callback comparison then fails on a
        // shape tsc never sees. drizzle-orm's `transaction<T>(cb: (tx: Tx, x:
        // T) => …)` override chain is 33 such TS2416 — every one an
        // `x: unknown` against the base's still-free `x: T` — and the fix is
        // in the inference (`infer.unify`'s bare-self candidate), not here.
        if (mode == .none and !instGenericParam(c, se, i) and !instGenericParam(c, te, i)) callbacks: {
            const s_cb = (try c.callbackSigOf(sp)) orelse break :callbacks;
            const t_cb = (try c.callbackSigOf(tp)) orelse break :callbacks;
            // tsc also requires matching undefined/null facts.
            if ((try c.includesNullish(sp)) != (try c.includesNullish(tp))) break :callbacks;
            const inner: SigMode = if (bivariant) .bivariant_callback else .strict_callback;
            if (try c.signatureAssignableMode(t_cb, s_cb, inner)) continue;
            return false;
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
    //     "Signature '…' must be a type predicate"). tsc's test is
    //     `isIdentifierTypePredicate(target) || isThisTypePredicate(target)`,
    //     so a `this is T` target forces it too — this arm was written
    //     against tsc 5.5.4, which had only the identifier half, and tsgo
    //     7.0.2 errors on `method(): boolean` overriding `method(): this is
    //     {a: 1}` (`compiler/typePredicateInherit`, both the `implements`
    //     and the `extends` witness). The two ASSERTS kinds are not in
    //     tsc's test and never reach here: an assertion returns `void`, so
    //     the early-out above already accepted the pair;
    //   - the predicate kinds must match: same asserts-ness and the same
    //     guarded position (`this` vs a parameter index);
    //   - the asserted type is covariant — source type assignable to
    //     target type.
    // A plain-boolean source → predicate target therefore *fails* (tsc
    // rejects it), and a predicate source → boolean target is fine (the
    // target has no predicate, so this block is skipped).
    if (c.ts.fnHasPredicate(te)) {
        const tp = c.ts.fnPredicate(te);
        if (!c.ts.fnHasPredicate(se)) return false;
        const spd = c.ts.fnPredicate(se);
        if (spd.asserts != tp.asserts) return false;
        if (spd.param != tp.param) return false;
        if (tp.ty != types.no_type) {
            if (spd.ty == types.no_type) return false;
            if (!try c.isAssignable(spd.ty, tp.ty)) return false;
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

/// tsc's `isInstantiatedGenericParameter(signature, pos)`: was parameter `pos`
/// of `sig` DECLARED as an instantiable (a `T`, a `T[K]`, a `keyof T`, a
/// conditional) that some instantiation has since replaced? The fact is
/// recorded on the parameter itself at substitution time — see
/// `types.param_flag_inst_generic` and `subst.declaredInstantiable`.
///
/// A position past the stored list is a rest expansion, which no declared
/// parameter backs: answer "no" and let the callback rule decide as it would
/// have.
fn instGenericParam(c: *Checker, sig: TypeId, pos: u32) bool {
    if (pos >= c.ts.fnParamCount(sig)) return false;
    return c.ts.fnParam(sig, pos).flags & types.param_flag_inst_generic != 0;
}

/// tsc `getSingleCallSignature(getNonNullableType(t))`: the lone call
/// signature of a type that is nothing BUT that signature — no properties,
/// no index signatures, no construct signatures, no overloads. A type
/// predicate disqualifies it (tsc excludes predicate signatures from the
/// callback relation).
pub fn callbackSigOf(c: *Checker, t: TypeId) Error!?TypeId {
    const stripped = try c.stripNullish(t);
    // Three of the four disqualifications are readable off the generic table
    // (see `lazyShapeOf`): a table with properties, with an index signature,
    // or with no call signature at all keeps every one of those through a
    // substitution. Only the "exactly one call signature" test has to
    // materialize, because `instantiateId` may drop a higher-order signature.
    if (try c.lazyShapeOf(stripped)) |generic| {
        if (c.ts.objectPropCount(generic) != 0) return null;
        if (c.ts.objectStringIndex(generic) != 0 or c.ts.objectNumberIndex(generic) != 0) return null;
        if (c.ts.objectCallSigCount(generic) == 0) return null;
    }
    const r = try c.resolveStructural(stripped);
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
/// Does any PARAMETER type of `sig` mention one of `sig`'s own type
/// parameters? Asked by erasing them inside each parameter type and looking
/// for a change, which reuses the memoized erasure the relation runs anyway.
fn sigParamsMentionOwnTypeParams(c: *Checker, sig: TypeId) Error!bool {
    if (c.ts.fnTypeParams(sig).len == 0) return false;
    for (0..c.ts.fnParamCount(sig)) |i| {
        const p = c.ts.fnParam(sig, @intCast(i)).ty;
        if (try c.eraseParamsOf(p, sig) != p) return true;
    }
    return false;
}

pub fn eraseParamsOf(c: *Checker, sig: TypeId, owner: TypeId) Error!TypeId {
    // Non-generic early-out before the dupe (the common case).
    const sig_tps = c.ts.fnTypeParams(owner);
    if (sig_tps.len == 0) return sig;
    // Memo (see `erase_cache`): the erasure is a pure function of
    // `(sig, owner)`, and the signature relation asks for it on both sides of
    // every generic comparison.
    const memo_key = (@as(u64, owner) << 32) | sig;
    if (c.inst_cache_on) {
        if (c.erase_cache.get(memo_key)) |r| return r;
    }
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
    // Scope the truncation flag to this derivation, exactly as `instantiateId`
    // scopes it to its own subtree: the memo below must ask "was MY result
    // truncated", not "did anything earlier in this call truncate".
    const outer_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or outer_trip;
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
    const result = try c.instantiate(sig, resolved);
    if (c.inst_cache_on and !c.inst_limit_tripped) try c.erase_cache.put(c.cm(), memo_key, result);
    return result;
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
        // whole element type — see that helper for what tsc computes, and
        // `restUnionContextualAt` for the one caller that reads the positions
        // apart.
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

/// tsc's `tryGetTypeAtPosition`, whose rest-parameter tail is
/// `getIndexedAccessType(restType, pos)` — an indexed access, so it
/// DISTRIBUTES over a rest typed by a UNION of tuples:
/// `([A, B, "a"] | [A, B, "b"])[2]` is `"a" | "b"`, not the rest's whole
/// element type. A callback written for such a parameter list gets its
/// parameters typed from here, and the whole-element answer flattened every
/// one of them to the join of every arm's every position — social-app's
/// `handles.test.ts`, whose `e` came out `string` where tsc has `"a" | "b"`,
/// and whose `IsValidHandle[e]` was a false TS7053 for it.
///
/// Kept OUT of `paramTypeAt`, which is also what the argument RELATION reads —
/// but no longer because the relation would break on it. `checkCallArguments`
/// and `argumentsMatch` now route every in-window argument through one PACKED
/// relation, which decides a union-typed rest per ARM, so the whole-list
/// question is already answered where it belongs and nothing at the parameter
/// side needs distributing (the earlier note here — that a spread made the call
/// go position by position, and that `useNavigationDeduped`'s
/// `navigation.navigate(...args)` would start failing — described machinery
/// that is gone).
///
/// Contextual typing is the side with no packed form to fall back on: a
/// callback parameter is typed from its own position and nothing else, which is
/// why the distributing read lives here rather than in the shared accessor.
///
/// An arm too SHORT to reach the position contributes nothing; the `undefined`
/// such an arm admits is `restUnionOptionalAt`'s answer, which `paramTypeAt`
/// already folded in.
pub fn paramContextualTypeAt(c: *Checker, sig: TypeId, i: u32) Error!?TypeId {
    const plain = (try paramTypeAt(c, sig, i)) orelse return null;
    const count = c.ts.fnParamCount(sig);
    if (count == 0 or i + 1 < count) return plain;
    const u = (try c.sigRestUnion(sig)) orelse return plain;
    const index = i - (count - 1);
    // `memberList` hands out a borrowed slice and `tupleElemTypeAt` can
    // re-enter the checker, which can invalidate it.
    const ms = try c.scratch().dupe(TypeId, try c.memberList(u));
    defer c.scratch().free(ms);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (ms) |m| {
        const arm = try c.resolveStructural(m);
        if (c.ts.kind(arm) != .tuple) return plain;
        const t = (try c.tupleElemTypeAt(arm, index)) orelse continue;
        try parts.append(c.scratch(), t);
    }
    if (parts.items.len == 0) return plain;
    const t = try c.ts.makeUnion(c.scratch(), parts.items);
    if (try c.restUnionOptionalAt(u, index)) return try c.makeUnion2(t, types.undefined_type);
    return t;
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

/// tsc's `getNonArrayRestType` for the family `sigNonArrayRest` does not cover:
/// a rest parameter still typed by an INSTANTIABLE type — a bare type parameter
/// (`...args: A`), a conditional (`...args: T extends 1 ? [x] : [x, y]`), an
/// indexed access. Such a rest has no element type worth comparing
/// position-wise: `A` is not `A[number]`, and relating the elements loses the
/// only thing the target could have said about it.
///
/// tsc packs both sides' remaining parameters into one tuple at that position
/// and relates them contravariantly, which is what makes
/// `(...args: A) => void` REJECT a target `(...args: unknown[]) => void` —
/// `unknown[]` is assignable to `A`'s constraint but not to `A`. Element-wise
/// both sides read `unknown` and the pair was accepted (`strictBindCallApply1`,
/// whose `callback.bind(2)` then blamed the argument instead of the receiver).
///
/// One already-loaded kind read on the last parameter, and only for a signature
/// that HAS a rest parameter; deliberately no `resolveStructural`, so an alias
/// `.ref` (which resolves to an array or a tuple in every shape this covers)
/// costs nothing on the relation's hot path.
fn sigInstantiableRest(c: *const Checker, sig: TypeId) bool {
    return instantiableRestType(c, sig) != null;
}

fn instantiableRestType(c: *const Checker, sig: TypeId) ?TypeId {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    const p = c.ts.fnParam(sig, count - 1);
    if (!p.rest()) return null;
    // `...args: [...Args]` is `...args: Args` (see `loneVariadic`), and the two
    // spellings meet each other constantly — a contextually typed
    // `(this, ...args) => …` written against a `(...args: Args) => …` parameter
    // comes back with the spread form.
    const ty = loneVariadic(c, p.ty);
    return switch (c.ts.kind(ty)) {
        .type_param, .conditional, .index_access => ty,
        else => null,
    };
}

/// tsc's `getRestTypeAtPosition`, which answers with the REST TYPE ITSELF at the
/// rest's own position:
///
/// ```ts
/// return pos === parameterCount - 1 ? restType : createArrayType(getIndexedAccessType(restType, numberType));
/// ```
///
/// `restTupleAtPosition` packs it into a tuple instead, which is the same type
/// for every rest that HAS a positional expansion (`makeTuple` collapses a lone
/// variadic element back to its array) and a strictly weaker one for a rest that
/// does not: `[...(T extends 1 ? [x] : [x, y])]` relates through the variadic
/// element's element type, where the bare conditional relates as itself and
/// rejects — `strictBindCallApply1`'s `baz` callback.
fn restTypeAtPosition(c: *Checker, sig: TypeId, pos: u32) Error!TypeId {
    if (instantiableRestType(c, sig)) |rt| {
        if (pos + 1 == c.ts.fnParamCount(sig)) return rt;
    }
    // The other half of tsc's `getEffectiveRestType`, for a rest typed by a
    // VARIADIC tuple:
    //
    // ```ts
    // if (restType.target.hasRestElement) return sliceTupleType(restType, restType.target.fixedLength);
    // ```
    //
    // The slice keeps the trailing element's VARIADIC flag, so
    // `(...x: [number, ...T])` answers `[...T]` — which normalizes to `T` —
    // at its rest position. `restTupleAtPosition` reads that position through
    // `paramTypeAt`, which hands back the variadic's ELEMENT type and drops
    // the spread, so the same signature packed `[(T[number])?]` and failed
    // against a target whose own rest IS `T`:
    // `(...x: [number, ...T]) => void` was refused as a
    // `(x: number, ...args: T) => void` (`restTuplesFromContextualTypes` f4).
    if (try c.sigRestTuple(sig)) |tup| {
        const len = c.ts.tupleLen(tup);
        if (len > 0 and pos + 1 == c.ts.fnParamCount(sig) - 1 + len) {
            const e = c.ts.tupleElem(tup, @intCast(len - 1));
            if (e.rest()) return e.ty;
        }
    }
    return loneVariadic(c, try c.restTupleAtPosition(sig, pos));
}

/// `[...X]` IS `X` — tsc's `createNormalizedTupleType` collapses a tuple whose
/// only element spreads another type. `makeTuple` already does it when `X` is an
/// array (there is an array type to collapse to); a `[...Args]` written over a
/// type PARAMETER keeps the wrapper, and comparing that wrapper against the bare
/// `Args` the other side supplies rejects a signature that is its own equal
/// (`esDecorators-contextualTypes.2`'s `(this, ...args) => …` against
/// `(this: This, ...args: Args) => Return`).
fn loneVariadic(c: *const Checker, t: TypeId) TypeId {
    if (c.ts.kind(t) != .tuple or c.ts.tupleLen(t) != 1) return t;
    const e = c.ts.tupleElem(t, 0);
    return if (e.rest()) e.ty else t;
}

/// Is everything `sig` accepts from position `pos` onward an UNBOUNDED rest
/// parameter whose element type is `any`? — `(...args: any[])` at position 0,
/// `(first: T, ...args: any[])` at position 1, `(...args: any)` (tsc's
/// `getEffectiveRestType` turns a bare `any` rest into `any[]`), and the
/// variadic tail of `(...args: [any, ...any[]])`.
///
/// It answers the one asymmetry in tsc's whole-list rest comparison. Where
/// either side's rest is not a single tuple, `compareSignaturesRelated` packs
/// both parameter lists into a tuple at that position
/// (`getRestTypeAtPosition`) and relates them contravariantly — and a packed
/// tuple with a required element is not something `any[]` satisfies:
/// `any[]` -> `[event: string, string]` is rejected as a plain assignment, by
/// tsgo and by ztsc alike. tsc nevertheless accepts every signature pair whose
/// TARGET packs to a bare `any[]` there, which is what makes
///
///     declare const q: (event: string, ...args: [number] | [string]) => void;
///     declare let p: (...args: any[]) => any;
///     p = q;
///
/// legal. Measured against the pinned oracle (tsgo 7.0.2) — see
/// `test/conformance/assignability/rest_union_packed_against_any_rest.ts`,
/// which pins every boundary below:
///
///   * ACCEPTED for a target rest of `any[]`, `readonly any[]`, `Array<any>`,
///     `any`, `[...any[]]`, `[any, ...any[]]`, with or without a leading fixed
///     target parameter, and whatever the target's return type is (so this is
///     not tsc's `isAnySignature`, which also demands one parameter, no type
///     parameters and an `any` return — a target of
///     `<T>(...args: any[]) => number` is accepted on its parameters and
///     rejected on its return alone).
///   * REJECTED, with the packed tuple named, for `unknown[]`, `number[]`,
///     `(string | number)[]`, `[unknown, ...unknown[]]` — `any` is the whole
///     rule, not "array of something wide".
///   * REJECTED when the position being packed is NOT the target's own rest
///     position, because the packed target is then a tuple with a fixed head
///     (`[a: string, ...any[]]`) rather than a bare `any[]`, and tsc compares
///     it in full.
///   * a FIXED tuple rest (`(...args: [any])`) is excluded: it has a
///     positional expansion, so tsc packs `[any]` and rejects a source that
///     needs two elements ("Source has 1 element(s) but target requires 2").
fn anyRestFrom(c: *Checker, sig: TypeId, pos: u32) Error!bool {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return false;
    const last = c.ts.fnParam(sig, count - 1);
    if (!last.rest()) return false;
    // Unbounded: a rest typed by a fully fixed tuple expands positionally.
    if ((try c.paramTotal(sig)) != std.math.maxInt(u32)) return false;
    // `pos` has to be the rest's own position, not one before it.
    if (pos + 1 != try c.effParamCount(sig)) return false;
    // `elemOfArrayish` answers `any` for anything it does not recognize — a
    // bare type-parameter rest (`...args: A`) among them — so the rest's own
    // shape is checked first, and only then its element type.
    switch (c.ts.kind(try c.resolveStructural(last.ty))) {
        .any => return true,
        .array, .tuple => {},
        else => return false,
    }
    return (try c.paramTypeAt(sig, pos)) == types.any_type;
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
    // An interface/class instance is an object for every argument list, and
    // an object is neither `void` nor a union containing it — so the member
    // table need not be materialized to say no. See `refExpandsToObject`.
    if (c.refExpandsToObject(ty)) return false;
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
//
// Lives in `assign_report.zig`: the relation above answers with a bare bool
// and allocates nothing, and the reporting reconstructs the failure post-hoc.
// Re-exported so `Checker`'s method aliases and other modules' imports keep
// resolving through `assign.zig`.

pub const checkAssignable = report_zig.checkAssignable;
pub const inlineCondAnnRejects = report_zig.inlineCondAnnRejects;
pub const condStrictSourceRejects = report_zig.condStrictSourceRejects;
pub const checkSatisfies = report_zig.checkSatisfies;
pub const elaborateLiteralError = report_zig.elaborateLiteralError;
pub const freshLiteralUnionMismatch = report_zig.freshLiteralUnionMismatch;
pub const literalPropsKnownIn = report_zig.literalPropsKnownIn;
pub const elemTypeAt = report_zig.elemTypeAt;
pub const unionElemTypeAt = report_zig.unionElemTypeAt;
pub const bestMatchingUnionMember = report_zig.bestMatchingUnionMember;
pub const elaborateCallbackError = report_zig.elaborateCallbackError;
pub const callbackParamsCompatible = report_zig.callbackParamsCompatible;
pub const tryReportMissingProps = report_zig.tryReportMissingProps;
pub const reportNotAssignable = report_zig.reportNotAssignable;
pub const stringLiteralSuggestion = report_zig.stringLiteralSuggestion;
pub const isSourceObjecty = report_zig.isSourceObjecty;
pub const excessPropertyCheck = report_zig.excessPropertyCheck;
pub const excessPropertyScan = report_zig.excessPropertyScan;
pub const excessPropertyFailure = report_zig.excessPropertyFailure;
pub const freshLiteralRejects = report_zig.freshLiteralRejects;
pub const intersectionExcessCheckable = report_zig.intersectionExcessCheckable;
pub const targetIsEmptyish = report_zig.targetIsEmptyish;
pub const targetKnowsProp = report_zig.targetKnowsProp;
pub const targetPropType = report_zig.targetPropType;

// The tuple side of the relation, including variadic tuples, lives in
// `tuple_relate.zig`.

pub const tupleAssignable = tuple_zig.tupleAssignable;
