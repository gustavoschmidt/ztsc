//! Which modifier may follow which, on a class member or a parameter property.
//!
//! One pure function over (modifiers already seen, the modifier now being read)
//! → the diagnostic for it, or null when the pair is legal (or is a rule ztsc
//! does not answer yet). It is tsc's `checkGrammarModifiers` walk, transcribed
//! per modifier and in tsc's own order — that order is load-bearing, because
//! tsc returns on its FIRST hit, so `accessor public static x` answers for
//! `public` alone and never mentions `static`.
//!
//! Only the ORDER and REPEAT rules live here. The rules that need to see more
//! than the modifier run — "readonly can only appear on a property", "abstract
//! methods can only appear within an abstract class", the module-element and
//! parameter positions — belong to whoever knows that context, and each is
//! marked below where tsc's walk would have reached it. Where ztsc has no
//! answer for a rule, this returns null and the pair is silently accepted: an
//! under-report never manufactures a wrong key, while guessing the NEXT arm's
//! code in tsc's chain would.

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const Code = diagnostics.Code;
const F = ast.Flags;

const access = F.public | F.private | F.protected;

/// The diagnostic for adding `bit` to a member that already carries `already`,
/// or null when the combination is legal or unanswered. `bit` is a single
/// `ast.Flags` modifier bit (`classMemberModifierBit`'s result).
///
/// `in_abstract_class` gates the two `abstract` PAIRS only: tsc reaches them
/// after TS1244 ("abstract methods can only appear within an abstract class"),
/// so on a member of a plain class TS1244 is the answer and these must stay
/// silent. A repeat of `abstract` is checked before TS1244 and so needs no gate.
pub fn check(already: u32, bit: u32, in_abstract_class: bool) ?Code {
    return switch (bit) {
        F.public => accessCode(already, .mod_order_public_static, .mod_order_public_override, .mod_order_public_accessor, .mod_order_public_readonly, .mod_order_public_async, .mod_order_public_abstract),
        F.protected => accessCode(already, .mod_order_protected_static, .mod_order_protected_override, .mod_order_protected_accessor, .mod_order_protected_readonly, .mod_order_protected_async, .mod_order_protected_abstract),
        // `private abstract` is TS1243 ("cannot be used with"), not TS1029, so
        // `private` passes null for the abstract arm rather than an order code.
        F.private => accessCode(already, .mod_order_private_static, .mod_order_private_override, .mod_order_private_accessor, .mod_order_private_readonly, .mod_order_private_async, null),

        F.static => blk: {
            if (already & F.static != 0) break :blk .mod_seen_static;
            if (already & F.readonly != 0) break :blk .mod_order_static_readonly;
            if (already & F.async != 0) break :blk .mod_order_static_async;
            if (already & F.accessor != 0) break :blk .mod_order_static_accessor;
            // tsc reaches TS1044 (module element) and TS1090 (parameter) here;
            // both are positions ztsc answers elsewhere. Then `static abstract`
            // is TS1243, which stops the walk — so an `abstract` already seen
            // must NOT fall through to the `override` arm below.
            if (already & F.abstract != 0) break :blk null;
            if (already & F.override != 0) break :blk .mod_order_static_override;
            break :blk null;
        },

        F.override => blk: {
            if (already & F.override != 0) break :blk .mod_seen_override;
            // `declare override` is TS1243; it stops the walk.
            if (already & F.declare != 0) break :blk null;
            if (already & F.readonly != 0) break :blk .mod_order_override_readonly;
            if (already & F.accessor != 0) break :blk .mod_order_override_accessor;
            if (already & F.async != 0) break :blk .mod_order_override_async;
            break :blk null;
        },

        F.abstract => blk: {
            if (already & F.abstract != 0) break :blk .mod_seen_abstract;
            // tsc's remaining `abstract` arms sit inside a guard that excludes a
            // class DECLARATION, and reach TS1242/TS1244 (only on a class
            // method or property; only within an abstract class) before these.
            // A member of a non-abstract class therefore answers TS1244 in tsc
            // and nothing here — the caller passes `in_abstract_class` so this
            // stays an under-report instead of a wrong key.
            if (!in_abstract_class) break :blk null; // TS1244
            if (already & (F.static | F.private) != 0) break :blk null; // TS1243
            if (already & F.async != 0) break :blk null; // TS1243, and on the `async`
            if (already & F.override != 0) break :blk .mod_order_abstract_override;
            if (already & F.accessor != 0) break :blk .mod_order_abstract_accessor;
            break :blk null;
        },

        F.accessor => blk: {
            if (already & F.accessor != 0) break :blk .mod_seen_accessor;
            // `readonly accessor` / `declare accessor` are TS1243; then TS1275
            // ("can only appear on a property declaration") ends the chain.
            break :blk null;
        },

        F.readonly => if (already & F.readonly != 0) .mod_seen_readonly else null,
        F.async => if (already & F.async != 0) .mod_seen_async else null,
        F.declare => if (already & F.declare != 0) .mod_seen_declare else null,

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
    try std.testing.expectEqual(@as(?Code, .mod_seen_readonly), check(F.readonly, F.readonly, false));
    try std.testing.expectEqual(@as(?Code, .mod_seen_accessor), check(F.accessor, F.accessor, false));
    try std.testing.expectEqual(@as(?Code, .accessibility_modifier_already_seen), check(F.public, F.private, false));
    // Not a repeat but the pair right next to it in `static`'s chain, so that a
    // dropped `already & F.static` guard would show up here.
    try std.testing.expectEqual(@as(?Code, .mod_order_static_readonly), check(F.readonly, F.static, false));
    // A repeat is checked before every pair, so it wins over one.
    try std.testing.expectEqual(@as(?Code, .mod_seen_static), check(F.readonly | F.static, F.static, false));
    // And the legal orders answer nothing.
    try std.testing.expectEqual(@as(?Code, null), check(F.public | F.static, F.readonly, false));
}

test "the walk stops at the first hit, in tsc's order" {
    // `accessor public static x`: `public` answers for `accessor` and the
    // `static` behind it is never mentioned.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_accessor), check(F.accessor, F.public, false));
    // `override public m()`: `override` outranks `static` in the chain.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_override), check(F.override | F.static, F.public, false));
    // `static public m()`.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_static), check(F.static, F.public, false));
    // `async override m()` and `override static s()`.
    try std.testing.expectEqual(@as(?Code, .mod_order_override_async), check(F.async, F.override, false));
    try std.testing.expectEqual(@as(?Code, .mod_order_static_override), check(F.override, F.static, false));
}

test "an unanswered rule yields null rather than the next arm's code" {
    // `abstract static x` is TS1243, so the `override` arm must not fire.
    try std.testing.expectEqual(@as(?Code, null), check(F.abstract | F.override, F.static, true));
    // `private abstract m()` is TS1243 too.
    try std.testing.expectEqual(@as(?Code, null), check(F.abstract, F.private, true));
    // ...while `public abstract` and `protected abstract` are order errors.
    try std.testing.expectEqual(@as(?Code, .mod_order_public_abstract), check(F.abstract, F.public, true));
}

test "the abstract pairs need an abstract class; the abstract repeat does not" {
    try std.testing.expectEqual(@as(?Code, .mod_order_abstract_override), check(F.override, F.abstract, true));
    try std.testing.expectEqual(@as(?Code, null), check(F.override, F.abstract, false));
    try std.testing.expectEqual(@as(?Code, .mod_seen_abstract), check(F.abstract, F.abstract, false));
}
