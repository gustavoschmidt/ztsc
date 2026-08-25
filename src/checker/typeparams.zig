//! Type parameters: reading a generic's parameter list off its declarations,
//! pairing that list with a written argument list, and judging the arguments
//! against their constraints.
//!
//! Three layers, in dependency order:
//!
//!   * the LIST — `typeParamsOf` folds a merged or reopened symbol's several
//!     declaration blocks into one positional parameter list (arity and
//!     constraints from the first block that declares one, defaults pooled
//!     across every block, a class's symbols canonicalized onto the class
//!     block);
//!   * the MAP — `buildInstMap` sends every block's i-th parameter symbol to
//!     the i-th argument, and `fixTypeArgs` checks arity and materializes the
//!     defaults (TS2314 / TS2315 / TS2707);
//!   * the GATE — TS2344, "type argument does not satisfy its constraint".
//!     It is queued at every site that WRITES a type-argument list and drained
//!     once every owned file has been checked (`drainTypeArgConstraints`), so
//!     no member table is still materializing when a verdict is formed, and it
//!     stays silent on anything that is not a decided set (`undecidableType`,
//!     `decidableConstraintSet`) — a negative check whose whole cost is false
//!     positives.
//!
//! typenode.zig re-exports this file's public surface, so `checker.zig`'s
//! method aliases and other modules' direct imports keep resolving there.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TpMap = @import("enums.zig").TpMap;
const elaborate = @import("elaborate.zig");

/// One type parameter of a generic declaration, as written: its symbol and
/// the (unconverted) nodes of its `extends` clause and default. The nodes are
/// read against the declaring block's own file and scope, which is why the
/// donating symbol travels with the default.
pub const TypeParamInfo = struct {
    sym: SymbolId,
    constraint: Node,
    default: Node,
    /// The type-parameter symbol whose declaration owns `default`. Normally
    /// `sym`, but a merged declaration may supply the default from a block
    /// OTHER than the one the parameter list was taken from (see
    /// `typeParamsOf`), and the default is a NODE — it has to be read
    /// against the tree and scope of the block that wrote it.
    default_sym: SymbolId = 0,
};

/// Type parameters of a generic symbol (class/interface/alias). Symbol ids
/// in the result are global.
///
/// A reopened or cross-file-merged interface may declare its type
/// parameters on any one of its blocks: tsc collects the parameter list
/// across *every* declaration, and a block that omits the list entirely is
/// legal whenever each parameter has a default (`areTypeParametersIdentical`
/// compares against the *minimum* argument count). `@types/node` relies on
/// exactly that — `interface Buffer<TArrayBuffer extends ArrayBufferLike =
/// ArrayBufferLike> extends Uint8Array<TArrayBuffer>` in one file, a bare
/// `interface Buffer { … }` reopen in another. So scan the constituents in
/// declaration order and take the first block that actually declares
/// parameters; a bare reopen must not erase them.
///
/// DEFAULTS, though, are pooled across every block. tsc reads a parameter's
/// default off its own symbol, whose declarations merge with the interface's,
/// so a parameter is optional as soon as ANY block gives it one — order does
/// not matter. `@types/node` depends on it: `compatibility/iterators.d.ts`
/// reopens `NodeJS.AsyncIterator<T, TReturn, TNext>` with no defaults while
/// `globals.d.ts` writes `<T, TReturn = undefined, TNext = any>`. Taking the
/// bare block's list alone made `NodeJS.AsyncIterator<any>` a TS2314 arity
/// error, which degrades to `any` — so `Readable`'s
/// `[Symbol.asyncIterator](): NodeJS.AsyncIterator<any>` returned `any`, and
/// `for await (… of readable)` reported TS2504 for want of an async iterator.
///
/// `buf` is an out-parameter with two contracts, and every caller passes an
/// EMPTY list because of them. The parameter list is APPENDED to it, and the
/// declaration scan stops at the first block that leaves `buf` non-empty — so
/// entries already in it end the scan before it starts. Whatever `buf` holds
/// when the scan finishes then has its `default_sym` REWRITTEN to that entry's
/// own `sym`, pre-existing entries included, before the merged-default pass
/// (which may replace some of them again) runs.
pub fn typeParamsOf(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    outer: for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            try c.declTypeParams(decl, buf);
            if (buf.items.len > 0) break :outer;
        }
    }
    if (buf.items.len == 0) return;
    for (buf.items) |*tp| tp.default_sym = tp.sym;
    try fillMergedTypeParamDefaults(c, sym, buf);
    if (c.symFlags(sym).class) try c.canonicalizeClassTypeParams(sym, buf);
}

/// Fill a parameter's missing default from a LATER declaring block of the
/// same merged symbol, positionally (see `typeParamsOf`). Arity, constraints
/// and parameter symbols stay with the block the list came from; only a
/// default the list is missing is adopted, and it carries the donating
/// block's symbol so the node is read against the right file and scope.
/// Nothing to do once every parameter already has one.
fn fillMergedTypeParamDefaults(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    var missing = false;
    for (buf.items) |tp| {
        if (tp.default == 0) missing = true;
    }
    if (!missing) return;
    var other: std.ArrayList(TypeParamInfo) = .empty;
    defer other.deinit(c.scratch());
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            other.clearRetainingCapacity();
            try c.declTypeParams(decl, &other);
            if (other.items.len != buf.items.len) continue;
            var still_missing = false;
            for (buf.items, other.items) |*tp, od| {
                if (tp.default != 0) continue;
                if (od.default == 0) {
                    still_missing = true;
                    continue;
                }
                tp.default = od.default;
                tp.default_sym = od.sym;
            }
            if (!still_missing) return;
        }
    }
}

/// A class merged with a same-named `interface` has TWO declaring blocks,
/// each binding its own type-parameter symbols; tsc unifies them by POSITION
/// (`interface P<A> { x: A }` beside `class P<A> { y: A }` — `P<number>`
/// types both members `number`). `buildInstMap` already substitutes every
/// block's i-th parameter, so an instantiation with real arguments is fine
/// either way; what is not fine is the SELF reference — the class's own
/// `this` instance `P<A>`, whose arguments are these symbols. The
/// `implements`/`extends` clauses written on the class body resolve their
/// `A` in the CLASS's scope, so unless the self reference uses the class
/// block's symbols too, `class P<A> implements R<A>` compares `R<class A>`
/// against an instance whose every member reads `R<interface A>` and fails
/// (drizzle's `PgRaw`, `SQLiteRaw` and `Column`, whose interface halves are
/// written first).
///
/// Only the SYMBOLS are canonicalized. Arity, constraints and defaults stay
/// with the first declaring block, which is what tsc's declared type keeps:
/// `@types/react` writes `interface Component<P = {}, S = {}, SS = any>`
/// beside `class Component<P, S>`, and `Component<any>` is legal there only
/// because the three defaulted parameters win.
pub fn canonicalizeClassTypeParams(c: *Checker, sym: SymbolId, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            var syms: std.ArrayList(SymbolId) = .empty;
            defer syms.deinit(c.scratch());
            try c.typeParamSymsOfDecl(decl, &syms);
            if (syms.items.len == 0) return;
            for (syms.items, 0..) |s, i| {
                if (i >= buf.items.len) break;
                buf.items[i].sym = s;
            }
            return;
        }
    }
}

/// Type parameters declared by ONE declaration node, appended to `buf`,
/// resolved in the current file context. Non-generic (or non-declaring)
/// nodes append nothing.
pub fn declTypeParams(c: *Checker, decl: Node, buf: *std.ArrayList(TypeParamInfo)) Error!void {
    if (!isGenericDeclForm(c, decl)) return;
    // `writtenTypeParamRange` answers null for a non-generic declaration, which
    // bails before `scopeOf` — the expensive half, and pure overhead for the
    // common case.
    const tps = writtenTypeParamRange(c, decl) orelse return;
    const decl_scope = (try c.scopeOf(decl)) orelse return;
    for (tps) |tp| {
        if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
        const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
        const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
        const td = c.tree.nodeData(tp);
        try buf.append(c.scratch(), .{ .sym = c.toGlobal(tp_sym), .constraint = td.lhs, .default = td.rhs });
    }
}

/// The declaration forms whose type parameters belong to a generic SYMBOL —
/// the ones `typeParamsOf` and `buildInstMap` pair with a written argument
/// list. A function's or signature's own parameters are read off its
/// signature instead, so they are not these two readers' business even though
/// `writtenTypeParamRange` can see them.
fn isGenericDeclForm(c: *const Checker, decl: Node) bool {
    return switch (c.tree.nodeTag(decl)) {
        .class_decl, .interface_decl, .type_alias => true,
        else => false,
    };
}

/// The type-parameter list a node WRITES, as an extra-data range, or null
/// when it writes none. One switch over every syntactic holder of a
/// `<…>` list: the shared `FnProto` (functions, methods, arrows, function
/// and constructor types, call/construct/method signatures) plus the three
/// declaration forms that carry their own extra struct.
fn writtenTypeParamRange(c: *const Checker, node: Node) ?[]const Node {
    const d = c.tree.nodeData(node);
    const start, const end = switch (c.tree.nodeTag(node)) {
        .arrow_fn,
        .function_expr,
        .function_decl,
        .class_method,
        .function_type,
        .method_signature,
        .call_signature,
        .construct_signature,
        .constructor_type,
        => blk: {
            const p = c.tree.extraData(ast.FnProto, d.lhs);
            break :blk .{ p.tp_start, p.tp_end };
        },
        .class_decl => blk: {
            const e = c.tree.extraData(ast.ClassData, d.lhs);
            break :blk .{ e.tp_start, e.tp_end };
        },
        .interface_decl => blk: {
            const e = c.tree.extraData(ast.InterfaceData, d.lhs);
            break :blk .{ e.tp_start, e.tp_end };
        },
        .type_alias => blk: {
            const e = c.tree.extraData(ast.TypeAlias, d.lhs);
            break :blk .{ e.tp_start, e.tp_end };
        },
        else => return null,
    };
    if (start == end) return null;
    return c.tree.extraRange(start, end);
}

/// TS2744, "Type parameter defaults can only reference previously declared
/// type parameters" — tsc's `checkTypeParametersNotReferenced`, run for every
/// type-parameter list the current file writes.
///
/// ```ts
/// for (let i = 0; i < typeParameterDeclarations.length; i++) {
///     const node = typeParameterDeclarations[i];
///     if (node.default) checkTypeParametersNotReferenced(node.default, typeParameterDeclarations, i);
/// }
/// ```
///
/// The window is `[i, len)`, so a parameter's default may not name ITSELF
/// either (`<T = T>`) — the self-reference and the forward reference are one
/// rule, not two.
///
/// This is a walk of the file's NODES rather than of its statements because
/// the rule is about a declaration's syntax and nothing else: it must fire on
/// a declaration whose type is never demanded (`declare function f13<T = U, U
/// = B>(…)` with no call to it), and firing it lazily off `typeParamDefault`
/// instead would make the report a function of which checker partition
/// happened to materialize the declaration. It runs once per owned file, after
/// the statement walk — `seal` sorts the diagnostics back into position order.
///
/// The candidate list is the binder's SCOPE OWNERS, not the file's nodes.
/// Every syntactic holder of a `<…>` list — function, method, arrow, class,
/// interface, alias, and the call/construct/method signature forms — opens a
/// scope for the parameters to be resolved in, so `scope_owners` is a superset
/// of the declarations this check is about and is two orders of magnitude
/// shorter than `nodeCount`. (A node owning several scopes appears several
/// times; `diagFmt` dedupes on `(file, code, span-start)`, so a repeat is
/// free.)
pub fn checkFileTypeParamDefaults(c: *Checker) Error!void {
    for (c.prog.files[c.cur_file].bind.scope_owners, 0..) |node, s| {
        if (s == 0 or node == null_node) continue;
        const tps = writtenTypeParamRange(c, node) orelse continue;
        for (tps, 0..) |tp, i| {
            if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
            const def = c.tree.nodeData(tp).rhs;
            if (def == null_node) continue;
            try reportForwardDefaultRefs(c, def, tps[i..]);
        }
    }
}

/// TS2313, "Type parameter 'T' has a circular constraint" — tsc's
/// `getImmediateBaseConstraint`, which reports when resolving a parameter's
/// base constraint re-enters that same parameter:
///
/// ```ts
/// class C<T extends T> {}                 // T
/// class D<U extends T, T extends V, V extends T> {}   // T and V, NOT U
/// ```
///
/// The `D` line is the shape that pins the rule down. tsc's
/// `pushTypeResolution` finds the cycle at `T` and marks the resolution stack
/// FROM `T` ONWARDS as failed, so only the parameters actually ON the cycle
/// report; `U`, which merely leads into it, does not. The memo (`t.immediate
/// BaseConstraint`) then keeps each parameter to one report however many other
/// parameters walk through it.
///
/// Restricted here to the chain a constraint spelled as a BARE reference to a
/// sibling parameter makes — the only edge shape ztsc can read without
/// resolving the constraint's type, and the only one either witness needs.
/// A parameter reached through a type ARGUMENT is not on that chain, which is
/// tsc's answer too: `function foo<S extends Foo<S>>()` is clean, because
/// `Foo<S>`'s base constraint is the alias's own body and never asks `S` for
/// its constraint. Under-reads the type-level rule (`T extends U | V, U
/// extends T` is circular for tsc and silent here) and cannot over-read it.
///
/// Runs off the SYNTAX for the same reason TS2744 does — see
/// `checkFileTypeParamDefaults`, whose `scope_owners` walk this shares.
pub fn checkFileCircularConstraints(c: *Checker) Error!void {
    for (c.prog.files[c.cur_file].bind.scope_owners, 0..) |node, s| {
        if (s == 0 or node == null_node) continue;
        const tps = writtenTypeParamRange(c, node) orelse continue;
        try reportCircularConstraints(c, tps);
    }
}

/// One type-parameter list's worth of TS2313. Each parameter has at most ONE
/// outgoing edge (its constraint names at most one sibling), so the walk is a
/// chain rather than a search, and the three states are tsc's resolution stack:
/// unvisited, on the current chain, resolved.
fn reportCircularConstraints(c: *Checker, tps: []const Node) Error!void {
    const State = enum(u8) { unvisited, on_chain, done };
    const mark = c.scratch_arena.mark();
    defer c.scratch_arena.restore(mark);
    const state = try c.scratch().alloc(State, tps.len);
    const circular = try c.scratch().alloc(bool, tps.len);
    @memset(state, .unvisited);
    @memset(circular, false);
    var chain: std.ArrayList(usize) = .empty;
    for (0..tps.len) |start| {
        if (state[start] != .unvisited) continue;
        chain.clearRetainingCapacity();
        var cur = start;
        // The parameter the chain CLOSED on, if it closed at all. A chain that
        // simply runs out of edges, or that joins an already-resolved one, is
        // not a cycle — and neither is the last parameter on it.
        var closed_on: ?usize = null;
        while (true) {
            state[cur] = .on_chain;
            try chain.append(c.scratch(), cur);
            const next = (try constraintNamesSibling(c, tps, cur)) orelse break;
            if (state[next] == .done) break;
            if (state[next] == .on_chain) {
                closed_on = next;
                break;
            }
            cur = next;
        }
        // Every parameter from the closing point to the head of the chain is on
        // the cycle — tsc marks exactly that suffix of its resolution stack as
        // failed, which is why the parameters that merely LEAD INTO a cycle
        // stay silent.
        if (closed_on) |c0| {
            var k = chain.items.len;
            while (k > 0) {
                k -= 1;
                circular[chain.items[k]] = true;
                if (chain.items[k] == c0) break;
            }
        }
        for (chain.items) |i| {
            state[i] = .done;
            if (!circular[i]) continue;
            const con = c.tree.nodeData(tps[i]).lhs;
            try c.diagFmt(2313, c.nodeSpan(con), "Type parameter '{s}' has a circular constraint.", .{
                c.atomText(try c.atomOfToken(c.tree.nodeMainToken(tps[i]))),
            });
        }
    }
}

/// The index of the sibling parameter `tps[i]`'s constraint names outright, or
/// null when it has no constraint or the constraint is anything else.
fn constraintNamesSibling(c: *Checker, tps: []const Node, i: usize) Error!?usize {
    if (tps[i] == null_node or c.nodeTag(tps[i]) != .type_param) return null;
    const con = c.tree.nodeData(tps[i]).lhs;
    if (con == null_node) return null;
    // A bare reference IS the identifier — the parser only wraps one in a
    // `.type_ref` to hang a written type-argument list off it, and `Foo<…>`'s
    // base constraint is the referent's own, not the argument's. So the
    // identifier form is exactly the edge shape, and every other node kind
    // (`.type_ref`, `.qualified_name`, an operator, a literal) ends the chain.
    if (c.nodeTag(con) != .identifier) return null;
    return namedTypeParamRef(c, con, tps);
}

/// Report every reference inside `root` to one of the type parameters in
/// `window` (the defaulted parameter itself and everything after it).
///
/// The match is by NAME, and the shadow guard is the price of that: a nested
/// declaration that rebinds one of these names owns its whole subtree, so the
/// walk skips it rather than blaming a reference that resolves somewhere else.
/// Conservative in the safe direction — a skipped subtree can only cost a
/// report, never invent one.
fn reportForwardDefaultRefs(c: *Checker, root: Node, window: []const Node) Error!void {
    const mark = c.scratch_arena.mark();
    defer c.scratch_arena.restore(mark);
    var stack: std.ArrayList(Node) = .empty;
    try stack.append(c.scratch(), root);
    while (stack.pop()) |cur| {
        if (cur != root) if (writtenTypeParamRange(c, cur)) |inner| {
            if (try shadowsAny(c, inner, window)) continue;
        };
        // Two shapes hold identifiers that are not type references, and tsc's
        // `node.kind === SyntaxKind.TypeReference` test excludes both: the head
        // of a qualified name is a NAMESPACE, and the operand of `typeof` is a
        // VALUE (a `TypeQuery`, not a `TypeReference`). Neither subtree holds a
        // type node below it either, so both stop the walk.
        switch (c.nodeTag(cur)) {
            .qualified_name, .typeof_type => continue,
            else => {},
        }
        if (try namedTypeParamRef(c, cur, window) != null) {
            try c.diagFmt(2744, c.nodeSpan(cur), "Type parameter defaults can only reference previously declared type parameters.", .{});
        }
        var it = c.tree.childIterator(cur);
        while (it.next()) |child| try stack.append(c.scratch(), child);
    }
}

/// Does `inner` (a nested declaration's own parameter list) rebind any name in
/// `window`?
fn shadowsAny(c: *Checker, inner: []const Node, window: []const Node) Error!bool {
    for (inner) |itp| {
        if (itp == null_node or c.nodeTag(itp) != .type_param) continue;
        const ia = try c.atomOfToken(c.tree.nodeMainToken(itp));
        for (window) |wtp| {
            if (wtp == null_node or c.nodeTag(wtp) != .type_param) continue;
            if (ia == try c.atomOfToken(c.tree.nodeMainToken(wtp))) return true;
        }
    }
    return false;
}

/// The index in `window` this node names, if it is a bare (unqualified) type
/// reference to one of those parameters. A written type-argument list makes
/// the reference a `.type_ref` whose `lhs` is the name; without one the
/// reference IS the identifier. A qualified name (`N.T`) never resolves to a
/// type parameter, so only the plain-identifier head counts.
fn namedTypeParamRef(c: *Checker, node: Node, window: []const Node) Error!?usize {
    const name: Node = switch (c.nodeTag(node)) {
        .identifier => node,
        .type_ref => c.tree.nodeData(node).lhs,
        else => return null,
    };
    if (name == null_node or c.nodeTag(name) != .identifier) return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(name));
    for (window, 0..) |wtp, i| {
        if (wtp == null_node or c.nodeTag(wtp) != .type_param) continue;
        if (a == try c.atomOfToken(c.tree.nodeMainToken(wtp))) return i;
    }
    return null;
}

/// Type-parameter symbols of a single declaration node (class/interface/
/// alias), in positional order, resolved in the current file context.
/// Reopened interface blocks each bind a *distinct* type-param symbol for
/// the same positional name, so an instantiation must map all of them (see
/// `buildInstMap`).
pub fn typeParamSymsOfDecl(c: *Checker, decl: Node, buf: *std.ArrayList(SymbolId)) Error!void {
    if (!isGenericDeclForm(c, decl)) return;
    const tps = writtenTypeParamRange(c, decl) orelse return;
    const decl_scope = (try c.scopeOf(decl)) orelse return;
    for (tps) |tp| {
        if (tp == null_node or c.nodeTag(tp) != .type_param) continue;
        const a = try c.atomOfToken(c.tree.nodeMainToken(tp));
        const tp_sym = c.bind.lookupInScope(decl_scope, a) orelse continue;
        try buf.append(c.scratch(), c.toGlobal(tp_sym));
    }
}

/// Build the type-parameter → argument substitution map for instantiating
/// generic `sym` with `args`. A reopened interface (or a cross-file merged
/// interface) binds a distinct type-param symbol per declaration
/// block, but tsc unifies them by position — so every block's i-th
/// type-param symbol maps to `args[i]`. Missing args fall back to `any`.
pub fn buildInstMap(c: *Checker, sym: SymbolId, args: []const TypeId, out: *std.ArrayList(TpMap)) Error!void {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |csym| {
        const saved = c.enterSymFile(csym);
        defer c.restoreCtx(saved);
        for (c.declsOf(csym)) |decl| {
            var syms: std.ArrayList(SymbolId) = .empty;
            defer syms.deinit(c.scratch());
            try c.typeParamSymsOfDecl(decl, &syms);
            for (syms.items, 0..) |tp_sym, i| {
                const ty = if (i < args.len) args[i] else types.any_type;
                try out.append(c.scratch(), .{ .sym = tp_sym, .ty = ty });
            }
        }
    }
}

/// Does `sym` declare any type parameter with an `extends` clause? Memoized:
/// the answer is a property of the declaration, asked once per written type
/// reference, and `typeParamsOf` walks every declaration block to answer it.
pub fn symHasConstrainedTypeParam(c: *Checker, sym: SymbolId) Error!bool {
    if (c.tp_constrained_cache.get(sym)) |v| return v;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    var any = false;
    for (tps.items) |tp| {
        if (tp.constraint != 0) any = true;
    }
    try c.tp_constrained_cache.put(c.cm(), sym, any);
    return any;
}

/// Queue a written type-argument list for its TS2344 constraint check (see
/// `PendingTypeArgs` for why the check may not run here).
///
/// Only references in a file this checker OWNS are queued: a diagnostic for
/// any other file is discarded at `seal`, and the checker that owns it queues
/// the same reference itself. Each (file, node) is queued once.
///
/// `args` is the caller's resolved argument list, holes skipped — the same
/// pairing the drain rebuilds against `writtenTypeArgNodes(node)`, which is
/// read here rather than passed in so queue and drain cannot drift apart.
pub fn queueTypeArgConstraints(c: *Checker, node: Node, sym: SymbolId, args: []const TypeId) Error!void {
    // `args` holds one entry per non-hole argument node, so an empty `args`
    // is exactly the old "no arguments, or none written" test.
    if (args.len == 0) return;
    if (c.cur_file >= c.owned_mask.len or !c.owned_mask[c.cur_file]) return;
    const f = c.symFlags(sym);
    if (!f.interface and !f.class and !f.type_alias) return;
    const gop = try c.pending_type_args_seen.getOrPut(c.cm(), c.nodeKey(node));
    if (gop.found_existing) return;
    // Nothing to decide, nothing to keep: most generics constrain no
    // parameter at all (`Array<T>`, `Promise<T>`, every one-off `Wrap<T>`),
    // and queueing those would hold an entry and its arguments for the rest
    // of the run for a drain that would immediately skip them.
    if (!try c.symHasConstrainedTypeParam(sym)) return;
    try queuePendingTypeArgs(c, node, sym, 0, args);
}

/// Queue the written type-argument list of an explicit list on a CALL
/// (`f<Bad>(x)`, `h.get<Bad>(…)`) for the same TS2344 gate a type reference
/// gets — tsc runs one `checkTypeArguments` for every site that writes a list.
///
/// The constraints come off the SIGNATURE's own type parameters rather than a
/// generic symbol's, so the entry carries the signature; everything else (the
/// deferral to the drain, the admission tests, the pairing against the written
/// nodes) is shared with `queueTypeArgConstraints`.
pub fn queueSigTypeArgConstraints(c: *Checker, node: Node, sig: TypeId, args: []const TypeId) Error!void {
    if (args.len == 0) return;
    if (c.cur_file >= c.owned_mask.len or !c.owned_mask[c.cur_file]) return;
    const tps = c.ts.fnTypeParams(sig);
    if (tps.len == 0 or args.len > tps.len) return;
    const gop = try c.pending_type_args_seen.getOrPut(c.cm(), c.nodeKey(node));
    if (gop.found_existing) return;
    // Same "nothing to decide, nothing to keep" test as the symbol path: most
    // generic signatures constrain no parameter at all.
    {
        var any_constrained = false;
        for (tps[0..@min(tps.len, args.len)]) |tp| {
            if (try c.typeParamConstraint(tp) != types.no_type) {
                any_constrained = true;
                break;
            }
        }
        if (!any_constrained) return;
    }
    try queuePendingTypeArgs(c, node, binder.no_symbol, sig, args);
}

/// The part of the queue every written-list site shares: the last admission
/// test, and the entry itself.
fn queuePendingTypeArgs(c: *Checker, node: Node, sym: SymbolId, sig: TypeId, args: []const TypeId) Error!void {
    // Nothing to decide when no WRITTEN argument is a decided set:
    // `undecidableType` is a pure function of the argument's `TypeId`, so its
    // answer at the drain is the answer here, and a reference all of whose
    // arguments are still type variables or deferred nodes (zod's
    // `DeepPartial<T["shape"][k]>`, every `Foo<infer X>`) would only be
    // skipped later — after being kept alive for the whole run.
    const arg_nodes = writtenTypeArgNodes(c, node);
    {
        var any_decidable = false;
        for (args[0..@min(args.len, arg_nodes.len)], 0..) |a, i| {
            if (arg_nodes[i] == null_node) continue;
            if (a == types.any_type or a == types.unknown_type) continue;
            if (try c.undecidableType(a)) continue;
            any_decidable = true;
            break;
        }
        if (!any_decidable) return;
    }
    const args_start: u32 = @intCast(c.pending_type_args_pool.items.len);
    try c.pending_type_args_pool.appendSlice(c.cm(), args);
    try c.pending_type_args.append(c.cm(), .{
        .file = c.cur_file,
        .node = node,
        .sym = sym,
        .sig = sig,
        .this_type = c.this_type,
        .args_start = args_start,
        .args_len = @intCast(args.len),
    });
}

/// The WRITTEN type-argument nodes of one of the four nodes that can carry a
/// list, straight out of the tree. Immutable program data for the life of the
/// program, so the TS2344 queue keeps the node instead of a copy of this list.
///
/// A `type_ref` and a `heritage` clause both hold the list as a `SubRange` at
/// `rhs` — except that a heritage clause with no list at all writes `0` there,
/// which is not a valid extra index. A call/`new` with type arguments holds it
/// inside its `CallInfo`.
fn writtenTypeArgNodes(c: *const Checker, node: Node) []const Node {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .call_expr_targs, .new_expr_targs, .optional_call => {
            const info = c.tree.extraData(ast.CallInfo, d.rhs);
            return c.tree.extraRange(info.targs_start, info.targs_end);
        },
        else => {
            if (d.rhs == 0) return &.{};
            const r = c.tree.extraData(ast.SubRange, d.rhs);
            return c.tree.extraRange(r.start, r.end);
        },
    }
}

/// Run every queued TS2344 constraint check. Called once, after every
/// statement of every owned file has been checked, so no class member table
/// is still materializing.
pub fn drainTypeArgConstraints(c: *Checker) Error!void {
    const saved_file = c.cur_file;
    const saved_scope = c.cur_scope;
    const saved_this = c.this_type;
    defer {
        c.setFile(saved_file);
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
    }
    // Index-walked, and the entry's arguments are copied out before the check
    // runs: a check can convert a type node that queues a further reference,
    // which both appends to `pending_type_args` (walked by index for exactly
    // that reason) and can grow — and so move — the argument pool. One reused
    // scratch buffer, never longer than the widest written argument list.
    var args: std.ArrayList(TypeId) = .empty;
    defer args.deinit(c.scratch());
    var i: usize = 0;
    while (i < c.pending_type_args.items.len) : (i += 1) {
        const p = c.pending_type_args.items[i];
        c.setFile(p.file);
        c.cur_scope = binder.file_scope;
        c.this_type = p.this_type;
        const arg_nodes = writtenTypeArgNodes(c, p.node);
        args.clearRetainingCapacity();
        try args.appendSlice(c.scratch(), c.pending_type_args_pool.items[p.args_start..][0..p.args_len]);
        // Each queued reference is its own source element, exactly as it was
        // when the enclosing statement was walked: the instantiation budget
        // is scoped to one (tsc resets `instantiationCount` per
        // `checkSourceElement`), and the TS2589 anchor is this reference.
        // Without the reset the whole drain is one statement and the budget
        // trips on the accumulated total of every reference in the program.
        for (arg_nodes) |an| {
            if (an != null_node) {
                c.anchorInst(an);
                break;
            }
        }
        c.inst_count = 0;
        c.newBudgetWindow();
        const before = c.diags.items.len;
        if (p.sig != 0) {
            try checkSigTypeArgConstraints(c, p.sig, args.items, arg_nodes);
        } else {
            try c.checkTypeArgConstraints(p.sym, args.items, arg_nodes);
        }
        if (p.sig != 0 and c.diags.items.len != before) withdrawArgDiags(c, p.node);
    }
    c.pending_type_args.clearRetainingCapacity();
    c.pending_type_args_pool.clearRetainingCapacity();
}

/// The diagnostic codes the ARGUMENT relation of a call files. Everything else
/// an argument expression reports is its own — tsc types every argument
/// expression whether or not the call resolves — so only these are withdrawn by
/// `withdrawArgDiags`.
const arg_relation_codes = [_]u16{ 2322, 2345, 2353, 2559, 2739, 2740, 2741, 2769 };

/// tsc suppresses the whole ARGUMENT check of a call whose EXPLICIT type
/// arguments failed their constraints: `checkTypeArguments` rejects the
/// candidate before `getSignatureApplicabilityError` ever runs, the call
/// resolves through `resolveErrorCall`, and nothing in the argument list is
/// ever related to a parameter. `incorrectNumberOfTypeArgumentsDuringError
/// Reporting` is that shape — `fn<MyObjA>({a: {x, y}, b: {}})`, where `MyObjA`
/// fails `A extends ObjA` (TS2559) and tsc says nothing about the object
/// literal's `y`, while ztsc added a TS2353.
///
/// ztsc cannot honour that at the call site: the constraint verdict is DEFERRED
/// to the drain on purpose (see `PendingTypeArgs` — forming it eagerly asks a
/// class member table for a constraint while that table is still materializing),
/// and by then the argument diagnostics are filed. So the drain withdraws them
/// instead, which is the same suppression one step later.
///
/// `diag_seen` is unwound with the entries, exactly as `rollbackDiags` does:
/// leaving the key behind would suppress a later, legitimate report at the same
/// span. `inst_diag_at` holds INDICES into `diags`; any at or after the first
/// hole is dropped rather than remapped (see `rollbackDiags`, which takes the
/// same side).
fn withdrawArgDiags(c: *Checker, node: Node) void {
    switch (c.nodeTag(node)) {
        .call_expr_targs, .new_expr_targs, .optional_call => {},
        else => return,
    }
    const info = c.tree.extraData(ast.CallInfo, c.tree.nodeData(node).rhs);
    const arg_nodes = c.tree.extraRange(info.args_start, info.args_end);
    var first: Node = null_node;
    var last: Node = null_node;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        if (first == null_node) first = an;
        last = an;
    }
    if (first == null_node) return;
    const lo = c.nodeSpanStart(first);
    const hi = c.nodeSpan(last).end;
    var w: usize = 0;
    var first_hole: ?usize = null;
    for (c.diags.items, 0..) |d, i| {
        if (d.file == c.cur_file and d.span.start >= lo and d.span.start < hi and
            std.mem.indexOfScalar(u16, &arg_relation_codes, d.code) != null)
        {
            _ = c.diag_seen.remove((@as(u128, d.file) << 64) | (@as(u128, d.code) << 32) | d.span.start);
            if (first_hole == null) first_hole = i;
            continue;
        }
        c.diags.items[w] = d;
        w += 1;
    }
    if (first_hole == null) return;
    c.diags.items.len = w;
    while (c.inst_diag_at.count() > 0) {
        var stale: ?u64 = null;
        var it = c.inst_diag_at.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* >= first_hole.?) {
                stale = e.key_ptr.*;
                break;
            }
        }
        _ = c.inst_diag_at.remove(stale orelse break);
    }
}

/// TS2344 — every WRITTEN type argument of a type reference must satisfy its
/// type parameter's constraint (tsc's `checkTypeArgumentConstraints`).
///
/// The constraint is instantiated under the reference's OWN argument list, so
/// a constraint that mentions an earlier parameter is checked in the supplied
/// world: drizzle writes `MySqlSelectWithout<T, TDynamic, K extends keyof T &
/// string>`, and `K`'s constraint only means anything once `T` is the class's
/// polymorphic `this`.
///
/// Deliberately silent — this is a *negative* check whose whole cost is false
/// positives — whenever the verdict would be about ztsc's own resolution
/// rather than the code:
///
///   * a parameter with no WRITTEN argument — a defaulted tail, or a list
///     whose arity is already another check's diagnostic (TS2314/TS2707) and
///     whose positions therefore pair with the wrong parameters,
///   * `any` / `unknown` on either side, which admit everything,
///   * an argument that is not a decided set (`undecidableType`), or
///   * a constraint that is not a decided set (`decidableConstraintSet`).
///
/// The check runs once per written reference per checker (the queue dedupes
/// on `nodeKey`), so a generic used a thousand times is judged at each of its
/// use sites exactly once, and never at its declaration.
pub fn checkTypeArgConstraints(c: *Checker, sym: SymbolId, args: []const TypeId, arg_nodes: []const Node) Error!void {
    if (args.len == 0) return;
    const f = c.symFlags(sym);
    if (!f.interface and !f.class and !f.type_alias) return;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) return;
    // Arity is another check's business (TS2314/TS2707); a mismatched list
    // pairs arguments with the wrong parameters, so say nothing.
    if (args.len > tps.items.len) return;
    var min: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (args.len < min) return;
    // The mapper tsc builds: every parameter to its supplied argument, with
    // defaulted tail parameters left as themselves (their own instantiation
    // is `fixTypeArgs`'s job, and a constraint that leans on one is not
    // decidable here).
    var map_list: std.ArrayList(TpMap) = .empty;
    defer map_list.deinit(c.scratch());
    try c.buildInstMap(sym, args, &map_list);
    for (tps.items, 0..) |tp, i| {
        if (i >= args.len or i >= arg_nodes.len) break;
        if (tp.constraint == 0) continue;
        var con: TypeId = undefined;
        {
            const saved = c.enterSymFile(tp.sym);
            defer c.restoreCtx(saved);
            c.cur_scope = c.symScope(tp.sym);
            con = try c.typeFromTypeNode(tp.constraint);
        }
        try checkOneTypeArgConstraint(c, args[i], con, map_list.items, arg_nodes[i]);
    }
}

/// TS2344 for an explicit type-argument list written on a CALL, against the
/// SIGNATURE's own type parameters (tsc's `checkTypeArguments`, reached from
/// `resolveCall`). Same shape as `checkTypeArgConstraints` — see there for why
/// each silent case is silent — with two differences that follow from the
/// parameters being a signature's rather than a symbol's:
///
///   * the constraint is read off the parameter symbol (`typeParamConstraint`,
///     which also handles a FRESH higher-order parameter whose bound is
///     already a TypeId), not off a declaration node this list owns, and
///   * the mapper leaves an unwritten tail parameter as itself, exactly as
///     `buildInstMap` does for a defaulted tail.
///
/// tsc REJECTS a candidate whose type arguments fail, then reports this from
/// `candidateForTypeArgumentError`; the reported return type still comes from
/// the written arguments (`pickLongestCandidateSignature` →
/// `getTypeArgumentsFromNodes` only fills what was not written). ztsc reports
/// without rejecting, which is the same diagnostic and the same downstream
/// typing, and keeps the failure out of overload resolution.
pub fn checkSigTypeArgConstraints(c: *Checker, sig: TypeId, args: []const TypeId, arg_nodes: []const Node) Error!void {
    if (args.len == 0) return;
    if (c.ts.kind(sig) != .function) return;
    const tps = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
    defer c.scratch().free(tps);
    if (tps.len == 0) return;
    // Arity is another check's business (TS2558), and a mismatched list pairs
    // arguments with the wrong parameters, so say nothing.
    if (args.len > tps.len or args.len < c.sigMinTargs(tps)) return;
    const map = try c.scratch().alloc(TpMap, tps.len);
    defer c.scratch().free(map);
    for (tps, 0..) |tp, i| {
        map[i] = .{
            .sym = tp,
            .ty = if (i < args.len) args[i] else try c.ts.makeTypeParam(tp),
        };
    }
    for (tps, 0..) |tp, i| {
        if (i >= args.len or i >= arg_nodes.len) break;
        const con = try c.typeParamConstraint(tp);
        if (con == types.no_type) continue;
        try checkOneTypeArgConstraint(c, args[i], con, map, arg_nodes[i]);
    }
}

/// The TS2344 verdict for ONE written type argument against its parameter's
/// (not yet instantiated) constraint. Shared by every site that writes a
/// list — a type reference, both heritage clauses, and an explicit list on a
/// call — so all four report the same message, from the same tests, at the
/// argument's own span.
fn checkOneTypeArgConstraint(c: *Checker, arg: TypeId, con0: TypeId, map: []const TpMap, an: Node) Error!void {
    if (an == null_node) return;
    if (arg == types.any_type or arg == types.unknown_type) return;
    if (try c.undecidableType(arg)) return;
    // A class whose `extends` chain reaches a base ztsc could not resolve has
    // an INCOMPLETE member set by construction, so "does not satisfy" against
    // it is a verdict about the missing base, not about the code — the same
    // reason `checkClass` skips its `implements` clauses (`hasUnresolvedBase`).
    // `@types/node`'s `class ReadableBase extends Stream` reaches `Stream`
    // through an `import S = internal.Stream` entity alias, and every
    // `StreamOptions<Readable>`/`<Writable>` heritage clause was a false
    // "missing compose, pipe".
    if (c.ts.kind(arg) == .ref and c.symFlags(c.ts.refSymbol(arg)).class and
        try c.hasUnresolvedBase(c.ts.refSymbol(arg)))
    {
        return;
    }
    // A constraint WRITTEN in terms of `this` is undecidable here for the
    // same reason a `this` argument is (see `undecidableType`): its meaning
    // depends on the instantiating class, and a `this` operand keeps every
    // conditional over it deferred, so instantiating it under this
    // reference's arguments re-expands without ever reducing. Asked before
    // the instantiation, which is the part that ran away — the two residual
    // TS2589s on drizzle's `PgSelectQueryBuilderBase` / `SQLiteSelectBase`
    // heritage clauses were exactly this.
    if (try c.containsThisType(con0)) return;
    const con = try c.instantiate(con0, map);
    if (!try c.decidableConstraintSet(con)) return;
    if (try c.isAssignable(arg, con)) return;
    // tsc replaces the "does not satisfy" head with the specific
    // missing-property error whenever that is what went wrong
    // (`reportRelationError` → `getExactOptionalUnassignableProperties`
    // path): `Holder<{ s: string }>` against `T extends Shape` is
    // TS2741, not TS2344.
    if (try c.tryReportMissingProps(arg, con, c.nodeSpan(an))) return;
    // Same substitution for the WEAK-type headline, which tsc's relation
    // reports ahead of the structural walk and therefore ahead of any head
    // message the caller supplied: `test<{t?: string}, bigint>()` is TS2559
    // ("Type 'bigint' has no properties in common with type '{ t?: string; }'"),
    // not TS2344.
    if (try c.weakTypeMismatch(arg, con, c.ts.kind(arg), c.ts.kind(con), c.ts.objectIsFresh(arg))) {
        try c.diagFmt(2559, c.nodeSpan(an), "Type '{s}' has no properties in common with type '{s}'.", .{
            try c.typeToString(arg), try c.typeToString(con),
        });
        return;
    }
    // A constraint violation elaborates like any other failed relation
    // (`elaborate.zig`): the argument and the constraint are the pair, and
    // tsc chains the same derivation under this head as under TS2322.
    try c.diagFmt(2344, c.nodeSpan(an), "Type '{s}' does not satisfy the constraint '{s}'.{s}", .{
        try c.typeToString(arg),
        try c.typeToString(con),
        try elaborate.chainText(c, arg, con),
    });
}

/// Budget for the TS2344 gates' structural scans. Running out answers
/// "undecidable", which for a negative check is always the safe direction.
const constraint_scan_budget: u32 = 512;

/// May a "does not satisfy" verdict be built against `con` as a TARGET?
///
/// Two shapes qualify.
///
/// A PRIMITIVE OR LITERAL SET — a primitive, a literal, an enum member,
/// `never`, or a union/intersection of those. That is what TS2344 is
/// overwhelmingly about (`K extends keyof T & string`, `K extends "a" | "b"`,
/// `N extends number`), and it is the shape ztsc decides *exactly*: membership
/// in a key set is a set question, not a structural one.
///
/// A STRUCTURAL constraint — an object type, or a reference to an
/// interface/class/alias (`T extends Shape`, `T extends ZodType<any, any,
/// any>`) — which is decided by the relation. That used to be excluded on the
/// argument that "the answer is only as good as the relation", with zod's
/// `ZodNumber` against `ZodType<any, any, any>` as the standing counter-
/// example. Both halves of that example are now fixed and pinned: the variance
/// half by `measuredVarianceVerdict` (`assignability/078`), and the
/// growing-instantiation half — `ZodString` against `ZodType<string | number |
/// symbol, any, any>`, where the walk burnt the whole per-statement
/// instantiation budget and the truncation came back as a cached FALSE — by
/// the relation's deeply-nested guard (`max_relation_identity_repeats`,
/// `assignability/080`). With those closed, `bench/parity_sweep.sh` holds
/// 0 under / 0 excess on all eight packages with the structural arm ENABLED,
/// which is the evidence this gate was waiting for.
///
/// What stays out is anything still DEFERRED — a free type parameter, a
/// conditional, a `keyof`, an indexed access, a mapped type, a template
/// pattern. Those are not sets ztsc can enumerate on either side of the
/// relation, and they are what the caller's `undecidableType` guard is about.
///
/// The structural arm is not free: it is one full relation per written
/// reference, and on declaration corpora that write many nominal constraints
/// against large lib interfaces (`T extends HTMLElement` appears 119 times in
/// @types/react) it was the dominant new cost — that package's check phase
/// 10.3 → 21.0 ms when the arm landed. Most of it is back: the relation now
/// answers a derived type against a DECLARED base of itself without walking
/// members at all (`nominalHeritageRelated`), which took @types/react to
/// 11.1 ms and its peak RSS 24.3 → 22.1 MB. What is left is the constraints
/// the fast path cannot settle nominally — zod's `ZodString` against
/// `ZodType<string | number | symbol, any, any>`, a base instantiation whose
/// arguments neither match nor are `any`, which is a real structural
/// question and stays one (10.8 → 10.5 ms). Everything else was flat
/// throughout: e2e `multi` 0.03 s / 41 MB and excalidraw 0.20 s / 122 MB,
/// because an application writes far fewer such references than a `.d.ts`
/// package does.
pub fn decidableConstraintSet(c: *Checker, con: TypeId) Error!bool {
    const s = &c.ts;
    var budget: u32 = constraint_scan_budget;
    var stack: std.ArrayList(TypeId) = .empty;
    defer stack.deinit(c.scratch());
    try stack.append(c.scratch(), con);
    while (stack.pop()) |cur| {
        if (budget == 0) return false;
        budget -= 1;
        switch (s.kind(cur)) {
            // Structural: decided by the relation. `undecidableType` has
            // already refused anything still deferred inside it.
            .object, .ref => if (try c.undecidableType(cur)) return false,
            // A CALLABLE constraint — `T extends (...args: any) => any`,
            // `T extends () => void` — is structural in exactly the same
            // sense: signature compatibility is what the relation decides,
            // and it decides it correctly (`typeof C` against `(...args:
            // any) => any` is already the right TS2322 at an assignment).
            // Excluded before, only because the kind was absent from this
            // list, which silently skipped the whole `Parameters<…>` /
            // `ReturnType<…>` family.
            //
            // `undecidableType` treats a `.function` as an opaque leaf (it
            // is written for the ARGUMENT side, where descending into a
            // signature would judge every generic's own members), so the
            // deferral screen is applied to the signature's own parts here.
            // A constraint signature with its OWN type parameters
            // (`T extends <U>(x: U) => U`) is not a decided set: the
            // relation would have to infer, so it stays out.
            .function => {
                if (s.fnTypeParams(cur).len != 0) return false;
                if (try c.undecidableType(s.fnReturn(cur))) return false;
                for (0..s.fnParamCount(cur)) |i| {
                    if (try c.undecidableType(s.fnParam(cur, @intCast(i)).ty)) return false;
                }
            },
            .overloads => {
                for (0..s.memberCount(cur)) |i| try stack.append(c.scratch(), s.memberAt(cur, i));
            },
            .string,
            .number,
            .boolean,
            .bigint,
            .symbol,
            .object_keyword,
            .never,
            .null,
            .undefined,
            .void,
            .bool_true,
            .bool_false,
            .string_literal,
            .number_literal,
            .number_literal_fresh,
            .bigint_literal,
            .enum_type,
            .unique_symbol,
            => {},
            .union_type, .intersection => {
                for (0..s.memberCount(cur)) |i| try stack.append(c.scratch(), s.memberAt(cur, i));
            },
            else => return false,
        }
    }
    return true;
}

/// May a "does not satisfy" verdict be built on `t`?
///
/// No, whenever `t` still contains a type variable or a DEFERRED node — a
/// free type parameter, an `infer` binder, a mapped key, an unreduced
/// conditional / indexed access / `keyof` / template pattern / string
/// intrinsic. Such a type is not a set ztsc can enumerate: tsc decides those
/// through the constraint machinery of a full deferred relation, ztsc does
/// not, and every one of the 130+ false TS2344s the naive check invented on
/// the corpus was one of these (`infer Type`, `T["shape"][k]`,
/// `DeepPartial<…>` against `ZodType<any, any, any>`).
///
/// An object's own property types count: drizzle writes a type argument
/// `{ tableName: infer TTableName }` inside a conditional's `extends` clause,
/// and the members of a set whose contents are still being inferred are not a
/// decided set either. A `.ref` is followed through its ARGUMENTS only —
/// expanding it to look inside a class instance would report on the type
/// parameters every generic class mentions in its own members.
pub fn undecidableType(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    var budget: u32 = constraint_scan_budget;
    var seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer seen.deinit(c.scratch());
    var stack: std.ArrayList(TypeId) = .empty;
    defer stack.deinit(c.scratch());
    try stack.append(c.scratch(), t);
    while (stack.pop()) |cur| {
        if (budget == 0) return true;
        budget -= 1;
        if ((try seen.getOrPut(c.scratch(), cur)).found_existing) continue;
        switch (s.kind(cur)) {
            .err,
            .type_param,
            // A polymorphic `this` is a type VARIABLE — that is what
            // `typeFromTypeNode`'s `.this_expr` arm establishes — and belongs
            // beside `.type_param` for exactly the reason the doc comment
            // gives: whether `this` satisfies a bound is a question about the
            // class's own resolution, decided over a self-reference whose
            // parameters are still their own bounds, not about the code.
            // drizzle writes `NotNull<this>` / `$Type<this, T>` on nearly every
            // column-builder method, and judging those produced 45 false
            // TS2344s ("Type 'this' does not satisfy the constraint …") plus
            // two TS2589s from the scans they provoked.
            .this_type,
            .infer_var,
            .mapped_param,
            .conditional,
            .index_access,
            .keyof_op,
            .mapped,
            .template_literal_type,
            .string_mapping,
            => return true,
            // Indexed walks, not `memberList` dupes: interning during the
            // scan may move `extra` (see `Store.memberAt`).
            .union_type, .intersection, .overloads => {
                for (0..s.memberCount(cur)) |i| try stack.append(c.scratch(), s.memberAt(cur, i));
            },
            .array => try stack.append(c.scratch(), s.arrayElem(cur)),
            .tuple => for (0..s.tupleLen(cur)) |i| {
                try stack.append(c.scratch(), s.tupleElem(cur, @intCast(i)).ty);
            },
            .ref => for (0..s.refArgCount(cur)) |i| {
                try stack.append(c.scratch(), s.refArgAt(cur, i));
            },
            .object => {
                for (0..s.objectPropCount(cur)) |i| {
                    try stack.append(c.scratch(), s.objectProp(cur, @intCast(i)).ty);
                }
                if (s.objectStringIndex(cur) != 0) try stack.append(c.scratch(), s.objectStringIndex(cur));
                if (s.objectNumberIndex(cur) != 0) try stack.append(c.scratch(), s.objectNumberIndex(cur));
            },
            else => {},
        }
    }
    return false;
}

/// Check type-argument arity against a generic symbol and fill defaults.
/// Returns null (after TS2314/2558) on arity mismatch.
pub fn fixTypeArgs(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!?[]const TypeId {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (args.len == tps.items.len) return try c.scratch().dupe(TypeId, args);
    var min: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (args.len < min or args.len > tps.items.len) {
        if (tps.items.len == 0) {
            // Non-generic type applied to type args. Report TS2315 (as tsc
            // does) but degrade to the base type rather than dropping it,
            // so a `X extends NonGeneric<T>` base keeps its inherited
            // members instead of stripping them all. (Historically this
            // bridged @types/node's generic `Buffer<T> extends
            // Uint8Array<T>` onto the 5.5.4 lib's non-generic
            // `Uint8Array`; the TS 7.0.2 lib is generic, so that skew is
            // gone, but the degradation stays the right lenient default.)
            try c.diagFmt(2315, c.tokSpan(tok), "Type '{s}' is not generic.", .{c.symbolName(sym)});
            return try c.scratch().dupe(TypeId, &.{});
        }
        if (min == tps.items.len) {
            try c.diagFmt(2314, c.tokSpan(tok), "Generic type '{s}' requires {d} type argument(s).", .{ c.symbolName(sym), min });
        } else {
            // With defaults the valid arity is a range (tsc's TS2707).
            try c.diagFmt(2707, c.tokSpan(tok), "Generic type '{s}' requires between {d} and {d} type arguments.", .{ c.symbolName(sym), min, tps.items.len });
        }
        return null;
    }
    var out = try c.scratch().alloc(TypeId, tps.items.len);
    for (tps.items, 0..) |tp, i| {
        if (i < args.len) {
            out[i] = args[i];
        } else if (tp.default != 0) {
            // A default that resolves back through its own parameter —
            // `interface SelfReference<T = SelfReference> {}`, tsc's TS2716 —
            // materializes the same reference, which fills the same default,
            // forever. tsc's `pushTypeResolution(tp, Default)`: a parameter
            // whose default is already being evaluated answers `any` rather
            // than re-entering. (ztsc does not report TS2716 itself.)
            if (std.mem.indexOfScalar(SymbolId, c.tp_default_stack.items, tp.sym) != null) {
                out[i] = types.any_type;
                continue;
            }
            // Defaults are nodes of the declaring file; evaluate there,
            // then substitute the already-resolved params so `B = A` sees
            // the supplied `A` (and `C = B` the defaulted `B`).
            // The file is the *type parameter's* — a merged interface may
            // declare its parameters on a block in a different file than
            // the merged symbol's representative, and reading the node
            // against the wrong tree is out of bounds.
            // `default_sym`, not `sym`: a merged symbol may take the default
            // from a different block than the parameter list (`typeParamsOf`).
            var def: TypeId = undefined;
            // The default's SYNTACTIC tag, read while the declaring file is
            // still current — `tp.default` indexes that file's tree, so asking
            // after the context is restored is out of bounds. See
            // `named_default` below for the one consumer.
            var def_tag: ast.Tag = undefined;
            {
                const dsym = if (tp.default_sym != 0) tp.default_sym else tp.sym;
                const saved = c.enterSymFile(dsym);
                defer c.restoreCtx(saved);
                c.cur_scope = c.symScope(dsym);
                try c.tp_default_stack.append(c.cm(), tp.sym);
                defer _ = c.tp_default_stack.pop();
                def_tag = c.nodeTag(tp.default);
                def = try c.typeFromTypeNode(tp.default);
            }
            // A *bare* default reference to an earlier own param (`Tr = T`)
            // whose alias is *self-recursive* is the recursion accumulator of
            // RHF's `PathInternal<T, TraversedTypes = T>`: its termination
            // guard `AnyIsEqual<Tr, V>` only fires once `Tr` is the concrete
            // form, so the default must resolve to that param's supplied
            // argument even for a library (`.d.ts`) generic. This is a single
            // symbol swap (no expansion), so it cannot reintroduce the
            // deep-generic OOM that gates `.d.ts` defaults. Scoping to
            // recursive aliases keeps non-recursive library defaults (e.g.
            // redux `Reducer<S, A, PreloadedState = S>`) on the pre-existing
            // unsubstituted path — substituting those would eagerly reduce
            // otherwise-deferred store machinery (`ExtractStoreExtensions`)
            // that only reduces cleanly once the infer-var/poison work lands.
            const bare_earlier: ?usize = if (c.ts.kind(def) == .type_param) blk: {
                const dsym = c.ts.typeParamSymbol(def);
                for (tps.items[0..i], 0..) |ptp, j| {
                    if (ptp.sym == dsym) break :blk j;
                }
                break :blk null;
            } else null;
            // A *ground* referenced argument (no type param anywhere) can
            // always be swapped in — this is a single symbol swap identical
            // to the function-call default path (`inferTypeArgs` fills an
            // uninferable default via `instantiate(def, resolved)`), so the
            // alias annotation `UseFormReturn<P>` fills its
            // `TTransformedValues = TFieldValues` default to the supplied `P`
            // exactly as `useForm<P>()`'s return does, keeping the two sides
            // structurally identical (reflexive assignability). A ground arg
            // cannot re-materialize deferred `.d.ts` machinery (the OOM guard
            // and the redux `ExtractStoreExtensions` unmask both require an
            // *abstract* arg), so those concerns below don't apply here.
            //
            // A referenced argument that is itself a *naked type parameter*
            // is the same single symbol swap: it renames one bound name to
            // another and expands nothing, so it can no more re-materialize
            // deferred `.d.ts` machinery than a ground argument can. Leaving
            // it unsubstituted is in fact unsound rather than lenient — the
            // alias body keeps a *free* occurrence of the alias's own `S`
            // that the caller's later instantiation can never close. RTK's
            // `interface Slice<State, …> { reducer: Reducer<State> }` over
            // redux's `Reducer<S, A, PreloadedState = S>` materialized as
            // `(state: State | S | undefined, …) => State`; substituting
            // `Slice<X>` then left the dangling `S` behind, and a merely
            // *generic* type poisons every conditional that tests it —
            // `combineReducers`' `M[keyof M] extends Reducer<…> | undefined`
            // never decided, so its result stayed an unreduced conditional
            // and `configureStore({ reducer: rootReducer })` was rejected.
            const swappable_earlier = bare_earlier != null and
                (!(try c.containsTypeParam(out[bare_earlier.?])) or
                    c.ts.kind(out[bare_earlier.?]) == .type_param);
            // Ensure the generic body is built so self-recursion is detected
            // (the flag is set when materialization re-enters this alias).
            const recursive = if (bare_earlier != null and !swappable_earlier and c.symInDeclFile(sym)) rec: {
                if ((c.alias_state.get(sym) orelse 0) != 1) _ = try c.aliasGeneric(sym);
                break :rec (c.alias_state.get(sym) orelse 0) == 1 or c.alias_recursive.contains(sym);
            } else true;
            // Every earlier position already resolved to a GROUND type. The
            // comment above says why that is the deciding property: the OOM
            // guard and the redux `ExtractStoreExtensions` unmask both require
            // an ABSTRACT argument to be threaded in, and there is none here —
            // the substitution can only replace type parameters by types that
            // mention no type parameter, which is a finite rewrite of a
            // finite term.
            //
            // Leaving it unsubstituted is what is actually unsound: bullmq's
            // `Queue<DataTypeOrJob = any, …, NameType extends string =
            // DataTypeOrJob extends Job<any, any, infer N> ? N : DefaultNameType>`
            // written as a bare `Queue` kept `NameType` as a conditional over
            // `Queue`'s OWN parameters, which nothing downstream can ever
            // close, so `queue.add(name, data)` was TS2345 against a type
            // spelled with the class's own type parameters in it.
            //
            // A NAKED TYPE PARAMETER in an earlier position counts as ground
            // for this test, for the same reason `swappable_earlier` above
            // accepts one: threading it in RENAMES a bound name and expands
            // nothing. Neither hazard the unsubstituted branch exists for can
            // fire on a rename — a conditional over an abstract argument is
            // still deferred after it, and a recursive `.d.ts` term is no more
            // materialized than it was — while leaving it alone is the same
            // unsoundness the bullmq case describes one paragraph up.
            //
            // react-navigation is the case: `NavigationProp<ParamList, …,
            // State extends NavigationState = NavigationState<ParamList>, …>`
            // written as `NavigationProp<T>` inside
            // `getRootNavigation<T extends {}>(nav: NavigationProp<T>)` kept
            // `State = NavigationState<ParamList>` over the ALIAS's own
            // `ParamList`. Instantiating the signature at `T = AllParams` then
            // closed `T` and left `ParamList` free, so the parameter's
            // `dispatch` was spelled `(state: {routeNames: Keyof<ParamList>[]})`
            // and no argument could ever meet it (two TS2345 on one call, plus
            // the cascade through the uninferred return type).
            const ground_earlier = blk: {
                for (out[0..i]) |a| {
                    if (c.ts.kind(a) == .type_param) continue;
                    if (try c.containsTypeParam(a)) break :blk false;
                }
                break :blk true;
            };
            // A default that resolved to a bare NAMED REFERENCE is a third
            // safe case whatever the earlier arguments are: instantiating a
            // `.ref` rewrites its argument list and expands nothing, so it can
            // neither re-materialize a recursive `.d.ts` term nor unmask a
            // deferred reduction — the two hazards the lenient branch exists
            // for. It is also the shape that most often carries the leak,
            // `State extends NavigationState = NavigationState<ParamList>`.
            //
            // ASK THE RESOLVED SHAPE, NOT JUST THE `.ref`. `kind(def) == .ref`
            // is only true while a recursive alias still ANSWERS with a ref,
            // which is a property of what has been materialized SO FAR rather
            // than of the declaration. The moment a mutual cluster finishes,
            // `NavigationProp`'s `State extends NavigationState =
            // NavigationState<ParamList>` comes back a materialized `.object`,
            // this guard misses, and the default is left UNSUBSTITUTED with the
            // alias's own `ParamList` free — `getRootNavigation(navigation)` at
            // social-app's `FeedPage.tsx:101` then has a parameter nothing can
            // meet (TS2345, oracle-clean). Which of the two shapes came back is
            // exactly the partition-dependence `markCycle` was built to remove
            // from the PRINTED type; the same skew reached this guard.
            //
            // An already-materialized object earns the arm on the same argument
            // the `.ref` does, from the other end: a ref expands nothing because
            // it defers, an object expands nothing because it is already
            // expanded. Substituting into either rewrites leaves. What must stay
            // out is a default that REDUCES when a concrete argument reaches it,
            // and that is what the measurement says too — every one of drizzle's
            // nine sites is a `.conditional` (`TSelectedFields =
            // BuildSubquerySelection<TSelection, TNullabilityMap>` on
            // `PgSelectBase` and its Kind/QueryBuilder neighbours), which is
            // precisely the deferred reduction this branch exists to leave
            // alone, and pulling those onto the substituting side is the
            // measured +12.8% wall on drizzle (3.73 s -> 4.20 s over 9 samples
            // of 20 runs, RSS flat).
            //
            // Kept to a default written as a NAME, which is the shape that
            // carries the leak and the only one measured to need this. An
            // inline object-literal default has no recursive alias behind it to
            // change shape underneath, so it stays on the pre-existing path.
            const materialized_default = def_tag == .type_ref and
                c.ts.kind(def) == .object and
                try c.containsTypeParam(def);
            const shallow_default = c.ts.kind(def) == .ref or materialized_default;
            if (bare_earlier != null and (swappable_earlier or recursive or !c.symInDeclFile(sym))) {
                out[i] = out[bare_earlier.?];
            } else if (c.symInDeclFile(sym) and !ground_earlier and !shallow_default) {
                // A *complex* or non-recursive library default (e.g. RTK's
                // `ExtractStoreExtensionsFromEnhancerTuple` tuple default, or
                // `Reducer`'s `PreloadedState = S`) stays unsubstituted:
                // threading a concrete arg through it re-materializes
                // deeply-recursive `.d.ts` types (the historic OOM) or unmasks
                // a still-deferred reduction, so keep prior lenient behavior.
                out[i] = def;
            } else if (c.tp_default_subst_depth >= checker_zig.max_tp_default_subst_depth) {
                // Depth cap (see `max_tp_default_subst_depth`). A CYCLE of
                // aliases naming each other in their defaults produces a fresh
                // type argument at every step, so no per-symbol guard above
                // ever repeats and this branch would recur without a bound.
                // Falling back to the unsubstituted default is what the
                // `.d.ts` branch above already answers; it is depth-dependent,
                // so it must suppress memoization of every enclosing
                // substitution exactly as `max_alias_depth` does.
                c.inst_limit_tripped = true;
                out[i] = def;
            } else {
                // Substitute the already-resolved params into the default so
                // an earlier-param reference (`B = A`) sees the supplied `A`
                // (and `C = B` the defaulted `B`) for user generics.
                c.tp_default_subst_depth += 1;
                defer c.tp_default_subst_depth -= 1;
                const pmap = try c.scratch().alloc(TpMap, i);
                for (tps.items[0..i], 0..) |ptp, j| pmap[j] = .{ .sym = ptp.sym, .ty = out[j] };
                out[i] = try c.instantiate(def, pmap);
            }
        } else {
            out[i] = types.any_type;
        }
    }
    return out;
}
