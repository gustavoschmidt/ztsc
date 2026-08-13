//! The program: module graph, cross-file symbol linking, global merge.
//!
//! This is where a program is BUILT: the two ways in (the parallel driver in
//! driver.zig calls `link` directly; `buildProgram` is the serial wavefront the
//! tests and tools use) and the linker underneath them. The data contract they
//! fill in — `FileId`, `Program`, `ProgFile`, `Target` — is program.zig, and
//! re-exported here, so `modules.Program` still names it. Specifier resolution
//! lives in resolve.zig, `package.json` reading in package_json.zig,
//! triple-slash directives in references.zig, the embedded libs in libs.zig,
//! and the lexical path helpers in paths.zig.
//!
//! Design decisions:
//!
//! - **Nonexistent module → TS2307** at the module-specifier string of the
//!   import/export statement (one per statement) — except a Node core module,
//!   whose absence tsc blames on a missing `@types/node` (TS2591, worded as a
//!   *name*). A module that resolved but turned out to be undeclared
//!   JavaScript from `node_modules` gets TS7016 at the same anchor, under
//!   `noImplicitAny`.
//! - **Unresolvable `/// <reference types="X" />` → TS2688** at the directive's
//!   name. Resolution happens during discovery, so the misses arrive on
//!   `ProgFile.type_ref_misses` and the linker only replays them.
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
//! - **A global `declare module "spec"` outranks the file the resolver found**
//!   for the same non-relative specifier (`applyAmbientModulePrecedence`,
//!   tsc's `tryFindAmbientModule` ahead of `getResolvedModule`). The file is
//!   still loaded — it is a program root either way — it just never answers an
//!   import. Pattern modules (`declare module "*.css"`) stay behind resolution.
//! - Checkers treat the sealed tables as read-only: no locks anywhere on
//!   the check path (the immutability boundary).
//! - Out of subset (documented): `export =` / `import x = require(...)`
//!   (parser flags them unsupported), ambient `declare module "..."`
//!   blocks, CommonJS interop semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const parser = @import("../frontend/parser.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const paths = @import("paths.zig");
const resolve = @import("resolve.zig");
// Only for `Discovery.paths_map` (the tsconfig `paths` table). tsconfig.zig
// imports this file back, but only inside a test, so the cycle is inert.
const tsconfig = @import("../tsconfig.zig");

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

// The immutable data contract — every type the checkers read back — lives in
// program.zig. This file is its other half: the code that FILLS those tables
// in. Re-exported wholesale, so `modules.Program`, `modules.FileId`, … keep
// naming exactly what they always did and no consumer moved.
const program = @import("program.zig");

pub const Error = program.Error;
pub const FileId = program.FileId;
pub const no_file = program.no_file;
pub const LinkOpts = program.LinkOpts;
pub const LinkResult = program.LinkResult;
pub const Program = program.Program;
pub const ProgFile = program.ProgFile;
pub const TypeRefMiss = program.TypeRefMiss;
pub const typeRefMiss = program.typeRefMiss;
pub const FileLinks = program.FileLinks;
pub const Target = program.Target;
pub const DualTarget = program.DualTarget;
pub const LinkDiag = program.LinkDiag;
pub const SpecMap = program.SpecMap;
pub const Globals = program.Globals;
pub const MergedSym = program.MergedSym;
pub const AmbientExport = program.AmbientExport;

// ===========================================================================
// program construction & linking
// ===========================================================================

/// Serial wavefront: load, parse, bind and resolve transitively from
/// `entries` (paths relative to `dir`), then link. Everything lives in
/// `arena`.
///
/// Tests and tools only — the CLI runs driver.zig's parallel pipeline. Every
/// decision about WHICH files a program contains is now literally the same
/// code in both: the per-FILE half of discovery, the seeding of the lib shards
/// and of the (canonicalized) entry paths, and the `@types/node`
/// auto-injection — all `Discovery` below.
///
/// What is still two implementations is the SCHEDULING half, and deliberately
/// so: this walks one pending list in one thread and assigns ids in discovery
/// order, while the driver front-ends files on a worker pool and re-derives
/// the ids from the import graph afterwards.
///
/// TODO: file ORDER is the last shared-by-convention piece. The driver seeds
/// the auto-included `@types/*` roots as a second BFS wave and renumbers
/// everything by the import graph; this assigns ids in pending order and has
/// no wave split, so a program with a `declare global` merge can still see a
/// different last-writer here than the CLI does. Sharing it means giving this
/// path the driver's renumbering, not a third ordering rule.
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

    // Discovery, shared verbatim with the parallel driver: the lib/root
    // seeding, the per-file specifier resolution, and the auto-injections.
    // `pending` IS the discovery order here, so it doubles as the shared
    // `paths` list.
    const disco: Discovery = .{
        .arena = arena,
        .store = scratch,
        .seen_alloc = scratch,
        .scratch = scratch,
        .io = io,
        .dir = dir,
        .interner = interner,
        .rcache = &rcache,
        .paths = &pending,
        .path_ids = &path_ids,
    };

    try disco.seedLibs(lib_set);
    for (entries) |e| _ = try disco.seedEntry(e);

    var jsx_runtime_fid: FileId = no_file;
    // Set once `@types/node` is in the program; until then every file that
    // imports a Node built-in asks for it (see `discoverNodeTypes`).
    var node_types_fid: ?FileId = null;
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
        tree.* = try parser.parseOpts(arena, bytes, .{
            .jsx = parser.isJsxPath(path),
            .dts = parser.isDeclarationPath(path),
            .experimental_decorators = link_opts.experimental_decorators,
        });
        const bound = try arena.create(Bind);
        bound.* = try binder.bind(arena, io, gpa, interner, tree, bytes, parser.isDeclarationPath(path));

        // Automatic JSX runtime: `<jsxImportSource>/jsx-runtime` exports the
        // `JSX` namespace (no global one exists under @types/react 19), so it is
        // a program input for every JSX file. Injected once, like a
        // triple-slash reference.
        if (jsx_runtime_fid == no_file and jsx_runtime_module != null and
            std.mem.endsWith(u8, path, ".tsx"))
        {
            if (try disco.discoverModule(path, jsx_runtime_module.?)) |jf| jsx_runtime_fid = jf;
        }

        // Triple-slash `/// <reference>` directives pull extra files into the
        // program — not import bindings, just program inputs.
        var type_ref_misses: std.ArrayList(TypeRefMiss) = .empty;
        for (try resolve.scanReferences(scratch, bytes)) |ref| {
            const rfid = try disco.discoverReference(path, ref);
            if (rfid == no_file and ref.kind == .types) {
                try type_ref_misses.append(arena, typeRefMiss(ref));
            }
        }

        // Resolve this file's specifiers; discover new files.
        var spec_atoms: std.ArrayList(Atom) = .empty;
        var spec_files: std.ArrayList(FileId) = .empty;
        var seen: std.AutoHashMapUnmanaged(Atom, void) = .empty;
        try disco.fileSpecs(path, bound, &seen, &spec_atoms, &spec_files);
        // Pull `@types/node` in on the first Node built-in import, exactly as
        // the CLI driver does, so its ambient `declare module "fs"` blocks
        // register and those specifiers resolve.
        if (node_types_fid == null) node_types_fid = try disco.discoverNodeTypes(path, bound);
        sortSpecPairs(spec_atoms.items, spec_files.items);

        try files.append(arena, .{
            .path = path,
            .src = bytes,
            .tree = tree,
            .bind = bound,
            .specs = .{
                .atoms = try arena.dupe(Atom, spec_atoms.items),
                .files = try arena.dupe(FileId, spec_files.items),
            },
            .type_ref_misses = try type_ref_misses.toOwnedSlice(arena),
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
            .dual_targets = lr.dual_targets,
            .types_wildcard = link_opts.types_wildcard,
            .experimental_decorators = link_opts.experimental_decorators,
            .jsx_runtime_file = jsx_runtime_fid,
        },
        .load_failures = try arena.dupe(BuildDiag, failures.items),
    };
}

/// Build the sealed per-file link tables and the merged global table. Serial;
/// results live in `arena`.
///
/// **`files` is mutated.** It is taken as `[]ProgFile`, not `[]const`, because
/// `applyAmbientModulePrecedence` rewrites `f.specs.files`: a specifier claimed
/// by a global `declare module "spec"` has its resolved FileId cleared, so
/// every consumer downstream reads the ambient module rather than the file the
/// resolver found. The patch replaces the slice (the original array is left
/// alone) and is the only write; after `link` returns, the program is immutable
/// and shared lock-free by the checkers.
pub fn link(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []ProgFile,
    link_opts: LinkOpts,
) Error!LinkResult {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    // tsc looks a non-relative specifier up in the ambient module declarations
    // BEFORE it consults the resolved file; apply that precedence once, up
    // front, so every specifier consumer downstream agrees on the answer.
    try applyAmbientModulePrecedence(arena, scratch, io, interner, files);

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
        .no_unchecked_side_effect_imports = link_opts.no_unchecked_side_effect_imports,
        .types_wildcard = link_opts.types_wildcard,
        .atom_export_equals = interner.intern(io, gpa, "export=") catch return Error.OutOfMemory,
        .state = try scratch.alloc(Linker.TableState, files.len),
        .tables = try scratch.alloc(std.AutoArrayHashMapUnmanaged(Atom, Target), files.len),
        .diags = try scratch.alloc(std.ArrayList(LinkDiag), files.len),
    };
    @memset(l.state, .unvisited);
    for (l.tables) |*t| t.* = .empty;
    for (l.diags) |*d| d.* = .empty;

    // Group the `declare module "spec"` blocks by the file they augment; the
    // export tables fold each block's new declarations in.
    try l.indexAugmentations();
    // Build every export table (deterministic file order).
    for (0..files.len) |i| _ = try l.table(@intCast(i));
    // Then the ambient/augmentation module registry, which import
    // resolution and TS2307 suppression consult below.
    try l.buildAmbient();
    // Only now can a file's `export * from "spec"` whose `spec` is an ambient
    // module (`@types/fs-extra`'s `export * from "fs"`) merge: its source names
    // did not exist while the file tables were being built.
    try l.starMergeFilesFromAmbient();
    // With every export table final, the re-exports that could not find their
    // name in a still-growing one get their answer — and their diagnostic.
    try l.resolvePendingReexports();

    const out = try arena.alloc(FileLinks, files.len);
    for (0..files.len) |i| {
        const fid: FileId = @intCast(i);
        try l.reportUnresolvedTypeRefs(fid);
        try l.reportUnresolvedModules(fid);
        try l.reportModuleGrammar(fid);

        const imports = try l.linkImports(fid);
        try sortByKeyU32(scratch, imports.locals, imports.targets);

        // Seal the export table sorted by atom.
        const t = &l.tables[i];
        const n = t.count();
        const atoms = try arena.alloc(Atom, n);
        const etargets = try arena.alloc(Target, n);
        @memcpy(atoms, t.keys());
        @memcpy(etargets, t.values());
        try sortByKeyU32(scratch, atoms, etargets);

        out[i] = .{
            .import_locals = try arena.dupe(u32, imports.locals),
            .import_targets = try arena.dupe(Target, imports.targets),
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

    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .ambient_exports = amb, .ambient_specs = amb_specs, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals, .export_equals_atom = l.atom_export_equals, .dual_targets = try arena.dupe(DualTarget, l.duals.items) };
}

/// Give a globally declared ambient module precedence over the file the
/// resolver found for the same specifier — tsc's `resolveExternalModuleName`,
/// whose FIRST act on a non-relative specifier is
/// `tryFindAmbientModule(name, /*withAugmentations*/ true)`: an exactly-named
/// `declare module "name"` living in `globals` is returned outright and the
/// resolved file is never even looked at. Only *pattern* modules (`declare
/// module "*.css"`) are consulted after resolution, which is where ztsc's
/// `ambientKey` fallback already puts them.
///
/// Resolution itself must stay file-first: tsc loads that file into the program
/// too (module resolution and symbol resolution are separate passes), it merely
/// never binds an import to it. So the precedence is applied here instead, by
/// clearing the resolved `FileId` out of every `SpecMap` entry an ambient module
/// claims. Every consumer — the linker's export/import tables and the checker's
/// `import("…")` / `require("…")` paths alike — reads through `SpecMap.get`, so
/// one edit here is the single `resolveExternalModuleName` tsc has, rather than
/// a precedence check bolted onto each call site.
///
/// **Only a `declare module "spec"` in a file that is itself a SCRIPT counts.**
/// The same block inside a MODULE file is a module *augmentation* (tsc's
/// `isModuleAugmentationExternal`); it is declared into that file's locals, never
/// into `globals`, and must merge into the module it names instead of replacing
/// it. Without that guard an app's own `declare module "react" { interface
/// CSSProperties … }` would make every `import … from "react"` resolve to the
/// augmentation's two-entry table.
///
/// outline is what this is for. `@types/yazl`'s `index.d.ts` does `import {
/// Buffer } from "buffer"`, and because it sits inside `node_modules` the node
/// walk finds a real package there — the browser polyfill `node_modules/buffer`,
/// a module exporting its own unrelated `Buffer` class. Every other file in the
/// program means `@types/node`'s ambient `declare module "buffer"`, whose
/// `Buffer` is the merged global interface, so passing a plain `Buffer` to
/// `ZipFile.addBuffer` was TS2345 against a same-named stranger. tsc binds both
/// sides to the ambient module and sees one type.
fn applyAmbientModulePrecedence(
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    interner: *Interner,
    files: []ProgFile,
) Error!void {
    var claimed: std.AutoArrayHashMapUnmanaged(Atom, void) = .empty;
    defer claimed.deinit(scratch);
    for (files) |*f| {
        if (f.bind.is_module) continue; // augmentation, not a global declaration
        for (f.bind.ambient_modules) |am| {
            if (am.spec == 0) continue;
            const text = interner.lookup(io, am.spec);
            // A pattern module stays behind resolution (`ambientKey`), and a
            // relative name is not an ambient module at all — tsc's
            // `tryFindAmbientModule` bails on `isExternalModuleNameRelative`.
            if (std.mem.indexOfScalar(u8, text, '*') != null) continue;
            if (isRelativeSpecifier(text)) continue;
            try claimed.put(scratch, am.spec, {});
        }
    }
    if (claimed.count() == 0) return;
    for (files) |*f| {
        // Most files name no claimed specifier; only copy one whose map changes.
        var hit = false;
        for (f.specs.atoms, f.specs.files) |atom, fid| {
            if (fid != no_file and claimed.contains(atom)) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        const patched = try arena.dupe(FileId, f.specs.files);
        for (f.specs.atoms, patched) |atom, *fid| {
            if (fid.* != no_file and claimed.contains(atom)) fid.* = no_file;
        }
        f.specs.files = patched;
    }
}

/// tsc's `isExternalModuleNameRelative`: a specifier is relative when it starts
/// with `/`, `./` or `../` (`.` and `..` alone included).
fn isRelativeSpecifier(spec: []const u8) bool {
    if (spec.len == 0) return false;
    if (spec[0] == '/') return true;
    if (!std.mem.startsWith(u8, spec, ".")) return false;
    if (spec.len == 1) return true; // "."
    if (spec[1] == '/') return true; // "./…"
    if (spec[1] != '.') return false;
    return spec.len == 2 or spec[2] == '/'; // ".." / "../…"
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
        lib_tree.* = try parser.parseOpts(arena, lf.source, .{ .dts = true });
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

// ===========================================================================
// private implementation
// ===========================================================================

// ---------------------------------------------------------------------------
// cross-file global merge
// ---------------------------------------------------------------------------

/// Result of folding every file's global contributions. Internal: the sealed
/// `Program`/`LinkResult` carry these fields out, nothing else reads the
/// bundle.
const GlobalMerge = struct {
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

/// A `export { local as exported } from "module"` record whose `local` the
/// target module did not export *yet* — parked by `table` and settled by
/// `resolvePendingReexports` after the star merges.
const PendingReexport = struct {
    file: FileId,
    mfile: FileId,
    module: Atom,
    local: Atom,
    exported: Atom,
    node: ast.Node,
    type_only: bool,
};

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
    /// Effective `noUncheckedSideEffectImports`; gates TS2882 (see `LinkOpts`).
    no_unchecked_side_effect_imports: bool = false,
    /// Effective `types: ["*"]`; picks TS2580 over TS2591 (see `LinkOpts`).
    types_wildcard: bool = false,
    /// Reserved key under which a module's `export = X` target is stored in its
    /// export/ambient table (`export=` can never be a real export name). Skipped
    /// by the namespace-object builders and `export *` merge.
    atom_export_equals: Atom,
    /// Per-file export-table build state. `building` is what makes the
    /// re-export walk cycle-safe: a file that is asked for its table while its
    /// own is still being built gets the partial table back rather than
    /// recursing (see `table`).
    state: []TableState,
    tables: []std.AutoArrayHashMapUnmanaged(Atom, Target),
    diags: []std.ArrayList(LinkDiag),
    /// Ambient/augmentation module registry: specifier atom → export
    /// table (export-name atom → Target). Built from every file's
    /// `declare module "spec" { … }` blocks; imports of `"spec"` resolve
    /// against it (after the on-disk module, so it augments a real module).
    ambient: std.AutoArrayHashMapUnmanaged(Atom, std.AutoArrayHashMapUnmanaged(Atom, Target)) = .empty,
    /// Augmentation index, grouped by the file being augmented: the blocks
    /// `declare module "spec" { … }` whose `spec` resolves to that file, as
    /// (augmenting file, `bind.ambient_modules` index) pairs in FileId order.
    /// `aug_start` has files.len+1 prefix sums. Built by `indexAugmentations`
    /// before any export table, since `table` folds the blocks' new
    /// declarations into the augmented module's exports.
    aug_start: []u32 = &.{},
    aug_files: []FileId = &.{},
    aug_blocks: []u32 = &.{},
    /// Backing store for `.dual` targets (`Target.payload` indexes it).
    /// Append-only; sealed into the arena at the end of `link`.
    duals: std.ArrayListUnmanaged(DualTarget) = .empty,
    /// `export { X } from "m"` records whose `X` was not in m's export table
    /// when that table was built, in statement order. Their lookup — and their
    /// TS2305/TS2459/TS2724 — are settled by `resolvePendingReexports`, once
    /// every star merge has run. See the `reexport_named` arm of `table`.
    pending_reexports: std.ArrayListUnmanaged(PendingReexport) = .empty,

    /// One file's import table before it is sealed: parallel arrays of local
    /// import-binding symbol and resolved `Target`, scratch-owned and in
    /// statement order (the caller sorts them by key).
    const ImportLinks = struct { locals: []u32, targets: []Target };

    /// Export-table build state of one file. `building` and `done` answer the
    /// same way — the table pointer is stable and a cycle reads the partial
    /// table — but they are distinct so the state means something to a reader.
    const TableState = enum(u8) { unvisited, building, done };

    const visit_limit = 256;
    /// Fixed-point bound for the ambient `export *` merge (`starMergeAmbient`):
    /// a star chain longer than this stops growing rather than spinning.
    const star_rounds = 8;

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

    /// Emit TS2305, or TS2724 when the module has a close export name, or
    /// TS2459 when the module DECLARES the name at its top level and simply
    /// did not export it (tsc's `reportNonExportedMember`, which outranks the
    /// spelling suggestion — the name is spelled right, it is just private).
    fn diagNoExportedMember(l: *Linker, file: FileId, mfile_opt: ?FileId, module: Atom, name: Atom, span: Span) Error!void {
        if (mfile_opt) |mfile| {
            const mb = l.files[mfile].bind;
            if (mb.is_module) {
                if (mb.lookupInScope(binder.file_scope, name)) |local_sym| {
                    if (!mb.symbol_flags[local_sym].import_binding) {
                        try l.diag(file, 2459, span, "Module '\"{s}\"' declares '{s}' locally, but it is not exported.", .{
                            l.atomText(module), l.atomText(name),
                        });
                        return;
                    }
                }
            }
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

    /// Group every `declare module "spec" { … }` block by the *file* its
    /// specifier resolves to. Reads only sealed per-file bind data and the
    /// already-built specifier maps, so it runs before any export table.
    /// A block whose specifier resolves to no file (a standalone ambient
    /// module, a wildcard pattern) is not an augmentation of a real module and
    /// stays with the ambient registry.
    fn indexAugmentations(l: *Linker) Error!void {
        const n = l.files.len;
        const counts = try l.scratch.alloc(u32, n + 1);
        @memset(counts, 0);
        for (l.files) |*f| {
            if (!f.bind.is_module) continue;
            for (f.bind.ambient_modules) |am| {
                const mfile = f.specs.get(am.spec) orelse continue;
                counts[mfile] += 1;
            }
        }
        const start = try l.scratch.alloc(u32, n + 1);
        var acc: u32 = 0;
        for (0..n) |i| {
            start[i] = acc;
            acc += counts[i];
        }
        start[n] = acc;
        const fill = try l.scratch.alloc(u32, n);
        @memcpy(fill, start[0..n]);
        const afiles = try l.scratch.alloc(FileId, acc);
        const ablocks = try l.scratch.alloc(u32, acc);
        for (l.files, 0..) |*f, fi| {
            if (!f.bind.is_module) continue;
            for (f.bind.ambient_modules, 0..) |am, ai| {
                const mfile = f.specs.get(am.spec) orelse continue;
                afiles[fill[mfile]] = @intCast(fi);
                ablocks[fill[mfile]] = @intCast(ai);
                fill[mfile] += 1;
            }
        }
        l.aug_start = start;
        l.aug_files = afiles;
        l.aug_blocks = ablocks;
    }

    /// The flattened export table of `file` (built on demand, cycle-safe).
    fn table(l: *Linker, file: FileId) Error!*std.AutoArrayHashMapUnmanaged(Atom, Target) {
        if (l.state[file] != .unvisited) return &l.tables[file];
        l.state[file] = .building;
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
                            found = (try l.exportEqualsMeanings(exeq, rec.local)) orelse
                                .{ .kind = .any };
                        }
                    }
                    if (found) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or rec.type_only;
                        try l.put(t, rec.exported, final);
                    } else {
                        // Not "missing" yet — only missing FROM A TABLE THAT CAN
                        // STILL GROW. `m`'s own `export * from "<ambient
                        // module>"` merges after every file table exists
                        // (`starMergeFilesFromAmbient`), so a name that reaches
                        // `m` that way is not there to be found at this point,
                        // and reporting here accused `export { createWriteStream
                        // } from "fs-extra"` of a member the import form of the
                        // same name resolves. The lookup and the diagnostic both
                        // move to `resolvePendingReexports`, past the merge; the
                        // `any` keeps the name bound until then.
                        try l.pending_reexports.append(l.scratch, .{
                            .file = file,
                            .mfile = mfile,
                            .module = rec.module,
                            .local = rec.local,
                            .exported = rec.exported,
                            .node = rec.node,
                            .type_only = rec.type_only,
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
                // A namespace's own `export { … }` is a member of that
                // namespace, never an export of the module around it.
                .ns_named => {},
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
                    try l.reportExportAssignMixing(file, rec.node, rec.scope);
                },
            }
        }

        // Pass 2: `export *` star merges (never `default`; first wins).
        //
        // Only a star whose source is a RESOLVED FILE settles here. One whose
        // source is served by an ambient `declare module "spec"` block instead
        // (`export * from "fs"`) cannot: the registry those names live in is
        // built after every file table (`buildAmbient`), so it is empty at this
        // point. That half runs as a deferred pass — `starMergeFilesFromAmbient`.
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

        // Pass 3: a `declare module "spec" { … }` augmentation's declarations
        // are exports of the module `spec` resolves to. tsc merges the
        // augmentation block into the module symbol, so a name the block
        // *introduces* becomes importable from the module — `import type {
        // DebounceSettings } from "lodash"` reaches an interface that only
        // `@types/lodash/common/function.d.ts` declares, and an unqualified
        // reference from a sibling augmentation block resolves through the
        // same table.
        //
        // Strictly last, and only for names the module does not already
        // resolve — its own exports, its `export *` re-exports, and the
        // members of its `export = <namespace>`. A name the module DOES
        // resolve is a *merge*, not a new export, and belongs to
        // `mergeAugmentations`, which needs `exportTarget` to still answer
        // with the real declaration to have something to merge into.
        if (l.aug_start.len != 0) {
            const alo = l.aug_start[file];
            const ahi = l.aug_start[file + 1];
            for (l.aug_files[alo..ahi], l.aug_blocks[alo..ahi]) |afile, ai| {
                if (afile == file) continue;
                const ab = l.files[afile].bind;
                const am = ab.ambient_modules[ai];
                const lo = ab.scope_members_start[am.scope];
                const hi = ab.scope_members_start[am.scope + 1];
                for (lo..hi) |i| {
                    const local = ab.member_syms[i];
                    if (ab.symbol_flags[local].export_default) continue;
                    const name = ab.member_atoms[i];
                    if (t.contains(name)) continue;
                    if (try l.exportEqualsHasMember(t, name)) continue;
                    try l.put(t, name, try l.finalizeLocal(afile, local, name, false, 0));
                }
            }
        }

        l.state[file] = .done;
        return t;
    }

    /// TS2309: `export =` may not coexist with any *value* export in the same
    /// module (type-only exports — interfaces, `export type` — are allowed).
    /// Emitted at the `export =` statement. Under-reports exotic mixings
    /// (re-exports) to stay clear of false positives.
    ///
    /// "The same module" is the container the `export =` lives in, not the
    /// file: one `.d.ts` routinely holds several `declare module "…"` blocks,
    /// and `@types/node`'s `events.d.ts` — `export = EventEmitter` in one
    /// block, a plain `export { … }` in another — was reported twice by a
    /// file-wide scan.
    fn reportExportAssignMixing(l: *Linker, file: FileId, node: ast.Node, scope: u32) Error!void {
        const b = l.files[file].bind;
        for (b.exports) |other| {
            if (other.scope != scope) continue;
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
                // A member DECLARED in the namespace body, under its own name.
                if (b.lookupInScope(ns_scope, name)) |member_local| {
                    var t = try l.finalizeLocal(exeq.file, member_local, name, exeq.type_only, 0);
                    t.type_only = t.type_only or exeq.type_only;
                    return t;
                }
                // …or a member the body RE-EXPORTS under a different local name:
                // `namespace EE { export { internal as EventEmitter } }`. The
                // scope holds `internal`, not `EventEmitter`, so the name-keyed
                // lookup above misses it and the whole entity degraded to `any`
                // — which is how `import { EventEmitter } from "node:events"`
                // lost every method @types/node declares on it, and with it the
                // contextual signature of every listener callback written for
                // one (TS7006 on `chunk`, `err`, `code`, …). tsc reads a
                // namespace's `export { … }` statements as exports of the
                // namespace, exactly as it does for a `declare module` block —
                // which `buildAmbient` already handles for the block case.
                for (b.exports) |rec| {
                    if (rec.kind != .ns_named or rec.scope != ns_scope) continue;
                    if (rec.exported != name) continue;
                    // Resolve the LOCAL name (`internal`), not the exported one:
                    // `finalizeLocal` matches the import record that created the
                    // binding by its local atom.
                    const ls = if (rec.sym != binder.no_symbol)
                        rec.sym
                    else
                        b.lookupInScope(ns_scope, rec.local) orelse continue;
                    var t = try l.finalizeLocal(exeq.file, ls, rec.local, rec.type_only or exeq.type_only, 0);
                    t.type_only = t.type_only or exeq.type_only;
                    return t;
                }
                return null;
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

    /// True when the module whose (partially built) export table is `t`
    /// already reaches `name` through its `export = <entity>`. Keeps the
    /// augmentation pass from shadowing a name the export assignment owns.
    fn exportEqualsHasMember(l: *Linker, t: *std.AutoArrayHashMapUnmanaged(Atom, Target), name: Atom) Error!bool {
        const exeq = t.get(l.atom_export_equals) orelse return false;
        return (try l.exportEqualsMember(exeq, name)) != null;
    }

    /// `import { X } from "m"` / `export { X } from "m"` where `m` is `export =
    /// <value>` and `X` is not a member of the entity itself: tsc falls back to
    /// the *type* of the export-assigned value and takes property `X` off it.
    /// The link phase cannot evaluate a type, so it records the question —
    /// `.export_equals_prop` — and the checker answers it. Null when the export
    /// assignment is not a plain declaration binding (a whole namespace object,
    /// an unresolved entity), where there is no value symbol to ask about.
    fn exportEqualsProp(exeq: ?Target, name: Atom) ?Target {
        const e = exeq orelse return null;
        if (e.kind != .binding) return null;
        return .{ .kind = .export_equals_prop, .file = e.file, .payload = e.payload, .name = name, .type_only = e.type_only };
    }

    /// Both meanings of `name` against an `export = <entity>` module, combined
    /// the way tsc's `getExternalModuleMember` does: the member of the exported
    /// entity (`symbolFromModule`) and the property of the exported value's
    /// type (`symbolFromVariable`). When both are available they are folded
    /// into one `.dual` binding — tsc's `combineValueAndTypeSymbols`, which
    /// takes the type meaning from the member and the value meaning from the
    /// property. Only one available ⇒ that one; neither ⇒ null.
    ///
    /// This is superagent's shape: `declare const request: request.Static` +
    /// `declare namespace request { interface Request … }` + `export =
    /// request`, where `interface Request` is the type meaning of `import {
    /// Request }` and `Static.Request: typeof SARequest` is its value meaning.
    /// `@types/supertest`'s `declare class Test extends Request` needs the
    /// value meaning to have a base at all, and every `.expect(...)` chain in
    /// a consumer needs the base's members.
    fn exportEqualsMeanings(l: *Linker, exeq: ?Target, name: Atom) Error!?Target {
        const member = if (exeq) |ee| try l.exportEqualsMember(ee, name) else null;
        const prop = exportEqualsProp(exeq, name);
        const m = member orelse return prop;
        const p = prop orelse return m;
        try l.duals.append(l.scratch, .{ .value_tgt = p, .type_tgt = m });
        return .{
            .kind = .dual,
            .payload = @intCast(l.duals.items.len - 1),
            .name = name,
            .type_only = m.type_only,
        };
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
        // Find the import record that created this binding. Matched on scope
        // as well as name: a `declare module` block's imports are records too,
        // and one of them may shadow a file-scope name.
        for (f.bind.imports) |rec| {
            if (rec.local != local_atom) continue;
            if (rec.scope != f.bind.symbol_scopes[local_sym]) continue;
            const t_only = type_only or rec.type_only;
            // `import x = require("m"); export = x;` — and its ES twin
            // `import * as x from "m"; export { x };` — where "m" is an
            // AMBIENT module (no file behind it). The first is how every
            // `node:<mod>` alias in `@types/node` is written; the second is
            // how `fs.d.ts` re-exports `promises`. Both name the module
            // NAMESPACE OBJECT, so both resolve through the ambient registry
            // rather than the file graph; without this the alias — and every
            // member reached through it — degraded to `any`.
            //
            // The registry's key space is seeded before any table is filled
            // (`buildAmbient`), so the `.ambient_ns` payload is always
            // available here. The `export =` preference below is not: a block
            // processed after this one has not stored its `export =` entity
            // yet, and the namespace object is what we fall back to — the
            // same ordering caveat the `equals` form has always had.
            if ((rec.kind == .equals or rec.kind == .namespace) and f.specs.get(rec.module) == null) {
                const key = l.ambientKey(rec.module) orelse return .{ .kind = .any };
                var tgt: Target = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?), .type_only = t_only };
                if (l.ambient.getPtr(key).?.get(l.atom_export_equals)) |exeq| {
                    if (exeq.kind != .any) tgt = exeq;
                }
                tgt.type_only = tgt.type_only or t_only;
                return tgt;
            }
            const mfile = f.specs.get(rec.module) orelse return .{ .kind = .any };
            switch (rec.kind) {
                .namespace => return .{ .kind = .namespace, .file = mfile, .type_only = t_only },
                .named, .default => {
                    if (try l.lookupExport(mfile, rec.imported, depth + 1)) |tgt| {
                        var final = tgt;
                        final.type_only = final.type_only or t_only;
                        return final;
                    }
                    // The same `export = <entity>` fallbacks `linkImports` uses
                    // for a named import, so a re-export *chain* through such a
                    // module resolves too: `@types/lodash.debounce` is nothing
                    // but `import { debounce } from "lodash"; export =
                    // debounce;`, and without this the whole package was `any`.
                    if (try l.lookupExport(mfile, l.atom_export_equals, depth + 1)) |exeq| {
                        if (try l.exportEqualsMeanings(exeq, rec.imported)) |m| {
                            var final = m;
                            final.type_only = final.type_only or t_only;
                            return final;
                        }
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
        // Seed every specifier key first, so the registry's index space is
        // complete before any table is filled. `finalizeLocal` hands out
        // `.ambient_ns` payloads (registry indices) while filling, and a
        // `declare module "node:x" { import x = require("x"); export = x; }`
        // block may be reached before the `"x"` block it names.
        for (l.files) |*f| {
            for (f.bind.ambient_modules) |am| {
                const gop = try l.ambient.getOrPut(l.scratch, am.spec);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
            }
        }
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
                            // `rec.sym` is the binder's own resolution, which
                            // walks outward from the `export { … }` statement
                            // and consults the file's `global { … }` blocks;
                            // the block-scope lookup only sees the block's own
                            // members. `declare module "buffer" { global { var
                            // Buffer … } export { Buffer }; }` needs the former.
                            const ls = if (rec.sym != binder.no_symbol)
                                rec.sym
                            else
                                b.lookupInScope(am.scope, rec.local) orelse continue;
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
                        else => {}, // `export *`: second pass, below
                    }
                }
            }
        }

        try l.starMergeAmbient();
    }

    /// `export * from "other"` inside a `declare module "spec" { … }` block.
    ///
    /// The star's source is usually ANOTHER ambient module declared in the same
    /// `.d.ts`: `transformation-matrix`'s typings are one script holding a
    /// `declare module` per entry point plus a final `declare module
    /// 'transformation-matrix'` block that stars them all back into the package
    /// root — so `import { compose, identity } from 'transformation-matrix'`
    /// reaches names no block of that specifier declares itself. Without this
    /// every such name was TS2305.
    ///
    /// Runs after `buildAmbient` has placed every block's own members, so a
    /// star never races the block it names, and iterates so a chain of stars
    /// settles. Same rules as the file-level star merge: `default` and the
    /// reserved `export=` key are not re-exported, and the first contributor of
    /// a name wins (which keeps a block's own declaration ahead of a star's).
    /// Order-invariant: the fixed point does not depend on visit order, since
    /// every round only *adds* names no round could have taken differently.
    fn starMergeAmbient(l: *Linker) Error!void {
        // A specifier whose blocks declare NOTHING of their own — `declare
        // module "node:fs" { export * from "fs"; }`, which is how every
        // `node:` alias in `@types/node` that is not an `import … = require`
        // is written — used to be emptied again at the end of the fixed point,
        // so it could relay a star CHAIN but exported nothing itself and every
        // named import from it degraded to `any`. That was a deliberate
        // under-report held in place by checker gaps the `any` was hiding
        // (generic overload inference, well-known-symbol members) — gaps since
        // closed. The `any` cost real diagnostics: `import { ChildProcess }
        // from "node:child_process"` typed as `any`, so every `.on(event, cb)`
        // written for one reported TS7006 on the callback's parameters.
        //
        // A star re-export IS an export, so the merged table now stands.
        var round: u32 = 0;
        while (round < star_rounds) : (round += 1) {
            var changed = false;
            for (l.files) |*f| {
                for (f.bind.ambient_modules) |am| {
                    const dst_idx = l.ambient.getIndex(am.spec) orelse continue;
                    for (f.bind.exports[am.export_start..am.export_end]) |rec| {
                        if (rec.kind != .reexport_all) continue;
                        // tsc's precedence: for a non-relative specifier an
                        // exactly-named ambient module outranks the resolved
                        // file, which `effectiveModuleFile` already encodes.
                        if (try l.effectiveModuleFile(f, rec.module)) |mfile| {
                            const mt = try l.table(mfile);
                            for (mt.keys(), mt.values()) |name, tgt| {
                                if (try l.starPut(dst_idx, name, tgt, rec.type_only)) changed = true;
                            }
                            continue;
                        }
                        const src_key = l.ambientKey(rec.module) orelse continue;
                        const src_idx = l.ambient.getIndex(src_key).?;
                        if (src_idx == dst_idx) continue; // self-star
                        // Snapshot: the put below may grow the destination
                        // table, and only the source's entries are read.
                        const src = l.ambient.values()[src_idx];
                        for (src.keys(), src.values()) |name, tgt| {
                            if (try l.starPut(dst_idx, name, tgt, rec.type_only)) changed = true;
                        }
                    }
                }
            }
            if (!changed) break;
        }
    }

    /// Deferred second half of `table`'s pass 2: a FILE's `export * from "spec"`
    /// whose `spec` is served by an ambient `declare module "spec" { … }` block
    /// rather than by a resolved file.
    ///
    /// `@types/fs-extra`'s `index.d.ts` is the shape — `export * from "fs"` on
    /// top of its own overloads. "fs" resolves to no file (`@types/node`
    /// declares it as an ambient module), so pass 2's `f.specs.get(rec.module)
    /// orelse continue` dropped the star whole and fs-extra's export table was
    /// its own declarations only. Every name the star contributes then went
    /// missing from all three ways of reaching the table at once: `import fs
    /// from "fs-extra"` (the `esModuleInterop` synthetic default, which IS this
    /// module's namespace object), `import * as fs from "fs-extra"`, and
    /// `import { createWriteStream } from "fs-extra"` — TS2339/TS2551/TS2305 on
    /// every `fs.createWriteStream` / `fs.readFileSync` / `fs.ReadStream` an
    /// application writes through the alias.
    ///
    /// It cannot run inside `table`: the ambient registry is filled only after
    /// every file table exists (`buildAmbient`), so the source names are not
    /// there yet. Hence a pass of its own — and, once a file table grows here,
    /// a re-run of BOTH other star merges, because that table is itself a
    /// possible star source: for the file→file direction (`export * from
    /// "fs-extra"` in a package that re-bundles it, whose pass-2 merge read the
    /// smaller table) and for the ambient one (`declare module "m" { export *
    /// from "fs-extra"; }`). All three reach a joint fixed point rather than
    /// each settling alone.
    ///
    /// Same rules as both existing star merges: `default` and the reserved
    /// `export=` key never travel, and the first contributor of a name wins,
    /// which keeps a module's own declaration (pass 1) ahead of any star's.
    /// Order-invariant: every round only *adds* names, and never one another
    /// round could have taken differently. `join_rounds` is a safety valve, not
    /// a depth budget — growth is monotone, so the loop cannot oscillate, and a
    /// sweep that changes nothing ends it.
    fn starMergeFilesFromAmbient(l: *Linker) Error!void {
        const join_rounds = 64;
        var round: u32 = 0;
        while (round < join_rounds) : (round += 1) {
            var changed = false;
            for (l.files, 0..) |*f, fi| {
                for (f.bind.exports, 0..) |rec, ri| {
                    if (rec.kind != .reexport_all) continue;
                    // A star written inside a `declare module` block re-exports
                    // into that block's specifier, not into the file around it;
                    // `starMergeAmbient` owns those. (`bindExportAll` records no
                    // scope, so the block's record RANGE is what separates them.)
                    if (inAmbientBlock(f, ri)) continue;
                    const t = &l.tables[fi];
                    if (f.specs.get(rec.module)) |mfile| {
                        // The file→file direction, which pass 2 already ran once
                        // — repeated here only so a source table that grew below
                        // reaches the modules that star it. Nothing new on the
                        // first round.
                        if (mfile == fi) continue;
                        const src = &l.tables[mfile];
                        for (src.keys(), src.values()) |name, tgt| {
                            if (try l.starPutFile(t, name, tgt, rec.type_only)) changed = true;
                        }
                        continue;
                    }
                    const key = l.ambientKey(rec.module) orelse continue;
                    // Snapshot: only the source's entries are read, and the put
                    // below grows a FILE table, never this one.
                    const src = l.ambient.values()[l.ambient.getIndex(key).?];
                    for (src.keys(), src.values()) |name, tgt| {
                        if (try l.starPutFile(t, name, tgt, rec.type_only)) changed = true;
                    }
                }
            }
            if (!changed) break;
            try l.starMergeAmbient();
        }
    }

    /// Settle every `export { X } from "m"` whose `X` was not in m's table when
    /// that table was built: look it up again now that all three star merges
    /// have run, and either bind it or report the missing member.
    ///
    /// Deferring the *diagnostic* is the point. A re-export is only wrong if the
    /// name is missing from m's FINAL export set, and m's set is not final until
    /// `starMergeFilesFromAmbient` has folded in whatever its `export * from
    /// "<ambient module>"` contributes — so `export { createWriteStream } from
    /// "fs-extra"` used to be TS2305 while `import { createWriteStream } from
    /// "fs-extra"` (resolved in `linkImports`, which runs later) succeeded. The
    /// suggestion search moves with it, for the same reason: TS2724's
    /// "did you mean" should be drawn from the full table.
    ///
    /// Records are settled in the order `table` parked them, which is statement
    /// order, so the file's own last-wins export precedence is preserved: a slot
    /// another statement has since claimed with a real target is left alone, and
    /// only the placeholder `any` this record itself put is replaced.
    fn resolvePendingReexports(l: *Linker) Error!void {
        for (l.pending_reexports.items) |p| {
            var found = try l.lookupExport(p.mfile, p.local, 0);
            // The parked path's `export =` fallback, repeated so the two stay
            // one rule. Nothing adds that key to a table after `table` ran, so
            // in practice a module with an `export =` never parks a record.
            if (found == null) {
                if (try l.lookupExport(p.mfile, l.atom_export_equals, 0)) |exeq| {
                    found = (try l.exportEqualsMeanings(exeq, p.local)) orelse
                        .{ .kind = .any };
                }
            }
            if (found) |tgt| {
                const t = &l.tables[p.file];
                if (t.get(p.exported)) |cur| {
                    if (cur.kind != .any) continue;
                }
                var final = tgt;
                final.type_only = final.type_only or p.type_only;
                try l.put(t, p.exported, final);
            } else {
                try l.diagNoExportedMember(p.file, p.mfile, p.module, p.local, l.nodeSpan(p.file, p.node));
            }
        }
    }

    /// One `export *`-merged name into a FILE's export table (`starPut`'s twin
    /// for the file side). True when it was actually new.
    fn starPutFile(
        l: *Linker,
        dst: *std.AutoArrayHashMapUnmanaged(Atom, Target),
        name: Atom,
        tgt: Target,
        type_only: bool,
    ) Error!bool {
        if (name == l.atom_default or name == l.atom_export_equals) return false;
        if (dst.contains(name)) return false;
        var final = tgt;
        final.type_only = final.type_only or type_only;
        try dst.put(l.scratch, name, final);
        return true;
    }

    /// True when export record `ri` of `f` was written inside one of the file's
    /// `declare module "spec" { … }` blocks (the blocks own contiguous ranges of
    /// `bind.exports`) rather than at the file's own top level.
    fn inAmbientBlock(f: *const ProgFile, ri: usize) bool {
        for (f.bind.ambient_modules) |am| {
            if (ri >= am.export_start and ri < am.export_end) return true;
        }
        return false;
    }

    /// One `export *`-merged name into ambient table `dst_idx`. True when it
    /// was actually new (the fixed-point driver's change signal).
    fn starPut(l: *Linker, dst_idx: usize, name: Atom, tgt: Target, type_only: bool) Error!bool {
        if (name == l.atom_default or name == l.atom_export_equals) return false;
        const dst = &l.ambient.values()[dst_idx];
        if (dst.contains(name)) return false;
        var final = tgt;
        final.type_only = final.type_only or type_only;
        try dst.put(l.scratch, name, final);
        return true;
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
    /// after resolution fails. `applyAmbientModulePrecedence` performs that flip
    /// program-wide before linking starts, for every specifier a GLOBAL `declare
    /// module` claims — so by the time this runs, `f.specs.get` has already
    /// answered null for those. What is left here are the specifiers whose
    /// ambient block sits in a MODULE file, i.e. an *augmentation*, which must
    /// merge into the module it names rather than replace it. That is right when
    /// the resolved file is itself a module; it is wrong in the two cases below,
    /// and the flip stays scoped to exactly those, so no augmentation can be
    /// turned into a replacement.
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

    /// True when `mfile` is the synthetic stand-in the resolver returns for an
    /// `exports`-map subpath the map does not name — i.e. the specifier did
    /// NOT really resolve, and tsc reports TS2307 at it.
    ///
    /// Splitting the report from the resolution is the whole point. The
    /// resolver may not answer `null` for a blocked subpath: an unresolved
    /// specifier dangles the import's symbol, which is order-dependent under
    /// parallel resolution and aborted intermittently in the flow-narrowing
    /// `mergedSym` path. So resolution keeps handing back a stable opaque `any`
    /// module (every downstream symbol stays bound and typed `any`, which is
    /// also tsc's observable type at such an import), and only the *diagnostic*
    /// treats the specifier as unresolved. Nothing here mutates shared state —
    /// the linker walks files sequentially into per-file `diags` sinks — so the
    /// recording inherits the link phase's thread-safety, not the resolver's.
    fn blockedSubpathReport(l: *Linker, mfile: FileId) bool {
        return paths.isBlockedSubpathPath(l.files[mfile].path);
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
    /// side-effect-only import (`import "./x"`) is governed by
    /// `noUncheckedSideEffectImports` (TS 5.6+) instead: tsc's
    /// `checkImportDeclaration` only resolves the specifier of a *bare*
    /// `import "m"` when that option is on, so with the option off (tsc's
    /// default, and the dogfood project's) an unresolved side-effect specifier
    /// is silently accepted — bundler plugins own specifiers like
    /// `import "@fontsource-variable/inter"`, which is a CSS-only package.
    /// When the option is on, ztsc reports TS2882, matching the pinned tsgo
    /// oracle (tsc words the same condition as TS2307); tsgo 7.0.2 differs from
    /// tsc only in defaulting the option ON.
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
                // An `exports`-blocked subpath is a RESOLUTION FAILURE wearing
                // a resolution's clothes: the resolver hands back a synthetic
                // opaque `any` module (`paths.blocked_subpath_suffix`) purely so
                // every downstream symbol stays bound — dangling the specifier
                // instead is not crash-safe under parallel resolution. The
                // diagnostic is decoupled from that liveness decision here:
                // liveness stays with the resolver's stand-in module, and the
                // report falls through to the same unresolved-specifier arms
                // below (ambient suppression included), so tsc's TS2307 lands
                // at the specifier token. See `blockedSubpathReport`.
                if (!l.blockedSubpathReport(mfile)) {
                    // Resolved. The one thing left to say about it: a dependency
                    // that turned out to be plain JavaScript has no types, and
                    // under `noImplicitAny` that is an error at the specifier.
                    if (l.no_implicit_any and !side_effect and untypedJsModule(l.files[mfile].path)) {
                        try l.diag(file, 7016, l.tokSpan(file, mod_tok), "Could not find a declaration file for module '{s}'. '{s}' implicitly has an 'any' type.", .{ stripped, l.files[mfile].path });
                    }
                    continue;
                }
            }
            if (l.hasAmbient(atom)) continue; // resolved by a `declare module`
            if (side_effect) {
                if (!l.no_unchecked_side_effect_imports) continue;
                try l.diag(file, 2882, l.tokSpan(file, mod_tok), "Cannot find module or type declarations for side-effect import of '{s}'.", .{stripped});
            } else if (!paths.isNodeCoreModule(stripped)) {
                try l.diag(file, 2307, l.tokSpan(file, mod_tok), "Cannot find module '{s}' or its corresponding type declarations.", .{stripped});
            } else if (l.types_wildcard) {
                try l.diag(file, 2580, l.tokSpan(file, mod_tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node`.", .{stripped});
            } else {
                // A Node core module that resolved to nothing is a missing
                // `@types/node`, and tsc says so — with the *name* wording, at
                // the specifier. Only for the exact core-module list
                // (`paths.isNodeCoreModule`); `bun:sqlite` and `node:nosuch`
                // stay TS2307. A side-effect import keeps TS2882: tsgo passes
                // its own message down and never consults the node list.
                try l.diag(file, 2591, l.tokSpan(file, mod_tok), "Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node` and then add 'node' to the types field in your tsconfig.", .{stripped});
            }
        }
    }

    /// TS2688 for a `/// <reference types="X" />` whose target resolved to
    /// nothing, at the directive's own name span (tsc anchors it just inside
    /// the opening quote). The misses were recorded by whichever driver
    /// discovered the file — resolution is a filesystem walk and does not
    /// belong in the linker — so this is a pure replay in source order.
    ///
    /// Unlike the tsconfig `types` list, whose unresolved entries tsc reports
    /// as a file-less global diagnostic (still an under-report here), these are
    /// anchored in a real file, which also means `skipLibCheck` suppresses the
    /// ones in a `.d.ts` — exactly what the oracle does, and what the driver's
    /// whole-file `.d.ts` suppression already delivers.
    fn reportUnresolvedTypeRefs(l: *Linker, file: FileId) Error!void {
        for (l.files[file].type_ref_misses) |miss| {
            try l.diag(file, 2688, miss.span, "Cannot find type definition file for '{s}'.", .{miss.name});
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
    ///
    /// Returns the file's whole import table (scratch-owned, statement order).
    fn linkImports(l: *Linker, file: FileId) Error!ImportLinks {
        var locals: std.ArrayList(u32) = .empty;
        var targets: std.ArrayList(Target) = .empty;
        const f = &l.files[file];
        for (f.bind.imports) |rec| {
            if (rec.kind == .side_effect) continue;
            // In the record's OWN scope: a `declare module "spec" { import
            // type { T } from "other"; … }` block declares its imports in the
            // block, not at file scope, and looking only at file scope dropped
            // the record — the local bound to nothing, so an interface
            // `extends` on it inherited no members at all.
            const local_sym = f.bind.lookupInScope(rec.scope, rec.local) orelse continue;
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
                            found = try l.exportEqualsMeanings(exeq, rec.imported);
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
        return .{ .locals = locals.items, .targets = targets.items };
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
/// gets TS2307 instead — a different diagnostic, emitted on the unresolved arm
/// of the same walk via `blockedSubpathReport`.
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
// discovery: turning one bound file's module references into file ids
//
// Both program builders share this. `buildProgram` above walks a pending list
// serially; the CLI driver (driver.zig) resolves each worker completion as it
// arrives. What they must agree on is the per-FILE step — which references
// count as module references, how a specifier becomes a path, and how a path
// becomes a file id — because a difference there is a difference in the
// program, and the two copies have drifted before.
// ===========================================================================

/// Everything a file's specifier resolution needs that does not vary from
/// file to file. The caller owns the discovery state this points at
/// (`paths` is the discovery order, `path_ids` its inverse) and drives the
/// scheduling; this only answers "what does this file reference".
pub const Discovery = struct {
    /// Program-lifetime allocator: the resolved path strings kept in `paths`
    /// (and used as `path_ids` keys) are duped into it.
    arena: Allocator,
    /// Backs the discovery bookkeeping: `paths`, `path_ids`, and the per-file
    /// spec-map lists. Separate from `arena` because the serial builder keeps
    /// this state in scratch and only the paths themselves must outlive it.
    store: Allocator,
    /// Backs the caller's per-file `seen` set. Separate again: the parallel
    /// driver creates and frees one per completion, so it must not grow an
    /// arena that lives for the whole run.
    seen_alloc: Allocator,
    /// Transient — candidate paths and `package.json` bodies. The caller
    /// resets it between files; nothing here retains a pointer into it.
    scratch: Allocator,
    io: Io,
    /// The directory relative paths resolve against.
    dir: Io.Dir,
    interner: *Interner,
    rcache: *ResolveCache,
    /// tsconfig `paths`, or null when the run has no config.
    paths_map: ?tsconfig.Paths = null,
    /// tsconfig `resolveJsonModule`, needed here (not just in `ResolveOpts`)
    /// because a `paths`-mapped `*.json` takes its own resolution route.
    resolve_json: bool = false,
    /// Discovered files in discovery order; a file's id is its index.
    paths: *std.ArrayList([]const u8),
    /// Path -> file id, over the very same strings `paths` holds.
    path_ids: *std.StringHashMapUnmanaged(FileId),

    /// Seed the selected built-in lib blobs as the first files (ids 0..).
    /// Their synthetic paths carry the embedded sources (`libs.libSourceFor`),
    /// which is how both front ends load them, and their top-level decls become
    /// the program globals. Empty under `--noLib` / `lib: []`. Must run before
    /// any other seeding: the lib shards own the ids from 0 up.
    pub fn seedLibs(d: *const Discovery, lib_set: LibSet) !void {
        var buf: [max_lib_files]LibFile = undefined;
        for (libs.libFiles(lib_set, &buf)) |lf| _ = try d.fileFor(lf.path);
    }

    /// Seed one program root and return its file id (the id it already has if
    /// this path was seeded before).
    ///
    /// A root under `node_modules` — in practice the auto-included `@types/*`
    /// ambient roots, which pnpm exposes as symlinks into its store — is keyed
    /// by its canonical path, the same identity the module resolver gives the
    /// very same file when an `import` reaches it. Without that step
    /// `node_modules/@types/react/index.d.ts` and the store path behind the
    /// symlink are two files with two symbol universes. Outside `node_modules`
    /// `canonicalPath` is a no-op, so project roots keep the path the user
    /// typed (and pay no realpath syscall).
    pub fn seedEntry(d: *const Discovery, path: []const u8) !FileId {
        const norm = try paths.normalizePath(d.arena, path);
        return try d.fileFor(try d.rcache.canonicalPath(d.io, d.scratch, d.dir, norm));
    }

    /// The file id of an already-resolved path, discovering it (appending to
    /// `paths`) if this is its first mention.
    pub fn fileFor(d: *const Discovery, resolved: []const u8) !FileId {
        const gop = try d.path_ids.getOrPut(d.store, resolved);
        if (gop.found_existing) return gop.value_ptr.*;
        // Give the map a stable key and `paths` a stable slice: `resolved` is
        // usually scratch-owned and about to be reset away.
        const stable = try d.arena.dupe(u8, resolved);
        gop.key_ptr.* = stable;
        const fid: FileId = @intCast(d.paths.items.len);
        gop.value_ptr.* = fid;
        try d.paths.append(d.store, stable);
        return fid;
    }

    /// Resolve one module specifier of `importer`, appending the
    /// (atom, file) pair to the file's spec map and discovering new files.
    /// A specifier already seen in this file contributes nothing (the spec
    /// map is keyed by atom).
    pub fn resolveSpec(
        d: *const Discovery,
        importer: []const u8,
        module_atom: Atom,
        seen: *std.AutoHashMapUnmanaged(Atom, void),
        atoms: *std.ArrayList(Atom),
        files: *std.ArrayList(FileId),
    ) !void {
        if (module_atom == 0) return;
        const gop = try seen.getOrPut(d.seen_alloc, module_atom);
        if (gop.found_existing) return;
        const spec = d.interner.lookup(d.io, module_atom);
        var fid: FileId = no_file;
        // tsconfig `paths` mapping applies to bare specifiers first;
        // unmatched or unresolved candidates fall through to normal
        // resolution, like tsc.
        var mapped: ?[]const u8 = null;
        if (d.paths_map) |pm| {
            if (spec.len > 0 and spec[0] != '.' and spec[0] != '/') {
                // A `paths`-mapped `*.json` (`@fixtures/apis/x.json`) resolves to the
                // JSON file directly — `resolveStem` only probes TS/declaration
                // extensions and would miss it.
                const is_json = d.resolve_json and std.mem.endsWith(u8, spec, ".json");
                for (try pm.mapSpecifier(d.scratch, spec)) |cand| {
                    const r = if (is_json)
                        try resolve.resolveJsonFile(d.io, d.scratch, d.dir, cand)
                    else
                        // Full "load as file or folder" — a substitution that names
                        // a package directory is resolved through its
                        // `package.json`, not just by stem probing
                        // (`resolvePathsCandidate`), under the same `ResolveOpts`
                        // every other probe of this run sees.
                        try d.rcache.pathsCandidate(d.io, d.scratch, d.dir, cand);
                    if (r) |rr| {
                        mapped = rr;
                        break;
                    }
                }
            }
        }
        // `paths`-mapped bare specifiers bypass the cache: their resolution is a
        // different decision (a tsconfig remap), rare, and one `resolveStem` call.
        // Everything else — the common case — goes through the memo.
        if (mapped orelse try d.rcache.resolve(d.io, d.scratch, d.dir, importer, spec)) |resolved| {
            fid = try d.fileFor(resolved);
        }
        try atoms.append(d.store, module_atom);
        try files.append(d.store, fid);
    }

    /// Every module reference of one bound file, in tsc's order. The result is
    /// the file's spec map (unsorted — the caller sorts with `sortSpecPairs`,
    /// which the atom renumbering may have to redo).
    pub fn fileSpecs(
        d: *const Discovery,
        importer: []const u8,
        bound: *const Bind,
        seen: *std.AutoHashMapUnmanaged(Atom, void),
        atoms: *std.ArrayList(Atom),
        files: *std.ArrayList(FileId),
    ) !void {
        for (bound.imports) |rec| {
            try d.resolveSpec(importer, rec.module, seen, atoms, files);
        }
        for (bound.exports) |rec| {
            if (rec.module != 0) {
                try d.resolveSpec(importer, rec.module, seen, atoms, files);
            }
        }
        // A `declare module "spec" { … }` block inside a file that is
        // itself a MODULE is a module *augmentation*, and its specifier is
        // a module reference of this file exactly like an import is —
        // tsc's `getModuleNames` appends `file.moduleAugmentations` to
        // `file.imports` before `processImportedModules` resolves them.
        // Without it `f.specs` only held specifiers some import/export
        // clause happened to name, so `mergeAugmentations` could not find
        // the augmented file and dropped the block: an augmentation that
        // is the ONLY mention of the module in its file never merged.
        //
        // That is the shape a package uses to augment ITSELF from a
        // sibling file — @tiptap/core's `dist/commands/*.d.ts` each carry
        // `declare module '@tiptap/core' { interface Commands<R> { … } }`
        // while importing only relative paths — so `Commands` stayed
        // empty except for the handful of third-party extension packages
        // (which DO import '@tiptap/core' for other reasons), and every
        // `editor.commands.*` / `editor.chain().*` was a TS2339.
        //
        // Gated on `bound.is_module`, tsc's `isExternalModuleFile`: in a
        // SCRIPT the same block is a standalone ambient module declaration
        // (@types/node's `declare module "fs"`), not an augmentation, and
        // must not resolve to anything.
        if (bound.is_module) {
            for (bound.ambient_modules) |am| {
                try d.resolveSpec(importer, am.spec, seen, atoms, files);
            }
        }
    }

    /// Pull a module into the program as a program INPUT rather than as an
    /// import binding — the auto-injected `@types/node` and
    /// `<jsxImportSource>/jsx-runtime`. Null when it does not resolve.
    pub fn discoverModule(d: *const Discovery, importer: []const u8, spec: []const u8) !?FileId {
        const resolved = try d.rcache.resolve(d.io, d.scratch, d.dir, importer, spec) orelse
            return null;
        return try d.fileFor(resolved);
    }

    /// Auto-include `@types/node` on account of `bound`'s imports, like tsc's
    /// automatic `@types` inclusion: a Node built-in specifier (`node:fs`,
    /// `path`, …) is answered by `@types/node`'s ambient `declare module "fs"`
    /// / `declare module "node:fs"` blocks, which only register once that
    /// package is a program input. Null when the file imports no built-in, or
    /// when `@types/node` is not installed — the caller keeps asking on later
    /// files, so a program that installs it later in the graph still gets it.
    ///
    /// Only the FIRST built-in import of the file is tried: one probe per file
    /// until the package is found, none afterwards (the caller stops asking).
    pub fn discoverNodeTypes(d: *const Discovery, importer: []const u8, bound: *const Bind) !?FileId {
        for (bound.imports) |rec| {
            // A syntactically broken import records no specifier — `import *
            // from Zero from "./0"`, `import * as while from "foo"`. Atom 0 is
            // the same "no specifier" sentinel `resolveSpec` skips; passing it
            // to `lookup` indexes the shard's string list with a wrapped
            // `0 - 1`.
            if (rec.module == 0) continue;
            if (!paths.isNodeBuiltin(d.interner.lookup(d.io, rec.module))) continue;
            return try d.discoverModule(importer, "@types/node");
        }
        return null;
    }

    /// Discover a triple-slash reference target as a program input. Unlike
    /// `resolveSpec` it records no import-specifier binding, and resolution
    /// goes through `ResolveCache.resolveRef`, so the target is keyed by its
    /// canonical path — the same identity an `import` of that file would get.
    /// `no_file` when the directive resolves to nothing (a `types=` miss is
    /// the linker's TS2688; the caller decides).
    pub fn discoverReference(d: *const Discovery, importer: []const u8, ref: resolve.RefDirective) !FileId {
        if (try d.rcache.resolveRef(d.io, d.scratch, d.dir, importer, ref)) |resolved| {
            return try d.fileFor(resolved);
        }
        return no_file;
    }
};

/// Sort a file's spec map by atom, keeping the (atom, file) pairs together.
/// Insertion sort: a file's specifiers arrive nearly sorted (atoms are handed
/// out in source order), and the run of one file's specifiers is short.
pub fn sortSpecPairs(atoms: []Atom, files: []FileId) void {
    var i: usize = 1;
    while (i < atoms.len) : (i += 1) {
        var j = i;
        while (j > 0 and atoms[j - 1] > atoms[j]) : (j -= 1) {
            std.mem.swap(Atom, &atoms[j - 1], &atoms[j]);
            std.mem.swap(FileId, &files[j - 1], &files[j]);
        }
    }
}

// ===========================================================================
// tests: the seeding both program builders share
// ===========================================================================

const testing = std.testing;

/// One `Discovery` over throwaway state, for the seeding tests: everything in
/// one arena, since a test's scratch never has to outlive it.
fn testDiscovery(
    alloc: Allocator,
    io: Io,
    dir: Io.Dir,
    interner: *Interner,
    rcache: *ResolveCache,
    file_paths: *std.ArrayList([]const u8),
    path_ids: *std.StringHashMapUnmanaged(FileId),
) Discovery {
    return .{
        .arena = alloc,
        .store = alloc,
        .seen_alloc = alloc,
        .scratch = alloc,
        .io = io,
        .dir = dir,
        .interner = interner,
        .rcache = rcache,
        .paths = file_paths,
        .path_ids = path_ids,
    };
}

// The lib shards own the file ids from 0 up, and the roots follow them — the
// contract `buildProgram` and driver.zig's `seedRoots` both rely on (the
// driver hands `lib_units.len` to the renumbering as the first BFS wave).
test "Discovery.seedLibs: the lib shards are files 0.., roots follow" {
    const io = testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var rcache = ResolveCache.init(alloc, true, .{});
    var file_paths: std.ArrayList([]const u8) = .empty;
    var path_ids: std.StringHashMapUnmanaged(FileId) = .empty;
    const disco = testDiscovery(alloc, io, Io.Dir.cwd(), &interner, &rcache, &file_paths, &path_ids);

    var buf: [max_lib_files]LibFile = undefined;
    const lib_list = libs.libFiles(.es_only, &buf);
    try disco.seedLibs(.es_only);
    try testing.expectEqual(lib_list.len, file_paths.items.len);
    for (lib_list, 0..) |lf, i| try testing.expectEqualStrings(lf.path, file_paths.items[i]);

    // A root outside `node_modules` keeps the path the user typed (normalized),
    // and takes the next id. Seeding it twice is one file.
    try testing.expectEqual(@as(FileId, @intCast(lib_list.len)), try disco.seedEntry("./src/main.ts"));
    try testing.expectEqual(@as(FileId, @intCast(lib_list.len)), try disco.seedEntry("src/main.ts"));
    try testing.expectEqualStrings("src/main.ts", file_paths.items[lib_list.len]);
}

// Roots are canonicalized, so a root reached through a `node_modules` symlink
// and the store path behind it are ONE file rather than two files with two
// symbol universes. The driver always did this; the serial `buildProgram` did
// not until both went through `seedEntry`.
test "Discovery.seedEntry: a symlinked node_modules root is one file" {
    const io = testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg");
    try d.writeFile(io, .{
        .sub_path = "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/index.d.ts",
        .data = "export declare const x: number;\n",
    });
    try d.createDirPath(io, "node_modules/@types");
    try d.symLink(io, "../.pnpm/@types+pkg@1/node_modules/@types/pkg", "node_modules/@types/pkg", .{ .is_directory = true });

    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var rcache = ResolveCache.init(alloc, true, .{});
    var file_paths: std.ArrayList([]const u8) = .empty;
    var path_ids: std.StringHashMapUnmanaged(FileId) = .empty;
    const disco = testDiscovery(alloc, io, d, &interner, &rcache, &file_paths, &path_ids);

    const canonical = "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/index.d.ts";
    const via_link = try disco.seedEntry("node_modules/@types/pkg/index.d.ts");
    const via_store = try disco.seedEntry(canonical);
    try testing.expectEqual(via_link, via_store);
    try testing.expectEqual(@as(usize, 1), file_paths.items.len);
    try testing.expectEqualStrings(canonical, file_paths.items[0]);
}

// A Node built-in import pulls `@types/node` into the program — the CLI's
// behavior, which the serial builder now gets from the same
// `Discovery.discoverNodeTypes`. Without it the ambient `declare module "fs"`
// never registers and the import is unresolved.
test "buildProgram: a node builtin import auto-injects @types/node" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "node_modules/@types/node");
    try d.writeFile(io, .{
        .sub_path = "node_modules/@types/node/index.d.ts",
        .data = "declare module \"node:fs\" { export const readFileSync: () => string; }\n",
    });
    try d.writeFile(io, .{
        .sub_path = "entry.ts",
        .data = "import { readFileSync } from \"node:fs\";\nexport const s = readFileSync();\n",
    });

    var interner = Interner.init();
    defer interner.deinit(gpa);
    const br = try buildProgram(alloc, io, gpa, &interner, d, &.{"entry.ts"}, .none, .{}, .{}, null);
    try testing.expectEqual(@as(usize, 0), br.load_failures.len);
    try testing.expectEqual(@as(usize, 2), br.program.files.len);
    try testing.expectEqualStrings("entry.ts", br.program.files[0].path);
    try testing.expectEqualStrings("node_modules/@types/node/index.d.ts", br.program.files[1].path);
    // The ambient block answered the import: no unresolved-module diagnostic.
    for (br.program.links) |fl| try testing.expectEqual(@as(usize, 0), fl.diags.len);
}
