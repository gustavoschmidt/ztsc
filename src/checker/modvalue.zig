//! The VALUE meaning of a module reference: what an import binding, a
//! namespace object (`import * as ns`), or a link-table target types as.
//!
//! Everything here reads the sealed link tables rather than the syntax, so it
//! is the checker's side of `link/modules.zig`: one function per target kind,
//! plus the two cycle-safe namespace-object caches and the `declare module`
//! augmentations that fold extra exports into them.

const std = @import("std");
const binder = @import("../frontend/binder.zig");
const modules = @import("../link/modules.zig");
const types = @import("../types.zig");

const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const FileId = checker_zig.FileId;

const hasValueMeaning = @import("names.zig").hasValueMeaning;

/// Value type of an import binding, via the sealed link tables.
pub fn importedSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const tgt = c.importTarget(sym) orelse return types.any_type; // unlinked
    return c.targetValueType(tgt);
}

/// The VALUE half of a `.dual` binding: property `name` of the export-assigned
/// value's type, or null when that value's type has no such property (the
/// binding then has only the meanings its `type_tgt` carries).
pub fn dualValueType(c: *Checker, d: modules.DualTarget) Error!?TypeId {
    const v = d.value_tgt;
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
        .binding => return c.typeOfSymbol(c.toGlobalIn(tgt.file, tgt.payload)),
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
                // Unnamed `export default class`: documented cut.
                .class_decl => return types.any_type,
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
                    const f = c.symFlags(g);
                    if (!hasValueMeaning(f)) continue;
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
                        if (!hasValueMeaning(c.symFlags(g))) continue;
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
    for (ae.atoms, ae.targets) |name, tgt| {
        if (name == c.prog.export_equals_atom) continue; // reserved key
        if (tgt.type_only) continue;
        const ty = try c.targetValueType(tgt);
        try props.append(c.scratch(), .{ .name = name, .ty = ty, .flags = types.prop_flag_readonly });
    }
    const obj = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.ambient_ns_types.put(c.cm(), idx, obj);
    return obj;
}
