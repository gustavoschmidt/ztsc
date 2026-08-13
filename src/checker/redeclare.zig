//! "Subsequent declarations must have the same type" — tsc's
//! `errorNextVariableOrPropertyDeclarationMustHaveSameType`.
//!
//! One name can be declared more than once (`var` merges with `var`, with a
//! parameter, and across files at global scope). The symbol's TYPE, though,
//! comes from its FIRST value declaration alone, so every later one is
//! checked against it and reported when the two are not IDENTICAL:
//!
//!     var a: any;      // the value declaration — `a` is `any`
//!     var a = 1;       // TS2403: must be of type 'any', but here has 'number'
//!
//! Identity, not assignability: `any` and `number` are mutually assignable
//! and still an error, which is the whole point of the check.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's `isTypeIdenticalTo`, as much of it as this check needs.
///
/// ztsc's type store is hash-consed: a union is sorted and deduped before
/// interning, an object's properties are sorted by name atom, and a signature
/// carries its whole payload in the key. Two structurally identical types
/// built through the store are therefore the SAME `TypeId`, and identity is
/// integer equality — which is why this needs no relation walk of its own
/// (and stays out of the assignability engine, whose answers are a different
/// question).
///
/// The one gap the equality misses is a NAMED type standing in front of a
/// structure: `interface I { x: number }` is a `.ref`, and `{ x: number }`
/// written out is an object. tsc's identity relation expands both, so one
/// `resolveStructural` on each side closes the common case. Members are NOT
/// compared recursively: two *distinct* interfaces with identical members
/// are identical to tsc and merely unequal here, so the check stays silent.
/// That direction is deliberate — a missed TS2403 is an under-report, an
/// invented one is a false error on legal code.
pub fn typesIdentical(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (a == b) return true;
    const ea = c.resolveStructural(a) catch return false;
    const eb = c.resolveStructural(b) catch return false;
    return ea == eb;
}

/// The name identifier of a variable declarator, or null when it binds a
/// pattern (tsc checks each binding element of a pattern separately; ztsc
/// does not reach those yet — a documented under-report).
fn declaratorName(c: *Checker, decl: Node) ?Node {
    const d = c.tree.nodeData(decl);
    const name = switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full => d.lhs,
        else => return null,
    };
    if (name == null_node or c.nodeTag(name) != .identifier) return null;
    return name;
}

/// Is `decl` the FIRST value declaration of `sym` — tsc's
/// `symbol.valueDeclaration`? A symbol whose representative lives in an
/// EARLIER file cannot have its first declaration here, so the file check
/// answers that case without touching another file's node ids.
fn isValueDeclaration(c: *Checker, sym: SymbolId, decl: Node) bool {
    if (c.symFile(sym) != c.cur_file) return false;
    for (c.declsOf(sym)) |dn| {
        switch (c.nodeTag(dn)) {
            .declarator, .declarator_init, .declarator_full => return dn == decl,
            else => {},
        }
    }
    return false;
}

/// TS2403 for one variable declarator. Silent when this declarator IS the
/// symbol's value declaration, when either type is an error (the divergence
/// was already reported), or when the two are identical.
pub fn checkSubsequentVarDecl(c: *Checker, decl: Node, is_const: bool) Error!void {
    const name = declaratorName(c, decl) orelse return;
    const tok = c.tree.nodeMainToken(name);
    const a = try c.atomOfToken(tok);
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return,
    };
    const f = c.symFlags(sym);
    if (!(f.var_decl or f.let_decl or f.const_decl)) return;
    if (isValueDeclaration(c, sym, decl)) return;
    const sym_ty = try c.typeOfSymbol(sym);
    const decl_ty = try c.declaratorType(sym, decl, is_const);
    if (sym_ty == types.error_type or decl_ty == types.error_type) return;
    if (try typesIdentical(c, sym_ty, decl_ty)) return;
    try c.diagFmt(
        2403,
        c.tokSpan(tok),
        "Subsequent variable declarations must have the same type.  Variable '{s}' must be of type '{s}', but here has type '{s}'.",
        .{ c.tokenText(tok), try c.typeToString(sym_ty), try c.typeToString(decl_ty) },
    );
}
