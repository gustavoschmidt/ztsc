//! The sealed bind *result* for one file: the ids, flag sets, records and the
//! `Bind` struct every downstream consumer (linker, checker, driver) reads.
//!
//! This file is deliberately free of construction logic — binder.zig owns the
//! machine that fills these arrays and re-exports everything declared here, so
//! consumers can keep importing either module. The only mutation `Bind` ever
//! sees after `bind()` returns is `remapAtoms`, which rewrites atom ids once on
//! the main thread; see the field notes there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const intern = @import("../intern.zig");
const diagnostics = @import("diagnostics.zig");

const Ast = ast.Ast;
const Node = ast.Node;
const Atom = intern.Atom;
const Interner = intern.Interner;
const Diagnostic = diagnostics.Diagnostic;

const Error = error{OutOfMemory};

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
    namespace,
    /// The member table of one `enum` (shared by every block of a merged
    /// enum). Entered while binding member initializers, so a bare name
    /// there resolves to a member of the same enum first — tsc's
    /// `resolveName` case for `SyntaxKind.EnumDeclaration`.
    enum_body,
    type_alias,
    for_head,
    catch_clause,
    /// Holds the expando properties (`fn.prop = …`) of one function value.
    /// Never entered lexically — reached only through `expandoScopeOf` — but
    /// parented at the function's own scope so a property's initializer
    /// resolves names where it was written.
    expando,
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
    /// `namespace` / `module` declaration (both a value and a type container).
    namespace_decl: bool = false,
    /// A function value carrying *expando* properties: same-scope
    /// `fn.prop = value` statements declare members on it (TS 3.1
    /// "properties declarations on functions"). Its members live in the
    /// scope `expandoScopeOf` maps it to.
    expando: bool = false,
    /// One such property. Its declarations are the `assign` nodes; the
    /// member type is the widened type of the assigned expressions.
    expando_member: bool = false,
    /// Every `namespace`/`module` block of this symbol is NON-INSTANTIATED —
    /// its body declares only types (interfaces, type aliases, non-exported
    /// imports, const enums, other non-instantiated namespaces), so it emits
    /// no runtime object. tsc gives such a symbol `NamespaceModule`, whose
    /// excludes mask is *empty*: it neither displaces nor is displaced by a
    /// `var`/`let`/`const` of the same name. `@types/node` leans on that in
    /// half a dozen places (`namespace webcrypto {…}` next to `const
    /// webcrypto`, `namespace console {…}` next to `var console`).
    ns_uninstantiated: bool = false,
    /// A `const` TYPE PARAMETER (TS 5.0 `f<const T>(…)`). Inference into it
    /// runs in a const context — a literal argument keeps its literal type and
    /// an object/array literal argument infers readonly members, as if the
    /// argument had been written `as const` — and the fresh-literal widening
    /// `getCovariantInference` normally applies is suppressed. Read off the
    /// tokens before the parameter's name at bind time (`bindTypeParams`), so
    /// the checker's per-argument test is one flag load.
    const_type_param: bool = false,
    /// At least one of this symbol's `class` declarations is NOT in an
    /// ambient context. Only consulted by the function/class merge check
    /// (TS2813/TS2814): tsc lets a class merge with function declarations
    /// so a `.d.ts` can model a callable class (`ClassExcludes` omits
    /// `Function` and vice-versa), but the pair is an error unless every
    /// class declaration is ambient.
    nonambient_class: bool = false,
    /// A class member declared `private` or `protected` (including a
    /// `constructor(private db: …)` parameter property). tsc's
    /// `ModifierFlags.NonPublic`. The checker does not enforce visibility at
    /// access sites yet; what it needs the bit for is `keyof`, which excludes
    /// non-public members outright (`getLiteralTypeFromProperty` answers
    /// `never` for them) — and with `keyof` every mapped type over it,
    /// `Pick<T, keyof T>` most of all.
    non_public: bool = false,
    /// One member of an `enum` body. tsc's `SymbolFlags.EnumMember`: a VALUE
    /// (its type is the member literal `E.A`), declared in the enum's own
    /// symbol table, which `resolveName` consults at the EnumDeclaration
    /// location — so a bare `A` inside a member initializer names the member
    /// and shadows an outer `A`. Two members of one name are TS2300.
    enum_member: bool = false,
    _pad: u1 = 0,

    pub fn bits(f: SymbolFlags) u32 {
        return @bitCast(f);
    }
    pub fn merge(a: SymbolFlags, b: SymbolFlags) SymbolFlags {
        return @bitCast(a.bits() | b.bits());
    }
    /// Whether the symbol denotes a value (for the `export =` mixing check).
    pub fn hasValue(f: SymbolFlags) bool {
        return (f.bits() & mask_value) != 0;
    }
};

/// The bit pattern of a comptime-known flag set. Used to build the masks
/// below and, in binder.zig, the per-declaration-kind "excludes" masks.
pub fn fbits(comptime f: SymbolFlags) u32 {
    return @bitCast(f);
}

pub const mask_let_const_class = fbits(.{ .let_decl = true }) | fbits(.{ .const_decl = true }) |
    fbits(.{ .class = true });
pub const mask_value = fbits(.{ .var_decl = true }) | mask_let_const_class |
    fbits(.{ .function = true }) | fbits(.{ .param = true }) |
    fbits(.{ .catch_param = true }) | fbits(.{ .import_binding = true }) |
    fbits(.{ .enum_decl = true }) | fbits(.{ .namespace_decl = true });
pub const mask_type = fbits(.{ .class = true }) | fbits(.{ .interface = true }) |
    fbits(.{ .type_alias = true }) | fbits(.{ .type_param = true }) |
    fbits(.{ .enum_decl = true }) | fbits(.{ .namespace_decl = true });
pub const mask_member = fbits(.{ .property = true }) | fbits(.{ .method = true }) |
    fbits(.{ .getter = true }) | fbits(.{ .setter = true });

/// Flag bits used on the TARGET side of an excludes check. A type-only import
/// occupies the *type* space only, so `import type { T } …; let T;` merges
/// without error while `type T = …` still clashes with it; a non-instantiated
/// namespace occupies no exclusion space at all (tsc's `NamespaceModule`), so
/// it merges with anything — including a `var`/`let`/`const` of the same name.
/// Neither bit is cleared on the symbol: only the excludes check ignores them,
/// so name resolution and the `N.member` container meaning are untouched.
pub fn effectiveBits(f: SymbolFlags) u32 {
    var bits = f.bits();
    if (f.import_binding and f.type_only) {
        bits &= ~fbits(.{ .import_binding = true });
        bits |= fbits(.{ .type_alias = true });
    }
    if (f.ns_uninstantiated) bits &= ~fbits(.{ .namespace_decl = true });
    return bits;
}

/// The flag bits a symbol carrying `f` cannot merge with — tsc's
/// `getExcludedSymbolFlags`, the union of each individual declaration meaning's
/// excludes mask. One symbol spans value and type space, so e.g. `var` excludes
/// other value declarations but not `interface`.
///
/// This is the single definition of the rule: the binder's per-declaration-kind
/// `DeclKind.excludes` is `excludesOfFlags(kind.flags())`, and the linker's
/// cross-file global merge asks it about a whole folded symbol.
pub fn excludesOfFlags(f: SymbolFlags) u32 {
    var x: u32 = 0;
    // var+var and var+param merge; everything else valueish clashes. A
    // namespace merges with function/class/enum/interface, so those meanings
    // whitelist the namespace bit (and vice-versa below).
    if (f.var_decl) x |= mask_value & ~(fbits(.{ .var_decl = true }) | fbits(.{ .param = true }));
    if (f.let_decl or f.const_decl or f.catch_param) x |= mask_value;
    // A function also merges with a *class* — tsc's `FunctionExcludes` omits
    // `Class` and `ClassExcludes` omits `Function`, so a `.d.ts` can model a
    // callable class (`function UAParser(…): IResult` next to `class UAParser`).
    // The pair is only legal when every class declaration is ambient;
    // `checkFunctionClassMerge` reports TS2813/TS2814 otherwise.
    if (f.function) x |= mask_value & ~(fbits(.{ .function = true }) |
        fbits(.{ .namespace_decl = true }) | fbits(.{ .class = true }));
    if (f.class) x |= (mask_value & ~(fbits(.{ .class = true }) |
        fbits(.{ .namespace_decl = true }) | fbits(.{ .function = true }))) |
        (mask_type & ~(fbits(.{ .interface = true }) | fbits(.{ .namespace_decl = true })));
    if (f.interface) x |= mask_type & ~(fbits(.{ .interface = true }) |
        fbits(.{ .class = true }) | fbits(.{ .namespace_decl = true }));
    // A type alias also merges with a namespace (the alias carries the type
    // meaning; the namespace the value + container meaning).
    if (f.type_alias) x |= mask_type & ~fbits(.{ .namespace_decl = true });
    // Two enum blocks (incl. const enum) with the same name merge; everything
    // else in value or type space clashes (bar namespace).
    if (f.enum_decl) x |= (mask_value | mask_type) &
        ~(fbits(.{ .enum_decl = true }) | fbits(.{ .namespace_decl = true }));
    // tsc's `EnumMemberExcludes = EnumMember`: members share a table with
    // nothing else, so only another member of the same name clashes.
    if (f.enum_member) x |= fbits(.{ .enum_member = true });
    // A namespace merges with another namespace, function, class, enum,
    // interface, and type alias; it clashes with var/let/const. A
    // non-instantiated one is tsc's `NamespaceModuleExcludes = 0`.
    if (f.namespace_decl and !f.ns_uninstantiated) {
        x |= (mask_value & ~(fbits(.{ .namespace_decl = true }) | fbits(.{ .function = true }) |
            fbits(.{ .class = true }) | fbits(.{ .enum_decl = true }))) |
            (mask_type & ~(fbits(.{ .namespace_decl = true }) | fbits(.{ .interface = true }) |
                fbits(.{ .class = true }) | fbits(.{ .enum_decl = true }) | fbits(.{ .type_alias = true })));
    }
    if (f.type_param) x |= mask_type & ~fbits(.{ .class = true });
    if (f.param) x |= mask_value & ~fbits(.{ .var_decl = true });
    if (f.import_binding) x |= if (f.type_only)
        mask_type | fbits(.{ .import_binding = true })
    else
        mask_value | mask_type;
    if (f.property) x |= mask_member;
    if (f.method) x |= mask_member & ~fbits(.{ .method = true });
    if (f.getter) x |= mask_member & ~fbits(.{ .setter = true });
    if (f.setter) x |= mask_member & ~fbits(.{ .getter = true });
    // Repeated `fn.prop = …` statements are all declarations of the same
    // property; they merge (the member type unions them), so `expando_member`
    // contributes nothing.
    return x;
}

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
    /// Fell out of a `default`-less switch because no clause matched.
    /// a = antecedent (pre-switch flow), b = the switch statement node.
    /// Whether this edge exists at all is a *type* question — an exhaustive
    /// switch over a literal-union discriminant never takes it — so the binder
    /// always emits it and the checker decides.
    switch_no_match,
    /// A call whose result the flow graph has to remember: a statement-position
    /// dotted-name call (a candidate assertion function) or a `super(...)` call
    /// anywhere. a = antecedent, b = the call node. tsc's `FlowFlags.Call`,
    /// which serves the same two purposes (`getTypeAtFlowCall` and
    /// `isPostSuperFlowNode`). The checker resolves an assertion callee lazily
    /// and a `super` callee resolves to nothing, so for the checker a super
    /// call is a plain pass-through; the binder's `this`-before-`super` walk is
    /// the only reader that cares which it is.
    call_stmt,
    /// A mutation that can grow an EVOLVING array: `x.push(…)`, `x.unshift(…)`
    /// or `x[i] = v`. a = antecedent, b = the call / assignment node. tsc's
    /// `FlowFlags.ArrayMutation`, created by `bindCallExpressionFlow` and
    /// `bindBinaryExpressionFlow`. Only a query for the mutated variable's own
    /// bare reference reads it (see `getTypeAtFlowArrayMutation`); for every
    /// other reference it is a pass-through.
    array_mutation,
};

pub const ImportKind = enum(u8) { default, namespace, named, side_effect, equals };
/// `ns_named` is `namespace N { export { x as y }; }` — an export of the
/// NAMESPACE, not of the module the namespace lives in. It is recorded so the
/// linker can read a namespace's aliases (see `exportEqualsMember`) and is
/// skipped everywhere a module's own export table is built.
pub const ExportKind = enum(u8) { named, default, reexport_named, reexport_all, reexport_ns, equals, ns_named };

/// One imported binding; feeds the module graph.
pub const ImportRec = struct {
    /// Local binding name (0 for side-effect imports).
    local: Atom,
    /// Name in the source module ("default", "*", or the named export).
    imported: Atom,
    /// Module specifier string contents (no quotes).
    module: Atom,
    /// The import_decl node (for diagnostics).
    node: Node,
    kind: ImportKind,
    type_only: bool,
    /// Scope the local binding was declared in. Almost always the file scope;
    /// a `declare module "spec" { import … }` block declares its imports in the
    /// block's own scope, and the linker has to look them up there.
    scope: ScopeId = file_scope,
};

/// One exported binding; feeds the module graph.
pub const ExportRec = struct {
    /// External name ("default" for default exports, 0 for `export *`).
    exported: Atom,
    /// Local name (or source-module name for re-exports; 0 if none).
    local: Atom,
    /// Module specifier for re-exports, 0 otherwise.
    module: Atom,
    /// Locally-bound symbol (0 for re-exports / anonymous default).
    sym: SymbolId,
    /// The export_* node (for diagnostics).
    node: Node,
    kind: ExportKind,
    type_only: bool,
    /// Scope the `export { … }` statement textually lives in. Almost always
    /// the file scope; a `declare module "spec" { … export { X }; }` block or a
    /// `namespace N { export { X }; }` body resolves `X` from *there*, walking
    /// outward, exactly as tsc's `resolveName` walks the node parent chain.
    /// Looking only at file scope reported TS2304 for every such re-export.
    scope: ScopeId = file_scope,
};

/// An identifier reference that did not resolve in-file (usually a global
/// or a name the linker will resolve; not a bind error).
pub const Ref = struct {
    atom: Atom,
    node: Node,
    scope: ScopeId,
};

/// One `declare module "spec" { … }` block: the specifier atom (no
/// quotes), the body scope whose `export`ed *declarations* are exports, and
/// the range of this block's `export` records (`export default` / `export { … }`
/// forms that don't set an `exported` flag).
pub const AmbientModule = struct {
    spec: Atom,
    scope: ScopeId,
    export_start: u32,
    export_end: u32,
};

/// The sealed bind result for one file. All slices live in the per-file
/// arena; nothing is freed individually and nothing mutates after `bind`.
///
/// The one exception is `remapAtoms`, the single post-seal writer: it rewrites
/// every stored atom id in place after `Interner.renumber`. The nine fields it
/// touches — `symbol_names`, `member_atoms`, `member_syms`, `global_atoms`,
/// `global_syms`, `imports`, `exports`, `unresolved`, `ambient_modules` — are
/// therefore declared as MUTABLE slices; every other field is `const` and is
/// genuinely immutable from the moment `bind` returns.
pub const Bind = struct {
    // --- symbols (SoA; index 0 is a reserved dummy) -----------------------
    /// Remapped post-seal (atom ids).
    symbol_names: []Atom,
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
    /// Remapped post-seal (atom ids, then re-sorted per segment).
    member_atoms: []Atom,
    /// Permuted post-seal alongside `member_atoms`.
    member_syms: []SymbolId,

    /// Class/interface symbol -> members scope, sorted by symbol id.
    member_scope_syms: []const SymbolId,
    member_scope_ids: []const ScopeId,
    /// Class symbol -> statics scope, sorted by symbol id.
    static_scope_syms: []const SymbolId,
    static_scope_ids: []const ScopeId,
    /// Namespace symbol -> (merged) body scope, sorted by symbol id. Kept
    /// separate from member_scope_* so a class/interface merged with a
    /// namespace keeps its own member scope distinct from the namespace body.
    ns_scope_syms: []const SymbolId,
    ns_scope_ids: []const ScopeId,
    /// Expando-function symbol -> the scope holding its `fn.prop = …`
    /// property symbols, sorted by symbol id. Empty for a file with no
    /// expando functions (the common case).
    expando_scope_syms: []const SymbolId = &.{},
    expando_scope_ids: []const ScopeId = &.{},
    /// Enum symbol -> its member scope, sorted by symbol id. Every block of a
    /// merged `enum E` shares the one entry. Empty for a file with no enums.
    enum_scope_syms: []const SymbolId = &.{},
    enum_scope_ids: []const ScopeId = &.{},

    // --- flow graph (SoA; 0 = none, 1 = shared unreachable) ---------------
    flow_tags: []const FlowTag,
    flow_a: []const u32,
    flow_b: []const u32,
    /// Lexical scope active when each flow node was bound. Read for the
    /// expression-bearing tags (assign/cond/call_stmt/switch_clause) so that
    /// flow-time re-evaluation of those expressions (e.g. a guard/assertion
    /// callee reached via a loop back-edge) resolves names in the scope where
    /// the expression textually lives, not the ambient scope of the reference
    /// whose flow is being computed.
    flow_scopes: []const ScopeId,
    /// Antecedent lists for branch/loop labels.
    flow_extra: []const FlowId,
    /// Compact node -> flow attachment map, sorted by node.
    flow_map_nodes: []const Node,
    flow_map_ids: []const FlowId,

    /// tsc's `isEvolvingArrayOperationTarget`: the identifier reads that are
    /// `x` in `x.length`, `x.push(…)`, `x.unshift(…)` or `x[i] = v`. Such a
    /// read of an evolving array answers with the *auto* array type rather
    /// than with the evolved one — the operation is what BUILDS the array, so
    /// it must not be checked against what has been put in it so far — and it
    /// is exempt from the TS7034/TS7005 pair.
    ///
    /// Only the binder can answer it: the predicate is about the read's
    /// PARENT, and the AST carries no parent links. Sorted by node; empty for
    /// the overwhelming majority of files.
    array_op_nodes: []const Node = &.{},
    /// Positionally aligned with `array_op_nodes`: the INDEX expression of an
    /// `x[i] = v` target (whose type still has to be number-like for tsc's
    /// predicate to hold — a type question the binder cannot answer), or
    /// `null_node` for the three property forms, which qualify outright.
    array_op_indexes: []const Node = &.{},

    /// Remapped post-seal (atom ids).
    imports: []ImportRec,
    /// Remapped post-seal (atom ids).
    exports: []ExportRec,
    /// References that did not resolve in-file, in traversal order.
    /// Remapped post-seal (atom ids).
    unresolved: []Ref,
    diagnostics: []const Diagnostic,

    // --- global contributions --------------------------------------
    /// True when this file is a *module* (has any top-level import/export).
    /// A module contributes to the program global table only through
    /// `declare global { … }` blocks; a *script* contributes its whole top
    /// level. Drives the linker's cross-file merge (modules.zig).
    is_module: bool = false,
    /// This file's global contributions, sorted by name atom, holding LOCAL
    /// SymbolIds: the whole file scope for a script/the lib, or the union of
    /// `declare global` block members for a module. Empty for the typical
    /// app module — the linker skips such files entirely (pay-per-use).
    /// Remapped post-seal (atom ids, then re-sorted run by run) unless it is
    /// a view of `member_atoms`, which `remapAtoms` has already rewritten.
    global_atoms: []Atom = &.{},
    /// Permuted post-seal alongside `global_atoms`.
    global_syms: []SymbolId = &.{},
    /// Split point inside `global_atoms`/`global_syms`: entries below it come
    /// from this file's own top level (a *script*'s ambient/declared globals),
    /// entries from it on come from `declare global { … }` / bare `global { … }`
    /// blocks. tsc merges the two classes in separate passes — every script's
    /// top level first, then every global *augmentation* — so the linker needs
    /// the boundary to reproduce that precedence (modules.zig `mergeGlobals`).
    global_aug_start: u32 = 0,
    /// Start offset of each atom-sorted run inside `global_atoms`. The slice is
    /// a *concatenation* of sorted segments (the file scope, the UMD entry,
    /// then one per `global { … }` block), not one sorted array, and
    /// `remapAtoms` has to restore exactly that shape after atom ids move.
    /// Empty means the whole slice is a single run.
    global_runs: []const u32 = &.{},
    /// Every atom this file interned or looked up, in first-touch order — the
    /// file's slice of the program-wide interning order. The driver replays
    /// these in file order to reassign atom ids deterministically
    /// (`Interner.renumber`); nothing else reads it, and `remapAtoms`
    /// deliberately leaves it alone (it is the map's *input*).
    first_touch: []const Atom = &.{},
    /// `declare module "spec" { … }` blocks in this file. The linker
    /// harvests each block scope's exported members into a program ambient
    /// module keyed by `spec`, which imports of `"spec"` resolve against (and
    /// which augments a real module's exports when `"spec"` also resolves).
    /// Remapped post-seal (atom ids).
    ambient_modules: []AmbientModule = &.{},

    // --- atom renumbering ----------------------------------------------------

    /// Number of `Bind` fields `remapAtoms` was written against. Bumping this
    /// is the reminder the test below enforces: a new field that holds an
    /// `Atom` (directly or inside a record) has to be rewritten here too, or
    /// the parallel front end ships a file whose names point at the wrong
    /// strings.
    ///
    /// internal: read by the binder test that enforces the reminder.
    /// (41 includes `enum_scope_syms`/`enum_scope_ids`, which hold symbol and
    /// scope ids, and `array_op_nodes`/`array_op_indexes`, which hold node
    /// ids — no atoms — so they need no rewrite.)
    pub const remap_field_count = 41;

    /// Rewrite every atom this file stored through `map` (old atom -> new
    /// atom), restoring the atom-sorted order of the tables that have one.
    /// Called once, on the main thread, after `Interner.renumber` and before
    /// anything reads the file — see main.zig's renumbering block.
    ///
    /// `scratch` is used for the re-sorts and can be released on return.
    pub fn remapAtoms(b: *Bind, scratch: Allocator, map: []const Atom) Error!void {
        comptime std.debug.assert(@typeInfo(Bind).@"struct".fields.len == remap_field_count);

        for (b.symbol_names) |*a| a.* = map[a.*];
        for (b.imports) |*rec| {
            rec.local = map[rec.local];
            rec.imported = map[rec.imported];
            rec.module = map[rec.module];
        }
        for (b.exports) |*rec| {
            rec.exported = map[rec.exported];
            rec.local = map[rec.local];
            rec.module = map[rec.module];
        }
        for (b.unresolved) |*ref| ref.atom = map[ref.atom];
        for (b.ambient_modules) |*am| am.spec = map[am.spec];

        // The member table is sorted by atom within each scope's segment, and
        // `lookupInScope` binary-searches it: remap, then restore the order.
        const members = b.member_atoms;
        const syms = b.member_syms;
        for (members) |*a| a.* = map[a.*];
        for (0..b.scope_members_start.len - 1) |s| {
            const lo = b.scope_members_start[s];
            const hi = b.scope_members_start[s + 1];
            try sortRun(scratch, members[lo..hi], syms[lo..hi]);
        }

        // `global_atoms` is either a view of one of those segments (already
        // done above) or a private concatenation of sorted runs.
        if (b.global_atoms.len != 0 and !overlaps(b.global_atoms, b.member_atoms)) {
            const gatoms = b.global_atoms;
            const gsyms = b.global_syms;
            for (gatoms) |*a| a.* = map[a.*];
            if (b.global_runs.len == 0) {
                try sortRun(scratch, gatoms, gsyms);
            } else {
                for (b.global_runs, 0..) |start, i| {
                    const end = if (i + 1 < b.global_runs.len) b.global_runs[i + 1] else @as(u32, @intCast(gatoms.len));
                    try sortRun(scratch, gatoms[start..end], gsyms[start..end]);
                }
            }
        }
    }

    /// Re-sort one (atom, symbol) run by atom. Names are unique within a run,
    /// so the order is total and an unstable sort is deterministic.
    fn sortRun(scratch: Allocator, atoms: []Atom, syms: []SymbolId) Error!void {
        if (atoms.len < 2) return;
        const Pair = struct { a: Atom, s: SymbolId };
        const pairs = try scratch.alloc(Pair, atoms.len);
        defer scratch.free(pairs);
        for (pairs, atoms, syms) |*p, a, s| p.* = .{ .a = a, .s = s };
        std.mem.sort(Pair, pairs, {}, struct {
            fn lessThan(_: void, x: Pair, y: Pair) bool {
                return x.a < y.a;
            }
        }.lessThan);
        for (pairs, atoms, syms) |p, *a, *s| {
            a.* = p.a;
            s.* = p.s;
        }
    }

    fn overlaps(inner: []const Atom, outer: []const Atom) bool {
        if (outer.len == 0) return false;
        const p = @intFromPtr(inner.ptr);
        return p >= @intFromPtr(outer.ptr) and p < @intFromPtr(outer.ptr + outer.len);
    }

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
    /// Value/type space is not distinguished at bind time (the checker filters by
    /// symbol flags in the checker). Returns null when unresolved (not an error).
    ///
    /// internal: used by binder.zig's `seal` and by the binder tests; nothing
    /// downstream of the front end resolves against a single file's `Bind`
    /// (the linker's cross-file resolution supersedes it).
    pub fn resolve(b: *const Bind, atom: Atom, scope: ScopeId) ?SymbolId {
        var s = scope;
        while (true) {
            if (b.lookupInScope(s, atom)) |sym| return sym;
            if (s == file_scope) return null;
            s = b.scope_parents[s];
        }
    }

    /// `resolve`, then the file's own `global { … }` block scopes as a last
    /// resort — the file-local half of tsc's "lexical chain, then globals"
    /// fallback. Used while sealing, where the program global table does not
    /// exist yet; the scopes are the binder's, not `Bind`'s, so they are
    /// passed in.
    ///
    /// internal: used by binder.zig's `seal` only.
    pub fn resolveWithGlobals(b: *const Bind, atom: Atom, scope: ScopeId, global_scopes: []const ScopeId) ?SymbolId {
        if (b.resolve(atom, scope)) |sym| return sym;
        for (global_scopes) |gs| {
            if (b.lookupInScope(gs, atom)) |sym| return sym;
        }
        return null;
    }

    /// Members scope of a class/interface symbol (instance side), if any.
    pub fn membersScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.member_scope_syms, b.member_scope_ids, sym);
    }

    /// Statics scope of a class symbol, if any.
    pub fn staticsScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.static_scope_syms, b.static_scope_ids, sym);
    }

    /// Body scope of a namespace symbol, if any.
    pub fn namespaceScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.ns_scope_syms, b.ns_scope_ids, sym);
    }

    /// Member scope of an enum symbol — where its member symbols live and
    /// where a member initializer's names resolve (`bindEnum`).
    pub fn enumScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.enum_scope_syms, b.enum_scope_ids, sym);
    }

    /// The enum symbol whose members live in `scope`, or null when `scope` is
    /// not an enum body. The reverse of `enumScopeOf`; enums per file are few,
    /// so the pair list is scanned rather than carrying a second sorted copy.
    pub fn enumOfScope(b: *const Bind, scope: ScopeId) ?SymbolId {
        for (b.enum_scope_ids, b.enum_scope_syms) |id, sym| {
            if (id == scope) return sym;
        }
        return null;
    }

    /// Expando-property scope of a function symbol, if any.
    pub fn expandoScopeOf(b: *const Bind, sym: SymbolId) ?ScopeId {
        return searchPair(b.expando_scope_syms, b.expando_scope_ids, sym);
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
            .assign, .cond_true, .cond_false, .switch_clause, .switch_no_match, .start, .call_stmt, .array_mutation => b.flow_b[flow],
            else => 0,
        };
    }

    /// Is `node` one of tsc's evolving-array operation targets, and if so what
    /// index expression (if any) still has to be number-like? See
    /// `array_op_nodes`. The outer optional is "is a target at all"; the
    /// payload is `null_node` for the property forms.
    pub fn arrayOpTarget(b: *const Bind, node: Node) ?Node {
        var lo: usize = 0;
        var hi: usize = b.array_op_nodes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const n = b.array_op_nodes[mid];
            if (n == node) return b.array_op_indexes[mid];
            if (n < node) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Lexical scope in which `flow`'s expression node was bound.
    pub fn flowScope(b: *const Bind, flow: FlowId) ScopeId {
        return b.flow_scopes[flow];
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
            b.static_scope_syms.len * 2 * @sizeOf(u32) +
            b.ns_scope_syms.len * 2 * @sizeOf(u32) +
            b.enum_scope_syms.len * 2 * @sizeOf(u32);
    }

    /// Exact bytes of the sealed flow graph + node attachment map.
    pub fn flowBytes(b: *const Bind) usize {
        return b.flow_tags.len * (@sizeOf(FlowTag) + 2 * @sizeOf(u32) + @sizeOf(ScopeId)) +
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

    /// Forwards to bind_dump.zig; kept as a method so callers stay put.
    pub fn dump(
        b: *const Bind,
        io: Io,
        interner: *Interner,
        tree: *const Ast,
        src: []const u8,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return @import("bind_dump.zig").dump(b, io, interner, tree, src, w);
    }
};
