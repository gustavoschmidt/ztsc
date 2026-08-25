//! TS2729, "Property 'x' is used before its initialization": a class member
//! read from code that runs while the class is still being set up, before the
//! read member's own initializer has run.
//!
//! The rule is SYNTACTIC, and deliberately so — tsc's is too. Its
//! `isInPropertyInitializerOrClassStaticBlock` walks from the use up to an
//! enclosing property declaration or static block, and
//! `isBlockScopedNameDeclaredBeforeUse` then compares declaration positions;
//! every step of both is a question about where the code is WRITTEN. This
//! module runs the same question downwards instead: from a field initializer
//! (or a static block's statements) it descends exactly the part of the
//! expression that is evaluated *there and then*, and reports every reference
//! it finds to a member the class has not assigned yet.
//!
//! Which sub-expressions are "there and then" is the whole subtlety, and it is
//! the mirror image of tsc's climb:
//!
//!   * a function, arrow or method BODY runs on call — the descent stops;
//!   * an object literal's `get [k]()` / `set [k]()` / `m()` KEY is evaluated
//!     as the literal is built, so the key is descended into even though the
//!     body is not (tsc's `ComputedPropertyName`/`MethodDeclaration` arms
//!     return `false`, i.e. keep climbing);
//!   * a class expression's `extends` clause is evaluated where the class is
//!     written, with the enclosing `this` (tsc's `HeritageClause` /
//!     `ExpressionWithTypeArguments` arms), and so are its members' computed
//!     names and its STATIC field initializers — but not its instance field
//!     initializers, which run per construction.
//!
//! Inside a nested class body `this` names the nested class, so only a
//! reference through the outer class's NAME can still reach the outer class
//! there; `allow_this` carries that.
//!
//! What counts as "not assigned yet" differs by how the member is reached,
//! because tsc's `isThisProperty(usage.parent)` guard makes it differ:
//!
//!   * through `this.x`, a sibling only counts as assigned if it is EARLIER in
//!     source *and* actually assigns — an initializer or a `!` definite
//!     assertion. A bare `x: number;` earlier in the class is still
//!     `undefined` when a later field's initializer runs, and tsc says so —
//!     unless a `static { … }` block could have filled it in first, which is a
//!     flow question this pass declines (`staticBlockRunsFirst`);
//!   * through `C.x`, position alone decides: an earlier declaration is fine
//!     whatever it looks like;
//!   * a `?` optional member is exempt either way — it is allowed to be
//!     missing;
//!   * a constructor's parameter property is never assigned in time: it is
//!     assigned by the constructor body prologue, after every field
//!     initializer has run.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const member_names = @import("../frontend/member_names.zig");

const Node = ast.Node;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Which half of the class the code being scanned belongs to. The static half
/// sees `static` members and the instance half sees the rest; a static field's
/// initializer reading an instance field is TS2339, not this diagnostic.
pub const Side = enum { instance, static };

/// One scan's fixed context: the class's member list, the member whose eager
/// code is being walked (a field, or a `static { … }` block), the class's own
/// name, and which half of the class it is.
const Scan = struct {
    members: []const Node,
    member: Node,
    class_name: []const u8,
    side: Side,
};

/// How a member access reaches the class being initialized, if at all.
const Receiver = enum { none, this_kw, class_name };

/// Scan one eagerly-evaluated expression — a field initializer, or a statement
/// of a `static { … }` block — for references to members the class has not
/// assigned yet.
pub fn checkSelfRefs(
    c: *Checker,
    members: []const Node,
    member: Node,
    expr: Node,
    class_name: []const u8,
    side: Side,
) Error!void {
    try walk(c, .{
        .members = members,
        .member = member,
        .class_name = class_name,
        .side = side,
    }, expr, true);
}

fn walk(c: *Checker, s: Scan, expr: Node, allow_this: bool) Error!void {
    switch (c.nodeTag(expr)) {
        // Deferred to call time — the class is fully set up by then.
        .arrow_fn, .function_expr, .function_decl => return,
        // `{ m() {} }` / `{ get [k]() {} }`: the KEY is evaluated as the
        // literal is built (lhs), the function is not (rhs).
        .object_method => return walk(c, s, c.tree.nodeData(expr).lhs, allow_this),
        .class_decl => return walkNestedClass(c, s, expr, allow_this),
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(expr);
            const recv = receiverOf(c, s, d.lhs, allow_this);
            const name = c.tokenText(d.rhs);
            if (recv != .none and isUnassigned(c, s, name, recv == .this_kw)) {
                try c.diagFmt(2729, c.tokSpan(d.rhs), "Property '{s}' is used before its initialization.", .{name});
            }
        },
        else => {},
    }
    // `this.a.b` keeps descending: the inner `this.a` is a declaration
    // reference in its own right, while `b` on top of it is not (tsc skips a
    // property access whose own receiver is an access).
    var it = c.tree.childIterator(expr);
    while (it.next()) |child| try walk(c, s, child, allow_this);
}

/// A class expression written inside an initializer. Its `extends` clause runs
/// where the class is written — with the ENCLOSING `this`, so `allow_this`
/// survives — and so do its members' computed names and its static field
/// initializers, but with `this` now naming the nested class. Its instance
/// field initializers and every method body run later and are skipped.
fn walkNestedClass(c: *Checker, s: Scan, expr: Node, allow_this: bool) Error!void {
    const e = c.tree.extraData(ast.ClassData, c.tree.nodeData(expr).lhs);
    if (e.extends != null_node) try walk(c, s, e.extends, allow_this);
    for (c.tree.extraRange(e.members_start, e.members_end)) |m| {
        if (m == null_node) continue;
        if (c.tree.computedKey(m)) |key| try walk(c, s, key, false);
        if (c.nodeTag(m) != .class_field) continue;
        const f = c.tree.extraData(ast.Field, c.tree.nodeData(m).lhs);
        if (f.flags & ast.Flags.static == 0 or f.init == null_node) continue;
        try walk(c, s, f.init, false);
    }
}

/// `this` and the class's own name are the two receivers that reach the class
/// being initialized. The name is matched as TEXT, exactly as the member lookup
/// beside it matches member names: a binding that shadows the class's own name
/// inside its own body would be needed to fool it, and an alias (`const D = C;
/// D.x`) is not a declaration reference tsc tracks either.
///
/// On the INSTANCE half only `this` qualifies — `C.x` there names a static.
fn receiverOf(c: *Checker, s: Scan, recv: Node, allow_this: bool) Receiver {
    return switch (c.nodeTag(recv)) {
        .this_expr => if (allow_this) .this_kw else .none,
        .identifier => if (s.side == .static and s.class_name.len > 0 and
            std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(recv)), s.class_name))
            .class_name
        else
            .none,
        else => .none,
    };
}

/// Is `name` a member of this class that has no value yet at the point
/// `s.member` runs? Members that are not plain fields are exempt: a method or
/// an accessor is on the prototype (or the constructor) before any initializer
/// runs.
fn isUnassigned(c: *Checker, s: Scan, name: []const u8, via_this: bool) bool {
    const want_static = s.side == .static;
    const here = c.nodeSpanStart(s.member);
    const strict = via_this and !staticBlockRunsFirst(c, s, here);
    for (s.members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_field) continue;
        const e = c.tree.extraData(ast.Field, c.tree.nodeData(m).lhs);
        if ((e.flags & ast.Flags.static != 0) != want_static) continue;
        if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(m)), name)) continue;
        if (e.flags & ast.Flags.optional != 0) return false;
        if (c.nodeSpanStart(m) >= here) return true;
        // Earlier in the class. Through the class's name position settles it;
        // through `this` the declaration must also ASSIGN something.
        return strict and e.init == null_node and e.flags & ast.Flags.definite == 0;
    }
    return via_this and s.side == .instance and isParamProperty(c, s.members, name);
}

/// Has a `static { … }` block already run by the point being scanned?
///
/// It matters because a static block can assign a static field the declaration
/// itself leaves empty, and tsc asks the FLOW graph whether one did
/// (`isPropertyInitializedInStaticBlocks`, plus the
/// `isClassStaticBlockDeclaration(current) → declaration.pos < usage.pos` arm
/// of `isUsedInFunctionOrInstanceProperty` for a use written inside a block).
/// A syntactic scan cannot answer a flow question, so once a block could have
/// run this falls back to the position-only rule — an earlier declaration is
/// accepted whether or not it writes anything. That is the conservative half:
/// it under-reports `static x; static { if (c) this.x = 1; } static y = this.x`
/// and never invents a diagnostic for `static x; static { this.x = 1 } static
/// y = this.x`, which is ordinary correct code.
fn staticBlockRunsFirst(c: *Checker, s: Scan, here: u32) bool {
    if (s.side != .static) return false;
    // A use written INSIDE a block is past every block that opened before it,
    // its own included — the block's statements can have assigned the field.
    if (c.nodeTag(s.member) == .block) return true;
    for (s.members) |m| {
        if (m == null_node or c.nodeTag(m) != .block) continue;
        if (c.nodeSpanStart(m) < here) return true;
    }
    return false;
}

/// Does the constructor declare `name` as a parameter property? One of those is
/// assigned by the constructor's prologue, which runs after every instance
/// field initializer, so a field initializer that reads it always reads
/// `undefined` — tsc reaches the same answer through the `ScriptTarget.ESNext
/// && useDefineForClassFields` arm of `isBlockScopedNameDeclaredBeforeUse`.
fn isParamProperty(c: *Checker, members: []const Node, name: []const u8) bool {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs);
        if (!member_names.isCtorMethod(c.tree, m, proto.flags)) continue;
        for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
            if (p == null_node or c.nodeTag(p) != .param_full) continue;
            const pd = c.tree.nodeData(p);
            const e = c.tree.extraData(ast.ParamFull, pd.rhs);
            if (e.flags & member_names.param_property_mask == 0) continue;
            // Only an identifier parameter names a member; a binding pattern
            // with a modifier is TS1187 and declares nothing.
            if (c.nodeTag(pd.lhs) != .identifier) continue;
            if (std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(pd.lhs)), name)) return true;
        }
    }
    return false;
}
