//! Module resolution, module graph, and cross-file symbol linking (M5).
//!
//! Design decisions (ROADMAP.md §2.3, M5):
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
//!   the check path (ROADMAP.md §2.3 immutability boundary).
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
pub const lib_path = "\x00lib/es.core.d.ts";
/// The embedded lib text (see `src/lib/es.core.d.ts`). Bound once per run;
/// its top-level declarations become the program's global symbols.
pub const lib_source = @embedFile("lib/es.core.d.ts");

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
/// are compared here (ROADMAP §5 M11 invariant 1).
pub const MergedSym = struct {
    name: Atom,
    flags: binder.SymbolFlags,
    parts: []const u32,
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

    /// Count of real per-file symbols (merged ids start here).
    pub fn totalSymbols(p: *const Program) u32 {
        return p.sym_base[p.files.len];
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
};

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
/// program global table, in FileId order (deterministic; ROADMAP §5 M11
/// invariant 4). The lib and script files offer their whole top level;
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
    const total_syms = sym_base[files.len];

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

    const g_atoms = try arena.alloc(Atom, n);
    const g_syms = try arena.alloc(u32, n);
    var merged_list: std.ArrayListUnmanaged(MergedSym) = .empty;
    for (names, 0..) |atom, i| {
        const parts = acc.get(atom).?.items;
        g_atoms[i] = atom;
        if (parts.len == 1) {
            g_syms[i] = parts[0];
            continue;
        }
        var flags: binder.SymbolFlags = .{};
        for (parts) |p| flags = binder.SymbolFlags.merge(flags, globalSymFlags(files, sym_base, p));
        const id = total_syms + @as(u32, @intCast(merged_list.items.len));
        try merged_list.append(arena, .{
            .name = atom,
            .flags = flags,
            .parts = try arena.dupe(u32, parts),
        });
        g_syms[i] = id;
    }
    return .{
        .globals = .{ .atoms = g_atoms, .syms = g_syms },
        .merged = try arena.dupe(MergedSym, merged_list.items),
    };
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
    return .{ .files = files, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged };
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

fn fileExists(io: Io, dir: Io.Dir, path: []const u8) bool {
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
            try l.diag(file, 2307, l.tokSpan(file, mod_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{stripped});
        }
    }

    /// Link one file's import bindings.
    fn linkImports(l: *Linker, file: FileId, locals: *std.ArrayList(u32), targets: *std.ArrayList(Target)) Error!void {
        const f = &l.files[file];
        for (f.bind.imports) |rec| {
            if (rec.kind == .side_effect) continue;
            const local_sym = f.bind.lookupInScope(binder.file_scope, rec.local) orelse continue;
            var tgt: Target = .{ .kind = .any };
            if (f.specs.get(rec.module)) |mfile| {
                switch (rec.kind) {
                    .namespace => tgt = .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only },
                    .named => {
                        if (try l.lookupExport(mfile, rec.imported, 0)) |found| {
                            tgt = found;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else {
                            try l.diag(file, 2305, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no exported member '{s}'.", .{
                                l.atomText(rec.module), l.atomText(rec.imported),
                            });
                        }
                    },
                    .default => {
                        if (try l.lookupExport(mfile, l.atom_default, 0)) |found| {
                            tgt = found;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if ((try l.lookupExport(mfile, rec.local, 0)) != null) {
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
    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged };
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

        // Resolve this file's specifiers; discover new files.
        var spec_atoms: std.ArrayList(Atom) = .empty;
        var spec_files: std.ArrayList(FileId) = .empty;
        var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        for (bound.imports) |rec| {
            try resolveOne(arena, scratch, io, interner, dir, path, rec.module, &spec_atoms, &spec_files, &seen, &path_ids, &pending);
        }
        for (bound.exports) |rec| {
            if (rec.module != 0) {
                try resolveOne(arena, scratch, io, interner, dir, path, rec.module, &spec_atoms, &spec_files, &seen, &path_ids, &pending);
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
        },
        .load_failures = try arena.dupe(BuildDiag, failures.items),
    };
}

fn resolveOne(
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    interner: *Interner,
    dir: Io.Dir,
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
    if (try resolveSpecifier(io, scratch, dir, importer, spec)) |resolved| {
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
