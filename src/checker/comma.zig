//! TS2695, the comma operator's dead left operand: "Left side of comma operator
//! is unused and has no side effects."
//!
//! `a, b` evaluates `a`, throws the value away and yields `b`. tsc's
//! `checkBinaryLikeExpressionWorker` reports whenever that discarded operand
//! could not have done anything observable either — `isSideEffectFree`, a closed
//! list of expression KINDS. Syntax only: no type is consulted, and an
//! unrecognized form answers "may have effects", so the check is silent rather
//! than wrong.

const std = @import("std");
const ast = @import("../frontend/ast.zig");

const Node = ast.Node;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// TS2695, at a COMMA expression whose left operand can be dropped:
/// tsc's `checkBinaryLikeExpressionWorker`'s `CommaToken` arm reports
/// "Left side of comma operator is unused and has no side effects" whenever
/// `isSideEffectFree(left)` holds (and `allowUnreachableCode` is not off, which
/// ztsc never sets).
///
/// Reported at the left operand. The one shape tsc exempts is the INDIRECT-CALL
/// idiom `(0, f)(…)`, which it recognizes by walking up to the call; ztsc has no
/// parent pointers, so it exempts a `0` left operand outright — the only
/// spelling of that idiom, and a `0,` that is genuinely dead loses nothing but
/// its diagnostic.
pub fn checkCommaOperand(c: *Checker, left: Node) Error!void {
    if (left == null_node) return;
    if (!sideEffectFree(c, left, 0)) return;
    if (c.nodeTag(left) == .number_literal and c.numberTokenValue(c.tree.nodeMainToken(left)) == 0) return;
    try c.diagFmt(2695, c.nodeSpan(left), "Left side of comma operator is unused and has no side effects.", .{});
}

/// tsc's `isSideEffectFree`: a closed list of expression kinds that cannot do
/// anything observable. Everything unrecognized answers false, so a new syntax
/// form is silent rather than mis-reported.
fn sideEffectFree(c: *Checker, node0: Node, depth: u32) bool {
    if (depth > 8) return false;
    var node = node0;
    while (c.nodeTag(node) == .paren_expr) {
        const inner = c.tree.nodeData(node).lhs;
        if (inner == null_node) return false;
        node = inner;
    }
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .identifier,
        .string_literal,
        .regex_literal,
        .template_literal,
        .template_expr,
        .tagged_template,
        .number_literal,
        .bigint_literal,
        .true_literal,
        .false_literal,
        .null_literal,
        .function_expr,
        .class_decl,
        .arrow_fn,
        .array_literal,
        .object_literal,
        .non_null,
        .jsx_element,
        => return true,
        .cond_expr => {
            const e = c.tree.extraData(ast.CondExpr, d.rhs);
            return sideEffectFree(c, e.then_expr, depth + 1) and sideEffectFree(c, e.else_expr, depth + 1);
        },
        .binary => return sideEffectFree(c, d.lhs, depth + 1) and sideEffectFree(c, d.rhs, depth + 1),
        // `~`, `!`, unary `+` and unary `-` are pure; `typeof` is too. Everything
        // else a prefix/postfix operator can be (`++`, `--`, `delete`, `await`,
        // `void`) is not — and `void` is tsc's explicit opt-out.
        .prefix_unary => return switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
            .bang, .plus, .minus, .tilde, .keyword_typeof => true,
            else => false,
        },
        // An `as`/`<T>` assertion is side-effect free in fact, and deliberately
        // NOT treated so by tsc ("can produce useful diagnostics").
        else => return false,
    }
}
