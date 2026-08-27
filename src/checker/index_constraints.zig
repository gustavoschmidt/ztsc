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
const index_signature = @import("../frontend/index_signature.zig");
const intern = @import("../intern.zig");
const member_names = @import("../frontend/member_names.zig");
const modules = @import("../link/modules.zig");
const numeric_lit = @import("../numeric_lit.zig");
const scanner = @import("../frontend/scanner.zig");
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
    /// The declared KEY type of the string-slot index signature when it is a
    /// template-literal pattern rather than plain `string` (0 = plain). tsc's
    /// `isApplicableIndexType` gates the property check on the name being
    /// assignable to this.
    string_key: TypeId = 0,

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
    // Ahead of the index-info screen below: an index signature whose KEY TYPE
    // is illegal never becomes an index info at all, so the screen is exactly
    // where the signatures this rule exists for disappear. See `checkKeyType`.
    try checkIndexGrammar(c, classMembers(c, node));
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
    // Ahead of the index-info screen, for the reason `checkClassIndexConstraints`
    // gives: `interface Test { [index: TypeNotFound]: any }` declares no index
    // info to screen ON, which is precisely what makes it a TS1268.
    {
        const saved = c.enterSymFile(sym);
        defer c.restoreCtx(saved);
        for (c.declsOf(sym)) |decl| {
            if (c.nodeTag(decl) != .interface_decl) continue;
            const saved_scope = c.cur_scope;
            defer c.cur_scope = saved_scope;
            if (try c.scopeOf(decl)) |s| c.cur_scope = s;
            const d = c.tree.extraData(ast.InterfaceData, c.tree.nodeData(decl).lhs);
            try checkIndexGrammar(c, c.tree.extraRange(d.members_start, d.members_end));
        }
    }
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

/// tsc's `checkTypeLiteral` -> `checkIndexConstraints(type, type.symbol)`:
/// TS2411 / TS2413 for an anonymous object TYPE LITERAL, whose contradiction is
/// just as invisible at every use as an interface's.
///
/// `members` is the literal's member range as written and `obj` the type it
/// resolved to; the caller is already in the literal's file and scope, and
/// spells the members with the same node tags an interface block does.
///
/// A type literal has no heritage, so there is no interface fallback and no
/// base that could be blamed instead: every member it carries is an OWN
/// declaration and the site is always the member itself. That makes this the
/// simplest of the three entry points — no merged blocks, no static half.
///
/// `checkIndexGrammar` runs here for the reason it runs from the two entry
/// points above: the index-info screen below would otherwise hide a signature
/// that never BECAME an index info, and a key type ztsc cannot make an info
/// out of is precisely what TS1268 is about. This arm is `typeFromTypeNode`'s
/// single `.object_type` case, memoized by `(file, node)`, so a written
/// `{ [index: RegExp]; }` is judged exactly once wherever its materialization
/// starts — the same once-per-literal position TS2411 already occupies.
pub fn checkTypeLiteralIndexConstraints(c: *Checker, members: []const Node, obj: TypeId) Error!void {
    try checkIndexGrammar(c, members);
    const t = try c.resolveStructural(obj);
    if (c.ts.kind(t) != .object) return;
    const infos = Infos.of(c, t);
    if (infos.none()) return;
    var own: Own = .{};
    defer own.deinit(c.scratch());
    try gatherTypeMembers(c, members, &own);
    try checkOne(c, t, own, null);
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
            // A pattern-keyed string index only constrains names assignable
            // to the pattern (tsc's `isApplicableIndexType`).
            if (slot == .string and own.string_key != 0 and
                !try c.isAssignable(try c.ts.makeStringLiteral(p.name, false), own.string_key))
            {
                continue;
            }
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
                // The CONSTRUCTOR names no member of its own, but its
                // parameter properties do. Asked of the DECLARATION
                // (`member_names.isCtorMethod`), not of the name atom: the
                // member-table key is the reserved `__@ctor`, and this walk
                // reads syntax, where the name is the literal `constructor`.
                if (tag == .class_method and member_names.isCtorMethod(c.tree, m, flags)) {
                    if (!statics) try addParamProps(c, md.lhs, out);
                    continue;
                }
                if ((flags & ast.Flags.static != 0) != statics) continue;
                const tok = c.tree.nodeMainToken(m);
                try addProp(c, out, try c.memberKey(tok, flags), tok, flags);
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

/// The instance members a CONSTRUCTOR declares through parameter properties.
///
/// `constructor(public bad: string)` declares `bad` as surely as a field does,
/// and tsc's `localPropDeclaration` finds it the same way — through the
/// property symbol's `valueDeclaration`, which for one of these is the
/// PARAMETER. So it is an own declaration here too, and the diagnostic goes to
/// the parameter's start, which is its modifier (`main_token` on a
/// `.param_full`).
fn addParamProps(c: *Checker, proto_idx: ast.ExtraIndex, out: *Own) Error!void {
    const proto = c.tree.extraData(ast.FnProto, proto_idx);
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |p| {
        if (p == null_node or c.nodeTag(p) != .param_full) continue;
        const pd = c.tree.nodeData(p);
        const e = c.tree.extraData(ast.ParamFull, pd.rhs);
        if (e.flags & member_names.param_property_mask == 0) continue;
        // Only a plain identifier parameter names a member; a binding pattern
        // with a modifier is TS1187 and declares nothing.
        if (c.nodeTag(pd.lhs) != .identifier) continue;
        const gop = try out.props.getOrPut(c.scratch(), try c.memberAtom(c.tree.nodeMainToken(pd.lhs)));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .file = c.cur_file, .span = c.tokSpan(c.tree.nodeMainToken(p)) };
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
        try gatherTypeMembers(c, c.tree.extraRange(data.members_start, data.members_end), out);
    }
}

/// The members an interface block or a type LITERAL writes, as own
/// declarations. Both spell their members with the same node tags, and the
/// index-constraint rule cares about exactly two of them: a name (which an
/// applicable index signature constrains) and an index signature (which
/// another one may constrain). The caller supplies the file and scope.
fn gatherTypeMembers(c: *Checker, members: []const Node, out: *Own) Error!void {
    for (members) |m| {
        if (m == null_node) continue;
        const md = c.tree.nodeData(m);
        switch (c.nodeTag(m)) {
            .property_signature, .method_signature => {
                const tok = c.tree.nodeMainToken(m);
                try addProp(c, out, try c.memberKey(tok, md.rhs), tok, md.rhs);
            },
            .index_signature => try addIndex(c, out, m, md.lhs),
            // Call and construct signatures name no member.
            else => {},
        }
    }
}

fn addProp(c: *Checker, out: *Own, name: Atom, tok: TokenIndex, flags: u32) Error!void {
    const gop = try out.props.getOrPut(c.scratch(), name);
    if (!gop.found_existing) gop.value_ptr.* = .{ .file = c.cur_file, .span = nameSpan(c, tok, flags) };
}

/// tsc's `getNameOfDeclaration(prop.valueDeclaration)` as a span. A member's
/// name token is the identifier that NAMES it, which for a computed key
/// (`[Symbol.toStringTag]`, `[k]`) sits INSIDE the brackets — but tsc's name
/// node is the whole `ComputedPropertyName`, so it anchors the diagnostic at
/// the `[`, and ztsc's own member NODE starts at that inner token too.
///
/// The bracket is recovered by walking back over the key's entity name — the
/// only shape a computed key that NAMES a member can have, since the name is
/// what `memberKey` resolved (`Symbol.iterator`, or an identifier path denoting
/// a `unique symbol`). Anything else ends the walk and keeps the name token, so
/// an unanticipated spelling costs the old position rather than a wrong one.
fn nameSpan(c: *Checker, tok: TokenIndex, flags: u32) Span {
    const name_span = c.tokSpan(tok);
    if (flags & (ast.Flags.computed | ast.Flags.computed_sym) == 0) return name_span;
    var i = tok;
    while (i > 0) : (i -= 1) {
        switch (c.tree.tokens.tag(i)) {
            .l_bracket => return c.tokSpan(i),
            .identifier, .dot => {},
            else => return name_span,
        }
    }
    return name_span;
}

fn addIndex(c: *Checker, out: *Own, node: Node, extra: ast.ExtraIndex) Error!void {
    const e = c.tree.extraData(ast.IndexSig, extra);
    // tsc blames the whole DECLARATION, whose span starts at the member's
    // modifiers (`static readonly [s: number]: T` answers at the `static`).
    // `nodeSpan` starts at the `[`: the modifiers are a flag word on the node,
    // with no child to widen the span.
    const site = indexSite(c, node);
    const key = try c.typeFromTypeNode(e.key_type);
    const slot: Slot = if (key == types.number_type)
        .number
    else if (key == types.symbol_type)
        .symbol
    else if (key == types.string_type)
        .string
    else {
        // A template-literal (pattern) key domain. ztsc's type store folds it
        // into the string-index slot, but tsc's `isApplicableIndexType` only
        // applies it to member names ASSIGNABLE to the pattern
        // (`jsxNamespacedNameNotComparedToNonMatchingIndexSignature`:
        // `"ns:thing"` is not constrained by `` [key: `do-${string}`] ``).
        // Record the declared key so the property walk can ask.
        out.string_key = key;
        out.setIdx(.string, site);
        return;
    };
    out.setIdx(slot, site);
}

/// The member list of a class body, as a node range.
fn classMembers(c: *Checker, node: Node) []const Node {
    const data = c.tree.extraData(ast.ClassData, c.tree.nodeData(node).lhs);
    return c.tree.extraRange(data.members_start, data.members_end);
}

/// Run `checkKeyType` over every index signature in one member list.
///
/// Separate from the `gather*` walks because it must run BEFORE their callers'
/// index-info screen, and because it is indifferent to `static`: a grammar rule
/// about a signature's own syntax does not care which half of the type the
/// signature lands in. Costs one tag read per member on a class or interface
/// with no index signature at all, which is the overwhelming majority.
fn checkIndexGrammar(c: *Checker, members: []const Node) Error!void {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .index_signature) continue;
        const e = c.tree.extraData(ast.IndexSig, c.tree.nodeData(m).lhs);
        if (e.key_type == null_node) continue;
        try checkKeyType(c, m, e, try c.typeFromTypeNode(e.key_type));
    }
}

/// tsc's `checkGrammarIndexSignature`, the two arms of it that need the key
/// type RESOLVED:
///
/// ```ts
/// if (someType(type, t => !!(t.flags & TypeFlags.StringOrNumberLiteralOrUnique)) || isGenericType(type)) {
///     return grammarErrorOnNode(parameter.name, …literal_type_or_generic_type…);      // TS1337
/// }
/// if (!everyType(type, isValidIndexKeyType)) {
///     return grammarErrorOnNode(parameter.name, …must_be_string_number_symbol…);      // TS1268
/// }
/// ```
///
/// The rest of the chain is the parser's (`frontend/index_signature.check`),
/// which runs on the parsed SHAPE and therefore cannot see through a name:
/// `[b: AliasedBoolean]`, `[u: "foo" | 42]` and `[index: TypeNotFound]` are all
/// spellings it has to decline. It does answer for a one-token KEYWORD
/// annotation, whose verdict needs no resolution at all — so those are exactly
/// what this skips, or the two halves would both report on `[a: boolean]`.
/// (The cost of drawing the line at "one keyword token" rather than at the
/// parser's keyword LIST is `[k: true]`, whose TS1337 stays the under-report
/// the parser's own comment already records it as. A list copied to a second
/// file would drift; this cannot.)
///
/// Both arms are POSITIVE tests — a constituent must be recognizably a literal
/// or generic for TS1337, recognizably not a key domain for TS1268 — so a shape
/// ztsc models differently than tsc (an enum key, a deferred `keyof T`) stays
/// silent instead of manufacturing a grammar error on a legal signature.
/// Reported on the parameter NAME: `interface R { [index: RegExp]: number }`
/// answers at column 16, the `index`, not at the `[`.
fn checkKeyType(c: *Checker, node: Node, e: ast.IndexSig, key: TypeId) Error!void {
    if (e.name_token == 0 or e.key_type == null_node) return;
    if (!isPlainOneParamSignature(c, node, e)) return;
    if (isOneKeywordToken(c, e.key_type)) return;
    const span = c.tokSpan(e.name_token);
    const resolved = try c.resolveStructural(key);
    const members: []const TypeId = if (c.ts.kind(resolved) == .union_type)
        c.ts.members(resolved)
    else
        &.{resolved};
    for (members) |m| {
        if (isLiteralOrGenericKey(c, m)) {
            try c.diagFmt(1337, span, "An index signature parameter type cannot be a literal type " ++
                "or generic type. Consider using a mapped object type instead.", .{});
            return;
        }
    }
    for (members) |m| {
        if (isInvalidKeyType(c, m)) {
            try c.diagFmt(1268, span, "An index signature parameter type must be 'string', " ++
                "'number', 'symbol', or a template literal type.", .{});
            return;
        }
    }
    // The chain's last arm, TS1021 ("must have a type annotation"), belongs
    // here too — the parser has to decline it for a key it cannot vouch for,
    // since answering it for `[key: Key]` would have been wrong had `Key`
    // turned out to be `boolean` — but it stays an under-report
    // (`indexerConstraints2` line 80): a missing value type reaches the
    // checker as an ERROR NODE, not as `null_node`, so nothing distinguishes
    // it here from one that was written and did not resolve.
}

/// Is this signature spelled `[name: T]` exactly — one parameter, no `...`, no
/// modifier, no `?`, no initializer, nothing after the annotation but the `]`?
///
/// tsc's grammar chain `return`s at the first thing it finds wrong, and every
/// one of those arms sits AHEAD of the key-type arms this file implements — so
/// `[...p3: any[]]` answers TS1017 and is never asked what `any[]` is. The
/// parser answered all of them already (`frontend/index_signature.check`); what
/// this reproduces is not its rules but the single fact that it HAD something
/// to say, which the AST does not record. Three token comparisons and a walk to
/// the `]` do it, and a spelling they do not recognize goes silent, which is
/// the direction a grammar rule may be wrong in.
fn isPlainOneParamSignature(c: *Checker, node: Node, e: ast.IndexSig) bool {
    const tags = c.tree.tokens.tags;
    // `[` then the name: anything between them is a `...` or a modifier.
    if (e.name_token != c.tree.nodeMainToken(node) + 1) return false;
    // …then the `:`, not a `?`.
    if (e.name_token + 1 >= tags.len or tags[e.name_token + 1] != .colon) return false;
    // …then the annotation, then the `]`: a `,` (second parameter) or an `=`
    // (initializer) here is another arm's answer.
    const end = c.nodeSpan(e.key_type).end;
    var i: TokenIndex = e.name_token + 2;
    while (i < tags.len and c.tokSpan(i).start < end) i += 1;
    return i < tags.len and tags[i] == .r_bracket;
}

/// Is `n` an annotation the PARSER's half of the chain already judged — one
/// token, and that token a keyword? See `checkKeyType`.
fn isOneKeywordToken(c: *Checker, n: Node) bool {
    const tok = c.tree.nodeMainToken(n);
    const tok_span = c.tokSpan(tok);
    const node_span = c.nodeSpan(n);
    if (tok_span.start != node_span.start or tok_span.end != node_span.end) return false;
    return scanner.Tag.isKeyword(c.tree.tokens.tags[tok]);
}

/// tsc's `t.flags & TypeFlags.StringOrNumberLiteralOrUnique`, plus the
/// `isGenericType(type)` disjunct folded in per constituent — a bare type
/// PARAMETER is the generic spelling that reaches an index signature
/// (`type Wat<T extends string> = { [x: T]: string }`).
fn isLiteralOrGenericKey(c: *const Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .string_literal, .number_literal, .unique_symbol, .type_param => true,
        else => false,
    };
}

/// The complement of tsc's `isValidIndexKeyType`, stated positively: a
/// constituent this recognizes as NOT a key domain. `string`, `number`,
/// `symbol` and a pattern template literal are the domains; an intersection is
/// one when some constituent is (tsc's own recursion). Everything this does not
/// recognize either way answers `false` and reports nothing.
fn isInvalidKeyType(c: *const Checker, t: TypeId) bool {
    if (t == types.string_type or t == types.number_type or t == types.symbol_type) return false;
    return switch (c.ts.kind(t)) {
        .template_literal_type => false,
        .intersection => for (c.ts.members(t)) |m| {
            if (!isInvalidKeyType(c, m)) break false;
        } else true,
        .boolean,
        .bool_true,
        .bool_false,
        .any,
        .err,
        .unknown,
        .never,
        .void,
        .undefined,
        .null,
        .bigint,
        .object,
        .object_keyword,
        .array,
        .tuple,
        .function,
        .overloads,
        .class_value,
        => true,
        else => false,
    };
}

/// The site of an index-signature declaration, modifiers included.
fn indexSite(c: *Checker, node: Node) Site {
    const start = index_signature.memberStartToken(&c.tree.tokens, c.tree.nodeMainToken(node));
    var span = c.nodeSpan(node);
    span.start = c.tokSpan(start).start;
    return .{ .file = c.cur_file, .span = span };
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
