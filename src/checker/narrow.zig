//! The narrowing primitives themselves: `(type, descriptor, sense) -> type`
//! filters on the type lattice — equality against a literal or a value,
//! `typeof`, a discriminant property, `in`, and `instanceof`/type-predicate
//! candidates.
//!
//! Every function here is a pure function of the types it is handed (plus the
//! `Checker`'s type store and relations). None of them knows what a flow node
//! is, reads the flow caches, or decides WHICH filter a condition calls —
//! that is `flow.zig`'s job, and it re-exports every symbol below so
//! `Checker` method spellings (`c.narrowByTypeof(...)`) keep resolving.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const Atom = intern.Atom;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const isInstantiableKind = @import("expr.zig").isInstantiableKind;
const typeof_names = Checker.typeof_names;

pub fn narrowByLiteralEquality(c: *Checker, t: TypeId, other: Node, strict: bool, sense: bool) Error!TypeId {
    const ot0 = try c.checkExprCached(other, types.no_type);
    const ot1 = try c.ts.regularLiteral(ot0);
    // `x === 'a'` / `x !== 1` where `x` is an ENUM: tsc's whole enum is the
    // union `E.A | E.B`, so `filterType(E, t => areTypesComparable(t, "a"))`
    // keeps `E.A` on the true branch and drops it on the false one. ztsc
    // keeps the enum as one type and the arms below match member types by
    // identity, so the raw value is translated into the member type it names
    // first — after which the existing enum arms do exactly tsc's thing.
    // Without it `e !== 'a'` never shrank `E` and `e === 'a'` collapsed the
    // reference to `never`.
    const ot = try enumMemberForLiteral(c, t, ot1);
    const ok = c.ts.kind(ot);
    const is_nullish = ok == .null or ok == .undefined;
    if (!strict and is_nullish) {
        // == null / == undefined match both.
        if (sense) {
            return c.filterUnion(t, struct {
                fn keep(ch: *Checker, m: TypeId) bool {
                    const k = ch.ts.kind(m);
                    return k == .null or k == .undefined or k == .any or k == .unknown or k == .err;
                }
            }.keep);
        }
        return c.nonNullable(t);
    }
    // `unknown === <anything>`: the one place a NON-unit comparand narrows.
    // tsc's `narrowTypeByEquality` gives an `unknown` reference the comparand's
    // own type when that type is primitive, and `object` when it is an object
    // type — a strict comparison can only succeed when the two sides share a
    // value, and `unknown` has nothing of its own to filter.
    if (strict and sense and c.ts.kind(t) == .unknown) {
        if (try unknownEqualityNarrow(c, ot)) |n| return n;
    }
    // tsc's `isUnitType` covers `TypeFlags.Unit` = Literal | UniqueESSymbol |
    // Nullable, so a `unique symbol` comparand narrows exactly like a literal
    // one: `if (post === POST_TOMBSTONE)` must remove the tombstone
    // constituent from `Shadow<PostView> | typeof POST_TOMBSTONE` on the else
    // branch. Plain `symbol` is NOT a unit type and still narrows nothing.
    const is_literal = c.ts.isLiteralLike(ot) or is_nullish or ok == .unique_symbol;
    if (!is_literal) return t;
    if (sense) {
        return c.narrowToValue(t, ot);
    }
    return c.narrowExcludeValue(t, ot);
}

/// tsc's `recombineUnknownType`: `{} | null | undefined` (`unknownUnionType`)
/// IS `unknown`, and tsc re-spells it the moment a narrowing that expanded
/// `unknown` into it hands the type back.
///
/// A flow JOIN is where the expansion otherwise escapes: `if (u === undefined)`
/// leaves `undefined` on one branch and `{} | null` on the other, and their
/// union is the expanded spelling. Every later query then sees a union where
/// tsc sees `unknown` — which silently disables every `unknown`-only rule
/// downstream, `narrowTypeByEquality`'s included.
pub fn recombineUnknown(c: *Checker, t: TypeId) TypeId {
    if (c.ts.kind(t) != .union_type) return t;
    const members = c.ts.members(t);
    if (members.len != 3) return t;
    var has_empty = false;
    var has_null = false;
    var has_undef = false;
    for (members) |m| {
        switch (c.ts.kind(m)) {
            .null => has_null = true,
            .undefined => has_undef = true,
            else => if (m == types.empty_object_type) {
                has_empty = true;
            } else return t,
        }
    }
    return if (has_empty and has_null and has_undef) types.unknown_type else t;
}

/// What a strict `unknown === v` narrows the reference to, or null when `v`
/// tells us nothing (tsc's `narrowTypeByEquality`, the `TypeFlags.Unknown &&
/// assumeTrue` arm):
///
///   - a PRIMITIVE comparand hands over its own type, so `u === aString` is
///     `string` and `u === NumberEnum.A` is `NumberEnum.A` — the comparand
///     UNRESOLVED, since that is the name the narrowing must keep;
///   - an OBJECT comparand hands over `object` (tsc's `nonPrimitiveType`), not
///     its own shape: equality proves only that the value is a reference;
///   - anything else — a union, an intersection, a type variable — narrows
///     nothing, so the reference stays `unknown`.
fn unknownEqualityNarrow(c: *Checker, v: TypeId) Error!?TypeId {
    switch (c.ts.kind(v)) {
        // Nominal kinds whose structural resolution would erase the very
        // identity the narrowing is meant to keep.
        .enum_type, .unique_symbol => return v,
        else => {},
    }
    return switch (c.ts.kind(try c.resolveStructural(v))) {
        .string, .number, .bigint, .boolean, .symbol, .void, .undefined, .null, .object_keyword => v,
        .string_literal, .number_literal, .number_literal_fresh, .bigint_literal => v,
        .bool_true, .bool_false, .template_literal_type, .string_mapping => v,
        .object, .array, .tuple, .function, .overloads, .class_value => types.object_keyword_type,
        else => null,
    };
}

/// Translate a plain literal comparand into the ENUM MEMBER type it names,
/// when the narrowed type is an enum (optionally nullable). Returns the
/// comparand unchanged in every other case, including a mixed union such as
/// `E | string`, where the plain literal is still the right comparand for the
/// non-enum constituents.
fn enumMemberForLiteral(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    switch (c.ts.kind(v)) {
        .string_literal, .number_literal, .number_literal_fresh => {},
        else => return v,
    }
    var sym: ?u32 = null;
    if (c.ts.kind(t) == .enum_type) {
        sym = c.ts.enumSymbol(t);
    } else if (c.ts.kind(t) == .union_type) {
        for (c.ts.members(t)) |m| {
            switch (c.ts.kind(m)) {
                .enum_type => {
                    const s = c.ts.enumSymbol(m);
                    if (sym != null and sym.? != s) return v; // two enums: leave it
                    sym = s;
                },
                .null, .undefined => {},
                else => return v, // a non-enum constituent still wants the literal
            }
        }
    }
    const es = sym orelse return v;
    return (try c.enumMemberForValue(es, v)) orelse v;
}

/// Narrow `t` to the single value type `v` (=== true branch).
pub fn narrowToValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const nm = try c.narrowToValue(m, v);
            if (nm != types.never_type) try parts.append(c.scratch(), nm);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const mt = try c.ts.regularLiteral(t);
    const k = c.ts.kind(mt);
    if (mt == v) return v;
    if (k == .any or k == .unknown or k == .err) return v;
    // `=== null` / `=== undefined`: only a matching nullish member (handled
    // by `mt == v` above) survives; any other concrete member is excluded.
    // Without this the false branch of `x !== null` stayed `number | null`,
    // defeating the inferred-predicate disjointness gate (and under-
    // narrowing `if (x === null)`).
    if (c.ts.kind(v) == .null or c.ts.kind(v) == .undefined) return types.never_type;
    if (try c.literalBaseOf(v) == mt) return v; // string narrowed by "a" / `E` by `E.A`
    if (k == .boolean and (c.ts.kind(v) == .bool_true or c.ts.kind(v) == .bool_false)) return v;
    // `=== <unique symbol>`: a nominal `unique symbol` is equal to nothing
    // but itself (the `mt == v` case above), so every other concrete member
    // is excluded. `symbol` itself survives unnarrowed — verified against the
    // oracle, which leaves `symbol` alone rather than narrowing it down to
    // the unit.
    if (c.ts.kind(v) == .unique_symbol) {
        return if (k == .symbol) mt else types.never_type;
    }
    if (c.ts.isLiteralLike(mt) or k == .null or k == .undefined) {
        return types.never_type; // different literal
    }
    // Non-literal member unrelated to v's base: exclude.
    if (c.ts.isLiteralLike(v)) return types.never_type;
    return mt;
}

/// Remove the single value type `v` from `t` (!== true branch).
/// Is `t`, or any constituent of it if it is a union, of kind `k`?
pub fn unionHasKind(c: *Checker, t: TypeId, k: types.Kind) bool {
    if (c.ts.kind(t) == k) return true;
    if (c.ts.kind(t) != .union_type) return false;
    for (c.ts.members(t)) |m| {
        if (c.ts.kind(m) == k) return true;
    }
    return false;
}

pub fn narrowExcludeValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const nm = try c.narrowExcludeValue(m, v);
            if (nm != types.never_type) try parts.append(c.scratch(), nm);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const mt = try c.ts.regularLiteral(t);
    if (mt == v) return types.never_type;
    // Under strictNullChecks tsc narrows `unknown` as if it were
    // `undefined | null | {}` (`unknownUnionType`) and re-spells the FULL
    // union `unknown` afterwards, so subtracting one nullish arm leaves the
    // other two. `if (e !== null && e !== undefined)` on an `unknown` ends at
    // `{}`, which carries `Object`'s apparent members.
    if (c.ts.kind(mt) == .unknown) {
        switch (c.ts.kind(v)) {
            .null => return try c.ts.makeUnion(c.scratch(), &.{ types.undefined_type, types.empty_object_type }),
            .undefined => return try c.ts.makeUnion(c.scratch(), &.{ types.null_type, types.empty_object_type }),
            else => {},
        }
    }
    // A DEFERRED conditional or indexed access is not a union, so none of
    // the arms here can subtract the nullish constituent hiding inside it,
    // and `x !== undefined` left the type exactly as it found it. tsc's
    // `getAdjustedTypeWithFacts` covers this: for `NEUndefined` it maps a
    // constituent that *could* be undefined onto its BASE CONSTRAINT and
    // re-applies the fact there. So
    // `K extends keyof M ? M[K] | undefined : never` guarded by
    // `!== undefined` becomes the constraint without `undefined`.
    //
    // `ShapeCache.generateElementShape` is the shape that needs it: its
    // inferred return type unions the guarded `cachedShape` with the
    // freshly-generated one, so an `undefined` that the `if (cachedShape
    // !== undefined) return cachedShape` had already excluded survived into
    // the result, and every `.forEach` on it reported an implicit `any`.
    // Only when the constraint really carries the value being excluded: an
    // access that CANNOT be undefined (`M[K]` inside `M[K] | undefined`)
    // must keep its deferred spelling, or the union arm above would trade
    // every such member for its constraint.
    if ((c.ts.kind(v) == .undefined or c.ts.kind(v) == .null) and
        (c.ts.kind(mt) == .conditional or c.ts.kind(mt) == .index_access))
    {
        const base = try c.transitiveBaseConstraint(mt);
        if (base != mt and base != types.no_type and c.unionHasKind(base, c.ts.kind(v))) {
            // `& {}`, exactly as a bare type parameter is handled: the
            // deferred spelling survives, so instantiating it later still
            // produces the caller's own type argument, while the apparent
            // members seen through it are the constraint's non-nullish
            // ones. Replacing it with the constraint outright would bake the
            // constraint into any inferred return type built from this
            // branch, and `f("a")` would come back `string | number[]`
            // instead of `number[]`.
            return c.ts.makeIntersection(c.scratch(), &.{ mt, types.empty_object_type });
        }
    }
    // `x !== E.A` on a WHOLE-enum reference: the enum is the union of its
    // members (tsc), so the branch keeps every other member —
    // `WS.INVALID | WS.UPDATE`, not `WS`. Without this the negative branch
    // never shrinks and a fully-covered `switch` is not exhaustive.
    if (c.ts.isEnumMember(v) and c.ts.kind(mt) == .enum_type and !c.ts.isEnumMember(mt) and
        c.ts.enumSymbol(mt) == c.ts.enumSymbol(v))
    {
        if (try c.enumMemberTypeUnion(c.ts.enumSymbol(mt), c.ts.enumMemberAtom(v))) |rest| return rest;
        return types.never_type;
    }
    if (c.ts.kind(mt) == .boolean) {
        if (c.ts.kind(v) == .bool_true) return types.false_type;
        if (c.ts.kind(v) == .bool_false) return types.true_type;
    }
    return t;
}

pub fn narrowByTypeof(c: *Checker, t0: TypeId, str: Atom, sense: bool) Error!TypeId {
    var which: usize = typeof_names.len;
    for (c.typeof_atoms, 0..) |a, i| {
        if (a == str) which = i;
    }
    if (which == typeof_names.len) return narrowByTypeofHostObject(c, t0, sense);
    // A type parameter narrows through its CONSTRAINT (`typeofMatches` only
    // inspects concrete kinds, so filtering `T` itself would collapse
    // `typeof x === 'object'` to `never`) — but the answer must stay a
    // subtype of `T`, so the filtered constraint is intersected back with
    // the type param. tsc does exactly this (`getNarrowedType` ends in
    // `getIntersectionType([t, candidate])` for an instantiable `t`), and it
    // is what keeps a narrowed reference passable where `T` is wanted: in
    // `<T extends { id: string } | string>`, the value argument of
    // `m.set(typeof e === "string" ? e : e.id, e)` is read at the merge of
    // the two branches, and a bare filtered constraint made it
    // `string | { id: string }` — not assignable to `T` (TS2345).
    if (c.ts.kind(t0) == .type_param) {
        const con = try c.baseConstraintOf(t0);
        if (con != t0) {
            const narrowed = try c.narrowByTypeofResolved(con, which, sense);
            if (narrowed == con) return t0; // nothing filtered
            if (c.ts.kind(narrowed) == .never) return types.never_type;
            return c.ts.makeIntersection(c.scratch(), &.{ t0, narrowed });
        }
    }
    return c.narrowByTypeofResolved(t0, which, sense);
}

/// `typeof x === "Object"` — a string literal that is not one of the eight
/// values `typeof` can produce. tsc does not give up: the comparison can only
/// succeed for a "host object" (tsc's `TypeofEQHostObject`/`TypeofNEHostObject`
/// fact masks, the fallback when the literal is in neither `typeofEQFacts` nor
/// `typeofNEFacts`), so the asserting branch keeps the OBJECT-ish constituents
/// and the other branch keeps the primitives.
///
/// Oracle-verified on `string | number | boolean | symbol | bigint | undefined
/// | null | C | (() => void) | {} | object`:
///   `=== "Object"` → `object | C | () => void`
///   `!== "Object"` → `string | number | bigint | symbol | boolean | {} | null
///                     | undefined`
/// and an `any`/`unknown` subject becomes `object` on the asserting branch.
/// `null` sides with the primitives even though `typeof null` IS `"object"`,
/// which is why it is excluded here explicitly.
///
/// One knowingly-kept divergence: tsc drops `{}` on the asserting branch (its
/// empty-object facts carry only the NE bit) while the object-kind test below
/// keeps it. Reproducing that would need an `emptyObjectType` identity ztsc
/// does not distinguish from any other member-less object type.
fn narrowByTypeofHostObject(c: *Checker, t: TypeId, sense: bool) Error!TypeId {
    const k = c.ts.kind(t);
    if (k == .any or k == .unknown or k == .err) {
        return if (sense) types.object_keyword_type else t;
    }
    if (k == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            if (try hostObjectMatches(c, m) == sense) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    if (try hostObjectMatches(c, t) == sense) return t;
    return types.never_type;
}

/// Could `typeof m` be a value outside the eight standard ones — i.e. is `m`
/// an object or a function, `null` aside?
fn hostObjectMatches(c: *Checker, m: TypeId) Error!bool {
    if (c.ts.kind(m) == .null) return false;
    if (try c.typeofMatchesFn(m, 7)) return true;
    return c.typeofMatchesFn(m, 6);
}

pub fn narrowByTypeofResolved(c: *Checker, t: TypeId, which: usize, sense: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            // A constituent that is itself an ALIAS for a union — React's
            // `ReactNode` inferred into a naked type variable is the case —
            // has to be seen through, or the whole alias answers "not a
            // string" and the `typeof child === 'string'` branch is `never`.
            // tsc's unions are always flattened; ztsc's can hold a reference.
            const rm = try c.resolveStructural(m);
            if (rm != m and c.ts.kind(rm) == .union_type) {
                const nm = try narrowByTypeofResolved(c, rm, which, sense);
                if (nm != types.never_type) try parts.append(c.scratch(), nm);
                continue;
            }
            const keep = try c.typeofMatchesFn(m, which);
            const kept = if (sense) keep else !keep;
            if (kept) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const k = c.ts.kind(t);
    if (k == .any or k == .unknown or k == .err) {
        if (!sense) return t;
        return switch (which) {
            0 => types.string_type,
            1 => types.number_type,
            2 => types.bigint_type,
            3 => types.boolean_type,
            4 => types.symbol_type,
            5 => types.undefined_type,
            6 => if (k == .unknown) try c.makeUnion2(types.object_keyword_type, types.null_type) else types.any_type,
            7 => t, // "function": no Function type in subset — keep
            else => t,
        };
    }
    const matches = try c.typeofMatchesFn(t, which);
    if (sense) return if (matches) t else types.never_type;
    return if (matches) types.never_type else t;
}

/// `typeofMatches` plus tsc's `isFunctionObjectType`: for `typeof x ===
/// "function"` an OBJECT type survives when it carries call or construct
/// signatures. `interface SymbolConstructor { (d?: string): symbol; … }` is
/// a `.ref`, so the syntactic-kind test alone answered "not a function" and
/// narrowed every callable interface — `Symbol`, `Array`, a mixin
/// constructor, an unannotated `const f = Object.assign(fn, {…})` — to
/// `never` inside its own `typeof === "function"` guard. Silent while a read
/// off `never` was permissive; a TS2339 the moment it stopped being.
///
/// Only the *keep* side is widened here: the `"object"` case still keeps a
/// callable (tsc's `FunctionFacts` would drop it), which under-narrows and
/// can only lose a diagnostic, never invent one.
pub fn typeofMatchesFn(c: *Checker, t: TypeId, which: usize) Error!bool {
    if (c.typeofMatches(t, which)) return true;
    if (c.ts.kind(t) == .enum_type) return c.enumTypeofDomain(t, which);
    if (which != 7) return false;
    return switch (c.ts.kind(t)) {
        .ref, .object, .intersection => c.hasCallableShape(t),
        else => false,
    };
}

/// Which `typeof` bucket an enum type falls in. tsc models an enum as the
/// UNION of its member types, and each member type is a string- or
/// number-LITERAL type carrying the enum flag — so `typeof` classifies an
/// enum by its VALUE domain, and `typeof p === 'string'` keeps a string enum
/// whole rather than collapsing it to `never`. ztsc keeps an enum as ONE
/// nominal type, so the domain has to be read off the declaration: a member
/// by its own constant value, a whole enum by whether any member is
/// string-valued (the split `isStringish` / `isNumberish` already follow).
///
/// Nothing else changes: an enum is not an object and not a function, so
/// every other bucket stays false and those branches narrow as before.
pub fn enumTypeofDomain(c: *Checker, t: TypeId, which: usize) Error!bool {
    if (which != 0 and which != 1) return false; // only "string" / "number"
    const sym = c.ts.enumSymbol(t);
    var stringish = c.enumHasStringMember(sym);
    if (c.ts.isEnumMember(t)) {
        if (try c.enumMemberValue(sym, c.ts.enumMemberAtom(t))) |v| {
            stringish = c.ts.kind(try c.ts.regularLiteral(v)) == .string_literal;
        }
    }
    return if (which == 0) stringish else !stringish;
}

/// Does `t` carry a call or construct signature? (`lastCallSig` already
/// walks overload sets and intersections for the call half.)
pub fn hasCallableShape(c: *Checker, t: TypeId) Error!bool {
    if ((try c.lastCallSig(t)) != null) return true;
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => return c.ts.objectConstructSigCount(r) > 0,
        .intersection => {
            for (try c.memberList(r)) |m| {
                if (try c.hasCallableShape(m)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn typeofMatches(c: *Checker, t: TypeId, which: usize) bool {
    const k = c.ts.kind(t);
    return switch (which) {
        0 => k == .string or k == .string_literal,
        1 => k == .number or k == .number_literal or k == .number_literal_fresh,
        2 => k == .bigint or k == .bigint_literal,
        3 => k == .boolean or k == .bool_true or k == .bool_false,
        4 => k == .symbol,
        5 => k == .undefined or k == .void,
        6 => k == .null or k == .object or k == .array or k == .tuple or k == .ref or
            k == .object_keyword or k == .intersection,
        7 => k == .function or k == .overloads or k == .class_value,
        else => false,
    };
}

/// The UNION facet of `t`, seeing through a deferred type-alias reference.
///
/// tsc's unions are always flattened by the time narrowing sees them:
/// `getDeclaredTypeOfTypeAlias` hands `getDiscriminantPropertyAccess` a real
/// union object, and a RECURSIVE alias is no different — the recursion is
/// carried by deferred member resolution, not by a different type shape.
/// ztsc defers such an alias as a `.ref` instead, because that laziness is
/// what terminates
///
///     type R = { type: 'a'; view: string } | { type: 'w'; media: R }
///
/// at all. The cost was that every union-shaped narrowing test — "is this a
/// discriminated union?", "which constituents survive?" — asked its question
/// of the reference, got "not a union", and declined to narrow: `r.media`
/// stayed `R` after `r.media.type === 'a'`, so reading `r.media.view`
/// reported TS2339, and social-app's `MediaPreview` kept the whole recursive
/// `Embed` constituent inside `e.media.view` and reported TS2322 against
/// `PostView['embed']`. Non-recursive aliases were unaffected, which is why
/// the shape needed a self-referential union to show at all.
///
/// Resolving here is one level and non-recursive: the members it yields may
/// themselves be references, which stay lazy exactly as before. It is used
/// for the DECISION only — every caller returns the original `t` when nothing
/// was filtered, so a narrowing that is a no-op still reports as the alias.
pub fn unionFacet(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .ref) return t;
    const r = try c.resolveStructural(t);
    return if (c.ts.kind(r) == .union_type) r else t;
}

pub fn narrowByDiscriminant(c: *Checker, t0: TypeId, prop: Atom, value: TypeId, sense: bool, decl0: TypeId) Error!TypeId {
    const t = try unionFacet(c, t0);
    const decl = try unionFacet(c, decl0);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    // Also filter a single (non-union) member: once a discriminated union
    // has been narrowed to one constituent, an equality guard on its
    // discriminant still refines it — the false branch of `x.type === 'C'`
    // on `{ type: 'C' }` is `never` (tsc). A member lacking the discriminant
    // prop (`any`/`unknown`/primitives, wide `type: string`) stays in both
    // branches via the conservative arms below, so nothing over-narrows.
    //
    // …but only when `prop` really is a DISCRIMINANT. tsc reaches every
    // discriminant narrowing (equality, truthiness, `switch`) through
    // `getDiscriminantPropertyAccess`, which selects
    // `declaredType.flags & Union ? declaredType : computedType` and then
    // demands `isDiscriminantProperty`. Both halves of that matter here:
    //
    //   * a NON-UNION reference is never discriminated at all, so
    //     `switch (data.encoding) { case "bstring": …; default: throw
    //     Error(data.encoding) }` on a plain `{ encoding: "bstring"; … }`
    //     keeps its type in the `default:` clause instead of collapsing to
    //     `never` — the exhaustiveness idiom, and a false positive before;
    //   * a property whose per-constituent types are uniform or carry no
    //     unit type is not a discriminant either, so
    //     `sel[0].id === app.selectedLinearElement?.elementId` must leave
    //     `sel[0]` (a `line | arrow` union with `id: string` on both) alone
    //     rather than filtering it to `never`.
    //
    // `decl` is the reference's declared type, threaded down from
    // `flowTypeInner` — for a reference already narrowed to one constituent
    // it is still the union, which is exactly the shape the single-member
    // fallback above exists for.
    const disc_over = if (c.ts.kind(decl) == .union_type) decl else t;
    if (!try c.isDiscriminantProp(disc_over, prop)) return t;
    // tsc's `narrowTypeByEquality` subtracts on the NOT-EQUAL side only when
    // the COMPARAND is a unit type: `if (valueType.flags & TypeFlags.Unit)
    // return filterType(…); return type;`. A comparand that is a whole enum
    // — or any union of units — has no Unit flag, so nothing is subtracted.
    //
    // social-app's `Conversation` screen is the shape: `const [prevState] =
    // useState(convoState.status)` gives `prevState` the WHOLE `ConvoStatus`
    // enum, and `if (prevState !== convoState.status)` then matched (and so
    // removed) every constituent of the convo union, leaving `never` for the
    // rest of the block.
    const value_unit = blk: {
        const rv = try c.ts.regularLiteral(value);
        break :blk c.ts.isLiteralLike(rv) or c.ts.kind(rv) == .null or c.ts.kind(rv) == .undefined;
    };
    if (!sense and !value_unit) return t;
    const single = [_]TypeId{t};
    const members: []const TypeId = if (c.ts.kind(t) == .union_type) try c.memberList(t) else &single;
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        const p = try c.propOfType(rm, prop);
        var matches = true; // members without the prop stay (conservative)
        if (p) |pp| {
            const pv = try c.ts.regularLiteral(pp.ty);
            if (c.ts.isLiteralLike(pv) or c.ts.kind(pv) == .null or c.ts.kind(pv) == .undefined) {
                matches = try c.isComparable(pv, value);
            } else {
                matches = try c.isComparable(pp.ty, value);
            }
        }
        const kept = if (sense) matches else blk: {
            // false branch removes a member only when its discriminant is a
            // UNIT type (literal / null / undefined) exactly equal to the
            // value. A wide discriminant (`current: string`) is never a
            // unit, so `x.current !== s` must keep it — dropping it to
            // `never` is the over-narrow that a single-member `t` exposed.
            if (p) |pp| {
                const pv = try c.ts.regularLiteral(pp.ty);
                const is_unit = c.ts.isLiteralLike(pv) or
                    c.ts.kind(pv) == .null or c.ts.kind(pv) == .undefined;
                // COMPARABLE, not identical — tsc's rule is
                // `!(isUnitLikeType(t) && areTypesComparable(t, valueType))`,
                // and `matches` above is that same comparability test. The
                // difference shows on a string/numeric ENUM discriminant
                // guarded by its raw value (`edit.action !== 'crop'` on
                // `action: AssetEditAction.Crop`): identity kept every member
                // on the false branch, so the branches overlapped and the
                // TS 5.5 inferred predicate on `find`/`filter` was refused.
                break :blk !(is_unit and matches);
            }
            break :blk true;
        };
        if (kept) try parts.append(c.scratch(), m);
    }
    // Nothing filtered: hand back the type the caller passed in, not the
    // resolved facet, so a no-op narrowing never expands a deferred alias
    // (`unionFacet`).
    if (parts.items.len == members.len) return t0;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

pub fn narrowByPropTruthiness(c: *Checker, t0: TypeId, prop: Atom, sense: bool, decl0: TypeId) Error!TypeId {
    const t = try unionFacet(c, t0);
    const decl = try unionFacet(c, decl0);
    if (c.ts.kind(t) != .union_type) return t0;
    // tsc's `narrowTypeByTruthiness` reaches the per-member filter only
    // through `getDiscriminantPropertyAccess`, which requires `prop` to be a
    // DISCRIMINANT of the union (`isDiscriminantProperty`). Without that gate
    // `element.lineHeight || …` — a `number & { _brand }` property that is
    // uniformly non-optional and never a unit type — dropped every member on
    // the falsy branch and left `never`, so the `||`'s right operand reported
    // TS2339 on the same reference. tsc leaves the union untouched there.
    if (!try c.isDiscriminantProp(if (c.ts.kind(decl) == .union_type) decl else t, prop))
        return t0;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    const truth_members = try c.memberList(t);
    for (truth_members) |m| {
        const rm = try c.resolveStructural(m);
        var keep = true;
        if (try c.propOfType(rm, prop)) |p| {
            if (sense) {
                // True branch: drop members whose prop is definitely falsy.
                const truthy = try c.getTruthyPart(p.ty);
                keep = truthy != types.never_type;
            } else {
                const falsy = try c.getFalsyPart(p.ty, true);
                keep = falsy != types.never_type or p.optional();
            }
        }
        if (keep) try parts.append(c.scratch(), m);
    }
    if (parts.items.len == truth_members.len) return t0;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// Is `t` a *unit* type in tsc's sense (`TypeFlags.Unit`: a literal, an enum
/// member, `unique symbol`, `null`, `undefined`)? Deliberately narrower than
/// `Store.isLiteralLike`, which also admits template-literal patterns and
/// `Uppercase<…>` string mappings — neither is a unit type.
fn isUnitLike(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .bool_true,
        .bool_false,
        .unique_symbol,
        .undefined,
        .null,
        => true,
        else => c.ts.isEnumMember(t),
    };
}

/// tsc's `isLiteralType`: `boolean` counts (it is the union of its two
/// literals), a union counts when every constituent is a unit type, and
/// anything else must be a unit type itself.
fn isLiteralTypeLike(c: *Checker, t0: TypeId) Error!bool {
    const t = try c.resolveStructural(t0);
    if (c.ts.kind(t) == .boolean) return true;
    if (c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (!isUnitLike(c, try c.resolveStructural(m))) return false;
        }
        return true;
    }
    return isUnitLike(c, t);
}

/// tsc's `isDiscriminantProperty`: a union's synthetic property qualifies as
/// a discriminant when its per-constituent types are NON-UNIFORM and at least
/// one of them is a literal/unit type (`CheckFlags.Discriminant =
/// HasNonUniformType | HasLiteralType`), and the resulting type is not
/// generic. Only such a property may narrow the *parent* reference; every
/// other property says nothing about which constituent is live, which is why
/// `if (x.someNumber)` must leave `x` alone.
///
/// A constituent that lacks the property contributes nothing (tsc records it
/// as `CheckFlags.Partial` and moves on). A property type that still mentions
/// a type parameter disqualifies the whole thing — matching tsc's
/// `!isGenericType(...)` and erring toward *less* narrowing, which can only
/// drop a diagnostic, never invent one.
pub fn isDiscriminantProp(c: *Checker, t: TypeId, prop: Atom) Error!bool {
    if (c.ts.kind(t) != .union_type) return false;
    var first: TypeId = types.no_type;
    var non_uniform = false;
    var has_literal = false;
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        const p = (try c.propOfType(rm, prop)) orelse continue;
        if (try c.containsTypeParam(p.ty)) return false;
        if (first == types.no_type) {
            first = p.ty;
        } else if (p.ty != first) {
            non_uniform = true;
        }
        if (try isLiteralTypeLike(c, p.ty)) has_literal = true;
    }
    return non_uniform and has_literal;
}

/// Is `prop` DECLARED on `rm`, for the purposes of `in`-narrowing? tsc's
/// `isTypePresencePossible` asks `getPropertyOfType`, and a still-GENERIC
/// mapped type (`Partial<Record<T, any>>` with `T` abstract) has no members
/// at all there — its key set is unknown, so it can neither confirm nor
/// supply the name. ztsc's `propOfType` synthesizes a member for any name
/// on such a type, which made every constituent of
/// `({ [ORIG_ID]?: string } | { id: string }) & Partial<Record<T, any>>`
/// look like it has `id`, so `"id" in el` filtered nothing.
pub fn propDeclaredForIn(c: *Checker, rm: TypeId, prop: Atom) Error!?types.Prop {
    switch (c.ts.kind(rm)) {
        .mapped => {
            const con = c.ts.mappedConstraint(rm);
            if (con == types.no_type or try c.containsTypeParam(con)) return null;
        },
        .intersection => {
            for (try c.memberList(rm)) |m| {
                const r = try c.resolveStructural(m);
                if (try c.propDeclaredForIn(r, prop)) |p| return p;
            }
            return null;
        },
        else => {},
    }
    return c.propOfType(rm, prop);
}

pub fn narrowByInProp(c: *Checker, t: TypeId, prop: Atom, sense: bool) Error!TypeId {
    // tsc's `narrowByInKeyword`: the filtering branch only applies when the
    // name is a *known* property — declared on some constituent, or covered
    // by one's string index signature. For an unknown name the true branch
    // is `type & Record<name, unknown>` instead, which is what makes
    //     if ("pointerType" in e && e.pointerType === "touch")   // e: MouseEvent
    // legal. The false branch of an unknown name says nothing.
    {
        const single = [_]TypeId{t};
        const members: []const TypeId = if (c.ts.kind(t) == .union_type)
            try c.memberList(t)
        else
            &single;
        var known = false;
        for (members) |m| {
            const rm = try c.resolveStructural(m);
            if ((try c.propOfType(rm, prop)) != null or
                c.ts.kind(rm) == .any or c.ts.kind(rm) == .unknown or
                (c.ts.kind(rm) == .object and c.ts.objectStringIndex(rm) != types.no_type))
            {
                known = true;
                break;
            }
        }
        if (!known) {
            if (!sense) return t;
            const rec = try c.ts.makeObject(
                &.{.{ .name = prop, .ty = types.unknown_type }},
                types.no_type,
                types.no_type,
                0,
            );
            return c.ts.makeIntersection(c.scratch(), &.{ t, rec });
        }
    }
    if (c.ts.kind(t) != .union_type) return t;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        const found = try c.propDeclaredForIn(rm, prop);
        const has = found != null;
        const optional = if (found) |p| p.optional() else false;
        const kept = if (sense) has else (!has or optional);
        if (kept) try parts.append(c.scratch(), m);
    }
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// tsc's `getInstanceType(constructorType)`: prefer the `prototype`
/// property type (when present and not `any`), else the union of the
/// construct signatures' return types. Returns `no_type` when the RHS is
/// not a usable constructor (→ no narrowing, sound under-narrowing).
pub fn instanceTypeOfConstructor(c: *Checker, rt: TypeId) Error!TypeId {
    if (try c.propOfType(rt, try c.internText("prototype"))) |p| {
        const k = c.ts.kind(p.ty);
        if (k != .any and k != .err and k != .unknown) return p.ty;
    }
    var obj = rt;
    if (c.ts.kind(obj) == .ref) obj = try c.expandRef(obj);
    if (c.ts.kind(obj) == .object) {
        const n = c.ts.objectConstructSigCount(obj);
        if (n > 0) {
            var rets: std.ArrayList(TypeId) = .empty;
            defer rets.deinit(c.scratch());
            for (0..n) |i| {
                // tsc: `getReturnTypeOfSignature(getErasedSignature(sig))` —
                // a GENERIC construct signature (`new <T>(): B<T>`) has no
                // type arguments to infer at an `instanceof`, so its own type
                // parameters collapse to `any`. Without the erasure the
                // narrowed instance kept `T` free, and `obj.foo = 1` on a
                // narrowed `B<T>` reported TS2322.
                const sig = try c.eraseParamsToAny(c.ts.objectConstructSig(obj, @intCast(i)));
                try rets.append(c.scratch(), c.ts.fnReturn(sig));
            }
            return c.ts.makeUnion(c.scratch(), rets.items);
        }
    }
    return types.no_type;
}

/// The instance type produced by `x instanceof RHS`, or `null` when the
/// RHS is not a usable constructor (→ no narrowing). A plain `class`
/// value maps to `C<any…>`. An `.intersection` of constructors is handled
/// member-wise: a `declare module` augmentation merges a class declaration
/// with itself into `typeof C & typeof C`, and mixins yield `typeof A &
/// typeof B` — in both cases the constructor is NOT a `.class_value`, so
/// without this the narrowing collapsed (`instanceTypeOfConstructor` finds
/// no `prototype`/construct sig on the intersection and gives up), leaving
/// the operand at its declared base type.
pub fn instanceofInstanceType(c: *Checker, rt: TypeId) Error!?TypeId {
    switch (c.ts.kind(rt)) {
        .class_value => {
            const cls = c.ts.classSymbol(rt);
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(cls, &tps);
            const args = try c.scratch().alloc(TypeId, tps.items.len);
            for (args) |*x| x.* = types.any_type;
            return try c.ts.makeRef(cls, args);
        },
        .intersection => {
            var insts: std.ArrayList(TypeId) = .empty;
            defer insts.deinit(c.scratch());
            for (try c.memberList(rt)) |m| {
                const mi = (try c.instanceofInstanceType(m)) orelse continue;
                var seen = false;
                for (insts.items) |e| {
                    if (e == mi) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try insts.append(c.scratch(), mi);
            }
            if (insts.items.len == 0) {
                const inst = try c.instanceTypeOfConstructor(rt);
                return if (inst == types.no_type) null else inst;
            }
            if (insts.items.len == 1) return insts.items[0];
            return try c.ts.makeIntersection(c.scratch(), insts.items);
        },
        else => {
            const inst = try c.instanceTypeOfConstructor(rt);
            return if (inst == types.no_type) null else inst;
        },
    }
}

pub fn isNullishKind(k: types.Kind) bool {
    return k == .null or k == .undefined or k == .void;
}

/// `instance` genuinely contains the nullish kind `k` — as itself, as a
/// union constituent, or because it is `any`/`unknown`. Deliberately NOT
/// an assignability question: an all-optional object is assignable FROM
/// `undefined` in ztsc's relation, and that is what this guards against.
pub fn admitsNullish(c: *Checker, instance: TypeId, k: types.Kind) Error!bool {
    const r = try c.resolveStructural(instance);
    const rk = c.ts.kind(r);
    if (rk == .any or rk == .unknown or rk == .err) return true;
    if (rk == k) return true;
    if (rk == .undefined and k == .void) return true;
    if (rk == .void and k == .undefined) return true;
    if (rk == .union_type) {
        for (0..c.ts.memberCount(r)) |i| {
            if (try c.admitsNullish(c.ts.memberAt(r, i), k)) return true;
        }
    }
    return false;
}

/// tsc's `getNarrowedType(type, candidate, assumeTrue, checkDerived)`.
/// `check_derived` marks the `instanceof` caller, whose relation is
/// `isTypeDerivedFrom` (nominal) rather than the subtype relation a type
/// predicate uses.
pub fn narrowByInstance(c: *Checker, t: TypeId, instance: TypeId, sense: bool, check_derived: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            var matches = try c.isAssignable(m, instance);
            // tsc's `getNarrowedTypeWorker` filters with the SUBTYPE
            // relation, and `undefined`/`null` are subtypes of nothing but
            // themselves. Under plain assignability a "weak" guard type —
            // an object whose properties are ALL optional, the shape of
            // every `json is Lib` validator — accepts them, so
            // `if (!isValidLibrary(data)) throw` left `undefined` in the
            // guarded branch and every later use reported TS18048.
            if (matches and isNullishKind(c.ts.kind(m)) and !try c.admitsNullish(instance, c.ts.kind(m)))
                matches = false;
            const kept = if (sense) matches else !matches;
            if (kept) try parts.append(c.scratch(), m);
        }
        const result = try c.ts.makeUnion(c.scratch(), parts.items);
        if (sense and result == types.never_type) {
            if (try c.isAssignable(instance, t)) return instance;
            // tsc's `getNarrowedTypeWorker` does not stop when no
            // constituent is directly related to the candidate: it then
            // keeps every constituent that is still INSTANTIABLE (a
            // deferred conditional, `keyof`, indexed access, or a bare type
            // parameter) and whose *constraint* the candidate is comparable
            // to — such a constituent can still be instantiated to
            // something the guard accepts, so narrowing it away is wrong.
            // `isShallowEqual`'s `comparators` is
            // `{ [k in keyof T]?: … } | (keyof T extends K[number] ? … )`,
            // and `Array.isArray(comparators)` filtered BOTH constituents
            // out, leaving `never` — so iterating the guarded value was
            // TS2488.
            for (try c.memberList(t)) |m| {
                if (!isInstantiableKind(c.ts.kind(m))) continue;
                const bc = try c.deferredDefaultConstraint(m, 0);
                if (bc == m) continue;
                if (try c.isAssignable(instance, bc)) return instance;
            }
            // tsc's tail is `getIntersectionType([type, candidate])`, and
            // for a union `type` that distributes into a union of
            // intersections — one per constituent. Most of them are
            // uninhabited (`{ type: "text" } & { type: "arrow" }`), and
            // tsc drops those in `getReducedType` before anything reads
            // the narrowed type. Doing the intersection WITHOUT that
            // reduction is what made this arm stop at `never` before: the
            // dead constituents leaked into spreads and inferred returns
            // and produced eight false TS2345s across rxjs.
            const isect = try c.ts.makeIntersection(c.scratch(), &.{ t, instance });
            return try c.reduceNeverIntersections(isect);
        }
        return result;
    }
    if (sense) {
        // tsc's `getNarrowedTypeWorker` opens with
        // `if (type.flags & AnyOrUnknown) return candidate` — an `any`
        // subject takes the guard's type outright. This has to come before
        // the assignability tests: `any` is assignable to everything, so
        // the first of them would otherwise keep `any` and drop the guard
        // (`Array.isArray(x)` on `any` never yielding `any[]`).
        const k = c.ts.kind(t);
        if (k == .any or k == .unknown or k == .err) return instance;
        // Same subtype rule as the union arm above: a guard whose type does
        // not itself admit `undefined`/`null` leaves nothing behind (tsc
        // ends at `undefined & Lib`, which is `never`).
        if (isNullishKind(k) and !try c.admitsNullish(instance, k)) return types.never_type;
        // tsc filters with the SUBTYPE relation, and a `readonly T[]` is
        // not a subtype of a mutable `U[]` — it has no `push`. The reverse
        // does hold, so `getNarrowedTypeWorker`'s second clause fires and
        // the narrowed type is the GUARD's: `Array.isArray(x)` on a
        // `readonly T[]` yields `any[]`, not `readonly T[]`. ztsc's
        // relation is deliberately readonly-blind, so both directions are
        // "assignable" here and the subject would win instead.
        if (k == .array and c.ts.arrayIsReadonly(t) and
            c.ts.kind(instance) == .array and !c.ts.arrayIsReadonly(instance))
            return instance;
        if (try c.isAssignable(t, instance)) return t;
        if (try c.isAssignable(instance, t)) return instance;
        // Unrelated `t` and guard `C`: tsc narrows to the intersection
        // `t & C` (e.g. `Array.isArray(s)` with `s: string` → `string &
        // any[]`, which carries the array members; disjoint primitives
        // reduce to `never`). Previously kept `t`, dropping the guard, so
        // `s.map(...)` in the true branch reported TS2339 on `string`.
        return c.ts.makeIntersection(c.scratch(), &.{ t, instance });
    }
    // assumeFalse on a NON-union subject. tsc does not simply keep it:
    //
    //     const trueType = getNarrowedType(type, candidate, /*assumeTrue*/ true, …);
    //     return filterType(type, t => !isTypeSubsetOf(t, trueType));
    //
    // and for a non-union subject `isTypeSubsetOf` degenerates to identity, so
    // a subject a TYPE PREDICATE narrows to ITSELF is excluded outright —
    // `never`. Keeping it made every `!guard(x)` branch of an already-narrow
    // `x` a no-op, which is what refused the TS 5.5 inferred predicate for
    // `updated.find(p => asPredicate(validate…)(p))`: its true branch is a
    // single intersection, so the soundness re-narrow could never reach
    // `never`.
    //
    // NOT for `instanceof` (`checkDerived`), whose assumeFalse arm is
    // `filterType(type, t => !isTypeDerivedFrom(t, candidate))` — a nominal
    // test that ztsc answers structurally. Two error classes that add no
    // members are structurally identical to `Error`, so the identity test
    // above would wrongly make the `else` of `e instanceof MaxHiddenRepliesError`
    // (on `e: Error`) `never`.
    if (!check_derived and try narrowByInstance(c, t, instance, true, check_derived) == t)
        return types.never_type;
    return t;
}

/// tsc's `narrowTypeByConstructor`: `x.constructor === C` keeps the
/// constituents of `x` that are COMPARABLE to `C.prototype`.
///
/// `ctor_t` is the type of the right-hand side (`typeof C`); the candidate is
/// its `prototype` property, which is what makes the guard work for a plain
/// interface-typed constructor variable as well as for a `class`. Answers `t`
/// unchanged — no narrowing — in each of tsc's bail cases:
///
///   * no `prototype` property (the comparand is not a constructor at all);
///   * `prototype: any`, which carries no information;
///   * a candidate that is exactly the global `Object` or `Function`, which
///     every object satisfies;
///
/// and, as tsc does, hands an `any` subject the candidate outright.
///
/// The caller applies this on the branch where the equality HOLDS only:
/// `x.constructor !== C` says nothing, because a subclass instance's
/// `constructor` is the subclass.
pub fn narrowByConstructorProp(c: *Checker, t: TypeId, ctor_t: TypeId) Error!TypeId {
    const proto_atom = try c.atom("prototype");
    const p = (try c.propOfType(try c.resolveStructural(ctor_t), proto_atom)) orelse return t;
    const cand = try c.resolveStructural(p.ty);
    const ck = c.ts.kind(cand);
    if (ck == .any or ck == .unknown or ck == .err) return t;
    if (try isObjectOrFunctionIface(c, cand)) return t;
    const tk = c.ts.kind(t);
    if (tk == .any or tk == .unknown or tk == .err) return cand;
    if (tk == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            if (try c.isComparable(m, cand)) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    if (try c.isComparable(t, cand)) return t;
    return types.never_type;
}

/// Is `t` exactly the global `Object` or `Function` interface — the two
/// candidates tsc refuses to narrow an `any` down to, in both the
/// `instanceof` and the `.constructor` guard (nothing is ruled out by them).
pub fn isObjectOrFunctionIface(c: *Checker, t: TypeId) Error!bool {
    if (isGlobalIface(c, t, c.atom_Object)) return true;
    return isGlobalIface(c, t, try c.atom("Function"));
}

/// Is `t` the global interface `name` names? A materialized instance still
/// names the reference it came from (`origin`), which is what `refFacetOf`
/// reads.
fn isGlobalIface(c: *Checker, t: TypeId, name: Atom) bool {
    const sym = c.prog.globals.lookup(name) orelse return false;
    const k = c.ts.kind(t);
    if (k == .ref) return sym == c.ts.refSymbol(t);
    if (c.refFacetOf(t, k)) |r| return sym == c.ts.refSymbol(r);
    return false;
}
