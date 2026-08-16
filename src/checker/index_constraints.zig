//! The DECLARATION-side index-signature checks — tsc's `checkIndexConstraints`.
//!
//! An index signature is a promise about every member of the type that carries
//! it, so a declaration that writes both `[k: string]: number` and `y: string`
//! has contradicted itself. tsc reports that at the declaration
//! (`checkClassLikeDeclaration` and `checkInterfaceDeclaration` both call
//! `checkIndexConstraints`), which is the one place the contradiction is
//! visible at all: every *use* of the type reads a consistent-looking member.
//!
//! Two diagnostics come out of it:
//!
//!   * **TS2411**, `checkIndexConstraintForProperty` — a PROPERTY's type is not
//!     assignable to an applicable index signature's type;
//!   * **TS2413**, `checkIndexConstraintForIndexSignature` — one INDEX
//!     SIGNATURE's type is not assignable to another applicable one's. With the
//!     two key domains ztsc models that is exactly one pair: a numeric key also
//!     reads the string index, so `[n: number]: T` must satisfy
//!     `[s: string]: U`.
//!
//! **Which index signatures apply to a name** is tsc's `getApplicableIndexInfos`
//! / `isApplicableIndexType`, and it is not simply "the one keyed by the name's
//! kind": a numeric name reads the string index too. So
//!
//!   * an ordinary name is judged against the STRING index only;
//!   * a name that *spells a number* (`isNumericIndexName`) is judged against
//!     both the NUMBER and the STRING index;
//!   * a symbol name is judged against the SYMBOL index only.
//!
//! **Where the diagnostic goes** is the subtle half, and it is what stops the
//! same contradiction from being reported once per inheriting declaration.
//! tsc's `errorNode` is, in order: the property's own declaration when this
//! declaration is the one that writes it; else the applicable index signature's
//! declaration when this declaration writes THAT; else — for an interface only
//! — the interface name, and then only when no single base already had both the
//! property and the index signature and could have reported it itself. When
//! none of the three applies, nothing is reported here: the contradiction
//! belongs to a base, which reported it at its own declaration.
//!
//! COST. Every entry point screens on "does the resolved type carry an index
//! signature at all" (three words off the interned object) and returns
//! immediately when it does not, which is the overwhelming majority of classes
//! and interfaces. The class walk and the interface walk both resolve the type
//! anyway — `checkClass` expands the instance type eagerly and
//! `checkInterfaceDecl` calls `interfaceGeneric` — so a type with no index
//! signature pays one load and one branch. Only past that screen is any
//! syntax walked or any relation run.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const modules = @import("../link/modules.zig");
const numeric_lit = @import("../numeric_lit.zig");
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const FileId = modules.FileId;
const Node = ast.Node;
const null_node = ast.null_node;
const Span = source.Span;
const SymbolId = binder.SymbolId;
const TokenIndex = ast.TokenIndex;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// The key domain an index signature is written with — tsc's `info.keyType`,
/// which is also how the diagnostic names it.
const Slot = enum {
    number,
    string,
    symbol,

    fn text(s: Slot) []const u8 {
        return switch (s) {
            .number => "number",
            .string => "string",
            .symbol => "symbol",
        };
    }
};

/// The index signatures a resolved object carries, by key domain. 0 = none.
///
/// ztsc keeps a SYMBOL index in the string-index slot (`obj_flag_symbol_index`
/// records which of the two it is), so reading them apart is this one branch
/// rather than a shape every consumer would have to know about.
const Infos = struct {
    number: TypeId = 0,
    string: TypeId = 0,
    symbol: TypeId = 0,

    fn of(c: *const Checker, obj: TypeId) Infos {
        const s = c.ts.objectStringIndex(obj);
        if (c.ts.objectFlags(obj) & types.obj_flag_symbol_index != 0) return .{ .symbol = s };
        return .{ .string = s, .number = c.ts.objectNumberIndex(obj) };
    }

    fn get(i: Infos, slot: Slot) TypeId {
        return switch (slot) {
            .number => i.number,
            .string => i.string,
            .symbol => i.symbol,
        };
    }

    fn none(i: Infos) bool {
        return i.number == 0 and i.string == 0 and i.symbol == 0;
    }
};

/// Where a diagnostic about one own declaration goes. The FILE travels with the
/// span because a merged interface's blocks need not share one: `interface A`
/// in one file and `interface A` in another are both "own" declarations of the
/// same type, and each reports in its own file.
const Site = struct { file: FileId, span: Span };

/// What THIS declaration writes itself — tsc's `localPropDeclaration` and
/// `localIndexDeclaration`, gathered from syntax in one pass so the property
/// walk can answer both questions by lookup.
const Own = struct {
    /// Member name → the site of its FIRST own declaration (tsc reports on
    /// `prop.valueDeclaration`, and an overloaded method's is its first).
    props: std.AutoHashMapUnmanaged(Atom, Site) = .empty,
    /// Index-signature sites by key domain.
    number: ?Site = null,
    string: ?Site = null,
    symbol: ?Site = null,

    fn idx(o: Own, slot: Slot) ?Site {
        return switch (slot) {
            .number => o.number,
            .string => o.string,
            .symbol => o.symbol,
        };
    }

    fn setIdx(o: *Own, slot: Slot, site: Site) void {
        const p = switch (slot) {
            .number => &o.number,
            .string => &o.string,
            .symbol => &o.symbol,
        };
        if (p.* == null) p.* = site;
    }

    fn deinit(o: *Own, alloc: std.mem.Allocator) void {
        o.props.deinit(alloc);
    }
};

/// tsc's third `errorNode` candidate: an INTERFACE may be blamed at its own
/// name for a contradiction between two things it merely inherited — but only
/// when no single base type had both halves and could be blamed instead.
const IfaceFallback = struct {
    site: Site,
    bases: []const TypeId,
};

// ------------------------------------------------------------------ entry

/// tsc's `checkIndexConstraints(type, symbol)` +
/// `checkIndexConstraints(staticType, symbol, /*isStaticIndex*/ true)` for a
/// class. `instance` is the class's `this` type as `checkClass` built it;
/// `statics` its `classStaticType`. A class is never the interface fallback
/// case (`ObjectFlags.Interface` is not set on a class instance type), so a
/// contradiction it only inherited is the BASE's diagnostic, not its.
pub fn checkClassIndexConstraints(
    c: *Checker,
    node: Node,
    class_sym: SymbolId,
    instance: TypeId,
    statics: TypeId,
) Error!void {
    for ([2]bool{ false, true }) |is_static| {
        const t = try c.resolveStructural(if (is_static) statics else instance);
        if (c.ts.kind(t) != .object) continue;
        const infos = Infos.of(c, t);
        if (infos.none()) continue;
        var own: Own = .{};
        defer own.deinit(c.scratch());
        try gatherClassMembers(c, node, is_static, &own);
        // A class merged with a same-named `interface` (or reopened in another
        // file) declares members in those blocks too, and they are just as
        // local to the type as the class body's.
        if (!is_static) try gatherInterfaceBlocks(c, class_sym, &own);
        try checkOne(c, t, own, null);
    }
}

/// tsc's `checkIndexConstraints(type, symbol)` for an interface, run — as tsc
/// runs it — only from the symbol's FIRST `interface` block: the type is the
/// merge of every block, and so is its single verdict.
pub fn checkInterfaceIndexConstraints(
    c: *Checker,
    sym: SymbolId,
    node: Node,
    name_token: TokenIndex,
) Error!void {
    if (name_token == 0) return;
    if (!isFirstInterfaceDecl(c, sym, node)) return;
    const self = try c.interfaceGeneric(sym);
    if (self == types.error_type) return;
    const t = try c.resolveStructural(self);
    if (c.ts.kind(t) != .object) return;
    const infos = Infos.of(c, t);
    if (infos.none()) return;

    var own: Own = .{};
    defer own.deinit(c.scratch());
    try gatherInterfaceBlocks(c, sym, &own);
    // A merged `class C {} interface C {}` reaches here through the interface
    // half too; the class body's members are own declarations of the same type.
    if (c.symFlags(sym).class) {
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .class_decl) continue;
            const saved = c.enterSymFile(sym);
            defer c.restoreCtx(saved);
            try gatherClassMembers(c, decl, false, &own);
        }
    }

    var bases: std.ArrayList(TypeId) = .empty;
    defer bases.deinit(c.scratch());
    {
        // `interfaceHeritageTypes` resolves each clause in the declaring
        // block's own file and scope, so it sets both and this restores them.
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        if (c.symFlags(sym).class) {
            if (try c.baseClassRef(sym)) |b| try bases.append(c.scratch(), b);
        }
        try c.interfaceHeritageTypes(sym, &bases);
    }
    try checkOne(c, t, own, .{
        .site = .{ .file = c.cur_file, .span = c.tokSpan(name_token) },
        .bases = bases.items,
    });
}

// ------------------------------------------------------------------ the check

fn checkOne(c: *Checker, obj: TypeId, own: Own, fallback: ?IfaceFallback) Error!void {
    const infos = Infos.of(c, obj);
    for (0..c.ts.objectPropCount(obj)) |i| {
        const p = c.ts.objectProp(obj, @intCast(i));
        const text = c.atomText(p.name);
        // tsc's `if (name && isPrivateIdentifier(name)) return;` — a `#x` is
        // not reachable through any index signature, so no index signature
        // constrains it.
        if (text.len != 0 and text[0] == '#') continue;
        for (applicableSlots(text)) |slot| {
            const idx_ty = infos.get(slot);
            if (idx_ty == 0) continue;
            const site = try errorSite(c, own, fallback, p.name, slot) orelse continue;
            if (try c.isAssignable(p.ty, idx_ty)) continue;
            try file(c, site, 2411, "Property '{s}' of type '{s}' is not assignable to '{s}' index type '{s}'.", .{
                text, try c.typeToString(p.ty), slot.text(), try c.typeToString(idx_ty),
            });
        }
    }
    // tsc's `if (indexInfos.length > 1)` arm. `getApplicableIndexInfos(type,
    // numberType)` is `[number, string]` and the string key's is `[string]`
    // alone, so the number index is the only one with anything to satisfy.
    if (infos.number != 0 and infos.string != 0) {
        if (try indexErrorSite(c, own, fallback)) |site| {
            if (!try c.isAssignable(infos.number, infos.string)) {
                try file(c, site, 2413, "'number' index type '{s}' is not assignable to 'string' index type '{s}'.", .{
                    try c.typeToString(infos.number), try c.typeToString(infos.string),
                });
            }
        }
    }
}

/// tsc's `getApplicableIndexInfos(type, getLiteralTypeFromProperty(prop))`,
/// as the key domains a member of this name can be read through. Returned in
/// tsc's usual declaration order for the pair a two-domain model can produce
/// (`[x: number]` before `[x: string]`, as `derivedInterfaceIncompatibleWith
/// BaseIndexer` writes them).
fn applicableSlots(name: []const u8) []const Slot {
    // A computed symbol name — the binder's `__@<name>` key. Only a `[k:
    // symbol]` index reads it: a `unique symbol` is assignable to neither
    // `string` nor `number`.
    if (std.mem.startsWith(u8, name, "__@")) return &.{.symbol};
    if (isNumericIndexName(name)) return &.{ .number, .string };
    return &.{.string};
}

/// tsc's `errorNode` for one (property, index signature) pair. Null = this
/// declaration is not the one to blame; some base is, and reported it there.
fn errorSite(c: *Checker, own: Own, fallback: ?IfaceFallback, name: Atom, slot: Slot) Error!?Site {
    if (own.props.get(name)) |s| return s;
    if (own.idx(slot)) |s| return s;
    const f = fallback orelse return null;
    for (f.bases) |base| {
        const b = try c.resolveStructural(base);
        if (c.ts.kind(b) != .object) continue;
        if (Infos.of(c, b).get(slot) == 0) continue;
        if (try c.propOfTypeEx(b, name, false) != null) return null;
    }
    return f.site;
}

/// The same choice for the index-signature-against-index-signature pair, whose
/// base screen asks for BOTH index signatures rather than a property and one.
fn indexErrorSite(c: *Checker, own: Own, fallback: ?IfaceFallback) Error!?Site {
    if (own.number) |s| return s;
    if (own.string) |s| return s;
    const f = fallback orelse return null;
    for (f.bases) |base| {
        const b = try c.resolveStructural(base);
        if (c.ts.kind(b) != .object) continue;
        const bi = Infos.of(c, b);
        if (bi.number != 0 and bi.string != 0) return null;
    }
    return f.site;
}

/// tsc's `isValidNumberString(s, /*roundTripOnly*/ true)`: does this name spell
/// the number it denotes, so that reading the member by that number and by that
/// string are the same read?
///
/// Deliberately NOT `literals.isNumericName`, which answers the *enum member
/// name* question and rejects the non-finite spellings to match tsgo's TS2452.
/// Here tsgo accepts them: `Infinity`, `-Infinity` and `NaN` are all reported
/// against a number index signature (`propertiesAndIndexersForNumericNames`).
fn isNumericIndexName(text: []const u8) bool {
    if (text.len == 0 or text.len > numeric_lit.max_name) return false;
    var buf: [numeric_lit.max_name]u8 = undefined;
    return std.mem.eql(u8, jsNumberText(&buf, numeric_lit.value(text)), text);
}

/// `String(v)` as JavaScript spells it. `numeric_lit.write` is the POSITIONAL
/// half of that spelling and the only half any other caller needs (a numeric
/// property name in real code is a small integer); the round-trip test above
/// needs the whole rule, because the names it must REJECT are exactly the ones
/// written in the other form (`"0.000000000000000000012"` denotes `1.2e-20`,
/// which JavaScript — and so tsc's index-signature applicability — spells
/// `"1.2e-20"`, so the long form names no numeric key).
///
/// The switch is on magnitude: positional for `1e-6 <= |v| < 1e21`, exponential
/// outside it, with a POSITIVE exponent spelled `e+21` where Zig's `{e}` writes
/// `e21`. Empty (a mismatch, so a rejection) for anything that overruns `buf`.
fn jsNumberText(buf: *[numeric_lit.max_name]u8, v: f64) []const u8 {
    const a = @abs(v);
    if (std.math.isNan(v) or std.math.isInf(v) or v == 0 or (a >= 1e-6 and a < 1e21)) {
        var w = std.Io.Writer.fixed(buf);
        numeric_lit.write(&w, v) catch return "";
        return w.buffered();
    }
    var tmp: [numeric_lit.max_name]u8 = undefined;
    const e = std.fmt.bufPrint(&tmp, "{e}", .{v}) catch return "";
    const at = std.mem.indexOfScalar(u8, e, 'e') orelse return "";
    if (at + 1 < e.len and e[at + 1] == '-') {
        if (e.len > buf.len) return "";
        @memcpy(buf[0..e.len], e);
        return buf[0..e.len];
    }
    if (e.len + 1 > buf.len) return "";
    @memcpy(buf[0 .. at + 1], e[0 .. at + 1]);
    buf[at + 1] = '+';
    @memcpy(buf[at + 2 .. e.len + 1], e[at + 1 ..]);
    return buf[0 .. e.len + 1];
}

/// File one diagnostic at a site that may belong to another file (a merged
/// interface's other block). `diagFmt` keys its dedupe on `c.cur_file`, and the
/// queue attributes the diagnostic to it, so the file has to be current.
fn file(c: *Checker, site: Site, code: u16, comptime fmt: []const u8, args: anytype) Error!void {
    if (site.file == c.cur_file) return c.diagFmt(code, site.span, fmt, args);
    const saved = c.saveCtx();
    defer c.restoreCtx(saved);
    c.setFile(site.file);
    try c.diagFmt(code, site.span, fmt, args);
}

// ------------------------------------------------------------------ syntax

fn gatherClassMembers(c: *Checker, node: Node, statics: bool, out: *Own) Error!void {
    if (c.nodeTag(node) != .class_decl) return;
    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(node).lhs);
    for (c.tree.extraRange(data.members_start, data.members_end)) |m| {
        if (m == null_node) continue;
        const md = c.tree.nodeData(m);
        const tag = c.nodeTag(m);
        switch (tag) {
            .class_field, .class_method => {
                const flags: u32 = if (tag == .class_field)
                    c.tree.extraData(ast.Field, md.lhs).flags
                else
                    c.tree.extraData(ast.FnProto, md.lhs).flags;
                if ((flags & ast.Flags.static != 0) != statics) continue;
                const tok = c.tree.nodeMainToken(m);
                const name = try c.memberKey(tok, flags);
                if (c.isCtorName(name)) continue;
                try addProp(c, out, name, tok);
            },
            .index_signature => {
                if ((md.rhs & ast.Flags.static != 0) != statics) continue;
                try addIndex(c, out, m, md.lhs);
            },
            // A decorator, a static block, a `;` — none of them names a member.
            else => {},
        }
    }
}

fn gatherInterfaceBlocks(c: *Checker, sym: SymbolId, out: *Own) Error!void {
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
                    try addProp(c, out, try c.memberKey(tok, md.rhs), tok);
                },
                .index_signature => try addIndex(c, out, m, md.lhs),
                // Call and construct signatures name no member.
                else => {},
            }
        }
    }
}

fn addProp(c: *Checker, out: *Own, name: Atom, tok: TokenIndex) Error!void {
    const gop = try out.props.getOrPut(c.scratch(), name);
    if (!gop.found_existing) gop.value_ptr.* = .{ .file = c.cur_file, .span = c.tokSpan(tok) };
}

fn addIndex(c: *Checker, out: *Own, node: Node, extra: ast.ExtraIndex) Error!void {
    const e = c.tree.extraData(ast.IndexSig, extra);
    const key = try c.typeFromTypeNode(e.key_type);
    const slot: Slot = if (key == types.number_type)
        .number
    else if (key == types.symbol_type)
        .symbol
    else if (key == types.string_type)
        .string
    else
        // A template-literal or union key domain, which ztsc does not model as
        // an index signature at all — nothing here can be said about it.
        return;
    out.setIdx(slot, .{ .file = c.cur_file, .span = c.nodeSpan(node) });
}

/// tsc's `getDeclarationOfKind(symbol, SyntaxKind.InterfaceDeclaration)`: is
/// `node` the symbol's FIRST `interface` block? The merged type has one
/// verdict, and re-deciding it in every reopened block would report it once
/// per block.
fn isFirstInterfaceDecl(c: *Checker, sym: SymbolId, node: Node) bool {
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .interface_decl) continue;
        return decl == node;
    }
    return false;
}

test "a numeric index signature judges the names that spell their own number" {
    const t = std.testing;
    for ([_][]const u8{ "0", "1", "-1", "-2.5", "3.141592", "1.2e-20", "1e+21", "100000000000000000000", "0.000001", "Infinity", "-Infinity", "NaN" }) |s| {
        try t.expect(isNumericIndexName(s));
    }
    for ([_][]const u8{ "", " 1", "1 ", "1 0 1", "hunter2", "+Infinity", "+NaN", "-NaN", "+1", "1e0", "-0", "-0e0", "0xF00D", "0123", "0o123", "0b101101001010", "0.000000000000000000012", "1e21", "0.0000001", "1000000000000000000000" }) |s| {
        try t.expect(!isNumericIndexName(s));
    }
}
