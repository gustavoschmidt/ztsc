//! Pure glob matching for `include`/`exclude` patterns.
//!
//! The matcher tsc's `include`/`exclude` regexes compile down to, spelled as a
//! recursive segment walk instead: `**` matches zero or more whole segments,
//! `*` any run of non-`/` characters, `?` exactly one non-`/` character, and no
//! wildcard ever matches a leading `.`. Every comparison takes the filesystem's
//! case rule as a parameter (`cs`), which is what tsc's `i` regex flag is.
//!
//! Everything here is pure: no allocator, no `Io`, no filesystem. The walk that
//! *uses* it — deciding what to open, what to prune, and which patterns are the
//! project's — lives in `tsconfig.zig`, which is where the policy belongs.

const std = @import("std");

// ===========================================================================
// pattern matching
// ===========================================================================

/// Match a glob `pattern` against a `/`-separated `path` (both lexically
/// normalized, no leading `./`, either both relative or both rooted). `**`
/// matches zero or more whole segments, `*` any run of non-`/` characters, `?`
/// exactly one non-`/` character. Wildcards never match a leading `.` of a
/// segment.
///
/// `case_sensitive` is the filesystem's, not a style choice: tsc and tsgo
/// compile these patterns to a regex and add the `i` flag whenever the host
/// reports case-insensitive file names, so on macOS/Windows `exclude: ["OUT"]`
/// really does exclude `out/`. Segment structure (`/`, the dot-segment rule)
/// is case-independent either way.
pub fn globMatch(case_sensitive: bool, pattern: []const u8, path: []const u8) bool {
    return matchParts(case_sensitive, pattern, path);
}

const Split = struct { head: []const u8, tail: ?[]const u8 };

fn splitSeg(s: []const u8) Split {
    if (std.mem.indexOfScalar(u8, s, '/')) |i| {
        return .{ .head = s[0..i], .tail = s[i + 1 ..] };
    }
    return .{ .head = s, .tail = null };
}

fn matchParts(cs: bool, pat: ?[]const u8, path: ?[]const u8) bool {
    const p = pat orelse return path == null;
    const sp = splitSeg(p);
    if (std.mem.eql(u8, sp.head, "**")) {
        // Zero segments...
        if (matchParts(cs, sp.tail, path)) return true;
        // ...or eat one path segment and retry (never a dot-segment).
        const t = path orelse return false;
        const st = splitSeg(t);
        if (st.head.len > 0 and st.head[0] == '.') return false;
        return matchParts(cs, p, st.tail);
    }
    const t = path orelse return false;
    const st = splitSeg(t);
    if (!segMatch(cs, sp.head, st.head)) return false;
    return matchParts(cs, sp.tail, st.tail);
}

/// Case-fold one byte the way tsc's `i` regex flag does: ASCII only. tsc
/// canonicalizes with `String.prototype.toLowerCase` restricted to ASCII
/// (`toFileNameLowerCase`), precisely so a locale never moves a file in or out
/// of a program.
fn foldEq(cs: bool, a: u8, b: u8) bool {
    if (a == b) return true;
    if (cs) return false;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Match one path segment (no `/`) against a pattern segment with `*`/`?`.
fn segMatch(cs: bool, pat: []const u8, name: []const u8) bool {
    // A leading '.' must be matched literally (tsc: wildcards skip
    // dotfiles).
    if (name.len > 0 and name[0] == '.' and pat.len > 0 and
        (pat[0] == '*' or pat[0] == '?')) return false;

    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;
    while (ni < name.len) {
        if (pi < pat.len and (pat[pi] == '?' or foldEq(cs, pat[pi], name[ni]))) {
            pi += 1;
            ni += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            pi += 1;
            star_ni = ni;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// ===========================================================================
// path predicates
// ===========================================================================

/// True for a pattern (or path) rooted at the filesystem root rather than at
/// the walk's base directory. tsc keeps both patterns and walked paths
/// absolute, so the two spaces mix freely there; ztsc walks base-relative for
/// the memory, and this is the flag that says which space a string is in.
pub fn isRooted(s: []const u8) bool {
    return s.len > 0 and s[0] == '/';
}

pub fn eqlPath(cs: bool, a: []const u8, b: []const u8) bool {
    if (cs) return std.mem.eql(u8, a, b);
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn startsWithPath(cs: bool, haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and eqlPath(cs, haystack[0..needle.len], needle);
}

/// The leading whole segments of an include pattern that contain no `*`/`?` —
/// the part tsc matches literally rather than by wildcard. `"src/**/*"` -> `src`,
/// `"node_modules/typed/**/*"` -> `node_modules/typed`, `"src/*/index.ts"` ->
/// `src`, `"**/*"` -> `""` (the walk root itself, and nothing under it).
pub fn literalPrefix(pat: []const u8) []const u8 {
    var end: usize = 0;
    var i: usize = 0;
    while (i < pat.len) {
        const seg_end = std.mem.indexOfScalarPos(u8, pat, i, '/') orelse pat.len;
        if (std.mem.indexOfAny(u8, pat[i..seg_end], "*?") != null) break;
        end = seg_end;
        i = seg_end + 1;
    }
    return pat[0..end];
}

/// Is the directory `<cur>/<name>` an ancestor of `path`, or `path` itself?
/// Whole-segment (`src` does not cover `srcx`), and spelled on the unjoined
/// parts so the caller need not build the child path to ask. Either part may be
/// empty (the caller that has already joined passes the whole directory as
/// `cur`). Case follows the filesystem, like every other comparison the walk
/// makes.
pub fn dirCoversPath(cs: bool, cur: []const u8, name: []const u8, path: []const u8) bool {
    var rest = path;
    if (cur.len != 0) {
        if (!startsWithPath(cs, rest, cur)) return false;
        if (rest.len == cur.len) return name.len == 0;
        if (rest[cur.len] != '/') return false;
        rest = rest[cur.len + 1 ..];
    }
    if (name.len == 0) return true;
    if (!startsWithPath(cs, rest, name)) return false;
    return rest.len == name.len or rest[name.len] == '/';
}

// ===========================================================================
// coordinate space
// ===========================================================================

/// The rules a walked path is matched under: the filesystem's case sensitivity
/// and the base directory's own absolute path.
///
/// `base_abs` exists so a *rooted* pattern is not dead on arrival. The walk
/// names files relative to the base directory, so an `exclude` (or an `outDir`)
/// spelled `/home/me/proj/out` shares no prefix with `proj/out` and could never
/// match; tsc has no such gap because it walks absolute. Rather than rebasing
/// the pattern — which cannot be done lexically once a wildcard sits above the
/// project (`/home/*/proj/out`) — the walked path is lifted into the pattern's
/// space, and only for the patterns that ask for it. Everything stays
/// base-relative on the common path, where no pattern is rooted at all.
pub const Matcher = struct {
    /// The walk's filesystem, as probed by `tsconfig.caseSensitiveFs`.
    case_sensitive: bool,
    /// Canonical absolute path of the base directory, no trailing `/`
    /// ("" = unknown, which leaves rooted patterns inert as they were).
    base_abs: []const u8,
    /// Scratch for the lifted path; rewritten on every `rooted*` call and only
    /// ever read before the next one.
    buf: [std.fs.max_path_bytes]u8 = undefined,

    /// `<base_abs>/<cur>/<name>` (any empty part elided), or null when it does
    /// not fit / the base is unknown. Already-rooted input passes through: a
    /// config named by an absolute `--project` path makes the whole walk
    /// absolute, and lifting it twice would be nonsense.
    pub fn rooted(m: *Matcher, cur: []const u8, name: []const u8) ?[]const u8 {
        if (isRooted(cur) or (cur.len == 0 and isRooted(name))) {
            if (cur.len == 0) return name;
            if (name.len == 0) return cur;
            return m.write(&.{ cur, name });
        }
        if (m.base_abs.len == 0) return null;
        return m.write(&.{ m.base_abs, cur, name });
    }

    fn write(m: *Matcher, parts: []const []const u8) ?[]const u8 {
        var n: usize = 0;
        for (parts) |p| {
            if (p.len == 0) continue;
            if (n != 0 and m.buf[n - 1] != '/') {
                if (n + 1 > m.buf.len) return null;
                m.buf[n] = '/';
                n += 1;
            }
            if (n + p.len > m.buf.len) return null;
            @memcpy(m.buf[n..][0..p.len], p);
            n += p.len;
        }
        return m.buf[0..n];
    }
};

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

test "globMatch: subset semantics" {
    const T = struct { pat: []const u8, path: []const u8, want: bool, cs: bool = true };
    const cases = [_]T{
        .{ .pat = "**/*", .path = "a.ts", .want = true },
        .{ .pat = "**/*", .path = "x/y/a.ts", .want = true },
        .{ .pat = "*", .path = "a.ts", .want = true },
        .{ .pat = "*", .path = "x/a.ts", .want = false },
        .{ .pat = "src/**/*", .path = "src/a.ts", .want = true },
        .{ .pat = "src/**/*", .path = "src/x/y/a.ts", .want = true },
        .{ .pat = "src/**/*", .path = "srcx/a.ts", .want = false },
        .{ .pat = "src/**/*", .path = "src", .want = false },
        .{ .pat = "src/**", .path = "src", .want = true },
        .{ .pat = "src/**", .path = "src/x/a.ts", .want = true },
        .{ .pat = "**/*.spec.ts", .path = "x/a.spec.ts", .want = true },
        .{ .pat = "**/*.spec.ts", .path = "a.spec.ts", .want = true },
        .{ .pat = "**/*.spec.ts", .path = "a.ts", .want = false },
        .{ .pat = "a/*/c.ts", .path = "a/b/c.ts", .want = true },
        .{ .pat = "a/*/c.ts", .path = "a/b/x/c.ts", .want = false },
        .{ .pat = "a?.ts", .path = "ab.ts", .want = true },
        .{ .pat = "a?.ts", .path = "abc.ts", .want = false },
        .{ .pat = "a?.ts", .path = "a.ts", .want = false },
        .{ .pat = "f*e.ts", .path = "fe.ts", .want = true },
        .{ .pat = "f*e.ts", .path = "fxyze.ts", .want = true },
        .{ .pat = "f*e.ts", .path = "fxyz.ts", .want = false },
        .{ .pat = "**/x/**/*.ts", .path = "a/x/b/c.ts", .want = true },
        .{ .pat = "**/x/**/*.ts", .path = "a/y/b/c.ts", .want = false },
        // Wildcards must not match dotfiles / dot-dirs.
        .{ .pat = "*", .path = ".hidden.ts", .want = false },
        .{ .pat = "**/*", .path = ".git/a.ts", .want = false },
        .{ .pat = ".*", .path = ".hidden.ts", .want = true },
        .{ .pat = "node_modules", .path = "node_modules", .want = true },
        .{ .pat = "node_modules", .path = "src/node_modules", .want = false },
        .{ .pat = "**/node_modules", .path = "src/node_modules", .want = true },
        // Rooted patterns are matched exactly like relative ones — the caller
        // is what lifts a walked path into their space.
        .{ .pat = "/a/b/out/**/*", .path = "/a/b/out/x.ts", .want = true },
        .{ .pat = "/a/b/out", .path = "/a/b/output/x.ts", .want = false },
        .{ .pat = "/a/*/out/**/*", .path = "/a/b/out/x.ts", .want = true },
        // Case: exact under `cs`, folded (ASCII only) without it.
        .{ .pat = "OUT/**/*", .path = "out/x.ts", .want = false },
        .{ .pat = "OUT/**/*", .path = "out/x.ts", .want = true, .cs = false },
        .{ .pat = "**/*.D.TS", .path = "a/b.d.ts", .want = true, .cs = false },
        .{ .pat = "/A/B/out", .path = "/a/b/out", .want = true, .cs = false },
        .{ .pat = "src", .path = "srC", .want = true, .cs = false },
        .{ .pat = "src", .path = "srcx", .want = false, .cs = false },
        // Folding is ASCII-only, like tsc's `toFileNameLowerCase`: a non-ASCII
        // byte pair that some locale would equate stays distinct.
        .{ .pat = "É.ts", .path = "é.ts", .want = false, .cs = false },
    };
    for (cases) |c| {
        if (globMatch(c.cs, c.pat, c.path) != c.want) {
            std.debug.print("globMatch({}, {s}, {s}) != {}\n", .{ c.cs, c.pat, c.path, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "literalPrefix: leading wildcard-free segments" {
    try testing.expectEqualStrings("", literalPrefix("**/*"));
    try testing.expectEqualStrings("", literalPrefix("*/index.ts"));
    try testing.expectEqualStrings("src", literalPrefix("src/**/*"));
    try testing.expectEqualStrings("src", literalPrefix("src/*/index.ts"));
    try testing.expectEqualStrings("src", literalPrefix("src/a?.ts"));
    try testing.expectEqualStrings("node_modules/typed", literalPrefix("node_modules/typed/**/*"));
    // No wildcard anywhere: the whole pattern is literal.
    try testing.expectEqualStrings("src/a.ts", literalPrefix("src/a.ts"));
}

test "dirCoversPath: whole-segment ancestor-or-self, unjoined" {
    try testing.expect(dirCoversPath(true, "", "node_modules", "node_modules"));
    try testing.expect(dirCoversPath(true, "", "node_modules", "node_modules/typed"));
    try testing.expect(dirCoversPath(true, "node_modules", "typed", "node_modules/typed"));
    try testing.expect(!dirCoversPath(true, "node_modules", "typed", "node_modules"));
    try testing.expect(!dirCoversPath(true, "src/deep", "node_modules", "src"));
    // Whole segments only.
    try testing.expect(!dirCoversPath(true, "", "src", "srcx/a"));
    try testing.expect(!dirCoversPath(true, "", "node_modules", "my_node_modules"));
}
