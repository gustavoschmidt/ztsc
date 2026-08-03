//! Enums: member typing, literal types, initializers.
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

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;
const Store = types.Store;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const check = checker_zig.check;
const max_instantiation_depth = checker_zig.max_instantiation_depth;
const max_instantiation_count = checker_zig.max_instantiation_count;
const max_chain_repeats = checker_zig.max_chain_repeats;
const max_this_subst_repeats = checker_zig.max_this_subst_repeats;
const chain_scan_floor = checker_zig.chain_scan_floor;
const scratch_retain_limit = checker_zig.scratch_retain_limit;
const FreshTp = checker_zig.FreshTp;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const aliasGeneric = @import("instantiate.zig").aliasGeneric;
const atom = Checker.atom;
const checkClass = @import("stmts.zig").checkClass;
const diagFmt = Checker.diagFmt;
const hasValueMeaning = @import("names.zig").hasValueMeaning;
const inferReverseMapped = @import("calls.zig").inferReverseMapped;
const inferTypeArgs = @import("calls.zig").inferTypeArgs;
const instanceofInstanceType = @import("flow.zig").instanceofInstanceType;
const isCtorName = @import("instantiate.zig").isCtorName;
const literalBaseOf = @import("names.zig").literalBaseOf;
const memberList = @import("typenode.zig").memberList;
const memberTypeOf = @import("signatures.zig").memberTypeOf;
const originTaggable = @import("instantiate.zig").originTaggable;
const propOfTypeEx = @import("props.zig").propOfTypeEx;
const reduceMapped = @import("generics.zig").reduceMapped;
const run = Checker.run;
const scratch = Checker.scratch;
const typeFromTypeNode = @import("typenode.zig").typeFromTypeNode;
const typeOfSymbol = @import("signatures.zig").typeOfSymbol;

/// Static side of a class (statics as object props; construct handled
/// separately by `new` resolution).
// =====================================================================
// enums
// =====================================================================

pub const EnumInfo = struct {
    is_const: bool,
    /// Every member is a string constant (nominal string enum).
    all_string: bool,
    /// No string members (pure numeric / auto-increment / computed).
    all_numeric: bool,
    /// At least one member has a non-constant initializer.
    has_computed: bool,
    /// Numeric member values, for numeric-literal membership checks.
    values: []const f64,

    pub fn hasValue(self: EnumInfo, v: f64) bool {
        for (self.values) |x| {
            if (x == v) return true;
        }
        return false;
    }
};

pub const EnumInitKind = enum { numeric, string, computed };

/// Classify an enum member initializer for constant folding. Only literal
/// numbers (incl. unary `-`/`+`) and string literals fold to constants;
/// anything else is "computed".
pub fn classifyEnumInit(c: *Checker, node: Node) struct { kind: EnumInitKind, value: f64 } {
    switch (c.nodeTag(node)) {
        .number_literal => return .{ .kind = .numeric, .value = c.numberTokenValue(c.tree.nodeMainToken(node)) },
        .prefix_unary => {
            const d = c.tree.nodeData(node);
            const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
            if ((op == .minus or op == .plus) and d.lhs != 0 and c.nodeTag(d.lhs) == .number_literal) {
                const v = c.numberTokenValue(c.tree.nodeMainToken(d.lhs));
                return .{ .kind = .numeric, .value = if (op == .minus) -v else v };
            }
            return .{ .kind = .computed, .value = 0 };
        },
        .string_literal => return .{ .kind = .string, .value = 0 },
        else => return .{ .kind = .computed, .value = 0 },
    }
}

/// Const-ness, string/numeric nature, and numeric member values of an
/// enum symbol (all declaration blocks merged). Pure computation, cached.
pub fn enumInfo(c: *Checker, sym: SymbolId) Error!EnumInfo {
    if (c.enum_info_cache.get(sym)) |info| return info;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(c.scratch());
    var is_const = false;
    var has_string = false;
    var has_computed = false;
    var member_count: u32 = 0;
    var auto: f64 = 0;
    var auto_ok = true;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.EnumData, d.lhs);
        if (data.flags & ast.Flags.const_enum != 0) is_const = true;
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            member_count += 1;
            const init_node = c.tree.nodeData(m).lhs;
            if (init_node == null_node) {
                if (auto_ok) {
                    try values.append(c.scratch(), auto);
                    auto += 1;
                }
                continue;
            }
            const ci = c.classifyEnumInit(init_node);
            switch (ci.kind) {
                .numeric => {
                    try values.append(c.scratch(), ci.value);
                    auto = ci.value + 1;
                    auto_ok = true;
                },
                .string => {
                    has_string = true;
                    auto_ok = false;
                },
                .computed => {
                    has_computed = true;
                    auto_ok = false;
                },
            }
        }
    }
    const info: EnumInfo = .{
        .is_const = is_const,
        .all_string = has_string and !has_computed and values.items.len == 0 and member_count > 0,
        .all_numeric = !has_string,
        .has_computed = has_computed,
        .values = try c.ca().dupe(f64, values.items),
    };
    try c.enum_info_cache.put(c.cm(), sym, info);
    return info;
}

/// Walk every member of an enum symbol (all declaration blocks merged) in
/// declaration order, handing the callback each member's name atom and the
/// literal type of its constant value — `no_type` when the value is
/// computed (or when auto-increment ran off a string/computed member, so
/// the number is unknowable). The one place the auto-increment rules live.
pub fn eachEnumMember(
    c: *Checker,
    sym: SymbolId,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), Atom, TypeId) Error!void,
) Error!void {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var auto: f64 = 0;
    var auto_ok = true;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const name = try c.memberAtom(c.tree.nodeMainToken(m));
            const init_node = c.tree.nodeData(m).lhs;
            if (init_node == null_node) {
                const v = if (auto_ok) try c.ts.makeNumberLiteral(auto, false) else types.no_type;
                if (auto_ok) auto += 1;
                try f(ctx, name, v);
                continue;
            }
            const ci = c.classifyEnumInit(init_node);
            switch (ci.kind) {
                .string => {
                    const av = try c.memberAtom(c.tree.nodeMainToken(init_node));
                    auto_ok = false;
                    try f(ctx, name, try c.ts.makeStringLiteral(av, false));
                },
                .numeric => {
                    auto = ci.value + 1;
                    auto_ok = true;
                    try f(ctx, name, try c.ts.makeNumberLiteral(ci.value, false));
                },
                .computed => {
                    auto_ok = false;
                    try f(ctx, name, types.no_type);
                },
            }
        }
    }
}

pub const EnumMemberLookup = struct {
    want: Atom,
    found: bool = false,
    value: TypeId = types.no_type,
    pub fn visit(self: *EnumMemberLookup, name: Atom, value: TypeId) Error!void {
        if (self.found or name != self.want) return;
        self.found = true;
        self.value = value;
    }
};

/// Does enum `sym` declare a member called `name`?
pub fn enumHasMemberNamed(c: *Checker, sym: SymbolId, name: Atom) Error!bool {
    var look: EnumMemberLookup = .{ .want = name };
    try c.eachEnumMember(sym, &look, EnumMemberLookup.visit);
    return look.found;
}

/// The constant VALUE literal of enum member `sym.name` (`"a"` / `0`), or
/// null when the member is absent or its value is computed. tsc makes a
/// member type a subtype of exactly this literal — that is what lets
/// `const k: "keydown" = EVENT.KEYDOWN` type-check while
/// `const k: "paste" = EVENT.KEYDOWN` does not.
pub fn enumMemberValue(c: *Checker, sym: SymbolId, name: Atom) Error!?TypeId {
    var look: EnumMemberLookup = .{ .want = name };
    try c.eachEnumMember(sym, &look, EnumMemberLookup.visit);
    if (!look.found or look.value == types.no_type) return null;
    return look.value;
}

pub const EnumMemberCollect = struct {
    c: *Checker,
    list: *std.ArrayList(TypeId),
    sym: SymbolId,
    skip: Atom = 0,
    pub fn visit(self: *EnumMemberCollect, name: Atom, value: TypeId) Error!void {
        _ = value;
        if (name == self.skip) return;
        const t = try self.c.ts.makeEnumMember(self.sym, name, false);
        for (self.list.items) |e| {
            if (e == t) return; // a re-declared member name is one type
        }
        try self.list.append(self.c.scratch(), t);
    }
};

/// The union of an enum's member TYPES (`E.A | E.B`) — tsc's actual
/// declared type of `E`, which is why narrowing a whole-enum reference
/// subtracts members and why `E` relates to `E.A | E.B`. `skip` drops one
/// member (the `x !== E.A` branch). Null for a member-less enum.
pub fn enumMemberTypeUnion(c: *Checker, sym: SymbolId, skip: Atom) Error!?TypeId {
    var list: std.ArrayList(TypeId) = .empty;
    defer list.deinit(c.scratch());
    var collect: EnumMemberCollect = .{ .c = c, .list = &list, .sym = sym, .skip = skip };
    try c.eachEnumMember(sym, &collect, EnumMemberCollect.visit);
    if (list.items.len == 0) return null;
    return try c.ts.makeUnion(c.scratch(), list.items);
}

/// Whether an enum has any string-valued member (non-allocating scan).
/// A string enum is stringish; an all-numeric enum is numberish — this
/// lets numeric enums take part in arithmetic/comparison like `number`.
pub fn enumHasStringMember(c: *Checker, sym: SymbolId) bool {
    if (c.enum_info_cache.get(sym)) |info| return !info.all_numeric;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const init_node = c.tree.nodeData(m).lhs;
            if (init_node != null_node and c.classifyEnumInit(init_node).kind == .string) return true;
        }
    }
    return false;
}

/// The value object of an enum (`typeof E`): one readonly property per
/// member, each typed as that member's own type `E.<name>` — FRESH, so a
/// member read widens to `E` at a mutable position (`let x = E.A` is `E`)
/// while a `const` keeps the member (`const x = E.A` is `E.A`), exactly as
/// a string literal does.
pub fn enumValueType(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.enum_value_cache.get(sym)) |t| return t;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.EnumData, d.lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const name = try c.memberAtom(c.tree.nodeMainToken(m));
            var dup = false;
            for (props.items) |p| {
                if (p.name == name) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue; // first declaration wins (unique object keys)
            const mt = try c.ts.makeEnumMember(sym, name, true);
            try props.append(c.scratch(), .{ .name = name, .ty = mt, .flags = types.prop_flag_readonly });
        }
    }
    const result = try c.ts.makeObject(props.items, 0, 0, 0);
    try c.enum_value_cache.put(c.cm(), sym, result);
    return result;
}

/// Nominal enum assignability. Identical types (same enum, same member)
/// are caught by `s == t` upstream, and `E.A → E` by the `literalBaseOf`
/// fast path, so what is left here is the widening in and out of the
/// primitive domain. Oracle-verified: a numeric enum (and a numeric
/// *member*) interconverts with `number` and accepts a numeric literal of
/// its own value; a string enum is a subtype of `string` but nothing —
/// not `string`, not the matching string literal — widens *into* it; and
/// `E → E.A`, `E.A → E.B` and `E1.A → E2.A` are all rejected.
pub fn enumAssignable(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
    if (sk == .enum_type and tk == .enum_type) return false;
    if (sk == .enum_type) {
        if (c.ts.isEnumMember(s)) {
            // A member widens to the primitive domain of its OWN value, so
            // a string member of a mixed enum still reaches `string`.
            if (try c.enumMemberValue(c.ts.enumSymbol(s), c.ts.enumMemberAtom(s))) |v| {
                return switch (c.ts.kind(v)) {
                    .string_literal => tk == .string,
                    else => tk == .number,
                };
            }
        }
        const info = try c.enumInfo(c.ts.enumSymbol(s));
        if (tk == .number and info.all_numeric) return true;
        if (tk == .string and info.all_string) return true;
        return false;
    }
    // tk == .enum_type
    const info = try c.enumInfo(c.ts.enumSymbol(t));
    if (!info.all_numeric) return false;
    if (sk == .number) return true;
    if (sk != .number_literal and sk != .number_literal_fresh) return false;
    if (c.ts.isEnumMember(t)) {
        // Only the literal equal to *this* member's value: `const p: N.P = 1`
        // is legal, `const p: N.P = 2` is not.
        const v = (try c.enumMemberValue(c.ts.enumSymbol(t), c.ts.enumMemberAtom(t))) orelse
            return true; // computed member: opaque, stay lenient
        if (c.ts.kind(v) == .string_literal) return false;
        return c.ts.numberValue(v) == c.ts.numberValue(s);
    }
    if (info.has_computed) return true;
    return info.hasValue(c.ts.numberValue(s));
}

/// Does a string-valued member of enum `sym` have the value `val`? Used by
/// the *comparable* relation (TS2367): a string enum overlaps a string
/// literal equal to one of its member values, even though the literal is
/// not assignable into the nominal enum.
pub fn enumHasStringValue(c: *Checker, sym: SymbolId, val: Atom) Error!bool {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.EnumData, d.lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const init_node = c.tree.nodeData(m).lhs;
            if (init_node == null_node or c.nodeTag(init_node) != .string_literal) continue;
            if ((try c.memberAtom(c.tree.nodeMainToken(init_node))) == val) return true;
        }
    }
    return false;
}

/// Type-check an enum declaration: validate member initializers (TS1061)
/// and check any initializer expressions.
pub fn checkEnum(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.EnumData, d.lhs);
    // A member with no initializer is only legal when the previous member
    // (or the start of the enum) is a numeric constant it can continue.
    var prev_numeric_const = true;
    for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
        if (m == null_node or c.nodeTag(m) != .enum_member) continue;
        const init_node = c.tree.nodeData(m).lhs;
        if (init_node == null_node) {
            if (!prev_numeric_const) {
                try c.diagFmt(1061, c.tokSpan(c.tree.nodeMainToken(m)), "Enum member must have initializer.", .{});
            }
            continue; // auto-increment continues the numeric chain
        }
        _ = try c.checkExprCached(init_node, types.no_type);
        // Only a string-valued member blocks a following bare member. A
        // non-literal ("computed") initializer may still be a constant
        // enum expression (e.g. a reference to a `const`), which tsc lets
        // a subsequent member continue — so we don't force TS1061 there.
        prev_numeric_const = c.classifyEnumInit(init_node).kind != .string;
    }
}

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
        // `this` inside a static member is the class's constructor type,
        // exactly as `classStaticType` sets it before resolving one.
        const saved_this = c.this_type;
        defer c.this_type = saved_this;
        c.this_type = try c.ts.makeClassValue(cls);
        return .{ .name = name, .ty = try c.typeOfSymbol(msym), .flags = flags };
    }
    return null;
}

pub fn classStaticType(c: *Checker, sym: SymbolId) Error!TypeId {
    if (c.class_static_cache.get(sym)) |t| return t;
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
    }
    var result = try c.ts.makeObject(props.items, 0, 0, 0);
    // Static members are inherited: `typeof D` includes `typeof Base`'s
    // statics (own members win over inherited). This is how leaflet's
    // `Map.include`/`GridLayer.extend` reach the static `extend`/`include`
    // declared on the root `class Class`. Guard the recursion against a
    // malformed `extends` cycle without poisoning the result cache — a
    // static-field initializer that reads a sibling static re-enters this
    // function and must still see the class's own members.
    if (!c.class_static_base_active.contains(sym)) {
        if (try c.baseClassSym(sym)) |base| {
            try c.class_static_base_active.put(c.cm(), sym, {});
            const base_static = try c.classStaticType(base);
            _ = c.class_static_base_active.remove(sym);
            result = try c.mergeBaseObject(result, base_static, false);
        }
    }
    try c.class_static_cache.put(c.cm(), sym, result);
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
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    if (c.ts.kind(statics) == .object) {
        for (0..c.ts.objectPropCount(statics)) |i| {
            try props.append(c.scratch(), c.ts.objectProp(statics, @intCast(i)));
        }
    }
    const obj = try c.ts.makeObjectSigs(props.items, 0, 0, types.obj_flag_not_inferable, &.{}, sigs.items);
    try c.class_ctor_cache.put(c.cm(), cls, obj);
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
pub fn ctorSignatures(c: *Checker, sym: SymbolId, out: *std.ArrayList(TypeId)) Error!void {
    var cur = sym;
    var depth: u32 = 0;
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
                    if (d.rhs == 0) try out.append(c.scratch(), sig);
                }
                if (out.items.len == 0) {
                    for (c.bind.declsOf(csym)) |decl| {
                        if (c.nodeTag(decl) != .class_method) continue;
                        const d = c.tree.nodeData(decl);
                        if (d.rhs != 0) {
                            try out.append(c.scratch(), try c.signatureOfProto(decl, d.lhs, true, true));
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
                    try out.append(c.scratch(), c.ts.objectConstructSig(base_ctor, @intCast(i)));
                }
            }
            return;
        };
        cur = c.ts.refSymbol(base);
    }
}

pub const TpMap = struct { sym: SymbolId, ty: TypeId };
pub const InferKey = struct { cond: u64, name: Atom };

/// Whether a higher-order signature is safe to instantiate-and-keep.
/// The rewrite substitutes the sig body and mints fresh symbols for own
/// params whose bounds move under the map. It is sound only when every own
/// param's constraint/default is *bare* (a plain type param) or absent: then
/// the fresh param needs no constraint enforcement (a bare bound was never
/// enforceable anyway — the `bare_outer` escape in `inferTypeArgs`) and its
/// default is a simple substitution. A sig with a *structured* bound (RHF's
/// `<TName extends FieldPath<TFieldValues>>`, whose `Path`/`PathValue` deep
/// conditional+template types ztsc can't fully reduce) is NOT eligible: it
/// is dropped exactly as before this rewrite, so those call sites keep their
/// pristine behavior (no churn) instead of trading one unreducible-type
/// diagnostic for another.
pub fn higherOrderSigEligible(c: *Checker, sig: TypeId) Error!bool {
    // Index, never a held `fnTypeParams` slice: resolving a bound
    // materializes it from the AST and interns, which can grow the store's
    // `extra` array out from under the iterator (the `memberAt` rule). A
    // held slice here segfaulted mid-check on drizzle-orm once the
    // partition put the right pair of files on one checker.
    for (0..c.ts.fnTypeParamCount(sig)) |i| {
        const p = c.ts.fnTypeParamAt(sig, i);
        const con = try c.typeParamConstraint(p);
        if (con != types.no_type and c.ts.kind(con) != .type_param and !try c.boundReducible(con, 0) and !try c.boundHasReducerShape(con, 0)) return false;
        const def = try c.typeParamDefault(p);
        if (def != types.no_type and c.ts.kind(def) != .type_param and !try c.boundReducible(def, 0) and !try c.boundHasReducerShape(def, 0)) return false;
    }
    return true;
}

/// Complements `boundReducible`: a structured bound the landed reducer chain
/// now drives home even though a static structural walk can't prove it
/// reduces. True when the bound contains a template-literal pattern (the RHF
/// `Path`/`FieldPath` dotted-path builder — reduced by template-hole
/// enumeration) or a mapped type (RHF `RegisterOptions`). Such a bound makes
/// its higher-order signature `higherOrderSigEligible`, so an instantiated
/// generic interface method (`register`/`watch`/`setValue` on a concrete
/// `UseFormReturn<F>`) relates its field-name literal against the reduced
/// `Path<F>` union. A bare `infer`-over-tuple bound (redux
/// `ExtractStoreExtensionsFromEnhancerTuple`) has neither shape and stays
/// gated — the reducer can't peel it, so its sig keeps the pristine drop.
pub fn boundHasReducerShape(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 6) return false;
    const s = &c.ts;
    switch (s.kind(t)) {
        .template_literal_type, .mapped => return true,
        .conditional => return (try c.boundHasReducerShape(s.condCheck(t), depth + 1)) or
            (try c.boundHasReducerShape(s.condExtends(t), depth + 1)) or
            (try c.boundHasReducerShape(s.condTrue(t), depth + 1)) or
            (try c.boundHasReducerShape(s.condFalse(t), depth + 1)),
        .array => return c.boundHasReducerShape(s.arrayElem(t), depth + 1),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try c.boundHasReducerShape(s.tupleElem(t, @intCast(i)).ty, depth + 1)) return true;
            }
            return false;
        },
        .union_type, .intersection, .overloads => {
            for (try c.memberList(t)) |m| {
                if (try c.boundHasReducerShape(m, depth + 1)) return true;
            }
            return false;
        },
        .keyof_op => return c.boundHasReducerShape(s.keyofOperand(t), depth + 1),
        .index_access => return (try c.boundHasReducerShape(s.indexAccessObj(t), depth + 1)) or
            (try c.boundHasReducerShape(s.indexAccessIndex(t), depth + 1)),
        .ref => {
            const sym = s.refSymbol(t);
            // Indexed: the recursion can reach `aliasGeneric` (below) and
            // intern types, invalidating a held `refArgs` slice.
            for (0..s.refArgCount(t)) |i| {
                if (try c.boundHasReducerShape(s.refArgAt(t, i), depth + 1)) return true;
            }
            if (c.symFlags(sym).type_alias) {
                return c.boundHasReducerShape(try c.aliasGeneric(sym), depth + 1);
            }
            return false;
        },
        else => return false,
    }
}

/// Whether an own-param *bound* (constraint/default) reduces once its
/// enclosing generic is substituted — the gate for whether a higher-order
/// sig is safe to rewrite. A *bare* bound is handled elsewhere; this
/// judges structured bounds. A plain conditional (`DBTypes extends DBSchema
/// ? … : …`, idb) or `keyof T` reduces once its check type is concrete and
/// is eligible. A bound whose evaluation needs recursive peeling ztsc can't
/// perform — a template-literal pattern (`${infer K}.${infer R}`, RHF
/// `Path`) or an `infer`-bearing conditional (redux
/// `ExtractStoreExtensionsFromEnhancerTuple`) — is not. Alias refs are
/// expanded (depth-capped; the cap trips to *not reducible*, the safe side,
/// so a deep recursive alias like `Path` is excluded).
pub fn boundReducible(c: *Checker, t: TypeId, depth: u32) Error!bool {
    if (depth > 6) return false;
    const s = &c.ts;
    switch (s.kind(t)) {
        .template_literal_type, .string_mapping, .infer_var, .mapped => return false,
        .conditional => {
            // An `infer` in the extends clause means the bound is peeled
            // structurally (recursive tuple/string walks ztsc can't do).
            if (try c.containsInfer(s.condExtends(t))) return false;
            return (try c.boundReducible(s.condCheck(t), depth + 1)) and
                (try c.boundReducible(s.condExtends(t), depth + 1)) and
                (try c.boundReducible(s.condTrue(t), depth + 1)) and
                (try c.boundReducible(s.condFalse(t), depth + 1));
        },
        .array => return c.boundReducible(s.arrayElem(t), depth + 1),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (!try c.boundReducible(s.tupleElem(t, @intCast(i)).ty, depth + 1)) return false;
            }
            return true;
        },
        .union_type, .intersection, .overloads => {
            for (try c.memberList(t)) |m| {
                if (!try c.boundReducible(m, depth + 1)) return false;
            }
            return true;
        },
        .keyof_op => return c.boundReducible(s.keyofOperand(t), depth + 1),
        .index_access => return (try c.boundReducible(s.indexAccessObj(t), depth + 1)) and
            (try c.boundReducible(s.indexAccessIndex(t), depth + 1)),
        .ref => {
            // Expand a type-alias ref to inspect its body (`FieldPath<T>` →
            // `Path<T>` → the template/infer core). Interface/class refs are
            // structural objects — reducible, no expansion needed. Also check
            // the ref's own type arguments.
            const sym = s.refSymbol(t);
            // Indexed: see `boundHasReducerShape` — `aliasGeneric` interns.
            for (0..s.refArgCount(t)) |i| {
                if (!try c.boundReducible(s.refArgAt(t, i), depth + 1)) return false;
            }
            if (c.symFlags(sym).type_alias) {
                return c.boundReducible(try c.aliasGeneric(sym), depth + 1);
            }
            return true;
        },
        else => return true,
    }
}

/// Whether an object call/construct signature `sig` references a type param
/// bound *outside* itself — structurally (excluding its own `<...>`), or
/// through one of its own params' constraint/default (`<U extends C<T>>`,
/// where `T` is the enclosing generic's param). Such a signature must be
/// (re-)instantiated with the enclosing generic; one that mentions only its
/// own params is self-contained. `bound` is the enclosing type-param scope.
/// A higher-order sig that is not `higherOrderSigEligible` is treated as
/// self-contained (returns false) so instantiation skips it — the pristine,
/// pre-rewrite behavior.
pub fn sigReferencesOuterParam(c: *Checker, sig: TypeId, bound: []const u32) Error!bool {
    const n_own = c.ts.fnTypeParamCount(sig);
    if (n_own != 0 and !try c.higherOrderSigEligible(sig)) return false;
    if (try c.containsFreeTypeParam(sig, bound)) return true;
    if (n_own == 0) return false;
    // Own params are copied out *after* the two calls above: both intern, and
    // a `fnTypeParams` slice held across an intern is dead (see `memberAt`).
    const own = try c.scratch().dupe(u32, c.ts.fnTypeParams(sig));
    // Inside the sig, both the enclosing scope and the sig's own params are
    // bound; a constraint/default reaching anything else is an outer ref.
    var scope: std.ArrayList(u32) = .empty;
    defer scope.deinit(c.scratch());
    try scope.appendSlice(c.scratch(), bound);
    try scope.appendSlice(c.scratch(), own);
    for (own) |p| {
        const con = try c.typeParamConstraint(p);
        if (con != types.no_type and try c.containsFreeTypeParam(con, scope.items)) return true;
        const def = try c.typeParamDefault(p);
        if (def != types.no_type and try c.containsFreeTypeParam(def, scope.items)) return true;
    }
    return false;
}

pub fn containsTypeParam(c: *Checker, t: TypeId) Error!bool {
    const v = c.triGet(&c.ctp_cache, t);
    if (v != 0) return v == 2;
    try c.triSet(&c.ctp_cache, t, 1); // assume no while computing (cycles)
    const result = try c.containsTypeParamInner(t);
    try c.triSet(&c.ctp_cache, t, if (result) 2 else 1);
    return result;
}

pub fn containsTypeParamInner(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    switch (s.kind(t)) {
        .type_param => return true,
        // Indexed walk, not a `memberList` dupe: the recursion can reach
        // `sigReferencesOuterParam` -> `typeFromTypeNode`, which interns
        // and may move `extra`. See `Store.memberAt`.
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| {
                if (try c.containsTypeParam(s.memberAt(t, i))) return true;
            }
            return false;
        },
        .array => return c.containsTypeParam(s.arrayElem(t)),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try c.containsTypeParam(s.tupleElem(t, @intCast(i)).ty)) return true;
            }
            return false;
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.containsTypeParam(s.objectProp(t, @intCast(i)).ty)) return true;
            }
            if (s.objectStringIndex(t) != 0 and try c.containsTypeParam(s.objectStringIndex(t))) return true;
            if (s.objectNumberIndex(t) != 0 and try c.containsTypeParam(s.objectNumberIndex(t))) return true;
            // A call/construct signature may reference a type param that
            // appears nowhere else (a callable interface whose only generic
            // use is its signature, e.g. `interface B<T,Y> { (...a:Y):T }`);
            // without this the object is judged concrete and instantiation
            // skips it, leaving the sig unsubstituted. A *higher-order* sig
            // (`<U extends C<T>>(…)`) counts too when it reaches the outer
            // `T` through its own param's constraint/default — the higher-order
            // rewrite substitutes those, so instantiation must be triggered.
            for (0..s.objectCallSigCount(t)) |i| {
                if (try c.sigReferencesOuterParam(s.objectCallSig(t, @intCast(i)), &.{})) return true;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (try c.sigReferencesOuterParam(s.objectConstructSig(t, @intCast(i)), &.{})) return true;
            }
            return false;
        },
        .function => {
            if (try c.containsTypeParam(s.fnReturn(t))) return true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.containsTypeParam(s.fnParam(t, @intCast(i)).ty)) return true;
            }
            // The type predicate's guarded type (`x is S`) can carry a type
            // param not present anywhere else in the signature.
            if (s.fnHasPredicate(t)) {
                const pr = s.fnPredicate(t);
                if (pr.ty != types.no_type and try c.containsTypeParam(pr.ty)) return true;
            }
            return false;
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| {
                if (try c.containsTypeParam(s.refArgAt(t, i))) return true;
            }
            return false;
        },
        // `this@I<T…>` is generic exactly when its home instance is (see
        // the `.this_type` arm of `instantiateId`).
        .this_type => return c.containsTypeParam(s.thisTypeInstance(t)),
        // A deferred conditional is "generic" (deferrable) iff any part
        // still mentions an *outer* type param. `infer_var` binders are not
        // type params, so they never make a conditional generic.
        .conditional => {
            if (try c.containsTypeParam(s.condCheck(t))) return true;
            if (try c.containsTypeParam(s.condExtends(t))) return true;
            if (try c.containsTypeParam(s.condTrue(t))) return true;
            if (try c.containsTypeParam(s.condFalse(t))) return true;
            return false;
        },
        .index_access => {
            if (try c.containsTypeParam(s.indexAccessObj(t))) return true;
            if (try c.containsTypeParam(s.indexAccessIndex(t))) return true;
            return false;
        },
        // A deferred mapped type needs (re-)instantiation while *any* part
        // still mentions an outer type param — the value/`as` branches as
        // well as the key set, so a `{[K in "a"]: T}` with generic `T` is
        // reached and its props substituted. Whether it *materializes* vs
        // stays deferred is decided separately (by the key set) in
        // `reduceMapped`. The `mapped_param` key is not an outer param.
        .mapped => {
            if (try c.containsTypeParam(s.mappedConstraint(t))) return true;
            if (try c.containsTypeParam(s.mappedValue(t))) return true;
            if (s.mappedAs(t) != 0 and try c.containsTypeParam(s.mappedAs(t))) return true;
            if (s.mappedSource(t) != 0 and try c.containsTypeParam(s.mappedSource(t))) return true;
            return false;
        },
        // A template-literal pattern / string-mapping is generic (deferred)
        // iff a hole / the argument still mentions an outer type param.
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.containsTypeParam(s.templateHole(t, @intCast(i)))) return true;
            }
            return false;
        },
        .string_mapping => return c.containsTypeParam(s.stringMappingArg(t)),
        .keyof_op => return c.containsTypeParam(s.keyofOperand(t)),
        else => return false,
    }
}

/// True iff `t` mentions a *free* type parameter — one not bound by an
/// enclosing signature's own `<...>`. Unlike `containsTypeParam`, a
/// signature's own params are treated as bound (not free), so
/// `{ f: <T>() => T }` reports **false**: it is a concrete object whose
/// only type variables are locally quantified. Used to decide whether an
/// indexed access `Obj[K]` is genuinely generic (must defer) or resolvable
/// now — indexing/mapping over such an object must reduce eagerly, else the
/// generic member is stranded as an unresolved `Obj["f"]` and lost.
/// `bound` is the stack of type-param symbols currently in scope.
pub fn containsFreeTypeParam(c: *Checker, t: TypeId, bound: []const u32) Error!bool {
    const s = &c.ts;
    // No enclosing signature scope and no free var found up to here: the
    // cached whole-type predicate is an exact, cheaper answer.
    if (bound.len == 0 and !try c.containsTypeParam(t)) return false;
    switch (s.kind(t)) {
        .type_param => {
            const sym = s.typeParamSymbol(t);
            for (bound) |b| {
                if (b == sym) return false; // bound by an enclosing signature
            }
            return true;
        },
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| {
                if (try c.containsFreeTypeParam(s.memberAt(t, i), bound)) return true;
            }
            return false;
        },
        .array => return c.containsFreeTypeParam(s.arrayElem(t), bound),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try c.containsFreeTypeParam(s.tupleElem(t, @intCast(i)).ty, bound)) return true;
            }
            return false;
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.containsFreeTypeParam(s.objectProp(t, @intCast(i)).ty, bound)) return true;
            }
            if (s.objectStringIndex(t) != 0 and try c.containsFreeTypeParam(s.objectStringIndex(t), bound)) return true;
            if (s.objectNumberIndex(t) != 0 and try c.containsFreeTypeParam(s.objectNumberIndex(t), bound)) return true;
            return false;
        },
        .function => {
            // The signature's own type params shadow within its body, so
            // extend the bound set before descending.
            const own = s.fnTypeParams(t);
            var scope_buf: std.ArrayList(u32) = .empty;
            defer scope_buf.deinit(c.scratch());
            const inner: []const u32 = if (own.len == 0) bound else blk: {
                try scope_buf.appendSlice(c.scratch(), bound);
                try scope_buf.appendSlice(c.scratch(), own);
                break :blk scope_buf.items;
            };
            if (try c.containsFreeTypeParam(s.fnReturn(t), inner)) return true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.containsFreeTypeParam(s.fnParam(t, @intCast(i)).ty, inner)) return true;
            }
            if (s.fnHasPredicate(t)) {
                const pr = s.fnPredicate(t);
                if (pr.ty != types.no_type and try c.containsFreeTypeParam(pr.ty, inner)) return true;
            }
            return false;
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| {
                if (try c.containsFreeTypeParam(s.refArgAt(t, i), bound)) return true;
            }
            return false;
        },
        .conditional => {
            if (try c.containsFreeTypeParam(s.condCheck(t), bound)) return true;
            if (try c.containsFreeTypeParam(s.condExtends(t), bound)) return true;
            if (try c.containsFreeTypeParam(s.condTrue(t), bound)) return true;
            if (try c.containsFreeTypeParam(s.condFalse(t), bound)) return true;
            return false;
        },
        .index_access => {
            if (try c.containsFreeTypeParam(s.indexAccessObj(t), bound)) return true;
            if (try c.containsFreeTypeParam(s.indexAccessIndex(t), bound)) return true;
            return false;
        },
        .mapped => {
            if (try c.containsFreeTypeParam(s.mappedConstraint(t), bound)) return true;
            if (try c.containsFreeTypeParam(s.mappedValue(t), bound)) return true;
            if (s.mappedAs(t) != 0 and try c.containsFreeTypeParam(s.mappedAs(t), bound)) return true;
            if (s.mappedSource(t) != 0 and try c.containsFreeTypeParam(s.mappedSource(t), bound)) return true;
            return false;
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.containsFreeTypeParam(s.templateHole(t, @intCast(i)), bound)) return true;
            }
            return false;
        },
        .string_mapping => return c.containsFreeTypeParam(s.stringMappingArg(t), bound),
        .keyof_op => return c.containsFreeTypeParam(s.keyofOperand(t), bound),
        else => return false,
    }
}

pub fn tpLookup(map: []const TpMap, sym: SymbolId) ?TypeId {
    for (map) |m| {
        if (m.sym == sym) return m.ty;
    }
    return null;
}

/// Canonicalize a substitution map to a stable small id: sort the
/// `(sym, arg)` pairs and intern the packed bytes. Two maps with the same
/// `(sym → arg)` set (regardless of slice order or identity) get the same
/// id, so the id keys the instantiate memo soundly. Called once per
/// top-level `instantiate`; the id is threaded down the recursion unchanged.
pub fn canonMapId(c: *Checker, map: []const TpMap) Error!u32 {
    const sorted = try c.scratch().dupe(TpMap, map);
    std.mem.sort(TpMap, sorted, {}, struct {
        fn lt(_: void, a: TpMap, b: TpMap) bool {
            return a.sym < b.sym;
        }
    }.lt);
    // Pack each pair as two little-endian u32 words (8 bytes/pair).
    const bytes = try c.scratch().alloc(u8, sorted.len * 8);
    for (sorted, 0..) |m, i| {
        std.mem.writeInt(u32, bytes[i * 8 ..][0..4], m.sym, .little);
        std.mem.writeInt(u32, bytes[i * 8 + 4 ..][0..4], m.ty, .little);
    }
    const gop = try c.inst_map_ids.getOrPut(c.cm(), bytes);
    if (!gop.found_existing) {
        gop.key_ptr.* = try c.ca().dupe(u8, bytes); // scratch is reset per stmt
        gop.value_ptr.* = c.inst_map_next;
        c.inst_map_next += 1;
        c.stats.inst_maps += 1;
    }
    return gop.value_ptr.*;
}

/// True for a fresh higher-order type-param symbol (`fresh_tp_ids`).
pub inline fn isFreshTp(c: *const Checker, sym: SymbolId) bool {
    return c.fresh_tp_base != 0 and sym >= c.fresh_tp_base;
}

/// Bounds record for a fresh higher-order type-param symbol.
pub fn freshTp(c: *const Checker, sym: SymbolId) *const FreshTp {
    return &c.fresh_tp_info.items[sym - c.fresh_tp_base];
}

/// Does type-parameter symbol `sym` carry the TS 5.0 `const` modifier? The
/// bounds guard is load-bearing: a type-param symbol id can be a FRESH
/// higher-order one (minted above the whole real + merged symbol space), which
/// indexes no per-symbol flag array.
pub inline fn isConstTypeParamSym(c: *const Checker, sym: SymbolId) bool {
    if (c.isFreshTp(sym)) return c.freshTp(sym).const_tp;
    return c.symFlags(sym).const_type_param;
}

/// Mint (or reuse) a fresh symbol for own type-param `orig` when a
/// signature is instantiated under `map` (canonical id `map_id`, computed
/// on demand when memoization is off). The fresh symbol carries the
/// already-`map`-substituted `constraint`/`default`. Deterministic and
/// memoized per `(orig, canonical map)`, so a repeat instantiation reuses
/// the same id (interning coherence).
pub fn mintFreshTp(c: *Checker, orig: SymbolId, map: []const TpMap, map_id: ?u32, constraint: TypeId, default: TypeId, has_default: bool, widen_bound: TypeId) Error!u32 {
    const mid: u32 = map_id orelse try c.canonMapId(map);
    const key = (@as(u64, orig) << 32) | mid;
    const gop = try c.fresh_tp_ids.getOrPut(c.cm(), key);
    if (!gop.found_existing) {
        gop.value_ptr.* = c.fresh_tp_next;
        c.fresh_tp_next += 1;
        try c.fresh_tp_info.append(c.cm(), .{
            .name = c.symNameAtom(orig),
            .constraint = constraint,
            .default = default,
            .has_default = has_default,
            .const_tp = c.isConstTypeParamSym(orig),
            .widen_bound = widen_bound,
        });
    }
    return gop.value_ptr.*;
}

/// Substitute the type parameters in `map` throughout `t`. Public entry:
/// canonicalizes the map (when caching is on) and dispatches to the
/// memoized recursive walk.
pub fn instantiate(c: *Checker, t: TypeId, map: []const TpMap) Error!TypeId {
    if (map.len == 0) return t;
    if (!try c.containsTypeParam(t)) return t;
    // At the outermost substitution, route every transient allocation the
    // call tree makes (worklists in `instantiateId`, the reduction helpers'
    // scratch, `makeUnion`/`makeObject` temporaries) into `inst_arena` by
    // swapping it in for `scratch_arena`, then release it on exit. This
    // bounds the per-statement scratch high-water to the single largest
    // instantiation rather than the sum of every one a statement performs
    // (a JSX return that materializes many generic component props spiked
    // the old shared arena to ~130 MB and it stuck for the process).
    // Safe because the tree keeps nothing past its own return: the result
    // is interned into `ts`, and any persistent key is copied into `carena`
    // (`canonMapId`/`mintFreshTp`) or the permanent output arena
    // (`diagFmt`) — the same discipline that already lets scratch reset per
    // statement. The swap is restored (and the arena released) on every
    // exit including errors, so `scratch_arena` is the shared arena
    // everywhere outside a top-level `instantiate`.
    if (c.inst_depth == 0) {
        // Reset the truncation flag at each top-level entry so a limit trip
        // in one instantiation never suppresses caching of the next.
        c.inst_limit_tripped = false;
        const saved = c.scratch_arena;
        c.scratch_arena = c.inst_arena;
        defer {
            const cap = c.inst_arena.queryCapacity();
            if (cap > c.stats.scratch_high_water) c.stats.scratch_high_water = cap;
            _ = c.inst_arena.reset(.{ .retain_with_limit = scratch_retain_limit });
            c.scratch_arena = saved;
        }
        const map_id: ?u32 = if (c.inst_cache_on) try c.canonMapId(map) else null;
        return c.instantiateId(t, map, map_id);
    }
    const map_id: ?u32 = if (c.inst_cache_on) try c.canonMapId(map) else null;
    return c.instantiateId(t, map, map_id);
}

/// Record the origin of a re-instantiated generic materialization. This is
/// bookkeeping, so it must not *report* anything: the origin-arg
/// substitution runs with diagnostics suppressed and restores the caller's
/// live depth and truncation flag. A trip during arg substitution just
/// yields a non-matching origin ref (safe: the reflexive fast-path simply
/// won't fire, falling back to the structural walk).
///
/// `inst_count` is deliberately *not* restored. It used to be, on the
/// reasoning that bookkeeping should not spend the TS2589 budget — but
/// that made the budget a function of traversal order rather than of the
/// program. Substitution results are memoized (`inst_cache`), so only the
/// *first* visit of a given `(map_id, type)` pair is counted; whether that
/// first visit lands inside one of these windows or outside it depends on
/// the order the checker reaches types in. That order is not run-to-run
/// stable: atom ids come from the interner's per-shard insertion order,
/// which the parallel front end varies between runs, and atoms are sort
/// keys for a scope's member table (`binder.Binder.seal`) and for a merged
/// namespace's member index (`modules.Merger.buildNsMembers`). Restoring
/// the count therefore subtracted a run-varying amount from it: on
/// drizzle-orm at `--checkers=1`, repeat runs of the same binary on the
/// same input charged 56,988 / 57,018 / 57,093 of an invariant 57,359
/// node-visits. Counting every visit, here as everywhere else, makes the
/// budget equal to the work the program actually demands — which *is*
/// run-to-run invariant — at the cost of charging origin tagging for the
/// visits it really performs.
pub fn tagInstantiatedOrigin(c: *Checker, result: TypeId, orig_ref: TypeId, map: []const TpMap, map_id: ?u32) Error!void {
    const saved_depth = c.inst_depth;
    const saved_trip = c.inst_limit_tripped;
    const saved_suppress = c.suppress_inst_diag;
    c.suppress_inst_diag = true;
    defer {
        c.inst_depth = saved_depth;
        c.inst_limit_tripped = saved_trip;
        c.suppress_inst_diag = saved_suppress;
    }
    var oargs: std.ArrayList(TypeId) = .empty;
    defer oargs.deinit(c.scratch());
    // Index, never a held `refArgs` slice: `instantiateId` interns types and
    // can grow the store's `extra` array out from under it (the same
    // iterator-invalidation class as the `memberList`/`fnParam` loops, which
    // all index for this reason). A held slice here segfaulted on a large
    // program once the partition put enough instantiation on one checker.
    const n_oargs = c.ts.refArgCount(orig_ref);
    try oargs.ensureTotalCapacity(c.scratch(), n_oargs);
    for (0..n_oargs) |i| {
        const a = c.ts.refArgAt(orig_ref, i);
        oargs.appendAssumeCapacity(try c.instantiateId(a, map, map_id));
    }
    const new_ref = try c.ts.makeRef(c.ts.refSymbol(orig_ref), oargs.items);
    try c.origin.put(c.cm(), result, new_ref);
}

/// Memoized recursive substitution. `map_id` (when non-null) canonically
/// identifies `map`; it keys the memo and is threaded unchanged down the
/// True when `t` already occupies `max_chain_repeats` of the
/// `instantiateId` frames currently on the stack — a cycle through `t`,
/// as opposed to a merely deep expansion.
pub fn chainRepeats(c: *const Checker, t: TypeId) bool {
    if (c.inst_depth < chain_scan_floor) return false;
    var reps: u32 = 0;
    for (c.inst_chain[0..c.inst_depth]) |a| {
        if (a != t) continue;
        reps += 1;
        if (reps >= max_chain_repeats) return true;
    }
    return false;
}

/// recursion. A `null` id disables the memo (`--no-inst-cache`).
pub fn instantiateId(c: *Checker, t: TypeId, map: []const TpMap, map_id: ?u32) Error!TypeId {
    // Per-constituent rebinding of a distributive conditional whose check is
    // no longer a bare type parameter — see the `.conditional` arm. Asked
    // before the type-parameter early-out, because the check being rebound
    // (`O[K]`) need not contain one.
    if (c.cond_check_subst) |cs| {
        if (t == cs.from) return cs.to;
    }
    if (!try c.containsTypeParam(t)) return t;
    if (map_id) |mid| {
        if (c.inst_cache.get((@as(u64, mid) << 32) | t)) |r| {
            c.stats.inst_hits += 1;
            return r;
        }
    }
    c.stats.inst_misses += 1;
    // Depth/count guard — cache-independent, so it fires identically with
    // the memo on or off. Exceeding it is TS2589 (excessively deep /
    // possibly infinite): report once at the materialization site and
    // truncate this subtree to `error_type`.
    // A non-terminating recursive-alias cycle: this exact type is already
    // being instantiated `max_chain_repeats` levels up. Cut it, silently
    // (see the constant, and the under-report policy the sibling cases in
    // test/conformance/instantiation record).
    if (c.chainRepeats(t)) {
        c.inst_limit_tripped = true;
        return types.error_type;
    }
    if (c.inst_depth > max_instantiation_depth or c.inst_count > max_instantiation_count) {
        c.inst_limit_tripped = true;
        if (!c.suppress_inst_diag) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return types.error_type;
    }
    c.inst_chain[c.inst_depth] = t;
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    const s = &c.ts;
    const result: TypeId = switch (s.kind(t)) {
        .type_param => tpLookup(map, s.typeParamSymbol(t)) orelse t,
        .union_type => blk: {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..s.memberCount(t)) |i| try parts.append(c.scratch(), try c.instantiateId(s.memberAt(t, i), map, map_id));
            break :blk try s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => blk: {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..s.memberCount(t)) |i| try parts.append(c.scratch(), try c.instantiateId(s.memberAt(t, i), map, map_id));
            const inter = try s.makeIntersection(c.scratch(), parts.items);
            // Propagate the origin tag through instantiation of a callable-
            // object alias that materializes to a kept intersection (RTK's
            // `AsyncThunk<…>` = `AsyncThunkActionCreator<…> & {…}`): the
            // pre-expanded sig-return `t` carries `origin[t] =
            // makeRef(G, own-params)`, and the substituted result denotes
            // `G<args'…>`. Without this the two route-divergent
            // instantiations of the same alias lose all origin identity and
            // the equivalence fast-path cannot fire. Budget-shielded like the
            // object arm.
            if (c.origin.get(t)) |orig_ref| {
                if (inter != t and c.ts.kind(inter) == .intersection) try c.tagInstantiatedOrigin(inter, orig_ref, map, map_id);
            }
            break :blk inter;
        },
        .overloads => blk: {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (0..s.memberCount(t)) |i| try parts.append(c.scratch(), try c.instantiateId(s.memberAt(t, i), map, map_id));
            break :blk try s.makeOverloads(parts.items);
        },
        .array => try s.makeArrayLike(t, try c.instantiateId(s.arrayElem(t), map, map_id)),
        .tuple => blk: {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try c.instantiateId(e.ty, map, map_id), .flags = e.flags });
            }
            break :blk try s.makeTuple(elems.items);
        },
        .object => blk: {
            var props: std.ArrayList(types.Prop) = .empty;
            defer props.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try props.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiateId(p.ty, map, map_id), .flags = p.flags });
            }
            const sidx = if (s.objectStringIndex(t) != 0) try c.instantiateId(s.objectStringIndex(t), map, map_id) else 0;
            const nidx = if (s.objectNumberIndex(t) != 0) try c.instantiateId(s.objectNumberIndex(t), map, map_id) else 0;
            // Call/construct signatures are `.function` types that
            // may mention the interface's type params (e.g. jest's
            // `Mock<T, Y, C>` call sig `(...args: Y): T`). Instantiate each
            // and preserve them via `makeObjectSigs` — dropping them here
            // (the prior `makeObject` path) made an instantiated callable
            // interface non-callable, so `Mock<any, any, any>` was not
            // assignable to any concrete function type.
            // A *higher-order* signature that declares its own type params
            // whose constraints/defaults reference the interface's params
            // (react-redux's `<AD extends DispatchType = DispatchType>(): AD`,
            // TypedUseSelectorHook's `<S>(sel:(st:TState)=>S):S`) is
            // instantiated the same way; the `.function` arm mints fresh
            // symbols for the own params, carrying the substituted
            // constraints/defaults, so the call site resolves them
            // correctly instead of stranding the interface param.
            var call_sigs: std.ArrayList(TypeId) = .empty;
            defer call_sigs.deinit(c.scratch());
            var construct_sigs: std.ArrayList(TypeId) = .empty;
            defer construct_sigs.deinit(c.scratch());
            for (0..s.objectCallSigCount(t)) |i| {
                const sig = s.objectCallSig(t, @intCast(i));
                // A non-eligible higher-order sig (RHF-style deep bound) is
                // dropped — the pristine behavior — so its call sites are
                // unchanged; eligible ones and param-free ones instantiate.
                if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                try call_sigs.append(c.scratch(), try c.instantiateId(sig, map, map_id));
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                const sig = s.objectConstructSig(t, @intCast(i));
                if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                try construct_sigs.append(c.scratch(), try c.instantiateId(sig, map, map_id));
            }
            const obj = try s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
            // Propagate the origin tag through instantiation (see `origin`):
            // if `t` is the pre-expanded materialization of `G<A…>`, the
            // instantiated result denotes `G<A'…>` with each arg substituted
            // by `map`. Bookkeeping is budget-shielded so it never trips
            // TS2589 on unrelated deep instantiations.
            if (c.origin.get(t)) |orig_ref| {
                if (obj != t and c.ts.kind(obj) == .object) try c.tagInstantiatedOrigin(obj, orig_ref, map, map_id);
            }
            break :blk obj;
        },
        .function => blk: {
            const n_tps = s.fnTypeParamCount(t);
            // Higher-order rewrite: an own type param whose
            // constraint/default is changed by `map` (`<U extends C<T>>`
            // under `T:=…`) gets a *fresh* symbol carrying the substituted
            // bounds, and its references in the body are rewritten to it.
            // Params unaffected by `map` keep their original symbol (the
            // AST-derived constraint/default path — zero behavior change).
            var kept: std.ArrayList(u32) = .empty;
            defer kept.deinit(c.scratch());
            var fresh_map: std.ArrayList(TpMap) = .empty;
            defer fresh_map.deinit(c.scratch());
            // The map a bound is substituted under: the incoming one plus
            // every fresh rewrite minted SO FAR in this loop. A bound may
            // name a SIBLING own param — kysely's
            // `where<RE extends ReferenceExpression<DB, TB>,
            //        VE extends OperandValueExpressionOrList<DB, TB, RE>>`
            // is the canonical shape — and substituting it under the bare
            // incoming map left `VE`'s fresh bound pointing at the ORIGINAL
            // `RE`, a symbol nothing ever binds. `RE`'s inferred literal
            // therefore never reached `ExtractTypeFromReferenceExpression`,
            // which stalled as a deferred conditional and rejected every
            // right-hand operand: TS2769 on every `.where(...)` overload set.
            // tsc does the same thing by construction — `instantiateSignature`
            // combines the fresh-parameter mapper INTO the outer one and
            // hands the combination to each cloned parameter.
            var cur_map: std.ArrayList(TpMap) = .empty;
            defer cur_map.deinit(c.scratch());
            var cur_id = map_id;
            // Mint fresh params only for an eligible sig (all own bounds
            // bare/absent); otherwise keep the original params + AST bounds
            // (the pre-rewrite behavior for standalone generic functions).
            const eligible = n_tps != 0 and map.len > 0 and try c.higherOrderSigEligible(t);
            if (eligible) try cur_map.appendSlice(c.scratch(), map);
            // Index: the loop body resolves bounds and instantiates, both of
            // which intern and can move `extra` (see `memberAt`).
            for (0..n_tps) |tp_i| {
                const tp = s.fnTypeParamAt(t, tp_i);
                if (tpLookup(map, tp) != null) continue; // substituted away
                var fresh: ?u32 = null;
                if (eligible) {
                    const od = try c.typeParamDefault(tp);
                    const oc = try c.typeParamConstraint(tp);
                    const nd = if (od != types.no_type) try c.instantiateId(od, cur_map.items, cur_id) else od;
                    const nc = if (oc != types.no_type) try c.instantiateId(oc, cur_map.items, cur_id) else oc;
                    // Fresh param carries the substituted *default* (so a
                    // no-arg `<AD = DispatchType>()` resolves to the supplied
                    // dispatch). Its *constraint* is enforced only when it
                    // was a structured, reducible bound (idb `StoreName
                    // extends StoreNames<DBTypes>` → a concrete store-name
                    // union that makes `"requests"` assignable). A *bare*
                    // bound (`filter<S extends T>`) carries no constraint:
                    // it was never enforceable pre-rewrite (`bare_outer`),
                    // and enforcing its substituted form would erase a
                    // legitimate inference. Mint only when a bound moved.
                    const fc = if (oc != types.no_type and c.ts.kind(oc) != .type_param) nc else types.no_type;
                    // A bare bound stays unenforced, but its substituted form
                    // rides along for the literal-widening rule — see
                    // `FreshTp.widen_bound`.
                    const wb = if (fc == types.no_type and oc != types.no_type and nc != oc) nc else types.no_type;
                    if (nc != oc or nd != od) {
                        fresh = try c.mintFreshTp(tp, cur_map.items, cur_id, fc, nd, od != types.no_type, wb);
                    }
                }
                if (fresh) |fid| {
                    try kept.append(c.scratch(), fid);
                    const rewrite: TpMap = .{ .sym = tp, .ty = try s.makeTypeParam(fid) };
                    try fresh_map.append(c.scratch(), rewrite);
                    try cur_map.append(c.scratch(), rewrite);
                    cur_id = if (c.inst_cache_on) try c.canonMapId(cur_map.items) else null;
                } else {
                    try kept.append(c.scratch(), tp);
                }
            }
            // Body substitution map: the incoming map plus the fresh-param
            // rewrites. Identical to `map` when no own param was affected,
            // so non-higher-order sigs keep their exact prior behavior.
            var sub_map = map;
            var sub_id = map_id;
            if (fresh_map.items.len > 0) {
                var em: std.ArrayList(TpMap) = .empty;
                defer em.deinit(c.scratch());
                try em.appendSlice(c.scratch(), map);
                try em.appendSlice(c.scratch(), fresh_map.items);
                sub_map = try c.scratch().dupe(TpMap, em.items);
                sub_id = if (c.inst_cache_on) try c.canonMapId(sub_map) else null;
            }
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try c.instantiateId(p.ty, sub_map, sub_id), .flags = p.flags });
            }
            const ret = try c.instantiateId(s.fnReturn(t), sub_map, sub_id);
            // Preserve the type predicate (`x is S`) through instantiation,
            // substituting its guarded type (`S` → arg). Dropping it (the
            // prior behavior) erased the guard on real-lib overloads like
            // `filter<S extends T>(p: (v: T) => v is S): S[]`, so a plain
            // boolean predicate spuriously matched the type-guard overload.
            // The `this` type is likewise preserved and instantiated.
            const pred: ?types.Predicate = if (s.fnHasPredicate(t)) blk_p: {
                const pr = s.fnPredicate(t);
                break :blk_p types.Predicate{
                    .param = pr.param,
                    .asserts = pr.asserts,
                    .ty = if (pr.ty != types.no_type) try c.instantiateId(pr.ty, sub_map, sub_id) else pr.ty,
                };
            } else null;
            const this_ty = s.fnThisType(t);
            const fnres = try s.makeFunctionThis(params.items, ret, kept.items, s.fnFlags(t), pred, if (this_ty != 0) try c.instantiateId(this_ty, sub_map, sub_id) else 0);
            // Propagate the origin tag through function instantiation (see
            // the `.object` arm) — an aliased function member such as RHF's
            // `UseFormClearErrors<T>` relates by identity across builds.
            if (c.origin.get(t)) |orig_ref| {
                if (fnres != t and c.ts.kind(fnres) == .function) try c.tagInstantiatedOrigin(fnres, orig_ref, map, map_id);
            }
            break :blk fnres;
        },
        .ref => blk: {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.instantiateId(a, map, map_id));
            break :blk try s.makeRef(s.refSymbol(t), args.items);
        },
        // A polymorphic `this` marker carries the home instance it was
        // declared against (`I<T…>`); substituting the interface's type
        // arguments must carry through it, so `this` inside `I<string>`
        // denotes `this@I<string>` and not the still-generic `this@I<T>`.
        // Without this, a `this`-returning member DECLARED on a derived
        // interface never relates to the base's own `this`-returning
        // member: the two markers reduce to `Derived<T_d>` and `Base<T_b>`,
        // two unrelated free type params, instead of the concrete pair the
        // caller is already relating (which the in-progress relation memo
        // answers).
        .this_type => try s.makeThisType(try c.instantiateId(s.thisTypeInstance(t), map, map_id)),
        .conditional => blk: {
            const check0 = s.condCheck(t);
            // Distribution: a naked type-param check distributes over a
            // union member-wise, re-binding that param per member so the
            // branches reflect each member (not the whole union).
            if (s.condDistributive(t) and s.kind(check0) == .type_param) {
                const new_check = try c.instantiateId(check0, map, map_id);
                if (s.kind(new_check) == .never) break :blk types.never_type;
                if (s.kind(new_check) == .union_type) {
                    const csym = s.typeParamSymbol(check0);
                    var parts: std.ArrayList(TypeId) = .empty;
                    defer parts.deinit(c.scratch());
                    for (try c.memberList(new_check)) |m| {
                        const m2 = try c.mapWith(map, csym, m);
                        try parts.append(c.scratch(), try c.instantiate(t, m2));
                    }
                    break :blk try s.makeUnion(c.scratch(), parts.items);
                }
            }
            // The same distribution, one instantiation later. A distributive
            // conditional written inside a mapped type is instantiated TWICE:
            // first with the alias argument (`SDV<O[K]>`, which leaves the
            // check the still-generic `O[K]` and defers), then per key. By the
            // second pass the check is an `.index_access`, not a bare type
            // parameter, so the rule above no longer fires — and the branches
            // below get instantiated with the WHOLE union substituted for the
            // check. A conditional nested in a branch then resolves against
            // the union instead of the constituent, and its answer is unioned
            // in beside the correct one.
            //
            // kysely's `ShallowDehydrateObject<O> = { [K in keyof O]:
            // ShallowDehydrateValue<O[K]> }` is that shape: for a
            // `string | null` column the outer arm correctly yields `null`,
            // while the nested `T extends (infer U)[] | null | undefined` arm
            // — reduced against `string | null`, which the `| null` half
            // matches with `U` unbound — contributed a spurious
            // `ShallowDehydrateValue<unknown>[]`, and every read of the column
            // was a TS2322.
            //
            // Rebinding is by the check EXPRESSION rather than by a symbol:
            // that is what the branches were instantiated against, and it is
            // the only handle left once the parameter is gone. The memo is
            // switched off (`map_id = null`) for the duration — the answer is
            // a function of the constituent too, which the `(map, type)` key
            // cannot express.
            if (s.condDistributive(t) and s.kind(check0) != .type_param) {
                const new_check = try c.instantiateId(check0, map, map_id);
                if (new_check != check0 and s.kind(new_check) == .union_type) {
                    const saved_subst = c.cond_check_subst;
                    defer c.cond_check_subst = saved_subst;
                    var parts: std.ArrayList(TypeId) = .empty;
                    defer parts.deinit(c.scratch());
                    for (try c.memberList(new_check)) |m| {
                        c.cond_check_subst = .{ .from = check0, .to = m };
                        const ext_m = try c.instantiateId(s.condExtends(t), map, null);
                        const tru_m = try c.instantiateId(s.condTrue(t), map, null);
                        const fls_m = try c.instantiateId(s.condFalse(t), map, null);
                        c.cond_check_subst = saved_subst;
                        try parts.append(c.scratch(), try c.reduceConditional(m, ext_m, tru_m, fls_m, false));
                    }
                    break :blk try s.makeUnion(c.scratch(), parts.items);
                }
            }
            const chk = try c.instantiateId(check0, map, map_id);
            const ext = try c.instantiateId(s.condExtends(t), map, map_id);
            const tru = try c.instantiateId(s.condTrue(t), map, map_id);
            const fls = try c.instantiateId(s.condFalse(t), map, map_id);
            break :blk try c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
        },
        .index_access => blk: {
            const obj = try c.instantiateId(s.indexAccessObj(t), map, map_id);
            const idx = try c.instantiateId(s.indexAccessIndex(t), map, map_id);
            break :blk try c.reduceIndexedAccess(obj, idx);
        },
        .mapped => blk: {
            const kp = s.mappedKeyParam(t); // key param identity is stable
            const con = try c.instantiateId(s.mappedConstraint(t), map, map_id);
            const val = try c.instantiateId(s.mappedValue(t), map, map_id);
            const as_c = if (s.mappedAs(t) != 0) try c.instantiateId(s.mappedAs(t), map, map_id) else 0;
            const src = if (s.mappedSource(t) != 0) try c.instantiateId(s.mappedSource(t), map, map_id) else 0;
            const red = try c.reduceMapped(kp, con, val, as_c, src, s.mappedFlags(t));
            // Same origin propagation as the `.object` arm: a mapped alias
            // instantiation reached through a generic interface's member
            // (`interface C<P> { propTypes?: WeakValidationMap<P> }`) is
            // re-instantiated at every use, and inference pairs the two
            // sides by alias identity (see `inferReverseMapped`).
            if (c.origin.get(t)) |orig_ref| {
                if (red != t and originTaggable(c.ts.kind(red))) try c.tagInstantiatedOrigin(red, orig_ref, map, map_id);
            }
            break :blk red;
        },
        .template_literal_type => blk: {
            var holes: std.ArrayList(TypeId) = .empty;
            defer holes.deinit(c.scratch());
            for (0..s.templateHoleCount(t)) |i| try holes.append(c.scratch(), try c.instantiateId(s.templateHole(t, @intCast(i)), map, map_id));
            break :blk try c.reduceTemplate(s.templateHead(t), holes.items, t);
        },
        .string_mapping => blk: {
            const arg = try c.instantiateId(s.stringMappingArg(t), map, map_id);
            break :blk try c.applyStringMapping(s.stringMappingKind(t), arg);
        },
        .keyof_op => blk: {
            const op = try c.instantiateId(s.keyofOperand(t), map, map_id);
            break :blk try c.keyofType(op);
        },
        else => t,
    };
    // Memoize only when nothing below tripped the limit (a truncated result
    // is depth-dependent, not a pure function of `(t, map)`).
    if (map_id) |mid| {
        if (!c.inst_limit_tripped) try c.inst_cache.put(c.cm(), (@as(u64, mid) << 32) | t, result);
    }
    return result;
}

/// Replace every polymorphic `this` marker in `t` with `repl` (the concrete
/// receiver at a property access). Gated by `has_this_types`, so it is a
/// no-op cost for programs that never declare a `this`-return.
/// `repl` sentinel for `substThis`: replace every marker with its OWN home
/// instance — the apparent type of a polymorphic `this` — rather than with
/// one common receiver. Used by the relation, where the two sides carry
/// markers declared against different instances.
pub const this_apparent: TypeId = 0;

pub fn substThis(c: *Checker, t: TypeId, repl: TypeId) Error!TypeId {
    if (!c.has_this_types) return t;
    if (!try c.containsThisType(t)) return t;
    if (c.inst_depth > max_instantiation_depth) return types.error_type;
    // Cycle cut. The deferred-operator arms below do not merely rewrite, they
    // *reduce*: `this["_zod"]` is looked up on the receiver, and the member it
    // finds mentions `this` again, so the reduction re-enters here with the
    // very same `(t, repl)` pair. zod's `$ZodType` closes such a circle in
    // four frames — `this["_zod"]["output"]` → `$ZodTypeInternals` →
    // `"~standard"` → `core.output<this>` → `this["_zod"]["output"]` — and
    // nothing about the pair changes on each lap, so no memo can see progress
    // and the walk only stopped when `max_instantiation_depth` truncated it to
    // `error_type`. That truncation is what made `.pipe(…).optional()` report
    // TS2589 and lose every property of the schema it typed.
    //
    // Leaving the operator symbolic on re-entry is the answer tsc arrives at
    // by never resolving it in the first place: it defers an indexed access
    // whose object is a type variable and only resolves it once a real
    // receiver exists, which is exactly the outermost frame here. That frame
    // still substitutes and still reduces; only the inner lap, which has no
    // new information, stops.
    const key = (@as(u64, t) << 32) | repl;
    for (c.this_subst_keys[0..c.this_subst_depth]) |k| {
        if (k == key) return t;
    }
    // Growth cut, the same rule the relation applies as `relIdDeeplyNested`:
    // a chain that keeps rewriting the SAME generic as a strictly larger
    // instantiation of itself is not converging on an answer. The pair test
    // above cannot see it, because nothing repeats — zod's `core.output<this>`
    // wraps another `$ZodType<any, …>` around its own argument every lap
    // (`$ZodType<any, $ZodType<any, $ZodType<any, …>>>`), so every frame is a
    // type this checker has never interned before. Leaving the subject
    // symbolic once the generic has been re-entered `max_this_subst_repeats`
    // times keeps the outer, informative rewrites and drops only the tail.
    const t_sym: SymbolId = if (c.ts.kind(t) == .ref) c.ts.refSymbol(t) else binder.no_symbol;
    if (t_sym != binder.no_symbol) {
        var seen: u32 = 0;
        for (c.this_subst_syms[0..c.this_subst_depth]) |sym| {
            if (sym == t_sym) seen += 1;
        }
        if (seen >= max_this_subst_repeats) return t;
    }
    c.this_subst_keys[c.this_subst_depth] = key;
    c.this_subst_syms[c.this_subst_depth] = t_sym;
    c.this_subst_depth += 1;
    defer c.this_subst_depth -= 1;
    c.inst_depth += 1;
    defer c.inst_depth -= 1;
    const s = &c.ts;
    switch (s.kind(t)) {
        .this_type => return if (repl == this_apparent) s.thisTypeInstance(t) else repl,
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
            return s.makeUnion(c.scratch(), parts.items);
        },
        .intersection => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
            return s.makeIntersection(c.scratch(), parts.items);
        },
        .overloads => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(t)) |m| try parts.append(c.scratch(), try c.substThis(m, repl));
            return s.makeOverloads(parts.items);
        },
        .array => return s.makeArrayLike(t, try c.substThis(s.arrayElem(t), repl)),
        .tuple => {
            var elems: std.ArrayList(types.TupleElem) = .empty;
            defer elems.deinit(c.scratch());
            for (0..s.tupleLen(t)) |i| {
                const e = s.tupleElem(t, @intCast(i));
                try elems.append(c.scratch(), .{ .ty = try c.substThis(e.ty, repl), .flags = e.flags });
            }
            return s.makeTuple(elems.items);
        },
        .function => {
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                try params.append(c.scratch(), .{ .name = p.name, .ty = try c.substThis(p.ty, repl), .flags = p.flags });
            }
            const ret = try c.substThis(s.fnReturn(t), repl);
            const this_ty = s.fnThisType(t);
            const pred: ?types.Predicate = if (s.fnHasPredicate(t)) s.fnPredicate(t) else null;
            return s.makeFunctionThis(params.items, ret, s.fnTypeParams(t), s.fnFlags(t), pred, this_ty);
        },
        .ref => {
            var args: std.ArrayList(TypeId) = .empty;
            defer args.deinit(c.scratch());
            for (try c.refArgsList(t)) |a| try args.append(c.scratch(), try c.substThis(a, repl));
            return s.makeRef(s.refSymbol(t), args.items);
        },
        // Anonymous object shape — see the `.object` arm of
        // `containsThisType` for the alias-expansion case that needs it.
        .object => {
            var props: std.ArrayList(types.Prop) = .empty;
            defer props.deinit(c.scratch());
            for (0..s.objectPropCount(t)) |i| {
                const p = s.objectProp(t, @intCast(i));
                try props.append(c.scratch(), .{ .name = p.name, .ty = try c.substThis(p.ty, repl), .flags = p.flags });
            }
            const sidx = if (s.objectStringIndex(t) != 0) try c.substThis(s.objectStringIndex(t), repl) else 0;
            const nidx = if (s.objectNumberIndex(t) != 0) try c.substThis(s.objectNumberIndex(t), repl) else 0;
            var call_sigs: std.ArrayList(TypeId) = .empty;
            defer call_sigs.deinit(c.scratch());
            var construct_sigs: std.ArrayList(TypeId) = .empty;
            defer construct_sigs.deinit(c.scratch());
            for (0..s.objectCallSigCount(t)) |i| {
                try call_sigs.append(c.scratch(), try c.substThis(s.objectCallSig(t, @intCast(i)), repl));
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                try construct_sigs.append(c.scratch(), try c.substThis(s.objectConstructSig(t, @intCast(i)), repl));
            }
            return s.makeObjectSigs(props.items, sidx, nidx, s.objectFlags(t), call_sigs.items, construct_sigs.items);
        },
        // The deferred type operators. A `this` operand keeps these symbolic
        // (see `isGenericObjectForIndex` / `reduceConditional`), so this is
        // where they finally resolve: substitute the receiver, then run the
        // same reducers `instantiateId` runs, which is what turns zod's
        // `this["_zod"]["output"]` into the schema's output type.
        .index_access => return c.reduceIndexedAccess(
            try c.substThis(s.indexAccessObj(t), repl),
            try c.substThis(s.indexAccessIndex(t), repl),
        ),
        .conditional => {
            const chk = try c.substThis(s.condCheck(t), repl);
            const ext = try c.substThis(s.condExtends(t), repl);
            const tru = try c.substThis(s.condTrue(t), repl);
            const fls = try c.substThis(s.condFalse(t), repl);
            return c.reduceConditional(chk, ext, tru, fls, s.condDistributive(t));
        },
        .keyof_op => return c.keyofType(try c.substThis(s.keyofOperand(t), repl)),
        .mapped => return c.reduceMapped(
            s.mappedKeyParam(t),
            try c.substThis(s.mappedConstraint(t), repl),
            try c.substThis(s.mappedValue(t), repl),
            if (s.mappedAs(t) != 0) try c.substThis(s.mappedAs(t), repl) else 0,
            if (s.mappedSource(t) != 0) try c.substThis(s.mappedSource(t), repl) else 0,
            s.mappedFlags(t),
        ),
        .template_literal_type => {
            var holes: std.ArrayList(TypeId) = .empty;
            defer holes.deinit(c.scratch());
            for (0..s.templateHoleCount(t)) |i| {
                try holes.append(c.scratch(), try c.substThis(s.templateHole(t, @intCast(i)), repl));
            }
            return c.reduceTemplate(s.templateHead(t), holes.items, t);
        },
        .string_mapping => return c.applyStringMapping(
            s.stringMappingKind(t),
            try c.substThis(s.stringMappingArg(t), repl),
        ),
        else => return t,
    }
}

/// Does `t` mention a polymorphic `this` anywhere `substThis` can reach?
/// The two must agree exactly: a shape this test misses is a shape
/// `substThis` is never asked to rewrite, so the marker survives into the
/// answer and resolves to nothing.
///
/// Memoized in the dense `ctt_cache` — types are immutable and the walk is
/// structural, so the answer is a pure function of the id, and every
/// property access pays for it once the program declares any `this` type.
pub fn containsThisType(c: *Checker, t: TypeId) Error!bool {
    const v = c.triGet(&c.ctt_cache, t);
    if (v != 0) return v == 2;
    const r = try containsThisTypeInner(c, t);
    try c.triSet(&c.ctt_cache, t, if (r) 2 else 1);
    return r;
}

fn containsThisTypeInner(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    switch (s.kind(t)) {
        .this_type => return true,
        .array => return c.containsThisType(s.arrayElem(t)),
        .union_type, .intersection, .overloads => {
            // Indexed: `containsThisType` interns nothing, but `members`
            // aliases store memory, so re-read per step for symmetry with
            // the rest of the file's walks.
            for (0..s.memberCount(t)) |i| {
                if (try c.containsThisType(s.memberAt(t, i))) return true;
            }
            return false;
        },
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try c.containsThisType(s.tupleElem(t, @intCast(i)).ty)) return true;
            }
            return false;
        },
        .function => {
            if (try c.containsThisType(s.fnReturn(t))) return true;
            for (0..s.fnParamCount(t)) |i| {
                if (try c.containsThisType(s.fnParam(t, @intCast(i)).ty)) return true;
            }
            return false;
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| {
                if (try c.containsThisType(s.refArgAt(t, i))) return true;
            }
            return false;
        },
        // An anonymous object shape carries `this` as readily as anything
        // else: zod's `safeParse(): ZodSafeParseResult<output<this>>` is an
        // alias that expands to a UNION OF OBJECT LITERALS whose `data`
        // property is the deferred `output<this>`. Without this arm the
        // union's members read as `this`-free and the marker never resolved
        // — every `safeParse().data` was `unknown`.
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (try c.containsThisType(s.objectProp(t, @intCast(i)).ty)) return true;
            }
            if (s.objectStringIndex(t) != 0 and try c.containsThisType(s.objectStringIndex(t))) return true;
            if (s.objectNumberIndex(t) != 0 and try c.containsThisType(s.objectNumberIndex(t))) return true;
            for (0..s.objectCallSigCount(t)) |i| {
                if (try c.containsThisType(s.objectCallSig(t, @intCast(i)))) return true;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (try c.containsThisType(s.objectConstructSig(t, @intCast(i)))) return true;
            }
            return false;
        },
        // Deferred operators — the forms a `this` operand keeps symbolic.
        // Without these arms `substThis` declared them `this`-free and left
        // them unsubstituted forever, so `this["k"]` never resolved.
        .index_access => return (try c.containsThisType(s.indexAccessObj(t))) or
            (try c.containsThisType(s.indexAccessIndex(t))),
        .conditional => return (try c.containsThisType(s.condCheck(t))) or
            (try c.containsThisType(s.condExtends(t))) or
            (try c.containsThisType(s.condTrue(t))) or
            (try c.containsThisType(s.condFalse(t))),
        .keyof_op => return c.containsThisType(s.keyofOperand(t)),
        .mapped => {
            if (try c.containsThisType(s.mappedConstraint(t))) return true;
            if (try c.containsThisType(s.mappedValue(t))) return true;
            if (s.mappedAs(t) != 0 and try c.containsThisType(s.mappedAs(t))) return true;
            if (s.mappedSource(t) != 0 and try c.containsThisType(s.mappedSource(t))) return true;
            return false;
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| {
                if (try c.containsThisType(s.templateHole(t, @intCast(i)))) return true;
            }
            return false;
        },
        .string_mapping => return c.containsThisType(s.stringMappingArg(t)),
        else => return false,
    }
}
