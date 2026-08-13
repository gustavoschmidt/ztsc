//! TS7031, the binding-element member of the implicit-'any' family.
//!
//! A destructuring declaration with no type annotation and no usable
//! initializer has no type to hand its bindings, so tsc *builds* one out of
//! the pattern itself (`getTypeFromBindingPattern`) and reports every leaf
//! that lands on `any`. The report is per BINDING ELEMENT, not per
//! declaration — which is why the parameter-level TS7006 is silent for a
//! destructured parameter: the elements speak instead.
//!
//! Two entry points, matching tsc's two producers:
//!
//!   - `reportPatternImplicitAny` — the pattern is the only source of type
//!     information (`function f([x, y]) {}`);
//!   - `reportPaddedTupleImplicitAny` — an ARRAY pattern IS initialized, but
//!     by a tuple shorter than itself, so tsc pads the missing positions with
//!     `any` (`padTupleType`) and reports the padded elements that carry no
//!     default (`function f([x, y] = [1]) {}` → `y`).
//!
//! Both are diagnostics only: the types those declarations receive are
//! computed in `destructure.zig`, which already lands on `any` in exactly
//! these positions.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const paths = @import("../link/paths.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's `declarationBelongsToPrivateAmbientMember`: the implicit-'any'
/// family is silent on a `private` class member in an AMBIENT context.
/// Such a member has no observable type outside its class — a `.d.ts` cannot
/// even spell one for an overload-free `private m(a);` — so tsc does not ask
/// for an annotation there. `node` is the function-like the parameter belongs
/// to; only a class member can be `private`, so everything else is false.
pub fn isPrivateAmbientMember(c: *Checker, node: Node) bool {
    if (node == null_node or c.nodeTag(node) != .class_method) return false;
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(node).lhs);
    if (proto.flags & ast.Flags.private == 0) return false;
    return inAmbientContext(c);
}

/// tsc's `NodeFlags.Ambient`, read from the CURRENT scope chain rather than
/// from a walk-time flag: every declaration in a `.d.ts` is ambient, as is
/// anything lexically inside a `declare` class/namespace/module.
///
/// Read from the scope chain because a member signature is routinely built by
/// LAZY demand (`computeMemberType` → `enterSymFile`), not by the statement
/// walk that maintains `ambient_ctx` — the flag is false there even when the
/// declaration sits inside a `declare class`.
fn inAmbientContext(c: *Checker) bool {
    if (c.ambient_ctx) return true;
    if (paths.isDeclarationPath(c.prog.files[c.cur_file].path)) return true;
    var s = c.cur_scope;
    while (true) {
        const owner = c.bind.scope_owners[s];
        if (owner != null_node and declaredAmbient(c, owner)) return true;
        if (s == binder.file_scope) return false;
        s = c.bind.scope_parents[s];
    }
}

/// Whether a scope-owning declaration node carries `declare` (or is an
/// ambient-module / global-augmentation block, which are ambient by form).
fn declaredAmbient(c: *Checker, node: Node) bool {
    const d = c.tree.nodeData(node);
    const flags: u32 = switch (c.nodeTag(node)) {
        .class_decl => c.tree.extraData(ast.ClassData, d.lhs).flags,
        .namespace_decl => c.tree.extraData(ast.NamespaceData, d.lhs).flags,
        else => return false,
    };
    return flags & (ast.Flags.declare | ast.Flags.ambient_module | ast.Flags.global_aug) != 0;
}

/// tsc's `getTypeFromBindingPattern(pattern, includePatternInType = false,
/// reportErrors = true)`: walk the pattern and report TS7031 at every leaf
/// name that neither carries a default nor is itself a pattern.
///
/// Skipped, following the same walk:
///   - an OBJECT rest (`{a, ...r}`) — tsc gives the implied type a string
///     index signature and never visits the element;
///   - an array pattern that is empty or is nothing but a rest (`[...r]`) —
///     tsc short-circuits both to `any[]`/`Iterable<any>`. An array rest with
///     siblings (`[a, ...r]`) IS visited, and `r` reports;
///   - an elision (`[a, , b]`) and any element with a default;
///   - a computed key that is not a literal — tsc cannot use it as a property
///     name, so the element never enters the implied type.
pub fn reportPatternImplicitAny(c: *Checker, pat: Node) Error!void {
    if (!isBindingPattern(c, pat)) return;
    try reportPatternRec(c, pat);
}

/// Whether a declaration name is a destructuring pattern (as opposed to a
/// plain identifier, whose implicit `any` is TS7005/TS7006 territory and is
/// reported — or deliberately not — by its own declaration site).
pub fn isBindingPattern(c: *Checker, node: Node) bool {
    if (node == null_node) return false;
    return switch (c.nodeTag(node)) {
        .object_pattern, .array_pattern => true,
        else => false,
    };
}

fn reportPatternRec(c: *Checker, pat: Node) Error!void {
    if (pat == null_node) return;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .identifier => try reportBindingElement(c, c.tree.nodeMainToken(pat)),
        .object_pattern => for (c.tree.nodeRange(pat)) |el| {
            if (el == null_node) continue;
            const ed = c.tree.nodeData(el);
            switch (c.nodeTag(el)) {
                .binding_property => {
                    if (ed.rhs != 0) continue; // `{a = 1}` / `{k: v = 1}`
                    if (ed.lhs != 0) {
                        try reportPatternRec(c, ed.lhs);
                    } else {
                        try reportBindingElement(c, c.tree.nodeMainToken(el));
                    }
                },
                .binding_property_computed => {
                    if (!isLiteralKey(c, ed.lhs)) continue;
                    try reportPatternRec(c, ed.rhs);
                },
                else => {}, // rest_element: a string index signature, not a leaf
            }
        },
        .array_pattern => {
            const els = c.tree.nodeRange(pat);
            if (els.len == 0) return;
            if (els.len == 1 and c.nodeTag(els[0]) == .rest_element) return;
            for (els) |el| {
                if (el == null_node or c.nodeTag(el) == .omitted) continue;
                try reportPatternRec(c, el);
            }
        },
        // `[a = 1]` supplies its own type; `...r` binds the element itself.
        .binding_default => {},
        .rest_element => try reportPatternRec(c, d.lhs),
        else => {},
    }
}

/// tsc's `padTupleType`: a parameter whose name is an ARRAY pattern and whose
/// initializer types as a tuple SHORTER than the pattern pads the missing
/// positions with `any`, reporting TS7031 at each padded element that carries
/// no default of its own. `function f([x, y] = [1]) {}` reports `y`.
///
/// A tuple with a rest element is never padded (it already covers every
/// position), and a non-tuple initializer (`[] as any`) supplies its own type
/// for the whole pattern, so neither reports.
pub fn reportPaddedTupleImplicitAny(c: *Checker, pat: Node, init_node: Node, init_ty: TypeId) Error!void {
    if (pat == null_node or c.nodeTag(pat) != .array_pattern) return;
    const arity = (tupleArity(c, init_ty) orelse arrayLiteralArity(c, init_node)) orelse return;
    const els = c.tree.nodeRange(pat);
    if (arity >= els.len) return;
    for (els[arity..], arity..) |el, i| {
        if (el == null_node or c.nodeTag(el) == .omitted) continue;
        // The pattern's own trailing rest absorbs the tail rather than
        // occupying one padded position.
        if (i == els.len - 1 and c.nodeTag(el) == .rest_element) continue;
        try reportPatternRec(c, el);
    }
}

/// Fixed positional arity of a tuple type, or null when the type is not a
/// tuple or carries a rest element (which already covers every position, so
/// tsc never pads it).
fn tupleArity(c: *Checker, ty: TypeId) ?u32 {
    if (c.ts.kind(ty) != .tuple) return null;
    const n = c.ts.tupleLen(ty);
    for (0..n) |i| {
        if (c.ts.tupleElem(ty, @intCast(i)).flags & types.elem_flag_rest != 0) return null;
    }
    return n;
}

/// The positional arity an ARRAY-LITERAL initializer contributes, or null.
///
/// tsc gets this from the type: an initializer whose declaration's name is a
/// binding pattern is contextually typed by the pattern's implied type
/// (`getContextualTypeForInitializerExpression`), and an array literal under a
/// tuple context types AS a tuple, so `[1]` is `[number]` and pads. ztsc
/// checks the initializer with no contextual type, so `[1]` widens to
/// `number[]` and the arity is gone by the time `padTupleType` would run —
/// it is read back off the syntax here. A spread element makes the implied
/// tuple variadic (tsc's rest flag), which is never padded.
fn arrayLiteralArity(c: *Checker, init_node: Node) ?u32 {
    if (init_node == null_node or c.nodeTag(init_node) != .array_literal) return null;
    const els = c.tree.nodeRange(init_node);
    for (els) |e| {
        if (e != null_node and c.nodeTag(e) == .spread_element) return null;
    }
    return @intCast(els.len);
}

/// One TS7031, named and located by the binding's own name token.
fn reportBindingElement(c: *Checker, tok: TokenIndex) Error!void {
    if (!c.prog.no_implicit_any) return;
    try c.diagFmt(7031, c.tokSpan(tok), "Binding element '{s}' implicitly has an 'any' type.", .{c.tokenText(tok)});
}

/// Whether a computed binding key is a literal tsc can use as a property name
/// (`{["a"]: v}`). A non-literal key leaves the element out of the implied
/// type entirely, so it reports nothing.
fn isLiteralKey(c: *Checker, key: Node) bool {
    if (key == null_node) return false;
    return switch (c.nodeTag(key)) {
        .string_literal, .number_literal, .template_literal => true,
        else => false,
    };
}
