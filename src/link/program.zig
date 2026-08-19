//! The sealed program: the immutable data contract every checker reads.
//!
//! This is the *shape* half of the link layer — the types the linker fills in
//! (modules.zig) and the checkers read back, with no construction logic of
//! their own beyond the accessors sealed into them. Splitting it out keeps the
//! contract readable on its own and makes the direction of dependency
//! explicit: program.zig knows nothing about how a program is built, while
//! modules.zig (which re-exports every name here, so no consumer changed)
//! knows everything.
//!
//! Everything is immutable after `modules.link`; N checkers read it
//! concurrently without locks (the immutability boundary).

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const source = @import("../frontend/source.zig");
const resolve = @import("resolve.zig");

const Ast = ast.Ast;
const Bind = binder.Bind;
const Atom = intern.Atom;
const Span = source.Span;

pub const Error = error{OutOfMemory};

pub const FileId = u32;
pub const no_file: FileId = std.math.maxInt(FileId);

/// The tsconfig options the *link* phase reads. Both are per-program constants
/// the driver settles before any file is linked; grouping them keeps the two
/// booleans from becoming an unlabelled pair at every call site.
pub const LinkOpts = struct {
    /// tsconfig `allowSyntheticDefaultImports`/`esModuleInterop`: a default
    /// import of a module with no default export binds to the module namespace
    /// object. See `linkImports`.
    allow_synthetic_default: bool = false,
    /// tsconfig `noImplicitAny`. Gates TS7016 ("Could not find a declaration
    /// file for module …"), the link-phase member of the implicit-any family;
    /// the checker gates TS7006/TS7053 on `Program.no_implicit_any`, which the
    /// driver sets from the same option.
    no_implicit_any: bool = true,
    /// tsconfig `noUncheckedSideEffectImports` (default OFF, like tsc). Gates the
    /// unresolved-specifier diagnostic for a side-effect-only import. See
    /// `reportUnresolvedModules`.
    no_unchecked_side_effect_imports: bool = false,
    /// Root identifier of tsconfig `jsxFactory` (see `Program.jsx_factory_ns`).
    /// Carried here only to reach the `Program` the driver builds from these
    /// options; the link phase itself never reads it.
    jsx_factory_ns: ?[]const u8 = null,
    /// tsconfig `types` contains the `"*"` wildcard (tsc's `usesWildcardTypes`).
    /// Only reachable effect: the node-flavoured not-found diagnostics drop
    /// their "and then add 'node' to the types field" tail and become TS2580
    /// instead of TS2591 — with a wildcard list there is no list to add to.
    types_wildcard: bool = false,
    /// tsconfig `experimentalDecorators`. Read only by `buildProgram`'s own
    /// parse (the serial wavefront parses the files it discovers, so it must
    /// know the decorator grammar); the parallel CLI driver parses before it
    /// links and passes the same value to `parseOpts` itself. See
    /// `parser.Opts.experimental_decorators`.
    experimental_decorators: bool = false,
};

/// Everything the serial link phase produces for the sealed program.
pub const LinkResult = struct {
    links: []const FileLinks,
    sym_base: []const u32,
    globals: Globals = .{},
    merged: []const MergedSym = &.{},
    ambient_exports: []const AmbientExport = &.{},
    ambient_specs: []const Atom = &.{},
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
    export_equals_atom: Atom = 0,
    dual_targets: []const DualTarget = &.{},
};

/// The sealed multi-file program handed to the checkers. Everything is
/// immutable after `link`; N checkers read it concurrently without locks.
pub const Program = struct {
    files: []const ProgFile,
    /// files.len+1 prefix sums of per-file symbol counts: global symbol id
    /// = sym_base[file] + local id. Global 0 stays the "no symbol" sentinel.
    sym_base: []const u32,
    /// Per-file link tables; empty slice = unlinked single-file mode
    /// (imports silently type as `any` — used by legacy unit-test paths).
    links: []const FileLinks = &.{},
    /// Lib global symbols (empty when no lib is injected).
    globals: Globals = .{},
    /// Cross-file merged global symbols. Program id of entry `k` is
    /// `totalSymbols() + k`. Empty in the common case (no name has 2+
    /// contributors).
    merged: []const MergedSym = &.{},
    /// Ambient module export tables, indexed by `Target.ambient_ns`
    /// payloads; for `import * as ns from "<ambient>"` namespace objects.
    ambient_exports: []const AmbientExport = &.{},
    /// Specifier atom of each `ambient_exports[i]` (the `declare module`
    /// name/pattern, in registry order). Lets a type-position `import("m")`
    /// resolve against an ambient module by exact or wildcard match.
    ambient_specs: []const Atom = &.{},
    /// Reverse merge index: merge-constituent real id → merged id,
    /// parallel arrays sorted by key. See `mergedOf`.
    constit_keys: []const u32 = &.{},
    constit_vals: []const u32 = &.{},
    /// Reserved atom keying `export = X` entries in export/ambient tables, so
    /// the namespace-object builders can skip it. 0 when no linker ran.
    export_equals_atom: Atom = 0,
    /// Backing store for `Target.dual` payloads: the (value, type) meaning
    /// pair of a name an `export =` module reaches through both halves.
    dual_targets: []const DualTarget = &.{},
    /// Effective `noImplicitAny` (true = on = report). When false, the checker
    /// suppresses the implicit-'any' diagnostic family (TS7006/TS7053); the
    /// affected values still type as `any`. Defaults on (strict semantics); the
    /// driver sets it from the tsconfig. See `tsconfig.Config.no_implicit_any`.
    no_implicit_any: bool = true,
    /// Effective `allowSyntheticDefaultImports`/`esModuleInterop`, as the
    /// CHECKER needs it: `linkImports` uses the linker's own copy for a static
    /// default import, but a DYNAMIC `import("m")` builds its type in the
    /// checker (`importCallType`) and needs the same rule for the `default`
    /// property it hands back. See `LinkOpts.allow_synthetic_default`.
    allow_synthetic_default: bool = false,
    /// Effective `types: [… "*" …]` (tsc's `usesWildcardTypes`). Picks TS2580
    /// over TS2591 for the node-flavoured not-found diagnostics; the checker
    /// reads it in `reportNameNotFound`/`reportModuleNotFound`. See
    /// `tsconfig.Config.types_wildcard`.
    types_wildcard: bool = false,
    /// Effective `experimentalDecorators`. The legacy decorator dialect calls a
    /// decorator as `(target, key, descriptorOrIndex)`, so the checker skips the
    /// standard `(value, context)` signature check (TS1238/1240/1241) when it is
    /// on. See `tsconfig.Config.experimental_decorators`.
    experimental_decorators: bool = false,
    /// The `<jsxImportSource>/jsx-runtime` module under the automatic JSX
    /// runtime (`jsx: "react-jsx"`), or `no_file`. tsc reads the `JSX` namespace
    /// off this module's exports there; the checker falls back to it when no
    /// global `JSX` namespace exists. See `tsconfig.Config.jsx_runtime_module`.
    jsx_runtime_file: FileId = no_file,
    /// The SPECIFIER `jsx_runtime_file` was looked up under
    /// (`"react/jsx-runtime"`, `"preact/jsx-runtime"`, …), or null when the
    /// automatic runtime is off. Kept beside the FileId because the checker
    /// needs the text even — especially — when the lookup FAILED: a JSX tag in
    /// a program whose runtime module does not resolve is TS2875, and the
    /// diagnostic names the path it could not find.
    jsx_runtime_module: ?[]const u8 = null,
    /// The ROOT identifier of tsconfig `jsxFactory` (`MyLib` for
    /// `MyLib.createElement`), or null. tsc's `getJsxNamespaceAt` reads the
    /// `JSX` namespace out of that container (`MyLib.JSX.IntrinsicElements`)
    /// before it falls back to the global one, so a project with an inline
    /// factory and its own local `JSX` namespace types its intrinsic elements
    /// from there. See `tsconfig.Config.jsx_factory_ns`.
    jsx_factory_ns: ?[]const u8 = null,

    /// The automatic-runtime specifier in force in `file`: its own
    /// `@jsxImportSource` pragma when it has one, else the program-wide
    /// setting. Null when the automatic runtime is off for it entirely.
    pub fn jsxRuntimeSpec(p: *const Program, file: FileId) ?[]const u8 {
        if (file < p.files.len) {
            if (p.files[file].jsx_pragma_module) |m| return m;
        }
        return p.jsx_runtime_module;
    }

    /// The file `jsxRuntimeSpec(file)` resolved to, or `no_file`. Paired with
    /// `jsxRuntimeSpec` so the two never disagree about WHICH specifier is
    /// being talked about — a pragma file whose module is missing must not
    /// borrow the program-wide one's resolution.
    pub fn jsxRuntimeFile(p: *const Program, file: FileId) FileId {
        if (file < p.files.len) {
            if (p.files[file].jsx_pragma_module != null) return p.files[file].jsx_pragma_file;
        }
        return p.jsx_runtime_file;
    }

    /// Count of real per-file symbols (merged ids start here).
    pub fn totalSymbols(p: *const Program) u32 {
        return p.sym_base[p.files.len];
    }

    /// If real global id `sym` is a constituent of a cross-file merge, the
    /// merged-range id it folds into; else null. Used so a merged name
    /// referenced from *within* a contributing file (bound to the file-local
    /// declaration, which never reaches the global fallback) still resolves to
    /// the merged view.
    pub fn mergedOf(p: *const Program, sym: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = p.constit_keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.constit_keys[mid] == sym) return p.constit_vals[mid];
            if (p.constit_keys[mid] < sym) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// True for a merged-range symbol id (indexes `merged`, not a file).
    pub fn isMergedId(p: *const Program, sym: u32) bool {
        return sym >= p.totalSymbols();
    }

    /// The merged symbol for a merged-range id.
    pub fn mergedSym(p: *const Program, sym: u32) *const MergedSym {
        return &p.merged[sym - p.totalSymbols()];
    }

    /// Total symbol-id space including the merged range (checker array sizing).
    pub fn symbolSpace(p: *const Program) u32 {
        return p.totalSymbols() + @as(u32, @intCast(p.merged.len));
    }

    /// Bytes of the module graph (spec maps + link tables + sym_base).
    pub fn graphBytes(p: *const Program) usize {
        var n: usize = p.sym_base.len * @sizeOf(u32);
        for (p.files) |*f| {
            n += f.specs.atoms.len * (@sizeOf(Atom) + @sizeOf(FileId));
        }
        for (p.links) |*l| n += l.bytes();
        return n;
    }
};

/// One program file: sealed parse/bind outputs plus its specifier map.
pub const ProgFile = struct {
    path: []const u8,
    src: []const u8,
    tree: *const Ast,
    bind: *const Bind,
    specs: SpecMap = .{},
    /// Unresolved `types=` reference directives, in source order. Recorded by
    /// the driver that discovered the file (only it runs resolution); replayed
    /// as TS2688 by `Linker.reportUnresolvedTypeRefs`.
    type_ref_misses: []const TypeRefMiss = &.{},
    /// This file's own `/* @jsxImportSource X */` pragma, expanded to the
    /// specifier `X/jsx-runtime`, and what it resolved to — null/`no_file` when
    /// the file carries no pragma and the program-wide `jsx_runtime_module`
    /// applies. Read through `Program.jsxRuntimeSpec`/`jsxRuntimeFile`, never
    /// directly: one `.tsx` may pick preact while its neighbour picks react.
    jsx_pragma_module: ?[]const u8 = null,
    jsx_pragma_file: FileId = no_file,
};

/// A `/// <reference … />` in a program file that resolved to nothing. `span`
/// is the directive's name, quotes excluded — where tsc anchors both wordings:
/// TS2688 ("Cannot find type definition file for 'X'") for a `types=`
/// directive, TS6053 ("File 'X' not found.") for a `path=` one. `kind` picks
/// between them, and it is the directive's own kind rather than a code so the
/// recorder never has to know what the reporter says.
pub const TypeRefMiss = struct { name: []const u8, span: Span, kind: resolve.RefDirective.Kind };

/// Turn an unresolved reference directive into its record. `spec` and `pos`
/// both come from `resolve.scanReferences`, which slices the live source
/// buffer, so the name needs no copy: the buffer outlives the program.
pub fn typeRefMiss(ref: resolve.RefDirective) TypeRefMiss {
    return .{
        .name = ref.spec,
        .span = .{ .start = ref.pos, .end = ref.pos + @as(u32, @intCast(ref.spec.len)) },
        .kind = ref.kind,
    };
}

/// Sealed link tables for one file (read-only during check).
pub const FileLinks = struct {
    /// Local import-binding SymbolIds, sorted, with their targets.
    import_locals: []const u32 = &.{},
    import_targets: []const Target = &.{},
    /// Flattened export table sorted by exported-name atom.
    export_atoms: []const Atom = &.{},
    export_targets: []const Target = &.{},
    diags: []const LinkDiag = &.{},

    pub fn importTarget(l: *const FileLinks, local: u32) ?Target {
        var lo: usize = 0;
        var hi: usize = l.import_locals.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (l.import_locals[mid] == local) return l.import_targets[mid];
            if (l.import_locals[mid] < local) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn exportTarget(l: *const FileLinks, atom: Atom) ?Target {
        var lo: usize = 0;
        var hi: usize = l.export_atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (l.export_atoms[mid] == atom) return l.export_targets[mid];
            if (l.export_atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Exact bytes of the sealed link tables.
    pub fn bytes(l: *const FileLinks) usize {
        return l.import_locals.len * (@sizeOf(u32) + @sizeOf(Target)) +
            l.export_atoms.len * (@sizeOf(Atom) + @sizeOf(Target)) +
            l.diags.len * @sizeOf(LinkDiag);
    }
};

/// The final resolution of an imported/exported name.
pub const Target = struct {
    pub const Kind = enum(u8) {
        /// Unresolved (missing module / missing export / out of subset).
        /// The binding types as `any`; the diagnostic was already issued.
        any,
        /// A declaration symbol: `payload` is a local SymbolId in `file`.
        binding,
        /// The module namespace object of `file` (`import * as ns` /
        /// `export * as ns`).
        namespace,
        /// An anonymous `export default <expr>`: `payload` is the
        /// `export_default` node in `file`.
        default_expr,
        /// The namespace object of an ambient module (`import * as ns from
        /// "fs"`): `payload` indexes `Program.ambient_exports`.
        ambient_ns,
        /// A PROPERTY of the value a module exports with `export = <value>`:
        /// `payload` is that value's local SymbolId in `file`, `name` the
        /// property. tsc resolves `import { X } from "m"` against the type of
        /// the export-assigned value when `X` is not an export of the entity
        /// itself — the shape `@types/lodash.debounce` is built on (`import {
        /// debounce } from "lodash"`, where lodash is `export = _` and
        /// `debounce` is a member of `_`'s interface). Only the checker can
        /// answer it: the link phase compares no types.
        export_equals_prop,
        /// A name an `export =` module reaches through BOTH of its halves:
        /// `payload` indexes `Program.dual_targets`. tsc's
        /// `combineValueAndTypeSymbols` — `import { Request } from
        /// "superagent"` finds `Request` as an `interface` of the exported
        /// namespace (the TYPE meaning) *and* as a `Request: typeof SARequest`
        /// property of the exported const's type (the VALUE meaning), and the
        /// binding carries both. A single-meaning Target cannot: with only the
        /// namespace member, `class Test extends Request` is TS2693 and
        /// inherits nothing.
        dual,
    };
    kind: Kind = .any,
    file: FileId = 0,
    payload: u32 = 0,
    /// Property name for `.export_equals_prop`; 0 otherwise.
    name: Atom = 0,
    /// The chain passed through `export type` / `import type` somewhere:
    /// value use of the binding is an error (TS1362-adjacent).
    type_only: bool = false,
};

/// The two meanings of one `.dual` binding. `type_tgt` is the member of the
/// export-assigned entity (interface/class/alias/namespace); `value_tgt` is the
/// `.export_equals_prop` question "property `name` of the export-assigned
/// value's type". The checker answers the value half lazily and falls back to
/// `type_tgt` when the property turns out not to exist — the link phase cannot
/// know, exactly as for a bare `.export_equals_prop`.
pub const DualTarget = struct {
    value_tgt: Target,
    type_tgt: Target,
};

/// A link-phase diagnostic (2307/2305/2613/1192/2304), file-local span.
pub const LinkDiag = struct {
    code: u16,
    span: Span,
    msg: []const u8,
};

/// Module-specifier atom → resolved FileId (or `no_file`), sorted by atom.
pub const SpecMap = struct {
    atoms: []const Atom = &.{},
    files: []const FileId = &.{},

    pub fn get(m: *const SpecMap, atom: Atom) ?FileId {
        var lo: usize = 0;
        var hi: usize = m.atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (m.atoms[mid] == atom) {
                const f = m.files[mid];
                return if (f == no_file) null else f;
            }
            if (m.atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// Global (lib) name table: the top-level declarations of the injected
/// lib file, keyed by name atom, holding GLOBAL SymbolIds. Sorted by atom
/// for binary-search fallback in name resolution (checker `resolveSpace`).
/// Empty when `--noLib` / no lib is injected. A name with a single
/// contributor maps to that contributor's `(file, sym)` global id; a name
/// with 2+ contributors maps to a merged-range id (`≥ totalSymbols()`)
/// indexing `Program.merged`.
pub const Globals = struct {
    atoms: []const Atom = &.{},
    syms: []const u32 = &.{},

    pub fn lookup(g: *const Globals, atom: Atom) ?u32 {
        var lo: usize = 0;
        var hi: usize = g.atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (g.atoms[mid] == atom) return g.syms[mid];
            if (g.atoms[mid] < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// A cross-file merged global symbol. When 2+ files contribute the
/// same global name, the linker allocates one of these; its program id is
/// `totalSymbols() + index` (the merged range). `flags` is the OR of the
/// constituents' flags; `parts` are the constituent GLOBAL SymbolIds (real
/// ids `< totalSymbols()`) in FileId order. Checkers materialize the type by
/// folding each constituent's declarations across files (the type-level twin
/// of within-file merging). Merge remains a symbol-table operation — no types
/// are compared here (invariant: merge symbols, never types).
pub const MergedSym = struct {
    name: Atom,
    flags: binder.SymbolFlags,
    parts: []const u32,
    /// Merged member index for namespace-bearing merges: member name
    /// atom → global sym (itself possibly a merged-range id, so a nested
    /// interface/namespace reopened across files resolves recursively).
    /// Sorted by atom; empty for non-namespace merges (interfaces materialize
    /// to object types, so their members need no symbol-level index).
    members: Globals = .{},
};

/// An ambient module's sealed export table, for `import * as ns`
/// namespace objects. Entries are (export-name atom → Target), atom-sorted.
pub const AmbientExport = struct {
    atoms: []const Atom = &.{},
    targets: []const Target = &.{},
};
