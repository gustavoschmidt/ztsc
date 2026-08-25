//! Type-space name resolution: what a NAME means in type position.
//!
//! A bare or qualified type reference (`T`, `A.B.T`), an `import("m").T`, a
//! `typeof x` query — each starts as syntax and has to reach a declaration
//! symbol before it can become a `TypeId`, and the walk in between is the one
//! part of type-node conversion that talks to the linker (`link/modules.zig`):
//! namespace bodies, module export tables, `export =` assignments, `declare
//! module` augmentations and import aliases are all followed here.
//!
//! Turning the symbol it lands on into a type is two functions
//! (`materializeTypeRef` for a bare name, `namedTypeFromSymbol` for a
//! qualified one); everything else in this file is resolution.
//!
//! typenode.zig re-exports this file's public surface, so `checker.zig`'s
//! method aliases and other modules' direct imports keep resolving there.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const modules = @import("../link/modules.zig");

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

const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const modvalue = @import("modvalue.zig");
const static_tp_scope = @import("static_tp_scope.zig");
const typeparams = @import("typeparams.zig");
const indexOfAtom = @import("generics.zig").indexOfAtom;
const intrinsicStringMapping = @import("generics.zig").intrinsicStringMapping;
const stripQuotes = Checker.stripQuotes;

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
            if (f.import_binding) import_blk: {
                const tgt0 = c.importTarget(sym) orelse {
                    // No import RECORD means the ENTITY-NAME form, `import
                    // modes = _modes` — nothing for the linker to resolve, so
                    // the right-hand side is walked here. An alias to a
                    // NAMESPACE has the namespace's meanings, and tsc's
                    // `SymbolFlags.Type` excludes them: naming it as a type is
                    // the same TS2709 the namespace's own name earns. A merged
                    // namespace that also declares a type is a type, and every
                    // other target stays the lenient `any` it was.
                    if (try c.importEqualsEntityContainer(sym)) |cont| {
                        switch (cont) {
                            .ns => |ns| if (!hasTypeMeaning(nonNsFlags(c.symFlags(ns)))) {
                                try c.diagFmt(2709, c.tokSpan(tok), "Cannot use namespace '{s}' as a type.", .{c.atomText(a)});
                                return types.error_type;
                            },
                            .module => {},
                        }
                    }
                    return types.any_type;
                };
                // A dual binding's TYPE half is the member of the exported
                // entity; its value half is a property and has none.
                const tgt = c.typeMeaningTarget(tgt0);
                switch (tgt.kind) {
                    .binding => {
                        const g = c.toGlobalIn(tgt.file, tgt.payload);
                        // Route through the cross-file merge index so an
                        // imported interface augmented by a `declare module`
                        // in another file resolves to the folded interface
                        // (cross-file augmentation).
                        sym = c.prog.mergedOf(g) orelse g;
                        f = c.symFlags(sym);
                        // The target may itself be an alias: a re-export of an
                        // import, or an import MERGED with a local value
                        // declaration (`import { A } from "./a"; const A = 0;
                        // export { A }` — a value export whose TYPE meaning is
                        // still the import's). tsc's `resolveAlias` keeps
                        // walking in exactly that case, and stops as soon as
                        // the symbol declares a type of its own.
                        if (f.import_binding and !declaresType(f)) {
                            const next = aliasDeclSym(c, sym);
                            if (next != sym) {
                                sym = next;
                                f = c.symFlags(sym);
                            }
                        }
                        if (!hasTypeMeaning(f) or (f.import_binding and !declaresType(f))) {
                            if (hasValueMeaning(f)) {
                                try c.diagFmt(2749, c.tokSpan(tok), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ c.tokenText(tok), c.tokenText(tok) });
                                return types.error_type;
                            }
                            return types.any_type;
                        }
                    },
                    // A whole MODULE namespace object named as a type is the
                    // same TS2709 `materializeTypeRef` reports for a
                    // `namespace` block: tsc's `SymbolFlags.Type` excludes
                    // both. `import WinJS = require("./m"); (w: WinJS) => {}`.
                    //
                    // Both ways a name can carry a SECOND, type meaning that
                    // the import half does not are handled rather than
                    // suppressed: `export type Drink = 0|1; export * as Drink
                    // from "./c"` is one `.dual` export-table entry, so
                    // `typeMeaningTarget` above already unwrapped it to the
                    // alias and never reaches here; and a LOCAL merge (`import
                    // * as B from "./b"` beside `interface B`) leaves the type
                    // declaration's own flag on the merged symbol, so the walk
                    // resumes at the ordinary materialization below.
                    .namespace => {
                        if (f.interface or f.class or f.type_alias or f.enum_decl) break :import_blk;
                        try c.diagFmt(2709, c.tokSpan(tok), "Cannot use namespace '{s}' as a type.", .{c.atomText(a)});
                        return types.error_type;
                    },
                    // A property of an `export =` value (value space only) /
                    // an ambient module's namespace object / unresolved: any.
                    .default_expr, .ambient_ns, .export_equals_prop, .dual, .any => return types.any_type,
                }
            }
            // TS2302: a class's type parameters do not reach its static
            // members. Reported here rather than at the declaration because
            // tsc's is a RESOLUTION failure — the name is answered with
            // nothing, so the reference is `error` and earns no cascade.
            // (wave-8 D: one flagged call into `static_tp_scope.zig`.)
            if (static_tp_scope.refFromStaticMember(c, sym, tok)) {
                try c.diagFmt(2302, c.tokSpan(tok), "Static members cannot reference class type parameters.", .{});
                return types.error_type;
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

/// `NoInfer<T>` — `T`, in a position inference must not read.
///
/// tsc represents it as a substitution type over `T` whose constraint is
/// `unknown`; the only thing that reads the marker is `inferFromTypes`, which
/// adds no candidate from one. ztsc has no substitution kind, so the wrapper is
/// the shape the ecosystem used before the intrinsic existed and which ztsc's
/// inference already declines: `[T][T extends any ? 0 : never]`, whose index is
/// a conditional over `T` and therefore deferred exactly as long as `T` is. Both
/// halves collapse the moment `T` is substituted — the conditional to `0`, the
/// access to element 0 — so the relation, `typeToString` and every message read
/// plain `T`, never the wrapper. msw ships the same trick by hand
/// (`type NoInfer<T> = [T][T extends any ? 0 : never]`, with a comment saying
/// why), which is what pins the encoding.
///
/// A type inference could not land on anyway (tsc's `isNoInferTargetType`) is
/// returned unwrapped: `NoInfer<string>` is `string`, and deferring an access
/// that resolves straight back to it would only cost.
fn noInferWrapper(c: *Checker, t: TypeId) Error!TypeId {
    if (!try c.containsFreeTypeParam(t, &.{})) return t;
    const idx = try c.ts.makeConditional(
        t,
        types.any_type,
        try c.ts.makeNumberLiteral(0, false),
        types.never_type,
        c.ts.kind(t) == .type_param,
    );
    return c.reduceIndexedAccess(try c.ts.makeTuple(&.{.{ .ty = t, .flags = 0 }}), idx);
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
            // `type NoInfer<T> = intrinsic` (lib.esnext.0.d.ts). tsc wraps the
            // argument in a SUBSTITUTION type whose constraint is `unknown`
            // (`getNoInferType`), which is `T` for every purpose except that
            // `inferFromTypes` adds no candidate from it. ztsc has no
            // substitution kind, so the wrapper is the shape the ecosystem used
            // before the intrinsic existed and which ztsc already blocks
            // inference through — `[T][T extends any ? 0 : never]`, a deferred
            // indexed access whose index never resolves while `T` is generic.
            // It reduces to exactly `T` the moment `T` is substituted, so the
            // relation and every message read `T` and not the wrapper.
            if (std.mem.eql(u8, c.atomText(a), "NoInfer") and c.aliasBodyIsIntrinsic(sym)) {
                return noInferWrapper(c, args[0]);
            }
        }
        // `type BuiltinIteratorReturn = intrinsic` (lib.esnext.1.d.ts) — the
        // `TReturn` every built-in iterator declares. `undefined` under
        // `strictBuiltinIteratorReturn`, which `strict` implies and ztsc runs
        // no other mode: `new Set([1]).values().next().value` is
        // `number | undefined`, not `any`.
        if (args.len == 0 and std.mem.eql(u8, c.atomText(a), "BuiltinIteratorReturn") and
            c.aliasBodyIsIntrinsic(sym))
        {
            return types.undefined_type;
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
    // TS2709. tsc's `SymbolFlags.Type` is `Class | Interface | Enum |
    // EnumMember | TypeLiteral | TypeParameter | TypeAlias` — NAMESPACE is not
    // in it — so `getTypeFromTypeReference` never lands on a namespace and the
    // reference answers "Cannot use namespace 'A' as a type." ztsc's
    // `hasTypeMeaning` DOES admit `namespace_decl`, because a qualified
    // `A.B.T` has to walk through `A`; the exclusion belongs here, where the
    // walk is over and the namespace itself is what the type node named.
    //
    // Every arm above has already claimed the merged shapes, so reaching here
    // with the flag set means nothing else in the merge carries a type: a bare
    // `namespace A {}`, and a `function f() {} namespace f {}` pair, both
    // report, while `enum E {} namespace E {}` and `class K {} namespace K {}`
    // do not. All four oracle-verified against tsgo 7.0.2.
    if (f.namespace_decl) {
        try c.diagFmt(2709, c.tokSpan(tok), "Cannot use namespace '{s}' as a type.", .{c.atomText(a)});
        return types.error_type;
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
        if (c.prog.mergedSym(ns_sym).members.lookup(name)) |m| return m;
        for (c.prog.mergedSym(ns_sym).parts) |p| {
            if (nsReexportMemberSym(c, p, name)) |g| return g;
        }
        return null;
    }
    const nb = c.symBind(ns_sym);
    const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return null;
    const local = nb.lookupInScope(ns, name) orelse
        return nsReexportMemberSym(c, ns_sym, name);
    // Route through the cross-file merge index, like `targetTypeSym`: a
    // member of an `export = <namespace>` module reached as `ns.I` may be
    // the real half of a `declare module` augmentation merge, and the
    // file-local declaration alone carries none of the augmented members.
    const g = c.toGlobalIn(c.symFile(ns_sym), local);
    return c.prog.mergedOf(g) orelse g;
}

/// The member a namespace body publishes with `export { X }` / `export { X as
/// name }`, or null.
///
/// tsc reads such a specifier as an export OF THE NAMESPACE, in every meaning
/// the aliased entity has: `namespace N { export { X }; }` makes `N.X` name
/// whatever `X` names, as a type and as a value. ztsc's binder does not
/// *declare* the exported name in the body scope — it records the specifier as
/// an `.ns_named` export record (see `bindExportNamed`, which keeps namespace
/// re-exports out of the module export table) — so `lookupInScope` above cannot
/// see it and the whole qualified name degraded to `any` (value position) or
/// TS2694 (type position).
///
/// expo's `expo-modules-core` is written this way: `global.d.ts` imports
/// `EventEmitter`/`SharedObject` and re-exports them into `declare namespace
/// ExpoGlobal { export { EventEmitter }; export { SharedObject }; }`, which the
/// package's public surface then names as `typeof ExpoGlobal.SharedObject`.
/// With the member unresolved, `class VideoPlayer extends SharedObject<…>`
/// inherited nothing at all.
fn nsReexportMemberSym(c: *Checker, ns_sym: SymbolId, name: Atom) ?SymbolId {
    if (c.prog.isMergedId(ns_sym)) return null;
    const file = c.symFile(ns_sym);
    const nb = c.prog.files[file].bind;
    const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return null;
    for (nb.exports) |rec| {
        if (rec.kind != .ns_named or rec.scope != ns) continue;
        if (rec.exported != name or rec.sym == binder.no_symbol) continue;
        return aliasDeclSym(c, c.toGlobalIn(file, rec.sym));
    }
    return null;
}

/// Follow an import binding to the declaration it aliases, so a namespace
/// re-export of an *imported* name yields the class/interface/namespace symbol
/// its consumers can materialize rather than the local alias (which carries no
/// members of its own). Stops at the first non-`binding` target — a whole
/// module-namespace object has no single declaration symbol — and at a fixed
/// hop count, so a re-export cycle terminates.
/// Does the symbol declare a TYPE of its own — as opposed to borrowing one
/// through an alias? tsc's `SymbolFlags.Type` minus the alias bit; a namespace
/// is excluded on purpose (naming one as a type is TS2709, not a resolution).
fn declaresType(f: binder.SymbolFlags) bool {
    return f.class or f.interface or f.type_alias or f.type_param or f.enum_decl;
}

fn aliasDeclSym(c: *Checker, sym0: SymbolId) SymbolId {
    var sym = c.prog.mergedOf(sym0) orelse sym0;
    var hops: u8 = 0;
    while (c.symFlags(sym).import_binding and hops < 8) : (hops += 1) {
        const tgt = c.typeMeaningTarget(c.importTarget(sym) orelse return sym);
        if (tgt.kind != .binding) return sym;
        const g = c.toGlobalIn(tgt.file, tgt.payload);
        const next = c.prog.mergedOf(g) orelse g;
        if (next == sym) return sym;
        sym = next;
    }
    return sym;
}

/// Append one value property per `export { X as name }` in namespace `ns_sym`'s
/// body — the value-space half of `nsReexportMemberSym`, for the namespace
/// object type. Names already present in `props` (a real declaration in the
/// body scope) win, as they do in the declaration loop.
pub fn nsReexportProps(c: *Checker, ns_sym: SymbolId, props: *std.ArrayList(types.Prop)) Error!void {
    if (c.prog.isMergedId(ns_sym)) {
        for (c.prog.mergedSym(ns_sym).parts) |p| try nsReexportPropsIn(c, p, props);
        return;
    }
    try nsReexportPropsIn(c, ns_sym, props);
}

fn nsReexportPropsIn(c: *Checker, ns_sym: SymbolId, props: *std.ArrayList(types.Prop)) Error!void {
    const file = c.symFile(ns_sym);
    const nb = c.prog.files[file].bind;
    const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return;
    for (nb.exports) |rec| {
        if (rec.kind != .ns_named or rec.scope != ns or rec.type_only) continue;
        if (rec.exported == 0 or rec.sym == binder.no_symbol) continue;
        const msym = c.toGlobalIn(file, rec.sym);
        const mf = c.symFlags(msym);
        if (!hasValueMeaning(mf)) continue;
        var dup = false;
        for (props.items) |p| {
            if (p.name == rec.exported) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        var flags: u32 = 0;
        if (mf.const_decl or mf.readonly_member) flags |= types.prop_flag_readonly;
        try props.append(c.scratch(), .{
            .name = rec.exported,
            // The alias symbol itself: `typeOfSymbol` follows an import
            // binding through the link, so the re-exported name gets the
            // same type a direct import of it would.
            .ty = try c.typeOfSymbol(msym),
            .flags = flags,
        });
    }
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
    // tsc's `getTypeFromImportTypeNode`: `if (!isLiteralImportTypeNode(node))
    // error(node.argument, String_literal_expected)`. Reported HERE and not in
    // the parser because it is a resolution-time error — an `import()` type
    // whose argument is not a string is silent until something asks for the
    // type (an unused `type A = import({x: 12})` reports nothing, measured).
    // (wave-34 D: one flagged crossing; the parser half is what makes the
    // argument reach this point at all.)
    if (c.tree.tokens.tag(spec_tok) != .string_literal) {
        if (report) {
            try c.diagFmt(1141, c.tokSpan(spec_tok), "String literal expected.", .{});
        }
        return null;
    }
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

/// The TYPE half of a link Target: a `.dual` binding (tsc's combined
/// value-and-type symbol) carries its type meaning in `type_tgt` — the member
/// of the export-assigned entity — while its `value_tgt` is a property of that
/// entity's type and has no type meaning at all. Every other kind is its own
/// type half. Unwraps nested duals (a dual re-exported through another
/// `export =` module), bounded.
pub fn typeMeaningTarget(c: *Checker, tgt: modules.Target) modules.Target {
    var t = tgt;
    var depth: u32 = 0;
    while (t.kind == .dual and depth < 8) : (depth += 1) {
        const d = c.prog.dual_targets[t.payload];
        const outer_type_only = t.type_only;
        t = d.type_tgt;
        t.type_only = t.type_only or outer_type_only;
    }
    return t;
}

/// The global symbol an export Target denotes (for type materialization),
/// or null for non-binding targets (namespace objects, default expressions).
pub fn targetTypeSym(c: *Checker, tgt0: modules.Target) ?SymbolId {
    const tgt = c.typeMeaningTarget(tgt0);
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

/// Does a namespace member name a TYPE? tsc's `SymbolFlags.Type` — `Class |
/// Interface | Enum | EnumMember | TypeLiteral | TypeParameter | TypeAlias` —
/// plus `Alias`, which stands for whatever it resolves to. `Namespace` is
/// deliberately absent, which is the same exclusion `materializeTypeRef`'s
/// TS2709 arm draws for a bare name: `namespace P { export namespace R { … } }`
/// with `var x: P.R` is "Namespace 'P' has no exported member 'R'".
fn memberNamesAType(f: binder.SymbolFlags) bool {
    return f.class or f.interface or f.type_alias or f.type_param or
        f.enum_decl or f.enum_member or f.import_binding;
}

/// Does a namespace member name a VALUE? A `namespace` block does only when it
/// is INSTANTIATED (tsc's `ValueModule` vs `NamespaceModule`): `namespace S {
/// export var y = 1 }` is a value, `namespace R { export interface I {} }` is
/// not. Both oracle-verified — the first is TS2749, the second TS2694.
///
/// The instantiation question is `modvalue.valuelessNamespace`, NOT the raw
/// `ns_uninstantiated` bit. The bit answers the binder's neighbouring question
/// ("does this block emit a runtime object"), which calls a const-enum-only
/// body and an exported-import body type-only where tsc's
/// `getModuleInstanceState` does not; and it is a per-part flag, so a merge
/// whose OR-ed flags say "uninstantiated" may still have one instantiated
/// block. Both discrepancies turn a correct TS2749 into a wrong TS2694, so the
/// one implementation of the rule is shared rather than re-spelled here.
fn memberNamesAValue(c: *const Checker, sym: SymbolId, f: binder.SymbolFlags) bool {
    if (f.var_decl or f.let_decl or f.const_decl or f.function or f.class or
        f.enum_decl or f.enum_member) return true;
    return f.namespace_decl and !modvalue.valuelessNamespace(c, sym);
}

/// Every EXPORTED member name declared in one namespace symbol's body scope.
/// The candidate pool for `namespaceMemberSuggestion`; the body scope's member
/// segment is atom-sorted and sealed, so this is a slice walk.
fn nsExportedNames(c: *Checker, ns_sym: SymbolId, out: *std.ArrayList(Atom)) Error!void {
    const nb = c.symBind(ns_sym);
    const ns = nb.namespaceScopeOf(c.localOf(ns_sym)) orelse return;
    const lo = nb.scope_members_start[ns];
    const hi = nb.scope_members_start[ns + 1];
    for (nb.member_atoms[lo..hi], nb.member_syms[lo..hi]) |a, s| {
        if (!nb.symbol_flags[s].exported) continue;
        try out.append(c.scratch(), a);
    }
}

/// tsc's `getSuggestedSymbolForNonexistentModule` for a NAMESPACE qualifier:
/// the exported member name closest to `name`, or 0 when none is close enough.
/// Turns the plain TS2694 into TS2724 ("'M' has no exported member named 'num'.
/// Did you mean 'nums'?"), which is the same refinement the linker already
/// applies to a missing named IMPORT — a namespace and a module answer a
/// qualified name the same way, so they must misspell it the same way too.
///
/// A cross-file merged namespace pools every constituent's exports, exactly as
/// `namespaceMemberSym` searches every part.
fn namespaceMemberSuggestion(c: *Checker, ns_sym: SymbolId, name: Atom) Error!Atom {
    var atoms: std.ArrayList(Atom) = .empty;
    defer atoms.deinit(c.scratch());
    if (c.prog.isMergedId(ns_sym)) {
        for (c.prog.mergedSym(ns_sym).parts) |p| try nsExportedNames(c, p, &atoms);
    } else {
        try nsExportedNames(c, ns_sym, &atoms);
    }
    if (atoms.items.len == 0) return 0;
    const names = try c.scratch().alloc([]const u8, atoms.items.len);
    defer c.scratch().free(names);
    for (atoms.items, names) |a, *n| n.* = c.atomText(a);
    const idx = intern.spellingSuggestion(c.scratch(), c.atomText(name), names) orelse return 0;
    return atoms.items[idx];
}

/// `A.Deep.G` — the written entity name, rebuilt from its tokens (tsc's
/// `entityNameToString`) for the messages that quote the WHOLE dotted name
/// rather than one segment. Scratch-allocated; `diagFmt` copies.
fn entityNameText(c: *Checker, node: Node, out: *std.ArrayList(u8)) Error!void {
    switch (c.nodeTag(node)) {
        .qualified_name, .member_expr => {
            const d = c.tree.nodeData(node);
            try entityNameText(c, d.lhs, out);
            try out.append(c.scratch(), '.');
            try out.appendSlice(c.scratch(), c.tokenText(d.rhs));
        },
        else => try out.appendSlice(c.scratch(), c.tokenText(c.tree.nodeMainToken(node))),
    }
}

/// The qualifier of a dotted type name reached no container. tsc splits that
/// into two diagnostics at the LEFTMOST identifier of the chain, and both were
/// silent `any` here:
///
///   * the name resolves to nothing at all, or to something with only a VALUE
///     meaning (`var vv; let x: vv.T`) — TS2503 "Cannot find namespace";
///   * it resolves to a TYPE that is not a container (a class, an interface, a
///     type alias) — TS2702 "only refers to a type, but is being used as a
///     namespace here", refined to TS2713 ("… Did you mean to retrieve the type
///     of the property …") when that type actually HAS the property the dotted
///     name went on to ask for. `member_tok` is that property's token: the
///     caller's own right-hand side for `T.abc`, or — when the failure is
///     deeper in the chain — the INNERMOST segment, which is the one tsc
///     quotes (`I.nested.deep` reports about `I.nested`).
///
/// Both oracle-verified against tsgo 7.0.2, together with the two cases that
/// must stay silent here: a resolved container whose deeper segment failed
/// (`.sym`, left to the TS2694 arms) and a namespace-augmentation name that
/// only the augmented module's exports declare (`augmentModuleTypeSym`, the
/// same fallback the bare-name path consults before it reports).
///
/// Returns whether it reported, so the caller can answer `error` instead of
/// `any` exactly when tsc does.
/// Does the type `sym` declares carry a property named by `member_tok`? The
/// TS2702-vs-TS2713 test: tsc offers the indexed-access rewrite (`T["abc"]`)
/// exactly when the rewrite would have worked.
///
/// The type is built with `sym`'s own type parameters standing in for
/// themselves (tsc's `getDeclaredTypeOfSymbol`) rather than through
/// `namedTypeFromSymbol`, whose `fixTypeArgs` would report a second, spurious
/// TS2314 for a generic name written bare — `interface G<T> { a: T }` with
/// `let x: G.a` is TS2713 alone.
///
/// `allow_index = false`, which is tsc's rule here twice over: a string index
/// signature does NOT make the name a property (`interface Idx { [k: string]:
/// number }` with `Idx.whatever` stays TS2702), and neither do the CLASS's
/// static members (only the instance type is consulted). It also means the
/// apparent members every object inherits from the global `Object` interface
/// are not consulted, where tsc does offer the rewrite (`Q.toString`); that
/// stays TS2702 — the refinement only ever under-fires, never over-fires.
fn qualifierHasProp(c: *Checker, sym: SymbolId, tok: TokenIndex, member_tok: TokenIndex) Error!bool {
    if (member_tok == 0) return false;
    const f = c.symFlags(sym);
    const declared: TypeId = if (f.type_param)
        try c.ts.makeTypeParam(sym)
    else if (f.enum_decl)
        try c.ts.makeEnumType(sym)
    else blk: {
        var tps: std.ArrayList(typeparams.TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        const args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        if (f.type_alias) break :blk try c.aliasInstance(sym, args, tok);
        if (f.interface or f.class) break :blk try c.ts.makeRef(sym, args);
        return false;
    };
    return (try c.propOfTypeEx(declared, try c.memberAtom(member_tok), false)) != null;
}

/// The same flags with the `namespace_decl` (and `import_binding`) bits
/// cleared, so `hasTypeMeaning` answers "does this symbol declare a TYPE?"
/// rather than "could it stand for one?". tsc's `SymbolFlags.Type` excludes
/// `NamespaceModule` / `ValueModule`, which is what makes a bare namespace name
/// in type position TS2709.
fn nonNsFlags(f: binder.SymbolFlags) binder.SymbolFlags {
    var out = f;
    out.namespace_decl = false;
    out.import_binding = false;
    return out;
}

/// Where a dotted ENTITY NAME stopped resolving: the namespace container that
/// could not answer, the qualifier node that named it (for the message, which
/// quotes the whole dotted path) and the segment it could not answer.
pub const NsBreak = struct {
    ns: SymbolId,
    qualifier: Node,
    name_tok: TokenIndex,
    /// The container declares the name but does not EXPORT it — the certain
    /// half of the failure. A name the container does not declare at all is the
    /// half a ztsc resolution gap can also produce, so a caller that is not
    /// tsc's own `resolveEntityName` site screens on this.
    unexported: bool,
};

/// tsc's `resolveEntityName` reports at the FIRST segment its container cannot
/// answer, not at the last one written: `D.inner.Class1` with `inner`
/// unexported is a TS2694 about `inner`. This walks a dotted name left to
/// right and returns that segment.
///
/// Null when every segment resolves, when the chain's ROOT is not a container
/// at all (a different diagnostic, and a different caller's business), and —
/// deliberately — when the failure is inside a whole-MODULE container, where
/// ztsc's re-export modelling is incomplete and the documented policy is
/// silence rather than a spurious TS2694 (`typeFromQualifiedName`'s `.module`
/// arm draws the same line).
pub fn nsChainBreak(c: *Checker, node: Node) Error!?NsBreak {
    switch (c.nodeTag(node)) {
        .qualified_name, .member_expr => {},
        else => return null,
    }
    const d = c.tree.nodeData(node);
    // The leftmost failure wins, so the qualifier is asked first.
    if (try nsChainBreak(c, d.lhs)) |b| return b;
    const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
    const ns = switch (outer) {
        .ns => |s| s,
        .module => return null,
    };
    const name = try c.memberAtom(d.rhs);
    if (c.containerMemberSym(outer, name) != null) return null;
    return .{
        .ns = ns,
        .qualifier = d.lhs,
        .name_tok = d.rhs,
        .unexported = c.namespaceMemberSym(ns, name) != null,
    };
}

/// The TS2694 / TS2724 pair for one `nsChainBreak`, spelled as tsc spells it:
/// the namespace is named by the WHOLE dotted qualifier (tsc's
/// `getFullyQualifiedName`), not by its last segment.
pub fn reportNsChainBreak(c: *Checker, b: NsBreak) Error!void {
    const name = try c.memberAtom(b.name_tok);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(c.scratch());
    try entityNameText(c, b.qualifier, &buf);
    const sugg = try namespaceMemberSuggestion(c, b.ns, name);
    if (sugg != 0) {
        try c.diagFmt(2724, c.tokSpan(b.name_tok), "'{s}' has no exported member named '{s}'. Did you mean '{s}'?", .{ buf.items, c.atomText(name), c.atomText(sugg) });
        return;
    }
    try c.diagFmt(2694, c.tokSpan(b.name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ buf.items, c.atomText(name) });
}

/// tsc's `checkImportEqualsDeclaration` → `resolveAlias` for the ENTITY-NAME
/// form `import X = A.B.C`, whose right-hand side is resolved with errors ON.
/// The module form (`= require("m")`) is the linker's, and a bare identifier
/// resolves in every meaning at once — only a DOTTED name has a container that
/// can fail.
///
/// `exported` additionally earns TS2708 on the root when the chain broke: an
/// `export import` alias whose target did not resolve keeps every meaning, so
/// tsc's emit resolver treats it as a value reference and resolves the root in
/// VALUE meaning — where a non-instantiated namespace is not a value. A
/// RESOLVED chain never reaches that path (oracle-verified: `export import a =
/// q.inner.k` through two type-only namespaces is silent, and the same
/// declaration with an unexported final segment reports both).
pub fn checkImportEqualsEntity(c: *Checker, entity: Node, exported: bool) Error!void {
    var root = entity;
    while (c.nodeTag(root) == .qualified_name or c.nodeTag(root) == .member_expr) {
        root = c.tree.nodeData(root).lhs;
    }
    if (c.nodeTag(root) != .identifier) return;
    const tok = c.tree.nodeMainToken(root);
    // A literal or a reserved word where the entity should be is a PARSE
    // error (`import n = 5`, `import q = null`), not a name to resolve.
    if (c.tree.tokens.tag(tok) != .identifier) return;
    // `globalThis` is in scope everywhere and has no declaration to find.
    if (std.mem.eql(u8, c.tokenText(tok), "globalThis")) return;
    const a = try c.atomOfToken(tok);
    // A root that names NOTHING, in any space. tsc's `resolveEntityName` here
    // carries `SymbolFlags.Namespace`, so the message is "Cannot find
    // namespace" (TS2503/TS2833) and not the TS2304 an expression-position
    // identifier would earn — oracle-verified for both the dotted and the bare
    // form of the right-hand side.
    const root_sym: SymbolId = switch (c.resolveNamespaceSpace(a, c.cur_scope)) {
        .sym => |s| s,
        else => {
            if (c.resolveSpace(a, c.cur_scope, true) != .none) return;
            if (c.resolveSpace(a, c.cur_scope, false) != .none) return;
            if (c.suggestName(a, c.cur_scope, false)) |sugg| {
                try c.diagFmt(2833, c.tokSpan(tok), "Cannot find namespace '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
            } else {
                try c.diagFmt(2503, c.tokSpan(tok), "Cannot find namespace '{s}'.", .{c.tokenText(tok)});
            }
            return;
        },
    };
    try reportHiddenModule(c, tok, a, root_sym);
    const b = (try nsChainBreak(c, entity)) orelse return;
    if (exported and modvalue.valuelessNamespace(c, root_sym)) {
        try c.diagFmt(2708, c.tokSpan(tok), "Cannot use namespace '{s}' as a value.", .{c.tokenText(tok)});
    }
    try reportNsChainBreak(c, b);
}

/// TS2437: `import Y = A` where a local declaration hides the module `A`.
///
/// The right-hand side resolves in NAMESPACE space, which walks straight past a
/// local `var A` to find the outer `namespace A`. What the alias EMITS, though,
/// is a plain `var Y = A;` — and that `A` resolves in VALUE space, to the local
/// declaration. The alias would bind the wrong thing, so tsc refuses it.
///
/// Both halves of that reasoning are load-bearing, and each one is a silence:
///
///   * a module with no value of its own emits nothing that could be wrong, so
///     an UNINSTANTIATED namespace is silent however it is shadowed — while the
///     same namespace merged with a class reports
///     (`internalImportUnInstantiatedModuleMergedWithClassNotReferencingInstance`
///     against the `TypeOnly` shape, both oracle-measured);
///   * a shadow that resolves in value space to the module ITSELF hides
///     nothing, which is why a local `namespace`, `enum` or import alias of the
///     same name is silent where a `var`, `let`, `function` or `class` reports.
///
/// Only the FIRST identifier of a dotted right-hand side is emitted as a bare
/// name, so only it is checked: `import F = Q.R` beside a local `var R` is
/// fine. Position does not matter either — a `var` written AFTER the alias
/// hides it just the same.
fn reportHiddenModule(c: *Checker, tok: TokenIndex, a: Atom, root_sym: SymbolId) Error!void {
    if (modvalue.valuelessNamespace(c, root_sym)) return;
    const in_value = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return,
    };
    if (in_value == root_sym) return;
    try c.diagFmt(2437, c.tokSpan(tok), "Module '{s}' is hidden by a local declaration with the same name.", .{c.tokenText(tok)});
}

fn reportBadNsQualifier(c: *Checker, node: Node, member_tok: TokenIndex) Error!bool {
    // A qualifier whose own chain broke earlier reports there, not at its
    // leftmost identifier: `D.inner.Class1` blames `inner`.
    //
    // Only the DECLARED-BUT-UNEXPORTED half is certain enough to report from a
    // type name. A name the container does not declare at all can equally mean
    // ztsc resolved the wrong container — sibling `namespace X.A.B.C` blocks
    // share one members scope here where tsc keeps their locals apart, so
    // `implements A.C.Z` next to a local `namespace A {}` finds the local one
    // (`declFileWithInternalModuleNameConflictsInExtendsClause2`) — and the
    // documented policy for a resolution gap is silence.
    if (try nsChainBreak(c, node)) |b| {
        if (!b.unexported) return false;
        try reportNsChainBreak(c, b);
        return true;
    }
    var n = node;
    var member = member_tok;
    while (c.nodeTag(n) == .qualified_name or c.nodeTag(n) == .member_expr) {
        member = c.tree.nodeData(n).rhs;
        n = c.tree.nodeData(n).lhs;
    }
    if (c.nodeTag(n) != .identifier) return false;
    const tok = c.tree.nodeMainToken(n);
    // `globalThis` is in scope everywhere and has no declaration for the walk
    // above to find, so it would read as "cannot find namespace". tsc's
    // `globalThisSymbol` carries `Module` meaning and resolves:
    // `T extends globalThis.Function` is silent (the lib's own
    // instanceofOperatorWithRHSHasSymbolHasInstance test).
    if (std.mem.eql(u8, c.tokenText(tok), "globalThis")) return false;
    const a = try c.atomOfToken(tok);
    const type_sym: ?SymbolId = switch (c.resolveNamespaceSpace(a, c.cur_scope)) {
        .sym => return false,
        .wrong_space => |sym| if (hasTypeMeaning(c.symFlags(sym))) sym else null,
        .none => null,
    };
    if ((try c.augmentModuleTypeSym(c.cur_scope, a)) != null) return false;
    if (type_sym) |sym| {
        if (try qualifierHasProp(c, sym, tok, member)) {
            try c.diagFmt(2713, c.tokSpan(tok), "Cannot access '{s}.{s}' because '{s}' is a type, but not a namespace. Did you mean to retrieve the type of the property '{s}' in '{s}' with '{s}[\"{s}\"]'?", .{
                c.tokenText(tok),    c.tokenText(member), c.tokenText(tok),
                c.tokenText(member), c.tokenText(tok),    c.tokenText(tok),
                c.tokenText(member),
            });
            return true;
        }
        try c.diagFmt(2702, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a namespace here.", .{c.tokenText(tok)});
        return true;
    }
    // tsc's "not found" pair, exactly as the bare-name arm above spells it:
    // a close name in scope turns the message into the suggestion variant
    // (TS2833 rather than TS2503).
    if (c.suggestName(a, c.cur_scope, false)) |sugg| {
        try c.diagFmt(2833, c.tokSpan(tok), "Cannot find namespace '{s}'. Did you mean '{s}'?", .{ c.tokenText(tok), c.atomText(sugg) });
        return true;
    }
    try c.diagFmt(2503, c.tokSpan(tok), "Cannot find namespace '{s}'.", .{c.tokenText(tok)});
    return true;
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
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(c.scratch());
            try entityNameText(c, d.lhs, &buf);
            try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ buf.items, c.atomText(name) });
            return types.error_type;
        }
    }
    const container = (try c.resolveNsContainer(d.lhs)) orelse {
        if (try reportBadNsQualifier(c, d.lhs, name_tok)) return types.error_type;
        return types.any_type;
    };
    switch (container) {
        .ns => |ns_sym| {
            if (c.namespaceMemberSym(ns_sym, name)) |g| {
                const mf = c.symFlags(g);
                if (mf.exported) {
                    if (memberNamesAType(mf)) return c.namedTypeFromSymbol(g, args, name_tok);
                    // Names a value and no type: tsc's `resolveEntityName`
                    // falls through to the VALUE meaning and answers TS2749
                    // over the whole dotted name, not TS2694 on the member.
                    // Reaches `export var v`, `export function fn`, `export
                    // const c`, an INSTANTIATED `export namespace S`, and the
                    // fundule pair `export function B<T>() {} export namespace
                    // B { … }` — which was a silent `any` before.
                    if (memberNamesAValue(c, g, mf)) {
                        var buf: std.ArrayList(u8) = .empty;
                        defer buf.deinit(c.scratch());
                        try entityNameText(c, node, &buf);
                        try c.diagFmt(2749, c.nodeSpan(node), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ buf.items, buf.items });
                        return types.error_type;
                    }
                }
            }
            // Both messages name the QUALIFIER as written, not the container's
            // own single name: tsc renders the symbol with
            // `SymbolFormatFlags.None`, whose qualified-name walk spells every
            // enclosing namespace — `M.N`, not `N` (and `M.Deep.Deeper` for a
            // chain). The dotted text of `d.lhs` is exactly that walk, and it
            // is already what the TS2749 arm above prints.
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(c.scratch());
            try entityNameText(c, d.lhs, &buf);
            const sugg = try namespaceMemberSuggestion(c, ns_sym, name);
            if (sugg != 0) {
                try c.diagFmt(2724, c.tokSpan(name_tok), "'{s}' has no exported member named '{s}'. Did you mean '{s}'?", .{ buf.items, c.atomText(name), c.atomText(sugg) });
                return types.error_type;
            }
            try c.diagFmt(2694, c.tokSpan(name_tok), "Namespace '{s}' has no exported member '{s}'.", .{ buf.items, c.atomText(name) });
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
            // NAMESPACE meaning, not type meaning: a `class` is a type but
            // not a container, and stopping at one hid an outer namespace of
            // the same name — `var x = class C { prop: C.type }` inside
            // `namespace C { export interface type {} }`.
            switch (c.resolveNamespaceSpace(a, c.cur_scope)) {
                .sym => |sym| {
                    if (c.symFlags(sym).namespace_decl) return .{ .ns = sym };
                    if (c.symFlags(sym).import_binding) {
                        if (c.importTarget(sym)) |tgt| return c.containerFromImportTarget(tgt);
                        // No import RECORD means the ENTITY-NAME form,
                        // `import booz = foo.bar.baz` — nothing to link, so
                        // the right-hand side is resolved in the ALIAS's own
                        // file and scope instead (`importEqualsEntityContainer`,
                        // which jsx.zig already does for `export import JSX =
                        // JSXInternal`).
                        return try c.importEqualsEntityContainer(sym);
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
pub fn containerFromImportTarget(c: *Checker, tgt0: modules.Target) ?NsContainer {
    // A namespace container is a type-space entity: take the dual's type half.
    const tgt = c.typeMeaningTarget(tgt0);
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

/// The namespace container an ENTITY-NAME `import X = A.B` alias stands for,
/// or null (including for every other kind of binding).
///
/// The binder records an import *record* only for `import X = require("m")`:
/// the entity-name form names something already in the program, so there is no
/// module to link and `importTarget` returns null. Alias consumers then see an
/// "unlinked" binding and degrade to `any`. The RHS is resolved here instead —
/// in the ALIAS's own file and scope, which is not the use site's, so the walk
/// enters that file first (`enterSymFile`).
///
/// preact publishes its JSX namespace this way (`declare global { export
/// import JSX = JSXInternal }`), which left `JSX.Element` /
/// `JSX.IntrinsicElements` resolving to nothing at all.
///
/// `entity_alias_stack` cuts the self-reference `import a = a.b`, whose
/// qualifier resolves straight back to the alias being resolved.
pub fn importEqualsEntityContainer(c: *Checker, sym0: SymbolId) Error!?NsContainer {
    const sym = c.reprSym(sym0);
    if (!c.symFlags(sym).import_binding) return null;
    if (c.importTarget(sym) != null) return null; // module form: not ours
    if (std.mem.indexOfScalar(SymbolId, c.entity_alias_stack.items, sym) != null) return null;
    for (c.declsOf(sym)) |decl| {
        if (c.prog.files[c.symFile(sym)].tree.nodeTag(decl) != .import_equals) continue;
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(sym);
        const e = c.tree.extraData(ast.ImportEquals, c.tree.nodeData(decl).lhs);
        if (e.module_token != 0 or e.entity == null_node) return null;
        try c.entity_alias_stack.append(c.cm(), sym);
        defer _ = c.entity_alias_stack.pop();
        return try c.resolveNsContainer(e.entity);
    }
    return null;
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
            if (c.moduleExportTarget(m, name)) |tgt| {
                if (c.containerFromImportTarget(tgt)) |ct| return ct;
            }
            // `export =` module: the members live on the ASSIGNED entity, not
            // in the module's own export table (which holds only the reserved
            // `export=` key). See `containerMemberSym` for the full story.
            const g = c.exportEqualsMemberSym(m, name) orelse return null;
            const mf = c.symFlags(g);
            if (mf.namespace_decl) return .{ .ns = g };
            if (mf.import_binding) {
                if (c.importTarget(g)) |t2| return c.containerFromImportTarget(t2);
            }
            return null;
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
            if (c.moduleExportTarget(m, name)) |tgt| {
                if (c.targetTypeSym(tgt)) |g| return g;
            }
            // A module that publishes its contents by ASSIGNMENT — `declare
            // namespace __React { … } declare module "react" { export =
            // __React }` — keeps nothing but the reserved `export=` key in its
            // own export table, so the lookup above misses every member. tsc
            // resolves `React.Component` by following the alias to the
            // assigned entity and taking ITS exports; `exportEqualsMemberSym`
            // is that walk, already used for `import("m").T`.
            //
            // The miss was silent and expensive: `class X extends
            // React.Component<…>` resolved to no base symbol at all, so every
            // React class component in the corpus inherited zero members —
            // no `props`, `state`, `setState`, `forceUpdate`, `context` or
            // `refs` — and `JSX.ElementClass` could never be satisfied.
            return c.exportEqualsMemberSym(m, name);
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

/// `typeof entity` in type position: the entity's value type.
pub fn typeofEntity(c: *Checker, node: Node) Error!TypeId {
    if (node == null_node) return types.any_type;
    // `typeof this` / `typeof this.a.b` — legal only in a type query, and
    // only where a `this` value exists (a class or interface body). The
    // query names the `this` VALUE, so the answer is the enclosing
    // declaration's `this` type; `this` is a value, never a name, so it
    // must not go through the identifier path (which would report TS2304).
    // Same reading as `this` in a TYPE position, polymorphic marker
    // included — `self: typeof this` on a base class read through a
    // SUBCLASS instance is the subclass, not the base.
    if (c.nodeTag(node) == .this_expr) {
        if (c.this_type == 0) return types.any_type;
        if (c.ts.kind(c.this_type) != .ref) return c.this_type;
        c.has_this_types = true;
        return c.ts.makeThisType(c.this_type);
    }
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
        var base = try c.typeofEntity(d.lhs);
        // A `typeof this.x` base is the polymorphic `this`; the PROPERTY it
        // qualifies is read off the home instance. Keeping the marker here
        // would defer the lookup behind `substThis`, and this member is
        // being resolved while that very table is built — there is no later
        // receiver to supply.
        if (c.ts.kind(base) == .this_type) base = c.ts.thisTypeInstance(base);
        const name = try c.memberAtom(d.rhs);
        const rb = try c.resolveStructural(base);
        // A class whose member table is still materializing resolves to
        // `err` (`expandRef`'s cycle cut), and a type query rooted at the
        // very class being built is exactly that: `resolveHandle: typeof
        // this.com.atproto.identity.resolveHandle` asks for a property of
        // its own home instance. tsc answers it because a member's type is
        // resolved per-SYMBOL, not by folding the whole table, so read the
        // one member's declaration directly rather than surrendering the
        // query — an `err` here erases every type built on it (@atproto's
        // `Agent` declares its whole call surface this way, so every
        // response type it returns came back untyped).
        if (c.ts.kind(rb) == .err) {
            if (try c.classChainMemberType(base, name)) |mt|
                return c.regularizeTypeQuery(mt);
        }
        if (c.ts.kind(rb) == .any or c.ts.kind(rb) == .err) return rb;
        if (try c.propOfType(rb, name)) |p| {
            // An OPTIONAL property's type includes `undefined` (tsc bakes it
            // in at declaration with `addOptionality`, so `getTypeOfSymbol`
            // — which is all a type query reads — already carries it). ztsc
            // keeps `| undefined` out of the stored property type and unions
            // it in at every read instead, so the type query has to do the
            // same or `typeof obj.optProp` comes back strictly narrower than
            // tsc's. social-app's `post-shadow.ts` declares
            // `let embed: typeof post.embed` over an optional `embed?:` and
            // assigns it only under a guard: with the `undefined` missing,
            // the declared type excluded `undefined` and definite-assignment
            // analysis reported a spurious TS2454.
            const pt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
            return c.regularizeTypeQuery(pt);
        }
        // Unknown member: stay silent (`any`) rather than risk a false
        // positive — the value-position access reports it where written.
        return types.any_type;
    }
    if (c.nodeTag(node) != .identifier) return types.any_type;
    const tok = c.tree.nodeMainToken(node);
    if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.undefined_type;
    const a = try c.atomOfToken(tok);
    switch (c.resolveTypeQuerySpace(a, c.cur_scope)) {
        .sym => |sym| {
            // `typeof M` names a VALUE, and a namespace with nothing but
            // types in it is not one (see `valuelessNamespace`).
            if (try modvalue.valuelessNamespaceRef(c, sym, c.symFlags(sym))) {
                try c.diagFmt(2708, c.tokSpan(tok), "Cannot use namespace '{s}' as a value.", .{c.tokenText(tok)});
                return types.error_type;
            }
            return c.regularizeTypeQuery(try c.typeOfSymbol(sym));
        },
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
            // Anything else that reached here carries a TYPE meaning and no
            // value meaning — an `interface`, a `type` alias, a type
            // parameter. `typeof` names a VALUE, so tsc reports TS2693
            // (`typeofSimple`'s `typeof J`, `typeofTypeParameter`'s
            // `typeof T`), the same message a value position gives.
            if (hasTypeMeaning(wf)) {
                try c.diagFmt(2693, c.tokSpan(tok), "'{s}' only refers to a type, but is being used as a value here.", .{c.tokenText(tok)});
                return types.error_type;
            }
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
