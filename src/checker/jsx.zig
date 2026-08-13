//! JSX (`.tsx`) element and attribute checking.
//!
//! A JSX element's *type* is always `JSX.Element`; everything here exists to
//! type its tag and check its attributes. Intrinsic tags (`<div>`) take their
//! props from `JSX.IntrinsicElements[tag]`, component tags (`<Foo>`) from the
//! component's first parameter — a call signature's, or a class component's
//! `props` member — with generic components inferring their type arguments
//! from the attributes ("attributes object as the sole argument"). Attributes
//! are then checked like an object literal assigned to that props type, with
//! spreads, `children`, and `IntrinsicAttributes`/`IntrinsicClassAttributes`
//! folded in.
//!
//! The `JSX` namespace itself is resolved from the classic global (`JSX.*`)
//! and, failing that, through the automatic-runtime fallback: the configured
//! JSX import source's `JSX` namespace (`react/jsx-runtime`), so a project on
//! `"jsx": "react-jsx"` with no global `JSX` still resolves `JSX.Element`,
//! `JSX.IntrinsicElements`, and friends.
//!
//! Split out of `expr.zig`, which re-exports every symbol below so the
//! `Checker` method aliases in `checker.zig` keep resolving.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const modules = @import("../link/modules.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const Span = source.Span;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const containsAtom = @import("expr.zig").containsAtom;
const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const NsContainer = @import("typespace.zig").NsContainer;
const tpIndex = @import("calls.zig").tpIndex;

pub fn checkJsxElement(c: *Checker, node: Node) Error!TypeId {
    // A JSX element's *type* is unconditionally `JSX.Element` (see the
    // return below): it does not depend on the tag's props, the attribute
    // values, or the children. Everything between here and that return
    // exists solely to raise diagnostics — and `diagFmt` files every
    // diagnostic under `cur_file`, which `seal` drops unless this checker
    // owns it. So in a file this checker does not own (reached only by
    // materializing a dependency's inferred type) the whole body is dead
    // work: same answer, discarded diagnostics.
    //
    // This is where the check phase's cross-checker duplication
    // concentrated: at `--checkers=4` each checker walked the JSX trees of
    // ~450 files it did not own, re-running props resolution and generic
    // component inference (`inferJsxTargs`) that another checker was
    // running anyway. Output is byte-identical for any `--checkers=N`
    // because the value produced here is `JSX.Element` either way.
    if (!c.owned_mask[c.cur_file]) return (try c.jsxNamespaceType(c.atom_Element)) orelse types.any_type;
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    var props: TypeId = types.no_type; // no_type = unknown target (skip attr typing)
    var is_component = false;
    if (e.tag == null_node) {
        // Fragment `<>…</>`: no attributes, no props.
    } else if (c.isIntrinsicJsxTag(e.tag)) {
        const tag_atom = try c.atomOfToken(c.tree.nodeMainToken(e.tag));
        if (try c.jsxNamespaceType(c.atom_IntrinsicElements)) |ie| {
            if (try c.propOfType(try c.resolveStructural(ie), tag_atom)) |p| {
                props = p.ty;
            } else {
                try c.diagFmt(2339, c.nodeSpan(e.tag), "Property '{s}' does not exist on type 'JSX.IntrinsicElements'.", .{c.atomText(tag_atom)});
            }
        } else {
            // tsc's `getIntrinsicTagSymbol`: with no `JSX.IntrinsicElements`
            // in scope the intrinsic tag's props type is the error type, and
            // under `noImplicitAny` that is reported as TS7026 — the JSX
            // counterpart of the implicit-'any' family. A `.tsx` file with no
            // JSX namespace at all (no React typings, `jsx: preserve`) is the
            // common shape; ztsc silently typed the props as "unknown target".
            //
            // The report is per TAG REFERENCE, not per element: tsc resolves
            // the closing tag name independently, so `<a></a>` reports twice.
            // Fragments (`<>…</>`) resolve no tag and never report.
            try jsxIntrinsicImplicitAny(c, c.tree.nodeMainToken(node));
            if (e.close_lt != 0) try jsxIntrinsicImplicitAny(c, e.close_lt);
        }
    } else {
        is_component = true;
        const tag_ty = try c.checkExprCached(e.tag, types.no_type);
        // Explicit type arguments on the tag (`<Select<string> …>`): resolve
        // them and instantiate the component signature so props (and the
        // contextual types of attribute handlers) become concrete.
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        for (c.tree.extraRange(e.targs_start, e.targs_end)) |tn| {
            if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
        }
        props = (try c.jsxComponentProps(tag_ty, targs.items, node)) orelse types.no_type;
    }
    try c.checkJsxAttributes(node, e, props, is_component, c.jsxChildrenPresent(e));
    // tsc's `getContextualTypeForChildJsxExpression`: a JSX child EXPRESSION is
    // contextually typed by the `JSX.ElementChildrenAttribute` prop (usually
    // `children`) of the tag's attributes type — the same type the identical
    // value written as an explicit `children={…}` attribute would get.
    // ztsc typed children at no context at all, so the RENDER-PROP idiom
    // (`children: Node | ((state: State) => Node)`, which every social-app
    // `Link`/`Button`/`Toggle.Item` is written with) left the arrow's
    // parameters implicit `any` — TS7006 at each one.
    //
    // With ONE semantic child the field type types it directly; with several,
    // tsc maps the field type through each ARRAY-LIKE constituent's element at
    // that child's position (`mapType(childFieldType, t => isArrayLikeType(t) ?
    // getIndexedAccessType(t, getNumberLiteralType(childIndex)) : t)`) and
    // leaves the non-array constituents alone. Without the multi-child half,
    // `<PagerWithHeader>{a}{b}{c}</PagerWithHeader>` — whose `children` is
    // `(((p: P) => JSX.Element) | null)[] | ((p: P) => JSX.Element)` — left
    // each render prop's destructured parameter implicit `any`.
    const child_field: TypeId = blk: {
        if (!is_component or props == types.no_type) break :blk types.no_type;
        const rt = try c.resolveStructural(props);
        if (rt == types.no_type) break :blk types.no_type;
        break :blk try c.ctxPropType(rt, rt, try c.jsxChildrenAttrName());
    };
    const single_child = c.jsxSemanticChildCount(e) == 1;
    var child_i: u32 = 0;
    for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
        const semantic = c.jsxChildIsSemantic(ch);
        defer if (semantic) {
            child_i += 1;
        };
        switch (c.nodeTag(ch)) {
            .jsx_expr_container => {
                const cd = c.tree.nodeData(ch);
                if (cd.lhs == null_node) continue;
                const child_ctx: TypeId = if (child_field == types.no_type)
                    types.no_type
                else if (single_child)
                    child_field
                else
                    try c.jsxChildCtxAt(child_field, child_i);
                _ = try c.checkExprCached(cd.lhs, child_ctx);
            },
            .jsx_element => _ = try c.checkJsxElement(ch),
            else => {}, // jsx_text
        }
    }
    return (try c.jsxNamespaceType(c.atom_Element)) orelse types.any_type;
}

/// TS7026 at one intrinsic-tag reference (`lt` = the tag's `<`), raised when
/// `JSX.IntrinsicElements` does not resolve. Gated on `noImplicitAny` exactly
/// like the rest of the TS70xx family.
fn jsxIntrinsicImplicitAny(c: *Checker, lt: TokenIndex) Error!void {
    if (!c.prog.no_implicit_any) return;
    try c.diagFmt(7026, c.tokSpan(lt), "JSX element implicitly has type 'any' because no interface 'JSX.IntrinsicElements' exists.", .{});
}

/// Whether a JSX tag node is an intrinsic element (simple lowercase-initial
/// identifier). Uppercase or dotted names are component values.
pub fn isIntrinsicJsxTag(c: *Checker, tag: Node) bool {
    if (c.nodeTag(tag) != .identifier) return false;
    const text = c.tokenText(c.tree.nodeMainToken(tag));
    return text.len > 0 and text[0] >= 'a' and text[0] <= 'z';
}

/// Resolve the type `JSX.<member>` (e.g. `JSX.Element`,
/// `JSX.IntrinsicElements`) from the global `JSX` namespace, or null when
/// no such namespace/member exists.
pub fn jsxNamespaceType(c: *Checker, member: Atom) Error!?TypeId {
    const g = (try c.jsxNamespaceMember(member)) orelse return null;
    return try c.namedTypeFromSymbol(g, &.{}, 0);
}

/// The (global) symbol for `JSX.<member>`, or null when the namespace or
/// member is absent. Existence checks use this directly so generic members
/// (e.g. `IntrinsicClassAttributes<T>`) are never instantiated bare.
pub fn jsxNamespaceMember(c: *Checker, member: Atom) Error!?SymbolId {
    if (try jsxFactoryNamespaceMember(c, member)) |g| return g;
    switch (c.resolveSpace(c.atom_JSX, c.cur_scope, false)) {
        .sym => |s| if (try jsxNamespaceSym(c, s)) |ns| {
            if (nsTypeMember(c, ns, member)) |g| return g;
        },
        else => {},
    }
    return try jsxRuntimeNamespaceMember(c, member);
}

/// The namespace a symbol that NAMES the JSX namespace denotes: itself when it
/// is a namespace declaration, else the namespace an entity-name `import`
/// alias stands for. preact publishes its namespace as
/// `export import JSX = JSXInternal` (module-level, and again inside
/// `declare global`), which is an import binding rather than a
/// `namespace_decl`: without the second arm the whole namespace (Element,
/// IntrinsicElements, …) resolved to nothing and every `<div>` lost its props
/// type — then reported TS7026.
fn jsxNamespaceSym(c: *Checker, sym: SymbolId) Error!?SymbolId {
    if (c.symFlags(sym).namespace_decl) return sym;
    return switch ((try c.importEqualsEntityContainer(sym)) orelse return null) {
        .ns => |n| n,
        .module => null,
    };
}

/// Exported type-space member `member` of JSX namespace `ns_sym`, or null.
///
/// Through `namespaceMemberSym`, so a `JSX` namespace declared in more than
/// one file is looked up in its MERGED member index. Reaching into one
/// declaration's body scope directly (`namespaceScopeOf` on the merged
/// symbol's representative constituent) saw only that file's members: a
/// project that adds its own custom elements with a script `declare namespace
/// JSX { interface IntrinsicElements { "em-emoji": any } }` shadowed the whole
/// React/preact `IntrinsicElements`, and every `<div>` in the project became
/// TS2339.
fn nsTypeMember(c: *Checker, ns_sym: SymbolId, member: Atom) ?SymbolId {
    const g = c.namespaceMemberSym(ns_sym, member) orelse return null;
    const mf = c.symFlags(g);
    return if (mf.exported and hasTypeMeaning(mf)) g else null;
}

/// `<jsxFactory-root>.JSX.<member>` — tsc's `getJsxNamespaceAt` step between
/// the automatic-runtime container and the global `JSX`. With
/// `jsxFactory: "MyLib.createElement"` the namespace that types every
/// intrinsic element is `MyLib.JSX`, so a library that ships its factory and
/// its `JSX.IntrinsicElements` together (the inline-factory idiom) needs no
/// global namespace at all. Null when `jsxFactory` is unset — tsc's default
/// root is `React`, but ztsc already reaches @types/react 19's namespace
/// through the jsx-runtime module and 18's through the global it declares,
/// so probing `React.JSX` unprompted would only add work.
fn jsxFactoryNamespaceMember(c: *Checker, member: Atom) Error!?SymbolId {
    if (c.atom_jsx_factory_ns == 0) return null;
    const root = switch (c.resolveSpace(c.atom_jsx_factory_ns, c.cur_scope, false)) {
        .sym => |s| s,
        else => return null,
    };
    const f = c.symFlags(root);
    const ct: NsContainer = if (f.namespace_decl)
        .{ .ns = root }
    else if (f.import_binding) blk: {
        if (c.importTarget(root)) |t| break :blk c.containerFromImportTarget(t) orelse return null;
        break :blk (try c.importEqualsEntityContainer(root)) orelse return null;
    } else return null;
    const jsx_ns = c.nestNsContainer(ct, c.atom_JSX) orelse return null;
    const g = c.containerMemberSym(jsx_ns, member) orelse return null;
    const mf = c.symFlags(g);
    return if (mf.exported and hasTypeMeaning(mf)) g else null;
}

/// tsc's `getJsxNamespaceContainerForImplicitImport`. Under `jsx: "react-jsx"`
/// the namespace is an *export* of the `<jsxImportSource>/jsx-runtime` module
/// rather than a global — @types/react 19 dropped
/// `declare global { namespace JSX }` entirely, so the global lookup finds
/// nothing and every intrinsic element would type its props as "unknown
/// target" (no contextual type for `onChange={(e) => …}`, no TS2339 for a
/// bogus tag). The driver puts that module in the program and hands its FileId
/// over as `Program.jsx_runtime_file`.
pub fn jsxRuntimeNamespaceMember(c: *Checker, member: Atom) Error!?SymbolId {
    const f = c.prog.jsx_runtime_file;
    if (f == modules.no_file or c.prog.links.len == 0) return null;
    const ns_tgt = c.prog.links[f].exportTarget(c.atom_JSX) orelse return null;
    const ns_sym0 = c.targetTypeSym(ns_tgt) orelse return null;
    const ns_sym = (try jsxNamespaceSym(c, ns_sym0)) orelse return null;
    return nsTypeMember(c, ns_sym, member);
}

/// Props type of a component tag. Function components: the first parameter
/// of the call signature. Class components (`class C extends Component<P>`):
/// the member of the instance type named by `JSX.ElementAttributesProperty`
/// (typically `props`). Null when it has no discernible props (so attribute
/// typing is skipped).
pub fn jsxComponentProps(c: *Checker, tag_ty: TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
    const t = try c.resolveStructural(tag_ty);
    if (c.ts.kind(t) == .class_value) return c.jsxClassComponentProps(t, explicit_targs, node);
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    try collectJsxCallSigs(c, t, &sigs);
    if (sigs.items.len == 0) return null;
    if (sigs.items.len == 1) return try jsxPropsOfSig(c, sigs.items[0], explicit_targs, node);
    return try chooseJsxSignature(c, sigs.items, explicit_targs, node);
}

/// The call signatures a component tag offers, in declaration order — the list
/// tsc's `resolveJsxOpeningLikeElement` hands to `resolveCall`.
fn collectJsxCallSigs(c: *Checker, t: TypeId, out: *std.ArrayList(TypeId)) Error!void {
    switch (c.ts.kind(t)) {
        .function => try out.append(c.scratch(), t),
        .overloads => try out.appendSlice(c.scratch(), try c.memberList(t)),
        // A callable *object* — a call-signature-bearing interface used as a
        // component. styled-components' `StyledComponentBase` is this shape,
        // with two: `(props: P & { as?: never })` and the polymorphic
        // `<AsC>(props: P & { as?: AsC })` behind it.
        .object => for (0..c.ts.objectCallSigCount(t)) |i| {
            try out.append(c.scratch(), c.ts.objectCallSig(t, @intCast(i)));
        },
        // A function merged with a namespace
        // (`declare function Icon(…); declare namespace Icon { … }`) types as
        // an *intersection* of the function value and the namespace object
        // (`computeTypeOfSymbol`). Pull the props from the callable
        // constituent; without this the whole props target is dropped and
        // every attribute goes unchecked (missing/excess/value all silently
        // pass — e.g. a bad `<Icon name>` slips through).
        .intersection => for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            switch (c.ts.kind(rm)) {
                .function, .overloads, .object => {
                    try collectJsxCallSigs(c, rm, out);
                    if (out.items.len > 0) return;
                },
                else => {},
            }
        },
        else => {},
    }
}

/// A JSX element with a MULTI-SIGNATURE component type is resolved the way a
/// call is: tsc builds the attributes object and runs `resolveCall` over the
/// whole signature list, taking the first candidate it satisfies.
///
/// ztsc took `sigs[0]` unconditionally, which is wrong for exactly the shape
/// the polymorphic-`as` idiom is built out of. styled-components declares
///
///     (props: Own & { as?: never | undefined }): Element;
///     <AsC extends string>(props: Own & { as?: AsC | undefined }): Element;
///
/// so `<Styled as="p">` has to fall through to the second signature; against
/// the first it read `Type '"p"' is not assignable to type 'undefined'`, once
/// per styled element in the program.
///
/// The acceptance test is the reporting walk itself, run with its diagnostics
/// withdrawn — the same trick `argumentsMatch` plays for a call argument, and
/// for the same reason: a probe must reject exactly what the report would
/// complain about, or a candidate is accepted and then diagnosed. The
/// withdrawal is scoped to the element's own source range, so a diagnostic the
/// probe merely triggered while materializing some other declaration survives,
/// and `no_publish_depth` keeps a declined candidate's contextual reading of an
/// attribute out of the `node_types` memo.
///
/// The instantiation budget is deliberately NOT refunded, unlike the call
/// path's, where a candidate probing a wide union constraint could bankrupt the
/// overload behind it. A refund means `newBudgetWindow`, whose fresh epoch
/// invalidates memoized types program-wide; a JSX candidate's probe is one
/// attributes relation, bounded by the element's attribute count rather than by
/// a library's type graph, so there is nothing here worth that reach. Measured
/// both ways on outline: identical key sets.
fn chooseJsxSignature(c: *Checker, sigs: []const TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    const has_children = c.jsxChildrenPresent(e);
    const elem = c.nodeSpan(node);
    var last: ?TypeId = null;
    for (sigs) |s| {
        const props = (try jsxPropsOfSig(c, s, explicit_targs, node)) orelse continue;
        last = props;
        const saved = c.diags.items.len;
        c.no_publish_depth += 1;
        {
            errdefer c.no_publish_depth -= 1;
            try c.checkJsxAttributes(node, e, props, true, has_children);
        }
        c.no_publish_depth -= 1;
        var rejected = false;
        for (c.diags.items[saved..]) |d| {
            if (d.file != c.cur_file) continue;
            if (d.span.start < elem.start or d.span.start >= elem.end) continue;
            rejected = true;
            break;
        }
        c.rollbackDiags(saved, .{ .file = c.cur_file, .lo = elem.start, .hi = elem.end });
        if (!rejected) return props;
    }
    // No candidate is clean. tsc reports out of the last one it tried, so the
    // element is checked (and diagnosed) against that one's props.
    return last;
}

/// The props type a single component signature exposes: its first parameter,
/// with type arguments bound.
fn jsxPropsOfSig(c: *Checker, sig_in: TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
    var sig = sig_in;
    // Bind explicit type arguments (`<Select<string> …>`) into the signature
    // so the props type is concrete. Mirrors the explicit-targ path of a
    // generic call; a count mismatch reports TS2558 there. With no explicit
    // args, a *generic* component's type params are inferred from the
    // attributes (tsc's "attributes object as the sole argument" model) —
    // without this `<Controller name control render>` keeps its props type
    // generic, so `control={control}` relates `Control<Form>` against the
    // still-free `Control<TFieldValues>` and its deferred `_defaultValues`
    // mapped-over-conditional spuriously fails (TS2322).
    if (explicit_targs.len > 0) {
        sig = try c.instantiateSigForCall(sig, explicit_targs, &.{}, node, types.no_type);
    } else if (c.ts.fnTypeParams(sig).len > 0) {
        const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        sig = try c.inferJsxTargs(sig, tps, e);
    }
    if (c.ts.fnParamCount(sig) == 0) return types.empty_object_type;
    // A props parameter that is OPTIONAL at the call site (`p?: Props`, or
    // `{ a }: Props = {}` — the "usable with no props at all" component
    // shape) carries `| undefined` in the signature, exactly as tsc's
    // `getTypeOfParameter` adds it. tsc then folds that union through
    // `intersectTypes(IntrinsicAttributes, props)`, whose `extractIrreducible`
    // pulls the `undefined` back OUT of the intersection: the props target
    // is `(IntrinsicAttributes & Props) | undefined`, and since a JSX
    // attributes object is never `undefined`, every check lands on the
    // object constituent. ztsc has no intersection step here, so strip the
    // nullish constituents directly. Leaving them in made the target a
    // UNION, which `checkJsxAttributes` treats as a lenient shape: the
    // missing/excess checks were skipped outright, and `propOfType` on the
    // union lost each prop's OPTIONAL flag, so passing a possibly-undefined
    // value to an optional prop was rejected (TS2322).
    const p0 = c.ts.fnParam(sig, 0).ty;
    const stripped = try c.nonNullableNullish(p0);
    return if (stripped == types.never_type) p0 else stripped;
}

/// Infer a generic component's type arguments from its JSX attributes,
/// mirroring tsc's "attributes object as the sole argument" model, then
/// return the signature instantiated with them. Only non-function attribute
/// values drive inference (a `render` callback is contextually typed, not a
/// Phase-1 inference source). A param no attribute constrains falls back to
/// its default, else its constraint, else `unknown` — so an un-inferred
/// `Controller<TFieldValues, TName>` resolves to concrete
/// `ControllerProps<Form, FieldPath<Form>, …>` whose props relate reflexively.
pub fn inferJsxTargs(c: *Checker, sig: TypeId, tps: []const u32, e: ast.JsxElementData) Error!TypeId {
    if (c.ts.fnParamCount(sig) == 0) return sig;
    const rp0 = try c.resolveStructural(c.ts.fnParam(sig, 0).ty);
    const candidates = try c.scratch().alloc(TypeId, tps.len);
    for (candidates) |*x| x.* = types.no_type;
    // Phase 1: unify each non-function attribute value against its target prop.
    for (c.tree.extraRange(e.attrs_start, e.attrs_end)) |attr| {
        if (c.nodeTag(attr) == .jsx_spread_attribute) continue;
        const name_tok = c.tree.nodeMainToken(attr);
        if (c.tree.tokens.tag(name_tok) == .jsx_name) continue; // hyphenated data-*/aria-*
        const ad = c.tree.nodeData(attr);
        // Skip a function-valued attribute (`render={() => …}`): a callback is
        // contextually typed, not a raw inference source, and typing it here
        // context-free would pollute the candidates.
        if (ad.lhs != null_node and c.nodeTag(ad.lhs) == .jsx_expr_container) {
            const cd = c.tree.nodeData(ad.lhs);
            if (cd.lhs != null_node and (c.nodeTag(cd.lhs) == .arrow_fn or c.nodeTag(cd.lhs) == .function_expr)) continue;
        }
        const pt = (try c.propOfType(rp0, try c.memberAtom(name_tok))) orelse continue;
        // A TEMPLATE-LITERAL attribute value is contextually typed by the
        // target prop, exactly as `inferTypeArgs`' Phase 1 does for a
        // template-expression argument: `ctxWantsTemplate` needs to see the
        // string-like-constrained type param to keep `` `owners.${number}.status` ``
        // a template-literal type. Checked context-free it widens to `string`,
        // which fails `TName extends FieldPath<TFieldValues>`, so `TName` fell
        // back to its default — the whole path union — and react-hook-form's
        // `<Controller name={`a.${i}.b`} …/>` typed `field.value` as the union
        // of EVERY field's value. Every other attribute shape keeps its
        // context-free inference (its contextual pass is `checkJsxAttributes`').
        const vctx: TypeId = blk: {
            if (ad.lhs == null_node or c.nodeTag(ad.lhs) != .jsx_expr_container) break :blk types.no_type;
            const cd = c.tree.nodeData(ad.lhs);
            if (cd.lhs == null_node) break :blk types.no_type;
            break :blk switch (c.nodeTag(cd.lhs)) {
                .template_expr => pt.ty,
                // An object/array-literal attribute whose target prop carries
                // a literal-constrained inference target keeps its literals —
                // the same gate `inferTypeArgs`' Phase 1 applies to an
                // object-literal ARGUMENT (`paramWantsLiteralCtx`). Without it
                // `options={[{ value: Breed.Nellore }, …]}` is checked
                // context-free, the enum members widen to the whole enum and
                // `T extends string` is inferred as `Breed`.
                .object_literal, .array_literal => if (try c.paramWantsLiteralCtx(pt.ty)) pt.ty else types.no_type,
                else => types.no_type,
            };
        };
        const vty = try c.jsxAttributeValueType(ad.lhs, vctx);
        try c.unify(pt.ty, vty, tps, candidates, 0);
    }
    // Resolve each param: inferred candidate (clamped to its constraint when
    // it violates it), else default, else constraint, else `unknown`. Mirrors
    // the final resolution loop of `inferTypeArgs`, threading each resolved
    // arg into `prov` so a later param's constraint (`TName extends
    // FieldPath<TFieldValues>`) sees the earlier one substituted.
    const args_buf = try c.scratch().alloc(TypeId, tps.len);
    const prov = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| prov[i] = .{ .sym = tp, .ty = if (candidates[i] != types.no_type) candidates[i] else types.any_type };
    for (tps, 0..) |tp, i| {
        var constraint: TypeId = try c.typeParamConstraint(tp);
        if (constraint != types.no_type) constraint = try c.instantiate(constraint, prov);
        if (candidates[i] != types.no_type) {
            args_buf[i] = candidates[i];
            const bare_outer = constraint != types.no_type and
                c.ts.kind(constraint) == .type_param and
                tpIndex(tps, c.ts.typeParamSymbol(constraint)) == null;
            // An `any`-valued index-signature constraint (`TFieldValues
            // extends FieldValues`, `FieldValues = Record<string, any>`) is
            // satisfied by any object candidate: tsc admits a named interface
            // there (every member is trivially assignable to `any`), so the
            // attribute-derived candidate must NOT be clamped down to
            // `FieldValues`. ztsc's general object→`{[x:string]:any}` relation
            // still rejects a named interface (a separate, unrelated gap), so
            // the clamp is bypassed explicitly here. Without this, `Controller`
            // resolves `TFieldValues` to `FieldValues`, its `_defaultValues`
            // stays `{[x:string]:any}`, and `control={control}` fails (TS2322).
            const any_index_ok = try c.constraintIsAnyIndex(constraint) and
                c.ts.kind(try c.resolveStructural(candidates[i])) == .object;
            if (constraint != types.no_type and !bare_outer and !any_index_ok and
                !try c.isAssignable(candidates[i], constraint))
            {
                args_buf[i] = (try c.clampToConstraint(candidates[i], constraint)).ty;
            }
        } else if (c.typeParamHasDefault(tp)) {
            args_buf[i] = try c.instantiate(try c.typeParamDefault(tp), prov);
        } else {
            args_buf[i] = if (constraint != types.no_type) constraint else types.unknown_type;
        }
        prov[i].ty = args_buf[i];
    }
    const map = try c.scratch().alloc(TpMap, tps.len);
    for (tps, 0..) |tp, i| map[i] = .{ .sym = tp, .ty = args_buf[i] };
    return c.instantiate(sig, map);
}

/// Props of a class component: read the member named by
/// `JSX.ElementAttributesProperty` (its single member's name, e.g. `props`)
/// off the class instance type. Null when the selector namespace is absent
/// (tsc leaves such attributes unchecked).
///
/// A GENERIC class component takes the same route tsc does for a generic
/// function component: tsc resolves `<C …/>` as a call against `typeof C`'s
/// construct signatures (`resolveJsxOpeningLikeElement`), so the class's own
/// type parameters are the signature's, inferred from the attributes object;
/// `getJsxPropsTypeForSignatureFromMember` then reads `props` off the
/// signature's RETURN — the instantiated instance type. Modelled here by
/// synthesising exactly that signature (`(props: P<T…>) => C<T…>`) and handing
/// it to `inferJsxTargs`, the same inference the function-component path uses.
///
/// react-native's lists are the shape this unblocks: `class FlatList<ItemT =
/// any> extends FlatListComponent<ItemT, FlatListProps<ItemT>>`. Bailing out
/// left the whole attributes target unknown — not merely `ItemT = any` — so
/// EVERY callback attribute lost its contextual type, `keyExtractor={(item,
/// index) => …}` and `onScroll={e => …}` alike (TS7006 on each parameter).
pub fn jsxClassComponentProps(c: *Checker, class_val: TypeId, explicit_targs: []const TypeId, node: Node) Error!?TypeId {
    const name = (try c.jsxPropsMemberName()) orelse return null;
    const cls = c.ts.classSymbol(class_val);
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(cls, &tps);
    if (tps.items.len != 0) return jsxGenericClassComponentProps(c, cls, tps.items, name, explicit_targs, node);
    const inst = try c.ts.makeRef(cls, &.{});
    const rinst = try c.resolveStructural(inst);
    if (try c.propOfType(rinst, name)) |p| return try c.withIntrinsicClassAttributes(p.ty, inst);
    // No resolvable props member — a modeling gap, not a genuinely
    // props-less component (an empty `Component<{}>` still yields a `props`
    // member above). This surfaces for class components whose base is a
    // class+interface declaration merge we don't fully fold (`@types/react`
    // `Component<P>` merges `interface Component extends ComponentLifecycle`
    // with `class Component { readonly props: Readonly<P> }`). Leave the
    // attributes unchecked (tsc's behavior for an unknown props target)
    // rather than reject every attribute against `{}` — under-report over a
    // false positive.
    return null;
}

/// The generic half of `jsxClassComponentProps` (see its doc comment): infer
/// the class's own type arguments from the attributes, then read `props` off
/// the instantiated instance.
///
/// Explicit type arguments (`<FlatList<Img> …/>`) short-circuit the inference,
/// exactly as they do on the function-component path. A count mismatch falls
/// back to inference rather than reporting — the JSX path has no TS2558 site.
fn jsxGenericClassComponentProps(
    c: *Checker,
    cls: SymbolId,
    tps: []const TypeParamInfo,
    name: Atom,
    explicit_targs: []const TypeId,
    node: Node,
) Error!?TypeId {
    const inst = blk: {
        if (explicit_targs.len == tps.len) break :blk try c.ts.makeRef(cls, explicit_targs);
        // `(props: P<T…>) => C<T…>` written in the class's own parameters —
        // tsc's construct signature for `typeof C`, whose type parameters ARE
        // the class's. The props member is read off the generic instance, so
        // a base-class `props: Readonly<P>` reaches it through the ordinary
        // heritage fold.
        const tp_syms = try c.scratch().alloc(u32, tps.len);
        const tp_tys = try c.scratch().alloc(TypeId, tps.len);
        for (tps, 0..) |tp, i| {
            tp_syms[i] = tp.sym;
            tp_tys[i] = try c.ts.makeTypeParam(tp.sym);
        }
        const generic_inst = try c.ts.makeRef(cls, tp_tys);
        const gp = (try c.propOfType(try c.resolveStructural(generic_inst), name)) orelse return null;
        const sig = try c.ts.makeFunction(
            &.{.{ .name = name, .ty = gp.ty }},
            generic_inst,
            tp_syms,
            0,
        );
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        break :blk c.ts.fnReturn(try c.inferJsxTargs(sig, tp_syms, e));
    };
    const p = (try c.propOfType(try c.resolveStructural(inst), name)) orelse return null;
    return try c.withIntrinsicClassAttributes(p.ty, inst);
}

/// tsc's `getJsxPropsTypeFromClassType`: a CLASS component's attributes
/// target is `IntrinsicClassAttributes<Instance> & Props` (the
/// `IntrinsicAttributes &` part is added by the shared JSX path). In
/// @types/react that interface is `{ ref?: Ref<T> }`, so without it every
/// `<ClassComp ref={…}>` read `ref` as an EXCESS attribute and the whole
/// element failed with TS2322 — 40+ hits on a React Native codebase, where
/// `View`/`Text`/`ScrollView` are all class components. Returns `props`
/// unchanged when the JSX namespace declares no such interface.
pub fn withIntrinsicClassAttributes(c: *Checker, props: TypeId, inst: TypeId) Error!TypeId {
    const sym = (try c.jsxNamespaceMember(c.atom_IntrinsicClassAttributes)) orelse return props;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    // tsc fills the single type parameter with the host class instance type;
    // a non-generic declaration is used bare.
    const args: []const TypeId = if (tps.items.len == 1) &.{inst} else &.{};
    if (tps.items.len > 1) return props;
    const ica = try c.namedTypeFromSymbol(sym, args, 0);
    if (ica == types.error_type or ica == types.any_type) return props;
    return c.ts.makeIntersection(c.scratch(), &.{ ica, props });
}

/// Name of the props member per `JSX.ElementAttributesProperty` — the name
/// of that interface's single property (React uses `props`). Null when the
/// interface is absent or empty.
pub fn jsxPropsMemberName(c: *Checker) Error!?Atom {
    const t = (try c.jsxNamespaceType(c.atom_ElementAttributesProperty)) orelse return null;
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return null;
    return c.ts.objectProp(rt, 0).name;
}

/// One explicit (literal) JSX attribute gathered during the first pass.
pub const JsxAttr = struct {
    name: Atom,
    ty: TypeId,
    value: Node,
    name_tok: TokenIndex,
    overwritten: bool = false, // shadowed by a later `{...spread}` (TS2783)
};

/// Check a JSX element's attributes against its props type (`no_type` =
/// unknown target, only value expressions are checked). Mirrors tsc's
/// "attributes object assigned to props" model: per-attribute value
/// mismatches report at the value; excess/missing report the whole object.
///
/// Spread attributes (`<C {...p} />`) fold their object's properties into
/// the attribute set (later wins). A spread's props count toward
/// required-prop satisfaction, an explicit attribute overwritten by a later
/// spread's REQUIRED member is TS2783 (an OPTIONAL spread member does not
/// overwrite — tsc's checkSpreadPropOverrides rule), and a non-object
/// spread is TS2698. Where a spread's
/// contents cannot be confidently enumerated (`any`, generics, unions,
/// index signatures) the missing-prop check is skipped rather than risk a
/// false positive — tsc reports fewer such cases than it would with full
/// generic inference, which is out of scope here.
///
/// For component tags the allowed-attribute set is widened by
/// `JSX.IntrinsicAttributes` (so `key`/`ref`-style props do not read as
/// excess), and JSX children satisfy the `JSX.ElementChildrenAttribute`
/// prop (so a required `children` is not spuriously reported missing). We
/// do not type-check children values (lenient; documented).
pub fn checkJsxAttributes(c: *Checker, node: Node, e: ast.JsxElementData, props: TypeId, is_component: bool, has_children: bool) Error!void {
    const attrs = c.tree.extraRange(e.attrs_start, e.attrs_end);
    const rt: TypeId = if (props != types.no_type) try c.resolveStructural(props) else types.no_type;
    // Missing/excess checks run against object targets and intersections
    // of objects (real React's `DetailedHTMLProps<...> = ClassAttributes &
    // P`); anything else (unions, generics, `any`) is handled leniently —
    // only per-attribute value assignability there. `target_props` is the
    // flattened view used by the missing/weak checks.
    var target_props: std.ArrayList(types.Prop) = .empty;
    defer target_props.deinit(c.scratch());
    const shape: JsxTargetShape = if (rt == types.no_type)
        .not_objecty
    else
        try c.jsxTargetShape(rt, &target_props);
    const is_obj_target = shape != .not_objecty;
    const target_open = shape == .open_object;

    // Names allowed but not required on a component via IntrinsicAttributes,
    // plus whether that selector interface exists at all. When it does, a
    // component's effective props target is `IntrinsicAttributes & Props`
    // (an intersection), for which tsc reports missing/excess as plain
    // TS2322 rather than the single-object TS2741/2739 refinement.
    var ia_names: std.ArrayList(Atom) = .empty;
    defer ia_names.deinit(c.scratch());
    var has_intrinsic_attrs = false;
    if (is_component) {
        if ((try c.jsxNamespaceMember(c.atom_IntrinsicAttributes)) != null) {
            has_intrinsic_attrs = true;
            try c.jsxIntrinsicAttrNames(&ia_names);
        }
    }

    var built: std.ArrayList(JsxAttr) = .empty;
    defer built.deinit(c.scratch());
    // Props known to be provided, in source order (explicit attrs +
    // enumerable spread contents + JSX children) — the missing-required
    // check reads the names, the whole-object diagnostics build the
    // combined "attributes object" from it (later wins on duplicates).
    var provided: std.ArrayList(types.Prop) = .empty;
    defer provided.deinit(c.scratch());
    var has_spread = false;
    var spread_opaque = false; // a spread whose props we could not enumerate
    var spread_any = false; // saw a spread of `any` (tsc's `hasSpreadAnyType`)
    var spread_non_object = false; // saw a primitive spread (TS2698)
    var last_spread_ty: TypeId = types.no_type; // for the TS2559 message

    for (attrs) |attr| {
        if (c.nodeTag(attr) == .jsx_spread_attribute) {
            has_spread = true;
            const sd = c.tree.nodeData(attr);
            if (sd.lhs == null_node) continue;
            const sty = try c.resolveStructural(try c.checkExprCached(sd.lhs, types.no_type));
            last_spread_ty = sty;
            if (c.ts.kind(sty) == .any or c.ts.kind(sty) == .err) spread_any = true;
            switch (try c.jsxSpreadInfo(sty, &provided)) {
                .non_object => {
                    spread_non_object = true;
                    try c.diagFmt(2698, c.nodeSpan(sd.lhs), "Spread types may only be created from object types.", .{});
                },
                .unknown_shape => spread_opaque = true,
                .names => |names| {
                    // A prior explicit attr re-provided by this spread is
                    // overwritten → TS2783 (this usage will be overwritten).
                    for (built.items) |*b| {
                        if (b.overwritten) continue;
                        if (containsAtom(names, b.name)) {
                            b.overwritten = true;
                            try c.diagFmt(2783, c.tokSpan(b.name_tok), "'{s}' is specified more than once, so this usage will be overwritten.", .{c.atomText(b.name)});
                        }
                    }
                },
            }
            continue;
        }
        const ad = c.tree.nodeData(attr);
        const name_tok = c.tree.nodeMainToken(attr);
        // Contextual type for the value = the target prop's type (used only
        // for a template-literal expression value; see jsxAttributeValueType).
        // A HYPHENATED name (`data-*`, `aria-*`, `connect-link`) is exempt
        // from the excess-property and assignability checks further down,
        // but not from contextual typing: tsc looks it up in the attributes
        // type like any other name, which for a props type carrying a string
        // index signature yields the index VALUE. Skipping the lookup here
        // left a callback written as a hyphenated attribute with no
        // contextual signature, so its parameters went implicit-any.
        const vctx: TypeId = if (rt != types.no_type) blk: {
            const nm = try c.memberAtom(name_tok);
            // `ctxPropType`, not a bare `propOfType`: a component's props
            // are routinely `Base & (VariantA | VariantB)` (the
            // discriminated-props idiom), and `propOfType` has no union
            // arm, so a prop living in one variant was not found and the
            // attribute value went unctx-typed — a callback attribute's
            // parameters then fell to implicit `any` (TS7006). Object
            // literals already read their contextual property this way.
            break :blk try c.ctxPropType(rt, rt, nm);
        } else types.no_type;
        const vty = try c.jsxAttributeValueType(ad.lhs, vctx);
        // Hyphenated names (`data-*`, `aria-*`) are exempt from excess and
        // assignability checks (tsc), but their value expressions are still
        // checked — `jsxAttributeValueType` above did that.
        if (c.tree.tokens.tag(name_tok) == .jsx_name) continue;
        const name = try c.memberAtom(name_tok);
        try built.append(c.scratch(), .{ .name = name, .ty = vty, .value = ad.lhs, .name_tok = name_tok });
        try provided.append(c.scratch(), .{ .name = name, .ty = vty });
    }

    if (rt == types.no_type) return;

    // tsc's `hasSpreadAnyType` (`createJsxAttributesTypeFromAttributesProperty`):
    // a spread attribute whose type is `any` makes the WHOLE attributes object
    // `any` — `return hasSpreadAnyType ? anyType : spread` — so every check
    // below is answered by that `any`: no per-attribute assignability, no
    // excess property, no missing required prop, no weak type. It is not the
    // same as an un-enumerable spread (a union, a type parameter, an index
    // signature), for which tsc builds a real spread type and keeps checking;
    // only `any` erases the object.
    //
    // The attribute VALUE expressions were still checked in the walk above,
    // which is where tsc checks them too (`checkJsxAttribute` runs for every
    // attribute whether or not the flag is set).
    //
    // `web: (value: any) => any` — an identity-on-web / nothing-on-native
    // helper — is the shape that makes this load-bearing: every
    // `<Button {...web({dataSet: …})} href={href}>` in a react-native app
    // spreads `any`, and tsc checks none of that element's attributes.
    if (spread_any) return;

    // JSX children satisfy the ElementChildrenAttribute prop (usually
    // `children`) on component tags — count it as provided.
    if (is_component and has_children) {
        try provided.append(c.scratch(), .{ .name = try c.jsxChildrenAttrName(), .ty = types.any_type });
    }

    // Per-attribute value assignability + excess, for explicit attrs.
    var first_excess: Span = .{ .start = 0, .end = 0 };
    var have_excess = false;
    // tsc's `checkTypeRelatedToAndOptionallyElaborate`: when the ELABORATION
    // (`elaborateJsxComponents` → `elaborateElementwise`) reported at least one
    // per-attribute error, the top-level `checkTypeRelatedTo` is never run at
    // all — so the whole-attributes-object diagnostics (excess property,
    // missing required prop, weak type) are suppressed by any attribute-level
    // failure. `elaborateElementwise` `continue`s over an attribute the target
    // does not know, so an EXCESS attribute never sets this; only a known prop
    // whose value mismatches does.
    var attr_elaborated = false;
    for (built.items) |b| {
        if (b.overwritten) continue; // shadowed by a later spread (TS2783)
        if (try c.propOfType(rt, b.name)) |p| {
            // tsc anchors a JSX attribute value mismatch at the attribute
            // NAME node (not the value), matching the excess-property anchor
            // above. Per-member elaboration for object/array-literal values
            // still points at the offending member via `b.value` below.
            const vspan = c.tokSpan(b.name_tok);
            // An optional prop (`date?: Date`) admits `undefined`, so an
            // explicit `date={maybeUndefined}` is not an error — mirrors the
            // structural object relation and the optional indexed-access path
            // (src/checker.zig:2864). Widen the target to `p.ty | undefined`
            // ONLY when the value can actually be undefined: a value that
            // never yields `undefined` (e.g. a fresh object literal) gets the
            // identical verdict from bare `p.ty`, and keeping it off the
            // object-to-union path avoids a distinct union-relation gap. A
            // required prop keeps `p.ty`, so an explicit `undefined` on it
            // still rejects.
            const target = if (p.optional() and c.containsUndefinedish(try c.resolveStructural(b.ty)))
                try c.makeUnion2(p.ty, types.undefined_type)
            else
                p.ty;
            if (!try c.checkAssignable(b.ty, target, b.value, vspan)) attr_elaborated = true;
        } else if (try c.unionNestedPropType(rt, b.name)) |nested| {
            // A prop that lives in a UNION member of an intersection props
            // type (`Base & (VariantA | VariantB)`) is not found by
            // `propOfType`, so its value used to go unchecked — and, since
            // the excess arm below only fires for an open target, silently.
            // Check it against the union of the arms that declare it, the
            // same type the attribute's contextual lookup above uses.
            if (!try c.checkAssignable(b.ty, nested, b.value, c.tokSpan(b.name_tok))) attr_elaborated = true;
        } else if (target_open and !containsAtom(ia_names.items, b.name)) {
            if (!have_excess) {
                first_excess = c.tokSpan(b.name_tok);
                have_excess = true;
            }
        }
    }

    if (!is_obj_target) return; // lenient target: value checks only

    // An attribute-level elaboration already reported: tsc stops here (see
    // `attr_elaborated`). This is a real suppression, not a cosmetic one —
    // tsc's error lands on the narrow attribute node, where a `@ts-expect-error`
    // written above that attribute absorbs it, while the whole-object error
    // would land on a line no directive covers.
    if (attr_elaborated) return;

    // When `JSX.IntrinsicAttributes` exists, a component's effective props
    // target is the intersection `IntrinsicAttributes & Props`, for which
    // tsgo reports missing props as plain TS2322 — UNLESS the namespace
    // also declares `IntrinsicClassAttributes` (as @types/react does), in
    // which case tsgo surfaces the refined TS2741/2739 against the plain
    // props type. Empirically bisected against tsgo 7.0.2; matched as
    // observed. Excess is always the plain TS2322 form.
    const raw_2322 = has_intrinsic_attrs and
        (try c.jsxNamespaceMember(c.atom_IntrinsicClassAttributes)) == null;

    if (have_excess) {
        // Excess wins over missing and is never refined to a
        // missing-property code (tsc's message is the excess flavor).
        try c.diagFmt(2322, first_excess, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(try c.jsxAttrsObject(provided.items)),
            try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }

    // Missing required props. When a spread's contents are opaque, any
    // required prop might come from it — skip to avoid a false positive.
    if (has_spread and spread_opaque) return;

    // Weak-type check (TS2559): the target has only optional props and the
    // (spread-provided) attributes share none of them. Fires only for
    // fully-enumerated spread sources — explicit-attr mismatches are excess
    // (TS2322, above), and opaque spreads were already skipped.
    if (has_spread and target_open) {
        var target_weak = target_props.items.len > 0 or ia_names.items.len > 0;
        for (target_props.items) |tp| {
            if (!tp.optional()) {
                target_weak = false;
                break;
            }
        }
        if (target_weak and (spread_non_object or provided.items.len > 0)) {
            var common = false;
            for (provided.items) |pp| {
                if ((try c.propOfType(rt, pp.name)) != null or containsAtom(ia_names.items, pp.name)) {
                    common = true;
                    break;
                }
            }
            if (!common) {
                const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
                const src_ty = if (last_spread_ty != types.no_type) last_spread_ty else try c.jsxAttrsObject(provided.items);
                try c.diagFmt(2559, span, "Type '{s}' has no properties in common with type '{s}'.", .{
                    try c.typeToString(src_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
                });
                return;
            }
        }
    }

    var any_missing = false;
    for (target_props.items) |tp| {
        if (tp.optional()) continue;
        if (!providedHas(provided.items, tp.name)) {
            any_missing = true;
            break;
        }
    }
    if (!any_missing) return;
    const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
    if (spread_non_object) {
        // The attributes' source type is the primitive spread itself —
        // plain TS2322 (a primitive never gets the missing-prop codes).
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(last_spread_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }
    const combined = try c.jsxAttrsObject(provided.items);
    if (raw_2322) {
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(combined), try c.jsxTargetString(props, true),
        });
    } else {
        try c.reportNotAssignable(2322, combined, props, span);
    }
}

/// Build the fresh object type standing in for the written attributes — the
/// combined explicit + spread-provided props, later occurrence winning.
/// Source type of the whole-object TS2322/2741/2739 messages.
pub fn jsxAttrsObject(c: *Checker, provided: []const types.Prop) Error!TypeId {
    var out: std.ArrayList(types.Prop) = .empty;
    defer out.deinit(c.scratch());
    for (provided) |p| {
        // Widened for display (`label="x"` prints as `label: string`,
        // matching tsc's messages); assignability used the fresh types.
        const wty = try c.widenLiteral(p.ty);
        var replaced = false;
        for (out.items) |*o| {
            if (o.name == p.name) {
                o.ty = wty; // later wins
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(c.scratch(), .{ .name = p.name, .ty = wty });
    }
    return c.ts.makeObject(out.items, 0, 0, types.obj_flag_fresh);
}

/// Display string for the props target: `IntrinsicAttributes & <Props>`
/// when the selector interface participates, else just the props type.
pub fn jsxTargetString(c: *Checker, props: TypeId, with_intrinsic: bool) Error![]const u8 {
    const s = try c.typeToString(props);
    if (!with_intrinsic) return s;
    return std.fmt.allocPrint(c.scratch(), "IntrinsicAttributes & {s}", .{s});
}

pub fn providedHas(list: []const types.Prop, name: Atom) bool {
    for (list) |p| if (p.name == name) return true;
    return false;
}

pub const JsxSpread = union(enum) { non_object, unknown_shape, names: []const Atom };

/// Classify a spread attribute's (resolved) type. `.names` are the prop
/// names it definitely contributes (their full props appended to
/// `provided` too); `.unknown_shape` means "unknown contents, could
/// provide anything" (any/union/generic/index-signature); `.non_object`
/// is a primitive (→ TS2698).
pub fn jsxSpreadInfo(c: *Checker, rst: TypeId, provided: *std.ArrayList(types.Prop)) Error!JsxSpread {
    switch (c.ts.kind(rst)) {
        .object => {
            if (c.ts.objectStringIndex(rst) != 0 or c.ts.objectNumberIndex(rst) != 0) return .unknown_shape;
            var names: std.ArrayList(Atom) = .empty;
            for (0..c.ts.objectPropCount(rst)) |i| {
                const p = c.ts.objectProp(rst, @intCast(i));
                // `names` drives the TS2783 overwrite check, which tsc
                // (checkSpreadPropOverrides) fires only for a REQUIRED
                // spread member — an optional prop in the spread does not
                // overwrite a prior explicit attribute. `provided` still
                // gets every prop (required-satisfaction reads all).
                if (!p.optional()) try names.append(c.scratch(), p.name);
                try provided.append(c.scratch(), p);
            }
            return .{ .names = try names.toOwnedSlice(c.scratch()) };
        },
        .intersection => {
            var names: std.ArrayList(Atom) = .empty;
            for (try c.memberList(rst)) |m| {
                const r = try c.resolveStructural(m);
                if (c.ts.kind(r) != .object or c.ts.objectStringIndex(r) != 0 or c.ts.objectNumberIndex(r) != 0) {
                    names.deinit(c.scratch());
                    return .unknown_shape;
                }
                for (0..c.ts.objectPropCount(r)) |i| {
                    const p = c.ts.objectProp(r, @intCast(i));
                    if (!p.optional()) try names.append(c.scratch(), p.name);
                    try provided.append(c.scratch(), p);
                }
            }
            return .{ .names = try names.toOwnedSlice(c.scratch()) };
        },
        .number, .number_literal, .number_literal_fresh, .string, .string_literal, .boolean, .bool_true, .bool_false, .bigint, .bigint_literal => return .non_object,
        else => return .unknown_shape, // any/unknown/union/type_param/mapped/…
    }
}

pub const JsxTargetShape = enum { not_objecty, open_object, closed_object };

/// Classify a (resolved) props target and flatten its properties into
/// `out`. Objects and intersections of objects are checkable (`open` when
/// no constituent has an index signature — tsc only excess-checks open
/// targets); anything else is `.not_objecty` (checked leniently).
pub fn jsxTargetShape(c: *Checker, rt: TypeId, out: *std.ArrayList(types.Prop)) Error!JsxTargetShape {
    switch (c.ts.kind(rt)) {
        .object => {
            for (0..c.ts.objectPropCount(rt)) |i| {
                try out.append(c.scratch(), c.ts.objectProp(rt, @intCast(i)));
            }
            const open = c.ts.objectStringIndex(rt) == 0 and c.ts.objectNumberIndex(rt) == 0;
            return if (open) .open_object else .closed_object;
        },
        .intersection => {
            var shape: JsxTargetShape = .open_object;
            for (try c.memberList(rt)) |m| {
                switch (try c.jsxTargetShape(try c.resolveStructural(m), out)) {
                    .not_objecty => return .not_objecty,
                    .closed_object => shape = .closed_object,
                    .open_object => {},
                }
            }
            return shape;
        },
        else => return .not_objecty,
    }
}

/// Names declared on `JSX.IntrinsicAttributes` (React: `key`, inherited
/// from `React.Attributes`) — allowed on any component tag without being
/// required.
pub fn jsxIntrinsicAttrNames(c: *Checker, out: *std.ArrayList(Atom)) Error!void {
    const t = (try c.jsxNamespaceType(c.atom_IntrinsicAttributes)) orelse return;
    const rt = try c.resolveStructural(t);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (try c.jsxTargetShape(rt, &props) == .not_objecty) return;
    for (props.items) |p| try out.append(c.scratch(), p.name);
}

/// The prop name JSX children flow into, per `JSX.ElementChildrenAttribute`
/// (its single member's name — React uses `children`). Defaults to
/// `children` when the selector interface is absent/empty.
pub fn jsxChildrenAttrName(c: *Checker) Error!Atom {
    const t = (try c.jsxNamespaceType(c.atom_ElementChildrenAttribute)) orelse return c.atom_children;
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object or c.ts.objectPropCount(rt) == 0) return c.atom_children;
    return c.ts.objectProp(rt, 0).name;
}

/// Whether a JSX element has meaningful children (any element/expression,
/// or non-whitespace text) — whitespace-only text does not count.
pub fn jsxChildrenPresent(c: *Checker, e: ast.JsxElementData) bool {
    return c.jsxSemanticChildCount(e) != 0;
}

/// How many of a JSX element's children are SEMANTIC (tsc's
/// `getSemanticJsxChildren`) — the count that decides whether the
/// `children` prop type types one child directly or is spread across a list.
/// Stops at two: no caller distinguishes higher counts.
pub fn jsxSemanticChildCount(c: *Checker, e: ast.JsxElementData) u32 {
    var n: u32 = 0;
    for (c.tree.extraRange(e.children_start, e.children_end)) |ch| {
        if (!c.jsxChildIsSemantic(ch)) continue;
        n += 1;
        if (n == 2) return n;
    }
    return n;
}

/// One child's half of `getSemanticJsxChildren`, so the children walk can
/// number the semantic children as it goes.
pub fn jsxChildIsSemantic(c: *Checker, ch: Node) bool {
    switch (c.nodeTag(ch)) {
        .jsx_element => return true,
        .jsx_expr_container => return c.tree.nodeData(ch).lhs != null_node,
        else => { // jsx_text
            // tsc ignores text that is whitespace-only AND spans a newline
            // (trivia between lines); same-line whitespace is a meaningful
            // space child.
            const span = c.nodeSpan(ch);
            if (span.end > c.src.len or span.start >= span.end) return false;
            var has_newline = false;
            for (c.src[span.start..span.end]) |ch2| {
                if (ch2 == '\n' or ch2 == '\r') {
                    has_newline = true;
                } else if (ch2 != ' ' and ch2 != '\t') {
                    return true; // non-whitespace
                }
            }
            return !has_newline;
        },
    }
}

/// tsc's `getContextualTypeForChildJsxExpression` for a MULTI-child element:
/// `mapType(childFieldType, t => isArrayLikeType(t) ? getIndexedAccessType(t,
/// getNumberLiteralType(childIndex)) : t)`. A constituent that is not
/// array-like types the child whole; an array-like one contributes its element
/// at this child's position.
pub fn jsxChildCtxAt(c: *Checker, field: TypeId, i: u32) Error!TypeId {
    const r = try c.resolveStructural(field);
    switch (c.ts.kind(r)) {
        .union_type => {
            const ms = try c.memberList(r);
            const buf = try c.scratch().alloc(TypeId, ms.len);
            for (ms, 0..) |m, k| buf[k] = try c.jsxChildCtxAt(m, i);
            return c.ts.makeUnion(c.scratch(), buf);
        },
        .array => return c.ts.arrayElem(r),
        .tuple => return (try c.tupleElemTypeAt(r, i)) orelse field,
        .object => {
            const idx = c.ts.objectNumberIndex(r);
            return if (idx != 0) idx else field;
        },
        else => return field,
    }
}

/// Type of a JSX attribute value: `name` → `true`, `name="s"` → fresh
/// `"s"` literal, `name={e}` → type of `e` (literals kept fresh, so
/// literal-union props accept them; widening is display-only), `name=<x/>`
/// → JSX.Element.
pub fn jsxAttributeValueType(c: *Checker, value: Node, ctx: TypeId) Error!TypeId {
    if (value == null_node) return types.true_type; // boolean shorthand
    switch (c.nodeTag(value)) {
        .string_literal => return c.ts.makeStringLiteral(try c.memberAtom(c.tree.nodeMainToken(value)), true),
        .jsx_expr_container => {
            const cd = c.tree.nodeData(value);
            if (cd.lhs == null_node) return types.undefined_type;
            // Contextually type the value by the target prop type for a
            // template-literal expression (so it keeps its template structure
            // instead of widening to `string`, e.g. `<Icon name={`ns:${s}`} />`
            // against a `` `${string}:${string}` `` prop), for an object
            // literal (so its properties are typed by the target — e.g.
            // `style={{ position: 'absolute' }}` against `CSSProperties`, whose
            // `position` is a union of string literals: without the context the
            // literal widens to `string` and rejects), and for an array literal
            // (so a fixed-length target picks the tuple member of a union —
            // e.g. `radius={[8, 8, 8, 8]}` against `number | [number, number,
            // number, number]`: without the context it widens to `number[]`
            // and fails the tuple). A conditional expression forwards the
            // context to both branches (`extraItems={cond ? [{…}] : []}`
            // against `Item[]`: each branch's array/object literal must be
            // contextually typed so its literal props don't widen — without
            // it `icon: 'link'` widens to `string` and rejects the `IconName`
            // prop). A function value (arrow or function expression) is
            // contextually typed by the target prop's signature, so its
            // parameters get their types from the callback type instead of
            // going implicit-any (`onPick={(v) => …}` against
            // `onPick?: (v: number) => void` — without the context every such
            // parameter raises TS7006). Other value kinds are checked
            // context-free.
            // A CALL is contextually typed too, so the callee's generic
            // inference gets tsc's `InferencePriority.ReturnType` seed: RN's
            // `size={platform({web: 'tiny', native: 'small'})}`
            // (`select<T>(spec: {[p in OS]?: T}): T | undefined`) keeps both
            // literals only because the attribute's `ButtonSize | undefined`
            // reaches the call — checked context-free every property widens
            // to `string` and `T` infers `string`.
            const vctx = switch (c.nodeTag(cd.lhs)) {
                .template_expr, .object_literal, .array_literal, .cond_expr, .arrow_fn, .function_expr => ctx,
                .call_expr, .call_expr_targs, .optional_call => ctx,
                else => types.no_type,
            };
            return c.checkExprCached(cd.lhs, vctx);
        },
        .jsx_element => return c.checkJsxElement(value),
        else => return types.any_type,
    }
}
