//! Name resolution (value vs type space) and literal freshness / widening helpers.
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
const paths = @import("../link/paths.zig");
const ZeroPagedArray = @import("../zeropage.zig").ZeroPagedArray;

const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;
const Store = types.Store;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const atom = Checker.atom;
const checkObjectLiteral = @import("expr.zig").checkObjectLiteral;
const indexOfAtom = @import("generics.zig").indexOfAtom;
const run = Checker.run;

// =====================================================================
// name resolution (value vs type space)
// =====================================================================

/// Import bindings are optimistic in both spaces (the target decides;
/// refined at use sites via the link tables) except that a type-only
/// import never has value meaning (TS1361 at value uses).
pub fn hasValueMeaning(f: binder.SymbolFlags) bool {
    if (f.import_binding and f.type_only) return false;
    return f.var_decl or f.let_decl or f.const_decl or f.function or f.class or
        f.param or f.catch_param or f.import_binding or f.enum_decl or f.namespace_decl;
}

pub fn hasTypeMeaning(f: binder.SymbolFlags) bool {
    return f.class or f.interface or f.type_alias or f.type_param or
        f.import_binding or f.enum_decl or f.namespace_decl;
}

pub const Resolved = union(enum) {
    sym: SymbolId,
    wrong_space: SymbolId,
    none,
};

/// Resolve in the current file's scope chain; returns GLOBAL ids.
pub fn resolveSpace(c: *Checker, a: Atom, from: ScopeId, want_value: bool) Resolved {
    var s = from;
    var wrong: SymbolId = binder.no_symbol;
    while (true) {
        if (c.bind.lookupInScope(s, a)) |sym| {
            const f = c.bind.symbol_flags[sym];
            const ok = if (want_value) hasValueMeaning(f) else hasTypeMeaning(f);
            if (ok) {
                // A reference from inside a contributing file binds to the
                // file-local declaration; if that declaration is a
                // cross-file merge constituent, route to the merged symbol
                // so its full member set (folded from every file) is seen
                // Its OR-of-constituents flags keep `ok` valid.
                const g = c.toGlobal(sym);
                return .{ .sym = c.prog.mergedOf(g) orelse g };
            }
            if (wrong == binder.no_symbol) wrong = sym;
        }
        // A bare name unresolved in *this* file's copy of a namespace body
        // may be declared in another file's contribution to the same
        // cross-file-merged namespace. Real `@types/node` relies on
        // this: `namespace NodeJS { interface ProcessEnv extends Dict<…> }`
        // sits in `process.d.ts` while `interface Dict<T>` is declared in
        // `globals.d.ts`'s `namespace NodeJS`. Consult the merged member
        // index for the enclosing namespace scope.
        if (c.bind.scope_kinds[s] == .namespace) {
            if (c.mergedNsMemberOfScope(s, a)) |gsym| {
                const gf = c.symFlags(gsym);
                const ok = if (want_value) hasValueMeaning(gf) else hasTypeMeaning(gf);
                if (ok) return .{ .sym = gsym };
            }
        }
        if (s == binder.file_scope) break;
        s = c.bind.scope_parents[s];
    }
    // Global (lib) fallback: bare names not found in the file's scope
    // chain resolve against the injected lib's top-level declarations
    // The table already holds GLOBAL SymbolIds.
    if (c.prog.globals.lookup(a)) |gsym| {
        const gf = c.symFlags(gsym);
        const ok = if (want_value) hasValueMeaning(gf) else hasTypeMeaning(gf);
        if (ok) return .{ .sym = gsym };
        if (wrong == binder.no_symbol) return .{ .wrong_space = gsym };
    }
    if (wrong != binder.no_symbol) return .{ .wrong_space = c.toGlobal(wrong) };
    return .none;
}

/// Edit distance <= threshold spelling suggestion among scope-visible
/// names (tsc's TS2552/TS2551 "Did you mean ...?").
///
/// tsc iterates each scope's symbol table in DECLARATION order and only
/// replaces the incumbent on a strictly smaller distance, so among
/// equal-distance candidates the first-declared wins (verified against the
/// pinned oracle: swapping two tied declarations swaps the suggestion).
/// `member_atoms` is sorted by ATOM id for binary-search lookup, and atom
/// ids depend on interning order across workers — iterating it and taking
/// the first tie would make the message run-to-run nondeterministic, which
/// it was. `member_syms` carries the binder's SymbolId, handed out in a
/// single sequential walk of the file's AST, so it *is* declaration order:
/// break ties toward the smaller symbol id and the pick matches tsc and is
/// stable for any --workers/--checkers count.
///
/// The tie-break is scope-local (`best_scope`). Scopes are visited
/// innermost-first, and an inner symbol can have a larger id than an outer
/// one declared earlier in the file, so comparing ids across scopes would
/// let an outer candidate beat an inner one; tsc's shrinking threshold
/// never does.
pub fn suggestName(c: *Checker, a: Atom, from: ScopeId, want_value: bool) ?Atom {
    const text = c.atomText(a);
    if (text.len < 3) return null;
    var best: ?Atom = null;
    var best_sym: binder.SymbolId = 0;
    var best_scope: ScopeId = 0;
    var best_d: usize = @max(2, (text.len * 34 + 99) / 100) + 1;
    var s = from;
    while (true) {
        const lo = c.bind.scope_members_start[s];
        const hi = c.bind.scope_members_start[s + 1];
        for (lo..hi) |i| {
            const cand = c.bind.member_atoms[i];
            if (cand == a) continue;
            const sym = c.bind.member_syms[i];
            const f = c.bind.symbol_flags[sym];
            const ok = if (want_value) hasValueMeaning(f) else hasTypeMeaning(f);
            if (!ok) continue;
            const cand_text = c.atomText(cand);
            const d = editDistance(text, cand_text, best_d);
            const better = d < best_d or
                (best != null and d == best_d and s == best_scope and sym < best_sym);
            if (!better) continue;
            best_d = d;
            best_sym = sym;
            best_scope = s;
            best = cand;
        }
        if (s == binder.file_scope) break;
        s = c.bind.scope_parents[s];
    }
    return best;
}

/// Report a name that resolved to nothing at `tok`, choosing tsc's code the
/// way `getCannotFindNameDiagnosticForName` does: the five globals `@types/node`
/// would have declared get the node-flavoured TS2591 (TS2580 when
/// `compilerOptions.types` holds the `"*"` wildcard, tsc's "no explicit types
/// list to add 'node' to" phrasing), everything else the generic TS2304.
///
/// Callers keep ownership of the spelling-suggestion arm (TS2552), which wins
/// over both — tsc tries `getSuggestedSymbolForNonexistentSymbol` before it
/// falls back to the not-found message, so `require` with `Required` in scope
/// is TS2552, not TS2591.
pub fn reportNameNotFound(c: *Checker, tok: ast.TokenIndex) Error!void {
    const text = c.tokenText(tok);
    if (!paths.isNodeGlobalName(text)) {
        try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{text});
    } else if (c.prog.types_wildcard) {
        try c.diagFmt(2580, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node`.", .{text});
    } else {
        try c.diagFmt(2591, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node` and then add 'node' to the types field in your tsconfig.", .{text});
    }
}

/// Report an unresolved module specifier at `spec_tok` with tsc's code for it
/// (`getCannotResolveModuleNameErrorForSpecificModule`): a specifier naming a
/// Node core module is the *name*-flavoured TS2591/TS2580 — tsc really does
/// print "Cannot find name 'node:tty'" for a missing `@types/node` — and
/// anything else is the generic TS2307.
pub fn reportModuleNotFound(c: *Checker, spec_tok: ast.TokenIndex) Error!void {
    const spec = Checker.stripQuotes(c.tokenText(spec_tok));
    if (!paths.isNodeCoreModule(spec)) {
        try c.diagFmt(2307, c.tokSpan(spec_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{spec});
    } else if (c.prog.types_wildcard) {
        try c.diagFmt(2580, c.tokSpan(spec_tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node`.", .{spec});
    } else {
        try c.diagFmt(2591, c.tokSpan(spec_tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node` and then add 'node' to the types field in your tsconfig.", .{spec});
    }
}

pub fn suggestProp(c: *Checker, a: Atom, obj: TypeId) ?Atom {
    const text = c.atomText(a);
    if (text.len < 3) return null;
    var best: ?Atom = null;
    var best_d: usize = @max(2, (text.len * 34 + 99) / 100) + 1;
    const t = c.resolveStructural(obj) catch return null;
    if (c.ts.kind(t) != .object) return null;
    for (0..c.ts.objectPropCount(t)) |i| {
        const p = c.ts.objectProp(t, @intCast(i));
        const cand_text = c.atomText(p.name);
        const d = editDistance(text, cand_text, best_d);
        if (d < best_d) {
            best_d = d;
            best = p.name;
        } else if (d == best_d and best != null and
            std.mem.order(u8, cand_text, c.atomText(best.?)) == .lt)
        {
            // Tie on edit distance: prefer the lexicographically smaller
            // name so the suggestion is byte-identical across --workers
            // (props are iterated in atom order, which is not stable).
            best = p.name;
        }
    }
    return best;
}

pub fn editDistance(a: []const u8, b: []const u8, cap: usize) usize {
    if (a.len > 32 or b.len > 32) return cap + 1;
    const big = @max(a.len, b.len);
    const small = @min(a.len, b.len);
    if (big - small > cap) return cap + 1;
    var row: [33]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        var prev = row[0];
        row[0] = i;
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const tmp = row[j];
            const cost: usize = if (toLower(a[i - 1]) == toLower(b[j - 1])) 0 else 1;
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), prev + cost);
            prev = tmp;
        }
    }
    return row[b.len];
}

pub fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

// =====================================================================
// literal freshness / widening helpers
// =====================================================================

/// `Store.literalBase`, extended with the enum-member case: the base of an
/// enum member type `E.A` is the whole enum `E` (tsc's
/// `getBaseTypeOfEnumLikeType`), so a member widens to `E`, is assignable
/// to `E`, and counts as a unit type everywhere the store's const helper
/// is consulted. Interning the whole-enum type needs the store, which is
/// why this cannot live on `Store.literalBase`.
pub fn literalBaseOf(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.isEnumMember(t)) return c.ts.makeEnumType(c.ts.enumSymbol(t));
    return c.ts.literalBase(t);
}

/// Fresh literal -> base primitive; unions widen fresh members; fresh
/// object literals lose freshness (their props were already widened at
/// creation unless contextually kept).
pub fn widenLiteral(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.isFreshLiteral(t)) {
        const base = try c.literalBaseOf(t);
        return if (base != types.no_type) base else t;
    }
    switch (c.ts.kind(t)) {
        .union_type => {
            var any_fresh = false;
            for (try c.memberList(t)) |m| {
                if (c.ts.isFreshLiteral(m) or c.ts.objectIsFresh(m)) any_fresh = true;
            }
            if (!any_fresh) return t;
            // Sibling normalization runs while the members are still fresh
            // (see `normalizeFreshObjectSiblings`), before they de-freshen.
            const norm = try c.normalizeFreshObjectSiblings(t);
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            for (try c.memberList(norm)) |m| try list.append(c.scratch(), try c.widenLiteral(m));
            return c.ts.makeUnion(c.scratch(), list.items);
        },
        .object => return c.ts.regular(t),
        else => return t,
    }
}

/// tsc's `getWidenedTypeOfObjectLiteral` + `getUndefinedProperty`: when two
/// or more *fresh* object literals are widened in the same widening
/// context — the arms of a `?:`, the elements of an array literal, the
/// `return` expressions of one function — each gains its siblings' missing
/// property names as `name?: undefined`. That is what makes
///
///     function g() { if (c) return { file: x }; return { errorMessage: y }; }
///     const r = g(); r.file;
///
/// legal: both constituents carry `file`, one of them only as `undefined`.
/// A *declared* union (`declare const r: {file: string} | {errorMessage:
/// number}`) is not normalized and `r.file` really is an error — which is
/// exactly why this keys off freshness and runs before the members
/// de-freshen.
///
/// Members that are not fresh objects are left alone and do not contribute
/// names, so a mixed `cond ? { a: 1 } : someDeclaredThing` normalizes
/// nothing. Returns `u` unchanged unless at least two fresh object members
/// actually differ in their key sets.
pub fn normalizeFreshObjectSiblings(c: *Checker, u: TypeId) Error!TypeId {
    const s = &c.ts;
    if (s.kind(u) != .union_type) return u;
    const members = try c.memberList(u);
    var fresh_count: u32 = 0;
    for (members) |m| {
        if (s.objectIsFresh(m)) fresh_count += 1;
    }
    if (fresh_count < 2) return u;
    // The union of every fresh member's property names.
    var names: std.ArrayList(Atom) = .empty;
    defer names.deinit(c.scratch());
    for (members) |m| {
        if (!s.objectIsFresh(m)) continue;
        for (0..s.objectPropCount(m)) |i| {
            const p = s.objectProp(m, @intCast(i));
            if (indexOfAtom(names.items, p.name) == null) try names.append(c.scratch(), p.name);
        }
    }
    var out: std.ArrayList(TypeId) = .empty;
    defer out.deinit(c.scratch());
    var changed = false;
    for (members) |m| {
        if (!s.objectIsFresh(m) or s.objectPropCount(m) == names.items.len) {
            try out.append(c.scratch(), m);
            continue;
        }
        var props: std.ArrayList(types.Prop) = .empty;
        defer props.deinit(c.scratch());
        for (0..s.objectPropCount(m)) |i| try props.append(c.scratch(), s.objectProp(m, @intCast(i)));
        for (names.items) |n| {
            if (s.objectPropByName(m, n) != null) continue;
            try props.append(c.scratch(), .{ .name = n, .ty = types.undefined_type, .flags = types.prop_flag_optional });
        }
        var calls: std.ArrayList(TypeId) = .empty;
        defer calls.deinit(c.scratch());
        for (0..s.objectCallSigCount(m)) |i| try calls.append(c.scratch(), s.objectCallSig(m, @intCast(i)));
        var ctors: std.ArrayList(TypeId) = .empty;
        defer ctors.deinit(c.scratch());
        for (0..s.objectConstructSigCount(m)) |i| try ctors.append(c.scratch(), s.objectConstructSig(m, @intCast(i)));
        changed = true;
        try out.append(c.scratch(), try s.makeObjectSigs(props.items, s.objectStringIndex(m), s.objectNumberIndex(m), s.objectFlags(m), calls.items, ctors.items));
    }
    if (!changed) return u;
    return s.makeUnion(c.scratch(), out.items);
}

/// Per-return widening for *inferred* (no-context) return types: like
/// `widenLiteral`, but a fresh PRIMITIVE literal is KEPT (not widened to its
/// base). This mirrors tsc: the fresh literal return-expression types are
/// unioned first, and only the *collapsed* union result is widened (see
/// `finalizeInferredReturn`). Objects/arrays still de-freshen exactly as in
/// `widenLiteral`, so object-property widening is unchanged.
pub fn widenReturnMember(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.isFreshLiteral(t)) return t; // keep — decide widening on the union
    switch (c.ts.kind(t)) {
        .union_type => {
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            for (try c.memberList(t)) |m| try list.append(c.scratch(), try c.widenReturnMember(m));
            return c.ts.makeUnion(c.scratch(), list.items);
        },
        // Fresh OBJECTS are kept too, for the same reason as fresh
        // literals: the several `return` statements of one function form a
        // single widening context, and the sibling-`undefined`
        // normalization can only be computed once they are all in the
        // union. `finalizeInferredReturn` normalizes and then de-freshens.
        .object => return t,
        else => return t,
    }
}

/// Finish an inferred (no-context) return type after unioning the
/// un-widened return members: tsc widens the union *result* only when it
/// collapsed to a single fresh literal (`() => "a"` ⇒ `string`; two same
/// literals collapse the same way), and PRESERVES a union of 2+ distinct
/// literals (`"a" | "b"`). The surviving union keeps its FRESH (widening)
/// literals — exactly as tsc, so `let x = f()` still widens to the base
/// while `const x: "a" | "b" = f()` stays assignable.
pub fn finalizeInferredReturn(c: *Checker, u: TypeId) Error!TypeId {
    if (c.ts.isFreshLiteral(u)) {
        const base = try c.literalBaseOf(u);
        return if (base != types.no_type) base else u;
    }
    // The returns of one function are one widening context: normalize the
    // fresh object members against each other, then de-freshen them
    // (`widenReturnMember` deliberately left them fresh for this).
    const norm = try c.normalizeFreshObjectSiblings(u);
    if (c.ts.kind(norm) == .object) return c.ts.regular(norm);
    if (c.ts.kind(norm) != .union_type) return norm;
    var list: std.ArrayList(TypeId) = .empty;
    defer list.deinit(c.scratch());
    var changed = false;
    for (try c.memberList(norm)) |m| {
        const r = if (c.ts.kind(m) == .object) try c.ts.regular(m) else m;
        if (r != m) changed = true;
        try list.append(c.scratch(), r);
    }
    return if (changed) c.ts.makeUnion(c.scratch(), list.items) else norm;
}

/// Widen a contextually-typed return expression: suppress literal widening
/// where the contextual return type admits the literal (tsc's
/// isLiteralOfContextualType), otherwise widen exactly as `widenLiteral`.
/// Object literals were already contextually typed member-by-member inside
/// `checkObjectLiteral` (and `widenLiteral` de-freshens an object without
/// touching its members), so only a *bare* primitive-literal return needs
/// suppression here (`() => 'Polygon'` under `() => 'Polygon'`); a union
/// distributes so a mixed `cond ? 'a' : null` keeps `'a'` under a
/// literal-admitting context. With no context this is `widenLiteral`.
pub fn widenToContext(c: *Checker, t: TypeId, ret_ctx: TypeId) Error!TypeId {
    if (ret_ctx == types.no_type) return c.widenLiteral(t);
    switch (c.ts.kind(t)) {
        .union_type => {
            var any_fresh = false;
            for (try c.memberList(t)) |m| {
                if (c.ts.isFreshLiteral(m) or c.ts.objectIsFresh(m)) any_fresh = true;
            }
            if (!any_fresh) return t;
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            for (try c.memberList(t)) |m| try list.append(c.scratch(), try c.widenToContext(m, ret_ctx));
            return c.ts.makeUnion(c.scratch(), list.items);
        },
        .string_literal, .number_literal, .number_literal_fresh, .bigint_literal, .bool_true, .bool_false => {
            if (c.ts.isFreshLiteral(t) and try c.contextAdmitsLiteral(ret_ctx, t)) return c.ts.regularLiteral(t);
            return c.widenLiteral(t);
        },
        else => return c.widenLiteral(t),
    }
}
