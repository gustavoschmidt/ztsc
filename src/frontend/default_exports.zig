//! The `default` export slot: which of a file's `export default`s collide.
//!
//! TS2528 (`A module cannot have multiple default exports.`) is not "more than
//! one `export default`" — several forms legally share the slot:
//!
//!     export default function foo(a: number): number      // three declarations
//!     export default function foo(a: string): string      // of ONE overload set
//!     export default function foo(a: any): any { … }
//!
//!     export default function f() {}                      // legal beside
//!     export default interface I {}                       // an interface
//!
//! tsc gets that for free: every `export default` declares into the container's
//! `exports` table under the reserved name `default`, and `declareSymbol`'s
//! ordinary includes/excludes algebra decides whether the newcomer merges or
//! collides. Only the MESSAGE is special-cased — a collision on the `default`
//! name is worded TS2528 instead of TS2300, and reported on every declaration
//! the symbol had plus the newcomer.
//!
//! ztsc has no `exports` symbol table (a file's exports are a record list the
//! linker reads), so this module is that algebra, restricted to the five shapes
//! an `export default` can take. Two properties of tsc's `declareSymbol` are
//! load-bearing and easy to miss:
//!
//!   * a collision RESETS the symbol — tsc replaces the table entry with a
//!     fresh symbol holding only the offending declaration — so the flags a
//!     later declaration is tested against are the ones since the last
//!     collision, not since the top of the file. That is what makes
//!     `export default interface Bar {}` silent after an earlier collision has
//!     already fired;
//!   * a collision reports on the newcomer AND on every declaration in the
//!     current group, so three colliding declarations produce five reports at
//!     three distinct positions. tsc dedupes identical diagnostics; `clashing`
//!     answers the deduped SET directly.
//!
//! Pure: `Kind` in, one bool per declaration out. The binder maps its export
//! records onto it and owns the positions (tsc's `getNameOfDeclaration(decl) ||
//! decl` — the declaration's name if it has one, else the whole
//! `export default` statement).

const std = @import("std");

/// The meanings a `default` export slot can hold — tsc's `SymbolFlags`, cut
/// down to the bits an `export default` declaration can contribute or exclude.
/// `enum_`/`ns`/`type_alias` are never CONTRIBUTED by one (there is no
/// `export default enum`), but they appear in the exclude masks, so they are
/// part of the vocabulary.
const Flags = packed struct(u8) {
    function: bool = false,
    class_: bool = false,
    interface_: bool = false,
    type_alias: bool = false,
    enum_: bool = false,
    /// tsc's `ValueModule`.
    ns: bool = false,
    property: bool = false,
    alias: bool = false,

    fn bits(f: Flags) u8 {
        return @bitCast(f);
    }
};

const all_flags: u8 = std.math.maxInt(u8);

/// What shape a single `export default` is.
pub const Kind = enum {
    /// `export default function f() {}` — tsc's `Function`, and the only kind
    /// that MERGES with itself (an overload set).
    function,
    /// `export default class C {}`.
    class_,
    /// `export default interface I {}` — the one type-only form.
    interface_,
    /// `export default <entity name>` (`export default Foo`). tsc's
    /// `bindExportAssignment` calls this an `Alias`: it re-exports every
    /// meaning the named entity has.
    alias,
    /// `export default <any other expression>` — tsc's `Property`.
    property,

    /// The meaning this declaration contributes to the slot.
    fn includes(k: Kind) Flags {
        return switch (k) {
            .function => .{ .function = true },
            .class_ => .{ .class_ = true },
            .interface_ => .{ .interface_ = true },
            .alias => .{ .alias = true },
            .property => .{ .property = true },
        };
    }

    /// The meanings this declaration REFUSES to share the slot with — tsc's
    /// `*Excludes` masks:
    ///
    ///   * `FunctionExcludes = Value & ~(Function | ValueModule | Class)`;
    ///   * `ClassExcludes = (Value | Type) & ~(ValueModule | Interface |
    ///     Function)` — a class MERGES with an interface and with a function
    ///     overload set, and tsc judges both merges in the checker instead
    ///     (TS2813/TS2814 for the function one, which is why
    ///     `export default function bar() {} export default class C {}` earns
    ///     those and not TS2528);
    ///   * `InterfaceExcludes = Type & ~(Interface | Class)`;
    ///   * both export-assignment forms use `SymbolFlags.All` — "if there is an
    ///     `export default x;` alias declaration, you can't `export default`
    ///     anything else", which is tsc's own comment on that line.
    fn excludes(k: Kind) u8 {
        return switch (k) {
            .function => Flags{ .enum_ = true, .property = true },
            .class_ => Flags{
                .class_ = true,
                .enum_ = true,
                .property = true,
                .type_alias = true,
            },
            .interface_ => Flags{ .enum_ = true, .type_alias = true },
            .alias, .property => return all_flags,
        }.bits();
    }
};

/// Which declarations of one file's `default` slot tsc reports TS2528 on, in
/// declaration order. `out.len` must equal `kinds.len`; every entry is written.
pub fn clashing(kinds: []const Kind, out: []bool) void {
    std.debug.assert(out.len == kinds.len);
    @memset(out, false);
    // The current merge group: the declarations since the last collision, and
    // their accumulated meaning. A collision reports the whole group.
    var group_start: usize = 0;
    var acc: u8 = 0;
    for (kinds, 0..) |k, i| {
        if (i > group_start and acc & k.excludes() != 0) {
            for (out[group_start .. i + 1]) |*o| o.* = true;
            // tsc answers a collision with a FRESH symbol holding only this
            // declaration, so the group restarts here.
            group_start = i;
            acc = k.includes().bits();
            continue;
        }
        acc |= k.includes().bits();
    }
}

// ===========================================================================
// tests: the corpus shapes, each named for the case it comes from
// ===========================================================================

const testing = std.testing;

fn expectClashing(kinds: []const Kind, expected: []const bool) !void {
    var out: [8]bool = undefined;
    clashing(kinds, out[0..kinds.len]);
    try testing.expectEqualSlices(bool, expected, out[0..kinds.len]);
}

test "one default export never clashes" {
    try expectClashing(&.{.function}, &.{false});
    try expectClashing(&.{.property}, &.{false});
}

test "function overloads share the slot (exportDefaultInterfaceClassAndFunctionOverloads)" {
    try expectClashing(&.{ .function, .function, .function }, &.{ false, false, false });
    // …until an export ASSIGNMENT lands on them, which excludes everything and
    // reports the whole group; the interface that follows meets a slot holding
    // only the alias, and `InterfaceExcludes` does not cover it.
    try expectClashing(
        &.{ .function, .function, .function, .alias, .interface_ },
        &.{ true, true, true, true, false },
    );
}

test "two classes clash (multipleDefaultExports03)" {
    try expectClashing(&.{ .class_, .class_ }, &.{ true, true });
}

test "three classes clash pairwise, three positions (multipleDefaultExports05)" {
    try expectClashing(&.{ .class_, .class_, .class_ }, &.{ true, true, true });
}

test "an expression default excludes everything (multipleExportDefault1-6)" {
    try expectClashing(&.{ .function, .property }, &.{ true, true });
    try expectClashing(&.{ .property, .function }, &.{ true, true });
    try expectClashing(&.{ .property, .class_ }, &.{ true, true });
    try expectClashing(&.{ .class_, .property }, &.{ true, true });
    try expectClashing(&.{ .property, .property }, &.{ true, true });
}

test "function beside interface is legal" {
    try expectClashing(&.{ .function, .interface_ }, &.{ false, false });
    try expectClashing(&.{ .interface_, .function }, &.{ false, false });
}

test "a class MERGES with a function overload set (multipleExportDefault5)" {
    // tsc judges this merge in the checker (TS2813/TS2814 on the pair), so the
    // slot itself does not collide and there is no TS2528.
    try expectClashing(&.{ .function, .class_ }, &.{ false, false });
    try expectClashing(&.{ .class_, .function }, &.{ false, false });
    // …and a class still merges with an interface.
    try expectClashing(&.{ .interface_, .class_ }, &.{ false, false });
    try expectClashing(&.{ .class_, .interface_ }, &.{ false, false });
}
