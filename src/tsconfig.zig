//! tsconfig.json subset (M6).
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
//!   neither `files` nor `include` is present) is `**/*`; default excludes
//!   are `node_modules`, `bower_components`, `jspm_packages`.
//! - **compilerOptions**:
//!   - `strict` must be `true` or absent — ztsc only implements strict
//!     semantics, so `strict: false` is a polite hard error (exit 2).
//!   - `noEmit` is ignored (ztsc never emits).
//!   - `target` / `module` / `moduleResolution` are accepted and ignored
//!     (surfaced as notes under `--verbose`): ztsc always checks its fixed
//!     esnext/bundler-resolution subset.
//!   - `baseUrl` + `paths`: minimal support — exact keys and single-`*`
//!     patterns mapped to relative directories; feeds module resolution
//!     (tsc rule: exact match wins, else the pattern with the longest
//!     matched prefix).
//!   - `lib` selects the built-in lib blobs (es-core + dom); the list
//!     replaces the default set (tsc semantics). Recognized families: `es*`
//!     (the ES-core blob) and `dom*` (the DOM blob); others warn + ignore.
//!     Absent `lib` = the default set (ES-core + DOM, matching tsgo).
//!   - `types` is ignored (ztsc resolves @types via imports/references).
//!   - Anything else warns and is ignored — unknown options never fail.
//! - Unknown top-level keys (incl. `extends`, `references`) warn + ignore.
//!
//! Discovery: with no file arguments, the CLI looks for `tsconfig.json` in
//! the current directory and then each parent (`findUpward`), or uses the
//! `--project/-p` path. All paths produced here are relative to the base
//! directory the config was loaded through (the cwd in production).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const modules = @import("modules.zig");

pub const Error = error{OutOfMemory};

// ===========================================================================
// JSONC value parser
// ===========================================================================

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: Object,

    pub const Object = struct {
        keys: []const []const u8 = &.{},
        vals: []const Value = &.{},

        pub fn get(o: Object, key: []const u8) ?Value {
            for (o.keys, o.vals) |k, v| {
                if (std.mem.eql(u8, k, key)) return v;
            }
            return null;
        }
    };
};

pub const JsonError = error{ SyntaxError, OutOfMemory };

/// Parse JSONC (JSON + comments + trailing commas) into an arena-backed
/// `Value`. Strings are unescaped copies.
pub fn parseJsonc(arena: Allocator, text: []const u8) JsonError!Value {
    var p: JsonParser = .{ .arena = arena, .text = text };
    p.skipWs();
    const v = try p.parseValue(0);
    p.skipWs();
    if (p.pos != p.text.len) return error.SyntaxError;
    return v;
}

const JsonParser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,

    const max_depth = 64;

    fn skipWs(p: *JsonParser) void {
        while (p.pos < p.text.len) {
            const c = p.text[p.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => p.pos += 1,
                '/' => {
                    if (p.pos + 1 >= p.text.len) return;
                    switch (p.text[p.pos + 1]) {
                        '/' => {
                            p.pos += 2;
                            while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
                        },
                        '*' => {
                            p.pos += 2;
                            while (p.pos + 1 < p.text.len and
                                !(p.text[p.pos] == '*' and p.text[p.pos + 1] == '/')) p.pos += 1;
                            p.pos = @min(p.pos + 2, p.text.len);
                        },
                        else => return,
                    }
                },
                else => return,
            }
        }
    }

    fn parseValue(p: *JsonParser, depth: u32) JsonError!Value {
        if (depth > max_depth) return error.SyntaxError;
        if (p.pos >= p.text.len) return error.SyntaxError;
        switch (p.text[p.pos]) {
            '{' => return p.parseObject(depth),
            '[' => return p.parseArray(depth),
            '"' => return .{ .string = try p.parseString() },
            't' => {
                try p.expectWord("true");
                return .{ .boolean = true };
            },
            'f' => {
                try p.expectWord("false");
                return .{ .boolean = false };
            },
            'n' => {
                try p.expectWord("null");
                return .null;
            },
            '-', '0'...'9' => return .{ .number = try p.parseNumber() },
            else => return error.SyntaxError,
        }
    }

    fn expectWord(p: *JsonParser, word: []const u8) JsonError!void {
        if (p.pos + word.len > p.text.len) return error.SyntaxError;
        if (!std.mem.eql(u8, p.text[p.pos..][0..word.len], word)) return error.SyntaxError;
        p.pos += word.len;
    }

    fn parseNumber(p: *JsonParser) JsonError!f64 {
        const start = p.pos;
        if (p.pos < p.text.len and p.text[p.pos] == '-') p.pos += 1;
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        return std.fmt.parseFloat(f64, p.text[start..p.pos]) catch error.SyntaxError;
    }

    fn parseString(p: *JsonParser) JsonError![]const u8 {
        std.debug.assert(p.text[p.pos] == '"');
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= p.text.len) return error.SyntaxError;
            const c = p.text[p.pos];
            if (c == '"') {
                p.pos += 1;
                return out.toOwnedSlice(p.arena);
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.pos >= p.text.len) return error.SyntaxError;
                const e = p.text[p.pos];
                p.pos += 1;
                switch (e) {
                    '"', '\\', '/' => try out.append(p.arena, e),
                    'b' => try out.append(p.arena, 8),
                    'f' => try out.append(p.arena, 12),
                    'n' => try out.append(p.arena, '\n'),
                    'r' => try out.append(p.arena, '\r'),
                    't' => try out.append(p.arena, '\t'),
                    'u' => {
                        if (p.pos + 4 > p.text.len) return error.SyntaxError;
                        const cp = std.fmt.parseInt(u16, p.text[p.pos..][0..4], 16) catch
                            return error.SyntaxError;
                        p.pos += 4;
                        var buf: [4]u8 = undefined;
                        // Lone surrogates encode as U+FFFD (config files
                        // don't need astral-plane fidelity).
                        const n = std.unicode.utf8Encode(cp, &buf) catch
                            std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                        try out.appendSlice(p.arena, buf[0..n]);
                    },
                    else => return error.SyntaxError,
                }
                continue;
            }
            try out.append(p.arena, c);
            p.pos += 1;
        }
    }

    fn parseArray(p: *JsonParser, depth: u32) JsonError!Value {
        p.pos += 1; // '['
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            if (p.text[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            try items.append(p.arena, try p.parseValue(depth + 1));
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            switch (p.text[p.pos]) {
                ',' => p.pos += 1, // trailing comma allowed: loop re-checks ']'
                ']' => {},
                else => return error.SyntaxError,
            }
        }
        return .{ .array = try items.toOwnedSlice(p.arena) };
    }

    fn parseObject(p: *JsonParser, depth: u32) JsonError!Value {
        p.pos += 1; // '{'
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            if (p.text[p.pos] == '}') {
                p.pos += 1;
                break;
            }
            if (p.text[p.pos] != '"') return error.SyntaxError;
            const key = try p.parseString();
            p.skipWs();
            if (p.pos >= p.text.len or p.text[p.pos] != ':') return error.SyntaxError;
            p.pos += 1;
            p.skipWs();
            try keys.append(p.arena, key);
            try vals.append(p.arena, try p.parseValue(depth + 1));
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            switch (p.text[p.pos]) {
                ',' => p.pos += 1,
                '}' => {},
                else => return error.SyntaxError,
            }
        }
        return .{ .object = .{
            .keys = try keys.toOwnedSlice(p.arena),
            .vals = try vals.toOwnedSlice(p.arena),
        } };
    }
};

// ===========================================================================
// glob matcher
// ===========================================================================

/// Match a glob `pattern` against a `/`-separated relative `path` (both
/// lexically normalized, no leading `./`). `**` matches zero or more whole
/// segments, `*` any run of non-`/` characters, `?` exactly one non-`/`
/// character. Wildcards never match a leading `.` of a segment.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return matchParts(pattern, path);
}

const Split = struct { head: []const u8, tail: ?[]const u8 };

fn splitSeg(s: []const u8) Split {
    if (std.mem.indexOfScalar(u8, s, '/')) |i| {
        return .{ .head = s[0..i], .tail = s[i + 1 ..] };
    }
    return .{ .head = s, .tail = null };
}

fn matchParts(pat: ?[]const u8, path: ?[]const u8) bool {
    const p = pat orelse return path == null;
    const sp = splitSeg(p);
    if (std.mem.eql(u8, sp.head, "**")) {
        // Zero segments...
        if (matchParts(sp.tail, path)) return true;
        // ...or eat one path segment and retry (never a dot-segment).
        const t = path orelse return false;
        const st = splitSeg(t);
        if (st.head.len > 0 and st.head[0] == '.') return false;
        return matchParts(p, st.tail);
    }
    const t = path orelse return false;
    const st = splitSeg(t);
    if (!segMatch(sp.head, st.head)) return false;
    return matchParts(sp.tail, st.tail);
}

/// Match one path segment (no `/`) against a pattern segment with `*`/`?`.
fn segMatch(pat: []const u8, name: []const u8) bool {
    // A leading '.' must be matched literally (tsc: wildcards skip
    // dotfiles).
    if (name.len > 0 and name[0] == '.' and pat.len > 0 and
        (pat[0] == '*' or pat[0] == '?')) return false;

    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;
    while (ni < name.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == name[ni])) {
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
// config
// ===========================================================================

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

pub const Config = struct {
    /// Path of the tsconfig.json that was loaded (base-relative).
    path: []const u8,
    /// Its directory ("" = the base directory itself), base-relative.
    dir: []const u8,
    /// Expanded root files: `files` entries first (in order), then
    /// include-matched files sorted by path; deduplicated.
    root_files: []const []const u8 = &.{},
    /// `paths`/`baseUrl` mapping for module resolution, if configured.
    paths: ?Paths = null,
    /// `compilerOptions.lib` entries (as written), or null when the field is
    /// absent. Fed to `modules.resolveLibSet` to pick the built-in lib blobs;
    /// null selects the default set (ES-core + DOM, matching tsgo).
    lib: ?[]const []const u8 = null,
    /// Non-fatal warnings (unknown options, bad shapes) for stderr.
    warnings: []const []const u8 = &.{},
    /// Accepted-and-ignored option notes, shown under --verbose only.
    notes: []const []const u8 = &.{},
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

/// Load and expand `config_path` through the cwd.
pub fn load(io: Io, arena: Allocator, config_path: []const u8) LoadError!Config {
    return loadInDir(io, arena, Io.Dir.cwd(), config_path);
}

/// Load `config_path` (relative to `base`), parse it, and expand its
/// file list. All returned paths are relative to `base`.
pub fn loadInDir(io: Io, arena: Allocator, base: Io.Dir, config_path: []const u8) LoadError!Config {
    const text = base.readFileAlloc(io, config_path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    const root = parseJsonc(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return error.SyntaxError,
    };
    if (root != .object) return error.SyntaxError;

    var cfg: Config = .{
        .path = config_path,
        .dir = modules.dirnamePart(config_path),
    };
    var warnings: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;

    var files: ?[]const []const u8 = null;
    var include: ?[]const []const u8 = null;
    var exclude: []const []const u8 = &default_excludes;
    var base_url: []const u8 = ".";
    var paths_obj: ?Value.Object = null;

    for (root.object.keys, root.object.vals) |key, val| {
        if (std.mem.eql(u8, key, "files")) {
            files = try stringArray(arena, &warnings, config_path, key, val);
        } else if (std.mem.eql(u8, key, "include")) {
            include = try stringArray(arena, &warnings, config_path, key, val);
        } else if (std.mem.eql(u8, key, "exclude")) {
            if (try stringArray(arena, &warnings, config_path, key, val)) |pats| exclude = pats;
        } else if (std.mem.eql(u8, key, "compilerOptions")) {
            if (val != .object) {
                try warn(arena, &warnings, "{s}: 'compilerOptions' must be an object (ignored)", .{config_path});
                continue;
            }
            for (val.object.keys, val.object.vals) |okey, oval| {
                if (std.mem.eql(u8, okey, "strict")) {
                    if (oval == .boolean and !oval.boolean) return error.StrictFalse;
                    if (oval != .boolean) {
                        try warn(arena, &warnings, "{s}: 'strict' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noEmit")) {
                    try note(arena, &notes, "{s}: 'noEmit' ignored (ztsc never emits)", .{config_path});
                } else if (std.mem.eql(u8, okey, "target") or
                    std.mem.eql(u8, okey, "module") or
                    std.mem.eql(u8, okey, "moduleResolution"))
                {
                    try note(arena, &notes, "{s}: '{s}' accepted and ignored (ztsc always checks its fixed esnext/bundler subset)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "jsx") or
                    std.mem.eql(u8, okey, "jsxImportSource") or
                    std.mem.eql(u8, okey, "jsxFactory") or
                    std.mem.eql(u8, okey, "jsxFragmentFactory"))
                {
                    try note(arena, &notes, "{s}: '{s}' accepted and ignored (ztsc type-checks JSX via the ambient/global `JSX` namespace; it never emits)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "lib")) {
                    if (try stringArray(arena, &warnings, config_path, okey, oval)) |libs| {
                        cfg.lib = libs;
                        for (libs) |name| {
                            if (!std.ascii.startsWithIgnoreCase(name, "es") and
                                !std.ascii.startsWithIgnoreCase(name, "dom"))
                            {
                                try note(arena, &notes, "{s}: lib '{s}' is out of subset (ignored; ztsc ships es-core + dom)", .{ config_path, name });
                            }
                        }
                    }
                } else if (std.mem.eql(u8, okey, "types")) {
                    try note(arena, &notes, "{s}: 'types' ignored (ztsc resolves @types via imports/references)", .{config_path});
                } else if (std.mem.eql(u8, okey, "skipLibCheck") or std.mem.eql(u8, okey, "skipDefaultLibCheck")) {
                    try note(arena, &notes, "{s}: '{s}' accepted ({s}the built-in lib is never re-checked; dependency .d.ts files are still checked)", .{
                        config_path, okey, if (std.mem.eql(u8, okey, "skipLibCheck")) "partially honored: " else "already the default: ",
                    });
                } else if (std.mem.eql(u8, okey, "baseUrl")) {
                    if (oval == .string) {
                        base_url = oval.string;
                    } else {
                        try warn(arena, &warnings, "{s}: 'baseUrl' must be a string (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "paths")) {
                    if (oval == .object) {
                        paths_obj = oval.object;
                    } else {
                        try warn(arena, &warnings, "{s}: 'paths' must be an object (ignored)", .{config_path});
                    }
                } else {
                    try warn(arena, &warnings, "{s}: unknown compiler option '{s}' (ignored)", .{ config_path, okey });
                }
            }
        } else if (std.mem.eql(u8, key, "extends")) {
            try warn(arena, &warnings, "{s}: 'extends' is not yet supported by ztsc (ignored)", .{config_path});
        } else {
            try warn(arena, &warnings, "{s}: unknown option '{s}' (ignored)", .{ config_path, key });
        }
    }

    // Build the paths map (validate: at most one '*' per key and value).
    if (paths_obj) |po| {
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList([]const []const u8) = .empty;
        for (po.keys, po.vals) |pkey, pval| {
            if (std.mem.count(u8, pkey, "*") > 1) {
                try warn(arena, &warnings, "{s}: paths pattern '{s}' has more than one '*' (ignored)", .{ config_path, pkey });
                continue;
            }
            if (pval != .array) {
                try warn(arena, &warnings, "{s}: paths entry '{s}' must be an array (ignored)", .{ config_path, pkey });
                continue;
            }
            var targets: std.ArrayList([]const u8) = .empty;
            for (pval.array) |t| {
                if (t != .string or std.mem.count(u8, t.string, "*") > 1) {
                    try warn(arena, &warnings, "{s}: bad substitution in paths entry '{s}' (skipped)", .{ config_path, pkey });
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
                .base = try joinNormalize(arena, cfg.dir, base_url),
            };
        }
    }

    // Expand the root file set.
    var root_files: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    if (files) |list| {
        for (list) |f| {
            const joined = try joinNormalize(arena, cfg.dir, f);
            const gop = try seen.getOrPut(arena, joined);
            if (!gop.found_existing) try root_files.append(arena, joined);
        }
    }
    // tsc: `include` defaults to everything only when `files` is absent.
    const include_pats: []const []const u8 = include orelse
        (if (files == null) &default_include else &.{});
    if (include_pats.len > 0) {
        const matched = try expandInclude(io, arena, base, cfg.dir, include_pats, exclude, &warnings, config_path);
        for (matched) |m| {
            const gop = try seen.getOrPut(arena, m);
            if (!gop.found_existing) try root_files.append(arena, m);
        }
    }

    cfg.root_files = try root_files.toOwnedSlice(arena);
    cfg.warnings = try warnings.toOwnedSlice(arena);
    cfg.notes = try notes.toOwnedSlice(arena);
    return cfg;
}

const default_include = [_][]const u8{"**/*"};
const default_excludes = [_][]const u8{ "node_modules", "bower_components", "jspm_packages" };

fn warn(arena: Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) Error!void {
    try list.append(arena, try std.fmt.allocPrint(arena, fmt, args));
}

const note = warn;

fn stringArray(
    arena: Allocator,
    warnings: *std.ArrayList([]const u8),
    config_path: []const u8,
    key: []const u8,
    val: Value,
) Error!?[]const []const u8 {
    if (val != .array) {
        try warn(arena, warnings, "{s}: '{s}' must be an array of strings (ignored)", .{ config_path, key });
        return null;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (val.array) |item| {
        if (item != .string) {
            try warn(arena, warnings, "{s}: non-string entry in '{s}' (skipped)", .{ config_path, key });
            continue;
        }
        try out.append(arena, item.string);
    }
    return try out.toOwnedSlice(arena);
}

fn joinNormalize(arena: Allocator, dir: []const u8, rest: []const u8) Error![]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".") or rest.len > 0 and rest[0] == '/') {
        return modules.normalizePath(arena, rest);
    }
    const joined = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, rest });
    defer arena.free(joined);
    return modules.normalizePath(arena, joined);
}

/// Preprocess an include pattern: normalize, and treat a directory-looking
/// pattern (last segment without wildcard or extension) as `p/**/*`.
fn preprocessInclude(arena: Allocator, pat: []const u8) Error![]const u8 {
    const norm = try modules.normalizePath(arena, pat);
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

/// Walk the config directory collecting `.ts`/`.d.ts` files matching any
/// include pattern and excluded by none. Returned paths are base-relative
/// (config dir prefix included) and sorted.
fn expandInclude(
    io: Io,
    arena: Allocator,
    base: Io.Dir,
    dir: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    warnings: *std.ArrayList([]const u8),
    config_path: []const u8,
) Error![]const []const u8 {
    var inc_pats: std.ArrayList([]const u8) = .empty;
    for (include) |p| try inc_pats.append(arena, try preprocessInclude(arena, p));
    var exc_pats: std.ArrayList([]const u8) = .empty;
    for (exclude) |p| try exc_pats.append(arena, try modules.normalizePath(arena, p));

    var out: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, "");

    while (stack.pop()) |rel| {
        const open_path = if (rel.len == 0)
            (if (dir.len == 0) "." else dir)
        else
            try joinNormalize(arena, dir, rel);
        var d = base.openDir(io, open_path, .{ .iterate = true }) catch {
            if (rel.len == 0) {
                try warn(arena, warnings, "{s}: cannot open directory '{s}'", .{ config_path, open_path });
            }
            continue;
        };
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const child = if (rel.len == 0)
                try arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
            switch (entry.kind) {
                .directory => {
                    if (!matchesAny(exc_pats.items, child)) try stack.append(arena, child);
                },
                .file => {
                    if (!hasTsExt(child)) continue;
                    if (matchesAny(exc_pats.items, child)) continue;
                    if (!matchesAny(inc_pats.items, child)) continue;
                    try out.append(arena, try joinNormalize(arena, dir, child));
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

fn matchesAny(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (globMatch(p, path)) return true;
    }
    return false;
}

// ===========================================================================
// discovery
// ===========================================================================

/// Look for `tsconfig.json` in `base`, then each parent, up to `max_levels`
/// parents. Returns the base-relative path ("tsconfig.json",
/// "../tsconfig.json", ...) or null.
pub fn findUpwardInDir(io: Io, arena: Allocator, base: Io.Dir, max_levels: usize) Error!?[]u8 {
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

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

test "jsonc: comments, trailing commas, escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parseJsonc(arena.allocator(),
        \\{
        \\  // line comment
        \\  "a": [1, 2, 3,], /* block
        \\     comment */
        \\  "b": { "nested": true, },
        \\  "s": "q\"\\\nA",
        \\  "n": -1.5e2,
        \\  "z": null,
        \\}
    );
    try testing.expect(v == .object);
    const a = v.object.get("a").?;
    try testing.expectEqual(@as(usize, 3), a.array.len);
    try testing.expectEqual(@as(f64, 2), a.array[1].number);
    try testing.expect(v.object.get("b").?.object.get("nested").?.boolean);
    try testing.expectEqualStrings("q\"\\\nA", v.object.get("s").?.string);
    try testing.expectEqual(@as(f64, -150), v.object.get("n").?.number);
    try testing.expect(v.object.get("z").? == .null);
    try testing.expectEqual(@as(?Value, null), v.object.get("missing"));
}

test "jsonc: syntax errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "",         "{",   "{\"a\" 1}",      "[1 2]",
        "{,}",      "tru", "\"unterminated", "{\"a\": }",
        "[1] junk", "01a",
    };
    for (bad) |text| {
        try testing.expectError(error.SyntaxError, parseJsonc(arena.allocator(), text));
    }
}

test "globMatch: subset semantics" {
    const T = struct { pat: []const u8, path: []const u8, want: bool };
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
    };
    for (cases) |c| {
        if (globMatch(c.pat, c.path) != c.want) {
            std.debug.print("globMatch({s}, {s}) != {}\n", .{ c.pat, c.path, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

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
    // esModuleInterop + references warn; target is a verbose note.
    try testing.expectEqual(@as(usize, 2), cfg.warnings.len);
    try testing.expectEqual(@as(usize, 1), cfg.notes.len);
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
    const resolved = try modules.resolveStem(io, alloc, d, c2[0]);
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
    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, cfg.root_files, .none);
    try testing.expectEqual(@as(usize, 2), br.program.files.len);

    const checker = @import("checker.zig");
    const owned = try alloc.alloc(modules.FileId, br.program.files.len);
    for (owned, 0..) |*f, i| f.* = @intCast(i);
    const result = try checker.checkFiles(alloc, io, gpa, &interner, &br.program, owned, null, true);
    // Exactly the one TS2322 in main.ts line 3; skip/broken.ts is excluded.
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqual(@as(u16, 2322), result.diagnostics[0].code);
}
