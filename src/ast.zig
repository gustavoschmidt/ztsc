//! Data-oriented AST (M2), modeled on the Zig compiler's own Ast.
//!
//! Design (ROADMAP.md §2.1):
//!
//! - **Nodes are `u32` indices** (`Node`); there are no pointers anywhere.
//! - **Storage is struct-of-arrays** (`std.MultiArrayList`): `tag` (1 byte),
//!   `main_token` (4-byte token index), `data { lhs, rhs }` (8 bytes) live in
//!   parallel arrays: 13 bytes/node before `extra_data` amortization.
//! - **Variable-length children** (statement lists, argument lists, union
//!   members, ...) live in the shared `extra_data: []u32` side array, either
//!   as a `[start, end)` range of node indices or as a small fixed struct
//!   read via `extraData(T, index)`.
//! - **OptionalNode encoding: `0` means "none"** (`null_node`). Node 0 is
//!   always the root, and the root is never anyone's child, so 0 is free as a
//!   sentinel. The same convention applies to optional extra_data indices
//!   (extra_data[0] is a reserved dummy word) and to optional *token* indices
//!   stored in node data (token 0 can never be a name/label token of any
//!   construct that stores one, because at least one token — `class`, `.`,
//!   `break`, ... — always precedes it). `maxInt` is *not* used as a sentinel
//!   anywhere.
//! - Out-of-subset constructs (enums, namespaces, decorators,
//!   conditional/mapped types, JSX, ...) become an `.unsupported` node
//!   spanning `main_token ..= data.rhs` (a token range), paired with an
//!   `unsupported_syntax` diagnostic — never a crash (ROADMAP.md §6).
//!
//! The AST is produced into the per-file arena by parser.zig and sealed
//! (read-only) after parse; nothing here mutates after `Parse.parse` returns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");

pub const Span = source.Span;
pub const Diagnostic = diagnostics.Diagnostic;
pub const TokenIndex = u32;

/// Index into `Ast.nodes`. 0 is the root; as a child reference, 0 = none.
pub const Node = u32;
pub const null_node: Node = 0;

/// Index into `Ast.extra_data`. 0 is a reserved dummy word, so 0 = none.
pub const ExtraIndex = u32;

/// A `[start, end)` range of `extra_data` words holding node indices.
pub const SubRange = struct { start: ExtraIndex, end: ExtraIndex };

/// Modifier / flag bits, stored in extra_data words where a construct
/// carries modifiers. Kept as plain constants (not packed struct) so flags
/// live in ordinary u32 extra words.
pub const Flags = struct {
    pub const async: u32 = 1 << 0;
    pub const generator: u32 = 1 << 1;
    pub const declare: u32 = 1 << 2;
    pub const static: u32 = 1 << 3;
    pub const public: u32 = 1 << 4;
    pub const private: u32 = 1 << 5;
    pub const protected: u32 = 1 << 6;
    pub const readonly: u32 = 1 << 7;
    pub const abstract: u32 = 1 << 8;
    pub const override: u32 = 1 << 9;
    pub const optional: u32 = 1 << 10; // `?` on params/members
    pub const definite: u32 = 1 << 11; // `!` on fields/declarators
    pub const get: u32 = 1 << 12;
    pub const set: u32 = 1 << 13;
    pub const type_only: u32 = 1 << 14; // `import type` / `export type`
    pub const rest: u32 = 1 << 15; // `...` param
    pub const accessor: u32 = 1 << 16;
    pub const const_enum: u32 = 1 << 17; // `const enum`
    pub const computed: u32 = 1 << 18; // `[Symbol.iterator]` well-known-symbol key
};

/// Maps a well-known `Symbol` property name (the `iterator` in
/// `[Symbol.iterator]`) to the synthetic member key the binder and checker
/// share for it. The `__@` prefix cannot appear in a real identifier, so a
/// synthetic key never collides with an ordinary member. Returns null for
/// names ztsc does not model (those stay out of subset).
pub fn wellKnownSymbolKey(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { n: []const u8, k: []const u8 }{
        .{ .n = "iterator", .k = "__@iterator" },
        .{ .n = "asyncIterator", .k = "__@asyncIterator" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p.n)) return p.k;
    }
    return null;
}

pub const NodeItem = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,
};

pub const Data = struct {
    lhs: u32,
    rhs: u32,
};

/// Node tags. Each tag documents its `main_token` and `data` layout.
/// Legend: `lhs`/`rhs` hold a Node unless stated; `extra→T` means the field
/// is an ExtraIndex of struct T; `range` means lhs..rhs is a SubRange of
/// node indices in extra_data; `token` means a TokenIndex.
pub const Tag = enum(u8) {
    /// Whole file. `range` of top-level statements. main_token = first token.
    root,

    // --- leaves ----------------------------------------------------------
    /// main_token = the identifier (or contextual-keyword) token. No data.
    /// Also used directly as a type ("number", "Foo") and as a literal type
    /// keyword; the grammar position, not the tag, decides value vs. type.
    identifier,
    /// main_token = number token. Doubles as a literal type.
    number_literal,
    /// main_token = string token. Doubles as a literal type / module name.
    string_literal,
    bigint_literal,
    regex_literal,
    /// No-substitution template literal token.
    template_literal,
    true_literal,
    false_literal,
    null_literal,
    this_expr,
    super_expr,
    /// `import` used as a call target (dynamic import `import(x)`).
    import_expr,
    /// Elided array element / pattern hole (`[a, , b]`).
    omitted,
    /// Placeholder produced where the grammar required an expression/type
    /// but none could be parsed (a diagnostic always accompanies it).
    error_node,
    /// Out-of-subset construct, parsed over without understanding.
    /// main_token = first token, data.rhs = last token (inclusive).
    unsupported,

    // --- expressions -------------------------------------------------------
    /// `(expr)` lhs = inner. main_token = `(`.
    paren_expr,
    /// `[a, b, ...c]` range of elements. main_token = `[`.
    array_literal,
    /// `{a: 1, b, ...c}` range of properties. main_token = `{`.
    object_literal,
    /// `key: value`. main_token = key's first token; lhs = key node
    /// (identifier/string/number/computed_name), rhs = value.
    object_property,
    /// `{ a }` / `{ a = 1 }` (cover grammar). main_token = name token;
    /// lhs = identifier node, rhs = optional default initializer.
    object_shorthand,
    /// `{ m() {} }`. lhs = key node, rhs = function_expr node.
    object_method,
    /// `...expr` in array/object literals and call arguments. lhs = expr.
    spread_element,
    /// `[expr]` computed property key. lhs = expr. main_token = `[`.
    computed_name,
    /// `` `a${x}b` `` main_token = template_head token; `range` of
    /// substitution expressions (string parts live in the token stream).
    template_expr,
    /// ``tag`x` `` lhs = tag expr, rhs = template node.
    tagged_template,
    /// Binary operator. main_token = operator token (which identifies the
    /// op: + - * / % ** == != === !== < > <= >= << >> >>> & | ^ && || ??
    /// instanceof in). lhs, rhs = operands.
    binary,
    /// Assignment (incl. compound). main_token = op token (= += &&= ...).
    assign,
    /// `c ? t : f`. main_token = `?`; lhs = cond, rhs = extra→CondExpr.
    cond_expr,
    /// `a, b` sequence. main_token = `,`; lhs, rhs.
    seq_expr,
    /// Prefix op: ! ~ + - ++ -- typeof void delete await.
    /// main_token = op token; lhs = operand.
    prefix_unary,
    /// Postfix `++`/`--`. main_token = op token; lhs = operand.
    postfix_unary,
    /// `expr!`. main_token = `!`; lhs = operand.
    non_null,
    /// `expr as T`. main_token = `as`; lhs = expr, rhs = type.
    as_expr,
    /// `expr satisfies T`. main_token = `satisfies`; lhs = expr, rhs = type.
    satisfies_expr,
    /// The `const` type in an `expr as const` const assertion. Leaf;
    /// main_token = the `const` keyword. Only valid as an `as_expr` rhs.
    const_type,
    /// Type predicate in return-type position: `x is T`, `asserts x is T`,
    /// or `asserts x`. main_token = the guarded parameter's name token (or
    /// `this`); lhs = target type node (0 for a bare `asserts x`);
    /// rhs = flags (bit0 = `asserts`).
    type_predicate,
    /// `obj.name`. main_token = `.`; lhs = object, rhs = name token.
    member_expr,
    /// `obj?.name`. main_token = `?.`; lhs = object, rhs = name token.
    optional_member_expr,
    /// `obj[index]`. main_token = `[`; lhs = object, rhs = index.
    index_expr,
    /// `obj?.[index]`. main_token = `?.`; lhs = object, rhs = index.
    optional_index_expr,
    /// `f(args)`. main_token = `(`; lhs = callee, rhs = extra→SubRange args.
    call_expr,
    /// `f<T>(args)`. main_token = `(`; lhs = callee, rhs = extra→CallInfo.
    call_expr_targs,
    /// `f?.(args)` / `f?.<T>(args)`. main_token = `?.`; lhs = callee,
    /// rhs = extra→CallInfo.
    optional_call,
    /// `new C` (no parens). main_token = `new`; lhs = callee, rhs unused.
    new_expr_bare,
    /// `new C(args)`. main_token = `new`; lhs = callee, rhs = extra→SubRange.
    new_expr,
    /// `new C<T>(args)`. main_token = `new`; lhs = callee, rhs = extra→CallInfo.
    new_expr_targs,
    /// `(a, b) => body`. main_token = `=>`; lhs = extra→FnProto,
    /// rhs = body (expression or block).
    arrow_fn,
    /// `function f() {}` in expression position. main_token = `function`;
    /// lhs = extra→FnProto, rhs = body block.
    function_expr,
    /// `yield` / `yield x` / `yield* x` (parsed; generators are flagged at
    /// the `function*` site). main_token = `yield`; lhs = optional operand,
    /// rhs = 1 if delegating (`yield*`).
    yield_expr,

    // --- JSX (parsed only in `.tsx` files) ---------------------------------
    /// `<tag ...>children</tag>`, `<tag ... />`, or `<>children</>`.
    /// main_token = `<`; lhs = extra→JsxElementData.
    jsx_element,
    /// `name`, `name="v"`, or `name={expr}`. main_token = name token;
    /// lhs = value node (0 = boolean shorthand).
    jsx_attribute,
    /// `{...expr}` in an attribute list. main_token = `{`; lhs = expr.
    jsx_spread_attribute,
    /// `{expr}` as an attribute value or a child. main_token = `{`;
    /// lhs = expr (0 = empty `{}`).
    jsx_expr_container,
    /// Children text between JSX tags. main_token = the `jsx_text` token.
    jsx_text,

    // --- patterns (declarations & params; expression LHS destructuring uses
    // the literal cover grammar: `[a,b] = c` keeps an array_literal LHS) ----
    /// `[a, b = 1, ...r]` range of elements. main_token = `[`.
    array_pattern,
    /// `{a, b: c, ...r}` range of properties. main_token = `{`.
    object_pattern,
    /// `key`, `key: target`, `key: target = init`, `key = init`.
    /// main_token = key token; lhs = optional target pattern (0 =
    /// shorthand), rhs = optional default initializer.
    binding_property,
    /// `pattern = default` inside array patterns / params-as-patterns.
    /// main_token = `=`; lhs = pattern, rhs = default expr.
    binding_default,
    /// `...pattern` in patterns. main_token = `...`; lhs = pattern.
    rest_element,

    // --- statements --------------------------------------------------------
    /// `{ ... }` range of statements. main_token = `{`.
    block,
    /// `var/let/const` with one declarator (the common case).
    /// main_token = `var`/`let`/`const`; lhs = declarator node.
    var_decl_one,
    /// `var/let/const` with 2+ declarators: `range` of declarator nodes.
    var_decl,
    /// `name` (no type, no init). main_token = first name token;
    /// lhs = name node (identifier or pattern).
    declarator,
    /// `name = init` (no type annotation). lhs = name node, rhs = init.
    declarator_init,
    /// `name: T [= init]` / `name! : T`. lhs = name node,
    /// rhs = extra→DeclaratorFull.
    declarator_full,
    /// Expression statement. lhs = expr.
    expr_stmt,
    /// `;`
    empty_stmt,
    /// `if (c) s`. main_token = `if`; lhs = cond, rhs = then-statement.
    if_stmt,
    /// `if (c) s else e`. lhs = cond, rhs = extra→IfElse.
    if_else_stmt,
    /// `while (c) s`. lhs = cond, rhs = body.
    while_stmt,
    /// `do s while (c);`. lhs = body, rhs = cond.
    do_stmt,
    /// `for (init; cond; update) body`. lhs = extra→For, rhs = body.
    for_stmt,
    /// `for (left in right) body`. lhs = extra→ForInOf, rhs = body.
    for_in_stmt,
    /// `for (left of right) body`. lhs = extra→ForInOf, rhs = body.
    for_of_stmt,
    /// `switch (d) { clauses }`. lhs = discriminant, rhs = extra→SubRange
    /// of case_clause/default_clause nodes.
    switch_stmt,
    /// `case e: stmts`. main_token = `case`; lhs = test expr,
    /// rhs = extra→SubRange of statements.
    case_clause,
    /// `default: stmts`. main_token = `default`; rhs = extra→SubRange.
    default_clause,
    /// `try b catch ... finally ...`. lhs = try block, rhs = extra→Try.
    try_stmt,
    /// `catch (e) b` / `catch b`. main_token = `catch`; lhs = optional
    /// binding (identifier/pattern/declarator_full for `e: unknown`),
    /// rhs = block.
    catch_clause,
    /// `throw e;` lhs = expr.
    throw_stmt,
    /// `return;` / `return e;` lhs = optional expr.
    return_stmt,
    /// `break;` / `break label;` lhs = optional label token (0 = none).
    break_stmt,
    /// `continue;` / `continue label;` lhs = optional label token.
    continue_stmt,
    /// `label: stmt`. main_token = label token; lhs = statement.
    labeled_stmt,
    /// `debugger;`
    debugger_stmt,

    // --- declarations ------------------------------------------------------
    /// `function f() {}` / overload signature (no body).
    /// main_token = `function`; lhs = extra→FnProto, rhs = optional body.
    function_decl,
    /// `class C ... { ... }` (also class expressions). main_token = `class`;
    /// lhs = extra→ClassData, rhs unused.
    class_decl,
    /// `extends Base<T>` / `implements I<T>` entry. main_token = first token
    /// of the expression; lhs = expr node, rhs = extra→SubRange of type args
    /// (0 = none).
    heritage,
    /// Class field. main_token = name token; lhs = extra→Field.
    class_field,
    /// Class method / constructor / accessor / overload signature.
    /// main_token = name token; lhs = extra→FnProto, rhs = optional body.
    class_method,
    /// `interface I<T> extends A, B { members }`. main_token = `interface`;
    /// lhs = extra→InterfaceData, rhs unused.
    interface_decl,
    /// `type A<T> = U`. main_token = `type`; lhs = extra→TypeAlias,
    /// rhs = aliased type node.
    type_alias,
    /// `enum E { ... }` / `const enum E { ... }`. main_token = `enum`
    /// (or `const` for a const enum); lhs = extra→EnumData, rhs unused.
    enum_decl,
    /// An enum member `Name` / `Name = expr`. main_token = name token;
    /// lhs = optional initializer expression (0 = none).
    enum_member,
    /// `namespace N { ... }` / `module N { ... }` (identifier-named).
    /// main_token = `namespace`/`module` keyword; lhs = extra→NamespaceData,
    /// rhs unused. A namespace is both a value (an object of its exported
    /// members) and a type/namespace container.
    namespace_decl,
    /// Type parameter `T extends C = D`. main_token = name token;
    /// lhs = optional constraint, rhs = optional default.
    type_param,
    /// Parameter `name: T` (no flags, no initializer; covers the common
    /// case). main_token = first token; lhs = name node (identifier or
    /// pattern), rhs = optional type.
    param,
    /// Parameter with `?`, `...`, initializer, or modifiers.
    /// main_token = first token; lhs = name node, rhs = extra→ParamFull.
    param_full,

    // --- modules -----------------------------------------------------------
    /// `import ... from "m"` / `import "m"`. main_token = `import`;
    /// lhs = extra→ImportData, rhs = module string token.
    import_decl,
    /// `a` / `a as b` / `type a as b` in import braces. main_token =
    /// imported name token; lhs = optional alias token, rhs = flags.
    import_specifier,
    /// `export { a, b as c } [from "m"]`. main_token = `export`;
    /// lhs = extra→ExportNamed, rhs = optional module string token.
    export_named,
    /// `a` / `a as b` in export braces. main_token = local name token;
    /// lhs = optional alias token, rhs = flags.
    export_specifier,
    /// `export * [as ns] from "m"`. main_token = `export`;
    /// lhs = extra→ExportAll, rhs = module string token.
    export_all,
    /// `export <decl>`. main_token = `export`; lhs = declaration node.
    export_decl,
    /// `export default <expr-or-decl>`. main_token = `export`; lhs = node.
    export_default,

    // --- types -------------------------------------------------------------
    /// `T[]`. main_token = `[`; lhs = element type.
    array_type,
    /// `[A, B?, ...C[]]` range of element types. main_token = `[`.
    tuple_type,
    /// `T?` inside tuples. main_token = `?`; lhs = type.
    optional_type,
    /// `...T` inside tuples. main_token = `...`; lhs = type.
    rest_type,
    /// `A | B | C` — flattened `range` of members. main_token = first `|`
    /// (or the token starting the type when no leading `|`).
    union_type,
    /// `A & B & C` — flattened `range`. main_token = first `&`.
    intersection_type,
    /// `{ members }` type literal. `range` of members. main_token = `{`.
    object_type,
    /// `name?: T` / `readonly name: T`. main_token = name token;
    /// lhs = optional type, rhs = flags.
    property_signature,
    /// `name?(params): R`. main_token = name token; lhs = extra→FnProto,
    /// rhs = flags.
    method_signature,
    /// `[k: K]: V`. main_token = `[`; lhs = extra→IndexSig, rhs = flags.
    index_signature,
    /// `(params) => R`. main_token = `(` or `<`; lhs = extra→FnProto.
    function_type,
    /// `keyof T`. lhs = operand.
    keyof_type,
    /// `typeof entity` in type position. lhs = entity name node
    /// (identifier / qualified_name / import_expr).
    typeof_type,
    /// `readonly T` (type operator). lhs = operand.
    readonly_type,
    /// `T[K]`. main_token = `[`; lhs = object type, rhs = index type.
    indexed_access_type,
    /// `(T)`. main_token = `(`; lhs = inner type.
    paren_type,
    /// `Foo<A, B>` — only used when type arguments are present (a bare
    /// reference is just an identifier/qualified_name node).
    /// main_token = `<`; lhs = name node, rhs = extra→SubRange of args.
    type_ref,
    /// `A.B`. main_token = `.`; lhs = left node, rhs = name token.
    qualified_name,
};

pub const CondExpr = struct { then_expr: Node, else_expr: Node };
pub const IfElse = struct { then_stmt: Node, else_stmt: Node };
pub const For = struct { init: Node, cond: Node, update: Node }; // all optional
pub const ForInOf = struct { left: Node, right: Node };
pub const Try = struct { catch_clause: Node, finally_block: Node }; // optional
pub const DeclaratorFull = struct { flags: u32, type_ann: Node, init: Node };
pub const Field = struct { flags: u32, type_ann: Node, init: Node };
pub const ParamFull = struct { flags: u32, type_ann: Node, init: Node };
pub const CallInfo = struct {
    targs_start: ExtraIndex,
    targs_end: ExtraIndex,
    args_start: ExtraIndex,
    args_end: ExtraIndex,
};
/// Shared by functions, methods, arrows, function types, method signatures.
pub const FnProto = struct {
    flags: u32,
    /// Name token (0 = anonymous / not applicable).
    name_token: TokenIndex,
    tp_start: ExtraIndex, // type parameter nodes
    tp_end: ExtraIndex,
    params_start: ExtraIndex, // param nodes
    params_end: ExtraIndex,
    /// Optional return type node.
    return_type: Node,
};
/// One JSX element/fragment. `tag` is the tag expression (identifier or
/// member_expr; 0 for a `<>…</>` fragment). `self_closing != 0` marks
/// `<tag/>` (no children). Attributes and children are node ranges in extra.
pub const JsxElementData = struct {
    tag: Node,
    self_closing: u32,
    attrs_start: ExtraIndex,
    attrs_end: ExtraIndex,
    children_start: ExtraIndex,
    children_end: ExtraIndex,
};

pub const ClassData = struct {
    flags: u32,
    name_token: TokenIndex, // 0 = anonymous class expression
    tp_start: ExtraIndex,
    tp_end: ExtraIndex,
    /// Optional heritage node for `extends`.
    extends: Node,
    impl_start: ExtraIndex, // heritage nodes for `implements`
    impl_end: ExtraIndex,
    members_start: ExtraIndex,
    members_end: ExtraIndex,
};
pub const InterfaceData = struct {
    flags: u32,
    name_token: TokenIndex,
    tp_start: ExtraIndex,
    tp_end: ExtraIndex,
    extends_start: ExtraIndex, // heritage nodes
    extends_end: ExtraIndex,
    members_start: ExtraIndex,
    members_end: ExtraIndex,
};
pub const TypeAlias = struct {
    flags: u32,
    name_token: TokenIndex,
    tp_start: ExtraIndex,
    tp_end: ExtraIndex,
};
pub const EnumData = struct {
    flags: u32, // Flags.declare / a const-enum marker bit (Flags.readonly)
    name_token: TokenIndex,
    members_start: ExtraIndex, // enum_member nodes
    members_end: ExtraIndex,
};
pub const NamespaceData = struct {
    flags: u32, // Flags.declare
    name_token: TokenIndex,
    body_start: ExtraIndex, // body statement nodes
    body_end: ExtraIndex,
};
pub const IndexSig = struct { name_token: TokenIndex, key_type: Node, value_type: Node };
pub const ImportData = struct {
    flags: u32,
    default_name_token: TokenIndex, // 0 = none
    ns_name_token: TokenIndex, // `* as ns`; 0 = none
    spec_start: ExtraIndex, // import_specifier nodes
    spec_end: ExtraIndex,
};
pub const ExportNamed = struct { flags: u32, spec_start: ExtraIndex, spec_end: ExtraIndex };
pub const ExportAll = struct { flags: u32, name_token: TokenIndex };

/// The sealed parse result for one file. All slices live in the per-file
/// arena; nothing is freed individually.
pub const Ast = struct {
    /// The token stream the parser consumed (SoA, ends with .eof).
    tokens: scanner.Tokens,
    nodes: std.MultiArrayList(NodeItem).Slice,
    extra_data: []const u32,
    diagnostics: []const Diagnostic,

    pub fn nodeTag(a: *const Ast, node: Node) Tag {
        return a.nodes.items(.tag)[node];
    }
    pub fn nodeMainToken(a: *const Ast, node: Node) TokenIndex {
        return a.nodes.items(.main_token)[node];
    }
    pub fn nodeData(a: *const Ast, node: Node) Data {
        return a.nodes.items(.data)[node];
    }

    /// Read a fixed-shape extra struct at `index` (all fields u32).
    pub fn extraData(a: *const Ast, comptime T: type, index: ExtraIndex) T {
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            comptime std.debug.assert(field.type == u32);
            @field(result, field.name) = a.extra_data[index + i];
        }
        return result;
    }

    /// Node list stored as a SubRange at lhs..rhs.
    pub fn nodeRange(a: *const Ast, node: Node) []const Node {
        const d = a.nodeData(node);
        return a.extra_data[d.lhs..d.rhs];
    }

    pub fn extraRange(a: *const Ast, start: ExtraIndex, end: ExtraIndex) []const Node {
        return a.extra_data[start..end];
    }

    /// Source text of a token.
    pub fn tokenSlice(a: *const Ast, src: []const u8, tok: TokenIndex) []const u8 {
        const start = a.tokens.start(tok);
        const end = scanner.tokenEnd(src, a.tokens.tag(tok), start);
        return src[start..end];
    }

    /// Exact bytes held by the node SoA arrays.
    pub fn nodeBytes(a: *const Ast) usize {
        return a.nodes.len * (@sizeOf(Tag) + @sizeOf(TokenIndex) + @sizeOf(Data));
    }

    /// Exact bytes held by extra_data.
    pub fn extraBytes(a: *const Ast) usize {
        return a.extra_data.len * @sizeOf(u32);
    }

    /// The key M2 metric: (node SoA + extra_data) bytes per node.
    pub fn bytesPerNode(a: *const Ast) f64 {
        if (a.nodes.len == 0) return 0;
        return @as(f64, @floatFromInt(a.nodeBytes() + a.extraBytes())) /
            @as(f64, @floatFromInt(a.nodes.len));
    }

    /// Derive the byte span of `node` by recursing over its children and
    /// token references. O(subtree); meant for diagnostics and tests, not
    /// hot paths (which should use main_token directly).
    pub fn span(a: *const Ast, src: []const u8, node: Node) Span {
        var lo: u32 = std.math.maxInt(u32);
        var hi: u32 = 0;
        spanInner(a, src, node, &lo, &hi);
        if (lo > hi) return .{ .start = 0, .end = 0 };
        return .{ .start = lo, .end = hi };
    }

    fn coverToken(a: *const Ast, src: []const u8, tok: TokenIndex, lo: *u32, hi: *u32) void {
        const s = a.tokens.start(tok);
        const e = scanner.tokenEnd(src, a.tokens.tag(tok), s);
        if (s < lo.*) lo.* = s;
        if (e > hi.*) hi.* = e;
    }

    fn spanInner(a: *const Ast, src: []const u8, node: Node, lo: *u32, hi: *u32) void {
        coverToken(a, src, a.nodeMainToken(node), lo, hi);
        if (a.nodeTag(node) == .unsupported) {
            coverToken(a, src, a.nodeData(node).rhs, lo, hi);
            return;
        }
        var it = childIterator(a, node);
        while (it.next()) |child| spanInner(a, src, child, lo, hi);
        for (extraTokens(a, node).slice()) |tok| coverToken(a, src, tok, lo, hi);
    }

    /// Iterate the node children of `node`, in source order where practical.
    pub fn childIterator(a: *const Ast, node: Node) ChildIterator {
        var it: ChildIterator = .{ .ast = a };
        it.collect(node);
        return it;
    }

    const max_segments = 6;

    /// Iterates children in source order. Children are gathered as ordered
    /// "segments": either a single (possibly-none) node or a contiguous
    /// range of node indices in extra_data. None-nodes (0) are skipped.
    pub const ChildIterator = struct {
        ast: *const Ast,
        /// Single nodes; ranges are marked by `is_range` and index `ranges`.
        ones: [max_segments]Node = undefined,
        ranges: [max_segments][]const Node = undefined,
        is_range: [max_segments]bool = undefined,
        n_seg: u8 = 0,
        seg: u8 = 0,
        range_i: usize = 0,

        pub fn next(it: *ChildIterator) ?Node {
            while (it.seg < it.n_seg) {
                if (it.is_range[it.seg]) {
                    const r = it.ranges[it.seg];
                    while (it.range_i < r.len) {
                        const n = r[it.range_i];
                        it.range_i += 1;
                        if (n != null_node) return n;
                    }
                    it.range_i = 0;
                    it.seg += 1;
                } else {
                    const n = it.ones[it.seg];
                    it.seg += 1;
                    if (n != null_node) return n;
                }
            }
            return null;
        }

        fn push(it: *ChildIterator, n: Node) void {
            it.ones[it.n_seg] = n;
            it.is_range[it.n_seg] = false;
            it.n_seg += 1;
        }

        fn pushRange(it: *ChildIterator, r: []const Node) void {
            it.ranges[it.n_seg] = r;
            it.is_range[it.n_seg] = true;
            it.n_seg += 1;
        }

        fn pushProto(it: *ChildIterator, a: *const Ast, extra: ExtraIndex) void {
            const proto = a.extraData(FnProto, extra);
            it.pushRange(a.extraRange(proto.tp_start, proto.tp_end));
            it.pushRange(a.extraRange(proto.params_start, proto.params_end));
            it.push(proto.return_type);
        }

        fn collect(it: *ChildIterator, node: Node) void {
            const a = it.ast;
            const d = a.nodeData(node);
            switch (a.nodeTag(node)) {
                // Leaves.
                .identifier,
                .number_literal,
                .string_literal,
                .bigint_literal,
                .regex_literal,
                .template_literal,
                .true_literal,
                .false_literal,
                .null_literal,
                .const_type,
                .this_expr,
                .super_expr,
                .import_expr,
                .omitted,
                .error_node,
                .unsupported,
                .empty_stmt,
                .debugger_stmt,
                .break_stmt,
                .continue_stmt,
                .import_specifier,
                .export_specifier,
                .jsx_text,
                => {},

                // lhs only.
                .paren_expr,
                .spread_element,
                .computed_name,
                .prefix_unary,
                .postfix_unary,
                .non_null,
                .rest_element,
                .expr_stmt,
                .throw_stmt,
                .labeled_stmt,
                .declarator,
                .array_type,
                .optional_type,
                .rest_type,
                .keyof_type,
                .typeof_type,
                .readonly_type,
                .paren_type,
                .export_decl,
                .export_default,
                .new_expr_bare,
                .var_decl_one,
                .type_predicate,
                => it.push(d.lhs),

                // optional lhs only.
                .return_stmt, .yield_expr => it.push(d.lhs),

                // lhs + rhs nodes.
                .object_property,
                .object_method,
                .tagged_template,
                .binary,
                .assign,
                .seq_expr,
                .as_expr,
                .satisfies_expr,
                .index_expr,
                .optional_index_expr,
                .binding_default,
                .declarator_init,
                .if_stmt,
                .while_stmt,
                .do_stmt,
                .indexed_access_type,
                => {
                    it.push(d.lhs);
                    it.push(d.rhs);
                },

                .type_alias => {
                    const alias = a.extraData(TypeAlias, d.lhs);
                    it.pushRange(a.extraRange(alias.tp_start, alias.tp_end));
                    it.push(d.rhs);
                },

                // lhs node + optional rhs node.
                .object_shorthand, .binding_property, .type_param, .param, .catch_clause => {
                    it.push(d.lhs);
                    it.push(d.rhs);
                },

                // member access: lhs node, rhs is a token.
                .member_expr, .optional_member_expr, .qualified_name => it.push(d.lhs),

                // ranges.
                .root,
                .array_literal,
                .object_literal,
                .template_expr,
                .array_pattern,
                .object_pattern,
                .block,
                .var_decl,
                .tuple_type,
                .union_type,
                .intersection_type,
                .object_type,
                => it.pushRange(a.extraRange(d.lhs, d.rhs)),

                // lhs node + extra SubRange in rhs.
                .call_expr, .new_expr => {
                    it.push(d.lhs);
                    const r = a.extraData(SubRange, d.rhs);
                    it.pushRange(a.extraRange(r.start, r.end));
                },
                .call_expr_targs, .optional_call, .new_expr_targs => {
                    it.push(d.lhs);
                    const info = a.extraData(CallInfo, d.rhs);
                    it.pushRange(a.extraRange(info.targs_start, info.targs_end));
                    it.pushRange(a.extraRange(info.args_start, info.args_end));
                },
                .type_ref => {
                    it.push(d.lhs);
                    const r = a.extraData(SubRange, d.rhs);
                    it.pushRange(a.extraRange(r.start, r.end));
                },
                .heritage => {
                    it.push(d.lhs);
                    if (d.rhs != 0) {
                        const r = a.extraData(SubRange, d.rhs);
                        it.pushRange(a.extraRange(r.start, r.end));
                    }
                },

                // extra structs.
                .cond_expr => {
                    it.push(d.lhs);
                    const e = a.extraData(CondExpr, d.rhs);
                    it.push(e.then_expr);
                    it.push(e.else_expr);
                },
                .if_else_stmt => {
                    it.push(d.lhs);
                    const e = a.extraData(IfElse, d.rhs);
                    it.push(e.then_stmt);
                    it.push(e.else_stmt);
                },
                .for_stmt => {
                    const e = a.extraData(For, d.lhs);
                    it.push(e.init);
                    it.push(e.cond);
                    it.push(e.update);
                    it.push(d.rhs);
                },
                .for_in_stmt, .for_of_stmt => {
                    const e = a.extraData(ForInOf, d.lhs);
                    it.push(e.left);
                    it.push(e.right);
                    it.push(d.rhs);
                },
                .switch_stmt => {
                    it.push(d.lhs);
                    const r = a.extraData(SubRange, d.rhs);
                    it.pushRange(a.extraRange(r.start, r.end));
                },
                .jsx_element => {
                    const e = a.extraData(JsxElementData, d.lhs);
                    it.push(e.tag);
                    it.pushRange(a.extraRange(e.attrs_start, e.attrs_end));
                    it.pushRange(a.extraRange(e.children_start, e.children_end));
                },
                // jsx_attribute lhs = value node; jsx_spread_attribute /
                // jsx_expr_container lhs = expr node (0 = none). jsx_text is a leaf.
                .jsx_attribute, .jsx_spread_attribute, .jsx_expr_container => it.push(d.lhs),
                .case_clause, .default_clause => {
                    it.push(d.lhs); // 0 for default_clause
                    const r = a.extraData(SubRange, d.rhs);
                    it.pushRange(a.extraRange(r.start, r.end));
                },
                .try_stmt => {
                    it.push(d.lhs);
                    const e = a.extraData(Try, d.rhs);
                    it.push(e.catch_clause);
                    it.push(e.finally_block);
                },
                .declarator_full => {
                    it.push(d.lhs);
                    const e = a.extraData(DeclaratorFull, d.rhs);
                    it.push(e.type_ann);
                    it.push(e.init);
                },
                .class_field => {
                    const e = a.extraData(Field, d.lhs);
                    it.push(e.type_ann);
                    it.push(e.init);
                },
                .param_full => {
                    it.push(d.lhs);
                    const e = a.extraData(ParamFull, d.rhs);
                    it.push(e.type_ann);
                    it.push(e.init);
                },
                .arrow_fn, .function_expr, .function_decl, .class_method => {
                    it.pushProto(a, d.lhs);
                    it.push(d.rhs); // body (optional)
                },
                .function_type, .method_signature => it.pushProto(a, d.lhs),
                .property_signature => it.push(d.lhs),
                .index_signature => {
                    const e = a.extraData(IndexSig, d.lhs);
                    it.push(e.key_type);
                    it.push(e.value_type);
                },
                .class_decl => {
                    const e = a.extraData(ClassData, d.lhs);
                    it.pushRange(a.extraRange(e.tp_start, e.tp_end));
                    it.push(e.extends);
                    it.pushRange(a.extraRange(e.impl_start, e.impl_end));
                    it.pushRange(a.extraRange(e.members_start, e.members_end));
                },
                .interface_decl => {
                    const e = a.extraData(InterfaceData, d.lhs);
                    it.pushRange(a.extraRange(e.tp_start, e.tp_end));
                    it.pushRange(a.extraRange(e.extends_start, e.extends_end));
                    it.pushRange(a.extraRange(e.members_start, e.members_end));
                },
                .enum_decl => {
                    const e = a.extraData(EnumData, d.lhs);
                    it.pushRange(a.extraRange(e.members_start, e.members_end));
                },
                .enum_member => it.push(d.lhs), // optional initializer
                .namespace_decl => {
                    const e = a.extraData(NamespaceData, d.lhs);
                    it.pushRange(a.extraRange(e.body_start, e.body_end));
                },
                .import_decl => {
                    const e = a.extraData(ImportData, d.lhs);
                    it.pushRange(a.extraRange(e.spec_start, e.spec_end));
                },
                .export_named => {
                    const e = a.extraData(ExportNamed, d.lhs);
                    it.pushRange(a.extraRange(e.spec_start, e.spec_end));
                },
                .export_all => {},
            }
        }
    };

    const TokenList = struct {
        buf: [3]TokenIndex = undefined,
        len: u8 = 0,
        fn slice(l: *const TokenList) []const TokenIndex {
            return l.buf[0..l.len];
        }
        fn add(l: *TokenList, tok: TokenIndex) void {
            if (tok == 0) return;
            l.buf[l.len] = tok;
            l.len += 1;
        }
    };

    /// Token references a node stores beyond main_token (names, aliases,
    /// module strings, labels). Used for span derivation.
    fn extraTokens(a: *const Ast, node: Node) TokenList {
        var l: TokenList = .{};
        const d = a.nodeData(node);
        switch (a.nodeTag(node)) {
            .member_expr, .optional_member_expr, .qualified_name => l.add(d.rhs),
            .break_stmt, .continue_stmt => l.add(d.lhs),
            .import_decl => {
                const e = a.extraData(ImportData, d.lhs);
                l.add(e.default_name_token);
                l.add(e.ns_name_token);
                l.add(d.rhs); // module string
            },
            .export_named => l.add(d.rhs),
            .export_all => {
                const e = a.extraData(ExportAll, d.lhs);
                l.add(e.name_token);
                l.add(d.rhs);
            },
            .import_specifier, .export_specifier => l.add(d.lhs),
            .index_signature => l.add(a.extraData(IndexSig, d.lhs).name_token),
            .function_decl, .function_expr, .class_method, .method_signature => {
                l.add(a.extraData(FnProto, d.lhs).name_token);
            },
            .class_decl => l.add(a.extraData(ClassData, d.lhs).name_token),
            .interface_decl => l.add(a.extraData(InterfaceData, d.lhs).name_token),
            .type_alias => l.add(a.extraData(TypeAlias, d.lhs).name_token),
            .enum_decl => l.add(a.extraData(EnumData, d.lhs).name_token),
            .namespace_decl => l.add(a.extraData(NamespaceData, d.lhs).name_token),
            else => {},
        }
        return l;
    }

    // --- S-expression dump (golden tests, --dump-ast) ---------------------

    /// Render `node` as an S-expression: `(tag[ :flags][ text] children...)`.
    /// Leaf literal/identifier nodes render as `(tag text)`; operator nodes
    /// include the operator text; nodes with modifiers include `:flag`s.
    pub fn dump(a: *const Ast, src: []const u8, w: *std.Io.Writer, node: Node) std.Io.Writer.Error!void {
        const tag = a.nodeTag(node);
        const d = a.nodeData(node);
        try w.print("({s}", .{@tagName(tag)});

        // Flags, where the node stores them.
        const flags: u32 = switch (tag) {
            .declarator_full => a.extraData(DeclaratorFull, d.rhs).flags,
            .class_field => a.extraData(Field, d.lhs).flags,
            .param_full => a.extraData(ParamFull, d.rhs).flags,
            .arrow_fn, .function_expr, .function_decl, .class_method, .function_type, .method_signature => a.extraData(FnProto, d.lhs).flags,
            .class_decl => a.extraData(ClassData, d.lhs).flags,
            .enum_decl => a.extraData(EnumData, d.lhs).flags,
            .namespace_decl => a.extraData(NamespaceData, d.lhs).flags,
            .interface_decl => a.extraData(InterfaceData, d.lhs).flags,
            .property_signature, .index_signature, .import_specifier, .export_specifier => d.rhs,
            .import_decl => a.extraData(ImportData, d.lhs).flags,
            .export_named => a.extraData(ExportNamed, d.lhs).flags,
            .export_all => a.extraData(ExportAll, d.lhs).flags,
            else => 0,
        };
        try dumpFlags(w, flags);

        // Identity text: main-token text for leaves/operators, name tokens
        // for declarations, member names, labels.
        switch (tag) {
            .identifier,
            .number_literal,
            .string_literal,
            .bigint_literal,
            .regex_literal,
            .template_literal,
            .binary,
            .assign,
            .prefix_unary,
            .postfix_unary,
            .object_shorthand,
            .binding_property,
            .type_param,
            .labeled_stmt,
            .property_signature,
            .enum_member,
            .class_field,
            .class_method,
            .method_signature,
            .import_specifier,
            .export_specifier,
            .var_decl_one,
            .var_decl,
            => try w.print(" {s}", .{a.tokenSlice(src, a.nodeMainToken(node))}),
            .member_expr, .optional_member_expr, .qualified_name => {},
            .function_decl, .function_expr => {
                const name_tok = a.extraData(FnProto, d.lhs).name_token;
                if (name_tok != 0) try w.print(" {s}", .{a.tokenSlice(src, name_tok)});
            },
            .class_decl => {
                const name_tok = a.extraData(ClassData, d.lhs).name_token;
                if (name_tok != 0) try w.print(" {s}", .{a.tokenSlice(src, name_tok)});
            },
            .interface_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(InterfaceData, d.lhs).name_token)}),
            .type_alias => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(TypeAlias, d.lhs).name_token)}),
            .enum_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(EnumData, d.lhs).name_token)}),
            .namespace_decl => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(NamespaceData, d.lhs).name_token)}),
            .break_stmt, .continue_stmt => {
                if (d.lhs != 0) try w.print(" {s}", .{a.tokenSlice(src, d.lhs)});
            },
            .index_signature => try w.print(" {s}", .{a.tokenSlice(src, a.extraData(IndexSig, d.lhs).name_token)}),
            .import_decl => {
                const e = a.extraData(ImportData, d.lhs);
                if (e.default_name_token != 0) try w.print(" default={s}", .{a.tokenSlice(src, e.default_name_token)});
                if (e.ns_name_token != 0) try w.print(" ns={s}", .{a.tokenSlice(src, e.ns_name_token)});
                if (d.rhs != 0) try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
            },
            .export_named => {
                if (d.rhs != 0) try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
            },
            .export_all => {
                const e = a.extraData(ExportAll, d.lhs);
                if (e.name_token != 0) try w.print(" ns={s}", .{a.tokenSlice(src, e.name_token)});
                try w.print(" from={s}", .{a.tokenSlice(src, d.rhs)});
            },
            .yield_expr => {
                if (d.rhs != 0) try w.writeAll(" *");
            },
            .unsupported => try w.print(" tokens={d}..{d}", .{ a.nodeMainToken(node), d.rhs }),
            else => {},
        }

        // Alias tokens on specifiers.
        switch (tag) {
            .import_specifier, .export_specifier => {
                if (d.lhs != 0) try w.print(" as={s}", .{a.tokenSlice(src, d.lhs)});
            },
            else => {},
        }

        var it = a.childIterator(node);
        while (it.next()) |child| {
            try w.writeAll(" ");
            try a.dump(src, w, child);
        }

        // Member/qualified name text goes after the object child.
        switch (tag) {
            .member_expr, .optional_member_expr, .qualified_name => {
                try w.print(" {s}", .{a.tokenSlice(src, d.rhs)});
            },
            else => {},
        }

        try w.writeAll(")");
    }

    fn dumpFlags(w: *std.Io.Writer, flags: u32) std.Io.Writer.Error!void {
        const names = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = Flags.async, .name = "async" },
            .{ .bit = Flags.generator, .name = "generator" },
            .{ .bit = Flags.declare, .name = "declare" },
            .{ .bit = Flags.static, .name = "static" },
            .{ .bit = Flags.public, .name = "public" },
            .{ .bit = Flags.private, .name = "private" },
            .{ .bit = Flags.protected, .name = "protected" },
            .{ .bit = Flags.readonly, .name = "readonly" },
            .{ .bit = Flags.abstract, .name = "abstract" },
            .{ .bit = Flags.override, .name = "override" },
            .{ .bit = Flags.optional, .name = "optional" },
            .{ .bit = Flags.definite, .name = "definite" },
            .{ .bit = Flags.get, .name = "get" },
            .{ .bit = Flags.set, .name = "set" },
            .{ .bit = Flags.type_only, .name = "type" },
            .{ .bit = Flags.rest, .name = "rest" },
            .{ .bit = Flags.accessor, .name = "accessor" },
        };
        for (names) |n| {
            if (flags & n.bit != 0) try w.print(" :{s}", .{n.name});
        }
    }
};

test "node storage is 13 bytes per node in SoA form" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Tag));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Data));
    // MultiArrayList stores tag/main_token/data in separate arrays, so the
    // per-node cost is exactly 1 + 4 + 8 = 13 bytes plus extra_data.
    var list: std.MultiArrayList(NodeItem) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .tag = .root, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
    const a: Ast = .{
        .tokens = .{ .tags = &.{}, .starts = &.{} },
        .nodes = list.slice(),
        .extra_data = &.{},
        .diagnostics = &.{},
    };
    try std.testing.expectEqual(@as(usize, 13), a.nodeBytes());
}
