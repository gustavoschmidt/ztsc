//! Where a definite-assignment assertion (`x!: T`) is allowed to stand.
//!
//! tsc asks the question twice with one answer — `checkGrammarVariableDeclaration`
//! for a declarator and `checkGrammarProperty` for a class field — and both
//! spell it as a single guard whose failure picks one of three wordings:
//!
//! ```ts
//! if (node.exclamationToken && (<wrong place> || !node.type || node.initializer
//!         || node.flags & NodeFlags.Ambient || isStatic(node) || hasAbstractModifier(node))) {
//!     const message = node.initializer      ? Declarations_with_initializers_cannot_also_…   // TS1263
//!         : !node.type                      ? Declarations_with_definite_assignment_…        // TS1264
//!         :                                   A_definite_assignment_assertion_is_not_…       // TS1255
//!     return grammarErrorOnNode(node.exclamationToken, message);
//! }
//! ```
//!
//! The `static`/`abstract` arms belong to the property side only — a declarator
//! is neither — so one `Site` covers both with those two defaulted off.
//!
//! Every arm was measured against tsgo 7.0.2 rather than read off the source
//! (`w48d/bang`): `static b!: string`, `declare c!: string`, `abstract r!:
//! number` and a field of a `declare class` are all TS1255; `d! = "x"` and `e!:
//! string = "y"` are TS1263; a bare `f!` is TS1264; a plain `a!: string` is
//! silent. `let w! = 1` and `let u!` answer the same two on the declarator side,
//! and `declare let z!: string` answers TS1255.
//!
//! The rule is syntactic — it never asks a type question — so it belongs in the
//! parser, next to the `!` it judges. It is a GRAMMAR check, though: it sits
//! behind `checkGrammarModifiers`, so a modifier diagnostic on the same member
//! swallows it (`public public static a!: string` answers TS1028 alone,
//! measured), and the call site is responsible for that gate.

const Code = @import("diagnostics.zig").Code;

/// Everything the guard asks about the declaration, and nothing else.
pub const Site = struct {
    /// Was a `!` written at all? Nothing below matters when it was not.
    bang: bool,
    /// A `: T` followed the name.
    type_annotation: bool,
    /// An `= …` followed.
    initializer: bool,
    /// tsc's `node.flags & NodeFlags.Ambient`: a `declare` modifier on this
    /// declaration or on anything containing it, a `declare namespace`/`global`
    /// body, or a `.d.ts` file.
    ambient: bool,
    /// Class field only: the `static` modifier.
    static_member: bool = false,
    /// Class field only: the `abstract` modifier.
    abstract_member: bool = false,
};

/// The diagnostic the `!` earns, reported on the `!` token itself, or null when
/// the assertion is legal where it stands.
pub fn check(s: Site) ?Code {
    if (!s.bang) return null;
    const misplaced = !s.type_annotation or s.initializer or s.ambient or
        s.static_member or s.abstract_member;
    if (!misplaced) return null;
    if (s.initializer) return .definite_assertion_with_initializer;
    if (!s.type_annotation) return .definite_assertion_needs_type;
    return .definite_assertion_not_permitted;
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;

test "a plain annotated assertion is legal, and no `!` is ever judged" {
    try expectEqual(@as(?Code, null), check(.{
        .bang = true,
        .type_annotation = true,
        .initializer = false,
        .ambient = false,
    }));
    // Every arm that would otherwise report stays silent without the `!`.
    try expectEqual(@as(?Code, null), check(.{
        .bang = false,
        .type_annotation = false,
        .initializer = true,
        .ambient = true,
        .static_member = true,
        .abstract_member = true,
    }));
}

test "an initializer wins over a missing annotation" {
    // `d! = "x"`: both arms of the ladder are live; tsc's `?:` takes the first.
    try expectEqual(@as(?Code, .definite_assertion_with_initializer), check(.{
        .bang = true,
        .type_annotation = false,
        .initializer = true,
        .ambient = false,
    }));
    try expectEqual(@as(?Code, .definite_assertion_with_initializer), check(.{
        .bang = true,
        .type_annotation = true,
        .initializer = true,
        .ambient = false,
    }));
}

test "a bare `f!` wants a type annotation" {
    try expectEqual(@as(?Code, .definite_assertion_needs_type), check(.{
        .bang = true,
        .type_annotation = false,
        .initializer = false,
        .ambient = false,
    }));
}

test "ambient, static and abstract are the three places an annotated `!` may not stand" {
    const base: Site = .{
        .bang = true,
        .type_annotation = true,
        .initializer = false,
        .ambient = false,
    };
    var ambient = base;
    ambient.ambient = true;
    try expectEqual(@as(?Code, .definite_assertion_not_permitted), check(ambient));

    var stat = base;
    stat.static_member = true;
    try expectEqual(@as(?Code, .definite_assertion_not_permitted), check(stat));

    var abst = base;
    abst.abstract_member = true;
    try expectEqual(@as(?Code, .definite_assertion_not_permitted), check(abst));
}
