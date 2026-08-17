//! Module resolution: turning a module specifier into a program file path.
//!
//! Resolution is bundler-style (matches `tsc --moduleResolution bundler` for
//! the subset):
//!
//! - Relative specifiers resolve against the importing file's directory.
//!   Extension order: exact `.ts`/`.d.ts` kept as written; `./x.js` rewrites
//!   to `./x.ts` then `./x.d.ts` (TS output-path style); bare `./x` tries
//!   `x.ts`, `x.d.ts`, `x/index.ts`, `x/index.d.ts`.
//! - Bare specifiers walk up from the importing file looking in
//!   `node_modules/<pkg>/`: the `package.json` `"types"`/`"typings"` field,
//!   else `index.d.ts` (then `index.ts`). Scoped packages (`@scope/pkg`) and
//!   plain subpaths (`pkg/sub` with the relative candidate order) are
//!   supported. The `package.json` `"exports"` map is honored: subpath
//!   keys (`"."`, `"./sub"`, `"./*"` and prefixed `"./d3-*"` wildcards),
//!   per-subpath condition objects, and the bundler condition set `{types,
//!   import, default}` (verified against tsc `--traceResolution`: types-first,
//!   first matching condition whose target exists wins, failed targets
//!   continue to the next). A `"types"`/`"import"` target that names a
//!   `.js`/`.mjs`/`.cjs` runtime file probes its declaration sibling
//!   (`.d.ts`/`.d.mts`/`.d.cts`); when no sibling exists the runtime file
//!   itself is the answer, as an opaque `any` module with TS7016 at the
//!   specifier, and the map's authority stops the legacy `"types"` key it
//!   hides from winning. Unlike Node/tsc, when `exports` is present but
//!   matches nothing *at all* we do NOT hard-fail — we fall back to legacy
//!   `"types"`/`index` probing (a deliberate under-report: never a false
//!   TS2307, may miss a real one). When `exports` is absent the legacy path is
//!   byte-for-byte unchanged. `package.json` is parsed with the shared JSONC
//!   parser (`tsconfig.parseJsonc`); the `"types"`/`"typings"` legacy fields
//!   still use the minimal string scanner. `typesVersions` — the pre-`exports`
//!   redirection layer — is honored on the legacy path, for the version range
//!   spellings `*` and `>=X[.Y]` (see `typesVersionsPaths`). tsconfig
//!   `resolvePackageJsonExports: false` switches the whole map off
//!   (`ResolveOpts.resolve_pkg_json_exports`), leaving only that legacy path —
//!   see the option's doc comment.
//! - Triple-slash `/// <reference path=… />` / `types=…` directives are the
//!   second way a file enters the module graph; they are scanned out of a
//!   file's leading comment block (`scanReferences`) and resolved here too.
//!
//! Two caching layers sit on top, both single-owner by design (resolution
//! never runs concurrently): `ResolveCache` memoizes whole
//! `(importer_dir, spec)` answers, and the `FsCache` under it memoizes the
//! filesystem facts a first-time specifier still pays for.
//!
//! Every private function here takes one `Fs` — where to look, how to ask,
//! what to remember, and the run's `ResolveOpts` — so the cached and uncached
//! legs differ in exactly one place (the `Fs` methods) rather than at every
//! call site. Two neighbours carry the parts that are not filesystem work at
//! all: package_json.zig reads a `package.json` body, references.zig scans and
//! resolves triple-slash directives.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tsconfig = @import("../tsconfig.zig");
const paths = @import("paths.zig");
const pkgjson = @import("package_json.zig");
const references = @import("references.zig");

/// Resolution's only failure mode is allocation. Spelled with the standard
/// error set rather than the link layer's alias so this file has no back-edge
/// to modules.zig (`modules.Error` IS this set).
const Error = Allocator.Error;
const blockedSubpathPath = paths.blockedSubpathPath;
const dirnamePart = paths.dirnamePart;
const endsWithAny = paths.endsWithAny;
const joinNormalize = paths.joinNormalize;
const normalizePath = paths.normalizePath;

/// `package.json` readers — pure text, no filesystem (package_json.zig). The
/// resolver is the only thing that asks a `package.json` a question, so these
/// stay private here.
const packageTypesField = pkgjson.packageTypesField;
const packageMainField = pkgjson.packageMainField;
const exportsOf = pkgjson.exportsOf;
const exportsIsSubpathMap = pkgjson.exportsIsSubpathMap;
const exportsConditionActive = pkgjson.exportsConditionActive;
const typesVersionsPaths = pkgjson.typesVersionsPaths;
const mapTypesVersions = pkgjson.mapTypesVersions;

/// Triple-slash reference directives (references.zig), re-exported: a
/// specifier and a directive are two spellings of the same question, and every
/// caller already holds the resolver.
pub const RefDirective = references.RefDirective;
pub const scanReferences = references.scanReferences;
const resolveReference = references.resolveReference;

/// Resolve a relative-or-package file stem with the documented extension
/// order. `stem` is a normalized path relative to `dir`. Public because
/// tsconfig `paths` mapping feeds mapped candidates through it.
pub fn resolveStem(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8) Error!?[]u8 {
    return resolveStemFs(.{ .io = io, .dir = dir }, alloc, stem);
}

/// `resolveStem` with the resolution context (`Fs`) threaded in — the same
/// probes under `f.cache`'s memo, or every stat re-issued without it.
pub fn resolveStemFs(f: Fs, alloc: Allocator, stem: []const u8) Error!?[]u8 {
    var buf: [6][]const u8 = undefined;
    var n: usize = 0;
    // Candidate paths are built with `alloc` (a scratch arena, freed after
    // the file's specifiers resolve). A previous fixed 256-byte buffer
    // silently failed on deep node_modules/@types paths — a wrong "module
    // not found" — so there is no length cap here.
    // A specifier that already names a TypeScript extension is not taken
    // literally: tsc strips the extension and re-probes the whole family
    // (`tryAddingExtensions`), so `./subDays.ts` finds `subDays.d.ts`. That is
    // how date-fns v4 ships — every barrel entry is `export * from "./x.ts"`
    // and only `x.d.ts` exists. `.mts`/`.cts` keep to their own family.
    if (endsWithAny(stem, &.{ ".d.mts", ".mts" })) {
        const base = stem[0 .. stem.len - (if (std.mem.endsWith(u8, stem, ".d.mts")) ".d.mts".len else ".mts".len)];
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.mts", .{base});
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.d.mts", .{base});
        n = 2;
        return tryCandidates(f, alloc, buf[0..n]);
    }
    if (endsWithAny(stem, &.{ ".d.cts", ".cts" })) {
        const base = stem[0 .. stem.len - (if (std.mem.endsWith(u8, stem, ".d.cts")) ".d.cts".len else ".cts".len)];
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.cts", .{base});
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.d.cts", .{base});
        n = 2;
        return tryCandidates(f, alloc, buf[0..n]);
    }
    if (endsWithAny(stem, &.{ ".d.ts", ".ts", ".tsx" })) {
        const tsx = std.mem.endsWith(u8, stem, ".tsx");
        const cut: usize = if (std.mem.endsWith(u8, stem, ".d.ts"))
            ".d.ts".len
        else if (tsx) ".tsx".len else ".ts".len;
        const base = stem[0 .. stem.len - cut];
        // `.tsx` prefers its exact match first; `.ts`/`.d.ts` prefer `.ts`.
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, if (tsx) "tsx" else "ts" });
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, if (tsx) "ts" else "tsx" });
        buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 3;
        return tryCandidates(f, alloc, buf[0..n]);
    }
    if (std.mem.endsWith(u8, stem, ".js") or std.mem.endsWith(u8, stem, ".jsx")) {
        const base = stem[0..std.mem.lastIndexOfScalar(u8, stem, '.').?];
        buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{base});
        buf[1] = try std.fmt.allocPrint(alloc, "{s}.tsx", .{base});
        buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        n = 3;
        return tryCandidates(f, alloc, buf[0..n]);
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
        return tryCandidates(f, alloc, buf[0..n]);
    }
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.tsx", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{stem});
    buf[3] = try std.fmt.allocPrint(alloc, "{s}/index.ts", .{stem});
    buf[4] = try std.fmt.allocPrint(alloc, "{s}/index.tsx", .{stem});
    buf[5] = try std.fmt.allocPrint(alloc, "{s}/index.d.ts", .{stem});
    n = 6;
    return tryCandidates(f, alloc, buf[0..n]);
}

/// Resolve a package *directory* (base-relative, e.g. a visible
/// `node_modules/@types/<name>`) to its main declaration file: the
/// `package.json` `"types"`/`"typings"` entry when present, else `index.d.ts`
/// (via `resolveStem`). The returned path is base-relative and owned by
/// `alloc`, or null when nothing resolves. Used by the tsconfig auto-`@types`
/// inclusion (`tsconfig.collectAutoTypes`) to turn each visible `@types/<name>`
/// directory into an ambient program root the way tsc's default `typeRoots`
/// does — this is a package *directory*, not a bare specifier, so it never
/// walks `node_modules` and never falls back to JS.
pub fn resolveTypesPackageMain(io: Io, alloc: Allocator, dir: Io.Dir, pkg_dir: []const u8) Error!?[]u8 {
    const f: Fs = .{ .io = io, .dir = dir };
    const pj_path = try std.fmt.allocPrint(alloc, "{s}/package.json", .{pkg_dir});
    defer alloc.free(pj_path);
    if (try f.packageJson(alloc, pj_path)) |pj| {
        defer pj.deinit(alloc);
        if (packageTypesField(pj.text)) |types_rel| {
            const stem = try joinNormalize(alloc, pkg_dir, types_rel);
            defer alloc.free(stem);
            if (try resolveStemFs(f, alloc, stem)) |p| return p;
        }
    }
    const idx = try std.fmt.allocPrint(alloc, "{s}/index", .{pkg_dir});
    defer alloc.free(idx);
    return resolveStemFs(f, alloc, idx);
}

/// Resolve a type-reference directive name (a `compilerOptions.types` entry)
/// through tsc's *secondary* lookup: ordinary node-module resolution of the
/// name, walking `node_modules` up from `from_dir`. tsc treats every `types`
/// entry as a type-reference directive — the primary lookup scans the
/// `typeRoots` (`@types/<name>`, handled by the caller), and when that misses
/// it resolves the name as a package, so `types: ["vitest/globals"]` reaches
/// `node_modules/vitest/globals.d.ts` through the package's `exports` map (or
/// its `"types"` field / `index.d.ts` for a bare name). Declarations only: a
/// type directive never falls back to a JS `main`.
///
/// `use_exports` is the caller's `resolvePackageJsonExports` (see
/// `ResolveOpts.resolve_pkg_json_exports`): a type directive is resolved by the
/// same node walk as an import, so the option gates its `exports` map too. The
/// caller passes it explicitly because this entry point runs during config load,
/// before any `ResolveCache` exists.
pub fn resolveTypeDirective(io: Io, alloc: Allocator, dir: Io.Dir, from_dir: []const u8, name: []const u8, use_exports: bool) Error!?[]u8 {
    return resolvePackage(.{ .io = io, .dir = dir }, alloc, from_dir, name, false, use_exports);
}

/// Stat a `*.json` stem (already `dir`-relative, ending in `.json`) as a
/// resolved JSON module. Unlike `resolveStem`, no extension probing: the file
/// must exist exactly as named (tsc resolves a JSON specifier only to the JSON
/// file itself). Returns the path (owned by `alloc`) or null. Public so the CLI
/// driver can stat a `paths`-mapped `*.json` candidate (which `resolveStem`
/// would not find).
pub fn resolveJsonFile(io: Io, alloc: Allocator, dir: Io.Dir, stem: []const u8) Error!?[]u8 {
    return resolveJsonFileFs(.{ .io = io, .dir = dir }, alloc, stem);
}

/// `resolveJsonFile` with the resolution context (`Fs`) threaded in.
fn resolveJsonFileFs(f: Fs, alloc: Allocator, stem: []const u8) Error!?[]u8 {
    if (try f.exists(stem)) return try alloc.dupe(u8, stem);
    return null;
}

pub fn fsProbeCount() u64 {
    return fs_probes.load(.monotonic);
}

pub fn resetFsProbeCount() void {
    fs_probes.store(0, .monotonic);
}

/// Memoizes `resolveSpecifier` over the discovery run. A module
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
    /// with no memo read or write — the "before" leg of the memo benchmark
    /// (`--no-resolve-cache`), and a correctness oracle for the cache.
    enabled: bool = true,
    /// Resolution options folded into the (dir, spec, config) pure function.
    opts: ResolveOpts = .{},
    /// Filesystem-fact memos under the specifier memo (S1-lite). Shares
    /// `enabled`: `--no-resolve-cache` disables both layers at once.
    fs: FsCache,
    /// Cached realpath of `dir` (arena-owned), used to re-relativize canonical
    /// paths; computed lazily on the first `node_modules` resolution.
    real_base: ?[]const u8 = null,
    real_base_done: bool = false,
    lookups: u64 = 0,
    hits: u64 = 0,

    pub fn init(arena: Allocator, enabled: bool, opts: ResolveOpts) ResolveCache {
        return .{ .arena = arena, .enabled = enabled, .opts = opts, .fs = .{ .arena = arena } };
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
            const r = (try resolveSpecifierFs(.{ .io = io, .dir = dir, .opts = rc.opts }, scratch, importer, spec)) orelse return null;
            return try rc.canonicalize(io, scratch, dir, r);
        }
        rc.lookups += 1;
        const importer_dir = dirnamePart(importer);
        // Build the key in scratch; only copy it into `arena` on a miss.
        const key = try std.fmt.allocPrint(scratch, "{s}\x00{s}", .{ importer_dir, spec });
        if (rc.map.get(key)) |cached| {
            rc.hits += 1;
            return cached;
        }
        const resolved = try resolveSpecifierFs(.{ .io = io, .dir = dir, .cache = &rc.fs, .opts = rc.opts }, scratch, importer, spec);
        const owned: ?[]const u8 = if (resolved) |p| try rc.canonicalize(io, scratch, dir, p) else null;
        try rc.map.put(rc.arena, try rc.arena.dupe(u8, key), owned);
        return owned;
    }

    /// Resolve a triple-slash `/// <reference>` directive to the *canonical* path
    /// of its target — the reference-directive twin of `resolve`.
    ///
    /// Reference directives are the second way a file enters the module graph
    /// (the third is a program root), and they used to skip the canonical-path
    /// step `resolve` applies, which made every symlinked route to a package a
    /// separate copy of it. In a pnpm workspace that is not an edge case: a
    /// `/// <reference types="node" />` from any package resolves through the
    /// hoisted `.pnpm/node_modules/@types/node` symlink, and the whole
    /// `@types/node` bundle — 130+ files reached from there by `path` refs —
    /// lands in the graph a second time, byte-identical to the copy already in
    /// it and with its own symbol universe. Canonicalizing here collapses those
    /// routes onto one file id, exactly like tsc's realpath-keyed file map.
    pub fn resolveRef(
        rc: *ResolveCache,
        io: Io,
        scratch: Allocator,
        dir: Io.Dir,
        importer: []const u8,
        ref: RefDirective,
    ) Error!?[]const u8 {
        const f: Fs = .{ .io = io, .dir = dir, .cache = if (rc.enabled) &rc.fs else null, .opts = rc.opts };
        const resolved = (try resolveReference(f, scratch, importer, ref)) orelse return null;
        return try rc.canonicalize(io, scratch, dir, resolved);
    }

    /// Resolve one *already substituted* tsconfig `paths` candidate under this
    /// cache's options (`resolvePathsCandidate`). The `paths` leg deliberately
    /// bypasses the specifier memo — a different decision, rare, and one probe
    /// — but it is still a probe of this run and must see the same
    /// `ResolveOpts`: `moduleSuffixes` widens every candidate file name the
    /// resolver stats, this one included.
    pub fn pathsCandidate(rc: *ResolveCache, io: Io, scratch: Allocator, dir: Io.Dir, cand: []const u8) Error!?[]u8 {
        return resolvePathsCandidateFs(.{ .io = io, .dir = dir, .opts = rc.opts }, scratch, cand);
    }

    /// The canonical path of an already-resolved file — for graph entry points
    /// that bypass `resolve` (program roots, notably the auto-included
    /// `@types/*` ambient roots, which pnpm exposes through a symlinked
    /// `node_modules/@types/<pkg>`). Arena-owned; a no-op outside
    /// `node_modules`, so project files keep the path the user typed.
    pub fn canonicalPath(rc: *ResolveCache, io: Io, scratch: Allocator, dir: Io.Dir, raw: []const u8) Error![]const u8 {
        return rc.canonicalize(io, scratch, dir, raw);
    }

    /// The `package.json` text at `path`, or null when it is absent/unreadable
    /// — the same memoized read resolution itself does, exposed for the
    /// package-identity pass (package_id.zig), which needs the `name`/`version`
    /// of the package a resolved file came out of. Almost always a memo hit:
    /// resolving into a package reads its `package.json` first.
    ///
    /// The result belongs to the cache arena on the cached leg and to `scratch`
    /// on the uncached one, so it is only valid until the caller's next scratch
    /// reset.
    pub fn packageJsonText(
        rc: *ResolveCache,
        io: Io,
        dir: Io.Dir,
        scratch: Allocator,
        path: []const u8,
    ) Error!?[]const u8 {
        const f: Fs = .{ .io = io, .dir = dir, .cache = if (rc.enabled) &rc.fs else null, .opts = rc.opts };
        const pj = (try f.packageJson(scratch, path)) orelse return null;
        return pj.text;
    }

    /// The realpath of `dir` (cached, arena-owned) for re-relativizing canonical
    /// paths, or null if the OS call failed (then canonical paths stay absolute).
    ///
    /// `Dir.realPath` fcntls the directory HANDLE, and the CLI's base directory
    /// is `Io.Dir.cwd()`, whose handle is the sentinel `AT.FDCWD` — not a real
    /// descriptor, so the fcntl fails with EBADF and every canonicalized
    /// `node_modules` path used to stay absolute for the whole (normal) run.
    /// `realPathFile(".")` answers for both shapes: libc `realpath` for the
    /// cwd sentinel, `openat`+fcntl for a real handle. `realPath` is still
    /// tried first — it is one syscall and needs no path buffer.
    fn dirRealBase(rc: *ResolveCache, io: Io, dir: Io.Dir) ?[]const u8 {
        if (!rc.real_base_done) {
            rc.real_base_done = true;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.realPath(io, &buf)) |n| {
                rc.real_base = rc.arena.dupe(u8, buf[0..n]) catch null;
            } else |_| if (dir.realPathFile(io, ".", &buf)) |n| {
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
    /// `node_modules` file (the resolve memo collapses repeats), never per probe
    /// — and, with the `FsCache` enabled, one per resolved *directory* (the
    /// package's whole symlink chain is shared by every file in it).
    fn canonicalize(rc: *ResolveCache, io: Io, scratch: Allocator, dir: Io.Dir, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOf(u8, raw, "node_modules") == null) return rc.arena.dupe(u8, raw);
        // A synthetic `exports`-blocked subpath names no on-disk file: today's
        // `realPathFile` fails on it and the raw path is kept. Skip it before the
        // per-directory realpath, which would happily canonicalize its (existing)
        // parent and hand back a different path. Saves a doomed syscall too.
        if (paths.isBlockedSubpathPath(raw)) return rc.arena.dupe(u8, raw);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = if (rc.enabled)
            (try rc.fs.realPathOfFile(io, dir, scratch, raw)) orelse return rc.arena.dupe(u8, raw)
        else abs: {
            const n = dir.realPathFile(io, raw, &buf) catch return rc.arena.dupe(u8, raw);
            break :abs buf[0..n];
        };
        // Debug-only oracle for the per-directory realpath: it can only diverge
        // from the direct call if the file's own last component is a symlink.
        if (builtin.mode == .Debug and rc.enabled) {
            var vbuf: [std.fs.max_path_bytes]u8 = undefined;
            if (dir.realPathFile(io, raw, &vbuf)) |vn| {
                std.debug.assert(std.mem.eql(u8, vbuf[0..vn], abs));
            } else |_| {}
        }
        if (rc.dirRealBase(io, dir)) |b| {
            if (abs.len > b.len + 1 and std.mem.startsWith(u8, abs, b) and abs[b.len] == '/') {
                return rc.arena.dupe(u8, abs[b.len + 1 ..]);
            }
        }
        return rc.arena.dupe(u8, abs);
    }
};

/// Filesystem-shape memos shared by one resolution run (S1-lite). Resolution
/// is a pure function of the filesystem and ztsc is a single-shot batch
/// process, so any probe it repeats is pure waste. Where `ResolveCache` memoizes
/// a whole `(importer_dir, spec)` answer, this memoizes the *filesystem facts*
/// underneath it — the part a first-time specifier still pays. Four memos, each
/// keyed on the exact path string probed today (never canonicalized: the key
/// space IS the behavior):
///
///  1. `nm_dirs` — does `<d>/node_modules` exist as a directory? The bare-
///     specifier walk climbs to the filesystem root and most levels have no
///     `node_modules` at all; one stat per level then answers every probe that
///     would have gone inside it. This is the big one: 169k of the dogfood
///     project's 257k resolve-phase syscalls (~99 ms) hit a path under a
///     `<d>/node_modules` that does not exist.
///  2. `pkg_json` — `package.json` text by path, misses cached too.
///     `resolvePackageAt` reads one at every walk level (27.9k reads for 616
///     distinct existing files; ~25k of the reads are ENOENT).
///  3. `real_dirs` — realpath keyed by DIRECTORY. Canonicalizing a resolved
///     `node_modules` file is realpath(dirname) + "/" + basename, and every file
///     in one package directory shares that whole symlink chain (deep under
///     pnpm), so 6.6k realpath calls collapse onto 1.2k directories.
///  4. `stat_files` — does this exact *candidate* path exist as a file? Once
///     (1) has short-circuited the empty walk levels, what is left is the stem
///     probing inside `node_modules` directories that DO exist: six candidates
///     per stem (`.ts`, `.tsx`, `.d.ts`, `index.*`), again for `@types/<pkg>`,
///     again per walk level, again per `exports` target. On the dogfood project
///     that is 55.5k of the 67.2k remaining probes over 23.1k distinct paths —
///     the same `node_modules/react/index.d.ts` re-statted by every specifier
///     that walks past it. One stat per distinct path answers all of them.
///
/// A fifth memo is not a stat but the parse on top of one: `pkg_exports` holds
/// the `exports` value of a `package.json` (`tsconfig.parseJsonc` of its text,
/// arena-owned). (2) already made each body read once, but every walk level of
/// every specifier re-PARSED the body it got back — thousands of parses of the
/// same few hundred files. The memo makes it one parse per file.
///
/// (3) is the only leg that is not identical by construction: it differs from
/// `realPathFile(path)` exactly when the final component is itself a symlink
/// (package *directories* are symlinked by pnpm/yarn; declaration files are
/// not). Debug builds therefore check it against the direct call on every use,
/// making the conformance suite a standing oracle. The synthetic
/// `exports`-blocked subpath — which names no on-disk file — is excluded
/// explicitly, since its parent directory does exist and would canonicalize.
///
/// Memory is negligible against the program: on the dogfood project 4.9 MiB
/// (1,907 + 1,373 + 1,218 + 23,107 + 614 entries) — half of it cached
/// `package.json` text, the rest candidate-path keys — against a ~350 MB peak
/// RSS, which did not move outside run-to-run noise. `--timing` prints the entry
/// counts, the byte total and the two hit rates.
///
/// Measured on the dogfood project (ReleaseFast, --checkers=4, medians):
/// resolve 159 ms → 127 ms and 67,240 → 34,886 FS probes. The stat memo is
/// 55,461 lookups / 58.3% hits (−32,354 syscalls, ~19 ms); the exports memo is
/// 2,443 lookups / 74.9% hits (1,829 parses avoided, ~13 ms).
///
/// Not thread-safe, deliberately: resolution is single-owner (the main thread in
/// the parallel driver, the sole thread in `buildProgram`) and each program owns
/// its own cache. Lives inside `ResolveCache` and shares its `enabled` flag, so
/// `--no-resolve-cache` turns the entire caching layer off in one switch and
/// stays a complete correctness oracle for it.
pub const FsCache = struct {
    /// Persistent storage for keys, cached `package.json` bodies and realpaths.
    /// Must outlive the per-file resolve scratch resets — the caller's arena.
    arena: Allocator,
    /// `<d>` → `<d>/node_modules` exists and is a directory.
    nm_dirs: std.StringHashMapUnmanaged(bool) = .empty,
    /// `package.json` path → its text, or null when absent/unreadable.
    pkg_json: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// directory path → its realpath (absolute), or null when the OS call failed.
    real_dirs: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// candidate path → it exists and is a regular file.
    stat_files: std.StringHashMapUnmanaged(bool) = .empty,
    /// `package.json` path → its `exports` value, or null when the file has no
    /// `exports` key (or does not parse — the uncached leg ignores it too).
    pkg_exports: std.StringHashMapUnmanaged(?tsconfig.Value) = .empty,
    /// `package.json` path → the `typesVersions` mapping object that applies to
    /// this compiler version, or null (no key, no matching version range, or a
    /// shape that is not an object). Same memo discipline as `pkg_exports`.
    pkg_typesver: std.StringHashMapUnmanaged(?tsconfig.Value.Object) = .empty,
    /// Arena bytes the memos own (keys + values), for the `--timing` line.
    bytes: usize = 0,
    /// `stat_files` scoreboard: calls, and calls answered from memory.
    stat_lookups: u64 = 0,
    stat_hits: u64 = 0,
    /// `pkg_exports` scoreboard: `parseJsonc` calls asked for, and avoided.
    exports_lookups: u64 = 0,
    exports_hits: u64 = 0,

    /// True when `<d>/node_modules` exists as a directory. When it does not, no
    /// `resolvePackageAt` at that level can resolve anything, so the level's
    /// entire probe set (a `package.json` read plus up to six stem candidates,
    /// again for the `@types/` twin, again for the allowJs phase) is skipped.
    fn hasNodeModules(fc: *FsCache, io: Io, dir: Io.Dir, scratch: Allocator, d: []const u8) Error!bool {
        if (fc.nm_dirs.get(d)) |v| return v;
        const path: []const u8 = if (d.len == 0)
            "node_modules"
        else
            try std.fmt.allocPrint(scratch, "{s}/node_modules", .{d});
        bumpProbe();
        const exists = if (dir.statFile(io, path, .{})) |st| st.kind == .directory else |_| false;
        const key = try fc.arena.dupe(u8, d);
        fc.bytes += key.len;
        try fc.nm_dirs.put(fc.arena, key, exists);
        return exists;
    }

    /// `package.json` text at `path` (cache-arena owned, valid for the run), or
    /// null when it does not exist / cannot be read. Mirrors the uncached read
    /// exactly, including the 1 MiB limit whose overflow reads as "absent".
    fn packageJson(fc: *FsCache, io: Io, dir: Io.Dir, path: []const u8) Error!?[]const u8 {
        if (fc.pkg_json.get(path)) |v| return v;
        bumpProbe();
        const text: ?[]const u8 = if (dir.readFileAlloc(io, path, fc.arena, .limited(1 << 20))) |t| t else |_| null;
        const key = try fc.arena.dupe(u8, path);
        fc.bytes += key.len + if (text) |t| t.len else 0;
        try fc.pkg_json.put(fc.arena, key, text);
        return text;
    }

    /// Does `path` exist as a regular file? The memoized `fileExists`: one stat
    /// per distinct candidate path for the run, keyed on the exact string
    /// probed. Identical by construction — the miss leg IS `fileExists`.
    fn statFileCached(fc: *FsCache, io: Io, dir: Io.Dir, path: []const u8) Error!bool {
        fc.stat_lookups += 1;
        if (fc.stat_files.get(path)) |v| {
            fc.stat_hits += 1;
            return v;
        }
        const exists = fileExists(io, dir, path);
        const key = try fc.arena.dupe(u8, path);
        fc.bytes += key.len;
        try fc.stat_files.put(fc.arena, key, exists);
        return exists;
    }

    /// The `exports` value of the `package.json` at `path`, whose text is
    /// `text` (the `pkg_json` body). Parsed at most once per path, into the
    /// cache arena so the value outlives the per-file scratch reset — the
    /// parser copies every string it returns, so nothing slices into `text`.
    /// A parse error or a non-object root reads as "no exports", exactly as the
    /// uncached leg's `else |_| {}` / `else => {}` do.
    fn packageExports(fc: *FsCache, path: []const u8, text: []const u8) Error!?tsconfig.Value {
        fc.exports_lookups += 1;
        if (fc.pkg_exports.get(path)) |v| {
            fc.exports_hits += 1;
            return v;
        }
        const val = exportsOf(fc.arena, text);
        // Reuse the `pkg_json` key when it is already arena-owned (it always is
        // when the body came from that memo) instead of duping the path twice.
        const key = fc.pkg_json.getKey(path) orelse key: {
            const k = try fc.arena.dupe(u8, path);
            fc.bytes += k.len;
            break :key k;
        };
        try fc.pkg_exports.put(fc.arena, key, val);
        return val;
    }

    /// The applicable `typesVersions` mapping of the `package.json` at `path`
    /// (memoized exactly like `packageExports`; see `typesVersionsPaths`).
    fn packageTypesVersions(fc: *FsCache, path: []const u8, text: []const u8) Error!?tsconfig.Value.Object {
        if (fc.pkg_typesver.get(path)) |v| return v;
        const val = typesVersionsPaths(fc.arena, text);
        const key = fc.pkg_json.getKey(path) orelse key: {
            const k = try fc.arena.dupe(u8, path);
            fc.bytes += k.len;
            break :key k;
        };
        try fc.pkg_typesver.put(fc.arena, key, val);
        return val;
    }

    /// Realpath of directory `d` (cache-arena owned), or null when the OS call
    /// failed. One syscall per distinct directory for the whole run.
    fn realDir(fc: *FsCache, io: Io, dir: Io.Dir, d: []const u8) Error!?[]const u8 {
        if (fc.real_dirs.get(d)) |v| return v;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var val: ?[]const u8 = null;
        if (dir.realPathFile(io, d, &buf)) |n| {
            val = try fc.arena.dupe(u8, buf[0..n]);
        } else |_| {}
        const key = try fc.arena.dupe(u8, d);
        fc.bytes += key.len + if (val) |v| v.len else 0;
        try fc.real_dirs.put(fc.arena, key, val);
        return val;
    }

    /// Canonical absolute path of the *file* `path`, as realpath(dirname) + "/"
    /// + basename (the directory leg memoized). Null when `path` has no
    /// directory part or its directory does not resolve — the caller then keeps
    /// the raw path, exactly as a failed `realPathFile` does today. Result is
    /// `scratch`-owned.
    fn realPathOfFile(fc: *FsCache, io: Io, dir: Io.Dir, scratch: Allocator, path: []const u8) Error!?[]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        const d = if (slash == 0) "/" else path[0..slash];
        const base = path[slash + 1 ..];
        const rd = (try fc.realDir(io, dir, d)) orelse return null;
        const sep: []const u8 = if (std.mem.endsWith(u8, rd, "/")) "" else "/";
        return try std.fmt.allocPrint(scratch, "{s}{s}{s}", .{ rd, sep, base });
    }

    /// Entry counts for the `--timing` scoreboard.
    pub fn entryCounts(fc: *const FsCache) struct {
        nm_dirs: u32,
        pkg_json: u32,
        real_dirs: u32,
        stat_files: u32,
        pkg_exports: u32,
    } {
        return .{
            .nm_dirs = fc.nm_dirs.count(),
            .pkg_json = fc.pkg_json.count(),
            .real_dirs = fc.real_dirs.count(),
            .stat_files = fc.stat_files.count(),
            .pkg_exports = fc.pkg_exports.count(),
        };
    }
};

/// The filesystem half of one resolution, handed around as a unit instead of
/// the `io` / `dir` / `fs` / `opts` quartet that used to thread through every
/// private function in this file.
///
/// `cache == null` is the uncached leg (`--no-resolve-cache`): identical
/// answers, every stat re-issued and every `package.json` re-read. That fork
/// lives in the methods below and nowhere else — callers never see which leg
/// they are on, which is what makes the uncached leg a usable oracle for the
/// cached one.
pub const Fs = struct {
    io: Io,
    dir: Io.Dir,
    /// Filesystem-fact memos, or null for the uncached leg.
    cache: ?*FsCache = null,
    /// The per-run options folded into resolution's pure function.
    opts: ResolveOpts = .{},

    /// Does `path` exist as a regular file?
    fn exists(f: Fs, path: []const u8) Error!bool {
        if (f.cache) |fc| return fc.statFileCached(f.io, f.dir, path);
        return fileExists(f.io, f.dir, path);
    }

    /// True when `<d>/node_modules` exists as a directory — the walk-level
    /// short-circuit. Without the memo there is nothing cheaper than the
    /// probes it would skip, so the uncached leg simply says yes and lets them
    /// run, exactly as before.
    fn hasNodeModules(f: Fs, scratch: Allocator, d: []const u8) Error!bool {
        const fc = f.cache orelse return true;
        return fc.hasNodeModules(f.io, f.dir, scratch, d);
    }

    /// The `package.json` at `path`, or null when it does not exist / cannot
    /// be read. Both legs share the 1 MiB limit whose overflow reads as
    /// "absent". Through the memo the body belongs to the cache arena and
    /// `PkgJson.deinit` is a no-op; on the uncached leg it is `scratch`-owned
    /// and the caller must `deinit` it, which is the one lifetime difference
    /// between the two.
    fn packageJson(f: Fs, scratch: Allocator, path: []const u8) Error!?PkgJson {
        if (f.cache) |fc| {
            const text = (try fc.packageJson(f.io, f.dir, path)) orelse return null;
            return .{ .path = path, .text = text };
        }
        bumpProbe();
        const text = f.dir.readFileAlloc(f.io, path, scratch, .limited(1 << 20)) catch return null;
        return .{ .path = path, .text = text, .owned = true };
    }

    /// The `exports` value of `pj` — one parse per `package.json` path through
    /// the memo, a parse into `scratch` without it.
    fn exports(f: Fs, scratch: Allocator, pj: PkgJson) Error!?tsconfig.Value {
        if (f.cache) |fc| return fc.packageExports(pj.path, pj.text);
        return exportsOf(scratch, pj.text);
    }

    /// The `typesVersions` mapping of `pj` that applies to this compiler,
    /// memoized the same way as `exports`.
    fn typesVersions(f: Fs, scratch: Allocator, pj: PkgJson) Error!?tsconfig.Value.Object {
        if (f.cache) |fc| return fc.packageTypesVersions(pj.path, pj.text);
        return typesVersionsPaths(scratch, pj.text);
    }
};

/// A `package.json` body together with the path it came from — the key the
/// parse memos (`exports`, `typesVersions`) hang off. `owned` marks the
/// uncached leg's scratch copy.
const PkgJson = struct {
    path: []const u8,
    text: []const u8,
    owned: bool = false,

    fn deinit(pj: PkgJson, alloc: Allocator) void {
        if (pj.owned) alloc.free(pj.text);
    }
};

/// Per-run resolution options that are not a pure function of (dir, spec):
/// `resolveJsonModule` and the `baseUrl` bare-specifier anchor. Carried on the
/// `ResolveCache` (set once at init) so `resolveSpecifier`'s determinism
/// contract — a pure function of `(dir, spec, config)` — is preserved with the
/// config folded in explicitly.
pub const ResolveOpts = struct {
    /// tsconfig `resolveJsonModule`: a `*.json` specifier that names an existing
    /// file resolves to it (typed opaquely as `any`; see `json_module_source`).
    /// Relative, `baseUrl`-anchored, and `node_modules` forms all resolve — a
    /// package's data files are ordinary files at ordinary paths
    /// (`resolveJsonPackage`).
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
    /// ztsc never parses/checks the JS source. When such a file came out of
    /// `node_modules`, tsc types the module `any` too and reports TS7016 at the
    /// specifier under `noImplicitAny`; the linker does the same
    /// (`modules.untypedJsModule`). A project-local `./x.js` stays silent, as
    /// in tsc, where that file IS added to the program.
    ///
    /// Note this flag does not gate the `exports`-map JavaScript target: a
    /// package whose map names only JavaScript is untyped with `allowJs` on or
    /// off, and tsc reports TS7016 either way (`resolvePackage` phase 2).
    allow_js: bool = false,
    /// tsconfig `resolvePackageJsonExports`. When false, a `package.json`
    /// `"exports"` map is ignored ENTIRELY — the map neither resolves a
    /// specifier nor hides the legacy fields, so every bare specifier and
    /// subpath takes the pre-`exports` path (`"types"`/`"typings"`, the
    /// declaration twin of `"main"`, `index.*`, a subpath's own directory
    /// `package.json`) and an unmatched subpath is no longer blocked.
    ///
    /// The default is `true` and stays true regardless of `moduleResolution`:
    /// tsc derives it (on for node16/nodenext/bundler, never used under node10),
    /// while ztsc always runs the bundler algorithm and accepts-and-ignores
    /// `moduleResolution`, so the bundler default is the only one it can have.
    /// Only an explicit `false` in a tsconfig changes any resolution.
    ///
    /// This is not a niche switch: a package that publishes an `exports` map
    /// with no `types` condition hides its own top-level `"types"` key, and a
    /// project that hits enough of those turns the option off wholesale rather
    /// than patch each dependency (`@hocuspocus/*` and `redlock` in the outline
    /// app: `exports` names only `.esm.js`/`.cjs`, while a perfectly good
    /// `index.d.ts` sits behind `"types"`).
    resolve_pkg_json_exports: bool = true,
    /// tsconfig `resolvePackageJsonImports`. When false, a `#`-prefixed
    /// ("private imports") specifier ignores the importing package's
    /// `package.json` `"imports"` map and stays unresolved — a `#` name can
    /// never be a `node_modules` directory, so there is no fallback.
    ///
    /// Same default reasoning as `resolve_pkg_json_exports`. See
    /// `resolveImportsSpecifier` for what the map supports (package-relative
    /// targets, conditions, wildcards) and what it does not (a target that
    /// names another package by name).
    resolve_pkg_json_imports: bool = true,
    /// tsconfig `moduleSuffixes` (TS 4.7), in the configured order. Every
    /// candidate file name is probed once per suffix, the suffix inserted
    /// BEFORE the extension — tsc's `tryFile`, which wraps every single-file
    /// probe the resolver makes (`probeCandidate`). The empty string means the
    /// unsuffixed name. The default — an empty slice — is the option's absence
    /// and the fast path: one stat per candidate, as if the feature did not
    /// exist.
    ///
    /// It lives here rather than in a module-level global because it is
    /// exactly what `ResolveOpts` is for: a per-run input to resolution's pure
    /// function of `(dir, spec, config)`. As a global it was invisible at every
    /// call site and reachable by entry points that run BEFORE the driver
    /// installs it (config-time type-directive resolution), which quietly gave
    /// those a different answer than the same probe during discovery.
    module_suffixes: []const []const u8 = &.{},
};

// =========================================================================
// private implementation
// =========================================================================

/// Count of filesystem probes issued during module resolution — every
/// `statFile` and every `package.json` read. It is the resolution cache's
/// scoreboard ("resolution syscall counts before/after"): with
/// the `(importer_dir, spec)` memo the same specifier imported from K files
/// walks `node_modules` once, not K times, so this collapses on inputs with
/// shared specifiers.
///
/// Resolution runs single-owner (the main thread in the parallel driver, the
/// sole thread in `buildProgram`), so the counter is never truly contended,
/// but it is atomic anyway — cheap insurance against a future parallel caller
/// and race-free under the test runner's threads.
///
/// It stays a module-level global on purpose, unlike `moduleSuffixes`, which
/// moved onto `ResolveOpts`: a probe is issued from legs that hold no cache
/// object at all — the uncached `--no-resolve-cache` leg (`Fs.cache == null`)
/// and the config-time entry points (`resolveTypeDirective`,
/// `resolveTypesPackageMain`), which run before any `ResolveCache` exists. A
/// counter on `FsCache` would silently stop counting exactly the probes the
/// scoreboard exists to compare against. It is a pure observation — no
/// resolution reads it — so a global costs nothing in answers.
var fs_probes: std.atomic.Value(u64) = .init(0);

inline fn bumpProbe() void {
    _ = fs_probes.fetchAdd(1, .monotonic);
}

fn fileExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    bumpProbe();
    const st = dir.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Which file an `exports` target is allowed to land on.
///
/// tsc resolves an `exports` map twice, mirroring its extension masks: first
/// for TypeScript/declaration files, and — when that finds nothing — again for
/// the raw JavaScript the target actually names. The second pass is not a
/// successful *type* resolution: the module has no declarations, so tsc types
/// it `any` and reports TS7016 at the specifier ("Could not find a declaration
/// file for module 'x'. '<the JS file>' implicitly has an 'any' type"). It
/// happens with `allowJs` on or off — the JS entry sits in `node_modules`, so
/// it is never added to the program either way.
const ExportProbe = enum {
    /// The declaration twin of the target (`./x.mjs` → `./x.d.mts`/`./x.d.ts`)
    /// or the target itself when it already names a `.ts`/`.d.ts`.
    declarations,
    /// The target itself, when it names an existing `.js`/`.jsx`/`.mjs`/`.cjs`
    /// file. Loaded as an opaque `any` module.
    javascript,
};

/// Resolve `subpath` ("." for the package root, "./x" for a subpath) against a
/// package.json `exports` value, returning an existing file under `pkg_dir`
/// (owned by `alloc`) or null. Pure function of the value + FS.
fn resolveExportsField(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    exports_val: tsconfig.Value,
    subpath: []const u8,
    probe: ExportProbe,
) Error!?[]u8 {
    switch (exports_val) {
        .string => |s| {
            // Sugar: a string `exports` defines only the package root ".".
            if (std.mem.eql(u8, subpath, ".")) return statExportTarget(f, alloc, pkg_dir, s, "", probe);
            return null;
        },
        .object => |obj| {
            if (exportsIsSubpathMap(obj)) return resolveExportsSubpath(f, alloc, pkg_dir, obj, subpath, probe);
            // A bare conditions object (no "./" keys) is sugar for the "." target.
            if (!std.mem.eql(u8, subpath, ".")) return null;
            return resolveConditionalTarget(f, alloc, pkg_dir, exports_val, "", probe);
        },
        else => return null,
    }
}

/// Match `subpath` against a subpath map: an exact key first, then the
/// longest-prefix wildcard pattern (`"./*"`, `"./d3-*"`), Node's best-match
/// rule. The `*` captures the middle; the capture substitutes into the target.
fn resolveExportsSubpath(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    obj: tsconfig.Value.Object,
    subpath: []const u8,
    probe: ExportProbe,
) Error!?[]u8 {
    if (obj.get(subpath)) |v| return resolveConditionalTarget(f, alloc, pkg_dir, v, "", probe);
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
        return resolveConditionalTarget(f, alloc, pkg_dir, obj.vals[bi], capture, probe);
    }
    return null;
}

/// Resolve one `exports` target value with `*` bound to `star`: a string is a
/// path; `null` is a blocked subpath; an array is a fallback list (first that
/// resolves); an object is a conditions map (first active condition whose
/// target resolves, in declaration order — a failed target continues to the
/// next, matching tsc).
fn resolveConditionalTarget(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    target: tsconfig.Value,
    star: []const u8,
    probe: ExportProbe,
) Error!?[]u8 {
    switch (target) {
        .null => return null, // explicitly blocked (`"./esm": null`)
        .string => |s| return statExportTarget(f, alloc, pkg_dir, s, star, probe),
        .array => |arr| {
            for (arr) |elem| {
                if (try resolveConditionalTarget(f, alloc, pkg_dir, elem, star, probe)) |p| return p;
            }
            return null;
        },
        .object => |obj| {
            for (obj.keys, obj.vals) |key, v| {
                if (!exportsConditionActive(key)) continue;
                if (try resolveConditionalTarget(f, alloc, pkg_dir, v, star, probe)) |p| return p;
            }
            return null;
        },
        else => return null,
    }
}

/// Stat an `exports` target string (with `*` replaced by `star`) under
/// `pkg_dir`. The target names a runtime path; under `probe == .declarations`
/// its types file is either the target itself (already a
/// `.d.ts`/`.d.mts`/`.d.cts`) or the declaration sibling of a
/// `.js`/`.mjs`/`.cjs` (`.mjs`→`.d.mts`, `.cjs`→`.d.cts`, `.js`→`.d.ts` —
/// verified via `--traceResolution`). Under `probe == .javascript` it is the
/// runtime file itself. Returns the existing path (owned by `alloc`) or null.
fn statExportTarget(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    target: []const u8,
    star: []const u8,
    probe: ExportProbe,
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
    if (probe == .javascript) {
        // The runtime file itself, and only when the target explicitly names a
        // JavaScript extension. An extensionless or non-JS target ("./index",
        // "./style.css") stays unresolved: Node requires full paths in an
        // `exports` map, and a `.css`/`.json`/asset target is not a module tsc
        // would type at all. A target that already names TypeScript was either
        // found by the `.declarations` pass or does not exist.
        if (!endsWithAny(p, &.{ ".js", ".jsx", ".mjs", ".cjs" })) return null;
        return probeCandidate(f, alloc, p);
    }
    if (endsWithAny(p, &.{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".tsx" })) {
        cands[0] = p;
        n = 1;
    } else if (std.mem.endsWith(u8, p, ".mjs")) {
        // `.mts` closes the same gap the `.js` arm's `.ts` closes: a target
        // naming the EMITTED file in a project that is itself TypeScript, where
        // no `.d.mts` was emitted and the source is what exists.
        const base = p[0 .. p.len - ".mjs".len];
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.mts", .{base});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        cands[2] = try std.fmt.allocPrint(alloc, "{s}.mts", .{base});
        n = 3;
    } else if (std.mem.endsWith(u8, p, ".cjs")) {
        const base = p[0 .. p.len - ".cjs".len];
        cands[0] = try std.fmt.allocPrint(alloc, "{s}.d.cts", .{base});
        cands[1] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{base});
        cands[2] = try std.fmt.allocPrint(alloc, "{s}.cts", .{base});
        n = 3;
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
    return tryCandidates(f, alloc, cands[0..n]);
}

fn tryCandidates(f: Fs, alloc: Allocator, cands: []const []const u8) Error!?[]u8 {
    for (cands) |cand| {
        if (try probeCandidate(f, alloc, cand)) |p| return p;
    }
    return null;
}

/// Every extension the resolver ever appends, longest-first so `.d.ts` wins
/// over `.ts` when both match the tail.
const known_extensions = [_][]const u8{
    ".d.mts", ".d.cts", ".d.ts", ".tsx", ".jsx", ".mts", ".cts", ".mjs", ".cjs", ".ts", ".js", ".json",
};

/// Stat one candidate path, honoring `ResolveOpts.module_suffixes`. Returns
/// the matched path (owned by `alloc`), or null when nothing exists.
fn probeCandidate(f: Fs, alloc: Allocator, cand: []const u8) Error!?[]u8 {
    const module_suffixes = f.opts.module_suffixes;
    if (module_suffixes.len == 0) {
        if (try f.exists(cand)) return try alloc.dupe(u8, cand);
        return null;
    }
    var ext: []const u8 = "";
    for (known_extensions) |e| {
        if (std.mem.endsWith(u8, cand, e)) {
            ext = e;
            break;
        }
    }
    const base = cand[0 .. cand.len - ext.len];
    for (module_suffixes) |suf| {
        if (suf.len == 0) {
            if (try f.exists(cand)) return try alloc.dupe(u8, cand);
            continue;
        }
        const p = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ base, suf, ext });
        if (try f.exists(p)) return p;
        alloc.free(p);
    }
    return null;
}

/// `allowJs` fallback for `resolveStem`: when no TypeScript/declaration file
/// matched `stem`, probe the raw JavaScript file. An explicit JS-family
/// extension (`.js`/`.jsx`/`.mjs`/`.cjs`) is statted as-is; an extensionless
/// stem probes `stem.js`/`stem.jsx` then `stem/index.js`/`stem/index.jsx`
/// (the JS twins of `resolveStem`'s TypeScript probes). The returned path is
/// loaded opaquely as `any` (`js_module_source`); ztsc never parses the JS.
fn resolveJsStem(f: Fs, alloc: Allocator, stem: []const u8) Error!?[]u8 {
    if (endsWithAny(stem, &.{ ".js", ".jsx", ".mjs", ".cjs" })) {
        return probeCandidate(f, alloc, stem);
    }
    var buf: [4][]const u8 = undefined;
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.js", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.jsx", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}/index.js", .{stem});
    buf[3] = try std.fmt.allocPrint(alloc, "{s}/index.jsx", .{stem});
    return tryCandidates(f, alloc, buf[0..4]);
}

/// `resolveStem`, then — under `allow_js` — the `resolveJsStem` JavaScript
/// fallback. Declaration/TypeScript files always win over a `.js` twin.
fn resolveStemOrJs(f: Fs, alloc: Allocator, stem: []const u8, allow_js: bool) Error!?[]u8 {
    if (try resolveStemFs(f, alloc, stem)) |p| return p;
    if (allow_js) return resolveJsStem(f, alloc, stem);
    return null;
}

/// Length of the package-name prefix of a bare specifier: `"pkg/sub"` → 3,
/// `"@scope/pkg/sub"` → 11, a specifier that is only a package name → its whole
/// length. (`"@scope/pkg"` keeps both segments; a scoped name is two.)
fn packageNameLen(spec: []const u8) usize {
    const first = std.mem.indexOfScalar(u8, spec, '/') orelse return spec.len;
    if (spec[0] != '@') return first;
    return std.mem.indexOfScalarPos(u8, spec, first + 1, '/') orelse spec.len;
}

/// A bare `*.json` specifier (`pkg/lib/data.json`) through the `node_modules`
/// walk. tsc resolves a JSON module by ordinary node resolution, so a package
/// that ships data files exposes them at their real path — the outline app
/// imports `nodemailer/lib/well-known/services.json`, which is a plain file in a
/// plain package. Exact match only: tsc appends no extension to a `*.json`
/// specifier and probes no `index`, so this is one stat per walk level.
///
/// A package that publishes an `exports` map is skipped while
/// `resolvePackageJsonExports` is on. The map is a closed set of entry points, so
/// a data file it does not name is unresolvable for tsc as well, and ztsc's map
/// resolution has no `*.json` leg — leaving those specifiers unresolved is both
/// exactly today's behavior and the half of tsc's rule that cannot invent a
/// resolution tsc refuses. (A `*.json` a map DOES name therefore stays an
/// under-report: TS2307 where tsc resolves.)
fn resolveJsonPackage(
    f: Fs,
    alloc: Allocator,
    importer_dir: []const u8,
    spec: []const u8,
    use_exports: bool,
) Error!?[]u8 {
    // `<pkg>` alone is never a `*.json` module; a subpath is required.
    const pkg_len = packageNameLen(spec);
    if (pkg_len >= spec.len) return null;

    var d = importer_dir;
    while (true) {
        const level_ok = try f.hasNodeModules(alloc, d);
        if (level_ok) {
            const nm = if (d.len == 0)
                try std.fmt.allocPrint(alloc, "node_modules/{s}", .{spec[0..pkg_len]})
            else
                try std.fmt.allocPrint(alloc, "{s}/node_modules/{s}", .{ d, spec[0..pkg_len] });
            defer alloc.free(nm);
            const blocked = use_exports and try packageHasExports(f, alloc, nm);
            if (!blocked) {
                const cand = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ nm, spec[pkg_len + 1 ..] });
                if (try f.exists(cand)) return cand;
                alloc.free(cand);
            }
        }
        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) break;
        d = dirnamePart(d);
    }
    return null;
}

/// Whether the package at `nm` (`…/node_modules/<pkg>`, base-relative) publishes
/// a `package.json` `"exports"` map. Reads and parses through the same memos the
/// main walk uses, so this costs nothing the walk has not already paid.
fn packageHasExports(f: Fs, alloc: Allocator, nm: []const u8) Error!bool {
    const pj_path = try std.fmt.allocPrint(alloc, "{s}/package.json", .{nm});
    defer alloc.free(pj_path);
    const pj = (try f.packageJson(alloc, pj_path)) orelse return false;
    defer pj.deinit(alloc);
    return (try f.exports(alloc, pj)) != null;
}

// ---------------------------------------------------------------------------
// the importing package's own `package.json`: `imports` map + self-reference
// ---------------------------------------------------------------------------

/// The package a file belongs to: the directory of the nearest `package.json`
/// at or above `dir`, together with that body. tsc's `getPackageScopeForPath`.
/// `node_modules` is not skipped — a dependency's own files self-reference and
/// use `#imports` through the dependency's `package.json`, not the project's.
const PackageScope = struct { dir: []const u8, pj: PkgJson };

fn packageScope(f: Fs, alloc: Allocator, dir: []const u8) Error!?PackageScope {
    var d = dir;
    while (true) {
        const pj_path = if (d.len == 0)
            try alloc.dupe(u8, "package.json")
        else
            try std.fmt.allocPrint(alloc, "{s}/package.json", .{d});
        if (try f.packageJson(alloc, pj_path)) |pj| return .{ .dir = d, .pj = pj };
        // `pj_path` is not freed on a miss: the memoized leg keys the negative
        // answer on it, so the string has to stay valid for the scratch's life.
        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) return null;
        d = dirnamePart(d);
    }
}

/// Both declaration and JavaScript passes over the importing package's own
/// `exports` value — the two-phase order `resolvePackage` walks for a
/// `node_modules` package, collapsed to a single package (there is no walk
/// here: the scope is the importer's own package and nothing else can answer).
fn resolveOwnExports(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    map: tsconfig.Value,
    subpath: []const u8,
) Error!?[]u8 {
    if (try resolveExportsField(f, alloc, pkg_dir, map, subpath, .declarations)) |p| return p;
    return resolveExportsField(f, alloc, pkg_dir, map, subpath, .javascript);
}

/// The same two passes over an `imports` map. It goes to `resolveExportsSubpath`
/// and not to `resolveExportsField`: an `imports` map is ALWAYS a subpath map,
/// whose keys start with `#` rather than `.`, so the `exports` sugar forms (a
/// bare target string, a bare conditions object — both meaning ".") do not
/// apply and the "is this a subpath map" test would reject it.
fn resolveOwnImports(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    obj: tsconfig.Value.Object,
    spec: []const u8,
) Error!?[]u8 {
    if (try resolveExportsSubpath(f, alloc, pkg_dir, obj, spec, .declarations)) |p| return p;
    return resolveExportsSubpath(f, alloc, pkg_dir, obj, spec, .javascript);
}

/// A `#specifier` — Node's "private imports" — resolved through the
/// `"imports"` map of the importing file's own package. tsc's
/// `loadModuleFromImports`: the key space is the raw specifier (`#cjs`,
/// `#/*`), matched by the same exact-then-longest-wildcard rule as `exports`,
/// and only the importer's OWN package answers (no `node_modules` walk).
///
/// A target that is not package-relative (`"#dep": "some-package"`, which Node
/// re-resolves as a bare specifier) is rejected by `statExportTarget` and left
/// unresolved — a documented under-implementation, not a wrong answer.
fn resolveImportsSpecifier(f: Fs, alloc: Allocator, importer_dir: []const u8, spec: []const u8) Error!?[]u8 {
    const scope = (try packageScope(f, alloc, importer_dir)) orelse return null;
    defer scope.pj.deinit(alloc);
    const map = pkgjson.importsOf(alloc, scope.pj.text) orelse return null;
    if (map != .object) return null;
    return resolveOwnImports(f, alloc, scope.dir, map.object, spec);
}

/// A package importing ITSELF by the name it publishes — Node's
/// "self-reference", tsc's `loadModuleFromSelfNameReference`. `import
/// "package/cjs"` inside the package whose `package.json` says `"name":
/// "package"` resolves `./cjs` against that package's own `exports` map, with
/// no `node_modules` directory involved. Requires an `exports` map, as Node
/// does: without one a package is not self-referenceable.
fn resolveSelfName(f: Fs, alloc: Allocator, importer_dir: []const u8, spec: []const u8) Error!?[]u8 {
    const scope = (try packageScope(f, alloc, importer_dir)) orelse return null;
    defer scope.pj.deinit(alloc);
    const name = pkgjson.packageNameField(scope.pj.text) orelse return null;
    if (name.len == 0 or !std.mem.startsWith(u8, spec, name)) return null;
    // Whole-segment match only: `packagex` must not match `"name": "package"`.
    if (spec.len != name.len and spec[name.len] != '/') return null;
    const exports_val = (try f.exports(alloc, scope.pj)) orelse return null;
    const subpath: []const u8 = if (spec.len == name.len)
        "."
    else
        try std.fmt.allocPrint(alloc, "./{s}", .{spec[name.len + 1 ..]});
    return resolveOwnExports(f, alloc, scope.dir, exports_val, subpath);
}

/// The DefinitelyTyped package holding `pkg`'s typings, allocated in `alloc`,
/// or null when `pkg` names no package. tsc's `mangleScopedPackageName`: the
/// `@types` scope is one level deep, so a scoped name folds its scope into the
/// package name with a double underscore (`@babel/core` → `babel__core`).
fn typesPackageName(alloc: Allocator, pkg: []const u8) Error!?[]u8 {
    if (pkg.len == 0) return null;
    if (pkg[0] != '@') return try std.fmt.allocPrint(alloc, "@types/{s}", .{pkg});
    const slash = std.mem.indexOfScalar(u8, pkg, '/') orelse return null;
    return try std.fmt.allocPrint(alloc, "@types/{s}__{s}", .{ pkg[1..slash], pkg[slash + 1 ..] });
}

/// Resolve a bare (package) specifier by walking `node_modules` up from
/// the importer's directory.
pub fn resolvePackage(f: Fs, alloc: Allocator, importer_dir: []const u8, spec: []const u8, allow_js: bool, use_exports: bool) Error!?[]u8 {
    const pkg_len = packageNameLen(spec);
    const pkg = spec[0..pkg_len];
    const sub = if (pkg_len < spec.len) spec[pkg_len + 1 ..] else "";

    // tsc also resolves a bare package's typings from `@types/<pkg>` (the
    // DefinitelyTyped fallback) when the real package has no types — e.g.
    // `import … from "react"` → `node_modules/@types/react`. We probe
    // `@types/<pkg>` right after `<pkg>` at each directory level.
    //
    // A SCOPED name is mangled first (tsc's `mangleScopedPackageName`): the
    // `@types` scope can hold only one level, so `@babel/core`'s types live at
    // `@types/babel__core`, not at a nested `@types/@babel/core`.
    const types_pkg = try typesPackageName(alloc, pkg);
    defer if (types_pkg) |tp| alloc.free(tp);

    // Three-phase walk: declarations beat JavaScript at ANY depth. Phase 1
    // probes the real pkg (decls only) then `@types/<pkg>` across ALL levels;
    // only if nothing typed is found anywhere do the JavaScript phases run —
    // phase 2 for the target a package's own `exports` map names, phase 3 for
    // the legacy `main`/index under allowJs.
    //
    // Phase 1 covering every level before any JavaScript is the whole point:
    // react's `exports` names `./index.js` and `./jsx-runtime.js`, both real
    // files, while its declarations live in a *separate package*,
    // `@types/react`. Landing on react's own JavaScript would type the entire
    // React surface `any`.
    var d = importer_dir;
    while (true) {
        if (try resolvePackageAt(f, alloc, d, pkg, sub, .declarations, false, use_exports)) |p| {
            // An `exports`-blocked subpath means "the real package publishes no
            // *declarations* here", not "resolution is over": tsc still consults
            // `@types/<pkg>` for the same subpath. `react/jsx-runtime` is the
            // canonical case — react's `exports` names `./jsx-runtime.js` (JS,
            // no types) while @types/react ships `jsx-runtime.d.ts`, which is
            // where the automatic runtime's `JSX` namespace lives. Returning the
            // opaque any-module here typed the whole JSX namespace as `any`.
            if (paths.isBlockedSubpathPath(p)) {
                if (types_pkg) |tp| {
                    if (try resolvePackageAt(f, alloc, d, tp, sub, .declarations, false, use_exports)) |q| return q;
                }
            }
            return p;
        }
        if (types_pkg) |tp| {
            if (try resolvePackageAt(f, alloc, d, tp, sub, .declarations, false, use_exports)) |p| return p;
        }
        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) break;
        d = dirnamePart(d);
    }
    // Phase 2: nothing anywhere declares this specifier, so fall to the
    // JavaScript a package's `exports` map names for it. Not gated on
    // `allowJs`: the file sits in `node_modules`, so tsc never adds it to the
    // program either way — it types the module `any` and reports TS7016 at the
    // specifier, which is what an opaque any-module here reproduces.
    //
    // With `resolvePackageJsonExports` off there is no map to read a target
    // from, so the whole walk is skipped rather than walked for a guaranteed
    // null (`resolvePackageAt` would short-circuit on the same flag).
    if (use_exports) {
        d = importer_dir;
        while (true) {
            if (try resolvePackageAt(f, alloc, d, pkg, sub, .javascript, false, use_exports)) |p| return p;
            if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) break;
            d = dirnamePart(d);
        }
    }
    // Phase 3: the legacy `main`/index JavaScript entry, under allowJs.
    if (allow_js) {
        d = importer_dir;
        while (true) {
            if (try resolvePackageAt(f, alloc, d, pkg, sub, .declarations, true, use_exports)) |p| return p;
            if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) break;
            d = dirnamePart(d);
        }
    }
    return null;
}

/// Resolve a directory that carries its own `package.json` entry map:
/// `pkg_dir` is the enclosing package's directory (the escape boundary),
/// `dir_path` the directory named by the subpath. `"types"`/`"typings"` first
/// (declarations only), then `main` — as a declaration through the usual
/// extension substitution, and only under `allow_js` as the raw JS file.
///
/// Targets are resolved relative to `dir_path` and may climb out of it
/// (`"../lib/Either.d.ts"`), which is the whole point of the idiom; they may
/// not climb out of `pkg_dir`.
fn resolveDirPackageJson(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    dir_path: []const u8,
    allow_js: bool,
) Error!?[]u8 {
    const pj_path = try std.fmt.allocPrint(alloc, "{s}/package.json", .{dir_path});
    defer alloc.free(pj_path);
    const pj = (try f.packageJson(alloc, pj_path)) orelse return null;
    defer pj.deinit(alloc);
    const t = pj.text;

    if (packageTypesField(t)) |rel| {
        if (try dirFieldTarget(f, alloc, pkg_dir, dir_path, rel, false)) |p| return p;
    }
    if (packageMainField(t)) |rel| {
        if (try dirFieldTarget(f, alloc, pkg_dir, dir_path, rel, allow_js)) |p| return p;
    }
    return null;
}

/// One `resolveDirPackageJson` field target: join, keep it inside the package,
/// then probe declarations (and, under `allow_js`, the raw JS twin).
fn dirFieldTarget(
    f: Fs,
    alloc: Allocator,
    pkg_dir: []const u8,
    dir_path: []const u8,
    rel: []const u8,
    allow_js: bool,
) Error!?[]u8 {
    const stem = try joinNormalize(alloc, dir_path, rel);
    defer alloc.free(stem);
    // `../` may leave the subdirectory but never the package.
    if (!std.mem.startsWith(u8, stem, pkg_dir)) return null;
    if (stem.len <= pkg_dir.len or stem[pkg_dir.len] != '/') return null;
    if (try resolveStemFs(f, alloc, stem)) |p| return p;
    if (allow_js) return resolveJsStem(f, alloc, stem);
    return null;
}

/// Which of `resolvePackage`'s walks `resolvePackageAt` is serving.
const PackagePhase = enum {
    /// Declarations: the `exports` map's declaration targets, `"types"`, the
    /// declaration twin of `"main"`, `index.d.ts` — plus, under `allow_js`,
    /// the legacy JavaScript `main`/index (phase 3, which shares this arm
    /// because it is the same probe sequence with one more candidate).
    declarations,
    /// The runtime JavaScript a package's own `exports` map names, and nothing
    /// else. Runs only after the declaration walk has missed at every level.
    javascript,
};

/// Resolve `<pkg>/<sub>` under one directory level's `node_modules`, honoring
/// `package.json` `"types"`/`"typings"` (for a bare package) or a relative
/// stem (for a subpath). Null when nothing resolves at this level.
///
/// `use_exports` false (tsconfig `resolvePackageJsonExports: false`) skips the
/// `exports` map entirely, so this is the pre-`exports` resolver: the map cannot
/// resolve anything, cannot hide the legacy `"types"` key, and cannot block an
/// unmatched subpath.
fn resolvePackageAt(f: Fs, alloc: Allocator, d: []const u8, pkg: []const u8, sub: []const u8, phase: PackagePhase, allow_js: bool, use_exports: bool) Error!?[]u8 {
    // Nothing under `<d>/node_modules` can resolve when that directory does not
    // exist, so one memoized stat per walk level replaces every probe below.
    // Pure short-circuit: the package.json read and all stem candidates would
    // have failed anyway (see `FsCache.hasNodeModules`).
    if (!try f.hasNodeModules(alloc, d)) return null;

    const nm = if (d.len == 0)
        try std.fmt.allocPrint(alloc, "node_modules/{s}", .{pkg})
    else
        try std.fmt.allocPrint(alloc, "{s}/node_modules/{s}", .{ d, pkg });
    defer alloc.free(nm);

    // Read package.json once — shared by the `exports` map and the legacy
    // `"types"`/`"typings"` scan. (For a subpath the legacy path skips it, but
    // `exports` may still map the subpath, so we always read.) The walk revisits
    // the same file at every level for every specifier, so the cached leg reads
    // each path once for the run (misses included).
    const pj_path = try std.fmt.allocPrint(alloc, "{s}/package.json", .{nm});
    defer alloc.free(pj_path);
    const pj = try f.packageJson(alloc, pj_path);
    defer if (pj) |t| t.deinit(alloc);

    // (1) `exports` map — authoritative for tsc when present. A target the map
    //     DOES name but that ships no declarations resolves to the JavaScript
    //     itself (an opaque `any` module, plus TS7016 at the specifier); only
    //     when the map names nothing our condition set can reach does a root
    //     (".") miss still fall through to legacy probing. On a *subpath* miss,
    //     however, tsc's bundler/Node16
    //     resolution hard-fails: a package that publishes `exports` is a closed
    //     set of entry points, so `pkg/deep/path` NOT named by the map is
    //     unresolvable — Node/tsc do NOT fall back to walking the filesystem.
    //     Matching that is decisive for real deps whose declaration bundles
    //     reference an internal, un-exported subpath (a dependency in the
    //     dogfood project ships an `exports` map that omits an internal subpath
    //     its own typings import; tsc leaves that reference `any`, keeping the
    //     downstream generic-props helper permissive, whereas resolving it
    //     concretely made the whole component-props chain spuriously strict).
    //
    //     Crash-safety: an unmatched subpath must NOT return null here. A null
    //     leaves the specifier UNRESOLVED, which dangles a symbol in the
    //     parallel resolution phase (order-dependent → intermittent SIGABRT in
    //     the flow-narrowing `mergedSym` path). Instead route the blocked
    //     subpath to a stable opaque `any` module (the JSON/allowJs any-module
    //     machinery): the import binds concretely to `any` — matching tsc's
    //     observable `any` at an un-exported subpath — and no symbol dangles.
    //     The stand-in is not silent: liveness and reporting are separate, so
    //     the linker still emits tsc's TS2307 at the specifier for a path
    //     carrying `paths.blocked_subpath_suffix` (`Linker.blockedSubpathReport`
    //     in modules.zig). Returning null here would report the same thing and
    //     crash; returning the stand-in reports it and does not.
    //
    //     The parse itself is memoized per `package.json` path (`pkg_exports`):
    //     the body was already read once for the run, but the walk re-parsed it
    //     at every level of every specifier. The uncached leg parses into the
    //     per-file scratch exactly as before.
    //
    //     `resolvePackageJsonExports: false` takes the whole block out: the
    //     body is still read (the legacy leg below wants `"types"`/`"main"`
    //     from it), it is simply never asked for an `exports` key.
    const exports_pj: ?PkgJson = if (use_exports) pj else null;
    if (exports_pj) |epj| {
        if (try f.exports(alloc, epj)) |exports_val| {
            const subpath: []const u8 = if (sub.len == 0)
                "."
            else
                try std.fmt.allocPrint(alloc, "./{s}", .{sub});
            defer if (sub.len != 0) alloc.free(subpath);
            if (phase == .javascript) {
                // Phase 2 in isolation: the runtime file the map names. See
                // the `resolvePackage` walk for why this is a separate pass
                // and not a fallback right here — `@types/<pkg>` has to be
                // consulted first.
                return resolveExportsField(f, alloc, nm, exports_val, subpath, .javascript);
            }
            if (try resolveExportsField(f, alloc, nm, exports_val, subpath, .declarations)) |p| return p;
            // The map names a target for this specifier, but only ships
            // JavaScript behind it. That is a resolution for tsc (an untyped
            // `any` module plus TS7016 at the specifier), just not one this
            // phase may return — so report "nothing declared here" and let the
            // walk continue to `@types/<pkg>`, then to phase 2.
            //
            // Returning null rather than falling through to the legacy leg
            // below is the point: a package that publishes `exports` without a
            // `types` condition hides its own top-level `"types"` key, and tsc
            // honours that (`browser-fs-access` ships exactly this shape —
            // `exports` names only `./dist/index.mjs`, while the real
            // `index.d.ts` is reachable solely through the legacy field).
            if (try resolveExportsField(f, alloc, nm, exports_val, subpath, .javascript)) |p| {
                alloc.free(p);
                return null;
            }
            // Subpath unmatched by a present `exports` map → opaque `any`
            // module (see above; NOT null — that dangles a symbol). The
            // root (".") still falls through to legacy probing, so a package
            // whose `.` entry our condition set misses entirely is not
            // regressed.
            if (sub.len != 0) return try blockedSubpathPath(alloc, nm, sub);
        }
    }
    // Phase 2 has nothing to say about a package with no `exports` map.
    if (phase == .javascript) return null;

    // (2) Legacy resolution (exports absent or unmatched).
    return resolvePackageLegacy(f, alloc, nm, pj, sub, allow_js);
}

/// tsc's legacy, pre-`exports` package entry resolution for the package rooted
/// at `nm` (base-relative), with `pj` its already-read `package.json` (null
/// when it has none). `sub` is the import subpath ("" for the package root).
///
/// Split out of `resolvePackageAt` because it is not specific to a
/// `node_modules/<pkg>` directory: a tsconfig `paths` substitution that names a
/// package directory gets the very same treatment from tsc
/// (`resolvePathsCandidate`).
fn resolvePackageLegacy(
    f: Fs,
    alloc: Allocator,
    nm: []const u8,
    pj: ?PkgJson,
    sub: []const u8,
    allow_js: bool,
) Error!?[]u8 {
    // `typesVersions` is part of it: the pre-`exports` redirection layer,
    // which tsc consults BEFORE the plain candidate for a subpath and before
    // the `"types"` entry for the package root
    // (`tryLoadModuleUsingPaths`/`loadNodeModuleFromDirectoryWorker`). Three
    // of the outline app's dependencies ship declarations reachable ONLY
    // through it — `@modelcontextprotocol/sdk` (`{"*": {"*":
    // ["./dist/esm/*"]}}`), `@faker-js/faker`, `@simplewebauthn/server` —
    // and with `resolvePackageJsonExports` off there is no map left to find
    // them by, so skipping it would trade one family of false positives for
    // another.
    const version_paths: ?tsconfig.Value.Object = if (pj) |have| try f.typesVersions(alloc, have) else null;
    if (sub.len > 0) {
        if (version_paths) |vp| {
            for (try mapTypesVersions(alloc, vp, sub)) |target| {
                const stem = try joinNormalize(alloc, nm, target);
                defer alloc.free(stem);
                if (try resolveStemOrJs(f, alloc, stem, allow_js)) |p| return p;
            }
        }
        const stem = try joinNormalize(alloc, nm, sub);
        defer alloc.free(stem);
        if (try resolveStemOrJs(f, alloc, stem, allow_js)) |p| return p;
        // The subpath may name a *directory* whose own package.json is the
        // entry map — the pre-`exports` idiom for publishing deep imports
        // (`fp-ts/Either/package.json` = `{"typings": "../lib/Either.d.ts"}`;
        // io-ts and rxjs-compat ship the same shape). Its targets routinely
        // escape the directory with `../`, which is fine as long as they stay
        // inside the package.
        //
        // Ordering cut: tsc consults the directory package.json before the
        // directory's `index.*`, this probes it after (`resolveStemOrJs`
        // covers both the file candidates and `index`). They disagree only for
        // a directory that has BOTH an `index.d.ts` and a package.json
        // pointing somewhere else — a shape no real package ships.
        return resolveDirPackageJson(f, alloc, nm, stem, allow_js);
    }
    // package.json "types"/"typings" (declaration entry — TS only), else the
    // JS "main" entry under allowJs (typed `any`), else index.d.ts/index.ts (or
    // index.js under allowJs).
    var resolved_types = false;
    if (pj) |have| {
        if (packageTypesField(have.text)) |types_rel| {
            resolved_types = true;
            // The root import goes through `typesVersions` FIRST, under the name
            // of the entry the package declares — tsc maps the entry path, not
            // the specifier (`@faker-js/faker` declares `"types": "index.d.ts"`
            // and maps `"*" → "dist/types/*"`, so the real declarations are
            // `dist/types/index.d.ts` and the declared `index.d.ts` does not
            // exist at all).
            if (version_paths) |vp| {
                for (try mapTypesVersions(alloc, vp, types_rel)) |target| {
                    const stem = try joinNormalize(alloc, nm, target);
                    defer alloc.free(stem);
                    if (try resolveStemFs(f, alloc, stem)) |p| return p;
                }
            }
            const stem = try joinNormalize(alloc, nm, types_rel);
            defer alloc.free(stem);
            if (try resolveStemFs(f, alloc, stem)) |p| return p;
        }
    }
    // No `"types"` to name: tsc maps `index` instead (`@simplewebauthn/server`
    // maps the literal key `"."`, which no entry-file name can match, so this
    // leg is what a `{".": [...]}` table needs — see the `"index"` and `"."`
    // spellings both being tried).
    if (!resolved_types) {
        if (version_paths) |vp| {
            for ([2][]const u8{ "index", "." }) |name| {
                for (try mapTypesVersions(alloc, vp, name)) |target| {
                    const stem = try joinNormalize(alloc, nm, target);
                    defer alloc.free(stem);
                    if (try resolveStemFs(f, alloc, stem)) |p| return p;
                }
            }
        }
    }
    if (!resolved_types) {
        // No `types`/`typings`: tsc falls back to `main` *even for a TypeScript
        // resolution*, substituting declaration extensions for the runtime one
        // (`loadFileNameFromPackageJsonField`). A package that ships only
        // `"main": "lib/index.js"` but sits next to a `lib/index.d.ts` — a very
        // common shape for a package that emits declarations without declaring
        // them — resolves to that `.d.ts`. `resolveStemFs` already performs the
        // `.js`→`.ts`/`.tsx`/`.d.ts` substitution, so this is the same probe the
        // relative `./x.js` importer gets. Declarations only here: the raw JS
        // twin stays behind the `allow_js` leg below, which keeps the two-phase
        // walk's promise that a declaration anywhere beats JS everywhere.
        if (pj) |have| {
            if (packageMainField(have.text)) |main_rel| {
                const stem = try joinNormalize(alloc, nm, main_rel);
                defer alloc.free(stem);
                if (try resolveStemFs(f, alloc, stem)) |p| return p;
                // Under allowJs the same `main` resolves to the raw JS entry
                // (typed `any`) when no declaration twin exists.
                if (allow_js) {
                    if (try resolveJsStem(f, alloc, stem)) |p| return p;
                }
            }
        }
        const idx = try std.fmt.allocPrint(alloc, "{s}/index", .{nm});
        defer alloc.free(idx);
        if (try resolveStemOrJs(f, alloc, idx, allow_js)) |p| return p;
    }
    // The package name may be a FILE, not a directory: `node_modules/foo.d.ts`
    // answers `import … from "foo"` (`cachedModuleResolution1`). tsc's
    // `loadModuleFromSpecificNodeModulesDirectory` runs `loadModuleFromFile` on
    // the candidate BEFORE `loadNodeModuleFromDirectoryWorker`; probing it last
    // instead keeps the precedence of every specifier that already resolves —
    // this leg only ever converts a "module not found" into a resolution, since a
    // directory and a same-named declaration file beside it is a shape no real
    // package ships.
    return resolveStemFs(f, alloc, nm);
}

/// The file half of `resolveStem`: the extension-substitution candidates for
/// `stem`, WITHOUT the `<stem>/index.*` legs. tsc keeps the two apart
/// (`loadModuleFromFile`, then `loadNodeModuleFromDirectory`) and slots the
/// directory's `package.json` between them. `resolveStem` fuses them, which is
/// harmless for a plain relative import and wrong for a candidate that names a
/// package directory — see `resolvePathsCandidate`.
fn resolveFileStemFs(f: Fs, alloc: Allocator, stem: []const u8) Error!?[]u8 {
    // A stem that already carries an extension has no `index` legs to drop:
    // `resolveStemFs` returns file candidates only for those families.
    if (endsWithAny(stem, &.{ ".d.mts", ".mts", ".d.cts", ".cts", ".d.ts", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" })) {
        return resolveStemFs(f, alloc, stem);
    }
    var buf: [3][]const u8 = undefined;
    buf[0] = try std.fmt.allocPrint(alloc, "{s}.ts", .{stem});
    buf[1] = try std.fmt.allocPrint(alloc, "{s}.tsx", .{stem});
    buf[2] = try std.fmt.allocPrint(alloc, "{s}.d.ts", .{stem});
    return tryCandidates(f, alloc, buf[0..3]);
}

/// Load one *already substituted* tsconfig `paths` candidate — tsc's
/// `tryLoadModuleUsingPaths`, which hands each substitution to the same
/// "load as file, then as folder" loader the `node_modules` walk uses
/// (`nodeLoadModuleByRelativeName` with `considerPackageJson`), `package.json`
/// included.
///
/// The `package.json` step is the one that decides a candidate naming a
/// *package directory*, and probing stems alone silently drops it. With
/// `"*": ["./node_modules/*", "./node_modules/@types/*"]` — the idiom for a
/// project that resolves bare specifiers through a fixed `node_modules` — a
/// package that publishes `"types": "./types/index.d.ts"` and no top-level
/// `index.d.ts` (sequelize) misses the FIRST substitution and lands on the
/// DefinitelyTyped stub named by the second. The real package's own
/// declarations then lose to `@types/<pkg>`, which tsc consults only for a
/// package that ships no types at all: sequelize's `class Model` became
/// `@types/sequelize`'s unrelated `interface Model`, and every static on it
/// (`findAll`, `findByPk`, …) vanished from `typeof <model>`.
///
/// Candidate order is tsc's: file (extension substitution) → `package.json`
/// (`typesVersions` → `types`/`typings` → `main`, with declaration extensions
/// substituted for the runtime one) → `index.*`. Declarations only, exactly
/// like the `resolveStem` this replaces — a `paths` candidate still never
/// resolves to raw JavaScript. No `exports` map either: a substituted target is
/// a path, not a bare package specifier, so Node's export gate does not apply
/// (tsc reaches it through the relative loader for the same reason).
pub fn resolvePathsCandidate(io: Io, alloc: Allocator, dir: Io.Dir, cand: []const u8) Error!?[]u8 {
    return resolvePathsCandidateFs(.{ .io = io, .dir = dir }, alloc, cand);
}

/// `resolvePathsCandidate` with the resolution context threaded in — the same
/// probe sequence, under the caller's `ResolveOpts` (see
/// `ResolveCache.pathsCandidate`).
fn resolvePathsCandidateFs(f: Fs, alloc: Allocator, cand: []const u8) Error!?[]u8 {
    if (try resolveFileStemFs(f, alloc, cand)) |p| return p;
    const pj_path = try std.fmt.allocPrint(alloc, "{s}/package.json", .{cand});
    defer alloc.free(pj_path);
    const pj = try f.packageJson(alloc, pj_path);
    defer if (pj) |t| t.deinit(alloc);
    return resolvePackageLegacy(f, alloc, cand, pj, "", false);
}

// -------------------------------------------------------------------------
// specifier resolution (the entry points the caches wrap)
// -------------------------------------------------------------------------

/// Resolve module specifier `spec` from file `importer` (both relative to
/// `dir`). Returns the normalized path of the resolved file, or null.
fn resolveSpecifier(
    io: Io,
    alloc: Allocator,
    dir: Io.Dir,
    importer: []const u8,
    spec: []const u8,
    opts: ResolveOpts,
) Error!?[]u8 {
    return resolveSpecifierFs(.{ .io = io, .dir = dir, .opts = opts }, alloc, importer, spec);
}

/// `resolveSpecifier` with the resolution context (`Fs`) threaded into the
/// `node_modules` walk: the filesystem memos when `f.cache` is set, and the
/// per-run `ResolveOpts` either way.
fn resolveSpecifierFs(
    f: Fs,
    alloc: Allocator,
    importer: []const u8,
    spec: []const u8,
) Error!?[]u8 {
    if (spec.len == 0) return null;
    const importer_dir = dirnamePart(importer);
    const is_json = f.opts.resolve_json and std.mem.endsWith(u8, spec, ".json");
    if (spec[0] == '.') {
        const stem = try joinNormalize(alloc, importer_dir, spec);
        defer alloc.free(stem);
        if (is_json) return resolveJsonFileFs(f, alloc, stem);
        return resolveStemOrJs(f, alloc, stem, f.opts.allow_js);
    }
    if (spec[0] == '/') {
        const stem = try normalizePath(alloc, spec);
        defer alloc.free(stem);
        if (is_json) return resolveJsonFileFs(f, alloc, stem);
        return resolveStemOrJs(f, alloc, stem, f.opts.allow_js);
    }
    // A `#`-prefixed specifier is NEVER a package: it names an entry in the
    // importing package's own `"imports"` map and nothing else (tsc's
    // `loadModuleFromImports` runs before the `node_modules` walk and a `#`
    // name can never appear in one).
    if (spec[0] == '#') {
        if (!f.opts.resolve_pkg_json_imports) return null;
        return resolveImportsSpecifier(f, alloc, importer_dir, spec);
    }
    // A bare `*.json` specifier resolves against `baseUrl` first (tsc's baseUrl
    // rule; the `public/api/x.json` shape), then through the `node_modules` walk
    // like any other bare specifier.
    if (is_json) {
        if (f.opts.base_url) |bu| {
            const stem = try joinNormalize(alloc, bu, spec);
            defer alloc.free(stem);
            if (try resolveJsonFileFs(f, alloc, stem)) |p| return p;
        }
        return resolveJsonPackage(f, alloc, importer_dir, spec, f.opts.resolve_pkg_json_exports);
    }
    // A bare non-json specifier resolves against `baseUrl` BEFORE the
    // node_modules walk (tsc bundler/node order: paths → baseUrl → node_modules;
    // `paths` is applied by the driver ahead of this call). `src/utils/mask`
    // → `<baseUrl>/src/utils/mask.ts`.
    if (f.opts.base_url) |bu| {
        const stem = try joinNormalize(alloc, bu, spec);
        defer alloc.free(stem);
        if (try resolveStemOrJs(f, alloc, stem, f.opts.allow_js)) |p| return p;
    }
    if (try resolvePackage(f, alloc, importer_dir, spec, f.opts.allow_js, f.opts.resolve_pkg_json_exports)) |p| return p;
    // Self-reference last. tsc tries it BEFORE the `node_modules` walk, which
    // differs only when a dependency is installed under the importing package's
    // own name — and running it as a recovery path instead keeps it off the hot
    // path entirely: a specifier that resolves normally never reads the
    // importer's `package.json` at all, and only an otherwise-unresolvable
    // specifier pays the walk up to the package scope.
    if (f.opts.resolve_pkg_json_exports) {
        if (try resolveSelfName(f, alloc, importer_dir, spec)) |p| return p;
    }
    return null;
}

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

const testing = std.testing;

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

// package.json `exports` resolution across the real shapes in the corpus
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

    // exports-miss: package with exports "." only. A subpath NOT named by the
    // map (even one with an on-disk file) is blocked from legacy probing and
    // routed to a stable opaque `any` module (the `paths.blocked_subpath_suffix`
    // any-module — NOT null, which would dangle a symbol under parallel
    // resolution). The covered root still resolves concretely.
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
        // Blocked subpath -> opaque `any` module (crash-safe; not null).
        .{ .spec = "onlyroot/missing", .want = NM ++ "/onlyroot/missing" ++ paths.blocked_subpath_suffix },
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
    // The blocked subpath is a recognized opaque `any` module: the loader
    // substitutes its synthetic body and never touches disk.
    const blocked = (try resolveSpecifier(io, alloc, d, "src/a.ts", "onlyroot/missing", .{})).?;
    try testing.expect(paths.isBlockedSubpathPath(blocked));
    try testing.expect(paths.anyModuleSourceFor(blocked) != null);
}

// the resolution memo serves a repeated `(importer_dir, spec)` from
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

// S1-lite: the filesystem-fact memos under the specifier memo. Every leg must
// give the same answers as the uncached walk while issuing far fewer probes;
// `--no-resolve-cache` (enabled = false) is the oracle.
test "FsCache: node_modules existence, package.json and realpath memos" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // A deep source tree whose intermediate levels have NO node_modules — the
    // shape the walk wastes almost all of its syscalls on.
    try d.createDirPath(io, "src/a/b/c");
    try d.createDirPath(io, "node_modules/pkg");
    try d.writeFile(io, .{ .sub_path = "src/a/b/c/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/a/b/c/y.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/package.json", .data = "{ \"types\": \"main.d.ts\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/pkg/main.d.ts", .data = "" });

    var on = ResolveCache.init(alloc, true, .{});
    var off = ResolveCache.init(alloc, false, .{});

    resetFsProbeCount();
    const cached = try on.resolve(io, alloc, d, "src/a/b/c/x.ts", "pkg");
    const cached_probes = fsProbeCount();
    resetFsProbeCount();
    const uncached = try off.resolve(io, alloc, d, "src/a/b/c/x.ts", "pkg");
    const uncached_probes = fsProbeCount();

    try testing.expectEqualStrings("node_modules/pkg/main.d.ts", cached.?);
    try testing.expectEqualStrings(uncached.?, cached.?);
    // The four bare levels (src/a/b/c … src) short-circuit on one stat each
    // instead of a package.json read plus six stem probes, twice.
    try testing.expect(cached_probes < uncached_probes);

    // The memos are consulted, not rebuilt: a distinct specifier from the same
    // tree re-uses every `<d>/node_modules` verdict and package.json body.
    const counts = on.fs.entryCounts();
    try testing.expectEqual(@as(u32, 5), counts.nm_dirs); // src/a/b/c, src/a/b, src/a, src, ""
    resetFsProbeCount();
    const ghost_cached = try on.resolve(io, alloc, d, "src/a/b/c/y.ts", "ghost");
    const ghost_cached_probes = fsProbeCount();
    resetFsProbeCount();
    const ghost_uncached = try off.resolve(io, alloc, d, "src/a/b/c/y.ts", "ghost");
    try testing.expectEqual(@as(?[]const u8, null), ghost_cached);
    try testing.expectEqual(@as(?[]const u8, null), ghost_uncached);
    try testing.expect(ghost_cached_probes < fsProbeCount());
    // No new `<d>/node_modules` stats: the levels were already decided.
    try testing.expectEqual(counts.nm_dirs, on.fs.entryCounts().nm_dirs);

    // The realpath memo is keyed by directory, so both files of one package
    // canonicalize off a single entry.
    try testing.expectEqual(@as(u32, 1), on.fs.entryCounts().real_dirs);
    try testing.expect(on.fs.bytes > 0);
}

// The 4th memo: stem candidates (`node_modules/<pkg>/index.d.ts`, …) are
// statted once per distinct path for the whole run, however many specifiers
// walk past them; and a `package.json` `exports` map is PARSED once per file,
// not once per walk level. `--no-resolve-cache` stays the oracle for both.
test "FsCache: candidate-stat and exports-parse memos" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // Two source directories importing the same two packages: one legacy
    // (`types` field), one with an `exports` map plus a subpath.
    try d.createDirPath(io, "src/one");
    try d.createDirPath(io, "src/two");
    try d.writeFile(io, .{ .sub_path = "src/one/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/two/b.ts", .data = "" });
    try d.createDirPath(io, "node_modules/legacy");
    try d.writeFile(io, .{ .sub_path = "node_modules/legacy/package.json", .data = "{ \"types\": \"main.d.ts\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/legacy/main.d.ts", .data = "" });
    try d.createDirPath(io, "node_modules/exp/dist");
    try d.writeFile(io, .{ .sub_path = "node_modules/exp/package.json", .data =
        \\{ "exports": { ".": { "types":"./dist/index.d.ts" }, "./sub": { "types":"./dist/sub.d.ts" } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/exp/dist/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/exp/dist/sub.d.ts", .data = "" });

    var on = ResolveCache.init(alloc, true, .{});
    var off = ResolveCache.init(alloc, false, .{});

    const specs = [_][]const u8{ "legacy", "exp", "exp/sub", "ghost" };
    const importers = [_][]const u8{ "src/one/a.ts", "src/two/b.ts" };
    resetFsProbeCount();
    for (importers) |imp| {
        for (specs) |s| {
            const cached = try on.resolve(io, alloc, d, imp, s);
            const uncached = try off.resolve(io, alloc, d, imp, s);
            if (cached) |c| {
                try testing.expectEqualStrings(uncached.?, c);
            } else {
                try testing.expectEqual(@as(?[]const u8, null), uncached);
            }
        }
    }
    const counts = on.fs.entryCounts();

    // Every candidate path is statted at most once; the second directory's
    // identical walk is served entirely from memory.
    try testing.expect(on.fs.stat_lookups > counts.stat_files);
    try testing.expect(on.fs.stat_hits > 0);
    try testing.expectEqual(on.fs.stat_lookups - on.fs.stat_hits, @as(u64, counts.stat_files));

    // `exp/package.json` is parsed once even though the walk asks for its
    // `exports` map on every specifier from every importer directory.
    try testing.expect(on.fs.exports_lookups > on.fs.exports_hits);
    try testing.expectEqual(on.fs.exports_lookups - on.fs.exports_hits, @as(u64, counts.pkg_exports));
    try testing.expect(counts.pkg_exports <= counts.pkg_json);

    // A `package.json` with no `exports` key needs no parse at all, and the
    // shared extractor says so for both legs.
    try testing.expectEqual(@as(?tsconfig.Value, null), exportsOf(alloc, "{ \"types\": \"main.d.ts\" }"));
    try testing.expect(exportsOf(alloc, "{ \"exports\": \"./index.d.ts\" }") != null);
    // Escaped text takes the parse path (the fast path only skips backslash-free
    // bodies, where the literal key bytes are conclusive).
    try testing.expect(exportsOf(alloc, "{ \"a\": \"b\\nc\", \"exports\": \"./index.d.ts\" }") != null);
    try testing.expectEqual(@as(?tsconfig.Value, null), exportsOf(alloc, "{ not json"));
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

// (b) pnpm duplicate-file dedupe: the same physical `.d.ts` is reachable by
// several symlinked routes — the top-level `node_modules/<pkg>` link a program
// root names, the hoisted `.pnpm/node_modules/<pkg>` link a `types` reference
// walks onto, and the real store path an `import` canonicalizes to. Every route
// that puts a file in the module graph must agree on one path, or the file is
// loaded, parsed, bound and *type-checked* once per route, each copy with its
// own symbol universe. `resolve` canonicalized; `resolveRef` and program roots
// (via `canonicalPath`) now do too.
test "ResolveCache: reference directives and roots canonicalize to one path" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // One real `@types/pkg` in the store, with a `path` reference to a sibling.
    try d.createDirPath(io, "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg");
    try d.writeFile(io, .{
        .sub_path = "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/index.d.ts",
        .data = "/// <reference path=\"./extra.d.ts\" />\n",
    });
    try d.writeFile(io, .{
        .sub_path = "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/extra.d.ts",
        .data = "export const x: number;\n",
    });
    // Three routes to it: the project's `@types` root, pnpm's hoisted store dir
    // (what a `/// <reference types="pkg" />` from another package walks onto),
    // and the real path itself.
    try d.createDirPath(io, "node_modules/@types");
    try d.createDirPath(io, "node_modules/.pnpm/node_modules/@types");
    try d.symLink(io, "../.pnpm/@types+pkg@1/node_modules/@types/pkg", "node_modules/@types/pkg", .{ .is_directory = true });
    try d.symLink(io, "../../@types+pkg@1/node_modules/@types/pkg", "node_modules/.pnpm/node_modules/@types/pkg", .{ .is_directory = true });
    try d.createDirPath(io, "node_modules/.pnpm/other@1/node_modules/other");
    try d.writeFile(io, .{ .sub_path = "node_modules/.pnpm/other@1/node_modules/other/index.d.ts", .data = "" });

    const canonical = "node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/index.d.ts";

    var rc = ResolveCache.init(alloc, true, .{});
    // A program root named through the project's `@types` symlink.
    try testing.expectEqualStrings(canonical, try rc.canonicalPath(io, alloc, d, "node_modules/@types/pkg/index.d.ts"));
    // A `types` reference from a sibling package, which finds the hoisted link.
    const types_ref = try rc.resolveRef(io, alloc, d, "node_modules/.pnpm/other@1/node_modules/other/index.d.ts", .{ .kind = .types, .spec = "pkg" });
    try testing.expectEqualStrings(canonical, types_ref.?);
    // A `path` reference out of the canonical file stays canonical.
    const path_ref = try rc.resolveRef(io, alloc, d, canonical, .{ .kind = .path, .spec = "./extra.d.ts" });
    try testing.expectEqualStrings("node_modules/.pnpm/@types+pkg@1/node_modules/@types/pkg/extra.d.ts", path_ref.?);
    // Project files are never canonicalized (no realpath, path as written).
    try d.writeFile(io, .{ .sub_path = "a.ts", .data = "" });
    try testing.expectEqualStrings("a.ts", try rc.canonicalPath(io, alloc, d, "a.ts"));

    // `--no-resolve-cache` is the oracle: same answers, memos bypassed.
    var off = ResolveCache.init(alloc, false, .{});
    try testing.expectEqualStrings(canonical, try off.canonicalPath(io, alloc, d, "node_modules/@types/pkg/index.d.ts"));
    const off_ref = try off.resolveRef(io, alloc, d, "node_modules/.pnpm/other@1/node_modules/other/index.d.ts", .{ .kind = .types, .spec = "pkg" });
    try testing.expectEqualStrings(canonical, off_ref.?);
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

    // A package's data file resolves through the node_modules walk, exactly like
    // any other bare specifier (`nodemailer/lib/well-known/services.json`).
    try d.createDirPath(io, "node_modules/plainpkg/lib/well-known");
    try d.writeFile(io, .{ .sub_path = "node_modules/plainpkg/package.json", .data = "{ \"name\": \"plainpkg\", \"main\": \"lib/index.js\" }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/plainpkg/lib/well-known/services.json", .data = "{}" });
    try testing.expectEqualStrings(
        "node_modules/plainpkg/lib/well-known/services.json",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "plainpkg/lib/well-known/services.json", on)).?,
    );
    // Exact match only — no extension probing, no `index.json`, and the option
    // still gates it.
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "plainpkg/lib/well-known/nope.json", on));
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "plainpkg/lib/well-known/services.json", .{}));
    // A package that publishes an `exports` map keeps its closed entry-point set:
    // ztsc has no `*.json` leg for the map, so the specifier stays unresolved
    // rather than resolving behind tsc's back (documented under-report). With
    // `resolvePackageJsonExports` off there is no map, and the file resolves.
    try d.createDirPath(io, "node_modules/mappedpkg/data");
    try d.writeFile(io, .{ .sub_path = "node_modules/mappedpkg/package.json", .data = "{ \"exports\": { \".\": \"./index.js\" } }" });
    try d.writeFile(io, .{ .sub_path = "node_modules/mappedpkg/data/list.json", .data = "{}" });
    try testing.expectEqual(@as(?[]u8, null), try resolveSpecifier(io, alloc, d, "src/a.ts", "mappedpkg/data/list.json", on));
    try testing.expectEqualStrings(
        "node_modules/mappedpkg/data/list.json",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "mappedpkg/data/list.json", .{ .resolve_json = true, .base_url = ".", .resolve_pkg_json_exports = false })).?,
    );
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
    try testing.expect(paths.isJsModulePath(qs));
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

// `typesVersions` — the pre-`exports` redirection layer, in the three real
// shapes the outline app depends on. It applies whenever the legacy leg runs, so
// the cases here use packages with no `exports` map; the exports-off case is the
// next test.
test "resolvePackage: typesVersions redirects subpaths and the package entry" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });

    // (1) `{"*": {"*": ["./dist/esm/*"]}}` — every subpath redirected, and the
    // `.js` specifier resolves to the `.d.ts` at the mapped location
    // (@modelcontextprotocol/sdk).
    try d.createDirPath(io, "node_modules/sdk/dist/esm/server");
    try d.writeFile(io, .{ .sub_path = "node_modules/sdk/package.json", .data =
        \\{ "name": "sdk", "typesVersions": { "*": { "*": ["./dist/esm/*"] } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/sdk/dist/esm/server/mcp.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/sdk/dist/esm/server/mcp.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "sdk/server/mcp.js", .{})).?,
    );

    // (2) `{">=4.0": {"*": ["dist/types/*"]}}` with a `"types"` that does not
    // exist: the ENTRY NAME is what gets mapped (@faker-js/faker).
    try d.createDirPath(io, "node_modules/faker/dist/types");
    try d.writeFile(io, .{ .sub_path = "node_modules/faker/package.json", .data =
        \\{ "name": "faker", "types": "index.d.ts",
        \\  "typesVersions": { ">=4.0": { "*": ["dist/types/*"] } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/faker/dist/types/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/faker/dist/types/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "faker", .{})).?,
    );

    // (3) Literal keys, no `"types"` field (@simplewebauthn/server): `"."` names
    // the package entry and `"helpers"` an exact subpath.
    try d.createDirPath(io, "node_modules/webauthn/esm/helpers");
    try d.createDirPath(io, "node_modules/webauthn/script");
    try d.writeFile(io, .{ .sub_path = "node_modules/webauthn/package.json", .data =
        \\{ "name": "webauthn", "main": "./script/index.js",
        \\  "typesVersions": { "*": { ".": ["esm/index.d.ts"], "helpers": ["esm/helpers/index.d.ts"] } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/webauthn/esm/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/webauthn/esm/helpers/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/webauthn/esm/helpers/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "webauthn/helpers", .{})).?,
    );
    try testing.expectEqualStrings(
        "node_modules/webauthn/esm/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "webauthn", .{})).?,
    );

    // A range this compiler does not satisfy is not a mapping: the package
    // resolves as if it had no `typesVersions` at all.
    try d.createDirPath(io, "node_modules/old/legacy");
    try d.writeFile(io, .{ .sub_path = "node_modules/old/package.json", .data =
        \\{ "name": "old", "types": "index.d.ts",
        \\  "typesVersions": { "<4.0": { "*": ["legacy/*"] } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/old/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/old/legacy/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/old/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "old", .{})).?,
    );
}

// tsconfig `resolvePackageJsonExports: false` — the `exports` map is ignored
// ENTIRELY, so the three things a present map does (resolve a target, hide the
// legacy `"types"` key, block an unnamed subpath) all stop happening and every
// specifier takes the pre-`exports` path. With the option at its default (true)
// the same tree resolves exactly as before.
test "resolveSpecifier: resolvePackageJsonExports gates the exports map" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src");
    // `hidden`: an `exports` map with no `types` condition, next to a perfectly
    // good top-level `"types"` the map hides (the `@hocuspocus/server` /
    // `redlock` shape that makes a project set the option in the first place).
    try d.createDirPath(io, "node_modules/hidden/dist");
    try d.createDirPath(io, "node_modules/hidden/lib/internal");
    try d.writeFile(io, .{ .sub_path = "node_modules/hidden/package.json", .data =
        \\{ "name": "hidden", "main": "dist/index.js", "types": "index.d.ts",
        \\  "exports": { ".": { "import": "./dist/index.js" } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/hidden/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/hidden/dist/index.js", .data = "" });
    // A subpath the map does not name, with a real declaration file behind it.
    try d.writeFile(io, .{ .sub_path = "node_modules/hidden/lib/internal/util.d.ts", .data = "" });
    // `mapped`: a well-formed map WITH a `types` condition pointing somewhere
    // other than the legacy `index.d.ts` — the two legs must be told apart.
    try d.createDirPath(io, "node_modules/mapped/types");
    try d.writeFile(io, .{ .sub_path = "node_modules/mapped/package.json", .data =
        \\{ "name": "mapped", "exports": { ".": { "types": "./types/api.d.ts" } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/mapped/types/api.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/mapped/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });

    const on: ResolveOpts = .{}; // default: exports honored
    const off: ResolveOpts = .{ .resolve_pkg_json_exports = false };

    // Default (map honored): the map names only JavaScript, so the package is
    // the opaque JS any-module and the legacy `"types"` stays hidden.
    const js = (try resolveSpecifier(io, alloc, d, "src/a.ts", "hidden", on)).?;
    try testing.expectEqualStrings("node_modules/hidden/dist/index.js", js);
    try testing.expect(paths.isJsModulePath(js));
    // Option off: the legacy `"types"` wins and the module is typed.
    try testing.expectEqualStrings(
        "node_modules/hidden/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "hidden", off)).?,
    );
    // Default: a subpath the map does not name is blocked (synthetic path,
    // reported as tsc's TS2307) even though the file exists.
    const blocked = (try resolveSpecifier(io, alloc, d, "src/a.ts", "hidden/lib/internal/util", on)).?;
    try testing.expect(paths.isBlockedSubpathPath(blocked));
    // Option off: nothing blocks it — the plain relative stem resolves.
    try testing.expectEqualStrings(
        "node_modules/hidden/lib/internal/util.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "hidden/lib/internal/util", off)).?,
    );
    // A `types` condition is a resolution the option takes away: with it off,
    // the same package falls back to `index.d.ts`.
    try testing.expectEqualStrings(
        "node_modules/mapped/types/api.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "mapped", on)).?,
    );
    try testing.expectEqualStrings(
        "node_modules/mapped/index.d.ts",
        (try resolveSpecifier(io, alloc, d, "src/a.ts", "mapped", off)).?,
    );
}

// The importing package's OWN `package.json`: the `"imports"` map a
// `#specifier` names, and the self-reference by the package's own `"name"`.
// Shapes taken from the TypeScript suite's `nodeModulesPackageImports` /
// `nodeModulesPackageExports` / `nodePackageSelfName` cases, whose targets name
// the EMITTED `.js`/`.mjs`/`.cjs` while only the TypeScript source exists.
test "resolveSpecifier: package.json imports map and self-reference" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/deep");
    try d.writeFile(io, .{ .sub_path = "package.json", .data =
        \\{ "name": "@scope/pkg", "type": "module",
        \\  "exports": { ".": "./index.js", "./cjs": "./index.cjs", "./sub/*": "./src/*.js" },
        \\  "imports": { "#cjs": "./index.cjs", "#mjs": "./index.mjs", "#/*": "./src/*" } }
    });
    try d.writeFile(io, .{ .sub_path = "index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "index.cts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "index.mts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/foo.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/deep/bar.ts", .data = "" });

    const cases = [_]struct { spec: []const u8, want: ?[]const u8 }{
        // `imports`: exact keys, and the `.cjs`/`.mjs` targets reaching their
        // TypeScript source when no declaration file was emitted.
        .{ .spec = "#cjs", .want = "index.cts" },
        .{ .spec = "#mjs", .want = "index.mts" },
        // A wildcard key, including a capture with its own directories.
        .{ .spec = "#/foo.ts", .want = "src/foo.ts" },
        .{ .spec = "#/deep/bar.ts", .want = "src/deep/bar.ts" },
        // An unnamed private import stays unresolved (no node_modules fallback).
        .{ .spec = "#nope", .want = null },
        // Self-reference: the package root, an exact subpath, and a wildcard.
        .{ .spec = "@scope/pkg", .want = "index.ts" },
        .{ .spec = "@scope/pkg/cjs", .want = "index.cts" },
        .{ .spec = "@scope/pkg/sub/foo", .want = "src/foo.ts" },
        // A subpath the map does not name, and a name that only PREFIXES the
        // package name, are not self-references.
        .{ .spec = "@scope/pkg/nope", .want = null },
        .{ .spec = "@scope/pkgx", .want = null },
    };
    for (cases) |c| {
        const got = try resolveSpecifier(io, alloc, d, "src/deep/bar.ts", c.spec, .{});
        if (c.want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expectEqual(@as(?[]u8, null), got);
        }
    }
    // Both features are gated by their own option.
    try testing.expectEqual(
        @as(?[]u8, null),
        try resolveSpecifier(io, alloc, d, "src/deep/bar.ts", "#cjs", .{ .resolve_pkg_json_imports = false }),
    );
    try testing.expectEqual(
        @as(?[]u8, null),
        try resolveSpecifier(io, alloc, d, "src/deep/bar.ts", "@scope/pkg/cjs", .{ .resolve_pkg_json_exports = false }),
    );
}

// A tsconfig `paths` substitution is loaded by tsc's FULL "load as file or
// folder" loader — `tryLoadModuleUsingPaths` hands each candidate to
// `nodeLoadModuleByRelativeName` with `considerPackageJson`, the same loader the
// `node_modules` walk uses. Probing stems alone (the old behaviour) drops the
// `package.json` step, and that step is the only one that can resolve a
// candidate naming a package directory whose declarations sit behind a `"types"`
// pin.
//
// The shape below is the sequelize one, minimized: a real package with a
// `"types"` pin and NO top-level `index.d.ts`, a `@types/<pkg>` sibling that
// does have one, and the `"*": [node_modules/*, node_modules/@types/*]` table
// that puts them in that order. The miss on the first substitution fell through
// to the second, so the real package's declarations lost to the DefinitelyTyped
// stub — an inversion of tsc's rule, which reaches `@types/<pkg>` only for a
// package that ships no types at all.
test "resolvePathsCandidate: a package-directory candidate resolves through package.json" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    // The real package: `"types"` points into a subdirectory, and the package
    // root holds no `index.*` at all.
    try d.createDirPath(io, "node_modules/orm/types");
    try d.writeFile(io, .{ .sub_path = "node_modules/orm/package.json", .data =
        \\{ "name": "orm", "main": "./lib/index.js", "types": "./types/index.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/orm/types/index.d.ts", .data = "" });
    // The DefinitelyTyped stub next to it, reachable by a literal `index.d.ts`.
    try d.createDirPath(io, "node_modules/@types/orm");
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/orm/package.json", .data =
        \\{ "name": "@types/orm", "types": "index.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/orm/index.d.ts", .data = "" });

    // The first substitution resolves — through `package.json`, not a stem — so
    // the `@types` substitution is never reached.
    try testing.expectEqualStrings(
        "node_modules/orm/types/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/orm")).?,
    );

    // The rule is about the real package having declarations, not about `@types`
    // coming second: a package with none still misses, and the caller's next
    // substitution (the `@types` twin) is what answers.
    try d.createDirPath(io, "node_modules/plainjs/lib");
    try d.writeFile(io, .{ .sub_path = "node_modules/plainjs/package.json", .data =
        \\{ "name": "plainjs", "main": "./lib/index.js" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/plainjs/lib/index.js", .data = "" });
    try d.createDirPath(io, "node_modules/@types/plainjs");
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/plainjs/index.d.ts", .data = "" });
    try testing.expectEqual(
        @as(?[]u8, null),
        try resolvePathsCandidate(io, alloc, d, "node_modules/plainjs"),
    );
    try testing.expectEqualStrings(
        "node_modules/@types/plainjs/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/@types/plainjs")).?,
    );

    // `main` with no `types`: the declaration twin of the runtime entry wins,
    // exactly as it does inside the `node_modules` walk.
    try d.createDirPath(io, "node_modules/mainonly/lib");
    try d.writeFile(io, .{ .sub_path = "node_modules/mainonly/package.json", .data =
        \\{ "name": "mainonly", "main": "lib/index.js" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/mainonly/lib/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/mainonly/lib/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/mainonly")).?,
    );

    // `typesVersions` still redirects the entry a `paths` candidate names.
    try d.createDirPath(io, "node_modules/versioned/dist/types");
    try d.writeFile(io, .{ .sub_path = "node_modules/versioned/package.json", .data =
        \\{ "name": "versioned", "types": "index.d.ts",
        \\  "typesVersions": { ">=4.0": { "*": ["dist/types/*"] } } }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/versioned/dist/types/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/versioned/dist/types/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/versioned")).?,
    );

    // Order is tsc's: the directory's `package.json` beats its `index.*`, and a
    // FILE candidate beats the directory entirely.
    try d.createDirPath(io, "node_modules/both/decls");
    try d.writeFile(io, .{ .sub_path = "node_modules/both/package.json", .data =
        \\{ "name": "both", "types": "./decls/main.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/both/decls/main.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/both/index.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/both/decls/main.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/both")).?,
    );
    try d.writeFile(io, .{ .sub_path = "node_modules/both.d.ts", .data = "" });
    try testing.expectEqualStrings(
        "node_modules/both.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/both")).?,
    );

    // The candidate shapes that already worked are untouched: a plain source
    // file (the `@server/*` mapping), a directory carrying only an `index.*` and
    // no package.json, and a target naming a declaration file outright
    // (outline's `vite` mapping).
    try d.createDirPath(io, "server/models/base");
    try d.writeFile(io, .{ .sub_path = "server/models/base/Model.ts", .data = "" });
    try d.createDirPath(io, "shared/utils");
    try d.writeFile(io, .{ .sub_path = "shared/utils/index.ts", .data = "" });
    try testing.expectEqualStrings(
        "server/models/base/Model.ts",
        (try resolvePathsCandidate(io, alloc, d, "server/models/base/Model")).?,
    );
    try testing.expectEqualStrings(
        "shared/utils/index.ts",
        (try resolvePathsCandidate(io, alloc, d, "shared/utils")).?,
    );
    try testing.expectEqualStrings(
        "node_modules/orm/types/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, "node_modules/orm/types/index.d.ts")).?,
    );
    // Nothing there at all stays null, so the caller tries the next substitution.
    try testing.expectEqual(
        @as(?[]u8, null),
        try resolvePathsCandidate(io, alloc, d, "node_modules/nosuch"),
    );
}

// The end-to-end shape the fix is for, driven through the same two-step the CLI
// driver performs (`Paths.mapSpecifier` → `resolvePathsCandidate` per candidate,
// in order): the `"*"` table, a real package with a `"types"` pin, its `@types`
// sibling, and an importer that lives INSIDE `node_modules` — tsc applies
// `paths` to those importers too, so this is the sequelize-typescript case.
test "paths: the real package's types pin beats the @types sibling, node_modules importer included" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;

    try d.createDirPath(io, "src");
    try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    try d.createDirPath(io, "node_modules/orm/types");
    try d.writeFile(io, .{ .sub_path = "node_modules/orm/package.json", .data =
        \\{ "name": "orm", "main": "./lib/index.js", "types": "./types/index.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/orm/types/index.d.ts", .data = "" });
    try d.createDirPath(io, "node_modules/@types/orm");
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/orm/index.d.ts", .data = "" });
    // The intermediate package whose declarations import the real one.
    try d.createDirPath(io, "node_modules/orm-decorators/dist");
    try d.writeFile(io, .{ .sub_path = "node_modules/orm-decorators/package.json", .data =
        \\{ "name": "orm-decorators", "types": "dist/index.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "node_modules/orm-decorators/dist/index.d.ts", .data = "" });

    const table: tsconfig.Paths = .{
        .keys = &.{"*"},
        .vals = &.{&.{ "./node_modules/*", "./node_modules/@types/*" }},
        .base = ".",
    };
    // `mapSpecifier` yields the substitutions in table order; the driver takes
    // the first that loads. Both importers — the project file and the one inside
    // `node_modules` — go through the same table and must land on the real
    // package.
    const cands = try table.mapSpecifier(alloc, "orm");
    try testing.expectEqual(@as(usize, 2), cands.len);
    try testing.expectEqualStrings("node_modules/orm", cands[0]);
    try testing.expectEqualStrings("node_modules/@types/orm", cands[1]);
    try testing.expectEqualStrings(
        "node_modules/orm/types/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, cands[0])).?,
    );

    // And the `orm-decorators` entry the project imports resolves through its
    // own `"types"` pin the same way.
    const dec = try table.mapSpecifier(alloc, "orm-decorators");
    try testing.expectEqualStrings(
        "node_modules/orm-decorators/dist/index.d.ts",
        (try resolvePathsCandidate(io, alloc, d, dec[0])).?,
    );
}

test "typesPackageName: tsc's mangleScopedPackageName" {
    const alloc = testing.allocator;
    const name = struct {
        fn of(a: std.mem.Allocator, pkg: []const u8) !?[]u8 {
            return typesPackageName(a, pkg);
        }
    }.of;
    // Unscoped: the package name straight into the `@types` scope.
    const react = (try name(alloc, "react")).?;
    defer alloc.free(react);
    try testing.expectEqualStrings("@types/react", react);
    // Scoped: the scope folds into the name, because `@types` is one level deep.
    const babel = (try name(alloc, "@babel/core")).?;
    defer alloc.free(babel);
    try testing.expectEqualStrings("@types/babel__core", babel);
    // A bare `@scope` names no package, and neither does the empty specifier.
    try testing.expectEqual(@as(?[]u8, null), try name(alloc, "@scope"));
    try testing.expectEqual(@as(?[]u8, null), try name(alloc, ""));
}
