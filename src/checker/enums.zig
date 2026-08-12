//! Enums: member typing, literal types, initializers, and the memoized
//! type-parameter substitution engine. Functions take the `Checker` context
//! as their first parameter.
//!
//! The class-statics engine that used to share this file now lives in
//! `statics.zig` and is re-exported at the bottom, so every existing consumer
//! (and every `Checker` method alias built on these names) still resolves
//! through here.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_instantiation_depth = checker_zig.max_instantiation_depth;
const max_chain_repeats = checker_zig.max_chain_repeats;
const max_this_subst_repeats = checker_zig.max_this_subst_repeats;
const chain_scan_floor = checker_zig.chain_scan_floor;
const scratch_retain_limit = checker_zig.scratch_retain_limit;
const prof_zig = checker_zig.prof_zig;
const FreshTp = checker_zig.FreshTp;

const originTaggable = @import("instantiate.zig").originTaggable;

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

// =====================================================================
// the syntactic constant evaluator (tsc's `createEvaluator`)
// =====================================================================

/// tsc evaluates a template EXPRESSION as a compile-time constant before it
/// decides between `string` and a template-literal type
/// (`checkTemplateExpression`: `const evaluated = node.parent.kind !==
/// TaggedTemplateExpression && evaluate(node).value; if (evaluated !==
/// undefined) return getFreshTypeOfLiteralType(getStringLiteralType(evaluated))`).
/// So `` const D = `feedgen|${VIDEO_FEED_URI}` `` — where the substitution
/// names a `const` whose own initializer is a string constant — has the
/// single string literal type `"feedgen|at://…"`, NOT `string`, and is
/// therefore assignable to `` `feedgen|${string}` ``.
///
/// This mirrors `utilities.ts`'s `createEvaluator` over the *syntax*, not
/// over checked types: tsc only folds a name that resolves to an enum member
/// or to a `const` variable with **no type annotation** and an initializer
/// (`evaluateEntityNameExpression` -> `isConstantVariable(symbol) &&
/// declaration && !declaration.type && declaration.initializer`). Folding on
/// the checked type instead would also fold `declare const x: 'abc'`, which
/// tsc leaves as `string` — a false NEGATIVE. The operator arms tsc supports
/// on numbers (`|`, `&`, `<<`, `+`, …) are deliberately left out: omitting a
/// case only under-folds, which can never turn a tsc error into silence.
///
/// Appends the value's string form to `out`; returns false when the
/// expression is not a compile-time constant.
pub fn evalConstToString(c: *Checker, node: Node, out: *std.ArrayList(u8), depth: u8) Error!bool {
    if (depth > max_const_eval_depth or node == null_node) return false;
    const d = c.tree.nodeData(node);
    const main_tok = c.tree.nodeMainToken(node);
    switch (c.nodeTag(node)) {
        .string_literal => {
            try out.appendSlice(c.scratch(), c.atomText(try c.memberAtom(main_tok)));
            return true;
        },
        // A no-substitution template is a string constant (tsc folds
        // `NoSubstitutionTemplateLiteral` to its cooked text).
        .template_literal => {
            try out.appendSlice(c.scratch(), c.atomText(try c.templateAtom(main_tok)));
            return true;
        },
        .number_literal => {
            try appendNumber(c, out, c.numberTokenValue(main_tok));
            return true;
        },
        .paren_expr => return evalConstToString(c, d.lhs, out, depth + 1),
        .prefix_unary => {
            const op = c.tree.tokens.tag(main_tok);
            if ((op == .minus or op == .plus) and d.lhs != null_node and c.nodeTag(d.lhs) == .number_literal) {
                const v = c.numberTokenValue(c.tree.nodeMainToken(d.lhs));
                try appendNumber(c, out, if (op == .minus) -v else v);
                return true;
            }
            return false;
        },
        .template_expr => {
            try out.appendSlice(c.scratch(), c.templateHeadText(main_tok));
            for (c.tree.nodeRange(node)) |sub| {
                if (sub == null_node) return false;
                if (!try evalConstToString(c, sub, out, depth + 1)) return false;
                const ctok = c.templateChunkTokAfter(main_tok, c.nodeSpan(sub).end);
                try out.appendSlice(c.scratch(), c.templateChunkText(ctok));
            }
            return true;
        },
        .identifier, .member_expr => return evalConstEntityName(c, node, out, depth),
        else => return false,
    }
}

const max_const_eval_depth: u8 = 16;

fn appendNumber(c: *Checker, out: *std.ArrayList(u8), v: f64) Error!void {
    var buf: [64]u8 = undefined;
    const s = if (v == @floor(v) and @abs(v) < 1e15)
        std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch return
    else
        std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    try out.appendSlice(c.scratch(), s);
}

/// tsc's `evaluateEntityNameExpression`: an enum member folds to its constant
/// value, a `const` variable with no annotation folds to its initializer's
/// value, anything else is not a constant.
fn evalConstEntityName(c: *Checker, node: Node, out: *std.ArrayList(u8), depth: u8) Error!bool {
    // `E.M` / `NS.E.M` — the enum-member arm, shared with the enum walk.
    if (c.nodeTag(node) == .member_expr) {
        const d = c.tree.nodeData(node);
        const saved_scope = c.cur_scope;
        defer c.cur_scope = saved_scope;
        if (try c.enumSymOfQualifier(d.lhs)) |esym| {
            const v = (try c.enumMemberValue(esym, try c.memberAtom(d.rhs))) orelse return false;
            switch (c.ts.kind(v)) {
                .string_literal => try out.appendSlice(c.scratch(), c.atomText(c.ts.literalAtom(v))),
                .number_literal, .number_literal_fresh => try appendNumber(c, out, c.ts.numberValue(v)),
                else => return false,
            }
            return true;
        }
        return false;
    }
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    var sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return false,
    };
    // Follow import aliases to the declaration that carries the initializer
    // (tsc's `resolveEntityName` resolves through aliases before the test).
    var hops: u8 = 0;
    while (c.symFlags(sym).import_binding) : (hops += 1) {
        if (hops >= 8) return false;
        const tgt = c.importTarget(sym) orelse return false;
        if (tgt.kind != .binding) return false;
        sym = c.toGlobalIn(tgt.file, tgt.payload);
    }
    if (!c.symFlags(sym).const_decl) return false;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return false;
    const decl = decls[0];
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    // `declarator_init` is exactly `!declaration.type && declaration.initializer`
    // with a plain name — a `declarator_full` carries an annotation (or is a
    // pattern), which tsc refuses to fold.
    if (c.nodeTag(decl) != .declarator_init) return false;
    const dd = c.tree.nodeData(decl);
    if (c.nodeTag(dd.lhs) != .identifier) return false;
    return evalConstToString(c, dd.rhs, out, depth + 1);
}

/// The folded string value of a template expression, or null when it is not a
/// compile-time constant.
pub fn constTemplateAtom(c: *Checker, node: Node) Error!?Atom {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(c.scratch());
    if (!try evalConstToString(c, node, &out, 0)) return null;
    // `internText`, NOT `atom`: the folded value lives in a scratch buffer that
    // is freed on return, and `atom_cache` keeps its KEY as the caller's slice.
    // Caching it leaves a dangling key that the next rehash walks — a
    // segfault whose crash site is wherever the map happens to grow, which is
    // why this reproduced only on excalidraw at `--checkers=2`.
    return try c.internText(out.items);
}

/// The constant value of an enum member initializer that REFERENCES another
/// constant enum member — `Asc = AssetOrder.Asc`, or `B = A` naming a member
/// of the same enum. tsc's `computeConstantValue` evaluates an entity-name
/// expression against the enum member it resolves to, so such a member is a
/// string (or numeric) constant like any other; ztsc classified it as
/// `computed`, which cost the whole enum its `all_string` classification —
/// `Aliased.Asc` was then not assignable to `string`, and immich's
/// `z.enum(AssetOrderWithRandom)` (whose parameter is
/// `Readonly<Record<string, string | number>>`) had no matching overload.
///
/// `own` is the enum being walked, so a self-reference resolves against its
/// own members without going back through the scope chain.
pub fn aliasedEnumInitValue(c: *Checker, own: SymbolId, init_node: Node) Error!?TypeId {
    if (c.enum_alias_depth >= 8) return null;
    c.enum_alias_depth += 1;
    defer c.enum_alias_depth -= 1;
    switch (c.nodeTag(init_node)) {
        // `E.M` (or `NS.E.M`) — the qualifier names an enum, the member name
        // is read off it exactly as the type-position form does.
        .member_expr => {
            const d = c.tree.nodeData(init_node);
            // Both walks that call this run under `enterSymFile`, which
            // switches the FILE but leaves `cur_scope` pointing into the
            // requester's — an out-of-bounds scope id in the enum's own file.
            // The qualifier is a top-level name in that file, so resolve it
            // from the file scope.
            const saved_scope = c.cur_scope;
            c.cur_scope = binder.file_scope;
            defer c.cur_scope = saved_scope;
            const esym = (try c.enumSymOfQualifier(d.lhs)) orelse return null;
            const name = try c.memberAtom(d.rhs);
            if (esym == own) return null; // a member of THIS enum, mid-walk
            return c.enumMemberValue(esym, name);
        },
        // The bare-name form (`B = A`, a member of the same enum) is left
        // alone: ztsc's binder declares no scope for an enum body — member
        // names live in the value object the checker materializes — so such
        // a reference is already TS2304 and folding its value would not make
        // the declaration check.
        else => return null,
    }
}

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
        // A NO-SUBSTITUTION template literal is a string constant, the same
        // as a quoted one: tsc's `computeConstantValue` folds
        // `NoSubstitutionTemplateLiteral` to its cooked text. Treating it as
        // computed instead made the member opaque, which cost the whole enum
        // its `all_string` classification and turned every `case E.M:` on it
        // into TS2678 (immich writes nine `ManualJobName` members in
        // backticks).
        .string_literal, .template_literal => return .{ .kind = .string, .value = 0 },
        else => return .{ .kind = .computed, .value = 0 },
    }
}

/// The cooked text of a constant string enum initializer — quoted or in
/// backticks (see `classifyEnumInit`). The token spellings differ, so the
/// atom has to be read through the matching accessor.
pub fn enumInitAtom(c: *Checker, init_node: Node) Error!Atom {
    const tok = c.tree.nodeMainToken(init_node);
    if (c.nodeTag(init_node) == .template_literal) return c.templateAtom(tok);
    return c.memberAtom(tok);
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
                    // A reference to another constant enum member is a
                    // CONSTANT (see `aliasedEnumInitValue`): folding it is
                    // what keeps a string enum's `all_string` classification
                    // when one of its members aliases another enum's.
                    if (try c.aliasedEnumInitValue(sym, init_node)) |v| {
                        if (c.ts.kind(v) == .string_literal) {
                            has_string = true;
                            auto_ok = false;
                        } else {
                            const n = c.ts.numberValue(v);
                            try values.append(c.scratch(), n);
                            auto = n + 1;
                            auto_ok = true;
                        }
                        continue;
                    }
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
                    const av = try c.enumInitAtom(init_node);
                    auto_ok = false;
                    try f(ctx, name, try c.ts.makeStringLiteral(av, false));
                },
                .numeric => {
                    auto = ci.value + 1;
                    auto_ok = true;
                    try f(ctx, name, try c.ts.makeNumberLiteral(ci.value, false));
                },
                .computed => {
                    // A reference to another constant enum member folds to
                    // that member's value (see `aliasedEnumInitValue`).
                    if (try c.aliasedEnumInitValue(sym, init_node)) |v| {
                        if (c.ts.kind(v) == .number_literal or c.ts.kind(v) == .number_literal_fresh) {
                            auto = c.ts.numberValue(v) + 1;
                            auto_ok = true;
                        } else {
                            auto_ok = false;
                        }
                        try f(ctx, name, v);
                        continue;
                    }
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

/// `eachEnumMember`'s walk for one enum, memoized under its symbol — see
/// `Checker.enum_members`. Every by-name consumer goes through here, so an
/// enum's declaration is read once per checker instead of once per question.
///
/// The list is published only after the walk completes, so a re-entrant
/// request for the SAME enum (an `aliasedEnumInitValue` cycle) falls through
/// to a second walk exactly as it did before, and the depth cap in
/// `enum_alias_depth` still bounds it.
pub fn enumMembersOf(c: *Checker, sym: SymbolId) Error![]const checker_zig.EnumMemberEntry {
    if (c.enum_members.get(sym)) |m| return m;
    const Collect = struct {
        c: *Checker,
        list: std.ArrayList(checker_zig.EnumMemberEntry) = .empty,
        fn visit(self: *@This(), name: Atom, value: TypeId) Error!void {
            try self.list.append(self.c.ca(), .{ .name = name, .value = value });
        }
    };
    var col: Collect = .{ .c = c };
    try c.eachEnumMember(sym, &col, Collect.visit);
    const out = col.list.items;
    try c.enum_members.put(c.cm(), sym, out);
    return out;
}

/// Does enum `sym` declare a member called `name`?
pub fn enumHasMemberNamed(c: *Checker, sym: SymbolId, name: Atom) Error!bool {
    for (try enumMembersOf(c, sym)) |m| {
        if (m.name == name) return true;
    }
    return false;
}

/// The constant VALUE literal of enum member `sym.name` (`"a"` / `0`), or
/// null when the member is absent or its value is computed. tsc makes a
/// member type a subtype of exactly this literal — that is what lets
/// `const k: "keydown" = EVENT.KEYDOWN` type-check while
/// `const k: "paste" = EVENT.KEYDOWN` does not.
pub fn enumMemberValue(c: *Checker, sym: SymbolId, name: Atom) Error!?TypeId {
    // First declaration wins, matching `EnumMemberLookup`'s `if (self.found)`
    // guard for an enum that declares the same name twice.
    for (try enumMembersOf(c, sym)) |m| {
        if (m.name != name) continue;
        if (m.value == types.no_type) return null;
        return m.value;
    }
    return null;
}

/// The member type of enum `sym` whose constant VALUE is the literal
/// `value` — `'a'` -> `E.A` for `enum E { A = 'a' }`. tsc needs no such
/// lookup: a whole enum IS the union of its member types there, so
/// `filterType(E, t => areTypesComparable(t, "a"))` matches `E.A` directly.
/// ztsc keeps the enum as ONE type, so a guard written against the raw value
/// has to be translated into the member type before the value narrowers can
/// keep or subtract it (see `narrowByLiteralEquality`).
pub const EnumMemberByValue = struct {
    c: *Checker,
    sym: SymbolId,
    want: TypeId,
    found: TypeId = types.no_type,
    pub fn visit(self: *EnumMemberByValue, name: Atom, value: TypeId) Error!void {
        if (self.found != types.no_type or value == types.no_type) return;
        if ((try self.c.ts.regularLiteral(value)) != self.want) return;
        self.found = try self.c.ts.makeEnumMember(self.sym, name, false);
    }
};

pub fn enumMemberForValue(c: *Checker, sym: SymbolId, value: TypeId) Error!?TypeId {
    var look: EnumMemberByValue = .{ .c = c, .sym = sym, .want = try c.ts.regularLiteral(value) };
    try c.eachEnumMember(sym, &look, EnumMemberByValue.visit);
    return if (look.found == types.no_type) null else look.found;
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
/// Collects `(name, value)` for every member of an enum, for the structural
/// enum comparison below.
const EnumPair = struct { name: Atom, value: TypeId };

const EnumMemberPairs = struct {
    c: *Checker,
    list: *std.ArrayList(EnumPair),
    pub fn visit(self: *EnumMemberPairs, name: Atom, value: TypeId) Error!void {
        for (self.list.items) |e| {
            if (e.name == name) return; // a re-declared member is one member
        }
        try self.list.append(self.c.scratch(), .{ .name = name, .value = value });
    }
};

/// tsc's `isEnumTypeRelatedTo`: two DIFFERENT enum declarations relate when
/// they share a name and every member of the source has a same-named member
/// of the same value in the target.
///
/// This is the one structural rule in an otherwise nominal type, and real
/// programs depend on it: a package that publishes an enum and an application
/// that redeclares it (immich's `src/dtos/env.dto.ts` re-writes
/// `@immich/sql-tools`' `DatabaseSslMode` with a `// TODO import from
/// sql-tools` note above it) must interoperate, and zod's
/// `$InferEnumOutput<T> = T[keyof T]` hands the redeclared members straight
/// into a parameter typed by the published one.
///
/// A `const enum` is excluded, matching tsc's `SymbolFlags.RegularEnum` test,
/// and so is an enum with a computed member, whose value is not comparable.
/// Cached per ordered pair, as tsc caches `enumRelation`.
pub fn enumsStructurallyRelated(c: *Checker, src: SymbolId, tgt: SymbolId) Error!bool {
    if (src == tgt) return true;
    const key = (@as(u64, src) << 32) | tgt;
    if (c.enum_relation_cache.get(key)) |v| return v;
    const answer = try enumsStructurallyRelatedUncached(c, src, tgt);
    try c.enum_relation_cache.put(c.cm(), key, answer);
    return answer;
}

fn enumsStructurallyRelatedUncached(c: *Checker, src: SymbolId, tgt: SymbolId) Error!bool {
    if (c.symNameAtom(src) != c.symNameAtom(tgt)) return false;
    const si = try c.enumInfo(src);
    const ti = try c.enumInfo(tgt);
    if (si.is_const or ti.is_const or si.has_computed or ti.has_computed) return false;

    var sm: std.ArrayList(EnumPair) = .empty;
    defer sm.deinit(c.scratch());
    var tm: std.ArrayList(EnumPair) = .empty;
    defer tm.deinit(c.scratch());
    var sv: EnumMemberPairs = .{ .c = c, .list = &sm };
    var tv: EnumMemberPairs = .{ .c = c, .list = &tm };
    try c.eachEnumMember(src, &sv, EnumMemberPairs.visit);
    try c.eachEnumMember(tgt, &tv, EnumMemberPairs.visit);
    if (sm.items.len == 0) return false;

    // Every SOURCE member must be present in the target with the same value;
    // the target may declare more (tsc scans the source's members only).
    for (sm.items) |a| {
        if (a.value == types.no_type) return false;
        var found = false;
        for (tm.items) |b| {
            if (b.name != a.name) continue;
            if (b.value == types.no_type) return false;
            if ((try c.ts.regularLiteral(a.value)) != (try c.ts.regularLiteral(b.value))) return false;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

/// The two enum types `s` and `t` under `enumsStructurallyRelated` — the
/// cross-declaration half of `enumAssignable`'s first arm. A whole enum is
/// tsc's union of its members, so a MEMBER reaches the other declaration's
/// whole enum and two members must name the same value; the whole enum does
/// not reach one member.
fn crossEnumAssignable(c: *Checker, s: TypeId, t: TypeId) Error!bool {
    if (!try enumsStructurallyRelated(c, c.ts.enumSymbol(s), c.ts.enumSymbol(t))) return false;
    if (!c.ts.isEnumMember(t)) return true;
    if (!c.ts.isEnumMember(s)) return false;
    const sv = (try c.enumMemberValue(c.ts.enumSymbol(s), c.ts.enumMemberAtom(s))) orelse return false;
    const tv = (try c.enumMemberValue(c.ts.enumSymbol(t), c.ts.enumMemberAtom(t))) orelse return false;
    return (try c.ts.regularLiteral(sv)) == (try c.ts.regularLiteral(tv));
}

pub fn enumAssignable(c: *Checker, s: TypeId, t: TypeId, sk: types.Kind, tk: types.Kind) Error!bool {
    if (sk == .enum_type and tk == .enum_type) {
        if (c.ts.enumSymbol(s) != c.ts.enumSymbol(t)) return crossEnumAssignable(c, s, t);
        // A WHOLE enum against one of its own members. tsc's declared type
        // of an enum is the union of its member types, so an enum with a
        // single member and that member are the same type there and relate
        // in both directions; ztsc keeps the two spellings distinct, so the
        // identity has to be stated. immich's `WorkflowType` (one member,
        // the rest commented out) is exactly this shape, and every DTO that
        // annotates `WorkflowType[]` while the value is `WorkflowType.AssetV1[]`
        // reported TS2322.
        if (!c.ts.isEnumMember(s) and c.ts.isEnumMember(t) and
            c.ts.enumSymbol(s) == c.ts.enumSymbol(t))
        {
            if (try c.enumMemberTypeUnion(c.ts.enumSymbol(s), 0)) |mu| {
                return mu == try c.ts.regularLiteral(t);
            }
        }
        return false;
    }
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
            if (init_node == null_node) continue;
            if (c.classifyEnumInit(init_node).kind != .string) continue;
            if ((try c.enumInitAtom(init_node)) == val) return true;
        }
    }
    return false;
}

/// Is every initialized member of enum `sym` string-valued? A STRING enum is
/// the nominal shape the assertion check has a special rule for (see
/// `stringEnumCastOverlap`); a numeric or mixed enum keeps the ordinary
/// numeric-literal comparability and must not take it.
pub fn enumIsStringValued(c: *Checker, sym: SymbolId) Error!bool {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var any = false;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const d = c.tree.nodeData(decl);
        const data = c.tree.extraData(ast.EnumData, d.lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const init_node = c.tree.nodeData(m).lhs;
            // An uninitialized member is auto-numbered: the enum is not
            // string-valued.
            if (init_node == null_node) return false;
            if (c.classifyEnumInit(init_node).kind != .string) return false;
            any = true;
        }
    }
    return any;
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
pub const TpMap = struct { sym: SymbolId, ty: TypeId };
pub const InferKey = struct { cond: u64, name: Atom };

/// A TS 4.8 `infer V extends C` binder: the written constraint plus the
/// binder's name, which is needed to rebuild the `infer_var` reference the
/// desugar puts in the check position. See `Checker.infer_constraints`.
pub const InferConstraint = struct { ty: TypeId, name: Atom };

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
            // And so can the `this` type: `static springify<T extends typeof
            // C>(this: T, ms?: number): C` names `T` nowhere else.
            // `instantiateId`'s `.function` arm substitutes the `this` type,
            // so this predicate — the early-out that decides whether that arm
            // runs at all — has to see it, or the signature is judged
            // concrete and `this` stays the bare type parameter. The receiver
            // check then compares `typeof ZoomIn` against an uninstantiated
            // `T` (TS2684) even though inference had a candidate for it.
            if (s.fnThisType(t) != 0 and try c.containsTypeParam(s.fnThisType(t))) return true;
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

/// Would substituting `map` through `t` change it? Answers **without
/// performing the substitution**, and is used at exactly one site: the mint
/// test of `instantiateId`'s `.function` arm, which otherwise has to compute
/// a signature's own type-parameter bounds eagerly just to find out whether
/// they moved (32% of immich's whole instantiation demand, 88% of it never
/// read again — see `prof.zig`'s "EAGER TYPE-PARAMETER BOUNDS").
///
/// The answer is EXACT in the direction that matters. `false` is returned
/// only when no symbol `map` rebinds occurs anywhere `instantiateId` could
/// look, so a `false` guarantees `instantiateId(t, map) == t` and the caller
/// may use `t` itself as the substituted bound. A `true` merely means "may
/// move": a type that mentions a rebound symbol can still substitute back to
/// itself if a reduction cancels it out, and the caller therefore treats a
/// `true` as speculative (see `FreshTp.pending_default_moved`).
pub fn boundMayMove(c: *Checker, t: TypeId, map: []const TpMap) Error!bool {
    if (map.len == 0) return false;
    if (!try c.containsTypeParam(t)) return false;
    const m = try c.tpMentions(t);
    if (m.saturated) return true;
    for (m.syms) |sym| {
        const rep = tpLookup(map, sym) orelse continue;
        // An identity binding (`T := T`, which a re-instantiation of an
        // already-substituted signature produces routinely) rebinds nothing.
        if (c.ts.kind(rep) == .type_param and c.ts.typeParamSymbol(rep) == sym) continue;
        return true;
    }
    return false;
}

/// The set of type-param symbols `t` mentions, memoized per `TypeId`. Mirrors
/// `containsTypeParamInner` arm for arm — that predicate is the gate
/// `instantiate` early-outs on, so anything it does not reach cannot be
/// substituted either — and additionally saturates (see `Mentions`) at a
/// signature that binds its own type parameters, rather than reasoning about
/// which of them shadow an outer one.
///
/// Called only on DECLARED type-parameter constraints, of which a program has
/// few and each is a small unreduced node (`Readonly<FilterObject<DB, TB>>`
/// is a ref holding a ref holding two type params), so the walk is paid once
/// per distinct bound and never on a materialized member table.
pub fn tpMentions(c: *Checker, t: TypeId) Error!checker_zig.Mentions {
    if (c.tp_mentions.get(t)) |m| return m;
    var syms: std.ArrayList(u32) = .empty;
    defer syms.deinit(c.scratch());
    // Pre-seed against a cycle through `t` (a constraint that reaches itself
    // through a recursive alias reference): a re-entry sees the saturated
    // record and the outer walk overwrites it with the real answer.
    try c.tp_mentions.put(c.cm(), t, .{ .syms = &.{}, .saturated = true });
    const saturated = try tpMentionsInto(c, t, &syms, false);
    const owned: []const u32 = if (saturated or syms.items.len == 0)
        &.{}
    else
        try c.cm().dupe(u32, syms.items);
    const m: checker_zig.Mentions = .{ .syms = owned, .saturated = saturated };
    try c.tp_mentions.put(c.cm(), t, m);
    return m;
}

fn tpMentionsInto(c: *Checker, t: TypeId, out: *std.ArrayList(u32), use_cache: bool) Error!bool {
    const s = &c.ts;
    if (!try c.containsTypeParam(t)) return false;
    // A sub-node already walked contributes its cached set wholesale. The
    // ROOT skips this: `tpMentions` has just seeded it with the saturated
    // cycle guard that this lookup would otherwise read back as the answer.
    if (use_cache) if (c.tp_mentions.get(t)) |m| {
        if (m.saturated) return true;
        for (m.syms) |sym| try addSym(c, out, sym);
        return false;
    };
    switch (s.kind(t)) {
        .type_param => {
            try addSym(c, out, s.typeParamSymbol(t));
            return false;
        },
        .union_type, .intersection, .overloads => {
            for (0..s.memberCount(t)) |i| {
                if (try tpMentionsInto(c, s.memberAt(t, i), out, true)) return true;
            }
            return false;
        },
        .array => return tpMentionsInto(c, s.arrayElem(t), out, true),
        .tuple => {
            for (0..s.tupleLen(t)) |i| {
                if (try tpMentionsInto(c, s.tupleElem(t, @intCast(i)).ty, out, true)) return true;
            }
            return false;
        },
        .object => {
            for (0..s.objectPropCount(t)) |i| {
                if (try tpMentionsInto(c, s.objectProp(t, @intCast(i)).ty, out, true)) return true;
            }
            if (s.objectStringIndex(t) != 0 and try tpMentionsInto(c, s.objectStringIndex(t), out, true)) return true;
            if (s.objectNumberIndex(t) != 0 and try tpMentionsInto(c, s.objectNumberIndex(t), out, true)) return true;
            for (0..s.objectCallSigCount(t)) |i| {
                if (try tpMentionsInto(c, s.objectCallSig(t, @intCast(i)), out, true)) return true;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                if (try tpMentionsInto(c, s.objectConstructSig(t, @intCast(i)), out, true)) return true;
            }
            return false;
        },
        .function => {
            // Own parameters shadow, and their bounds are themselves
            // substituted by the `.function` arm — the very thing this walk
            // is asked about. Give up rather than model it.
            if (s.fnTypeParamCount(t) != 0) return true;
            if (try tpMentionsInto(c, s.fnReturn(t), out, true)) return true;
            for (0..s.fnParamCount(t)) |i| {
                if (try tpMentionsInto(c, s.fnParam(t, @intCast(i)).ty, out, true)) return true;
            }
            if (s.fnThisType(t) != types.no_type and
                try tpMentionsInto(c, s.fnThisType(t), out, true)) return true;
            if (s.fnHasPredicate(t)) {
                const pr = s.fnPredicate(t);
                if (pr.ty != types.no_type and try tpMentionsInto(c, pr.ty, out, true)) return true;
            }
            return false;
        },
        .ref => {
            for (0..s.refArgCount(t)) |i| {
                if (try tpMentionsInto(c, s.refArgAt(t, i), out, true)) return true;
            }
            return false;
        },
        .this_type => return tpMentionsInto(c, s.thisTypeInstance(t), out, true),
        .conditional => {
            if (try tpMentionsInto(c, s.condCheck(t), out, true)) return true;
            if (try tpMentionsInto(c, s.condExtends(t), out, true)) return true;
            if (try tpMentionsInto(c, s.condTrue(t), out, true)) return true;
            if (try tpMentionsInto(c, s.condFalse(t), out, true)) return true;
            return false;
        },
        .index_access => {
            if (try tpMentionsInto(c, s.indexAccessObj(t), out, true)) return true;
            if (try tpMentionsInto(c, s.indexAccessIndex(t), out, true)) return true;
            return false;
        },
        .mapped => {
            if (try tpMentionsInto(c, s.mappedConstraint(t), out, true)) return true;
            if (try tpMentionsInto(c, s.mappedValue(t), out, true)) return true;
            if (s.mappedAs(t) != 0 and try tpMentionsInto(c, s.mappedAs(t), out, true)) return true;
            if (s.mappedSource(t) != 0 and try tpMentionsInto(c, s.mappedSource(t), out, true)) return true;
            return false;
        },
        .template_literal_type => {
            for (0..s.templateHoleCount(t)) |i| {
                if (try tpMentionsInto(c, s.templateHole(t, @intCast(i)), out, true)) return true;
            }
            return false;
        },
        .string_mapping => return tpMentionsInto(c, s.stringMappingArg(t), out, true),
        .keyof_op => return tpMentionsInto(c, s.keyofOperand(t), out, true),
        // `containsTypeParam` said yes and this arm cannot say where from.
        else => return true,
    }
}

fn addSym(c: *Checker, out: *std.ArrayList(u32), sym: u32) Error!void {
    if (std.mem.indexOfScalar(u32, out.items, sym) != null) return;
    try out.append(c.scratch(), sym);
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
            // Same slot `containsTypeParamInner` reads: a signature can name a
            // type param in its `this` type and nowhere else.
            if (s.fnThisType(t) != 0 and try c.containsFreeTypeParam(s.fnThisType(t), inner)) return true;
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
    // `TpMap` is two `u32` fields and nothing else, so on a little-endian
    // target its own bytes ARE the packed `(sym, arg)` key this used to build
    // a second buffer for. Both the dupe and the pack loop were copies of a
    // copy; `sliceAsBytes` reads the caller's slice in place. (The stored key
    // is still duped into `carena` on a miss, so nothing borrows scratch.)
    comptime std.debug.assert(@sizeOf(TpMap) == 8 and @import("builtin").cpu.arch.endian() == .little);
    // Most maps arrive already ordered — they are built by appending a
    // declaration's type parameters in order, and the common arities are one
    // and two — so the sort's inputs are usually its own output. Checking
    // costs a linear scan the pack loop was paying anyway and, when it holds,
    // removes the scratch dupe as well as the sort.
    var view: []const TpMap = map;
    var ordered = true;
    for (1..map.len) |i| {
        if (map[i - 1].sym > map[i].sym) {
            ordered = false;
            break;
        }
    }
    if (!ordered) {
        const sorted = try c.scratch().dupe(TpMap, map);
        // Stable, as before: a map may bind one symbol twice (an inner
        // rebinding shadowing an outer one) and the canonical key has to keep
        // the two in their arrival order or one map gets two ids.
        std.mem.sort(TpMap, sorted, {}, struct {
            fn lt(_: void, a: TpMap, b: TpMap) bool {
                return a.sym < b.sym;
            }
        }.lt);
        view = sorted;
    }
    const bytes = std.mem.sliceAsBytes(view);
    const gop = try c.inst_map_ids.getOrPut(c.cm(), bytes);
    if (!gop.found_existing) {
        const owned = try c.ca().dupe(u8, bytes); // scratch dies with the expression
        gop.key_ptr.* = owned;
        gop.value_ptr.* = c.inst_map_next;
        c.inst_map_next += 1;
        c.stats.inst_maps += 1;
        // Ids are dense from 1, so `id - 1` indexes this list; it aliases the
        // key table's bytes (no second copy) and exists only so `mapForId`
        // can run the interning backwards.
        std.debug.assert(c.inst_map_bytes.items.len + 1 == gop.value_ptr.*);
        try c.inst_map_bytes.append(c.cm(), owned);
    }
    return gop.value_ptr.*;
}

/// The inverse of `canonMapId`: decode a canonical map id back into a
/// (scratch-allocated, sorted by symbol) `[]TpMap`. The result is a *set*,
/// not the original slice — which is exactly what a substitution needs, and
/// is why deferring one is sound even though the slice it was built from
/// died with its statement.
pub fn mapForId(c: *Checker, mid: u32) Error![]const TpMap {
    const bytes = c.inst_map_bytes.items[mid - 1];
    const n = bytes.len / 8;
    const out = try c.scratch().alloc(TpMap, n);
    for (out, 0..) |*m, i| {
        m.sym = std.mem.readInt(u32, bytes[i * 8 ..][0..4], .little);
        m.ty = std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], .little);
    }
    return out;
}

/// True for a fresh higher-order type-param symbol (`fresh_tp_ids`).
pub inline fn isFreshTp(c: *const Checker, sym: SymbolId) bool {
    return c.fresh_tp_base != 0 and sym >= c.fresh_tp_base;
}

/// Bounds record for a fresh higher-order type-param symbol.
pub fn freshTp(c: *const Checker, sym: SymbolId) *const FreshTp {
    return &c.fresh_tp_info.items[sym - c.fresh_tp_base];
}

/// The declaration symbol a (possibly FRESH) type-parameter symbol stands
/// for — itself for an ordinary one. See `FreshTp.orig`.
pub inline fn tpOrigin(c: *const Checker, sym: SymbolId) SymbolId {
    if (c.isFreshTp(sym)) return c.freshTp(sym).orig;
    return sym;
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
            .orig = c.tpOrigin(orig),
            .widen_bound = widen_bound,
        });
    }
    return gop.value_ptr.*;
}

/// `mintFreshTp` with the CONSTRAINT left unevaluated: `oc` is the
/// unsubstituted bound and `mid` the map to substitute it under, recorded on
/// the record and forced by `resolveFreshBound` the first time anybody asks
/// for the parameter's constraint. Everything else — the name, the `const`
/// modifier, the origin, and the already-substituted default — is identical
/// to the eager mint, and the record's identity still keys on `(orig, mid)`
/// alone, so deferral does not change which fresh symbol a given
/// (parameter, map) pair gets.
pub fn mintFreshTpDeferred(
    c: *Checker,
    orig: SymbolId,
    mid: u32,
    oc: TypeId,
    default: TypeId,
    has_default: bool,
    enforce: bool,
    default_moved: bool,
) Error!u32 {
    const key = (@as(u64, orig) << 32) | mid;
    const gop = try c.fresh_tp_ids.getOrPut(c.cm(), key);
    if (!gop.found_existing) {
        gop.value_ptr.* = c.fresh_tp_next;
        c.fresh_tp_next += 1;
        try c.fresh_tp_info.append(c.cm(), .{
            .name = c.symNameAtom(orig),
            .constraint = types.no_type,
            .default = default,
            .has_default = has_default,
            .const_tp = c.isConstTypeParamSym(orig),
            .orig = c.tpOrigin(orig),
            .widen_bound = types.no_type,
            .pending_bound = oc,
            .pending_map = mid,
            .pending_enforce = enforce,
            .pending_default_moved = default_moved,
        });
        c.stats.bound_deferred += 1;
    }
    return gop.value_ptr.*;
}

/// Force a deferred bound (`FreshTp.pending_bound`) — run the substitution
/// the mint site skipped and install `constraint` / `widen_bound`. Idempotent
/// and cheap after the first call. This is the ONLY place a deferred bound is
/// paid for, and on immich it runs for 12% of the parameters that carry one.
pub fn resolveFreshBound(c: *Checker, sym: SymbolId) Error!void {
    const idx = sym - c.fresh_tp_base;
    const oc = c.fresh_tp_info.items[idx].pending_bound;
    if (oc == types.no_type) return;
    const mid = c.fresh_tp_info.items[idx].pending_map;
    const enforce = c.fresh_tp_info.items[idx].pending_enforce;
    const default_moved = c.fresh_tp_info.items[idx].pending_default_moved;
    // Cleared FIRST: substituting the bound can re-enter this parameter (a
    // bound that reaches its own signature through a recursive alias), and a
    // re-entry must see a finished — if unconstrained — record rather than
    // recurse forever. The eager code had the same hole and filled it the
    // same way, with `no_type`.
    c.fresh_tp_info.items[idx].pending_bound = types.no_type;
    c.stats.bound_forced += 1;
    const map = try c.mapForId(mid);
    const nc = try c.instantiate(oc, map);
    // `instantiate` interns, which can append to `fresh_tp_info`; re-index.
    const rec = &c.fresh_tp_info.items[idx];
    if (nc == oc) c.stats.bound_speculative += @intFromBool(!default_moved);
    if (nc == oc and !default_moved) {
        // The mint was speculative — `boundMayMove` said "may" and the
        // substitution turned out to be a no-op, so the eager code would not
        // have minted at all and the signature would have kept the original
        // parameter, whose constraint is `oc`, ENFORCED. Reproduce that:
        // dropping to `no_type` here (which is what an ineligible bound gets)
        // would delete a constraint the program declared.
        rec.constraint = oc;
        rec.widen_bound = types.no_type;
        return;
    }
    rec.constraint = if (enforce) nc else types.no_type;
    rec.widen_bound = if (!enforce and nc != oc) nc else types.no_type;
}

/// The pre-deferral mint path, unchanged, for the two cases a deferral does
/// not cover: the memo is off (`--no-inst-cache`, so there is no canonical
/// map id to defer under and the whole run is an oracle anyway), or
/// `boundMayMove` proved the bound cannot move — in which case `nc == oc` is
/// established WITHOUT substituting, and the only reason to mint is a moved
/// default. Returns the fresh symbol, or null to keep the original parameter.
fn eagerBound(
    c: *Checker,
    tp: SymbolId,
    oc: TypeId,
    od: TypeId,
    nd: TypeId,
    cur_map: []const TpMap,
    cur_id: ?u32,
    eligible: bool,
    may_move: bool,
    bound_before: u64,
) Error!?u32 {
    const nc = if (may_move) try c.instantiateId(oc, cur_map, cur_id) else oc;
    const bound_cost = if (c.prof.on) c.inst_total - bound_before else 0;
    if (c.prof.on) c.stats.inst_bound_visits += bound_cost;
    // Fresh param carries the substituted *default* (so a no-arg
    // `<AD = DispatchType>()` resolves to the supplied dispatch). Its
    // *constraint* is enforced only when it was a structured, reducible bound
    // (idb `StoreName extends StoreNames<DBTypes>` → a concrete store-name
    // union that makes `"requests"` assignable). A *bare* bound
    // (`filter<S extends T>`) carries no constraint: it was never enforceable
    // pre-rewrite (`bare_outer`), and enforcing its substituted form would
    // erase a legitimate inference. Mint only when a bound moved.
    const fc = if (eligible and oc != types.no_type and c.ts.kind(oc) != .type_param) nc else types.no_type;
    // A bare bound stays unenforced, but its substituted form rides along for
    // the literal-widening rule — see `FreshTp.widen_bound`.
    const wb = if (fc == types.no_type and oc != types.no_type and nc != oc) nc else types.no_type;
    if (c.prof.on) {
        if (fc != types.no_type) {
            c.stats.inst_bound_enforced += bound_cost;
        } else if (wb != types.no_type) {
            c.stats.inst_bound_widen += bound_cost;
        } else if (nc == oc and nd == od) {
            c.stats.inst_bound_discarded += bound_cost;
        }
    }
    if (nc == oc and nd == od) return null;
    const fresh = try c.mintFreshTp(tp, cur_map, cur_id, fc, nd, od != types.no_type, wb);
    if (c.prof.on and fc != types.no_type) prof_zig.noteFreshBound(c, fresh, bound_cost);
    return fresh;
}

/// Mint (or reuse) a fresh symbol for own type-param `orig` when a signature
/// is `this`-substituted against receiver `repl` (`substThis`). Same record
/// pool as `mintFreshTp`, but a SEPARATE key table: that one keys on a
/// canonical map id and this one on a `TypeId`, both `u32`, so sharing one
/// table would alias unrelated pairs onto the same fresh symbol.
pub fn mintThisTp(c: *Checker, orig: SymbolId, repl: TypeId, constraint: TypeId, default: TypeId, has_default: bool) Error!u32 {
    const key = (@as(u64, orig) << 32) | repl;
    const gop = try c.this_tp_ids.getOrPut(c.cm(), key);
    if (!gop.found_existing) {
        gop.value_ptr.* = c.fresh_tp_next;
        c.fresh_tp_next += 1;
        try c.fresh_tp_info.append(c.cm(), .{
            .name = c.symNameAtom(orig),
            .constraint = constraint,
            .default = default,
            .has_default = has_default,
            .const_tp = c.isConstTypeParamSym(orig),
            .orig = c.tpOrigin(orig),
            .widen_bound = types.no_type,
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
        if (c.prof.on) {
            const before = c.inst_total;
            const focused = prof_zig.focusEnter(c, t);
            const r = c.instantiateId(t, map, map_id);
            if (focused) prof_zig.focusExit(c);
            prof_zig.noteTopLevel(c, @returnAddress(), t, c.inst_total - before);
            return r;
        }
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
/// the order the checker reaches types in — an implementation detail either
/// way, and one that was not even run-to-run stable when this was written:
/// atom ids came from the interner's per-shard insertion order, which the
/// parallel front end varied between runs, and atoms are sort keys for a
/// scope's member table (`binder.Binder.seal`) and for a merged namespace's
/// member index (`modules.Merger.buildNsMembers`). Restoring
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
        if (c.inst_cache.get(mid, t)) |r| {
            c.stats.inst_hits += 1;
            if (c.prof.on) c.prof.kind_hits[@intFromEnum(c.ts.kind(t))] += 1;
            return r;
        }
    }
    c.stats.inst_misses += 1;
    if (c.prof.on) {
        c.prof.kinds[@intFromEnum(c.ts.kind(t))] += 1;
        prof_zig.noteVisit(c, t);
    }
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
    if (c.inst_depth > max_instantiation_depth or c.inst_count > c.inst_budget) {
        c.inst_limit_tripped = true;
        c.inst_ceiling_trips += 1;
        if (c.prof.on) {
            c.prof.tripped += 1;
            prof_zig.noteTrip(c);
        }
        if (c.instDiagAllowed()) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return types.error_type;
    }
    c.inst_chain[c.inst_depth] = t;
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    // Release this frame's scratch on the way out. Everything the arms below
    // allocate — the exact-size worklists, the `memberList` dupes, the
    // reduction helpers' temporaries — is dead once the frame's answer has
    // been interned into the type store, but an arena that can only rewind to
    // empty had to hold all of it until the whole top-level substitution
    // finished. One kysely builder chain peaked that region above a gigabyte,
    // nearly all of it already dead. `BumpArena` marks are strictly nested
    // with the recursion, so restoring here frees this subtree's bytes and
    // nothing an enclosing frame still holds (its buffers were bumped before
    // this mark was taken). Only while the dedicated instantiation arena is
    // swapped in: the shared scratch arena is reset per statement by callers
    // who do hold buffers across an `instantiate`.
    const bump_owned = c.scratch_arena == c.inst_arena;
    const bump_mark = c.inst_arena.mark();
    defer if (bump_owned) c.inst_arena.restore(bump_mark);
    // Truncation is a property of THIS subtree, so the flag the memoization
    // test below reads has to be scoped to it. It used to be scoped to the
    // whole top-level `instantiate` call and never cleared, which made it
    // "somebody, somewhere earlier in this call, truncated" — so one
    // `chainRepeats` cut near the start of a big expansion suppressed
    // memoization of every unrelated sibling reached after it. Which
    // siblings those are is the order the walk reaches them in, and that
    // order was not run-to-run stable when this was found (see
    // `bench/repeat_sweep.sh`: object property records are sorted by name atom
    // and atom ids came from the parallel interner's per-shard insertion
    // order, before the renumbering pinned them). drizzle-orm charged
    // 499,656 / 499,854 / 499,944 `inst cache misses` across repeats of one
    // binary for exactly that reason. Scoped to the subtree the test asks
    // the question it means — "was MY result truncated" — and the memo
    // becomes a function of `(map, t)` alone.
    const outer_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or outer_trip;
    const s = &c.ts;
    const result: TypeId = switch (s.kind(t)) {
        .type_param => tpLookup(map, s.typeParamSymbol(t)) orelse t,
        .union_type => blk: {
            // Exact allocation, not a doubling `ArrayList`: the arity is known
            // and an arena cannot reuse a realloc predecessor, so every growth
            // step of every list this walk builds stays resident until the
            // top-level `instantiate` releases `inst_arena`. See the note on
            // `scratch_high_water` there — one kysely builder chain peaked the
            // arena above a gigabyte, most of it abandoned growth steps.
            const parts = try c.scratch().alloc(TypeId, s.memberCount(t));
            defer c.scratch().free(parts);
            for (parts, 0..) |*p, i| p.* = try c.instantiateId(s.memberAt(t, i), map, map_id);
            break :blk try s.makeUnion(c.scratch(), parts);
        },
        .intersection => blk: {
            const parts = try c.scratch().alloc(TypeId, s.memberCount(t));
            defer c.scratch().free(parts);
            for (parts, 0..) |*p, i| p.* = try c.instantiateId(s.memberAt(t, i), map, map_id);
            const inter = try s.makeIntersection(c.scratch(), parts);
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
            const parts = try c.scratch().alloc(TypeId, s.memberCount(t));
            defer c.scratch().free(parts);
            for (parts, 0..) |*p, i| p.* = try c.instantiateId(s.memberAt(t, i), map, map_id);
            break :blk try s.makeOverloads(parts);
        },
        .array => try s.makeArrayLike(t, try c.instantiateId(s.arrayElem(t), map, map_id)),
        .tuple => blk: {
            const elems = try c.scratch().alloc(types.TupleElem, s.tupleLen(t));
            defer c.scratch().free(elems);
            for (elems, 0..) |*el, i| {
                const e = s.tupleElem(t, @intCast(i));
                el.* = .{ .ty = try c.instantiateId(e.ty, map, map_id), .flags = e.flags };
            }
            break :blk try s.makeTuple(elems);
        },
        .object => blk: {
            const props = try c.scratch().alloc(types.Prop, s.objectPropCount(t));
            defer c.scratch().free(props);
            // Per-member charging, only for the ONE table an `expandRef` frame
            // is substituting right now (see `InstProf.expand_generic`).
            const charge_members = c.prof.on and t == c.prof.expand_generic and t != 0;
            const charge_sym = c.prof.expand_sym;
            for (props, 0..) |*out, i| {
                const p = s.objectProp(t, @intCast(i));
                const before = if (charge_members) c.inst_total else 0;
                out.* = .{ .name = p.name, .ty = try c.instantiateId(p.ty, map, map_id), .flags = p.flags };
                if (charge_members) prof_zig.noteMemberCost(c, charge_sym, p.name, out.ty, c.inst_total - before);
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
            const call_buf = try c.scratch().alloc(TypeId, s.objectCallSigCount(t));
            defer c.scratch().free(call_buf);
            var n_call: usize = 0;
            const ctor_buf = try c.scratch().alloc(TypeId, s.objectConstructSigCount(t));
            defer c.scratch().free(ctor_buf);
            var n_ctor: usize = 0;
            for (0..s.objectCallSigCount(t)) |i| {
                const sig = s.objectCallSig(t, @intCast(i));
                // A non-eligible higher-order sig (RHF-style deep bound) is
                // dropped — the pristine behavior — so its call sites are
                // unchanged; eligible ones and param-free ones instantiate.
                if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                call_buf[n_call] = try c.instantiateId(sig, map, map_id);
                n_call += 1;
            }
            for (0..s.objectConstructSigCount(t)) |i| {
                const sig = s.objectConstructSig(t, @intCast(i));
                if (s.fnTypeParams(sig).len != 0 and !try c.higherOrderSigEligible(sig)) continue;
                ctor_buf[n_ctor] = try c.instantiateId(sig, map, map_id);
                n_ctor += 1;
            }
            const obj = try s.makeObjectSigs(props, sidx, nidx, s.objectFlags(t), call_buf[0..n_call], ctor_buf[0..n_ctor]);
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
            // Eligibility decides whether a rewritten bound is ENFORCED, not
            // whether the substitution happens. Gating the substitution too
            // left an ineligible signature's own bound standing over the
            // ENCLOSING generic's parameter — a bound nothing can satisfy,
            // because that parameter has just been substituted away. socket.io
            // writes `emit<Ev extends EventNames<RemoveAcknowledgements<E>>>`
            // on `StrictEventEmitter<…, E>`; `higherOrderSigEligible` declines
            // the bound (its `Last`/`Parameters` chain has an `infer` in the
            // extends clause, so `boundReducible` is false and there is no
            // mapped/template shape at the top for `boundHasReducerShape`),
            // and `Ev` was then clamped to a constraint still mentioning `E`.
            // Every `server.emit('…')` in immich was TS2345 against an
            // unreduced `IsAny<…>` chain.
            //
            // So the substitution is unconditional and only `fc` — the
            // constraint the fresh parameter actually enforces — keeps the
            // gate. An ineligible bound rides along as `widen_bound`, exactly
            // as a bare bound already does: unenforced, but no longer a
            // dangling reference.
            const rewritable = n_tps != 0 and map.len > 0;
            const eligible = rewritable and try c.higherOrderSigEligible(t);
            if (rewritable) try cur_map.appendSlice(c.scratch(), map);
            // Index: the loop body resolves bounds and instantiates, both of
            // which intern and can move `extra` (see `memberAt`).
            for (0..n_tps) |tp_i| {
                const tp = s.fnTypeParamAt(t, tp_i);
                if (tpLookup(map, tp) != null) continue; // substituted away
                var fresh: ?u32 = null;
                if (rewritable) {
                    const od = try c.typeParamDefault(tp);
                    const oc = try c.typeParamConstraint(tp);
                    const bound_before = if (c.prof.on) c.inst_total else 0;
                    const nd = if (od != types.no_type) try c.instantiateId(od, cur_map.items, cur_id) else od;
                    // The constraint is the expensive half (a kysely bound is
                    // a mapped type over every column of every table in
                    // scope) and 88% of the ones this checker computes are
                    // never read back. Decide whether it MOVES without
                    // substituting it, and when it may, hand the substitution
                    // to `resolveFreshBound` — the fresh parameter's bound has
                    // exactly one reader, `typeParamConstraint`.
                    const may_move = oc != types.no_type and try c.boundMayMove(oc, cur_map.items);
                    if (may_move and cur_id != null) {
                        // `may_move` IS the mint test on the constraint side;
                        // the default half rides along on the record so a
                        // resolution can tell a speculative mint from a real
                        // one. Nothing is substituted here.
                        const enforce = eligible and c.ts.kind(oc) != .type_param;
                        fresh = try c.mintFreshTpDeferred(tp, cur_id.?, oc, nd, od != types.no_type, enforce, nd != od);
                    } else {
                        // Either the memo is off (no map id to defer under) or
                        // the bound provably cannot move, in which case
                        // `nc == oc` exactly and the substitution is skipped
                        // outright — this is the `discarded` population the
                        // eager code paid for and threw away.
                        fresh = try eagerBound(c, tp, oc, od, nd, cur_map.items, cur_id, eligible, may_move, bound_before);
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
            const params = try c.scratch().alloc(types.Param, s.fnParamCount(t));
            defer c.scratch().free(params);
            for (params, 0..) |*out, i| {
                const p = s.fnParam(t, @intCast(i));
                out.* = .{ .name = p.name, .ty = try c.instantiateId(p.ty, sub_map, sub_id), .flags = p.flags };
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
            const fnres = try s.makeFunctionThis(params, ret, kept.items, s.fnFlags(t), pred, if (this_ty != 0) try c.instantiateId(this_ty, sub_map, sub_id) else 0);
            // Propagate the origin tag through function instantiation (see
            // the `.object` arm) — an aliased function member such as RHF's
            // `UseFormClearErrors<T>` relates by identity across builds.
            if (c.origin.get(t)) |orig_ref| {
                if (fnres != t and c.ts.kind(fnres) == .function) try c.tagInstantiatedOrigin(fnres, orig_ref, map, map_id);
            }
            break :blk fnres;
        },
        .ref => blk: {
            const args = try c.scratch().alloc(TypeId, s.refArgCount(t));
            defer c.scratch().free(args);
            for (args, 0..) |*a, i| a.* = try c.instantiateId(s.refArgAt(t, i), map, map_id);
            break :blk try s.makeRef(s.refSymbol(t), args);
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
                        if (c.prof.on) c.prof.cond_subst_laps += 1;
                        c.cond_check_subst = .{ .from = check0, .to = m };
                        const ext_m = try c.instantiateId(s.condExtends(t), map, null);
                        const tru_m = try c.instantiateId(s.condTrue(t), map, null);
                        const fls_m = try c.instantiateId(s.condFalse(t), map, null);
                        c.cond_check_subst = saved_subst;
                        // Distributivity is spent only on a member that cannot
                        // grow: a STILL-GENERIC member (`keyof P` for an
                        // unbound `P`) becomes a union of its own once that
                        // parameter arrives, and those constituents need the
                        // same one-at-a-time treatment. Baking `false` here
                        // froze the member as a single whole-union test, so the
                        // later expansion was asked `"as" | "size" | "ellipsis"
                        // extends "as" | "size"` — false — and `Exclude` handed
                        // back every key it was supposed to remove.
                        //
                        // styled-components' `.attrs` is that shape, two alias
                        // hops deep: `MakeAttrsOptional<C, O, A>` reaches
                        // `OmitU<P & O, A>` → `PickU<T, Exclude<keyof T, K>>`,
                        // whose `keyof (P & O)` is `keyof P | keyof O` — a union
                        // of two DEFERRED keyofs. With the exclusion lost, every
                        // prop `.attrs({…})` supplies stayed REQUIRED in the
                        // component's props, so `<Title>text</Title>` was missing
                        // `as`/`size`, the first (non-polymorphic) call signature
                        // was rejected, and the element re-checked against the
                        // polymorphic `as` signature with `AsC` inferred as
                        // `string`/`unknown` — one TS2322 per styled element.
                        const m_open = try c.containsFreeTypeParam(m, &.{}) or
                            try c.containsMappedParam(m) or
                            try c.containsThisType(m);
                        try parts.append(c.scratch(), try c.reduceConditional(m, ext_m, tru_m, fls_m, m_open));
                    }
                    break :blk try s.makeUnion(c.scratch(), parts.items);
                }
            }
            const chk = try c.instantiateId(check0, map, map_id);
            const ext = try c.instantiateId(s.condExtends(t), map, map_id);
            // Decide FIRST, substitute the winning branch only — see
            // `CondPlan`. A fall-through chain of conditionals (kysely's
            // reference-expression machinery is eight deep) costs its own
            // length here instead of two to the power of it.
            const plan = try c.planConditional(chk, ext, s.condDistributive(t));
            switch (plan) {
                .value => |v| break :blk v,
                .take_false => break :blk try c.instantiateId(s.condFalse(t), map, map_id),
                .take_true => |b| break :blk try c.condTrueBranch(b, try c.instantiateId(s.condTrue(t), map, map_id)),
                .both_any, .need_both => {
                    const tru = try c.instantiateId(s.condTrue(t), map, map_id);
                    const fls = try c.instantiateId(s.condFalse(t), map, map_id);
                    break :blk try c.finishCondPlan(plan, chk, ext, tru, fls, s.condDistributive(t));
                },
            }
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
            const holes = try c.scratch().alloc(TypeId, s.templateHoleCount(t));
            defer c.scratch().free(holes);
            for (holes, 0..) |*h, i| h.* = try c.instantiateId(s.templateHole(t, @intCast(i)), map, map_id);
            break :blk try c.reduceTemplate(s.templateHead(t), holes, t);
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
        if (!c.inst_limit_tripped) c.inst_cache.put(mid, t, result);
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
    if (c.inst_depth > max_instantiation_depth) {
        // Depth-dependent truncation, so it has to be announced: an enclosing
        // `instantiateId`/`substThis` frame is about to decide whether to
        // memoize a result that has this `error_type` inside it, and that
        // decision is `inst_limit_tripped`. Returning silently let a
        // truncated answer be cached as if it were a function of the pair —
        // and whether a given walk arrives here deep or shallow is traversal
        // order, which is not run-to-run stable.
        c.inst_limit_tripped = true;
        return types.error_type;
    }
    const memo_key = (@as(u64, t) << 32) | repl;
    if (c.subst_this_cache.get(memo_key)) |m| return m;
    // Subtree-scoped, for `instantiateId`'s reason — the flag has to answer
    // "was MY result truncated", not "was anything earlier in this call".
    // `this_subst_cuts` below is already scoped that way, by delta.
    const outer_trip = c.inst_limit_tripped;
    c.inst_limit_tripped = false;
    defer c.inst_limit_tripped = c.inst_limit_tripped or outer_trip;
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
    for (c.this_subst_keys[0..c.this_subst_depth]) |k| {
        if (k == memo_key) {
            c.this_subst_cuts +%= 1;
            return t;
        }
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
        if (seen >= max_this_subst_repeats) {
            c.this_subst_cuts +%= 1;
            return t;
        }
    }
    c.this_subst_keys[c.this_subst_depth] = memo_key;
    c.this_subst_syms[c.this_subst_depth] = t_sym;
    c.this_subst_depth += 1;
    defer c.this_subst_depth -= 1;
    const cuts_before = c.this_subst_cuts;
    const r = try substThisInner(c, t, repl);
    // A truncated answer is depth-dependent, and one computed while a guard
    // above cut a lap underneath depends on the live stack — neither is a
    // function of the pair, so neither is memoized (the rule `inst_cache`
    // follows).
    if (!c.inst_limit_tripped and c.this_subst_cuts == cuts_before)
        try c.subst_this_cache.put(c.cm(), memo_key, r);
    return r;
}

fn substThisInner(c: *Checker, t: TypeId, repl: TypeId) Error!TypeId {
    if (c.inst_depth > max_instantiation_depth) {
        c.inst_limit_tripped = true; // see `substThis`
        return types.error_type;
    }
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
            // A `this` marker also hides in the signature's OWN type-param
            // BOUNDS, and those are held by symbol, not by type — so leaving
            // `fnTypeParams` alone left the marker unresolvable. zod's
            // `refine<Ch extends (arg: output<this>) => unknown>(check: Ch)`
            // is the shape: the argument's contextual type comes from `Ch`'s
            // constraint, so an unsubstituted bound handed the callback a
            // deferred `this extends {_zod:{output:any}} ? … : unknown` and
            // every parameter of the arrow fell to implicit `any` (TS7006)
            // with TS2339 on each use. tsc has no such gap by construction:
            // it appends `thisType` to the interface's type parameters and
            // the receiver to its arguments, so ORDINARY instantiation —
            // which does clone own params with substituted bounds — covers
            // `this` too. Mirror `instantiateId`'s higher-order rewrite here:
            // mint a fresh symbol per own param whose bound actually moved,
            // and rewrite its references in the body to the fresh one.
            var kept: std.ArrayList(u32) = .empty;
            defer kept.deinit(c.scratch());
            var fresh_map: std.ArrayList(TpMap) = .empty;
            defer fresh_map.deinit(c.scratch());
            for (0..s.fnTypeParamCount(t)) |tp_i| {
                const tp = s.fnTypeParamAt(t, tp_i);
                const oc = try c.typeParamConstraint(tp);
                const od = try c.typeParamDefault(tp);
                // A bound may name a SIBLING own param, so the rewrites
                // minted so far in this loop apply to it as well (the reason
                // `instantiateId` threads `cur_map`).
                var nc = if (oc != types.no_type) try c.substThis(oc, repl) else oc;
                var nd = if (od != types.no_type) try c.substThis(od, repl) else od;
                if (fresh_map.items.len > 0) {
                    if (nc != types.no_type) nc = try c.instantiate(nc, fresh_map.items);
                    if (nd != types.no_type) nd = try c.instantiate(nd, fresh_map.items);
                }
                if (nc != oc or nd != od) {
                    const fid = try c.mintThisTp(tp, repl, nc, nd, od != types.no_type);
                    try kept.append(c.scratch(), fid);
                    try fresh_map.append(c.scratch(), .{ .sym = tp, .ty = try s.makeTypeParam(fid) });
                } else {
                    try kept.append(c.scratch(), tp);
                }
            }
            var params: std.ArrayList(types.Param) = .empty;
            defer params.deinit(c.scratch());
            for (0..s.fnParamCount(t)) |i| {
                const p = s.fnParam(t, @intCast(i));
                var pt = try c.substThis(p.ty, repl);
                if (fresh_map.items.len > 0) pt = try c.instantiate(pt, fresh_map.items);
                try params.append(c.scratch(), .{ .name = p.name, .ty = pt, .flags = p.flags });
            }
            var ret = try c.substThis(s.fnReturn(t), repl);
            if (fresh_map.items.len > 0) ret = try c.instantiate(ret, fresh_map.items);
            const this_ty = s.fnThisType(t);
            const pred: ?types.Predicate = if (s.fnHasPredicate(t)) s.fnPredicate(t) else null;
            return s.makeFunctionThis(params.items, ret, kept.items, s.fnFlags(t), pred, this_ty);
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

// =====================================================================
// re-exports
// =====================================================================
//
// `statics.zig` was split out of this file. Its symbols keep their original
// import path here so the `Checker` method aliases in `checker.zig` — and
// every other module's `@import("enums.zig").X` — resolve unchanged.

const statics = @import("statics.zig");
pub const ownStaticMemberProp = statics.ownStaticMemberProp;
pub const classStaticType = statics.classStaticType;
pub const classConstructType = statics.classConstructType;
pub const sigWithReturn = statics.sigWithReturn;
pub const ctorSignatures = statics.ctorSignatures;
