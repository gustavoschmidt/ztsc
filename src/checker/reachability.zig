//! Syntactic reachability: does control flow fall off the end of a statement
//! list? Drives TS2366/TS2355 (a function that must return a value but can
//! reach its end) and the phantom-`undefined` arm of inferred return types,
//! plus the exhaustiveness half of both — a `switch` with no `default` that
//! nevertheless covers every constituent of its discriminant.
//!
//! Predicates only: each answers a bool and reports nothing. They are NOT
//! pure functions of the syntax, though — deciding exhaustiveness needs the
//! discriminant's TYPE, and this runs from inside a return-type probe that
//! has not typed it yet, so the type is synthesized on demand (memoized).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;

const typeof_names = Checker.typeof_names;

pub fn stmtListTerminal(c: *Checker, stmts: []const Node) bool {
    // Does control flow fall off the end of this list? Walk forward tracking
    // reachability: the first terminal statement (return/throw/terminal
    // loop…) kills it, and straight-line code never revives it. A terminal
    // statement in the *middle* therefore makes the whole list terminal —
    // trailing dead code or a hoisted `function`/type declaration after a
    // `return` does not resurrect the endpoint (the previous "inspect the
    // last statement only" rule wrongly did, adding a phantom `| undefined`
    // to the inferred return type of the common
    // `return { … }; function helper() {…}` hook pattern).
    var reachable = true;
    for (stmts) |s| {
        if (s == null_node or !reachable) continue;
        if (c.stmtTerminal(s)) reachable = false;
    }
    return !reachable;
}

pub fn stmtTerminal(c: *Checker, node: Node) bool {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .return_stmt, .throw_stmt => return true,
        // tsc's endpoint analysis is CFA, not syntax: `functionHasImplicit
        // Return` reads `isReachableFlowNode(func.endFlowNode)`, whose Call
        // arm ends the flow at a call whose signature returns `never`. So
        // `this.handleError(e): never` as the last statement of a `catch`
        // makes the endpoint unreachable — no TS2366, and no phantom
        // `| undefined` on an inferred return type. `flowReachable` already
        // reads this for narrowing; both endpoint consumers need it too.
        .expr_stmt => return switch (c.nodeTag(d.lhs)) {
            .call_expr, .call_expr_targs, .optional_call => c.callReturnsNever(d.lhs) catch false,
            else => false,
        },
        .block => return c.stmtListTerminal(c.tree.nodeRange(node)),
        .if_else_stmt => {
            const e = c.tree.extraData(ast.IfElse, d.rhs);
            return c.stmtTerminal(e.then_stmt) and c.stmtTerminal(e.else_stmt);
        },
        .labeled_stmt => return c.stmtTerminal(d.lhs),
        .try_stmt => {
            const e = c.tree.extraData(ast.Try, d.rhs);
            // A `finally` that itself ends abruptly (return/throw) makes the
            // whole statement terminal regardless of the try/catch bodies.
            if (e.finally_block != null_node and c.stmtTerminal(e.finally_block)) return true;
            // Otherwise the statement can complete normally if the try block
            // can, or — when a catch exists — if the catch block can. It is
            // terminal only when neither falls through.
            const try_terminal = c.stmtTerminal(d.lhs);
            if (e.catch_clause != null_node) {
                const catch_block = c.tree.nodeData(e.catch_clause).rhs;
                return try_terminal and c.stmtTerminal(catch_block);
            }
            return try_terminal;
        },
        .switch_stmt => return c.switchTerminal(node),
        .while_stmt => {
            // while (true) without break is terminal-ish.
            if (c.nodeTag(d.lhs) == .true_literal and !c.containsBreak(d.rhs)) return true;
            return false;
        },
        .for_stmt => {
            const e = c.tree.extraData(ast.For, d.lhs);
            if (e.cond == 0 and !c.containsBreak(d.rhs)) return true;
            return false;
        },
        else => return false,
    }
}

/// A switch is terminal if it has a default (or is exhaustive over a
/// literal-union discriminant), every clause ends terminally, and no
/// clause breaks out.
pub fn switchTerminal(c: *Checker, node: Node) bool {
    const d = c.tree.nodeData(node);
    const r = c.tree.extraData(ast.SubRange, d.rhs);
    var has_default = false;
    var n_cases: usize = 0;
    for (c.tree.extraRange(r.start, r.end)) |clause| {
        if (clause == null_node) continue;
        const cd = c.tree.nodeData(clause);
        if (c.nodeTag(clause) == .default_clause) has_default = true else n_cases += 1;
        const cr = c.tree.extraData(ast.SubRange, cd.rhs);
        const stmts = c.tree.extraRange(cr.start, cr.end);
        for (stmts) |s| {
            if (s != null_node and c.containsBreak(s)) return false;
        }
        // A clause with statements must end terminally (empty clauses
        // fall through to the next).
        var has_stmt = false;
        for (stmts) |s| {
            if (s != null_node) has_stmt = true;
        }
        if (has_stmt and !c.stmtListTerminal(stmts)) return false;
    }
    if (has_default) return true;
    // Exhaustiveness: discriminant type's union members all covered.
    return c.switchIsExhaustive(node);
}

pub fn switchIsExhaustive(c: *Checker, node: Node) bool {
    const d = c.tree.nodeData(node);
    // switch (typeof x): exhaustive when every typeof outcome of x's
    // type is covered by a case string.
    if (c.nodeTag(d.lhs) == .prefix_unary and
        c.tree.tokens.tag(c.tree.nodeMainToken(d.lhs)) == .keyword_typeof)
    {
        return c.typeofSwitchIsExhaustive(node, c.tree.nodeData(d.lhs).lhs);
    }
    // The discriminant type may not be cached yet: `switchIsExhaustive` is
    // reached from `inferReturnType`, a type probe that checks only the
    // `return` expressions, never the switch discriminant. Synthesize it on
    // demand (memoized by `checkExprCached`) so an exhaustive switch over a
    // literal-union parameter — `switch (fmt) { case 'a': … }` covering
    // every `FormatKey` member — is recognized as terminal, and the
    // function's inferred return type gains no phantom `| undefined`.
    const disc_t0 = c.nodeType(d.lhs) orelse (c.checkExprCached(d.lhs, types.no_type) catch return false);
    const disc_t1 = c.resolveStructural(disc_t0) catch return false;
    // A whole-enum discriminant is the union of its member types (tsc), so
    // `switch (e) { case E.A: … case E.B: … }` over every member IS
    // exhaustive. Expanding here keeps the one covering loop below.
    const disc_t = if (c.ts.kind(disc_t1) == .enum_type and !c.ts.isEnumMember(disc_t1))
        ((c.enumMemberTypeUnion(c.ts.enumSymbol(disc_t1), 0) catch return false) orelse return false)
    else
        disc_t1;
    if (c.ts.kind(disc_t) != .union_type) return false;
    const r = c.tree.extraData(ast.SubRange, d.rhs);
    for (0..c.ts.memberCount(disc_t)) |mi| {
        const rm = c.ts.regularLiteral(c.ts.memberAt(disc_t, mi)) catch return false;
        if (!c.ts.isLiteralLike(rm) and
            c.ts.kind(rm) != .null and c.ts.kind(rm) != .undefined) return false;
        var covered = false;
        for (c.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node or c.nodeTag(clause) != .case_clause) continue;
            const test_node = c.tree.nodeData(clause).lhs;
            if (test_node == 0) continue;
            // Case-label literals may be unchecked in the return-type probe
            // (it types only `return` expressions) — synthesize on demand
            // (memoized) so switch coverage is seen.
            const tt0 = c.nodeType(test_node) orelse (c.checkExprCached(test_node, types.no_type) catch continue);
            const tt = c.ts.regularLiteral(tt0) catch continue;
            if (tt == rm) covered = true;
        }
        if (!covered) return false;
    }
    return true;
}

pub fn typeofSwitchIsExhaustive(c: *Checker, sw: Node, operand: Node) bool {
    const t = c.nodeType(operand) orelse (c.checkExprCached(operand, types.no_type) catch return false);
    const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
    // For each possible typeof outcome of t, require a covering case.
    for (0..typeof_names.len) |which| {
        var possible = false;
        if (c.ts.kind(t) == .union_type) {
            for (c.ts.members(t)) |m| {
                if (c.typeofMatches(m, which)) possible = true;
            }
        } else {
            possible = c.typeofMatches(t, which);
        }
        if (!possible) continue;
        var covered = false;
        for (c.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node or c.nodeTag(clause) != .case_clause) continue;
            const test_node = c.tree.nodeData(clause).lhs;
            if (test_node == 0) continue;
            // Case-label literals may be unchecked in the return-type probe
            // (it types only `return` expressions) — synthesize on demand
            // (memoized) so switch coverage is seen.
            const tt0 = c.nodeType(test_node) orelse (c.checkExprCached(test_node, types.no_type) catch continue);
            const tt = c.ts.regularLiteral(tt0) catch continue;
            if (c.ts.kind(tt) != .string_literal) continue;
            if (c.ts.literalAtom(tt) == c.typeof_atoms[which]) covered = true;
        }
        if (!covered) return false;
    }
    return true;
}

/// Does `node` contain a `break` that would leave the loop or switch it is
/// being asked about? Purely syntactic — the only predicate here that reads
/// no types at all, hence the `*const` receiver.
pub fn containsBreak(c: *const Checker, node: Node) bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        .break_stmt => return true,
        // Breaks inside nested loops/switches target those.
        .while_stmt, .do_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => return false,
        .arrow_fn, .function_expr, .function_decl, .class_decl => return false,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (c.containsBreak(child)) return true;
    }
    return false;
}
