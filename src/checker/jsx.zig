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
const classes = @import("classes.zig");

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
const discriminate_ctx = @import("discriminate_ctx.zig");
const elaborate = @import("elaborate.zig");
const hasTypeMeaning = @import("names.zig").hasTypeMeaning;
const NsContainer = @import("typespace.zig").NsContainer;
const tpIndex = @import("calls.zig").tpIndex;

/// TS2875, for the automatic JSX runtime (`jsx: "react-jsx"` /
/// `"react-jsxdev"`): the `<jsxImportSource>/jsx-runtime` module that every JSX
/// tag in the program compiles into has to EXIST, and the program's resolver
/// could not find it.
///
/// tsc asks the question lazily, off the first JSX tag it checks in a file, and
/// caches the answer on the file (`getNodeLinks(file).jsxImplicitImportContainer
/// = false`) — so a file with fifty tags answers once, at its outermost-and-
/// first one. `jsx_runtime_reported` is that cache; without it a React app with
/// a broken `@types/react` install would report per tag rather than per file.
///
/// Silent when the automatic runtime is off (`jsx_runtime_module == null`,
/// which covers `jsx: "preserve"` and the classic `react` factory) and, of
/// course, when the module resolved.
fn reportMissingJsxRuntime(c: *Checker, node: Node) Error!void {
    const spec = c.prog.jsxRuntimeSpec(c.cur_file) orelse return;
    if (c.prog.jsxRuntimeFile(c.cur_file) != modules.no_file) return;
    if (c.jsx_runtime_reported[c.cur_file]) return;
    // The module needs a FILE to supply `JSX` from, which is what
    // `jsx_runtime_file` records — but tsc's question here is only whether the
    // specifier RESOLVES, and a global `declare module "react/jsx-runtime"`
    // (how the suite's react16.d.ts ships it, and how DefinitelyTyped shims
    // one) resolves it without a file of its own. Wildcards count too, exactly
    // as they do for an ordinary import.
    if (c.ambientIndex(try c.internText(spec)) != null) return;
    c.jsx_runtime_reported[c.cur_file] = true;
    try c.diagFmt(
        2875,
        c.nodeSpan(jsxRuntimeAnchor(c, node)),
        "This JSX tag requires the module path '{s}' to exist, but none could be found. Make sure you have types for the appropriate package installed.",
        .{spec},
    );
}

/// Which tag "the first JSX tag tsc checks in this file" actually is.
///
/// tsc does not check a file's tags in source order: `checkSourceFile` walks
/// the statements, and `checkFunctionExpressionOrObjectLiteralMethod` DEFERS a
/// function expression's, an arrow's and an object-literal method's body to a
/// final pass (`checkNodeDeferred` / `checkDeferredNodes`). A function or class
/// *declaration*'s body is checked in place. So the report lands on the first
/// tag outside every deferred body, and only a file whose tags are all inside
/// one reports on the first of those — which is what `node`, the tag that
/// triggered this, already is.
///
/// `const Title = (props) => <h1/>; const el = <Title/>;` is the shape that
/// makes the difference visible: tsc blames `<Title/>`, not the `<h1/>` in the
/// arrow it checks second.
///
/// Walked once per file and only from the report itself — i.e. only in a
/// program whose runtime module is missing, which is the whole subject of
/// TS2875 — so the traversal costs nothing in a program that resolves.
fn jsxRuntimeAnchor(c: *Checker, node: Node) Node {
    for (c.tree.nodeRange(0)) |stmt| {
        if (firstEagerJsxTag(c, stmt)) |n| return n;
    }
    return node;
}

/// First `.jsx_element` in `node`'s subtree, not entering a body tsc defers.
fn firstEagerJsxTag(c: *const Checker, node: Node) ?Node {
    if (node == null_node) return null;
    switch (c.nodeTag(node)) {
        .jsx_element => return node,
        .arrow_fn, .function_expr, .object_method => return null,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (firstEagerJsxTag(c, child)) |n| return n;
    }
    return null;
}

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
    try reportMissingJsxRuntime(c, node);
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    var props: TypeId = types.no_type; // no_type = unknown target (skip attr typing)
    var is_component = false;
    var overloads_exhausted = false;
    if (e.tag == null_node) {
        // Fragment `<>…</>`: no attributes, no props.
    } else if (c.isIntrinsicJsxTag(e.tag)) {
        const tag_atom = try c.atomOfToken(c.tree.nodeMainToken(e.tag));
        // Every arm below reports per TAG REFERENCE, not per element: tsc's
        // `checkJsxElementDeferred` resolves the closing tag name
        // independently of the opening one, so `<a></a>` reports twice.
        // Fragments (`<>…</>`) resolve no tag and never report.
        const open_lt = c.tree.nodeMainToken(node);
        switch (try intrinsicPropsOf(c, tag_atom)) {
            .props => |p| props = p,
            .missing => {
                try jsxIntrinsicMissing(c, open_lt, tag_atom);
                if (e.close_lt != 0) try jsxIntrinsicMissing(c, e.close_lt, tag_atom);
            },
            // tsc's `getIntrinsicTagSymbol`: with no `JSX.IntrinsicElements`
            // in scope the intrinsic tag's props type is the error type, and
            // under `noImplicitAny` that is reported as TS7026 — the JSX
            // counterpart of the implicit-'any' family. A `.tsx` file with no
            // JSX namespace at all (no React typings, `jsx: preserve`) is the
            // common shape; ztsc silently typed the props as "unknown target".
            .no_namespace => {
                try jsxIntrinsicImplicitAny(c, open_lt);
                if (e.close_lt != 0) try jsxIntrinsicImplicitAny(c, e.close_lt);
            },
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
        // tsc's `getUninstantiatedJsxSignaturesOfType`, string-literal arm: a
        // component-looking tag whose VALUE is a string literal still names an
        // intrinsic element — `var CustomTag: "h1" = "h1"; <CustomTag/>` is
        // looked up as `JSX.IntrinsicElements["h1"]`. A hit synthesizes a
        // signature (so the props type is the intrinsic's); a miss is a TS2339
        // naming the LITERAL, reported at the element, and leaves the signature
        // list empty so the TS2604 below fires as well (`tsxDynamicTagName3`).
        // `tagWithoutSignaturesIsError` already excused the literal from
        // TS2604; without the lookup it reported nothing at all.
        const lit_tag: ?Atom = blk: {
            const rt = try c.resolveStructural(tag_ty);
            break :blk if (c.ts.kind(rt) == .string_literal) c.ts.literalAtom(rt) else null;
        };
        const chosen: JsxProps = if (lit_tag) |name| switch (try intrinsicPropsOf(c, name)) {
            .props => |p| .{ .props = p },
            .missing => blk: {
                try jsxIntrinsicMissing(c, c.tree.nodeMainToken(node), name);
                break :blk .{ .props = null, .no_signatures = true };
            },
            // Silent, unlike the lowercase-tag arm above:
            // `getIntrinsicAttributesTypeFromStringLiteralType` returns
            // `anyType` outright when `JSX.IntrinsicElements` is the error type
            // ("If we need to report an error, we already [have] done so
            // here"), so `<this._tagName>` in a file with no JSX namespace at
            // all earns nothing — not the TS7026 an intrinsic tag would
            // (`tsxDynamicTagName9`).
            .no_namespace => .{ .props = null },
        } else try c.jsxComponentProps(tag_ty, targs.items, node);
        props = chosen.props orelse types.no_type;
        if (jsx_lma and props != types.no_type) {
            props = try libraryManagedAttributes(c, tag_ty, props);
        }
        overloads_exhausted = chosen.overloads_exhausted;
        // TS2604, tsc's `resolveJsxOpeningLikeElement`: with no signature to
        // resolve against there is no component here at all. Blamed on the TAG
        // NAME, not on the element.
        if (chosen.no_signatures) {
            // tsc's `getTextOfNode(node.tagName)` — the tag as WRITTEN, which
            // for a qualified tag (`<A.B/>`) is the whole dotted name.
            const tag_span = c.nodeSpan(e.tag);
            try c.diagFmt(
                2604,
                tag_span,
                "JSX element type '{s}' does not have any construct or call signatures.",
                .{c.src[tag_span.start..tag_span.end]},
            );
        }
        // TS2607, tsc's `getJsxPropsTypeFromClassType`: the tag constructs an
        // instance, but that instance has no member for the attributes to land
        // on. Silent with no attributes written — `<C/>` against a props-less
        // component is perfectly legal — which is tsc's
        // `!!length(context.attributes.properties)` guard. Blamed on the
        // ELEMENT, not the tag name (tsc errors on `context`, the opening
        // element), and only for an explicit attribute: a spread is a property
        // of the attributes object too, so both count.
        if (chosen.no_props_member and e.attrs_start != e.attrs_end) {
            if (try c.jsxPropsMemberName()) |pname| {
                try c.diagFmt(
                    2607,
                    c.nodeSpan(node),
                    "JSX element class does not support attributes because it does not have a '{s}' property.",
                    .{c.atomText(pname)},
                );
            }
        }
        try checkJsxTagBound(c, e.tag, chosen, tag_ty);
    }
    // tsc's `discriminateContextualTypeByJSXAttributes`, the JSX half of the
    // step an object literal gets in `objectLiteralType`: a props type that is
    // a UNION is collapsed to the constituent the attributes themselves select
    // BEFORE anything reads it — each attribute's contextual type, the
    // children's, and so every render prop's contextual signature. Placed here
    // rather than inside `checkJsxAttributes` so the children below share the
    // one answer.
    if (props != types.no_type) {
        const rp = try c.resolveStructural(props);
        if (c.ts.kind(rp) == .union_type) {
            props = try discriminate_ctx.byJsxAttributes(
                c,
                c.tree.extraRange(e.attrs_start, e.attrs_end),
                rp,
                c.jsxChildrenPresent(e),
            );
        }
    }
    if (overloads_exhausted) {
        try reportJsxOverloadFailure(c, node, e, props);
    } else {
        try c.checkJsxAttributes(node, e, props, is_component, c.jsxChildrenPresent(e));
    }
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

/// The applicability diagnostics an attribute check files — the ones tsc's
/// `resolveCall` produces and then REPLACES with a TS2769 when an overload set
/// is exhausted. Everything else the same walk files (an implicit `any` inside
/// an attribute value, a duplicate attribute name, a spread of a non-object)
/// is filed outside `resolveCall` in tsc and survives.
/// Exactly the codes `checkJsxAttributes`' own report sites emit — the
/// `checkAssignable` family (TS2322 and the missing-property refinements it
/// hands off to), the excess-property TS2353 and the no-overlap TS2559 — and
/// deliberately not TS2769: a nested element inside an attribute VALUE files
/// its own, and that one is about a different call.
const jsx_applicability_codes = [_]u16{ 2322, 2353, 2559, 2739, 2740, 2741 };

/// tsc's `reportCallResolutionError` for an OVERLOADED component whose every
/// signature rejected the attributes: one TS2769 stands in for the
/// per-attribute complaints. Its span is the complaint's own position when
/// every complaint sits at the same one (tsc keeps `diags[0]`'s span if
/// `every(diags, d => d.start === diags[0].start)`), and the whole element
/// otherwise. Oracle-verified against tsgo 7.0.2 on
/// `tsxStatelessFunctionComponentOverload4`, whose nine TS2769 keys all land on
/// the offending attribute rather than on the tag.
fn reportJsxOverloadFailure(c: *Checker, node: Node, e: ast.JsxElementData, props: TypeId) Error!void {
    const elem = c.nodeSpan(node);
    const saved = c.diags.items.len;
    try c.checkJsxAttributes(node, e, props, true, c.jsxChildrenPresent(e));
    var anchor: ?Span = null;
    var one_place = true;
    for (c.diags.items[saved..]) |d| {
        if (d.file != c.cur_file) continue;
        if (d.span.start < elem.start or d.span.start >= elem.end) continue;
        if (std.mem.indexOfScalar(u16, &jsx_applicability_codes, d.code) == null) continue;
        if (anchor) |a| {
            if (a.start != d.span.start) one_place = false;
        } else {
            anchor = d.span;
        }
    }
    // Nothing to summarize: the candidate the element is typed against had no
    // applicability complaint of its own (it was declined for something the
    // probe counted and this walk does not report). Leave the walk's own
    // diagnostics standing rather than inventing a TS2769.
    const first = anchor orelse return;
    c.rollbackDiags(saved, .{
        .file = c.cur_file,
        .lo = elem.start,
        .hi = elem.end,
        .codes = &jsx_applicability_codes,
    });
    try c.diagFmt(2769, if (one_place) first else elem, "No overload matches this call.", .{});
}

/// What `JSX.IntrinsicElements[name]` answered. The three cases are tsc's
/// `getIntrinsicTagSymbol` arms and they report differently: a hit types the
/// props, a miss is TS2339, and no `JSX.IntrinsicElements` in scope at all is
/// TS7026 (per TAG REFERENCE, not per element).
const IntrinsicLookup = union(enum) {
    props: TypeId,
    missing,
    no_namespace,
};

fn intrinsicPropsOf(c: *Checker, name: Atom) Error!IntrinsicLookup {
    const ie = (try c.jsxNamespaceType(c.atom_IntrinsicElements)) orelse return .no_namespace;
    const p = (try c.propOfType(try c.resolveStructural(ie), name)) orelse return .missing;
    return .{ .props = p.ty };
}

/// TS2339 for an intrinsic tag `JSX.IntrinsicElements` does not declare.
///
/// Blamed on the ELEMENT (`lt` = its `<`), not on the tag name: tsc's
/// `getIntrinsicTagSymbol` errors on the `JsxOpeningLikeElement`/
/// `JsxClosingElement` it was handed, so `<span/>` reports at the `<` one
/// column before the name — and a PAIRED element reports TWICE, because
/// `checkJsxElementDeferred` resolves the closing tag name independently
/// ("so that rename/go to definition/etc work"). ztsc reported once, at the
/// name; both halves showed up as position mismatches across the tsx corpus.
fn jsxIntrinsicMissing(c: *Checker, lt: TokenIndex, name: Atom) Error!void {
    try c.diagFmt(2339, c.tokSpan(lt), "Property '{s}' does not exist on type 'JSX.IntrinsicElements'.", .{c.atomText(name)});
}

/// TS7026 at one intrinsic-tag reference (`lt` = the tag's `<`), raised when
/// `JSX.IntrinsicElements` does not resolve. Gated on `noImplicitAny` exactly
/// like the rest of the TS70xx family.
fn jsxIntrinsicImplicitAny(c: *Checker, lt: TokenIndex) Error!void {
    if (!c.prog.no_implicit_any) return;
    try c.diagFmt(7026, c.tokSpan(lt), "JSX element implicitly has type 'any' because no interface 'JSX.IntrinsicElements' exists.", .{});
}

/// Whether a JSX tag node is an intrinsic element (simple lowercase-initial
/// identifier). Uppercase or dotted names are component values — except a
/// NAMESPACED name (`<A:foo>`), which tsc's `isJsxIntrinsicTagName` answers
/// intrinsic whatever its case, because a JsxNamespacedName can never name a
/// component value. The parser leaves the whole namespaced name in one
/// `.jsx_name` token, so the `:` is what identifies it.
pub fn isIntrinsicJsxTag(c: *Checker, tag: Node) bool {
    if (c.nodeTag(tag) != .identifier) return false;
    const text = c.tokenText(c.tree.nodeMainToken(tag));
    if (std.mem.indexOfScalar(u8, text, ':') != null) return true;
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
    // tsc's `getJsxNamespaceAt` asks the implicit-import container FIRST and
    // only falls back to `resolveName(JSX)` when there is none — so a program
    // that has BOTH a global `JSX` namespace and an automatic runtime types its
    // tags from the runtime's namespace. @emotion/react is the shape that
    // depends on it: its `jsx-runtime` re-exports an `IntrinsicElements` that
    // widens react's global one with `css`, and reading the global first made
    // every `css={…}` attribute an excess property (TS2322).
    //
    // The per-member fallback (rather than tsc's all-or-nothing container) is
    // deliberate: a runtime module that resolves but publishes only *part* of
    // the namespace still gets the global's remaining members here, where tsc
    // would type them as the error type.
    if (try jsxRuntimeNamespaceMember(c, member)) |g| return g;
    // GLOBALS only, never the enclosing scope chain. tsc's last resort here is
    // `getGlobalSymbol(JsxNames.JSX, …)` — the two lookups before it are the
    // implicit-import container and `resolveName(jsxNamespace)`, and
    // `jsxNamespace` is the FACTORY root (`React`), not `JSX`. So a
    // `declare namespace JSX` written at the top level of a MODULE is invisible
    // to tsc: `jsxPropsAsIdentifierNames` declares its whole namespace inside
    // an `export default`-bearing file and still gets TS7026 for want of
    // `JSX.IntrinsicElements`. A script file's identical declaration IS global
    // and still resolves, which is the shape most of the suite's fixtures use.
    const s = c.prog.globals.lookup(c.atom_JSX) orelse return null;
    const ns = (try jsxNamespaceSym(c, s)) orelse return null;
    return nsTypeMember(c, ns, member);
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
    const f = c.prog.jsxRuntimeFile(c.cur_file);
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
pub fn jsxComponentProps(c: *Checker, tag_ty: TypeId, explicit_targs: []const TypeId, node: Node) Error!JsxProps {
    const t = try c.resolveStructural(tag_ty);
    // tsc's `resolveCustomJsxElementAttributesType` distributes over a UNION
    // tag type and unions the per-constituent props. @types/react's
    // `ComponentType<P> = ComponentClass<P> | StatelessComponent<P>` is that
    // shape, so a `React.ComponentType<Props>`-typed component had NO props
    // target at all: every attribute went unchecked and a render-prop child
    // lost its contextual signature (TS7006/TS7031 on its parameters).
    if (c.ts.kind(t) == .union_type) {
        var acc: TypeId = types.no_type;
        // tsc resolves a union tag through `getUnionSignatures`, which needs
        // EVERY constituent to contribute one — so a single non-callable
        // member makes the whole union signature-less (`tsxUnionTypeComponent2`:
        // `ComponentClass<any> | number`).
        var any_missing = false;
        // `getUnionSignatures` combines the constituents' signatures into one
        // whose RETURN is the union of theirs — so the element type a union tag
        // is held to is the union of what each constituent evaluates to
        // (`ClassComponent | { type: string | undefined }` in
        // `jsxComponentTypeErrors`). A constituent that contributes no element
        // type at all drops out rather than poisoning the union.
        var elems: TypeId = types.no_type;
        for (try c.memberList(t)) |m| {
            const r = try jsxComponentProps(c, m, explicit_targs, node);
            if (r.no_signatures) any_missing = true;
            if (r.elem_type != types.no_type) {
                elems = if (elems == types.no_type) r.elem_type else try c.makeUnion2(elems, r.elem_type);
            }
            const p = r.props orelse continue;
            acc = if (acc == types.no_type) p else try c.makeUnion2(acc, p);
        }
        return .{
            .props = if (acc == types.no_type) null else acc,
            .no_signatures = any_missing,
            .elem_type = elems,
        };
    }
    // A class always has a construct signature, whatever its props turn out to
    // be, so a null here means "no discernible props", never "not a component".
    if (c.ts.kind(t) == .class_value) return try c.jsxClassComponentProps(t, explicit_targs, node);
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    try collectJsxCallSigs(c, t, &sigs);
    if (sigs.items.len == 0) {
        // tsc's `getUninstantiatedJsxSignaturesOfType` asks for the CALL
        // signatures first and falls back to the CONSTRUCT signatures when
        // there are none — `<C/>` where `C: new () => {props: P; render(): …}`
        // is a class component whose class is not a class DECLARATION, which
        // `.class_value` above never sees. Without the fallback such a tag had
        // no props target at all: every attribute went unchecked, and the tag
        // itself escaped TS2604 only because `tagWithoutSignaturesIsError`
        // excuses anything assignable to `Function`.
        var csigs: std.ArrayList(TypeId) = .empty;
        defer csigs.deinit(c.scratch());
        try collectJsxConstructSigs(c, t, &csigs);
        if (csigs.items.len != 0) return try jsxConstructSigProps(c, csigs.items, explicit_targs, node);
        return .{ .props = null, .no_signatures = try tagWithoutSignaturesIsError(c, tag_ty, t) };
    }
    if (sigs.items.len == 1) return try jsxPropsOfSig(c, sigs.items[0], explicit_targs, node);
    return try chooseJsxSignature(c, sigs.items, explicit_targs, node);
}

/// What a component tag offers the attribute check: its props type, plus the
/// one thing the CHOICE of signature says about reporting — that an overload
/// SET was tried and every candidate rejected the attributes, which is a
/// TS2769 about the set rather than a complaint about one attribute.
pub const JsxProps = struct {
    props: ?TypeId,
    overloads_exhausted: bool = false,
    /// tsc's `getUninstantiatedJsxSignaturesOfType` came back EMPTY and the tag
    /// type is not one of the shapes that excuses that — i.e. this tag is a
    /// TS2604. Distinct from `props == null`, which a perfectly good class
    /// component with no discernible props also answers.
    no_signatures: bool = false,
    /// The tag IS a component — it has a construct signature — but the
    /// instance that signature returns has no member named by
    /// `JSX.ElementAttributesProperty`, so there is nowhere for an attribute
    /// to land. tsc's TS2607, reported only when attributes are actually
    /// written (`getJsxPropsTypeFromClassType`'s
    /// `!!length(context.attributes.properties)` guard).
    no_props_member: bool = false,
    /// What the CHOSEN signature says this tag evaluates to — tsc's
    /// `elemInstanceType`, i.e. `getReturnTypeOfSignature(getResolvedSignature
    /// (node))`: a function component's RETURN type, a class component's
    /// INSTANCE type. `no_type` when no signature was chosen (or the tag is an
    /// intrinsic, whose synthetic signature returns `JSX.Element` and so can
    /// never fail its bound). Read only by `checkJsxTagBound`.
    elem_type: TypeId = types.no_type,
};

/// tsc's `JsxReferenceKind` — WHICH bound `checkJsxReturnAssignableToAppropriate
/// Bound` holds the tag to, decided by the signatures the TAG TYPE offers rather
/// than by the one that was chosen: construct signatures make it a class
/// component, call signatures a function component, and anything else (an
/// intrinsic tag, a union that mixes the two, a signature-less tag) is `mixed`
/// and answers to both bounds at once.
pub const JsxRefKind = enum { function, component, mixed };

/// tsc's `getJsxReferenceKind`: which of the two JSX component protocols this
/// tag speaks, read off the TAG TYPE's signatures rather than off the signature
/// that was chosen. Construct signatures win over call signatures (a class is a
/// class even though `typeof C` is callable in a `.d.ts` sense), and a tag that
/// offers neither — or a union whose constituents disagree — is `mixed`.
///
/// The union rule is `getUnionSignatures`': a union has signatures of a kind
/// only when EVERY constituent contributes one, so
/// `FunctionComponent | ClassComponent` has neither and answers `mixed`, which
/// is exactly why tsc holds it to `Element | null | ElementClass`.
fn jsxRefKind(c: *Checker, tag_ty: TypeId) Error!JsxRefKind {
    const t = try c.resolveStructural(tag_ty);
    if (c.ts.kind(t) == .union_type) {
        var all_ctor = true;
        var all_call = true;
        for (try c.memberList(t)) |m| switch (try jsxRefKind(c, m)) {
            .component => all_call = false,
            .function => all_ctor = false,
            .mixed => {
                all_ctor = false;
                all_call = false;
            },
        };
        if (all_ctor) return .component;
        if (all_call) return .function;
        return .mixed;
    }
    // A class DECLARATION's value type is not an object with construct
    // signatures in ztsc's model, but it is one in tsc's.
    if (c.ts.kind(t) == .class_value) return .component;
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    try collectJsxConstructSigs(c, t, &sigs);
    if (sigs.items.len != 0) return .component;
    sigs.clearRetainingCapacity();
    try collectJsxCallSigs(c, t, &sigs);
    return if (sigs.items.len != 0) .function else .mixed;
}

/// TS2786, tsc's `checkJsxReturnAssignableToAppropriateBound`: a tag that
/// resolves to a signature perfectly well can still fail to be a COMPONENT,
/// because what it evaluates to is not a JSX element. A function component's
/// return type has to satisfy `JSX.Element | null`, a class component's
/// instance type `JSX.ElementClass`, and a `mixed` tag (an intrinsic, or a
/// union that is neither) the union of the two.
///
/// Anchored at the TAG NAME — `openingLikeElement.tagName`, whose text is also
/// the message's `{0}` — and so reported once per opening element, never at the
/// closing tag.
///
/// SILENT when the JSX namespace declares `ElementType` (TS 5.1 /
/// @types/react 18.3 and later, which both benchmark apps are on):
/// `checkJsxOpeningLikeElementOrOpeningFragment` takes the OTHER branch there,
/// bounding the tag TYPE instead of what it returns, and never calls this at
/// all. The gate is first so a modern-React program pays one namespace lookup
/// per tag and nothing else — no signature walk, no relation.
fn checkJsxTagBound(c: *Checker, tag: Node, chosen: JsxProps, tag_ty: TypeId) Error!void {
    if (chosen.elem_type == types.no_type or chosen.no_signatures) return;
    if ((try c.jsxNamespaceMember(c.atom_ElementType)) != null) return;
    // `getJsxStatelessElementTypeAt` / `getJsxElementClassTypeAt` both answer
    // `undefined` when their member is missing, and an absent bound is no
    // check — a JSX namespace with no `Element` cannot say what a component is.
    const bound: TypeId = switch (try jsxRefKind(c, tag_ty)) {
        .function => try sfcBound(c) orelse return,
        .component => (try c.jsxNamespaceType(c.atom_ElementClass)) orelse return,
        .mixed => blk: {
            const sfc = try sfcBound(c) orelse return;
            const cls = (try c.jsxNamespaceType(c.atom_ElementClass)) orelse return;
            break :blk try c.makeUnion2(sfc, cls);
        },
    };
    if (try c.isAssignable(chosen.elem_type, bound)) return;
    const span = c.nodeSpan(tag);
    // `getTextOfNode(node.tagName)` — the tag as WRITTEN, so a qualified tag
    // keeps its dots (and even its interior spaces: `<obj. Member/>`).
    try c.diagFmt(2786, span, "'{s}' cannot be used as a JSX component.", .{c.src[span.start..span.end]});
}

/// `getJsxStatelessElementTypeAt`: `JSX.Element | null`, the bound a FUNCTION
/// component's return type answers to — a component is allowed to render
/// nothing.
fn sfcBound(c: *Checker) Error!?TypeId {
    const el = (try c.jsxNamespaceType(c.atom_Element)) orelse return null;
    return try c.makeUnion2(el, types.null_type);
}

/// TS2604's precondition: a component tag whose type offers no call or
/// construct signature is an error UNLESS tsc excuses it. The excuses are
/// `getUninstantiatedJsxSignaturesOfType`'s string arms — a `string`-typed tag
/// is given `anySignature`, and a string LITERAL is looked up as an intrinsic —
/// and `isUntypedFunctionCall`'s: `any` (and an error type, which
/// `resolveJsxOpeningLikeElement` returns on before asking at all), and a
/// non-union, non-`never` type that is merely ASSIGNABLE to the global
/// `Function`.
///
/// The string-literal excuse is only reached through a UNION tag type now:
/// `checkJsxElement` performs the intrinsic lookup itself for a bare literal
/// tag, and a MISS there is a TS2604 after all.
///
/// One shape is excused here that tsc DOES report, a deliberate under-report of
/// ztsc's own making: a TYPE PARAMETER, because tsc asks the question of the
/// APPARENT type and ztsc's structural resolve does not walk a parameter's
/// constraint, so `<T extends ComponentType>` would otherwise read as
/// signature-less.
///
/// `undefined`/`void` used to be excused too, for a reason that has since been
/// fixed: an unannotated ambient `declare var Foo` — how half the suite's JSX
/// fixtures declare their components — was typed `undefined` rather than `any`,
/// so reporting on `undefined` was five false positives apiece in
/// `tsxReactEmit3`/`tsxExternalModuleEmit2`. See `SymbolFlags.ambient_var`.
fn tagWithoutSignaturesIsError(c: *Checker, tag_ty: TypeId, resolved: TypeId) Error!bool {
    // `<this/>` inside the very class it names, reached while that class's
    // member table is still being built: `resolveStructural` answers the CYCLE
    // — the error type — and the `.err` arm below excuses it, so the tag earned
    // nothing at all. `classes.inProgressCallSigless` answers the question the
    // table cannot off the DECLARATIONS instead, and a class BODY has no syntax
    // for a call signature, so a `true` there is a TS2604 for certain. Asked of
    // the UNRESOLVED tag type, which is the `this` type the walk needs.
    //
    // Only the window matters: with a return-type annotation on the enclosing
    // method the class is not in flight, `resolved` is the ordinary instance
    // object, and the `Function` relation below was already giving the right
    // answer (`tsxDynamicTagName7`, `jsxComponentTypeErrors`).
    if (try classes.inProgressCallSigless(c, tag_ty)) return true;
    switch (c.ts.kind(resolved)) {
        .any, .err, .string, .string_literal, .type_param, .infer_var => return false,
        // tsc's `!(getReducedType(apparentFuncType).flags & TypeFlags.Never)`
        // guard puts `never` back INSIDE the error, so it falls through.
        .never => return true,
        else => {},
    }
    const sym = c.prog.globals.lookup(c.atom_Function) orelse return true;
    if (!c.symFlags(sym).interface) return true;
    return !(try c.isAssignable(tag_ty, try c.ts.makeRef(sym, &.{})));
}

/// The CONSTRUCT signatures a component tag offers, in declaration order —
/// what `getUninstantiatedJsxSignaturesOfType` falls back to when the tag has
/// no call signature. Same shapes as `collectJsxCallSigs`, minus the two that
/// cannot carry a construct signature (`.function` and `.overloads` are call
/// signatures by construction; `new (…) => R` is an OBJECT with one construct
/// signature and no call signature — see `typenode.zig`'s `.constructor_type`).
fn collectJsxConstructSigs(c: *Checker, t: TypeId, out: *std.ArrayList(TypeId)) Error!void {
    switch (c.ts.kind(t)) {
        .object => for (0..c.ts.objectConstructSigCount(t)) |i| {
            try out.append(c.scratch(), c.ts.objectConstructSig(t, @intCast(i)));
        },
        .intersection => for (try c.memberList(t)) |m| {
            const rm = try c.resolveStructural(m);
            if (c.ts.kind(rm) != .object) continue;
            try collectJsxConstructSigs(c, rm, out);
            if (out.items.len > 0) return;
        },
        else => {},
    }
}

/// tsc's `getJsxPropsTypeFromClassType` for a tag whose component is a bare
/// CONSTRUCT signature rather than a class declaration: the attributes target
/// is the member of the signature's RETURN type named by
/// `JSX.ElementAttributesProperty`, wrapped in `IntrinsicClassAttributes<I>`
/// exactly as the class-declaration path wraps it (`withIntrinsicClassAttributes`).
///
/// The FIRST signature is the one read. tsc resolves an overloaded construct
/// signature set through `resolveCall` with the attributes object as the sole
/// argument, which is what `chooseJsxSignature` does on the call side; a
/// construct-signature component with overloads is rare enough that reading
/// the first is the conservative shape — it types the attributes against a
/// real target instead of leaving them unchecked, and never reports a
/// signature-set failure the call side would.
///
/// A return type with no such member is tsc's TS2607, surfaced through
/// `JsxProps.no_props_member` so the element (which knows whether any
/// attribute was written) decides. Deliberately NOT extended to the
/// class-declaration path: `jsxClassComponentProps` answers null for a
/// modelling gap of ztsc's own — the `@types/react` class+interface merge —
/// where tsc has a perfectly good `props`, and reporting there would be a
/// false positive on every React class component.
fn jsxConstructSigProps(
    c: *Checker,
    sigs: []const TypeId,
    explicit_targs: []const TypeId,
    node: Node,
) Error!JsxProps {
    const sel = try jsxPropsSelector(c);
    const name_opt: ?Atom = switch (sel) {
        .member => |m| m,
        else => null,
    };
    var sig = sigs[0];
    if (explicit_targs.len > 0) {
        sig = try c.instantiateSigForCall(sig, explicit_targs, &.{}, node, types.no_type);
    } else if (sel == .first_param and c.ts.fnTypeParams(sig).len > 0) {
        // The signature IS the inference target here — its first parameter is
        // the props type, so `inferJsxTargs` can take it as written rather than
        // through a synthetic re-packaging.
        const tp_syms = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        sig = try c.inferJsxTargs(sig, tp_syms, e);
    } else if (name_opt) |name| if (c.ts.fnTypeParams(sig).len > 0) {
        // A GENERIC construct signature infers its type arguments from the
        // attributes, exactly as the class-declaration path does — tsc's
        // `inferJsxTypeArguments` over
        // `getEffectiveFirstArgumentForJsxSignature`, which for a component
        // reference IS `getJsxPropsTypeFromClassType`. So the inference source
        // is the props member of the still-generic instance, packaged as the
        // sole parameter of a synthetic `(props: P<T…>) => I<T…>` — the same
        // synthesis `jsxGenericClassComponentProps` performs. Without it
        // `<G v={1}/>` against `new <T>(p: T) => {props: {v: T}}` related `1`
        // to the free `T` and reported TS2322.
        const tp_syms = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
        const generic_inst = c.ts.fnReturn(sig);
        if (try c.propOfType(try c.resolveStructural(generic_inst), name)) |gp| {
            const synth = try c.ts.makeFunction(
                &.{.{ .name = name, .ty = gp.ty }},
                generic_inst,
                tp_syms,
                0,
            );
            const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
            sig = try c.inferJsxTargs(synth, tp_syms, e);
        }
    };
    const inst = c.ts.fnReturn(sig);
    switch (sel) {
        // "the type of the first parameter of the signature, which should be
        // the els props type" — a signature that takes none has no target, and
        // `empty_object_type` is the same answer `jsxPropsOfSig` gives a
        // zero-parameter function component.
        .first_param => return .{
            .props = if (c.ts.fnParamCount(sig) == 0 or try jsxHasManagedAttributes(c))
                null
            else
                c.ts.fnParam(sig, 0).ty,
            .elem_type = inst,
        },
        // "If there is no e.g. 'props' member in ElementAttributesProperty, use
        // the element class type instead."
        .instance => return .{ .props = try c.withIntrinsicClassAttributes(inst, inst), .elem_type = inst },
        .member => {},
    }
    const name = name_opt.?;
    const rinst = try c.resolveStructural(inst);
    // `getJsxPropsTypeForSignatureFromMember`'s first line: `isTypeAny(
    // instanceType) ? instanceType : getTypeOfPropertyOfType(…)`. An `any`
    // instance HAS every member, so `new (n: string) => any` is a component
    // whose attributes are unchecked rather than one missing its props member —
    // ztsc read the failed lookup as TS2607 (`tsxElementResolution12`).
    if (c.ts.kind(rinst) == .any or c.ts.kind(rinst) == .err) {
        return .{ .props = rinst, .elem_type = inst };
    }
    const p = (try c.propOfType(rinst, name)) orelse
        return .{ .props = null, .no_props_member = true, .elem_type = inst };
    return .{ .props = try c.withIntrinsicClassAttributes(p.ty, inst), .elem_type = inst };
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
fn chooseJsxSignature(c: *Checker, sigs: []const TypeId, explicit_targs: []const TypeId, node: Node) Error!JsxProps {
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    const has_children = c.jsxChildrenPresent(e);
    const elem = c.nodeSpan(node);
    var last: ?JsxProps = null;
    var tried: u32 = 0;
    for (sigs) |s| {
        const cand = try jsxPropsOfSig(c, s, explicit_targs, node);
        const props = cand.props orelse continue;
        last = cand;
        tried += 1;
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
        if (!rejected) return cand;
    }
    // No candidate is clean. tsc's `reportCallResolutionError` then has an
    // overload SET to talk about, so the per-attribute complaints are replaced
    // by one TS2769 — the same rule `resolveSignatureCall` applies to a call
    // whose candidate pile holds two or more. The element is still checked
    // against the last candidate's props (that is where the anchor and the
    // attributes' contextual types come from); only the report changes.
    const l = last orelse return .{ .props = null };
    return .{ .props = l.props, .elem_type = l.elem_type, .overloads_exhausted = tried > 1 };
}

/// The props type a single component signature exposes: its first parameter,
/// with type arguments bound — plus, in `elem_type`, what that same
/// (instantiated) signature RETURNS, which is what `checkJsxTagBound` holds to
/// `JSX.Element | null`. Both have to come from the one instantiation: the
/// return of the still-generic signature would carry free type parameters.
fn jsxPropsOfSig(c: *Checker, sig_in: TypeId, explicit_targs: []const TypeId, node: Node) Error!JsxProps {
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
    const elem = c.ts.fnReturn(sig);
    if (c.ts.fnParamCount(sig) == 0) return .{ .props = types.empty_object_type, .elem_type = elem };
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
    return .{ .props = if (stripped == types.never_type) p0 else stripped, .elem_type = elem };
}

/// Infer a generic component's type arguments from its JSX attributes,
/// mirroring tsc's "attributes object as the sole argument" model, then
/// return the signature instantiated with them. Only non-function attribute
/// values drive inference (a `render` callback is contextually typed, not a
/// Phase-1 inference source). A param no attribute constrains falls back to
/// its default, else its constraint, else `unknown` — so an un-inferred
/// `Controller<TFieldValues, TName>` resolves to concrete
/// `ControllerProps<Form, FieldPath<Form>, …>` whose props relate reflexively.
/// The index into `tps` of the type parameter the attributes object infers to
/// WHOLE — `p0` itself, or the single bare parameter among an intersection's
/// constituents — or null when the target has no such naked position.
///
/// Null too when any SPREAD attribute is present: the object built from the
/// written attributes would then be missing the spread's members, and a
/// candidate that under-describes the attributes is worse than none (the
/// spread's own members would each read as excess against it). Such an element
/// keeps the pre-existing default/constraint fallback.
fn nakedTypeParamTarget(c: *Checker, p0: TypeId, tps: []const u32, e: ast.JsxElementData) Error!?usize {
    if (tps.len == 0) return null;
    for (c.tree.extraRange(e.attrs_start, e.attrs_end)) |attr| {
        if (c.nodeTag(attr) == .jsx_spread_attribute) return null;
    }
    if (c.ts.kind(p0) == .type_param) return tpIndex(tps, c.ts.typeParamSymbol(p0));
    if (c.ts.kind(p0) != .intersection) return null;
    var found: ?usize = null;
    for (try c.memberList(p0)) |m| {
        if (c.ts.kind(m) != .type_param) continue;
        const i = tpIndex(tps, c.ts.typeParamSymbol(m)) orelse continue;
        if (found != null) return null; // two naked parameters: ambiguous, bail
        found = i;
    }
    return found;
}

pub fn inferJsxTargs(c: *Checker, sig: TypeId, tps: []const u32, e: ast.JsxElementData) Error!TypeId {
    if (c.ts.fnParamCount(sig) == 0) return sig;
    const p0 = c.ts.fnParam(sig, 0).ty;
    const rp0 = try c.resolveStructural(p0);
    const candidates = try c.scratch().alloc(TypeId, tps.len);
    for (candidates) |*x| x.* = types.no_type;
    // The attributes as an object type, collected alongside phase 1 and used
    // only by `nakedTypeParamTarget` below.
    var attrs_obj: std.ArrayList(types.Prop) = .empty;
    defer attrs_obj.deinit(c.scratch());
    const naked = try nakedTypeParamTarget(c, p0, tps, e);
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
            if (cd.lhs != null_node and (c.nodeTag(cd.lhs) == .arrow_fn or c.nodeTag(cd.lhs) == .function_expr)) {
                // The naked-parameter object still needs the NAME (or the
                // attribute reads as excess against the inferred `P`), but not
                // a type: `unknown` stands in for what a contextual pass that
                // has not happened yet would have produced.
                //
                // `unknown` and not `any`, because the inferred `P` lands in an
                // INTERSECTION with the props the tag declares outright
                // (`props: P & { children? }` over `Component<Props &
                // BaseProps<Values>>`), and `makeIntersection` collapses a whole
                // intersection containing `any` to `any` while it simply drops
                // `unknown`. With `any` the attribute's own contextual lookup
                // then found `any` instead of `(cur: Values) => Values` and
                // every `nextValues={a => a}` went implicit-any
                // (checkJsxGenericTagHasCorrectInferences).
                if (naked != null) try attrs_obj.append(c.scratch(), .{ .name = try c.memberAtom(name_tok), .ty = types.unknown_type });
                continue;
            }
        }
        const pt = (try c.propOfType(rp0, try c.memberAtom(name_tok))) orelse {
            if (naked != null) {
                const vt = try c.jsxAttributeValueType(ad.lhs, types.no_type);
                try attrs_obj.append(c.scratch(), .{ .name = try c.memberAtom(name_tok), .ty = vt });
            }
            continue;
        };
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
        if (naked != null) try attrs_obj.append(c.scratch(), .{ .name = try c.memberAtom(name_tok), .ty = vty });
        try c.unify(pt.ty, vty, tps, candidates, 0);
    }
    // Phase 1b, tsc's `InferencePriority.NakedTypeVariable`: when the target
    // is a bare type parameter — on its own or as a constituent of an
    // intersection — the WHOLE attributes object is its candidate. That is the
    // only inference a class component's props target admits in the corpus's
    // `react.d.ts`, whose `Component<P, S>` declares `props: P & { children?:
    // ReactNode }`: phase 1 reads the intersection's members and finds only
    // `children`, so `P` collected nothing and fell back to its DEFAULT.
    // `declare class MyComp<P = Prop> extends React.Component<P, {}>` then
    // checked `<MyComp />` against `Prop` and reported two false TS2322s that
    // tsc does not (`tsxReactComponentWithDefaultTypeParameter2`).
    //
    // Verified against tsgo: `<Cons q={1}/>` over `Cons<P extends {k:number}>`
    // renders as `Cons<{k: number}>` in the message — the candidate `{q:
    // number}` WAS formed and then clamped to the constraint, which is exactly
    // the resolution loop below.
    if (naked) |idx| {
        if (candidates[idx] == types.no_type) candidates[idx] = try jsxAttrsObject(c, attrs_obj.items, .display);
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
/// The INSTANCE type it settles on rides along in `elem_type`: that is what
/// `checkJsxTagBound` holds to `JSX.ElementClass`, and it is meaningful even
/// when the props member is not (the two failures below both leave a perfectly
/// good instance type behind).
pub fn jsxClassComponentProps(c: *Checker, class_val: TypeId, explicit_targs: []const TypeId, node: Node) Error!JsxProps {
    const cls = c.ts.classSymbol(class_val);
    // With no `JSX.ElementAttributesProperty` the target is the CONSTRUCTOR's
    // first parameter, which is a plain construct-signature question — the same
    // one `jsxConstructSigProps` answers for a non-declaration class, so the
    // class's own construct signatures are handed straight to it. This covers a
    // generic class too: the signature carries the class's type parameters, and
    // the inference from the attributes is that path's.
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(cls, &tps);
    if (try jsxPropsSelector(c) == .first_param) {
        if (try jsxClassCtorParamProps(c, cls, tps.items, explicit_targs, node)) |r| return r;
    }
    if (tps.items.len != 0) return jsxGenericClassComponentProps(c, cls, tps.items, explicit_targs, node);
    const inst = try c.ts.makeRef(cls, &.{});
    // The instance type is settled before the props member is looked up, so a
    // JSX namespace with no `ElementAttributesProperty` at all — which leaves
    // the attributes unchecked — still hands `checkJsxTagBound` something to
    // hold to `JSX.ElementClass` (`jsxComponentTypeErrors` declares exactly
    // that namespace: `Element` and `ElementClass`, nothing else).
    const name = (try c.jsxPropsMemberName()) orelse return .{ .props = null, .elem_type = inst };
    const rinst = try c.resolveStructural(inst);
    if (try c.propOfType(rinst, name)) |p| {
        return .{ .props = try c.withIntrinsicClassAttributes(p.ty, inst), .elem_type = inst };
    }
    // No resolvable props member — a modeling gap, not a genuinely
    // props-less component (an empty `Component<{}>` still yields a `props`
    // member above). This surfaces for class components whose base is a
    // class+interface declaration merge we don't fully fold (`@types/react`
    // `Component<P>` merges `interface Component extends ComponentLifecycle`
    // with `class Component { readonly props: Readonly<P> }`). Leave the
    // attributes unchecked (tsc's behavior for an unknown props target)
    // rather than reject every attribute against `{}` — under-report over a
    // false positive.
    return .{ .props = null, .elem_type = inst };
}

/// `getJsxPropsTypeFromClassType`'s FIRST arm for a class DECLARATION: with no
/// `JSX.ElementAttributesProperty` in the namespace, the attributes target is
/// the CONSTRUCTOR's first parameter — "which should be the els props type".
///
/// A generic class takes the same synthetic-signature route the props-member
/// arm takes (`jsxGenericClassComponentProps`): `(props: P<T…>) => C<T…>`
/// written in the class's own type parameters, handed to `inferJsxTargs`, so
/// `<List data={images} keyExtractor={(item, i) => …}/>` still infers `ItemT`
/// from `data` and contextually types the callback. Routing it through
/// `jsxConstructSigProps` instead does NOT work: `ctorSignatures` hands back an
/// INHERITED `constructor(props: P)` already substituted down the `extends`
/// chain, so the signature carries no type parameters of its own and there is
/// nothing left for the inference to bind.
///
/// Null when the class has no constructor at all (the default one takes no
/// parameter, so there is no props type to speak of) — the attributes are left
/// unchecked, which is where this path stood before.
fn jsxClassCtorParamProps(
    c: *Checker,
    cls: SymbolId,
    tps: []const TypeParamInfo,
    explicit_targs: []const TypeId,
    node: Node,
) Error!?JsxProps {
    if (try jsxHasManagedAttributes(c)) return null;
    var csigs: std.ArrayList(TypeId) = .empty;
    defer csigs.deinit(c.scratch());
    try c.ctorSignatures(cls, &csigs);
    if (csigs.items.len == 0 or c.ts.fnParamCount(csigs.items[0]) == 0) return null;
    const p0 = c.ts.fnParam(csigs.items[0], 0).ty;
    if (tps.len == 0) return .{ .props = p0, .elem_type = try c.ts.makeRef(cls, &.{}) };
    if (explicit_targs.len == tps.len) {
        const map = try c.scratch().alloc(TpMap, tps.len);
        for (tps, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = explicit_targs[i] };
        return .{
            .props = try c.instantiate(p0, map),
            .elem_type = try c.ts.makeRef(cls, explicit_targs),
        };
    }
    const tp_syms = try c.scratch().alloc(u32, tps.len);
    const tp_tys = try c.scratch().alloc(TypeId, tps.len);
    for (tps, 0..) |tp, i| {
        tp_syms[i] = tp.sym;
        tp_tys[i] = try c.ts.makeTypeParam(tp.sym);
    }
    const sig = try c.ts.makeFunction(
        &.{.{ .name = 0, .ty = p0 }},
        try c.ts.makeRef(cls, tp_tys),
        tp_syms,
        0,
    );
    const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
    const inst_sig = try c.inferJsxTargs(sig, tp_syms, e);
    return .{ .props = c.ts.fnParam(inst_sig, 0).ty, .elem_type = c.ts.fnReturn(inst_sig) };
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
    explicit_targs: []const TypeId,
    node: Node,
) Error!JsxProps {
    // Without a props member to infer THROUGH there is nothing to infer FROM:
    // only explicit type arguments can pin the instance down.
    const name = (try c.jsxPropsMemberName()) orelse return .{
        .props = null,
        .elem_type = if (explicit_targs.len == tps.len) try c.ts.makeRef(cls, explicit_targs) else types.no_type,
    };
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
        const gp = (try c.propOfType(try c.resolveStructural(generic_inst), name)) orelse
            return .{ .props = null, .elem_type = generic_inst };
        const sig = try c.ts.makeFunction(
            &.{.{ .name = name, .ty = gp.ty }},
            generic_inst,
            tp_syms,
            0,
        );
        const e = c.tree.extraData(ast.JsxElementData, c.tree.nodeData(node).lhs);
        break :blk c.ts.fnReturn(try c.inferJsxTargs(sig, tp_syms, e));
    };
    const p = (try c.propOfType(try c.resolveStructural(inst), name)) orelse
        return .{ .props = null, .elem_type = inst };
    return .{ .props = try c.withIntrinsicClassAttributes(p.ty, inst), .elem_type = inst };
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
/// interface is absent or empty. Only the TS2607 report reads this; the props
/// resolution itself goes through `jsxPropsSelector`, which distinguishes the
/// two null cases.
pub fn jsxPropsMemberName(c: *Checker) Error!?Atom {
    return switch (try jsxPropsSelector(c)) {
        .member => |m| m,
        else => null,
    };
}

/// Where a CLASS component's attributes target lives — tsc's
/// `getJsxPropsTypeFromClassType`, which reads `JSX.ElementAttributesProperty`
/// and branches three ways, not two:
///
///   - no such interface at all → the construct signature's FIRST PARAMETER
///     ("return the type of the first parameter of the signature, which should
///     be the els props type");
///   - the interface exists but declares no property → the signature's RETURN,
///     i.e. the element class instance itself;
///   - otherwise → that property, read off the return type.
///
/// ztsc collapsed the first two into "no target, leave the attributes
/// unchecked", which is a real under-report: a `declare namespace JSX` that
/// only spells `Element`/`IntrinsicElements` — the shape of every fixture
/// written before `ElementAttributesProperty` existed, and of any program whose
/// JSX namespace is module-scoped and therefore invisible (`jsxNamespaceMember`)
/// — lost every attribute check AND every attribute's contextual type, so a
/// callback attribute's parameters came back implicit `any`.
///
/// The FUNCTION-component path never asks: tsc's `getJsxPropsTypeFromCallSignature`
/// takes the first parameter unconditionally.
const JsxPropsSelector = union(enum) {
    first_param,
    instance,
    member: Atom,
};

fn jsxPropsSelector(c: *Checker) Error!JsxPropsSelector {
    const t = (try c.jsxNamespaceType(c.atom_ElementAttributesProperty)) orelse return .first_param;
    const rt = try c.resolveStructural(t);
    if (c.ts.kind(rt) != .object) return .first_param;
    if (c.ts.objectPropCount(rt) == 0) return .instance;
    return .{ .member = c.ts.objectProp(rt, 0).name };
}

/// Apply `JSX.LibraryManagedAttributes` for real (`libraryManagedAttributes`)
/// instead of surrendering the props target wherever the namespace declares
/// one (`jsxHasManagedAttributes`). ON since wave 47.
///
/// The transform is a rule of the LIBRARY, not of the language: whatever the
/// namespace's alias says happens to the props type before a single attribute
/// is checked. React's is `Defaultize<P, typeof C.defaultProps>` plus the
/// `propTypes` widening — both of which only LOOSEN — but emotion's is
/// `P & { css: string }`, which tightens nothing and adds a name, and a
/// hand-rolled one can say anything at all. So "declares one" was never a
/// verdict; it was a stand-in for evaluating it, kept while the prerequisite
/// (`generics.inferFromExtendsInner` walking a `.class_value`'s statics, so
/// `C extends { defaultProps: infer D }` can match) was missing.
///
/// CORRECTNESS, unchanged from wave 45 through the wave-47 sweep that shipped
/// it:
///
///   * ts-suite: ZERO match -> non-match over 8641 run cases, +1 exact
///     (`jsxLibraryManagedAttributesUnusedGeneric`, emotion's
///     `WithCSSProp<P> = P & { css: string }`), -15 missing keys / +2 excess
///     (`tsxLibraryManagedAttributes` 15/15 tsgo keys, two residual excess —
///     see below). Only those two cases moved in the whole sweep.
///   * both apps byte-identical to their baselines; `zig build test` green
///     (conformance 1328/1328); the checkers x orders grid byte-identical
///     (80 cells: excalidraw at `tsconfig.tsgo.json`/`tsconfig.json` and
///     social-app at `tsconfig.json`/`tsconfig.check.json`, 1/2/4/8 checkers
///     x 5 root orders) — and every one of those 80 cells is byte-identical
///     BETWEEN the two flag settings, which is the real statement: turning
///     the transform on moves no diagnostic on either app.
///
/// PERF was what kept it off for two waves. Wave 45 measured +15.56 % wall on
/// social-app; wave 46's three memos took that to +2.7 % median / +1.9 % min,
/// a hair over the +2 % gate. Wave 47 settled it by SPLITTING the cost instead
/// of chasing the wall clock on a loaded machine:
///
/// social-app is the whole of the cost: 16 547 component tags over ~1 300
/// DISTINCT component types, and @types/react's chain — `C extends
/// MemoExoticComponent<infer T> | LazyExoticComponent<infer T> ? … :
/// ReactManagedAttributes<C, P>` over a `C extends { defaultProps: infer D }`
/// arm. `jsx_lma_cache` already collapses the per-TAG cost (91 % hit rate,
/// 12 749 hits / 1 300 misses); the misses are irreducible, because the
/// distinct (tag type, props) pairs are ~1:1 with the distinct TAG TYPES.
///
/// The flag does TWO things, and wave 46 had attributed the residue to the
/// wrong one. Besides evaluating the transform, `true` makes
/// `jsxHasManagedAttributes` answer `false`, which re-enables two arms that
/// previously surrendered their props target entirely (`jsxPropsOfSig`'s
/// `.first_param` case and `jsxClassCtorParamProps`) — so `true` genuinely
/// checks attributes that `false` never checked at all. A third binary with
/// those arms enabled but the transform NOT evaluated separates the two, and
/// it measures **+0.00 % min / +0.00 % median** against `false`: the extra
/// attribute checking is free, and a `Defaultize<…>` target costs nothing
/// extra to check against — which it could not, on this app: social-app's
/// React declares `C extends { defaultProps: infer D } ? Defaultize<P, D> : P`
/// and the app has no `defaultProps` at all, so every tag takes the `: P` arm
/// and gets back the SAME TypeId it came in with.
///
/// So the whole delta is the transform's own evaluation, and that is
/// measurable without a wall clock. Five independent 1 ms sampling profiles of
/// a `--workers=1 --checkers=1` social-app run, against a binary with
/// `computeLibraryManagedAttributes` marked `noinline` so it has its own
/// frame, put its INCLUSIVE cost at 1.2 / 1.3 / 1.4 / 1.5 / 1.6 % — 318 of
/// 22 565 samples, **1.41 %**. That is load-immune where a wall clock is not
/// (the machine this was settled on ran at load average 8-34, and the same
/// interleaved min-of-N A/B read +1.54 % at load 11 and +4.17 % at load 20),
/// and it is an UPPER bound twice over: the `noinline` frame is call overhead
/// the shipped binary does not pay, and part of the subtree is instantiation
/// the rest of the run would have done anyway.
///
/// Under it: `subst.instantiate` 91 %, split between `generics.planConditional`,
/// `subst.instantiateId` and `containsFreeTypeParamInner`, with `assign.relate`
/// only 4 %. The lever is the alias-body instantiation machinery, not this
/// file and not the relation — there is nothing left to memoize here (the
/// `jsx_lma_cache` misses are ~1:1 with the distinct tag types, and a memo
/// keyed on the tag type alone was measured and saves nothing).
///
/// Elsewhere: excalidraw -1.05 % min, and zod / drizzle / typebox flat
/// (-0.22 % / +0.12 % / -1.96 % min) — as they must be, since none has JSX.
///
/// Kept as a compile-time const rather than inlined so the two behaviours stay
/// one binary apart — see `assign.measured_variance_decides` for the same
/// pattern. Flip it to `false` to re-measure.
///
/// TWO RESIDUAL EXCESS KEYS at `true` (`tsxLibraryManagedAttributes.tsx`
/// 60:12 and 103:12), and they are NOT this seam: a `Defaultize`-shaped alias
/// instantiated with a TYPE PARAMETER in its key set and an `infer` binder
/// supplying the excluded keys loses the split. Minimal repro — the first is
/// correct, the second is not, and they differ only in `TProps`:
///
///     Lma<Ctor, {}>            where Lma<C, TProps> = C extends
///       { defaultProps: infer D; propTypes: infer P }
///         ? Defaultize<TProps & InferredPropTypes<P>, D> : TProps
///
/// gives `{ bar; baz; foo }` (foo REQUIRED) `& { foo? }`, while writing `{}`
/// in place of `TProps` gives the right `{ bar; baz } & { foo? } & { foo? }`.
/// The `Extract` map comes back empty and the `Exclude` map keeps every key.
const jsx_lma = true;

/// tsc's `getJsxManagedAttributesFromLocatedAttributes`: run the located props
/// type through `JSX.LibraryManagedAttributes<TagType, Props>` before anything
/// checks an attribute against it.
///
/// `ctor` is `getStaticTypeOfReferencedJsxConstructor`'s answer — for a
/// component tag, the type of the tag expression itself (the class's STATIC
/// side, which is what carries `defaultProps`/`propTypes`).
///
/// Both of tsc's arms are covered by `namedTypeFromSymbol`, which instantiates
/// an alias and an interface alike; the shared precondition is tsc's
/// `length(params) >= 2`. Two arguments are supplied and the rest are left to
/// `fixTypeArgs` to fill from their DEFAULTS, which is `fillMissingTypeArguments`
/// with `minTypeArgumentCount = 2`. A declaration whose third parameter has no
/// default is where the two part ways — tsc fills `unknown`, `fixTypeArgs` would
/// report a TS2314 against a synthetic span — so that shape declines instead.
///
/// Memoized on `Checker.jsx_lma_cache`: this runs once per COMPONENT TAG, and
/// leaving it un-memoized is +20% single-threaded wall on social-app. See the
/// field for the measurement and for why the namespace member is part of the
/// key.
fn libraryManagedAttributes(c: *Checker, ctor: TypeId, props: TypeId) Error!TypeId {
    const sym = (try c.jsxNamespaceMember(c.atom_LibraryManagedAttributes)) orelse return props;
    const key: checker_zig.JsxLmaKey = .{ .sym = sym, .ctor = ctor, .props = props };
    if (c.jsx_lma_cache.get(key)) |t| return t;
    // Scope the truncation flag exactly as `eraseParamsOf` does: the memo must
    // ask "was MY result truncated", not "did anything earlier trip".
    const outer_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or outer_trip;
    const managed = try computeLibraryManagedAttributes(c, sym, ctor, props);
    if (!c.inst_limit_tripped) try c.jsx_lma_cache.put(c.cm(), key, managed);
    return managed;
}

/// The pure half of `libraryManagedAttributes`: `sym` is the already-resolved
/// `JSX.LibraryManagedAttributes` declaration, and the answer is a function of
/// (`sym`, `ctor`, `props`) alone.
fn computeLibraryManagedAttributes(c: *Checker, sym: SymbolId, ctor: TypeId, props: TypeId) Error!TypeId {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len < 2) return props;
    var required: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) required += 1;
    }
    if (required > 2) return props;
    const managed = try c.namedTypeFromSymbol(sym, &.{ ctor, props }, 0);
    // A declaration that is neither alias nor interface answers `any_type`
    // here; an arity/cycle failure answers `error_type`. Neither is a props
    // target, and tsc reaches neither, so keep the located type.
    if (managed == types.error_type or managed == types.any_type) return props;
    return managed;
}

/// Does the JSX namespace declare `LibraryManagedAttributes`? The `!jsx_lma`
/// leg's stand-in for evaluating it (see `jsx_lma`): the transform's whole job
/// in React is to make props OPTIONAL — `Defaultize<P, typeof C.defaultProps>`
/// and the `propTypes` widening both only ever loosen the target — so a
/// namespace that declares one is a namespace where an un-managed props type is
/// known to be too strict, and every missing/excess complaint against it is a
/// false positive: `tsxLibraryManagedAttributes` grew 18 of them the moment the
/// first-parameter arm below started answering.
///
/// Consulted only by the arms that had NO target at all before, so this cannot
/// take a check away from anything that already worked.
fn jsxHasManagedAttributes(c: *Checker) Error!bool {
    if (jsx_lma) return false;
    return (try c.jsxNamespaceMember(c.atom_LibraryManagedAttributes)) != null;
}

/// The type of the tag's `defaultProps` static, or `no_type` when the tag has
/// none (or is intrinsic, which cannot carry one). Its property NAMES are the
/// props tsc's `Defaultize` turns optional; only the missing-required-prop
/// loop consults it, and only to take a complaint away, so a wrong answer here
/// can never manufacture a diagnostic.
///
/// Reads the tag's ALREADY-CHECKED type out of the memo rather than checking
/// the tag again: `checkJsxElement` types the tag before any of this runs, and
/// a second `checkExprCached` from inside the attribute walk would re-enter
/// signature selection for an overloaded component.
fn jsxDefaultPropsType(c: *Checker, tag: Node, is_component: bool) Error!TypeId {
    if (!is_component or tag == null_node) return types.no_type;
    // `Defaultize` is not a rule of the language — it is whatever the JSX
    // namespace's `LibraryManagedAttributes` says, and React's is what turns
    // `defaultProps` names optional. A namespace that declares no such member
    // gets NO transform, and the oracle duly reports the missing prop even
    // when a `defaultProps` static supplies it (verified on a hand-rolled
    // namespace). So the suppression is gated on the same member
    // `jsxHasManagedAttributes` looks for.
    if (!try jsxHasManagedAttributes(c)) return types.no_type;
    const tag_ty = c.nodeType(tag) orelse return types.no_type;
    const p = (try c.propOfType(try c.resolveStructural(tag_ty), try c.atom("defaultProps"))) orelse
        return types.no_type;
    return c.resolveStructural(p.ty);
}

/// One explicit (literal) JSX attribute gathered during the first pass.
pub const JsxAttr = struct {
    name: Atom,
    ty: TypeId,
    value: Node,
    name_tok: TokenIndex,
    overwritten: bool = false, // shadowed by a later `{...spread}` (TS2783)
    /// A hyphenated name (`data-*`, `aria-*`). tsc waives it in exactly two
    /// places: `isKnownProperty` answers TRUE for it whatever the target
    /// declares (so it is never EXCESS), and `generateJsxAttributes` skips it
    /// (so it is never ELABORATED per attribute). It is still a member of the
    /// attributes object, so a value the target's prop rejects still fails the
    /// whole-object relation — and, with no elaboration to explain it, lands
    /// as the plain TS2322 anchored at the tag.
    hyphenated: bool = false,
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
    // Aligned with `provided`: did this entry come from a `{...spread}` rather
    // than a written attribute? tsc's `generateJsxAttributes` yields no spread,
    // so a spread-contributed property is invisible to the elementwise
    // elaboration and can only be answered by the whole-object report — the
    // same split `JsxAttr.hyphenated` draws for the other unelaborated name.
    var from_spread: std.ArrayList(bool) = .empty;
    defer from_spread.deinit(c.scratch());
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
            // tsc's `getContextualTypeForJsxAttribute` gives a SPREAD the
            // contextual type of the whole attributes object — the props
            // target itself (`return getContextualType(attribute.parent)`),
            // not a per-name lookup as a written attribute gets. Without it
            // `<test1 {...{x: (n) => n.len}} />` types the spread's object
            // literal context-free and `n` goes implicit-any
            // (tsxAttributeResolution4).
            const sty = try c.resolveStructural(try c.checkExprCached(sd.lhs, props));
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
            while (from_spread.items.len < provided.items.len) try from_spread.append(c.scratch(), true);
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
        const name = try c.memberAtom(name_tok);
        // A hyphenated name (`data-*`, `aria-*`) IS a property of the
        // attributes object tsc builds — `createJsxAttributesType` puts every
        // attribute in it — and it is only `isKnownProperty` that waives it
        // (`isComparingJsxAttributes && isHyphenatedJsxName(name)`), i.e. the
        // EXCESS check. So it counts as PROVIDED — `<ToolButton type="button"
        // aria-label={…} />` satisfies a required `"aria-label": string`, and
        // dropping it reported TS2322 on 38 excalidraw elements the moment
        // discrimination narrowed their props union to the one arm — AND it
        // is related to the prop it lands on when the target declares one:
        // `<test1 data-foo={32}/>` against `{ "data-foo"?: string }` is a
        // TS2322, because `isKnownProperty` waives the excess verdict, not
        // the relation.
        try provided.append(c.scratch(), .{ .name = name, .ty = vty });
        try from_spread.append(c.scratch(), false);
        try built.append(c.scratch(), .{
            .name = name,
            .ty = vty,
            .value = ad.lhs,
            .name_tok = name_tok,
            .hyphenated = c.tree.tokens.tag(name_tok) == .jsx_name,
        });
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
    // `children`) — count it as provided.
    //
    // INTRINSIC tags included: tsc builds one attributes object per JSX element
    // in `createJsxAttributesTypeFromAttributesProperty`, which knows nothing
    // about intrinsic-vs-component and folds the children in either way. Gating
    // this on components made every `<h1>text</h1>` whose declared props require
    // `children` a false TS2741 — the children were right there in the tag.
    if (has_children) {
        try provided.append(c.scratch(), .{ .name = try c.jsxChildrenAttrName(), .ty = types.any_type });
        try from_spread.append(c.scratch(), false);
    }

    // ---------------------------------------------------------------- verdicts
    // tsc's `checkTypeRelatedToAndOptionallyElaborate` is a THREE-stage
    // pipeline, and the stages are ordered:
    //
    //     if (isTypeRelatedTo(source, target, relation)) return true;  // silent
    //     if (!elaborateError(expr, ...)) return checkTypeRelatedTo(..., errorNode);
    //
    // The whole ATTRIBUTES OBJECT is related first, silently; only when that
    // relation FAILS does `elaborateJsxComponents` → `elaborateElementwise`
    // run and report per attribute; and only when the elaboration reported
    // NOTHING does the whole-object diagnostic (excess property, missing
    // required prop, weak type) land. So the per-attribute walk below runs
    // twice: once to reach a verdict in silence, and — only past the
    // whole-object gate — once more to report.
    var first_excess: Span = .{ .start = 0, .end = 0 };
    var have_excess = false;
    // Some attribute's value was rejected by the prop it lands on. tsc's
    // `elaborateElementwise` `continue`s over an attribute the target does
    // not know, so an EXCESS attribute never sets this; only a known prop
    // whose value mismatches does.
    //
    // Split by WHY, because the whole-object gate below can only re-decide one
    // of the two: ztsc's relation is memoized on type pairs and so cannot see
    // freshness (see assign_report.zig's header), which is why the fresh-literal
    // rejections are taken here, per expression, and stand on their own.
    var attr_failed = false;
    var attr_fresh_failed = false;
    // A HYPHENATED attribute whose value the target's own prop rejects. It is
    // kept apart from `attr_failed` because the elaboration below will not
    // report it (tsc's `generateJsxAttributes` skips hyphenated names), so it
    // has to be answered by the whole-object report instead.
    var hyphen_failed = false;
    for (built.items) |b| {
        // The type the ATTRIBUTES OBJECT carries for this name, which is the
        // written value's unless a later spread overwrote it (TS2783). tsc's
        // `elaborateElementwise` reads `getIndexedAccessType(source, name)` —
        // the object's member — while anchoring at the written attribute's
        // NAME node, so an overwritten attribute is still elaborated, and
        // with the SPREAD's type: `<test1 x="ok" {...{x: 32}} />` against
        // `{ x: string }` is a TS2322 at the `x`, not at the tag
        // (`tsxAttributeResolution3`).
        const sty = if (b.overwritten)
            (providedType(provided.items, b.name) orelse continue)
        else
            b.ty;
        if (try jsxAttrTarget(c, rt, b.name, sty)) |target| {
            // Mirrors the elaboration loop below: an attribute the elaboration
            // will skip cannot be the reason it runs.
            if (elaborate.skipsDeferredIndexAccess(c, target)) continue;
            // tsc's `isIgnoredJsxProperty`: `membersRelatedToIndexInfo` skips
            // a hyphenated attribute outright, so an INDEX SIGNATURE standing
            // in for the name says nothing about its value —
            // `<MyComponent data-bar='hello'/>` against
            // `{ [s: string]: boolean }` is clean. Only a prop the target
            // DECLARES relates it (`propertiesRelatedTo` has no such waiver).
            if (b.hyphenated and !try jsxDeclaresName(c, rt, b.name)) continue;
            if (!try c.isAssignable(sty, target)) {
                if (b.hyphenated) hyphen_failed = true else attr_failed = true;
            } else if (!b.hyphenated and !b.overwritten and b.value != null_node and
                try c.freshLiteralRejects(b.value, b.ty, target))
            {
                // Freshness belongs to the WRITTEN expression, so an
                // overwritten attribute has none to contribute.
                attr_fresh_failed = true;
            }
        } else if (!b.overwritten and target_open and !b.hyphenated and !containsAtom(ia_names.items, b.name)) {
            if (!have_excess) {
                first_excess = c.tokSpan(b.name_tok);
                have_excess = true;
            }
        }
    }

    // Missing required props, and the weak-type check. Both are whole-object
    // verdicts, and both are skipped when a spread's contents are opaque —
    // any required prop might come from it, and a false positive there is
    // worse than the under-report.
    const whole_object_checkable = is_obj_target and !(has_spread and spread_opaque);

    const weak_hit = whole_object_checkable and has_spread and target_open and
        try jsxWeakTypeHit(c, rt, target_props.items, provided.items, ia_names.items, spread_non_object);
    // A prop the tag's own `defaultProps` supplies is never missing (see
    // `jsxMissingRequiredProp`); not evaluated at all when the weak-type
    // verdict already stands, since that report wins.
    const missing_hit = whole_object_checkable and !weak_hit and
        try jsxMissingRequiredProp(c, e, target_props.items, provided.items, is_component);

    // A property the attributes object gets from a `{...spread}`, whose value
    // the target's own prop rejects. tsc's `generateJsxAttributes` skips
    // spreads, so `elaborateElementwise` produces nothing for it and
    // `checkTypeRelatedTo` prints its own TS2322 at the tag with the property
    // chain underneath — exactly the `hyphen_failed` shape, and reported
    // through the same arm. `<div {...{text: 42}} />` against
    // `{ text?: string }`.
    //
    // Reached only when nothing ELSE has a verdict, and only past tsc's silent
    // first stage — which is both the faithful order (`isTypeRelatedTo` before
    // `elaborateError`) and the cheap one. The per-property walk it guards is
    // quadratic in the attribute count and asks the relation once per name; a
    // react-native `{...props}` spreads a ~250-property type, so running it on
    // every clean element would have cost more than the whole check. The
    // whole-object query costs ONE relation, is memoized on the type pair, and
    // is the same one the reporting path below re-asks.
    //
    // Inside it: only the LAST contributor of a name is in the object (later
    // wins), and a name some WRITTEN attribute also carries is the
    // elaboration's to report — it has a name node to anchor at, and the walk
    // above already took that name's verdict from the object's member type.
    //
    // Gated on `whole_object_checkable` for the reason every other
    // whole-object verdict is: with an un-enumerable spread the source type
    // ztsc can spell is not the one tsc relates.
    var spread_failed = false;
    if (whole_object_checkable and has_spread and
        !attr_failed and !attr_fresh_failed and !hyphen_failed and
        !have_excess and !weak_hit and !missing_hit and
        !try c.isAssignable(try c.jsxAttrsObject(provided.items, .relate), props))
    {
        for (provided.items, 0..) |p, i| {
            if (!from_spread.items[i]) continue;
            if (lastProvidedIndex(provided.items, p.name) != i) continue;
            if (namedAttr(built.items, p.name)) continue;
            const target = (try jsxAttrTarget(c, rt, p.name, p.ty)) orelse continue;
            if (elaborate.skipsDeferredIndexAccess(c, target)) continue;
            if (!try c.isAssignable(p.ty, target)) {
                spread_failed = true;
                break;
            }
        }
    }

    // Nothing to say: neither the elaboration nor the whole-object report has
    // a candidate, so tsc's silent first stage cannot change the outcome and
    // is not paid for. This is the overwhelmingly common path, and it is why
    // the split walk costs nothing on it.
    if (!attr_failed and !attr_fresh_failed and !hyphen_failed and !spread_failed and
        !have_excess and !weak_hit and !missing_hit) return;

    // tsc's silent first stage. The attributes object is built UNWIDENED (so
    // `variant="a"` still satisfies `"a" | "b"`) and NOT fresh. A target that
    // reads its props as a UNIT — a union of variants, an intersection under a
    // mapped type — can accept the object whole where the per-property walk,
    // which picks a target for each name independently, cannot; and a required
    // prop "missing" from one union arm is not missing from the object.
    //
    // Skipped when the rejection is a FRESHNESS one (an excess attribute name,
    // or an attribute value that is a fresh literal carrying a name its prop
    // does not know). Those verdicts were reached from the expressions, which
    // is the only place ztsc can see freshness at all — a non-fresh probe
    // object cannot restate them, so it must not be allowed to overturn them.
    if (!have_excess and !attr_fresh_failed and
        try c.isAssignable(try c.jsxAttrsObject(provided.items, .relate), props)) return;

    // ------------------------------------------------------------ elaboration
    var attr_elaborated = false;
    for (built.items) |b| {
        // tsc's `generateJsxAttributes` yields neither a spread nor a
        // hyphenated name, so neither is ever the subject of an elementwise
        // elaboration; a hyphenated mismatch is answered at the tag below.
        if (b.hyphenated) continue;
        // Same source type the verdict walk used (see there): the attributes
        // object's member, not necessarily this attribute's written value.
        const sty = if (b.overwritten)
            (providedType(provided.items, b.name) orelse continue)
        else
            b.ty;
        if (try jsxAttrTarget(c, rt, b.name, sty)) |target| {
            if (elaborate.skipsDeferredIndexAccess(c, target)) continue;
            // tsc anchors a JSX attribute value mismatch at the attribute
            // NAME node (not the value), matching the excess-property anchor
            // above. Per-member elaboration for object/array-literal values
            // still points at the offending member via `b.value` — which an
            // overwritten attribute does not own, so it elaborates bare.
            const val = if (b.overwritten) null_node else b.value;
            if (!try c.checkAssignable(sty, target, val, c.tokSpan(b.name_tok))) attr_elaborated = true;
        }
    }

    if (!is_obj_target) return; // lenient target: value checks only

    // An attribute-level elaboration already reported: tsc stops here. This is
    // a real suppression, not a cosmetic one — tsc's error lands on the narrow
    // attribute node, where a `@ts-expect-error` written above that attribute
    // absorbs it, while the whole-object error would land on a line no
    // directive covers.
    if (attr_elaborated) return;

    // ------------------------------------------------------- whole-object report
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
            try c.typeToString(try c.jsxAttrsObject(provided.items, .display)),
            try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }

    if (weak_hit) {
        const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
        const src_ty = if (last_spread_ty != types.no_type)
            last_spread_ty
        else
            try c.jsxAttrsObject(provided.items, .display);
        try c.diagFmt(2559, span, "Type '{s}' has no properties in common with type '{s}'.", .{
            try c.typeToString(src_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }

    const span = if (e.tag != null_node) c.nodeSpan(e.tag) else c.nodeSpan(node);
    if (!missing_hit) {
        // A rejected HYPHENATED attribute is the one whole-object relation
        // failure ztsc's per-attribute walk sees but cannot report where tsc
        // reports it: `generateJsxAttributes` skipped it, so tsc's
        // elaboration produced nothing and `checkTypeRelatedTo` printed its
        // own message at the tag, with the property chain underneath.
        // `<test1 data-foo={32}/>` against `{ "data-foo"?: string }`.
        // A SPREAD-contributed property is the other one, for the identical
        // reason (`generateJsxAttributes` skips spreads too) — `spread_failed`
        // is already gated on `whole_object_checkable` where it is computed.
        //
        // Gated on `whole_object_checkable` for the reason every other
        // whole-object verdict is: with an un-enumerable spread the source
        // type ztsc can spell is not the one tsc relates (tsc keeps the
        // spread's own type in the intersection), so the message would name a
        // type the element does not have and the refinement machinery would
        // read a "missing" prop the spread supplies.
        if (spread_failed or (hyphen_failed and whole_object_checkable)) {
            try c.reportNotAssignable(
                2322,
                try c.jsxAttrsObject(provided.items, .display),
                props,
                span,
            );
        }
        return;
    }
    if (spread_non_object) {
        // The attributes' source type is the primitive spread itself —
        // plain TS2322 (a primitive never gets the missing-prop codes).
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(last_spread_ty), try c.jsxTargetString(props, has_intrinsic_attrs),
        });
        return;
    }
    const combined = try c.jsxAttrsObject(provided.items, .display);
    if (raw_2322) {
        try c.diagFmt(2322, span, "Type '{s}' is not assignable to type '{s}'.", .{
            try c.typeToString(combined), try c.jsxTargetString(props, true),
        });
    } else {
        try c.reportNotAssignable(2322, combined, props, span);
    }
}

/// Does the props target DECLARE `name` as a member, rather than merely
/// covering it with an index signature? The distinction is what
/// `isIgnoredJsxProperty` draws: it takes a hyphenated attribute out of
/// `membersRelatedToIndexInfo` and out of nothing else, so an index signature
/// says nothing about such a value while a declared prop still relates it.
fn jsxDeclaresName(c: *Checker, rt: TypeId, name: Atom) Error!bool {
    var via_index = false;
    if ((try c.propOfTypeViaIndex(rt, name, &via_index)) != null and !via_index) return true;
    return false;
}

/// tsc's `isHyphenatedJsxName`: an attribute name containing a `-` (`data-*`,
/// `aria-*`, `ignore-prop`). `isKnownProperty` answers TRUE for such a name
/// whenever it is comparing JSX attributes, whatever the target declares —
/// the escape hatch that lets arbitrary DOM attributes through a props type.
///
/// The direct-attribute path recognizes the same names by TOKEN TAG
/// (`.jsx_name`, which the scanner only produces for a hyphenated attribute
/// name); a name arriving through a SPREAD is a string-literal key of an
/// ordinary object type and has no token to read, so it is spelled out here.
fn isHyphenatedJsxName(c: *Checker, name: Atom) bool {
    return std.mem.indexOfScalar(u8, c.atomText(name), '-') != null;
}

/// What `jsxAttrsObject` is being built for.
pub const JsxAttrsUse = enum {
    /// The source type of a whole-object TS2322/2741/2739/2559 message, and
    /// the inference candidate for a naked type-parameter props target:
    /// literals widened (`label="x"` prints as `label: string`, matching
    /// tsc's messages) and flagged fresh.
    display,
    /// The source of the silent whole-object relation: literals KEPT (so
    /// `variant="a"` still satisfies `"a" | "b"`) and not fresh — the
    /// excess-property verdict is taken by name, with the hyphenated-name
    /// waiver `isKnownProperty` applies.
    relate,
};

/// Build the object type standing in for the written attributes — the
/// combined explicit + spread-provided props, later occurrence winning.
pub fn jsxAttrsObject(c: *Checker, provided: []const types.Prop, use: JsxAttrsUse) Error!TypeId {
    var out: std.ArrayList(types.Prop) = .empty;
    defer out.deinit(c.scratch());
    for (provided) |p| {
        const ty = if (use == .display) try c.widenLiteral(p.ty) else p.ty;
        var replaced = false;
        for (out.items) |*o| {
            if (o.name == p.name) {
                o.ty = ty; // later wins
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(c.scratch(), .{ .name = p.name, .ty = ty });
    }
    return c.ts.makeObject(out.items, 0, 0, if (use == .display) types.obj_flag_fresh else 0);
}

/// Index of the LAST entry naming `name` — the one whose value the combined
/// attributes object actually carries (`jsxAttrsObject`'s "later wins").
fn lastProvidedIndex(provided: []const types.Prop, name: Atom) usize {
    var found: usize = 0;
    for (provided, 0..) |p, i| {
        if (p.name == name) found = i;
    }
    return found;
}

/// The type the combined attributes object carries for `name`, or `null` when
/// no contributor named it.
fn providedType(provided: []const types.Prop, name: Atom) ?TypeId {
    var found: ?TypeId = null;
    for (provided) |p| {
        if (p.name == name) found = p.ty;
    }
    return found;
}

/// Is `name` written as an attribute (so an elementwise elaboration can anchor
/// at its name node), rather than reaching the object only through a spread?
fn namedAttr(built: []const JsxAttr, name: Atom) bool {
    for (built) |b| {
        if (b.name == name and !b.hyphenated) return true;
    }
    return false;
}

/// The type one written attribute's value is checked against, or `null` when
/// the props target declares no home for that name (an EXCESS attribute, or
/// one on a target with an index signature).
///
/// Shared by the silent verdict pass and the reporting elaboration so the two
/// cannot disagree about what an attribute is compared to.
fn jsxAttrTarget(c: *Checker, rt: TypeId, name: Atom, ty: TypeId) Error!?TypeId {
    if (try c.propOfType(rt, name)) |p| {
        // An optional prop (`date?: Date`) admits `undefined`, so an explicit
        // `date={maybeUndefined}` is not an error — mirrors the structural
        // object relation and the optional indexed-access path
        // (src/checker.zig:2864). Widen the target to `p.ty | undefined` ONLY
        // when the value can actually be undefined: a value that never yields
        // `undefined` (e.g. a fresh object literal) gets the identical verdict
        // from bare `p.ty`, and keeping it off the object-to-union path avoids
        // a distinct union-relation gap. A required prop keeps `p.ty`, so an
        // explicit `undefined` on it still rejects.
        if (p.optional() and c.containsUndefinedish(try c.resolveStructural(ty))) {
            return try c.makeUnion2(p.ty, types.undefined_type);
        }
        return p.ty;
    }
    // A prop that lives in a UNION member of an intersection props type
    // (`Base & (VariantA | VariantB)`) is not found by `propOfType`, so its
    // value used to go unchecked — and, since the excess arm only fires for an
    // open target, silently. Check it against the union of the arms that
    // declare it, the same type the attribute's contextual lookup uses.
    return try c.unionNestedPropType(rt, name);
}

/// tsc's weak-type check for a JSX element (TS2559): the target has only
/// optional props and the (spread-provided) attributes share none of them.
/// Fires only for fully-enumerated spread sources — explicit-attr mismatches
/// are excess (TS2322), and opaque spreads are skipped by the caller.
fn jsxWeakTypeHit(
    c: *Checker,
    rt: TypeId,
    target_props: []const types.Prop,
    provided: []const types.Prop,
    ia_names: []const Atom,
    spread_non_object: bool,
) Error!bool {
    if (target_props.len == 0 and ia_names.len == 0) return false;
    for (target_props) |tp| if (!tp.optional()) return false;
    if (!spread_non_object and provided.len == 0) return false;
    for (provided) |pp| {
        if (isHyphenatedJsxName(c, pp.name) or
            (try c.propOfType(rt, pp.name)) != null or
            containsAtom(ia_names, pp.name)) return false;
    }
    return true;
}

/// Does the element leave a required prop unprovided?
///
/// A prop the tag's own `defaultProps` supplies is never missing: tsc's
/// `getJsxManagedAttributesFromLocatedAttributes` runs the props type through
/// `Defaultize<P, typeof C.defaultProps>` BEFORE anything checks a required
/// prop, which turns exactly those names optional. ztsc does not apply the
/// transform (see `jsxHasManagedAttributes`), so the same names are excused
/// here instead — `BackButton.defaultProps = { text: … }` is what makes
/// `<BackButton />` legal against a required `text`.
///
/// `defaultProps` is resolved LAZILY: `jsxNamespaceMember` re-walks the
/// factory and runtime modules on every call, and an element that supplies all
/// its required props must not pay for that. `null` means "not looked up yet";
/// the lookup happens at most once, on the first prop that would be reported.
fn jsxMissingRequiredProp(
    c: *Checker,
    e: ast.JsxElementData,
    target_props: []const types.Prop,
    provided: []const types.Prop,
    is_component: bool,
) Error!bool {
    var defaults: ?TypeId = null;
    for (target_props) |tp| {
        if (tp.optional()) continue;
        if (providedHas(provided, tp.name)) continue;
        const d = defaults orelse blk: {
            const t = try jsxDefaultPropsType(c, e.tag, is_component);
            defaults = t;
            break :blk t;
        };
        if (d != types.no_type and (try c.propOfType(d, tp.name)) != null) continue;
        return true;
    }
    return false;
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
            // A name two constituents both declare is ONE property of the
            // spread, and its type is their INTERSECTION — that is what
            // `getPropertiesOfType` synthesizes and what `propOfType`'s
            // intersection arm already computes. Appending each constituent's
            // props separately would leave `provided`'s "later wins" to pick
            // an arbitrary arm instead: social-app's
            // `Omit<ButtonProps, 'hitSlop'> & { color?: string }` spread onto
            // a `color?: "primary" | …` prop then reads as bare `string` and
            // rejects, where tsc relates `("primary" | …) & string` and
            // accepts. Same shape in excalidraw's `Omit<SidebarTriggerProps,
            // "name"> & React.HTMLAttributes<HTMLDivElement>` (`onToggle`).
            var seen: std.ArrayList(Atom) = .empty;
            defer seen.deinit(c.scratch());
            for (try c.memberList(rst)) |m| {
                const r = try c.resolveStructural(m);
                if (c.ts.kind(r) != .object or c.ts.objectStringIndex(r) != 0 or c.ts.objectNumberIndex(r) != 0) {
                    names.deinit(c.scratch());
                    return .unknown_shape;
                }
                for (0..c.ts.objectPropCount(r)) |i| {
                    const p = c.ts.objectProp(r, @intCast(i));
                    if (!p.optional()) try names.append(c.scratch(), p.name);
                    if (containsAtom(seen.items, p.name)) continue;
                    try seen.append(c.scratch(), p.name);
                    try provided.append(c.scratch(), (try c.propOfType(rst, p.name)) orelse p);
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
