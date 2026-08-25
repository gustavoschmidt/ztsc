//! Class `static { … }` blocks: checking a block's body.
//!
//! A static block is a function-like container whose `this` is the class's
//! STATIC side. The binder gives it a `.function` scope of its own (see
//! `bindClass`'s `.block` arm), so everything the statement walk needs is
//! already in place; what this module adds is the two facts that scope cannot
//! carry — the receiver type, and the source position the block occupies among
//! the class's static members.
//!
//! The block's own grammar rules (TS18037 `await`, TS1163 `yield`, TS18041
//! `return`, TS18038 `for await`, TS1359 for a binding named `await`) are the
//! PARSER's: they are decided by where the code is written, and the parser is
//! the pass that knows that without a scope walk. See `Parser.fn_ctx`.

const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const init_order = @import("init_order.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Check one `static { … }` member: the statements run with `this` bound to the
/// class's static side, in the block's own scope, and with no enclosing
/// function contract for a `return` to satisfy (there is no legal `return` in a
/// static block at all — TS18041).
///
/// `members` and `member` are handed over for the TS2729 scan (`init_order.zig`),
/// which is a question about source ORDER among the class's static declarations.
pub fn checkStaticBlock(
    c: *Checker,
    members: []const Node,
    member: Node,
    class_sym: SymbolId,
    class_name: []const u8,
    fallback_this: TypeId,
) Error!void {
    // Same owned-file guard as `checkFunctionBody`: this walk only produces
    // diagnostics, `seal` drops a foreign file's, and its cache effects are
    // memos every reader re-derives on miss.
    if (!c.owned_mask[c.cur_file]) return;
    const saved_scope = c.cur_scope;
    const saved_this = c.this_type;
    const saved_ctx = c.fn_ctx;
    defer {
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
        c.fn_ctx = saved_ctx;
    }
    if (try c.scopeOf(member)) |s| c.cur_scope = s;
    c.this_type = if (class_sym != binder.no_symbol)
        try c.ts.makeClassValue(class_sym)
    else
        fallback_this;
    // A static block is neither async nor a generator, and nothing it returns
    // is related to anything: a `return` there is TS18041, already reported.
    c.fn_ctx = .{
        .ret_ann = types.no_type,
        .ret_ctx = types.no_type,
        .is_async = false,
        .is_generator = false,
        .yield_type = 0,
    };
    for (c.tree.nodeRange(member)) |stmt| {
        if (stmt == null_node) continue;
        // A static block runs in the same window a static field initializer
        // does, so it answers to the same source-order rule (`init_order.zig`).
        try init_order.checkSelfRefs(c, members, member, stmt, class_name, .static);
        try c.checkStatement(stmt);
    }
}
