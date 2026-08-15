//! The one hole in a class type parameter's scope: the class's STATIC members.
//!
//! *"The scope of a type parameter extends over the entire declaration with
//! which the type parameter list is associated, with the exception of static
//! member declarations in classes"* (TS 1.0 spec §3.4.1). A static member
//! belongs to the constructor object, which exists once for every
//! instantiation, so there is no `T` there to mean anything — hence TS2302.
//!
//! tsc decides this inside `resolveNameHelper`: having found the name in a
//! class's type-parameter table, it asks whether the class CHILD it walked out
//! of (`lastLocation`) carries `static`. ztsc's class member tables are not in
//! the lexical scope chain (a static method's scope parent is the class scope
//! itself, exactly as an instance method's is), so the same question is asked
//! positionally instead: which member of the declaring class contains the
//! reference, and is that member static? Members are disjoint and in source
//! order, so the containing one is the last whose span starts at or before the
//! reference — no full span walk needed.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const SymbolId = binder.SymbolId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;

/// Is `tok` — a reference that resolved to the type parameter `sym` — written
/// inside a static member of the class that declares `sym`? True is TS2302.
///
/// False for every symbol that is not a class's own type parameter, which is
/// the overwhelmingly common answer and costs one flag test.
pub fn refFromStaticMember(c: *const Checker, sym: SymbolId, tok: TokenIndex) bool {
    if (!c.symFlags(sym).type_param) return false;
    // A type parameter is always resolved lexically, so a cross-file symbol
    // here would mean the scope tables being read belong to another file.
    if (c.symFile(sym) != c.cur_file) return false;
    const scope = c.symScope(sym);
    if (c.bind.scope_kinds[scope] != .class) return false;
    const owner = c.bind.scope_owners[scope];
    if (c.nodeTag(owner) != .class_decl) return false;

    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(owner).lhs);
    const at = c.tree.tokens.start(tok);
    var containing: Node = null_node;
    for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
        if (m == null_node) continue;
        // Past the reference: every later member starts later still.
        if (c.nodeSpanStart(m) > at) break;
        containing = m;
    }
    return containing != null_node and memberIsStatic(c, containing);
}

/// tsc's `isStatic`: a `static` modifier, or a static initialization block —
/// which has no modifier list of its own and is the only `.block` a class body
/// can hold.
fn memberIsStatic(c: *const Checker, member: Node) bool {
    const d = c.tree.nodeData(member);
    const flags: u32 = switch (c.nodeTag(member)) {
        .class_field => c.tree.extraData(ast.Field, d.lhs).flags,
        .class_method => c.tree.extraData(ast.FnProto, d.lhs).flags,
        .index_signature => d.rhs,
        .block => return true,
        else => return false,
    };
    return flags & ast.Flags.static != 0;
}
