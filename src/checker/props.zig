//! Property lookup and type-parameter parts: what member a type has, and
//! what a type parameter's constraint/default/arity are. Functions take the
//! `Checker` context as their first parameter.
//!
//! Two concerns were split out and are re-exported below so `Checker`'s
//! method aliases keep resolving here: `iteration.zig` (promises, `await`,
//! yield types) and `nullability.zig` (the nullish/truthiness facts).

const std = @import("std");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const prof_zig = @import("prof.zig");

const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const instantiate = @import("enums.zig").instantiate;
const iteration = @import("iteration.zig");
const nullability = @import("nullability.zig");
const resolveStructural = @import("instantiate.zig").resolveStructural;

// =====================================================================
// properties & type parts
// =====================================================================

/// Property of a *structural* type (call resolveStructural first).
/// Handles objects, unions, intersections, arrays/tuples/strings
/// (`length`), and type params (via constraint).
pub fn propOfType(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
    return c.propOfTypeEx(t, name, true);
}

/// Named-property lookup. `allow_index=true` (the member-access default)
/// lets a string index signature stand in for any name — `obj.foo` on a
/// `{ [k: string]: V }` yields `V`. `allow_index=false` is the *assignability*
/// rule: a source's index signature does NOT satisfy a required *named*
/// target property (tsc reports TS2741/TS2740), so `{ [k: string]: any }` is
/// not assignable to `Date`/`{ x: number }`. Only the relation callers pass
/// false; the index signature is related separately (indexSignaturesRelatedTo).
pub fn propOfTypeEx(c: *Checker, t: TypeId, name: Atom, allow_index: bool) Error!?types.Prop {
    return propOfTypeIdx(c, t, name, .{ .allow_index = allow_index });
}

/// tsc's `getPropertyOfType(t, name, /*skipObjectFunctionPropertyAugment*/ true)`
/// — the lookup CONTEXTUAL typing runs. A property's contextual type is what
/// the target DECLARES for that name, never what the global `Function` and
/// `Object` interfaces lend every value: an object literal written against
/// `WebpackPluginInstance | ((c: Compiler) => void)` must take `apply` from the
/// interface alone, because reading `CallableFunction.apply` off the function
/// constituent puts a second, disagreeing signature into a union that
/// `contextualCallSig` then refuses outright (TS7006 on the callback).
pub fn ctxPropOfType(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
    return propOfTypeIdx(c, t, name, .{ .skip_augment = true });
}

/// What a property lookup should answer beyond the name itself.
const PropLookup = struct {
    /// `true` (the member-access default) lets a string index signature stand
    /// in for any name; see `propOfTypeEx`.
    allow_index: bool = true,
    /// Skip the apparent members every value inherits from the global
    /// `Function`/`Object` interfaces (tsc's `skipObjectFunctionPropertyAugment`).
    skip_augment: bool = false,
    /// Set when the answer came from a string INDEX SIGNATURE rather than from
    /// a declared/apparent member. Only the intersection arm asks — see there.
    from_index: ?*bool = null,
};

fn propOfTypeIdx(c: *Checker, t: TypeId, name: Atom, o: PropLookup) Error!?types.Prop {
    const allow_index = o.allow_index;
    const from_index = o.from_index;
    const s = &c.ts;
    switch (s.kind(t)) {
        .object => {
            if (s.objectPropByName(t, name)) |p| return p;
            // The global-scope object stores no properties: its members are
            // the program's merged global value declarations, resolved on
            // demand (see `globalThisType`).
            //
            // Only for MEMBER ACCESS (`allow_index`), never for the
            // structural relation. Resolving a global's type is a lazy,
            // re-entrant operation and the global table is self-referential
            // — `@types/node` declares `var AbortController: typeof
            // globalThis extends { onmessage: any; AbortController: infer T
            // } ? T : …`, whose own resolution asks the global object for
            // `AbortController`. The relation walks a target's properties
            // in stored (atom) order, and atom ids come from the parallel
            // interner, so *which* arm of that cycle is entered first moves
            // run to run: the diagnostics held but the work counters did
            // not (`_types_node` repeat sweep, 19/40 runs). Keeping the
            // relation out means `typeof globalThis` relates as the empty
            // object it stores, which is order-free by construction.
            if (allow_index and s.objectFlags(t) & types.obj_flag_global_this != 0) {
                return c.globalThisProp(name);
            }
            // A callable object/interface (one carrying call/construct
            // signatures, e.g. react-i18next `TFunction`) inherits the
            // apparent members of the global `Function` interface
            // (`.bind`/`.call`/`.apply`/`.name`/`.length`/…). Plain
            // (non-callable) objects do NOT — an absent member stays TS2339.
            if (!o.skip_augment and (s.objectCallSigCount(t) > 0 or s.objectConstructSigCount(t) > 0)) {
                if (try functionInterfaceProp(c, name)) |p| return p;
            }
            if (!allow_index) {
                // An interface whose only base is `any` and which declares
                // nothing of its own RELATES as `any` (tsc's
                // `getNormalizedType` -> `getSingleBaseForNonAugmentingSubtype`
                // swaps the reference for its single base before the relation
                // runs). Answering `any` for every name is that rule expressed
                // where the relation asks the question: `propertiesRelatedTo`
                // then finds each target property present and `any`-typed, so
                // `@types/koa`'s `DefaultState` satisfies `{ state: { auth:
                // … } }` — and satisfies `Function`, which is what makes
                // calling it legal. See `types.obj_flag_any_base` for what the
                // oracle says the rule does and does not reach. A DECLARED
                // `[k: string]: any` gets none of this and still answers null,
                // which is what keeps it TS2741 against a required property.
                if (s.objectRelatesAsAny(t)) {
                    return .{ .name = name, .ty = types.any_type, .flags = 0 };
                }
                return null;
            }
            // Every object type also has the apparent members of the global
            // `Object` interface — `hasOwnProperty`, `toString`,
            // `valueOf`, … — the tail of tsc's `getPropertyOfType`
            // (`return getPropertyOfObjectType(globalObjectType, name)`).
            // Member access only: the assignability relation asks a
            // *target*'s own property list, and `isKnownProperty` (the
            // excess-property check) deliberately does not consult the
            // global object type.
            if (!o.skip_augment) {
                if (try c.objectInterfaceProp(name)) |p| return p;
            }
            // The string index signature is the LAST resort, after the
            // apparent members — tsc's `getPropertyOfType` never consults
            // an index signature at all, and
            // `checkPropertyAccessExpression` only falls back to
            // `getApplicableIndexInfoForName` once the property lookup has
            // come back empty. Consulting it first made
            // `props.hasOwnProperty(k)` on a `{ [k: string]: ReactNode |
            // ((el) => ReactNode) }` type as the index VALUE rather than
            // as `Object.hasOwnProperty`, so calling it was TS2349.
            if (s.objectStringIndex(t) != 0) {
                if (from_index) |f| f.* = true;
                return .{ .name = name, .ty = s.objectStringIndex(t), .flags = 0 };
            }
            return null;
        },
        .union_type => {
            // tsc's `getUnionOrIntersectionProperty`: a union has a
            // property only when *every* constituent has it, and its type
            // is the union of the per-constituent types. Reached whenever a
            // union is not the top-level type of a member access — through
            // a type parameter's union constraint (`<T extends A | B>`),
            // an intersection constituent, or an apparent-member lookup.
            // Flags accumulate: optional/readonly on any constituent makes
            // the merged property optional/readonly.
            const members = try c.memberList(t);
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            var flags: u32 = 0;
            // A constituent's answer is kept so `unionPropertyDropped` can judge
            // the set as a whole (see there).
            var found: std.ArrayList(types.Prop) = .empty;
            defer found.deinit(c.scratch());
            for (members) |m| {
                const r = try c.resolveStructural(m);
                const p = (try propOfTypeIdx(c, r, name, o)) orelse return null;
                try found.append(c.scratch(), p);
                try parts.append(c.scratch(), p.ty);
                flags |= p.flags;
            }
            if (unionPropertyDropped(found.items)) return null;
            return .{ .name = name, .ty = try s.makeUnion(c.scratch(), parts.items), .flags = flags };
        },
        .intersection => {
            const members = try c.memberList(t);
            // `T & {}` (NonNullable of a type parameter): the empty-object
            // marker signals the value is non-nullish, so a type-param
            // constituent's members come from its constraint with
            // null/undefined stripped — `(T extends string | undefined) & {}`
            // exposes `string`'s members. Without the marker a bare `T`
            // resolves through its raw constraint (nullish kept).
            var has_marker = false;
            for (members) |m| {
                if (c.isEmptyObjectType(try c.resolveStructural(m))) {
                    has_marker = true;
                    break;
                }
            }
            // A sibling's INDEX SIGNATURE must not outrank a constituent's
            // declared property. tsc keeps the two steps apart:
            // `getPropertyOfType` on an intersection consults no index
            // signature at all, and only when it comes back empty does
            // `checkPropertyAccessExpression` ask for an applicable index info.
            // The `.object` arm above already orders those two for a lone
            // object, but a constituent is asked in ISOLATION, so it answers
            // from its own index before its sibling is ever consulted — and
            // `any & X` is `any`. So each constituent's answer carries its
            // provenance, and a declared one wins.
            //
            // The FREE-TYPE-PARAMETER guard is deliberate, and it is a cost
            // bound rather than a semantic one. An `any`-valued index signature
            // reaching this arm is usually ztsc's *stand-in* for a constituent
            // it could not reduce (`transitiveBaseConstraint` of a mapped type
            // whose key domain is still generic answers `{ [x: string]: any }`),
            // so preferring the sibling everywhere makes the checker
            // materialize whole regions of a library's type graph the `any`
            // used to cut off. styled-components is the case in point:
            // unguarded, the sibling also wins for the `propTypes`,
            // `defaultProps` and `withComponent` that `NonReactStatics` maps
            // over every `StyledComponent` — `WeakValidationMap`/`Partial` over
            // the full ~270-property `StyledComponentProps`, and a
            // `withComponent` whose return type is another `StyledComponent`,
            // i.e. the same expansion again. Where the declared property is
            // CONCRETE the `any` costs only precision the stand-in had already
            // given up; where it names a free parameter it costs an inference
            // candidate, which is unrecoverable. `containsFreeTypeParam` with
            // an empty scope is exactly that test — a generic METHOD's own
            // parameters are bound by its own signature and do not count.
            //
            // styled-components' polymorphic `as` is that generic case. The
            // second call signature takes `StyledComponentProps<AsC, …> & { as?:
            // AsC | undefined; … }`, whose first constituent is a conditional
            // still deferred on the free `AsC`; its default constraint bottoms
            // out in exactly such a mapped type. `as` answered `any`, so the
            // attribute-driven inference in `inferJsxTargs` had no target worth
            // a candidate, `AsC` fell back to its default `C`, and every
            // `<Styled as="p">` in the program read `Type '"p"' is not
            // assignable to type '"span" | undefined'`.
            var found: ?types.Prop = null;
            var idx_found: ?types.Prop = null;
            var all: ?types.Prop = null;
            for (members) |m| {
                const r = try c.resolveStructural(m);
                var lookup = r;
                if (has_marker and c.ts.kind(r) == .type_param) {
                    const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
                    if (con != types.no_type) {
                        lookup = try c.resolveStructural(try c.nonNullable(con));
                    }
                }
                var via_index = false;
                var sub_index = o;
                sub_index.from_index = &via_index;
                if (try propOfTypeIdx(c, lookup, name, sub_index)) |p| {
                    for ([_]*?types.Prop{ if (via_index) &idx_found else &found, &all }) |slot| {
                        if (slot.* == null) {
                            slot.* = p;
                        } else {
                            const merged = try c.ts.makeIntersection(c.scratch(), &.{ slot.*.?.ty, p.ty });
                            slot.* = .{ .name = name, .ty = merged, .flags = slot.*.?.flags & p.flags };
                        }
                    }
                }
            }
            if (found) |p| {
                if (idx_found == null or try c.containsFreeTypeParam(p.ty, &.{})) return p;
            }
            if (found == null and idx_found != null) {
                if (from_index) |f| f.* = true;
            }
            return all;
        },
        // A template-literal pattern and a string-transform intrinsic are
        // subtypes of `string` (`Store.literalBase`), so their apparent
        // members are `String`'s — `` `${number}`.split `` resolves exactly
        // like `"1".split`.
        .array, .tuple, .string, .string_literal, .template_literal_type, .string_mapping => {
            if (name == c.atom_length) {
                if (s.kind(t) == .tuple) {
                    // tsc: a tuple with no rest element has a LITERAL length
                    // — the union of every arity it admits, so `[a: number,
                    // b?: string]["length"]` is `1 | 2` and `[a?: number]`
                    // is `0 | 1`. Only a rest element makes it `number`.
                    // Collapsing an optional tuple to `number` broke every
                    // `Parameters<F>["length"] extends 0 | 1 ? … : never`
                    // arity guard: the conditional took the false branch and
                    // the parameter became `never`.
                    var has_rest = false;
                    var required: usize = 0;
                    const total = s.tupleLen(t);
                    for (0..total) |i| {
                        const e = s.tupleElem(t, @intCast(i));
                        if (e.rest()) has_rest = true;
                        if (!e.optional() and !e.rest()) required = i + 1;
                    }
                    if (!has_rest) {
                        var lens: std.ArrayList(TypeId) = .empty;
                        defer lens.deinit(c.scratch());
                        var n = required;
                        while (n <= total) : (n += 1) {
                            try lens.append(c.scratch(), try s.makeNumberLiteral(@floatFromInt(n), false));
                        }
                        return .{ .name = name, .ty = try s.makeUnion(c.scratch(), lens.items), .flags = types.prop_flag_readonly };
                    }
                }
                // `Array<T>.length` is *writable* in tsc (`arr.length = 0`
                // is idiomatic truncation); `string.length` and a fixed
                // tuple's length (above) are readonly.
                const flags: u32 = if (s.kind(t) == .array) 0 else types.prop_flag_readonly;
                return .{ .name = name, .ty = types.number_type, .flags = flags };
            }
            return primitiveInterfaceProp(c, t, name);
        },
        .number,
        .number_literal,
        .number_literal_fresh,
        .boolean,
        .bool_true,
        .bool_false,
        .bigint,
        .bigint_literal,
        .symbol,
        .unique_symbol,
        => {
            return primitiveInterfaceProp(c, t, name);
        },
        // tsc's `getApparentType(objectType)` is `globalObjectType`, so the
        // `object` KEYWORD carries the same `Object.prototype` members every
        // object type does — `constructor`, `toString`, `hasOwnProperty`, …
        // `typeof v === 'object' && v !== null && v.constructor === Object`
        // is the idiom that needs it. Member access only, like the `.object`
        // arm's own fallback.
        .object_keyword => {
            if (!allow_index) return null;
            return c.objectInterfaceProp(name);
        },
        .type_param => {
            // Walk the constraint chain iteratively — `U extends T extends
            // {…}` — instead of re-entering this arm per hop. A CIRCULAR
            // constraint (`T extends T`, or `T extends U` with `U extends T`;
            // tsc's TS2313) recursed here until the stack died. tsc's
            // `getBaseConstraintOfType` answers undefined for a circular
            // constraint — no apparent members — which is the `null` below.
            // Same fixpoint break and 8-hop chain bound as
            // `indexObjBaseConstraint` / `transitiveBaseConstraint`.
            var cur = t;
            var hops: u32 = 0;
            while (hops < 8) : (hops += 1) {
                const constraint = try c.typeParamConstraint(s.typeParamSymbol(cur));
                if (constraint == types.no_type) return null;
                const next = try c.resolveStructural(constraint);
                if (next == cur) return null;
                if (s.kind(next) != .type_param) {
                    return propOfTypeIdx(c, next, name, o);
                }
                cur = next;
            }
            return null;
        },
        .mapped => {
            // A DEFERRED homomorphic map has no members of its own, but its
            // APPARENT members are the map applied to its source's base
            // constraint — tsc resolves `x.a` inside `<T extends Base>(x:
            // Mutable<T>)` through `getBaseConstraintOfType` on the
            // modifiers type, yielding `T["a"]`. Member access only: the
            // structural relation must not invent members a still-generic
            // map does not have.
            if (!allow_index) return null;
            // …and neither may member access, when the map's KEY DOMAIN is
            // itself still generic (`mappedKeysStillGeneric`): tsc's
            // `getPropertyOfType` then has no *named* members at all — but a
            // mapped type is still an object type there, so the tail of
            // `getPropertyOfType` (`getPropertyOfObjectType(globalObjectType,
            // name)`) still supplies the apparent `Object` members. That is
            // why `collection.hasOwnProperty(v)` on the `Record<T, any>`
            // constituent of `Set<T> | readonly T[] | Record<T, any> |
            // Map<T, any>` is legal; without it every name was TS2339.
            if (try mappedKeysStillGeneric(c, t)) return c.objectInterfaceProp(name);
            if (s.mappedHomomorphic(t)) {
                const src = s.mappedSource(t);
                const bc = try c.transitiveBaseConstraint(src);
                if (bc == src) return c.objectInterfaceProp(name);
                const inst = try c.reduceMapped(
                    s.mappedKeyParam(t),
                    s.mappedConstraint(t),
                    s.mappedValue(t),
                    s.mappedAs(t),
                    bc,
                    s.mappedFlags(t),
                );
                // key set still generic
                if (s.kind(inst) == .mapped) return c.objectInterfaceProp(name);
                return propOfTypeIdx(c, inst, name, o);
            }
            // A NON-homomorphic map (`Pick`/`Omit`/`Record` applied to a
            // generic) defers on its *constraint*, not a source, so the
            // homomorphic route above cannot reach it and it exposed no
            // members at all. Its apparent type is the base constraint of
            // the whole map: `Omit<Partial<T>, "id">` with `T extends Base`
            // has apparent type `Omit<Partial<Base>, "id">`, which is what
            // tsc resolves a property access against.
            const bc = try c.transitiveBaseConstraint(t);
            if (bc == t) return c.objectInterfaceProp(name);
            const rbc = try c.resolveStructural(bc);
            // key set still generic
            if (s.kind(rbc) == .mapped) return c.objectInterfaceProp(name);
            return propOfTypeIdx(c, rbc, name, o);
        },
        // A still-deferred conditional has the apparent members of its
        // DEFAULT CONSTRAINT — tsc's `getDefaultConstraintOfConditionalType`,
        // the union of the true branch (instantiated under its own extends
        // clause) and the false branch. A property both branches declare is
        // therefore readable: `{ encryptionKey } & ([T] extends [never] ?
        // { metadata?: T } : { metadata: T })` has `metadata`. Without this
        // arm a conditional exposed nothing at all, in an intersection or
        // on its own.
        .conditional => {
            const u = try c.makeUnion2(try c.condTrueUnderExtends(t), s.condFalse(t));
            if (u == t) return null;
            return propOfTypeIdx(c, u, name, o);
        },
        .ref => return propOfTypeIdx(c, try c.resolveStructural(t), name, o),
        .class_value => return classValueProp(c, s.classSymbol(t), name, o),
        .enum_type => {
            // A value of enum type borrows its base primitive's members.
            const info = try c.enumInfo(s.enumSymbol(t));
            const base: TypeId = if (info.all_string) types.string_type else types.number_type;
            return propOfTypeIdx(c, base, name, o);
        },
        // A bare function type or overload set (arrow/normal function,
        // `(x) => y`, an overloaded signature) has the apparent members of
        // the global `Function` interface.
        .function, .overloads => return if (o.skip_augment) null else functionInterfaceProp(c, name),
        else => return null,
    }
}

/// Does this deferred mapped type's KEY DOMAIN stay generic — i.e. would
/// tsc's `resolveMappedTypeMembers` produce no members at all for it?
///
/// tsc iterates `getLowerBoundOfKeyType(constraintType)` and only makes a
/// member for a key that is usable as a property name. A key type that is
/// still a naked type parameter is neither a literal nor a valid index key,
/// so the map contributes NOTHING to a named lookup — `Record<T, any>`,
/// `Pick<Base, K>` and `{ [P in K]: … }` all report TS2339 for every name
/// until `K`/`T` is known. Only `keyof X` gets the apparent-type treatment
/// (`getIndexType(getApparentType(X))`), which is what makes the members of
/// a homomorphic `Partial<T>` visible through `T`'s constraint.
///
/// Answers "generic" only when tsc would too: anything unrecognized is
/// reported concrete, so the existing base-constraint route below still runs
/// and no name that resolves today starts failing.
fn mappedKeysStillGeneric(c: *Checker, t: TypeId) Error!bool {
    // A homomorphic map stores `X` (of `keyof X`) as its source, not the
    // `keyof` node; its key domain is exactly `keyof src`.
    if (c.ts.mappedHomomorphic(t)) return keyofStillGeneric(c, c.ts.mappedSource(t), 0);
    return keyDomainStillGeneric(c, c.ts.mappedConstraint(t), 0);
}

/// `getLowerBoundOfKeyType` on a mapped type's constraint, asked only for
/// "does this land on a concrete set of names?".
fn keyDomainStillGeneric(c: *Checker, con: TypeId, depth: u32) Error!bool {
    if (depth > 8 or con == types.no_type) return false;
    const s = &c.ts;
    const r = try c.resolveStructural(con);
    switch (s.kind(r)) {
        .keyof_op => return keyofStillGeneric(c, s.keyofOperand(r), depth + 1),
        // A naked type parameter is returned unchanged by
        // `getLowerBoundOfKeyType` — its CONSTRAINT is never consulted, so
        // `Record<T, any>` has no members even for `T extends "a" | "b"`.
        .type_param => return true,
        // A constituent with a concrete key set still contributes its names
        // (`Partial<Record<T, number> & Base>` resolves `x` through `Base`),
        // so only an all-generic union/intersection is empty.
        .union_type, .intersection => {
            for (0..s.memberCount(r)) |i| {
                if (!try keyDomainStillGeneric(c, s.memberAt(r, i), depth + 1)) return false;
            }
            return true;
        },
        // A distributive conditional is re-instantiated with the lower bound
        // of its CHECK type, so `Omit<T, "y">` — `Exclude<keyof T, "y">` —
        // resolves exactly when `keyof T` does.
        .conditional => return keyDomainStillGeneric(c, s.condCheck(r), depth + 1),
        else => return false,
    }
}

/// `getIndexType(getApparentType(t))`, asked the same way: are the keys of
/// `t` a concrete set of names?
fn keyofStillGeneric(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return false;
    const s = &c.ts;
    const r = try c.resolveStructural(t);
    switch (s.kind(r)) {
        // The apparent type of a type variable is its constraint; an
        // unconstrained `T` has no keys to speak of.
        .type_param => {
            const con = try c.typeParamConstraint(s.typeParamSymbol(r));
            if (con == types.no_type) return true;
            return keyofStillGeneric(c, con, depth + 1);
        },
        // `keyof` a mapped type IS that map's key domain — tsc's
        // `getIndexTypeForMappedType` returns its constraint. This is what
        // separates `Partial<Partial<T>>` (composes down to `keyof T`, so
        // `T`'s constraint supplies the names) from
        // `Partial<Record<T, any>>` (whose inner key domain is the naked
        // `T`, so the whole thing has no members).
        .mapped => return mappedKeysStillGeneric(c, r),
        .union_type, .intersection => {
            for (0..s.memberCount(r)) |i| {
                if (!try keyofStillGeneric(c, s.memberAt(r, i), depth + 1)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Look `name` up on the global `Function` interface — the apparent members
/// (`bind`/`call`/`apply`/`name`/`length`/`toString`/…) that tsc gives every
/// function-shaped type. Returns null when the lib has no `Function`
/// interface (`--noLib`) or the property genuinely isn't a `Function`
/// member, so a bogus member on a callable still degrades to TS2339.
fn functionInterfaceProp(c: *Checker, name: Atom) Error!?types.Prop {
    const sym = c.prog.globals.lookup(c.atom_Function) orelse return null;
    if (!c.symFlags(sym).interface) return null;
    const ref = try c.ts.makeRef(sym, &.{});
    return c.propOfType(try c.resolveStructural(ref), name);
}

/// A property read off a class's CONSTRUCTOR side (`typeof C` — the value the
/// class name denotes). Three sources, in tsc's own order:
///
///   1. the class's own `static` members, then the static side it inherits
///      through `extends` (`classStaticType`);
///   2. `prototype`, which every class declaration carries implicitly. tsc
///      synthesizes it (`getTypeOfPrototypeProperty`) as the class's INSTANCE
///      type, with `any` for each type parameter — "an instantiation of the
///      class type with type Any supplied as a type argument for each type
///      parameter", per the 1.0 spec §8.4 the compiler still cites — and marks
///      it readonly. The global `Function` interface also declares
///      `prototype`, but only as `any`, so this must come first;
///   3. the global `Function` interface, which is the apparent type of every
///      callable value and so supplies `name`, `length`, `call`, `apply`,
///      `bind`, `toString` and `Symbol.hasInstance` to a class value exactly
///      as it does to a function expression.
///
/// Source 3 is what a bare `.class_value` arm was missing: `Class.name` — the
/// idiom every DI container, test factory and log line in a Nest/Angular
/// codebase is built on — was TS2339 on every class in the program.
fn classValueProp(c: *Checker, cls: SymbolId, name: Atom, o: PropLookup) Error!?types.Prop {
    if (try c.ownStaticMemberProp(cls, name)) |p| return p;
    if (try propOfTypeIdx(c, try c.classStaticType(cls), name, o)) |p| return p;
    if (name == c.atom_prototype and name != 0) {
        var tps: std.ArrayList(checker_zig.Checker.TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(cls, &tps);
        const args = try c.scratch().alloc(TypeId, tps.items.len);
        defer c.scratch().free(args);
        @memset(args, types.any_type);
        return .{
            .name = name,
            .ty = try c.ts.makeRef(cls, args),
            .flags = types.prop_flag_readonly,
        };
    }
    if (o.skip_augment) return null;
    return functionInterfaceProp(c, name);
}

/// Look `name` up on the global `Object` interface — the
/// `Object.prototype` members (`hasOwnProperty`/`isPrototypeOf`/
/// `propertyIsEnumerable`/`toString`/`toLocaleString`/`valueOf`/
/// `constructor`) that tsc gives every object type. Returns null when the
/// lib has no `Object` interface (`--noLib`) or the name genuinely isn't
/// one of its members, so a bogus member still degrades to TS2339.
///
/// Re-entrancy: the `Object` interface's own member lookup lands back in
/// the `.object` arm that calls this, so a miss there would recurse
/// forever. The flag makes the inner lookup a plain one.
pub fn objectInterfaceProp(c: *Checker, name: Atom) Error!?types.Prop {
    if (c.in_object_iface) return null;
    const sym = c.prog.globals.lookup(c.atom_Object) orelse return null;
    if (!c.symFlags(sym).interface) return null;
    const ref = try c.ts.makeRef(sym, &.{});
    c.in_object_iface = true;
    defer c.in_object_iface = false;
    return c.propOfType(try c.resolveStructural(ref), name);
}

/// Does a union have NO property of this name even though every constituent
/// answered one? tsc's `createUnionOrIntersectionProperty` bails outright when
/// the constituents contribute DIFFERENT declarations and any one of them is
/// `private`/`protected` — "a property has a private or protected declaration in
/// one constituent, but is missing or has a different declaration in another" —
/// so `v: Public | Protected; v.member` is TS2339 rather than TS2445
/// (`conformance/types/union/unionTypePropertyAccessibility`).
///
/// tsc decides "different declaration" by SYMBOL identity, which ztsc does not
/// carry on a `Prop`. The stand-in is the pair (type, flags): identical on every
/// side exactly when the constituents inherited ONE declaration (`Base |
/// Derived`, the pattern that must keep working), different as soon as the
/// accessibility or the type disagrees. Two DISTINCT classes declaring the same
/// `protected x: string` therefore keep the property where tsc drops it — an
/// under-report, and the safe direction.
///
/// Pure, and shared: the member-ACCESS path distributes over a union itself (to
/// name the whole union in its diagnostic), so it asks this the same question
/// with the same list rather than re-deriving the rule.
pub fn unionPropertyDropped(found: []const types.Prop) bool {
    if (found.len < 2) return false;
    var non_public = false;
    var all_same = true;
    for (found) |p| {
        if (p.nonPublic()) non_public = true;
        if (p.ty != found[0].ty or p.flags != found[0].flags) all_same = false;
    }
    return non_public and !all_same;
}

/// Bridge a primitive/array/tuple to its lib interface and look
/// the property up there: `arr.map` -> `Array<T>.map`, `"x".toUpperCase`
/// -> `String.toUpperCase`, etc. Returns null when no lib is loaded or
/// the interface is missing, so member access degrades to TS2339 exactly
/// as it did lib-free.
fn primitiveInterfaceProp(c: *Checker, t: TypeId, name: Atom) Error!?types.Prop {
    const iface = (try primitiveInterfaceOf(c, t)) orelse return null;
    return c.propOfType(iface, name);
}

/// The lib interface `t` borrows its apparent members from, RESOLVED to an
/// object type: `T[]` and `[A, B]` -> `Array<…>`, `"x"` -> `String`, and so on.
/// Null when no lib is loaded, the interface is missing, or `t` is not one of
/// the bridged kinds — every caller then degrades exactly as it did lib-free.
fn primitiveInterfaceOf(c: *Checker, t: TypeId) Error!?TypeId {
    const s = &c.ts;
    var iface_atom: Atom = 0;
    var elem: TypeId = types.no_type;
    var has_elem = false;
    switch (s.kind(t)) {
        .array => {
            iface_atom = c.atom_Array;
            elem = s.arrayElem(t);
            has_elem = true;
        },
        .tuple => {
            iface_atom = c.atom_Array;
            elem = try c.tupleElementUnion(t);
            has_elem = true;
        },
        .string, .string_literal, .template_literal_type, .string_mapping => iface_atom = c.atom_String,
        .number, .number_literal, .number_literal_fresh => iface_atom = c.atom_Number,
        .boolean, .bool_true, .bool_false => iface_atom = c.atom_Boolean,
        // tsc's `getApparentType` bridges `bigint` to `globalBigIntType`, so
        // `(1n).toString(2)` and `v.toLocaleString(…)` resolve exactly as their
        // `number` counterparts do (`bigintWithoutLib`).
        .bigint, .bigint_literal => iface_atom = c.atom_BigInt,
        // `symbol` and a `unique symbol` bridge to `globalESSymbolType` the same
        // way (tsc's `getApparentType`: `esSymbolType -> globalESSymbolType`).
        // Without it `symbol` had NO apparent members at all — not
        // `description`, not `toString`, and not the `constructor` that
        // `Object` lends every other type — so a UNION with a `symbol`
        // constituent lost the property for the whole union
        // (`typeGuardConstructorPrimitiveTypes` reads `.constructor` off
        // `string | number | boolean | any[] | symbol | bigint`).
        //
        // Interned per lookup rather than cached on `Checker`: only a member
        // access whose receiver is a symbol reaches here, and one hash probe
        // against the already-interned name is cheaper than another field on
        // the hot struct.
        .symbol, .unique_symbol => iface_atom = try c.internText("Symbol"),
        else => return null,
    }
    const sym = c.prog.globals.lookup(iface_atom) orelse return null;
    if (!c.symFlags(sym).interface) return null;
    const args: []const TypeId = if (has_elem) &.{elem} else &.{};
    const ref = try s.makeRef(sym, args);
    return try c.resolveStructural(ref);
}

/// The apparent object type of an ARRAY or TUPLE — the `Array<T>` instance
/// whose members tsc's `getUnmatchedProperty` scans when such a type is the
/// TARGET of a relation. Null for anything else, and when no lib is loaded.
pub fn arrayApparentObject(c: *Checker, t: TypeId) Error!?TypeId {
    switch (c.ts.kind(t)) {
        .array, .tuple => {},
        else => return null,
    }
    const iface = (try primitiveInterfaceOf(c, t)) orelse return null;
    return if (c.ts.kind(iface) == .object) iface else null;
}

// Promises, `await`, and generator yield types live in `iteration.zig`, next
// to the `for..of` half they share a walk with; re-exported here because
// `Checker`'s method aliases and `calls.zig` name this file.
pub const asyncGeneratorYieldType = iteration.asyncGeneratorYieldType;
pub const awaitedType = iteration.awaitedType;
// Alias-only, and no caller left: kept `pub` because `Checker`'s alias block
// (which this refactor may not touch) still names it through this file.
pub const generatorYieldType = iteration.generatorYieldType;
pub const isPromiseLikeOf = iteration.isPromiseLikeOf;
pub const makePromise = iteration.makePromise;
pub const tupleElementUnion = iteration.tupleElementUnion;

/// Uninferred own-type-param value for contextual signature instantiation:
/// declared default, else constraint, else `unknown` (tsc's order).
pub fn typeParamFallback(c: *Checker, sym: SymbolId) Error!TypeId {
    const d = try c.typeParamDefault(sym);
    if (d != types.no_type) return d;
    const con = try c.typeParamConstraint(sym);
    if (con != types.no_type) return con;
    return types.unknown_type;
}

pub fn typeParamConstraint(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.isFreshTp(sym)) {
        // THE choke point: a fresh parameter's bound is substituted here, on
        // first read, and not at the mint site. See `resolveFreshBound`.
        if (c.freshTp(sym).pending_bound != types.no_type) try c.resolveFreshBound(sym);
        if (c.prof.on) prof_zig.noteFreshBoundRead(c, sym);
        return c.freshTp(sym).constraint;
    }
    if (c.inst_cache_on) {
        if (c.tp_constraint_cache.get(sym)) |t| return t;
    }
    // The memo is written on the way OUT, so it cannot break a constraint that
    // reads back through its own parameter (`<T extends Foo | T["hello"]>`,
    // tsc's TS2313): the re-entry arrives before there is anything to answer
    // with. tsc's `pushTypeResolution(tp, Constraint)` — a parameter already
    // being resolved has no constraint yet, and `no_type` is that answer. Not
    // memoized: it is a property of this circle, not of the parameter.
    if (std.mem.indexOfScalar(SymbolId, c.tp_constraint_stack.items, sym) != null) {
        return types.no_type;
    }
    try c.tp_constraint_stack.append(c.cm(), sym);
    defer _ = c.tp_constraint_stack.pop();
    const result = try typeParamConstraintUncached(c, sym);
    if (c.inst_cache_on) try c.tp_constraint_cache.put(c.cm(), sym, result);
    return result;
}

fn typeParamConstraintUncached(c: *Checker, sym: SymbolId) Error!TypeId {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    const decls = c.declsOf(sym);
    for (decls) |decl| {
        if (c.nodeTag(decl) != .type_param) continue;
        const d = c.tree.nodeData(decl);
        if (d.lhs == 0) return types.no_type;
        c.cur_scope = c.symScope(sym);
        return c.typeFromTypeNode(d.lhs);
    }
    return types.no_type;
}

/// The default type of a type parameter (`<T = D>`), evaluated in its
/// declaring file + declaration scope, or `no_type` if it has none. The
/// result references earlier type-params as their type-param types; a
/// caller wanting `B = A` to see the supplied `A` must instantiate the
/// result under the mapping resolved so far.
pub fn typeParamDefault(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.isFreshTp(sym)) return c.freshTp(sym).default;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .type_param) continue;
        const d = c.tree.nodeData(decl);
        if (d.rhs == 0) return types.no_type;
        c.cur_scope = c.symScope(sym);
        return c.typeFromTypeNode(d.rhs);
    }
    return types.no_type;
}

/// Whether a type parameter declares a default (`<T = D>`).
pub fn typeParamHasDefault(c: *Checker, sym: SymbolId) bool {
    if (c.isFreshTp(sym)) return c.freshTp(sym).has_default;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .type_param) continue;
        return c.tree.nodeData(decl).rhs != 0;
    }
    return false;
}

/// Minimum required type-argument count for a signature: type params up to
/// the first defaulted one (defaults are trailing-only, so this is the
/// count of params without a default).
pub fn sigMinTargs(c: *Checker, tps: []const u32) usize {
    var min: usize = 0;
    for (tps) |tp| {
        if (!c.typeParamHasDefault(tp)) min += 1;
    }
    return min;
}

/// Whether `n` explicit type arguments satisfy a signature's arity given
/// defaults: `min <= n <= tps.len`.
pub fn sigTargArityOk(c: *Checker, sig: TypeId, n: usize) bool {
    const tps = c.ts.fnTypeParams(sig);
    if (n > tps.len) return false;
    return n >= c.sigMinTargs(tps);
}

// Nullish/truthiness facts live in `nullability.zig`; re-exported here
// because `Checker`'s method aliases name this file.
pub const canBeFalsy = nullability.canBeFalsy;
pub const canBeNullish = nullability.canBeNullish;
pub const containsNull = nullability.containsNull;
pub const containsNullish = nullability.containsNullish;
pub const containsUndefinedish = nullability.containsUndefinedish;
pub const filterUnion = nullability.filterUnion;
pub const getFalsyPart = nullability.getFalsyPart;
pub const getTruthyPart = nullability.getTruthyPart;
pub const isZeroBigInt = nullability.isZeroBigInt;
pub const nonNullable = nullability.nonNullable;
pub const nonNullableChain = nullability.nonNullableChain;
pub const nonNullableNullish = nullability.nonNullableNullish;
pub const removeUndefined = nullability.removeUndefined;
pub const unionAnyMember = nullability.unionAnyMember;
