//! Control-flow narrowing and definite assignment.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const FlowId = binder.FlowId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const CallShape = @import("calls.zig").CallShape;
const countArgs = @import("calls.zig").countArgs;
const atom = Checker.atom;
const findBindingType = @import("signatures.zig").findBindingType;
const init = Checker.init;
const isInstantiableKind = @import("expr.zig").isInstantiableKind;
const lazy_base_depth = @import("instantiate.zig").lazy_base_depth;
const propOfType = @import("props.zig").propOfType;
const reduceSubtypes = @import("typenode.zig").reduceSubtypes;
const refExpansionActive = @import("instantiate.zig").refExpansionActive;
const typeOfSymbol = @import("signatures.zig").typeOfSymbol;

// =====================================================================
// control-flow narrowing
// =====================================================================
//
// This file owns the DECISIONS: which condition narrows which reference, the
// flow-graph walk and its caches, guards, `switch` narrowing, and definite
// assignment. The three pieces that are not decisions live beside it and are
// re-exported here, so `checker.zig`'s alias block — and therefore every
// `c.foo(...)` method spelling — keeps resolving through `flow.zig`:
//
//   * `refkey.zig`       — what a tracked reference IS (the packed `RefKey`).
//   * `narrow.zig`       — the type-lattice filters a decision then applies.
//   * `reassign_scan.zig` — the lazy per-file assignment pre-scan.

const refkey = @import("refkey.zig");
pub const max_ref_depth = refkey.max_ref_depth;
pub const max_deep_ref_depth = refkey.max_deep_ref_depth;
pub const PathElem = refkey.PathElem;
pub const RefKey = refkey.RefKey;
pub const DeepPath = refkey.DeepPath;
pub const FlowQ = refkey.FlowQ;
pub const RefQ = refkey.RefQ;
pub const SymLoop = refkey.SymLoop;
pub const LoopFrame = refkey.LoopFrame;
pub const this_flow_root = refkey.this_flow_root;
pub const pattern_root_base = refkey.pattern_root_base;
pub const isPseudoRoot = refkey.isPseudoRoot;
pub const makeRefKey = refkey.makeRefKey;
pub const refPath = refkey.refPath;
const refKeyIndex = refkey.refKeyIndex;
pub const constIndexOf = refkey.constIndexOf;
pub const stableIndexSymbol = refkey.stableIndexSymbol;
pub const buildRefKey = refkey.buildRefKey;
pub const referenceCandidate = refkey.referenceCandidate;
const refMatches = refkey.refMatches;
const pathElemOfAccess = refkey.pathElemOfAccess;
pub const refMatchesPath = refkey.refMatchesPath;
const refPrefixWritten = refkey.refPrefixWritten;
pub const isNarrowable = refkey.isNarrowable;

const narrow = @import("narrow.zig");
const narrowByLiteralEquality = narrow.narrowByLiteralEquality;
pub const narrowToValue = narrow.narrowToValue;
pub const unionHasKind = narrow.unionHasKind;
pub const narrowExcludeValue = narrow.narrowExcludeValue;
pub const narrowByTypeof = narrow.narrowByTypeof;
pub const narrowByTypeofResolved = narrow.narrowByTypeofResolved;
pub const typeofMatchesFn = narrow.typeofMatchesFn;
pub const enumTypeofDomain = narrow.enumTypeofDomain;
pub const hasCallableShape = narrow.hasCallableShape;
pub const typeofMatches = narrow.typeofMatches;
const narrowByDiscriminant = narrow.narrowByDiscriminant;
const narrowByPropTruthiness = narrow.narrowByPropTruthiness;
pub const isDiscriminantProp = narrow.isDiscriminantProp;
pub const propDeclaredForIn = narrow.propDeclaredForIn;
const narrowByInProp = narrow.narrowByInProp;
pub const instanceTypeOfConstructor = narrow.instanceTypeOfConstructor;
pub const instanceofInstanceType = narrow.instanceofInstanceType;
pub const isNullishKind = narrow.isNullishKind;
pub const admitsNullish = narrow.admitsNullish;
const narrowByInstance = narrow.narrowByInstance;
const narrowByConstructorProp = narrow.narrowByConstructorProp;
/// Not re-exported: `switchDefaultCovered` is the only reader outside
/// `narrow.zig`, and it reaches it directly rather than as a `Checker` method.
const unionFacet = narrow.unionFacet;

const reassign_scan = @import("reassign_scan.zig");
pub const ensureReassignScan = reassign_scan.ensureReassignScan;
pub const recordReassign = reassign_scan.recordReassign;
pub const markReassignTarget = reassign_scan.markReassignTarget;
pub const no_past_assignment = reassign_scan.no_past_assignment;
pub const markMemberWriteRoot = reassign_scan.markMemberWriteRoot;
pub const recordMemberWrite = reassign_scan.recordMemberWrite;

/// Is `sym` a binding-pattern pseudo-root (`pattern_root_base`), as opposed to
/// a real symbol or the `this` sentinel? Only the flow walk mints and consumes
/// these, so unlike `isPseudoRoot` it has no reader outside this file.
inline fn isPatternRoot(sym: SymbolId) bool {
    return sym >= pattern_root_base and sym != this_flow_root;
}

/// Intern `decl` (a parameter or declarator whose name is an object binding
/// pattern) as a pseudo-reference root. Null when the sentinel range is
/// exhausted or would collide with the fresh-type-param space — the reference
/// is then simply not tracked (sound under-narrowing).
fn patternRoot(c: *Checker, decl: Node) Error!?SymbolId {
    if (c.fresh_tp_base != 0 and c.fresh_tp_base >= pattern_root_base) return null;
    const gop = try c.pattern_root_ids.getOrPut(c.cm(), c.nodeKey(decl));
    if (!gop.found_existing) {
        if (c.pattern_root_decls.items.len >= this_flow_root - pattern_root_base) {
            _ = c.pattern_root_ids.remove(c.nodeKey(decl));
            return null;
        }
        try c.pattern_root_decls.append(c.cm(), c.nodeKey(decl));
        gop.value_ptr.* = @intCast(c.pattern_root_decls.items.len - 1);
    }
    return pattern_root_base + gop.value_ptr.*;
}

/// The `(file, node)` declaration a pattern pseudo-root stands for.
fn patternRootDecl(c: *const Checker, sym: SymbolId) u64 {
    return c.pattern_root_decls.items[sym - pattern_root_base];
}

pub fn flowTypeOfReference(c: *Checker, node: Node, sym: SymbolId, declared: TypeId) Error!TypeId {
    return c.flowTypeOfKey(node, .{ .sym = sym }, declared);
}

/// The object binding pattern a declaration binds through, or null.
fn objectPatternOf(c: *Checker, decl: Node) ?Node {
    const pat: Node = switch (c.nodeTag(decl)) {
        .param, .param_full, .declarator, .declarator_init, .declarator_full => c.tree.nodeData(decl).lhs,
        else => return null,
    };
    if (pat == null_node or c.nodeTag(pat) != .object_pattern) return null;
    return pat;
}

/// The type of a destructuring declaration's whole value — tsc's
/// `getTypeForBindingElementParent`.
///
/// An annotation answers directly. A `const` declarator without one is typed
/// by its INITIALIZER, exactly as `declaratorType` types it — `const
/// {assets, canceled} = await picker()` is the common spelling of a
/// destructured discriminated union, and refusing it left every such
/// `if (canceled) return` un-narrowed. The initializer is re-typed through
/// `checkExprCached` (in practice a cache hit: the caller already asked for
/// the binding's declared type, which walks the same expression) under the
/// same `defer_bodies` guard `declaratorType` uses, so a demand arriving
/// here first cannot walk a function body that the declarator path would
/// have deferred — the order-dependence that guard exists to prevent.
///
/// An unannotated PARAMETER is still left out: its type is contextual, so it
/// is not a function of the declaration at all. Sound under-narrowing.
fn patternParentType(c: *Checker, decl: Node, is_const: bool) Error!TypeId {
    const d = c.tree.nodeData(decl);
    var init_node: Node = null_node;
    const ann: Node = switch (c.nodeTag(decl)) {
        // `.param` carries its (optional) annotation directly in `rhs`;
        // `.param_full` moves it into the side table with flags/initializer.
        .param => d.rhs,
        .param_full => c.tree.extraData(ast.ParamFull, d.rhs).type_ann,
        .declarator_init => blk: {
            init_node = d.rhs;
            break :blk null_node;
        },
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            init_node = e.init;
            break :blk e.type_ann;
        },
        else => null_node,
    };
    if (ann != null_node) return c.typeFromTypeNode(ann);
    if (init_node == null_node or !is_const) return types.no_type;
    c.defer_bodies += 1;
    defer c.defer_bodies -= 1;
    const init_t = try c.checkExprCached(init_node, types.no_type);
    return c.widenInitializer(init_t, is_const);
}

/// `patternParentType` resolved to a UNION, or `no_type` when the declaration
/// destructures anything else. Every identifier bound by the pattern asks the
/// same question of the same declaration, and for an unannotated `const` the
/// answer costs an initializer walk — so it is memoized per declaration. The
/// memo is a pure function of the declaration (the same reason the value is
/// safe to share across the file), so no `--checkers=N` partition can see a
/// different answer than another.
fn patternParentUnion(c: *Checker, decl: Node, is_const: bool, key: u64) Error!TypeId {
    if (c.pattern_parent_types.get(key)) |t| return t;
    const whole = try patternParentType(c, decl, is_const);
    var parent: TypeId = types.no_type;
    if (whole != types.no_type) {
        const r = try patternParentConstraint(c, try c.resolveStructural(whole));
        if (c.ts.kind(r) == .union_type) parent = r;
    }
    try c.pattern_parent_types.put(c.cm(), key, parent);
    return parent;
}

/// tsc's `mapType(parentType, getBaseConstraintOrType)`: the destructured
/// parent seen through type-parameter constraints, so
///
///     function f<T extends { kind: 'A', payload: number }
///                         | { kind: 'B', payload: string }>({ kind, payload }: T)
///
/// destructures the CONSTRAINT's union and a guard on `kind` still narrows
/// `payload`. Without it the parent type is the bare `T`, "not a union", and
/// the whole sibling-narrowing rule declined (`dependentDestructuredVariables`
/// f13/f14).
///
/// Only an INSTANTIABLE constituent is replaced — tsc's
/// `getBaseConstraintOfType` answers `undefined` for a plain object type, and
/// ztsc's `baseConstraintOf` would otherwise substitute the type parameters
/// nested INSIDE one (`A<T> | B<T>` becoming `A<con> | B<con>`), which is a
/// different type than the destructuring is written against.
fn patternParentConstraint(c: *Checker, r: TypeId) Error!TypeId {
    if (c.ts.kind(r) != .union_type) return constraintOrSelf(c, r);
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    var changed = false;
    for (try c.memberList(r)) |m| {
        const cm = try constraintOrSelf(c, m);
        if (cm != m) changed = true;
        try parts.append(c.scratch(), cm);
    }
    if (!changed) return r;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

fn constraintOrSelf(c: *Checker, t: TypeId) Error!TypeId {
    if (!isInstantiableKind(c.ts.kind(t))) return t;
    const con = try c.baseConstraintOf(t);
    return try c.resolveStructural(con);
}

/// The direct `binding_property` of `pat` that binds `name`, if it is one
/// tsc would let participate: no default (`{ a = 1 }` has an initializer),
/// no rest element, and a plain identifier target (a nested pattern's own
/// bindings are reached through their own declaration).
fn bindingPropertyFor(c: *Checker, pat: Node, name: Atom) Error!?Node {
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node or c.nodeTag(el) != .binding_property) continue;
        const ed = c.tree.nodeData(el);
        if (ed.rhs != 0) continue; // has a default
        if (ed.lhs == 0) {
            if ((try c.memberAtom(c.tree.nodeMainToken(el))) == name) return el;
        } else if (c.nodeTag(ed.lhs) == .identifier) {
            if ((try c.atomOfToken(c.tree.nodeMainToken(ed.lhs))) == name) return el;
        }
    }
    return null;
}

/// tsc's `getNarrowedTypeOfSymbol`, binding-element arm.
///
/// `function f({ kind, data }: { kind: 'a', data: A } | { kind: 'b', data: B })`
/// destructures a discriminated union, and TS 4.6 lets a guard on one binding
/// narrow the others: `switch (kind) { case 'a': data /* A */ }`. Nothing in
/// the flow graph connects the two — they are separate symbols — so the union
/// itself is narrowed as a pseudo-reference rooted at the declaration
/// (`pattern_root_base`), with `discriminantOfRef` teaching the narrowers that
/// a bare identifier bound by that pattern reads the corresponding property;
/// the requested binding is then re-projected out of the narrowed parent by
/// the same `findBindingType` that produced its declared type.
///
/// Null when the shape does not qualify or the walk found nothing to narrow,
/// leaving the caller's declared type untouched.
pub fn narrowedPatternBinding(c: *Checker, node: Node, sym: SymbolId) Error!?TypeId {
    if (isPseudoRoot(sym) or c.isFreshTp(sym) or sym == binder.no_symbol) return null;
    const f = c.symFlags(sym);
    // tsc: a `const`-like binding only — a parameter with no assignment to it,
    // or a `const` declarator.
    if (!(f.param or f.const_decl)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return null;
    const decl = decls[0];
    const pat = objectPatternOf(c, decl) orelse return null;
    // tsc requires at least two elements: with one there is no sibling
    // discriminant to narrow by.
    if (c.tree.nodeRange(pat).len < 2) return null;
    const name = c.symNameAtom(sym);
    if ((try bindingPropertyFor(c, pat, name)) == null) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;

    // tsc's `InCheckIdentifier` node flag, set *around* the parent-type
    // computation as well as the flow walk (an unannotated declarator's
    // parent type re-enters the checker through its initializer).
    const busy_key = c.nodeKey(decl);
    if (c.pattern_narrow_busy.contains(busy_key)) return null;
    try c.pattern_narrow_busy.put(c.cm(), busy_key, {});
    defer _ = c.pattern_narrow_busy.remove(busy_key);

    const parent = try patternParentUnion(c, decl, f.const_decl, busy_key);
    if (parent == types.no_type) return null;

    const root = (try patternRoot(c, decl)) orelse return null;
    const narrowed = try c.flowTypeOfKey(node, .{ .sym = root }, parent);
    if (narrowed == parent) return null;
    if (c.ts.kind(narrowed) == .never) return types.never_type;
    const bound = (try c.findBindingType(pat, name, narrowed, null)) orelse return null;
    if (bound == types.no_type) return null;
    return bound;
}

/// Is `node` a bare identifier bound by the object pattern behind the
/// pseudo-root `key`, and if so which property does it read? (tsc's
/// `getCandidateDiscriminantPropertyAccess`, binding-pattern arm.)
fn patternDiscriminantAtom(c: *Checker, node: Node, key: RefKey) Error!?Atom {
    if (key.len != 0) return null;
    if (c.nodeTag(node) != .identifier) return null;
    const dk = patternRootDecl(c, key.sym);
    if (dk >> 32 != c.cur_file) return null;
    const decl: Node = @truncate(dk);
    const pat = objectPatternOf(c, decl) orelse return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    // The identifier must resolve to a binding of THIS pattern, and must not
    // be reassigned (tsc's `isParameterOrMutableLocalVariable && !isSymbolAssigned`).
    if (isPseudoRoot(sym) or c.isFreshTp(sym)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1 or decls[0] != decl) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;
    const el = (try bindingPropertyFor(c, pat, a)) orelse return null;
    // `binding_property`'s main token is the PROPERTY name in both the
    // shorthand (`{ kind }`) and the renamed (`{ kind: k }`) form.
    return try c.memberAtom(c.tree.nodeMainToken(el));
}

/// tsc's `isPastLastAssignment` (TS 5.4). `sym` is known to be assigned
/// somewhere in this file; the narrowing at a closure's definition point
/// survives the crossing only when the reference starts strictly after the
/// last such assignment's extended position (`recordLastAssign`).
///
/// tsc's eligibility test is `isParameterOrMutableLocalVariable`, which admits
/// parameters, `catch` variables and non-exported non-global `let`s — and
/// **not `var`**, whose declaration is hoisted out of the block it is written
/// in. A `var` that is assigned anywhere therefore stays at its declared type
/// across a closure, exactly as before this rule existed.
fn pastLastAssignment(c: *Checker, sym: SymbolId, sf: binder.SymbolFlags) bool {
    if (!(sf.let_decl or sf.param or sf.catch_param)) return false;
    const at = c.last_assign_pos.get(sym) orelse return false;
    if (at == no_past_assignment) return false;
    if (c.flow_ref_node == null_node) return false;
    return at < c.nodeSpanStart(c.flow_ref_node);
}

pub fn flowTypeOfKey(c: *Checker, node: Node, key: RefKey, declared: TypeId) Error!TypeId {
    var t = declared;
    if (c.isNarrowable(declared)) {
        if (c.bind.flowAt(node)) |flow| {
            c.stats.flow_queries += 1;
            // The reference the closure-crossing arm places against
            // `last_assign_pos`. Saved and restored because narrowing a
            // condition re-checks expressions, which can start a nested flow
            // query for a different reference.
            const saved_ref = c.flow_ref_node;
            defer c.flow_ref_node = saved_ref;
            c.flow_ref_node = node;
            t = try flowType(c, flow, key, declared, 0);
            // The tail of tsc's `getFlowTypeOfReference`. tsc has *two*
            // `never`s: the ordinary one a guard narrows a reference down to,
            // and `unreachableNeverType`, which is what the walk answers when
            // it bottoms out in code no control path reaches. Only the first
            // is a type anyone may observe — for the second the DECLARED type
            // is handed back, which is why `function f(x: string) { return 1;
            //   x.length; }` is silent while an exhausted union's dead branch
            // reports TS2339. ztsc computes both with the one `never_type`,
            // so the distinction is drawn here, by asking the graph whether
            // the reference's own flow node is reachable at all.
            if (c.ts.kind(t) == .never and !try flowReachable(c, flow)) t = declared;
        }
    }
    return applyChainGuards(c, key, t);
}

/// tsc's `isReachableFlowNode`. Only asked on a `never` answer (a fraction of
/// a percent of queries), so the memo is there to bound a pathological graph
/// rather than to carry a hot path.
fn flowReachable(c: *Checker, flow: FlowId) Error!bool {
    if (flow == binder.no_flow) return true;
    if (flow == binder.unreachable_flow) return false;
    const cache_key = c.cur_flow_base + flow;
    // 0 = in flight. A cycle can only close through a loop label, whose
    // *entry* edge is the one edge walked, so this is defensive only;
    // answering "reachable" keeps it on the non-suppressing side.
    if (c.flow_reach.get(cache_key)) |v| return v != 1;
    try c.flow_reach.put(c.cm(), cache_key, 0);
    const r = try flowReachableInner(c, flow);
    try c.flow_reach.put(c.cm(), cache_key, if (r) 2 else 1);
    return r;
}

fn flowReachableInner(c: *Checker, flow: FlowId) Error!bool {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none, .start => return true,
        .unreachable_ => return false,
        .branch_label => {
            for (b.flowAntecedents(flow)) |a| {
                if (try flowReachable(c, a)) return true;
            }
            return false;
        },
        // Only the entry edge: a loop's back edges are reachable exactly
        // when the head is, so following them would answer with itself.
        .loop_label => {
            const antes = b.flowAntecedents(flow);
            if (antes.len == 0) return false;
            return flowReachable(c, antes[0]);
        },
        // tsc's Call arm: a call statement whose signature returns `never`
        // (`invariant(false)`, `fail(msg): never`) ends the flow — the
        // statements after it are dead, and a reference read there is back
        // at its declared type.
        .call_stmt => {
            if (try callStmtReturnsNever(c, flow)) return false;
            return flowReachable(c, b.flow_a[flow]);
        },
        // A `switch_no_match` edge is deliberately NOT tested for
        // exhaustiveness here: the fall-out of an exhaustive `switch` is
        // where tsc reports `never` on the discriminant, so it must stay
        // "reachable" and let the narrowed `never` through.
        else => return flowReachable(c, b.flow_a[flow]),
    }
}

/// Does the call statement behind `flow` return `never`? Resolved from the
/// callee's DECLARED (or already-memoized) type only — `never` is not a
/// return type inference produces for a declaration, and re-checking a
/// callee from inside a flow query is the re-entrancy `guardCallOf`'s header
/// note documents.
fn callStmtReturnsNever(c: *Checker, flow: FlowId) Error!bool {
    return callReturnsNever(c, c.bind.flowNode(flow));
}

/// The same question asked of a call NODE, so consumers with no flow node to
/// hand can ask it too (`stmtTerminal`'s endpoint analysis).
///
/// Resolving the callee needs the scope it was WRITTEN in, and neither caller
/// has it: a flow walk runs at the querying reference's scope, and
/// `stmtTerminal` recurses into nested blocks from the body's. The binder
/// attaches a flow entry to every identifier and member read
/// (`bindIdentifierRef` / `bindExpr`), and `flowScope` on that entry is
/// exactly the scope wanted — reading it here is what keeps a callee declared
/// in an inner block (`const render = () => …; … render();`) from resolving
/// against the function scope, where the name does not exist and
/// `checkExprCached` would report a phantom TS2304.
pub fn callReturnsNever(c: *Checker, call: Node) Error!bool {
    if (call == null_node) return false;
    const shape = c.callShape(call);
    const callee = shape.callee;
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (c.bind.flowAt(callee)) |f| c.cur_scope = c.bind.flowScope(f);
    const callee_t = switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.nodeType(callee) orelse
            try declaredPathType(c, callee),
        .identifier => if (calleeNeedsExplicitDecl(c, callee))
            c.nodeType(callee) orelse try declaredPathType(c, callee)
        else
            try c.checkExprCached(callee, types.no_type),
        else => return false,
    };
    if (callee_t == types.no_type) return false;
    // The RESOLVED signature, not the last declared one: an overload set is
    // read by tsc through `getEffectsSignature`, and an assertion set whose
    // *other* overload returns `never` (`declare function invariant(v: any,
    // m: string): asserts v; declare function invariant(v: false, m: string):
    // never;`) otherwise reads as "this call ends the flow" for every call —
    // killing the narrowing the very same statement just made.
    const sig = (try effectsSignature(c, call, shape, callee_t)) orelse return false;
    return c.ts.kind(c.ts.fnReturn(sig)) == .never;
}

/// The binder binds optional chains linearly (see its header note), so the
/// non-nullish branch a `?.` opens is not a flow node. tsc's binder splits
/// it — `a?.b?.[i]` binds as `a && a.b && a.b[i]`, with the index
/// expression bound under the accumulated true-branch — which is what makes
/// `updates?.points?.[updates?.points?.length - 1]` legal: inside the
/// brackets, `updates` and `updates.points` are already known non-nullish,
/// so the inner chain does not re-add the short-circuit `undefined`.
///
/// `pushChainGuards` reconstructs exactly that condition set for the one
/// place it is observable in an expression checker — a subexpression the
/// chain evaluates only on the non-nullish branch — by walking the access
/// spine and recording the *object* of every `?.` link, which is precisely
/// the expression that link asserts. Only those objects are recorded, never
/// the whole spine: in `a?.b[i]` the sole assertion is on `a`, and treating
/// `a.b` as guarded too would swallow the TS18048 that a nullish `a.b`
/// owes the reads inside `i`.
pub fn pushChainGuards(c: *Checker, node: Node) Error!void {
    var n = node;
    while (true) {
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        const d = c.tree.nodeData(n);
        switch (c.nodeTag(n)) {
            .optional_member_expr, .optional_index_expr, .optional_call => {
                if (try c.buildRefKey(d.lhs)) |k| try c.chain_guards.append(c.cm(), k);
            },
            .member_expr, .index_expr, .call_expr, .call_expr_targs => {},
            else => return,
        }
        n = d.lhs;
    }
}

/// Non-nullish for a reference an enclosing chain has already guarded.
/// Applied *after* flow narrowing (and after the untracked-reference early
/// outs) so it composes with whatever the flow graph knows.
fn applyChainGuards(c: *Checker, key: RefKey, t: TypeId) Error!TypeId {
    if (c.chain_guards.items.len == 0) return t;
    for (c.chain_guards.items) |k| {
        if (std.meta.eql(k, key)) return c.nonNullableChain(t);
    }
    return t;
}

/// Is this query already on the walk stack (still being computed)? Only
/// asked on a `flow_same` hit under a back-edge walk, which is why a linear
/// scan of a push/pop stack is the right shape: a second hash map on the
/// `flowType` hot path measured +330 ms of check time on the dogfood app,
/// three times the whole flow phase.
fn flowInFlight(c: *const Checker, q: FlowQ) bool {
    var i: usize = c.flow_stack.items.len;
    while (i > 0) : (i -= 1) {
        if (c.flow_stack.items[i - 1] == q) return true;
    }
    return false;
}

fn flowType(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
    if (flow == binder.no_flow) return declared;
    if (flow == binder.unreachable_flow) return types.never_type;
    if (depth > 4000) return declared; // pathological chains: stay sound
    const q: FlowQ = (@as(u64, c.cur_flow_base + flow) << 32) | try refKeyIndex(c, key, declared);
    // tsc's `getTypeAtFlowLoopLabel` in-process check. Re-entering a loop
    // label that is still computing (the walk came back round the loop, or
    // an assignment's right-hand side reads the very reference the label is
    // resolving) answers with the union of the antecedent types gathered so
    // far — tsc's *incomplete* FlowType — not with the declared type. That
    // partial value is what makes the fixpoint converge for a self-reading
    // loop assignment (`x = x.replace(…)` under an `x !== undefined`
    // guard): the read sees the narrowed entry type instead of re-widening.
    if (c.flow_loop_stack.items.len != 0 and c.bind.flow_tags[flow] == .loop_label) {
        var i: usize = c.flow_loop_stack.items.len;
        while (i > 0) : (i -= 1) {
            const fr = &c.flow_loop_stack.items[i - 1];
            if (fr.q != q or fr.parts.items.len == 0) continue;
            return narrow.recombineUnknown(c, try c.ts.makeUnion(c.scratch(), fr.parts.items));
        }
    }
    // `flow_same` covers both states that answer `declared`: a query still
    // in progress (the walk stack below) and a finished one that narrowed
    // nothing. `flow_narrow` holds the rest, and the two are disjoint.
    if (c.flow_same.contains(q)) {
        // Under a back-edge walk the two states are *not* interchangeable.
        // Every node between the re-entering reference and its loop label
        // is in flight (a `for..of`/`for..in` binding is itself an
        // assignment node, so there is always at least one), and answering
        // `declared` there swallows the partial the label is publishing —
        // the very widening this mechanism removes. Re-walk instead,
        // bounded, and memoize in `flow_tmp`. Everywhere else the old,
        // cheap answer stands: outside a back-edge walk there is no partial
        // for an in-flight node to swallow.
        if (c.flow_back_edge != 0 and c.flow_busy_depth < 4 and flowInFlight(c, q)) {
            if (c.flow_tmp.get(q)) |t| return t;
            c.flow_busy_depth += 1;
            defer c.flow_busy_depth -= 1;
            const r = try flowTypeInner(c, flow, key, declared, depth);
            try c.flow_tmp.put(c.cm(), q, r);
            return r;
        }
        return declared;
    }
    if (c.flow_narrow.get(q)) |t| return t;
    // Everything computed while a loop label's BACK edges are walked is
    // computed against the partial fixpoint that label publishes, so it is
    // only valid inside that walk: it goes to `flow_tmp` (dropped when the
    // outermost label finishes) and never to the persistent cache, which
    // therefore only ever holds answers taken against *finished* labels.
    //
    // Marking that positionally rather than tainting the values is what
    // makes it affordable: the label's own result is decided *outside* its
    // back-edge walk, so it is always cached. Propagating an incompleteness
    // bit up the walk instead — tsc's literal `isIncomplete` — keeps whole
    // nests of labels out of the cache, and each uncached label re-walks
    // back edges that re-check expressions that start fresh walks over the
    // same uncached labels: measured at three orders of magnitude.
    if (c.flow_back_edge != 0) {
        if (c.flow_tmp.get(q)) |t| return t;
    }
    // Mark in progress. If the result turns out to be `declared` this
    // entry *is* the final answer, so the common case never writes twice.
    try c.flow_same.put(c.cm(), q, {});
    try c.flow_stack.append(c.cm(), q);
    const result = try flowTypeInner(c, flow, key, declared, depth);
    _ = c.flow_stack.pop();
    if (c.flow_back_edge != 0) {
        _ = c.flow_same.remove(q);
        try c.flow_tmp.put(c.cm(), q, result);
        return result;
    }
    // `no_type` is not storable as a result (it was the old in-progress
    // sentinel and still reads back as "declared"); leaving such a result
    // in `flow_same` reproduces the previous behaviour exactly.
    if (result != declared and result != types.no_type) {
        _ = c.flow_same.remove(q);
        try c.flow_narrow.put(c.cm(), q, result);
    }
    return result;
}

fn flowTypeInner(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none => return declared,
        .start => {
            // tsc's `initialType`, taken at the top of the flow graph (see
            // `RefKey.opt_init`): the constructor has not run yet, so the
            // property still reads `undefined`. This is the ONLY place
            // `undefined` enters a `strictPropertyInitialization` walk — a
            // definite write answers the declared type, and narrowing can
            // only ever remove constituents — which is what makes "the answer
            // still admits `undefined`" mean "some path left it unwritten".
            if (key.opt_init) {
                return c.ts.makeUnion(c.scratch(), &.{ declared, types.undefined_type });
            }
            // A function/arrow body's start records its definition-point
            // flow as the antecedent. For a constant bare-identifier
            // reference captured by this closure, continue analysis in the
            // enclosing function so its narrowing is preserved (tsc narrows
            // `const`/effectively-const references across closures, but not
            // property paths, `this`, or reassignable variables). Namespace
            // and file starts have `no_flow` here and stop at `declared`.
            const ante = b.flow_a[flow];
            if (ante == binder.no_flow) return declared;
            // A closure whose textual definition point is unreachable (e.g. a
            // hoisted `function` declared after a `return`) can still be
            // invoked — its body runs in a fresh reachable context. Crossing
            // into the unreachable definition-point flow would yield `never`
            // for a captured reference, which then makes a property *write*
            // target (`ref.current = x`) spuriously collapse to `never` (a
            // read to `never` is silently accepted, so only writes surface it).
            // Use the declared type instead: there is no valid narrowing at an
            // unreachable definition point.
            if (ante == binder.unreachable_flow) return declared;
            // Property paths and `this` never continue into an enclosing
            // function's flow — tsc's Start arm excludes exactly
            // PropertyAccess, ElementAccess and `this`.
            if (key.len != 0 or key.sym == this_flow_root) return declared;
            // A BINDING-PATTERN pseudo-reference is none of those, and tsc
            // asks for it with no `flowContainer` at all, so it crosses every
            // closure boundary unconditionally. It may: the pattern only ever
            // stands for a `const` declarator or a never-assigned parameter
            // (`narrowedPatternBinding`'s own gate), so the narrowing a guard
            // gave it cannot be undone by an assignment somewhere else.
            // Without this the sibling narrowing evaporated the moment it was
            // read inside a callback — `lists.map((l, i) => i === lists.length
            // - 1 …)` after `isPending`/`isError` were ruled out.
            if (isPatternRoot(key.sym)) return flowType(c, ante, key, declared, depth + 1);
            // Only a reference *captured* by this closure may continue into
            // the definition-point flow. A reference to something the
            // closure declares itself (its parameters, its own locals) is
            // not captured — tsc's `checkIdentifier` only walks out to an
            // enclosing container when the declaration container differs
            // from the reference's. Crossing anyway put the closure's own
            // symbol into the enclosing function's flow, where
            // `assignNarrows` matches a declarator by NAME
            // (`patternBindsSym`): a same-named outer `const d: string`
            // then narrowed an `unknown`-typed parameter `d` to `string`.
            // (Only visible for a declared type `assignmentRefines` accepts,
            // which is why `unknown` parameters were the reported shape.)
            if (c.symFile(key.sym) == c.cur_file) {
                const own = c.containerOf(c.bind.symbol_scopes[c.localOf(key.sym)]);
                if (c.bind.scope_owners[own] == b.flowNode(flow)) return declared;
            }
            const sf = c.symFlags(key.sym);
            if (!sf.const_decl) {
                // Effectively-const let/var/param: tsc narrows a captured
                // reference across a closure like a `const` when the variable
                // is a mutable *local* that is never reassigned (matching
                // tsc's `isParameterOrMutableLocalVariable` + the
                // function-expression/arrow container walk in
                // `checkIdentifier`). Excluded, so the declared type stands:
                //   • non let/var/param/catch symbols,
                //   • exported variables, and a top-level variable of a
                //     SCRIPT — tsc's `isMutableLocalVariableDeclaration`
                //     admits a `let` that is neither exported nor global, and
                //     a script's top level IS the global scope, where any file
                //     may reassign the binding. A MODULE's top-level `let` is
                //     a module-local and does qualify (a top-level `const`
                //     qualifies either way, via the const path above),
                //   • the crossed closure being a *function declaration*
                //     (only function-expression/arrow/method containers extend
                //     the flow — a hoisted `function` captures at its
                //     definition point, before any guard),
                //   • an assignment the reference is not textually past
                //     (tsc's `isPastLastAssignment`, below).
                if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return declared;
                if (sf.exported) return declared;
                if (c.symFile(key.sym) != c.cur_file) return declared;
                const decl_scope = c.bind.symbol_scopes[c.localOf(key.sym)];
                switch (c.bind.scope_kinds[c.containerOf(decl_scope)]) {
                    .function => {},
                    // A module's top level. `var` is left out here even though
                    // the function case still admits it: tsc admits neither,
                    // and the function case is a pre-existing looseness this
                    // does not propagate.
                    .file => if (!c.bind.is_module or
                        !(sf.let_decl or sf.param or sf.catch_param)) return declared,
                    else => return declared,
                }
                switch (c.nodeTag(b.flowNode(flow))) {
                    .arrow_fn, .function_expr, .object_method, .class_method => {},
                    else => return declared, // function declaration etc.
                }
                try c.ensureReassignScan();
                if (c.reassigned_syms.contains(key.sym) and
                    !pastLastAssignment(c, key.sym, sf)) return declared;
            }
            const outer = try flowType(c, ante, key, declared, depth + 1);
            // tsc's two `never`s, at the closure boundary (see
            // `flowTypeOfKey`'s tail for the other place the distinction is
            // drawn). A definition point standing in code no path reaches
            // answers `unreachableNeverType`, and every reader of that is
            // handed the DECLARED type — the closure's own body is reachable
            // whatever surrounds its definition, since it may be invoked from
            // anywhere. `invariant(res?.data, "…")` in outline's stores is the
            // shape: `res` is `any`, so the call resolves to
            // `@types/invariant`'s FIRST overload — `(testValue: false, …):
            // never`, which `any` satisfies — the statement ends the flow, and
            // the `runInAction(() => … res.data …)` callback right after it
            // read every capture as `never` (36 fresh TS2339s).
            if (c.ts.kind(outer) == .never and !try flowReachable(c, ante)) return declared;
            return outer;
        },
        .unreachable_ => return types.never_type,
        .assign => {
            const target = b.flowNode(flow);
            const ante = b.flow_a[flow];
            // Re-evaluating the initializer/rhs resolves names in the scope
            // where the assignment lives, not the reference's query scope.
            // The `for..in` test below is a name resolution too (it matches
            // the loop's right-hand side against the queried reference), so
            // it shares the scope — but only the TEST does: walking the
            // antecedent has to happen back in the query's own scope, exactly
            // as the fall-through below does.
            var strip_nullish = false;
            {
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                c.cur_scope = b.flowScope(flow);
                if (try assignNarrows(c, target, key, declared)) |narrowed| {
                    return narrowed;
                }
                strip_nullish = try forInSubjectMatches(c, flow, target, key);
            }
            const before = try flowType(c, ante, key, declared, depth + 1);
            // The tail of tsc's `getTypeAtFlowAssignment`: the assignment that
            // binds a `for..in` KEY strips nullish from the object being
            // enumerated, for the whole body. `for (const k in
            // maybeUndefined)` is legal JS — enumerating `undefined` yields no
            // keys — so tsc reports nothing on the header
            // (`checkForInStatement` runs `getNonNullableTypeIfNeeded` over
            // the right-hand side) and nothing inside the body either, because
            // a body only runs when there was an object to enumerate.
            // outline's `for (const key in extra) { … extra[key] … }` over an
            // optional parameter was 3 × TS2407 plus 3 × TS18048.
            if (strip_nullish and isNullishUnion(c, before)) return try c.nonNullable(before);
            return before;
        },
        .cond_true, .cond_false => {
            const cond = b.flowNode(flow);
            const ante = b.flow_a[flow];
            // tsc's `createFlowCondition`: the edge that contradicts a literal
            // `true`/`false` KEYWORD does not exist. That is what makes
            // `while (true) { this.x = v; break; }` a definite assignment —
            // the loop's fall-out edge is unreachable, so the only way past
            // the loop is the `break`, after the write. (`while (1)` is *not*
            // covered, in tsc either: only the two keywords are.)
            //
            // Applied to initialization queries alone. It is tsc's rule for
            // every reference, but ztsc's binder builds both edges
            // unconditionally today, and retrofitting the rule into the graph
            // would re-shape narrowing for all of them — a change with its own
            // measurement, not a side effect of this one.
            if (key.opt_init and cond != null_node) {
                const dead: ast.Tag = if (b.flow_tags[flow] == .cond_true) .false_literal else .true_literal;
                if (c.nodeTag(cond) == dead) return types.never_type;
            }
            const before = try flowType(c, ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            const sense = b.flow_tags[flow] == .cond_true;
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return c.narrowByCondition(before, cond, sense, key, declared);
        },
        .switch_clause => {
            const clause = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const before = try flowType(c, ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return narrowBySwitchClause(c, before, clause, key, declared);
        },
        .switch_no_match => {
            const sw = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            // An exhaustive `default`-less switch cannot fall out of its
            // clause list, so this edge does not exist.
            if (c.switchIsExhaustive(sw)) return types.never_type;
            return flowType(c, ante, key, declared, depth + 1);
        },
        .call_stmt => {
            const call = b.flowNode(flow);
            const ante = b.flow_a[flow];
            // tsc's `getTypeAtFlowCall`: a call statement whose signature
            // returns `never` ENDS the flow (`unreachableNeverType`), for
            // every query and not just an initialization one.
            //
            // The end of the walk asks the same question once
            // (`flowTypeOfKey`'s reachability test), which is all a read
            // *standing after* the `never` call needs — it just wants its
            // declared type back. But a read whose flow only PASSES THROUGH
            // such an edge on one of several antecedents needs the answer
            // *here*: `if (!file) { ctx.throw(err); } return file.size;`
            // joins the `!file` true-branch, dead because koa's `ctx.throw`
            // returns `never`, with the false branch where `file` is defined
            // — and `never` drops out of that union, which is the whole
            // mechanism by which a throw helper ends a block. Asked at the
            // end instead, the reference's own flow node is plainly
            // reachable and the dead branch's `undefined` survived.
            // (Same reason an initialization query needs it: a `never` call
            // is what makes `constructor() { fail(); }` initialize
            // everything — nothing flows out of the constructor at all.)
            if (try callStmtReturnsNever(c, flow)) return types.never_type;
            const before = try flowType(c, ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            // The assertion callee is re-checked here; resolve it in the
            // scope where the call statement lives (it may be reached via a
            // loop back-edge from a shallower query scope).
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return narrowByAssertCall(c, before, call, key, declared);
        },
        .branch_label, .loop_label => {
            const antes = b.flowAntecedents(flow);
            // A loop label whose reference is *never assigned inside the
            // loop* keeps its pre-loop narrowing across the whole loop body
            // (tsc `getTypeAtFlowLoopLabel`: a reference only re-widens at a
            // back edge when the loop actually assigns it). The binder builds
            // a loop label with antecedent[0] = the pre-loop entry edge and
            // [1..] = back edges / `continue` jumps. For an unassigned simple
            // reference the type is invariant around the loop, so its type at
            // the label is exactly the entry type — take antecedent[0] alone
            // and skip the back edges. This both preserves the narrowing
            // (ztsc previously widened to `declared` at the in-progress back
            // edge, dropping every loop-crossing narrowing — `x: T | null`
            // guarded by an early return re-acquired `| null` inside a
            // following `for`/`while`) and avoids poisoning the flow cache
            // with an under-approximation while the label is in progress.
            // "Assigned inside this loop" is exact for `for/for..of/for..in`
            // (see `reassigned_in_loop` below) and a sound over-approximation
            // (file-level `reassigned_syms`) for `while`/`do`.
            // Loop-header bindings (a `for..of` element is not in the
            // reassignment scan yet is re-bound every iteration) and property
            // paths keep the full union-over-all-antecedents behavior.
            //
            // The shortcut fires *only when the pre-loop entry is actually
            // narrower than the declared type* — i.e. there is a narrowing to
            // preserve. When the entry equals `declared` the reference is
            // un-narrowed and the ordinary union path (which re-walks the back
            // edges and, in doing so, populates the flow cache exactly as
            // before) reproduces the pre-fix result byte-for-byte. This keeps
            // the change surgical: it can only ever *retain* a narrowing that
            // the old code dropped, never perturb the cache interaction of a
            // reference that was never narrowed before the loop (which would
            // otherwise unmask unrelated latent FPs downstream).
            if (b.flow_tags[flow] == .loop_label and antes.len >= 1 and
                !isPatternRoot(key.sym) and !c.symDeclaredInForHead(key.sym))
            {
                try c.ensureReassignScan();
                // "Assigned inside *this* loop" is the exact tsc predicate. A
                // `for`/`for..of`/`for..in` label's own scope is the loop's
                // `.for_head`, so a symbol assigned before the loop but never
                // inside it (`let x; …; x = f(); if(!x) return; for(…) use(x)`)
                // keeps its narrowing. `while`/`do` push no header scope, so
                // there the coarse file-level "reassigned anywhere" test is
                // used (sound: an assignment inside the loop always lands in
                // the file scan → never keeps a mutated narrowing).
                // A property path (`key.len != 0`) additionally re-widens if
                // ANY member/element write rooted at the same symbol occurs
                // inside the loop (the root reassign test alone misses
                // `o.p = …`). The property-name is not distinguished — a
                // write to any property of the root blocks the shortcut,
                // which is sound (only ever fails to retain a narrowing).
                const loop_scope = b.flowScope(flow);
                const is_for = b.scope_kinds[loop_scope] == .for_head;
                const root_assigned = if (is_for)
                    c.reassigned_in_loop.contains(.{ .sym = key.sym, .scope = loop_scope })
                else
                    c.reassigned_syms.contains(key.sym);
                const member_written = key.len != 0 and (if (is_for)
                    c.member_written_in_loop.contains(.{ .sym = key.sym, .scope = loop_scope })
                else
                    c.member_written_syms.contains(key.sym));
                const assigned_in_loop = root_assigned or member_written;
                if (!assigned_in_loop) {
                    const entry_t = try flowType(c, antes[0], key, declared, depth + 1);
                    if (entry_t != declared) return entry_t;
                }
            }
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            // The binder lays a loop label out as antecedent[0] = the
            // non-looping entry edge and [1..] = the back edges. tsc walks
            // the entry edge first, then publishes the partial union on the
            // in-process stack while it walks the back edges, so any query
            // that comes back round to this label reads that partial
            // instead of the declared type (see `flowType`).
            const looping = b.flow_tags[flow] == .loop_label and antes.len > 1;
            var frame: usize = 0;
            var published = false;
            for (antes, 0..) |a, i| {
                // tsc publishes as soon as ONE antecedent has been gathered,
                // whatever it says (`flowLoopTypes[i].length` is the only
                // test in `getTypeAtFlowLoopLabel`'s in-process check), and
                // this must not be narrowed to "only when the entry edge
                // narrowed". The partial's *value* is indeed uninteresting
                // when `parts[0] == declared` — it is the declared type
                // either way — but publication is also what raises
                // `flow_back_edge`, and that is what keeps every node the
                // back edge re-walks OUT of the persistent cache. Skipping it
                // let a node whose walk bottoms out in an in-flight ancestor
                // answer `declared` and then keep that answer forever in
                // `flow_same`, so a later authoritative query read "nothing
                // narrows here" for the whole tail of the loop body: social-
                // app's `const {success, type, mimeType} = await …; if
                // (!success) continue;` kept its sibling narrowing at every
                // guard inside the body and lost it at the joins between them.
                if (looping and i == 1 and parts.items.len != 0) {
                    published = true;
                    frame = c.flow_loop_stack.items.len;
                    const q: FlowQ = (@as(u64, c.cur_flow_base + flow) << 32) |
                        try refKeyIndex(c, key, declared);
                    // `parts` is scratch-backed and this publishes it where a
                    // deeper query can read it, so it is the one place in the
                    // checker that hands a scratch buffer sideways. It stays
                    // sound only because it is grown in THIS loop body alone,
                    // always after the recursive `flowType` below has fully
                    // unwound — i.e. always at this frame's own arena top,
                    // above every mark an inner expression takes — and because
                    // nested queries only read it. Growing it from anywhere
                    // reachable by a deeper frame would be a use-after-free.
                    try c.flow_loop_stack.append(c.cm(), .{ .q = q, .parts = &parts });
                    c.flow_back_edge += 1;
                    // Everything a back edge re-checks (an assignment's
                    // right-hand side, a guard call) is evaluated against
                    // the *partial* fixpoint, so its type must not be
                    // published as the node's answer — the authoritative
                    // check re-runs it against the finished label. tsc drops
                    // `flowTypeCache` around exactly this walk.
                    c.no_publish_depth += 1;
                }
                const t = try flowType(c, a, key, declared, depth + 1);
                if (t != types.never_type) try parts.append(c.scratch(), t);
            }
            if (published) {
                c.flow_loop_stack.shrinkRetainingCapacity(frame);
                c.flow_back_edge -= 1;
                c.no_publish_depth -= 1;
                // The partial answers only mean anything while some loop
                // fixpoint is in flight; once the outermost one finishes,
                // every query re-runs against the finished labels and lands
                // in the persistent cache.
                if (c.flow_back_edge == 0) c.flow_tmp.clearRetainingCapacity();
            }
            if (parts.items.len == 0) return types.never_type;
            // `recombineUnknown`: a join whose branches between them re-spell
            // `unknown` must hand `unknown` back, not its expansion.
            const joined = narrow.recombineUnknown(c, try c.ts.makeUnion(c.scratch(), parts.items));
            // tsc joins the antecedents of an EVOLVING (`auto`-typed)
            // variable with `UnionReduction.Subtype`, so a branch that
            // assigns `{ appState: … }` and one that assigns the
            // all-optional `Init` collapse to `Init` instead of a union
            // whose first constituent lacks the other's properties. Without
            // it every later `v?.someProp` reported TS2339.
            if (key.len == 0 and !isPseudoRoot(key.sym) and c.isEvolvingVar(key.sym)) {
                return reduceEvolvingJoin(c, joined);
            }
            return joined;
        },
    }
}

/// Can the assigned value change the answer at all — i.e. can
/// `assignmentReduced(declared, …)` return anything but `declared`?
///
/// tsc's `getTypeAtFlowAssignment` states the rule outright: *"Assignments
/// only narrow the computed type if the declared type is a union type."*
/// Its assignment arm is `declaredType.flags & Union ?
/// getAssignmentReducedType(declaredType, getAssignedType(node)) :
/// declaredType` — for every other declared type the right-hand side is
/// never even *evaluated*. (ztsc keeps one more refining case, a declared
/// `unknown`, which `assignmentReduced` widens the assigned value into.)
///
/// The distinction is not an optimization: TYPING the right-hand side is
/// arbitrary work pulled into the middle of a flow walk, and a flow walk is
/// routinely run from inside a *return-type inference*. Two unannotated
/// functions in a module cycle then reach each other through a right-hand
/// side whose value is discarded a line later, and whichever demand entered
/// the cycle first hits `typeOfSymbol`'s in-progress break and answers
/// `any`. That is how `getElementsWithinSelection`'s inferred return
/// (`return elementsInSelection`, a plain `El[]`) came to depend on
/// `elementOverlapsWithFrame` — through `elementsInSelection =
/// elementsInSelection.filter((e) => elementOverlapsWithFrame(…))`, an
/// assignment that cannot possibly refine `El[]` — and, because the cycle
/// was then entered from whichever side the partition happened to schedule
/// first, `.some((e) => …)` on the `any` result lost its contextual
/// signature in some `--checkers=N` and not others.
///
/// A declared `unknown` used to refine here too, which is NOT tsc's rule and
/// cost a dozen keys on `unknown`'s own conformance case: `const u: unknown =
/// undefined` typed every later reference `undefined`, so `u === aString`
/// narrowed to `never` and `let s: string = u` reported a phantom TS2322.
/// `unknown` is exactly the declared type that says "the value is not
/// characterised by where it came from".
fn assignmentRefines(c: *Checker, declared: TypeId) bool {
    return c.ts.kind(declared) == .union_type;
}

/// Does a write with this assignment operator INITIALIZE the property — i.e.
/// can `undefined` not survive it on any path?
///
/// `=` does. So do `??=` and `||=`, and not because tsc classifies them as
/// `AssignmentKind.Definite` (it does, via
/// `isLogicalOrCoalescingAssignmentOperator`) but because of what their flow
/// graph says: tsc binds `x ??= v` as a conditional, and the branch that
/// *skips* the write is the one where `x` was already non-nullish — truthy, for
/// `||=` — so neither branch leaves `undefined` behind. `&&=` is the mirror
/// image: its skipping branch is the FALSY one, which keeps `undefined`, so
/// `this.x &&= v` never initializes `x` and the oracle still reports TS2564.
/// ztsc's binder builds one unconditional assign node for all three, so the
/// distinction is drawn here rather than in the graph; the verdict is the same.
///
/// Every other compound operator reads before it writes and is not a definite
/// write in tsc either (`AssignmentKind.Compound`, whose arm hands back the type
/// from before the write).
fn definiteAssignOp(op: scanner.Tag) bool {
    return switch (op) {
        .eq, .pipe_pipe_eq, .question_question_eq => true,
        else => false,
    };
}

/// Does the destructuring-assignment target `node` write the reference `key`
/// anywhere inside it? Every element target of an object/array cover-grammar
/// pattern is its own definite write in tsc's flow graph, and nesting, defaults
/// and rest elements make the shape arbitrary, so this is a syntactic search
/// rather than a positional decode.
///
/// Over-approximating is the safe direction: a `this.x` that appears only in an
/// element's DEFAULT expression is a read, and counting it as a write can only
/// lose a TS2564, never invent one. Nested function bodies are excluded — a
/// `this.x` there is not part of this write at all.
fn patternWritesRef(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node) return false;
    if (try refMatches(c, node, key)) return true;
    switch (c.nodeTag(node)) {
        .arrow_fn, .function_expr, .function_decl, .object_method, .class_decl => return false,
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (try patternWritesRef(c, child, key)) return true;
    }
    return false;
}

/// Is `target` the element access `this["<key's member>"]` — the string-index
/// spelling of the one-link `this`-rooted reference `key` stands for? See the
/// call site for why the equivalence lives here and not in `refMatchesPath`.
fn writesThisStringIndex(c: *Checker, target: Node, key: RefKey) Error!bool {
    if (key.sym != this_flow_root or key.len != 1 or key.deep != 0) return false;
    if (key.path[0].isIndex()) return false;
    var n = c.referenceCandidate(target);
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .index_expr, .optional_index_expr => {},
        else => return false,
    }
    const d = c.tree.nodeData(n);
    if (c.nodeTag(d.lhs) != .this_expr) return false;
    var idx = d.rhs;
    while (c.nodeTag(idx) == .paren_expr) idx = c.tree.nodeData(idx).lhs;
    if (c.nodeTag(idx) != .string_literal) return false;
    return (try c.memberAtom(c.tree.nodeMainToken(idx))) == key.path[0].atom();
}

/// tsc's `containsUndefinedType`: does `t` have an `undefined` constituent?
/// Strictly `undefined` — `void` is a separate type there
/// (`getFalsyFlags(voidType) & TypeFlags.Undefined` is 0), which is why tsc
/// reports TS2564 for an uninitialized `x: void` and not for `x: undefined`.
/// `containsUndefinedish` folds the two together and is the wrong predicate
/// here.
pub fn hasUndefinedMember(c: *Checker, t: TypeId) bool {
    return c.unionAnyMember(t, struct {
        fn f(ch: *Checker, m: TypeId) bool {
            return ch.ts.kind(m) == .undefined;
        }
    }.f);
}

/// tsc's `isPropertyInitializedInConstructor`, inverted: does some path
/// reaching `flow` leave `this.<name>` unwritten?
///
/// `flow` is the constructor's RETURN join (the binder's `flowAt(ctor)`, tsc's
/// `returnFlowNode`) for TS2564, or a reference's own flow node for TS2565.
/// The walk is the ordinary narrowing walk with `RefKey.opt_init` set, so
/// `undefined` enters only at the top of the constructor's flow and only a
/// definite write or a narrowing can remove it.
///
/// `false` on anything untrackable (an unfoldable member atom, a path the
/// interner refused): the property is then treated as initialized, which is the
/// under-reporting side.
pub fn thisPropUnassigned(c: *Checker, flow: FlowId, name: Atom, declared: TypeId) Error!bool {
    if (!PathElem.memberFits(name)) return false;
    const elems = [1]PathElem{.member(name)};
    var key = (try c.makeRefKey(this_flow_root, elems[0..])) orelse return false;
    key.opt_init = true;
    const t = try flowType(c, flow, key, declared, 0);
    return hasUndefinedMember(c, t);
}

/// The definite-assignment (TS2454) half of the same walk, for a VARIABLE
/// reference: the ordinary narrowing walk over `declared | undefined`, run as
/// an initialization query (`RefKey.opt_init`) so the two rules a plain
/// narrowing walk deliberately skips both apply here —
///
///   • a COMPOUND write (`x += 1`, `x++`) is not an initialization, so
///     `undefined` survives it exactly as tsc's compound arm does, and
///   • the branch a literal `true`/`false` condition contradicts does not
///     exist, so `false ? unassigned : y` and `if (true) { x = 1; } x` are
///     both silent.
///
/// `undefined` still enters only at the top of the flow, which is what makes
/// "the answer still admits `undefined`" mean "some path left it unwritten".
pub fn unassignedVarType(c: *Checker, node: Node, sym: SymbolId, optional: TypeId) Error!TypeId {
    return c.flowTypeOfKey(node, .{ .sym = sym, .opt_init = true }, optional);
}

/// tsc's `getControlFlowContainer`: the nearest enclosing function, MODULE
/// BLOCK, or source file.
///
/// `Checker.containerOf` stops only at functions and the file, which is the
/// right answer for the scope questions it is asked but the wrong one for
/// definite assignment: a `namespace` body has its own flow graph, so a `var`
/// of an enclosing namespace (or of the file) read inside a nested one is an
/// OUTER variable to tsc and assumed initialized. Without the distinction
/// `namespace m2 { var x: string|number; namespace m3 { … x … } }` reported
/// TS2454 on every such read (`typeGuardsInModule`,
/// `typeGuardsInFunctionAndModuleBlock`).
pub fn flowContainerOf(c: *const Checker, s: binder.ScopeId) binder.ScopeId {
    var cur = s;
    while (cur != binder.file_scope) {
        switch (c.bind.scope_kinds[cur]) {
            .function, .file, .namespace => return cur,
            else => cur = c.bind.scope_parents[cur],
        }
    }
    return binder.file_scope;
}

/// Is `node` an identifier that the head of an enclosing `for..in`/`for..of`
/// statement ASSIGNS — `for (x of xs)`, `for ({ a: x } of xs)`,
/// `for ([x] of xss)`? Such a reference is a WRITE, and tsc never reports it
/// unassigned: its binder places the head's flow assignment node *ahead* of
/// the target expression, so the target's own identifiers read the loop
/// variable as already written. Only uses after the loop are reported, since
/// the loop body may never run.
///
/// ztsc's binder adds the assign node after binding the target (`bindForInOf`),
/// which is the right order for narrowing the loop BODY, so the exemption is
/// drawn here instead of in the graph. Restricted to the assignment form: a
/// declaration head declares the variable and never reaches TS2454 anyway.
pub fn inForHeadWriteTarget(c: *Checker, node: Node, sym: SymbolId) Error!bool {
    const b = c.bind;
    const stop = c.containerOf(c.cur_scope);
    var s = c.cur_scope;
    while (true) {
        if (b.scope_kinds[s] == .for_head) {
            const owner = b.scope_owners[s];
            const is_for_in_of = owner != null_node and switch (c.nodeTag(owner)) {
                .for_in_stmt, .for_of_stmt => true,
                else => false,
            };
            if (is_for_in_of) {
                const e = c.tree.extraData(ast.ForInOf, c.tree.nodeData(owner).lhs);
                switch (c.nodeTag(e.left)) {
                    .var_decl_one, .var_decl => {},
                    else => if (try patternBindsSym(c, e.left, sym)) {
                        // A single-statement loop body shares the head's
                        // scope, so the name match alone is not enough — the
                        // reference has to sit inside the target itself.
                        const span = c.nodeSpan(e.left);
                        const at = c.nodeSpanStart(node);
                        if (at >= span.start and at < span.end) return true;
                    },
                }
            }
        }
        if (s == stop or s == binder.file_scope) return false;
        s = b.scope_parents[s];
    }
}

/// Is this assign-flow node a `for..in` key binding whose ENUMERATED OBJECT
/// is the reference being asked about? Then the type inside the loop is the
/// antecedent's with nullish stripped (tsc's `getTypeAtFlowAssignment`, last
/// arm). The binder marks the per-iteration key binding with an `.assign`
/// flow whose node is the loop's own initializer and whose scope is the
/// loop's `.for_head`, and that scope's owner is the `for..in` statement —
/// which is how the right-hand side is reached from here.
///
/// Restricted to the DECLARATION form, as tsc is (`isVariableDeclaration`):
/// `for (k in maybeUndefined)` — assigning to an existing binding — narrows
/// nothing there either.
fn forInSubjectMatches(c: *Checker, flow: FlowId, target: Node, key: RefKey) Error!bool {
    const b = c.bind;
    switch (c.nodeTag(target)) {
        .var_decl_one, .var_decl => {},
        else => return false,
    }
    const scope = b.flowScope(flow);
    if (b.scope_kinds[scope] != .for_head) return false;
    const owner = b.scope_owners[scope];
    if (owner == null_node or c.nodeTag(owner) != .for_in_stmt) return false;
    const e = c.tree.extraData(ast.ForInOf, c.tree.nodeData(owner).lhs);
    if (e.left != target) return false;
    return refMatches(c, e.right, key);
}

/// Does this type carry a `null`/`undefined` constituent to strip? tsc's
/// `getNonNullableTypeIfNeeded` guard, kept syntactic so that a type whose
/// nullish arm is hidden behind a constraint (a bare type parameter) is left
/// exactly as it was.
///
/// The union kind is checked before the member walk because `members` is a
/// raw `extra` slice keyed by kind: an `.object`'s payload words are an extra
/// index and a property count, so reading them as a member range is not a
/// wrong answer but an invalid slice.
pub fn isNullishUnion(c: *Checker, t: TypeId) bool {
    if (isNullishKind(c.ts.kind(t))) return true;
    if (c.ts.kind(t) != .union_type) return false;
    for (c.ts.members(t)) |m| {
        if (isNullishKind(c.ts.kind(m))) return true;
    }
    return false;
}

/// If the assign-flow node writes the reference (or invalidates a
/// property path by writing its root), the type after the assignment;
/// null when it is unrelated.
fn assignNarrows(c: *Checker, target: Node, key: RefKey, declared: TypeId) Error!?TypeId {
    if (target == null_node) return null;
    const root_sym = key.sym;
    switch (c.nodeTag(target)) {
        .declarator_init => {
            const d = c.tree.nodeData(target);
            if (!try patternBindsSym(c, d.lhs, root_sym)) return null;
            if (key.len != 0) return declared; // root re-init: reset path
            if (c.nodeTag(d.lhs) != .identifier) return declared;
            if (!assignmentRefines(c, declared)) return declared;
            const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
            return try assignmentReduced(c, declared, vt);
        },
        .declarator_full => {
            const d = c.tree.nodeData(target);
            if (!try patternBindsSym(c, d.lhs, root_sym)) return null;
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (key.len != 0) return declared;
            if (e.init == 0) return declared;
            if (c.nodeTag(d.lhs) != .identifier) return declared;
            if (!assignmentRefines(c, declared)) return declared;
            // Reading this variable can reach its declaration's flow node
            // BEFORE the declaration statement itself is checked — a JSX
            // attribute referring to a `const cb: CB = (props) => …`
            // declared earlier in the file, or a cross-file demand. The
            // initializer then has to be checked here, and checking it with
            // NO contextual type is what the declaration statement would
            // never do: an arrow's parameters get no contextual signature,
            // materialize as `any`, and that answer is what the (cached)
            // authoritative check reads back — TS7006 on every callback in
            // the body. Supply the annotation, exactly as `checkDeclarator`
            // does, so both orders produce the same signature.
            // (`unique symbol` is left alone — it contextually types
            // nothing, and resolving it here would raise TS1335 a second
            // time, out of the declaration's own position.)
            const ctx: TypeId = if (e.type_ann != 0 and c.nodeTag(e.type_ann) != .unique_symbol_type)
                try c.typeFromTypeNode(e.type_ann)
            else
                types.no_type;
            const vt = c.nodeType(e.init) orelse try c.checkExprCached(e.init, ctx);
            return try assignmentReduced(c, declared, vt);
        },
        .assign => {
            const d = c.tree.nodeData(target);
            // Full path write: <ref> = v narrows the tracked reference.
            if (key.len != 0 and try refMatches(c, d.lhs, key)) {
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                // A COMPOUND write is not an initialization: tsc's
                // `getAssignmentTargetKind` calls `=` and the three logical
                // assignments *definite* and everything else compound, and its
                // compound arm hands back the type from BEFORE the write — so
                // `this.x += 1` in a constructor still leaves TS2564 (and
                // reports TS2565 for the read the operator performs). ztsc's
                // arm below instead types the whole expression, which answers
                // the declared type: right for narrowing, wrong here.
                if (key.opt_init and !definiteAssignOp(op)) return null;
                // A compound assignment writes a PATH exactly as it writes a
                // variable, and tsc narrows both (a property access is a
                // reference in the flow graph). `session.startSegment ??= i`
                // leaves a `number`, and giving up here left it `number |
                // null` for the rest of the function — immich's
                // `TranscodingService.onSegmentRequest`.
                if (op != .eq) {
                    const vt = c.nodeType(target) orelse
                        try c.checkExprCached(target, types.no_type);
                    return try assignmentReduced(c, declared, vt);
                }
                if (!assignmentRefines(c, declared)) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                return try assignmentReduced(c, declared, vt);
            }
            // Writing any proper prefix of the path (its root, or an
            // intermediate member) invalidates the whole subtree.
            if (try refPrefixWritten(c, d.lhs, key)) return declared;
            if (c.nodeTag(d.lhs) == .identifier) {
                if (!try c.identIsSym(d.lhs, root_sym)) return null;
                // key.len != 0 was caught above by refPrefixWritten.
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                // Same rule the property query draws above, for a variable:
                // a compound write is not an initialization, so an
                // initialization query walks PAST it and lets `undefined`
                // through. The narrowing arm below deliberately answers with
                // the whole expression's type instead, which is more precise
                // than tsc's `getBaseTypeOfLiteralType(typeAtAntecedent)` and
                // would hide every TS2454 after an `x += 1`.
                if (key.opt_init and !definiteAssignOp(op)) return null;
                // An evolving (`auto`-typed) variable takes the assigned
                // type outright — there is no declared type to reduce it
                // against (tsc `getTypeAtFlowAssignment`, autoType branch).
                const evolving = key.len == 0 and c.isEvolvingVar(root_sym);
                if (op != .eq) {
                    // A compound assignment's post-value is the whole
                    // expression's type (`x ??= s` leaves `NonNullable<x> |
                    // typeof s`), so it has to be CHECKED, not read
                    // opportunistically out of the node cache. A reference can
                    // reach this flow node before the assignment statement is
                    // itself checked — a later reference in the same function
                    // whose type is demanded first (an inferred return type
                    // mentioning it is enough) — and falling back to `declared`
                    // there is not merely imprecise: `flowType` memoizes a
                    // result equal to `declared` as "this reference narrows
                    // nothing", so the non-answer is published for every later
                    // query at this node. The `.eq` arm below already checks
                    // its right-hand side for exactly this reason.
                    const vt = c.nodeType(target) orelse
                        try c.checkExprCached(target, types.no_type);
                    if (evolving) return try c.widenLiteral(vt);
                    return try assignmentReduced(c, declared, vt);
                }
                if (!evolving and !assignmentRefines(c, declared)) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                if (evolving) return try c.widenLiteral(vt);
                return try assignmentReduced(c, declared, vt);
            }
            if (try patternBindsSym(c, d.lhs, root_sym)) {
                // `[, width, height] = match` assigns a *position* of the
                // right-hand side, and tsc reduces the declared type by that
                // element's type just like a plain `width = …` (its
                // `getAssignedType` walks the destructuring target). Falling
                // back to `declared` here re-widened a `string | null` that
                // an earlier `width = width || "50"` had already narrowed.
                if (key.len == 0 and assignmentRefines(c, declared)) {
                    const rt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                    if (try destructuredAssignType(c, d.lhs, c.symNameAtom(root_sym), rt)) |vt| {
                        return try assignmentReduced(c, declared, vt);
                    }
                }
                return declared;
            }
            // A destructuring assignment can write a `this` property —
            // `({ a: this.a } = o)`, `[this.a] = arr`, `({ a: this.a = d } = o)`.
            // tsc records each element target as its own definite write
            // (`bindDestructuringTargetFlow`); ztsc's narrowing does not track
            // property paths through a pattern and answers "unrelated", which
            // is a sound loss of narrowing but would MANUFACTURE a TS2564.
            // Only the initialization query needs the write, and only its
            // presence, so the pattern is scanned for the reference itself.
            if (key.opt_init) {
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                switch (c.nodeTag(d.lhs)) {
                    .object_literal, .array_literal, .object_pattern, .array_pattern => {
                        if (try patternWritesRef(c, d.lhs, key)) return declared;
                    },
                    // `this["x"] = v` writes the same property as `this.x = v`
                    // — tsc's `isMatchingReference` compares accesses through
                    // `getAccessedPropertyName`, which reads a string-literal
                    // index as a property name. ztsc's narrowing does not
                    // unify the two spellings (the binder only tracks an
                    // element access indexed by a number or a stable
                    // identifier), and widening it there would re-shape
                    // narrowing for every reference; the initialization query
                    // needs only to see the WRITE, so the widening is here.
                    .index_expr, .optional_index_expr => {
                        if (definiteAssignOp(op) and try writesThisStringIndex(c, d.lhs, key)) return declared;
                    },
                    else => {},
                }
            }
            return null;
        },
        .prefix_unary, .postfix_unary => {
            const d = c.tree.nodeData(target);
            if (try refMatches(c, d.lhs, key)) {
                // `this.x++` is compound in tsc's sense: see the note in the
                // `.assign` arm. It reads before it writes, so it neither
                // initializes the property nor hides TS2565.
                if (key.opt_init) return null;
                return try assignmentReduced(c, declared, types.number_type);
            }
            if (try refPrefixWritten(c, d.lhs, key)) return declared;
            return null;
        },
        // for-of / for-in left (var decl or expression).
        .var_decl_one, .var_decl => {
            if (try varDeclBindsSym(c, target, root_sym)) {
                if (key.len != 0) return declared;
                // The element type was computed when the statement was
                // checked; the symbol type already reflects it.
                return try c.typeOfSymbol(root_sym);
            }
            return null;
        },
        .identifier => {
            if (!try c.identIsSym(target, root_sym)) return null;
            return declared;
        },
        else => {
            if (try patternBindsSym(c, target, root_sym)) return declared;
            return null;
        },
    }
}

/// Narrow `t` (the flow type of the reference) by a decomposed
/// condition node.
/// Whether the tracked reference is a *constant reference* in tsc's sense:
/// a root-identifier reference to a `const`, or to a parameter / mutable
/// local that is never reassigned anywhere in its file. Aliased-condition
/// narrowing requires this — an alias snapshots the condition at its
/// declaration point, so a reassignable subject could make the snapshot
/// stale (mirrors tsc's `isConstantReference`).
fn isConstantRefSym(c: *Checker, key: RefKey) Error!bool {
    if (key.len != 0) return false;
    if (isPseudoRoot(key.sym)) return false;
    const sf = c.symFlags(key.sym);
    if (sf.const_decl) return true;
    if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return false;
    if (sf.exported) return false; // a top-level export may be reassigned elsewhere
    if (c.symFile(key.sym) != c.cur_file) return false;
    try c.ensureReassignScan();
    return !c.reassigned_syms.contains(key.sym);
}

/// TS4.4 aliased-condition support: if `cond` is a bare identifier bound to
/// a `const` variable whose declarator has an initializer and no explicit
/// type annotation, and the tracked reference `key` is a constant
/// reference, return that initializer expression so the caller can narrow
/// `key` by it. Any unmet precondition returns null (narrowing untouched):
///   • alias must be declared `const` (a never-reassigned `let` does NOT
///     narrow — verified against tsc 5.9.3),
///   • the declarator must carry no explicit type annotation (`const m:
///     boolean = …` does not narrow), and bind a plain identifier (no
///     destructured alias),
///   • same-file, non-exported (so the initializer resolves in scope).
fn constAliasInit(c: *Checker, cond: Node, key: RefKey) Error!?Node {
    if (c.nodeTag(cond) != .identifier) return null;
    if (!try isConstantRefSym(c, key)) return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(cond));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    if (sym == key.sym) return null; // matched-reference case handled by the caller
    const sf = c.symFlags(sym);
    if (!sf.const_decl) return null;
    if (sf.exported) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return null;
    const decl = decls[0];
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .declarator_init => {
            if (c.nodeTag(d.lhs) != .identifier) return null;
            return d.rhs;
        },
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann != 0 or e.init == 0) return null;
            if (c.nodeTag(d.lhs) != .identifier) return null;
            return e.init;
        },
        else => return null,
    }
}

pub fn narrowByCondition(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey, decl: TypeId) Error!TypeId {
    if (cond == null_node) return t;
    const d = c.tree.nodeData(cond);
    switch (c.nodeTag(cond)) {
        .paren_expr => return c.narrowByCondition(t, d.lhs, sense, key, decl),
        .non_null => return c.narrowByCondition(t, d.lhs, sense, key, decl),
        // `if ((m = next()))` — an assignment's value is the target's new
        // value, so its truthiness narrows the target (tsc narrows by
        // `getReferenceCandidate` of the condition); a comma expression
        // condition is its right operand.
        .assign, .seq_expr => {
            const cand = c.referenceCandidate(cond);
            if (cand != cond) return c.narrowByCondition(t, cand, sense, key, decl);
            return t;
        },
        .identifier => {
            if (try refMatches(c, cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            // A bare identifier can also READ a discriminant rather than be
            // one: a binding destructured out of a union stands for the
            // property it binds, so `if (canceled)` / `if (detached)`
            // discriminates the union the same way `if (x.canceled)` does.
            // This is `getDiscriminantPropertyAccess` inside tsc's
            // `narrowTypeByTruthiness`; without it only the equality and
            // `switch` forms narrowed the siblings, and the boolean
            // discriminant — the form that has no comparand to write — did
            // not narrow at all.
            if (try discriminantOfRef(c, cond, key)) |prop| {
                return narrowByPropTruthiness(c, t, prop, sense, decl);
            }
            // Aliased-condition narrowing (tsc TS4.4 "control flow analysis
            // of aliased conditions and discriminants"): the condition is a
            // bare identifier bound to a `const` whose initializer is itself
            // a narrowing expression. Narrow the tracked reference by that
            // initializer instead. `constAliasInit` enforces tsc's rules
            // (const alias, no explicit annotation, subject a constant
            // reference so the snapshot cannot go stale); the level cap
            // bounds alias-of-alias chains.
            if (c.alias_inline_level < 5) {
                if (try constAliasInit(c, cond, key)) |init_expr| {
                    c.alias_inline_level += 1;
                    defer c.alias_inline_level -= 1;
                    return c.narrowByCondition(t, init_expr, sense, key, decl);
                }
            }
            return t;
        },
        .member_expr, .optional_member_expr => {
            // The path itself is the condition.
            if (try refMatches(c, cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            // `if (<ref>.p)` / `if (<ref>?.p)` — discriminate the tracked
            // reference by the truthiness of an extra property `p`.
            if (try refMatches(c, d.lhs, key)) {
                var base = t;
                if (c.nodeTag(cond) == .optional_member_expr and sense) {
                    base = try c.nonNullable(base);
                }
                const prop = try c.memberAtom(d.rhs);
                return narrowByPropTruthiness(c, base, prop, sense, decl);
            }
            // A truthy optional chain (`if (a?.b.c)`, `if (!a?.b.c)` else)
            // implies its receivers did not short-circuit: narrow a contained
            // receiver reference to non-null. This is tsc's
            // `narrowTypeByTruthiness` optional-chain-containment rule — it
            // fires on the true branch only (a falsy chain says nothing about
            // whether the receiver was nullish).
            if (sense and try optionalChainContainsRef(c, cond, key)) {
                return c.nonNullable(t);
            }
            return t;
        },
        // `if (arr[0])` — a constant element access is a tracked
        // reference, so its own truthiness narrows it (`refMatches` walks
        // element links). Failing that, an ELEMENT-access chain link
        // (`a?.[k]`) is the same optional chain as `a?.p` on a different
        // node tag: a truthy chain implies its receivers did not
        // short-circuit, so the member arm's containment rule applies.
        .index_expr, .optional_index_expr => {
            if (try refMatches(c, cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            // `if (<ref>["p"])` — the element spelling of the member arm's
            // discriminant-truthiness rule (`getAccessedPropertyName` reads
            // both spellings as the same property).
            if (try discriminantOfRef(c, cond, key)) |prop| {
                var base = t;
                if (c.nodeTag(cond) == .optional_index_expr and sense) {
                    base = try c.nonNullable(base);
                }
                return narrowByPropTruthiness(c, base, prop, sense, decl);
            }
            if (sense and try optionalChainContainsRef(c, cond, key)) {
                return c.nonNullable(t);
            }
            return t;
        },
        .binary => {
            const op = c.tree.tokens.tag(c.tree.nodeMainToken(cond));
            switch (op) {
                .eq_eq_eq, .bang_eq_eq, .eq_eq, .bang_eq => {
                    const strict = op == .eq_eq_eq or op == .bang_eq_eq;
                    var eff_sense = sense;
                    if (op == .bang_eq_eq or op == .bang_eq) eff_sense = !sense;
                    return narrowByEqualityCond(c, t, d.lhs, d.rhs, strict, eff_sense, key, decl);
                },
                .keyword_in => {
                    // `"p" in x`
                    if (!try refMatches(c, d.rhs, key)) return t;
                    const lhs_t = try c.checkExprCached(d.lhs, types.no_type);
                    const rl = try c.ts.regularLiteral(lhs_t);
                    if (c.ts.kind(rl) != .string_literal) return t;
                    return narrowByInProp(c, t, c.ts.literalAtom(rl), sense);
                },
                .keyword_instanceof => {
                    if (!try refMatches(c, d.lhs, key)) {
                        // `a?.b instanceof C` being true implies the chain
                        // did not short-circuit, so its receivers are not
                        // nullish — the same optional-chain containment rule
                        // the truthiness arms above apply, and the reason
                        // `if (cached?.image instanceof Promise) await
                        // cached.image;` is legal. False says nothing.
                        if (sense and try optionalChainContainsRef(c, d.lhs, key)) {
                            return c.nonNullable(t);
                        }
                        return t;
                    }
                    const rt = try c.checkExprCached(d.rhs, types.no_type);
                    if (try c.instanceofInstanceType(rt)) |inst| {
                        // tsc's "don't narrow from 'any' if the target type is
                        // exactly 'Object' or 'Function'" — every value
                        // satisfies either, so `x instanceof Object` on an
                        // `any` would only take members away.
                        const tk = c.ts.kind(t);
                        if ((tk == .any or tk == .unknown or tk == .err) and
                            try narrow.isObjectOrFunctionIface(c, inst)) return t;
                        return narrowByInstance(c, t, inst, sense, true);
                    }
                    return t;
                },
                // `a && b` true implies both operands are truthy; `a || b`
                // false implies both are falsy (tsc
                // `narrowTypeByBinaryExpression`). A condition written
                // directly in an `if` never reaches here — the binder
                // decomposes it into separate flow nodes — but an *aliased*
                // condition does, because `constAliasInit` hands the alias's
                // initializer straight to this narrower, bypassing the
                // binder. `const g = isImg(e) && files[e.fileId]; if (g) …`
                // is the shape that needs it. The other polarity of each
                // operator says nothing about either operand.
                // The OTHER polarity of each operator is not silent either,
                // it is a union of the two ways the operator can land
                // (tsc `narrowTypeByBinaryExpression`): `a || b` true means
                // "a true, OR a false and b true", and `a && b` false means
                // "a false, OR a true and b false". `const terminal =
                // s?.status === 'x' || s?.status === 'y'; if (terminal) s.n`
                // needs it — each arm alone removes `undefined` from `s`, so
                // their union does too, while returning `t` here keeps it.
                .amp_amp => {
                    const lt = try c.narrowByCondition(t, d.lhs, true, key, decl);
                    if (sense) return c.narrowByCondition(lt, d.rhs, true, key, decl);
                    return c.makeUnion2(
                        try c.narrowByCondition(t, d.lhs, false, key, decl),
                        try c.narrowByCondition(lt, d.rhs, false, key, decl),
                    );
                },
                .pipe_pipe => {
                    const lf = try c.narrowByCondition(t, d.lhs, false, key, decl);
                    if (!sense) return c.narrowByCondition(lf, d.rhs, false, key, decl);
                    return c.makeUnion2(
                        try c.narrowByCondition(t, d.lhs, true, key, decl),
                        try c.narrowByCondition(lf, d.rhs, true, key, decl),
                    );
                },
                else => return t,
            }
        },
        // A condition written directly in an `if` never reaches here — the
        // binder decomposes `!` into separate flow nodes — but an *aliased*
        // condition does, because `constAliasInit` hands the alias's
        // initializer straight to this narrower, bypassing the binder. Exactly
        // the reason the `&&` / `||` arms above exist, and `const isActive =
        // !!v; if (!isActive) return;` is the shape that needs it. Only `!`
        // says anything about its operand; `-`/`~`/`+`/`typeof`/`void` do not.
        .prefix_unary => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(cond)) != .bang) return t;
            return c.narrowByCondition(t, d.lhs, !sense, key, decl);
        },
        .call_expr, .call_expr_targs, .optional_call => {
            // A truthy optional-*call* chain (`if (a?.m())`, or the
            // fall-through of `if (!a?.m()) return`) implies its receivers
            // did not short-circuit: narrow a contained receiver to
            // non-null. Symmetric with the optional-member arm above
            // (tsc's `narrowTypeByTruthiness` optional-chain containment);
            // fires on the truthy branch only. This is what lets the common
            // `if (!raw?.trim()) return ''; …raw…` guard narrow `raw`.
            if (sense and try optionalChainContainsRef(c, cond, key)) {
                return c.nonNullable(t);
            }
            return narrowByGuardCall(c, t, cond, sense, key);
        },
        else => return t,
    }
}

fn narrowByEqualityCond(c: *Checker, t: TypeId, lhs: Node, rhs: Node, strict: bool, sense: bool, key: RefKey, decl: TypeId) Error!TypeId {
    // typeof <ref> === "..."
    if (try typeofTargetOf(c, lhs, key)) {
        const rt = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
        if (c.ts.kind(rt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(rt), sense);
        }
        return t;
    }
    if (try typeofTargetOf(c, rhs, key)) {
        const lt = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
        if (c.ts.kind(lt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(lt), sense);
        }
        return t;
    }
    // `typeof <optional-chain-containing-ref> === "…"`: the chain short-
    // circuits to `undefined` (so `typeof` is `"undefined"`) exactly when a
    // receiver was nullish. If this branch forces `typeof(chain) !=
    // "undefined"`, that receiver did not short-circuit — narrow it non-null
    // (tsc's `narrowTypeByTypeof` optional-chain-containment rule). `sense`
    // here is already equals-folded (`!==`/`!=` inverted by the caller).
    if (try typeofChainContainsRef(c, lhs, key)) {
        return narrowByTypeofChainContainment(c, t, rhs, sense);
    }
    if (try typeofChainContainsRef(c, rhs, key)) {
        return narrowByTypeofChainContainment(c, t, lhs, sense);
    }
    // <ref> === <literal> / <literal> === <ref>
    if (try refMatches(c, lhs, key)) {
        return narrowByLiteralEquality(c, t, rhs, strict, sense);
    }
    if (try refMatches(c, rhs, key)) {
        return narrowByLiteralEquality(c, t, lhs, strict, sense);
    }
    // `<ref>.constructor === C` — tsc's `narrowTypeByConstructor`. Ahead of
    // the discriminant arm, which would otherwise read `constructor` as a
    // discriminant property and filter by a literal no constituent carries.
    // Only the branch where the equality HOLDS narrows (`sense` is already
    // equals-folded): a subclass instance's `constructor` is the subclass, so
    // the inequality rules nothing out.
    if (try constructorRefOf(c, lhs, key)) {
        if (!sense) return t;
        return narrowByConstructorProp(c, t, try c.checkExprCached(rhs, types.no_type));
    }
    if (try constructorRefOf(c, rhs, key)) {
        if (!sense) return t;
        return narrowByConstructorProp(c, t, try c.checkExprCached(lhs, types.no_type));
    }
    // <ref>.k === <literal> narrows <ref> by its discriminant. `<ref>` is
    // the tracked reference — a root symbol (`x.k`, key.len == 0) or a
    // member path (`f.geometry.k`, narrowing the union stored at the
    // tracked `f.geometry`). The union `t` is `<ref>`'s type, so the same
    // discriminant filter applies regardless of the reference's depth.
    if (try discriminantOfRef(c, lhs, key)) |prop| {
        const other = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
        const narrowed = try narrowByDiscriminant(c, t, prop, other, sense, decl);
        // An OPTIONAL discriminant read (`x?.k === lit`) short-circuits to
        // `undefined` when the receiver is nullish, so the equality also
        // forces the receiver non-nullish on the asserting branch (tsc's
        // optional-chain containment). The discriminant filter alone keeps
        // `undefined` (no `k` prop → conservatively kept), so strip it too.
        if (c.nodeTag(lhs) == .optional_member_expr or c.nodeTag(lhs) == .optional_index_expr) {
            return narrowByOptChainContainment(c, narrowed, rhs, strict, sense);
        }
        return narrowed;
    }
    if (try discriminantOfRef(c, rhs, key)) |prop| {
        const other = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
        const narrowed = try narrowByDiscriminant(c, t, prop, other, sense, decl);
        if (c.nodeTag(rhs) == .optional_member_expr or c.nodeTag(rhs) == .optional_index_expr) {
            return narrowByOptChainContainment(c, narrowed, lhs, strict, sense);
        }
        return narrowed;
    }
    // Optional-chain containment: `a?.….m() === <value>` narrows the chain's
    // *receiver* `a` to non-null (tsc's narrowTypeByOptionalChainContainment).
    // If `a` were nullish the whole chain short-circuits to `undefined`, so
    // when the comparison to `value` can only hold for a non-undefined (and,
    // for `==`/`!=`, non-null) `value`, the receiver did not short-circuit.
    if (try optionalChainContainsRef(c, lhs, key)) {
        return narrowByOptChainContainment(c, t, rhs, strict, sense);
    }
    if (try optionalChainContainsRef(c, rhs, key)) {
        return narrowByOptChainContainment(c, t, lhs, strict, sense);
    }
    return t;
}

/// Walks an optional chain's receiver spine (`chain.expression` at each
/// link), returning true when `key` matches a receiver at some optional
/// link — i.e. `key`'s reference is a container of the chain's short-circuit
/// (tsc's `optionalChainContainsReference`). Only fires for a chain that
/// actually has a `?.` link; a plain `a.b.c` never matches.
fn optionalChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
    var n = node;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    while (c.isOptionalChain(n)) {
        n = c.tree.nodeData(n).lhs; // step to this link's object/callee
        if (try refMatches(c, n, key)) return true;
    }
    return false;
}

/// Apply tsc's `narrowTypeByOptionalChainContainment`: remove `null`/
/// `undefined` from the receiver `t` when the comparand `value` forces the
/// chain to not have short-circuited in this branch. `strict` selects the
/// nullable set (`===`/`!==` → `undefined` only; `==`/`!=` → `null` |
/// `undefined`). `sense` is the already-bang-folded truthiness (so `!==`
/// arrives as an inverted `===`): with the operator's equals-ness folded in,
/// `sense` true means "narrow when every comparand constituent is
/// non-nullish and not any/unknown"; `sense` false means "narrow when every
/// comparand constituent is nullish".
fn narrowByOptChainContainment(c: *Checker, t: TypeId, value: Node, strict: bool, sense: bool) Error!TypeId {
    const vt = try c.checkExprCached(value, types.no_type);
    if (optChainComparandRemovesNullable(c, vt, strict, sense)) return c.nonNullable(t);
    return t;
}

fn optChainComparandRemovesNullable(c: *Checker, vt: TypeId, strict: bool, sense: bool) bool {
    if (c.ts.kind(vt) == .union_type) {
        for (c.ts.members(vt)) |m| {
            if (!optChainComparandConstituentOk(c, m, strict, sense)) return false;
        }
        return true;
    }
    return optChainComparandConstituentOk(c, vt, strict, sense);
}

fn optChainComparandConstituentOk(c: *Checker, m: TypeId, strict: bool, sense: bool) bool {
    const k = c.ts.kind(m);
    const nullish = k == .undefined or k == .void or (!strict and k == .null);
    if (sense) {
        // Every constituent must be non-nullish and not any/unknown/err
        // (their domains include undefined/null, so they can't force a
        // non-null receiver).
        return !nullish and k != .any and k != .unknown and k != .err;
    }
    // Every constituent must be nullish.
    return nullish;
}

fn typeofTargetOf(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
    if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
    return refMatches(c, c.tree.nodeData(node).lhs, key);
}

/// `node` is `typeof <expr>` whose `<expr>` is an optional chain containing
/// `key`'s reference at an optional link (but is not the ref itself — that
/// exact case is `typeofTargetOf`).
fn typeofChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
    if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
    return optionalChainContainsRef(c, c.tree.nodeData(node).lhs, key);
}

/// Narrow a chain receiver `t` to non-null when a `typeof <chain>` branch
/// forces `typeof(chain) != "undefined"`. `sense` is the equals-folded
/// branch truthiness (true ⇒ the branch asserts `typeof(chain) == literal`).
/// The chain did not short-circuit iff its `typeof` is not `"undefined"`, so
/// narrow iff `sense == (literal != "undefined")`.
fn narrowByTypeofChainContainment(c: *Checker, t: TypeId, value: Node, sense: bool) Error!TypeId {
    const rt = try c.ts.regularLiteral(try c.checkExprCached(value, types.no_type));
    if (c.ts.kind(rt) != .string_literal) return t;
    const is_undef_lit = c.ts.literalAtom(rt) == c.typeof_atoms[5]; // "undefined"
    if (sense != is_undef_lit) return c.nonNullable(t);
    return t;
}

/// `<ref>.k` where `<ref>` is exactly `key`'s reference: returns the
/// discriminant property NAME `k`. Handles any tracked reference — a root
/// symbol (`x.k`) *or* a depth-1 member path (`f.geometry.k`) — by reusing
/// `refMatches` on the access base.
///
/// Both a plain `.k` and an optional `?.k` access count, and so does the
/// ELEMENT spelling `["k"]`: tsc's `getDiscriminantPropertyAccess` asks
/// `getAccessedPropertyName`, which reads a string-literal element access as
/// the same property name (`switch (s['kind'])` discriminates exactly as
/// `switch (s.kind)` does). An optional read short-circuits to `undefined`
/// when the base is nullish, which is what the discriminant filter then
/// removes on the asserting branch (the caller finishes the job with
/// `narrowByOptChainContainment`, since a member with no `k` at all is kept
/// by the filter). The reference's depth is likewise irrelevant: the union
/// being filtered is the reference's own type whether it is a root symbol
/// (`x?.k`) or a member path (`s.openDialog?.k`).
/// tsc's `isMatchingConstructorReference`: is `node` the access
/// `<ref>.constructor` (or its element spelling `<ref>["constructor"]`) where
/// `<ref>` is exactly `key`'s reference? Optional forms are excluded, as they
/// are in tsc.
fn constructorRefOf(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        .member_expr, .index_expr => {},
        else => return false,
    }
    const pe = (try pathElemOfAccess(c, node)) orelse return false;
    if (pe.isIndex()) return false;
    if (pe.atom() != try c.atom("constructor")) return false;
    return refMatches(c, c.tree.nodeData(node).lhs, key);
}

fn discriminantOfRef(c: *Checker, node: Node, key: RefKey) Error!?Atom {
    if (node == null_node) return null;
    // A binding-pattern pseudo-reference reads its discriminant through a
    // sibling BINDING, not a member access (see `narrowedPatternBinding`).
    if (isPatternRoot(key.sym)) return patternDiscriminantAtom(c, node, key);
    switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => {},
        .identifier => return aliasedDiscriminantAtom(c, node, key),
        else => return null,
    }
    const pe = (try pathElemOfAccess(c, node)) orelse return null;
    // A numeric or identifier-keyed element access names no property.
    if (pe.isIndex()) return null;
    if (!try refMatches(c, c.tree.nodeData(node).lhs, key)) return null;
    return pe.atom();
}

/// tsc's `getCandidateDiscriminantPropertyAccess`, IDENTIFIER arm: a `const`
/// that reads the reference's discriminant stands in for that read, so
///
///     const kind = obj.kind;      // or: const { kind } = obj;
///     if (kind === 'foo') obj.foo;
///
/// narrows `obj` exactly as `if (obj.kind === 'foo')` does. Both spellings
/// tsc accepts are here: an initializer that is an access expression on the
/// reference, and a default-less object-binding property of a pattern whose
/// initializer *is* the reference.
///
/// The alias must be a same-file `const` with a single declaration — the same
/// staleness rule `constAliasInit` documents, since the alias snapshots the
/// discriminant at its declaration point.
fn aliasedDiscriminantAtom(c: *Checker, node: Node, key: RefKey) Error!?Atom {
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    if (sym == key.sym or isPseudoRoot(sym) or c.isFreshTp(sym)) return null;
    const sf = c.symFlags(sym);
    if (!sf.const_decl or sf.exported) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return null;
    const decl = decls[0];
    const d = c.tree.nodeData(decl);
    const init_expr: Node = switch (c.nodeTag(decl)) {
        .declarator_init => d.rhs,
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            // An explicit annotation replaces the alias's snapshot with a
            // written type, which carries no discriminant information.
            if (e.type_ann != 0) return null;
            break :blk e.init;
        },
        else => return null,
    };
    if (init_expr == null_node) return null;
    // `const { kind } = obj` — the pattern's property name is the discriminant.
    if (objectPatternOf(c, decl)) |pat| {
        if (!try refMatches(c, init_expr, key)) return null;
        const el = (try bindingPropertyFor(c, pat, a)) orelse return null;
        return try c.memberAtom(c.tree.nodeMainToken(el));
    }
    // `const kind = obj.kind` — the initializer is the discriminant read.
    // Parenthesized to any depth: Angular's generated type-check blocks write
    // `const _t1 = (((((this).test)).type));`.
    if (c.nodeTag(d.lhs) != .identifier) return null;
    const access = c.referenceCandidate(init_expr);
    const pe = (try pathElemOfAccess(c, access)) orelse return null;
    if (pe.isIndex()) return null;
    if (!try refMatches(c, c.tree.nodeData(access).lhs, key)) return null;
    return pe.atom();
}

pub fn identIsSym(c: *Checker, node: Node, sym: SymbolId) Error!bool {
    if (node == null_node) return false;
    if (sym == this_flow_root) return c.nodeTag(node) == .this_expr;
    // A binding pattern is never itself written as an expression, so no
    // identifier ever *is* a pattern pseudo-root (its bindings are matched by
    // `discriminantOfRef` instead).
    if (isPatternRoot(sym)) return false;
    if (c.nodeTag(node) != .identifier) return false;
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    if (a != c.symNameAtom(sym)) return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s == sym,
        else => false,
    };
}

/// The type a destructuring *assignment* target gives to the element named
/// `name` (`[, width] = m`, `({ a: x } = o)`), or null when it cannot be
/// pinned down exactly. This is the cover-grammar mirror of
/// `findBindingType`, which only walks the declaration forms: an assignment
/// target is parsed as an array/object *literal*, with `object_property` /
/// `object_shorthand` / `spread_element` in place of the binding nodes.
/// Returning null keeps the caller's conservative "reset to declared".
fn destructuredAssignType(c: *Checker, pat: Node, name: Atom, whole: TypeId) Error!?TypeId {
    if (pat == null_node) return null;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .paren_expr => return destructuredAssignType(c, d.lhs, name, whole),
        .identifier => {
            if ((try c.atomOfToken(c.tree.nodeMainToken(pat))) != name) return null;
            return whole;
        },
        // `[a] = xs` inside a target is a default (`[a = 1] = xs`), which
        // strips `undefined` exactly as a binding default does.
        .assign, .binding_default => {
            const inner = (try destructuredAssignType(c, d.lhs, name, whole)) orelse return null;
            return try c.removeUndefined(inner);
        },
        .array_literal, .array_pattern => {
            const r = try c.resolveStructural(whole);
            // Every non-tuple position takes the iterated element type
            // (tsc's `checkIteratedTypeOrElementType`), which is how a
            // `RegExpMatchArray` — an interface over `Array<string>`, not an
            // `.array` — yields `string` per position.
            const iter: TypeId = if (c.ts.kind(r) == .tuple)
                types.no_type
            else
                (try c.iterationElementType(r)) orelse types.no_type;
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted) continue;
                var et: TypeId = iter;
                if (c.ts.kind(r) == .tuple and i < c.ts.tupleLen(r)) {
                    const te = c.ts.tupleElem(r, i);
                    et = if (te.optional() or te.rest())
                        try c.makeUnion2(te.ty, types.undefined_type)
                    else
                        te.ty;
                }
                if (et == types.no_type) continue;
                const tag = c.nodeTag(el);
                if (tag == .rest_element or tag == .spread_element) {
                    const rest = try c.ts.makeArray(et);
                    if (try destructuredAssignType(c, c.tree.nodeData(el).lhs, name, rest)) |v| return v;
                    continue;
                }
                if (try destructuredAssignType(c, el, name, et)) |v| return v;
            }
            return null;
        },
        .object_literal, .object_pattern => {
            const r = try c.resolveStructural(whole);
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    // `({ p: target } = o)` — key in main_token, target in rhs.
                    .object_property, .binding_property => {
                        const keyed = try c.memberAtom(c.tree.nodeMainToken(el));
                        const p = (try c.propOfType(r, keyed)) orelse continue;
                        const pt = if (p.optional())
                            try c.makeUnion2(p.ty, types.undefined_type)
                        else
                            p.ty;
                        const tgt = if (c.nodeTag(el) == .object_property) ed.rhs else ed.lhs;
                        if (try destructuredAssignType(c, tgt, name, pt)) |v| return v;
                    },
                    .object_shorthand => {
                        const keyed = try c.memberAtom(c.tree.nodeMainToken(el));
                        if (keyed != name) continue;
                        const p = (try c.propOfType(r, keyed)) orelse continue;
                        return if (p.optional())
                            try c.makeUnion2(p.ty, types.undefined_type)
                        else
                            p.ty;
                    },
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    }
}

fn patternBindsSym(c: *Checker, pat: Node, sym: SymbolId) Error!bool {
    if (pat == null_node) return false;
    // A pattern never binds `this`, nor another pattern's pseudo-root.
    if (isPseudoRoot(sym)) return false;
    switch (c.nodeTag(pat)) {
        .identifier => return (try c.atomOfToken(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym),
        .array_pattern, .object_pattern, .array_literal, .object_literal => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el != null_node and try patternBindsSym(c, el, sym)) return true;
            }
            return false;
        },
        // `object_property` is the *cover grammar* form (`({ p: a } = …)`):
        // main_token/lhs are the property KEY and rhs is the target. The
        // declaration form `binding_property` puts the target in lhs (0 when
        // shorthand), and `object_shorthand`'s lhs is the target identifier.
        .object_property, .binding_property_computed => return patternBindsSym(c, c.tree.nodeData(pat).rhs, sym),
        .binding_property, .object_shorthand => {
            const d = c.tree.nodeData(pat);
            if (d.lhs != 0) return patternBindsSym(c, d.lhs, sym);
            return (try c.memberAtom(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym);
        },
        .binding_default, .rest_element, .spread_element => {
            return patternBindsSym(c, c.tree.nodeData(pat).lhs, sym);
        },
        else => return false,
    }
}

fn varDeclBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
    const d = c.tree.nodeData(decl);
    if (c.nodeTag(decl) == .var_decl_one) {
        return declaratorBindsSym(c, d.lhs, sym);
    }
    for (c.tree.nodeRange(decl)) |dn| {
        if (dn != null_node and try declaratorBindsSym(c, dn, sym)) return true;
    }
    return false;
}

fn declaratorBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
    const d = c.tree.nodeData(decl);
    return switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full => patternBindsSym(c, d.lhs, sym),
        else => patternBindsSym(c, decl, sym),
    };
}

/// tsc's getAssignmentReducedType: keep declared-union constituents
/// the assigned type is assignable to.
///
/// "Assignable to" is tsc's `typeMaybeAssignableTo`, which for a UNION
/// source asks whether SOME constituent is assignable — not whether all of
/// them are. The difference decides whether a union survives its own
/// assignment: under the strict reading, writing `A | B` into a variable
/// declared `A | B` keeps only the constituents the WHOLE union fits, so a
/// variable initialized with `x || fallback` or `cond ? a : b` collapsed to
/// whichever arm happened to be a supertype of the other and lost the rest
/// — at the point of use, not at the expression.
///
/// The reduced union is only taken when the assigned type actually fits it
/// (tsc's closing `isTypeAssignableTo` guard) — under the loosened filter a
/// kept set can otherwise fail to admit the very value being written. The
/// guard is inert for a non-union assigned type, where "some" and "all"
/// agree and the kept set trivially admits it.
/// Subtype reduction for an evolving variable's flow join, with the
/// nullish constituents held out of it. `null`/`undefined` must survive:
/// ztsc's relation lets them satisfy an object whose properties are all
/// optional, so a plain `reduceSubtypes` would absorb the `null` that a
/// branch which assigns nothing still contributes.
fn reduceEvolvingJoin(c: *Checker, joined: TypeId) Error!TypeId {
    if (c.ts.kind(joined) != .union_type) return joined;
    var nullish: std.ArrayList(TypeId) = .empty;
    defer nullish.deinit(c.scratch());
    var rest: std.ArrayList(TypeId) = .empty;
    defer rest.deinit(c.scratch());
    for (try c.memberList(joined)) |m| {
        if (isNullishKind(c.ts.kind(m)))
            try nullish.append(c.scratch(), m)
        else
            try rest.append(c.scratch(), m);
    }
    if (nullish.items.len == 0) return c.reduceSubtypes(joined);
    if (rest.items.len == 0) return joined;
    const reduced = try c.reduceSubtypes(try c.ts.makeUnion(c.scratch(), rest.items));
    try nullish.append(c.scratch(), reduced);
    return c.ts.makeUnion(c.scratch(), nullish.items);
}

fn assignmentReduced(c: *Checker, declared: TypeId, assigned0: TypeId) Error!TypeId {
    const dk = c.ts.kind(declared);
    if (dk == .any or dk == .err or dk == .unknown) {
        if (dk == .unknown) return c.widenLiteral(assigned0);
        return declared;
    }
    const assigned = try c.ts.regular(try c.ts.regularLiteral(assigned0));
    if (dk != .union_type) return declared;
    if (assigned == declared) return declared;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(declared)) |m| {
        if (try c.maybeAssignable(assigned, m)) try parts.append(c.scratch(), m);
    }
    if (parts.items.len != 0) {
        const reduced = try c.ts.makeUnion(c.scratch(), parts.items);
        if (try c.isAssignable(assigned, reduced)) return reduced;
        return declared;
    }
    for (try c.memberList(declared)) |m| {
        if (try c.isComparable(assigned, m)) try parts.append(c.scratch(), m);
    }
    if (parts.items.len == 0) return declared;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// DECLARED type of a dotted path of plain names (`m.isA`, `this.a.b`),
/// resolved structurally: the root symbol's declared type followed by
/// property lookups. No expression is checked, no flow narrowing runs and
/// nothing is memoized, so this is safe to call from inside the flow walk
/// itself — where re-checking the expression would both re-enter an
/// in-progress flow query (a receiver transiently re-widened to its
/// declared type) and publish that transient answer into `node_types`.
///
/// Returns `no_type` for anything it cannot resolve exactly; the caller
/// treats that as "no information" (sound under-narrowing).
fn declaredPathType(c: *Checker, node: Node) Error!TypeId {
    c.side_query_depth += 1;
    defer c.side_query_depth -= 1;
    // A property lookup can materialize a generic instantiation and trip
    // the instantiation limit; whether it trips *here* rather than at the
    // authoritative check depends on what this checker already cached, so a
    // narrowing query must not be allowed to anchor a TS2589.
    const saved = c.suppress_inst_diag;
    defer c.suppress_inst_diag = saved;
    c.suppress_inst_diag = true;
    return declaredPathTypeInner(c, node);
}

/// tsc's `isDeclarationWithExplicitTypeAnnotation`, asked of every
/// declaration of a variable symbol: only such a symbol may be
/// materialized from inside a flow walk (see `declaredPathTypeInner`).
fn symExplicitlyTyped(c: *Checker, sym: SymbolId) bool {
    const f = c.symFlags(sym);
    if (!(f.var_decl or f.let_decl or f.const_decl)) return false;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var annotated = false;
    for (c.declsOf(sym)) |decl| {
        switch (c.nodeTag(decl)) {
            // `const x = <init>`: no annotation by construction.
            .declarator_init => return false,
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, c.tree.nodeData(decl).rhs);
                if (e.type_ann == 0) return false;
                annotated = true;
            },
            // The type-space half of a merge (`interface Array<T>` beside
            // `declare var Array: ArrayConstructor`) says nothing about
            // how the VALUE is typed.
            else => {},
        }
    }
    return annotated;
}

/// Does `sym` denote a NAMESPACE VALUE — a `namespace`/`module` declaration,
/// or an import binding that names a whole module (`import * as NS from "m"`,
/// and the re-exported `export * as NS` form)? tsc's `SymbolFlags.ValueModule`
/// after alias resolution; see the call site for why it is resolved outright.
fn symIsNamespaceValue(c: *Checker, sym: SymbolId) bool {
    const f = c.symFlags(sym);
    if (f.type_only) return false;
    if (f.namespace_decl) return true;
    if (!f.import_binding) return false;
    const tgt = c.importTarget(sym) orelse return false;
    return tgt.kind == .namespace or tgt.kind == .ambient_ns;
}

fn declaredPathTypeInner(c: *Checker, node: Node) Error!TypeId {
    switch (c.nodeTag(node)) {
        .paren_expr => return declaredPathTypeInner(c, c.tree.nodeData(node).lhs),
        .this_expr => return if (c.this_type != 0) c.this_type else types.no_type,
        .identifier => {
            const tok = c.tree.nodeMainToken(node);
            if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.no_type;
            const a = try c.atomOfToken(tok);
            return switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| blk: {
                    // Read-only: a narrowing query must not be what *starts*
                    // a symbol's materialization. Doing so pulls the work
                    // into the middle of the flow walk, where a dependency
                    // that is already in progress resolves to `any` — and
                    // that answer is then cached as the symbol's type for
                    // the rest of the run.
                    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) break :blk types.no_type;
                    if (c.sym_state.items[sym] == .computed) break :blk c.sym_types.items[sym];
                    if (c.sym_state.items[sym] == .in_progress) break :blk types.no_type;
                    // tsc's `getExplicitTypeOfSymbol` DOES resolve a
                    // variable whose declaration carries an explicit type
                    // ANNOTATION: reading an annotation costs no inference
                    // and cannot pull a function body into the flow walk.
                    // Refusing it made the answer depend on whether this
                    // checker happened to have materialized the symbol
                    // yet, which varies with how the files were
                    // partitioned — `Array.isArray(x)` narrowed at
                    // `--checkers=1` and silently did not at
                    // `--checkers=4`, because the lib's `declare var
                    // Array: ArrayConstructor` was still cold in the
                    // checker that owned the file.
                    // tsc's `getExplicitTypeOfSymbol` resolves a ValueModule
                    // outright, and so must this: a namespace object's type
                    // is a fact of the module graph, not an inference over a
                    // body, so reading it neither depends on nor disturbs any
                    // narrowing state — which is what the rule above guards.
                    //
                    // Without it the receiver of `NS.isFoo(x)` answered "no
                    // information" whenever this checker had not already
                    // materialized the namespace import, so the guard was
                    // dropped and nothing narrowed — order-dependently, since
                    // an already-`.computed` symbol short-circuits above.
                    // Every @atproto/api guard on social-app is written that
                    // way (`ChatBskyConvoDefs.isGroupConvo(prev.kind)`,
                    // `AppBskyEmbedRecord.isView(embed)`).
                    if (symIsNamespaceValue(c, sym)) break :blk try c.typeOfSymbol(sym);
                    if (!symExplicitlyTyped(c, sym)) break :blk types.no_type;
                    break :blk try c.typeOfSymbol(sym);
                },
                else => types.no_type,
            };
        },
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            const obj = try declaredPathTypeInner(c, d.lhs);
            if (obj == types.no_type) return types.no_type;
            const name = try c.memberAtom(d.rhs);
            const recv = try c.nonNullable(obj);
            // The identifier arm's rule, one level down: a property lookup
            // on a class whose own member table is mid-materialization
            // would *build* that table, so answer "no information" instead.
            if (try classSideOnCycle(c, recv, 0)) return types.no_type;
            const p = (try c.propOfType(recv, name)) orelse return types.no_type;
            return p.ty;
        },
        else => return types.no_type,
    }
}

/// Is `recv` a CLASS receiver — `typeof C` (the static side) or a `C`
/// instance — whose member table is *currently being materialized*?
///
/// `propOfType` on such a receiver runs `classStaticType` / `expandRef`,
/// computing every member's type. That is exactly what a narrowing query
/// must never do while the class is on the cycle: a sibling whose own
/// materialization is already on the stack answers `any` (`typeOfSymbol`'s
/// cycle break), and that `any` is then memoized as the *asking* member's
/// type for the rest of the run.
///
/// That is the circular-accessor defect. A static getter whose body narrows
/// a field it initializes (`if (!C._r) C._r = C.init(); return C._r;`) was
/// demanded from inside `init`'s own return-type inference, because the
/// effects-signature probe on an ordinary call statement in that body
/// (`C.reg.call(o);` → `guardCallOf` → `declaredPathType` → here) built
/// `typeof C`. With `init` in progress the assignment's right-hand side
/// reads as `any`, `assignmentReduced` keeps the DECLARED `… | undefined`,
/// and the getter caches that — a `possibly undefined` on every later read.
///
/// tsc never gets there: its equivalent probe (`getEffectsSignature` →
/// `getTypeOfDottedName`) resolves one property symbol, and the predicate
/// test it feeds (`hasTypePredicateOrNeverReturnType`) consults only an
/// *annotated* return type, so no inferred return is ever forced.
///
/// The answer here is the same shape as `refExpansionActive` /
/// `lazyRefProp`: off the cycle nothing changes (the caller's ordinary
/// `propOfType` runs, byte for byte as before); on it the query answers
/// `no_type`, "no information" — the sound under-narrowing it already
/// promises for everything it cannot resolve exactly.
fn classSideOnCycle(c: *Checker, recv: TypeId, depth: u32) Error!bool {
    if (depth >= lazy_base_depth) return false;
    const statics = switch (c.ts.kind(recv)) {
        .class_value => true,
        .ref => false,
        else => return false,
    };
    const cls = if (statics) c.ts.classSymbol(recv) else c.ts.refSymbol(recv);
    if (!c.symFlags(cls).class) return false;
    // The instance side marks its own in-progress table (`expandRef` and
    // `classInstanceGeneric` both park `no_type` there).
    if (!statics and c.refExpansionActive(recv)) return true;
    // Either side is also on the cycle when one of its member symbols is
    // mid-`typeOfSymbol` — which is how `classStaticType`'s loop, and every
    // demand that reaches a member directly, marks its progress.
    const saved_ctx = c.enterSymFile(cls);
    defer c.restoreCtx(saved_ctx);
    if (if (statics) c.bind.staticsScopeOf(c.localOf(cls)) else c.bind.membersScopeOf(c.localOf(cls))) |ms| {
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            const msym = c.toGlobal(c.bind.member_syms[i]);
            if (msym == binder.no_symbol or msym >= c.sym_types.items.len) continue;
            if (c.sym_state.items[msym] == .in_progress) return true;
        }
    }
    // Inherited members come from the base's table, so a base on the cycle
    // is this receiver on the cycle too.
    if (try c.baseClassSym(cls)) |base| {
        const base_recv = if (statics)
            try c.ts.makeClassValue(base)
        else
            try c.ts.makeRef(base, &.{});
        return classSideOnCycle(c, base_recv, depth + 1);
    }
    return false;
}

/// A resolved predicate call: the callee's predicate and the argument
/// expression sitting in the guarded parameter's position.
pub const GuardCall = struct { pred: types.Predicate, arg: Node };

/// If `call`'s callee is a predicate signature, return that predicate
/// together with the argument in the guarded parameter's position.
fn guardCallOf(c: *Checker, call: Node) Error!?GuardCall {
    const shape = c.callShape(call);
    // Obtain the callee's type for predicate inspection. When the callee is
    // a MEMBER/element access (`rule.abstract.startsWith`), re-checking it
    // here — a flow-narrowing side query — would re-evaluate its receiver;
    // if this query is a re-entrant walk of a loop back-edge triggered by
    // the very call statement/condition being checked (loop label still in
    // progress), the receiver is transiently re-widened to its declared
    // type, so the member access raises a spurious TS18048/2532 and caches a
    // poisoned type. So the memoized type is used when the callee has
    // already been checked top-down.
    //
    // An un-memoized member callee is not always that re-entrant state,
    // though: `inferReturnType` is a probe that checks a function's
    // `return` EXPRESSIONS directly, so in a function without a return
    // annotation `if (m.isA(e)) return e.av;` reaches here with `m.isA`
    // never checked — and the guard was silently dropped, which is what
    // made member-callee predicates look unsupported. Resolve the callee
    // structurally instead (`declaredPathType`): a type predicate is a
    // property of the declaration, so the declared type answers the
    // question, and the lookup neither narrows, checks nor memoizes.
    //
    // A plain NAME follows tsc's `getExplicitTypeOfSymbol`: a function,
    // class or namespace is resolved outright, but a *variable without a
    // type annotation* is not — computing it here would run its
    // initializer's inference from inside the flow walk. tsc gives up
    // entirely there; ztsc uses the answer when the symbol happens to be
    // resolved already (`declaredPathType`) and otherwise treats the call
    // as carrying no information. An unannotated `const f = (…) => {…}`
    // holding an *assertion* is not expressible anyway — `asserts x is T`
    // is a return-type annotation — so nothing is lost, while the arrow
    // body (which may reach back into a class whose members are mid-
    // materialization) is never checked at this point.
    const callee = shape.callee;
    const callee_t = switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.nodeType(callee) orelse
            try declaredPathType(c, callee),
        .identifier => if (calleeNeedsExplicitDecl(c, callee))
            c.nodeType(callee) orelse try declaredPathType(c, callee)
        else
            try c.checkExprCached(callee, types.no_type),
        else => try c.checkExprCached(callee, types.no_type),
    };
    if (callee_t == types.no_type) return null;
    const sig_t = (try effectsSignature(c, call, shape, callee_t)) orelse return null;
    if (!c.ts.fnHasPredicate(sig_t)) return null; // `never` return, no predicate
    const pred = c.ts.fnPredicate(sig_t);
    if (pred.param == types.Predicate.this_param) return null; // `this is T`: gap
    if (pred.param >= shape.arg_nodes.len) return null;
    const arg = shape.arg_nodes[pred.param];
    if (arg == null_node) return null;
    return .{ .pred = pred, .arg = arg };
}

/// The signature this call resolves to, when it is one a FLOW NODE cares
/// about — a type predicate, or a `never` return. tsc's `getEffectsSignature`.
///
/// The callee's type is not a `.function` nearly as often as it looks. An
/// OVERLOAD SET is an `.overloads` type, and a callable declared through an
/// interface or an object type literal — `interface InvariantStatic { (v:
/// false, m: string): never; (v: any, m: string): asserts v }`, which is
/// `@types/invariant`'s exact shape and outline's most-used assertion — is an
/// `.object` carrying call signatures. Asking `fnHasPredicate` about either
/// answers "no" (it demands `kind == .function`), so every predicate declared
/// that way was invisible and neither `asserts x` nor `x is T` narrowed.
///
/// tsc reads the predicate off the call's RESOLVED signature, so:
///
///  * gather the callee's call signatures (`getSignaturesOfType`), and stop
///    at once unless one of them has a predicate or returns `never` — that
///    keeps the ordinary call, which is the overwhelming majority, at one
///    kind switch;
///  * a lone non-generic signature *is* the answer (tsc's first branch);
///  * otherwise re-run overload resolution — arity, then `argumentsMatch` —
///    exactly as `resolveSignatureCall` does, because WHICH overload wins
///    decides what the call means to the flow graph: `invariant(false, m)`
///    picks the `never` overload and `invariant(maybe, m)` the `asserts`
///    one. Taking the last signature of the set instead (what the `never`
///    probe used to do) reads `declare function v(v: any, m: string):
///    asserts v; declare function v(v: false, m: string): never;` as a call
///    that ends the flow, which cancels the assertion it just made. This
///    runs silently: every diagnostic and every instantiation charge it makes
///    inside the argument list is an artifact of a flow-side query, and the
///    real check of the call files its own.
fn effectsSignature(c: *Checker, call: Node, shape: CallShape, callee_t: TypeId) Error!?TypeId {
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    try collectCallSigs(c, callee_t, &sigs, 0);
    if (sigs.items.len == 0) return null;
    var any_effect = false;
    for (sigs.items) |s| {
        if (sigHasEffect(c, s)) {
            any_effect = true;
            break;
        }
    }
    if (!any_effect) return null;

    const saved_diags = c.diags.items.len;
    const saved_file = c.cur_file;
    const saved_inst_count = c.inst_count;
    const saved_inst_trip = c.inst_limit_tripped;
    defer {
        c.rollbackArgDiags(saved_diags, saved_file, shape.arg_nodes);
        c.inst_count = saved_inst_count;
        c.newBudgetWindow();
        c.inst_limit_tripped = saved_inst_trip;
    }

    var targs: std.ArrayList(TypeId) = .empty;
    defer targs.deinit(c.scratch());
    for (shape.targ_nodes) |tn| {
        if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
    }

    // A single signature: no choice to make, so the only work left is the
    // instantiation a GENERIC guard needs (`isMemberOf = <T extends string>
    // (coll: readonly T[], v: string): v is T` narrows to the INFERRED `T`,
    // not the naked type parameter).
    if (sigs.items.len == 1) {
        const sig = sigs.items[0];
        if (c.ts.fnTypeParams(sig).len == 0) return sig;
        const inst = try c.instantiateSigForCall(sig, targs.items, shape.arg_nodes, call, types.no_type);
        return if (sigHasEffect(c, inst)) inst else sig;
    }

    const nargs = countArgs(shape.arg_nodes);
    var fallback: ?TypeId = null;
    // tsc's `resolveCall` runs `chooseOverload` TWICE over a multi-candidate
    // set: first under the SUBTYPE relation, and only if nothing matched under
    // the ASSIGNABLE one. The single rule that separates the two here is that
    // `any` is a subtype of nothing but `any`/`unknown` while being assignable
    // to everything — and it decides `@types/invariant` outright.
    // `invariant(result, "…")` over an `any` argument matches
    // `(testValue: false, format: string): never` under assignability, so a
    // one-pass probe reads outline's most common assertion as a call that ENDS
    // the flow, and every narrowing after it (`authenticationParams.expiresIn`,
    // 40 statements later) is lost. Under the subtype relation `any` misses
    // `false`, the `asserts testValue` overload wins, and the assertion
    // narrows — which is what tsc reports.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        for (sigs.items) |sig| {
            if (targs.items.len > 0 and !c.sigTargArityOk(sig, targs.items.len)) continue;
            const inst = try c.instantiateSigForCall(sig, targs.items, shape.arg_nodes, call, types.no_type);
            if (nargs < try c.requiredParams(inst) or nargs > try c.paramTotal(inst)) continue;
            // The first arity-fitting candidate stands in for a call whose
            // arguments no overload accepts: tsc's failure path keeps a
            // candidate too, and a call that is already an error should not
            // also lose its narrowing.
            if (fallback == null) fallback = inst;
            if (pass == 0 and try anyArgMissesSubtype(c, inst, shape.arg_nodes)) continue;
            if (try c.argumentsMatch(inst, shape.arg_nodes)) {
                return if (sigHasEffect(c, inst)) inst else null;
            }
        }
    }
    const fb = fallback orelse return null;
    return if (sigHasEffect(c, fb)) fb else null;
}

/// The one place the subtype relation is stricter than the assignable one for
/// an overload probe: an `any` argument. `isSimpleTypeRelatedTo` short-circuits
/// on an `any` SOURCE for the assignable and comparable relations only, so
/// under subtyping `any` reaches a parameter typed `any`/`unknown` and nothing
/// else.
///
/// Only plain reference and literal arguments are examined — a context-
/// sensitive argument (an arrow, an object literal) has no type until a
/// candidate's parameter gives it one, and none of them is `any`-rooted on its
/// own, so leaving them out keeps this test free of the candidate-order
/// dependence that probing them would introduce.
fn anyArgMissesSubtype(c: *Checker, sig: TypeId, arg_nodes: []const Node) Error!bool {
    var ai: u32 = 0;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        defer ai += 1;
        switch (c.nodeTag(an)) {
            .identifier,
            .member_expr,
            .optional_member_expr,
            .index_expr,
            .optional_index_expr,
            .this_expr,
            .non_null,
            .paren_expr,
            => {},
            else => continue,
        }
        const at = try c.checkExprCached(an, types.no_type);
        switch (c.ts.kind(at)) {
            .any, .err => {},
            else => continue,
        }
        const pt = (try c.paramTypeAt(sig, ai)) orelse continue;
        switch (c.ts.kind(try c.resolveStructural(pt))) {
            .any, .unknown, .err => continue,
            else => return true,
        }
    }
    return false;
}

/// tsc's `hasTypePredicateOrNeverReturnType`: the two things a signature can
/// say to the flow graph.
fn sigHasEffect(c: *Checker, sig: TypeId) bool {
    if (c.ts.kind(sig) != .function) return false;
    return c.ts.fnHasPredicate(sig) or c.ts.kind(c.ts.fnReturn(sig)) == .never;
}

/// `getSignaturesOfType(type, Call)`: the call signatures a callee offers,
/// in declaration order. An intersection concatenates its members' lists,
/// same rule `checkCallExprInner` follows.
fn collectCallSigs(c: *Checker, t0: TypeId, out: *std.ArrayList(TypeId), depth: u32) Error!void {
    if (depth > 4) return;
    const t = try c.resolveStructural(t0);
    switch (c.ts.kind(t)) {
        .function => try out.append(c.scratch(), t),
        .overloads => for (try c.memberList(t)) |m| try out.append(c.scratch(), m),
        .object => for (0..c.ts.objectCallSigCount(t)) |i| {
            try out.append(c.scratch(), c.ts.objectCallSig(t, @intCast(i)));
        },
        .intersection => for (try c.memberList(t)) |m| try collectCallSigs(c, m, out, depth + 1),
        else => {},
    }
}

/// tsc's `isDeclarationWithExplicitTypeAnnotation`, asked the other way
/// round: does this plain-name callee resolve to a VARIABLE whose type
/// would have to be *inferred from an initializer*? That is the one case
/// `getExplicitTypeOfSymbol` refuses to resolve, because inferring it is
/// arbitrary work — including a function-body walk — pulled into the
/// middle of a flow walk.
///
/// ztsc keeps one case tsc gives up on, because it costs nothing and the
/// app relies on it: an unannotated `const isX = (n): n is T => …`. The
/// predicate a guard probe is looking for *is* a return-type annotation,
/// so a declaration that carries one can be resolved without inferring
/// anything, and a declaration that carries none has no predicate to
/// find — resolving it could only cost a body walk.
fn calleeNeedsExplicitDecl(c: *Checker, callee: Node) bool {
    const tok = c.tree.nodeMainToken(callee);
    const a = c.atomOfToken(tok) catch return false;
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return false,
    };
    if (sym == binder.no_symbol) return false;
    const f = c.symFlags(sym);
    if (!(f.var_decl or f.let_decl or f.const_decl)) return false;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .declarator_init => {
                // `const x = <init>` — no annotation by construction.
                if (d.rhs != 0 and initReturnsPredicate(c, d.rhs)) return false;
            },
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (e.type_ann != 0) return false; // annotated: resolve it
                if (e.init != 0 and initReturnsPredicate(c, e.init)) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Is `init` a function/arrow literal whose RETURN TYPE ANNOTATION is a
/// type predicate (`x is T` / `asserts x is T`)? The only initializer
/// shape a guard probe can learn anything from without inferring.
fn initReturnsPredicate(c: *Checker, init_node: Node) bool {
    switch (c.nodeTag(init_node)) {
        .arrow_fn, .function_expr => {},
        else => return false,
    }
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(init_node).lhs);
    if (proto.return_type == 0) return false;
    return c.nodeTag(proto.return_type) == .type_predicate;
}

/// `if (isT(x))` — a user-defined type guard used in a condition.
/// True branch narrows the argument to the predicate type; the false
/// branch takes the complement (union filtering handles both).
fn narrowByGuardCall(c: *Checker, t: TypeId, call: Node, sense: bool, key: RefKey) Error!TypeId {
    const g = (try guardCallOf(c, call)) orelse return t;
    if (!try refMatches(c, g.arg, key)) return narrowByGuardArgChain(c, t, g, sense, key);
    const pred = g.pred;
    if (pred.asserts) return t; // assertion fns narrow after the call, not here
    if (pred.ty == types.no_type) return t;
    return narrowByInstance(c, t, pred.ty, sense, false);
}

/// tsc's `narrowTypeByTypePredicate` optional-chain arm: the guarded
/// ARGUMENT is an optional chain whose receiver is the tracked reference
/// (`Array.isArray(data?.detail)`). A nullish receiver short-circuits the
/// chain to `undefined`, so when the predicate's asserted type cannot BE
/// `undefined`, the asserting branch proves the receiver did not
/// short-circuit — narrow it to non-null. Only the true branch says
/// anything (a failed predicate is equally consistent with a nullish
/// receiver), which is why tsc gates this on `assumeTrue`.
fn narrowByGuardArgChain(c: *Checker, t: TypeId, g: GuardCall, sense: bool, key: RefKey) Error!TypeId {
    if (!sense) return t;
    if (g.pred.asserts) return t; // narrows after the call, not in the condition
    if (g.pred.ty == types.no_type) return t;
    if (try c.admitsNullish(g.pred.ty, .undefined)) return t;
    if (!try optionalChainContainsRef(c, g.arg, key)) return t;
    return c.nonNullable(t);
}

/// `assertIsT(x);` — an assertion-function call statement narrows the
/// argument to the asserted type for the rest of the flow; a bare
/// `asserts cond` narrows by truthiness.
fn narrowByAssertCall(c: *Checker, t: TypeId, call: Node, key: RefKey, decl: TypeId) Error!TypeId {
    const g = (try guardCallOf(c, call)) orelse return t;
    if (!g.pred.asserts) return t; // plain guards don't narrow as statements
    if (g.pred.ty == types.no_type) {
        // `asserts cond` (no `is T`): tsc's `narrowTypeByAssertion` hands
        // the ARGUMENT EXPRESSION to the condition narrower with
        // `assumeTrue`, so `invariant(x !== null)` / `assert(typeof v ===
        // "string")` narrows through the operator. Requiring the tracked
        // reference to *be* the argument only ever caught the degenerate
        // `assert(x)` — which the same call still handles, via the
        // identifier arm's truthiness narrowing.
        return c.narrowByCondition(t, g.arg, true, key, decl);
    }
    // `asserts x is T` names its subject positionally: it must be the arg.
    if (!try refMatches(c, g.arg, key)) return t;
    return narrowByInstance(c, t, g.pred.ty, true, false);
}

fn narrowBySwitchClause(c: *Checker, t: TypeId, clause: Node, key: RefKey, decl: TypeId) Error!TypeId {
    if (clause == null_node) return t;
    // Find the owning switch statement's discriminant: clause nodes
    // don't back-reference it, so scan: the discriminant condition
    // narrows only when it's the reference or `ref.prop`.
    const sw = switchOfClause(c, clause) orelse return t;
    var disc = c.tree.nodeData(sw).lhs;
    while (disc != null_node and c.nodeTag(disc) == .paren_expr) disc = c.tree.nodeData(disc).lhs;
    const is_default = c.nodeTag(clause) == .default_clause;

    // `switch (true) { case <guard>: … }` — TS 5.3's switch-on-`true`
    // narrowing (tsc's `narrowTypeBySwitchOnTrue`). Each clause expression is
    // a CONDITION on the reference, not a value to compare it against, so no
    // discriminant test applies.
    if (c.nodeTag(disc) == .true_literal) {
        return narrowBySwitchOnTrue(c, t, sw, clause, key, decl);
    }

    var prop: Atom = 0;
    var direct = false;
    if (try refMatches(c, disc, key)) {
        direct = true;
    } else if (try discriminantOfRef(c, disc, key)) |disc_prop| {
        prop = disc_prop;
    }
    if (!direct and prop == 0 and c.nodeTag(disc) == .prefix_unary and try typeofTargetOf(c, disc, key)) {
        // switch (typeof x)
        if (is_default) return t;
        const test_node = c.tree.nodeData(clause).lhs;
        const tt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
        if (c.ts.kind(tt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(tt), true);
        }
        return t;
    }
    if (!direct and prop == 0) return t;

    if (is_default) {
        // tsc's `narrowTypeBySwitchOnDiscriminant` narrows the DISCRIMINANT
        // type first and only then filters the constituents: when no
        // discriminant value survives the `case` labels the clause is
        // unreachable and the narrowed type is `never`. The per-member
        // subtraction below can only drop a member whose discriminant is a
        // single literal, so it leaves a member with a WIDE discriminant
        // (`type: "line" | "arrow"`) — and a naked type parameter
        // (`switch (t)` on `T extends "a" | "b"`) — alive in `default:`,
        // which is the false positive on every `assertNever(x)` idiom.
        if (try switchDefaultCovered(c, sw, t, prop, decl)) return types.never_type;
        // Exclude every case value.
        var cur = t;
        const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
        for (c.tree.extraRange(r.start, r.end)) |cl| {
            if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
            const test_node = c.tree.nodeData(cl).lhs;
            if (test_node == 0) continue;
            const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
            if (!c.ts.isLiteralLike(vt) and c.ts.kind(vt) != .null and c.ts.kind(vt) != .undefined) continue;
            cur = if (prop == 0)
                try c.narrowExcludeValue(cur, vt)
            else
                try narrowByDiscriminant(c, cur, prop, vt, false, decl);
        }
        return cur;
    }
    const test_node = c.tree.nodeData(clause).lhs;
    if (test_node == 0) return t;
    const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
    const is_lit = c.ts.isLiteralLike(vt) or c.ts.kind(vt) == .null or c.ts.kind(vt) == .undefined;
    if (!is_lit) return t;
    const narrowed = if (prop == 0)
        try c.narrowToValue(t, vt)
    else
        try narrowByDiscriminant(c, t, prop, vt, true, decl);
    // An OPTIONAL discriminant read (`switch (x?.k)`) short-circuits to
    // `undefined` when the receiver is nullish, so a `case` label that is not
    // itself nullish forces the receiver non-nullish on that clause — tsc's
    // optional-chain containment, which the `if (x?.k === lit)` path above
    // already applies. The discriminant filter alone keeps `undefined` (a
    // constituent with no `k` at all is conservatively kept), so a
    // `switch (payload?.reason)` left every `case` body reading `payload` as
    // possibly undefined. A switch compares with `===`, hence `strict`.
    //
    // Only the `case` clauses: `default:` is exactly where a short-circuited
    // chain lands, so the receiver stays nullable there.
    if (try optionalChainContainsRef(c, disc, key)) {
        return narrowByOptChainContainment(c, narrowed, test_node, true, true);
    }
    return narrowed;
}

/// tsc's `narrowTypeBySwitchOnTrue`: in `switch (true)` every `case`
/// expression is a condition, so a clause's own expression narrows with
/// `assumeTrue` and every clause that could have matched FIRST narrows with
/// `assumeFalse`. `default:` is reached only when nothing matched, so there
/// every case expression narrows false — including the ones written after it.
///
/// ztsc's binder gives each clause its own `switch_clause` flow node and joins
/// fallthrough separately, so a clause range (tsc's `clauseStart`/`clauseEnd`,
/// which exists to model a fallthrough group) is exactly one clause here.
fn narrowBySwitchOnTrue(c: *Checker, t0: TypeId, sw: Node, clause: Node, key: RefKey, decl: TypeId) Error!TypeId {
    var t = t0;
    const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
    const clauses = c.tree.extraRange(r.start, r.end);
    var past = false;
    const is_default = c.nodeTag(clause) == .default_clause;
    for (clauses) |cl| {
        if (cl == clause) {
            past = true;
            continue;
        }
        // A clause AFTER this one only constrains the `default:` edge.
        if (past and !is_default) break;
        if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
        const test_node = c.tree.nodeData(cl).lhs;
        if (test_node == 0) continue;
        t = try c.narrowByCondition(t, test_node, false, key, decl);
    }
    if (is_default) return t;
    const own = c.tree.nodeData(clause).lhs;
    if (own == 0) return t;
    return c.narrowByCondition(t, own, true, key, decl);
}

/// Every value the discriminant can take is covered by a `case` label, so
/// the `default:` clause is unreachable (tsc's `narrowTypeBySwitchOnDiscriminant`
/// reduces the discriminant to `never` there). `prop == 0` means the switch
/// is on the reference itself, otherwise on `ref.prop`.
///
/// Answers `false` for anything it cannot decide exactly — a case label
/// that is not a unit value, a member without the discriminant property, a
/// non-literal discriminant — so the caller falls back to the per-member
/// subtraction, which is sound but coarser.
fn switchDefaultCovered(c: *Checker, sw: Node, t0: TypeId, prop: Atom, decl0: TypeId) Error!bool {
    // Same deferred-alias unwrap the equality path needs (`unionFacet`):
    // `switch (r.media.type)` on a recursive alias must see the union it
    // stands for, or exhaustiveness is judged over a one-member list.
    const t = try unionFacet(c, t0);
    const decl = try unionFacet(c, decl0);
    // Discriminant-based exhaustiveness needs an actual discriminated union,
    // for the same reason `narrowByDiscriminant` does — tsc reaches
    // `narrowTypeBySwitchOnDiscriminantProperty` only through
    // `getDiscriminantPropertyAccess`. Switching on the reference ITSELF
    // (`prop == 0`) is plain equality narrowing and applies to any type.
    if (prop != 0) {
        const over = if (c.ts.kind(decl) == .union_type) decl else t;
        if (!try c.isDiscriminantProp(over, prop)) return false;
    }
    var vals: std.ArrayList(TypeId) = .empty;
    defer vals.deinit(c.scratch());
    const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
    for (c.tree.extraRange(r.start, r.end)) |cl| {
        if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
        const test_node = c.tree.nodeData(cl).lhs;
        if (test_node == 0) continue;
        const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
        if (!c.ts.isLiteralLike(vt) and c.ts.kind(vt) != .null and c.ts.kind(vt) != .undefined)
            return false;
        try vals.append(c.scratch(), vt);
    }
    if (vals.items.len == 0) return false;
    const single = [_]TypeId{t};
    const members: []const TypeId = if (c.ts.kind(t) == .union_type)
        try c.memberList(t)
    else
        &single;
    if (members.len == 0) return false;
    for (members) |m| {
        var d = m;
        if (prop != 0) {
            const rm = try c.resolveStructural(m);
            const p = (try c.propOfType(rm, prop)) orelse return false;
            if (p.optional()) return false;
            d = p.ty;
        }
        if (!try discriminantCovered(c, d, vals.items, 0)) return false;
    }
    return true;
}

/// Every value of the discriminant type `d0` is one of `vals`.
fn discriminantCovered(c: *Checker, d0: TypeId, vals: []const TypeId, depth: u32) Error!bool {
    if (depth > 4) return false;
    var d = try c.resolveStructural(d0);
    // A naked type parameter stands for its constraint: tsc substitutes
    // constraints for a narrowable reference before the flow walk, which is
    // what makes `switch (t)` over `T extends "a" | "b"` exhaustive.
    if (c.ts.kind(d) == .type_param) d = try c.resolveStructural(try c.baseConstraintOf(d));
    switch (c.ts.kind(d)) {
        // Every constituent must be covered.
        .union_type => {
            for (try c.memberList(d)) |dm| {
                if (!try discriminantCovered(c, dm, vals, depth + 1)) return false;
            }
            return true;
        },
        // An intersection's value satisfies every constituent, so one
        // covered constituent covers the whole.
        .intersection => {
            for (try c.memberList(d)) |dm| {
                if (try discriminantCovered(c, dm, vals, depth + 1)) return true;
            }
            return false;
        },
        else => {},
    }
    const dv = try c.ts.regularLiteral(d);
    if (!c.ts.isLiteralLike(dv) and c.ts.kind(dv) != .null and c.ts.kind(dv) != .undefined)
        return false;
    for (vals) |v| {
        if (dv == v) return true;
    }
    return false;
}

/// The switch statement owning a case/default clause (linear scan of
/// switch nodes; cached would be overkill for the subset).
fn switchOfClause(c: *Checker, clause: Node) ?Node {
    // Clause nodes are created right after their tests and before the
    // switch node itself; scan forward from the clause for a switch
    // whose clause range contains it.
    var n: Node = clause + 1;
    const total: Node = @intCast(c.tree.nodes.len);
    while (n < total) : (n += 1) {
        if (c.nodeTag(n) != .switch_stmt) continue;
        const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(n).rhs);
        for (c.tree.extraRange(r.start, r.end)) |cl| {
            if (cl == clause) return n;
        }
    }
    return null;
}

// --- definite assignment (TS2454) ------------------------------------

pub fn definitelyAssigned(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
    if (flow == binder.no_flow or flow == binder.unreachable_flow) return true;
    const key = (@as(u64, flow) << 32) | sym;
    if (c.da_cache.get(key)) |v| {
        if (v == 2) return true; // optimistic on loops
        return v == 1;
    }
    try c.da_cache.put(c.cm(), key, 2);
    const result = try definitelyAssignedInner(c, flow, sym);
    try c.da_cache.put(c.cm(), key, @intFromBool(result));
    return result;
}

fn definitelyAssignedInner(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none => return true,
        .unreachable_ => return true,
        .start => return false,
        .assign => {
            const target = b.flowNode(flow);
            if (try assignTargetsSymForDa(c, target, sym)) return true;
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .cond_true, .cond_false, .switch_clause, .call_stmt => {
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .switch_no_match => {
            // The "no clause matched" edge out of a `default`-less switch.
            // When the switch is exhaustive over a literal-union
            // discriminant the edge is unreachable, so it constrains
            // nothing — a `let x: number` assigned in every clause is
            // definitely assigned afterwards, exactly as tsc sees it.
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            if (c.switchIsExhaustive(b.flowNode(flow))) return true;
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .branch_label, .loop_label => {
            for (b.flowAntecedents(flow)) |a| {
                if (!try c.definitelyAssigned(a, sym)) return false;
            }
            return true;
        },
    }
}

fn assignTargetsSymForDa(c: *Checker, target: Node, sym: SymbolId) Error!bool {
    if (target == null_node) return false;
    switch (c.nodeTag(target)) {
        .declarator_init => return patternBindsSym(c, c.tree.nodeData(target).lhs, sym),
        .declarator_full => {
            const d = c.tree.nodeData(target);
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.init == 0) return false;
            return patternBindsSym(c, d.lhs, sym);
        },
        .assign => {
            const d = c.tree.nodeData(target);
            // A COMPOUND write reads before it writes and does not
            // initialize: tsc's `getTypeAtFlowAssignment` hands its compound
            // arm the (base-widened) type from BEFORE the write, so
            // `let x: number; x **= 1; x;` reports TS2454 at BOTH uses. `=`,
            // `||=` and `??=` do initialize — see `definiteAssignOp`.
            if (!definiteAssignOp(c.tree.tokens.tag(c.tree.nodeMainToken(target)))) return false;
            return patternBindsSym(c, d.lhs, sym);
        },
        // `x++` / `--x` is compound in exactly the same sense.
        .prefix_unary, .postfix_unary => return false,
        .var_decl_one, .var_decl => return varDeclBindsSym(c, target, sym),
        else => return patternBindsSym(c, target, sym),
    }
}
