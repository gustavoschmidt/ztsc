//! Which modifier may follow which, on a class member or a parameter property.
//!
//! One pure walk over a member's modifier run → the ONE diagnostic it earns, or
//! null. It is tsc's `checkGrammarModifiers`, transcribed per modifier and in
//! tsc's own order — that order is load-bearing twice over, because tsc
//! `return`s on its FIRST hit:
//!
//!   * across modifiers, so `accessor public static x` answers for `public`
//!     alone and never mentions `static`;
//!   * within one modifier's arm, so `abstract abstract m()` in a plain class
//!     answers TS1244 for the FIRST `abstract` rather than TS1030 for the
//!     second — the position rule of an earlier modifier outranks the repeat
//!     rule of a later one.
//!
//! The walk therefore needs the member's KIND, which the parser only learns
//! after the run is read (a `constructor` is one until the `(` proves it). So
//! the run is collected as `Mod`s and judged here once the kind is known, and
//! the caller reports whatever comes back.
//!
//! Two families of rule live here: REPEAT/ORDER (TS1030/TS1029/TS1028), which
//! need only the modifiers, and POSITION (TS1242/TS1244/TS1253/TS1089), which
//! needs the kind. The positions ztsc answers elsewhere — TS1044 on a module
//! element, TS1090 on a parameter, TS1071 on an index signature — stay out, and
//! each is marked below where tsc's walk would have reached it. Where ztsc has
//! no answer for a rule, this returns null and the pair is silently accepted:
//! an under-report never manufactures a wrong key, while guessing the NEXT
//! arm's code in tsc's chain would.

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const Code = diagnostics.Code;
const F = ast.Flags;

const access = F.public | F.private | F.protected;

/// One modifier of a member's run: its `ast.Flags` bit and the token it was
/// written at (which is where its diagnostic is blamed).
pub const Mod = struct { bit: u32, token: u32 };

/// What the modified declaration IS — tsc's `node.kind`, narrowed to the
/// distinctions its `checkGrammarModifiers` actually makes.
pub const Member = enum {
    /// A `constructor(…)` that is not `get`/`set`. Note that `static` does NOT
    /// take a member out of this class: tsc's parser builds a
    /// `ConstructorDeclaration` for `static constructor() {}` too, which is
    /// exactly why TS1089 exists to reject the `static`.
    constructor,
    /// A method, including a generator and an overload signature.
    method,
    /// `get x()` / `set x(v)` — a method for every rule here.
    accessor,
    /// A field, including an `accessor` field.
    property,
    /// Every position whose POSITION rules ztsc answers elsewhere or not at
    /// all: an index signature (TS1071, `index_signature.zig`), a constructor
    /// parameter property (TS1090, `param_modifiers.zig`), and a member whose
    /// name failed to parse. Repeat and order rules still apply.
    other,
};

/// The one diagnostic a modifier run earns, and the modifier it is blamed on.
pub const Finding = struct { code: Code, token: u32 };

/// tsc's whole `checkGrammarModifiers` for a class member: the per-modifier
/// walk, then the constructor-only block that closes it.
pub fn walk(mods: []const Mod, member: Member, in_abstract_class: bool) ?Finding {
    var already: u32 = 0;
    for (mods) |m| {
        if (check(already, m.bit, member, in_abstract_class)) |code| {
            // tsc blames every one of these on the modifier its walk is
            // standing on, with the single exception noted in the `abstract`
            // arm: the async pair says `grammarErrorOnNode(lastAsync, …)`.
            const at = if (code == .mod_pair_async_abstract)
                lastToken(mods, F.async) orelse m.token
            else
                m.token;
            return .{ .code = code, .token = at };
        }
        already |= m.bit;
    }
    // tsc's trailing `if (node.kind === SyntaxKind.Constructor)` block: it runs
    // only when the walk above found nothing, and asks in this fixed order —
    // which is why `static abstract constructor()` is the `abstract`'s TS1242
    // (found in the walk) and not the `static`'s TS1089.
    if (member == .constructor) {
        if (lastToken(mods, F.static)) |t| return .{ .code = .ctor_mod_static, .token = t };
        if (lastToken(mods, F.override)) |t| return .{ .code = .ctor_mod_override, .token = t };
        if (lastToken(mods, F.async)) |t| return .{ .code = .ctor_mod_async, .token = t };
        // tsc's block ends `return false` — a constructor never reaches the
        // async check below.
        return null;
    }
    // tsc's `checkGrammarAsyncModifier`, the last thing the pass asks:
    // TS1042, because `async` describes a BODY and a member that has none —
    // a field, an auto-accessor field, a `get`/`set` — cannot carry it. A
    // method may; an index signature (`.other`) answered TS1071 before the
    // walk began. Blamed on `lastAsync`, and a TRAILING check rather than an
    // arm of the walk, so every pair rule above outranks it.
    if (member == .accessor or member == .property) {
        if (lastToken(mods, F.async)) |t| {
            return .{ .code = .async_modifier_not_allowed_here, .token = t };
        }
    }
    return null;
}

/// tsc's `lastStatic`/`lastOverride`/`lastAsync`: the LAST modifier of a kind
/// the run carried, which is the token its trailing block blames.
fn lastToken(mods: []const Mod, bit: u32) ?u32 {
    var found: ?u32 = null;
    for (mods) |m| {
        if (m.bit == bit) found = m.token;
    }
    return found;
}

/// The diagnostic for adding `bit` to a member that already carries `already`,
/// or null when the combination is legal or unanswered. `bit` is a single
/// `ast.Flags` modifier bit (`classMemberModifierBit`'s result).
///
/// `in_abstract_class` is tsc's `node.parent.kind === ClassDeclaration &&
/// hasSyntacticModifier(node.parent, Abstract)` — a class EXPRESSION is never
/// abstract, so its members answer TS1244/TS1253 like a plain class's.
pub fn check(already: u32, bit: u32, member: Member, in_abstract_class: bool) ?Code {
    return switch (bit) {
        F.public => accessCode(already, .mod_order_public_static, .mod_order_public_override, .mod_order_public_accessor, .mod_order_public_readonly, .mod_order_public_async, .mod_order_public_abstract),
        F.protected => accessCode(already, .mod_order_protected_static, .mod_order_protected_override, .mod_order_protected_accessor, .mod_order_protected_readonly, .mod_order_protected_async, .mod_order_protected_abstract),
        // `private abstract` is TS1243 ("cannot be used with"), not TS1029, so
        // `private` passes the pair code where the other two pass an order one.
        F.private => accessCode(already, .mod_order_private_static, .mod_order_private_override, .mod_order_private_accessor, .mod_order_private_readonly, .mod_order_private_async, .mod_pair_private_abstract),

        F.static => blk: {
            if (already & F.static != 0) break :blk .mod_seen_static;
            if (already & F.readonly != 0) break :blk .mod_order_static_readonly;
            if (already & F.async != 0) break :blk .mod_order_static_async;
            if (already & F.accessor != 0) break :blk .mod_order_static_accessor;
            // tsc reaches TS1044 (module element) and TS1090 (parameter) here;
            // both are positions ztsc answers elsewhere. Then `static abstract`
            // is TS1243, which stops the walk — so an `abstract` already seen
            // must NOT fall through to the `override` arm below.
            if (already & F.abstract != 0) break :blk .mod_pair_static_abstract;
            if (already & F.override != 0) break :blk .mod_order_static_override;
            break :blk null;
        },

        F.override => blk: {
            if (already & F.override != 0) break :blk .mod_seen_override;
            if (already & F.declare != 0) break :blk .mod_pair_override_declare;
            if (already & F.readonly != 0) break :blk .mod_order_override_readonly;
            if (already & F.accessor != 0) break :blk .mod_order_override_accessor;
            if (already & F.async != 0) break :blk .mod_order_override_async;
            break :blk null;
        },

        F.abstract => blk: {
            if (already & F.abstract != 0) break :blk .mod_seen_abstract;
            // tsc's remaining `abstract` arms sit inside a guard that excludes a
            // class DECLARATION (and a constructor TYPE), and its two position
            // rules come first: `abstract` on anything that is not a method,
            // accessor or property is TS1242, and on one of those in a class
            // that is not abstract it is TS1244 / TS1253.
            switch (member) {
                .constructor => break :blk .abstract_modifier_not_valid_here, // TS1242
                // An index signature answered TS1071 before the walk began, and
                // a parameter TS1090; a member with no name has no kind.
                .other => break :blk null,
                .property => if (!in_abstract_class) break :blk .abstract_property_outside_abstract_class,
                .method, .accessor => if (!in_abstract_class) break :blk .abstract_method_outside_abstract_class,
            }
            // The TS1243 pairs. tsc hard-codes each arm's two words, so they
            // read the same whichever order they were written in and only the
            // blamed token — this `abstract` — moves.
            if (already & F.static != 0) break :blk .mod_pair_static_abstract;
            if (already & F.private != 0) break :blk .mod_pair_private_abstract;
            // The one pair tsc does NOT blame on the modifier its walk is
            // standing on: its arm reads `grammarErrorOnNode(lastAsync, …)`,
            // so `async abstract m()` and `abstract async m()` BOTH point at
            // the `async`. `walk` re-anchors it.
            if (already & F.async != 0) break :blk .mod_pair_async_abstract;
            if (already & F.override != 0) break :blk .mod_order_abstract_override;
            if (already & F.accessor != 0) break :blk .mod_order_abstract_accessor;
            break :blk null;
        },

        F.accessor => blk: {
            if (already & F.accessor != 0) break :blk .mod_seen_accessor;
            if (already & F.readonly != 0) break :blk .mod_pair_accessor_readonly;
            if (already & F.declare != 0) break :blk .mod_pair_accessor_declare;
            // TS1275 ends the chain: an auto-accessor is a PROPERTY and
            // nothing else. `.other` is left out for the usual reason — an
            // index signature answered TS1071 before the walk began, and a
            // member whose name failed to parse has no kind to judge.
            break :blk switch (member) {
                .constructor, .method, .accessor => .accessor_modifier_not_valid_here,
                .property, .other => null,
            };
        },

        F.readonly => blk: {
            if (already & F.readonly != 0) break :blk .mod_seen_readonly;
            // The mirror of the `accessor` arm's first pair: both modifiers
            // carry an arm that names itself first, so the two orders read
            // differently.
            if (already & F.accessor != 0) break :blk .mod_pair_readonly_accessor;
            // TS1024, `readonly`'s own position rule, closes the arm. It has
            // to be answered here and not left null: `readonly accessor m()`
            // is this, and a null would hand the member to the `accessor` arm
            // behind it and manufacture the TS1243 tsc never reaches.
            break :blk switch (member) {
                .constructor, .method, .accessor => .readonly_not_on_property,
                // A property takes it; an index signature and a parameter are
                // the other two kinds tsc exempts, and both land in `.other`.
                .property, .other => null,
            };
        },
        F.async => blk: {
            if (already & F.async != 0) break :blk .mod_seen_async;
            // tsc reaches TS1040 (ambient) and TS1090 (parameter) here. TS1042
            // is NOT part of this arm — it is `checkGrammarAsyncModifier`, a
            // TRAILING check like the constructor block, which is why `async
            // abstract p: number` answers the pair and not TS1042.
            break :blk if (already & F.abstract != 0) .mod_pair_async_abstract else null;
        },
        // TS1031 after the repeat, as tsc's `case DeclareKeyword` chain has it:
        // a `declare` on a class element that is not a PROPERTY. `.other` is
        // left out — the kinds it covers (an index signature, a member whose
        // name failed to parse) answer their position rules elsewhere or not at
        // all, and guessing here could only invent a diagnostic.
        F.declare => blk: {
            if (already & F.declare != 0) break :blk .mod_seen_declare;
            break :blk switch (member) {
                .constructor, .method, .accessor => .declare_on_class_element,
                // `accessor declare x` — tsc's `case DeclareKeyword` reaches
                // the accessor pair only PAST the TS1031 above, so a member
                // that is not a property answers for its position first.
                .property, .other => if (already & F.accessor != 0)
                    .mod_pair_declare_accessor
                else
                    null,
            };
        },

        else => null,
    };
}

/// The `public`/`protected`/`private` chain, which is one shape with the word
/// substituted — tsc's `visibilityToString(modifierToFlag(modifier.kind))`.
/// A repeat inside the trio is TS1028, which does not name the word.
fn accessCode(
    already: u32,
    after_static: Code,
    after_override: Code,
    after_accessor: Code,
    after_readonly: Code,
    after_async: Code,
    after_abstract: ?Code,
) ?Code {
    if (already & access != 0) return .accessibility_modifier_already_seen;
    if (already & F.override != 0) return after_override;
    if (already & F.static != 0) return after_static;
    if (already & F.accessor != 0) return after_accessor;
    if (already & F.readonly != 0) return after_readonly;
    if (already & F.async != 0) return after_async;
    // tsc reaches TS1044 (module element) here, then the abstract pair, then
    // TS18010 (an accessibility modifier with a private identifier).
    if (already & F.abstract != 0) return after_abstract;
    return null;
}

const std = @import("std");

test "a repeat names the modifier, except in the accessibility trio" {
    try std.testing.expectEqual(@as(?Code, .mod_seen_readonly), check(F.readonly, F.readonly, .property, false));
    try std.testing.expectEqual(@as(?Code, .mod_seen_accessor), check(F.accessor, F.accessor, .property, false));
    try std.testing.expectEqual(@as(?Code, .accessibility_modifier_already_seen), check(F.public, F.private, .property, false));
    // Not a repeat but the pair right next to it in `static`'s chain, so that a
    // dropped `already & F.static` guard would show up here.
    try std.testing.expectEqual(@as(?Code, .mod_order_static_readonly), check(F.readonly, F.static, .property, false));
    // A repeat is checked before every pair, so it wins over one.
    try std.testing.expectEqual(@as(?Code, .mod_seen_static), check(F.readonly | F.static, F.static, .property, false));
    // And the legal orders answer nothing.
    try std.testing.expectEqual(@as(?Code, null), check(F.public | F.static, F.readonly, .property, false));
}

test "the walk stops at the first hit, in tsc's order" {
    // `accessor public static x`: `public` answers for `accessor` and the
    // `static` behind it is never mentioned.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_accessor), check(F.accessor, F.public, .property, false));
    // `override public m()`: `override` outranks `static` in the chain.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_override), check(F.override | F.static, F.public, .method, false));
    // `static public m()`.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_static), check(F.static, F.public, .method, false));
    // `async override m()` and `override static s()`.
    try std.testing.expectEqual(@as(?Code, .mod_order_override_async), check(F.async, F.override, .method, false));
    try std.testing.expectEqual(@as(?Code, .mod_order_static_override), check(F.override, F.static, .method, false));
}

test "the pair rules stop the walk before the order rule behind them" {
    // `abstract override static x` is the static/abstract PAIR, so the
    // `override` order arm one line below it must not fire.
    try std.testing.expectEqual(
        @as(?Code, .mod_pair_static_abstract),
        check(F.abstract | F.override, F.static, .property, true),
    );
    // `private abstract m()` is a pair too, and `public`/`protected` are not.
    try std.testing.expectEqual(@as(?Code, .mod_pair_private_abstract), check(F.abstract, F.private, .method, true));
    try std.testing.expectEqual(@as(?Code, .mod_order_public_abstract), check(F.abstract, F.public, .method, true));
}

test "the accessor pairs name themselves first, in both directions" {
    try std.testing.expectEqual(@as(?Code, .mod_pair_accessor_readonly), check(F.readonly, F.accessor, .property, false));
    try std.testing.expectEqual(@as(?Code, .mod_pair_readonly_accessor), check(F.accessor, F.readonly, .property, false));
    try std.testing.expectEqual(@as(?Code, .mod_pair_accessor_declare), check(F.declare, F.accessor, .property, false));
    try std.testing.expectEqual(@as(?Code, .mod_pair_declare_accessor), check(F.accessor, F.declare, .property, false));
    // Each arm asks its pair BEFORE its own position rule, exactly as tsc
    // does, so `declare accessor m()` reaching the accessor arm is still the
    // pair — but it never does reach it, because `declare`'s TS1031 stops the
    // walk one modifier earlier.
    try std.testing.expectEqual(@as(?Code, .mod_pair_accessor_declare), check(F.declare, F.accessor, .method, false));
    try std.testing.expectEqual(@as(?Code, .declare_on_class_element), check(F.accessor, F.declare, .method, false));
    // `readonly accessor m()` is the shape that PROVES the position rules
    // cannot be left null: the `readonly` answers TS1024 and the accessor arm
    // behind it is never reached (measured — tsgo reports the TS1024 alone).
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .readonly_not_on_property, .token = 3 }),
        walk(&.{ .{ .bit = F.readonly, .token = 3 }, .{ .bit = F.accessor, .token = 4 } }, .method, false),
    );
    try std.testing.expectEqual(@as(?Code, null), check(0, F.readonly, .property, false));
}

test "TS1042 is a trailing check, so every pair rule outranks it" {
    // `async abstract p: number` — the `async` alone would be TS1042, but the
    // walk reaches the `abstract` first and the pair wins, blamed on the
    // `async` (tsc's `lastAsync`).
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .mod_pair_async_abstract, .token = 3 }),
        walk(&.{ .{ .bit = F.async, .token = 3 }, .{ .bit = F.abstract, .token = 4 } }, .property, true),
    );
    // The other order points at the same token.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .mod_pair_async_abstract, .token = 4 }),
        walk(&.{ .{ .bit = F.abstract, .token = 3 }, .{ .bit = F.async, .token = 4 } }, .property, true),
    );
    // With no `abstract` the trailing check speaks, and only for a member with
    // no body of its own.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .async_modifier_not_allowed_here, .token = 3 }),
        walk(&.{.{ .bit = F.async, .token = 3 }}, .property, false),
    );
    try std.testing.expectEqual(@as(?Finding, null), walk(&.{.{ .bit = F.async, .token = 3 }}, .method, false));
    // A constructor's own block answers instead and never falls through.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .ctor_mod_async, .token = 3 }),
        walk(&.{.{ .bit = F.async, .token = 3 }}, .constructor, false),
    );
}

test "the abstract pairs need an abstract class; the abstract repeat does not" {
    try std.testing.expectEqual(@as(?Code, .mod_order_abstract_override), check(F.override, F.abstract, .method, true));
    try std.testing.expectEqual(
        @as(?Code, .abstract_method_outside_abstract_class),
        check(F.override, F.abstract, .method, false),
    );
    try std.testing.expectEqual(@as(?Code, .mod_seen_abstract), check(F.abstract, F.abstract, .method, false));
}

test "abstract picks its wording off the member kind" {
    try std.testing.expectEqual(
        @as(?Code, .abstract_property_outside_abstract_class),
        check(0, F.abstract, .property, false),
    );
    try std.testing.expectEqual(
        @as(?Code, .abstract_method_outside_abstract_class),
        check(0, F.abstract, .accessor, false),
    );
    // A constructor is neither, whatever the class is.
    try std.testing.expectEqual(
        @as(?Code, .abstract_modifier_not_valid_here),
        check(0, F.abstract, .constructor, true),
    );
    // An index signature answered TS1071 already; a parameter, TS1090.
    try std.testing.expectEqual(@as(?Code, null), check(0, F.abstract, .other, false));
}

test "the constructor block runs only when the walk found nothing" {
    // `static constructor()` — the walk is clean, so the trailing block answers.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .ctor_mod_static, .token = 7 }),
        walk(&.{.{ .bit = F.static, .token = 7 }}, .constructor, false),
    );
    // `static async constructor()`: static outranks async in the block's order.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .ctor_mod_static, .token = 7 }),
        walk(&.{ .{ .bit = F.static, .token = 7 }, .{ .bit = F.async, .token = 8 } }, .constructor, false),
    );
    // `static abstract constructor()`: the `abstract` arm hits inside the walk,
    // so the block never runs.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .abstract_modifier_not_valid_here, .token = 8 }),
        walk(&.{ .{ .bit = F.static, .token = 7 }, .{ .bit = F.abstract, .token = 8 } }, .constructor, true),
    );
    // …and none of it applies to a method.
    try std.testing.expectEqual(
        @as(?Finding, null),
        walk(&.{.{ .bit = F.static, .token = 7 }}, .method, false),
    );
}

test "an earlier modifier's position rule outranks a later one's repeat" {
    // `abstract abstract m()` in a plain class is TS1244 on the FIRST word.
    try std.testing.expectEqual(
        @as(?Finding, .{ .code = .abstract_method_outside_abstract_class, .token = 3 }),
        walk(&.{ .{ .bit = F.abstract, .token = 3 }, .{ .bit = F.abstract, .token = 4 } }, .method, false),
    );
}
