//! tsconfig.json subset.
//!
//! Supported surface:
//!
//! - **JSONC**: `//` and `/* */` comments plus trailing commas, parsed by a
//!   small self-contained recursive-descent parser (arena-allocated values).
//! - **Top level**: `files`, `include`, `exclude`. The include/exclude glob
//!   subset is `**` (zero or more directories), `*` (any run of non-`/`
//!   characters), `?` (exactly one non-`/` character); wildcards never match
//!   a leading `.` in a segment. An include pattern whose last segment has no
//!   wildcard and no extension is treated as a directory (`p` -> `p/**/*`),
//!   like tsc. Only `.ts`/`.d.ts` files are collected. Default include (when
//!   neither `files` nor `include` is present) is `**/*`. The default `exclude`
//!   — used only when no `exclude` key survives the `extends` merge — is
//!   `[outDir, declarationDir]`; see `defaultExcludes`. What keeps the walk out
//!   of `node_modules`,
//!   `bower_components` and `jspm_packages` is not `exclude` at all but tsc's
//!   `implicitExcludePathRegexPattern`, which prunes those folder names
//!   wherever a wildcard could have reached them — so an explicit `exclude`
//!   neither enables nor disables it. A pattern's wildcard-free literal prefix
//!   is the one way in (`include: ["node_modules/typed"]`), and it opts in only
//!   what that prefix names; see `implicitlyPruned`. An entry may be rooted
//!   (`/home/me/proj/out`); the walk lifts candidate paths into that space to
//!   match it, so rooted and relative spellings of the same directory do the
//!   same thing, and one that names somewhere else matches nothing — see
//!   `Matcher`. Every pattern comparison — `exclude`, `include`, and the
//!   package-folder prune — ignores case exactly when the filesystem does, the
//!   condition tsc puts the `i` flag on its regexes under; see
//!   `caseSensitiveFs`. The `.ts`/`.tsx` extension gate does not: it is a plain
//!   suffix test in tsc too, so `a.TS` is never an input even on macOS.
//! - **compilerOptions**:
//!   - `strict` must be `true` or absent — ztsc only implements strict
//!     semantics, so `strict: false` is a polite hard error (exit 2).
//!   - `noEmit` is ignored (ztsc never emits).
//!   - `outDir` / `declarationDir` are accepted and never used as output
//!     locations; they matter only as the default `exclude` above.
//!   - `target` / `module` / `moduleResolution` are accepted and ignored
//!     (surfaced as notes under `--verbose`): ztsc always checks its fixed
//!     esnext/bundler-resolution subset.
//!   - `resolvePackageJsonExports` / `resolvePackageJsonImports` are honored,
//!     defaulting to `true` (the bundler value — they do NOT follow the ignored
//!     `moduleResolution`). `resolvePackageJsonExports: false` makes module
//!     resolution ignore every dependency's `"exports"` map, falling back to the
//!     legacy `"types"`/`"typings"`/`"main"`/`index` path; the `"imports"` map is
//!     not implemented at all, so its flag only records the option.
//!   - `baseUrl` + `paths`: minimal support — exact keys and single-`*`
//!     patterns mapped to relative directories; feeds module resolution
//!     (tsc rule: exact match wins, else the pattern with the longest
//!     matched prefix).
//!   - `lib` selects the built-in lib blobs (es-core + dom); the list
//!     replaces the default set (tsc semantics). Recognized families: `es*`
//!     (the ES-core blob) and `dom*` (the DOM blob); others warn + ignore.
//!     Absent `lib` = the default set (ES-core + DOM, matching tsgo).
//!   - `types` / `typeRoots` drive auto-`@types` inclusion (tsc's default
//!     `typeRoots`): with neither set, every `node_modules/@types/<pkg>`
//!     visible walking up from the project becomes an ambient program root
//!     (its `package.json` `types`/`typings`, else `index.d.ts`), so ambient
//!     `declare module` augmentations merge the way tsc sees them. `typeRoots`
//!     overrides the root directories; `types: [...]` restricts to the named
//!     packages (`@scope/name` → `scope__name`); `types: []` disables it. The
//!     set is loaded in a stable sorted order (determinism); see
//!     `collectAutoTypes`. Loaded `.d.ts` are checked/suppressed per
//!     `skipLibCheck` like any other `.d.ts`.
//!   - Anything else warns and is ignored — unknown options never fail.
//! - **`extends`**: a string or array of strings. Each base is loaded first,
//!   then the extending config overrides it. Relative (`./`, `../`) values
//!   resolve against the config's directory (`.json` implied); bare specifiers
//!   resolve node-style (walk up `node_modules`, consulting a package dir's
//!   `package.json` `"tsconfig"` field or its `tsconfig.json`). `compilerOptions`
//!   merge per-key (child wins wholesale, including the entire `paths` object);
//!   `files`/`include`/`exclude` are inherited whole unless the child sets them.
//!   All relative paths resolve against the config that declared them (inherited
//!   `include`/`exclude`/`baseUrl`/`paths` re-anchor to the base's directory).
//!   Circular `extends` chains are broken with a warning (tsc TS18000); a
//!   missing/unreadable base warns and degrades to no-extends.
//! - Unknown top-level keys (incl. `references`) warn + ignore.
//!
//! Discovery: with no file arguments, the CLI looks for `tsconfig.json` in
//! the current directory and then each parent (`findUpward`), or uses the
//! `--project/-p` path. All paths produced here are relative to the base
//! directory the config was loaded through (the cwd in production).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const modules = @import("link/modules.zig");
const paths = @import("link/paths.zig");
const resolve = @import("link/resolve.zig");
const jsonc = @import("jsonc.zig");
const glob = @import("glob.zig");

const Error = error{OutOfMemory};

/// The state every leg of a config load carries but none of it owns: the
/// config arena and the two diagnostic sinks that end up on `Config`. Passed by
/// value — it is three words, and the lists behind the pointers are what the
/// callees actually append to.
///
/// A `warn` is a problem with the config the user should fix; a `note` is an
/// "accepted and ignored" remark, printed only under `--verbose`. Both are
/// plain strings allocated out of `arena`, so they live exactly as long as the
/// `Config` that carries them.
const Ctx = struct {
    arena: Allocator,
    warnings: *std.ArrayList([]const u8),
    notes: *std.ArrayList([]const u8),

    fn warn(cx: Ctx, comptime fmt: []const u8, args: anytype) Error!void {
        try cx.warnings.append(cx.arena, try std.fmt.allocPrint(cx.arena, fmt, args));
    }

    fn note(cx: Ctx, comptime fmt: []const u8, args: anytype) Error!void {
        try cx.notes.append(cx.arena, try std.fmt.allocPrint(cx.arena, fmt, args));
    }
};

// ===========================================================================
// config
// ===========================================================================

/// Load and expand `config_path` through the cwd.
pub fn load(io: Io, arena: Allocator, config_path: []const u8) LoadError!Config {
    return loadInDir(io, arena, Io.Dir.cwd(), config_path);
}

/// Load `config_path` (relative to `base`), resolve its `extends` chain,
/// merge, and expand its file list. All returned paths are relative to `base`.
fn loadInDir(io: Io, arena: Allocator, base: Io.Dir, config_path: []const u8) LoadError!Config {
    var cfg: Config = .{
        .path = config_path,
        .dir = paths.dirnamePart(config_path),
    };
    var warnings: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    const cx: Ctx = .{ .arena = arena, .warnings = &warnings, .notes = &notes };

    // Merge the `extends` chain (base configs applied first, this config last).
    var acc: Merged = .{};
    var chain: std.ArrayList([]const u8) = .empty;
    try mergeConfig(io, cx, base, config_path, cfg.dir, &acc, &chain, true);

    // `strict` is evaluated on the merged value (child overrides base per-key):
    // only an explicit final `false` is the unsupported case.
    if (acc.strict) |s| {
        if (!s) return error.StrictFalse;
    }

    cfg.lib = acc.lib;
    if (acc.module_suffixes) |ms| cfg.module_suffixes = ms;
    // Effective noImplicitAny = explicit value ?? strict. ztsc only runs strict
    // semantics (strict is true or absent — an explicit `false` errored above),
    // so the fallback is `true`; an explicit `noImplicitAny: false` still wins.
    cfg.no_implicit_any = acc.no_implicit_any orelse (acc.strict orelse true);
    if (!cfg.no_implicit_any) {
        try cx.note("'noImplicitAny' is off: implicit-'any' diagnostics (TS7006/TS7053) are suppressed; unannotated values still type as 'any'", .{});
    }
    cfg.experimental_decorators = acc.experimental_decorators orelse false;
    if (cfg.experimental_decorators) {
        try cx.note("'experimentalDecorators' honored: parameter decorators are accepted and decorator signatures are not checked against the standard 'Class*DecoratorContext' shapes (the legacy dialect calls them differently)", .{});
    }
    cfg.allow_js = acc.allow_js orelse false;
    if (cfg.allow_js) {
        try cx.note("'allowJs' honored: a specifier resolving only to a .js file is typed opaquely as 'any' (ztsc never parses JS; 'checkJs' is unsupported)", .{});
    }
    cfg.skip_lib_check = acc.skip_lib_check orelse false;
    cfg.skip_all_lib_check = acc.skip_all_lib_check orelse false;
    cfg.resolve_json_module = acc.resolve_json_module orelse false;
    cfg.no_unchecked_side_effect_imports = acc.no_unchecked_side_effect_imports orelse false;
    // `resolvePackageJsonExports`/`resolvePackageJsonImports` default ON: tsc
    // derives them from `moduleResolution` (on for node16/nodenext/bundler) and
    // ztsc always resolves with the bundler algorithm, so only an explicit
    // `false` changes any resolution. Resolved here, above the `types`
    // type-directive resolution (`collectAutoTypes` →
    // `resolve.resolveTypeDirective`), which is the first thing that needs it —
    // the driver carries the same value into its `ResolveCache` for imports.
    cfg.resolve_pkg_json_exports = acc.resolve_pkg_json_exports orelse true;
    cfg.resolve_pkg_json_imports = acc.resolve_pkg_json_imports orelse true;
    if (!cfg.resolve_pkg_json_exports) {
        try cx.note("'resolvePackageJsonExports' is off: 'package.json' \"exports\" maps are ignored entirely — every specifier resolves through the legacy \"types\"/\"typings\"/\"main\"/index path, and a subpath a map does not name is no longer blocked", .{});
    }
    if (!cfg.resolve_pkg_json_imports) {
        try cx.note("'resolvePackageJsonImports' is off: 'package.json' \"imports\" maps are ignored (ztsc never reads them, so this is already its behavior)", .{});
    }
    // Effective allowSyntheticDefaultImports = explicit value ?? esModuleInterop
    // ?? (module is system || moduleResolution is bundler). ztsc always resolves
    // with the bundler algorithm (`moduleResolution` is accepted and ignored
    // above), so the last term is unconditionally true here — the default is ON,
    // and only an explicit `false` (for either key) turns it off. Defaulting to
    // false false-positived TS1192 on every bundler project that omits
    // `esModuleInterop`.
    cfg.allow_synthetic_default_imports = acc.allow_synthetic_default_imports orelse acc.es_module_interop orelse true;
    if (cfg.allow_synthetic_default_imports) {
        try cx.note("'allowSyntheticDefaultImports' is on (explicit, via 'esModuleInterop', or by default under bundler resolution): a default import of a module with no default export binds to the module namespace object (the synthesized default)", .{});
    } else {
        try cx.note("'allowSyntheticDefaultImports'/'esModuleInterop' explicitly off: a default import of a module with no default export raises TS1192", .{});
    }
    if (acc.base_url) |bu| {
        cfg.base_url = try joinNormalize(arena, acc.base_url_dir, bu);
    }
    // Automatic JSX runtime: the `JSX` namespace comes from the
    // `<jsxImportSource>/jsx-runtime` module rather than global scope.
    if (acc.jsx) |j| {
        if (std.mem.eql(u8, j, "react-jsx") or std.mem.eql(u8, j, "react-jsxdev")) {
            cfg.jsx_runtime_module = try std.fmt.allocPrint(arena, "{s}/jsx-runtime", .{acc.jsx_import_source orelse "react"});
            try cx.note("'jsx: {s}': the `JSX` namespace is read from '{s}' (automatic runtime), falling back to a global `JSX` namespace", .{ j, cfg.jsx_runtime_module.? });
        }
    }
    if (cfg.skip_all_lib_check) {
        try cx.note("'skipLibCheck' honored: no diagnostics are surfaced from any .d.ts file (default lib and dependency/project .d.ts alike); their types still flow into .ts checking", .{});
    } else if (acc.skip_lib_check) |sv| {
        if (sv) {
            try cx.note("'skipDefaultLibCheck' honored: the embedded default lib is not type-checked (other .d.ts files are still checked; use 'skipLibCheck' to skip those too)", .{});
        } else {
            try cx.note("'skipLibCheck'/'skipDefaultLibCheck' is not enabled; the embedded default lib is type-checked (matching tsc/tsgo)", .{});
        }
    }

    // Build the paths map (validate: at most one '*' per key and value).
    // tsc anchors path targets at `baseUrl` when present, else at the directory
    // of the config that declared `paths` (both may come from different configs
    // after an extends merge).
    if (acc.paths_obj) |po| {
        const paths_base: []const u8 = if (acc.base_url) |bu|
            try joinNormalize(arena, acc.base_url_dir, bu)
        else
            try paths.normalizePath(arena, if (acc.paths_dir.len == 0) "." else acc.paths_dir);
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList([]const []const u8) = .empty;
        for (po.keys, po.vals) |pkey, pval| {
            if (std.mem.count(u8, pkey, "*") > 1) {
                try cx.warn("{s}: paths pattern '{s}' has more than one '*' (ignored)", .{ acc.paths_path, pkey });
                continue;
            }
            if (pval != .array) {
                try cx.warn("{s}: paths entry '{s}' must be an array (ignored)", .{ acc.paths_path, pkey });
                continue;
            }
            var targets: std.ArrayList([]const u8) = .empty;
            for (pval.array) |t| {
                if (t != .string or std.mem.count(u8, t.string, "*") > 1) {
                    try cx.warn("{s}: bad substitution in paths entry '{s}' (skipped)", .{ acc.paths_path, pkey });
                    continue;
                }
                try targets.append(arena, t.string);
            }
            try keys.append(arena, pkey);
            try vals.append(arena, try targets.toOwnedSlice(arena));
        }
        if (keys.items.len > 0) {
            cfg.paths = .{
                .keys = try keys.toOwnedSlice(arena),
                .vals = try vals.toOwnedSlice(arena),
                .base = paths_base,
            };
        }
    }

    // Expand the root file set. `files`/`include`/`exclude` each resolve
    // against the directory of the config that declared them (inherited entries
    // re-anchor to the base's directory).
    var root_files: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    if (acc.files) |list| {
        for (list) |f| {
            const joined = try joinNormalize(arena, acc.files_dir, f);
            const gop = try seen.getOrPut(arena, joined);
            if (!gop.found_existing) try root_files.append(arena, joined);
        }
    }

    // tsc: `include` defaults to everything only when `files` is absent.
    var include_pats: []const []const u8 = &.{};
    var include_dir: []const u8 = cfg.dir;
    if (acc.include) |list| {
        include_pats = list;
        include_dir = acc.include_dir;
    } else if (acc.files == null) {
        include_pats = &default_include;
    }
    if (include_pats.len > 0) {
        // Re-express include/exclude patterns in the base-relative space the
        // filesystem walk produces, so patterns from different configs (and the
        // walk root) share one coordinate system.
        var inc_abs: std.ArrayList([]const u8) = .empty;
        for (include_pats) |p| {
            try inc_abs.append(arena, try joinNormalize(arena, include_dir, try preprocessInclude(arena, p)));
        }
        var exc_abs: std.ArrayList([]const u8) = .empty;
        if (acc.exclude) |list| {
            for (list) |e| {
                try appendExclude(arena, &exc_abs, try joinNormalize(arena, acc.exclude_dir, e));
            }
        } else {
            try defaultExcludes(arena, &exc_abs, &acc);
        }
        var matcher: Matcher = .{
            .case_sensitive = caseSensitiveFs(io, arena, base, config_path),
            .base_abs = baseAbsPath(io, arena, base),
        };
        const matched = try expandInclude(io, cx, base, &matcher, include_dir, inc_abs.items, exc_abs.items, cfg.path);
        for (matched) |m| {
            const gop = try seen.getOrPut(arena, m);
            if (!gop.found_existing) try root_files.append(arena, m);
        }
    }

    cfg.root_files = try root_files.toOwnedSlice(arena);

    // Auto-include every visible `@types/*` package as an ambient program root
    // (tsc's default `typeRoots`), honoring `types`/`typeRoots`.
    const type_roots_abs: ?[]const []const u8 = if (acc.type_roots) |trs| blk: {
        var abs: std.ArrayList([]const u8) = .empty;
        for (trs) |r| try abs.append(arena, try joinNormalize(arena, acc.type_roots_dir, r));
        break :blk try abs.toOwnedSlice(arena);
    } else null;
    if (acc.types) |ts| {
        for (ts) |t| {
            if (std.mem.eql(u8, t, "*")) cfg.types_wildcard = true;
        }
    }
    cfg.auto_type_files = try collectAutoTypes(io, arena, base, cfg.dir, type_roots_abs, acc.types, cfg.resolve_pkg_json_exports);
    if (cfg.auto_type_files.len > 0) {
        try cx.note("auto-included {d} '@types' package(s) as ambient roots (tsc's default typeRoots); override with 'typeRoots'/'types'", .{cfg.auto_type_files.len});
    }

    cfg.warnings = try warnings.toOwnedSlice(arena);
    cfg.notes = try notes.toOwnedSlice(arena);
    return cfg;
}

pub const Config = struct {
    /// Path of the tsconfig.json that was loaded (base-relative).
    path: []const u8,
    /// Its directory ("" = the base directory itself), base-relative.
    dir: []const u8,
    /// Expanded root files: `files` entries first (in order), then
    /// include-matched files sorted by path; deduplicated.
    root_files: []const []const u8 = &.{},
    /// Auto-included `@types/*` package main declaration files (base-relative,
    /// sorted). tsc's default `typeRoots` behavior: with neither `types` nor
    /// `typeRoots` set, every `node_modules/@types/<pkg>` visible walking up
    /// from the project directory is an ambient program root. `typeRoots`
    /// overrides the root directories; `types: [...]` restricts to the named
    /// packages (`types: []` disables it). Kept separate from `root_files` so
    /// the "no inputs" diagnostic still keys on real sources; the driver appends
    /// these to the program roots. Skipped/checked per `skipLibCheck` like any
    /// other `.d.ts`.
    auto_type_files: []const []const u8 = &.{},
    /// `paths`/`baseUrl` mapping for module resolution, if configured.
    paths: ?Paths = null,
    /// `compilerOptions.lib` entries (as written), or null when the field is
    /// absent. Fed to `libs.resolveLibSet` to pick the built-in lib blobs;
    /// null selects the default set (ES-core + DOM, matching tsgo).
    lib: ?[]const []const u8 = null,
    /// `compilerOptions.moduleSuffixes` (TS 4.7), in order. Every candidate
    /// file name is probed once per suffix, inserted before the extension
    /// (tsc's `tryFile`); the empty string means the unsuffixed name. Empty
    /// = the option is absent, i.e. probe the plain name only. React Native
    /// projects set `[".ios", ".android", ".native", ""]`.
    module_suffixes: []const []const u8 = &.{},
    /// `compilerOptions.skipLibCheck` or `skipDefaultLibCheck` set to true.
    /// Suppresses type-checking of the embedded default lib (which ztsc checks
    /// by default, matching tsc/tsgo). `skipLibCheck` additionally sets
    /// `skip_all_lib_check` below (it subsumes `skipDefaultLibCheck`).
    skip_lib_check: bool = false,
    /// `compilerOptions.skipLibCheck` (only) set to true — the strict superset
    /// of `skipDefaultLibCheck`. Suppresses diagnostics located in *every*
    /// `.d.ts` file, not just the default lib, so ztsc's observable output
    /// matches tsc's on valid `.d.ts`. tsc keeps genuine *syntactic* errors in
    /// `.d.ts`; ztsc drops parser diagnostics there too, because it cannot
    /// distinguish a genuine syntax error from a parser-subset-gap cascade and
    /// published `.d.ts` are syntactically valid (no-false-positives wins over
    /// exact syntactic parity). `.d.ts` types still flow into `.ts`/`.tsx`.
    skip_all_lib_check: bool = false,
    /// Effective `compilerOptions.noImplicitAny` (true = on = report). tsc's
    /// rule is `noImplicitAny ?? strict`; ztsc only runs strict semantics, so an
    /// absent value defaults on (strict is true or absent). When off, the
    /// implicit-any diagnostic family (TS7006 parameter, TS7053 element index) is
    /// suppressed — the value still becomes `any`, only the diagnostic is gone.
    /// `strictNullChecks` etc. remain governed by `strict`, never coupled here.
    no_implicit_any: bool = true,
    /// `compilerOptions.types` contains the `"*"` wildcard (tsc's
    /// `usesWildcardTypes`). Its only effect on diagnostics: the node-flavoured
    /// not-found messages ("Do you need to install type definitions for node?")
    /// drop the "and then add 'node' to the types field" tail, which is a
    /// different diagnostic code — TS2580 rather than TS2591.
    types_wildcard: bool = false,
    /// `compilerOptions.allowJs`: a bare/relative specifier that resolves only to
    /// a JavaScript file (a JS-only package, or a `./x.js` with no `.ts`/`.d.ts`
    /// twin) is typed opaquely as `any` rather than raising TS2307. ztsc never
    /// parses/checks the JS. `checkJs` stays unsupported.
    allow_js: bool = false,
    /// `compilerOptions.experimentalDecorators`: the pre-TC39 ("legacy")
    /// decorator dialect Angular/NestJS/TypeORM are written against. It is a
    /// different LANGUAGE from the standard decorators ztsc otherwise
    /// implements, not a flag on top of them:
    ///
    ///   * parameter decorators (`constructor(@Inject(X) private x: T)`) are
    ///     grammatical, where the standard dialect makes them TS1206;
    ///   * a decorator is invoked as `(target, key, descriptorOrIndex)`, not
    ///     as `(value, context)`, so the standard `Class*DecoratorContext`
    ///     signature check (TS1238/1240/1241) does not describe it at all.
    ///
    /// When on, ztsc accepts both — the parameter-decorator grammar and every
    /// decorator signature. That is a deliberate under-report (a genuinely
    /// ill-typed legacy decorator goes unreported) chosen over the alternative,
    /// which is thousands of false positives on any Nest/Angular program.
    experimental_decorators: bool = false,
    /// `compilerOptions.resolveJsonModule`: a `*.json` import that names an
    /// existing file resolves (typed opaquely as `any`) rather than TS2307.
    resolve_json_module: bool = false,
    /// `compilerOptions.resolvePackageJsonExports`: when false, a dependency's
    /// `package.json` `"exports"` map is ignored entirely and every specifier
    /// resolves through the legacy `"types"`/`"typings"`/`"main"`/`index` path.
    /// Default true (see `resolve.ResolveOpts.resolve_pkg_json_exports` for the
    /// resolver-side contract and why the default does not follow
    /// `moduleResolution`). A real project turns this off when its dependencies
    /// publish `exports` maps with no `types` condition, which otherwise hide
    /// the declarations their own `"types"` key points at.
    resolve_pkg_json_exports: bool = true,
    /// `compilerOptions.resolvePackageJsonImports`: when false, a `#`-prefixed
    /// specifier ignores the importing package's `"imports"` map. Default true.
    /// ztsc does not implement that map at all, so the option is recorded and
    /// carried to the resolver but changes nothing today.
    resolve_pkg_json_imports: bool = true,
    /// `compilerOptions.noUncheckedSideEffectImports` (TS 5.6+). tsc's default is
    /// OFF: a side-effect-only `import "m"` whose specifier resolves to nothing
    /// is silently accepted, because bundler plugins routinely own such
    /// specifiers (`import "@fontsource-variable/inter"` is CSS). Only when the
    /// option is on does the unresolved specifier become an error. Note the
    /// pinned tsgo oracle defaults this ON — see `Linker.reportUnresolvedModules`.
    no_unchecked_side_effect_imports: bool = false,
    /// Effective `compilerOptions.allowSyntheticDefaultImports`, i.e.
    /// `allowSyntheticDefaultImports ?? esModuleInterop ?? (module is system ||
    /// moduleResolution is bundler)` (tsc's rule). ztsc always resolves with the
    /// bundler algorithm, so the fallback is `true` and only an explicit `false`
    /// turns it off. When on, a default import of a module that has no default
    /// export binds to the module namespace object (the synthesized default)
    /// instead of raising TS1192.
    allow_synthetic_default_imports: bool = true,
    /// `compilerOptions.baseUrl`, resolved to a base-relative directory (null
    /// when unset). Consulted for bare `*.json` specifiers only (`public/api/
    /// x.json`); non-json baseUrl resolution is not modeled.
    base_url: ?[]const u8 = null,
    /// Under the automatic JSX runtime (`jsx: "react-jsx"` / `"react-jsxdev"`)
    /// the `JSX` namespace is NOT a global: tsc reads it off the exports of the
    /// `<jsxImportSource>/jsx-runtime` module (`jsxImportSource` defaults to
    /// `"react"`). This is that module specifier, or null under the classic
    /// runtime / `preserve`, where the global `JSX` namespace is authoritative.
    /// The driver pulls the named module into the program (like `@types/node`)
    /// and the checker falls back to its `JSX` export when no global exists —
    /// @types/react 19 ships no `declare global { namespace JSX }` at all, so
    /// without this every intrinsic element (`<div>`, `<input>`) has an unknown
    /// props type and its attribute values lose their contextual type.
    jsx_runtime_module: ?[]const u8 = null,
    /// Non-fatal warnings (unknown options, bad shapes) for stderr.
    warnings: []const []const u8 = &.{},
    /// Accepted-and-ignored option notes, shown under --verbose only.
    notes: []const []const u8 = &.{},
};

/// Minimal `compilerOptions.paths` support: exact keys and single-`*`
/// patterns, values relative to `base` (baseUrl resolved against the
/// config directory).
pub const Paths = struct {
    keys: []const []const u8 = &.{},
    vals: []const []const []const u8 = &.{},
    /// Base-relative directory targets resolve against ("" = base dir).
    base: []const u8 = "",

    /// Map a bare specifier through the table. tsc rule: an exact-match key
    /// wins; otherwise the `*` pattern with the longest matched prefix.
    /// Returns candidate stem paths (base-relative, normalized) to feed
    /// module resolution; empty slice if no key matches.
    pub fn mapSpecifier(p: *const Paths, arena: Allocator, spec: []const u8) Error![]const []const u8 {
        var exact: ?usize = null;
        var best: ?usize = null;
        var best_prefix: usize = 0;
        for (p.keys, 0..) |key, i| {
            if (std.mem.indexOfScalar(u8, key, '*')) |star| {
                const prefix = key[0..star];
                const suffix = key[star + 1 ..];
                if (spec.len >= prefix.len + suffix.len and
                    std.mem.startsWith(u8, spec, prefix) and
                    std.mem.endsWith(u8, spec, suffix))
                {
                    if (best == null or prefix.len > best_prefix) {
                        best = i;
                        best_prefix = prefix.len;
                    }
                }
            } else if (std.mem.eql(u8, key, spec)) {
                exact = i;
            }
        }
        const idx = exact orelse (best orelse return &.{});
        const key = p.keys[idx];
        var out: std.ArrayList([]const u8) = .empty;
        for (p.vals[idx]) |val| {
            var target: []const u8 = val;
            if (exact == null) {
                // Substitute the '*' capture into the value.
                const star = std.mem.indexOfScalar(u8, key, '*').?;
                const captured = spec[star .. spec.len - (key.len - star - 1)];
                if (std.mem.indexOfScalar(u8, val, '*')) |vstar| {
                    target = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
                        val[0..vstar], captured, val[vstar + 1 ..],
                    });
                }
            }
            try out.append(arena, try joinNormalize(arena, p.base, target));
        }
        return out.toOwnedSlice(arena);
    }
};

pub const LoadError = error{
    OutOfMemory,
    /// The file could not be read.
    NotFound,
    /// The file is not valid JSONC.
    SyntaxError,
    /// `compilerOptions.strict` is explicitly false — unsupported.
    StrictFalse,
};

// ===========================================================================
// discovery
// ===========================================================================

/// `findUpwardInDir` from the current working directory, walking up as many
/// levels as the cwd path has components.
pub fn findUpward(io: Io, arena: Allocator) Error!?[]u8 {
    const cwd_path = std.process.currentPathAlloc(io, arena) catch return null;
    var levels: usize = 0;
    var it = std.mem.splitScalar(u8, cwd_path, '/');
    while (it.next()) |seg| {
        if (seg.len > 0) levels += 1;
    }
    return findUpwardInDir(io, arena, Io.Dir.cwd(), levels);
}

/// Look for `tsconfig.json` in `base`, then each parent, up to `max_levels`
/// parents. Returns the base-relative path ("tsconfig.json",
/// "../tsconfig.json", ...) or null.
fn findUpwardInDir(io: Io, arena: Allocator, base: Io.Dir, max_levels: usize) Error!?[]u8 {
    var prefix: std.ArrayList(u8) = .empty;
    var level: usize = 0;
    while (level <= max_levels) : (level += 1) {
        const cand = try std.fmt.allocPrint(arena, "{s}tsconfig.json", .{prefix.items});
        if (base.statFile(io, cand, .{})) |st| {
            if (st.kind == .file) return cand;
        } else |_| {}
        try prefix.appendSlice(arena, "../");
    }
    return null;
}

// ===========================================================================
// JSONC value parser (re-exports)
// ===========================================================================

// The parser itself lives in `jsonc.zig` — a general utility, not tsconfig
// policy: `link/resolve.zig` reads every `package.json` through it. Re-exported
// here so a caller that already has the tsconfig module need not import both.
pub const parseJsonc = jsonc.parseJsonc;
pub const Value = jsonc.Value;
pub const JsonError = jsonc.JsonError;

// ===========================================================================
// glob matcher (re-exports)
// ===========================================================================

// The pure pattern matcher lives in `glob.zig`; what stays here is the walk
// that uses it (`expandInclude`) and the policy that decides which paths are
// even offered to it (`implicitlyPruned`, `defaultExcludes`).
pub const globMatch = glob.globMatch;

const Matcher = glob.Matcher;
const isRooted = glob.isRooted;
const eqlPath = glob.eqlPath;
const literalPrefix = glob.literalPrefix;
const dirCoversPath = glob.dirCoversPath;

// ===========================================================================
// private implementation
// ===========================================================================

// ---------------------------------------------------------------------------
// config loading, extends resolution, include expansion
// ---------------------------------------------------------------------------

/// Enumerate the `@types/*` packages tsc would auto-include for this project,
/// returning each package's main declaration file (base-relative), sorted for
/// run-to-run determinism (directory iteration order is not stable).
///
/// Roots: `type_roots` when set (an explicit `typeRoots`), else every
/// `<ancestor>/node_modules/@types` walking up from `project_dir`. A package
/// name seen in a nearer root shadows the same name in a farther one (tsc's
/// closest-wins). Symlinked package directories (pnpm) are followed like tsc's
/// realpath resolution.
///
/// `types`, when non-null, replaces the enumeration: each entry is a *type
/// reference directive*, resolved the way tsc resolves one — the primary
/// lookup takes the first `<typeRoot>/<name>` package directory (also trying
/// DefinitelyTyped's `@scope/name` → `scope__name` convention), and on a miss
/// the secondary lookup is ordinary node-module resolution of the name from
/// the project directory (`resolve.resolveTypeDirective`). The secondary leg
/// is what makes a non-`@types` entry work: `types: ["vitest/globals"]`
/// resolves to `node_modules/vitest/globals.d.ts` through the package's
/// `exports` map — unless `use_pkg_exports` is false
/// (`resolvePackageJsonExports`), which resolves the directive through the
/// legacy fields like every other specifier. An empty `types` yields nothing;
/// an entry that resolves nowhere is skipped: tsc's TS2688 for it is a *file-less* global diagnostic
/// (the directive lives in the config, not in a source file), and ztsc prints
/// only file-anchored ones — an under-report. The same directive written as a
/// `/// <reference types="…" />` inside a source file does get TS2688, from
/// `Linker.reportUnresolvedTypeRefs`.
fn collectAutoTypes(
    io: Io,
    arena: Allocator,
    base: Io.Dir,
    project_dir: []const u8,
    type_roots: ?[]const []const u8,
    types: ?[]const []const u8,
    use_pkg_exports: bool,
) Error![]const []const u8 {
    // The `@types` root directories to scan, nearest first.
    var roots: std.ArrayList([]const u8) = .empty;
    if (type_roots) |trs| {
        for (trs) |r| try roots.append(arena, r);
    } else {
        var d = project_dir;
        while (true) {
            const at = if (d.len == 0)
                try arena.dupe(u8, "node_modules/@types")
            else
                try std.fmt.allocPrint(arena, "{s}/node_modules/@types", .{d});
            try roots.append(arena, at);
            // Base-relative walk cannot escape the base directory ("" stops the
            // climb); an absolute `project_dir` (the `-p /abs/path` case) climbs
            // to the filesystem root and covers every ancestor, matching tsc.
            if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) break;
            d = paths.dirnamePart(d);
        }
    }

    var out: std.ArrayList([]const u8) = .empty;

    // An explicit `types` list names type reference directives, not just
    // `@types` directories: resolve each one instead of enumerating.
    if (types) |list| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (list) |name| {
            if (name.len == 0) continue;
            const mangled = try typesDirName(arena, name);
            var found: ?[]u8 = null;
            primary: for (roots.items) |root| {
                const names: [2][]const u8 = .{ mangled, name };
                for (names, 0..) |n, i| {
                    if (i == 1 and std.mem.eql(u8, n, mangled)) continue;
                    const pkg_dir = if (root.len == 0)
                        try arena.dupe(u8, n)
                    else
                        try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, n });
                    if (try resolve.resolveTypesPackageMain(io, arena, base, pkg_dir)) |main| {
                        found = main;
                        break :primary;
                    }
                }
            }
            if (found == null) {
                found = try resolve.resolveTypeDirective(io, arena, base, project_dir, name, use_pkg_exports);
            }
            if (found) |f| {
                const gop = try seen.getOrPut(arena, f);
                if (!gop.found_existing) try out.append(arena, f);
            }
        }
        // NOT sorted: the enumeration branch sorts because directory iteration
        // order is not stable, but an explicit `types` list is already a
        // deterministic order — the one the user wrote — and it is the order
        // tsc loads the directives in. That order is observable when two
        // entries declare the same global (a project pulling in both
        // `vitest/globals` and, transitively, `@types/jest`, each declaring
        // `expect`): sorting would silently reshuffle which declaration the
        // merge sees last.
        return out.toOwnedSlice(arena);
    }

    // Collect unique package directory names (nearest root wins) -> package dir.
    var pkg_dirs: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (roots.items) |root| {
        const open_path = if (root.len == 0) "." else root;
        var dir = base.openDir(io, open_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            switch (entry.kind) {
                // pnpm stores each `@types/<pkg>` as a symlink; follow it.
                .directory, .sym_link => {},
                else => continue,
            }
            const gop = try pkg_dirs.getOrPut(arena, entry.name);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try arena.dupe(u8, entry.name);
            const pkg_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name });
            gop.value_ptr.* = pkg_dir;
            if (try resolve.resolveTypesPackageMain(io, arena, base, pkg_dir)) |main| {
                try out.append(arena, main);
            }
        }
    }

    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(arena);
}

/// Map a `compilerOptions.types` entry to its `@types` subdirectory name:
/// `"@scope/name"` → `"scope__name"` (DefinitelyTyped's scoped convention),
/// any other name unchanged.
fn typesDirName(arena: Allocator, name: []const u8) Error![]const u8 {
    if (name.len > 1 and name[0] == '@') {
        if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
            return std.fmt.allocPrint(arena, "{s}__{s}", .{ name[1..slash], name[slash + 1 ..] });
        }
    }
    return name;
}

/// Accumulator for the merged config across an `extends` chain. Each field that
/// carries relative paths remembers the directory of the config that set it, so
/// inherited entries re-anchor correctly (all base-relative). "Last write wins"
/// gives child-overrides-base semantics since bases are applied first.
const Merged = struct {
    strict: ?bool = null,
    no_implicit_any: ?bool = null,
    allow_js: ?bool = null,
    experimental_decorators: ?bool = null,
    jsx: ?[]const u8 = null,
    jsx_import_source: ?[]const u8 = null,
    lib: ?[]const []const u8 = null,
    module_suffixes: ?[]const []const u8 = null,
    skip_lib_check: ?bool = null,
    skip_all_lib_check: ?bool = null,
    resolve_json_module: ?bool = null,
    resolve_pkg_json_exports: ?bool = null,
    resolve_pkg_json_imports: ?bool = null,
    no_unchecked_side_effect_imports: ?bool = null,
    es_module_interop: ?bool = null,
    allow_synthetic_default_imports: ?bool = null,
    base_url: ?[]const u8 = null,
    base_url_dir: []const u8 = "",
    paths_obj: ?Value.Object = null,
    paths_dir: []const u8 = "",
    paths_path: []const u8 = "",
    files: ?[]const []const u8 = null,
    files_dir: []const u8 = "",
    include: ?[]const []const u8 = null,
    include_dir: []const u8 = "",
    exclude: ?[]const []const u8 = null,
    exclude_dir: []const u8 = "",
    // `compilerOptions.outDir` / `declarationDir`: emit-only for tsc and
    // meaningless to ztsc except as the *default* `exclude` (see
    // `defaultExcludes`). Anchored to the config that declared them.
    out_dir: ?[]const u8 = null,
    out_dir_dir: []const u8 = "",
    declaration_dir: ?[]const u8 = null,
    declaration_dir_dir: []const u8 = "",
    // `compilerOptions.types`: restrict auto-`@types` inclusion to the named
    // packages (null = unset → include everything; `[]` = include nothing).
    types: ?[]const []const u8 = null,
    // `compilerOptions.typeRoots`: override the default walk-up set of
    // `@types` root directories (base-relative, anchored to `type_roots_dir`).
    type_roots: ?[]const []const u8 = null,
    type_roots_dir: []const u8 = "",
};

/// Read, parse, and merge `config_path` (base-relative, directory `dir`) into
/// `acc`, resolving its `extends` bases first. `chain` is the stack of configs
/// currently being resolved (for cycle detection). `is_root` distinguishes the
/// user-named config (whose read/parse failures are hard errors) from a base
/// (whose failures warn and degrade to no-extends).
fn mergeConfig(
    io: Io,
    cx: Ctx,
    base: Io.Dir,
    config_path: []const u8,
    dir: []const u8,
    acc: *Merged,
    chain: *std.ArrayList([]const u8),
    is_root: bool,
) LoadError!void {
    try chain.append(cx.arena, config_path);
    defer _ = chain.pop();

    const text = base.readFileAlloc(io, config_path, cx.arena, .limited(16 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (is_root) return error.NotFound;
            try cx.warn("{s}: cannot read config referenced by 'extends' (ignored)", .{config_path});
            return;
        },
    };
    const root = parseJsonc(cx.arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            if (is_root) return error.SyntaxError;
            try cx.warn("{s}: config referenced by 'extends' is not valid JSON (ignored)", .{config_path});
            return;
        },
    };
    if (root != .object) {
        if (is_root) return error.SyntaxError;
        try cx.warn("{s}: config referenced by 'extends' is not an object (ignored)", .{config_path});
        return;
    }

    // Resolve `extends` bases first so their options apply before this config's.
    if (root.object.get("extends")) |ev| {
        const specs: []const Value = switch (ev) {
            .string => &.{ev},
            .array => ev.array,
            else => blk: {
                try cx.warn("{s}: 'extends' must be a string or an array of strings (ignored)", .{config_path});
                break :blk &.{};
            },
        };
        for (specs) |sv| {
            if (sv != .string) {
                try cx.warn("{s}: non-string entry in 'extends' (skipped)", .{config_path});
                continue;
            }
            const spec = sv.string;
            const resolved = try resolveExtends(io, cx.arena, base, dir, spec);
            if (resolved) |rp| {
                var cyclic = false;
                for (chain.items) |c| {
                    if (std.mem.eql(u8, c, rp)) cyclic = true;
                }
                if (cyclic) {
                    try cx.warn("{s}: TS18000: circularity detected resolving 'extends' to '{s}' (ignored)", .{ config_path, rp });
                    continue;
                }
                try mergeConfig(io, cx, base, rp, paths.dirnamePart(rp), acc, chain, false);
            } else {
                try cx.warn("{s}: cannot find config '{s}' referenced by 'extends' (ignored)", .{ config_path, spec });
            }
        }
    }

    try applyOwn(cx, root.object, dir, config_path, acc);
}

/// Apply one config object's own keys into `acc` (its `extends` already
/// handled). Later calls (the extending config) overwrite per-key.
fn applyOwn(
    cx: Ctx,
    obj: Value.Object,
    dir: []const u8,
    config_path: []const u8,
    acc: *Merged,
) Error!void {
    for (obj.keys, obj.vals) |key, val| {
        if (std.mem.eql(u8, key, "extends")) {
            // Already resolved by the caller.
        } else if (std.mem.eql(u8, key, "$schema") or std.mem.eql(u8, key, "display")) {
            // Editor/schema hints (common in shared base configs); tsc ignores
            // these silently, so we do too — no warning.
        } else if (std.mem.eql(u8, key, "files")) {
            if (try stringArray(cx, config_path, key, val)) |list| {
                acc.files = list;
                acc.files_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "include")) {
            if (try stringArray(cx, config_path, key, val)) |list| {
                acc.include = list;
                acc.include_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "exclude")) {
            if (try stringArray(cx, config_path, key, val)) |list| {
                acc.exclude = list;
                acc.exclude_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "compilerOptions")) {
            if (val != .object) {
                try cx.warn("{s}: 'compilerOptions' must be an object (ignored)", .{config_path});
                continue;
            }
            for (val.object.keys, val.object.vals) |okey, oval| {
                if (std.mem.eql(u8, okey, "strict")) {
                    if (oval == .boolean) {
                        acc.strict = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'strict' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noEmit")) {
                    try cx.note("{s}: 'noEmit' ignored (ztsc never emits)", .{config_path});
                } else if (std.mem.eql(u8, okey, "target") or
                    std.mem.eql(u8, okey, "module") or
                    std.mem.eql(u8, okey, "moduleResolution"))
                {
                    try cx.note("{s}: '{s}' accepted and ignored (ztsc always checks its fixed esnext/bundler subset)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "jsx")) {
                    // Kept only to decide where the `JSX` namespace lives: under
                    // the automatic runtime (`react-jsx`/`react-jsxdev`) tsc
                    // reads it off the `<jsxImportSource>/jsx-runtime` module's
                    // exports, not the global scope. Emit is never affected —
                    // ztsc does not emit.
                    if (oval == .string) acc.jsx = oval.string;
                } else if (std.mem.eql(u8, okey, "jsxImportSource")) {
                    if (oval == .string) acc.jsx_import_source = oval.string;
                } else if (std.mem.eql(u8, okey, "jsxFactory") or
                    std.mem.eql(u8, okey, "jsxFragmentFactory"))
                {
                    try cx.note("{s}: '{s}' accepted and ignored (ztsc type-checks JSX via the ambient/global `JSX` namespace; it never emits)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "lib")) {
                    if (try stringArray(cx, config_path, okey, oval)) |libs| {
                        acc.lib = libs;
                        for (libs) |name| {
                            if (!std.ascii.startsWithIgnoreCase(name, "es") and
                                !std.ascii.startsWithIgnoreCase(name, "dom"))
                            {
                                try cx.note("{s}: lib '{s}' is out of subset (ignored; ztsc ships es-core + dom)", .{ config_path, name });
                            }
                        }
                    }
                } else if (std.mem.eql(u8, okey, "moduleSuffixes")) {
                    // TS 4.7 `moduleSuffixes`: every candidate file name is
                    // probed once per suffix, inserted before the extension,
                    // in the configured order. React Native projects set
                    // `[".ios", ".android", ".native", ""]`, which is what
                    // makes `import './threads'` pick `threads.native.d.ts`.
                    if (try stringArray(cx, config_path, okey, oval)) |list| {
                        acc.module_suffixes = list;
                    }
                } else if (std.mem.eql(u8, okey, "resolveJsonModule")) {
                    if (oval == .boolean) {
                        acc.resolve_json_module = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'resolveJsonModule' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "resolvePackageJsonExports")) {
                    // Turning this off is the pre-`exports` resolver: no
                    // `exports` map resolves, hides a legacy field, or blocks a
                    // subpath (`resolve.resolvePackageAt`).
                    if (oval == .boolean) {
                        acc.resolve_pkg_json_exports = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'resolvePackageJsonExports' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "resolvePackageJsonImports")) {
                    if (oval == .boolean) {
                        acc.resolve_pkg_json_imports = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'resolvePackageJsonImports' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noUncheckedSideEffectImports")) {
                    if (oval == .boolean) {
                        acc.no_unchecked_side_effect_imports = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'noUncheckedSideEffectImports' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "esModuleInterop")) {
                    if (oval == .boolean) {
                        acc.es_module_interop = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'esModuleInterop' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "allowSyntheticDefaultImports")) {
                    if (oval == .boolean) {
                        acc.allow_synthetic_default_imports = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'allowSyntheticDefaultImports' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noImplicitAny")) {
                    if (oval == .boolean) {
                        acc.no_implicit_any = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'noImplicitAny' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "experimentalDecorators")) {
                    if (oval == .boolean) {
                        acc.experimental_decorators = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'experimentalDecorators' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "emitDecoratorMetadata")) {
                    // Emit-only (it makes tsc write `design:type` metadata
                    // calls); it has no effect on type checking, and ztsc
                    // never emits.
                    try cx.note("{s}: 'emitDecoratorMetadata' accepted and ignored (emit-only; ztsc never emits)", .{config_path});
                } else if (std.mem.eql(u8, okey, "allowJs")) {
                    if (oval == .boolean) {
                        acc.allow_js = oval.boolean;
                    } else {
                        try cx.warn("{s}: 'allowJs' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "types")) {
                    // `types: [...]` restricts auto-`@types` inclusion to the
                    // listed packages; `types: []` disables it. Applied in
                    // `collectAutoTypes`. A non-array is ignored (auto-include).
                    if (try stringArray(cx, config_path, okey, oval)) |list| {
                        acc.types = list;
                    }
                } else if (std.mem.eql(u8, okey, "typeRoots")) {
                    // `typeRoots: [...]` overrides the default walk-up set of
                    // `@types` root directories (anchored to this config's dir).
                    if (try stringArray(cx, config_path, okey, oval)) |list| {
                        acc.type_roots = list;
                        acc.type_roots_dir = dir;
                    }
                } else if (std.mem.eql(u8, okey, "skipLibCheck") or std.mem.eql(u8, okey, "skipDefaultLibCheck")) {
                    if (oval == .boolean) {
                        // Both keys skip the default lib. `skipLibCheck` is the
                        // superset: it also skips every other .d.ts file.
                        acc.skip_lib_check = oval.boolean;
                        if (std.mem.eql(u8, okey, "skipLibCheck")) {
                            acc.skip_all_lib_check = oval.boolean;
                        }
                    } else {
                        try cx.warn("{s}: '{s}' must be a boolean (ignored)", .{ config_path, okey });
                    }
                } else if (std.mem.eql(u8, okey, "outDir") or std.mem.eql(u8, okey, "declarationDir")) {
                    // Never used as an output location (ztsc does not emit),
                    // only as tsc's default `exclude`; see `defaultExcludes`.
                    if (oval == .string) {
                        if (std.mem.eql(u8, okey, "outDir")) {
                            acc.out_dir = oval.string;
                            acc.out_dir_dir = dir;
                        } else {
                            acc.declaration_dir = oval.string;
                            acc.declaration_dir_dir = dir;
                        }
                        // Worded for the general case: this fires while merging
                        // one config, before it is known whether some config in
                        // the chain has an `exclude` that drops the default.
                        try cx.note("{s}: '{s}' accepted; ztsc never emits, so it affects only the default 'exclude', which any explicit 'exclude' replaces", .{ config_path, okey });
                    } else {
                        try cx.warn("{s}: '{s}' must be a string (ignored)", .{ config_path, okey });
                    }
                } else if (std.mem.eql(u8, okey, "baseUrl")) {
                    if (oval == .string) {
                        acc.base_url = oval.string;
                        acc.base_url_dir = dir;
                    } else {
                        try cx.warn("{s}: 'baseUrl' must be a string (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "paths")) {
                    if (oval == .object) {
                        acc.paths_obj = oval.object;
                        acc.paths_dir = dir;
                        acc.paths_path = config_path;
                    } else {
                        try cx.warn("{s}: 'paths' must be an object (ignored)", .{config_path});
                    }
                } else {
                    try cx.warn("{s}: unknown compiler option '{s}' (ignored)", .{ config_path, okey });
                }
            }
        } else {
            try cx.warn("{s}: unknown option '{s}' (ignored)", .{ config_path, key });
        }
    }
}

/// Resolve an `extends` specifier (as written) from a config whose directory is
/// `from_dir` (base-relative). Returns the base-relative path of the base config
/// file, or null when it cannot be found. Relative/rooted specifiers are file
/// paths (`.json` implied); bare specifiers resolve node-style by walking up
/// `node_modules`.
fn resolveExtends(io: Io, arena: Allocator, base: Io.Dir, from_dir: []const u8, spec: []const u8) Error!?[]const u8 {
    if (spec.len == 0) return null;
    if (std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../") or
        std.mem.eql(u8, spec, ".") or std.mem.eql(u8, spec, "..") or spec[0] == '/')
    {
        const cand = try joinNormalize(arena, from_dir, spec);
        if (isFile(io, base, cand)) return cand;
        const withext = try std.fmt.allocPrint(arena, "{s}.json", .{cand});
        if (isFile(io, base, withext)) return withext;
        return null;
    }
    // Bare node-module specifier: walk up `node_modules`.
    var d: []const u8 = from_dir;
    while (true) {
        const nm = if (d.len == 0)
            try arena.dupe(u8, "node_modules")
        else
            try std.fmt.allocPrint(arena, "{s}/node_modules", .{d});
        if (try resolveExtendsInNodeModules(io, arena, base, nm, spec)) |p| return p;
        if (d.len == 0 or std.mem.eql(u8, d, "/") or std.mem.eql(u8, d, ".")) return null;
        d = paths.dirnamePart(d);
    }
}

/// Try to resolve `spec` under one `node_modules` directory (base-relative
/// `nm`): the file itself, `<file>.json`, then the package directory's
/// `package.json` `"tsconfig"` field (falling back to `tsconfig.json`).
fn resolveExtendsInNodeModules(io: Io, arena: Allocator, base: Io.Dir, nm: []const u8, spec: []const u8) Error!?[]const u8 {
    const full = try joinNormalize(arena, nm, spec);
    if (isFile(io, base, full)) return full;
    const withext = try std.fmt.allocPrint(arena, "{s}.json", .{full});
    if (isFile(io, base, withext)) return withext;

    // Treat `full` as a package/config directory.
    const pj = try std.fmt.allocPrint(arena, "{s}/package.json", .{full});
    if (base.readFileAlloc(io, pj, arena, .limited(1 << 20))) |ptext| {
        if (parseJsonc(arena, ptext)) |pv| {
            if (pv == .object) {
                if (pv.object.get("tsconfig")) |tv| {
                    if (tv == .string) {
                        const tcand = try joinNormalize(arena, full, tv.string);
                        if (isFile(io, base, tcand)) return tcand;
                        const te = try std.fmt.allocPrint(arena, "{s}.json", .{tcand});
                        if (isFile(io, base, te)) return te;
                    }
                }
            }
        } else |_| {}
    } else |_| {}
    const tj = try std.fmt.allocPrint(arena, "{s}/tsconfig.json", .{full});
    if (isFile(io, base, tj)) return tj;
    return null;
}

fn isFile(io: Io, base: Io.Dir, path: []const u8) bool {
    const st = base.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Does this filesystem distinguish `out` from `OUT`? Every include/exclude
/// comparison the walk makes hangs off the answer, because tsc and tsgo build
/// their matcher from the host's `useCaseSensitiveFileNames` — so on a Mac
/// `outDir: "OUT"` really does exclude `out/`, and on Linux it excludes nothing.
///
/// Answered the way tsc answers it — ask the filesystem, do not guess from the
/// OS name (a case-sensitive volume mounts fine on macOS, and a case-insensitive
/// one on Linux): stat a path known to exist under its case-swapped spelling.
/// The probe is `probe`, the config file itself, so the answer describes the
/// volume the project actually lives on. A probe with no ASCII letters (or one
/// that has vanished) answers "sensitive", the conservative reading — it keeps
/// every comparison exact.
fn caseSensitiveFs(io: Io, arena: Allocator, base: Io.Dir, probe: []const u8) bool {
    const swapped = arena.dupe(u8, probe) catch return true;
    var any = false;
    for (swapped) |*c| {
        if (std.ascii.isLower(c.*)) {
            c.* = std.ascii.toUpper(c.*);
            any = true;
        } else if (std.ascii.isUpper(c.*)) {
            c.* = std.ascii.toLower(c.*);
            any = true;
        }
    }
    if (!any) return true;
    return !isFile(io, base, swapped);
}

/// Canonical absolute path of the walk's base directory, or "" when the OS will
/// not say. Only rooted patterns need it (see `Matcher`); "" leaves those inert,
/// which is strictly better than matching the wrong tree.
fn baseAbsPath(io: Io, arena: Allocator, base: Io.Dir) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = base.realPathFile(io, ".", &buf) catch return "";
    var p = buf[0..n];
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return arena.dupe(u8, p) catch "";
}

const default_include = [_][]const u8{"**/*"};

/// The package folders tsc keeps the include walk out of (`implicitlyPruned`).
/// They are *not* a default `exclude` — that is `[outDir, declarationDir]`, see
/// `defaultExcludes`. Modeling them as an exclude instead would make them
/// unconditional and defeat the escape hatch: `include: ["node_modules/typed"]`
/// with no `exclude` field must still find its files.
const common_package_dirs = [_][]const u8{ "node_modules", "bower_components", "jspm_packages" };

/// tsc's default `exclude`, used only when the merged config has no `exclude`
/// key at all: the `outDir` and `declarationDir` that are set, each resolved
/// against the config that declared it. Appends the patterns to `out` via
/// `appendExclude`, in the walk's coordinate system (base-relative, or rooted
/// when the value was).
///
/// The rule is a plain substitution, not a union — it is `exclude` that decides,
/// and any `exclude` (even `[]`, even one inherited through `extends`) replaces
/// this list wholesale, so a project that sets `outDir` and any `exclude` roots
/// its own output. Nothing else is consulted: neither `declaration` (an
/// unusable `declarationDir` still excludes) nor whether the directory holds
/// real sources or is the project root (`outDir: "."` legitimately empties the
/// program), nor an `include` that names it — exclude always wins. Verified
/// against tsc 7.0.2.
///
/// A rooted (absolute) value works like any other: `appendExclude` keeps it
/// rooted and the walk lifts candidate paths into that space to match (see
/// `Matcher`), so `outDir: "/home/me/proj/out"` excludes exactly what the
/// relative spelling would. One outside the project matches nothing, which is
/// also what tsc does with it.
fn defaultExcludes(arena: Allocator, out: *std.ArrayList([]const u8), acc: *const Merged) Error!void {
    const dirs = [_]struct { ?[]const u8, []const u8 }{
        .{ acc.out_dir, acc.out_dir_dir },
        .{ acc.declaration_dir, acc.declaration_dir_dir },
    };
    for (dirs) |d| {
        const spec = d[0] orelse continue;
        try appendExclude(arena, out, try joinNormalize(arena, d[1], spec));
    }
}

/// Append the two patterns one `exclude` entry expands to: the entry itself, so
/// the walk prunes a named directory on sight, and `<entry>/**/*`, which is what
/// tsc's trailing `($|/)` buys — the only form that still bites when the
/// excluded directory is the walk root itself (or an ancestor of it) and so is
/// never tested as a child. `.` is the walk root spelled as a path, and its
/// subtree form has no prefix at all.
fn appendExclude(arena: Allocator, out: *std.ArrayList([]const u8), pat: []const u8) Error!void {
    try out.append(arena, pat);
    try out.append(arena, if (std.mem.eql(u8, pat, "."))
        "**/*"
    else if (std.mem.eql(u8, pat, "/"))
        "/**/*"
    else
        try std.fmt.allocPrint(arena, "{s}/**/*", .{pat}));
}

fn stringArray(
    cx: Ctx,
    config_path: []const u8,
    key: []const u8,
    val: Value,
) Error!?[]const []const u8 {
    if (val != .array) {
        try cx.warn("{s}: '{s}' must be an array of strings (ignored)", .{ config_path, key });
        return null;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (val.array) |item| {
        if (item != .string) {
            try cx.warn("{s}: non-string entry in '{s}' (skipped)", .{ config_path, key });
            continue;
        }
        try out.append(cx.arena, item.string);
    }
    return try out.toOwnedSlice(cx.arena);
}

fn joinNormalize(arena: Allocator, dir: []const u8, rest: []const u8) Error![]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".") or rest.len > 0 and rest[0] == '/') {
        return paths.normalizePath(arena, rest);
    }
    const joined = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, rest });
    defer arena.free(joined);
    return paths.normalizePath(arena, joined);
}

/// Preprocess an include pattern: normalize, and treat a directory-looking
/// pattern (last segment without wildcard or extension) as `p/**/*`.
fn preprocessInclude(arena: Allocator, pat: []const u8) Error![]const u8 {
    const norm = try paths.normalizePath(arena, pat);
    if (std.mem.eql(u8, norm, ".")) return "**/*";
    const last = if (std.mem.lastIndexOfScalar(u8, norm, '/')) |i| norm[i + 1 ..] else norm;
    const has_wild = std.mem.indexOfAny(u8, last, "*?") != null;
    const has_ext = std.mem.indexOfScalar(u8, last, '.') != null;
    if (!has_wild and !has_ext) {
        return std.fmt.allocPrint(arena, "{s}/**/*", .{norm});
    }
    return norm;
}

fn hasTsExt(name: []const u8) bool {
    // `.ts` (covers `.d.ts`) and `.tsx` (JSX). tsc includes both regardless
    // of the `jsx` option — that option governs emit, which ztsc never does.
    return std.mem.endsWith(u8, name, ".ts") or std.mem.endsWith(u8, name, ".tsx");
}

/// Walk from `walk_root` (base-relative dir) collecting `.ts`/`.d.ts` files
/// matching any `include` pattern and excluded by none. `include`/`exclude`
/// patterns are base-relative like the walked paths — except the rooted ones,
/// which `Matcher` handles — so patterns declared in different configs compose
/// correctly. Directories are additionally pruned by `implicitlyPruned`, which
/// `exclude` can neither turn on nor off — without it this walk descends the
/// entire dependency tree looking for sources that are never there.
/// Returned paths are base-relative and sorted.
fn expandInclude(
    io: Io,
    cx: Ctx,
    base: Io.Dir,
    m: *Matcher,
    walk_root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    config_path: []const u8,
) Error![]const []const u8 {
    const arena = cx.arena;
    var out: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, walk_root);

    while (stack.pop()) |cur| {
        const open_path = if (cur.len == 0) "." else cur;
        var d = base.openDir(io, open_path, .{ .iterate = true }) catch {
            if (std.mem.eql(u8, cur, walk_root)) {
                try cx.warn("{s}: cannot open directory '{s}'", .{ config_path, open_path });
            }
            continue;
        };
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            // Both arms decide on the unjoined `cur`/`entry.name` first and
            // materialize the child path only for entries that survive. On a
            // tree with a populated `node_modules` the rejected entries are the
            // overwhelming majority, and none of them should cost an arena
            // string that lives until the config arena dies.
            switch (entry.kind) {
                .directory => {
                    if (implicitlyPruned(m, include, cur, entry.name)) continue;
                    const child = try joinChild(arena, cur, entry.name);
                    if (!matchesAny(m, exclude, cur, entry.name, child)) try stack.append(arena, child);
                },
                .file => {
                    if (!hasTsExt(entry.name)) continue;
                    const child = try joinChild(arena, cur, entry.name);
                    if (matchesAny(m, exclude, cur, entry.name, child)) continue;
                    if (!matchesAny(m, include, cur, entry.name, child)) continue;
                    try out.append(arena, child);
                },
                else => {},
            }
        }
    }

    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(arena);
}

/// Does any of `patterns` match `<cur>/<name>`? `path` is that same join, which
/// the caller has already had to materialize; `cur`/`name` come along so a
/// rooted pattern can be answered without a second arena string.
fn matchesAny(m: *Matcher, patterns: []const []const u8, cur: []const u8, name: []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (isRooted(p)) {
            const abs = m.rooted(cur, name) orelse continue;
            if (globMatch(m.case_sensitive, p, abs)) return true;
        } else if (globMatch(m.case_sensitive, p, path)) return true;
    }
    return false;
}

/// tsc's implicit exclude (`implicitExcludePathRegexPattern`): include expansion
/// never descends into a directory named `node_modules`, `bower_components` or
/// `jspm_packages`. tsc splices that negative lookahead into the *wildcard*
/// fragment of each include pattern, never into the literal head, which makes
/// the rule positional: a package folder is reachable only while the walk is
/// still inside some pattern's wildcard-free prefix, and is unreachable
/// everywhere a wildcard could have put it.
///
/// So `include: ["src", "node_modules/typed"]` opts in exactly
/// `node_modules/typed` — not `src/deep/node_modules` (wildcard territory under
/// `src/**/*`), and not `node_modules/typed/node_modules` (past the end of the
/// literal prefix). A whole-pattern "does this name appear anywhere" test would
/// wrongly open all three, so the test is `<cur>/<name>` being an
/// ancestor-or-self of a literal prefix.
///
/// The same rule is what keeps a project that itself lives under a package
/// folder working (`-p root/node_modules/mypkg`, or an `extends` base inside
/// `node_modules` that declares `include`): the walk root's own segments are
/// inside every derived pattern's literal prefix, so they open, while package
/// dirs deeper in the project are still in wildcard territory and prune.
///
/// Takes `cur` and `name` unjoined so a pruned directory never allocates its
/// path. Purely lexical, so the walk stays deterministic. Both halves — the
/// folder name and the escape hatch — follow the filesystem's case rule, since
/// tsc splices the package names into the same regex that carries the `i` flag:
/// on macOS a `NODE_MODULES` prunes, and a lowercase `include` still names it.
fn implicitlyPruned(m: *Matcher, include: []const []const u8, cur: []const u8, name: []const u8) bool {
    for (common_package_dirs) |pkg_dir| {
        if (!eqlPath(m.case_sensitive, name, pkg_dir)) continue;
        for (include) |pat| {
            const prefix = literalPrefix(pat);
            if (isRooted(pat)) {
                // Only here — a package folder, under a rooted pattern — is
                // lifting the path out of the base-relative space worth it.
                const abs = m.rooted(cur, name) orelse continue;
                if (dirCoversPath(m.case_sensitive, abs, "", prefix)) return false;
            } else if (dirCoversPath(m.case_sensitive, cur, name, prefix)) return false;
        }
        return true;
    }
    return false;
}

fn joinChild(arena: Allocator, cur: []const u8, name: []const u8) Error![]const u8 {
    if (cur.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ cur, name });
}

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

test "config: files + include/exclude expansion" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src/gen");
    try d.createDirPath(io, "proj/vendor");
    try d.createDirPath(io, "proj/node_modules/pkg");
    try d.writeFile(io, .{ .sub_path = "proj/main.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/b.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/c.spec.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/gen/g.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/readme.md", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/vendor/v.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/pkg/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{
        \\  // subset config
        \\  "compilerOptions": { "strict": true, "noEmit": true, },
        \\  "files": ["main.ts"],
        \\  "include": ["src"],
        \\  "exclude": ["src/gen", "**/*.spec.ts"],
        \\}
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqualStrings("proj", cfg.dir);
    try testing.expectEqual(@as(usize, 3), cfg.root_files.len);
    try testing.expectEqualStrings("proj/main.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[1]);
    try testing.expectEqualStrings("proj/src/b.d.ts", cfg.root_files[2]);
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    try testing.expect(cfg.notes.len > 0); // noEmit note
}

/// Tree shared by the `outDir`/`declarationDir` default-exclude tests: sources
/// at the root and under `src`, generated output under `out` and `decls`.
/// `output/` and `out.ts` are the whole-segment decoys — `outDir: "out"` must
/// leave both alone, which a plain string-prefix exclude test would not.
fn writeOutDirTree(io: Io, d: Io.Dir, config: []const u8) !void {
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/out");
    try d.createDirPath(io, "proj/decls");
    try d.createDirPath(io, "proj/output");
    try d.writeFile(io, .{ .sub_path = "proj/root.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/out.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/out/b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/out/c.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/decls/e.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/output/o.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data = config });
}

test "config: outDir/declarationDir are the default exclude" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try writeOutDirTree(io, d,
        \\{ "compilerOptions": { "strict": true, "declaration": true,
        \\                       "outDir": "out", "declarationDir": "./decls/" } }
    );

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 4), cfg.root_files.len);
    // `out.ts` and `output/` are not `out`: the exclude matches whole segments.
    try testing.expectEqualStrings("proj/out.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/output/o.ts", cfg.root_files[1]);
    try testing.expectEqualStrings("proj/root.ts", cfg.root_files[2]);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[3]);
    // Accepted, not "unknown compiler option" (`declaration` still is one).
    try testing.expectEqual(@as(usize, 1), cfg.warnings.len);
    try testing.expectEqual(@as(usize, 3), cfg.notes.len); // both, plus skipLibCheck
}

test "config: any 'exclude' replaces the outDir default wholesale" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // An `exclude` that never mentions `out`/`decls` still un-excludes them:
    // the default is substituted, never unioned.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeOutDirTree(io, tmp.dir,
            \\{ "compilerOptions": { "strict": true, "outDir": "out", "declarationDir": "decls" },
            \\  "exclude": ["src"] }
        );
        const cfg = try loadInDir(io, alloc, tmp.dir, "proj/tsconfig.json");
        try testing.expectEqual(@as(usize, 6), cfg.root_files.len);
        try testing.expectEqualStrings("proj/decls/e.d.ts", cfg.root_files[0]);
        try testing.expectEqualStrings("proj/out.ts", cfg.root_files[1]);
        try testing.expectEqualStrings("proj/out/b.ts", cfg.root_files[2]);
        try testing.expectEqualStrings("proj/out/c.d.ts", cfg.root_files[3]);
        try testing.expectEqualStrings("proj/output/o.ts", cfg.root_files[4]);
        try testing.expectEqualStrings("proj/root.ts", cfg.root_files[5]);
    }
    // Even an empty one.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeOutDirTree(io, tmp.dir,
            \\{ "compilerOptions": { "strict": true, "outDir": "out" }, "exclude": [] }
        );
        const cfg = try loadInDir(io, alloc, tmp.dir, "proj/tsconfig.json");
        try testing.expectEqual(@as(usize, 7), cfg.root_files.len);
    }
}

test "config: the outDir default exclude beats an include that names it" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeOutDirTree(io, tmp.dir,
            \\{ "compilerOptions": { "strict": true, "outDir": "out" }, "include": ["out/**/*"] }
        );
        const cfg = try loadInDir(io, alloc, tmp.dir, "proj/tsconfig.json");
        try testing.expectEqual(@as(usize, 0), cfg.root_files.len);
    }
    // `outDir` at the project root excludes the project (tsc: TS18003).
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeOutDirTree(io, tmp.dir,
            \\{ "compilerOptions": { "strict": true, "outDir": "." } }
        );
        const cfg = try loadInDir(io, alloc, tmp.dir, "proj/tsconfig.json");
        try testing.expectEqual(@as(usize, 0), cfg.root_files.len);
    }
    // `""` is not "unset": it normalizes to the declaring config's directory,
    // so it empties the program exactly as `"."` does.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeOutDirTree(io, tmp.dir,
            \\{ "compilerOptions": { "strict": true, "outDir": "" } }
        );
        const cfg = try loadInDir(io, alloc, tmp.dir, "proj/tsconfig.json");
        try testing.expectEqual(@as(usize, 0), cfg.root_files.len);
    }
}

test "config: a project at the walk root excludes itself via the bare '**/*' form" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Config directory `""` is the one case where the excluded path normalizes
    // to `.`; the literal pattern cannot match (the walk root is never tested
    // as a child), so only the `**/*` descendant form empties the program.
    for ([_][]const u8{ ".", "" }) |out_dir| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const d = tmp.dir;
        try d.createDirPath(io, "src");
        try d.writeFile(io, .{ .sub_path = "root.ts", .data = "" });
        try d.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
        const config = try std.fmt.allocPrint(
            alloc,
            "{{ \"compilerOptions\": {{ \"strict\": true, \"outDir\": \"{s}\" }} }}",
            .{out_dir},
        );
        try d.writeFile(io, .{ .sub_path = "tsconfig.json", .data = config });

        const cfg = try loadInDir(io, alloc, d, "tsconfig.json");
        try testing.expectEqualStrings("", cfg.dir);
        try testing.expectEqual(@as(usize, 0), cfg.root_files.len);
    }
}

test "config: extends — outDir anchors to the config that declared it" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/out");
    try d.createDirPath(io, "proj/base/out");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/out/b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/base/out/q.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/base/tsconfig.base.json", .data =
        \\{ "compilerOptions": { "strict": true, "outDir": "out" } }
    });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "extends": "./base/tsconfig.base.json" }
    });

    // `out` means `proj/base/out`, so the project's own `proj/out` survives.
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 2), cfg.root_files.len);
    try testing.expectEqualStrings("proj/out/b.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[1]);
}

test "config: extends — a child's outDir replaces the base's, its declarationDir survives" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/out");
    try d.createDirPath(io, "proj/other");
    try d.createDirPath(io, "proj/base/out");
    try d.createDirPath(io, "proj/base/decls");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/out/b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/other/o.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/base/out/q.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/base/decls/w.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/base/tsconfig.base.json", .data =
        \\{ "compilerOptions": { "strict": true, "outDir": "out", "declarationDir": "decls" } }
    });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "extends": "./base/tsconfig.base.json", "compilerOptions": { "outDir": "other" } }
    });

    // The two options are independent: `outDir` is now `proj/other` (so the
    // base's `proj/base/out` is back in), while `declarationDir` still carries
    // the base's anchor and keeps `proj/base/decls` out.
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 3), cfg.root_files.len);
    try testing.expectEqualStrings("proj/base/out/q.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/out/b.ts", cfg.root_files[1]);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[2]);
}

test "config: extends — an inherited 'exclude' still replaces the outDir default" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try writeOutDirTree(io, d,
        \\{ "extends": "./tsconfig.base.json",
        \\  "compilerOptions": { "outDir": "out", "declarationDir": "decls" } }
    );
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.base.json", .data =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["src"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 6), cfg.root_files.len);
    try testing.expectEqualStrings("proj/decls/e.d.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/out.ts", cfg.root_files[1]);
    try testing.expectEqualStrings("proj/out/b.ts", cfg.root_files[2]);
    try testing.expectEqualStrings("proj/out/c.d.ts", cfg.root_files[3]);
    try testing.expectEqualStrings("proj/output/o.ts", cfg.root_files[4]);
    try testing.expectEqualStrings("proj/root.ts", cfg.root_files[5]);
}

// ---------------------------------------------------------------------------
// rooted (absolute) and case-mismatched patterns
//
// Every `want` below is what tsgo 7.0.2 actually produced for that config on
// the `writeOutDirTree` tree — a file-set oracle, not a reading of the rules:
// this is the one part of the loader where being subtly wrong shows up as a
// program that silently checks the wrong files.
// ---------------------------------------------------------------------------

/// The root-file sets the fixtures below select from, base-relative and sorted
/// exactly as `expandInclude` returns them.
const out_tree = struct {
    const all = [_][]const u8{
        "proj/decls/e.d.ts", "proj/out.ts",  "proj/out/b.ts", "proj/out/c.d.ts",
        "proj/output/o.ts",  "proj/root.ts", "proj/src/a.ts",
    };
    /// `out/` gone; `out.ts` and `output/` stay (whole-segment matching).
    const no_out = [_][]const u8{
        "proj/decls/e.d.ts", "proj/out.ts", "proj/output/o.ts", "proj/root.ts", "proj/src/a.ts",
    };
    const no_decls = [_][]const u8{
        "proj/out.ts", "proj/out/b.ts", "proj/out/c.d.ts", "proj/output/o.ts", "proj/root.ts", "proj/src/a.ts",
    };
    const no_out_decls = [_][]const u8{
        "proj/out.ts", "proj/output/o.ts", "proj/root.ts", "proj/src/a.ts",
    };
    const no_root = [_][]const u8{
        "proj/decls/e.d.ts", "proj/out.ts", "proj/out/b.ts", "proj/out/c.d.ts", "proj/output/o.ts", "proj/src/a.ts",
    };
    const no_dts = [_][]const u8{
        "proj/out.ts", "proj/out/b.ts", "proj/output/o.ts", "proj/root.ts", "proj/src/a.ts",
    };
    const only_src = [_][]const u8{"proj/src/a.ts"};
    const none = [_][]const u8{};
};

/// Substitute `needle` in `text`.
fn substAll(alloc: Allocator, text: []const u8, needle: []const u8, with: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, std.mem.replacementSize(u8, text, needle, with));
    _ = std.mem.replace(u8, text, needle, with, buf);
    return buf;
}

/// Expand `config` (a `writeOutDirTree` tsconfig, with `@ROOT@` standing for the
/// temporary directory's absolute path and `@ROOTUP@` for that path upper-cased)
/// and assert the root files come out as `want`.
fn expectOutTree(io: Io, alloc: Allocator, config: []const u8, want: []const []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    const root = baseAbsPath(io, alloc, d);
    try testing.expect(root.len > 0); // no absolute path, no rooted fixture
    const upper = try alloc.dupe(u8, root);
    for (upper) |*c| c.* = std.ascii.toUpper(c.*);
    try writeOutDirTree(io, d, try substAll(alloc, try substAll(alloc, config, "@ROOTUP@", upper), "@ROOT@", root));

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    var ok = cfg.root_files.len == want.len;
    if (ok) {
        for (cfg.root_files, want) |got, w| ok = ok and std.mem.eql(u8, got, w);
    }
    if (!ok) {
        std.debug.print("config: {s}\n  got: ", .{config});
        for (cfg.root_files) |f| std.debug.print(" {s}", .{f});
        std.debug.print("\n  want:", .{});
        for (want) |f| std.debug.print(" {s}", .{f});
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "config: rooted include/exclude/outDir match instead of being ignored" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const T = struct { cfg: []const u8, want: []const []const u8 };
    for ([_]T{
        // The default `exclude`, spelled rooted: same effect as `"out"`.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "outDir": "@ROOT@/proj/out" } }
        , .want = &out_tree.no_out },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "outDir": "@ROOT@/proj/out/" } }
        , .want = &out_tree.no_out },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "declarationDir": "@ROOT@/proj/decls" } }
        , .want = &out_tree.no_decls },
        // An explicit rooted `exclude`, of a directory and of a single file.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true },
        \\  "exclude": ["@ROOT@/proj/out", "@ROOT@/proj/decls"] }
        , .want = &out_tree.no_out_decls },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOT@/proj/root.ts"] }
        , .want = &out_tree.no_root },
        // Rooted globs, including one whose wildcard sits *above* the project —
        // the case no lexical rebase of the pattern could have handled.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOT@/proj/**/*.d.ts"] }
        , .want = &out_tree.no_dts },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOT@/*/out"] }
        , .want = &out_tree.no_out },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["@ROOT@/*/src/**/*"] }
        , .want = &out_tree.only_src },
        // `.` and `..` are normalized away before matching.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOT@/proj/src/../out"] }
        , .want = &out_tree.no_out },
        // Rooted `include`: a directory (which becomes `<dir>/**/*`) and a glob.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["@ROOT@/proj/src"] }
        , .want = &out_tree.only_src },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["@ROOT@/proj/**/*"] }
        , .want = &out_tree.all },
        // Rooted and relative patterns compose: exclude still beats include.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true },
        \\  "include": ["src", "out"], "exclude": ["@ROOT@/proj/out"] }
        , .want = &out_tree.only_src },
        // The walk root itself, and an ancestor of it: only the `<pat>/**/*`
        // companion form can bite here, and it must (tsc TS18003).
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "outDir": "@ROOT@/proj" } }
        , .want = &out_tree.none },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOT@"] }
        , .want = &out_tree.none },
        // Rooted somewhere else entirely: matches nothing, excludes nothing.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "outDir": "/tmp/ztsc-nowhere-xyz" } }
        , .want = &out_tree.all },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["/tmp/ztsc-nowhere-xyz/**/*"] }
        , .want = &out_tree.none },
    }) |c| try expectOutTree(io, alloc, c.cfg, c.want);
}

test "config: an exclude entry covers the directory it names, root or not" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // tsc terminates every exclude pattern with `($|/)`, so an entry naming the
    // walk root empties the program — the literal pattern alone cannot say so,
    // since the walk root is never tested as a child of anything.
    for ([_][]const u8{ ".", "", "src/..", "./" }) |spec| {
        const cfg = try std.fmt.allocPrint(
            alloc,
            "{{ \"compilerOptions\": {{ \"strict\": true }}, \"exclude\": [\"{s}\"] }}",
            .{spec},
        );
        try expectOutTree(io, alloc, cfg, &out_tree.none);
    }
}

/// Ground truth for the case fixtures, established without `caseSensitiveFs`:
/// write a file, then ask for it back under a different spelling.
fn tmpDirCaseSensitive(io: Io, d: Io.Dir) bool {
    d.writeFile(io, .{ .sub_path = "CaseProbe.tmp", .data = "" }) catch return true;
    return !isFile(io, d, "caseprobe.tmp");
}

test "caseSensitiveFs: agrees with the filesystem it is asked about" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{}" });
    try testing.expectEqual(
        tmpDirCaseSensitive(io, tmp.dir),
        caseSensitiveFs(io, arena.allocator(), tmp.dir, "tsconfig.json"),
    );
    // A probe that cannot answer (no letters to swap, or simply not there)
    // reports "sensitive", which leaves every comparison exact.
    try testing.expect(caseSensitiveFs(io, arena.allocator(), tmp.dir, "123/456"));
    try testing.expect(caseSensitiveFs(io, arena.allocator(), tmp.dir, "no-such-config.json"));
}

test "config: include/exclude casing follows the filesystem, like tsc's regex flag" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var probe = std.testing.tmpDir(.{});
    defer probe.cleanup();
    // On a case-insensitive volume the expectations are tsgo 7.0.2's, measured
    // on this machine; on a case-sensitive one they are tsgo's too — the only
    // thing that changes over there is the `i` flag on its pattern regexes, so
    // every mismatched spelling simply stops matching.
    const cs = tmpDirCaseSensitive(io, probe.dir);

    const T = struct { cfg: []const u8, ci_want: []const []const u8, cs_want: []const []const u8 };
    for ([_]T{
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true, "outDir": "OUT" } }
        , .ci_want = &out_tree.no_out, .cs_want = &out_tree.all },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["OUT", "DECLS"] }
        , .ci_want = &out_tree.no_out_decls, .cs_want = &out_tree.all },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["**/*.D.TS"] }
        , .ci_want = &out_tree.no_dts, .cs_want = &out_tree.all },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["SRC"] }
        , .ci_want = &out_tree.only_src, .cs_want = &out_tree.none },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["SRC/**/*"] }
        , .ci_want = &out_tree.only_src, .cs_want = &out_tree.none },
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "include": ["**/*.TS"] }
        , .ci_want = &out_tree.all, .cs_want = &out_tree.none },
        // Rooted *and* mis-cased: the walk lifts the path with the base's real
        // spelling, so the fold has to reach the rooted prefix too.
        .{ .cfg =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["@ROOTUP@/PROJ/OUT"] }
        , .ci_want = &out_tree.no_out, .cs_want = &out_tree.all },
    }) |c| try expectOutTree(io, alloc, c.cfg, if (cs) c.cs_want else c.ci_want);
}

test "expandInclude: one tree, both case rules — the sensitive half runs everywhere" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The fixtures above can only assert the rule this machine's filesystem
    // happens to have. Driving the walk directly pins down *both* halves on any
    // machine, which is the half that matters for not regressing Linux: with
    // `case_sensitive`, a mis-spelled pattern must go on matching nothing.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try writeOutDirTree(io, d,
        \\{ "compilerOptions": { "strict": true } }
    );
    const root = baseAbsPath(io, alloc, d);
    try testing.expect(root.len > 0);
    const rooted_out = try std.fmt.allocPrint(alloc, "{s}/proj/OUT", .{root});

    const T = struct {
        include: []const []const u8,
        exclude: []const []const u8,
        cs_want: []const []const u8,
        ci_want: []const []const u8,
    };
    for ([_]T{
        .{
            .include = &.{"proj/**/*"},
            .exclude = &.{ "proj/OUT", "proj/OUT/**/*" },
            .cs_want = &out_tree.all,
            .ci_want = &out_tree.no_out,
        },
        .{
            .include = &.{"proj/SRC/**/*"},
            .exclude = &.{},
            .cs_want = &out_tree.none,
            .ci_want = &out_tree.only_src,
        },
        .{
            .include = &.{"proj/**/*"},
            .exclude = &.{"**/*.D.TS"},
            .cs_want = &out_tree.all,
            .ci_want = &out_tree.no_dts,
        },
        .{
            .include = &.{"proj/**/*"},
            .exclude = &.{ rooted_out, try std.fmt.allocPrint(alloc, "{s}/**/*", .{rooted_out}) },
            .cs_want = &out_tree.all,
            .ci_want = &out_tree.no_out,
        },
    }) |c| {
        for ([_]bool{ true, false }) |cs| {
            var warnings: std.ArrayList([]const u8) = .empty;
            var notes: std.ArrayList([]const u8) = .empty;
            const cx: Ctx = .{ .arena = alloc, .warnings = &warnings, .notes = &notes };
            var m: Matcher = .{ .case_sensitive = cs, .base_abs = root };
            const got = try expandInclude(io, cx, d, &m, "proj", c.include, c.exclude, "proj/tsconfig.json");
            const want = if (cs) c.cs_want else c.ci_want;
            try testing.expectEqual(want.len, got.len);
            for (got, want) |g, w| try testing.expectEqualStrings(w, g);
        }
    }
}

test "config: the .ts extension gate stays case-sensitive whatever the filesystem" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // tsgo 7.0.2 on this (case-insensitive) machine does not pick these up:
    // the extension filter is a plain suffix test, applied outside the pattern
    // regex that carries the `i` flag. So `include: ["**/*.TS"]` matching
    // `a.ts` (above) and `a.TS` never being an input are both true at once.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj");
    try d.writeFile(io, .{ .sub_path = "proj/keep.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/upper.TS", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/upper.D.TS", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/upper.Tsx", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true } }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("proj/keep.ts", cfg.root_files[0]);
}

test "config: the node_modules prune follows the filesystem's casing" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var probe = std.testing.tmpDir(.{});
    defer probe.cleanup();
    const cs = tmpDirCaseSensitive(io, probe.dir);

    // tsc splices the package-folder names into the same regex the `i` flag is
    // put on, so on a case-insensitive volume `NODE_MODULES` prunes exactly
    // like `node_modules` — and a lowercase `include` still names it.
    const T = struct { include: []const u8, ci: usize, cs_: usize };
    for ([_]T{
        // Default include: pruned where the filesystem folds case, walked
        // (and its `.d.ts` rooted) where it does not.
        .{ .include = "", .ci = 1, .cs_ = 2 },
        // The escape hatch, spelled either way.
        .{ .include = ", \"include\": [\"src\", \"NODE_MODULES/pkg\"]", .ci = 2, .cs_ = 2 },
        .{ .include = ", \"include\": [\"src\", \"node_modules/pkg\"]", .ci = 2, .cs_ = 1 },
    }) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const d = tmp.dir;
        try d.createDirPath(io, "proj/src");
        try d.createDirPath(io, "proj/NODE_MODULES/pkg");
        try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
        try d.writeFile(io, .{ .sub_path = "proj/NODE_MODULES/pkg/index.d.ts", .data = "" });
        const config = try std.fmt.allocPrint(
            alloc,
            "{{ \"compilerOptions\": {{ \"strict\": true }}{s} }}",
            .{c.include},
        );
        try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data = config });

        const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
        try testing.expectEqual(if (cs) c.cs_ else c.ci, cfg.root_files.len);
        try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[cfg.root_files.len - 1]);
    }
}

test "implicitlyPruned: the escape hatch is positional, not global" {
    var m: Matcher = .{ .case_sensitive = true, .base_abs = "" };
    // Nothing names them: all three prune wherever they appear.
    try testing.expect(implicitlyPruned(&m, &.{"**/*"}, "", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &.{"**/*"}, "", "bower_components"));
    try testing.expect(implicitlyPruned(&m, &.{"**/*"}, "", "jspm_packages"));
    try testing.expect(implicitlyPruned(&m, &.{"**/*"}, "src/deep", "node_modules"));
    // Non-package directories are never the prune's business.
    try testing.expect(!implicitlyPruned(&m, &.{"**/*"}, "", "src"));
    try testing.expect(!implicitlyPruned(&m, &.{"**/*"}, "", "node_modules_x"));

    // `include: ["src", "node_modules/typed"]` opts in exactly the one folder
    // the literal prefix names — the defect a whole-pattern scan would create
    // is that the other two would open too.
    const inc = [_][]const u8{ "src/**/*", "node_modules/typed/**/*" };
    try testing.expect(!implicitlyPruned(&m, &inc, "", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &inc, "src/deep", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &inc, "node_modules/typed", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &inc, "", "jspm_packages"));

    // Wildcard territory always prunes, even one segment in: `src/*/index.ts`
    // could match `src/node_modules/index.ts` textually, and tsc still refuses.
    try testing.expect(implicitlyPruned(&m, &.{"src/*/index.ts"}, "src", "node_modules"));

    // A project *under* a package folder: the walk root's own segments sit
    // inside the pattern's literal prefix, so they open.
    const under = [_][]const u8{"node_modules/mypkg/src/**/*"};
    try testing.expect(!implicitlyPruned(&m, &under, "", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &under, "node_modules/mypkg", "node_modules"));
    try testing.expect(implicitlyPruned(&m, &under, "node_modules/mypkg/src/deep", "node_modules"));
}

test "config: explicit exclude does not re-enable walking node_modules" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    // An `exclude` that names neither node_modules nor the nested copy: tsc
    // still refuses to descend either, and so must ztsc.
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/node_modules/pkg");
    try d.createDirPath(io, "proj/src/node_modules/dep");
    try d.createDirPath(io, "proj/bower_components/widget");
    try d.createDirPath(io, "proj/tests");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/pkg/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/node_modules/dep/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/bower_components/widget/w.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tests/t.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true }, "exclude": ["tests"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[0]);
}

test "config: an include naming node_modules walks only what it names" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src/deep/node_modules/dep");
    try d.createDirPath(io, "proj/node_modules/typed/node_modules/inner");
    try d.createDirPath(io, "proj/jspm_packages/other");
    try d.writeFile(io, .{ .sub_path = "proj/src/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/src/deep/node_modules/dep/index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/typed/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/typed/node_modules/inner/index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/jspm_packages/other/o.ts", .data = "" });
    // No `exclude` field at all: the escape hatch must work without one, which
    // it cannot if the package folders are also modeled as a default exclude.
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{
        \\  "compilerOptions": { "strict": true },
        \\  "include": ["src", "node_modules/typed"],
        \\}
    });

    // Verified against tsc 7.0.2 `--showConfig` on the same tree: exactly these
    // two. `src/deep/node_modules` is wildcard territory under `src/**/*`;
    // `node_modules/typed/node_modules` is past the literal prefix.
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 2), cfg.root_files.len);
    try testing.expectEqualStrings("proj/node_modules/typed/index.d.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("proj/src/x.ts", cfg.root_files[1]);
}

test "config: a project under node_modules sees the same roots as anywhere else" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    // The identical tree at two placements. The prune must key on position
    // relative to the include patterns, not on whether `node_modules` happens
    // to appear in the project's own path.
    for ([_][]const u8{ "proj", "node_modules/mypkg" }) |root| {
        const dir = try std.fmt.allocPrint(alloc, "{s}/src/deep/node_modules/dep", .{root});
        try d.createDirPath(io, dir);
        try d.createDirPath(io, try std.fmt.allocPrint(alloc, "{s}/node_modules/other", .{root}));
        try d.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(alloc, "{s}/src/x.ts", .{root}),
            .data = "",
        });
        try d.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(alloc, "{s}/src/deep/node_modules/dep/index.ts", .{root}),
            .data = "",
        });
        try d.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(alloc, "{s}/node_modules/other/index.ts", .{root}),
            .data = "",
        });
        try d.writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(alloc, "{s}/tsconfig.json", .{root}),
            .data =
            \\{ "compilerOptions": { "strict": true }, "include": ["src"], "exclude": ["dist"] }
            ,
        });

        const cfg = try loadInDir(io, alloc, d, try std.fmt.allocPrint(alloc, "{s}/tsconfig.json", .{root}));
        try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
        try testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "{s}/src/x.ts", .{root}), cfg.root_files[0]);
    }
}

test "config: a 'files' entry under node_modules loads (the walk never sees it)" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/node_modules/pkg");
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/pkg/index.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true }, "files": ["node_modules/pkg/index.ts"] }
    });

    // `files` is a literal list, not a pattern — the prune is a property of
    // include expansion only, and `include` defaults to nothing when `files`
    // is present.
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("proj/node_modules/pkg/index.ts", cfg.root_files[0]);
}

test "auto @types: default walk-up includes every visible package, sorted" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    // Project-level @types: `alpha` (package.json "types") and `beta` (index).
    try d.createDirPath(io, "proj/node_modules/@types/alpha");
    try d.createDirPath(io, "proj/node_modules/@types/beta");
    // A parent-level @types the walk-up must also reach.
    try d.createDirPath(io, "node_modules/@types/gamma");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/alpha/package.json", .data =
        \\{ "name": "alpha", "types": "main.d.ts" }
    });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/alpha/main.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/beta/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/gamma/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true }, "include": ["src"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 3), cfg.auto_type_files.len);
    // Sorted lexically by path: "node_modules/..." (parent gamma) precedes
    // "proj/node_modules/..." (project alpha via its "types" field, then beta).
    try testing.expectEqualStrings("node_modules/@types/gamma/index.d.ts", cfg.auto_type_files[0]);
    try testing.expectEqualStrings("proj/node_modules/@types/alpha/main.d.ts", cfg.auto_type_files[1]);
    try testing.expectEqualStrings("proj/node_modules/@types/beta/index.d.ts", cfg.auto_type_files[2]);
}

test "auto @types: nearest node_modules shadows a farther same-named package" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/node_modules/@types/dup");
    try d.createDirPath(io, "node_modules/@types/dup");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/dup/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/@types/dup/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true }, "include": ["src"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 1), cfg.auto_type_files.len);
    // The nearer (project-level) copy wins.
    try testing.expectEqualStrings("proj/node_modules/@types/dup/index.d.ts", cfg.auto_type_files[0]);
}

test "auto @types: 'types' restricts (and scoped name maps to scope__name); '[]' disables" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    try d.createDirPath(io, "proj/node_modules/@types/keep");
    try d.createDirPath(io, "proj/node_modules/@types/drop");
    try d.createDirPath(io, "proj/node_modules/@types/scope__pkg");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/keep/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/drop/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/scope__pkg/index.d.ts", .data = "" });

    // types: ["keep", "@scope/pkg"] -> keep + scope__pkg only, drop excluded.
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true, "types": ["keep", "@scope/pkg"] }, "include": ["src"] }
    });
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 2), cfg.auto_type_files.len);
    try testing.expectEqualStrings("proj/node_modules/@types/keep/index.d.ts", cfg.auto_type_files[0]);
    try testing.expectEqualStrings("proj/node_modules/@types/scope__pkg/index.d.ts", cfg.auto_type_files[1]);

    // types: [] disables auto-inclusion entirely.
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true, "types": [] }, "include": ["src"] }
    });
    const cfg2 = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg2.auto_type_files.len);
}

test "auto @types: a 'types' entry that is not an @types package resolves as a package" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    // A real (non-DefinitelyTyped) package exposing a types-only subpath
    // through its `exports` map — the `vitest/globals` shape.
    try d.createDirPath(io, "proj/node_modules/vitest");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/vitest/package.json", .data =
        \\{ "name": "vitest", "types": "./dist/index.d.ts",
        \\  "exports": { "./globals": { "types": "./globals.d.ts" } } }
    });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/vitest/globals.d.ts", .data = "" });
    // A plain `"types"`-field package named without a subpath.
    try d.createDirPath(io, "proj/node_modules/@testing-library/jest-dom");
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@testing-library/jest-dom/package.json", .data =
        \\{ "name": "@testing-library/jest-dom", "types": "types/index.d.ts" }
    });
    try d.createDirPath(io, "proj/node_modules/@testing-library/jest-dom/types");
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@testing-library/jest-dom/types/index.d.ts", .data = "" });
    // An @types package still wins its name through the primary (typeRoots)
    // lookup, and an entry that resolves nowhere is simply dropped.
    try d.createDirPath(io, "proj/node_modules/@types/node");
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/node/index.d.ts", .data = "" });

    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true,
        \\    "types": ["vitest/globals", "@testing-library/jest-dom", "node", "nope"] },
        \\  "include": ["src"] }
    });
    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 3), cfg.auto_type_files.len);
    // In `types` order (not sorted): that is the order tsc loads the
    // directives in, and it decides which of two same-named globals is merged
    // last.
    try testing.expectEqualStrings("proj/node_modules/vitest/globals.d.ts", cfg.auto_type_files[0]);
    try testing.expectEqualStrings("proj/node_modules/@testing-library/jest-dom/types/index.d.ts", cfg.auto_type_files[1]);
    try testing.expectEqualStrings("proj/node_modules/@types/node/index.d.ts", cfg.auto_type_files[2]);
}

test "auto @types: 'typeRoots' overrides the default @types directories" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    // Default location — must be ignored once typeRoots is set.
    try d.createDirPath(io, "proj/node_modules/@types/ignored");
    // Custom typeRoots directory — its immediate children are the packages.
    try d.createDirPath(io, "proj/custom_types/only");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/node_modules/@types/ignored/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/custom_types/only/index.d.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true, "typeRoots": ["./custom_types"] }, "include": ["src"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 1), cfg.auto_type_files.len);
    try testing.expectEqualStrings("proj/custom_types/only/index.d.ts", cfg.auto_type_files[0]);
}

test "config: default include, node_modules excluded, unknown options warn" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "node_modules");
    try d.writeFile(io, .{ .sub_path = "a.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "b.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "node_modules/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "compilerOptions": { "esModuleInterop": true, "target": "es2020" },
        \\  "references": [] }
    });

    const cfg = try loadInDir(io, alloc, d, "tsconfig.json");
    try testing.expectEqual(@as(usize, 2), cfg.root_files.len);
    try testing.expectEqualStrings("a.ts", cfg.root_files[0]);
    try testing.expectEqualStrings("b.ts", cfg.root_files[1]);
    // references warns; target is a verbose note; esModuleInterop is honored
    // (recognized, effective allowSyntheticDefaultImports on → its own note).
    try testing.expect(cfg.allow_synthetic_default_imports);
    try testing.expectEqual(@as(usize, 1), cfg.warnings.len);
    try testing.expectEqual(@as(usize, 2), cfg.notes.len);
}

test "config: strict false is a hard error; missing file" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": false } }
    });
    try testing.expectError(error.StrictFalse, loadInDir(io, alloc, d, "tsconfig.json"));
    try testing.expectError(error.NotFound, loadInDir(io, alloc, d, "nope/tsconfig.json"));
    try d.writeFile(io, .{ .sub_path = "bad.json", .data = "{ oops }" });
    try testing.expectError(error.SyntaxError, loadInDir(io, alloc, d, "bad.json"));
}

test "config: paths + baseUrl mapping" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "app/src/lib");
    try d.writeFile(io, .{ .sub_path = "app/src/lib/util.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "app/src/core.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "app/tsconfig.json", .data =
        \\{
        \\  "compilerOptions": {
        \\    "strict": true,
        \\    "baseUrl": "./src",
        \\    "paths": {
        \\      "@lib/*": ["lib/*"],
        \\      "@lib/deep/*": ["lib/deep/*"],
        \\      "core": ["core.ts"],
        \\    }
        \\  },
        \\  "files": ["src/core.ts"]
        \\}
    });

    const cfg = try loadInDir(io, alloc, d, "app/tsconfig.json");
    const pm = cfg.paths.?;
    try testing.expectEqualStrings("app/src", pm.base);

    // Exact key.
    const c1 = try pm.mapSpecifier(alloc, "core");
    try testing.expectEqual(@as(usize, 1), c1.len);
    try testing.expectEqualStrings("app/src/core.ts", c1[0]);

    // Star key with substitution.
    const c2 = try pm.mapSpecifier(alloc, "@lib/util");
    try testing.expectEqual(@as(usize, 1), c2.len);
    try testing.expectEqualStrings("app/src/lib/util.ts", try std.fmt.allocPrint(alloc, "{s}.ts", .{c2[0]}));

    // Longest-prefix pattern wins.
    const c3 = try pm.mapSpecifier(alloc, "@lib/deep/x");
    try testing.expectEqualStrings("app/src/lib/deep/x", c3[0]);

    // No match.
    const c4 = try pm.mapSpecifier(alloc, "other");
    try testing.expectEqual(@as(usize, 0), c4.len);

    // Candidates actually resolve through module resolution.
    const resolved = try resolve.resolveStem(io, alloc, d, c2[0]);
    try testing.expect(resolved != null);
    try testing.expectEqualStrings("app/src/lib/util.ts", resolved.?);
}

test "findUpwardInDir walks parents" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "a/b/c");
    try d.writeFile(io, .{ .sub_path = "a/tsconfig.json", .data = "{}" });

    var deep = try d.openDir(io, "a/b/c", .{});
    defer deep.close(io);
    const found = try findUpwardInDir(io, alloc, deep, 4);
    try testing.expect(found != null);
    try testing.expectEqualStrings("../../tsconfig.json", found.?);

    var sib = try d.openDir(io, "a", .{});
    defer sib.close(io);
    const direct = try findUpwardInDir(io, alloc, sib, 0);
    try testing.expect(direct != null);
    try testing.expectEqualStrings("tsconfig.json", direct.?);
}

test "config-driven program builds and checks (conformance-style)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/skip");
    try d.writeFile(io, .{ .sub_path = "src/util.ts", .data =
        \\export function twice(n: number): number { return n + n; }
    });
    try d.writeFile(io, .{ .sub_path = "src/main.ts", .data =
        \\import { twice } from "./util";
        \\const ok: number = twice(2);
        \\const bad: string = twice(3);
    });
    try d.writeFile(io, .{ .sub_path = "src/skip/broken.ts", .data = "const x: number = \"nope\";" });
    try d.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "compilerOptions": { "strict": true },
        \\  "include": ["src"], "exclude": ["src/skip"] }
    });

    const cfg = try loadInDir(io, alloc, d, "tsconfig.json");
    try testing.expectEqual(@as(usize, 2), cfg.root_files.len);

    var interner = @import("intern.zig").Interner.init();
    defer interner.deinit(gpa);
    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, cfg.root_files, .none, .{}, .{
        .allow_synthetic_default = cfg.allow_synthetic_default_imports,
        .no_implicit_any = cfg.no_implicit_any,
    }, cfg.jsx_runtime_module);
    try testing.expectEqual(@as(usize, 2), br.program.files.len);

    const checker = @import("checker.zig");
    const owned = try alloc.alloc(modules.FileId, br.program.files.len);
    for (owned, 0..) |*f, i| f.* = @intCast(i);
    const result = try checker.checkFiles(alloc, io, gpa, &interner, &br.program, owned, null, true, 0);
    // Exactly the one TS2322 in main.ts line 3; skip/broken.ts is excluded.
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqual(@as(u16, 2322), result.diagnostics[0].code);
}

fn hasWarningContaining(cfg: Config, needle: []const u8) bool {
    for (cfg.warnings) |w| {
        if (std.mem.indexOf(u8, w, needle) != null) return true;
    }
    return false;
}

test "config: extends relative + chained, child overrides base per-key" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "proj/src");
    try d.writeFile(io, .{ .sub_path = "proj/src/a.ts", .data = "" });
    // Base sets strict/skipLibCheck/lib; mid overrides lib; leaf adds jsx.
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.base.json", .data =
        \\{ "compilerOptions": { "strict": true, "skipLibCheck": true, "lib": ["es2020"] } }
    });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.mid.json", .data =
        \\{ "extends": "./tsconfig.base.json",
        \\  "compilerOptions": { "lib": ["esnext", "dom"] } }
    });
    try d.writeFile(io, .{ .sub_path = "proj/tsconfig.json", .data =
        \\{ "extends": "./tsconfig.mid.json",
        \\  "compilerOptions": { "jsx": "react-jsx" },
        \\  "include": ["src"] }
    });

    const cfg = try loadInDir(io, alloc, d, "proj/tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    try testing.expect(cfg.skip_lib_check); // inherited from base
    try testing.expect(cfg.lib != null);
    // mid's lib wins over base's.
    try testing.expectEqual(@as(usize, 2), cfg.lib.?.len);
    try testing.expectEqualStrings("esnext", cfg.lib.?[0]);
    try testing.expectEqualStrings("dom", cfg.lib.?[1]);
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("proj/src/a.ts", cfg.root_files[0]);
}

test "config: extends node_modules specifier (subpath .json + package.json tsconfig field)" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "app/src/x");
    try d.createDirPath(io, "app/node_modules/@scope/cfg");
    try d.writeFile(io, .{ .sub_path = "app/src/x/u.ts", .data = "" });
    // Package dir with a "tsconfig" field, plus a subpath config that extends
    // the package base and declares paths.
    try d.writeFile(io, .{ .sub_path = "app/node_modules/@scope/cfg/package.json", .data =
        \\{ "name": "@scope/cfg", "tsconfig": "./base.json" }
    });
    try d.writeFile(io, .{ .sub_path = "app/node_modules/@scope/cfg/base.json", .data =
        \\{ "compilerOptions": { "strict": true, "skipLibCheck": true } }
    });
    try d.writeFile(io, .{ .sub_path = "app/node_modules/@scope/cfg/react.json", .data =
        \\{ "extends": "./base.json",
        \\  "compilerOptions": { "paths": { "@x/*": ["src/x/*"] } } }
    });

    // Child A: bare specifier with a subpath and explicit .json (the dogfood-project shape),
    // supplies baseUrl so paths anchor at the child dir.
    try d.writeFile(io, .{ .sub_path = "app/tsconfig.json", .data =
        \\{ "extends": "@scope/cfg/react.json",
        \\  "compilerOptions": { "baseUrl": "." },
        \\  "include": ["src"] }
    });
    const cfg = try loadInDir(io, alloc, d, "app/tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    try testing.expect(cfg.skip_lib_check);
    const pm = cfg.paths.?;
    try testing.expectEqualStrings("app", pm.base);
    const cand = try pm.mapSpecifier(alloc, "@x/u");
    try testing.expectEqual(@as(usize, 1), cand.len);
    try testing.expectEqualStrings("app/src/x/u", cand[0]);
    // src/x/u.ts is the only include.
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("app/src/x/u.ts", cfg.root_files[0]);

    // Child B: bare *package* specifier (no subpath) resolves via package.json
    // "tsconfig" field -> base.json.
    try d.writeFile(io, .{ .sub_path = "app/tsconfig.pkg.json", .data =
        \\{ "extends": "@scope/cfg", "include": ["src"] }
    });
    const cfg2 = try loadInDir(io, alloc, d, "app/tsconfig.pkg.json");
    try testing.expectEqual(@as(usize, 0), cfg2.warnings.len);
    try testing.expect(cfg2.skip_lib_check);
}

test "config: extends include/exclude inheritance re-anchors to base dir" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "ws/pkgs/base/lib/skip");
    try d.createDirPath(io, "ws/app/src");
    try d.writeFile(io, .{ .sub_path = "ws/pkgs/base/lib/t.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "ws/pkgs/base/lib/skip/s.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "ws/app/src/a.ts", .data = "" });
    // Base declares include/exclude relative to its own dir; child inherits both.
    try d.writeFile(io, .{ .sub_path = "ws/pkgs/base/base.json", .data =
        \\{ "compilerOptions": { "strict": true },
        \\  "include": ["lib"], "exclude": ["lib/skip"] }
    });
    try d.writeFile(io, .{ .sub_path = "ws/app/tsconfig.json", .data =
        \\{ "extends": "../pkgs/base/base.json",
        \\  "compilerOptions": { "jsx": "react-jsx" } }
    });

    const cfg = try loadInDir(io, alloc, d, "ws/app/tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    // Inherited include picks up base's lib (re-anchored), excludes lib/skip,
    // and does NOT pick up the child's own src/.
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("ws/pkgs/base/lib/t.ts", cfg.root_files[0]);
}

test "config: extends cycle detection and missing base degrade gracefully" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "cyc");
    try d.createDirPath(io, "mp");
    // Cycle: tsconfig -> a -> b -> a.
    try d.writeFile(io, .{ .sub_path = "cyc/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "cyc/a.json", .data =
        \\{ "extends": "./b.json", "compilerOptions": { "strict": true } }
    });
    try d.writeFile(io, .{ .sub_path = "cyc/b.json", .data =
        \\{ "extends": "./a.json", "compilerOptions": { "skipLibCheck": true } }
    });
    try d.writeFile(io, .{ .sub_path = "cyc/tsconfig.json", .data =
        \\{ "extends": "./a.json", "files": ["x.ts"] }
    });
    const cfg = try loadInDir(io, alloc, d, "cyc/tsconfig.json");
    // Breaks the cycle with a TS18000 warning; still loads the reachable opts.
    try testing.expect(hasWarningContaining(cfg, "TS18000"));
    try testing.expect(cfg.skip_lib_check); // from b.json before the cycle broke
    try testing.expectEqual(@as(usize, 1), cfg.root_files.len);
    try testing.expectEqualStrings("cyc/x.ts", cfg.root_files[0]);

    // Missing base: warns and degrades to no-extends (never crashes).
    try d.writeFile(io, .{ .sub_path = "mp/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "mp/tsconfig.json", .data =
        \\{ "extends": "./does-not-exist.json", "files": ["x.ts"] }
    });
    const cfg2 = try loadInDir(io, alloc, d, "mp/tsconfig.json");
    try testing.expect(hasWarningContaining(cfg2, "cannot find config"));
    try testing.expectEqual(@as(usize, 1), cfg2.root_files.len);
}

test "config: extends array applies bases in order (last wins), child overrides" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "arr");
    try d.writeFile(io, .{ .sub_path = "arr/x.ts", .data = "" });
    try d.writeFile(io, .{ .sub_path = "arr/one.json", .data =
        \\{ "compilerOptions": { "strict": true, "lib": ["es2020"], "skipLibCheck": false } }
    });
    try d.writeFile(io, .{ .sub_path = "arr/two.json", .data =
        \\{ "compilerOptions": { "lib": ["esnext"], "skipLibCheck": true } }
    });
    try d.writeFile(io, .{ .sub_path = "arr/tsconfig.json", .data =
        \\{ "extends": ["./one.json", "./two.json"], "files": ["x.ts"] }
    });
    const cfg = try loadInDir(io, alloc, d, "arr/tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    // two.json (last) wins lib and skipLibCheck over one.json.
    try testing.expectEqualStrings("esnext", cfg.lib.?[0]);
    try testing.expect(cfg.skip_lib_check);
}

test "config: noImplicitAny effective value (explicit false beats strict; default = strict) + allowJs" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.writeFile(io, .{ .sub_path = "x.ts", .data = "" });

    // (1) Absent noImplicitAny: effective value follows strict — ztsc runs strict
    //     semantics (strict true/absent), so implicit-any stays ON by default.
    try d.writeFile(io, .{ .sub_path = "a.json", .data =
        \\{ "compilerOptions": { "strict": true }, "files": ["x.ts"] }
    });
    const a = try loadInDir(io, alloc, d, "a.json");
    try testing.expect(a.no_implicit_any); // on
    try testing.expect(!a.allow_js);

    // (2) The dogfood-project shape: a base sets `noImplicitAny: false` + `allowJs`, a child
    //     that extends it keeps `strict: true`. The explicit false wins over
    //     strict; strict is NOT coupled to noImplicitAny.
    try d.writeFile(io, .{ .sub_path = "base.json", .data =
        \\{ "compilerOptions": { "strict": true, "noImplicitAny": false, "allowJs": true } }
    });
    try d.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "extends": "./base.json",
        \\  "compilerOptions": { "strict": true },
        \\  "files": ["x.ts"] }
    });
    const cfg = try loadInDir(io, alloc, d, "tsconfig.json");
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);
    try testing.expect(!cfg.no_implicit_any); // explicit false wins over strict
    try testing.expect(cfg.allow_js); // inherited from base

    // (3) A child can turn it back on over a base's false (last write wins).
    try d.writeFile(io, .{ .sub_path = "on.json", .data =
        \\{ "extends": "./base.json",
        \\  "compilerOptions": { "noImplicitAny": true },
        \\  "files": ["x.ts"] }
    });
    const on = try loadInDir(io, alloc, d, "on.json");
    try testing.expect(on.no_implicit_any); // child's explicit true wins
    try testing.expect(on.allow_js); // still inherited
    // noImplicitAny / allowJs are recognized options — no "unknown option" warning.
    for (cfg.warnings) |w| try testing.expect(std.mem.indexOf(u8, w, "noImplicitAny") == null and std.mem.indexOf(u8, w, "allowJs") == null);
}
