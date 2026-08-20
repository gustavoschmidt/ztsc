//! `keyof T` and `T[K]` — the two type-level operators that read a member
//! table rather than build one.
//!
//! They are one file because they are two halves of the same question. `keyof`
//! produces a KEY SET (a union of literals, or a primitive key domain, or a
//! deferred `keyof` when the operand is still generic), and an indexed access
//! consumes one: every arm of `indexedAccessType` is a key kind, and the union
//! arms of both distribute over the same constituents. The key-set predicates
//! in the middle (`keySetEnumerable`, `keySetHas`, …) are what lets
//! `keyof (A | B)` be intersected exactly instead of symbolically.
//!
//! Both operators answer for GENERIC operands wherever they can: `keyof` reads
//! a reference's uninstantiated member table (names and visibility survive
//! substitution untouched), and an access resolves a single member instead of
//! a whole table when the instantiation ceiling has been hit. Those two are
//! the file's main memory levers, not micro-optimizations.
//!
//! typenode.zig re-exports this file's public surface, so `checker.zig`'s
//! method aliases and other modules' direct imports keep resolving there.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const lazyIndexedProp = @import("instantiate.zig").lazyIndexedProp;
const tuple_relate = @import("tuple_relate.zig");

/// The key set of one object member table — the names it stores, plus the
/// domains its index signatures open up. Reads nothing but names, flags and
/// index-signature presence, all three of which `instantiateId` carries
/// through a substitution unchanged; that is what lets `keyofType` answer for
/// a generic reference off the table the substitution would have been applied
/// to.
fn keyofObjectTable(c: *Checker, r: TypeId) Error!TypeId {
    // Only valid while no new `key_name_types` entry has landed since: the
    // answer reads that side table and it is written against an object after
    // interning. See `Checker.keyof_obj_cache`.
    if (c.keyof_obj_cache.get(r)) |k| {
        if (k.gen == c.key_name_gen) return k.ty;
    }
    const computed = try keyofObjectTableUncached(c, r);
    try c.keyof_obj_cache.put(c.cm(), r, .{ .ty = computed, .gen = c.key_name_gen });
    return computed;
}

/// The synthetic-member-atom prefix the parser, the binder and the checker
/// share for every key that is not a source identifier. It cannot begin a
/// real identifier, so it never collides (`ast.wellKnownSymbolKey`,
/// `atoms.uniqueSymAtom`, `binder.memberKey`).
pub const synthetic_prefix = "__@";

/// What `keyof` makes of a member NAME, as one memoized answer: `no_type` for
/// an ordinary name, whose key is its string literal, and otherwise the SYMBOL
/// the member is named by.
///
/// tsc's `getLiteralTypeFromProperty` answers a
/// LATE-BOUND property with its `links.nameType` — the `unique symbol` its
/// computed key evaluated to — rather than a string literal over the
/// property's internal name. ztsc keys such a member by the synthetic atom
/// the parser and binder share, and `__@u<id>` decodes back to the symbol
/// arithmetically: `Checker.uniqueSymType` IS `makeUniqueSymbol(<global node
/// id of the annotation>)` and `uniqueSymAtom` prints that id, so the key
/// type is the very type `typeof k` has. That identity is what makes
/// `keyof I` accept `s` and reject a DIFFERENT `unique symbol`.
///
/// Answering a string literal instead is what made `Extract<keyof I, string>`
/// keep `"__@u90369"`, `keyof I` print an atom nobody wrote, `const k: keyof
/// I = s` a spurious TS2322, `Pick<I, typeof s>` an empty object and
/// `{ [P in keyof I]: 1 }` drop the member: the key domain of a symbol-named
/// member is `symbol`, and every string filter — `Extract`, a
/// template-literal placeholder, an index-signature domain
/// (`index_constraints.applicableSlots` already agrees) — has to see that.
///
/// The memo is not an optimization, it is what makes the rule affordable:
/// answering needs the member's NAME, and reading a name is not free —
/// `Interner.lookup` takes the interner's shard mutex — while this runs for
/// every property of every table `keyof` expands. Asking it directly cost
/// drizzle 10% of its wall clock against a 2% bar; keyed by atom (the answer
/// is a pure function of the name and never changes) it costs one
/// integer-map hit.
///
/// WELL-KNOWN symbols are deliberately NOT symbol-named here, and that too is
/// measured. `__@iterator` and `__@unscopables` sit on `Array`, `String`,
/// `Map`, `Set` and every iterable in the lib, so honouring them puts a
/// `unique symbol` constituent into the `keyof` of nearly every type a
/// program touches — which was the other half of that same 10%. A `unique
/// symbol` CONST member is rare in real code and costs nothing, and it is the
/// half the suite asks for (`keyRemappingKeyofResult`,
/// `contextuallyTypedSymbolNamedProperties`, `extractInferenceImprovement`
/// all key on `const s = Symbol()`). The consequence kept: `Extract<keyof
/// number[], string>` still wrongly keeps `"__@iterator"`.
///
/// Carrying the fact on the TABLE instead — an object flag set once where the
/// table is interned — was tried and does NOT close it. The per-property
/// derivation is not what costs: it is already one integer-map hit, and a
/// table flag can only skip tables that have no synthetic member at all, which
/// `Array`/`String`/`Map`/`Set` are precisely not. Measured (drizzle, 9
/// interleaved A/B samples of 15 batched invocations): answering the
/// well-known keys with `SymbolConstructor`'s own `unique symbol` — memoized
/// per atom, so 13 scans for the whole program — is +11.2% median wall and
/// +8.8% min, with every paired sample worse, against a 2% bar. The cost is
/// downstream and intrinsic: the extra `unique symbol` constituent widens the
/// `keyof` of nearly every lib type and every relation over one pays for it.
/// The suite pays nothing back — the same run was 7116 exact either way, zero
/// cases moved. Reopen only with a plan that makes the WIDER key set cheap,
/// not with another way to compute it.
pub fn memberKeyKind(c: *Checker, name: types.Atom) Error!TypeId {
    if (c.sym_key_cache.get(name)) |t| return t;
    const answer = try computeMemberKeyKind(c, name);
    try c.sym_key_cache.put(c.cm(), name, answer);
    return answer;
}

fn computeMemberKeyKind(c: *Checker, name: types.Atom) Error!TypeId {
    const txt = c.atomText(name);
    if (!std.mem.startsWith(u8, txt, synthetic_prefix)) return types.no_type;
    const rest = txt[synthetic_prefix.len..];
    // `__@u<id>` and nothing else. `__@ctor` and `__@class` are member slots
    // ztsc invents for a constructor and a class expression, `__@k$…` is the
    // placeholder a computed key wears until it is nominalized, and the
    // well-known `__@<name>` keys are excluded on purpose (see above) — all
    // of them must keep whatever key behaviour they already had.
    if (rest.len < 2 or rest[0] != 'u') return types.no_type;
    const id = std.fmt.parseInt(u32, rest[1..], 10) catch return types.no_type;
    return try c.ts.makeUniqueSymbol(id);
}

/// The member atom a SYMBOL-typed key denotes — the inverse of
/// `memberKeyKind`, and what lets `I[typeof s]` and every mapped type
/// over a key set containing one find the member again.
///
/// Well-known symbols are tried FIRST, and the order is the design, not a
/// preference: the lib types `Symbol.iterator` as a `unique symbol` of its
/// own, so `uniqueSymAtom` would happily answer `__@u<lib node>` for it —
/// a key no table has, since the declaration side is keyed syntactically
/// (`__@iterator`). `expr.zig`'s element-access path orders the same two
/// probes the same way for the same reason.
///
/// `keyof` no longer PRODUCES a well-known symbol key (see
/// `memberKeyKind` for the measurement that scoped it out), so that
/// first probe now serves only a key written by hand —
/// `T[typeof Symbol.iterator]` — and never runs on a key set walk.
pub fn symbolKeyAtom(c: *Checker, idx: TypeId) Error!?types.Atom {
    if (c.ts.kind(try c.ts.regular(idx)) != .unique_symbol) return null;
    if (try wellKnownAtomOfType(c, idx)) |a| return a;
    return c.uniqueSymAtom(idx);
}

/// `SymbolConstructor` resolved to its member table, or null when no lib
/// declares it.
fn symbolConstructorTable(c: *Checker) Error!?TypeId {
    const iface = c.prog.globals.lookup(try c.internText("SymbolConstructor")) orelse return null;
    if (!c.symFlags(iface).interface) return null;
    const obj = try c.resolveStructural(try c.ts.makeRef(iface, &.{}));
    return if (c.ts.kind(obj) == .object) obj else null;
}

/// The `__@<name>` member key of the well-known symbol whose type is `t`.
///
/// Found by scanning `SymbolConstructor` for the member that HAS this type
/// rather than by decoding `t`: a well-known symbol's identity is the lib
/// declaration, and nothing about the interned `unique symbol` records which
/// property it came from. The scan is over one already-resolved table (~25
/// members) and only a symbol-typed key ever reaches it.
fn wellKnownAtomOfType(c: *Checker, t: TypeId) Error!?types.Atom {
    const obj = (try symbolConstructorTable(c)) orelse return null;
    const reg = try c.ts.regular(t);
    for (0..c.ts.objectPropCount(obj)) |i| {
        const p = c.ts.objectProp(obj, @intCast(i));
        if ((try c.ts.regular(p.ty)) != reg) continue;
        const key = ast.wellKnownSymbolKey(c.atomText(p.name)) orelse continue;
        return try c.internText(key);
    }
    return null;
}

fn keyofObjectTableUncached(c: *Checker, r: TypeId) Error!TypeId {
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (0..c.ts.objectPropCount(r)) |i| {
        const p = c.ts.objectProp(r, @intCast(i));
        // A `private`/`protected` class member is not a key. tsc's
        // `getLiteralTypeFromProperty` answers `never` for one, which is what
        // keeps `Pick<C, keyof C>` — and every mapped type over a class — to
        // the public surface. immich's test mocks are built that way
        // (`RepositoryInterface<T> = Pick<T, keyof T>` over repositories whose
        // `constructor(private db: …)` parameter property would otherwise be a
        // required key of every mock).
        if (p.nonPublic()) continue;
        // The SYMBOL this member is named by, if any — one memoized probe
        // per property; see `memberKeyKind`.
        const kind = try memberKeyKind(c, p.name);
        // A member declared with a computed ENUM-MEMBER key is NAMED by that
        // enum member even though the table keys it by the string value —
        // tsc's `symbol.links.nameType`. Without it `keyof M` came back as a
        // plain string-literal union and `T extends keyof M` no longer
        // satisfied `T extends E` (immich `src/utils/sync.ts:34`).
        if (c.key_name_types.get((@as(u64, r) << 32) | p.name)) |nt| {
            try parts.append(c.scratch(), nt);
            continue;
        }
        if (kind != types.no_type) {
            try parts.append(c.scratch(), kind);
            continue;
        }
        try parts.append(c.scratch(), try c.ts.makeStringLiteral(p.name, false));
    }
    if (c.ts.objectStringIndex(r) != 0) {
        // A `symbol`-keyed signature shares the string slot but its key
        // domain is `symbol`, not `string | number` — see
        // `obj_flag_symbol_index`. Without this a `unique symbol` argument
        // was rejected by every `keyof S` parameter over such a shape
        // (nestjs-cls' `ClsStore`, immich `config.repository.ts:302-304`).
        if (c.ts.objectFlags(r) & types.obj_flag_symbol_index != 0) {
            try parts.append(c.scratch(), types.symbol_type);
        } else if (c.ts.objectFlags(r) & types.obj_flag_mapped_keys != 0) {
            // The signature IS a mapped type's key set, and `keyof` of a mapped
            // type is its constraint: `keyof Record<string, V>` is `string`
            // alone, never `string | number`. See `obj_flag_mapped_keys`.
            try parts.append(c.scratch(), types.string_type);
        } else {
            try parts.append(c.scratch(), types.string_type);
            try parts.append(c.scratch(), types.number_type);
        }
    }
    // A numeric enum's reverse-mapping signature is not a key of the enum:
    // `keyof typeof E` is its member names, never `number`. See
    // `obj_flag_enum_index`.
    if (c.ts.objectNumberIndex(r) != 0 and
        c.ts.objectFlags(r) & types.obj_flag_enum_index == 0)
    {
        try parts.append(c.scratch(), types.number_type);
    }
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// `keyof T[]` / `keyof readonly T[]` / `keyof [A, B]` — the lib list
/// interface's member NAMES, its numeric index domain, and (for a tuple) the
/// literal names of its FIXED positions.
///
/// tsc reaches this through `getIndexType(getApparentType(t))`: an array or
/// tuple's apparent type is an `Array<T>` / `ReadonlyArray<T>` reference, so
/// `keyof string[]` is `number | "length" | "push" | "slice" | …` and
/// `keyof [A, B]` adds `"0" | "1"`. `readonly` picks `ReadonlyArray`, which
/// is what keeps `"push"` OUT of `keyof readonly string[]`.
///
/// **Read off the GENERIC table, never built here.** `keyofObjectTable` reads
/// names, visibility and index-signature presence only, all of which survive
/// substitution, so the element type is irrelevant — and building the table
/// from this walk is a measured disaster: materializing a generic member table
/// runs a declaration walk that can re-enter the very reference being
/// expanded, so WHEN it first runs is observable (see `lazyShapeOf`; hoisting
/// the construction into `keyofType` took excalidraw's sweep from 17
/// diagnostics to 279). `Checker.run` materializes both tables once, at its
/// top, before any expansion is in flight; here we only read what it left.
/// With no lib (or no table) the answer degrades to the old `number`
/// approximation.
fn arrayKeySet(c: *Checker, r: TypeId) Error!TypeId {
    const s = &c.ts;
    const readonly = switch (s.kind(r)) {
        .array => s.arrayIsReadonly(r),
        .tuple => s.tupleIsReadonly(r),
        else => false,
    };
    const generic = (if (readonly) c.readonly_array_generic else c.array_generic) orelse
        return types.number_type;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    try parts.append(c.scratch(), try keyofObjectTable(c, generic));
    // A tuple's FIXED positions are real properties of it (tsc's
    // `getPropertyOfType(tuple, "0")`), so their names are keys on top of the
    // borrowed list members. The variable part is not: `[A, ...B[]]` has no
    // `"1"` key, only the `number` domain the list interface already gave.
    if (s.kind(r) == .tuple) {
        var buf: [16]u8 = undefined;
        for (0..tuple_relate.fixedLength(c, r)) |i| {
            const name = try c.internText(std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue);
            try parts.append(c.scratch(), try s.makeStringLiteral(name, false));
        }
    }
    return s.makeUnion(c.scratch(), parts.items);
}

/// The answer for an operand whose key set cannot be read right now: its
/// structure is still materializing further down this stack, or the walk has
/// come back around to it.
///
/// A `.ref` DEFERS. It is NOT the same thing as `any`: answering the full
/// `string | number | symbol` domain bakes that answer into whatever composite
/// is being built — react-hook-form's `Merge<A, B>` interned `keyof A & keyof
/// B` as `("message"|…) & (string|number|symbol)`, so every key took the "in
/// both" branch and `FieldErrors<T>[k]` came out with `unknown` members.
/// Deferring keeps `keyof <ref>` reducible. Anything else has no deferred form
/// to fall back to and answers the whole key domain.
fn unreadableKeySet(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .ref) return c.ts.makeKeyof(t);
    return c.makeUnion2(types.string_type, c.makeUnion2(types.number_type, types.symbol_type) catch unreachable);
}

/// keyof T for the resolved structural type (object-ish only; the v0.0.1
/// subset has non-generic keys).
pub fn keyofType(c: *Checker, t: TypeId) Error!TypeId {
    // `keyof` reads member NAMES and the `private`/`protected` flag, and both
    // survive instantiation untouched — so an interface/class reference
    // answers off its generic table without substituting a single member (see
    // `lazyShapeOf`). This was by a wide margin the checker's largest
    // materialization site: a mapped type over a generic repository interface
    // expanded that interface's whole table per argument list only to read the
    // names back out of it.
    if (try c.lazyShapeOf(t)) |generic| return keyofObjectTable(c, generic);
    // The member table is being built further down this stack — a member
    // whose type is inferred ran an expression check that came back here —
    // so nothing can read it and `resolveStructural` below would take
    // `expandRef`'s cycle cut. Member NAMES are a function of the
    // declarations, and reading them there is what makes this answer
    // independent of who asked first. See `keyofInProgressRef`.
    if (try c.keyofInProgressRef(t)) |k| return k;
    // This operand's key set is already being computed further up the stack.
    // A recursive conditional alias can resolve to a union that has the alias
    // itself as a constituent, and the `.union_type` arm below asks for each
    // constituent's key set in turn — so the walk comes straight back here on
    // the same type and recursed until the stack died. Its key set is exactly
    // as unreadable as a structure still materializing, and gets the same
    // answer.
    // …and the same answer once the walk is deeper than any real key set
    // nests. The laps are not always the same type: each expansion of a
    // recursive conditional alias mints a fresh one, so no visited set closes
    // it and only a depth bound can. See `max_keyof_depth`.
    if (std.mem.indexOfScalar(TypeId, c.keyof_stack.items, t) != null or
        c.keyof_stack.items.len >= checker_zig.max_keyof_depth)
    {
        return unreadableKeySet(c, t);
    }
    try c.keyof_stack.append(c.cm(), t);
    defer _ = c.keyof_stack.pop();
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        // A `.ref` that does not resolve to a structure is a reference whose
        // key set we cannot read yet — a self-recursive alias whose body is
        // still materializing resolves to `error` through `expandRef`'s cycle
        // cut.
        .err => return unreadableKeySet(c, t),
        // `keyof any` AND `keyof never` are both the whole key domain — the
        // last line of tsc's `getIndexType` tests them together
        // (`type.flags & (TypeFlags.Any | TypeFlags.Never) ? stringNumberSymbolType`),
        // and only `keyof unknown` is `never`. Reading `keyof never` as `never`
        // (the `else` arm below) empties every mapped type built over it, and
        // `{ [K in keyof never]: … }` is not a curiosity: `hoist-non-react-
        // statics`' `NonReactStatics<S>` maps over `keyof S`, and
        // styled-components hands it `never` for every non-component inner tag
        // (`StyledComponent<C, …> = string & StyledComponentBase<…> &
        // NonReactStatics<C extends ComponentType<any> ? C : never>`). Emptied,
        // that member vanishes from the intersection, `typeof SomeStyled` stops
        // satisfying `AnyStyledComponent`, `styled(Component)` falls to the
        // wrong overload, and every prop of every wrapped styled component is
        // checked against the wrong target.
        .any, .never => return c.makeUnion2(types.string_type, c.makeUnion2(types.number_type, types.symbol_type) catch unreachable),
        .object => return keyofObjectTable(c, r),
        .array, .tuple => return arrayKeySet(c, r),
        // `keyof typeof N` for a namespace or class value. `.class_value`
        // is a nominal shortcut carrying no properties of its own, so it
        // fell to the `else` arm and collapsed to `never` — and a namespace
        // is exactly how ztsc models the value side of an `export =
        // <namespace>` module, which is what `@types/react` and every
        // `declare namespace X; export = X` package is. An empty key set
        // silently empties every constraint built on it (vitest's `spyOn`
        // rejects `"useRef"`). Members come from the same place property
        // access reads them, `classStaticType`.
        .class_value => {
            const statics = try c.classStaticType(c.ts.classSymbol(r));
            if (statics == r) return types.never_type; // self-referential: no members
            return c.keyofType(statics);
        },
        // `keyof` of a mapped type reflects its key set (closing the
        // loop with mapped types): `keyof { [K in "a"|"b"]: X }` === `"a" | "b"`.
        // The key set is the constraint (homomorphic → `keyof source`),
        // possibly narrowed by an `as` remap. A generic key set stays
        // deferred; a concrete `as` clause is applied per key.
        .mapped => return c.keyofMapped(r),
        // `keyof (A & B) === keyof A | keyof B` (tsc `getIndexType` maps over
        // the intersection constituents and unions the per-constituent key
        // sets). A concrete param-free intersection would otherwise fall to
        // the `else` arm and wrongly collapse to `never`, so a conditional
        // `K extends keyof (A & B)` (react-hook-form `PathValue`/`FieldPath`
        // over an intersection form type) took its false arm. Per-member
        // deferral is automatic: a generic constituent's `keyofType` returns
        // its own deferred `keyof`, which the union carries and reduces once
        // that constituent is known.
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            // `memberList` DUPES the member ids onto scratch before the loop.
            // Iterating `c.ts.members(r)` directly would be a use-after-
            // realloc: the recursive `keyofType(m)` interns new composite
            // types (its own `makeUnion`, and — under instantiation — nested
            // `instantiate` calls), which append to the store's `extra`
            // array and can move its backing buffer, dangling a live slice
            // captured from `members(r)`. A later iteration would then read a
            // stale/garbage member id (in Debug a 0xAA-poison bounds panic;
            // in ReleaseFast an unchecked garbage read). Every other member-
            // iterating site that interns in its body already dupes first.
            for (try c.memberList(r)) |m| {
                try parts.append(c.scratch(), try c.keyofType(m));
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        // `keyof (A | B) === keyof A & keyof B` (tsc `getIndexType` maps
        // over the union constituents and *intersects* the per-constituent
        // key sets — only a key present on every constituent can be read
        // off the union). Without this arm a concrete union fell to the
        // `else` and collapsed to `never`, so every `Omit`/`Pick`/
        // `Required` over a discriminated union materialized as `{}` — and,
        // through the `.intersection` arm above, `keyof (Union & {index})`
        // came out as just `"index"`.
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            // `memberList` dupes first for the same reason as the
            // `.intersection` arm above: `keyofType(m)` interns.
            for (try c.memberList(r)) |m| {
                try parts.append(c.scratch(), try c.keyofType(m));
            }
            return c.intersectKeySets(parts.items);
        },
        // A generic operand (a type param or another deferred node) → a
        // deferred `keyof` that resolves on instantiation. `keyof T` is not
        // computable until `T` is known, so it must not collapse to `never`.
        .type_param, .index_access, .conditional, .keyof_op, .infer_var, .this_type => return c.ts.makeKeyof(r),
        else => {
            if (try c.containsTypeParam(r)) return c.ts.makeKeyof(r);
            return types.never_type;
        },
    }
}

/// Intersect per-constituent key sets for `keyof (A | B | …)`.
///
/// tsc builds `getIntersectionType(map(constituents, getIndexType))` and
/// leans on intersection reduction over literal types to collapse it to the
/// common keys. ztsc's `makeIntersection` is purely canonical (flatten /
/// dedup / sort) and does not reduce a literal-union intersection, so the
/// common set is computed here directly whenever it is *enumerable*:
/// every constituent key set consists of key literals and/or the whole
/// primitive key domains (`string` / `number` / `symbol`, which is what an
/// index signature or `keyof any` contributes). A key survives when every
/// other set contains it — either literally, or via the primitive domain it
/// belongs to, which is what makes `keyof ({ [k: string]: V } | { a: 1 })`
/// come out as `"a"` rather than `never`.
///
/// A non-enumerable set (a deferred `keyof T`, a type param, …) means the
/// answer is not yet computable, so the intersection is left symbolic and
/// reduces on instantiation.
pub fn intersectKeySets(c: *Checker, parts: []const TypeId) Error!TypeId {
    const s = &c.ts;
    // Pick the base: the first fully-literal set (a primitive domain is a
    // filter, never an enumeration). Bail out to a symbolic intersection as
    // soon as any set is not enumerable.
    var base: ?TypeId = null;
    for (parts) |p| {
        if (!c.keySetEnumerable(p)) return s.makeIntersection(c.scratch(), parts);
        if (base == null and c.keySetAllLiterals(p)) base = p;
    }
    const b = base orelse return s.makeIntersection(c.scratch(), parts);
    var keep: std.ArrayList(TypeId) = .empty;
    defer keep.deinit(c.scratch());
    for (try c.keySetMembers(b)) |k| {
        for (parts) |p| {
            if (p == b) continue;
            if (!c.keySetHas(p, k)) break;
        } else try keep.append(c.scratch(), k);
    }
    return s.makeUnion(c.scratch(), keep.items);
}

/// The constituents of a key set, as a scratch-owned slice (a lone key is
/// wrapped, `never` is the empty set).
pub fn keySetMembers(c: *Checker, t: TypeId) Error![]const TypeId {
    if (c.ts.kind(t) == .union_type) return c.memberList(t);
    if (t == types.never_type) return &.{};
    return c.scratch().dupe(TypeId, &.{t});
}

/// A key set every constituent of which is a key literal or a whole
/// primitive key domain — the shape `intersectKeySets` can compute with.
pub fn keySetEnumerable(c: *Checker, t: TypeId) bool {
    if (t == types.never_type) return true;
    if (c.ts.kind(t) == .union_type) {
        for (c.ts.members(t)) |m| if (!isKeyAtom(c.ts.kind(m))) return false;
        return true;
    }
    return isKeyAtom(c.ts.kind(t));
}

/// As above, but rejecting the primitive domains: only such a set can serve
/// as the enumeration `intersectKeySets` filters.
pub fn keySetAllLiterals(c: *Checker, t: TypeId) bool {
    if (t == types.never_type) return true;
    if (c.ts.kind(t) == .union_type) {
        for (c.ts.members(t)) |m| if (!isKeyLiteral(c.ts.kind(m))) return false;
        return true;
    }
    return isKeyLiteral(c.ts.kind(t));
}

/// Does key set `set` contain key literal `k` — literally, or through the
/// primitive domain `k` belongs to?
pub fn keySetHas(c: *Checker, set: TypeId, k: TypeId) bool {
    const dom: TypeId = switch (c.ts.kind(k)) {
        .string_literal, .template_literal_type, .string_mapping => types.string_type,
        .number_literal, .number_literal_fresh => types.number_type,
        .unique_symbol => types.symbol_type,
        else => 0,
    };
    if (c.ts.kind(set) == .union_type) {
        for (c.ts.members(set)) |m| if (m == k or (dom != 0 and m == dom)) return true;
        return false;
    }
    return set == k or (dom != 0 and set == dom);
}

pub fn isKeyLiteral(k: types.Kind) bool {
    return switch (k) {
        .string_literal, .number_literal, .number_literal_fresh, .unique_symbol, .template_literal_type, .string_mapping => true,
        else => false,
    };
}

pub fn isKeyAtom(k: types.Kind) bool {
    return isKeyLiteral(k) or switch (k) {
        .string, .number, .symbol => true,
        else => false,
    };
}

/// `keyof` of a (deferred) mapped type: its key set. Non-remapped maps use
/// the constraint directly (homomorphic → `keyof source`); an `as` clause
/// with concrete keys is applied per member so `Omit`-style filtering and
/// renames are reflected.
pub fn keyofMapped(c: *Checker, m: TypeId) Error!TypeId {
    const s = &c.ts;
    // Enumerating the remapped key set asks the `as` clause about one key at a
    // time, and an `as` clause may name `keyof` of the map it is renaming for
    // (see `keyof_mapped_active`). Answering "the key set is whatever the key
    // set is" is not possible; defer, exactly as a non-enumerable constraint
    // does below.
    if (c.keyof_mapped_active.contains(m)) return s.makeKeyof(m);
    try c.keyof_mapped_active.put(c.cm(), m, {});
    defer _ = c.keyof_mapped_active.remove(m);
    const homomorphic = s.mappedHomomorphic(m);
    const constraint: TypeId = if (homomorphic)
        try c.keyofType(s.mappedSource(m))
    else
        s.mappedConstraint(m);
    const as_clause = s.mappedAs(m);
    if (as_clause == 0) return constraint;
    // With an `as` remap, the keys are the remapped set. Only enumerate
    // when the constraint is a concrete literal / union of literals;
    // otherwise defer via a keyof over the whole mapped type.
    const key_id = s.mappedParamId(s.mappedKeyParam(m));
    var keys_buf = [_]TypeId{constraint};
    const keys: []const TypeId = if (s.kind(constraint) == .union_type)
        try c.memberList(constraint)
    else
        keys_buf[0..];
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (keys) |k| {
        switch (s.kind(k)) {
            .string_literal, .number_literal, .number_literal_fresh => {
                const nm = (try c.remapKey(as_clause, key_id, k)) orelse continue;
                try parts.append(c.scratch(), try s.makeStringLiteral(nm, false));
            },
            else => return c.ts.makeKeyof(m), // non-enumerable key set — defer
        }
    }
    return s.makeUnion(c.scratch(), parts.items);
}

/// T[K] with literal / index-signature keys (non-generic subset).
///
/// The looked-up member may itself mention the home instance's polymorphic
/// `this` (zod's `parse(): output<this>`); `Obj["parse"]` must read that as
/// `Obj`, the receiver the access names. tsc gets this for free — it resolves
/// a type reference's members with the reference as `thisArgument` — so the
/// substitution rides on the answer here instead. A no-op (one `has_this_types`
/// test) for the overwhelming majority of programs, which declare no `this`
/// type at all.
pub fn indexedAccessType(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
    return c.substThis(try indexedAccessTypeInner(c, obj, idx), obj);
}

fn indexedAccessTypeInner(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
    // `C["m"]` written while `C`'s own instance type is being materialized
    // (a member signature mentions an alias that indexes back into the
    // class). The whole-table expansion cannot answer, but the single
    // member can — see `lazyRefProp`.
    if (c.ts.kind(idx) == .string_literal and c.refExpansionActive(obj)) {
        // An access on a GENERIC object is one tsc never performs here: it
        // answers with a deferred `IndexedAccessType` and resolves the
        // property only once the object is instantiated with real arguments,
        // by which time the member's own type exists. ztsc resolves it
        // eagerly, so a member reached this way can re-enter its own
        // resolution where tsc never would (`readonly _: { …; inferSelect:
        // Infer<Table<T>> }`, where `Infer` indexes `Table<T>['_']`). The
        // lookup is unchanged — the cut answers as it always did — but a
        // circle closed under one of these must not be *named*. Only the
        // object is recorded here; whether it is generic is asked on the
        // cycle path alone (`lazy_index_objs`), which costs the hot path a
        // push and a pop.
        try c.lazy_index_objs.append(c.cm(), obj);
        defer _ = c.lazy_index_objs.pop();
        if (try c.lazyRefProp(obj, c.ts.literalAtom(idx))) |p| {
            return if (p.optional() and !c.homo_index_mode) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        }
    }
    // ONE member of a nominal reference, instead of its whole table — but only
    // once this checker has already run out of instantiation room at least
    // once. See `lazyIndexedProp` for why the gate is the design and not a
    // safety belt.
    if (c.inst_ceiling_trips != 0 and c.ts.kind(idx) == .string_literal) {
        if (try lazyIndexedProp(c, obj, c.ts.literalAtom(idx))) |p| {
            return if (p.optional() and !c.homo_index_mode) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        }
    }
    const r = try c.resolveStructural(obj);
    // An indexed access over a *union object* distributes over its members:
    // `(A | B)[K]` = `A[K] | B[K]` (tsc's getIndexedAccessType). `propOfType`
    // has no union arm, so without this a `(typeof arr)[number]['key']` shape
    // (a union of object-literal element types indexed by a name) fell
    // through to `unknown`, dropping the literal-key union — which then made
    // `Record<that, V>`'s keys vanish from `keyof (Named & Record<…>)`.
    if (c.ts.kind(r) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(r)) |m| {
            try parts.append(c.scratch(), try c.indexedAccessType(m, idx));
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    switch (c.ts.kind(idx)) {
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(idx)) |m| {
                try parts.append(c.scratch(), try c.indexedAccessType(obj, m));
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        // A SYMBOL key — `I[typeof s]`, and every distribution of
        // `I[keyof I]` over a table with a symbol-named member. The member is
        // stored under the synthetic atom that names the symbol, so the
        // lookup is the string-literal arm's with `symbolKeyAtom` in place of
        // `literalAtom`; a `symbol`-domain index signature is the fallback,
        // the way `objectStringIndex` is for a string key.
        .unique_symbol => {
            if (try symbolKeyAtom(c, idx)) |name| {
                if (try c.propOfType(r, name)) |p| {
                    return if (p.optional() and !c.homo_index_mode) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                }
            }
            if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0 and
                c.ts.objectFlags(r) & types.obj_flag_symbol_index != 0)
            {
                return c.ts.objectStringIndex(r);
            }
            return switch (c.ts.kind(r)) {
                .any, .err => types.any_type,
                else => types.unknown_type,
            };
        },
        .string_literal => {
            if (try c.propOfType(r, c.ts.literalAtom(idx))) |p| {
                return if (p.optional() and !c.homo_index_mode) c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            }
            if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0) {
                return c.ts.objectStringIndex(r);
            }
            // Property genuinely absent (no index signature). tsc's
            // `getIndexedAccessType` resolves a missing type-level access
            // to `unknown`, NOT `any` — decisive for a conditional check
            // type like `TOpt['returnObjects'] extends true`: an absent
            // property must yield the FALSE branch (`unknown extends true`
            // is false), whereas `any extends true` wrongly took the true
            // branch (i18next `t()` → `$SpecialObject` instead of `string`).
            // An `any`/error object still indexes to `any`.
            return switch (c.ts.kind(r)) {
                .any, .err => types.any_type,
                else => types.unknown_type,
            };
        },
        .number_literal, .number_literal_fresh => {
            // A concrete numeric index into a tuple selects that element
            // (matching tsc) — this is also what makes a homomorphic map
            // over a tuple preserve per-element types. A *branded* tuple
            // (`[X, Y] & { _brand }`) indexes through its tuple
            // constituent, the same way tsc finds the numeric key among the
            // intersection's properties.
            const rt = if (c.ts.kind(r) == .intersection)
                (try c.indexableConstituent(r)) orelse r
            else
                r;
            if (c.ts.kind(rt) == .tuple) {
                const v = c.ts.numberValue(idx);
                if (v == @floor(v) and v >= 0) {
                    const i: u32 = @intFromFloat(v);
                    if (i < c.ts.tupleLen(rt)) {
                        const e = c.ts.tupleElem(rt, i);
                        if (e.rest()) return try c.elemOfArrayish(e.ty);
                        // An *optional* tuple element indexes to
                        // `T | undefined` (tsc's `getIndexedAccessType` over
                        // `[x?: T]` at `[0]`), the same undefined-widening the
                        // string-literal arm applies to an optional property.
                        // Decisive for the dogfood project's `VariantProps`
                        // chain: with a correct `Parameters<C>` tuple whose
                        // first element is optional (`[props?: P]`),
                        // `Parameters<C>[0]` must be `P | undefined` so
                        // `OmitUndefined<…>` then strips it — dropping the
                        // `undefined` here left ztsc over-strict and rejected
                        // valid JSX props (TS2322 `IntrinsicAttributes & X`).
                        return if (e.optional() and !c.homo_index_mode)
                            c.makeUnion2(e.ty, types.undefined_type)
                        else
                            e.ty;
                    }
                }
            }
            // A NUMERICALLY NAMED property answers a numeric key, exactly as
            // the string-literal arm answers a named one — tsc's
            // `getPropertyOfType(objectType, "0")` runs before it ever looks
            // for an index signature. Without it `{ 0: string; 1: string }[0]`
            // (and every mapped type over a NUMERIC enum, whose keys are the
            // members' values) answered `any` off `numberIndexType`, which has
            // no signature to read.
            if (try c.numericKeyProp(r, idx)) |p| {
                return if (p.optional() and !c.homo_index_mode)
                    c.makeUnion2(p.ty, types.undefined_type)
                else
                    p.ty;
            }
            return c.numberIndexType(r);
        },
        .number => return c.numberIndexType(r),
        .string => {
            if (c.ts.kind(r) == .object and c.ts.objectStringIndex(r) != 0) {
                return c.ts.objectStringIndex(r);
            }
            return types.any_type;
        },
        // `T[never]` is `never` (tsc's getIndexedAccessType short-circuits an
        // empty index set). Reaching the `any` fallback below instead poisons
        // any union that contains such an access — `keyof {}` is `never`, and
        // @types/react builds `ReactNode` as `… | Empty[keyof Empty]`, so the
        // whole union collapsed to `any` and every ReactNode-contextual
        // callback parameter became an implicit any.
        .never => return types.never_type,
        // A BRANDED key (`FontString = string & { _brand }`, the whole
        // `Ordered`/`FontString` family) is an intersection, not one of the
        // kinds above, and fell through to `any` — so every read through
        // `{ [key: FontString]: T }` lost its type. tsc classifies the index
        // by `TypeFlags.StringLike` / `NumberLike`, so reduce a string-like
        // (number-like) index to its base primitive and re-enter.
        else => {
            const ri = try c.resolveStructural(idx);
            // An ENUM MEMBER index names the property its VALUE spells: a
            // member table keys a computed enum key by the value
            // (`literalKeyAtom`), and so does a mapped type over an enum
            // domain. Falling through to the string-like arm below indexed by
            // `string` instead, which answers `any` for a table with no string
            // index signature — immich's
            // `Jobs = { [K in JobItem['name']]: (JobItem & { name: K })['data'] }`
            // read through `JobOf<JobName.LibrarySyncFiles>` handed back `any`
            // and every callback under it lost its parameter types.
            if (c.ts.kind(ri) == .enum_type) {
                if (c.ts.isEnumMember(ri)) {
                    if (try c.enumMemberValue(c.ts.enumSymbol(ri), c.ts.enumMemberAtom(ri))) |v| {
                        return c.indexedAccessType(obj, try c.ts.regularLiteral(v));
                    }
                } else if (try c.enumMemberTypeUnion(c.ts.enumSymbol(ri), 0)) |mu| {
                    // A WHOLE enum index is tsc's union of its members.
                    if (mu != ri) return c.indexedAccessType(obj, mu);
                }
            }
            if (try c.typeIsStringLike(ri)) return c.indexedAccessType(obj, types.string_type);
            if (try c.typeIsNumberLike(ri)) return c.numberIndexType(r);
            return types.any_type;
        },
    }
}

/// TS2536 — "Type 'K' cannot be used to index type 'T'" (tsc's
/// `checkIndexedAccessIndexType`, run on the type NODE that produced the
/// access).
///
/// Only a DEFERRED access is checked, exactly as tsc gates on
/// `TypeFlags.IndexedAccess`: a concrete `T[K]` has already been resolved by
/// `indexedAccessType`, which answers `unknown` for an absent key and never
/// leaves anything for this check to say.
///
/// tsc runs it on every deferred access and leans on its substitution types
/// plus a constraint-chasing relation to clear the generic keys; ztsc has
/// neither, so the literal transcription — "is the index assignable to
/// `keyof obj`" — rejects the whole mapped/conditional family
/// (`{ [P in K]: T[P] }`, `K extends keyof O ? O[K] : D`, `Form[infer K]`),
/// none of which tsc reports. The check is therefore restricted to the
/// DECIDABLE shape:
///
///   * the object is a bare TYPE PARAMETER with a written constraint (read
///     straight off the declaration — no `baseConstraintOf` instantiation
///     pass, which would spend the statement's TS2589 budget on a check);
///   * the index is a single string-literal key, not a type variable,
///     `infer` binder, mapped key or key union (a NUMERIC key is left alone:
///     its answer comes from index signatures and lib members ztsc
///     approximates — `T["length"]` under `T extends readonly any[]`, the
///     `IsTuple`/`Parameters<F>["length"]` arity guard);
///   * the constraint is a plain OBJECT type with no index signature, and
///     the key is absent from it. Absence is asked with `propOfType` — the
///     same lookup the concrete access path uses, so inheritance and
///     declaration merging answer here exactly as they do there, which an
///     enumerated `keyofType` key set does not (drizzle's
///     `MySqlDeleteBase`'s `_` comes from the merged interface half);
///   * the access is not inside a conditional type's TRUE branch, where tsc's
///     substitution types narrow the check type to its `extends` type and
///     admit keys the declared constraint does not have (`T extends
///     ZodObject<…> ? … T["shape"] …`, zod's `DeepPartial`; the same gap
///     `condTrueUnderExtends` names on the relation side).
///
/// Everything else stays silent — a deterministic under-report, never a
/// false positive.
///
/// The access type is returned UNCHANGED (tsc substitutes `errorType`):
/// downstream assignability still reports the TS2322 through the unusable
/// access, which is the diagnostic that keeps the bad value from passing.
pub fn checkIndexedAccessIndexType(c: *Checker, acc: TypeId, node: Node) Error!void {
    if (c.ts.kind(acc) != .index_access) return;
    if (c.cond_true_depth > 0) return;
    const obj = c.ts.indexAccessObj(acc);
    if (c.ts.kind(obj) != .type_param) return;
    const idx = try c.ts.regularLiteral(c.ts.indexAccessIndex(acc));
    if (c.ts.kind(idx) != .string_literal) return;
    const con = try c.typeParamConstraint(c.ts.typeParamSymbol(obj));
    if (con == types.no_type) return;
    const bc = try c.resolveStructural(con);
    // A shape whose members are knowable. `any`/`err`/`unknown`, a
    // still-deferred mapped/conditional form, an array/tuple (approximate
    // key set) and the primitives are all "cannot tell".
    if (c.ts.kind(bc) != .object) return;
    if (c.ts.objectStringIndex(bc) != 0 or c.ts.objectNumberIndex(bc) != 0) return;
    // A CLASS instance constraint is not authoritative: a same-named
    // interface merges extra members into it (drizzle's `MySqlDeleteBase`
    // declares its `_` on the interface half), and ztsc does not model that
    // merge — reporting here would turn one modelling gap into a second,
    // louder one.
    if (c.refFacetOf(bc, c.ts.kind(bc))) |r| {
        if (c.symFlags(c.ts.refSymbol(r)).class) return;
    }
    if (try c.propOfType(bc, c.ts.literalAtom(idx)) != null) return;
    try c.diagFmt(2536, c.nodeSpan(node), "Type '{s}' cannot be used to index type '{s}'.", .{
        try c.typeToString(idx), try c.typeToString(obj),
    });
}

/// tsc's `TypeFlags.NumberLike` over a resolved type (union/intersection
/// scan, as in `maybeTypeOfKind`).
pub fn typeIsNumberLike(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .number, .number_literal, .number_literal_fresh => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (try c.typeIsNumberLike(try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn numberIndexType(c: *Checker, r: TypeId) Error!TypeId {
    switch (c.ts.kind(r)) {
        .array => return c.ts.arrayElem(r),
        .tuple => {
            if (c.inst_cache_on) {
                if (c.arrayish_elem_cache.get(r)) |hit| return hit;
            }
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..c.ts.tupleLen(r)) |i| {
                const e = c.ts.tupleElem(r, @intCast(i));
                const et = if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
                try parts.append(c.scratch(), et);
            }
            const u = try c.ts.makeUnion(c.scratch(), parts.items);
            if (c.inst_cache_on) try c.arrayish_elem_cache.put(c.cm(), r, u);
            return u;
        },
        .object => {
            if (c.ts.objectNumberIndex(r) != 0) return c.ts.objectNumberIndex(r);
            if (c.ts.objectStringIndex(r) != 0) return c.ts.objectStringIndex(r);
            return types.any_type;
        },
        .intersection => {
            if (try c.indexableConstituent(r)) |m| return c.numberIndexType(m);
            return types.any_type;
        },
        .string => return types.string_type,
        // A class VALUE's index signatures are declared `static` and live on
        // its static-side object, which `resolveStructural` does not unwrap to:
        // `class C { static [s: number]: 42 }` makes `C[2]` a `42`, not `any`.
        .class_value => return c.numberIndexType(try c.classStaticType(c.ts.classSymbol(r))),
        else => return types.any_type,
    }
}

/// Upper bound on the constituents of a distributed element access. The work
/// is linear in this number and the key sets that need it are hand-written
/// unions; a wider key set keeps the caller's `any`.
pub const max_union_index_keys = 64;

/// Why a distributed element access did not resolve — the constituent that
/// stopped it, so the caller can REPORT the key set instead of silently
/// keeping the `any` the access falls back to.
pub const UnionIndexMiss = union(enum) {
    /// Not attempted, or not decidable here (a non-literal constituent, a
    /// key set too wide to walk, an approximate receiver): stay silent.
    none,
    /// A key literal the receiver has neither a member nor an index
    /// signature for → the access is an implicit 'any' (TS7053).
    absent_key,
    /// A numeric key past the end of a tuple (TS2493). The tuple is the one
    /// actually indexed (a branded tuple indexes through its constituent).
    tuple_range: struct { tuple: TypeId, index: u32 },
};

/// A distributed element access either resolved to an element type or stopped
/// on a constituent (`UnionIndexMiss`).
pub const UnionIndexResult = union(enum) {
    resolved: TypeId,
    miss: UnionIndexMiss,
};

/// `o[k]` where the KEY is a union of literals: tsc's `getIndexedAccessType`
/// distributes, so the access is `o[k1] | o[k2] | …`. Answers a `.miss` —
/// leaving the caller's own single-key handling in charge — unless every
/// constituent resolves, so a key set that is partly unknown still reaches the
/// caller's implicit-any reporting instead of being silently narrowed here.
///
/// A `.miss` names the constituent that stopped a distribution, but only
/// where the answer is certain: a receiver whose member set ztsc models
/// exactly (an object, or a union/intersection of them) for an absent key, a
/// tuple for an out-of-range numeric key. Array/tuple *string* keys and every
/// non-literal constituent answer `.miss = .none` — their key sets involve lib
/// members ztsc approximates, and a wrong "cannot index" there would be a
/// false positive.
pub fn unionIndexElemType(c: *Checker, r: TypeId, idx_t: TypeId) Error!UnionIndexResult {
    if (c.ts.kind(idx_t) != .union_type) return .{ .miss = .none };
    const rk = c.ts.kind(r);
    // A branded tuple indexes through its tuple constituent, as in the
    // single-number-literal arm.
    const rt = if (rk == .intersection)
        (try c.indexableConstituent(r)) orelse r
    else
        r;
    const keys = try c.memberList(idx_t);
    if (keys.len == 0 or keys.len > max_union_index_keys) return .{ .miss = .none };
    const parts = try c.scratch().alloc(TypeId, keys.len);
    for (keys, 0..) |k, i| {
        const rl = try c.ts.regularLiteral(k);
        switch (c.ts.kind(rl)) {
            .string_literal => {
                const name = c.ts.literalAtom(rl);
                if (try c.propOfType(r, name)) |p| {
                    parts[i] = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                } else if (rk == .object and c.ts.objectStringIndex(r) != 0) {
                    parts[i] = c.ts.objectStringIndex(r);
                } else {
                    const certain = rk == .object or rk == .union_type or rk == .intersection;
                    return .{ .miss = if (certain) .absent_key else .none };
                }
            },
            .number_literal => {
                if (c.ts.kind(rt) != .tuple) {
                    // A number-literal key names a property (`"2"`) just as a
                    // string-literal one does — tsc's
                    // `getPropertyNameFromIndex` — so a number-keyed lookup
                    // table distributes like any other. `BITS[bytes]` with
                    // `BITS = { 1: 8, 2: 16, 4: 32 } as const` and
                    // `bytes: 1 | 2 | 4` is `8 | 16 | 32`, not `any`.
                    if (try c.numericKeyProp(r, rl)) |p| {
                        parts[i] = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                        continue;
                    }
                    return .{ .miss = .none };
                }
                const v = c.ts.numberValue(rl);
                const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                if (iv < c.ts.tupleLen(rt)) {
                    const e = c.ts.tupleElem(rt, iv);
                    parts[i] = if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
                } else if (try c.tupleElemTypeAt(rt, iv)) |et| {
                    parts[i] = et;
                } else {
                    return .{ .miss = .{ .tuple_range = .{ .tuple = rt, .index = iv } } };
                }
            },
            else => return .{ .miss = .none },
        }
    }
    return .{ .resolved = try c.ts.makeUnion(c.scratch(), parts) };
}

/// The constituent of an intersection that carries element access — a
/// branded tuple/array (`[X, Y] & { _brand: "t" }`, the `Ordered`/`LocalPoint`
/// shape) or, failing that, the first constituent with an index signature.
///
/// tsc gets this for free: `getIndexedAccessType` looks the numeric key up
/// as a *property* of the intersection, and an intersection's property set
/// is the union of its constituents'. ztsc's element-access paths switch on
/// the resolved kind, so an intersection fell to the `else` and produced
/// `any` — which then classified `-t[0]` as `bigint` and let genuinely
/// wrong element types through unchecked. Returns null (leaving `any`) when
/// no constituent is indexable, and takes the first when several are: a
/// brand object contributes no elements, so the tuple/array constituent is
/// the answer whenever there is one.
pub fn indexableConstituent(c: *Checker, r: TypeId) Error!?TypeId {
    const members = try c.memberList(r);
    for (members) |m| {
        switch (c.ts.kind(m)) {
            .array, .tuple => return m,
            else => {},
        }
    }
    for (members) |m| {
        if (c.ts.kind(m) == .object and
            (c.ts.objectNumberIndex(m) != 0 or c.ts.objectStringIndex(m) != 0)) return m;
    }
    return null;
}
