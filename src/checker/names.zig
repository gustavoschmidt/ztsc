//! Name resolution (value vs type space) and literal freshness / widening helpers.
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const paths = @import("../link/paths.zig");

const Atom = intern.Atom;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

const indexOfAtom = @import("generics.zig").indexOfAtom;

// =====================================================================
// name resolution (value vs type space)
// =====================================================================

/// Import bindings are optimistic in both spaces (the target decides;
/// refined at use sites via the link tables) except that a type-only
/// import never has value meaning (TS1361 at value uses).
pub fn hasValueMeaning(f: binder.SymbolFlags) bool {
    if (f.import_binding and f.type_only) return false;
    return f.var_decl or f.let_decl or f.const_decl or f.function or f.class or
        f.param or f.catch_param or f.import_binding or f.enum_decl or f.namespace_decl or
        f.enum_member;
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

/// Which SPACE a lookup is asking about — tsc's `meaning` argument to
/// `resolveName`. A name is skipped, and the walk continues outward, unless
/// the symbol it found carries the requested meaning.
pub const Meaning = enum {
    value,
    type_space,
    /// The qualifier of a dotted name (`A.B`), which must be a container:
    /// a namespace, an enum, or an alias that may resolve to one. A `class`
    /// carries type meaning and is NOT a container, which is what lets
    /// `var x = class C { prop: C.type }` find the outer `namespace C`
    /// (tsc's `resolveName(..., SymbolFlags.Namespace)`).
    namespace,

    fn matches(m: Meaning, f: binder.SymbolFlags) bool {
        return switch (m) {
            .value => hasValueMeaning(f),
            .type_space => hasTypeMeaning(f),
            .namespace => f.namespace_decl or f.enum_decl or f.import_binding,
        };
    }
};

/// Resolve in the current file's scope chain; returns GLOBAL ids.
pub fn resolveSpace(c: *Checker, a: Atom, from: ScopeId, want_value: bool) Resolved {
    return resolveSpaceInner(c, a, from, if (want_value) .value else .type_space, false);
}

/// `resolveSpace` for the QUALIFIER of a dotted name — see `Meaning`.
pub fn resolveNamespaceSpace(c: *Checker, a: Atom, from: ScopeId) Resolved {
    return resolveSpaceInner(c, a, from, .namespace, false);
}

/// `resolveSpace` for the operand of a `typeof` TYPE QUERY, where a
/// type-only import binding counts as a value.
///
/// tsc gives a type-only import alias the target's full meaning and reports
/// TS1361 as a separate use-site check, so the binding SHADOWS an outer
/// declaration of the same name whether or not the use is a value position.
/// ztsc filters it out of value space instead, and the walk then simply kept
/// going: `import type { File } from 'expo-file-system'` was skipped in the
/// file scope and `typeof File` bound the DOM's global `File` constructor.
/// expo's own `class File extends ExpoFileSystem.FileSystemFile` — where
/// `FileSystemFile: typeof File` names that import — inherited the DOM's
/// `Blob` instead of the file-system file, so `uri`, `exists`, `open`,
/// `copy` and `delete` were all missing.
///
/// A type query is a TYPE position, so accepting the binding here reports no
/// TS1361 that tsc does not: every value position still goes through
/// `resolveSpace`.
pub fn resolveTypeQuerySpace(c: *Checker, a: Atom, from: ScopeId) Resolved {
    return resolveSpaceInner(c, a, from, .value, true);
}

fn resolveSpaceInner(c: *Checker, a: Atom, from: ScopeId, meaning: Meaning, type_only_ok: bool) Resolved {
    const want_value = meaning == .value;
    var s = from;
    var wrong: SymbolId = binder.no_symbol;
    while (true) {
        if (c.bind.lookupInScope(s, a)) |sym| {
            const f = c.bind.symbol_flags[sym];
            const ok = meaning.matches(f) or
                (want_value and type_only_ok and f.import_binding and f.type_only);
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
            // A TYPE-ONLY import binding SHADOWS whatever an outer scope (or
            // the lib) declares under the same name: tsc gives the alias the
            // target's full meaning and reports TS1361 as a separate use-site
            // check, so the walk must stop here rather than fall through to a
            // global. `import type { File } from "expo-file-system"` followed
            // by a value use of `File` is TS1361, not the DOM's constructor.
            if (want_value and f.import_binding and f.type_only) {
                return .{ .wrong_space = c.toGlobal(sym) };
            }
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
                const ok = meaning.matches(gf) or
                    (want_value and type_only_ok and gf.import_binding and gf.type_only);
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
        if (meaning.matches(gf)) return .{ .sym = gsym };
        if (wrong == binder.no_symbol) return .{ .wrong_space = gsym };
    }
    if (wrong != binder.no_symbol) return .{ .wrong_space = c.toGlobal(wrong) };
    return .none;
}

/// What a bare private name `#x` resolved to.
pub const PrivateName = union(enum) {
    /// The declaring class member (a LOCAL symbol id in the current file).
    member: binder.SymbolId,
    /// Inside a class body, but no class on the chain declares the name.
    no_such_member,
    /// No enclosing class body at all — TS18016.
    outside_class,
};

/// Resolve a bare private name, tsc's
/// `lookupSymbolForPrivateIdentifierDeclaration`: walk out through the
/// enclosing CLASS scopes and take the first that declares the name, on
/// either its instance or its static side. The grammar admits a bare `#x`
/// in exactly one expression — the ergonomic brand check `#x in obj` — so
/// this is not a hot path.
///
/// A class's member scopes are NOT in the lexical chain (a method body's
/// parent is the class scope itself), so they are reached through the owner
/// node `bindClass` gives all three.
pub fn resolvePrivateName(c: *Checker, a: Atom, from: ScopeId) PrivateName {
    var s = from;
    var in_class = false;
    while (true) {
        if (c.bind.scope_kinds[s] == .class) {
            in_class = true;
            const owner = c.bind.scope_owners[s];
            for (c.bind.scope_kinds, 0..) |k, i| {
                switch (k) {
                    .class_members, .class_statics => {},
                    else => continue,
                }
                if (c.bind.scope_owners[i] != owner) continue;
                if (c.bind.lookupInScope(@intCast(i), a)) |sym| return .{ .member = sym };
            }
        }
        if (s == binder.file_scope) break;
        s = c.bind.scope_parents[s];
    }
    return if (in_class) .no_such_member else .outside_class;
}

/// Longest name this module will score. tsc has no ceiling; a stack DP row
/// needs one. The length pre-filter inside `spellCandidateDistance` already
/// bounds an admissible candidate to `name.len * 1.34 + 2`, so a name at the
/// ceiling admits nothing wider than `spell_scratch_len`.
const spell_max_len = 160;
const spell_scratch_len = 256;

/// Weighted edit distance in tenths (tsc's `levenshteinWithMax` costs) of
/// `cand` against `name`, or null when the candidate is inadmissible, too long
/// to score on the stack, or worse than `cap` tenths. `cap` is INCLUSIVE.
fn spellDistance(name: []const u8, cand: []const u8, cap: usize) ?usize {
    if (cand.len >= spell_scratch_len) return null;
    var scratch: [2 * spell_scratch_len]usize = undefined;
    return intern.spellCandidateDistance(name, cand, cap, scratch[0 .. 2 * (cand.len + 1)]);
}

/// Edit distance <= threshold spelling suggestion among scope-visible
/// names (tsc's TS2552/TS2551 "Did you mean ...?").
///
/// The metric is tsc's `getSpellingSuggestion`, not a plain Levenshtein
/// distance: a substitution costs TWICE an insert or a delete (0.1 when the
/// two characters differ only in case), and the bound to beat is
/// `floor(name.len * 0.4) + 1`. The asymmetry is the whole point — tsc will
/// suggest a name reachable by adding or dropping characters (`remove` for
/// `move`) and refuses one that needs letters exchanged (`store` for `sort`,
/// `restore` for `rootStore`, `all` for `add`), where a symmetric-cost
/// distance says yes to all of them and turns tsc's plain TS2339/TS2304 into
/// a bogus "Did you mean".
///
/// tsc iterates each scope's symbol table in DECLARATION order and only
/// replaces the incumbent on a strictly smaller distance, so among
/// equal-distance candidates the first-declared wins (verified against the
/// pinned oracle: swapping two tied declarations swaps the suggestion).
/// `member_atoms` is sorted by ATOM id for binary-search lookup, and atom
/// ids are interning order, not declaration order — iterating it and taking
/// the first tie would pick by an unrelated ordering (and, before the ids
/// were made scheduling-independent, a run-to-run unstable one, which is how
/// this surfaced). `member_syms` carries the binder's SymbolId, handed out in a
/// single sequential walk of the file's AST, so it *is* declaration order:
/// break ties toward the smaller symbol id and the pick matches tsc and is
/// stable for any --workers/--checkers count.
///
/// The tie-break is scope-local (`best_scope`). Scopes are visited
/// innermost-first, and an inner symbol can have a larger id than an outer
/// one declared earlier in the file, so comparing ids across scopes would
/// let an outer candidate beat an inner one; tsc's shrinking threshold
/// never does.
///
/// The walk ends in the GLOBAL (lib) table, exactly as `resolveSpaceInner`
/// does: `getSuggestedSymbolForNonexistentSymbol` rides tsc's ordinary
/// `resolveNameHelper`, whose last stop is the global symbol table, so an
/// unresolved `$ERROR` really does suggest the lib's `Error`. Scanning the
/// whole table is only reached on the ERROR path (a name that resolved to
/// nothing), which is where tsc computes suggestions too, and the length
/// pre-filter inside `spellCandidateDistance` rejects all but a sliver of it
/// before any DP row is built.
pub fn suggestName(c: *Checker, a: Atom, from: ScopeId, want_value: bool) ?Atom {
    const text = c.atomText(a);
    if (text.len == 0 or text.len > spell_max_len) return null;
    var best: ?Atom = null;
    var best_sym: binder.SymbolId = 0;
    var best_scope: ScopeId = 0;
    // The incumbent came from the global table rather than a lexical scope,
    // so the declaration-order tie-break must compare global ids with global
    // ids (a lexical `SymbolId` and a program-wide global id are different
    // numbering spaces).
    var best_global = false;
    // Inclusive acceptance bound in tenths; shrinks to the incumbent's
    // distance so a strictly closer candidate wins outright and an exactly
    // tied one falls to the declaration-order tie-break below.
    var best_d: usize = intern.spellInitialCapTenths(text.len);
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
            const d = spellDistance(text, cand_text, best_d) orelse continue;
            const better = best == null or d < best_d or
                (d == best_d and !best_global and s == best_scope and sym < best_sym);
            if (!better) continue;
            best_d = d;
            best_sym = sym;
            best_scope = s;
            best_global = false;
            best = cand;
        }
        if (s == binder.file_scope) break;
        s = c.bind.scope_parents[s];
    }
    // Globals are visited last, so a lexical candidate at the same distance
    // keeps the suggestion (tsc only replaces on a strictly smaller one);
    // among globals the smaller id — the earlier lib declaration — wins.
    for (c.prog.globals.atoms, c.prog.globals.syms) |cand, gsym| {
        if (cand == a) continue;
        const gf = c.symFlags(gsym);
        const ok = if (want_value) hasValueMeaning(gf) else hasTypeMeaning(gf);
        if (!ok) continue;
        const cand_text = c.atomText(cand);
        const d = spellDistance(text, cand_text, best_d) orelse continue;
        const better = best == null or d < best_d or
            (d == best_d and best_global and gsym < best_sym);
        if (!better) continue;
        best_d = d;
        best_sym = gsym;
        best_global = true;
        best = cand;
    }
    return best;
}

/// Report a name that resolved to nothing at `tok`, choosing tsc's code the
/// way `getCannotFindNameDiagnosticForName` does: a name some well-known typings
/// package would have declared gets that package's flavoured message instead of
/// the generic TS2304 — the five `@types/node` globals (TS2591/TS2580), `$`
/// (TS2592/TS2581) and a test runner's `describe`/`suite`/`it`/`test`
/// (TS2593/TS2582). Each pair differs only by whether `compilerOptions.types`
/// named an explicit list to add the package to.
///
/// Callers keep ownership of the spelling-suggestion arm (TS2552), which wins
/// over both — tsc tries `getSuggestedSymbolForNonexistentSymbol` before it
/// falls back to the not-found message, so `require` with `Required` in scope
/// is TS2552, not TS2591.
/// tsc's `checkAndReportErrorForUsingTypeAsValue`: six primitive TYPE names
/// are never values, and a value-position use of one is TS2693 rather than
/// any not-found message — checked before the spelling suggestion, so
/// `var x = number` is "'number' only refers to a type" and not "did you mean
/// 'Number'". The list is tsc's, verbatim; `bigint`, `symbol`, `object`,
/// `void` and `undefined` are deliberately NOT on it.
pub fn primitiveTypeNameUsedAsValue(text: []const u8) bool {
    const names = [_][]const u8{ "any", "string", "number", "boolean", "never", "unknown" };
    for (names) |n| {
        if (std.mem.eql(u8, text, n)) return true;
    }
    return false;
}

pub fn reportNameNotFound(c: *Checker, tok: ast.TokenIndex) Error!void {
    const text = c.tokenText(tok);
    // `types_wildcard` is "the program named no explicit `types` list", which is
    // the half of each pair tsc phrases without the "and then add … to the types
    // field" tail.
    const no_types_list = c.prog.types_wildcard;
    if (paths.isNodeGlobalName(text)) {
        if (no_types_list) {
            try c.diagFmt(2580, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node`.", .{text});
        } else {
            try c.diagFmt(2591, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node` and then add 'node' to the types field in your tsconfig.", .{text});
        }
    } else if (std.mem.eql(u8, text, "$")) {
        // tsc's arm is the bare `$` alone; `jQuery` gets the generic message.
        if (no_types_list) {
            try c.diagFmt(2581, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for jQuery? Try `npm i --save-dev @types/jquery`.", .{text});
        } else {
            try c.diagFmt(2592, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for jQuery? Try `npm i --save-dev @types/jquery` and then add 'jquery' to the types field in your tsconfig.", .{text});
        }
    } else if (paths.isTestRunnerGlobalName(text)) {
        if (no_types_list) {
            try c.diagFmt(2582, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for a test runner? Try `npm i --save-dev @types/jest` or `npm i --save-dev @types/mocha`.", .{text});
        } else {
            try c.diagFmt(2593, c.tokSpan(tok), "Cannot find name '{s}'. Do you need to install type definitions for a test runner? Try `npm i --save-dev @types/jest` or `npm i --save-dev @types/mocha` and then add 'jest' or 'mocha' to the types field in your tsconfig.", .{text});
        }
    } else {
        try c.diagFmt(2304, c.tokSpan(tok), "Cannot find name '{s}'.", .{text});
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

/// `suggestName`'s property twin (the TS2551 "Did you mean" arm of a failed
/// member access), on tsc's `getSpellingSuggestion` metric — see there.
pub fn suggestProp(c: *Checker, a: Atom, obj: TypeId) ?Atom {
    const text = c.atomText(a);
    if (text.len == 0 or text.len > spell_max_len) return null;
    var best: ?Atom = null;
    var best_d: usize = intern.spellInitialCapTenths(text.len);
    const t = c.resolveStructural(obj) catch return null;
    if (c.ts.kind(t) != .object) return null;
    for (0..c.ts.objectPropCount(t)) |i| {
        const p = c.ts.objectProp(t, @intCast(i));
        const cand_text = c.atomText(p.name);
        const d = spellDistance(text, cand_text, best_d) orelse continue;
        if (best == null or d < best_d) {
            best_d = d;
            best = p.name;
        } else if (d == best_d and std.mem.order(u8, cand_text, c.atomText(best.?)) == .lt) {
            // Tie on distance: prefer the lexicographically smaller name so
            // the suggestion is byte-identical across --workers (props are
            // iterated in atom order, which is not stable).
            best = p.name;
        }
    }
    return best;
}

// =====================================================================
// literal freshness / widening helpers
// =====================================================================

/// tsc's `isConstTypeVariable`: is `t` a `const` TYPE PARAMETER (TS 5.0
/// `f<const T>(…)`), or a union with one as a member? An expression whose
/// CONTEXTUAL type is one is checked in a const context — literal types kept,
/// object/array literals readonly — which is the whole of what `const` on a
/// type parameter means at an argument position (tsc's `isConstContext`:
/// `isValidConstAssertionArgument(node) && isConstTypeVariable(contextualType)`).
///
/// The union arm is the only nesting ztsc's contextual types actually produce
/// here (`T | undefined` at an optional parameter); tsc also descends indexed
/// accesses, conditionals, mapped types and variadic tuples, which ztsc leaves
/// as a deliberate under-application — the literal is then checked as if the
/// parameter had no `const`, i.e. exactly today's behavior.
pub fn isConstTypeVar(c: *Checker, t: TypeId) bool {
    switch (c.ts.kind(t)) {
        .type_param => return c.isConstTypeParamSym(c.ts.typeParamSymbol(t)),
        .union_type => {
            for (0..c.ts.memberCount(t)) |i| {
                const m = c.ts.memberAt(t, @intCast(i));
                if (c.ts.kind(m) == .type_param and
                    c.isConstTypeParamSym(c.ts.typeParamSymbol(m))) return true;
            }
            return false;
        },
        else => return false,
    }
}

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

/// tsc's `getBaseTypeOfLiteralType`: EVERY literal type — fresh or not —
/// stands for its base primitive here, an enum member for its whole enum, a
/// template pattern / string-mapping for `string`, and a union member-wise.
/// Everything else is returned unchanged.
///
/// Distinct from `widenLiteral`, which is tsc's *widening* (`getWidenedType`)
/// and only fires on FRESHNESS: a declared `const x: "abc"` never widens, and
/// must not. This one is what `checkAssertionWorker` runs on the source of an
/// `as` cast before the comparable test, which is why `x as "def"` and `1 as 2`
/// are legal TypeScript: the cast is judged `string`-vs-`"def"`, not
/// `"abc"`-vs-`"def"`.
pub fn baseTypeOfLiteral(c: *Checker, t: TypeId) Error!TypeId {
    if (c.ts.kind(t) == .union_type) {
        var list: std.ArrayList(TypeId) = .empty;
        defer list.deinit(c.scratch());
        var moved = false;
        for (try c.memberList(t)) |m| {
            const b = try baseTypeOfLiteral(c, m);
            if (b != m) moved = true;
            try list.append(c.scratch(), b);
        }
        if (!moved) return t;
        return c.ts.makeUnion(c.scratch(), list.items);
    }
    const base = try literalBaseOf(c, t);
    return if (base != types.no_type) base else t;
}

/// Fresh literal -> base primitive; unions widen fresh members; object
/// literals are WIDENED (`widenObjectLiterals`), losing both their freshness
/// and their literal origin — this is tsc's mutable-location widening
/// (`getWidenedType`), so it belongs at a variable initializer, an inferred
/// return, or an inference result, not at a property of a literal still being
/// built (that is `widenPropValue`).
pub fn widenLiteral(c: *Checker, t: TypeId) Error!TypeId {
    return widenLiteralInner(c, t, true);
}

/// Widening for a value written *inside* another literal — an object-literal
/// property or an array-literal element. tsc reaches these through
/// `checkExpressionForMutableLocation`, whose
/// `getWidenedLiteralLikeTypeForContextualType` widens a fresh PRIMITIVE
/// literal and calls `getRegularTypeOfLiteralType`, neither of which touches
/// an object type's flags: a nested object literal keeps `ObjectLiteral` (and
/// in tsc its freshness too, which is how nested excess-property checking
/// works — ztsc drives that from the syntax instead, so freshness is still
/// dropped here).
///
/// Keeping the ORIGIN is what makes `f({x: {a: 1}, y: {b: 2}})` infer the
/// object-literal candidate UNION rather than the leftmost candidate alone.
pub fn widenPropValue(c: *Checker, t: TypeId) Error!TypeId {
    return widenLiteralInner(c, t, false);
}

fn widenLiteralInner(c: *Checker, t: TypeId, widen_objects: bool) Error!TypeId {
    if (c.ts.isFreshLiteral(t)) {
        const base = try c.literalBaseOf(t);
        return if (base != types.no_type) base else t;
    }
    switch (c.ts.kind(t)) {
        .union_type => {
            var any_fresh = false;
            for (try c.memberList(t)) |m| {
                if (c.ts.isFreshLiteral(m) or c.ts.objectIsLiteralOrigin(m)) any_fresh = true;
            }
            if (!any_fresh) return t;
            // Sibling normalization runs before the members are widened away
            // (see `normalizeFreshObjectSiblings`).
            const norm = if (widen_objects) try c.normalizeFreshObjectSiblings(t) else t;
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            for (try c.memberList(norm)) |m| try list.append(c.scratch(), try widenLiteralInner(c, m, widen_objects));
            return c.ts.makeUnion(c.scratch(), list.items);
        },
        .object => return if (widen_objects) c.ts.widenedObject(t) else c.ts.regular(t),
        else => return t,
    }
}

/// tsc's `getWidenedType` restricted to its object-literal half: the union of
/// inference candidates is widened unconditionally at the end of
/// `getCovariantInference`, even when the literal-widening arm above it was
/// skipped because the type parameter occurs at the top level of the return
/// type. That widening is what normalizes the object-literal siblings against
/// each other and then strips their literal origin.
pub fn widenObjectLiterals(c: *Checker, t: TypeId) Error!TypeId {
    switch (c.ts.kind(t)) {
        .union_type => {
            var any = false;
            for (try c.memberList(t)) |m| {
                if (c.ts.objectIsLiteralOrigin(m)) any = true;
            }
            if (!any) return t;
            const norm = try c.normalizeFreshObjectSiblings(t);
            var list: std.ArrayList(TypeId) = .empty;
            defer list.deinit(c.scratch());
            for (try c.memberList(norm)) |m| try list.append(c.scratch(), try c.ts.widenedObject(m));
            return c.ts.makeUnion(c.scratch(), list.items);
        },
        .object => return c.ts.widenedObject(t),
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
/// exactly why this keys off the literal ORIGIN (tsc's
/// `ObjectFlags.ObjectLiteral`, the flag `getWidenedTypeWithContext` tests)
/// and runs before the members are widened. Freshness is the wrong key: it is
/// gone by the time an object literal written as a property of another
/// literal reaches an inference candidate union.
///
/// Members that were not written as object literals are left alone and do not
/// contribute names, so a mixed `cond ? { a: 1 } : someDeclaredThing`
/// normalizes nothing. Returns `u` unchanged unless at least two literal
/// members actually differ in their key sets.
pub fn normalizeFreshObjectSiblings(c: *Checker, u: TypeId) Error!TypeId {
    const s = &c.ts;
    if (s.kind(u) != .union_type) return u;
    const members = try c.memberList(u);
    const take = try c.scratch().alloc(bool, members.len);
    defer c.scratch().free(take);
    for (members, take) |m, *t| t.* = s.objectIsLiteralOrigin(m);
    const out = (try undefinedSiblingMembers(c, members, take)) orelse return u;
    return s.makeUnion(c.scratch(), out);
}

/// The widening-context rule itself, over a POSITIONAL member list: `take[i]`
/// says whether member `i` takes part — tsc's `ObjectFlags.ObjectLiteral`
/// test, decided by the caller. Returns a list aligned with `members`, or null
/// when no member gained anything.
///
/// Split out of `normalizeFreshObjectSiblings` for the one caller whose
/// members are not a union and no longer carry the flag: an array literal's
/// per-element types have already been widened by the time they meet each
/// other (`expr.zig`'s `arrayLiteralElemType`), so it decides participation
/// from the RAW element types it kept alongside.
pub fn undefinedSiblingMembers(c: *Checker, members: []const TypeId, take: []const bool) Error!?[]TypeId {
    const s = &c.ts;
    std.debug.assert(members.len == take.len);
    var count: u32 = 0;
    for (take) |t| {
        if (t) count += 1;
    }
    if (count < 2) return null;
    // The union of every participating member's property names.
    var names: std.ArrayList(Atom) = .empty;
    defer names.deinit(c.scratch());
    for (members, take) |m, t| {
        if (!t) continue;
        for (0..s.objectPropCount(m)) |i| {
            const p = s.objectProp(m, @intCast(i));
            if (indexOfAtom(names.items, p.name) == null) try names.append(c.scratch(), p.name);
        }
    }
    var out: std.ArrayList(TypeId) = .empty;
    defer out.deinit(c.scratch());
    var changed = false;
    for (members, take) |m, t| {
        if (!t or s.objectPropCount(m) == names.items.len) {
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
    if (!changed) return null;
    const owned: []TypeId = try out.toOwnedSlice(c.scratch());
    return owned;
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
    if (c.ts.kind(norm) == .object) return c.ts.widenedObject(norm);
    if (c.ts.kind(norm) != .union_type) return norm;
    var list: std.ArrayList(TypeId) = .empty;
    defer list.deinit(c.scratch());
    var changed = false;
    for (try c.memberList(norm)) |m| {
        const r = if (c.ts.kind(m) == .object) try c.ts.widenedObject(m) else m;
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
                if (c.ts.isFreshLiteral(m) or c.ts.objectIsLiteralOrigin(m)) any_fresh = true;
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
