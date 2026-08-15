//! TS2303: circular definitions of an import alias.
//!
//! An *alias declaration* names something that lives somewhere else — an import
//! specifier, a namespace/default import, `import X = require("m")`,
//! `import X = Entity`, an export specifier, `export = X`, `export default X`.
//! Every one of them has exactly ONE target, so the alias graph is a functional
//! graph: each node has out-degree 1 and therefore lies on at most one cycle.
//! When a cycle exists the aliases on it define each other and nothing else, and
//! tsc reports TS2303 at EVERY declaration on the cycle — verified against tsgo
//! for entity aliases (`namespace M { import A = B; import B = A; }`), cross-file
//! `import type`/`export type` specifier loops, `import self =
//! require("<own module>") + export = self` (both in a file and in an ambient
//! `declare module` block), `import * as self` / `import self` self-loops, and a
//! loop that runs through an `export *`.
//!
//! Why a pass of its own rather than a guard inside the linker's resolution: the
//! linker's export tables are already cycle-SAFE (a file asked for its table
//! while building reads the partial one, so a loop silently contributes
//! nothing). That is the right answer for *resolution* — it keeps every symbol
//! bound — but it erases the evidence a diagnostic needs. This pass asks the
//! separate question "which alias declarations define each other", reads only
//! sealed bind data, and writes nothing but diagnostics: it cannot change what
//! any name resolves to.
//!
//! What is deliberately terminal (an under-report, never an over-report):
//!   - a qualified entity alias (`import G = H.I`) — resolving `H.I` needs
//!     namespace-member lookup, which is checker territory;
//!   - `export * as ns from "m"` (the alias is a module namespace object);
//!   - `export as namespace N` (its name lives in the global merge, not in a
//!     module's own tables);
//!   - a wildcard ambient module (`declare module "*.css"`).
//!
//! Cost: one hash-map probe per alias declaration in the program, plus a single
//! pass over each file's symbol flags to find entity aliases (which carry no
//! import record). A program with no cycle pays exactly that and emits nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ast = @import("../frontend/ast.zig");
const bind_result = @import("../frontend/bind_result.zig");
const intern = @import("../intern.zig");
const program = @import("program.zig");
const source = @import("../frontend/source.zig");
const scanner = @import("../frontend/scanner.zig");

const Atom = intern.Atom;
const Bind = bind_result.Bind;
const FileId = program.FileId;
const Interner = intern.Interner;
const LinkDiag = program.LinkDiag;
const Node = ast.Node;
const ProgFile = program.ProgFile;
const ScopeId = bind_result.ScopeId;
const Span = source.Span;
const SymbolId = bind_result.SymbolId;
const TokenIndex = ast.TokenIndex;

const Error = program.Error;

/// How an alias declaration reaches its target. The tag decides both the edge
/// (`nextSite`) and where the diagnostic lands (`Site.span`).
const Kind = enum {
    /// `import { ref as name } from module`
    import_named,
    /// `import * as name from module` (`tok` = the name)
    import_ns,
    /// `import name from module` (`tok` = the name)
    import_default,
    /// `import name = require(module)`
    import_require,
    /// `import name = Entity` — `ref` is the (single-identifier) entity
    import_entity,
    /// `export { ref as name }` — `ref` resolves in `scope`
    export_spec,
    /// `export { ref as name } from module`
    export_from,
    /// `export = ref`
    export_equals,
    /// `export default ref`
    export_default,
};

/// One alias declaration. `(file, node)` is its identity; `name` is what the
/// message prints (tsc's `symbolToString` of the alias symbol, which for an
/// export assignment is the identifier it names).
const Site = struct {
    file: FileId,
    node: Node,
    kind: Kind,
    name: Atom,
    /// Module specifier, for the `import_*`/`export_from` kinds.
    module: Atom = 0,
    /// Name looked up in the target module, or resolved in `scope`.
    ref: Atom = 0,
    /// `ref`'s symbol when the binder already resolved it (`seal` fills the
    /// `export { … }` and `export default <ident>` records in), else
    /// `no_symbol` and `ref`/`scope` are resolved on demand.
    sym: SymbolId = bind_result.no_symbol,
    /// Scope `ref` resolves from (a `declare module "m" { … }` block declares
    /// its own imports, so this is not always the file scope).
    scope: ScopeId = bind_result.file_scope,
    /// Name token, when the error span is the name rather than the whole node.
    tok: TokenIndex = 0,

    /// Site identity. `kind` is part of it because one `import_decl` node can
    /// carry two bindings (`import d, * as n from "m"`), which are two aliases.
    fn key(s: Site) Key {
        return .{ .file = s.file, .node = s.node, .kind = s.kind };
    }
};

const Key = struct { file: FileId, node: Node, kind: Kind };

/// A `declare module "spec" { … }` block: the file it is written in and its own
/// scope (which is what distinguishes two blocks in one file).
const Block = struct { file: FileId, scope: ScopeId, export_start: u32, export_end: u32 };

/// Bounded `export *` walk. A star chain deeper than this stops rather than
/// spinning; the linker's own re-export walk is bounded the same way.
const star_depth = 32;

const Ctx = struct {
    arena: Allocator,
    scratch: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []const ProgFile,
    diags: []std.ArrayList(LinkDiag),
    atom_default: Atom,
    /// Exactly-named ambient modules: specifier → its blocks, in file order.
    blocks: std.AutoArrayHashMapUnmanaged(Atom, std.ArrayListUnmanaged(Block)) = .empty,
    /// Alias-site walk state: `Site.key` → index in `path` while the site is on
    /// the current path, `done` once it has been walked. Cycle-detection state,
    /// scratch-owned, dropped with the pass.
    state: std.AutoHashMapUnmanaged(Key, i64) = .empty,
    /// The path being walked (out-degree is 1, so one path is all we need).
    path: std.ArrayListUnmanaged(Site) = .empty,
    /// Files already visited by one `export *` walk; reset per walk.
    star_seen: std.AutoHashMapUnmanaged(FileId, void) = .empty,

    const done: i64 = -1;

    fn nodeSpan(c: *Ctx, file: FileId, node: Node) Span {
        return c.files[file].tree.span(c.files[file].src, node);
    }

    fn tokSpan(c: *Ctx, file: FileId, tok: TokenIndex) Span {
        const f = &c.files[file];
        const start = f.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(f.src, f.tree.tokens.tag(tok), start) };
    }
};

/// Report TS2303 for every alias declaration on a definition cycle. Appends to
/// `diags` (messages allocated in `arena`) and touches nothing else.
pub fn report(
    arena: Allocator,
    scratch: Allocator,
    gpa: Allocator,
    io: Io,
    interner: *Interner,
    files: []const ProgFile,
    diags: []std.ArrayList(LinkDiag),
) Error!void {
    var c: Ctx = .{
        .arena = arena,
        .scratch = scratch,
        .gpa = gpa,
        .io = io,
        .interner = interner,
        .files = files,
        .diags = diags,
        .atom_default = interner.intern(io, gpa, "default") catch return Error.OutOfMemory,
    };
    try indexBlocks(&c);
    for (files, 0..) |*f, fi| {
        const file: FileId = @intCast(fi);
        for (f.bind.imports) |rec| {
            if (importSite(&c, file, rec)) |s| try walk(&c, s);
        }
        for (f.bind.exports) |rec| {
            if (exportSite(&c, file, rec)) |s| try walk(&c, s);
        }
        for (try entityAliases(&c, file)) |s| try walk(&c, s);
    }
}

/// Group every file's `declare module "spec" { … }` blocks by specifier.
fn indexBlocks(c: *Ctx) Error!void {
    for (c.files, 0..) |*f, fi| {
        for (f.bind.ambient_modules) |am| {
            const gop = try c.blocks.getOrPut(c.scratch, am.spec);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(c.scratch, .{
                .file = @intCast(fi),
                .scope = am.scope,
                .export_start = am.export_start,
                .export_end = am.export_end,
            });
        }
    }
}

// --------------------------------------------------------------- site building

fn importSite(c: *Ctx, file: FileId, rec: bind_result.ImportRec) ?Site {
    const tree = c.files[file].tree;
    const base: Site = .{
        .file = file,
        .node = rec.node,
        .kind = .import_named,
        .name = rec.local,
        .module = rec.module,
        .ref = rec.imported,
        .scope = rec.scope,
    };
    switch (rec.kind) {
        .side_effect => return null,
        .named => return base,
        .equals => {
            var s = base;
            s.kind = .import_require;
            return s;
        },
        .namespace, .default => {
            // The record's node is the whole `import` statement; tsc narrows the
            // span of a NamespaceImport / ImportClause error to its name.
            if (tree.nodeTag(rec.node) != .import_decl) return null;
            const data = tree.extraData(ast.ImportData, tree.nodeData(rec.node).lhs);
            var s = base;
            s.kind = if (rec.kind == .namespace) .import_ns else .import_default;
            s.tok = if (rec.kind == .namespace) data.ns_name_token else data.default_name_token;
            if (s.tok == 0) return null;
            return s;
        },
    }
}

fn exportSite(c: *Ctx, file: FileId, rec: bind_result.ExportRec) ?Site {
    const tree = c.files[file].tree;
    const base: Site = .{
        .file = file,
        .node = rec.node,
        .kind = .export_spec,
        .name = rec.exported,
        .module = rec.module,
        .ref = rec.local,
        .scope = rec.scope,
    };
    switch (rec.kind) {
        // `export *` is not an alias declaration, and `export * as ns` names a
        // module namespace object, which nothing can alias back.
        .reexport_all, .reexport_ns => return null,
        // A DECLARATION carrying an `export` modifier is not an alias; only the
        // `export { … }` specifier form is. `export import X = …` reaches the
        // same node through its import record / the entity scan, so it is left
        // to those (one site per node).
        .named, .ns_named => {
            if (tree.nodeTag(rec.node) != .export_specifier) return null;
            if (rec.local == 0) return null;
            var s = base;
            s.sym = rec.sym;
            return s;
        },
        .reexport_named => {
            if (rec.local == 0 or rec.module == 0) return null;
            var s = base;
            s.kind = .export_from;
            return s;
        },
        .equals => {
            if (rec.local == 0) return null;
            var s = base;
            s.kind = .export_equals;
            // tsc prints the identifier an export assignment names, not the
            // internal `export=`/`default` symbol name (`getNameOfDeclaration`
            // of an ExportAssignment is its expression).
            s.name = rec.local;
            return s;
        },
        .default => {
            // Only the ENTITY-NAME form is an alias — `export default class C {}`
            // declares the class. (`seal` resolves `rec.sym` for both forms, so
            // the symbol cannot tell them apart; the expression can.)
            if (rec.local == 0) return null;
            if (tree.nodeTag(rec.node) != .export_default) return null;
            if (tree.nodeTag(tree.nodeData(rec.node).lhs) != .identifier) return null;
            var s = base;
            s.kind = .export_default;
            s.name = rec.local;
            s.sym = rec.sym;
            return s;
        },
    }
}

/// The file's `import X = Entity` aliases. They carry no import record (there is
/// no module to follow), so they are recovered from the symbols they declare:
/// an import binding whose declaration is an `import_equals` with no specifier.
fn entityAliases(c: *Ctx, file: FileId) Error![]const Site {
    const f = &c.files[file];
    const b = f.bind;
    var out: std.ArrayListUnmanaged(Site) = .empty;
    for (b.symbol_flags, 0..) |flags, si| {
        if (!flags.import_binding) continue;
        const sym: SymbolId = @intCast(si);
        for (b.declsOf(sym)) |decl| {
            if (f.tree.nodeTag(decl) != .import_equals) continue;
            const e = f.tree.extraData(ast.ImportEquals, f.tree.nodeData(decl).lhs);
            if (e.module_token != 0 or e.entity == ast.null_node) continue;
            if (f.tree.nodeTag(e.entity) != .identifier) continue; // qualified: terminal
            const text = f.tree.tokenSlice(f.src, f.tree.nodeMainToken(e.entity));
            const ref = c.interner.intern(c.io, c.gpa, text) catch return Error.OutOfMemory;
            try out.append(c.scratch, .{
                .file = file,
                .node = decl,
                .kind = .import_entity,
                .name = b.symbol_names[sym],
                .ref = ref,
                .scope = b.symbol_scopes[sym],
            });
            break;
        }
    }
    return out.items;
}

// -------------------------------------------------------------------- the walk

/// Follow the single outgoing edge of `start` until the path leaves the graph or
/// meets a site already on it. Every site from the meeting point to the top of
/// the path is on a cycle and reports.
fn walk(c: *Ctx, start: Site) Error!void {
    c.path.clearRetainingCapacity();
    var cur = start;
    while (true) {
        if (c.state.get(cur.key())) |v| {
            // A value other than `done` is an index into the CURRENT path:
            // every site is marked `done` as this loop unwinds.
            if (v != Ctx.done) {
                for (c.path.items[@intCast(v)..]) |s| try emit(c, s);
            }
            break;
        }
        try c.state.put(c.scratch, cur.key(), @intCast(c.path.items.len));
        try c.path.append(c.scratch, cur);
        cur = (try nextSite(c, cur)) orelse break;
    }
    for (c.path.items) |s| try c.state.put(c.scratch, s.key(), Ctx.done);
}

fn emit(c: *Ctx, s: Site) Error!void {
    const span = if (s.tok != 0) c.tokSpan(s.file, s.tok) else c.nodeSpan(s.file, s.node);
    const name = if (s.name == 0) "" else c.interner.lookup(c.io, s.name);
    const msg = try std.fmt.allocPrint(c.arena, "Circular definition of import alias '{s}'.", .{name});
    try c.diags[s.file].append(c.arena, .{ .code = 2303, .span = span, .msg = msg });
}

/// The one alias declaration `s` defines itself in terms of, or null when it
/// reaches a real declaration (or something this pass does not follow).
fn nextSite(c: *Ctx, s: Site) Error!?Site {
    return switch (s.kind) {
        .import_named, .export_from => try namedSite(c, s.file, s.module, s.ref),
        // `import x = require("m")` and `import * as x from "m"` both name the
        // module ENTITY, which for a module with an export assignment is that
        // assignment (tsc's `resolveExternalModuleSymbol`).
        .import_require, .import_ns => try equalsSite(c, s.file, s.module),
        .import_default => (try namedSite(c, s.file, s.module, c.atom_default)) orelse
            try equalsSite(c, s.file, s.module),
        .import_entity, .export_spec, .export_equals, .export_default => localSite(c, s.file, s.scope, s.ref, s.sym),
    };
}

/// The alias declaration that publishes `name` from `module`, as seen from
/// `from`. Null when the name is published by a real declaration, comes from a
/// module this pass does not follow, or is not published at all.
fn namedSite(c: *Ctx, from: FileId, module: Atom, name: Atom) Error!?Site {
    if (module == 0 or name == 0) return null;
    if (moduleFile(c, from, module)) |mfile| {
        c.star_seen.clearRetainingCapacity();
        return try exportedSite(c, mfile, name, star_depth);
    }
    for (blocksOf(c, module)) |blk| {
        const b = c.files[blk.file].bind;
        for (b.exports[blk.export_start..blk.export_end]) |rec| {
            if (rec.exported != name) continue;
            if (exportSite(c, blk.file, rec)) |s| return s;
        }
    }
    return null;
}

/// `namedSite`'s file half: the export record for `name` in `mfile`, following
/// `export *` when the file has no record of its own.
fn exportedSite(c: *Ctx, mfile: FileId, name: Atom, depth: u32) Error!?Site {
    if (depth == 0) return null;
    if ((try c.star_seen.getOrPut(c.scratch, mfile)).found_existing) return null;
    const b = c.files[mfile].bind;
    // Last writer wins, exactly as the linker's export table does.
    var found: ?Site = null;
    var direct = false;
    for (b.exports) |rec| {
        if (rec.exported != name) continue;
        switch (rec.kind) {
            .named, .default, .reexport_named => {},
            else => continue,
        }
        direct = true;
        found = exportSite(c, mfile, rec);
    }
    if (direct) return found;
    for (b.exports) |rec| {
        if (rec.kind != .reexport_all) continue;
        const src = moduleFile(c, mfile, rec.module) orelse continue;
        if (try exportedSite(c, src, name, depth - 1)) |s| return s;
    }
    return null;
}

/// The export assignment of `module`, as seen from `from`.
fn equalsSite(c: *Ctx, from: FileId, module: Atom) Error!?Site {
    if (module == 0) return null;
    if (moduleFile(c, from, module)) |mfile| {
        for (c.files[mfile].bind.exports) |rec| {
            if (rec.kind != .equals or rec.scope != bind_result.file_scope) continue;
            if (exportSite(c, mfile, rec)) |s| return s;
        }
        return null;
    }
    for (blocksOf(c, module)) |blk| {
        const b = c.files[blk.file].bind;
        for (b.exports[blk.export_start..blk.export_end]) |rec| {
            if (rec.kind != .equals or rec.scope != blk.scope) continue;
            if (exportSite(c, blk.file, rec)) |s| return s;
        }
    }
    return null;
}

/// The alias declaration of local `name`, resolved from `scope` outward (or
/// `sym0` when the binder already did it). Null when the name is a real
/// declaration, a global, or unresolved.
fn localSite(c: *Ctx, file: FileId, scope: ScopeId, name: Atom, sym0: SymbolId) ?Site {
    if (name == 0) return null;
    const f = &c.files[file];
    const b = f.bind;
    const sym = if (sym0 != bind_result.no_symbol) sym0 else (b.resolve(name, scope) orelse return null);
    if (!b.symbol_flags[sym].import_binding) return null;
    const home = b.symbol_scopes[sym];
    for (b.imports) |rec| {
        if (rec.local != b.symbol_names[sym] or rec.scope != home) continue;
        return importSite(c, file, rec);
    }
    // No import record: an entity alias (`import X = Entity`).
    for (b.declsOf(sym)) |decl| {
        if (f.tree.nodeTag(decl) != .import_equals) continue;
        const e = f.tree.extraData(ast.ImportEquals, f.tree.nodeData(decl).lhs);
        if (e.module_token != 0 or e.entity == ast.null_node) continue;
        if (f.tree.nodeTag(e.entity) != .identifier) return null;
        const text = f.tree.tokenSlice(f.src, f.tree.nodeMainToken(e.entity));
        const ref = c.interner.intern(c.io, c.gpa, text) catch return null;
        return .{
            .file = file,
            .node = decl,
            .kind = .import_entity,
            .name = b.symbol_names[sym],
            .ref = ref,
            .scope = home,
        };
    }
    return null;
}

/// The program file backing `spec` in `from`, or null when the specifier
/// resolved to nothing. A globally declared ambient module has already claimed
/// its specifier out of every `specs` map (`applyAmbientModulePrecedence`), so
/// tsc's precedence needs nothing extra here — and an AUGMENTATION block must
/// not shadow the real file, which is why this consults `specs` first.
fn moduleFile(c: *Ctx, from: FileId, spec: Atom) ?FileId {
    return c.files[from].specs.get(spec);
}

fn blocksOf(c: *Ctx, spec: Atom) []const Block {
    const list = c.blocks.getPtr(spec) orelse return &.{};
    return list.items;
}
