//! Embedded built-in lib shards (`lib.*.d.ts`) and their injection into a
//! program.
//!
//! The ES-core and DOM libs ship inside the binary as sharded blobs; a
//! tsconfig `lib` list selects which shards a run injects (`resolveLibSet`),
//! the loaders substitute their embedded text for the synthetic paths
//! (`libSourceFor`), and `seedLibAtoms` pins their interner atoms before the
//! worker pool starts so runs stay deterministic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("frontend/ast.zig");
const parser = @import("frontend/parser.zig");
const binder = @import("frontend/binder.zig");
const intern = @import("intern.zig");

const Ast = ast.Ast;
const Bind = binder.Bind;
const Interner = intern.Interner;

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

/// Deterministic lib atoms. Intern every string the lib front end
/// produces, single-threaded, *before* the worker pool starts. An `Atom`
/// encodes shard-local insertion order (intern.zig), so run-to-run stability
/// requires the lib's strings to be interned in a fixed order ahead of the
/// concurrent user-file work; the worker that later binds the lib re-interns
/// the same text and receives these stable atoms. This is the seeded-interner
/// approach (option a): it pins the lib's atoms (the ones a serialized
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
        _ = try binder.bind(sa, io, gpa, interner, &lib_tree, lf.source, true);
        // Each lib file's own path atom is interned by the worker front end too.
        _ = try interner.intern(io, gpa, lf.path);
    }
}

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

/// Synthetic paths of the injected ES-core lib shards (sharded later for the parallel front-end).
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

/// Synthetic paths of the injected DOM lib shards. Loaded when tsconfig
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

/// Synthetic path of the minimal `console` shim. Loaded ONLY when esnext
/// is selected without dom (backend configs, lib:["esnext"]): `console` lives
/// in lib.dom, so without DOM there is no `console`. DOM configs use lib.dom's
/// richer `Console` and skip this (no duplicate `var console`).
pub const console_shim_path = "\x00lib/lib.console.d.ts";
pub const console_shim_source = @embedFile("lib/lib.console.d.ts");

/// Upper bound on injected lib files: every es shard + every dom shard + the
/// console shim. Sizes the fixed-capacity `LibFile` buffers callers pass in.
pub const max_lib_files = es_shard_count + dom_shard_count + 1;

// -------------------------------------------------------------------------
// tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "seedLibAtoms: covers every atom the lib binder produces (atom determinism)" {
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
        b_ptr.* = try binder.bind(a, io, gpa, &itn1, tree, lf.source, true);
        last_bind = b_ptr;
    }
    try testing.expectEqual(seeded_count, itn1.count(io));

    // A second, independent seed assigns byte-for-byte identical atom values
    // to the lib's strings — the run-to-run stability a serialized lib blob would rely on.
    var itn2 = Interner.init();
    defer itn2.deinit(gpa);
    try seedLibAtoms(io, gpa, &itn2, set);
    try testing.expectEqual(seeded_count, itn2.count(io));
    for (last_bind.symbol_names[1..]) |atom| {
        if (atom == 0) continue; // anonymous symbol, no name
        try testing.expectEqualStrings(itn1.lookup(io, atom), itn2.lookup(io, atom));
    }
}
