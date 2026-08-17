//! TS2440: an import alias whose TARGET carries a meaning the alias's own name
//! already declares locally — tsc's `checkAliasSymbol`.
//!
//! The check cannot live in the binder, which is where the diagnostic used to
//! come from: the verdict is about the meanings of the alias's *target*, and
//! the target is in another file (or behind an entity name the binder does not
//! resolve). `import a = M` where `M` is a type-only namespace declares nothing
//! in value space and clashes with a `var a` not at all, while `import { N }
//! from "./f1"` beside a local `namespace N` DOES clash when f1's `N` is an
//! instantiated namespace — two shapes a syntactic guess gets backwards.
//!
//! tsc's rule, spelled out (`checkAliasSymbol`):
//!
//!     excludedMeanings = the meanings the alias's own NAME declares
//!                        (Value / Type / Namespace — the alias bit itself
//!                         is in none of the three)
//!     error iff resolveAlias(symbol).flags & excludedMeanings
//!
//! so an alias that merged with nothing (the overwhelming majority) is silent
//! without the target ever being resolved — which is what keeps this a
//! flag test per symbol over the file's symbol table.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const modules = @import("../link/modules.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const SymbolFlags = binder.SymbolFlags;
const TokenIndex = ast.TokenIndex;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's three declaration meanings (`SymbolFlags.Value` / `.Type` /
/// `.Namespace`). A symbol spans any subset of them; the conflict is a
/// non-empty intersection between the alias name's own set and its target's.
const Meanings = packed struct(u3) {
    value: bool = false,
    type_space: bool = false,
    namespace: bool = false,

    fn bits(m: Meanings) u3 {
        return @bitCast(m);
    }
    fn empty(m: Meanings) bool {
        return m.bits() == 0;
    }
    fn overlaps(a: Meanings, b: Meanings) bool {
        return a.bits() & b.bits() != 0;
    }
};

/// The meanings a symbol's declarations occupy. The `import_binding` bit
/// contributes none of the three — tsc's `SymbolFlags.Alias` is outside
/// `Value`, `Type` and `Namespace` alike, which is precisely why an alias
/// merges with everything and needs this check instead of an excludes mask.
///
/// A non-instantiated namespace is tsc's `NamespaceModule`: `Namespace`
/// meaning without `Value` (`namespace M {}` beside `var a; import a = M` is
/// the whole of `duplicateVarAndImport`).
fn meaningsOf(f: SymbolFlags) Meanings {
    return .{
        .value = f.var_decl or f.let_decl or f.const_decl or f.function or
            f.class or f.param or f.catch_param or f.enum_decl or f.enum_member or
            f.property or f.method or f.getter or f.setter or f.expando_member or
            (f.namespace_decl and !f.ns_uninstantiated),
        .type_space = f.class or f.interface or f.type_alias or f.type_param or
            f.enum_decl or f.enum_member,
        .namespace = f.namespace_decl or f.enum_decl,
    };
}

/// Report TS2440 for every alias of the current file whose target's meanings
/// collide with the ones its name declares. Runs once per owned file, after
/// the statement walk (position order is restored by `seal`'s sort); the
/// candidate list is the binder's and is empty for almost every file.
pub fn checkFileAliases(c: *Checker) Error!void {
    for (c.prog.files[c.cur_file].bind.alias_merges) |m| {
        const declared = meaningsOf(m.flags);
        if (declared.empty()) continue;
        const sym = c.toGlobal(m.sym);
        const target = (try targetMeanings(c, sym, m.decl, max_hops)) orelse continue;
        if (!declared.overlaps(target)) continue;
        try c.diagFmt(2440, c.tokSpan(m.tok), "Import declaration conflicts with local declaration of '{s}'.", .{c.atomText(c.symNameAtom(sym))});
    }
}

/// How many aliases `resolveAlias` chases before giving up. A re-export chain
/// is a handful of hops at most; the bound is what makes a CYCLE terminate.
const max_hops = 8;

/// The meanings of `resolveAlias(sym)`, or null when the target does not
/// resolve — tsc's `target !== unknownSymbol` guard, which is why an import of
/// a name the module does not export (`import d, { x } from "./m"`) earns
/// TS2305 alone and never TS2440 on top.
///
/// An alias of an alias resolves to what the *last* one names, and only that:
/// `import Q = r.Q` where `r.Q` is itself `export import Q = q.Q` merged with
/// an `export type Q` has the const `q.Q`'s meanings, not the intermediate
/// symbol's (`shadowedInternalModule`).
fn targetMeanings(c: *Checker, sym: SymbolId, decl: Node, hops: u8) Error!?Meanings {
    if (hops == 0) return null;
    if (c.importTarget(sym)) |t| {
        return switch (t.kind) {
            // Unresolved: the diagnostic for it was already issued elsewhere.
            .any => null,
            .binding => try symMeanings(c, c.toGlobalIn(t.file, t.payload), hops - 1),
            // Everything else is a module or a member of one: a source file's
            // own symbol is tsc's `ValueModule` (value *and* namespace
            // meaning), and an `export =`/default value is a value.
            .namespace, .ambient_ns => .{ .value = true, .namespace = true },
            .default_expr, .export_equals_prop => .{ .value = true },
            .dual => .{ .value = true, .type_space = true },
        };
    }
    // The ENTITY-NAME form (`import x = A.B`) has no link record: its target
    // is resolved in the ALIAS's own file and scope, which a chased hop is no
    // longer in, as tsc's `resolveEntityName` resolves it.
    if (c.nodeTag(decl) != .import_equals) return null;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    const e = c.tree.extraData(ast.ImportEquals, c.tree.nodeData(decl).lhs);
    if (e.module_token != 0 or e.entity == null_node) return null;
    const target = (try entitySym(c, e.entity)) orelse return null;
    return try symMeanings(c, target, hops - 1);
}

/// The meanings a resolved target contributes — its own, unless it is itself
/// an alias, in which case tsc's `resolveAlias` keeps walking.
fn symMeanings(c: *Checker, sym0: SymbolId, hops: u8) Error!?Meanings {
    const sym = c.prog.mergedOf(sym0) orelse sym0;
    const f = c.symFlags(sym);
    if (!f.import_binding) return meaningsOf(f);
    const decl = aliasDecl(c, sym) orelse return meaningsOf(f);
    return try targetMeanings(c, sym, decl, hops);
}

/// The alias declaration of `sym`. A symbol with two of them is a duplicate
/// identifier, already reported; the first wins.
fn aliasDecl(c: *Checker, sym: SymbolId) ?Node {
    const tree = c.prog.files[c.symFile(sym)].tree;
    for (c.declsOf(sym)) |d| {
        switch (tree.nodeTag(d)) {
            .import_decl, .import_specifier, .import_equals => return d,
            else => {},
        }
    }
    return null;
}

/// The symbol an `import x = <entity>` right-hand side names, or null when it
/// resolves to nothing this checker can see (silence, not a guess).
fn entitySym(c: *Checker, entity: Node) Error!?SymbolId {
    switch (c.nodeTag(entity)) {
        .identifier => {
            const tok = c.tree.nodeMainToken(entity);
            if (c.tree.tokens.tag(tok) != .identifier) return null;
            const a = try c.atomOfToken(tok);
            // tsc resolves the root in every meaning at once; ztsc asks one
            // space at a time, and a name that is a container answers first
            // (`import M = Z.M` next to an `interface M` must find `Z`, not
            // the interface).
            if (found(c.resolveNamespaceSpace(a, c.cur_scope))) |s| return s;
            if (found(c.resolveSpace(a, c.cur_scope, true))) |s| return s;
            if (found(c.resolveSpace(a, c.cur_scope, false))) |s| return s;
            return null;
        },
        .qualified_name, .member_expr => {
            const d = c.tree.nodeData(entity);
            const outer = (try c.resolveNsContainer(d.lhs)) orelse return null;
            const name = try c.memberAtom(d.rhs);
            return c.containerMemberSym(outer, name);
        },
        else => return null,
    }
}

/// The symbol a lookup landed on, or null for "found nothing here" and for a
/// name found in the WRONG space (which is not this check's business).
fn found(r: Checker.Resolved) ?SymbolId {
    return switch (r) {
        .sym => |s| s,
        else => null,
    };
}
