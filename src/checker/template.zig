//! Template-literal types (`` `a${T}b` ``) and the string intrinsics
//! (`Uppercase` and friends): building one from syntax, evaluating it once its
//! holes are concrete, matching a string against one as a pattern, and
//! inferring `infer` binders out of one.
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = @import("../intern.zig").Atom;
const SymbolId = @import("../frontend/binder.zig").SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_instantiation_depth = checker_zig.max_instantiation_depth;

const indexOfId = @import("generics.zig").indexOfId;

pub fn intrinsicStringMapping(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Uppercase")) return types.string_mapping_uppercase;
    if (std.mem.eql(u8, name, "Lowercase")) return types.string_mapping_lowercase;
    if (std.mem.eql(u8, name, "Capitalize")) return types.string_mapping_capitalize;
    if (std.mem.eql(u8, name, "Uncapitalize")) return types.string_mapping_uncapitalize;
    return null;
}

/// Whether type alias `sym`'s body is the bare `intrinsic` keyword-identifier
/// (`type Uppercase<S extends string> = intrinsic;`), the marker the real lib
/// uses for its magic string transforms. Distinguishes them from a user alias
/// that merely shares the name.
pub fn aliasBodyIsIntrinsic(c: *Checker, sym: SymbolId) bool {
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .type_alias) continue;
        const body = c.tree.nodeData(decl).rhs;
        if (body == null_node or c.nodeTag(body) != .identifier) return false;
        return std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(body)), "intrinsic");
    }
    return false;
}

/// The literal text following template hole `i` in a template-literal type
/// node: strip the `template_middle` (`}…${`) or `template_tail` (`}…\``)
/// delimiters. No unescaping (a documented simplification — escapes in
/// template *types* are rare).
pub fn templateChunkText(c: *Checker, tok: TokenIndex) []const u8 {
    const text = c.tokenText(tok);
    // middle: `}...${` (drop 1 leading `}`, 2 trailing `${`);
    // tail:   `}...\`` (drop 1 leading `}`, 1 trailing backtick).
    return switch (c.tree.tokens.tag(tok)) {
        .template_middle => if (text.len >= 3) text[1 .. text.len - 2] else "",
        .template_tail => if (text.len >= 2) text[1 .. text.len - 1] else "",
        else => text,
    };
}

/// Head literal text of a template-literal type node's main token: strip
/// the `template_head` (`` `…${ ``) or `no_substitution` (`` `…` ``) delims.
pub fn templateHeadText(c: *Checker, tok: TokenIndex) []const u8 {
    const text = c.tokenText(tok);
    return switch (c.tree.tokens.tag(tok)) {
        .template_head => if (text.len >= 3) text[1 .. text.len - 2] else "",
        .no_substitution_template_literal => if (text.len >= 2) text[1 .. text.len - 1] else "",
        else => text,
    };
}

/// Does the contextual type want a template-literal-typed value? True when
/// `ctx` is (or a union contains) a string-literal or template-literal type —
/// tsc's `isTemplateLiteralContextualType` (`TypeFlags.StringLiteral |
/// TypeFlags.TemplateLiteral`), which is what `checkTemplateExpression`
/// consults before it widens a template expression to `string`.
///
/// The STRING-LITERAL half is what makes a template over a literal union land
/// on a literal-union target: `` navigation.navigate(`${tab}Tab`) `` with
/// `tab: "Home" | "Search" | …` is contextually a union of route-name
/// literals, so tsc builds `` `${"Home" | "Search" | …}Tab` `` — which expands
/// to exactly those route names — instead of `string`. Widening lost it, and
/// social-app's `Drawer`/`BottomBar` tab dispatch was a phantom TS2322/TS2345
/// pair on every such call.
///
/// (An earlier attempt at this half was reverted: it exposed a SEPARATE hole,
/// a template-literal type not relating to `{}`, which made excalidraw's
/// `` transform: `translate(${n}px, …)` `` against `Globals | (string & {})`
/// two fresh TS2322. That relation is fixed at its own site — see the
/// template-literal source arm in `isAssignableInner` — so the two no longer
/// interact.)
pub fn ctxWantsTemplate(c: *Checker, ctx: TypeId) Error!bool {
    if (ctx == types.no_type) return false;
    const r = try c.resolveStructural(ctx);
    switch (c.ts.kind(r)) {
        .template_literal_type, .string_literal => return true,
        .union_type => {
            for (try c.memberList(r)) |m| if (try c.ctxWantsTemplate(m)) return true;
            return false;
        },
        // tsc's `isTemplateLiteralContextualType` also admits an
        // instantiable type whose base constraint is string-like: a
        // template expression inferred into `watch<N extends
        // FieldPath<T>>` must keep `` `contacts.${number}.type` ``
        // (widening to `string` fails the constraint, erasing `N` and
        // rejecting the overload).
        .type_param => {
            const con = try c.typeParamConstraint(c.ts.typeParamSymbol(r));
            if (con == types.no_type) return false;
            // tsc reads the BASE constraint here (`getBaseConstraintOfType`),
            // which is what makes a constraint that is itself parameterised
            // string-like: `TName extends FieldPath<TFieldValues>` is a
            // deferred alias reference while `TFieldValues` is free, so the
            // resolved-structural test alone answered "not string-like" and
            // the template expression widened to `string`.
            const base = if (try c.containsTypeParam(con)) try c.baseConstraintOf(con) else con;
            return c.typeIsStringLike(try c.resolveStructural(base));
        },
        else => return false,
    }
}

/// tsc's `TypeFlags.StringLike` over a resolved constraint (plus a
/// union/intersection scan, as in `maybeTypeOfKind`).
pub fn typeIsStringLike(c: *Checker, t: TypeId) Error!bool {
    return switch (c.ts.kind(t)) {
        .string, .string_literal, .template_literal_type, .string_mapping => true,
        .union_type, .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (try c.typeIsStringLike(try c.resolveStructural(m))) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// The `template_middle` / `template_tail` chunk token immediately following
/// a substitution that ends at byte `after`. Robust under nested template
/// substitutions: an inner template's tokens all start before `after`, so
/// the first middle/tail token at or past `after` is this template's chunk.
pub fn templateChunkTokAfter(c: *Checker, head_tok: TokenIndex, after: u32) TokenIndex {
    const n = c.tree.tokens.len();
    var t: usize = @as(usize, head_tok) + 1;
    while (t < n) : (t += 1) {
        const tg = c.tree.tokens.tag(@intCast(t));
        if ((tg == .template_middle or tg == .template_tail) and c.tree.tokens.start(@intCast(t)) >= after)
            return @intCast(t);
    }
    return head_tok;
}

/// A template-literal *expression* (`` `head${e0}c0${e1}…` ``) contextually
/// typed by a template-literal type: build the corresponding template-literal
/// *type* (`` `head${T0}c0${T1}…` ``) from the head/chunk texts and the
/// substitution types, rather than widening to `string`. This lets
/// `` `material-symbols:${status.icon}` `` (`status.icon: string`) satisfy a
/// `` `${string}:${string}` `` target — matching tsc's contextual typing.
/// tsc's `isTypeAssignableTo(type, templateConstraintType)` for one
/// template-expression hole — `templateConstraintType` is
/// `string | number | bigint | boolean | null | undefined`, the primitives a
/// template can actually spell. Anything else (an object, a symbol) is
/// replaced by `string`, so `` `${o}Tab` `` is `` `${string}Tab` ``.
///
/// A generic hole is decided through the relation, not by kind: `T extends
/// keyof AssetExifTable` IS assignable to the constraint, which is what keeps
/// `` `excluded.${col}` `` a template over `T` (and kysely's `eb.ref` overload
/// resolvable) instead of collapsing it to `` `excluded.${string}` ``.
fn templateHoleSpellable(c: *Checker, t: TypeId) Error!bool {
    const s = &c.ts;
    var buf: [6]TypeId = .{
        types.string_type,
        types.number_type,
        types.bigint_type,
        types.boolean_type,
        types.null_type,
        types.undefined_type,
    };
    const constraint = s.makeUnion(c.scratch(), &buf) catch return true;
    return c.isAssignable(t, constraint);
}

pub fn templateExprType(c: *Checker, node: Node) Error!TypeId {
    const main_tok = c.tree.nodeMainToken(node);
    const head = try c.atom(c.templateHeadText(main_tok));
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(c.scratch());
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (c.tree.nodeRange(node)) |sub| {
        const st = if (sub != null_node) try c.checkExprCached(sub, types.no_type) else types.string_type;
        // tsc's `checkTemplateExpression`:
        // `types.push(isTypeAssignableTo(type, templateConstraintType) ? type
        // : stringType)`. A hole whose value is not one of the primitives a
        // template can spell (`string | number | bigint | boolean | null |
        // undefined`) contributes `string`, not itself — so `` `${o}Tab` ``
        // over an `object` is `` `${string}Tab` ``, which a
        // `` `${string}Tab` `` target accepts.
        try holes.append(c.scratch(), if (try templateHoleSpellable(c, st)) st else types.string_type);
        const ctok = c.templateChunkTokAfter(main_tok, c.nodeSpan(sub).end);
        try chunks.append(c.scratch(), try c.atom(c.templateChunkText(ctok)));
    }
    if (holes.items.len == 0) return c.ts.makeStringLiteral(head, false);
    return c.reduceTemplateChunks(head, holes.items, chunks.items);
}

pub fn templateTypeFromNode(c: *Checker, node: Node) Error!TypeId {
    const d = c.tree.nodeData(node);
    const e = c.tree.extraData(ast.TemplateLitType, d.lhs);
    const head = try c.atom(c.templateHeadText(c.tree.nodeMainToken(node)));
    const hole_nodes = c.tree.extraRange(e.holes_start, e.holes_end);
    const chunk_toks = c.tree.extraRange(e.chunks_start, e.chunks_end);
    if (hole_nodes.len == 0) return c.ts.makeStringLiteral(head, false);
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(c.scratch());
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (hole_nodes, 0..) |hn, i| {
        try holes.append(c.scratch(), try c.typeFromTypeNode(hn));
        const ct = if (i < chunk_toks.len) try c.atom(c.templateChunkText(chunk_toks[i])) else try c.atom("");
        try chunks.append(c.scratch(), ct);
    }
    return c.reduceTemplateChunks(head, holes.items, chunks.items);
}

/// Re-evaluate a template from an existing template-literal `tpl` (reuses
/// its stored chunk atoms) with fresh `holes` (post-substitution).
pub fn reduceTemplate(c: *Checker, head: Atom, holes: []const TypeId, tpl: TypeId) Error!TypeId {
    var chunks: std.ArrayList(Atom) = .empty;
    defer chunks.deinit(c.scratch());
    for (0..c.ts.templateHoleCount(tpl)) |i| try chunks.append(c.scratch(), c.ts.templateChunk(tpl, @intCast(i)));
    return c.reduceTemplateChunks(head, holes, chunks.items);
}

/// A partially-evaluated template builder: a concrete `head` string plus a
/// list of committed *pattern* holes (a non-enumerable hole type and the
/// literal text that follows it). Concrete/enumerable text is folded into
/// `head` (no pattern holes yet) or into the last hole's `chunk`.
pub const TplBuilder = struct {
    head: std.ArrayList(u8),
    holes: std.ArrayList(TypeId),
    chunks: std.ArrayList(std.ArrayList(u8)),
};

/// The single evaluation point for a template-literal type (build time +
/// each instantiation). Defers (keeps the template symbolic) while any hole
/// is still generic; otherwise cross-products the enumerable holes and
/// keeps non-enumerable (`string`/`number`) holes as a pattern. Counted
/// against the TS2589 depth/count budget.
pub fn reduceTemplateChunks(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
    if (c.inst_depth > max_instantiation_depth or c.inst_count > c.inst_budget) {
        c.inst_limit_tripped = true;
        if (c.instDiagAllowed()) try c.instLimitDiag(2589, "Type instantiation is excessively deep and possibly infinite.");
        return types.error_type;
    }
    c.inst_depth += 1;
    c.inst_count += 1;
    c.inst_total += 1;
    defer c.inst_depth -= 1;
    // Release this evaluation's scratch on the way out, the way a `relate`
    // frame does. `evalTemplate` cross-products its builder list hole by
    // hole, cloning every builder each round and "freeing" the previous
    // generation — but `BumpArena.free` is a no-op for anything but the most
    // recent block, and an `ArrayList` growing abandons each predecessor, so
    // a wide cross product leaves the whole intermediate generation sequence
    // live. Nothing it allocates outlives this call: both return paths hand
    // back an interned `TypeId` (`makeTemplateLiteral` copies `holes`/`chunks`
    // into store memory, `makeUnion` uses the scratch only for its flatten
    // worklist), and `holes`/`chunks` themselves were bumped by the caller
    // before this mark. The arena is captured rather than re-read because a
    // nested top-level `instantiate` swaps a different one in for its own
    // duration.
    //
    // Measured on immich: `check scratch high-water` 874,668,264 -> 237,658,344
    // and peak RSS 1.201 -> 0.564 GB at one checker (2.554 -> 1.402 GB at
    // four), diagnostics byte-identical.
    const tpl_arena = c.scratch_arena;
    const tpl_mark = tpl_arena.mark();
    defer tpl_arena.restore(tpl_mark);
    // Still generic in any hole → defer (keep the deferred template type).
    for (holes) |h| {
        if (try c.containsTypeParam(h) or try c.containsMappedParam(h) or try c.containsInfer(h)) {
            return c.ts.makeTemplateLiteral(head, holes, chunks);
        }
    }
    return c.evalTemplate(head, holes, chunks);
}

/// Concrete cross-product evaluation. Produces a union of string-literal
/// types (all holes enumerable) and/or template-literal *pattern* types
/// (some hole is a bare `string`/`number`). Bounds the working set by the
/// instantiation count limit; on explosion trips TS2589 (bounded, never hangs).
pub fn evalTemplate(c: *Checker, head: Atom, holes: []const TypeId, chunks: []const Atom) Error!TypeId {
    const gpa = c.scratch();
    var builders: std.ArrayList(TplBuilder) = .empty;
    defer {
        for (builders.items) |*b| freeBuilder(gpa, b);
        builders.deinit(gpa);
    }
    {
        var b0: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
        try b0.head.appendSlice(gpa, c.atomText(head));
        try builders.append(gpa, b0);
    }
    // tsc caps a template-literal union at 100000 members, emitting TS2590
    // past it. Match that so a `${D}${D}${D}${D}${D}` (10^5) blowup trips
    // gracefully instead of materializing millions of string literals.
    const cap: usize = 100_000;
    for (holes, 0..) |hole, i| {
        const chunk_text = c.atomText(chunks[i]);
        var forms: std.ArrayList(Atom) = .empty;
        defer forms.deinit(gpa);
        const enumerable = try c.enumerableForms(hole, &forms);
        var next: std.ArrayList(TplBuilder) = .empty;
        if (enumerable) {
            for (builders.items) |*b| {
                for (forms.items) |f| {
                    var nb = try cloneBuilder(gpa, b);
                    try appendConcrete(gpa, &nb, c.atomText(f));
                    try appendConcrete(gpa, &nb, chunk_text);
                    try next.append(gpa, nb);
                }
                freeBuilder(gpa, b);
            }
        } else {
            for (builders.items) |*b| {
                var nb = try cloneBuilder(gpa, b);
                try nb.holes.append(gpa, hole);
                var ch: std.ArrayList(u8) = .empty;
                try ch.appendSlice(gpa, chunk_text);
                try nb.chunks.append(gpa, ch);
                try next.append(gpa, nb);
                freeBuilder(gpa, b);
            }
        }
        builders.deinit(gpa);
        builders = next;
        if (builders.items.len >= cap) {
            c.inst_limit_tripped = true;
            try c.instLimitDiag(2590, "Expression produces a union type that is too complex to represent.");
            return types.string_type;
        }
    }
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(gpa);
    for (builders.items) |*b| {
        const bhead = try c.internText(b.head.items);
        if (b.holes.items.len == 0) {
            try parts.append(gpa, try c.ts.makeStringLiteral(bhead, false));
        } else {
            var chunk_atoms: std.ArrayList(Atom) = .empty;
            defer chunk_atoms.deinit(gpa);
            for (b.chunks.items) |ch| try chunk_atoms.append(gpa, try c.internText(ch.items));
            try parts.append(gpa, try c.ts.makeTemplateLiteral(bhead, b.holes.items, chunk_atoms.items));
        }
    }
    return c.ts.makeUnion(gpa, parts.items);
}

pub fn cloneBuilder(gpa: std.mem.Allocator, b: *const TplBuilder) Error!TplBuilder {
    var nb: TplBuilder = .{ .head = .empty, .holes = .empty, .chunks = .empty };
    try nb.head.appendSlice(gpa, b.head.items);
    try nb.holes.appendSlice(gpa, b.holes.items);
    for (b.chunks.items) |ch| {
        var c2: std.ArrayList(u8) = .empty;
        try c2.appendSlice(gpa, ch.items);
        try nb.chunks.append(gpa, c2);
    }
    return nb;
}

pub fn freeBuilder(gpa: std.mem.Allocator, b: *TplBuilder) void {
    b.head.deinit(gpa);
    b.holes.deinit(gpa);
    for (b.chunks.items) |*ch| ch.deinit(gpa);
    b.chunks.deinit(gpa);
}

/// Append concrete text: into the running `head` while no pattern hole has
/// been committed, otherwise onto the last committed hole's chunk.
pub fn appendConcrete(gpa: std.mem.Allocator, b: *TplBuilder, text: []const u8) Error!void {
    if (b.chunks.items.len == 0) {
        try b.head.appendSlice(gpa, text);
    } else {
        try b.chunks.items[b.chunks.items.len - 1].appendSlice(gpa, text);
    }
}

/// If `hole` enumerates to a finite set of concrete strings, append them to
/// `out` and return true; otherwise (bare `string`/`number`, deferred
/// intrinsic, …) return false — the hole must stay a pattern.
pub fn enumerableForms(c: *Checker, hole0: TypeId, out: *std.ArrayList(Atom)) Error!bool {
    const s = &c.ts;
    const hole = try c.resolveStructural(hole0);
    switch (s.kind(hole)) {
        .string_literal => {
            try out.append(c.scratch(), s.literalAtom(hole));
            return true;
        },
        .number_literal, .number_literal_fresh => {
            try out.append(c.scratch(), try c.numberLiteralAtom(hole));
            return true;
        },
        .bigint_literal => {
            try out.append(c.scratch(), s.literalAtom(hole));
            return true;
        },
        .bool_true => {
            try out.append(c.scratch(), try c.atom("true"));
            return true;
        },
        .bool_false => {
            try out.append(c.scratch(), try c.atom("false"));
            return true;
        },
        // `boolean` interpolates as the union `"false" | "true"`.
        .boolean => {
            try out.append(c.scratch(), try c.atom("false"));
            try out.append(c.scratch(), try c.atom("true"));
            return true;
        },
        .null => {
            try out.append(c.scratch(), try c.atom("null"));
            return true;
        },
        .undefined => {
            try out.append(c.scratch(), try c.atom("undefined"));
            return true;
        },
        .union_type => {
            for (try c.memberList(hole)) |m| {
                if (!try c.enumerableForms(m, out)) return false;
            }
            return true;
        },
        // An enum interpolates as its constant VALUES. tsc needs no special
        // case: a member type carries `StringLiteral | EnumLiteral` (so
        // `addSpans` reads its `value` straight off) and a WHOLE enum IS the
        // union of its members, which the union arm above distributes over.
        // ztsc keeps the enum as one `.enum_type`, so both forms are spelled
        // out here — without it `` `${AppLanguage}` `` stayed a symbolic
        // pattern that no member string was comparable to (5 TS2678 on
        // social-app's `switch (lang as `${AppLanguage}`)`).
        .enum_type => {
            const esym = s.enumSymbol(hole);
            if (s.isEnumMember(hole)) {
                const v = (try c.enumMemberValue(esym, s.enumMemberAtom(hole))) orelse return false;
                return c.enumerableForms(v, out);
            }
            const members = try c.enumMembersOf(esym);
            if (members.len == 0) return false;
            for (members) |m| {
                if (m.value == types.no_type) return false;
                if (!try c.enumerableForms(m.value, out)) return false;
            }
            return true;
        },
        // The `Core & string` template-hole idiom, generalized: `"a" & string`
        // (a single literal), `("a"|"b") & string` (a literal UNION, which the
        // single-literal `stringLiteralOf` path missed — it left the hole a
        // malformed pattern), and — the load-bearing case for recursive
        // path builders — `PathInternal<V, …> & string` where the non-primitive
        // member is an alias `.ref` inside the hole. Each member is resolved
        // structurally, which DRIVES such a ref home (e.g. `PInt<{deep}>` →
        // `"deep"`) under the ordinary shrinking discipline; the string/number
        // primitive constraint is absorbed and the sole literal core enumerates.
        // Two non-primitive members (a genuine literal-vs-literal intersection)
        // or a non-enumerable core fall back to keeping the hole a pattern.
        .intersection => {
            var core: TypeId = types.no_type;
            for (try c.memberList(hole)) |m0| {
                const m = try c.resolveStructural(m0);
                switch (s.kind(m)) {
                    // primitive supertypes absorbed by a string/number literal
                    .string, .number, .bigint => {},
                    else => {
                        if (core != types.no_type) return false;
                        core = m;
                    },
                }
            }
            if (core != types.no_type) return c.enumerableForms(core, out);
            return false;
        },
        else => return false, // string / number / pattern / mapping → keep as pattern
    }
}

/// The single concrete string-literal atom `t` denotes, seeing through a
/// `literal & primitive` intersection (`"a" & string` → `"a"`). Null when
/// `t` is not a single concrete string.
pub fn stringLiteralOf(c: *Checker, t0: TypeId) Error!?Atom {
    const s = &c.ts;
    const t = try c.resolveStructural(t0);
    return switch (s.kind(t)) {
        .string_literal => s.literalAtom(t),
        .number_literal, .number_literal_fresh => try c.numberLiteralAtom(t),
        .intersection => blk: {
            for (try c.memberList(t)) |m| {
                if (s.kind(m) == .string_literal) break :blk s.literalAtom(m);
            }
            break :blk null;
        },
        else => null,
    };
}

/// Apply a string-transform intrinsic. Concrete string → transformed
/// string-literal; union → distribute; still-generic arg → defer as a
/// `string_mapping` type. `string` itself maps to `string`.
pub fn applyStringMapping(c: *Checker, kind_idx: u32, arg0: TypeId) Error!TypeId {
    const s = &c.ts;
    const arg = try c.resolveStructural(arg0);
    switch (s.kind(arg)) {
        .string => return types.string_type,
        .any, .err => return arg,
        .never => return types.never_type,
        .union_type => {
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            for (try c.memberList(arg)) |m| try parts.append(c.scratch(), try c.applyStringMapping(kind_idx, m));
            return s.makeUnion(c.scratch(), parts.items);
        },
        else => {},
    }
    if (try c.stringLiteralOf(arg)) |atom_| {
        const src = c.atomText(atom_);
        const buf = try c.scratch().alloc(u8, src.len);
        defer c.scratch().free(buf);
        transformString(kind_idx, src, buf);
        return s.makeStringLiteral(try c.internText(buf), false);
    }
    // Still generic (type param / mapped_param / infer / nested template
    // pattern / another mapping) → defer.
    return s.makeStringMapping(kind_idx, arg);
}

pub fn transformString(kind_idx: u32, src: []const u8, dst: []u8) void {
    for (src, 0..) |ch, i| dst[i] = ch;
    switch (kind_idx) {
        types.string_mapping_uppercase => for (dst) |*ch| {
            ch.* = std.ascii.toUpper(ch.*);
        },
        types.string_mapping_lowercase => for (dst) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        },
        types.string_mapping_capitalize => if (dst.len > 0) {
            dst[0] = std.ascii.toUpper(dst[0]);
        },
        types.string_mapping_uncapitalize => if (dst.len > 0) {
            dst[0] = std.ascii.toLower(dst[0]);
        },
        else => {},
    }
}

/// Does concrete `text` match template-literal pattern `tpl`? Used for
/// `"axb"`-assignable-to-`` `a${string}b` ``. Backtracks over occurrences of
/// each hole's following literal so multi-hole patterns match soundly.
pub fn matchTemplatePattern(c: *Checker, text: []const u8, tpl: TypeId) Error!bool {
    const head = c.atomText(c.ts.templateHead(tpl));
    if (!std.mem.startsWith(u8, text, head)) return false;
    return c.matchTplHole(text[head.len..], tpl, 0);
}

pub fn matchTplHole(c: *Checker, rest: []const u8, tpl: TypeId, i: u32) Error!bool {
    const s = &c.ts;
    const n = s.templateHoleCount(tpl);
    if (i == n) return rest.len == 0;
    const hole = s.templateHole(tpl, i);
    const chunk = c.atomText(s.templateChunk(tpl, i));
    if (i + 1 == n) {
        if (!std.mem.endsWith(u8, rest, chunk)) return false;
        return c.holeAccepts(hole, rest[0 .. rest.len - chunk.len]);
    }
    if (chunk.len == 0) {
        var split: usize = 0;
        while (split <= rest.len) : (split += 1) {
            if ((try c.holeAccepts(hole, rest[0..split])) and try c.matchTplHole(rest[split..], tpl, i + 1)) return true;
        }
        return false;
    }
    var from: usize = 0;
    while (std.mem.indexOf(u8, rest[from..], chunk)) |rel| {
        const pos = from + rel;
        if ((try c.holeAccepts(hole, rest[0..pos])) and try c.matchTplHole(rest[pos + chunk.len ..], tpl, i + 1)) return true;
        from = pos + 1;
    }
    return false;
}

/// Whether a template pattern hole type admits the substring `str`.
pub fn holeAccepts(c: *Checker, hole0: TypeId, str: []const u8) Error!bool {
    const s = &c.ts;
    const hole = try c.resolveStructural(hole0);
    switch (s.kind(hole)) {
        .string, .any, .err => return true,
        .number => return isNumericString(str),
        .bigint => return isNumericString(str),
        .boolean => return std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "false"),
        .bool_true => return std.mem.eql(u8, str, "true"),
        .bool_false => return std.mem.eql(u8, str, "false"),
        .string_literal => return std.mem.eql(u8, str, c.atomText(s.literalAtom(hole))),
        .number_literal, .number_literal_fresh => return std.mem.eql(u8, str, c.atomText(try c.numberLiteralAtom(hole))),
        .union_type => {
            for (try c.memberList(hole)) |m| {
                if (try c.holeAccepts(m, str)) return true;
            }
            return false;
        },
        .template_literal_type => return c.matchTemplatePattern(str, hole),
        else => return false,
    }
}

pub fn isNumericString(str: []const u8) bool {
    if (str.len == 0) return false;
    _ = std.fmt.parseFloat(f64, str) catch return false;
    return true;
}

// =====================================================================
// inference through a template-literal pattern
// =====================================================================

/// Greedy pattern-match a concrete string against a template-literal
/// pattern, binding each `infer` hole (tsc's rules: a non-empty following
/// literal captures up to its *first* occurrence — lazy; the last hole
/// takes the remainder; two adjacent holes split one character to the
/// first). No backtracking (a documented simplification, exact for
/// the single-delimiter forms tsc users rely on).
pub fn inferFromTemplate(c: *Checker, text: []const u8, tpl: TypeId, ids: []const u32, vals: []TypeId) Error!void {
    const s = &c.ts;
    const head = c.atomText(s.templateHead(tpl));
    if (!std.mem.startsWith(u8, text, head)) return;
    const n = s.templateHoleCount(tpl);
    var pos: usize = head.len;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const hole = s.templateHole(tpl, i);
        const chunk = c.atomText(s.templateChunk(tpl, i));
        var cap_end: usize = undefined;
        if (i + 1 == n) {
            // Last hole: `chunk` is the tail literal; text must end with it.
            if (!std.mem.endsWith(u8, text[pos..], chunk)) return;
            cap_end = text.len - chunk.len;
        } else if (chunk.len == 0) {
            // Adjacent holes with no separator: capture one char.
            cap_end = @min(pos + 1, text.len);
        } else {
            const rel = std.mem.indexOf(u8, text[pos..], chunk) orelse return;
            cap_end = pos + rel;
        }
        const captured = text[pos..cap_end];
        try c.bindTemplateInfer(hole, captured, ids, vals);
        pos = cap_end + (if (i + 1 == n) chunk.len else if (chunk.len == 0) @as(usize, 0) else chunk.len);
    }
}

/// Bind the infer var(s) in a template hole to a captured substring. The
/// common case is a bare `infer X` (→ the string-literal of the capture);
/// a `string`/`number` typed hole binds nothing.
pub fn bindTemplateInfer(c: *Checker, hole: TypeId, captured: []const u8, ids: []const u32, vals: []TypeId) Error!void {
    const s = &c.ts;
    if (s.kind(hole) != .infer_var) return;
    const idx = indexOfId(ids, s.inferVarId(hole)) orelse return;
    const lit = try c.ts.makeStringLiteral(try c.internText(captured), false);
    if (vals[idx] == types.no_type) {
        vals[idx] = lit;
    } else {
        vals[idx] = try c.makeUnion2(vals[idx], lit);
    }
}

/// Infer from a template-literal *type* source into a template-literal
/// pattern — tsc's `inferTypesFromTemplateLiteralType` +
/// `inferFromLiteralPartsToTemplateLiteral`. The source contributes its fixed
/// text parts (`texts[0]` = head, `texts[i+1]` = the chunk after hole `i`)
/// and its placeholder types; `matchTemplateParts` produces one match type
/// per TARGET hole, and each is then inferred into that hole exactly as tsc
/// pairs `matches[i]` with `target.types[i]`. So
/// `` `owners.${number}.status` extends `${infer K}.${infer R}` `` binds
/// `K = "owners"` and `` R = `${number}.status` ``, and the recursive path
/// walk keeps going instead of collapsing to `never`.
pub fn inferFromTemplateSource(c: *Checker, src: TypeId, tpl: TypeId, ids: []const u32, vals: []TypeId, contra: bool, depth: u32) Error!void {
    const s = &c.ts;
    const gpa = c.scratch();
    const n = s.templateHoleCount(src);
    // Interned atom bytes are stable for the interner's lifetime, so the
    // text slices survive the atom-table growth `addMatch` triggers.
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);
    var holes: std.ArrayList(TypeId) = .empty;
    defer holes.deinit(gpa);
    try texts.append(gpa, c.atomText(s.templateHead(src)));
    for (0..n) |i| {
        try holes.append(gpa, s.templateHole(src, @intCast(i)));
        try texts.append(gpa, c.atomText(s.templateChunk(src, @intCast(i))));
    }
    var matches: std.ArrayList(TypeId) = .empty;
    defer matches.deinit(gpa);
    if (!try c.matchTemplateParts(texts.items, holes.items, tpl, &matches)) return;
    for (matches.items, 0..) |m, i| {
        try c.inferFromExtends(m, s.templateHole(tpl, @intCast(i)), ids, vals, contra, depth + 1);
    }
}

/// The scan half of tsc's `inferFromLiteralPartsToTemplateLiteral`. Anchors
/// the target's leading/trailing fixed text, then walks the target's interior
/// delimiters left-to-right over the source's parts. A delimiter is only ever
/// found in source TEXT — a source placeholder (`${number}`) is opaque and
/// cannot be split by it, so a hole that spans one absorbs it whole and the
/// match is rebuilt as a template-literal type. Appends one match type per
/// target hole to `out`; returns false (inferring nothing) when the source
/// cannot match, matching tsc's `undefined`.
pub fn matchTemplateParts(c: *Checker, source_texts: []const []const u8, source_types: []const TypeId, tpl: TypeId, out: *std.ArrayList(TypeId)) Error!bool {
    const s = &c.ts;
    std.debug.assert(source_texts.len == source_types.len + 1);
    const m = s.templateHoleCount(tpl);
    if (m == 0) return false;
    const last_source = source_texts.len - 1;
    const target_start = c.atomText(s.templateHead(tpl));
    const target_end = c.atomText(s.templateChunk(tpl, m - 1));
    const source_start = source_texts[0];
    const source_end = source_texts[last_source];
    if (last_source == 0 and source_start.len < target_start.len + target_end.len) return false;
    if (!std.mem.startsWith(u8, source_start, target_start)) return false;
    if (!std.mem.endsWith(u8, source_end, target_end)) return false;

    var w: PartWalk = .{
        .c = c,
        .texts = source_texts,
        .types = source_types,
        .last = last_source,
        .remaining_end = source_end[0 .. source_end.len - target_end.len],
        .pos = target_start.len,
        .out = out,
    };
    var j: u32 = 0;
    while (j + 1 < m) : (j += 1) {
        const delim = c.atomText(s.templateChunk(tpl, j));
        if (delim.len > 0) {
            var si = w.seg;
            var p = w.pos;
            while (true) {
                const txt = w.sourceText(si);
                if (p <= txt.len) {
                    if (std.mem.indexOf(u8, txt[p..], delim)) |rel| {
                        p += rel;
                        break;
                    }
                }
                si += 1;
                if (si == source_texts.len) return false;
                p = 0;
            }
            try w.addMatch(si, p);
            w.pos += delim.len;
        } else if (w.pos < w.sourceText(w.seg).len) {
            // Adjacent target holes, source text left to split: one char.
            try w.addMatch(w.seg, w.pos + 1);
        } else if (w.seg < last_source) {
            // …otherwise the next hole absorbs the source's placeholder.
            try w.addMatch(w.seg + 1, 0);
        } else return false;
    }
    try w.addMatch(last_source, w.sourceText(last_source).len);
    return true;
}

/// tsc's tail of `getTemplateLiteralType`: a template whose text parts are
/// ALL empty is not a pattern at all, it is its hole. `` `${string}` `` (any
/// number of `string` holes) is exactly `string`, and a lone hole that is
/// itself a pattern (`` `${`a${number}`}` ``, `` `${Uppercase<T>}` ``) is
/// that pattern. Applied only to the types `matchTemplateParts` recombines,
/// so the shared `reduceTemplateChunks` evaluation point is untouched —
/// without it an `infer` hole would bind `` `${string}` `` where tsc binds
/// `string`, and the extra pattern wrapper would reject a plain `string`
/// downstream (a false positive).
pub fn normalizeTextlessTemplate(c: *Checker, t: TypeId) Error!TypeId {
    const s = &c.ts;
    if (s.kind(t) != .template_literal_type) return t;
    const n = s.templateHoleCount(t);
    if (c.atomText(s.templateHead(t)).len != 0) return t;
    for (0..n) |i| {
        if (c.atomText(s.templateChunk(t, @intCast(i))).len != 0) return t;
    }
    var all_string = true;
    for (0..n) |i| {
        if (s.kind(try c.resolveStructural(s.templateHole(t, @intCast(i)))) != .string) all_string = false;
    }
    if (all_string) return types.string_type;
    if (n == 1) {
        const hole = s.templateHole(t, 0);
        switch (s.kind(hole)) {
            .template_literal_type, .string_mapping => return hole,
            else => {},
        }
    }
    return t;
}

/// Cursor over a source template's (texts, types) parts: `seg` is the text
/// part the cursor sits in and `pos` the offset within it.
const PartWalk = struct {
    c: *Checker,
    texts: []const []const u8,
    types: []const TypeId,
    last: usize,
    /// The last text part with the target's trailing literal stripped; it is
    /// what `sourceText` reports for the final segment.
    remaining_end: []const u8,
    seg: usize = 0,
    pos: usize,
    out: *std.ArrayList(TypeId),

    fn sourceText(w: *const PartWalk, i: usize) []const u8 {
        return if (i < w.last) w.texts[i] else w.remaining_end;
    }

    /// Commit the span from (`seg`, `pos`) up to (`si`, `p`) as one target
    /// hole's match: a string literal when it stays inside one text part,
    /// otherwise a template-literal type recombining the crossed text and
    /// placeholder parts.
    fn addMatch(w: *PartWalk, si: usize, p: usize) Error!void {
        const c = w.c;
        const gpa = c.scratch();
        var match: TypeId = undefined;
        if (si == w.seg) {
            match = try c.ts.makeStringLiteral(try c.internText(w.sourceText(si)[w.pos..p]), false);
        } else {
            var chunks: std.ArrayList(Atom) = .empty;
            defer chunks.deinit(gpa);
            var k = w.seg + 1;
            while (k < si) : (k += 1) try chunks.append(gpa, try c.internText(w.texts[k]));
            try chunks.append(gpa, try c.internText(w.sourceText(si)[0..p]));
            const head = try c.internText(w.texts[w.seg][w.pos..]);
            match = try c.normalizeTextlessTemplate(try c.reduceTemplateChunks(head, w.types[w.seg..si], chunks.items));
        }
        try w.out.append(gpa, match);
        w.seg = si;
        w.pos = p;
    }
};
