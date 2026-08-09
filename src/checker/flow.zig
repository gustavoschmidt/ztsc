//! Control-flow narrowing and definite assignment.
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
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Interner = intern.Interner;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const FlowId = binder.FlowId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const check = checker_zig.check;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const atom = Checker.atom;
const checkDeclarator = @import("stmts.zig").checkDeclarator;
const checkIdentifier = @import("expr.zig").checkIdentifier;
const classInstanceGeneric = @import("instantiate.zig").classInstanceGeneric;
const classStaticType = @import("enums.zig").classStaticType;
const expandRef = @import("instantiate.zig").expandRef;
const findBindingType = @import("signatures.zig").findBindingType;
const indexChainInner = @import("expr.zig").indexChainInner;
const inferReturnType = @import("signatures.zig").inferReturnType;
const init = Checker.init;
const isInstantiableKind = @import("expr.zig").isInstantiableKind;
const lazyRefProp = @import("instantiate.zig").lazyRefProp;
const lazy_base_depth = @import("instantiate.zig").lazy_base_depth;
const propOfType = @import("props.zig").propOfType;
const reduceSubtypes = @import("typenode.zig").reduceSubtypes;
const refExpansionActive = @import("instantiate.zig").refExpansionActive;
const run = Checker.run;
const typeOfSymbol = @import("signatures.zig").typeOfSymbol;
const typeof_names = Checker.typeof_names;

// =====================================================================
// control-flow narrowing
// =====================================================================

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

pub inline fn isPatternRoot(sym: SymbolId) bool {
    return sym >= pattern_root_base and sym != this_flow_root;
}

/// Is this a sentinel root (`this`, or a binding pattern) rather than a real
/// symbol? Guards every `symFlags`/`symFile`/`declsOf` read in a flow walk.
pub inline fn isPseudoRoot(sym: SymbolId) bool {
    return sym >= pattern_root_base;
}

/// Intern `decl` (a parameter or declarator whose name is an object binding
/// pattern) as a pseudo-reference root. Null when the sentinel range is
/// exhausted or would collide with the fresh-type-param space — the reference
/// is then simply not tracked (sound under-narrowing).
pub fn patternRoot(c: *Checker, decl: Node) Error!?SymbolId {
    if (c.fresh_tp_base != 0 and c.fresh_tp_base >= pattern_root_base) return null;
    const gop = try c.pattern_root_ids.getOrPut(c.cm(), c.nodeKey(decl));
    if (!gop.found_existing) {
        if (c.pattern_root_decls.items.len >= this_flow_root - pattern_root_base) {
            _ = c.pattern_root_ids.remove(c.nodeKey(decl));
            return null;
        }
        try c.pattern_root_decls.append(c.cm(), c.nodeKey(decl));
        gop.value_ptr.* = @intCast(c.pattern_root_decls.items.len - 1);
    }
    return pattern_root_base + gop.value_ptr.*;
}

/// The `(file, node)` declaration a pattern pseudo-root stands for.
pub fn patternRootDecl(c: *const Checker, sym: SymbolId) u64 {
    return c.pattern_root_decls.items[sym - pattern_root_base];
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
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    if (sym == binder.no_symbol) return null;
    if (!PathElem.symFits(sym)) return null;
    const sf = c.symFlags(sym);
    if (sf.const_decl) return sym;
    if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;
    return sym;
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
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        const tag = c.nodeTag(n);
        const d = c.tree.nodeData(n);
        if (tag == .member_expr or tag == .optional_member_expr) {
            if (count >= max_deep_ref_depth) return null; // too deep: not tracked
            const ma = try c.memberAtom(d.rhs);
            if (!PathElem.memberFits(ma)) return null; // unfoldable atom: not tracked
            elems[count] = .member(ma);
        } else if (tag == .index_expr or tag == .optional_index_expr) {
            if (count >= max_deep_ref_depth) return null;
            if (c.constIndexOf(d.rhs)) |iv| {
                elems[count] = .element(iv);
            } else if (try c.stableIndexSymbol(d.rhs)) |is| {
                elems[count] = .elementSym(is);
            } else return null; // unstable index: untracked
        } else break;
        count += 1;
        n = d.lhs;
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
pub fn referenceCandidate(c: *Checker, node0: Node) Node {
    var n = node0;
    while (n != null_node) {
        switch (c.nodeTag(n)) {
            .paren_expr => n = c.tree.nodeData(n).lhs,
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
        const tag = c.nodeTag(n);
        const d = c.tree.nodeData(n);
        const pe = path[i - 1];
        if (pe.isIndexSym()) {
            if (tag != .index_expr and tag != .optional_index_expr) return false;
            const is = (try c.stableIndexSymbol(d.rhs)) orelse return false;
            if (is != pe.indexSym()) return false;
        } else if (pe.isIndex()) {
            if (tag != .index_expr and tag != .optional_index_expr) return false;
            const iv = c.constIndexOf(d.rhs) orelse return false;
            if (iv != pe.index()) return false;
        } else {
            if (tag != .member_expr and tag != .optional_member_expr) return false;
            if ((try c.memberAtom(d.rhs)) != pe.atom()) return false;
        }
        n = d.lhs;
    }
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

pub fn flowTypeOfReference(c: *Checker, node: Node, sym: SymbolId, declared: TypeId) Error!TypeId {
    return c.flowTypeOfKey(node, .{ .sym = sym }, declared);
}

/// The object binding pattern a declaration binds through, or null.
fn objectPatternOf(c: *Checker, decl: Node) ?Node {
    const pat: Node = switch (c.nodeTag(decl)) {
        .param, .param_full, .declarator, .declarator_init, .declarator_full => c.tree.nodeData(decl).lhs,
        else => return null,
    };
    if (pat == null_node or c.nodeTag(pat) != .object_pattern) return null;
    return pat;
}

/// The ANNOTATED type of a destructuring declaration's whole value —
/// tsc's `getTypeForBindingElementParent`, restricted to the annotated forms.
/// An unannotated parameter's type is contextual and an unannotated
/// declarator's comes from an initializer checked in another scope; leaving
/// both out keeps this a pure function of the declaration (so `--checkers=N`
/// partitions cannot disagree about it) at the cost of narrowing fewer
/// destructurings than tsc — sound under-narrowing either way.
fn patternParentType(c: *Checker, decl: Node) Error!TypeId {
    const d = c.tree.nodeData(decl);
    const ann: Node = switch (c.nodeTag(decl)) {
        // `.param` carries its (optional) annotation directly in `rhs`;
        // `.param_full` moves it into the side table with flags/initializer.
        .param => d.rhs,
        .param_full => c.tree.extraData(ast.ParamFull, d.rhs).type_ann,
        .declarator_full => c.tree.extraData(ast.DeclaratorFull, d.rhs).type_ann,
        else => null_node,
    };
    if (ann == null_node) return types.no_type;
    return c.typeFromTypeNode(ann);
}

/// The direct `binding_property` of `pat` that binds `name`, if it is one
/// tsc would let participate: no default (`{ a = 1 }` has an initializer),
/// no rest element, and a plain identifier target (a nested pattern's own
/// bindings are reached through their own declaration).
fn bindingPropertyFor(c: *Checker, pat: Node, name: Atom) Error!?Node {
    for (c.tree.nodeRange(pat)) |el| {
        if (el == null_node or c.nodeTag(el) != .binding_property) continue;
        const ed = c.tree.nodeData(el);
        if (ed.rhs != 0) continue; // has a default
        if (ed.lhs == 0) {
            if ((try c.memberAtom(c.tree.nodeMainToken(el))) == name) return el;
        } else if (c.nodeTag(ed.lhs) == .identifier) {
            if ((try c.atomOfToken(c.tree.nodeMainToken(ed.lhs))) == name) return el;
        }
    }
    return null;
}

/// tsc's `getNarrowedTypeOfSymbol`, binding-element arm.
///
/// `function f({ kind, data }: { kind: 'a', data: A } | { kind: 'b', data: B })`
/// destructures a discriminated union, and TS 4.6 lets a guard on one binding
/// narrow the others: `switch (kind) { case 'a': data /* A */ }`. Nothing in
/// the flow graph connects the two — they are separate symbols — so the union
/// itself is narrowed as a pseudo-reference rooted at the declaration
/// (`pattern_root_base`), with `discriminantOfRef` teaching the narrowers that
/// a bare identifier bound by that pattern reads the corresponding property;
/// the requested binding is then re-projected out of the narrowed parent by
/// the same `findBindingType` that produced its declared type.
///
/// Null when the shape does not qualify or the walk found nothing to narrow,
/// leaving the caller's declared type untouched.
pub fn narrowedPatternBinding(c: *Checker, node: Node, sym: SymbolId) Error!?TypeId {
    if (isPseudoRoot(sym) or c.isFreshTp(sym) or sym == binder.no_symbol) return null;
    const f = c.symFlags(sym);
    // tsc: a `const`-like binding only — a parameter with no assignment to it,
    // or a `const` declarator.
    if (!(f.param or f.const_decl)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return null;
    const decl = decls[0];
    const pat = objectPatternOf(c, decl) orelse return null;
    // tsc requires at least two elements: with one there is no sibling
    // discriminant to narrow by.
    if (c.tree.nodeRange(pat).len < 2) return null;
    const name = c.symNameAtom(sym);
    if ((try bindingPropertyFor(c, pat, name)) == null) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;

    const whole = try patternParentType(c, decl);
    if (whole == types.no_type) return null;
    const parent = try c.resolveStructural(whole);
    if (c.ts.kind(parent) != .union_type) return null;

    const busy_key = c.nodeKey(decl);
    if (c.pattern_narrow_busy.contains(busy_key)) return null;
    try c.pattern_narrow_busy.put(c.cm(), busy_key, {});
    defer _ = c.pattern_narrow_busy.remove(busy_key);

    const root = (try patternRoot(c, decl)) orelse return null;
    const narrowed = try c.flowTypeOfKey(node, .{ .sym = root }, parent);
    if (narrowed == parent) return null;
    if (c.ts.kind(narrowed) == .never) return types.never_type;
    var out: TypeId = types.no_type;
    if (!try c.findBindingType(pat, name, narrowed, &out, null)) return null;
    if (out == types.no_type) return null;
    return out;
}

/// Is `node` a bare identifier bound by the object pattern behind the
/// pseudo-root `key`, and if so which property does it read? (tsc's
/// `getCandidateDiscriminantPropertyAccess`, binding-pattern arm.)
fn patternDiscriminantTok(c: *Checker, node: Node, key: RefKey) Error!?TokenIndex {
    if (key.len != 0) return null;
    if (c.nodeTag(node) != .identifier) return null;
    const dk = patternRootDecl(c, key.sym);
    if (dk >> 32 != c.cur_file) return null;
    const decl: Node = @truncate(dk);
    const pat = objectPatternOf(c, decl) orelse return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    // The identifier must resolve to a binding of THIS pattern, and must not
    // be reassigned (tsc's `isParameterOrMutableLocalVariable && !isSymbolAssigned`).
    if (isPseudoRoot(sym) or c.isFreshTp(sym)) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1 or decls[0] != decl) return null;
    try c.ensureReassignScan();
    if (c.reassigned_syms.contains(sym)) return null;
    const el = (try bindingPropertyFor(c, pat, a)) orelse return null;
    // `binding_property`'s main token is the PROPERTY name in both the
    // shorthand (`{ kind }`) and the renamed (`{ kind: k }`) form.
    return c.tree.nodeMainToken(el);
}

pub fn flowTypeOfKey(c: *Checker, node: Node, key: RefKey, declared: TypeId) Error!TypeId {
    var t = declared;
    if (c.isNarrowable(declared)) {
        if (c.bind.flowAt(node)) |flow| {
            c.stats.flow_queries += 1;
            t = try c.flowType(flow, key, declared, 0);
            // The tail of tsc's `getFlowTypeOfReference`. tsc has *two*
            // `never`s: the ordinary one a guard narrows a reference down to,
            // and `unreachableNeverType`, which is what the walk answers when
            // it bottoms out in code no control path reaches. Only the first
            // is a type anyone may observe — for the second the DECLARED type
            // is handed back, which is why `function f(x: string) { return 1;
            //   x.length; }` is silent while an exhausted union's dead branch
            // reports TS2339. ztsc computes both with the one `never_type`,
            // so the distinction is drawn here, by asking the graph whether
            // the reference's own flow node is reachable at all.
            if (c.ts.kind(t) == .never and !try c.flowReachable(flow)) t = declared;
        }
    }
    return c.applyChainGuards(key, t);
}

/// tsc's `isReachableFlowNode`. Only asked on a `never` answer (a fraction of
/// a percent of queries), so the memo is there to bound a pathological graph
/// rather than to carry a hot path.
pub fn flowReachable(c: *Checker, flow: FlowId) Error!bool {
    if (flow == binder.no_flow) return true;
    if (flow == binder.unreachable_flow) return false;
    const cache_key = c.cur_flow_base + flow;
    // 0 = in flight. A cycle can only close through a loop label, whose
    // *entry* edge is the one edge walked, so this is defensive only;
    // answering "reachable" keeps it on the non-suppressing side.
    if (c.flow_reach.get(cache_key)) |v| return v != 1;
    try c.flow_reach.put(c.cm(), cache_key, 0);
    const r = try flowReachableInner(c, flow);
    try c.flow_reach.put(c.cm(), cache_key, if (r) 2 else 1);
    return r;
}

fn flowReachableInner(c: *Checker, flow: FlowId) Error!bool {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none, .start => return true,
        .unreachable_ => return false,
        .branch_label => {
            for (b.flowAntecedents(flow)) |a| {
                if (try c.flowReachable(a)) return true;
            }
            return false;
        },
        // Only the entry edge: a loop's back edges are reachable exactly
        // when the head is, so following them would answer with itself.
        .loop_label => {
            const antes = b.flowAntecedents(flow);
            if (antes.len == 0) return false;
            return c.flowReachable(antes[0]);
        },
        // tsc's Call arm: a call statement whose signature returns `never`
        // (`invariant(false)`, `fail(msg): never`) ends the flow — the
        // statements after it are dead, and a reference read there is back
        // at its declared type.
        .call_stmt => {
            if (try callStmtReturnsNever(c, flow)) return false;
            return c.flowReachable(b.flow_a[flow]);
        },
        // A `switch_no_match` edge is deliberately NOT tested for
        // exhaustiveness here: the fall-out of an exhaustive `switch` is
        // where tsc reports `never` on the discriminant, so it must stay
        // "reachable" and let the narrowed `never` through.
        else => return c.flowReachable(b.flow_a[flow]),
    }
}

/// Does the call statement behind `flow` return `never`? Resolved from the
/// callee's DECLARED (or already-memoized) type only — `never` is not a
/// return type inference produces for a declaration, and re-checking a
/// callee from inside a flow query is the re-entrancy `guardCallOf`'s header
/// note documents.
fn callStmtReturnsNever(c: *Checker, flow: FlowId) Error!bool {
    return callReturnsNever(c, c.bind.flowNode(flow));
}

/// The same question asked of a call NODE, so consumers with no flow node to
/// hand can ask it too (`stmtTerminal`'s endpoint analysis).
///
/// Resolving the callee needs the scope it was WRITTEN in, and neither caller
/// has it: a flow walk runs at the querying reference's scope, and
/// `stmtTerminal` recurses into nested blocks from the body's. The binder
/// attaches a flow entry to every identifier and member read
/// (`bindIdentifierRef` / `bindExpr`), and `flowScope` on that entry is
/// exactly the scope wanted — reading it here is what keeps a callee declared
/// in an inner block (`const render = () => …; … render();`) from resolving
/// against the function scope, where the name does not exist and
/// `checkExprCached` would report a phantom TS2304.
pub fn callReturnsNever(c: *Checker, call: Node) Error!bool {
    if (call == null_node) return false;
    const callee = c.callShape(call).callee;
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (c.bind.flowAt(callee)) |f| c.cur_scope = c.bind.flowScope(f);
    const callee_t = switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.nodeType(callee) orelse
            try c.declaredPathType(callee),
        .identifier => if (c.calleeNeedsExplicitDecl(callee))
            c.nodeType(callee) orelse try c.declaredPathType(callee)
        else
            try c.checkExprCached(callee, types.no_type),
        else => return false,
    };
    if (callee_t == types.no_type) return false;
    const sig = (try c.lastCallSig(callee_t)) orelse return false;
    return c.ts.kind(c.ts.fnReturn(sig)) == .never;
}

/// The binder binds optional chains linearly (see its header note), so the
/// non-nullish branch a `?.` opens is not a flow node. tsc's binder splits
/// it — `a?.b?.[i]` binds as `a && a.b && a.b[i]`, with the index
/// expression bound under the accumulated true-branch — which is what makes
/// `updates?.points?.[updates?.points?.length - 1]` legal: inside the
/// brackets, `updates` and `updates.points` are already known non-nullish,
/// so the inner chain does not re-add the short-circuit `undefined`.
///
/// `pushChainGuards` reconstructs exactly that condition set for the one
/// place it is observable in an expression checker — a subexpression the
/// chain evaluates only on the non-nullish branch — by walking the access
/// spine and recording the *object* of every `?.` link, which is precisely
/// the expression that link asserts. Only those objects are recorded, never
/// the whole spine: in `a?.b[i]` the sole assertion is on `a`, and treating
/// `a.b` as guarded too would swallow the TS18048 that a nullish `a.b`
/// owes the reads inside `i`.
pub fn pushChainGuards(c: *Checker, node: Node) Error!void {
    var n = node;
    while (true) {
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        const d = c.tree.nodeData(n);
        switch (c.nodeTag(n)) {
            .optional_member_expr, .optional_index_expr, .optional_call => {
                if (try c.buildRefKey(d.lhs)) |k| try c.chain_guards.append(c.cm(), k);
            },
            .member_expr, .index_expr, .call_expr, .call_expr_targs => {},
            else => return,
        }
        n = d.lhs;
    }
}

/// Non-nullish for a reference an enclosing chain has already guarded.
/// Applied *after* flow narrowing (and after the untracked-reference early
/// outs) so it composes with whatever the flow graph knows.
pub fn applyChainGuards(c: *Checker, key: RefKey, t: TypeId) Error!TypeId {
    if (c.chain_guards.items.len == 0) return t;
    for (c.chain_guards.items) |k| {
        if (std.meta.eql(k, key)) return c.nonNullableChain(t);
    }
    return t;
}

/// Is this query already on the walk stack (still being computed)? Only
/// asked on a `flow_same` hit under a back-edge walk, which is why a linear
/// scan of a push/pop stack is the right shape: a second hash map on the
/// `flowType` hot path measured +330 ms of check time on the dogfood app,
/// three times the whole flow phase.
pub fn flowInFlight(c: *const Checker, q: FlowQ) bool {
    var i: usize = c.flow_stack.items.len;
    while (i > 0) : (i -= 1) {
        if (c.flow_stack.items[i - 1] == q) return true;
    }
    return false;
}

pub fn flowType(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
    if (flow == binder.no_flow) return declared;
    if (flow == binder.unreachable_flow) return types.never_type;
    if (depth > 4000) return declared; // pathological chains: stay sound
    const q: FlowQ = (@as(u64, c.cur_flow_base + flow) << 32) | try c.refKeyIndex(key, declared);
    // tsc's `getTypeAtFlowLoopLabel` in-process check. Re-entering a loop
    // label that is still computing (the walk came back round the loop, or
    // an assignment's right-hand side reads the very reference the label is
    // resolving) answers with the union of the antecedent types gathered so
    // far — tsc's *incomplete* FlowType — not with the declared type. That
    // partial value is what makes the fixpoint converge for a self-reading
    // loop assignment (`x = x.replace(…)` under an `x !== undefined`
    // guard): the read sees the narrowed entry type instead of re-widening.
    if (c.flow_loop_stack.items.len != 0 and c.bind.flow_tags[flow] == .loop_label) {
        var i: usize = c.flow_loop_stack.items.len;
        while (i > 0) : (i -= 1) {
            const fr = &c.flow_loop_stack.items[i - 1];
            if (fr.q != q or fr.parts.items.len == 0) continue;
            return c.ts.makeUnion(c.scratch(), fr.parts.items);
        }
    }
    // `flow_same` covers both states that answer `declared`: a query still
    // in progress (the walk stack below) and a finished one that narrowed
    // nothing. `flow_narrow` holds the rest, and the two are disjoint.
    if (c.flow_same.contains(q)) {
        // Under a back-edge walk the two states are *not* interchangeable.
        // Every node between the re-entering reference and its loop label
        // is in flight (a `for..of`/`for..in` binding is itself an
        // assignment node, so there is always at least one), and answering
        // `declared` there swallows the partial the label is publishing —
        // the very widening this mechanism removes. Re-walk instead,
        // bounded, and memoize in `flow_tmp`. Everywhere else the old,
        // cheap answer stands: outside a back-edge walk there is no partial
        // for an in-flight node to swallow.
        if (c.flow_back_edge != 0 and c.flow_busy_depth < 4 and c.flowInFlight(q)) {
            if (c.flow_tmp.get(q)) |t| return t;
            c.flow_busy_depth += 1;
            defer c.flow_busy_depth -= 1;
            const r = try c.flowTypeInner(flow, key, declared, depth);
            try c.flow_tmp.put(c.cm(), q, r);
            return r;
        }
        return declared;
    }
    if (c.flow_narrow.get(q)) |t| return t;
    // Everything computed while a loop label's BACK edges are walked is
    // computed against the partial fixpoint that label publishes, so it is
    // only valid inside that walk: it goes to `flow_tmp` (dropped when the
    // outermost label finishes) and never to the persistent cache, which
    // therefore only ever holds answers taken against *finished* labels.
    //
    // Marking that positionally rather than tainting the values is what
    // makes it affordable: the label's own result is decided *outside* its
    // back-edge walk, so it is always cached. Propagating an incompleteness
    // bit up the walk instead — tsc's literal `isIncomplete` — keeps whole
    // nests of labels out of the cache, and each uncached label re-walks
    // back edges that re-check expressions that start fresh walks over the
    // same uncached labels: measured at three orders of magnitude.
    if (c.flow_back_edge != 0) {
        if (c.flow_tmp.get(q)) |t| return t;
    }
    // Mark in progress. If the result turns out to be `declared` this
    // entry *is* the final answer, so the common case never writes twice.
    try c.flow_same.put(c.cm(), q, {});
    try c.flow_stack.append(c.cm(), q);
    const result = try c.flowTypeInner(flow, key, declared, depth);
    _ = c.flow_stack.pop();
    if (c.flow_back_edge != 0) {
        _ = c.flow_same.remove(q);
        try c.flow_tmp.put(c.cm(), q, result);
        return result;
    }
    // `no_type` is not storable as a result (it was the old in-progress
    // sentinel and still reads back as "declared"); leaving such a result
    // in `flow_same` reproduces the previous behaviour exactly.
    if (result != declared and result != types.no_type) {
        _ = c.flow_same.remove(q);
        try c.flow_narrow.put(c.cm(), q, result);
    }
    return result;
}

pub fn flowTypeInner(c: *Checker, flow: FlowId, key: RefKey, declared: TypeId, depth: u32) Error!TypeId {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none => return declared,
        .start => {
            // A function/arrow body's start records its definition-point
            // flow as the antecedent. For a constant bare-identifier
            // reference captured by this closure, continue analysis in the
            // enclosing function so its narrowing is preserved (tsc narrows
            // `const`/effectively-const references across closures, but not
            // property paths, `this`, or reassignable variables). Namespace
            // and file starts have `no_flow` here and stop at `declared`.
            const ante = b.flow_a[flow];
            if (ante == binder.no_flow) return declared;
            // A closure whose textual definition point is unreachable (e.g. a
            // hoisted `function` declared after a `return`) can still be
            // invoked — its body runs in a fresh reachable context. Crossing
            // into the unreachable definition-point flow would yield `never`
            // for a captured reference, which then makes a property *write*
            // target (`ref.current = x`) spuriously collapse to `never` (a
            // read to `never` is silently accepted, so only writes surface it).
            // Use the declared type instead: there is no valid narrowing at an
            // unreachable definition point.
            if (ante == binder.unreachable_flow) return declared;
            // Property paths, `this` and binding-pattern pseudo-roots never
            // continue into an enclosing function's flow.
            if (key.len != 0 or isPseudoRoot(key.sym)) return declared;
            // Only a reference *captured* by this closure may continue into
            // the definition-point flow. A reference to something the
            // closure declares itself (its parameters, its own locals) is
            // not captured — tsc's `checkIdentifier` only walks out to an
            // enclosing container when the declaration container differs
            // from the reference's. Crossing anyway put the closure's own
            // symbol into the enclosing function's flow, where
            // `assignNarrows` matches a declarator by NAME
            // (`patternBindsSym`): a same-named outer `const d: string`
            // then narrowed an `unknown`-typed parameter `d` to `string`.
            // (Only visible for a declared type `assignmentRefines` accepts,
            // which is why `unknown` parameters were the reported shape.)
            if (c.symFile(key.sym) == c.cur_file) {
                const own = c.containerOf(c.bind.symbol_scopes[c.localOf(key.sym)]);
                if (c.bind.scope_owners[own] == b.flowNode(flow)) return declared;
            }
            const sf = c.symFlags(key.sym);
            if (!sf.const_decl) {
                // Effectively-const let/var/param: tsc narrows a captured
                // reference across a closure like a `const` when the variable
                // is a mutable *local* that is never reassigned (matching
                // tsc's `isParameterOrMutableLocalVariable` + the
                // function-expression/arrow container walk in
                // `checkIdentifier`). Excluded, so the declared type stands:
                //   • non let/var/param/catch symbols,
                //   • module/global top-level or exported variables — a
                //     top-level `let` may be reassigned by any function, so
                //     tsc never trusts the narrowing across a closure (a
                //     top-level `const` still does, via the const path above),
                //   • the crossed closure being a *function declaration*
                //     (only function-expression/arrow/method containers extend
                //     the flow — a hoisted `function` captures at its
                //     definition point, before any guard),
                //   • reassignment anywhere (conservative vs tsc's
                //     position-based `lastAssignmentPos`; only ever
                //     under-narrows, never a new false positive).
                if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return declared;
                if (sf.exported) return declared;
                if (c.symFile(key.sym) != c.cur_file) return declared;
                const decl_scope = c.bind.symbol_scopes[c.localOf(key.sym)];
                if (c.bind.scope_kinds[c.containerOf(decl_scope)] != .function) return declared;
                switch (c.nodeTag(b.flowNode(flow))) {
                    .arrow_fn, .function_expr, .object_method, .class_method => {},
                    else => return declared, // function declaration etc.
                }
                try c.ensureReassignScan();
                if (c.reassigned_syms.contains(key.sym)) return declared;
            }
            return c.flowType(ante, key, declared, depth + 1);
        },
        .unreachable_ => return types.never_type,
        .assign => {
            const target = b.flowNode(flow);
            const ante = b.flow_a[flow];
            // Re-evaluating the initializer/rhs resolves names in the scope
            // where the assignment lives, not the reference's query scope.
            {
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                c.cur_scope = b.flowScope(flow);
                if (try c.assignNarrows(target, key, declared)) |narrowed| {
                    return narrowed;
                }
            }
            return c.flowType(ante, key, declared, depth + 1);
        },
        .cond_true, .cond_false => {
            const cond = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const before = try c.flowType(ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            const sense = b.flow_tags[flow] == .cond_true;
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return c.narrowByCondition(before, cond, sense, key, declared);
        },
        .switch_clause => {
            const clause = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const before = try c.flowType(ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return c.narrowBySwitchClause(before, clause, key, declared);
        },
        .switch_no_match => {
            const sw = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            // An exhaustive `default`-less switch cannot fall out of its
            // clause list, so this edge does not exist.
            if (c.switchIsExhaustive(sw)) return types.never_type;
            return c.flowType(ante, key, declared, depth + 1);
        },
        .call_stmt => {
            const call = b.flowNode(flow);
            const ante = b.flow_a[flow];
            const before = try c.flowType(ante, key, declared, depth + 1);
            if (before == types.never_type) return before;
            // The assertion callee is re-checked here; resolve it in the
            // scope where the call statement lives (it may be reached via a
            // loop back-edge from a shallower query scope).
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            return c.narrowByAssertCall(before, call, key, declared);
        },
        .branch_label, .loop_label => {
            const antes = b.flowAntecedents(flow);
            // A loop label whose reference is *never assigned inside the
            // loop* keeps its pre-loop narrowing across the whole loop body
            // (tsc `getTypeAtFlowLoopLabel`: a reference only re-widens at a
            // back edge when the loop actually assigns it). The binder builds
            // a loop label with antecedent[0] = the pre-loop entry edge and
            // [1..] = back edges / `continue` jumps. For an unassigned simple
            // reference the type is invariant around the loop, so its type at
            // the label is exactly the entry type — take antecedent[0] alone
            // and skip the back edges. This both preserves the narrowing
            // (ztsc previously widened to `declared` at the in-progress back
            // edge, dropping every loop-crossing narrowing — `x: T | null`
            // guarded by an early return re-acquired `| null` inside a
            // following `for`/`while`) and avoids poisoning the flow cache
            // with an under-approximation while the label is in progress.
            // "Assigned inside this loop" is exact for `for/for..of/for..in`
            // (see `reassigned_in_loop` below) and a sound over-approximation
            // (file-level `reassigned_syms`) for `while`/`do`.
            // Loop-header bindings (a `for..of` element is not in the
            // reassignment scan yet is re-bound every iteration) and property
            // paths keep the full union-over-all-antecedents behavior.
            //
            // The shortcut fires *only when the pre-loop entry is actually
            // narrower than the declared type* — i.e. there is a narrowing to
            // preserve. When the entry equals `declared` the reference is
            // un-narrowed and the ordinary union path (which re-walks the back
            // edges and, in doing so, populates the flow cache exactly as
            // before) reproduces the pre-fix result byte-for-byte. This keeps
            // the change surgical: it can only ever *retain* a narrowing that
            // the old code dropped, never perturb the cache interaction of a
            // reference that was never narrowed before the loop (which would
            // otherwise unmask unrelated latent FPs downstream).
            if (b.flow_tags[flow] == .loop_label and antes.len >= 1 and
                !isPatternRoot(key.sym) and !c.symDeclaredInForHead(key.sym))
            {
                try c.ensureReassignScan();
                // "Assigned inside *this* loop" is the exact tsc predicate. A
                // `for`/`for..of`/`for..in` label's own scope is the loop's
                // `.for_head`, so a symbol assigned before the loop but never
                // inside it (`let x; …; x = f(); if(!x) return; for(…) use(x)`)
                // keeps its narrowing. `while`/`do` push no header scope, so
                // there the coarse file-level "reassigned anywhere" test is
                // used (sound: an assignment inside the loop always lands in
                // the file scan → never keeps a mutated narrowing).
                // A property path (`key.len != 0`) additionally re-widens if
                // ANY member/element write rooted at the same symbol occurs
                // inside the loop (the root reassign test alone misses
                // `o.p = …`). The property-name is not distinguished — a
                // write to any property of the root blocks the shortcut,
                // which is sound (only ever fails to retain a narrowing).
                const loop_scope = b.flowScope(flow);
                const is_for = b.scope_kinds[loop_scope] == .for_head;
                const root_assigned = if (is_for)
                    c.reassigned_in_loop.contains(.{ .sym = key.sym, .scope = loop_scope })
                else
                    c.reassigned_syms.contains(key.sym);
                const member_written = key.len != 0 and (if (is_for)
                    c.member_written_in_loop.contains(.{ .sym = key.sym, .scope = loop_scope })
                else
                    c.member_written_syms.contains(key.sym));
                const assigned_in_loop = root_assigned or member_written;
                if (!assigned_in_loop) {
                    const entry_t = try c.flowType(antes[0], key, declared, depth + 1);
                    if (entry_t != declared) return entry_t;
                }
            }
            var parts: std.ArrayList(TypeId) = .empty;
            defer parts.deinit(c.scratch());
            // The binder lays a loop label out as antecedent[0] = the
            // non-looping entry edge and [1..] = the back edges. tsc walks
            // the entry edge first, then publishes the partial union on the
            // in-process stack while it walks the back edges, so any query
            // that comes back round to this label reads that partial
            // instead of the declared type (see `flowType`).
            const looping = b.flow_tags[flow] == .loop_label and antes.len > 1;
            var frame: usize = 0;
            var published = false;
            for (antes, 0..) |a, i| {
                // Publish only when the entry edge actually carries a
                // narrowing. With `parts[0] == declared` the partial union
                // *is* the declared type, so every answer it could give is
                // the answer the old in-progress sentinel already gave —
                // and skipping the publication keeps the re-walk (and the
                // suppressed expression memo below) off the overwhelming
                // majority of loops, which is what keeps the check phase
                // where it was.
                if (looping and i == 1 and parts.items.len != 0 and parts.items[0] != declared) {
                    published = true;
                    frame = c.flow_loop_stack.items.len;
                    const q: FlowQ = (@as(u64, c.cur_flow_base + flow) << 32) |
                        try c.refKeyIndex(key, declared);
                    // `parts` is scratch-backed and this publishes it where a
                    // deeper query can read it, so it is the one place in the
                    // checker that hands a scratch buffer sideways. It stays
                    // sound only because it is grown in THIS loop body alone,
                    // always after the recursive `flowType` below has fully
                    // unwound — i.e. always at this frame's own arena top,
                    // above every mark an inner expression takes — and because
                    // nested queries only read it. Growing it from anywhere
                    // reachable by a deeper frame would be a use-after-free.
                    try c.flow_loop_stack.append(c.cm(), .{ .q = q, .parts = &parts });
                    c.flow_back_edge += 1;
                    // Everything a back edge re-checks (an assignment's
                    // right-hand side, a guard call) is evaluated against
                    // the *partial* fixpoint, so its type must not be
                    // published as the node's answer — the authoritative
                    // check re-runs it against the finished label. tsc drops
                    // `flowTypeCache` around exactly this walk.
                    c.no_publish_depth += 1;
                }
                const t = try c.flowType(a, key, declared, depth + 1);
                if (t != types.never_type) try parts.append(c.scratch(), t);
            }
            if (published) {
                c.flow_loop_stack.shrinkRetainingCapacity(frame);
                c.flow_back_edge -= 1;
                c.no_publish_depth -= 1;
                // The partial answers only mean anything while some loop
                // fixpoint is in flight; once the outermost one finishes,
                // every query re-runs against the finished labels and lands
                // in the persistent cache.
                if (c.flow_back_edge == 0) c.flow_tmp.clearRetainingCapacity();
            }
            if (parts.items.len == 0) return types.never_type;
            const joined = try c.ts.makeUnion(c.scratch(), parts.items);
            // tsc joins the antecedents of an EVOLVING (`auto`-typed)
            // variable with `UnionReduction.Subtype`, so a branch that
            // assigns `{ appState: … }` and one that assigns the
            // all-optional `Init` collapse to `Init` instead of a union
            // whose first constituent lacks the other's properties. Without
            // it every later `v?.someProp` reported TS2339.
            if (key.len == 0 and !isPseudoRoot(key.sym) and c.isEvolvingVar(key.sym)) {
                return c.reduceEvolvingJoin(joined);
            }
            return joined;
        },
    }
}

/// Can the assigned value change the answer at all — i.e. can
/// `assignmentReduced(declared, …)` return anything but `declared`?
///
/// tsc's `getTypeAtFlowAssignment` states the rule outright: *"Assignments
/// only narrow the computed type if the declared type is a union type."*
/// Its assignment arm is `declaredType.flags & Union ?
/// getAssignmentReducedType(declaredType, getAssignedType(node)) :
/// declaredType` — for every other declared type the right-hand side is
/// never even *evaluated*. (ztsc keeps one more refining case, a declared
/// `unknown`, which `assignmentReduced` widens the assigned value into.)
///
/// The distinction is not an optimization: TYPING the right-hand side is
/// arbitrary work pulled into the middle of a flow walk, and a flow walk is
/// routinely run from inside a *return-type inference*. Two unannotated
/// functions in a module cycle then reach each other through a right-hand
/// side whose value is discarded a line later, and whichever demand entered
/// the cycle first hits `typeOfSymbol`'s in-progress break and answers
/// `any`. That is how `getElementsWithinSelection`'s inferred return
/// (`return elementsInSelection`, a plain `El[]`) came to depend on
/// `elementOverlapsWithFrame` — through `elementsInSelection =
/// elementsInSelection.filter((e) => elementOverlapsWithFrame(…))`, an
/// assignment that cannot possibly refine `El[]` — and, because the cycle
/// was then entered from whichever side the partition happened to schedule
/// first, `.some((e) => …)` on the `any` result lost its contextual
/// signature in some `--checkers=N` and not others.
pub fn assignmentRefines(c: *Checker, declared: TypeId) bool {
    return switch (c.ts.kind(declared)) {
        .union_type, .unknown => true,
        else => false,
    };
}

/// If the assign-flow node writes the reference (or invalidates a
/// property path by writing its root), the type after the assignment;
/// null when it is unrelated.
pub fn assignNarrows(c: *Checker, target: Node, key: RefKey, declared: TypeId) Error!?TypeId {
    if (target == null_node) return null;
    const root_sym = key.sym;
    switch (c.nodeTag(target)) {
        .declarator_init => {
            const d = c.tree.nodeData(target);
            if (!try c.patternBindsSym(d.lhs, root_sym)) return null;
            if (key.len != 0) return declared; // root re-init: reset path
            if (c.nodeTag(d.lhs) != .identifier) return declared;
            if (!c.assignmentRefines(declared)) return declared;
            const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
            return try c.assignmentReduced(declared, vt);
        },
        .declarator_full => {
            const d = c.tree.nodeData(target);
            if (!try c.patternBindsSym(d.lhs, root_sym)) return null;
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (key.len != 0) return declared;
            if (e.init == 0) return declared;
            if (c.nodeTag(d.lhs) != .identifier) return declared;
            if (!c.assignmentRefines(declared)) return declared;
            // Reading this variable can reach its declaration's flow node
            // BEFORE the declaration statement itself is checked — a JSX
            // attribute referring to a `const cb: CB = (props) => …`
            // declared earlier in the file, or a cross-file demand. The
            // initializer then has to be checked here, and checking it with
            // NO contextual type is what the declaration statement would
            // never do: an arrow's parameters get no contextual signature,
            // materialize as `any`, and that answer is what the (cached)
            // authoritative check reads back — TS7006 on every callback in
            // the body. Supply the annotation, exactly as `checkDeclarator`
            // does, so both orders produce the same signature.
            // (`unique symbol` is left alone — it contextually types
            // nothing, and resolving it here would raise TS1335 a second
            // time, out of the declaration's own position.)
            const ctx: TypeId = if (e.type_ann != 0 and c.nodeTag(e.type_ann) != .unique_symbol_type)
                try c.typeFromTypeNode(e.type_ann)
            else
                types.no_type;
            const vt = c.nodeType(e.init) orelse try c.checkExprCached(e.init, ctx);
            return try c.assignmentReduced(declared, vt);
        },
        .assign => {
            const d = c.tree.nodeData(target);
            // Full path write: <ref> = v narrows the tracked reference.
            if (key.len != 0 and try c.refMatches(d.lhs, key)) {
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                // A compound assignment writes a PATH exactly as it writes a
                // variable, and tsc narrows both (a property access is a
                // reference in the flow graph). `session.startSegment ??= i`
                // leaves a `number`, and giving up here left it `number |
                // null` for the rest of the function — immich's
                // `TranscodingService.onSegmentRequest`.
                if (op != .eq) {
                    const vt = c.nodeType(target) orelse
                        try c.checkExprCached(target, types.no_type);
                    return try c.assignmentReduced(declared, vt);
                }
                if (!c.assignmentRefines(declared)) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                return try c.assignmentReduced(declared, vt);
            }
            // Writing any proper prefix of the path (its root, or an
            // intermediate member) invalidates the whole subtree.
            if (try c.refPrefixWritten(d.lhs, key)) return declared;
            if (c.nodeTag(d.lhs) == .identifier) {
                if (!try c.identIsSym(d.lhs, root_sym)) return null;
                // key.len != 0 was caught above by refPrefixWritten.
                const op = c.tree.tokens.tag(c.tree.nodeMainToken(target));
                // An evolving (`auto`-typed) variable takes the assigned
                // type outright — there is no declared type to reduce it
                // against (tsc `getTypeAtFlowAssignment`, autoType branch).
                const evolving = key.len == 0 and c.isEvolvingVar(root_sym);
                if (op != .eq) {
                    // A compound assignment's post-value is the whole
                    // expression's type (`x ??= s` leaves `NonNullable<x> |
                    // typeof s`), so it has to be CHECKED, not read
                    // opportunistically out of the node cache. A reference can
                    // reach this flow node before the assignment statement is
                    // itself checked — a later reference in the same function
                    // whose type is demanded first (an inferred return type
                    // mentioning it is enough) — and falling back to `declared`
                    // there is not merely imprecise: `flowType` memoizes a
                    // result equal to `declared` as "this reference narrows
                    // nothing", so the non-answer is published for every later
                    // query at this node. The `.eq` arm below already checks
                    // its right-hand side for exactly this reason.
                    const vt = c.nodeType(target) orelse
                        try c.checkExprCached(target, types.no_type);
                    if (evolving) return try c.widenLiteral(vt);
                    return try c.assignmentReduced(declared, vt);
                }
                if (!evolving and !c.assignmentRefines(declared)) return declared;
                const vt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                if (evolving) return try c.widenLiteral(vt);
                return try c.assignmentReduced(declared, vt);
            }
            if (try c.patternBindsSym(d.lhs, root_sym)) {
                // `[, width, height] = match` assigns a *position* of the
                // right-hand side, and tsc reduces the declared type by that
                // element's type just like a plain `width = …` (its
                // `getAssignedType` walks the destructuring target). Falling
                // back to `declared` here re-widened a `string | null` that
                // an earlier `width = width || "50"` had already narrowed.
                if (key.len == 0 and c.assignmentRefines(declared)) {
                    const rt = c.nodeType(d.rhs) orelse try c.checkExprCached(d.rhs, types.no_type);
                    if (try c.destructuredAssignType(d.lhs, c.symNameAtom(root_sym), rt)) |vt| {
                        return try c.assignmentReduced(declared, vt);
                    }
                }
                return declared;
            }
            return null;
        },
        .prefix_unary, .postfix_unary => {
            const d = c.tree.nodeData(target);
            if (try c.refMatches(d.lhs, key)) {
                return try c.assignmentReduced(declared, types.number_type);
            }
            if (try c.refPrefixWritten(d.lhs, key)) return declared;
            return null;
        },
        // for-of / for-in left (var decl or expression).
        .var_decl_one, .var_decl => {
            if (try c.varDeclBindsSym(target, root_sym)) {
                if (key.len != 0) return declared;
                // The element type was computed when the statement was
                // checked; the symbol type already reflects it.
                return try c.typeOfSymbol(root_sym);
            }
            return null;
        },
        .identifier => {
            if (!try c.identIsSym(target, root_sym)) return null;
            return declared;
        },
        else => {
            if (try c.patternBindsSym(target, root_sym)) return declared;
            return null;
        },
    }
}

/// Narrow `t` (the flow type of the reference) by a decomposed
/// condition node.
/// Whether the tracked reference is a *constant reference* in tsc's sense:
/// a root-identifier reference to a `const`, or to a parameter / mutable
/// local that is never reassigned anywhere in its file. Aliased-condition
/// narrowing requires this — an alias snapshots the condition at its
/// declaration point, so a reassignable subject could make the snapshot
/// stale (mirrors tsc's `isConstantReference`).
pub fn isConstantRefSym(c: *Checker, key: RefKey) Error!bool {
    if (key.len != 0) return false;
    if (isPseudoRoot(key.sym)) return false;
    const sf = c.symFlags(key.sym);
    if (sf.const_decl) return true;
    if (!(sf.let_decl or sf.var_decl or sf.param or sf.catch_param)) return false;
    if (sf.exported) return false; // a top-level export may be reassigned elsewhere
    if (c.symFile(key.sym) != c.cur_file) return false;
    try c.ensureReassignScan();
    return !c.reassigned_syms.contains(key.sym);
}

/// TS4.4 aliased-condition support: if `cond` is a bare identifier bound to
/// a `const` variable whose declarator has an initializer and no explicit
/// type annotation, and the tracked reference `key` is a constant
/// reference, return that initializer expression so the caller can narrow
/// `key` by it. Any unmet precondition returns null (narrowing untouched):
///   • alias must be declared `const` (a never-reassigned `let` does NOT
///     narrow — verified against tsc 5.9.3),
///   • the declarator must carry no explicit type annotation (`const m:
///     boolean = …` does not narrow), and bind a plain identifier (no
///     destructured alias),
///   • same-file, non-exported (so the initializer resolves in scope).
pub fn constAliasInit(c: *Checker, cond: Node, key: RefKey) Error!?Node {
    if (c.nodeTag(cond) != .identifier) return null;
    if (!try c.isConstantRefSym(key)) return null;
    const a = try c.atomOfToken(c.tree.nodeMainToken(cond));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return null,
    };
    if (sym == key.sym) return null; // matched-reference case handled by the caller
    const sf = c.symFlags(sym);
    if (!sf.const_decl) return null;
    if (sf.exported) return null;
    if (c.symFile(sym) != c.cur_file) return null;
    const decls = c.declsOf(sym);
    if (decls.len != 1) return null;
    const decl = decls[0];
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        .declarator_init => {
            if (c.nodeTag(d.lhs) != .identifier) return null;
            return d.rhs;
        },
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.type_ann != 0 or e.init == 0) return null;
            if (c.nodeTag(d.lhs) != .identifier) return null;
            return e.init;
        },
        else => return null,
    }
}

pub fn narrowByCondition(c: *Checker, t: TypeId, cond: Node, sense: bool, key: RefKey, decl: TypeId) Error!TypeId {
    if (cond == null_node) return t;
    const d = c.tree.nodeData(cond);
    switch (c.nodeTag(cond)) {
        .paren_expr => return c.narrowByCondition(t, d.lhs, sense, key, decl),
        .non_null => return c.narrowByCondition(t, d.lhs, sense, key, decl),
        // `if ((m = next()))` — an assignment's value is the target's new
        // value, so its truthiness narrows the target (tsc narrows by
        // `getReferenceCandidate` of the condition); a comma expression
        // condition is its right operand.
        .assign, .seq_expr => {
            const cand = c.referenceCandidate(cond);
            if (cand != cond) return c.narrowByCondition(t, cand, sense, key, decl);
            return t;
        },
        .identifier => {
            if (try c.refMatches(cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            // Aliased-condition narrowing (tsc TS4.4 "control flow analysis
            // of aliased conditions and discriminants"): the condition is a
            // bare identifier bound to a `const` whose initializer is itself
            // a narrowing expression. Narrow the tracked reference by that
            // initializer instead. `constAliasInit` enforces tsc's rules
            // (const alias, no explicit annotation, subject a constant
            // reference so the snapshot cannot go stale); the level cap
            // bounds alias-of-alias chains.
            if (c.alias_inline_level < 5) {
                if (try c.constAliasInit(cond, key)) |init_expr| {
                    c.alias_inline_level += 1;
                    defer c.alias_inline_level -= 1;
                    return c.narrowByCondition(t, init_expr, sense, key, decl);
                }
            }
            return t;
        },
        .member_expr, .optional_member_expr => {
            // The path itself is the condition.
            if (try c.refMatches(cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            // `if (<ref>.p)` / `if (<ref>?.p)` — discriminate the tracked
            // reference by the truthiness of an extra property `p`.
            if (try c.refMatches(d.lhs, key)) {
                var base = t;
                if (c.nodeTag(cond) == .optional_member_expr and sense) {
                    base = try c.nonNullable(base);
                }
                const prop = try c.memberAtom(d.rhs);
                return c.narrowByPropTruthiness(base, prop, sense, decl);
            }
            // A truthy optional chain (`if (a?.b.c)`, `if (!a?.b.c)` else)
            // implies its receivers did not short-circuit: narrow a contained
            // receiver reference to non-null. This is tsc's
            // `narrowTypeByTruthiness` optional-chain-containment rule — it
            // fires on the true branch only (a falsy chain says nothing about
            // whether the receiver was nullish).
            if (sense and try c.optionalChainContainsRef(cond, key)) {
                return c.nonNullable(t);
            }
            return t;
        },
        // `if (arr[0])` — a constant element access is a tracked
        // reference, so its own truthiness narrows it (`refMatches` walks
        // element links). Failing that, an ELEMENT-access chain link
        // (`a?.[k]`) is the same optional chain as `a?.p` on a different
        // node tag: a truthy chain implies its receivers did not
        // short-circuit, so the member arm's containment rule applies.
        .index_expr, .optional_index_expr => {
            if (try c.refMatches(cond, key)) {
                return if (sense) c.getTruthyPart(t) else c.getFalsyPart(t, true);
            }
            if (sense and try c.optionalChainContainsRef(cond, key)) {
                return c.nonNullable(t);
            }
            return t;
        },
        .binary => {
            const op = c.tree.tokens.tag(c.tree.nodeMainToken(cond));
            switch (op) {
                .eq_eq_eq, .bang_eq_eq, .eq_eq, .bang_eq => {
                    const strict = op == .eq_eq_eq or op == .bang_eq_eq;
                    var eff_sense = sense;
                    if (op == .bang_eq_eq or op == .bang_eq) eff_sense = !sense;
                    return c.narrowByEqualityCond(t, d.lhs, d.rhs, strict, eff_sense, key, decl);
                },
                .keyword_in => {
                    // `"p" in x`
                    if (!try c.refMatches(d.rhs, key)) return t;
                    const lhs_t = try c.checkExprCached(d.lhs, types.no_type);
                    const rl = try c.ts.regularLiteral(lhs_t);
                    if (c.ts.kind(rl) != .string_literal) return t;
                    return c.narrowByInProp(t, c.ts.literalAtom(rl), sense);
                },
                .keyword_instanceof => {
                    if (!try c.refMatches(d.lhs, key)) {
                        // `a?.b instanceof C` being true implies the chain
                        // did not short-circuit, so its receivers are not
                        // nullish — the same optional-chain containment rule
                        // the truthiness arms above apply, and the reason
                        // `if (cached?.image instanceof Promise) await
                        // cached.image;` is legal. False says nothing.
                        if (sense and try c.optionalChainContainsRef(d.lhs, key)) {
                            return c.nonNullable(t);
                        }
                        return t;
                    }
                    const rt = try c.checkExprCached(d.rhs, types.no_type);
                    if (try c.instanceofInstanceType(rt)) |inst|
                        return c.narrowByInstance(t, inst, sense);
                    return t;
                },
                // `a && b` true implies both operands are truthy; `a || b`
                // false implies both are falsy (tsc
                // `narrowTypeByBinaryExpression`). A condition written
                // directly in an `if` never reaches here — the binder
                // decomposes it into separate flow nodes — but an *aliased*
                // condition does, because `constAliasInit` hands the alias's
                // initializer straight to this narrower, bypassing the
                // binder. `const g = isImg(e) && files[e.fileId]; if (g) …`
                // is the shape that needs it. The other polarity of each
                // operator says nothing about either operand.
                // The OTHER polarity of each operator is not silent either,
                // it is a union of the two ways the operator can land
                // (tsc `narrowTypeByBinaryExpression`): `a || b` true means
                // "a true, OR a false and b true", and `a && b` false means
                // "a false, OR a true and b false". `const terminal =
                // s?.status === 'x' || s?.status === 'y'; if (terminal) s.n`
                // needs it — each arm alone removes `undefined` from `s`, so
                // their union does too, while returning `t` here keeps it.
                .amp_amp => {
                    const lt = try c.narrowByCondition(t, d.lhs, true, key, decl);
                    if (sense) return c.narrowByCondition(lt, d.rhs, true, key, decl);
                    return c.makeUnion2(
                        try c.narrowByCondition(t, d.lhs, false, key, decl),
                        try c.narrowByCondition(lt, d.rhs, false, key, decl),
                    );
                },
                .pipe_pipe => {
                    const lf = try c.narrowByCondition(t, d.lhs, false, key, decl);
                    if (!sense) return c.narrowByCondition(lf, d.rhs, false, key, decl);
                    return c.makeUnion2(
                        try c.narrowByCondition(t, d.lhs, true, key, decl),
                        try c.narrowByCondition(lf, d.rhs, true, key, decl),
                    );
                },
                else => return t,
            }
        },
        // A condition written directly in an `if` never reaches here — the
        // binder decomposes `!` into separate flow nodes — but an *aliased*
        // condition does, because `constAliasInit` hands the alias's
        // initializer straight to this narrower, bypassing the binder. Exactly
        // the reason the `&&` / `||` arms above exist, and `const isActive =
        // !!v; if (!isActive) return;` is the shape that needs it. Only `!`
        // says anything about its operand; `-`/`~`/`+`/`typeof`/`void` do not.
        .prefix_unary => {
            if (c.tree.tokens.tag(c.tree.nodeMainToken(cond)) != .bang) return t;
            return c.narrowByCondition(t, d.lhs, !sense, key, decl);
        },
        .call_expr, .call_expr_targs, .optional_call => {
            // A truthy optional-*call* chain (`if (a?.m())`, or the
            // fall-through of `if (!a?.m()) return`) implies its receivers
            // did not short-circuit: narrow a contained receiver to
            // non-null. Symmetric with the optional-member arm above
            // (tsc's `narrowTypeByTruthiness` optional-chain containment);
            // fires on the truthy branch only. This is what lets the common
            // `if (!raw?.trim()) return ''; …raw…` guard narrow `raw`.
            if (sense and try c.optionalChainContainsRef(cond, key)) {
                return c.nonNullable(t);
            }
            return c.narrowByGuardCall(t, cond, sense, key);
        },
        else => return t,
    }
}

pub fn narrowByEqualityCond(c: *Checker, t: TypeId, lhs: Node, rhs: Node, strict: bool, sense: bool, key: RefKey, decl: TypeId) Error!TypeId {
    // typeof <ref> === "..."
    if (try c.typeofTargetOf(lhs, key)) {
        const rt = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
        if (c.ts.kind(rt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(rt), sense);
        }
        return t;
    }
    if (try c.typeofTargetOf(rhs, key)) {
        const lt = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
        if (c.ts.kind(lt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(lt), sense);
        }
        return t;
    }
    // `typeof <optional-chain-containing-ref> === "…"`: the chain short-
    // circuits to `undefined` (so `typeof` is `"undefined"`) exactly when a
    // receiver was nullish. If this branch forces `typeof(chain) !=
    // "undefined"`, that receiver did not short-circuit — narrow it non-null
    // (tsc's `narrowTypeByTypeof` optional-chain-containment rule). `sense`
    // here is already equals-folded (`!==`/`!=` inverted by the caller).
    if (try c.typeofChainContainsRef(lhs, key)) {
        return c.narrowByTypeofChainContainment(t, rhs, sense);
    }
    if (try c.typeofChainContainsRef(rhs, key)) {
        return c.narrowByTypeofChainContainment(t, lhs, sense);
    }
    // <ref> === <literal> / <literal> === <ref>
    if (try c.refMatches(lhs, key)) {
        return c.narrowByLiteralEquality(t, rhs, strict, sense);
    }
    if (try c.refMatches(rhs, key)) {
        return c.narrowByLiteralEquality(t, lhs, strict, sense);
    }
    // <ref>.k === <literal> narrows <ref> by its discriminant. `<ref>` is
    // the tracked reference — a root symbol (`x.k`, key.len == 0) or a
    // member path (`f.geometry.k`, narrowing the union stored at the
    // tracked `f.geometry`). The union `t` is `<ref>`'s type, so the same
    // discriminant filter applies regardless of the reference's depth.
    if (try c.discriminantOfRef(lhs, key)) |prop_tok| {
        const other = try c.ts.regularLiteral(try c.checkExprCached(rhs, types.no_type));
        const narrowed = try c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense, decl);
        // An OPTIONAL discriminant read (`x?.k === lit`) short-circuits to
        // `undefined` when the receiver is nullish, so the equality also
        // forces the receiver non-nullish on the asserting branch (tsc's
        // optional-chain containment). The discriminant filter alone keeps
        // `undefined` (no `k` prop → conservatively kept), so strip it too.
        if (c.nodeTag(lhs) == .optional_member_expr) {
            return c.narrowByOptChainContainment(narrowed, rhs, strict, sense);
        }
        return narrowed;
    }
    if (try c.discriminantOfRef(rhs, key)) |prop_tok| {
        const other = try c.ts.regularLiteral(try c.checkExprCached(lhs, types.no_type));
        const narrowed = try c.narrowByDiscriminant(t, try c.memberAtom(prop_tok), other, sense, decl);
        if (c.nodeTag(rhs) == .optional_member_expr) {
            return c.narrowByOptChainContainment(narrowed, lhs, strict, sense);
        }
        return narrowed;
    }
    // Optional-chain containment: `a?.….m() === <value>` narrows the chain's
    // *receiver* `a` to non-null (tsc's narrowTypeByOptionalChainContainment).
    // If `a` were nullish the whole chain short-circuits to `undefined`, so
    // when the comparison to `value` can only hold for a non-undefined (and,
    // for `==`/`!=`, non-null) `value`, the receiver did not short-circuit.
    if (try c.optionalChainContainsRef(lhs, key)) {
        return c.narrowByOptChainContainment(t, rhs, strict, sense);
    }
    if (try c.optionalChainContainsRef(rhs, key)) {
        return c.narrowByOptChainContainment(t, lhs, strict, sense);
    }
    return t;
}

/// Walks an optional chain's receiver spine (`chain.expression` at each
/// link), returning true when `key` matches a receiver at some optional
/// link — i.e. `key`'s reference is a container of the chain's short-circuit
/// (tsc's `optionalChainContainsReference`). Only fires for a chain that
/// actually has a `?.` link; a plain `a.b.c` never matches.
pub fn optionalChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
    var n = node;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    while (c.isOptionalChain(n)) {
        n = c.tree.nodeData(n).lhs; // step to this link's object/callee
        if (try c.refMatches(n, key)) return true;
    }
    return false;
}

/// Apply tsc's `narrowTypeByOptionalChainContainment`: remove `null`/
/// `undefined` from the receiver `t` when the comparand `value` forces the
/// chain to not have short-circuited in this branch. `strict` selects the
/// nullable set (`===`/`!==` → `undefined` only; `==`/`!=` → `null` |
/// `undefined`). `sense` is the already-bang-folded truthiness (so `!==`
/// arrives as an inverted `===`): with the operator's equals-ness folded in,
/// `sense` true means "narrow when every comparand constituent is
/// non-nullish and not any/unknown"; `sense` false means "narrow when every
/// comparand constituent is nullish".
pub fn narrowByOptChainContainment(c: *Checker, t: TypeId, value: Node, strict: bool, sense: bool) Error!TypeId {
    const vt = try c.checkExprCached(value, types.no_type);
    if (c.optChainComparandRemovesNullable(vt, strict, sense)) return c.nonNullable(t);
    return t;
}

pub fn optChainComparandRemovesNullable(c: *Checker, vt: TypeId, strict: bool, sense: bool) bool {
    if (c.ts.kind(vt) == .union_type) {
        for (c.ts.members(vt)) |m| {
            if (!c.optChainComparandConstituentOk(m, strict, sense)) return false;
        }
        return true;
    }
    return c.optChainComparandConstituentOk(vt, strict, sense);
}

pub fn optChainComparandConstituentOk(c: *Checker, m: TypeId, strict: bool, sense: bool) bool {
    const k = c.ts.kind(m);
    const nullish = k == .undefined or k == .void or (!strict and k == .null);
    if (sense) {
        // Every constituent must be non-nullish and not any/unknown/err
        // (their domains include undefined/null, so they can't force a
        // non-null receiver).
        return !nullish and k != .any and k != .unknown and k != .err;
    }
    // Every constituent must be nullish.
    return nullish;
}

pub fn typeofTargetOf(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
    if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
    return c.refMatches(c.tree.nodeData(node).lhs, key);
}

/// `node` is `typeof <expr>` whose `<expr>` is an optional chain containing
/// `key`'s reference at an optional link (but is not the ref itself — that
/// exact case is `typeofTargetOf`).
pub fn typeofChainContainsRef(c: *Checker, node: Node, key: RefKey) Error!bool {
    if (node == null_node or c.nodeTag(node) != .prefix_unary) return false;
    if (c.tree.tokens.tag(c.tree.nodeMainToken(node)) != .keyword_typeof) return false;
    return c.optionalChainContainsRef(c.tree.nodeData(node).lhs, key);
}

/// Narrow a chain receiver `t` to non-null when a `typeof <chain>` branch
/// forces `typeof(chain) != "undefined"`. `sense` is the equals-folded
/// branch truthiness (true ⇒ the branch asserts `typeof(chain) == literal`).
/// The chain did not short-circuit iff its `typeof` is not `"undefined"`, so
/// narrow iff `sense == (literal != "undefined")`.
pub fn narrowByTypeofChainContainment(c: *Checker, t: TypeId, value: Node, sense: bool) Error!TypeId {
    const rt = try c.ts.regularLiteral(try c.checkExprCached(value, types.no_type));
    if (c.ts.kind(rt) != .string_literal) return t;
    const is_undef_lit = c.ts.literalAtom(rt) == c.typeof_atoms[5]; // "undefined"
    if (sense != is_undef_lit) return c.nonNullable(t);
    return t;
}

/// `<ref>.k` where `<ref>` is exactly `key`'s reference: returns the
/// discriminant property token `k`. Handles any tracked reference — a root
/// symbol (`x.k`) *or* a depth-1 member path (`f.geometry.k`) — by reusing
/// `refMatches` on the access base.
///
/// Both a plain `.k` and an optional `?.k` access count. tsc's
/// `getDiscriminantPropertyAccess` accepts either — an optional read
/// short-circuits to `undefined` when the base is nullish, which is exactly
/// what the discriminant filter then removes on the asserting branch (the
/// caller finishes the job with `narrowByOptChainContainment`, since a
/// member with no `k` at all is kept by the filter). The reference's depth
/// is likewise irrelevant: the union being filtered is the reference's own
/// type whether it is a root symbol (`x?.k`) or a member path
/// (`s.openDialog?.k`).
pub fn discriminantOfRef(c: *Checker, node: Node, key: RefKey) Error!?TokenIndex {
    if (node == null_node) return null;
    // A binding-pattern pseudo-reference reads its discriminant through a
    // sibling BINDING, not a member access (see `narrowedPatternBinding`).
    if (isPatternRoot(key.sym)) return patternDiscriminantTok(c, node, key);
    switch (c.nodeTag(node)) {
        .member_expr, .optional_member_expr => {},
        else => return null,
    }
    const d = c.tree.nodeData(node);
    if (!try c.refMatches(d.lhs, key)) return null;
    return d.rhs;
}

pub fn identIsSym(c: *Checker, node: Node, sym: SymbolId) Error!bool {
    if (node == null_node) return false;
    if (sym == this_flow_root) return c.nodeTag(node) == .this_expr;
    // A binding pattern is never itself written as an expression, so no
    // identifier ever *is* a pattern pseudo-root (its bindings are matched by
    // `discriminantOfRef` instead).
    if (isPatternRoot(sym)) return false;
    if (c.nodeTag(node) != .identifier) return false;
    const a = try c.atomOfToken(c.tree.nodeMainToken(node));
    if (a != c.symNameAtom(sym)) return false;
    return switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s == sym,
        else => false,
    };
}

/// Populate `reassigned_syms` for the current file: the set of value
/// symbols that are ever the target of a reassignment (`x = …`, `x += …`,
/// `x++`, or a destructuring-assignment element). Runs once per file
/// (`reassign_scanned`); the declarator initializer is *not* a
/// reassignment. Order-invariant — a pure function of the file's AST.
pub fn ensureReassignScan(c: *Checker) Error!void {
    if (c.reassign_scanned[c.cur_file]) return;
    c.reassign_scanned[c.cur_file] = true;
    const b = c.bind;
    var flow: FlowId = 0;
    while (flow < b.flow_tags.len) : (flow += 1) {
        if (b.flow_tags[flow] != .assign) continue;
        const node = b.flowNode(flow);
        if (node == null_node) continue;
        const scope = b.flowScope(flow);
        switch (c.nodeTag(node)) {
            .assign => {
                try c.markReassignTarget(c.tree.nodeData(node).lhs, scope);
                try c.markMemberWriteRoot(c.tree.nodeData(node).lhs, scope);
            },
            .prefix_unary, .postfix_unary => {
                switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                    .plus_plus, .minus_minus => {
                        try c.markReassignTarget(c.tree.nodeData(node).lhs, scope);
                        try c.markMemberWriteRoot(c.tree.nodeData(node).lhs, scope);
                    },
                    else => {},
                }
            },
            // declarator_init / declarator_full / for-in-of bindings are
            // the variable's *initialization*, not a reassignment.
            else => {},
        }
    }
}

/// Record `sym` as reassigned, and for every `for`/`for..of`/`for..in`
/// header scope enclosing the assignment's `scope`, record that `sym` is
/// assigned *inside that loop*. The ancestor walk means an assignment nested
/// N loops deep marks all N enclosing loops.
pub fn recordReassign(c: *Checker, sym: SymbolId, scope: ScopeId) Error!void {
    try c.reassigned_syms.put(c.cm(), sym, {});
    const b = c.bind;
    var s = scope;
    while (true) {
        if (b.scope_kinds[s] == .for_head)
            try c.reassigned_in_loop.put(c.cm(), .{ .sym = sym, .scope = s }, {});
        const p = b.scope_parents[s];
        if (p == s) break;
        s = p;
    }
}

pub fn markReassignTarget(c: *Checker, target: Node, scope: ScopeId) Error!void {
    if (target == null_node) return;
    var n = target;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    switch (c.nodeTag(n)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(n));
            switch (c.resolveSpace(a, scope, true)) {
                .sym => |s| try c.recordReassign(s, scope),
                else => {},
            }
        },
        // Destructuring-assignment target: `[a] = …` / `({a} = …)`.
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            for (c.tree.nodeRange(n)) |el| {
                if (el != null_node) try c.markReassignTarget(el, scope);
            }
        },
        // Cover grammar: `object_property`'s target is rhs (lhs is the key).
        .object_property => try c.markReassignTarget(c.tree.nodeData(n).rhs, scope),
        // `{[k]: target}` — lhs is the key expression, rhs the target.
        .binding_property_computed => try c.markReassignTarget(c.tree.nodeData(n).rhs, scope),
        .binding_property, .object_shorthand => {
            const d = c.tree.nodeData(n);
            if (d.lhs != 0) {
                try c.markReassignTarget(d.lhs, scope);
            } else {
                const a = try c.memberAtom(c.tree.nodeMainToken(n));
                switch (c.resolveSpace(a, scope, true)) {
                    .sym => |s| try c.recordReassign(s, scope),
                    else => {},
                }
            }
        },
        .binding_default, .rest_element, .spread_element => {
            try c.markReassignTarget(c.tree.nodeData(n).lhs, scope);
        },
        // member_expr (`o.p = v`) reassigns a property, not a variable.
        else => {},
    }
}

/// Record the ROOT symbol of a member/element-write target (`o.p = …`,
/// `o[i] = …`) so property-path narrowings rooted at that symbol are known
/// to be potentially invalidated inside the enclosing loop(s). Peels the
/// member/index spine (and parens) to the base identifier / `this`.
pub fn markMemberWriteRoot(c: *Checker, target: Node, scope: ScopeId) Error!void {
    if (target == null_node) return;
    var n = target;
    while (true) {
        while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
        const tag = c.nodeTag(n);
        if (tag == .member_expr or tag == .optional_member_expr or
            tag == .index_expr or tag == .optional_index_expr)
        {
            n = c.tree.nodeData(n).lhs;
            continue;
        }
        break;
    }
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    if (target == n) return; // not a member/element write (bare identifier)
    switch (c.nodeTag(n)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(n));
            switch (c.resolveSpace(a, scope, true)) {
                .sym => |s| try c.recordMemberWrite(s, scope),
                else => {},
            }
        },
        .this_expr => try c.recordMemberWrite(this_flow_root, scope),
        else => {},
    }
}

/// Mirror of `recordReassign` for member/element writes: record the root as
/// member-written file-wide and inside every enclosing `for` loop.
pub fn recordMemberWrite(c: *Checker, sym: SymbolId, scope: ScopeId) Error!void {
    try c.member_written_syms.put(c.cm(), sym, {});
    const b = c.bind;
    var s = scope;
    while (true) {
        if (b.scope_kinds[s] == .for_head)
            try c.member_written_in_loop.put(c.cm(), .{ .sym = sym, .scope = s }, {});
        const p = b.scope_parents[s];
        if (p == s) break;
        s = p;
    }
}

/// The type a destructuring *assignment* target gives to the element named
/// `name` (`[, width] = m`, `({ a: x } = o)`), or null when it cannot be
/// pinned down exactly. This is the cover-grammar mirror of
/// `findBindingType`, which only walks the declaration forms: an assignment
/// target is parsed as an array/object *literal*, with `object_property` /
/// `object_shorthand` / `spread_element` in place of the binding nodes.
/// Returning null keeps the caller's conservative "reset to declared".
pub fn destructuredAssignType(c: *Checker, pat: Node, name: Atom, whole: TypeId) Error!?TypeId {
    if (pat == null_node) return null;
    const d = c.tree.nodeData(pat);
    switch (c.nodeTag(pat)) {
        .paren_expr => return c.destructuredAssignType(d.lhs, name, whole),
        .identifier => {
            if ((try c.atomOfToken(c.tree.nodeMainToken(pat))) != name) return null;
            return whole;
        },
        // `[a] = xs` inside a target is a default (`[a = 1] = xs`), which
        // strips `undefined` exactly as a binding default does.
        .assign, .binding_default => {
            const inner = (try c.destructuredAssignType(d.lhs, name, whole)) orelse return null;
            return try c.removeUndefined(inner);
        },
        .array_literal, .array_pattern => {
            const r = try c.resolveStructural(whole);
            // Every non-tuple position takes the iterated element type
            // (tsc's `checkIteratedTypeOrElementType`), which is how a
            // `RegExpMatchArray` — an interface over `Array<string>`, not an
            // `.array` — yields `string` per position.
            const iter: TypeId = if (c.ts.kind(r) == .tuple)
                types.no_type
            else
                (try c.iterationElementType(r)) orelse types.no_type;
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted) continue;
                var et: TypeId = iter;
                if (c.ts.kind(r) == .tuple and i < c.ts.tupleLen(r)) {
                    const te = c.ts.tupleElem(r, i);
                    et = if (te.optional() or te.rest())
                        try c.makeUnion2(te.ty, types.undefined_type)
                    else
                        te.ty;
                }
                if (et == types.no_type) continue;
                const tag = c.nodeTag(el);
                if (tag == .rest_element or tag == .spread_element) {
                    const rest = try c.ts.makeArray(et);
                    if (try c.destructuredAssignType(c.tree.nodeData(el).lhs, name, rest)) |v| return v;
                    continue;
                }
                if (try c.destructuredAssignType(el, name, et)) |v| return v;
            }
            return null;
        },
        .object_literal, .object_pattern => {
            const r = try c.resolveStructural(whole);
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                switch (c.nodeTag(el)) {
                    // `({ p: target } = o)` — key in main_token, target in rhs.
                    .object_property, .binding_property => {
                        const keyed = try c.memberAtom(c.tree.nodeMainToken(el));
                        const p = (try c.propOfType(r, keyed)) orelse continue;
                        const pt = if (p.optional())
                            try c.makeUnion2(p.ty, types.undefined_type)
                        else
                            p.ty;
                        const tgt = if (c.nodeTag(el) == .object_property) ed.rhs else ed.lhs;
                        if (try c.destructuredAssignType(tgt, name, pt)) |v| return v;
                    },
                    .object_shorthand => {
                        const keyed = try c.memberAtom(c.tree.nodeMainToken(el));
                        if (keyed != name) continue;
                        const p = (try c.propOfType(r, keyed)) orelse continue;
                        return if (p.optional())
                            try c.makeUnion2(p.ty, types.undefined_type)
                        else
                            p.ty;
                    },
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    }
}

pub fn patternBindsSym(c: *Checker, pat: Node, sym: SymbolId) Error!bool {
    if (pat == null_node) return false;
    // A pattern never binds `this`, nor another pattern's pseudo-root.
    if (isPseudoRoot(sym)) return false;
    switch (c.nodeTag(pat)) {
        .identifier => return (try c.atomOfToken(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym),
        .array_pattern, .object_pattern, .array_literal, .object_literal => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el != null_node and try c.patternBindsSym(el, sym)) return true;
            }
            return false;
        },
        // `object_property` is the *cover grammar* form (`({ p: a } = …)`):
        // main_token/lhs are the property KEY and rhs is the target. The
        // declaration form `binding_property` puts the target in lhs (0 when
        // shorthand), and `object_shorthand`'s lhs is the target identifier.
        .object_property, .binding_property_computed => return c.patternBindsSym(c.tree.nodeData(pat).rhs, sym),
        .binding_property, .object_shorthand => {
            const d = c.tree.nodeData(pat);
            if (d.lhs != 0) return c.patternBindsSym(d.lhs, sym);
            return (try c.memberAtom(c.tree.nodeMainToken(pat))) == c.symNameAtom(sym);
        },
        .binding_default, .rest_element, .spread_element => {
            return c.patternBindsSym(c.tree.nodeData(pat).lhs, sym);
        },
        else => return false,
    }
}

pub fn varDeclBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
    const d = c.tree.nodeData(decl);
    if (c.nodeTag(decl) == .var_decl_one) {
        return c.declaratorBindsSym(d.lhs, sym);
    }
    for (c.tree.nodeRange(decl)) |dn| {
        if (dn != null_node and try c.declaratorBindsSym(dn, sym)) return true;
    }
    return false;
}

pub fn declaratorBindsSym(c: *Checker, decl: Node, sym: SymbolId) Error!bool {
    const d = c.tree.nodeData(decl);
    return switch (c.nodeTag(decl)) {
        .declarator, .declarator_init, .declarator_full => c.patternBindsSym(d.lhs, sym),
        else => c.patternBindsSym(decl, sym),
    };
}

/// tsc's getAssignmentReducedType: keep declared-union constituents
/// the assigned type is assignable to.
///
/// "Assignable to" is tsc's `typeMaybeAssignableTo`, which for a UNION
/// source asks whether SOME constituent is assignable — not whether all of
/// them are. The difference decides whether a union survives its own
/// assignment: under the strict reading, writing `A | B` into a variable
/// declared `A | B` keeps only the constituents the WHOLE union fits, so a
/// variable initialized with `x || fallback` or `cond ? a : b` collapsed to
/// whichever arm happened to be a supertype of the other and lost the rest
/// — at the point of use, not at the expression.
///
/// The reduced union is only taken when the assigned type actually fits it
/// (tsc's closing `isTypeAssignableTo` guard) — under the loosened filter a
/// kept set can otherwise fail to admit the very value being written. The
/// guard is inert for a non-union assigned type, where "some" and "all"
/// agree and the kept set trivially admits it.
/// Subtype reduction for an evolving variable's flow join, with the
/// nullish constituents held out of it. `null`/`undefined` must survive:
/// ztsc's relation lets them satisfy an object whose properties are all
/// optional, so a plain `reduceSubtypes` would absorb the `null` that a
/// branch which assigns nothing still contributes.
pub fn reduceEvolvingJoin(c: *Checker, joined: TypeId) Error!TypeId {
    if (c.ts.kind(joined) != .union_type) return joined;
    var nullish: std.ArrayList(TypeId) = .empty;
    defer nullish.deinit(c.scratch());
    var rest: std.ArrayList(TypeId) = .empty;
    defer rest.deinit(c.scratch());
    for (try c.memberList(joined)) |m| {
        if (isNullishKind(c.ts.kind(m)))
            try nullish.append(c.scratch(), m)
        else
            try rest.append(c.scratch(), m);
    }
    if (nullish.items.len == 0) return c.reduceSubtypes(joined);
    if (rest.items.len == 0) return joined;
    const reduced = try c.reduceSubtypes(try c.ts.makeUnion(c.scratch(), rest.items));
    try nullish.append(c.scratch(), reduced);
    return c.ts.makeUnion(c.scratch(), nullish.items);
}

pub fn assignmentReduced(c: *Checker, declared: TypeId, assigned0: TypeId) Error!TypeId {
    const dk = c.ts.kind(declared);
    if (dk == .any or dk == .err or dk == .unknown) {
        if (dk == .unknown) return c.widenLiteral(assigned0);
        return declared;
    }
    const assigned = try c.ts.regular(try c.ts.regularLiteral(assigned0));
    if (dk != .union_type) return declared;
    if (assigned == declared) return declared;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(declared)) |m| {
        if (try c.maybeAssignable(assigned, m)) try parts.append(c.scratch(), m);
    }
    if (parts.items.len != 0) {
        const reduced = try c.ts.makeUnion(c.scratch(), parts.items);
        if (try c.isAssignable(assigned, reduced)) return reduced;
        return declared;
    }
    for (try c.memberList(declared)) |m| {
        if (try c.isComparable(assigned, m)) try parts.append(c.scratch(), m);
    }
    if (parts.items.len == 0) return declared;
    return c.ts.makeUnion(c.scratch(), parts.items);
}

pub fn narrowByLiteralEquality(c: *Checker, t: TypeId, other: Node, strict: bool, sense: bool) Error!TypeId {
    const ot0 = try c.checkExprCached(other, types.no_type);
    const ot1 = try c.ts.regularLiteral(ot0);
    // `x === 'a'` / `x !== 1` where `x` is an ENUM: tsc's whole enum is the
    // union `E.A | E.B`, so `filterType(E, t => areTypesComparable(t, "a"))`
    // keeps `E.A` on the true branch and drops it on the false one. ztsc
    // keeps the enum as one type and the arms below match member types by
    // identity, so the raw value is translated into the member type it names
    // first — after which the existing enum arms do exactly tsc's thing.
    // Without it `e !== 'a'` never shrank `E` and `e === 'a'` collapsed the
    // reference to `never`.
    const ot = try enumMemberForLiteral(c, t, ot1);
    const ok = c.ts.kind(ot);
    const is_nullish = ok == .null or ok == .undefined;
    if (!strict and is_nullish) {
        // == null / == undefined match both.
        if (sense) {
            return c.filterUnion(t, struct {
                fn keep(ch: *Checker, m: TypeId) bool {
                    const k = ch.ts.kind(m);
                    return k == .null or k == .undefined or k == .any or k == .unknown or k == .err;
                }
            }.keep);
        }
        return c.nonNullable(t);
    }
    // tsc's `isUnitType` covers `TypeFlags.Unit` = Literal | UniqueESSymbol |
    // Nullable, so a `unique symbol` comparand narrows exactly like a literal
    // one: `if (post === POST_TOMBSTONE)` must remove the tombstone
    // constituent from `Shadow<PostView> | typeof POST_TOMBSTONE` on the else
    // branch. Plain `symbol` is NOT a unit type and still narrows nothing.
    const is_literal = c.ts.isLiteralLike(ot) or is_nullish or ok == .unique_symbol;
    if (!is_literal) return t;
    if (sense) {
        return c.narrowToValue(t, ot);
    }
    return c.narrowExcludeValue(t, ot);
}

/// Translate a plain literal comparand into the ENUM MEMBER type it names,
/// when the narrowed type is an enum (optionally nullable). Returns the
/// comparand unchanged in every other case, including a mixed union such as
/// `E | string`, where the plain literal is still the right comparand for the
/// non-enum constituents.
fn enumMemberForLiteral(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    switch (c.ts.kind(v)) {
        .string_literal, .number_literal, .number_literal_fresh => {},
        else => return v,
    }
    var sym: ?u32 = null;
    if (c.ts.kind(t) == .enum_type) {
        sym = c.ts.enumSymbol(t);
    } else if (c.ts.kind(t) == .union_type) {
        for (c.ts.members(t)) |m| {
            switch (c.ts.kind(m)) {
                .enum_type => {
                    const s = c.ts.enumSymbol(m);
                    if (sym != null and sym.? != s) return v; // two enums: leave it
                    sym = s;
                },
                .null, .undefined => {},
                else => return v, // a non-enum constituent still wants the literal
            }
        }
    }
    const es = sym orelse return v;
    return (try c.enumMemberForValue(es, v)) orelse v;
}

/// Narrow `t` to the single value type `v` (=== true branch).
pub fn narrowToValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const nm = try c.narrowToValue(m, v);
            if (nm != types.never_type) try parts.append(c.scratch(), nm);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const mt = try c.ts.regularLiteral(t);
    const k = c.ts.kind(mt);
    if (mt == v) return v;
    if (k == .any or k == .unknown or k == .err) return v;
    // `=== null` / `=== undefined`: only a matching nullish member (handled
    // by `mt == v` above) survives; any other concrete member is excluded.
    // Without this the false branch of `x !== null` stayed `number | null`,
    // defeating the inferred-predicate disjointness gate (and under-
    // narrowing `if (x === null)`).
    if (c.ts.kind(v) == .null or c.ts.kind(v) == .undefined) return types.never_type;
    // `=== <unique symbol>`: the comparand is a unit type whose only wider
    // domain is `symbol` (a different unique symbol was ruled out by the
    // identity test above), so every other constituent is excluded.
    if (c.ts.kind(v) == .unique_symbol) return if (k == .symbol) v else types.never_type;
    if (try c.literalBaseOf(v) == mt) return v; // string narrowed by "a" / `E` by `E.A`
    if (k == .boolean and (c.ts.kind(v) == .bool_true or c.ts.kind(v) == .bool_false)) return v;
    if (c.ts.isLiteralLike(mt) or k == .null or k == .undefined) {
        return types.never_type; // different literal
    }
    // Non-literal member unrelated to v's base: exclude.
    if (c.ts.isLiteralLike(v)) return types.never_type;
    return mt;
}

/// Remove the single value type `v` from `t` (!== true branch).
/// Is `t`, or any constituent of it if it is a union, of kind `k`?
pub fn unionHasKind(c: *Checker, t: TypeId, k: types.Kind) bool {
    if (c.ts.kind(t) == k) return true;
    if (c.ts.kind(t) != .union_type) return false;
    for (c.ts.members(t)) |m| {
        if (c.ts.kind(m) == k) return true;
    }
    return false;
}

pub fn narrowExcludeValue(c: *Checker, t: TypeId, v: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const nm = try c.narrowExcludeValue(m, v);
            if (nm != types.never_type) try parts.append(c.scratch(), nm);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const mt = try c.ts.regularLiteral(t);
    if (mt == v) return types.never_type;
    // A DEFERRED conditional or indexed access is not a union, so none of
    // the arms here can subtract the nullish constituent hiding inside it,
    // and `x !== undefined` left the type exactly as it found it. tsc's
    // `getAdjustedTypeWithFacts` covers this: for `NEUndefined` it maps a
    // constituent that *could* be undefined onto its BASE CONSTRAINT and
    // re-applies the fact there. So
    // `K extends keyof M ? M[K] | undefined : never` guarded by
    // `!== undefined` becomes the constraint without `undefined`.
    //
    // `ShapeCache.generateElementShape` is the shape that needs it: its
    // inferred return type unions the guarded `cachedShape` with the
    // freshly-generated one, so an `undefined` that the `if (cachedShape
    // !== undefined) return cachedShape` had already excluded survived into
    // the result, and every `.forEach` on it reported an implicit `any`.
    // Only when the constraint really carries the value being excluded: an
    // access that CANNOT be undefined (`M[K]` inside `M[K] | undefined`)
    // must keep its deferred spelling, or the union arm above would trade
    // every such member for its constraint.
    if ((c.ts.kind(v) == .undefined or c.ts.kind(v) == .null) and
        (c.ts.kind(mt) == .conditional or c.ts.kind(mt) == .index_access))
    {
        const base = try c.transitiveBaseConstraint(mt);
        if (base != mt and base != types.no_type and c.unionHasKind(base, c.ts.kind(v))) {
            // `& {}`, exactly as a bare type parameter is handled: the
            // deferred spelling survives, so instantiating it later still
            // produces the caller's own type argument, while the apparent
            // members seen through it are the constraint's non-nullish
            // ones. Replacing it with the constraint outright would bake the
            // constraint into any inferred return type built from this
            // branch, and `f("a")` would come back `string | number[]`
            // instead of `number[]`.
            return c.ts.makeIntersection(c.scratch(), &.{ mt, types.empty_object_type });
        }
    }
    // `x !== E.A` on a WHOLE-enum reference: the enum is the union of its
    // members (tsc), so the branch keeps every other member —
    // `WS.INVALID | WS.UPDATE`, not `WS`. Without this the negative branch
    // never shrinks and a fully-covered `switch` is not exhaustive.
    if (c.ts.isEnumMember(v) and c.ts.kind(mt) == .enum_type and !c.ts.isEnumMember(mt) and
        c.ts.enumSymbol(mt) == c.ts.enumSymbol(v))
    {
        if (try c.enumMemberTypeUnion(c.ts.enumSymbol(mt), c.ts.enumMemberAtom(v))) |rest| return rest;
        return types.never_type;
    }
    if (c.ts.kind(mt) == .boolean) {
        if (c.ts.kind(v) == .bool_true) return types.false_type;
        if (c.ts.kind(v) == .bool_false) return types.true_type;
    }
    return t;
}

pub fn narrowByTypeof(c: *Checker, t0: TypeId, str: Atom, sense: bool) Error!TypeId {
    var which: usize = typeof_names.len;
    for (c.typeof_atoms, 0..) |a, i| {
        if (a == str) which = i;
    }
    if (which == typeof_names.len) return t0;
    // A type parameter narrows through its CONSTRAINT (`typeofMatches` only
    // inspects concrete kinds, so filtering `T` itself would collapse
    // `typeof x === 'object'` to `never`) — but the answer must stay a
    // subtype of `T`, so the filtered constraint is intersected back with
    // the type param. tsc does exactly this (`getNarrowedType` ends in
    // `getIntersectionType([t, candidate])` for an instantiable `t`), and it
    // is what keeps a narrowed reference passable where `T` is wanted: in
    // `<T extends { id: string } | string>`, the value argument of
    // `m.set(typeof e === "string" ? e : e.id, e)` is read at the merge of
    // the two branches, and a bare filtered constraint made it
    // `string | { id: string }` — not assignable to `T` (TS2345).
    if (c.ts.kind(t0) == .type_param) {
        const con = try c.baseConstraintOf(t0);
        if (con != t0) {
            const narrowed = try c.narrowByTypeofResolved(con, which, sense);
            if (narrowed == con) return t0; // nothing filtered
            if (c.ts.kind(narrowed) == .never) return types.never_type;
            return c.ts.makeIntersection(c.scratch(), &.{ t0, narrowed });
        }
    }
    return c.narrowByTypeofResolved(t0, which, sense);
}

pub fn narrowByTypeofResolved(c: *Checker, t: TypeId, which: usize, sense: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            const keep = try c.typeofMatchesFn(m, which);
            const kept = if (sense) keep else !keep;
            if (kept) try parts.append(c.scratch(), m);
        }
        return c.ts.makeUnion(c.scratch(), parts.items);
    }
    const k = c.ts.kind(t);
    if (k == .any or k == .unknown or k == .err) {
        if (!sense) return t;
        return switch (which) {
            0 => types.string_type,
            1 => types.number_type,
            2 => types.bigint_type,
            3 => types.boolean_type,
            4 => types.symbol_type,
            5 => types.undefined_type,
            6 => if (k == .unknown) try c.makeUnion2(types.object_keyword_type, types.null_type) else types.any_type,
            7 => t, // "function": no Function type in subset — keep
            else => t,
        };
    }
    const matches = try c.typeofMatchesFn(t, which);
    if (sense) return if (matches) t else types.never_type;
    return if (matches) types.never_type else t;
}

/// `typeofMatches` plus tsc's `isFunctionObjectType`: for `typeof x ===
/// "function"` an OBJECT type survives when it carries call or construct
/// signatures. `interface SymbolConstructor { (d?: string): symbol; … }` is
/// a `.ref`, so the syntactic-kind test alone answered "not a function" and
/// narrowed every callable interface — `Symbol`, `Array`, a mixin
/// constructor, an unannotated `const f = Object.assign(fn, {…})` — to
/// `never` inside its own `typeof === "function"` guard. Silent while a read
/// off `never` was permissive; a TS2339 the moment it stopped being.
///
/// Only the *keep* side is widened here: the `"object"` case still keeps a
/// callable (tsc's `FunctionFacts` would drop it), which under-narrows and
/// can only lose a diagnostic, never invent one.
pub fn typeofMatchesFn(c: *Checker, t: TypeId, which: usize) Error!bool {
    if (c.typeofMatches(t, which)) return true;
    if (c.ts.kind(t) == .enum_type) return c.enumTypeofDomain(t, which);
    if (which != 7) return false;
    return switch (c.ts.kind(t)) {
        .ref, .object, .intersection => c.hasCallableShape(t),
        else => false,
    };
}

/// Which `typeof` bucket an enum type falls in. tsc models an enum as the
/// UNION of its member types, and each member type is a string- or
/// number-LITERAL type carrying the enum flag — so `typeof` classifies an
/// enum by its VALUE domain, and `typeof p === 'string'` keeps a string enum
/// whole rather than collapsing it to `never`. ztsc keeps an enum as ONE
/// nominal type, so the domain has to be read off the declaration: a member
/// by its own constant value, a whole enum by whether any member is
/// string-valued (the split `isStringish` / `isNumberish` already follow).
///
/// Nothing else changes: an enum is not an object and not a function, so
/// every other bucket stays false and those branches narrow as before.
pub fn enumTypeofDomain(c: *Checker, t: TypeId, which: usize) Error!bool {
    if (which != 0 and which != 1) return false; // only "string" / "number"
    const sym = c.ts.enumSymbol(t);
    var stringish = c.enumHasStringMember(sym);
    if (c.ts.isEnumMember(t)) {
        if (try c.enumMemberValue(sym, c.ts.enumMemberAtom(t))) |v| {
            stringish = c.ts.kind(try c.ts.regularLiteral(v)) == .string_literal;
        }
    }
    return if (which == 0) stringish else !stringish;
}

/// Does `t` carry a call or construct signature? (`lastCallSig` already
/// walks overload sets and intersections for the call half.)
pub fn hasCallableShape(c: *Checker, t: TypeId) Error!bool {
    if ((try c.lastCallSig(t)) != null) return true;
    const r = try c.resolveStructural(t);
    switch (c.ts.kind(r)) {
        .object => return c.ts.objectConstructSigCount(r) > 0,
        .intersection => {
            for (try c.memberList(r)) |m| {
                if (try c.hasCallableShape(m)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn typeofMatches(c: *Checker, t: TypeId, which: usize) bool {
    const k = c.ts.kind(t);
    return switch (which) {
        0 => k == .string or k == .string_literal,
        1 => k == .number or k == .number_literal or k == .number_literal_fresh,
        2 => k == .bigint or k == .bigint_literal,
        3 => k == .boolean or k == .bool_true or k == .bool_false,
        4 => k == .symbol,
        5 => k == .undefined or k == .void,
        6 => k == .null or k == .object or k == .array or k == .tuple or k == .ref or
            k == .object_keyword or k == .intersection,
        7 => k == .function or k == .overloads or k == .class_value,
        else => false,
    };
}

pub fn narrowByDiscriminant(c: *Checker, t: TypeId, prop: Atom, value: TypeId, sense: bool, decl: TypeId) Error!TypeId {
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    // Also filter a single (non-union) member: once a discriminated union
    // has been narrowed to one constituent, an equality guard on its
    // discriminant still refines it — the false branch of `x.type === 'C'`
    // on `{ type: 'C' }` is `never` (tsc). A member lacking the discriminant
    // prop (`any`/`unknown`/primitives, wide `type: string`) stays in both
    // branches via the conservative arms below, so nothing over-narrows.
    //
    // …but only when `prop` really is a DISCRIMINANT. tsc reaches every
    // discriminant narrowing (equality, truthiness, `switch`) through
    // `getDiscriminantPropertyAccess`, which selects
    // `declaredType.flags & Union ? declaredType : computedType` and then
    // demands `isDiscriminantProperty`. Both halves of that matter here:
    //
    //   * a NON-UNION reference is never discriminated at all, so
    //     `switch (data.encoding) { case "bstring": …; default: throw
    //     Error(data.encoding) }` on a plain `{ encoding: "bstring"; … }`
    //     keeps its type in the `default:` clause instead of collapsing to
    //     `never` — the exhaustiveness idiom, and a false positive before;
    //   * a property whose per-constituent types are uniform or carry no
    //     unit type is not a discriminant either, so
    //     `sel[0].id === app.selectedLinearElement?.elementId` must leave
    //     `sel[0]` (a `line | arrow` union with `id: string` on both) alone
    //     rather than filtering it to `never`.
    //
    // `decl` is the reference's declared type, threaded down from
    // `flowTypeInner` — for a reference already narrowed to one constituent
    // it is still the union, which is exactly the shape the single-member
    // fallback above exists for.
    const disc_over = if (c.ts.kind(decl) == .union_type) decl else t;
    if (!try c.isDiscriminantProp(disc_over, prop)) return t;
    const single = [_]TypeId{t};
    const members: []const TypeId = if (c.ts.kind(t) == .union_type) try c.memberList(t) else &single;
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        const p = try c.propOfType(rm, prop);
        var matches = true; // members without the prop stay (conservative)
        if (p) |pp| {
            const pv = try c.ts.regularLiteral(pp.ty);
            if (c.ts.isLiteralLike(pv) or c.ts.kind(pv) == .null or c.ts.kind(pv) == .undefined) {
                matches = try c.isComparable(pv, value);
            } else {
                matches = try c.isComparable(pp.ty, value);
            }
        }
        const kept = if (sense) matches else blk: {
            // false branch removes a member only when its discriminant is a
            // UNIT type (literal / null / undefined) exactly equal to the
            // value. A wide discriminant (`current: string`) is never a
            // unit, so `x.current !== s` must keep it — dropping it to
            // `never` is the over-narrow that a single-member `t` exposed.
            if (p) |pp| {
                const pv = try c.ts.regularLiteral(pp.ty);
                const is_unit = c.ts.isLiteralLike(pv) or
                    c.ts.kind(pv) == .null or c.ts.kind(pv) == .undefined;
                // COMPARABLE, not identical — tsc's rule is
                // `!(isUnitLikeType(t) && areTypesComparable(t, valueType))`,
                // and `matches` above is that same comparability test. The
                // difference shows on a string/numeric ENUM discriminant
                // guarded by its raw value (`edit.action !== 'crop'` on
                // `action: AssetEditAction.Crop`): identity kept every member
                // on the false branch, so the branches overlapped and the
                // TS 5.5 inferred predicate on `find`/`filter` was refused.
                break :blk !(is_unit and matches);
            }
            break :blk true;
        };
        if (kept) try parts.append(c.scratch(), m);
    }
    return c.ts.makeUnion(c.scratch(), parts.items);
}

pub fn narrowByPropTruthiness(c: *Checker, t: TypeId, prop: Atom, sense: bool, decl: TypeId) Error!TypeId {
    if (c.ts.kind(t) != .union_type) return t;
    // tsc's `narrowTypeByTruthiness` reaches the per-member filter only
    // through `getDiscriminantPropertyAccess`, which requires `prop` to be a
    // DISCRIMINANT of the union (`isDiscriminantProperty`). Without that gate
    // `element.lineHeight || …` — a `number & { _brand }` property that is
    // uniformly non-optional and never a unit type — dropped every member on
    // the falsy branch and left `never`, so the `||`'s right operand reported
    // TS2339 on the same reference. tsc leaves the union untouched there.
    if (!try c.isDiscriminantProp(if (c.ts.kind(decl) == .union_type) decl else t, prop))
        return t;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        var keep = true;
        if (try c.propOfType(rm, prop)) |p| {
            if (sense) {
                // True branch: drop members whose prop is definitely falsy.
                const truthy = try c.getTruthyPart(p.ty);
                keep = truthy != types.never_type;
            } else {
                const falsy = try c.getFalsyPart(p.ty, true);
                keep = falsy != types.never_type or p.optional();
            }
        }
        if (keep) try parts.append(c.scratch(), m);
    }
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// Is `t` a *unit* type in tsc's sense (`TypeFlags.Unit`: a literal, an enum
/// member, `unique symbol`, `null`, `undefined`)? Deliberately narrower than
/// `Store.isLiteralLike`, which also admits template-literal patterns and
/// `Uppercase<…>` string mappings — neither is a unit type.
fn isUnitLike(c: *Checker, t: TypeId) bool {
    return switch (c.ts.kind(t)) {
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .bool_true,
        .bool_false,
        .unique_symbol,
        .undefined,
        .null,
        => true,
        else => c.ts.isEnumMember(t),
    };
}

/// tsc's `isLiteralType`: `boolean` counts (it is the union of its two
/// literals), a union counts when every constituent is a unit type, and
/// anything else must be a unit type itself.
fn isLiteralTypeLike(c: *Checker, t0: TypeId) Error!bool {
    const t = try c.resolveStructural(t0);
    if (c.ts.kind(t) == .boolean) return true;
    if (c.ts.kind(t) == .union_type) {
        for (try c.memberList(t)) |m| {
            if (!isUnitLike(c, try c.resolveStructural(m))) return false;
        }
        return true;
    }
    return isUnitLike(c, t);
}

/// tsc's `isDiscriminantProperty`: a union's synthetic property qualifies as
/// a discriminant when its per-constituent types are NON-UNIFORM and at least
/// one of them is a literal/unit type (`CheckFlags.Discriminant =
/// HasNonUniformType | HasLiteralType`), and the resulting type is not
/// generic. Only such a property may narrow the *parent* reference; every
/// other property says nothing about which constituent is live, which is why
/// `if (x.someNumber)` must leave `x` alone.
///
/// A constituent that lacks the property contributes nothing (tsc records it
/// as `CheckFlags.Partial` and moves on). A property type that still mentions
/// a type parameter disqualifies the whole thing — matching tsc's
/// `!isGenericType(...)` and erring toward *less* narrowing, which can only
/// drop a diagnostic, never invent one.
pub fn isDiscriminantProp(c: *Checker, t: TypeId, prop: Atom) Error!bool {
    if (c.ts.kind(t) != .union_type) return false;
    var first: TypeId = types.no_type;
    var non_uniform = false;
    var has_literal = false;
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        const p = (try c.propOfType(rm, prop)) orelse continue;
        if (try c.containsTypeParam(p.ty)) return false;
        if (first == types.no_type) {
            first = p.ty;
        } else if (p.ty != first) {
            non_uniform = true;
        }
        if (try isLiteralTypeLike(c, p.ty)) has_literal = true;
    }
    return non_uniform and has_literal;
}

/// Is `prop` DECLARED on `rm`, for the purposes of `in`-narrowing? tsc's
/// `isTypePresencePossible` asks `getPropertyOfType`, and a still-GENERIC
/// mapped type (`Partial<Record<T, any>>` with `T` abstract) has no members
/// at all there — its key set is unknown, so it can neither confirm nor
/// supply the name. ztsc's `propOfType` synthesizes a member for any name
/// on such a type, which made every constituent of
/// `({ [ORIG_ID]?: string } | { id: string }) & Partial<Record<T, any>>`
/// look like it has `id`, so `"id" in el` filtered nothing.
pub fn propDeclaredForIn(c: *Checker, rm: TypeId, prop: Atom) Error!?types.Prop {
    switch (c.ts.kind(rm)) {
        .mapped => {
            const con = c.ts.mappedConstraint(rm);
            if (con == types.no_type or try c.containsTypeParam(con)) return null;
        },
        .intersection => {
            for (try c.memberList(rm)) |m| {
                const r = try c.resolveStructural(m);
                if (try c.propDeclaredForIn(r, prop)) |p| return p;
            }
            return null;
        },
        else => {},
    }
    return c.propOfType(rm, prop);
}

pub fn narrowByInProp(c: *Checker, t: TypeId, prop: Atom, sense: bool) Error!TypeId {
    // tsc's `narrowByInKeyword`: the filtering branch only applies when the
    // name is a *known* property — declared on some constituent, or covered
    // by one's string index signature. For an unknown name the true branch
    // is `type & Record<name, unknown>` instead, which is what makes
    //     if ("pointerType" in e && e.pointerType === "touch")   // e: MouseEvent
    // legal. The false branch of an unknown name says nothing.
    {
        const single = [_]TypeId{t};
        const members: []const TypeId = if (c.ts.kind(t) == .union_type)
            try c.memberList(t)
        else
            &single;
        var known = false;
        for (members) |m| {
            const rm = try c.resolveStructural(m);
            if ((try c.propOfType(rm, prop)) != null or
                c.ts.kind(rm) == .any or c.ts.kind(rm) == .unknown or
                (c.ts.kind(rm) == .object and c.ts.objectStringIndex(rm) != types.no_type))
            {
                known = true;
                break;
            }
        }
        if (!known) {
            if (!sense) return t;
            const rec = try c.ts.makeObject(
                &.{.{ .name = prop, .ty = types.unknown_type }},
                types.no_type,
                types.no_type,
                0,
            );
            return c.ts.makeIntersection(c.scratch(), &.{ t, rec });
        }
    }
    if (c.ts.kind(t) != .union_type) return t;
    var parts: std.ArrayList(TypeId) = .empty;
    defer parts.deinit(c.scratch());
    for (try c.memberList(t)) |m| {
        const rm = try c.resolveStructural(m);
        const found = try c.propDeclaredForIn(rm, prop);
        const has = found != null;
        const optional = if (found) |p| p.optional() else false;
        const kept = if (sense) has else (!has or optional);
        if (kept) try parts.append(c.scratch(), m);
    }
    return c.ts.makeUnion(c.scratch(), parts.items);
}

/// DECLARED type of a dotted path of plain names (`m.isA`, `this.a.b`),
/// resolved structurally: the root symbol's declared type followed by
/// property lookups. No expression is checked, no flow narrowing runs and
/// nothing is memoized, so this is safe to call from inside the flow walk
/// itself — where re-checking the expression would both re-enter an
/// in-progress flow query (a receiver transiently re-widened to its
/// declared type) and publish that transient answer into `node_types`.
///
/// Returns `no_type` for anything it cannot resolve exactly; the caller
/// treats that as "no information" (sound under-narrowing).
pub fn declaredPathType(c: *Checker, node: Node) Error!TypeId {
    c.side_query_depth += 1;
    defer c.side_query_depth -= 1;
    // A property lookup can materialize a generic instantiation and trip
    // the instantiation limit; whether it trips *here* rather than at the
    // authoritative check depends on what this checker already cached, so a
    // narrowing query must not be allowed to anchor a TS2589.
    const saved = c.suppress_inst_diag;
    defer c.suppress_inst_diag = saved;
    c.suppress_inst_diag = true;
    return c.declaredPathTypeInner(node);
}

/// tsc's `isDeclarationWithExplicitTypeAnnotation`, asked of every
/// declaration of a variable symbol: only such a symbol may be
/// materialized from inside a flow walk (see `declaredPathTypeInner`).
pub fn symExplicitlyTyped(c: *Checker, sym: SymbolId) bool {
    const f = c.symFlags(sym);
    if (!(f.var_decl or f.let_decl or f.const_decl)) return false;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    var annotated = false;
    for (c.declsOf(sym)) |decl| {
        switch (c.nodeTag(decl)) {
            // `const x = <init>`: no annotation by construction.
            .declarator_init => return false,
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, c.tree.nodeData(decl).rhs);
                if (e.type_ann == 0) return false;
                annotated = true;
            },
            // The type-space half of a merge (`interface Array<T>` beside
            // `declare var Array: ArrayConstructor`) says nothing about
            // how the VALUE is typed.
            else => {},
        }
    }
    return annotated;
}

/// Does `sym` denote a NAMESPACE VALUE — a `namespace`/`module` declaration,
/// or an import binding that names a whole module (`import * as NS from "m"`,
/// and the re-exported `export * as NS` form)? tsc's `SymbolFlags.ValueModule`
/// after alias resolution; see the call site for why it is resolved outright.
fn symIsNamespaceValue(c: *Checker, sym: SymbolId) bool {
    const f = c.symFlags(sym);
    if (f.type_only) return false;
    if (f.namespace_decl) return true;
    if (!f.import_binding) return false;
    const tgt = c.importTarget(sym) orelse return false;
    return tgt.kind == .namespace or tgt.kind == .ambient_ns;
}

pub fn declaredPathTypeInner(c: *Checker, node: Node) Error!TypeId {
    switch (c.nodeTag(node)) {
        .paren_expr => return c.declaredPathTypeInner(c.tree.nodeData(node).lhs),
        .this_expr => return if (c.this_type != 0) c.this_type else types.no_type,
        .identifier => {
            const tok = c.tree.nodeMainToken(node);
            if (c.tree.tokens.tag(tok) == .keyword_undefined) return types.no_type;
            const a = try c.atomOfToken(tok);
            return switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| blk: {
                    // Read-only: a narrowing query must not be what *starts*
                    // a symbol's materialization. Doing so pulls the work
                    // into the middle of the flow walk, where a dependency
                    // that is already in progress resolves to `any` — and
                    // that answer is then cached as the symbol's type for
                    // the rest of the run.
                    if (sym == binder.no_symbol or sym >= c.sym_types.items.len) break :blk types.no_type;
                    if (c.sym_state.items[sym] == .computed) break :blk c.sym_types.items[sym];
                    if (c.sym_state.items[sym] == .in_progress) break :blk types.no_type;
                    // tsc's `getExplicitTypeOfSymbol` DOES resolve a
                    // variable whose declaration carries an explicit type
                    // ANNOTATION: reading an annotation costs no inference
                    // and cannot pull a function body into the flow walk.
                    // Refusing it made the answer depend on whether this
                    // checker happened to have materialized the symbol
                    // yet, which varies with how the files were
                    // partitioned — `Array.isArray(x)` narrowed at
                    // `--checkers=1` and silently did not at
                    // `--checkers=4`, because the lib's `declare var
                    // Array: ArrayConstructor` was still cold in the
                    // checker that owned the file.
                    // tsc's `getExplicitTypeOfSymbol` resolves a ValueModule
                    // outright, and so must this: a namespace object's type
                    // is a fact of the module graph, not an inference over a
                    // body, so reading it neither depends on nor disturbs any
                    // narrowing state — which is what the rule above guards.
                    //
                    // Without it the receiver of `NS.isFoo(x)` answered "no
                    // information" whenever this checker had not already
                    // materialized the namespace import, so the guard was
                    // dropped and nothing narrowed — order-dependently, since
                    // an already-`.computed` symbol short-circuits above.
                    // Every @atproto/api guard on social-app is written that
                    // way (`ChatBskyConvoDefs.isGroupConvo(prev.kind)`,
                    // `AppBskyEmbedRecord.isView(embed)`).
                    if (symIsNamespaceValue(c, sym)) break :blk try c.typeOfSymbol(sym);
                    if (!c.symExplicitlyTyped(sym)) break :blk types.no_type;
                    break :blk try c.typeOfSymbol(sym);
                },
                else => types.no_type,
            };
        },
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            const obj = try c.declaredPathTypeInner(d.lhs);
            if (obj == types.no_type) return types.no_type;
            const name = try c.memberAtom(d.rhs);
            const recv = try c.nonNullable(obj);
            // The identifier arm's rule, one level down: a property lookup
            // on a class whose own member table is mid-materialization
            // would *build* that table, so answer "no information" instead.
            if (try c.classSideOnCycle(recv, 0)) return types.no_type;
            const p = (try c.propOfType(recv, name)) orelse return types.no_type;
            return p.ty;
        },
        else => return types.no_type,
    }
}

/// Is `recv` a CLASS receiver — `typeof C` (the static side) or a `C`
/// instance — whose member table is *currently being materialized*?
///
/// `propOfType` on such a receiver runs `classStaticType` / `expandRef`,
/// computing every member's type. That is exactly what a narrowing query
/// must never do while the class is on the cycle: a sibling whose own
/// materialization is already on the stack answers `any` (`typeOfSymbol`'s
/// cycle break), and that `any` is then memoized as the *asking* member's
/// type for the rest of the run.
///
/// That is the circular-accessor defect. A static getter whose body narrows
/// a field it initializes (`if (!C._r) C._r = C.init(); return C._r;`) was
/// demanded from inside `init`'s own return-type inference, because the
/// effects-signature probe on an ordinary call statement in that body
/// (`C.reg.call(o);` → `guardCallOf` → `declaredPathType` → here) built
/// `typeof C`. With `init` in progress the assignment's right-hand side
/// reads as `any`, `assignmentReduced` keeps the DECLARED `… | undefined`,
/// and the getter caches that — a `possibly undefined` on every later read.
///
/// tsc never gets there: its equivalent probe (`getEffectsSignature` →
/// `getTypeOfDottedName`) resolves one property symbol, and the predicate
/// test it feeds (`hasTypePredicateOrNeverReturnType`) consults only an
/// *annotated* return type, so no inferred return is ever forced.
///
/// The answer here is the same shape as `refExpansionActive` /
/// `lazyRefProp`: off the cycle nothing changes (the caller's ordinary
/// `propOfType` runs, byte for byte as before); on it the query answers
/// `no_type`, "no information" — the sound under-narrowing it already
/// promises for everything it cannot resolve exactly.
pub fn classSideOnCycle(c: *Checker, recv: TypeId, depth: u32) Error!bool {
    if (depth >= lazy_base_depth) return false;
    const statics = switch (c.ts.kind(recv)) {
        .class_value => true,
        .ref => false,
        else => return false,
    };
    const cls = if (statics) c.ts.classSymbol(recv) else c.ts.refSymbol(recv);
    if (!c.symFlags(cls).class) return false;
    // The instance side marks its own in-progress table (`expandRef` and
    // `classInstanceGeneric` both park `no_type` there).
    if (!statics and c.refExpansionActive(recv)) return true;
    // Either side is also on the cycle when one of its member symbols is
    // mid-`typeOfSymbol` — which is how `classStaticType`'s loop, and every
    // demand that reaches a member directly, marks its progress.
    const saved_ctx = c.enterSymFile(cls);
    defer c.restoreCtx(saved_ctx);
    if (if (statics) c.bind.staticsScopeOf(c.localOf(cls)) else c.bind.membersScopeOf(c.localOf(cls))) |ms| {
        const lo = c.bind.scope_members_start[ms];
        const hi = c.bind.scope_members_start[ms + 1];
        for (lo..hi) |i| {
            const msym = c.toGlobal(c.bind.member_syms[i]);
            if (msym == binder.no_symbol or msym >= c.sym_types.items.len) continue;
            if (c.sym_state.items[msym] == .in_progress) return true;
        }
    }
    // Inherited members come from the base's table, so a base on the cycle
    // is this receiver on the cycle too.
    if (try c.baseClassSym(cls)) |base| {
        const base_recv = if (statics)
            try c.ts.makeClassValue(base)
        else
            try c.ts.makeRef(base, &.{});
        return c.classSideOnCycle(base_recv, depth + 1);
    }
    return false;
}

/// A resolved predicate call: the callee's predicate and the argument
/// expression sitting in the guarded parameter's position.
pub const GuardCall = struct { pred: types.Predicate, arg: Node };

/// If `call`'s callee is a predicate signature, return that predicate
/// together with the argument in the guarded parameter's position.
pub fn guardCallOf(c: *Checker, call: Node) Error!?GuardCall {
    const shape = c.callShape(call);
    // Obtain the callee's type for predicate inspection. When the callee is
    // a MEMBER/element access (`rule.abstract.startsWith`), re-checking it
    // here — a flow-narrowing side query — would re-evaluate its receiver;
    // if this query is a re-entrant walk of a loop back-edge triggered by
    // the very call statement/condition being checked (loop label still in
    // progress), the receiver is transiently re-widened to its declared
    // type, so the member access raises a spurious TS18048/2532 and caches a
    // poisoned type. So the memoized type is used when the callee has
    // already been checked top-down.
    //
    // An un-memoized member callee is not always that re-entrant state,
    // though: `inferReturnType` is a probe that checks a function's
    // `return` EXPRESSIONS directly, so in a function without a return
    // annotation `if (m.isA(e)) return e.av;` reaches here with `m.isA`
    // never checked — and the guard was silently dropped, which is what
    // made member-callee predicates look unsupported. Resolve the callee
    // structurally instead (`declaredPathType`): a type predicate is a
    // property of the declaration, so the declared type answers the
    // question, and the lookup neither narrows, checks nor memoizes.
    //
    // A plain NAME follows tsc's `getExplicitTypeOfSymbol`: a function,
    // class or namespace is resolved outright, but a *variable without a
    // type annotation* is not — computing it here would run its
    // initializer's inference from inside the flow walk. tsc gives up
    // entirely there; ztsc uses the answer when the symbol happens to be
    // resolved already (`declaredPathType`) and otherwise treats the call
    // as carrying no information. An unannotated `const f = (…) => {…}`
    // holding an *assertion* is not expressible anyway — `asserts x is T`
    // is a return-type annotation — so nothing is lost, while the arrow
    // body (which may reach back into a class whose members are mid-
    // materialization) is never checked at this point.
    const callee = shape.callee;
    const callee_t = switch (c.nodeTag(callee)) {
        .member_expr, .optional_member_expr, .index_expr, .optional_index_expr => c.nodeType(callee) orelse
            try c.declaredPathType(callee),
        .identifier => if (c.calleeNeedsExplicitDecl(callee))
            c.nodeType(callee) orelse try c.declaredPathType(callee)
        else
            try c.checkExprCached(callee, types.no_type),
        else => try c.checkExprCached(callee, types.no_type),
    };
    if (callee_t == types.no_type) return null;
    if (!c.ts.fnHasPredicate(callee_t)) return null;
    // A GENERIC guard names its own type parameter in the predicate
    // (`isMemberOf = <T extends string>(coll: readonly T[], v: string):
    // v is T`). The DECLARED signature therefore narrows the argument to
    // the naked `T`; tsc reads the predicate off the call's RESOLVED
    // signature, whose `T` is the inferred type argument. There is no
    // resolved-signature memo here, so re-run the same inference the call
    // itself ran — silently, since anything it files inside the argument
    // list is an artifact of this side query and the real check of the
    // call reports it (or not) on its own.
    const sig_t = if (c.ts.fnTypeParams(callee_t).len == 0) callee_t else blk: {
        const saved = c.diags.items.len;
        var targs: std.ArrayList(TypeId) = .empty;
        defer targs.deinit(c.scratch());
        for (shape.targ_nodes) |tn| {
            if (tn != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(tn));
        }
        const inst = try c.instantiateSigForCall(callee_t, targs.items, shape.arg_nodes, call, types.no_type);
        c.rollbackArgDiags(saved, c.cur_file, shape.arg_nodes);
        break :blk if (c.ts.fnHasPredicate(inst)) inst else callee_t;
    };
    const pred = c.ts.fnPredicate(sig_t);
    if (pred.param == types.Predicate.this_param) return null; // `this is T`: gap
    if (pred.param >= shape.arg_nodes.len) return null;
    const arg = shape.arg_nodes[pred.param];
    if (arg == null_node) return null;
    return .{ .pred = pred, .arg = arg };
}

/// tsc's `isDeclarationWithExplicitTypeAnnotation`, asked the other way
/// round: does this plain-name callee resolve to a VARIABLE whose type
/// would have to be *inferred from an initializer*? That is the one case
/// `getExplicitTypeOfSymbol` refuses to resolve, because inferring it is
/// arbitrary work — including a function-body walk — pulled into the
/// middle of a flow walk.
///
/// ztsc keeps one case tsc gives up on, because it costs nothing and the
/// app relies on it: an unannotated `const isX = (n): n is T => …`. The
/// predicate a guard probe is looking for *is* a return-type annotation,
/// so a declaration that carries one can be resolved without inferring
/// anything, and a declaration that carries none has no predicate to
/// find — resolving it could only cost a body walk.
pub fn calleeNeedsExplicitDecl(c: *Checker, callee: Node) bool {
    const tok = c.tree.nodeMainToken(callee);
    const a = c.atomOfToken(tok) catch return false;
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return false,
    };
    if (sym == binder.no_symbol) return false;
    const f = c.symFlags(sym);
    if (!(f.var_decl or f.let_decl or f.const_decl)) return false;
    const saved = c.enterSymFile(sym);
    defer c.restoreCtx(saved);
    for (c.declsOf(sym)) |decl| {
        const d = c.tree.nodeData(decl);
        switch (c.nodeTag(decl)) {
            .declarator_init => {
                // `const x = <init>` — no annotation by construction.
                if (d.rhs != 0 and c.initReturnsPredicate(d.rhs)) return false;
            },
            .declarator_full => {
                const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
                if (e.type_ann != 0) return false; // annotated: resolve it
                if (e.init != 0 and c.initReturnsPredicate(e.init)) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Is `init` a function/arrow literal whose RETURN TYPE ANNOTATION is a
/// type predicate (`x is T` / `asserts x is T`)? The only initializer
/// shape a guard probe can learn anything from without inferring.
pub fn initReturnsPredicate(c: *Checker, init_node: Node) bool {
    switch (c.nodeTag(init_node)) {
        .arrow_fn, .function_expr => {},
        else => return false,
    }
    const proto = c.tree.extraData(ast.FnProto, c.tree.nodeData(init_node).lhs);
    if (proto.return_type == 0) return false;
    return c.nodeTag(proto.return_type) == .type_predicate;
}

/// `if (isT(x))` — a user-defined type guard used in a condition.
/// True branch narrows the argument to the predicate type; the false
/// branch takes the complement (union filtering handles both).
pub fn narrowByGuardCall(c: *Checker, t: TypeId, call: Node, sense: bool, key: RefKey) Error!TypeId {
    const g = (try c.guardCallOf(call)) orelse return t;
    if (!try c.refMatches(g.arg, key)) return c.narrowByGuardArgChain(t, g, sense, key);
    const pred = g.pred;
    if (pred.asserts) return t; // assertion fns narrow after the call, not here
    if (pred.ty == types.no_type) return t;
    return c.narrowByInstance(t, pred.ty, sense);
}

/// tsc's `narrowTypeByTypePredicate` optional-chain arm: the guarded
/// ARGUMENT is an optional chain whose receiver is the tracked reference
/// (`Array.isArray(data?.detail)`). A nullish receiver short-circuits the
/// chain to `undefined`, so when the predicate's asserted type cannot BE
/// `undefined`, the asserting branch proves the receiver did not
/// short-circuit — narrow it to non-null. Only the true branch says
/// anything (a failed predicate is equally consistent with a nullish
/// receiver), which is why tsc gates this on `assumeTrue`.
pub fn narrowByGuardArgChain(c: *Checker, t: TypeId, g: GuardCall, sense: bool, key: RefKey) Error!TypeId {
    if (!sense) return t;
    if (g.pred.asserts) return t; // narrows after the call, not in the condition
    if (g.pred.ty == types.no_type) return t;
    if (try c.admitsNullish(g.pred.ty, .undefined)) return t;
    if (!try c.optionalChainContainsRef(g.arg, key)) return t;
    return c.nonNullable(t);
}

/// `assertIsT(x);` — an assertion-function call statement narrows the
/// argument to the asserted type for the rest of the flow; a bare
/// `asserts cond` narrows by truthiness.
pub fn narrowByAssertCall(c: *Checker, t: TypeId, call: Node, key: RefKey, decl: TypeId) Error!TypeId {
    const g = (try c.guardCallOf(call)) orelse return t;
    if (!g.pred.asserts) return t; // plain guards don't narrow as statements
    if (g.pred.ty == types.no_type) {
        // `asserts cond` (no `is T`): tsc's `narrowTypeByAssertion` hands
        // the ARGUMENT EXPRESSION to the condition narrower with
        // `assumeTrue`, so `invariant(x !== null)` / `assert(typeof v ===
        // "string")` narrows through the operator. Requiring the tracked
        // reference to *be* the argument only ever caught the degenerate
        // `assert(x)` — which the same call still handles, via the
        // identifier arm's truthiness narrowing.
        return c.narrowByCondition(t, g.arg, true, key, decl);
    }
    // `asserts x is T` names its subject positionally: it must be the arg.
    if (!try c.refMatches(g.arg, key)) return t;
    return c.narrowByInstance(t, g.pred.ty, true);
}

/// tsc's `getInstanceType(constructorType)`: prefer the `prototype`
/// property type (when present and not `any`), else the union of the
/// construct signatures' return types. Returns `no_type` when the RHS is
/// not a usable constructor (→ no narrowing, sound under-narrowing).
pub fn instanceTypeOfConstructor(c: *Checker, rt: TypeId) Error!TypeId {
    if (try c.propOfType(rt, try c.internText("prototype"))) |p| {
        const k = c.ts.kind(p.ty);
        if (k != .any and k != .err and k != .unknown) return p.ty;
    }
    var obj = rt;
    if (c.ts.kind(obj) == .ref) obj = try c.expandRef(obj);
    if (c.ts.kind(obj) == .object) {
        const n = c.ts.objectConstructSigCount(obj);
        if (n > 0) {
            var rets: std.ArrayList(TypeId) = .empty;
            defer rets.deinit(c.scratch());
            for (0..n) |i| {
                try rets.append(c.scratch(), c.ts.fnReturn(c.ts.objectConstructSig(obj, @intCast(i))));
            }
            return c.ts.makeUnion(c.scratch(), rets.items);
        }
    }
    return types.no_type;
}

/// The instance type produced by `x instanceof RHS`, or `null` when the
/// RHS is not a usable constructor (→ no narrowing). A plain `class`
/// value maps to `C<any…>`. An `.intersection` of constructors is handled
/// member-wise: a `declare module` augmentation merges a class declaration
/// with itself into `typeof C & typeof C`, and mixins yield `typeof A &
/// typeof B` — in both cases the constructor is NOT a `.class_value`, so
/// without this the narrowing collapsed (`instanceTypeOfConstructor` finds
/// no `prototype`/construct sig on the intersection and gives up), leaving
/// the operand at its declared base type.
pub fn instanceofInstanceType(c: *Checker, rt: TypeId) Error!?TypeId {
    switch (c.ts.kind(rt)) {
        .class_value => {
            const cls = c.ts.classSymbol(rt);
            var tps: std.ArrayList(TypeParamInfo) = .empty;
            defer tps.deinit(c.scratch());
            try c.typeParamsOf(cls, &tps);
            const args = try c.scratch().alloc(TypeId, tps.items.len);
            for (args) |*x| x.* = types.any_type;
            return try c.ts.makeRef(cls, args);
        },
        .intersection => {
            var insts: std.ArrayList(TypeId) = .empty;
            defer insts.deinit(c.scratch());
            for (try c.memberList(rt)) |m| {
                const mi = (try c.instanceofInstanceType(m)) orelse continue;
                var seen = false;
                for (insts.items) |e| {
                    if (e == mi) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try insts.append(c.scratch(), mi);
            }
            if (insts.items.len == 0) {
                const inst = try c.instanceTypeOfConstructor(rt);
                return if (inst == types.no_type) null else inst;
            }
            if (insts.items.len == 1) return insts.items[0];
            return try c.ts.makeIntersection(c.scratch(), insts.items);
        },
        else => {
            const inst = try c.instanceTypeOfConstructor(rt);
            return if (inst == types.no_type) null else inst;
        },
    }
}

pub fn isNullishKind(k: types.Kind) bool {
    return k == .null or k == .undefined or k == .void;
}

/// `instance` genuinely contains the nullish kind `k` — as itself, as a
/// union constituent, or because it is `any`/`unknown`. Deliberately NOT
/// an assignability question: an all-optional object is assignable FROM
/// `undefined` in ztsc's relation, and that is what this guards against.
pub fn admitsNullish(c: *Checker, instance: TypeId, k: types.Kind) Error!bool {
    const r = try c.resolveStructural(instance);
    const rk = c.ts.kind(r);
    if (rk == .any or rk == .unknown or rk == .err) return true;
    if (rk == k) return true;
    if (rk == .undefined and k == .void) return true;
    if (rk == .void and k == .undefined) return true;
    if (rk == .union_type) {
        for (0..c.ts.memberCount(r)) |i| {
            if (try c.admitsNullish(c.ts.memberAt(r, i), k)) return true;
        }
    }
    return false;
}

pub fn narrowByInstance(c: *Checker, t: TypeId, instance: TypeId, sense: bool) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(c.scratch());
        for (try c.memberList(t)) |m| {
            var matches = try c.isAssignable(m, instance);
            // tsc's `getNarrowedTypeWorker` filters with the SUBTYPE
            // relation, and `undefined`/`null` are subtypes of nothing but
            // themselves. Under plain assignability a "weak" guard type —
            // an object whose properties are ALL optional, the shape of
            // every `json is Lib` validator — accepts them, so
            // `if (!isValidLibrary(data)) throw` left `undefined` in the
            // guarded branch and every later use reported TS18048.
            if (matches and isNullishKind(c.ts.kind(m)) and !try c.admitsNullish(instance, c.ts.kind(m)))
                matches = false;
            const kept = if (sense) matches else !matches;
            if (kept) try parts.append(c.scratch(), m);
        }
        const result = try c.ts.makeUnion(c.scratch(), parts.items);
        if (sense and result == types.never_type) {
            if (try c.isAssignable(instance, t)) return instance;
            // tsc's `getNarrowedTypeWorker` does not stop when no
            // constituent is directly related to the candidate: it then
            // keeps every constituent that is still INSTANTIABLE (a
            // deferred conditional, `keyof`, indexed access, or a bare type
            // parameter) and whose *constraint* the candidate is comparable
            // to — such a constituent can still be instantiated to
            // something the guard accepts, so narrowing it away is wrong.
            // `isShallowEqual`'s `comparators` is
            // `{ [k in keyof T]?: … } | (keyof T extends K[number] ? … )`,
            // and `Array.isArray(comparators)` filtered BOTH constituents
            // out, leaving `never` — so iterating the guarded value was
            // TS2488.
            for (try c.memberList(t)) |m| {
                if (!isInstantiableKind(c.ts.kind(m))) continue;
                const bc = try c.deferredDefaultConstraint(m, 0);
                if (bc == m) continue;
                if (try c.isAssignable(instance, bc)) return instance;
            }
            // tsc's tail is `getIntersectionType([type, candidate])`, and
            // for a union `type` that distributes into a union of
            // intersections — one per constituent. Most of them are
            // uninhabited (`{ type: "text" } & { type: "arrow" }`), and
            // tsc drops those in `getReducedType` before anything reads
            // the narrowed type. Doing the intersection WITHOUT that
            // reduction is what made this arm stop at `never` before: the
            // dead constituents leaked into spreads and inferred returns
            // and produced eight false TS2345s across rxjs.
            const isect = try c.ts.makeIntersection(c.scratch(), &.{ t, instance });
            return try c.reduceNeverIntersections(isect);
        }
        return result;
    }
    if (sense) {
        // tsc's `getNarrowedTypeWorker` opens with
        // `if (type.flags & AnyOrUnknown) return candidate` — an `any`
        // subject takes the guard's type outright. This has to come before
        // the assignability tests: `any` is assignable to everything, so
        // the first of them would otherwise keep `any` and drop the guard
        // (`Array.isArray(x)` on `any` never yielding `any[]`).
        const k = c.ts.kind(t);
        if (k == .any or k == .unknown or k == .err) return instance;
        // Same subtype rule as the union arm above: a guard whose type does
        // not itself admit `undefined`/`null` leaves nothing behind (tsc
        // ends at `undefined & Lib`, which is `never`).
        if (isNullishKind(k) and !try c.admitsNullish(instance, k)) return types.never_type;
        // tsc filters with the SUBTYPE relation, and a `readonly T[]` is
        // not a subtype of a mutable `U[]` — it has no `push`. The reverse
        // does hold, so `getNarrowedTypeWorker`'s second clause fires and
        // the narrowed type is the GUARD's: `Array.isArray(x)` on a
        // `readonly T[]` yields `any[]`, not `readonly T[]`. ztsc's
        // relation is deliberately readonly-blind, so both directions are
        // "assignable" here and the subject would win instead.
        if (k == .array and c.ts.arrayIsReadonly(t) and
            c.ts.kind(instance) == .array and !c.ts.arrayIsReadonly(instance))
            return instance;
        if (try c.isAssignable(t, instance)) return t;
        if (try c.isAssignable(instance, t)) return instance;
        // Unrelated `t` and guard `C`: tsc narrows to the intersection
        // `t & C` (e.g. `Array.isArray(s)` with `s: string` → `string &
        // any[]`, which carries the array members; disjoint primitives
        // reduce to `never`). Previously kept `t`, dropping the guard, so
        // `s.map(...)` in the true branch reported TS2339 on `string`.
        return c.ts.makeIntersection(c.scratch(), &.{ t, instance });
    }
    return t;
}

pub fn narrowBySwitchClause(c: *Checker, t: TypeId, clause: Node, key: RefKey, decl: TypeId) Error!TypeId {
    if (clause == null_node) return t;
    // Find the owning switch statement's discriminant: clause nodes
    // don't back-reference it, so scan: the discriminant condition
    // narrows only when it's the reference or `ref.prop`.
    const sw = c.switchOfClause(clause) orelse return t;
    const disc = c.tree.nodeData(sw).lhs;
    const is_default = c.nodeTag(clause) == .default_clause;

    var prop: Atom = 0;
    var direct = false;
    if (try c.refMatches(disc, key)) {
        direct = true;
    } else if (try c.discriminantOfRef(disc, key)) |prop_tok| {
        prop = try c.memberAtom(prop_tok);
    }
    if (!direct and prop == 0 and c.nodeTag(disc) == .prefix_unary and try c.typeofTargetOf(disc, key)) {
        // switch (typeof x)
        if (is_default) return t;
        const test_node = c.tree.nodeData(clause).lhs;
        const tt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
        if (c.ts.kind(tt) == .string_literal) {
            return c.narrowByTypeof(t, c.ts.literalAtom(tt), true);
        }
        return t;
    }
    if (!direct and prop == 0) return t;

    if (is_default) {
        // tsc's `narrowTypeBySwitchOnDiscriminant` narrows the DISCRIMINANT
        // type first and only then filters the constituents: when no
        // discriminant value survives the `case` labels the clause is
        // unreachable and the narrowed type is `never`. The per-member
        // subtraction below can only drop a member whose discriminant is a
        // single literal, so it leaves a member with a WIDE discriminant
        // (`type: "line" | "arrow"`) — and a naked type parameter
        // (`switch (t)` on `T extends "a" | "b"`) — alive in `default:`,
        // which is the false positive on every `assertNever(x)` idiom.
        if (try c.switchDefaultCovered(sw, t, prop, decl)) return types.never_type;
        // Exclude every case value.
        var cur = t;
        const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
        for (c.tree.extraRange(r.start, r.end)) |cl| {
            if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
            const test_node = c.tree.nodeData(cl).lhs;
            if (test_node == 0) continue;
            const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
            if (!c.ts.isLiteralLike(vt) and c.ts.kind(vt) != .null and c.ts.kind(vt) != .undefined) continue;
            cur = if (prop == 0)
                try c.narrowExcludeValue(cur, vt)
            else
                try c.narrowByDiscriminant(cur, prop, vt, false, decl);
        }
        return cur;
    }
    const test_node = c.tree.nodeData(clause).lhs;
    if (test_node == 0) return t;
    const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
    const is_lit = c.ts.isLiteralLike(vt) or c.ts.kind(vt) == .null or c.ts.kind(vt) == .undefined;
    if (!is_lit) return t;
    return if (prop == 0)
        try c.narrowToValue(t, vt)
    else
        try c.narrowByDiscriminant(t, prop, vt, true, decl);
}

/// Every value the discriminant can take is covered by a `case` label, so
/// the `default:` clause is unreachable (tsc's `narrowTypeBySwitchOnDiscriminant`
/// reduces the discriminant to `never` there). `prop == 0` means the switch
/// is on the reference itself, otherwise on `ref.prop`.
///
/// Answers `false` for anything it cannot decide exactly — a case label
/// that is not a unit value, a member without the discriminant property, a
/// non-literal discriminant — so the caller falls back to the per-member
/// subtraction, which is sound but coarser.
pub fn switchDefaultCovered(c: *Checker, sw: Node, t: TypeId, prop: Atom, decl: TypeId) Error!bool {
    // Discriminant-based exhaustiveness needs an actual discriminated union,
    // for the same reason `narrowByDiscriminant` does — tsc reaches
    // `narrowTypeBySwitchOnDiscriminantProperty` only through
    // `getDiscriminantPropertyAccess`. Switching on the reference ITSELF
    // (`prop == 0`) is plain equality narrowing and applies to any type.
    if (prop != 0) {
        const over = if (c.ts.kind(decl) == .union_type) decl else t;
        if (!try c.isDiscriminantProp(over, prop)) return false;
    }
    var vals: std.ArrayList(TypeId) = .empty;
    defer vals.deinit(c.scratch());
    const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(sw).rhs);
    for (c.tree.extraRange(r.start, r.end)) |cl| {
        if (cl == null_node or c.nodeTag(cl) != .case_clause) continue;
        const test_node = c.tree.nodeData(cl).lhs;
        if (test_node == 0) continue;
        const vt = try c.ts.regularLiteral(try c.checkExprCached(test_node, types.no_type));
        if (!c.ts.isLiteralLike(vt) and c.ts.kind(vt) != .null and c.ts.kind(vt) != .undefined)
            return false;
        try vals.append(c.scratch(), vt);
    }
    if (vals.items.len == 0) return false;
    const single = [_]TypeId{t};
    const members: []const TypeId = if (c.ts.kind(t) == .union_type)
        try c.memberList(t)
    else
        &single;
    if (members.len == 0) return false;
    for (members) |m| {
        var d = m;
        if (prop != 0) {
            const rm = try c.resolveStructural(m);
            const p = (try c.propOfType(rm, prop)) orelse return false;
            if (p.optional()) return false;
            d = p.ty;
        }
        if (!try c.discriminantCovered(d, vals.items, 0)) return false;
    }
    return true;
}

/// Every value of the discriminant type `d0` is one of `vals`.
pub fn discriminantCovered(c: *Checker, d0: TypeId, vals: []const TypeId, depth: u32) Error!bool {
    if (depth > 4) return false;
    var d = try c.resolveStructural(d0);
    // A naked type parameter stands for its constraint: tsc substitutes
    // constraints for a narrowable reference before the flow walk, which is
    // what makes `switch (t)` over `T extends "a" | "b"` exhaustive.
    if (c.ts.kind(d) == .type_param) d = try c.resolveStructural(try c.baseConstraintOf(d));
    switch (c.ts.kind(d)) {
        // Every constituent must be covered.
        .union_type => {
            for (try c.memberList(d)) |dm| {
                if (!try c.discriminantCovered(dm, vals, depth + 1)) return false;
            }
            return true;
        },
        // An intersection's value satisfies every constituent, so one
        // covered constituent covers the whole.
        .intersection => {
            for (try c.memberList(d)) |dm| {
                if (try c.discriminantCovered(dm, vals, depth + 1)) return true;
            }
            return false;
        },
        else => {},
    }
    const dv = try c.ts.regularLiteral(d);
    if (!c.ts.isLiteralLike(dv) and c.ts.kind(dv) != .null and c.ts.kind(dv) != .undefined)
        return false;
    for (vals) |v| {
        if (dv == v) return true;
    }
    return false;
}

/// The switch statement owning a case/default clause (linear scan of
/// switch nodes; cached would be overkill for the subset).
pub fn switchOfClause(c: *Checker, clause: Node) ?Node {
    // Clause nodes are created right after their tests and before the
    // switch node itself; scan forward from the clause for a switch
    // whose clause range contains it.
    var n: Node = clause + 1;
    const total: Node = @intCast(c.tree.nodes.len);
    while (n < total) : (n += 1) {
        if (c.nodeTag(n) != .switch_stmt) continue;
        const r = c.tree.extraData(ast.SubRange, c.tree.nodeData(n).rhs);
        for (c.tree.extraRange(r.start, r.end)) |cl| {
            if (cl == clause) return n;
        }
    }
    return null;
}

// --- definite assignment (TS2454) ------------------------------------

pub fn definitelyAssigned(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
    if (flow == binder.no_flow or flow == binder.unreachable_flow) return true;
    const key = (@as(u64, flow) << 32) | sym;
    if (c.da_cache.get(key)) |v| {
        if (v == 2) return true; // optimistic on loops
        return v == 1;
    }
    try c.da_cache.put(c.cm(), key, 2);
    const result = try c.definitelyAssignedInner(flow, sym);
    try c.da_cache.put(c.cm(), key, @intFromBool(result));
    return result;
}

pub fn definitelyAssignedInner(c: *Checker, flow: FlowId, sym: SymbolId) Error!bool {
    const b = c.bind;
    switch (b.flow_tags[flow]) {
        .none => return true,
        .unreachable_ => return true,
        .start => return false,
        .assign => {
            const target = b.flowNode(flow);
            if (try c.assignTargetsSymForDa(target, sym)) return true;
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .cond_true, .cond_false, .switch_clause, .call_stmt => {
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .switch_no_match => {
            // The "no clause matched" edge out of a `default`-less switch.
            // When the switch is exhaustive over a literal-union
            // discriminant the edge is unreachable, so it constrains
            // nothing — a `let x: number` assigned in every clause is
            // definitely assigned afterwards, exactly as tsc sees it.
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            c.cur_scope = b.flowScope(flow);
            if (c.switchIsExhaustive(b.flowNode(flow))) return true;
            return c.definitelyAssigned(b.flow_a[flow], sym);
        },
        .branch_label, .loop_label => {
            for (b.flowAntecedents(flow)) |a| {
                if (!try c.definitelyAssigned(a, sym)) return false;
            }
            return true;
        },
    }
}

pub fn assignTargetsSymForDa(c: *Checker, target: Node, sym: SymbolId) Error!bool {
    if (target == null_node) return false;
    switch (c.nodeTag(target)) {
        .declarator_init => return c.patternBindsSym(c.tree.nodeData(target).lhs, sym),
        .declarator_full => {
            const d = c.tree.nodeData(target);
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.init == 0) return false;
            return c.patternBindsSym(d.lhs, sym);
        },
        .assign => {
            const d = c.tree.nodeData(target);
            return c.patternBindsSym(d.lhs, sym);
        },
        .prefix_unary, .postfix_unary => {
            return c.identIsSym(c.tree.nodeData(target).lhs, sym);
        },
        .var_decl_one, .var_decl => return c.varDeclBindsSym(target, sym),
        else => return c.patternBindsSym(target, sym),
    }
}
