//! Module resolution, module graph, and cross-file symbol linking (M5).
//!
//! Design decisions (M5):
//!
//! - **Resolution is bundler-style** (matches `tsc --moduleResolution
//!   bundler` for the subset):
//!   - Relative specifiers resolve against the importing file's directory.
//!     Extension order: exact `.ts`/`.d.ts` kept as written; `./x.js`
//!     rewrites to `./x.ts` then `./x.d.ts` (TS output-path style); bare
//!     `./x` tries `x.ts`, `x.d.ts`, `x/index.ts`, `x/index.d.ts`.
//!   - Bare specifiers walk up from the importing file looking in
//!     `node_modules/<pkg>/`: the `package.json` `"types"`/`"typings"`
//!     field, else `index.d.ts` (then `index.ts`). Scoped packages
//!     (`@scope/pkg`) and plain subpaths (`pkg/sub` with the relative
//!     candidate order) are supported. **No `"exports"` map support**
//!     (documented cut); `package.json` is scanned with a minimal string
//!     scanner (no escape sequences — fine for the fixture/corpus subset).
//! - **Nonexistent module → TS2307** at the module-specifier string of the
//!   import/export statement (one per statement).
//! - **Linking is serial and pure**: after all files are bound (parallel
//!   phases), `link` builds per-file sealed tables:
//!   - a flattened **export table** (name → final `Target`), with
//!     re-export chains (`export { x } from`, `export *`,
//!     `export * as ns`) followed to their defining symbol, cycle-safe
//!     (a re-export cycle contributes nothing / reports the miss);
//!     `export *` does not re-export `default`; on duplicate star names
//!     the first (statement order) wins — tsc excludes ambiguous star
//!     exports instead (documented deviation).
//!   - an **import table** (local import-binding symbol → final `Target`),
//!     import-of-re-export chains followed the same way. A missing named
//!     export is TS2305; a missing default is TS2613 (when a same-named
//!     named export exists) or TS1192.
//! - Checkers treat the sealed tables as read-only: no locks anywhere on
//!   the check path (the immutability boundary).
//! - Out of subset (documented): `export =` / `import x = require(...)`
//!   (parser flags them unsupported), ambient `declare module "..."`
//!   blocks, CommonJS interop semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const binder = @import("binder.zig");
const intern = @import("intern.zig");
const source = @import("source.zig");

const Ast = ast.Ast;
const Bind = binder.Bind;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Span = source.Span;

pub const Error = error{OutOfMemory};

pub const FileId = u32;
pub const no_file: FileId = std.math.maxInt(FileId);

/// Synthetic path of the injected ES-core lib (M10). It has no on-disk
/// location; the loaders special-case this exact path and use `lib_source`.
/// The leading NUL keeps it from colliding with any real filesystem path.
pub const lib_path = "\x00lib/lib.esnext.d.ts";
/// The embedded lib text (see `src/lib/lib.esnext.d.ts`, M18.2 — the real
/// TypeScript 5.5.4 ES-core..esnext surface, DOM excluded, plus a minimal
/// `console` shim). Bound once per run; its top-level declarations become the
/// program's global symbols. Its own diagnostics are suppressed (like tsc's
/// default lib) — see the print loop in main.zig.
pub const lib_source = @embedFile("lib/lib.esnext.d.ts");

/// The final resolution of an imported/exported name.
pub const Target = struct {
    pub const Kind = enum(u8) {
        /// Unresolved (missing module / missing export / out of subset).
        /// The binding types as `any`; the diagnostic was already issued.
        any,
        /// A declaration symbol: `payload` is a local SymbolId in `file`.
        binding,
        /// The module namespace object of `file` (`import * as ns` /
        /// `export * as ns`).
        namespace,
        /// An anonymous `export default <expr>`: `payload` is the
        /// `export_default` node in `file`.
        default_expr,
        /// The namespace object of an ambient module (`import * as ns from
        /// "fs"`, M11c): `payload` indexes `Program.ambient_exports`.
        ambient_ns,
    };
    kind: Kind = .any,
    file: FileId = 0,
    payload: u32 = 0,
    /// The chain passed through `export type` / `import type` somewhere:
    /// value use of the binding is an error (TS1362-adjacent).
    type_only: bool = false,
};

/// A link-phase diagnostic (2307/2305/2613/1192/2304), file-local span.
pub const LinkDiag = struct {
    code: u16,
    span: Span,
    msg: []const u8,
};

/// Module-specifier atom → resolved FileId (or `no_file`), sorted by atom.
pub const SpecMap = struct {
    atoms: []const Atom = &.{},
    files: []const FileId = &.{},

    pub fn get(m: *const SpecMap, atom: Atom) ?FileId {
        var lo: usize = 0;
        var hi: usize = m.atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (m.atoms[mid] == atom) {
                const f = m.files[mid];
                return if (f == no_file) null else f;
            }
            if (m.atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// One program file: sealed parse/bind outputs plus its specifier map.
pub const ProgFile = struct {
    path: []const u8,
    src: []const u8,
    tree: *const Ast,
    bind: *const Bind,
    specs: SpecMap = .{},
};

/// Sealed link tables for one file (read-only during check).
pub const FileLinks = struct {
    /// Local import-binding SymbolIds, sorted, with their targets.
    import_locals: []const u32 = &.{},
    import_targets: []const Target = &.{},
    /// Flattened export table sorted by exported-name atom.
    export_atoms: []const Atom = &.{},
    export_targets: []const Target = &.{},
    diags: []const LinkDiag = &.{},

    pub fn importTarget(l: *const FileLinks, local: u32) ?Target {
        var lo: usize = 0;
        var hi: usize = l.import_locals.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (l.import_locals[mid] == local) return l.import_targets[mid];
            if (l.import_locals[mid] < local) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn exportTarget(l: *const FileLinks, atom: Atom) ?Target {
        var lo: usize = 0;
        var hi: usize = l.export_atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (l.export_atoms[mid] == atom) return l.export_targets[mid];
            if (l.export_atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Exact bytes of the sealed link tables.
    pub fn bytes(l: *const FileLinks) usize {
        return l.import_locals.len * (@sizeOf(u32) + @sizeOf(Target)) +
            l.export_atoms.len * (@sizeOf(Atom) + @sizeOf(Target)) +
            l.diags.len * @sizeOf(LinkDiag);
    }
};

/// A cross-file merged global symbol (M11a). When 2+ files contribute the
/// same global name, the linker allocates one of these; its program id is
/// `totalSymbols() + index` (the merged range). `flags` is the OR of the
/// constituents' flags; `parts` are the constituent GLOBAL SymbolIds (real
/// ids `< totalSymbols()`) in FileId order. Checkers materialize the type by
/// folding each constituent's declarations across files (the type-level twin
/// of within-file merging). Merge remains a symbol-table operation — no types
/// are compared here (M11 invariant: merge symbols, never types).
pub const MergedSym = struct {
    name: Atom,
    flags: binder.SymbolFlags,
    parts: []const u32,
    /// Merged member index for namespace-bearing merges (M11b): member name
    /// atom → global sym (itself possibly a merged-range id, so a nested
    /// interface/namespace reopened across files resolves recursively).
    /// Sorted by atom; empty for non-namespace merges (interfaces materialize
    /// to object types, so their members need no symbol-level index).
    members: Globals = .{},
};

/// An ambient module's sealed export table (M11c), for `import * as ns`
/// namespace objects. Entries are (export-name atom → Target), atom-sorted.
pub const AmbientExport = struct {
    atoms: []const Atom = &.{},
    targets: []const Target = &.{},
};

/// Global (lib) name table: the top-level declarations of the injected
/// lib file, keyed by name atom, holding GLOBAL SymbolIds. Sorted by atom
/// for binary-search fallback in name resolution (checker `resolveSpace`).
/// Empty when `--noLib` / no lib is injected. A name with a single
/// contributor maps to that contributor's `(file, sym)` global id; a name
/// with 2+ contributors maps to a merged-range id (`≥ totalSymbols()`)
/// indexing `Program.merged` (M11a).
pub const Globals = struct {
    atoms: []const Atom = &.{},
    syms: []const u32 = &.{},

    pub fn lookup(g: *const Globals, atom: Atom) ?u32 {
        var lo: usize = 0;
        var hi: usize = g.atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (g.atoms[mid] == atom) return g.syms[mid];
            if (g.atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// The sealed multi-file program handed to the checkers. Everything is
/// immutable after `link`; N checkers read it concurrently without locks.
pub const Program = struct {
    files: []const ProgFile,
    /// files.len+1 prefix sums of per-file symbol counts: global symbol id
    /// = sym_base[file] + local id. Global 0 stays the "no symbol" sentinel.
    sym_base: []const u32,
    /// Per-file link tables; empty slice = unlinked single-file mode
    /// (imports silently type as `any` — used by legacy unit-test paths).
    links: []const FileLinks = &.{},
    /// Lib global symbols (empty when no lib is injected).
    globals: Globals = .{},
    /// Cross-file merged global symbols (M11a). Program id of entry `k` is
    /// `totalSymbols() + k`. Empty in the common case (no name has 2+
    /// contributors).
    merged: []const MergedSym = &.{},
    /// Ambient module export tables (M11c), indexed by `Target.ambient_ns`
    /// payloads; for `import * as ns from "<ambient>"` namespace objects.
    ambient_exports: []const AmbientExport = &.{},
    /// Specifier atom of each `ambient_exports[i]` (the `declare module`
    /// name/pattern, in registry order). Lets a type-position `import("m")`
    /// (M14) resolve against an ambient module by exact or wildcard match.
    ambient_specs: []const Atom = &.{},
    /// Reverse merge index (M11a): merge-constituent real id → merged id,
    /// parallel arrays sorted by key. See `mergedOf`.
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},

    /// Count of real per-file symbols (merged ids start here).
    pub fn totalSymbols(p: *const Program) u32 {
        return p.sym_base[p.files.len];
    }

    /// If real global id `sym` is a constituent of a cross-file merge, the
    /// merged-range id it folds into; else null. Used so a merged name
    /// referenced from *within* a contributing file (bound to the file-local
    /// declaration, which never reaches the global fallback) still resolves to
    /// the merged view.
    pub fn mergedOf(p: *const Program, sym: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = p.constit_keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.constit_keys[mid] == sym) return p.constit_vals[mid];
            if (p.constit_keys[mid] < sym) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// True for a merged-range symbol id (indexes `merged`, not a file).
    pub fn isMergedId(p: *const Program, sym: u32) bool {
        return sym >= p.totalSymbols();
    }

    /// The merged symbol for a merged-range id.
    pub fn mergedSym(p: *const Program, sym: u32) *const MergedSym {
        return &p.merged[sym - p.totalSymbols()];
    }

    /// Total symbol-id space including the merged range (checker array sizing).
    pub fn symbolSpace(p: *const Program) u32 {
        return p.totalSymbols() + @as(u32, @intCast(p.merged.len));
    }

    /// Bytes of the module graph (spec maps + link tables + sym_base).
    pub fn graphBytes(p: *const Program) usize {
        var n: usize = p.sym_base.len * @sizeOf(u32);
        for (p.files) |*f| {
            n += f.specs.atoms.len * (@sizeOf(Atom) + @sizeOf(FileId));
        }
        for (p.links) |*l| n += l.bytes();
        return n;
    }
};

/// Prefix sums of per-file symbol-array lengths (incl. the per-file dummy).
pub fn computeSymBase(alloc: Allocator, files: []const ProgFile) Error![]u32 {
    const base = try alloc.alloc(u32, files.len + 1);
    base[0] = 0;
    for (files, 0..) |*f, i| {
        base[i + 1] = base[i] + @as(u32, @intCast(f.bind.symbol_names.len));
    }
    return base;
}

/// M12.1 — deterministic lib atoms. Intern every string the lib front end
/// produces, single-threaded, *before* the worker pool starts. An `Atom`
/// encodes shard-local insertion order (intern.zig), so run-to-run stability
/// requires the lib's strings to be interned in a fixed order ahead of the
/// concurrent user-file work; the worker that later binds the lib re-interns
/// the same text and receives these stable atoms. This is the seeded-interner
/// approach (M12.1 option a): it pins the lib's atoms (the ones a serialized
/// lib blob would reference) without touching user-file atoms.
///
/// Seeding runs the real binder — not a token scan — so it interns exactly
/// what binding interns, including the text transforms binding applies
/// (`stripQuotes`, well-known-symbol keys, the "default"/"*" constants).
/// The parse/bind products are thrown away; only their interner side effects
/// (which are idempotent) survive. Cheap: the lib is ~9 KB.
pub fn seedLibAtoms(io: Io, gpa: Allocator, interner: *Interner) !void {
    var seed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer seed_arena.deinit();
    const sa = seed_arena.allocator();
    const lib_tree = try parser.parse(sa, lib_source);
    _ = try binder.bind(sa, io, gpa, interner, &lib_tree, lib_source);
    // The lib file's own path atom is interned by the worker front end too.
    _ = try interner.intern(io, gpa, lib_path);
}

/// FileId of the injected lib file (matched by its synthetic path), or
/// `no_file` when no lib was injected.
pub fn libFileId(files: []const ProgFile) FileId {
    for (files, 0..) |*f, i| {
        if (std.mem.eql(u8, f.path, lib_path)) return @intCast(i);
    }
    return no_file;
}

/// Result of folding every file's global contributions (M11a).
pub const GlobalMerge = struct {
    globals: Globals = .{},
    merged: []const MergedSym = &.{},
    /// Reverse index (M11a): each merge constituent's real global id → the
    /// merged-range id it folds into. Parallel arrays sorted by key. Lets a
    /// reference to a merged name from *inside* a contributing file (which
    /// binds to the file-local constituent, not the global fallback) route to
    /// the merged view. Empty in the common case (no cross-file merges).
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
};

/// A (constituent real id → merged id) pair for the reverse index.
const ConstitPair = struct { key: u32, val: u32 };

/// FileId owning global symbol `sym` (binary search over sym_base prefix sums).
fn fileOfGlobal(sym_base: []const u32, n_files: usize, sym: u32) FileId {
    var lo: usize = 0;
    var hi: usize = n_files;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (sym_base[mid] <= sym) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

fn globalSymFlags(files: []const ProgFile, sym_base: []const u32, sym: u32) binder.SymbolFlags {
    const f = fileOfGlobal(sym_base, files.len, sym);
    return files[f].bind.symbol_flags[sym - sym_base[f]];
}

/// Fold every file's global-contribution slice (the binder harvest) into the
/// program global table, in FileId order (deterministic by construction —
/// the M11 merge is a pure function of file order). The lib and script files
/// offer their whole top level;
/// modules offer their `declare global` block members; the typical app module
/// offers nothing and is skipped (invariant 3, pay-per-use).
///
/// A name with a single contributor maps directly to that contributor's
/// `(file, sym)` global id — today's lib representation, the overwhelmingly
/// common case. A name with 2+ contributors allocates a merged symbol (id in
/// the merged range) carrying the OR of the constituents' flags and the
/// constituent list; the checker materializes its type by folding each
/// constituent's declarations across files. Merge is a pure symbol-table
/// operation — no types are compared here (invariant 1).
pub fn mergeGlobals(
    arena: Allocator,
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
) Error!GlobalMerge {
    // Accumulate name -> constituent global ids, contributions in FileId order.
    var acc: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)) = .empty;
    var any = false;
    for (files, 0..) |*f, fi| {
        const b = f.bind;
        if (b.global_atoms.len == 0) continue;
        any = true;
        const base = sym_base[fi];
        for (b.global_atoms, b.global_syms) |atom, local| {
            const gop = try acc.getOrPut(scratch, atom);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(scratch, base + local);
        }
    }
    if (!any) return .{};

    const n = acc.count();
    const names = try scratch.alloc(Atom, n);
    @memcpy(names, acc.keys());
    std.mem.sort(Atom, names, {}, struct {
        fn lt(_: void, a: Atom, b: Atom) bool {
            return a < b;
        }
    }.lt);

    var m: Merger = .{ .arena = arena, .scratch = scratch, .files = files, .sym_base = sym_base };
    const g_atoms = try arena.alloc(Atom, n);
    const g_syms = try arena.alloc(u32, n);
    for (names, 0..) |atom, i| {
        g_atoms[i] = atom;
        g_syms[i] = try m.mergeSet(acc.get(atom).?.items);
    }
    std.mem.sort(ConstitPair, m.constit.items, {}, struct {
        fn lt(_: void, a: ConstitPair, b: ConstitPair) bool {
            return a.key < b.key;
        }
    }.lt);
    const ck = try arena.alloc(u32, m.constit.items.len);
    const cv = try arena.alloc(u32, m.constit.items.len);
    for (m.constit.items, 0..) |pr, i| {
        ck[i] = pr.key;
        cv[i] = pr.val;
    }
    return .{
        .globals = .{ .atoms = g_atoms, .syms = g_syms },
        .merged = try arena.dupe(MergedSym, m.merged.items),
        .constit_keys = ck,
        .constit_vals = cv,
    };
}

/// Recursive cross-file symbol merger (M11a/M11b). Assigns merged-range ids as
/// it goes; a namespace merge recurses into member scopes so a nested
/// interface/namespace reopened across files becomes a nested merged symbol.
const Merger = struct {
    arena: Allocator,
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    merged: std.ArrayListUnmanaged(MergedSym) = .empty,
    /// (constituent real id → merged id), accumulated in `scratch` as merges
    /// are formed (including nested namespace-member merges), sorted at the end.
    constit: std.ArrayListUnmanaged(ConstitPair) = .empty,

    fn totalSyms(m: *const Merger) u32 {
        return m.sym_base[m.files.len];
    }

    /// Merge a set of contributor global ids (real ids) for one name into a
    /// single program id: the id itself when there is one contributor, else a
    /// fresh merged-range id.
    fn mergeSet(m: *Merger, parts: []const u32) Error!u32 {
        if (parts.len == 1) return parts[0];
        var flags: binder.SymbolFlags = .{};
        for (parts) |p| flags = binder.SymbolFlags.merge(flags, globalSymFlags(m.files, m.sym_base, p));
        // Namespace-bearing merges need a member index so `N.member` resolves
        // across every contributor (recursively for nested merges). Build it
        // first so nested merged ids are allocated below this symbol's id.
        var members: Globals = .{};
        if (flags.namespace_decl) members = try m.buildNsMembers(parts);
        const id = m.totalSyms() + @as(u32, @intCast(m.merged.items.len));
        try m.merged.append(m.arena, .{
            .name = globalSymName(m.files, m.sym_base, parts[0]),
            .flags = flags,
            .parts = try m.arena.dupe(u32, parts),
            .members = members,
        });
        for (parts) |p| try m.constit.append(m.scratch, .{ .key = p, .val = id });
        return id;
    }

    /// Build the merged member index over the namespace body scopes of the
    /// namespace-bearing parts: member atom → merged program id.
    fn buildNsMembers(m: *Merger, parts: []const u32) Error!Globals {
        var acc: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)) = .empty;
        for (parts) |p| {
            const fid = fileOfGlobal(m.sym_base, m.files.len, p);
            const b = m.files[fid].bind;
            const base = m.sym_base[fid];
            const ns_scope = b.namespaceScopeOf(p - base) orelse continue;
            const lo = b.scope_members_start[ns_scope];
            const hi = b.scope_members_start[ns_scope + 1];
            for (lo..hi) |k| {
                const gop = try acc.getOrPut(m.scratch, b.member_atoms[k]);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(m.scratch, base + b.member_syms[k]);
            }
        }
        const cnt = acc.count();
        if (cnt == 0) return .{};
        const mnames = try m.scratch.alloc(Atom, cnt);
        @memcpy(mnames, acc.keys());
        std.mem.sort(Atom, mnames, {}, struct {
            fn lt(_: void, a: Atom, b: Atom) bool {
                return a < b;
            }
        }.lt);
        const atoms = try m.arena.alloc(Atom, cnt);
        const syms = try m.arena.alloc(u32, cnt);
        for (mnames, 0..) |atom, i| {
            atoms[i] = atom;
            syms[i] = try m.mergeSet(acc.get(atom).?.items);
        }
        return .{ .atoms = atoms, .syms = syms };
    }
};

fn globalSymName(files: []const ProgFile, sym_base: []const u32, sym: u32) Atom {
    const f = fileOfGlobal(sym_base, files.len, sym);
    return files[f].bind.symbol_names[sym - sym_base[f]];
}

/// Wrap one already-bound file as an unlinked Program (legacy M4 paths).
pub fn singleFileProgram(
    alloc: Allocator,
    path: []const u8,
    src: []const u8,
    tree: *const Ast,
    bind: *const Bind,
) Error!Program {
    const files = try alloc.alloc(ProgFile, 1);
    files[0] = .{ .path = path, .src = src, .tree = tree, .bind = bind };
    return .{ .files = files, .sym_base = try computeSymBase(alloc, files) };
}

/// Build a program of the injected lib (file 0) plus one already-bound
/// source file (file 1), with the lib's globals collected. Used by the
/// single-file test/conformance path so those cases see the same globals
/// and primitive/array methods the CLI provides. `no_lib` reproduces the
/// legacy lib-free single-file program.
pub fn singleWithLibProgram(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    path: []const u8,
    src: []const u8,
    tree: *const Ast,
    bind: *const Bind,
    no_lib: bool,
) !Program {
    if (no_lib) return singleFileProgram(arena, path, src, tree, bind);
    const lib_tree = try arena.create(Ast);
    lib_tree.* = try parser.parse(arena, lib_source);
    const lib_bind = try arena.create(Bind);
    lib_bind.* = try binder.bind(arena, io, gpa, interner, lib_tree, lib_source);
    const files = try arena.alloc(ProgFile, 2);
    files[0] = .{ .path = lib_path, .src = lib_source, .tree = lib_tree, .bind = lib_bind };
    files[1] = .{ .path = path, .src = src, .tree = tree, .bind = bind };
    const sym_base = try computeSymBase(arena, files);
    // Unlinked single-file path: a script user file may still augment lib
    // globals; merge diagnostics (none for the clean case) have no link table
    // to land in here and are dropped.
    const gm = try mergeGlobals(arena, arena, files, sym_base);
    return .{ .files = files, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals };
}

// ===========================================================================
// path utilities (lexical; no FS access)
// ===========================================================================

/// Directory part of a path ("" for none). Forward slashes only.
pub fn dirnamePart(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    if (i == 0) return "/";
    return path[0..i];
}

/// Lexically normalize `path`: collapse `.`, `..`, `//`. Keeps the path
/// relative if it was relative (leading `..` segments survive).
pub fn normalizePath(alloc: Allocator, path: []const u8) Error![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    const absolute = path.len > 0 and path[0] == '/';
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
                continue;
            }
            if (absolute) continue; // /.. = /
            try parts.append(alloc, seg);
            continue;
        }
        try parts.append(alloc, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (absolute) try out.append(alloc, '/');
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try out.append(alloc, '/');
        try out.appendSlice(alloc, seg);
    }
    if (out.items.len == 0) try out.append(alloc, '.');
    return out.toOwnedSlice(alloc);
}

fn joinNormalize(alloc: Allocator, dir: []const u8, rest: []const u8) Error![]u8 {
    if (dir.len == 0) return normalizePath(alloc, rest);
    const joined = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, rest });
    defer alloc.free(joined);
    return normalizePath(alloc, joined);
}

// ===========================================================================
// specifier resolution (FS-backed)
// ===========================================================================

/// Count of filesystem probes issued during module resolution — every
/// `statFile` and every `package.json` read. It is the resolution cache's
/// scoreboard (M13, "resolution syscall counts before/after"): with
/// the `(importer_dir, spec)` memo the same specifier imported from K files
/// walks `node_modules` once, not K times, so this collapses on inputs with
/// shared specifiers.
///
/// Resolution runs single-owner (the main thread in the parallel driver, the
/// sole thread in `buildProgram`), so the counter is never truly contended,
/// but it is atomic anyway — cheap insurance against a future parallel caller
/// and race-free under the test runner's threads.
var fs_probes: std.atomic.Value(u64) = .init(0);

pub fn fsProbeCount() u64 {
    return fs_probes.load(.monotonic);
}
pub fn resetFsProbeCount() void {
    fs_probes.store(0, .monotonic);
}
inline fn bumpProbe() void {
    _ = fs_probes.fetchAdd(1, .monotonic);
}

fn fileExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    bumpProbe();
    const st = dir.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Minimal `package.json` scan for `"types"` / `"typings"` (first match;
/// string escapes unsupported — documented cut).
fn packageTypesField(text: []const u8) ?[]const u8 {
    for ([_][]const u8{ "\"types\"", "\"typings\"" }) |key| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, key)) |at| {
            var i = at + key.len;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                text[i] == '\r' or text[i] == '\n')) i += 1;
            if (i >= text.len or text[i] != ':') {
                from = at + key.len;
                continue;
            }
            i += 1;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or
                text[i] == '\r' or text[i] == '\n')) i += 1;
            if (i >= text.len or text[i] != '"') return null;
            i += 1;
            const start = i;
            while (i < text.len and text[i] != '"') i += 1;
            if (i >= text.len) return null;
            return text[start..i];
        }
    }
    return null;
}

fn tryCandidates(io: Io, alloc: Allocator, dir: Io.Dir, cands: []const []const u8) Error!?[]u8 {
    for (cands) |cand| {
        if (fileExists(io, dir, cand)) return try alloc.dupe(u8, cand);
    }
    return null;
}

/// Resolve a relative-or-package file stem with the documented extension
/// order. `stem` is a normalized path relative to `dir`. Public because
/// tsconfig `paths` mapping (M6) feeds mapped candidates through it.
pub fn resolveStem(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8) Error!?[]u8 {
    var buf: [4][]const u8 = undefined;
    var n: usize = 0;
    // Candidate paths are built with `alloc` (a scratch arena, freed after
    // the file's specifiers resolve). A previous fixed 256-byte buffer
    // silently failed on deep node_modules/@types paths — a wrong "module
    // not found" — so there is no length cap here.
    if (std.mem.endsWith(u8, stem, ".d.ts") or std.mem.endsWith(u8, stem, ".ts")) {
        buf[0] = stem;
        n = 1;
        return tryCandidates(io, alloc, dir, buf[0..n]);
    }
    if (std.mem.endsWith(u8, stem, ".js")) {
        const base = stem[0 .. stem.len - 3];
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{base});
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 2;
        return tryCandidates(io, alloc, dir, buf[0..n]);
    }
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}/index.ts", .{stem});
    buf[3] = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{stem});
    n = 4;
    return tryCandidates(io, alloc, dir, buf[0..n]);
}

/// Resolve a bare (package) specifier by walking `node_modules` up from
/// the importer's directory.
fn resolvePackage(io: Io, alloc: Allocator, dir: Io.Dir, importer_dir: []const u8, spec: []const u8) Error!?[]u8 {
    // Split "pkg/sub" / "@scope/pkg/sub".
    var pkg_len: usize = spec.len;
    if (std.mem.indexOfScalar(u8, spec, '/')) |first| {
        if (spec[0] == '@') {
            if (std.mem.indexOfScalarPos(u8, spec, first + 1, '/')) |second| {
                pkg_len = second;
            }
        } else {
            pkg_len = first;
        }
    }
    const pkg = spec[0..pkg_len];
    const sub = if (pkg_len < spec.len) spec[pkg_len + 1 ..] else "";

    var d = importer_dir;
    while (true) {
        const nm = if (d.len == 0)
            try std.fmt.allocPrint(alloc, "node_modules/{s}", .{pkg})
        else
            try std.fmt.allocPrint(alloc, "{s}/node_modules/{s}", .{ d, pkg });
        defer alloc.free(nm);

        if (sub.len > 0) {
            const stem = try joinNormalize(alloc, nm, sub);
            defer alloc.free(stem);
            if (try resolveStem(io, alloc, dir, stem)) |p| return p;
        } else {
            // package.json "types"/"typings", else index.d.ts / index.ts.
            const pj = try std.fmt.allocPrint(alloc, "{s}/package.json", .{nm});
            defer alloc.free(pj);
            var resolved_types = false;
            bumpProbe();
            if (dir.readFileAlloc(io, pj, alloc, .limited(1 << 20))) |text| {
                defer alloc.free(text);
                if (packageTypesField(text)) |types_rel| {
                    resolved_types = true;
                    const stem = try joinNormalize(alloc, nm, types_rel);
                    defer alloc.free(stem);
                    if (try resolveStem(io, alloc, dir, stem)) |p| return p;
                }
            } else |_| {}
            if (!resolved_types) {
                const idx = try std.fmt.allocPrint(alloc, "{s}/index", .{nm});
                defer alloc.free(idx);
                if (try resolveStem(io, alloc, dir, idx)) |p| return p;
            }
        }

        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) return null;
        d = dirnamePart(d);
    }
}

/// Resolve module specifier `spec` from file `importer` (both relative to
/// `dir`). Returns the normalized path of the resolved file, or null.
pub fn resolveSpecifier(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    importer: []const u8,
    spec: []const u8,
) Error!?[]u8 {
    if (spec.len == 0) return null;
    const importer_dir = dirnamePart(importer);
    if (spec[0] == '.') {
        const stem = try joinNormalize(alloc, importer_dir, spec);
        defer alloc.free(stem);
        return resolveStem(io, alloc, dir, stem);
    }
    if (spec[0] == '/') {
        const stem = try normalizePath(alloc, spec);
        defer alloc.free(stem);
        return resolveStem(io, alloc, dir, stem);
    }
    return resolvePackage(io, alloc, dir, importer_dir, spec);
}

/// Memoizes `resolveSpecifier` over the discovery run (M13). A module
/// specifier resolves as a pure function of `(importer_dir, spec)` given a
/// fixed filesystem — both a bare `node_modules` walk and a relative
/// `joinNormalize` depend on nothing else — so that pair is an exact key. The
/// win: `@types/node` (or any shared package) imported from K files walks the
/// tree once instead of K times, and unresolvable specifiers are remembered
/// too (the negative cache), so a bad import from K files also probes once.
///
/// Keyed on the *directory* rather than the importer path so sibling files in
/// one directory share entries. Determinism is untouched: a cached path is
/// byte-identical to the live resolution it replaces.
///
/// Not thread-safe by design — resolution is single-owner (see `fs_probes`).
pub const ResolveCache = struct {
    /// Persistent storage for keys and cached paths — outlives the per-file
    /// scratch resets, so it must be the caller's discovery arena.
    arena: Allocator,
    /// `"<importer_dir>\x00<spec>"` → resolved path, or `null` (negative).
    map: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// When false, every call falls straight through to `resolveSpecifier`
    /// with no memo read or write — the "before" leg of the M13 benchmark
    /// (`--no-resolve-cache`), and a correctness oracle for the cache.
    enabled: bool = true,
    lookups: u64 = 0,
    hits: u64 = 0,

    pub fn init(arena: Allocator, enabled: bool) ResolveCache {
        return .{ .arena = arena, .enabled = enabled };
    }

    /// Cached `resolveSpecifier`. `scratch` holds the transient candidate
    /// paths / package.json bodies (reset per file by the caller); a resolved
    /// path is copied into `arena` so it survives that reset. The returned
    /// slice is `arena`-owned on a miss and on every hit.
    pub fn resolve(
        rc: *ResolveCache,
        io: Io,
        scratch: Allocator,
        dir: Io.Dir,
        importer: []const u8,
        spec: []const u8,
    ) Error!?[]const u8 {
        if (!rc.enabled) return resolveSpecifier(io, scratch, dir, importer, spec);
        rc.lookups += 1;
        const importer_dir = dirnamePart(importer);
        // Build the key in scratch; only copy it into `arena` on a miss.
        const key = try std.fmt.allocPrint(scratch, "{s}\x00{s}", .{ importer_dir, spec });
        if (rc.map.get(key)) |cached| {
            rc.hits += 1;
            return cached;
        }
        const resolved = try resolveSpecifier(io, scratch, dir, importer, spec);
        const owned: ?[]const u8 = if (resolved) |p| try rc.arena.dupe(u8, p) else null;
        try rc.map.put(rc.arena, try rc.arena.dupe(u8, key), owned);
        return owned;
    }
};

// ===========================================================================
// linking
// ===========================================================================

const Linker = struct {
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    files: []const ProgFile,

    atom_default: Atom,
    /// 0 = not built, 1 = building (cycle), 2 = done.
    state: []u8,
    tables: []std.AutoArrayHashMapUnmanaged(Atom, Target),
    diags: []std.ArrayList(LinkDiag),
    /// Ambient/augmentation module registry (M11c): specifier atom → export
    /// table (export-name atom → Target). Built from every file's
    /// `declare module "spec" { … }` blocks; imports of `"spec"` resolve
    /// against it (after the on-disk module, so it augments a real module).
    ambient: std.AutoArrayHashMapUnmanaged(Atom, std.AutoArrayHashMapUnmanaged(Atom, Target)) = .empty,

    const visit_limit = 256;

    fn atomText(l: *Linker, a: Atom) []const u8 {
        if (a == 0) return "";
        return l.interner.lookup(l.io, a);
    }

    fn diag(l: *Linker, file: FileId, code: u16, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(l.arena, fmt, args);
        try l.diags[file].append(l.arena, .{ .code = code, .span = span, .msg = msg });
    }

    fn nodeSpan(l: *Linker, file: FileId, node: ast.Node) Span {
        return l.files[file].tree.span(l.files[file].src, node);
    }

    fn tokSpan(l: *Linker, file: FileId, tok: ast.TokenIndex) Span {
        const tree = l.files[file].tree;
        const start = tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(l.files[file].src, tree.tokens.tag(tok), start) };
    }

    /// The flattened export table of `file` (built on demand, cycle-safe).
    fn table(l: *Linker, file: FileId) Error!*std.AutoArrayHashMapUnmanaged(Atom, Target) {
        if (l.state[file] == 2 or l.state[file] == 1) return &l.tables[file];
        l.state[file] = 1;
        const f = &l.files[file];
        const t = &l.tables[file];

        // Pass 1: own exports and single re-exports (statement order).
        for (f.bind.exports) |rec| {
            switch (rec.kind) {
                .named => {
                    if (rec.sym != binder.no_symbol) {
                        const tgt = try l.finalizeLocal(file, rec.sym, rec.local, rec.type_only, 0);
                        try l.put(t, rec.exported, tgt);
                    } else if (rec.local != 0) {
                        try l.diag(file, 2304, l.nodeSpan(file, rec.node), "Cannot find name '{s}'.", .{l.atomText(rec.local)});
                    }
                },
                .default => {
                    if (rec.sym != binder.no_symbol) {
                        try l.put(t, rec.exported, .{ .kind = .binding, .file = file, .payload = rec.sym });
                    } else {
                        try l.put(t, rec.exported, .{ .kind = .default_expr, .file = file, .payload = rec.node });
                    }
                },
                .reexport_named => {
                    const mfile = f.specs.get(rec.module) orelse {
                        try l.put(t, rec.exported, .{ .kind = .any });
                        continue; // 2307 reported statement-level
                    };
                    if (try l.lookupExport(mfile, rec.local, 0)) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or rec.type_only;
                        try l.put(t, rec.exported, final);
                    } else {
                        try l.diag(file, 2305, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no exported member '{s}'.", .{
                            l.atomText(rec.module), l.atomText(rec.local),
                        });
                        try l.put(t, rec.exported, .{ .kind = .any });
                    }
                },
                .reexport_ns => {
                    if (f.specs.get(rec.module)) |mfile| {
                        try l.put(t, rec.exported, .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only });
                    } else {
                        try l.put(t, rec.exported, .{ .kind = .any });
                    }
                },
                .reexport_all => {},
            }
        }

        // Pass 2: `export *` star merges (never `default`; first wins).
        for (f.bind.exports) |rec| {
            if (rec.kind != .reexport_all) continue;
            const mfile = f.specs.get(rec.module) orelse continue;
            if (mfile == file) continue;
            const mt = try l.table(mfile);
            for (mt.keys(), mt.values()) |name, tgt| {
                if (name == l.atom_default) continue;
                if (t.contains(name)) continue;
                var final = tgt;
                final.type_only = final.type_only or rec.type_only;
                try t.put(l.scratch, name, final);
            }
        }

        l.state[file] = 2;
        return t;
    }

    fn put(l: *Linker, t: *std.AutoArrayHashMapUnmanaged(Atom, Target), name: Atom, tgt: Target) Error!void {
        // Later explicit exports of the same name overwrite (duplicate
        // export names are a bind-phase diagnostic concern, not ours).
        try t.put(l.scratch, name, tgt);
    }

    /// Final target of export-table lookup `name` in `file`.
    fn lookupExport(l: *Linker, file: FileId, name: Atom, depth: u32) Error!?Target {
        if (depth > visit_limit) return null;
        const t = try l.table(file);
        return t.get(name);
    }

    /// Final target of a local symbol used as an export: follow import
    /// bindings to their defining module.
    fn finalizeLocal(l: *Linker, file: FileId, local_sym: u32, local_atom: Atom, type_only: bool, depth: u32) Error!Target {
        if (depth > visit_limit) return .{ .kind = .any };
        const f = &l.files[file];
        const flags = f.bind.symbol_flags[local_sym];
        if (!flags.import_binding) {
            return .{ .kind = .binding, .file = file, .payload = local_sym, .type_only = type_only };
        }
        // Find the import record that created this binding.
        for (f.bind.imports) |rec| {
            if (rec.local != local_atom) continue;
            const t_only = type_only or rec.type_only;
            const mfile = f.specs.get(rec.module) orelse return .{ .kind = .any };
            switch (rec.kind) {
                .namespace => return .{ .kind = .namespace, .file = mfile, .type_only = t_only },
                .named, .default => {
                    if (try l.lookupExport(mfile, rec.imported, depth + 1)) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or t_only;
                        return final;
                    }
                    return .{ .kind = .any };
                },
                .side_effect => break,
            }
        }
        return .{ .kind = .any };
    }

    /// Populate the ambient/augmentation registry from every file's
    /// `declare module "spec" { … }` blocks (M11c). Each block's `export`ed
    /// members become entries in `spec`'s export table; the first contributor
    /// of a name wins (deterministic FileId order). Must run after all export
    /// tables are built (member `finalizeLocal` may follow re-exports).
    fn buildAmbient(l: *Linker) Error!void {
        for (l.files, 0..) |*f, fi| {
            const fid: FileId = @intCast(fi);
            const b = f.bind;
            for (b.ambient_modules) |am| {
                const gop = try l.ambient.getOrPut(l.scratch, am.spec);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                const tbl = gop.value_ptr;

                // Declaration exports (`export function/const/interface/…`):
                // members with the `exported` flag. Default exports are handled
                // via the export records below, so skip them here.
                const lo = b.scope_members_start[am.scope];
                const hi = b.scope_members_start[am.scope + 1];
                for (lo..hi) |i| {
                    const local = b.member_syms[i];
                    const fl = b.symbol_flags[local];
                    if (!fl.exported or fl.export_default) continue;
                    const name = b.member_atoms[i];
                    if (tbl.contains(name)) continue;
                    try tbl.put(l.scratch, name, try l.finalizeLocal(fid, local, name, false, 0));
                }

                // `export default …` / `export { a, b }` forms (which carry no
                // `exported` flag): resolve each in the block scope.
                for (b.exports[am.export_start..am.export_end]) |rec| {
                    switch (rec.kind) {
                        .default => {
                            if (tbl.contains(l.atom_default)) continue;
                            var tgt: Target = .{ .kind = .default_expr, .file = fid, .payload = rec.node };
                            if (rec.sym != binder.no_symbol) {
                                tgt = try l.finalizeLocal(fid, rec.sym, rec.local, rec.type_only, 0);
                            } else if (rec.local != 0) {
                                if (b.lookupInScope(am.scope, rec.local)) |ls| {
                                    tgt = try l.finalizeLocal(fid, ls, rec.local, rec.type_only, 0);
                                }
                            }
                            try tbl.put(l.scratch, l.atom_default, tgt);
                        },
                        .named => {
                            if (tbl.contains(rec.exported)) continue;
                            const ls = b.lookupInScope(am.scope, rec.local) orelse continue;
                            try tbl.put(l.scratch, rec.exported, try l.finalizeLocal(fid, ls, rec.local, rec.type_only, 0));
                        },
                        else => {}, // re-exports from another module: unsupported
                    }
                }
            }
        }
    }

    fn lookupAmbient(l: *Linker, spec: Atom, name: Atom) ?Target {
        const key = l.ambientKey(spec) orelse return null;
        return l.ambient.getPtr(key).?.get(name);
    }

    fn hasAmbient(l: *Linker, spec: Atom) bool {
        return l.ambientKey(spec) != null;
    }

    /// An ambient module whose block yielded no ES-style named exports — it
    /// uses `export =` / `import = require` or the ambient auto-export rule
    /// (top-level `let`/`function` with no `export`), all out of subset. Real
    /// `@types/node`'s `path`/`timers`/`events`/`os`/… are all this shape.
    /// Named imports from such a module degrade to `any` (a clean deferral)
    /// rather than spuriously reporting TS2305 "has no exported member".
    fn ambientOpaque(l: *Linker, spec: Atom) bool {
        const key = l.ambientKey(spec) orelse return false;
        return l.ambient.getPtr(key).?.count() == 0;
    }

    /// The registry key matching specifier `spec`: an exact `declare module`
    /// name, else a wildcard pattern (`declare module "*.css"`, M11c). Returns
    /// null when no ambient module covers the specifier.
    fn ambientKey(l: *Linker, spec: Atom) ?Atom {
        if (l.ambient.contains(spec)) return spec;
        const text = l.atomText(spec);
        for (l.ambient.keys()) |pat_atom| {
            const pat = l.atomText(pat_atom);
            const star = std.mem.indexOfScalar(u8, pat, '*') orelse continue;
            const prefix = pat[0..star];
            const suffix = pat[star + 1 ..];
            if (text.len >= prefix.len + suffix.len and
                std.mem.startsWith(u8, text, prefix) and
                std.mem.endsWith(u8, text, suffix)) return pat_atom;
        }
        return null;
    }

    /// TS2307 for unresolved module specifiers, one per statement.
    /// Side-effect-only imports (`import "./x"`) are exempt — tsc does not
    /// report unresolved modules for them under bundler resolution.
    fn reportUnresolvedModules(l: *Linker, file: FileId) Error!void {
        const f = &l.files[file];
        const tree = f.tree;
        for (tree.nodeRange(0)) |stmt| {
            if (stmt == ast.null_node) continue;
            const tag = tree.nodeTag(stmt);
            if (tag != .import_decl and tag != .export_named and tag != .export_all) continue;
            if (tag == .import_decl) {
                const data = tree.extraData(ast.ImportData, tree.nodeData(stmt).lhs);
                if (data.default_name_token == 0 and data.ns_name_token == 0 and
                    data.spec_start == data.spec_end) continue;
            }
            const mod_tok = tree.nodeData(stmt).rhs;
            if (mod_tok == 0) continue;
            const text = tree.tokenSlice(f.src, mod_tok);
            const stripped = stripQuotes(text);
            if (stripped.len == 0) continue;
            const atom = l.interner.intern(l.io, l.gpa, stripped) catch return Error.OutOfMemory;
            if (f.specs.get(atom) != null) continue;
            if (l.hasAmbient(atom)) continue; // resolved by a `declare module`
            try l.diag(file, 2307, l.tokSpan(file, mod_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{stripped});
        }
    }

    /// Link one file's import bindings. A named/default import resolves first
    /// against the on-disk module (if the specifier resolved to a file), then
    /// against an ambient/augmentation module of the same specifier (M11c), so
    /// `declare module "spec"` supplies exports for an unresolved specifier and
    /// augments a resolved one. Diagnostics fire only when the module is known
    /// (a real file or an ambient declaration); a wholly unknown specifier is
    /// left to `reportUnresolvedModules` (TS2307).
    fn linkImports(l: *Linker, file: FileId, locals: *std.ArrayList(u32), targets: *std.ArrayList(Target)) Error!void {
        const f = &l.files[file];
        for (f.bind.imports) |rec| {
            if (rec.kind == .side_effect) continue;
            const local_sym = f.bind.lookupInScope(binder.file_scope, rec.local) orelse continue;
            var tgt: Target = .{ .kind = .any };
            const mfile_opt = f.specs.get(rec.module);
            const known = mfile_opt != null or l.hasAmbient(rec.module);
            if (known) {
                switch (rec.kind) {
                    .namespace => {
                        if (mfile_opt) |mfile| {
                            tgt = .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only };
                        } else if (l.ambientOpaque(rec.module)) {
                            // Opaque ambient module: `import * as p` is `any`,
                            // so member access doesn't spuriously TS2339.
                            tgt = .{ .kind = .any };
                        } else if (l.ambientKey(rec.module)) |key| {
                            tgt = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?), .type_only = rec.type_only };
                        }
                    },
                    .named => {
                        var found: ?Target = null;
                        if (mfile_opt) |mfile| found = try l.lookupExport(mfile, rec.imported, 0);
                        if (found == null) found = l.lookupAmbient(rec.module, rec.imported);
                        if (found) |ff| {
                            tgt = ff;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (mfile_opt == null and l.ambientOpaque(rec.module)) {
                            // Out-of-subset ambient module (export= / auto-export):
                            // degrade to `any`, no spurious TS2305.
                            tgt = .{ .kind = .any };
                        } else {
                            try l.diag(file, 2305, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no exported member '{s}'.", .{
                                l.atomText(rec.module), l.atomText(rec.imported),
                            });
                        }
                    },
                    .default => {
                        var found: ?Target = null;
                        if (mfile_opt) |mfile| found = try l.lookupExport(mfile, l.atom_default, 0);
                        if (found == null) found = l.lookupAmbient(rec.module, l.atom_default);
                        if (found) |ff| {
                            tgt = ff;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (mfile_opt == null and l.ambientOpaque(rec.module)) {
                            // `export =`-shaped ambient module: the CommonJS
                            // export-assignment *is* the default under interop.
                            tgt = .{ .kind = .any };
                        } else if ((mfile_opt != null and (try l.lookupExport(mfile_opt.?, rec.local, 0)) != null) or
                            l.lookupAmbient(rec.module, rec.local) != null)
                        {
                            try l.diag(file, 2613, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no default export. Did you mean to use 'import {{ {s} }} from \"{s}\"' instead?", .{
                                l.atomText(rec.module), l.atomText(rec.local), l.atomText(rec.module),
                            });
                        } else {
                            try l.diag(file, 1192, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no default export.", .{l.atomText(rec.module)});
                        }
                    },
                    .side_effect => unreachable,
                }
            }
            try locals.append(l.scratch, local_sym);
            try targets.append(l.scratch, tgt);
        }
    }
};

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
        if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
        return text[1..];
    }
    return text;
}

/// Everything the serial link phase produces for the sealed program.
pub const LinkResult = struct {
    links: []const FileLinks,
    sym_base: []const u32,
    globals: Globals = .{},
    merged: []const MergedSym = &.{},
    ambient_exports: []const AmbientExport = &.{},
    ambient_specs: []const Atom = &.{},
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
};

/// Build the sealed per-file link tables and the merged global table. Serial;
/// results live in `arena`.
pub fn link(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []const ProgFile,
) Error!LinkResult {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var l: Linker = .{
        .arena = arena,
        .scratch = scratch,
        .io = io,
        .gpa = gpa,
        .interner = interner,
        .files = files,
        .atom_default = interner.intern(io, gpa, "default") catch return Error.OutOfMemory,
        .state = try scratch.alloc(u8, files.len),
        .tables = try scratch.alloc(std.AutoArrayHashMapUnmanaged(Atom, Target), files.len),
        .diags = try scratch.alloc(std.ArrayList(LinkDiag), files.len),
    };
    @memset(l.state, 0);
    for (l.tables) |*t| t.* = .empty;
    for (l.diags) |*d| d.* = .empty;

    // Build every export table (deterministic file order).
    for (0..files.len) |i| _ = try l.table(@intCast(i));
    // Then the ambient/augmentation module registry (M11c), which import
    // resolution and TS2307 suppression consult below.
    try l.buildAmbient();

    const out = try arena.alloc(FileLinks, files.len);
    for (0..files.len) |i| {
        const fid: FileId = @intCast(i);
        try l.reportUnresolvedModules(fid);

        var locals: std.ArrayList(u32) = .empty;
        var targets: std.ArrayList(Target) = .empty;
        try l.linkImports(fid, &locals, &targets);
        try sortByKeyU32(scratch, locals.items, targets.items);

        // Seal the export table sorted by atom.
        const t = &l.tables[i];
        const n = t.count();
        const atoms = try arena.alloc(Atom, n);
        const etargets = try arena.alloc(Target, n);
        @memcpy(atoms, t.keys());
        @memcpy(etargets, t.values());
        try sortByKeyU32(scratch, atoms, etargets);

        out[i] = .{
            .import_locals = try arena.dupe(u32, locals.items),
            .import_targets = try arena.dupe(Target, targets.items),
            .export_atoms = atoms,
            .export_targets = etargets,
            .diags = try arena.dupe(LinkDiag, l.diags[i].items),
        };
    }

    // Cross-file global merge (M11a): fold every file's harvest slice.
    const sym_base = try computeSymBase(arena, files);
    const gm = try mergeGlobals(arena, scratch, files, sym_base);

    // Seal the ambient module export tables (M11c) in registry order, so
    // `Target.ambient_ns` payloads (assigned from `getIndex`) address them.
    const amb = try arena.alloc(AmbientExport, l.ambient.count());
    const amb_specs = try arena.alloc(Atom, l.ambient.count());
    @memcpy(amb_specs, l.ambient.keys());
    for (l.ambient.values(), 0..) |*tbl, i| {
        const n = tbl.count();
        const atoms = try arena.alloc(Atom, n);
        const tgts = try arena.alloc(Target, n);
        @memcpy(atoms, tbl.keys());
        @memcpy(tgts, tbl.values());
        try sortByKeyU32(scratch, atoms, tgts);
        amb[i] = .{ .atoms = atoms, .targets = tgts };
    }

    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .ambient_exports = amb, .ambient_specs = amb_specs, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals };
}

/// Sort parallel (key, value) arrays by key ascending. Export/import tables
/// come out of an `AutoArrayHashMap` in insertion order (not nearly sorted),
/// so use an O(n log n) sort over an index permutation (`scratch` holds the
/// permutation and the copied-out originals; both are freed with the arena).
fn sortByKeyU32(scratch: Allocator, keys: []u32, vals: []Target) Error!void {
    const n = keys.len;
    if (n < 2) return;
    const idx = try scratch.alloc(u32, n);
    for (idx, 0..) |*x, k| x.* = @intCast(k);
    std.mem.sort(u32, idx, keys, struct {
        fn lt(ks: []const u32, a: u32, b: u32) bool {
            return ks[a] < ks[b];
        }
    }.lt);
    const keys_copy = try scratch.dupe(u32, keys);
    const vals_copy = try scratch.dupe(Target, vals);
    for (idx, 0..) |old, k| {
        keys[k] = keys_copy[old];
        vals[k] = vals_copy[old];
    }
}

// ===========================================================================
// triple-slash reference directives (M11c)
// ===========================================================================

pub const RefKind = enum { path, types };
/// A `/// <reference path=… />` / `<reference types=… />` directive; `spec`
/// slices into the source. `lib=` references are ignored (built-in libs).
pub const RefDirective = struct { kind: RefKind, spec: []const u8 };

/// Scan the leading `///`-comment block of `src` for reference directives.
/// tsc only honors them before the first token, so scanning stops at the
/// first non-trivia character. Slices into `src` (no allocation of text).
pub fn scanReferences(alloc: Allocator, src: []const u8) Error![]RefDirective {
    var out: std.ArrayList(RefDirective) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) i += 1;
        if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '/') {
            const start = i;
            while (i < src.len and src[i] != '\n') i += 1;
            const line = src[start..i];
            // Triple-slash only.
            if (line.len >= 3 and line[2] == '/') {
                if (parseReference(line[3..])) |d| try out.append(alloc, d);
            }
            continue;
        }
        if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = if (i + 1 < src.len) i + 2 else src.len;
            continue;
        }
        break; // first real token — directives must precede it
    }
    return out.toOwnedSlice(alloc);
}

/// Parse the body of a `///` comment (text after the three slashes) into a
/// reference directive, or null if it is not `<reference path|types=…/>`.
fn parseReference(body: []const u8) ?RefDirective {
    var s = body;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    if (!std.mem.startsWith(u8, s, "<reference")) return null;
    if (attrValue(s, "path")) |v| return .{ .kind = .path, .spec = v };
    if (attrValue(s, "types")) |v| return .{ .kind = .types, .spec = v };
    return null;
}

/// Value of a `key="…"` / `key='…'` attribute in `s`, or null.
fn attrValue(s: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, key)) |at| {
        var k = at + key.len;
        while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
        if (k < s.len and s[k] == '=') {
            k += 1;
            while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
            if (k < s.len and (s[k] == '"' or s[k] == '\'')) {
                const q = s[k];
                k += 1;
                const vstart = k;
                while (k < s.len and s[k] != q) k += 1;
                if (k < s.len) return s[vstart..k];
            }
        }
        from = at + key.len;
    }
    return null;
}

/// Resolve a reference directive to a file path (owned by `alloc`), or null.
/// `path` references resolve relative to the referencing file's directory;
/// `types` references resolve like a bare package, preferring `@types/<name>`.
pub fn resolveReference(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    importer: []const u8,
    ref: RefDirective,
) Error!?[]u8 {
    switch (ref.kind) {
        .path => {
            const stem = try joinNormalize(alloc, dirnamePart(importer), ref.spec);
            defer alloc.free(stem);
            return resolveStem(io, alloc, dir, stem);
        },
        .types => {
            const scoped = try std.fmt.allocPrint(alloc, "@types/{s}", .{ref.spec});
            defer alloc.free(scoped);
            if (try resolvePackage(io, alloc, dir, dirnamePart(importer), scoped)) |p| return p;
            return resolvePackage(io, alloc, dir, dirnamePart(importer), ref.spec);
        },
    }
}

// ===========================================================================
// serial program builder (tests, tools; main.zig runs the parallel version)
// ===========================================================================

pub const BuildDiag = struct { path: []const u8, err: anyerror };

pub const BuildResult = struct {
    program: Program,
    /// Entry files that failed to load.
    load_failures: []const BuildDiag,
};

/// Serial wavefront: load, parse, bind and resolve transitively from
/// `entries` (paths relative to `dir`), then link. Everything lives in
/// `arena`.
pub fn buildProgram(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    dir: Io.Dir,
    entries: []const []const u8,
    no_lib: bool,
) !BuildResult {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var rcache = ResolveCache.init(arena, true);

    var files: std.ArrayList(ProgFile) = .empty;
    var path_ids: std.StringHashMapUnmanaged(FileId) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var failures: std.ArrayList(BuildDiag) = .empty;

    // Inject the ES-core lib as the first entry (file 0) unless disabled.
    if (!no_lib) {
        try path_ids.put(scratch, lib_path, 0);
        try pending.append(scratch, lib_path);
    }

    for (entries) |e| {
        const norm = try normalizePath(arena, e);
        const gop = try path_ids.getOrPut(scratch, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(files.items.len + pending.items.len);
            try pending.append(scratch, norm);
        }
    }

    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const path = pending.items[next];
        const bytes: []const u8 = if (std.mem.eql(u8, path, lib_path))
            lib_source
        else
            dir.readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| {
                try failures.append(scratch, .{ .path = path, .err = err });
                // Keep ids dense: substitute an empty file.
                const tree = try arena.create(Ast);
                tree.* = try parser.parse(arena, "");
                const bound = try arena.create(Bind);
                bound.* = try binder.bind(arena, io, gpa, interner, tree, "");
                try files.append(arena, .{ .path = path, .src = "", .tree = tree, .bind = bound });
                continue;
            };
        const tree = try arena.create(Ast);
        tree.* = try parser.parseOpts(arena, bytes, parser.isJsxPath(path));
        const bound = try arena.create(Bind);
        bound.* = try binder.bind(arena, io, gpa, interner, tree, bytes);

        // Triple-slash `/// <reference>` directives pull extra files into the
        // program (M11c) — not import bindings, just program inputs.
        for (try scanReferences(scratch, bytes)) |ref| {
            if (try resolveReference(io, scratch, dir, path, ref)) |resolved| {
                const stable = try arena.dupe(u8, resolved);
                const gop = try path_ids.getOrPut(scratch, stable);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(pending.items.len);
                    try pending.append(scratch, stable);
                }
            }
        }

        // Resolve this file's specifiers; discover new files.
        var spec_atoms: std.ArrayList(Atom) = .empty;
        var spec_files: std.ArrayList(FileId) = .empty;
        var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        for (bound.imports) |rec| {
            try resolveOne(arena, scratch, io, &rcache, dir, interner, path, rec.module, &spec_atoms, &spec_files, &seen, &path_ids, &pending);
        }
        for (bound.exports) |rec| {
            if (rec.module != 0) {
                try resolveOne(arena, scratch, io, &rcache, dir, interner, path, rec.module, &spec_atoms, &spec_files, &seen, &path_ids, &pending);
            }
        }
        sortSpecs(spec_atoms.items, spec_files.items);

        try files.append(arena, .{
            .path = path,
            .src = bytes,
            .tree = tree,
            .bind = bound,
            .specs = .{
                .atoms = try arena.dupe(Atom, spec_atoms.items),
                .files = try arena.dupe(FileId, spec_files.items),
            },
        });
        spec_atoms.deinit(scratch);
        spec_files.deinit(scratch);
        seen.deinit(scratch);
    }

    const file_slice = try arena.dupe(ProgFile, files.items);
    const lr = try link(arena, gpa, io, interner, file_slice);
    return .{
        .program = .{
            .files = file_slice,
            .sym_base = lr.sym_base,
            .links = lr.links,
            .globals = lr.globals,
            .merged = lr.merged,
            .ambient_exports = lr.ambient_exports,
            .ambient_specs = lr.ambient_specs,
            .constit_keys = lr.constit_keys,
            .constit_vals = lr.constit_vals,
        },
        .load_failures = try arena.dupe(BuildDiag, failures.items),
    };
}

fn resolveOne(
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    rcache: *ResolveCache,
    dir: Io.Dir,
    interner: *Interner,
    importer: []const u8,
    module_atom: Atom,
    spec_atoms: *std.ArrayList(Atom),
    spec_files: *std.ArrayList(FileId),
    seen: *std.AutoHashMapUnmanaged(Atom, void),
    path_ids: *std.StringHashMapUnmanaged(FileId),
    pending: *std.ArrayList([]const u8),
) !void {
    if (module_atom == 0) return;
    const gop = try seen.getOrPut(scratch, module_atom);
    if (gop.found_existing) return;
    const spec = interner.lookup(io, module_atom);
    var fid: FileId = no_file;
    if (try rcache.resolve(io, scratch, dir, importer, spec)) |resolved| {
        const stable = try arena.dupe(u8, resolved);
        const pgop = try path_ids.getOrPut(scratch, stable);
        if (pgop.found_existing) {
            fid = pgop.value_ptr.*;
        } else {
            fid = @intCast(pending.items.len);
            pgop.value_ptr.* = fid;
            try pending.append(scratch, stable);
        }
    }
    try spec_atoms.append(scratch, module_atom);
    try spec_files.append(scratch, fid);
}

fn sortSpecs(atoms: []Atom, files: []FileId) void {
    var i: usize = 1;
    while (i < atoms.len) : (i += 1) {
        var j = i;
        while (j > 0 and atoms[j - 1] > atoms[j]) : (j -= 1) {
            std.mem.swap(Atom, &atoms[j - 1], &atoms[j]);
            std.mem.swap(FileId, &files[j - 1], &files[j]);
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "seedLibAtoms: covers every atom the lib binder produces (M12.1 determinism)" {
    const io = testing.io;
    const gpa = testing.allocator;

    // Seed a fresh interner single-threaded, as the CLI does before spawning
    // workers.
    var itn1 = Interner.init();
    defer itn1.deinit(gpa);
    try seedLibAtoms(io, gpa, &itn1);
    const seeded_count = itn1.count(io);

    // Re-binding the lib into the seeded interner must intern *zero* new
    // strings: seeding already produced every atom binding needs, including
    // the transformed ones (stripQuotes, well-known-symbol keys, the
    // "default"/"*" constants). Anything seeding missed would be interned
    // here for the first time by a worker thread — i.e. nondeterministically.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try parser.parse(a, lib_source);
    const b = try binder.bind(a, io, gpa, &itn1, &tree, lib_source);
    try testing.expectEqual(seeded_count, itn1.count(io));

    // A second, independent seed assigns byte-for-byte identical atom values
    // to the lib's strings — the run-to-run stability M12.2's blob relies on.
    var itn2 = Interner.init();
    defer itn2.deinit(gpa);
    try seedLibAtoms(io, gpa, &itn2);
    try testing.expectEqual(seeded_count, itn2.count(io));
    for (b.symbol_names[1..]) |atom| {
        if (atom == 0) continue; // anonymous symbol, no name
        try testing.expectEqualStrings(itn1.lookup(io, atom), itn2.lookup(io, atom));
    }
}

test "normalizePath: lexical cleanup" {
    const alloc = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "a/./b", "a/b" },
        .{ "a/../b", "b" },
        .{ "./x", "x" },
        .{ "a/b/../../c", "c" },
        .{ "../x", "../x" },
        .{ "a//b", "a/b" },
        .{ "/a/../b", "/b" },
        .{ ".", "." },
        .{ "a/..", "." },
    };
    for (cases) |c| {
        const got = try normalizePath(alloc, c[0]);
        defer alloc.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "dirnamePart" {
    try testing.expectEqualStrings("", dirnamePart("x.ts"));
    try testing.expectEqualStrings("a/b", dirnamePart("a/b/x.ts"));
    try testing.expectEqualStrings("/", dirnamePart("/x.ts"));
}

test "packageTypesField: minimal scan" {
    try testing.expectEqualStrings("index.d.ts", packageTypesField(
        \\{ "name": "p", "types": "index.d.ts" }
    ).?);
    try testing.expectEqualStrings("lib/main.d.ts", packageTypesField(
        \\{ "typings" : "lib/main.d.ts" }
    ).?);
    try testing.expectEqual(@as(?[]const u8, null), packageTypesField(
        \\{ "name": "p" }
    ));
}

test "resolveSpecifier: relative, index, js rewrite, node_modules" {
    const io = testing.io;
    // Candidate paths are transient and owned by the passed allocator; a
    // scratch arena mirrors how the real driver calls resolution.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/util");
    try d.createDirPath(io, "node_modules/pkg");
    try d.createDirPath(io, "node_modules/@scope/tools");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/c.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/util/index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/package.json", .data = "{ \"types\": \"main.d.ts\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/main.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/extra.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/@scope/tools/index.d.ts", .data = "" });

    const cases = [_]struct { spec: []const u8, want: ?[]const u8 }{
        .{ .spec = "./b", .want = "src/b.ts" },
        .{ .spec = "./b.ts", .want = "src/b.ts" },
        .{ .spec = "./b.js", .want = "src/b.ts" },
        .{ .spec = "./c", .want = "src/c.d.ts" },
        .{ .spec = "./c.js", .want = "src/c.d.ts" },
        .{ .spec = "./util", .want = "src/util/index.ts" },
        .{ .spec = "../src/b", .want = "src/b.ts" },
        .{ .spec = "./nope", .want = null },
        .{ .spec = "pkg", .want = "node_modules/pkg/main.d.ts" },
        .{ .spec = "pkg/extra", .want = "node_modules/pkg/extra.d.ts" },
        .{ .spec = "@scope/tools", .want = "node_modules/@scope/tools/index.d.ts" },
        .{ .spec = "ghost", .want = null },
    };
    for (cases) |c| {
        const got = try resolveSpecifier(io, alloc, d, "src/a.ts", c.spec);
        if (c.want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expectEqual(@as(?[]u8, null), got);
        }
    }
}

// M13: the resolution memo serves a repeated `(importer_dir, spec)` from
// cache with no new FS probes, caches unresolvable specifiers (negative
// cache), and returns byte-identical results to the uncached path.
test "ResolveCache: memo collapses repeated resolution, matches uncached" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src");
    try d.createDirPath(io, "node_modules/pkg");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/package.json", .data = "{ \"types\": \"main.d.ts\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/main.d.ts", .data = "" });

    var rc = ResolveCache.init(alloc, true);

    // First resolve of a bare specifier walks the tree (probes > 0).
    resetFsProbeCount();
    const r1 = try rc.resolve(io, alloc, d, "src/a.ts", "pkg");
    try testing.expectEqualStrings("node_modules/pkg/main.d.ts", r1.?);
    try testing.expect(fsProbeCount() > 0);

    // Second resolve of the same (dir, spec) — a sibling importer in `src`
    // — is served from the memo: zero additional probes, same answer.
    resetFsProbeCount();
    const r2 = try rc.resolve(io, alloc, d, "src/b.ts", "pkg");
    try testing.expectEqualStrings("node_modules/pkg/main.d.ts", r2.?);
    try testing.expectEqual(@as(u64, 0), fsProbeCount());
    try testing.expectEqual(@as(u64, 2), rc.lookups);
    try testing.expectEqual(@as(u64, 1), rc.hits);

    // Negative caching: an unresolvable specifier probes once, then never.
    resetFsProbeCount();
    const n1 = try rc.resolve(io, alloc, d, "src/a.ts", "ghost");
    try testing.expectEqual(@as(?[]const u8, null), n1);
    const after_miss = fsProbeCount();
    try testing.expect(after_miss > 0);
    const n2 = try rc.resolve(io, alloc, d, "src/b.ts", "ghost");
    try testing.expectEqual(@as(?[]const u8, null), n2);
    try testing.expectEqual(after_miss, fsProbeCount()); // no new probes

    // A disabled cache is a pure pass-through to `resolveSpecifier`.
    var off = ResolveCache.init(alloc, false);
    const p1 = try off.resolve(io, alloc, d, "src/a.ts", "pkg");
    const p2 = try resolveSpecifier(io, alloc, d, "src/a.ts", "pkg");
    try testing.expectEqualStrings(p2.?, p1.?);
    try testing.expectEqual(@as(u64, 0), off.lookups);
}

// Regression: resolution used to build candidate paths in a fixed 256-byte
// buffer and silently return null (a wrong "module not found") for any
// deeper path — exactly the shape of `node_modules/@types/...` in a big
// project. The stem here is well over 256 bytes.
test "resolveSpecifier: path longer than the old 256-byte cap" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // 8 segments of 40 chars each -> ~320-byte directory chain, past 256.
    const seg = "a234567890123456789012345678901234567890"; // 40 chars
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(alloc);
    for (0..8) |k| {
        if (k != 0) try deep.append(alloc, '/');
        try deep.appendSlice(alloc, seg);
    }
    const deep_dir = deep.items;
    try testing.expect(deep_dir.len > 256);

    try d.createDirPath(io, deep_dir);
    const modpath = try std.fmt.allocPrint(alloc, "{s}/mod.ts", .{deep_dir});
    try d.writeFile(io, .{ .sub_path = modpath, .data = "" });

    const spec = try std.fmt.allocPrint(alloc, "./{s}/mod", .{deep_dir});
    const got = try resolveSpecifier(io, alloc, d, "a.ts", spec);
    try testing.expect(got != null);
    try testing.expectEqualStrings(modpath, got.?);
}
