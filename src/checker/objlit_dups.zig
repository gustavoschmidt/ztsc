//! Duplicate keys in an object literal — tsc's
//! `checkGrammarObjectLiteralExpression`, the one check that reads an object
//! literal's keys for their own sake rather than to build its type.
//!
//! Four codes come out of one walk, chosen by what the two colliding entries
//! ARE (tsc's `DeclarationMeaning`):
//!
//!   * two methods                        → TS2300 (duplicate identifier)
//!   * anything else among property/method → TS1117 (multiple properties)
//!   * two accessors of the same kind      → TS1118 (multiple get/set)
//!   * an accessor against a property      → TS1119 (property and accessor)
//!
//! A get/set PAIR is legal, so the first collision between the two accessor
//! kinds merges their meanings instead of reporting; a third accessor then
//! collides with the merged pair. TS1118 and TS1119 stop the walk, matching
//! tsc's early `return`.
//!
//! The key a property is filed under is `atoms.zig`'s business, and using it
//! here is what makes `{ 0x20: 0, 3.2e1: 0 }` one key (`"32"`) and
//! `{ [n]: 1, [n]: 1 }` — a LATE-BOUND name, not a syntactic one — a duplicate
//! as well.
//!
//! Not run for a destructuring assignment (`({ a, a } = x)` is legal cover
//! grammar): those patterns never reach `checkObjectLiteral` at all, they go
//! through `checkDestructuringElement`.

const std = @import("std");

const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const Span = source.Span;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// What an object-literal entry contributes to a name, as a bit set so a
/// get/set pair can be one merged meaning (tsc's `DeclarationMeaning`).
const Meaning = struct {
    const getter: u8 = 1;
    const setter: u8 = 2;
    const property: u8 = 4;
    const method: u8 = 8;

    const accessor: u8 = getter | setter;
    const prop_or_method: u8 = property | method;
};

/// Report every duplicate key in the object literal `node`.
pub fn checkObjectLiteralDups(c: *Checker, node: Node) Error!void {
    var seen: std.AutoHashMapUnmanaged(Atom, u8) = .empty;
    defer seen.deinit(c.scratch());
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const cur = meaningOf(c, prop) orelse continue;
        const key = (try effectiveKey(c, prop)) orelse continue;
        const gop = try seen.getOrPut(c.scratch(), key);
        if (!gop.found_existing) {
            gop.value_ptr.* = cur;
            continue;
        }
        const existing = gop.value_ptr.*;
        const span = keySpan(c, prop);
        const text = keyText(c, prop, key);
        if (cur & Meaning.method != 0 and existing & Meaning.method != 0) {
            try c.diagFmt(2300, span, "Duplicate identifier '{s}'.", .{text});
        } else if (cur & Meaning.prop_or_method != 0 and existing & Meaning.prop_or_method != 0) {
            try c.diagFmt(1117, span, "An object literal cannot have multiple properties with the same name.", .{});
        } else if (cur & Meaning.accessor != 0 and existing & Meaning.accessor != 0) {
            // A get beside a set is the one legal collision: remember that
            // BOTH have now been seen, so a third accessor reports.
            if (existing != Meaning.accessor and cur != existing) {
                gop.value_ptr.* = cur | existing;
                continue;
            }
            // Two accessors of the SAME kind are also a plain duplicate to
            // tsc's binder, which reports it at every declaration of the name
            // it has seen — the earlier get, the set that legally paired with
            // it, and this one — on top of the grammar error here.
            try reportAccessorDups(c, node, key, prop);
            try c.diagFmt(1118, span, "An object literal cannot have multiple get/set accessors with the same name.", .{});
            return;
        } else {
            try c.diagFmt(1119, span, "An object literal cannot have property and accessor with the same name.", .{});
            return;
        }
    }
}

/// TS2300 at every entry of `node` named `key`, up to and including `last` —
/// the binder-level duplicate that accompanies a same-kind accessor clash.
fn reportAccessorDups(c: *Checker, node: Node, key: Atom, last: Node) Error!void {
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        if (meaningOf(c, prop) != null) {
            if ((try effectiveKey(c, prop)) == key) {
                try c.diagFmt(2300, keySpan(c, prop), "Duplicate identifier '{s}'.", .{keyText(c, prop, key)});
            }
        }
        if (prop == last) return;
    }
}

/// The meaning an entry contributes, or null for one that names nothing (a
/// spread element, a parse error).
fn meaningOf(c: *Checker, prop: Node) ?u8 {
    switch (c.nodeTag(prop)) {
        .object_property, .object_shorthand => return Meaning.property,
        .object_method => {
            const fn_node = c.tree.nodeData(prop).rhs;
            if (fn_node == null_node) return Meaning.method;
            const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(fn_node).lhs);
            if (proto.flags & ast.Flags.get != 0) return Meaning.getter;
            if (proto.flags & ast.Flags.set != 0) return Meaning.setter;
            return Meaning.method;
        },
        else => return null,
    }
}

/// The computed-name node of an entry, or 0 when its key is written plainly.
fn computedNameOf(c: *Checker, prop: Node) Node {
    const lhs = switch (c.nodeTag(prop)) {
        .object_property, .object_method => c.tree.nodeData(prop).lhs,
        else => return 0,
    };
    if (lhs == null_node or c.nodeTag(lhs) != .computed_name) return 0;
    return lhs;
}

/// The name an entry is filed under, or null when it has none — a computed key
/// whose expression is not a literal or a `unique symbol` is tsc's
/// `getPropertyNameForPropertyNameNode` returning `undefined`, and two such
/// keys are never duplicates of each other however they are spelled.
fn effectiveKey(c: *Checker, prop: Node) Error!?Atom {
    const computed = computedNameOf(c, prop);
    if (computed == 0) return try c.memberAtom(c.tree.nodeMainToken(prop));
    const key_expr = c.tree.nodeData(computed).lhs;
    if (key_expr == null_node) return null;
    if (try signedNumericKey(c, key_expr)) |a| return a;
    // The type walk has already run (see the call site), so the key's type is a
    // memo read here — never a fresh evaluation, which would make this check
    // the first reader of a key nothing else reads and put its diagnostics on
    // this walk's account.
    const kt = c.nodeType(key_expr) orelse return null;
    if (try c.uniqueSymAtom(kt)) |a| return a;
    return try c.literalKeyAtom(kt);
}

/// tsc's `isSignedNumericLiteral` arm of `getPropertyNameForPropertyNameNode`:
/// `[+1]` names `"1"` and `[-1]` names `"-1"`, read off the SYNTAX. ztsc types
/// a signed literal as plain `number`, so without this arm `{ 1: 1, [+1]: 0 }`
/// and `{ "-1": 1, [-1]: 0 }` were not duplicates.
fn signedNumericKey(c: *Checker, key_expr: Node) Error!?Atom {
    if (c.nodeTag(key_expr) != .prefix_unary) return null;
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(key_expr));
    const operand = c.tree.nodeData(key_expr).lhs;
    if (operand == null_node or c.nodeTag(operand) != .number_literal) return null;
    const name = try c.memberAtom(c.tree.nodeMainToken(operand));
    switch (op) {
        .plus => return name,
        .minus => return try c.internText(
            try std.fmt.allocPrint(c.scratch(), "-{s}", .{c.atomText(name)}),
        ),
        else => return null,
    }
}

/// Where the report goes: the whole `[expr]` for a computed key, the name
/// token otherwise (never the `get`/`set` keyword — tsc anchors on
/// `prop.name`).
fn keySpan(c: *Checker, prop: Node) Span {
    const computed = computedNameOf(c, prop);
    if (computed != 0) return c.nodeSpan(computed);
    return c.tokSpan(c.tree.nodeMainToken(prop));
}

/// The key for the one message that names it (TS2300): as WRITTEN for a plain
/// name, and the name it late-bound to for a computed one (there is no token to
/// quote there, and `[k]` says nothing about which property it is).
fn keyText(c: *Checker, prop: Node, key: Atom) []const u8 {
    if (computedNameOf(c, prop) != 0) return c.atomText(key);
    return c.tokenText(c.tree.nodeMainToken(prop));
}
