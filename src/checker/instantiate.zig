//! Named-type expansion and generic instantiation.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const modules = @import("../link/modules.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Io = std.Io;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const check = checker_zig.check;
const max_alias_depth = checker_zig.max_alias_depth;

const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const arrayDecidablyExtends = @import("generics.zig").arrayDecidablyExtends;
const atom = Checker.atom;
const buildInstMap = @import("typenode.zig").buildInstMap;
const checkClass = @import("stmts.zig").checkClass;
const prof_zig = checker_zig.prof_zig;
const diagFmt = Checker.diagFmt;
const fixTypeArgs = @import("typenode.zig").fixTypeArgs;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const indexedAccessType = @import("typenode.zig").indexedAccessType;
const inferReverseMapped = @import("calls.zig").inferReverseMapped;
const objectTypeFromMembers = @import("typenode.zig").objectTypeFromMembers;
const primitiveInterfaceProp = @import("props.zig").primitiveInterfaceProp;
const propOfTypeEx = @import("props.zig").propOfTypeEx;
const resolveSpace = @import("names.zig").resolveSpace;
const run = Checker.run;
const typeParamsOf = @import("typenode.zig").typeParamsOf;

// =====================================================================
// named-type expansion & instantiation
// =====================================================================

pub fn aliasInstance(c: *Checker, sym: SymbolId, args: []const TypeId, tok: TokenIndex) Error!TypeId {
    // Crash guard for pathological mutually-recursive generic alias chains
    // (see `max_alias_depth`). `alias_state` only breaks direct self-
    // recursion; a chain through distinct syms is bounded here.
    if (c.alias_depth >= max_alias_depth) {
        // Depth-dependent, so it must suppress memoization of every enclosing
        // substitution the same way the instantiation depth cap does — see
        // `substThis`.
        c.inst_limit_tripped = true;
        return types.error_type;
    }
    c.alias_depth += 1;
    defer c.alias_depth -= 1;
    const state = c.alias_state.get(sym) orelse 0;
    if (state == 1) {
        // In-progress: recursive alias; leave a lazy ref. Record the
        // self-recursion so `fixTypeArgs` can scope its accumulator-default
        // substitution to genuinely recursive aliases.
        try c.alias_recursive.put(c.cm(), sym, {});
        const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
        return c.ts.makeRef(sym, fixed);
    }
    const fixed = try c.fixTypeArgs(sym, args, tok) orelse return types.error_type;
    const generic = try c.aliasGeneric(sym);
    // ONE spelling for a recursive alias whose body is an INTERSECTION.
    //
    // The cycle-cut arm above leaves a lazy `.ref` for every reference taken
    // while the body was still materializing; a reference taken afterwards
    // gets a separately interned structural materialization. Both denote the
    // same type, but they are distinct `TypeId`s, so `makeUnion` /
    // `makeIntersection` cannot dedupe them and a union can carry the same
    // type under both spellings — and WHICH references fall inside the cycle
    // depends on the order files are visited, i.e. on the checker count.
    //
    // Answering with the ref in BOTH cases makes the spelling of a recursive
    // alias one thing. Scoped to an `originTaggable` body — object, function
    // or intersection — which is exactly the set the `origin` machinery
    // already treats as "a ref and its materialization are interchangeable".
    // A union body must stay materialized: a `.ref` standing in for a union
    // is NOT interchangeable, because discriminant narrowing and the
    // union-source relation arms switch on `.union_type` directly.
    if (c.alias_recursive.contains(sym) and originTaggable(c.ts.kind(generic))) {
        return c.ts.makeRef(sym, fixed);
    }
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len == 0) return generic;
    var map = try c.scratch().alloc(TpMap, tps.items.len);
    for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = fixed[i] };
    const result = try c.instantiate(generic, map);
    // Same recursive shrinking-argument reduction as `expandRef` — applied
    // here so a materialized annotation (`type A = Tail<"a.b.c">`) reduces
    // all the way to `"c"` rather than stalling at the one-step `Tail<"b.c">`
    // ref, keeping the displayed type and the declared type in step with the
    // structural reduction the relation check performs.
    const orig = try c.ts.makeRef(sym, fixed);
    const reduced = try c.reexpandShrinking(orig, result);
    // Origin tag (see `origin`): a one-step alias instantiation carries the
    // canonical `makeRef(sym, fixed)` so the reflexive fast-path can match
    // it against a two-step re-instantiation of the same alias object.
    if (originTaggable(c.ts.kind(reduced))) try c.origin.put(c.cm(), reduced, orig);
    return reduced;
}

pub fn aliasGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.alias_generic.get(sym)) |t| return t;
    try c.alias_state.put(c.cm(), sym, 1);
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    // The alias body is a separate lexical declaration: its own type params
    // shadow any same-named `infer`/mapped binder of the referencing site
    // (see `tp_shadow`). Build the shadow name set for the duration of the
    // body materialization.
    var shadow_buf: std.ArrayList(Atom) = .empty;
    defer shadow_buf.deinit(c.scratch());
    {
        var body_tps: std.ArrayList(TypeParamInfo) = .empty;
        defer body_tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &body_tps);
        for (body_tps.items) |tp| try shadow_buf.append(c.scratch(), c.symNameAtom(tp.sym));
    }
    const saved_shadow = c.tp_shadow;
    c.tp_shadow = shadow_buf.items;
    defer c.tp_shadow = saved_shadow;
    const decls = c.declsOf(sym);
    var result: TypeId = types.any_type;
    for (decls) |decl| {
        if (c.nodeTag(decl) != .type_alias) continue;
        const d = c.tree.nodeData(decl);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s else c.cur_scope = c.symScope(sym);
        result = try c.typeFromTypeNode(d.rhs);
        break;
    }
    // `type T = T` (any cycle collapsing to a self-ref) is circular.
    if (c.ts.kind(result) == .ref and c.ts.refSymbol(result) == sym) {
        const decls2 = c.declsOf(sym);
        if (decls2.len > 0) {
            const data = c.tree.extraData(ast.TypeAlias, c.tree.nodeData(decls2[0]).lhs);
            try c.diagFmt(2456, c.tokSpan(data.name_token), "Type alias '{s}' circularly references itself.", .{c.symbolName(sym)});
        }
        result = types.error_type;
    }
    try c.alias_generic.put(c.cm(), sym, result);
    try c.alias_state.put(c.cm(), sym, 2);
    return result;
}

/// Resolve `.ref` chains to a structural type (object/function/...).
pub fn resolveStructural(c: *Checker, t0: TypeId) Error!TypeId {
    // A polymorphic `this` type has the apparent structure of its home
    // class instance.
    var t = if (c.ts.kind(t0) == .this_type) c.ts.thisTypeInstance(t0) else t0;
    var i: u32 = 0;
    const prof_before = c.inst_total;
    while (c.ts.kind(t) == .ref) : (i += 1) {
        if (i > 16) return types.error_type;
        t = try c.expandRef(t);
    }
    if (c.prof.on and c.inst_total != prof_before) {
        prof_zig.noteExpandSite(c, @returnAddress(), c.inst_total - prof_before);
    }
    return t;
}

/// Is `t` a reference whose expansion is an OBJECT whatever its type
/// arguments are — answerable without expanding it?
///
/// An interface's and a class's member table is `.object` before and after
/// substitution: `interfaceGeneric`/`classInstanceGeneric` build an object
/// (or `error_type` on a base cycle), `instantiateId`'s `.object` arm
/// rebuilds an object, and the two interfaces that would break the rule —
/// `Array`/`ReadonlyArray` — never become refs at all, because
/// `typeFromTypeRef` lowers them to `.array` at construction.
///
/// So a predicate that only reads the KIND of the expansion is a function
/// of the ref's SYMBOL, and can skip materializing a member table that a
/// generic builder interface makes enormous. Type ALIASES are excluded on
/// purpose: an alias body REDUCES when instantiated — a conditional picks a
/// branch, an indexed access resolves, a mapped type materializes — so its
/// kind genuinely depends on the arguments and only the expansion can say.
pub fn refExpandsToObject(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) != .ref) return false;
    const f = c.symFlags(c.ts.refSymbol(t));
    return f.interface or f.class;
}

pub fn expandRef(c: *Checker, ref: TypeId) Error!TypeId {
    if (c.expansions.get(ref)) |t| {
        if (t == types.no_type) return types.error_type; // cycle
        return t;
    }
    try c.expansions.put(c.cm(), ref, types.no_type); // in-progress
    const sym = c.ts.refSymbol(ref);
    const prof_before = c.inst_total;
    defer if (c.prof.on) prof_zig.noteExpand(c, sym, c.inst_total - prof_before);
    const args = try c.scratch().dupe(TypeId, c.ts.refArgs(ref));
    const f = c.symFlags(sym);
    var generic: TypeId = types.any_type;
    // A class's generic table is PROVISIONAL when some class on the way was
    // still materializing (`classTableProvisional`); such a table is never
    // memoized, and neither is any expansion built on it — see the invariant
    // on `classTableProvisional`.
    var provisional = false;
    if (f.class) {
        generic = try c.classInstanceGeneric(sym);
        provisional = c.classTableProvisional(sym);
    } else if (f.interface) {
        generic = try c.interfaceGeneric(sym);
    } else if (f.type_alias) {
        generic = try c.aliasGeneric(sym);
        if (c.ts.kind(generic) == .ref and c.ts.refSymbol(generic) == sym) {
            generic = types.error_type;
        }
    }
    var result = generic;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    if (tps.items.len > 0) {
        // Map every declaration block's positional type params (reopened /
        // merged interfaces bind a distinct symbol per block) to args.
        var map_list: std.ArrayList(TpMap) = .empty;
        defer map_list.deinit(c.scratch());
        try c.buildInstMap(sym, args, &map_list);
        result = try c.instantiate(generic, map_list.items);
        // Recursive-reduction of a shrinking alias (see `reexpandShrinking`):
        // `Tail<"a.b.c">` instantiates its conditional body to the bare ref
        // `Tail<"b.c">`; eagerly re-expand while the argument metric strictly
        // decreases so it fully reduces to `"c"`. A growing recursion
        // (`Grow<{deeper:T}>`) never re-expands — its metric increases.
        if (f.type_alias) result = try c.reexpandShrinking(ref, result);
    }
    // Withdraw the in-progress mark rather than memoizing an expansion of a
    // provisional table: the answer is only true for the duration of the
    // cycle that produced it, and the first reader outside that cycle must
    // recompute it. Nor is it origin-tagged — an incomplete object must not
    // become the identity other materializations of `ref` relate to.
    if (provisional) {
        _ = c.expansions.remove(ref);
        return result;
    }
    // Origin tag: this object is the materialization of `ref =
    // makeRef(sym, canonical-args)` (interface refs carry default-filled
    // args from `fixTypeArgs`). Record it so a structurally-divergent
    // re-materialization of the SAME `ref` relates by identity. Only
    // objects are tagged — a ref that resolved to a union/primitive/etc.
    // is already compared by its own rules.
    if (originTaggable(c.ts.kind(result))) try c.origin.put(c.cm(), result, ref);
    try c.expansions.put(c.cm(), ref, result);
    return result;
}

/// A materialized generic instantiation carries an origin tag (see `origin`)
/// only when it lands on a structural shape whose identity the reflexive /
/// equivalence fast-path can exploit: an object, a function, or an
/// intersection (a callable-object `Callable & {…}` alias such as RTK's
/// `AsyncThunk<…>` materializes to a kept intersection, and its two
/// route-divergent instantiations must relate by origin). Unions/primitives
/// are compared by their own rules and are never tagged.
pub fn originTaggable(k: types.Kind) bool {
    // `.mapped` is tagged too: a still-generic alias instantiation
    // (`WeakValidationMap<P>` with `P` free) never materializes into an
    // object, and inference needs its alias identity to pair with a
    // concrete `WeakValidationMap<X>` argument — tsc's same-alias rule (see
    // `inferReverseMapped`).
    return k == .object or k == .function or k == .intersection or k == .mapped;
}

/// Bound on nested eager expansion of a recursive alias reached through a
/// conditional's true branch (`driveShrinkingAlias`). The chains this
/// drives shrink and bottom out in a handful of hops; the bound is what
/// keeps a GROWING recursion from being driven forever, since the
/// enclosing-ref comparison `reexpandShrinking` uses is not available at
/// that call site.
pub const max_eager_alias_depth: u32 = 8;

/// A recursive alias reached through a resolved conditional's TRUE BRANCH
/// has no enclosing `.ref` for `expandRef` to re-expand from, so the
/// recursion stalls one hop in.
///
/// The lib's `FlatArray<Arr, Depth>` is the case: `arr.flat()`'s return
/// type is the alias body already materialized against the method's own
/// type parameters, i.e. a deferred indexed access — no `FlatArray<…>` ref
/// survives for `aliasInstance`/`expandRef` to drive. Substituting the call's
/// arguments resolves `Arr extends ReadonlyArray<infer I>` and hands back
/// the bare ref `FlatArray<Elem, 0>`, which then simply sits there. A
/// stalled ref is not a union, so `typeof x === "string"` narrowing and the
/// union relation arms never see the constituents.
///
/// Drive it the same way `aliasInstance` drives a source-written
/// `Alias<args>`, and only where `aliasInstance` itself would: a recursive
/// alias whose body is `originTaggable` (object/function/intersection)
/// deliberately keeps ONE ref spelling. Answers null — keep the lazy ref —
/// for everything else, including a chain that does not bottom out.
pub fn driveShrinkingAlias(c: *Checker, ref: TypeId) Error!?TypeId {
    if (c.ts.kind(ref) != .ref) return null;
    if (c.eager_alias_depth >= max_eager_alias_depth) return null;
    const sym = c.ts.refSymbol(ref);
    if (!c.symFlags(sym).type_alias) return null;
    if (!c.alias_recursive.contains(sym)) return null;
    if ((c.alias_state.get(sym) orelse 0) == 1) return null; // body still materializing
    // Not while an argument still carries an unbound `infer` binder (or a
    // deferred conditional / indexed access): expanding then resolves the
    // recursive step against the placeholder instead of against the value
    // the enclosing conditional is about to bind, which loses the
    // distribution and stalls the chain one hop EARLIER than leaving it
    // lazy would. A free outer type parameter is fine — the reduction is
    // the same for every substitution, which is exactly why the enclosing
    // conditional resolved at all (`arrayDecidablyExtends`).
    if (!try c.refArgsSettled(ref, 0)) return null;
    if (originTaggable(c.ts.kind(try c.aliasGeneric(sym)))) return null;
    c.eager_alias_depth += 1;
    defer c.eager_alias_depth -= 1;
    const expanded = try c.expandRef(ref);
    if (expanded == types.error_type) return null;
    const reduced = try c.reexpandShrinking(ref, expanded);
    // Still a ref: the recursion did not bottom out (a non-shrinking hop, or
    // the ceiling). Keep the lazy spelling rather than a half-driven one.
    if (c.ts.kind(reduced) == .ref) return null;
    return reduced;
}

/// Nothing in `t` is a placeholder an enclosing conditional is still about
/// to fill: no `infer` binder, no deferred conditional / indexed access /
/// mapped type. A free type parameter IS settled — substituting it later
/// cannot change the reduction.
///
/// Only the type-forming shapes an `infer` binder can be handed back
/// through are walked; a materialized object/function is settled by
/// definition, and walking one would visit an app's whole element type on
/// every hop.
pub fn refArgsSettled(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 8) return false;
    const s = &c.ts;
    return switch (s.kind(t)) {
        .infer_var,
        .mapped_param,
        .mapped,
        .index_access,
        .conditional,
        .keyof_op,
        .string_mapping,
        .template_literal_type,
        => false,
        // Indexed walks: the recursion can intern and move `extra`.
        .union_type, .intersection, .overloads => blk: {
            for (0..s.memberCount(t)) |i| {
                if (!try c.refArgsSettled(s.memberAt(t, i), depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .array => c.refArgsSettled(s.arrayElem(t), depth + 1),
        .tuple => blk: {
            for (0..s.tupleLen(t)) |i| {
                if (!try c.refArgsSettled(s.tupleElem(t, @intCast(i)).ty, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .ref => blk: {
            for (0..s.refArgCount(t)) |i| {
                if (!try c.refArgsSettled(s.refArgAt(t, i), depth + 1)) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

/// Depth ceiling on the recursive origin-arg equivalence walk (see
/// `originArgEquiv`) — a belt on top of the structure-only reduction, which
/// already terminates (each hop peels a ref/intersection/tuple layer).
pub const origin_equiv_depth: u32 = 8;

pub fn isEmptyObjectType(c: *Checker, t: TypeId) bool {
    const s = &c.ts;
    return s.kind(t) == .object and s.objectPropCount(t) == 0 and
        s.objectStringIndex(t) == 0 and s.objectNumberIndex(t) == 0 and
        s.objectCallSigCount(t) == 0 and s.objectConstructSigCount(t) == 0 and
        // `typeof globalThis` stores no properties but is NOT `{}` — its
        // members live in the linker's globals table. Treating it as the
        // empty-object marker would let `Window & typeof globalThis`
        // reduce away the global half (and mislead the `T & {}`
        // non-nullish marker).
        s.objectFlags(t) & types.obj_flag_global_this == 0;
}

/// `typeof globalThis` — the global-scope object. A single interned marker
/// object with no stored properties; `propOfTypeEx` resolves its members
/// against `prog.globals` on demand. See `types.obj_flag_global_this`.
///
/// Materializing the members eagerly is not an option: the program's merged
/// global value table is thousands of names deep with a full lib, and it is
/// self-referential (`declare var window: Window & typeof globalThis`), so
/// any eager fold would have to break the cycle at whichever point it was
/// first triggered — making `window`'s type depend on traversal order and
/// so on the checker count. Lazy lookup has neither problem.
pub fn globalThisType(c: *Checker) Error!TypeId {
    if (c.global_this_ty == types.no_type) {
        c.global_this_ty = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_global_this | types.obj_flag_not_inferable);
    }
    return c.global_this_ty;
}

/// A member of the global scope object: a program-global *var*, *function*,
/// *namespace* or `declare module` value (`prog.globals`, the same table the
/// bare-name fallback in `resolveSpace` consults).
///
/// BLOCK-SCOPED globals are deliberately excluded. A global `const` / `let`
/// / `class` / `enum` is in lexical scope but is not a property of the
/// global object, and tsc reports exactly that — `globalThis.someConst` is
/// TS2339 while the bare `someConst` resolves (oracle-verified against the
/// pinned tsgo). Type-space-only globals (`interface Window`) are not
/// members either; those are the `globalThisHasValue` = false case, which
/// the access site turns into TS7017 rather than TS2339.
pub fn globalThisProp(c: *Checker, name: Atom) Error!?types.Prop {
    const sym = c.prog.globals.lookup(name) orelse return null;
    const f = c.symFlags(sym);
    if (!hasValueMeaning(f)) return null;
    if (f.const_decl or f.let_decl or f.class or f.enum_decl) return null;
    const flags: u32 = if (f.readonly_member) types.prop_flag_readonly else 0;
    return .{ .name = name, .ty = try c.typeOfSymbol(sym), .flags = flags };
}

/// Whether `name` names a program global with VALUE meaning at all —
/// block-scoped or not. Distinguishes tsc's two failure messages on
/// `globalThis.x`: a known-but-block-scoped global is TS2339 ("Property 'x'
/// does not exist"), an entirely unknown name is TS7017 (the implicit-any
/// index message).
pub fn globalThisHasValue(c: *Checker, name: Atom) bool {
    const sym = c.prog.globals.lookup(name) orelse return false;
    return hasValueMeaning(c.symFlags(sym));
}

/// Canonicalize a type for origin-arg equivalence: resolve refs to their
/// structural form, and drop empty-object members from an intersection
/// (`T & {} ≡ T` — `{}` adds no constraint to an object member, a SOUND
/// rewrite). Returns the interned TypeId so two structurally-identical
/// reductions compare equal by identity, never by assignability.
pub fn reduceForOriginEquiv(c: *Checker, t: TypeId) Error!TypeId {
    const r = try c.resolveStructural(t);
    if (c.ts.kind(r) != .intersection) return r;
    var non_empty: std.ArrayList(TypeId) = .empty;
    defer non_empty.deinit(c.scratch());
    for (try c.memberList(r)) |m| {
        const rm = try c.resolveStructural(m);
        if (!c.isEmptyObjectType(rm)) try non_empty.append(c.scratch(), rm);
    }
    if (non_empty.items.len == 1) return try c.reduceForOriginEquiv(non_empty.items[0]);
    return r;
}

/// Are two origin args EQUAL as types? Sound, identity-based (never mutual
/// assignability): exact TypeId equality, OR same-symbol refs whose args are
/// pairwise equivalent, OR same-shape tuples elementwise, OR one is the
/// `T & {}` form of the other, OR two materializations sharing a same-symbol
/// origin tag. Anything else — including `unknown`/`any` collapse against a
/// concrete type — is NOT equivalent, so a genuinely different instantiation
/// still fails the relation.
pub fn originArgEquiv(c: *Checker, a0: TypeId, b0: TypeId, depth: u32) Error!bool {
    if (a0 == b0) return true;
    if (depth > origin_equiv_depth) return false;
    const s = &c.ts;
    // Compare same-symbol refs structurally WITHOUT expanding (so the
    // recursion tracks arg identity, not the materialized objects).
    if (s.kind(a0) == .ref and s.kind(b0) == .ref and s.refSymbol(a0) == s.refSymbol(b0)) {
        const na = s.refArgCount(a0);
        if (na == s.refArgCount(b0)) {
            var all = true;
            for (0..na) |i| {
                if (!try c.originArgEquiv(s.refArgAt(a0, i), s.refArgAt(b0, i), depth + 1)) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
    }
    const a = try c.reduceForOriginEquiv(a0);
    const b = try c.reduceForOriginEquiv(b0);
    // Identity after reduction — but not for the trivial top/bottom types,
    // whose relation the normal walk already handles permissively (guards
    // against a cycle-truncated `error_type` on both sides reading as equal).
    if (a == b) {
        return switch (s.kind(a)) {
            .any, .err, .unknown, .never, .none => false,
            else => true,
        };
    }
    const ak = s.kind(a);
    if (ak != s.kind(b)) return false;
    if (ak == .tuple) {
        if (s.tupleLen(a) != s.tupleLen(b)) return false;
        for (0..s.tupleLen(a)) |i| {
            const ea = s.tupleElem(a, @intCast(i));
            const eb = s.tupleElem(b, @intCast(i));
            if (ea.flags != eb.flags) return false;
            if (!try c.originArgEquiv(ea.ty, eb.ty, depth + 1)) return false;
        }
        return true;
    }
    // Two distinct materializations of the same generic (each carrying an
    // origin tag): recurse on the origin refs.
    if (ak == .object or ak == .function or ak == .intersection) {
        if (c.origin.get(a)) |oa| {
            if (c.origin.get(b)) |ob| {
                if (oa == ob) return true;
                if (s.kind(oa) == .ref and s.kind(ob) == .ref and s.refSymbol(oa) == s.refSymbol(ob)) {
                    return try c.originArgEquiv(oa, ob, depth + 1);
                }
            }
        }
    }
    return false;
}

/// Ceiling on eager recursive re-expansion of a shrinking alias — a
/// belt-and-braces bound on top of the strict-decrease rule (which already
/// guarantees termination, since the metric is a non-negative integer that
/// strictly decreases each hop). Hitting it stops expanding and keeps the
/// lazy ref — exactly the pre-fix behavior.
pub const shrink_reexpand_ceiling: u32 = 100;

/// Eagerly reduce a recursive alias reference whose argument demonstrably
/// SHRINKS on each hop. `result0` is what `Alias<args>` (identified by
/// `orig_ref`) instantiated to. When that is a bare `.ref` back to a type
/// alias with a STRICTLY SMALLER structural argument metric, re-expand it —
/// this is what carries `Tail<"a.b.c">` → `Tail<"b.c">` → `Tail<"c">` → `"c"`
/// and tuple peels like `[H, ...infer R]` all the way down.
///
/// The strict-decrease test is precisely what keeps the unbounded `Grow<T> =
/// … Grow<{deeper:T}>` case (conformance instantiation/003 + the Grow-like
/// negative control) from ever eagerly expanding: its argument GROWS, so the
/// metric rises and we stop, leaving the lazy ref (the relation cap /
/// deliberate under-report handles it, unchanged). Mutual recursion (A→B→A)
/// re-expands whenever a hop strictly shrinks and is otherwise conservatively
/// left lazy (a non-decreasing hop stops the loop).
pub fn reexpandShrinking(c: *Checker, orig_ref: TypeId, result0: TypeId) Error!TypeId {
    var result = result0;
    // A DISTRIBUTED result is a union of one-step refs — the conditional's
    // naked-check distribution ran per union member, and each member came
    // back as `Alias<smaller-arg>`. Each of those would have been driven
    // had it been the whole result, so drive them member-wise under the
    // same strict-shrink rule. Without this, `Awaited<Promise<A> |
    // Promise<B>>` stalled at `Awaited<A> | Awaited<B>` while the
    // undistributed `Awaited<Promise<A>>` reduced to `A` — the property
    // accesses on a `Promise.all` result (whose element type is exactly
    // this shape) then all failed with TS2339.
    if (c.ts.kind(result) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        var changed = false;
        for (try c.memberList(result)) |m| {
            const r = if (c.ts.kind(m) == .ref) try c.reexpandShrinking(orig_ref, m) else m;
            if (r != m) changed = true;
            try parts.append(c.scratch(), r);
        }
        return if (changed) c.ts.makeUnion(c.scratch(), parts.items) else result;
    }
    if (c.ts.kind(result) != .ref) return result;
    var prev_ref = orig_ref;
    var iter: u32 = 0;
    while (c.ts.kind(result) == .ref and iter < shrink_reexpand_ceiling) : (iter += 1) {
        const rsym = c.ts.refSymbol(result);
        if (!c.symFlags(rsym).type_alias) break;
        // Cross-alias ENTRY on the first hop: when a NON-recursive wrapper
        // alias reduced to a bare ref of a *different*, self-recursive alias
        // (`ExtractStoreExtensions<…> → ExtractStoreExtensionsFromEnhancerTuple
        // <Tail, Acc>`), the `orig`/`result` symbols differ and the summed
        // metric — comparing two unrelated aliases — need not decrease, so
        // the argument-wise recursion would never start. Expand once to
        // "enter" the inner alias; every subsequent hop is same-alias and
        // must pass the strict argument-wise shrink test below. The growing-
        // argument guards (003/010) are self-recursive (same symbol as
        // `orig`) or reduce to a union (not a bare ref), so they never take
        // this entry — only the strict-shrink path, which correctly stops.
        const entry = iter == 0 and c.ts.refSymbol(prev_ref) != rsym;
        if (!entry and !c.refStrictlyShrinks(prev_ref, result)) break; // not shrinking → leave lazy
        prev_ref = result;
        result = try c.expandRef(result);
    }
    return result;
}

/// Decide whether the hop `prev_ref → cur_ref` strictly shrinks, i.e. the
/// recursion is making progress toward a base case and may be eagerly driven.
///
/// For a SELF-recursive hop (both refs name the same alias), the decision is
/// ARGUMENT-WISE: the hop shrinks iff at least one positional argument's
/// structural metric strictly decreases. This is what carries an accumulator
/// alias `Rec<Tup, Acc> = Tup extends [infer H, ...infer T] ? Rec<T, Acc &
/// F<H>> : Acc` down: the tuple argument strictly shrinks each hop even
/// though the growing accumulator would keep a *summed* metric flat or rising
/// (the RTK `ExtractStoreExtensionsFromEnhancerTuple` + `Acc` and RHF
/// `PathInternal<V, Tr|V>` shapes). The shrinking argument is a non-negative
/// integer bounded below, so a single always-decreasing argument terminates;
/// `shrink_reexpand_ceiling` backstops any pathological alternation. The
/// growing-argument guards (conformance 003/010) stay safe: their sole
/// argument GROWS, so no argument decreases and the hop is not driven.
///
/// For a CROSS-alias hop (mutual recursion A→B), no positional correspondence
/// holds, so fall back to the conservative SUMMED strict-decrease test.
pub fn refStrictlyShrinks(c: *Checker, prev_ref: TypeId, cur_ref: TypeId) bool {
    const s = &c.ts;
    if (s.kind(prev_ref) != .ref or s.kind(cur_ref) != .ref)
        return c.shrinkMetric(cur_ref, 0) < c.shrinkMetric(prev_ref, 0);
    if (s.refSymbol(prev_ref) == s.refSymbol(cur_ref)) {
        const pargs = s.refArgs(prev_ref);
        const cargs = s.refArgs(cur_ref);
        if (pargs.len == cargs.len and pargs.len > 0) {
            for (pargs, cargs) |p, q| {
                if (c.shrinkMetric(q, 0) < c.shrinkMetric(p, 0)) return true;
            }
            return false;
        }
    }
    return c.shrinkMetric(cur_ref, 0) < c.shrinkMetric(prev_ref, 0);
}

/// A conservative structural size metric used only to decide whether a
/// recursive alias argument is shrinking. It must (a) DECREASE for the
/// canonical peels — string-literal length for template peels, tuple arity
/// for tuple peels — and (b) INCREASE for `Grow`-style wrapping. String and
/// number literals contribute their text length; tuples/objects/refs charge
/// per element so arity is visible; everything else is a small constant.
/// Bounded by a depth cap so a pathological argument can't blow the stack.
pub fn shrinkMetric(c: *Checker, t: TypeId, depth: u32) u64 {
    if (depth > 40) return 1;
    const s = &c.ts;
    return switch (s.kind(t)) {
        .string_literal, .bigint_literal => 1 + @as(u64, @intCast(c.atomText(s.literalAtom(t)).len)),
        .number_literal, .number_literal_fresh => 3,
        .tuple => blk: {
            var sum: u64 = 1;
            for (0..s.tupleLen(t)) |i| sum += 1 + c.shrinkMetric(s.tupleElem(t, @intCast(i)).ty, depth + 1);
            break :blk sum;
        },
        .array => 2 + c.shrinkMetric(s.arrayElem(t), depth + 1),
        .union_type, .intersection, .overloads => blk: {
            var sum: u64 = 1;
            for (s.members(t)) |m| sum += 1 + c.shrinkMetric(m, depth + 1);
            break :blk sum;
        },
        .object => blk: {
            var sum: u64 = 1;
            for (0..s.objectPropCount(t)) |i| sum += 2 + c.shrinkMetric(s.objectProp(t, @intCast(i)).ty, depth + 1);
            break :blk sum;
        },
        .ref => blk: {
            var sum: u64 = 1;
            for (s.refArgs(t)) |a| sum += c.shrinkMetric(a, depth + 1);
            break :blk sum;
        },
        else => 1,
    };
}

/// A re-entry into `interfaceGeneric(sym)` closed a reference loop. If the
/// whole loop — every gray frame from `sym` to the top — is currently
/// resolving an `extends` base, it is a genuine base cycle: report TS2310
/// for each member (tsc reports on every interface in the cycle), each
/// attributed to its own declaration file so `diagFmt`'s per-(file,code,
/// span) dedup keeps one per member and its owning checker keeps its own.
/// A loop that runs through a member or type-argument edge is a legal
/// recursive reference and reports nothing. Either way the emitted set is
/// a pure function of the extends graph — order- and partition-independent
pub fn emitBaseCycle(c: *Checker, sym: SymbolId) Error!void {
    const stack = c.iface_stack.items;
    var start: usize = stack.len;
    while (start > 0) : (start -= 1) {
        if (stack[start - 1].sym == sym) break;
    }
    if (start == 0) return; // sym not on the stack (defensive; shouldn't happen)
    for (stack[start - 1 ..]) |fr| {
        if (!fr.resolving_base) return; // loop closes through a non-base edge
    }
    for (stack[start - 1 ..]) |fr| {
        const saved = c.enterSymFile(fr.sym);
        defer c.restoreCtx(saved);
        const decls = c.declsOf(fr.sym);
        if (decls.len == 0) continue;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decls[0]).lhs);
        try c.diagFmt(2310, c.tokSpan(data.name_token), "Type '{s}' recursively references itself as a base type.", .{c.symbolName(fr.sym)});
    }
}

/// Generic (type-params-as-themselves) instance shape of an interface,
/// with `extends` bases merged (derived members win).
pub fn interfaceGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    if (c.iface_generic.get(sym)) |t| {
        if (t == types.no_type) {
            // Recursive base chain: `sym` is still on the gray stack, so
            // the slice from it to the top is the cycle. Fire TS2310 for
            // every member (tsc reports on each interface in the cycle),
            // attributed to its own file — the diagnostic set no longer
            // depends on which member the traversal entered first.
            try c.emitBaseCycle(sym);
            return types.error_type;
        }
        return t;
    }
    try c.iface_generic.put(c.cm(), sym, types.no_type);
    try c.iface_stack.append(c.cm(), .{ .sym = sym });
    defer _ = c.iface_stack.pop();

    // Constituents: a within-file interface is one symbol carrying every
    // reopened block's decls; a cross-file merged interface is a
    // list of per-file symbols. Members are converted in *each* constituent's
    // own file context (member type nodes resolve against that file's
    // scopes). A merged interface must fold in TWO phases — all constituents'
    // DIRECT members first, then every constituent's `extends` bases — so an
    // own member (which may live on a LATER cross-file constituent, e.g. a
    // `lib.dom.iterable` augmentation) overrides an inherited one gathered
    // from an EARLIER constituent's base. Folding whole per-constituent
    // objects (direct + inherited) instead would let an earlier
    // constituent's inherited member shadow a later constituent's own
    // member. This mirrors the single-file binder merge, where all reopened
    // blocks' direct members are gathered before any base is applied.
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    // The whole declaration set a member's `this` and type-parameter list
    // belong to. `sym` may be ONE constituent of a cross-file merge — the
    // declaration walk expands the file-local symbol so its members'
    // diagnostics fire — and that partial expansion memoizes member
    // signatures. Binding `this` to the constituent would bake a reference
    // that expands to one file's members alone into those memos, which the
    // merged expansion then inherits.
    const owner = c.prog.mergedOf(sym) orelse sym;

    // Phase 1: direct members of every interface constituent, unioned with
    // earlier-file members winning on conflict (disjoint in the clean case;
    // conflicts are TS2717, deferred).
    var result: TypeId = types.no_type;
    for (parts) |csym| {
        if (!c.symFlags(csym).interface) continue;
        const dm = try c.interfaceConstituentDirect(csym, owner);
        result = if (result == types.no_type) dm else try c.mergeBaseObject(result, dm, true);
    }
    // An empty interface (no members, no bases) is still a nominal shape:
    // it lacks the implied string index that an empty object *literal* has.
    if (result == types.no_type) result = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_not_inferable);
    // Phase 2: merge every constituent's `extends` bases; the phase-1 direct
    // members win, so an own member overrides an inherited one.
    for (parts) |csym| {
        if (!c.symFlags(csym).interface) continue;
        result = try c.interfaceConstituentApplyBases(csym, result, owner);
    }
    try c.iface_generic.put(c.cm(), sym, result);
    return result;
}

/// Set `this` to `sym`'s generic instance (polymorphic `this` return,
/// `this` property/param types). Caller saves/restores `c.this_type`.
///
/// `sym` must be the WHOLE declaration set — the merged id for a cross-file
/// merged interface, not one constituent. A `foo(): this` written in one
/// constituent denotes the merged interface, so binding `this` to the
/// constituent symbol would yield a reference that expands to that one
/// file's members alone (dropping the sibling constituent's members and its
/// `extends` bases), and a spurious mismatch against the base's own
/// `this`-returning member.
pub fn setInterfaceThis(c: *Checker, sym: SymbolId) Error!void {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    const args = try c.scratch().alloc(TypeId, tps.items.len);
    for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
    c.this_type = try c.ts.makeRef(sym, args);
}

/// Direct members (no `extends` bases) of one interface constituent `sym`:
/// the union of every reopened block's members, converted in the symbol's
/// own file context. `owner` is the whole declaration set the constituent
/// belongs to (see `setInterfaceThis`). See `interfaceGeneric` for why
/// bases are applied separately.
pub fn interfaceConstituentDirect(c: *Checker, sym: SymbolId, owner: SymbolId) Error!TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    try c.setInterfaceThis(owner);

    var all_members: std.ArrayList(Node) = .empty;
    defer all_members.deinit(c.scratch());
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.InterfaceData, d.lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m != null_node) try all_members.append(c.scratch(), m);
        }
    }
    // Convert members in one interface scope — the first block that
    // declares the type parameters, else the first block. Reopened blocks
    // bind a distinct type-param symbol per block and `buildInstMap` maps
    // them all positionally, so any declaring block's scope resolves the
    // parameter names; a block that omits the list entirely (legal when
    // every parameter has a default) does not, so it must not be picked
    // over one that has them. Mirrors `typeParamsOf`.
    var scope_decl: Node = null_node;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        if (scope_decl == null_node) scope_decl = decl;
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.declTypeParams(decl, &tps);
        if (tps.items.len > 0) {
            scope_decl = decl;
            break;
        }
    }
    if (scope_decl != null_node) {
        if (try c.scopeOf(scope_decl)) |s| c.cur_scope = s;
    }
    return c.objectTypeFromMembers(all_members.items, types.obj_flag_not_inferable);
}

/// Merge one interface symbol's `extends` bases into `acc` (members already
/// in `acc` win), converting the heritage clauses in the symbol's own file
/// context. Marks the current gray frame as resolving bases so a re-entry is
/// recognized as a base cycle (TS2310); member/type-argument resolution
/// stays out of the base phase, so a recursive reference through them is
/// legal and reports nothing.
pub fn interfaceConstituentApplyBases(c: *Checker, sym: SymbolId, acc: TypeId, owner: SymbolId) Error!TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    try c.setInterfaceThis(owner);

    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    try c.interfaceHeritageTypes(sym, &bases);
    const frame_idx: ?usize = if (c.iface_stack.items.len > 0) c.iface_stack.items.len - 1 else null;
    if (frame_idx) |fi| c.iface_stack.items[fi].resolving_base = true;
    defer if (frame_idx) |fi| {
        c.iface_stack.items[fi].resolving_base = false;
    };
    var own = acc;
    for (bases.items) |base| {
        own = try c.mergeBaseResolved(own, try c.resolveStructural(base));
    }
    return own;
}

/// The `extends` heritage types written on every `interface` declaration of
/// `sym`, in declaration order, converted in the symbol's own file context.
/// Caller sets `this` and the file context (see `interfaceConstituentApplyBases`).
pub fn interfaceHeritageTypes(c: *Checker, sym: SymbolId, out: *std.ArrayList(TypeId)) Error!void {
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.InterfaceData, d.lhs);
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        for (c.tree.extraRange(data.extends_start, data.extends_end)) |h| {
            if (h == null_node or c.nodeTag(h) != .heritage) continue;
            const hd = c.tree.nodeData(h);
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            if (hd.rhs != 0) {
                const r = c.tree.extraData(ast.SubRange, hd.rhs);
                for (c.tree.extraRange(r.start, r.end)) |an| {
                    if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                }
            }
            try out.append(c.scratch(), try c.typeFromTypeName(hd.lhs, targs.items));
        }
    }
}

/// Merge one resolved base into `derived`. A base that reduces to an
/// intersection of objects (e.g. `interface X extends Omit<M, K> & { … }`,
/// or a `type` alias whose body is an intersection) contributes the members
/// of each object constituent — folded left-to-right so an earlier
/// constituent (and `derived` itself) wins on a name clash. Without this,
/// `mergeBaseObject`'s object-only guard would silently drop every inherited
/// member of an intersection base.
pub fn mergeBaseResolved(c: *Checker, derived: TypeId, base: TypeId) Error!TypeId {
    if (c.ts.kind(base) == .intersection) {
        var result = derived;
        for (try c.memberList(base)) |m| {
            result = try c.mergeBaseResolved(result, try c.resolveStructural(m));
        }
        return result;
    }
    // `interface RegExpMatchArray extends Array<string>` (and every
    // user-written `interface X extends Array<T>`). ztsc models an array
    // with a dedicated `.array` kind rather than the lib `Array<T>`
    // interface's object, so `mergeBaseObject`'s object-only guard dropped
    // the whole base: `m.length`, `m.slice`, `m[Symbol.iterator]` were all
    // TS2339. Bridge to the interface object the same way a member access
    // on a bare array does (`primitiveInterfaceProp`) and merge that.
    if (c.ts.kind(base) == .array or c.ts.kind(base) == .tuple) {
        const obj = (try c.arrayInterfaceObject(base)) orelse return derived;
        return c.mergeBaseObject(derived, obj, false);
    }
    return c.mergeBaseObject(derived, base, false);
}

/// The lib `Array<T>` interface's object for an array/tuple type, or null
/// when no lib is loaded (so the bridge degrades to today's behavior).
pub fn arrayInterfaceObject(c: *Checker, t: TypeId) Error!?TypeId {
    const elem = switch (c.ts.kind(t)) {
        .array => c.ts.arrayElem(t),
        .tuple => try c.tupleElementUnion(t),
        else => return null,
    };
    const sym = c.prog.globals.lookup(c.atom_Array) orelse return null;
    if (!c.symFlags(sym).interface) return null;
    const r = try c.resolveStructural(try c.ts.makeRef(sym, &.{elem}));
    return if (c.ts.kind(r) == .object) r else null;
}

/// Combined overload set of two callable members (`.function` or
/// `.overloads`), `a`'s signatures before `b`'s. Returns null when either
/// side is not callable, so the caller falls back to earlier-wins.
pub fn unionCallableSigs(c: *Checker, a: TypeId, b: TypeId) Error!?TypeId {
    const s = &c.ts;
    const ka = s.kind(a);
    const kb = s.kind(b);
    const a_ok = ka == .function or ka == .overloads;
    const b_ok = kb == .function or kb == .overloads;
    if (!a_ok or !b_ok) return null;
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    for ([2]TypeId{ a, b }) |o| {
        if (s.kind(o) == .overloads) {
            for (s.members(o)) |m| try sigs.append(c.scratch(), m);
        } else {
            try sigs.append(c.scratch(), o);
        }
    }
    return try s.makeOverloads(sigs.items);
}

/// Merge base-object members into `derived` (derived wins). When
/// `union_overloads` is set (the cross-file interface-declaration Phase-1
/// merge), a method declared in BOTH objects contributes its signatures to
/// a single combined overload set (`derived`'s first) rather than the
/// earlier declaration hiding the later's overloads — mirroring tsc's
/// declaration-order overload concatenation across merged interface
/// declarations, and the within-file reopened-block behavior already
/// implemented in `objectTypeFromMembers`. Base/heritage merging keeps
/// `union_overloads` false: an inherited member is shadowed, not unioned.
pub fn mergeBaseObject(c: *Checker, derived: TypeId, base: TypeId, union_overloads: bool) Error!TypeId {
    if (c.ts.kind(base) != .object or c.ts.kind(derived) != .object) return derived;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var idx: std.AutoHashMapUnmanaged(Atom, u32) = .empty;
    defer idx.deinit(c.scratch());
    for (0..c.ts.objectPropCount(derived)) |i| {
        const p = c.ts.objectProp(derived, @intCast(i));
        try idx.put(c.scratch(), p.name, @intCast(props.items.len));
        try props.append(c.scratch(), p);
    }
    for (0..c.ts.objectPropCount(base)) |i| {
        const bp = c.ts.objectProp(base, @intCast(i));
        if (idx.get(bp.name)) |di| {
            if (union_overloads) {
                if (try c.unionCallableSigs(props.items[di].ty, bp.ty)) |mt| props.items[di].ty = mt;
            }
        } else {
            try idx.put(c.scratch(), bp.name, @intCast(props.items.len));
            try props.append(c.scratch(), bp);
        }
    }
    const sidx = if (c.ts.objectStringIndex(derived) != 0) c.ts.objectStringIndex(derived) else c.ts.objectStringIndex(base);
    const nidx = if (c.ts.objectNumberIndex(derived) != 0) c.ts.objectNumberIndex(derived) else c.ts.objectNumberIndex(base);
    // Preserve call/construct signatures from both sides: a callable
    // interface extending another accumulates every signature.
    if (!c.ts.objectHasSigs(derived) and !c.ts.objectHasSigs(base)) {
        return c.ts.makeObject(props.items, sidx, nidx, c.ts.objectFlags(derived) & ~types.obj_flag_has_sigs);
    }
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var constructs: std.ArrayList(TypeId) = .empty;
    defer constructs.deinit(c.scratch());
    for ([2]TypeId{ derived, base }) |o| {
        for (0..c.ts.objectCallSigCount(o)) |i| try calls.append(c.scratch(), c.ts.objectCallSig(o, @intCast(i)));
        for (0..c.ts.objectConstructSigCount(o)) |i| try constructs.append(c.scratch(), c.ts.objectConstructSig(o, @intCast(i)));
    }
    return c.ts.makeObjectSigs(props.items, sidx, nidx, c.ts.objectFlags(derived) & ~types.obj_flag_has_sigs, calls.items, constructs.items);
}

/// Generic instance shape of a class: instance members + base instance.
pub fn classInstanceGeneric(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.class_inst_generic.get(sym)) |t| {
        if (t == types.no_type) return types.error_type;
        return t;
    }
    try c.class_inst_generic.put(c.cm(), sym, types.no_type);
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    // `this` inside member type nodes (a `foo(): this` return, a `x: this`
    // property, a `this` parameter) refers to this class's generic
    // instance. Set it here so member signatures pick up the polymorphic
    // `this` marker even when they are first evaluated through instance
    // expansion (before `checkClass`).
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(sym, &tps);
        const args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        c.this_type = try c.ts.makeRef(sym, args);
    }
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    // Set when a base could not be folded completely; see the base merge
    // below and the invariant on `classTableProvisional`.
    var provisional = false;
    // A class instance is a nominal shape without the implied string index
    // that an object/type literal carries (an empty `class C {}` must still
    // fail assignment to `{[k:string]:T}`).
    var result: TypeId = try c.ts.makeObject(&.{}, 0, 0, types.obj_flag_not_inferable);
    if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
        const kscope = c.symScope(sym);
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            const msym = c.toGlobal(c.bind.member_syms[i]);
            const name = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope);
            const mf = c.symFlags(msym);
            if (isCtorName(c, name)) continue;
            var flags: u32 = 0;
            if (mf.optional_member) flags |= types.prop_flag_optional;
            if (mf.readonly_member) flags |= types.prop_flag_readonly;
            // A get-only accessor is a read-only property (TS2540 on write).
            if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
            try props.append(c.scratch(), .{
                .name = name,
                .ty = try c.memberTypeOf(msym),
                .flags = flags,
            });
        }
        result = try c.ts.makeObject(props.items, 0, 0, types.obj_flag_not_inferable);
    }
    // Same-file class+interface declaration merge. tsc binds the pair to ONE
    // symbol whose declarations share a single member table, and whose base
    // list is the class's `extends` FOLLOWED BY every interface block's
    // `extends` (`getBaseTypes` runs `resolveBaseTypesOfClass` and then
    // `resolveBaseTypesOfInterface`). So the interface half's DECLARED
    // members join the class's own here — before any base, so a declared
    // member still overrides an inherited one — and its `extends` bases are
    // folded after the class's base below. drizzle leans on this hard:
    // `interface Table extends SQLWrapper {}` beside `declare class Table
    // implements SQLWrapper {}` is what makes the class satisfy the
    // interface at all.
    const iface_half = !c.prog.isMergedId(sym) and c.symFlags(sym).interface;
    if (iface_half) {
        result = try c.mergeBaseObject(result, try c.interfaceConstituentDirect(sym, sym), true);
    }
    // Merge base class instance. A base whose own table is still
    // materializing further down this stack resolves to `err`, which
    // `mergeBaseObject`'s object-only guard drops — the derived instance
    // then silently loses EVERY inherited member. The fold still cuts (there
    // is nothing else it could do mid-cycle), but the incomplete table it
    // produced is marked provisional so it is never memoized.
    if (try c.baseClassRef(sym)) |base_ref| {
        result = try c.mergeBaseObject(result, try c.resolveStructural(base_ref), false);
        if (c.baseRefProvisional(base_ref)) provisional = true;
    } else if (try c.baseExprConstructType(sym)) |base_ctor| {
        // `extends <value with construct signatures>`: the base instance is
        // the construct signature's return type.
        const inst = c.ts.objectConstructSig(base_ctor, 0);
        const ret = c.ts.fnReturn(inst);
        result = try c.mergeBaseObject(result, try c.resolveStructural(ret), false);
    }
    // Cross-file `declare module` augmentation: an `interface Map`
    // block in another package folds its members into the resolved class's
    // instance type (interface-augments-class declaration merge). The class
    // is the merged symbol's representative constituent; each interface
    // constituent supplies augmentation members, added on top of the base
    // and unioning any callable-signature overloads (e.g. `on(...)`).
    if (c.prog.isMergedId(sym)) {
        for (c.prog.mergedSym(sym).parts) |p| {
            if (!c.symFlags(p).interface) continue;
            result = try c.mergeBaseObject(result, try c.interfaceConstituentDirect(p, sym), true);
        }
    }
    if (iface_half) result = try c.classInterfaceHalfBases(sym, result, &provisional);
    // Only a table folded over COMPLETE bases earns a place in the memo —
    // see `classTableProvisional`. Withdraw the in-progress mark otherwise,
    // so the next reader recomputes instead of inheriting the cut.
    if (provisional) {
        _ = c.class_inst_generic.remove(sym);
    } else {
        try c.class_inst_generic.put(c.cm(), sym, result);
    }
    return result;
}

/// Was `sym`'s class member table left PROVISIONAL — folded over a base this
/// checker could not see completely, because that base's own table was still
/// materializing further down the stack?
///
/// The invariant this reads: **`class_inst_generic` holds complete tables
/// only.** A table folded across a cycle cut is returned to its caller (there
/// is no better answer mid-cycle) but never memoized, so the entry is either
/// absent (provisional, withdrawn) or `no_type` (still materializing) exactly
/// when the answer is incomplete. Transitivity is free: a derived class that
/// folded a provisional base sees no memo entry for it and marks itself
/// provisional in turn.
pub fn classTableProvisional(c: *Checker, sym: SymbolId) bool {
    const g = c.class_inst_generic.get(sym) orelse return true;
    return g == types.no_type;
}

/// `classTableProvisional` for a resolved base written as a type reference.
/// Only class refs answer true — an interface / alias base is folded by
/// different machinery with its own guard.
pub fn baseRefProvisional(c: *Checker, base_ref: TypeId) bool {
    if (c.ts.kind(base_ref) != .ref) return false;
    const sym = c.ts.refSymbol(base_ref);
    if (!c.symFlags(sym).class) return false;
    return c.classTableProvisional(sym);
}

/// Fold the `extends` bases written on a class's same-file `interface` half
/// into its instance type; members already in `acc` (the class's own and the
/// interface half's declared members, plus the class's `extends` base) win.
/// A class base among them that could not be folded completely sets
/// `provisional`, exactly as the class's own `extends` base does.
pub fn classInterfaceHalfBases(c: *Checker, sym: SymbolId, acc: TypeId, provisional: *bool) Error!TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    try c.interfaceHeritageTypes(sym, &bases);
    var own = acc;
    for (bases.items) |b| {
        own = try c.mergeBaseResolved(own, try c.resolveStructural(b));
        if (c.baseRefProvisional(b)) provisional.* = true;
    }
    return own;
}

pub fn isCtorName(c: *Checker, name: Atom) bool {
    return std.mem.eql(u8, c.atomText(name), "constructor");
}

/// Ceiling on the `extends` walk in `lazyRefProp`. A base chain is already
/// acyclic by construction (a cyclic `extends` is a bind error), but the
/// lazy path runs *inside* an in-progress materialization where the usual
/// caches are unavailable, so it carries its own belt.
pub const lazy_base_depth: u32 = 16;

/// Is `sym`'s class member table being materialized further down this
/// checker's stack? `classInstanceGeneric` marks in-progress with `no_type`,
/// and answers `error_type` — a cut, not a result — for the whole window.
pub fn classGenericInProgress(c: *Checker, sym: SymbolId) bool {
    const g = c.class_inst_generic.get(sym) orelse return false;
    return g == types.no_type;
}

/// Is `ref`'s materialization already on this checker's stack? Both layers
/// mark in-progress with `no_type`: `class_inst_generic` for the class's
/// own member table and `expansions` for this particular argument list. The
/// class layer is consulted FIRST and is the authoritative one — a SECOND
/// argument list for the same class (`Sel<any>` reached while `Sel<T>` is
/// materializing) has no `expansions` mark of its own, and `expandRef`
/// withdraws the mark it did make rather than memoizing the cut, so only the
/// class layer can see the whole window.
///
/// Distinct from `classTableProvisional`, which also answers true for a
/// class whose table was withdrawn and is not being materialized right now.
/// This one is the narrower "on the stack" question the lazy single-member
/// lookups route on.
pub fn refExpansionActive(c: *Checker, ref: TypeId) bool {
    if (c.ts.kind(ref) != .ref) return false;
    const sym = c.ts.refSymbol(ref);
    if (c.symFlags(sym).class and c.classGenericInProgress(sym)) return true;
    const e = c.expansions.get(ref) orelse return false;
    return e == types.no_type;
}

/// ONE named member of a class `ref`, resolved without materializing the
/// whole member table. Null when the name is not a member of the class or
/// its bases — the caller then takes its ordinary not-found path.
///
/// `expandRef` builds a class instance eagerly: every member's type is
/// computed to fill the object. That makes a perfectly ordinary TypeScript
/// cycle — a method parameter annotated with an alias that indexes back
/// into the class (`type P = { s: C["s"] }; class C { use(p: P) {} }`) —
/// re-enter the class's own in-progress expansion, where the only answer
/// available was `error_type` → `any`. The `any` is then *memoized* into
/// the alias body, so every later reader of `P.s` sees `any` for the rest
/// of the run, and which members lose depends on traversal order (so on
/// the checker count).
///
/// tsc has no such state: `getPropertyOfType` resolves a single property
/// symbol on demand, and only the member that is *itself* circular is an
/// error. This is that lookup — the same lazy-member idea `globalThisType`
/// already relies on for the self-referential global table.
pub fn lazyRefProp(c: *Checker, ref: TypeId, name: Atom, depth: u32) Error!?types.Prop {
    if (depth >= lazy_base_depth) return null;
    const sym = c.ts.refSymbol(ref);
    // Interfaces are not on this path: `interfaceGeneric` folds heritage
    // and reopened declaration blocks, and a single-member shortcut past
    // that fold would answer differently from the table it stands in for.
    if (!c.symFlags(sym).class) return null;
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    // Same polymorphic-`this` binding `classInstanceGeneric` installs, so a
    // member signature mentioning `this` resolves identically on both paths.
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    {
        const targs = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| targs[i] = try c.ts.makeTypeParam(tp.sym);
        c.this_type = try c.ts.makeRef(sym, targs);
    }
    var found: ?types.Prop = null;
    if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
        const kscope = c.symScope(sym);
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            const nm = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope);
            if (nm != name) continue;
            if (isCtorName(c, nm)) continue;
            const msym = c.toGlobal(c.bind.member_syms[i]);
            // `class C { a: C["a"] }` — the member's own type asks for
            // itself. Genuinely circular; leave it to the caller's
            // not-found path rather than recursing.
            if (c.lazy_member_active.contains(msym)) return null;
            try c.lazy_member_active.put(c.cm(), msym, {});
            defer _ = c.lazy_member_active.remove(msym);
            const mf = c.symFlags(msym);
            var flags: u32 = 0;
            if (mf.optional_member) flags |= types.prop_flag_optional;
            if (mf.readonly_member) flags |= types.prop_flag_readonly;
            if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
            found = .{ .name = nm, .ty = try c.memberTypeOf(msym), .flags = flags };
            break;
        }
    }
    if (found == null) {
        // Inherited member: walk `extends`. A base whose own expansion is
        // also on the stack stays on the lazy path.
        if (try c.baseClassRef(sym)) |base_ref| {
            if (c.refExpansionActive(base_ref)) {
                found = try c.lazyRefProp(base_ref, name, depth + 1);
            } else {
                const b = try c.resolveStructural(base_ref);
                found = try c.propOfTypeEx(b, name, false);
            }
        }
    }
    var p = found orelse return null;
    if (tps.items.len > 0) {
        var map_list: std.ArrayList(TpMap) = .empty;
        defer map_list.deinit(c.scratch());
        const args = try c.scratch().dupe(TypeId, c.ts.refArgs(ref));
        try c.buildInstMap(sym, args, &map_list);
        p.ty = try c.instantiate(p.ty, map_list.items);
    }
    return p;
}

/// Expression-position companion to the `indexedAccessType` wiring above:
/// a property read whose receiver is a class ref (or a polymorphic `this`
/// standing for one) whose materialization is on this checker's stack.
/// Null whenever the ordinary path is the right one — the receiver is not
/// such a ref, or the name is genuinely not a member.
///
/// Termination: every recursion goes through `lazyRefProp`, which marks the
/// member symbol it is resolving in `lazy_member_active` and answers null
/// for a member already on that stack. A self-referential inferred return
/// (`m() { return this.m(); }`) or field (`p = this.p`) therefore cuts to
/// the caller's not-found path instead of recurring, and a mutual cycle
/// cuts after at most one pass per member.
pub fn lazyThisProp(c: *Checker, recv: TypeId, name: Atom) Error!?types.Prop {
    const t = if (c.ts.kind(recv) == .this_type) c.ts.thisTypeInstance(recv) else recv;
    if (!c.refExpansionActive(t)) return null;
    return c.lazyRefProp(t, name, 0);
}

/// Is `name` an OWN instance member (field, param-property, accessor,
/// method) of the class whose constructor is currently being checked? Used
/// to permit a `readonly` assignment via `this.name` inside that
/// constructor (an inherited readonly is not own → still TS2540).
pub fn ctorClassOwnsMember(c: *Checker, name: Atom) bool {
    if (c.ctor_class_sym == binder.no_symbol) return false;
    const saved = c.enterSymFile(c.ctor_class_sym);
    defer c.restoreCtx(saved);
    const ms = c.bind.membersScopeOf(c.localOf(c.ctor_class_sym)) orelse return false;
    const lo = c.bind.scope_members_start[ms];
    const hi = c.bind.scope_members_start[ms + 1];
    for (lo..hi) |i| {
        if (c.bind.member_atoms[i] == name) return true;
    }
    return false;
}

/// The `extends` base of a class as a ref (or null). The base name
/// resolves in the class's own file (so imported bases work).
pub fn baseClassRef(c: *Checker, sym: SymbolId) Error!?TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        if (data.extends == 0) return null;
        const hd = c.tree.nodeData(data.extends);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const base_sym = (try c.classBaseEntitySym(hd.lhs)) orelse return null;
        if (!c.symFlags(base_sym).class) return null;
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        if (hd.rhs != 0) {
            const r = c.tree.extraData(ast.SubRange, hd.rhs);
            for (c.tree.extraRange(r.start, r.end)) |an| {
                if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
            }
        }
        const name_tok = switch (c.nodeTag(hd.lhs)) {
            .identifier => c.tree.nodeMainToken(hd.lhs),
            else => c.tree.nodeData(hd.lhs).rhs,
        };
        const fixed = try c.fixTypeArgs(base_sym, targs.items, name_tok) orelse return null;
        return try c.ts.makeRef(base_sym, fixed);
    }
    return null;
}

/// True when somewhere up `sym`'s `extends` chain there is a base ztsc could
/// not resolve to a class declaration — an `import S = internal.Stream;`
/// entity alias (deliberately lenient, resolves to `any`), a mixin
/// expression, a base behind an unmodeled construct. Such a class's member
/// set is INCOMPLETE by construction, so any "does not implement" verdict
/// against it is an artifact of the missing base, not a fact about the code:
/// `@types/node`'s `class ReadableBase extends Stream implements
/// NodeJS.ReadableStream` is exactly this shape. Callers use it to stay
/// silent rather than emit a false positive.
pub fn hasUnresolvedBase(c: *Checker, sym: SymbolId) Error!bool {
    var cur = sym;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        var has_extends = false;
        {
            const saved_ctx = c.enterSymFile(cur);
            defer c.restoreCtx(saved_ctx);
            for (c.declsOf(cur)) |decl| {
                if (c.nodeTag(decl) != .class_decl) continue;
                const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
                if (data.extends != 0) {
                    has_extends = true;
                    break;
                }
            }
        }
        if (!has_extends) return false;
        const base = (try c.baseClassSym(cur)) orelse return true;
        if (base == cur) return false; // self-extends: not an unknown base
        cur = base;
    }
    return false;
}

/// The base *class symbol* of `sym` (`class D extends B`), when the base
/// resolves to a class declaration. Mirrors `baseClassRef`'s resolution but
/// yields the symbol — used to inherit static members (`typeof D` includes
/// `typeof B`'s statics: `Map.include`/`GridLayer.extend` reach `Class`).
pub fn baseClassSym(c: *Checker, sym: SymbolId) Error!?SymbolId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        if (data.extends == 0) return null;
        const hd = c.tree.nodeData(data.extends);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const base_sym = (try c.classBaseEntitySym(hd.lhs)) orelse return null;
        if (!c.symFlags(base_sym).class) return null;
        if (base_sym == sym) return null; // self-extends: no static inherit
        return base_sym;
    }
    return null;
}

/// Resolve a class `extends` entity (identifier or dotted, e.g.
/// `React.Component`) to its declaration symbol. Import bindings are
/// followed; a namespace import of an `export =`-namespace module (the
/// @types/react shape) resolves through the exported namespace. Null for
/// anything unresolvable or non-symbolic (expressions, mixins).
pub fn classBaseEntitySym(c: *Checker, node: Node) Error!?SymbolId {
    switch (c.nodeTag(node)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(node));
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| {
                    if (!c.symFlags(sym).import_binding) return sym;
                    const tgt = c.importTarget(sym) orelse return null;
                    // A dual binding is a heritage base through its VALUE
                    // meaning — tsc's combined symbol takes `valueDeclaration`
                    // from the property (`Request: typeof SARequest`), so the
                    // base is that constructor's class, not the same-named
                    // interface in the type half. `@types/supertest`'s
                    // `declare class Test extends Request` is exactly this.
                    if (tgt.kind == .dual) {
                        if (try c.dualValueType(c.prog.dual_targets[tgt.payload])) |vt| {
                            if (c.ts.kind(vt) == .class_value) return c.ts.classSymbol(vt);
                        }
                    }
                    return c.importedContainerSym(tgt);
                },
                else => return null,
            }
        },
        .member_expr, .qualified_name => {
            // `extends mod.Base` — resolve the qualifier to its container
            // (namespace symbol or whole-module namespace of an
            // `import * as`), then take the exported member. Shares the
            // unified resolver so a namespace-import qualifier over a plain
            // named-export module works, not just `export =` namespaces.
            const d = c.tree.nodeData(node);
            const container = (try c.resolveNsContainer(d.lhs)) orelse return null;
            return c.containerMemberSym(container, try c.memberAtom(d.rhs));
        },
        else => return null,
    }
}

/// When a class `extends <expr>` and `<expr>` is a *value* (not a class
/// symbol) whose type carries construct signatures — the
/// `declare const Base: { new (input): R }` mixin-base pattern, e.g. the
/// AWS-SDK Smithy `class XCommand extends XCommand_base` where the base
/// const's type has a `new(input)` signature — returns that base
/// constructor object type (resolved structurally). The derived class then
/// inherits both the construct signature (for `new Derived(args)`) and the
/// signature's return type as its base instance. Null when there is no
/// extends clause, the base resolves to a class symbol (handled by
/// `baseClassRef`), or the base value has no construct signatures.
pub fn baseExprConstructType(c: *Checker, sym: SymbolId) Error!?TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        if (data.extends == 0) return null;
        const hd = c.tree.nodeData(data.extends);
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        // A class-symbol base is `baseClassRef`'s job; skip it here.
        if (try c.classBaseEntitySym(hd.lhs)) |bs| {
            if (c.symFlags(bs).class) return null;
        }
        const bt = try c.resolveStructural(try c.checkExprCached(hd.lhs, types.no_type));
        if (c.ts.kind(bt) == .object and c.ts.objectConstructSigCount(bt) > 0) return bt;
        return null;
    }
    return null;
}

/// The declaration symbol behind an import target: a direct binding, or —
/// for a whole-module (`import * as X`) target — the module's `export =`
/// entity when it is a symbol (namespace/class), which is how `X.Member`
/// reaches into `export = X`-style packages. Null otherwise.
pub fn importedContainerSym(c: *Checker, tgt0: modules.Target) ?SymbolId {
    // The declaration behind a dual binding is its type half (the member of
    // the export-assigned entity); the value half is a property, not a symbol.
    const tgt = c.typeMeaningTarget(tgt0);
    switch (tgt.kind) {
        .binding => return c.toGlobalIn(tgt.file, tgt.payload),
        .namespace => {
            if (c.prog.links.len == 0) return null;
            const eq = c.prog.links[tgt.file].exportTarget(c.prog.export_equals_atom) orelse return null;
            return c.targetTypeSym(eq);
        },
        .ambient_ns => {
            const eq = c.moduleExportTarget(.{ .ambient = tgt.payload }, c.prog.export_equals_atom) orelse return null;
            return c.targetTypeSym(eq);
        },
        else => return null,
    }
}

/// Whether a class symbol is declared `abstract`.
pub fn classIsAbstract(c: *Checker, sym: SymbolId) Error!bool {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        return data.flags & ast.Flags.abstract != 0;
    }
    return false;
}

/// Does one of `bases` — the extra base types a class picks up from its
/// same-file `interface` half — supply a declaration of `name` that
/// satisfies an inherited abstract member? tsc compares declaration symbols
/// (`derivedElsewhere !== base`); ztsc's resolved objects carry no symbol
/// identity, so the equivalent question is "present in that base, and not
/// itself a still-abstract class member" — only a class can declare one, so
/// an interface base that has the name always satisfies.
pub fn abstractSatisfiedElsewhere(c: *Checker, bases: []const TypeId, name: Atom) Error!bool {
    for (bases) |b| {
        const r = try c.resolveStructural(b);
        if ((try c.propOfType(r, name)) == null) continue;
        if (try c.classChainMemberIsAbstract(b, name, 0)) continue;
        return true;
    }
    return false;
}

/// Walking a class ref's own members and then its `extends` chain: is
/// `name` declared there and still `abstract`? A non-class base answers
/// false.
pub fn classChainMemberIsAbstract(c: *Checker, t: TypeId, name: Atom, depth: u32) Error!bool {
    if (depth >= 64 or c.ts.kind(t) != .ref) return false;
    const sym = c.ts.refSymbol(t);
    if (!c.symFlags(sym).class) return false;
    {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                if (c.bind.member_atoms[i] != name) continue;
                return c.memberIsAbstract(c.toGlobal(c.bind.member_syms[i]));
            }
        }
    }
    const nb = try c.baseClassRef(sym) orelse return false;
    return c.classChainMemberIsAbstract(nb, name, depth + 1);
}

/// Whether a class member symbol's declaration is `abstract`.
pub fn memberIsAbstract(c: *Checker, msym: SymbolId) bool {
    for (c.declsOf(msym)) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .class_method => {
                const proto = c.tree.extraData(ast.FnProto, d.lhs);
                if (proto.flags & ast.Flags.abstract != 0) return true;
            },
            .class_field => {
                const f = c.tree.extraData(ast.Field, d.lhs);
                if (f.flags & ast.Flags.abstract != 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// A concrete class extending an abstract one must implement every
/// still-abstract inherited member. One missing member → TS2515; two or
/// more → the aggregate TS2654. Both point at the derived class name.
pub fn checkAbstractImplementation(c: *Checker, class_sym: SymbolId, class_node: Node) Error!void {
    if (try c.classIsAbstract(class_sym)) return;
    const base_ref = try c.baseClassRef(class_sym) orelse return;
    const direct_base = c.ts.refSymbol(base_ref);

    // Names the derived class (and any concrete override on the way up)
    // provides; walking most-derived first, the first declaration of each
    // name wins. The derived class itself is concrete, so all its members
    // count as implementations.
    var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
    defer seen.deinit(c.scratch());
    try c.collectClassMemberAtoms(class_sym, &seen);

    // Same-file class+interface declaration merge. The interface half's
    // DECLARED members are part of the one merged member table, so they
    // implement the abstract member outright; its `extends` clauses are
    // extra base types of the merged declared type, which tsc searches for
    // a satisfying declaration ("The class may have more than one base type
    // via declaration merging with an interface with the same name" —
    // `checkKindsOfPropertyMemberOverrides`). drizzle's `PgSelectBase` is
    // exactly this: `interface PgSelectBase extends …, SQLWrapper` supplies
    // the `getSQL` its abstract `TypedQueryBuilder` base leaves open, while
    // the MySQL/SQLite twins — whose interface halves do NOT extend
    // `SQLWrapper` — still report.
    var iface_bases: std.ArrayList(TypeId) = .empty;
    defer iface_bases.deinit(c.scratch());
    if (!c.prog.isMergedId(class_sym) and c.symFlags(class_sym).interface) {
        const saved = c.enterSymFile(class_sym);
        defer c.restoreCtx(saved);
        const direct = try c.interfaceConstituentDirect(class_sym, class_sym);
        if (c.ts.kind(direct) == .object) {
            for (0..c.ts.objectPropCount(direct)) |i| {
                try seen.put(c.scratch(), c.ts.objectProp(direct, @intCast(i)).name, {});
            }
        }
        try c.interfaceHeritageTypes(class_sym, &iface_bases);
    }

    var unimpl: std.ArrayList(Atom) = .empty;
    defer unimpl.deinit(c.scratch());

    var cur = direct_base;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        {
            const saved = c.enterSymFile(cur);
            defer c.restoreCtx(saved);
            if (c.bind.membersScopeOf(c.localOf(cur))) |ms| {
                const lo = c.bind.scope_members_start[ms];
                const hi = c.bind.scope_members_start[ms + 1];
                // Collect this base's unimplemented members in source
                // order (scope-member order is name-bucketed, not
                // declaration order) so the TS2654 list matches tsc.
                const Unimpl = struct { atom: Atom, start: u32 };
                var batch: std.ArrayList(Unimpl) = .empty;
                defer batch.deinit(c.scratch());
                for (lo..hi) |i| {
                    const name_atom = c.bind.member_atoms[i];
                    if (isCtorName(c, name_atom)) continue;
                    if (seen.contains(name_atom)) continue;
                    try seen.put(c.scratch(), name_atom, {});
                    const local_sym = c.bind.member_syms[i];
                    const msym = c.toGlobal(local_sym);
                    if (c.memberIsAbstract(msym)) {
                        if (try c.abstractSatisfiedElsewhere(iface_bases.items, name_atom)) continue;
                        const decls = c.bind.declsOf(local_sym);
                        const start = if (decls.len > 0) c.nodeSpan(decls[0]).start else 0;
                        try batch.append(c.scratch(), .{ .atom = name_atom, .start = start });
                    }
                }
                std.mem.sort(Unimpl, batch.items, {}, struct {
                    fn lessThan(_: void, x: Unimpl, y: Unimpl) bool {
                        return x.start < y.start;
                    }
                }.lessThan);
                for (batch.items) |u| try unimpl.append(c.scratch(), u.atom);
            }
        }
        const nb = try c.baseClassRef(cur) orelse break;
        cur = c.ts.refSymbol(nb);
    }

    if (unimpl.items.len == 0) return;
    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(class_node).lhs);
    const span = c.tokSpan(data.name_token);
    const class_name = c.symbolName(class_sym);
    const base_name = c.symbolName(direct_base);
    if (unimpl.items.len == 1) {
        try c.diagFmt(2515, span, "Non-abstract class '{s}' does not implement inherited abstract member {s} from class '{s}'.", .{
            class_name, c.atomText(unimpl.items[0]), base_name,
        });
    } else {
        var names: std.Io.Writer.Allocating = .init(c.scratch());
        defer names.deinit();
        for (unimpl.items, 0..) |m, i| {
            if (i > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
            names.writer.print("'{s}'", .{c.atomText(m)}) catch return error.OutOfMemory;
        }
        try c.diagFmt(2654, span, "Non-abstract class '{s}' is missing implementations for the following members of '{s}': {s}.", .{
            class_name, base_name, names.written(),
        });
    }
}

/// Record every member-name of a class (instance and static) into `seen`.
pub fn collectClassMemberAtoms(c: *Checker, sym: SymbolId, seen: *std.AutoHashMapUnmanaged(Atom, void)) Error!void {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    const local = c.localOf(sym);
    inline for (.{ c.bind.membersScopeOf(local), c.bind.staticsScopeOf(local) }) |maybe_scope| {
        if (maybe_scope) |ms| {
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| try seen.put(c.scratch(), c.bind.member_atoms[i], {});
        }
    }
}
