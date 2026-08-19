//! The predefined type names a declaration may not take, tsc's
//! `checkTypeNameIsReserved` (plus the one name that gets its own wording,
//! `undefined` on a namespace — `checkCollisionWithGlobalPromiseName`'s
//! neighbour `checkCollisionWithRequireExportsInGeneratedCode` family).
//!
//! `type any = …` is not a redeclaration of anything — `any` is a KEYWORD in
//! type position, not a symbol — so no duplicate-identifier rule catches it;
//! tsc has a rule of its own, one message per declaration form, and reports it
//! on the name. The forms differ only in wording, so they are one function over
//! the declaration node — except the import alias, whose rule additionally
//! depends on what its target MEANS (see the `.import_equals` arm).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");

const Node = ast.Node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const alias_conflict = @import("alias_conflict.zig");

/// tsc's list in `checkTypeNameIsReserved`, restricted to the names that ztsc's
/// parser accepts as a declaration name at all: every predefined type name is a
/// CONTEXTUAL keyword except `void` and `null`, which are reserved words and so
/// never reach a name position (tsc answers a syntactic TS1109 for `type void =
/// 1` and then TS2457 in the same program — a shape ztsc's suppression model
/// cannot reproduce, and one no corpus case needs).
const reserved = [_][]const u8{
    "any",     "unknown", "never",  "number", "bigint",
    "boolean", "string",  "symbol", "object", "undefined",
};

/// The declaration form a name belongs to, if this statement declares a type
/// name at all. tsc words the message per form.
const Form = enum { class, interface, type_alias, @"enum", namespace, import_equals };

/// One statement: if it declares a type name that is a predefined type name,
/// report it. A no-op for every other statement, which is why the whole rule is
/// one call at the top of the statement walk.
pub fn checkDeclName(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const form: Form, const name_token: ast.TokenIndex = switch (c.nodeTag(node)) {
        .class_decl => .{ .class, c.tree.extraData(ast.ClassData, d.lhs).name_token },
        .interface_decl => .{ .interface, c.tree.extraData(ast.InterfaceData, d.lhs).name_token },
        .type_alias => .{ .type_alias, c.tree.extraData(ast.TypeAlias, d.lhs).name_token },
        .enum_decl => .{ .@"enum", c.tree.extraData(ast.EnumData, d.lhs).name_token },
        .namespace_decl => .{ .namespace, c.tree.extraData(ast.NamespaceData, d.lhs).name_token },
        .import_equals => .{ .import_equals, c.tree.extraData(ast.ImportEquals, d.lhs).name_token },
        else => return,
    };
    if (name_token == 0) return;
    const name = c.tokenText(name_token);
    var hit = false;
    for (reserved) |r| {
        if (std.mem.eql(u8, r, name)) {
            hit = true;
            break;
        }
    }
    if (!hit) return;
    // A NAMESPACE is only reported for `undefined`, and with tsc's other
    // wording: `namespace any {}` is legal (it declares a value, and `any` is
    // only a keyword in type position), while `namespace undefined {}` shadows
    // the global `undefined` VALUE. Measured, both ways.
    //
    // "Shadows the global" is the whole rule, so it takes a declaration that IS
    // in the global scope: the file's top level, and only when the file is not a
    // module (a module's top level is its own scope, and a nested namespace is
    // never global). `typeNamedUndefined2.ts` — `export namespace undefined` in
    // a module, twice — is silent in tsgo, and `namespace N { namespace
    // undefined {} }` is too.
    if (form == .namespace) {
        if (!std.mem.eql(u8, name, "undefined")) return;
        if (c.cur_scope != binder.file_scope) return;
        if (c.bind.imports.len != 0 or c.bind.exports.len != 0) return;
        try c.diagFmt(2397, c.tokSpan(name_token), "Declaration name conflicts with built-in global identifier '{s}'.", .{name});
        return;
    }
    // An import ALIAS is only reported when its TARGET has type meaning: tsc
    // guards `checkTypeNameIsReserved(node.name, Import_name_cannot_be_0)` on
    // `target.flags & SymbolFlags.Type` (`checkImportEqualsDeclaration`, right
    // beside the TS2437 `typespace.zig` reports from the `Value` half of the
    // same pair). `import any = <a value>` is legal — `any` is a keyword in
    // TYPE position only, so an alias that names nothing in type space never
    // puts the keyword anywhere it could be read as one. That guard is why
    // wave-20's 11-name probe over value targets was all-silent.
    //
    // Every name in the list counts, `undefined` included — the whole list is
    // oracle-measured here (`import undefined = <a type alias>` is TS2438 in
    // tsgo, while the same alias of a const, of a namespace, or of a
    // value-only namespace member is silent).
    if (form == .import_equals) {
        const e = c.tree.extraData(ast.ImportEquals, c.tree.nodeData(node).lhs);
        if (e.module_token != 0 or e.entity == ast.null_node) return;
        if (!try alias_conflict.entityTargetHasTypeMeaning(c, e.entity)) return;
        try c.diagFmt(2438, c.tokSpan(name_token), "Import name cannot be '{s}'.", .{name});
        return;
    }
    switch (form) {
        .class => try c.diagFmt(2414, c.tokSpan(name_token), "Class name cannot be '{s}'.", .{name}),
        .interface => try c.diagFmt(2427, c.tokSpan(name_token), "Interface name cannot be '{s}'.", .{name}),
        .type_alias => try c.diagFmt(2457, c.tokSpan(name_token), "Type alias name cannot be '{s}'.", .{name}),
        .@"enum" => try c.diagFmt(2431, c.tokSpan(name_token), "Enum name cannot be '{s}'.", .{name}),
        .namespace, .import_equals => unreachable,
    }
}
