//! Nominal declaration shapes: what an `interface` and a `class` instance ARE,
//! and everything the `extends` graph implies about them.
//!
//! One member table per declaration set, folded in a fixed order — own
//! members, then the declaration-merged `interface` half, then the bases — so
//! the table is a function of the DECLARATIONS rather than of the order they
//! were demanded in. `interfaceGeneric` and `classInstanceGeneric` are that
//! fold; the rest of the file is what it needs:
//!
//!   * heritage resolution — `interfaceHeritageTypes`, `baseClassRef` /
//!     `baseClassSym` / `classBaseEntitySym` for a named base, and
//!     `baseExprConstructType` for a mixin / constructor-valued one;
//!   * the merge primitives `mergeBaseResolved` / `mergeBaseObjectPlain` /
//!     `unionCallableSigs` / `carryKeyNameTypes` (derived members win, and a
//!     callable member accumulates overloads across merged declarations);
//!   * cycle and completeness bookkeeping — `emitBaseCycle` for a genuine
//!     TS2310, and `classTableProvisional` / `baseRefProvisional` /
//!     `baseRefCut` to keep a table folded across a cut OUT of the memo;
//!   * the lazy single-member lookups (`lazyRefProp`, `lazyThisProp`,
//!     `classChainMemberType`) and the declaration-only key walk
//!     (`declaredKeyUnion`), which answer one question INSIDE an in-progress
//!     fold instead of taking the cycle cut;
//!   * the `abstract` rules, ending in `checkAbstractImplementation`.
//!
//! `stmts.checkClass` — the per-declaration checks — is deliberately not here;
//! this file answers what a declaration MEANS, not whether it is well-formed.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const member_names = @import("../frontend/member_names.zig");
const types = @import("../types.zig");
const modules = @import("../link/modules.zig");

const Allocator = std.mem.Allocator;
const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const prof_zig = checker_zig.prof_zig;

const accessibility = @import("accessibility.zig");
const TpMap = @import("enums.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;

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
    prof_zig.declAsk(c, sym, .iface, sym);
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
    const dwin = prof_zig.declEnter(c, sym, .iface, prof_zig.dupKey(.iface, sym));
    defer prof_zig.declExit(c, dwin);

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
    //
    // WAVE-26 DETERMINISM FINDING (agent D): this loop walks `parts` in
    // MERGE order, which the linker builds by walking files in file-id order
    // (`eachGlobalDecl`), which `--file-order` permutes. Where two
    // constituents contribute CONFLICTING inherited index signatures the
    // first one wins (`mergeBaseResolved` keeps the accumulator's), so the
    // answer moves with the root order. Measured on social-app: `ProcessEnv`
    // is `@types/node`'s `extends Dict<string>` merged with expo's
    // `extends ExpoProcessEnv`, whose string index is `any`. Source order
    // folds `Dict<string>` first and every `process.env.X` reads
    // `string | undefined`; `--file-order=reverse` (and shuffle=3) folds the
    // expo half first and every `process.env.X` reads `any` — which is then
    // frozen into `iface_generic` and into the `sym_types` of the three
    // `export const …_DEV_URL = process.env.…` bindings, so the two
    // `src/env/common.ts` TS2322s vanish for the rest of the run.
    //
    // tsc has the same first-base-wins rule, so the fix is not here: it is
    // that `parts` must not be a function of the ROOT ORDER. That means a
    // canonical constituent order in `src/link/modules.zig` (by file PATH,
    // not by file id), which was out of this agent's edit surface.
    for (parts) |csym| {
        if (!c.symFlags(csym).interface) continue;
        result = try c.interfaceConstituentApplyBases(csym, result, owner);
    }
    try recordSigGroups(c, parts, result, .call_signature);
    try recordSigGroups(c, parts, result, .construct_signature);
    try c.iface_generic.put(c.cm(), sym, result);
    return result;
}

/// Record where each `interface` DECLARATION's call (or construct) signatures
/// start in the generic table's corresponding signature list, for
/// `appendObjectCallCandidates` / `appendObjectConstructCandidates` — tsc's
/// `reorderCandidates` groups a callable type's signatures by
/// `signature.declaration.parent`, and an interface reopened twice is two
/// parents even though it is one symbol.
///
/// `mergeBaseObject` appends the DERIVED object's signatures before the base's
/// and `interfaceGeneric` folds the constituents' direct members before any
/// `extends`, so the declarations' own signatures are a contiguous prefix of
/// `result`'s signature list, in declaration order. The recorded value is
/// `groups + 1` ascending offsets — group `i` is `[bounds[i], bounds[i + 1])`
/// and the last entry is the end of that prefix, so the inherited remainder is
/// identifiable without re-deriving it. Nothing is recorded unless at least two
/// declarations contribute a signature, which is what makes the order
/// observable at all.
///
/// The two signature kinds are counted and stored separately because they are
/// separate lists on the object: `MapConstructor` reopened by
/// lib.es2015.iterable is two construct groups and zero call groups.
fn recordSigGroups(c: *Checker, parts: []const SymbolId, result: TypeId, want: ast.Tag) Error!void {
    if (c.ts.kind(result) != .object) return;
    const n = if (want == .call_signature) c.ts.objectCallSigCount(result) else c.ts.objectConstructSigCount(result);
    if (n < 2) return;
    var bounds: std.ArrayList(u32) = .empty;
    defer bounds.deinit(c.scratch());
    var total: u32 = 0;
    for (parts) |csym| {
        if (!c.symFlags(csym).interface) continue;
        const saved_ctx = c.enterSymFile(csym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(csym)) |decl| {
            if (c.nodeTag(decl) != .interface_decl) continue;
            const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
            var cnt: u32 = 0;
            for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
                if (m != null_node and c.nodeTag(m) == want) cnt += 1;
            }
            if (cnt == 0) continue;
            try bounds.append(c.scratch(), total);
            total += cnt;
        }
    }
    if (bounds.items.len < 2 or total > n) return;
    try bounds.append(c.scratch(), total);
    const at: u32 = @intCast(c.overload_group_pool.items.len);
    try c.overload_group_pool.appendSlice(c.cm(), bounds.items);
    const dst = if (want == .call_signature) &c.overload_groups else &c.construct_groups;
    try dst.put(c.cm(), result, .{ .start = at, .len = @intCast(bounds.items.len) });
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
            var target: SymbolId = binder.no_symbol;
            const base = try c.typeFromTypeNameEx(hd.lhs, targs.items, &target);
            // `interface I extends G<Bad>` is the same written list as
            // `class D extends G<Bad>` (see `baseClassRef`) and the same gate.
            // Every caller enters `sym`'s own file first, which is what makes
            // the clause node index `c.tree` and the queue attribute the
            // diagnostic to the declaring file.
            if (target != binder.no_symbol) {
                try c.queueTypeArgConstraints(h, target, targs.items);
            }
            try out.append(c.scratch(), base);
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
    // `interface X extends C` where `C` names a class VALUE — always through a
    // `typeof` alias, since a bare class name in an `extends` denotes its
    // INSTANCE. The value's members live on its static-side object, which
    // `resolveStructural` does not unwrap to, so the object-only guard dropped
    // the base whole. The lib is the case in point: `interface
    // IteratorConstructor extends IteratorObjectConstructor`, with
    // `type IteratorObjectConstructor = typeof Iterator` over the abstract
    // class, lost its `new ()` — so `new Iterator<number>()` was a false
    // TS2351 and `class C extends Iterator<number>` a false TS2507.
    if (c.ts.kind(base) == .class_value) {
        return c.mergeBaseObject(derived, try c.classConstructType(c.ts.classSymbol(base)), false);
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

/// The index signatures one half of a class body declares. 0 = none.
///
/// A `symbol`-keyed signature shares the `str` slot — the whole type store
/// models it that way (`obj_flag_symbol_index`) — so `sym_only` is what tells
/// the two apart, and `objFlags` folds it back into the flag word every
/// `makeObject` caller has to pass anyway.
pub const ClassIndexInfos = struct {
    str: TypeId = 0,
    num: TypeId = 0,
    /// The `str` slot holds a `[k: symbol]` signature and nothing else claims
    /// the domain — the exact condition `typenode`'s interface/type-literal
    /// builder sets `obj_flag_symbol_index` on.
    sym_only: bool = false,
    /// `readonly` on whichever signature claimed each slot — tsc's
    /// `IndexInfo.isReadonly`. `class C { static readonly [s: string]: number }`
    /// makes `C.foo = 1` TS2542.
    str_readonly: bool = false,
    num_readonly: bool = false,

    /// `base` plus the symbol-index and readonly-index flags this half earned.
    pub fn objFlags(i: ClassIndexInfos, base: u32) u32 {
        var f = base;
        if (i.sym_only) f |= types.obj_flag_symbol_index;
        if (i.str_readonly and i.str != 0) f |= types.obj_flag_readonly_string_index;
        if (i.num_readonly and i.num != 0) f |= types.obj_flag_readonly_number_index;
        return f;
    }
};

/// The index signatures written in a class BODY. tsc resolves
/// `[k: string]: T` onto the INSTANCE side and `static [k: string]: T` onto
/// the class value's own type (`resolveClassOrInterfaceMembers` reads the
/// declarations of whichever half it is building), so `statics` picks the
/// half. Only this class's own declarations are read: an inherited signature
/// arrives through the heritage merge, which already prefers the derived
/// one (`mergeBaseObjectPlain`).
///
/// Without this a class body's index signature was dropped entirely — every
/// `C['f']` on a class declaring `[s: string]: number` was a false TS7053,
/// and `D[42]` through a base's `static [s: number]:` answered `any`.
pub fn classIndexInfos(c: *Checker, sym: SymbolId, statics: bool) Error!ClassIndexInfos {
    var out: ClassIndexInfos = .{};
    // Which of the two writers of the shared `str` slot won, decided once at
    // the end: a `[k: string]` signature written alongside a `[k: symbol]` one
    // takes the domain back, and either of them may come first in the body.
    var str_index = false;
    var sym_index = false;
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    // The member scope's parent chain carries the class's type parameters,
    // which an instance-side value type may name (`[k: string]: T`).
    if (c.bind.membersScopeOf(c.localOf(sym))) |ms| c.cur_scope = ms;
    for (c.declsOf(sym)) |decl| {
        // `.class_decl` covers class expressions too (one tag).
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .index_signature) continue;
            const md = c.tree.nodeData(m);
            if ((md.rhs & ast.Flags.static != 0) != statics) continue;
            const e = c.tree.extraData(ast.IndexSig, md.lhs);
            const key = try c.typeFromTypeNode(e.key_type);
            const val = try c.typeFromTypeNode(e.value_type);
            const ro = md.rhs & ast.Flags.readonly != 0;
            if (key == types.number_type) {
                out.num = val;
                out.num_readonly = ro;
            } else if (key == types.string_type) {
                str_index = true;
                out.str = val;
                out.str_readonly = ro;
            } else if (key == types.symbol_type) {
                sym_index = true;
                out.str = val;
                out.str_readonly = ro;
            }
        }
    }
    out.sym_only = sym_index and !str_index and out.num == 0;
    return out;
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
///
/// The PLAIN merge: object-in, object-out, with no view on what a
/// non-object base means. Every caller in this file — and `Checker`'s
/// `mergeBaseObject` alias — goes through `typenode.mergeBaseObject`, the
/// any-base-aware wrapper that delegates here for the ordinary case.
pub fn mergeBaseObjectPlain(c: *Checker, derived: TypeId, base: TypeId, union_overloads: bool) Error!TypeId {
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
    const merged_flags = mergedIndexFlags(c, derived, base, nidx);
    // Preserve call/construct signatures from both sides: a callable
    // interface extending another accumulates every signature.
    if (!c.ts.objectHasSigs(derived) and !c.ts.objectHasSigs(base)) {
        const m = try c.ts.makeObject(props.items, sidx, nidx, merged_flags & ~types.obj_flag_has_sigs);
        try c.carryKeyNameTypes(m, &.{ derived, base });
        return m;
    }
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var constructs: std.ArrayList(TypeId) = .empty;
    defer constructs.deinit(c.scratch());
    for ([2]TypeId{ derived, base }) |o| {
        for (0..c.ts.objectCallSigCount(o)) |i| try calls.append(c.scratch(), c.ts.objectCallSig(o, @intCast(i)));
        for (0..c.ts.objectConstructSigCount(o)) |i| try constructs.append(c.scratch(), c.ts.objectConstructSig(o, @intCast(i)));
    }
    const merged = try c.ts.makeObjectSigs(props.items, sidx, nidx, merged_flags & ~types.obj_flag_has_sigs, calls.items, constructs.items);
    try c.carryKeyNameTypes(merged, &.{ derived, base });
    return merged;
}

/// `derived`'s flag word, corrected for the one flag the index merge above can
/// change: `obj_flag_symbol_index`.
///
/// The flag says "the string slot holds a `[k: symbol]` signature, and nothing
/// else claims the key domain", so it belongs to whichever side actually
/// supplied the slot. A derived class that declares no index of its own and
/// inherits a base's symbol signature (`class D extends C {}` where `C` writes
/// `[s: symbol]: V`) would otherwise read that value type back as a STRING
/// index — turning every inherited member into an index-signature violation.
fn mergedIndexFlags(c: *const Checker, derived: TypeId, base: TypeId, nidx: TypeId) u32 {
    var flags = c.ts.objectFlags(derived);
    // Each slot's `readonly` bit follows whichever side SUPPLIED the slot: an
    // inherited `readonly [k: string]` is still readonly on the derived shape
    // (`interface B extends A {}` — TS2542 on `b.x = 1`). The derived object's
    // own bit is only ever set alongside its own slot, so nothing spurious
    // survives when the base wins.
    if (c.ts.objectStringIndex(derived) == 0 and
        c.ts.objectFlags(base) & types.obj_flag_readonly_string_index != 0)
        flags |= types.obj_flag_readonly_string_index;
    if (c.ts.objectNumberIndex(derived) == 0 and
        c.ts.objectFlags(base) & types.obj_flag_readonly_number_index != 0)
        flags |= types.obj_flag_readonly_number_index;
    if (c.ts.objectStringIndex(derived) != 0) return flags;
    const from_base = c.ts.objectFlags(base) & types.obj_flag_symbol_index != 0;
    // A number index — from either side — takes the domain back.
    if (from_base and nidx == 0) return flags | types.obj_flag_symbol_index;
    return flags & ~types.obj_flag_symbol_index;
}

/// Carry `key_name_types` entries from the tables an object was BUILT from
/// onto the object itself (see `Checker.key_name_types`). A member declared
/// with a computed enum key is keyed by the member's VALUE and only NAMED by
/// the enum member, and the naming lives in a side table against the interned
/// object — so every place that re-interns a table (heritage folding, a
/// homomorphic map over it) has to bring the names along or the enum identity
/// is silently lost. `interface M extends Record<E, V>` was exactly that: the
/// base materialized enum-named keys, the merge interned a fresh object, and
/// `keyof M` came back a plain string union again.
///
/// `from` is searched in order, so a derived member's own name type wins over
/// an inherited one. No-op for the overwhelming majority of objects, which
/// have no such key.
pub fn carryKeyNameTypes(c: *Checker, out: TypeId, from: []const TypeId) Error!void {
    if (c.key_name_types.count() == 0) return;
    if (c.ts.kind(out) != .object) return;
    for (0..c.ts.objectPropCount(out)) |i| {
        const name = c.ts.objectProp(out, @intCast(i)).name;
        const key = (@as(u64, out) << 32) | name;
        if (c.key_name_types.contains(key)) continue;
        for (from) |src| {
            if (c.ts.kind(src) != .object) continue;
            if (c.key_name_types.get((@as(u64, src) << 32) | name)) |nt| {
                try c.putKeyNameType(out, name, nt);
                break;
            }
        }
    }
}

/// Generic instance shape of a class: instance members + base instance.
pub fn classInstanceGeneric(c: *Checker, sym0: SymbolId) Error!TypeId {
    // A class a cross-file `declare module "pkg" { interface C { … } }`
    // augmentation merged into keeps its FULL table under the merged id —
    // that is where the interface constituents are folded, below. A
    // reference that arrived as `ref(<class>)` rather than `ref(<merged>)`
    // must see the same table: type positions route through
    // `Program.mergedOf` already, but a VALUE position never does
    // (`new C()`, `extends C`, the return of a `typeof C` construct
    // signature all build the instance ref from the class symbol itself).
    // Without this the augmented and un-augmented views of one class are two
    // different shapes, and assigning between them is a phantom TS2739 —
    // outline augments `prosemirror-inputrules`' `InputRule` with its
    // `@internal` `match`/`handler`/`undoable` and hits exactly that.
    const sym = c.prog.mergedOf(sym0) orelse sym0;
    prof_zig.declAsk(c, sym, .class, sym);
    if (c.class_inst_generic.get(sym)) |t| {
        if (t == types.no_type) return types.error_type;
        return t;
    }
    try c.class_inst_generic.put(c.cm(), sym, types.no_type);
    const dwin = prof_zig.declEnter(c, sym, .class, prof_zig.dupKey(.class, sym));
    defer prof_zig.declExit(c, dwin);
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
    // fail assignment to `{[k:string]:T}`) — but a body that WRITES one has
    // it (`class C { [k: string]: number }`).
    const own_index = try classIndexInfos(c, sym, false);
    var result: TypeId = try c.ts.makeObject(&.{}, own_index.str, own_index.num, own_index.objFlags(types.obj_flag_not_inferable));
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
            if (mf.optional_member or memberIsOptionalParamProperty(c, msym)) flags |= types.prop_flag_optional;
            if (mf.readonly_member) flags |= types.prop_flag_readonly;
            // A get-only accessor is a read-only property (TS2540 on write).
            if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
            flags |= visibilityPropFlags(c, msym, mf.non_public);
            if (mf.method or mf.getter or mf.setter) flags |= types.prop_flag_class_fn;
            try props.append(c.scratch(), .{
                .name = name,
                .ty = try c.memberTypeOf(msym),
                .flags = flags,
            });
        }
        result = try c.ts.makeObject(props.items, own_index.str, own_index.num, own_index.objFlags(types.obj_flag_not_inferable));
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
    // Merge base class instance. A base this checker cannot see completely
    // right now resolves to `err`, which `mergeBaseObject`'s object-only guard
    // drops — the derived instance then silently loses EVERY inherited member.
    // The fold still cuts (there is nothing else it could do mid-cycle), but
    // the incomplete table it produced is marked provisional so it is never
    // memoized. `baseRefCut` decides; see there for the three ways a base cuts.
    if (try c.baseClassRef(sym)) |base_ref| {
        const bstruct = try c.resolveStructural(base_ref);
        result = try c.mergeBaseObject(result, bstruct, false);
        if (c.baseRefProvisional(base_ref)) provisional = true;
        if (c.ts.kind(bstruct) == .err and c.baseRefCut(base_ref)) provisional = true;
    } else if (try c.baseExprConstructType(sym)) |base_ctor| {
        // `extends <value with construct signatures>`: the base instance is
        // the construct signature's return type — and when the base is an
        // INTERSECTION of constructors (every mixin, including react-native's
        // `Constructor<NativeMethods> & typeof ViewComponent`) it is the
        // intersection of ALL of their returns, not just the first's.
        // Overloads of one constructor all return the same instance, so this
        // is a no-op for the single-base case.
        for (0..c.ts.objectConstructSigCount(base_ctor)) |i| {
            const ret = c.ts.fnReturn(c.ts.objectConstructSig(base_ctor, @intCast(i)));
            const rstruct = try c.resolveStructural(ret);
            result = try c.mergeBaseObject(result, rstruct, false);
            if (c.ts.kind(rstruct) == .err and (c.baseRefProvisional(ret) or c.baseRefCut(ret))) provisional = true;
        }
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
    if (iface_half) {
        const half = try c.classInterfaceHalfBases(sym, result);
        result = half.ty;
        if (half.provisional) provisional = true;
    }
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
pub fn classTableProvisional(c: *Checker, sym0: SymbolId) bool {
    // Same normalization `classInstanceGeneric` applies: an augmented class's
    // table is memoized under the merged id, and asking about the raw one
    // must read that entry rather than report a permanent "provisional".
    const sym = c.prog.mergedOf(sym0) orelse sym0;
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

/// A base folded to `err`: was that a CUT — a fact about this checker's
/// current stack — rather than a fact about the base itself?
///
/// A GENERIC base has two independent memos on the way to its member table,
/// and `classTableProvisional` only watches the first. `class_inst_generic`
/// holds the un-substituted table (`classInstanceGeneric`); `expansions` holds
/// the substitution of it for one argument list (`expandRef`). Either can be
/// the frame we are nested inside, and either cuts to `err`:
///
///   * the base class's own generic table is still materializing further down
///     the stack — `baseRefProvisional`, checked by the caller;
///   * that table is COMPLETE, but substituting THESE type arguments into it
///     is a frame we are nested inside, so `expansions[base_ref]` is still
///     the in-progress marker. outline's `class CollectionsStore extends
///     Store<Collection>` is exactly this shape: `Store`'s generic table is
///     long finished, and materializing `Store<Collection>` is what re-entered
///     `CollectionsStore`, so `classTableProvisional(Store)` truthfully says
///     "complete" while `Store<Collection>` answers `err`. Every one of
///     `CollectionsStore`'s 40-odd inherited members — `add`, `fetch`,
///     `rootStore`, `isLoaded` — was dropped and the 24-member remainder
///     memoized for the rest of the run;
///   * the substitution ran out of budget inside THIS budget window
///     (`trunc_expansions`) — `expandRef` withdraws its own memo for that and
///     the same reasoning applies one level up.
///
/// Only consulted when the base actually resolved to `err`, so a base that is
/// legitimately non-object (an `any` mixin, an intersection) is untouched, and
/// a class whose base is permanently unresolvable still memoizes its table
/// rather than rebuilding it on every property access.
pub fn baseRefCut(c: *Checker, base_ref: TypeId) bool {
    if (c.ts.kind(base_ref) != .ref) return false;
    if (c.expansions.get(base_ref)) |e| return e == types.no_type;
    if (c.trunc_expansions.get(base_ref)) |epoch| return epoch == c.budget_epoch;
    return false;
}

/// The folded table plus whether folding it hit an incomplete base — see
/// `classInterfaceHalfBases` and the invariant on `classTableProvisional`.
pub const HalfBases = struct { ty: TypeId, provisional: bool };

/// Fold the `extends` bases written on a class's same-file `interface` half
/// into its instance type; members already in `acc` (the class's own and the
/// interface half's declared members, plus the class's `extends` base) win.
/// A class base among them that could not be folded completely answers
/// `provisional`, exactly as the class's own `extends` base does.
pub fn classInterfaceHalfBases(c: *Checker, sym: SymbolId, acc: TypeId) Error!HalfBases {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    try c.interfaceHeritageTypes(sym, &bases);
    var own = acc;
    var provisional = false;
    for (bases.items) |b| {
        const rb = try c.resolveStructural(b);
        own = try c.mergeBaseResolved(own, rb);
        if (c.baseRefProvisional(b)) provisional = true;
        if (c.ts.kind(rb) == .err and c.baseRefCut(b)) provisional = true;
    }
    return .{ .ty = own, .provisional = provisional };
}

/// The symbol a class-like node declares — the one every SymbolId-keyed view
/// of the class is filed under (`classInstanceGeneric`, `classStaticType`,
/// `baseClassRef`, the member and static scopes).
///
/// Where it lives depends on the form, and the two places must both be asked:
///
///   * a class DECLARATION names itself in the ENCLOSING scope, so
///     `outer_scope` finds it;
///   * a class EXPRESSION does not. Its self-name — or, when it has no name,
///     `member_names.class_expr_name` — is declared in the class's OWN scope
///     instead (`Binder.bindClass`), which is also where the binder hangs the
///     member and static tables.
///
/// Asking only the enclosing scope answered `no_symbol` for every class
/// expression, named ones included: no `this` type inside the body, no member
/// checks, and `any` for the expression itself.
pub fn classSymbolOf(c: *Checker, node: Node, outer_scope: binder.ScopeId) Error!SymbolId {
    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(node).lhs);
    if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(outer_scope, a)) |sym| {
            if (c.bind.symbol_flags[sym].class) return c.toGlobal(sym);
        }
        const cs = try c.scopeOf(node) orelse return binder.no_symbol;
        if (c.bind.lookupInScope(cs, a)) |sym| {
            if (c.bind.symbol_flags[sym].class) return classExprSym(c, c.toGlobal(sym));
        }
        return binder.no_symbol;
    }
    // Nameless: only the reserved key, and only in the class's own scope.
    // Interning the reserved text here cannot mint a new atom — reaching this
    // line means the binder already declared the symbol under it.
    const cs = try c.scopeOf(node) orelse return binder.no_symbol;
    const a = try c.atom(member_names.class_expr_name);
    if (c.bind.lookupInScope(cs, a)) |sym| {
        if (c.bind.symbol_flags[sym].class) return classExprSym(c, c.toGlobal(sym));
    }
    return binder.no_symbol;
}

/// A class EXPRESSION's symbol, withdrawn when its `extends` base resolves to
/// nothing at all.
///
/// The symbol buys the checker a member table, a `this` type and a `typeof C`
/// — all of which are WRONG when the base is invisible, because everything the
/// base contributes is simply missing from them. Every `this.<inherited>` is
/// then a TS2339 about ztsc's gap rather than about the code, which is the
/// same reasoning `hasUnresolvedBase` already encodes for the "does not
/// implement" verdicts. `class extends React.PureComponent<P, void>` is the
/// live case: `declare module "react" { export = __React }` does not link, so
/// the base is `any` and `this.props` inside the class expression became a
/// false TS2339 (`tsxGenericAttributesType9`).
///
/// Narrower than `hasUnresolvedBase`, which asks about the whole chain and
/// counts a mixin's constructor-valued base as unresolved: a mixin base IS
/// resolvable (`baseExprConstructType`), and typing those classes is the
/// entire point. Only a class expression is withdrawn; a class DECLARATION
/// with an invisible base keeps whatever it reports today.
fn classExprSym(c: *Checker, sym: SymbolId) Error!SymbolId {
    var has_extends = false;
    {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            if (c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs).extends != 0) {
                has_extends = true;
                break;
            }
        }
    }
    if (!has_extends) return sym;
    if (try baseClassRef(c, sym) != null) return sym;
    if (try baseExprConstructType(c, sym) != null) return sym;
    return binder.no_symbol;
}

/// Is this member-table key the class's constructor? The constructor is keyed
/// under a reserved name (`member_names.ctor_member_name`) precisely so that no
/// source-spelled member can answer yes — `constructor(public constructor: T)`
/// declares a parameter property whose key IS the text `constructor`, and it is
/// an ordinary member.
pub fn isCtorName(c: *Checker, name: Atom) bool {
    return std.mem.eql(u8, c.atomText(name), member_names.ctor_member_name);
}

/// The same question asked of a member DECLARATION rather than of a key — for
/// the sites that have the `.class_method` node in hand and no member table
/// (`checkMemberOverrides`, the method-body walk, the decorator target). Before
/// the reserved key existed these compared the name atom's text, which now
/// answers no for the constructor and yes for a parameter property of that
/// name — exactly backwards.
pub fn isCtorMember(c: *Checker, member: ast.Node, flags: u32) bool {
    return member_names.isCtorMethod(c.tree, member, flags);
}

/// TS1187, tsc's grammar check on a constructor's parameter list: a parameter
/// property DECLARES a class member, and a member needs one name — a binding
/// pattern names several (or none), so the two spellings cannot combine.
///
/// The binder already declares the member for the identifier spelling only
/// (`bindParam` gates on `.identifier`), so a pattern-named parameter
/// property declares nothing either way; this is the diagnostic that says so.
/// Blamed on the PARAMETER, whose `main_token` is its first — the modifier
/// itself, which is where tsc's parameter-node span starts.
pub fn checkCtorParamPropertyPatterns(c: *Checker, proto: ast.FnProto) Error!void {
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        if (pn == null_node or c.nodeTag(pn) != .param_full) continue;
        const d = c.tree.nodeData(pn);
        const e = c.tree.extraData(ast.ParamFull, d.rhs);
        if (e.flags & member_names.param_property_mask == 0) continue;
        switch (c.nodeTag(d.lhs)) {
            .array_pattern, .object_pattern => {},
            else => continue,
        }
        try c.diagFmt(1187, c.tokSpan(c.tree.nodeMainToken(pn)), "A parameter property may not be declared using a binding pattern.", .{});
    }
}

/// Ceiling on the `extends` walk in `lazyRefProp`. A base chain is already
/// acyclic by construction (a cyclic `extends` is a bind error), but the
/// lazy path runs *inside* an in-progress materialization where the usual
/// caches are unavailable, so it carries its own belt.
pub const lazy_base_depth: u32 = 16;

/// Is `sym`'s class member table being materialized further down this
/// checker's stack? `classInstanceGeneric` marks in-progress with `no_type`,
/// and answers `error_type` — a cut, not a result — for the whole window.
pub fn classGenericInProgress(c: *Checker, sym0: SymbolId) bool {
    // The merged id is the one `classInstanceGeneric` marks (see there).
    const sym = c.prog.mergedOf(sym0) orelse sym0;
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

/// Is `msym`'s own type already being computed further down this stack?
/// `memberTypeOf` pushes each member it resolves onto `member_type_stack` and
/// reports the circle when it is re-entered.
fn memberTypeInFlight(c: *Checker, msym: SymbolId) bool {
    for (c.member_type_stack.items) |m| {
        if (m == msym) return true;
    }
    return false;
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
pub fn lazyRefProp(c: *Checker, ref: TypeId, name: Atom) Error!?types.Prop {
    return lazyRefPropRec(c, ref, name, 0);
}

/// `lazyRefProp`, carrying the `extends`-walk depth (see `lazy_base_depth`).
fn lazyRefPropRec(c: *Checker, ref: TypeId, name: Atom, depth: u32) Error!?types.Prop {
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
            // …and the same for a member whose type an OUTER frame is already
            // computing, when the demand comes from a mapped type being
            // materialized. Reading it would close a circle through
            // `memberTypeOf`, which NAMES it (TS7022 / TS7023 / TS2502) — but
            // tsc never issues this read at all: it builds a mapped type's
            // members lazily, so `Partial<Omit<C, K>>` created inside `C`'s
            // own table window asks for no member's type until long after the
            // window has closed. Answer not-found and let the caller take its
            // ordinary path, exactly as `lazy_member_active` does. Outside a
            // mapped materialization the circle IS tsc's and is reported —
            // see `classes/062_inferred_return_this_cycle`,
            // `indexed/021_self_referential_member_annotation`.
            if (c.mapped_value_depth > 0 and memberTypeInFlight(c, msym)) return null;
            try c.lazy_member_active.put(c.cm(), msym, {});
            defer _ = c.lazy_member_active.remove(msym);
            const mf = c.symFlags(msym);
            var flags: u32 = 0;
            if (mf.optional_member or memberIsOptionalParamProperty(c, msym)) flags |= types.prop_flag_optional;
            if (mf.readonly_member) flags |= types.prop_flag_readonly;
            if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
            flags |= visibilityPropFlags(c, msym, mf.non_public);
            if (mf.method or mf.getter or mf.setter) flags |= types.prop_flag_class_fn;
            found = .{ .name = nm, .ty = try c.memberTypeOf(msym), .flags = flags };
            break;
        }
    }
    if (found == null) {
        // Inherited member: walk `extends`. A base whose own expansion is
        // also on the stack stays on the lazy path.
        if (try c.baseClassRef(sym)) |base_ref| {
            if (c.refExpansionActive(base_ref)) {
                found = try lazyRefPropRec(c, base_ref, name, depth + 1);
            } else {
                const b = try c.resolveStructural(base_ref);
                found = try c.propOfTypeEx(b, name, false);
            }
        } else if (try c.baseExprConstructType(sym)) |base_ctor| {
            // `extends <value with construct signatures>` — every mixin. The
            // base instance is the construct signature's return type, the same
            // fold `classInstanceGeneric` does; the lazy path had only the
            // named-base arm, so a member inherited through a mixin base was
            // simply not found here. `const M = <T extends
            // Constructor<Point>>(B: T) => class extends B { m(): number {
            // return this.x } }` is the shape: the ANNOTATED return type takes
            // the lazy path, and `this.x` was TS2339.
            for (0..c.ts.objectConstructSigCount(base_ctor)) |i| {
                const ret = c.ts.fnReturn(c.ts.objectConstructSig(base_ctor, @intCast(i)));
                if (try c.propOfTypeEx(try c.resolveStructural(ret), name, false)) |p| {
                    found = p;
                    break;
                }
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
    return lazyRefProp(c, t, name);
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

/// ---------------------------------------------------------------------
/// Declared key NAMES, read off the declarations
/// ---------------------------------------------------------------------
///
/// tsc materializes a nominal type in two halves. `resolveDeclaredMembers`
/// builds the member SYMBOL table from the declaration syntax alone — no
/// annotation is resolved, no initializer is checked — and `getTypeOfSymbol`
/// types one member later, on demand. The first half is therefore never
/// observable half-built, which is why `keyof C` answers the same set for
/// every asker in every order.
///
/// ztsc has ONE pass: `classInstanceGeneric` / `interfaceGeneric` resolve
/// every member's type as they build the table. A member whose type is
/// INFERRED — outline's `add = (item: PartialExcept<T, "id"> | T): T => …` —
/// runs a whole expression check inside that window, and the check can demand
/// `keyof` of the very class being built. The table is marked in progress, so
/// the read took `expandRef`'s cycle cut: `keyof Model` came back as an
/// unresolvable deferred node, `Exclude<keyof Model, "id">` collapsed to
/// `never`, `Partial<Omit<Model, "id">>` to `{}`, and the collapse was
/// memoized into whatever composite happened to ask first. Written OUTSIDE
/// the cycle the same type computes correctly — so the answer depended on
/// demand order, and demand order depends on the partition.
///
/// This is the missing first half, for the one question that needs it. It
/// resolves no member annotation and checks no initializer, so it cannot
/// re-enter the window it is answering inside of.
///
/// It answers null — and the caller keeps its previous behavior — for every
/// shape whose key set is NOT a function of the declarations alone:
///
///   * a mixin / expression base (`class D extends mix(B)`), whose members
///     come from a construct signature's return type;
///   * an `extends` clause naming anything but a class/interface (an alias,
///     `Array<T>`, an intersection), which only the fold can read;
///   * a computed ENUM-MEMBER key, whose key TYPE lives in `key_name_types`
///     keyed by the interned table this route never builds.
const declared_keys_depth: u32 = 32;

/// `name_ty` is the member's tsc `nameType` when it has one that this route
/// can derive from syntax alone — a NUMERIC declaration name (see
/// `Checker.memberNameType`); `no_type` means the key is the plain string
/// literal of the atom.
const DeclKey = struct { name: Atom, non_public: bool, name_ty: TypeId = types.no_type };

const DeclKeyWalk = struct {
    keys: std.ArrayList(DeclKey) = .empty,
    index: std.AutoHashMapUnmanaged(Atom, void) = .empty,
    visited: std.ArrayList(SymbolId) = .empty,
    str_index: bool = false,
    sym_index: bool = false,
    num_index: bool = false,

    /// First writer wins, which is the merge direction the table fold uses:
    /// a derived member overrides the inherited one of the same name, and the
    /// walk visits derived before base.
    fn add(w: *DeclKeyWalk, alloc: Allocator, name: Atom, non_public: bool) Error!void {
        return w.addNamed(alloc, name, non_public, types.no_type);
    }

    fn addNamed(w: *DeclKeyWalk, alloc: Allocator, name: Atom, non_public: bool, name_ty: TypeId) Error!void {
        const gop = try w.index.getOrPut(alloc, name);
        if (gop.found_existing) return;
        try w.keys.append(alloc, .{ .name = name, .non_public = non_public, .name_ty = name_ty });
    }

    fn deinit(w: *DeclKeyWalk, alloc: Allocator) void {
        w.keys.deinit(alloc);
        w.index.deinit(alloc);
        w.visited.deinit(alloc);
    }
};

/// `keyof <class ref>` answered off the declarations, for the case where the
/// member table cannot be read because it is being built further down this
/// stack. Null when the ordinary path is the right one — the operand is not
/// such a reference, its table is readable, or its key set is not derivable
/// from syntax (see `declaredKeyUnion`).
///
/// CLASSES only. An interface's table is materialized by a declaration walk
/// too (`interfaceGeneric`), so it has the same window — but the deferral it
/// falls back to is already sound there, and answering an interface off the
/// declarations is measurably not: @tiptap's `Commands<T>` is reopened by
/// every extension package through `declare module`, and a `keyof Commands`
/// read from inside its own materialization came back without the members a
/// later constituent contributes (social-app lost `focus`/`blur` off
/// `ChainedCommands`, three TS2339 on a package that is at parity). A class
/// cannot be reopened that way, which is what makes its declared key set a
/// function of syntax alone.
pub fn keyofInProgressRef(c: *Checker, t: TypeId) Error!?TypeId {
    if (c.ts.kind(t) != .ref) return null;
    const sym = c.ts.refSymbol(t);
    if (!c.symFlags(sym).class) return null;
    if (!classGenericInProgress(c, sym)) return null;
    return declaredKeyUnion(c, sym);
}

/// Is `name` genuinely ABSENT from the receiver `recv`, whose class member
/// table is being built further down this stack?
///
/// That window is why `class B { bar() { return this._t.length; } }` said
/// nothing: `bar`'s return type is INFERRED, so its body is checked while
/// `classInstanceGeneric` still holds `B`'s table open, `resolveStructural`
/// can only answer the error type there, and a property access on the error
/// type degrades to `any` — the same degradation `lazyThisProp` exists to
/// avoid for a member that DOES exist. Annotating the return type made the
/// very same access TS2339, so the report depended on nothing but whether the
/// table happened to be open.
///
/// The declarations can still answer, exactly as they answer `keyof` in the
/// same window (`keyofInProgressRef`): `walkDeclaredKeys` resolves no
/// annotation and checks no initializer, so it cannot re-enter the
/// materialization it is answering inside of. `false` — no verdict — for
/// every shape it declines (a mixin or expression base, an `extends` naming
/// an alias) and for any index signature, which answers every name.
pub fn inProgressMemberAbsent(c: *Checker, recv: TypeId, name: Atom) Error!bool {
    const t = if (c.ts.kind(recv) == .this_type) c.ts.thisTypeInstance(recv) else recv;
    if (!refExpansionActive(c, t)) return false;
    const sym = c.ts.refSymbol(t);
    if (!c.symFlags(sym).class) return false;
    if (c.declared_keys_active) return false; // see `Checker.declared_keys_active`
    c.declared_keys_active = true;
    defer c.declared_keys_active = false;
    var w = DeclKeyWalk{};
    defer w.deinit(c.scratch());
    if (!try walkDeclaredKeys(c, sym, &w, 0)) return false;
    if (w.str_index or w.sym_index or w.num_index) return false;
    // Every declared name, `private` and `protected` included: a non-public
    // member EXISTS, and the access's own verdict on it is TS2341's, not this
    // one's.
    return !w.index.contains(name);
}

/// `inProgressMemberAbsent`'s companion: the names that walk found, for the
/// SUGGESTION the report it enables wants to make. tsc reaches both from one
/// `getPropertiesOfType(getApparentType(…))`, so the same window that lets
/// ztsc say "no such member" has to be able to say "did you mean this one" —
/// `class Foo { _store = …; bar() { return this.store; } }` is TS2551 in tsc
/// and was a bare TS2339 here (`propertyOrdering`).
///
/// Appends nothing whenever the walk declines, which is the caller's
/// "suggest nothing" answer.
pub fn inProgressMemberNames(c: *Checker, recv: TypeId, out: *std.ArrayList(Atom)) Error!void {
    const t = if (c.ts.kind(recv) == .this_type) c.ts.thisTypeInstance(recv) else recv;
    if (c.ts.kind(t) != .ref or !refExpansionActive(c, t)) return;
    const sym = c.ts.refSymbol(t);
    if (!c.symFlags(sym).class) return;
    if (c.declared_keys_active) return; // see `Checker.declared_keys_active`
    c.declared_keys_active = true;
    defer c.declared_keys_active = false;
    var w = DeclKeyWalk{};
    defer w.deinit(c.scratch());
    if (!try walkDeclaredKeys(c, sym, &w, 0)) return;
    for (w.keys.items) |k| try out.append(c.scratch(), k.name);
}

/// The key union of a class or interface symbol, derived from its
/// declarations. Null when some part of the shape is not derivable.
pub fn declaredKeyUnion(c: *Checker, sym: SymbolId) Error!?TypeId {
    if (c.declared_keys_active) return null; // see `Checker.declared_keys_active`
    c.declared_keys_active = true;
    defer c.declared_keys_active = false;
    var w = DeclKeyWalk{};
    defer w.deinit(c.scratch());
    if (!try walkDeclaredKeys(c, sym, &w, 0)) return null;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (w.keys.items) |k| {
        // A `private`/`protected` member is not a key — `keyofObjectTable`'s
        // rule, and the reason `Pick<C, keyof C>` is the public surface.
        if (k.non_public) continue;
        if (k.name_ty != types.no_type) {
            try parts.append(c.scratch(), k.name_ty);
            continue;
        }
        try parts.append(c.scratch(), try c.ts.makeStringLiteral(k.name, false));
    }
    // The index-signature domains `keyofObjectTable` contributes. A
    // `symbol`-keyed signature shares the string slot, and only owns the key
    // domain outright when nothing else claims it (`obj_flag_symbol_index`).
    if (w.str_index or w.sym_index) {
        if (w.sym_index and !w.str_index and !w.num_index) {
            try parts.append(c.scratch(), types.symbol_type);
        } else {
            try parts.append(c.scratch(), types.string_type);
            try parts.append(c.scratch(), types.number_type);
        }
    }
    if (w.num_index) try parts.append(c.scratch(), types.number_type);
    return try c.ts.makeUnion(c.scratch(), parts.items);
}

/// Accumulate `sym`'s declared key names into `w`, in the order the table
/// fold would give them precedence. False means "not derivable" — the whole
/// answer is then discarded.
fn walkDeclaredKeys(c: *Checker, sym: SymbolId, w: *DeclKeyWalk, depth: u32) Error!bool {
    if (depth >= declared_keys_depth) return false;
    // A heritage diamond reaches the same base twice; a malformed `extends`
    // cycle reaches the same symbol forever.
    for (w.visited.items) |v| {
        if (v == sym) return true;
    }
    try w.visited.append(c.scratch(), sym);
    const f = c.symFlags(sym);
    if (!f.class and !f.interface) return false;
    if (!f.class) return walkInterfaceKeys(c, sym, w, depth);

    // A class: own instance members, then the same-file `interface` half and
    // any cross-file interface augmentation, then the `extends` base — the
    // order `classInstanceGeneric` folds them in.
    {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
            const kscope = c.symScope(sym);
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                const name = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope);
                if (isCtorName(c, name)) continue;
                const mf = c.symFlags(c.toGlobal(c.bind.member_syms[i]));
                try w.add(c.scratch(), name, mf.non_public);
            }
        }
    }
    // Declaration-merged interface blocks. Their DIRECT members join here;
    // their own `extends` bases are folded only for the same-file half
    // (`classInterfaceHalfBases`), exactly as `classInstanceGeneric` does.
    const iface_half = !c.prog.isMergedId(sym) and f.interface;
    if (iface_half) {
        if (!try declKeysOfInterfaceBlocks(c, sym, w)) return false;
    } else if (c.prog.isMergedId(sym)) {
        for (c.prog.mergedSym(sym).parts) |p| {
            if (!c.symFlags(p).interface) continue;
            if (!try declKeysOfInterfaceBlocks(c, p, w)) return false;
        }
    }
    if (try classExtendsClause(c, sym)) {
        const base_ref = (try baseClassRef(c, sym)) orelse return false; // mixin / unmodeled
        if (c.ts.kind(base_ref) != .ref) return false;
        const bsym = c.ts.refSymbol(base_ref);
        if (bsym != sym and !try walkDeclaredKeys(c, bsym, w, depth + 1)) return false;
    }
    if (iface_half and !try declKeysOfHeritage(c, sym, w, depth)) return false;
    return true;
}

/// An interface symbol: every constituent's direct members, then every
/// constituent's `extends` bases (`interfaceGeneric`'s two phases).
fn walkInterfaceKeys(c: *Checker, sym: SymbolId, w: *DeclKeyWalk, depth: u32) Error!bool {
    var one = [_]SymbolId{sym};
    const parts: []const SymbolId = if (c.prog.isMergedId(sym)) c.prog.mergedSym(sym).parts else one[0..];
    for (parts) |p| {
        if (!c.symFlags(p).interface) continue;
        if (!try declKeysOfInterfaceBlocks(c, p, w)) return false;
    }
    for (parts) |p| {
        if (!c.symFlags(p).interface) continue;
        if (!try declKeysOfHeritage(c, p, w, depth)) return false;
    }
    return true;
}

/// Does `sym` write an `extends` clause on any of its class declarations?
fn classExtendsClause(c: *Checker, sym: SymbolId) Error!bool {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        if (data.extends != 0) return true;
    }
    return false;
}

/// The `extends` bases written on `sym`'s interface declaration blocks.
fn declKeysOfHeritage(c: *Checker, sym: SymbolId, w: *DeclKeyWalk, depth: u32) Error!bool {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    try c.interfaceHeritageTypes(sym, &bases);
    for (bases.items) |b| {
        if (c.ts.kind(b) != .ref) return false; // alias / array / intersection base
        const bsym = c.ts.refSymbol(b);
        const bf = c.symFlags(bsym);
        if (!bf.class and !bf.interface) return false;
        if (bsym == sym) continue;
        if (!try walkDeclaredKeys(c, bsym, w, depth + 1)) return false;
    }
    return true;
}

/// Direct member names of every `interface` declaration block of `sym` —
/// `objectTypeFromMembers`, restricted to what names a key.
fn declKeysOfInterfaceBlocks(c: *Checker, sym: SymbolId, w: *DeclKeyWalk) Error!bool {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const data = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node) continue;
            const md = c.tree.nodeData(m);
            switch (c.nodeTag(m)) {
                .property_signature, .method_signature => {
                    const tok = c.tree.nodeMainToken(m);
                    const nt = try c.memberNameType(tok, md.rhs);
                    // A NUMERIC name (`{ 200: T }`) is named by the number
                    // literal, which is a function of the token — this route
                    // can carry it. A computed enum-member key is NAMED by the
                    // enum member, and that name type is recorded against the
                    // interned table this route never builds.
                    if (nt != types.no_type and c.ts.kind(nt) != .number_literal) return false;
                    try w.addNamed(c.scratch(), try c.memberKey(tok, md.rhs), false, nt);
                },
                .index_signature => {
                    const e = c.tree.extraData(ast.IndexSig, md.lhs);
                    const key = try c.typeFromTypeNode(e.key_type);
                    if (key == types.number_type) {
                        w.num_index = true;
                    } else if (key == types.symbol_type) {
                        w.sym_index = true;
                    } else {
                        w.str_index = true;
                    }
                },
                else => {}, // call / construct signatures key nothing
            }
        }
    }
    return true;
}

/// The class symbol a heritage EXPRESSION denotes through its *type* — tsc's
/// `resolveBaseTypesOfClass` first arm, `baseConstructorType.symbol &&
/// baseConstructorType.symbol.flags & SymbolFlags.Class`. The base entity need
/// not be the class binding itself: a `const` whose declared type is a class's
/// static side denotes that class just as well, and tsc then takes the NOMINAL
/// route (`getTypeFromClassOrInterfaceReference`) rather than reading a
/// construct signature's return type.
///
/// `expo-modules-core` publishes its whole class hierarchy this way —
/// `export declare const SharedObject: typeof ExpoGlobal.SharedObject` beside
/// a same-named type alias — so `expo-video`'s
/// `class VideoPlayer extends SharedObject<VideoPlayerEvents>` had its base
/// resolved off the construct signature, whose return type still mentions the
/// base's own unbound parameter. `VideoPlayer` therefore carried
/// `_TEventsMap_DONT_USE_IT?: any` instead of the events map, and every
/// `useEventListener(player, 'timeUpdate', evt => …)` lost the contextual
/// listener type its `TEventsMap` inference hangs on (TS7006 on `evt`).
///
/// Null unless the written type-argument arity is one this base accepts:
/// falling back to the construct-signature route keeps the pre-existing
/// (lenient) answer rather than adding a TS2314/TS2707 `fixTypeArgs` reports.
fn baseCtorClassSym(c: *Checker, expr: Node, targ_count: usize) Error!?SymbolId {
    const bt = try c.checkExprCached(expr, types.no_type);
    if (c.ts.kind(bt) != .class_value) return null;
    const bsym = c.ts.classSymbol(bt);
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(bsym, &tps);
    if (targ_count > tps.items.len) return null;
    var min: usize = 0;
    for (tps.items) |tp| {
        if (tp.default == 0) min += 1;
    }
    if (targ_count < min) return null;
    return bsym;
}

/// TS2507, the tail of tsc's `getBaseConstructorTypeOfClass`:
/// `!isConstructorType(baseConstructorType)` — the `extends` expression names
/// a value with nothing to construct, so there is no base at all. Reported at
/// the expression, and `diagFmt`'s (file, code, span) dedupe makes the many
/// callers of `baseClassRef` file it exactly once.
///
/// Deliberately narrow, because this arm is also where every base ztsc could
/// NOT model lands — a mixin factory, an entity alias, an unmodeled
/// construct — and staying silent there is the documented policy
/// (`hasUnresolvedBase`). So the verdict is taken from the base's TYPE, and
/// only for a PRIMITIVE (`var C = 1; class D extends C`), where nothing about
/// ztsc's modelling is in question.
///
/// An OBJECT without construct signatures is tsc's error too, and NOT admitted
/// here: `class C extends Iterator<number>` is exactly that shape whenever the
/// value half of a lib global is modelled without its `new` signature, and
/// `builtinIterator` earns five false TS2507s from it. That costs the one
/// genuine object case in the corpus (`importAsBaseClass`'s
/// `import C = require("./m")` namespace object) — the safe direction, and the
/// arm becomes admissible the moment a construct-signature-less object can be
/// told from an under-modelled one.
fn reportNonConstructorBase(c: *Checker, expr: Node) Error!void {
    const t = try c.checkExprCached(expr, types.no_type);
    switch (c.ts.kind(try c.resolveStructural(t))) {
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .void,
        .bool_true,
        .bool_false,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        => {},
        else => return,
    }
    try c.diagFmt(2507, c.nodeSpan(expr), "Type '{s}' is not a constructor function type.", .{
        try c.typeToString(t),
    });
}

/// How many type arguments a heritage clause writes.
fn heritageArgCount(c: *Checker, hd: ast.Data) usize {
    if (hd.rhs == 0) return 0;
    const r = c.tree.extraData(ast.SubRange, hd.rhs);
    var n: usize = 0;
    for (c.tree.extraRange(r.start, r.end)) |an| {
        if (an != null_node) n += 1;
    }
    return n;
}

/// tsc's `checkSuperExpression` tail, once the container has been accepted as
/// a legal one:
///
///     const classLikeDeclaration = container.parent as ClassLikeDeclaration;
///     if (!getClassExtendsHeritageElement(classLikeDeclaration)) {
///         error(node, Diagnostics.super_can_only_be_referenced_in_a_derived_class);
///         return errorType;
///     }
///
/// The test is SYNTACTIC — "is there an `extends` clause on this class
/// declaration" — not "did a base type resolve". That distinction is the whole
/// of `superCallFromClassThatHasNoBaseTypeButWithSameSymbolInterface`: an
/// `interface Foo extends Array<number> {}` merged into `class Foo {}` gives
/// the SYMBOL a base type, but the class declaration still writes no
/// `extends`, so `super()` in its constructor is TS2335.
///
/// The container is read off `c.this_type` rather than walked to from the
/// `super` node (ztsc has no parent pointers): a class member binds it to the
/// class's instance ref, a STATIC one to the class value. Anything else — an
/// object-literal method (tsc types `super` there as `any` and reports
/// nothing), a `this` parameter naming an interface, a free function — answers
/// null and reports nothing, which is the conservative half of the rule.
pub fn reportSuperWithoutBase(c: *Checker, super_node: Node) Error!bool {
    const sym = superHomeClassSym(c) orelse return false;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        if (c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs).extends != 0) return false;
        try c.diagFmt(2335, c.nodeSpan(super_node), "'super' can only be referenced in a derived class.", .{});
        return true;
    }
    return false;
}

/// The class whose body lexically encloses the expression being checked, as
/// `c.this_type` records it — see `reportSuperWithoutBase`.
fn superHomeClassSym(c: *Checker) ?SymbolId {
    if (c.this_type == 0) return null;
    const inst = if (c.ts.kind(c.this_type) == .this_type)
        c.ts.thisTypeInstance(c.this_type)
    else
        c.this_type;
    const sym: SymbolId = switch (c.ts.kind(inst)) {
        .ref => c.ts.refSymbol(inst),
        .class_value => c.ts.classSymbol(inst),
        else => return null,
    };
    return if (c.symFlags(sym).class) sym else null;
}

/// The `extends` base of a class as a ref (or null). The base name
/// resolves in the class's own file (so imported bases work).
pub fn baseClassRef(c: *Checker, sym: SymbolId) Error!?TypeId {
    // The clause is an expression, and checking it can ask for this very
    // class's base again — see `Checker.base_ref_active`.
    if (c.base_ref_active.contains(sym)) return null;
    try c.base_ref_active.put(c.cm(), sym, {});
    defer _ = c.base_ref_active.remove(sym);
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
        const base_sym = blk: {
            if (try c.classBaseEntitySym(hd.lhs)) |bs| {
                if (c.symFlags(bs).class) break :blk bs;
            }
            if (try baseCtorClassSym(c, hd.lhs, heritageArgCount(c, hd))) |bs| break :blk bs;
            try reportNonConstructorBase(c, hd.lhs);
            return null;
        };
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        if (hd.rhs != 0) {
            const r = c.tree.extraData(ast.SubRange, hd.rhs);
            for (c.tree.extraRange(r.start, r.end)) |an| {
                if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
            }
        }
        // `class D extends G<Bad>` writes a type-argument list, and tsc gates
        // it on `G`'s constraints exactly as it gates one written in a type
        // position (`checkClassLikeDeclaration` → `checkTypeReferenceNode` on
        // the heritage clause). ztsc reaches the gate here rather than in
        // `checkClass` because the arguments are converted here — and because
        // this is entered under the CLASS's own file context, so the queue's
        // owned-file test and the entry's `file` are the clause's own however
        // the base was demanded (`nominalBases`, a member lookup, the
        // declaration walk). The queue dedupes on the clause node, so a class
        // whose base is asked for a hundred times is judged once.
        try c.queueTypeArgConstraints(data.extends, base_sym, targs.items);
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

/// The visibility half of a class member's `Prop` flag word: `0` for a public
/// member, `prop_flag_non_public` for a `private` one, and that bit plus
/// `prop_flag_protected` for a `protected` one.
///
/// The binder records one `non_public` bit (its `SymbolFlags` has no room for
/// a second), so WHICH modifier it was is rediscovered from the declaration —
/// the same walk `accessibility.accessOfMember` runs for an access site, and
/// the same answer, so the two cannot drift. It runs only for a member the
/// binder already marked non-public, which is a rare member and never an
/// ordinary public one.
///
/// The distinction has to reach the flag word because member tables are
/// HASH-CONSED: `protected static x: string` and `private static x: string`
/// were otherwise one identical table and therefore one type id, and
/// `checkStaticSideExtends` answers `derived_static == base_static` before the
/// nominal rule can run (`derivedClassWithPrivateStaticShadowingProtectedStatic`).
/// See `types.prop_flag_protected`.
pub fn visibilityPropFlags(c: *Checker, msym: SymbolId, non_public: bool) u32 {
    if (!non_public) return 0;
    const base = types.prop_flag_non_public;
    return if (accessibility.accessOfMember(c, msym, false) == .protected)
        base | types.prop_flag_protected
    else
        base;
}

/// Bound on the breadth-first heritage walks that answer a question about the
/// `extends`/`implements` GRAPH rather than about a member table — the same
/// bound `accessibility.declaringClass` and `nominal_members.declaringMember`
/// use, and for the same reason: a malformed program must not be able to make
/// one of them unbounded.
pub const max_heritage_nodes = 32;

/// tsc's `hasBaseType(derived, base)` over the DECLARED heritage graph:
/// equality included, so a class is its own base and a re-declaration inside a
/// derived class is still a valid override of the base's `protected` member.
///
/// Breadth-first over `declaredBaseRefs` rather than the `extends` chain alone,
/// because an interface may extend a class and several bases at once.
pub fn derivesFrom(c: *Checker, derived: SymbolId, base: SymbolId) Error!bool {
    var queue: [max_heritage_nodes]SymbolId = undefined;
    var seen: [max_heritage_nodes]SymbolId = undefined;
    var qn: usize = 1;
    var head: usize = 0;
    var n: usize = 0;
    queue[0] = derived;
    while (head < qn) {
        const sym = queue[head];
        head += 1;
        if (sym == base) return true;
        if (n == seen.len) return false;
        var dup = false;
        for (seen[0..n]) |s| if (s == sym) {
            dup = true;
        };
        if (dup) continue;
        seen[n] = sym;
        n += 1;
        for (try c.declaredBaseRefs(sym)) |b| {
            if (c.ts.kind(b) != .ref or qn == queue.len) continue;
            queue[qn] = c.ts.refSymbol(b);
            qn += 1;
        }
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
        const base_sym = blk: {
            if (try c.classBaseEntitySym(hd.lhs)) |bs| {
                if (c.symFlags(bs).class) break :blk bs;
            }
            // Same static side `baseClassRef` now takes the instance from.
            break :blk (try baseCtorClassSym(c, hd.lhs, heritageArgCount(c, hd))) orelse return null;
        };
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
            var resolved = c.resolveSpace(a, c.cur_scope, true);
            // A TYPE-ONLY import binding is excluded from value space by
            // `hasValueMeaning`, so the value-space resolution above answers
            // `.wrong_space` — but the binding still DENOTES the imported
            // class, and an ambient class may legally extend it (see
            // `checkClass`, which is where the emitted-position TS1361 lives).
            // Dropping the base here cost the derived class every inherited
            // member and every base type argument, so `expo-video`'s
            // `VideoPlayer` was structurally unrelated to the `EventEmitter`
            // its own hierarchy declares.
            if (resolved == .wrong_space) {
                const ws = resolved.wrong_space;
                const wf = c.symFlags(ws);
                if (wf.import_binding and wf.type_only) resolved = .{ .sym = ws };
            }
            switch (resolved) {
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

/// tsc's `getBaseTypeVariableOfClass`: the type VARIABLE a class extends,
/// when its base constructor type is one (or an intersection containing one).
/// `getTypeOfFuncClassEnumModule` intersects it into the class's own static
/// type, which is what makes a mixin factory type-check:
///
/// ```ts
/// function Mixin<T extends abstract new (...a: any) => any>(base: T):
///     T & (abstract new (...a: any) => Mixin) {
///   abstract class MixinClass extends base implements Mixin { … }
///   return MixinClass;   // typeof MixinClass & T
/// }
/// ```
///
/// Without the `& T` the returned value satisfies the anonymous-constructor
/// half of the declared return and nothing at all of the `T` half, so every
/// such `return` was a TS2322 (`mixinAbstractClasses`, `mixinClassesAnnotated`).
///
/// Only a bare-identifier base is examined. A type variable can only ever
/// reach a heritage clause through a name — a parameter or a local bound to
/// one — so the restriction costs nothing and keeps this off the path of the
/// dotted/qualified bases that make up the rest of the corpus. A base that
/// resolves to a class SYMBOL is the ordinary nominal case and answers null
/// without typing anything.
pub fn baseTypeVariableOfClass(c: *Checker, sym: SymbolId) Error!?TypeId {
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .class_decl) continue;
        const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
        if (data.extends == 0) return null;
        const hd = c.tree.nodeData(data.extends);
        if (c.nodeTag(hd.lhs) != .identifier) return null;
        const saved = c.cur_scope;
        defer c.cur_scope = saved;
        if (try c.scopeOf(decl)) |s| c.cur_scope = s;
        const bs = (try c.classBaseEntitySym(hd.lhs)) orelse return null;
        const bf = c.symFlags(bs);
        if (bf.class or bf.interface or bf.namespace_decl) return null;
        const bt = try c.typeOfSymbol(bs);
        if (c.ts.kind(bt) == .type_param) return bt;
        if (c.ts.kind(bt) == .intersection) {
            for (try c.memberList(bt)) |m| {
                if (c.ts.kind(m) == .type_param) return m;
            }
        }
        return null;
    }
    return null;
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
    // The other half of the `extends`-clause resolution, and it checks the
    // same expression — so it takes the same re-entry guard
    // (`Checker.base_ref_active`). The two are called in sequence, never
    // nested, so one set covers both.
    if (c.base_ref_active.contains(sym)) return null;
    try c.base_ref_active.put(c.cm(), sym, {});
    defer _ = c.base_ref_active.remove(sym);
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
        const bt = try baseCtorObject(c, try c.checkExprCached(hd.lhs, types.no_type));
        if (c.ts.kind(bt) == .object and c.ts.objectConstructSigCount(bt) > 0) return bt;
        return null;
    }
    return null;
}

/// The base expression's type as ONE structural constructor object.
///
/// A plain `{ new (…): R }` value resolves straight through, and that is all
/// this used to accept. Two other shapes carry construct signatures and were
/// silently dropped, taking the whole base with them:
///
///   * a `.class_value` (`declare const B: typeof C; class D extends B {}`),
///     ztsc's nominal shortcut for a static side — `classConstructType` is
///     the materialization of exactly that; and
///   * a TYPE PARAMETER, which is how a mixin FACTORY is spelled: `<T extends
///     Constructor<Point>>(Base: T) => class extends Base { … }`. tsc's
///     `resolveBaseTypesOfClass` takes `getApparentType` of the base
///     constructor type, so the parameter stands for its constraint; ztsc
///     dropped the base entirely, and every member inherited from `Point` was
///     TS2339 (`overrideBaseIntersectionMethod`, `mixinClassesAnnotated`); and
///   * an INTERSECTION of constructors, which is how every mixin is spelled.
///     react-native writes each host component that way —
///     `declare const ViewBase: Constructor<NativeMethods> & typeof
///     ViewComponent; export class View extends ViewBase {}` — so `View`,
///     `Text`, `ScrollView` and every sibling inherited neither `props` nor
///     `NativeMethods`. A collapsed props type strips the contextual type off
///     every JSX callback attribute on those components (`onLayout={e => …}`,
///     `onScroll={e => …}`), and the missing methods are the TS2339 on
///     `ref.current?.measure(…)` plus TS7006 on each of its parameters.
///
/// Members merge in written order and every constituent's construct
/// signatures are kept, so the caller can intersect their return types into
/// the base instance.
fn baseCtorObject(c: *Checker, base_in: TypeId) Error!TypeId {
    const s = &c.ts;
    // A type parameter stands for its constraint here (tsc's `getApparentType`
    // of the base constructor type). A chain of them narrows one link at a
    // time; the bound keeps it finite even for a malformed `<T extends T>`,
    // whose constraint resolution answers `no_type` on re-entry.
    var base0 = base_in;
    var hops: u8 = 0;
    while (s.kind(base0) == .type_param and hops < 16) : (hops += 1) {
        const con = try c.typeParamConstraint(s.typeParamSymbol(base0));
        if (con == types.no_type or con == base0) break;
        base0 = con;
    }
    const base = if (s.kind(base0) == .class_value)
        try c.classConstructType(s.classSymbol(base0))
    else
        try c.resolveStructural(base0);
    if (s.kind(base) != .intersection) return base;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var ctors: std.ArrayList(TypeId) = .empty;
    defer ctors.deinit(c.scratch());
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    var sidx: TypeId = 0;
    var nidx: TypeId = 0;
    for (try c.memberList(base)) |m0| {
        const m = if (s.kind(m0) == .class_value)
            try c.classConstructType(s.classSymbol(m0))
        else
            try c.resolveStructural(m0);
        if (s.kind(m) != .object) continue;
        for (0..s.objectPropCount(m)) |i| {
            const p = s.objectProp(m, @intCast(i));
            // Written order wins on a name collision, matching how tsc reads
            // an intersection's property (the first constituent that has it).
            var seen = false;
            for (props.items) |q| {
                if (q.name == p.name) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try props.append(c.scratch(), p);
        }
        for (0..s.objectConstructSigCount(m)) |i| try ctors.append(c.scratch(), s.objectConstructSig(m, @intCast(i)));
        for (0..s.objectCallSigCount(m)) |i| try calls.append(c.scratch(), s.objectCallSig(m, @intCast(i)));
        if (sidx == 0) sidx = s.objectStringIndex(m);
        if (nidx == 0) nidx = s.objectNumberIndex(m);
    }
    if (ctors.items.len == 0) return base;
    std.mem.sort(types.Prop, props.items, {}, struct {
        fn lt(_: void, a: types.Prop, b: types.Prop) bool {
            return a.name < b.name;
        }
    }.lt);
    return s.makeObjectSigs(props.items, sidx, nidx, 0, calls.items, ctors.items);
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
        if (try c.classChainMemberIsAbstract(b, name)) continue;
        return true;
    }
    return false;
}

/// Walking a class ref's own members and then its `extends` chain: is
/// `name` declared there and still `abstract`? A non-class base answers
/// false.
pub fn classChainMemberIsAbstract(c: *Checker, t: TypeId, name: Atom) Error!bool {
    return classChainMemberIsAbstractRec(c, t, name, 0);
}

fn classChainMemberIsAbstractRec(c: *Checker, t: TypeId, name: Atom, depth: u32) Error!bool {
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
    return classChainMemberIsAbstractRec(c, nb, name, depth + 1);
}

/// The declared type of instance member `name` on a class/interface
/// reference `t`, read from that member's own DECLARATION instead of from
/// the folded instance table, and walking the `extends` chain with the
/// reference's type arguments substituted in.
///
/// This is the lazy half of `classInstanceGeneric`: it answers ONE member
/// without demanding the whole table, which is what makes it usable while
/// that table is still materializing. A `typeof this.x` written as a member
/// of the very class that declares `x` is exactly that situation — the fold
/// cuts to `err` and there is no table to read, but the member's own
/// declaration is perfectly resolvable. Null when the name is not declared
/// anywhere on the chain.
pub fn classChainMemberType(c: *Checker, t: TypeId, name: Atom) Error!?TypeId {
    return classChainMemberTypeRec(c, t, name, 0);
}

/// `classChainMemberType`, carrying the `extends`-walk depth.
fn classChainMemberTypeRec(c: *Checker, t: TypeId, name: Atom, depth: u32) Error!?TypeId {
    if (depth >= 64 or c.ts.kind(t) != .ref) return null;
    const sym = c.ts.refSymbol(t);
    const f = c.symFlags(sym);
    if (!f.class and !f.interface) return null;
    var map: std.ArrayList(TpMap) = .empty;
    defer map.deinit(c.scratch());
    const args = c.ts.refArgs(t);
    if (args.len > 0) try c.buildInstMap(sym, args, &map);
    {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        if (c.bind.membersScopeOf(c.localOf(sym))) |ms| {
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                if (c.bind.member_atoms[i] != name) continue;
                const mt = try c.memberTypeOf(c.toGlobal(c.bind.member_syms[i]));
                return if (map.items.len == 0) mt else try c.instantiate(mt, map.items);
            }
        }
    }
    // The base reference is written in the derived class's own parameters,
    // so the derived reference's arguments have to reach it before the walk
    // continues.
    const nb = try c.baseClassRef(sym) orelse return null;
    const base_ref = if (map.items.len == 0) nb else try c.instantiate(nb, map.items);
    return classChainMemberTypeRec(c, base_ref, name, depth + 1);
}

/// A parameter property written `constructor(public two?: U)` declares an
/// OPTIONAL member, exactly as `two?: U` written in the body would — tsc's
/// `getTypeOfVariableOrParameterOrProperty` reads the optionality off the
/// declaration, and a `ParameterPropertyDeclaration` is one of the
/// declarations it reads. The binder records `optional_member` only for the
/// class-body spellings (`class_field` / `class_method`), so the parameter
/// form is answered here off its `param_full` decl node.
///
/// An INITIALIZER does not make it optional: `constructor(public y = "h")`
/// makes the PARAMETER omissible but the property is always assigned, and
/// tsc keeps it required (`{} as {}` into that class is still a TS2741).
fn memberIsOptionalParamProperty(c: *Checker, msym: SymbolId) bool {
    for (c.declsOf(msym)) |decl| {
        if (c.nodeTag(decl) != .param_full) continue;
        const e = c.tree.extraData(ast.ParamFull, c.tree.nodeData(decl).rhs);
        if (e.flags & ast.Flags.optional != 0) return true;
    }
    return false;
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
    const base_name = c.symbolName(direct_base);
    // A class EXPRESSION gets its own pair of codes and its own wording — tsc
    // branches on `isClassExpression(derivedClassDecl)`, not on whether the
    // class has a name — and is reported at the `class` keyword, since there is
    // no name token to point at. `var C = class extends A {}` is TS2653, never
    // TS2515 about a class called `C`.
    const expr = try isClassExpr(c, class_node, class_sym);
    const span = if (expr) c.tokSpan(c.tree.nodeMainToken(class_node)) else c.tokSpan(data.name_token);
    const class_name = c.symbolName(class_sym);
    if (unimpl.items.len == 1) {
        if (expr) {
            try c.diagFmt(2653, span, "Non-abstract class expression does not implement inherited abstract member '{s}' from class '{s}'.", .{
                c.atomText(unimpl.items[0]), base_name,
            });
        } else {
            try c.diagFmt(2515, span, "Non-abstract class '{s}' does not implement inherited abstract member {s} from class '{s}'.", .{
                class_name, c.atomText(unimpl.items[0]), base_name,
            });
        }
        return;
    }
    var names: std.Io.Writer.Allocating = .init(c.scratch());
    defer names.deinit();
    for (unimpl.items, 0..) |m, i| {
        if (i > 0) names.writer.writeAll(", ") catch return error.OutOfMemory;
        names.writer.print("'{s}'", .{c.atomText(m)}) catch return error.OutOfMemory;
    }
    if (expr) {
        try c.diagFmt(18052, span, "Non-abstract class expression is missing implementations for the following members of '{s}': {s}.", .{
            base_name, names.written(),
        });
    } else {
        try c.diagFmt(2654, span, "Non-abstract class '{s}' is missing implementations for the following members of '{s}': {s}.", .{
            class_name, base_name, names.written(),
        });
    }
}

/// Is this class node a class EXPRESSION? Its symbol is declared in the class's
/// OWN scope; a class DECLARATION names itself in the enclosing one. See
/// `Binder.bindClass`, which is where the two are put in different places, and
/// `classSymbolOf`, which is why both are reachable from here.
fn isClassExpr(c: *Checker, class_node: Node, class_sym: SymbolId) Error!bool {
    const saved = c.enterSymFile(class_sym);
    defer c.restoreCtx(saved);
    const cs = try c.scopeOf(class_node) orelse return false;
    return c.symScope(class_sym) == cs;
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
