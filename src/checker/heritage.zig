//! Heritage-clause conformance: what a declaration inherits versus what it
//! redeclares.
//!
//! Two checks live here, both of them "compare a declaration against the
//! thing it extends":
//!
//!   * TS2430 — an `interface` must be assignable to every interface it
//!     extends (tsc's `checkInterfaceDeclaration`), with the TS2320
//!     "bases disagree with each other" alternative that suppresses it;
//!   * TS2612 — a derived class property that redeclares a base class
//!     property without initializing it (tsc's
//!     `checkKindsOfPropertyMemberOverrides`), which under
//!     `useDefineForClassFields` semantics silently overwrites the base value
//!     with `undefined`.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const elaborate = @import("elaborate.zig");
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;

/// TS2430: `interface D extends B` where `D` is not assignable to `B`.
///
/// tsc's `checkInterfaceDeclaration`:
///
/// ```ts
/// const firstInterfaceDecl = getDeclarationOfKind(symbol, SyntaxKind.InterfaceDeclaration);
/// if (node === firstInterfaceDecl) {
///     const type = getDeclaredTypeOfSymbol(symbol);
///     const typeWithThis = getTypeWithThisArgument(type);
///     if (checkInheritedPropertiesAreIdentical(type, node.name)) {
///         for (const baseType of getBaseTypes(type)) {
///             checkTypeAssignableTo(typeWithThis, getTypeWithThisArgument(baseType, type.thisType),
///                 node.name, Diagnostics.Interface_0_incorrectly_extends_interface_1);
///         }
///     }
/// }
/// ```
///
/// Four properties of that shape matter and are reproduced here:
///
///   * the check runs ONCE per interface SYMBOL, on its first declaration —
///     a reopened `interface I { … }` block does not re-report — and the
///     bases are the merged symbol's, not that one block's;
///   * the source is the interface as a REFERENCE (`Derived<T>`, tsc's
///     `getTypeWithThisArgument`), which is also what the headline names;
///   * the diagnostic is anchored at the interface NAME, never at the
///     heritage reference that failed;
///   * a failing TS2320 (`checkInheritedPropertiesAreIdentical`) suppresses
///     TS2430 outright. The two are alternatives: an interface whose bases
///     disagree with EACH OTHER is told that, not that it fails to extend
///     one of them.
///
/// The class analogue (TS2415/TS2416, `stmts.zig`) needs a per-member second
/// pass because tsc splits the class message; the interface message has no
/// such split, so the elaboration chain the relation would have printed is
/// the whole body.
///
/// tsc reports one TS2430 per failing base; `diagFmt` dedupes on
/// `(file, code, span-start)` and every one of them lands on the same name
/// token, so ztsc prints the first. The chain under it describes the same
/// conflict, and the diagnostic KEY set — which is what parity is measured
/// on — is identical either way.
pub fn checkInterfaceExtends(c: *Checker, sym: SymbolId, node: Node, name_token: ast.TokenIndex) Error!void {
    if (name_token == 0) return;
    if (!isFirstInterfaceDecl(c, sym, node)) return;
    // Most interfaces extend nothing, and everything below — the type-parameter
    // list, the heritage re-walk, one relation per base — costs something. One
    // syntactic scan of the declarations skips all of it.
    if (!hasHeritage(c, sym)) return;
    if ((try c.interfaceGeneric(sym)) == types.error_type) return;
    const self = try selfReference(c, sym) orelse return;

    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    {
        // `interfaceHeritageTypes` resolves the clauses in the symbol's own
        // file and moves `cur_scope` to each block's scope as it goes.
        // Re-walking them is diagnostic-safe: type-node diagnostics dedupe on
        // `(file, code, span)` and `queueTypeArgConstraints` dedupes on the
        // clause node, so this second walk adds nothing the first one did not
        // already record.
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        // tsc's `getBaseTypes` runs `resolveBaseTypesOfClass` BEFORE
        // `resolveBaseTypesOfInterface` and a declaration-merged
        // `class C {} interface C extends I {}` has both flags, so the class's
        // `extends` is one of the interface's base types too. Leaving it out
        // reported TS2430 against the interface base where tsc reports TS2320
        // against the pair (`mergedInheritedMembersSatisfyAbstractBase`).
        if (c.symFlags(sym).class) {
            if (try c.baseClassRef(sym)) |b| try bases.append(c.scratch(), b);
        }
        try c.interfaceHeritageTypes(sym, &bases);
    }
    try dropRepeatedBases(c, sym, &bases);

    // The interface's OWN member names, read once: both checks below need
    // them (`checkInheritedPropertiesIdentical` to seed, the generic-override
    // screen to identify what this interface redeclares).
    var own: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer own.deinit(c.scratch());
    try ownMemberNames(c, sym, &own);

    if (!try checkInheritedPropertiesIdentical(c, self, bases.items, &own, name_token)) return;

    for (bases.items) |base| {
        if (!try relatableBase(c, base) or base == self) continue;
        if (try genericOverrideUnrelatable(c, self, base, &own)) continue;
        if (try c.isAssignable(self, base)) continue;
        try c.diagFmt(2430, c.tokSpan(name_token), "Interface '{s}' incorrectly extends interface '{s}'.{s}", .{
            try c.typeToString(self),
            try c.typeToString(base),
            try elaborate.chainText(c, self, base),
        });
    }
}

/// The interface as tsc's `getTypeWithThisArgument(type)` sees it: a
/// reference to its own symbol carrying its own type parameters as arguments
/// (`Derived<T>`, not the folded member object). Relating and printing both
/// want this form — the fold is what `isAssignable` reaches on its own, and
/// the headline is supposed to name the interface.
///
/// Null — the check declines — for a GENERIC symbol that is also a class.
/// tsc unifies the two halves' type parameter lists
/// (`checkTypeParameterListsIdentical`, TS2428 when they disagree) and reads
/// every member through the one list; ztsc keeps a distinct type-parameter
/// symbol per declaration, so `interface S<T> extends R<T> {}` merged with
/// `declare class S<T> { … }` relates the class half's `T` against the
/// interface half's `T` and reports "Type 'T' is not assignable to type 'T'".
/// The gap is in the merged member table, not in this check, so this check
/// stays out of it. A NON-generic merge has no such ambiguity and is checked
/// (`mergedInheritedMembersSatisfyAbstractBase` needs it).
fn selfReference(c: *Checker, sym: SymbolId) Error!?TypeId {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len != 0 and c.symFlags(sym).class) return null;
    const args = try c.scratch().alloc(TypeId, tps.items.len);
    for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
    return try c.ts.makeRef(sym, args);
}

/// A base ztsc resolved well enough to relate against.
///
/// An unresolved base (`err`) contributes nothing to the interface's own
/// members either, so the verdict would be about ztsc's gap rather than the
/// code — the same guard the class heritage checks use.
///
/// A base that resolves to something other than an OBJECT is the second
/// exclusion, and it is a ztsc representation boundary rather than a tsc
/// rule: `interface Matches extends Array<string>` has an `.array` base,
/// which `mergeBaseResolved` folds into the derived interface as a plain
/// object carrying the array's members. That fold is one-way — the resulting
/// object is not an `.array` — so relating it back to `string[]` always fails
/// and would report TS2430 on code tsc accepts. tsc has no such asymmetry
/// (`Array<T>` is an ordinary interface there). The conformance cases that
/// pin this shape are `assignability/interface_extends_array.ts` and
/// `inference/100_array_like_interface_contextual_element.ts`.
fn relatableBase(c: *Checker, base: TypeId) Error!bool {
    if (base == types.error_type or base == types.any_type) return false;
    if (c.ts.kind(base) == .err) return false;
    return c.ts.kind(try c.resolveStructural(base)) == .object;
}

/// Does this interface override a base member with a GENERIC signature the
/// base does not have? Then ztsc's verdict on the pair is not trustworthy and
/// the check declines.
///
/// tsc's `compareSignaturesRelated` instantiates a generic SOURCE signature in
/// the target's context (`instantiateSignatureInContextOf`) before comparing
/// parameters, so `child<U extends Extract<keyof T, string>>(path: U)` relates
/// to `child(path: string)` by solving `U := string`. ztsc's relation does
/// that only once the outer type arguments are known; with the interface's own
/// `T` still free it compares `string` against the uninstantiated `U` and says
/// no, which would report TS2430 on code tsc accepts (`deeplyNestedCheck.ts`).
///
/// The screen is deliberately narrow — a generic member on the DERIVED side,
/// shadowing a base member — because the reverse shape (a generic member in
/// the BASE, as in `subtypingWithGenericCallSignaturesWithOptionalParameters`)
/// is a genuine under-report of the same relation gap and must not be turned
/// into silence here as well. Removing this screen is the observable test that
/// the relation gap is fixed.
fn genericOverrideUnrelatable(
    c: *Checker,
    self: TypeId,
    base: TypeId,
    own: *const std.AutoHashMapUnmanaged(Atom, void),
) Error!bool {
    if (own.count() == 0) return false;
    const derived = try c.resolveStructural(self);
    const rb = try c.resolveStructural(base);
    for (0..c.ts.objectPropCount(derived)) |i| {
        const p = c.ts.objectProp(derived, @intCast(i));
        if (!own.contains(p.name)) continue;
        const bp = (try c.propOfTypeEx(rb, p.name, false)) orelse continue;
        if (try hasGenericSignature(c, p.ty) and !try hasGenericSignature(c, bp.ty)) return true;
    }
    return false;
}

/// Does `t` carry a call or construct signature with type parameters of its
/// own? A method's type is a bare `.function`; an overload set or a callable
/// object carries them on an `.object`.
fn hasGenericSignature(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    if (c.ts.kind(r) == .function) return c.ts.fnTypeParams(r).len != 0;
    if (c.ts.kind(r) != .object) return false;
    for (0..c.ts.objectCallSigCount(r)) |i| {
        if (c.ts.fnTypeParams(c.ts.objectCallSig(r, @intCast(i))).len != 0) return true;
    }
    for (0..c.ts.objectConstructSigCount(r)) |i| {
        if (c.ts.fnTypeParams(c.ts.objectConstructSig(r, @intCast(i))).len != 0) return true;
    }
    return false;
}

/// TS2320, tsc's `checkInheritedPropertiesAreIdentical`: two of an
/// interface's bases may not disagree about a property the interface does not
/// itself redeclare.
///
/// ```ts
/// const seen = new Map();
/// forEach(resolveDeclaredMembers(type).declaredProperties, p => seen.set(p.escapedName, { prop: p, containingType: type }));
/// for (const base of baseTypes) {
///     for (const prop of getPropertiesOfType(getTypeWithThisArgument(base, type.thisType))) {
///         const existing = seen.get(prop.escapedName);
///         if (!existing) seen.set(prop.escapedName, { prop, containingType: base });
///         else if (existing.containingType !== type && !isPropertyIdenticalTo(existing.prop, prop)) { ok = false; error(…); }
///     }
/// }
/// ```
///
/// Seeding with the interface's OWN member names is what makes
/// `interface D extends A, B { x: … }` legal however far A's and B's `x`
/// diverge: `D` redeclares it, so it is `D`'s job to satisfy both, which is
/// TS2430's question and not this one. Only the names the interface inherits
/// without redeclaring are compared, and only across DIFFERENT bases.
///
/// tsc's `isPropertyIdenticalTo` runs the *identity* relation, which ztsc
/// does not have; mutual assignability stands in for it. That is the strictly
/// broader relation, so the error direction is under-reporting — a pair tsc
/// calls non-identical but that relates both ways stays silent here (and its
/// TS2430 then fires, which is the alternative tsc would have suppressed).
/// Returns whether the caller should go on to TS2430.
fn checkInheritedPropertiesIdentical(
    c: *Checker,
    self: TypeId,
    bases: []const TypeId,
    own: *const std.AutoHashMapUnmanaged(Atom, void),
    name_token: ast.TokenIndex,
) Error!bool {
    if (bases.len < 2) return true;

    // Name -> (type, owning base). Scratch-lived: one entry per inherited
    // property of one interface, freed with the check.
    var seen: std.AutoHashMapUnmanaged(Atom, struct { prop: types.Prop, from: TypeId }) = .empty;
    defer seen.deinit(c.scratch());

    var ok = true;
    for (bases) |base| {
        if (!try relatableBase(c, base)) continue;
        const r = try c.resolveStructural(base);
        for (0..c.ts.objectPropCount(r)) |i| {
            const prop = c.ts.objectProp(r, @intCast(i));
            if (own.contains(prop.name)) continue;
            const gop = try seen.getOrPut(c.scratch(), prop.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .prop = prop, .from = base };
                continue;
            }
            const prev = gop.value_ptr.*;
            if (prev.from == base) continue;
            if (try propsIdentical(c, prev.prop, prop)) continue;
            ok = false;
            try c.diagFmt(2320, c.tokSpan(name_token), "Interface '{s}' cannot simultaneously extend types '{s}' and '{s}'.\n  Named property '{s}' of types '{s}' and '{s}' are not identical.", .{
                try c.typeToString(self),
                try c.typeToString(prev.from),
                try c.typeToString(base),
                c.atomText(prop.name),
                try c.typeToString(prev.from),
                try c.typeToString(base),
            });
        }
    }
    return ok;
}

/// tsc's `isPropertyIdenticalTo` (`compareProperties` with
/// `compareTypesIdentical`), with mutual assignability standing in for the
/// identity relation — see `checkInheritedPropertiesIdentical`.
fn propsIdentical(c: *Checker, a: types.Prop, b: types.Prop) Error!bool {
    if (a.optional() != b.optional()) return false;
    if (a.ty == b.ty) return true;
    return (try c.isAssignable(a.ty, b.ty)) and (try c.isAssignable(b.ty, a.ty));
}

/// Collapse repeated bases of a GENERIC interface written as several blocks.
///
/// Each block gets its own type-parameter symbols in ztsc, so
/// `interface I<T> extends B<T> {}` written twice produces two base types that
/// differ only in WHICH `T` they carry. tsc unifies the lists first
/// (`checkTypeParameterListsIdentical`, TS2428 when they disagree) and ends up
/// with one `B<T>`; ztsc ends up with `B<T₁>` and `B<T₂>`, which compare
/// non-identical property by property. react16.d.ts's twice-declared
/// `HTMLAttributes<T> extends DOMAttributes<T>` is the shape, and it
/// manufactured a TS2320 in 26 otherwise-matching cases plus a TS2430 on a
/// reduction of it.
///
/// Keeping the FIRST base per symbol is what tsc's unification amounts to
/// here. Restricted to the multi-block generic case so that a single block's
/// `extends A<string>, A<number>` — where tsc really does compare two
/// different instantiations — keeps both.
fn dropRepeatedBases(c: *Checker, sym: SymbolId, bases: *std.ArrayList(TypeId)) Error!void {
    if (bases.items.len < 2) return;
    var blocks: usize = 0;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) == .interface_decl) blocks += 1;
    }
    if (blocks < 2) return;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) return;

    var kept: usize = 0;
    outer: for (bases.items) |b| {
        if (c.ts.kind(b) == .ref) {
            const s = c.ts.refSymbol(b);
            for (bases.items[0..kept]) |k| {
                if (c.ts.kind(k) == .ref and c.ts.refSymbol(k) == s) continue :outer;
            }
        }
        bases.items[kept] = b;
        kept += 1;
    }
    bases.shrinkRetainingCapacity(kept);
}

/// The member names the interface's own blocks declare — tsc's
/// `resolveDeclaredMembers(type).declaredProperties`, reduced to the names,
/// which is all the seeding above needs.
fn ownMemberNames(c: *Checker, sym: SymbolId, out: *std.AutoHashMapUnmanaged(Atom, void)) Error!void {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| try out.put(c.scratch(), c.bind.member_atoms[i], {});
    }
}

/// tsc's `getDeclarationOfKind(symbol, SyntaxKind.InterfaceDeclaration)`:
/// is `node` the symbol's FIRST `interface` block? A reopened block is a
/// second declaration of the same symbol and re-running the check there
/// would report the merged type's single verdict once per block.
fn isFirstInterfaceDecl(c: *Checker, sym: SymbolId, node: Node) bool {
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        return decl == node;
    }
    return false;
}

/// Does any declaration of `sym` write a heritage clause? Syntax only: the
/// `extends` list of any `interface` block, or the `extends` of a merged
/// `class` half. With none, `getBaseTypes` would be empty and neither TS2320
/// nor TS2430 has anything to say.
fn hasHeritage(c: *Checker, sym: SymbolId) bool {
    for (c.declsOf(sym)) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .interface_decl => {
                const data = c.tree.extraData(ast.InterfaceData, d.lhs);
                if (data.extends_end > data.extends_start) return true;
            },
            .class_decl => {
                if (c.tree.extraData(ast.ClassData, d.lhs).extends != 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// What the base class chain declares for one member name, extracted while
/// the walk still holds the declaring file's context (a `Node` from another
/// file would index the wrong tree once the context is restored).
const BaseMember = struct {
    /// A `class_field` — tsc's `SymbolFlags.Property`. False for a method or
    /// an accessor, both of which are `class_method` here.
    is_field: bool,
    /// The declaration's modifier flags (`private`, `abstract`, `accessor`, …).
    flags: u32,
};

/// TS2612, tsc's `checkKindsOfPropertyMemberOverrides` restricted to the arm
/// that fires under `useDefineForClassFields`:
///
/// ```ts
/// else if (useDefineForClassFields) {
///     const uninitialized = derived.declarations?.find(d =>
///         d.kind === SyntaxKind.PropertyDeclaration && !d.initializer);
///     if (uninitialized
///         && !(derived.flags & SymbolFlags.Transient)
///         && !(baseDeclarationFlags & ModifierFlags.Abstract)
///         && !(derivedDeclarationFlags & ModifierFlags.Abstract)
///         && !derived.declarations?.some(d => !!(d.flags & NodeFlags.Ambient))) {
///         const constructor = findConstructorDeclaration(…);
///         const propName = uninitialized.name;
///         if (uninitialized.exclamationToken || !constructor || !isIdentifier(propName)
///             || !strictNullChecks || !isPropertyInitializedInConstructor(propName, type, constructor)) {
///             error(…, Property_0_will_overwrite_the_base_property_in_1_…);
///         }
///     }
/// }
/// ```
///
/// A field declaration with no initializer EMITS one under class-fields
/// semantics (`Object.defineProperty(this, "x", { value: undefined })`), so
/// it destroys whatever the base constructor put there. The fix tsc names is
/// an initializer (say so) or a `declare` modifier (there is no field, only a
/// type).
///
/// The exemptions each come from a line of the source above and each was
/// verified against the oracle:
///
///   * `declare x` on the member (tsc's `NodeFlags.Ambient`), which emits no
///     field at all. The other half of `NodeFlags.Ambient` — every member of
///     a `declare class`, a `.d.ts`, or a `declare namespace` body — is the
///     caller's gate, which it shares with TS2564;
///   * `abstract` on either side — an abstract member emits nothing either;
///   * an initializer on the derived member, which is the intended spelling;
///   * `static`, because the loop is over the base's INSTANCE properties;
///   * a base member that is a METHOD (prototype property) or an ACCESSOR:
///     tsc routes those to `continue` and to TS2610 respectively, never here;
///   * a base member declared by the class's merged INTERFACE half rather
///     than by its class body (`interface J extends I {}` + `class J`), which
///     tsc screens with `base.valueDeclaration.parent.kind === InterfaceDeclaration`
///     and which falls out here from only ever consulting class member
///     declarations;
///   * `private` on either side — a private member is not an override;
///   * a constructor that definitely assigns the property, which is the whole
///     point of the rule: the base value is overwritten and then rewritten.
///     `!` on the derived member forfeits that escape (tsc tests it FIRST),
///     as does a non-identifier name (`"quoted"`, `3`), which tsc cannot
///     build a flow reference for.
///
/// Runs after the member walk so the constructor's body has been checked and
/// its flow is queryable — the same ordering constraint TS2564 has, and the
/// same `ctor`/`widened` pair drives both.
pub fn checkBasePropertyOverwrites(
    c: *Checker,
    class_sym: SymbolId,
    this_t: TypeId,
    members: []const Node,
    ctor: Node,
    ctor_widened: bool,
) Error!void {
    const base_ref = try c.baseClassRef(class_sym) orelse return;
    if (base_ref == types.error_type or base_ref == types.any_type or base_ref == this_t) return;
    if (try c.hasUnresolvedBase(class_sym)) return;
    const derived = try c.resolveStructural(this_t);

    for (members) |member| {
        if (member == null_node or c.nodeTag(member) != .class_field) continue;
        const e = c.tree.extraData(ast.Field, c.tree.nodeData(member).lhs);
        // An initializer is the intended spelling; `accessor x` is an
        // accessor, not a property (tsc's TS2611 arm, not this one).
        if (e.init != 0 or e.flags & ast.Flags.accessor != 0) continue;
        const skip = ast.Flags.static | ast.Flags.declare | ast.Flags.abstract |
            ast.Flags.private | ast.Flags.computed | ast.Flags.computed_sym;
        if (e.flags & skip != 0) continue;
        const tok = c.tree.nodeMainToken(member);
        // A `#private` field is not a property of the type at all, so it can
        // never override one.
        const text = c.tokenText(tok);
        if (text.len != 0 and text[0] == '#') continue;
        const name = try c.memberKey(tok, e.flags);

        const base = try baseClassMember(c, class_sym, base_ref, name) orelse continue;
        if (!base.is_field) continue; // a method or an accessor in the base
        if (base.flags & (ast.Flags.private | ast.Flags.abstract | ast.Flags.accessor) != 0) continue;

        if (e.flags & ast.Flags.definite == 0 and ctor != null_node and isIdentifierName(c, tok)) {
            const declared = if (try c.propOfTypeEx(derived, name, false)) |p| p.ty else types.no_type;
            if (try c.propAssignedInCtor(ctor, ctor_widened, name, declared)) continue;
        }
        try c.diagFmt(2612, c.tokSpan(tok), "Property '{s}' will overwrite the base property in '{s}'. If this is intentional, add an initializer. Otherwise, add a 'declare' modifier or remove the redundant declaration.", .{
            propertyDisplayName(c, tok, name),
            try c.typeToString(base_ref),
        });
    }
}

/// tsc's `isIdentifier(propName)` on a member name: a quoted or numeric
/// member name is a literal, not an identifier, and tsc cannot synthesize the
/// `this.<name>` reference its constructor-initialization query needs.
/// Keywords used as member names (`class C { for: number }`) ARE identifiers.
fn isIdentifierName(c: *Checker, tok: ast.TokenIndex) bool {
    return switch (c.tree.tokens.tag(tok)) {
        .string_literal, .numeric_literal => false,
        else => true,
    };
}

/// tsc's `symbolToString` for a property name: a name that was written as a
/// string literal prints back WITH quotes (`Property '"quoted"'`), a numeric
/// one without. The atom has already lost its quotes, so they go back on.
fn propertyDisplayName(c: *Checker, tok: ast.TokenIndex, name: Atom) []const u8 {
    if (c.tree.tokens.tag(tok) != .string_literal) return c.atomText(name);
    return std.fmt.allocPrint(c.scratch(), "\"{s}\"", .{c.atomText(name)}) catch c.atomText(name);
}

/// The base class chain's declaration of instance member `name`, or null when
/// no class body on the chain declares it.
///
/// tsc reads `base.valueDeclaration` off the property symbol; ztsc's resolved
/// property carries no symbol identity (see `abstractSatisfiedElsewhere`), so
/// the declaration is reached the same way `classChainMemberIsAbstract` does
/// — the class's own member scope, then its `extends` chain. Only class BODY
/// members answer: a name the base's merged `interface` half declares is not
/// found here, which is exactly tsc's `base.valueDeclaration.parent.kind ===
/// InterfaceDeclaration` screen.
///
/// The walk stops at a class it has already visited. `class C extends E`,
/// `class D extends C`, `class E extends D` is a base CYCLE: tsc reports
/// TS2506 and leaves `getBaseTypes` empty, so nothing is inherited and no
/// member of those classes overrides anything. Without the visited set the
/// walk goes all the way round and finds the class's OWN member as its own
/// base member, reporting TS2612 on all three
/// (`classExtendsItselfIndirectly`).
fn baseClassMember(c: *Checker, origin: SymbolId, t0: TypeId, name: Atom) Error!?BaseMember {
    // Cycle-detection stack, bounded by the same depth every other `extends`
    // walk here uses. Local to one lookup, and seeded with the class the walk
    // started from so `class C extends E` cannot rediscover `C`'s own members.
    var seen: [64]SymbolId = undefined;
    seen[0] = origin;
    var n: usize = 1;
    var t = t0;
    while (n < seen.len) {
        if (c.ts.kind(t) != .ref) return null;
        const sym = c.ts.refSymbol(t);
        if (!c.symFlags(sym).class) return null;
        for (seen[0..n]) |s| if (s == sym) return null;
        seen[n] = sym;
        n += 1;
        {
            const saved = c.enterSymFile(sym);
            defer c.restoreCtx(saved);
            if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
                const lo = c.bind.scope_members_start[ms];
                const hi = c.bind.scope_members_start[ms + 1];
                for (lo..hi) |i| {
                    if (c.bind.member_atoms[i] != name) continue;
                    if (memberDeclKind(c, c.toGlobal(c.bind.member_syms[i]))) |m| return m;
                }
            }
        }
        t = try c.baseClassRef(sym) orelse return null;
    }
    return null;
}

/// The first class-body declaration of a member symbol, as a `BaseMember`.
/// Null when the symbol has none (it came from a merged `interface` block).
/// Called with the symbol's file already entered.
///
/// A constructor PARAMETER PROPERTY (`constructor(public a: string)`) counts
/// as a field: tsc gives it a `SymbolFlags.Property` symbol whose
/// `valueDeclaration` is the parameter, and the base constructor assigns it,
/// so a derived uninitialized redeclaration overwrites it exactly as it would
/// a field. (`checkInstanceSideExtends` excludes parameter properties on the
/// DERIVED side for the opposite reason — tsc walks derived member nodes
/// there, and a parameter is not one.)
fn memberDeclKind(c: *Checker, msym: SymbolId) ?BaseMember {
    for (c.declsOf(msym)) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .class_field => return .{ .is_field = true, .flags = c.tree.extraData(ast.Field, d.lhs).flags },
            .class_method => return .{ .is_field = false, .flags = c.tree.extraData(ast.FnProto, d.lhs).flags },
            .param_full => return .{ .is_field = true, .flags = c.tree.extraData(ast.ParamFull, d.rhs).flags },
            else => {},
        }
    }
    return null;
}
