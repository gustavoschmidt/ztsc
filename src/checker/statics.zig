//! Class statics: the static side of a class (`typeof C`) materialized as an
//! object type, the structural constructor object built over it, and the
//! constructor-signature walk up the `extends` chain.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const TpMap = @import("subst.zig").TpMap;
const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const isCtorName = @import("instantiate.zig").isCtorName;
const classIndexInfos = @import("classes.zig").classIndexInfos;

/// One own static member of `cls`, resolved WITHOUT materializing its
/// siblings — tsc's `getPropertyOfType` on the static side, which reaches
/// the member symbol and then `getTypeOfSymbol` on it alone.
///
/// Going through `classStaticType` instead is what made a static whose
/// initializer reads another static of the same class resolve to `any`:
/// building the static object types EVERY member, so while member A is
/// still in progress the loop reaches member B, checks B's body against
/// the transient `any` A's in-progress guard hands out, and memoizes that
/// answer for B forever. `ShapeCache` is the shape — `static get = <T>(e) =>
/// ShapeCache.cache.get(e) as …` demands the static object from inside
/// `get`, so `generateElementShape` was typed against `get: any`. Resolving
/// only the member actually asked for breaks the chain: `cache` is
/// reachable from inside `get` without B ever being visited.
///
/// Own members only. An inherited or namespace-merged static returns null
/// here and the caller falls back to the whole static object, which is
/// where merging lives.
pub fn ownStaticMemberProp(c: *Checker, cls: SymbolId, name: Atom) Error!?types.Prop {
    const saved_ctx = c.enterSymFile(cls);
    defer c.restoreCtx(saved_ctx);
    const ss = c.bind.staticsScopeOf(c.localOf(cls)) orelse return null;
    const kscope = c.symScope(cls);
    const lo = c.bind.scope_members_start[ss];
    const hi = c.bind.scope_members_start[ss + 1];
    for (lo..hi) |i| {
        if (try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope) != name) continue;
        const msym = c.toGlobal(c.bind.member_syms[i]);
        const mf = c.symFlags(msym);
        var flags: u32 = 0;
        if (mf.readonly_member) flags |= types.prop_flag_readonly;
        if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
        if (mf.non_public) flags |= types.prop_flag_non_public;
        if (mf.method or mf.getter or mf.setter) flags |= types.prop_flag_class_fn;
        // `this` inside a static member is the class's constructor type,
        // exactly as `classStaticType` sets it before resolving one.
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        c.this_type = try c.ts.makeClassValue(cls);
        return .{ .name = name, .ty = try c.typeOfSymbol(msym), .flags = flags };
    }
    return null;
}

/// Contextually type the STATIC fields of a class EXPRESSION — tsc's
/// `getContextualTypeForStaticPropertyDeclaration`, which takes the class
/// expression's own contextual type and reads the same-named property off it.
///
///     interface I { x: { a: "a" } }
///     let c: I = class { static x = { a: "a" } };
///
/// Without the context the initializer widens to `{ a: string }` and the class
/// is not assignable to `I` — nine false TS2322s across
/// `staticFieldWithInterfaceContext` alone, all of them invisible while a class
/// expression was still typed `any`.
///
/// SEEDED rather than threaded: a member's type is computed on demand from its
/// initializer with no contextual type, and the demand can arrive from
/// anywhere. `setTypeOfSymbol` is first-writer-wins, so writing the contextual
/// answer before the class is walked is what makes it the one every later
/// reader sees. A member that already has a type (an annotation, an earlier
/// demand) keeps it.
///
/// A no-op unless the class expression has a contextual type; only fields
/// carrying an initializer and no annotation can be contextually typed at all.
pub fn seedStaticFieldContext(c: *Checker, node: Node, cls: SymbolId, ctx: TypeId) Error!void {
    if (ctx == types.no_type or ctx == types.any_type or ctx == types.error_type) return;
    const ss = c.bind.staticsScopeOf(c.localOf(cls)) orelse return;
    const kscope = c.symScope(cls);
    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(node).lhs);
    for (c.tree.extraRange(data.members_start, data.members_end)) |member| {
        if (member == null_node or c.nodeTag(member) != .class_field) continue;
        const f = c.tree.extraData(ast.Field, c.tree.nodeData(member).lhs);
        if (f.flags & ast.Flags.static == 0) continue;
        if (f.type_ann != 0 or f.init == 0) continue;
        const m = staticMemberOfDecl(c, ss, member) orelse continue;
        const name = try c.nominalizeComputedKey(m.name, kscope);
        const p = try c.propOfTypeEx(ctx, name, false) orelse continue;
        // Same guard the on-demand path uses: a function body inside the
        // initializer must not be walked while the class's own type is still
        // being built (see `DeferredBody`).
        c.defer_bodies += 1;
        defer c.defer_bodies -= 1;
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        c.this_type = try c.ts.makeClassValue(cls);
        c.setTypeOfSymbol(m.sym, try c.widenLiteral(try c.checkExprCached(f.init, p.ty)));
    }
}

/// The static-scope entry a class member DECLARATION declares, or null when
/// the member declares none (a nameless recovery member, a key the binder
/// could not form).
const StaticMember = struct { sym: SymbolId, name: Atom };

fn staticMemberOfDecl(c: *Checker, ss: binder.ScopeId, member: Node) ?StaticMember {
    const lo = c.bind.scope_members_start[ss];
    const hi = c.bind.scope_members_start[ss + 1];
    for (lo..hi) |i| {
        const msym = c.toGlobal(c.bind.member_syms[i]);
        for (c.declsOf(msym)) |d| {
            if (d == member) return .{ .sym = msym, .name = c.bind.member_atoms[i] };
        }
    }
    return null;
}

/// Would folding `sym`'s base statics right now close an `extends` cycle?
///
/// True only when `sym` is already on `class_static_stack` AND every frame
/// from it to the top is in its base phase — i.e. the path back to it runs
/// through `extends` edges and nothing else. A re-entry that passes through a
/// member edge (a static initializer, a member annotation naming another
/// class) leaves a non-base frame in between and is not a cycle: it is an
/// ordinary nested demand, and it must be free to fold its own base or the
/// answer depends on who asked first.
fn staticBaseCycle(c: *Checker, sym: SymbolId) bool {
    var i = c.class_static_stack.items.len;
    while (i > 0) {
        i -= 1;
        const f = c.class_static_stack.items[i];
        if (!f.in_base) return false;
        if (f.sym == sym) return true;
    }
    return false;
}

/// TS2506 for every class ON the `extends` cycle `sym` just closed. The gray
/// frames from `sym` to the top of `class_static_stack` are exactly its members
/// (that is what `staticBaseCycle` established), so a class that merely REACHES
/// the cycle from outside stays silent — it sits below `sym` on the stack.
///
/// This is tsc's `getBaseConstructorTypeOfClass` failing to pop its own
/// resolution, which is why the message talks about the base EXPRESSION and why
/// the static side is where it belongs: the base of a class value is an
/// expression, and resolving it is what re-enters. Reported at each class's
/// name, in that class's own file, so `diagFmt`'s per-(file, code, span) dedup
/// keeps one report per class however often the cycle is re-entered — and the
/// emitted set is a function of the extends graph, not of which class the
/// traversal happened to start from.
fn emitStaticBaseCycle(c: *Checker, sym: SymbolId) Error!void {
    const stack = c.class_static_stack.items;
    var start = stack.len;
    while (start > 0) : (start -= 1) {
        if (stack[start - 1].sym == sym) break;
    }
    if (start == 0) return; // `staticBaseCycle` just found it; defensive
    for (stack[start - 1 ..]) |fr| {
        const saved = c.enterSymFile(fr.sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(fr.sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            if (data.name_token == 0) continue;
            try c.diagFmt(
                2506,
                c.tokSpan(data.name_token),
                "'{s}' is referenced directly or indirectly in its own base expression.",
                .{c.symbolName(fr.sym)},
            );
            break;
        }
    }
}

/// A class whose `extends` names ITSELF — an `extends` cycle of length one. The
/// static fold never re-enters on it (`baseClassSym` answers "no base" for a
/// self-extends, since there are no statics to inherit), so `staticBaseCycle`
/// cannot see it and it has to be recognized directly.
///
/// Screened syntactically first: only a clause whose last identifier repeats the
/// class's own name can be one, and that is a token comparison, so the base
/// resolution below runs for essentially no real class.
fn selfExtendingClass(c: *Checker, sym: SymbolId) Error!bool {
    var suspect = false;
    {
        const saved_ctx = c.enterSymFile(sym);
        defer c.restoreCtx(saved_ctx);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(decl).lhs);
            if (data.extends == 0 or data.name_token == 0) continue;
            const entity = c.tree.nodeData(data.extends).lhs;
            const last_tok = switch (c.nodeTag(entity)) {
                .identifier => c.tree.nodeMainToken(entity),
                // A dotted base (`Module.C`): the member half is the name.
                .member_expr, .qualified_name => c.tree.nodeData(entity).rhs,
                else => continue,
            };
            if (last_tok == 0) continue;
            if (std.mem.eql(u8, c.tokenText(last_tok), c.tokenText(data.name_token))) suspect = true;
            break;
        }
    }
    if (!suspect) return false;
    const base_ref = (try c.baseClassRef(sym)) orelse return false;
    return c.ts.kind(base_ref) == .ref and c.ts.refSymbol(base_ref) == sym;
}

/// Static side of a class (statics as object props; construct handled
/// separately by `new` resolution).
pub fn classStaticType(c: *Checker, sym: SymbolId) Error!TypeId {
    // Only complete objects are ever memoized, so a hit is never cut.
    if (c.class_static_cache.get(sym)) |t| {
        c.class_static_cut = false;
        return t;
    }
    // Is this re-entry an `extends` cycle (or past the depth backstop)? Both
    // answers are properties of the heritage graph alone, so both are the same
    // whoever asks first. See `Checker.class_static_stack`.
    const base_cycle = staticBaseCycle(c, sym);
    // The cycle is a malformed program, not just something the fold has to cut:
    // report it. Only a real `extends` cycle does — the depth backstop below is a
    // resource bound, and a deep-but-legal chain must stay silent.
    if (base_cycle) {
        try emitStaticBaseCycle(c, sym);
    } else if (try selfExtendingClass(c, sym)) {
        // The one-class cycle: `sym` is not on the stack yet, so push its frame
        // first and let the same emitter name it.
        try c.class_static_stack.append(c.cm(), .{ .sym = sym });
        defer _ = c.class_static_stack.pop();
        try emitStaticBaseCycle(c, sym);
    }
    const cycle = base_cycle or
        c.class_static_stack.items.len >= checker_zig.max_class_static_depth;
    try c.class_static_stack.append(c.cm(), .{ .sym = sym });
    const my_frame = c.class_static_stack.items.len - 1;
    defer _ = c.class_static_stack.pop();
    const saved_ctx = c.enterSymFile(sym);
    defer c.restoreCtx(saved_ctx);
    // `this` inside a static member is the class's constructor type (tsc),
    // exactly as `checkClass` sets it for the static branch. Set it here too
    // so a static field whose initializer is a function (`static _save = ()
    // => this.locker…`) sees the right receiver even when its type is first
    // materialized through static expansion rather than the class walk —
    // otherwise `this` was whatever the ambient value happened to be at
    // materialization time (the *enclosing* class, when one class's members
    // pull in another's).
    const saved_this = c.this_type;
    defer c.this_type = saved_this;
    c.this_type = try c.ts.makeClassValue(sym);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (c.bind.staticsScopeOf(c.localOf(sym))) |ss| {
        const kscope = c.symScope(sym);
        const lo = c.bind.scope_members_start[ss];
        const hi = c.bind.scope_members_start[ss + 1];
        for (lo..hi) |i| {
            const msym = c.toGlobal(c.bind.member_syms[i]);
            const mf = c.symFlags(msym);
            var flags: u32 = 0;
            if (mf.readonly_member) flags |= types.prop_flag_readonly;
            if (mf.getter and !mf.setter) flags |= types.prop_flag_readonly;
            if (mf.non_public) flags |= types.prop_flag_non_public;
            if (mf.method or mf.getter or mf.setter) flags |= types.prop_flag_class_fn;
            try props.append(c.scratch(), .{
                .name = try c.nominalizeComputedKey(c.bind.member_atoms[i], kscope),
                // Route through typeOfSymbol (not memberTypeOf directly) so a
                // static field whose initializer reads a sibling static —
                // `static a = () => C.b; static b = 1` — re-enters the
                // in-progress guard (returns `any` transiently, then the
                // outer frame resolves the real type) instead of rebuilding
                // this same static object and recursing to a stack overflow.
                // Statics can't reference the class type params, so the
                // per-symbol type cache is sound here.
                .ty = try c.typeOfSymbol(msym),
                .flags = flags,
            });
        }
    }
    // Namespace value members: one property per *exported* value-space
    // member. A merged namespace draws them from its merged member
    // index (member ids may themselves be merged); a plain namespace from
    // its (merged-within-file) body scope.
    if (c.symFlags(sym).namespace_decl) {
        var midx_atoms: []const Atom = &.{};
        var midx_syms: []const u32 = &.{};
        if (c.prog.isMergedId(sym)) {
            const idx = c.prog.mergedSym(sym).members;
            midx_atoms = idx.atoms;
            midx_syms = idx.syms;
        } else if (c.bind.namespaceScopeOf(c.localOf(sym))) |ns| {
            const lo = c.bind.scope_members_start[ns];
            const hi = c.bind.scope_members_start[ns + 1];
            // Lift the body-scope segment to global ids in this file.
            const gs = try c.scratch().alloc(u32, hi - lo);
            for (lo..hi, 0..) |i, k| gs[k] = c.toGlobal(c.bind.member_syms[i]);
            midx_atoms = c.bind.member_atoms[lo..hi];
            midx_syms = gs;
        }
        for (midx_atoms, midx_syms) |name, msym| {
            const mf = c.symFlags(msym);
            if (!mf.exported or !hasValueMeaning(mf)) continue;
            var dup = false;
            for (props.items) |p| {
                if (p.name == name) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            var flags: u32 = 0;
            if (mf.const_decl or mf.readonly_member) flags |= types.prop_flag_readonly;
            try props.append(c.scratch(), .{
                .name = name,
                .ty = try c.typeOfSymbol(msym),
                .flags = flags,
            });
        }
        // …plus the names the body re-exports with `export { X as Y }`, which
        // the binder records as export records rather than declaring in the
        // body scope, so the member index above does not carry them.
        try c.nsReexportProps(sym, &props);
    }
    // `static [k: string]: T` belongs to the class VALUE's type — the half
    // `classIndexInfos` reads with `statics` set. Inherited signatures arrive
    // through the base merge below.
    const own_index = try classIndexInfos(c, sym, true);
    var result = try c.ts.makeObject(props.items, own_index.str, own_index.num, own_index.objFlags(0));
    // Static members are inherited: `typeof D` includes `typeof Base`'s
    // statics (own members win over inherited). This is how leaflet's
    // `Map.include`/`GridLayer.extend` reach the static `extend`/`include`
    // declared on the root `class Class`. A malformed `extends` cycle cuts the
    // recursion (`staticBaseCycle`) and yields the class's own members alone —
    // which is also what a static-field initializer that reads a sibling
    // static needs to see when it re-enters this function.
    //
    // `cut` = did this object lose its inherited statics? See
    // `Checker.class_static_cut`.
    var cut = false;
    if (!cycle) {
        if (try c.baseClassSym(sym)) |base| {
            c.class_static_stack.items[my_frame].in_base = true;
            c.class_static_cut = false;
            const base_static = try c.classStaticType(base);
            cut = c.class_static_cut;
            c.class_static_stack.items[my_frame].in_base = false;
            result = try c.mergeBaseObject(result, base_static, false);
        } else if (blk: {
            c.class_static_stack.items[my_frame].in_base = true;
            defer c.class_static_stack.items[my_frame].in_base = false;
            c.class_static_cut = false;
            const b = try c.baseExprConstructType(sym);
            cut = c.class_static_cut;
            break :blk b;
        }) |base_ctor| {
            // `class D extends <expression>`: the STATIC side inherits the
            // base expression's own members, exactly as it inherits a base
            // class's statics — tsc gives the class's static type the base
            // CONSTRUCTOR type as its base type, so anything declared beside
            // the construct signature is reachable through `D.`. The
            // signatures are deliberately dropped: `classConstructType`
            // builds this class's own from its constructors, and the base
            // instance already comes from `classInstanceGeneric`'s matching
            // `baseExprConstructType` arm.
            //
            // nestjs-zod is written this way — `class Dto extends
            // createZodDto(Schema) {}`, where `ZodDto` declares
            // `create(input: unknown)`, `schema` and `isZodDto` next to its
            // `new ()`. immich calls `HlsPlaylistHeaderDto.create(headers)`
            // and reads `PluginManifestDto.schema`.
            var bprops: std.ArrayList(types.Prop) = .empty;
            defer bprops.deinit(c.scratch());
            for (0..c.ts.objectPropCount(base_ctor)) |i| {
                try bprops.append(c.scratch(), c.ts.objectProp(base_ctor, @intCast(i)));
            }
            const base_static = try c.ts.makeObject(
                bprops.items,
                c.ts.objectStringIndex(base_ctor),
                c.ts.objectNumberIndex(base_ctor),
                0,
            );
            result = try c.mergeBaseObject(result, base_static, false);
        }
    } else cut = true;
    c.class_static_cut = cut;
    // A cut object is missing every inherited static. Memoizing it is what
    // made `typeof ParanoidModel` (outline, three classes below sequelize's
    // `Model`) lose `findAll`/`findOne`/`scope`/… for the rest of the run:
    // one demand reached `IdModel` while `IdModel`'s own base fold was on the
    // stack, cached the own-members-only answer, and every class below it
    // folded THAT and cached the hole permanently. Which demand arrives inside
    // the window is a partition/order accident, so the diagnostics moved with
    // `--checkers`. Leaving a cut object uncached costs one rebuild.
    if (!cut) try c.class_static_cache.put(c.cm(), sym, result);
    return result;
}

/// A class value (`typeof C`) rendered as an ordinary *structural*
/// constructor object: the class's static members plus one construct
/// signature per constructor overload, each returning the class instance.
///
/// `.class_value` is a nominal shortcut — `new C()` and `C.staticMember`
/// read it directly (see `checkCallLike` / `propOfTypeEx`), so nothing ever
/// had to materialize its construct signatures. But a *pattern* match needs
/// them: `InstanceType<T> = T extends abstract new (…args: any) => infer R ?
/// R : never` matches an object carrying construct signatures, and a bare
/// `.class_value` source offers none, so `R` stayed uninferred and the whole
/// conditional collapsed to `unknown`. The instance type comes from the
/// class symbol (a constructor's own declared return is `void`), with the
/// class's type parameters filled with `any` — the same erasure
/// `instanceofInstanceType` uses for `x instanceof C`.
pub fn classConstructType(c: *Checker, cls: SymbolId) Error!TypeId {
    if (c.class_ctor_cache.get(cls)) |t| return t;
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(cls, &tps);
    const args = try c.scratch().alloc(TypeId, tps.items.len);
    for (args) |*x| x.* = types.any_type;
    const inst = try c.ts.makeRef(cls, args);
    var ctor_sigs: std.ArrayList(TypeId) = .empty;
    defer ctor_sigs.deinit(c.scratch());
    try c.ctorSignatures(cls, &ctor_sigs);
    const map = try c.scratch().alloc(TpMap, tps.items.len);
    for (tps.items, 0..) |tp, i| map[i] = .{ .sym = tp.sym, .ty = args[i] };
    var sigs: std.ArrayList(TypeId) = .empty;
    defer sigs.deinit(c.scratch());
    for (ctor_sigs.items) |sig0| {
        const sig = if (map.len > 0) try c.instantiate(sig0, map) else sig0;
        try sigs.append(c.scratch(), try c.sigWithReturn(sig, inst));
    }
    // No declared constructor: the implicit `new () => C`.
    if (sigs.items.len == 0) {
        try sigs.append(c.scratch(), try c.ts.makeFunction(&.{}, inst, &.{}, 0));
    }
    const statics = try c.classStaticType(cls);
    // …and inherits its cut: a constructor object built over a static table
    // that lost its inherited members is just as incomplete, so it must not
    // outlive the window either (see `Checker.class_static_cut`).
    const cut = c.class_static_cut;
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (c.ts.kind(statics) == .object) {
        for (0..c.ts.objectPropCount(statics)) |i| {
            try props.append(c.scratch(), c.ts.objectProp(statics, @intCast(i)));
        }
    }
    const obj = try c.ts.makeObjectSigs(props.items, 0, 0, types.obj_flag_not_inferable, &.{}, sigs.items);
    c.class_static_cut = cut;
    if (!cut) try c.class_ctor_cache.put(c.cm(), cls, obj);
    return obj;
}

/// `sig` with its return type replaced (params, type params and arity kept).
pub fn sigWithReturn(c: *Checker, sig: TypeId, ret: TypeId) Error!TypeId {
    const s = &c.ts;
    var params: std.ArrayList(types.Param) = .empty;
    defer params.deinit(c.scratch());
    for (0..s.fnParamCount(sig)) |i| try params.append(c.scratch(), s.fnParam(sig, @intCast(i)));
    var tps: std.ArrayList(u32) = .empty;
    defer tps.deinit(c.scratch());
    for (0..s.fnTypeParamCount(sig)) |i| try tps.append(c.scratch(), s.fnTypeParamAt(sig, i));
    return s.makeFunction(params.items, ret, tps.items, 0);
}

/// Constructor signatures of a class (own or inherited); empty list
/// means the default ctor.
///
/// An INHERITED signature is instantiated with the type arguments the
/// heritage clause wrote: `class ViewComponent extends React.Component<
/// ViewProps>` declares no constructor of its own, so it inherits
/// `Component<P>`'s `constructor(props: P)` — and that signature has to read
/// `constructor(props: ViewProps)`, not `constructor(props: P)`. Walking to
/// the base SYMBOL alone dropped the reference's arguments and let the base
/// class's own parameter escape into `typeof ViewComponent`, where nothing
/// could ever bind it.
///
/// It surfaces through any pattern that reads a class's construct signature.
/// `React.ComponentProps<typeof C>` is `typeof C extends
/// JSXElementConstructor<infer P> ? P : …`, so the free parameter was what
/// `infer P` matched: every React Native host component's props type came
/// back as an unbound type parameter, and social-app reads
/// `ComponentProps<typeof View>` (and of `Text`, `ScrollView`, `Pressable`,
/// `TextInput`) to declare its own components' props.
pub fn ctorSignatures(c: *Checker, sym: SymbolId, out: *std.ArrayList(TypeId)) Error!void {
    var cur = sym;
    var depth: u32 = 0;
    // The heritage type ARGUMENTS accumulated down the `extends` chain, empty
    // at the class the caller asked about (whose own signatures are already
    // written in its own parameters). See the doc comment.
    var map: std.ArrayList(TpMap) = .empty;
    defer map.deinit(c.scratch());
    while (depth < 16) : (depth += 1) {
        const saved = c.enterSymFile(cur);
        defer c.restoreCtx(saved);
        if (c.bind.membersScopeOf(c.localOf(cur))) |ms| {
            const lo = c.bind.scope_members_start[ms];
            const hi = c.bind.scope_members_start[ms + 1];
            for (lo..hi) |i| {
                if (!isCtorName(c, c.bind.member_atoms[i])) continue;
                const csym = c.bind.member_syms[i];
                for (c.bind.declsOf(csym)) |decl| {
                    if (c.nodeTag(decl) != .class_method) continue;
                    const d = c.tree.nodeData(decl);
                    // Overload signatures (no body) participate; the
                    // implementation is used only if it's alone.
                    const sig = try c.signatureOfProto(decl, d.lhs, true, true);
                    if (d.rhs == 0) try out.append(c.scratch(), try applyHeritageArgs(c, sig, map.items));
                }
                if (out.items.len == 0) {
                    for (c.bind.declsOf(csym)) |decl| {
                        if (c.nodeTag(decl) != .class_method) continue;
                        const d = c.tree.nodeData(decl);
                        if (d.rhs != 0) {
                            const sig = try c.signatureOfProto(decl, d.lhs, true, true);
                            try out.append(c.scratch(), try applyHeritageArgs(c, sig, map.items));
                        }
                    }
                }
                if (out.items.len > 0) return;
            }
        }
        // Inherit base ctor.
        const base = try c.baseClassRef(cur) orelse {
            // `extends <value with construct signatures>` (mixin-base):
            // inherit the base value's construct signatures.
            if (try c.baseExprConstructType(cur)) |base_ctor| {
                for (0..c.ts.objectConstructSigCount(base_ctor)) |i| {
                    const sig = c.ts.objectConstructSig(base_ctor, @intCast(i));
                    try out.append(c.scratch(), try applyHeritageArgs(c, sig, map.items));
                }
            }
            return;
        };
        const base_sym = c.ts.refSymbol(base);
        // Compose this clause's arguments into the running map before
        // descending. Composition (rather than replacement) is what makes a
        // chain work: an argument written here may itself mention the CURRENT
        // class's parameters (`class A<T> extends B<T[]>`), and those have
        // already been resolved by the map built above it.
        var btps: std.ArrayList(TypeParamInfo) = .empty;
        defer btps.deinit(c.scratch());
        try c.typeParamsOf(base_sym, &btps);
        var next: std.ArrayList(TpMap) = .empty;
        for (btps.items, 0..) |tp, i| {
            if (i >= c.ts.refArgCount(base)) break;
            var arg = c.ts.refArgAt(base, i);
            if (map.items.len > 0) arg = try c.instantiate(arg, map.items);
            try next.append(c.scratch(), .{ .sym = tp.sym, .ty = arg });
        }
        map.deinit(c.scratch());
        map = next;
        cur = base_sym;
    }
}

/// A constructor signature with the accumulated heritage-argument
/// substitution applied. Empty map (the class's own constructors) is the
/// identity, so nothing is instantiated that does not need to be.
fn applyHeritageArgs(c: *Checker, sig: TypeId, map: []const TpMap) Error!TypeId {
    if (map.len == 0) return sig;
    return c.instantiate(sig, map);
}
