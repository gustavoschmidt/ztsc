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
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const Span = source.Span;
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
const keyof = @import("keyof.zig");
const markSpeculativePin = @import("signatures.zig").markSpeculativePin;
const max_deep_ref_depth = @import("flow.zig").max_deep_ref_depth;
const subst = @import("subst.zig");

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
                        var pt: TypeId = (try patternPropType(c, whole, key)) orelse types.any_type;
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
                        if (ed.rhs != 0) pt = try defaultedElemType(c, ed.rhs, pt);
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
                const et: TypeId = (try patternElemType(c, r, i)) orelse types.any_type;
                if (c.nodeTag(el) == .rest_element) {
                    const ed = c.tree.nodeData(el);
                    // tsc's `getTypeForBindingElement`: a rest over a TUPLE is
                    // `sliceTupleType(parent, index)` — the remaining positions
                    // with their own flags, not an array of position `index`'s
                    // type. `var [, ...r] = [1, "x", true]` is `[string,
                    // boolean]`; the array reading dropped every position but
                    // the first.
                    const rest_t = if (c.ts.kind(r) == .tuple)
                        try tupleSlice(c, r, i)
                    else
                        try c.ts.makeArray(et);
                    if (try c.findBindingType(ed.lhs, name, rest_t, null)) |t| return t;
                } else if (c.nodeTag(el) == .binding_default) {
                    const ed = c.tree.nodeData(el);
                    if (try c.findBindingType(ed.lhs, name, try defaultedElemType(c, ed.rhs, et), null)) |t| return t;
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

/// What an OBJECT pattern's `key` element destructures out of `whole` — tsc's
/// `getTypeOfPropertyOfType(parentType, name)`, with `undefined` folded in for
/// an optional property. Null when the source has no such property, which is
/// "no answer": `findBindingType` reads that as `any` and continues, while a
/// CONTEXTUAL use reads it as no contextual type at all.
pub fn patternPropType(c: *Checker, whole: TypeId, key: Atom) Error!?TypeId {
    if (whole == types.no_type) return null;
    const p = (try c.propOfType(try c.resolveStructural(whole), key)) orelse return null;
    return if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
}

/// The same for an ARRAY pattern's position `i` of a RESOLVED source `r` —
/// tsc's `getContextualTypeForElementExpression(parentType, index)`. Null for
/// a source that is neither an array nor a tuple.
pub fn patternElemType(c: *Checker, r: TypeId, i: u32) Error!?TypeId {
    return switch (c.ts.kind(r)) {
        .array => c.ts.arrayElem(r),
        .tuple => try tupleBindingElemType(c, r, i),
        else => null,
    };
}

/// What a binding element with a DEFAULT reads, given `et`, what the source
/// gives its position. tsc's `getBindingElementTypeFromParentType` tail is
/// `getUnionType([getNonUndefinedType(type), <the default's own type>])`;
/// ztsc keeps only the source side, which is the same answer whenever the
/// source carries the position at all.
///
/// It is not the same answer when the source carries NOTHING there. An
/// out-of-range tuple position reads `undefined` — tsc accesses it with
/// `AccessFlags.AllowMissing` precisely BECAUSE a default is present, which
/// is also why it is not the TS2493 the undefaulted position gets — and
/// stripping `undefined` off it leaves `never`, a type `var [a, b = 9] = [1]`
/// plainly does not have. Where the source side reduces to `never` the union
/// IS the default's type, so that is what this answers.
fn defaultedElemType(c: *Checker, def: Node, et: TypeId) Error!TypeId {
    const stripped = try c.removeUndefined(et);
    if (def == null_node or c.ts.kind(stripped) != .never) return stripped;
    return c.widenLiteral(try c.checkExprCached(def, types.no_type));
}

/// Position `i` of a TUPLE as a binding element reads it — tsc's
/// `getIndexedAccessTypeOrUndefined(parentType, getNumberLiteralType(index))`.
/// An OPTIONAL position also holds `undefined`, a REST position holds its own
/// element type (its stored type is the array), and a position past the end
/// falls to the tuple's rest element if it has one and to `undefined`
/// otherwise (`getRestTypeOfTupleType(t) || undefinedType`) — the same answer
/// whose report is TS2493.
fn tupleBindingElemType(c: *Checker, r: TypeId, i: u32) Error!TypeId {
    if (i < c.ts.tupleLen(r)) {
        const e = c.ts.tupleElem(r, i);
        if (e.rest()) return (try c.tupleElemTypeAt(r, i)) orelse types.any_type;
        return if (e.optional()) try c.makeUnion2(e.ty, types.undefined_type) else e.ty;
    }
    return (try c.tupleElemTypeAt(r, i)) orelse types.undefined_type;
}

/// tsc's `sliceTupleType(type, index)`: the tuple's positions from `index`
/// on, keeping each one's flags (and the source tuple's readonly-ness).
fn tupleSlice(c: *Checker, r: TypeId, from: u32) Error!TypeId {
    const len = c.ts.tupleLen(r);
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    var i = from;
    while (i < len) : (i += 1) try elems.append(c.scratch(), c.ts.tupleElem(r, i));
    return c.ts.makeTupleLike(r, elems.items);
}

/// Object rest type: `whole` with every key named by a non-rest sibling of
/// `pat` removed (tsc's `{a, ...rest}` → `rest = Omit<whole, "a">`), and every
/// UNSPREADABLE member dropped as well (`types.Prop.spreadable`). Objects and
/// intersections of objects are filtered (index signatures preserved);
/// anything else (unions, generics, `any`) falls back to `whole` unchanged —
/// lenient, matching how the rest of the checker treats non-enumerable shapes.
///
/// `pat` is either a binding pattern (siblings are `binding_property`) or the
/// expression cover grammar an object destructuring ASSIGNMENT parses to
/// (`object_property` / `object_shorthand`) — tsc runs the one `getRestType`
/// for both. An assignment sibling with a COMPUTED key cannot be named
/// statically here; under-excluding it would invent an assignability error at
/// the rest target, so the whole shape falls back to `whole`.
pub fn objectRestType(c: *Checker, whole: TypeId, pat: Node) Error!TypeId {
    const r0 = try c.resolveStructural(whole);
    // tsc's `getRestType` walks `getPropertiesOfType(source)`, which answers
    // for a CLASS VALUE (`const { ...rest } = C`) out of its static side.
    // Leaving `typeof C` untouched instead handed the rest binding every
    // static the class has, including the `#private` ones a spread drops
    // (`privateNameAndObjectRestSpread`).
    const r = if (c.ts.kind(r0) == .class_value)
        try c.classStaticType(c.ts.classSymbol(r0))
    else
        r0;
    const kind = c.ts.kind(r);
    if (kind != .object and kind != .intersection) return whole;

    var excluded: std.ArrayList(Atom) = .empty;
    defer excluded.deinit(c.scratch());
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        switch (c.nodeTag(el)) {
            .binding_property, .object_shorthand => {
                try excluded.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(el)));
            },
            .object_property => {
                const key = c.tree.nodeData(el).lhs;
                if (key != null_node and c.nodeTag(key) == .computed_name) return whole;
                try excluded.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(el)));
            },
            else => {},
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

/// Whether a pattern element's DEFAULT is RELATED to the type of the position
/// it stands in for, or merely typed by it.
///
/// Only a declaration whose type is WRITTEN relates it. When the type is
/// inferred from an initializer instead, `getBindingElementTypeFromParentType`
/// unions the default's own type into the element's — `let { a: v = 1 } = src`
/// binds `string | number` where `let { a: v = 1 }: A = src` binds `string`
/// (oracle-verified) — and the relation is then vacuous by construction: the
/// source of the check is the very type the target just absorbed. So the two
/// spellings differ by one TS2322, and skipping is exactly equivalent to
/// building the union and relating against it.
pub const DefaultCheck = enum { relate, contextual_only };

/// A binding element's DEFAULT: checked under the contextual type of the
/// position it stands in for, then related to that position's declared type.
/// `el` is a `.binding_property` or a `.binding_default`, `pt` the type the
/// element's position destructures (`no_type` when nothing declares it — an
/// unannotated parameter, a `for` head — which is tsc's "no parent type" and
/// reports nothing).
///
/// tsc's `checkVariableLikeDeclaration` tail:
/// `checkTypeAssignableToAndOptionallyElaborate(checkExpressionCached(init),
/// type, node, node.initializer)` — the error node is the ELEMENT, whose
/// span `getErrorSpanForNode` narrows to its NAME, and the initializer is the
/// elaboration root, so a mismatch inside an object/array literal or an arrow
/// body is blamed there instead. `function h({ prop = "baz" }: StringUnion)`
/// reports on `prop`, while `({ prop = [101, 1234] }: Tuples)` reports twice
/// inside the array literal.
///
/// `undefined` comes off the target exactly where tsc takes it off
/// (`getBindingElementTypeFromParentType`): a default is what supplies the
/// missing value, so `{ a = 1 }: { a?: string }` is TS2322 against `string` —
/// unless the default is ITSELF possibly-undefined, in which case the
/// position keeps it and `{ a = undefined }` is clean.
///
/// The same stripped type is what CONTEXTUALLY types the default: tsc's
/// `getContextualTypeForBindingElement` ends in `getTypeOfPropertyOfType`,
/// which answers the property's declared type — an optional property's
/// `undefined` is folded in by the destructuring walk, not by that lookup.
/// A class expression's static members are contextually typed through it
/// (`staticFieldWithInterfaceContext`'s `{ c: c4 = class { static x = { a:
/// "a" } } }: { c?: I }`), and a `I | undefined` context hid that.
pub fn checkPatternDefault(c: *Checker, el: Node, pt: TypeId, mode: DefaultCheck) Error!void {
    const d = c.tree.nodeData(el);
    const declared = if (pt == types.no_type or pt == types.error_type)
        pt
    else
        try c.removeUndefined(pt);
    const it = try c.checkExprCached(d.rhs, defaultContextualType(c, d.lhs, declared));
    if (mode == .contextual_only or pt == types.no_type or pt == types.error_type) return;
    const target = if (c.containsUndefinedish(it)) pt else declared;
    // The element's NAME — for a shorthand `{ a = 1 }` the key token itself,
    // which is where tsc's `BindingElement` error span lands either way.
    const span = if (d.lhs != 0) c.nodeSpan(d.lhs) else c.tokSpan(c.tree.nodeMainToken(el));
    _ = try c.checkAssignable(it, target, d.rhs, span);
}

/// The contextual type of a binding element's DEFAULT: the type its position
/// destructures — except when the element's own name is itself a PATTERN,
/// which tsc's `getContextualTypeForBindingElement` refuses outright
/// (`isBindingPattern(name)` returns `undefined` before the property lookup).
/// The ASSIGNABILITY target above is unaffected: `{ a: { z } = 1 }` is still
/// checked against `{ z: string }`, it just does not type `1` from it.
pub fn defaultContextualType(c: *Checker, name: Node, pt: TypeId) TypeId {
    if (name == null_node) return pt;
    return switch (c.nodeTag(name)) {
        .object_pattern, .array_pattern => types.no_type,
        else => pt,
    };
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
///
/// `has_init` is tsc's `needCheckInitializer` — does the declaration this
/// pattern names carry an initializer (a `var`'s `= x`, a parameter's or a
/// binding element's default)? It decides one thing only, and only for an
/// EMPTY array pattern: see `checkEmptyPatternSource`.
pub fn checkPatternProps(c: *Checker, pat: Node, whole: TypeId, has_init: bool) Error!void {
    if (pat == null_node or whole == types.no_type) return;
    switch (c.nodeTag(pat)) {
        // A default IS the initializer the rule asks about.
        .binding_default => try checkPatternProps(c, c.tree.nodeData(pat).lhs, whole, true),
        // Anything still GENERIC is left alone by the PROPERTY walk. A bare
        // type parameter, because tsc narrows one by its constraint's
        // constituents (`value.kind === "a"` makes `T` read as `T & { a:
        // string }`) and ztsc does not — `narrowingDestructuring`'s five
        // pre-existing TS2339s on `value.a` are that gap. And any type that
        // merely CARRIES one, because tsc's `getIndexedAccessType` defers on
        // it rather than answering: `correlatedUnions`' `{ letter, caller }:
        // LetterCaller<K>` destructures `{ [P in K]: … }[K]`, which has no
        // resolved member table to be missing a property from.
        .object_pattern => {
            try checkEmptyPatternSource(c, pat, whole);
            if (c.ts.kind(whole) != .type_param and !try subst.containsTypeParam(c, whole))
                try checkObjectPatternProps(c, pat, whole);
        },
        // The ITERABILITY walk has no such excuse: narrowing `T` to
        // `T & { kind: "a" }` cannot add a `[Symbol.iterator]` the constraint
        // did not have, so the answer for `T` is the answer for its apparent
        // type either way — which is exactly what tsc asks
        // (`checkIteratedTypeOrElementType` runs on `getApparentType`).
        .array_pattern => {
            // Before the iterability report, as tsc orders them.
            if (has_init) try checkEmptyPatternSource(c, pat, whole);
            try checkArrayPatternProps(c, pat, whole);
        },
        else => {},
    }
}

/// tsc's `checkVariableLikeDeclaration` tail for a binding pattern with NO
/// elements: `checkNonNullNonVoidType(widenedType, node)`. `var { } = x` binds
/// nothing, so no member walk ever touches `x` and nothing else would notice
/// that it cannot be destructured at all — this is the one report the empty
/// pattern earns (TS2571 / TS2531-3, `destructuringVoidStrictNullChecks`).
///
/// The site is the PATTERN, not the declaration: `getErrorSpanForNode` swaps a
/// VariableDeclaration / Parameter / BindingElement for its `name`, and the
/// name here is the pattern. Every caller of `checkPatternProps` is one of
/// those three, so the site is right for all of them.
///
/// An empty ARRAY pattern takes the same report, but only when the declaration
/// has an INITIALIZER: that branch is tsc's `needCheckInitializer` one, and the
/// `needCheckWidenedType` branch below it sends an array pattern to
/// `checkIteratedTypeOrElementType` instead. So `let [] = null` is the TS2488
/// *and* the TS2531, while the annotation-only `function g([]: null) {}` is the
/// TS2488 alone.
fn checkEmptyPatternSource(c: *Checker, pat: Node, whole: TypeId) Error!void {
    if (c.tree.nodeRange(pat).len != 0) return;
    try reportNonNullDestructuringSource(c, c.nodeSpan(pat), whole, true);
}

/// tsc's `checkObjectLiteralAssignment` head: *"if (strictNullChecks &&
/// properties.length === 0) return checkNonNullType(sourceType, node)"* — the
/// ASSIGNMENT spelling of the rule above, for `({ } = x)`.
///
/// `checkNonNullType`, not `checkNonNullNonVoidType`: the assignment form says
/// nothing about a bare `void` source, which is the one way the two spellings
/// disagree (`({} = v)` is silent where `const {} = v` is TS2532).
pub fn checkEmptyAssignPatternSource(c: *Checker, lit: Node, whole: TypeId) Error!void {
    if (whole == types.no_type or c.tree.nodeRange(lit).len != 0) return;
    try reportNonNullDestructuringSource(c, c.nodeSpan(lit), whole, false);
}

/// tsc's `checkNonNullType` / `checkNonNullNonVoidType` for a DESTRUCTURING
/// site, which is never an entity-name expression (it is a binding pattern or
/// an empty object literal) — so the object-shaped codes are the only ones
/// reachable and there is no name to print.
///
/// tsc's steps, in order:
///   1. `unknown` is rejected outright (TS2571) — `catch ({})` lands here.
///   2. the NULLABLE flags (`null` / `undefined`, and NOT `void`) report
///      TS2531-3. `void | null` is TS2531 alone, never also TS2532, because
///      `getNonNullableType` filters `void` out along with the nullables and
///      the `never` that leaves degrades to the error type.
///   3. only `non_void` callers, and only then, report a bare `void` as
///      TS2532. A union that merely CARRIES `void` (`void | { a: 1 }`) says
///      nothing: `getFalsyFlags` finds nothing nullable in it and the union's
///      own flags are not `Void`.
///
/// A type parameter is left alone, like the property walk leaves it alone:
/// `getFalsyFlags` of one is empty and its flags are not `Void`, so tsc says
/// nothing for `function f<T extends void>(t: T) { const {} = t; }` either.
fn reportNonNullDestructuringSource(c: *Checker, span: Span, whole: TypeId, non_void: bool) Error!void {
    if (c.ts.kind(try c.resolveStructural(whole)) == .unknown) {
        try c.diagFmt(2571, span, "Object is of type 'unknown'.", .{});
        return;
    }
    const has_null = c.containsNull(whole);
    const has_undef = c.unionAnyMember(whole, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) == .undefined;
        }
    }.f);
    if (has_null and has_undef) {
        try c.diagFmt(2533, span, "Object is possibly 'null' or 'undefined'.", .{});
    } else if (has_null) {
        try c.diagFmt(2531, span, "Object is possibly 'null'.", .{});
    } else if (has_undef or (non_void and c.ts.kind(whole) == .void)) {
        try c.diagFmt(2532, span, "Object is possibly 'undefined'.", .{});
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
            //
            // `AllowMissing` relaxes a property LOOKUP, though, and a NULLISH
            // constituent has no property table for the lookup to be relaxed
            // against — `getIndexedAccessTypeOrUndefined` still fails on it
            // and names the whole union. `function test({ nested: { p = 'c' }
            // }: { nested?: { p: 'a' | 'b' } })` destructures
            // `{ p: "a" | "b" } | undefined`, and `p` is TS2339 there despite
            // its default (`destructuringParameterDeclaration8`).
            if (c.tree.nodeData(el).rhs != 0 and !c.containsNullish(r)) continue;
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
        // A nested pattern destructures exactly what the element BINDS
        // (`patternPropType`, then the default's `undefined` strip), and a
        // nullish remainder is NOT taken off: tsc types the element through
        // `getIndexedAccessType`, which has no property to find on `undefined`
        // or `null`, so `const { a: { b } } = o` on `{ a?: { b: string } }` is
        // TS2339 naming `{ b: string; } | undefined` — not the TS2532 a dotted
        // `o.a.b` would get. A DEFAULT is what makes it clean, and it does so
        // by supplying the missing value, which is the same strip
        // `defaultedElemType` performs. `never` has no member to be missing.
        const sub = c.tree.nodeData(el).lhs;
        if (sub == 0) continue;
        var pt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        if (c.tree.nodeData(el).rhs != 0) pt = try defaultedElemType(c, c.tree.nodeData(el).rhs, pt);
        if (c.ts.kind(pt) == .never) continue;
        try checkPatternProps(c, sub, pt, c.tree.nodeData(el).rhs != 0);
    }
}

/// A `{ [k]: v }` binding element: the accessibility of the property its key
/// LATE-BINDS to. `const { ["p"]: v } = new C()` reads `C`'s `private p` just
/// as `const { p: v }` does, and tsc reports it from the same
/// `getIndexedAccessType` — the key node is the anchor (`main_token` is its
/// `[`).
///
/// A key that names nothing static must land on an INDEX SIGNATURE, which is
/// the TS2537 half (`Record<string, T>` destructuring is the legitimate
/// shape). `whole` is the source type AS WRITTEN and `r` its resolved
/// structure: the first is what names the declaring class for
/// `accessibility.check` and what the message prints, the second is what
/// carries the property.
fn checkComputedPatternProp(c: *Checker, el: Node, whole: TypeId, r: TypeId) Error!void {
    const key_expr = c.tree.nodeData(el).lhs;
    if (key_expr == null_node) return;
    const kt = try c.checkExprCached(key_expr, types.no_type);
    const key = (try c.uniqueSymAtom(kt)) orelse (try c.literalKeyAtom(kt)) orelse {
        return reportNoMatchingIndex(c, key_expr, whole, r, kt);
    };
    const p = (try c.propOfType(r, key)) orelse return;
    if (!p.nonPublic()) return;
    try accessibility.check(c, whole, key, c.tree.nodeMainToken(el), .{ .dir = .read });
}

/// TS2537 for a binding element whose computed key is a WHOLE primitive
/// domain rather than one name. A pattern element is typed through tsc's
/// `getIndexedAccessType` with the key node as the access node, and its
/// no-access-expression reporting path is:
///
/// ```
/// else if (indexType.flags & (TypeFlags.String | TypeFlags.Number)) {
///     error(indexNode, Diagnostics.Type_0_has_no_matching_index_signature_for_type_1,
///           typeToString(objectType), typeToString(indexType));
/// }
/// ```
///
/// so `let { [foo()]: bar } = {}` with `foo(): string` is an error while
/// `let { ["bar"]: bar } = { bar: 1 }` (a literal key, handled by the caller)
/// and `let { [k]: v } = r` on a `Record<string, T>` are not.
///
/// Deliberately only the `string`/`number` kinds tsc names. A key that is a
/// union of literals distributes over its members, a generic one defers, and
/// an `any` one is tsc's TS2538 — none of which this answers, so each keeps
/// today's silence.
fn reportNoMatchingIndex(c: *Checker, key_expr: Node, whole: TypeId, r: TypeId, kt: TypeId) Error!void {
    const k = c.ts.kind(try c.resolveStructural(kt));
    if (k != .string and k != .number) return;
    // An `any`/`error`/`never` source has no shape to be missing an index
    // signature — tsc returns the object type itself for those.
    switch (c.ts.kind(r)) {
        .any, .err, .never, .unknown => return,
        // A tuple/array carries the numeric domain; a `string` receiver carries
        // it through lib's `interface String`. Only a real member table can be
        // short an index signature.
        .object => {},
        else => return,
    }
    if (c.ts.objectStringIndex(r) != 0) return;
    if (k == .number and c.ts.objectNumberIndex(r) != 0) return;
    try c.diagFmt(2537, c.nodeSpan(key_expr), "Type '{s}' has no matching index signature for type '{s}'.", .{
        try c.typeToString(whole),
        try c.typeToString(if (k == .string) types.string_type else types.number_type),
    });
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

/// The type a destructuring pattern implies, as the CONTEXTUAL TYPE of the
/// value it destructures. Both spellings arrive here — a declaration's
/// BINDING pattern (`var [a, b] = …`) and the expression cover grammar an
/// ASSIGNMENT pattern parses as (`[a, b] = …`) — and tsc reaches the two by
/// different routes with different answers, which `arrayPatternContextualType`
/// spells out.
///
/// For a binding pattern it is `getTypeFromArrayBindingPattern`, reached from
/// `getContextualTypeForInitializerExpression`, which falls back to
/// `getTypeFromBindingPattern(name, /*includePatternInType*/ true)` when the
/// declaration carries no annotation of its own. It is what makes
/// `var [a, b] = [1, "x"]` give `a: number` and `b: string`. Without it the
/// literal is checked with no context, widens to `(string | number)[]`, and
/// every name the pattern binds gets that union — and a position past the end
/// silently gets it too, instead of the TS2493 an out-of-range tuple index
/// earns.
///
/// Every BINDING position is `any`: such a pattern says WHERE, never WHAT
/// (`getTypeFromBindingElement` answers `nonInferrableAnyType` for a plain
/// name). The exception is a nested ARRAY pattern, which recurses so an inner
/// literal is in tuple context too — a nested OBJECT pattern stays `any`,
/// because its implied type is `pattern`-stamped and contextually typing a
/// literal by one turns on tsc's `contextualTypeHasPattern` excess branch,
/// which `checkPatternExcessProps` already runs from the declaration.
///
/// `no_type` — no contextual type at all — for anything that implies no
/// tuple: a non-array pattern, and the two shapes tsc answers
/// `Iterable<any>`/`any[]` for, an empty pattern and a lone `[...r]` that
/// says nothing about its target.
pub fn patternContextualType(c: *Checker, pat: Node) Error!TypeId {
    if (pat == null_node) return types.no_type;
    return switch (c.nodeTag(pat)) {
        .object_pattern => objectPatternContextualType(c, pat),
        .array_pattern, .array_literal => arrayPatternContextualType(c, pat),
        else => types.no_type,
    };
}

/// The type a BINDING PATTERN declares for the thing it destructures, when
/// nothing else does — tsc's `getTypeFromBindingPattern(name,
/// /*includePatternInType*/ false, /*reportErrors*/ true)`, the last arm of
/// `getTypeForVariableLikeDeclaration` for a parameter with no annotation, no
/// contextual signature and no initializer.
///
/// A pattern says how many positions the value must have and which names it
/// must carry; typing such a parameter `any` threw all of that away, so
/// `function c5([a, b, [[c]]]) {}` accepted a five-element argument where tsc
/// answers TS2345 against `[any, any, [[any]]]`
/// (`destructuringParameterDeclaration1ES6`), and `function foo({x: [a, b]})`
/// accepted an `x` that is an ARRAY rather than a two-tuple
/// (`argumentExpressionContextualTyping`).
///
/// This is the same walk `patternContextualType` runs, minus its
/// object-pattern gate: that gate exists because handing an all-`any`
/// CONTEXTUAL type to an initializer is not the same as handing it none, and
/// a DECLARED type has no such hazard. `no_type` for everything the walk
/// cannot enumerate — a rest element, a computed key, an empty pattern — where
/// the caller keeps its `any`.
pub fn patternDeclaredType(c: *Checker, pat: Node) Error!TypeId {
    return switch (c.nodeTag(pat)) {
        .object_pattern => (try patternImpliedType(c, pat, .binding)) orelse types.no_type,
        .array_pattern => arrayPatternContextualType(c, pat),
        else => types.no_type,
    };
}

/// How one position of an array pattern behaves, over BOTH vocabularies: a
/// declaration's binding pattern (`.rest_element`, `.binding_default`) and
/// the expression cover grammar an assignment pattern parses as
/// (`.spread_element`, and a plain `=` assignment for a default).
const ArrayElemRole = enum { rest, hole, defaulted, plain };

fn arrayElemRole(c: *const Checker, el: Node) ArrayElemRole {
    return switch (c.nodeTag(el)) {
        .rest_element, .spread_element => .rest,
        .omitted => .hole,
        .binding_default => .defaulted,
        .assign => if (c.tree.tokens.tag(c.tree.nodeMainToken(el)) == .eq) .defaulted else .plain,
        else => .plain,
    };
}

/// An ASSIGNMENT pattern's implied type is `checkArrayLiteral`'s
/// `inDestructuringPattern` tuple, not `getTypeFromArrayBindingPattern`, and
/// the two differ in what a position CONTRIBUTES. A binding pattern declares
/// its names, so a position says WHERE and not WHAT (`any`); an assignment
/// pattern WRITES names that already have types, and tsc puts each target's
/// own type at its position — `checkExpressionForMutableLocation(element)`.
/// That is what makes `[, multiSkillB] = ["roomba", ["vacuum", "mopping"]]`
/// read the inner literal as the tuple `multiSkillB` is declared to be
/// instead of widening it to `string[]`.
///
/// The target types are read off the DECLARATION
/// (`assignTargetDeclaredType`), never by checking the target as an
/// expression — a bare name only, everything else contributing `any`. The
/// reason is the same one that helper already carries for the object arm:
/// checking a target as an expression re-runs its diagnostics as a READ,
/// which is exactly what `checkDestructuringTarget` peels apart to avoid.
///
/// A REST element takes the same reading with `ElementFlags.Variadic`
/// semantics: a target that is itself an array pattern SPREADS its tuple
/// into these positions, and a target declared as an array becomes this
/// tuple's rest — so `[...multiRobotAInfo] = ["trimmer", ["trimming", ""]]`
/// contextually types the inner literal by `multiRobotAInfo`'s element.
fn arrayPatternContextualType(c: *Checker, pat: Node) Error!TypeId {
    const assignment = c.nodeTag(pat) == .array_literal;
    const els = c.tree.nodeRange(pat);
    // tsc's `minLength`: one past the last position that is neither the rest,
    // omitted, nor defaulted. Everything after it is optional.
    var min_len: u32 = 0;
    var n: u32 = 0;
    for (els) |el| {
        if (el == null_node) continue;
        n += 1;
        if (arrayElemRole(c, el) == .plain) min_len = n;
    }
    var elems: std.ArrayList(types.TupleElem) = .empty;
    defer elems.deinit(c.scratch());
    // Whether any position carries more than the `any` a binding pattern
    // contributes — the test the two "implies nothing" bails below use.
    var informative = false;
    var i: u32 = 0;
    for (els) |el| {
        if (el == null_node) continue;
        defer i += 1;
        if (arrayElemRole(c, el) == .rest) {
            const target = c.tree.nodeData(el).lhs;
            if (assignment) {
                if (try restTargetTuple(c, target)) |spread| {
                    for (0..c.ts.tupleLen(spread)) |j| {
                        try elems.append(c.scratch(), c.ts.tupleElem(spread, @intCast(j)));
                    }
                    informative = true;
                    continue;
                }
                if (try assignTargetDeclaredType(c, target)) |t| {
                    if (c.ts.kind(try c.resolveStructural(t)) == .array) {
                        try elems.append(c.scratch(), .{ .ty = t, .flags = types.elem_flag_rest });
                        informative = true;
                        continue;
                    }
                }
            }
            try elems.append(c.scratch(), .{
                .ty = try c.ts.makeArray(types.any_type),
                .flags = types.elem_flag_rest,
            });
            continue;
        }
        const ty = try patternElemContextualType(c, el, assignment);
        if (ty != types.any_type) informative = true;
        try elems.append(c.scratch(), .{
            .ty = ty,
            .flags = if (i >= min_len) types.elem_flag_optional else 0,
        });
    }
    if (elems.items.len == 0) return types.no_type;
    if (!informative and elems.items.len == 1 and elems.items[0].flags & types.elem_flag_rest != 0) return types.no_type;
    return try c.ts.makeTuple(elems.items);
}

/// The tuple a rest element's target implies, when that target is itself an
/// array pattern — the operand of `ElementFlags.Variadic` above. Null for
/// anything else (a plain name, an object pattern, a member expression).
fn restTargetTuple(c: *Checker, target: Node) Error!?TypeId {
    if (target == null_node) return null;
    var t = target;
    while (c.nodeTag(t) == .paren_expr) t = c.tree.nodeData(t).lhs;
    switch (c.nodeTag(t)) {
        .array_pattern, .array_literal => {},
        else => return null,
    }
    const nested = try patternContextualType(c, t);
    if (nested == types.no_type or c.ts.kind(nested) != .tuple) return null;
    return nested;
}

/// One position of the tuple above. A DEFAULT is looked through rather than
/// typed: tsc types `[a] = [0]` from the default expression, but the only
/// part of that answer this contextual type can use is its SHAPE, and the
/// pattern under the default carries the same one.
fn patternElemContextualType(c: *Checker, el0: Node, assignment: bool) Error!TypeId {
    var el = el0;
    while (true) {
        switch (c.nodeTag(el)) {
            .binding_default => el = c.tree.nodeData(el).lhs,
            .assign => {
                if (c.tree.tokens.tag(c.tree.nodeMainToken(el)) != .eq) break;
                el = c.tree.nodeData(el).lhs;
            },
            .paren_expr => el = c.tree.nodeData(el).lhs,
            else => break,
        }
    }
    switch (c.nodeTag(el)) {
        .array_pattern, .array_literal => {
            const nested = try patternContextualType(c, el);
            return if (nested == types.no_type) types.any_type else nested;
        },
        else => {},
    }
    if (assignment) {
        if (try assignTargetDeclaredType(c, el)) |t| return t;
    }
    return types.any_type;
}

/// The object type an OBJECT binding pattern implies, as the CONTEXTUAL TYPE
/// of the initializer it destructures — the same
/// `getContextualTypeForInitializerExpression` fallback the array arm above
/// is, spelled `getTypeFromObjectBindingPattern`.
///
/// A pattern says WHERE, not WHAT, so a plain name contributes `any` and the
/// whole thing is worth nothing. A DEFAULT is the exception: it says exactly
/// what the property is expected to be, and tsc carries that into the
/// initializer. `const { f = (x: string) => x.length } = id({ f: x => x.charAt })`
/// is the shape — the pattern implies `{ f?: ((x: string) => number) |
/// undefined }`, `id`'s `T` seeds from it, the argument literal's `f` is
/// contextually a `(x: string) => …`, and `x` is not an implicit any
/// (`objectBindingPatternContextuallyTypesArgument`,
/// `intraBindingPatternReferences`).
///
/// Gated on some element actually carrying a default (or a nested pattern
/// that does), because that is the only information this type can carry:
/// without one every member is `any` and handing the initializer an
/// all-`any` contextual type is not the same as handing it none — it would
/// perturb literal freshness and inference everywhere for no benefit. tsc
/// supplies the all-`any` type; the narrowing is deliberate and measured
/// (the sweep moves only on the defaulted shapes).
///
/// The member types come from `patternImpliedType`, which is the same tsc
/// function (`getTypeFromObjectBindingPattern`) read for its display
/// spelling in the excess-property report — `null` there, for a rest element
/// or a computed key, is `no_type` here for the same reason: neither shape
/// implies a type this walk can enumerate.
fn objectPatternContextualType(c: *Checker, pat: Node) Error!TypeId {
    if (!patternHasDefault(c, pat)) return types.no_type;
    return (try patternImpliedType(c, pat, .binding)) orelse types.no_type;
}

/// Does any element of `pat` — at any depth — carry a default?
fn patternHasDefault(c: *Checker, pat: Node) bool {
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node) continue;
        const ed = c.tree.nodeData(el);
        switch (c.nodeTag(el)) {
            .binding_property => {
                if (ed.rhs != 0) return true;
                if (ed.lhs != 0 and isPattern(c, ed.lhs) and patternHasDefault(c, ed.lhs)) return true;
            },
            .binding_default => return true,
            else => {},
        }
    }
    return false;
}

fn isPattern(c: *const Checker, n: Node) bool {
    return switch (c.nodeTag(n)) {
        .object_pattern, .array_pattern => true,
        else => false,
    };
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
            try checkPatternProps(c, c.tree.nodeData(el).lhs, try c.ts.makeArray(elem), false);
            continue;
        }
        // Only a TUPLE source gives an element position its own exact type. An
        // ARRAY source is the widened element type, and descending with that
        // union would report a property missing from a sibling's type
        // (`destructuringVariableDeclaration2`) — a literal initializer is a
        // tuple here precisely because the pattern contextually types it
        // (`patternContextualType`).
        if (c.ts.kind(r) != .tuple) {
            // A UNION of tuples has no single element type to descend with,
            // but the out-of-range question still has one answer for the whole
            // union — tsc's indexed access reports on the union receiver, with
            // the generic TS2339 rather than any one constituent's arity.
            if (c.ts.kind(r) == .union_type and c.nodeTag(el) != .binding_default and
                try keyof.tupleIndexVerdict(c, r, i) == .out_of_range)
            {
                try keyof.reportTupleIndexOutOfRange(c, r, whole, i, el);
            }
            continue;
        }
        if (i >= c.ts.tupleLen(r)) {
            // Past the end, with no rest element to absorb it: the same
            // out-of-range indexed access `tupleBindingElemType` answers
            // `undefined` for, and tsc reports it from there. A DEFAULT
            // silences it — that is `AccessFlags.AllowMissing`, which
            // `hasDefaultValue(declaration)` turns on.
            if (c.nodeTag(el) == .binding_default) continue;
            if ((try c.tupleElemTypeAt(r, i)) != null) continue;
            try c.diagFmt(2493, c.nodeSpan(el), "Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{
                try c.typeToString(r), c.ts.tupleLen(r), i,
            });
            // …and the walk carries on with what the access ANSWERED. tsc's
            // `getIndexedAccessTypeOrUndefined` reports and yields
            // `undefinedType`, which a NESTED pattern then destructures — so
            // `var [[a0]] = []` is the TS2493 *and* a TS2488 for `undefined`
            // at the inner pattern (`destructuringArrayBindingPatternAndAssignment2`).
            try checkPatternProps(c, el, types.undefined_type, false);
            continue;
        }
        try checkPatternProps(c, el, c.ts.tupleElem(r, i).ty, false);
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
            break :blk try c.checkExprCached(d.rhs, try patternContextualType(c, pat));
        },
        else => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann != 0) break :blk try c.typeFromTypeNode(e.type_ann);
            if (e.init == 0) break :blk fallback;
            init_node = e.init;
            break :blk try c.checkExprCached(e.init, try patternContextualType(c, pat));
        },
    };
    // tsc's `needCheckInitializer` is about the declaration CARRYING one, not
    // about `src` having come from it: `const []: void = v` annotates and still
    // takes the initializer branch. `.declarator_full` with an annotation is
    // exactly that case, and it leaves `init_node` unset.
    const has_init = init_node != null_node or (c.nodeTag(decl) == .declarator_full and
        c.tree.extraData(ast.DeclaratorFull, d.rhs).init != 0);
    try checkPatternProps(c, pat, src, has_init);
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
            .binding => try bindingElemImpliedType(c, ed.lhs, ed.rhs),
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

/// One BINDING element's contribution to the type above — tsc's
/// `getTypeFromBindingElement`:
///
/// ```ts
/// if (element.initializer) {
///     const contextualType = isBindingPattern(element.name) ? getTypeFromBindingPattern(element.name, true, false) : unknownType;
///     return addOptionality(widenTypeInferredFromInitializer(element, checkDeclarationInitializer(element, CheckMode.Normal, contextualType)));
/// }
/// if (isBindingPattern(element.name)) return getTypeFromBindingPattern(element.name, includePatternInType, reportErrors);
/// return includePatternInType ? nonInferrableAnyType : anyType;
/// ```
///
/// `nested` is the element's own nested pattern (0 for a plain name) and
/// `default_expr` its default (0 for none). A default is the only thing a
/// pattern can say about a property's TYPE, and it is what makes the implied
/// type worth handing to the initializer at all.
///
/// The literal is WIDENED, where tsc widens only for a non-`const`
/// declaration (`widenTypeInferredFromInitializer` reads the element's
/// combined node flags). ztsc has no parent pointers, so the element cannot
/// see its declaration list from here; widening is the conservative half of
/// the choice — an unwidened literal in a CONTEXTUAL type pins freshness on
/// the initializer, and the only visible cost is that the excess-property
/// report prints `{ a?: number | undefined }` where tsc prints
/// `{ a?: 1 | undefined }`.
fn bindingElemImpliedType(c: *Checker, nested: Node, default_expr: Node) Error!TypeId {
    if (default_expr != 0) {
        const inner: TypeId = if (nested != 0 and isPattern(c, nested))
            try patternContextualType(c, nested)
        else
            types.no_type;
        const t = try c.widenLiteral(try c.checkExprCached(default_expr, inner));
        // tsc's `addOptionality`: the property is optional AND its type
        // carries `undefined`, which is what the initializer's own property
        // is allowed to be.
        return try c.ts.makeUnion(c.scratch(), &.{ t, types.undefined_type });
    }
    if (nested != 0 and isPattern(c, nested)) {
        const t = try patternContextualType(c, nested);
        if (t != types.no_type) return t;
    }
    return types.any_type;
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
