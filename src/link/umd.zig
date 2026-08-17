//! UMD globals: `export as namespace X;`.
//!
//! A declaration file that is a module may publish its exports under a GLOBAL
//! name — the UMD pattern (`export as namespace React`). tsc binds the name
//! into the source file's own `globalExports` table and, in
//! `initializeTypeChecker`, copies it into the program's `globals` **only if
//! the name is not already there**:
//!
//! ```ts
//! for (const file of host.getSourceFiles()) {
//!     if (!isExternalOrCommonJsModule(file)) mergeSymbolTable(globals, file.locals);
//!     if (file.symbol?.globalExports) {
//!         file.symbol.globalExports.forEach((sym, id) => {
//!             if (!globals.has(id)) globals.set(id, sym);
//!         });
//!     }
//! }
//! // …and only afterwards: every `declare global { … }` augmentation.
//! ```
//!
//! Two consequences this module exists to model, both oracle-verified:
//!
//!  1. The UMD name enters the merge chain at ITS FILE's position, in the
//!     non-augmentation pass — the same position `bind.global_atoms[0 ..
//!     global_aug_start]` holds for a script's top level. A *script* file that
//!     declares the same name EARLIER wins outright and the UMD entry is
//!     dropped with no diagnostic; one that declares it later merges INTO the
//!     UMD entry and can clash.
//!  2. What it clashes with is exactly what a *namespace* clashes with:
//!     `var`/`let`/`const` collide (TS2300 / TS2451), while
//!     `function`/`class`/`interface`/`namespace`/`type`/`enum` merge silently.
//!     tsc's UMD symbol is an alias whose target is the module symbol
//!     (`ValueModule`), and the merge is judged on the resolved meaning.
//!
//! The binder does not surface the declaration (it keeps only `umd_name`, and
//! only for the `export = <ident>` shape it can resolve), so the records are
//! harvested here by a scan of each declaration file's top level — the same
//! shape as `alias_cycle.zig`'s harvest, and just as read-only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ast = @import("../frontend/ast.zig");
const intern = @import("../intern.zig");
const paths = @import("paths.zig");
const program = @import("program.zig");
const scanner = @import("../frontend/scanner.zig");
const source = @import("../frontend/source.zig");

const Atom = intern.Atom;
const Error = program.Error;
const FileId = program.FileId;
const Interner = intern.Interner;
const ProgFile = program.ProgFile;
const Span = source.Span;

/// One `export as namespace X;` declaration. `span` is the NAME identifier —
/// where tsc anchors the duplicate-declaration diagnostics.
pub const Global = struct {
    file: FileId,
    name: Atom,
    span: Span,
};

/// Every `export as namespace X;` in the program, in (file, source) order —
/// which is the order the merge chain needs.
///
/// Only a declaration file that is a MODULE can publish one: tsc reports
/// TS1315/TS1316 and registers nothing otherwise, and the parser has already
/// rejected the non-top-level position. Both filters are cheap tests on data
/// the linker already has, so a program with no `.d.ts` module pays a single
/// predicate per file and nothing else.
pub fn collect(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []const ProgFile,
) Error![]Global {
    var out: std.ArrayListUnmanaged(Global) = .empty;
    for (files, 0..) |*f, fi| {
        if (!f.bind.is_module) continue;
        if (!paths.isDeclarationPath(f.path)) continue;
        for (f.tree.nodeRange(ast.root_node)) |stmt| {
            if (f.tree.nodeTag(stmt) != .export_as_ns) continue;
            const tok: ast.TokenIndex = @intCast(f.tree.nodeData(stmt).lhs);
            const name = interner.intern(io, gpa, f.tree.tokenSlice(f.src, tok)) catch
                return Error.OutOfMemory;
            const start = f.tree.tokens.start(tok);
            try out.append(arena, .{
                .file = @intCast(fi),
                .name = name,
                .span = .{ .start = start, .end = scanner.tokenEnd(f.src, f.tree.tokens.tag(tok), start) },
            });
        }
    }
    return out.items;
}

/// One `export as namespace <text>` declaration of `f`, or null when the file
/// publishes no UMD global by that name.
///
/// The same three filters `collect` applies, then a byte compare on the name
/// token: the caller arrives with the one name it is looking for, and a file
/// declares at most a couple of these, so this is cheaper than interning and
/// needs no allocator.
pub fn declNaming(f: *const ProgFile, text: []const u8) ?Decl {
    if (!f.bind.is_module) return null;
    if (!paths.isDeclarationPath(f.path)) return null;
    for (f.tree.nodeRange(ast.root_node)) |stmt| {
        if (f.tree.nodeTag(stmt) != .export_as_ns) continue;
        const tok: ast.TokenIndex = @intCast(f.tree.nodeData(stmt).lhs);
        if (std.mem.eql(u8, f.tree.tokenSlice(f.src, tok), text)) return .{ .node = stmt, .tok = tok };
    }
    return null;
}

/// The statement node of one `export as namespace X;` and its name token.
pub const Decl = struct { node: ast.Node, tok: ast.TokenIndex };

/// The records naming `atom`, as a subslice of a `collect` result sorted by
/// name. See `sortByName`.
pub fn forName(sorted: []const Global, atom: Atom) []const Global {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid].name < atom) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < sorted.len and sorted[end].name == atom) end += 1;
    return sorted[lo..end];
}

/// Sort `globals` by name, keeping the (file, source) order within one name —
/// the merge chain's order. In place.
pub fn sortByName(globals: []Global) void {
    std.mem.sort(Global, globals, {}, struct {
        fn lt(_: void, a: Global, b: Global) bool {
            return a.name < b.name;
        }
    }.lt);
}
