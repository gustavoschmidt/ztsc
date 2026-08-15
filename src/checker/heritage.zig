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
    // Everything below — the type-parameter list, the heritage re-walk, one
    // relation per base — costs something, and for the overwhelming majority
    // of interfaces the answer is a foregone "yes, it extends it". Two cheap
    // screens decide that without resolving a type: `hasHeritage` (does it
    // extend anything at all?) and `heritageCanConflict`.
    if (!hasHeritage(c, sym)) return;
    if ((try c.interfaceGeneric(sym)) == types.error_type) return;
    if (!try heritageCanConflict(c, sym, node)) return;
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

    const derived = try c.resolveStructural(self);
    for (bases.items) |base| {
        if (!try relatableBase(c, base) or base == self) continue;
        if (try inheritedVerbatim(c, derived, try c.resolveStructural(base))) continue;
        if (try c.isAssignable(self, base)) continue;
        if (try untrustworthyOverride(c, sym, base, &own)) continue;
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

/// Could this interface's heritage produce a diagnostic at all? A cheap
/// screen, run before anything resolves a type.
///
/// `interfaceGeneric` builds the interface by folding each base's members in
/// and letting the declared ones win. If no declared name collides with a base
/// member, and no two bases share a name, then every base survives the fold
/// verbatim: the interface extends each of them by construction (no TS2430)
/// and no two of them disagree (no TS2320). The heritage clauses then never
/// have to be resolved a second time.
///
/// That matters because re-resolving them is not cheap: `typeFromTypeName`
/// runs `fixTypeArgs` (type-parameter list, defaults, arity) and interns a
/// fresh reference for every clause and every written type argument. Measured
/// on `@types/react`, `zod` and `rxjs`, doing it for every interface cost
/// 13-20% of check CPU; resolving the base NAME to a symbol - all this screen
/// does - costs nothing measurable, and the property NAMES it then reads come
/// off objects the fold already built.
///
/// Everything the screen cannot rule out returns true and pays full price:
///
///   * an interface written as more than one block, or merged with a `class`
///     that has its own `extends` - its declarations may live in other files,
///     so this file's tree cannot read them;
///   * a base written as a qualified name, or one that does not resolve to a
///     class or interface (an alias, an import, `Array<T>`) - its member set
///     is not readable this way;
///   * a base carrying call, construct or index signatures - the fold unions
///     or drops overloads, and an index signature constrains members the
///     derived adds, so "contains it verbatim" is no longer the whole story;
///   * a name two bases share, or one the interface declares itself - the
///     only two ways the fold can drop something. This is the common decline
///     (292 of 372 on `@types/react`) and it is the case with real work to do.
///
/// Property NAMES are instantiation-independent (an interface has no mapped
/// members), so the uninstantiated base is the right thing to ask.
fn heritageCanConflict(c: *Checker, sym: SymbolId, node: Node) Error!bool {
    if (!soleInterfaceBlock(c, sym, node)) return true;
    const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(node).lhs);

    var own: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer own.deinit(c.scratch());
    try ownMemberNames(c, sym, &own);
    // Names an earlier base already contributed. Scratch-lived, one interface.
    var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer seen.deinit(c.scratch());

    // The clauses are resolved in THIS declaration's scope, exactly as
    // `interfaceHeritageTypes` would; `soleInterfaceBlock` guarantees there is
    // no other one.
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    for (c.tree.extraRange(data.extends_start, data.extends_end)) |h| {
        if (h == null_node or c.nodeTag(h) != .heritage) continue;
        const name_node = c.tree.nodeData(h).lhs;
        if (c.nodeTag(name_node) != .identifier) return true;
        // `resolveSpace` already answers with a GLOBAL symbol id (see
        // `typeFromTypeNameEx`, which uses it unmapped).
        const base_sym = switch (c.resolveSpace(try c.atomOfToken(c.tree.nodeMainToken(name_node)), c.cur_scope, false)) {
            .sym => |bs| bs,
            else => return true,
        };
        const f = c.symFlags(base_sym);
        // An import binding has to be followed to its target before its
        // members are readable; that is `typeFromTypeNameEx`'s job, not this
        // screen's.
        if (f.import_binding) return true;
        const base = if (f.interface)
            try c.interfaceGeneric(base_sym)
        else if (f.class)
            try c.classInstanceGeneric(base_sym)
        else
            return true;
        const r = try c.resolveStructural(base);
        if (c.ts.kind(r) != .object) return true;
        if (c.ts.objectCallSigCount(r) != 0 or c.ts.objectConstructSigCount(r) != 0) return true;
        if (c.ts.objectStringIndex(r) != types.no_type or c.ts.objectNumberIndex(r) != types.no_type) return true;
        for (0..c.ts.objectPropCount(r)) |i| {
            const name = c.ts.objectProp(r, @intCast(i)).name;
            if (own.contains(name)) return true;
            const gop = try seen.getOrPut(c.scratch(), name);
            if (gop.found_existing) return true;
        }
    }
    return false;
}

/// Is `node` - the declaration being checked, and by `isFirstInterfaceDecl`
/// the symbol's first - the symbol's ONLY `interface` block, with no merged
/// `class` half carrying its own `extends`? Then every heritage clause the
/// symbol has is written in this node, in this file's tree and this node's
/// scope, which is what lets the screen read them syntactically.
fn soleInterfaceBlock(c: *Checker, sym: SymbolId, node: Node) bool {
    for (c.declsOf(sym)) |decl| {
        switch (c.nodeTag(decl)) {
            .interface_decl => if (decl != node) return false,
            .class_decl => {
                if (c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs).extends != 0) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Did the interface inherit this base UNCHANGED? Then it extends it, and no
/// relation has to run to find that out.
///
/// A base whose every property survives the fold at the identical TypeId and
/// identical flags is present in the result verbatim - nothing was shadowed by
/// an own member, and nothing was shadowed by an earlier base. A type that
/// literally contains another's members relates to it trivially.
///
/// `heritageCanConflict` answers the same question more cheaply for the
/// interfaces it can read syntactically; this is the fallback for the ones it
/// cannot (a reopened block, a qualified base name).
///
/// Bases carrying call or construct signatures fall through to the relation:
/// `mergeBaseObjectPlain` may union or drop overloads, so their presence in
/// the result is not the same simple fact.
fn inheritedVerbatim(c: *Checker, derived: TypeId, base: TypeId) Error!bool {
    if (c.ts.kind(derived) != .object or c.ts.kind(base) != .object) return false;
    if (c.ts.objectCallSigCount(base) != 0 or c.ts.objectConstructSigCount(base) != 0) return false;
    const si = c.ts.objectStringIndex(base);
    if (si != types.no_type and c.ts.objectStringIndex(derived) != si) return false;
    const ni = c.ts.objectNumberIndex(base);
    if (ni != types.no_type and c.ts.objectNumberIndex(derived) != ni) return false;
    for (0..c.ts.objectPropCount(base)) |i| {
        const p = c.ts.objectProp(base, @intCast(i));
        const d = c.ts.objectPropByName(derived, p.name) orelse return false;
        if (d.ty != p.ty or d.flags != p.flags) return false;
    }
    return true;
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

/// The relation just said this interface does NOT extend its base. Is that
/// verdict trustworthy? One override shape says no, and the check declines
/// rather than report a TS2430 tsc does not.
///
/// (A second arm used to sit here: an own member with a GENERIC signature the
/// base does not have, declined because ztsc's relation erased such a source's
/// type parameters to their constraints instead of instantiating it in the
/// target's context. `genericSourceRelatesByInference` now does the
/// instantiation for a generic target too — and compares un-erased — so the
/// arm's own "removing it is the observable test" is satisfied and it is
/// gone: `callSignatureAssignabilityInInheritance3`,
/// `constructSignatureAssignabilityInInheritance3` and
/// `subtypingWithConstructSignatures6` report again, while
/// `deeplyNestedCheck.ts`'s `child<U extends Extract<keyof T, string>>(path: U)`
/// against `child(path: string)` stays silent because the inference now solves
/// `U := string`.)
///
/// What remains is an own member written with METHOD syntax that redeclares a
/// base member. tsc relates methods BIVARIANTLY — `strictFunctionTypes` exempts
/// them, so a redeclaration only has to relate in one direction, either one.
/// ztsc applies the exemption inside its signature relation but loses it where
/// the member is reached through the optional form (`m?(…)`, stored as
/// `((…) => …) | undefined`) and the two `this` parameters name classes its
/// model does not relate. `@types/node`'s
/// `DuplexOptions.construct?(this: Duplex, …)` over
/// `WritableOptions.construct?(this: Writable, …)` is both at once, and it
/// reported a TS2430 tsc does not.
///
/// The test is syntactic on purpose: what it needs is how the member was
/// WRITTEN (method versus property-with-a-function-type), which is exactly the
/// distinction tsc's bivariance rule keys on and which the resolved type no
/// longer carries. Property-written members (`a: (x: T) => T`) are unaffected,
/// which is what keeps the `subtypingWith…` and
/// `callSignatureAssignabilityInInheritance` families reporting.
///
/// Removing it is the observable test that the bivariance gap is fixed.
fn untrustworthyOverride(
    c: *Checker,
    sym: SymbolId,
    base: TypeId,
    own: *const std.AutoHashMapUnmanaged(Atom, void),
) Error!bool {
    if (own.count() == 0) return false;
    const rb = try c.resolveStructural(base);
    if (c.ts.kind(rb) != .object) return false;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .method_signature) continue;
            const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs);
            const name = try c.memberKey(c.tree.nodeMainToken(m), proto.flags);
            if (c.ts.objectPropByName(rb, name) != null) return true;
        }
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
    // For an OPTIONAL property, `undefined` is part of what tsc reads out of
    // the symbol (`getTypeOfSymbol` adds it under `strictNullChecks`), but
    // ztsc's representations disagree about whether it is spelled in the
    // stored type: a mapped `Partial<T>` leaves `port: number` and sets the
    // flag, while a written `port?: number | undefined` stores the union. The
    // two describe the same property, so the flag decides and `undefined` is
    // normalized away on both sides before comparing. Without this,
    // `@types/node`'s `https.AgentOptions extends http.AgentOptions,
    // tls.ConnectionOptions` reported a TS2320 tsc does not.
    const at = if (a.optional()) try c.removeUndefined(a.ty) else a.ty;
    const bt = if (b.optional()) try c.removeUndefined(b.ty) else b.ty;
    if (at == bt) return true;
    return (try c.isAssignable(at, bt)) and (try c.isAssignable(bt, at));
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
