//! Type representation + hash-consing (M4, ROADMAP.md §2.2).
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
//! - **Intersections are canonical** the same way: flattened, deduped,
//!   sorted; `unknown` dropped (`T & unknown = T`), `never`/`any` absorbing,
//!   empty intersection is `unknown`. Object-member *merging* is not done at
//!   construction; the checker merges views lazily (property lookup walks
//!   all constituents).
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
pub const first_free_index: TypeId = 17;

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
    ///  then per property (sorted by name atom): name, type, prop_flags].
    /// Object flags: 1 = fresh (object literal, excess-prop checked).
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
    /// Enum type (nominal). a = enum symbol id. Used both for `let x: E`
    /// annotations and for the type of a member access `E.A`.
    enum_type,
    /// `unique symbol` (M14). a = nominal identity id (a dense per-declaration
    /// number assigned by the checker). Assignable only to itself and to
    /// `symbol`; two distinct `unique symbol` declarations never unify.
    unique_symbol,
    /// Polymorphic `this` type (M14). a = the home class's generic instance
    /// ref (its "apparent" type). Produced for a method's `foo(): this` return
    /// annotation; substituted with the concrete receiver at property access,
    /// so `sub.foo()` types as the subclass. resolveStructural/assignability
    /// fall back to the stored instance ref.
    this_type,
    /// `infer V` binder (M16a). a = a dense id (unique per (conditional, name)),
    /// b = the binder's name atom (for display). Appears only inside a
    /// conditional type's extends/true branches; substituted away when the
    /// conditional resolves. Not a "free type parameter" for deferral purposes.
    infer_var,
    /// Deferred conditional type `C extends E ? T : F` (M16a). a = extra index,
    /// b = flags (bit0 = distributive: check was a naked type param). Interned
    /// only while the check type is still generic; resolved on instantiation.
    /// extra[a..]: [check, extends, true, false].
    conditional,
    /// The key parameter `K` of a mapped type (`{ [K in …]: … }`, M16b).
    /// a = a dense id (unique per mapped-type node), b = the name atom (for
    /// display). Behaves like a locally-bound parameter of the mapped type:
    /// substituted with each concrete key literal at materialization. Not a
    /// "free type parameter" for deferral purposes (like `infer_var`).
    mapped_param,
    /// Deferred indexed access `Obj[Idx]` (M16b, minimal — a down-payment on
    /// M16d). a = the object type, b = the index type. Interned by
    /// `indexedAccessType` only while `Idx` is a mapped key parameter (so a
    /// mapped value `T[K]` stays symbolic until each key is materialized).
    index_access,
    /// Deferred mapped type `{ [K in C] V }` (M16b). a = extra index,
    /// b = modifier flags. Interned only while the key set is still generic
    /// (constraint / homomorphic source mentions an outer type param);
    /// resolved to a concrete object on instantiation.
    /// extra[a..]: [key_param, constraint, value, as_clause, source, flags].
    mapped,
    /// Deferred / pattern template-literal type `` `head${h0}c0${h1}c1…` ``
    /// (M16c). a = extra index, b = hole count N. extra[a] = head literal atom;
    /// then per hole i: [hole_type, chunk_atom] where chunk_atom is the literal
    /// text immediately following hole i. Interned when a hole is still generic
    /// (deferred) OR when a hole is a non-enumerable primitive (`string` /
    /// `number`) — the "pattern" form (`` `a${string}` ``). A fully-concrete
    /// template never lands here (it resolves to a string-literal / union).
    template_literal_type,
    /// Intrinsic string-transform application (M16c): `Uppercase` /
    /// `Lowercase` / `Capitalize` / `Uncapitalize`. a = intrinsic index
    /// (`string_mapping_*` below), b = the argument type. Interned only while
    /// the argument is still generic; a concrete argument resolves to the
    /// transformed string-literal (or distributes over a union).
    string_mapping,
};

pub const cond_flag_distributive: u32 = 1;

// String-transform intrinsic indices (M16c), stored in a `string_mapping`
// type's `data_a`.
pub const string_mapping_uppercase: u32 = 0;
pub const string_mapping_lowercase: u32 = 1;
pub const string_mapping_capitalize: u32 = 2;
pub const string_mapping_uncapitalize: u32 = 3;

// Mapped-type modifier flags (M16b), stored in a mapped type's `data_b` (and
// repeated as its final extra word so they participate in hash-cons identity).
// Set by the parser (`+`/`-`/bare) and interpreted by the checker.
pub const mapped_flag_readonly_add: u32 = 1; // `+readonly` / `readonly`
pub const mapped_flag_readonly_remove: u32 = 2; // `-readonly`
pub const mapped_flag_optional_add: u32 = 4; // `+?` / `?`
pub const mapped_flag_optional_remove: u32 = 8; // `-?`
pub const mapped_flag_homomorphic: u32 = 16; // constraint was `keyof T`

pub const obj_flag_fresh: u32 = 1;
pub const prop_flag_optional: u32 = 1;
pub const prop_flag_readonly: u32 = 2;
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
/// **Frozen base / per-checker overlay (M14.5).** A `Store` is either a
/// *base* (`base == null`) — a self-contained store that owns TypeIds
/// `[0, kinds.len)` — or an *overlay* over a frozen base. An overlay owns
/// TypeIds `[base_len, …)` in its own SoA arrays and delegates all reads of
/// ids `< base_len` to `base`. Interning probes the frozen base's map first,
/// so a type structurally identical to a base type returns the *base* id
/// (shared, no per-overlay duplication); only genuinely new types allocate an
/// overlay id at `base_len + local_index`. The base is built and `freeze`d
/// single-threaded before workers spawn, then shared read-only across every
/// overlay — the type-level twin of M11's merged-symbol layer. A `TypeId`
/// therefore spans base+overlay and is never assumed checker-local (ROADMAP
/// M14.5 "Layout commitments").
pub const Store = struct {
    alloc: Allocator,
    kinds: std.ArrayList(Kind) = .empty,
    data_a: std.ArrayList(u32) = .empty,
    data_b: std.ArrayList(u32) = .empty,
    extra: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(TypeId, void, MapCtx, 80) = .empty,
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

    pub fn init(alloc: Allocator) Error!Store {
        var s: Store = .{ .alloc = alloc };
        // Index 0: none sentinel.
        try s.appendRaw(.none, 0, 0);
        // Fixed-index intrinsics; order must match the constants above.
        const fixed = [_]Kind{
            .any,    .unknown,        .never,  .void,      .undefined,
            .null,   .string,         .number, .boolean,   .bigint,
            .symbol, .object_keyword, .err,    .bool_true, .bool_false,
        };
        for (fixed) |k| {
            const id: TypeId = @intCast(s.kinds.items.len);
            try s.appendRaw(k, 0, 0);
            try s.map.putContext(s.alloc, id, {}, .{ .store = &s });
        }
        // empty object {} at index 16.
        const eo = try s.makeObject(&.{}, no_type, no_type, false);
        std.debug.assert(eo == empty_object_type);
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

    /// Seal a base store: no further interning, safe to share read-only as the
    /// frozen base of any number of overlays.
    pub fn freeze(s: *Store) void {
        s.frozen = true;
    }

    fn appendRaw(s: *Store, k: Kind, a: u32, b: u32) Error!void {
        try s.kinds.append(s.alloc, k);
        try s.data_a.append(s.alloc, a);
        try s.data_b.append(s.alloc, b);
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

    /// Exact bytes held by the sealed-style SoA arrays (base + overlay). The
    /// base's bytes are shared across overlays; `overlayBytes` isolates this
    /// overlay's own footprint.
    pub fn typeBytes(s: *const Store) usize {
        const local = s.kinds.items.len * (1 + 4 + 4) + s.extra.items.len * 4;
        return local + if (s.base) |b| b.typeBytes() else 0;
    }

    /// Bytes held by this store's own SoA arrays (overlay-local; excludes the
    /// shared base).
    pub fn overlayBytes(s: *const Store) usize {
        return s.kinds.items.len * (1 + 4 + 4) + s.extra.items.len * 4;
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
    pub fn members(s: *const Store, id: TypeId) []const TypeId {
        if (id < s.base_len) return s.base.?.members(id);
        return s.extra.items[s.dataA(id)..s.dataB(id)];
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
    pub fn objectProp(s: *const Store, id: TypeId, i: u32) Prop {
        if (id < s.base_len) return s.base.?.objectProp(id, i);
        const base = s.dataA(id) + 3 + 3 * i;
        return .{
            .name = s.extra.items[base],
            .ty = s.extra.items[base + 1],
            .flags = s.extra.items[base + 2],
        };
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
    pub fn fnTypeParams(s: *const Store, id: TypeId) []const u32 {
        if (id < s.base_len) return s.base.?.fnTypeParams(id);
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        return s.extra.items[base + 3 .. base + 3 + tpc];
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

    pub fn inferVarId(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
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

    pub fn typeParamSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn classSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
    }
    pub fn enumSymbol(s: *const Store, id: TypeId) u32 {
        return s.dataA(id);
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
            else => unreachable,
        };
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
            .object => return s.extra.items[a .. a + 3 + 3 * b],
            .function => {
                const tpc = s.extra.items[a + 2];
                // A predicate function (`x is T` / `asserts x`) stores 3 extra
                // words after the params; they are part of the type's identity,
                // so include them in the shape or two guards differing only in
                // the predicate would hash-cons together.
                const pred: u32 = if (s.extra.items[a] & fn_flag_predicate != 0) 3 else 0;
                // A `this`-parameter type (M14) is one trailing word after the
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

    fn hashShape(kind_: Kind, words: []const u32) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(kind_));
        h.update(std.mem.sliceAsBytes(words));
        return h.final();
    }

    const MapCtx = struct {
        store: *const Store,
        pub fn hash(ctx: MapCtx, id: TypeId) u64 {
            var buf: [2]u32 = undefined;
            const words = ctx.store.shapeWords(id, &buf);
            return hashShape(ctx.store.kind(id), words);
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
        pub fn hash(ctx: PendingCtx, _: void) u64 {
            return hashShape(ctx.kind, ctx.words);
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
        // Probe the frozen base first: a type structurally identical to a base
        // type resolves to the shared *base* id (no overlay duplication). The
        // candidate `words` reference only sub-ids that are integer-equal to
        // the base type's, so the raw-word hash/equality carries across stores.
        if (s.base) |base| {
            if (base.map.getKeyAdapted(
                @as(void, {}),
                PendingCtx{ .store = base, .kind = kind_, .words = words },
            )) |base_id| return base_id;
        }
        const gop = try s.map.getOrPutContextAdapted(
            s.alloc,
            @as(void, {}),
            PendingCtx{ .store = s, .kind = kind_, .words = words },
            MapCtx{ .store = s },
        );
        if (gop.found_existing) return gop.key_ptr.*;

        // New overlay ids start at `base_len`; base ids at 0 (base_len == 0).
        const id: TypeId = s.base_len + @as(u32, @intCast(s.kinds.items.len));
        switch (kind_) {
            .union_type, .intersection, .overloads => {
                const start: u32 = @intCast(s.extra.items.len);
                try s.extra.appendSlice(s.alloc, words);
                try s.appendRaw(kind_, start, @intCast(s.extra.items.len));
            },
            .tuple, .object, .function, .ref, .conditional, .mapped, .template_literal_type => {
                const start: u32 = @intCast(s.extra.items.len);
                try s.extra.appendSlice(s.alloc, words);
                try s.appendRaw(kind_, start, b_count);
            },
            else => try s.appendRaw(kind_, words[0], words[1]),
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

    pub fn makeTypeParam(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.type_param, &.{ symbol, 0 }, 0);
    }

    pub fn makeClassValue(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.class_value, &.{ symbol, 0 }, 0);
    }

    pub fn makeEnumType(s: *Store, symbol: u32) Error!TypeId {
        return s.internType(.enum_type, &.{ symbol, 0 }, 0);
    }

    pub fn makeUniqueSymbol(s: *Store, id: u32) Error!TypeId {
        return s.internType(.unique_symbol, &.{ id, 0 }, 0);
    }

    pub fn makeTuple(s: *Store, elems: []const TupleElem) Error!TypeId {
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
        fresh: bool,
    ) Error!TypeId {
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.append(s.alloc, if (fresh) obj_flag_fresh else 0);
        try s.pending.append(s.alloc, string_index);
        try s.pending.append(s.alloc, number_index);
        const pstart = s.pending.items.len;
        for (props) |p| {
            try s.pending.append(s.alloc, p.name);
            try s.pending.append(s.alloc, p.ty);
            try s.pending.append(s.alloc, p.flags);
        }
        // Sort the 3-word property records by name atom.
        sortTriples(s.pending.items[pstart..]);
        return s.internType(.object, s.pending.items[start..], @intCast(props.len));
    }

    /// The regular (non-fresh) variant of a fresh object literal type.
    pub fn regular(s: *Store, id: TypeId) Error!TypeId {
        if (!s.objectIsFresh(id)) return id;
        const a = s.dataA(id);
        const n = s.dataB(id);
        // The fresh object may live in the frozen base; read its shape words
        // from the owning store (base ids carry base-relative extra offsets).
        const own = if (id < s.base_len) s.base.? else s;
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.appendSlice(s.alloc, own.extra.items[a .. a + 3 + 3 * n]);
        s.pending.items[start] &= ~obj_flag_fresh;
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

    pub fn makeInferVar(s: *Store, id: u32, name: Atom) Error!TypeId {
        return s.internType(.infer_var, &.{ id, name }, 0);
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

        if (list.len == 0) return never_type;
        if (list.len == 1) return list[0];
        return s.internType(.union_type, list, 0);
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

    /// Canonical intersection (flatten, dedup, sort; unknown dropped;
    /// never/any absorbing; empty -> unknown; single -> unwrapped).
    pub fn makeIntersection(s: *Store, scratch: Allocator, parts: []const TypeId) Error!TypeId {
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
        const items = flat.items;
        std.mem.sort(TypeId, items, {}, std.sort.asc(TypeId));
        var n: usize = 0;
        for (items) |t| {
            if (n > 0 and items[n - 1] == t) continue;
            items[n] = t;
            n += 1;
        }
        if (n == 0) return unknown_type;
        if (n == 1) return items[0];
        return s.internType(.intersection, items[0..n], 0);
    }

    fn indexOf(list: []const TypeId, t: TypeId) ?usize {
        for (list, 0..) |x, i| {
            if (x == t) return i;
        }
        return null;
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
    // order-insensitive
    const o1 = try s.makeObject(&.{.{ .name = 1, .ty = string_type }}, 0, 0, false);
    const o2 = try s.makeObject(&.{.{ .name = 2, .ty = number_type }}, 0, 0, false);
    const ix = try s.makeIntersection(sc, &.{ o1, o2 });
    const iy = try s.makeIntersection(sc, &.{ o2, o1 });
    try testing.expectEqual(ix, iy);
    try testing.expectEqual(Kind.intersection, s.kind(ix));
    // empty -> unknown
    try testing.expectEqual(unknown_type, try s.makeIntersection(sc, &.{}));
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
    const o1 = try s.makeObject(&props_ab, 0, 0, false);
    const o2 = try s.makeObject(&props_ba, 0, 0, false);
    try testing.expectEqual(o1, o2);

    const fresh = try s.makeObject(&props_ab, 0, 0, true);
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
    const base_obj = try base.makeObject(&.{.{ .name = 100, .ty = number_type }}, no_type, no_type, false);
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
    try testing.expectEqual(base_obj, try ov1.makeObject(&.{.{ .name = 100, .ty = number_type }}, no_type, no_type, false));
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
