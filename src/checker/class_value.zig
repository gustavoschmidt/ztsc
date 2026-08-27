//! The OUTER type parameters of a class — tsc's `outerTypeParameters`, and
//! the two operations they exist for.
//!
//! A class declared inside a generic can mention the enclosing declaration's
//! type parameters:
//!
//! ```ts
//! function outer<T>(x: T) {
//!   class Inner { static y: T = x; }
//!   return Inner;
//! }
//! let y: number = outer(5).y;   // `y` is `number`, not `T`
//! ```
//!
//! `typeof Inner` is therefore not one type but a family, indexed by `T` —
//! tsc models it as an anonymous type whose `outerTypeParameters` are the
//! parameters in lexical scope at the declaration, and instantiates it
//! through `getObjectTypeInstantiation` like any other generic. ztsc's
//! `.class_value` carries the same thing: a list of type ARGUMENTS filling
//! those parameters (see `types.Kind.class_value`). The list is empty for
//! every class outside a generic scope, which is nearly all of them, and an
//! empty list interns to the exact id the kind had before it existed.
//!
//! `classValueOf` is the one producer: it mints `typeof C` with each outer
//! parameter standing for itself, so an ordinary `instantiate` — the call's
//! own argument substitution — fills them in on the way out of the generic.
//! `outerArgMap` is the one consumer: it turns a filled-in class value back
//! into the substitution its members must be read under.
//!
//! Functions take the `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const scanner = @import("../frontend/scanner.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const Atom = @import("../intern.zig").Atom;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const TpMap = @import("enums.zig").TpMap;

/// `typeof C`, with `C`'s outer type parameters standing for themselves.
///
/// Every producer of a class value goes through here so the id is the same
/// one whichever side reached it (a name reference, a static member's `this`,
/// a namespace merge). Degenerates to the bare `makeClassValue` — the same
/// interned id as before outer arguments existed — for a class with no
/// generic declaration around it.
pub fn classValueOf(c: *Checker, cls: SymbolId) Error!TypeId {
    const tps = try outerTypeParams(c, cls);
    if (tps.len == 0) return c.ts.makeClassValue(cls);
    const args = try c.scratch().alloc(TypeId, tps.len);
    defer c.scratch().free(args);
    for (args, tps) |*a, tp| a.* = try c.ts.makeTypeParam(tp);
    return c.ts.makeClassValueArgs(cls, args);
}

/// The substitution a FILLED-IN class value denotes, appended to `buf`:
/// each outer type parameter paired with the argument standing in for it.
///
/// Empty — and cheap — for the two cases that are not an instantiation: a
/// class value with no outer parameters at all, and one whose arguments are
/// still the parameters themselves (the shape `classValueOf` mints, which is
/// what every reference inside the generic reads).
fn outerArgMap(c: *Checker, cv: TypeId, buf: *std.ArrayList(TpMap)) Error!void {
    const n = c.ts.classValueArgs(cv).len;
    if (n == 0) return;
    const tps = try outerTypeParams(c, c.ts.classSymbol(cv));
    // A class value interned before the class's list was memoized under a
    // different file context could disagree; the substitution is then not
    // expressible and the members are read generically, exactly as they were
    // before this payload existed.
    if (tps.len != n) return;
    for (tps, 0..) |tp, i| {
        const arg = c.ts.classValueArgs(cv)[i];
        if (c.ts.kind(arg) == .type_param and c.ts.typeParamSymbol(arg) == tp) continue;
        try buf.append(c.scratch(), .{ .sym = tp, .ty = arg });
    }
}

/// `ty` read under the substitution `cv`'s outer arguments denote — the one
/// call every consumer of a class value's members makes. A pass-through
/// whenever `outerArgMap` is empty.
pub fn instantiateOuter(c: *Checker, cv: TypeId, ty: TypeId) Error!TypeId {
    if (c.ts.classValueArgs(cv).len == 0) return ty;
    var map: std.ArrayList(TpMap) = .empty;
    defer map.deinit(c.scratch());
    try outerArgMap(c, cv, &map);
    if (map.items.len == 0) return ty;
    return c.instantiate(ty, map.items);
}

/// The type parameters in lexical scope at `cls`'s declaration, outermost
/// scope last (the order is arbitrary but stable — the list is only ever
/// zipped with a positional argument list it minted itself).
///
/// Memoized per class symbol (`Checker.class_outer_tps`): the answer is a
/// pure function of the program, the walk costs a file-context switch and a
/// scope-chain traversal, and the overwhelmingly common answer — the empty
/// list, for every class not inside a generic — must cost one map probe.
pub fn outerTypeParams(c: *Checker, cls: SymbolId) Error![]const SymbolId {
    if (c.class_outer_tps.get(cls)) |l| return l;
    var out: std.ArrayList(SymbolId) = .empty;
    defer out.deinit(c.scratch());
    try collectOuterTypeParams(c, cls, &out);
    const owned = try c.cm().dupe(SymbolId, out.items);
    try c.class_outer_tps.put(c.cm(), cls, owned);
    return owned;
}

fn collectOuterTypeParams(c: *Checker, cls: SymbolId, out: *std.ArrayList(SymbolId)) Error!void {
    // A namespace object is a class value too (see `computeTypeOfSymbol`), and
    // has no declaration this walk could read; so is a MERGED id, whose parts
    // are the real declarations. Neither can be nested in a generic — merging
    // happens in a namespace or the global scope — so both answer empty.
    if (!c.symFlags(cls).class or c.prog.isMergedId(cls)) return;
    const saved = c.enterSymFile(cls);
    defer c.restoreCtx(saved);
    const decl = blk: {
        for (c.declsOf(cls)) |d| {
            if (c.nodeTag(d) == .class_decl) break :blk d;
        }
        return;
    };
    // The class's OWN scope holds its OWN parameters (see `static_tp_scope`),
    // so the walk starts at its parent.
    const own = (try c.scopeOf(decl)) orelse return;
    var scope = c.bind.scope_parents[own];
    // Has the walk left a function body on the way out? tsc's
    // `isTypeParameterPossiblyReferenced` gives up — and keeps the parameter —
    // as soon as a BLOCK sits between the declaration and the parameter's
    // owner, because a block can hold anything.
    var crossed_body = false;
    while (scope != binder.file_scope) : (scope = c.bind.scope_parents[scope]) {
        const kind = c.bind.scope_kinds[scope];
        // A `.function` scope IS the body for this purpose: its parameters
        // and its statements share it.
        const keep_all = crossed_body or kind == .function;
        const lo = c.bind.scope_members_start[scope];
        const hi = c.bind.scope_members_start[scope + 1];
        for (lo..hi) |i| {
            const local = c.bind.member_syms[i];
            if (!c.bind.symbol_flags[local].type_param) continue;
            if (!keep_all and !mentionsName(c, decl, c.bind.member_atoms[i])) continue;
            try out.append(c.scratch(), c.toGlobal(local));
        }
        if (kind == .function or kind == .block) crossed_body = true;
    }
}

/// Is `name` written as an identifier anywhere inside `decl`?
///
/// The syntactic half of tsc's `isTypeParameterPossiblyReferenced`, which
/// walks the declaration looking for a reference that resolves to the
/// parameter. Asked only where tsc asks it — a class nested directly in a
/// generic class's member, with no block in between — and only about a class
/// that already sits inside a generic, so it never runs on the common path.
///
/// A name that occurs but resolves elsewhere (a shadowing local, a property
/// of that name) keeps a parameter tsc would drop, which costs an argument
/// slot and nothing else. Not seeing an occurrence at all leaves the class
/// exactly as it was before outer arguments existed — which is also what an
/// occurrence spelled with a `\uXXXX` escape gets, since the comparison is on
/// raw source text: it INTERNS nothing, so a walk over a class body cannot
/// mint atoms and perturb the interner's numbering.
fn mentionsName(c: *Checker, decl: Node, name: Atom) bool {
    const want = c.atomText(name);
    const span = c.nodeSpan(decl);
    const toks = &c.tree.tokens;
    // Token starts ascend, so the node's own tokens are one contiguous run.
    var i = firstTokenAt(toks, span.start);
    while (i < toks.starts.len and toks.start(i) < span.end) : (i += 1) {
        if (toks.tag(i) != .identifier) continue;
        if (std.mem.eql(u8, c.tokenText(@intCast(i)), want)) return true;
    }
    return false;
}

/// Index of the first token starting at or after `offset`.
///
/// Hand-rolled rather than `std.sort.lowerBound` over `Tokens.starts`,
/// because that array is NOT the offsets: the scanner packs the
/// preceded-by-newline bit into the top bit of each word, so every token at
/// the start of a line sorts above 2^31. `Tokens.start` is the accessor that
/// masks it, and the search has to go through it.
fn firstTokenAt(toks: *const scanner.Tokens, offset: u32) usize {
    var lo: usize = 0;
    var hi: usize = toks.starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (toks.start(mid) < offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}
