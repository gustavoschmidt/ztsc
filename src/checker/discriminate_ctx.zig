//! Contextual-type discrimination: when an object literal or a JSX attribute
//! list is contextually typed by a UNION, tsc picks the ONE constituent the
//! literal's own discriminant properties select, and everything downstream —
//! each property's contextual type, and so every callback's contextual
//! signature — reads that constituent instead of the union.
//!
//! `getApparentTypeOfContextualType` is where it happens:
//!
//! ```ts
//! return apparentType.flags & TypeFlags.Union && isObjectLiteralExpression(node) ?
//!         discriminateContextualTypeByObjectMembers(node, apparentType as UnionType) :
//!     apparentType.flags & TypeFlags.Union && isJsxAttributes(node) ?
//!         discriminateContextualTypeByJSXAttributes(node, apparentType as UnionType) :
//!     apparentType;
//! ```
//!
//! Both spellings feed the same engine (`discriminateTypeByDiscriminantProperties`),
//! which is `select` below; the two front-ends differ only in how they read
//! (name, value) pairs out of the syntax.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const TypeId = types.TypeId;
const null_node = ast.null_node;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const identity = @import("identity.zig");
const isUnitType = @import("assign.zig").isUnitType;

/// One candidate discriminator read out of the syntax: the property name, and
/// either the expression that supplies its value or — for a JSX attribute
/// written bare (`<Foo renderNumber />`) — the type that value implies.
const Cand = struct {
    name: Atom,
    value: Node = null_node,
    ty: TypeId = types.no_type,
};

/// tsc's `isPossiblyDiscriminantValue`: the expression forms whose type is
/// worth asking for before the literal has a contextual type at all. Anything
/// else contributes no discriminator, so a callback or a nested literal never
/// drags the whole union through a speculative check.
pub fn possiblyDiscriminantValue(c: *Checker, node: Node) bool {
    if (node == null_node) return false;
    return switch (c.nodeTag(node)) {
        .string_literal,
        .number_literal,
        .bigint_literal,
        .template_literal,
        .template_expr,
        .true_literal,
        .false_literal,
        .null_literal,
        .identifier,
        => true,
        .paren_expr, .member_expr => possiblyDiscriminantValue(c, c.tree.nodeData(node).lhs),
        else => false,
    };
}

/// tsc's `getContextFreeTypeOfExpression` for a candidate discriminant value.
///
/// The node-type memo is keyed by (node, contextual type), so the answer taken
/// here neither satisfies nor displaces the authoritative check the property
/// walk runs afterwards with the property's real contextual type — which is
/// exactly the separation tsc gets from its own `contextFreeTypeCache`.
fn contextFreeType(c: *Checker, node: Node) Error!TypeId {
    return c.checkExprCached(node, types.no_type);
}

/// tsc's `isLiteralType`: a single-valued type, a union of them, or `boolean`
/// (which is stored as the union of its two literals in tsc and as its own
/// kind here). One constituent's property being one of these is half of what
/// makes the property a discriminant.
fn isLiteralLike(c: *Checker, t: TypeId) Error!bool {
    if (c.ts.kind(t) == .boolean) return true;
    if (c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (!isUnitType(c, try c.resolveStructural(m))) return false;
        }
        return true;
    }
    return isUnitType(c, t);
}

/// Does constituent `member` accept the discriminant value `src` for `name`?
/// tsc runs `isTypeAssignableTo(src, getTypeOfPropertyOfType(member, name))`,
/// and under `strictNullChecks` an OPTIONAL property's type already carries
/// `undefined` — which is what lets the omitted-property discriminator below
/// select `{ renderNumber?: false }` over `{ renderNumber: true }`.
///
/// The `| undefined` is decided rather than built: only an `undefined` source
/// can need it, and only optionality can supply it. Interning one union per
/// constituent per candidate name — for a flag — cost ~2% of peak RSS on
/// social-app.
fn memberAccepts(c: *Checker, member: TypeId, name: Atom, src: TypeId) Error!bool {
    const p = (try c.propOfType(try c.resolveStructural(member), name)) orelse return false;
    if (p.optional() and c.ts.kind(src) == .undefined) return true;
    return c.isAssignable(src, p.ty);
}

/// tsc's `isDiscriminantProperty`: the union's property for `name` must carry
/// `CheckFlags.Discriminant` — `HasNonUniformType | HasLiteralType`, i.e. the
/// constituents must not all agree on it AND at least one of them must give it
/// a literal type.
///
/// A property some constituent does not declare at all is not asked: tsc's
/// union property is `ReadPartial` there and the discriminator is skipped, and
/// answering "this member does not constrain the name, keep it" instead is
/// what kept whole unions alive through discrimination — the very thing that
/// makes the contextual-signature agreement rule fire on unions tsc has
/// already collapsed to one constituent.
fn isDiscriminantProp(c: *Checker, members: []const TypeId, name: Atom) Error!bool {
    var first: TypeId = types.no_type;
    var first_opt = false;
    var non_uniform = false;
    var has_literal = false;
    for (members) |m| {
        const p = (try c.propOfType(try c.resolveStructural(m), name)) orelse return false;
        if (first == types.no_type) {
            first = p.ty;
            first_opt = p.optional();
        } else if (p.ty != first or p.optional() != first_opt) {
            non_uniform = true;
        }
        // The declared type with `undefined` added back for an optional
        // property, decided WITHOUT building the union — this runs once per
        // candidate name per constituent, and the allocation showed up.
        // `undefined` is itself a unit type, so the answer only differs from
        // the declared type's for `p?: never`, whose `never | undefined`
        // reduces to plain `undefined`.
        if (!has_literal) {
            has_literal = (p.optional() and c.ts.kind(p.ty) == .never) or try isLiteralLike(c, p.ty);
        }
    }
    return non_uniform and has_literal;
}

/// tsc's `discriminateTypeByDiscriminantProperties`, run over the candidates a
/// front-end collected.
///
/// Each discriminator marks every constituent it does not accept as OUT, for
/// good; a constituent it accepts is marked IN only if nothing has ruled it
/// out yet. The union survives unless exactly one constituent is left standing
/// (several identical ones count as one), so the step only ever answers with a
/// single constituent or with the union it was handed.
fn select(c: *Checker, rctx: TypeId, cands: []const Cand, present: []const Atom) Error!TypeId {
    const members = try c.memberList(rctx);
    if (members.len < 2) return rctx;
    const state = try c.scratch().alloc(?bool, members.len);
    defer c.scratch().free(state);
    @memset(state, null);
    var any_discriminator = false;

    for (cands) |cand| {
        if (!try isDiscriminantProp(c, members, cand.name)) continue;
        const src = if (cand.ty != types.no_type) cand.ty else try contextFreeType(c, cand.value);
        if (src == types.no_type) continue;
        any_discriminator = true;
        for (members, 0..) |m, i| {
            if (try memberAccepts(c, m, cand.name, src)) {
                if (state[i] == null) state[i] = true;
            } else {
                state[i] = false;
            }
        }
    }

    // The second half of tsc's discriminator list: every OPTIONAL discriminant
    // property of the CONTEXTUAL TYPE that the literal LEAVES OUT discriminates
    // by `undefined`. It is what tells `<Foo>{cb}</Foo>` from
    // `<Foo renderNumber>{cb}</Foo>` when the union is
    // `{ renderNumber?: false; … } | { renderNumber: true; … }`.
    //
    // The names come from the FIRST constituent alone, which is where tsc gets
    // them too: `getPropertiesOfUnionOrIntersectionType` stops after one
    // constituent for an index-signature-free union, because a union's
    // properties are the ones present in all of them — and `isDiscriminantProp`
    // below re-checks exactly that. It also bounds the work, which matters:
    // this runs on every contextually-typed object literal and JSX element.
    const first = try c.resolveStructural(members[0]);
    if (c.ts.kind(first) == .object) {
        for (0..c.ts.objectPropCount(first)) |i| {
            const p = c.ts.objectProp(first, @intCast(i));
            if (containsAtom(present, p.name)) continue;
            if (!try isDiscriminantProp(c, members, p.name)) continue;
            // OPTIONAL is asked of the UNION's property, not of this one
            // constituent's: `createUnionOrIntersectionProperty` ORs the flag
            // across constituents, so `{ disc: true } | { disc?: false }` has
            // an optional `disc` even though the arm the names came from
            // requires it.
            if (!try optionalInSomeConstituent(c, members, p.name)) continue;
            any_discriminator = true;
            for (members, 0..) |m, j| {
                if (try memberAccepts(c, m, p.name, types.undefined_type)) {
                    if (state[j] == null) state[j] = true;
                } else {
                    state[j] = false;
                }
            }
        }
    }

    if (!any_discriminator) return rctx;
    var match: ?usize = null;
    for (state, 0..) |s, i| {
        if (s != true) continue;
        const prev = match orelse {
            match = i;
            continue;
        };
        // Two survivors are one answer only when they are the same type.
        if (!try identity.identical(c, members[prev], members[i])) return rctx;
    }
    return if (match) |i| members[i] else rctx;
}

/// Is the union's property for `name` optional? tsc's union property carries
/// `SymbolFlags.Optional` when ANY constituent's does. Asked constituent by
/// constituent rather than through `propOfType` on the union, which would
/// build (and intern) the merged property type just to read one flag.
fn optionalInSomeConstituent(c: *Checker, members: []const TypeId, name: Atom) Error!bool {
    for (members) |m| {
        const p = (try c.propOfType(try c.resolveStructural(m), name)) orelse continue;
        if (p.optional()) return true;
    }
    return false;
}

fn containsAtom(names: []const Atom, name: Atom) bool {
    for (names) |n| if (n == name) return true;
    return false;
}

/// tsc's `discriminateContextualTypeByObjectMembers`. `node` is the object
/// literal, `rctx` its resolved union contextual type.
pub fn byObjectMembers(c: *Checker, node: Node, rctx: TypeId) Error!TypeId {
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(c.scratch());
    var present: std.ArrayList(Atom) = .empty;
    defer present.deinit(c.scratch());
    for (c.tree.nodeRange(node)) |prop| {
        if (prop == null_node) continue;
        const pd = c.tree.nodeData(prop);
        switch (c.nodeTag(prop)) {
            // A computed key names no property the union can be keyed by.
            .object_property => {
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                const name = try c.memberAtom(c.tree.nodeMainToken(prop));
                try present.append(c.scratch(), name);
                if (possiblyDiscriminantValue(c, pd.rhs)) {
                    try cands.append(c.scratch(), .{ .name = name, .value = pd.rhs });
                }
            },
            // `{ kind }` is a property assignment whose value is an
            // identifier, which is one of the forms tsc asks about.
            .object_shorthand => {
                const name = try c.memberAtom(c.tree.nodeMainToken(prop));
                try present.append(c.scratch(), name);
                try cands.append(c.scratch(), .{ .name = name, .value = pd.lhs });
            },
            // A method is `p.kind === SyntaxKind.PropertyAssignment` false —
            // never a discriminator — but it does make the name PRESENT, so
            // `select`'s omitted-optional arm must not invent one for it.
            .object_method => {
                if (pd.lhs != 0 and c.nodeTag(pd.lhs) == .computed_name) continue;
                try present.append(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(prop)));
            },
            // A spread contributes NOTHING here, and does not stop the walk:
            // tsc's omitted-optional set is keyed off `node.symbol.members`,
            // the binder's table for the literal, and a `SpreadAssignment`
            // has no name to put in it. So a name only a spread supplies is
            // "omitted" for tsc too, and bailing out instead lost every
            // discrimination for a literal that merely mentions a spread.
            .spread_element => {},
            else => {},
        }
    }
    return select(c, rctx, cands.items, present.items);
}

/// tsc's `discriminateContextualTypeByJSXAttributes`. `attrs` is the attribute
/// list of the opening element; `has_children` says whether the element has
/// JSX children, which stand in for the `children` prop.
pub fn byJsxAttributes(c: *Checker, attrs: []const Node, rctx: TypeId, has_children: bool) Error!TypeId {
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(c.scratch());
    var present: std.ArrayList(Atom) = .empty;
    defer present.deinit(c.scratch());
    for (attrs) |attr| {
        if (attr == null_node) continue;
        // Same reasoning as the object literal's spread element: a
        // `JsxSpreadAttribute` has no symbol name, so it is invisible to
        // tsc's omitted-optional filter rather than a reason to stop.
        if (c.nodeTag(attr) == .jsx_spread_attribute) continue;
        const ad = c.tree.nodeData(attr);
        const name_tok = c.tree.nodeMainToken(attr);
        // A hyphenated name (`data-*`) is not an identifier tsc keys a union by.
        if (c.tree.tokens.tag(name_tok) == .jsx_name) continue;
        const name = try c.memberAtom(name_tok);
        try present.append(c.scratch(), name);
        if (ad.lhs == null_node) {
            // `<Foo renderNumber />` — tsc's `checkJsxAttribute` gives a
            // valueless attribute `trueType`.
            try cands.append(c.scratch(), .{ .name = name, .ty = types.true_type });
            continue;
        }
        // `attr={expr}` arrives wrapped in a `jsx_expr_container`;
        // `attr="s"` is the string literal itself.
        const v = if (c.nodeTag(ad.lhs) == .jsx_expr_container) c.tree.nodeData(ad.lhs).lhs else ad.lhs;
        if (possiblyDiscriminantValue(c, v)) {
            try cands.append(c.scratch(), .{ .name = name, .value = v });
        }
    }
    if (has_children) try present.append(c.scratch(), try c.jsxChildrenAttrName());
    return select(c, rctx, cands.items, present.items);
}
