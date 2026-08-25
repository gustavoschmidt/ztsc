//! Atom interning and member-key construction — the one place that decides
//! what NAME a member is filed under.
//!
//! Three families, all landing on an `Atom`:
//!
//!   * **interning** (`atom`, `internText`, `atomText`, `atomOfToken`) — the
//!     per-checker `atom_cache` in front of the shared interner. `atom` keeps
//!     the caller's slice as a cache key, so anything transient must go
//!     through `internText` instead, which copies.
//!   * **syntactic keys** (`memberAtom`, `memberKey`, `stripQuotes`,
//!     `wellKnownKeyOfExpr`) — the name a property is spelled with, quotes
//!     shed and well-known symbols mapped to their `__@name` form. Mirrors
//!     the binder's own `memberKey`, and must keep mirroring it: the two
//!     index the same member tables.
//!   * **late-bound keys** (`computedSymKey`, `constSymbolKeyAtom`,
//!     `literalKeyAtom`, `uniqueSymAtom`, `nominalizeComputedKey`) — tsc's
//!     `isLateBindableName`: a computed key `[k]` is keyed nominally when
//!     `k`'s type is a `unique symbol` (`__@u<id>`), or by the literal it
//!     spells out when it is a string/number/enum-member literal. Anything
//!     else degrades to the `__@k$<name>` placeholder, which keeps the member
//!     addressable by name instead of erroring.
//!
//! `memberNameType` is the type-side counterpart: the key an entry is FILED
//! under and the key `keyof` REPORTS differ for enum-member and numeric names,
//! and both have to be produced from the same resolution.
//!
//! Split mechanically from checker.zig; functions take the `Checker` context
//! as their first parameter and are re-exported as `Checker` methods there.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");
const numeric_lit = @import("../numeric_lit.zig");
const print_zig = @import("print.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const SymbolId = binder.SymbolId;
const ScopeId = binder.ScopeId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

pub fn atom(c: *Checker, text: []const u8) Error!Atom {
    const gop = try c.atom_cache.getOrPut(c.cm(), text);
    if (!gop.found_existing) {
        gop.value_ptr.* = try c.interner.intern(c.io, c.gpa, text);
    }
    return gop.value_ptr.*;
}

/// Intern text from a *transient* buffer (a scratch/stack slice). Goes
/// straight to the interner (which copies the bytes) instead of `atom`,
/// whose `atom_cache` would otherwise store the caller's slice as a key and
/// dangle once the buffer is freed. Use for any computed/temporary string.
pub fn internText(c: *Checker, text: []const u8) Error!Atom {
    return c.interner.intern(c.io, c.gpa, text);
}

pub fn atomText(c: *Checker, a: Atom) []const u8 {
    if (a == 0) return "";
    return c.interner.lookup(c.io, a);
}

/// Atom of an identifier-ish token, `\uXXXX` escapes decoded — tsc's
/// `escapedText`, the name the binder filed the symbol under (mirrors
/// `Binder.atomOfIdent`, and must keep mirroring it: the two index the same
/// symbol tables). The decoded bytes live in a stack buffer, so they go
/// straight to the interner rather than through `atom`, whose cache would
/// keep the dangling slice as a key.
fn atomOfIdentText(c: *Checker, text: []const u8) Error!Atom {
    var buf: [scanner.max_unescaped_ident]u8 = undefined;
    const decoded = scanner.unescapeIdentifier(text, &buf) orelse return c.atom(text);
    return c.internText(decoded);
}

pub fn atomOfToken(c: *Checker, tok: TokenIndex) Error!Atom {
    return atomOfIdentText(c, c.tokenText(tok));
}

/// Property-name atom: string keys lose quotes; an identifier key's `\uXXXX`
/// escapes are decoded (a string key's are not — see `Binder.memberAtom`); a
/// NUMERIC key is canonicalized to the string JavaScript names it by, so `0`,
/// `0.0` and `"0"` are one member and `0b11010` is `26`.
pub fn memberAtom(c: *Checker, tok: TokenIndex) Error!Atom {
    const text = c.tokenText(tok);
    switch (c.tree.tokens.tag(tok)) {
        // `.jsx_string` is a JSX attribute's quoted value; a no-substitution
        // template is a string literal for naming purposes (`isStringLiteralLike`).
        .string_literal, .jsx_string, .no_substitution_template_literal => return c.atom(stripQuotes(text)),
        .numeric_literal => {
            var buf: [numeric_lit.max_name]u8 = undefined;
            return c.internText(numeric_lit.name(&buf, text));
        },
        else => return atomOfIdentText(c, text),
    }
}

/// Member-name atom honoring a `[Symbol.iterator]` computed key (mirrors the
/// binder's `memberKey`): with the `computed` flag set, `tok` names the
/// well-known symbol and the member is keyed by a synthetic `__@name` atom.
pub fn memberKey(c: *Checker, tok: TokenIndex, flags: u32) Error!Atom {
    if (flags & ast.Flags.computed_sym != 0) {
        // `[k]` / `[a.b]` computed key naming a const `unique symbol`:
        // resolve it in the current scope to its nominal `__@u<id>` atom.
        return c.computedSymKey(tok, flags, c.cur_scope);
    }
    if (flags & ast.Flags.computed != 0) {
        if (ast.wellKnownSymbolKey(c.tokenText(tok))) |k| return c.atom(k);
    }
    return c.memberAtom(tok);
}

/// Synthetic member atom for a value whose type is a `unique symbol`, so a
/// computed key `{ [k]: … }` and an element access `o[k]` agree on the
/// property name. `__@` cannot begin a real identifier, so it never
/// collides with an ordinary member (mirrors `wellKnownSymbolKey`).
pub fn uniqueSymAtom(c: *Checker, t: TypeId) Error!?Atom {
    const r = try c.ts.regular(t);
    if (c.ts.kind(r) != .unique_symbol) return null;
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "__@u{d}", .{c.ts.uniqueSymId(r)}) catch unreachable;
    return try c.internText(s); // stack buffer: copy, don't store as a cache key
}

/// Prefix of a computed-key placeholder atom (see `computedSymPlaceholder`).
pub const computed_sym_prefix = "__@k$";

/// The member name a computed key `[expr]` denotes when `expr`'s type is a
/// LITERAL — tsc's late-bound name rule (`isLateBindableName`: a computed
/// name is bindable when its type is a string literal, a numeric literal,
/// or a unique symbol). A string enum member counts: `[E.A]` with
/// `A = "a"` declares the property `"a"`, and `keyof` over such a map is
/// the union of the VALUES, not of anything derived from how the keys were
/// spelled.
///
/// Sibling of `uniqueSymAtom`, which covers the third case. Without this
/// one, every `{ [E.A]: T }` map kept the syntactic placeholder as its
/// member name, so `m.a` was TS2339, `keyof M` printed the placeholders
/// back at the user, and no `E`-typed key was assignable to it.
pub fn literalKeyAtom(c: *Checker, ty: TypeId) Error!?Atom {
    const r = try c.ts.regular(ty);
    switch (c.ts.kind(r)) {
        .string_literal => return c.ts.literalAtom(r),
        .number_literal, .number_literal_fresh => {
            var buf: [32]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            print_zig.printNumber(&w, c.ts.numberValue(r)) catch return null;
            // Stack buffer: `internText` copies. `atom` would keep the
            // transient slice as an `atom_cache` key and dangle.
            return try c.internText(w.buffered());
        },
        // An enum MEMBER stands for its own constant value; a whole enum
        // type (or a computed member with no constant) does not.
        .enum_type => {
            if (!c.ts.isEnumMember(r)) return null;
            const v = (try c.enumMemberValue(c.ts.enumSymbol(r), c.ts.enumMemberAtom(r))) orelse return null;
            if (v == r) return null; // no self-recursion on an opaque member
            return c.literalKeyAtom(v);
        },
        else => return null,
    }
}

/// The nominal member atom a computed-key expression of type `ty` denotes:
/// the `__@u<id>` of a `unique symbol`, else the literal name it spells
/// out. Null when `ty` is neither, and the caller falls back to the
/// syntactic placeholder.
fn computedKeyAtomOfType(c: *Checker, ty: TypeId) Error!?Atom {
    if (try c.uniqueSymAtom(ty)) |a| return a;
    return c.literalKeyAtom(ty);
}

/// Placeholder member atom for a computed const-`unique symbol` key, keyed
/// by the identifier text (matches the binder's `computedSymPlaceholder`).
/// Used as a lenient fallback when the key identifier can't be resolved to
/// a `unique symbol` (e.g. a plain `symbol`, or an unresolved import): the
/// member still exists and is keyed by name, degrading nominal identity to
/// same-name matching rather than emitting a spurious error.
pub fn computedSymPlaceholder(c: *Checker, name: []const u8) Error!Atom {
    const s = try std.fmt.allocPrint(c.scratch(), "{s}{s}", .{ computed_sym_prefix, name });
    return c.internText(s); // scratch slice: copy, don't store as a cache key
}

/// Resolve a computed-key identifier `name` (a `[k]` key) in `scope` to the
/// member atom it denotes: the nominal `__@u<id>` of a const `unique
/// symbol`, or the literal name a string/number-literal constant spells out
/// (`computedKeyAtomOfType`). Returns null when it is neither — the caller
/// then falls back to the name placeholder. Resolution goes through the value
/// space and `typeOfSymbol`, so an imported key resolves to the *declaring*
/// site's nominal id, giving cross-file key identity for free.
fn constSymbolKeyAtom(c: *Checker, name: []const u8, scope: ScopeId) Error!?Atom {
    const ty = (try constSymbolKeyType(c, name, scope)) orelse return null;
    return computedKeyAtomOfType(c, ty);
}

/// The TYPE a computed-key identifier denotes — the resolution half of
/// `constSymbolKeyAtom`, split out because the key's type is also its
/// tsc `nameType` (see `memberNameType`): `[E.A]` is keyed by the atom
/// `"AV1"` but NAMED by the enum-member literal `E.A`, and `keyof` has to
/// report the latter.
fn constSymbolKeyType(c: *Checker, name: []const u8, scope: ScopeId) Error!?TypeId {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        // Qualified `[a.b]` key: resolve `a` in the value space, then find
        // the member *symbol* `b` directly on it (class statics, namespace
        // exports). Symbol-level lookup goes through `typeOfSymbol`'s
        // per-member guard, so a self-referential key (`[C.k]` inside `C`
        // itself, node's `[EventEmitter.captureRejectionSymbol]`) resolves
        // nominally without re-entering the class-static materialization.
        // `name` may live in scratch (see `computedSymKey`): intern the
        // pieces via `internText` — `atom` would store the transient
        // slice as an `atom_cache` key and dangle after a scratch reset.
        const obj = switch (c.resolveSpace(try c.internText(name[0..dot]), scope, true)) {
            .sym => |s| s,
            else => return null,
        };
        const member = try c.internText(name[dot + 1 ..]);
        if (qualifiedKeyMemberSym(c, obj, member)) |msym| {
            return try c.typeOfSymbol(msym);
        }
        // Fallback for a base that is not itself a class/namespace (an
        // import binding, or a var whose *type* carries the member —
        // rxjs's `[Symbol.observable]` on `var Symbol: SymbolConstructor`):
        // materialize the base's type. Depth-bounded: an alias cycle
        // re-resolving the same key degrades to the placeholder.
        if (c.computed_key_depth >= 4) return null;
        c.computed_key_depth += 1;
        defer c.computed_key_depth -= 1;
        const p = (try c.propOfType(try c.typeOfSymbol(obj), member)) orelse return null;
        return p.ty;
    }
    const a = try c.atom(name);
    const sym = switch (c.resolveSpace(a, scope, true)) {
        .sym => |s| s,
        // A TYPE-ONLY import of a const (`import { type ID as K }`, then
        // `{ [K]?: boolean }`) has no VALUE meaning, so the value-space
        // lookup misses it and the key degraded to the name placeholder —
        // which is a plain string atom, so `keyof` reported
        // `"__@k$…"` where tsc reports the enum-member literal.
        // tsc's `isLateBindableName` resolves the entity name through the
        // alias and reads the target's literal type regardless of the
        // type-only modifier. Restricted to an IMPORT BINDING so a real
        // type name in key position still falls back to the placeholder.
        else => blk: {
            const t = switch (c.resolveSpace(a, scope, false)) {
                .sym => |s| s,
                else => return null,
            };
            if (!c.symFlags(t).import_binding) return null;
            break :blk t;
        },
    };
    return try c.typeOfSymbol(sym);
}

/// tsc's `symbol.links.nameType` for a member whose DECLARATION name is
/// not the plain string literal of the atom it is keyed by — tsc's
/// `getLiteralTypeFromPropertyName`, which types the name node itself
/// rather than the escaped name. Two cases:
///
///   * a computed ENUM-MEMBER key (`{ [E.A]: T }`). A member table keys by
///     atom, and an enum member's atom is its VALUE (`"AV1"`), so `keyof`
///     read back a plain string-literal union and lost the enum's identity
///     — `T extends keyof M` then did not satisfy `T extends E`.
///   * a NUMERIC name (`{ 200: T }`, `{ [200]: T }`, `[k]` with
///     `const k = 200`). tsc checks the numeric literal, so the key type
///     is the NUMBER literal `200`; a QUOTED `{ "200": T }` names the
///     string `"200"` and is unaffected (verified against tsc: the two
///     spell different key sets and neither is assignable to the other).
///     Without it octokit's `SuccessStatuses & keyof Responses` — numeric
///     status codes on both sides — intersected to `never` and every
///     `Endpoints[…]["response"]` read came out `unknown`.
///
/// Returns `no_type` for every other key, which is every key that names
/// itself: an ordinary identifier or string key. A `unique symbol` key is
/// already nominal through its `__@u<id>` atom.
pub fn memberNameType(c: *Checker, tok: TokenIndex, flags: u32) Error!TypeId {
    if (flags & ast.Flags.computed_sym == 0) {
        // A plain (`200:`) or computed (`[200]:`) numeric name. Both key
        // the table by the digits `memberAtom` interns, so the numeric
        // literal is only the right name type when those digits ARE the
        // number's canonical rendering: `{ 0x10: T }` / `{ 1e3: T }` are
        // keyed `"0x10"` / `"1e3"` here where tsc keys them `"16"` /
        // `"1000"`, and naming them `16` / `1000` would leave the key type
        // and the member name disagreeing — a key `keyof` reports that no
        // indexed access can read. Those stay as they were (see the
        // `memberAtom` normalization gap).
        if (c.tree.tokens.tag(tok) != .numeric_literal) return types.no_type;
        return numericNameType(c, c.numberTokenValue(tok), c.tokenText(tok));
    }
    const name = if (flags & ast.Flags.computed_sym_qual != 0)
        try std.fmt.allocPrint(c.scratch(), "{s}.{s}", .{ c.tokenText(tok - 2), c.tokenText(tok) })
    else
        c.tokenText(tok);
    const ty = (try constSymbolKeyType(c, name, c.cur_scope)) orelse return types.no_type;
    const r = try c.ts.regular(ty);
    switch (c.ts.kind(r)) {
        // `[k]` with `const k = 200`: `literalKeyAtom` keys the member by
        // the canonical rendering already, so the numeric literal always
        // agrees with the atom. `ts.regular` only sheds an OBJECT's
        // freshness, so a fresh literal needs `regularLiteral`.
        .number_literal, .number_literal_fresh => return c.ts.regularLiteral(r),
        .enum_type => if (c.ts.isEnumMember(r)) return r,
        else => {},
    }
    return types.no_type;
}

/// The NUMBER literal type a numeric member name denotes, or `no_type`
/// when `text` is not that number's canonical rendering — the atom the
/// member is keyed by. See `memberNameType`.
fn numericNameType(c: *Checker, value: f64, text: []const u8) Error!TypeId {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    print_zig.printNumber(&w, value) catch return types.no_type;
    if (!std.mem.eql(u8, w.buffered(), text)) return types.no_type;
    return c.ts.makeNumberLiteral(value, false);
}

/// Member symbol `name` of `obj` for qualified computed-key resolution:
/// a class's static (own class, or the class constituent of a merge), or
/// a namespace export. Null when `obj` is neither, or the member is
/// absent — the caller then falls back to type materialization.
fn qualifiedKeyMemberSym(c: *Checker, obj: SymbolId, name: Atom) ?SymbolId {
    if (c.prog.isMergedId(obj)) {
        const m = c.prog.mergedSym(obj);
        for (m.parts) |p| {
            if (c.symFlags(p).class) {
                if (classStaticMemberSym(c, p, name)) |s| return s;
            }
        }
        if (m.flags.namespace_decl) return c.namespaceMemberSym(obj, name);
        return null;
    }
    const f = c.symFlags(obj);
    if (f.class) {
        if (classStaticMemberSym(c, obj, name)) |s| return s;
    }
    if (f.namespace_decl) return c.namespaceMemberSym(obj, name);
    return null;
}

/// Static member `name` of class `cls` as a global symbol id, or null.
fn classStaticMemberSym(c: *Checker, cls: SymbolId, name: Atom) ?SymbolId {
    const cb = c.symBind(cls);
    const ss = cb.staticsScopeOf(c.localOf(cls)) orelse return null;
    const local = cb.lookupInScope(ss, name) orelse return null;
    return c.toGlobalIn(c.symFile(cls), local);
}

/// Final member atom for a computed const-symbol key token, resolved in
/// `scope`: the nominal `__@u<id>` when the key denotes a `unique symbol`,
/// else the name placeholder. For a qualified `[a.b]` key the object
/// identifier sits two tokens before the member identifier (see parser).
pub fn computedSymKey(c: *Checker, tok: TokenIndex, flags: u32, scope: ScopeId) Error!Atom {
    const name = if (flags & ast.Flags.computed_sym_qual != 0)
        try std.fmt.allocPrint(c.scratch(), "{s}.{s}", .{ c.tokenText(tok - 2), c.tokenText(tok) })
    else
        c.tokenText(tok);
    if (try constSymbolKeyAtom(c, name, scope)) |k| return k;
    return c.computedSymPlaceholder(name);
}

/// Rekey a bound member atom (from the binder's member index) to its
/// nominal `__@u<id>` when it is a computed-key placeholder; otherwise
/// return it unchanged. `scope` must reach the key identifier's binding.
pub fn nominalizeComputedKey(c: *Checker, name: Atom, scope: ScopeId) Error!Atom {
    const text = c.atomText(name);
    if (!std.mem.startsWith(u8, text, computed_sym_prefix)) return name;
    const ident = text[computed_sym_prefix.len..];
    if (try constSymbolKeyAtom(c, ident, scope)) |k| return k;
    return name;
}

/// The key expression's TYPE behind a computed-key PLACEHOLDER atom, or null
/// when `name` is not a placeholder (an ordinary member, or a key already
/// nominalized to `__@u<id>` / a literal name) or when the key identifier
/// resolves to nothing at all.
///
/// A placeholder is precisely the member tsc's `isLateBindableName` refuses:
/// the key resolved, but to something that is not a string literal, a numeric
/// literal or a `unique symbol`. Those members declare no property — they
/// contribute an INDEX SIGNATURE instead (tsc's `getIndexInfosOfIndexSymbol`),
/// and `computed_key.splitDynamicMembers` needs the key type to say which
/// domain. Split out here because the resolution it reuses
/// (`constSymbolKeyType`) is this file's, and it deliberately answers WITHOUT
/// re-entering the expression walk — a class member's key is resolved while
/// the class's own table is materializing.
pub fn placeholderKeyType(c: *Checker, name: Atom, scope: ScopeId) Error!?TypeId {
    const text = c.atomText(name);
    if (!std.mem.startsWith(u8, text, computed_sym_prefix)) return null;
    return constSymbolKeyType(c, text[computed_sym_prefix.len..], scope);
}

/// Is `name` a computed-key placeholder atom at all? The cheap half of
/// `placeholderKeyType`, for a pre-scan that wants to skip the resolution.
pub fn isComputedPlaceholder(c: *Checker, name: Atom) bool {
    return std.mem.startsWith(u8, c.atomText(name), computed_sym_prefix);
}

/// If `node` is syntactically `Symbol.<wellKnownName>` (e.g.
/// `Symbol.iterator`), returns the synthetic member key `__@<name>` used by
/// the declaration side (`ast.wellKnownSymbolKey`). Matches the identifier
/// text `Symbol` like the binder/parser do — a purely syntactic recognizer,
/// independent of whether the real lib types `Symbol.iterator` as a
/// `unique symbol`.
pub fn wellKnownKeyOfExpr(c: *const Checker, node: Node) ?[]const u8 {
    if (node == null_node or c.nodeTag(node) != .member_expr) return null;
    const md = c.tree.nodeData(node);
    if (c.nodeTag(md.lhs) != .identifier) return null;
    if (!std.mem.eql(u8, c.tokenText(c.tree.nodeMainToken(md.lhs)), "Symbol")) return null;
    return ast.wellKnownSymbolKey(c.tokenText(md.rhs));
}

pub fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
        if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
        return text[1..];
    }
    if (text.len >= 1 and (text[0] == '"' or text[0] == '\'')) return text[1..];
    return text;
}
