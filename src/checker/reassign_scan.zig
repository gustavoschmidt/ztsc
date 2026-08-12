//! The lazy per-file reassignment pre-scan.
//!
//! Binder-shaped work that the checker does on demand instead: one linear pass
//! over a file's flow nodes that answers "is this symbol ever assigned?", "is
//! it assigned inside this loop?", "is this member path ever written?", and
//! "where is its last assignment?" (TS 5.4's preserved-narrowing-in-closures
//! rule). The tables it fills — `reassigned_syms`, `reassigned_in_loop`,
//! `member_written_syms`, `member_written_in_loop`, `last_assign_pos` — are
//! pure functions of one file's AST, so the answers never depend on check
//! order.
//!
//! `flow.zig` re-exports every symbol below so `Checker` method spellings
//! (`c.ensureReassignScan()`) keep resolving.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const FlowId = binder.FlowId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const this_flow_root = @import("refkey.zig").this_flow_root;

/// Populate `reassigned_syms` for the current file: the set of value
/// symbols that are ever the target of a reassignment (`x = …`, `x += …`,
/// `x++`, or a destructuring-assignment element). Runs once per file
/// (`reassign_scanned`); the declarator initializer is *not* a
/// reassignment. Order-invariant — a pure function of the file's AST.
///
/// It doubles as ztsc's `markNodeAssignments`: every symbol it records also
/// gets a `last_assign_pos` entry (see `recordLastAssign`), which is what
/// TS 5.4's "preserved narrowing in closures following the last assignment"
/// reads. tsc walks the declaring function's AST for the same information;
/// the flow graph carries exactly the same assignment nodes (each `.assign`
/// flow node IS an assignment / update expression), so the walk is over
/// `flow_tags` instead — same set, one linear pass, no parent pointers.
pub fn ensureReassignScan(c: *Checker) Error!void {
    if (c.reassign_scanned[c.cur_file]) return;
    c.reassign_scanned[c.cur_file] = true;
    const b = c.bind;
    var flow: FlowId = 0;
    while (flow < b.flow_tags.len) : (flow += 1) {
        if (b.flow_tags[flow] != .assign) continue;
        const node = b.flowNode(flow);
        if (node == null_node) continue;
        const scope = b.flowScope(flow);
        switch (c.nodeTag(node)) {
            .assign => {
                try c.markReassignTarget(c.tree.nodeData(node).lhs, scope, node);
                try c.markMemberWriteRoot(c.tree.nodeData(node).lhs, scope);
            },
            .prefix_unary, .postfix_unary => {
                switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                    .plus_plus, .minus_minus => {
                        try c.markReassignTarget(c.tree.nodeData(node).lhs, scope, node);
                        try c.markMemberWriteRoot(c.tree.nodeData(node).lhs, scope);
                    },
                    else => {},
                }
            },
            // declarator_init / declarator_full / for-in-of bindings are
            // the variable's *initialization*, not a reassignment.
            //
            // `for (x of xs)` over an ALREADY-declared `x` IS an assignment
            // to tsc's `markNodeAssignments`, and is deliberately still left
            // out: adding it would put `x` into `reassigned_syms`, which four
            // other consumers (`stableIndexSymbol`, the loop-label shortcut,
            // `narrowedPatternBinding`) read as "not effectively const" — a
            // tightening well outside the 5.4 rule. Leaving it out only ever
            // preserves MORE narrowing, which is the pre-existing answer.
            else => {},
        }
    }
}

/// Record `sym` as reassigned, and for every `for`/`for..of`/`for..in`
/// header scope enclosing the assignment's `scope`, record that `sym` is
/// assigned *inside that loop*. The ancestor walk means an assignment nested
/// N loops deep marks all N enclosing loops.
pub fn recordReassign(c: *Checker, sym: SymbolId, scope: ScopeId) Error!void {
    try c.reassigned_syms.put(c.cm(), sym, {});
    const b = c.bind;
    var s = scope;
    while (true) {
        if (b.scope_kinds[s] == .for_head)
            try c.reassigned_in_loop.put(c.cm(), .{ .sym = sym, .scope = s }, {});
        const p = b.scope_parents[s];
        if (p == s) break;
        s = p;
    }
}

pub fn markReassignTarget(c: *Checker, target: Node, scope: ScopeId, at: Node) Error!void {
    if (target == null_node) return;
    var n = target;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(n));
            switch (c.resolveSpace(a, scope, true)) {
                .sym => |s| {
                    try c.recordReassign(s, scope);
                    try recordLastAssign(c, s, scope, at);
                },
                else => {},
            }
        },
        // Destructuring-assignment target: `[a] = …` / `({a} = …)`.
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            for (c.tree.nodeRange(n)) |el| {
                if (el != null_node) try c.markReassignTarget(el, scope, at);
            }
        },
        // Cover grammar: `object_property`'s target is rhs (lhs is the key).
        .object_property => try c.markReassignTarget(c.tree.nodeData(n).rhs, scope, at),
        // `{[k]: target}` — lhs is the key expression, rhs the target.
        .binding_property_computed => try c.markReassignTarget(c.tree.nodeData(n).rhs, scope, at),
        .binding_property, .object_shorthand => {
            const d = c.tree.nodeData(n);
            if (d.lhs != 0) {
                try c.markReassignTarget(d.lhs, scope, at);
            } else {
                const a = try c.memberAtom(c.tree.nodeMainToken(n));
                switch (c.resolveSpace(a, scope, true)) {
                    .sym => |s| {
                        try c.recordReassign(s, scope);
                        try recordLastAssign(c, s, scope, at);
                    },
                    else => {},
                }
            }
        },
        .binding_default, .rest_element, .spread_element => {
            try c.markReassignTarget(c.tree.nodeData(n).lhs, scope, at);
        },
        // member_expr (`o.p = v`) reassigns a property, not a variable.
        else => {},
    }
}

/// "No reference is ever past this symbol's last assignment" — the pre-TS-5.4
/// answer, and what `last_assign_pos` stores whenever the position cannot be
/// pinned down (see `recordLastAssign`).
pub const no_past_assignment: u32 = std.math.maxInt(u32);

/// tsc's `markNodeAssignments` + `extendAssignmentPosition`, for one
/// assignment of `sym` at `at` (the assignment/update expression node) in
/// `scope`.
///
/// tsc records `symbol.lastAssignmentPos = max(previous, extended)`, where
/// `extended` walks from the assignment identifier up through its ancestors
/// and takes the END of the OUTERMOST enclosing *statement* that begins after
/// the declaration — so an assignment and a reference that share such a
/// statement (both inside one `if`/`while`/`try`) never count as "reference
/// after assignment", however the two are ordered textually. An assignment
/// made from a DIFFERENT function than the declaring one is recorded as
/// `Number.MAX_VALUE`: it can run at any time, so no reference is ever past
/// it.
///
/// ztsc has no parent pointers, so the outermost enclosing statement is found
/// top-down instead: the declaring scope's own statement list is indexed by
/// start offset, the statement containing `at` is located by binary search,
/// and a bare `{ … }` block — the one statement kind tsc's list does NOT
/// include, and so treats as transparent — is descended into. The statement's
/// END is the next sibling's start (or the bound inherited from the level
/// above), which is exactly tsc's `node.end` up to the trivia between two
/// statements; tsc compares against `location.pos`, which counts that same
/// trivia on the other side.
///
/// A declaring scope whose statements cannot be listed (a `for` header, a
/// `catch` clause, a namespace body) records `no_past_assignment`, i.e. the
/// pre-5.4 behaviour — never a narrowing that tsc would not also make.
fn recordLastAssign(c: *Checker, sym: SymbolId, scope: ScopeId, at: Node) Error!void {
    const gop = try c.last_assign_pos.getOrPut(c.cm(), sym);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    if (gop.value_ptr.* == no_past_assignment) return;
    gop.value_ptr.* = @max(gop.value_ptr.*, extendedAssignPos(c, sym, scope, at));
}

fn extendedAssignPos(c: *Checker, sym: SymbolId, scope: ScopeId, at: Node) u32 {
    if (c.symFile(sym) != c.cur_file) return no_past_assignment;
    const decl_scope = c.symScope(sym);
    // tsc: `referencingFunction !== declaringFunction` ⇒ MAX_VALUE.
    if (c.containerOf(scope) != c.containerOf(decl_scope)) return no_past_assignment;
    var stmts = stmtsOfScope(c, decl_scope) orelse return no_past_assignment;
    const pos = c.nodeSpanStart(at);
    var upper: u32 = no_past_assignment;
    // Descend through transparent bare blocks to the outermost statement kind
    // tsc's `extendAssignmentPosition` actually stops at.
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const i = stmtIndexContaining(c, stmts, pos) orelse return upper;
        const next = if (i + 1 < stmts.len) c.nodeSpanStart(stmts[i + 1]) else upper;
        if (c.nodeTag(stmts[i]) != .block) return next;
        upper = next;
        stmts = c.tree.nodeRange(stmts[i]);
        if (stmts.len == 0) return upper;
    }
    return no_past_assignment;
}

/// Index of the last statement in `stmts` that starts at or before `pos`, or
/// null when `pos` precedes the whole list. `stmts` is in source order, so a
/// binary search over the (cheap) span STARTS finds it.
fn stmtIndexContaining(c: *Checker, stmts: []const Node, pos: u32) ?usize {
    if (stmts.len == 0 or c.nodeSpanStart(stmts[0]) > pos) return null;
    var lo: usize = 0;
    var hi: usize = stmts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (c.nodeSpanStart(stmts[mid]) <= pos) lo = mid else hi = mid;
    }
    return lo;
}

/// The statement list a scope's declarations sit directly in, or null when
/// the scope is not one (`for` header, `catch` clause, class body, …).
fn stmtsOfScope(c: *Checker, scope: ScopeId) ?[]const Node {
    const owner = c.bind.scope_owners[scope];
    return switch (c.bind.scope_kinds[scope]) {
        // The file scope owns node 0, which is the `root` node: a range of
        // the file's top-level statements.
        .file => c.tree.nodeRange(ast.root_node),
        .block => c.tree.nodeRange(owner),
        .function => blk: {
            const body = fnBodyOf(c, owner);
            if (body == null_node or c.nodeTag(body) != .block) break :blk null;
            break :blk c.tree.nodeRange(body);
        },
        else => null,
    };
}

/// The body node of a function-like declaration (`null_node` when it has
/// none, e.g. an overload signature or an ambient declaration).
fn fnBodyOf(c: *Checker, node: Node) Node {
    return switch (c.nodeTag(node)) {
        .function_decl, .function_expr, .class_method, .arrow_fn => c.tree.nodeData(node).rhs,
        // `{ m() {} }` — the method's function value carries the body.
        .object_method => fnBodyOf(c, c.tree.nodeData(node).rhs),
        else => null_node,
    };
}

/// Record the ROOT symbol of a member/element-write target (`o.p = …`,
/// `o[i] = …`) so property-path narrowings rooted at that symbol are known
/// to be potentially invalidated inside the enclosing loop(s). Peels the
/// member/index spine (and parens) to the base identifier / `this`.
pub fn markMemberWriteRoot(c: *Checker, target: Node, scope: ScopeId) Error!void {
    if (target == null_node) return;
    var n = target;
    while (true) {
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        const tag = c.nodeTag(n);
        if (tag == .member_expr or tag == .optional_member_expr or
            tag == .index_expr or tag == .optional_index_expr)
        {
            n = c.tree.nodeData(n).lhs;
            continue;
        }
        break;
    }
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    if (target == n) return; // not a member/element write (bare identifier)
    switch (c.nodeTag(n)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(n));
            switch (c.resolveSpace(a, scope, true)) {
                .sym => |s| try c.recordMemberWrite(s, scope),
                else => {},
            }
        },
        .this_expr => try c.recordMemberWrite(this_flow_root, scope),
        else => {},
    }
}

/// Mirror of `recordReassign` for member/element writes: record the root as
/// member-written file-wide and inside every enclosing `for` loop.
pub fn recordMemberWrite(c: *Checker, sym: SymbolId, scope: ScopeId) Error!void {
    try c.member_written_syms.put(c.cm(), sym, {});
    const b = c.bind;
    var s = scope;
    while (true) {
        if (b.scope_kinds[s] == .for_head)
            try c.member_written_in_loop.put(c.cm(), .{ .sym = sym, .scope = s }, {});
        const p = b.scope_parents[s];
        if (p == s) break;
        s = p;
    }
}
