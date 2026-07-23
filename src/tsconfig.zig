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
    /// `compilerOptions.allowJs`: a bare/relative specifier that resolves only to
    /// a JavaScript file (a JS-only package, or a `./x.js` with no `.ts`/`.d.ts`
    /// twin) is typed opaquely as `any` rather than raising TS2307. ztsc never
    /// parses/checks the JS. `checkJs` stays unsupported.
    allow_js: bool = false,
    /// `compilerOptions.resolveJsonModule`: a `*.json` import that names an
    /// existing file resolves (typed opaquely as `any`) rather than TS2307.
    resolve_json_module: bool = false,
    /// Effective `compilerOptions.allowSyntheticDefaultImports`, i.e.
    /// `allowSyntheticDefaultImports ?? esModuleInterop ?? false` (tsc's rule;
    /// esModuleInterop implies it). When on, a default import of a module that
    /// has no default export binds to the module namespace object (the
    /// synthesized default) instead of raising TS1192.
    allow_synthetic_default_imports: bool = false,
    /// `compilerOptions.baseUrl`, resolved to a base-relative directory (null
    /// when unset). Consulted for bare `*.json` specifiers only (`public/api/
    /// x.json`); non-json baseUrl resolution is not modeled.
    base_url: ?[]const u8 = null,
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

/// Load `config_path` (relative to `base`), resolve its `extends` chain,
/// merge, and expand its file list. All returned paths are relative to `base`.
pub fn loadInDir(io: Io, arena: Allocator, base: Io.Dir, config_path: []const u8) LoadError!Config {
    var cfg: Config = .{
        .path = config_path,
        .dir = modules.dirnamePart(config_path),
    };
    var warnings: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;

    // Merge the `extends` chain (base configs applied first, this config last).
    var acc: Merged = .{};
    var chain: std.ArrayList([]const u8) = .empty;
    try mergeConfig(io, arena, base, config_path, cfg.dir, &acc, &warnings, &notes, &chain, true);

    // `strict` is evaluated on the merged value (child overrides base per-key):
    // only an explicit final `false` is the unsupported case.
    if (acc.strict) |s| {
        if (!s) return error.StrictFalse;
    }

    cfg.lib = acc.lib;
    // Effective noImplicitAny = explicit value ?? strict. ztsc only runs strict
    // semantics (strict is true or absent — an explicit `false` errored above),
    // so the fallback is `true`; an explicit `noImplicitAny: false` still wins.
    cfg.no_implicit_any = acc.no_implicit_any orelse (acc.strict orelse true);
    if (!cfg.no_implicit_any) {
        try note(arena, &notes, "'noImplicitAny' is off: implicit-'any' diagnostics (TS7006/TS7053) are suppressed; unannotated values still type as 'any'", .{});
    }
    cfg.allow_js = acc.allow_js orelse false;
    if (cfg.allow_js) {
        try note(arena, &notes, "'allowJs' honored: a specifier resolving only to a .js file is typed opaquely as 'any' (ztsc never parses JS; 'checkJs' is unsupported)", .{});
    }
    cfg.skip_lib_check = acc.skip_lib_check orelse false;
    cfg.skip_all_lib_check = acc.skip_all_lib_check orelse false;
    cfg.resolve_json_module = acc.resolve_json_module orelse false;
    // Effective allowSyntheticDefaultImports = explicit value ?? esModuleInterop
    // ?? false (tsc's rule; esModuleInterop implies it).
    cfg.allow_synthetic_default_imports = acc.allow_synthetic_default_imports orelse acc.es_module_interop orelse false;
    if (cfg.allow_synthetic_default_imports) {
        try note(arena, &notes, "'allowSyntheticDefaultImports'/'esModuleInterop' honored: a default import of a module with no default export binds to the module namespace object (the synthesized default)", .{});
    }
    if (acc.base_url) |bu| {
        cfg.base_url = try joinNormalize(arena, acc.base_url_dir, bu);
    }
    if (cfg.skip_all_lib_check) {
        try note(arena, &notes, "'skipLibCheck' honored: no diagnostics are surfaced from any .d.ts file (default lib and dependency/project .d.ts alike); their types still flow into .ts checking", .{});
    } else if (acc.skip_lib_check) |sv| {
        if (sv) {
            try note(arena, &notes, "'skipDefaultLibCheck' honored: the embedded default lib is not type-checked (other .d.ts files are still checked; use 'skipLibCheck' to skip those too)", .{});
        } else {
            try note(arena, &notes, "'skipLibCheck'/'skipDefaultLibCheck' is not enabled; the embedded default lib is type-checked (matching tsc/tsgo)", .{});
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
            try modules.normalizePath(arena, if (acc.paths_dir.len == 0) "." else acc.paths_dir);
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList([]const []const u8) = .empty;
        for (po.keys, po.vals) |pkey, pval| {
            if (std.mem.count(u8, pkey, "*") > 1) {
                try warn(arena, &warnings, "{s}: paths pattern '{s}' has more than one '*' (ignored)", .{ acc.paths_path, pkey });
                continue;
            }
            if (pval != .array) {
                try warn(arena, &warnings, "{s}: paths entry '{s}' must be an array (ignored)", .{ acc.paths_path, pkey });
                continue;
            }
            var targets: std.ArrayList([]const u8) = .empty;
            for (pval.array) |t| {
                if (t != .string or std.mem.count(u8, t.string, "*") > 1) {
                    try warn(arena, &warnings, "{s}: bad substitution in paths entry '{s}' (skipped)", .{ acc.paths_path, pkey });
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
    var exclude_pats: []const []const u8 = &default_excludes;
    var exclude_dir: []const u8 = include_dir;
    if (acc.exclude) |list| {
        exclude_pats = list;
        exclude_dir = acc.exclude_dir;
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
        for (exclude_pats) |e| {
            try exc_abs.append(arena, try joinNormalize(arena, exclude_dir, e));
        }
        const matched = try expandInclude(io, arena, base, include_dir, inc_abs.items, exc_abs.items, &warnings, cfg.path);
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

/// Accumulator for the merged config across an `extends` chain. Each field that
/// carries relative paths remembers the directory of the config that set it, so
/// inherited entries re-anchor correctly (all base-relative). "Last write wins"
/// gives child-overrides-base semantics since bases are applied first.
const Merged = struct {
    strict: ?bool = null,
    no_implicit_any: ?bool = null,
    allow_js: ?bool = null,
    lib: ?[]const []const u8 = null,
    skip_lib_check: ?bool = null,
    skip_all_lib_check: ?bool = null,
    resolve_json_module: ?bool = null,
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
};

/// Read, parse, and merge `config_path` (base-relative, directory `dir`) into
/// `acc`, resolving its `extends` bases first. `chain` is the stack of configs
/// currently being resolved (for cycle detection). `is_root` distinguishes the
/// user-named config (whose read/parse failures are hard errors) from a base
/// (whose failures warn and degrade to no-extends).
fn mergeConfig(
    io: Io,
    arena: Allocator,
    base: Io.Dir,
    config_path: []const u8,
    dir: []const u8,
    acc: *Merged,
    warnings: *std.ArrayList([]const u8),
    notes: *std.ArrayList([]const u8),
    chain: *std.ArrayList([]const u8),
    is_root: bool,
) LoadError!void {
    try chain.append(arena, config_path);
    defer _ = chain.pop();

    const text = base.readFileAlloc(io, config_path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (is_root) return error.NotFound;
            try warn(arena, warnings, "{s}: cannot read config referenced by 'extends' (ignored)", .{config_path});
            return;
        },
    };
    const root = parseJsonc(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            if (is_root) return error.SyntaxError;
            try warn(arena, warnings, "{s}: config referenced by 'extends' is not valid JSON (ignored)", .{config_path});
            return;
        },
    };
    if (root != .object) {
        if (is_root) return error.SyntaxError;
        try warn(arena, warnings, "{s}: config referenced by 'extends' is not an object (ignored)", .{config_path});
        return;
    }

    // Resolve `extends` bases first so their options apply before this config's.
    if (root.object.get("extends")) |ev| {
        const specs: []const Value = switch (ev) {
            .string => &.{ev},
            .array => ev.array,
            else => blk: {
                try warn(arena, warnings, "{s}: 'extends' must be a string or an array of strings (ignored)", .{config_path});
                break :blk &.{};
            },
        };
        for (specs) |sv| {
            if (sv != .string) {
                try warn(arena, warnings, "{s}: non-string entry in 'extends' (skipped)", .{config_path});
                continue;
            }
            const spec = sv.string;
            const resolved = try resolveExtends(io, arena, base, dir, spec);
            if (resolved) |rp| {
                var cyclic = false;
                for (chain.items) |c| {
                    if (std.mem.eql(u8, c, rp)) cyclic = true;
                }
                if (cyclic) {
                    try warn(arena, warnings, "{s}: TS18000: circularity detected resolving 'extends' to '{s}' (ignored)", .{ config_path, rp });
                    continue;
                }
                try mergeConfig(io, arena, base, rp, modules.dirnamePart(rp), acc, warnings, notes, chain, false);
            } else {
                try warn(arena, warnings, "{s}: cannot find config '{s}' referenced by 'extends' (ignored)", .{ config_path, spec });
            }
        }
    }

    try applyOwn(arena, root.object, dir, config_path, acc, warnings, notes);
}

/// Apply one config object's own keys into `acc` (its `extends` already
/// handled). Later calls (the extending config) overwrite per-key.
fn applyOwn(
    arena: Allocator,
    obj: Value.Object,
    dir: []const u8,
    config_path: []const u8,
    acc: *Merged,
    warnings: *std.ArrayList([]const u8),
    notes: *std.ArrayList([]const u8),
) Error!void {
    for (obj.keys, obj.vals) |key, val| {
        if (std.mem.eql(u8, key, "extends")) {
            // Already resolved by the caller.
        } else if (std.mem.eql(u8, key, "$schema") or std.mem.eql(u8, key, "display")) {
            // Editor/schema hints (common in shared base configs); tsc ignores
            // these silently, so we do too — no warning.
        } else if (std.mem.eql(u8, key, "files")) {
            if (try stringArray(arena, warnings, config_path, key, val)) |list| {
                acc.files = list;
                acc.files_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "include")) {
            if (try stringArray(arena, warnings, config_path, key, val)) |list| {
                acc.include = list;
                acc.include_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "exclude")) {
            if (try stringArray(arena, warnings, config_path, key, val)) |list| {
                acc.exclude = list;
                acc.exclude_dir = dir;
            }
        } else if (std.mem.eql(u8, key, "compilerOptions")) {
            if (val != .object) {
                try warn(arena, warnings, "{s}: 'compilerOptions' must be an object (ignored)", .{config_path});
                continue;
            }
            for (val.object.keys, val.object.vals) |okey, oval| {
                if (std.mem.eql(u8, okey, "strict")) {
                    if (oval == .boolean) {
                        acc.strict = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'strict' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noEmit")) {
                    try note(arena, notes, "{s}: 'noEmit' ignored (ztsc never emits)", .{config_path});
                } else if (std.mem.eql(u8, okey, "target") or
                    std.mem.eql(u8, okey, "module") or
                    std.mem.eql(u8, okey, "moduleResolution"))
                {
                    try note(arena, notes, "{s}: '{s}' accepted and ignored (ztsc always checks its fixed esnext/bundler subset)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "jsx") or
                    std.mem.eql(u8, okey, "jsxImportSource") or
                    std.mem.eql(u8, okey, "jsxFactory") or
                    std.mem.eql(u8, okey, "jsxFragmentFactory"))
                {
                    try note(arena, notes, "{s}: '{s}' accepted and ignored (ztsc type-checks JSX via the ambient/global `JSX` namespace; it never emits)", .{ config_path, okey });
                } else if (std.mem.eql(u8, okey, "lib")) {
                    if (try stringArray(arena, warnings, config_path, okey, oval)) |libs| {
                        acc.lib = libs;
                        for (libs) |name| {
                            if (!std.ascii.startsWithIgnoreCase(name, "es") and
                                !std.ascii.startsWithIgnoreCase(name, "dom"))
                            {
                                try note(arena, notes, "{s}: lib '{s}' is out of subset (ignored; ztsc ships es-core + dom)", .{ config_path, name });
                            }
                        }
                    }
                } else if (std.mem.eql(u8, okey, "resolveJsonModule")) {
                    if (oval == .boolean) {
                        acc.resolve_json_module = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'resolveJsonModule' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "esModuleInterop")) {
                    if (oval == .boolean) {
                        acc.es_module_interop = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'esModuleInterop' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "allowSyntheticDefaultImports")) {
                    if (oval == .boolean) {
                        acc.allow_synthetic_default_imports = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'allowSyntheticDefaultImports' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "noImplicitAny")) {
                    if (oval == .boolean) {
                        acc.no_implicit_any = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'noImplicitAny' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "allowJs")) {
                    if (oval == .boolean) {
                        acc.allow_js = oval.boolean;
                    } else {
                        try warn(arena, warnings, "{s}: 'allowJs' must be a boolean (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "types")) {
                    try note(arena, notes, "{s}: 'types' ignored (ztsc resolves @types via imports/references)", .{config_path});
                } else if (std.mem.eql(u8, okey, "skipLibCheck") or std.mem.eql(u8, okey, "skipDefaultLibCheck")) {
                    if (oval == .boolean) {
                        // Both keys skip the default lib. `skipLibCheck` is the
                        // superset: it also skips every other .d.ts file.
                        acc.skip_lib_check = oval.boolean;
                        if (std.mem.eql(u8, okey, "skipLibCheck")) {
                            acc.skip_all_lib_check = oval.boolean;
                        }
                    } else {
                        try warn(arena, warnings, "{s}: '{s}' must be a boolean (ignored)", .{ config_path, okey });
                    }
                } else if (std.mem.eql(u8, okey, "baseUrl")) {
                    if (oval == .string) {
                        acc.base_url = oval.string;
                        acc.base_url_dir = dir;
                    } else {
                        try warn(arena, warnings, "{s}: 'baseUrl' must be a string (ignored)", .{config_path});
                    }
                } else if (std.mem.eql(u8, okey, "paths")) {
                    if (oval == .object) {
                        acc.paths_obj = oval.object;
                        acc.paths_dir = dir;
                        acc.paths_path = config_path;
                    } else {
                        try warn(arena, warnings, "{s}: 'paths' must be an object (ignored)", .{config_path});
                    }
                } else {
                    try warn(arena, warnings, "{s}: unknown compiler option '{s}' (ignored)", .{ config_path, okey });
                }
            }
        } else {
            try warn(arena, warnings, "{s}: unknown option '{s}' (ignored)", .{ config_path, key });
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
        d = modules.dirnamePart(d);
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

/// Walk from `walk_root` (base-relative dir) collecting `.ts`/`.d.ts` files
/// matching any `include` pattern and excluded by none. `include`/`exclude`
/// patterns are already base-relative (same coordinate system as the walked
/// paths), so patterns declared in different configs compose correctly.
/// Returned paths are base-relative and sorted.
fn expandInclude(
    io: Io,
    arena: Allocator,
    base: Io.Dir,
    walk_root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    warnings: *std.ArrayList([]const u8),
    config_path: []const u8,
) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, walk_root);

    while (stack.pop()) |cur| {
        const open_path = if (cur.len == 0) "." else cur;
        var d = base.openDir(io, open_path, .{ .iterate = true }) catch {
            if (std.mem.eql(u8, cur, walk_root)) {
                try warn(arena, warnings, "{s}: cannot open directory '{s}'", .{ config_path, open_path });
            }
            continue;
        };
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const child = if (cur.len == 0)
                try arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ cur, entry.name });
            switch (entry.kind) {
                .directory => {
                    if (!matchesAny(exclude, child)) try stack.append(arena, child);
                },
                .file => {
                    if (!hasTsExt(child)) continue;
                    if (matchesAny(exclude, child)) continue;
                    if (!matchesAny(include, child)) continue;
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
    const br = try modules.buildProgram(alloc, io, gpa, &interner, d, cfg.root_files, .none, .{}, cfg.allow_synthetic_default_imports);
    try testing.expectEqual(@as(usize, 2), br.program.files.len);

    const checker = @import("checker.zig");
    const owned = try alloc.alloc(modules.FileId, br.program.files.len);
    for (owned, 0..) |*f, i| f.* = @intCast(i);
    const result = try checker.checkFiles(alloc, io, gpa, &interner, &br.program, owned, null, true);
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
