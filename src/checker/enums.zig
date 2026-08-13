//! Enums: member typing, literal types, initializers, the syntactic constant
//! evaluator they share with template folding, and the nominal/structural
//! enum relations. Functions take the `Checker` context as their first
//! parameter.
//!
//! The class-statics and type-parameter-substitution engines that used to
//! share this file now live in `statics.zig` and `subst.zig`; both are
//! re-exported at the bottom, so every existing consumer (and every
//! `Checker` method alias built on these names) still resolves through here.

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
fn aliasedEnumInitValue(c: *Checker, own: SymbolId, init_node: Node) Error!?TypeId {
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
        // The bare-name form (`B = A`, a member of the same enum) RESOLVES
        // — `bindEnum` gives the body its own scope — but is not folded:
        // `own` is mid-walk here, so re-entering `enumMembersOf` for it
        // would recurse, and the values of the members already visited are
        // not threaded through this call. The member is classified
        // `computed`, exactly as it was before the scope existed, so this is
        // a pure under-fold: a value tsc knows and ztsc does not.
        else => return null,
    }
}

/// Classify an enum member initializer for constant folding. Only literal
/// numbers (incl. unary `-`/`+`) and string literals fold to constants;
/// anything else is "computed".
fn classifyEnumInit(c: *Checker, node: Node) struct { kind: EnumInitKind, value: f64 } {
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
fn enumInitAtom(c: *Checker, init_node: Node) Error!Atom {
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
            const ci = classifyEnumInit(c, init_node);
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
                    if (try aliasedEnumInitValue(c, sym, init_node)) |v| {
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
            const ci = classifyEnumInit(c, init_node);
            switch (ci.kind) {
                .string => {
                    const av = try enumInitAtom(c, init_node);
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
                    if (try aliasedEnumInitValue(c, sym, init_node)) |v| {
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

/// The enum a MEMBER symbol belongs to, as a global (possibly cross-file
/// merged) symbol: members live in the enum's body scope, which
/// `enumOfScope` maps straight back to the enum symbol.
pub fn enumOfMemberSym(c: *Checker, sym: SymbolId) ?SymbolId {
    const local = c.localOf(sym);
    const b = c.symBind(sym);
    const scope = b.symbol_scopes[local];
    const owner = b.enumOfScope(scope) orelse return null;
    const g = c.toGlobalIn(c.symFile(sym), owner);
    return c.prog.mergedOf(g) orelse g;
}

/// `getTypeOfSymbol` for an enum MEMBER symbol — the member literal type
/// `E.A`, the same type `E.A` produces at a property access (`memberTypeOf`
/// builds it with the same `makeEnumMember` call). A member whose enclosing
/// enum cannot be recovered degrades to `number`, never to an error type:
/// the reference itself resolved.
pub fn enumMemberSymbolType(c: *Checker, sym: SymbolId) Error!TypeId {
    const esym = enumOfMemberSym(c, sym) orelse return types.number_type;
    return c.ts.makeEnumMember(esym, c.symNameAtom(sym), false);
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
    // First declaration wins, for an enum that declares the same name twice
    // (`enumMembersOf` keeps both entries, in declaration order).
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
pub fn enumMemberForValue(c: *Checker, sym: SymbolId, value: TypeId) Error!?TypeId {
    const ByValue = struct {
        c: *Checker,
        sym: SymbolId,
        want: TypeId,
        found: TypeId = types.no_type,
        fn visit(self: *@This(), name: Atom, v: TypeId) Error!void {
            if (self.found != types.no_type or v == types.no_type) return;
            if ((try self.c.ts.regularLiteral(v)) != self.want) return;
            self.found = try self.c.ts.makeEnumMember(self.sym, name, false);
        }
    };
    var look: ByValue = .{ .c = c, .sym = sym, .want = try c.ts.regularLiteral(value) };
    try c.eachEnumMember(sym, &look, ByValue.visit);
    return if (look.found == types.no_type) null else look.found;
}

/// `eachEnumMember` visitor collecting one member TYPE per distinct member
/// name. Stays `pub` — unlike this file's other visitors it has a second
/// consumer, `generics.zig`'s whole-enum key expansion.
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
            if (init_node != null_node and classifyEnumInit(c, init_node).kind == .string) return true;
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

/// Nominal enum assignability. Identical types (same enum, same member)
/// are caught by `s == t` upstream, and `E.A → E` by the `literalBaseOf`
/// fast path, so what is left here is the widening in and out of the
/// primitive domain. Oracle-verified: a numeric enum (and a numeric
/// *member*) interconverts with `number` and accepts a numeric literal of
/// its own value; a string enum is a subtype of `string` but nothing —
/// not `string`, not the matching string literal — widens *into* it; and
/// `E → E.A`, `E.A → E.B` and `E1.A → E2.A` are all rejected.
///
/// `sk`/`tk` are caller-supplied rather than re-derived from `s`/`t`: the
/// sole caller (`assign.zig`'s relation) has already switched on both kinds
/// to get here and passes the values it holds. At least one of them is
/// `.enum_type`.
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
            if (classifyEnumInit(c, init_node).kind != .string) continue;
            if ((try enumInitAtom(c, init_node)) == val) return true;
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
            if (classifyEnumInit(c, init_node).kind != .string) return false;
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
    // Initializers are checked INSIDE the enum's member scope, so a bare
    // member name resolves to the member (and shadows an outer binding of
    // the same name) — tsc's `resolveName` case for an EnumDeclaration
    // location. Reached through the enum SYMBOL rather than `scopeOf(node)`,
    // because merged blocks share one scope owned by the first of them.
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(c.cur_scope, a)) |local| {
            if (c.bind.enumScopeOf(local)) |s| c.cur_scope = s;
        }
    }
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
        prev_numeric_const = classifyEnumInit(c, init_node).kind != .string;
    }
}

// =====================================================================
// re-exports
// =====================================================================
//
// `statics.zig` and `subst.zig` were split out of this file. Their symbols
// keep their original import path here so the `Checker` method aliases in
// `checker.zig` — and every other module's `@import("enums.zig").X` — resolve
// unchanged.

const statics = @import("statics.zig");
pub const ownStaticMemberProp = statics.ownStaticMemberProp;
pub const classStaticType = statics.classStaticType;
pub const classConstructType = statics.classConstructType;
pub const sigWithReturn = statics.sigWithReturn;
pub const ctorSignatures = statics.ctorSignatures;

const subst = @import("subst.zig");
pub const TpMap = subst.TpMap;
pub const InferKey = subst.InferKey;
pub const InferConstraint = subst.InferConstraint;
pub const higherOrderSigEligible = subst.higherOrderSigEligible;
pub const boundHasReducerShape = subst.boundHasReducerShape;
pub const boundReducible = subst.boundReducible;
pub const sigReferencesOuterParam = subst.sigReferencesOuterParam;
pub const containsTypeParam = subst.containsTypeParam;
pub const containsTypeParamInner = subst.containsTypeParamInner;
pub const boundMayMove = subst.boundMayMove;
pub const tpMentions = subst.tpMentions;
pub const containsFreeTypeParam = subst.containsFreeTypeParam;
pub const tpLookup = subst.tpLookup;
pub const canonMapId = subst.canonMapId;
pub const mapForId = subst.mapForId;
pub const isFreshTp = subst.isFreshTp;
pub const freshTp = subst.freshTp;
pub const tpOrigin = subst.tpOrigin;
pub const isConstTypeParamSym = subst.isConstTypeParamSym;
pub const mintFreshTp = subst.mintFreshTp;
pub const mintFreshTpDeferred = subst.mintFreshTpDeferred;
pub const resolveFreshBound = subst.resolveFreshBound;
pub const mintThisTp = subst.mintThisTp;
pub const instantiate = subst.instantiate;
pub const tagInstantiatedOrigin = subst.tagInstantiatedOrigin;
pub const chainRepeats = subst.chainRepeats;
pub const instantiateId = subst.instantiateId;
pub const this_apparent = subst.this_apparent;
pub const substThis = subst.substThis;
pub const containsThisType = subst.containsThisType;
