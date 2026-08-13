//! `package.json` reading: the pure-text half of module resolution.
//!
//! Everything here is a function of a `package.json` body (plus, for
//! `mapTypesVersions`, the subpath being resolved) — no filesystem, no
//! candidate probing, no options. resolve.zig reads the file (through the
//! `FsCache` or straight from disk) and asks these for the fields it needs:
//! the legacy `"types"`/`"typings"`/`"main"` entries (a minimal root-object
//! string scan, deliberately not a full parse), the `"exports"` map and the
//! condition/subpath rules that select inside it, and the pre-`exports`
//! `typesVersions` redirection layer.
//!
//! Keeping it separate is what makes it testable without a filesystem: every
//! test below is a string in, an answer out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tsconfig = @import("../tsconfig.zig");

const Error = Allocator.Error;

/// Minimal `package.json` scan for the string value of the first of `keys`
/// (quoted key literals, e.g. `"types"`) that appears as a key of the ROOT
/// object. Keys are tried in the given priority order, each over the whole
/// file, so declaration order in the file does not decide between them.
///
/// Nesting matters: a flat substring search matched `"types"` at *any* depth,
/// and `"scripts": { "types": "tsc src/index.tsx --declaration …" }` is a
/// real, common shape. The build-script command line was then taken as the
/// declaration path, the package looked like it had a `types` field, and the
/// package's actual top-level `"typings"` was never reached — an unresolvable
/// package (TS2307) whose declarations were sitting right there.
///
/// Depth is tracked by counting braces/brackets outside strings; string
/// escapes are honored only well enough not to lose track of the quoting.
fn packageStringField(text: []const u8, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (packageRootStringField(text, key)) |v| return v;
    }
    return null;
}

/// One key's root-object lookup for `packageStringField`.
fn packageRootStringField(text: []const u8, key: []const u8) ?[]const u8 {
    const isWs = struct {
        fn f(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\r' or c == '\n';
        }
    }.f;
    var i: usize = 0;
    var depth: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '{', '[' => {
                depth += 1;
                i += 1;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                i += 1;
            },
            '"' => {
                const start = i;
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
                if (i >= text.len) return null;
                const tok = text[start .. i + 1];
                i += 1;
                if (depth != 1) continue; // not a key of the root object
                var j = i;
                while (j < text.len and isWs(text[j])) j += 1;
                if (j >= text.len or text[j] != ':') continue; // a value, not a key
                j += 1;
                while (j < text.len and isWs(text[j])) j += 1;
                if (!std.mem.eql(u8, tok, key)) {
                    i = j; // resume at the value (an object/array re-enters depth)
                    continue;
                }
                if (j >= text.len or text[j] != '"') return null; // present, not a string
                j += 1;
                const vstart = j;
                while (j < text.len and text[j] != '"') : (j += 1) {
                    if (text[j] == '\\') j += 1;
                }
                if (j >= text.len) return null;
                return text[vstart..j];
            },
            else => i += 1,
        }
    }
    return null;
}

/// `package.json` `"types"` / `"typings"` field (the declaration entry).
pub fn packageTypesField(text: []const u8) ?[]const u8 {
    return packageStringField(text, &.{ "\"types\"", "\"typings\"" });
}

/// `package.json` `"main"` field (the runtime JS entry), consulted only under
/// `allowJs` when a package ships no types.
pub fn packageMainField(text: []const u8) ?[]const u8 {
    return packageStringField(text, &.{"\"main\""});
}

// ---------------------------------------------------------------------------
// package.json "exports" map (bundler/Node16-style)
// ---------------------------------------------------------------------------

/// True if an `exports` object is a subpath map (keys begin with ".") rather
/// than a conditions object. Node forbids mixing the two, so the first key
/// decides.
pub fn exportsIsSubpathMap(obj: tsconfig.Value.Object) bool {
    return obj.keys.len > 0 and obj.keys[0].len > 0 and obj.keys[0][0] == '.';
}

/// A condition name active for type resolution under `moduleResolution:
/// bundler`. tsc resolves in import mode, so the on-set is {types, import}
/// plus the universal `default` fallback — verified via `--traceResolution`
/// ("Resolving ... with conditions 'import', 'types'"; "Saw non-matching
/// condition 'require'"). `require`/`module`/`node`/`browser` are inactive.
pub fn exportsConditionActive(key: []const u8) bool {
    return std.mem.eql(u8, key, "types") or
        std.mem.eql(u8, key, "import") or
        std.mem.eql(u8, key, "default");
}

/// The `exports` value of a `package.json` body, or null when it has none /
/// does not parse. Shared by the memoized and unmemoized legs so both read the
/// file exactly the same way.
pub fn exportsOf(alloc: Allocator, text: []const u8) ?tsconfig.Value {
    // An `exports` key means the nine bytes `"exports"` appear literally in the
    // text — unless the file uses string escapes at all, in which case the key
    // could be spelled `"exports"`. Backslash-free text (every real
    // `package.json`) therefore settles it without a parse: this skips the
    // parser for the majority of packages and, more importantly, keeps their
    // parse graphs out of the cache arena.
    if (std.mem.indexOfScalar(u8, text, '\\') == null and
        std.mem.indexOf(u8, text, "\"exports\"") == null) return null;
    const root = tsconfig.parseJsonc(alloc, text) catch return null;
    return switch (root) {
        .object => |ro| ro.get("exports"),
        else => null,
    };
}

/// The `imports` value of a `package.json` body — the "private imports" map a
/// `#specifier` resolves through — or null when it has none / does not parse.
/// Same literal-key screen as `exportsOf`, for the same reason: no parse (and
/// no parse graph in the cache arena) for a package that has no such map.
pub fn importsOf(alloc: Allocator, text: []const u8) ?tsconfig.Value {
    if (std.mem.indexOfScalar(u8, text, '\\') == null and
        std.mem.indexOf(u8, text, "\"imports\"") == null) return null;
    const root = tsconfig.parseJsonc(alloc, text) catch return null;
    return switch (root) {
        .object => |ro| ro.get("imports"),
        else => null,
    };
}

/// `package.json` `"name"` field — the package's own name, which it may use to
/// import itself (Node's "self-reference"; see `resolveSelfName`).
pub fn packageNameField(text: []const u8) ?[]const u8 {
    return packageStringField(text, &.{"\"name\""});
}

/// The TypeScript version ztsc answers `typesVersions` range keys as. It is the
/// version of the vendored lib and of the pinned oracle (tsgo 7.0.2), so a
/// package that ships a version-gated declaration set hands ztsc the same set it
/// hands the oracle.
const ts_version_major = 7;
const ts_version_minor = 0;

/// The `typesVersions` mapping (a `paths`-shaped object) that applies to this
/// compiler, or null when the `package.json` has no `typesVersions`, no version
/// key matches, or the shape is wrong.
///
/// `typesVersions` is the pre-`exports` way to ship a version-gated declaration
/// layout: `{ ">=4.0": { "*": ["dist/types/*"] } }`. tsc takes the FIRST version
/// key whose range matches and treats its value as a `paths` table rooted at the
/// package directory. Only the two range spellings real packages use are
/// understood — `*` and `>=<major>[.<minor>]` — and an unrecognized range simply
/// does not match, which is the safe direction: an unmapped package resolves
/// exactly as it did before `typesVersions` existed.
pub fn typesVersionsPaths(alloc: Allocator, text: []const u8) ?tsconfig.Value.Object {
    // Same backslash-free literal-key test as `exportsOf`: no parse for the
    // overwhelming majority of packages, which ship no `typesVersions` at all.
    if (std.mem.indexOfScalar(u8, text, '\\') == null and
        std.mem.indexOf(u8, text, "\"typesVersions\"") == null) return null;
    const root = tsconfig.parseJsonc(alloc, text) catch return null;
    if (root != .object) return null;
    const tv = root.object.get("typesVersions") orelse return null;
    if (tv != .object) return null;
    for (tv.object.keys, tv.object.vals) |range, map| {
        if (map != .object) continue;
        if (versionRangeMatches(range)) return map.object;
    }
    return null;
}

/// Does a `typesVersions` range key cover this compiler? `*` always does;
/// `>=X[.Y]` does when the compiler version is at least that. Anything else
/// (`<4.0`, a full semver range with operators) does not match — see
/// `typesVersionsPaths` for why that is the safe answer.
fn versionRangeMatches(range: []const u8) bool {
    const r = std.mem.trim(u8, range, " ");
    if (std.mem.eql(u8, r, "*")) return true;
    if (!std.mem.startsWith(u8, r, ">=")) return false;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, r[2..], " "), '.');
    const major = std.fmt.parseInt(u32, it.first(), 10) catch return false;
    const minor: u32 = if (it.next()) |m| (std.fmt.parseInt(u32, m, 10) catch 0) else 0;
    if (ts_version_major != major) return ts_version_major > major;
    return ts_version_minor >= minor;
}

/// Map `sub` (a package-relative module name — `"server/mcp.js"`, or the
/// package's own entry file name for a root import) through a `typesVersions`
/// table. Same rule as tsconfig `paths`: an exact key wins, else the `*` pattern
/// with the longest matched prefix; the capture is substituted into each target.
/// Returns the targets in order (package-relative, `alloc`-owned), or an empty
/// slice when no key matches.
pub fn mapTypesVersions(alloc: Allocator, obj: tsconfig.Value.Object, sub: []const u8) Error![]const []const u8 {
    var exact: ?usize = null;
    var best: ?usize = null;
    var best_prefix: usize = 0;
    for (obj.keys, 0..) |key, i| {
        if (std.mem.indexOfScalar(u8, key, '*')) |star| {
            const prefix = key[0..star];
            const suffix = key[star + 1 ..];
            if (sub.len >= prefix.len + suffix.len and
                std.mem.startsWith(u8, sub, prefix) and
                std.mem.endsWith(u8, sub, suffix))
            {
                if (best == null or prefix.len > best_prefix) {
                    best = i;
                    best_prefix = prefix.len;
                }
            }
        } else if (std.mem.eql(u8, key, sub)) {
            exact = i;
        }
    }
    const idx = exact orelse (best orelse return &.{});
    const key = obj.keys[idx];
    if (obj.vals[idx] != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (obj.vals[idx].array) |t| {
        if (t != .string) continue;
        var target: []const u8 = t.string;
        if (exact == null) {
            const star = std.mem.indexOfScalar(u8, key, '*').?;
            const captured = sub[star .. sub.len - (key.len - star - 1)];
            if (std.mem.indexOfScalar(u8, t.string, '*')) |vstar| {
                target = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
                    t.string[0..vstar], captured, t.string[vstar + 1 ..],
                });
            }
        }
        try out.append(alloc, target);
    }
    return out.toOwnedSlice(alloc);
}

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

const testing = std.testing;

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

test "packageTypesField: only root-object keys count" {
    // A `types` *script* is not a declaration entry; the root `typings` is.
    try testing.expectEqualStrings("./lib/index.d.ts", packageTypesField(
        \\{ "name": "p", "typings": "./lib/index.d.ts",
        \\  "scripts": { "types": "tsc src/index.tsx --declaration" } }
    ).?);
    // Nested-only: nothing at the root, so nothing resolves.
    try testing.expectEqual(@as(?[]const u8, null), packageTypesField(
        \\{ "name": "p", "scripts": { "types": "tsc --declaration" } }
    ));
    // The nesting may be an array of objects, and a *value* that looks like a
    // key must not be mistaken for one.
    try testing.expectEqualStrings("d/i.d.ts", packageTypesField(
        \\{ "contributors": [ { "types": "nope" } ], "note": "\"types\":",
        \\  "types": "d/i.d.ts" }
    ).?);
    // `types` outranks `typings` regardless of which comes first in the file.
    try testing.expectEqualStrings("a.d.ts", packageTypesField(
        \\{ "typings": "b.d.ts", "types": "a.d.ts" }
    ).?);
    try testing.expectEqualStrings("./lib/index.js", packageMainField(
        \\{ "main": "./lib/index.js", "scripts": { "main": "node ." } }
    ).?);
}

test "packageMainField: minimal scan" {
    try testing.expectEqualStrings("lib/index.js", packageMainField(
        \\{ "name": "qs", "main": "lib/index.js" }
    ).?);
    try testing.expectEqual(@as(?[]const u8, null), packageMainField(
        \\{ "name": "p", "types": "index.d.ts" }
    ));
}

test "versionRangeMatches: the two spellings real packages ship" {
    try testing.expect(versionRangeMatches("*"));
    try testing.expect(versionRangeMatches(">=4.0"));
    try testing.expect(versionRangeMatches(">=3.1"));
    try testing.expect(versionRangeMatches(">=7"));
    try testing.expect(versionRangeMatches(">=7.0"));
    try testing.expect(!versionRangeMatches(">=7.1"));
    try testing.expect(!versionRangeMatches(">=8.0"));
    // Unrecognized spellings do not match (the pre-`typesVersions` answer).
    try testing.expect(!versionRangeMatches("<4.0"));
    try testing.expect(!versionRangeMatches("4.0"));
    try testing.expect(!versionRangeMatches(">=abc"));
}
