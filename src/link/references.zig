//! Triple-slash reference directives — the second way a file enters the
//! module graph (an import is the first, a program root the third).
//!
//! `/// <reference path="./x.d.ts" />` and `/// <reference types="node" />`
//! are honored only in a file's leading comment block, before the first real
//! token, exactly as tsc does. Scanning them out of a source is pure string
//! work (`scanReferences`); resolving one is ordinary module resolution
//! (`resolveReference`), so it runs on the same `Fs` context, memos included,
//! that an import gets.
//!
//! resolve.zig re-exports `RefDirective` and `scanReferences` — the two names
//! the driver and the linker use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const paths = @import("paths.zig");

const Error = Allocator.Error;
const dirnamePart = paths.dirnamePart;
const joinNormalize = paths.joinNormalize;
const Fs = resolve.Fs;

/// A `/// <reference path=… />` / `<reference types=… />` directive; `spec`
/// slices into the source. `lib=` references are ignored (built-in libs).
pub const RefDirective = struct {
    pub const Kind = enum { path, types };

    kind: Kind,
    spec: []const u8,
    /// Byte offset of `spec[0]` in the scanned source — the first character
    /// *inside* the opening quote, which is where tsc anchors the directive's
    /// own diagnostic (TS2688). Filled by `scanReferences`; 0 when a caller
    /// builds a directive by hand (resolution never reads it).
    pos: u32 = 0,
};

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
                if (parseReference(line[3..])) |d| {
                    // `spec` is always a subslice of `src` (the scanner never
                    // copies), so its byte offset is a pointer difference —
                    // the anchor a directive diagnostic (TS2688) reports at.
                    var with_pos = d;
                    with_pos.pos = @intCast(@intFromPtr(d.spec.ptr) - @intFromPtr(src.ptr));
                    try out.append(alloc, with_pos);
                }
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
/// `f` carries the same filesystem context (and memos) the module resolver
/// uses.
///
/// The result is *not* canonicalized — callers that key the module graph by path
/// must run it through `ResolveCache.canonicalPath` (or call
/// `ResolveCache.resolveRef`, which does both), or a symlinked package
/// directory becomes a second copy of a file already in the graph.
pub fn resolveReference(
    f: Fs,
    alloc: Allocator,
    importer: []const u8,
    ref: RefDirective,
) Error!?[]u8 {
    switch (ref.kind) {
        .path => {
            const stem = try joinNormalize(alloc, dirnamePart(importer), ref.spec);
            defer alloc.free(stem);
            // tsc's `resolveTripleslashReference` is a plain path join: a
            // `path=` directive names a FILE, and nothing is probed for it —
            // which is why `/// <reference path='typescript.ts'/>` with no such
            // file is TS6053 rather than a search. So the literal path answers
            // FIRST. Without that pass the stem walk below strips `.d.ts` and
            // prefers `.ts`, so `path="a.d.ts"` written in `a.ts` resolved to
            // `a.ts` — a different file from the one named, and (once the
            // self-reference rule existed) one that read as the file
            // referencing itself (`bangInModuleName`).
            if (try resolve.fileAt(f, alloc, stem)) |p| return p;
            // The stem probe stays behind it: ztsc has always been lenient
            // about the extensionless spellings tsc calls TS6053, and taking
            // that away is a diagnostic change with no evidence behind it.
            return resolve.resolveStemFs(f, alloc, stem);
        },
        .types => {
            // A `types=` directive is a package resolution, so it honors
            // `resolvePackageJsonExports` exactly like an import does.
            const use_exports = f.opts.resolve_pkg_json_exports;
            const scoped = try std.fmt.allocPrint(alloc, "@types/{s}", .{ref.spec});
            defer alloc.free(scoped);
            if (try resolve.resolvePackage(f, alloc, dirnamePart(importer), scoped, false, use_exports)) |p| return p;
            return resolve.resolvePackage(f, alloc, dirnamePart(importer), ref.spec, false, use_exports);
        },
    }
}

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

const testing = std.testing;

// (b2) `scanReferences` reports each directive's name span, which is where the
// unresolved-directive diagnostic (TS2688) lands — one character past the
// opening quote, name length wide, whatever precedes it on the line.
test "scanReferences: kind, spec and name offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\/// <reference types="nope" />
        \\/// <reference types='@scope/nope' />
        \\   /// <reference path="./other.d.ts" />
        \\/// <reference lib="es2015" />
        \\export const x = 1;
        \\/// <reference types="after-first-token" />
        \\
    ;
    const refs = try scanReferences(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 3), refs.len);
    try testing.expectEqual(RefDirective.Kind.types, refs[0].kind);
    try testing.expectEqualStrings("nope", refs[0].spec);
    // `/// <reference types="` is 22 characters, so the name starts at byte 22
    // (column 23, the oracle's anchor).
    try testing.expectEqual(@as(u32, 22), refs[0].pos);
    try testing.expectEqualStrings("nope", src[refs[0].pos..][0..refs[0].spec.len]);
    try testing.expectEqualStrings("@scope/nope", refs[1].spec);
    try testing.expectEqualStrings("@scope/nope", src[refs[1].pos..][0..refs[1].spec.len]);
    // Indentation shifts the offset; a `path=` directive keeps its own kind.
    try testing.expectEqual(RefDirective.Kind.path, refs[2].kind);
    try testing.expectEqualStrings("./other.d.ts", src[refs[2].pos..][0..refs[2].spec.len]);
    // `lib=` is not a program input here, and nothing past the first real token
    // is a directive at all.
}
