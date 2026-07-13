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
    ///  then per param: name_atom, type, param_flags].
    /// Function flags: 1 = method (bivariant params). param_flags:
    /// 1 = optional, 2 = rest, 4 = has_initializer.
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
};

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
pub const Store = struct {
    alloc: Allocator,
    kinds: std.ArrayList(Kind) = .empty,
    data_a: std.ArrayList(u32) = .empty,
    data_b: std.ArrayList(u32) = .empty,
    extra: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(TypeId, void, MapCtx, 80) = .empty,
    /// Scratch for building candidate payloads before interning.
    pending: std.ArrayList(u32) = .empty,

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

    fn appendRaw(s: *Store, k: Kind, a: u32, b: u32) Error!void {
        try s.kinds.append(s.alloc, k);
        try s.data_a.append(s.alloc, a);
        try s.data_b.append(s.alloc, b);
    }

    pub fn count(s: *const Store) usize {
        return s.kinds.items.len - 1;
    }

    /// Exact bytes held by the sealed-style SoA arrays (not map overhead).
    pub fn typeBytes(s: *const Store) usize {
        return s.kinds.items.len * (1 + 4 + 4) + s.extra.items.len * 4;
    }

    /// Approximate bytes including intern map capacity.
    pub fn totalBytes(s: *const Store) usize {
        return s.typeBytes() + s.map.capacity() * (@sizeOf(TypeId) + 1);
    }

    pub fn kind(s: *const Store, id: TypeId) Kind {
        return s.kinds.items[id];
    }
    pub fn dataA(s: *const Store, id: TypeId) u32 {
        return s.data_a.items[id];
    }
    pub fn dataB(s: *const Store, id: TypeId) u32 {
        return s.data_b.items[id];
    }

    // --- payload views ------------------------------------------------------

    /// Union/intersection/overload members.
    pub fn members(s: *const Store, id: TypeId) []const TypeId {
        return s.extra.items[s.dataA(id)..s.dataB(id)];
    }

    pub fn arrayElem(s: *const Store, id: TypeId) TypeId {
        return s.dataA(id);
    }

    pub fn tupleLen(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }

    pub fn tupleElem(s: *const Store, id: TypeId, i: u32) TupleElem {
        const base = s.dataA(id) + 2 * i;
        return .{ .ty = s.extra.items[base], .flags = s.extra.items[base + 1] };
    }

    pub fn objectFlags(s: *const Store, id: TypeId) u32 {
        return s.extra.items[s.dataA(id)];
    }
    pub fn objectIsFresh(s: *const Store, id: TypeId) bool {
        return s.kind(id) == .object and s.objectFlags(id) & obj_flag_fresh != 0;
    }
    pub fn objectStringIndex(s: *const Store, id: TypeId) TypeId {
        return s.extra.items[s.dataA(id) + 1];
    }
    pub fn objectNumberIndex(s: *const Store, id: TypeId) TypeId {
        return s.extra.items[s.dataA(id) + 2];
    }
    pub fn objectPropCount(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    pub fn objectProp(s: *const Store, id: TypeId, i: u32) Prop {
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
        return s.extra.items[s.dataA(id)];
    }
    pub fn fnReturn(s: *const Store, id: TypeId) TypeId {
        return s.extra.items[s.dataA(id) + 1];
    }
    pub fn fnTypeParams(s: *const Store, id: TypeId) []const u32 {
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        return s.extra.items[base + 3 .. base + 3 + tpc];
    }
    pub fn fnParamCount(s: *const Store, id: TypeId) u32 {
        return s.dataB(id);
    }
    pub fn fnParam(s: *const Store, id: TypeId, i: u32) Param {
        const base = s.dataA(id);
        const tpc = s.extra.items[base + 2];
        const pbase = base + 3 + tpc + 3 * i;
        return .{
            .name = s.extra.items[pbase],
            .ty = s.extra.items[pbase + 1],
            .flags = s.extra.items[pbase + 2],
        };
    }

    pub fn refSymbol(s: *const Store, id: TypeId) u32 {
        return s.extra.items[s.dataA(id)];
    }
    pub fn refArgs(s: *const Store, id: TypeId) []const TypeId {
        const base = s.dataA(id);
        return s.extra.items[base + 1 .. base + 1 + s.dataB(id)];
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
            else => no_type,
        };
    }

    // --- interning ------------------------------------------------------------

    /// Shape words for hashing/equality. For inline-payload kinds the
    /// caller-provided buffer receives (a, b); for extra-payload kinds the
    /// stored extra words are returned.
    fn shapeWords(s: *const Store, id: TypeId, buf: *[2]u32) []const u32 {
        const a = s.dataA(id);
        const b = s.dataB(id);
        switch (s.kinds.items[id]) {
            .union_type, .intersection, .overloads => return s.extra.items[a..b],
            .tuple => return s.extra.items[a .. a + 2 * b],
            .object => return s.extra.items[a .. a + 3 + 3 * b],
            .function => {
                const tpc = s.extra.items[a + 2];
                return s.extra.items[a .. a + 3 + tpc + 3 * b];
            },
            .ref => return s.extra.items[a .. a + 1 + b],
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
            return hashShape(ctx.store.kinds.items[id], words);
        }
        pub fn eql(ctx: MapCtx, x: TypeId, y: TypeId) bool {
            if (x == y) return true;
            if (ctx.store.kinds.items[x] != ctx.store.kinds.items[y]) return false;
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
            if (ctx.store.kinds.items[existing] != ctx.kind) return false;
            var buf: [2]u32 = undefined;
            const w = ctx.store.shapeWords(existing, &buf);
            return std.mem.eql(u32, ctx.words, w);
        }
    };

    /// Intern a type whose payload words are in `words`. For inline kinds
    /// words = [a, b]; for extra kinds words are appended to `extra` on miss.
    fn internType(s: *Store, kind_: Kind, words: []const u32, b_count: u32) Error!TypeId {
        const gop = try s.map.getOrPutContextAdapted(
            s.alloc,
            @as(void, {}),
            PendingCtx{ .store = s, .kind = kind_, .words = words },
            MapCtx{ .store = s },
        );
        if (gop.found_existing) return gop.key_ptr.*;

        const id: TypeId = @intCast(s.kinds.items.len);
        switch (kind_) {
            .union_type, .intersection, .overloads => {
                const start: u32 = @intCast(s.extra.items.len);
                try s.extra.appendSlice(s.alloc, words);
                try s.appendRaw(kind_, start, @intCast(s.extra.items.len));
            },
            .tuple, .object, .function, .ref => {
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
        const start = s.pending.items.len;
        defer s.pending.items.len = start;
        try s.pending.appendSlice(s.alloc, s.extra.items[a .. a + 3 + 3 * n]);
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
        return s.internType(.function, s.pending.items[start..], @intCast(params.len));
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
