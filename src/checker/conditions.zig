//! What a CONDITION's expression is worth before it is evaluated:
//!
//!   * TS2872 "This kind of expression is always truthy."
//!   * TS2873 "This kind of expression is always falsy."
//!   * TS2774 "…this function is always defined. Did you mean to call it?"
//!   * TS2845 "This condition will always return '<true|false>'." — an enum
//!     member with a known value, or a comparison against `NaN`.
//!
//! The first two are tsc's `checkTruthinessOfType` /
//! `getSyntacticTruthySemantics` (TS 5.6's "disallowed nullish and truthy
//! checks"); the last two are `checkTestingKnownTruthyCallableOrAwaitableOr
//! EnumMemberType` and `checkNaNEquality`.
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
const binder = @import("../frontend/binder.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;

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

/// Walk context for `checkUncalledFunction`: the two things tsc reads through
/// parent pointers, which are not reachable from the node being judged. Both are
/// pure walk state — pushed and popped around the subtree they describe, never
/// consulted outside it.
pub const CondWalk = struct {
    /// One entry per LOGICAL expression whose left-operand subtree the check is
    /// currently inside, outermost first: the operand on its right, and whether
    /// its operator was `&&`.
    ///
    /// This is tsc's `isSymbolUsedInBinaryExpressionChain(condExpr.parent, sym)`,
    /// which walks up through `&&` PARENTS and searches each right operand for
    /// another use of the tested symbol — `f && f()` is the idiom the escape
    /// exists for, and `f && 1 && f()` is why it must see the whole chain rather
    /// than the nearest operand. The walk stops at the first non-`&&` parent,
    /// which is why `||`/`??` push an entry too: theirs is a BARRIER that hides
    /// the `&&`s above it (`if (f1 || f2)` must still report `f1`).
    ///
    /// `checkBinary` pushes around its left operand's check, so an entry lives
    /// exactly as long as the subtree it is an ancestor of. Capacity is
    /// retained: the depth is the source's logical nesting, so after warmup this
    /// never allocates.
    and_rights: std.ArrayListUnmanaged(ChainLink) = .empty,
    /// The `if`/`?:` branch guarded by the condition being walked, and the
    /// logical node that presently owns it. tsc lets a use in the guarded branch
    /// excuse a candidate anywhere in the condition's LOGICAL closure — every
    /// operand reachable from the condition through `&&`/`||`/`??` and
    /// parentheses, but not through a call argument (verified against tsgo:
    /// `if (f1 && f2 && f3) { f1(); }` excuses `f1` while
    /// `if (g(f1 && f2)) { f1(); }` does not). `body_root` is how that closure is
    /// tracked without parent pointers: each logical node that owns the body
    /// hands it to its own paren-skipped operands as it checks them.
    body: Node = null_node,
    body_root: Node = null_node,
};

pub const ChainLink = struct { right: Node, is_and: bool };

pub const SavedCondition = struct { body: Node, body_root: Node };

/// Publish an `if`/`?:` condition's guarded branch for the duration of the
/// condition's own walk. Only the two nodes are saved — the `and_rights` stack is
/// balanced by its own pusher and must keep the capacity the walk gave it.
pub fn enterCondition(c: *Checker, cond: Node, body: Node) SavedCondition {
    const saved: SavedCondition = .{ .body = c.cond_walk.body, .body_root = c.cond_walk.body_root };
    c.cond_walk.body = body;
    c.cond_walk.body_root = skipParens(c, cond);
    return saved;
}

pub fn leaveCondition(c: *Checker, s: SavedCondition) void {
    c.cond_walk.body = s.body;
    c.cond_walk.body_root = s.body_root;
}

/// Push `node`'s right operand as a chain link for the duration of its LEFT
/// operand's check, and hand the guarded body down to the operand being checked.
/// Returns the state to give back to `leaveLogicalOperand`.
pub fn enterLogical(c: *Checker, node: Node, is_and: bool) Error!SavedLogical {
    const d = c.tree.nodeData(node);
    try c.cond_walk.and_rights.append(c.cm(), .{ .right = d.rhs, .is_and = is_and });
    const saved: SavedLogical = .{ .body_root = c.cond_walk.body_root, .owns = node == c.cond_walk.body_root };
    if (saved.owns) c.cond_walk.body_root = skipParens(c, d.lhs);
    return saved;
}

/// End the left operand's chain link; the right operand inherits the body but
/// not the link (its candidates' parents are this node, which is no longer an
/// ANCESTOR-of-the-left).
pub fn leaveLeftOperand(c: *Checker, node: Node, saved: SavedLogical) void {
    _ = c.cond_walk.and_rights.pop();
    if (saved.owns) c.cond_walk.body_root = skipParens(c, c.tree.nodeData(node).rhs);
}

pub fn leaveLogical(c: *Checker, saved: SavedLogical) void {
    c.cond_walk.body_root = saved.body_root;
}

pub const SavedLogical = struct { body_root: Node, owns: bool };

/// The guarded body a logical node's own candidates may be excused by: non-null
/// only while that node is inside the condition's logical closure.
pub fn bodyFor(c: *const Checker, node: Node) Node {
    return if (node == c.cond_walk.body_root) c.cond_walk.body else null_node;
}

/// tsc's `checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType`, which
/// reports two things about a condition that cannot go either way:
///
///   * TS2774 "This condition will always return true since this function is
///     always defined. Did you mean to call it instead?" — the tested reference
///     is function-typed and non-nullable, i.e. the author forgot the `()`;
///   * TS2845 "This condition will always return '{0}'." — the tested reference
///     is an ENUM MEMBER whose constant value is known, so its truthiness is.
///
/// The two positions tsc checks are an `if` condition (`body` = the
/// then-statement) and a `?:` condition (`body` = the whenTrue branch), plus the
/// LEFT operand of every `&&` (`checkBinary`). A `while`/`do`/`for` condition is
/// NOT one of them — verified against tsgo, which reports nothing for
/// `while (isFoo)` while reporting for `if (isFoo)`.
///
/// From the given root the walk is tsc's `bothHelper`/`helper` pair: the LEFT
/// spine of the root is walked all the way down (through every logical
/// operator), each element's RIGHT operand is judged, and a right operand that
/// is itself logical starts the same walk one level in. `if (b && (f1 || f2))`
/// reports on BOTH `f1` and `f2` that way.
///
/// `seed_chain` says whether the chain links already on `CondWalk.and_rights`
/// are this root's — true for `checkBinary`'s `&&` arm (the enclosing `&&`s are
/// exactly what it pushed), false for a condition, whose parent is a statement.
///
/// Duplicates are expected and harmless: the `&&` arm and the condition walk
/// deliberately overlap (tsc's do too), and `diagFmt` dedupes by span.
pub fn checkUncalledFunction(c: *Checker, cond: Node, ty: types.TypeId, body: Node, seed_chain: bool) Error!void {
    var chain: std.ArrayList(Node) = .empty;
    defer chain.deinit(c.scratch());
    if (seed_chain) {
        // Only the contiguous run of `&&` links closest to the top: a `||`/`??`
        // link is a barrier (see `CondWalk.and_rights`).
        const links = c.cond_walk.and_rights.items;
        var i = links.len;
        while (i > 0 and links[i - 1].is_and) : (i -= 1) {
            try chain.append(c.scratch(), links[i - 1].right);
        }
    }
    try bothHelper(c, cond, ty, body, &chain, 0);
}

/// Recursion cap for the `bothHelper` -> `helper` -> `bothHelper` descent, which
/// only ever recurses through a logical operand's RIGHT side (the left spine is
/// the loop below). A right-nested chain that deep is not real source.
const max_cond_depth = 16;

fn bothHelper(c: *Checker, cond0: Node, ty: types.TypeId, body: Node, chain: *std.ArrayList(Node), depth: u32) Error!void {
    if (cond0 == null_node or depth > max_cond_depth) return;
    var cond = skipParens(c, cond0);
    var first = true;
    while (true) {
        try helper(c, cond, if (first) ty else types.no_type, body, chain, depth);
        first = false;
        const op = logicalOp(c, cond) orelse break;
        const left = c.tree.nodeData(cond).lhs;
        if (left == null_node) break;
        // Descending one step to the left makes THIS node the next candidate's
        // parent: a `&&` adds its right operand to the chain, anything else cuts
        // the chain outright.
        if (op == .amp_amp) {
            try chain.append(c.scratch(), c.tree.nodeData(cond).rhs);
        } else {
            chain.clearRetainingCapacity();
        }
        cond = skipParens(c, left);
    }
}

fn helper(c: *Checker, cond: Node, ty: types.TypeId, body: Node, chain: *std.ArrayList(Node), depth: u32) Error!void {
    if (cond == null_node) return;
    // A logical expression is judged through its RIGHT operand; the left one is
    // the next step of the spine walk above.
    const location = if (logicalOp(c, cond) != null)
        skipParens(c, c.tree.nodeData(cond).rhs)
    else
        cond;
    if (location == null_node) return;
    if (logicalOp(c, location) != null) {
        // The recursion's candidates hang off `location`, whose own parent is
        // `cond` — reached only through a right operand or a parenthesis, so the
        // `&&` chain never continues into it.
        var inner: std.ArrayList(Node) = .empty;
        defer inner.deinit(c.scratch());
        return bothHelper(c, location, types.no_type, body, &inner, depth + 1);
    }
    const loc_ty = if (location == cond and ty != types.no_type) ty else c.nodeType(location) orelse return;
    try checkTestedReference(c, location, loc_ty, body, chain.items);
}

/// The judgement on ONE tested reference (tsc's `helper` body).
fn checkTestedReference(c: *Checker, loc: Node, ty: types.TypeId, body: Node, chain: []const Node) Error!void {
    const name_tok = switch (c.nodeTag(loc)) {
        .identifier => c.tree.nodeMainToken(loc),
        .member_expr, .optional_member_expr => blk: {
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
    // The enum arm takes no escape: `E.One && use(E.One)` is still reported,
    // because a constant that cannot be falsy is a mistake however the value is
    // used afterwards (oracle-verified against tsgo).
    if (try enumMemberVerdict(c, loc)) |always| {
        try c.diagFmt(2845, c.nodeSpan(loc), "This condition will always return '{s}'.", .{
            if (always) "true" else "false",
        });
        return;
    }
    if (!try isAlwaysDefinedFunction(c, ty)) return;
    const tested = try testedRef(c, loc, name_tok);
    // tsc's `isSymbolUsedInConditionBody`: the guarded branch already uses the
    // thing that was tested, so the author did not forget the call.
    if (try refUsedIn(c, body, &tested, c.cur_scope)) return;
    // tsc's `isSymbolUsedInBinaryExpressionChain`, which compares the tested
    // SYMBOL alone — no receiver test, so `a.f && b.f()` really does excuse
    // `a.f` when both name the same declared property (oracle-verified).
    for (chain) |right| {
        if (try chainUsesRef(c, right, &tested, c.cur_scope)) return;
    }
    try c.diagFmt(2774, c.nodeSpan(loc), "This condition will always return true since this function is always defined. Did you mean to call it instead?", .{});
}

/// TS2845's enum arm: is `loc` a member access `E.M` on an ENUM whose member
/// `M` has a written constant value? Returns that value's truthiness.
///
/// The receiver must be the enum itself, not merely something enum-member
/// typed: tsc asks `getSymbolAtLocation(location)` for an enum-member symbol, so
/// `const alias = E.One; if (alias)` and `if (o.field)` (field typed `E.One`)
/// are both silent, and `if (E["One"])` — an element access — is too.
///
/// "Written" excludes an auto-numbered member of an AMBIENT enum, which tsc
/// gives no constant value at all (`declare enum E { A, B = 1 }`: `if (E.A)` is
/// silent while `if (E.B)` reports). A `const enum` always has values, ambient
/// or not; outside those two, requiring an initializer only under-reports.
fn enumMemberVerdict(c: *Checker, loc: Node) Error!?bool {
    switch (c.nodeTag(loc)) {
        .member_expr, .optional_member_expr => {},
        else => return null,
    }
    const mt = c.nodeType(loc) orelse return null;
    if (!c.ts.isEnumMember(mt)) return null;
    const esym: SymbolId = c.ts.enumSymbol(mt);
    const name = c.ts.enumMemberAtom(mt);
    // The RECEIVER has to be the enum object itself, which is exactly the type
    // `enumValueType` interns for it. Without this test any property that merely
    // HAPPENS to be enum-member typed would qualify.
    if (c.nodeType(c.tree.nodeData(loc).lhs) != try c.enumValueType(esym)) return null;
    if (!try enumMemberHasWrittenValue(c, esym, name)) return null;
    const v = (try c.enumMemberValue(esym, name)) orelse return null;
    return switch (c.ts.kind(v)) {
        .number_literal, .number_literal_fresh => c.ts.numberValue(v) != 0,
        .string_literal => c.atomText(c.ts.literalAtom(v)).len != 0,
        else => null,
    };
}

fn enumMemberHasWrittenValue(c: *Checker, esym: SymbolId, name: Atom) Error!bool {
    if ((try c.enumInfo(esym)).is_const) return true;
    const saved = c.enterSymFile(esym);
    defer c.restoreCtx(saved);
    for (c.declsOf(esym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            if ((try c.memberAtom(c.tree.nodeMainToken(m))) != name) continue;
            return c.tree.nodeData(m).lhs != null_node;
        }
    }
    return false;
}

/// TS2845's other source — tsc's `checkNaNEquality`. A comparison against the
/// global `NaN` is decided before it runs: `===`/`==` can only be false and
/// `!==`/`!=` can only be true, because `NaN` equals nothing, itself included.
/// Anchored on the whole comparison, and only for the GLOBAL `NaN`: a parameter
/// or local of that name is an ordinary number (tsc resolves the symbol and
/// compares it to `globalNaNSymbol`).
pub fn checkNaNEquality(c: *Checker, node: Node, lhs: Node, rhs: Node) Error!void {
    if (!isGlobalNaN(c, skipParens(c, lhs)) and !isGlobalNaN(c, skipParens(c, rhs))) return;
    const eq = switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
        .eq_eq, .eq_eq_eq => true,
        else => false,
    };
    try c.diagFmt(2845, c.nodeSpan(node), "This condition will always return '{s}'.", .{
        if (eq) "false" else "true",
    });
}

fn isGlobalNaN(c: *Checker, node: Node) bool {
    if (node == null_node or c.nodeTag(node) != .identifier) return false;
    const tok = c.tree.nodeMainToken(node);
    if (!std.mem.eql(u8, c.tokenText(tok), "NaN")) return false;
    const a = c.atom("NaN") catch return false;
    const g = c.prog.globals.lookup(a) orelse return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| sym == g,
        else => false,
    };
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

/// The longest dotted path a tested reference can be compared by. `a.b.c.d.e.f`
/// nested deeper than this degrades to the name-only test, which suppresses.
const max_ref_path = 6;

/// What a tested reference IS, for the two escapes: its dotted path (base first,
/// one element for a bare name) and, when it is a bare name, the symbol it
/// resolves to.
const TestedRef = struct {
    buf: [max_ref_path][]const u8 = undefined,
    len: usize = 0,
    /// `no_symbol` when the reference is a member access, or when the name did
    /// not resolve — then the text stands in for the symbol.
    sym: SymbolId = binder.no_symbol,

    fn parts(self: *const TestedRef) []const []const u8 {
        return self.buf[0..self.len];
    }
    fn last(self: *const TestedRef) []const u8 {
        return self.buf[self.len - 1];
    }
};

fn testedRef(c: *Checker, loc: Node, name_tok: ast.TokenIndex) Error!TestedRef {
    var out: TestedRef = .{};
    if (c.nodeTag(loc) == .identifier) {
        out.buf[0] = c.tokenText(name_tok);
        out.len = 1;
        out.sym = switch (c.resolveSpace(try c.atomOfToken(name_tok), c.cur_scope, true)) {
            .sym => |s| s,
            else => binder.no_symbol,
        };
        return out;
    }
    // A member access, written back-to-front and then reversed.
    var n = loc;
    while (out.len < max_ref_path) {
        switch (c.nodeTag(n)) {
            .member_expr, .optional_member_expr => {
                out.buf[out.len] = c.tokenText(c.tree.nodeData(n).rhs);
                out.len += 1;
                n = skipParens(c, c.tree.nodeData(n).lhs);
            },
            // tsc's walk steps over a CALL on both sides at once
            // (`chrome.keys.subtle().exportKey` matches itself), so the call is
            // a path component of its own — one no source name can collide with.
            .call_expr, .call_expr_targs, .optional_call => {
                out.buf[out.len] = "()";
                out.len += 1;
                n = skipParens(c, c.tree.nodeData(n).lhs);
            },
            .identifier, .this_expr => {
                out.buf[out.len] = if (c.nodeTag(n) == .this_expr) "this" else c.tokenText(c.tree.nodeMainToken(n));
                out.len += 1;
                std.mem.reverse([]const u8, out.buf[0..out.len]);
                return out;
            },
            else => break,
        }
    }
    // Not a plain entity name (`f().g`, a chain deeper than the buffer): fall
    // back to the member NAME alone, which only ever suppresses.
    out.buf[0] = c.tokenText(name_tok);
    out.len = 1;
    return out;
}

/// tsc's `isSymbolUsedInConditionBody`: does `node` use the very thing the
/// condition tested? A bare name is compared by SYMBOL, so a parameter or local
/// that merely shadows it does not excuse the condition
/// (`if (f) { [1].forEach(f => f) }` is still reported); a member access is
/// compared by its whole dotted path, so `if (a.g) { b.g(); }` is too.
fn refUsedIn(c: *Checker, node: Node, tested: *const TestedRef, scope: binder.ScopeId) Error!bool {
    if (node == null_node) return false;
    const cur = (try c.scopeOf(node)) orelse scope;
    if (tested.len == 1) {
        if (c.nodeTag(node) == .identifier) {
            const tok = c.tree.nodeMainToken(node);
            if (std.mem.eql(u8, c.tokenText(tok), tested.buf[0])) {
                if (tested.sym == binder.no_symbol) return true;
                switch (c.resolveSpace(try c.atomOfToken(tok), cur, true)) {
                    .sym => |s| if (s == tested.sym) return true,
                    else => {},
                }
            }
        }
    } else switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr => {
            const probe = try testedRef(c, node, c.tree.nodeData(node).rhs);
            if (probe.len == tested.len) {
                var all = true;
                for (probe.parts(), tested.parts()) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        all = false;
                        break;
                    }
                }
                if (all) return true;
            }
        },
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (try refUsedIn(c, child, tested, cur)) return true;
    }
    return false;
}

/// tsc's `isSymbolUsedInBinaryExpressionChain`, which compares only the tested
/// SYMBOL — no receiver test. A property has no symbol identity in ztsc, so its
/// name stands in (a superset, which only suppresses).
fn chainUsesRef(c: *Checker, node: Node, tested: *const TestedRef, scope: binder.ScopeId) Error!bool {
    if (node == null_node) return false;
    const cur = (try c.scopeOf(node)) orelse scope;
    switch (c.nodeTag(node)) {
        .identifier => {
            const tok = c.tree.nodeMainToken(node);
            if (std.mem.eql(u8, c.tokenText(tok), tested.last())) {
                if (tested.sym == binder.no_symbol) return true;
                switch (c.resolveSpace(try c.atomOfToken(tok), cur, true)) {
                    .sym => |s| if (s == tested.sym) return true,
                    else => {},
                }
            }
        },
        .member_expr, .optional_member_expr => {
            if (tested.len > 1 and std.mem.eql(u8, c.tokenText(c.tree.nodeData(node).rhs), tested.last())) return true;
        },
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (try chainUsesRef(c, child, tested, cur)) return true;
    }
    return false;
}

/// tsc's `skipParentheses`.
fn skipParens(c: *const Checker, node0: Node) Node {
    var node = node0;
    while (node != null_node and c.nodeTag(node) == .paren_expr) {
        const inner = c.tree.nodeData(node).lhs;
        if (inner == null_node) break;
        node = inner;
    }
    return node;
}

/// tsc's `isLogicalOrCoalescingBinaryExpression`: the operator of `node` when it
/// is `&&` / `||` / `??`, null otherwise. Not paren-skipping — every caller has
/// already done that, and tsc's predicate is on the node itself.
fn logicalOp(c: *const Checker, node: Node) ?scanner.Tag {
    if (node == null_node or c.nodeTag(node) != .binary) return null;
    return switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
        .amp_amp => .amp_amp,
        .pipe_pipe => .pipe_pipe,
        .question_question => .question_question,
        else => null,
    };
}

/// `&&` / `||` / `??`, through parentheses.
fn isLogicalBinary(c: *Checker, node0: Node) bool {
    return logicalOp(c, skipParens(c, node0)) != null;
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
