//! Declaration SPACES — tsc's `getDeclarationSpaces` and the export/local
//! agreement rule built on it (`checkExportsOnMergedDeclarations`, TS2395).
//!
//! One name can be declared more than once and still be legal: `interface I`
//! twice, `var v` twice, `class C` beside `namespace C`. tsc additionally
//! requires every declaration of such a merged name to agree on VISIBILITY —
//! either all of them carry `export` or none of them does:
//!
//!     namespace N {
//!         interface I { }
//!         export interface I { }   // TS2395, on both names
//!     }
//!
//! The rule is not "any two declarations", it is "two declarations claiming a
//! common declaration space": the three spaces a declaration can occupy are
//! VALUE, TYPE and NAMESPACE, and `type t = 0; namespace t {…}; export const t
//! = 0` is legal precisely because no space is claimed twice with disagreeing
//! visibility.
//!
//! Why tsc has the check at all is worth recording, because it explains the
//! neighbouring diagnostics ztsc must NOT report: tsc's binder gives a
//! container two symbol tables, `exports` and `locals`, and declares an
//! exported member in `exports` with its full meaning while leaving a
//! *meaningless* placeholder (`ExportValue`, or nothing at all for a type) in
//! `locals`. An `export`ed declaration therefore never displaces a later local
//! one of the same name — no TS2300/TS2451 — and this check stands in for the
//! duplicate diagnostic that the split suppressed. `binder.zig`'s `priorFlags`
//! is the other half of that story.

const std = @import("std");
const ast = @import("ast.zig");

/// The three spaces of tsc's `DeclarationSpaces`. A declaration claims one or
/// more; two declarations conflict when they claim one in common.
pub const Spaces = packed struct(u8) {
    value: bool = false,
    type_: bool = false,
    namespace: bool = false,
    _pad: u5 = 0,

    pub fn bits(s: Spaces) u8 {
        return @bitCast(s);
    }
    pub fn merge(a: Spaces, b: Spaces) Spaces {
        return @bitCast(a.bits() | b.bits());
    }
    pub fn intersect(a: Spaces, b: Spaces) Spaces {
        return @bitCast(a.bits() & b.bits());
    }
    pub fn any(s: Spaces) bool {
        return s.bits() != 0;
    }
};

/// The spaces a declaration of this NODE KIND claims, or null when the kind is
/// one this check does not model — which switches the whole symbol off rather
/// than guessing. The nulls are deliberate:
///
///   * ALIASES (`import x = …`, an import/export specifier, `export =`) claim
///     the spaces of their *target*, which takes alias resolution — a checker
///     job, and the binder is where this check runs.
///   * class and type members never carry an `export` modifier, so they can
///     never be a mixed merge in the first place.
///
/// A `namespace` block claims NAMESPACE, and also VALUE when it is
/// INSTANTIATED — a property of the block's body rather than of its kind, so
/// the caller ORs that in (binder.zig's `instantiated`).
pub fn ofTag(tag: ast.Tag) ?Spaces {
    return switch (tag) {
        .interface_decl, .type_alias => .{ .type_ = true },
        .class_decl, .enum_decl, .enum_member => .{ .type_ = true, .value = true },
        .namespace_decl => .{ .namespace = true },
        // Every VALUE-only declaration shape: a `var`/`let`/`const`
        // declarator (with or without type annotation or initializer), a
        // function, and a parameter.
        .declarator, .declarator_init, .declarator_full => .{ .value = true },
        .function_decl, .param, .param_full => .{ .value = true },
        else => null,
    };
}

/// The spaces claimed BOTH by an `export`ed declaration of a name and by a
/// local one — tsc's `commonDeclarationSpacesForExportsAndLocals`. Empty when
/// the group of declarations is legal.
pub fn conflict(exported: Spaces, local: Spaces) Spaces {
    return exported.intersect(local);
}

test "spaces of the kinds a mixed merge can reach" {
    try std.testing.expect(ofTag(.interface_decl).?.type_);
    try std.testing.expect(!ofTag(.interface_decl).?.value);
    try std.testing.expect(ofTag(.class_decl).?.value and ofTag(.class_decl).?.type_);
    try std.testing.expect(ofTag(.namespace_decl).?.namespace);
    try std.testing.expect(!ofTag(.namespace_decl).?.value);
    try std.testing.expect(ofTag(.import_equals) == null);
    try std.testing.expect(ofTag(.class_field) == null);
}

test "a conflict needs a space claimed on both sides" {
    const ty: Spaces = .{ .type_ = true };
    const val: Spaces = .{ .value = true };
    try std.testing.expect(!conflict(ty, val).any());
    try std.testing.expect(conflict(ty, ty.merge(val)).any());
    // `type t = 0; namespace t {}` local beside `export const t = 0`: the
    // exported side claims VALUE, the local side TYPE and NAMESPACE.
    try std.testing.expect(!conflict(val, ty.merge(.{ .namespace = true })).any());
}
