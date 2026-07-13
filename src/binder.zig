//! Per-file binder (M3): symbol tables, scope tree, control-flow graph.
//!
//! Design decisions (ROADMAP.md §2.2, M3):
//!
//! - **Everything is u32 indices in flat arrays**, matching the AST's
//!   data-oriented style. Symbols, scopes, and flow nodes are SoA; the sealed
//!   `Bind` result lives in the per-file arena and is immutable afterwards.
//!   0 is the "none" sentinel throughout (symbol 0 and flow 0 are reserved
//!   dummies; scope 0 is the file scope, which is never a child).
//! - **Scope member maps**: during binding, a single file-wide open-addressed
//!   hash map keyed by `(scope << 32) | atom` handles inserts and duplicate
//!   detection in O(1) — one map per file, not one per scope, so there is no
//!   per-scope HashMap churn. At seal time members are flattened into two
//!   parallel arrays (`member_atoms`, `member_syms`) segmented per scope via
//!   `scope_members_start` (n+1 entries, so `end == start[s+1]`), each
//!   segment **sorted by atom for binary-search lookup**. Sorted-segment
//!   lookup costs 8 bytes/member with zero per-scope allocation; a
//!   per-scope table would pay ~2x for load factor plus per-scope headers.
//! - **Symbols support multiple declarations** (function overloads,
//!   interface-interface merge) via a per-symbol decl list, built during
//!   binding as linked links in scratch and sealed into one flat `decls`
//!   array segmented by `symbol_decls_start` (n+1 entries).
//! - **One symbol per (scope, name)** across value and type space, tsc-style:
//!   `var x; interface x {}` is one symbol with both flags set. Conflicts are
//!   detected with per-kind "excludes" masks (see `DeclKind.excludes`).
//! - **Hoisting**: `var` and (per modern/strict semantics that ES modules
//!   imply) *not* function declarations — functions in blocks bind in the
//!   block. `var` binds in the nearest enclosing function/file scope; the
//!   scopes it hoists past are recorded (`var_transits`) so a later
//!   `let x` in one of those blocks still reports TS2451 regardless of
//!   declaration order. let/const/class bind in the current block and record
//!   their first declaration node for M4's TDZ checks (not checked here).
//! - **Flow graph** modeled on tsc's antecedent-linked flow nodes: `start`,
//!   `assign`, `cond_true`/`cond_false`, `branch_label` (join),
//!   `loop_label` (join with loop-back edges added later), `switch_clause`,
//!   and a single shared `unreachable` node (flow 1). Labels keep antecedent
//!   lists in `flow_extra`; single-antecedent joins collapse to their
//!   antecedent and never allocate a node. Flow ids are attached to
//!   identifier/member reads via a compact (node, flow) map sorted by node —
//!   8 bytes per *reference* instead of 4 bytes per *node* for a full side
//!   array; `flowAt` is a binary search.
//! - Deferred flow precision (documented for M4): `??` and optional chaining
//!   bind linearly (no nullish branch); `continue` joins the loop head
//!   (for `for(;;)` this skips the update's assignments — conservative);
//!   try/catch/finally uses the pre-try state as the catch antecedent and
//!   joins conservatively; default-parameter and `getter/setter` flows are
//!   linear; labeled `continue` falls back to the innermost loop if the
//!   label doesn't name a loop.
//! - Not bound (documented): function/class *expression* names (their
//!   self-references show up as unresolved refs, which M3 treats as
//!   non-errors), computed member names as symbols (the key expression is
//!   still bound), and declaration merging beyond interface-interface
//!   (class+interface pairs merge silently without member merging — the
//!   subset boundary check lands with the checker).
//!
//! Unresolved identifiers are NOT errors in M3 (globals and cross-file
//! imports resolve in M5); they are exposed via `Bind.unresolved`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const intern = @import("intern.zig");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Diagnostic = diagnostics.Diagnostic;
const Code = diagnostics.Code;
const Span = source.Span;

pub const Error = error{OutOfMemory};

/// Index into the symbol arrays. 0 is a reserved dummy ("no symbol").
pub const SymbolId = u32;
pub const no_symbol: SymbolId = 0;

/// Index into the scope arrays. 0 is the file scope.
pub const ScopeId = u32;
pub const file_scope: ScopeId = 0;

/// Index into the flow arrays. 0 = none, 1 = the shared unreachable node.
pub const FlowId = u32;
pub const no_flow: FlowId = 0;
pub const unreachable_flow: FlowId = 1;

pub const ScopeKind = enum(u8) {
    file,
    function,
    block,
    class,
    class_members,
    class_statics,
    interface,
    interface_members,
    type_alias,
    for_head,
    catch_clause,
};

/// Packed symbol flag bitset (4 bytes/symbol).
pub const SymbolFlags = packed struct(u32) {
    var_decl: bool = false,
    let_decl: bool = false,
    const_decl: bool = false,
    function: bool = false,
    class: bool = false,
    interface: bool = false,
    type_alias: bool = false,
    type_param: bool = false,
    param: bool = false,
    catch_param: bool = false,
    property: bool = false,
    method: bool = false,
    getter: bool = false,
    setter: bool = false,
    static_member: bool = false,
    import_binding: bool = false,
    /// `import type` / `export type` binding (type space only).
    type_only: bool = false,
    exported: bool = false,
    export_default: bool = false,
    /// A function/method declaration with a body has been seen.
    has_impl: bool = false,
    optional_member: bool = false,
    readonly_member: bool = false,
    /// `enum` / `const enum` declaration (both a value and a type).
    enum_decl: bool = false,
    _pad: u9 = 0,

    pub fn bits(f: SymbolFlags) u32 {
        return @bitCast(f);
    }
    pub fn merge(a: SymbolFlags, b: SymbolFlags) SymbolFlags {
        return @bitCast(a.bits() | b.bits());
    }
};

fn fbits(comptime f: SymbolFlags) u32 {
    return @bitCast(f);
}

const mask_let_const_class = fbits(.{ .let_decl = true }) | fbits(.{ .const_decl = true }) |
    fbits(.{ .class = true });
const mask_value = fbits(.{ .var_decl = true }) | mask_let_const_class |
    fbits(.{ .function = true }) | fbits(.{ .param = true }) |
    fbits(.{ .catch_param = true }) | fbits(.{ .import_binding = true }) |
    fbits(.{ .enum_decl = true });
const mask_type = fbits(.{ .class = true }) | fbits(.{ .interface = true }) |
    fbits(.{ .type_alias = true }) | fbits(.{ .type_param = true }) |
    fbits(.{ .enum_decl = true });
const mask_member = fbits(.{ .property = true }) | fbits(.{ .method = true }) |
    fbits(.{ .getter = true }) | fbits(.{ .setter = true });

/// What kind of declaration is being bound; determines the flags a new
/// symbol gets and which existing flags it refuses to merge with.
const DeclKind = enum {
    var_decl,
    let_decl,
    const_decl,
    function,
    class,
    interface,
    type_alias,
    enum_decl,
    type_param,
    param,
    catch_param,
    import_value,
    import_type,
    property,
    method,
    getter,
    setter,

    fn flags(k: DeclKind) SymbolFlags {
        return switch (k) {
            .var_decl => .{ .var_decl = true },
            .let_decl => .{ .let_decl = true },
            .const_decl => .{ .const_decl = true },
            .function => .{ .function = true },
            .class => .{ .class = true },
            .interface => .{ .interface = true },
            .type_alias => .{ .type_alias = true },
            .enum_decl => .{ .enum_decl = true },
            .type_param => .{ .type_param = true },
            .param => .{ .param = true },
            .catch_param => .{ .catch_param = true },
            .import_value => .{ .import_binding = true },
            .import_type => .{ .import_binding = true, .type_only = true },
            .property => .{ .property = true },
            .method => .{ .method = true },
            .getter => .{ .getter = true },
            .setter => .{ .setter = true },
        };
    }

    /// Existing-symbol flag bits this declaration kind cannot merge with.
    /// One symbol spans value and type space, so e.g. `var` excludes other
    /// value declarations but not `interface`.
    fn excludes(k: DeclKind) u32 {
        return switch (k) {
            // var+var and var+param merge; everything else valueish clashes.
            .var_decl => mask_value & ~(fbits(.{ .var_decl = true }) | fbits(.{ .param = true })),
            .let_decl, .const_decl => mask_value,
            .function => mask_value & ~fbits(.{ .function = true }),
            .class => (mask_value & ~fbits(.{ .class = true })) |
                (mask_type & ~fbits(.{ .interface = true })),
            .interface => mask_type & ~(fbits(.{ .interface = true }) | fbits(.{ .class = true })),
            .type_alias => mask_type,
            // Two enum blocks (incl. const enum) with the same name merge;
            // everything else in value or type space clashes.
            .enum_decl => (mask_value | mask_type) & ~fbits(.{ .enum_decl = true }),
            .type_param => mask_type & ~fbits(.{ .class = true }),
            .param => mask_value & ~fbits(.{ .var_decl = true }),
            .catch_param => mask_value,
            .import_value => mask_value | mask_type,
            .import_type => mask_type | fbits(.{ .import_binding = true }),
            .property => mask_member,
            .method => mask_member & ~fbits(.{ .method = true }),
            .getter => mask_member & ~fbits(.{ .setter = true }),
            .setter => mask_member & ~fbits(.{ .getter = true }),
        };
    }

    fn isBlockScoped(k: DeclKind) bool {
        return switch (k) {
            .let_decl, .const_decl, .class => true,
            else => false,
        };
    }

    fn isTypeOnly(k: DeclKind) bool {
        return switch (k) {
            .interface, .type_alias, .type_param, .import_type => true,
            else => false,
        };
    }
};

pub const FlowTag = enum(u8) {
    /// Reserved index 0.
    none,
    /// Shared "code cannot reach here" node (index 1).
    unreachable_,
    /// Function/file entry. b = owning AST node.
    start,
    /// After an assignment/initialization/++/--/for-of binding.
    /// a = antecedent, b = the assigning AST node.
    assign,
    /// Condition took the true branch. a = antecedent, b = condition node.
    cond_true,
    /// Condition took the false branch. a = antecedent, b = condition node.
    cond_false,
    /// Join point. a..b = antecedent list range in `flow_extra`.
    branch_label,
    /// Loop head join (has loop-back antecedents). a..b = range in extra.
    loop_label,
    /// Reached a switch clause. a = antecedent (pre-switch flow),
    /// b = case/default clause node.
    switch_clause,
};

pub const ImportKind = enum(u8) { default, namespace, named, side_effect };
pub const ExportKind = enum(u8) { named, default, reexport_named, reexport_all, reexport_ns };

/// One imported binding; feeds M5's module graph.
pub const ImportRec = struct {
    /// Local binding name (0 for side-effect imports).
    local: Atom,
    /// Name in the source module ("default", "*", or the named export).
    imported: Atom,
    /// Module specifier string contents (no quotes).
    module: Atom,
    /// The import_decl node (for M5 diagnostics).
    node: Node,
    kind: ImportKind,
    type_only: bool,
};

/// One exported binding; feeds M5's module graph.
pub const ExportRec = struct {
    /// External name ("default" for default exports, 0 for `export *`).
    exported: Atom,
    /// Local name (or source-module name for re-exports; 0 if none).
    local: Atom,
    /// Module specifier for re-exports, 0 otherwise.
    module: Atom,
    /// Locally-bound symbol (0 for re-exports / anonymous default).
    sym: SymbolId,
    /// The export_* node (for M5 diagnostics).
    node: Node,
    kind: ExportKind,
    type_only: bool,
};

/// An identifier reference that did not resolve in-file (usually a global
/// or a name M5 will resolve; not an error in M3).
pub const Ref = struct {
    atom: Atom,
    node: Node,
    scope: ScopeId,
};

/// The sealed bind result for one file. All slices live in the per-file
/// arena; nothing is freed individually and nothing mutates after `bind`.
pub const Bind = struct {
    // --- symbols (SoA; index 0 is a reserved dummy) -----------------------
    symbol_names: []const Atom,
    symbol_flags: []const SymbolFlags,
    symbol_scopes: []const ScopeId,
    /// n+1 entries; symbol i's decl nodes are decls[start[i]..start[i+1]].
    symbol_decls_start: []const u32,
    symbol_decls: []const Node,

    // --- scopes (SoA; index 0 is the file scope) --------------------------
    scope_parents: []const ScopeId,
    scope_kinds: []const ScopeKind,
    /// AST node that introduced the scope (0/root for the file scope).
    scope_owners: []const Node,
    /// n+1 entries; scope s's members are member_*[start[s]..start[s+1]],
    /// sorted by atom within the segment.
    scope_members_start: []const u32,
    member_atoms: []const Atom,
    member_syms: []const SymbolId,

    /// Class/interface symbol -> members scope, sorted by symbol id.
    member_scope_syms: []const SymbolId,
    member_scope_ids: []const ScopeId,
    /// Class symbol -> statics scope, sorted by symbol id.
    static_scope_syms: []const SymbolId,
    static_scope_ids: []const ScopeId,

    // --- flow graph (SoA; 0 = none, 1 = shared unreachable) ---------------
    flow_tags: []const FlowTag,
    flow_a: []const u32,
    flow_b: []const u32,
    /// Antecedent lists for branch/loop labels.
    flow_extra: []const FlowId,
    /// Compact node -> flow attachment map, sorted by node.
    flow_map_nodes: []const Node,
    flow_map_ids: []const FlowId,

    imports: []const ImportRec,
    exports: []const ExportRec,
    /// References that did not resolve in-file, in traversal order.
    unresolved: []const Ref,
    diagnostics: []const Diagnostic,

    // --- name resolution ---------------------------------------------------

    /// Look `atom` up in exactly one scope (binary search of the sealed,
    /// atom-sorted member segment).
    pub fn lookupInScope(b: *const Bind, scope: ScopeId, atom: Atom) ?SymbolId {
        var lo = b.scope_members_start[scope];
        var hi = b.scope_members_start[scope + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const a = b.member_atoms[mid];
            if (a == atom) return b.member_syms[mid];
            if (a < atom) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Resolve `atom` starting at `scope`, walking the parent chain.
    /// Value/type space is not distinguished in M3 (the checker filters by
    /// symbol flags in M4). Returns null when unresolved (not an error).
    pub fn resolve(b: *const Bind, atom: Atom, scope: ScopeId) ?SymbolId {
        var s = scope;
        while (true) {
            if (b.lookupInScope(s, atom)) |sym| return sym;
            if (s == file_scope) return null;
            s = b.scope_parents[s];
        }
    }

    /// Members scope of a class/interface symbol (instance side), if any.
    pub fn membersScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.member_scope_syms, b.member_scope_ids, sym);
    }

    /// Statics scope of a class symbol, if any.
    pub fn staticsScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.static_scope_syms, b.static_scope_ids, sym);
    }

    fn searchPair(keys: []const u32, vals: []const u32, key: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keys[mid] == key) return vals[mid];
            if (keys[mid] < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Decl nodes of a symbol.
    pub fn declsOf(b: *const Bind, sym: SymbolId) []const Node {
        return b.symbol_decls[b.symbol_decls_start[sym]..b.symbol_decls_start[sym + 1]];
    }

    // --- flow queries --------------------------------------------------------

    /// Flow node attached to an AST node (identifier/member reads), if any.
    pub fn flowAt(b: *const Bind, node: Node) ?FlowId {
        var lo: usize = 0;
        var hi: usize = b.flow_map_nodes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const n = b.flow_map_nodes[mid];
            if (n == node) return b.flow_map_ids[mid];
            if (n < node) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Antecedent flow ids of `flow` (0 or 1 entries for non-labels).
    pub fn flowAntecedents(b: *const Bind, flow: FlowId) []const FlowId {
        return switch (b.flow_tags[flow]) {
            .branch_label, .loop_label => b.flow_extra[b.flow_a[flow]..b.flow_b[flow]],
            .none, .unreachable_, .start => b.flow_extra[0..0],
            else => b.flow_a[flow .. flow + 1], // single antecedent, stored in a
        };
    }

    /// The AST node a flow node references (assign/condition/switch), or 0.
    pub fn flowNode(b: *const Bind, flow: FlowId) Node {
        return switch (b.flow_tags[flow]) {
            .assign, .cond_true, .cond_false, .switch_clause, .start => b.flow_b[flow],
            else => 0,
        };
    }

    // --- memory accounting ---------------------------------------------------

    /// Exact bytes of the sealed symbol arrays.
    pub fn symbolBytes(b: *const Bind) usize {
        return b.symbol_names.len * (@sizeOf(Atom) + @sizeOf(SymbolFlags) + @sizeOf(ScopeId)) +
            b.symbol_decls_start.len * @sizeOf(u32) + b.symbol_decls.len * @sizeOf(Node);
    }

    /// Exact bytes of the sealed scope tree + member maps.
    pub fn scopeBytes(b: *const Bind) usize {
        return b.scope_parents.len * (@sizeOf(ScopeId) + @sizeOf(ScopeKind) + @sizeOf(Node)) +
            b.scope_members_start.len * @sizeOf(u32) +
            b.member_atoms.len * (@sizeOf(Atom) + @sizeOf(SymbolId)) +
            b.member_scope_syms.len * 2 * @sizeOf(u32) +
            b.static_scope_syms.len * 2 * @sizeOf(u32);
    }

    /// Exact bytes of the sealed flow graph + node attachment map.
    pub fn flowBytes(b: *const Bind) usize {
        return b.flow_tags.len * (@sizeOf(FlowTag) + 2 * @sizeOf(u32)) +
            b.flow_extra.len * @sizeOf(FlowId) +
            b.flow_map_nodes.len * (@sizeOf(Node) + @sizeOf(FlowId));
    }

    /// Exact bytes of import/export/unresolved records.
    pub fn recordBytes(b: *const Bind) usize {
        return b.imports.len * @sizeOf(ImportRec) + b.exports.len * @sizeOf(ExportRec) +
            b.unresolved.len * @sizeOf(Ref);
    }

    pub fn totalBytes(b: *const Bind) usize {
        return b.symbolBytes() + b.scopeBytes() + b.flowBytes() + b.recordBytes();
    }

    pub fn symbolCount(b: *const Bind) usize {
        return b.symbol_names.len - 1; // minus reserved dummy
    }
    pub fn scopeCount(b: *const Bind) usize {
        return b.scope_parents.len;
    }
    pub fn flowCount(b: *const Bind) usize {
        return b.flow_tags.len - 2; // minus none + unreachable
    }

    // --- stable text dump (--dump-symbols, golden tests) -------------------

    pub fn dump(
        b: *const Bind,
        io: Io,
        interner: *Interner,
        tree: *const Ast,
        src: []const u8,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try b.dumpScope(io, interner, tree, src, w, file_scope, 0);

        var n_start: usize = 0;
        var n_assign: usize = 0;
        var n_cond: usize = 0;
        var n_branch: usize = 0;
        var n_loop: usize = 0;
        var n_switch: usize = 0;
        for (b.flow_tags) |t| switch (t) {
            .start => n_start += 1,
            .assign => n_assign += 1,
            .cond_true, .cond_false => n_cond += 1,
            .branch_label => n_branch += 1,
            .loop_label => n_loop += 1,
            .switch_clause => n_switch += 1,
            .none, .unreachable_ => {},
        };
        try w.print(
            "flow: nodes={d} attach={d} (start={d} assign={d} cond={d} branch={d} loop={d} switch={d})\n",
            .{ b.flowCount(), b.flow_map_nodes.len, n_start, n_assign, n_cond, n_branch, n_loop, n_switch },
        );

        for (b.imports) |rec| {
            try w.print("import local={s} imported={s} from=\"{s}\" {s}{s}\n", .{
                atomText(io, interner, rec.local),
                atomText(io, interner, rec.imported),
                atomText(io, interner, rec.module),
                @tagName(rec.kind),
                if (rec.type_only) " type-only" else "",
            });
        }
        for (b.exports) |rec| {
            try w.print("export exported={s} local={s}", .{
                atomText(io, interner, rec.exported),
                atomText(io, interner, rec.local),
            });
            if (rec.module != 0) try w.print(" from=\"{s}\"", .{atomText(io, interner, rec.module)});
            try w.print(" {s}{s}\n", .{
                @tagName(rec.kind),
                if (rec.type_only) " type-only" else "",
            });
        }

        if (b.unresolved.len > 0) {
            try w.writeAll("unresolved:");
            // Aggregate by atom in first-seen order (O(n^2), test-sized).
            var i: usize = 0;
            while (i < b.unresolved.len) : (i += 1) {
                const atom = b.unresolved[i].atom;
                var seen_before = false;
                for (b.unresolved[0..i]) |r| {
                    if (r.atom == atom) {
                        seen_before = true;
                        break;
                    }
                }
                if (seen_before) continue;
                var count: usize = 0;
                for (b.unresolved[i..]) |r| {
                    if (r.atom == atom) count += 1;
                }
                try w.print(" {s}({d})", .{ atomText(io, interner, atom), count });
            }
            try w.writeAll("\n");
        }
    }

    fn atomText(io: Io, interner: *Interner, atom: Atom) []const u8 {
        if (atom == 0) return "-";
        return interner.lookup(io, atom);
    }

    fn dumpScope(
        b: *const Bind,
        io: Io,
        interner: *Interner,
        tree: *const Ast,
        src: []const u8,
        w: *std.Io.Writer,
        scope: ScopeId,
        depth: usize,
    ) std.Io.Writer.Error!void {
        try w.splatByteAll(' ', depth * 2);
        try w.print("scope {d}: {s}", .{ scope, @tagName(b.scope_kinds[scope]) });
        if (scopeName(tree, src, b.scope_kinds[scope], b.scope_owners[scope])) |name| {
            try w.print(" {s}", .{name});
        }
        try w.writeAll("\n");

        // Symbols in creation (source) order — deterministic across runs
        // even though atoms (and thus member-array order) are not.
        for (1..b.symbol_names.len) |i| {
            if (b.symbol_scopes[i] != scope) continue;
            try w.splatByteAll(' ', depth * 2 + 2);
            try w.print("{s}:", .{atomText(io, interner, b.symbol_names[i])});
            try dumpFlags(w, b.symbol_flags[i]);
            const n_decls = b.symbol_decls_start[i + 1] - b.symbol_decls_start[i];
            if (n_decls > 1) try w.print(" decls={d}", .{n_decls});
            try w.writeAll("\n");
        }

        for (1..b.scope_parents.len) |child| {
            if (b.scope_parents[child] != scope) continue;
            try b.dumpScope(io, interner, tree, src, w, @intCast(child), depth + 1);
        }
    }

    fn scopeName(tree: *const Ast, src: []const u8, kind: ScopeKind, owner: Node) ?[]const u8 {
        if (owner == 0) return null;
        const d = tree.nodeData(owner);
        const name_tok: TokenIndex = switch (tree.nodeTag(owner)) {
            .function_decl, .function_expr, .class_method, .method_signature => tree.extraData(ast.FnProto, d.lhs).name_token,
            .class_decl => tree.extraData(ast.ClassData, d.lhs).name_token,
            .interface_decl => tree.extraData(ast.InterfaceData, d.lhs).name_token,
            .type_alias => tree.extraData(ast.TypeAlias, d.lhs).name_token,
            else => 0,
        };
        _ = kind;
        if (name_tok == 0) return null;
        return tree.tokenSlice(src, name_tok);
    }

    fn dumpFlags(w: *std.Io.Writer, f: SymbolFlags) std.Io.Writer.Error!void {
        const names = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = fbits(.{ .var_decl = true }), .name = "var" },
            .{ .bit = fbits(.{ .let_decl = true }), .name = "let" },
            .{ .bit = fbits(.{ .const_decl = true }), .name = "const" },
            .{ .bit = fbits(.{ .function = true }), .name = "function" },
            .{ .bit = fbits(.{ .class = true }), .name = "class" },
            .{ .bit = fbits(.{ .interface = true }), .name = "interface" },
            .{ .bit = fbits(.{ .type_alias = true }), .name = "type" },
            .{ .bit = fbits(.{ .type_param = true }), .name = "type-param" },
            .{ .bit = fbits(.{ .param = true }), .name = "param" },
            .{ .bit = fbits(.{ .catch_param = true }), .name = "catch" },
            .{ .bit = fbits(.{ .property = true }), .name = "property" },
            .{ .bit = fbits(.{ .method = true }), .name = "method" },
            .{ .bit = fbits(.{ .getter = true }), .name = "get" },
            .{ .bit = fbits(.{ .setter = true }), .name = "set" },
            .{ .bit = fbits(.{ .static_member = true }), .name = "static" },
            .{ .bit = fbits(.{ .import_binding = true }), .name = "import" },
            .{ .bit = fbits(.{ .type_only = true }), .name = "type-only" },
            .{ .bit = fbits(.{ .exported = true }), .name = "exported" },
            .{ .bit = fbits(.{ .export_default = true }), .name = "default" },
            .{ .bit = fbits(.{ .has_impl = true }), .name = "impl" },
            .{ .bit = fbits(.{ .optional_member = true }), .name = "optional" },
            .{ .bit = fbits(.{ .readonly_member = true }), .name = "readonly" },
        };
        for (names) |n| {
            if (f.bits() & n.bit != 0) try w.print(" {s}", .{n.name});
        }
    }
};

/// Bind a sealed parse tree. Output goes into `arena` (the per-file binder
/// arena) and is sealed on return; internal scratch is freed before
/// returning. `interner`/`io`/`gpa` follow the shared-interner contract
/// (gpa must be thread-safe when binding files in parallel).
/// Total on arbitrary parser output: never fails except on OOM.
pub fn bind(
    arena: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,
) Error!Bind {
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();

    var b: Binder = .{
        .arena = arena,
        .scratch = scratch_arena.allocator(),
        .io = io,
        .gpa = gpa,
        .interner = interner,
        .tree = tree,
        .src = src,
    };

    // Reserved entries (0-sentinel style, like the AST).
    try b.sym_names.append(b.scratch, 0);
    try b.sym_flags.append(b.scratch, .{});
    try b.sym_scopes.append(b.scratch, 0);
    try b.sym_decl_head.append(b.scratch, 0);
    try b.sym_decl_tail.append(b.scratch, 0);
    try b.sym_decl_count.append(b.scratch, 0);
    try b.decl_links.append(b.scratch, .{ .value = 0, .next = 0 });
    try b.ante_links.append(b.scratch, .{ .value = 0, .next = 0 });

    try b.scope_parents.append(b.scratch, 0);
    try b.scope_kinds.append(b.scratch, .file);
    try b.scope_owners.append(b.scratch, 0);

    try b.addFlowRaw(.none, 0, 0); // flow 0
    try b.addFlowRaw(.unreachable_, 0, 0); // flow 1
    b.cur_flow = try b.addFlow(.start, no_flow, 0); // file entry

    // Bind all top-level statements of the root.
    for (tree.nodeRange(0)) |stmt| {
        if (stmt != null_node) try b.bindStatement(stmt);
    }

    return b.seal();
}

const Link = struct { value: u32, next: u32 };
const Pending = struct { head: u32 = 0, tail: u32 = 0, count: u32 = 0 };
const PendingId = u32;

const CtxKind = enum(u8) { loop, switch_blk, labeled };
const Ctx = struct {
    kind: CtxKind,
    label: Atom = 0,
    /// Pending join for `break` targets.
    brk: PendingId,
    /// Pending join for `continue` targets (loops only).
    cont: PendingId = 0,
};

const CondFlows = struct { t: FlowId, f: FlowId };

const Binder = struct {
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    gpa: Allocator,
    interner: *Interner,
    tree: *const Ast,
    src: []const u8,

    // symbols under construction (scratch)
    sym_names: std.ArrayList(Atom) = .empty,
    sym_flags: std.ArrayList(SymbolFlags) = .empty,
    sym_scopes: std.ArrayList(ScopeId) = .empty,
    sym_decl_head: std.ArrayList(u32) = .empty,
    sym_decl_tail: std.ArrayList(u32) = .empty,
    sym_decl_count: std.ArrayList(u32) = .empty,
    decl_links: std.ArrayList(Link) = .empty,

    // scopes under construction
    scope_parents: std.ArrayList(ScopeId) = .empty,
    scope_kinds: std.ArrayList(ScopeKind) = .empty,
    scope_owners: std.ArrayList(Node) = .empty,
    /// The active scope chain as an explicit stack (for var-hoist checks).
    scope_stack: std.ArrayList(ScopeId) = .empty,
    /// One map for the whole file: (scope << 32 | atom) -> symbol.
    members: std.AutoHashMapUnmanaged(u64, SymbolId) = .empty,
    /// (scope, atom) pairs a `var` hoisted past, for order-independent
    /// var-vs-let conflict detection.
    var_transits: std.ArrayList(Link) = .empty, // value=scope, next=atom (reused shape)
    /// class/interface symbol -> members scope (merge reuses it).
    member_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,
    static_scopes: std.AutoHashMapUnmanaged(SymbolId, ScopeId) = .empty,

    // flow under construction
    flow_tags: std.ArrayList(FlowTag) = .empty,
    flow_a: std.ArrayList(u32) = .empty,
    flow_b: std.ArrayList(u32) = .empty,
    pendings: std.ArrayList(Pending) = .empty,
    ante_links: std.ArrayList(Link) = .empty,
    flow_pairs: std.ArrayList(Link) = .empty, // value=node, next=flow

    refs: std.ArrayList(Ref) = .empty,
    import_recs: std.ArrayList(ImportRec) = .empty,
    export_recs: std.ArrayList(ExportRec) = .empty,
    diags: std.ArrayList(Diagnostic) = .empty,
    /// Per-file atom cache so repeated identifiers don't hit the shared
    /// (mutex-guarded) interner more than once each.
    atom_cache: std.StringHashMapUnmanaged(Atom) = .empty,

    cur_scope: ScopeId = file_scope,
    var_scope: ScopeId = file_scope,
    cur_flow: FlowId = no_flow,
    ctxs: std.ArrayList(Ctx) = .empty,
    /// Contexts below this index belong to enclosing functions.
    ctx_base: usize = 0,
    /// Set by a labeled statement wrapping a loop/switch.
    pending_label: Atom = 0,
    /// True while binding the name(s) of an `export`ed declaration.
    exporting_node: Node = 0,

    // --- small helpers ------------------------------------------------------

    fn atomOf(b: *Binder, text: []const u8) Error!Atom {
        const gop = try b.atom_cache.getOrPut(b.scratch, text);
        if (!gop.found_existing) {
            gop.value_ptr.* = try b.interner.intern(b.io, b.gpa, text);
        }
        return gop.value_ptr.*;
    }

    fn tokenText(b: *Binder, tok: TokenIndex) []const u8 {
        return b.tree.tokenSlice(b.src, tok);
    }

    /// Atom of an identifier-ish token.
    fn atomOfToken(b: *Binder, tok: TokenIndex) Error!Atom {
        return b.atomOf(b.tokenText(tok));
    }

    /// Atom of a member/property name token; string keys lose their quotes
    /// so `"a"` and `a` name the same member. (Escapes are not decoded in
    /// M3 — the corpus subset does not rely on escaped member names.)
    fn memberAtom(b: *Binder, tok: TokenIndex) Error!Atom {
        const text = b.tokenText(tok);
        if (b.tree.tokens.tag(tok) == .string_literal) return b.atomOf(stripQuotes(text));
        return b.atomOf(text);
    }

    /// Atom of a module-specifier string token (contents without quotes).
    fn moduleAtom(b: *Binder, tok: TokenIndex) Error!Atom {
        if (tok == 0) return 0;
        return b.atomOf(stripQuotes(b.tokenText(tok)));
    }

    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
            const last = text[text.len - 1];
            if (last == text[0]) return text[1 .. text.len - 1];
            return text[1..];
        }
        if (text.len >= 1 and (text[0] == '"' or text[0] == '\'')) return text[1..];
        return text;
    }

    fn tokSpan(b: *Binder, tok: TokenIndex) Span {
        const start = b.tree.tokens.start(tok);
        return .{ .start = start, .end = scanner.tokenEnd(b.src, b.tree.tokens.tag(tok), start) };
    }

    fn diag(b: *Binder, code: Code, tok: TokenIndex) Error!void {
        try b.diags.append(b.scratch, .{ .code = code, .span = b.tokSpan(tok) });
    }

    fn nodeTag(b: *const Binder, node: Node) ast.Tag {
        return b.tree.nodeTag(node);
    }

    // --- scopes -----------------------------------------------------------

    fn newScope(b: *Binder, kind: ScopeKind, owner: Node, parent: ScopeId) Error!ScopeId {
        const id: ScopeId = @intCast(b.scope_parents.items.len);
        try b.scope_parents.append(b.scratch, parent);
        try b.scope_kinds.append(b.scratch, kind);
        try b.scope_owners.append(b.scratch, owner);
        return id;
    }

    /// Create a scope as a child of the current one and enter it.
    fn pushScope(b: *Binder, kind: ScopeKind, owner: Node) Error!ScopeId {
        const id = try b.newScope(kind, owner, b.cur_scope);
        try b.scope_stack.append(b.scratch, id);
        b.cur_scope = id;
        return id;
    }

    fn popScope(b: *Binder, to: ScopeId) void {
        while (b.scope_stack.items.len > 0 and
            b.scope_stack.items[b.scope_stack.items.len - 1] != to)
        {
            _ = b.scope_stack.pop();
        }
        b.cur_scope = to;
    }

    const SavedState = struct {
        cur_scope: ScopeId,
        var_scope: ScopeId,
        cur_flow: FlowId,
        ctx_base: usize,
        ctx_len: usize,
        stack_len: usize,
    };

    fn saveState(b: *Binder) SavedState {
        return .{
            .cur_scope = b.cur_scope,
            .var_scope = b.var_scope,
            .cur_flow = b.cur_flow,
            .ctx_base = b.ctx_base,
            .ctx_len = b.ctxs.items.len,
            .stack_len = b.scope_stack.items.len,
        };
    }

    fn restoreState(b: *Binder, s: SavedState) void {
        b.cur_scope = s.cur_scope;
        b.var_scope = s.var_scope;
        b.cur_flow = s.cur_flow;
        b.ctx_base = s.ctx_base;
        b.ctxs.items.len = s.ctx_len;
        b.scope_stack.items.len = s.stack_len;
    }

    // --- symbols ------------------------------------------------------------

    fn appendDecl(b: *Binder, sym: SymbolId, node: Node) Error!void {
        const link: u32 = @intCast(b.decl_links.items.len);
        try b.decl_links.append(b.scratch, .{ .value = node, .next = 0 });
        if (b.sym_decl_head.items[sym] == 0) {
            b.sym_decl_head.items[sym] = link;
        } else {
            b.decl_links.items[b.sym_decl_tail.items[sym]].next = link;
        }
        b.sym_decl_tail.items[sym] = link;
        b.sym_decl_count.items[sym] += 1;
    }

    fn memberKey(scope: ScopeId, atom: Atom) u64 {
        return (@as(u64, scope) << 32) | atom;
    }

    /// Flag bits used for the excludes check. A type-only import occupies
    /// the *type* space only, so `import type { T } ...; let T;` merges
    /// without error while `type T = ...` still clashes with it.
    fn effectiveBits(f: SymbolFlags) u32 {
        var bits = f.bits();
        if (f.import_binding and f.type_only) {
            bits &= ~fbits(.{ .import_binding = true });
            bits |= fbits(.{ .type_alias = true });
        }
        return bits;
    }

    /// Pick the diagnostic code for a declaration that failed the excludes
    /// check against `existing`. Choices documented in the module header;
    /// golden-tested against the codes tsc reports for the common cases.
    fn dupCode(existing: SymbolFlags, kind: DeclKind) Code {
        if (existing.catch_param) return .catch_redeclare;
        const e_import = existing.import_binding;
        const n_import = kind == .import_value or kind == .import_type;
        if (e_import != n_import) return .import_conflict;
        if (e_import and n_import) return .duplicate_identifier;
        // Pure type-space collisions are plain duplicates.
        if (kind.isTypeOnly() or (existing.bits() & mask_value) == 0)
            return .duplicate_identifier;
        if (kind == .class and existing.class) return .duplicate_identifier;
        if (kind.isBlockScoped() or (existing.bits() & mask_let_const_class) != 0)
            return .block_scoped_redeclare;
        return .duplicate_identifier;
    }

    /// Declare `atom` in `scope`. Merges with an existing symbol when the
    /// excludes masks allow it (overloads, interface merge, var+var, value/
    /// type-space sharing); reports a diagnostic at `name_tok` otherwise
    /// (the *later* declaration site, one diagnostic per clash).
    fn declare(
        b: *Binder,
        scope: ScopeId,
        atom: Atom,
        kind: DeclKind,
        decl_node: Node,
        name_tok: TokenIndex,
        extra_flags: SymbolFlags,
    ) Error!SymbolId {
        const flags = kind.flags().merge(extra_flags);

        // Hoisted var: check the scopes it hoists past for block-scoped
        // clashes, and record transits for later `let`s (order-independent).
        if (kind == .var_decl and scope != b.cur_scope) {
            var i = b.scope_stack.items.len;
            while (i > 0) {
                i -= 1;
                const s = b.scope_stack.items[i];
                if (s == scope) break;
                if (b.members.get(memberKey(s, atom))) |sym| {
                    if (b.sym_flags.items[sym].bits() & mask_let_const_class != 0) {
                        try b.diag(.block_scoped_redeclare, name_tok);
                    }
                }
                try b.var_transits.append(b.scratch, .{ .value = s, .next = atom });
            }
        }
        // Block-scoped decl: a var declared *inside* this scope's subtree
        // (already hoisted out) still clashes.
        if (kind.isBlockScoped()) {
            for (b.var_transits.items) |t| {
                if (t.value == scope and t.next == atom) {
                    try b.diag(.block_scoped_redeclare, name_tok);
                    break;
                }
            }
        }

        const gop = try b.members.getOrPut(b.scratch, memberKey(scope, atom));
        if (gop.found_existing) {
            const sym = gop.value_ptr.*;
            const existing = b.sym_flags.items[sym];
            if (effectiveBits(existing) & kind.excludes() != 0) {
                try b.diag(dupCode(existing, kind), name_tok);
            } else if (kind == .function or kind == .method) {
                // Overload grouping: at most one implementation.
                if (flags.has_impl and existing.has_impl) {
                    try b.diag(.duplicate_function_implementation, name_tok);
                }
            }
            b.sym_flags.items[sym] = existing.merge(flags);
            try b.appendDecl(sym, decl_node);
            try b.noteExport(sym, atom, scope);
            return sym;
        }

        const sym: SymbolId = @intCast(b.sym_names.items.len);
        try b.sym_names.append(b.scratch, atom);
        try b.sym_flags.append(b.scratch, flags);
        try b.sym_scopes.append(b.scratch, scope);
        try b.sym_decl_head.append(b.scratch, 0);
        try b.sym_decl_tail.append(b.scratch, 0);
        try b.sym_decl_count.append(b.scratch, 0);
        gop.value_ptr.* = sym;
        try b.appendDecl(sym, decl_node);
        try b.noteExport(sym, atom, scope);
        return sym;
    }

    /// While binding the names of `export <decl>`, emit an export record
    /// for each name bound in the file scope.
    fn noteExport(b: *Binder, sym: SymbolId, atom: Atom, scope: ScopeId) Error!void {
        if (b.exporting_node == 0 or scope != file_scope) return;
        if (b.sym_flags.items[sym].exported) return; // one record per symbol
        b.sym_flags.items[sym].exported = true;
        try b.export_recs.append(b.scratch, .{
            .exported = atom,
            .local = atom,
            .module = 0,
            .sym = sym,
            .node = b.exporting_node,
            .kind = .named,
            .type_only = false,
        });
    }

    // --- flow -----------------------------------------------------------------

    fn addFlowRaw(b: *Binder, tag: FlowTag, a: u32, bb: u32) Error!void {
        try b.flow_tags.append(b.scratch, tag);
        try b.flow_a.append(b.scratch, a);
        try b.flow_b.append(b.scratch, bb);
    }

    fn addFlow(b: *Binder, tag: FlowTag, antecedent: FlowId, node: Node) Error!FlowId {
        const id: FlowId = @intCast(b.flow_tags.items.len);
        try b.addFlowRaw(tag, antecedent, node);
        return id;
    }

    fn newPending(b: *Binder) Error!PendingId {
        const id: PendingId = @intCast(b.pendings.items.len);
        try b.pendings.append(b.scratch, .{});
        return id;
    }

    /// Add an antecedent to a pending join; unreachable and duplicate
    /// antecedents are skipped (tsc does the same).
    fn pendAdd(b: *Binder, pid: PendingId, flow: FlowId) Error!void {
        if (flow == no_flow or flow == unreachable_flow) return;
        const p = &b.pendings.items[pid];
        var l = p.head;
        while (l != 0) : (l = b.ante_links.items[l].next) {
            if (b.ante_links.items[l].value == flow) return;
        }
        const link: u32 = @intCast(b.ante_links.items.len);
        try b.ante_links.append(b.scratch, .{ .value = flow, .next = 0 });
        if (p.head == 0) p.head = link else b.ante_links.items[p.tail].next = link;
        p.tail = link;
        p.count += 1;
    }

    /// Turn a pending join into a flow id: 0 antecedents -> unreachable,
    /// 1 -> pass through, else a branch_label (a holds the pending id until
    /// seal() rewrites it into a flow_extra range).
    fn finishPending(b: *Binder, pid: PendingId) Error!FlowId {
        const p = b.pendings.items[pid];
        if (p.count == 0) return unreachable_flow;
        if (p.count == 1) return b.ante_links.items[p.head].value;
        return b.addFlow(.branch_label, pid, 0);
    }

    /// A loop head must exist before its back edges do, so it is created
    /// eagerly with its own pending antecedent list.
    fn newLoopLabel(b: *Binder) Error!FlowId {
        const pid = try b.newPending();
        return b.addFlow(.loop_label, pid, 0);
    }

    fn addLoopAntecedent(b: *Binder, label: FlowId, flow: FlowId) Error!void {
        try b.pendAdd(b.flow_a.items[label], flow);
    }

    fn attachFlow(b: *Binder, node: Node) Error!void {
        try b.flow_pairs.append(b.scratch, .{ .value = node, .next = b.cur_flow });
    }

    // --- control-flow contexts (break/continue targets) -----------------------

    fn findBreakCtx(b: *Binder, label: Atom) ?*Ctx {
        var i = b.ctxs.items.len;
        while (i > b.ctx_base) {
            i -= 1;
            const c = &b.ctxs.items[i];
            if (label != 0) {
                if (c.label == label) return c;
            } else if (c.kind != .labeled) {
                return c;
            }
        }
        return null;
    }

    fn findContinueCtx(b: *Binder, label: Atom) ?*Ctx {
        var i = b.ctxs.items.len;
        var fallback: ?*Ctx = null;
        while (i > b.ctx_base) {
            i -= 1;
            const c = &b.ctxs.items[i];
            if (c.kind != .loop) continue;
            if (label == 0 or c.label == label) return c;
            if (fallback == null) fallback = c; // documented fallback
        }
        return fallback;
    }

    fn takePendingLabel(b: *Binder) Atom {
        const l = b.pending_label;
        b.pending_label = 0;
        return l;
    }

    // --- statements -------------------------------------------------------------

    fn bindStatement(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .block => {
                const saved = b.cur_scope;
                _ = try b.pushScope(.block, node);
                for (b.tree.nodeRange(node)) |stmt| try b.bindStatement(stmt);
                b.popScope(saved);
            },
            .var_decl_one, .var_decl => try b.bindVarDecl(node),
            .expr_stmt => try b.bindExpr(d.lhs),
            .empty_stmt, .debugger_stmt, .error_node, .unsupported, .omitted => {},

            .if_stmt => {
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindStatement(d.rhs);
                const after_then = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, cond.f);
                b.cur_flow = try b.finishPending(pid);
            },
            .if_else_stmt => {
                const e = b.tree.extraData(ast.IfElse, d.rhs);
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindStatement(e.then_stmt);
                const after_then = b.cur_flow;
                b.cur_flow = cond.f;
                try b.bindStatement(e.else_stmt);
                const after_else = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, after_else);
                b.cur_flow = try b.finishPending(pid);
            },
            .while_stmt => try b.bindWhile(node, d.lhs, d.rhs),
            .do_stmt => try b.bindDoWhile(node, d.lhs, d.rhs),
            .for_stmt => try b.bindFor(node),
            .for_in_stmt, .for_of_stmt => try b.bindForInOf(node),
            .switch_stmt => try b.bindSwitch(node),
            .try_stmt => try b.bindTry(node),
            .throw_stmt => {
                try b.bindExpr(d.lhs);
                b.cur_flow = unreachable_flow;
            },
            .return_stmt => {
                try b.bindExpr(d.lhs);
                b.cur_flow = unreachable_flow;
            },
            .break_stmt => {
                const label: Atom = if (d.lhs != 0) try b.atomOfToken(d.lhs) else 0;
                if (b.findBreakCtx(label)) |ctx| try b.pendAdd(ctx.brk, b.cur_flow);
                b.cur_flow = unreachable_flow;
            },
            .continue_stmt => {
                const label: Atom = if (d.lhs != 0) try b.atomOfToken(d.lhs) else 0;
                if (b.findContinueCtx(label)) |ctx| try b.pendAdd(ctx.cont, b.cur_flow);
                b.cur_flow = unreachable_flow;
            },
            .labeled_stmt => try b.bindLabeled(node),

            .function_decl => try b.bindFunctionDecl(node),
            .class_decl => try b.bindClass(node, true),
            .interface_decl => try b.bindInterface(node),
            .type_alias => try b.bindTypeAlias(node),
            .enum_decl => try b.bindEnum(node),
            .import_decl => try b.bindImport(node),
            .export_decl => {
                const saved = b.exporting_node;
                b.exporting_node = node;
                try b.bindStatement(d.lhs);
                b.exporting_node = saved;
            },
            .export_default => try b.bindExportDefault(node),
            .export_named => try b.bindExportNamed(node),
            .export_all => try b.bindExportAll(node),

            // Anything else in statement position (recovery leftovers) is
            // bound as an expression — keeps the binder total.
            else => try b.bindExpr(node),
        }
    }

    fn bindLabeled(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const label = try b.atomOfToken(b.tree.nodeMainToken(node));
        switch (b.nodeTag(d.lhs)) {
            // The loop/switch consumes the label into its own context.
            .while_stmt, .do_stmt, .for_stmt, .for_in_stmt, .for_of_stmt, .switch_stmt => {
                b.pending_label = label;
                try b.bindStatement(d.lhs);
                b.pending_label = 0;
            },
            else => {
                const brk = try b.newPending();
                try b.ctxs.append(b.scratch, .{ .kind = .labeled, .label = label, .brk = brk });
                try b.bindStatement(d.lhs);
                _ = b.ctxs.pop();
                try b.pendAdd(brk, b.cur_flow);
                b.cur_flow = try b.finishPending(brk);
            },
        }
    }

    const LoopCtx = struct { brk: PendingId, cont: PendingId };

    fn pushLoopCtx(b: *Binder, label: Atom) Error!LoopCtx {
        const brk = try b.newPending();
        const cont = try b.newPending();
        try b.ctxs.append(b.scratch, .{
            .kind = .loop,
            .label = label,
            .brk = brk,
            .cont = cont,
        });
        return .{ .brk = brk, .cont = cont };
    }

    fn bindWhile(b: *Binder, node: Node, cond_node: Node, body: Node) Error!void {
        _ = node;
        // Capture the label before binding sub-expressions, so a label never
        // leaks into a loop nested inside the condition.
        const label = b.takePendingLabel();
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        const cond = try b.bindCondition(cond_node);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        b.cur_flow = cond.t;
        try b.bindStatement(body);
        _ = b.ctxs.pop();
        try b.pendAdd(cont, b.cur_flow);
        try b.addLoopAntecedent(loop, try b.finishPending(cont));
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
    }

    fn bindDoWhile(b: *Binder, node: Node, body: Node, cond_node: Node) Error!void {
        _ = node;
        const label = b.takePendingLabel();
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        try b.bindStatement(body);
        _ = b.ctxs.pop();
        // continue targets the condition check.
        try b.pendAdd(cont, b.cur_flow);
        b.cur_flow = try b.finishPending(cont);
        const cond = try b.bindCondition(cond_node);
        try b.addLoopAntecedent(loop, cond.t);
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
    }

    fn bindFor(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.For, d.lhs);
        const label = b.takePendingLabel();
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.for_head, node);

        if (e.init != 0) {
            switch (b.nodeTag(e.init)) {
                .var_decl_one, .var_decl => try b.bindVarDecl(e.init),
                else => try b.bindExpr(e.init),
            }
        }
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        var cond: CondFlows = .{ .t = loop, .f = unreachable_flow }; // for(;;)
        if (e.cond != 0) cond = try b.bindCondition(e.cond);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        b.cur_flow = cond.t;
        try b.bindStatement(d.rhs);
        _ = b.ctxs.pop();
        // continue joins before the update expression runs.
        try b.pendAdd(cont, b.cur_flow);
        b.cur_flow = try b.finishPending(cont);
        if (e.update != 0) try b.bindExpr(e.update);
        try b.addLoopAntecedent(loop, b.cur_flow);
        try b.pendAdd(brk, cond.f);
        b.cur_flow = try b.finishPending(brk);
        b.popScope(saved_scope);
    }

    fn bindForInOf(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.ForInOf, d.lhs);
        const label = b.takePendingLabel();
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.for_head, node);

        try b.bindExpr(e.right); // evaluated once, before the loop
        const loop = try b.newLoopLabel();
        try b.addLoopAntecedent(loop, b.cur_flow);
        b.cur_flow = loop;
        // The per-iteration element binding is an assignment for narrowing.
        switch (b.nodeTag(e.left)) {
            .var_decl_one, .var_decl => try b.bindVarDecl(e.left),
            else => try b.bindExpr(e.left),
        }
        b.cur_flow = try b.addFlow(.assign, b.cur_flow, e.left);
        const ctx = try b.pushLoopCtx(label);
        const brk = ctx.brk;
        const cont = ctx.cont;
        try b.bindStatement(d.rhs);
        _ = b.ctxs.pop();
        try b.pendAdd(cont, b.cur_flow);
        try b.addLoopAntecedent(loop, try b.finishPending(cont));
        // Loop exit: iteration may not run at all -> exit from the loop head.
        try b.pendAdd(brk, loop);
        b.cur_flow = try b.finishPending(brk);
        b.popScope(saved_scope);
    }

    fn bindSwitch(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const label = b.takePendingLabel();
        try b.bindExpr(d.lhs);
        const pre = b.cur_flow;
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.block, node); // one case-block scope for all clauses

        const brk = try b.newPending();
        try b.ctxs.append(b.scratch, .{
            .kind = .switch_blk,
            .label = label,
            .brk = brk,
        });
        var has_default = false;
        var prev: FlowId = unreachable_flow; // fallthrough from previous clause
        const r = b.tree.extraData(ast.SubRange, d.rhs);
        for (b.tree.extraRange(r.start, r.end)) |clause| {
            if (clause == null_node) continue;
            const ctag = b.nodeTag(clause);
            if (ctag == .default_clause) has_default = true;
            const cd = b.tree.nodeData(clause);
            if (ctag == .case_clause and cd.lhs != 0) {
                b.cur_flow = pre;
                try b.bindExpr(cd.lhs); // case test expression
            }
            const clause_flow = try b.addFlow(.switch_clause, pre, clause);
            const pid = try b.newPending();
            try b.pendAdd(pid, prev); // fallthrough (skipped if unreachable)
            try b.pendAdd(pid, clause_flow);
            b.cur_flow = try b.finishPending(pid);
            if (ctag == .case_clause or ctag == .default_clause) {
                const cr = b.tree.extraData(ast.SubRange, cd.rhs);
                for (b.tree.extraRange(cr.start, cr.end)) |stmt| try b.bindStatement(stmt);
            }
            prev = b.cur_flow;
        }
        _ = b.ctxs.pop();
        try b.pendAdd(brk, prev);
        if (!has_default) try b.pendAdd(brk, pre); // no clause matched
        b.cur_flow = try b.finishPending(brk);
        b.popScope(saved_scope);
    }

    fn bindTry(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const e = b.tree.extraData(ast.Try, d.rhs);
        const pre = b.cur_flow;
        try b.bindStatement(d.lhs); // try block
        const after_try = b.cur_flow;

        var after_catch: FlowId = unreachable_flow;
        if (e.catch_clause != 0) {
            // Conservative: the catch body starts from the pre-try state
            // (any prefix of the try block may have run).
            b.cur_flow = pre;
            const cd = b.tree.nodeData(e.catch_clause);
            const saved_scope = b.cur_scope;
            _ = try b.pushScope(.catch_clause, e.catch_clause);
            if (cd.lhs != 0) try b.bindCatchBinding(cd.lhs);
            // The catch body's statements bind directly in the catch scope so
            // `catch (e) { let e; }` is caught (TS2492).
            if (cd.rhs != 0 and b.nodeTag(cd.rhs) == .block) {
                for (b.tree.nodeRange(cd.rhs)) |stmt| try b.bindStatement(stmt);
            } else {
                try b.bindStatement(cd.rhs);
            }
            b.popScope(saved_scope);
            after_catch = b.cur_flow;
        }

        const pid = try b.newPending();
        try b.pendAdd(pid, after_try);
        try b.pendAdd(pid, after_catch);
        var joined = try b.finishPending(pid);
        if (e.finally_block != 0) {
            // Conservative: the finally body may also run mid-try.
            const fp = try b.newPending();
            try b.pendAdd(fp, pre);
            try b.pendAdd(fp, joined);
            b.cur_flow = try b.finishPending(fp);
            try b.bindStatement(e.finally_block);
            joined = b.cur_flow;
        }
        b.cur_flow = joined;
    }

    fn bindCatchBinding(b: *Binder, binding: Node) Error!void {
        switch (b.nodeTag(binding)) {
            .declarator_full => {
                const d = b.tree.nodeData(binding);
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, .catch_param, binding);
                try b.bindType(e.type_ann);
            },
            .declarator => {
                try b.bindPattern(b.tree.nodeData(binding).lhs, .catch_param, binding);
            },
            else => try b.bindPattern(binding, .catch_param, binding),
        }
    }

    // --- declarations ------------------------------------------------------------

    fn declKindOfVar(b: *Binder, node: Node) DeclKind {
        return switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
            .keyword_const => .const_decl,
            .keyword_let => .let_decl,
            else => .var_decl,
        };
    }

    fn bindVarDecl(b: *Binder, node: Node) Error!void {
        const kind = b.declKindOfVar(node);
        const d = b.tree.nodeData(node);
        if (b.nodeTag(node) == .var_decl_one) {
            try b.bindDeclarator(d.lhs, kind);
        } else {
            for (b.tree.nodeRange(node)) |decl| {
                if (decl != null_node) try b.bindDeclarator(decl, kind);
            }
        }
    }

    fn bindDeclarator(b: *Binder, node: Node, kind: DeclKind) Error!void {
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .declarator => try b.bindPattern(d.lhs, kind, node),
            .declarator_init => {
                try b.bindPattern(d.lhs, kind, node);
                try b.bindExpr(d.rhs);
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
            },
            .declarator_full => {
                const e = b.tree.extraData(ast.DeclaratorFull, d.rhs);
                try b.bindPattern(d.lhs, kind, node);
                try b.bindType(e.type_ann);
                if (e.init != 0) {
                    try b.bindExpr(e.init);
                    b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                }
            },
            else => {}, // recovery leftovers
        }
    }

    /// Declare all names bound by a pattern. `var` names go to the nearest
    /// function/file scope; everything else binds in the current scope.
    fn bindPattern(b: *Binder, node: Node, kind: DeclKind, decl_node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, .{});
            },
            .array_pattern, .object_pattern => {
                for (b.tree.nodeRange(node)) |el| try b.bindPattern(el, kind, decl_node);
            },
            .binding_default => {
                try b.bindPattern(d.lhs, kind, decl_node);
                try b.bindExpr(d.rhs);
            },
            .rest_element => try b.bindPattern(d.lhs, kind, decl_node),
            .binding_property => {
                if (d.lhs != 0) {
                    // `key: target` — the key is a property name, not a binding.
                    try b.bindPattern(d.lhs, kind, decl_node);
                } else {
                    // Shorthand `{ a }` (possibly with a default) binds the key.
                    const tok = b.tree.nodeMainToken(node);
                    const target = if (kind == .var_decl) b.var_scope else b.cur_scope;
                    _ = try b.declare(target, try b.atomOfToken(tok), kind, decl_node, tok, .{});
                }
                if (d.rhs != 0) try b.bindExpr(d.rhs); // default initializer
            },
            .omitted, .error_node, .unsupported => {},
            else => {}, // not a pattern (recovery); no bindings
        }
    }

    fn bindFunctionDecl(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const proto = b.tree.extraData(ast.FnProto, d.lhs);
        if (proto.name_token != 0) {
            const atom = try b.atomOfToken(proto.name_token);
            const flags: SymbolFlags = .{ .has_impl = d.rhs != 0 };
            _ = try b.declare(b.cur_scope, atom, .function, node, proto.name_token, flags);
        }
        try b.bindFunctionLike(node, d.lhs, d.rhs, false);
    }

    /// Shared by function declarations/expressions, arrows, methods, and
    /// function types. Creates the function scope (params + body top-level
    /// share it, so `function f(x) { let x }` clashes) and a fresh `start`
    /// flow for the body. `is_ctor` adds parameter properties.
    fn bindFunctionLike(b: *Binder, node: Node, proto_idx: u32, body: Node, is_ctor: bool) Error!void {
        const proto = b.tree.extraData(ast.FnProto, proto_idx);
        const saved = b.saveState();
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;

        const s = try b.pushScope(.function, node);
        b.var_scope = s;
        b.ctx_base = b.ctxs.items.len;

        try b.bindTypeParams(proto.tp_start, proto.tp_end);
        for (b.tree.extraRange(proto.params_start, proto.params_end)) |param| {
            try b.bindParam(param, is_ctor);
        }
        try b.bindType(proto.return_type);

        if (body != 0) {
            b.cur_flow = try b.addFlow(.start, no_flow, node);
            if (b.nodeTag(body) == .block) {
                // Body statements bind directly in the function scope.
                for (b.tree.nodeRange(body)) |stmt| try b.bindStatement(stmt);
            } else {
                try b.bindExpr(body); // arrow expression body
            }
        }
        b.restoreState(saved);
    }

    fn bindTypeParams(b: *Binder, start: u32, end: u32) Error!void {
        for (b.tree.extraRange(start, end)) |tp| {
            if (tp == null_node or b.nodeTag(tp) != .type_param) continue;
            const tok = b.tree.nodeMainToken(tp);
            _ = try b.declare(b.cur_scope, try b.atomOfToken(tok), .type_param, tp, tok, .{});
            const d = b.tree.nodeData(tp);
            try b.bindType(d.lhs); // constraint
            try b.bindType(d.rhs); // default
        }
    }

    fn bindParam(b: *Binder, node: Node, is_ctor: bool) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .param => {
                try b.bindPattern(d.lhs, .param, node);
                try b.bindType(d.rhs);
            },
            .param_full => {
                const e = b.tree.extraData(ast.ParamFull, d.rhs);
                try b.bindPattern(d.lhs, .param, node);
                try b.bindType(e.type_ann);
                try b.bindExpr(e.init);
                // Constructor parameter property: also a class member.
                const prop_mask = ast.Flags.public | ast.Flags.private |
                    ast.Flags.protected | ast.Flags.readonly;
                if (is_ctor and e.flags & prop_mask != 0 and
                    b.nodeTag(d.lhs) == .identifier)
                {
                    const class_scope = b.scope_parents.items[b.cur_scope];
                    if (b.memberScopeOfClassScope(class_scope)) |ms| {
                        const tok = b.tree.nodeMainToken(d.lhs);
                        _ = try b.declare(ms, try b.atomOfToken(tok), .property, node, tok, .{
                            .readonly_member = e.flags & ast.Flags.readonly != 0,
                        });
                    }
                }
            },
            else => try b.bindPattern(node, .param, node),
        }
    }

    /// Find the class_members scope hanging off a class scope.
    fn memberScopeOfClassScope(b: *Binder, class_scope: ScopeId) ?ScopeId {
        var s: ScopeId = class_scope + 1;
        while (s < b.scope_parents.items.len) : (s += 1) {
            if (b.scope_parents.items[s] == class_scope and
                b.scope_kinds.items[s] == .class_members) return s;
        }
        return null;
    }

    fn bindClass(b: *Binder, node: Node, declare_name: bool) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ClassData, d.lhs);
        var class_sym: SymbolId = no_symbol;
        if (declare_name and data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            class_sym = try b.declare(b.cur_scope, atom, .class, node, data.name_token, .{});
        }
        const saved = b.saveState();
        const clear_export = b.exporting_node;
        b.exporting_node = 0;
        defer b.exporting_node = clear_export;

        const cs = try b.pushScope(.class, node);
        try b.bindTypeParams(data.tp_start, data.tp_end);

        if (data.extends != 0) try b.bindHeritage(data.extends, true);
        for (b.tree.extraRange(data.impl_start, data.impl_end)) |h| {
            if (h != null_node) try b.bindHeritage(h, false);
        }

        const ms = try b.newScope(.class_members, node, cs);
        const ss = try b.newScope(.class_statics, node, cs);
        if (class_sym != no_symbol) {
            try b.member_scopes.put(b.scratch, class_sym, ms);
            try b.static_scopes.put(b.scratch, class_sym, ss);
        }

        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node) continue;
            const md = b.tree.nodeData(member);
            switch (b.nodeTag(member)) {
                .class_field => {
                    const f = b.tree.extraData(ast.Field, md.lhs);
                    const is_static = f.flags & ast.Flags.static != 0;
                    const tok = b.tree.nodeMainToken(member);
                    _ = try b.declare(if (is_static) ss else ms, try b.memberAtom(tok), .property, member, tok, .{
                        .static_member = is_static,
                        .optional_member = f.flags & ast.Flags.optional != 0,
                        .readonly_member = f.flags & ast.Flags.readonly != 0,
                    });
                    try b.bindType(f.type_ann);
                    try b.bindExpr(f.init);
                },
                .class_method => {
                    const proto = b.tree.extraData(ast.FnProto, md.lhs);
                    const is_static = proto.flags & ast.Flags.static != 0;
                    const is_get = proto.flags & ast.Flags.get != 0;
                    const is_set = proto.flags & ast.Flags.set != 0;
                    const tok = b.tree.nodeMainToken(member);
                    const atom = try b.memberAtom(tok);
                    const kind: DeclKind = if (is_get) .getter else if (is_set) .setter else .method;
                    _ = try b.declare(if (is_static) ss else ms, atom, kind, member, tok, .{
                        .static_member = is_static,
                        .has_impl = md.rhs != 0 and !is_get and !is_set,
                    });
                    const is_ctor = b.tree.tokens.tag(tok) == .keyword_constructor and !is_static;
                    try b.bindFunctionLike(member, md.lhs, md.rhs, is_ctor);
                },
                .error_node, .unsupported => {},
                else => {},
            }
        }
        b.restoreState(saved);
    }

    /// `extends`/`implements` entry: `extends` is a value read (with flow),
    /// `implements` is a type reference; type arguments are types either way.
    fn bindHeritage(b: *Binder, node: Node, is_value: bool) Error!void {
        const d = b.tree.nodeData(node);
        if (is_value) {
            try b.bindExpr(d.lhs);
        } else {
            try b.bindTypeName(d.lhs);
        }
        if (d.rhs != 0) {
            const r = b.tree.extraData(ast.SubRange, d.rhs);
            for (b.tree.extraRange(r.start, r.end)) |arg| try b.bindType(arg);
        }
    }

    /// An enum declares one symbol (a value and a type). Member names live in
    /// the enum's value object, materialized by the checker from the AST; the
    /// binder only declares the enum symbol and binds member initializers in
    /// the enclosing scope (so references in `A = expr` resolve/flow normally).
    fn bindEnum(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.EnumData, d.lhs);
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            _ = try b.declare(b.cur_scope, atom, .enum_decl, node, data.name_token, .{});
        }
        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node or b.nodeTag(member) != .enum_member) continue;
            try b.bindExpr(b.tree.nodeData(member).lhs); // optional initializer
        }
    }

    fn bindInterface(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.InterfaceData, d.lhs);
        var sym: SymbolId = no_symbol;
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            sym = try b.declare(b.cur_scope, atom, .interface, node, data.name_token, .{});
        }
        const saved_scope = b.cur_scope;
        const is = try b.pushScope(.interface, node);
        try b.bindTypeParams(data.tp_start, data.tp_end);
        for (b.tree.extraRange(data.extends_start, data.extends_end)) |h| {
            if (h != null_node) try b.bindHeritage(h, false);
        }

        // Interface-interface merge within a file shares one members scope.
        var ms: ScopeId = 0;
        if (sym != no_symbol) {
            if (b.member_scopes.get(sym)) |existing| {
                ms = existing;
            } else {
                ms = try b.newScope(.interface_members, node, is);
                try b.member_scopes.put(b.scratch, sym, ms);
            }
        } else {
            ms = try b.newScope(.interface_members, node, is);
        }

        for (b.tree.extraRange(data.members_start, data.members_end)) |member| {
            if (member == null_node) continue;
            try b.bindTypeMember(member, ms);
        }
        b.popScope(saved_scope);
    }

    /// A member of an interface or object-type literal.
    fn bindTypeMember(b: *Binder, member: Node, ms: ScopeId) Error!void {
        const md = b.tree.nodeData(member);
        switch (b.nodeTag(member)) {
            .property_signature => {
                const tok = b.tree.nodeMainToken(member);
                _ = try b.declare(ms, try b.memberAtom(tok), .property, member, tok, .{
                    .optional_member = md.rhs & ast.Flags.optional != 0,
                    .readonly_member = md.rhs & ast.Flags.readonly != 0,
                });
                try b.bindType(md.lhs);
            },
            .method_signature => {
                const tok = b.tree.nodeMainToken(member);
                _ = try b.declare(ms, try b.memberAtom(tok), .method, member, tok, .{});
                try b.bindFunctionType(member, md.lhs);
            },
            .index_signature => {
                const e = b.tree.extraData(ast.IndexSig, md.lhs);
                try b.bindType(e.key_type);
                try b.bindType(e.value_type);
            },
            .error_node, .unsupported => {},
            else => {},
        }
    }

    fn bindTypeAlias(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.TypeAlias, d.lhs);
        if (data.name_token != 0) {
            const atom = try b.atomOfToken(data.name_token);
            _ = try b.declare(b.cur_scope, atom, .type_alias, node, data.name_token, .{});
        }
        if (data.tp_start != data.tp_end) {
            const saved_scope = b.cur_scope;
            _ = try b.pushScope(.type_alias, node);
            try b.bindTypeParams(data.tp_start, data.tp_end);
            try b.bindType(d.rhs);
            b.popScope(saved_scope);
        } else {
            try b.bindType(d.rhs);
        }
    }

    // --- imports & exports ----------------------------------------------------

    fn bindImport(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ImportData, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const decl_type_only = data.flags & ast.Flags.type_only != 0;
        var any_binding = false;

        if (data.default_name_token != 0) {
            any_binding = true;
            const atom = try b.atomOfToken(data.default_name_token);
            const kind: DeclKind = if (decl_type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, atom, kind, node, data.default_name_token, .{});
            try b.import_recs.append(b.scratch, .{
                .local = atom,
                .imported = try b.atomOf("default"),
                .module = module,
                .node = node,
                .kind = .default,
                .type_only = decl_type_only,
            });
        }
        if (data.ns_name_token != 0) {
            any_binding = true;
            const atom = try b.atomOfToken(data.ns_name_token);
            const kind: DeclKind = if (decl_type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, atom, kind, node, data.ns_name_token, .{});
            try b.import_recs.append(b.scratch, .{
                .local = atom,
                .imported = try b.atomOf("*"),
                .module = module,
                .node = node,
                .kind = .namespace,
                .type_only = decl_type_only,
            });
        }
        for (b.tree.extraRange(data.spec_start, data.spec_end)) |spec| {
            if (spec == null_node or b.nodeTag(spec) != .import_specifier) continue;
            any_binding = true;
            const sd = b.tree.nodeData(spec);
            const imported_tok = b.tree.nodeMainToken(spec);
            const local_tok = if (sd.lhs != 0) sd.lhs else imported_tok;
            const type_only = decl_type_only or sd.rhs & ast.Flags.type_only != 0;
            const imported = try b.memberAtom(imported_tok);
            const local = try b.atomOfToken(local_tok);
            const kind: DeclKind = if (type_only) .import_type else .import_value;
            _ = try b.declare(b.cur_scope, local, kind, spec, local_tok, .{});
            try b.import_recs.append(b.scratch, .{
                .local = local,
                .imported = imported,
                .module = module,
                .node = spec,
                .kind = .named,
                .type_only = type_only,
            });
        }
        if (!any_binding and module != 0) {
            try b.import_recs.append(b.scratch, .{
                .local = 0,
                .imported = 0,
                .module = module,
                .node = node,
                .kind = .side_effect,
                .type_only = false,
            });
        }
    }

    fn bindExportDefault(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const inner = d.lhs;
        var local: Atom = 0;
        var sym: SymbolId = no_symbol;
        switch (b.nodeTag(inner)) {
            .function_decl => {
                const proto = b.tree.extraData(ast.FnProto, b.tree.nodeData(inner).lhs);
                if (proto.name_token != 0) local = try b.atomOfToken(proto.name_token);
                try b.bindStatement(inner);
                if (local != 0) sym = b.members.get(memberKey(b.cur_scope, local)) orelse no_symbol;
            },
            .class_decl => {
                const data = b.tree.extraData(ast.ClassData, b.tree.nodeData(inner).lhs);
                if (data.name_token != 0) local = try b.atomOfToken(data.name_token);
                try b.bindStatement(inner);
                if (local != 0) sym = b.members.get(memberKey(b.cur_scope, local)) orelse no_symbol;
            },
            else => try b.bindExpr(inner),
        }
        if (sym != no_symbol) {
            b.sym_flags.items[sym].exported = true;
            b.sym_flags.items[sym].export_default = true;
        }
        try b.export_recs.append(b.scratch, .{
            .exported = try b.atomOf("default"),
            .local = local,
            .module = 0,
            .sym = sym,
            .node = node,
            .kind = .default,
            .type_only = false,
        });
    }

    fn bindExportNamed(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ExportNamed, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const decl_type_only = data.flags & ast.Flags.type_only != 0;
        for (b.tree.extraRange(data.spec_start, data.spec_end)) |spec| {
            if (spec == null_node or b.nodeTag(spec) != .export_specifier) continue;
            const sd = b.tree.nodeData(spec);
            const local_tok = b.tree.nodeMainToken(spec);
            const local = try b.memberAtom(local_tok);
            const exported = if (sd.lhs != 0) try b.memberAtom(sd.lhs) else local;
            const type_only = decl_type_only or sd.rhs & ast.Flags.type_only != 0;
            try b.export_recs.append(b.scratch, .{
                .exported = exported,
                .local = local,
                .module = module,
                .sym = no_symbol, // local exports resolved at seal
                .node = spec,
                .kind = if (module != 0) .reexport_named else .named,
                .type_only = type_only,
            });
        }
    }

    fn bindExportAll(b: *Binder, node: Node) Error!void {
        const d = b.tree.nodeData(node);
        const data = b.tree.extraData(ast.ExportAll, d.lhs);
        const module = try b.moduleAtom(d.rhs);
        const ns: Atom = if (data.name_token != 0) try b.atomOfToken(data.name_token) else 0;
        try b.export_recs.append(b.scratch, .{
            .exported = ns,
            .local = 0,
            .module = module,
            .sym = no_symbol,
            .node = node,
            .kind = if (ns != 0) .reexport_ns else .reexport_all,
            .type_only = data.flags & ast.Flags.type_only != 0,
        });
    }

    // --- expressions -------------------------------------------------------------

    /// Bind an expression subtree: record identifier references (with flow
    /// attachment), assignments (flow), branches (flow), and nested
    /// function/class scopes. Total on any tree shape.
    fn bindExpr(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => try b.bindIdentifierRef(node),
            .member_expr, .optional_member_expr => {
                try b.bindExpr(d.lhs);
                // Narrowable reference (`x.y` discriminants): attach flow.
                try b.attachFlow(node);
            },
            .assign => {
                try b.bindExpr(d.lhs);
                try b.bindExpr(d.rhs);
                b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
            },
            .prefix_unary, .postfix_unary => {
                try b.bindExpr(d.lhs);
                switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                    .plus_plus, .minus_minus => {
                        b.cur_flow = try b.addFlow(.assign, b.cur_flow, node);
                    },
                    else => {},
                }
            },
            .binary => {
                switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                    .amp_amp, .pipe_pipe => {
                        // Value position: bind as condition, then join.
                        const cond = try b.bindCondition(node);
                        const pid = try b.newPending();
                        try b.pendAdd(pid, cond.t);
                        try b.pendAdd(pid, cond.f);
                        b.cur_flow = try b.finishPending(pid);
                    },
                    else => {
                        try b.bindExpr(d.lhs);
                        try b.bindExpr(d.rhs);
                    },
                }
            },
            .cond_expr => {
                const e = b.tree.extraData(ast.CondExpr, d.rhs);
                const cond = try b.bindCondition(d.lhs);
                b.cur_flow = cond.t;
                try b.bindExpr(e.then_expr);
                const after_then = b.cur_flow;
                b.cur_flow = cond.f;
                try b.bindExpr(e.else_expr);
                const after_else = b.cur_flow;
                const pid = try b.newPending();
                try b.pendAdd(pid, after_then);
                try b.pendAdd(pid, after_else);
                b.cur_flow = try b.finishPending(pid);
            },
            .as_expr, .satisfies_expr => {
                try b.bindExpr(d.lhs);
                try b.bindType(d.rhs);
            },
            .call_expr_targs, .optional_call, .new_expr_targs => {
                try b.bindExpr(d.lhs);
                const info = b.tree.extraData(ast.CallInfo, d.rhs);
                for (b.tree.extraRange(info.targs_start, info.targs_end)) |t| try b.bindType(t);
                for (b.tree.extraRange(info.args_start, info.args_end)) |a| try b.bindExpr(a);
            },
            .object_literal => {
                for (b.tree.nodeRange(node)) |prop| {
                    if (prop == null_node) continue;
                    const pd = b.tree.nodeData(prop);
                    switch (b.nodeTag(prop)) {
                        .object_property => {
                            // Non-computed keys are names, not references.
                            if (pd.lhs != 0 and b.nodeTag(pd.lhs) == .computed_name) {
                                try b.bindExpr(pd.lhs);
                            }
                            try b.bindExpr(pd.rhs);
                        },
                        .object_shorthand => {
                            try b.bindExpr(pd.lhs); // shorthand *is* a reference
                            try b.bindExpr(pd.rhs); // cover-grammar default
                        },
                        .object_method => {
                            if (pd.lhs != 0 and b.nodeTag(pd.lhs) == .computed_name) {
                                try b.bindExpr(pd.lhs);
                            }
                            try b.bindExpr(pd.rhs); // function_expr
                        },
                        else => try b.bindExpr(prop), // spread etc.
                    }
                }
            },
            .arrow_fn, .function_expr => {
                // Function-expression names are not bound in M3 (documented).
                try b.bindFunctionLike(node, d.lhs, d.rhs, false);
            },
            .class_decl => try b.bindClass(node, false), // class expression
            .function_decl => try b.bindFunctionDecl(node), // recovery
            .interface_decl => try b.bindInterface(node),
            .type_alias => try b.bindTypeAlias(node),
            .block => try b.bindStatement(node),

            // Leaves without references.
            .number_literal,
            .string_literal,
            .bigint_literal,
            .regex_literal,
            .template_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .this_expr,
            .super_expr,
            .import_expr,
            .omitted,
            .error_node,
            .unsupported,
            .empty_stmt,
            .debugger_stmt,
            => {},

            // Everything else: recurse over expression children generically.
            else => {
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindExpr(child);
            },
        }
    }

    fn bindIdentifierRef(b: *Binder, node: Node) Error!void {
        const tok = b.tree.nodeMainToken(node);
        // `undefined` is an intrinsic, not a reference (like `null`).
        if (b.tree.tokens.tag(tok) == .keyword_undefined) return;
        const atom = try b.atomOfToken(tok);
        try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
        try b.attachFlow(node);
    }

    /// Bind a condition expression, producing the flows for its true and
    /// false outcomes. Decomposes `&&`, `||`, `!`, and parens so M4 can
    /// narrow each operand (truthiness/typeof/equality/discriminant).
    fn bindCondition(b: *Binder, node: Node) Error!CondFlows {
        if (node == null_node) {
            return .{ .t = b.cur_flow, .f = unreachable_flow };
        }
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .paren_expr => return b.bindCondition(d.lhs),
            .prefix_unary => {
                if (b.tree.tokens.tag(b.tree.nodeMainToken(node)) == .bang) {
                    const inner = try b.bindCondition(d.lhs);
                    return .{ .t = inner.f, .f = inner.t };
                }
            },
            .binary => switch (b.tree.tokens.tag(b.tree.nodeMainToken(node))) {
                .amp_amp => {
                    const lhs = try b.bindCondition(d.lhs);
                    b.cur_flow = lhs.t;
                    const rhs = try b.bindCondition(d.rhs);
                    const pid = try b.newPending();
                    try b.pendAdd(pid, lhs.f);
                    try b.pendAdd(pid, rhs.f);
                    return .{ .t = rhs.t, .f = try b.finishPending(pid) };
                },
                .pipe_pipe => {
                    const lhs = try b.bindCondition(d.lhs);
                    b.cur_flow = lhs.f;
                    const rhs = try b.bindCondition(d.rhs);
                    const pid = try b.newPending();
                    try b.pendAdd(pid, lhs.t);
                    try b.pendAdd(pid, rhs.t);
                    return .{ .t = try b.finishPending(pid), .f = rhs.f };
                },
                else => {},
            },
            else => {},
        }
        try b.bindExpr(node);
        return .{
            .t = try b.addFlow(.cond_true, b.cur_flow, node),
            .f = try b.addFlow(.cond_false, b.cur_flow, node),
        };
    }

    // --- types ---------------------------------------------------------------

    /// Bind a type subtree: record type references (no flow attachment) and
    /// scopes for function types. Intrinsic keyword types (`number`, ...)
    /// are not references.
    fn bindType(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        const d = b.tree.nodeData(node);
        switch (b.nodeTag(node)) {
            .identifier => try b.bindTypeName(node),
            .qualified_name => try b.bindTypeName(node),
            .type_ref => {
                try b.bindTypeName(d.lhs);
                const r = b.tree.extraData(ast.SubRange, d.rhs);
                for (b.tree.extraRange(r.start, r.end)) |arg| try b.bindType(arg);
            },
            .typeof_type => {
                // `typeof x` references the *value* x.
                try b.bindTypeofEntity(d.lhs);
            },
            .function_type, .method_signature => try b.bindFunctionType(node, d.lhs),
            .object_type => {
                const ms = try b.newScope(.interface_members, node, b.cur_scope);
                for (b.tree.nodeRange(node)) |member| {
                    if (member != null_node) try b.bindTypeMember(member, ms);
                }
            },
            .number_literal,
            .string_literal,
            .bigint_literal,
            .template_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .this_expr,
            .error_node,
            .unsupported,
            => {},
            else => {
                // array/tuple/union/intersection/keyof/readonly/paren/
                // indexed-access/optional/rest: children are all types.
                var it = b.tree.childIterator(node);
                while (it.next()) |child| try b.bindType(child);
            },
        }
    }

    /// A type-position name: the leftmost identifier of `A.B.C` is the
    /// reference; intrinsics (number/string/...) are skipped.
    fn bindTypeName(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                if (isIntrinsicTypeToken(b.tree.tokens.tag(tok))) return;
                const atom = try b.atomOfToken(tok);
                try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
            },
            .qualified_name => try b.bindTypeName(b.tree.nodeData(node).lhs),
            else => try b.bindType(node),
        }
    }

    /// `typeof entity` in type position: a value-space reference without
    /// flow attachment (narrowing does not apply inside types).
    fn bindTypeofEntity(b: *Binder, node: Node) Error!void {
        if (node == null_node) return;
        switch (b.nodeTag(node)) {
            .identifier => {
                const tok = b.tree.nodeMainToken(node);
                if (b.tree.tokens.tag(tok) == .keyword_undefined) return;
                const atom = try b.atomOfToken(tok);
                try b.refs.append(b.scratch, .{ .atom = atom, .node = node, .scope = b.cur_scope });
            },
            .qualified_name => try b.bindTypeofEntity(b.tree.nodeData(node).lhs),
            else => {},
        }
    }

    fn isIntrinsicTypeToken(tag: scanner.Tag) bool {
        return switch (tag) {
            .keyword_any,
            .keyword_unknown,
            .keyword_never,
            .keyword_void,
            .keyword_number,
            .keyword_string,
            .keyword_boolean,
            .keyword_object,
            .keyword_symbol,
            .keyword_bigint,
            .keyword_undefined,
            => true,
            else => false,
        };
    }

    /// A function *type* gets a scope for its type/value params but no flow.
    fn bindFunctionType(b: *Binder, node: Node, proto_idx: u32) Error!void {
        const proto = b.tree.extraData(ast.FnProto, proto_idx);
        const saved_scope = b.cur_scope;
        _ = try b.pushScope(.function, node);
        try b.bindTypeParams(proto.tp_start, proto.tp_end);
        for (b.tree.extraRange(proto.params_start, proto.params_end)) |param| {
            try b.bindParam(param, false);
        }
        try b.bindType(proto.return_type);
        b.popScope(saved_scope);
    }

    // --- seal ---------------------------------------------------------------------

    /// Flatten scratch state into arena-allocated, immutable arrays; resolve
    /// recorded references (unresolved ones are kept, they are not errors);
    /// resolve local `export {...}` records against the file scope.
    fn seal(b: *Binder) Error!Bind {
        const arena = b.arena;
        const n_syms = b.sym_names.items.len;
        const n_scopes = b.scope_parents.items.len;

        // Symbols.
        const symbol_names = try arena.dupe(Atom, b.sym_names.items);
        const symbol_flags = try arena.dupe(SymbolFlags, b.sym_flags.items);
        const symbol_scopes = try arena.dupe(ScopeId, b.sym_scopes.items);
        const decls_start = try arena.alloc(u32, n_syms + 1);
        var total_decls: u32 = 0;
        for (b.sym_decl_count.items, 0..) |count, i| {
            decls_start[i] = total_decls;
            total_decls += count;
        }
        decls_start[n_syms] = total_decls;
        const decls = try arena.alloc(Node, total_decls);
        {
            var out: usize = 0;
            for (0..n_syms) |i| {
                var l = b.sym_decl_head.items[i];
                while (l != 0) : (l = b.decl_links.items[l].next) {
                    decls[out] = b.decl_links.items[l].value;
                    out += 1;
                }
            }
        }

        // Scopes + member maps (sorted by (scope, atom) for binary search).
        const scope_parents = try arena.dupe(ScopeId, b.scope_parents.items);
        const scope_kinds = try arena.dupe(ScopeKind, b.scope_kinds.items);
        const scope_owners = try arena.dupe(Node, b.scope_owners.items);

        const Entry = struct { scope: ScopeId, atom: Atom, sym: SymbolId };
        var entries = try b.scratch.alloc(Entry, b.members.count());
        {
            var it = b.members.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                entries[i] = .{
                    .scope = @intCast(kv.key_ptr.* >> 32),
                    .atom = @truncate(kv.key_ptr.*),
                    .sym = kv.value_ptr.*,
                };
            }
        }
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, x: Entry, y: Entry) bool {
                if (x.scope != y.scope) return x.scope < y.scope;
                return x.atom < y.atom;
            }
        }.lessThan);
        const members_start = try arena.alloc(u32, n_scopes + 1);
        const member_atoms = try arena.alloc(Atom, entries.len);
        const member_syms = try arena.alloc(SymbolId, entries.len);
        {
            var e: usize = 0;
            for (0..n_scopes) |s| {
                members_start[s] = @intCast(e);
                while (e < entries.len and entries[e].scope == @as(ScopeId, @intCast(s))) : (e += 1) {
                    member_atoms[e] = entries[e].atom;
                    member_syms[e] = entries[e].sym;
                }
            }
            members_start[n_scopes] = @intCast(e);
        }

        const msp = try sealPairMap(arena, b.scratch, &b.member_scopes);
        const ssp = try sealPairMap(arena, b.scratch, &b.static_scopes);

        // Flow: convert label pending ids into flow_extra ranges.
        const n_flows = b.flow_tags.items.len;
        const flow_tags = try arena.dupe(FlowTag, b.flow_tags.items);
        const flow_a = try arena.alloc(u32, n_flows);
        const flow_b = try arena.alloc(u32, n_flows);
        var extra: std.ArrayList(FlowId) = .empty;
        defer extra.deinit(b.scratch);
        for (0..n_flows) |i| {
            switch (b.flow_tags.items[i]) {
                .branch_label, .loop_label => {
                    const p = b.pendings.items[b.flow_a.items[i]];
                    flow_a[i] = @intCast(extra.items.len);
                    var l = p.head;
                    while (l != 0) : (l = b.ante_links.items[l].next) {
                        try extra.append(b.scratch, b.ante_links.items[l].value);
                    }
                    flow_b[i] = @intCast(extra.items.len);
                },
                else => {
                    flow_a[i] = b.flow_a.items[i];
                    flow_b[i] = b.flow_b.items[i];
                },
            }
        }
        const flow_extra = try arena.dupe(FlowId, extra.items);

        // Node -> flow attachment map, sorted by node id.
        std.mem.sort(Link, b.flow_pairs.items, {}, struct {
            fn lessThan(_: void, x: Link, y: Link) bool {
                return x.value < y.value;
            }
        }.lessThan);
        const flow_map_nodes = try arena.alloc(Node, b.flow_pairs.items.len);
        const flow_map_ids = try arena.alloc(FlowId, b.flow_pairs.items.len);
        for (b.flow_pairs.items, 0..) |pair, i| {
            flow_map_nodes[i] = pair.value;
            flow_map_ids[i] = pair.next;
        }

        var result: Bind = .{
            .symbol_names = symbol_names,
            .symbol_flags = symbol_flags,
            .symbol_scopes = symbol_scopes,
            .symbol_decls_start = decls_start,
            .symbol_decls = decls,
            .scope_parents = scope_parents,
            .scope_kinds = scope_kinds,
            .scope_owners = scope_owners,
            .scope_members_start = members_start,
            .member_atoms = member_atoms,
            .member_syms = member_syms,
            .member_scope_syms = msp.keys,
            .member_scope_ids = msp.vals,
            .static_scope_syms = ssp.keys,
            .static_scope_ids = ssp.vals,
            .flow_tags = flow_tags,
            .flow_a = flow_a,
            .flow_b = flow_b,
            .flow_extra = flow_extra,
            .flow_map_nodes = flow_map_nodes,
            .flow_map_ids = flow_map_ids,
            .imports = &.{},
            .exports = &.{},
            .unresolved = &.{},
            .diagnostics = &.{},
        };

        // Resolve recorded references; keep the unresolved ones.
        var unresolved: std.ArrayList(Ref) = .empty;
        defer unresolved.deinit(b.scratch);
        for (b.refs.items) |ref| {
            if (result.resolve(ref.atom, ref.scope) == null) {
                try unresolved.append(b.scratch, ref);
            }
        }
        result.unresolved = try arena.dupe(Ref, unresolved.items);

        // Resolve local `export { a }` records + mark the symbols exported.
        for (b.export_recs.items) |*rec| {
            if (rec.kind == .named and rec.sym == no_symbol and rec.local != 0 and rec.module == 0) {
                if (result.lookupInScope(file_scope, rec.local)) |sym| {
                    rec.sym = sym;
                    symbol_flags[sym].exported = true;
                }
            }
        }
        result.imports = try arena.dupe(ImportRec, b.import_recs.items);
        result.exports = try arena.dupe(ExportRec, b.export_recs.items);
        result.diagnostics = try arena.dupe(Diagnostic, b.diags.items);
        return result;
    }

    fn sealPairMap(
        arena: Allocator,
        scratch: Allocator,
        map: *std.AutoHashMapUnmanaged(SymbolId, ScopeId),
    ) Error!struct { keys: []const u32, vals: []const u32 } {
        const Pair = struct { k: u32, v: u32 };
        var pairs = try scratch.alloc(Pair, map.count());
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            pairs[i] = .{ .k = kv.key_ptr.*, .v = kv.value_ptr.* };
        }
        std.mem.sort(Pair, pairs, {}, struct {
            fn lessThan(_: void, x: Pair, y: Pair) bool {
                return x.k < y.k;
            }
        }.lessThan);
        const keys = try arena.alloc(u32, pairs.len);
        const vals = try arena.alloc(u32, pairs.len);
        for (pairs, 0..) |p, j| {
            keys[j] = p.k;
            vals[j] = p.v;
        }
        return .{ .keys = keys, .vals = vals };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");

/// Everything needed to bind a source string in a test.
const TestBind = struct {
    arena: std.heap.ArenaAllocator,
    interner: Interner,
    tree: Ast,
    b: Bind,
    src: []const u8,

    fn init(src: []const u8) !TestBind {
        var t: TestBind = undefined;
        t.src = src;
        t.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer t.arena.deinit();
        t.interner = Interner.init();
        errdefer t.interner.deinit(testing.allocator);
        t.tree = try parser.parse(t.arena.allocator(), src);
        t.b = try bind(t.arena.allocator(), testing.io, testing.allocator, &t.interner, &t.tree, src);
        return t;
    }

    fn deinit(t: *TestBind) void {
        t.interner.deinit(testing.allocator);
        t.arena.deinit();
    }

    fn dumpAlloc(t: *TestBind, alloc: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try t.b.dump(testing.io, &t.interner, &t.tree, t.src, &aw.writer);
        return aw.toOwnedSlice();
    }

    fn atom(t: *TestBind, text: []const u8) !Atom {
        return t.interner.intern(testing.io, testing.allocator, text);
    }

    /// The nth (0-based) identifier node whose token text equals `name`.
    fn identNode(t: *TestBind, name: []const u8, nth: usize) ?Node {
        var seen: usize = 0;
        for (0..t.tree.nodes.len) |i| {
            const node: Node = @intCast(i);
            if (t.tree.nodeTag(node) != .identifier) continue;
            const text = t.tree.tokenSlice(t.src, t.tree.nodeMainToken(node));
            if (!std.mem.eql(u8, text, name)) continue;
            if (seen == nth) return node;
            seen += 1;
        }
        return null;
    }
};

fn expectDump(src: []const u8, expected: []const u8) !void {
    var t = try TestBind.init(src);
    defer t.deinit();
    const got = try t.dumpAlloc(t.arena.allocator());
    testing.expectEqualStrings(expected, got) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        return err;
    };
}

fn expectBindCodes(src: []const u8, expected: []const Code) !void {
    var t = try TestBind.init(src);
    defer t.deinit();
    testing.expectEqual(expected.len, t.b.diagnostics.len) catch |err| {
        std.debug.print("--- source: {s}\n", .{src});
        for (t.b.diagnostics) |d| {
            std.debug.print("  [{d}..{d}] {s}\n", .{ d.span.start, d.span.end, d.message() });
        }
        return err;
    };
    for (expected, t.b.diagnostics) |want, got| {
        testing.expectEqual(want, got.code) catch |err| {
            std.debug.print("--- source: {s}\n", .{src});
            return err;
        };
    }
}

test "smoke: bind a small file" {
    var t = try TestBind.init("const x = 1; function f(a: number) { return a + x; }");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.diagnostics.len);
    try testing.expect(t.b.symbolCount() >= 3);
    const x = try t.atom("x");
    try testing.expect(t.b.resolve(x, file_scope) != null);
}

// --- goldens: hoisting & scopes ---------------------------------------------

test "golden: var hoists out of blocks to the function scope" {
    try expectDump("function f() { var x = 1; { var y = 2; let z = 3; } }",
        \\scope 0: file
        \\  f: function impl
        \\  scope 1: function f
        \\    x: var
        \\    y: var
        \\    scope 2: block
        \\      z: let
        \\flow: nodes=5 attach=0 (start=2 assign=3 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: function declaration in a block is block-scoped (modern semantics)" {
    try expectDump("{ function g() {} }",
        \\scope 0: file
        \\  scope 1: block
        \\    g: function impl
        \\    scope 2: function g
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: let shadowing chain (TDZ names, one symbol per scope)" {
    try expectDump("let a = 1; { let a = 2; { let a = 3; a; } a; } a;",
        \\scope 0: file
        \\  a: let
        \\  scope 1: block
        \\    a: let
        \\    scope 2: block
        \\      a: let
        \\flow: nodes=4 attach=3 (start=1 assign=3 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: class members vs statics, parameter properties" {
    try expectDump("class C<T> { x: number = 1; static y: string; m(p: T): void {} static s(): void {} constructor(private z: number) {} }",
        \\scope 0: file
        \\  C: class
        \\  scope 1: class C
        \\    T: type-param
        \\    scope 2: class_members C
        \\      x: property
        \\      m: method impl
        \\      constructor: method impl
        \\      z: property
        \\    scope 3: class_statics C
        \\      y: property static
        \\      s: method static impl
        \\    scope 4: function m
        \\      p: param
        \\    scope 5: function s
        \\    scope 6: function constructor
        \\      z: param
        \\flow: nodes=4 attach=0 (start=4 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: params, destructured params, defaults referencing earlier params" {
    try expectDump("function h(a: number, [b, c]: number[], { d, e: f2 = a }: any, g2 = a + b) {}",
        \\scope 0: file
        \\  h: function impl
        \\  scope 1: function h
        \\    a: param
        \\    b: param
        \\    c: param
        \\    d: param
        \\    f2: param
        \\    g2: param
        \\flow: nodes=2 attach=3 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
    // The defaults' references to earlier params resolve in-file.
    var t = try TestBind.init("function h(a: number, g2 = a + 1) {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "golden: catch parameter gets its own scope shared with the body" {
    try expectDump("try { f(); } catch (e) { g(e); }",
        \\scope 0: file
        \\  scope 1: block
        \\  scope 2: catch_clause
        \\    e: catch
        \\flow: nodes=1 attach=3 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\unresolved: f(1) g(1)
        \\
    );
}

test "golden: for and for-of heads scope their declarations" {
    try expectDump("for (let i = 0; i < 10; i++) { i; } for (const x of xs) { x; }",
        \\scope 0: file
        \\  scope 1: for_head
        \\    i: let
        \\    scope 2: block
        \\  scope 3: for_head
        \\    x: const
        \\    scope 4: block
        \\flow: nodes=8 attach=5 (start=1 assign=3 cond=2 branch=0 loop=2 switch=0)
        \\unresolved: xs(1)
        \\
    );
}

test "golden: import records incl. type-only, namespace, side-effect" {
    try expectDump("import d, { a, b as c, type T } from \"./m\"; import * as ns from \"./n\"; import type X from \"./x\"; import \"./side\";",
        \\scope 0: file
        \\  d: import
        \\  a: import
        \\  c: import
        \\  T: import type-only
        \\  ns: import
        \\  X: import type-only
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\import local=d imported=default from="./m" default
        \\import local=a imported=a from="./m" named
        \\import local=c imported=b from="./m" named
        \\import local=T imported=T from="./m" named type-only
        \\import local=ns imported=* from="./n" namespace
        \\import local=X imported=default from="./x" default type-only
        \\import local=- imported=- from="./side" side_effect
        \\
    );
}

test "golden: export records (decl, alias, re-export, star, default)" {
    try expectDump("export const k = 1; export function ef() {} export { k as kk }; export type { T2 } from \"./t\"; export * from \"./all\"; export default 42;",
        \\scope 0: file
        \\  k: const exported
        \\  ef: function exported impl
        \\  scope 1: function ef
        \\flow: nodes=3 attach=0 (start=2 assign=1 cond=0 branch=0 loop=0 switch=0)
        \\export exported=k local=k named
        \\export exported=ef local=ef named
        \\export exported=kk local=k named
        \\export exported=T2 local=T2 from="./t" reexport_named type-only
        \\export exported=- local=- from="./all" reexport_all
        \\export exported=default local=- default
        \\
    );
}

test "golden: overload signatures group into one symbol" {
    try expectDump("function ov(a: number): void; function ov(a: string): void; function ov(a: any): void {}",
        \\scope 0: file
        \\  ov: function impl decls=3
        \\  scope 1: function ov
        \\    a: param
        \\  scope 2: function ov
        \\    a: param
        \\  scope 3: function ov
        \\    a: param
        \\flow: nodes=2 attach=0 (start=2 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: interface-interface merge shares one members scope" {
    try expectDump("interface I { a: number; m(): void; } interface I { b: string; }",
        \\scope 0: file
        \\  I: interface decls=2
        \\  scope 1: interface I
        \\    scope 2: interface_members I
        \\      a: property
        \\      m: method
        \\      b: property
        \\    scope 3: function m
        \\  scope 4: interface I
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

test "golden: type alias with type params" {
    try expectDump("type Alias<T> = T | null; let v: Alias<number>;",
        \\scope 0: file
        \\  Alias: type
        \\  v: let
        \\  scope 1: type_alias Alias
        \\    T: type-param
        \\flow: nodes=1 attach=0 (start=1 assign=0 cond=0 branch=0 loop=0 switch=0)
        \\
    );
}

// --- duplicate-declaration diagnostics --------------------------------------

test "dup: let/let redeclare is TS2451" {
    try expectBindCodes("let x = 1; let x = 2;", &.{.block_scoped_redeclare});
    try testing.expectEqual(@as(u16, 2451), Code.block_scoped_redeclare.tsCode());
}

test "dup: var-vs-let in both orders is TS2451" {
    try expectBindCodes("var x; let x;", &.{.block_scoped_redeclare});
    try expectBindCodes("let x; var x;", &.{.block_scoped_redeclare});
    // Order-independence across blocks: the var hoists past the let's scope.
    try expectBindCodes("let x; { var x; }", &.{.block_scoped_redeclare});
    try expectBindCodes("{ var x; let x; }", &.{.block_scoped_redeclare});
    // No conflict when the block-scoped name is in a sibling/inner scope.
    try expectBindCodes("var x; { let x; }", &.{});
    try expectBindCodes("function f() { { let x; } var x; }", &.{});
}

test "dup: class/let and class/class" {
    try expectBindCodes("let A; class A {}", &.{.block_scoped_redeclare});
    try expectBindCodes("class A {} let A;", &.{.block_scoped_redeclare});
    try expectBindCodes("class A {} class A {}", &.{.duplicate_identifier});
}

test "dup: var/function is TS2300, var/var and var/param merge" {
    try expectBindCodes("function f() {} var f;", &.{.duplicate_identifier});
    try expectBindCodes("var x; var x;", &.{});
    try expectBindCodes("function f(x: number) { var x; }", &.{});
}

test "dup: two function implementations is TS2393, overloads are fine" {
    try expectBindCodes("function f() {} function f() {}", &.{.duplicate_function_implementation});
    try expectBindCodes("function f(): void; function f() {}", &.{});
    try expectBindCodes(
        "class C { m(): void; m(a: number): void; m(a?: number) {} }",
        &.{},
    );
    try expectBindCodes(
        "class C { m() {} m() {} }",
        &.{.duplicate_function_implementation},
    );
}

test "dup: duplicate parameters are TS2300 (strict mode)" {
    try expectBindCodes("function f(a: number, a: string) {}", &.{.duplicate_identifier});
    try expectBindCodes("function f([a, b]: any, { a: a2, c: a }: any) {}", &.{.duplicate_identifier});
}

test "dup: import conflicts are TS2440, duplicate imports TS2300" {
    try expectBindCodes("import { a } from \"./m\"; let a = 1;", &.{.import_conflict});
    try expectBindCodes("let a = 1; import { a } from \"./m\";", &.{.import_conflict});
    try expectBindCodes("import { a } from \"./m\"; import { a } from \"./n\";", &.{.duplicate_identifier});
    // Type-only imports live in type space only.
    try expectBindCodes("import type { T } from \"./m\"; let T = 1;", &.{});
    try expectBindCodes("import type { T } from \"./m\"; type T = number;", &.{.import_conflict});
}

test "dup: catch-clause redeclaration is TS2492, var escape is allowed" {
    try expectBindCodes("try {} catch (e) { let e; }", &.{.catch_redeclare});
    try expectBindCodes("try {} catch (e) { var e; }", &.{});
}

test "dup: type-space clashes" {
    try expectBindCodes("interface I {} type I = number;", &.{.duplicate_identifier});
    try expectBindCodes("type T = number; type T = string;", &.{.duplicate_identifier});
    try expectBindCodes("class C {} type C = number;", &.{.duplicate_identifier});
    // Value/type space sharing is legal (one merged symbol).
    try expectBindCodes("var x = 1; interface x {}", &.{});
    try expectBindCodes("function f() {} interface f {}", &.{});
}

test "dup: class members" {
    try expectBindCodes("class C { x: number; x: string; }", &.{.duplicate_identifier});
    try expectBindCodes("class C { x: number; m() {} }", &.{});
    // Instance and static sides are separate tables.
    try expectBindCodes("class C { x: number; static x: string; }", &.{});
    // get/set pairs merge silently.
    try expectBindCodes("class C { get v(): number { return 1; } set v(n: number) {} }", &.{});
    try expectBindCodes("interface I { a: number; a: string; }", &.{.duplicate_identifier});
}

// --- flow graph structure -----------------------------------------------------

test "flow: if/else join has both assignment antecedents" {
    var t = try TestBind.init("let x = 1; if (c) { x = 2; } else { x = 3; } x;");
    defer t.deinit();
    const read = t.identNode("x", 3).?; // decl, =2 target, =3 target, read
    const flow = t.b.flowAt(read).?;
    try testing.expectEqual(FlowTag.branch_label, t.b.flow_tags[flow]);
    const antes = t.b.flowAntecedents(flow);
    try testing.expectEqual(@as(usize, 2), antes.len);
    for (antes) |a| try testing.expectEqual(FlowTag.assign, t.b.flow_tags[a]);
}

test "flow: while loop head has entry and loop-back antecedents" {
    var t = try TestBind.init("let i = 0; while (c) { i = i + 1; } i;");
    defer t.deinit();
    const read = t.identNode("i", 3).?; // decl, =target, read in i+1, final read
    const flow = t.b.flowAt(read).?;
    // Exiting the loop: the false branch of the condition.
    try testing.expectEqual(FlowTag.cond_false, t.b.flow_tags[flow]);
    const loop = t.b.flowAntecedents(flow)[0];
    try testing.expectEqual(FlowTag.loop_label, t.b.flow_tags[loop]);
    const antes = t.b.flowAntecedents(loop);
    try testing.expectEqual(@as(usize, 2), antes.len); // entry + back edge
    var has_assign_back_edge = false;
    for (antes) |a| {
        if (t.b.flow_tags[a] == .assign) has_assign_back_edge = true;
    }
    try testing.expect(has_assign_back_edge);
}

test "flow: statements after an early return are unreachable" {
    var t = try TestBind.init("function f(x: number) { if (x) { return; } x; } function g(y: number) { return; y; }");
    defer t.deinit();
    // In f, `x;` after the conditional return is reachable (join of the
    // false branch); in g, `y;` is dead.
    const x_read = t.identNode("x", 2).?; // param, cond, read
    try testing.expect(t.b.flowAt(x_read).? != unreachable_flow);
    const y_read = t.identNode("y", 1).?; // param, read
    try testing.expectEqual(unreachable_flow, t.b.flowAt(y_read).?);
}

test "flow: switch fallthrough joins, break isolates" {
    var t = try TestBind.init("let a = 0; switch (v) { case 1: a; break; case 2: a = 1; case 3: a; }");
    defer t.deinit();
    // Read in case 1: only the switch_clause flow reaches it (no fallthrough).
    const first = t.identNode("a", 1).?;
    const f1 = t.b.flowAt(first).?;
    try testing.expectEqual(FlowTag.switch_clause, t.b.flow_tags[f1]);
    // Read in case 3: fallthrough from case 2's assignment joins the clause.
    const third = t.identNode("a", 3).?;
    const f3 = t.b.flowAt(third).?;
    try testing.expectEqual(FlowTag.branch_label, t.b.flow_tags[f3]);
    const antes = t.b.flowAntecedents(f3);
    try testing.expectEqual(@as(usize, 2), antes.len);
    var tags: [2]FlowTag = undefined;
    for (antes, 0..) |a, i| tags[i] = t.b.flow_tags[a];
    try testing.expect((tags[0] == .assign and tags[1] == .switch_clause) or
        (tags[0] == .switch_clause and tags[1] == .assign));
}

test "flow: && decomposes conditions for narrowing" {
    var t = try TestBind.init("if (a && b) { c; }");
    defer t.deinit();
    const read = t.identNode("c", 0).?;
    const flow = t.b.flowAt(read).?;
    // Inside the then-branch: true of `b`, whose antecedent is true of `a`.
    try testing.expectEqual(FlowTag.cond_true, t.b.flow_tags[flow]);
    const prev = t.b.flowAntecedents(flow)[0];
    try testing.expectEqual(FlowTag.cond_true, t.b.flow_tags[prev]);
}

// --- resolve() & unresolved references -----------------------------------------

test "resolve: shadowing chain picks the innermost symbol" {
    var t = try TestBind.init("let a = 1; function f() { let a = 2; { let a = 3; } }");
    defer t.deinit();
    const a = try t.atom("a");
    // Scopes: 0 file, 1 function f, 2 inner block.
    const file_sym = t.b.resolve(a, 0).?;
    const fn_sym = t.b.resolve(a, 1).?;
    const blk_sym = t.b.resolve(a, 2).?;
    try testing.expect(file_sym != fn_sym and fn_sym != blk_sym);
    try testing.expectEqual(@as(ScopeId, 0), t.b.symbol_scopes[file_sym]);
    try testing.expectEqual(@as(ScopeId, 1), t.b.symbol_scopes[fn_sym]);
    try testing.expectEqual(@as(ScopeId, 2), t.b.symbol_scopes[blk_sym]);
    // A name only in the file scope resolves from the inner block.
    const f_atom = try t.atom("f");
    try testing.expectEqual(t.b.resolve(f_atom, 0).?, t.b.resolve(f_atom, 2).?);
    // Unknown names resolve to null.
    const nope = try t.atom("nope");
    try testing.expectEqual(@as(?SymbolId, null), t.b.resolve(nope, 2));
}

test "resolve: hoisted var and params resolve from nested blocks" {
    var t = try TestBind.init("function f(p: number) { { var v = p; } return v; }");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "resolve: forward references to hoisted declarations resolve" {
    var t = try TestBind.init("f(); function f() {} let i: I; interface I {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.unresolved.len);
}

test "unresolved: iteration order and contents" {
    var t = try TestBind.init("foo(bar); let baz = qux; type T = Missing;");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 4), t.b.unresolved.len);
    try testing.expectEqual(try t.atom("foo"), t.b.unresolved[0].atom);
    try testing.expectEqual(try t.atom("bar"), t.b.unresolved[1].atom);
    try testing.expectEqual(try t.atom("qux"), t.b.unresolved[2].atom);
    try testing.expectEqual(try t.atom("Missing"), t.b.unresolved[3].atom);
    // Intrinsic type names and `undefined` are not references.
    var t2 = try TestBind.init("let a: number = undefined; let b: string | null;");
    defer t2.deinit();
    try testing.expectEqual(@as(usize, 0), t2.b.unresolved.len);
}

test "symbols: TDZ position is recorded via the first decl node" {
    var t = try TestBind.init("let x = 1;");
    defer t.deinit();
    const x = try t.atom("x");
    const sym = t.b.resolve(x, 0).?;
    const decls = t.b.declsOf(sym);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqual(ast.Tag.declarator_init, t.tree.nodeTag(decls[0]));
}

test "records: member scopes are queryable for classes and interfaces" {
    var t = try TestBind.init("class C { m() {} static s() {} } interface I { p: number; }");
    defer t.deinit();
    const c_sym = t.b.resolve(try t.atom("C"), 0).?;
    const i_sym = t.b.resolve(try t.atom("I"), 0).?;
    const cm = t.b.membersScopeOf(c_sym).?;
    const cs = t.b.staticsScopeOf(c_sym).?;
    const im = t.b.membersScopeOf(i_sym).?;
    try testing.expect(t.b.lookupInScope(cm, try t.atom("m")) != null);
    try testing.expect(t.b.lookupInScope(cs, try t.atom("s")) != null);
    try testing.expect(t.b.lookupInScope(im, try t.atom("p")) != null);
    try testing.expectEqual(@as(?ScopeId, null), t.b.staticsScopeOf(i_sym));
}

// --- stress: the binder is total on arbitrary parser output ---------------------

/// Oracle: binding any parse tree terminates and produces internally
/// consistent, in-bounds output.
fn checkBinderOnArbitraryBytes(alloc: Allocator, interner: *Interner, input: []const u8) !void {
    const tree = parser.parse(alloc, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SourceTooLarge => unreachable,
    };
    const b = try bind(alloc, testing.io, testing.allocator, interner, &tree, input);

    const n_syms = b.symbol_names.len;
    const n_scopes = b.scope_parents.len;
    const n_flows = b.flow_tags.len;
    try testing.expect(n_syms >= 1 and n_scopes >= 1 and n_flows >= 3);
    try testing.expectEqual(n_syms + 1, b.symbol_decls_start.len);
    try testing.expectEqual(n_scopes + 1, b.scope_members_start.len);

    for (b.symbol_scopes) |s| try testing.expect(s < n_scopes);
    for (0..n_syms) |i| {
        try testing.expect(b.symbol_decls_start[i] <= b.symbol_decls_start[i + 1]);
    }
    try testing.expectEqual(@as(usize, b.symbol_decls_start[n_syms]), b.symbol_decls.len);
    for (b.symbol_decls) |n| try testing.expect(n < tree.nodes.len);

    for (b.scope_parents, 0..) |p, i| {
        try testing.expect(p < n_scopes);
        if (i > 0) try testing.expect(p < i); // parents precede children
    }
    for (0..n_scopes) |s| {
        const lo = b.scope_members_start[s];
        const hi = b.scope_members_start[s + 1];
        try testing.expect(lo <= hi);
        // Sorted-by-atom segments (binary-search invariant).
        var j = lo;
        while (j + 1 < hi) : (j += 1) {
            try testing.expect(b.member_atoms[j] < b.member_atoms[j + 1]);
        }
    }
    try testing.expectEqual(@as(usize, b.scope_members_start[n_scopes]), b.member_atoms.len);
    for (b.member_syms) |sym| try testing.expect(sym != 0 and sym < n_syms);

    for (0..n_flows) |f| {
        switch (b.flow_tags[f]) {
            .branch_label, .loop_label => {
                try testing.expect(b.flow_a[f] <= b.flow_b[f]);
                try testing.expect(b.flow_b[f] <= b.flow_extra.len);
                for (b.flow_extra[b.flow_a[f]..b.flow_b[f]]) |a| {
                    try testing.expect(a < n_flows);
                }
            },
            .assign, .cond_true, .cond_false, .switch_clause => {
                try testing.expect(b.flow_a[f] < n_flows);
                try testing.expect(b.flow_b[f] < tree.nodes.len);
            },
            .none, .unreachable_, .start => {},
        }
    }
    var k: usize = 0;
    while (k + 1 < b.flow_map_nodes.len) : (k += 1) {
        try testing.expect(b.flow_map_nodes[k] <= b.flow_map_nodes[k + 1]);
    }
    for (b.flow_map_ids) |f| try testing.expect(f != 0 and f < n_flows);
    for (b.unresolved) |r| {
        try testing.expect(r.atom != 0);
        try testing.expect(r.scope < n_scopes);
        try testing.expect(r.node < tree.nodes.len);
    }
    for (b.diagnostics) |d| {
        try testing.expect(d.span.start <= input.len);
        try testing.expect(d.span.end <= input.len + 1);
    }
}

test "stress: bind deterministic random byte soup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0xb1d_2026);
    const random = prng.random();
    var buf: [384]u8 = undefined;
    for (0..400) |_| {
        const n = random.uintLessThan(usize, buf.len + 1);
        random.bytes(buf[0..n]);
        try checkBinderOnArbitraryBytes(arena.allocator(), &interner, buf[0..n]);
        _ = arena.reset(.retain_capacity);
    }
}

test "stress: bind token soup (valid tokens, random order)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x70cc_2027);
    const random = prng.random();

    const vocab = [_][]const u8{
        "if",      "else",       "for",       "while",     "return",   "function",    "class",  "const",
        "let",     "var",        "interface", "type",      "import",   "export",      "new",    "typeof",
        "extends", "implements", "as",        "satisfies", "keyof",    "in",          "of",     "async",
        "await",   "yield",      "static",    "private",   "readonly", "this",        "super",  "null",
        "true",    "false",      "x",         "y",         "foo",      "Bar",         "42",     "3.14",
        "\"s\"",   "`t`",        "`a${",      "}",         "{",        "}",           "(",      ")",
        "[",       "]",          ";",         ",",         ":",        "?",           ".",      "?.",
        "...",     "=>",         "=",         "+",         "-",        "*",           "/",      "%",
        "**",      "==",         "===",       "!=",        "<",        ">",           "<=",     ">=",
        "<<",      ">>",         ">>>",       "&&",        "||",       "??",          "!",      "~",
        "&",       "|",          "^",         "++",        "--",       "+=",          "??=",    "@",
        "#",       "\\",         "enum",      "namespace", "declare",  "abstract",    "0x1n",   "/re/g",
        "break",   "continue",   "switch",    "case",      "default",  "try",         "catch",  "finally",
        "throw",   "do",         "get",       "set",       "from",     "constructor", "label:", "undefined",
    };

    var buf: [2048]u8 = undefined;
    for (0..300) |_| {
        var len: usize = 0;
        const count = random.uintLessThan(usize, 120);
        for (0..count) |_| {
            const word = vocab[random.uintLessThan(usize, vocab.len)];
            if (len + word.len + 1 > buf.len) break;
            @memcpy(buf[len..][0..word.len], word);
            len += word.len;
            buf[len] = if (random.uintLessThan(u8, 6) == 0) '\n' else ' ';
            len += 1;
        }
        try checkBinderOnArbitraryBytes(arena.allocator(), &interner, buf[0..len]);
        _ = arena.reset(.retain_capacity);
    }
}

test "stress: bind pathological nesting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    // Deep blocks: {{{{ ... }}}} — one scope per block.
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(testing.allocator);
    for (0..200) |_| try s.appendSlice(testing.allocator, "{ let x = 1; ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
    _ = arena.reset(.retain_capacity);
    // Deep expression nesting.
    s.clearRetainingCapacity();
    try s.appendSlice(testing.allocator, "x = ");
    for (0..200) |_| try s.appendSlice(testing.allocator, "(a && ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
    _ = arena.reset(.retain_capacity);
    // Deep unclosed loops.
    s.clearRetainingCapacity();
    for (0..100) |_| try s.appendSlice(testing.allocator, "while (c) { for (;;) ");
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, s.items);
}

fn fuzzBinderOne(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .value(u8, '{', 3),
        .value(u8, '}', 3),
        .value(u8, '(', 3),
        .value(u8, ')', 3),
        .value(u8, '=', 3),
        .value(u8, ';', 3),
        .value(u8, '\n', 3),
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interner = Interner.init();
    defer interner.deinit(testing.allocator);
    try checkBinderOnArbitraryBytes(arena.allocator(), &interner, source_buf[0..len]);
}

test "fuzz: binder on arbitrary bytes" {
    try testing.fuzz({}, fuzzBinderOne, .{});
}

test "memory: sealed byte accounting is consistent" {
    var t = try TestBind.init(
        \\import { a } from "./m";
        \\export function f(x: number): number {
        \\  let total = 0;
        \\  for (let i = 0; i < x; i++) { total = total + a; }
        \\  return total;
        \\}
    );
    defer t.deinit();
    try testing.expect(t.b.symbolBytes() > 0);
    try testing.expect(t.b.scopeBytes() > 0);
    try testing.expect(t.b.flowBytes() > 0);
    try testing.expect(t.b.recordBytes() > 0);
    try testing.expectEqual(
        t.b.symbolBytes() + t.b.scopeBytes() + t.b.flowBytes() + t.b.recordBytes(),
        t.b.totalBytes(),
    );
    // SoA sanity: 12 fixed bytes per symbol + starts + decls.
    const n = t.b.symbol_names.len;
    try testing.expectEqual(
        n * 12 + (n + 1) * 4 + t.b.symbol_decls.len * 4,
        t.b.symbolBytes(),
    );
}

test "records: exported overloads produce a single export record" {
    var t = try TestBind.init("export function f(): void; export function f() {}");
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.b.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), t.b.exports.len);
    try testing.expectEqual(@as(usize, 2), t.b.declsOf(t.b.exports[0].sym).len);
}
