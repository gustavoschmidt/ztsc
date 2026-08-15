//! "Where is the implementation?" — tsc's `reportImplementationExpectedError`
//! (TS2391 for a function or method, TS2390 for a constructor).
//!
//! An overload signature is a declaration with no body, and a set of them is
//! only legal when one declaration in the set DOES have a body:
//!
//!     function foo();            // TS2391: implementation is missing
//!     class C { constructor(); } // TS2390: constructor implementation is missing
//!
//! tsc decides this in `checkFunctionOrConstructorSymbol` over a symbol's whole
//! declaration list, and reports at its `lastSeenNonAmbientDeclaration` — the
//! LAST declaration that is neither ambient nor an interface member. One error
//! per name, at that declaration, whether or not an earlier declaration had a
//! body:
//!
//!     class d {
//!         private foo(n: number): string;
//!         private foo(ns: any) { return ns.toString(); }
//!         private foo(s: string): string;   // TS2391 lands HERE
//!     }
//!
//! This module is the per-declaration half of the rule: given the last such
//! declaration, does it expect an implementation? The walk that finds it is
//! binder.zig's `checkMissingImplementations`, which has the declaration list.
//!
//! The exclusions are all tsc's, each verified against tsgo 7.0.2:
//!
//!   * a body — nothing to report;
//!   * an AMBIENT context (`declare function f();`, a `declare class`/`declare
//!     namespace` body, any `.d.ts`): a signature with no implementation is the
//!     whole point of an ambient declaration;
//!   * `abstract`, and an OPTIONAL method (`m?(): void`): both legally bodyless;
//!   * an INTERFACE or type-literal member, whose signatures never have bodies —
//!     tsc's `inAmbientContextOrInterface`;
//!   * an ACCESSOR: tsc's declaration walk collects `MethodDeclaration`,
//!     `MethodSignature`, `Constructor` and `FunctionDeclaration` only, so
//!     `get x(): number;` with no body is not this diagnostic's business.

const std = @import("std");
const ast = @import("ast.zig");
const bind_result = @import("bind_result.zig");

const ScopeKind = bind_result.ScopeKind;

/// Which diagnostic a declaration with no implementation earns, if any.
pub const Expected = enum { none, function, constructor };

/// `flags` is the declaration's `FnProto.flags`; `is_ctor` says the declaration
/// is a class CONSTRUCTOR, which ztsc spells with the same node tag as a method
/// and tsc gives its own message and its own node KIND (which is why a
/// constructor followed by a method is TS2390 and not the "implementation name
/// must be…" TS2389 — the kinds differ).
pub fn expected(
    scope: ScopeKind,
    tag: ast.Tag,
    flags: u32,
    is_ctor: bool,
    has_body: bool,
) Expected {
    if (has_body) return .none;
    if (flags & (ast.Flags.declare | ast.Flags.abstract | ast.Flags.optional) != 0) return .none;
    if (flags & (ast.Flags.get | ast.Flags.set) != 0) return .none;
    switch (tag) {
        // A `function` statement: legal wherever statements are, and a
        // namespace body counts.
        .function_decl => switch (scope) {
            .file, .function, .block, .namespace, .catch_clause, .for_head => {},
            else => return .none,
        },
        // A class member. `class_statics` is the same declaration shape one
        // `static` further on; every other member table (an interface's, a type
        // literal's) holds signatures that are legally bodyless.
        .class_method => switch (scope) {
            .class_members, .class_statics => {},
            else => return .none,
        },
        else => return .none,
    }
    return if (is_ctor) .constructor else .function;
}

test "expected: the shapes that want an implementation" {
    const t = std.testing;
    // A bodyless function statement, and the same in a namespace body.
    try t.expectEqual(Expected.function, expected(.file, .function_decl, 0, false, false));
    try t.expectEqual(Expected.function, expected(.namespace, .function_decl, 0, false, false));
    try t.expectEqual(Expected.function, expected(.block, .function_decl, 0, false, false));
    // Class members, instance and static; a constructor gets its own code.
    try t.expectEqual(Expected.function, expected(.class_members, .class_method, 0, false, false));
    try t.expectEqual(Expected.function, expected(.class_statics, .class_method, 0, false, false));
    try t.expectEqual(Expected.constructor, expected(.class_members, .class_method, 0, true, false));
}

test "expected: the exclusions" {
    const t = std.testing;
    // A body.
    try t.expectEqual(Expected.none, expected(.file, .function_decl, 0, false, true));
    // `declare`, `abstract`, optional, and an accessor.
    try t.expectEqual(Expected.none, expected(.file, .function_decl, ast.Flags.declare, false, false));
    try t.expectEqual(Expected.none, expected(.class_members, .class_method, ast.Flags.abstract, false, false));
    try t.expectEqual(Expected.none, expected(.class_members, .class_method, ast.Flags.optional, false, false));
    try t.expectEqual(Expected.none, expected(.class_members, .class_method, ast.Flags.get, false, false));
    try t.expectEqual(Expected.none, expected(.class_members, .class_method, ast.Flags.set, false, false));
    // An interface / type-literal member, and any other node kind.
    try t.expectEqual(Expected.none, expected(.interface_members, .class_method, 0, false, false));
    try t.expectEqual(Expected.none, expected(.interface_members, .method_signature, 0, false, false));
    try t.expectEqual(Expected.none, expected(.file, .class_field, 0, false, false));
}
