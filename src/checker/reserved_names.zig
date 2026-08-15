//! The predefined type names a declaration may not take, tsc's
//! `checkTypeNameIsReserved` (plus the one name that gets its own wording,
//! `undefined` on a namespace — `checkCollisionWithGlobalPromiseName`'s
//! neighbour `checkCollisionWithRequireExportsInGeneratedCode` family).
//!
//! `type any = …` is not a redeclaration of anything — `any` is a KEYWORD in
//! type position, not a symbol — so no duplicate-identifier rule catches it;
//! tsc has a rule of its own, one message per declaration form, and reports it
//! on the name. The four forms differ only in wording, so they are one function
//! over the declaration node.

const std = @import("std");
const ast = @import("../frontend/ast.zig");

const Node = ast.Node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

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
const Form = enum { class, interface, type_alias, @"enum", namespace };

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
    if (form == .namespace) {
        if (!std.mem.eql(u8, name, "undefined")) return;
        try c.diagFmt(2397, c.tokSpan(name_token), "Declaration name conflicts with built-in global identifier '{s}'.", .{name});
        return;
    }
    switch (form) {
        .class => try c.diagFmt(2414, c.tokSpan(name_token), "Class name cannot be '{s}'.", .{name}),
        .interface => try c.diagFmt(2427, c.tokSpan(name_token), "Interface name cannot be '{s}'.", .{name}),
        .type_alias => try c.diagFmt(2457, c.tokSpan(name_token), "Type alias name cannot be '{s}'.", .{name}),
        .@"enum" => try c.diagFmt(2431, c.tokSpan(name_token), "Enum name cannot be '{s}'.", .{name}),
        .namespace => unreachable,
    }
}
