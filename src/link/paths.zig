//! Lexical path predicates and utilities — pure string work, no filesystem
//! access.
//!
//! Two groups live here: the path *shape* predicates the loader and the
//! diagnostic printer key on (declaration file, JSON/JS any-module, the
//! synthetic `exports`-blocked subpath), and the lexical path algebra module
//! resolution is built from (`normalizePath`, `dirnamePart`, `joinNormalize`).
//! The synthetic any-module source texts sit next to the predicates that
//! select them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The only failure these helpers can have is allocation. Spelled with the
/// standard error set (not the link layer's alias) so this file imports
/// nothing from the layer above it — paths.zig is a leaf.
const Error = Allocator.Error;

/// True for a TypeScript *declaration* file (`.d.ts`, `.d.mts`, `.d.cts`). These
/// never emit and — under `skipLibCheck` — have all their diagnostics
/// suppressed. The `.d.mts`/`.d.cts` variants matter for ESM/CJS-dual packages
/// (redux-toolkit, zod, typebox) whose published types live in those files.
pub fn isDeclarationPath(path: []const u8) bool {
    return endsWithAny(path, &.{ ".d.ts", ".d.mts", ".d.cts" });
}

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

pub fn joinNormalize(alloc: Allocator, dir: []const u8, rest: []const u8) Error![]u8 {
    if (dir.len == 0) return normalizePath(alloc, rest);
    const joined = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, rest });
    defer alloc.free(joined);
    return normalizePath(alloc, joined);
}

/// The Node.js built-in modules tsc resolves via an auto-included `@types/node`
/// (its `declare module "fs"` / `declare module "node:fs"` blocks). `node:`-
/// prefixed specifiers are always built-ins; the bare names cover the common
/// unprefixed imports. Used by `modules.Discovery.discoverNodeTypes` — both
/// program builders — to pull `@types/node` into the program on demand so those
/// ambient blocks register and the import resolves.
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

/// tsc's *exact* Node core-module list (`core.NodeCoreModules` in tsgo,
/// `nodeCoreModules` in TypeScript): every name `require('module').builtinModules`
/// reports, each accepted bare and `node:`-prefixed, plus the handful that exist
/// only under the prefix.
///
/// Distinct from `isNodeBuiltin`, and deliberately so. `isNodeBuiltin` answers
/// "should the driver pull `@types/node` in for this specifier?", where being
/// generous costs nothing (`node:anything` counts). This one decides a
/// *diagnostic code*: an unresolved specifier in this set is TS2591 ("…install
/// type definitions for node…"), one outside it is the generic TS2307. The
/// oracle draws that line precisely — `node:sqlite` is TS2591 while
/// `node:nosuch` and bare `test` are TS2307 — so an approximation here would
/// invent a wrong code on real input.
pub fn isNodeCoreModule(spec: []const u8) bool {
    // `require('module').builtinModules.filter(x => !x.match(/^(?:_|node:)/))`
    const unprefixed = [_][]const u8{
        "assert",           "assert/strict",      "async_hooks",         "buffer",
        "child_process",    "cluster",            "console",             "constants",
        "crypto",           "dgram",              "diagnostics_channel", "dns",
        "dns/promises",     "domain",             "events",              "fs",
        "fs/promises",      "http",               "http2",               "https",
        "inspector",        "inspector/promises", "module",              "net",
        "os",               "path",               "path/posix",          "path/win32",
        "perf_hooks",       "process",            "punycode",            "querystring",
        "readline",         "readline/promises",  "repl",                "stream",
        "stream/consumers", "stream/promises",    "stream/web",          "string_decoder",
        "sys",              "timers",             "timers/promises",     "tls",
        "trace_events",     "tty",                "url",                 "util",
        "util/types",       "v8",                 "vm",                  "wasi",
        "worker_threads",   "zlib",
    };
    // `require('module').builtinModules.filter(x => x.startsWith('node:'))`
    const prefixed_only = [_][]const u8{
        "node:quic", "node:sea", "node:sqlite", "node:test", "node:test/reporters",
    };
    const bare = if (std.mem.startsWith(u8, spec, "node:")) spec["node:".len..] else spec;
    for (unprefixed) |b| if (std.mem.eql(u8, bare, b)) return true;
    for (prefixed_only) |b| if (std.mem.eql(u8, spec, b)) return true;
    return false;
}

/// The global names tsc attributes to `@types/node` when they resolve to
/// nothing: an unresolved use is TS2591 ("…install type definitions for
/// node…") rather than the generic TS2304. tsgo's
/// `getCannotFindNameDiagnosticForName` keys off exactly these five, and only
/// for a bare identifier — a qualified `NodeJS.Timeout` fails as a *namespace*
/// (TS2503) and never reaches here.
pub fn isNodeGlobalName(name: []const u8) bool {
    const names = [_][]const u8{ "process", "require", "Buffer", "module", "NodeJS" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// The globals a test runner's typings would have declared — tsc's
/// `getCannotFindNameDiagnosticForName` `describe`/`suite`/`it`/`test` arm, which
/// answers TS2582/TS2593 instead of the plain TS2304.
pub fn isTestRunnerGlobalName(name: []const u8) bool {
    const names = [_][]const u8{ "describe", "suite", "it", "test" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Embedded synthetic source for a resolved JSON or JS any-module (or an
/// `exports`-blocked subpath), or null for a real file that must be read and
/// parsed. Centralizes the loader's any-module routing (JSON via
/// `resolveJsonModule`, JS via `allowJs`, blocked subpaths via a present
/// `exports` map that omits the subpath).
pub fn anyModuleSourceFor(path: []const u8) ?[]const u8 {
    if (isJsonModulePath(path)) return json_module_source;
    if (isJsModulePath(path)) return js_module_source;
    if (isBlockedSubpathPath(path)) return js_module_source;
    return null;
}

/// True for a program path that is a resolved JSON module (loaded as
/// `json_module_source`, not read/parsed from disk). Only reachable when
/// `resolveJsonModule` routed a `*.json` specifier to an on-disk file.
fn isJsonModulePath(path: []const u8) bool {
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

/// True when `path` lies inside a `node_modules` directory — tsc's
/// `isExternalLibraryImport`. A JavaScript file resolved from there is never
/// added to the program (it is past `maxNodeModuleJsDepth`), so tsc types the
/// module `any` and reports TS7016; a JavaScript file resolved from the
/// project itself (a relative `./x.js`, or a `baseUrl`/`paths` mapping) IS
/// added and stays silent. Forward slashes only, as everywhere in the loader.
pub fn isInNodeModules(path: []const u8) bool {
    var rest = path;
    while (std.mem.indexOf(u8, rest, "node_modules")) |at| {
        const before_ok = at == 0 or rest[at - 1] == '/';
        const end = at + "node_modules".len;
        if (before_ok and end < rest.len and rest[end] == '/') return true;
        rest = rest[end..];
    }
    return false;
}

/// True for a synthetic exports-blocked-subpath any-module path (see
/// `blocked_subpath_suffix`).
pub fn isBlockedSubpathPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, blocked_subpath_suffix);
}

/// Build the stable, deterministic synthetic program path for an
/// `exports`-blocked subpath under `nm` (`node_modules/<pkg>`, base-relative)
/// with import subpath `sub`. Owned by `alloc`. Recognized by
/// `anyModuleSourceFor` as an opaque `any` module.
pub fn blockedSubpathPath(alloc: Allocator, nm: []const u8, sub: []const u8) Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ nm, sub, blocked_subpath_suffix });
}

pub fn endsWithAny(s: []const u8, exts: []const []const u8) bool {
    for (exts) |e| if (std.mem.endsWith(u8, s, e)) return true;
    return false;
}

/// Synthetic TypeScript source substituted for a resolved `*.json` module
/// (`resolveJsonModule`). tsc synthesizes a structural type from the JSON
/// literal; the under-report policy lets us type the module opaquely as `any`
/// instead (a missed error is allowed, a false positive is not). `export =` (not
/// `export default`) makes the module absorb every import form — default,
/// namespace, and named — as `any` without a spurious TS1192/TS2305. The
/// loaders special-case a `.json` program path to this text instead of parsing
/// the raw JSON as TypeScript.
const json_module_source = "declare const j: any;\nexport = j;\n";

/// Synthetic source substituted for a resolved JavaScript module under
/// `allowJs`, and for the JavaScript an `exports` map names when the package
/// ships no declarations behind it. Identical shape to `json_module_source`
/// (opaque `any` via `export =`): ztsc never parses/checks JS, so a JS-only
/// dependency (`qs`, `leaflet.markercluster`) types as `any` instead of
/// raising TS2307. Under `noImplicitAny` tsc reports TS7016 at the specifier
/// for such a module when it came from `node_modules`; the linker does the
/// same (`Linker.reportUnresolvedModules`).
const js_module_source = json_module_source;

/// Synthetic program-path suffix marking an `exports`-blocked subpath — a
/// `<pkg>/<sub>` import where `<pkg>` publishes an `exports` map that does NOT
/// name `<sub>`. A published `exports` map is a closed set of entry points, so
/// tsc's bundler/Node16 resolution refuses to legacy-probe the filesystem for
/// such a subpath and the reference degrades to `any`. `resolvePackageAt`
/// mirrors that by routing the subpath to a stable opaque `any` module carrying
/// this suffix, rather than returning null (an UNRESOLVED specifier dangles a
/// symbol in the parallel resolution phase — an intermittent, load-dependent
/// crash). The suffix is deliberately not a real file extension: it never
/// collides with an on-disk file, and `anyModuleSourceFor` recognizes it so the
/// loader substitutes the synthetic `any` body and never touches disk. It is
/// also what the linker keys tsc's TS2307 off (`blockedSubpathReport`): the
/// stand-in keeps the symbols alive, the suffix keeps the diagnostic.
pub const blocked_subpath_suffix = ".ztsc-exports-blocked";

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

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

// (b2) The exact core-module list that picks TS2591 over TS2307. Every case
// below is pinned against tsgo 7.0.2 on a project with no `@types/node`.
test "isNodeCoreModule: exactly tsc's list, bare and node:-prefixed" {
    try testing.expect(isNodeCoreModule("node:tty"));
    try testing.expect(isNodeCoreModule("tty"));
    try testing.expect(isNodeCoreModule("fs/promises"));
    try testing.expect(isNodeCoreModule("node:fs/promises"));
    try testing.expect(isNodeCoreModule("stream/consumers"));
    // Prefix-only members: `node:sqlite` counts, bare `sqlite` does not, and
    // bare `test` is an ordinary package name (oracle: TS2307).
    try testing.expect(isNodeCoreModule("node:sqlite"));
    try testing.expect(!isNodeCoreModule("sqlite"));
    try testing.expect(isNodeCoreModule("node:test/reporters"));
    try testing.expect(!isNodeCoreModule("test"));
    // Unlike `isNodeBuiltin`, an unknown name under the prefix is NOT a core
    // module — tsgo reports TS2307 for it.
    try testing.expect(!isNodeCoreModule("node:nosuch"));
    try testing.expect(!isNodeCoreModule("bun:sqlite"));
    try testing.expect(!isNodeCoreModule("react"));
    try testing.expect(!isNodeCoreModule("./local"));
}

// (b3) The five globals that carry the "install @types/node" wording.
test "isNodeGlobalName: tsc's five node globals" {
    for ([_][]const u8{ "process", "require", "Buffer", "module", "NodeJS" }) |n| {
        try testing.expect(isNodeGlobalName(n));
    }
    try testing.expect(!isNodeGlobalName("buffer")); // case-sensitive
    try testing.expect(!isNodeGlobalName("Bufferr"));
    try testing.expect(!isNodeGlobalName("global"));
    try testing.expect(!isNodeGlobalName("__dirname"));
}
