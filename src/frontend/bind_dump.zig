//! Stable text dump of a sealed `Bind` (`--dump-symbols`, binder golden
//! tests). Split out of the result surface because it is pure presentation:
//! it reads `Bind` through its public fields only and nothing in the front end
//! or the checker depends on it. `Bind.dump` forwards here.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const intern = @import("../intern.zig");
const bind_result = @import("bind_result.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Bind = bind_result.Bind;
const ScopeId = bind_result.ScopeId;
const ScopeKind = bind_result.ScopeKind;
const SymbolFlags = bind_result.SymbolFlags;
const file_scope = bind_result.file_scope;
const fbits = bind_result.fbits;

pub fn dump(
    b: *const Bind,
    io: Io,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try dumpScope(b, io, interner, tree, src, w, file_scope, 0);

    var n_start: usize = 0;
    var n_assign: usize = 0;
    var n_cond: usize = 0;
    var n_branch: usize = 0;
    var n_loop: usize = 0;
    var n_switch: usize = 0;
    var n_call: usize = 0;
    var n_arraymut: usize = 0;
    var n_reduce: usize = 0;
    for (b.flow_tags) |t| switch (t) {
        .start => n_start += 1,
        .assign => n_assign += 1,
        .cond_true, .cond_false, .chain_taken, .chain_short => n_cond += 1,
        .branch_label => n_branch += 1,
        .loop_label => n_loop += 1,
        .switch_clause, .switch_no_match => n_switch += 1,
        .call_stmt => n_call += 1,
        .array_mutation => n_arraymut += 1,
        .reduce_label => n_reduce += 1,
        .none, .unreachable_ => {},
    };
    try w.print(
        "flow: nodes={d} attach={d} (start={d} assign={d} cond={d} branch={d} loop={d} switch={d} call={d} arraymut={d} reduce={d})\n",
        .{ b.flowCount(), b.flow_map_nodes.len, n_start, n_assign, n_cond, n_branch, n_loop, n_switch, n_call, n_arraymut, n_reduce },
    );

    for (b.imports) |rec| {
        try w.print("import local={s} imported={s} from=\"{s}\" {s}{s}\n", .{
            atomText(io, interner, rec.local),
            atomText(io, interner, rec.imported),
            atomText(io, interner, rec.module),
            @tagName(rec.kind),
            if (rec.type_only) " type-only" else "",
        });
    }
    for (b.exports) |rec| {
        try w.print("export exported={s} local={s}", .{
            atomText(io, interner, rec.exported),
            atomText(io, interner, rec.local),
        });
        if (rec.module != 0) try w.print(" from=\"{s}\"", .{atomText(io, interner, rec.module)});
        try w.print(" {s}{s}\n", .{
            @tagName(rec.kind),
            if (rec.type_only) " type-only" else "",
        });
    }

    if (b.unresolved.len > 0) {
        try w.writeAll("unresolved:");
        // Aggregate by atom in first-seen order (O(n^2), test-sized).
        var i: usize = 0;
        while (i < b.unresolved.len) : (i += 1) {
            const atom = b.unresolved[i].atom;
            var seen_before = false;
            for (b.unresolved[0..i]) |r| {
                if (r.atom == atom) {
                    seen_before = true;
                    break;
                }
            }
            if (seen_before) continue;
            var count: usize = 0;
            for (b.unresolved[i..]) |r| {
                if (r.atom == atom) count += 1;
            }
            try w.print(" {s}({d})", .{ atomText(io, interner, atom), count });
        }
        try w.writeAll("\n");
    }
}

fn atomText(io: Io, interner: *Interner, atom: Atom) []const u8 {
    if (atom == 0) return "-";
    return interner.lookup(io, atom);
}

fn dumpScope(
    b: *const Bind,
    io: Io,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,
    w: *std.Io.Writer,
    scope: ScopeId,
    depth: usize,
) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * 2);
    try w.print("scope {d}: {s}", .{ scope, @tagName(b.scope_kinds[scope]) });
    if (scopeName(tree, src, b.scope_kinds[scope], b.scope_owners[scope])) |name| {
        try w.print(" {s}", .{name});
    }
    try w.writeAll("\n");

    // Symbols in creation (source) order — deterministic across runs
    // even though atoms (and thus member-array order) are not.
    for (1..b.symbol_names.len) |i| {
        if (b.symbol_scopes[i] != scope) continue;
        try w.splatByteAll(' ', depth * 2 + 2);
        try w.print("{s}:", .{atomText(io, interner, b.symbol_names[i])});
        try dumpFlags(w, b.symbol_flags[i]);
        const n_decls = b.symbol_decls_start[i + 1] - b.symbol_decls_start[i];
        if (n_decls > 1) try w.print(" decls={d}", .{n_decls});
        try w.writeAll("\n");
    }

    for (1..b.scope_parents.len) |child| {
        if (b.scope_parents[child] != scope) continue;
        try dumpScope(b, io, interner, tree, src, w, @intCast(child), depth + 1);
    }
}

fn scopeName(tree: *const Ast, src: []const u8, kind: ScopeKind, owner: Node) ?[]const u8 {
    if (owner == 0) return null;
    const d = tree.nodeData(owner);
    const name_tok: TokenIndex = switch (tree.nodeTag(owner)) {
        .function_decl, .function_expr, .class_method, .method_signature => tree.extraData(ast.FnProto, d.lhs).name_token,
        .class_decl => tree.extraData(ast.ClassData, d.lhs).name_token,
        .interface_decl => tree.extraData(ast.InterfaceData, d.lhs).name_token,
        .type_alias => tree.extraData(ast.TypeAlias, d.lhs).name_token,
        .namespace_decl => tree.extraData(ast.NamespaceData, d.lhs).name_token,
        else => 0,
    };
    _ = kind;
    if (name_tok == 0) return null;
    return tree.tokenSlice(src, name_tok);
}

fn dumpFlags(w: *std.Io.Writer, f: SymbolFlags) std.Io.Writer.Error!void {
    const names = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = fbits(.{ .var_decl = true }), .name = "var" },
        .{ .bit = fbits(.{ .let_decl = true }), .name = "let" },
        .{ .bit = fbits(.{ .const_decl = true }), .name = "const" },
        .{ .bit = fbits(.{ .function = true }), .name = "function" },
        .{ .bit = fbits(.{ .class = true }), .name = "class" },
        .{ .bit = fbits(.{ .interface = true }), .name = "interface" },
        .{ .bit = fbits(.{ .type_alias = true }), .name = "type" },
        .{ .bit = fbits(.{ .type_param = true }), .name = "type-param" },
        .{ .bit = fbits(.{ .param = true }), .name = "param" },
        .{ .bit = fbits(.{ .catch_param = true }), .name = "catch" },
        .{ .bit = fbits(.{ .property = true }), .name = "property" },
        .{ .bit = fbits(.{ .method = true }), .name = "method" },
        .{ .bit = fbits(.{ .getter = true }), .name = "get" },
        .{ .bit = fbits(.{ .setter = true }), .name = "set" },
        .{ .bit = fbits(.{ .static_member = true }), .name = "static" },
        .{ .bit = fbits(.{ .import_binding = true }), .name = "import" },
        .{ .bit = fbits(.{ .type_only = true }), .name = "type-only" },
        .{ .bit = fbits(.{ .exported = true }), .name = "exported" },
        .{ .bit = fbits(.{ .export_default = true }), .name = "default" },
        .{ .bit = fbits(.{ .has_impl = true }), .name = "impl" },
        .{ .bit = fbits(.{ .optional_member = true }), .name = "optional" },
        .{ .bit = fbits(.{ .readonly_member = true }), .name = "readonly" },
        .{ .bit = fbits(.{ .expando = true }), .name = "expando" },
        .{ .bit = fbits(.{ .expando_member = true }), .name = "expando-prop" },
    };
    for (names) |n| {
        if (f.bits() & n.bit != 0) try w.print(" {s}", .{n.name});
    }
}
