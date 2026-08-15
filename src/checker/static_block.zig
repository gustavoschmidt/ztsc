//! Class `static { … }` blocks: checking a block's body, and the static half of
//! the "used before its initialization" rule (TS2729) that the block shares
//! with static field initializers.
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

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
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
/// `members` and `member` are handed over for the TS2729 scan, which is a
/// question about source ORDER among the class's static declarations.
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
        try checkStaticSelfRefs(c, members, member, stmt, class_name);
        try c.checkStatement(stmt);
    }
}

/// TS2729 on the STATIC side, the mirror of `checkFieldInitSelfRefs`: a
/// `C.x` or `this.x` that names an own static field whose initializer has not
/// run yet at this point in the class body — a LATER sibling, or the very field
/// being initialized. Both read `undefined` while the class is being set up.
///
/// The two callers are the two places static initialization code can be
/// written: a static field's initializer, and a static block. Static
/// initializers run in source order, so "not yet" is decided by comparing
/// declaration positions, exactly as the instance rule does.
///
/// Syntactic, for the same reason the instance rule is: every exemption is a
/// property of where the reference is written. A use inside a nested function
/// or class runs later, so the descent stops there; a receiver that is itself
/// an access (`C.a.b`) is not a declaration reference; and members other than
/// plain static fields are exempt — a static method is on the constructor
/// before any initializer runs.
pub fn checkStaticSelfRefs(
    c: *Checker,
    members: []const Node,
    member: Node,
    expr: Node,
    class_name: []const u8,
) Error!void {
    switch (c.nodeTag(expr)) {
        // Deferred to call time — the class is fully initialized by then.
        .arrow_fn, .function_expr, .function_decl, .object_method, .class_decl => return,
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(expr);
            if (receiverIsThisClass(c, d.lhs, class_name)) {
                const name = c.tokenText(d.rhs);
                for (members) |m| {
                    if (m == null_node or c.nodeTag(m) != .class_field) continue;
                    const e = c.tree.extraData(ast.Field, c.tree.nodeData(m).lhs);
                    if (e.flags & ast.Flags.static == 0) continue;
                    if (e.flags & (ast.Flags.optional | ast.Flags.declare | ast.Flags.abstract) != 0) continue;
                    if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(m)), name)) continue;
                    // Initialized already: a strictly earlier sibling.
                    if (m != member and c.nodeSpanStart(m) < c.nodeSpanStart(member)) break;
                    try c.diagFmt(2729, c.tokSpan(d.rhs), "Property '{s}' is used before its initialization.", .{name});
                    break;
                }
            }
        },
        else => {},
    }
    var it = c.tree.childIterator(expr);
    while (it.next()) |child| try checkStaticSelfRefs(c, members, member, child, class_name);
}

/// Is this the receiver a static initializer uses to reach its own class —
/// `this`, or the class's own name? Only those two: a reference through an
/// alias (`const D = C; D.x`) is not a declaration reference tsc tracks either.
/// Matched by NAME rather than by symbol, exactly as the member lookup around
/// it matches member names: a binding that shadows the class's own name inside
/// its own body would be needed to fool it.
fn receiverIsThisClass(c: *Checker, recv: Node, class_name: []const u8) bool {
    return switch (c.nodeTag(recv)) {
        .this_expr => true,
        .identifier => class_name.len > 0 and
            std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(recv)), class_name),
        else => false,
    };
}
