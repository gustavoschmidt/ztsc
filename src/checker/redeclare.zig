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
//! tsc compares the two with its IDENTITY relation, not with assignability:
//! `any` and `number` are mutually assignable and still an error. ztsc has no
//! identity relation, so `typesIdentical` approximates one — see there for
//! exactly which way it errs.

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

/// A CONSERVATIVE stand-in for tsc's `isTypeIdenticalTo`, deliberately biased
/// toward answering "identical".
///
/// A real identity relation is a structural walk of its own, and ztsc has
/// none: the assignability engine answers a different question and belongs to
/// nobody here to extend. So this decides identity from what is available.
/// EVERY step below can only *widen* the set of pairs called identical — a
/// missed TS2403 is an under-report, an invented one is a false error on
/// legal code, and the check is only worth having in the first place if it
/// never does the latter.
///
///   1. `TypeId` equality. The store is hash-consed (unions sorted and
///      deduped, object properties sorted by name atom, a signature's whole
///      payload in the key), so structurally identical types built through it
///      are already the same id. `A | B` and `B | A` land here.
///   2. The refusals: inputs ztsc reached by giving up rather than by reading
///      the program (`identityUndecidable`), and a literal beside its own
///      base, which is ztsc's widening diverging rather than the two
///      declarations.
///   3. `resolveStructural` on each side, which puts a named type
///      (`interface Point`, a `.ref`) and the structure it stands for on the
///      same footing.
///   4. MUTUAL assignability. This is the loose step and the load-bearing
///      one: `interface Point` versus a widened `{ x: number, y: number }`
///      object literal, and `{ (s: string): number }` versus `(s: string) =>
///      number`, are identical to tsc but differ in ztsc's object flags and
///      in kind respectively. Everything tsc separates and mutual
///      assignability does not — two spread unions, two signatures differing
///      only under `any` — is simply not reported.
///
/// `any`/`unknown` is the one place mutual assignability errs in the
/// REPORTING direction rather than the silent one — it relates to everything
/// both ways, while tsc's identity relation matches it only with itself — so
/// the caller settles that case before asking (see `checkSubsequentVarDecl`).
pub fn typesIdentical(c: *Checker, a: TypeId, b: TypeId) Error!bool {
    if (a == b) return true;
    if (identityUndecidable(c, a) or identityUndecidable(c, b)) return true;
    // A literal and its own base primitive. tsc widens an initializer before
    // it compares (`getWidenedTypeForVariableLikeDeclaration`), so a pair
    // that differs only by that widening is ztsc's widening diverging, not
    // the program's two declarations: `var r = foo(1, 2); var r = foo({}, 1);`
    // is `number` twice to tsc and `2` then `number` here.
    if (c.ts.literalBase(a) == b or c.ts.literalBase(b) == a) return true;
    const ea = c.resolveStructural(a) catch return true;
    const eb = c.resolveStructural(b) catch return true;
    if (ea == eb) return true;
    // Two WEAK types (every property optional) are unrelated by assignability
    // in both directions — that is tsc's weak-type screen (TS2559), a
    // heuristic on top of the structural relation rather than a structural
    // fact, since neither side has a required member the other lacks. It
    // leaves this check with no identity evidence at all, so it answers
    // "identical" rather than reading the heuristic as a difference.
    if (allOptional(c, ea) and allOptional(c, eb)) return true;
    // An object with NOTHING in it — no property, no index signature, no
    // call or construct signature — is ztsc failing to materialize a shape
    // rather than a program that wrote `{}`. A `declare class Point` merged
    // with a `declare namespace Point` comes back empty here, and comparing
    // that against the `{ x: number; y: number }` it should have been is a
    // report about ztsc, not about the two declarations.
    if (isEmptyObject(c, ea) or isEmptyObject(c, eb)) return true;
    return (try c.isAssignable(ea, eb)) and (try c.isAssignable(eb, ea));
}

fn isEmptyObject(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) != .object) return false;
    return c.ts.objectPropCount(t) == 0 and
        c.ts.objectCallSigCount(t) == 0 and
        c.ts.objectConstructSigCount(t) == 0 and
        c.ts.objectStringIndex(t) == types.no_type and
        c.ts.objectNumberIndex(t) == types.no_type;
}

/// An object type with at least one property, all of them optional.
fn allOptional(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) != .object) return false;
    const n = c.ts.objectPropCount(t);
    if (n == 0) return false;
    for (0..n) |i| {
        if (c.ts.objectProp(t, @intCast(i)).flags & types.prop_flag_optional == 0) return false;
    }
    return true;
}

/// Types whose identity this module refuses to judge, because ztsc reaches
/// them by giving up rather than by reading the program:
///
///   * `unknown` is what a failed inference leaves behind (`xs.map(identity)`
///     is `number[]` to tsc and `unknown[]` here), `err` what a reported
///     error leaves, and `void` what an unresolved value declaration leaves.
///   * a `class_value` (`typeof C`, and a namespace object) is NOMINAL here,
///     so it is never mutually assignable with the structural type tsc
///     considers identical to it.
///
/// Answering "identical" for these is the same under-report the rest of the
/// approximation makes, and it is what keeps a divergence that belongs to
/// inference or to overload resolution from surfacing as a TS2403.
fn identityUndecidable(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .unknown, .void, .err, .class_value => true,
        .array => identityUndecidable(c, c.ts.arrayElem(t)),
        else => false,
    };
}

/// Is `t` the top type — the one thing mutual assignability cannot tell apart
/// from anything else?
fn isAnyLike(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .any, .unknown => true,
        else => false,
    };
}

/// Did the PROGRAM ask for this declaration's `any`, or did ztsc fall back to
/// it? tsc has one `any`; ztsc uses the same type as its "could not work this
/// out" answer, and an unresolved annotation (`var p: alias.Point` where the
/// import alias does not resolve) must not be read as "declared `any`" and
/// turned into a TS2403 against the next declaration.
///
/// True for the two forms tsc itself gives `any`: a bare `var x;` (its "auto"
/// type, which `convertAutoToAny` maps to `any`) and an explicit `any` /
/// `unknown` annotation. An INITIALIZER that happened to widen to `any` is
/// excluded — that is an under-report, and the safe direction.
fn topTypeIsDeclared(c: *Checker, decl: Node) bool {
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .declarator => return true,
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann == 0) return false;
            if (c.nodeTag(e.type_ann) != .identifier) return false;
            return switch (c.tree.tokens.tag(c.tree.nodeMainToken(e.type_ann))) {
                .keyword_any, .keyword_unknown => true,
                else => false,
            };
        },
        else => return false,
    }
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

/// The symbol's FIRST value declaration — tsc's `symbol.valueDeclaration` —
/// when it lives in the current file, else null (another file's node ids are
/// not addressable through `c.tree`).
///
/// A PARAMETER counts: `function f(x: A) { var x: B; }` merges the two into
/// one symbol whose value declaration is the parameter, and the `var` is the
/// subsequent one tsc reports. Type-space declarations that merged onto the
/// same symbol (lib's `interface Object` beside `declare var Object`) do not.
fn firstValueDecl(c: *Checker, sym: SymbolId) ?Node {
    if (c.symFile(sym) != c.cur_file) return null;
    for (c.declsOf(sym)) |dn| {
        switch (c.nodeTag(dn)) {
            .declarator, .declarator_init, .declarator_full, .param, .param_full => return dn,
            else => {},
        }
    }
    return null;
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
    // The value declaration has to be in THIS file. A cross-file reference
    // resolves to the MERGED symbol, which can fold declarations tsc keeps
    // apart — a namespace local that was never `export`ed merges into the
    // cross-file namespace member index here, so `namespace A { var Origin:
    // string }` in one file was compared against another file's `export var
    // Origin: Point`. This check cannot see which constituents are really
    // one symbol, so it declines the whole cross-file case (which loses the
    // genuine `var x = 3;` / `var x = true;` across two script files).
    const first = firstValueDecl(c, sym) orelse return;
    if (first == decl) return;
    const sym_ty = try c.typeOfSymbol(sym);
    const decl_ty = try c.declaratorType(sym, decl, is_const);
    if (sym_ty == types.error_type or decl_ty == types.error_type) return;
    // `any` on exactly one side is tsc's canonical TS2403 (`var a: any; var
    // a = 1;`) and the one verdict mutual assignability cannot reach — but
    // only when the program really asked for it; see `topTypeIsDeclared`.
    if (isAnyLike(c, sym_ty) != isAnyLike(c, decl_ty)) {
        const any_decl = if (isAnyLike(c, decl_ty)) decl else first;
        if (!topTypeIsDeclared(c, any_decl)) return;
    } else if (try typesIdentical(c, sym_ty, decl_ty)) return;
    try c.diagFmt(
        2403,
        c.tokSpan(tok),
        "Subsequent variable declarations must have the same type.  Variable '{s}' must be of type '{s}', but here has type '{s}'.",
        .{ c.tokenText(tok), try c.typeToString(sym_ty), try c.typeToString(decl_ty) },
    );
}
