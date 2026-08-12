//! Type-node conversion: AST type annotations -> TypeIds.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const Check = checker_zig.Check;
const check = checker_zig.check;

const annTypeMaybeUnique = Checker.annTypeMaybeUnique;
const atom = Checker.atom;
const checkIdentifier = @import("expr.zig").checkIdentifier;
const classStaticType = @import("enums.zig").classStaticType;
const expandRef = @import("instantiate.zig").expandRef;
const inferTypeArgs = @import("calls.zig").inferTypeArgs;
const inferVarFromNode = @import("generics.zig").inferVarFromNode;
const instantiate = @import("enums.zig").instantiate;
const lazyIndexedProp = @import("instantiate.zig").lazyIndexedProp;
const lazyRefProp = @import("instantiate.zig").lazyRefProp;
const mergeBaseObjectPlain = @import("instantiate.zig").mergeBaseObject;
const propOfType = @import("props.zig").propOfType;
const scopeOf = Checker.scopeOf;
const scratch = Checker.scratch;
const signatureAssignableModeInner = @import("assign.zig").signatureAssignableModeInner;
const signatureOfProto = @import("signatures.zig").signatureOfProto;

const typespace_zig = @import("typespace.zig");
const typeparams_zig = @import("typeparams.zig");

// =====================================================================
// re-exports
//
// The clusters extracted out of this file, re-exported under the names they
// had when they lived here: `checker.zig`'s method-alias block and several
// sibling modules import them from this file.
// =====================================================================

/// Type-space name resolution (typespace.zig).
pub const ModuleRef = typespace_zig.ModuleRef;
pub const NsContainer = typespace_zig.NsContainer;
pub const ambientIndex = typespace_zig.ambientIndex;
pub const augmentModuleTypeSym = typespace_zig.augmentModuleTypeSym;
pub const containerFromImportTarget = typespace_zig.containerFromImportTarget;
pub const containerMemberSym = typespace_zig.containerMemberSym;
pub const enumSymFromImportTarget = typespace_zig.enumSymFromImportTarget;
pub const enumSymOfQualifier = typespace_zig.enumSymOfQualifier;
pub const exportEqualsMemberSym = typespace_zig.exportEqualsMemberSym;
pub const importTypeMember = typespace_zig.importTypeMember;
pub const materializeTypeRef = typespace_zig.materializeTypeRef;
pub const mergedNsMemberOfScope = typespace_zig.mergedNsMemberOfScope;
pub const moduleExportTarget = typespace_zig.moduleExportTarget;
pub const namedTypeFromSymbol = typespace_zig.namedTypeFromSymbol;
pub const namespaceMemberSym = typespace_zig.namespaceMemberSym;
pub const nestNsContainer = typespace_zig.nestNsContainer;
pub const nsReexportProps = typespace_zig.nsReexportProps;
pub const qualifierText = typespace_zig.qualifierText;
pub const regularizeTypeQuery = typespace_zig.regularizeTypeQuery;
pub const resolveImportTypeModule = typespace_zig.resolveImportTypeModule;
pub const resolveNsContainer = typespace_zig.resolveNsContainer;
pub const targetTypeSym = typespace_zig.targetTypeSym;
pub const typeFromQualifiedName = typespace_zig.typeFromQualifiedName;
pub const typeFromTypeName = typespace_zig.typeFromTypeName;
pub const typeFromTypeNameEx = typespace_zig.typeFromTypeNameEx;
pub const typeMeaningTarget = typespace_zig.typeMeaningTarget;
pub const typeofEntity = typespace_zig.typeofEntity;
/// Type-parameter lists, instantiation maps and the TS2344 gate
/// (typeparams.zig).
pub const TypeParamInfo = typeparams_zig.TypeParamInfo;
pub const buildInstMap = typeparams_zig.buildInstMap;
pub const canonicalizeClassTypeParams = typeparams_zig.canonicalizeClassTypeParams;
pub const checkSigTypeArgConstraints = typeparams_zig.checkSigTypeArgConstraints;
pub const checkTypeArgConstraints = typeparams_zig.checkTypeArgConstraints;
pub const decidableConstraintSet = typeparams_zig.decidableConstraintSet;
pub const declTypeParams = typeparams_zig.declTypeParams;
pub const drainTypeArgConstraints = typeparams_zig.drainTypeArgConstraints;
pub const fixTypeArgs = typeparams_zig.fixTypeArgs;
pub const queueSigTypeArgConstraints = typeparams_zig.queueSigTypeArgConstraints;
pub const queueTypeArgConstraints = typeparams_zig.queueTypeArgConstraints;
pub const symHasConstrainedTypeParam = typeparams_zig.symHasConstrainedTypeParam;
pub const typeParamSymsOfDecl = typeparams_zig.typeParamSymsOfDecl;
pub const typeParamsOf = typeparams_zig.typeParamsOf;
pub const undecidableType = typeparams_zig.undecidableType;

// =====================================================================
// type-node conversion
// =====================================================================

pub fn typeFromTypeNode(c: *Checker, node: Node) Error!TypeId {
    if (node == null_node) return types.no_type;
    // A type annotation resolves names against its lexically-fixed scope
    // (and any enclosing interface's `this`), both determined by the node's
    // location — so its synthesized type is context-free and memoizable by
    // `(file, node)` alone. (Diagnostics emitted here dedupe on
    // `(file, code, span)`, so skipping re-evaluation is diagnostic-safe.)
    // Only *compound* nodes are cached: leaf annotations (a bare name or a
    // literal) recompute in O(1), so caching them is pure memory overhead —
    // the re-walk cost the memo targets lives in the recursive kinds. This
    // keeps the memo small on non-generic-heavy code (RSS-neutral) while
    // still collapsing repeated walks of nested generic/object/function
    // annotations.
    const cacheable = c.inst_cache_on and typeNodeCacheable(c.nodeTag(node));
    const key = c.nodeKey(node);
    if (cacheable) {
        if (c.type_node_cache.get(key)) |t| return t;
    }
    const result = try c.typeFromTypeNodeUncached(node);
    if (cacheable) try c.type_node_cache.put(c.cm(), key, result);
    return result;
}

/// Type-node kinds whose synthesis recurses into sub-nodes (so re-walking
/// is non-trivial and worth memoizing). Leaf kinds are excluded.
pub fn typeNodeCacheable(tag: ast.Tag) bool {
    return switch (tag) {
        .type_ref,
        .qualified_name,
        .array_type,
        .tuple_type,
        .union_type,
        .intersection_type,
        .object_type,
        .function_type,
        .constructor_type,
        .keyof_type,
        .typeof_type,
        .indexed_access_type,
        => true,
        else => false,
    };
}

pub fn typeFromTypeNodeUncached(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .identifier => return c.typeFromTypeName(node, &.{}),
        .type_ref => {
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            const arg_nodes = c.tree.extraRange(r.start, r.end);
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (arg_nodes) |an| {
                if (an != null_node) try args.append(c.scratch(), try c.typeFromTypeNode(an));
            }
            var target: SymbolId = binder.no_symbol;
            const result = try c.typeFromTypeNameEx(d.lhs, args.items, &target);
            if (target != binder.no_symbol) {
                try c.queueTypeArgConstraints(node, target, args.items);
            }
            return result;
        },
        .qualified_name => return c.typeFromQualifiedName(node, &.{}),
        .import_type => {
            // Bare `import("m")` in type position: resolve for discovery /
            // TS2307; the module namespace itself is not a type — `any`.
            _ = try c.resolveImportTypeModule(node, true);
            return types.any_type;
        },
        .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(node)), false),
        .template_literal => return c.ts.makeStringLiteral(try c.templateAtom(c.tree.nodeMainToken(node)), false),
        .number_literal => return c.ts.makeNumberLiteral(c.numberTokenValue(c.tree.nodeMainToken(node)), false),
        .bigint_literal => return c.ts.makeBigIntLiteral(try c.atomOfToken(c.tree.nodeMainToken(node)), false),
        .true_literal => return types.true_type,
        .false_literal => return types.false_type,
        .null_literal => return types.null_type,
        .prefix_unary => {
            // Negative numeric literal type `-1`.
            if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .minus and
                d.lhs != 0 and c.nodeTag(d.lhs) == .number_literal)
            {
                const v = c.numberTokenValue(c.tree.nodeMainToken(d.lhs));
                return c.ts.makeNumberLiteral(-v, false);
            }
            return types.any_type;
        },
        .array_type => return c.ts.makeArray(try c.typeFromTypeNode(d.lhs)),
        .tuple_type => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (c.tree.nodeRange(node)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    .optional_type => try elems.append(c.scratch(), .{
                        .ty = try c.typeFromTypeNode(ed.lhs),
                        .flags = types.elem_flag_optional,
                    }),
                    .rest_type => try elems.append(c.scratch(), .{
                        .ty = try c.typeFromTypeNode(ed.lhs),
                        .flags = types.elem_flag_rest,
                    }),
                    else => try elems.append(c.scratch(), .{ .ty = try c.typeFromTypeNode(el) }),
                }
            }
            return c.ts.makeTuple(elems.items);
        },
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (c.tree.nodeRange(node)) |m| {
                if (m != null_node) try parts.append(c.scratch(), try c.typeFromTypeNode(m));
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
        .intersection_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (c.tree.nodeRange(node)) |m| {
                if (m != null_node) try parts.append(c.scratch(), try c.typeFromTypeNode(m));
            }
            // tsc's `getTypeFromIntersectionTypeNode`: *"We perform no
            // supertype reduction for X & {} or {} & X, where X is a
            // primitive type"* — the two-member, source-WRITTEN form is the
            // `'a' | 'b' | (string & {})` idiom (a literal union that still
            // accepts any string), so the `{}` must survive there even
            // though the same intersection reduces to `X` when it arrives
            // by instantiation (`NonNullable<string>` is `string`). tsc's
            // opt-out covers exactly the non-unit string/number/bigint
            // primitives: a written `boolean & {}`, `symbol & {}`,
            // `'x' & {}` or `I & {}` all still reduce.
            if (parts.items.len == 2) {
                const ei: ?usize = if (parts.items[0] == types.empty_object_type)
                    0
                else if (parts.items[1] == types.empty_object_type) 1 else null;
                if (ei) |i| {
                    switch (c.ts.kind(parts.items[1 - i])) {
                        .string, .number, .bigint, .template_literal_type => {
                            return c.ts.makeIntersectionNoReduce(c.scratch(), parts.items);
                        },
                        else => {},
                    }
                }
            }
            return c.ts.makeIntersection(c.scratch(), parts.items);
        },
        .object_type => return c.objectTypeFromMembers(c.tree.nodeRange(node), 0),
        .function_type => return c.signatureOfProto(node, d.lhs, false, true),
        .constructor_type => {
            // `new (…) => R` / `abstract new (…) => R`: an object
            // type with a single construct signature and no call signature.
            // (Abstract-ness is not yet modelled — under-reports TS2511 on
            // `new (abstractCtor)()`, never a false positive.)
            const sig = try c.signatureOfProto(node, d.lhs, false, true);
            return c.ts.makeObjectSigs(&.{}, 0, 0, types.obj_flag_not_inferable, &.{}, &.{sig});
        },
        .keyof_type => return c.keyofType(try c.typeFromTypeNode(d.lhs)),
        .typeof_type => {
            const base = try c.typeofEntity(d.lhs);
            if (d.rhs == 0) return base;
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            return c.instantiationExprType(base, c.tree.extraRange(r.start, r.end), node);
        },
        .readonly_type => {
            // `readonly T[]` carries Array's members and relates exactly as
            // `T[]` does; the flag is only there for tsc's subtype-based
            // type-predicate narrowing (see `makeArrayReadonly`). Anything
            // else (`readonly [a, b]`) is unchanged.
            const inner = try c.typeFromTypeNode(d.lhs);
            if (c.ts.kind(inner) == .array and !c.ts.arrayIsReadonly(inner))
                return c.ts.makeArrayReadonly(c.ts.arrayElem(inner));
            return inner;
        },
        .unique_symbol_type => {
            // A `unique symbol` reached through the generic type path is in
            // a disallowed position (param, return, alias, array, union,
            // …). The allowed declaration sites (const variable, static
            // readonly field, readonly interface/type-literal property)
            // resolve it via `annTypeMaybeUnique` and never land here.
            try c.diagFmt(1335, c.nodeSpan(node), "'unique symbol' types are not allowed here.", .{});
            return c.uniqueSymType(node);
        },
        .indexed_access_type => {
            const obj = try c.typeFromTypeNode(d.lhs);
            const idx = try c.typeFromTypeNode(d.rhs);
            const acc = try c.reduceIndexedAccess(obj, idx);
            try c.checkIndexedAccessIndexType(acc, node);
            return acc;
        },
        .conditional_type => return c.conditionalTypeFromNode(node),
        .infer_type => return c.inferVarFromNode(node),
        .mapped_type_node => return c.mappedTypeFromNode(node),
        .template_literal_type_node => return c.templateTypeFromNode(node),
        .paren_type, .optional_type, .rest_type => return c.typeFromTypeNode(d.lhs),
        // A predicate in return-type position behaves like `boolean` for
        // a plain guard (`x is T`), or `void` for an assertion function
        // (`asserts ...`, rhs bit0). signatureOfProto attaches the
        // predicate; this keeps every other consumer (TS2355, etc.)
        // consistent.
        .type_predicate => return if (d.rhs != 0) types.void_type else types.boolean_type,
        // `this` in a TYPE position is tsc's `thisType`: a type *variable*
        // whose constraint is the home instance, not the instance itself.
        // The distinction only shows up when the `this` is an operand of a
        // deferred type operator — `this["k"]`, `F<this>` with a conditional
        // body — where resolving it eagerly would demand the home
        // interface's member table *while that table is being built*
        // (`expandRef` reports a cycle → `any`). Kept symbolic, the operator
        // stays deferred until `substThis` supplies a concrete receiver at
        // the access site, exactly as tsc resolves it. zod's
        // `parse(): output<this>` (→ `this["_zod"]["output"]`) is the shape
        // that needs it.
        .this_expr => {
            if (c.this_type == 0) return types.any_type;
            if (c.ts.kind(c.this_type) != .ref) return c.this_type;
            c.has_this_types = true;
            return c.ts.makeThisType(c.this_type);
        },
        .error_node, .unsupported => return types.any_type,
        else => return types.any_type,
    }
}

/// The mapped-type key parameter named `a` that is lexically in scope, or
/// null when there is none. Walks `mapped_key_scopes` innermost-out so an
/// inner map's `[K in …]` shadows a same-named enclosing one, and a SHADOW
/// entry (`ty == 0`, pushed for a signature's own type parameter) hides every
/// enclosing mapped key of that name.
pub fn lookupMappedKey(c: *Checker, a: Atom) ?checker_zig.MappedKeyScope {
    if (a == 0) return null;
    var i = c.mapped_key_scopes.items.len;
    while (i > 0) {
        i -= 1;
        const e = c.mapped_key_scopes.items[i];
        if (e.name == a) return if (e.ty == 0) null else e;
    }
    return null;
}

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
        // A member declared with a computed ENUM-MEMBER key is NAMED by that
        // enum member even though the table keys it by the string value —
        // tsc's `symbol.links.nameType`. Without it `keyof M` came back as a
        // plain string-literal union and `T extends keyof M` no longer
        // satisfied `T extends E` (immich `src/utils/sync.ts:34`).
        if (c.key_name_types.get((@as(u64, r) << 32) | p.name)) |nt| {
            try parts.append(c.scratch(), nt);
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
    if (c.ts.objectNumberIndex(r) != 0) try parts.append(c.scratch(), types.number_type);
    return c.ts.makeUnion(c.scratch(), parts.items);
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
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .err => {
            // A `.ref` that does not resolve to a structure is NOT the same
            // thing as `any`: it is a reference we cannot read the key set of
            // yet (a self-recursive alias whose body is still materializing
            // resolves to `error` through `expandRef`'s cycle cut). Answering
            // the full `string | number | symbol` domain bakes that answer
            // into whatever composite is being built — react-hook-form's
            // `Merge<A, B>` interned `keyof A & keyof B` as
            // `("message"|…) & (string|number|symbol)`, so every key took the
            // "in both" branch and `FieldErrors<T>[k]` came out with `unknown`
            // members. Deferring keeps `keyof <ref>` reducible.
            if (c.ts.kind(t) == .ref) return c.ts.makeKeyof(t);
            return c.makeUnion2(types.string_type, c.makeUnion2(types.number_type, types.symbol_type) catch unreachable);
        },
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
        .array, .tuple => return types.number_type, // approximation (no lib members)
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
        if (try c.lazyRefProp(obj, c.ts.literalAtom(idx), 0)) |p| {
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

/// `o[k]` where the KEY is a union of literals: tsc's `getIndexedAccessType`
/// distributes, so the access is `o[k1] | o[k2] | …`. Returns null — leaving
/// the caller's own single-key handling in charge — unless every constituent
/// resolves, so a key set that is partly unknown still reaches the caller's
/// implicit-any reporting instead of being silently narrowed here.
///
/// `miss` names the constituent that stopped a distribution, but only where
/// the answer is certain: a receiver whose member set ztsc models exactly
/// (an object, or a union/intersection of them) for an absent key, a tuple
/// for an out-of-range numeric key. Array/tuple *string* keys and every
/// non-literal constituent leave `.none` — their key sets involve lib
/// members ztsc approximates, and a wrong "cannot index" there would be a
/// false positive.
pub fn unionIndexElemType(c: *Checker, r: TypeId, idx_t: TypeId, miss: *UnionIndexMiss) Error!?TypeId {
    miss.* = .none;
    if (c.ts.kind(idx_t) != .union_type) return null;
    const rk = c.ts.kind(r);
    // A branded tuple indexes through its tuple constituent, as in the
    // single-number-literal arm.
    const rt = if (rk == .intersection)
        (try c.indexableConstituent(r)) orelse r
    else
        r;
    const keys = try c.memberList(idx_t);
    if (keys.len == 0 or keys.len > max_union_index_keys) return null;
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
                    if (rk == .object or rk == .union_type or rk == .intersection) miss.* = .absent_key;
                    return null;
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
                    return null;
                }
                const v = c.ts.numberValue(rl);
                const iv: u32 = if (v >= 0 and v == @floor(v) and v < 4096) @intFromFloat(v) else 4096;
                if (iv < c.ts.tupleLen(rt)) {
                    const e = c.ts.tupleElem(rt, iv);
                    parts[i] = if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
                } else if (try c.tupleElemTypeAt(rt, iv)) |et| {
                    parts[i] = et;
                } else {
                    miss.* = .{ .tuple_range = .{ .tuple = rt, .index = iv } };
                    return null;
                }
            },
            else => return null,
        }
    }
    return try c.ts.makeUnion(c.scratch(), parts);
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

/// The element type behind an "arrayish" position — a tuple's rest element
/// (`[...xs: T]`) or a rest parameter (`...args: T`).
///
/// A *tuple* T answers with its numeric index type (the union of its
/// element types), not `any`: `(...args: [A, B])` used to erase both
/// positions to `any`, which silently accepted every argument and every
/// destructured element. Named tuple rest params are the standard way a
/// higher-order helper forwards a call (`<T extends any[]>(fn: (...a: T) =>
/// void)` instantiated at `[string, number]`), so the erasure removed
/// argument checking from every such call site.
/// A *union* of arrayish types answers with the union of their element
/// types, the way tsc's `getIndexedAccessType(restType, number)`
/// distributes: `(...handlers: S[] | S[][])` accepts an `S` *or* an `S[]`
/// per position, and collapsing that to `any` left every argument — most
/// visibly a callback — contextually untyped, so its parameters fell to
/// implicit `any` (TS7006) at call sites the non-union form typed fine.
pub fn elemOfArrayish(c: *Checker, t: TypeId) Error!TypeId {
    const r = if (c.ts.kind(t) == .ref) try c.resolveStructural(t) else t;
    return switch (c.ts.kind(r)) {
        .array => c.ts.arrayElem(r),
        .tuple => try c.numberIndexType(r),
        .union_type => blk: {
            if (c.inst_cache_on) {
                if (c.arrayish_elem_cache.get(r)) |hit| break :blk hit;
            }
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            const u = u: {
                for (try c.memberList(r)) |m| {
                    const e = try c.elemOfArrayish(m);
                    // One non-arrayish constituent leaves the whole position
                    // untyped, exactly as the single-type path does.
                    if (c.ts.kind(e) == .any) break :u types.any_type;
                    try parts.append(c.scratch(), e);
                }
                break :u try c.ts.makeUnion(c.scratch(), parts.items);
            };
            if (c.inst_cache_on) try c.arrayish_elem_cache.put(c.cm(), r, u);
            break :blk u;
        },
        else => types.any_type,
    };
}

/// The fixed tuple a *trailing rest parameter* is typed by, if any.
/// `(...args: [a: A, b?: B])` has exactly the parameter list `(a: A, b?: B)`
/// — tsc expands such a signature before any arity or argument check
/// (`getExpandedParameters`). A generic (`...args: T`) or plain array
/// (`...args: A[]`) rest has no expansion and stays unbounded.
pub fn restTupleOf(c: *Checker, p: types.Param) Error!?TypeId {
    if (!p.rest()) return null;
    const r = try c.resolveStructural(p.ty);
    if (c.ts.kind(r) != .tuple) return null;
    // A *variadic* tuple whose spread is not last — rxjs's
    // `[...ObservableInputTuple<T>, SchedulerLike]` — has no positional
    // expansion: the elements after the spread sit at an arity nobody
    // knows yet. Leave those signatures unexpanded (unbounded rest, the
    // pre-existing behaviour) rather than mis-assigning position 1 to the
    // trailing element.
    const len = c.ts.tupleLen(r);
    for (0..len) |i| {
        if (c.ts.tupleElem(r, @intCast(i)).rest() and i != len - 1) return null;
    }
    return r;
}

/// The trailing rest parameter's expansion tuple for a whole signature.
pub fn sigRestTuple(c: *Checker, sig: TypeId) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    return c.restTupleOf(c.ts.fnParam(sig, count - 1));
}

/// The trailing rest parameter's type when it is a UNION OF TUPLES —
/// i18next's `TFunction`, whose one call signature is
/// `(...args: [key: K, options?: O] | [key: K, defaultValue: D,
/// options?: O])`.
///
/// Such a signature has no single expanded parameter list (`sigRestTuple`
/// answers null) and no per-position type either: position 1 above would
/// have to be `O | undefined | D`, which relates to neither a `(k, o?)`
/// nor a `(k, d, o?)` target. tsc treats the union as the parameter list
/// chosen as a WHOLE (`getNonArrayRestType`): the other side's parameters
/// — or, at a call, the argument list — are packed into one tuple and have
/// to satisfy exactly one ARM.
///
/// The SIGNATURE-RELATION half of that is what this drives
/// (`restTupleAtPosition`, `signatureAssignableModeInner`); its CALL half is
/// `sigNonArrayRest` below, which is the same rule one step more general.
pub fn sigRestUnion(c: *Checker, sig: TypeId) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    const p = c.ts.fnParam(sig, count - 1);
    if (!p.rest()) return null;
    switch (c.ts.kind(p.ty)) {
        .union_type, .ref => {},
        else => return null,
    }
    const r = try c.resolveStructural(p.ty);
    if (c.ts.kind(r) != .union_type) return null;
    // Cheap first pass over the borrowed member slice: bail on the first
    // non-tuple, and only pay the scratch dupe when a member is a `ref`
    // that has to be resolved (resolving interns, which dangles the slice).
    var needs_resolve = false;
    for (c.ts.members(r)) |m| {
        switch (c.ts.kind(m)) {
            .tuple => {},
            .ref => needs_resolve = true,
            else => return null,
        }
    }
    if (!needs_resolve) return r;
    for (try c.memberList(r)) |m| {
        if (c.ts.kind(try c.resolveStructural(m)) != .tuple) return null;
    }
    return r;
}

/// tsc's `getNonArrayRestType`: the trailing rest parameter's type when the
/// argument list has to satisfy it as a WHOLE rather than position by
/// position. tsc's test is "there is an effective rest type and it is not an
/// array type" — a union of tuples (i18next's `TFunction`), a union of arrays
/// (an emitter's `...handlers: Sub[] | Sub[][]`), a bare type parameter. A
/// FULLY FIXED tuple rest has no effective rest type at all (it expands
/// positionally), and a plain `T[]` rest is an array, so both keep the
/// per-position walk.
///
/// ztsc narrows that to a UNION, which is where the whole-list rule earns its
/// keep and where per-position typing provably cannot answer: position 1 of
/// `[k, o?] | [k, d, o?]` would have to union the options bag with the default
/// string, which relates to neither arm. Every other non-array rest stays on
/// the per-position path — a deterministic under-report of the same shape the
/// per-position check already handles.
pub fn sigNonArrayRest(c: *Checker, sig: TypeId) Error!?TypeId {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    const p = c.ts.fnParam(sig, count - 1);
    if (!p.rest()) return null;
    switch (c.ts.kind(p.ty)) {
        .union_type, .ref => {},
        else => return null,
    }
    const r = try c.resolveStructural(p.ty);
    return if (c.ts.kind(r) == .union_type) r else null;
}

/// Is `index` an OPTIONAL position of a rest parameter typed by a union of
/// tuples? It is as soon as ONE arm says so — either its element there is
/// marked `?` or the arm is too short to reach the index at all — because
/// a call may pick that arm and omit the argument. tsc reads the position
/// as `getIndexedAccessType(restType, index)`, which distributes over the
/// union and so carries each arm's own `| undefined` along; ztsc's
/// positional answer is the rest's whole element type (`elemOfArrayish`),
/// which loses it. Without the `undefined` a perfectly ordinary
/// `t(key, maybeOptions)` — the options bag typed `Opts | undefined` at
/// the call site — had nothing in the parameter to be assignable to.
pub fn restUnionOptionalAt(c: *Checker, u: TypeId, index: u32) Error!bool {
    for (try c.memberList(u)) |m| {
        const arm = try c.resolveStructural(m);
        const len = c.ts.tupleLen(arm);
        if (index < len) {
            if (c.ts.tupleElem(arm, index).optional()) return true;
        } else if (len == 0 or !c.ts.tupleElem(arm, len - 1).rest()) return true;
    }
    return false;
}

/// tsc's `getRestTypeAtPosition`: `sig`'s parameters from `pos` onward
/// packed into one tuple, so a whole parameter list can be related to a
/// rest parameter's type in one step. A signature whose own rest is a
/// union of tuples answers with that union at its rest position — tsc
/// builds `[...(A | B)]` there and `createNormalizedTupleType` distributes
/// the variadic union straight back to `A | B`.
pub fn restTupleAtPosition(c: *Checker, sig: TypeId, pos: u32) Error!TypeId {
    const pc = try c.effParamCount(sig);
    if (pos + 1 == pc) {
        if (try c.sigRestUnion(sig)) |u| return u;
    }
    const count = c.ts.fnParamCount(sig);
    // An UNBOUNDED rest (`...xs: T[]`, `...xs: T`) has no positional
    // expansion; it rides as the tuple's variadic element, exactly as tsc
    // pushes `restType` with `ElementFlags.Variadic`.
    const unbounded = count > 0 and c.ts.fnParam(sig, count - 1).rest() and
        (try c.sigRestTuple(sig)) == null and (try c.sigRestUnion(sig)) == null;
    const req = try c.requiredParams(sig);
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    var i = pos;
    while (i < pc) : (i += 1) {
        if (unbounded and i + 1 == count) {
            try elems.append(c.scratch(), .{
                .ty = c.ts.fnParam(sig, count - 1).ty,
                .flags = types.elem_flag_rest,
            });
            break;
        }
        const t = try c.paramTypeAt(sig, i) orelse break;
        try elems.append(c.scratch(), .{
            .ty = t,
            .flags = if (i < req) 0 else types.elem_flag_optional,
        });
    }
    return c.ts.makeTuple(elems.items);
}

/// Copy union members to scratch: slices into the type store dangle
/// as soon as a new type is interned (extra array may grow).
pub fn memberList(c: *Checker, t: TypeId) Error![]const TypeId {
    return c.scratch().dupe(TypeId, c.ts.members(t));
}

pub fn refArgsList(c: *Checker, t: TypeId) Error![]const TypeId {
    return c.scratch().dupe(TypeId, c.ts.refArgs(t));
}

pub fn makeUnion2(c: *Checker, a: TypeId, b: TypeId) Error!TypeId {
    return c.ts.makeUnion(c.scratch(), &.{ a, b });
}

/// tsc's `getUnionType([left, right], UnionReduction.Subtype)` — the union
/// reduction it applies to the `&&` / `||` / `??` result. Build the union,
/// then drop any member that is a subtype of another member, so
/// `Item[] | never[]` (and ztsc's `[] : any[]` fallback branch) collapses
/// into the concrete `Item[]` instead of leaving a two-array union that
/// later mis-reports `.map(...)` as not callable (TS2349).
pub fn logicalUnion(c: *Checker, a: TypeId, b: TypeId) Error!TypeId {
    const u = try c.ts.makeUnion(c.scratch(), &.{ a, b });
    return c.reduceSubtypes(u);
}

/// Remove union members that are subtypes of another member. Mutually
/// assignable members (e.g. `any[]` vs `Item[]`) collapse to exactly one —
/// the any-rooted one (`anyRooted`), which is tsc's winner and, unlike the
/// TypeId this used to compare, a property of the program rather than of the
/// order its roots were listed in.
///
/// tsc guard mirrored from `strictSubtypeRelation`: an
/// *empty anonymous object type* (`{}` — the `?? {}` / `|| {}` fallback)
/// never absorbs another member — `T | {}` must not collapse to `{}` —
/// while `{}` itself is still absorbed by a member it's assignable to
/// (e.g. `{ [k: string]: any } | {}` -> the indexed type, matching tsc).
///
/// A FRESH object literal never ABSORBS a sibling, and is only absorbed
/// itself when it survives an excess-property check against the absorber.
/// Both fall out of tsc reducing with `strictSubtypeRelation`, which
/// excess-checks a fresh source; the asymmetry is real and observable —
/// `cond ? declaredWide : { … }` keeps both members, `cond ? declaredWide :
/// declaredNarrow` collapses, and a literal that is a plain subtype of its
/// sibling (`f() || { width, height }` against `{ width, height, scale?:
/// number }`) still disappears into it. The literal has not been widened
/// yet, so letting it absorb would throw away a sibling's properties on the
/// strength of a shape that is still being formed.
///
/// An ANY-ROOTED twin outranks its concrete counterpart rather than racing it
/// for the lower TypeId — see `anyRooted` for why the latter was a root-order
/// bug, and for the shape the rank deliberately does not cover.
pub fn reduceSubtypes(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return t;
    const members = try c.memberList(t);
    // Guard cost: `||`/`??` unions are tiny; skip pathological ones
    // (leaving the union untouched is always sound — never a new FP).
    if (members.len < 2 or members.len > 32) return t;
    // The weak-type rule is not consulted while reducing — see
    // `Checker.weak_rule_off`.
    c.weak_rule_off += 1;
    defer c.weak_rule_off -= 1;
    var kept: std.ArrayList(TypeId) = .empty;
    defer kept.deinit(c.scratch());
    outer: for (members, 0..) |m, i| {
        const m_empty = c.isEmptyAnonObject(m);
        const m_fresh = c.ts.objectIsFresh(m);
        for (members, 0..) |o, j| {
            if (i == j) continue;
            if (c.ts.objectIsFresh(o)) continue; // a fresh literal never absorbs
            if (c.isEmptyAnonObject(o)) continue; // `{}` never absorbs
            if (m_fresh and try c.freshHasExcessProp(m, o)) continue;
            if (!try c.isAssignable(m, o)) continue; // m not a subtype of o
            if (!m_empty and try c.isAssignable(o, m)) {
                // Mutually assignable: exactly one twin survives. A fresh
                // literal always yields — it can never absorb, so keeping
                // it here would keep both.
                if (m_fresh) continue :outer;
                // tsc's subtype relation is ASYMMETRIC exactly where the
                // assignability relation is not (`anyRooted`): an any-rooted
                // twin is not a subtype of the concrete one, so it is the one
                // that survives. Consulted before the reached-first fallback
                // because that fallback reads a TypeId, which is not a
                // property of the program.
                const m_any = try anyRooted(c, m, 0);
                const o_any = try anyRooted(c, o, 0);
                if (m_any != o_any) {
                    // `m` is the any-carrying twin: `o` cannot absorb it.
                    if (m_any) continue;
                    // `m` is the concrete twin: it IS the subtype, so it goes
                    // whether or not `o` has been kept yet.
                    continue :outer;
                }
                for (kept.items) |k| if (k == o) continue :outer;
            } else {
                // Strict subtype (or the `{}` member itself): m is redundant.
                continue :outer;
            }
        }
        try kept.append(c.scratch(), m);
    }
    if (kept.items.len == members.len) return t;
    return c.ts.makeUnion(c.scratch(), kept.items);
}

/// Is `t` ANY-ROOTED — `any` itself, or an array/tuple whose every element is
/// any-rooted? The tie-break `reduceSubtypes` needs for a mutually assignable
/// pair, and the one place tsc's SUBTYPE relation is asymmetric where ztsc's
/// assignability relation is not.
///
/// tsc reduces a `||`/`??`/`?:` union with `strictSubtypeRelation`, in which
/// `T` is a subtype of `any` but `any` is a subtype of nothing except `any`
/// and `unknown`. So `string[] | any[]` is not a symmetric pair for tsc at
/// all: the concrete arm is the subtype, it is the arm that goes, and the
/// result is `any[]` (measured against tsgo 7.0.2, which types `c ? xs : ys`
/// as `any[]` for `xs: string[]`, `ys: any[]`).
///
/// ztsc's assignability relation cannot see that — `any` relates in both
/// directions — so the two arms came back MUTUALLY assignable and the
/// reduction fell through to "keep whichever of the two was reached first",
/// i.e. the lower TypeId. That is the bug: TypeIds are handed out in demand
/// order, demand order follows file ids, and file ids follow the ROOT FILE
/// ORDER, so the surviving arm — and the type of every expression derived from
/// it — moved when the `include` walk was permuted, which `src/checker.zig:15`
/// promises cannot happen.
///
/// It was excalidraw's last order-dependent result. `App.tsx`'s
///
///     const elementsWithinSelection = this.state.selectionElement
///       ? getElementsWithinSelection(…)
///       : [];
///
/// is `NonDeletedExcalidrawElement[] | any[]` here, because ztsc types a bare
/// `[]` as `any[]` (evolving arrays are out of subset — see
/// `checkArrayLiteral`) where tsc types it `never[]`. Under
/// `--file-order=source` the `any[]` arm happened to hold the lower id and
/// won; under `reverse` the concrete arm did, so the `.reduce` twelve lines
/// below ran on a typed array instead of on `any` and reported two TS7053s
/// that no other order reported.
///
/// ANY-ROOTED, not "contains an `any` anywhere", and the restriction is load
/// bearing rather than a cost guard. Keeping the any-carrying twin is
/// information-preserving exactly when the `any` swallows the whole compared
/// value: nothing can be read off it, so nothing can be reported through it,
/// and the worst case is the under-report ztsc already accepts for `[]`. When
/// the twin is an OBJECT whose `any` sits inside one property, keeping it
/// throws the other twin's properties away — and that invents diagnostics.
/// Measured: social-app's `loggedOutFetch` returns
/// `{success: boolean; data: OutputSchema}` in one arm and
/// `{success: boolean; data: {feed: any[]}}` in the other (that `any[]` is
/// again a bare `[]`), the two are mutually assignable, and preferring the
/// any-carrying arm dropped `OutputSchema`'s `cursor` — one fresh TS2339 on an
/// app that is otherwise 0. tsc keeps the concrete arm there because its
/// `{feed: never[]}` IS a strict subtype; ztsc's `any` placeholder points the
/// opposite way, so the rank is not consulted for that shape and the
/// reached-first fallback stands. That leaves object twins minted in different
/// FILES a residual order hazard; none is reachable on the gated corpus, and
/// closing it properly means a real subtype relation, not a better tie-break.
fn anyRooted(c: *Checker, t: TypeId, depth: u32) Error!bool {
    const s = &c.ts;
    if (s.kind(t) == .any) return true;
    if (depth > 2) return false;
    switch (s.kind(t)) {
        .array => return anyRooted(c, s.arrayElem(t), depth + 1),
        .tuple => {
            const n = s.tupleLen(t);
            if (n == 0) return false;
            for (0..n) |i| {
                if (!try anyRooted(c, s.tupleElem(t, @intCast(i)).ty, depth + 1)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// tsc's `hasExcessProperties`, asked of two *types* rather than of a
/// literal's syntax: does the fresh object literal `m` declare a property
/// `o` does not know? A target with an index signature, or the empty object
/// type, knows every property and never reports one.
pub fn freshHasExcessProp(c: *Checker, m: TypeId, o0: TypeId) Error!bool {
    const s = &c.ts;
    if (s.kind(m) != .object) return false;
    const o = try c.resolveStructural(o0);
    if (s.kind(o) != .object) return false;
    if (s.objectStringIndex(o) != 0 or s.objectNumberIndex(o) != 0) return false;
    if (c.isEmptyObjectType(o)) return false;
    for (0..s.objectPropCount(m)) |i| {
        if (s.objectPropByName(o, s.objectProp(m, @intCast(i)).name) == null) return true;
    }
    return false;
}

/// tsc's `isEmptyAnonymousObjectType`: a structural object type with no
/// properties, no call/construct signatures, and no index signatures.
/// Named refs are not resolved — only literal `{}` shapes qualify (the
/// `|| {}` / `?? {}` fallback), matching tsc's Anonymous-flag check.
pub fn isEmptyAnonObject(c: *Checker, t: TypeId) bool {
    const s = &c.ts;
    if (s.kind(t) != .object) return false;
    return s.objectPropCount(t) == 0 and
        s.objectStringIndex(t) == 0 and s.objectNumberIndex(t) == 0 and
        s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0;
}

/// `string | number | symbol` — the apparent constraint of a deferred
/// `keyof T` and TS's `PropertyKey`.
pub fn propertyKeyType(c: *Checker) Error!TypeId {
    return c.ts.makeUnion(c.scratch(), &.{ types.string_type, types.number_type, types.symbol_type });
}

/// Fold one heritage base into a derived interface/class shape.
///
/// Everything except an `any` base is `instantiate.mergeBaseObject` verbatim.
/// An `any` base is the case that one silently dropped (its object-only guard
/// handed `derived` straight back), and it is not a no-op in tsc:
/// `interface DefaultState extends DefaultStateExtends {}` over
/// `type DefaultStateExtends = any` — `@types/koa`'s user-augmentable request
/// state — is an interface that accepts EVERY property read. tsc's
/// `resolveObjectTypeMembers` substitutes `anyBaseTypeIndexInfo`
/// (`[x: string]: any`) for an `any` base's index infos, and — when the
/// interface declares nothing of its own — `getNormalizedType` additionally
/// relates the whole shape as `any`. See `types.obj_flag_any_base` for the
/// oracle-verified surface of both halves.
///
/// A base that is `any` because it FAILED to resolve is a different animal:
/// `error_type`, not `.any`, so it still contributes nothing.
pub fn mergeBaseObject(c: *Checker, derived: TypeId, base: TypeId, union_overloads: bool) Error!TypeId {
    const s = &c.ts;
    if (s.kind(base) == .any and s.kind(derived) == .object) return anyBaseShape(c, derived);
    const merged = try mergeBaseObjectPlain(c, derived, base, union_overloads);
    if (s.kind(base) != .object or s.kind(merged) != .object) return merged;
    // A SECOND base decides whether "relates as `any`" survives the fold, and
    // `mergeBaseObjectPlain` carries `derived`'s flags through unexamined.
    // tsc's condition is `getBaseTypes(target).length === 1`, so:
    //   `interface R extends Any, B {}` — `Any` was folded first and flagged
    //   the accumulator; `B` is a real object base, so R has two bases and must
    //   NOT relate as `any` (it is missing B's members from tsc's answer too).
    //   `interface T extends P {}` where P relates as `any` — T has the single
    //   base P, declares nothing, and tsc normalizes T -> P -> `any` (the
    //   `getNormalizedType` loop), so the flag has to reach T as well.
    if (s.objectRelatesAsAny(base)) {
        if (!s.objectRelatesAsAny(merged) and bareInterfaceShape(s, derived) and !anyBaseOwnerIsGeneric(c)) {
            return withAnyBaseFlag(c, merged, true);
        }
        return merged;
    }
    if (s.objectRelatesAsAny(merged)) return withAnyBaseFlag(c, merged, false);
    return merged;
}

/// `derived` with an `any` base folded in: a `[x: string]: any` index signature
/// (unless it declares an index of its own — a declared signature wins over an
/// inherited one, tsc's `findIndexInfo` filter), plus `obj_flag_any_base` when
/// the interface declares nothing at all, which is the extra condition tsc's
/// `getSingleBaseForNonAugmentingSubtype` puts on relating as `any`.
fn anyBaseShape(c: *Checker, derived: TypeId) Error!TypeId {
    const s = &c.ts;
    // `[k: symbol]: V` parks its value type in the string slot
    // (`obj_flag_symbol_index`), so an interface declaring one has no string
    // index for tsc's purposes and should still inherit `any`. ztsc has only
    // the one slot to put it in, so leave that shape exactly as it was rather
    // than lose the symbol keying.
    if (s.objectFlags(derived) & types.obj_flag_symbol_index != 0) return derived;
    const own_sidx = s.objectStringIndex(derived);
    const relates_as_any = bareInterfaceShape(s, derived) and !anyBaseOwnerIsGeneric(c);
    const sidx = if (own_sidx != 0) own_sidx else types.any_type;
    var flags = s.objectFlags(derived);
    if (relates_as_any) flags |= types.obj_flag_any_base;
    if (sidx == own_sidx and flags == s.objectFlags(derived)) return derived;
    return rebuildObject(c, derived, sidx, flags);
}

/// Does the interface declare NOTHING of its own — the `getMembersOfSymbol(
/// type.symbol).size === 0` half of tsc's non-augmenting-subtype test, read off
/// the shape that ztsc has already built from those members?
fn bareInterfaceShape(s: *const types.Store, derived: TypeId) bool {
    return s.objectPropCount(derived) == 0 and !s.objectHasSigs(derived) and
        s.objectStringIndex(derived) == 0 and s.objectNumberIndex(derived) == 0;
}

/// Is the interface whose bases are being folded GENERIC? tsc bails out of
/// `getSingleBaseForNonAugmentingSubtype` on `getMembersOfSymbol(type.symbol)
/// .size`, and TypeScript's binder declares an interface's TYPE PARAMETERS in
/// that very member table — so a generic interface never relates as its single
/// base, however empty its body. Verified by instrumenting tsc: `interface
/// G<X> extends A {}` logs `own-members=1` and stays unassignable to an
/// unrelated class, while `interface G3 extends A {}` logs `OK … -> any`.
///
/// Only `interfaceConstituentApplyBases` marks its frame `resolving_base`, so
/// this reads the interface whose Phase-2 fold we are inside. Any other caller
/// (a class's `interface` half) answers "generic" and settles for the index
/// signature alone rather than trust an unrelated stack top.
fn anyBaseOwnerIsGeneric(c: *Checker) bool {
    if (c.iface_stack.items.len == 0) return true;
    const frame = c.iface_stack.items[c.iface_stack.items.len - 1];
    if (!frame.resolving_base) return true;
    return symDeclaresTypeParams(c, frame.sym);
}

/// Does any `interface` declaration of `sym` (or of a cross-file merge's
/// constituents) carry a type-parameter list? Read straight off the AST — no
/// scope walk, no type conversion — in each declaration's OWN file context,
/// because a merged symbol's declarations are spread across trees.
fn symDeclaresTypeParams(c: *Checker, sym: SymbolId) bool {
    if (c.prog.isMergedId(sym)) {
        for (c.prog.mergedSym(sym).parts) |p| {
            if (symDeclaresTypeParams(c, p)) return true;
        }
        return false;
    }
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
        if (data.tp_start != data.tp_end) return true;
    }
    return false;
}

/// `merged` with `obj_flag_any_base` set or cleared, everything else identical.
fn withAnyBaseFlag(c: *Checker, merged: TypeId, on: bool) Error!TypeId {
    const s = &c.ts;
    const flags = if (on)
        s.objectFlags(merged) | types.obj_flag_any_base
    else
        s.objectFlags(merged) & ~types.obj_flag_any_base;
    if (flags == s.objectFlags(merged)) return merged;
    return rebuildObject(c, merged, s.objectStringIndex(merged), flags);
}

/// Re-intern an object with a new string index and/or flags, carrying its
/// properties, signatures, number index and enum key names across unchanged.
fn rebuildObject(c: *Checker, from: TypeId, sidx: TypeId, flags: u32) Error!TypeId {
    const s = &c.ts;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    for (0..s.objectPropCount(from)) |i| {
        try props.append(c.scratch(), s.objectProp(from, @intCast(i)));
    }
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var constructs: std.ArrayList(TypeId) = .empty;
    defer constructs.deinit(c.scratch());
    for (0..s.objectCallSigCount(from)) |i| try calls.append(c.scratch(), s.objectCallSig(from, @intCast(i)));
    for (0..s.objectConstructSigCount(from)) |i| try constructs.append(c.scratch(), s.objectConstructSig(from, @intCast(i)));
    const m = try s.makeObjectSigs(
        props.items,
        sidx,
        s.objectNumberIndex(from),
        flags & ~types.obj_flag_has_sigs,
        calls.items,
        constructs.items,
    );
    try c.carryKeyNameTypes(m, &.{from});
    return m;
}

/// Object type from interface/object-literal-type member nodes.
pub fn objectTypeFromMembers(c: *Checker, member_nodes: []const Node, obj_flags: u32) Error!TypeId {
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer prop_index.deinit(c.scratch());
    var sindex: TypeId = 0;
    var nindex: TypeId = 0;
    var sym_index = false;
    var str_index = false;
    // Method overload grouping: name -> sig list.
    var methods: std.AutoHashMapUnmanaged(Atom, std.ArrayList(TypeId)) = .empty;
    defer {
        var it = methods.valueIterator();
        while (it.next()) |l| l.deinit(c.scratch());
        methods.deinit(c.scratch());
    }
    var order: std.ArrayList(Atom) = .empty;
    defer order.deinit(c.scratch());
    // Members whose declaration name is not the plain string literal of their
    // atom — a computed ENUM-MEMBER key, or a NUMERIC name (`{ 200: T }`) —
    // as (atom, name type); tsc's `symbol.links.nameType`. Recorded against
    // the interned object below so `keyof` can report `E.A` where the table is
    // keyed `"AV1"`, and `200` where it is keyed `"200"`. See
    // `Checker.memberNameType` and `Checker.key_name_types`; empty for every
    // type with no such member.
    var name_types: std.ArrayList(struct { name: Atom, ty: TypeId }) = .empty;
    defer name_types.deinit(c.scratch());
    // Method names declared optional (`m?(): T`) — tsc marks the resulting
    // property optional (e.g. `PropertyDescriptor.get?`/`set?`).
    var optional_methods: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer optional_methods.deinit(c.scratch());
    // Call / construct signature lists, kept in declaration order.
    var call_sigs: std.ArrayList(TypeId) = .empty;
    defer call_sigs.deinit(c.scratch());
    var construct_sigs: std.ArrayList(TypeId) = .empty;
    defer construct_sigs.deinit(c.scratch());
    // Accessor keys, to type a get/set pair as one property and mark a
    // get-only accessor read-only.
    var getter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer getter_keys.deinit(c.scratch());
    var setter_keys: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer setter_keys.deinit(c.scratch());

    for (member_nodes) |m| {
        if (m == null_node) continue;
        const md = c.tree.nodeData(m);
        switch (c.nodeTag(m)) {
            .property_signature => {
                const name = try c.memberKey(c.tree.nodeMainToken(m), md.rhs);
                const nt = try c.memberNameType(c.tree.nodeMainToken(m), md.rhs);
                if (nt != types.no_type) try name_types.append(c.scratch(), .{ .name = name, .ty = nt });
                var flags: u32 = 0;
                if (md.rhs & ast.Flags.optional != 0) flags |= types.prop_flag_optional;
                if (md.rhs & ast.Flags.readonly != 0) flags |= types.prop_flag_readonly;
                const ty = if (md.lhs != 0)
                    try c.annTypeMaybeUnique(md.lhs, md.rhs & ast.Flags.readonly != 0, 1330, c.tokSpan(c.tree.nodeMainToken(m)))
                else
                    types.any_type;
                try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = ty, .flags = flags });
            },
            .method_signature => {
                const name = try c.memberKey(c.tree.nodeMainToken(m), md.rhs);
                {
                    // A numeric / enum-member METHOD name is named the same
                    // way a property name is (`{ 200(): void }`).
                    const nt = try c.memberNameType(c.tree.nodeMainToken(m), md.rhs);
                    if (nt != types.no_type) try name_types.append(c.scratch(), .{ .name = name, .ty = nt });
                }
                // `get x(): T` / `set x(v: T)` accessor signatures: the
                // property type is the getter return (or setter param).
                const is_get = md.rhs & ast.Flags.get != 0;
                const is_set = md.rhs & ast.Flags.set != 0;
                if (is_get or is_set) {
                    const sig = try c.signatureOfProto(m, md.lhs, true, false);
                    if (is_get) {
                        try getter_keys.put(c.scratch(), name, {});
                        const gt = if (c.ts.kind(sig) == .function) c.ts.fnReturn(sig) else types.any_type;
                        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = gt, .flags = 0 });
                    } else {
                        try setter_keys.put(c.scratch(), name, {});
                        if (!getter_keys.contains(name)) {
                            const st = if (c.ts.kind(sig) == .function and c.ts.fnParamCount(sig) > 0)
                                c.ts.fnParam(sig, 0).ty
                            else
                                types.any_type;
                            try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = st, .flags = 0 });
                        }
                    }
                    continue;
                }
                const sig = try c.signatureOfProto(m, md.lhs, true, true);
                if (md.rhs & ast.Flags.optional != 0) try optional_methods.put(c.scratch(), name, {});
                const gop = try methods.getOrPut(c.scratch(), name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                    try order.append(c.scratch(), name);
                }
                try gop.value_ptr.append(c.scratch(), sig);
            },
            .index_signature => {
                const e = c.tree.extraData(ast.IndexSig, md.lhs);
                const key = try c.typeFromTypeNode(e.key_type);
                const val = try c.typeFromTypeNode(e.value_type);
                if (key == types.number_type) {
                    nindex = val;
                } else {
                    // A `symbol`-keyed signature shares the string slot, so
                    // everything that reads an index signature is unchanged;
                    // the flag is only there for `keyof`. A string signature
                    // written alongside one takes the slot back and clears it
                    // — see `obj_flag_symbol_index`.
                    if (key == types.symbol_type) sym_index = true else str_index = true;
                    sindex = val;
                }
            },
            // Call / construct signatures. Compared like function
            // types (not methods), so params are contravariant.
            .call_signature => {
                try call_sigs.append(c.scratch(), try c.signatureOfProto(m, md.lhs, false, true));
            },
            .construct_signature => {
                try construct_sigs.append(c.scratch(), try c.signatureOfProto(m, md.lhs, false, true));
            },
            else => {},
        }
    }
    for (order.items) |name| {
        const sigs = methods.get(name).?;
        const ty = try c.ts.makeOverloads(sigs.items);
        const mflags: u32 = if (optional_methods.contains(name)) types.prop_flag_optional else 0;
        try upsertProp(c.scratch(), &props, &prop_index, .{ .name = name, .ty = ty, .flags = mflags });
    }
    // Get-only accessors are read-only properties.
    var git = getter_keys.keyIterator();
    while (git.next()) |k| {
        if (setter_keys.contains(k.*)) continue;
        if (prop_index.get(k.*)) |idx| props.items[idx].flags |= types.prop_flag_readonly;
    }
    const flags = if (sym_index and !str_index and nindex == 0)
        obj_flags | types.obj_flag_symbol_index
    else
        obj_flags;
    const obj = try c.ts.makeObjectSigs(props.items, sindex, nindex, flags, call_sigs.items, construct_sigs.items);
    for (name_types.items) |nt| {
        try c.putKeyNameType(obj, nt.name, nt.ty);
    }
    return obj;
}

/// Append `p`, replacing any existing prop with the same name. `index`
/// maps name atom -> slot in `props` so accumulation is O(1) amortized
/// instead of a linear rescan per insert (O(P^2) for large interfaces).
pub fn upsertProp(
    alloc: Allocator,
    props: *std.ArrayList(types.Prop),
    index: *std.AutoHashMapUnmanaged(Atom, u32),
    p: types.Prop,
) Error!void {
    const gop = try index.getOrPut(alloc, p.name);
    if (gop.found_existing) {
        props.items[gop.value_ptr.*] = p;
        return;
    }
    gop.value_ptr.* = @intCast(props.items.len);
    try props.append(alloc, p);
}

pub fn propByName(props: []const types.Prop, name: Atom) ?types.Prop {
    for (props) |p| {
        if (p.name == name) return p;
    }
    return null;
}

/// Fold the properties of a spread source (`{ ...src }`) into an object
/// literal's property set. An intersection source contributes the props of
/// every constituent (a later constituent wins on a name clash, mirroring
/// tsc's spread over `A & B`); without this, spreading a value of an
/// intersection type produced an empty `{}` (the object-only guard skipped
/// it), which then failed assignment to the very type it was spread from.
pub fn gatherSpreadProps(
    c: *Checker,
    st: TypeId,
    props: *std.ArrayList(types.Prop),
    prop_index: *std.AutoHashMapUnmanaged(Atom, u32),
    str_index_vals: *std.ArrayList(TypeId),
    num_index_vals: *std.ArrayList(TypeId),
) Error!void {
    switch (c.ts.kind(st)) {
        .object => {
            // tsc's `getSpreadType` carries the source's index signatures
            // into the result, so `{ ...src }` of `{ [k: string]: any }`
            // keeps the string index (`updated.arr` stays `any`, not a
            // missing-property TS2551/2339).
            if (c.ts.objectStringIndex(st) != 0) try str_index_vals.append(c.scratch(), c.ts.objectStringIndex(st));
            if (c.ts.objectNumberIndex(st) != 0) try num_index_vals.append(c.scratch(), c.ts.objectNumberIndex(st));
            for (0..c.ts.objectPropCount(st)) |i| {
                const p = c.ts.objectProp(st, @intCast(i));
                // tsc's `getSpreadType`: when a property is present in both
                // the accumulated left (`{ a, b, ... }`) and this spread and
                // the spread's property is OPTIONAL, the result keeps the
                // LEFT's optionality and unions the value types. So an
                // explicit required prop stays required even when a later
                // `Partial<…>` spread re-supplies it optionally — without
                // this, every prop of `{ id, active, ...overrides }` (with
                // `overrides: Partial<X>`) became optional and failed
                // assignment to the required target (TS2322 factory FPs).
                try c.addSpreadProp(p, props, prop_index);
            }
        },
        .intersection => {
            // tsc spreads the *apparent* members of the intersection, and a
            // name declared by more than one constituent has the
            // INTERSECTION of its declared types (`getPropertyOfUnionOr
            // IntersectionType` synthesizes one symbol per name). Recursing
            // per constituent and letting the last one win instead threw the
            // narrower declaration away: `{ height?: number } & { height?:
            // string | number }` spread to `height?: string | number`, which
            // then failed assignment back to the very type it came from.
            // The constituents are still walked first — for their index
            // signatures, and to collect the name set in declaration order.
            var names: std.ArrayList(types.Prop) = .empty;
            defer names.deinit(c.scratch());
            var nindex: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
            defer nindex.deinit(c.scratch());
            for (try c.memberList(st)) |m| {
                try c.gatherSpreadProps(try c.resolveStructural(m), &names, &nindex, str_index_vals, num_index_vals);
            }
            for (names.items) |p| {
                const merged = (try c.propOfTypeEx(st, p.name, false)) orelse p;
                try c.addSpreadProp(merged, props, prop_index);
            }
        },
        .union_type => {
            // tsc's `getSpreadType` distributes over a union and yields a
            // UNION of spread results. ztsc's object literal is one object,
            // so the constituents are FOLDED instead: a property every
            // member declares keeps the union of its types; one that some
            // member lacks (or declares optional) becomes optional. That
            // drops the correlation between properties, but the arm did not
            // exist at all, so a union spread source contributed NOTHING —
            // `{ ...(tool || { type: "selection" }), extra }` lost `type`
            // entirely and failed every target that requires it.
            //
            // A member is folded through the SAME gather this function
            // performs for a non-union source, so an INTERSECTION member
            // contributes the merged properties of its constituents. That
            // matters for every discriminated union whose members are
            // `Base & { … }`: taking only `.object` members made
            // `{ ...element, … }` over such a union contribute nothing at
            // all, because each member resolves to an intersection.
            // `null`/`undefined`/`void` members spread nothing (tsc), and
            // anything else leaves the whole spread unmodelled as before.
            const members = try c.memberList(st);
            var objs: std.ArrayList([]const types.Prop) = .empty;
            defer objs.deinit(c.scratch());
            // A `null`/`undefined`/`void` member spreads the EMPTY object
            // (tsc), i.e. one alternative supplies no property at all — so
            // every folded property is optional when the union has one.
            var has_empty = false;
            // Index signatures ARE carried out of the fold. tsc strips the
            // nullish (and empty-object) members first — `tryMergeUnionOf
            // ObjectTypeAndEmptyObject` — and when exactly ONE carrier is
            // left it spreads that carrier through `getAnonymousPartial
            // Type`, which keeps its index infos verbatim. So `{ ...attrs }`
            // over `{ [x: string]: JSONValue } | undefined` keeps the string
            // index instead of collapsing to `{}` (every `attrs.href` read
            // was a bogus TS2339).
            //
            // With two or more carriers tsc DISTRIBUTES instead and each arm
            // keeps only its own index infos. The fold is one object and
            // cannot say that, so it carries an index kind only when EVERY
            // carrier declares one, and unions their value types: a carrier
            // without an index would, distributed, reject exactly the
            // accesses the index permits, so carrying it anyway would
            // silence real errors.
            var idx_carriers: usize = 0;
            var all_str = true;
            var all_num = true;
            var idx_str: std.ArrayList(TypeId) = .empty;
            defer idx_str.deinit(c.scratch());
            var idx_num: std.ArrayList(TypeId) = .empty;
            defer idx_num.deinit(c.scratch());
            for (members) |m| {
                const rm = try c.resolveStructural(m);
                switch (c.ts.kind(rm)) {
                    .object, .intersection => {
                        var mprops: std.ArrayList(types.Prop) = .empty;
                        var mindex: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
                        defer mindex.deinit(c.scratch());
                        var ms: std.ArrayList(TypeId) = .empty;
                        defer ms.deinit(c.scratch());
                        var mn: std.ArrayList(TypeId) = .empty;
                        defer mn.deinit(c.scratch());
                        try c.gatherSpreadProps(rm, &mprops, &mindex, &ms, &mn);
                        try objs.append(c.scratch(), mprops.items);
                        // An EMPTY object member (`{}`) is one of the members
                        // tsc strips, so it neither votes on nor supplies an
                        // index — it only makes the folded properties
                        // optional, which an empty property list already
                        // does.
                        if (mprops.items.len == 0 and ms.items.len == 0 and mn.items.len == 0) continue;
                        idx_carriers += 1;
                        if (ms.items.len == 0) all_str = false;
                        if (mn.items.len == 0) all_num = false;
                        try idx_str.appendSlice(c.scratch(), ms.items);
                        try idx_num.appendSlice(c.scratch(), mn.items);
                    },
                    .null, .undefined, .void => has_empty = true,
                    else => return,
                }
            }
            if (idx_carriers > 0) {
                if (all_str) try str_index_vals.appendSlice(c.scratch(), idx_str.items);
                if (all_num) try num_index_vals.appendSlice(c.scratch(), idx_num.items);
            }
            if (objs.items.len == 0) return;
            var names: std.ArrayList(Atom) = .empty;
            defer names.deinit(c.scratch());
            var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
            defer seen.deinit(c.scratch());
            for (objs.items) |o| {
                for (o) |p| {
                    const g = try seen.getOrPut(c.scratch(), p.name);
                    if (!g.found_existing) try names.append(c.scratch(), p.name);
                }
            }
            for (names.items) |nm| {
                var parts: std.ArrayList(TypeId) = .empty;
                defer parts.deinit(c.scratch());
                var optional = has_empty;
                var readonly = false;
                for (objs.items) |o| {
                    if (propByName(o, nm)) |p| {
                        try parts.append(c.scratch(), try c.removeUndefined(p.ty));
                        if (p.flags & types.prop_flag_optional != 0) optional = true;
                        if (p.flags & types.prop_flag_readonly != 0) readonly = true;
                    } else optional = true;
                }
                var flags: u8 = 0;
                if (optional) flags |= types.prop_flag_optional;
                if (readonly) flags |= types.prop_flag_readonly;
                try c.addSpreadProp(.{
                    .name = nm,
                    .ty = try c.ts.makeUnion(c.scratch(), parts.items),
                    .flags = flags,
                }, props, prop_index);
            }
        },
        else => {},
    }
}

/// Fold one spread source property into the accumulated literal. tsc's
/// `getSpreadType`: when the property is already present on the left
/// (`{ a, b, ...rest }`) and the spread declares it OPTIONAL, the left
/// keeps its optionality and the value types union — so an explicit
/// required property stays required even when a later `Partial<…>` spread
/// re-supplies it.
pub fn addSpreadProp(
    c: *Checker,
    p: types.Prop,
    props: *std.ArrayList(types.Prop),
    prop_index: *std.AutoHashMapUnmanaged(Atom, u32),
) Error!void {
    if (p.flags & types.prop_flag_optional != 0) {
        if (prop_index.get(p.name)) |idx| {
            props.items[idx].ty = try c.logicalUnion(props.items[idx].ty, try c.removeUndefined(p.ty));
            return;
        }
    }
    try upsertProp(c.scratch(), props, prop_index, .{ .name = p.name, .ty = p.ty, .flags = p.flags & types.prop_flag_optional });
}
