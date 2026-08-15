//! Reference identity for control-flow narrowing.
//!
//! A narrowable reference is a root (a value symbol, `this`, or a binding-
//! pattern pseudo-root) plus a path of dotted-member / element-access links,
//! packed into the 20-byte `RefKey` — the key every flow-cache slot is stored
//! under, which is why the layout is bit-packed rather than obvious. This file
//! owns that representation, its interning side tables, and the predicates
//! that decide whether an expression denotes a tracked reference at all.
//!
//! Nothing here walks the flow graph; `flow.zig` does that, and re-exports
//! every symbol below so `Checker` method spellings (`c.buildRefKey(...)`)
//! keep resolving.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// How many path links a `RefKey` stores *inline*. Chosen for layout, not
/// for semantics: `[3]PathElem` is what keeps `RefQ` at 24 bytes (see
/// `PathElem`), and a live reference is at this depth or shallower in the
/// overwhelming majority of cases.
pub const max_ref_depth = 3;

/// Maximum *tracked* reference-path depth. Links past `max_ref_depth` do
/// not fit inline, so a deeper path is interned in `deep_path_list` and
/// the key carries only its id (see `makeRefKey`) — the inline layout, and
/// therefore `RefQ`'s size, is unchanged. Paths deeper than this are still
/// not tracked (sound under-narrowing = the reference keeps its declared
/// type). tsc keys flow references by AST node identity and has no such
/// cap at all, and real code does reach past five links once element
/// accesses count as links: a GeoServer legend guard walks
/// `data?.Legend?.[0].rules?.[0]?.symbolizers?.[0]?.Raster?.colormap?.entries`
/// — nine links — and every reference on that spine has to narrow. The cap
/// only sizes `DeepPath`, the side-table entry an over-deep path interns
/// into; the inline `RefKey`/`RefQ` layout is fixed by `max_ref_depth` and
/// does not move, so raising it costs 16 bytes per distinct over-deep path
/// and nothing per flow-cache slot. Measured on the dogfood app, 5 vs 9 is
/// indistinguishable in wall clock and peak RSS.
pub const max_deep_ref_depth = 9;

/// One link in a reference path: a dotted member (`.p`), a constant element
/// access (`[0]`), or an element access through a *stable identifier* index
/// (`[tag]`, where `tag` is a `const` or a never-reassigned local/parameter
/// — tsc's `isMatchingReference` element-access arm). Any other index
/// expression is not a stable reference, so `buildRefKey` rejects it.
///
/// The three payloads are mutually exclusive by tag, so they share one u32
/// and the tag rides in that u32's two high bits (`atom()` / `index()` /
/// `indexSym()` assert the tag): the original two-field form carried a
/// permanently-zero companion field and cost 12 bytes, which `RefKey`'s
/// `[3]PathElem` multiplied into a 48-byte `ref_keys` key; a shared payload
/// behind a separate `bool` tag still cost 8 (`RefQ` 36) to the bool's own
/// field slot. Folding the tag into the high bits gets `PathElem` to 4
/// (`RefQ` 24).
///
/// The fold is lossless because every payload fits in 30 bits: element
/// indices are bounded by 4096 (`constIndexOf`), a symbol id is bounded by
/// the program's symbol count, and a member atom is a shard-interleaved
/// interner handle (`Interner.atomFrom`), so the tag bits are clear until a
/// single shard holds 2^(30 - 4) = 67 M strings — tens of millions of
/// distinct identifiers. That is a size bound, not a structural one, so
/// `memberFits`/`symFits` check it at the one construction site instead of
/// assuming it: a payload that does not fit makes `buildRefKey` return null,
/// i.e. the reference is simply not tracked (sound under-narrowing, the same
/// degradation as an over-deep path) — never a silent alias.
pub const PathElem = struct {
    /// Bit 31 = element access, bit 30 = (with bit 31) identifier index,
    /// bits 0..29 = payload. A dotted member is tag `00`, so `member(0)`
    /// is the all-zero default and unused slots hash canonically.
    bits: u32 = 0,

    pub const index_tag: u32 = 1 << 31;
    pub const sym_tag: u32 = 1 << 30;
    pub const payload_max: u32 = sym_tag - 1;

    /// Can this property atom be folded? (See the type doc: false only
    /// past atom 2^30-1, where the caller stops tracking the reference.)
    pub fn memberFits(a: Atom) bool {
        return a <= payload_max;
    }
    /// Can this index symbol be folded? (Same bound, same fallback.)
    pub fn symFits(s: SymbolId) bool {
        return s <= payload_max;
    }
    pub fn member(a: Atom) PathElem {
        std.debug.assert(memberFits(a));
        return .{ .bits = a };
    }
    pub fn element(i: u32) PathElem {
        std.debug.assert(i <= payload_max);
        return .{ .bits = index_tag | i };
    }
    pub fn elementSym(s: SymbolId) PathElem {
        std.debug.assert(symFits(s));
        return .{ .bits = index_tag | sym_tag | s };
    }
    pub fn isIndex(pe: PathElem) bool {
        return pe.bits & index_tag != 0;
    }
    pub fn isIndexSym(pe: PathElem) bool {
        return pe.bits & (index_tag | sym_tag) == (index_tag | sym_tag);
    }
    pub fn atom(pe: PathElem) Atom {
        std.debug.assert(!pe.isIndex());
        return pe.bits;
    }
    pub fn index(pe: PathElem) u32 {
        std.debug.assert(pe.isIndex() and !pe.isIndexSym());
        return pe.bits & payload_max;
    }
    pub fn indexSym(pe: PathElem) SymbolId {
        std.debug.assert(pe.isIndexSym());
        return pe.bits & payload_max;
    }
};

/// A narrowable reference: a bare identifier (`len == 0`) or a member
/// path `sym.path[0].path[1]…` capped at `max_deep_ref_depth`. `path[0]` is
/// the innermost link (closest to the root), `path[len-1]` the outermost.
/// Each link is a dotted member (`.p`) or a constant element access (`[i]`),
/// so `data.Legend[0].rules` is a depth-3 reference (`Legend`, `[0]`,
/// `rules`). A `this`-rooted path uses the sentinel root `this_flow_root`
/// (flow graphs are per-function, so the sentinel never crosses a
/// `this`-rebind boundary).
///
/// Up to `max_ref_depth` links live in `path`, with trailing slots past
/// `len` left default so the struct hashes/compares canonically as an
/// `AutoHashMap` key. A deeper path does not fit — widening `path` would
/// push `RefQ` past its 24-byte commitment — so it is interned instead:
/// `deep` holds its 1-based `deep_path_list` id and `path` stays all
/// default. Interning is structural (equal link sequences share one id),
/// so key equality stays exact either way, and `deep` is free: `sym` +
/// `path` + `len` is 17 bytes of a 4-aligned 20-byte struct, so it fits in
/// padding the key already carried. `refPath` reads either form.
pub const RefKey = struct {
    sym: SymbolId,
    path: [max_ref_depth]PathElem = [_]PathElem{.{}} ** max_ref_depth,
    /// 1-based `deep_path_list` id, or 0 when the path is inline.
    deep: u16 = 0,
    len: u8 = 0,
    /// A DEFINITE-ASSIGNMENT query — `strictPropertyInitialization` for a
    /// `this` property (`thisPropUnassigned`, TS2564/TS2565) or use-before-
    /// assignment for a variable (`unassignedVarType`, TS2454) — rather than
    /// an ordinary narrowing query: the walk starts from tsc's `initialType`
    /// — `declared | undefined` — instead of the declared type, so that
    /// reaching the top of the flow *is* the answer "this path never wrote
    /// it". tsc passes the two types separately
    /// (`getFlowTypeOfReference(ref, declaredType, initialType)`); ztsc's walk
    /// carries one, so the difference rides in the reference key.
    ///
    /// Two arms of the walk read it beyond that: a compound write does not
    /// initialize, and an edge a literal `true`/`false` condition contradicts
    /// does not exist. Both are tsc's rule for every reference; ztsc applies
    /// them where the answer is a yes/no about assignment rather than a type
    /// anyone observes, because the narrowing arms they would replace are
    /// strictly more precise (see their call sites in `flow.zig`).
    ///
    /// It has to live in the KEY rather than beside it: `FlowQ` interns
    /// `(flow, reference, declared)` and caches the answer under it, and the
    /// same triple is queried both ways — an ordinary read of `this.x` inside
    /// the constructor asks for the same reference at the same flow node with
    /// the same declared type, and must not read back an initialization
    /// verdict (or leave one behind). Riding in the key makes the two query
    /// families disjoint by construction, and it is free: it fills the
    /// padding byte `deep`/`len` already left in a 20-byte struct, so `RefQ`
    /// keeps its 24-byte commitment.
    opt_init: bool = false,
};

/// One interned over-deep link sequence (see `RefKey.deep`). Slots past
/// `len` stay default so the struct is a canonical `AutoHashMap` key.
pub const DeepPath = struct {
    elems: [max_deep_ref_depth]PathElem = [_]PathElem{.{}} ** max_deep_ref_depth,
    len: u8 = 0,
};

/// Sentinel `RefKey.sym` for `this`-rooted property paths.
pub const this_flow_root: SymbolId = std.math.maxInt(SymbolId);

/// Base of the sentinel `RefKey.sym` range for OBJECT-BINDING-PATTERN
/// pseudo-references — tsc's `getNarrowedTypeOfSymbol`, which narrows the
/// destructured *parent* (`function f({ kind, data }: A | B)`) by a guard on
/// one binding and then re-projects the requested binding out of the narrowed
/// union. tsc uses the pattern node itself as the reference; ztsc's `RefKey`
/// is rooted at a `SymbolId`, so the declaration is interned into
/// `pattern_root_decls` and its index rides in this reserved range.
///
/// The range sits a megabyte below `this_flow_root`, i.e. above every real,
/// merged and fresh-type-param id (`fresh_tp_base` is the total symbol count
/// and grows upward from it); `patternRoot` refuses to mint when the two
/// spaces would meet, so the encoding can never alias a real symbol. Every
/// `key.sym` consumer that would dereference a real symbol tests
/// `isPatternRoot` first, exactly as it already tests `this_flow_root`.
pub const pattern_root_base: SymbolId = std.math.maxInt(SymbolId) - (1 << 20);

/// Is this a sentinel root (`this`, or a binding pattern) rather than a real
/// symbol? Guards every `symFlags`/`symFile`/`declsOf` read in a flow walk.
pub inline fn isPseudoRoot(sym: SymbolId) bool {
    return sym >= pattern_root_base;
}

/// A flow-cache query key, packed into one u64:
///   high 32 = the program-global flow id (`flow_base[file] + flow`),
///   low  32 = the dense `ref_keys` index of `(reference, declared)`.
///
/// Both halves are dense u32 counters, so the packing is a bijection on
/// the old `(file, flow, ref, declared)` tuple — no key can alias another.
/// Folding `declared` into the interned reference (rather than carrying it
/// as a fourth field) is what makes the tuple fit: `declared` is a function
/// of the reference in all but a handful of cases (measured on the dogfood project:
/// 50 771 distinct `(ref, declared)` pairs vs 50 718 distinct refs), so it
/// costs ~0.1% more `ref_keys` entries and saves 8 bytes on every one of
/// the ~1.8 M flow-cache slots.
pub const FlowQ = u64;
/// The `ref_keys` interning key: a reference *plus* the declared type it
/// was queried with (see `FlowQ`).
pub const RefQ = struct { key: RefKey, declared: TypeId };
pub const SymLoop = struct { sym: SymbolId, scope: ScopeId };

/// One in-progress loop-label query (tsc's `flowLoopNodes` /
/// `flowLoopKeys` / `flowLoopTypes` stack). `parts` points at the live
/// antecedent-type list of the `flowTypeInner` frame that owns the label,
/// so a re-entrant query reads the union computed *so far*.
pub const LoopFrame = struct { q: FlowQ, parts: *std.ArrayList(TypeId) };

/// Assemble the key for `root.elems[0].elems[1]…` (innermost first),
/// interning the link sequence when it is too deep to store inline. Null
/// when the overflow table is full — the reference is then simply not
/// tracked, the same sound under-narrowing as an over-deep path. The
/// refusal is memoized under the path itself, so which paths are tracked
/// never depends on how often one is rebuilt.
pub fn makeRefKey(c: *Checker, sym: SymbolId, elems: []const PathElem) Error!?RefKey {
    std.debug.assert(elems.len <= max_deep_ref_depth);
    var key: RefKey = .{ .sym = sym, .len = @intCast(elems.len) };
    if (elems.len <= max_ref_depth) {
        @memcpy(key.path[0..elems.len], elems);
        return key;
    }
    var dp: DeepPath = .{ .len = @intCast(elems.len) };
    @memcpy(dp.elems[0..elems.len], elems);
    const gop = try c.deep_path_ids.getOrPut(c.cm(), dp);
    if (!gop.found_existing) {
        if (c.deep_path_list.items.len >= std.math.maxInt(u16)) {
            gop.value_ptr.* = 0;
        } else {
            try c.deep_path_list.append(c.cm(), dp);
            gop.value_ptr.* = @intCast(c.deep_path_list.items.len);
        }
    }
    if (gop.value_ptr.* == 0) return null;
    key.deep = gop.value_ptr.*;
    return key;
}

/// The reference's links, innermost first. An inline path is returned in
/// place (hence the `*const` key: the slice points into the caller's own
/// storage); a deep one is copied into `buf` rather than handed out as a
/// view of `deep_path_list`, which a later `makeRefKey` may reallocate.
pub fn refPath(c: *const Checker, key: *const RefKey, buf: *[max_deep_ref_depth]PathElem) []const PathElem {
    if (key.deep == 0) return key.path[0..key.len];
    @memcpy(buf[0..key.len], c.deep_path_list.items[key.deep - 1].elems[0..key.len]);
    return buf[0..key.len];
}

pub fn refKeyIndex(c: *Checker, key: RefKey, declared: TypeId) Error!u32 {
    const gop = try c.ref_keys.getOrPut(c.cm(), .{ .key = key, .declared = declared });
    if (!gop.found_existing) gop.value_ptr.* = @intCast(c.ref_keys.count());
    return gop.value_ptr.*;
}

/// A constant, non-negative integer element-access index (`arr[0]`), else
/// null. A variable/expression index (`arr[i]`) is not a stable reference,
/// so it is untracked (sound under-narrowing). The 4096 bound matches the
/// tuple-index ceiling used by `indexChainInner`.
pub fn constIndexOf(c: *Checker, rhs: Node) ?u32 {
    var n = rhs;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    if (c.nodeTag(n) != .number_literal) return null;
    const v = c.numberTokenValue(c.tree.nodeMainToken(n));
    if (v < 0 or v != @floor(v) or v >= 4096) return null;
    return @intFromFloat(v);
}

/// The value symbol of a *stable* identifier element-access index
/// (`ICON_BY_TAG[tag]`), else null. This is tsc's `isMatchingReference`
/// element-access arm: two element accesses spelled with the same
/// identifier denote the same reference when that identifier's symbol is
/// `isConstantVariable` — a `const` — or `isParameterOrMutableLocalVariable
/// && !isSymbolAssigned` — a parameter or a `let`/`var`/catch local that is
/// never assigned. Anything else (a reassigned local, a property, a call
/// result, a computed expression) leaves the reference untracked, which is
/// sound under-narrowing.
///
/// Order-independent: `const`ness is a declaration flag, and the
/// never-assigned test reads `reassigned_syms`, a pure function of one
/// file's AST (`ensureReassignScan`). Because that table is only populated
/// for files already scanned, the non-`const` case is restricted to symbols
/// declared in the file being checked — otherwise the answer would depend
/// on which files had been visited, which is exactly the order-dependence
/// the determinism contract forbids. The same restriction guards the
/// closure-crossing arm of `flowType`.
pub fn stableIndexSymbol(c: *Checker, rhs: Node) Error!?SymbolId {
    var n = rhs;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    if (c.nodeTag(n) != .identifier) return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(n));
    var sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    if (sym == binder.no_symbol) return null;
    // An IMPORTED key is the normal spelling of this idiom — outline declares
    // `export const PAGINATION_SYMBOL = Symbol.for("pagination")` in one file
    // and guards `users[PAGINATION_SYMBOL]` in another. tsc resolves the index
    // through aliases before its `isConstVariable` test
    // (`tryGetNameFromEntityNameExpression` → `resolveEntityName`), so an
    // import binding must land on the declaration it names — both because the
    // local alias carries none of the flags below, and because keying the path
    // on the TARGET makes the two spellings name one reference.
    var hops: u8 = 0;
    while (c.symFlags(sym).import_binding) : (hops += 1) {
        if (hops >= 8) return null; // re-export cycle: untracked
        const tgt = c.importTarget(sym) orelse return null;
        if (tgt.kind != .binding) return null; // a namespace object, not a value
        sym = c.toGlobalIn(tgt.file, tgt.payload);
    }
    if (!PathElem.symFits(sym)) return null;
    const sf = c.symFlags(sym);
    if (sf.const_decl) return sym;
    if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;
    return sym;
}

/// A STRING-literal element-access key read as a member name: `o["a-b"]`
/// names the property `a-b`, exactly as `o.a` names `a`. This is tsc's
/// `getAccessedPropertyName`, whose element-access arm accepts a
/// string-literal argument and answers the same `__String` a dotted access
/// does. Null for any other index expression.
fn stringKeyAtom(c: *Checker, rhs: Node) Error!?Atom {
    var n = rhs;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .string_literal => return try c.memberAtom(c.tree.nodeMainToken(n)),
        // A NO-SUBSTITUTION template names a property too (tsc's
        // `getAccessedPropertyName` accepts `isStringOrNumericLiteralLike`,
        // which covers `NoSubstitutionTemplateLiteral`): `val[`kind`]` is the
        // `kind` discriminant.
        .template_literal => {
            const text = c.tokenText(c.tree.nodeMainToken(n));
            if (text.len < 2 or text[0] != '`' or text[text.len - 1] != '`') return null;
            return try c.atom(text[1 .. text.len - 1]);
        },
        else => return null,
    }
}

/// The path link an access node contributes, or null when it is not a stable
/// one (a computed index, an unfoldable payload) — in which case the caller
/// stops tracking the reference.
///
/// A string-literal element access yields the same `.member` link the dotted
/// spelling does, which is what makes `s["kind"]` and `s.kind` ONE reference:
/// tsc's `isMatchingReference` compares accessed property NAMES, so a
/// discriminant written either way narrows reads written the other way, and a
/// write through either spelling invalidates both.
pub fn pathElemOfAccess(c: *Checker, node: Node) Error!?PathElem {
    const d = c.tree.nodeData(node);
    switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr => {
            const ma = try c.memberAtom(d.rhs);
            if (!PathElem.memberFits(ma)) return null;
            return .member(ma);
        },
        .index_expr, .optional_index_expr => {
            if (c.constIndexOf(d.rhs)) |iv| return .element(iv);
            if (try stringKeyAtom(c, d.rhs)) |a| {
                if (!PathElem.memberFits(a)) return null;
                return .member(a);
            }
            if (try c.stableIndexSymbol(d.rhs)) |is| return .elementSym(is);
            return null;
        },
        else => return null,
    }
}

/// Build the tracked reference key for a member/element-access node by
/// peeling its spine right-to-left, collecting dotted-member atoms and
/// constant element indices, until it bottoms out at a bare identifier
/// (resolved to a value symbol) or `this`. Returns null when the root is
/// neither (call result, non-constant index, etc.) or the path is deeper
/// than `max_deep_ref_depth` (untracked = sound under-narrowing).
pub fn buildRefKey(c: *Checker, node: Node) Error!?RefKey {
    var elems: [max_deep_ref_depth]PathElem = [_]PathElem{.{}} ** max_deep_ref_depth;
    var count: usize = 0;
    var n = node;
    while (true) {
        n = peelTransparent(c, n);
        const tag = c.nodeTag(n);
        if (tag != .member_expr and tag != .optional_member_expr and
            tag != .index_expr and tag != .optional_index_expr) break;
        if (count >= max_deep_ref_depth) return null; // too deep: not tracked
        // Null = an unstable index or an unfoldable atom: not tracked.
        elems[count] = (try pathElemOfAccess(c, n)) orelse return null;
        count += 1;
        n = c.tree.nodeData(n).lhs;
    }
    // `n` is the root. A bare identifier must resolve to a value symbol
    // (skip the `undefined` keyword, which is not a reference); `this`
    // uses the sentinel root.
    var root: SymbolId = 0;
    if (c.nodeTag(n) == .identifier) {
        const base_tok = c.tree.nodeMainToken(n);
        if (c.tree.tokens.tag(base_tok) == .keyword_undefined) return null;
        const a = try c.atomOfToken(base_tok);
        switch (c.resolveSpace(a, c.cur_scope, true)) {
            .sym => |sym| root = sym,
            else => return null,
        }
    } else if (c.nodeTag(n) == .this_expr) {
        root = this_flow_root;
    } else return null;
    // Links were collected outermost-first; reverse so `path[0]` is the
    // innermost link (closest to the root).
    std.mem.reverse(PathElem, elems[0..count]);
    return c.makeRefKey(root, elems[0..count]);
}

/// tsc's `getReferenceCandidate`: the expression a narrowing condition is
/// really *about*. Parentheses are transparent; an assignment stands in for
/// its target, so `while ((m = next()) !== null)` narrows `m`; and a comma
/// expression stands in for its right operand. Without this the whole
/// assign-in-a-condition idiom narrowed nothing and every use inside the
/// body kept the nullable declared type.
/// The wrappers a reference is the same reference THROUGH: parentheses, a
/// non-null assertion, and a `satisfies`. tsc peels all three in
/// `isMatchingReference` and in `getFlowCacheKey`, so `working.thing!.name` is
/// the same flow reference as `working.thing.name` and a guard written on one
/// narrows the other. Without the `!` the spine walk stopped at the assertion
/// and the whole reference went untracked, so `if (working.thing!.name !==
/// "Correct")` discriminated nothing and both branches read the full union
/// (`narrowingUnionWithBang`).
///
/// `as` is deliberately NOT here: an `as` changes the type a read answers, and
/// tsc does not treat it as the same reference either.
fn peelTransparent(c: *Checker, node: Node) Node {
    var n = node;
    while (true) {
        switch (c.nodeTag(n)) {
            .paren_expr, .non_null, .satisfies_expr => {
                const inner = c.tree.nodeData(n).lhs;
                if (inner == null_node) return n;
                n = inner;
            },
            else => return n,
        }
    }
}

pub fn referenceCandidate(c: *Checker, node0: Node) Node {
    var n = node0;
    while (n != null_node) {
        switch (c.nodeTag(n)) {
            .paren_expr, .non_null, .satisfies_expr => {
                const inner = c.tree.nodeData(n).lhs;
                if (inner == null_node) return n;
                n = inner;
            },
            .assign => switch (c.tree.tokens.tag(c.tree.nodeMainToken(n))) {
                .eq, .pipe_pipe_eq, .amp_amp_eq, .question_question_eq => n = c.tree.nodeData(n).lhs,
                else => return n,
            },
            .seq_expr => n = c.tree.nodeData(n).rhs,
            else => return n,
        }
    }
    return n;
}

/// Does `node` denote exactly this reference? Peels the member/element
/// spine right-to-left, matching each link against the key's path
/// (outermost = `path[len-1]`), and bottoms out at the root identifier /
/// `this`.
pub fn refMatches(c: *Checker, node: Node, key: RefKey) Error!bool {
    var buf: [max_deep_ref_depth]PathElem = undefined;
    return c.refMatchesPath(node, key.sym, c.refPath(&key, &buf));
}

/// `refMatches` against an explicit link sequence, so a caller holding a
/// path (`refPrefixWritten`) can test a prefix without interning it.
pub fn refMatchesPath(c: *Checker, node: Node, sym: SymbolId, path: []const PathElem) Error!bool {
    if (node == null_node) return false;
    var n = c.referenceCandidate(node);
    if (path.len == 0) return c.identIsSym(n, sym);
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        n = c.referenceCandidate(n);
        // One link, read the same way `buildRefKey` wrote it — which is what
        // lets the two spellings of a property access (`s.kind`, `s["kind"]`)
        // match each other.
        const got = (try pathElemOfAccess(c, n)) orelse return false;
        if (got.bits != path[i - 1].bits) return false;
        n = c.tree.nodeData(n).lhs;
    }
    // The ROOT is parenthesizable too (`(this).test`, `(obj).kind` — the shape
    // Angular's generated type-check blocks write), and `identIsSym` matches a
    // bare node. `buildRefKey` peels at the top of its own loop, so without
    // this the two disagreed on exactly these spellings.
    n = c.referenceCandidate(n);
    return c.identIsSym(n, sym);
}

/// Is `target` a proper prefix of the tracked reference `key`? Writing any
/// prefix (the root, or `root.path[0..k]` for `k < len`) invalidates the
/// whole subtree's narrowing.
pub fn refPrefixWritten(c: *Checker, target: Node, key: RefKey) Error!bool {
    if (key.len == 0) return false;
    var buf: [max_deep_ref_depth]PathElem = undefined;
    const path = c.refPath(&key, &buf);
    var k: usize = 0;
    while (k < path.len) : (k += 1) {
        if (try c.refMatchesPath(target, key.sym, path[0..k])) return true;
    }
    return false;
}

/// Is narrowing worth running for this declared type? `any` *is* narrowable
/// — tsc's `narrowTypeByTypeof` opens with `isTypeAny(type)` and its
/// `Array.isArray`/type-predicate guards apply to it too, so
/// `if (typeof d !== "string") return undefined; return d;` on `d: any`
/// returns `string | undefined`, not `any`. Only the types no guard can
/// refine stay out (`assignmentReduced` already leaves an `any` declared
/// type alone, so an assignment still cannot narrow it).
pub fn isNarrowable(c: *Checker, declared: TypeId) bool {
    return switch (c.ts.kind(declared)) {
        .err, .never, .void, .none => false,
        else => true,
    };
}

// `PathElem`'s three payload forms share one u32 (see its doc comment), so
// the pack/unpack pair is the one invariant here that can be checked without
// a `Checker` at all.

test "PathElem packs a dotted member as the untagged payload" {
    const pe = PathElem.member(7);
    try std.testing.expect(!pe.isIndex());
    try std.testing.expect(!pe.isIndexSym());
    try std.testing.expectEqual(@as(Atom, 7), pe.atom());
    // A member of atom 0 must be the all-zero default, so unused `RefKey`
    // path slots hash canonically.
    try std.testing.expectEqual(@as(u32, 0), PathElem.member(0).bits);
    try std.testing.expectEqual(@as(u32, 0), (PathElem{}).bits);
}

test "PathElem keeps element and identifier indices distinct" {
    const el = PathElem.element(4095);
    try std.testing.expect(el.isIndex());
    try std.testing.expect(!el.isIndexSym());
    try std.testing.expectEqual(@as(u32, 4095), el.index());

    const sym = PathElem.elementSym(4095);
    try std.testing.expect(sym.isIndex());
    try std.testing.expect(sym.isIndexSym());
    try std.testing.expectEqual(@as(SymbolId, 4095), sym.indexSym());
    // Same payload, different form: the two must not collide.
    try std.testing.expect(el.bits != sym.bits);

    try std.testing.expect(PathElem.memberFits(PathElem.payload_max));
    try std.testing.expect(!PathElem.memberFits(PathElem.payload_max + 1));
    try std.testing.expect(PathElem.symFits(PathElem.payload_max));
    try std.testing.expect(!PathElem.symFits(PathElem.sym_tag));
}
