//! Destructuring: what a binding pattern gives each name it binds.
//!
//! One walk (`findBindingType`) answers it for every form — object and array
//! patterns, nested patterns, defaults, and both rests — and everything else
//! here feeds it: the pins that publish those types onto the parameter's
//! symbols, the flow key that lets a destructured binding inherit the
//! narrowing of the property it came from, and the `Omit`-shaped rest type.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const accessibility = @import("accessibility.zig");
const PathElem = @import("flow.zig").PathElem;
const RefKey = @import("flow.zig").RefKey;
const containsAtom = @import("expr.zig").containsAtom;
const markSpeculativePin = @import("signatures.zig").markSpeculativePin;
const max_deep_ref_depth = @import("flow.zig").max_deep_ref_depth;

/// Pin every symbol bound by a destructured parameter's pattern to the type
/// the parameter (contextual or annotated) gives it. The counterpart of the
/// named-parameter pin in `signatureOfProtoCtx`: without it those symbols
/// have no pinned type and `computeTypeOfSymbol` re-derives them from the
/// declaration alone, with no contextual signature to read.
///
/// Each binding's type comes from `bindingElementType`, the same walk
/// `computeTypeOfSymbol` would use, so optional properties, defaults, and
/// object/array rests behave identically — only the starting `whole` is
/// better. `force` mirrors the named case: a contextual signature
/// overwrites, because the same arrow is materialized once per overload
/// candidate and the last materialization is the one the body is checked
/// under.
pub fn pinPatternParamSyms(c: *Checker, pn: Node, pat: Node, whole: TypeId, force: bool) Error!void {
    if (pat == null_node) return;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .identifier => try c.pinBindingSym(pn, try c.atomOfToken(c.tree.nodeMainToken(pat)), whole, force),
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    .binding_property => {
                        if (ed.lhs != 0) {
                            try c.pinPatternParamSyms(pn, ed.lhs, whole, force);
                        } else {
                            try c.pinBindingSym(pn, try c.memberAtom(c.tree.nodeMainToken(el)), whole, force);
                        }
                    },
                    .rest_element => try c.pinPatternParamSyms(pn, ed.lhs, whole, force),
                    else => {},
                }
            }
        },
        .array_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node or c.nodeTag(el) == .omitted) continue;
                try c.pinPatternParamSyms(pn, el, whole, force);
            }
        },
        .binding_default, .rest_element => try c.pinPatternParamSyms(pn, d.lhs, whole, force),
        else => {},
    }
}

pub fn pinBindingSym(c: *Checker, pn: Node, name: Atom, whole: TypeId, force: bool) Error!void {
    const psym = c.bind.lookupInScope(c.cur_scope, name) orelse return;
    if (!c.bind.symbol_flags[psym].param) return;
    const gsym = c.toGlobal(psym);
    if (gsym == binder.no_symbol or gsym >= c.sym_types.items.len) return;
    if (!force and c.sym_state.items[gsym] == .computed) return;
    // Re-entrancy: `bindingElementType` checks the pattern's defaults, which
    // can read this very symbol. Leave the slot alone while computing.
    if (c.sym_state.items[gsym] == .in_progress) return;
    const saved = c.sym_state.items[gsym];
    c.sym_state.items[gsym] = .in_progress;
    const t = c.bindingElementType(gsym, pn, whole) catch |err| {
        c.sym_state.items[gsym] = saved;
        return err;
    };
    c.sym_types.items[gsym] = t;
    c.sym_state.items[gsym] = .computed;
    markSpeculativePin(c, gsym);
}

/// Type of `sym` when bound by a destructuring pattern whose whole
/// value has type `whole`: walk the pattern to the binding position.
pub fn bindingElementType(c: *Checker, sym: SymbolId, decl: Node, whole: TypeId) Error!TypeId {
    const d = c.tree.nodeData(decl);
    const pattern: Node = switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full, .param, .param_full => d.lhs,
        else => decl,
    };
    const name = c.symNameAtom(sym);
    const bf = try c.bindingFlowBase(sym, decl);
    return (try c.findBindingType(pattern, name, whole, bf)) orelse types.any_type;
}

/// A destructured binding inherits the NARROWING of the property it comes
/// from: `const { multiElement } = this.state` inside `if
/// (this.state.multiElement)` binds the narrowed, non-null type. tsc builds
/// a synthetic `<initializer>["prop"]` element access carrying the
/// declaration's flow node and asks `getFlowTypeOfReference` about it
/// (`getFlowTypeOfDestructuring`); the equivalent here is to extend the
/// initializer's reference key by each pattern link and query the flow graph
/// at the declaration.
///
/// Only when the initializer is itself a tracked reference and the
/// declaration lives in the file being checked — a cross-file symbol is
/// never flow-narrowed, and its flow ids belong to another graph.
pub const BindFlow = struct { node: Node, key: RefKey };

pub fn bindingFlowBase(c: *Checker, sym: SymbolId, decl: Node) Error!?BindFlow {
    if (c.symFile(sym) != c.cur_file) return null;
    const d = c.tree.nodeData(decl);
    const init_node: Node = switch (c.nodeTag(decl)) {
        .declarator_init => d.rhs,
        .declarator_full => c.tree.extraData(ast.DeclaratorFull, d.rhs).init,
        else => return null,
    };
    if (init_node == null_node) return null;
    const key = (try c.buildRefKey(init_node)) orelse return null;
    return .{ .node = init_node, .key = key };
}

/// The reference key one pattern link deeper, or null when the path would
/// exceed the tracked depth (sound under-narrowing).
pub fn extendRefKey(c: *Checker, base: RefKey, elem: PathElem) Error!?RefKey {
    if (base.len >= max_deep_ref_depth) return null;
    var elems: [max_deep_ref_depth]PathElem = undefined;
    var buf: [max_deep_ref_depth]PathElem = undefined;
    const path = c.refPath(&base, &buf);
    @memcpy(elems[0..path.len], path);
    elems[path.len] = elem;
    return c.makeRefKey(base.sym, elems[0 .. path.len + 1]);
}

/// The type `name` receives when the pattern `pat` destructures a value of
/// type `whole` — null when the pattern binds no such name.
pub fn findBindingType(c: *Checker, pat: Node, name: Atom, whole: TypeId, bf: ?BindFlow) Error!?TypeId {
    if (pat == null_node) return null;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .identifier => {
            if ((try c.atomOfToken(c.tree.nodeMainToken(pat))) == name) return whole;
            return null;
        },
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    .binding_property => {
                        const key = try c.memberAtom(c.tree.nodeMainToken(el));
                        var pt: TypeId = types.any_type;
                        if (try c.propOfType(try c.resolveStructural(whole), key)) |p| {
                            pt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
                        }
                        // Inherit the narrowing of `<initializer>.key` at the
                        // declaration (see `bindingFlowBase`).
                        var sub_bf: ?BindFlow = null;
                        if (bf) |b| {
                            if (PathElem.memberFits(key)) {
                                if (try c.extendRefKey(b.key, .member(key))) |k| {
                                    pt = try c.flowTypeOfKey(b.node, k, pt);
                                    sub_bf = .{ .node = b.node, .key = k };
                                }
                            }
                        }
                        if (ed.rhs != 0) pt = try c.removeUndefined(pt); // default strips undefined
                        if (ed.lhs != 0) {
                            if (try c.findBindingType(ed.lhs, name, pt, sub_bf)) |t| return t;
                        } else if (key == name) {
                            return pt;
                        }
                    },
                    .binding_property_computed => {
                        // `{[k]: v}` → `v: whole[typeof k]` (tsc's
                        // `getIndexedAccessType` over the computed key). A
                        // non-literal key lands on the index signature, which
                        // is what `Record<string, T>` destructuring wants.
                        var pt: TypeId = types.any_type;
                        if (ed.lhs != 0) {
                            const kt = try c.checkExprCached(ed.lhs, types.no_type);
                            pt = try c.indexedAccessType(try c.resolveStructural(whole), kt);
                        }
                        if (try c.findBindingType(ed.rhs, name, pt, null)) |t| return t;
                    },
                    .rest_element => {
                        // `{a, b, ...rest}` → rest = `whole` minus the
                        // sibling-named keys (tsc's object rest type,
                        // `Omit<whole, "a"|"b">`). Binding it to the whole
                        // object wrongly kept the destructured props, which
                        // then read as duplicated by a later spread (TS2783).
                        const rest_ty = try c.objectRestType(whole, pat);
                        if (try c.findBindingType(ed.lhs, name, rest_ty, null)) |t| return t;
                    },
                    else => {},
                }
            }
            return null;
        },
        .array_pattern => {
            const r = try c.resolveStructural(whole);
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted) continue;
                var et: TypeId = types.any_type;
                switch (c.ts.kind(r)) {
                    .array => et = c.ts.arrayElem(r),
                    .tuple => {
                        if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                    },
                    else => {},
                }
                if (c.nodeTag(el) == .rest_element) {
                    const ed = c.tree.nodeData(el);
                    const rest_t = try c.ts.makeArray(et);
                    if (try c.findBindingType(ed.lhs, name, rest_t, null)) |t| return t;
                } else if (c.nodeTag(el) == .binding_default) {
                    const ed = c.tree.nodeData(el);
                    if (try c.findBindingType(ed.lhs, name, try c.removeUndefined(et), null)) |t| return t;
                } else {
                    if (try c.findBindingType(el, name, et, null)) |t| return t;
                }
            }
            return null;
        },
        .binding_default => return c.findBindingType(d.lhs, name, whole, bf),
        .rest_element => return c.findBindingType(d.lhs, name, whole, null),
        else => return null,
    }
}

/// Object binding-pattern rest type: `whole` with every key named by a
/// sibling `binding_property` in `pat` removed (tsc's `{a, ...rest}` →
/// `rest = Omit<whole, "a">`), and every UNSPREADABLE member dropped as well
/// (`types.Prop.spreadable`). Objects and intersections of objects are
/// filtered (index signatures preserved); anything else (unions, generics,
/// `any`) falls back to `whole` unchanged — lenient, matching how the rest
/// of the checker treats non-enumerable shapes.
pub fn objectRestType(c: *Checker, whole: TypeId, pat: Node) Error!TypeId {
    const r = try c.resolveStructural(whole);
    const kind = c.ts.kind(r);
    if (kind != .object and kind != .intersection) return whole;

    var excluded: std.ArrayList(Atom) = .empty;
    defer excluded.deinit(c.scratch());
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        if (c.nodeTag(el) == .binding_property) {
            try excluded.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(el)));
        }
    }

    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var sidx: TypeId = 0;
    var nidx: TypeId = 0;
    // Flatten one level: a plain object contributes its own props; an
    // intersection contributes each object member's props (later members
    // win on a name clash, mirroring intersection member order). A member
    // that is not a plain object makes the shape non-enumerable → bail to
    // `whole` rather than drop constraints.
    const members: []const TypeId = if (kind == .intersection) try c.memberList(r) else &.{r};
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        if (c.ts.kind(rm) != .object) return whole;
        if (c.ts.objectStringIndex(rm) != 0) sidx = c.ts.objectStringIndex(rm);
        if (c.ts.objectNumberIndex(rm) != 0) nidx = c.ts.objectNumberIndex(rm);
        for (0..c.ts.objectPropCount(rm)) |i| {
            const p = c.ts.objectProp(rm, @intCast(i));
            if (containsAtom(excluded.items, p.name)) continue;
            // tsc's `getRestType` copies only SPREADABLE members: a
            // `private`/`protected` field and a class-declared method or
            // accessor both stay behind (the latter lives on the prototype).
            // Reading one off the rest object is TS2339 —
            // `destructuringUnspreadableIntoRest`.
            if (!p.spreadable()) continue;
            var replaced = false;
            for (props.items) |*existing| {
                if (existing.name == p.name) {
                    existing.* = p;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try props.append(c.scratch(), p);
        }
    }
    return c.ts.makeObject(props.items, sidx, nidx, 0);
}

// =====================================================================
// binding-pattern defaults seen from the initializer's side
// =====================================================================

/// Mark optional every property of `t` that the object binding pattern
/// `pat` destructures WITH A DEFAULT.
///
/// tsc arrives here from the other side: the initializer of a
/// binding-pattern declaration is contextually typed by the pattern's
/// implied type — in which a destructured-with-default name is optional —
/// and `checkObjectLiteral`'s `contextualTypeHasPattern` branch copies that
/// `Optional` flag onto each matching literal property. The part of that
/// which the parameter's *type* depends on is exactly this flag transfer,
/// so it is done directly. (The other half of tsc's branch, TS2353 for an
/// initializer property the pattern does not name, is a separate
/// diagnostic and is not synthesized here.)
///
/// Only a plain object type is rewritten: an initializer that is not an
/// object literal (a union, a callable) keeps whatever it has.
pub fn optionalizePatternDefaults(c: *Checker, t: TypeId, pat: Node) Error!TypeId {
    if (pat == null_node or c.nodeTag(pat) != .object_pattern) return t;
    if (c.ts.kind(t) != .object) return t;
    if (c.ts.objectCallSigCount(t) != 0 or c.ts.objectConstructSigCount(t) != 0) return t;
    const n = c.ts.objectPropCount(t);
    if (n == 0) return t;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var changed = false;
    for (0..n) |i| {
        var p = c.ts.objectProp(t, @intCast(i));
        if (p.flags & types.prop_flag_optional == 0 and try c.patternDefaultsProp(pat, p.name)) {
            p.flags |= types.prop_flag_optional;
            changed = true;
        }
        try props.append(c.scratch(), p);
    }
    if (!changed) return t;
    return c.ts.makeObject(props.items, c.ts.objectStringIndex(t), c.ts.objectNumberIndex(t), c.ts.objectFlags(t));
}

/// Does the object binding pattern `pat` destructure `name` with a default?
pub fn patternDefaultsProp(c: *Checker, pat: Node, name: Atom) Error!bool {
    const el = (try patternMemberElem(c, pat, .binding, name)) orelse return false;
    return c.tree.nodeData(el).rhs != 0;
}

/// Which spelling of an object pattern a member walk is looking at.
///
///   * `.binding` — a real binding pattern (`var { x } = …`, a parameter, a
///     `for…of` head): `object_pattern` of `binding_property` elements, and
///     what each names is a fresh symbol, so the pattern implies nothing
///     about its type (tsc's `getTypeFromObjectBindingPattern` gives every
///     member `any`).
///   * `.assignment` — the cover-grammar assignment pattern (`({ x } = …)`),
///     which the parser keeps as an `object_literal` of `object_shorthand` /
///     `object_property`: each element is a WRITE, so the member's type is
///     the target's own.
///
/// The two reach tsc's `contextualTypeHasPattern` arm by different routes —
/// `getTypeFromObjectBindingPattern` for the first, the `pattern` stamp
/// `checkObjectLiteral` puts on an `inDestructuringPattern` literal for the
/// second — but the arm itself is one piece of code, so this walk is too.
const PatternForm = enum { binding, assignment };

/// Does an element of this spelling of pattern NAME a member (as opposed to a
/// rest element, a hole, or a form the walk does not model)?
fn patternElemNames(tag: ast.Tag, form: PatternForm) bool {
    return switch (form) {
        .binding => tag == .binding_property,
        .assignment => tag == .object_property or tag == .object_shorthand,
    };
}

/// The element of the object pattern `pat` that names `name`, or null when the
/// pattern does not name it. The one scan every "what does this pattern say
/// about `name`?" question goes through.
fn patternMemberElem(c: *Checker, pat: Node, form: PatternForm, name: Atom) Error!?Node {
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node or !patternElemNames(c.nodeTag(el), form)) continue;
        if ((try c.memberAtom(c.tree.nodeMainToken(el))) == name) return el;
    }
    return null;
}

/// The SUB-PATTERN a matched element destructures through — the child a
/// nested object literal initializing it is contextually typed by — or
/// `null_node` when the element binds a plain name.
fn patternElemNested(c: *Checker, el: Node, form: PatternForm) Node {
    const d = c.tree.nodeData(el);
    return switch (form) {
        .binding => d.lhs,
        // A shorthand's `lhs` is the target *identifier*, never a pattern.
        .assignment => if (c.nodeTag(el) == .object_property) d.rhs else null_node,
    };
}

// =====================================================================
// what a pattern demands of the type it destructures
// =====================================================================

/// TS2339/TS2551 for an object binding property the destructured type does
/// not have, and TS2488 for an array binding pattern whose source is not
/// iterable. tsc reaches both from `getBindingElementTypeFromParentType`,
/// which types each element through `getIndexedAccessType(parentType, <the
/// property name>, name)` — the missing-property report is that access's —
/// and an array pattern's elements through
/// `checkIteratedTypeOrElementType(IterationUse.Destructuring, …)`.
///
/// A walk of its own rather than a report inside `findBindingType`: that one
/// answers ONE name's type and is memoized per symbol, so a diagnostic raised
/// there would fire once per bound name — and zero times for a symbol whose
/// type an earlier demand already cached, which makes the report depend on
/// the order demands arrive in. This runs once, from the declaration check.
pub fn checkPatternProps(c: *Checker, pat: Node, whole: TypeId) Error!void {
    if (pat == null_node or whole == types.no_type) return;
    switch (c.nodeTag(pat)) {
        .binding_default => try checkPatternProps(c, c.tree.nodeData(pat).lhs, whole),
        // A TYPE PARAMETER is left alone by the PROPERTY walk. tsc narrows one
        // by its constraint's constituents (`value.kind === "a"` makes `T` read
        // as `T & { a: string }`), ztsc does not — `narrowingDestructuring`'s
        // five pre-existing TS2339s on `value.a` are that gap — so anything
        // this walk concluded about `T` would be about the missing narrowing
        // rather than about the pattern.
        .object_pattern => if (c.ts.kind(whole) != .type_param)
            try checkObjectPatternProps(c, pat, whole),
        // The ITERABILITY walk has no such excuse: narrowing `T` to
        // `T & { kind: "a" }` cannot add a `[Symbol.iterator]` the constraint
        // did not have, so the answer for `T` is the answer for its apparent
        // type either way — which is exactly what tsc asks
        // (`checkIteratedTypeOrElementType` runs on `getApparentType`).
        .array_pattern => try checkArrayPatternProps(c, pat, whole),
        else => {},
    }
}

/// A source nothing can be missing from: `any` and the error type (tsc's
/// `isTypeAny(parentType)` early return), plus the absent type, which is what
/// a base this checker could not resolve leaves behind.
fn patternSourceOpaque(c: *Checker, r: TypeId) bool {
    return switch (c.ts.kind(r)) {
        .any, .err, .none => true,
        else => false,
    };
}

fn checkObjectPatternProps(c: *Checker, pat: Node, whole: TypeId) Error!void {
    const r = try c.resolveStructural(whole);
    if (patternSourceOpaque(c, r)) return;
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        if (c.nodeTag(el) == .binding_property_computed) {
            try checkComputedPatternProp(c, el, whole, r);
            continue;
        }
        if (c.nodeTag(el) != .binding_property) continue;
        const key_tok = c.tree.nodeMainToken(el);
        const key = try c.memberAtom(key_tok);
        const p = (try c.propOfType(r, key)) orelse {
            // A DEFAULT makes the property optional to begin with: tsc passes
            // `AccessFlags.AllowMissing` for `hasDefaultValue(declaration)`,
            // which is what keeps `var { x = 1 } = {}` clean.
            if (c.tree.nodeData(el).rhs != 0) continue;
            // A NUMERIC-looking name reaches the number index signature (and a
            // tuple/array element) as well — `isApplicableIndexType`'s
            // numeric-name disjunct, the same one the `o["0"]` read takes. It
            // is what makes `var [...{ 0: a }] = [0, 1]` clean.
            if (try c.numericNameIndexHit(r, c.ts.kind(r), c.atomText(key)) != null) continue;
            // In a union, a constituent that was WRITTEN as an object literal
            // and lacks the property contributes `undefined` instead of making
            // the property unreadable — tsc's `createUnionOrIntersection-
            // Property` marks that case `WritePartial`, not `ReadPartial`. It
            // is what makes `let { color } = options || {}` clean while the
            // same union spelled out in a type annotation stays TS2339.
            if (try unionLiteralConstituentLacks(c, r, key)) continue;
            // tsc's `getSuggestionForNonexistentProperty` runs here too, so a
            // near-miss is TS2551 exactly as it is on a dotted read.
            if (c.suggestProp(key, r)) |sugg| {
                try c.diagFmt(2551, c.tokSpan(key_tok), "Property '{s}' does not exist on type '{s}'. Did you mean '{s}'?", .{
                    c.atomText(key), try c.typeToString(whole), c.atomText(sugg),
                });
            } else {
                try c.diagFmt(2339, c.tokSpan(key_tok), "Property '{s}' does not exist on type '{s}'.", .{
                    c.atomText(key), try c.typeToString(whole),
                });
            }
            continue;
        };
        // Reading a property through a pattern is an ACCESS, so the
        // accessibility rules apply exactly as they do to `o.p`: tsc types
        // every binding element through `getIndexedAccessType(parentType, …,
        // name)`, whose `checkPropertyAccessibility` is the same one a dotted
        // read takes. Without it `const { p } = new C()` read a `private p`
        // silently.
        if (p.nonPublic()) {
            try accessibility.check(c, whole, key, key_tok, .{ .dir = .read });
        }
        // A nested pattern destructures the property's own type — with nullish
        // stripped first, because a possibly-undefined intermediate is tsc's
        // TS2532 (the access's own diagnostic), not a missing property, and
        // `never` has no member to be missing.
        const sub = c.tree.nodeData(el).lhs;
        if (sub == 0) continue;
        var pt = p.ty;
        if (c.containsNullish(pt)) pt = try c.nonNullable(pt);
        if (c.ts.kind(pt) == .never) continue;
        try checkPatternProps(c, sub, pt);
    }
}

/// A `{ [k]: v }` binding element: the accessibility of the property its key
/// LATE-BINDS to. `const { ["p"]: v } = new C()` reads `C`'s `private p` just
/// as `const { p: v }` does, and tsc reports it from the same
/// `getIndexedAccessType` — the key node is the anchor (`main_token` is its
/// `[`).
///
/// Only the accessibility half: a computed key that names nothing static
/// legitimately lands on an index signature (`Record<string, T>`
/// destructuring), so there is no missing-property verdict to make here.
/// `whole` is the source type AS WRITTEN and `r` its resolved structure: the
/// first is what names the declaring class for `accessibility.check`, the
/// second is what carries the property.
fn checkComputedPatternProp(c: *Checker, el: Node, whole: TypeId, r: TypeId) Error!void {
    const key_expr = c.tree.nodeData(el).lhs;
    if (key_expr == null_node) return;
    const kt = try c.checkExprCached(key_expr, types.no_type);
    const key = (try c.uniqueSymAtom(kt)) orelse (try c.literalKeyAtom(kt)) orelse return;
    const p = (try c.propOfType(r, key)) orelse return;
    if (!p.nonPublic()) return;
    try accessibility.check(c, whole, key, c.tree.nodeMainToken(el), .{ .dir = .read });
}

/// Does a union constituent that was written as an OBJECT LITERAL lack `name`?
/// That is the `WritePartial` half of tsc's `createUnionOrIntersectionProperty`
/// — the missing member reads as `undefined` rather than as absent — so the
/// property is readable and nothing is reported. False for anything that is
/// not a union, and for a union whose lacking constituents are all declared
/// shapes (which is `ReadPartial`, i.e. genuinely absent).
fn unionLiteralConstituentLacks(c: *Checker, r: TypeId, name: Atom) Error!bool {
    if (c.ts.kind(r) != .union_type) return false;
    for (try c.memberList(r)) |m| {
        const rm = try c.resolveStructural(m);
        if (!c.ts.objectIsLiteralOrigin(rm)) continue;
        if ((try c.propOfType(rm, name)) == null) return true;
    }
    return false;
}

fn checkArrayPatternProps(c: *Checker, pat: Node, whole: TypeId) Error!void {
    const r = try c.resolveStructural(whole);
    if (patternSourceOpaque(c, r)) return;
    const elem = (try c.iterationElementType(r)) orelse {
        try c.diagFmt(2488, c.nodeSpan(pat), "Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{
            try c.typeToString(whole),
        });
        return;
    };
    var i: u32 = 0;
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        defer i += 1;
        if (c.nodeTag(el) == .omitted) continue;
        if (c.nodeTag(el) == .rest_element) {
            // `[...{ 0: a, b }]` destructures the REST array, so the nested
            // pattern's source is `E[]`, not `E`.
            try checkPatternProps(c, c.tree.nodeData(el).lhs, try c.ts.makeArray(elem));
            continue;
        }
        // Only a TUPLE source gives an element position its own exact type. An
        // ARRAY source is what an array literal widens to here, whereas tsc
        // contextually types that literal by the pattern's implied TUPLE
        // (`getTypeFromArrayBindingPattern`) and so sees each position
        // separately — descending with the widened element UNION instead would
        // report a property missing from a sibling's type
        // (`destructuringVariableDeclaration2`). Left to the day the pattern's
        // implied type becomes a real contextual type.
        if (c.ts.kind(r) != .tuple) continue;
        if (i >= c.ts.tupleLen(r)) continue;
        try checkPatternProps(c, el, c.ts.tupleElem(r, i).ty);
    }
}

/// The checks above driven from a DECLARATION whose name is a binding
/// pattern. The destructured type is the annotation when there is one and the
/// initializer's type otherwise — the same `whole` `declaratorType` hands
/// `bindingElementType`. `fallback` is what a declaration with neither
/// destructures: `unknown` for a catch parameter, and `no_type` (i.e. no
/// check) for a bare `var [a]`, whose leaves are implicit `any`.
pub fn checkDeclPattern(c: *Checker, decl: Node, fallback: TypeId) Error!void {
    if (decl == null_node) return;
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full => {},
        else => return,
    }
    const pat = d.lhs;
    // Nothing to demand of a plain name — and asking for the source type of one
    // is not free: a `unique symbol` annotation is legal only on an identifier
    // name, and reading it here rather than through `annTypeMaybeUnique` files
    // TS1335 on every one of them.
    switch (c.nodeTag(pat)) {
        .object_pattern, .array_pattern => {},
        else => return,
    }
    var init_node: Node = null_node;
    const src: TypeId = switch (c.nodeTag(decl)) {
        .declarator => fallback,
        .declarator_init => blk: {
            init_node = d.rhs;
            break :blk try c.checkExprCached(d.rhs, types.no_type);
        },
        else => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann != 0) break :blk try c.typeFromTypeNode(e.type_ann);
            if (e.init == 0) break :blk fallback;
            init_node = e.init;
            break :blk try c.checkExprCached(e.init, types.no_type);
        },
    };
    try checkPatternProps(c, pat, src);
    // The excess half only applies when the PATTERN is the literal's
    // contextual type, i.e. when the declaration carries no annotation.
    if (init_node != null_node and src != types.no_type) try checkPatternExcessProps(c, pat, .binding, init_node);
}

/// The same arm for a destructuring ASSIGNMENT (`({ x } = { x: 0, y: 0 })`).
/// tsc reaches it through the ordinary contextual-type chain rather than
/// through the declaration: `getContextualTypeForBinaryOperand` answers
/// `getTypeOfExpression(left)` for the right operand of an `=`, and the left
/// operand of a destructuring assignment is an object literal that
/// `checkObjectLiteral` stamped with `pattern` (its `inDestructuringPattern`
/// branch) — so `contextualTypeHasPattern` holds and every member of the
/// right-hand literal the pattern does not name is TS2353.
///
/// The declaration form does NOT go through this chain, which is why the two
/// disagree on an EMPTY pattern: `getContextualTypeForVariableLikeDeclaration`
/// has no VariableDeclaration arm at all, so `var { } = { x: 0 }` has no
/// contextual type and says nothing, while `({ } = { x: 0 })` is contextually
/// typed by `{}` and reports. (`var { x } = { x: 0, y: 0 }` still reports —
/// from `checkVariableLikeDeclaration`'s assignability check against the
/// pattern's implied type, which `checkDeclPattern` above stands in for.)
pub fn checkAssignPatternExcessProps(c: *Checker, pat: Node, init: Node) Error!void {
    try checkPatternExcessProps(c, pat, .assignment, init);
}

/// The other half of tsc's `contextualTypeHasPattern` branch in
/// `checkObjectLiteral` (`optionalizePatternDefaults` is the first): a
/// property of the object literal that INITIALIZES an object binding pattern,
/// and which the pattern does not name, is TS2353 at the literal's key —
/// `getPropertyOfType(contextualType, member.escapedName)` coming up empty
/// with no string index info on the pattern's implied type. Unlike the
/// relation's excess check this one does not bail after the first find: tsc
/// walks every member of the literal here.
fn checkPatternExcessProps(c: *Checker, pat: Node, form: PatternForm, init: Node) Error!void {
    if (pat == null_node or init == null_node) return;
    if (c.nodeTag(init) != .object_literal) return;
    switch (form) {
        .binding => if (c.nodeTag(pat) != .object_pattern) return,
        .assignment => if (c.nodeTag(pat) != .object_literal) return,
    }
    const implied = (try patternImpliedType(c, pat, form)) orelse return;
    for (c.tree.nodeRange(init)) |prop| {
        if (prop == null_node) continue;
        const tag = c.nodeTag(prop);
        switch (tag) {
            .object_property, .object_shorthand, .object_method => {},
            // A spread contributes names this walk cannot enumerate, so the
            // whole literal is left alone rather than guessed at.
            .spread_element => return,
            else => continue,
        }
        const pd = c.tree.nodeData(prop);
        if (tag != .object_shorthand and pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
        const key_tok = c.tree.nodeMainToken(prop);
        const key = try c.memberAtom(key_tok);
        const el = (try patternMemberElem(c, pat, form, key)) orelse {
            try c.diagFmt(2353, c.tokSpan(key_tok), "Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{
                c.atomText(key), try c.typeToString(implied),
            });
            continue;
        };
        // A nested literal is contextually typed by the nested pattern, so
        // the same branch runs one level down.
        if (tag == .object_property) try checkPatternExcessProps(c, patternElemNested(c, el, form), form, pd.rhs);
    }
}

/// The object type an object pattern implies as the contextual type of the
/// literal that initializes it — one member per named property.
///
/// tsc builds it two ways. For a BINDING pattern it is
/// `getTypeFromObjectBindingPattern`: every member is `any`, and optional
/// where the element has a default. For an ASSIGNMENT pattern it is
/// `checkObjectLiteral` on the pattern itself, so every member has the type
/// its WRITE TARGET already has — which is what makes the message read
/// `does not exist in type '{ x: number; }'` there and `'{ x: any; }'` here.
///
/// Null when the pattern names something this walk cannot enumerate — a rest
/// element, whose implied type carries a `[k: string]: any` that absorbs
/// every unnamed property, or a computed key, which sets tsc's
/// `ObjectLiteralPatternWithComputedProperties` and takes the branch out of
/// play. In both cases nothing in the literal is excess.
fn patternImpliedType(c: *Checker, pat: Node, form: PatternForm) Error!?TypeId {
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        const tag = c.nodeTag(el);
        if (!patternElemNames(tag, form)) return null;
        const ed = c.tree.nodeData(el);
        // A computed key in the ASSIGNMENT spelling rides on the property
        // node itself (the binding spelling has its own element tag, already
        // refused above).
        if (tag == .object_property and ed.lhs != 0 and c.nodeTag(ed.lhs) == .computed_name) return null;
        const ty: TypeId = switch (form) {
            .binding => types.any_type,
            // `{ k: target }` writes through `rhs`; a shorthand `{ x }` is its
            // own target, in `lhs`.
            .assignment => (try assignTargetDeclaredType(c, if (tag == .object_property) ed.rhs else ed.lhs)) orelse return null,
        };
        try props.append(c.scratch(), .{
            .name = try c.memberAtom(c.tree.nodeMainToken(el)),
            .ty = ty,
            .flags = if (form == .binding and ed.rhs != 0) types.prop_flag_optional else 0,
        });
    }
    // An EMPTY BINDING pattern implies nothing and contextually types nothing:
    // `getContextualTypeForInitializerExpression` only reaches
    // `getTypeFromBindingPattern` for `elements.length > 0`, so
    // `var { } = { x: 0 }` has no pattern target to be excess against. An
    // empty ASSIGNMENT pattern is an ordinary object literal of type `{}`,
    // and `({ } = { x: 0 })` reports against it.
    if (props.items.len == 0 and form == .binding) return null;
    return try c.ts.makeObject(props.items, 0, 0, 0);
}

/// The type an assignment pattern's element WRITES, read off the target's own
/// declaration rather than by checking the target as an expression — which
/// would re-run every diagnostic `checkDestructuringPattern` already raises
/// for it, and a `let`'s definite-assignment report besides.
///
/// Only the shapes whose type is a symbol's own answer: a bare name, seen
/// through parentheses and its default. Everything else — a property access,
/// a nested pattern — answers null and the excess walk stands down, rather
/// than print a contextual type it guessed at.
fn assignTargetDeclaredType(c: *Checker, target0: Node) Error!?TypeId {
    var t = target0;
    while (t != null_node) {
        switch (c.nodeTag(t)) {
            .paren_expr, .binding_default => t = c.tree.nodeData(t).lhs,
            // `({ x = 1 } = …)`: the cover grammar parses a default as a
            // plain assignment expression.
            .assign => {
                if (c.tree.tokens.tag(c.tree.nodeMainToken(t)) != .eq) return null;
                t = c.tree.nodeData(t).lhs;
            },
            .identifier => {
                const tok = c.tree.nodeMainToken(t);
                if (c.tree.tokens.tag(tok) != .identifier) return null;
                const a = try c.atomOfToken(tok);
                return switch (c.resolveSpace(a, c.cur_scope, true)) {
                    .sym => |sym| try c.typeOfSymbol(sym),
                    else => null,
                };
            },
            else => return null,
        }
    }
    return null;
}
