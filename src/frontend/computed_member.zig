//! Which TS116x diagnostic a computed member name `[expr]` earns when the
//! expression cannot possibly name a property.
//!
//! tsc asks two questions about a computed name. The one this module answers is
//! `checkGrammarForInvalidDynamicName`'s: is the name a *dynamic* one that
//! cannot be *late-bound*, and if so, which of the five wordings fits where it
//! sits. The other one — is the key's TYPE assignable to
//! `string | number | symbol` — is TS2464 and lives in
//! `src/checker/computed_key.zig`.
//!
//! The predicate is purely SYNTACTIC, which is the measured surprise here.
//! tsc's `isNonBindableDynamicName` is `isDynamicName && !isLateBindableName`,
//! and `isLateBindableName` asks a *type* question ("is the key's type a string
//! literal, a numeric literal or a `unique symbol`") on top of the syntactic
//! `isLateBindableAST`. tsgo 7.0.2 answers as though only the syntactic half
//! were there: `declare const s: string; class C { [s]: number = 1 }` is
//! non-late-bindable by tsc's rule yet tsgo reports nothing, and so does
//! `[s.length]` (type `number`). `[foo()]`, `[(s)]`, `["a" + "b"]`,
//! `[s ? "a" : "b"]`, `[s!]` and `[s as string]` — none of them an
//! entity-name expression — all report. Measured shape by shape against
//! tsgo 7.0.2, so what ztsc mirrors is:
//!
//!   * a string / numeric / no-substitution-template literal key, and a signed
//!     numeric literal (`[-1]`), is not a dynamic name at all — its name is the
//!     literal's own;
//!   * an entity-name expression (an identifier, or a dotted chain of them) is
//!     late-bindable in principle, so it is never a grammar error, whatever its
//!     type turns out to be;
//!   * everything else earns the code `grammarCode` picks.
//!
//! The five wordings are tsc's, and they come from exactly TWO call sites —
//! `checkGrammarProperty` for a property and `checkGrammarMethod` for a
//! method. An ACCESSOR is a `GetAccessorDeclaration`/`SetAccessorDeclaration`
//! and reaches neither, so a computed accessor name is silent EVERYWHERE, not
//! only in a class body: `type T = { get [foo()](): string }` and `interface I
//! { get [foo()](): string }` are both silent for tsgo, where ztsc answered
//! TS1170/TS1169 (`noMappedGetSet`). All of it measured (probes `t/k3.ts`–
//! `t/k5.ts`, and `get`/`set` in each of the three homes).

const Code = @import("diagnostics.zig").Code;

/// Where the member sits — tsc's three-way `isClassLike(node.parent)` /
/// `InterfaceDeclaration` / `TypeLiteral` split.
pub const Home = enum { class_body, interface_body, type_literal };

/// What the member is. tsc's `checkGrammarProperty` sees `.property`, its
/// `checkGrammarMethod` sees the two method shapes, and an `.accessor` is
/// judged by neither.
pub const MemberKind = enum {
    /// A field / property signature, including `static`, `abstract` and
    /// `accessor` ones.
    property,
    /// A method with a body.
    method_impl,
    /// A method with no body: an overload signature, an `abstract` method, or
    /// any method of a `declare class` / an ambient block.
    method_signature,
    /// `get x()` / `set x(v)`.
    accessor,
};

/// The diagnostic a non-late-bindable computed name earns, or null when it
/// earns none. `ambient` is tsc's `node.flags & NodeFlags.Ambient` — a
/// `declare class`, a `declare module` body, or a `.d.ts`.
///
/// Order matters and is tsc's: inside a class body a PROPERTY is judged by
/// `checkGrammarProperty` before `checkGrammarMethod` ever sees it, so
/// `declare class C { ["a" + "b"]: number }` is TS1166 (the class-property
/// wording) while its sibling `["a" + "c"](): number` is TS1165 (the ambient
/// one). An interface or a type literal has one wording for both shapes, and
/// keeps it inside a `declare namespace` too.
pub fn grammarCode(home: Home, kind: MemberKind, ambient: bool) ?Code {
    return switch (home) {
        .class_body => switch (kind) {
            .property => .computed_name_in_class_property,
            .accessor => null,
            // A method with a body is legal: the name is simply never bound.
            .method_impl => null,
            .method_signature => if (ambient)
                .computed_name_in_ambient_context
            else
                .computed_name_in_method_overload,
        },
        .interface_body => switch (kind) {
            .accessor => null,
            .property, .method_impl, .method_signature => .computed_name_in_interface,
        },
        .type_literal => switch (kind) {
            .accessor => null,
            .property, .method_impl, .method_signature => .computed_name_in_type_literal,
        },
    };
}

const std = @import("std");

test "a class method with a body is silent, its overload is not" {
    try std.testing.expectEqual(@as(?Code, null), grammarCode(.class_body, .method_impl, false));
    try std.testing.expectEqual(
        @as(?Code, .computed_name_in_method_overload),
        grammarCode(.class_body, .method_signature, false),
    );
    try std.testing.expectEqual(
        @as(?Code, .computed_name_in_ambient_context),
        grammarCode(.class_body, .method_signature, true),
    );
}

test "a class property keeps its own wording in an ambient context" {
    try std.testing.expectEqual(
        @as(?Code, .computed_name_in_class_property),
        grammarCode(.class_body, .property, true),
    );
}

test "an accessor is judged in no home at all" {
    for ([_]Home{ .class_body, .interface_body, .type_literal }) |home| {
        try std.testing.expectEqual(@as(?Code, null), grammarCode(home, .accessor, false));
        try std.testing.expectEqual(@as(?Code, null), grammarCode(home, .accessor, true));
    }
}
