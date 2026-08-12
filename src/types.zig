//! Type representation + hash-consing.
//!
//! Design decisions:
//!
//! - **`TypeId` is a `u32`** index into a struct-of-arrays store: `kind`
//!   (1 byte) + `data { a, b }` (8 bytes) in parallel arrays, with
//!   variable-length payloads (union members, object properties, function
//!   params) in a shared `extra: []u32` side array — the same layout
//!   discipline as the AST and binder.
//! - **Types are interned (hash-consed)**: structurally identical types get
//!   the same `TypeId`, so type equality is integer equality and relation
//!   caches can key on `TypeId` pairs. The intern map hashes a type's
//!   *shape* — its kind plus payload words with extra-ranges dereferenced —
//!   so two candidates with equal contents at different extra offsets are
//!   the same type. Types are immutable after creation and never freed.
//! - **Well-known types live at fixed indices** (`any = 1`, ... `empty_object
//!   = 16`), created in `init` in a fixed order. Index 0 is the usual "none"
//!   sentinel.
//! - **Unions are canonical**: flattened, deduped, sorted by TypeId, `never`
//!   dropped, `any`/`unknown` absorbing, literals absorbed by their base
//!   primitive when present, and `true | false` collapsed to `boolean`
//!   (tsc models `boolean` as that union; we keep the intrinsic and
//!   canonicalize toward it — same observable behavior for the subset).
//!   `T | never = T`, a single member is returned unwrapped, and the empty
//!   union is `never`.
//! - **Intersections are canonical** in the same way *except for order*:
//!   flattened, deduped (first occurrence wins), `unknown` dropped
//!   (`T & unknown = T`), `never`/`any` absorbing, empty intersection is
//!   `unknown` — but members keep the order they were written in, as they do
//!   in tsc, because that order is observable (an intersection's call
//!   signatures are its constituents' concatenated in member order). So
//!   `A & B` and `B & A` are two TypeIds. A *union* constituent is distributed
//!   into a union of intersections (`(A | B) & C` -> `A & C | B & C`), as tsc
//!   does, so no interned intersection ever contains a union member.
//!   Object-member *merging* is not done at construction; the checker merges
//!   views lazily (property lookup walks all constituents).
//! - **Freshness** (for excess-property checking) is a flag bit on object
//!   types that *participates* in interning: the fresh and regular variants
//!   of an object literal type are two TypeIds, and `regular()` maps
//!   fresh -> regular. This keeps interning sound without a side table.
//! - **Lazy named types**: interface/class-instance/alias references are
//!   `.ref { symbol, args }` types; the checker expands them on demand and
//!   caches the expansion. This file only stores the reference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const intern = @import("intern.zig");

pub const Atom = intern.Atom;
pub const Error = error{OutOfMemory};

/// Index into the type store. 0 = "no type" sentinel.
pub const TypeId = u32;
pub const no_type: TypeId = 0;

// --- well-known TypeIds (fixed indices, created by Store.init) -------------
pub const any_type: TypeId = 1;
pub const unknown_type: TypeId = 2;
pub const never_type: TypeId = 3;
pub const void_type: TypeId = 4;
pub const undefined_type: TypeId = 5;
pub const null_type: TypeId = 6;
pub const string_type: TypeId = 7;
pub const number_type: TypeId = 8;
pub const boolean_type: TypeId = 9;
pub const bigint_type: TypeId = 10;
pub const symbol_type: TypeId = 11;
/// The `object` keyword type (any non-primitive).
pub const object_keyword_type: TypeId = 12;
/// Internal error type: produced after a diagnostic was already reported;
/// assignable in both directions so errors don't cascade. Prints as "any".
pub const error_type: TypeId = 13;
pub const true_type: TypeId = 14;
pub const false_type: TypeId = 15;
/// `{}` — the empty (non-fresh) object type.
pub const empty_object_type: TypeId = 16;
/// tsc's `anyFunctionType`: the placeholder a CONTEXT-SENSITIVE function
/// expression is typed as while a call's first inference round runs under
/// `CheckMode.SkipContextSensitive`. It carries no properties and no call
/// signatures, so nothing structural is learned from it, and
/// `inferFromTypes` refuses it outright as a candidate for a type variable
/// (tsc marks it `ObjectFlags.NonInferrableType`) — the round-1 reading of
/// such an argument is an artifact of running before the type arguments
/// exist, and the second round re-derives it for real. Distinct from `{}`
/// only by the not-inferable flag, which is what keeps it a separate
/// interned id.
pub const any_function_type: TypeId = 17;
pub const first_free_index: TypeId = 18;

pub const Kind = enum(u8) {
    /// Reserved index 0.
    none,
    // Intrinsics (no payload).
    any,
    unknown,
    never,
    void,
    undefined,
    null,
    string,
    number,
    boolean,
    bigint,
    symbol,
    object_keyword,
    err,
    bool_true,
    bool_false,
    /// String literal type. a = atom, b = 1 if fresh (widening).
    string_literal,
    /// Number literal type. a,b = f64 bits (lo, hi).
    number_literal,
    /// Fresh (widening) number literal; payload identical to number_literal.
    number_literal_fresh,
    /// BigInt literal type. a = atom of the literal text (incl. `n`),
    /// b = 1 if fresh.
    bigint_literal,
    /// Union. extra[a..b] = member TypeIds (canonical: sorted, deduped).
    union_type,
    /// Intersection. extra[a..b] = member TypeIds (canonical).
    intersection,
    /// Array. a = element type.
    array,
    /// Tuple. a = extra index, b = element count.
    /// extra[a..]: per element [type, flags] (flags: 1 optional, 2 rest).
    tuple,
    /// Object type. a = extra index, b = property count. extra[a..]:
    /// [flags, string_index_type, number_index_type,
    ///  (iff flags has obj_flag_has_sigs) call_count, construct_count,
    ///  then per property (sorted by name atom): name, type, prop_flags,
    ///  (iff obj_flag_has_sigs) then call-sig TypeIds, then construct-sig
    ///  TypeIds — each an interned `.function` type, in declaration order].
    /// Object flags: 1 = fresh (object literal, excess-prop checked);
    /// 2 = not-inferable-index (interface / class-instance shape — has no
    /// *implied* string index for the index-signature relation, unlike
    /// object/type literals); 4 = has call/construct signatures.
    /// prop_flags: 1 = optional, 2 = readonly.
    object,
    /// Function/signature type. a = extra index, b = param count. extra[a..]:
    /// [flags, return_type, tp_count, tp symbol ids...,
    ///  then per param: name_atom, type, param_flags,
    ///  then (iff flags has fn_flag_predicate) pred_flags, pred_param,
    ///  pred_type].
    /// Function flags: 1 = method (bivariant params), 2 = predicate.
    /// param_flags: 1 = optional, 2 = rest, 4 = has_initializer.
    function,
    /// Overload set. extra[a..b] = function TypeIds in declaration order.
    overloads,
    /// Lazy named reference (interface / class instance / alias).
    /// a = extra index, b = arg count. extra[a..]: [symbol, args...].
    ref,
    /// Generic type parameter. a = symbol id.
    type_param,
    /// Class value (static side / constructor). a = class symbol id.
    class_value,
    /// Enum type (nominal). a = enum symbol id.
    /// b = 0 for the WHOLE enum (`let x: E`); otherwise this is the enum
    /// *member* type `E.A` and b is the member's name atom, OR-ed with
    /// `enum_member_fresh` while the type is still widening. tsc models a
    /// member as an "enum literal": a nominal unit type that is a subtype of
    /// its declared value literal and of the whole enum, distinct from every
    /// sibling member. Freshness follows `string_literal`'s: a member *access*
    /// (`E.A`) is fresh and widens to `E` at a mutable position, an annotation
    /// (`x: E.A`) is not. Atom ids never reach 2^31, so the top bit is free.
    enum_type,
    /// `unique symbol`. a = nominal identity id (a dense per-declaration
    /// number assigned by the checker). Assignable only to itself and to
    /// `symbol`; two distinct `unique symbol` declarations never unify.
    unique_symbol,
    /// Polymorphic `this` type. a = the home class's generic instance
    /// ref (its "apparent" type). Produced for a method's `foo(): this` return
    /// annotation; substituted with the concrete receiver at property access,
    /// so `sub.foo()` types as the subclass. resolveStructural/assignability
    /// fall back to the stored instance ref.
    this_type,
    /// `infer V` binder. a = a dense id (unique per (conditional, name)),
    /// b = the binder's name atom (for display). Appears only inside a
    /// conditional type's extends/true branches; substituted away when the
    /// conditional resolves. Not a "free type parameter" for deferral purposes.
    infer_var,
    /// Deferred conditional type `C extends E ? T : F`. a = extra index,
    /// b = flags (bit0 = distributive: check was a naked type param). Interned
    /// only while the check type is still generic; resolved on instantiation.
    /// extra[a..]: [check, extends, true, false].
    conditional,
    /// The key parameter `K` of a mapped type (`{ [K in …]: … }`).
    /// a = a dense id (unique per mapped-type node), b = the name atom (for
    /// display). Behaves like a locally-bound parameter of the mapped type:
    /// substituted with each concrete key literal at materialization. Not a
    /// "free type parameter" for deferral purposes (like `infer_var`).
    mapped_param,
    /// Deferred indexed access `Obj[Idx]` (minimal — a down-payment on    /// full generic indexed access). a = the object type, b = the index type. Interned by
    /// `indexedAccessType` only while `Idx` is a mapped key parameter (so a
    /// mapped value `T[K]` stays symbolic until each key is materialized).
    index_access,
    /// Deferred mapped type `{ [K in C] V }`. a = extra index,
    /// b = modifier flags. Interned only while the key set is still generic
    /// (constraint / homomorphic source mentions an outer type param);
    /// resolved to a concrete object on instantiation.
    /// extra[a..]: [key_param, constraint, value, as_clause, source, flags].
    mapped,
    /// Deferred / pattern template-literal type `` `head${h0}c0${h1}c1…` ``
    /// a = extra index, b = hole count N. extra[a] = head literal atom;
    /// then per hole i: [hole_type, chunk_atom] where chunk_atom is the literal
    /// text immediately following hole i. Interned when a hole is still generic
    /// (deferred) OR when a hole is a non-enumerable primitive (`string` /
    /// `number`) — the "pattern" form (`` `a${string}` ``). A fully-concrete
    /// template never lands here (it resolves to a string-literal / union).
    template_literal_type,
    /// Intrinsic string-transform application: `Uppercase` /
    /// `Lowercase` / `Capitalize` / `Uncapitalize`. a = intrinsic index
    /// (`string_mapping_*` below), b = the argument type. Interned only while
    /// the argument is still generic; a concrete argument resolves to the
    /// transformed string-literal (or distributes over a union).
    string_mapping,
    /// Deferred `keyof T`. a = the operand type, b = 0. Interned only
    /// while the operand is still generic (a type param or another deferred
    /// node) — a concrete object/array resolves eagerly to its key union in
    /// `keyofType`. Resolved on instantiation (`instantiateId`'s `.keyof_op`
    /// arm re-runs `keyofType` on the substituted operand). Its apparent
    /// constraint is `string | number | symbol`.
    keyof_op,
};

pub const cond_flag_distributive: u32 = 1;

/// Freshness bit in an `enum_type` member payload (`data_b`). See `enum_type`.
pub const enum_member_fresh: u32 = 0x8000_0000;

/// Marks an `infer_var` occurrence that is a *reference* to a binder declared
/// by an enclosing conditional (a bare `R` in `string extends R ? … : …`),
/// as opposed to the `infer R` DECLARATION itself. Stored in the high bit of
/// the payload id so both occurrences keep the same logical `inferVarId`;
/// only `inferVarIsRef` can tell them apart. A conditional binds exactly the
/// declarations in its own extends clause — see `reduceConditional`.
pub const infer_var_reference: u32 = 0x8000_0000;

// String-transform intrinsic indices, stored in a `string_mapping`
// type's `data_a`.
pub const string_mapping_uppercase: u32 = 0;
pub const string_mapping_lowercase: u32 = 1;
pub const string_mapping_capitalize: u32 = 2;
pub const string_mapping_uncapitalize: u32 = 3;

// Mapped-type modifier flags, stored in a mapped type's `data_b` (and
// repeated as its final extra word so they participate in hash-cons identity).
// Set by the parser (`+`/`-`/bare) and interpreted by the checker.
pub const mapped_flag_readonly_add: u32 = 1; // `+readonly` / `readonly`
pub const mapped_flag_readonly_remove: u32 = 2; // `-readonly`
pub const mapped_flag_optional_add: u32 = 4; // `+?` / `?`
pub const mapped_flag_optional_remove: u32 = 8; // `-?`
pub const mapped_flag_homomorphic: u32 = 16; // constraint was `keyof T`

pub const obj_flag_fresh: u32 = 1;
/// The object is an interface or class-instance shape: it does NOT carry an
/// *implied* string index signature for the index-signature assignability
/// relation. Object/type literals (the inferable-index case) leave this clear.
pub const obj_flag_not_inferable: u32 = 2;
/// The object carries call and/or construct signature lists (a hybrid
/// "callable object" type). When set, the payload has two extra header
/// words after the index-signature words — `[call_count, construct_count]` —
/// and the call-sig then construct-sig TypeIds trail the property records.
/// Sig-less objects (the common case) leave this clear and pay no extra words.
pub const obj_flag_has_sigs: u32 = 4;
/// The global-scope object — the type of `globalThis` (and, via lib.dom's
/// `declare var window: Window & typeof globalThis`, of `window` / `self`).
/// A marker only: the object carries no stored properties, because the global
/// scope's members are the *program's* merged global value declarations, a set
/// far too large (and too self-referential — `window`'s own type mentions it)
/// to materialize. Member lookup consults the linker's globals table instead
/// (`Checker.propOfTypeEx`), so the type stays a single interned word and its
/// members cost exactly what is asked for.
pub const obj_flag_global_this: u32 = 8;
/// The object's ONLY index signature is keyed by `symbol` (`[k: symbol]: V`).
/// The value type is kept in the string-index slot, so every consumer of an
/// index signature keeps behaving as it did; the flag exists so `keyof` can
/// report `symbol` instead of `string | number`, which is what lets a
/// `unique symbol` key satisfy a `keyof S` parameter (nestjs-cls' `ClsStore`
/// is `{ [key: symbol]: any }` and `cls.get(CLS_ID)` passes exactly that).
/// Left clear when a string/number index is present too, so the shared slot
/// is never mis-reported.
pub const obj_flag_symbol_index: u32 = 16;
/// The object was WRITTEN as an object literal (tsc's `ObjectFlags.
/// ObjectLiteral`, which is a distinct bit from `ObjectFlags.FreshLiteral`).
/// Freshness — the excess-property/weak-type trigger — is stripped the moment
/// the literal is contextually consumed; the *origin* survives that, and is
/// what tsc's `unionObjectAndArrayLiteralCandidates` and its widening context
/// (`getWidenedTypeOfObjectLiteral`) key off. Cleared only by the widening
/// that tsc's `getWidenedType` performs on a mutable location, which is where
/// `getWidenedTypeOfObjectLiteral` builds a fresh anonymous type and keeps
/// neither bit.
pub const obj_flag_literal_origin: u32 = 32;
/// The shape came from an interface (or class) whose `extends` heritage
/// resolved to `any` — `interface DefaultState extends DefaultStateExtends {}`
/// with `type DefaultStateExtends = any`, which is how `@types/koa` declares
/// its user-augmentable state — AND which declares nothing of its own.
///
/// tsc handles that shape in two places, and both are observable:
///
///  1. `resolveObjectTypeMembers` contributes `[x: string]: any` for an `any`
///     base instead of the base's index infos (its `anyBaseTypeIndexInfo`), so
///     every property read succeeds with `any` and `keyof` is `string | number`.
///     That part is just the string-index slot; it applies even when the
///     interface declares members of its own.
///  2. `getNormalizedType` — via `getSingleBaseForNonAugmentingSubtype` — swaps
///     a NON-GENERIC class/interface reference with exactly one base type and no
///     own members for that base type before the relation runs. With the base
///     being `any`, the interface therefore *relates* as `any`: it is assignable
///     to every object target (verified against the oracle: to `Date`, to
///     `[number, string]`, to a class with a `private` member, to `{ auth:
///     never }`, and to `Function`, which is what makes calling it legal),
///     while a plain `{ [x: string]: any }` is assignable to none of those.
///     It is NOT assignable to a primitive target — `isRelatedTo` answers the
///     object→primitive pair from the *un*-normalized source, so `const n:
///     number = state` stays TS2322.
///
/// This flag records (2); (1) is the string-index slot on the same object. Only
/// the `!allow_index` (relation) arm of `propOfTypeEx` reads it — answering
/// `any` for every name is exactly what makes the source satisfy an arbitrary
/// target property list, which is the whole of what normalizing to `any` buys.
pub const obj_flag_any_base: u32 = 64;
/// The object's index signatures ARE a mapped type's own key set, so `keyof`
/// reports exactly their key types and does not widen a string index to
/// `string | number`.
///
/// tsc never asks an index signature this question: a mapped type stays a
/// `MappedType`, and `getIndexType` answers it from
/// `getConstraintTypeFromMappedType` — so `keyof Record<string, V>` is `string`,
/// and `const k: keyof Record<string, V> = 0` is an error. ztsc materializes a
/// mapped type whose key set is concrete into an ordinary object, and the
/// `[k: string]: V` that comes out is indistinguishable from a written one,
/// whose `keyof` genuinely IS `string | number` (a numeric key reads a string
/// index signature). This flag is that distinction, which is also why it is a
/// flag and not a side table: interning must keep `Record<string, V>` and
/// `{ [k: string]: V }` apart, exactly as tsc's two type objects are apart.
///
/// A HOMOMORPHIC map propagates it from its source (`{ [K in keyof S]: … }` has
/// the key set `keyof S`, whatever that is), so a map over a written index
/// signature keeps the widening and a map over a `Record` keeps the flag.
///
/// Outline writes `keyof typeof codeLanguages` for a `Record<string,
/// CodeLanguage>` and hands it to `FrequencyTracker<T extends string>`: without
/// this, `string | number` failed the constraint and every read through the
/// tracker's `filter?: (item: T) => boolean` was a false TS2322/TS2344.
pub const obj_flag_mapped_keys: u32 = 128;
pub const prop_flag_optional: u32 = 1;
pub const prop_flag_readonly: u32 = 2;
/// A `private`/`protected` class member (tsc's `ModifierFlags.NonPublic`).
/// Carried so `keyof` can leave it out — tsc's `getLiteralTypeFromProperty`
/// answers `never` for a non-public property, which is what keeps
/// `Pick<C, keyof C>` (and every `{ [K in keyof C]: … }` over a class) to the
/// public surface. The structural relation still sees the member.
pub const prop_flag_non_public: u32 = 4;
pub const elem_flag_optional: u32 = 1;
pub const elem_flag_rest: u32 = 2;
/// A `readonly` tuple element (produced by `as const`). Ignored by the
/// assignability relation (like readonly object props); enforced at write
/// sites (indexed writes -> TS2540).
pub const elem_flag_readonly: u32 = 4;
pub const fn_flag_method: u32 = 1;
/// The signature carries a type predicate (`x is T` / `asserts x[ is T]`).
/// When set, the payload has three trailing words after the params:
/// [pred_flags, pred_param, pred_type]. pred_flags bit0 = asserts.
pub const fn_flag_predicate: u32 = 2;
/// The signature carries an explicit `this` parameter type (`f(this: T, ...)`).
/// When set, one extra word (the `this` type) trails the params and any
/// predicate words. The `this` parameter is excluded from the ordinary param
/// list, so it never counts toward arity; it is used for the call-site
/// receiver check (TS2684) and for typing `this` inside the body.
pub const fn_flag_this: u32 = 4;
pub const param_flag_optional: u32 = 1;
pub const param_flag_rest: u32 = 2;
pub const param_flag_initializer: u32 = 4;

pub const Prop = struct {
    name: Atom,
    ty: TypeId,
    flags: u32 = 0,

    pub fn optional(p: Prop) bool {
        return p.flags & prop_flag_optional != 0;
    }
    pub fn readonly(p: Prop) bool {
        return p.flags & prop_flag_readonly != 0;
    }
    pub fn nonPublic(p: Prop) bool {
        return p.flags & prop_flag_non_public != 0;
    }
};

pub const Param = struct {
    name: Atom,
    ty: TypeId,
    flags: u32 = 0,

    pub fn optional(p: Param) bool {
        return p.flags & (param_flag_optional | param_flag_initializer) != 0;
    }
    pub fn rest(p: Param) bool {
        return p.flags & param_flag_rest != 0;
    }
};

/// A signature's type predicate. `param` names the guarded parameter by
/// index (or `this_param` for a `this is T` guard); `ty` is the asserted
/// type (`no_type` for a bare `asserts cond`); `asserts` distinguishes an
/// assertion function from a plain user-defined type guard.
pub const Predicate = struct {
    pub const this_param: u32 = std.math.maxInt(u32);
    param: u32,
    ty: TypeId,
    asserts: bool,
};

pub const TupleElem = struct {
    ty: TypeId,
    flags: u32 = 0,

    pub fn optional(e: TupleElem) bool {
        return e.flags & elem_flag_optional != 0;
    }
    pub fn rest(e: TupleElem) bool {
        return e.flags & elem_flag_rest != 0;
    }
    pub fn readonly(e: TupleElem) bool {
        return e.flags & elem_flag_readonly != 0;
    }
};

/// The hash-consing type store. All storage comes from one allocator (the
/// per-checker type arena); nothing is freed individually.
///
/// **Frozen base / per-checker overlay.** A `Store` is either a
/// *base* (`base == null`) — a self-contained store that owns TypeIds
/// `[0, kinds.len)` — or an *overlay* over a frozen base. An overlay owns
/// TypeIds `[base_len, …)` in its own SoA arrays and delegates all reads of
/// ids `< base_len` to `base`. Interning probes the frozen base's map first,
/// so a type structurally identical to a base type returns the *base* id
/// (shared, no per-overlay duplication); only genuinely new types allocate an
/// overlay id at `base_len + local_index`. The base is built and `freeze`d
/// single-threaded before workers spawn, then shared read-only across every
/// overlay — the type-level twin of the merged-symbol layer. A `TypeId`
/// therefore spans base+overlay and is never assumed checker-local (the
/// frozen-base layout commitment).
pub const Store = struct {
    alloc: Allocator,
    kinds: std.ArrayList(Kind) = .empty,
    data_a: std.ArrayList(u32) = .empty,
    data_b: std.ArrayList(u32) = .empty,
    extra: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(TypeId, void, MapCtx, 80) = .empty,
    /// Hash-cons key of every type this store owns, parallel to `kinds`
    /// (index `id - base_len`). See `MapCtx.hash`: the intern map's growth
    /// rehashes every stored key, and re-deriving a key's *shape* — the whole
    /// `extra` payload, reached through three random-access SoA reads — and
    /// Wyhashing it was measured at 6.5% of immich's check phase, because a
    /// package whose types run ~5 per AST node outgrows `reserveTypes`'
    /// estimate by an order of magnitude and pays the whole doubling
    /// sequence. Storing the hash the intern already computed turns each
    /// rehash into one array read. 4 bytes per type (10 MB on immich at one
    /// checker).
    shape_hash: std.ArrayList(u32) = .empty,
    /// Scratch for building candidate payloads before interning.
    pending: std.ArrayList(u32) = .empty,
    /// Frozen base this store overlays, or null for a base store. Read-only;
    /// shared across all overlay threads (pure reads of immutable data).
    base: ?*const Store = null,
    /// First TypeId this store owns. `== base.kinds.items.len` for an overlay
    /// (base owns `[0, base_len)`), `0` for a base store. An id `< base_len`
    /// is a base id and every accessor delegates it to `base`.
    base_len: u32 = 0,
    /// Set by `freeze`; a frozen store is immutable and safe to share as a
    /// base. Guards against accidental post-freeze interning.
    frozen: bool = false,
    /// Per `Kind`, the longest shape a FROZEN base holds — 0 when the base
    /// holds no type of that kind at all. Set by `freeze`, read by an
    /// overlay's `internType` to skip the base probe outright: a candidate
    /// whose kind the base does not hold, or whose shape is longer than any
    /// the base holds, cannot possibly be a base type, so hashing it a second
    /// time to ask is pure loss. Today's base is 15 scalar intrinsics plus the
    /// empty object, so this skips the probe for every composite — which is
    /// exactly the population whose shapes are long. It stays exact if the
    /// base ever carries a real payload (frozen-base piece 2): the test only
    /// ever skips a lookup that could not have hit.
    base_kind_words: [256]u32 = @splat(0),

    pub fn init(alloc: Allocator) Error!Store {
        var s: Store = .{ .alloc = alloc };
        // Index 0: none sentinel.
        try s.appendRaw(.none, 0, 0, hashShape32(.none, &.{ 0, 0 }));
        // Fixed-index intrinsics; order must match the constants above.
        const fixed = [_]Kind{
            .any,    .unknown,        .never,  .void,      .undefined,
            .null,   .string,         .number, .boolean,   .bigint,
            .symbol, .object_keyword, .err,    .bool_true, .bool_false,
        };
        for (fixed) |k| {
            const id: TypeId = @intCast(s.kinds.items.len);
            try s.appendRaw(k, 0, 0, hashShape32(k, &.{ 0, 0 }));
            try s.map.putContext(s.alloc, id, {}, .{ .store = &s });
        }
        // empty object {} at index 16.
        const eo = try s.makeObject(&.{}, no_type, no_type, 0);
        std.debug.assert(eo == empty_object_type);
        // `anyFunctionType` at index 17.
        const aft = try s.makeObject(&.{}, no_type, no_type, obj_flag_not_inferable);
        std.debug.assert(aft == any_function_type);
        return s;
    }

    /// A fresh overlay over a frozen `base`. The overlay owns no fixed
    /// intrinsics — the well-known ids live in the base — and allocates its
    /// first local type at `base_len`. `base` must already be `freeze`d and
    /// outlive every overlay built over it.
    pub fn initOverlay(alloc: Allocator, base: *const Store) Error!Store {
        std.debug.assert(base.frozen);
        std.debug.assert(base.base == null); // single base level (no chaining)
        return .{
            .alloc = alloc,
            .base = base,
            .base_len = @intCast(base.kinds.items.len),
        };
    }

    /// Pre-size the hash-consing map for `n` expected types.
    pub fn reserveTypes(s: *Store, n: usize) Error!void {
        try s.map.ensureTotalCapacityContext(s.alloc, @intCast(n), .{ .store = s });
    }

    /// Seal a base store: no further interning, safe to share read-only as the
    /// frozen base of any number of overlays.
    pub fn freeze(s: *Store) void {
        s.frozen = true;
        // Summarize the base's shapes for every overlay's `internType`
        // base-probe skip (see `base_kind_words`). Only ids this store owns
        // are considered; a base never overlays another base.
        s.base_kind_words = @splat(0);
        var i: u32 = 1; // skip the index-0 `none` sentinel
        while (i < s.kinds.items.len) : (i += 1) {
            var buf: [2]u32 = undefined;
            const k = @intFromEnum(s.kinds.items[i]);
            const n: u32 = @intCast(s.shapeWords(i, &buf).len);
            if (n > s.base_kind_words[k]) s.base_kind_words[k] = n;
        }
    }

    /// Release the store's own SoA arrays. Only meaningful when `alloc` is a
    /// *freeing* allocator (the per-checker overlay); a store built on an arena
    /// is released with the arena and never calls this.
    pub fn deinit(s: *Store) void {
        s.kinds.deinit(s.alloc);
        s.data_a.deinit(s.alloc);
        s.data_b.deinit(s.alloc);
        s.extra.deinit(s.alloc);
        s.pending.deinit(s.alloc);
        s.shape_hash.deinit(s.alloc);
        s.map.deinit(s.alloc);
    }

    fn appendRaw(s: *Store, k: Kind, a: u32, b: u32, h: u32) Error!void {
        try s.kinds.append(s.alloc, k);
        try s.data_a.append(s.alloc, a);
        try s.data_b.append(s.alloc, b);
        try s.shape_hash.append(s.alloc, h);
    }

    /// Total types visible through this store (base + overlay), excluding the
    /// index-0 `none` sentinel. An overlay's own contribution is
    /// `overlayCount`; the shared base is counted once here.
    pub fn count(s: *const Store) usize {
        if (s.base) |b| return b.count() + s.kinds.items.len;
        return s.kinds.items.len - 1;
    }

    /// Types interned into this overlay's own storage (0 for a fresh overlay).
    pub fn overlayCount(s: *const Store) usize {
        return if (s.base == null) 0 else s.kinds.items.len;
    }

    /// Debug-only soundness net: every union/intersection/overloads member id
    /// interned into this overlay must land inside the valid id space. A member
    /// pointing past the end is a corrupt id that reached `internType` — the
    /// signature of a use-after-realloc escape (a live `members()` slice read
    /// while the loop body grew `extra` and moved its buffer; see the
    /// `keyofType` intersection arm) or an uninitialized member slot. Compiled
    /// out entirely in release (guarded by `runtime_safety`), and O(total
    /// composite members) when on. Call once after a check completes.
    pub fn debugValidateComposites(s: *const Store) void {
        if (!std.debug.runtime_safety) return;
        const upper: TypeId = s.base_len + @as(TypeId, @intCast(s.kinds.items.len));
        var i: usize = 0;
        while (i < s.kinds.items.len) : (i += 1) {
            const id: TypeId = s.base_len + @as(TypeId, @intCast(i));
            switch (s.kinds.items[i]) {
                .union_type, .intersection, .overloads => {
                    for (s.members(id)) |m| {
                        std.debug.assert(m < upper);
                    }
                },
                else => {},
            }
        }
    }

    /// Exact bytes held by the sealed-style SoA arrays (base + overlay). The
    /// base's bytes are shared across overlays; `overlayBytes` isolates this
    /// overlay's own footprint.
    pub fn typeBytes(s: *const Store) usize {
        const local = s.kinds.items.len * (1 + 4 + 4 + 4) + s.extra.items.len * 4;
        return local + if (s.base) |b| b.typeBytes() else 0;
    }

    /// Bytes held by this store's own SoA arrays (overlay-local; excludes the
    /// shared base).
    pub fn overlayBytes(s: *const Store) usize {
        return s.kinds.items.len * (1 + 4 + 4 + 4) + s.extra.items.len * 4;
    }

    /// Approximate bytes including intern map capacity.
    pub fn totalBytes(s: *const Store) usize {
        return s.typeBytes() + s.map.capacity() * (@sizeOf(TypeId) + 1);
    }

    // --- base/overlay dispatch ----------------------------------------------
    // Reads of an id `< base_len` delegate to the frozen base (whose own
    // `base_len` is 0, so its accessors index directly — one level, no loop);
    // ids `>= base_len` index this overlay's arrays at `id - base_len`.

    pub fn kind(s: *const Store, id: TypeId) Kind {
        if (id < s.base_len) return s.base.?.kind(id);
        return s.kinds.items[id - s.base_len];
    }
    pub fn dataA(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.dataA(id);
        return s.data_a.items[id - s.base_len];
    }
    pub fn dataB(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.dataB(id);
        return s.data_b.items[id - s.base_len];
    }

    // --- payload views ------------------------------------------------------

    /// Union/intersection/overload members.
    ///
    /// The returned slice points straight into `extra`, so it **dangles as
    /// soon as a new type is interned** (`extra` may grow and move). Only hold
    /// it across a loop that provably cannot intern; otherwise walk with
    /// `memberCount`/`memberAt`, which re-derive the slice per step.
    pub fn members(s: *const Store, id: TypeId) []const TypeId {
        if (id < s.base_len) return s.base.?.members(id);
        return s.extra.items[s.dataA(id)..s.dataB(id)];
    }

    /// Member count for a `memberAt` walk.
    pub fn memberCount(s: *const Store, id: TypeId) usize {
        return s.members(id).len;
    }

    /// One member by index, re-deriving the slice on every call. Interning
    /// mid-walk can grow/move `extra` — that is exactly the iterator
    /// invalidation fixed in dceff79 — but a type's *contents* are immutable
    /// once interned, so an index stays valid where a pointer does not.
    /// Costs two loads instead of a scratch dupe of the whole list.
    pub fn memberAt(s: *const Store, id: TypeId, i: usize) TypeId {
        return s.members(id)[i];
    }

    pub fn arrayElem(s: *const Store, id: TypeId) TypeId {
        return s.dataA(id);
    }

    pub fn tupleLen(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }

    pub fn tupleElem(s: *const Store, id: TypeId, i: u32) TupleElem {
        if (id < s.base_len) return s.base.?.tupleElem(id, i);
        const base = s.dataA(id) + 2 * i;
        return .{ .ty = s.extra.items[base], .flags = s.extra.items[base + 1] };
    }

    pub fn objectFlags(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.objectFlags(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn objectIsFresh(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_fresh != 0;
    }
    /// Was this object WRITTEN as an object literal (tsc's
    /// `ObjectFlags.ObjectLiteral`)? Outlives freshness — see
    /// `obj_flag_literal_origin`.
    pub fn objectIsLiteralOrigin(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_literal_origin != 0;
    }
    /// An object/type-literal shape carries an *implied* string index signature
    /// for the index-signature relation; interface / class-instance shapes
    /// (marked `obj_flag_not_inferable`) do not.
    pub fn objectHasImpliedIndex(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_not_inferable == 0;
    }
    /// An interface shape whose only base is `any` and which declares nothing
    /// of its own, so the relation treats it as `any` would be — see
    /// `obj_flag_any_base`.
    pub fn objectRelatesAsAny(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_any_base != 0;
    }
    pub fn objectStringIndex(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.objectStringIndex(id);
        return s.extra.items[s.dataA(id) + 1];
    }
    pub fn objectNumberIndex(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.objectNumberIndex(id);
        return s.extra.items[s.dataA(id) + 2];
    }
    pub fn objectPropCount(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    /// Property records start at `dataA + objectHeaderLen`: 3 header words
    /// (flags, string index, number index), plus 2 more (call/construct
    /// counts) when the object carries signatures.
    fn objectHeaderLen(s: *const Store, id: TypeId) u32 {
        return if (s.objectFlags(id) & obj_flag_has_sigs != 0) 5 else 3;
    }
    pub fn objectProp(s: *const Store, id: TypeId, i: u32) Prop {
        if (id < s.base_len) return s.base.?.objectProp(id, i);
        const base = s.dataA(id) + s.objectHeaderLen(id) + 3 * i;
        return .{
            .name = s.extra.items[base],
            .ty = s.extra.items[base + 1],
            .flags = s.extra.items[base + 2],
        };
    }
    /// Number of call signatures on a callable object (0 for a plain object).
    pub fn objectCallSigCount(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.objectCallSigCount(id);
        if (s.objectFlags(id) & obj_flag_has_sigs == 0) return 0;
        return s.extra.items[s.dataA(id) + 3];
    }
    /// Number of construct signatures on a callable object.
    pub fn objectConstructSigCount(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.objectConstructSigCount(id);
        if (s.objectFlags(id) & obj_flag_has_sigs == 0) return 0;
        return s.extra.items[s.dataA(id) + 4];
    }
    pub fn objectCallSig(s: *const Store, id: TypeId, i: u32) TypeId {
        if (id < s.base_len) return s.base.?.objectCallSig(id, i);
        const sigs_base = s.dataA(id) + 5 + 3 * s.dataB(id);
        return s.extra.items[sigs_base + i];
    }
    pub fn objectConstructSig(s: *const Store, id: TypeId, i: u32) TypeId {
        if (id < s.base_len) return s.base.?.objectConstructSig(id, i);
        const sigs_base = s.dataA(id) + 5 + 3 * s.dataB(id) + s.objectCallSigCount(id);
        return s.extra.items[sigs_base + i];
    }
    /// Whether the object carries any call or construct signature.
    pub fn objectHasSigs(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_has_sigs != 0;
    }

    /// Binary search an object type's (atom-sorted) properties.
    pub fn objectPropByName(s: *const Store, id: TypeId, name: Atom) ?Prop {
        var lo: u32 = 0;
        var hi: u32 = s.objectPropCount(id);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const p = s.objectProp(id, mid);
            if (p.name == name) return p;
            if (p.name < name) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn fnFlags(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.fnFlags(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn fnReturn(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.fnReturn(id);
        return s.extra.items[s.dataA(id) + 1];
    }
    /// The signature's own type-param symbols. **Borrowed from `extra` — dead as
    /// soon as a new type is interned**, exactly like `members`. Only hold it
    /// across a loop that provably cannot intern; otherwise walk with
    /// `fnTypeParamCount`/`fnTypeParamAt`, which re-derive per step. Resolving a
    /// type param's constraint/default *does* intern (it materializes the bound
    /// from the AST), so any loop that touches bounds must index.
    pub fn fnTypeParams(s: *const Store, id: TypeId) []const u32 {
        if (id < s.base_len) return s.base.?.fnTypeParams(id);
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        return s.extra.items[base + 3 .. base + 3 + tpc];
    }
    /// Type-param count for a `fnTypeParamAt` walk.
    pub fn fnTypeParamCount(s: *const Store, id: TypeId) usize {
        return s.fnTypeParams(id).len;
    }
    /// One type param by index, re-deriving the slice on every call — an index
    /// survives an intern-driven `extra` growth where a held pointer does not
    /// (see `memberAt`).
    pub fn fnTypeParamAt(s: *const Store, id: TypeId, i: usize) u32 {
        return s.fnTypeParams(id)[i];
    }
    pub fn fnParamCount(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    pub fn fnParam(s: *const Store, id: TypeId, i: u32) Param {
        if (id < s.base_len) return s.base.?.fnParam(id, i);
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        const pbase = base + 3 + tpc + 3 * i;
        return .{
            .name = s.extra.items[pbase],
            .ty = s.extra.items[pbase + 1],
            .flags = s.extra.items[pbase + 2],
        };
    }

    pub fn fnHasPredicate(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .function and s.fnFlags(id) & fn_flag_predicate != 0;
    }
    pub fn fnPredicate(s: *const Store, id: TypeId) Predicate {
        if (id < s.base_len) return s.base.?.fnPredicate(id);
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        const pbase = base + 3 + tpc + 3 * s.dataB(id);
        return .{
            .asserts = s.extra.items[pbase] != 0,
            .param = s.extra.items[pbase + 1],
            .ty = s.extra.items[pbase + 2],
        };
    }

    /// The `this`-parameter type of a signature, or 0 if it has none.
    pub fn fnThisType(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.fnThisType(id);
        if (s.kind(id) != .function or s.fnFlags(id) & fn_flag_this == 0) return 0;
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        const pred: u32 = if (s.extra.items[base] & fn_flag_predicate != 0) 3 else 0;
        return s.extra.items[base + 3 + tpc + 3 * s.dataB(id) + pred];
    }

    /// The stored instance ref of a polymorphic `this` type.
    pub fn thisTypeInstance(s: *const Store, id: TypeId) TypeId {
        return s.dataA(id);
    }

    pub fn refSymbol(s: *const Store, id: TypeId) u32 {
        if (id < s.base_len) return s.base.?.refSymbol(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn refArgs(s: *const Store, id: TypeId) []const TypeId {
        if (id < s.base_len) return s.base.?.refArgs(id);
        const base = s.dataA(id);
        return s.extra.items[base + 1 .. base + 1 + s.dataB(id)];
    }

    /// `refArgs` counterparts of `memberCount`/`memberAt` — same rationale.
    pub fn refArgCount(s: *const Store, id: TypeId) usize {
        return s.refArgs(id).len;
    }

    pub fn refArgAt(s: *const Store, id: TypeId, i: usize) TypeId {
        return s.refArgs(id)[i];
    }

    pub fn inferVarId(s: *const Store, id: TypeId) u32 {
        return s.dataA(id) & ~infer_var_reference;
    }
    /// True for a bare mention of a binder declared by an *enclosing*
    /// conditional (`infer_var_reference`).
    pub fn inferVarIsRef(s: *const Store, id: TypeId) bool {
        return s.dataA(id) & infer_var_reference != 0;
    }
    pub fn inferVarName(s: *const Store, id: TypeId) Atom {
        return s.dataB(id);
    }

    pub fn condCheck(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.condCheck(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn condExtends(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.condExtends(id);
        return s.extra.items[s.dataA(id) + 1];
    }
    pub fn condTrue(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.condTrue(id);
        return s.extra.items[s.dataA(id) + 2];
    }
    pub fn condFalse(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.condFalse(id);
        return s.extra.items[s.dataA(id) + 3];
    }
    pub fn condDistributive(s: *const Store, id: TypeId) bool {
        return s.dataB(id) & cond_flag_distributive != 0;
    }

    pub fn mappedParamId(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn mappedParamName(s: *const Store, id: TypeId) Atom {
        return s.dataB(id);
    }

    pub fn indexAccessObj(s: *const Store, id: TypeId) TypeId {
        return s.dataA(id);
    }
    pub fn indexAccessIndex(s: *const Store, id: TypeId) TypeId {
        return s.dataB(id);
    }

    pub fn mappedKeyParam(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.mappedKeyParam(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn mappedConstraint(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.mappedConstraint(id);
        return s.extra.items[s.dataA(id) + 1];
    }
    pub fn mappedValue(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.mappedValue(id);
        return s.extra.items[s.dataA(id) + 2];
    }
    pub fn mappedAs(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.mappedAs(id);
        return s.extra.items[s.dataA(id) + 3];
    }
    pub fn mappedSource(s: *const Store, id: TypeId) TypeId {
        if (id < s.base_len) return s.base.?.mappedSource(id);
        return s.extra.items[s.dataA(id) + 4];
    }
    pub fn mappedFlags(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    pub fn mappedHomomorphic(s: *const Store, id: TypeId) bool {
        return s.mappedFlags(id) & mapped_flag_homomorphic != 0;
    }

    pub fn templateHead(s: *const Store, id: TypeId) Atom {
        if (id < s.base_len) return s.base.?.templateHead(id);
        return s.extra.items[s.dataA(id)];
    }
    pub fn templateHoleCount(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    pub fn templateHole(s: *const Store, id: TypeId, i: u32) TypeId {
        if (id < s.base_len) return s.base.?.templateHole(id, i);
        return s.extra.items[s.dataA(id) + 1 + 2 * i];
    }
    pub fn templateChunk(s: *const Store, id: TypeId, i: u32) Atom {
        if (id < s.base_len) return s.base.?.templateChunk(id, i);
        return s.extra.items[s.dataA(id) + 2 + 2 * i];
    }

    pub fn stringMappingKind(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn stringMappingArg(s: *const Store, id: TypeId) TypeId {
        return s.dataB(id);
    }

    pub fn keyofOperand(s: *const Store, id: TypeId) TypeId {
        return s.dataA(id);
    }

    pub fn typeParamSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn classSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn enumSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    /// Whether `id` is an enum *member* type (`E.A`) rather than a whole enum.
    pub fn isEnumMember(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .enum_type and s.dataB(id) != 0;
    }
    /// The member name atom of an enum member type; 0 for a whole enum.
    pub fn enumMemberAtom(s: *const Store, id: TypeId) Atom {
        return s.dataB(id) & ~enum_member_fresh;
    }
    /// Nominal identity id of a `unique symbol` type.
    pub fn uniqueSymId(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }

    pub fn numberValue(s: *const Store, id: TypeId) f64 {
        const bits = @as(u64, s.dataA(id)) | (@as(u64, s.dataB(id)) << 32);
        return @bitCast(bits);
    }
    pub fn literalAtom(s: *const Store, id: TypeId) Atom {
        return s.dataA(id);
    }

    // --- literal freshness (widening literal types, tsc-style) --------------

    /// Fresh literals widen to their base primitive at mutable positions.
    pub fn isFreshLiteral(s: *const Store, id: TypeId) bool {
        return switch (s.kind(id)) {
            .string_literal, .bigint_literal, .bool_true, .bool_false => s.dataB(id) == 1,
            .number_literal_fresh => true,
            // An enum *member* access is a widening literal; the whole enum
            // (data_b == 0) is not.
            .enum_type => s.dataB(id) & enum_member_fresh != 0,
            else => false,
        };
    }

    /// The non-fresh (annotation-equivalent) variant of a literal type.
    pub fn regularLiteral(s: *Store, id: TypeId) Error!TypeId {
        if (!s.isFreshLiteral(id)) return id;
        return switch (s.kind(id)) {
            .string_literal => s.makeStringLiteral(s.dataA(id), false),
            .bigint_literal => s.makeBigIntLiteral(s.dataA(id), false),
            .bool_true => true_type,
            .bool_false => false_type,
            .number_literal_fresh => s.internType(.number_literal, &.{ s.dataA(id), s.dataB(id) }, 0),
            .enum_type => s.internType(.enum_type, &.{ s.dataA(id), s.dataB(id) & ~enum_member_fresh }, 0),
            else => unreachable,
        };
    }

    /// Whether `id` is a *unit* type — one that denotes a single value and can
    /// therefore serve as a discriminant / narrowing target: a literal, or an
    /// enum member. Enum members need their own arm because their base (the
    /// whole enum) has to be interned and `literalBase` cannot allocate.
    pub fn isLiteralLike(s: *const Store, id: TypeId) bool {
        return s.literalBase(id) != no_type or s.isEnumMember(id);
    }

    /// Base primitive of a literal type, or `no_type` for non-literals.
    pub fn literalBase(s: *const Store, id: TypeId) TypeId {
        return switch (s.kind(id)) {
            .string_literal => string_type,
            .number_literal, .number_literal_fresh => number_type,
            .bigint_literal => bigint_type,
            .bool_true, .bool_false => boolean_type,
            // A template-literal pattern and a string-transform intrinsic are
            // subtypes of `string` — so `` `a${string}` `` / `Uppercase<T>` are
            // assignable to `string` (and absorbed by `string` in a union).
            .template_literal_type, .string_mapping => string_type,
            else => no_type,
        };
    }

    // --- interning ------------------------------------------------------------

    /// Shape words for hashing/equality. For inline-payload kinds the
    /// caller-provided buffer receives (a, b); for extra-payload kinds the
    /// stored extra words are returned.
    fn shapeWords(s: *const Store, id: TypeId, buf: *[2]u32) []const u32 {
        // Only ever called on an id this store *owns* (its intern map holds
        // only local ids for an overlay, only base ids for a base), so the
        // extra-array offsets below index `s.extra` correctly. `s.kind` still
        // dispatches so overlay ids index the local `kinds` array.
        const a = s.dataA(id);
        const b = s.dataB(id);
        switch (s.kind(id)) {
            .union_type, .intersection, .overloads => return s.extra.items[a..b],
            .tuple => return s.extra.items[a .. a + 2 * b],
            .object => {
                // A callable object has 2 extra header words plus one
                // TypeId per call/construct signature after the property
                // records; all part of the identity shape.
                if (s.extra.items[a] & obj_flag_has_sigs != 0) {
                    const sig_words = s.extra.items[a + 3] + s.extra.items[a + 4];
                    return s.extra.items[a .. a + 5 + 3 * b + sig_words];
                }
                return s.extra.items[a .. a + 3 + 3 * b];
            },
            .function => {
                const tpc = s.extra.items[a + 2];
                // A predicate function (`x is T` / `asserts x`) stores 3 extra
                // words after the params; they are part of the type's identity,
                // so include them in the shape or two guards differing only in
                // the predicate would hash-cons together.
                const pred: u32 = if (s.extra.items[a] & fn_flag_predicate != 0) 3 else 0;
                // A `this`-parameter type is one trailing word after the
                // predicate; part of the identity so two signatures differing
                // only in the `this` type do not hash-cons together.
                const thisw: u32 = if (s.extra.items[a] & fn_flag_this != 0) 1 else 0;
                return s.extra.items[a .. a + 3 + tpc + 3 * b + pred + thisw];
            },
            .ref => return s.extra.items[a .. a + 1 + b],
            .conditional => return s.extra.items[a .. a + 4],
            .mapped => return s.extra.items[a .. a + 6],
            .template_literal_type => return s.extra.items[a .. a + 1 + 2 * b],
            else => {
                buf[0] = a;
                buf[1] = b;
                return buf[0..2];
            },
        }
    }

    /// The hash-cons key of a shape, stored per type in `shape_hash`. It is a
    /// u32 rather than Wyhash's u64 so the side table costs 4 bytes per type
    /// instead of 8; over 2.5 M types that is ~1,800 accidental collisions in
    /// the whole run, each costing one extra `eql` — against 10 MB saved.
    fn hashShape32(kind_: Kind, words: []const u32) u32 {
        var h = std.hash.Wyhash.init(@intFromEnum(kind_));
        h.update(std.mem.sliceAsBytes(words));
        return @truncate(h.final());
    }

    /// Widen a stored 32-bit shape hash into the 64-bit value the hash map
    /// consumes. `std.HashMapUnmanaged` takes its 7-bit slot fingerprint from
    /// the TOP bits and its bucket index from the BOTTOM ones, so duplicating
    /// the word keeps the two independent (they come from opposite ends of the
    /// same well-mixed u32). Every producer of a map hash — candidate and
    /// stored key alike — goes through here, so the two always agree.
    inline fn spreadHash(h: u32) u64 {
        return (@as(u64, h) << 32) | @as(u64, h);
    }

    const MapCtx = struct {
        store: *const Store,
        /// Read back the key computed when the type was interned. This is the
        /// map's rehash path (`grow`), which touches every stored key; see
        /// `shape_hash` for why re-deriving them was worth removing.
        pub fn hash(ctx: MapCtx, id: TypeId) u64 {
            return spreadHash(ctx.store.shape_hash.items[id - ctx.store.base_len]);
        }
        pub fn eql(ctx: MapCtx, x: TypeId, y: TypeId) bool {
            if (x == y) return true;
            if (ctx.store.kind(x) != ctx.store.kind(y)) return false;
            var bx: [2]u32 = undefined;
            var by: [2]u32 = undefined;
            const wx = ctx.store.shapeWords(x, &bx);
            const wy = ctx.store.shapeWords(y, &by);
            return std.mem.eql(u32, wx, wy);
        }
    };

    const PendingCtx = struct {
        store: *const Store,
        kind: Kind,
        words: []const u32,
        /// Precomputed by `internType`. The candidate is looked up in TWO maps
        /// (the frozen base's and this store's own) and Wyhashing its whole
        /// payload once per lookup was ~6% of immich's check phase on its own.
        h: u32,
        pub fn hash(ctx: PendingCtx, _: void) u64 {
            return spreadHash(ctx.h);
        }
        pub fn eql(ctx: PendingCtx, _: void, existing: TypeId) bool {
            if (ctx.store.kind(existing) != ctx.kind) return false;
            var buf: [2]u32 = undefined;
            const w = ctx.store.shapeWords(existing, &buf);
            return std.mem.eql(u32, ctx.words, w);
        }
    };

    /// Intern a type whose payload words are in `words`. For inline kinds
    /// words = [a, b]; for extra kinds words are appended to `extra` on miss.
    fn internType(s: *Store, kind_: Kind, words: []const u32, b_count: u32) Error!TypeId {
        std.debug.assert(!s.frozen);
        // ONE hash for the whole call: the candidate is looked up in the base's
        // map and then in this store's own, and the two agree on the key by
        // construction (`spreadHash` of the same `hashShape32`).
        const h = hashShape32(kind_, words);
        // Probe the frozen base first: a type structurally identical to a base
        // type resolves to the shared *base* id (no overlay duplication). The
        // candidate `words` reference only sub-ids that are integer-equal to
        // the base type's, so the raw-word hash/equality carries across stores.
        //
        // Skipped outright when the base holds no shape this candidate could
        // equal — see `base_kind_words`.
        if (s.base) |base| {
            const cap = base.base_kind_words[@intFromEnum(kind_)];
            if (cap != 0 and words.len <= cap) {
                if (base.map.getKeyAdapted(
                    @as(void, {}),
                    PendingCtx{ .store = base, .kind = kind_, .words = words, .h = h },
                )) |base_id| return base_id;
            }
        }
        const gop = try s.map.getOrPutContextAdapted(
            s.alloc,
            @as(void, {}),
            PendingCtx{ .store = s, .kind = kind_, .words = words, .h = h },
            MapCtx{ .store = s },
        );
        if (gop.found_existing) return gop.key_ptr.*;

        // New overlay ids start at `base_len`; base ids at 0 (base_len == 0).
        const id: TypeId = s.base_len + @as(u32, @intCast(s.kinds.items.len));
        switch (kind_) {
            .union_type, .intersection, .overloads => {
                const start: u32 = @intCast(s.extra.items.len);
                try s.extra.appendSlice(s.alloc, words);
                try s.appendRaw(kind_, start, @intCast(s.extra.items.len), h);
            },
            .tuple, .object, .function, .ref, .conditional, .mapped, .template_literal_type => {
                const start: u32 = @intCast(s.extra.items.len);
                try s.extra.appendSlice(s.alloc, words);
                try s.appendRaw(kind_, start, b_count, h);
            },
            else => try s.appendRaw(kind_, words[0], words[1], h),
        }
        gop.key_ptr.* = id;
        return id;
    }

    // --- constructors -----------------------------------------------------------

    pub fn makeStringLiteral(s: *Store, atom: Atom, fresh: bool) Error!TypeId {
        return s.internType(.string_literal, &.{ atom, @intFromBool(fresh) }, 0);
    }

    pub fn makeNumberLiteral(s: *Store, value: f64, fresh: bool) Error!TypeId {
        const bits: u64 = @bitCast(value);
        const k: Kind = if (fresh) .number_literal_fresh else .number_literal;
        return s.internType(k, &.{ @truncate(bits), @intCast(bits >> 32) }, 0);
    }

    pub fn makeBigIntLiteral(s: *Store, atom: Atom, fresh: bool) Error!TypeId {
        return s.internType(.bigint_literal, &.{ atom, @intFromBool(fresh) }, 0);
    }

    pub fn makeBooleanLiteral(s: *Store, value: bool, fresh: bool) Error!TypeId {
        if (!fresh) return if (value) true_type else false_type;
        return s.internType(if (value) .bool_true else .bool_false, &.{ 0, 1 }, 0);
    }

    pub fn makeArray(s: *Store, elem: TypeId) Error!TypeId {
        return s.internType(.array, &.{ elem, 0 }, 0);
    }

    /// `readonly T[]` / `ReadonlyArray<T>`. Interned apart from `T[]` and
    /// carrying the SAME members (the global `Array` interface) — the flag is
    /// data, deliberately invisible to the assignability relation, exactly as
    /// `elem_flag_readonly` is for tuples. Its one consumer is the type
    /// predicate narrowing in `narrowByInstance`, which mirrors tsc's SUBTYPE
    /// filter: a `readonly T[]` is not a subtype of a mutable `U[]` (it has no
    /// `push`), so `Array.isArray(x)` on a readonly array narrows to the
    /// guard's `any[]` rather than to `x`'s own type.
    pub fn makeArrayReadonly(s: *Store, elem: TypeId) Error!TypeId {
        return s.internType(.array, &.{ elem, 1 }, 0);
    }

    pub fn arrayIsReadonly(s: *const Store, id: TypeId) bool {
        return s.dataB(id) != 0;
    }

    /// Rebuild an array with `src`'s readonly-ness — used by every
    /// substitution path so the flag survives instantiation.
    pub fn makeArrayLike(s: *Store, src: TypeId, elem: TypeId) Error!TypeId {
        return s.internType(.array, &.{ elem, s.dataB(src) }, 0);
    }

    pub fn makeTypeParam(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.type_param, &.{ symbol, 0 }, 0);
    }

    pub fn makeClassValue(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.class_value, &.{ symbol, 0 }, 0);
    }

    pub fn makeEnumType(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.enum_type, &.{ symbol, 0 }, 0);
    }

    /// The member type `E.<name>` of enum `symbol` (see `Kind.enum_type`).
    pub fn makeEnumMember(s: *Store, symbol: u32, name: Atom, fresh: bool) Error!TypeId {
        std.debug.assert(name != 0 and name & enum_member_fresh == 0);
        return s.internType(.enum_type, &.{ symbol, if (fresh) name | enum_member_fresh else name }, 0);
    }

    pub fn makeUniqueSymbol(s: *Store, id: u32) Error!TypeId {
        return s.internType(.unique_symbol, &.{ id, 0 }, 0);
    }

    pub fn makeTuple(s: *Store, elems: []const TupleElem) Error!TypeId {
        // tsc's `createNormalizedTupleType`: a REST element whose type is
        // itself a TUPLE contributes that tuple's elements positionally, so
        // `[...[A, B], C]` IS `[A, B, C]` — and, the case that reaches this
        // constantly, `[...[], K]` IS `[K]`.
        //
        // Instantiation is where it bites. bluesky's storage API declares
        // `set<Key extends keyof Schema>(scopes: [...Scopes, Key], …)` on a
        // `Storage<Scopes extends unknown[], Schema>`, and the device store is
        // a `Storage<[], Device>`: substituting `Scopes := []` left a
        // TWO-element tuple whose first element was an empty tuple spread.
        // Position 0 then reads as `never` (an empty tuple has no element
        // type), so every `device.get(['fontScale'])` in the app was
        // "Type '"fontScale"' is not assignable to type 'never'".
        //
        // Splicing here rather than in the instantiation arm covers every
        // construction site at once, and it terminates: an inner tuple was
        // itself built through this function, so its own rest elements are
        // already arrays or unresolved type params, never tuples.
        for (elems) |e| {
            if ((e.flags & elem_flag_rest) == 0 or s.kind(e.ty) != .tuple) continue;
            var out: std.ArrayList(TupleElem) = .empty;
            defer out.deinit(s.alloc);
            for (elems) |el| {
                if ((el.flags & elem_flag_rest) != 0 and s.kind(el.ty) == .tuple) {
                    for (0..s.tupleLen(el.ty)) |i| {
                        const inner = s.tupleElem(el.ty, @intCast(i));
                        // A `readonly` spread makes what it splices in
                        // readonly (tsc carries the modifier onto each
                        // spliced element); the inner element keeps its own
                        // optional/rest position.
                        try out.append(s.alloc, .{
                            .ty = inner.ty,
                            .flags = inner.flags | (el.flags & elem_flag_readonly),
                        });
                    }
                } else try out.append(s.alloc, el);
            }
            return s.makeTuple(out.items);
        }
        // tsc's `getTupleTargetType`: "[...X[]] is equivalent to just X[]".
        // A tuple whose ONLY element is a rest element already spelled as an
        // array (or a readonly array) is that array — there is no positional
        // information left for the tuple form to carry. It matters wherever a
        // parameter list is reified: `Parameters<(...args: any[]) => void>`
        // came back `[...any[]]`, and `ReadonlyArray<infer E>` then inferred
        // `E = any[]` instead of `any`, which is how socket.io's
        // `Last<Parameters<Map[K]>>` stopped being `any` and its whole
        // `IsAny<…>` chain stopped reducing.
        if (elems.len == 1 and (elems[0].flags & elem_flag_rest) != 0 and
            s.kind(elems[0].ty) == .array)
        {
            return elems[0].ty;
        }
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        for (elems) |e| {
            try s.pending.append(s.alloc, e.ty);
            try s.pending.append(s.alloc, e.flags);
        }
        return s.internType(.tuple, s.pending.items[start..], @intCast(elems.len));
    }

    /// `props` must not contain duplicate names; they are sorted here.
    pub fn makeObject(
        s: *Store,
        props: []const Prop,
        string_index: TypeId,
        number_index: TypeId,
        flags: u32,
    ) Error!TypeId {
        return s.makeObjectSigs(props, string_index, number_index, flags, &.{}, &.{});
    }

    /// A hybrid callable object: an object with call and/or construct
    /// signature lists (each an interned `.function` type) alongside its
    /// properties. With empty sig lists this is exactly `makeObject`, and the
    /// `obj_flag_has_sigs` bit stays clear so sig-less objects pay no extra
    /// words. Signature order is preserved (overload resolution is
    /// declaration-order sensitive); properties are still name-sorted.
    pub fn makeObjectSigs(
        s: *Store,
        props: []const Prop,
        string_index: TypeId,
        number_index: TypeId,
        flags0: u32,
        call_sigs: []const TypeId,
        construct_sigs: []const TypeId,
    ) Error!TypeId {
        const has_sigs = call_sigs.len != 0 or construct_sigs.len != 0;
        const flags = if (has_sigs) flags0 | obj_flag_has_sigs else flags0 & ~obj_flag_has_sigs;
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.append(s.alloc, flags);
        try s.pending.append(s.alloc, string_index);
        try s.pending.append(s.alloc, number_index);
        if (has_sigs) {
            try s.pending.append(s.alloc, @intCast(call_sigs.len));
            try s.pending.append(s.alloc, @intCast(construct_sigs.len));
        }
        const pstart = s.pending.items.len;
        for (props) |p| {
            try s.pending.append(s.alloc, p.name);
            try s.pending.append(s.alloc, p.ty);
            try s.pending.append(s.alloc, p.flags);
        }
        // Sort the 3-word property records by name atom.
        sortTriples(s.pending.items[pstart..]);
        // Signatures trail the properties in declaration order.
        try s.pending.appendSlice(s.alloc, call_sigs);
        try s.pending.appendSlice(s.alloc, construct_sigs);
        return s.internType(.object, s.pending.items[start..], @intCast(props.len));
    }

    /// The regular (non-fresh) variant of a fresh object literal type. The
    /// literal ORIGIN (`obj_flag_literal_origin`) survives — tsc's
    /// `getRegularTypeOfObjectLiteral` clears `FreshLiteral` and keeps
    /// `ObjectLiteral`.
    pub fn regular(s: *Store, id: TypeId) Error!TypeId {
        if (!s.objectIsFresh(id)) return id;
        return s.clearObjFlags(id, obj_flag_fresh);
    }

    /// The WIDENED variant of an object literal type: both its freshness and
    /// its literal origin are gone, because tsc's `getWidenedTypeOfObjectLiteral`
    /// builds a new anonymous type carrying neither flag. This is what a
    /// mutable location (`const x = { … }`) and an inference result are widened
    /// to, and it is what stops a widened literal from re-entering the
    /// object-literal candidate union at a later call.
    pub fn widenedObject(s: *Store, id: TypeId) Error!TypeId {
        if (s.kind(id) != .object) return id;
        if (s.objectFlags(id) & (obj_flag_fresh | obj_flag_literal_origin) == 0) return id;
        return s.clearObjFlags(id, obj_flag_fresh | obj_flag_literal_origin);
    }

    fn clearObjFlags(s: *Store, id: TypeId, mask: u32) Error!TypeId {
        const a = s.dataA(id);
        const n = s.dataB(id);
        // The fresh object may live in the frozen base; read its shape words
        // from the owning store (base ids carry base-relative extra offsets).
        const own = if (id < s.base_len) s.base.? else s;
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        // Copy the whole shape (header + props + any call/construct sigs).
        const len: u32 = if (own.extra.items[a] & obj_flag_has_sigs != 0)
            5 + 3 * n + own.extra.items[a + 3] + own.extra.items[a + 4]
        else
            3 + 3 * n;
        try s.pending.appendSlice(s.alloc, own.extra.items[a .. a + len]);
        s.pending.items[start] &= ~mask;
        return s.internType(.object, s.pending.items[start..], n);
    }

    pub fn makeFunction(
        s: *Store,
        params: []const Param,
        ret: TypeId,
        type_params: []const u32,
        flags: u32,
    ) Error!TypeId {
        return s.makeFunctionPred(params, ret, type_params, flags, null);
    }

    pub fn makeFunctionPred(
        s: *Store,
        params: []const Param,
        ret: TypeId,
        type_params: []const u32,
        flags0: u32,
        pred: ?Predicate,
    ) Error!TypeId {
        return s.makeFunctionThis(params, ret, type_params, flags0, pred, 0);
    }

    pub fn makeFunctionThis(
        s: *Store,
        params: []const Param,
        ret: TypeId,
        type_params: []const u32,
        flags0: u32,
        pred: ?Predicate,
        this_ty: TypeId,
    ) Error!TypeId {
        // Invariant: the predicate flag is set exactly when predicate words are
        // appended. A caller may pass `flags0` copied from a predicate source
        // (e.g. signature instantiation) while supplying no predicate — clear
        // the bit so it never claims words that are not there. The `this` flag
        // is likewise kept in lockstep with the trailing `this` word.
        var flags = if (pred != null) flags0 | fn_flag_predicate else flags0 & ~fn_flag_predicate;
        flags = if (this_ty != 0) flags | fn_flag_this else flags & ~fn_flag_this;
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.append(s.alloc, flags);
        try s.pending.append(s.alloc, ret);
        try s.pending.append(s.alloc, @intCast(type_params.len));
        try s.pending.appendSlice(s.alloc, type_params);
        for (params) |p| {
            try s.pending.append(s.alloc, p.name);
            try s.pending.append(s.alloc, p.ty);
            try s.pending.append(s.alloc, p.flags);
        }
        if (pred) |pr| {
            try s.pending.append(s.alloc, @intFromBool(pr.asserts));
            try s.pending.append(s.alloc, pr.param);
            try s.pending.append(s.alloc, pr.ty);
        }
        if (this_ty != 0) try s.pending.append(s.alloc, this_ty);
        return s.internType(.function, s.pending.items[start..], @intCast(params.len));
    }

    pub fn makeThisType(s: *Store, instance_ref: TypeId) Error!TypeId {
        return s.internType(.this_type, &.{ instance_ref, 0 }, 0);
    }

    /// `is_ref` distinguishes a bare mention of an already-declared binder
    /// from the `infer V` declaration — see `infer_var_reference`.
    pub fn makeInferVar(s: *Store, id: u32, name: Atom, is_ref: bool) Error!TypeId {
        const payload = if (is_ref) id | infer_var_reference else id;
        return s.internType(.infer_var, &.{ payload, name }, 0);
    }

    /// Intern a deferred conditional type. `distributive` records that the
    /// check type was originally a naked type parameter (so it distributes
    /// over a union once the substitution supplies one).
    pub fn makeConditional(s: *Store, check: TypeId, extends: TypeId, true_ty: TypeId, false_ty: TypeId, distributive: bool) Error!TypeId {
        const flags: u32 = if (distributive) cond_flag_distributive else 0;
        return s.internType(.conditional, &.{ check, extends, true_ty, false_ty }, flags);
    }

    pub fn makeMappedParam(s: *Store, id: u32, name: Atom) Error!TypeId {
        return s.internType(.mapped_param, &.{ id, name }, 0);
    }

    pub fn makeIndexAccess(s: *Store, obj: TypeId, idx: TypeId) Error!TypeId {
        return s.internType(.index_access, &.{ obj, idx }, 0);
    }

    pub fn makeKeyof(s: *Store, operand: TypeId) Error!TypeId {
        return s.internType(.keyof_op, &.{ operand, 0 }, 0);
    }

    /// Intern a deferred mapped type. `flags` carries the modifier bits and the
    /// homomorphic marker; it is stored both in `data_b` and (via the last
    /// word) in the identity payload so two mapped types differing only in a
    /// modifier do not hash-cons together.
    pub fn makeMapped(s: *Store, key_param: TypeId, constraint: TypeId, value: TypeId, as_clause: TypeId, source: TypeId, flags: u32) Error!TypeId {
        return s.internType(.mapped, &.{ key_param, constraint, value, as_clause, source, flags }, flags);
    }

    /// Intern a deferred/pattern template-literal type. `holes[i]` is the type
    /// of the i-th interpolation and `chunks[i]` the literal text following it;
    /// `head` is the literal before the first hole. `holes.len == chunks.len`.
    pub fn makeTemplateLiteral(s: *Store, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
        std.debug.assert(holes.len == chunks.len);
        const n = holes.len;
        const words = try s.alloc.alloc(u32, 1 + 2 * n);
        defer s.alloc.free(words);
        words[0] = head;
        for (0..n) |i| {
            words[1 + 2 * i] = holes[i];
            words[2 + 2 * i] = chunks[i];
        }
        return s.internType(.template_literal_type, words, @intCast(n));
    }

    pub fn makeStringMapping(s: *Store, kind_idx: u32, arg: TypeId) Error!TypeId {
        return s.internType(.string_mapping, &.{ kind_idx, arg }, 0);
    }

    pub fn makeOverloads(s: *Store, fns: []const TypeId) Error!TypeId {
        if (fns.len == 1) return fns[0];
        return s.internType(.overloads, fns, 0);
    }

    pub fn makeRef(s: *Store, symbol: u32, args: []const TypeId) Error!TypeId {
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.append(s.alloc, symbol);
        try s.pending.appendSlice(s.alloc, args);
        return s.internType(.ref, s.pending.items[start..], @intCast(args.len));
    }

    /// Canonical union of `parts` (see module docs for the rules).
    /// `scratch` is used for the worklist; the result is interned.
    pub fn makeUnion(s: *Store, scratch: Allocator, parts: []const TypeId) Error!TypeId {
        var flat: std.ArrayList(TypeId) = .empty;
        defer flat.deinit(scratch);
        var has_unknown = false;
        for (parts) |p| {
            if (try s.unionFlatten(scratch, &flat, p, &has_unknown)) return any_type;
        }
        if (has_unknown) return unknown_type;

        const items = flat.items;
        std.mem.sort(TypeId, items, {}, std.sort.asc(TypeId));
        // Dedup in place.
        var n: usize = 0;
        for (items) |t| {
            if (n > 0 and items[n - 1] == t) continue;
            items[n] = t;
            n += 1;
        }
        var list = items[0..n];

        // true | false -> boolean (fresh or regular variants).
        var saw_true = false;
        var saw_false = false;
        for (list) |t| {
            if (s.kind(t) == .bool_true) saw_true = true;
            if (s.kind(t) == .bool_false) saw_false = true;
        }
        if (saw_true and saw_false) {
            var w: usize = 0;
            var saw_boolean = false;
            for (list) |t| {
                if (s.kind(t) == .bool_true or s.kind(t) == .bool_false) continue;
                if (t == boolean_type) saw_boolean = true;
                list[w] = t;
                w += 1;
            }
            if (!saw_boolean) {
                list[w] = boolean_type;
                w += 1;
            }
            list = list[0..w];
            std.mem.sort(TypeId, list, {}, std.sort.asc(TypeId));
        }

        // Literal types absorbed by their base primitive when present.
        const has_string = indexOf(list, string_type) != null;
        const has_number = indexOf(list, number_type) != null;
        const has_boolean = indexOf(list, boolean_type) != null;
        const has_bigint = indexOf(list, bigint_type) != null;
        if (has_string or has_number or has_boolean or has_bigint) {
            var w: usize = 0;
            for (list) |t| {
                const absorbed = switch (s.kind(t)) {
                    .string_literal => has_string,
                    .number_literal, .number_literal_fresh => has_number,
                    .bigint_literal => has_bigint,
                    .bool_true, .bool_false => has_boolean,
                    else => false,
                };
                if (absorbed) continue;
                list[w] = t;
                w += 1;
            }
            list = list[0..w];
        }

        // `X & {}` next to `X` is absorbed by it. Every value of `X & {}` is a
        // value of `X`, so the union is just `X` — tsc reaches the same answer
        // through subtype reduction, which drops any constituent that is a
        // subtype of another. This is the one shape that reduction MUST cover
        // here: `& {}` is the marker narrowing puts on a type it has taken the
        // nullish arm off without being able to rewrite it (a bare type
        // parameter, a deferred conditional or indexed access), so a function
        // that returns the guarded value on one path and the unguarded one on
        // another infers `X & {} | X`. Left in place that union has no apparent
        // members in common with `X` for property lookup to find.
        var has_marked = false;
        for (list) |t| {
            if (s.kind(t) == .intersection and indexOf(s.members(t), empty_object_type) != null) {
                has_marked = true;
                break;
            }
        }
        if (has_marked) {
            var w: usize = 0;
            for (list) |t| {
                if (s.strippedEmptyObject(t)) |base| {
                    if (indexOf(list, base) != null) continue;
                }
                list[w] = t;
                w += 1;
            }
            list = list[0..w];
        }

        if (list.len == 0) return never_type;
        if (list.len == 1) return list[0];
        return s.internType(.union_type, list, 0);
    }

    /// `X & {}` -> `X`, for a two-member intersection with the empty object
    /// type as one member. Null for anything else, including a longer
    /// intersection: `X & Y & {}` is not `X & Y`'s duplicate in a union unless
    /// that whole intersection is itself a constituent, which the caller
    /// cannot check without interning a new type.
    fn strippedEmptyObject(s: *Store, t: TypeId) ?TypeId {
        if (s.kind(t) != .intersection) return null;
        const ms = s.members(t);
        if (ms.len != 2) return null;
        if (ms[0] == empty_object_type) return ms[1];
        if (ms[1] == empty_object_type) return ms[0];
        return null;
    }

    fn unionFlatten(
        s: *Store,
        scratch: Allocator,
        out: *std.ArrayList(TypeId),
        t: TypeId,
        has_unknown: *bool,
    ) Error!bool {
        switch (s.kind(t)) {
            .any, .err => return true,
            .unknown => {
                has_unknown.* = true;
                return false;
            },
            .never => return false,
            .union_type => {
                for (s.members(t)) |m| {
                    if (try s.unionFlatten(scratch, out, m, has_unknown)) return true;
                }
                return false;
            },
            .none => return false,
            else => {
                try out.append(scratch, t);
                return false;
            },
        }
    }

    /// Ceiling on the number of constituents a distributed intersection may
    /// produce (tsc's `checkCrossProductUnion` limit). Past it we keep the
    /// undistributed intersection rather than tsc's hard error — the
    /// under-report policy — so a pathological shape degrades instead of
    /// exploding the type store.
    const max_cross_product: usize = 100_000;

    /// Canonical intersection (flatten, dedup; unknown dropped; never/any
    /// absorbing; empty -> unknown; single -> unwrapped).
    ///
    /// Member order is the order the members were WRITTEN — the first
    /// occurrence of each, after flattening nested intersections in place.
    /// tsc's `getIntersectionType` does the same (`addTypeToIntersection`
    /// appends into an insertion-ordered map; only `getUnionType` sorts), and
    /// the order is observable: `getSignaturesOfType` on an intersection
    /// concatenates its constituents' call signatures in member order, so the
    /// order decides which overload a call matches first. Sorting by TypeId
    /// made that order a function of this checker's *interning* sequence,
    /// which is a function of which files it owns — so `window.setTimeout`
    /// answered lib.dom's `number` or @types/node's `Timeout` depending on
    /// the `--checkers` partition. Written order is program-canonical, so the
    /// answer is not.
    ///
    /// The cost is that `A & B` and `B & A` are now distinct TypeIds, exactly
    /// as they are in tsc (mutually assignable, structurally compared).
    ///
    /// A union constituent is *distributed*: `(A | B) & C` becomes
    /// `(A & C) | (B & C)`, recursively for further unions (tsc's
    /// `getIntersectionType` / `getCrossProductIntersections`). Keeping the
    /// union outermost is what lets discriminant narrowing, assignability and
    /// property lookup — all of which already handle unions — see through the
    /// shape. The resulting *union* is canonical (`makeUnion` sorts), but the
    /// cross-product members keep the operand order they were built from.
    pub fn makeIntersection(s: *Store, scratch: Allocator, parts: []const TypeId) Error!TypeId {
        return s.makeIntersectionFlags(scratch, parts, true);
    }

    /// `makeIntersection` with tsc's `IntersectionFlags.NoSupertypeReduction`:
    /// the `{}` constituent is KEPT. Used only by the intersection *type node*
    /// path for the `X & {}` / `{} & X` idiom (see `emptyObjectSupertypeOf`).
    pub fn makeIntersectionNoReduce(s: *Store, scratch: Allocator, parts: []const TypeId) Error!TypeId {
        return s.makeIntersectionFlags(scratch, parts, false);
    }

    fn makeIntersectionFlags(s: *Store, scratch: Allocator, parts: []const TypeId, reduce_empty_object: bool) Error!TypeId {
        var flat: std.ArrayList(TypeId) = .empty;
        defer flat.deinit(scratch);
        for (parts) |p| {
            switch (s.kind(p)) {
                .never => return never_type,
                .any, .err => return any_type,
                .unknown, .none => {},
                .intersection => for (s.members(p)) |m| {
                    if (s.kind(m) == .never) return never_type;
                    if (s.kind(m) == .any or s.kind(m) == .err) return any_type;
                    try flat.append(scratch, m);
                },
                else => try flat.append(scratch, p),
            }
        }
        // Dedup keeping the FIRST occurrence, so the surviving order is the
        // written one. Quadratic, over a list that is two or three long in
        // every real program.
        const items = flat.items;
        var n: usize = 0;
        outer: for (items) |t| {
            for (items[0..n]) |seen| {
                if (seen == t) continue :outer;
            }
            items[n] = t;
            n += 1;
        }
        if (n == 0) return unknown_type;
        if (n == 1) return items[0];
        var list = items[0..n];
        if (nullishIntersectionIsEmpty(s, list)) return never_type;
        if (distinctUnitIntersectionIsEmpty(s, list)) return never_type;
        if (disjointDomainIntersectionIsEmpty(s, list)) return never_type;
        if (discriminantIntersectionIsEmpty(s, list)) return never_type;

        // tsc's `removeRedundantPrimitiveTypes`: a base primitive is dropped
        // when a LITERAL of the same primitive is in the intersection, so
        // `"a" & string` IS `"a"`. Without it the pair stayed live and the
        // `keyof M & (string | symbol)` key-filter idiom produced
        // `("a" & string) | ("b" & string)`, which then indexed nothing —
        // socket.io's `EventNames` is written exactly that way and every
        // `Map[EventNames<Map>]` downstream of it collapsed.
        //
        // An ENUM member is left out: its primitive domain follows its VALUE,
        // which the store cannot read.
        {
            var lit: u32 = 0;
            for (list) |t| lit |= switch (s.kind(t)) {
                .string_literal, .template_literal_type, .string_mapping => @as(u32, 1),
                .number_literal, .number_literal_fresh => 2,
                .bigint_literal => 4,
                .unique_symbol => 8,
                .undefined => 16,
                .bool_true, .bool_false => 32,
                else => 0,
            };
            if (lit != 0) {
                var w: usize = 0;
                for (list) |t| {
                    const drop = switch (s.kind(t)) {
                        .string => lit & 1 != 0,
                        .number => lit & 2 != 0,
                        .bigint => lit & 4 != 0,
                        .symbol => lit & 8 != 0,
                        .void => lit & 16 != 0,
                        .boolean => lit & 32 != 0,
                        else => false,
                    };
                    if (drop) continue;
                    list[w] = t;
                    w += 1;
                }
                list = list[0..w];
                if (list.len == 0) return unknown_type;
                if (list.len == 1) return list[0];
            }
        }

        // Supertype reduction against `{}` (tsc's `getIntersectionType`): `{}`
        // is a supertype of every non-nullish type, so `X & {}` IS `X` and the
        // `{}` constituent is dropped. `NonNullable<T>` is spelled `T & {}`, so
        // without this every `NonNullable<X>` for a concrete `X` stayed a
        // two-member intersection — which reads as an OBJECT type, flipping
        // `X extends object` from false to true (react-hook-form's
        // `DeepRequired<T>` = `{ [K in keyof T]-?: NonNullable<DeepRequired<T[K]>> }`
        // made every `string` field an object, so `FieldErrorsImpl` took its
        // `Merge<FieldError, …>` arm and every `FieldErrors<Form>` value read
        // as `unknown`).
        if (reduce_empty_object) {
            if (indexOf(list, empty_object_type)) |ei| {
                var reduce = false;
                for (list, 0..) |t, i| {
                    if (i == ei) continue;
                    if (emptyObjectSupertypeOf(s.kind(t))) {
                        reduce = true;
                        break;
                    }
                }
                if (reduce) {
                    var w: usize = 0;
                    for (list, 0..) |t, i| {
                        if (i == ei) continue;
                        list[w] = t;
                        w += 1;
                    }
                    list = list[0..w];
                    if (list.len == 1) return list[0];
                }
            }
        }

        // tsc's `extractIrreducible`, which runs BEFORE the cross product and
        // factors a nullish constituent out of the whole intersection instead
        // of multiplying it through: when EVERY member is a union that
        // contains `undefined` (then, separately, `null`), the nullish half is
        // irreducible — it survives no product with any other member — so
        // `(A | null) & (B | null)` is `(A & B) | null` and not the
        // four-way product `A & B | A & null | null & B | null`.
        //
        // This is not only a spelling: `nullishIntersectionIsEmpty` is
        // deliberately syntactic and cannot reduce `null & <ref>`, so the
        // products it leaves standing are live garbage constituents. kysely's
        // `deletedAt` is exactly that shape — a CTE that shadows its own table
        // intersects `Timestamp | null` with `Date | null`, and the surviving
        // `null & Date` made `SelectType<…>` distribute onto a constituent
        // that matched `ColumnType<infer S, …>` while inferring nothing, so
        // the column came out `unknown`.
        for ([_]Kind{ .undefined, .null }) |nullish| {
            var all = true;
            for (list) |t| {
                if (s.kind(t) != .union_type or indexOfKind(s, s.members(t), nullish) == null) {
                    all = false;
                    break;
                }
            }
            if (!all) continue;
            const rest = try scratch.alloc(TypeId, list.len);
            defer scratch.free(rest);
            for (list, 0..) |t, i| rest[i] = try s.filterOutKind(scratch, t, nullish);
            const core = try s.makeIntersectionFlags(scratch, rest, reduce_empty_object);
            return s.makeUnion(scratch, &.{ core, if (nullish == .null) null_type else undefined_type });
        }

        // Distribute over the first union constituent, if any.
        var union_idx: usize = list.len;
        var size: usize = 1;
        for (list, 0..) |t, i| {
            if (s.kind(t) != .union_type) continue;
            if (union_idx == list.len) union_idx = i;
            size *|= s.members(t).len;
        }
        if (union_idx != list.len and size <= max_cross_product) {
            // `members` dangles once the recursion interns anything.
            const um = try scratch.dupe(TypeId, s.members(list[union_idx]));
            defer scratch.free(um);
            var out: std.ArrayList(TypeId) = .empty;
            defer out.deinit(scratch);
            try out.ensureTotalCapacityPrecise(scratch, um.len);
            const combo = try scratch.dupe(TypeId, list);
            defer scratch.free(combo);
            for (um) |m| {
                combo[union_idx] = m;
                out.appendAssumeCapacity(try s.makeIntersection(scratch, combo));
            }
            return s.makeUnion(scratch, out.items);
        }
        return s.internType(.intersection, list, 0);
    }

    /// Kinds that are provably SUBTYPES of `{}` — every value of one is a
    /// value of the empty object type — so an intersection containing one of
    /// them absorbs an `{}` constituent (tsc's supertype reduction in
    /// `getIntersectionType`). Every object-ish kind and every primitive
    /// except the nullish domain qualifies; `void` does NOT (`void & {}` has
    /// no reduction in tsc either).
    ///
    /// `.ref` (interface / class instance / lazy generic-alias instance) is on
    /// the list: an interface or class instance is never nullish, and a lazy
    /// alias ref is the spelling `NonNullable<Recursive<X>>` leaves behind —
    /// the one this reduction has to see through. `null`/`undefined` are
    /// absent because `nullishIntersectionIsEmpty` already answers `never` for
    /// them. Deliberately syntactic, like every other rule in this store: the
    /// still-generic kinds (`.type_param`, `.conditional`, `.index_access`,
    /// `.keyof_op`, `.mapped`, `.infer_var`, `.this_type`) are NOT reduced —
    /// `T & {}` for an unconstrained `T` is a real type in tsc *and* the
    /// marker ztsc's narrowing puts on a type it took the nullish arm off.
    fn emptyObjectSupertypeOf(k: Kind) bool {
        return switch (k) {
            .object,
            .array,
            .tuple,
            .function,
            .overloads,
            .class_value,
            .object_keyword,
            .ref,
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
            .enum_type,
            .unique_symbol,
            .template_literal_type,
            .string_mapping,
            => true,
            else => false,
        };
    }

    /// tsc's empty-intersection rule for the nullish domain
    /// (`getIntersectionType`): under `strictNullChecks`, an intersection that
    /// mixes `null`/`undefined` with a member of ANY other domain has no
    /// inhabitants and reduces to `never` — `null & {}`, `null & { a: 1 }`,
    /// `undefined & string`, `null & (() => void)`, and (both being distinct
    /// domains) `null & undefined` itself. Oracle-verified for objects,
    /// arrays, functions, every primitive, and `void`; `void & {}` is NOT
    /// empty and stays.
    ///
    /// Without it `NonNullable<T>` — spelled `T & {}` since TS 4.8 — leaves a
    /// `null & {}` constituent in the distributed union, so `NonNullable<FileId
    /// | null>` printed (and behaved as) `null & {} | FileId & {}` instead of
    /// `FileId`.
    ///
    /// Deliberately syntactic: a `.ref` / `.type_param` / conditional member
    /// could still resolve to an object, but this store has no checker to ask,
    /// and leaving those unreduced is the pre-existing (sound) behaviour. A
    /// `.union_type` member is likewise skipped — the cross-product below
    /// re-enters this function per combination, where the check applies.
    fn nullishIntersectionIsEmpty(s: *const Store, list: []const TypeId) bool {
        var has_null = false;
        var has_undefined = false;
        var has_other_domain = false;
        for (list) |t| {
            switch (s.kind(t)) {
                .null => has_null = true,
                .undefined => has_undefined = true,
                // Every domain that is provably disjoint from `null`/`undefined`.
                .object, .array, .tuple, .function, .overloads, .class_value, .object_keyword, .void, .string, .number, .boolean, .bigint, .symbol, .bool_true, .bool_false, .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .enum_type, .unique_symbol, .template_literal_type, .string_mapping => has_other_domain = true,
                else => {},
            }
        }
        if (!has_null and !has_undefined) return false;
        return has_other_domain or (has_null and has_undefined);
    }

    /// tsc's "two distinct unit types" rule (`addTypeToIntersection`: *"we have
    /// seen two distinct unit types which means we should reduce to an empty
    /// intersection"*). A unit type has exactly one value, so an intersection
    /// containing two different ones is uninhabited: `"line" & "arrow"`,
    /// `1 & 2`, `true & false` are all `never`.
    ///
    /// This is what makes a refining intersection collapse the way tsc's does:
    /// `ExcalidrawArrowElement = ExcalidrawLinearElement & { type: "arrow" }`
    /// distributes to `("line" & "arrow") | ("arrow" & "arrow")`, and without
    /// the rule the dead first arm survived — so an exhaustive `switch` over
    /// `element.type` left `"arrow" & "line"` in the default branch and
    /// `assertNever(type)` reported TS2345.
    ///
    /// Freshness is not part of a unit's identity here (a fresh and a regular
    /// `"a"` are one unit), which under-reports relative to tsc — it keys the
    /// set on the type object, where the two are distinct — and under-reporting
    /// is the safe direction for a rule whose output is `never`. Non-unit
    /// members (including `.union_type`, re-entered per combination by the
    /// cross-product below) are ignored.
    /// Identity of a UNIT type — one that denotes a single value — modulo
    /// literal freshness. Null for everything else. Two different keys are two
    /// different values, which is tsc's *"an intersection containing more than
    /// one unit type is empty"* rule.
    fn unitKey(s: *const Store, t: TypeId) ?[3]u32 {
        return switch (s.kind(t)) {
            .string_literal => .{ 1, s.dataA(t), 0 },
            .number_literal, .number_literal_fresh => .{ 2, s.dataA(t), s.dataB(t) },
            .bigint_literal => .{ 3, s.dataA(t), 0 },
            .bool_true => .{ 4, 0, 0 },
            .bool_false => .{ 5, 0, 0 },
            .unique_symbol => .{ 6, s.dataA(t), 0 },
            // An enum MEMBER is a unit type (tsc's "enum literal"); a whole
            // enum is not. A member is nominally distinct from the literal it
            // is initialized to — `E.X & "XV"` is empty in tsc — so the enum
            // symbol is part of the key.
            .enum_type => if (s.isEnumMember(t))
                .{ 7, s.dataA(t), s.dataB(t) & ~enum_member_fresh }
            else
                null,
            else => null,
        };
    }

    fn distinctUnitIntersectionIsEmpty(s: *const Store, list: []const TypeId) bool {
        var seen: ?[3]u32 = null;
        for (list) |t| {
            const key = unitKey(s, t) orelse continue;
            if (seen) |prev| {
                if (!std.mem.eql(u32, &prev, &key)) return true;
            } else seen = key;
        }
        return false;
    }

    /// tsc's `TypeFlags.DisjointDomains`: the primitive domains no value can
    /// belong to two of. `boolean` is deliberately absent — tsc leaves it out
    /// too — and so is `TypeFlags.Object`, which is why a branded
    /// `string & { __brand }` and `NonNullable<T>`'s `T & {}` survive.
    ///
    /// An enum has no bit: a member's domain follows its VALUE, which the
    /// store cannot read, so an enum-bearing intersection is left alone.
    fn disjointDomain(s: *const Store, t: TypeId) u32 {
        return switch (s.kind(t)) {
            .object_keyword => 1, // NonPrimitive
            .string, .string_literal, .template_literal_type, .string_mapping => 2,
            .number, .number_literal, .number_literal_fresh => 4,
            .bigint, .bigint_literal => 8,
            .symbol, .unique_symbol => 16,
            .void, .undefined => 32,
            .null => 64,
            else => 0,
        };
    }

    /// tsc's `getIntersectionType` emptiness rule for the primitive domains:
    /// *"a string-like type and a type known to be non-string-like, a
    /// number-like type and a type known to be non-number-like, …"* — i.e.
    /// two DIFFERENT disjoint domains make the intersection `never`.
    ///
    /// Without it `1 & string` stayed a live intersection, and the whole
    /// `IsAny<T> = 0 extends 1 & T ? …` family, plus every
    /// `keyof M & (string | symbol)` key filter, carried junk constituents
    /// (`"AppRestartV1" & symbol`) that poisoned every later indexed access.
    /// socket.io's `EventNames` / `EventNamesWithoutAck` are written that way.
    fn disjointDomainIntersectionIsEmpty(s: *const Store, list: []const TypeId) bool {
        var mask: u32 = 0;
        for (list) |t| {
            const d = disjointDomain(s, t);
            if (d == 0) continue;
            if (mask != 0 and mask != d) return true;
            mask |= d;
        }
        return false;
    }

    /// Whether two types denote provably DISJOINT sets of single values.
    ///
    /// Each side is a unit type or a union of them — the shape a discriminant
    /// has — and the answer is "no value satisfies both". `"c"` against
    /// `"a" | "b"` is disjoint, which is what tsc's `getIntersectionType`
    /// answers by distributing (`"c" & "a" | "c" & "b"` = `never`); a side with
    /// any non-unit member is not provably anything and the pair is kept.
    ///
    /// The `A & { tag: "x" | "y" }` narrowing of a discriminated union is where
    /// the union form appears: `SavedFeedItem & { type: "feed" | "list" }`
    /// distributes over `SavedFeedItem`, and without this the `{ type:
    /// "timeline"; view: undefined }` product survived — so `view` kept its
    /// `undefined` constituent through every discriminant narrowing and each
    /// use of it was a spurious TS18048.
    fn unitTypesDisjoint(s: *const Store, a: TypeId, b: TypeId) bool {
        if (a == b) return false;
        const ams: []const TypeId = if (s.kind(a) == .union_type) s.members(a) else &.{a};
        const bms: []const TypeId = if (s.kind(b) == .union_type) s.members(b) else &.{b};
        if (ams.len == 0 or bms.len == 0) return false;
        for (ams) |am| {
            const ka = unitKey(s, am) orelse return false;
            for (bms) |bm| {
                const kb = unitKey(s, bm) orelse return false;
                if (std.mem.eql(u32, &ka, &kb)) return false;
            }
        }
        return true;
    }

    /// tsc's `getReducedType` / `isDiscriminantWithNeverType`: an intersection
    /// is EMPTY when some property it merges comes out `never` — which for a
    /// discriminant means two constituents give the same property disjoint
    /// unit types.
    ///
    /// This is what makes `(A | B) & { tag: true }` usable after the
    /// distribution above: the `B & { tag: true }` product, whose `tag` would
    /// be `false & true`, drops out of the union instead of staying as a
    /// constituent with none of `A`'s members. immich's
    /// `MaintenanceModeState & { isMaintenanceMode: true }` read every
    /// property off it as missing (TS2339 on `.secret` / `.action`).
    ///
    /// An intersection's synthesized property is optional only when it is
    /// optional in EVERY constituent (tsc's `getUnionOrIntersectionProperty`),
    /// and only an optional one is exempt — so a required side against an
    /// optional one still reduces.
    fn discriminantIntersectionIsEmpty(s: *const Store, list: []const TypeId) bool {
        for (list, 0..) |a, i| {
            if (s.kind(a) != .object) continue;
            const na = s.objectPropCount(a);
            if (na == 0) continue;
            for (list[i + 1 ..]) |b| {
                if (s.kind(b) != .object) continue;
                const nb = s.objectPropCount(b);
                if (nb == 0) continue;
                // Property records are interned sorted by name atom, so one
                // merge pass finds every shared name.
                var ia: u32 = 0;
                var ib: u32 = 0;
                while (ia < na and ib < nb) {
                    const pa = s.objectProp(a, ia);
                    const pb = s.objectProp(b, ib);
                    if (pa.name < pb.name) {
                        ia += 1;
                    } else if (pb.name < pa.name) {
                        ib += 1;
                    } else {
                        if ((!pa.optional() or !pb.optional()) and
                            unitTypesDisjoint(s, pa.ty, pb.ty)) return true;
                        ia += 1;
                        ib += 1;
                    }
                }
            }
        }
        return false;
    }

    fn indexOf(list: []const TypeId, t: TypeId) ?usize {
        for (list, 0..) |x, i| {
            if (x == t) return i;
        }
        return null;
    }

    fn indexOfKind(s: *const Store, list: []const TypeId, k: Kind) ?usize {
        for (list, 0..) |x, i| {
            if (s.kind(x) == k) return i;
        }
        return null;
    }

    /// tsc's `filterType` for one kind: the union `t` without its members of
    /// kind `k`. `t` is known to BE a union that has one (see
    /// `makeIntersectionFlags`), so the result is never the input.
    fn filterOutKind(s: *Store, scratch: Allocator, t: TypeId, k: Kind) Error!TypeId {
        const src = try scratch.dupe(TypeId, s.members(t));
        defer scratch.free(src);
        var w: usize = 0;
        for (src) |m| {
            if (s.kind(m) == k) continue;
            src[w] = m;
            w += 1;
        }
        return s.makeUnion(scratch, src[0..w]);
    }

    /// Insertion-sort 3-word (name, type, flags) records by name.
    /// Sort the 3-word (name, ty, flags) property records by name atom.
    /// Property names are deduplicated upstream, so keys are unique and an
    /// unstable O(n log n) sort is deterministic. Reinterpreting the flat
    /// words as `[3]u32` lets `std.mem.sort` move whole records with no
    /// scratch allocation (u32 and [3]u32 share alignment).
    fn sortTriples(words: []u32) void {
        const n = words.len / 3;
        if (n < 2) return;
        const triples = @as([*][3]u32, @ptrCast(words.ptr))[0..n];
        std.mem.sort([3]u32, triples, {}, struct {
            fn lt(_: void, a: [3]u32, b: [3]u32) bool {
                return a[0] < b[0];
            }
        }.lt);
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "well-known types occupy their fixed indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    try testing.expectEqual(Kind.any, s.kind(any_type));
    try testing.expectEqual(Kind.unknown, s.kind(unknown_type));
    try testing.expectEqual(Kind.never, s.kind(never_type));
    try testing.expectEqual(Kind.void, s.kind(void_type));
    try testing.expectEqual(Kind.undefined, s.kind(undefined_type));
    try testing.expectEqual(Kind.null, s.kind(null_type));
    try testing.expectEqual(Kind.string, s.kind(string_type));
    try testing.expectEqual(Kind.number, s.kind(number_type));
    try testing.expectEqual(Kind.boolean, s.kind(boolean_type));
    try testing.expectEqual(Kind.bigint, s.kind(bigint_type));
    try testing.expectEqual(Kind.bool_true, s.kind(true_type));
    try testing.expectEqual(Kind.bool_false, s.kind(false_type));
    try testing.expectEqual(Kind.object, s.kind(empty_object_type));
    try testing.expectEqual(@as(u32, 0), s.objectPropCount(empty_object_type));
}

test "interning: literals and arrays are canonical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const a1 = try s.makeStringLiteral(42, false);
    const a2 = try s.makeStringLiteral(42, false);
    const b = try s.makeStringLiteral(43, false);
    try testing.expectEqual(a1, a2);
    try testing.expect(a1 != b);

    const n1 = try s.makeNumberLiteral(3.25, false);
    const n2 = try s.makeNumberLiteral(3.25, false);
    try testing.expectEqual(n1, n2);
    try testing.expectEqual(@as(f64, 3.25), s.numberValue(n1));

    const arr1 = try s.makeArray(number_type);
    const arr2 = try s.makeArray(number_type);
    const arr3 = try s.makeArray(string_type);
    try testing.expectEqual(arr1, arr2);
    try testing.expect(arr1 != arr3);
    // Nested: number[][] interned once.
    try testing.expectEqual(try s.makeArray(arr1), try s.makeArray(arr2));
}

test "interning: predicate functions are distinct by predicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const params = [_]Param{.{ .name = 1, .ty = unknown_type, .flags = 0 }};

    // Two guards `(x) => x is string` / `(x) => x is number` share params/return
    // but differ only in the predicate — they must NOT hash-cons together
    // (the predicate words are part of the shape).
    const g_str = try s.makeFunctionPred(&params, boolean_type, &.{}, 0, .{ .asserts = false, .param = 0, .ty = string_type });
    const g_str2 = try s.makeFunctionPred(&params, boolean_type, &.{}, 0, .{ .asserts = false, .param = 0, .ty = string_type });
    const g_num = try s.makeFunctionPred(&params, boolean_type, &.{}, 0, .{ .asserts = false, .param = 0, .ty = number_type });
    try testing.expectEqual(g_str, g_str2); // identical guards canonicalize
    try testing.expect(g_str != g_num); // different predicate ⇒ distinct type

    // A non-predicate function built with predicate-flagged source flags must
    // drop the flag (no predicate words appended) — else its shape would claim
    // words that are not there (OOB / corruption).
    const plain = try s.makeFunction(&params, boolean_type, &.{}, fn_flag_predicate);
    try testing.expect(!s.fnHasPredicate(plain));
    // Interning it again is stable (round-trips through the shape cleanly).
    try testing.expectEqual(plain, try s.makeFunction(&params, boolean_type, &.{}, fn_flag_predicate));
}

test "union canonicalization: order, dups, flatten, never, true|false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const sc = testing.allocator;

    const ua = try s.makeUnion(sc, &.{ string_type, number_type });
    const ub2 = try s.makeUnion(sc, &.{ number_type, string_type });
    try testing.expectEqual(ua, ub2);

    // dups + flatten
    const uc = try s.makeUnion(sc, &.{ ua, string_type, number_type });
    try testing.expectEqual(ua, uc);

    // T | never = T
    try testing.expectEqual(string_type, try s.makeUnion(sc, &.{ string_type, never_type }));
    // empty -> never
    try testing.expectEqual(never_type, try s.makeUnion(sc, &.{}));
    // any absorbs; unknown absorbs everything but any
    try testing.expectEqual(any_type, try s.makeUnion(sc, &.{ string_type, any_type }));
    try testing.expectEqual(unknown_type, try s.makeUnion(sc, &.{ string_type, unknown_type }));
    try testing.expectEqual(any_type, try s.makeUnion(sc, &.{ unknown_type, any_type }));

    // true | false -> boolean
    try testing.expectEqual(boolean_type, try s.makeUnion(sc, &.{ true_type, false_type }));
    const ub = try s.makeUnion(sc, &.{ true_type, false_type, string_type });
    try testing.expectEqual(try s.makeUnion(sc, &.{ boolean_type, string_type }), ub);

    // literal absorbed by base primitive
    const lit = try s.makeStringLiteral(7, false);
    try testing.expectEqual(string_type, try s.makeUnion(sc, &.{ lit, string_type }));
    const num_lit = try s.makeNumberLiteral(1, false);
    try testing.expectEqual(number_type, try s.makeUnion(sc, &.{ num_lit, number_type }));
    try testing.expectEqual(boolean_type, try s.makeUnion(sc, &.{ true_type, boolean_type }));
}

test "intersection canonicalization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const sc = testing.allocator;

    // T & unknown = T
    try testing.expectEqual(string_type, try s.makeIntersection(sc, &.{ string_type, unknown_type }));
    // never absorbs
    try testing.expectEqual(never_type, try s.makeIntersection(sc, &.{ string_type, never_type }));
    // Member order is the WRITTEN order and is part of the identity, as in
    // tsc: `A & B` and `B & A` are two types over the same member set.
    const o1 = try s.makeObject(&.{.{ .name = 1, .ty = string_type }}, 0, 0, 0);
    const o2 = try s.makeObject(&.{.{ .name = 2, .ty = number_type }}, 0, 0, 0);
    const ix = try s.makeIntersection(sc, &.{ o1, o2 });
    const iy = try s.makeIntersection(sc, &.{ o2, o1 });
    try testing.expect(ix != iy);
    try testing.expectEqual(Kind.intersection, s.kind(ix));
    try testing.expectEqualSlices(TypeId, &.{ o1, o2 }, s.members(ix));
    try testing.expectEqualSlices(TypeId, &.{ o2, o1 }, s.members(iy));
    // Re-intersecting an intersection flattens in place and dedups on the
    // first occurrence, so the order survives.
    try testing.expectEqual(ix, try s.makeIntersection(sc, &.{ ix, o1 }));
    try testing.expectEqual(ix, try s.makeIntersection(sc, &.{ o1, ix }));
    // empty -> unknown
    try testing.expectEqual(unknown_type, try s.makeIntersection(sc, &.{}));

    // A union constituent distributes: `(A | B) & C` = `A & C | B & C`, and
    // no interned intersection holds a union member.
    const o3 = try s.makeObject(&.{.{ .name = 3, .ty = boolean_type }}, 0, 0, 0);
    const uni_ab = try s.makeUnion(sc, &.{ o1, o2 });
    const dist = try s.makeIntersection(sc, &.{ uni_ab, o3 });
    try testing.expectEqual(Kind.union_type, s.kind(dist));
    try testing.expectEqual(try s.makeUnion(sc, &.{
        try s.makeIntersection(sc, &.{ o1, o3 }),
        try s.makeIntersection(sc, &.{ o2, o3 }),
    }), dist);
    for (s.members(dist)) |m| try testing.expectEqual(Kind.intersection, s.kind(m));

    // Two unions cross-multiply into four intersections. The *union* is
    // canonical, but each cross-product member keeps the operand order it was
    // built from, so swapping the operands yields a different (mutually
    // assignable) union — the same thing tsc's `getCrossProductIntersections`
    // does.
    const o4 = try s.makeObject(&.{.{ .name = 4, .ty = string_type }}, 0, 0, 0);
    const uni_cd = try s.makeUnion(sc, &.{ o3, o4 });
    const cross = try s.makeIntersection(sc, &.{ uni_ab, uni_cd });
    try testing.expectEqual(@as(usize, 4), s.members(cross).len);
    for (s.members(cross)) |m| {
        try testing.expectEqual(Kind.intersection, s.kind(m));
        try testing.expectEqual(@as(usize, 2), s.members(m).len);
    }

    // `any` still absorbs through a union constituent, and a union member that
    // repeats an intersected part collapses (`(A | B) & A` keeps `A` once).
    try testing.expectEqual(any_type, try s.makeIntersection(sc, &.{ uni_ab, any_type }));
    // `(o1 | o2) & o1` distributes to `o1 | (o2 & o1)` — the distributed
    // member keeps the union constituent first, so it is `iy`, not `ix`.
    try testing.expectEqual(try s.makeUnion(sc, &.{ o1, iy }), try s.makeIntersection(sc, &.{ uni_ab, o1 }));
}

test "object interning: property order does not matter, freshness does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());

    const props_ab = [_]Prop{
        .{ .name = 10, .ty = number_type },
        .{ .name = 20, .ty = string_type, .flags = prop_flag_optional },
    };
    const props_ba = [_]Prop{ props_ab[1], props_ab[0] };
    const o1 = try s.makeObject(&props_ab, 0, 0, 0);
    const o2 = try s.makeObject(&props_ba, 0, 0, 0);
    try testing.expectEqual(o1, o2);

    const fresh = try s.makeObject(&props_ab, 0, 0, obj_flag_fresh);
    try testing.expect(fresh != o1);
    try testing.expect(s.objectIsFresh(fresh));
    try testing.expectEqual(o1, try s.regular(fresh));
    try testing.expectEqual(o1, try s.regular(o1));

    const p = s.objectPropByName(o1, 20).?;
    try testing.expectEqual(string_type, p.ty);
    try testing.expect(p.optional());
    try testing.expectEqual(@as(?Prop, null), s.objectPropByName(o1, 30));
}

test "function and tuple interning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());

    const params = [_]Param{
        .{ .name = 1, .ty = number_type },
        .{ .name = 2, .ty = string_type, .flags = param_flag_optional },
    };
    const f1 = try s.makeFunction(&params, void_type, &.{}, 0);
    const f2 = try s.makeFunction(&params, void_type, &.{}, 0);
    try testing.expectEqual(f1, f2);
    // Param names don't unify: (a: number) => void differs from (b: number) => void
    // only by atom, which participates in identity. That's fine — display
    // types differ; assignability ignores names.
    const f3 = try s.makeFunction(&params, number_type, &.{}, 0);
    try testing.expect(f1 != f3);
    try testing.expectEqual(void_type, s.fnReturn(f1));
    try testing.expectEqual(@as(u32, 2), s.fnParamCount(f1));
    try testing.expect(s.fnParam(f1, 1).optional());

    const t1 = try s.makeTuple(&.{ .{ .ty = number_type }, .{ .ty = string_type, .flags = elem_flag_optional } });
    const t2 = try s.makeTuple(&.{ .{ .ty = number_type }, .{ .ty = string_type, .flags = elem_flag_optional } });
    try testing.expectEqual(t1, t2);
    try testing.expectEqual(@as(u32, 2), s.tupleLen(t1));
    try testing.expect(s.tupleElem(t1, 1).optional());
}

test "refs and type params intern by symbol + args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const r1 = try s.makeRef(5, &.{number_type});
    const r2 = try s.makeRef(5, &.{number_type});
    const r3 = try s.makeRef(5, &.{string_type});
    const r4 = try s.makeRef(6, &.{number_type});
    try testing.expectEqual(r1, r2);
    try testing.expect(r1 != r3 and r1 != r4);
    try testing.expectEqual(@as(u32, 5), s.refSymbol(r1));
    try testing.expectEqualSlices(TypeId, &.{number_type}, s.refArgs(r1));

    const tp1 = try s.makeTypeParam(9);
    try testing.expectEqual(tp1, try s.makeTypeParam(9));
    try testing.expectEqual(@as(u32, 9), s.typeParamSymbol(tp1));
}

test "frozen base / overlay: base ids shared, overlay ids above base_len, deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a base with some non-trivial structural types, then freeze it.
    var base = try Store.init(a);
    const base_union = try base.makeUnion(testing.allocator, &.{ string_type, number_type });
    const base_obj = try base.makeObject(&.{.{ .name = 100, .ty = number_type }}, no_type, no_type, 0);
    const base_ref = try base.makeRef(7, &.{string_type});
    const base_len: TypeId = @intCast(base.kinds.items.len);
    try testing.expect(base_union < base_len);
    try testing.expect(base_obj < base_len);
    try testing.expect(base_ref < base_len);
    base.freeze();

    // Two independent overlays over the same frozen base.
    var ov1 = try Store.initOverlay(a, &base);
    var ov2 = try Store.initOverlay(a, &base);

    // Well-known intrinsics resolve to their fixed base ids through the overlay.
    try testing.expectEqual(Kind.string, ov1.kind(string_type));
    try testing.expectEqual(Kind.number, ov1.kind(number_type));

    // Interning a type structurally identical to a base type returns the BASE
    // id (shared, < base_len) — no overlay duplication.
    try testing.expectEqual(base_union, try ov1.makeUnion(testing.allocator, &.{ number_type, string_type }));
    try testing.expectEqual(base_obj, try ov1.makeObject(&.{.{ .name = 100, .ty = number_type }}, no_type, no_type, 0));
    try testing.expectEqual(base_ref, try ov1.makeRef(7, &.{string_type}));
    try testing.expectEqual(@as(usize, 0), ov1.overlayCount());

    // Base payload is readable through the overlay's dispatching accessors.
    try testing.expectEqual(number_type, ov1.objectProp(base_obj, 0).ty);
    try testing.expectEqual(@as(u32, 7), ov1.refSymbol(base_ref));
    try testing.expectEqualSlices(TypeId, &.{string_type}, ov1.refArgs(base_ref));

    // An overlay-only type gets an id >= base_len.
    const ov_arr1 = try ov1.makeArray(number_type);
    try testing.expect(ov_arr1 >= base_len);
    try testing.expectEqual(number_type, ov1.arrayElem(ov_arr1));

    // Two independent overlays assign identical ids for the same structural
    // overlay-only type (determinism across checkers over one frozen base).
    const ov_arr2 = try ov2.makeArray(number_type);
    try testing.expectEqual(ov_arr1, ov_arr2);

    // A base structural match still wins in the second overlay too.
    try testing.expectEqual(base_union, try ov2.makeUnion(testing.allocator, &.{ string_type, number_type }));

    // Overlay-only union that mixes a base id and an overlay id interns locally
    // and reads back through the dispatch boundary.
    const mixed = try ov1.makeUnion(testing.allocator, &.{ base_ref, ov_arr1 });
    try testing.expect(mixed >= base_len);
    try testing.expectEqual(@as(usize, 2), ov1.members(mixed).len);
}

test "bytes accounting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try Store.init(arena.allocator());
    const before = s.typeBytes();
    _ = try s.makeArray(number_type);
    try testing.expect(s.typeBytes() > before);
    try testing.expect(s.totalBytes() >= s.typeBytes());
    try testing.expect(s.count() >= first_free_index - 1);
}
