//! The program: module graph, cross-file symbol linking, global merge.
//!
//! This is the project-wide data contract — `FileId`, `Program`, `ProgFile`,
//! `Target` — plus the two ways a program is built (the parallel driver in
//! main.zig calls `link` directly; `buildProgram` is the serial wavefront the
//! tests and tools use). Specifier resolution lives in resolve.zig, the
//! embedded libs in libs.zig, and the lexical path helpers in paths.zig.
//!
//! Design decisions:
//!
//! - **Nonexistent module → TS2307** at the module-specifier string of the
//!   import/export statement (one per statement). A module that resolved but
//!   turned out to be undeclared JavaScript from `node_modules` gets TS7016
//!   at the same anchor, under `noImplicitAny`.
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
const libs = @import("libs.zig");
const paths = @import("paths.zig");
const resolve = @import("resolve.zig");

const Ast = ast.Ast;
const Bind = binder.Bind;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Span = source.Span;

const LibFile = libs.LibFile;
const LibSet = libs.LibSet;
const ResolveCache = resolve.ResolveCache;
const ResolveOpts = resolve.ResolveOpts;
const max_lib_files = libs.max_lib_files;

pub const Error = error{OutOfMemory};

pub const FileId = u32;
pub const no_file: FileId = std.math.maxInt(FileId);

// ===========================================================================
// program construction & linking
// ===========================================================================

/// The tsconfig options the *link* phase reads. Both are per-program constants
/// the driver settles before any file is linked; grouping them keeps the two
/// booleans from becoming an unlabelled pair at every call site.
pub const LinkOpts = struct {
    /// tsconfig `allowSyntheticDefaultImports`/`esModuleInterop`: a default
    /// import of a module with no default export binds to the module namespace
    /// object. See `linkImports`.
    allow_synthetic_default: bool = false,
    /// tsconfig `noImplicitAny`. Gates TS7016 ("Could not find a declaration
    /// file for module …"), the link-phase member of the implicit-any family;
    /// the checker gates TS7006/TS7053 on `Program.no_implicit_any`, which the
    /// driver sets from the same option.
    no_implicit_any: bool = true,
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
    lib_set: LibSet,
    resolve_opts: ResolveOpts,
    link_opts: LinkOpts,
    /// `<jsxImportSource>/jsx-runtime` under the automatic JSX runtime, else
    /// null. Pulled into the program on the first `.tsx` file, exactly as the
    /// CLI driver does; its FileId becomes `Program.jsx_runtime_file`.
    jsx_runtime_module: ?[]const u8,
) !BuildResult {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var rcache = ResolveCache.init(arena, true, resolve_opts);

    var files: std.ArrayList(ProgFile) = .empty;
    var path_ids: std.StringHashMapUnmanaged(FileId) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var failures: std.ArrayList(BuildDiag) = .empty;

    // Inject the selected built-in lib blobs as the first entries (files 0..).
    var lib_buf: [max_lib_files]LibFile = undefined;
    for (libs.libFiles(lib_set, &lib_buf)) |lf| {
        try path_ids.put(scratch, lf.path, @intCast(pending.items.len));
        try pending.append(scratch, lf.path);
    }

    for (entries) |e| {
        const norm = try paths.normalizePath(arena, e);
        const gop = try path_ids.getOrPut(scratch, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(files.items.len + pending.items.len);
            try pending.append(scratch, norm);
        }
    }

    var jsx_runtime_fid: FileId = no_file;
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const path = pending.items[next];
        const bytes: []const u8 = if (libs.libSourceFor(path)) |s|
            s
        else if (paths.anyModuleSourceFor(path)) |s|
            s
        else
            dir.readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| {
                try failures.append(scratch, .{ .path = path, .err = err });
                // Keep ids dense: substitute an empty file.
                const tree = try arena.create(Ast);
                tree.* = try parser.parse(arena, "");
                const bound = try arena.create(Bind);
                bound.* = try binder.bind(arena, io, gpa, interner, tree, "", parser.isDeclarationPath(path));
                try files.append(arena, .{ .path = path, .src = "", .tree = tree, .bind = bound });
                continue;
            };
        const tree = try arena.create(Ast);
        tree.* = try parser.parseOpts(arena, bytes, parser.isJsxPath(path));
        const bound = try arena.create(Bind);
        bound.* = try binder.bind(arena, io, gpa, interner, tree, bytes, parser.isDeclarationPath(path));

        // Automatic JSX runtime: `<jsxImportSource>/jsx-runtime` exports the
        // `JSX` namespace (no global one exists under @types/react 19), so it is
        // a program input for every JSX file. Injected once, like a
        // triple-slash reference.
        if (jsx_runtime_fid == no_file and jsx_runtime_module != null and
            std.mem.endsWith(u8, path, ".tsx"))
        {
            if (try rcache.resolve(io, scratch, dir, path, jsx_runtime_module.?)) |jp| {
                const stable = try arena.dupe(u8, jp);
                const gop = try path_ids.getOrPut(scratch, stable);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(pending.items.len);
                    try pending.append(scratch, stable);
                }
                jsx_runtime_fid = gop.value_ptr.*;
            }
        }

        // Triple-slash `/// <reference>` directives pull extra files into the
        // program — not import bindings, just program inputs.
        for (try resolve.scanReferences(scratch, bytes)) |ref| {
            if (try rcache.resolveRef(io, scratch, dir, path, ref)) |resolved| {
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
    const lr = try link(arena, gpa, io, interner, file_slice, link_opts);
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
            .export_equals_atom = lr.export_equals_atom,
            .jsx_runtime_file = jsx_runtime_fid,
        },
        .load_failures = try arena.dupe(BuildDiag, failures.items),
    };
}

/// Build the sealed per-file link tables and the merged global table. Serial;
/// results live in `arena`.
pub fn link(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []const ProgFile,
    link_opts: LinkOpts,
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
        .allow_synthetic_default = link_opts.allow_synthetic_default,
        .no_implicit_any = link_opts.no_implicit_any,
        .atom_export_equals = interner.intern(io, gpa, "export=") catch return Error.OutOfMemory,
        .state = try scratch.alloc(u8, files.len),
        .tables = try scratch.alloc(std.AutoArrayHashMapUnmanaged(Atom, Target), files.len),
        .diags = try scratch.alloc(std.ArrayList(LinkDiag), files.len),
    };
    @memset(l.state, 0);
    for (l.tables) |*t| t.* = .empty;
    for (l.diags) |*d| d.* = .empty;

    // Build every export table (deterministic file order).
    for (0..files.len) |i| _ = try l.table(@intCast(i));
    // Then the ambient/augmentation module registry, which import
    // resolution and TS2307 suppression consult below.
    try l.buildAmbient();

    const out = try arena.alloc(FileLinks, files.len);
    for (0..files.len) |i| {
        const fid: FileId = @intCast(i);
        try l.reportUnresolvedModules(fid);
        try l.reportModuleGrammar(fid);

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

    // Cross-file global merge + module augmentation merge: fold
    // every file's harvest slice and every `declare module` augmentation of a
    // resolved real module. Needs the sealed export tables (`out`).
    const sym_base = try computeSymBase(arena, files);
    const gm = try mergeGlobals(arena, scratch, files, sym_base, out, l.atom_export_equals);

    // Seal the ambient module export tables in registry order, so
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

    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .ambient_exports = amb, .ambient_specs = amb_specs, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals, .export_equals_atom = l.atom_export_equals };
}

/// Wrap one already-bound file as an unlinked Program (legacy single-file paths).
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

/// Build a program of the selected lib blobs (files 0..) plus one already-bound
/// source file (last file), with the libs' globals collected. Used by the
/// single-file test/conformance path so those cases see the same globals
/// and primitive/array methods the CLI provides. An empty `lib_set` reproduces
/// the legacy lib-free single-file program.
pub fn singleWithLibProgram(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    path: []const u8,
    src: []const u8,
    tree: *const Ast,
    bind: *const Bind,
    lib_set: LibSet,
) !Program {
    if (!lib_set.any()) return singleFileProgram(arena, path, src, tree, bind);
    var buf: [max_lib_files]LibFile = undefined;
    const lib_list = libs.libFiles(lib_set, &buf);
    const files = try arena.alloc(ProgFile, lib_list.len + 1);
    for (lib_list, 0..) |lf, i| {
        const lib_tree = try arena.create(Ast);
        lib_tree.* = try parser.parse(arena, lf.source);
        const lib_bind = try arena.create(Bind);
        lib_bind.* = try binder.bind(arena, io, gpa, interner, lib_tree, lf.source, true);
        files[i] = .{ .path = lf.path, .src = lf.source, .tree = lib_tree, .bind = lib_bind };
    }
    files[lib_list.len] = .{ .path = path, .src = src, .tree = tree, .bind = bind };
    const sym_base = try computeSymBase(arena, files);
    // Unlinked single-file path: a script user file may still augment lib
    // globals; merge diagnostics (none for the clean case) have no link table
    // to land in here and are dropped.
    const gm = try mergeGlobals(arena, arena, files, sym_base, &.{}, 0);
    return .{ .files = files, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals };
}

pub const BuildDiag = struct { path: []const u8, err: anyerror };

pub const BuildResult = struct {
    program: Program,
    /// Entry files that failed to load.
    load_failures: []const BuildDiag,
};

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
    export_equals_atom: Atom = 0,
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
    /// Cross-file merged global symbols. Program id of entry `k` is
    /// `totalSymbols() + k`. Empty in the common case (no name has 2+
    /// contributors).
    merged: []const MergedSym = &.{},
    /// Ambient module export tables, indexed by `Target.ambient_ns`
    /// payloads; for `import * as ns from "<ambient>"` namespace objects.
    ambient_exports: []const AmbientExport = &.{},
    /// Specifier atom of each `ambient_exports[i]` (the `declare module`
    /// name/pattern, in registry order). Lets a type-position `import("m")`
    /// resolve against an ambient module by exact or wildcard match.
    ambient_specs: []const Atom = &.{},
    /// Reverse merge index: merge-constituent real id → merged id,
    /// parallel arrays sorted by key. See `mergedOf`.
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
    /// Reserved atom keying `export = X` entries in export/ambient tables, so
    /// the namespace-object builders can skip it. 0 when no linker ran.
    export_equals_atom: Atom = 0,
    /// Effective `noImplicitAny` (true = on = report). When false, the checker
    /// suppresses the implicit-'any' diagnostic family (TS7006/TS7053); the
    /// affected values still type as `any`. Defaults on (strict semantics); the
    /// driver sets it from the tsconfig. See `tsconfig.Config.no_implicit_any`.
    no_implicit_any: bool = true,
    /// The `<jsxImportSource>/jsx-runtime` module under the automatic JSX
    /// runtime (`jsx: "react-jsx"`), or `no_file`. tsc reads the `JSX` namespace
    /// off this module's exports there; the checker falls back to it when no
    /// global `JSX` namespace exists. See `tsconfig.Config.jsx_runtime_module`.
    jsx_runtime_file: FileId = no_file,

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
        /// "fs"`): `payload` indexes `Program.ambient_exports`.
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

/// Global (lib) name table: the top-level declarations of the injected
/// lib file, keyed by name atom, holding GLOBAL SymbolIds. Sorted by atom
/// for binary-search fallback in name resolution (checker `resolveSpace`).
/// Empty when `--noLib` / no lib is injected. A name with a single
/// contributor maps to that contributor's `(file, sym)` global id; a name
/// with 2+ contributors maps to a merged-range id (`≥ totalSymbols()`)
/// indexing `Program.merged`.
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

/// A cross-file merged global symbol. When 2+ files contribute the
/// same global name, the linker allocates one of these; its program id is
/// `totalSymbols() + index` (the merged range). `flags` is the OR of the
/// constituents' flags; `parts` are the constituent GLOBAL SymbolIds (real
/// ids `< totalSymbols()`) in FileId order. Checkers materialize the type by
/// folding each constituent's declarations across files (the type-level twin
/// of within-file merging). Merge remains a symbol-table operation — no types
/// are compared here (invariant: merge symbols, never types).
pub const MergedSym = struct {
    name: Atom,
    flags: binder.SymbolFlags,
    parts: []const u32,
    /// Merged member index for namespace-bearing merges: member name
    /// atom → global sym (itself possibly a merged-range id, so a nested
    /// interface/namespace reopened across files resolves recursively).
    /// Sorted by atom; empty for non-namespace merges (interfaces materialize
    /// to object types, so their members need no symbol-level index).
    members: Globals = .{},
};

/// An ambient module's sealed export table, for `import * as ns`
/// namespace objects. Entries are (export-name atom → Target), atom-sorted.
pub const AmbientExport = struct {
    atoms: []const Atom = &.{},
    targets: []const Target = &.{},
};

/// Result of folding every file's global contributions.
pub const GlobalMerge = struct {
    globals: Globals = .{},
    merged: []const MergedSym = &.{},
    /// Reverse index: each merge constituent's real global id → the
    /// merged-range id it folds into. Parallel arrays sorted by key. Lets a
    /// reference to a merged name from *inside* a contributing file (which
    /// binds to the file-local constituent, not the global fallback) route to
    /// the merged view. Empty in the common case (no cross-file merges).
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
};

// ===========================================================================
// private implementation
// ===========================================================================

// ---------------------------------------------------------------------------
// cross-file global merge
// ---------------------------------------------------------------------------

/// Prefix sums of per-file symbol-array lengths (incl. the per-file dummy).
fn computeSymBase(alloc: Allocator, files: []const ProgFile) Error![]u32 {
    const base = try alloc.alloc(u32, files.len + 1);
    base[0] = 0;
    for (files, 0..) |*f, i| {
        base[i + 1] = base[i] + @as(u32, @intCast(f.bind.symbol_names.len));
    }
    return base;
}

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
/// the cross-file merge is a pure function of file order). The lib and script files
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
fn mergeGlobals(
    arena: Allocator,
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    links: []const FileLinks,
    export_equals_atom: Atom,
) Error!GlobalMerge {
    // Accumulate name -> constituent global ids in TWO passes over the files,
    // each pass in FileId order: first every *script*'s own top level, then
    // every `declare global { … }` augmentation block (`global_aug_start`
    // splits each file's harvest). That is tsc's merge order — `initialize
    // TypeChecker` folds the non-module files' locals into `globals` and only
    // afterwards merges the collected global-scope augmentations — and merge
    // order decides precedence: `mergeSymbol` keeps the target's existing
    // value declaration, so a script's `declare var expect: jest.Expect` wins
    // the *value* over a module's `declare global { const expect: … }` no
    // matter which file was loaded first. `parts[0]` is that winner here.
    // Type space is unaffected: every constituent still folds (interface
    // merging is order-independent by name-sorted union).
    var acc: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)) = .empty;
    for ([2]bool{ false, true }) |aug_pass| {
        for (files, 0..) |*f, fi| {
            const b = f.bind;
            if (b.global_atoms.len == 0) continue;
            const split = @min(b.global_aug_start, b.global_atoms.len);
            const lo = if (aug_pass) split else 0;
            const hi = if (aug_pass) b.global_atoms.len else split;
            const base = sym_base[fi];
            for (b.global_atoms[lo..hi], b.global_syms[lo..hi]) |atom, local| {
                const gop = try acc.getOrPut(scratch, atom);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(scratch, base + local);
            }
        }
    }

    var m: Merger = .{ .arena = arena, .scratch = scratch, .files = files, .sym_base = sym_base };

    // Global (declare-global / script / lib) name merge.
    var globals: Globals = .{};
    if (acc.count() != 0) {
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
        for (names, 0..) |atom, i| {
            g_atoms[i] = atom;
            g_syms[i] = try m.mergeSet(acc.get(atom).?.items);
        }
        globals = .{ .atoms = g_atoms, .syms = g_syms };
    }

    // Cross-file module augmentation merge: fold a `declare module
    // "spec" { interface I { … } }` block (in a MODULE-context file) into the
    // interface `I` already exported by the real module `spec` resolves to.
    try mergeAugmentations(&m, files, sym_base, links, export_equals_atom);

    if (m.merged.items.len == 0) return .{ .globals = globals };

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
        .globals = globals,
        .merged = try arena.dupe(MergedSym, m.merged.items),
        .constit_keys = ck,
        .constit_vals = cv,
    };
}

/// Cross-file module augmentation merge. A `declare module "spec" { …
/// }` block in a file that is itself a *module* (has top-level import/export)
/// augments the module `spec` resolves to — the TypeScript rule that
/// distinguishes an augmentation from a standalone ambient-module declaration
/// (which lives in a *script*). For every interface declared in such a block
/// whose name is already an interface export of the resolved real module, this
/// forms a cross-file merged symbol `[real, aug…]` and registers both sides in
/// the reverse index, so an `import { I }` (or `ns.I`) of the real module
/// resolves to the folded interface (all members from every file).
///
/// Order-invariant: augmentation contributors are collected in FileId order and
/// the merged member set is a union displayed name-sorted, so the observable
/// type is independent of discovery order (only a same-name/different-type
/// conflict's winner is order-sensitive — a deferred TS2717 under-report). New
/// exports added by an augmentation and augmentations of an *unresolved*
/// specifier keep their existing behavior (the ambient export-table fallback in
/// `linkImports`); only merges into an existing real interface are handled here.
fn mergeAugmentations(
    m: *Merger,
    files: []const ProgFile,
    sym_base: []const u32,
    links: []const FileLinks,
    export_equals_atom: Atom,
) Error!void {
    if (links.len != files.len) return; // unlinked path: no export tables

    // real interface export global id → augmenting block interface global ids.
    var aug: std.AutoArrayHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    for (files, 0..) |*f, fi| {
        const b = f.bind;
        // A `declare module` is an augmentation only in a module context; in a
        // script it is a standalone ambient module (left to the fallback path).
        if (!b.is_module or b.ambient_modules.len == 0) continue;
        const base = sym_base[fi];
        for (b.ambient_modules) |am| {
            const mfile = f.specs.get(am.spec) orelse continue; // unresolved: fallback
            const lo = b.scope_members_start[am.scope];
            const hi = b.scope_members_start[am.scope + 1];
            for (lo..hi) |i| {
                const local = b.member_syms[i];
                // The augmenting block member must be an interface or a
                // namespace. An interface merges into a real interface/class
                // (instance members); a `namespace N { … }` block merges into a
                // real namespace/function-namespace, adding value members
                // reached as `N.member` (`declare module "leaflet" { namespace
                // control { function sideBySide } }`). Value/generic type-param
                // unification stays deferred — degrade, no crash.
                const lf_flags = b.symbol_flags[local];
                if (!lf_flags.interface and !lf_flags.namespace_decl) continue;
                const name = b.member_atoms[i];
                const tgt = links[mfile].exportTarget(name) orelse
                    exportEqualsMemberTarget(files, links, mfile, export_equals_atom, name) orelse
                    continue;
                if (tgt.kind != .binding) continue;
                const real = sym_base[tgt.file] + tgt.payload;
                // The real export may be an interface (interface↔interface
                // merge), a class (an interface augmentation of a class —
                // `declare module "leaflet" { interface Map { pm } }` against
                // `class Map` — folded into the class instance by
                // `classInstanceGeneric`), or a namespace/function-namespace
                // (namespace↔namespace value-member merge).
                const rf = globalSymFlags(files, sym_base, real);
                if (!rf.interface and !rf.class and !rf.namespace_decl) continue;
                const aug_id = base + local;
                if (real == aug_id) continue; // self (should not happen)
                const gop = try aug.getOrPut(m.scratch, real);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(m.scratch, aug_id);
            }
        }
    }
    if (aug.count() == 0) return;

    // Deterministic merged-id assignment: process real keys in ascending order.
    const keys = try m.scratch.alloc(u32, aug.count());
    @memcpy(keys, aug.keys());
    std.mem.sort(u32, keys, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    for (keys) |real| {
        const augs = aug.get(real).?.items; // FileId order by construction
        const parts = try m.scratch.alloc(u32, 1 + augs.len);
        parts[0] = real;
        @memcpy(parts[1..], augs);
        _ = try m.mergeSet(parts);
    }
}

/// Member `name` of the entity a module exports with `export = <entity>`, read
/// off the *sealed* link tables (`mergeAugmentations` runs after the linker has
/// finished, so `Linker.exportEqualsMember` is out of reach). Two container
/// shapes, exactly as the linker's version: a namespace `.binding` (look the
/// name up in that symbol's body scope) and a whole module-namespace object
/// (look it up in that module's export table).
///
/// This is what makes an augmentation of a DefinitelyTyped-shaped package
/// (`export = _; declare const _: _.LoDashStatic; declare namespace _ {
/// interface LoDashStatic {} }`) merge at all: `LoDashStatic` is not an export
/// of the module — it is a member of the export-assigned namespace — so a
/// direct `exportTarget` lookup misses and every `declare module "../index" {
/// interface LoDashStatic { … } }` block was silently dropped.
fn exportEqualsMemberTarget(
    files: []const ProgFile,
    links: []const FileLinks,
    mfile: FileId,
    export_equals_atom: Atom,
    name: Atom,
) ?Target {
    if (export_equals_atom == 0) return null;
    const exeq = links[mfile].exportTarget(export_equals_atom) orelse return null;
    switch (exeq.kind) {
        .binding => {
            const b = files[exeq.file].bind;
            const ns = b.namespaceScopeOf(exeq.payload) orelse return null;
            const local = b.lookupInScope(ns, name) orelse return null;
            // An imported member re-exported out of the namespace body: follow
            // the import binding to its defining declaration.
            if (b.symbol_flags[local].import_binding) {
                const t = links[exeq.file].importTarget(local) orelse return null;
                return t;
            }
            return .{ .kind = .binding, .file = exeq.file, .payload = local, .type_only = exeq.type_only };
        },
        .namespace => return links[exeq.file].exportTarget(name),
        else => return null,
    }
}

/// Recursive cross-file symbol merger. Assigns merged-range ids as
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
    /// Effective `allowSyntheticDefaultImports`/`esModuleInterop`: a default
    /// import of a module with no default export binds to the module namespace
    /// object rather than raising TS1192.
    allow_synthetic_default: bool = false,
    /// Effective `noImplicitAny`; gates TS7016 (see `LinkOpts`).
    no_implicit_any: bool = true,
    /// Reserved key under which a module's `export = X` target is stored in its
    /// export/ambient table (`export=` can never be a real export name). Skipped
    /// by the namespace-object builders and `export *` merge.
    atom_export_equals: Atom,
    /// 0 = not built, 1 = building (cycle), 2 = done.
    state: []u8,
    tables: []std.AutoArrayHashMapUnmanaged(Atom, Target),
    diags: []std.ArrayList(LinkDiag),
    /// Ambient/augmentation module registry: specifier atom → export
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

    /// A missing named import/re-export that has a close export name in the
    /// target module gets tsc's TS2724 ("Did you mean 'X'?") in place of the
    /// plain TS2305. Returns the suggested export name atom, or 0 when none is
    /// close enough (tsc's getSuggestedSymbolForNonexistentModule over the
    /// module's exports). `mfile` must be a resolved module file.
    fn moduleExportSuggestion(l: *Linker, mfile: FileId, name: Atom) Error!Atom {
        const et = l.table(mfile) catch return 0;
        if (et.count() == 0) return 0;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(l.scratch);
        var atoms: std.ArrayList(Atom) = .empty;
        defer atoms.deinit(l.scratch);
        var it = et.iterator();
        while (it.next()) |entry| {
            const a = entry.key_ptr.*;
            // Reserved internal keys are never named-export suggestions.
            if (a == l.atom_default or a == l.atom_export_equals) continue;
            try atoms.append(l.scratch, a);
            try names.append(l.scratch, l.atomText(a));
        }
        if (names.items.len == 0) return 0;
        const idx = intern.spellingSuggestion(l.scratch, l.atomText(name), names.items) orelse return 0;
        return atoms.items[idx];
    }

    /// Emit TS2305, or TS2724 when the module has a close export name.
    fn diagNoExportedMember(l: *Linker, file: FileId, mfile_opt: ?FileId, module: Atom, name: Atom, span: Span) Error!void {
        if (mfile_opt) |mfile| {
            const sugg = try l.moduleExportSuggestion(mfile, name);
            if (sugg != 0) {
                try l.diag(file, 2724, span, "'\"{s}\"' has no exported member named '{s}'. Did you mean '{s}'?", .{
                    l.atomText(module), l.atomText(name), l.atomText(sugg),
                });
                return;
            }
        }
        try l.diag(file, 2305, span, "Module '\"{s}\"' has no exported member '{s}'.", .{
            l.atomText(module), l.atomText(name),
        });
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
                        // Through `finalizeLocal` so `import X from "m"; export
                        // default X;` follows the chain to m's export rather
                        // than stopping at the local import binding.
                        try l.put(t, rec.exported, try l.finalizeLocal(file, rec.sym, rec.local, rec.type_only, 0));
                    } else {
                        try l.put(t, rec.exported, .{ .kind = .default_expr, .file = file, .payload = rec.node });
                    }
                },
                .reexport_named => {
                    const mfile = f.specs.get(rec.module) orelse {
                        try l.put(t, rec.exported, .{ .kind = .any });
                        continue; // 2307 reported statement-level
                    };
                    var found = try l.lookupExport(mfile, rec.local, 0);
                    // `export { X } from "m"` where `m` is `export = ns` reads
                    // the namespace member `ns.X`, exactly as `import { X }
                    // from "m"` does in `linkImports`. Without this arm the
                    // re-export form reported TS2305 where the import form
                    // resolved — and it fired on every re-export from a module
                    // ztsc loads as a synthetic opaque `any` (an allowJs `.js`
                    // entry, a `*.json`, an `exports`-blocked subpath), whose
                    // whole body is `declare const j: any; export = j;`. A
                    // module with an `export =` therefore degrades to `any`
                    // rather than accusing it of a missing member.
                    if (found == null) {
                        if (try l.lookupExport(mfile, l.atom_export_equals, 0)) |exeq| {
                            found = (try l.exportEqualsMember(exeq, rec.local)) orelse .{ .kind = .any };
                        }
                    }
                    if (found) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or rec.type_only;
                        try l.put(t, rec.exported, final);
                    } else {
                        try l.diagNoExportedMember(file, mfile, rec.module, rec.local, l.nodeSpan(file, rec.node));
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
                .equals => {
                    // `export = <entity>`: resolve the named local and store it
                    // under the reserved `export=` key. A bare/non-identifier
                    // entity stays lenient (`any`).
                    var tgt: Target = .{ .kind = .any };
                    if (rec.local != 0) {
                        if (f.bind.lookupInScope(binder.file_scope, rec.local)) |ls| {
                            tgt = try l.finalizeLocal(file, ls, rec.local, false, 0);
                        }
                    }
                    try l.put(t, l.atom_export_equals, tgt);
                    // TS2309: `export =` cannot coexist with a value export.
                    try l.reportExportAssignMixing(file, rec.node);
                },
            }
        }

        // Pass 2: `export *` star merges (never `default`; first wins).
        for (f.bind.exports) |rec| {
            if (rec.kind != .reexport_all) continue;
            const mfile = f.specs.get(rec.module) orelse continue;
            if (mfile == file) continue;
            const mt = try l.table(mfile);
            for (mt.keys(), mt.values()) |name, tgt| {
                if (name == l.atom_default or name == l.atom_export_equals) continue;
                if (t.contains(name)) continue;
                var final = tgt;
                final.type_only = final.type_only or rec.type_only;
                try t.put(l.scratch, name, final);
            }
        }

        l.state[file] = 2;
        return t;
    }

    /// TS2309: `export =` may not coexist with any *value* export in the same
    /// module (type-only exports — interfaces, `export type` — are allowed).
    /// Emitted at the `export =` statement. Under-reports exotic mixings
    /// (re-exports) to stay clear of false positives.
    fn reportExportAssignMixing(l: *Linker, file: FileId, node: ast.Node) Error!void {
        const b = l.files[file].bind;
        for (b.exports) |other| {
            const is_value = switch (other.kind) {
                .default => true,
                .named => other.module == 0 and other.sym != binder.no_symbol and
                    b.symbol_flags[other.sym].hasValue(),
                else => false,
            };
            if (!is_value) continue;
            try l.diag(file, 2309, l.nodeSpan(file, node), "An export assignment cannot be used in a module with other exported elements.", .{});
            return;
        }
    }

    /// The `export = X` entity of a known module (on-disk file first, then an
    /// ambient `declare module "spec" { export = … }`), or null if the module
    /// has no export assignment.
    fn lookupExportEquals(l: *Linker, mfile_opt: ?FileId, module: Atom) Error!?Target {
        if (mfile_opt) |mfile| {
            if (try l.lookupExport(mfile, l.atom_export_equals, 0)) |t| return t;
        }
        return l.lookupAmbient(module, l.atom_export_equals);
    }

    /// Resolve member `name` against an `export = <entity>` target `exeq`, per
    /// the TS rule that `import { name } from "m"` (m is `export = ns`) binds to
    /// `ns.name`. Two container shapes are handled: a namespace/value `.binding`
    /// (look the name up in the symbol's namespace body scope, then finalize the
    /// member local so a re-exported member follows its chain) and a whole
    /// module-namespace object `.namespace` (look the name up in that module's
    /// export table). Returns null for any other shape or a missing member, so
    /// the caller keeps its lenient `any` fallback. Order-invariant: reads only
    /// sealed per-file bind data + already-built export tables.
    fn exportEqualsMember(l: *Linker, exeq: Target, name: Atom) Error!?Target {
        switch (exeq.kind) {
            .binding => {
                const b = l.files[exeq.file].bind;
                const ns_scope = b.namespaceScopeOf(exeq.payload) orelse return null;
                const member_local = b.lookupInScope(ns_scope, name) orelse return null;
                var t = try l.finalizeLocal(exeq.file, member_local, name, exeq.type_only, 0);
                t.type_only = t.type_only or exeq.type_only;
                return t;
            },
            .namespace => {
                if (try l.lookupExport(exeq.file, name, 0)) |t| {
                    var final = t;
                    final.type_only = final.type_only or exeq.type_only;
                    return final;
                }
                return null;
            },
            else => return null,
        }
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
                .equals => {
                    // `import x = require("m"); export = x;` — follow the chain to
                    // m's `export =` entity (else the module namespace object).
                    if (try l.lookupExport(mfile, l.atom_export_equals, depth + 1)) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or t_only;
                        return final;
                    }
                    return .{ .kind = .namespace, .file = mfile, .type_only = t_only };
                },
                .side_effect => break,
            }
        }
        return .{ .kind = .any };
    }

    /// Populate the ambient/augmentation registry from every file's
    /// `declare module "spec" { … }` blocks. Each block's `export`ed
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
                // tsc's ambient-module auto-export: a `declare module` block with
                // NO explicit `export` anywhere implicitly exports every one of
                // its top-level members (@types/leaflet-draw's `declare module
                // "leaflet" { namespace DrawEvents … }` carries no `export`, yet
                // `import { DrawEvents } from "leaflet"` resolves). When the block
                // DOES use an explicit export, only the exported members leak —
                // matching the value-augment path (`appendAugmentedModuleExports`)
                // which folds bare-declared members like `const drawLocal` in.
                var has_explicit = am.export_end != am.export_start;
                if (!has_explicit) {
                    for (lo..hi) |i| {
                        if (b.symbol_flags[b.member_syms[i]].exported) {
                            has_explicit = true;
                            break;
                        }
                    }
                }
                for (lo..hi) |i| {
                    const local = b.member_syms[i];
                    const fl = b.symbol_flags[local];
                    if (fl.export_default) continue;
                    if (has_explicit and !fl.exported) continue;
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
                        .equals => {
                            // `declare module "m" { export = X }`: store the
                            // export entity under the reserved key. Makes the
                            // module non-opaque so imports resolve through it.
                            if (tbl.contains(l.atom_export_equals)) continue;
                            var tgt: Target = .{ .kind = .any };
                            if (rec.local != 0) {
                                if (b.lookupInScope(am.scope, rec.local)) |ls| {
                                    tgt = try l.finalizeLocal(fid, ls, rec.local, false, 0);
                                }
                            }
                            try tbl.put(l.scratch, l.atom_export_equals, tgt);
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

    /// The file backing specifier `spec` in `f`, with tsc's ambient-module
    /// precedence applied.
    ///
    /// tsc's `resolveExternalModuleNameWorker` looks a NON-RELATIVE specifier
    /// up in the globals as an exactly-named ambient module (`declare module
    /// "png-chunks-extract"`) BEFORE it consults the resolved file; only
    /// *pattern* ambient modules (`declare module "*.css"`) are consulted
    /// after resolution fails. ztsc resolves file-first, which is right when
    /// the resolved file is itself a module — `declare module "x"` inside a
    /// module file is an *augmentation*, and must merge into the module it
    /// names rather than replace it. It is wrong in the two cases below, and
    /// the precedence flip is scoped to exactly those, so no augmentation can
    /// be turned into a replacement.
    ///
    /// 1. A SYNTHETIC opaque `any` module. Under `allowJs` a JS-only
    ///    dependency loads as `declare const j: any; export = j;`
    ///    (`paths.js_module_source`), and that placeholder `export =` answered
    ///    the import before the real ambient block declaring the package.
    ///
    /// 2. A resolved file that is a *script*, not a module (`bind.is_module`
    ///    false: no top-level import/export). `open-color` is the shape — its
    ///    `"types"` points at `open-color.d.ts`, whose entire content is a
    ///    global `declare module 'open-color' { … }` block. Resolving it made
    ///    the specifier "known" while the file itself declared no module, and
    ///    the block's own `export default` record leaked into the file's export
    ///    table as a target that types `any`. A script has no module exports to
    ///    augment, so preferring the declaration loses nothing; it is also
    ///    exactly what tsc does, since a script's symbol is not a module symbol
    ///    for `resolveExternalModuleName` to return.
    ///
    /// Both are keyed on an EXACT ambient name; a pattern module
    /// (`declare module "*.css"`) is left where tsc puts it, after resolution.
    fn effectiveModuleFile(l: *Linker, f: *const ProgFile, spec: Atom) Error!?FileId {
        const mfile = f.specs.get(spec) orelse return null;
        if (!l.ambient.contains(spec)) return mfile;
        if (paths.anyModuleSourceFor(l.files[mfile].path) != null) return null;
        if (!l.files[mfile].bind.is_module) return null;
        return mfile;
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
    /// name, else the best-matching wildcard pattern (`declare module
    /// "*.css"`). Returns null when no ambient module covers the specifier.
    ///
    /// "Best" is tsc's `findBestPatternMatch`: among the patterns that match,
    /// the one with the LONGEST prefix, first declaration winning a tie. Taking
    /// the first match instead gave `prefix-*` a specifier that
    /// `prefix-deep-*` was written for; vite's `client.d.ts` alone declares
    /// forty overlapping patterns (`*?worker` / `*?worker&inline`, `*.css` /
    /// `*.module.css`), so the distinction is not hypothetical.
    fn ambientKey(l: *Linker, spec: Atom) ?Atom {
        if (l.ambient.contains(spec)) return spec;
        const text = l.atomText(spec);
        var best: ?Atom = null;
        var best_prefix: usize = 0;
        for (l.ambient.keys()) |pat_atom| {
            const pat = l.atomText(pat_atom);
            const star = std.mem.indexOfScalar(u8, pat, '*') orelse continue;
            const prefix = pat[0..star];
            const suffix = pat[star + 1 ..];
            if (text.len < prefix.len + suffix.len) continue;
            if (!std.mem.startsWith(u8, text, prefix)) continue;
            if (!std.mem.endsWith(u8, text, suffix)) continue;
            if (best == null or prefix.len > best_prefix) {
                best = pat_atom;
                best_prefix = prefix.len;
            }
        }
        return best;
    }

    /// TS2307 for unresolved module specifiers, one per statement. A
    /// side-effect-only import (`import "./x"`) of an unresolved module gets
    /// TS2882 instead — TS7 flags these (tsc 5.5 left them silent under
    /// bundler resolution).
    ///
    /// The same walk carries TS7016 for the module that resolved but has no
    /// declarations behind it — see `untypedJsModule`.
    fn reportUnresolvedModules(l: *Linker, file: FileId) Error!void {
        const f = &l.files[file];
        const tree = f.tree;
        for (tree.nodeRange(0)) |stmt| {
            if (stmt == ast.null_node) continue;
            const tag = tree.nodeTag(stmt);
            if (tag != .import_decl and tag != .export_named and tag != .export_all and tag != .import_equals) continue;
            var side_effect = false;
            var mod_tok: ast.TokenIndex = tree.nodeData(stmt).rhs;
            if (tag == .import_decl) {
                const data = tree.extraData(ast.ImportData, tree.nodeData(stmt).lhs);
                side_effect = data.default_name_token == 0 and data.ns_name_token == 0 and
                    data.spec_start == data.spec_end;
            } else if (tag == .import_equals) {
                // `import x = require("m")`: the specifier is in the extra data.
                mod_tok = tree.extraData(ast.ImportEquals, tree.nodeData(stmt).lhs).module_token;
            }
            if (mod_tok == 0) continue;
            const text = tree.tokenSlice(f.src, mod_tok);
            const stripped = stripQuotes(text);
            if (stripped.len == 0) continue;
            const atom = l.interner.intern(l.io, l.gpa, stripped) catch return Error.OutOfMemory;
            if (try l.effectiveModuleFile(f, atom)) |mfile| {
                // Resolved. The one thing left to say about it: a dependency
                // that turned out to be plain JavaScript has no types, and
                // under `noImplicitAny` that is an error at the specifier.
                if (l.no_implicit_any and !side_effect and untypedJsModule(l.files[mfile].path)) {
                    try l.diag(file, 7016, l.tokSpan(file, mod_tok), "Could not find a declaration file for module '{s}'. '{s}' implicitly has an 'any' type.", .{ stripped, l.files[mfile].path });
                }
                continue;
            }
            if (l.hasAmbient(atom)) continue; // resolved by a `declare module`
            if (side_effect) {
                try l.diag(file, 2882, l.tokSpan(file, mod_tok), "Cannot find module or type declarations for side-effect import of '{s}'.", .{stripped});
            } else {
                try l.diag(file, 2307, l.tokSpan(file, mod_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{stripped});
            }
        }
    }

    /// TS1202 / TS1203: `import x = require(...)` / `export = ...` are emit
    /// constructs illegal when targeting ECMAScript modules (the harness and
    /// ztsc both use `module: esnext`). Reported only for non-declaration files
    /// (a `.d.ts` never emits), at the statement, matching tsgo. Entity-name
    /// aliases (`import A = B.C`) are not emit constructs and stay silent.
    fn reportModuleGrammar(l: *Linker, file: FileId) Error!void {
        const f = &l.files[file];
        if (paths.isDeclarationPath(f.path)) return;
        // Resolved JSON/JS any-modules carry a synthetic `export = any` body
        // (never emitted); the grammar rule that bans `export =` under ESM does
        // not apply to them.
        if (paths.anyModuleSourceFor(f.path) != null) return;
        const tree = f.tree;
        for (tree.nodeRange(0)) |stmt| {
            if (stmt == ast.null_node) continue;
            switch (tree.nodeTag(stmt)) {
                .import_equals => {
                    const e = tree.extraData(ast.ImportEquals, tree.nodeData(stmt).lhs);
                    if (e.module_token != 0) {
                        try l.diag(file, 1202, l.nodeSpan(file, stmt), "Import assignment cannot be used when targeting ECMAScript modules. Consider using 'import * as ns from \"mod\"', 'import {{a}} from \"mod\"', 'import d from \"mod\"', or another module format instead.", .{});
                    }
                },
                .export_assign => try l.diag(file, 1203, l.nodeSpan(file, stmt), "Export assignment cannot be used when targeting ECMAScript modules. Consider using 'export default' or another module format instead.", .{}),
                else => {},
            }
        }
    }

    /// Link one file's import bindings. A named/default import resolves first
    /// against the on-disk module (if the specifier resolved to a file), then
    /// against an ambient/augmentation module of the same specifier, so
    /// `declare module "spec"` supplies exports for an unresolved specifier and
    /// augments a resolved one — except when the resolved "file" is a synthetic
    /// opaque `any` module, where an exactly-named ambient declaration wins
    /// (see `effectiveModuleFile`). Diagnostics fire only when the module is known
    /// (a real file or an ambient declaration); a wholly unknown specifier is
    /// left to `reportUnresolvedModules` (TS2307).
    fn linkImports(l: *Linker, file: FileId, locals: *std.ArrayList(u32), targets: *std.ArrayList(Target)) Error!void {
        const f = &l.files[file];
        for (f.bind.imports) |rec| {
            if (rec.kind == .side_effect) continue;
            const local_sym = f.bind.lookupInScope(binder.file_scope, rec.local) orelse continue;
            var tgt: Target = .{ .kind = .any };
            const mfile_opt = try l.effectiveModuleFile(f, rec.module);
            const known = mfile_opt != null or l.hasAmbient(rec.module);
            if (known) {
                const exeq = try l.lookupExportEquals(mfile_opt, rec.module);
                switch (rec.kind) {
                    .equals => {
                        // `import x = require("m")`: the whole `export =` entity
                        // (value + type + namespace). Against a plain module it is
                        // the module namespace object.
                        if (exeq) |ee| {
                            tgt = ee;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (mfile_opt) |mfile| {
                            tgt = .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only };
                        } else if (!l.ambientOpaque(rec.module)) {
                            if (l.ambientKey(rec.module)) |key| {
                                tgt = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?), .type_only = rec.type_only };
                            }
                        }
                    },
                    .namespace => {
                        // A namespace import of an `export =` module reaches the
                        // export entity (so `ns.member` works); leniently keeps
                        // its call signature (tsgo strips it — a documented
                        // under-report of TS2349 on `ns()`).
                        if (exeq) |ee| {
                            tgt = ee;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (mfile_opt) |mfile| {
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
                        if (found == null) {
                            // `import { X } from "m"` where `m` is `export = ns`
                            // (a namespace): X binds to the namespace member
                            // `ns.X` (TS semantics). jest-dom augments jest's
                            // `Matchers` via `extends TestingLibraryMatchers`,
                            // an interface imported this way from an `export =`
                            // module — without member resolution the heritage
                            // base degrades to `any` and its matchers vanish.
                            if (exeq) |ee| found = try l.exportEqualsMember(ee, rec.imported);
                        }
                        if (found) |ff| {
                            tgt = ff;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (exeq != null or (mfile_opt == null and l.ambientOpaque(rec.module))) {
                            // A named import of an `export =` (or out-of-subset
                            // auto-export) module degrades to `any`, no spurious
                            // TS2305.
                            tgt = .{ .kind = .any };
                        } else {
                            try l.diagNoExportedMember(file, mfile_opt, rec.module, rec.imported, l.nodeSpan(file, rec.node));
                        }
                    },
                    .default => {
                        var found: ?Target = null;
                        if (mfile_opt) |mfile| found = try l.lookupExport(mfile, l.atom_default, 0);
                        if (found == null) found = l.lookupAmbient(rec.module, l.atom_default);
                        // Under `module: esnext`, a default import of an
                        // `export =` module binds to the export entity (verified
                        // against tsgo).
                        if (found == null) found = exeq;
                        if (found) |ff| {
                            tgt = ff;
                            tgt.type_only = tgt.type_only or rec.type_only;
                        } else if (l.allow_synthetic_default and mfile_opt != null and
                            paths.isDeclarationPath(l.files[mfile_opt.?].path))
                        {
                            // allowSyntheticDefaultImports/esModuleInterop: a
                            // default import of a module that has no default
                            // export binds to the module namespace object (tsc's
                            // synthesized default). `export =` is already handled
                            // above (via `exeq`); this covers the ES-module /
                            // `export as namespace` shape (`import L from
                            // "leaflet"` → the leaflet namespace object).
                            //
                            // Only a DECLARATION file gets the synthesized
                            // default, mirroring tsc's `canHaveSyntheticDefault`:
                            // a `.d.ts` describes a module whose runtime shape is
                            // unknown, so the default may exist at runtime. A real
                            // source file in the program that carries ES-module
                            // syntax is known not to have one, and tsc reports
                            // TS1192/TS2613 there whatever the flag says
                            // (conformance modules/11, modules/25).
                            tgt = .{ .kind = .namespace, .file = mfile_opt.?, .type_only = rec.type_only };
                        } else if (mfile_opt == null and l.ambientOpaque(rec.module)) {
                            // `export =`-shaped ambient module: the CommonJS
                            // export-assignment *is* the default under interop.
                            tgt = .{ .kind = .any };
                        } else if (l.allow_synthetic_default and mfile_opt == null and
                            l.ambientKey(rec.module) != null)
                        {
                            // Same synthesized default, for a specifier served
                            // by an ambient `declare module "m"` block with real
                            // named exports rather than by a resolved file. Such
                            // a block only ever appears in a declaration file, so
                            // it always satisfies tsc's `canHaveSyntheticDefault`
                            // — the runtime shape is unknown and the default may
                            // exist. `@types/node` declares `fs`, `util`,
                            // `crypto`, … this way (unlike `path`, which is
                            // `export =` and is handled by `exeq` above), so
                            // without this a plain `import fs from "fs"` reported
                            // TS1192 under `esModuleInterop`.
                            const key = l.ambientKey(rec.module).?;
                            tgt = .{
                                .kind = .ambient_ns,
                                .payload = @intCast(l.ambient.getIndex(key).?),
                                .type_only = rec.type_only,
                            };
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

/// True for a program path that is a JavaScript file pulled out of
/// `node_modules` — a dependency ztsc resolved but that ships no declarations,
/// loaded as the opaque `any` body `paths.js_module_source`. Two ways in: a
/// package whose `main` is only `.js` under `allowJs`, and (whatever `allowJs`
/// says) the JavaScript an `exports` map names when nothing behind the map
/// declares types.
///
/// This is the TS7016 predicate. The `node_modules` clause is tsc's
/// `isExternalLibraryImport` — a JS file from a dependency is never added to
/// the program, so its module has no symbol and tsc errors at the specifier,
/// whereas a project-local `./x.js` IS added and stays silent. The other
/// synthetic any-modules are deliberately excluded: a `*.json` resolved by
/// `resolveJsonModule` is a legal resolution (tsc types it structurally, ztsc
/// opaquely — an under-report, not an error), and an `exports`-blocked subpath
/// is tsc's TS2307, a different diagnostic ztsc under-reports on purpose.
fn untypedJsModule(path: []const u8) bool {
    return paths.isJsModulePath(path) and paths.isInNodeModules(path);
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
        if (text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
        return text[1..];
    }
    return text;
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
