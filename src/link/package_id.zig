//! Package identity: two on-disk copies of one package are ONE file.
//!
//! A `node_modules` tree routinely holds the same package twice — `@types/foo`
//! hoisted at the top and `a/node_modules/foo` nested under a dependency, a
//! pnpm store that links the same version from two places, a monorepo where
//! two workspaces each install it. Both copies declare the same classes, and a
//! class is NOMINAL as soon as it has a `private`/`protected` member: without
//! dedup the two `Foo`s are unrelated types and every value that crosses
//! between the two copies is a TS2322/TS2345 that tsc never reports.
//!
//! tsc's rule (`getPackageId` / `packageIdToSourceFile` / `redirectTargetsMap`)
//! is an identity triple taken from the package the file came out of:
//!
//!   * `name` and `version` from that package's `package.json`, and
//!   * `subModuleName` — the file's path RELATIVE to the package directory,
//!     so `foo/Foo.d.ts` and `foo/Bar.d.ts` stay two different files
//!     (`duplicatePackage_packageIdIncludesSubModule`).
//!
//! The package directory itself is read off the path, not off how the
//! specifier was written (tsc's `parseNodeModuleFromPath`): the LAST
//! `/node_modules/` component plus one directory, two for an `@scope/name`.
//! That is why a *relative* import inside a package is deduped too
//! (`duplicatePackage_relativeImportWithinPackage`) — the identity is a
//! property of where the file lives, not of the specifier that reached it.
//!
//! When two files share the triple, the second one is a *redirect* to the
//! first: every specifier that resolved to it binds to the first copy's
//! symbols instead. This module computes that table; applying it is the
//! caller's (both program builders rewrite their spec maps with it, so the
//! serial and parallel pipelines cannot disagree about module identity).
//!
//! WHICH copy wins is decided by final file id — the deterministic,
//! graph-derived order both builders settle before this runs — and not by
//! discovery/completion order, which in the parallel driver depends on thread
//! scheduling. tsc's winner is its depth-first discovery order instead; the
//! two agree on every corpus case because duplicate copies of one package
//! *version* are byte-identical in practice, and determinism is worth more
//! here than bug-compatibility with a traversal order ztsc does not have.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const paths = @import("paths.zig");
const pkgjson = @import("package_json.zig");
const program = @import("program.zig");
const resolve = @import("resolve.zig");

const FileId = program.FileId;
const no_file = program.no_file;
const Error = Allocator.Error;

const nm_part = "/node_modules/";

/// The `node_modules` package directory `path` lies in, or null when it lies
/// in none. tsc's `parseNodeModuleFromPath`: the last `/node_modules/` plus
/// one path component, two when that component is an `@scope`.
///
/// A path that IS the `node_modules/<pkg>` directory (no file part left) has
/// no package identity here — every caller passes a resolved FILE.
pub fn packageDirOf(path: []const u8) ?[]const u8 {
    const after: usize = if (std.mem.lastIndexOf(u8, path, nm_part)) |at|
        at + nm_part.len
    else if (std.mem.startsWith(u8, path, nm_part[1..]))
        // A base-relative run can start the path with the component itself.
        nm_part.len - 1
    else
        return null;
    if (after >= path.len) return null;
    var end = std.mem.indexOfScalarPos(u8, path, after, '/') orelse return null;
    if (path[after] == '@') {
        end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse return null;
    }
    return path[0..end];
}

/// One package's identity fields, as read from its `package.json`. Null for a
/// package that names no `name` or no `version` — tsc requires both before it
/// will call two files the same, so such a package is never deduped.
const Meta = struct { name: []const u8, version: []const u8 };

fn metaOf(text: []const u8) ?Meta {
    const name = pkgjson.packageNameField(text) orelse return null;
    const version = pkgjson.packageVersionField(text) orelse return null;
    return .{ .name = name, .version = version };
}

/// The redirect table for a discovered program: `map[i]` is the file every
/// reference to file `i` should bind to — `i` itself unless `i` is a later
/// copy of a package another file already provides.
///
/// Null when the program holds no duplicate copy, which is the normal case:
/// then the caller skips the rewrite entirely and the pass costs one path scan
/// per `node_modules` file plus one `package.json` field read per distinct
/// package directory (both memoized in `rc`, which already read most of those
/// bodies while resolving).
///
/// `scratch` holds the bookkeeping (freed by the caller's arena reset); the
/// returned table is `arena`-owned.
pub fn redirects(
    arena: Allocator,
    scratch: Allocator,
    rc: *resolve.ResolveCache,
    io: Io,
    dir: Io.Dir,
    file_paths: []const []const u8,
) Error!?[]const FileId {
    // Bookkeeping, all scratch: package dir -> its identity fields (so a
    // package.json is scanned once per package, not once per file in it), and
    // identity key -> the first file that claimed it.
    var metas: std.StringHashMapUnmanaged(?Meta) = .empty;
    var owners: std.StringHashMapUnmanaged(FileId) = .empty;
    var map: ?[]FileId = null;

    for (file_paths, 0..) |path, i| {
        const pkg_dir = packageDirOf(path) orelse continue;
        const meta = blk: {
            const gop = try metas.getOrPut(scratch, pkg_dir);
            if (!gop.found_existing) {
                const pj = try std.fmt.allocPrint(scratch, "{s}/package.json", .{pkg_dir});
                gop.value_ptr.* = if (try rc.packageJsonText(io, dir, scratch, pj)) |text|
                    metaOf(text)
                else
                    null;
            }
            break :blk gop.value_ptr.* orelse continue;
        };
        // tsc's `packageIdToString`: `<name>/<subModuleName>@<version>`.
        const key = try std.fmt.allocPrint(scratch, "{s}/{s}@{s}", .{
            meta.name, path[pkg_dir.len + 1 ..], meta.version,
        });
        const gop = try owners.getOrPut(scratch, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
            continue;
        }
        // A duplicate: materialize the table (identity so far) and record it.
        if (map == null) {
            map = try arena.alloc(FileId, file_paths.len);
            for (map.?, 0..) |*m, j| m.* = @intCast(j);
        }
        map.?[i] = gop.value_ptr.*;
    }
    return map;
}

/// Rewrite one file's resolved specifier targets through `map`. Every module
/// reference of every file goes through this, which is what makes a duplicate
/// copy unreachable by name.
pub fn applyTo(map: []const FileId, spec_files: []FileId) void {
    for (spec_files) |*fid| {
        if (fid.* != no_file) fid.* = map[fid.*];
    }
}

// ===========================================================================
// tests: the path -> package-directory rule (tsc's parseNodeModuleFromPath)
// ===========================================================================

const testing = std.testing;

test "packageDirOf: plain, scoped, nested and absent" {
    try testing.expectEqualStrings(
        "node_modules/foo",
        packageDirOf("node_modules/foo/index.d.ts").?,
    );
    try testing.expectEqualStrings(
        "node_modules/@types/foo",
        packageDirOf("node_modules/@types/foo/index.d.ts").?,
    );
    try testing.expectEqualStrings(
        "/node_modules/a/node_modules/foo",
        packageDirOf("/node_modules/a/node_modules/foo/index.d.ts").?,
    );
    try testing.expectEqualStrings(
        "/p/node_modules/@scope/pkg",
        packageDirOf("/p/node_modules/@scope/pkg/dist/sub/x.d.ts").?,
    );
    try testing.expect(packageDirOf("src/index.ts") == null);
    // No file part left: the directory itself has no identity here.
    try testing.expect(packageDirOf("node_modules/foo") == null);
    try testing.expect(packageDirOf("node_modules/@types/foo") == null);
}

test "packageDirOf: subpath is the rest of the path" {
    const p = "/node_modules/foo/dist/Foo.d.ts";
    const d = packageDirOf(p).?;
    try testing.expectEqualStrings("dist/Foo.d.ts", p[d.len + 1 ..]);
}
