//! The VALUE meaning of a module reference: what an import binding, a
//! namespace object (`import * as ns`), or a link-table target types as.
//!
//! Everything here reads the sealed link tables rather than the syntax, so it
//! is the checker's side of `link/modules.zig`: one function per target kind,
//! plus the two cycle-safe namespace-object caches and the `declare module`
//! augmentations that fold extra exports into them.
//!
//! `globalThis` closes the set at the bottom: the outermost "namespace object"
//! of all, read the same way — one member per value-space entry of the sealed
//! `prog.globals` table, on demand.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const modules = @import("../link/modules.zig");
const paths = @import("../link/paths.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const FileId = checker_zig.FileId;

const names = @import("names.zig");
const typenode = @import("typenode.zig");
const hasValueMeaning = names.hasValueMeaning;

/// tsc's `checkAndReportErrorForUsingNamespaceAsTypeOrValue`, value half:
/// does this name denote a NON-INSTANTIATED namespace and nothing else?
///
/// `namespace M { export interface P {} }` declares no value at all, so tsc
/// gives its symbol `SymbolFlags.NamespaceModule` — which is outside
/// `SymbolFlags.Value` — and a value-position use of `M` is TS2708 rather
/// than a type. ztsc's `hasValueMeaning` accepts every `namespace_decl` so
/// that the lexical walk still *finds* the name (stopping there is what makes
/// the diagnostic specific instead of "Cannot find name"); the use sites ask
/// this instead of resolving differently.
///
/// A MERGED id reports the OR of its parts' flags, and `ns_uninstantiated` has
/// to be an AND (one instantiated block makes the whole merge a value), so the
/// merge is walked part by part.
pub fn valuelessNamespace(c: *const Checker, sym: SymbolId) bool {
    if (!c.symFlags(sym).namespace_decl) return false;
    if (!c.prog.isMergedId(sym)) return uninstantiatedPart(c, sym);
    const m = c.prog.mergedSym(sym);
    for (m.parts) |p| {
        if (!uninstantiatedPart(c, p)) return false;
    }
    return m.parts.len != 0;
}

/// `valuelessNamespace` through an ENTITY-NAME alias. `import U = Outer.uninst`
/// carries exactly the meanings its right-hand side has, so `typeof U` and
/// `U.member` in value position are the same TS2708 the namespace's own name
/// earns (`typeofInternalModules`). The `= require("m")` form has an import
/// RECORD and is the linker's; only the entity form is walked here.
///
/// `f` is the caller's already-loaded `symFlags(sym)`: every call site has it,
/// and `interesting(f)` — one branch on two bits — is what keeps this off the
/// hot path for the identifiers that are neither.
pub fn valuelessNamespaceRef(c: *Checker, sym: SymbolId, f: binder.SymbolFlags) Error!bool {
    if (!interesting(f)) return false;
    if (valuelessNamespace(c, sym)) return true;
    if (!f.import_binding or c.importTarget(sym) != null) return false;
    return switch ((try c.importEqualsEntityContainer(sym)) orelse return false) {
        .ns => |ns| valuelessNamespace(c, ns),
        .module => false,
    };
}

/// Could `valuelessNamespaceRef` possibly say yes? A name that is neither a
/// namespace nor an alias never can, and that is every identifier in ordinary
/// code — so the screen is inlined at each call site's already-loaded flags
/// rather than paid as a call.
pub fn interesting(f: binder.SymbolFlags) bool {
    return f.namespace_decl or f.import_binding;
}

/// One declaration: a namespace block with no value in it, merged with nothing
/// that carries a value meaning of its own. An import binding counts as a value
/// here — an alias's own meaning is the target's, which this flag screen cannot
/// see.
fn uninstantiatedPart(c: *const Checker, sym: SymbolId) bool {
    const f = c.symFlags(sym);
    if (!f.namespace_decl or !f.ns_uninstantiated) return false;
    if (f.var_decl or f.let_decl or f.const_decl or f.function or f.class or
        f.param or f.catch_param or f.enum_decl or f.enum_member or f.import_binding) return false;
    const tree = c.prog.files[c.symFile(sym)].tree;
    for (c.declsOf(sym)) |decl| {
        if (tree.nodeTag(decl) != .namespace_decl) continue;
        if (!nonInstantiatedBlock(tree, decl, 16)) return false;
    }
    return true;
}

/// tsc's `getModuleInstanceState(node) === NonInstantiated`, which is what
/// decides whether the binder gives a `namespace` symbol `NamespaceModule` (no
/// value meaning, so TS2708 at a value use) or `ValueModule`.
///
/// NOT `binder.instantiated`, which answers the neighbouring question "does
/// this block EMIT a runtime object with `preserveConstEnums` off" for the
/// declaration-merge rule. The two disagree on exactly the shapes this one has
/// to get right:
///
///   * a `const enum` body is `ConstEnumOnly`, not `NonInstantiated`, so the
///     namespace keeps its value meaning (`constEnums`: `A.B.C.E.V1` is silent
///     while the binder calls every block of `A` type-only);
///   * an `export`ed import alias is `Instantiated` outright — tsc returns
///     `NonInstantiated` for an import only when it is NOT exported
///     (`exportImportAlias`: `namespace C { export import a = A }` read as
///     `C.a.x`). The binder's walk cannot see that `export`, which the parser
///     records as a FLAG on the import node rather than as an `export` wrapper.
///
/// Reached only after `ns_uninstantiated` — true wherever tsc's
/// `NonInstantiated` is — has already screened the name, so the walk is paid on
/// the handful of namespaces whose verdict it can change.
fn nonInstantiatedBlock(tree: *const ast.Ast, node: Node, depth: u8) bool {
    if (depth == 0) return false; // "cannot tell" ⇒ keep the value meaning
    const data = tree.extraData(ast.NamespaceData, tree.nodeData(node).lhs);
    for (tree.extraRange(data.body_start, data.body_end)) |raw| {
        if (raw == null_node) continue;
        // `export interface I {}` is an InterfaceDeclaration for tsc; the
        // modifier is not a node of its own there.
        var stmt = raw;
        while (tree.nodeTag(stmt) == .export_decl) {
            stmt = tree.nodeData(stmt).lhs;
            if (stmt == null_node) return false;
        }
        switch (tree.nodeTag(stmt)) {
            .interface_decl, .type_alias => {},
            .import_decl => {
                const e = tree.extraData(ast.ImportData, tree.nodeData(stmt).lhs);
                if (e.flags & ast.Flags.exported != 0) return false;
            },
            .import_equals => {
                const e = tree.extraData(ast.ImportEquals, tree.nodeData(stmt).lhs);
                if (e.flags & ast.Flags.exported != 0) return false;
            },
            .namespace_decl => if (!nonInstantiatedBlock(tree, stmt, depth - 1)) return false,
            else => return false,
        }
    }
    return true;
}

/// Does an exported BINDING contribute a member to a module namespace object
/// (`typeof import("m")`, `import * as ns`)?
///
/// tsc's `SymbolFlags.Value` test on the export. Beyond the flag screen it
/// takes in the non-instantiated namespace: `export namespace Baz { export
/// interface J {} }` emits no runtime object, so tsc gives it `NamespaceModule`
/// rather than `ValueModule` and the module's namespace object has no `Baz`
/// property at all — an object literal that omits it is complete, not a TS2741
/// (`importTypeLocal`, `importTypeAmbient`, `importTypeGenericTypes`).
fn bindingHasValue(c: *const Checker, g: SymbolId) bool {
    return hasValueMeaning(c.symFlags(g)) and !valuelessNamespace(c, g);
}

/// Does a VALUE-position reference through an import binding have a value to
/// refer to, and if not, why not?
pub const AliasValueVerdict = enum {
    /// Not an alias at all, or one whose target really is a value — and the
    /// verdict for any merged symbol that already answers the value meaning
    /// out of its own declarations, whose alias is never consulted.
    has_value,
    /// The alias names something with only a TYPE meaning: TS2693 in an
    /// expression, but a legal `export =` / `export default` target.
    type_target,
    /// The alias reaches a value through an `export type { … }` re-export,
    /// which strips the value meaning at the boundary: TS1362.
    export_type,
};

/// tsc's `resolveAlias` + value-meaning test for a name that resolved to an
/// import binding. Shared by the value-expression identifier arm (which turns
/// the verdict into a diagnostic) and by `export =` / `export default`, whose
/// operand tsc resolves in `SymbolFlags.All` and leaves alone when the alias
/// has no value meaning.
///
/// The alias is consulted only when the merged symbol has no value meaning OF
/// ITS OWN: tsc resolves the name in the Value meaning and stops at the symbol
/// it finds, so a local `const X` merged with a type-only `import { X }` is a
/// perfectly good value `X` (`symbolMergeValueAndImportedType`).
pub fn aliasValueVerdict(c: *Checker, sym: SymbolId, f: binder.SymbolFlags) Error!AliasValueVerdict {
    if (!f.import_binding or names.hasOwnValueMeaning(f)) return .has_value;
    const tgt0 = c.importTarget(sym) orelse return .has_value;
    // A dual binding (tsc's combined value-and-type symbol) has a value
    // meaning as long as the export-assigned value's type really does carry
    // the property; when it does not, only the member's meanings are left and
    // the type-only verdict applies to it.
    const tgt = if (try c.dualHasValue(tgt0)) tgt0 else c.typeMeaningTarget(tgt0);
    if (tgt.kind == .binding) {
        const tf = c.symFlags(c.toGlobalIn(tgt.file, tgt.payload));
        // A pure type target is 2693 (matches tsc even through `export type`
        // chains); a value target reached through `export type` is 1362.
        if (!names.hasValueMeaning(tf) and names.hasTypeMeaning(tf)) return .type_target;
    }
    if (tgt.type_only) return .export_type;
    return .has_value;
}

/// The VALUE type of an `import X = A.B` alias — the ENTITY-NAME form, which
/// names something already in the program and so has no module for the linker
/// to record. `importedSymbolType` saw an unlinked binding and answered `any`,
/// which is a value that accepts everything: `import myA = M.A` on an abstract
/// `M.A` was `new`-able where `new M.A` is TS2511, and the alias of a class
/// lost its statics, its construct signature and its instance type all at once.
///
/// tsc's `resolveAlias` → `resolveEntityName` in the VALUE meaning: the alias
/// denotes exactly what its right-hand side denotes, so this resolves the
/// entity in the ALIAS's own file and scope (which is not the use site's) and
/// answers the target's own type. Null when there is no entity form here, or
/// when the entity names nothing in value space — `checkImportEqualsEntity`
/// owns the diagnostics for that, and the old `any` is the right silence.
///
/// `entity_alias_stack` cuts the self-reference `import a = a.b`, exactly as
/// it does for the type-space walk (`importEqualsEntityContainer`).
fn entityAliasValueType(c: *Checker, sym0: SymbolId) Error!?TypeId {
    const sym = c.reprSym(sym0);
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
        const target = (try entityValueSym(c, e.entity)) orelse return null;
        if (target == sym) return null;
        return try c.typeOfSymbol(target);
    }
    return null;
}

/// The symbol an `import X = …` right-hand side denotes in VALUE space: a bare
/// name resolves lexically, a dotted one through its namespace container.
fn entityValueSym(c: *Checker, entity: Node) Error!?SymbolId {
    switch (c.nodeTag(entity)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(entity));
            return switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |s| c.toGlobal(s),
                else => null,
            };
        },
        .qualified_name, .member_expr => {
            const d = c.tree.nodeData(entity);
            const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
            return c.containerMemberSym(outer, try c.memberAtom(d.rhs));
        },
        else => return null,
    }
}

/// Value type of an import binding, via the sealed link tables.
pub fn importedSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const tgt = c.importTarget(sym) orelse {
        // Unlinked: either the entity-name form (resolved above) or a module
        // reference that did not link at all, which stays `any`.
        return (try entityAliasValueType(c, sym)) orelse types.any_type;
    };
    if (tgt.kind == .any) try reportNamespaceRequireMiss(c, sym);
    const ty = try c.targetValueType(tgt);
    if (!c.prog.es_module_interop or !starImportBinding(c, sym)) return ty;
    if (!try canHaveSyntheticDefault(c, tgt)) return ty;
    return interopNamespaceType(c, ty);
}

/// tsc's `canHaveSyntheticDefault`, the guard on the interop reshaping below:
/// a module that already declares `default` SYNTACTICALLY (`export default`,
/// `export { x as default }`, `export * as default`) gets no synthesized one,
/// and neither does one that declares `__esModule` — both are the author
/// stating the module's runtime shape, which the `__importStar` helper then
/// passes through untouched.
///
/// This is what keeps `import type * as Hls from "hls.js"` — a `.d.ts` with
/// `export default class Hls` alongside its named exports — spelling
/// `Hls.default` as the class rather than as the whole module namespace.
///
/// `linkImports` gives a `.namespace` import record one of four target shapes,
/// and each answers the question directly: `.namespace`/`.ambient_ns` name the
/// module's own export table (walk it); `.any` is an opaque ambient module (no
/// shape to reason about); and ANY other kind means the linker followed the
/// module's `export =`, which is tsc's `hasExportAssignment` — the one case
/// where a source file (not just a `.d.ts`) can have a synthesized default, and
/// a module with `export =` can declare no `default` of its own.
fn canHaveSyntheticDefault(c: *Checker, tgt: modules.Target) Error!bool {
    const es_module_atom = try c.atom("__esModule");
    switch (tgt.kind) {
        .any => return false,
        .namespace => {
            if (c.prog.links.len == 0) return false;
            const l = &c.prog.links[tgt.file];
            return l.exportTarget(c.atom_default) == null and l.exportTarget(es_module_atom) == null;
        },
        .ambient_ns => {
            const ae = c.prog.ambient_exports[tgt.payload];
            for (ae.atoms) |name| {
                if (name == c.atom_default or name == es_module_atom) return false;
            }
            return true;
        },
        else => return true,
    }
}

/// Is `sym` the star of an `import * as ns from "m"` clause?
///
/// tsc's `resolveESModuleSymbol` applies the interop shape below only to that
/// syntax (and to a dynamic `import()`); `import ns = require("m")`, a plain
/// named import and an `export * as ns` re-export all keep the module's own
/// type, so the test is on the DECLARATION, not on the link target — every one
/// of those forms can point at the very same `.namespace` target.
///
/// `import d, * as ns from "m"` declares two symbols on the one `import_decl`,
/// so the name is compared as well. The comparison is on raw token text, which
/// a `\uXXXX`-escaped binding name would fail — that answers "not the star",
/// i.e. the pre-interop type, which is the safe side of the branch.
fn starImportBinding(c: *Checker, sym: SymbolId) bool {
    const s = c.reprSym(sym);
    const f = c.symFile(s);
    const pf = &c.prog.files[f];
    const decls = pf.bind.declsOf(s - c.prog.sym_base[f]);
    if (decls.len != 1) return false;
    if (pf.tree.nodeTag(decls[0]) != .import_decl) return false;
    const d = pf.tree.extraData(ast.ImportData, pf.tree.nodeData(decls[0]).lhs);
    if (d.ns_name_token == 0) return false;
    if (d.default_name_token == 0) return true;
    return std.mem.eql(u8, pf.tree.tokenSlice(pf.src, d.ns_name_token), c.atomText(c.symNameAtom(s)));
}

/// tsc's `resolveESModuleSymbol` interop shape: under `esModuleInterop`, the
/// namespace object of `import * as ns from "m"` is `getSpreadType([m, {
/// default: m }])` when `m`'s type is callable/constructible or already carries
/// a `default`. That is the shape of what the emitted `__importStar` helper
/// hands back at runtime for a CommonJS module, so `ns.default` names the whole
/// module (`esModuleInteropImportNamespace`).
///
/// Being a SPREAD is load-bearing in both directions: it adds `default` and it
/// DROPS the call/construct signatures, so `import * as f from "./fn"` under
/// interop is no longer callable — `f()` is TS2349 and `f.default()` is the
/// working spelling (`esModuleInteropDefaultImports`).
///
/// Gated on `esModuleInterop` alone, never on `allowSyntheticDefaultImports`:
/// the latter is ON by default under bundler resolution (ztsc's fixed model),
/// so gating on it would give every project this reshaping.
/// tsc's condition for the reshaping below: the module type has a call or a
/// construct signature, or already carries a `default`. Restricted to the
/// shapes `gatherSpreadProps` can reproduce faithfully — a class value's static
/// side, a bare `ref` or a union keeps the module's own type, since a namespace
/// object missing half its members is worse than one missing `default`.
///
/// The `function`/`overloads` shapes carry no own members, so their spread is
/// exactly `{ default: m }` and the empty gather is the right answer. An
/// `intersection` is the `export =` of a function/namespace merge (`(() =>
/// void) & typeof foo`), which is the ordinary spelling of a CommonJS module
/// that is both callable and a namespace.
fn interopReshapes(c: *Checker, st: TypeId) Error!bool {
    return switch (c.ts.kind(st)) {
        .function, .overloads => true,
        .object => c.ts.objectHasSigs(st) or c.ts.objectPropByName(st, c.atom_default) != null,
        .intersection => blk: {
            for (try c.memberList(st)) |m| {
                if (try interopReshapes(c, try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn interopNamespaceType(c: *Checker, t: TypeId) Error!TypeId {
    const st = try c.resolveStructural(t);
    if (!try interopReshapes(c, st)) return t;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var prop_index: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer prop_index.deinit(c.scratch());
    var str_index_vals: std.ArrayList(TypeId) = .empty;
    defer str_index_vals.deinit(c.scratch());
    var num_index_vals: std.ArrayList(TypeId) = .empty;
    defer num_index_vals.deinit(c.scratch());
    try c.gatherSpreadProps(st, &props, &prop_index, &str_index_vals, &num_index_vals);
    // The right-hand `{ default: m }` wins over any `default` the module
    // already exported (tsc's `createDefaultPropertyWrapperForModule`).
    try typenode.upsertProp(c.scratch(), &props, &prop_index, .{ .name = c.atom_default, .ty = t, .flags = 0 });
    const sidx = if (str_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), str_index_vals.items) else 0;
    const nidx = if (num_index_vals.items.len > 0) try c.ts.makeUnion(c.scratch(), num_index_vals.items) else 0;
    return c.ts.makeObject(props.items, sidx, nidx, 0);
}

/// TS2307 for `import x = require("missing")` written inside a PLAIN namespace,
/// reported at the first READ of the alias.
///
/// The link phase declines that specifier on purpose (`reportUnresolvedIn`): an
/// import naming a module in a namespace body is a grammar error (TS1147), and
/// tsc's `checkExternalImportOrExportDeclaration` returns before resolving it,
/// so a TS2307 at the declaration would be a cascade tsc does not emit. What
/// tsc *does* do is resolve the alias when something reads it (`resolveAlias`)
/// and report there — measured: the same declaration with no use of `x` earns
/// TS1147 alone, and with a use earns both, at the specifier either way
/// (`importInsideModule`). Reads after the first are deduplicated by span.
fn reportNamespaceRequireMiss(c: *Checker, sym: SymbolId) Error!void {
    // `diagFmt` files against the CURRENT file, and the scope/declaration
    // lookups below read the current file's tables: a demand that has not
    // entered the alias's own file says nothing rather than the wrong thing.
    if (c.symFile(sym) != c.cur_file) return;
    if (!plainNamespaceScope(c, c.symScope(sym))) return;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .import_equals) continue;
        const e = c.tree.extraData(ast.ImportEquals, c.tree.nodeData(decl).lhs);
        if (e.module_token == 0) continue;
        try c.reportModuleNotFound(e.module_token);
    }
}

/// Is `scope` the body of a plain `namespace`/`module` block — as opposed to a
/// file's top level or a `declare module "spec"` / `declare global` block,
/// which are ambient MODULES and do take module syntax? The binder's
/// `inPlainNamespaceBody` asks the same question of its unsealed arrays.
fn plainNamespaceScope(c: *const Checker, scope: binder.ScopeId) bool {
    if (scope == binder.file_scope) return false;
    if (c.bind.scope_kinds[scope] != .namespace) return false;
    const owner = c.bind.scope_owners[scope];
    if (owner == null_node or c.tree.nodeTag(owner) != .namespace_decl) return false;
    const data = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(owner).lhs);
    return data.flags & (ast.Flags.ambient_module | ast.Flags.global_aug) == 0;
}

/// The VALUE half of a `.dual` binding, or null when it turns out not to exist.
///
/// Only the `export =` flavour of a dual can miss: its value half is the
/// *question* "property `name` of the export-assigned value's type", which the
/// link phase could not answer. Every other value half (the module namespace
/// object of an `export * as X` merged with a local `export type X`, a plain
/// declaration) is a resolved target and always has a type.
pub fn dualValueType(c: *Checker, d: modules.DualTarget) Error!?TypeId {
    const v = d.value_tgt;
    if (v.kind != .export_equals_prop) return try c.targetValueType(v);
    const base = try c.typeOfSymbol(c.toGlobalIn(v.file, v.payload));
    const p = (try c.propOfType(base, v.name)) orelse return null;
    return p.ty;
}

/// True when a `.dual` binding really does have a value meaning through its
/// export-assigned value's type. Lets a value-position reference decide
/// between "both meanings" and "type meaning only" (TS2693).
pub fn dualHasValue(c: *Checker, tgt: modules.Target) Error!bool {
    if (tgt.kind != .dual) return false;
    return (try c.dualValueType(c.prog.dual_targets[tgt.payload])) != null;
}

pub fn targetValueType(c: *Checker, tgt: modules.Target) Error!TypeId {
    switch (tgt.kind) {
        .any => return types.any_type,
        // A link target names the DECLARATION the export table recorded, but a
        // cross-file `declare module` augmentation may since have merged that
        // declaration with others. tsc has one symbol per entity after merging,
        // so the value type must be the MERGED one whichever spelling reached
        // here: `import { Observable }` (a raw `(file, local)` target) and
        // `import * as O` (which routes through `mergedOf` in
        // `namespaceObjectType`) have to agree.
        .binding => {
            const g = c.toGlobalIn(tgt.file, tgt.payload);
            return c.typeOfSymbol(c.prog.mergedOf(g) orelse g);
        },
        .namespace => return c.namespaceObjectType(tgt.file),
        .ambient_ns => return c.ambientNamespaceType(tgt.payload),
        // `import { X } from "m"` where `m` is `export = <value>` and `X`
        // is a property of that value's TYPE. A missing property stays
        // `any` (the link phase could not have known, and the lenient
        // fallback it replaces was `any` too).
        .export_equals_prop => {
            const base = try c.typeOfSymbol(c.toGlobalIn(tgt.file, tgt.payload));
            const p = (try c.propOfType(base, tgt.name)) orelse return types.any_type;
            return p.ty;
        },
        // Both meanings available (tsc's `combineValueAndTypeSymbols`): the
        // VALUE meaning is the property of the export-assigned value's type.
        // The link phase could not check that the property exists, so a miss
        // falls back to the member's own value meaning — which is what the
        // binding resolved to before the dual existed.
        .dual => {
            const d = c.prog.dual_targets[tgt.payload];
            if (try c.dualValueType(d)) |t| return t;
            return c.targetValueType(d.type_tgt);
        },
        .default_expr => {
            const saved = c.saveCtx();
            defer c.restoreCtx(saved);
            c.setFile(tgt.file);
            c.cur_scope = binder.file_scope;
            const inner = c.tree.nodeData(tgt.payload).lhs;
            switch (c.nodeTag(inner)) {
                .function_decl => return c.signatureOfProto(inner, c.tree.nodeData(inner).lhs, false, true),
                // An UNNAMED `export default class {}` has no name to look up
                // in the file scope, but the binder still declares it in the
                // class's OWN scope under the reserved class-expression key —
                // which is exactly what `classSymbolOf` asks for a class
                // expression, and what makes the export a class value rather
                // than the `any` that accepted everything and could not be
                // TS2511 (`newAbstractInstance2`).
                .class_decl => {
                    const sym = try c.classSymbolOf(inner, binder.file_scope);
                    if (sym == binder.no_symbol) return types.any_type;
                    return c.typeOfSymbol(sym);
                },
                else => return c.widenLiteral(try c.checkExprCached(inner, types.no_type)),
            }
        },
    }
}

/// The module namespace object of `file` (`import * as ns`): one
/// read-only property per value-space export. Type-space-only exports
/// (interfaces, aliases, `export type`) are omitted — accessing them
/// as values is a property error, close to tsc's behavior. Cycle-safe.
pub fn namespaceObjectType(c: *Checker, file: FileId) Error!TypeId {
    if (c.ns_types.get(file)) |t| {
        if (t == types.no_type) return types.any_type; // ns cycle
        return t;
    }
    try c.ns_types.put(c.cm(), file, types.no_type);
    // `export = X` module (e.g. `@types/react` `export = React`): the value
    // namespace object is the value type of the export-equals target, not an
    // empty object built from the (absent) named exports. `typeof
    // import("react").createContext` must reach React's members.
    if (c.prog.links.len != 0) {
        if (c.prog.links[file].exportTarget(c.prog.export_equals_atom)) |eq| {
            if (!eq.type_only) {
                const t = try c.targetValueType(eq);
                try c.ns_types.put(c.cm(), file, t);
                return t;
            }
        }
    }
    // A file that is a SCRIPT has no module symbol to import FROM: tsc's
    // `resolveExternalModuleName` finds no `sourceFile.symbol`, reports TS2306
    // at the specifier (`link/modules.zig` does the same) and binds nothing, so
    // every read through the alias is the ERROR type rather than a member of an
    // empty object. Answering `{}` instead turned `import foo = require("./
    // script"); foo.answer` into a TS2339 on top of the TS2306 tsgo reports
    // alone (`importNonExternalModule`). A synthetic JSON/JS any-module is not a
    // script — it carries `export =` and never sees a binder — and is excluded
    // here exactly as it is at the report site.
    if (c.prog.links.len != 0 and !c.prog.files[file].bind.is_module and
        paths.anyModuleSourceFor(c.prog.files[file].path) == null)
    {
        try c.ns_types.put(c.cm(), file, types.error_type);
        return types.error_type;
    }
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (c.prog.links.len != 0) {
        const l = &c.prog.links[file];
        for (l.export_atoms, l.export_targets) |name, tgt| {
            if (name == c.prog.export_equals_atom) continue; // reserved key
            if (tgt.type_only) continue;
            var ty: TypeId = types.any_type;
            switch (tgt.kind) {
                .binding => {
                    const g0 = c.toGlobalIn(tgt.file, tgt.payload);
                    // A cross-file `declare module` augmentation may have
                    // merged this export (`namespace control` + a plugin's
                    // `namespace control { sideBySide }`): use the merged
                    // view so `L.control.sideBySide` resolves.
                    const g = c.prog.mergedOf(g0) orelse g0;
                    if (!bindingHasValue(c, g)) continue;
                    ty = try c.typeOfSymbol(g);
                },
                .namespace => ty = try c.namespaceObjectType(tgt.file),
                .ambient_ns => ty = try c.ambientNamespaceType(tgt.payload),
                .default_expr, .export_equals_prop => ty = try c.targetValueType(tgt),
                // A re-exported dual contributes to the namespace object
                // through its value half. Without one it falls back to the
                // member, which — being a type-only interface in the shape
                // that motivates duals — is then omitted like any other.
                .dual => {
                    const d = c.prog.dual_targets[tgt.payload];
                    if (try c.dualValueType(d)) |vt| {
                        ty = vt;
                    } else if (c.targetTypeSym(d.type_tgt)) |g| {
                        if (!bindingHasValue(c, g)) continue;
                        ty = try c.typeOfSymbol(g);
                    } else {
                        ty = try c.targetValueType(d.type_tgt);
                    }
                },
                .any => {},
            }
            try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
        }
    }
    // Cross-package `declare module "M" { const drawLocal … }` value
    // augmentations add fresh exports to M's namespace object that have no
    // constituent in M's own export table (so no merge formed). Fold them
    // in: `import L from "leaflet"; L.drawLocal` (leaflet-draw augments
    // leaflet). Members already present as a real export are skipped (those
    // merge through the export-table path above).
    try c.appendAugmentedModuleExports(file, &props);
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.ns_types.put(c.cm(), file, obj);
    return obj;
}

/// Append value-space members contributed by cross-file `declare module`
/// augmentation blocks whose specifier resolves to `file`, for names not
/// already collected. Deterministic: files then block members in id order.
pub fn appendAugmentedModuleExports(c: *Checker, file: FileId, props: *std.ArrayList(types.Prop)) Error!void {
    for (c.prog.files, 0..) |*pf, fi| {
        const b = pf.bind;
        if (!b.is_module or b.ambient_modules.len == 0) continue;
        const base = c.prog.sym_base[fi];
        for (b.ambient_modules) |am| {
            const mfile = pf.specs.get(am.spec) orelse continue;
            if (mfile != file) continue;
            const lo = b.scope_members_start[am.scope];
            const hi = b.scope_members_start[am.scope + 1];
            for (lo..hi) |i| {
                const g = base + b.member_syms[i];
                const f = c.symFlags(g);
                if (!hasValueMeaning(f)) continue;
                const name = b.member_atoms[i];
                var dup = false;
                for (props.items) |p| {
                    if (p.name == name) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                var flags: u32 = types.prop_flag_readonly;
                if (!f.const_decl and !f.readonly_member) flags = 0;
                try props.append(c.scratch(), .{
                    .name = name,
                    .ty = try c.typeOfSymbol(c.prog.mergedOf(g) orelse g),
                    .flags = flags,
                });
            }
        }
    }
}

/// Namespace object of an ambient module (`import * as ns from "fs"`):
///  one read-only property per value-space export. Cycle-safe via
/// `ambient_ns_types`.
pub fn ambientNamespaceType(c: *Checker, idx: u32) Error!TypeId {
    if (c.ambient_ns_types.get(idx)) |t| {
        if (t == types.no_type) return types.any_type; // cycle
        return t;
    }
    try c.ambient_ns_types.put(c.cm(), idx, types.no_type);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    const ae = c.prog.ambient_exports[idx];
    // An ambient module with NO named exports is opaque, not empty: it is the
    // shorthand `declare module "m";` (every export `any`) or a block that uses
    // `export =` / the ambient auto-export rule, both out of subset. The linker
    // already answers `any` for a STATIC `import * as ns from "m"` there
    // (`ambientOpaque`); answering an empty object here made the same module
    // read as `{}` through `import("m")`, so `(await import("fs")).readFile` was
    // a false TS2339 while the static form was clean.
    if (ae.atoms.len == 0) {
        try c.ambient_ns_types.put(c.cm(), idx, types.any_type);
        return types.any_type;
    }
    for (ae.atoms, ae.targets) |name, tgt| {
        if (name == c.prog.export_equals_atom) continue; // reserved key
        if (tgt.type_only) continue;
        if (tgt.kind == .binding) {
            const g0 = c.toGlobalIn(tgt.file, tgt.payload);
            if (!bindingHasValue(c, c.prog.mergedOf(g0) orelse g0)) continue;
        }
        const ty = try c.targetValueType(tgt);
        try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
    }
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.ambient_ns_types.put(c.cm(), idx, obj);
    return obj;
}

/// `typeof globalThis` — the global-scope object. A single interned marker
/// object with no stored properties; `propOfTypeEx` resolves its members
/// against `prog.globals` on demand. See `types.obj_flag_global_this`.
///
/// Materializing the members eagerly is not an option: the program's merged
/// global value table is thousands of names deep with a full lib, and it is
/// self-referential (`declare var window: Window & typeof globalThis`), so
/// any eager fold would have to break the cycle at whichever point it was
/// first triggered — making `window`'s type depend on traversal order and
/// so on the checker count. Lazy lookup has neither problem.
pub fn globalThisType(c: *Checker) Error!TypeId {
    if (c.global_this_ty == types.no_type) {
        c.global_this_ty = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_global_this | types.obj_flag_not_inferable);
    }
    return c.global_this_ty;
}

/// A member of the global scope object: a program-global *var*, *function*,
/// *namespace* or `declare module` value (`prog.globals`, the same table the
/// bare-name fallback in `resolveSpace` consults).
///
/// BLOCK-SCOPED globals are deliberately excluded. A global `const` / `let`
/// / `class` / `enum` is in lexical scope but is not a property of the
/// global object, and tsc reports exactly that — `globalThis.someConst` is
/// TS2339 while the bare `someConst` resolves (oracle-verified against the
/// pinned tsgo). Type-space-only globals (`interface Window`) are not
/// members either; those are the `globalThisHasValue` = false case, which
/// the access site turns into TS7017 rather than TS2339.
pub fn globalThisProp(c: *Checker, name: Atom) Error!?types.Prop {
    const sym = c.prog.globals.lookup(name) orelse return null;
    const f = c.symFlags(sym);
    if (!hasValueMeaning(f)) return null;
    if (f.const_decl or f.let_decl or f.class or f.enum_decl) return null;
    const flags: u32 = if (f.readonly_member) types.prop_flag_readonly else 0;
    return .{ .name = name, .ty = try c.typeOfSymbol(sym), .flags = flags };
}

/// Whether `name` names a program global with VALUE meaning at all —
/// block-scoped or not. Distinguishes tsc's two failure messages on
/// `globalThis.x`: a known-but-block-scoped global is TS2339 ("Property 'x'
/// does not exist"), an entirely unknown name is TS7017 (the implicit-any
/// index message).
pub fn globalThisHasValue(c: *Checker, name: Atom) bool {
    const sym = c.prog.globals.lookup(name) orelse return false;
    return hasValueMeaning(c.symFlags(sym));
}
