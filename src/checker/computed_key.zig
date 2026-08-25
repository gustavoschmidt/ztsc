//! What a computed property NAME is allowed to be (TS2464), and — when it
//! names no property at all — the INDEX SIGNATURE it contributes instead.
//!
//! A computed key has to name a property, and the three things that can name
//! one are a string, a number and a symbol — so tsc's
//! `checkComputedPropertyName` asks whether the key's type is assignable to
//! `string | number | symbol`, with `any` and `never` sliding through as they
//! do everywhere else.
//!
//! The admissible/inadmissible boundary was measured against tsgo 7.0.2 over
//! sixteen key types. Through: `string`, `number`, `symbol`, `any`, `never`, a
//! `unique symbol`, an enum, a template-literal type, `number | string`, and
//! `K extends keyof T`. Reported: `unknown`, `void`, `null`, `undefined`,
//! `boolean`, `bigint`, `object`, a function type, an array type, an
//! unconstrained `T`, `number | number[]`, `string | boolean`, and
//! `typeof Symbol` (the constructor object, not a symbol).
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const literals = @import("../frontend/literals.zig");
const numeric_lit = @import("../numeric_lit.zig");
const types = @import("../types.zig");

const atoms = @import("atoms.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Where a member's computed name sits, for the two rules that care whether a
/// reference in it is real EMITTED code evaluated at class-definition time.
///
///   * `Checker.in_type_space_name` — tsc's `markAliasReferenced` gate. An
///     interface's or a type literal's member name is type space, and an ambient
///     class body is emitted nowhere (the same reason `stmts.zig` skips checking
///     an ambient `extends` clause as a value), so neither is a value use.
///   * `Checker.defer_computed_key_tdz` — tsc's
///     `isInAmbientOrTypeNode || isUsedInFunctionOrInstanceProperty` inside
///     `isBlockScopedNameDeclaredBeforeUse`. A forward reference in a computed
///     name is legal in all of those, AND in a class METHOD's name, because
///     walking up from there hits a function-like node. What is left — the only
///     position that reports — is a non-ambient class FIELD's name.
pub const Home = enum { class_body, ambient_class_body, type_space };

/// Check a `.computed_name` node's key expression, reporting TS2464 when the
/// type it produces cannot name a property. Returns the key type so a caller
/// that also needs it (an object literal deciding what member the key
/// contributes) does not check the expression twice.
///
/// Safe to call on a non-`.computed_name` node, which is what lets a member
/// walk hand over whatever it has for a name.
/// `on_class` says the name belongs to a CLASS member — the one home in which
/// a `this` reference inside it is TS2465 (see `IllegalRefs`). An object
/// literal's name passes `false`, and so does an interface's or type literal's.
pub fn checkComputedName(c: *Checker, name_node: Node, on_class: bool) Error!TypeId {
    if (name_node == null_node or c.nodeTag(name_node) != .computed_name) return types.no_type;
    const expr = c.tree.nodeData(name_node).lhs;
    const want: IllegalRefs = .{ .super = superInNameIsError(c), .this = on_class };
    if (want.super or want.this) try reportIllegalRefs(c, expr, want, 0);
    // A super CALL in the name is this file's TS2466, never the call site's
    // TS2337 — tsc's `checkSuperExpression` tests the computed name first.
    // (wave-20 A: `Checker.in_computed_key`.)
    const saved_key = c.in_computed_key;
    c.in_computed_key = true;
    defer c.in_computed_key = saved_key;
    const kt = try c.checkExprCached(expr, types.no_type);
    try report(c, name_node, kt);
    return kt;
}

/// TS2466: a `super` reference written inside a computed property NAME.
///
/// tsc's `getSuperContainer` steps OVER a ComputedPropertyName — it jumps
/// straight past the owning member and keeps walking — so a `super` in a
/// member's NAME never reaches a legal container, however ordinary the member
/// is: `class C extends B { [super.bar()]() {} }` is an error even though the
/// very same `super.bar()` in that method's BODY is fine.
/// `checkSuperExpression` then re-walks for an enclosing computed name and
/// reports this wording in place of the generic "super outside a constructor"
/// one.
///
/// What the skip LANDS ON is the whole question, and it is a question about
/// the member's surroundings, not about the name: `class C extends B { foo() {
/// var o = { [super.bar()]() {} } } }` skips the object method and finds
/// `C.foo`, which IS a legal container, so tsc is silent — as it is for the
/// same shape wrapped in a nested class expression or in an arrow. So the
/// report is confined to the case where the skip can find nothing at all: no
/// enclosing function-like SCOPE anywhere above the name, i.e. a member of a
/// top-level class. Everything nested stays silent, which under-reports the
/// one shape tsc still errors on (a super CALL inside an arrow,
/// `computedPropertyNames30`) and never invents one.
fn superInNameIsError(c: *Checker) bool {
    var s = c.cur_scope;
    while (true) {
        if (c.bind.scope_kinds[s] == .function) return false;
        if (s == binder.file_scope) return true;
        s = c.bind.scope_parents[s];
    }
}

/// Which of the two keyword references a walk of the name expression should
/// refuse. They share one traversal because they share the boundary exactly:
/// both `getSuperContainer` and `getThisContainer` stop at the same set of
/// nodes on the way out, and step over the same ones.
const IllegalRefs = struct {
    /// TS2466 — see `superInNameIsError` for when this is on.
    super: bool,
    /// TS2465: `this` cannot be referenced in a computed property name.
    ///
    /// tsc's `getThisContainer(node, includeArrowFunctions: true,
    /// includeClassComputedPropertyName: true)` makes a ComputedPropertyName a
    /// `this` container in its own right — but ONLY when its grandparent is
    /// class-like. `checkThisExpression` then reports on that container instead
    /// of switching on the ordinary ones.
    ///
    /// So it is the class-ness of the home that decides, not the name: an
    /// interface's or a type literal's computed name steps over (its `this` is
    /// `typeof globalThis`, and the shape reports TS7017 instead), while an
    /// AMBIENT class body reports exactly like a concrete one.
    this: bool,
};

/// Walk the name expression for an illegal `super`/`this`, stopping at a nested
/// `function`/class boundary: such a node IS the reference's container, and the
/// `getSuperContainer` / `getThisContainer` walk returns it before the computed
/// name is ever reached.
///
/// An ARROW is deliberately absent from the boundary set — it has no `this` or
/// `super` of its own, so `class C { [(() => this.bar())()]() {} }` reports —
/// and so is the OBJECT LITERAL, which lets the walk reach a `this` nested in
/// an inner object literal's own computed name
/// (`[{ [this.bar()]: 1 }[0]]() {}`, `computedPropertyNames23`). A nested CLASS
/// is a boundary for the opposite reason: its members' names get their own
/// `checkMemberNames` pass, so descending would report them twice.
fn reportIllegalRefs(c: *Checker, node: Node, want: IllegalRefs, depth: u16) Error!void {
    if (node == null_node or depth > max_name_depth) return;
    switch (c.nodeTag(node)) {
        .super_expr => if (want.super) return c.diagFmt(
            2466,
            c.nodeSpan(node),
            "'super' cannot be referenced in a computed property name.",
            .{},
        ),
        .this_expr => if (want.this) return c.diagFmt(
            2465,
            c.nodeSpan(node),
            "'this' cannot be referenced in a computed property name.",
            .{},
        ),
        // A reference written inside one of these has IT as its container, so
        // the computed name never enters the answer.
        .function_expr,
        .function_decl,
        .class_decl,
        .class_method,
        .object_method,
        .class_field,
        => return,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try reportIllegalRefs(c, child, want, depth + 1);
}

/// Far above any hand-written key expression; the cap only ever under-reports.
const max_name_depth: u16 = 200;

/// TS2467: a member's computed NAME cannot reference a type parameter of the
/// class or interface that declares it. The name is evaluated once, when the
/// declaration is elaborated, so the type arguments a use site supplies do not
/// exist yet — `class C<T> { [foo<T>()]() {} }` has no `T` to call `foo` with.
///
/// The boundary was measured against tsgo 7.0.2 over twenty shapes, and it is
/// narrower than "any type parameter in scope":
///
///   * only the IMMEDIATELY containing class or interface counts. An enclosing
///     function's parameter is fine, and so is an OUTER class's seen from a
///     class nested in one of its methods.
///   * a TYPE LITERAL never reports, even as the body of a generic type alias
///     (`type D<T> = { [foo<T>()]: number }` is TS1170 alone) — which is why
///     `typenode`'s call passes no type parameters.
///   * the reference has to be in a TYPE position. `class C<T> { [T]() {} }`
///     is TS2304, not this: the value space has no `T` and the type space is
///     never asked.
///   * a STATIC member reports too, and so does a class EXPRESSION's member;
///     every reference reports, so `[foo<[A, B]>()]` is two diagnostics.
///
/// Matched by NAME against the declaration's type-parameter list rather than by
/// resolving the reference: an interface's computed names are checked in the
/// ENCLOSING scope (that is where a computed key is evaluated), so its own type
/// parameters are not in scope to resolve against at all.
fn reportTypeParamRefs(c: *Checker, node: Node, tps: []const Node, depth: u16) Error!void {
    if (node == null_node or depth > max_name_depth) return;
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        // The three ways a TYPE can be written inside an expression. Each
        // hands its type slots to the type-position walk; everything else
        // under this node stays an expression.
        .call_expr_targs, .optional_call, .new_expr_targs => {
            const info = c.tree.extraData(ast.CallInfo, d.rhs);
            for (c.tree.extraRange(info.targs_start, info.targs_end)) |t| {
                try reportTypeParamRefsInType(c, t, tps, depth + 1);
            }
        },
        .instantiation_expr => {
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            for (c.tree.extraRange(r.start, r.end)) |t| {
                try reportTypeParamRefsInType(c, t, tps, depth + 1);
            }
        },
        .as_expr, .satisfies_expr => try reportTypeParamRefsInType(c, d.rhs, tps, depth + 1),
        // A nested declaration of its own is a different containing type — the
        // same boundary `reportIllegalRefs` stops at, and for the same reason.
        .function_expr,
        .function_decl,
        .class_decl,
        .class_method,
        .object_method,
        .class_field,
        => return,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try reportTypeParamRefs(c, child, tps, depth + 1);
}

/// The type-position half of `reportTypeParamRefs`: every `identifier` under
/// here names a TYPE, so one matching a containing type parameter is the
/// reference TS2467 refuses. Nesting is walked whole — `T[]`, `{ a: T }`,
/// `Foo<T>` and `[A, B]` all report, once per reference.
fn reportTypeParamRefsInType(c: *Checker, node: Node, tps: []const Node, depth: u16) Error!void {
    if (node == null_node or depth > max_name_depth) return;
    switch (c.nodeTag(node)) {
        .identifier => {
            const text = c.tokenText(c.tree.nodeMainToken(node));
            for (tps) |tp| {
                if (tp == null_node) continue;
                if (!std.mem.eql(u8, text, c.tokenText(c.tree.nodeMainToken(tp)))) continue;
                return c.diagFmt(
                    2467,
                    c.nodeSpan(node),
                    "A computed property name cannot reference a type parameter from its containing type.",
                    .{},
                );
            }
            return;
        },
        // `typeof x` names a VALUE, and a type parameter is not one — the
        // reference there is a TS2304, not this.
        .typeof_type => return,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try reportTypeParamRefsInType(c, child, tps, depth + 1);
}

/// The computed NAMES of a class body's or an interface's members — tsc's
/// `checkComputedPropertyName`, reached from the declaration walk so it runs in
/// the file that owns the declaration and for an unreferenced container too.
///
/// The key expression is where a computed member's own diagnostics live: an
/// unresolved key is TS2304 (`class C { [nosuch]: number }`), and a key whose
/// type cannot name a property is TS2464. Neither was reachable before the
/// parser retained the expression — the key was a token, resolved by TEXT, and a
/// failed resolution fell back to a name placeholder in silence.
///
/// tsc guards the whole thing on `getNodeLinks(node.expression).resolvedType`
/// being unset, i.e. on the expression not having been checked yet; ztsc's
/// equivalent is the node-type memo, which keeps a second walk over the same
/// members from doubling the reports.
///
/// `home` says whether the member name is EMITTED code — see
/// `Checker.in_type_space_name` for the one diagnostic that turns on.
///
/// `type_params` are the CONTAINING class's or interface's own type-parameter
/// nodes, which a name may not reference (TS2467, see `reportTypeParamRefs`).
/// A type literal has none of its own and passes an empty slice.
pub fn checkMemberNames(c: *Checker, members: []const Node, home: Home, type_params: []const Node) Error!void {
    // Almost every file has no computed member name at all.
    if (c.tree.computed_keys.len == 0) return;
    const saved = c.in_type_space_name;
    const saved_tdz = c.defer_computed_key_tdz;
    const saved_in_name = c.in_computed_member_name;
    defer {
        c.in_type_space_name = saved;
        c.defer_computed_key_tdz = saved_tdz;
        c.in_computed_member_name = saved_in_name;
    }
    c.in_type_space_name = home != .class_body;
    c.in_computed_member_name = true;
    for (members) |m| {
        if (m == null_node) continue;
        const key = c.tree.computedKey(m) orelse continue;
        if (c.node_types.contains(c.nodeKey(c.tree.nodeData(key).lhs))) continue;
        // Only a non-ambient class FIELD's name is a use that can be too early.
        c.defer_computed_key_tdz = home != .class_body or c.nodeTag(m) != .class_field;
        if (type_params.len > 0) {
            try reportTypeParamRefs(c, c.tree.nodeData(key).lhs, type_params, 0);
        }
        _ = try checkComputedName(c, key, home != .type_space);
    }
}

/// TS2464 for a key whose type the caller already has. tsc anchors the report
/// on the whole `[…]` name, so the span starts at the `[`.
pub fn report(c: *Checker, name_node: Node, kt: TypeId) Error!void {
    if (try admissible(c, kt)) return;
    try c.diagFmt(
        2464,
        c.nodeSpan(name_node),
        "A computed property name must be of type 'string', 'number', 'symbol', or 'any'.",
        .{},
    );
}

/// The static member name a computed key `[expr]` declares — tsc's
/// `isLateBindableName` followed by `getLateBoundNameFromType`. A computed name
/// is late-BINDABLE when its type is a string literal, a numeric literal or a
/// unique symbol; every other key (a `string`-typed one, a template type, an
/// `any`) is dynamic and declares no member at all.
///
/// Two of ztsc's spellings sit alongside the type test, because ztsc names the
/// member syntactically where tsc names it from a resolved symbol:
///
///   * `[Symbol.iterator]` is recognized from the SYNTAX (`wellKnownKeyOfExpr`)
///     and keyed `__@iterator`, the way the binder's `memberKey` and the
///     element access in `indexChainInner` both key it. That it is asked BEFORE
///     the general `unique symbol` spelling is load-bearing: in the real lib
///     `Symbol.iterator` IS a `unique symbol`, so keyed by its nominal
///     `__@u<id>` instead, `{ [Symbol.iterator]: 0 }` declared a member no
///     reader of `o[Symbol.iterator]` could find (`symbolProperty18`);
///   * a QUALIFIED enum-member key (`[Breed.X]`) has a value the checker leaves
///     unknown for a computed member, so it is keyed by the same text-derived
///     `__@k$<obj>.<member>` placeholder the binder gives the declaration side.
///
/// `key_type` is the key expression's already-checked type, passed in rather
/// than recomputed: a caller reading it out of the node-type memo then never
/// re-enters the expression walk, and so never re-reports TS2464 on the key.
pub fn lateBoundName(c: *Checker, key_expr: Node, key_type: TypeId) Error!?Atom {
    if (c.wellKnownKeyOfExpr(key_expr)) |wk| return try c.atom(wk);
    // The syntactic recognizer above needs no type, and is the only arm that
    // can answer for a key the checker never typed: a METHOD's computed name is
    // not an expression tsc checks (`symbolProperty1`), so a caller reading the
    // node-type memo has nothing for it. Everything below is a question about
    // the type, and has none to ask.
    if (key_type == types.no_type or key_type == types.error_type) return null;
    if (try c.uniqueSymAtom(key_type)) |a| return a;
    const rk = try c.resolveStructural(key_type);
    switch (c.ts.kind(rk)) {
        .string_literal => return c.ts.dataA(rk),
        .number_literal, .number_literal_fresh => {
            var buf: [numeric_lit.max_name]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            numeric_lit.write(&w, c.ts.numberValue(rk)) catch return null;
            // Stack buffer: intern a copy, never keep the slice.
            return try c.internText(w.buffered());
        },
        .enum_type => {
            if (c.nodeTag(key_expr) != .member_expr) return null;
            const member_tok = c.tree.nodeData(key_expr).rhs;
            return try c.computedSymKey(
                member_tok,
                ast.Flags.computed_sym | ast.Flags.computed_sym_qual,
                c.cur_scope,
            );
        },
        else => return null,
    }
}

/// A computed name AS WRITTEN, brackets included — tsc's `symbolToString` of a
/// late-bound property, which is `getTextOfNode` on the declaration's name
/// (`'[Symbol.toPrimitive]'`, `'["zzz"]'`, `'[E.A]'`), never the synthetic atom
/// the member is keyed by.
///
/// The node's own span ends at the key EXPRESSION, so the closing bracket is
/// scanned for. Bounded: a name node the parser recovered from may have no `]`
/// at all, and the un-terminated text is a better answer than a runaway slice.
pub fn nameText(c: *const Checker, name_node: Node) []const u8 {
    const sp = c.nodeSpan(name_node);
    const limit = @min(c.src.len, sp.end + max_bracket_scan);
    var end = sp.end;
    while (end < limit and c.src[end] != ']') end += 1;
    if (end < limit) end += 1 else return c.src[sp.start..sp.end];
    return c.src[sp.start..end];
}

/// How far past a computed name's key expression its `]` is looked for. Only
/// trivia can sit in between, and a comment is the only trivia with any length.
const max_bracket_scan = 4096;

/// Can a value of type `kt` name a property?
pub fn admissible(c: *Checker, kt: TypeId) Error!bool {
    // An unresolved key (`{ [nosuch]: 1 }`) is `error`, which is assignable to
    // everything — tsc reports the TS2304 and stops, with no TS2464 behind it.
    if (kt == types.error_type or kt == types.no_type) return true;
    // tsc tests `TypeFlags.Nullable` SEPARATELY from assignability, which is
    // what keeps a `null` or `undefined` key reported under
    // `strictNullChecks: false`, where it would otherwise be assignable to
    // `string`. `void` and `unknown` fail the assignability test anyway;
    // reading them here too only reaches the same answer sooner.
    if (c.containsNullish(kt)) return false;
    return c.isAssignable(kt, try stringNumberSymbol(c));
}

/// `string | number | symbol` — tsc's `stringNumberSymbolType`. Built on demand
/// rather than cached: the only callers are computed keys, which are rare, and
/// the union constructor interns.
fn stringNumberSymbol(c: *Checker) Error!TypeId {
    return c.makeUnion2(types.string_type, try c.makeUnion2(types.number_type, types.symbol_type));
}

/// Which of the three index-signature key domains a member's computed name
/// falls in, once the name is known to declare no property of its own.
pub const Domain = enum { string, number, symbol };

/// tsc's `getIndexInfosOfIndexSymbol` domain test, verified against tsgo 7.0.2
/// over sixteen key types (see `splitDynamicMembers` for the measurements).
/// It is an if/else CHAIN over the whole key type, not a per-constituent walk:
/// a `string | symbol` key lands in the string domain alone, and a
/// `string | number` one in the string domain alone too.
///
/// Null when the key names a property after all, or names nothing: an
/// inadmissible key (`boolean`, `unknown` — TS2464 already reported) declares
/// neither a member nor a signature.
fn indexDomain(c: *Checker, kt: TypeId) Error!?Domain {
    if (kt == types.no_type or kt == types.error_type) return null;
    if (!try admissible(c, kt)) return null;
    // `any` and `never` are both assignable to `number`, and tsc's chain
    // therefore files them under the NUMBER domain — measured, not assumed:
    // `class C { [k]() {} }` with `k: any` has `keyof C === number`.
    if (try c.isAssignable(kt, types.number_type)) return .number;
    if (try c.isAssignable(kt, types.symbol_type)) return .symbol;
    return .string;
}

/// The index signatures a table's non-late-bindable computed member names
/// contribute between them.
pub const DynamicIndexes = struct {
    /// Value type for the STRING-keyed signature (or, when `sym_only`, the
    /// symbol-keyed one — ztsc keeps both in the same slot, see
    /// `types.obj_flag_symbol_index`). Zero when there is none.
    str: TypeId = 0,
    num: TypeId = 0,
    /// The `str` slot holds a `[k: symbol]` signature.
    sym_only: bool = false,
    /// Every member that claimed the slot carried `readonly` — tsc's
    /// `IndexInfo.isReadonly`, which makes a write TS2542.
    str_readonly: bool = false,
    num_readonly: bool = false,
};

/// Split the members a NON-late-bindable computed name declared out of `props`
/// and return the index signatures they contribute — tsc's
/// `getIndexInfosOfIndexSymbol`.
///
/// A computed name whose key type is not a string literal, a numeric literal
/// or a `unique symbol` (`class K { [plain]() {} }` with `plain: symbol`)
/// declares no property: the binder files every such member under one `__index`
/// symbol, and `resolveDeclaredMembers` turns that symbol into index
/// signatures. ztsc's binder keys them by a `__@k$<ident>` PLACEHOLDER atom
/// instead (see `atoms.placeholderKeyType`), so they arrive here as ordinary
/// props and are removed from `props` in place once classified.
///
/// The shapes below were measured against tsgo 7.0.2 by reading `keyof` and
/// element-access results back out of classes, interfaces and type literals:
///
///   * **domain** — `symbol` → `[x: symbol]`; `string`, `` `data-${string}` ``,
///     `Uppercase<string>`, `"a" | "b"`, `string | number`, `string | symbol`
///     → `[x: string]`; `number`, `1 | 2`, a numeric enum, `any`, `never`
///     → `[x: number]`. `unknown` and `boolean` (TS2464) contribute nothing.
///   * **value type** — each signature's value is the union of the members
///     whose key lands in its domain, PLUS the table's ordinary members that a
///     key of that domain could read. So the string signature takes every
///     string- and numeric-NAMED sibling and every string- and number-keyed
///     computed member; the number signature takes only numeric-named siblings
///     and number-keyed computed members; the symbol signature takes only
///     symbol-named siblings and symbol-keyed computed members. Verified:
///     `class A { plainProp = true; [ks]() {…} [kn]() {…} [ky]() {…} }` reads
///     `a["zz"]` as `boolean | (() => number) | (() => string)`, `a[3]` as
///     `() => string`, and `a[ky]` as `() => bigint`.
///   * an OPTIONAL member contributes `T | undefined`
///     (`declarationEmitComputedNameWithQuestionToken` reads
///     `(() => string) | undefined`).
///   * a table with no computed member in a domain gets no signature there —
///     a symbol key alone leaves `a["zz"]` a TS7053, and a number key alone
///     leaves `b["zz"]` a TS7015.
///
/// **Representation limit.** ztsc stores two index slots and reinterprets the
/// string one as symbol-keyed via `types.obj_flag_symbol_index`, so a table
/// that would need a symbol signature ALONGSIDE a string or number one cannot
/// have all three. The symbol half is dropped there and its members stay
/// placeholder props, exactly as they were before this pass existed — the rare
/// case degrades to the old behavior rather than losing the common one.
///
/// `scope` must reach the key identifiers' bindings.
pub fn splitDynamicMembers(
    c: *Checker,
    props: *std.ArrayList(types.Prop),
    scope: binder.ScopeId,
) Error!DynamicIndexes {
    // Pre-scan: a table with no placeholder member — every table in the DOM
    // lib, and all but a handful in any real program — pays one interned-text
    // prefix test per prop and allocates nothing.
    var any_placeholder = false;
    for (props.items) |p| {
        if (atoms.isComputedPlaceholder(c, p.name)) {
            any_placeholder = true;
            break;
        }
    }
    if (!any_placeholder) return .{};

    // Parallel to `props`: the domain each member was classified into, or null
    // for a member that stays a property. Scratch-allocated on the rare path
    // only (guarded above).
    const doms = try c.scratch().alloc(?Domain, props.items.len);
    defer c.scratch().free(doms);
    var have: [3]bool = .{ false, false, false };
    var ro: [3]bool = .{ true, true, true };
    for (props.items, 0..) |p, i| {
        doms[i] = null;
        const kt = (try atoms.placeholderKeyType(c, p.name, scope)) orelse continue;
        const d = (try indexDomain(c, kt)) orelse continue;
        doms[i] = d;
        have[@intFromEnum(d)] = true;
        if (p.flags & types.prop_flag_readonly == 0) ro[@intFromEnum(d)] = false;
    }
    const has_str = have[@intFromEnum(Domain.string)];
    const has_num = have[@intFromEnum(Domain.number)];
    // See the representation limit above: a symbol signature is only storable
    // when nothing else claims a slot.
    const has_sym = have[@intFromEnum(Domain.symbol)] and !has_str and !has_num;
    if (!has_str and !has_num and !has_sym) return .{};
    if (!has_sym) {
        for (doms) |*d| {
            if (d.* == .symbol) d.* = null;
        }
    }

    var str_vals: std.ArrayList(TypeId) = .empty;
    defer str_vals.deinit(c.scratch());
    var num_vals: std.ArrayList(TypeId) = .empty;
    defer num_vals.deinit(c.scratch());
    var sym_vals: std.ArrayList(TypeId) = .empty;
    defer sym_vals.deinit(c.scratch());
    for (props.items, 0..) |p, i| {
        const vt = if (p.optional()) try c.makeUnion2(p.ty, types.undefined_type) else p.ty;
        if (doms[i]) |d| switch (d) {
            // A number-keyed member is readable through the string signature
            // too — a numeric key IS a string key — so it joins both.
            .number => {
                try num_vals.append(c.scratch(), vt);
                if (has_str) try str_vals.append(c.scratch(), vt);
            },
            .string => try str_vals.append(c.scratch(), vt),
            .symbol => try sym_vals.append(c.scratch(), vt),
        } else {
            // An ordinary sibling, folded into whichever signature a key of
            // its own name domain would reach.
            const text = c.atomText(p.name);
            if (std.mem.startsWith(u8, text, "__@")) {
                if (has_sym) try sym_vals.append(c.scratch(), vt);
            } else {
                if (has_str) try str_vals.append(c.scratch(), vt);
                if (has_num and literals.isNumericName(text)) try num_vals.append(c.scratch(), vt);
            }
        }
    }

    var out: DynamicIndexes = .{};
    if (has_str) {
        out.str = try c.ts.makeUnion(c.scratch(), str_vals.items);
        out.str_readonly = ro[@intFromEnum(Domain.string)];
    } else if (has_sym) {
        out.str = try c.ts.makeUnion(c.scratch(), sym_vals.items);
        out.str_readonly = ro[@intFromEnum(Domain.symbol)];
        out.sym_only = true;
    }
    if (has_num) {
        out.num = try c.ts.makeUnion(c.scratch(), num_vals.items);
        out.num_readonly = ro[@intFromEnum(Domain.number)];
    }

    // Drop the classified members: they name no property (tsc keys them under
    // `__index`, which is not in the member table at all).
    var w: usize = 0;
    for (props.items, 0..) |p, i| {
        if (doms[i] != null) continue;
        props.items[w] = p;
        w += 1;
    }
    props.shrinkRetainingCapacity(w);
    return out;
}
