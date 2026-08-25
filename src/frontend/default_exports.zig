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

/// What one `export default` declaration earns. The two diagnostics are
/// complements of each other — a collision is TS2528 and a MERGE of two or
/// more is TS2323 — so one walk answers both, and no declaration ever carries
/// them both.
pub const Verdict = struct {
    /// TS2528: this declaration is in a group a collision reported.
    multiple: bool = false,
    /// TS2323: this declaration shares a MERGED slot with another.
    redeclared: bool = false,
};

/// What each declaration of one file's `default` slot earns, in declaration
/// order. `out.len` must equal `kinds.len`; every entry is written.
///
/// `overload[i]` marks a declaration tsc's `isNotOverload` filters out of the
/// TS2323 count — a function SIGNATURE, which is one more declaration of the
/// same binding rather than a second binding. It has no bearing on TS2528.
pub fn check(kinds: []const Kind, overload: []const bool, out: []Verdict) void {
    std.debug.assert(out.len == kinds.len and overload.len == kinds.len);
    @memset(out, .{});
    // The current merge group: the declarations since the last collision, and
    // their accumulated meaning. A collision reports the whole group.
    var group_start: usize = 0;
    var acc: u8 = 0;
    for (kinds, 0..) |k, i| {
        if (i > group_start and acc & k.excludes() != 0) {
            for (out[group_start .. i + 1]) |*o| o.multiple = true;
            // The group that just ENDED is the symbol tsc is about to replace,
            // and its declarations are the ones TS2323 asks about.
            markRedeclared(overload[group_start..i], acc, out[group_start..i]);
            // tsc answers a collision with a FRESH symbol holding only this
            // declaration, so the group restarts here.
            group_start = i;
            acc = k.includes().bits();
            continue;
        }
        acc |= k.includes().bits();
    }
    markRedeclared(overload[group_start..], acc, out[group_start..]);
}

/// TS2323 for ONE merge group: the `default` binding it leaves behind was
/// declared more than once, and a module's export list is a set of bindings.
/// tsc's `checkExternalModuleExports` — "It is a Syntax Error if the
/// ExportedNames of ModuleItemList contains any duplicate entries", with the
/// TypeScript exceptions it names in the same comment: a namespace, an
/// interface or an enum MERGES into one binding by design and returns early,
/// and a function SIGNATURE is not a second declaration of anything.
///
/// Measured: `export default foo` beside `export default class Foo {}` is
/// TS2323 on both (they merge — `ClassExcludes` does not contain `Alias`),
/// while `export default class A {}` twice is TS2528 and NOT TS2323, because
/// the collision leaves two symbols of one declaration each.
fn markRedeclared(overload: []const bool, meaning: u8, out: []Verdict) void {
    const merging = Flags{ .interface_ = true, .enum_ = true, .ns = true };
    if (meaning & merging.bits() != 0) return;
    var n: usize = 0;
    for (overload) |ov| {
        if (!ov) n += 1;
    }
    if (n < 2) return;
    for (out, overload) |*o, ov| {
        if (!ov) o.redeclared = true;
    }
}

// ===========================================================================
// tests: the corpus shapes, each named for the case it comes from
// ===========================================================================

const testing = std.testing;

/// The TS2528 half, with no overload signatures in the set.
fn expectClashing(kinds: []const Kind, expected: []const bool) !void {
    var out: [8]Verdict = undefined;
    var ovl: [8]bool = @splat(false);
    check(kinds, ovl[0..kinds.len], out[0..kinds.len]);
    var got: [8]bool = undefined;
    for (out[0..kinds.len], got[0..kinds.len]) |v, *g| g.* = v.multiple;
    try testing.expectEqualSlices(bool, expected, got[0..kinds.len]);
}

/// The TS2323 half. `overload` marks the body-less function signatures.
fn expectRedeclared(kinds: []const Kind, overload: []const bool, expected: []const bool) !void {
    var out: [8]Verdict = undefined;
    check(kinds, overload, out[0..kinds.len]);
    var got: [8]bool = undefined;
    for (out[0..kinds.len], got[0..kinds.len]) |v, *g| g.* = v.redeclared;
    try testing.expectEqualSlices(bool, expected, got[0..kinds.len]);
}

test "a MERGED slot with two bindings is TS2323 (exportDefaultClassAndValue)" {
    // `export default foo` then `export default class Foo {}`: no collision
    // (`ClassExcludes` does not contain `Alias`), so the two share one symbol.
    try expectRedeclared(&.{ .alias, .class_ }, &.{ false, false }, &.{ true, true });
    // A COLLISION leaves two symbols of one declaration each, so the same pair
    // in the other order is TS2528 and not this.
    try expectRedeclared(&.{ .class_, .alias }, &.{ false, false }, &.{ false, false });
    try expectRedeclared(&.{ .class_, .class_ }, &.{ false, false }, &.{ false, false });
    // exportDefaultTypeClassAndValue: the merged pair reports, the collision's
    // fresh symbol behind it does not.
    try expectRedeclared(
        &.{ .alias, .class_, .alias },
        &.{ false, false, false },
        &.{ true, true, false },
    );
}

test "an interface in the slot makes the merge legal" {
    try expectRedeclared(&.{ .function, .interface_ }, &.{ false, false }, &.{ false, false });
    try expectRedeclared(&.{ .class_, .interface_ }, &.{ false, false }, &.{ false, false });
}

test "an overload set is one binding" {
    try expectRedeclared(
        &.{ .function, .function, .function },
        &.{ true, true, false },
        &.{ false, false, false },
    );
    // …two IMPLEMENTATIONS are two bindings.
    try expectRedeclared(
        &.{ .function, .function },
        &.{ false, false },
        &.{ true, true },
    );
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
