//! Type-node conversion: AST type annotations -> TypeIds.
//!
//! `typeFromTypeNode` is the entry point and the switch over every type-node
//! kind; what is left here beside it is what that switch needs and nothing
//! else has a better home for: the rest-parameter helpers (a rest position's
//! element type, a signature's expansion tuple), the union algebra
//! (`makeUnion2`, `logicalUnion`, `reduceSubtypes`) and object construction
//! from written members (`objectTypeFromMembers`, the spread/prop helpers).
//!
//! `memberList` and `makeUnion2` live here too, and are the most widely
//! imported primitives in the checker — `memberList` because a member slice
//! borrowed from the type store dangles the moment anything interns.
//!
//! The three clusters that used to share this file are now their own:
//! typespace.zig (name / module / namespace resolution), typeparams.zig
//! (type-parameter lists, instantiation maps, TS2344) and keyof.zig (`keyof`
//! and indexed access). Their public surface is re-exported below, so
//! `checker.zig`'s method aliases and other modules' direct imports keep
//! resolving through this file.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TokenIndex = ast.TokenIndex;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const annTypeMaybeUnique = Checker.annTypeMaybeUnique;
const computed_key = @import("computed_key.zig");
const implicit_any = @import("implicit_any.zig");
const inferVarFromNode = @import("generics.zig").inferVarFromNode;
const mergeBaseObjectPlain = @import("classes.zig").mergeBaseObjectPlain;
const scratch = Checker.scratch;
const signatureOfProto = @import("signatures.zig").signatureOfProto;

const keyof_zig = @import("keyof.zig");
const tuple_relate = @import("tuple_relate.zig");
const typeparams_zig = @import("typeparams.zig");
const typespace_zig = @import("typespace.zig");

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
pub const importEqualsEntityContainer = typespace_zig.importEqualsEntityContainer;
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
pub const checkFileTypeParamDefaults = typeparams_zig.checkFileTypeParamDefaults;
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

/// `keyof` and indexed access (keyof.zig).
const checkIndexedAccessIndexType = keyof_zig.checkIndexedAccessIndexType;
pub const indexableConstituent = keyof_zig.indexableConstituent;
pub const indexedAccessType = keyof_zig.indexedAccessType;
pub const intersectKeySets = keyof_zig.intersectKeySets;
pub const isKeyAtom = keyof_zig.isKeyAtom;
pub const isKeyLiteral = keyof_zig.isKeyLiteral;
pub const keySetAllLiterals = keyof_zig.keySetAllLiterals;
pub const keySetEnumerable = keyof_zig.keySetEnumerable;
pub const keySetHas = keyof_zig.keySetHas;
pub const keySetMembers = keyof_zig.keySetMembers;
pub const keyofMapped = keyof_zig.keyofMapped;
pub const keyofType = keyof_zig.keyofType;
pub const max_union_index_keys = keyof_zig.max_union_index_keys;
pub const numberIndexType = keyof_zig.numberIndexType;
pub const typeIsNumberLike = keyof_zig.typeIsNumberLike;
pub const unionIndexElemType = keyof_zig.unionIndexElemType;

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
    const result = try typeFromTypeNodeUncached(c, node);
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

fn typeFromTypeNodeUncached(c: *Checker, node: Node) Error!TypeId {
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
            // Negative literal type `-1` / `-1n`. The parser wraps BOTH in a
            // `.number_literal` node (its type-position `.minus` arm takes
            // either token and leafs one tag), so the operand is told apart by
            // its TOKEN, not by its node tag — read as a number, `-1n`'s `1n`
            // parsed as `0` and the type came out `0`.
            if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .minus and d.lhs != 0) {
                const lit = c.tree.nodeMainToken(d.lhs);
                switch (c.tree.tokens.tag(lit)) {
                    .numeric_literal => {
                        var v = -c.numberTokenValue(lit);
                        // `-0` is `0`: tsc's literal-type map is keyed by value
                        // with SameValueZero, so the two are one type.
                        if (v == 0) v = 0;
                        return c.ts.makeNumberLiteral(v, false);
                    },
                    .bigint_literal => return negatedBigIntLiteral(c, lit, false),
                    else => {},
                }
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
        .object_type => {
            // A type literal has no declaration walk of its own, so its
            // members' computed NAMES are checked here — the one place every
            // written `{ … }` passes through. `typeFromTypeNode` memoizes by
            // `(file, node)` and reports against the file the node lives in, so
            // this is once per literal wherever the materialization starts.
            // (wave-10 A: one flagged call into `computed_key.zig`.)
            try computed_key.checkMemberNames(c, c.tree.nodeRange(node), .type_space);
            return c.objectTypeFromMembers(c.tree.nodeRange(node), 0);
        },
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
            // tsc's `checkTypeOperator`: the modifier is only permitted on an
            // array or tuple *literal* type, syntactically — `readonly
            // Array<string>` and `readonly readonly string[]` are both TS1354,
            // whatever their operand resolves to.
            if (c.nodeTag(d.lhs) != .array_type and c.nodeTag(d.lhs) != .tuple_type) {
                try c.diagFmt(1354, c.nodeSpan(node), "'readonly' type modifier is only permitted on array and tuple literal types.", .{});
            }
            const inner = try c.typeFromTypeNode(d.lhs);
            // `readonly T[]` carries Array's members and relates as `T[]` does
            // except for the readonly screen (`isReadonlyArrayOrTuple`); the
            // flag also drives the subtype-based type-predicate narrowing (see
            // `makeArrayReadonly`).
            if (c.ts.kind(inner) == .array and !c.ts.arrayIsReadonly(inner))
                return c.ts.makeArrayReadonly(c.ts.arrayElem(inner));
            // `readonly [a, b]`: the modifier is a property of the TUPLE (tsc
            // keeps it on the tuple target), so it survives interning and
            // every derivation made with `makeTupleLike`.
            if (c.ts.kind(inner) == .tuple and !c.ts.tupleIsReadonly(inner)) {
                const elems = try c.scratch().alloc(types.TupleElem, c.ts.tupleLen(inner));
                defer c.scratch().free(elems);
                for (elems, 0..) |*e, i| e.* = c.ts.tupleElem(inner, @intCast(i));
                return c.ts.makeTupleFlags(elems, c.ts.tupleFlags(inner) | types.tuple_flag_readonly);
            }
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
            try checkIndexedAccessIndexType(c, acc, node);
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
    // knows yet. Leave those signatures unexpanded rather than mis-assigning
    // position 1 to the trailing element; `sigNonArrayRest` picks exactly
    // those up and has the argument list satisfy the tuple as a WHOLE, which
    // is the only form of the question that has an answer.
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
/// ztsc covers the two shapes where per-position typing provably cannot answer:
///
///   * a UNION rest — position 1 of `[k, o?] | [k, d, o?]` would have to union
///     the options bag with the default string, which relates to neither arm;
///   * a tuple rest with a rest or variadic element BEFORE its last position
///     (`...args: [...strs: string[], n: number]`) — which target position an
///     argument lands on then depends on how many arguments there are, so
///     "position 1" is a question with no answer (`elemOfArrayish` gave the
///     union of every element type, which blamed the wrong argument).
///
/// `from` is where the whole-list check starts: tsc's `getEffectiveRestType`
/// slices the tuple at its `fixedLength`, leaving the leading FIXED elements on
/// the ordinary per-position walk. A fully fixed tuple rest has no effective
/// rest type at all (it expands positionally) and a plain `T[]` rest is an
/// array, so both keep the per-position walk entirely.
pub const NonArrayRest = struct {
    /// The type the packed argument tuple must satisfy.
    ty: TypeId,
    /// The first argument index that goes into the packed tuple.
    from: u32,
};

pub fn sigNonArrayRest(c: *Checker, sig: TypeId) Error!?NonArrayRest {
    const count = c.ts.fnParamCount(sig);
    if (count == 0) return null;
    const p = c.ts.fnParam(sig, count - 1);
    if (!p.rest()) return null;
    switch (c.ts.kind(p.ty)) {
        .union_type, .ref, .tuple => {},
        else => return null,
    }
    const r = try c.resolveStructural(p.ty);
    if (c.ts.kind(r) == .union_type) return .{ .ty = r, .from = count - 1 };
    if (c.ts.kind(r) != .tuple) return null;
    const fixed = tuple_relate.fixedLength(c, r);
    const len = c.ts.tupleLen(r);
    // An empty tuple rest (`...args: []`), nothing variable at all, or a lone
    // variable element in LAST position: the positional expansion
    // (`restTupleOf`) already answers every position.
    if (len == 0 or fixed >= len - 1) return null;
    const rest_slice = try sliceTuple(c, r, fixed, 0);
    if (c.ts.kind(rest_slice) != .tuple) return null;
    return .{ .ty = rest_slice, .from = count - 1 + fixed };
}

/// tsc's `sliceTupleType`: `tup`'s elements from `index` through
/// `arity - end_skip`, as a tuple.
///
/// ```ts
/// return index > target.fixedLength ? getRestArrayTypeOfTupleType(type) || createTupleType(emptyArray) :
///     createTupleType(getTypeArguments(type).slice(index, endIndex), target.elementFlags.slice(index, endIndex), …);
/// ```
///
/// The cut is at the FIXED length, not the arity: a slice that starts PAST the
/// last fixed position has no positional form left and answers with the rest
/// ARRAY the variable tail spans. A slice starting exactly AT the variable part
/// lands on the same answer through `makeTuple`, which collapses a lone rest
/// element to its array — which is why only `index > fixedLength` needed the
/// explicit arm. It is what splits `[number, boolean, ...string[]]` for
/// `curry(fn2, 1, true, 'abc', 'def')`, whose implied arity of 4 runs past the
/// source's 3 positions: `U := string[]`, not the empty tuple
/// (`variadicTuples1`).
pub fn sliceTuple(c: *Checker, tup: TypeId, index: u32, end_skip: u32) Error!TypeId {
    const len = c.ts.tupleLen(tup);
    if (index > tuple_relate.fixedLength(c, tup)) {
        return (try restArrayOfTuple(c, tup)) orelse c.ts.makeTuple(&.{});
    }
    if (index > len or index + end_skip > len) return c.ts.makeTuple(&.{});
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    for (index..len - end_skip) |i| {
        try elems.append(c.scratch(), c.ts.tupleElem(tup, @intCast(i)));
    }
    return c.ts.makeTuple(elems.items);
}

/// tsc's `getRestArrayTypeOfTupleType`: the array `tup`'s variable tail spans.
/// `null` when the tuple has no variable tail.
pub fn restArrayOfTuple(c: *Checker, tup: TypeId) Error!?TypeId {
    return tupleSliceElemArray(c, tup, tuple_relate.fixedLength(c, tup), 0);
}

/// `createArrayType(getElementTypeOfSliceOfTupleType(tup, index, end_skip))`:
/// the array that ONE variable position spanning `tup`'s elements from `index`
/// through `arity - end_skip` would have. `null` for an empty slice.
///
/// A variable element contributes its ELEMENT type — tsc reads it as
/// `getIndexedAccessType(t, numberType)`, and ztsc stores the array itself on
/// such an element, so `elemOfArrayish` is that read:
///
/// ```ts
/// elementTypes.push(type.target.elementFlags[i] & ElementFlags.Variadic ? getIndexedAccessType(t, numberType) : t);
/// ```
pub fn tupleSliceElemArray(c: *Checker, tup: TypeId, index: u32, end_skip: u32) Error!?TypeId {
    const len = c.ts.tupleLen(tup);
    if (index + end_skip >= len) return null;
    const mid = try c.scratch().alloc(TypeId, len - end_skip - index);
    defer c.scratch().free(mid);
    for (mid, index..) |*m, i| {
        const e = c.ts.tupleElem(tup, @intCast(i));
        m.* = if (tuple_relate.elemKind(c, e).variable()) try c.elemOfArrayish(e.ty) else e.ty;
    }
    return try c.ts.makeArray(try c.ts.makeUnion(c.scratch(), mid));
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

/// The bigint LITERAL type `-<lit>` denotes, for the literal token `lit`.
/// Shared by the two positions the negation is written in: a literal TYPE
/// (`let f: -1n`, the `.prefix_unary` arm above) and an EXPRESSION (`-1n`,
/// `checkPrefixUnary`'s `.minus` arm, which passes `fresh`).
///
/// tsc models a bigint literal as a `{ negative, base10Value }` pseudo-bigint
/// and `pseudoBigIntToString` writes the sign in front; ztsc keys one by its
/// source text, so the negated form is that text with a `-` glued on. The one
/// value that does not take the sign is ZERO — tsc's own `negative &&
/// base10Value !== "0"` guard — without which `-0n` and `0n` would be two
/// types that print alike.
pub fn negatedBigIntLiteral(c: *Checker, lit: TokenIndex, fresh: bool) Error!TypeId {
    const text = c.tokenText(lit);
    if (bigIntTokenIsZero(text)) return c.ts.makeBigIntLiteral(try c.atomOfToken(lit), fresh);
    // Scratch, like every other synthetic member/type name built from token
    // text (`computedSymKey`): the arena is reset per source element, and
    // `internText` copies before the slice can go away.
    const s = try std.fmt.allocPrint(c.scratch(), "-{s}", .{text});
    return c.ts.makeBigIntLiteral(try c.internText(s), fresh);
}

/// Is a bigint literal token's text the value zero (`0n`, `0x0n`, `0b0_0n`)?
fn bigIntTokenIsZero(text: []const u8) bool {
    var digits = text;
    if (std.mem.endsWith(u8, digits, "n")) digits = digits[0 .. digits.len - 1];
    if (digits.len > 2 and digits[0] == '0') {
        switch (digits[1]) {
            'x', 'X', 'b', 'B', 'o', 'O' => digits = digits[2..],
            else => {},
        }
    }
    if (digits.len == 0) return false;
    for (digits) |ch| {
        if (ch != '0' and ch != '_') return false;
    }
    return true;
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
        const m_empty = isEmptyAnonObject(c, m);
        const m_fresh = c.ts.objectIsFresh(m);
        for (members, 0..) |o, j| {
            if (i == j) continue;
            if (c.ts.objectIsFresh(o)) continue; // a fresh literal never absorbs
            if (isEmptyAnonObject(c, o)) continue; // `{}` never absorbs
            if (m_fresh and try freshHasExcessProp(c, m, o)) continue;
            if (!try c.isAssignable(m, o)) continue; // m not a subtype of o
            if (try strictArityWiderThan(c, m, o)) continue; // nor under StrictArity
            if (!m_empty and (try c.isAssignable(o, m)) and !(try strictArityWiderThan(c, o, m))) {
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

/// Does `src` declare MORE parameter positions than `tgt` accepts? tsc's
/// `signatureRelatedTo` runs the strict-subtype relation — the one union
/// reduction uses — under `SignatureCheckMode.StrictArity`, where the arity
/// guard reads `getParameterCount(source) > getParameterCount(target)` instead
/// of assignability's `getMinArgumentCount(source) > …`. Optional parameters
/// count, so `(b?: string) => void` is NOT a subtype of `() => void` even
/// though the two are mutually ASSIGNABLE — which is the whole difference in
///
///     declare const val: { something(): void };
///     function run(options: { something?(b?: string): void }) {
///         const something = options.something ?? val.something;
///         something('');
///     }
///
/// (`unionReductionMutualSubtypes`): tsc reduces to the `(b?: string)` arm and
/// the call is fine, while a symmetric reduction could keep `() => void` and
/// report a false TS2554. A target with an EFFECTIVE rest parameter
/// (unbounded, i.e. `paramTotal` saturates) skips the guard entirely, exactly
/// as `hasEffectiveRestParameter` does.
///
/// Top-level signatures only. tsc threads the check mode through the whole
/// relation, so a signature nested in a property is compared the same way;
/// reproducing that needs a relation mode `isAssignable` does not carry, and
/// the shallow rule is the one that is observable here.
fn strictArityWiderThan(c: *Checker, src: TypeId, tgt: TypeId) Error!bool {
    if (c.ts.kind(src) != .function or c.ts.kind(tgt) != .function) return false;
    if ((try c.paramTotal(tgt)) == std.math.maxInt(u32)) return false;
    return (try c.effParamCount(src)) > try c.effParamCount(tgt);
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
fn freshHasExcessProp(c: *Checker, m: TypeId, o0: TypeId) Error!bool {
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
fn isEmptyAnonObject(c: *Checker, t: TypeId) bool {
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
/// Everything except an `any` base is `classes.mergeBaseObjectPlain` verbatim.
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
    // `readonly` on whichever signature last claimed each slot — tsc's
    // `IndexInfo.isReadonly`, which the write sites report TS2542 from.
    var sindex_ro = false;
    var nindex_ro = false;
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
                else blk: {
                    // An un-annotated member of an interface or a type literal
                    // has nothing to infer from: TS7008. This is tsc's
                    // `widenTypeForVariableLikeDeclaration` fallback, and it is
                    // the same report a class field gets from the class walk.
                    try implicit_any.reportMemberImplicitAny(c, c.tree.nodeMainToken(m), md.rhs);
                    break :blk types.any_type;
                };
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
                const ro = md.rhs & ast.Flags.readonly != 0;
                if (key == types.number_type) {
                    nindex = val;
                    nindex_ro = ro;
                } else {
                    sindex_ro = ro;
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
    var flags = if (sym_index and !str_index and nindex == 0)
        obj_flags | types.obj_flag_symbol_index
    else
        obj_flags;
    if (sindex_ro and sindex != 0) flags |= types.obj_flag_readonly_string_index;
    if (nindex_ro and nindex != 0) flags |= types.obj_flag_readonly_number_index;
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
                // tsc's `getSpreadType` copies only SPREADABLE members: a
                // `private`/`protected` field and a class-declared method or
                // accessor stay behind, exactly as they do for a destructuring
                // rest (`types.Prop.spreadable`, `objectRestType`).
                if (!p.spreadable()) continue;
                // tsc's `getSpreadType`: when a property is present in both
                // the accumulated left (`{ a, b, ... }`) and this spread and
                // the spread's property is OPTIONAL, the result keeps the
                // LEFT's optionality and unions the value types. So an
                // explicit required prop stays required even when a later
                // `Partial<…>` spread re-supplies it optionally — without
                // this, every prop of `{ id, active, ...overrides }` (with
                // `overrides: Partial<X>`) became optional and failed
                // assignment to the required target (TS2322 factory FPs).
                try addSpreadProp(c, p, props, prop_index);
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
                try addSpreadProp(c, merged, props, prop_index);
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
                try addSpreadProp(c, .{
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
fn addSpreadProp(
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
