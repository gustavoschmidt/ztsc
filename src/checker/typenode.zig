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
const modules = @import("../link/modules.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const FileId = checker_zig.FileId;
const Check = checker_zig.Check;
const check = checker_zig.check;

const TpMap = @import("enums.zig").TpMap;
const annTypeMaybeUnique = Checker.annTypeMaybeUnique;
const atom = Checker.atom;
const checkIdentifier = @import("expr.zig").checkIdentifier;
const classStaticType = @import("enums.zig").classStaticType;
const elaborate = @import("elaborate.zig");
const expandRef = @import("instantiate.zig").expandRef;
const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const indexOfAtom = @import("generics.zig").indexOfAtom;
const inferTypeArgs = @import("calls.zig").inferTypeArgs;
const inferVarFromNode = @import("generics.zig").inferVarFromNode;
const instantiate = @import("enums.zig").instantiate;
const intrinsicStringMapping = @import("generics.zig").intrinsicStringMapping;
const lazyRefProp = @import("instantiate.zig").lazyRefProp;
const propOfType = @import("props.zig").propOfType;
const scopeOf = Checker.scopeOf;
const scratch = Checker.scratch;
const signatureAssignableModeInner = @import("assign.zig").signatureAssignableModeInner;
const signatureOfProto = @import("signatures.zig").signatureOfProto;
const stripQuotes = Checker.stripQuotes;

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
        .this_expr => return if (c.this_type != 0) c.this_type else types.any_type,
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

/// A named type reference (identifier, possibly with type arguments).
pub fn typeFromTypeName(c: *Checker, name_node: Node, args: []const TypeId) Error!TypeId {
    return typeFromTypeNameEx(c, name_node, args, null);
}

/// `typeFromTypeName`, additionally reporting WHICH generic symbol the name
/// resolved to. Only the syntactic type-reference arm needs it — to check the
/// written type arguments against that symbol's constraints (TS2344) — and
/// only it pays for the out-parameter.
pub fn typeFromTypeNameEx(c: *Checker, name_node: Node, args: []const TypeId, out_sym: ?*SymbolId) Error!TypeId {
    if (name_node == null_node) return types.any_type;
    // `member_expr` appears when the name came from expression position
    // (class/interface `extends` clauses); it shares qualified_name's
    // layout (lhs = base node, rhs = name token).
    if (c.nodeTag(name_node) == .qualified_name or c.nodeTag(name_node) == .member_expr)
        return c.typeFromQualifiedName(name_node, args);
    if (c.nodeTag(name_node) != .identifier) return types.any_type;
    const tok = c.tree.nodeMainToken(name_node);
    switch (c.tree.tokens.tag(tok)) {
        .keyword_any => return types.any_type,
        .keyword_unknown => return types.unknown_type,
        .keyword_never => return types.never_type,
        .keyword_void => return types.void_type,
        .keyword_undefined => return types.undefined_type,
        .keyword_number => return types.number_type,
        .keyword_string => return types.string_type,
        .keyword_boolean => return types.boolean_type,
        .keyword_bigint => return types.bigint_type,
        .keyword_symbol => return types.symbol_type,
        .keyword_object => return types.object_keyword_type,
        else => {},
    }
    const a = try c.atomOfToken(tok);
    // An `infer V` binder is in scope (extends + true branches) as a bare
    // type reference to `V`. It shadows outer names, matching tsc. Search
    // the active conditional scopes innermost-outward: a nested conditional
    // in an outer conditional's true branch still resolves the outer infer
    // vars (only scopes that actually declared `V` have an entry).
    // A same-named type param of the alias body currently being built is
    // more local than any outer `infer`/mapped binder, so it shadows them
    // (tsc lexical scoping) — skip both lookups for such a name.
    const shadowed = indexOfAtom(c.tp_shadow, a) != null;
    if (args.len == 0 and !shadowed) {
        // Lexical innermost-wins between an outer conditional's `infer X`
        // and a same-named mapped key `[X in K]`: the mapped key is
        // declared INSIDE the branch that binds `infer X`, so within the
        // mapped `as`/value a bare `X` is the mapped param and shadows the
        // infer binder — matching tsc, and (crucially) making the built
        // value route-independent. `cur_mapped_key_scope_depth` is the
        // infer-scope stack height when the mapped key was entered: scopes
        // below it are OUTER (mapped key shadows them); scopes at/above it
        // belong to a conditional NESTED in the mapped value and stay inner
        // (they still win). Without this, `{ [P in K]: T[P] }` nested in a
        // `… infer P …` branch built its value as `T[infer_var]`; the
        // unbound infer var collapses the indexed access to `any` at
        // reduction → every prop dropped to required (the
        // `--checkers`-partition-dependent TS2739/TS2322 non-confluence).
        //
        // The lookup walks the mapped-key STACK innermost-out, so a mapped
        // type nested in another map's value still resolves the ENCLOSING
        // key (`{ [P in keyof S]: { [M in keyof S[P]]: S[P][M] } }` — `P` in
        // the inner value); an inner key of the same name shadows the outer.
        const mk = c.lookupMappedKey(a);
        var i = c.infer_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (mk) |e| if (i < e.infer_depth) return e.ty;
            if (c.infer_ids.get(.{ .cond = c.infer_scopes.items[i], .name = a })) |id| {
                // A bare mention of an already-declared binder, not the
                // `infer V` declaration (that path is `inferVarFromNode`).
                // Flagged so a NESTED conditional that mentions it in its
                // own extends clause (`string extends R`, React's
                // `PropsWithRef`) does not treat it as its own binder.
                return c.ts.makeInferVar(id, a, true);
            }
        }
        // A mapped type's key parameter `K` is in scope in its `as`/value
        // branches; a bare `K` there resolves to the mapped_param.
        if (mk) |e| return e.ty;
    }
    switch (c.resolveSpace(a, c.cur_scope, false)) {
        .sym => |sym0| {
            var sym = sym0;
            var f = c.symFlags(sym);
            if (f.import_binding) {
                const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
                switch (tgt.kind) {
                    .binding => {
                        const g = c.toGlobalIn(tgt.file, tgt.payload);
                        // Route through the cross-file merge index so an
                        // imported interface augmented by a `declare module`
                        // in another file resolves to the folded interface
                        // (cross-file augmentation).
                        sym = c.prog.mergedOf(g) orelse g;
                        f = c.symFlags(sym);
                        if (!hasTypeMeaning(f) or f.import_binding) {
                            if (hasValueMeaning(f)) {
                                try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
                                return types.error_type;
                            }
                            return types.any_type;
                        }
                    },
                    // Namespace-as-type / a property of an `export =` value
                    // (value space only) / unresolved: any (documented).
                    .namespace, .default_expr, .ambient_ns, .export_equals_prop, .any => return types.any_type,
                }
            }
            if (out_sym) |o| o.* = sym;
            return c.materializeTypeRef(sym, args, tok, a);
        },
        .wrong_space => {
            try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
            return types.error_type;
        },
        .none => {
            // Inside a `declare module "X"` augmentation of a real module,
            // an unqualified name resolves against X's own exports — the
            // augmentation shares X's symbol table in tsc. Lets `declare
            // module "leaflet" { namespace DrawEvents { interface DrawStop
            // extends LeafletEvent … } }` reach leaflet's `LeafletEvent`;
            // without it the heritage base silently drops and the interface
            // loses every inherited member (→ spurious TS2352 downstream on
            // a `DrawStop`-typed value cast to a `LeafletEvent` handler).
            if (try c.augmentModuleTypeSym(c.cur_scope, a)) |gsym| {
                if (out_sym) |o| o.* = gsym;
                return c.materializeTypeRef(gsym, args, tok, a);
            }
            // The four intrinsic string transforms are magic global
            // aliases (`type Uppercase<S extends string> = intrinsic;`),
            // not declared in ztsc's minimal lib — recognize them by name
            // here, after user symbols (which would shadow) had their turn.
            if (args.len == 1) {
                if (intrinsicStringMapping(c.atomText(a))) |kind_idx| {
                    return c.applyStringMapping(kind_idx, args[0]);
                }
            }
            if (c.suggestName(a, c.cur_scope, false)) |sugg| {
                try c.diagFmt(2552, c.tokSpan(tok), "Cannot find name '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
            } else {
                try c.reportNameNotFound(tok);
            }
            return types.error_type;
        },
    }
}

/// Materialize a resolved type-space symbol `sym` into its `TypeId`
/// (type-parameter / enum / alias-instance / interface-or-class ref),
/// applying `args`. Shared by the ordinary scope-resolution arm and the
/// `declare module` augmentation fallback so both build the identical type.
pub fn materializeTypeRef(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex, a: Atom) Error!TypeId {
    const f = c.symFlags(sym);
    if (f.type_param) return c.ts.makeTypeParam(sym);
    if (f.enum_decl) return c.ts.makeEnumType(sym);
    if (f.type_alias) {
        // The real lib declares the four string transforms as
        // `type Uppercase<S extends string> = intrinsic;`. Recognize an
        // `intrinsic`-bodied alias by name and apply the mapping (ztsc has
        // no general `intrinsic` mechanism). A user alias of the same name
        // with a real body is unaffected.
        if (args.len == 1) {
            if (intrinsicStringMapping(c.atomText(a))) |kind_idx| {
                if (c.aliasBodyIsIntrinsic(sym)) return c.applyStringMapping(kind_idx, args[0]);
            }
        }
        return c.aliasInstance(sym, args, tok);
    }
    if (f.interface or f.class) {
        const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
        // The global `Array<T>` / `ReadonlyArray<T>` lower to `T[]`: tsc
        // treats `Array<T>` and `T[]` as the *same* type, and
        // `ReadonlyArray<T>` as `readonly T[]` — which lowers to the same
        // members, only flagged (see `makeArrayReadonly`). Keeping them as
        // structural refs instead makes `T[]` fail to relate to them
        // through the interface body (ref→array has no structural bridge).
        if (fixed.len == 1 and c.globalSymNamed(sym, "Array")) {
            return c.ts.makeArray(fixed[0]);
        }
        if (fixed.len == 1 and c.globalSymNamed(sym, "ReadonlyArray")) {
            return c.ts.makeArrayReadonly(fixed[0]);
        }
        return c.ts.makeRef(sym, fixed);
    }
    return types.any_type;
}

/// Walk outward from `from` for an enclosing `declare module "X"`
/// augmentation block; if found, resolve the augmented module X (via the
/// current file's specifier map) and return export `a`'s type-space global
/// symbol. Powers tsc's rule that unqualified names inside a module
/// augmentation see the augmented module's own exports.
pub fn augmentModuleTypeSym(c: *Checker, from: ScopeId, a: Atom) Error!?SymbolId {
    if (c.prog.files.len == 0) return null;
    var s = from;
    while (true) {
        const owner = c.bind.scope_owners[s];
        if (owner != 0 and c.nodeTag(owner) == .namespace_decl) {
            const nd = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(owner).lhs);
            if (nd.flags & ast.Flags.ambient_module != 0 and nd.name_token != 0) {
                const spec = try c.memberAtom(nd.name_token);
                if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| {
                    if (c.moduleExportTarget(.{ .file = mfile }, a)) |tgt| {
                        if (c.targetTypeSym(tgt)) |gsym| {
                            if (hasTypeMeaning(c.symFlags(gsym))) return gsym;
                        }
                    }
                }
            }
        }
        if (s == binder.file_scope) break;
        s = c.bind.scope_parents[s];
    }
    return null;
}

/// Resolve member `name` of namespace symbol `ns_sym` to its global id, or
/// null. A merged namespace consults its merged member index; a
/// plain namespace looks the name up in its single (merged-within-file)
/// body scope. The caller filters by space/`exported`.
pub fn namespaceMemberSym(c: *Checker, ns_sym: SymbolId, name: Atom) ?SymbolId {
    if (c.prog.isMergedId(ns_sym)) {
        return c.prog.mergedSym(ns_sym).members.lookup(name);
    }
    const nb = c.symBind(ns_sym);
    const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return null;
    const local = nb.lookupInScope(ns, name) orelse return null;
    // Route through the cross-file merge index, like `targetTypeSym`: a
    // member of an `export = <namespace>` module reached as `ns.I` may be
    // the real half of a `declare module` augmentation merge, and the
    // file-local declaration alone carries none of the augmented members.
    const g = c.toGlobalIn(c.symFile(ns_sym), local);
    return c.prog.mergedOf(g) orelse g;
}

/// If namespace scope `s` belongs to a symbol that is a cross-file merge
/// constituent, return member `a` from the merged member index (a global
/// id), else null. Lets a bare name inside one file's namespace body see
/// declarations another file contributed to the same merged namespace.
pub fn mergedNsMemberOfScope(c: *Checker, s: ScopeId, a: Atom) ?SymbolId {
    const owner = c.bind.scope_owners[s];
    if (owner == 0 or c.nodeTag(owner) != .namespace_decl) return null;
    const nd = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(owner).lhs);
    // Only named namespaces merge by name; `global {}` / `declare module`
    // blocks carry a keyword/string name_token, not an identifier.
    if (nd.flags & (ast.Flags.global_aug | ast.Flags.ambient_module) != 0) return null;
    if (nd.name_token == 0) return null;
    const name = c.atomOfToken(nd.name_token) catch return null;
    const local = c.bind.lookupInScope(c.bind.scope_parents[s], name) orelse return null;
    const merged = c.prog.mergedOf(c.toGlobal(local)) orelse return null;
    if (!c.prog.isMergedId(merged)) return null;
    return c.prog.mergedSym(merged).members.lookup(a);
}

/// A resolved type-position `import("m")` target: an on-disk program file
/// or an ambient/augmentation module.
pub const ModuleRef = union(enum) { file: FileId, ambient: u32 };

/// The left side of a qualified type/entity name (`A.B.T`), resolved to the
/// container that holds its members: either a namespace symbol or a whole
/// module namespace object (`import * as ns from "m"`). Unifies the two
/// member-lookup mechanisms (namespace scope vs module export table) so a
/// namespace-import qualifier reaches a named-export module's members —
/// e.g. `import * as mod from "./m"; interface I extends mod.Base {}`.
pub const NsContainer = union(enum) { ns: SymbolId, module: ModuleRef };

/// Resolve an `.import_type` node's specifier to its module. Reports TS2307
/// (deduped per span; TS2591 for a Node core module — see
/// `reportModuleNotFound`) when the specifier resolves to neither an on-disk
/// module nor an ambient `declare module`.
pub fn resolveImportTypeModule(c: *Checker, import_node: Node, report: bool) Error!?ModuleRef {
    const spec_tok = c.tree.nodeData(import_node).lhs;
    if (spec_tok == 0) return null;
    const spec = try c.memberAtom(spec_tok);
    if (c.prog.files.len != 0) {
        if (c.prog.files[c.cur_file].specs.get(spec)) |mfile| return .{ .file = mfile };
    }
    if (c.ambientIndex(spec)) |idx| return .{ .ambient = idx };
    if (report) {
        try c.reportModuleNotFound(spec_tok);
    }
    return null;
}

/// Ambient-module registry index matching specifier `spec`: exact name,
/// else the best-matching wildcard pattern (`declare module "*.css"`) —
/// longest prefix, first declaration on a tie. Mirrors the linker's
/// `ambientKey` so import() types resolve against the same registry.
pub fn ambientIndex(c: *Checker, spec: Atom) ?u32 {
    const specs = c.prog.ambient_specs;
    for (specs, 0..) |s, i| if (s == spec) return @intCast(i);
    const text = c.atomText(spec);
    var best: ?u32 = null;
    var best_prefix: usize = 0;
    for (specs, 0..) |s, i| {
        const pat = c.atomText(s);
        const star = std.mem.indexOfScalar(u8, pat, '*') orelse continue;
        const prefix = pat[0..star];
        const suffix = pat[star + 1 ..];
        if (text.len < prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        if (!std.mem.endsWith(u8, text, suffix)) continue;
        if (best == null or prefix.len > best_prefix) {
            best = @intCast(i);
            best_prefix = prefix.len;
        }
    }
    return best;
}

/// Look up export `name` in a resolved module, returning its link Target.
pub fn moduleExportTarget(c: *Checker, m: ModuleRef, name: Atom) ?modules.Target {
    switch (m) {
        .file => |f| {
            if (c.prog.links.len == 0) return null;
            return c.prog.links[f].exportTarget(name);
        },
        .ambient => |idx| {
            const ae = c.prog.ambient_exports[idx];
            var lo: usize = 0;
            var hi: usize = ae.atoms.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (ae.atoms[mid] == name) return ae.targets[mid];
                if (ae.atoms[mid] < name) lo = mid + 1 else hi = mid;
            }
            return null;
        },
    }
}

/// Member `name` of a module that exports a namespace by assignment
/// (`export = ns`), as a GLOBAL symbol id. The module's own export table only
/// holds the assignment, under the reserved `export=` key, so a plain
/// `moduleExportTarget` miss is not the end of the lookup: tsc resolves
/// `import("m").name` — like `import { name } from "m"` — against the members
/// of the export-assigned entity. `@types/node`'s `declare module "assert" {
/// namespace assert { function ok(…): …; … } export = assert; }` is the shape;
/// without this every `typeof import("node:assert").ok` in `test.d.ts` was a
/// spurious TS2694. Null when the module has no export assignment, when the
/// assignment is not a namespace, or when the member is not exported.
pub fn exportEqualsMemberSym(c: *Checker, m: ModuleRef, name: Atom) ?SymbolId {
    return exportEqualsMemberSymAt(c, m, name, 0);
}

fn exportEqualsMemberSymAt(c: *Checker, m: ModuleRef, name: Atom, depth: u32) ?SymbolId {
    if (depth > 8) return null; // `export =` chains are shallow; cycles are not
    if (c.prog.export_equals_atom == 0) return null;
    const eq = c.moduleExportTarget(m, c.prog.export_equals_atom) orelse return null;
    switch (eq.kind) {
        .binding => {
            const ns = targetTypeSym(c, eq) orelse return null;
            const mem = c.namespaceMemberSym(ns, name) orelse return null;
            return if (c.symFlags(mem).exported) mem else null;
        },
        // `export = ` a whole module-namespace object: its members are that
        // module's exports.
        .namespace => {
            const tgt = c.moduleExportTarget(.{ .file = eq.file }, name) orelse return null;
            return targetTypeSym(c, tgt);
        },
        // `declare module "node:assert" { import a = require("assert");
        // export = a; }` — the assignment is another ambient module's
        // namespace; ask it the same question.
        .ambient_ns => {
            const sub: ModuleRef = .{ .ambient = eq.payload };
            if (c.moduleExportTarget(sub, name)) |tgt| {
                if (targetTypeSym(c, tgt)) |g| return g;
            }
            return exportEqualsMemberSymAt(c, sub, name, depth + 1);
        },
        else => return null,
    }
}

/// The global symbol an export Target denotes (for type materialization),
/// or null for non-binding targets (namespace objects, default expressions).
pub fn targetTypeSym(c: *Checker, tgt: modules.Target) ?SymbolId {
    return switch (tgt.kind) {
        // Route through the cross-file merge index so a `ns.I` / qualified /
        // `import("m").I` reference to an interface augmented by a
        // `declare module` in another file sees the folded interface.
        .binding => blk: {
            const g = c.toGlobalIn(tgt.file, tgt.payload);
            break :blk c.prog.mergedOf(g) orelse g;
        },
        else => null,
    };
}

/// `import("m").T[<args>]` in type position: resolve the module, then
/// its exported type `T`. Unresolved module ⇒ TS2307 (in the resolver);
/// missing/non-type member ⇒ TS2694, matching tsc.
pub fn importTypeMember(c: *Checker, import_node: Node, name_tok: TokenIndex, args: []const TypeId) Error!TypeId {
    const m = (try c.resolveImportTypeModule(import_node, true)) orelse return types.error_type;
    const name = try c.memberAtom(name_tok);
    if (c.moduleExportTarget(m, name)) |tgt| {
        if (c.targetTypeSym(tgt)) |sym| {
            if (hasTypeMeaning(c.symFlags(sym))) return c.namedTypeFromSymbol(sym, args, name_tok);
        }
    }
    if (c.exportEqualsMemberSym(m, name)) |sym| {
        if (hasTypeMeaning(c.symFlags(sym))) return c.namedTypeFromSymbol(sym, args, name_tok);
    }
    const spec_tok = c.tree.nodeData(import_node).lhs;
    try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ stripQuotes(c.tokenText(spec_tok)), c.atomText(name) });
    return types.error_type;
}

/// Resolve a qualified type name `A.B.T` (in type position) by walking
/// namespace containers left-to-right, then building the final member's
/// type. Missing/non-exported members report TS2694 like tsc.
pub fn typeFromQualifiedName(c: *Checker, node: Node, args: []const TypeId) Error!TypeId {
    const d = c.tree.nodeData(node);
    const name_tok: TokenIndex = d.rhs;
    // `import("m").T` — the qualifier base is a module, not a namespace sym.
    if (c.nodeTag(d.lhs) == .import_type) return c.importTypeMember(d.lhs, name_tok, args);
    const name = try c.memberAtom(name_tok);
    // A qualified ENUM MEMBER in type position (`WS.INIT`, `NS.E.X`): the
    // member's own nominal unit type. Checked before the namespace walk —
    // an enum symbol is not a namespace container, so `resolveNsContainer`
    // returns null for it and the whole annotation used to degrade to
    // `any`, taking every union discriminated by enum members with it.
    if (try c.enumSymOfQualifier(d.lhs)) |esym| {
        if (try c.enumHasMemberNamed(esym, name)) return c.ts.makeEnumMember(esym, name, false);
        // An enum merged with a namespace still has namespace members;
        // only a pure enum can conclude "no such member" here.
        if (!c.symFlags(esym).namespace_decl) {
            try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ c.symbolName(esym), c.atomText(name) });
            return types.error_type;
        }
    }
    const container = (try c.resolveNsContainer(d.lhs)) orelse return types.any_type;
    switch (container) {
        .ns => |ns_sym| {
            if (c.namespaceMemberSym(ns_sym, name)) |g| {
                const mf = c.symFlags(g);
                if (mf.exported and hasTypeMeaning(mf)) {
                    return c.namedTypeFromSymbol(g, args, name_tok);
                }
            }
            try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ c.symbolName(ns_sym), c.atomText(name) });
            return types.error_type;
        },
        .module => |m| {
            if (c.moduleExportTarget(m, name)) |tgt| {
                if (c.targetTypeSym(tgt)) |g| {
                    if (hasTypeMeaning(c.symFlags(g))) return c.namedTypeFromSymbol(g, args, name_tok);
                }
            }
            // A member ztsc cannot resolve through a namespace-import module
            // (incomplete `export *` / re-export modeling, CommonJS namespace
            // identity out of subset) degrades to `any` rather than a
            // spurious TS2694 — the documented under-report policy. The
            // fix is that resolvable members (`extends mod.Base`) now bind;
            // unresolvable ones stay as lenient as the pre-fix `any`.
            return types.any_type;
        },
    }
}

/// The enum symbol a qualified-name qualifier denotes — `WS` in `WS.INIT`,
/// `NS.E` in `NS.E.X`, an `import`ed alias of either — or null when the
/// qualifier is not an enum.
pub fn enumSymOfQualifier(c: *Checker, node: Node) Error!?SymbolId {
    switch (c.nodeTag(node)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(node));
            switch (c.resolveSpace(a, c.cur_scope, false)) {
                .sym => |sym| {
                    if (c.symFlags(sym).enum_decl) return sym;
                    if (c.symFlags(sym).import_binding) {
                        if (c.importTarget(sym)) |tgt| return c.enumSymFromImportTarget(tgt);
                    }
                    return null;
                },
                else => return null,
            }
        },
        .qualified_name, .member_expr => {
            const d = c.tree.nodeData(node);
            const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
            const g = c.containerMemberSym(outer, try c.memberAtom(d.rhs)) orelse return null;
            return if (c.symFlags(g).enum_decl) g else null;
        },
        else => return null,
    }
}

pub fn enumSymFromImportTarget(c: *Checker, tgt: modules.Target) ?SymbolId {
    if (tgt.kind != .binding) return null;
    const g = c.toGlobalIn(tgt.file, tgt.payload);
    if (c.symFlags(g).enum_decl) return g;
    if (c.symFlags(g).import_binding) {
        if (c.importTarget(g)) |t2| return c.enumSymFromImportTarget(t2);
    }
    return null;
}

/// Resolve the qualifier of a dotted type/entity name (identifier or nested
/// qualified name) to the container that holds its members — a namespace
/// symbol or a whole-module namespace object. Follows `import * as ns` /
/// `import = require` bindings to the imported module so `ns.Member` reaches
/// a named-export module's exports (previously such a base silently degraded
/// to `any`, so heritage `extends ns.Base` inherited zero members). Null for
/// a non-namespace or unresolvable qualifier.
pub fn resolveNsContainer(c: *Checker, node: Node) Error!?NsContainer {
    switch (c.nodeTag(node)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(node));
            switch (c.resolveSpace(a, c.cur_scope, false)) {
                .sym => |sym| {
                    if (c.symFlags(sym).namespace_decl) return .{ .ns = sym };
                    if (c.symFlags(sym).import_binding) {
                        if (c.importTarget(sym)) |tgt| return c.containerFromImportTarget(tgt);
                    }
                    return null;
                },
                else => return null,
            }
        },
        .qualified_name, .member_expr => {
            const d = c.tree.nodeData(node);
            const name = try c.memberAtom(d.rhs);
            // `import("m").NS` as a namespace container: the module itself.
            if (c.nodeTag(d.lhs) == .import_type) {
                const m = (try c.resolveImportTypeModule(d.lhs, true)) orelse return null;
                return c.nestNsContainer(.{ .module = m }, name);
            }
            const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
            return c.nestNsContainer(outer, name);
        },
        else => return null,
    }
}

/// Follow an import-binding link target to the namespace container it
/// denotes: a namespace declaration symbol (the `export =` entity of an
/// `export =`-module, or a re-export), or the whole-module namespace object
/// of a plain named-export module (`import * as`). Null otherwise.
pub fn containerFromImportTarget(c: *Checker, tgt: modules.Target) ?NsContainer {
    switch (tgt.kind) {
        .binding => {
            const g = c.toGlobalIn(tgt.file, tgt.payload);
            if (c.symFlags(g).namespace_decl) return .{ .ns = g };
            if (c.symFlags(g).import_binding) {
                if (c.importTarget(g)) |t2| return c.containerFromImportTarget(t2);
            }
            return null;
        },
        .namespace => return .{ .module = .{ .file = tgt.file } },
        .ambient_ns => return .{ .module = .{ .ambient = tgt.payload } },
        else => return null,
    }
}

/// Resolve member `name` of a container to a *nested* namespace container
/// (for a deeper `a.b.c` qualifier). Requires the member to be an exported
/// namespace (or a re-export/namespace-import of one). Null otherwise.
pub fn nestNsContainer(c: *Checker, outer: NsContainer, name: Atom) ?NsContainer {
    switch (outer) {
        .ns => |ns| {
            const g = c.namespaceMemberSym(ns, name) orelse return null;
            const mf = c.symFlags(g);
            if (!mf.exported) return null;
            if (mf.namespace_decl) return .{ .ns = g };
            if (mf.import_binding) {
                if (c.importTarget(g)) |t2| return c.containerFromImportTarget(t2);
            }
            return null;
        },
        .module => |m| {
            const tgt = c.moduleExportTarget(m, name) orelse return null;
            return c.containerFromImportTarget(tgt);
        },
    }
}

/// The exported member symbol `name` of a namespace container (global id),
/// or null. Shared by qualified-entity resolution that needs the member's
/// declaration symbol (class-`extends` bases) rather than its type.
pub fn containerMemberSym(c: *Checker, container: NsContainer, name: Atom) ?SymbolId {
    switch (container) {
        .ns => |ns| {
            const g = c.namespaceMemberSym(ns, name) orelse return null;
            return if (c.symFlags(g).exported) g else null;
        },
        .module => |m| {
            const tgt = c.moduleExportTarget(m, name) orelse return null;
            return c.targetTypeSym(tgt);
        },
    }
}

/// Display text of a qualified-name qualifier's trailing identifier, for
/// TS2694 messages (`Namespace '<here>' has no exported member '…'`).
pub fn qualifierText(c: *Checker, node: Node) []const u8 {
    return switch (c.nodeTag(node)) {
        .identifier => c.tokenText(c.tree.nodeMainToken(node)),
        .qualified_name, .member_expr => c.tokenText(c.tree.nodeData(node).rhs),
        else => "",
    };
}

/// Build the type of a named type symbol (interface/class/alias/enum/
/// type-param). Shared by bare and qualified type-name resolution.
pub fn namedTypeFromSymbol(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!TypeId {
    const f = c.symFlags(sym);
    if (f.type_param) return c.ts.makeTypeParam(sym);
    if (f.enum_decl) return c.ts.makeEnumType(sym);
    if (f.type_alias) return c.aliasInstance(sym, args, tok);
    if (f.interface or f.class) {
        const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
        return c.ts.makeRef(sym, fixed);
    }
    return types.any_type;
}

/// `typeof entity` in type position: the entity's value type.
/// tsc's `getRegularTypeOfLiteralType`: a `typeof x` type query never yields
/// a *fresh* (widening) literal — the const's widening-literal type is
/// regularized so the query result does not re-widen when later used as an
/// object-literal property type. De-freshens the top literal and, for a
/// union, each member; leaves everything else (incl. objects) untouched.
pub fn regularizeTypeQuery(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.isFreshLiteral(t)) return c.ts.regularLiteral(t);
    if (c.ts.kind(t) == .union_type) {
        var any_fresh = false;
        for (try c.memberList(t)) |m| {
            if (c.ts.isFreshLiteral(m)) any_fresh = true;
        }
        if (!any_fresh) return t;
        var list: std.ArrayList(TypeId) = .empty;
        defer list.deinit(c.scratch());
        for (try c.memberList(t)) |m| try list.append(c.scratch(), try c.regularizeTypeQuery(m));
        return c.ts.makeUnion(c.scratch(), list.items);
    }
    return t;
}

pub fn typeofEntity(c: *Checker, node: Node) Error!TypeId {
    if (node == null_node) return types.any_type;
    // `typeof import("m")` — the module's value-namespace object type.
    if (c.nodeTag(node) == .import_type) {
        const m = (try c.resolveImportTypeModule(node, true)) orelse return types.error_type;
        return switch (m) {
            .file => |f| c.namespaceObjectType(f),
            .ambient => |idx| c.ambientNamespaceType(idx),
        };
    }
    // `typeof import("m").val` — the value type of the export `val`.
    if (c.nodeTag(node) == .qualified_name) {
        const d = c.tree.nodeData(node);
        if (c.nodeTag(d.lhs) == .import_type) {
            const m = (try c.resolveImportTypeModule(d.lhs, true)) orelse return types.error_type;
            const name = try c.memberAtom(d.rhs);
            if (c.moduleExportTarget(m, name)) |tgt| return c.targetValueType(tgt);
            if (c.exportEqualsMemberSym(m, name)) |sym| {
                return c.regularizeTypeQuery(try c.typeOfSymbol(sym));
            }
            const spec_tok = c.tree.nodeData(d.lhs).lhs;
            try c.diagFmt(2694, c.tokSpan(d.rhs), "Namespace '{s}' has no exported member '{s}'.", .{ stripQuotes(c.tokenText(spec_tok)), c.atomText(name) });
            return types.error_type;
        }
        // `typeof A.b` for any other qualified entity name (a namespace
        // member, a namespace-import member, a nested namespace, a static):
        // a type query names a VALUE, so the answer is property `b` on the
        // type of `A`. This used to fall through to `any`, which erased the
        // whole type downstream — `Radix.ComponentPropsWithoutRef<typeof
        // Primitive.div>` (the shape every Radix component's props are
        // built from) collapsed to `{}`, so every attribute on such a
        // component read as excess.
        const base = try c.typeofEntity(d.lhs);
        const rb = try c.resolveStructural(base);
        if (c.ts.kind(rb) == .any or c.ts.kind(rb) == .err) return rb;
        if (try c.propOfType(rb, try c.memberAtom(d.rhs))) |p| {
            return c.regularizeTypeQuery(p.ty);
        }
        // Unknown member: stay silent (`any`) rather than risk a false
        // positive — the value-position access reports it where written.
        return types.any_type;
    }
    if (c.nodeTag(node) != .identifier) return types.any_type;
    const tok = c.tree.nodeMainToken(node);
    if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
    const a = try c.atomOfToken(tok);
    switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| return c.regularizeTypeQuery(try c.typeOfSymbol(sym)),
        .wrong_space => |sym| {
            // A type-only import binding is excluded from value space by
            // `hasValueMeaning` so that a *value* use reports TS1361 — but
            // it still denotes the imported entity, and a type query is a
            // TYPE position: `import type { App }` followed by
            // `typeof App` / `InstanceType<typeof App>` is legal in tsc
            // (verified against the oracle for named, default and
            // namespace type-only imports). Without this the query
            // degraded to `any` and erased everything built on it — every
            // member of an `InstanceType<typeof App>["…"]` API surface.
            const wf = c.symFlags(sym);
            if (wf.import_binding and wf.type_only)
                return c.regularizeTypeQuery(try c.typeOfSymbol(sym));
            return types.any_type;
        },
        .none => {
            // `typeof globalThis` — always in scope (see checkIdentifier).
            if (std.mem.eql(u8, c.atomText(a), "globalThis")) return c.globalThisType();
            try c.reportNameNotFound(tok);
            return types.error_type;
        },
    }
}

pub const TypeParamInfo = struct {
    sym: SymbolId,
    constraint: Node,
    default: Node,
};

/// Type parameters of a generic symbol (class/interface/alias). Symbol ids
/// in the result are global.
///
/// A reopened or cross-file-merged interface may declare its type
/// parameters on any one of its blocks: tsc collects the parameter list
/// across *every* declaration, and a block that omits the list entirely is
/// legal whenever each parameter has a default (`areTypeParametersIdentical`
/// compares against the *minimum* argument count). `@types/node` relies on
/// exactly that — `interface Buffer<TArrayBuffer extends ArrayBufferLike =
/// ArrayBufferLike> extends Uint8Array<TArrayBuffer>` in one file, a bare
/// `interface Buffer { … }` reopen in another. So scan the constituents in
/// declaration order and take the first block that actually declares
/// parameters; a bare reopen must not erase them.
pub fn typeParamsOf(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    outer: for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            try c.declTypeParams(decl, buf);
            if (buf.items.len > 0) break :outer;
        }
    }
    if (buf.items.len > 0 and c.symFlags(sym).class) try c.canonicalizeClassTypeParams(sym, buf);
}

/// A class merged with a same-named `interface` has TWO declaring blocks,
/// each binding its own type-parameter symbols; tsc unifies them by POSITION
/// (`interface P<A> { x: A }` beside `class P<A> { y: A }` — `P<number>`
/// types both members `number`). `buildInstMap` already substitutes every
/// block's i-th parameter, so an instantiation with real arguments is fine
/// either way; what is not fine is the SELF reference — the class's own
/// `this` instance `P<A>`, whose arguments are these symbols. The
/// `implements`/`extends` clauses written on the class body resolve their
/// `A` in the CLASS's scope, so unless the self reference uses the class
/// block's symbols too, `class P<A> implements R<A>` compares `R<class A>`
/// against an instance whose every member reads `R<interface A>` and fails
/// (drizzle's `PgRaw`, `SQLiteRaw` and `Column`, whose interface halves are
/// written first).
///
/// Only the SYMBOLS are canonicalized. Arity, constraints and defaults stay
/// with the first declaring block, which is what tsc's declared type keeps:
/// `@types/react` writes `interface Component<P = {}, S = {}, SS = any>`
/// beside `class Component<P, S>`, and `Component<any>` is legal there only
/// because the three defaulted parameters win.
pub fn canonicalizeClassTypeParams(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            var syms: std.ArrayList(SymbolId) = .empty;
            defer syms.deinit(c.scratch());
            try c.typeParamSymsOfDecl(decl, &syms);
            if (syms.items.len == 0) return;
            for (syms.items, 0..) |s, i| {
                if (i >= buf.items.len) break;
                buf.items[i].sym = s;
            }
            return;
        }
    }
}

/// Type parameters declared by ONE declaration node, appended to `buf`,
/// resolved in the current file context. Non-generic (or non-declaring)
/// nodes append nothing.
pub fn declTypeParams(c: *Checker, decl: Node, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    const d = c.tree.nodeData(decl);
    var tp_start: u32 = 0;
    var tp_end: u32 = 0;
    switch (c.nodeTag(decl)) {
        .class_decl => {
            const data = c.tree.extraData(ast.ClassData, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        .interface_decl => {
            const data = c.tree.extraData(ast.InterfaceData, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        .type_alias => {
            const data = c.tree.extraData(ast.TypeAlias, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        else => return,
    }
    // Non-generic declaration: bail before `scopeOf`, which is the
    // expensive half and is pure overhead for the common case.
    if (tp_start == tp_end) return;
    const decl_scope = (try c.scopeOf(decl)) orelse return;
    for (c.tree.extraRange(tp_start, tp_end)) |tp| {
        if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
        const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
        const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
        const td = c.tree.nodeData(tp);
        try buf.append(c.scratch(), .{ .sym = c.toGlobal(tp_sym), .constraint = td.lhs, .default = td.rhs });
    }
}

/// Type-parameter symbols of a single declaration node (class/interface/
/// alias), in positional order, resolved in the current file context.
/// Reopened interface blocks each bind a *distinct* type-param symbol for
/// the same positional name, so an instantiation must map all of them (see
/// `buildInstMap`).
pub fn typeParamSymsOfDecl(c: *Checker, decl: Node, buf: *std.ArrayList(SymbolId)) Error!void {
    const d = c.tree.nodeData(decl);
    var tp_start: u32 = 0;
    var tp_end: u32 = 0;
    switch (c.nodeTag(decl)) {
        .class_decl => {
            const data = c.tree.extraData(ast.ClassData, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        .interface_decl => {
            const data = c.tree.extraData(ast.InterfaceData, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        .type_alias => {
            const data = c.tree.extraData(ast.TypeAlias, d.lhs);
            tp_start = data.tp_start;
            tp_end = data.tp_end;
        },
        else => return,
    }
    const decl_scope = (try c.scopeOf(decl)) orelse return;
    for (c.tree.extraRange(tp_start, tp_end)) |tp| {
        if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
        const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
        const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
        try buf.append(c.scratch(), c.toGlobal(tp_sym));
    }
}

/// Build the type-parameter → argument substitution map for instantiating
/// generic `sym` with `args`. A reopened interface (or a cross-file merged
/// interface) binds a distinct type-param symbol per declaration
/// block, but tsc unifies them by position — so every block's i-th
/// type-param symbol maps to `args[i]`. Missing args fall back to `any`.
pub fn buildInstMap(c: *Checker, sym: SymbolId, args: []const TypeId, out: *std.ArrayList(TpMap)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            var syms: std.ArrayList(SymbolId) = .empty;
            defer syms.deinit(c.scratch());
            try c.typeParamSymsOfDecl(decl, &syms);
            for (syms.items, 0..) |tp_sym, i| {
                const ty = if (i < args.len) args[i] else types.any_type;
                try out.append(c.scratch(), .{ .sym = tp_sym, .ty = ty });
            }
        }
    }
}

/// Does `sym` declare any type parameter with an `extends` clause? Memoized:
/// the answer is a property of the declaration, asked once per written type
/// reference, and `typeParamsOf` walks every declaration block to answer it.
pub fn symHasConstrainedTypeParam(c: *Checker, sym: SymbolId) Error!bool {
    if (c.tp_constrained_cache.get(sym)) |v| return v;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    var any = false;
    for (tps.items) |tp| {
        if (tp.constraint != 0) any = true;
    }
    try c.tp_constrained_cache.put(c.cm(), sym, any);
    return any;
}

/// Queue a written type-argument list for its TS2344 constraint check (see
/// `PendingTypeArgs` for why the check may not run here).
///
/// Only references in a file this checker OWNS are queued: a diagnostic for
/// any other file is discarded at `seal`, and the checker that owns it queues
/// the same reference itself. Each (file, node) is queued once.
///
/// `args` is the caller's resolved argument list, holes skipped — the same
/// pairing the drain rebuilds against `writtenTypeArgNodes(node)`, which is
/// read here rather than passed in so queue and drain cannot drift apart.
pub fn queueTypeArgConstraints(c: *Checker, node: Node, sym: SymbolId, args: []const TypeId) Error!void {
    // `args` holds one entry per non-hole argument node, so an empty `args`
    // is exactly the old "no arguments, or none written" test.
    if (args.len == 0) return;
    if (c.cur_file >= c.owned_mask.len or !c.owned_mask[c.cur_file]) return;
    const f = c.symFlags(sym);
    if (!f.interface and !f.class and !f.type_alias) return;
    const gop = try c.pending_type_args_seen.getOrPut(c.cm(), c.nodeKey(node));
    if (gop.found_existing) return;
    // Nothing to decide, nothing to keep: most generics constrain no
    // parameter at all (`Array<T>`, `Promise<T>`, every one-off `Wrap<T>`),
    // and queueing those would hold an entry and its arguments for the rest
    // of the run for a drain that would immediately skip them.
    if (!try c.symHasConstrainedTypeParam(sym)) return;
    // Nor is anything to decide when no WRITTEN argument is a decided set:
    // `undecidableType` is a pure function of the argument's `TypeId`, so its
    // answer at the drain is the answer here, and a reference all of whose
    // arguments are still type variables or deferred nodes (zod's
    // `DeepPartial<T["shape"][k]>`, every `Foo<infer X>`) would only be
    // skipped later — after being kept alive for the whole run.
    const arg_nodes = writtenTypeArgNodes(c, node);
    {
        var any_decidable = false;
        for (args[0..@min(args.len, arg_nodes.len)], 0..) |a, i| {
            if (arg_nodes[i] == null_node) continue;
            if (a == types.any_type or a == types.unknown_type) continue;
            if (try c.undecidableType(a)) continue;
            any_decidable = true;
            break;
        }
        if (!any_decidable) return;
    }
    const args_start: u32 = @intCast(c.pending_type_args_pool.items.len);
    try c.pending_type_args_pool.appendSlice(c.cm(), args);
    try c.pending_type_args.append(c.cm(), .{
        .file = c.cur_file,
        .node = node,
        .sym = sym,
        .this_type = c.this_type,
        .args_start = args_start,
        .args_len = @intCast(args.len),
    });
}

/// The WRITTEN type-argument nodes of a `type_ref`, straight out of the tree.
/// Immutable program data for the life of the program, so the TS2344 queue
/// keeps the reference node instead of a copy of this list.
fn writtenTypeArgNodes(c: *const Checker, node: Node) []const Node {
    const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(node).rhs);
    return c.tree.extraRange(r.start, r.end);
}

/// Run every queued TS2344 constraint check. Called once, after every
/// statement of every owned file has been checked, so no class member table
/// is still materializing.
pub fn drainTypeArgConstraints(c: *Checker) Error!void {
    const saved_file = c.cur_file;
    const saved_scope = c.cur_scope;
    const saved_this = c.this_type;
    defer {
        c.setFile(saved_file);
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
    }
    // Index-walked, and the entry's arguments are copied out before the check
    // runs: a check can convert a type node that queues a further reference,
    // which both appends to `pending_type_args` (walked by index for exactly
    // that reason) and can grow — and so move — the argument pool. One reused
    // scratch buffer, never longer than the widest written argument list.
    var args: std.ArrayList(TypeId) = .empty;
    defer args.deinit(c.scratch());
    var i: usize = 0;
    while (i < c.pending_type_args.items.len) : (i += 1) {
        const p = c.pending_type_args.items[i];
        c.setFile(p.file);
        c.cur_scope = binder.file_scope;
        c.this_type = p.this_type;
        const arg_nodes = writtenTypeArgNodes(c, p.node);
        args.clearRetainingCapacity();
        try args.appendSlice(c.scratch(), c.pending_type_args_pool.items[p.args_start..][0..p.args_len]);
        // Each queued reference is its own source element, exactly as it was
        // when the enclosing statement was walked: the instantiation budget
        // is scoped to one (tsc resets `instantiationCount` per
        // `checkSourceElement`), and the TS2589 anchor is this reference.
        // Without the reset the whole drain is one statement and the budget
        // trips on the accumulated total of every reference in the program.
        for (arg_nodes) |an| {
            if (an != null_node) {
                c.anchorInst(an);
                break;
            }
        }
        c.inst_count = 0;
        try c.checkTypeArgConstraints(p.sym, args.items, arg_nodes);
    }
    c.pending_type_args.clearRetainingCapacity();
    c.pending_type_args_pool.clearRetainingCapacity();
}

/// TS2344 — every WRITTEN type argument of a type reference must satisfy its
/// type parameter's constraint (tsc's `checkTypeArgumentConstraints`).
///
/// The constraint is instantiated under the reference's OWN argument list, so
/// a constraint that mentions an earlier parameter is checked in the supplied
/// world: drizzle writes `MySqlSelectWithout<T, TDynamic, K extends keyof T &
/// string>`, and `K`'s constraint only means anything once `T` is the class's
/// polymorphic `this`.
///
/// Deliberately silent — this is a *negative* check whose whole cost is false
/// positives — whenever the verdict would be about ztsc's own resolution
/// rather than the code:
///
///   * a parameter with no WRITTEN argument — a defaulted tail, or a list
///     whose arity is already another check's diagnostic (TS2314/TS2707) and
///     whose positions therefore pair with the wrong parameters,
///   * `any` / `unknown` on either side, which admit everything,
///   * an argument that is not a decided set (`undecidableType`), or
///   * a constraint that is not a decided set (`decidableConstraintSet`).
///
/// The check runs once per written reference per checker (the queue dedupes
/// on `nodeKey`), so a generic used a thousand times is judged at each of its
/// use sites exactly once, and never at its declaration.
pub fn checkTypeArgConstraints(c: *Checker, sym: SymbolId, args: []const TypeId, arg_nodes: []const Node) Error!void {
    if (args.len == 0) return;
    const f = c.symFlags(sym);
    if (!f.interface and !f.class and !f.type_alias) return;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) return;
    // Arity is another check's business (TS2314/TS2707); a mismatched list
    // pairs arguments with the wrong parameters, so say nothing.
    if (args.len > tps.items.len) return;
    var min: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (args.len < min) return;
    // The mapper tsc builds: every parameter to its supplied argument, with
    // defaulted tail parameters left as themselves (their own instantiation
    // is `fixTypeArgs`'s job, and a constraint that leans on one is not
    // decidable here).
    var map_list: std.ArrayList(TpMap) = .empty;
    defer map_list.deinit(c.scratch());
    try c.buildInstMap(sym, args, &map_list);
    for (tps.items, 0..) |tp, i| {
        if (i >= args.len or i >= arg_nodes.len) break;
        if (tp.constraint == 0) continue;
        const an = arg_nodes[i];
        if (an == null_node) continue;
        const arg = args[i];
        if (arg == types.any_type or arg == types.unknown_type) continue;
        if (try c.undecidableType(arg)) continue;
        var con: TypeId = undefined;
        {
            const saved = c.enterSymFile(tp.sym);
            defer c.restoreCtx(saved);
            c.cur_scope = c.symScope(tp.sym);
            con = try c.typeFromTypeNode(tp.constraint);
        }
        con = try c.instantiate(con, map_list.items);
        if (!try c.decidableConstraintSet(con)) continue;
        if (try c.isAssignable(arg, con)) continue;
        // tsc replaces the "does not satisfy" head with the specific
        // missing-property error whenever that is what went wrong
        // (`reportRelationError` → `getExactOptionalUnassignableProperties`
        // path): `Holder<{ s: string }>` against `T extends Shape` is
        // TS2741, not TS2344.
        if (try c.tryReportMissingProps(arg, con, c.nodeSpan(an))) continue;
        // A constraint violation elaborates like any other failed relation
        // (`elaborate.zig`): the argument and the constraint are the pair, and
        // tsc chains the same derivation under this head as under TS2322.
        try c.diagFmt(2344, c.nodeSpan(an), "Type '{s}' does not satisfy the constraint '{s}'.{s}", .{
            try c.typeToString(arg),
            try c.typeToString(con),
            try elaborate.chainText(c, arg, con),
        });
    }
}

/// Budget for the TS2344 gates' structural scans. Running out answers
/// "undecidable", which for a negative check is always the safe direction.
pub const constraint_scan_budget: u32 = 512;

/// May a "does not satisfy" verdict be built against `con` as a TARGET?
///
/// Two shapes qualify.
///
/// A PRIMITIVE OR LITERAL SET — a primitive, a literal, an enum member,
/// `never`, or a union/intersection of those. That is what TS2344 is
/// overwhelmingly about (`K extends keyof T & string`, `K extends "a" | "b"`,
/// `N extends number`), and it is the shape ztsc decides *exactly*: membership
/// in a key set is a set question, not a structural one.
///
/// A STRUCTURAL constraint — an object type, or a reference to an
/// interface/class/alias (`T extends Shape`, `T extends ZodType<any, any,
/// any>`) — which is decided by the relation. That used to be excluded on the
/// argument that "the answer is only as good as the relation", with zod's
/// `ZodNumber` against `ZodType<any, any, any>` as the standing counter-
/// example. Both halves of that example are now fixed and pinned: the variance
/// half by `measuredVarianceVerdict` (`assignability/078`), and the
/// growing-instantiation half — `ZodString` against `ZodType<string | number |
/// symbol, any, any>`, where the walk burnt the whole per-statement
/// instantiation budget and the truncation came back as a cached FALSE — by
/// the relation's deeply-nested guard (`max_relation_identity_repeats`,
/// `assignability/080`). With those closed, `bench/parity_sweep.sh` holds
/// 0 under / 0 excess on all eight packages with the structural arm ENABLED,
/// which is the evidence this gate was waiting for.
///
/// What stays out is anything still DEFERRED — a free type parameter, a
/// conditional, a `keyof`, an indexed access, a mapped type, a template
/// pattern. Those are not sets ztsc can enumerate on either side of the
/// relation, and they are what the caller's `undecidableType` guard is about.
///
/// The structural arm is not free: it is one full relation per written
/// reference, and on declaration corpora that write many nominal constraints
/// against large lib interfaces (`T extends HTMLElement` appears 119 times in
/// @types/react) it was the dominant new cost — that package's check phase
/// 10.3 → 21.0 ms when the arm landed. Most of it is back: the relation now
/// answers a derived type against a DECLARED base of itself without walking
/// members at all (`nominalHeritageRelated`), which took @types/react to
/// 11.1 ms and its peak RSS 24.3 → 22.1 MB. What is left is the constraints
/// the fast path cannot settle nominally — zod's `ZodString` against
/// `ZodType<string | number | symbol, any, any>`, a base instantiation whose
/// arguments neither match nor are `any`, which is a real structural
/// question and stays one (10.8 → 10.5 ms). Everything else was flat
/// throughout: e2e `multi` 0.03 s / 41 MB and excalidraw 0.20 s / 122 MB,
/// because an application writes far fewer such references than a `.d.ts`
/// package does.
pub fn decidableConstraintSet(c: *Checker, con: TypeId) Error!bool {
    const s = &c.ts;
    var budget: u32 = constraint_scan_budget;
    var stack: std.ArrayList(TypeId) = .empty;
    defer stack.deinit(c.scratch());
    try stack.append(c.scratch(), con);
    while (stack.pop()) |cur| {
        if (budget == 0) return false;
        budget -= 1;
        switch (s.kind(cur)) {
            // Structural: decided by the relation. `undecidableType` has
            // already refused anything still deferred inside it.
            .object, .ref => if (try c.undecidableType(cur)) return false,
            .string,
            .number,
            .boolean,
            .bigint,
            .symbol,
            .object_keyword,
            .never,
            .null,
            .undefined,
            .void,
            .bool_true,
            .bool_false,
            .string_literal,
            .number_literal,
            .number_literal_fresh,
            .bigint_literal,
            .enum_type,
            .unique_symbol,
            => {},
            .union_type, .intersection => {
                for (0..s.memberCount(cur)) |i| try stack.append(c.scratch(), s.memberAt(cur, i));
            },
            else => return false,
        }
    }
    return true;
}

/// May a "does not satisfy" verdict be built on `t`?
///
/// No, whenever `t` still contains a type variable or a DEFERRED node — a
/// free type parameter, an `infer` binder, a mapped key, an unreduced
/// conditional / indexed access / `keyof` / template pattern / string
/// intrinsic. Such a type is not a set ztsc can enumerate: tsc decides those
/// through the constraint machinery of a full deferred relation, ztsc does
/// not, and every one of the 130+ false TS2344s the naive check invented on
/// the corpus was one of these (`infer Type`, `T["shape"][k]`,
/// `DeepPartial<…>` against `ZodType<any, any, any>`).
///
/// An object's own property types count: drizzle writes a type argument
/// `{ tableName: infer TTableName }` inside a conditional's `extends` clause,
/// and the members of a set whose contents are still being inferred are not a
/// decided set either. A `.ref` is followed through its ARGUMENTS only —
/// expanding it to look inside a class instance would report on the type
/// parameters every generic class mentions in its own members.
pub fn undecidableType(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    var budget: u32 = constraint_scan_budget;
    var seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer seen.deinit(c.scratch());
    var stack: std.ArrayList(TypeId) = .empty;
    defer stack.deinit(c.scratch());
    try stack.append(c.scratch(), t);
    while (stack.pop()) |cur| {
        if (budget == 0) return true;
        budget -= 1;
        if ((try seen.getOrPut(c.scratch(), cur)).found_existing) continue;
        switch (s.kind(cur)) {
            .err,
            .type_param,
            .infer_var,
            .mapped_param,
            .conditional,
            .index_access,
            .keyof_op,
            .mapped,
            .template_literal_type,
            .string_mapping,
            => return true,
            // Indexed walks, not `memberList` dupes: interning during the
            // scan may move `extra` (see `Store.memberAt`).
            .union_type, .intersection, .overloads => {
                for (0..s.memberCount(cur)) |i| try stack.append(c.scratch(), s.memberAt(cur, i));
            },
            .array => try stack.append(c.scratch(), s.arrayElem(cur)),
            .tuple => for (0..s.tupleLen(cur)) |i| {
                try stack.append(c.scratch(), s.tupleElem(cur, @intCast(i)).ty);
            },
            .ref => for (0..s.refArgCount(cur)) |i| {
                try stack.append(c.scratch(), s.refArgAt(cur, i));
            },
            .object => {
                for (0..s.objectPropCount(cur)) |i| {
                    try stack.append(c.scratch(), s.objectProp(cur, @intCast(i)).ty);
                }
                if (s.objectStringIndex(cur) != 0) try stack.append(c.scratch(), s.objectStringIndex(cur));
                if (s.objectNumberIndex(cur) != 0) try stack.append(c.scratch(), s.objectNumberIndex(cur));
            },
            else => {},
        }
    }
    return false;
}

/// Check type-argument arity against a generic symbol and fill defaults.
/// Returns null (after TS2314/2558) on arity mismatch.
pub fn fixTypeArgs(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!?[]const TypeId {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (args.len == tps.items.len) return try c.scratch().dupe(TypeId, args);
    var min: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (args.len < min or args.len > tps.items.len) {
        if (tps.items.len == 0) {
            // Non-generic type applied to type args. Report TS2315 (as tsc
            // does) but degrade to the base type rather than dropping it,
            // so a `X extends NonGeneric<T>` base keeps its inherited
            // members instead of stripping them all. (Historically this
            // bridged @types/node's generic `Buffer<T> extends
            // Uint8Array<T>` onto the 5.5.4 lib's non-generic
            // `Uint8Array`; the TS 7.0.2 lib is generic, so that skew is
            // gone, but the degradation stays the right lenient default.)
            try c.diagFmt(2315, c.tokSpan(tok), "Type '{s}' is not generic.", .{c.symbolName(sym)});
            return try c.scratch().dupe(TypeId, &.{});
        }
        if (min == tps.items.len) {
            try c.diagFmt(2314, c.tokSpan(tok), "Generic type '{s}' requires {d} type argument(s).", .{ c.symbolName(sym), min });
        } else {
            // With defaults the valid arity is a range (tsc's TS2707).
            try c.diagFmt(2707, c.tokSpan(tok), "Generic type '{s}' requires between {d} and {d} type arguments.", .{ c.symbolName(sym), min, tps.items.len });
        }
        return null;
    }
    var out = try c.scratch().alloc(TypeId, tps.items.len);
    for (tps.items, 0..) |tp, i| {
        if (i < args.len) {
            out[i] = args[i];
        } else if (tp.default != 0) {
            // Defaults are nodes of the declaring file; evaluate there,
            // then substitute the already-resolved params so `B = A` sees
            // the supplied `A` (and `C = B` the defaulted `B`).
            // The file is the *type parameter's* — a merged interface may
            // declare its parameters on a block in a different file than
            // the merged symbol's representative, and reading the node
            // against the wrong tree is out of bounds.
            var def: TypeId = undefined;
            {
                const saved = c.enterSymFile(tp.sym);
                defer c.restoreCtx(saved);
                c.cur_scope = c.symScope(tp.sym);
                def = try c.typeFromTypeNode(tp.default);
            }
            // A *bare* default reference to an earlier own param (`Tr = T`)
            // whose alias is *self-recursive* is the recursion accumulator of
            // RHF's `PathInternal<T, TraversedTypes = T>`: its termination
            // guard `AnyIsEqual<Tr, V>` only fires once `Tr` is the concrete
            // form, so the default must resolve to that param's supplied
            // argument even for a library (`.d.ts`) generic. This is a single
            // symbol swap (no expansion), so it cannot reintroduce the
            // deep-generic OOM that gates `.d.ts` defaults. Scoping to
            // recursive aliases keeps non-recursive library defaults (e.g.
            // redux `Reducer<S, A, PreloadedState = S>`) on the pre-existing
            // unsubstituted path — substituting those would eagerly reduce
            // otherwise-deferred store machinery (`ExtractStoreExtensions`)
            // that only reduces cleanly once the infer-var/poison work lands.
            const bare_earlier: ?usize = if (c.ts.kind(def) == .type_param) blk: {
                const dsym = c.ts.typeParamSymbol(def);
                for (tps.items[0..i], 0..) |ptp, j| {
                    if (ptp.sym == dsym) break :blk j;
                }
                break :blk null;
            } else null;
            // A *ground* referenced argument (no type param anywhere) can
            // always be swapped in — this is a single symbol swap identical
            // to the function-call default path (`inferTypeArgs` fills an
            // uninferable default via `instantiate(def, resolved)`), so the
            // alias annotation `UseFormReturn<P>` fills its
            // `TTransformedValues = TFieldValues` default to the supplied `P`
            // exactly as `useForm<P>()`'s return does, keeping the two sides
            // structurally identical (reflexive assignability). A ground arg
            // cannot re-materialize deferred `.d.ts` machinery (the OOM guard
            // and the redux `ExtractStoreExtensions` unmask both require an
            // *abstract* arg), so those concerns below don't apply here.
            //
            // A referenced argument that is itself a *naked type parameter*
            // is the same single symbol swap: it renames one bound name to
            // another and expands nothing, so it can no more re-materialize
            // deferred `.d.ts` machinery than a ground argument can. Leaving
            // it unsubstituted is in fact unsound rather than lenient — the
            // alias body keeps a *free* occurrence of the alias's own `S`
            // that the caller's later instantiation can never close. RTK's
            // `interface Slice<State, …> { reducer: Reducer<State> }` over
            // redux's `Reducer<S, A, PreloadedState = S>` materialized as
            // `(state: State | S | undefined, …) => State`; substituting
            // `Slice<X>` then left the dangling `S` behind, and a merely
            // *generic* type poisons every conditional that tests it —
            // `combineReducers`' `M[keyof M] extends Reducer<…> | undefined`
            // never decided, so its result stayed an unreduced conditional
            // and `configureStore({ reducer: rootReducer })` was rejected.
            const swappable_earlier = bare_earlier != null and
                (!(try c.containsTypeParam(out[bare_earlier.?])) or
                    c.ts.kind(out[bare_earlier.?]) == .type_param);
            // Ensure the generic body is built so self-recursion is detected
            // (the flag is set when materialization re-enters this alias).
            const recursive = if (bare_earlier != null and !swappable_earlier and c.symInDeclFile(sym)) rec: {
                if ((c.alias_state.get(sym) orelse 0) != 1) _ = try c.aliasGeneric(sym);
                break :rec (c.alias_state.get(sym) orelse 0) == 1 or c.alias_recursive.contains(sym);
            } else true;
            if (bare_earlier != null and (swappable_earlier or recursive or !c.symInDeclFile(sym))) {
                out[i] = out[bare_earlier.?];
            } else if (c.symInDeclFile(sym)) {
                // A *complex* or non-recursive library default (e.g. RTK's
                // `ExtractStoreExtensionsFromEnhancerTuple` tuple default, or
                // `Reducer`'s `PreloadedState = S`) stays unsubstituted:
                // threading a concrete arg through it re-materializes
                // deeply-recursive `.d.ts` types (the historic OOM) or unmasks
                // a still-deferred reduction, so keep prior lenient behavior.
                out[i] = def;
            } else {
                // Substitute the already-resolved params into the default so
                // an earlier-param reference (`B = A`) sees the supplied `A`
                // (and `C = B` the defaulted `B`) for user generics.
                const pmap = try c.scratch().alloc(TpMap, i);
                for (tps.items[0..i], 0..) |ptp, j| pmap[j] = .{ .sym = ptp.sym, .ty = out[j] };
                out[i] = try c.instantiate(def, pmap);
            }
        } else {
            out[i] = types.any_type;
        }
    }
    return out;
}

/// keyof T for the resolved structural type (object-ish only; the v0.0.1
/// subset has non-generic keys).
pub fn keyofType(c: *Checker, t: TypeId) Error!TypeId {
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
        .any => return c.makeUnion2(types.string_type, c.makeUnion2(types.number_type, types.symbol_type) catch unreachable),
        .object => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..c.ts.objectPropCount(r)) |i| {
                const p = c.ts.objectProp(r, @intCast(i));
                try parts.append(c.scratch(), try c.ts.makeStringLiteral(p.name, false));
            }
            if (c.ts.objectStringIndex(r) != 0) {
                try parts.append(c.scratch(), types.string_type);
                try parts.append(c.scratch(), types.number_type);
            }
            if (c.ts.objectNumberIndex(r) != 0) try parts.append(c.scratch(), types.number_type);
            return c.ts.makeUnion(c.scratch(), parts.items);
        },
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
pub fn indexedAccessType(c: *Checker, obj: TypeId, idx: TypeId) Error!TypeId {
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
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..c.ts.tupleLen(r)) |i| {
                const e = c.ts.tupleElem(r, @intCast(i));
                const et = if (e.rest()) try c.elemOfArrayish(e.ty) else e.ty;
                try parts.append(c.scratch(), et);
            }
            return c.ts.makeUnion(c.scratch(), parts.items);
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
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(r)) |m| {
                const e = try c.elemOfArrayish(m);
                // One non-arrayish constituent leaves the whole position
                // untyped, exactly as the single-type path does.
                if (c.ts.kind(e) == .any) break :blk types.any_type;
                try parts.append(c.scratch(), e);
            }
            break :blk try c.ts.makeUnion(c.scratch(), parts.items);
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
/// assignable members (e.g. `any[]` vs `Item[]`) collapse to exactly one
/// (the first kept). tsc guard mirrored from `strictSubtypeRelation`: an
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
/// Order-invariant: members are already TypeId-sorted by `makeUnion`, and
/// the kept set is a deterministic function of that order.
pub fn reduceSubtypes(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return t;
    const members = try c.memberList(t);
    // Guard cost: `||`/`??` unions are tiny; skip pathological ones
    // (leaving the union untouched is always sound — never a new FP).
    if (members.len < 2 or members.len > 32) return t;
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
                // it here would keep both. Otherwise keep whichever of the
                // two was reached first.
                if (m_fresh) continue :outer;
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

/// Object type from interface/object-literal-type member nodes.
pub fn objectTypeFromMembers(c: *Checker, member_nodes: []const Node, obj_flags: u32) Error!TypeId {
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer prop_index.deinit(c.scratch());
    var sindex: TypeId = 0;
    var nindex: TypeId = 0;
    // Method overload grouping: name -> sig list.
    var methods: std.AutoHashMapUnmanaged(Atom, std.ArrayList(TypeId)) = .empty;
    defer {
        var it = methods.valueIterator();
        while (it.next()) |l| l.deinit(c.scratch());
        methods.deinit(c.scratch());
    }
    var order: std.ArrayList(Atom) = .empty;
    defer order.deinit(c.scratch());
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
                if (key == types.number_type) nindex = val else sindex = val;
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
    return c.ts.makeObjectSigs(props.items, sindex, nindex, obj_flags, call_sigs.items, construct_sigs.items);
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
            for (members) |m| {
                const rm = try c.resolveStructural(m);
                switch (c.ts.kind(rm)) {
                    .object, .intersection => {
                        var mprops: std.ArrayList(types.Prop) = .empty;
                        var mindex: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
                        defer mindex.deinit(c.scratch());
                        // A union member's index signatures are not carried
                        // into the fold (they were not before this arm
                        // recursed either); a throwaway sink keeps the
                        // recursive gather's contract.
                        var sink_s: std.ArrayList(TypeId) = .empty;
                        defer sink_s.deinit(c.scratch());
                        var sink_n: std.ArrayList(TypeId) = .empty;
                        defer sink_n.deinit(c.scratch());
                        try c.gatherSpreadProps(rm, &mprops, &mindex, &sink_s, &sink_n);
                        try objs.append(c.scratch(), mprops.items);
                    },
                    .null, .undefined, .void => has_empty = true,
                    else => return,
                }
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
