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
//!     candidate order) are supported. The `package.json` `"exports"` map is
//!     honored (M22): subpath keys (`"."`, `"./sub"`, `"./*"` and prefixed
//!     `"./d3-*"` wildcards), per-subpath condition objects, and the bundler
//!     condition set `{types, import, default}` (verified against tsc
//!     `--traceResolution`: types-first, first matching condition whose target
//!     exists wins, failed targets continue to the next). A `"types"`/`"import"`
//!     target that names a `.js`/`.mjs`/`.cjs` runtime file probes its
//!     declaration sibling (`.d.ts`/`.d.mts`/`.d.cts`). Unlike Node/tsc, when
//!     `exports` is present but matches nothing we do NOT hard-fail — we fall
//!     back to legacy `"types"`/`index` probing (a deliberate under-report:
//!     never a false TS2307, may miss a real one). When `exports` is absent the
//!     legacy path is byte-for-byte unchanged. `package.json` is parsed with the
//!     shared JSONC parser (`tsconfig.parseJsonc`); the `"types"`/`"typings"`
//!     legacy fields still use the minimal string scanner.
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
const tsconfig = @import("tsconfig.zig");

const Ast = ast.Ast;
const Bind = binder.Bind;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Span = source.Span;

pub const Error = error{OutOfMemory};

pub const FileId = u32;
pub const no_file: FileId = std.math.maxInt(FileId);

// The big ES-core and DOM libs are each embedded as N shard files rather than
// one giant blob, so the front end (scan → parse → bind) parallelizes across
// worker threads instead of running one 2.35 MB file serially on a single
// worker. src/lib/gen_lib.js splits them at top-level declaration boundaries
// (byte-preserving: the shards concatenate back to the un-sharded blob) and the
// linker merges their globals cross-file exactly as if they were one file —
// which is in fact how tsc itself sees the lib (one SourceFile per lib.*.d.ts).
// KEEP THESE COUNTS IN SYNC WITH src/lib/gen_lib.js (ES_SHARDS / DOM_SHARDS).
pub const es_shard_count = 4;
pub const dom_shard_count = 8;

/// Synthetic paths of the injected ES-core lib shards (M10; sharded in M21.perf).
/// They have no on-disk location; the loaders special-case these exact paths and
/// use the matching embedded source. The leading NUL keeps them from colliding
/// with any real filesystem path.
pub const lib_paths = [es_shard_count][]const u8{
    "\x00lib/lib.esnext.0.d.ts", "\x00lib/lib.esnext.1.d.ts",
    "\x00lib/lib.esnext.2.d.ts", "\x00lib/lib.esnext.3.d.ts",
};
/// The embedded ES-core lib shard texts (real TypeScript 7.0.2 ES-core..esnext
/// surface, DOM excluded). Bound once per run; their top-level declarations
/// become the program's global symbols. Their own diagnostics are suppressed
/// (like tsc's default lib) — see the print loop in main.zig.
pub const lib_sources = [es_shard_count][]const u8{
    @embedFile("lib/lib.esnext.0.d.ts"), @embedFile("lib/lib.esnext.1.d.ts"),
    @embedFile("lib/lib.esnext.2.d.ts"), @embedFile("lib/lib.esnext.3.d.ts"),
};

/// Synthetic paths of the injected DOM lib shards (M21). Loaded when tsconfig
/// `lib` selects "dom" (or by default — tsgo's target-esnext default includes
/// DOM). Provide browser globals plus the real `console`.
pub const dom_lib_paths = [dom_shard_count][]const u8{
    "\x00lib/lib.dom.0.d.ts", "\x00lib/lib.dom.1.d.ts",
    "\x00lib/lib.dom.2.d.ts", "\x00lib/lib.dom.3.d.ts",
    "\x00lib/lib.dom.4.d.ts", "\x00lib/lib.dom.5.d.ts",
    "\x00lib/lib.dom.6.d.ts", "\x00lib/lib.dom.7.d.ts",
};
/// The embedded DOM lib shard texts (browser globals + `Console`; es* deps
/// omitted, supplied by the esnext blob it always loads alongside).
pub const dom_lib_sources = [dom_shard_count][]const u8{
    @embedFile("lib/lib.dom.0.d.ts"), @embedFile("lib/lib.dom.1.d.ts"),
    @embedFile("lib/lib.dom.2.d.ts"), @embedFile("lib/lib.dom.3.d.ts"),
    @embedFile("lib/lib.dom.4.d.ts"), @embedFile("lib/lib.dom.5.d.ts"),
    @embedFile("lib/lib.dom.6.d.ts"), @embedFile("lib/lib.dom.7.d.ts"),
};

/// FileId of the first ES-core lib shard, matched by path (or `no_file`). The
/// esnext shards are always injected as a contiguous block starting here.
pub const lib_path = lib_paths[0];

/// Synthetic path of the minimal `console` shim (M21). Loaded ONLY when esnext
/// is selected without dom (backend configs, lib:["esnext"]): `console` lives
/// in lib.dom, so without DOM there is no `console`. DOM configs use lib.dom's
/// richer `Console` and skip this (no duplicate `var console`).
pub const console_shim_path = "\x00lib/lib.console.d.ts";
pub const console_shim_source = @embedFile("lib/lib.console.d.ts");

/// Upper bound on injected lib files: every es shard + every dom shard + the
/// console shim. Sizes the fixed-capacity `LibFile` buffers callers pass in.
pub const max_lib_files = es_shard_count + dom_shard_count + 1;

/// Which built-in lib blobs to inject. Derived from tsconfig `lib` (or the
/// default) by `resolveLibSet`; consumed by `libFiles`, `seedLibAtoms`,
/// `buildProgram`, and the CLI injection site. `dom` always implies `es`
/// (lib.dom references es2015 / es2018.asynciterable, both in the esnext blob),
/// and `shim` (the console shim) is present exactly when `es and !dom`.
pub const LibSet = struct {
    es: bool = false,
    dom: bool = false,
    shim: bool = false,

    /// No libs at all — `--noLib` / `lib:[]`.
    pub const none: LibSet = .{};
    /// The tsgo default (no `lib` field, target esnext): ES-core + DOM.
    pub const default: LibSet = .{ .es = true, .dom = true };
    /// Backend config: ES-core + the console shim, no DOM.
    pub const es_only: LibSet = .{ .es = true, .shim = true };

    pub fn any(s: LibSet) bool {
        return s.es or s.dom or s.shim;
    }
};

/// One synthetic lib file (path + embedded source).
pub const LibFile = struct { path: []const u8, source: []const u8 };

/// Fill `buf` with the ordered synthetic lib files for `set`. Order is fixed
/// (esnext, dom, console shim) so that seeded atoms (`seedLibAtoms`) and the
/// injected file ids agree run-to-run — the determinism the seeded interner
/// relies on. Returns the populated prefix of `buf`.
pub fn libFiles(set: LibSet, buf: *[max_lib_files]LibFile) []const LibFile {
    var n: usize = 0;
    if (set.es) {
        for (lib_paths, lib_sources) |p, s| {
            buf[n] = .{ .path = p, .source = s };
            n += 1;
        }
    }
    if (set.dom) {
        for (dom_lib_paths, dom_lib_sources) |p, s| {
            buf[n] = .{ .path = p, .source = s };
            n += 1;
        }
    }
    if (set.shim) {
        buf[n] = .{ .path = console_shim_path, .source = console_shim_source };
        n += 1;
    }
    return buf[0..n];
}

/// Embedded source for a synthetic lib path, or null for a real file path.
pub fn libSourceFor(path: []const u8) ?[]const u8 {
    for (lib_paths, lib_sources) |p, s| {
        if (std.mem.eql(u8, path, p)) return s;
    }
    for (dom_lib_paths, dom_lib_sources) |p, s| {
        if (std.mem.eql(u8, path, p)) return s;
    }
    if (std.mem.eql(u8, path, console_shim_path)) return console_shim_source;
    return null;
}

/// True for any injected built-in lib path (diagnostics/stat suppression).
pub fn isLibPath(path: []const u8) bool {
    return libSourceFor(path) != null;
}

/// True for a TypeScript *declaration* file (`.d.ts`, `.d.mts`, `.d.cts`). These
/// never emit and — under `skipLibCheck` — have all their diagnostics
/// suppressed. The `.d.mts`/`.d.cts` variants matter for ESM/CJS-dual packages
/// (redux-toolkit, zod, typebox) whose published types live in those files.
pub fn isDeclarationPath(path: []const u8) bool {
    return endsWithAny(path, &.{ ".d.ts", ".d.mts", ".d.cts" });
}

/// Resolve a tsconfig `lib` list (or null = not specified) to the blob set.
/// tsc semantics: a `lib` list REPLACES the default set. We map any `es*`
/// token to the ES-core blob and any `dom*` token to the DOM blob; other
/// families (webworker/scripthost) are out of subset and ignored (warned at
/// tsconfig parse). `dom` forces `es` on (its reference deps live in the es
/// blob); the console shim fills in when es is selected without dom.
pub fn resolveLibSet(lib: ?[]const []const u8) LibSet {
    const list = lib orelse return LibSet.default;
    var es = false;
    var dom = false;
    for (list) |name| {
        if (std.ascii.startsWithIgnoreCase(name, "dom")) {
            dom = true;
        } else if (std.ascii.startsWithIgnoreCase(name, "es")) {
            es = true;
        }
    }
    if (dom) es = true;
    return .{ .es = es, .dom = dom, .shim = es and !dom };
}

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
    /// Reserved atom keying `export = X` entries in export/ambient tables, so
    /// the namespace-object builders can skip it. 0 when no linker ran.
    export_equals_atom: Atom = 0,
    /// Effective `noImplicitAny` (true = on = report). When false, the checker
    /// suppresses the implicit-'any' diagnostic family (TS7006/TS7053); the
    /// affected values still type as `any`. Defaults on (strict semantics); the
    /// driver sets it from the tsconfig. See `tsconfig.Config.no_implicit_any`.
    no_implicit_any: bool = true,

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
pub fn seedLibAtoms(io: Io, gpa: Allocator, interner: *Interner, set: LibSet) !void {
    var buf: [max_lib_files]LibFile = undefined;
    for (libFiles(set, &buf)) |lf| {
        var seed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer seed_arena.deinit();
        const sa = seed_arena.allocator();
        const lib_tree = try parser.parse(sa, lf.source);
        _ = try binder.bind(sa, io, gpa, interner, &lib_tree, lf.source);
        // Each lib file's own path atom is interned by the worker front end too.
        _ = try interner.intern(io, gpa, lf.path);
    }
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
    links: []const FileLinks,
) Error!GlobalMerge {
    // Accumulate name -> constituent global ids, contributions in FileId order.
    var acc: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(u32)) = .empty;
    for (files, 0..) |*f, fi| {
        const b = f.bind;
        if (b.global_atoms.len == 0) continue;
        const base = sym_base[fi];
        for (b.global_atoms, b.global_syms) |atom, local| {
            const gop = try acc.getOrPut(scratch, atom);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(scratch, base + local);
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

    // Cross-file module augmentation merge (M11c): fold a `declare module
    // "spec" { interface I { … } }` block (in a MODULE-context file) into the
    // interface `I` already exported by the real module `spec` resolves to.
    try mergeAugmentations(&m, files, sym_base, links);

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

/// Cross-file module augmentation merge (M11c). A `declare module "spec" { …
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
                // Only interface↔interface merges (value/namespace/generic
                // type-param unification stay deferred — degrade, no crash).
                if (!b.symbol_flags[local].interface) continue;
                const name = b.member_atoms[i];
                const tgt = links[mfile].exportTarget(name) orelse continue;
                if (tgt.kind != .binding) continue;
                const real = sym_base[tgt.file] + tgt.payload;
                if (!globalSymFlags(files, sym_base, real).interface) continue;
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
    const lib_list = libFiles(lib_set, &buf);
    const files = try arena.alloc(ProgFile, lib_list.len + 1);
    for (lib_list, 0..) |lf, i| {
        const lib_tree = try arena.create(Ast);
        lib_tree.* = try parser.parse(arena, lf.source);
        const lib_bind = try arena.create(Bind);
        lib_bind.* = try binder.bind(arena, io, gpa, interner, lib_tree, lf.source);
        files[i] = .{ .path = lf.path, .src = lf.source, .tree = lib_tree, .bind = lib_bind };
    }
    files[lib_list.len] = .{ .path = path, .src = src, .tree = tree, .bind = bind };
    const sym_base = try computeSymBase(arena, files);
    // Unlinked single-file path: a script user file may still augment lib
    // globals; merge diagnostics (none for the clean case) have no link table
    // to land in here and are dropped.
    const gm = try mergeGlobals(arena, arena, files, sym_base, &.{});
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

/// Minimal `package.json` scan for the first string value of any of `keys`
/// (quoted key literals, e.g. `"types"`). First match wins; string escapes
/// unsupported — documented cut.
fn packageStringField(text: []const u8, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
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

/// `package.json` `"types"` / `"typings"` field (the declaration entry).
fn packageTypesField(text: []const u8) ?[]const u8 {
    return packageStringField(text, &.{ "\"types\"", "\"typings\"" });
}

/// `package.json` `"main"` field (the runtime JS entry), consulted only under
/// `allowJs` when a package ships no types.
fn packageMainField(text: []const u8) ?[]const u8 {
    return packageStringField(text, &.{"\"main\""});
}

// ---------------------------------------------------------------------------
// package.json "exports" map (M22; bundler/Node16-style)
// ---------------------------------------------------------------------------

fn endsWithAny(s: []const u8, exts: []const []const u8) bool {
    for (exts) |e| if (std.mem.endsWith(u8, s, e)) return true;
    return false;
}

/// True if an `exports` object is a subpath map (keys begin with ".") rather
/// than a conditions object. Node forbids mixing the two, so the first key
/// decides.
fn exportsIsSubpathMap(obj: tsconfig.Value.Object) bool {
    return obj.keys.len > 0 and obj.keys[0].len > 0 and obj.keys[0][0] == '.';
}

/// A condition name active for type resolution under `moduleResolution:
/// bundler`. tsc resolves in import mode, so the on-set is {types, import}
/// plus the universal `default` fallback — verified via `--traceResolution`
/// ("Resolving ... with conditions 'import', 'types'"; "Saw non-matching
/// condition 'require'"). `require`/`module`/`node`/`browser` are inactive.
fn exportsConditionActive(key: []const u8) bool {
    return std.mem.eql(u8, key, "types") or
        std.mem.eql(u8, key, "import") or
        std.mem.eql(u8, key, "default");
}

/// Resolve `subpath` ("." for the package root, "./x" for a subpath) against a
/// package.json `exports` value, returning an existing declaration file under
/// `pkg_dir` (owned by `alloc`) or null. Pure function of the value + FS.
fn resolveExportsField(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    pkg_dir: []const u8,
    exports_val: tsconfig.Value,
    subpath: []const u8,
) Error!?[]u8 {
    switch (exports_val) {
        .string => |s| {
            // Sugar: a string `exports` defines only the package root ".".
            if (std.mem.eql(u8, subpath, ".")) return statExportTarget(io, alloc, dir, pkg_dir, s, "");
            return null;
        },
        .object => |obj| {
            if (exportsIsSubpathMap(obj)) return resolveExportsSubpath(io, alloc, dir, pkg_dir, obj, subpath);
            // A bare conditions object (no "./" keys) is sugar for the "." target.
            if (!std.mem.eql(u8, subpath, ".")) return null;
            return resolveConditionalTarget(io, alloc, dir, pkg_dir, exports_val, "");
        },
        else => return null,
    }
}

/// Match `subpath` against a subpath map: an exact key first, then the
/// longest-prefix wildcard pattern (`"./*"`, `"./d3-*"`), Node's best-match
/// rule. The `*` captures the middle; the capture substitutes into the target.
fn resolveExportsSubpath(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    pkg_dir: []const u8,
    obj: tsconfig.Value.Object,
    subpath: []const u8,
) Error!?[]u8 {
    if (obj.get(subpath)) |v| return resolveConditionalTarget(io, alloc, dir, pkg_dir, v, "");
    var best: ?usize = null;
    var best_prefix: usize = 0;
    for (obj.keys, 0..) |key, i| {
        const star = std.mem.indexOfScalar(u8, key, '*') orelse continue;
        const prefix = key[0..star];
        const suffix = key[star + 1 ..];
        if (subpath.len < prefix.len + suffix.len) continue;
        if (!std.mem.startsWith(u8, subpath, prefix)) continue;
        if (!std.mem.endsWith(u8, subpath, suffix)) continue;
        if (best == null or prefix.len > best_prefix) {
            best = i;
            best_prefix = prefix.len;
        }
    }
    if (best) |bi| {
        const key = obj.keys[bi];
        const star = std.mem.indexOfScalar(u8, key, '*').?;
        const prefix = key[0..star];
        const suffix = key[star + 1 ..];
        const capture = subpath[prefix.len .. subpath.len - suffix.len];
        return resolveConditionalTarget(io, alloc, dir, pkg_dir, obj.vals[bi], capture);
    }
    return null;
}

/// Resolve one `exports` target value with `*` bound to `star`: a string is a
/// path; `null` is a blocked subpath; an array is a fallback list (first that
/// resolves); an object is a conditions map (first active condition whose
/// target resolves, in declaration order — a failed target continues to the
/// next, matching tsc).
fn resolveConditionalTarget(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    pkg_dir: []const u8,
    target: tsconfig.Value,
    star: []const u8,
) Error!?[]u8 {
    switch (target) {
        .null => return null, // explicitly blocked (`"./esm": null`)
        .string => |s| return statExportTarget(io, alloc, dir, pkg_dir, s, star),
        .array => |arr| {
            for (arr) |elem| {
                if (try resolveConditionalTarget(io, alloc, dir, pkg_dir, elem, star)) |p| return p;
            }
            return null;
        },
        .object => |obj| {
            for (obj.keys, obj.vals) |key, v| {
                if (!exportsConditionActive(key)) continue;
                if (try resolveConditionalTarget(io, alloc, dir, pkg_dir, v, star)) |p| return p;
            }
            return null;
        },
        else => return null,
    }
}

/// Stat an `exports` target string (with `*` replaced by `star`) as a
/// declaration file under `pkg_dir`. The target names a runtime path; its
/// types file is either the target itself (already a `.d.ts`/`.d.mts`/`.d.cts`)
/// or the declaration sibling of a `.js`/`.mjs`/`.cjs` (`.mjs`→`.d.mts`,
/// `.cjs`→`.d.cts`, `.js`→`.d.ts` — verified via `--traceResolution`). Returns
/// the existing path (owned by `alloc`) or null.
fn statExportTarget(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    pkg_dir: []const u8,
    target: []const u8,
    star: []const u8,
) Error!?[]u8 {
    // Targets must be package-relative ("./..."). Reject anything else
    // (absolute, "../escape", bare) — Node does, and it keeps resolution
    // inside the package.
    if (!std.mem.startsWith(u8, target, "./")) return null;

    // Substitute the wildcard capture for every '*'.
    var subst: []const u8 = target;
    if (std.mem.indexOfScalar(u8, target, '*') != null) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        var rest = target;
        while (std.mem.indexOfScalar(u8, rest, '*')) |at| {
            try buf.appendSlice(alloc, rest[0..at]);
            try buf.appendSlice(alloc, star);
            rest = rest[at + 1 ..];
        }
        try buf.appendSlice(alloc, rest);
        subst = try alloc.dupe(u8, buf.items);
    }

    const joined = try joinNormalize(alloc, pkg_dir, subst);
    defer alloc.free(joined);
    // A wildcard capture with "../" could escape the package; normalization
    // then drops `pkg_dir` from the front. Reject that.
    if (!std.mem.startsWith(u8, joined, pkg_dir)) return null;

    var cands: [3][]const u8 = undefined;
    var n: usize = 0;
    const p = joined;
    if (endsWithAny(p, &.{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".tsx" })) {
        cands[0] = p;
        n = 1;
    } else if (std.mem.endsWith(u8, p, ".mjs")) {
        const base = p[0 .. p.len - ".mjs".len];
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.mts", .{base});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 2;
    } else if (std.mem.endsWith(u8, p, ".cjs")) {
        const base = p[0 .. p.len - ".cjs".len];
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.cts", .{base});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 2;
    } else if (endsWithAny(p, &.{ ".js", ".jsx" })) {
        const base = p[0..std.mem.lastIndexOfScalar(u8, p, '.').?];
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.d.mts", .{base});
        cands[2] = try std.fmt.allocPrint(alloc, "{s}.ts", .{base});
        n = 3;
    } else if (std.mem.indexOfScalar(u8, std.fs.path.basename(p), '.') == null) {
        // An extensionless target ("./index"): probe TypeScript/declaration
        // extensions like a bare stem.
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{p});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.ts", .{p});
        n = 2;
    } else {
        // A non-TypeScript extension (`.css`/`.json`/`.svg`/…). tsc strips it
        // and searches TS/declaration extensions — it never treats the raw
        // asset as a module (verified via `--traceResolution`: a `.css` target
        // "was not resolved"). Do NOT stat it as-is: that would pull a CSS/JSON
        // file in to be parsed as TypeScript (a false-positive cascade). Leave
        // it unresolved so the import degrades exactly as before this feature.
        return null;
    }
    for (cands[0..n]) |c| {
        if (fileExists(io, dir, c)) return try alloc.dupe(u8, c);
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
    var buf: [6][]const u8 = undefined;
    var n: usize = 0;
    // Candidate paths are built with `alloc` (a scratch arena, freed after
    // the file's specifiers resolve). A previous fixed 256-byte buffer
    // silently failed on deep node_modules/@types paths — a wrong "module
    // not found" — so there is no length cap here.
    if (endsWithAny(stem, &.{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".tsx", ".mts", ".cts" })) {
        buf[0] = stem;
        n = 1;
        return tryCandidates(io, alloc, dir, buf[0..n]);
    }
    if (std.mem.endsWith(u8, stem, ".js") or std.mem.endsWith(u8, stem, ".jsx")) {
        const base = stem[0..std.mem.lastIndexOfScalar(u8, stem, '.').?];
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{base});
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.tsx", .{base});
        buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 3;
        return tryCandidates(io, alloc, dir, buf[0..n]);
    }
    // `.mjs`/`.cjs` rewrite to their declaration siblings (`.mjs`→`.mts`/`.d.mts`,
    // `.cjs`→`.cts`/`.d.cts`) — the relative-import twin of the `exports`-field
    // rule (`statExportTarget`). Needed for ESM-only packages (typebox, zod)
    // whose `.d.mts`/`.d.cts` re-export `./x.mjs`/`./x.cjs`.
    if (std.mem.endsWith(u8, stem, ".mjs") or std.mem.endsWith(u8, stem, ".cjs")) {
        const base = stem[0 .. stem.len - ".mjs".len];
        const m: u8 = stem[stem.len - 3]; // 'm' or 'c'
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.{c}ts", .{ base, m });
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.d.{c}ts", .{ base, m });
        n = 2;
        return tryCandidates(io, alloc, dir, buf[0..n]);
    }
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.tsx", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{stem});
    buf[3] = try std.fmt.allocPrint(alloc, "{s}/index.ts", .{stem});
    buf[4] = try std.fmt.allocPrint(alloc, "{s}/index.tsx", .{stem});
    buf[5] = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{stem});
    n = 6;
    return tryCandidates(io, alloc, dir, buf[0..n]);
}

/// `allowJs` fallback for `resolveStem`: when no TypeScript/declaration file
/// matched `stem`, probe the raw JavaScript file. An explicit JS-family
/// extension (`.js`/`.jsx`/`.mjs`/`.cjs`) is statted as-is; an extensionless
/// stem probes `stem.js`/`stem.jsx` then `stem/index.js`/`stem/index.jsx`
/// (the JS twins of `resolveStem`'s TypeScript probes). The returned path is
/// loaded opaquely as `any` (`js_module_source`); ztsc never parses the JS.
fn resolveJsStem(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8) Error!?[]u8 {
    if (endsWithAny(stem, &.{ ".js", ".jsx", ".mjs", ".cjs" })) {
        if (fileExists(io, dir, stem)) return try alloc.dupe(u8, stem);
        return null;
    }
    var buf: [4][]const u8 = undefined;
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.js", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.jsx", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}/index.js", .{stem});
    buf[3] = try std.fmt.allocPrint(alloc, "{s}/index.jsx", .{stem});
    return tryCandidates(io, alloc, dir, buf[0..4]);
}

/// `resolveStem`, then — under `allow_js` — the `resolveJsStem` JavaScript
/// fallback. Declaration/TypeScript files always win over a `.js` twin.
fn resolveStemOrJs(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8, allow_js: bool) Error!?[]u8 {
    if (try resolveStem(io, alloc, dir, stem)) |p| return p;
    if (allow_js) return resolveJsStem(io, alloc, dir, stem);
    return null;
}

/// Resolve a bare (package) specifier by walking `node_modules` up from
/// the importer's directory.
fn resolvePackage(io: Io, alloc: Allocator, dir: Io.Dir, importer_dir: []const u8, spec: []const u8, allow_js: bool) Error!?[]u8 {
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

    // For an unscoped bare package, tsc also resolves its typings from
    // `@types/<pkg>` (the DefinitelyTyped fallback) when the real package has
    // no types — e.g. `import … from "react"` → `node_modules/@types/react`.
    // We probe `@types/<pkg>` right after `<pkg>` at each directory level.
    const types_pkg: ?[]const u8 = if (pkg.len > 0 and pkg[0] != '@')
        try std.fmt.allocPrint(alloc, "@types/{s}", .{pkg})
    else
        null;
    defer if (types_pkg) |tp| alloc.free(tp);

    var d = importer_dir;
    while (true) {
        if (try resolvePackageAt(io, alloc, dir, d, pkg, sub, allow_js)) |p| return p;
        if (types_pkg) |tp| {
            // `@types/<pkg>` ships declarations only — never a JS fallback.
            if (try resolvePackageAt(io, alloc, dir, d, tp, sub, false)) |p| return p;
        }

        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) return null;
        d = dirnamePart(d);
    }
}

/// Resolve `<pkg>/<sub>` under one directory level's `node_modules`, honoring
/// `package.json` `"types"`/`"typings"` (for a bare package) or a relative
/// stem (for a subpath). Null when nothing resolves at this level.
fn resolvePackageAt(io: Io, alloc: Allocator, dir: Io.Dir, d: []const u8, pkg: []const u8, sub: []const u8, allow_js: bool) Error!?[]u8 {
    const nm = if (d.len == 0)
        try std.fmt.allocPrint(alloc, "node_modules/{s}", .{pkg})
    else
        try std.fmt.allocPrint(alloc, "{s}/node_modules/{s}", .{ d, pkg });
    defer alloc.free(nm);

    // Read package.json once — shared by the `exports` map and the legacy
    // `"types"`/`"typings"` scan. (For a subpath the legacy path skips it, but
    // `exports` may still map the subpath, so we always read.)
    const pj = try std.fmt.allocPrint(alloc, "{s}/package.json", .{nm});
    defer alloc.free(pj);
    var pj_text: ?[]u8 = null;
    bumpProbe();
    if (dir.readFileAlloc(io, pj, alloc, .limited(1 << 20))) |t| {
        pj_text = t;
    } else |_| {}
    defer if (pj_text) |t| alloc.free(t);

    // (1) `exports` map — authoritative for tsc when present. On a miss we fall
    //     through to legacy probing (deliberate under-report; see file header).
    if (pj_text) |text| {
        if (tsconfig.parseJsonc(alloc, text)) |root| switch (root) {
            .object => |ro| if (ro.get("exports")) |exports_val| {
                const subpath: []const u8 = if (sub.len == 0)
                    "."
                else
                    try std.fmt.allocPrint(alloc, "./{s}", .{sub});
                defer if (sub.len != 0) alloc.free(subpath);
                if (try resolveExportsField(io, alloc, dir, nm, exports_val, subpath)) |p| return p;
            },
            else => {},
        } else |_| {}
    }

    // (2) Legacy resolution (exports absent or unmatched).
    if (sub.len > 0) {
        const stem = try joinNormalize(alloc, nm, sub);
        defer alloc.free(stem);
        return resolveStemOrJs(io, alloc, dir, stem, allow_js);
    }
    // package.json "types"/"typings" (declaration entry — TS only), else the
    // JS "main" entry under allowJs (typed `any`), else index.d.ts/index.ts (or
    // index.js under allowJs).
    var resolved_types = false;
    if (pj_text) |text| {
        if (packageTypesField(text)) |types_rel| {
            resolved_types = true;
            const stem = try joinNormalize(alloc, nm, types_rel);
            defer alloc.free(stem);
            if (try resolveStem(io, alloc, dir, stem)) |p| return p;
        }
    }
    if (!resolved_types) {
        // Under allowJs, a types-less package resolves to its `main` JS entry
        // (a declaration twin next to it still wins — `resolveStemOrJs`).
        if (allow_js) {
            if (pj_text) |text| {
                if (packageMainField(text)) |main_rel| {
                    const stem = try joinNormalize(alloc, nm, main_rel);
                    defer alloc.free(stem);
                    if (try resolveStemOrJs(io, alloc, dir, stem, true)) |p| return p;
                }
            }
        }
        const idx = try std.fmt.allocPrint(alloc, "{s}/index", .{nm});
        defer alloc.free(idx);
        if (try resolveStemOrJs(io, alloc, dir, idx, allow_js)) |p| return p;
    }
    return null;
}

/// Per-run resolution options that are not a pure function of (dir, spec):
/// `resolveJsonModule` and the `baseUrl` bare-specifier anchor. Carried on the
/// `ResolveCache` (set once at init) so `resolveSpecifier`'s determinism
/// contract — a pure function of `(dir, spec, config)` — is preserved with the
/// config folded in explicitly.
pub const ResolveOpts = struct {
    /// tsconfig `resolveJsonModule`: a `*.json` specifier that names an existing
    /// file resolves to it (typed opaquely as `any`; see `json_module_source`).
    resolve_json: bool = false,
    /// tsconfig `baseUrl`, already resolved to a `dir`-relative directory, or
    /// null. A bare (non-relative) specifier probes `baseUrl/<spec>` — for both
    /// `*.json` and TS/JS stems — AFTER `paths` (handled by the driver) and
    /// BEFORE the `node_modules` walk, matching tsc's bundler/node order
    /// (verified with `--traceResolution`: paths → baseUrl → node_modules).
    base_url: ?[]const u8 = null,
    /// tsconfig `allowJs`: when a specifier has no TS/declaration resolution but
    /// a JavaScript file exists (a package whose entry is only `.js`, or a
    /// `./x.js` file with no `.ts`/`.d.ts` twin), resolve to that `.js`/`.jsx`/
    /// `.mjs`/`.cjs` file and type it opaquely as `any` (see `js_module_source`).
    /// ztsc never parses/checks the JS source. tsc would report TS7016 under
    /// `noImplicitAny`; ztsc under-reports (silent `any`) — a missed diagnostic,
    /// never a false positive.
    allow_js: bool = false,
};

/// Synthetic TypeScript source substituted for a resolved `*.json` module
/// (`resolveJsonModule`). tsc synthesizes a structural type from the JSON
/// literal; the under-report policy lets us type the module opaquely as `any`
/// instead (a missed error is allowed, a false positive is not). `export =` (not
/// `export default`) makes the module absorb every import form — default,
/// namespace, and named — as `any` without a spurious TS1192/TS2305. The
/// loaders special-case a `.json` program path to this text instead of parsing
/// the raw JSON as TypeScript.
pub const json_module_source = "declare const j: any;\nexport = j;\n";

/// Synthetic source substituted for a resolved JavaScript module under
/// `allowJs`. Identical shape to `json_module_source` (opaque `any` via
/// `export =`): ztsc never parses/checks JS, so a JS-only dependency (`qs`,
/// `leaflet.markercluster`) types as `any` instead of raising TS2307. Under
/// `noImplicitAny` tsc emits TS7016 here; ztsc under-reports (silent `any`).
pub const js_module_source = json_module_source;

/// True for a program path that is a resolved JSON module (loaded as
/// `json_module_source`, not read/parsed from disk). Only reachable when
/// `resolveJsonModule` routed a `*.json` specifier to an on-disk file.
pub fn isJsonModulePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".json");
}

/// True for a program path that is a resolved JavaScript module (loaded as
/// `js_module_source`, not read/parsed from disk). Only reachable under
/// `allowJs`: TS/declaration resolution never returns a raw `.js`/`.jsx`/
/// `.mjs`/`.cjs` path (it rewrites to declaration twins), so any such program
/// path is an allowJs any-module.
pub fn isJsModulePath(path: []const u8) bool {
    return endsWithAny(path, &.{ ".js", ".jsx", ".mjs", ".cjs" });
}

/// Embedded synthetic source for a resolved JSON or JS any-module, or null for
/// a real file that must be read and parsed. Centralizes the loader's
/// any-module routing (JSON via `resolveJsonModule`, JS via `allowJs`).
pub fn anyModuleSourceFor(path: []const u8) ?[]const u8 {
    if (isJsonModulePath(path)) return json_module_source;
    if (isJsModulePath(path)) return js_module_source;
    return null;
}

/// The Node.js built-in modules tsc resolves via an auto-included `@types/node`
/// (its `declare module "fs"` / `declare module "node:fs"` blocks). `node:`-
/// prefixed specifiers are always built-ins; the bare names cover the common
/// unprefixed imports. Used by the driver to pull `@types/node` into the program
/// on demand so those ambient blocks register and the import resolves.
pub fn isNodeBuiltin(spec: []const u8) bool {
    if (std.mem.startsWith(u8, spec, "node:")) return true;
    const builtins = [_][]const u8{
        "assert",          "async_hooks",     "buffer",     "child_process",  "cluster",
        "console",         "constants",       "crypto",     "dgram",          "dns",
        "domain",          "events",          "fs",         "http",           "http2",
        "https",           "inspector",       "module",     "net",            "os",
        "path",            "perf_hooks",      "process",    "punycode",       "querystring",
        "readline",        "repl",            "stream",     "string_decoder", "timers",
        "tls",             "tty",             "url",        "util",           "v8",
        "vm",              "worker_threads",  "zlib",       "fs/promises",    "dns/promises",
        "stream/promises", "timers/promises", "util/types",
    };
    for (builtins) |b| if (std.mem.eql(u8, spec, b)) return true;
    return false;
}

/// Stat a `*.json` stem (already `dir`-relative, ending in `.json`) as a
/// resolved JSON module. Unlike `resolveStem`, no extension probing: the file
/// must exist exactly as named (tsc resolves a JSON specifier only to the JSON
/// file itself). Returns the path (owned by `alloc`) or null. Public so the CLI
/// driver can stat a `paths`-mapped `*.json` candidate (which `resolveStem`
/// would not find).
pub fn resolveJsonFile(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8) Error!?[]u8 {
    if (fileExists(io, dir, stem)) return try alloc.dupe(u8, stem);
    return null;
}

/// Resolve module specifier `spec` from file `importer` (both relative to
/// `dir`). Returns the normalized path of the resolved file, or null.
pub fn resolveSpecifier(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    importer: []const u8,
    spec: []const u8,
    opts: ResolveOpts,
) Error!?[]u8 {
    if (spec.len == 0) return null;
    const importer_dir = dirnamePart(importer);
    const is_json = opts.resolve_json and std.mem.endsWith(u8, spec, ".json");
    if (spec[0] == '.') {
        const stem = try joinNormalize(alloc, importer_dir, spec);
        defer alloc.free(stem);
        if (is_json) return resolveJsonFile(io, alloc, dir, stem);
        return resolveStemOrJs(io, alloc, dir, stem, opts.allow_js);
    }
    if (spec[0] == '/') {
        const stem = try normalizePath(alloc, spec);
        defer alloc.free(stem);
        if (is_json) return resolveJsonFile(io, alloc, dir, stem);
        return resolveStemOrJs(io, alloc, dir, stem, opts.allow_js);
    }
    // A bare `*.json` specifier resolves against `baseUrl` only (tsc's baseUrl
    // rule; the `public/api/x.json` shape) — never node_modules.
    if (is_json) {
        if (opts.base_url) |bu| {
            const stem = try joinNormalize(alloc, bu, spec);
            defer alloc.free(stem);
            if (try resolveJsonFile(io, alloc, dir, stem)) |p| return p;
        }
        return null;
    }
    // A bare non-json specifier resolves against `baseUrl` BEFORE the
    // node_modules walk (tsc bundler/node order: paths → baseUrl → node_modules;
    // `paths` is applied by the driver ahead of this call). `src/utils/mask`
    // → `<baseUrl>/src/utils/mask.ts`.
    if (opts.base_url) |bu| {
        const stem = try joinNormalize(alloc, bu, spec);
        defer alloc.free(stem);
        if (try resolveStemOrJs(io, alloc, dir, stem, opts.allow_js)) |p| return p;
    }
    return resolvePackage(io, alloc, dir, importer_dir, spec, opts.allow_js);
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
    /// Resolution options folded into the (dir, spec, config) pure function.
    opts: ResolveOpts = .{},
    /// Cached realpath of `dir` (arena-owned), used to re-relativize canonical
    /// paths; computed lazily on the first `node_modules` resolution.
    real_base: ?[]const u8 = null,
    real_base_done: bool = false,
    lookups: u64 = 0,
    hits: u64 = 0,

    pub fn init(arena: Allocator, enabled: bool, opts: ResolveOpts) ResolveCache {
        return .{ .arena = arena, .enabled = enabled, .opts = opts };
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
        if (!rc.enabled) {
            const r = (try resolveSpecifier(io, scratch, dir, importer, spec, rc.opts)) orelse return null;
            return try rc.canonicalize(io, dir, r);
        }
        rc.lookups += 1;
        const importer_dir = dirnamePart(importer);
        // Build the key in scratch; only copy it into `arena` on a miss.
        const key = try std.fmt.allocPrint(scratch, "{s}\x00{s}", .{ importer_dir, spec });
        if (rc.map.get(key)) |cached| {
            rc.hits += 1;
            return cached;
        }
        const resolved = try resolveSpecifier(io, scratch, dir, importer, spec, rc.opts);
        const owned: ?[]const u8 = if (resolved) |p| try rc.canonicalize(io, dir, p) else null;
        try rc.map.put(rc.arena, try rc.arena.dupe(u8, key), owned);
        return owned;
    }

    /// The realpath of `dir` (cached, arena-owned) for re-relativizing canonical
    /// paths, or null if the OS call failed (then canonical paths stay absolute).
    fn dirRealBase(rc: *ResolveCache, io: Io, dir: Io.Dir) ?[]const u8 {
        if (!rc.real_base_done) {
            rc.real_base_done = true;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.realPath(io, &buf)) |n| {
                rc.real_base = rc.arena.dupe(u8, buf[0..n]) catch null;
            } else |_| {}
        }
        return rc.real_base;
    }

    /// Canonicalize a resolved path to a stable file identity by resolving
    /// symlinks (pnpm's isolated store links a package's real location under
    /// `.pnpm/`; only through the realpath are its sibling deps reachable by the
    /// upward `node_modules` walk). tsc keys files by realpath for exactly this
    /// reason. The result is re-relativized against `dir`'s realpath so a
    /// relative-rooted run/test keeps a relative path space. Determinism holds:
    /// realpath is a deterministic, idempotent function of the filesystem; the
    /// cached and uncached (`--no-resolve-cache`) legs both apply it. Only
    /// `node_modules` paths are canonicalized — nothing else is symlinked into a
    /// store, so user-file paths (and their diagnostic display) are untouched and
    /// no realpath syscall is spent on them. One syscall per resolved
    /// `node_modules` file (the resolve memo collapses repeats), never per probe.
    fn canonicalize(rc: *ResolveCache, io: Io, dir: Io.Dir, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOf(u8, raw, "node_modules") == null) return rc.arena.dupe(u8, raw);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = dir.realPathFile(io, raw, &buf) catch return rc.arena.dupe(u8, raw);
        const abs = buf[0..n];
        if (rc.dirRealBase(io, dir)) |b| {
            if (abs.len > b.len + 1 and std.mem.startsWith(u8, abs, b) and abs[b.len] == '/') {
                return rc.arena.dupe(u8, abs[b.len + 1 ..]);
            }
        }
        return rc.arena.dupe(u8, abs);
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
    /// Reserved key under which a module's `export = X` target is stored in its
    /// export/ambient table (`export=` can never be a real export name). Skipped
    /// by the namespace-object builders and `export *` merge.
    atom_export_equals: Atom,
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

    /// TS2307 for unresolved module specifiers, one per statement. A
    /// side-effect-only import (`import "./x"`) of an unresolved module gets
    /// TS2882 instead — TS7 flags these (tsc 5.5 left them silent under
    /// bundler resolution).
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
            if (f.specs.get(atom) != null) continue;
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
        if (isDeclarationPath(f.path)) return;
        // Resolved JSON/JS any-modules carry a synthetic `export = any` body
        // (never emitted); the grammar rule that bans `export =` under ESM does
        // not apply to them.
        if (anyModuleSourceFor(f.path) != null) return;
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
                            try l.diag(file, 2305, l.nodeSpan(file, rec.node), "Module '\"{s}\"' has no exported member '{s}'.", .{
                                l.atomText(rec.module), l.atomText(rec.imported),
                            });
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
    export_equals_atom: Atom = 0,
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
    // Then the ambient/augmentation module registry (M11c), which import
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

    // Cross-file global merge (M11a) + module augmentation merge (M11c): fold
    // every file's harvest slice and every `declare module` augmentation of a
    // resolved real module. Needs the sealed export tables (`out`).
    const sym_base = try computeSymBase(arena, files);
    const gm = try mergeGlobals(arena, scratch, files, sym_base, out);

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

    return .{ .links = out, .sym_base = sym_base, .globals = gm.globals, .merged = gm.merged, .ambient_exports = amb, .ambient_specs = amb_specs, .constit_keys = gm.constit_keys, .constit_vals = gm.constit_vals, .export_equals_atom = l.atom_export_equals };
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
            if (try resolvePackage(io, alloc, dir, dirnamePart(importer), scoped, false)) |p| return p;
            return resolvePackage(io, alloc, dir, dirnamePart(importer), ref.spec, false);
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
    lib_set: LibSet,
    resolve_opts: ResolveOpts,
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
    for (libFiles(lib_set, &lib_buf)) |lf| {
        try path_ids.put(scratch, lf.path, @intCast(pending.items.len));
        try pending.append(scratch, lf.path);
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
        const bytes: []const u8 = if (libSourceFor(path)) |s|
            s
        else if (anyModuleSourceFor(path)) |s|
            s
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
            .export_equals_atom = lr.export_equals_atom,
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

    // The default runtime set (ES-core + DOM) is the widest seed; exercise it.
    const set = LibSet.default;

    // Seed a fresh interner single-threaded, as the CLI does before spawning
    // workers.
    var itn1 = Interner.init();
    defer itn1.deinit(gpa);
    try seedLibAtoms(io, gpa, &itn1, set);
    const seeded_count = itn1.count(io);

    // Re-binding every lib blob into the seeded interner must intern *zero* new
    // strings: seeding already produced every atom binding needs, including
    // the transformed ones (stripQuotes, well-known-symbol keys, the
    // "default"/"*" constants). Anything seeding missed would be interned
    // here for the first time by a worker thread — i.e. nondeterministically.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [max_lib_files]LibFile = undefined;
    var last_bind: *const Bind = undefined;
    for (libFiles(set, &buf)) |lf| {
        const tree = try a.create(Ast);
        tree.* = try parser.parse(a, lf.source);
        const b_ptr = try a.create(Bind);
        b_ptr.* = try binder.bind(a, io, gpa, &itn1, tree, lf.source);
        last_bind = b_ptr;
    }
    try testing.expectEqual(seeded_count, itn1.count(io));

    // A second, independent seed assigns byte-for-byte identical atom values
    // to the lib's strings — the run-to-run stability M12.2's blob relies on.
    var itn2 = Interner.init();
    defer itn2.deinit(gpa);
    try seedLibAtoms(io, gpa, &itn2, set);
    try testing.expectEqual(seeded_count, itn2.count(io));
    for (last_bind.symbol_names[1..]) |atom| {
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
        const got = try resolveSpecifier(io, alloc, d, "src/a.ts", c.spec, .{});
        if (c.want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expectEqual(@as(?[]u8, null), got);
        }
    }
}

// M22: package.json `exports` resolution across the real shapes in the corpus
// (redux/sentry/react-i18next/base-ui/victory), verified against tsc
// `--traceResolution`. Also covers the exports-miss fallback and the
// no-exports regression path.
test "resolveSpecifier: package.json exports map" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });

    const NM = "node_modules";

    // redux shape: exports "." with a flat `types` string.
    try d.createDirPath(io, NM ++ "/redux/dist");
    try d.writeFile(io, .{ .sub_path = NM ++ "/redux/package.json", .data =
        \\{ "types":"dist/redux.d.ts",
        \\  "exports": { "./package.json":"./package.json",
        \\    ".": { "types":"./dist/redux.d.ts", "import":"./dist/redux.mjs", "default":"./dist/cjs/redux.cjs" } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/redux/dist/redux.d.ts", .data = "" });

    // @sentry/core shape: "." -> import.types (types nested UNDER import; no
    // top-level types condition). Also exercises scoped packages.
    try d.createDirPath(io, NM ++ "/@sentry/core/build/types");
    try d.writeFile(io, .{ .sub_path = NM ++ "/@sentry/core/package.json", .data =
        \\{ "exports": { ".": {
        \\   "import": { "types":"./build/types/index.d.ts", "default":"./build/esm/index.js" },
        \\   "require": { "types":"./build/types/index.d.ts", "default":"./build/cjs/index.js" } } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/@sentry/core/build/types/index.d.ts", .data = "" });

    // react-i18next shape: "." -> types.import (types is itself a
    // {require,import} object; import condition -> ".d.mts"), plus subpath keys.
    try d.createDirPath(io, NM ++ "/react-i18next");
    try d.writeFile(io, .{ .sub_path = NM ++ "/react-i18next/package.json", .data =
        \\{ "types":"./index.d.mts",
        \\  "exports": {
        \\    ".": { "types": { "require":"./index.d.ts", "import":"./index.d.mts" }, "import":"./dist/es/index.js", "default":"./dist/es/index.js" },
        \\    "./TransWithoutContext": { "types": { "require":"./TransWithoutContext.d.ts", "import":"./TransWithoutContext.d.mts" }, "import":"./x.js" } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/react-i18next/index.d.mts", .data = "" });
    try d.writeFile(io, .{ .sub_path = NM ++ "/react-i18next/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = NM ++ "/react-i18next/TransWithoutContext.d.mts", .data = "" });

    // @base-ui/utils shape: explicit "./store" subpath + "./*" wildcard +
    // blocked "./esm": null. No top-level types (exports is the only entry).
    try d.createDirPath(io, NM ++ "/@base-ui/utils/esm/store");
    try d.writeFile(io, .{ .sub_path = NM ++ "/@base-ui/utils/package.json", .data =
        \\{ "exports": {
        \\    "./store": { "import": { "types":"./esm/store/index.d.ts", "default":"./esm/store/index.js" }, "default": { "types":"./esm/store/index.d.ts" } },
        \\    "./*": { "import": { "types":"./esm/*.d.ts", "default":"./esm/*.js" }, "default": { "types":"./esm/*.d.ts" } },
        \\    "./esm": null } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/@base-ui/utils/esm/store/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = NM ++ "/@base-ui/utils/esm/useEnhancedClickHandler.d.ts", .data = "" });

    // victory-vendor shape: prefixed wildcard "./d3-*" -> types flat string.
    try d.createDirPath(io, NM ++ "/victory-vendor");
    try d.writeFile(io, .{ .sub_path = NM ++ "/victory-vendor/package.json", .data =
        \\{ "exports": { "./d3-*": { "types":"./d3-*.d.ts", "import":"./es/d3-*.js", "default":"./lib/d3-*.js" } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/victory-vendor/d3-shape.d.ts", .data = "" });

    // pjs shape: import condition names an .mjs runtime file -> probe the
    // .d.mts declaration sibling (no explicit types condition).
    try d.createDirPath(io, NM ++ "/pjs/dist");
    try d.writeFile(io, .{ .sub_path = NM ++ "/pjs/package.json", .data =
        \\{ "exports": { ".": { "import":"./dist/index.mjs", "default":"./dist/index.mjs" } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/pjs/dist/index.d.mts", .data = "" });

    // exports-miss: package with exports "." only. A subpath with no export and
    // no on-disk file must stay unresolved (null); the covered root resolves.
    try d.createDirPath(io, NM ++ "/onlyroot");
    try d.writeFile(io, .{ .sub_path = NM ++ "/onlyroot/package.json", .data =
        \\{ "exports": { ".": { "types":"./index.d.ts" } } }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/onlyroot/index.d.ts", .data = "" });

    // no-exports regression: legacy `types` field still resolves unchanged.
    try d.createDirPath(io, NM ++ "/legacy");
    try d.writeFile(io, .{ .sub_path = NM ++ "/legacy/package.json", .data =
        \\{ "types":"main.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = NM ++ "/legacy/main.d.ts", .data = "" });

    const cases = [_]struct { spec: []const u8, want: ?[]const u8 }{
        .{ .spec = "redux", .want = NM ++ "/redux/dist/redux.d.ts" },
        .{ .spec = "@sentry/core", .want = NM ++ "/@sentry/core/build/types/index.d.ts" },
        .{ .spec = "react-i18next", .want = NM ++ "/react-i18next/index.d.mts" },
        .{ .spec = "react-i18next/TransWithoutContext", .want = NM ++ "/react-i18next/TransWithoutContext.d.mts" },
        .{ .spec = "@base-ui/utils/store", .want = NM ++ "/@base-ui/utils/esm/store/index.d.ts" },
        .{ .spec = "@base-ui/utils/useEnhancedClickHandler", .want = NM ++ "/@base-ui/utils/esm/useEnhancedClickHandler.d.ts" },
        .{ .spec = "victory-vendor/d3-shape", .want = NM ++ "/victory-vendor/d3-shape.d.ts" },
        .{ .spec = "pjs", .want = NM ++ "/pjs/dist/index.d.mts" },
        .{ .spec = "onlyroot", .want = NM ++ "/onlyroot/index.d.ts" },
        .{ .spec = "onlyroot/missing", .want = null },
        .{ .spec = "legacy", .want = NM ++ "/legacy/main.d.ts" },
    };
    for (cases) |c| {
        const got = try resolveSpecifier(io, alloc, d, "src/a.ts", c.spec, .{});
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

    var rc = ResolveCache.init(alloc, true, .{});

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
    var off = ResolveCache.init(alloc, false, .{});
    const p1 = try off.resolve(io, alloc, d, "src/a.ts", "pkg");
    const p2 = try resolveSpecifier(io, alloc, d, "src/a.ts", "pkg", .{});
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
    const got = try resolveSpecifier(io, alloc, d, "a.ts", spec, .{});
    try testing.expect(got != null);
    try testing.expectEqualStrings(modpath, got.?);
}

// (a) pnpm isolated store: a package's real location lives under
// `node_modules/.pnpm/<name>@<ver>/node_modules/<name>`, and its deps are
// siblings there — reachable only after the resolver realpaths the importing
// file (a top-level `node_modules/<name>` symlink) before walking up. The
// `ResolveCache` canonicalizes resolved `node_modules` paths so the transitive
// dep resolves; without it, the dep would be a spurious TS2307.
test "ResolveCache: pnpm symlinked store resolves transitive deps via realpath" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // Real store locations (pnpm layout).
    try d.createDirPath(io, "node_modules/.pnpm/pkg-a@1/node_modules/pkg-a");
    try d.createDirPath(io, "node_modules/.pnpm/dep@1/node_modules/dep");
    try d.writeFile(io, .{ .sub_path = "node_modules/.pnpm/pkg-a@1/node_modules/pkg-a/index.d.ts", .data = "import \"dep\";\n" });
    try d.writeFile(io, .{ .sub_path = "node_modules/.pnpm/dep@1/node_modules/dep/index.d.ts", .data = "export const x: number;\n" });
    // dep is a sibling of pkg-a in pkg-a's real store dir (not hoisted to top).
    try d.symLink(io, "../../dep@1/node_modules/dep", "node_modules/.pnpm/pkg-a@1/node_modules/dep", .{ .is_directory = true });
    // Top-level symlink the app imports through.
    try d.symLink(io, ".pnpm/pkg-a@1/node_modules/pkg-a", "node_modules/pkg-a", .{ .is_directory = true });
    try d.writeFile(io, .{ .sub_path = "a.ts", .data = "import \"pkg-a\";\n" });

    var rc = ResolveCache.init(alloc, true, .{});

    // "pkg-a" from a.ts resolves through the top-level symlink and canonicalizes
    // to its real store path.
    const a = try rc.resolve(io, alloc, d, "a.ts", "pkg-a");
    try testing.expectEqualStrings("node_modules/.pnpm/pkg-a@1/node_modules/pkg-a/index.d.ts", a.?);

    // "dep" imported *from* pkg-a's canonical location walks up to the sibling
    // in the real store dir — the whole point of realpath-before-walk.
    const dep = try rc.resolve(io, alloc, d, a.?, "dep");
    try testing.expect(dep != null);
    try testing.expectEqualStrings("node_modules/.pnpm/dep@1/node_modules/dep/index.d.ts", dep.?);

    // The cached and uncached legs must agree (determinism contract).
    var off = ResolveCache.init(alloc, false, .{});
    const dep_uncached = try off.resolve(io, alloc, d, a.?, "dep");
    try testing.expectEqualStrings(dep.?, dep_uncached.?);
}

// (c) resolveJsonModule: a `*.json` specifier resolves to the JSON file only
// when the option is on (relative and baseUrl-anchored bare forms), and stays
// unresolved otherwise (tsc's TS2732 shape → ztsc leaves it a TS2307 miss).
test "resolveSpecifier: resolveJsonModule gates *.json resolution" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/data");
    try d.createDirPath(io, "public/api");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/data/config.json", .data = "{}" });
    try d.writeFile(io, .{ .sub_path = "public/api/layers.json", .data = "{}" });

    const on: ResolveOpts = .{ .resolve_json = true, .base_url = "." };
    // Relative *.json resolves to the file itself (no extension probing).
    try testing.expectEqualStrings(
        "src/data/config.json",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "./data/config.json", on)).?,
    );
    // Bare *.json resolves against baseUrl.
    try testing.expectEqualStrings(
        "public/api/layers.json",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "public/api/layers.json", on)).?,
    );
    // A missing *.json stays unresolved even with the option on.
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "./data/missing.json", on));
    // With the option off, an existing *.json does NOT resolve as a module.
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "./data/config.json", .{}));
}

test "packageMainField: minimal scan" {
    try testing.expectEqualStrings("lib/index.js", packageMainField(
        \\{ "name": "qs", "main": "lib/index.js" }
    ).?);
    try testing.expectEqual(@as(?[]const u8, null), packageMainField(
        \\{ "name": "p", "types": "index.d.ts" }
    ));
}

// Sub-task 2: a bare (non-relative) specifier probes `baseUrl/<spec>` with the
// standard TS extension/index order, AFTER `paths` (driver-applied) and BEFORE
// the node_modules walk — matching tsc's bundler order verified with
// `--traceResolution` (paths → baseUrl → node_modules).
test "resolveSpecifier: baseUrl bare specifier probing + order vs node_modules" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/utils/interfaces");
    try d.createDirPath(io, "src/modules/map/map-render");
    try d.createDirPath(io, "node_modules/shared");
    try d.createDirPath(io, "node_modules/only-pkg");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/utils/mask.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/utils/interfaces/index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/modules/map/map-render/map-render.context.tsx", .data = "" });
    // A package that ALSO shares the bare name `shared`: the baseUrl file
    // (`<baseUrl>/shared.ts`) wins over the node_modules package.
    try d.writeFile(io, .{ .sub_path = "shared.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/shared/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/only-pkg/index.d.ts", .data = "" });

    const on: ResolveOpts = .{ .base_url = "." };
    // Bare specifier → baseUrl/<spec> with .ts / index / .tsx probing.
    try testing.expectEqualStrings("src/utils/mask.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "src/utils/mask", on)).?);
    try testing.expectEqualStrings("src/utils/interfaces/index.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "src/utils/interfaces", on)).?);
    try testing.expectEqualStrings("src/modules/map/map-render/map-render.context.tsx", (try resolveSpecifier(io, alloc, d, "src/a.ts", "src/modules/map/map-render/map-render.context", on)).?);
    // baseUrl is consulted BEFORE node_modules: `shared` resolves to the baseUrl
    // file, not the node_modules package.
    try testing.expectEqualStrings("shared.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "shared", on)).?);
    // A bare specifier with no baseUrl match still falls through to node_modules.
    try testing.expectEqualStrings("node_modules/only-pkg/index.d.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "only-pkg", on)).?);
    // Without baseUrl, a bare non-package specifier does not resolve (TS2307).
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "src/utils/mask", .{}));
}

// Sub-task 3: under `allowJs`, a specifier resolving only to a `.js` file (a
// package whose entry is JS, or a relative `./x.js` with no TS twin) resolves to
// that JS path — loaded opaquely as `any` (`isJsModulePath`) — instead of
// TS2307. With allowJs off, the same specifier stays unresolved.
test "resolveSpecifier: allowJs resolves JS-only package/main and relative .js as any-module" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src");
    // `qs`: no types, `main` → lib/index.js.
    try d.createDirPath(io, "node_modules/qs/lib");
    try d.writeFile(io, .{ .sub_path = "node_modules/qs/package.json", .data = "{ \"name\": \"qs\", \"main\": \"lib/index.js\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/qs/lib/index.js", .data = "module.exports = {};" });
    // `leaflet.markercluster`: no types, no main → index.js at package root.
    try d.createDirPath(io, "node_modules/leaflet.markercluster");
    try d.writeFile(io, .{ .sub_path = "node_modules/leaflet.markercluster/package.json", .data = "{ \"name\": \"leaflet.markercluster\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/leaflet.markercluster/index.js", .data = "" });
    // A package that DOES ship types: the .d.ts wins over any .js twin.
    try d.createDirPath(io, "node_modules/typed");
    try d.writeFile(io, .{ .sub_path = "node_modules/typed/package.json", .data = "{ \"types\": \"index.d.ts\", \"main\": \"index.js\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/typed/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/typed/index.js", .data = "" });
    // Relative JS with no TS twin.
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/legacy.js", .data = "" });

    const on: ResolveOpts = .{ .allow_js = true };
    const off: ResolveOpts = .{};

    // allowJs ON: JS-only package resolves to its .js entry (loaded as any).
    const qs = (try resolveSpecifier(io, alloc, d, "src/a.ts", "qs", on)).?;
    try testing.expectEqualStrings("node_modules/qs/lib/index.js", qs);
    try testing.expect(isJsModulePath(qs));
    try testing.expectEqualStrings("node_modules/leaflet.markercluster/index.js", (try resolveSpecifier(io, alloc, d, "src/a.ts", "leaflet.markercluster", on)).?);
    // A .d.ts always wins over the .js twin, even under allowJs.
    try testing.expectEqualStrings("node_modules/typed/index.d.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "typed", on)).?);
    // Relative ./legacy.js resolves to the JS file itself under allowJs.
    try testing.expectEqualStrings("src/legacy.js", (try resolveSpecifier(io, alloc, d, "src/a.ts", "./legacy", on)).?);
    try testing.expectEqualStrings("src/legacy.js", (try resolveSpecifier(io, alloc, d, "src/a.ts", "./legacy.js", on)).?);

    // allowJs OFF: none of the JS-only specifiers resolve (would be TS2307).
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "qs", off));
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "leaflet.markercluster", off));
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "./legacy", off));
    // The typed package still resolves to its declarations with allowJs off.
    try testing.expectEqualStrings("node_modules/typed/index.d.ts", (try resolveSpecifier(io, alloc, d, "src/a.ts", "typed", off)).?);
}

// (b) Node built-in classification: `node:`-prefixed specifiers and the bare
// builtin names are recognized (the driver pulls in `@types/node` for these so
// their ambient `declare module` blocks resolve them); ordinary packages are
// not.
test "isNodeBuiltin: node: prefix and bare builtin names" {
    try testing.expect(isNodeBuiltin("node:fs"));
    try testing.expect(isNodeBuiltin("node:path"));
    try testing.expect(isNodeBuiltin("node:anything")); // any node: is a builtin
    try testing.expect(isNodeBuiltin("fs"));
    try testing.expect(isNodeBuiltin("path"));
    try testing.expect(isNodeBuiltin("fs/promises"));
    try testing.expect(!isNodeBuiltin("react"));
    try testing.expect(!isNodeBuiltin("@reduxjs/toolkit"));
    try testing.expect(!isNodeBuiltin("./local"));
}
