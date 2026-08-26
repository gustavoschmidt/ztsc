//! Mapped types — `{ [K in C as A]: V }`: building one from syntax, deciding
//! per evaluation whether to defer (key set still generic) or materialize it,
//! the homomorphic (`[K in keyof T]`) source walks that carry a source's
//! props/index signatures/modifiers through, substitution of the key binder,
//! and indexed access `T[K]`.
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = @import("../intern.zig").Atom;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_instantiation_depth = checker_zig.max_instantiation_depth;

const EnumMemberCollect = @import("enums.zig").EnumMemberCollect;
const symbolKeyAtom = @import("keyof.zig").symbolKeyAtom;

/// A homomorphic map whose source variable is DECLARED with an all-array /
/// all-tuple constraint, so that instantiating it with `any` yields an ARRAY
/// rather than an index-signatured object — tsc's `instantiateMappedType`:
///
/// ```ts
/// if (isArrayType(t) || t.flags & TypeFlags.Any && … &&
///     (constraint = getConstraintOfTypeParameter(typeVariable)) &&
///     everyType(constraint, isArrayOrTupleType)) {
///     return instantiateMappedArrayType(t, type, …);
/// }
/// ```
///
/// A property of the map AS WRITTEN, not of whatever it is instantiated with:
/// `getHomomorphicTypeVariable` reads the declared `keyof T`, so
/// `Objectish<T> = { [K in keyof T]: T[K] }` stays object-flavoured even when
/// reached through `IndirectArrayish<U extends unknown[]> = Objectish<U>`
/// (`mappedTypeWithAny` pins exactly that). It is therefore recorded once, in
/// `mappedTypeFromNode`, and only carried through instantiation — never
/// recomputed from a substituted source.
///
/// Kept here rather than beside the syntactic `mapped_flag_*` bits in
/// `ast.zig`: the parser cannot know it, and neither can anything outside this
/// file, which is the only reader.
const mapped_flag_any_is_array: u32 = 32;

/// Does a homomorphic map over `src` turn an `any` instantiation into an
/// array? True exactly when `src` is a type parameter whose constraint is
/// present and is (a union of) array/tuple types.
fn anyMapsToArray(c: *Checker, src: TypeId) Error!bool {
    if (src == 0 or c.ts.kind(src) != .type_param) return false;
    const con = try c.typeParamConstraint(c.ts.typeParamSymbol(src));
    if (con == types.no_type) return false;
    const rc = try c.resolveStructural(con);
    if (c.ts.kind(rc) == .union_type) {
        for (try c.memberList(rc)) |m| {
            const rm = try c.resolveStructural(m);
            if (c.ts.kind(rm) != .array and c.ts.kind(rm) != .tuple) return false;
        }
        return true;
    }
    return c.ts.kind(rc) == .array or c.ts.kind(rc) == .tuple;
}

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
        if (try anyMapsToArray(c, src_type)) flags |= mapped_flag_any_is_array;
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
    // …and while `keyof src` only LOOKS concrete because it distributed. The
    // test above reads the key set, which is the right thing to read for an
    // object source; for a UNION or INTERSECTION source it is not, because
    // `keyof` distributes across one — `keyof (A | B)` is `keyof A & keyof B`,
    // `keyof (A & B)` is `keyof A | keyof B` — and the distribution can drop
    // every mention of the free parameter the source still carries.
    //
    //     type Gen<T extends ABC> = { v: T } &
    //         ({ v: ABC.A, a: string } | { v: ABC.B, b: string })
    //     type Gen2<T extends ABC> = { [P in keyof Gen<T>]: string }
    //
    // (`mappedTypeNotMistakenlyHomomorphic`): `keyof Gen<T>` collapses to the
    // one key both arms share, `"v"`, so the map materialized AT DECLARATION
    // against a source that is still a union — distributing into
    // `{ v; a } | { v; b }` and freezing both arms before `T` could pick one.
    // Each `Gen2<ABC.A>` / `Gen2<ABC.B>` then instantiated that frozen union,
    // and the two came out mutually assignable, so the pair of TS2741s tsc
    // reports for `a = b; b = a;` went missing. tsc never gets here: its
    // deferral test is `isGenericIndexType(constraintType)` on the WRITTEN
    // `keyof Gen<T>`, which is generic whatever `keyof` would distribute to.
    //
    // Scoped to a union/intersection source, which is the only shape `keyof`
    // distributes over. An OBJECT source whose free params live in its VALUES
    // must still materialize — that is the case the key-set test exists for
    // (react-hook-form's `Partial<Impl<T>>`, see above).
    const key_generic = try c.containsFreeTypeParam(key_src, &.{}) or
        try c.containsInfer(key_src) or
        try c.containsMappedParam(key_src) or
        (homomorphic and try distributedKeyofHidGeneric(c, src_type));
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

/// Did `keyof src` hide a free type parameter by DISTRIBUTING over `src`? True
/// for a union or intersection source that still mentions one — see the
/// `key_generic` comment for the shape and for why no other source kind counts.
fn distributedKeyofHidGeneric(c: *Checker, src_type: TypeId) Error!bool {
    if (src_type == 0) return false;
    const r = try c.resolveStructural(src_type);
    return switch (c.ts.kind(r)) {
        .union_type, .intersection => c.containsFreeTypeParam(r, &.{}),
        else => false,
    };
}

pub fn applyPropModifiers(base: u32, flags: u32) u32 {
    // tsc's `resolveMappedTypeMembers` makes a fresh `SymbolFlags.Property`
    // symbol per key, so a mapped type's members are all spreadable even where
    // the source's were class-declared methods (`prop_flag_class_fn`).
    var f = base & ~types.prop_flag_class_fn;
    if (flags & types.mapped_flag_readonly_add != 0) f |= types.prop_flag_readonly;
    if (flags & types.mapped_flag_readonly_remove != 0) f &= ~types.prop_flag_readonly;
    if (flags & types.mapped_flag_optional_add != 0) f |= types.prop_flag_optional;
    if (flags & types.mapped_flag_optional_remove != 0) f &= ~types.prop_flag_optional;
    return f;
}

/// tsc's `CheckFlags.StripOptional` (`getTypeOfMappedSymbol`'s
/// `removeMissingOrUndefinedType(propType)`): a mapped type that REMOVES
/// optionality (`-?`) from a source property that WAS optional also removes
/// `undefined` from that property's type — `Required<{a?: X}>` is `{a: X}`,
/// and `Required<{a?: X | undefined}>` is `{a: X}` too.
///
/// ztsc normally keeps `| undefined` out of a stored property type and unions
/// it in at read time from `prop_flag_optional`, so for a source whose props
/// are declared directly the flag clear in `applyPropModifiers` is already
/// enough. It is NOT enough once the source is itself a materialized mapped
/// type: a NON-homomorphic map (`Pick`, `Omit`) computes its value through
/// `T[K]`, which bakes the `| undefined` into the stored type, so
/// `Required<Pick<P, "image">>` came out `{ image: X | undefined }` — flag
/// cleared, undefined still there. social-app's `EditImageInner`, whose
/// parameter is `Required<Pick<EditImageDialogProps, 'image'>> & Omit<…>`,
/// then reported TS18048 on every `image.…` read.
///
/// Gated on the SOURCE property being optional, exactly as tsc gates
/// `StripOptional` on `symbol.flags & SymbolFlags.Optional`: a REQUIRED
/// property declared `a: X | undefined` keeps its `undefined` under `-?`.
fn stripMappedOptional(c: *Checker, pt: TypeId, base: u32, flags: u32) Error!TypeId {
    if (flags & types.mapped_flag_optional_remove == 0) return pt;
    if (base & types.prop_flag_optional == 0) return pt;
    return c.removeUndefined(pt);
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
    // tsc builds a mapped type's members lazily; ztsc builds them here. See
    // `Checker.mapped_value_depth` for the one thing that depends on the
    // difference.
    c.mapped_value_depth += 1;
    defer c.mapped_value_depth -= 1;
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
            .err => return types.any_type,
            // A homomorphic map over `any` is NOT `any`. tsc's
            // `instantiateMappedType` sends `any` down the materializing arm
            // (`AnyOrUnknown` is on the positive side of its test), so the map
            // is resolved with the key set `keyof any` —
            // `string | number | symbol` — and comes out as index signatures:
            // `Own<any>` for `{ [P in keyof T]: number }` is
            // `{ [x: string]: number; [x: number]: number }`, `Partial<any>` is
            // `{ [x: string]: any }`. Collapsing to `any` erased every check
            // through such a type — `const b: boolean = partialOfAny` passed,
            // and `{ [P in keyof any]: TakeString }` offered an object literal
            // no contextual property type at all, so its callback parameters
            // went implicit-`any` (`mappedTypeContextualTypesApplied`).
            //
            // Built here rather than by re-entering the non-homomorphic tail
            // with `keyof any` as the constraint: that tail would rediscover
            // the same two index keys through `collectMappedKeys` and set up
            // the modifiers-type and name-type machinery none of them use, and
            // this arm is hot enough for that to show (drizzle). The value
            // template has already had the source substituted, so a `T[P]`
            // template reads `any[P]` and answers `any` per key, as it must.
            // `symbol` is dropped for the same reason the tail drops it: ztsc
            // has no symbol index signature.
            //
            // …unless the map's source variable was DECLARED with an
            // array/tuple constraint, in which case tsc keeps the result a
            // LIST (`mapped_flag_any_is_array`): `Promise.all`'s
            // `{ -readonly [P in keyof T]: Awaited<T[P]> }` over
            // `T extends readonly unknown[]` handed `any` must still be an
            // array, or `Promise.all(anything as any)` reports a false TS2740
            // for the missing `length`/`pop`/… . Routed through the `.array`
            // arm below by handing it an `any[]` source, which is exactly
            // tsc's `instantiateMappedArrayType(t, …)`: the element is the
            // value template with the key bound to `number`, and `any` is
            // never a `readonly` array so only `+readonly` can make one.
            .any => {
                if (flags & mapped_flag_any_is_array != 0) {
                    return c.materializeMapped(key_param, constraint, value, as_clause, try s.makeArray(types.any_type), flags);
                }
                // An `as` clause computes each property's NAME from its key,
                // and neither `string` nor `number` is a key it can name — the
                // non-homomorphic tail drops such a key outright, so the map
                // has no members at all.
                if (as_clause != 0) return types.empty_object_type;
                const sidx = try c.substMappedKey(value, key_id, types.string_type);
                const nidx = try c.substMappedKey(value, key_id, types.number_type);
                var obj_flags: u32 = types.obj_flag_mapped_keys;
                if (flags & types.mapped_flag_readonly_add != 0) {
                    obj_flags |= types.obj_flag_readonly_string_index | types.obj_flag_readonly_number_index;
                }
                return s.makeObject(&.{}, sidx, nidx, obj_flags);
            },
            // `{ [P in keyof T]: … }` over a CLASS STATIC SIDE / namespace value
            // (`typeof C`). `.class_value` is a nominal shortcut that carries no
            // properties of its own — every reader materializes them through
            // `classStaticType` (`propOfTypeEx`, and `keyofType`'s own
            // `.class_value` arm) — so it fell to the `else` below and the whole
            // map collapsed to `{}` while `keyof typeof C` still answered the
            // full static key set. Map the static object instead: same key set
            // `keyof src`, so the two stay in agreement.
            //
            // Construct signatures are deliberately not carried: tsc's
            // `keyof typeof C` covers the static properties only, and a mapped
            // type never reproduces call/construct signatures.
            //
            // sequelize is built on this idiom — `NonConstructorKeys<T> = { [P
            // in keyof T]: T[P] extends new () => any ? never : P }[keyof T]`,
            // `ModelStatic<M> = Pick<typeof Model, NonConstructorKeys<typeof
            // Model>> & { new (): M }`. With the map empty, `NonConstructorKeys`
            // indexed a `{}` and answered `unknown`, `Pick<T, unknown>` gave
            // `{}`, and `ModelStatic<M>` degenerated to exactly `{ new (): M }`:
            // every `Model.findAll`/`.findOne`/`.scope(…)` on outline's models
            // was a TS2339, and the argument checks tsc does report at those
            // same calls went missing.
            .class_value => {
                const statics = try c.classStaticType(s.classSymbol(src));
                // Self-referential (`classStaticType` handed back the value
                // type itself): no members to map.
                if (statics == src) return types.empty_object_type;
                return c.materializeMapped(key_param, constraint, value, as_clause, statics, flags);
            },
            .array => {
                // A homomorphic map over an array yields an array; the
                // element is the value with `K` bound to the number index.
                //
                // tsc guards this shortcut (and the tuple one below) with
                // `if (!type.declaration.nameType)`: an `as` clause may DELETE
                // a position, and the result is then an ordinary object.
                // `{ [K in keyof number[] as Exclude<K, "length">]: … }` has
                // every `Array<number>` member EXCEPT `length`, which is why
                // tsc refuses it as a `number[]`
                // (`mappedTypeWithAsClauseAndLateBoundProperty`, an
                // under-report here). Mapping the apparent object instead was
                // tried and reverted: ztsc's ARRAY TARGET is nominal (a
                // non-list source is refused outright — see the `.array` arm of
                // `isAssignableInner`), so the UN-filtered spelling `as K`,
                // which tsc still spends as a list, became a false TS2345
                // (`mappedTypeWithNameClauseAppliedToArrayType`). Trading a
                // false positive for an under-report is the wrong direction;
                // the object form needs a structural array target first — and
                // then also needs the index signature tsc rebuilds from the
                // `number` key, which the `as_clause == 0` guard below drops.
                const elem = try c.substMappedKey(value, key_id, types.number_type);
                // `+readonly` makes it a `readonly T[]` and `-readonly` a
                // mutable one, exactly as for the tuple arm below
                // (`Readonly<number[]>` IS `readonly number[]`, which the
                // readonly screen then refuses to spend as a `number[]`).
                var ro = s.arrayIsReadonly(src);
                if (flags & types.mapped_flag_readonly_add != 0) ro = true;
                if (flags & types.mapped_flag_readonly_remove != 0) ro = false;
                return if (ro) s.makeArrayReadonly(elem) else s.makeArray(elem);
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
                // tsc's `instantiateMappedTupleType` newReadonly: `+readonly`
                // sets it, `-readonly` clears it, and anything else inherits
                // the source tuple's own modifier.
                var tf = s.tupleFlags(src);
                if (flags & types.mapped_flag_readonly_add != 0) tf |= types.tuple_flag_readonly;
                if (flags & types.mapped_flag_readonly_remove != 0) tf &= ~types.tuple_flag_readonly;
                return s.makeTupleFlags(elems.items, tf);
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
                    // An ARRAY constituent has its own homomorphic arm right
                    // above (`Mutable<readonly A[]>` is `A[]`), so distributing
                    // over it is exactly tsc's `mapType` and the recursion
                    // below already answers correctly. Without it a single
                    // array constituent sank the whole map to `{}`:
                    // excalidraw's `Mutable<NonNullable<readonly BoundElement[]
                    // | readonly { id; type }[] | null>>` — the two spellings a
                    // recursive alias leaves behind, one lazy `.ref` and one
                    // materialization — came back `{}`, so `.push` did not
                    // exist on it and the result was not assignable back to the
                    // union it was mapped from (restore.ts:404/417,
                    // newElement.ts:749/756).
                    //
                    // TUPLE constituents are deliberately NOT included, even
                    // though the arm above handles one. `compiler/mappedType
                    // UnionConstrainTupleTreatedAsArrayLike.ts` pins it: the
                    // map's source there is a still-GENERIC `T extends [number]
                    // | [string]`, so distributing reduces a type that must
                    // stay deferred and four TS2352 follow at the casts. An
                    // array constituent cannot be reached that way — the
                    // measured case is a materialized union, not a type
                    // parameter's constraint.
                    const ok = s.kind(rm) == .intersection or
                        s.kind(rm) == .array or
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
                    // The map's own `+readonly`/`-readonly` does NOT reach the
                    // array-ish half: it applies to the mapped PROPERTIES, and
                    // tsc's result here is an anonymous object whose member set
                    // is `keyof src` — computed on the source constituent as
                    // written. A `readonly` list in ztsc is a list whose member
                    // table is `ReadonlyArray`'s (no `push`), which is exactly
                    // what the relation reads, so the modifier that decides it
                    // is the CONSTITUENT's own, not the map's:
                    //   * `Readonly<[number, number] & Brand>` keeps `keyof
                    //     [number, number]` — `push` and friends included — so
                    //     tsc still spends it as a `[number, number]`
                    //     (excalidraw's `Readonly<GlobalPoint>` parameters,
                    //     5 false TS2345/TS2352 when the map made it readonly);
                    //   * `Mutable<readonly [number, number] & Brand>` keeps
                    //     `keyof readonly [number, number]` — no `push` — so
                    //     tsc refuses it as a `[number, number]`, which
                    //     honouring `-readonly` here would have accepted.
                    // The write site pays for the approximation: tsc reports
                    // TS2540 for `p[0] = …` through a `Readonly<Tup & Brand>`
                    // and ztsc does not (it did not before readonly lists
                    // existed either) — an under-report, not a false positive.
                    const arr_flags = flags & ~(types.mapped_flag_readonly_add | types.mapped_flag_readonly_remove);
                    for (imembers) |m| {
                        const rm = try c.resolveStructural(m);
                        if (s.kind(rm) != .array and s.kind(rm) != .tuple) continue;
                        try arrayish.append(c.scratch(), try c.materializeMapped(key_param, constraint, value, as_clause, rm, arr_flags));
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
                    const pt = try stripMappedOptional(c, try c.substMappedKey(value, key_id, key_lit), p.flags, flags);
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
                // `readonly` on the resulting signatures: the source's own,
                // then the map's `+readonly`/`-readonly` on top — the same
                // composition `applyPropModifiers` performs for named props.
                var sindex_ro = false;
                var nindex_ro = false;
                if (as_clause == 0) {
                    const src_index = try c.collectHomoIndex(src);
                    sindex_ro = src_index.string_readonly;
                    nindex_ro = src_index.number_readonly;
                    if (flags & types.mapped_flag_readonly_add != 0) {
                        sindex_ro = true;
                        nindex_ro = true;
                    }
                    if (flags & types.mapped_flag_readonly_remove != 0) {
                        sindex_ro = false;
                        nindex_ro = false;
                    }
                    if (src_index.string != 0) {
                        var v = try c.substMappedKey(value, key_id, types.string_type);
                        if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                        sindex = v;
                    }
                    if (src_index.number != 0) {
                        var v = try c.substMappedKey(value, key_id, types.number_type);
                        if (flags & types.mapped_flag_optional_add != 0) v = try c.makeUnion2(v, types.undefined_type);
                        nindex = v;
                    }
                }
                const empty = props.items.len == 0 and sindex == 0 and nindex == 0;
                // A homomorphic map's key set is `keyof src`, so whether its
                // index signatures ARE that key set is exactly whether the
                // source's were (see `obj_flag_mapped_keys`): a map over
                // `Record<string, V>` keeps the flag, a map over a written
                // `{ [k: string]: V }` keeps the `string | number` widening.
                var obj_flags: u32 = if ((sindex != 0 or nindex != 0) and
                    s.kind(src) == .object and
                    s.objectFlags(src) & types.obj_flag_mapped_keys != 0)
                    types.obj_flag_mapped_keys
                else
                    0;
                if (sindex_ro and sindex != 0) obj_flags |= types.obj_flag_readonly_string_index;
                if (nindex_ro and nindex != 0) obj_flags |= types.obj_flag_readonly_number_index;
                if (arrayish.items.len == 0) {
                    const mapped = try c.objectFromPropsFlags(props.items, sindex, nindex, obj_flags);
                    // An enum-keyed member is NAMED by the enum only in a side
                    // table (see `carryKeyNameTypes`), so a homomorphic map
                    // over such a source — `Partial<Record<E, V>>` — has to
                    // bring the names across or `keyof` loses the enum. Only
                    // an un-remapped map keeps the key: an `as` clause names
                    // the property itself.
                    if (as_clause == 0) {
                        // `carryKeyNameTypes` reads the side table by OBJECT
                        // id, so an INTERSECTION source has to be handed its
                        // constituents — the same flattening `collectHomoProps`
                        // did to reach their members. `PartMappings =
                        // Omit<M, "foo"> & Partial<Pick<M, "foo">>` is that
                        // shape, and handing it the intersection carried
                        // nothing: a numeric key `42` came out of the map named
                        // `"42"`.
                        var srcs: std.ArrayList(TypeId) = .empty;
                        defer srcs.deinit(c.scratch());
                        try collectHomoSources(c, src, &srcs);
                        try c.carryKeyNameTypes(mapped, srcs.items);
                    }
                    return mapped;
                }
                if (!empty) try arrayish.append(c.scratch(), try c.objectFromPropsFlags(props.items, sindex, nindex, obj_flags));
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
    // Which property slot each ENUM-MEMBER key landed in, and the key type it
    // was instantiated with — the state the `.enum_type` arm's duplicate-name
    // merge needs (see there). Only that arm can collide, so only that arm
    // records anything here.
    var enum_keys: std.ArrayList(struct { name: Atom, slot: usize, key: TypeId }) = .empty;
    defer enum_keys.deinit(c.scratch());
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
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, name, false)) |sp| base = sp.flags & mod_mask;
                }
                // Two enum MEMBERS can share a VALUE, and the property is named
                // by the value — so `[V in TerrestrialAnimalTypes |
                // AlienAnimalTypes]` reaches the name `cat` twice, once per
                // enum's `CAT`. tsc's `addMemberForKeyType` merges the second
                // into the first by UNIONING the key types and instantiating
                // the template once:
                //
                // ```ts
                // if (existingProp) {
                //     existingProp.links.nameType = getUnionType([existingProp.links.nameType!, keyType]);
                //     existingProp.links.keyType = getUnionType([existingProp.links.keyType, keyType]);
                // }
                // ```
                //
                // Letting the second key simply overwrite the first (what
                // `objectFromProps`' later-wins dedup does) instantiates the
                // template with ONE of the two members, and a template that
                // reads the key — `Extract<Cats, { type: V }>[]`, issue #37859's
                // `CatMap` — then admits only that enum's cat: the object
                // literal's other element was a false TS2322. Unioning first
                // gives `Extract<Cats, { type: T.CAT | A.CAT }>[]`, which is
                // what the value must be for both to fit.
                //
                // The scan is linear in the props built so far and lives in
                // this arm alone: every other key kind names its property after
                // a distinct literal, so no two of them can collide.
                var key_ty = key_lit;
                var dup: ?usize = null;
                for (enum_keys.items) |*e| {
                    if (e.name != name) continue;
                    dup = e.slot;
                    key_ty = try c.makeUnion2(e.key, key_lit);
                    e.key = key_ty;
                    break;
                }
                const pt = try stripMappedOptional(c, try c.substMappedKey(value, key_id, key_ty), base, flags);
                const prop: types.Prop = .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) };
                if (dup) |i| {
                    props.items[i] = prop;
                } else {
                    try enum_keys.append(c.scratch(), .{ .name = name, .slot = props.items.len, .key = key_ty });
                    try props.append(c.scratch(), prop);
                }
                if (as_clause == 0) {
                    // `keyof` of the result answers with the same union.
                    var nt_dup = false;
                    for (name_types.items) |*nt| {
                        if (nt.name != name) continue;
                        nt.ty = key_ty;
                        nt_dup = true;
                        break;
                    }
                    if (!nt_dup) try name_types.append(c.scratch(), .{ .name = name, .ty = key_ty });
                }
            },
            // A SYMBOL-named key (`{ [P in keyof I]: … }` over an interface
            // with a `[s]: …` member). The property is stored under the
            // synthetic atom that names the symbol, exactly as the source
            // table stores it — `symbolKeyAtom` is the inverse of the
            // `keyof` side's `memberKeyKind`, so the round trip is
            // lossless and no `key_name_types` entry is needed: `keyof` of
            // the RESULT decodes the atom back to the same symbol.
            //
            // Without this arm the key fell to the catch-all below and the
            // member was dropped outright, so `Readonly<I>`, `Partial<I>`
            // and every homomorphic map silently lost its symbol-named
            // members the moment `keyof` stopped calling them strings.
            .unique_symbol => {
                const kname = (try symbolKeyAtom(c, key_lit)) orelse continue;
                const name = if (as_clause == 0)
                    kname
                else
                    (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, kname, false)) |sp| base = sp.flags & mod_mask;
                }
                const pt = try stripMappedOptional(c, try c.substMappedKey(value, key_id, key_lit), base, flags);
                try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) });
            },
            .string_literal => {
                const name = (try c.remapKey(as_clause, key_id, key_lit)) orelse continue;
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, s.literalAtom(key_lit), false)) |sp| base = sp.flags & mod_mask;
                }
                const pt = try stripMappedOptional(c, try c.substMappedKey(value, key_id, key_lit), base, flags);
                try props.append(c.scratch(), .{ .name = name, .ty = pt, .flags = applyPropModifiers(base, flags) });
            },
            .number_literal, .number_literal_fresh => {
                const nm = try c.numberLiteralAtom(key_lit);
                var base: u32 = 0;
                if (mod_src != 0) {
                    if (try c.propOfTypeEx(mod_src, nm, false)) |sp| base = sp.flags & mod_mask;
                }
                const pt = try stripMappedOptional(c, try c.substMappedKey(value, key_id, key_lit), base, flags);
                try props.append(c.scratch(), .{ .name = nm, .ty = pt, .flags = applyPropModifiers(base, flags) });
                // The member is KEYED by the digits, but it is NAMED by the
                // number — tsc's `addMemberForKeyType` stores the key type as
                // `links.nameType`, and `getLiteralTypeFromProperty` reads it
                // back. Without the entry `keyof` re-mints the atom as a STRING
                // literal, so `keyof Omit<{ 42: string }, "x">` came back
                // `"42"` where `keyof { 42: string }` (which typenode.zig does
                // record) is `42` — the two disagree, and a `K extends keyof
                // typeof mapper` argument then failed a `(typeof arr)[number]`
                // constraint whose numeric member it does contain
                // (`mappedTypeIndexedAccessConstraint` 57/60).
                if (as_clause == 0) {
                    try name_types.append(c.scratch(), .{ .name = nm, .ty = try s.regularLiteral(key_lit) });
                }
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
    // The index signatures here came out of the map's own key set — a `string`
    // or `number` member of the constraint — so `keyof` must report exactly
    // that set (see `obj_flag_mapped_keys`).
    var obj_flags: u32 = if (sindex != 0 or nindex != 0) types.obj_flag_mapped_keys else 0;
    // `{ readonly [K in string]: V }` / `Readonly<Record<string, V>>`: the
    // map's own `readonly` modifier lands on the INDEX SIGNATURE it produces,
    // exactly as it lands on a named property (tsc's `addMemberForKeyType`
    // builds the index info with `isReadonly` from the modifiers). There is no
    // source signature to remove it from on this path, so only `+readonly`
    // matters.
    if (flags & types.mapped_flag_readonly_add != 0) {
        if (sindex != 0) obj_flags |= types.obj_flag_readonly_string_index;
        if (nindex != 0) obj_flags |= types.obj_flag_readonly_number_index;
    }
    const obj = try s.makeObject(props.items, sindex, nindex, obj_flags);
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
        // A class static side / namespace value (`typeof C`) reached as an
        // INTERSECTION constituent (`{ [P in keyof (typeof C & X)]: … }`). The
        // bare-source case is handled in `materializeMapped`'s own
        // `.class_value` arm; here the statics have to be collected, or
        // `keyof` (whose `.intersection` arm does include them) and the map
        // would disagree about the key set.
        .class_value => {
            const statics = try c.classStaticType(c.ts.classSymbol(r));
            if (statics != r) try c.collectHomoProps(statics, out);
        },
        else => {},
    }
}

/// The OBJECT tables a homomorphic map's source contributes members from —
/// itself, or an intersection's constituents. Mirrors `collectHomoProps`'
/// flattening; `carryKeyNameTypes` needs the tables themselves rather than
/// their props, because the `key_name_types` side table is keyed by object id.
fn collectHomoSources(c: *Checker, t: TypeId, out: *std.ArrayList(TypeId)) Error!void {
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => try out.append(c.scratch(), r),
        .intersection => for (try c.memberList(r)) |m| try collectHomoSources(c, m, out),
        else => {},
    }
}

/// The value types of a homomorphic mapped source's index signatures; `0`
/// for a signature the source does not have.
pub const HomoIndex = struct {
    string: TypeId = 0,
    number: TypeId = 0,
    /// `readonly` on the signature that filled the slot above — the map's own
    /// `+readonly`/`-readonly` applies on top of it, as it does for a named
    /// property's flags.
    string_readonly: bool = false,
    number_readonly: bool = false,
};

/// Collect the string/number index-signature value types of a homomorphic
/// mapped source (object, or an intersection of objects). First constituent
/// with a given signature wins — intersection index-value merging is a rare
/// edge left to the source shape. Used so a homomorphic map preserves index
/// signatures.
pub fn collectHomoIndex(c: *Checker, t: TypeId) Error!HomoIndex {
    var found: HomoIndex = .{};
    try collectHomoIndexInto(c, t, &found);
    return found;
}

fn collectHomoIndexInto(c: *Checker, t: TypeId, found: *HomoIndex) Error!void {
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => {
            if (found.string == 0) {
                found.string = c.ts.objectStringIndex(r);
                if (found.string != 0) found.string_readonly = c.ts.stringIndexIsReadonly(r);
            }
            if (found.number == 0) {
                found.number = c.ts.objectNumberIndex(r);
                if (found.number != 0) found.number_readonly = c.ts.numberIndexIsReadonly(r);
            }
        },
        .intersection => {
            for (try c.memberList(r)) |m| try collectHomoIndexInto(c, m, found);
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
                    // A symbol-named key survives exactly the mirror-image
                    // filter — `keyof T & symbol`, the counterpart of the
                    // `keyof T & string` idiom this arm exists for. Reachable
                    // only since `keyof` started answering a symbol-named
                    // member with the symbol itself (`memberKeyKind`).
                    .unique_symbol => want_symbol and !want_string and !want_number,
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
    return objectFromPropsFlags(c, props, sindex, nindex, 0);
}

/// `objectFromProps` with object flags to carry onto the result.
pub fn objectFromPropsFlags(c: *Checker, props: []const types.Prop, sindex: TypeId, nindex: TypeId, obj_flags: u32) Error!TypeId {
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
    return c.ts.makeObject(out.items, sindex, nindex, obj_flags);
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

/// How far past tsc's single `getSimplifiedIndexedAccessType` step
/// `simplifyIndexAccess` is allowed to go. The two readings differ only in
/// what they are asked ABOUT, which is why they share one implementation.
pub const IndexSimplify = enum {
    /// One mapped-object substitution on the WRITTEN object type. This is what
    /// the RELATION and the property lookup want: they hold an interned access
    /// and are asking "does this reduce to the other side's template?", so
    /// resolving the object through aliases or distributing an intersection
    /// would answer about a different type than the one being related.
    mapped_only,
    /// The inference-PATTERN reading: resolve the object structurally,
    /// re-simplify the substituted value (which is how the intersection
    /// underneath a `Readonly<A & E>` surfaces), and distribute an
    /// INTERSECTION object — `(A & E)[K]` -> `A[K] & E[K]` — so the naked type
    /// variable a candidate can pair with becomes visible.
    pattern,
};

/// tsc's `getSimplifiedIndexedAccessType`, the generic-MAPPED-object arm:
/// "If the object type is a mapped type `{ [P in K]: E }`, where `K` is
/// generic, instantiate `E` using a mapper that substitutes the index type
/// for `P`." `mode` selects how much of tsc's surrounding `getSimplifiedType`
/// recursion comes with it (see `IndexSimplify`).
///
/// Null when nothing applies — a non-mapped, non-intersection object, or a map
/// that REMAPS its keys (`as N<P>`), where the substitution is not the value at
/// `idx` — or when the simplification is the access itself.
///
/// The map's OPTIONALITY is deliberately not folded in. tsc bakes `|
/// undefined` into `getTemplateTypeFromMappedType` and therefore carries it
/// on both sides of every template comparison; ztsc keeps `mappedValue` the
/// written template and judges `?` separately (`mappedAddsOptional`), so
/// adding it here would make one side of that comparison carry an
/// `undefined` the other never has.
///
/// This is what relates `Readonly<Partial<T>>` to `Partial<T>`: the source's
/// template is `Partial<T>[P]`, which is the target's `T[P]` only once the
/// inner map is substituted through. Neither side's base-constraint route
/// can answer it — `T` is a free parameter, so both accesses stay deferred.
///
/// Asked as a QUERY, never baked into the type's identity: the relation reads
/// the same access structurally and wants it whole, and interning the
/// simplification also drops `Partial<T>[K]`'s `| undefined`.
pub fn simplifyIndexAccess(c: *Checker, acc: TypeId, mode: IndexSimplify) Error!?TypeId {
    return simplifyIndexAccessAt(c, acc, mode, 0);
}

fn simplifyIndexAccessAt(c: *Checker, acc: TypeId, mode: IndexSimplify, depth: u32) Error!?TypeId {
    if (depth > 4) return null;
    const s = &c.ts;
    if (s.kind(acc) != .index_access) return null;
    const idx = s.indexAccessIndex(acc);
    const obj = switch (mode) {
        .mapped_only => s.indexAccessObj(acc),
        .pattern => try c.resolveStructural(s.indexAccessObj(acc)),
    };
    if (s.kind(obj) == .mapped and s.mappedAs(obj) == 0) {
        const val = try c.substMappedKey(s.mappedValue(obj), s.mappedParamId(s.mappedKeyParam(obj)), idx);
        if (val == acc) return null;
        if (mode == .mapped_only) return val;
        return (try simplifyIndexAccessAt(c, val, mode, depth + 1)) orelse val;
    }
    if (mode == .mapped_only or s.kind(obj) != .intersection) return null;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    const ms = try c.scratch().dupe(TypeId, try c.memberList(obj));
    defer c.scratch().free(ms);
    for (ms) |mm| try parts.append(c.scratch(), try c.reduceIndexedAccess(mm, idx));
    const out = try s.makeIntersection(c.scratch(), parts.items);
    return if (out == acc) null else out;
}

/// `simplifyIndexAccess` in its `.mapped_only` reading — the relation and
/// property-lookup entry point, kept under its own name because that is what
/// its four call sites are asking for.
pub fn simplifyMappedIndexAccess(c: *Checker, acc: TypeId) Error!?TypeId {
    return simplifyIndexAccess(c, acc, .mapped_only);
}

/// The same simplification a READER of `M[K]` sees, which is the written
/// template plus the map's own `+?` spelled as `| undefined`.
///
/// tsc has only one simplification, but it bakes the optionality into the
/// template itself:
///
/// ```ts
/// function getTemplateTypeFromMappedType(type: MappedType) {
///     return type.templateType || (type.templateType = type.declaration.type ?
///         instantiateType(addOptionality(getTypeFromTypeNode(type.declaration.type), /*isProperty*/ true,
///             !!(getMappedTypeModifiers(type) & MappedTypeModifiers.IncludeOptional)), type.mapper) :
///         errorType);
/// }
/// ```
///
/// ztsc cannot do that, for the reason `simplifyMappedIndexAccess` states:
/// `mappedValue` is compared template-to-template by `mappedTypeRelatedTo`,
/// where both sides judge `?` separately (`mappedCombinedOptionality`), so an
/// `undefined` folded into one side's template is an `undefined` the other
/// side never has. So the two readings are separate functions, and only the
/// places that ask "what does this access EVALUATE to" call this one.
///
/// `Partial<T>[K]` is the shape it exists for: reading one yields `T[K] |
/// undefined`, so `x[k] = y[k]` with `y: Partial<T>` is an error
/// (`mappedTypeRelationships` `f10`…`f13`) even though `Partial<T>` and `T`
/// share a template.
///
/// The map's OWN `+?` only, exactly as `getMappedTypeModifiers` reads it — a
/// `Readonly<Partial<T>>` adds nothing here and picks the `undefined` up from
/// simplifying its template's inner `Partial<T>[P]` instead.
pub fn simplifyMappedIndexAccessRead(c: *Checker, acc: TypeId) Error!?TypeId {
    const sim = (try simplifyMappedIndexAccess(c, acc)) orelse return null;
    if (c.ts.mappedFlags(c.ts.indexAccessObj(acc)) & types.mapped_flag_optional_add == 0) return sim;
    return try c.makeUnion2(sim, types.undefined_type);
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
            return s.makeTupleLike(t, elems.items);
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
