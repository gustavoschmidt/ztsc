//! What a modifier keyword means in PARAMETER position.
//!
//! One pure function from a token tag to the modifier's standing there: either
//! it is a parameter-property modifier (legal, and carries an `ast.Flags` bit)
//! or it is rejected, with the diagnostic tsc answers for it. Rejected is not
//! the same as unparsed — tsc's `parseModifiers` CONSUMES the keyword either
//! way, so the parameter behind it still parses cleanly and a single grammar
//! error stands in for what would otherwise be a cascade of "',' expected".
//!
//! tsc reaches this question in `checkGrammarModifiers` only after the repeat
//! and order walk (`modifier_order.zig`) has passed, and answers per modifier:
//! the four that are simply not parameter modifiers get TS1090 naming the word,
//! while `abstract`, `accessor` and the variance pair each have their own "can
//! only appear on ..." sentence that never mentions parameters. Every arm below
//! was measured against tsgo 7.0.2 on
//! `class A { constructor(<mod> a: number) {} }`, one program per modifier —
//! sharing a program hides them all, because one syntactic error suppresses
//! every semantic diagnostic in the whole program.
//!
//! `const` is deliberately absent from `role`. tsc does not treat it as a
//! parameter modifier at all: `constructor(const a: number)` is TS1359
//! ("'const' is a reserved word that cannot be used here"), and the parameter's
//! name is then simply missing. It is still modifier-SPELLED, which is a
//! separate question with a separate answer — see `isModifierKind`.

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const scanner = @import("scanner.zig");

const Code = diagnostics.Code;
const Tag = scanner.Tag;
const F = ast.Flags;

/// A modifier keyword's standing in parameter position.
pub const Role = union(enum) {
    /// A parameter PROPERTY modifier (`constructor(readonly x: T)`): legal
    /// here, and contributes this `ast.Flags` bit.
    property: u32,
    /// Not a parameter modifier. Consume it anyway and answer this.
    rejected: Code,
};

/// Every bit `role` can hand back as a `.property` — "this parameter is a
/// parameter PROPERTY", tsc's `ModifierFlags.ParameterPropertyModifier`. The
/// rules that ask are about the parameter, not about which modifier spelled it
/// (TS1317, TS2369), so they want the whole set at once.
pub const property_mask: u32 = F.public | F.private | F.protected | F.readonly | F.override;

/// tsc's `isModifierKind` — "this token is spelled like a modifier", asked
/// WITHOUT regard to whether a parameter may carry it. `role` answers the
/// narrower question ("is it a modifier HERE, and what does it mean"); this one
/// is the syntactic class, and it is strictly wider: `const` and `default` are
/// modifier keywords elsewhere in the grammar (`const` type parameters, `export
/// default`) even though a parameter never accepts them.
///
/// The one caller is `parseNameOfParameter`'s recovery: when the binding name
/// came back MISSING, tsc consumes a modifier-spelled token anyway
/// (`getFullWidth(name) === 0 && !some(modifiers) && isModifierKind(token())`),
/// so `function f(default: number) {}` reads `: number` as the annotation and
/// answers ONE TS1359 — where a non-modifier reserved word (`null`, `void`,
/// `true`) stalls the list and earns a second TS1138 on the `:`. Measured
/// against tsgo 7.0.2, one function per keyword.
pub fn isModifierKind(tag: Tag) bool {
    return switch (tag) {
        .keyword_const, .keyword_default => true,
        else => role(tag) != null,
    };
}

/// `tag`'s standing in parameter position, or null when it is not a modifier
/// there at all — in which case it is the parameter's own NAME.
pub fn role(tag: Tag) ?Role {
    return switch (tag) {
        .keyword_public => .{ .property = F.public },
        .keyword_private => .{ .property = F.private },
        .keyword_protected => .{ .property = F.protected },
        .keyword_readonly => .{ .property = F.readonly },
        .keyword_override => .{ .property = F.override },

        .keyword_static => .{ .rejected = .param_mod_static },
        .keyword_export => .{ .rejected = .param_mod_export },
        .keyword_declare => .{ .rejected = .param_mod_declare },
        .keyword_async => .{ .rejected = .param_mod_async },

        // These three have their own sentence rather than TS1090's, so a
        // parameter is never mentioned in them.
        .keyword_abstract => .{ .rejected = .abstract_modifier_not_valid_here },
        .keyword_accessor => .{ .rejected = .accessor_modifier_not_valid_here },
        .keyword_in => .{ .rejected = .in_modifier_not_valid_here },
        .keyword_out => .{ .rejected = .out_modifier_not_valid_here },

        else => null,
    };
}

const std = @import("std");

test "the parameter-property modifiers are the legal ones" {
    for ([_]Tag{ .keyword_public, .keyword_private, .keyword_protected, .keyword_readonly, .keyword_override }) |t| {
        try std.testing.expect(role(t).? == .property);
        // …and every one of them is in the mask the parameter-property rules
        // read, so the two cannot drift apart.
        try std.testing.expect(property_mask & role(t).?.property != 0);
    }
}

test "the rejected modifiers carry tsc's own code, not one shared sentence" {
    try std.testing.expectEqual(@as(?Code, .param_mod_static), role(.keyword_static).?.rejected);
    try std.testing.expectEqual(@as(?Code, .param_mod_async), role(.keyword_async).?.rejected);
    // `abstract`/`accessor`/`in`/`out` answer their own "can only appear on"
    // sentence — TS1242/TS1275/TS1274, never TS1090.
    try std.testing.expectEqual(@as(u16, 1242), role(.keyword_abstract).?.rejected.tsCode());
    try std.testing.expectEqual(@as(u16, 1275), role(.keyword_accessor).?.rejected.tsCode());
    try std.testing.expectEqual(@as(u16, 1274), role(.keyword_in).?.rejected.tsCode());
    try std.testing.expectEqual(@as(u16, 1274), role(.keyword_out).?.rejected.tsCode());
    try std.testing.expectEqual(@as(u16, 1090), role(.keyword_static).?.rejected.tsCode());
}

test "isModifierKind is tsc's list: every `role` plus `const` and `default`" {
    // Widening: everything `role` names is modifier-spelled…
    for ([_]Tag{
        .keyword_public,   .keyword_private,  .keyword_protected, .keyword_readonly,
        .keyword_override, .keyword_static,   .keyword_export,    .keyword_declare,
        .keyword_async,    .keyword_abstract, .keyword_accessor,  .keyword_in,
        .keyword_out,
    }) |t| try std.testing.expect(isModifierKind(t));
    // …plus exactly the two `role` refuses.
    try std.testing.expect(isModifierKind(.keyword_const));
    try std.testing.expect(isModifierKind(.keyword_default));
    // Reserved words that are NOT modifiers keep stalling the parameter list.
    for ([_]Tag{ .keyword_null, .keyword_void, .keyword_true, .keyword_enum, .identifier }) |t|
        try std.testing.expect(!isModifierKind(t));
}

test "a non-modifier keyword is the parameter's own name" {
    // `const` is the measured one: tsc answers TS1359 from the scanner there.
    try std.testing.expectEqual(@as(?Role, null), role(.keyword_const));
    try std.testing.expectEqual(@as(?Role, null), role(.identifier));
}
