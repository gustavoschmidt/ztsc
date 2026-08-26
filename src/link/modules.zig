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
const bind_result = @import("../frontend/bind_result.zig");
const decl_spaces = @import("../frontend/decl_spaces.zig");
const diagnostics = @import("../frontend/diagnostics.zig");
const intern = @import("../intern.zig");
const literals = @import("../frontend/literals.zig");
const source = @import("../frontend/source.zig");
const libs = @import("../libs.zig");
const alias_cycle = @import("alias_cycle.zig");
const global_dup = @import("global_dup.zig");
const jsx_pragma = @import("jsx_pragma.zig");
const package_id = @import("package_id.zig");
const paths = @import("paths.zig");
const resolve = @import("resolve.zig");
const umd = @import("umd.zig");
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
pub const typeRefSelf = program.typeRefSelf;
pub const FileLinks = program.FileLinks;
pub const Target = program.Target;
const TypeOnly = program.TypeOnly;
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
    // The same slices the `ProgFile`s point at, kept mutable for the
    // package-identity rewrite after discovery (see the end of this function).
    var spec_file_slices: std.ArrayList([]FileId) = .empty;

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
        // …and this file's own `/* @jsxImportSource X */` override, if any.
        const jsx_pragma_rt = try disco.discoverJsxPragma(path, bytes);

        // Triple-slash `/// <reference>` directives pull extra files into the
        // program — not import bindings, just program inputs.
        var type_ref_misses: std.ArrayList(TypeRefMiss) = .empty;
        for (try resolve.scanReferences(scratch, bytes)) |ref| {
            const rt = try disco.discoverReference(path, ref);
            if (rt.file == no_file) {
                try type_ref_misses.append(arena, typeRefMiss(ref));
            } else if (rt.self) {
                try type_ref_misses.append(arena, typeRefSelf(ref));
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

        // Kept as a mutable slice as well: the package-identity pass below
        // rewrites the resolved targets in place once every file is known.
        const resolved_specs = try arena.dupe(FileId, spec_files.items);
        try spec_file_slices.append(scratch, resolved_specs);
        try files.append(arena, .{
            .path = path,
            .src = bytes,
            .tree = tree,
            .bind = bound,
            .specs = .{
                .atoms = try arena.dupe(Atom, spec_atoms.items),
                .files = resolved_specs,
            },
            .type_ref_misses = try type_ref_misses.toOwnedSlice(arena),
            .jsx_pragma_module = if (jsx_pragma_rt) |p| p.spec else null,
            .jsx_pragma_file = if (jsx_pragma_rt) |p| p.file else no_file,
        });
        spec_atoms.deinit(scratch);
        spec_files.deinit(scratch);
        seen.deinit(scratch);
    }

    const file_slice = try arena.dupe(ProgFile, files.items);
    // Package-identity dedup, shared with the driver: two on-disk copies of one
    // package version are ONE module, so every specifier that resolved to a
    // later copy is re-pointed at the first (package_id.zig). `pending` is the
    // final file order here — this builder assigns ids in discovery order and
    // never renumbers — so the winner is settled before any specifier is read.
    if (try package_id.redirects(arena, scratch, &rcache, io, dir, pending.items)) |map| {
        for (spec_file_slices.items) |sf| package_id.applyTo(map, sf);
    }
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
            .eq_default_imports = lr.eq_default_imports,
            .types_wildcard = link_opts.types_wildcard,
            .es_module_interop = link_opts.es_module_interop,
            .experimental_decorators = link_opts.experimental_decorators,
            .jsx_runtime_file = jsx_runtime_fid,
            .jsx_runtime_module = jsx_runtime_module,
            .jsx_factory_ns = link_opts.jsx_factory_ns,
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
    // Index the program's global declarations, so an `export { x }` naming a
    // global resolves instead of reporting TS2304. Must precede table
    // building; the full global MERGE runs afterwards, once the tables it
    // needs are sealed.
    try l.indexGlobals();
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
    // `export as namespace X` records, name-sorted for `umd.forName`. Needed
    // here (before the tables seal) as well as by the global merge below: a
    // `declare global { namespace X }` of a UMD name merges into the MODULE,
    // so its members are exports of that module.
    const umds = try umd.collect(scratch, gpa, io, interner, files);
    umd.sortByName(umds);
    try l.foldUmdGlobalMembers(umds);
    // TS2303: alias declarations that define each other. A pure diagnostic pass
    // over the sealed bind data — the export tables above are cycle-SAFE, which
    // keeps every name bound but erases the evidence this needs.
    try alias_cycle.report(arena, scratch, gpa, io, interner, files, l.diags);

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
            // `.diags` is sealed AFTER the global merge below, which reports the
            // cross-file duplicate declarations (global_dup.zig) into the same
            // per-file lists.
        };
    }

    // Cross-file global merge + module augmentation merge: fold
    // every file's harvest slice and every `declare module` augmentation of a
    // resolved real module. Needs the sealed export tables (`out`).
    const sym_base = try computeSymBase(arena, files);
    const gm = try mergeGlobals(arena, scratch, files, sym_base, out, l.atom_export_equals, l.atom_default, umds, .{ .diags = l.diags, .io = l.io, .interner = l.interner });
    for (0..files.len) |i| out[i].diags = try arena.dupe(LinkDiag, l.diags[i].items);

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

    // Parked TS2595 questions, in `(file, position)` order so one file's run is
    // contiguous (`Program.eqDefaultImportsOf`). The two producers sweep the
    // program separately, so the raw list is not in file order.
    const eq_defaults = try arena.dupe(program.EqDefaultImport, l.eq_default_imports.items);
    std.mem.sort(program.EqDefaultImport, eq_defaults, {}, struct {
        fn lessThan(_: void, x: program.EqDefaultImport, y: program.EqDefaultImport) bool {
            if (x.file != y.file) return x.file < y.file;
            return x.span.start < y.span.start;
        }
    }.lessThan);

    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .ambient_exports = amb, .ambient_specs = amb_specs, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals, .export_equals_atom = l.atom_export_equals, .dual_targets = try arena.dupe(DualTarget, l.duals.items), .eq_default_imports = eq_defaults };
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
    const gm = try mergeGlobals(arena, arena, files, sym_base, &.{}, 0, 0, &.{}, null);
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

/// Does a SCRIPT file before `umd_file` already declare `name` at its top
/// level? That is exactly when tsc's `if (!globals.has(id))` finds the slot
/// taken and the `export as namespace name` entry never enters `globals` at
/// all — so the UMD name merges with nothing, silently.
///
/// A module file's top-level harvest does not count: it is offered to the
/// global table only through its own `export = <ident>` stand-in (umd.zig), and
/// a module's locals are never folded into `globals` by
/// `initializeTypeChecker`. Nor do `declare global { … }` members, which are
/// merged in a LATER pass and therefore merge into the UMD entry rather than
/// displacing it.
fn scriptDeclaresBefore(files: []const ProgFile, name: Atom, umd_file: FileId) bool {
    for (files[0..umd_file]) |*f| {
        const b = f.bind;
        if (b.is_module) continue;
        const split = @min(b.global_aug_start, b.global_atoms.len);
        for (b.global_atoms[0..split]) |atom| {
            if (atom == name) return true;
        }
    }
    return false;
}

/// One link of a global name's merge chain: a real declaration symbol, or the
/// synthetic `export as namespace X` entry, which owns no symbol at all (the
/// binder keeps only the name). See umd.zig.
const ChainLink = union(enum) {
    real: u32,
    umd: umd.Global,
};

/// The merge chain of one global name, in tsc's `initializeTypeChecker` order:
/// each file's own top level and its UMD entry, in file order, then every
/// `declare global { … }` augmentation.
///
/// `parts` is already in that order bar the UMD entries, which the binder
/// harvests only for the `export = <ident>` shape it can resolve — and even
/// then as the exported ENTITY's symbol, whose declarations are the entity's,
/// not the `export as namespace` line tsc reports at. Those stand-in
/// contributors (the only global contributor that is a MODULE file's top-level
/// symbol) are dropped here and re-supplied from `umds`, uniformly for every
/// export shape.
///
/// A UMD entry is dropped outright once anything precedes it: tsc's copy step
/// is `if (!globals.has(id)) globals.set(id, sym)`, so a name a script already
/// declared keeps the script's symbol and the UMD name never merges with
/// anything. A LATER script declaration of the same name does merge into it,
/// which is what makes the clash order-dependent.
fn buildChain(
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
    umds: []const umd.Global,
) Error![]ChainLink {
    var chain: std.ArrayListUnmanaged(ChainLink) = .empty;
    try chain.ensureTotalCapacity(scratch, parts.len + umds.len);
    var u: usize = 0;
    var i: usize = 0;
    while (i < parts.len) : (i += 1) {
        const fid = fileOfGlobal(sym_base, files.len, parts[i]);
        const b = files[fid].bind;
        // The own-top-level pass ends at the first block-scoped contributor:
        // a `declare global { … }` member (see `eachGlobalDecl`).
        if (b.symbol_scopes[parts[i] - sym_base[fid]] != binder.file_scope) break;
        while (u < umds.len and umds[u].file < fid) : (u += 1) {
            if (chain.items.len == 0) chain.appendAssumeCapacity(.{ .umd = umds[u] });
        }
        if (!b.is_module) chain.appendAssumeCapacity(.{ .real = parts[i] });
    }
    while (u < umds.len) : (u += 1) {
        if (chain.items.len == 0) chain.appendAssumeCapacity(.{ .umd = umds[u] });
    }
    while (i < parts.len) : (i += 1) chain.appendAssumeCapacity(.{ .real = parts[i] });
    return chain.items;
}

/// The member half of a UMD merge: a global `namespace X { export const c }`
/// that merges into the module `export as namespace X` publishes brings its
/// members with it, and one the module ALREADY exports meets `mergeSymbol`
/// there — `exportAsNamespace_augment`'s three-way `conflict`.
///
/// The export table has already absorbed the members that were NEW
/// (`Linker.foldUmdGlobalMembers`), so a name whose export target is the block
/// member itself is that fold, not a duplicate; a name whose target is
/// something else is the module's own export winning the collision, which is
/// the pair to judge. Verdict and message are `global_dup.mergeClash`'s, the
/// same rule the name itself was judged by one line above.
fn reportUmdGlobalMemberDups(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    l: *const FileLinks,
    chain: []const ChainLink,
) Error!void {
    for (chain) |ln| {
        const p = switch (ln) {
            .real => |r| r,
            .umd => continue,
        };
        const fid = fileOfGlobal(sym_base, files.len, p);
        const b = files[fid].bind;
        const ns = b.namespaceScopeOf(p - sym_base[fid]) orelse continue;
        const lo = b.scope_members_start[ns];
        const hi = b.scope_members_start[ns + 1];
        for (lo..hi) |i| {
            const msym = b.member_syms[i];
            if (!b.symbol_flags[msym].exported) continue;
            const tgt = l.exportTarget(b.member_atoms[i]) orelse continue;
            if (tgt.kind != .binding) continue;
            const real = sym_base[tgt.file] + tgt.payload;
            const mine = sym_base[fid] + msym;
            if (real == mine) continue; // the fold, not a second declaration
            const flags = [2]binder.SymbolFlags{
                globalSymFlags(files, sym_base, real),
                globalSymFlags(files, sym_base, mine),
            };
            const code = switch (global_dup.mergeClash(&flags) orelse continue) {
                .duplicate => |c| c,
                // The `NamespaceModule` arm's TS2649 is reported for the
                // top-level global merge alone, where the oracle pins it
                // (`reportGlobalDup`); a member-table target that takes it
                // stays silent rather than guessing a second position.
                .augment_non_module => continue,
            };
            try reportContributors(arena, scratch, diags, files, sym_base, &.{ real, mine }, code);
        }
    }
}

/// The module a merge chain publishes from, when the chain is a UMD entry that
/// a REAL declaration merges into — the shape `umdNamespace` is the symbol for.
/// Null for every other chain: one with no UMD entry (the ordinary global
/// merge), and one whose UMD entry stands alone, where `addUmdGlobals` supplies
/// the module's exports and there is nothing to merge with.
fn umdMergeTarget(chain: []const ChainLink) ?FileId {
    var uf: ?FileId = null;
    var any_real = false;
    for (chain) |ln| switch (ln) {
        .umd => |u| uf = uf orelse u.file,
        .real => any_real = true,
    };
    return if (any_real) uf else null;
}

/// The `.real` links of a chain, in chain order.
fn chainReals(scratch: Allocator, chain: []const ChainLink) Error![]const u32 {
    const out = try scratch.alloc(u32, chain.len);
    var n: usize = 0;
    for (chain) |ln| switch (ln) {
        .real => |p| {
            out[n] = p;
            n += 1;
        },
        .umd => {},
    };
    return out[0..n];
}

/// Where the global merge files its diagnostics, plus what spelling a name in
/// one takes. Bundled so `mergeGlobals` carries "report or not" as a single
/// optional parameter rather than three.
const DupSink = struct {
    diags: []std.ArrayList(LinkDiag),
    io: Io,
    interner: *Interner,

    fn text(s: DupSink, a: Atom) []const u8 {
        return if (a == 0) "" else s.interner.lookup(s.io, a);
    }
};

/// One global name's contributors, checked for a merge tsc rejects. The verdict
/// and the reporting are global_dup.zig's; this is the bridge that turns
/// program ids into the (flags, declarations) views it works on.
fn reportGlobalDup(
    arena: Allocator,
    scratch: Allocator,
    sink: DupSink,
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
    umds: []const umd.Global,
    /// The merged name, for TS2649's message.
    name: Atom,
) Error!void {
    const diags = sink.diags;
    if (parts.len + umds.len < 2) return;
    const chain = try buildChain(scratch, files, sym_base, parts, umds);
    if (chain.len < 2) return;
    const flags = try scratch.alloc(binder.SymbolFlags, chain.len);
    for (chain, 0..) |ln, i| {
        flags[i] = switch (ln) {
            .real => |p| globalSymFlags(files, sym_base, p),
            // tsc's UMD symbol is an ALIAS to the module symbol, and the merge
            // is judged on the meaning that alias resolves to — a value-bearing
            // module. So it merges with function/class/interface/namespace/
            // type/enum and clashes with var/let/const, exactly as a namespace
            // does (oracle-verified for all seven).
            .umd => .{ .namespace_decl = true },
        };
    }
    const clash = global_dup.mergeClash(flags) orelse {
        // The name itself merges. When it merges as an INTERFACE, tsc goes on to
        // merge the blocks' member tables, where a member-kind clash is its own
        // duplicate — `interface TopLevel { duplicate1: () => string }` in one
        // file beside `interface TopLevel { duplicate1(): number }` in another.
        var folded: binder.SymbolFlags = .{};
        for (flags) |f| folded = binder.SymbolFlags.merge(folded, f);
        if (folded.interface) {
            const reals = try scratch.alloc(u32, chain.len);
            var n: usize = 0;
            for (chain) |ln| switch (ln) {
                .real => |p| {
                    reals[n] = p;
                    n += 1;
                },
                .umd => {},
            };
            try reportMergedMemberDups(arena, scratch, diags, files, sym_base, reals[0..n]);
        }
        return;
    };
    switch (clash) {
        .duplicate => |code| try reportChain(arena, scratch, diags, files, sym_base, chain, code),
        // tsc's `mergeSymbol` reports this one on the SOURCE alone, at its
        // first declaration's name — and says nothing at all when the target
        // is `globalThis`, which is in the global table like any other name.
        .augment_non_module => |i| {
            const p = switch (chain[i]) {
                .real => |r| r,
                // A UMD entry is an alias to a module symbol, never a
                // declaration this message can point at.
                .umd => return,
            };
            const text = sink.text(name);
            if (std.mem.eql(u8, text, "globalThis")) return;
            const fid = fileOfGlobal(sym_base, files.len, p);
            try global_dup.reportAugmentNonModule(arena, diags, .{
                .file = fid,
                .tree = files[fid].tree,
                .src = files[fid].src,
                .decls = files[fid].bind.declsOf(p - sym_base[fid]),
            }, text);
        },
    }
}

/// Report `code` at every declaration of every link of `chain`.
fn reportChain(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    chain: []const ChainLink,
    code: diagnostics.Code,
) Error!void {
    const contributors = try scratch.alloc(global_dup.Contributor, chain.len);
    // Backing store for the single-element `spans` slices below: a switch
    // capture is a local copy, so its address would dangle past the loop.
    const umd_spans = try scratch.alloc(Span, chain.len);
    for (chain, 0..) |ln, i| {
        switch (ln) {
            .umd => |u| {
                umd_spans[i] = u.span;
                contributors[i] = .{
                    .file = u.file,
                    .tree = files[u.file].tree,
                    .src = files[u.file].src,
                    .spans = umd_spans[i .. i + 1],
                };
            },
            .real => |p| {
                const fid = fileOfGlobal(sym_base, files.len, p);
                contributors[i] = .{
                    .file = fid,
                    .tree = files[fid].tree,
                    .src = files[fid].src,
                    .decls = files[fid].bind.declsOf(p - sym_base[fid]),
                };
            },
        }
    }
    try global_dup.reportAll(arena, diags, contributors, code);
}

/// Report `code` at every declaration of every one of `parts`.
fn reportContributors(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
    code: diagnostics.Code,
) Error!void {
    const contributors = try scratch.alloc(global_dup.Contributor, parts.len);
    for (parts, 0..) |p, i| {
        const fid = fileOfGlobal(sym_base, files.len, p);
        const pf = &files[fid];
        contributors[i] = .{
            .file = fid,
            .tree = pf.tree,
            .src = pf.src,
            .decls = pf.bind.declsOf(p - sym_base[fid]),
        };
    }
    try global_dup.reportAll(arena, diags, contributors, code);
}

/// One atom-SORTED member segment of a merged container (an interface block's
/// member table, a `declare module "spec" { … }` block's top level).
const MemberSeg = struct { file: FileId, atoms: []const Atom, syms: []const u32, at: usize = 0 };

/// Every name declared by 2+ of `segs`, as a k-way merge over the atom-sorted
/// segments rather than a gather into a map: no allocation proportional to the
/// member count, and a name declared by a single segment is skipped after two
/// comparisons. That matters because the lib's big merged interfaces (`Array`,
/// `Window`) are exactly this shape and the walk runs in the serial linker.
///
/// `f` receives the name and its contributors' GLOBAL symbol ids, in segment
/// order. `segs` is consumed (each cursor advances to its end).
fn eachSharedMember(
    scratch: Allocator,
    sym_base: []const u32,
    segs: []MemberSeg,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), Atom, []const u32) Error!void,
) Error!void {
    if (segs.len < 2) return;
    const hits = try scratch.alloc(u32, segs.len);
    while (true) {
        var min_atom: Atom = 0;
        var live = false;
        for (segs) |*s| {
            if (s.at == s.atoms.len) continue;
            if (!live or s.atoms[s.at] < min_atom) min_atom = s.atoms[s.at];
            live = true;
        }
        if (!live) return;
        var k: usize = 0;
        for (segs) |*s| {
            if (s.at == s.atoms.len or s.atoms[s.at] != min_atom) continue;
            hits[k] = sym_base[s.file] + s.syms[s.at];
            k += 1;
            s.at += 1;
        }
        if (k < 2) continue;
        try f(ctx, min_atom, hits[0..k]);
    }
}

/// The member tables of `parts`, as segments for `eachSharedMember`. A part with
/// no members (or an empty one) contributes nothing.
fn memberSegs(
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
) Error![]MemberSeg {
    const segs = try scratch.alloc(MemberSeg, parts.len);
    var n: usize = 0;
    for (parts) |p| {
        const fid = fileOfGlobal(sym_base, files.len, p);
        const b = files[fid].bind;
        const scope = b.membersScopeOf(p - sym_base[fid]) orelse continue;
        const lo = b.scope_members_start[scope];
        const hi = b.scope_members_start[scope + 1];
        if (hi == lo) continue;
        segs[n] = .{ .file = fid, .atoms = b.member_atoms[lo..hi], .syms = b.member_syms[lo..hi] };
        n += 1;
    }
    return segs[0..n];
}

/// The reporting half of the cross-file member walk: one shared name's
/// contributors, checked for a member-KIND clash (`global_dup.memberClash`) and
/// reported at every declaration of every one of them.
const MemberDupReporter = struct {
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,

    fn visit(r: *const MemberDupReporter, _: Atom, hits: []const u32) Error!void {
        const flags = try r.scratch.alloc(binder.SymbolFlags, hits.len);
        for (hits, 0..) |h, i| flags[i] = globalSymFlags(r.files, r.sym_base, h);
        const code = global_dup.memberClash(flags) orelse return;
        try reportContributors(r.arena, r.scratch, r.diags, r.files, r.sym_base, hits, code);
    }
};

/// The same-named members contributed by the blocks of one cross-file merged
/// interface, checked for a member-KIND clash.
///
/// Two blocks in the SAME file share one member table, so this only ever sees
/// cross-FILE pairs; the binder already decided the within-file ones.
fn reportMergedMemberDups(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
) Error!void {
    const segs = try memberSegs(scratch, files, sym_base, parts);
    const r: MemberDupReporter = .{
        .arena = arena,
        .scratch = scratch,
        .diags = diags,
        .files = files,
        .sym_base = sym_base,
    };
    try eachSharedMember(scratch, sym_base, segs, &r, MemberDupReporter.visit);
}

// ---------------------------------------------------------------------------
// TS2433: a namespace merged with a class or function in ANOTHER file
// ---------------------------------------------------------------------------
//
// The merged value is the class/function object with the namespace's exports
// added, so the namespace block has to RUN second. Within one file the binder
// enforces that by position (TS2434, `checkNamespacePriorToMerge`); across
// files no position could fix it, and tsc says so with its own message:
//
//     // a.ts             // b.ts
//     class D { }         namespace D { export var y = "hi"; }   // TS2433
//
// tsc's `checkModuleDeclaration` runs the two arms off one lookup —
// `getFirstNonAmbientClassOrFunctionDeclaration(symbol)`, then "different
// file?" before "written earlier?" — over the MERGED symbol, which is why the
// cross-file half belongs to the linker.
//
// The rule applies at every nesting depth, not just at the global name: it is
// the namespace MEMBER tables that merge `namespace X.Y { export class Point }`
// with `namespace X.Y { export namespace Point { … } }`. So the walk descends
// through the shared exported members of every namespace that merges across
// files, which is also what bounds its cost — a name whose blocks all live in
// one file, or that is not a namespace at all, is dropped before any member
// table is touched.

/// Is this file entirely ambient? tsc's `NodeFlags.Ambient` covers a `.d.ts`
/// wholesale, and an ambient namespace is never the runtime half of a merge.
fn isDeclarationFile(pf: *const ProgFile) bool {
    return std.mem.endsWith(u8, pf.path, ".d.ts");
}

/// `declare` on the declaration itself (tsc reads the same flag through
/// `NodeFlags.Ambient`). Only the three tags the merge rule looks at.
fn declHasDeclareFlag(tree: *const Ast, decl: ast.Node) bool {
    const lhs = tree.nodeData(decl).lhs;
    const flags: u32 = switch (tree.nodeTag(decl)) {
        .function_decl => tree.extraData(ast.FnProto, lhs).flags,
        .class_decl => tree.extraData(ast.ClassData, lhs).flags,
        .namespace_decl => tree.extraData(ast.NamespaceData, lhs).flags,
        else => return false,
    };
    return flags & ast.Flags.declare != 0;
}

/// tsc's `getFirstNonAmbientClassOrFunctionDeclaration`, reduced to the only
/// thing the cross-file arm asks of it: which FILE it lives in. A function
/// needs a BODY to be the merge's runtime half — an overload signature has
/// nothing for the namespace to run after.
fn firstClassOrFunctionFile(files: []const ProgFile, sym_base: []const u32, parts: []const u32) ?FileId {
    for (parts) |p| {
        const fid = fileOfGlobal(sym_base, files.len, p);
        const pf = &files[fid];
        if (isDeclarationFile(pf)) continue;
        for (pf.bind.declsOf(p - sym_base[fid])) |decl| {
            switch (pf.tree.nodeTag(decl)) {
                .class_decl => {},
                .function_decl => if (pf.tree.nodeData(decl).rhs == 0) continue,
                else => continue,
            }
            if (declHasDeclareFlag(pf.tree, decl)) continue;
            return fid;
        }
    }
    return null;
}

/// One merged name's TS2433s: every instantiated, non-ambient namespace block
/// of it that is NOT in the file the class/function came from.
fn reportNamespaceSplitAt(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
) Error!void {
    const home = firstClassOrFunctionFile(files, sym_base, parts) orelse return;
    for (parts) |p| {
        const fid = fileOfGlobal(sym_base, files.len, p);
        if (fid == home) continue; // the binder's TS2434 owns the same-file arm
        const pf = &files[fid];
        if (isDeclarationFile(pf)) continue;
        const f = globalSymFlags(files, sym_base, p);
        if (!f.namespace_decl or f.ns_uninstantiated) continue;
        const decls = pf.bind.declsOf(p - sym_base[fid]);
        const blocks = try scratch.alloc(ast.Node, decls.len);
        var n: usize = 0;
        for (decls) |decl| {
            if (pf.tree.nodeTag(decl) != .namespace_decl) continue;
            if (declHasDeclareFlag(pf.tree, decl)) continue;
            blocks[n] = decl;
            n += 1;
        }
        if (n == 0) continue;
        try global_dup.reportAll(arena, diags, &.{.{
            .file = fid,
            .tree = pf.tree,
            .src = pf.src,
            .decls = blocks[0..n],
        }}, .namespace_split_across_files);
    }
}

/// The EXPORTED members of `parts`' namespace bodies, as segments for
/// `eachSharedMember`. Only exported names take part in the merge tsc performs
/// — a namespace local lives in its own table and meets nothing — so the
/// segments are filtered copies rather than slices of the binder's arrays.
/// Atom order survives the filter, which is what the k-way merge needs.
fn nsMemberSegs(
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
) Error![]MemberSeg {
    const segs = try scratch.alloc(MemberSeg, parts.len);
    var n: usize = 0;
    for (parts) |p| {
        const fid = fileOfGlobal(sym_base, files.len, p);
        const b = files[fid].bind;
        const scope = b.namespaceScopeOf(p - sym_base[fid]) orelse continue;
        const lo = b.scope_members_start[scope];
        const hi = b.scope_members_start[scope + 1];
        if (hi == lo) continue;
        const atoms = try scratch.alloc(Atom, hi - lo);
        const syms = try scratch.alloc(u32, hi - lo);
        var k: usize = 0;
        for (lo..hi) |i| {
            const msym = b.member_syms[i];
            if (!b.symbol_flags[msym].exported) continue;
            atoms[k] = b.member_atoms[i];
            syms[k] = msym;
            k += 1;
        }
        if (k == 0) continue;
        segs[n] = .{ .file = fid, .atoms = atoms[0..k], .syms = syms[0..k] };
        n += 1;
    }
    return segs[0..n];
}

/// Namespaces nest, so the walk does. The cap is a guard on ztsc's stack, not
/// a fact about the language: past it the remaining depths stay SILENT, which
/// is the safe direction.
const max_ns_merge_depth: u8 = 16;

/// The TS2433 walk over one merged name and everything its namespace blocks
/// export. `parts` are the contributors in merge order.
fn reportNamespaceSplit(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    parts: []const u32,
    depth: u8,
) Error!void {
    if (parts.len < 2 or depth >= max_ns_merge_depth) return;
    // Nothing here merges across files unless two contributors sit in
    // different ones — the whole-program gate that keeps this off the hot path
    // for the lib's big single-file namespaces.
    var live_ns = false;
    var multi_file = false;
    const first_file = fileOfGlobal(sym_base, files.len, parts[0]);
    for (parts) |p| {
        if (fileOfGlobal(sym_base, files.len, p) != first_file) multi_file = true;
        const f = globalSymFlags(files, sym_base, p);
        if (f.namespace_decl and !f.ns_uninstantiated) live_ns = true;
    }
    if (!live_ns or !multi_file) return;

    try reportNamespaceSplitAt(arena, scratch, diags, files, sym_base, parts);

    const segs = try nsMemberSegs(scratch, files, sym_base, parts);
    const w: NsSplitWalker = .{
        .arena = arena,
        .scratch = scratch,
        .diags = diags,
        .files = files,
        .sym_base = sym_base,
        .depth = depth,
    };
    try eachSharedMember(scratch, sym_base, segs, &w, NsSplitWalker.visit);
}

const NsSplitWalker = struct {
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    depth: u8,

    fn visit(w: *const NsSplitWalker, _: Atom, hits: []const u32) Error!void {
        try reportNamespaceSplit(w.arena, w.scratch, w.diags, w.files, w.sym_base, hits, w.depth + 1);
    }
};

/// TS2451 / TS2300 / TS2567 for a module export that an AUGMENTATION of that
/// module redeclares:
///
///     // a.d.ts                       // b.ts
///     export const conflict = 0;      declare module "./a" {
///                                         export const conflict = 0;
///                                     }
///
/// tsc's `mergeModuleAugmentation` folds the block's symbol table into the real
/// module's `exports` with `mergeSymbolTable`, so a name the module ALREADY
/// exports meets `mergeSymbol` there exactly as two global declarations of one
/// name do — same call, same verdict, same message. `mergeAugmentations` below
/// folds the pairs that MERGE (interface into interface/class, namespace into
/// namespace); this reports the pairs that do not.
///
/// The chain is (real export, then every augmenting block member in FileId
/// order), which is the order the augmentations are merged in, and both the
/// verdict and the message come from `global_dup.mergeClash` — the one
/// implementation of tsc's rule, shared with the global name merge.
///
/// Only a module-context `declare module "spec"` whose `spec` resolves to a
/// REAL file is an augmentation; a script's `declare module` is a standalone
/// ambient module (`reportAmbientMemberDups` speaks to those), and an
/// unresolved specifier declares a module of its own. A name whose export
/// target is not a plain `.binding` — a namespace object, a property of an
/// `export =` value — names no symbol whose flags could be judged, so it is
/// skipped rather than guessed at.
/// TS2649 for a `declare module "spec" { … }` block whose target module is
/// `export = <entity>` and that entity is not a namespace.
///
///     // node_modules/lib/index.d.ts        // @types/lib-extender/index.d.ts
///     declare var lib: () => void;          declare module "lib" {
///     declare namespace lib {}                  export function fn(): void;
///     export = lib;                         }
///
/// This is `mergeSymbol` again — the very arm `mergeClash` already models — one
/// table over: tsc's `mergeModuleAugmentation` folds the block's exports into
/// the module's, and the module's symbol here is what `export = lib` resolves
/// to, a `var` merged with a type-only namespace. The block carries value
/// exports, that `var` is in the way, and the target's `NamespaceModule` bit
/// picks the augment-a-non-module message over the duplicate one — at the
/// block's module NAME, which is where tsc puts `source.declarations[0]`
/// (`augmentExportEquals7`).
///
/// Only the `export =` shape can reach it: a plain ES module's own symbol is a
/// `ValueModule`, which merges with the block by definition.
fn reportAugmentNonModule(
    arena: Allocator,
    sink: DupSink,
    files: []const ProgFile,
    sym_base: []const u32,
    links: []const FileLinks,
    export_equals_atom: Atom,
) Error!void {
    if (links.len != files.len) return; // unlinked path: no export tables
    for (files, 0..) |*f, fi| {
        const b = f.bind;
        // A `declare module` is an augmentation only in a module context; in a
        // script it is a standalone ambient module and augments nothing.
        if (!b.is_module or b.ambient_modules.len == 0) continue;
        var reported_spec: Atom = 0;
        for (b.ambient_modules) |am| {
            if (am.spec == reported_spec) continue; // one report per specifier
            const mfile = f.specs.get(am.spec) orelse continue; // unresolved
            const exeq = links[mfile].exportTarget(export_equals_atom) orelse continue;
            if (exeq.kind != .binding) continue;
            const target = globalSymFlags(files, sym_base, sym_base[exeq.file] + exeq.payload);
            // The block as tsc's source symbol: a `ValueModule` when it exports
            // any value, a `NamespaceModule` (which excludes nothing, so it
            // never clashes) when it is types all the way down.
            const block: binder.SymbolFlags = .{
                .namespace_decl = true,
                .ns_uninstantiated = !blockHasValueExport(b, am),
            };
            switch (global_dup.mergeClash(&.{ target, block }) orelse continue) {
                .augment_non_module => {},
                // The plain duplicate arm names declarations on both sides and
                // is `reportAugmentationExportDups`'s per-NAME business, not
                // this whole-module one.
                .duplicate => continue,
            }
            const owner = b.scope_owners[am.scope];
            if (owner == ast.null_node or f.tree.nodeTag(owner) != .namespace_decl) continue;
            const tok = f.tree.extraData(ast.NamespaceData, f.tree.nodeData(owner).lhs).name_token;
            if (tok == 0) continue;
            const start = f.tree.tokens.start(tok);
            reported_spec = am.spec;
            try sink.diags[fi].append(arena, .{
                .code = 2649,
                .span = .{ .start = start, .end = scanner.tokenEnd(f.src, f.tree.tokens.tag(tok), start) },
                .msg = try std.fmt.allocPrint(
                    arena,
                    "Cannot augment module '{s}' with value exports because it resolves to a non-module entity.",
                    .{sink.text(am.spec)},
                ),
            });
        }
    }
}

/// Does an augmentation block export anything with a VALUE meaning? That is
/// what makes its symbol tsc's `ValueModule` rather than `NamespaceModule`.
fn blockHasValueExport(b: *const Bind, am: binder.AmbientModule) bool {
    const lo = b.scope_members_start[am.scope];
    const hi = b.scope_members_start[am.scope + 1];
    for (lo..hi) |i| {
        const f = b.symbol_flags[b.member_syms[i]];
        if (!f.exported) continue;
        if (bind_result.effectiveBits(f) & bind_result.mask_value != 0) return true;
    }
    return false;
}

fn reportAugmentationExportDups(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
    links: []const FileLinks,
    export_equals_atom: Atom,
) Error!void {
    if (links.len != files.len) return; // unlinked path: no export tables

    // real export global id → the augmenting block members redeclaring it, in
    // FileId order. Scratch-owned accumulator, dropped with the pass.
    var aug: std.AutoArrayHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    for (files, 0..) |*f, fi| {
        const b = f.bind;
        if (!b.is_module or b.ambient_modules.len == 0) continue;
        const base = sym_base[fi];
        for (b.ambient_modules) |am| {
            const mfile = f.specs.get(am.spec) orelse continue; // unresolved
            const lo = b.scope_members_start[am.scope];
            const hi = b.scope_members_start[am.scope + 1];
            for (lo..hi) |i| {
                const name = b.member_atoms[i];
                const tgt = links[mfile].exportTarget(name) orelse
                    exportEqualsMemberTarget(files, links, mfile, export_equals_atom, name) orelse
                    continue;
                if (tgt.kind != .binding) continue;
                const real = sym_base[tgt.file] + tgt.payload;
                const aug_id = base + b.member_syms[i];
                // The linker's own fallback already routes an export a block
                // ADDS back to that block; the name is then one declaration,
                // not two.
                if (real == aug_id) continue;
                const gop = try aug.getOrPut(scratch, real);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(scratch, aug_id);
            }
        }
    }
    if (aug.count() == 0) return;

    // Deterministic report order: ascending real id, as `mergeAugmentations`
    // walks its own keys.
    const keys = try scratch.alloc(u32, aug.count());
    @memcpy(keys, aug.keys());
    std.mem.sort(u32, keys, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    for (keys) |real| {
        const augs = aug.get(real).?.items;
        const parts = try scratch.alloc(u32, 1 + augs.len);
        parts[0] = real;
        @memcpy(parts[1..], augs);
        const flags = try scratch.alloc(binder.SymbolFlags, parts.len);
        for (parts, 0..) |p, i| flags[i] = globalSymFlags(files, sym_base, p);
        const code = switch (global_dup.mergeClash(flags) orelse continue) {
            .duplicate => |c| c,
            // See `reportUmdGlobalMemberDups`: TS2649 belongs to the top-level
            // global merge only.
            .augment_non_module => continue,
        };
        try reportContributors(arena, scratch, diags, files, sym_base, parts, code);
    }
}

/// The same treatment for the blocks of one AMBIENT MODULE / module
/// augmentation: `declare module "someMod" { export interface TopLevel { … } }`
/// in two files declares ONE interface `TopLevel`, whose member tables tsc
/// merges exactly as it merges a global interface's — and a member-KIND clash
/// across them is TS2300 at every declaration
/// (`duplicateIdentifierRelatedSpans6`/`7`).
///
/// The registry that would answer "which blocks share a specifier" is the
/// linker's, built much later, so the grouping is done here off sealed bind data
/// alone: specifier atom -> the blocks declaring it, in FileId order. Only a
/// specifier with 2+ blocks pays anything beyond one hash insert, and only a
/// name declared by 2+ of those blocks reaches the member walk — so the usual
/// program (whose every `declare module` names a distinct package) pays one map
/// build over its ambient blocks and stops.
///
/// Deliberately narrower than `mergeClash`: only an interface-vs-interface pair
/// is judged, matching the `folded.interface` gate on the global side. A block
/// member that clashes by KIND (`class A` in one block, `function A` in another)
/// is a different rule and stays an under-report.
fn reportAmbientMemberDups(
    arena: Allocator,
    scratch: Allocator,
    diags: []std.ArrayList(LinkDiag),
    files: []const ProgFile,
    sym_base: []const u32,
) Error!void {
    // specifier -> the (file, block scope) pairs declaring it, in FileId order.
    const Block = struct { file: FileId, scope: u32 };
    var by_spec: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(Block)) = .empty;
    var any = false;
    for (files, 0..) |*f, fi| {
        for (f.bind.ambient_modules) |am| {
            if (am.spec == 0) continue;
            const gop = try by_spec.getOrPut(scratch, am.spec);
            if (!gop.found_existing) gop.value_ptr.* = .empty else any = true;
            try gop.value_ptr.append(scratch, .{ .file = @intCast(fi), .scope = am.scope });
        }
    }
    if (!any) return;

    const InterfaceGroups = struct {
        arena: Allocator,
        scratch: Allocator,
        diags: []std.ArrayList(LinkDiag),
        files: []const ProgFile,
        sym_base: []const u32,

        /// One name declared by several blocks of the same specifier: keep the
        /// INTERFACE contributors and hand their member tables on.
        fn visit(g: *const @This(), _: Atom, hits: []const u32) Error!void {
            const ifaces = try g.scratch.alloc(u32, hits.len);
            var n: usize = 0;
            for (hits) |h| {
                if (!globalSymFlags(g.files, g.sym_base, h).interface) continue;
                ifaces[n] = h;
                n += 1;
            }
            if (n < 2) return;
            try reportMergedMemberDups(g.arena, g.scratch, g.diags, g.files, g.sym_base, ifaces[0..n]);
        }
    };
    const groups: InterfaceGroups = .{
        .arena = arena,
        .scratch = scratch,
        .diags = diags,
        .files = files,
        .sym_base = sym_base,
    };

    for (by_spec.values()) |blocks| {
        if (blocks.items.len < 2) continue;
        const segs = try scratch.alloc(MemberSeg, blocks.items.len);
        var n: usize = 0;
        for (blocks.items) |blk| {
            const b = files[blk.file].bind;
            const lo = b.scope_members_start[blk.scope];
            const hi = b.scope_members_start[blk.scope + 1];
            if (hi == lo) continue;
            segs[n] = .{ .file = blk.file, .atoms = b.member_atoms[lo..hi], .syms = b.member_syms[lo..hi] };
            n += 1;
        }
        try eachSharedMember(scratch, sym_base, segs[0..n], &groups, InterfaceGroups.visit);
    }
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
/// Walk every GLOBAL declaration of the program — each file's own script-level
/// top level first, then every `declare global { … }` augmentation block, each
/// pass in FileId order.
///
/// That order is tsc's merge order: `initializeTypeChecker` folds the
/// non-module files' locals into `globals` and only afterwards merges the
/// collected global-scope augmentations, and merge order decides precedence
/// (`mergeSymbol` keeps the target's existing value declaration, so a script's
/// `declare var expect: jest.Expect` wins the *value* over a module's `declare
/// global { const expect: … }` whichever file was loaded first). The FIRST
/// visit of a name is therefore its value winner — `parts[0]` in
/// `mergeGlobals`, and the target `indexGlobals` records. Type space is
/// unaffected either way: every constituent still folds, and interface merging
/// is an order-independent name-sorted union.
fn eachGlobalDecl(
    files: []const ProgFile,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), FileId, Atom, u32) Error!void,
) Error!void {
    for ([2]bool{ false, true }) |aug_pass| {
        for (files, 0..) |*pf, fi| {
            const b = pf.bind;
            if (b.global_atoms.len == 0) continue;
            const split = @min(b.global_aug_start, b.global_atoms.len);
            const lo = if (aug_pass) split else 0;
            const hi = if (aug_pass) b.global_atoms.len else split;
            for (b.global_atoms[lo..hi], b.global_syms[lo..hi]) |atom, local| {
                try f(ctx, @intCast(fi), atom, local);
            }
        }
    }
}

fn mergeGlobals(
    arena: Allocator,
    scratch: Allocator,
    files: []const ProgFile,
    sym_base: []const u32,
    links: []const FileLinks,
    export_equals_atom: Atom,
    /// The interned name `"default"`, or 0 for a caller with no interner. An
    /// augmenting block's `export default interface I` names the real module's
    /// DEFAULT export, not one called `I` (`mergeAugmentations`).
    default_atom: Atom,
    /// The program's `export as namespace X` declarations, sorted by name (see
    /// umd.zig). They join the global merge chain of the name they publish.
    umds: []const umd.Global,
    /// Where the cross-file duplicate declarations the merge finds
    /// (`global_dup.zig`) are filed, or null for a caller with no diagnostic
    /// surface (`buildGlobals`, which builds a table for tests/tools).
    dup_diags: ?DupSink,
) Error!GlobalMerge {
    // Accumulate name -> constituent global ids in the merge order
    // `eachGlobalDecl` documents.
    var acc: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)) = .empty;
    const Collect = struct {
        acc: *std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)),
        scratch: Allocator,
        sym_base: []const u32,
        fn visit(self: *@This(), fi: FileId, atom: Atom, local: u32) Error!void {
            const gop = try self.acc.getOrPut(self.scratch, atom);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.scratch, self.sym_base[fi] + local);
        }
    };
    var col: Collect = .{ .acc = &acc, .scratch = scratch, .sym_base = sym_base };
    try eachGlobalDecl(files, &col, Collect.visit);

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
        const linked = links.len == files.len;
        for (names, 0..) |atom, i| {
            const parts = acc.get(atom).?.items;
            const us = umd.forName(umds, atom);
            g_atoms[i] = atom;
            // A name that a UMD entry and a real declaration BOTH reach is one
            // symbol whose merge target is the module (see `umdNamespace`), so
            // it is built from the module's export index rather than from the
            // real parts alone. Every other name — including a UMD name the
            // binder harvested through its own `export = <ident>` and nothing
            // else declares — takes the plain merge.
            const chain: []const ChainLink = if (us.len == 0 or !linked)
                &.{}
            else
                try buildChain(scratch, files, sym_base, parts, us);
            g_syms[i] = if (umdMergeTarget(chain)) |uf|
                try m.umdNamespace(atom, uf, &links[uf], export_equals_atom, chainReals(scratch, chain) catch
                    return Error.OutOfMemory)
            else
                try m.mergeSet(parts);
            // tsc's `mergeSymbol` reports the failed merge as it folds; the
            // fold itself is unchanged (the merged symbol still carries the OR
            // of every contributor's flags, so a duplicate name still resolves).
            if (dup_diags) |ds| {
                try reportGlobalDup(arena, scratch, ds, files, sym_base, parts, us, atom);
                // …the same merge, judged by tsc's other cross-file rule: a
                // namespace that merges with a class or function in a
                // DIFFERENT file (TS2433), at every nesting depth.
                try reportNamespaceSplit(arena, scratch, ds.diags, files, sym_base, parts, 0);
                // …and, when the name merged INTO a module, the member tables
                // that merge with it.
                if (umdMergeTarget(chain)) |uf| {
                    try reportUmdGlobalMemberDups(arena, scratch, ds.diags, files, sym_base, &links[uf], chain);
                }
            }
        }
        globals = .{ .atoms = g_atoms, .syms = g_syms };
    }

    // The same member-kind duplicate check for the blocks of one ambient module
    // (or one module augmentation), which never pass through the global name
    // merge above: they live in their own block scopes.
    if (dup_diags) |ds| try reportAmbientMemberDups(arena, scratch, ds.diags, files, sym_base);

    // …and the export table of a real module against the `declare module
    // "spec" { … }` blocks that augment it, which is the same `mergeSymbol`
    // again — one more table, not one more rule.
    if (dup_diags) |ds| try reportAugmentationExportDups(arena, scratch, ds.diags, files, sym_base, links, export_equals_atom);

    // …and the whole-module version of the same merge: a block augmenting a
    // module whose `export =` entity is not a namespace at all.
    if (dup_diags) |ds| try reportAugmentNonModule(arena, ds, files, sym_base, links, export_equals_atom);

    // Cross-file module augmentation merge: fold a `declare module
    // "spec" { interface I { … } }` block (in a MODULE-context file) into the
    // interface `I` already exported by the real module `spec` resolves to.
    try mergeAugmentations(&m, files, sym_base, links, export_equals_atom, default_atom);

    // …and the same fold WITHIN one ambient specifier, whose blocks name no
    // real file for the pass above to key off.
    try mergeAmbientBlocks(&m, files, sym_base);

    // Finally the UMD names the merge above did not already claim.
    globals = try addUmdGlobals(arena, scratch, &m, links, export_equals_atom, globals, umds);

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

/// Publish each `export as namespace X` name as a global, unless the merge
/// already gave the name an owner — tsc's `if (!globals.has(id))`. Two modules
/// publishing one name is legal and the first wins.
///
/// What the name resolves to is the MODULE, so the entry is a synthetic
/// namespace whose members are that module's exports. The `export = <entity>`
/// shape needs none of this: the binder already harvests the entity itself as
/// the file's own global contribution (`Bind.global_atoms`), which is a better
/// answer — the real symbol, with its declarations — and is why it is already
/// in `globals` by the time this runs.
fn addUmdGlobals(
    arena: Allocator,
    scratch: Allocator,
    m: *Merger,
    links: []const FileLinks,
    export_equals_atom: Atom,
    globals: Globals,
    umds: []const umd.Global,
) Error!Globals {
    if (umds.len == 0 or links.len == 0) return globals;
    var atoms: std.ArrayListUnmanaged(Atom) = .empty;
    var syms: std.ArrayListUnmanaged(u32) = .empty;
    var prev: Atom = 0;
    for (umds) |u| {
        if (u.name == prev) continue; // first module publishing the name wins
        prev = u.name;
        if (globals.lookup(u.name) != null) continue;
        syms.append(scratch, try m.umdNamespace(u.name, u.file, &links[u.file], export_equals_atom, &.{})) catch
            return Error.OutOfMemory;
        try atoms.append(scratch, u.name);
    }
    if (atoms.items.len == 0) return globals;
    // Splice into the atom-sorted table. `umds` is name-sorted, so both inputs
    // are, and the merge is linear.
    const n = globals.atoms.len + atoms.items.len;
    const out_atoms = try arena.alloc(Atom, n);
    const out_syms = try arena.alloc(u32, n);
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const take_old = j == atoms.items.len or
            (i < globals.atoms.len and globals.atoms[i] < atoms.items[j]);
        if (take_old) {
            out_atoms[k] = globals.atoms[i];
            out_syms[k] = globals.syms[i];
            i += 1;
        } else {
            out_atoms[k] = atoms.items[j];
            out_syms[k] = syms.items[j];
            j += 1;
        }
    }
    return .{ .atoms = out_atoms, .syms = out_syms };
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
    default_atom: Atom,
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
                // `export default interface I { x }` in the block names the
                // real module's DEFAULT export, not one spelled `I` — the
                // local name is not exported at all. tsc merges the two
                // default-export symbols (`moduleAugmentationOfAlias`).
                const name = if (lf_flags.export_default and default_atom != 0)
                    default_atom
                else
                    b.member_atoms[i];
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

/// Declaration merging WITHIN one ambient module specifier. Every `declare
/// module "spec" { … }` block in the program declares the same module — tsc
/// merges the blocks' symbol tables outright — so two blocks that both declare
/// `X` are two declarations of ONE entity:
///
///     declare module "Observable" { class Observable {} }
///     declare module "Observable" { interface Observable { foo(): number } }
///
/// is the ordinary interface-into-class merge, and `import {Observable} from
/// "Observable"; x.foo()` needs it. `buildAmbient` keeps only the FIRST
/// contributor per exported name, so without this the class alone answered and
/// `foo` was a false TS2339 — moduleAugmentationInAmbientModule1-4, where the
/// augmenting block is spelled `module "Observable" { … }` NESTED inside a
/// second ambient module (`bindAmbientModule` records a nested block in
/// `ambient_modules` exactly like a top-level one, so both shapes arrive here).
///
/// `mergeAugmentations` above cannot serve: it keys off the real FILE a
/// specifier resolves to, and an ambient specifier resolves to no file at all.
///
/// The admitted shapes are that function's: the first contributor may be an
/// interface, a class or a namespace, and every later one must be an interface
/// or a namespace (interface↔interface, interface→class, namespace↔namespace).
/// Anything else is a duplicate-identifier clash rather than a merge, and
/// `reportAmbientMemberDups` is the pass that speaks to it.
fn mergeAmbientBlocks(m: *Merger, files: []const ProgFile, sym_base: []const u32) Error!void {
    const Block = struct { file: FileId, scope: u32 };
    // specifier -> the (file, block scope) pairs declaring it, in FileId order.
    var by_spec: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(Block)) = .empty;
    var any = false;
    for (files, 0..) |*f, fi| {
        for (f.bind.ambient_modules) |am| {
            if (am.spec == 0) continue;
            const gop = try by_spec.getOrPut(m.scratch, am.spec);
            if (!gop.found_existing) gop.value_ptr.* = .empty else any = true;
            try gop.value_ptr.append(m.scratch, .{ .file = @intCast(fi), .scope = am.scope });
        }
    }
    if (!any) return;

    // first contributor's real id -> the later contributors, in FileId order.
    var sets: std.AutoArrayHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    const Collect = struct {
        m: *Merger,
        sets: *std.AutoArrayHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)),

        fn visit(g: @This(), _: Atom, hits: []const u32) Error!void {
            const head = globalSymFlags(g.m.files, g.m.sym_base, hits[0]);
            if (!head.interface and !head.class and !head.namespace_decl) return;
            for (hits[1..]) |h| {
                if (h == hits[0]) continue;
                const hf = globalSymFlags(g.m.files, g.m.sym_base, h);
                if (!hf.interface and !hf.namespace_decl) continue;
                const gop = try g.sets.getOrPut(g.m.scratch, hits[0]);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(g.m.scratch, h);
            }
        }
    };
    const collect: Collect = .{ .m = m, .sets = &sets };

    for (by_spec.values()) |blocks| {
        if (blocks.items.len < 2) continue;
        const segs = try m.scratch.alloc(MemberSeg, blocks.items.len);
        var n: usize = 0;
        for (blocks.items) |blk| {
            const b = files[blk.file].bind;
            const lo = b.scope_members_start[blk.scope];
            const hi = b.scope_members_start[blk.scope + 1];
            if (hi == lo) continue;
            segs[n] = .{ .file = blk.file, .atoms = b.member_atoms[lo..hi], .syms = b.member_syms[lo..hi] };
            n += 1;
        }
        try eachSharedMember(m.scratch, sym_base, segs[0..n], collect, Collect.visit);
    }
    if (sets.count() == 0) return;

    // A real id may only ever fold into ONE merged id — `constit` is a
    // key-sorted lookup, and a second entry under the same key would answer
    // whichever the binary search landed on. `mergeAugmentations` has already
    // run, so anything it claimed is off limits here (a specifier that names a
    // real file AND carries ambient blocks is the shape that overlaps).
    var claimed: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (m.constit.items) |pr| try claimed.put(m.scratch, pr.key, {});

    // Deterministic merged-id assignment: ascending real ids, as above.
    const keys = try m.scratch.alloc(u32, sets.count());
    @memcpy(keys, sets.keys());
    std.mem.sort(u32, keys, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    for (keys) |head| {
        if (claimed.contains(head)) continue;
        const rest = sets.get(head).?.items;
        var clash = false;
        for (rest) |r| {
            if (claimed.contains(r)) clash = true;
        }
        if (clash) continue;
        const parts = try m.scratch.alloc(u32, 1 + rest.len);
        parts[0] = head;
        @memcpy(parts[1..], rest);
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
            return .{ .kind = .binding, .file = exeq.file, .payload = local, .type_only = exeq.type_only, .type_only_from_export = exeq.type_only_from_export };
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

    /// A merged-range symbol standing for the MODULE a UMD global names: a
    /// namespace whose members are the module's exports. Consumers read it
    /// through `members`, the same index a cross-file namespace merge exposes.
    ///
    /// `parts` cannot be empty — `Checker.reprSym` takes `parts[0]` to decide
    /// which FILE a merged symbol belongs to — and must not be a real
    /// declaration either, or its members would fold into the namespace on top
    /// of the export index. The one part is the module file's RESERVED DUMMY
    /// symbol (local id 0, `no_symbol`): it names the right file, carries no
    /// flags, and has no declarations, so every fold over `parts` is a no-op.
    /// It is deliberately NOT registered in `constit`: the dummy is not a
    /// constituent of anything and must keep resolving to itself.
    ///
    /// Only `.binding` exports are indexed. The rest (a namespace object, an
    /// anonymous `export default <expr>`, a property of an `export =` value)
    /// resolve to something no symbol id can name, and the reserved `export=`
    /// key is not an export name at all.
    ///
    /// `reals` are the GLOBAL declarations of the same name that merge into the
    /// UMD entry — empty for a name nothing else declares. tsc's `mergeSymbol`
    /// resolves the UMD alias before merging, so the module is the merge
    /// TARGET: it keeps `parts[0]` (and with it the file the merged symbol
    /// reports as its own), its export wins a name collision, and the real
    /// declarations fold in for their flags and declarations.
    fn umdNamespace(
        m: *Merger,
        name: Atom,
        file: FileId,
        l: *const FileLinks,
        export_equals_atom: Atom,
        reals: []const u32,
    ) Error!u32 {
        var atoms: std.ArrayListUnmanaged(Atom) = .empty;
        var syms: std.ArrayListUnmanaged(u32) = .empty;
        for (l.export_atoms, l.export_targets) |a, t| {
            if (a == export_equals_atom or t.kind != .binding) continue;
            try atoms.append(m.scratch, a);
            try syms.append(m.scratch, m.sym_base[t.file] + t.payload);
        }
        // Built before this symbol's own id so nested merged ids sit below it,
        // the ordering `mergeSet` keeps.
        var members: Globals = .{
            // `export_atoms` is already atom-sorted, so the filtered copy is.
            .atoms = try m.arena.dupe(Atom, atoms.items),
            .syms = try m.arena.dupe(u32, syms.items),
        };
        var flags: binder.SymbolFlags = .{ .namespace_decl = true };
        if (reals.len != 0) {
            members = try m.unionMembers(members, try m.buildNsMembers(reals));
            for (reals) |p| flags = binder.SymbolFlags.merge(flags, globalSymFlags(m.files, m.sym_base, p));
        }
        const parts = try m.arena.alloc(u32, 1 + reals.len);
        parts[0] = m.sym_base[file];
        @memcpy(parts[1..], reals);
        const id = m.totalSyms() + @as(u32, @intCast(m.merged.items.len));
        try m.merged.append(m.arena, .{
            .name = name,
            .flags = flags,
            .parts = parts,
            .members = members,
        });
        // The dummy `parts[0]` is deliberately absent: it is not a constituent
        // of anything and must keep resolving to itself.
        for (reals) |p| try m.constit.append(m.scratch, .{ .key = p, .val = id });
        return id;
    }

    /// Two atom-sorted member indexes as one, `a` winning a shared name. The
    /// merge target's table is `a`, matching tsc's `mergeSymbolTable`, which
    /// leaves the target's entry in place (and reports) when the source has
    /// the same name.
    fn unionMembers(m: *Merger, a: Globals, b: Globals) Error!Globals {
        if (b.atoms.len == 0) return a;
        if (a.atoms.len == 0) return b;
        const atoms = try m.arena.alloc(Atom, a.atoms.len + b.atoms.len);
        const syms = try m.arena.alloc(u32, atoms.len);
        var i: usize = 0;
        var j: usize = 0;
        var k: usize = 0;
        while (i < a.atoms.len or j < b.atoms.len) {
            const take_a = j == b.atoms.len or (i < a.atoms.len and a.atoms[i] <= b.atoms[j]);
            if (take_a) {
                if (j < b.atoms.len and b.atoms[j] == a.atoms[i]) j += 1; // target wins
                atoms[k] = a.atoms[i];
                syms[k] = a.syms[i];
                i += 1;
            } else {
                atoms[k] = b.atoms[j];
                syms[k] = b.syms[j];
                j += 1;
            }
            k += 1;
        }
        return .{ .atoms = atoms[0..k], .syms = syms[0..k] };
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
    /// Keyed by the blocks a SCRIPT declared — the ones that bring a module
    /// into existence, as opposed to the ones in a module file (or nested in
    /// another ambient module), which tsc reads as AUGMENTATIONS of a module
    /// that has to exist already (`isModuleAugmentationExternal`). An
    /// augmentation contributes members to an existing key and never mints
    /// one; see `buildAmbient`.
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
    /// Every GLOBAL declaration name -> the `.binding` target of its
    /// value-winning contributor. Built by `indexGlobals` before any export
    /// table, so `export { x }` naming a global resolves rather than
    /// reporting TS2304. Scratch-only: the sealed `Program` carries the full
    /// merged `Globals` table instead.
    global_decls: std.AutoHashMapUnmanaged(Atom, Target) = .empty,
    /// Backing store for `.dual` targets (`Target.payload` indexes it).
    /// Append-only; sealed into the arena at the end of `link`.
    duals: std.ArrayListUnmanaged(DualTarget) = .empty,
    /// `export { X } from "m"` records whose `X` was not in m's export table
    /// when that table was built, in statement order. Their lookup — and their
    /// TS2305/TS2459/TS2724 — are settled by `resolvePendingReexports`, once
    /// every star merge has run. See the `reexport_named` arm of `table`.
    pending_reexports: std.ArrayListUnmanaged(PendingReexport) = .empty,
    /// TS2595 questions the checker has to finish (`EqDefaultImport`). Filled
    /// out of order — `table` walks re-exports and `linkImports` walks imports,
    /// each in its own file sweep — and sorted by `(file, span.start)` at the
    /// seal, so `Program.eqDefaultImportsOf` can bracket one file's run.
    eq_default_imports: std.ArrayListUnmanaged(program.EqDefaultImport) = .empty,

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

    /// The name `mfile` exports `local_sym` UNDER, when that is not the
    /// declaration's own name — tsc's `find(symbolsToArray(exports), s =>
    /// getSymbolIfSameReference(s, localSymbol))`, which turns "declares it
    /// locally" into "declares it locally, but exports it as …". Table order
    /// is insertion order, so the first `export { bar as baz }` wins, as it
    /// does there. The reserved `export=`/`default` keys are skipped: neither
    /// is a name the author could have written in the import's braces.
    fn exportNameOfLocal(l: *Linker, mfile: FileId, local_sym: u32) ?Atom {
        const t = l.table(mfile) catch return null;
        var it = t.iterator();
        while (it.next()) |e| {
            const a = e.key_ptr.*;
            if (a == l.atom_default or a == l.atom_export_equals) continue;
            const tgt = e.value_ptr.*;
            if (tgt.kind == .binding and tgt.file == mfile and tgt.payload == local_sym) return a;
        }
        return null;
    }

    /// The "no such named export" family, in tsc's own order
    /// (`getExternalModuleMember`'s error tail):
    ///
    ///   1. TS2724 when a close export NAME exists — a misspelling outranks
    ///      everything, because the name the author meant is right there;
    ///   2. TS2614 when the module has a DEFAULT export — "did you mean
    ///      `import X from "m"`?", the mistake an ES-module author makes
    ///      against a `export default` module, and tsc offers it whether or
    ///      not the name also happens to be declared locally;
    ///   3. TS2460/TS2459 when the module DECLARES the name at its top level
    ///      (tsc's `reportNonExportedMember`) — TS2460 when some export of the
    ///      module names that very declaration under a DIFFERENT name
    ///      (`declare function bar(); export { bar as baz }`), TS2459 when it
    ///      is not exported at all;
    ///   4. TS2305 otherwise.
    fn diagNoExportedMember(l: *Linker, file: FileId, mfile_opt: ?FileId, module: Atom, name: Atom, span: Span) Error!void {
        if (mfile_opt) |mfile| {
            const sugg = try l.moduleExportSuggestion(mfile, name);
            if (sugg != 0) {
                try l.diag(file, 2724, span, "'\"{s}\"' has no exported member named '{s}'. Did you mean '{s}'?", .{
                    l.atomText(module), l.atomText(name), l.atomText(sugg),
                });
                return;
            }
            if (l.table(mfile) catch null) |et| {
                if (et.contains(l.atom_default)) {
                    try l.diag(file, 2614, span, "Module '\"{s}\"' has no exported member '{s}'. Did you mean to use 'import {s} from \"{s}\"' instead?", .{
                        l.atomText(module), l.atomText(name), l.atomText(name), l.atomText(module),
                    });
                    return;
                }
            }
            const mb = l.files[mfile].bind;
            if (mb.is_module) {
                if (mb.lookupInScope(binder.file_scope, name)) |local_sym| {
                    if (!mb.symbol_flags[local_sym].import_binding) {
                        if (l.exportNameOfLocal(mfile, local_sym)) |as_name| {
                            try l.diag(file, 2460, span, "Module '\"{s}\"' declares '{s}' locally, but it is exported as '{s}'.", .{
                                l.atomText(module), l.atomText(name), l.atomText(as_name),
                            });
                            return;
                        }
                        try l.diag(file, 2459, span, "Module '\"{s}\"' declares '{s}' locally, but it is not exported.", .{
                            l.atomText(module), l.atomText(name),
                        });
                        return;
                    }
                }
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

    /// Index every GLOBAL declaration name to the `(file, local)` of its
    /// value-winning contributor (see `eachGlobalDecl` for the order). Reads
    /// only sealed per-file bind data, so it runs before any export table —
    /// which is what an `export { x }` naming a global needs.
    fn indexGlobals(l: *Linker) Error!void {
        const Index = struct {
            l: *Linker,
            fn visit(self: *@This(), fi: FileId, atom: Atom, local: u32) Error!void {
                const gop = try self.l.global_decls.getOrPut(self.l.scratch, atom);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .kind = .binding, .file = fi, .payload = local };
                }
            }
        };
        var idx: Index = .{ .l = l };
        try eachGlobalDecl(l.files, &idx, Index.visit);
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

    /// TS2661, tsc's `checkExportSpecifier` tail: an `export { X }` with no
    /// module specifier whose name resolves to a declaration of a GLOBAL
    /// source file cannot export it — the specifier form re-exports a
    /// module-local, and a global is not one.
    ///
    ///     // a.d.ts (a script — its top level IS the global scope)
    ///     declare class X {}
    ///     // b.ts
    ///     export { X };   // TS2661
    ///
    /// `is_global` is the caller's verdict, because the two arms know it
    /// differently: a name with no local symbol that the program's global
    /// table answered is global by construction, while a resolved local is
    /// global exactly when its own scope is the file scope of a SCRIPT (a
    /// module's file scope is module-local — `export { x }` next to
    /// `let x` is the ordinary form and must stay silent).
    ///
    /// Restricted to a genuine `export_specifier` node: a `.named` record is
    /// also how `export var x` is recorded, and tsc's check is on the
    /// specifier syntax alone. Reported at the specifier's own name token,
    /// which is `propertyName || name` — `export { x, x as y }` answers twice.
    fn reportGlobalExportSpecifier(l: *Linker, file: FileId, rec: binder.ExportRec, is_global: bool) Error!void {
        if (!is_global or rec.module != 0) return;
        const tree = l.files[file].tree;
        if (tree.nodeTag(rec.node) != .export_specifier) return;
        try l.diag(file, 2661, l.tokSpan(file, tree.nodeMainToken(rec.node)), "Cannot export '{s}'. Only local declarations can be exported from a module.", .{l.atomText(rec.local)});
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
                        try l.reportGlobalExportSpecifier(file, rec, f.bind.symbol_scopes[rec.sym] == binder.file_scope and !f.bind.is_module);
                        const tgt = try l.finalizeLocal(file, rec.sym, rec.local, .exported(rec.type_only), 0);
                        try l.put(t, rec.exported, tgt);
                    } else if (rec.local != 0) {
                        // A module may re-export a GLOBAL: `declare var x` in
                        // a script, `export { x }` in a module. The name has
                        // no local symbol here, and tsc's `resolveName` walks
                        // on into the global table rather than reporting
                        // TS2304.
                        if (l.global_decls.get(rec.local)) |tgt| {
                            try l.reportGlobalExportSpecifier(file, rec, true);
                            try l.put(t, rec.exported, tgt);
                        } else {
                            try l.diag(file, 2304, l.nodeSpan(file, rec.node), "Cannot find name '{s}'.", .{l.atomText(rec.local)});
                        }
                    }
                },
                .default => {
                    if (rec.sym != binder.no_symbol) {
                        // Through `finalizeLocal` so `import X from "m"; export
                        // default X;` follows the chain to m's export rather
                        // than stopping at the local import binding.
                        try l.put(t, rec.exported, try l.finalizeLocal(file, rec.sym, rec.local, .exported(rec.type_only), 0));
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
                            found = try l.exportEqualsMeanings(exeq, rec.local);
                            try l.noteEqDefaultImport(file, l.nodeSpan(file, rec.node), rec.local, found);
                            if (found == null) found = .{ .kind = .any };
                        }
                    }
                    if (found) |tgt| {
                        var final = tgt;
                        final.markTypeOnly(.exported(rec.type_only));
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
                        try l.put(t, rec.exported, .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only, .type_only_from_export = true });
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
                            tgt = try l.finalizeLocal(file, ls, rec.local, .none, 0);
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
        //
        // TS2308 rides along: tsc builds the star merge in a table of its own
        // (`nestedSymbols`) precisely so it can tell a name two stars disagree
        // about from one the module also declares itself. `own_exports` is that
        // distinction here — the table is insertion-ordered, so everything pass
        // 1 put in it sits below that mark.
        const own_exports = t.count();
        var star_first: std.AutoArrayHashMapUnmanaged(Atom, StarSource) = .empty;
        defer star_first.deinit(l.scratch);
        var star_dups: std.ArrayList(StarDup) = .empty;
        defer star_dups.deinit(l.scratch);
        for (f.bind.exports) |rec| {
            if (rec.kind != .reexport_all) continue;
            const mfile = f.specs.get(rec.module) orelse continue;
            if (mfile == file) continue;
            const mt = try l.table(mfile);
            for (mt.keys(), mt.values()) |name, tgt| {
                if (name == l.atom_default or name == l.atom_export_equals) continue;
                const gop = try star_first.getOrPut(l.scratch, name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .node = rec.node, .target = tgt };
                } else if (!sameStarTarget(gop.value_ptr.target, tgt)) {
                    try star_dups.append(l.scratch, .{ .name = name, .node = rec.node });
                }
                _ = try l.starPutFile(t, name, tgt, rec.type_only);
            }
        }
        try l.reportStarCollisions(file, t, own_exports, &star_first, star_dups.items);

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
                    try l.put(t, name, try l.finalizeLocal(afile, local, name, .none, 0));
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
        // tsc runs this from `checkExternalModuleExports`, which it calls for an
        // external module's SourceFile and for an ambient module declaration —
        // never for a plain block. `moduleElementsInWrongContext` writes the
        // whole module-element zoo, `export = M` included, inside `{ … }`: the
        // file is not an external module, so tsc's walk never reaches it and
        // ztsc's file-wide scan invented a TS2309 on top of the TS1231 family
        // that shape really earns.
        const ambient_scope = for (b.ambient_modules) |am| {
            if (am.scope == scope) break true;
        } else false;
        if (!ambient_scope and !(scope == binder.file_scope and b.is_module)) return;
        var has_company = false;
        for (b.exports) |other| {
            if (other.scope != scope) continue;
            switch (other.kind) {
                .default => has_company = true,
                .named => has_company = has_company or (other.module == 0 and
                    other.sym != binder.no_symbol and b.symbol_flags[other.sym].hasValue()),
                else => {},
            }
        }
        // A declaration carrying the `export` MODIFIER files no export record at
        // all — the binder marks the symbol instead — so an ambient block's
        // members have to be read directly: `export namespace a { … }` beside
        // `export = c` is `incompatibleExports1`. Only for a block, whose member
        // list is exactly its exports; a file scope holds every local as well.
        if (!has_company and ambient_scope) {
            const lo = b.scope_members_start[scope];
            const hi = b.scope_members_start[scope + 1];
            for (lo..hi) |i| {
                const f = b.symbol_flags[b.member_syms[i]];
                if (!f.exported) continue;
                // An `export import a = x.c` counts only when the alias TARGET
                // has a value meaning: tsc resolves it and judges that, and
                // `importDeclWithExportModifierAndExportAssignmentInAmbientContext`
                // — an alias to an interface, beside `export = x` — is silent
                // while the same shape over a value namespace is TS2309
                // (measured both ways). The link phase resolves no alias here,
                // so one is skipped outright: an under-report on the value half
                // and no false report on the type half. `effectiveBits` covers
                // the other type-only shape, a non-instantiated namespace.
                if (bind_result.effectiveBits(f) & bind_result.mask_value &
                    ~bind_result.fbits(.{ .import_binding = true }) == 0) continue;
                has_company = true;
                break;
            }
        }
        if (!has_company) return;
        try l.diag(file, 2309, l.nodeSpan(file, node), "An export assignment cannot be used in a module with other exported elements.", .{});
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
                    var t = try l.finalizeLocal(exeq.file, member_local, name, exeq.typeOnly(), 0);
                    t.markTypeOnly(exeq.typeOnly());
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
                    var t = try l.finalizeLocal(exeq.file, ls, rec.local, TypeOnly.exported(rec.type_only).under(exeq.typeOnly()), 0);
                    t.markTypeOnly(exeq.typeOnly());
                    return t;
                }
                return null;
            },
            .namespace => {
                if (try l.lookupExport(exeq.file, name, 0)) |t| {
                    var final = t;
                    final.markTypeOnly(exeq.typeOnly());
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

    /// Park the TS2595 question for `import { name } from "m"` / `export {
    /// name } from "m"` when `m` is `export = <entity>` and the entity IS the
    /// thing called `name` — tsc's `reportInvalidImportEqualsExportMember`,
    /// reached from `getExternalModuleMember` when neither the entity's members
    /// nor the module's exports produced a symbol.
    ///
    /// `found` is what `exportEqualsMeanings` answered: anything other than a
    /// bare `.export_equals_prop` means a MEMBER was found (tsc's
    /// `symbolFromModule`), which settles the import and reports nothing. The
    /// remaining half — does the export-assigned value's type carry a property
    /// of that name (`class Foo { static Foo }` does) — needs a type, so it
    /// travels to `checker/export_equals_import.zig` with the specifier's span.
    ///
    /// The identity test is tsc's `getSymbolIfSameReference(exportEquals,
    /// locals.get(name))`, in the only spelling the link phase can be sure of:
    /// the export-assigned declaration is itself named `name`. An entity
    /// reached through an alias chain (`export = someNs.Foo`) is left alone —
    /// its declaration is not one of `m`'s locals, which is exactly when tsc
    /// takes a different branch.
    fn noteEqDefaultImport(l: *Linker, file: FileId, span: Span, name: Atom, found: ?Target) Error!void {
        const t = found orelse return;
        if (t.kind != .export_equals_prop) return;
        const b = l.files[t.file].bind;
        if (t.payload >= b.symbol_names.len or b.symbol_names[t.payload] != name) return;
        try l.eq_default_imports.append(l.scratch, .{
            .file = file,
            .span = span,
            .name = name,
            .sym_file = t.file,
            .sym = t.payload,
        });
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
            .type_only_from_export = m.type_only_from_export,
        };
    }

    /// The declaration SPACES an export Target answers in, or null when the
    /// link phase cannot say (an alias, whose spaces are its target's, and
    /// every non-declaration kind). A module namespace object is tsc's
    /// `ValueModule | NamespaceModule`: value and namespace, never type.
    fn targetSpaces(l: *Linker, tgt: Target) ?decl_spaces.Spaces {
        switch (tgt.kind) {
            .binding => {
                const f = &l.files[tgt.file];
                const decls = f.bind.declsOf(tgt.payload);
                if (decls.len == 0) return null;
                var s: decl_spaces.Spaces = .{};
                for (decls) |d| s = s.merge(decl_spaces.ofTag(f.tree.nodeTag(d)) orelse return null);
                return s;
            },
            .namespace, .ambient_ns => return .{ .value = true, .namespace = true },
            else => return null,
        }
    }

    /// Two exports of the same NAME whose declaration spaces are disjoint are
    /// ONE symbol in tsc, carrying both — the export table's half of
    /// declaration merging:
    ///
    ///     export type Drink = 0 | 1;             // type space
    ///     export * as Drink from "./constants";  // value/namespace space
    ///
    /// so a consumer's `const x: Drink = Drink.TEA` reads the alias in type
    /// position and the module namespace object in value position. A plain
    /// overwrite kept only the later declaration, and the *type* meaning it
    /// dropped is exactly what a namespace-in-type-position diagnostic would
    /// then misfire on (see `materializeTypeRef`'s TS2709 arm) — a collapse and
    /// a genuine namespace-only export were indistinguishable.
    ///
    /// Null when the two share a space (the later declaration wins outright,
    /// as before) or when either side is a kind `targetSpaces` declines.
    fn dualMerge(l: *Linker, old: Target, new: Target) Error!?Target {
        const os = targetSpaces(l, old) orelse return null;
        const ns = targetSpaces(l, new) orelse return null;
        if (decl_spaces.conflict(os, ns).any()) return null;
        const val: Target, const typ: Target = if (os.value and ns.type_)
            .{ old, new }
        else if (ns.value and os.type_)
            .{ new, old }
        else
            return null;
        try l.duals.append(l.scratch, .{ .value_tgt = val, .type_tgt = typ });
        return .{
            .kind = .dual,
            .payload = @intCast(l.duals.items.len - 1),
            .name = val.name,
            // Both halves are real declarations here (unlike the `export =`
            // dual, whose value half is a property probe), so the entry is
            // type-only only when neither meaning survives a value use.
            .type_only = val.type_only and typ.type_only,
            .type_only_from_export = val.type_only_from_export,
        };
    }

    fn put(l: *Linker, t: *std.AutoArrayHashMapUnmanaged(Atom, Target), name: Atom, tgt: Target) Error!void {
        // Later explicit exports of the same name overwrite (duplicate
        // export names are a bind-phase diagnostic concern, not ours) —
        // unless the two carry disjoint meanings, which tsc merges. One
        // `getOrPut` rather than a probe plus a store: `put` runs once per
        // export of every file in the program, and the collision it looks for
        // is rare.
        const gop = try t.getOrPut(l.scratch, name);
        gop.value_ptr.* = if (gop.found_existing)
            (try l.dualMerge(gop.value_ptr.*, tgt)) orelse tgt
        else
            tgt;
    }

    /// Final target of export-table lookup `name` in `file`.
    fn lookupExport(l: *Linker, file: FileId, name: Atom, depth: u32) Error!?Target {
        if (depth > visit_limit) return null;
        const t = try l.table(file);
        return t.get(name);
    }

    /// Final target of a local symbol used as an export: follow import
    /// bindings to their defining module.
    /// Whether `local_sym` is declared by an entity-name `import X = A.B`
    /// (as opposed to `import X = require("m")`, which has an import record).
    fn isEntityImportEquals(f: *const ProgFile, local_sym: u32) bool {
        for (f.bind.declsOf(local_sym)) |decl| {
            if (f.tree.nodeTag(decl) != .import_equals) continue;
            const e = f.tree.extraData(ast.ImportEquals, f.tree.nodeData(decl).lhs);
            return e.module_token == 0 and e.entity != ast.null_node;
        }
        return false;
    }

    /// `type_only` is the mark the DECLARATION THAT NAMED THIS LOCAL carries —
    /// the export specifier a caller is resolving, or the `export =` target it
    /// came through. That declaration sits between the use site and the import
    /// binding this walk is about to follow, so it is the NEARER hop and its
    /// mark layers over everything found below (`TypeOnly.under`).
    fn finalizeLocal(l: *Linker, file: FileId, local_sym: u32, local_atom: Atom, type_only: TypeOnly, depth: u32) Error!Target {
        if (depth > visit_limit) return .{ .kind = .any };
        const f = &l.files[file];
        const flags = f.bind.symbol_flags[local_sym];
        if (!flags.import_binding) {
            return .{ .kind = .binding, .file = file, .payload = local_sym, .type_only = type_only.on, .type_only_from_export = type_only.from_export };
        }
        // An alias MERGED with a real declaration of the same name is not a
        // re-export of its target: tsc's export specifier names the local
        // symbol, which carries both meanings, and a use of it resolves
        // through whichever declaration the use's meaning selects.
        //
        //     // a.ts                 // b.ts
        //     interface A {}          import { A } from "./a";
        //     export type { A };      const A = 0;
        //                             export { A };
        //
        // Following the alias here published b's `A` as a type-only export, so
        // `import { A } from "./b"; A;` was TS2693 (`typeOnlyMerge1`,
        // `exportNamespace9`) and `typeof import("./b")` was missing the
        // member outright (`namespaceImportTypeQuery2`). Targeting the local
        // symbol keeps BOTH meanings reachable — the checker follows the alias
        // itself for the half the local declaration does not carry.
        //
        // The TYPE half is the mirror image, and needs the same answer:
        //
        //     // a.ts                              // index.ts
        //     import * as B from "./b";            import { B } from "./a";
        //     interface B { x: string }            const x: B = { x: "" };
        //     export { B };                        B.zzz;
        //
        // Following the alias published a's `B` as the module NAMESPACE alone,
        // so the annotation resolved to a namespace and earned a phantom
        // TS2709 (`noCrashOnImportShadowing`).
        if (bind_result.effectiveBits(flags) & (bind_result.mask_value | bind_result.mask_type) &
            ~bind_result.fbits(.{ .import_binding = true }) != 0)
        {
            return .{ .kind = .binding, .file = file, .payload = local_sym, .type_only = type_only.on, .type_only_from_export = type_only.from_export };
        }
        // An ENTITY-NAME `import X = A.B` is an import binding with no import
        // record — it names something already in the program, so there is no
        // module for the linker to follow and the loop below would fall out to
        // `any`. Target the alias DECLARATION instead and let the checker
        // resolve the entity (`importEqualsEntityContainer`), which is where
        // scope-sensitive name resolution lives. preact's jsx-runtime exports
        // its whole `JSX` namespace as `export import JSX = JSXInternal`.
        if (isEntityImportEquals(f, local_sym)) {
            return .{ .kind = .binding, .file = file, .payload = local_sym, .type_only = type_only.on, .type_only_from_export = type_only.from_export };
        }
        // Find the import record that created this binding. Matched on scope
        // as well as name: a `declare module` block's imports are records too,
        // and one of them may shadow a file-scope name.
        for (f.bind.imports) |rec| {
            if (rec.local != local_atom) continue;
            if (rec.scope != f.bind.symbol_scopes[local_sym]) continue;
            // The import record is one hop FARTHER from the use site than
            // whatever named this local, so its `import type` mark only lands
            // when the nearer declaration carried none.
            const t_only = TypeOnly.imported(rec.type_only).under(type_only);
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
                var tgt: Target = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?) };
                if (l.ambient.getPtr(key).?.get(l.atom_export_equals)) |exeq| {
                    if (exeq.kind != .any) tgt = exeq;
                }
                tgt.markTypeOnly(t_only);
                return tgt;
            }
            const mfile = f.specs.get(rec.module) orelse return .{ .kind = .any };
            switch (rec.kind) {
                .namespace => return .{ .kind = .namespace, .file = mfile, .type_only = t_only.on, .type_only_from_export = t_only.from_export },
                .named, .default => {
                    if (try l.lookupExport(mfile, rec.imported, depth + 1)) |tgt| {
                        var final = tgt;
                        final.markTypeOnly(t_only);
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
                            final.markTypeOnly(t_only);
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
                        final.markTypeOnly(t_only);
                        return final;
                    }
                    return .{ .kind = .namespace, .file = mfile, .type_only = t_only.on, .type_only_from_export = t_only.from_export };
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
        //
        // Only an AUGMENTATION-FREE block seeds a key, i.e. exactly the blocks
        // tsc's `bindModuleDeclaration` puts in `globals` (and in
        // `patternAmbientModules`). tsc's `isModuleAugmentationExternal` calls
        // a top-level `declare module "X"` an *augmentation* whenever its file
        // is a module, and a NESTED one whenever its container is an ambient
        // module — `declare module "Map" { module "Observable" { … } }`. Both
        // are declared into the FILE's locals, never into `globals`, and
        // `mergeModuleAugmentation` then resolves the name and gives up
        // silently when nothing answers: an augmentation never brings a module
        // into existence. So such a block still CONTRIBUTES members to a key a
        // script declared (which is what moduleAugmentationInAmbientModule 1-4
        // need, alongside `mergeAmbientBlocks`), but a specifier only
        // augmentations name stays unknown, and an import of it is TS2307
        // (`ambientExternalModuleInAnotherExternalModule`) — while the
        // augmentation itself earns TS2664 from `reportAugmentationName`.
        for (l.files) |*f| {
            if (f.bind.is_module) continue;
            for (f.bind.ambient_modules) |am| {
                if (f.bind.scope_parents[am.scope] != binder.file_scope) continue;
                const gop = try l.ambient.getOrPut(l.scratch, am.spec);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
            }
        }
        for (l.files, 0..) |*f, fi| {
            const fid: FileId = @intCast(fi);
            const b = f.bind;
            for (b.ambient_modules) |am| {
                const tbl = l.ambient.getPtr(am.spec) orelse continue;

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
                    try tbl.put(l.scratch, name, try l.finalizeLocal(fid, local, name, .none, 0));
                }

                // `export default …` / `export { a, b }` forms (which carry no
                // `exported` flag): resolve each in the block scope.
                for (b.exports[am.export_start..am.export_end]) |rec| {
                    switch (rec.kind) {
                        .default => {
                            if (tbl.contains(l.atom_default)) continue;
                            var tgt: Target = .{ .kind = .default_expr, .file = fid, .payload = rec.node };
                            if (rec.sym != binder.no_symbol) {
                                tgt = try l.finalizeLocal(fid, rec.sym, rec.local, .exported(rec.type_only), 0);
                            } else if (rec.local != 0) {
                                if (b.lookupInScope(am.scope, rec.local)) |ls| {
                                    tgt = try l.finalizeLocal(fid, ls, rec.local, .exported(rec.type_only), 0);
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
                            try tbl.put(l.scratch, rec.exported, try l.finalizeLocal(fid, ls, rec.local, .exported(rec.type_only), 0));
                        },
                        .equals => {
                            // `declare module "m" { export = X }`: store the
                            // export entity under the reserved key. Makes the
                            // module non-opaque so imports resolve through it.
                            if (tbl.contains(l.atom_export_equals)) continue;
                            var tgt: Target = .{ .kind = .any };
                            if (rec.local != 0) {
                                // The entity is routinely declared OUTSIDE the
                                // block: `declare namespace __React { … }
                                // declare module "react" { export = __React }`
                                // is the shape of every UMD typing in the
                                // ecosystem, and the block-scope lookup alone
                                // never finds it — the reserved key stored
                                // `any`, so `React.Component` resolved to
                                // nothing and `class X extends React.Component`
                                // inherited zero members.
                                //
                                // A file-scope fallback is the whole walk that
                                // is needed: `buildAmbient` only visits blocks
                                // whose parent scope IS the file scope (a
                                // nested block is an augmentation and seeds no
                                // specifier), so there is no third scope
                                // between the two. `export as namespace X`
                                // resolves its own entity the same way
                                // (`Bind.umd_sym`).
                                const found = b.lookupInScope(am.scope, rec.local) orelse
                                    b.lookupInScope(binder.file_scope, rec.local);
                                if (found) |ls| tgt = try l.finalizeLocal(fid, ls, rec.local, .none, 0);
                            }
                            try tbl.put(l.scratch, l.atom_export_equals, tgt);
                        },
                        else => {}, // `export *`: second pass, below
                    }
                }
            }
        }

        try l.mergeAmbientReexports();
    }

    /// The `… from "other"` export forms inside a `declare module "spec" { … }`
    /// block: `export * from`, `export { a, b } from`, `export * as ns from`.
    ///
    /// The star's source is usually ANOTHER ambient module declared in the same
    /// `.d.ts`: `transformation-matrix`'s typings are one script holding a
    /// `declare module` per entry point plus a final `declare module
    /// 'transformation-matrix'` block that stars them all back into the package
    /// root — so `import { compose, identity } from 'transformation-matrix'`
    /// reaches names no block of that specifier declares itself. Without this
    /// every such name was TS2305.
    ///
    /// The NAMED form matters just as much and used to be dropped whole (the
    /// record kind fell off the end of `buildAmbient`'s switch). social-app's
    /// `declare module 'expo-image-manipulator' { export { manipulateAsync } from
    /// 'expo-image-manipulator/build/ImageManipulator'; … }` — an ambient block
    /// that restates a package's surface — exported only its one directly
    /// declared `const`, so every other name it names was TS2305 at each import.
    ///
    /// Runs after `buildAmbient` has placed every block's own members, so a
    /// re-export never races the block it names, and iterates so a chain of them
    /// settles. Same rules as the file-level merges: a star carries neither
    /// `default` nor the reserved `export=` key, and the first contributor of a
    /// name wins — which keeps a block's own declaration ahead of any re-export,
    /// and orders the re-exports among themselves by record (source) order.
    /// Order-invariant: the fixed point does not depend on file visit order,
    /// since every round only *adds* names no round could have taken
    /// differently. A name the source does not (yet) have is simply not put, so
    /// a later round can still find it and today's TS2305-at-the-import stands
    /// for a name no round ever resolves.
    fn mergeAmbientReexports(l: *Linker) Error!void {
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
                        switch (rec.kind) {
                            .reexport_all => {
                                // tsc's precedence: for a non-relative specifier
                                // an exactly-named ambient module outranks the
                                // resolved file, which `effectiveModuleFile`
                                // already encodes.
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
                                // Snapshot: the put below may grow the
                                // destination table, and only the source's
                                // entries are read.
                                const src = l.ambient.values()[src_idx];
                                for (src.keys(), src.values()) |name, tgt| {
                                    if (try l.starPut(dst_idx, name, tgt, rec.type_only)) changed = true;
                                }
                            },
                            .reexport_named => {
                                if (l.ambient.values()[dst_idx].contains(rec.exported)) continue;
                                if (try l.ambientReexportTarget(f, rec, dst_idx)) |tgt| {
                                    var final = tgt;
                                    final.markTypeOnly(.exported(rec.type_only));
                                    try l.ambient.values()[dst_idx].put(l.scratch, rec.exported, final);
                                    changed = true;
                                }
                            },
                            .reexport_ns => {
                                if (l.ambient.values()[dst_idx].contains(rec.exported)) continue;
                                const tgt = try l.ambientNamespaceTarget(f, rec);
                                try l.ambient.values()[dst_idx].put(l.scratch, rec.exported, tgt);
                                changed = true;
                            },
                            else => {}, // placed by `buildAmbient`'s first pass
                        }
                    }
                }
            }
            if (!changed) break;
        }
    }

    /// One `export { local as exported } from "module"` inside an ambient block:
    /// the target `exported` should name, or null when the source cannot answer
    /// it *yet* (a later round may, and a name no round resolves stays absent so
    /// the import's own TS2305 still lands).
    ///
    /// The source arms mirror `table`'s `.reexport_named`: a resolved file is
    /// read through its export table, with the `export =` namespace-member
    /// fallback that keeps a CommonJS-shaped or synthetic-`any` module from
    /// being accused of a missing member; an ambient source is read out of the
    /// registry, and an ambient source with no ES-style exports at all is
    /// opaque, so every name off it degrades to `any` exactly as an import of it
    /// would (`ambientOpaque`). A specifier nothing answers is `any` too — its
    /// TS2307 is reported at the statement.
    fn ambientReexportTarget(l: *Linker, f: *const ProgFile, rec: binder.ExportRec, dst_idx: usize) Error!?Target {
        if (try l.effectiveModuleFile(f, rec.module)) |mfile| {
            if (try l.lookupExport(mfile, rec.local, 0)) |t| return t;
            if (try l.lookupExport(mfile, l.atom_export_equals, 0)) |exeq| {
                return (try l.exportEqualsMeanings(exeq, rec.local)) orelse .{ .kind = .any };
            }
            return null;
        }
        const src_key = l.ambientKey(rec.module) orelse return .{ .kind = .any };
        const src_idx = l.ambient.getIndex(src_key).?;
        if (src_idx == dst_idx) return null; // self-reference
        const src = l.ambient.values()[src_idx];
        if (src.get(rec.local)) |t| return t;
        return if (src.count() == 0) .{ .kind = .any } else null;
    }

    /// One `export * as ns from "module"` inside an ambient block: the namespace
    /// object of the module the specifier names, whichever half answers it.
    fn ambientNamespaceTarget(l: *Linker, f: *const ProgFile, rec: binder.ExportRec) Error!Target {
        if (try l.effectiveModuleFile(f, rec.module)) |mfile| {
            return .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only, .type_only_from_export = true };
        }
        if (l.ambientKey(rec.module)) |key| {
            return .{
                .kind = .ambient_ns,
                .payload = @intCast(l.ambient.getIndex(key).?),
                .type_only = rec.type_only,
                .type_only_from_export = true,
            };
        }
        return .{ .kind = .any };
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
            try l.mergeAmbientReexports();
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
                    found = try l.exportEqualsMeanings(exeq, p.local);
                    try l.noteEqDefaultImport(p.file, l.nodeSpan(p.file, p.node), p.local, found);
                    if (found == null) found = .{ .kind = .any };
                }
            }
            if (found) |tgt| {
                const t = &l.tables[p.file];
                if (t.get(p.exported)) |cur| {
                    if (cur.kind != .any) continue;
                }
                var final = tgt;
                final.markTypeOnly(.exported(p.type_only));
                try l.put(t, p.exported, final);
            } else {
                try l.diagNoExportedMember(p.file, p.mfile, p.module, p.local, l.nodeSpan(p.file, p.node));
            }
        }
    }

    /// Fold a GLOBAL declaration of a UMD name into the module that publishes
    /// it — the export-table half of the merge `mergeGlobals` performs on the
    /// symbol side.
    ///
    /// `export as namespace a` puts an ALIAS in tsc's `globals`; a later
    /// `declare global { namespace a { export const y } }` merges into it, and
    /// `mergeSymbol` resolves the alias first, so what the namespace really
    /// merges into is the MODULE symbol (a clone of it, recorded as its merged
    /// symbol). The members the global block adds are therefore exports of the
    /// module itself:
    ///
    ///     import * as a2 from "./a";
    ///     declare global { namespace a { export const y = 0 } }
    ///     a2.y;   // OK — `y` is an export of "./a"
    ///
    /// so this is a fold into the export table, not a second table beside it.
    /// The module's OWN export wins a name collision (tsc keeps the merge
    /// target's entry and reports; `reportUmdGlobalDups` is the report).
    ///
    /// Skipped entirely when a SCRIPT file earlier in file order already
    /// declares the name at its top level: tsc's copy step is `if
    /// (!globals.has(id)) globals.set(id, sym)`, so the UMD name never enters
    /// the table and nothing merges with it.
    ///
    /// A module file's own top level is not a global contribution here — for
    /// the `export = <ident>` shape the binder harvests the exported entity as
    /// the file's global (see umd.zig), and that entity IS the module, so
    /// folding it back in would merge the module with itself. Only `declare
    /// global { … }` members and script top levels are real second declarations.
    fn foldUmdGlobalMembers(l: *Linker, umds: []const umd.Global) Error!void {
        var prev: Atom = 0;
        for (umds) |u| {
            if (u.name == prev) continue; // first module publishing the name wins
            prev = u.name;
            if (scriptDeclaresBefore(l.files, u.name, u.file)) continue;
            for (l.files, 0..) |*f, fi| {
                if (fi == u.file) continue;
                const b = f.bind;
                const split = @min(b.global_aug_start, b.global_atoms.len);
                for (b.global_atoms, b.global_syms, 0..) |atom, local, k| {
                    if (atom != u.name) continue;
                    // A module's own top level (the pre-augmentation half of
                    // the harvest) is the `export = <ident>` stand-in, not a
                    // second declaration.
                    if (b.is_module and k < split) continue;
                    if (!b.symbol_flags[local].namespace_decl) continue;
                    const ns = b.namespaceScopeOf(local) orelse continue;
                    const lo = b.scope_members_start[ns];
                    const hi = b.scope_members_start[ns + 1];
                    for (lo..hi) |mi| {
                        const msym = b.member_syms[mi];
                        if (!b.symbol_flags[msym].exported) continue;
                        _ = try l.starPutFile(&l.tables[u.file], b.member_atoms[mi], .{
                            .kind = .binding,
                            .file = @intCast(fi),
                            .payload = msym,
                        }, false);
                    }
                }
            }
        }
    }

    /// One `export *`-merged name into an export table. True when the table
    /// actually changed — the fixed-point drivers' signal.
    ///
    /// `default` and the reserved `export=` key never travel, and the first
    /// contributor of a name wins. The one thing a LATER contributor can still
    /// change is the type-only mark: tsc's `getExportsOfModuleWorker` builds
    /// `typeOnlyExportStarMap` from the `export type *` clauses and then
    /// deletes from it every name a NON-type-only visit also reached, so
    ///
    ///     export type * from "./a";
    ///     export * from "./a";
    ///
    /// publishes `./a`'s names as VALUES. Keeping the first star's mark made
    /// every use of them TS1362 (`exportNamespace5`, `exportNamespace8`).
    /// Only the star's own mark is cancelled; a mark the target already
    /// carried — an `export type { X }` specifier upstream — is a property of
    /// the alias and stands.
    fn starPutFile(
        l: *Linker,
        dst: *std.AutoArrayHashMapUnmanaged(Atom, Target),
        name: Atom,
        tgt: Target,
        type_only: bool,
    ) Error!bool {
        if (name == l.atom_default or name == l.atom_export_equals) return false;
        if (dst.getPtr(name)) |cur| {
            if (type_only or !cur.type_only_from_star) return false;
            cur.type_only = false;
            cur.type_only_from_export = false;
            cur.type_only_from_star = false;
            return true;
        }
        var final = tgt;
        final.markTypeOnly(.exported(type_only));
        final.type_only_from_star = type_only and !tgt.type_only;
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

    /// `starPutFile` addressed by ambient-registry index rather than by table
    /// pointer — the registry's values are the same kind of export table.
    fn starPut(l: *Linker, dst_idx: usize, name: Atom, tgt: Target, type_only: bool) Error!bool {
        return l.starPutFile(&l.ambient.values()[dst_idx], name, tgt, type_only);
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
    /// `import "m"` when that option is on. With the option ON — ztsc's
    /// default, following tsgo 7.0.2's; see `tsconfig.Config` for why that is
    /// not TypeScript 5.x's — the unresolved specifier is TS2882, the same
    /// condition tsc words as TS2307. With it explicitly off, the specifier is
    /// silently accepted, which is what a project whose bundler plugins own
    /// specifiers like `import "@fontsource-variable/inter"` (a CSS-only
    /// package) needs.
    ///
    /// The same walk carries TS7016 for the module that resolved but has no
    /// declarations behind it — see `untypedJsModule`.
    fn reportUnresolvedModules(l: *Linker, file: FileId) Error!void {
        try l.reportUnresolvedIn(file, l.files[file].tree.nodeRange(ast.root_node), true);
        try l.reportUnresolvedImportCalls(file);
    }

    /// The same report for a DYNAMIC `import("m")`, whose specifier is an
    /// expression operand and so is nowhere in the statement walk above.
    /// tsc's `checkImportCallExpression` resolves it through
    /// `resolveExternalModuleName` exactly like a static import clause —
    /// measured: `import("./script")` where the target is a script answers
    /// TS2306, a missing one TS2307, and `import("fs")` without
    /// `@types/node` answers TS2591 — so it routes into `reportSpecifier`
    /// with `side_effect = false`, the named-import arm.
    ///
    /// No AST walk: the binder already registered every literal-specifier
    /// `import()` as a module reference of the file (`bindDynamicImport`),
    /// so the records are in hand and the specifier resolution has already
    /// happened. A record is a dynamic import exactly when its node is the
    /// CALL — `bindImportType`'s record carries the `.import_type` node
    /// (the checker's `resolveImportTypeModule` reports that one, at the
    /// use site, where tsc does), and every static form carries its
    /// statement.
    fn reportUnresolvedImportCalls(l: *Linker, file: FileId) Error!void {
        const f = &l.files[file];
        for (f.bind.imports) |rec| {
            if (f.tree.nodeTag(rec.node) != .call_expr) continue;
            const r = f.tree.extraData(ast.SubRange, f.tree.nodeData(rec.node).rhs);
            const args = f.tree.extraRange(r.start, r.end);
            if (args.len == 0) continue;
            try l.reportSpecifier(file, f, f.tree.nodeMainToken(args[0]), false);
        }
    }

    /// `reportUnresolvedModules` over one statement list, recursing into the
    /// AMBIENT MODULE bodies that may hold further import/export declarations.
    ///
    /// A specifier is not a top-level-only construct: `declare module "M" {
    /// import { x } from "external" }` names a module and tsc resolves it. A
    /// plain `namespace N { … }` does NOT: tsc's
    /// `checkExternalImportOrExportDeclaration` reports the grammar error
    /// (TS1147 / TS1194 — an import there may not reference a module) and
    /// returns false, and the caller bails before it ever resolves the
    /// specifier. Reporting TS2307 alongside the grammar error is exactly the
    /// cascade tsc suppresses. Only a USE of the alias makes tsc resolve it
    /// after all (`resolveAlias` at the use site), which is a checker question,
    /// not a link one — and an under-report, the safe direction.
    ///
    /// The test is on the DIRECT parent, tsc's `node.parent.kind ===
    /// ModuleBlock && isAmbientModule(node.parent.parent)`, so a plain
    /// namespace nested inside an ambient module ends the walk too.
    ///
    /// `top_level` distinguishes the file's own statement list from an ambient
    /// module BODY, which is the one thing an `declare module "spec"` block
    /// needs to know about itself before it can be judged an augmentation.
    fn reportUnresolvedIn(l: *Linker, file: FileId, stmts: []const ast.Node, top_level: bool) Error!void {
        const f = &l.files[file];
        const tree = f.tree;
        for (stmts) |stmt0| {
            if (stmt0 == ast.null_node) continue;
            // `export declare module "m" { … }` / `export import x =
            // require("m")`: the modifier wraps the declaration it applies to.
            const stmt = if (tree.nodeTag(stmt0) == .export_decl) tree.nodeData(stmt0).lhs else stmt0;
            if (stmt == ast.null_node) continue;
            const tag = tree.nodeTag(stmt);
            if (tag == .namespace_decl) {
                const e = tree.extraData(ast.NamespaceData, tree.nodeData(stmt).lhs);
                if (e.flags & ast.Flags.ambient_module != 0) {
                    if (top_level) try l.reportAugmentationName(file, f, e.name_token);
                    try l.reportUnresolvedIn(file, tree.extraRange(e.body_start, e.body_end), false);
                }
                continue;
            }
            if (tag != .import_decl and tag != .export_named and tag != .export_all and tag != .import_equals) continue;
            var side_effect = false;
            var mod_tok: ast.TokenIndex = tree.nodeData(stmt).rhs;
            if (tag == .import_decl) {
                // A SIDE-EFFECT import is `import "m"` with no import CLAUSE at
                // all — not merely one that binds no name. `import {} from "m"`
                // has an (empty) clause, and tsc treats it like any other
                // named import: TS2307, not TS2882. The clause is what sits
                // between the `import` keyword and the specifier, so its
                // absence is exactly "the specifier came next"
                // (`ImportData`'s token fields cannot tell empty braces from no
                // braces).
                side_effect = mod_tok == tree.nodeMainToken(stmt) + 1;
            } else if (tag == .import_equals) {
                // `import x = require("m")`: the specifier is in the extra data.
                mod_tok = tree.extraData(ast.ImportEquals, tree.nodeData(stmt).lhs).module_token;
            } else if (tag == .export_named) {
                // `export {} from "m"` re-exports nothing, and tsc never
                // resolves the specifier: no name asks for the module, so a
                // missing one is silent (measured — `export { a } from "m"` and
                // `export * as ns from "m"` both still answer TS2307).
                const e = tree.extraData(ast.ExportNamed, tree.nodeData(stmt).lhs);
                if (e.spec_start == e.spec_end) continue;
            }
            if (mod_tok == 0) continue;
            try l.reportSpecifier(file, f, mod_tok, side_effect);
        }
    }

    /// One module specifier token, resolved and diagnosed. Shared by every
    /// syntactic form that names a module — the import/export STATEMENTS
    /// `reportUnresolvedIn` walks and the `import()` CALLS
    /// `reportUnresolvedImportCalls` walks — because tsc reaches all of them
    /// through the same `resolveExternalModuleName`, and so answers the same
    /// four codes at the same anchor.
    ///
    /// `side_effect` is the `import "m"` form, whose miss is TS2882 (see
    /// `reportUnresolvedIn`); everything else falls through the TS2307 /
    /// TS2591 / TS2580 arms below.
    fn reportSpecifier(
        l: *Linker,
        file: FileId,
        f: *const ProgFile,
        mod_tok: ast.TokenIndex,
        side_effect: bool,
    ) Error!void {
        const text = f.tree.tokenSlice(f.src, mod_tok);
        const stripped = literals.stripQuotes(text);
        // `import * as A from ""` resolves to nothing and is TS2307 like
        // any other miss; it just has no atom to look anything up by (the
        // empty string is not a name the interner hands out).
        if (stripped.len != 0) {
            if (try l.reportResolvedModule(file, f, stripped, mod_tok, side_effect)) return;
        }
        if (side_effect) {
            if (!l.no_unchecked_side_effect_imports) return;
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

    /// TS2664 for a module AUGMENTATION whose target does not exist —
    /// tsc's `mergeModuleAugmentation`, whose `resolveExternalModuleNameWorker`
    /// is handed `Invalid_module_name_in_augmentation_module_0_cannot_be_found`
    /// as its not-found message.
    ///
    /// A top-level `declare module "spec" { … }` is an augmentation exactly
    /// when its file is a MODULE (tsc's `isExternalModuleAugmentation`); in a
    /// SCRIPT the same block DECLARES the module and there is nothing to
    /// resolve — `@types/node`'s `declare module "fs"` is that, and it is the
    /// reason the name lookup here may only find a script-declared key, never
    /// another augmentation. `buildAmbient` keys the registry on exactly those,
    /// so a plain `ambientKey` is that lookup.
    ///
    /// Skipped in a DECLARATION file: tsc's gate is `!(moduleName.parent.parent
    /// .flags & NodeFlags.Ambient)`, and every node of a `.d.ts` carries
    /// `Ambient`, so the same block there is silent — measured, with
    /// `skipLibCheck` off, on a `.d.ts` that augments a module that does not
    /// exist. Nested blocks are skipped for the same reason (their container IS
    /// ambient), which is what `top_level` carries.
    fn reportAugmentationName(l: *Linker, file: FileId, f: *const ProgFile, name_tok: ast.TokenIndex) Error!void {
        if (!f.bind.is_module or name_tok == 0) return;
        if (paths.isDeclarationPath(f.path)) return;
        const text = f.tree.tokenSlice(f.src, name_tok);
        const stripped = literals.stripQuotes(text);
        if (stripped.len == 0) return;
        const atom = l.interner.intern(l.io, l.gpa, stripped) catch return Error.OutOfMemory;
        if ((try l.effectiveModuleFile(f, atom)) != null) return;
        if (l.ambientKey(atom) != null) return;
        try l.diag(file, 2664, l.tokSpan(file, name_tok), "Invalid module name in augmentation, module '{s}' cannot be found.", .{stripped});
    }

    /// True when specifier `stripped` resolved (to a file or to a `declare
    /// module`), leaving nothing for the caller's unresolved arms to say. The
    /// one diagnostic a RESOLVED specifier can still carry — TS7016 for a
    /// dependency that turned out to be plain JavaScript — is issued here.
    fn reportResolvedModule(
        l: *Linker,
        file: FileId,
        f: *const ProgFile,
        stripped: []const u8,
        mod_tok: ast.TokenIndex,
        side_effect: bool,
    ) Error!bool {
        const atom = l.interner.intern(l.io, l.gpa, stripped) catch return Error.OutOfMemory;
        if (try l.effectiveModuleFile(f, atom)) |mfile| {
            // An `exports`-blocked subpath is a RESOLUTION FAILURE wearing
            // a resolution's clothes: the resolver hands back a synthetic
            // opaque `any` module (`paths.blocked_subpath_suffix`) purely so
            // every downstream symbol stays bound — dangling the specifier
            // instead is not crash-safe under parallel resolution. The
            // diagnostic is decoupled from that liveness decision here:
            // liveness stays with the resolver's stand-in module, and the
            // report falls through to the caller's unresolved-specifier arms
            // (ambient suppression included), so tsc's TS2307 lands at the
            // specifier token. See `blockedSubpathReport`.
            if (!l.blockedSubpathReport(mfile)) {
                // Resolved. The one thing left to say about it: a dependency
                // that turned out to be plain JavaScript has no types, and
                // under `noImplicitAny` that is an error at the specifier.
                if (l.no_implicit_any and !side_effect and untypedJsModule(l.files[mfile].path)) {
                    try l.diag(file, 7016, l.tokSpan(file, mod_tok), "Could not find a declaration file for module '{s}'. '{s}' implicitly has an 'any' type.", .{ stripped, l.files[mfile].path });
                }
                // …and a file that exists but is a SCRIPT has no module symbol
                // to import from. tsc's `resolveExternalModuleName`: the file
                // resolved, `sourceFile.symbol` is undefined, so it reports
                // TS2306 at the specifier and binds nothing. A side-effect
                // import asks for no name and stays silent, and a synthetic
                // JSON/JS any-module (which carries `export = any` and never
                // sees a binder) is not a script.
                if (!side_effect and !l.files[mfile].bind.is_module and
                    paths.anyModuleSourceFor(l.files[mfile].path) == null)
                {
                    try l.diag(file, 2306, l.tokSpan(file, mod_tok), "File '{s}' is not a module.", .{l.files[mfile].path});
                }
                return true;
            }
        }
        return l.hasAmbient(atom); // resolved by a `declare module`
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
            // A directive that named its own file resolved perfectly well; what
            // is wrong with it is the circle, and tsc words that one way for
            // both directive kinds.
            if (miss.self_reference) {
                try l.diag(file, 1006, miss.span, "A file cannot have a reference to itself.", .{});
                continue;
            }
            switch (miss.kind) {
                .types => try l.diag(file, 2688, miss.span, "Cannot find type definition file for '{s}'.", .{miss.name}),
                // TS6053 names the specifier as WRITTEN, not the path resolution
                // tried: `///<reference path='typescript.ts' />` in a directory
                // without one reports `File 'typescript.ts' not found.`
                // (`parserRealSource3`, measured).
                .path => {
                    // ztsc's path resolution is POSIX-only: it neither
                    // normalizes `\` nor recognizes a Windows drive prefix,
                    // while tsc does both (`normalizeSlashes`,
                    // `isRootedDiskPath`). A directive spelled that way
                    // resolves for the oracle and not here, so reporting would
                    // blame the PROGRAM for ztsc's own gap —
                    // `tripleSlashReferenceAbsoluteWindowsPath` is the corpus
                    // case. An under-report until the resolver learns both.
                    if (windowsSpelledPath(miss.name)) continue;
                    try l.diag(file, 6053, miss.span, "File '{s}' not found.", .{miss.name});
                },
            }
        }
    }

    /// Which `export *` first contributed a name, and what it contributed —
    /// tsc's `ExportCollisionTracker.specifierText` plus the symbol the
    /// comparison is against.
    const StarSource = struct { node: ast.Node, target: Target };

    /// One `export *` that re-exported a name an EARLIER one already gave a
    /// different meaning. tsc reports at the later declaration and names the
    /// earlier one's specifier.
    const StarDup = struct { name: Atom, node: ast.Node };

    /// tsc's `resolveSymbol(targetSymbol) === resolveSymbol(sourceSymbol)`: two
    /// stars that reach the SAME declaration are not a collision, however many
    /// paths lead there (a diamond of re-exports is legal and common). ztsc's
    /// `Target` is already the resolved end of that walk, so identity is a field
    /// comparison — `type_only` excluded, because it records how the name
    /// travelled and not what it names.
    fn sameStarTarget(a: Target, b: Target) bool {
        return a.kind == b.kind and a.file == b.file and a.payload == b.payload and a.name == b.name;
    }

    /// TS2308, tsc's `getExportsOfModuleWorker` collision pass: `export * from
    /// "a"` and `export * from "b"` both exporting `x`, where the two `x`es are
    /// different declarations, makes neither win — tsc reports at every star
    /// past the first and names the first one's specifier.
    ///
    /// Two suppressions, both tsc's: a name the module also exports ITSELF wins
    /// outright and says nothing (`symbols.has(id)`), and `default` / `export=`
    /// never travel through a star to begin with.
    ///
    /// The specifier is quoted as WRITTEN — tsc's `getTextOfNode` hands the
    /// message the source text, quotes included, so `export * from "./t1"`
    /// reports `Module "./t1" has already…` and a single-quoted one keeps its
    /// own quotes.
    ///
    /// Scope: stars whose source is a RESOLVED FILE, which is what this pass
    /// merges. One served by an ambient `declare module "spec"` block settles in
    /// `starMergeFilesFromAmbient`, past every file table, and goes unjudged.
    fn reportStarCollisions(
        l: *Linker,
        file: FileId,
        t: *const std.AutoArrayHashMapUnmanaged(Atom, Target),
        own_exports: usize,
        star_first: *const std.AutoArrayHashMapUnmanaged(Atom, StarSource),
        dups: []const StarDup,
    ) Error!void {
        if (dups.len == 0) return;
        const f = &l.files[file];
        for (dups) |d| {
            if (t.getIndex(d.name)) |i| {
                if (i < own_exports) continue;
            }
            const first = star_first.get(d.name) orelse continue;
            const spec_tok = f.tree.nodeData(first.node).rhs;
            if (spec_tok == 0) continue;
            try l.diag(
                file,
                2308,
                l.nodeSpan(file, d.node),
                "Module {s} has already exported a member named '{s}'. Consider explicitly re-exporting to resolve the ambiguity.",
                .{ f.tree.tokenSlice(f.src, spec_tok), l.atomText(d.name) },
            );
        }
    }

    /// Is this reference path spelled the way Windows spells one — with `\`
    /// separators, or behind a drive prefix? Both are ordinary path characters
    /// to ztsc's POSIX-only resolver and structure to tsc's.
    fn windowsSpelledPath(spec: []const u8) bool {
        if (std.mem.indexOfScalar(u8, spec, '\\') != null) return true;
        return spec.len >= 2 and spec[1] == ':' and std.ascii.isAlphabetic(spec[0]);
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
                    // A TYPE-ONLY import assignment (`import type X =
                    // require("m")`) is erased, so it is not an emit construct
                    // and tsc exempts it: `checkImportEqualsDeclaration` guards
                    // the rule on `!node.isTypeOnly`.
                    if (e.module_token != 0 and e.flags & ast.Flags.type_only == 0) {
                        var span = l.nodeSpan(file, stmt);
                        // `export import x = require("m")`: tsc's declaration
                        // node starts at the MODIFIER, and `main_token` is the
                        // `import` keyword after it. `ImportEquals.flags` is
                        // what records the modifier (the parser folds it away),
                        // so the `export` token is the one before the keyword.
                        if (e.flags & ast.Flags.exported != 0) {
                            const kw = tree.nodeMainToken(stmt);
                            if (kw > 0 and tree.tokens.tag(kw - 1) == .keyword_export) {
                                span.start = l.tokSpan(file, kw - 1).start;
                            }
                        }
                        try l.diag(file, 1202, span, "Import assignment cannot be used when targeting ECMAScript modules. Consider using 'import * as ns from \"mod\"', 'import {{a}} from \"mod\"', 'import d from \"mod\"', or another module format instead.", .{});
                    }
                },
                // `declare export = x` is AMBIENT, and tsc's ESM check is
                // guarded on `!(node.flags & NodeFlags.Ambient)` — the modifier
                // already earned its own TS1120 in the parser, and there is no
                // emit to complain about. The parser records the modifier flags
                // in the node's spare `rhs`.
                .export_assign => if (tree.nodeData(stmt).rhs & ast.Flags.declare == 0) {
                    try l.diag(file, 1203, l.nodeSpan(file, stmt), "Export assignment cannot be used when targeting ECMAScript modules. Consider using 'export default' or another module format instead.", .{});
                },
                else => {},
            }
        }
    }

    /// Where a complaint about a DEFAULT import goes: the local name the
    /// default was bound to (`import d from "m"` → `d`), which is tsc's
    /// `ImportClause.name` and where it anchors TS1192 and TS2613 — not the
    /// statement, and not the `export` modifier a malformed `export import d,
    /// * as ns from "m"` puts in front of it.
    ///
    /// Falls back to the statement for a shape with no default name token,
    /// which the `.default` arm's own record kind makes unreachable.
    fn defaultBindingSpan(l: *Linker, file: FileId, node: ast.Node) source.Span {
        const tree = l.files[file].tree;
        if (node != ast.null_node and tree.nodeTag(node) == .import_decl) {
            const data = tree.extraData(ast.ImportData, tree.nodeData(node).lhs);
            if (data.default_name_token != 0) return l.tokSpan(file, data.default_name_token);
        }
        return l.nodeSpan(file, node);
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
                            tgt.markTypeOnly(.imported(rec.type_only));
                        } else if (mfile_opt) |mfile| {
                            tgt = .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only, .type_only_from_export = false };
                        } else if (!l.ambientOpaque(rec.module)) {
                            if (l.ambientKey(rec.module)) |key| {
                                tgt = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?), .type_only = rec.type_only, .type_only_from_export = false };
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
                            tgt.markTypeOnly(.imported(rec.type_only));
                        } else if (mfile_opt) |mfile| {
                            tgt = .{ .kind = .namespace, .file = mfile, .type_only = rec.type_only, .type_only_from_export = false };
                        } else if (l.ambientOpaque(rec.module)) {
                            // Opaque ambient module: `import * as p` is `any`,
                            // so member access doesn't spuriously TS2339.
                            tgt = .{ .kind = .any };
                        } else if (l.ambientKey(rec.module)) |key| {
                            tgt = .{ .kind = .ambient_ns, .payload = @intCast(l.ambient.getIndex(key).?), .type_only = rec.type_only, .type_only_from_export = false };
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
                            try l.noteEqDefaultImport(file, l.nodeSpan(file, rec.node), rec.imported, found);
                        }
                        if (found) |ff| {
                            tgt = ff;
                            tgt.markTypeOnly(.imported(rec.type_only));
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
                            tgt.markTypeOnly(.imported(rec.type_only));
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
                            tgt = .{ .kind = .namespace, .file = mfile_opt.?, .type_only = rec.type_only, .type_only_from_export = false };
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
                                .type_only_from_export = false,
                            };
                        } else if ((mfile_opt != null and (try l.lookupExport(mfile_opt.?, rec.local, 0)) != null) or
                            l.lookupAmbient(rec.module, rec.local) != null)
                        {
                            try l.diag(file, 2613, l.defaultBindingSpan(file, rec.node), "Module '\"{s}\"' has no default export. Did you mean to use 'import {{ {s} }} from \"{s}\"' instead?", .{
                                l.atomText(rec.module), l.atomText(rec.local), l.atomText(rec.module),
                            });
                        } else {
                            try l.diag(file, 1192, l.defaultBindingSpan(file, rec.node), "Module '\"{s}\"' has no default export.", .{l.atomText(rec.module)});
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

    /// The per-file automatic JSX runtime a `/* @jsxImportSource X */` pragma
    /// selects, resolved. Null when `src` carries no pragma (the common case,
    /// and the only cost then is the leading-comment scan) or when `importer`
    /// is not a JSX file — a `.ts` file has no tags for the runtime to serve,
    /// and tsc's implicit import container is only ever asked for from one.
    ///
    /// `file` is `no_file` when the module does not resolve; that is not a
    /// failure to report here, it is what makes the file's first tag TS2875.
    pub fn discoverJsxPragma(
        d: *const Discovery,
        importer: []const u8,
        src: []const u8,
    ) !?struct { spec: []const u8, file: FileId } {
        if (!parser.isJsxPath(importer)) return null;
        const base = jsx_pragma.scan(src) orelse return null;
        const spec = try std.fmt.allocPrint(d.arena, "{s}/jsx-runtime", .{base});
        return .{ .spec = spec, .file = (try d.discoverModule(importer, spec)) orelse no_file };
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
    /// `file` is `no_file` when the directive resolves to nothing (a `types=`
    /// miss is the linker's TS2688; the caller decides), and `self` is set when
    /// it resolves to the very file it is written in — tsc's TS1006, which the
    /// caller records the same way it records a miss. Both are answers about
    /// ONE resolution, which is why they come back together.
    pub fn discoverReference(d: *const Discovery, importer: []const u8, ref: resolve.RefDirective) !ReferenceTarget {
        const resolved = try d.rcache.resolveRef(d.io, d.scratch, d.dir, importer, ref) orelse
            return .{ .file = no_file, .self = false };
        const fid = try d.fileFor(resolved);
        // Identity is the file id, not the spelling: `resolveRef` canonicalizes,
        // and `path_ids` is keyed by that same canonical path, so a directive
        // that names its own file through `./x`, `../dir/x` or the bare name all
        // land on the id the importer already has. A plain `get` (never
        // `fileFor`) so a lookup can only ever answer about a file the program
        // already holds.
        return .{ .file = fid, .self = (d.path_ids.get(importer) orelse no_file) == fid };
    }
};

/// What one `/// <reference … />` resolved to. See `discoverReference`.
pub const ReferenceTarget = struct { file: FileId, self: bool };

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
