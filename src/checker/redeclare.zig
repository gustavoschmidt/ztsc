//! "Subsequent declarations must agree" — the checks tsc runs over a name
//! declared MORE THAN ONCE: `errorNextVariableOrPropertyDeclarationMustHaveSameType`
//! (TS2403, below) and `checkTypeParameterListsIdentical` (TS2428, at the end
//! of this file).
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
//! `any` and `number` are mutually assignable and still an error. That relation
//! is `identity.zig`; `typesIdentical` is the screen in front of it, refusing
//! the inputs ztsc reached by giving up rather than by reading the program.

const std = @import("std");

const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const diagnostics = @import("../frontend/diagnostics.zig");
const global_dup = @import("../link/global_dup.zig");
const intern = @import("../intern.zig");
const modules = @import("../link/modules.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;
const TypeParamInfo = @import("typeparams.zig").TypeParamInfo;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const identity = @import("identity.zig");

/// The screen in front of tsc's `isTypeIdenticalTo` (`identity.zig`),
/// deliberately biased toward answering "identical".
///
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
///   4. `identity.identical` — the structural relation itself, which puts a
///      named reference and its structure, and an object type with one call
///      signature and a function type, on the same footing while keeping
///      everything tsc separates apart (`any` from `number`, `<T, U>(x: T,
///      y: U) => T` from `<T, U>(x: any, y: any) => any`).
///
/// `any`/`unknown` still needs the caller's help: ztsc uses `any` as its "could
/// not work this out" answer as well as for a written `any`, so the caller
/// settles that case before asking (see `checkSubsequentVarDecl`).
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
    // The relation is handed the UNRESOLVED pair: it resolves references
    // itself, and it has a rule that only applies to two materializations of
    // the same generic reference (an `any` type argument is ztsc's inference
    // giving up, not a difference the program wrote). `ea`/`eb` above exist
    // only for the screens that read a materialized shape.
    return identity.identical(c, a, b);
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

/// The value declaration a subsequent declarator is measured against.
///
///   * `sym` is the symbol whose TYPE tsc calls the variable's type — the
///     constituent that owns the value declaration, not the merged view (a
///     merged view folds every constituent, while tsc reads the first value
///     declaration alone).
///   * `own` is the constituent declared in the CURRENT file, which is what the
///     declarator being checked belongs to.
///   * `file`/`decl` locate the value declaration for the "is this it?" test.
const ValueDecl = struct { sym: SymbolId, own: SymbolId, file: modules.FileId, decl: Node };

/// Locate the symbol's value declaration, following a cross-file GLOBAL merge.
///
/// A merged id folds constituents tsc sometimes keeps apart: the merged
/// namespace-member index carries a namespace local that was never `export`ed,
/// so `namespace A { var Origin: string }` in one file would be compared against
/// another file's `export var Origin: Point`. What distinguishes tsc's `globals`
/// merge — where the comparison IS right — is that every constituent sits at its
/// file's top level, so that is the gate. It is the shape behind the common real
/// case: a script or `.d.ts` writing `declare var console: { log(…): void }`
/// beside the lib's `declare var console: Console`.
///
/// Declined outright when a constituent carries a value meaning that is not a
/// variable (a function/class/enum/namespace of the same name), because then
/// tsc's `valueDeclaration` is that other declaration and not a declarator at
/// all.
fn firstValueDeclOf(c: *Checker, sym: SymbolId) Error!?ValueDecl {
    if (!c.prog.isMergedId(sym)) {
        const decl = firstValueDecl(c, sym) orelse return null;
        return .{ .sym = sym, .own = sym, .file = c.cur_file, .decl = decl };
    }
    const parts = c.prog.mergedSym(sym).parts;
    // A merge tsc REJECTED is not a set of subsequent declarations of one
    // variable: `mergeSymbol` reports the duplicate (`declare const a: number`
    // beside `declare const a: string` is TS2451 at both) and never goes on to
    // compare the second declaration's type against the first's.
    {
        const flags = try c.scratch().alloc(binder.SymbolFlags, parts.len);
        defer c.scratch().free(flags);
        for (parts, 0..) |p, i| flags[i] = c.symFlags(p);
        if (global_dup.mergeClash(flags) != null) return null;
    }
    var found: ?ValueDecl = null;
    var own: SymbolId = 0;
    for (parts) |p| {
        if (c.symScope(p) != binder.file_scope) return null;
        const pf = c.symFlags(p);
        if (pf.function or pf.class or pf.enum_decl or pf.namespace_decl or
            pf.import_binding or pf.param or pf.catch_param) return null;
        if (c.symFile(p) == c.cur_file) own = p;
        if (found != null) continue;
        const file = c.symFile(p);
        for (c.prog.files[file].bind.declsOf(p - c.prog.sym_base[file])) |dn| {
            switch (c.prog.files[file].tree.nodeTag(dn)) {
                .declarator, .declarator_init, .declarator_full => {
                    found = .{ .sym = p, .own = p, .file = file, .decl = dn };
                    break;
                },
                else => {},
            }
        }
    }
    if (own == 0) return null;
    var v = found orelse return null;
    v.own = own;
    return v;
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
    // A BLOCK-SCOPED name never has a subsequent declaration to check. tsc's
    // `declareSymbol` reports the redeclaration (TS2451, or TS2300 when the
    // first declaration was a `var`) and then gives the offending declaration
    // a FRESH symbol, so `node === symbol.valueDeclaration` holds for it and
    // `checkVariableLikeDeclaration` takes the first arm:
    //
    //     var a = 10; let a;          // TS2300 twice — and no TS2403
    //     let b: number; let b: string;   // TS2451 twice — and no TS2403
    //
    // `let`/`const` excludes every value meaning (tsc's
    // `BlockScopedVariableExcludes`), so ONE such bit on the symbol means every
    // declaration after the first clashed. `var` beside `var` — the only pair
    // that really merges — is what is left, and it is the shape TS2403 is for.
    // (The cross-file spelling of the same rule is `mergeClash` in
    // `firstValueDeclOf`.)
    if (f.let_decl or f.const_decl) return;
    const value_decl = (try firstValueDeclOf(c, sym)) orelse return;
    // Node ids are per-file, so "this declarator IS the value declaration" is
    // only a question within one file.
    if (value_decl.file == c.cur_file and value_decl.decl == decl) return;
    const own = value_decl.own;
    const sym_ty = try c.typeOfSymbol(value_decl.sym);
    const decl_ty = try c.declaratorType(own, decl, is_const);
    if (sym_ty == types.error_type or decl_ty == types.error_type) return;
    // `any` on exactly one side is tsc's canonical TS2403 (`var a: any; var
    // a = 1;`) and the one verdict mutual assignability cannot reach — but
    // only when the program really asked for it; see `topTypeIsDeclared`.
    if (isAnyLike(c, sym_ty) != isAnyLike(c, decl_ty)) {
        // Reading the OTHER file's declaration node needs that file's tree, and
        // `topTypeIsDeclared` reads `c.tree`; a cross-file value declaration is
        // therefore only consulted when it is the one being checked.
        const any_decl = if (isAnyLike(c, decl_ty))
            decl
        else if (value_decl.file == c.cur_file)
            value_decl.decl
        else
            return;
        if (!topTypeIsDeclared(c, any_decl)) return;
    } else if (try typesIdentical(c, sym_ty, decl_ty)) return;
    try c.diagFmt(
        2403,
        c.tokSpan(tok),
        "Subsequent variable declarations must have the same type.  Variable '{s}' must be of type '{s}', but here has type '{s}'.",
        .{ c.tokenText(tok), try c.typeToString(sym_ty), try c.typeToString(decl_ty) },
    );
}

// ===========================================================================
// TS2717 — a subsequent PROPERTY declaration's own type
// ===========================================================================

/// The property half of the same rule: tsc runs one
/// `checkVariableLikeDeclaration` per property declaration and, for each
/// declaration that is not the symbol's `valueDeclaration`, compares that
/// declaration's OWN widened type against the symbol's type —
/// `errorNextVariableOrPropertyDeclarationMustHaveSameType` files TS2403 for a
/// variable and TS2717 for a property.
///
/// ztsc folds every declaration of a member into ONE `types.Prop`, so the
/// comparison cannot be made from the member table; it is made from the
/// declaration list, first declaration against each later one
/// (`memberDeclOwnType` is `getWidenedTypeForVariableLikeDeclaration`).
///
/// Only a PROPERTY declaration is reported at — a method's second declaration
/// is an overload, which tsc checks in `checkFunctionOrMethodDeclaration` and
/// never through this path — but the FIRST declaration may be anything, and its
/// own type is read exactly the way tsc reads it: from its type annotation,
/// which for a method or accessor is the RETURN annotation. That is what keeps
/// `class C { a(): number; a: number }` clean while
/// `class D { c: number; c: string }` reports.
///
/// Same file only: another file's node ids are not addressable through `c.tree`,
/// and a lib interface reopened by a program is the shape where a cross-file
/// verdict would be about ztsc's merge and not about the code.
///
/// `decl` is the declaration this walk is driven from, and it runs only from the
/// FIRST one: a merged interface's blocks share one members scope while
/// `checkInterfaceDecl` runs per block, so without that gate every clash would
/// be reported once per block.
pub fn checkSubsequentMemberDecls(c: *Checker, sym: SymbolId, decl: Node) Error!void {
    const decls = c.declsOf(sym);
    if (decls.len == 0 or decls[0] != decl) return;
    // Two NON-EXPORTED interfaces of one name in two blocks of a reopened
    // namespace are ONE symbol here and two unrelated symbols to tsc, so their
    // members were never redeclared at all — the same gate TS2428 needs, and it
    // keeps `mergedInterfacesWithConflictingPropertyNames`'s `M` (one namespace
    // block) reported while its `M2` (two) stays legal.
    if (decls.len > 1 and namespaceLocalAcrossBlocks(c, sym)) return;
    const local = c.localOf(sym);
    const scopes = [_]?binder.ScopeId{ c.bind.membersScopeOf(local), c.bind.staticsScopeOf(local) };
    for (scopes) |maybe_ms| {
        const ms = maybe_ms orelse continue;
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            try checkMemberRedeclare(c, c.toGlobal(c.bind.member_syms[i]));
        }
    }
}

/// TS2804 — a PRIVATE name (`#foo`) declared on both the static and the
/// instance side of one class.
///
/// A private name is not a property name: it is a lexically scoped slot on the
/// class, and the static and instance sides do not get one each. tsc's
/// `checkClassLikeDeclaration` runs
/// `checkClassNameCollisionWithObject`-adjacent bookkeeping over the private
/// identifiers of the class body and reports
/// "Static and instance elements cannot share the same private name" at EVERY
/// declaration of the clashing name, on both sides — so `#foo` beside
/// `static #foo` is two diagnostics, not one.
///
/// The binder files the two under separate scopes (`class_members` /
/// `class_statics`), which is right for every ORDINARY name — `x` and
/// `static x` are unrelated members — so the clash is only visible by
/// intersecting the two scopes, which is what this does. Same-side duplicates
/// are already the binder's ordinary TS2300.
///
/// Same file only, for the reason on `checkSubsequentMemberDecls`.
pub fn checkPrivateNameStaticDups(c: *Checker, sym: SymbolId, decl: Node) Error!void {
    const decls = c.declsOf(sym);
    if (decls.len == 0 or decls[0] != decl) return;
    const local = c.localOf(sym);
    const ms = c.bind.membersScopeOf(local) orelse return;
    const ss = c.bind.staticsScopeOf(local) orelse return;
    const lo = c.bind.scope_members_start[ms];
    const hi = c.bind.scope_members_start[ms + 1];
    for (lo..hi) |i| {
        const name = c.bind.member_atoms[i];
        if (!std.mem.startsWith(u8, c.atomText(name), "#")) continue;
        const static_local = c.bind.lookupInScope(ss, name) orelse continue;
        try reportPrivateNameClash(c, c.toGlobal(c.bind.member_syms[i]));
        try reportPrivateNameClash(c, c.toGlobal(static_local));
    }
}

/// Every declaration of `msym` gets the TS2804 (see
/// `checkPrivateNameStaticDups`), anchored at its name token.
fn reportPrivateNameClash(c: *Checker, msym: SymbolId) Error!void {
    if (c.symFile(msym) != c.cur_file) return;
    for (c.declsOf(msym)) |dn| {
        switch (c.nodeTag(dn)) {
            .class_field, .class_method => {},
            else => continue,
        }
        const tok = c.tree.nodeMainToken(dn);
        try c.diagFmt(
            2804,
            c.tokSpan(tok),
            "Duplicate identifier '{s}'. Static and instance elements cannot share the same private name.",
            .{c.tokenText(tok)},
        );
    }
}

fn checkMemberRedeclare(c: *Checker, msym: SymbolId) Error!void {
    if (c.symFile(msym) != c.cur_file) return;
    const decls = c.declsOf(msym);
    if (decls.len < 2) return;
    // A PRIVATE name declared twice in one class body is a hard duplicate, not
    // a merge: tsc gives the second declaration its own symbol, so it is its
    // container's `valueDeclaration` and `checkVariableLikeDeclaration` never
    // reaches the subsequent-declaration comparison. Reporting TS2717 on top of
    // the TS2300/TS2804 the pair already earns is ztsc's declaration-merging
    // model leaking — `privateNameDuplicateField`'s `#foo() {}` beside
    // `#foo = "foo"` got both.
    //
    // An ORDINARY class member is genuinely merged by tsc (`PropertyExcludes`
    // is `None`, so `c: number; c: string` is ONE symbol with two
    // declarations), and TS2717 at the later one is the only thing reported —
    // so the gate has to be this narrow.
    if (std.mem.startsWith(u8, c.atomText(c.symNameAtom(msym)), "#")) return;
    // A member's annotation is resolved in the MEMBER scope, whose parent chain
    // carries the container's type parameters. Read from the caller's scope
    // instead, `interface I<T> { m(): T; … }` cannot see `T` and every generic
    // member annotation became a TS2304.
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    c.cur_scope = c.symScope(msym);
    const first = (try memberDeclOwnType(c, decls[0])) orelse return;
    if (first == types.error_type) return;
    for (decls[1..]) |dn| {
        switch (c.nodeTag(dn)) {
            .class_field, .property_signature => {},
            else => continue,
        }
        const own = (try memberDeclOwnType(c, dn)) orelse continue;
        if (own == types.error_type) continue;
        if (try typesIdentical(c, first, own)) continue;
        const tok = c.tree.nodeMainToken(dn);
        try c.diagFmt(
            2717,
            c.tokSpan(tok),
            "Subsequent property declarations must have the same type.  Property '{s}' must be of type '{s}', but here has type '{s}'.",
            .{ c.tokenText(tok), try c.typeToString(first), try c.typeToString(own) },
        );
    }
}

/// tsc's `getWidenedTypeForVariableLikeDeclaration` for a class or interface
/// member: the type ANNOTATION when there is one, the widened initializer when
/// there is not, and `any` when there is neither (`widenTypeForVariableLike-
/// Declaration`'s fallback, which is what makes an unannotated `get Foo()`
/// disagree with `Foo = 0`). Null for a member shape this walk does not read —
/// an index or call signature, which has no name to be redeclared.
fn memberDeclOwnType(c: *Checker, decl: Node) Error!?TypeId {
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .class_field => {
            const f = c.tree.extraData(ast.Field, d.lhs);
            if (f.type_ann != 0) return annOwnType(c, f.type_ann);
            if (f.init != 0) return try c.widenInitializer(try c.checkExprCached(f.init, types.no_type), false);
            return types.any_type;
        },
        .property_signature => {
            if (d.lhs != 0) return annOwnType(c, d.lhs);
            return types.any_type;
        },
        .class_method, .method_signature => {
            const proto = c.tree.extraData(ast.FnProto, d.lhs);
            if (proto.return_type == 0) return types.any_type;
            // A signature's OWN type parameters live in its proto scope
            // (`sel<C extends CB>(cb: C): C`), so its return annotation is read
            // there and not in the member scope the caller entered.
            const saved_scope = c.cur_scope;
            defer c.cur_scope = saved_scope;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            return annOwnType(c, proto.return_type);
        },
        else => return null,
    }
}

/// The annotation's type, or null when the member is one this check declines to
/// judge.
///
/// `unique symbol` is the only such annotation. Its type is NOMINAL — keyed by
/// the declaration, and legal only in the positions `annTypeMaybeUnique` gates
/// — so two declarations of one member spelling it are two different types by
/// construction while tsc accepts the merge (`interface SymbolConstructor {
/// readonly observer: symbol }` beside `readonly observer: unique symbol`), and
/// reading the node through the plain `typeFromTypeNode` files TS1335 on top.
fn annOwnType(c: *Checker, ann: Node) Error!?TypeId {
    if (c.nodeTag(ann) == .unique_symbol_type) return null;
    return try c.typeFromTypeNode(ann);
}

// ===========================================================================
// TS2300 — a clodule's statics against its namespace's exports
// ===========================================================================

/// A `class C` merged with a `namespace C` (a "clodule") has ONE export table in
/// tsc: a class's STATIC members *are* its `exports`, and `mergeSymbol` folds the
/// namespace's exports into them. So a static member and an EXPORTED namespace
/// member of the same name collide, and tsc reports at every declaration of both:
///
///     class Point { static Origin: Point = …; }
///     namespace Point { export var Origin = ""; }   // TS2300 on both `Origin`s
///
/// ztsc keeps the two in separate scopes (`staticsScopeOf`, `namespaceScopeOf`),
/// which is why neither the binder nor the linker's global merge ever compares
/// them. This does, with `global_dup.cloduleClash` deciding — so a static method
/// beside an exported function clashes
/// (`ClassAndModuleThatMergeWithStaticFunctionAndExportedFunctionThatShareAName`)
/// while a static beside an exported `interface` does not.
///
/// Scope: the class's OWN file. Both halves of a clodule written across files are
/// a cross-file merge with no diagnostic surface here, and an under-report there
/// is the safe direction. Cost: two already-sorted member segments merged, and
/// only for a symbol that is both a class and a namespace.
pub fn checkCloduleMemberDups(c: *Checker, sym: SymbolId) Error!void {
    const local = c.localOf(sym);
    const b = c.bind;
    const ss = b.staticsScopeOf(local) orelse return;
    const ns = b.namespaceScopeOf(local) orelse return;

    const s_lo = b.scope_members_start[ss];
    const s_hi = b.scope_members_start[ss + 1];
    const n_lo = b.scope_members_start[ns];
    const n_hi = b.scope_members_start[ns + 1];
    var i = s_lo;
    var j = n_lo;
    while (i < s_hi and j < n_hi) {
        const sa = b.member_atoms[i];
        const na = b.member_atoms[j];
        if (sa < na) {
            i += 1;
            continue;
        }
        if (na < sa) {
            j += 1;
            continue;
        }
        defer {
            i += 1;
            j += 1;
        }
        const s_sym = b.member_syms[i];
        const n_sym = b.member_syms[j];
        // Only an EXPORTED namespace member reaches the shared table; a block
        // local is invisible to the class side (see `mergesAcrossBlocks`).
        if (!b.symbol_flags[n_sym].exported) continue;
        const code = global_dup.cloduleClash(b.symbol_flags[s_sym], b.symbol_flags[n_sym]) orelse continue;
        try reportAtDecls(c, s_sym, code);
        try reportAtDecls(c, n_sym, code);
    }
}

/// Report `code` at the name of every declaration of a LOCAL symbol of the
/// current file. A declaration whose name is not a single token (a destructuring
/// pattern) has no span to point at and is skipped.
fn reportAtDecls(c: *Checker, local: SymbolId, code: diagnostics.Code) Error!void {
    for (c.bind.declsOf(local)) |decl| {
        const tok = c.tree.declNameToken(decl) orelse continue;
        try c.diagFmt(code.tsCode(), c.tokSpan(tok), "Duplicate identifier '{s}'.", .{c.tokenText(tok)});
    }
}

// ===========================================================================
// TS2428 — "All declarations of 'X' must have identical type parameters"
// ===========================================================================

/// One class/interface declaration block of a merged symbol: the block node and
/// the constituent symbol whose FILE it lives in (the file its nodes, scopes and
/// source bytes must be read against).
const Block = struct { sym: SymbolId, node: Node };

/// tsc's `checkTypeParameterListsIdentical`/`areTypeParametersIdentical`: a
/// class/interface declared more than once must spell the SAME type-parameter
/// list in every block, and when it does not, EVERY declaration is reported —
/// not just the odd one out.
///
/// The verdict is a property of the whole declaration set, so it is recomputed
/// per block and reported only at the block being checked. Each block's own file
/// walk therefore files its own key and the set of keys is the one tsc prints,
/// with no cross-file diagnostic plumbing. Declaration sets are tiny (the lib's
/// most-reopened generic interface has about a dozen blocks) and a name declared
/// once returns before reading anything.
///
/// What "identical" means, position by position, and why each half is what it
/// is:
///
///   * ARITY. tsc compares against the merged list's MINIMUM and MAXIMUM
///     argument counts, so a block may omit trailing parameters that have
///     defaults — and may omit the list entirely when every parameter has one
///     (`@types/node` reopens `interface Buffer` bare beside
///     `interface Buffer<TArrayBuffer extends ArrayBufferLike = …>`). Anything
///     outside that window is a mismatch.
///   * NAMES. Positional, by name atom: `interface A<T>` beside
///     `interface A<U>` is an error even though the two lists are otherwise
///     interchangeable. Purely syntactic, so this half can never invent an
///     error.
///   * CONSTRAINTS and DEFAULTS. tsc reads them off the type parameter's whole
///     declaration set, so a block that OMITS one adopts what another block
///     declares — `interface C<T>` beside `interface C<T extends number>` is
///     legal in either order. Only two blocks that both declare position `i`
///     and disagree are an error, and "disagree" is decided by
///     `annotationsAgree`, which is deliberately timid.
pub fn checkTypeParamListsIdentical(c: *Checker, sym: SymbolId, name_tok: ast.TokenIndex) Error!void {
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(c.scratch());
    try declarationBlocks(c, sym, &blocks);
    if (blocks.items.len < 2) return;
    if (namespaceLocalAcrossBlocks(c, sym)) return;

    if (try listsIdentical(c, blocks.items)) return;
    try c.diagFmt(
        2428,
        c.tokSpan(name_tok),
        "All declarations of '{s}' must have identical type parameters.",
        .{c.tokenText(name_tok)},
    );
}

/// Are these declarations two symbols to tsc that ztsc has folded into one?
///
/// A namespace reopened in the same file contributes to ONE merged body scope
/// here, so a NON-EXPORTED member declared in two different blocks becomes a
/// single symbol with two declarations. tsc keeps those apart — a non-exported
/// member lives in that block's `locals`, and only an `export`ed one reaches the
/// merged `exports` table — so comparing them would report on legal code:
///
///     namespace M { interface B<T, U> { x: U } }
///     namespace M { interface B<T, V> { y: V } }   // ok to tsc: two symbols
///
/// Two blocks of the SAME namespace declaration are one table in tsc too, so the
/// gate is "more than one block", not "inside a namespace": that keeps
/// `namespace M { interface A<T> {} interface A<U> {} }` reported.
fn namespaceLocalAcrossBlocks(c: *Checker, sym: SymbolId) bool {
    const s = c.reprSym(sym);
    if (c.symFlags(s).exported) return false;
    const scope = c.symScope(s);
    const file = c.symFile(s);
    const b = c.prog.files[file].bind;
    if (scope == binder.file_scope or b.scope_kinds[scope] != .namespace) return false;
    // The namespace whose body scope this is, and how many blocks it has.
    for (b.ns_scope_ids, 0..) |sid, i| {
        if (sid != scope) continue;
        var blocks: usize = 0;
        for (b.declsOf(b.ns_scope_syms[i])) |dn| {
            if (c.prog.files[file].tree.nodeTag(dn) == .namespace_decl) blocks += 1;
        }
        return blocks > 1;
    }
    return false;
}

/// Every class/interface declaration block of `sym`, across constituents of a
/// cross-file merge, in merge order.
fn declarationBlocks(c: *Checker, sym: SymbolId, out: *std.ArrayList(Block)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |d| {
            switch (c.nodeTag(d)) {
                .class_decl, .interface_decl => try out.append(c.scratch(), .{ .sym = csym, .node = d }),
                else => {},
            }
        }
    }
}

/// One position of the UNION list every block is measured against: the name it
/// must spell there, and the first constraint/default any block declares for it
/// (each with the type-parameter symbol whose file and scope the node is read
/// against).
const Slot = struct {
    name: Atom,
    constraint: Node = null_node,
    constraint_sym: SymbolId = 0,
    default: Node = null_node,
    default_sym: SymbolId = 0,
};

/// Does every block's list fall inside the union list's arity window and agree
/// with every other block on names, constraints and defaults?
///
/// The window is measured against the UNION of the blocks' lists, not against any
/// one block: tsc reads each position's default off the type parameter's whole
/// declaration set, so a default declared by ANY block makes that position
/// optional for EVERY block. That is what makes
///
///     interface i04 {}                            // 0 arguments
///     interface i04<T> {}                         // 1, no default here
///     interface i04<T = number> {}                // the default for position 0
///     interface i04<T = number, U = string> {}    // and for position 1
///
/// legal: the union is `<T = number, U = string>`, whose minimum argument count
/// is 0 and maximum 2, and every block sits inside that.
fn listsIdentical(c: *Checker, blocks: []const Block) Error!bool {
    var slots: std.ArrayList(Slot) = .empty;
    defer slots.deinit(c.scratch());
    var list: std.ArrayList(TypeParamInfo) = .empty;
    defer list.deinit(c.scratch());

    // Pass 1: the union. A position's name comes from the first block that
    // declares it, its constraint/default from the first block that declares one.
    for (blocks) |b| {
        try blockTypeParams(c, b, &list);
        for (list.items, 0..) |tp, i| {
            if (i == slots.items.len) {
                try slots.append(c.scratch(), .{ .name = c.symNameAtom(tp.sym) });
            }
            const slot = &slots.items[i];
            if (slot.constraint == null_node and tp.constraint != null_node) {
                slot.constraint = tp.constraint;
                slot.constraint_sym = tp.sym;
            }
            if (slot.default == null_node and tp.default != null_node) {
                slot.default = tp.default;
                slot.default_sym = tp.sym;
            }
        }
    }
    const max_n = slots.items.len;
    // tsc's `getMinTypeArgumentCount`: the count up to and including the last
    // position with no default.
    var min_n: usize = 0;
    for (slots.items, 0..) |slot, i| {
        if (slot.default == null_node) min_n = i + 1;
    }

    // Pass 2: every block against the union.
    for (blocks) |b| {
        try blockTypeParams(c, b, &list);
        if (list.items.len < min_n or list.items.len > max_n) return false;
        for (list.items, 0..) |tp, i| {
            const slot = slots.items[i];
            if (c.symNameAtom(tp.sym) != slot.name) return false;
            if (tp.constraint != null_node and tp.constraint != slot.constraint and
                !try annotationsAgree(c, slot.constraint, slot.constraint_sym, tp.constraint, tp.sym))
            {
                return false;
            }
            if (tp.default != null_node and tp.default != slot.default and
                !try annotationsAgree(c, slot.default, slot.default_sym, tp.default, tp.sym))
            {
                return false;
            }
        }
    }
    return true;
}

/// One block's type-parameter list, read in that block's own file context.
fn blockTypeParams(c: *Checker, b: Block, out: *std.ArrayList(TypeParamInfo)) Error!void {
    out.clearRetainingCapacity();
    const saved = c.enterSymFile(b.sym);
    defer c.restoreCtx(saved);
    try c.declTypeParams(b.node, out);
}

/// Do two type-parameter annotations (two constraints, or two defaults) from
/// different blocks say the same thing? Two screens, in this order, and both of
/// them err toward "yes":
///
///   1. The SOURCE TEXT of the two nodes. Equal text is equal meaning, and it
///      is the only screen that can see through a type parameter: each block
///      binds its OWN parameter symbols, so `interface I<T extends Foo<T>>`
///      written twice mentions two DIFFERENT `T`s, whose types are unrelated to
///      the relation engine even though the source is identical.
///   2. `typesIdentical`, for text that differs. `T extends Date` beside
///      `T extends Number` is a real mismatch; `T extends string` beside
///      `T extends S` where `type S = string` is not, and only the types can
///      tell those apart.
///
/// A textually-different annotation that mentions a type parameter is therefore
/// judged by (2), which will usually call it identical — an under-report, and
/// the safe direction.
fn annotationsAgree(c: *Checker, a: Node, a_sym: SymbolId, b: Node, b_sym: SymbolId) Error!bool {
    if (nodeTextEql(c, a, a_sym, b, b_sym)) return true;
    const ta = try annotationType(c, a, a_sym);
    const tb = try annotationType(c, b, b_sym);
    if (ta == types.error_type or tb == types.error_type) return true;
    return typesIdentical(c, ta, tb);
}

/// The type of an annotation node, read in the file and scope of the type
/// parameter that declared it. A failure to type it at all reads as "agrees":
/// this check must never turn ztsc's own gap into an error on legal code.
fn annotationType(c: *Checker, node: Node, tp_sym: SymbolId) Error!TypeId {
    const saved = c.enterSymFile(tp_sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(tp_sym);
    return c.typeFromTypeNode(node) catch types.error_type;
}

/// The two nodes' source text, compared with ASCII whitespace normalized away.
/// Each node is read against the tree and source of the file its own type
/// parameter lives in, so a cross-file merge compares the right bytes.
fn nodeTextEql(c: *Checker, a: Node, a_sym: SymbolId, b: Node, b_sym: SymbolId) bool {
    const pa = &c.prog.files[c.symFile(a_sym)];
    const pb = &c.prog.files[c.symFile(b_sym)];
    const sa = pa.tree.span(pa.src, a);
    const sb = pb.tree.span(pb.src, b);
    return whitespaceInsensitiveEql(pa.src[sa.start..sa.end], pb.src[sb.start..sb.end]);
}

/// Byte equality ignoring ASCII whitespace — enough to make "the same
/// annotation, formatted differently" compare equal without running a second
/// tokenizer. Two spellings differing only inside a string literal's whitespace
/// are the theoretical false "equal", and calling those identical is the safe
/// direction anyway.
fn whitespaceInsensitiveEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}
