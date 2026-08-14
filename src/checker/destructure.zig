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
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node or c.nodeTag(el) != .binding_property) continue;
        const ed = c.tree.nodeData(el);
        if (ed.rhs == 0) continue; // no default
        if ((try c.memberAtom(c.tree.nodeMainToken(el))) == name) return true;
    }
    return false;
}
