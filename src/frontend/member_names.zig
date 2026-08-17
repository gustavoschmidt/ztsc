//! Reserved class-member keys, and the one predicate that decides a class
//! member IS the constructor.
//!
//! A class member table is keyed by the member's name atom, and two members
//! that key the same are a duplicate identifier. That makes the constructor a
//! problem: `constructor` is also a legal parameter name, so
//!
//!     class C { constructor(public constructor: string) {} }
//!
//! declares a parameter PROPERTY whose name is the same text the constructor
//! itself would be keyed under — and the pair reads as a redeclaration that
//! tsc never reports. tsc avoids it by keying a `ConstructorDeclaration` under
//! the reserved `InternalSymbolName.Constructor` (`"__constructor"`) instead of
//! its source text; ztsc uses the `__@` prefix its other synthetic member keys
//! already use (`__@iterator`, `__@k$…`), which cannot appear in an identifier,
//! so the reserved key is unreachable by name from source.
//!
//! Because the key is no longer the member's text, "is this the constructor?"
//! has exactly two spellings and they must agree:
//!
//!   * from a member TABLE (an atom) — compare against `ctor_member_name`
//!     (the checker's `isCtorName`);
//!   * from a member DECLARATION (a node) — `isCtorMethod` below.
//!
//! The declaration-side gate lives here so the binder that assigns the key and
//! every checker site that skips the constructor cannot drift apart.

const std = @import("std");
const ast = @import("ast.zig");

const Ast = ast.Ast;
const Node = ast.Node;

/// The reserved member-table key of a class constructor — tsc's
/// `InternalSymbolName.Constructor`, in ztsc's synthetic-key spelling.
pub const ctor_member_name = "__@ctor";

/// tsc's `ModifierFlags.ParameterPropertyModifier`: the modifiers whose
/// presence on a constructor parameter makes it declare a class MEMBER.
///
/// Lives beside `isCtorMethod` because it answers the same kind of question —
/// which syntax declares which class member — and because its two readers sit
/// in different phases: the binder declares the member (and rejects the
/// modifier outside a constructor implementation, TS2369), while the checker's
/// index-constraint walk has to count the parameter as an own declaration of
/// the class (TS2411).
pub const param_property_mask: u32 = ast.Flags.public | ast.Flags.private |
    ast.Flags.protected | ast.Flags.readonly | ast.Flags.override;

/// True when a `.class_method` member is the class's CONSTRUCTOR: the name
/// token is the `constructor` keyword and the member is neither `static` nor an
/// accessor. A `static constructor()` is an ordinary static member of that name
/// and `get constructor()` is an accessor (TS1341), so neither owns the
/// constructor slot — exactly the shape tsc's `SyntaxKind.Constructor` covers.
pub fn isCtorMethod(tree: *const Ast, member: Node, flags: u32) bool {
    if (flags & (ast.Flags.static | ast.Flags.get | ast.Flags.set) != 0) return false;
    return tree.tokens.tag(tree.nodeMainToken(member)) == .keyword_constructor;
}
