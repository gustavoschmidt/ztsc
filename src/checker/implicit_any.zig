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
const Atom = @import("../intern.zig").Atom;

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

/// The RETURN-type member of the implicit-'any' family: a signature with no
/// return-type annotation AND NO BODY has nothing to infer from, so its return
/// type is `any` and tsc says which kind of signature it was —
///   TS7010 a named function/method  (at the name),
///   TS7020 a bare call signature    (at the `(`),
///   TS7013 a construct signature    (at the `new`).
///
/// Silent for the forms that have no return type to annotate (a constructor, a
/// SET accessor) and for a GET accessor, whose missing return type is the
/// property-flavoured TS7033 instead (not implemented). A signature WITH a
/// body infers its return type and reports nothing; `function_type` and
/// `method_signature` always carry one syntactically.
pub fn reportMissingReturnType(c: *Checker, node: Node, proto: ast.FnProto) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        .call_signature => return c.diagFmt(7020, c.nodeSpan(node), "Call signature, which lacks return-type annotation, implicitly has an 'any' return type.", .{}),
        .construct_signature => return c.diagFmt(7013, c.nodeSpan(node), "Construct signature, which lacks return-type annotation, implicitly has an 'any' return type.", .{}),
        .function_decl, .class_method, .method_signature => {},
        else => return,
    }
    if (c.tree.nodeData(node).rhs != 0) return; // has a body: inferred, not implicit
    if (proto.flags & (ast.Flags.get | ast.Flags.set) != 0) return;
    if (proto.name_token == 0) return;
    if (c.nodeTag(node) == .class_method and
        proto.flags & ast.Flags.static == 0 and
        c.tree.tokens.tag(proto.name_token) == .keyword_constructor) return;
    try c.diagFmt(7010, c.tokSpan(proto.name_token), "'{s}', which lacks return-type annotation, implicitly has an 'any' return type.", .{c.tokenText(proto.name_token)});
}

/// The ACCESSOR-PAIR member of the family — tsc's `resolveTypeOfAccessors`,
/// which resolves the PROPERTY's type from, in order:
///
///   1. the `get` accessor's return annotation,
///   2. the `set` accessor's parameter annotation,
///   3. the `get` accessor's body, inferred.
///
/// With all three missing the property is `any`, and tsc names whichever half
/// could have said so: TS7032 at the SET accessor when there is one (a setter's
/// parameter can never be inferred), TS7033 at the GET accessor otherwise. Both
/// are reported at the accessor's NAME.
///
/// Purely syntactic — one pass to find whether the body has both halves, then a
/// pairing pass, exactly as `checkAccessorVisibility` is shaped and for the same
/// reason: a class body with no accessor at all walks its members once and stops.
pub fn reportAccessorImplicitAny(c: *Checker, members: []const Node) Error!void {
    if (!c.prog.no_implicit_any) return;
    var any_accessor = false;
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const f = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs).flags;
        if (f & (ast.Flags.get | ast.Flags.set) != 0) any_accessor = true;
    }
    if (!any_accessor) return;
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs);
        // Anchored on the GETTER when there is one, so the pair is judged once.
        if (proto.flags & ast.Flags.get == 0) continue;
        if (proto.return_type != 0) continue;
        if (c.tree.nodeData(m).rhs != 0) continue; // a body infers the type
        const name = try c.memberAtom(proto.name_token);
        if (try accessorPartner(c, members, m, name, proto.flags, ast.Flags.set)) |setter| {
            const sp = c.tree.extraData(ast.FnProto, c.tree.nodeData(setter).lhs);
            if (paramIsAnnotated(c, sp)) continue;
            if (!try reportAccessorAny(c, 7032, sp.name_token, sp.flags, "set accessor lacks a parameter type annotation")) continue;
        } else {
            _ = try reportAccessorAny(c, 7033, proto.name_token, proto.flags, "get accessor lacks a return type annotation");
        }
    }
    // A SET accessor with no getter at all: nothing can supply the type either.
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs);
        if (proto.flags & ast.Flags.set == 0) continue;
        if (paramIsAnnotated(c, proto)) continue;
        const name = try c.memberAtom(proto.name_token);
        if ((try accessorPartner(c, members, m, name, proto.flags, ast.Flags.get)) != null) continue;
        _ = try reportAccessorAny(c, 7032, proto.name_token, proto.flags, "set accessor lacks a parameter type annotation");
    }
}

fn reportAccessorAny(c: *Checker, code: u16, name_tok: TokenIndex, flags: u32, why: []const u8) Error!bool {
    if (name_tok == 0) return false;
    if (nameIsRecoveredModifier(c, name_tok)) return false;
    // `isPrivateWithinAmbient`, as everywhere else in this file.
    const private = flags & ast.Flags.private != 0 or
        c.tree.tokens.tag(name_tok) == .private_identifier;
    if (private and inAmbientContext(c)) return false;
    try c.diagFmt(code, c.tokSpan(name_tok), "Property '{s}' implicitly has type 'any', because its {s}.", .{
        c.tokenText(name_tok), why,
    });
    return true;
}

/// The other half of `m`'s accessor pair — the member with the same name and the
/// same static-ness carrying `want` (`Flags.get` / `Flags.set`).
fn accessorPartner(c: *Checker, members: []const Node, m: Node, name: Atom, flags: u32, want: u32) Error!?Node {
    for (members) |o| {
        if (o == m or o == null_node or c.nodeTag(o) != .class_method) continue;
        const op = c.tree.extraData(ast.FnProto, c.tree.nodeData(o).lhs);
        if (op.flags & want == 0) continue;
        if (op.flags & ast.Flags.static != flags & ast.Flags.static) continue;
        if ((try c.memberAtom(op.name_token)) != name) continue;
        return o;
    }
    return null;
}

/// TS7032 at an accessor NAME token, for callers outside this file that do
/// their own pairing — an OBJECT LITERAL's accessors, which have no member
/// list to walk (`signatures.reportLoneObjectLiteralSetter`).
pub fn reportSetAccessorImplicitAny(c: *Checker, name_tok: TokenIndex) Error!void {
    if (!c.prog.no_implicit_any) return;
    _ = try reportAccessorAny(c, 7032, name_tok, 0, "set accessor lacks a parameter type annotation");
}

/// Does this accessor's first parameter carry a type annotation?
pub fn paramIsAnnotated(c: *Checker, proto: ast.FnProto) bool {
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node) continue;
        return switch (c.nodeTag(p)) {
            // `.param` carries its annotation in `rhs` directly; `.param_full`
            // is the form with `?`/`...`/an initializer/modifiers.
            .param => c.tree.nodeData(p).rhs != 0,
            .param_full => c.tree.extraData(ast.ParamFull, c.tree.nodeData(p).rhs).type_ann != 0,
            else => false,
        };
    }
    // No parameter at all — a grammar error tsc reports on its own; the property
    // type question never arises.
    return true;
}

/// The MEMBER member of the family: a property with neither a type annotation
/// nor an initializer to infer from falls to `any`, and tsc reports TS7008 at
/// its name (`reportImplicitAny`'s `PropertyDeclaration`/`PropertySignature`
/// arm). Covers a class field, an interface property signature and a type
/// literal's property alike — the three forms that share tsc's
/// `widenTypeForVariableLikeDeclaration` fallback.
///
/// A `private` member of an AMBIENT declaration is exempt for the same reason
/// its parameters are (`isPrivateAmbientMember`): a `.d.ts` cannot spell the
/// type of something no consumer can name.
pub fn reportMemberImplicitAny(c: *Checker, name_tok: TokenIndex, flags: u32) Error!void {
    if (!c.prog.no_implicit_any) return;
    if (nameIsRecoveredModifier(c, name_tok)) return;
    // `isPrivateWithinAmbient` counts a `#name` member as private too — it is
    // even less nameable from outside than a `private` one.
    const private = flags & ast.Flags.private != 0 or
        c.tree.tokens.tag(name_tok) == .private_identifier;
    if (private and inAmbientContext(c)) return;
    try c.diagFmt(7008, c.tokSpan(name_tok), "Member '{s}' implicitly has an 'any' type.", .{c.tokenText(name_tok)});
}

/// Is this member's "name" actually a MODIFIER the parser recovered from?
///
/// `interface I { public a: any }`, `interface I { static [k: string]: number }`
/// and `class C { get \n x() {} }` are all grammar errors tsc reports as such
/// (TS1044/TS1070/…); ztsc's parser recovers by reading the modifier keyword as
/// a property NAME, which leaves behind a member that is un-annotated by
/// accident. Reporting an implicit `any` for it is an artifact of the recovery,
/// not something the source said, so the whole family stays quiet there.
///
/// The cost is a real property whose name happens to be a modifier keyword AND
/// that carries no annotation (`interface I { get }`), which loses its TS7008.
fn nameIsRecoveredModifier(c: *Checker, name_tok: TokenIndex) bool {
    return switch (c.tree.tokens.tag(name_tok)) {
        .keyword_public,
        .keyword_private,
        .keyword_protected,
        .keyword_static,
        .keyword_readonly,
        .keyword_abstract,
        .keyword_declare,
        .keyword_override,
        .keyword_accessor,
        .keyword_get,
        .keyword_set,
        .keyword_constructor,
        => true,
        else => false,
    };
}

/// The VARIABLE member of the family, for the two shapes that have no flow to
/// fall back on. tsc gives an un-annotated, un-initialized `var`/`let` the
/// control-flow-tracked `autoType` — but only when it is neither AMBIENT nor
/// EXPORTED (`!(getCombinedModifierFlags(declaration) & Export) &&
/// !(declaration.flags & Ambient)`), because neither can be flow-analyzed: one
/// describes something the runtime already provides, the other something another
/// file may write. Both are plain `any`, reported at the name.
///
/// Everything else stays silent here: `var x;` in a function or at a module's
/// top level IS auto-typed, and tsc reports only where a READ cannot be resolved
/// (TS7034 at the declaration + TS7005 at that read — see
/// `expr.checkEvolvingVarRead`).
pub fn reportVarImplicitAny(c: *Checker, name_node: Node, ambient: bool) Error!void {
    if (!c.prog.no_implicit_any) return;
    if (name_node == null_node or c.nodeTag(name_node) != .identifier) return;
    const tok = c.tree.nodeMainToken(name_node);
    if (!ambient and !inAmbientContext(c) and !isExportedName(c, tok)) return;
    try c.diagFmt(7005, c.tokSpan(tok), "Variable '{s}' implicitly has an 'any' type.", .{c.tokenText(tok)});
}

/// Does the name declared at `tok` carry `export`? Asked of the SYMBOL, because
/// the modifier sits on the statement and the declarator does not see it.
fn isExportedName(c: *Checker, tok: TokenIndex) bool {
    const a = c.atomOfToken(tok) catch return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |sym| c.symFlags(sym).exported,
        else => false,
    };
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
