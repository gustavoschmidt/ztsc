//! S-expression dump of a parsed `Ast` (`--dump-ast`, parser golden tests).
//!
//! Split out of ast.zig because it is pure presentation: it reads the tree
//! through the public accessors only (`nodeTag`, `nodeData`, `extraData`,
//! `tokenSlice`, `childIterator`) and nothing in the front end or the checker
//! depends on it. `Ast.dump` forwards here.

const std = @import("std");
const ast = @import("ast.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const Flags = ast.Flags;
const DeclaratorFull = ast.DeclaratorFull;
const Field = ast.Field;
const ParamFull = ast.ParamFull;
const FnProto = ast.FnProto;
const ClassData = ast.ClassData;
const EnumData = ast.EnumData;
const NamespaceData = ast.NamespaceData;
const InterfaceData = ast.InterfaceData;
const ImportData = ast.ImportData;
const ExportNamed = ast.ExportNamed;
const ExportAll = ast.ExportAll;
const TypeAlias = ast.TypeAlias;
const IndexSig = ast.IndexSig;
const ImportEquals = ast.ImportEquals;

/// Render `node` as an S-expression: `(tag[ :flags][ text] children...)`.
/// Leaf literal/identifier nodes render as `(tag text)`; operator nodes
/// include the operator text; nodes with modifiers include `:flag`s.
pub fn dump(a: *const Ast, src: []const u8, w: *std.Io.Writer, node: Node) std.Io.Writer.Error!void {
    const tag = a.nodeTag(node);
    const d = a.nodeData(node);
    try w.print("({s}", .{@tagName(tag)});

    // Flags, where the node stores them.
    const flags: u32 = switch (tag) {
        .declarator_full => a.extraData(DeclaratorFull, d.rhs).flags,
        .class_field => a.extraData(Field, d.lhs).flags,
        .param_full => a.extraData(ParamFull, d.rhs).flags,
        .arrow_fn, .function_expr, .function_decl, .class_method, .function_type, .method_signature, .call_signature, .construct_signature, .constructor_type => a.extraData(FnProto, d.lhs).flags,
        .class_decl => a.extraData(ClassData, d.lhs).flags,
        .enum_decl => a.extraData(EnumData, d.lhs).flags,
        .namespace_decl => a.extraData(NamespaceData, d.lhs).flags,
        .interface_decl => a.extraData(InterfaceData, d.lhs).flags,
        .property_signature, .index_signature, .import_specifier, .export_specifier => d.rhs,
        .import_decl => a.extraData(ImportData, d.lhs).flags,
        .export_named => a.extraData(ExportNamed, d.lhs).flags,
        .export_all => a.extraData(ExportAll, d.lhs).flags,
        else => 0,
    };
    try dumpFlags(w, flags);

    // Identity text: main-token text for leaves/operators, name tokens
    // for declarations, member names, labels.
    switch (tag) {
        .identifier,
        .number_literal,
        .string_literal,
        .bigint_literal,
        .regex_literal,
        .template_literal,
        .binary,
        .assign,
        .prefix_unary,
        .postfix_unary,
        .object_shorthand,
        .binding_property,
        .type_param,
        .labeled_stmt,
        .property_signature,
        .enum_member,
        .class_field,
        .class_method,
        .method_signature,
        .import_specifier,
        .export_specifier,
        .var_decl_one,
        .var_decl,
        => try w.print(" {s}", .{a.tokenSlice(src, a.nodeMainToken(node))}),
        .member_expr, .optional_member_expr, .qualified_name => {},
        .function_decl, .function_expr => {
            const name_tok = a.extraData(FnProto, d.lhs).name_token;
            if (name_tok != 0) try w.print(" {s}", .{a.tokenSlice(src, name_tok)});
        },
        .class_decl => {
            const name_tok = a.extraData(ClassData, d.lhs).name_token;
            if (name_tok != 0) try w.print(" {s}", .{a.tokenSlice(src, name_tok)});
        },
        .interface_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(InterfaceData, d.lhs).name_token)}),
        .type_alias => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(TypeAlias, d.lhs).name_token)}),
        .enum_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(EnumData, d.lhs).name_token)}),
        .namespace_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(NamespaceData, d.lhs).name_token)}),
        .break_stmt, .continue_stmt => {
            if (d.lhs != 0) try w.print(" {s}", .{a.tokenSlice(src, d.lhs)});
        },
        .index_signature => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(IndexSig, d.lhs).name_token)}),
        .import_decl => {
            const e = a.extraData(ImportData, d.lhs);
            if (e.default_name_token != 0) try w.print(" default={s}", .{a.tokenSlice(src, e.default_name_token)});
            if (e.ns_name_token != 0) try w.print(" ns={s}", .{a.tokenSlice(src, e.ns_name_token)});
            if (d.rhs != 0) try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
        },
        .export_named => {
            if (d.rhs != 0) try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
        },
        .export_all => {
            const e = a.extraData(ExportAll, d.lhs);
            if (e.name_token != 0) try w.print(" ns={s}", .{a.tokenSlice(src, e.name_token)});
            try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
        },
        .import_equals => {
            const e = a.extraData(ImportEquals, d.lhs);
            try w.print(" {s}", .{a.tokenSlice(src, e.name_token)});
            if (e.module_token != 0) try w.print(" require={s}", .{a.tokenSlice(src, e.module_token)});
        },
        .yield_expr => {
            if (d.rhs != 0) try w.writeAll(" *");
        },
        .unsupported => try w.print(" tokens={d}..{d}", .{ a.nodeMainToken(node), d.rhs }),
        .import_type => try w.print(" {s}", .{a.tokenSlice(src, d.lhs)}),
        else => {},
    }

    // Alias tokens on specifiers.
    switch (tag) {
        .import_specifier, .export_specifier => {
            if (d.lhs != 0) try w.print(" as={s}", .{a.tokenSlice(src, d.lhs)});
        },
        else => {},
    }

    var it = a.childIterator(node);
    while (it.next()) |child| {
        try w.writeAll(" ");
        try dump(a, src, w, child);
    }

    // Member/qualified name text goes after the object child.
    switch (tag) {
        .member_expr, .optional_member_expr, .qualified_name => {
            try w.print(" {s}", .{a.tokenSlice(src, d.rhs)});
        },
        else => {},
    }

    try w.writeAll(")");
}

fn dumpFlags(w: *std.Io.Writer, flags: u32) std.Io.Writer.Error!void {
    const names = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = Flags.async, .name = "async" },
        .{ .bit = Flags.generator, .name = "generator" },
        .{ .bit = Flags.declare, .name = "declare" },
        .{ .bit = Flags.static, .name = "static" },
        .{ .bit = Flags.public, .name = "public" },
        .{ .bit = Flags.private, .name = "private" },
        .{ .bit = Flags.protected, .name = "protected" },
        .{ .bit = Flags.readonly, .name = "readonly" },
        .{ .bit = Flags.abstract, .name = "abstract" },
        .{ .bit = Flags.override, .name = "override" },
        .{ .bit = Flags.optional, .name = "optional" },
        .{ .bit = Flags.definite, .name = "definite" },
        .{ .bit = Flags.get, .name = "get" },
        .{ .bit = Flags.set, .name = "set" },
        .{ .bit = Flags.type_only, .name = "type" },
        .{ .bit = Flags.rest, .name = "rest" },
        .{ .bit = Flags.accessor, .name = "accessor" },
    };
    for (names) |n| {
        if (flags & n.bit != 0) try w.print(" :{s}", .{n.name});
    }
}
