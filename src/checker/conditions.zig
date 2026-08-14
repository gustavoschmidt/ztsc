//! What a CONDITION's expression is worth before it is evaluated — tsc's
//! `checkTruthinessOfType` / `getSyntacticTruthySemantics` (TS 5.6's
//! "disallowed nullish and truthy checks"):
//!
//!   * TS2872 "This kind of expression is always truthy."
//!   * TS2873 "This kind of expression is always falsy."
//!
//! The classification is SYNTACTIC, and deliberately so: `if ("abc")` is
//! reported while `declare const s: "abc"; if (s)` is not, even though the two
//! carry the same type. That is what keeps the check off the type graph — one
//! switch on a node tag, no type is resolved and nothing is memoized — and it
//! is why a literal spelled through a variable stays legal.
//!
//! The positions are exactly the ones tsc routes through
//! `checkTruthinessExpression`: an `if`/`while`/`do..while`/`for` condition, a
//! `?:` condition, the operand of `!`, and the LEFT operand of `&&` / `||`.
//! `??` is NOT one of them — its left operand is tested for nullishness, not
//! truthiness, and tsc reports TS2869 there instead.
//!
//! Verified against tsgo shape by shape (`scratchpad/wave5/C/probe/t`), which
//! is where the surprises are: `0n` is always TRUTHY (a bigint literal is
//! classified by kind, with no zero carve-out) while `0` and `1` are neither
//! (tsc's explicit `while (1)` allowance), a numeric literal is judged by VALUE
//! and not by spelling (`1.0`, `0x1`, `1e0` are all "sometimes"), `void 0` is
//! always falsy, and a `?:` folds to its two branches' common verdict while a
//! `&&`/`||`/`,`/`+`/`!` does not fold at all.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's `PredicateSemantics`.
const Semantics = enum { always, never, sometimes };

/// tsc's `checkTruthinessOfType(type, node)`, for `node` in a truthiness
/// position with type `ty`:
///
///   * a `void` operand cannot be tested at all (TS1345);
///   * a syntactically constant one is TS2872/TS2873.
///
/// Both are reported on the node AS WRITTEN: `if (("abc"))` is anchored at the
/// parenthesis, because tsc passes the unskipped condition to `error()` and
/// only the classification skips outer expressions.
pub fn checkTruthiness(c: *Checker, node: Node, ty: types.TypeId) Error!void {
    if (node == null_node) return;
    // `type.flags & TypeFlags.Void` — the void KEYWORD only, so a union that
    // merely contains `void` is testable.
    //
    // Never asked of a LOGICAL expression's own type: tsc builds `a && b` as
    // `getUnionType([falsyPartOf(a), b])` under LITERAL reduction, so
    // `undefined | void` stays a two-member union there and the void test sees
    // nothing — while ztsc subtype-reduces the same pair to `void`, because
    // `undefined` is a subtype of it. Asking anyway reported
    // `if (n && assertStr(n?.child?.value))` (an assertion signature returns
    // `void`), which tsc accepts (`narrowing/089`).
    if (c.ts.kind(ty) == .void and !isLogicalBinary(c, node)) {
        try c.diagFmt(1345, c.nodeSpan(node), "An expression of type 'void' cannot be tested for truthiness.", .{});
    }
    switch (try semanticsOf(c, node, 0)) {
        .sometimes => {},
        .always => try c.diagFmt(2872, c.nodeSpan(node), "This kind of expression is always truthy.", .{}),
        .never => try c.diagFmt(2873, c.nodeSpan(node), "This kind of expression is always falsy.", .{}),
    }
}

/// TS2774 "This condition will always return true since this function is always
/// defined. Did you mean to call it instead?" — tsc's
/// `checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType`, for the one
/// shape of it that needs no ancestry: the condition IS a plain reference to
/// something function-typed and non-nullable.
///
/// tsc's own version walks the `||`/`??` spine of the condition and each
/// `&&`/`||` operand, and lets the reference off whenever the same symbol is
/// used again anywhere in the surrounding binary chain (`isSymbolUsedIn
/// BinaryExpressionChain`) — `f && f()` is the idiom the escape exists for.
/// Reproducing that needs the chain ABOVE the operand being judged, which ztsc
/// (parent-pointer-free) does not have at the point it checks one, so this
/// implements only the operator-free case and leaves every logical-chain
/// condition to report nothing. Under-reports; never invents.
///
/// `body` is the statement or expression the condition guards; a reference to
/// the same name inside it is tsc's `isSymbolUsedInConditionBody` escape, and it
/// is compared by NAME rather than by symbol — a superset of tsc's escape, which
/// again only ever suppresses.
pub fn checkUncalledFunction(c: *Checker, node: Node, ty: types.TypeId, body: Node) Error!void {
    if (node == null_node) return;
    var loc = node;
    while (c.nodeTag(loc) == .paren_expr) {
        const inner = c.tree.nodeData(loc).lhs;
        if (inner == null_node) return;
        loc = inner;
    }
    const name_tok = switch (c.nodeTag(loc)) {
        .identifier => c.tree.nodeMainToken(loc),
        .member_expr => blk: {
            // tsc's `isPropertyExpressionCast` exemption: a member read off a
            // TYPE ASSERTION is how code narrows an `unknown` by hand
            // (`if ((result as I).always)`), and the assertion is the author
            // saying the shape is not to be trusted — so the "always defined"
            // claim is not made. `isTypeAssertion` skips parentheses first.
            var obj = c.tree.nodeData(loc).lhs;
            while (c.nodeTag(obj) == .paren_expr) {
                const inner = c.tree.nodeData(obj).lhs;
                if (inner == null_node) break;
                obj = inner;
            }
            switch (c.nodeTag(obj)) {
                .as_expr, .satisfies_expr => return,
                else => {},
            }
            break :blk c.tree.nodeData(loc).rhs;
        },
        else => return,
    };
    if (!try isAlwaysDefinedFunction(c, ty)) return;
    if (nameOccursIn(c, body, c.tokenText(name_tok))) return;
    try c.diagFmt(2774, c.nodeSpan(loc), "This condition will always return true since this function is always defined. Did you mean to call it instead?", .{});
}

/// tsc's two conditions on the tested type: it is truthy for certain
/// (`getTypeFacts(type, Truthy)`, so an optional `(() => void) | undefined` is
/// out) and it has at least one CALL signature. The promise arm (TS2801) is not
/// implemented.
fn isAlwaysDefinedFunction(c: *Checker, ty: types.TypeId) Error!bool {
    if (ty == types.no_type or ty == types.error_type) return false;
    // `if (someIdentifier)` is everywhere, so the kinds that CANNOT carry a call
    // signature are screened out on one already-loaded tag before anything walks
    // a union or resolves a reference.
    switch (c.ts.kind(ty)) {
        .any,
        .err,
        .none,
        .never,
        .void,
        .null,
        .undefined,
        .unknown,
        .boolean,
        .bool_true,
        .bool_false,
        .number,
        .number_literal,
        .number_literal_fresh,
        .string,
        .string_literal,
        .template_literal_type,
        .string_mapping,
        .bigint,
        .bigint_literal,
        .symbol,
        .unique_symbol,
        .enum_type,
        .array,
        .tuple,
        .object_keyword,
        => return false,
        else => {},
    }
    if (try c.canBeFalsy(ty, 0)) return false;
    const r = try c.resolveStructural(ty);
    return switch (c.ts.kind(r)) {
        .function, .overloads => true,
        .object => c.ts.objectCallSigCount(r) > 0,
        else => false,
    };
}

/// Does the identifier (or member name) `text` appear anywhere in `node`?
fn nameOccursIn(c: *Checker, node: Node, text: []const u8) bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        .identifier => {
            if (std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(node)), text)) return true;
        },
        .member_expr, .optional_member_expr => {
            if (std.mem.eql(u8, c.tokenText(c.tree.nodeData(node).rhs), text)) return true;
        },
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (nameOccursIn(c, child, text)) return true;
    }
    return false;
}

/// `&&` / `||` / `??`, through parentheses.
fn isLogicalBinary(c: *Checker, node0: Node) bool {
    var node = node0;
    while (c.nodeTag(node) == .paren_expr) {
        const inner = c.tree.nodeData(node).lhs;
        if (inner == null_node) return false;
        node = inner;
    }
    if (c.nodeTag(node) != .binary) return false;
    return switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
        .amp_amp, .pipe_pipe, .question_question => true,
        else => false,
    };
}

fn semanticsOf(c: *Checker, node0: Node, depth: u32) Error!Semantics {
    if (depth > 8) return .sometimes;
    // tsc's `skipOuterExpressions(node, OuterExpressionKinds.All)`: a
    // parenthesis, a type assertion (`as` / `satisfies`) and a non-null
    // assertion are all transparent to the classification.
    var node = node0;
    while (true) {
        const d = c.tree.nodeData(node);
        switch (c.nodeTag(node)) {
            .paren_expr, .non_null, .as_expr, .satisfies_expr => {
                if (d.lhs == null_node) return .sometimes;
                node = d.lhs;
            },
            else => break,
        }
    }
    const main_tok = c.tree.nodeMainToken(node);
    switch (c.nodeTag(node)) {
        // `0` and `1` are the two spellings tsc deliberately allows (`while
        // (1)`); every other value is a constant. Judged by VALUE, which is
        // what makes `1.0` and `0x1` allowances too.
        .number_literal => {
            const v = c.numberTokenValue(main_tok);
            return if (v == 0 or v == 1) .sometimes else .always;
        },
        .string_literal => {
            const a = try c.memberAtom(main_tok);
            return if (c.atomText(a).len == 0) .never else .always;
        },
        .template_literal => {
            const a = try c.templateAtom(main_tok);
            return if (c.atomText(a).len == 0) .never else .always;
        },
        // Classified by KIND, with no value test — `0n` included.
        .bigint_literal,
        .regex_literal,
        .array_literal,
        .object_literal,
        .arrow_fn,
        .function_expr,
        .function_decl,
        .class_decl,
        .jsx_element,
        => return .always,
        .null_literal => return .never,
        .prefix_unary => {
            // `void e` evaluates to `undefined`. No other prefix operator
            // folds — `-1` and `!x` are both "sometimes" for tsc.
            return if (c.tree.tokens.tag(main_tok) == .keyword_void) .never else .sometimes;
        },
        // The one identifier with a constant truthiness: `undefined`. Spelled
        // as a text test, exactly as `nullishKeywordOf` spells it — a local
        // binding named `undefined` is not legal in strict code.
        .identifier => {
            return if (std.mem.eql(u8, c.tokenText(main_tok), "undefined")) .never else .sometimes;
        },
        // `getSyntacticTruthySemantics` of a conditional is the INTERSECTION of
        // its branches: `v ? "a" : "b"` is always truthy however `v` goes.
        .cond_expr => {
            const e = c.tree.extraData(ast.CondExpr, c.tree.nodeData(node).rhs);
            const t = try semanticsOf(c, e.then_expr, depth + 1);
            if (t == .sometimes) return .sometimes;
            const f = try semanticsOf(c, e.else_expr, depth + 1);
            return if (t == f) t else .sometimes;
        },
        else => return .sometimes,
    }
}
