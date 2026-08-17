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

const elaborate = @import("elaborate.zig");

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

/// What one member initializer evaluated to. `computed` is tsc's `undefined`
/// — no constant value — and is what the enum diagnostics fire on; `capped`
/// is ztsc's own "gave up", which must fire NOTHING (see `Const.deep`).
const EnumInitKind = enum { numeric, string, computed, capped };

// =====================================================================
// the syntactic constant evaluator (tsc's `createEvaluator`)
// =====================================================================

/// A syntactic-constant evaluation result. `.str` means the value's TEXT was
/// appended to the caller's `out` buffer; every other arm leaves `out` at the
/// length it had on entry. That convention makes string concatenation free —
/// `a + b` evaluates both operands into the same buffer, back to back, and the
/// concatenation is already there.
///
/// `.deep` is NOT `.none`. `.none` is tsc's answer — this expression has no
/// constant value — and the enum diagnostics fire on it; `.deep` is ztsc's own
/// recursion cap giving up, which tsc has no equivalent of, so every caller
/// has to fall silent rather than report. `1 + 1 + … + 1` thirty times over,
/// or a chain of two dozen `const`s, is a perfectly ordinary constant that a
/// fixed cap cannot fold, and reporting there would be a false TS1061.
const Const = union(enum) { num: f64, str, none, deep };

/// The enum-member walk an evaluation is running inside, if any. tsc's
/// `evaluate(initializer, member)` resolves a name against the members the
/// SAME walk has already evaluated (`enum E { A = 1, B = A + 1 }`) instead of
/// re-entering the enum, which is what keeps the walk from recursing.
const EnumScope = struct {
    active: bool = false,
    own: SymbolId = 0,
    seen: []const checker_zig.EnumMemberEntry = &.{},
    /// File TS2651 on every forward reference the walk meets. Off for the
    /// memoized member walk — that one is re-entrant, and a diagnostic filed
    /// from inside it would land once per entry into the memo. `checkEnum`
    /// re-runs the same evaluator once per member with this on, which visits
    /// exactly the subexpressions tsc's `evaluate` does.
    report: bool = false,
    /// The `enum_member` node whose initializer is being evaluated — tsc's
    /// `location`. A reference that lands back on it is TS2565 rather than
    /// TS2651 (`declaration === location` in `evaluateEnumMember`).
    self: Node = null_node,

    /// `.none` when the name is not a member evaluated so far — the caller
    /// falls back to ordinary resolution; a member declared LATER in the same
    /// enum resolves to a symbol with no foldable declaration, so it lands on
    /// `.none` there too (tsc's forward-reference rule, minus its diagnostic).
    fn lookup(self: EnumScope, name: Atom) ?TypeId {
        if (!self.active) return null;
        for (self.seen) |m| {
            if (m.name == name) return m.value;
        }
        return null;
    }
};

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
/// The enum member walk folds through the SAME evaluator, because tsc's is
/// the same function (`utilities.ts`'s `createEvaluator`, one instance shared
/// by `checkTemplateExpression` and `computeConstantValue`). Completeness
/// matters in the enum direction: a form tsc folds and this does not turns
/// tsc's silence into a false TS1061/TS1066/TS2474, so the operator arms are
/// exactly tsc's set.
///
/// This works over the *syntax*, not over checked types: tsc only folds a
/// name that resolves to an enum member or to a `const` variable with **no
/// type annotation** and an initializer (`evaluateEntityNameExpression` ->
/// `isConstantVariable(symbol) && declaration && !declaration.type &&
/// declaration.initializer`). Folding on the checked type instead would also
/// fold `declare const x: 'abc'`, which tsc leaves as `string`.
fn evalConst(c: *Checker, node: Node, out: *std.ArrayList(u8), es: EnumScope, depth: u16) Error!Const {
    if (node == null_node) return .none;
    if (depth > max_const_eval_depth) return .deep;
    const mark = out.items.len;
    const d = c.tree.nodeData(node);
    const main_tok = c.tree.nodeMainToken(node);
    switch (c.nodeTag(node)) {
        .string_literal => {
            try out.appendSlice(c.scratch(), c.atomText(try c.memberAtom(main_tok)));
            return .str;
        },
        // A no-substitution template is a string constant (tsc folds
        // `NoSubstitutionTemplateLiteral` to its cooked text).
        .template_literal => {
            try out.appendSlice(c.scratch(), c.atomText(try c.templateAtom(main_tok)));
            return .str;
        },
        .number_literal => return .{ .num = c.numberTokenValue(main_tok) },
        .paren_expr => return evalConst(c, d.lhs, out, es, depth + 1),
        .prefix_unary => {
            const op = c.tree.tokens.tag(main_tok);
            if (op != .minus and op != .plus and op != .tilde) return .none;
            const r = try evalConst(c, d.lhs, out, es, depth + 1);
            out.shrinkRetainingCapacity(mark);
            const v = switch (r) {
                .num => |n| n,
                .deep => return .deep,
                else => return .none,
            };
            return .{ .num = switch (op) {
                .minus => -v,
                .plus => v,
                else => @floatFromInt(~toInt32(v)),
            } };
        },
        .binary => return evalConstBinary(c, node, out, es, depth),
        .template_expr => {
            try out.appendSlice(c.scratch(), c.templateHeadText(main_tok));
            for (c.tree.nodeRange(node)) |sub| {
                const r = try evalConst(c, sub, out, es, depth + 1);
                switch (r) {
                    .none, .deep => {
                        out.shrinkRetainingCapacity(mark);
                        return if (r == .deep) .deep else .none;
                    },
                    // A numeric substitution stringifies (tsc's
                    // `evaluateTemplateExpression` does `result += value`).
                    .num => |n| try appendNumber(c, out, n),
                    .str => {},
                }
                const ctok = c.templateChunkTokAfter(main_tok, c.nodeSpan(sub).end);
                try out.appendSlice(c.scratch(), c.templateChunkText(ctok));
            }
            return .str;
        },
        .identifier, .member_expr, .index_expr => return evalConstEntity(c, node, out, es, depth),
        else => return .none,
    }
}

/// Deep enough for any hand-written constant expression — the deepest in the
/// TypeScript corpus is a dozen — and shallow enough that the recursion costs
/// far less stack than the parse of the same expression did. Beyond it the
/// answer is `.deep`, never `.none`, so overrunning it stays silent.
const max_const_eval_depth: u16 = 200;

/// JS `ToInt32`, the coercion every bitwise operator applies to its operands.
fn toInt32(v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const wrapped = @mod(@trunc(v), 4294967296.0);
    if (!(wrapped >= 0) or wrapped >= 4294967296.0) return 0;
    return @bitCast(@as(u32, @intFromFloat(wrapped)));
}

fn toUint32(v: f64) u32 {
    return @bitCast(toInt32(v));
}

/// tsc's `BinaryExpression` arm: the twelve arithmetic/bitwise operators over
/// two numbers, plus `+` over two strings. Anything else is not a constant.
fn evalConstBinary(c: *Checker, node: Node, out: *std.ArrayList(u8), es: EnumScope, depth: u16) Error!Const {
    const mark = out.items.len;
    const d = c.tree.nodeData(node);
    const op = c.tree.tokens.tag(c.tree.nodeMainToken(node));
    switch (op) {
        .pipe, .amp, .caret, .lt_lt, .gt_gt, .gt_gt_gt, .asterisk, .slash, .plus, .minus, .percent, .asterisk_asterisk => {},
        else => return .none,
    }
    const l = try evalConst(c, d.lhs, out, es, depth + 1);
    if (l == .none or l == .deep) {
        out.shrinkRetainingCapacity(mark);
        return if (l == .deep) .deep else .none;
    }
    const r = try evalConst(c, d.rhs, out, es, depth + 1);
    // tsc's `+` arm coerces with `"" + left + right` as soon as EITHER side is
    // a string, so `"a" + 1` and `` `1` + 1 `` are string constants — not
    // computed members. A `.num` operand contributed nothing to `out`, so the
    // stringified number goes in at that operand's place: after the left
    // half's bytes, or at `mark` when the number is the left operand.
    if (op == .plus and (l == .str or r == .str)) {
        if (l == .str and r == .str) return .str;
        if (l == .str and r == .num) {
            try appendNumber(c, out, r.num);
            return .str;
        }
        if (l == .num and r == .str) {
            var buf: [64]u8 = undefined;
            try out.insertSlice(c.scratch(), mark, numberText(&buf, l.num));
            return .str;
        }
    }
    if (l != .num or r != .num) {
        out.shrinkRetainingCapacity(mark);
        return if (r == .deep) .deep else .none;
    }
    const a = l.num;
    const b = r.num;
    const sh: u5 = @intCast(toUint32(b) & 31);
    return .{ .num = switch (op) {
        .pipe => @floatFromInt(toInt32(a) | toInt32(b)),
        .amp => @floatFromInt(toInt32(a) & toInt32(b)),
        .caret => @floatFromInt(toInt32(a) ^ toInt32(b)),
        .lt_lt => @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(@as(u64, toUint32(a)) << sh))))),
        .gt_gt => @floatFromInt(toInt32(a) >> sh),
        .gt_gt_gt => @floatFromInt(toUint32(a) >> sh),
        .asterisk => a * b,
        .slash => a / b,
        .plus => a + b,
        .minus => a - b,
        .percent => @rem(a, b),
        else => std.math.pow(f64, a, b),
    } };
}

/// JS `String(v)` for the values the evaluator can hold, rendered into
/// caller-owned storage. Empty when the value does not fit the buffer.
fn numberText(buf: []u8, v: f64) []const u8 {
    return if (v == @floor(v) and @abs(v) < 1e15)
        std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch ""
    else
        std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

fn appendNumber(c: *Checker, out: *std.ArrayList(u8), v: f64) Error!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(c.scratch(), numberText(&buf, v));
}

/// The literal type an enum member walk produced, back in evaluator terms.
fn constOfType(c: *Checker, v: TypeId, out: *std.ArrayList(u8)) Error!Const {
    if (v == types.no_type) return .none;
    return switch (c.ts.kind(v)) {
        .string_literal => blk: {
            try out.appendSlice(c.scratch(), c.atomText(c.ts.literalAtom(v)));
            break :blk .str;
        },
        .number_literal, .number_literal_fresh => .{ .num = c.ts.numberValue(v) },
        else => .none,
    };
}

/// `Infinity` / `NaN` fold to their values only while they still name the lib
/// globals — tsc's `isInfinityOrNaNString(text) && symbol === globalSymbol`,
/// which `enumShadowedInfinityNaN` exercises by shadowing both with `{}`.
fn globalNumberName(c: *Checker, a: Atom, sym: SymbolId) ?f64 {
    const text = c.atomText(a);
    const v: f64 = if (std.mem.eql(u8, text, "Infinity"))
        std.math.inf(f64)
    else if (std.mem.eql(u8, text, "NaN"))
        std.math.nan(f64)
    else
        return null;
    const g = c.prog.globals.lookup(a) orelse return null;
    return if (g == sym) v else null;
}

/// tsc's `evaluateEntityNameExpression` / `evaluateElementAccessExpression`:
/// an enum member folds to its constant value, a `const` variable with no
/// annotation folds to its initializer's value.
fn evalConstEntity(c: *Checker, node: Node, out: *std.ArrayList(u8), es: EnumScope, depth: u16) Error!Const {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(node));
            if (es.lookup(a)) |v| return constOfType(c, v, out);
            if (try forwardEnumMember(c, es, a, node)) |v| return v;
            const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |s| s,
                else => return .none,
            };
            if (globalNumberName(c, a, sym)) |v| return .{ .num = v };
            return evalConstSym(c, sym, out, depth);
        },
        // `E.M` / `NS.E.M` — the enum-member arm; `NS.Q` — a `const` reached
        // through its namespace container.
        .member_expr => {
            const name = try c.memberAtom(d.rhs);
            if (try evalEnumQualified(c, d.lhs, name, out, es, node)) |r| return r;
            const saved_scope = c.cur_scope;
            defer c.cur_scope = saved_scope;
            const outer = (try c.resolveNsContainer(d.lhs)) orelse return .none;
            const g = c.containerMemberSym(outer, name) orelse return .none;
            return evalConstSym(c, g, out, depth);
        },
        // ``E["M"]`` / ``E[`M`]`` — tsc's `evaluateElementAccessExpression`,
        // whose index must be `isStringLiteralLike` (a quoted literal or a
        // no-substitution template) and whose root must name an enum.
        .index_expr => {
            const itok = c.tree.nodeMainToken(d.rhs);
            const name = switch (c.nodeTag(d.rhs)) {
                .string_literal => try c.memberAtom(itok),
                .template_literal => try c.templateAtom(itok),
                else => return .none,
            };
            return (try evalEnumQualified(c, d.lhs, name, out, es, node)) orelse .none;
        },
        else => return .none,
    }
}

/// A name that the enum currently being walked declares but has NOT reached
/// yet — `const enum E1 { X = Y, Y = 1 }`. tsc's `evaluateEnumMember` reports
/// TS2651 for it and then returns **0**, not `undefined`, so the member does
/// have a value: the following members keep auto-incrementing and a `const`
/// enum gets no TS2474. `at` is the reference expression tsc anchors that
/// diagnostic on — the bare identifier, or the whole `E.M` / `E["M"]` access.
///
/// Read straight off the declaration, never through `enumMembersOf` — the
/// enum's own walk is in progress, and re-entering it would recurse.
fn forwardEnumMember(c: *Checker, es: EnumScope, name: Atom, at: Node) Error!?Const {
    if (!es.active) return null;
    for (c.declsOf(es.own)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            if ((try c.memberAtom(c.tree.nodeMainToken(m))) != name) continue;
            if (es.report) {
                if (m == es.self) {
                    try c.diagFmt(2565, c.nodeSpan(at), "Property '{s}' is used before being assigned.", .{c.atomText(name)});
                } else {
                    try c.diagFmt(2651, c.nodeSpan(at), "A member initializer in a enum declaration cannot reference members declared after it, including members defined in other enums.", .{});
                }
            }
            return Const{ .num = 0 };
        }
    }
    return null;
}

/// `E.M` where `E` names an enum. Null when the qualifier is not an enum, so
/// the caller can try the namespace-container reading of the same syntax.
fn evalEnumQualified(c: *Checker, qual: Node, name: Atom, out: *std.ArrayList(u8), es: EnumScope, at: Node) Error!?Const {
    // ztsc's own cycle cap, not a fact about the code: `.deep`, so a chain
    // of enum references longer than this stays SILENT instead of earning a
    // false TS1061/TS2474.
    if (c.enum_alias_depth >= 8) return Const.deep;
    c.enum_alias_depth += 1;
    defer c.enum_alias_depth -= 1;
    const saved_scope = c.cur_scope;
    defer c.cur_scope = saved_scope;
    const esym = (try c.enumSymOfQualifier(qual)) orelse return null;
    // A member of the enum being walked: answer from the members evaluated so
    // far rather than re-entering the walk.
    if (es.active and esym == es.own) {
        if (es.lookup(name)) |v| return try constOfType(c, v, out);
        return (try forwardEnumMember(c, es, name, at)) orelse Const.none;
    }
    const v = (try c.enumMemberValue(esym, name)) orelse return Const.none;
    return try constOfType(c, v, out);
}

/// Fold a name that has already been resolved to a symbol.
fn evalConstSym(c: *Checker, sym0: SymbolId, out: *std.ArrayList(u8), depth: u16) Error!Const {
    var sym = sym0;
    // Follow import aliases to the declaration that carries the initializer
    // (tsc's `resolveEntityName` resolves through aliases before the test).
    var hops: u8 = 0;
    while (c.symFlags(sym).import_binding) : (hops += 1) {
        if (hops >= 8) return .deep;
        const tgt = c.importTarget(sym) orelse return .none;
        if (tgt.kind != .binding) return .none;
        sym = c.toGlobalIn(tgt.file, tgt.payload);
    }
    if (c.symFlags(sym).enum_member) {
        if (c.enum_alias_depth >= 8) return .deep;
        c.enum_alias_depth += 1;
        defer c.enum_alias_depth -= 1;
        const esym = enumOfMemberSym(c, sym) orelse return .none;
        const v = (try c.enumMemberValue(esym, c.symNameAtom(sym))) orelse return .none;
        return constOfType(c, v, out);
    }
    if (!c.symFlags(sym).const_decl) return .none;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return .none;
    const decl = decls[0];
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = c.symScope(sym);
    // `declarator_init` is exactly `!declaration.type && declaration.initializer`
    // with a plain name — a `declarator_full` carries an annotation (or is a
    // pattern), which tsc refuses to fold.
    if (c.nodeTag(decl) != .declarator_init) return .none;
    const dd = c.tree.nodeData(decl);
    if (c.nodeTag(dd.lhs) != .identifier) return .none;
    return evalConst(c, dd.rhs, out, .{}, depth + 1);
}

/// The folded string value of a template expression, or null when it is not a
/// compile-time constant.
pub fn constTemplateAtom(c: *Checker, node: Node) Error!?Atom {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(c.scratch());
    switch (try evalConst(c, node, &out, .{}, 0)) {
        .none, .deep => return null,
        .num => |v| try appendNumber(c, &out, v),
        .str => {},
    }
    // `internText`, NOT `atom`: the folded value lives in a scratch buffer that
    // is freed on return, and `atom_cache` keeps its KEY as the caller's slice.
    // Caching it leaves a dangling key that the next rehash walks — a
    // segfault whose crash site is wherever the map happens to grow, which is
    // why this reproduced only on excalidraw at `--checkers=2`.
    return try c.internText(out.items);
}

/// The constant value of one enum member initializer, in the middle of a walk
/// over the enum's members. `.computed` is tsc's `undefined` — the member has
/// no constant value, which is what makes a FOLLOWING bare member TS1061 and
/// (in an ambient or `const` enum) makes this initializer itself an error.
const EnumInitValue = struct { kind: EnumInitKind, num: f64 = 0, str: Atom = 0 };

fn evalEnumInit(c: *Checker, es: EnumScope, init_node: Node) Error!EnumInitValue {
    // The three literal shapes carry their value in a token, so the common
    // case never touches the string buffer (or interns a second copy of an
    // atom the scanner already made).
    const tok = c.tree.nodeMainToken(init_node);
    switch (c.nodeTag(init_node)) {
        .number_literal => return .{ .kind = .numeric, .num = c.numberTokenValue(tok) },
        .string_literal => return .{ .kind = .string, .str = try c.memberAtom(tok) },
        .template_literal => return .{ .kind = .string, .str = try c.templateAtom(tok) },
        else => {},
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(c.scratch());
    return switch (try evalConst(c, init_node, &out, es, 0)) {
        .none => .{ .kind = .computed },
        .deep => .{ .kind = .capped },
        .num => |v| .{ .kind = .numeric, .num = v },
        // `internText`, not `atom` — see `constTemplateAtom`.
        .str => .{ .kind = .string, .str = try c.internText(out.items) },
    };
}

/// The scope a member initializer resolves names in: the enum's own body
/// scope, where `bindEnum` put the members, so a bare `A` names the member
/// and shadows an outer `A` (tsc's `resolveName` case for an
/// EnumDeclaration location). The caller must already be in the enum's file.
fn enumBodyScope(c: *Checker, sym: SymbolId) binder.ScopeId {
    return c.bind.enumScopeOf(c.localOf(sym)) orelse binder.file_scope;
}

/// Const-ness, string/numeric nature, and numeric member values of an
/// enum symbol (all declaration blocks merged). Pure computation, cached.
pub fn enumInfo(c: *Checker, sym: SymbolId) Error!EnumInfo {
    if (c.enum_info_cache.get(sym)) |info| return info;
    const members = try enumMembersOf(c, sym);
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(c.scratch());
    var has_string = false;
    var has_computed = false;
    for (members) |m| {
        if (m.computed) has_computed = true;
        if (m.value == types.no_type) continue;
        switch (c.ts.kind(m.value)) {
            .string_literal => has_string = true,
            .number_literal, .number_literal_fresh => try values.append(c.scratch(), c.ts.numberValue(m.value)),
            else => {},
        }
    }
    var is_const = false;
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        if (data.flags & ast.Flags.const_enum != 0) is_const = true;
    }
    const info: EnumInfo = .{
        .is_const = is_const,
        .all_string = has_string and !has_computed and values.items.len == 0 and members.len > 0,
        .all_numeric = !has_string,
        .has_computed = has_computed,
        .values = try c.ca().dupe(f64, values.items),
    };
    try c.enum_info_cache.put(c.cm(), sym, info);
    return info;
}

/// Evaluate every member of an enum symbol (all declaration blocks merged) in
/// declaration order. The one place the auto-increment rules live: a member
/// with no initializer continues the previous member's number, and the chain
/// restarts at 0 in each declaration BLOCK — tsc's `computeEnumMemberValues`
/// runs per `EnumDeclaration` with `autoValue = 0`, which is why
/// `enum E { A = "x".length }` followed by `enum E { B }` is not an error.
fn evalEnumMembers(c: *Checker, sym: SymbolId, out: *std.ArrayList(checker_zig.EnumMemberEntry)) Error!void {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    c.cur_scope = enumBodyScope(c, sym);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        var auto: f64 = 0;
        var auto_ok = true;
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m == null_node or c.nodeTag(m) != .enum_member) continue;
            const name = try c.memberAtom(c.tree.nodeMainToken(m));
            const init_node = c.tree.nodeData(m).lhs;
            var entry: checker_zig.EnumMemberEntry = .{ .name = name, .value = types.no_type };
            if (init_node == null_node) {
                if (auto_ok) {
                    entry.value = try c.ts.makeNumberLiteral(auto, false);
                    auto += 1;
                }
            } else {
                const es: EnumScope = .{ .active = true, .own = sym, .seen = out.items };
                const ci = try evalEnumInit(c, es, init_node);
                switch (ci.kind) {
                    .numeric => {
                        entry.value = try c.ts.makeNumberLiteral(ci.num, false);
                        auto = ci.num + 1;
                        auto_ok = true;
                    },
                    .string => {
                        entry.value = try c.ts.makeStringLiteral(ci.str, false);
                        auto_ok = false;
                    },
                    .computed => {
                        entry.computed = true;
                        auto_ok = false;
                    },
                    // ztsc gave up, tsc did not: the member has no value here
                    // and the diagnostics must not fire on it (`computed`
                    // stays false), and the auto-increment chain carries on so
                    // a following bare member does not earn a false TS1061
                    // either. Both are under-reports, which is the only
                    // direction a cap of ours is allowed to move.
                    .capped => {},
                }
            }
            try out.append(c.ca(), entry);
        }
    }
}

/// Walk every member of an enum symbol in declaration order, handing the
/// callback each member's name atom and the literal type of its constant
/// value — `no_type` when the value is computed (or when auto-increment ran
/// off a string/computed member, so the number is unknowable).
pub fn eachEnumMember(
    c: *Checker,
    sym: SymbolId,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), Atom, TypeId) Error!void,
) Error!void {
    for (try enumMembersOf(c, sym)) |m| try f(ctx, m.name, m.value);
}

/// The evaluated members of one enum, memoized under its symbol — see
/// `Checker.enum_members`. Every consumer goes through here, so an enum's
/// declaration is read once per checker instead of once per question.
///
/// The list is published only after the walk completes, so a re-entrant
/// request for the SAME enum (a cross-enum reference cycle) falls through to
/// a second walk, and the depth cap in `enum_alias_depth` still bounds it.
pub fn enumMembersOf(c: *Checker, sym: SymbolId) Error![]const checker_zig.EnumMemberEntry {
    if (c.enum_members.get(sym)) |m| return m;
    var list: std.ArrayList(checker_zig.EnumMemberEntry) = .empty;
    try evalEnumMembers(c, sym, &list);
    const out = list.items;
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

/// Whether an enum has any string-valued member. A string enum is stringish;
/// an all-numeric enum is numberish — this lets numeric enums take part in
/// arithmetic/comparison like `number`. Infallible so the two `expr.zig`
/// union predicates can call it from a non-`Error` closure; the only failure
/// `enumInfo` has is OOM, which every caller here would report as "numeric".
pub fn enumHasStringMember(c: *Checker, sym: SymbolId) bool {
    const info = enumInfo(c, sym) catch return false;
    return !info.all_numeric;
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
    // A NUMERIC enum reverse-maps: `E[0]` is `"A"` at runtime, and tsc gives
    // the value object a `[n: number]: string` signature to say so (its shared
    // `enumNumberIndexInfo`). Without it `E[1]` was a TS7053 where tsc answers
    // `string` — which is also why `++(ENUM[1] + ENUM[2])` reported TS2357
    // (a bad assignment target) instead of tsc's TS2356 (a bad arithmetic
    // operand) in `incrementOperatorWithEnumTypeInvalidOperations`.
    //
    // tsc's gate is "the declared type is a bare enum, or some member is
    // number-like" — i.e. everything except an enum whose every member is a
    // string constant, which is exactly `EnumInfo.all_string`. An EMPTY enum
    // is included (its declared type is the bare `Enum`), verified against the
    // oracle. The flag keeps the signature out of `keyof`; see there.
    const numeric = !(try enumInfo(c, sym)).all_string;
    const result = if (numeric)
        try c.ts.makeObject(props.items, 0, types.string_type, types.obj_flag_enum_index)
    else
        try c.ts.makeObject(props.items, 0, 0, 0);
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
    for (try enumMembersOf(c, sym)) |m| {
        if (m.value == types.no_type or c.ts.kind(m.value) != .string_literal) continue;
        if (c.ts.literalAtom(m.value) == val) return true;
    }
    return false;
}

/// Is every initialized member of enum `sym` string-valued? A STRING enum is
/// the nominal shape the assertion check has a special rule for (see
/// `stringEnumCastOverlap`); a numeric or mixed enum keeps the ordinary
/// numeric-literal comparability and must not take it.
pub fn enumIsStringValued(c: *Checker, sym: SymbolId) Error!bool {
    const members = try enumMembersOf(c, sym);
    for (members) |m| {
        // An uninitialized member is auto-numbered, and a computed one has no
        // value at all: neither makes the enum string-valued.
        if (m.value == types.no_type or c.ts.kind(m.value) != .string_literal) return false;
    }
    return members.len > 0;
}

/// The index into `enumMembersOf(sym)` at which declaration block `node`'s
/// own members begin — the walk concatenates every block in declaration
/// order, so this is just the count of members in the blocks before it.
fn enumBlockBase(c: *Checker, sym: SymbolId, node: Node) usize {
    var base: usize = 0;
    for (c.declsOf(sym)) |decl| {
        if (decl == node) break;
        if (c.nodeTag(decl) != .enum_decl) continue;
        const data = c.tree.extraData(ast.EnumData, c.tree.nodeData(decl).lhs);
        for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
            if (m != null_node and c.nodeTag(m) == .enum_member) base += 1;
        }
    }
    return base;
}

/// Type-check an enum declaration: check the initializer expressions, and
/// report tsc's `computeMemberValue`/`computeConstantValue` diagnostics for
/// members the constant evaluator could not fold — TS1061 (a bare member with
/// no numeric chain to continue), TS1066 (an ambient enum), TS2474 (a `const`
/// enum), TS2477/TS2478 (a `const` enum member folded to Infinity/NaN).
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
    var esym: SymbolId = binder.no_symbol;
    if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(c.cur_scope, a)) |local| {
            if (c.bind.enumScopeOf(local)) |s| c.cur_scope = s;
            esym = c.toGlobal(local);
        }
    }
    const is_const = data.flags & ast.Flags.const_enum != 0;
    // tsc's `NodeFlags.Ambient`: `declare enum`, or any enum inside a `.d.ts`
    // or a `declare namespace` body — which is what `ambient_ctx` tracks.
    const ambient = c.ambient_ctx or data.flags & ast.Flags.declare != 0;
    const empty: []const checker_zig.EnumMemberEntry = &.{};
    const members = if (esym != binder.no_symbol) try enumMembersOf(c, esym) else empty;
    const base = if (esym != binder.no_symbol) enumBlockBase(c, esym, node) else 0;

    var i: usize = 0;
    for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
        if (m == null_node or c.nodeTag(m) != .enum_member) continue;
        const entry: checker_zig.EnumMemberEntry = if (base + i < members.len)
            members[base + i]
        else
            .{ .name = 0, .value = types.no_type };
        const value = entry.value;
        i += 1;
        const init_node = c.tree.nodeData(m).lhs;
        if (init_node == null_node) {
            // In an ambient NON-const enum a member with no initializer is a
            // computed member, not an auto-increment: tsc answers `undefined`
            // before it ever consults the running value, so there is no
            // TS1061 to report however the chain before it ended.
            if (ambient and !is_const) continue;
            if (value == types.no_type) {
                try c.diagFmt(1061, c.tokSpan(c.tree.nodeMainToken(m)), "Enum member must have initializer.", .{});
            }
            continue;
        }
        const init_t = try c.checkExprCached(init_node, types.no_type);
        // TS2651. The memoized member walk already RESOLVES forward references
        // (`forwardEnumMember`), but it may be entered from anywhere and must
        // stay silent, so the diagnostic comes from a second, throwaway run of
        // the same evaluator over this one initializer — same traversal, same
        // "members evaluated so far" scope, `report` on.
        if (esym != binder.no_symbol and base + i <= members.len) {
            var probe: std.ArrayList(u8) = .empty;
            defer probe.deinit(c.scratch());
            const es: EnumScope = .{
                .active = true,
                .own = esym,
                .seen = members[0 .. base + i - 1],
                .report = true,
                .self = m,
            };
            _ = try evalConst(c, init_node, &probe, es, 0);
        }
        if (value != types.no_type) {
            // A `const` enum inlines its members at every use, so a value
            // that is not a finite number has nothing to inline.
            if (is_const and c.ts.kind(value) != .string_literal) {
                const n = c.ts.numberValue(value);
                if (std.math.isNan(n)) {
                    try c.diagFmt(2478, c.nodeSpan(init_node), "'const' enum member initializer was evaluated to disallowed value 'NaN'.", .{});
                } else if (!std.math.isFinite(n)) {
                    try c.diagFmt(2477, c.nodeSpan(init_node), "'const' enum member initializer was evaluated to a non-finite value.", .{});
                }
            }
            continue;
        }
        // No value AND not tsc's "computed": the evaluator hit one of ztsc's
        // own caps (`Const.deep`). tsc has no such answer, so neither do we.
        if (!entry.computed) continue;
        if (is_const) {
            try c.diagFmt(2474, c.nodeSpan(init_node), "const enum member initializers must be constant expressions.", .{});
        } else if (ambient) {
            try c.diagFmt(1066, c.nodeSpan(init_node), "In ambient enum declarations member initializer must be constant expression.", .{});
        } else if (!try c.isAssignable(init_t, types.number_type)) {
            // A computed member of a plain enum is legal, but its VALUE still
            // has to be a number — tsc's last arm of `computeConstantValue`,
            // `checkTypeAssignableTo(checkExpression(initializer),
            // numberType, initializer, ...)` with its own head message. The
            // derivation chain under it is the ordinary assignability one.
            const chain = try elaborate.chainText(c, init_t, types.number_type);
            try c.diagFmt(18033, c.nodeSpan(init_node), "Type '{s}' is not assignable to type '{s}' as required for computed enum member values.{s}", .{
                try c.typeToString(init_t), try c.typeToString(types.number_type), chain,
            });
        }
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
pub const seedStaticFieldContext = statics.seedStaticFieldContext;
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
