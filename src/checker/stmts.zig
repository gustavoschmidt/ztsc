//! Statements & declarations: variable declarations, loops, switches,
//! function bodies, classes, interfaces, aliases. Functions take the
//! `Checker` context as their first parameter.
//!
//! Three concerns the statement walk drives were split out and are
//! re-exported below so `Checker`'s method aliases keep resolving here:
//! `reachability.zig` (endpoint analysis), `iteration.zig` (the `for..of`
//! protocol), and `decorators.zig`.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const implicit_any = @import("implicit_any.zig");
const intern = @import("../intern.zig");
const binder = @import("../frontend/binder.zig");
const literals = @import("../frontend/literals.zig");
const source = @import("../frontend/source.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const prof_zig = checker_zig.prof_zig;
const Error = checker_zig.Error;
const max_instantiation_count = checker_zig.max_instantiation_count;

const TypeParamInfo = @import("typenode.zig").TypeParamInfo;
const accessibility = @import("accessibility.zig");
const baseClassRef = @import("instantiate.zig").baseClassRef;
const computed_key = @import("computed_key.zig");
const conditions = @import("conditions.zig");
const expr_zig = @import("expr.zig");
const checkExprCached = expr_zig.checkExprCached;
const checkCtorParamPropertyPatterns = @import("classes.zig").checkCtorParamPropertyPatterns;
const classStaticType = @import("enums.zig").classStaticType;
const decorators = @import("decorators.zig");
const destructure = @import("destructure.zig");
const diagFmt = Checker.diagFmt;
const elaborate = @import("elaborate.zig");
const heritage = @import("heritage.zig");
const index_constraints = @import("index_constraints.zig");
const init_order = @import("init_order.zig");
const isNonPrimitiveKind = @import("assign.zig").isNonPrimitiveKind;
const isNullishUnion = @import("flow.zig").isNullishUnion;
const modvalue = @import("modvalue.zig");
const iteration = @import("iteration.zig");
const reachability = @import("reachability.zig");
const reserved_names = @import("reserved_names.zig");
const static_block = @import("static_block.zig");
const signatures = @import("signatures.zig");
const statics = @import("statics.zig");
const typeOfSymbol = signatures.typeOfSymbol;
const typespace = @import("typespace.zig");

// =====================================================================
// statements & declarations
// =====================================================================

pub fn checkStatement(c: *Checker, node: Node) Error!void {
    if (node == null_node) return;
    if (c.dprof.on) prof_zig.noteStmtEntry(c);
    // Baseline anchor for any TS2589 raised while materializing types in
    // this statement (refined to finer spans at expression / assignment
    // boundaries), and the source element the instantiation budget is
    // scoped to (`max_instantiation_count` — tsc's `checkSourceElement`
    // resets `instantiationCount` at exactly this point).
    // Profiler: the budget the *previous* source element spent is final at
    // exactly this point, where the next one resets it.
    if (c.prof.on and c.inst_count > 0) {
        const f, const sp = c.instSpanHere();
        prof_zig.noteStatement(c, f, sp.start, c.inst_count);
    }
    c.anchorInst(node);
    // A declaration may not take a predefined TYPE name (TS2414/2427/2431/2457,
    // and TS2397 for a namespace named `undefined`). One call for all five
    // forms; a no-op for every other statement (wave-7 A: `reserved_names.zig`).
    try reserved_names.checkDeclName(c, node);
    c.inst_count = 0;
    c.inst_budget = max_instantiation_count;
    c.newBudgetWindow();
    c.epoch_sym = 0; // this element's own budget (see `Checker.epoch_sym`)
    const d = c.tree.nodeData(node);
    const stmt_tag = c.nodeTag(node);
    // A class-position decorator applies to the class that immediately
    // follows it in the statement list (possibly through an `export`
    // wrapper). Any other statement means a preceding decorator had no
    // class target — drop the pending set so it can't attach to a later
    // class. (`export_default` can also wrap the decorated class.)
    switch (stmt_tag) {
        .decorator, .class_decl, .export_decl, .export_default => {},
        else => c.pending_class_decos.clearRetainingCapacity(),
    }
    switch (stmt_tag) {
        .block => {
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(node)) |s| c.cur_scope = s;
            for (c.tree.nodeRange(node)) |stmt| try c.checkStatement(stmt);
        },
        .var_decl_one, .var_decl => try checkVarDeclStatement(c, node),
        .expr_stmt => {
            // An expression statement throws its value away — announce that
            // downward (`Checker.discarded_expr`, tsc's
            // `expressionResultIsUnused`), since the expression itself has no
            // parent to ask.
            const saved_discarded = c.discarded_expr;
            defer c.discarded_expr = saved_discarded;
            c.discarded_expr = expr_zig.skipParens(c, d.lhs);
            _ = try c.checkExprCached(d.lhs, types.no_type);
        },
        .empty_stmt, .debugger_stmt, .error_node, .unsupported, .omitted => {},
        .if_stmt => {
            const cond_t = try checkIfCondition(c, d.lhs, d.rhs);
            try conditions.checkUncalledFunction(c, d.lhs, cond_t, d.rhs, false);
            try c.checkStatement(d.rhs);
        },
        .if_else_stmt => {
            const e = c.tree.extraData(ast.IfElse, d.rhs);
            const cond_t = try checkIfCondition(c, d.lhs, e.then_stmt);
            try conditions.checkUncalledFunction(c, d.lhs, cond_t, e.then_stmt, false);
            try c.checkStatement(e.then_stmt);
            try c.checkStatement(e.else_stmt);
        },
        // A `while`/`do`/`for` condition is tested for truthiness but NOT for
        // the always-defined mistakes (TS2774/TS2845): tsc routes only `if` and
        // `?:` conditions through `checkTestingKnownTruthyCallableOrAwaitableOr
        // EnumMemberType`, and tsgo reports nothing for `while (isFoo)`.
        .while_stmt => {
            const cond_t = try c.checkExprCached(d.lhs, types.no_type);
            try conditions.checkTruthiness(c, d.lhs, cond_t);
            try c.checkStatement(d.rhs);
        },
        // tsc's `checkWithStatement` checks the object expression and STOPS —
        // it never calls `checkSourceElement(node.statement)`, so nothing
        // inside a `with` block is diagnosed at all. The statement's own
        // TS1101/TS2410 are raised in the parser (grammar-class), so the only
        // work left here is the expression.
        .with_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
        .do_stmt => {
            try c.checkStatement(d.lhs);
            const cond_t = try c.checkExprCached(d.rhs, types.no_type);
            try conditions.checkTruthiness(c, d.rhs, cond_t);
        },
        .for_stmt => {
            const e = c.tree.extraData(ast.For, d.lhs);
            const saved = c.cur_scope;
            defer c.cur_scope = saved;
            if (try c.scopeOf(node)) |s| c.cur_scope = s;
            if (e.init != 0) {
                switch (c.nodeTag(e.init)) {
                    .var_decl_one, .var_decl => try checkVarDeclStatement(c, e.init),
                    else => _ = try c.checkExprCached(e.init, types.no_type),
                }
            }
            if (e.cond != 0) {
                const cond_t = try c.checkExprCached(e.cond, types.no_type);
                try conditions.checkTruthiness(c, e.cond, cond_t);
            }
            if (e.update != 0) _ = try c.checkExprCached(e.update, types.no_type);
            try c.checkStatement(d.rhs);
        },
        .for_in_stmt, .for_of_stmt => try checkForInOf(c, node),
        .switch_stmt => try checkSwitch(c, node),
        .case_clause, .default_clause => {}, // handled by checkSwitch
        .try_stmt => {
            const e = c.tree.extraData(ast.Try, d.rhs);
            try c.checkStatement(d.lhs);
            if (e.catch_clause != 0) {
                const cd = c.tree.nodeData(e.catch_clause);
                const saved = c.cur_scope;
                defer c.cur_scope = saved;
                if (try c.scopeOf(e.catch_clause)) |s| c.cur_scope = s;
                // An unannotated catch parameter destructures `unknown`
                // (useUnknownInCatchVariables, which strict implies), so a
                // pattern there names properties nothing has.
                try c.checkDeclPattern(cd.lhs, types.unknown_type);
                if (cd.rhs != 0) {
                    if (c.nodeTag(cd.rhs) == .block) {
                        for (c.tree.nodeRange(cd.rhs)) |stmt| try c.checkStatement(stmt);
                    } else {
                        try c.checkStatement(cd.rhs);
                    }
                }
            }
            if (e.finally_block != 0) try c.checkStatement(e.finally_block);
        },
        .throw_stmt => _ = try c.checkExprCached(d.lhs, types.no_type),
        .return_stmt => try checkReturn(c, node),
        .break_stmt, .continue_stmt => {},
        .labeled_stmt => try c.checkStatement(d.lhs),
        .function_decl => try checkFunctionDecl(c, node),
        .decorator => try c.pending_class_decos.append(c.cm(), node),
        .class_decl => try c.checkClass(node),
        .interface_decl => try checkInterfaceDecl(c, node),
        .type_alias => try checkTypeAliasDecl(c, node),
        .enum_decl => try c.checkEnum(node),
        .namespace_decl => try checkNamespace(c, node),
        .import_decl => {}, // module graph
        .import_equals => {
            const e = c.tree.extraData(ast.ImportEquals, d.lhs);
            // `import X = require("m")` is the linker's; the ENTITY-NAME form
            // resolves here (tsc's `checkImportEqualsDeclaration`). Without
            // this arm the declaration fell to `checkExprCached`'s recovery
            // walk, which checked the entity name as if it were a value
            // expression.
            if (e.module_token == 0 and e.entity != null_node) {
                const exported = e.flags & ast.Flags.exported != 0 and
                    !c.ambient_ctx and !precededByDeclare(c, node);
                try typespace.checkImportEqualsEntity(c, e.entity, exported);
            }
        },
        .export_named, .export_all => {},
        .export_decl => try c.checkStatement(d.lhs),
        .export_default, .export_assign => {
            switch (c.nodeTag(d.lhs)) {
                // A DECLARATION under `export default` is checked as the
                // declaration it is. Without the type-space arms here,
                // `export default interface A { value: number }` fell to
                // `checkExprCached` and the interface BODY was checked as an
                // expression — `value: number` read `number` as an
                // identifier, for a phantom TS2693.
                .function_decl,
                .class_decl,
                .interface_decl,
                .type_alias,
                .enum_decl,
                .namespace_decl,
                => try c.checkStatement(d.lhs),
                else => try checkExportTarget(c, d.lhs, c.nodeTag(node) == .export_assign),
            }
        },
        else => _ = try c.checkExprCached(node, types.no_type),
    }
}

/// tsc's `checkExportAssignment` for the operand of `export = <expr>` and
/// `export default <expr>`: a BARE IDENTIFIER there is resolved in ALL
/// meanings (`resolveEntityName(id, SymbolFlags.All, /*ignoreErrors*/ true)`)
/// and is only handed to `checkExpressionCached` when the symbol it names
/// actually has a VALUE meaning — or when it names nothing at all, which is
/// how `export default nonexistent` still earns its TS2304.
///
/// So `export = SomeInterface` and `export default SomeTypeAlias` are legal
/// export targets, not value-position uses, and neither is TS2693.
/// Everything that is not a bare identifier is an ordinary expression.
///
/// `is_export_equals` distinguishes `export = X` from `export default X`: only
/// the former lifts the temporal-dead-zone rule off its operand — see
/// `Checker.in_export_equals_target`.
fn checkExportTarget(c: *Checker, expr: Node, is_export_equals: bool) Error!void {
    const bare_ident = c.nodeTag(expr) == .identifier;
    if (bare_ident) {
        const a = try c.atomOfToken(c.tree.nodeMainToken(expr));
        switch (c.resolveSpace(a, c.cur_scope, true)) {
            // Type or namespace meaning only: a legal export target, silent.
            .wrong_space => return,
            // `SymbolFlags.All` includes the namespace meaning, so a namespace
            // that emits no runtime object is a legal export target too — the
            // value-position TS2708 does not apply here. An import binding is
            // RESOLVED (tsc's `resolveEntityName` follows the alias): one whose
            // target is a pure type is a legal export target as well, not the
            // value-position TS2693 (`exportDefaultImportedType`).
            .sym => |sym| {
                const sf = c.symFlags(sym);
                if (try modvalue.valuelessNamespaceRef(c, sym, sf)) return;
                if (try modvalue.aliasValueVerdict(c, sym, sf) == .type_target) return;
            },
            .none => {},
        }
    }
    const saved = c.in_export_equals_target;
    c.in_export_equals_target = is_export_equals and bare_ident;
    defer c.in_export_equals_target = saved;
    _ = try c.checkExprCached(expr, types.no_type);
}

/// tsc's `checkGrammarTopLevelElementsForRequiredDeclareModifier`: inside a
/// `.d.ts`, every top-level DECLARATION (and every variable statement) must
/// start with `declare`, `export` or `default`. Interfaces, type aliases,
/// imports and exports are exempt, and anything that is not a declaration is
/// not this check's business. tsc stops at the FIRST offender, so a file
/// gets at most one TS1046.
pub fn checkDeclFileTopLevel(c: *Checker) Error!void {
    for (c.tree.nodeRange(0)) |stmt| {
        if (stmt == null_node) continue;
        const needs = switch (c.nodeTag(stmt)) {
            // A variable statement never carries the modifier on its own
            // node — the parser consumes `declare` and starts the statement
            // at `var`/`let`/`const` — so read it off the token stream.
            .var_decl_one, .var_decl => !precededByDeclare(c, stmt),
            .class_decl => !declFlagSet(c, ast.ClassData, stmt),
            .function_decl => !declFlagSet(c, ast.FnProto, stmt),
            .enum_decl => !declFlagSet(c, ast.EnumData, stmt),
            .namespace_decl => blk: {
                const data = c.tree.extraData(ast.NamespaceData, c.tree.nodeData(stmt).lhs);
                // A QUOTED-name module is only ever ambient, so the parser
                // stamps `declare` on it whether or not the source wrote the
                // modifier — the flag cannot answer for `module "Foo" {}` and
                // the token stream has to. (`global { }` keeps the flag,
                // since a global augmentation carries no name to modify.)
                if (data.flags & ast.Flags.ambient_module != 0) break :blk !precededByDeclare(c, stmt);
                break :blk data.flags & ast.Flags.declare == 0;
            },
            else => false,
        };
        if (!needs) continue;
        try c.diagFmt(1046, c.tokSpan(c.tree.nodeMainToken(stmt)), "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier.", .{});
        return;
    }
}

fn declFlagSet(c: *Checker, comptime T: type, node: Node) bool {
    const data = c.tree.extraData(T, c.tree.nodeData(node).lhs);
    return data.flags & ast.Flags.declare != 0;
}

/// Is the token immediately before `node`'s main token a `declare` keyword?
/// The parser folds `declare` into a flag for every declaration form except
/// variable statements, where it simply bumps past it.
fn precededByDeclare(c: *Checker, node: Node) bool {
    const mt = c.tree.nodeMainToken(node);
    return mt > 0 and c.tree.tokens.tag(mt - 1) == .keyword_declare;
}

/// An `if` condition, checked with `body` published as the branch its logical
/// operands may be excused by (`conditions.CondWalk.body`). The publication has
/// to happen BEFORE the condition is walked, because it is `checkBinary`'s `&&`
/// arm — not this statement — that judges a left operand.
fn checkIfCondition(c: *Checker, cond: Node, body: Node) Error!types.TypeId {
    const saved = conditions.enterCondition(c, cond, body);
    defer conditions.leaveCondition(c, saved);
    const cond_t = try c.checkExprCached(cond, types.no_type);
    try conditions.checkTruthiness(c, cond, cond_t);
    return cond_t;
}

fn checkVarDeclStatement(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const is_const = c.tree.tokens.tag(c.tree.nodeMainToken(node)) == .keyword_const;
    const ambient = c.ambient_ctx or precededByDeclare(c, node);
    const let_or_const = isLetOrConst(c, node);
    const const_like: ?[]const u8 = if (ambient) null else constLikeKeyword(c, node);
    if (c.nodeTag(node) == .var_decl_one) {
        if (ambient) try checkAmbientInitializer(c, d.lhs, is_const);
        if (const_like) |kw| try checkConstInitialized(c, d.lhs, kw);
        if (let_or_const) try checkLetName(c, c.tree.nodeData(d.lhs).lhs);
        try checkDeclarator(c, d.lhs, is_const, ambient);
    } else {
        for (c.tree.nodeRange(node)) |decl| {
            if (decl == null_node) continue;
            if (ambient) try checkAmbientInitializer(c, decl, is_const);
            if (const_like) |kw| try checkConstInitialized(c, decl, kw);
            if (let_or_const) try checkLetName(c, c.tree.nodeData(decl).lhs);
            try checkDeclarator(c, decl, is_const, ambient);
        }
    }
}

fn isLetOrConst(c: *Checker, var_decl: Node) bool {
    return switch (c.tree.tokens.tag(c.tree.nodeMainToken(var_decl))) {
        .keyword_const, .keyword_let => true,
        else => false,
    };
}

/// tsc's `checkGrammarNameInLetOrConstDeclarations`: a `let`/`const` may not
/// BIND the name `let`. Only the identifier form is answered — tsc recurses
/// into binding patterns, and no corpus case needs that, so a pattern stays
/// silent rather than guessing at an element's name node.
fn checkLetName(c: *Checker, name: Node) Error!void {
    if (name == null_node or c.nodeTag(name) != .identifier) return;
    const tok = c.tree.nodeMainToken(name);
    if (!std.mem.eql(u8, c.tokenText(tok), "let")) return;
    try c.diagFmt(2480, c.tokSpan(tok), "'let' is not allowed to be used as a name in 'let' or 'const' declarations.", .{});
}

/// tsc's `checkGrammarVariableDeclaration` arm for an uninitialized
/// `const`-LIKE declaration. Reported on the NAME, and only for a STATEMENT's
/// declaration list — a `for…in`/`for…of` head is exempt (tsc's own guard) and
/// never reaches here, because those heads are checked by
/// `checkForInOfStatement`, while a C-style `for (const x;;)` does reach here
/// and is reported, as tsc has it.
///
/// `keyword` is what tsc's `isVarConstLike` matched, and the message is
/// parameterized on it: `const`, `using`, or `await using`.
///
/// A binding PATTERN with no initializer is TS1182 in tsc ("a destructuring
/// declaration must have an initializer"), which `return`s before this arm;
/// ztsc does not answer TS1182 yet, so a pattern stays silent rather than
/// borrowing the wrong code.
fn checkConstInitialized(c: *Checker, decl: Node, keyword: []const u8) Error!void {
    const d = c.tree.nodeData(decl);
    const name: Node = switch (c.nodeTag(decl)) {
        .declarator => d.lhs,
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            if (e.init != 0) return;
            break :blk d.lhs;
        },
        // `.declarator_init` always has one; anything else is recovery.
        else => return,
    };
    if (c.nodeTag(name) != .identifier) return;
    try c.diagFmt(1155, c.tokSpan(c.tree.nodeMainToken(name)), "'{s}' declarations must be initialized.", .{keyword});
}

/// The `const`-LIKE keyword a declaration list is introduced by — tsc's
/// `isVarConstLike`, which is `const` plus the two explicit-resource forms
/// (TS 5.2). Null for `var`/`let`.
///
/// The parser puts the list's `main_token` on `using` for BOTH resource forms
/// and leaves `await` as the token in front, which is the same shape
/// `Binder.declKindOfVar` reads.
fn constLikeKeyword(c: *Checker, node: Node) ?[]const u8 {
    const mt = c.tree.nodeMainToken(node);
    return switch (c.tree.tokens.tag(mt)) {
        .keyword_const => "const",
        .keyword_using => if (mt > 0 and c.tree.tokens.tag(mt - 1) == .keyword_await)
            "await using"
        else
            "using",
        else => null,
    };
}

/// tsc's `checkAmbientInitializer` for a variable declarator: an initializer
/// is not allowed in an ambient context (TS1039) unless the declaration is a
/// `const` WITHOUT a type annotation — the one form that carries a literal
/// value into the declaration file. (tsc additionally requires that
/// exempted initializer to be a literal, TS1254; ztsc stays silent there, a
/// deliberate under-report rather than a guess at "literal enum reference".)
fn checkAmbientInitializer(c: *Checker, decl: Node, is_const: bool) Error!void {
    const d = c.tree.nodeData(decl);
    const init: Node, const has_ann: bool = switch (c.nodeTag(decl)) {
        .declarator_init => .{ d.rhs, false },
        .declarator_full => blk: {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            break :blk .{ e.init, e.type_ann != 0 };
        },
        else => return,
    };
    if (init == null_node) return;
    if (is_const and !has_ann) return;
    try c.diagFmt(1039, c.nodeSpan(init), "Initializers are not allowed in ambient contexts.", .{});
}

fn checkDeclarator(c: *Checker, decl: Node, is_const: bool, ambient: bool) Error!void {
    // TS2403 — every declaration of a name after the first must have an
    // identical type. Runs before the initializer checks so the type demand
    // is the same one `typeOfSymbol` would make on its own.
    try c.checkSubsequentVarDecl(decl, is_const);
    const d = c.tree.nodeData(decl);
    switch (c.nodeTag(decl)) {
        // `var [a], {b};` — no annotation and no initializer, so the pattern
        // is the only source of type information and every leaf it binds is
        // an implicit `any` (TS7031). Only a VAR STATEMENT reaches here; a
        // `for…of`/`for…in` head takes its declarator's type from the
        // iterable and is checked elsewhere.
        .declarator => {
            try implicit_any.reportPatternImplicitAny(c, d.lhs);
            try implicit_any.reportVarImplicitAny(c, d.lhs, ambient);
        },
        .declarator_init => {
            const it = try c.checkExprCached(d.rhs, try destructure.patternContextualType(c, d.lhs));
            // Materialize the symbol's type (infers + caches). The
            // initializer's type is what the pattern destructures, so it is
            // also what contextually types the pattern's defaults.
            try materializePatternTypes(c, d.lhs, it, .contextual_only);
        },
        .declarator_full => {
            const e = c.tree.extraData(ast.DeclaratorFull, d.rhs);
            const name_span = if (c.nodeTag(d.lhs) == .identifier)
                c.tokSpan(c.tree.nodeMainToken(d.lhs))
            else
                c.nodeSpan(d.lhs);
            const ann: TypeId = if (e.type_ann != 0) try c.annTypeMaybeUnique(e.type_ann, is_const, 1332, name_span) else types.no_type;
            // What the initializer is CHECKED against. The annotation when
            // there is one; otherwise an array binding pattern's implied tuple
            // (`patternContextualType`), which is a contextual type only — the
            // assignability check below stays on `ann`.
            const init_ctx: TypeId = if (ann != types.no_type) ann else try destructure.patternContextualType(c, d.lhs);
            // A `unique symbol` const accepts only a fresh `Symbol()` /
            // `Symbol.for()` initializer; the assignability check (a plain
            // `symbol` is not assignable to `unique symbol`) is skipped for
            // that one form, matching tsc.
            if (e.init != 0 and e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and c.isFreshSymbolCall(e.init)) {
                _ = try c.checkExprCached(e.init, ann);
                try materializePatternTypes(c, d.lhs, ann, .relate);
                return;
            }
            // What the pattern destructures, for the defaults inside it: the
            // annotation, else the initializer's own type.
            var whole: TypeId = ann;
            if (e.init != 0) {
                const it0 = try c.checkExprCached(e.init, init_ctx);
                if (whole == types.no_type) whole = it0;
                // tsc binds `f.x = 1` onto the FUNCTION EXPRESSION's symbol,
                // so the initializer of `const f: T = () => {}` already
                // carries the expando members when it is checked against `T`
                // — which is the whole point of
                // `expandoFunctionExpressionsWithDynamicNames2`, where the
                // annotation demands a member only the assignments supply.
                // The variable itself keeps `T` (see `varHasTypeAnnotation`).
                const it = if (ann == types.no_type)
                    it0 // no annotation: the VARIABLE's own type folds them in
                else
                    try expandoInitializerType(c, d.lhs, e.init, it0);
                if (ann != types.no_type and ann != types.error_type) {
                    // An INLINE deferred conditional annotation does not get
                    // the both-branches leniency here (see
                    // `inlineCondAnnRejects`): tsc treats a distributive
                    // conditional written inside the generic function's body
                    // as distribution dependent and rejects the write.
                    if (try c.checkAssignable(it, ann, e.init, name_span) and
                        try c.inlineCondAnnRejects(e.type_ann, it, ann))
                    {
                        try c.reportNotAssignable(2322, it, ann, name_span);
                    }
                }
            }
            try materializePatternTypes(c, d.lhs, whole, if (ann != types.no_type) .relate else .contextual_only);
        },
        else => {},
    }
    // What the pattern demands of the type it destructures (TS2339/TS2488 per
    // element, TS2353 for an initializer property the pattern does not name).
    // After the arms above so the initializer is typed under its own
    // contextual type first — `checkDeclPattern` reads the cache.
    try c.checkDeclPattern(decl, types.no_type);
}

/// `it`, the type of a variable's function-expression initializer, with the
/// expando members `name`'s symbol collected folded in. A pass-through for
/// everything else — a non-identifier binding, a non-callable initializer,
/// or a symbol with no `f.x = …` assignments at all.
fn expandoInitializerType(c: *Checker, name: Node, init: Node, it: TypeId) Error!TypeId {
    switch (c.nodeTag(init)) {
        .arrow_fn, .function_expr => {},
        else => return it,
    }
    if (c.nodeTag(name) != .identifier) return it;
    const a = try c.atomOfToken(c.tree.nodeMainToken(name));
    const sym = switch (c.resolveSpace(a, c.cur_scope, true)) {
        .sym => |s| s,
        else => return it,
    };
    return signatures.withExpandoProps(c, sym, it);
}

/// Force typeOfSymbol for every name bound by a pattern so inference
/// diagnostics fire deterministically at the declaration site.
///
/// `whole` is the type the pattern destructures — the declaration's
/// annotation when it has one and its initializer's type otherwise, i.e. the
/// `parentType` of tsc's `getContextualTypeForBindingElement` — threaded down
/// so a pattern element's DEFAULT is checked against the type of the property
/// it stands in for, rather than with no contextual type at all. Without it
/// `let { stringIdentity: id = arg => arg }: StringIdentity = …` walked the
/// arrow with nothing to type `arg` from and reported it an implicit `any`
/// (`contextuallyTypedBindingInitializer`). `no_type` — from a `for` head,
/// whose binding is typed by what is iterated — simply propagates.
fn materializePatternTypes(c: *Checker, pat: Node, whole: TypeId, mode: destructure.DefaultCheck) Error!void {
    if (pat == null_node) return;
    switch (c.nodeTag(pat)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
            switch (c.resolveSpace(a, c.cur_scope, true)) {
                .sym => |sym| _ = try c.typeOfSymbol(sym),
                else => {},
            }
        },
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el != null_node) try materializePatternTypes(c, el, whole, mode);
            }
        },
        .array_pattern => {
            const r = if (whole == types.no_type) types.no_type else try c.resolveStructural(whole);
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                if (c.nodeTag(el) == .omitted) continue;
                const et: TypeId = if (r == types.no_type)
                    types.no_type
                else
                    (try destructure.patternElemType(c, r, i)) orelse types.no_type;
                try materializePatternTypes(c, el, et, mode);
            }
        },
        .binding_property => {
            const d = c.tree.nodeData(pat);
            const key = try c.memberAtom(c.tree.nodeMainToken(pat));
            const pt = (try destructure.patternPropType(c, whole, key)) orelse types.no_type;
            if (d.lhs != 0) {
                try materializePatternTypes(c, d.lhs, pt, mode);
            } else {
                switch (c.resolveSpace(key, c.cur_scope, true)) {
                    .sym => |sym| _ = try c.typeOfSymbol(sym),
                    else => {},
                }
            }
            if (d.rhs != 0) try destructure.checkPatternDefault(c, pat, pt, mode);
        },
        .binding_property_computed => {
            const d = c.tree.nodeData(pat);
            // tsc's `getContextualTypeForBindingElement` drops out on
            // `isComputedNonLiteralName` — a computed key whose expression is
            // NOT a string/numeric literal. One that IS still names a
            // property, so `{ ["show"]: r = v => v }` is contextually typed
            // exactly as `{ show: r = v => v }` is; without the lookup the
            // arrow's `v` was an implicit `any`
            // (`contextuallyTypedBindingInitializer`).
            var pt = types.no_type;
            if (d.lhs != 0) {
                const kt = try c.checkExprCached(d.lhs, types.no_type);
                if (try c.literalKeyAtom(kt)) |key| {
                    pt = (try destructure.patternPropType(c, whole, key)) orelse types.no_type;
                }
            }
            if (d.rhs != 0) try materializePatternTypes(c, d.rhs, pt, mode);
        },
        .binding_default => {
            const d = c.tree.nodeData(pat);
            try materializePatternTypes(c, d.lhs, whole, mode);
            try destructure.checkPatternDefault(c, pat, whole, mode);
        },
        .rest_element => try materializePatternTypes(c, c.tree.nodeData(pat).lhs, types.no_type, mode),
        else => {},
    }
}

/// Is `head` a variable-declaration list with NO declarations? That is what
/// `for (var of X)` parses to once the lookahead takes `of` as the keyword
/// rather than as the declared name (tsc's `canFollowContextualOfKeyword`).
fn headDeclarationsEmpty(c: *const Checker, head: Node) bool {
    return switch (c.nodeTag(head)) {
        .var_decl_one => c.tree.nodeData(head).lhs == null_node,
        .var_decl => c.tree.nodeRange(head).len == 0,
        else => false,
    };
}

fn checkForInOf(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const e = c.tree.extraData(ast.ForInOf, d.lhs);
    const is_of = c.nodeTag(node) == .for_of_stmt;
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    // `for (var of X)`: the parser takes `of` as the keyword and leaves the
    // declaration list EMPTY (TS1123). tsc's `checkForOfStatement` reaches
    // the right-hand side only through `checkForInOrForOfVariableDeclaration`
    // — which guards on `declarations.length >= 1` — so `X` is never checked
    // at all, and a `for…of` over an undeclared name reports nothing but the
    // empty-list grammar error. (`for…in` reads its right-hand side
    // unconditionally, so this is a `for…of`-only early-out.)
    if (is_of and headDeclarationsEmpty(c, e.left)) return c.checkStatement(d.rhs);

    const rt = try c.checkExprCached(e.right, types.no_type);
    var elem_t: TypeId = types.any_type;
    if (is_of) {
        elem_t = try c.forOfElementType(rt, e.right, e.is_await != 0);
    } else {
        elem_t = types.string_type; // for..in keys
        // `for (const k in maybeUndefined)` is legal JS — enumerating
        // `null`/`undefined` produces no keys — so tsc's
        // `checkForInStatement` runs the right-hand side through
        // `getNonNullableTypeIfNeeded` before testing its kind, and prints
        // the STRIPPED type in the diagnostic. (The body's own view of the
        // subject is `forInSubjectNarrows`, the flow half of the same rule.)
        const rt_nn = if (isNullishUnion(c, rt)) try c.nonNullable(rt) else rt;
        const rk = c.ts.kind(try c.resolveStructural(rt_nn));
        if (!isNonPrimitiveKind(rk) and rk != .any and rk != .err and rk != .unknown and rk != .type_param) {
            try c.diagFmt(2407, c.nodeSpan(e.right), "The right-hand side of a 'for...in' statement must be of type 'any', an object type or a type parameter, but here has type '{s}'.", .{try c.typeToString(rt_nn)});
        }
    }
    // Bind the left side.
    switch (c.nodeTag(e.left)) {
        .var_decl_one, .var_decl => {
            const ld = c.tree.nodeData(e.left);
            const decl = if (c.nodeTag(e.left) == .var_decl_one) ld.lhs else blk: {
                const range = c.tree.nodeRange(e.left);
                break :blk if (range.len > 0) range[0] else null_node;
            };
            // `for (let let of …)` — the ForDeclaration arm of tsc's
            // `checkGrammarNameInLetOrConstDeclarations`, which a `for` head
            // reaches even though it skips the rest of the declaration checks.
            if (decl != null_node and isLetOrConst(c, e.left)) {
                try checkLetName(c, c.tree.nodeData(decl).lhs);
            }
            if (decl != null_node) {
                const dd = c.tree.nodeData(decl);
                switch (c.nodeTag(decl)) {
                    .declarator => {
                        if (c.nodeTag(dd.lhs) == .identifier) {
                            const a = try c.atomOfToken(c.tree.nodeMainToken(dd.lhs));
                            if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
                                c.setTypeOfSymbol(c.toGlobal(sym), elem_t);
                            }
                        } else {
                            try assignPatternFromType(c, dd.lhs, elem_t);
                        }
                    },
                    .declarator_full => {
                        const ee = c.tree.extraData(ast.DeclaratorFull, dd.rhs);
                        // A `for` head's binding has no contextual type of its
                        // own unless it is ANNOTATED: tsc's
                        // `getContextualTypeForVariableLikeDeclaration` reads
                        // the annotation, then the declaration's INITIALIZER —
                        // and a loop head has none, so what is iterated never
                        // becomes one. `for (const { show: fs = v => v… } of
                        // rows)` really is an implicit-any `v` (TS7006).
                        // The annotation itself is never RELATED to what is
                        // iterated: a `for` head's one declaration may not
                        // carry a type annotation at all, so the annotation is
                        // already TS2404/TS2483 (`checkGrammarForInOrForOfStatement`,
                        // raised in the parser) and tsc reports nothing else
                        // about it. It still TYPES the binding, so the pattern
                        // walk below keeps reading it.
                        var whole: TypeId = types.no_type;
                        if (ee.type_ann != 0) whole = try c.typeFromTypeNode(ee.type_ann);
                        try materializePatternTypes(c, dd.lhs, whole, if (ee.type_ann != 0) .relate else .contextual_only);
                    },
                    else => {},
                }
            }
        },
        // A destructuring pattern head is a destructuring ASSIGNMENT whose
        // source is the iterated type: tsc's `checkForOfStatement` hands
        // `varExpr` straight to `checkDestructuringAssignment(varExpr,
        // iteratedType || errorType)`, so every position is resolved through
        // the element type instead of being typed as the expression it
        // syntactically is. `for ({ x, y = E.x } of array)` gets its
        // per-property TS2322 from that walk and nowhere else.
        // `for..in` has no source to hand down (the head is TS2491 there),
        // so it keeps the plain expression check.
        .array_literal, .object_literal, .array_pattern, .object_pattern => {
            if (is_of) {
                try expr_zig.checkDestructuringPattern(c, e.left, elem_t);
            } else {
                _ = try c.checkExprCached(e.left, types.no_type);
            }
        },
        else => {
            const expr_t = try c.checkExprCached(e.left, types.no_type);
            // The head WRITES its target on every iteration, so the same
            // refusals an assignment applies (TS2588/2628-32/2540/2542) apply
            // — and the type it writes INTO is the target's declared one, not
            // the flow-narrowed one a read would see (`writeTargetType`).
            const write_t = try expr_zig.writeTargetType(c, e.left);
            const left_t = if (write_t == types.no_type) expr_t else write_t;
            if (is_of) {
                _ = try expr_zig.checkReferenceExpression(c, e.left, .for_of);
                // …and what it writes is the ITERATED type, so tsc's
                // `checkForOfStatement` relates the two exactly as an
                // assignment relates its right operand to its target — the
                // one check a non-declaration head has, since there is no
                // declaration for `checkVariableLikeDeclaration` to run on.
                // `any` on either side is tsc's "iteratedType is undefined"
                // (the right-hand side was not iterable, already TS2488) and
                // its `isTypeAny` short-circuit; neither may cascade. An
                // EVOLVING target has no declared type to check against at
                // all — its `undefined` is where the flow starts, not a
                // constraint (tsc's `convertAutoToAny`).
                if (elem_t != types.any_type and elem_t != types.error_type and
                    left_t != types.any_type and left_t != types.error_type and
                    !expr_zig.assignTargetIsEvolving(c, e.left))
                {
                    _ = try c.checkAssignable(elem_t, left_t, e.left, c.nodeSpan(e.left));
                }
            } else if (try c.isAssignable(types.string_type, left_t)) {
                // tsc reaches the reference check for `for…in` only after the
                // key type fits the target ("run check only if the former
                // check succeeded to avoid cascading errors"). The key type is
                // `getIndexTypeOrString(rightType)`, approximated by `string`,
                // which is exactly what a `for…in` binding may hold.
                _ = try expr_zig.checkReferenceExpression(c, e.left, .for_in);
            }
        },
    }
    try c.checkStatement(d.rhs);
}

/// Pre-set the types of identifiers bound in a destructuring pattern
/// from the element type (for-of patterns).
fn assignPatternFromType(c: *Checker, pat: Node, whole: TypeId) Error!void {
    if (pat == null_node) return;
    switch (c.nodeTag(pat)) {
        .identifier => {
            const a = try c.atomOfToken(c.tree.nodeMainToken(pat));
            if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), whole);
        },
        .object_pattern => {
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                const ed = c.tree.nodeData(el);
                if (c.nodeTag(el) == .binding_property) {
                    const key = try c.memberAtom(c.tree.nodeMainToken(el));
                    var pt: TypeId = types.any_type;
                    if (try c.propOfType(try c.resolveStructural(whole), key)) |p| pt = p.ty;
                    if (ed.lhs != 0) {
                        try assignPatternFromType(c, ed.lhs, pt);
                    } else {
                        const a = try c.memberAtom(c.tree.nodeMainToken(el));
                        if (c.bind.lookupInScope(c.cur_scope, a)) |sym| c.setTypeOfSymbol(c.toGlobal(sym), pt);
                    }
                } else if (c.nodeTag(el) == .binding_property_computed) {
                    // `{[k]: target}` → `target: whole[typeof k]`.
                    var pt: TypeId = types.any_type;
                    if (ed.lhs != 0) {
                        const kt = try c.checkExprCached(ed.lhs, types.no_type);
                        pt = try c.indexedAccessType(try c.resolveStructural(whole), kt);
                    }
                    if (ed.rhs != 0) try assignPatternFromType(c, ed.rhs, pt);
                }
            }
        },
        .array_pattern => {
            const r = try c.resolveStructural(whole);
            var i: u32 = 0;
            for (c.tree.nodeRange(pat)) |el| {
                if (el == null_node) continue;
                defer i += 1;
                var et: TypeId = types.any_type;
                switch (c.ts.kind(r)) {
                    .array => et = c.ts.arrayElem(r),
                    .tuple => {
                        if (i < c.ts.tupleLen(r)) et = c.ts.tupleElem(r, i).ty;
                    },
                    else => {},
                }
                try assignPatternFromType(c, el, et);
            }
        },
        .binding_default => try assignPatternFromType(c, c.tree.nodeData(pat).lhs, whole),
        .rest_element => try assignPatternFromType(c, c.tree.nodeData(pat).lhs, try c.ts.makeArray(whole)),
        else => {},
    }
}

// The iteration protocol lives in `iteration.zig`, next to the `await`/yield
// half it shares a walk with; re-exported here because the `for..of` walk
// above drives it and `Checker`'s method aliases name this file.
pub const asyncIterationElementType = iteration.asyncIterationElementType;
pub const callableReturn = iteration.callableReturn;
pub const forOfElementType = iteration.forOfElementType;
pub const iterationElementType = iteration.iterationElementType;
pub const contextualIterationElementType = iteration.contextualIterationElementType;
pub const iteratorNextValue = iteration.iteratorNextValue;

fn checkSwitch(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const disc_t = try c.checkExprCached(d.lhs, types.no_type);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    if (try c.scopeOf(node)) |s| c.cur_scope = s;
    const r = c.tree.extraData(ast.SubRange, d.rhs);
    for (c.tree.extraRange(r.start, r.end)) |clause| {
        if (clause == null_node) continue;
        const cd = c.tree.nodeData(clause);
        if (c.nodeTag(clause) == .case_clause and cd.lhs != 0) {
            const case_t = try c.checkExprCached(cd.lhs, types.no_type);
            // tsc's probe is DIRECTIONAL, and its failure arm REPORTS:
            //
            // ```ts
            // if (!isTypeEqualityComparableTo(comparedExpressionType, caseType)) {
            //     checkTypeComparableTo(caseType, comparedExpressionType, clause.expression);
            // }
            // ```
            //
            // The second call carries the clause expression as its error
            // node, so a fresh object literal written as a case is subject
            // to the excess-property check — and `switch (new C()) { case
            // { id: 12, name: '' }: }` is TS2353 on `name`, not silence
            // (`switchStatements`). The two questions line up: a literal
            // carrying a name the discriminant lacks is exactly a
            // discriminant that is not comparable TO the literal, which is
            // what makes the directional probe fail.
            //
            // Ordered before the whole-type report for the same reason
            // `checkAssignable` orders it before TS2322: the excess check
            // runs at the top of `isRelatedTo` and a reported TS2353 is the
            // only diagnostic the pair earns.
            if (!try c.excessPropertyFailure(cd.lhs, case_t, disc_t)) {
                // TS2678 is the same *comparable* relation as TS2367, so it
                // goes through the same union/intersection-distributing test:
                // a `case null:` on a non-nullable discriminant is clean in
                // tsc, and `case 1:` on a branded `number & { _brand }` relates
                // through the intersection's `number` constituent. Bare
                // `isComparable` (mutual assignability) reported both.
                if (!try c.typesHaveOverlap(case_t, disc_t)) {
                    try c.diagFmt(2678, c.nodeSpan(cd.lhs), "Type '{s}' is not comparable to type '{s}'.", .{
                        try c.typeToString(case_t), try c.typeToString(disc_t),
                    });
                }
            }
        }
        const cr = c.tree.extraData(ast.SubRange, cd.rhs);
        for (c.tree.extraRange(cr.start, cr.end)) |stmt| try c.checkStatement(stmt);
    }
}

fn checkReturn(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const ctx = c.fn_ctx orelse {
        if (d.lhs != 0) _ = try c.checkExprCached(d.lhs, types.no_type);
        return;
    };
    if (d.lhs != 0) {
        // Contextual type of the return expression. For async, tsc's
        // `getContextualTypeForReturnExpression` yields `T | Promise<T>`
        // (awaited payload OR a promise of it), so a returned generic
        // call/`new` whose own return is `Promise<R>` infers `R` from the
        // promise arm (`return new Promise(()=>{})` → `Promise<T>`;
        // `return axios.delete(...)` → `Promise<R=T>`). The assignability
        // check below still relates the *awaited* value to `ctx.ret_ann`.
        // With no annotation, the contextual signature's return type takes
        // that role (`c.ret_ctx`) — it is what tsc's
        // `getContextualTypeForReturnExpression` yields for a contextually
        // typed function, and without it a `return { handler: (e) => … }`
        // inside such a function lost every nested contextual type.
        const base_ctx = if (ctx.ret_ann != types.no_type) ctx.ret_ann else ctx.ret_ctx;
        const expr_ctx = if (ctx.is_async and base_ctx != types.no_type and
            base_ctx != types.error_type and c.ts.kind(base_ctx) != .none)
            try c.makeUnion2(base_ctx, try c.makePromise(base_ctx))
        else
            base_ctx;
        const rt = try c.checkExprCached(d.lhs, expr_ctx);
        // async: `return v` in a `Promise<T>` relates the awaited `v` to the
        // payload `T` (so `return somePromise` is not double-wrapped).
        const eff_rt = if (ctx.is_async) try c.awaitedType(rt) else rt;
        if (ctx.ret_ann != types.no_type and ctx.ret_ann != types.error_type and
            ctx.ret_ann != types.any_type and c.ts.kind(ctx.ret_ann) != .none)
        {
            // Anchored at the RETURN STATEMENT, not the expression: tsc's
            // `checkReturnStatement` passes the statement as the error
            // node, so the column is `return`'s, seven characters to the
            // left of the expression's. (The expression node still goes in
            // as `expr_node`, so the literal elaboration below still
            // descends into it.) The bare-`return` arm below already
            // anchored this way.
            _ = try c.checkAssignable(eff_rt, ctx.ret_ann, d.lhs, c.nodeSpan(node));
        }
    } else if (ctx.ret_ann != types.no_type) {
        const k = c.ts.kind(ctx.ret_ann);
        const allows_bare = k == .void or k == .any or k == .unknown or k == .err or k == .none or
            c.containsUndefinedish(ctx.ret_ann);
        if (!allows_bare) {
            try c.diagFmt(2322, c.nodeSpan(node), "Type 'undefined' is not assignable to type '{s}'.", .{try c.typeToString(ctx.ret_ann)});
        }
    }
}

fn checkFunctionDecl(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    // Builds the signature (reports 7006 etc. once).
    _ = try c.signatureOfProto(node, d.lhs, false, true);
    if (d.rhs != 0) {
        try checkOverloadSet(c, node);
        const sig = try c.signatureOfProto(node, d.lhs, false, true);
        try c.checkFunctionBody(node, d.lhs, d.rhs, sig, types.no_type);
    }
}

/// TS2394 for the overload set `node` implements — see
/// `signatures.checkOverloadImplementation`. Driven from the IMPLEMENTATION so
/// it runs once per function symbol, in source order, whichever declaration a
/// type demand happened to reach first.
fn checkOverloadSet(c: *Checker, node: Node) Error!void {
    const name_tok = c.tree.extraData(ast.FnProto, c.tree.nodeData(node).lhs).name_token;
    if (name_tok == 0) return;
    const a = try c.atomOfToken(name_tok);
    const local = c.bind.lookupInScope(c.cur_scope, a) orelse return;
    const sym = c.toGlobal(local);
    // A merged symbol's parts come from other files, which declare their own
    // overload sets; only this file's declarations are this check's business.
    if (c.prog.isMergedId(sym)) return;
    var overloads: std.ArrayList(Node) = .empty;
    defer overloads.deinit(c.scratch());
    for (c.declsOf(sym)) |decl| {
        if (c.nodeTag(decl) != .function_decl) continue;
        // A second implementation is TS2393's business, not this one's.
        if (decl != node and c.tree.nodeData(decl).rhs != 0) return;
        if (decl != node) try overloads.append(c.scratch(), decl);
    }
    try signatures.checkOverloadImplementation(c, overloads.items, node);
}

/// TS2394 for the constructor overload set `impl` implements — the class-member
/// half of `checkOverloadSet`. The bodiless `constructor(…);` declarations are
/// the sibling class members, in source order; a second one WITH a body is
/// TS2392's business, not this one's.
fn checkCtorOverloadSet(c: *Checker, members: []const ast.Node, impl: ast.Node) Error!void {
    var overloads: std.ArrayList(ast.Node) = .empty;
    defer overloads.deinit(c.scratch());
    for (members) |m| {
        if (m == null_node or m == impl or c.nodeTag(m) != .class_method) continue;
        const d = c.tree.nodeData(m);
        const proto = c.tree.extraData(ast.FnProto, d.lhs);
        if (!c.isCtorMember(m, proto.flags)) continue;
        if (d.rhs != 0) return;
        try overloads.append(c.scratch(), m);
    }
    try signatures.checkOverloadImplementation(c, overloads.items, impl);
}

/// TS2377 — tsc's `checkConstructorDeclaration`, super-call half:
///
/// ```ts
/// if (getClassExtendsHeritageElement(containingClassDecl)) {
///     const classExtendsNull = classDeclarationExtendsNull(containingClassDecl);
///     const superCall = findFirstSuperCall(node.body!);
///     if (superCall) { … }
///     else if (!classExtendsNull) {
///         error(node, Diagnostics.Constructors_for_derived_classes_must_contain_a_super_call);
///     }
/// }
/// ```
///
/// Only an IMPLEMENTATION is asked (tsc returns early on a missing body), so
/// `body` is never 0 here, and `class C extends null` is exempt — it has no
/// base constructor to call.
fn checkDerivedCtorSuperCall(c: *Checker, extends: ast.Node, ctor: ast.Node, body: ast.Node) Error!void {
    if (extends == null_node or body == null_node) return;
    if (c.nodeTag(extends) != .heritage) return;
    if (c.nodeTag(c.tree.nodeData(extends).lhs) == .null_literal) return;
    if (try hasSuperCall(c, body)) return;
    try c.diagFmt(2377, ctorDeclSpan(c, ctor), "Constructors for derived classes must contain a 'super' call.", .{});
}

/// The span of a constructor DECLARATION, modifiers included — tsc's
/// `error(node, …)` on a `ConstructorDeclaration`, whose `pos` is the start of
/// its modifier list. `nodeSpan` starts at the `constructor` token, so
/// `private constructor() {}` would be blamed three words late. The AST records
/// no modifier tokens, but the parser guarantees a member's modifiers are the
/// contiguous run of modifier keywords immediately before it.
fn ctorDeclSpan(c: *Checker, ctor: ast.Node) source.Span {
    var span = c.nodeSpan(ctor);
    var tok = c.tree.nodeMainToken(ctor);
    while (tok > 0) : (tok -= 1) {
        switch (c.tree.tokens.tag(tok - 1)) {
            .keyword_public,
            .keyword_private,
            .keyword_protected,
            .keyword_declare,
            .keyword_abstract,
            .keyword_override,
            .keyword_readonly,
            .keyword_static,
            => {},
            else => break,
        }
    }
    span.start = c.tokSpan(tok).start;
    return span;
}

/// tsc's `findFirstSuperCall`, as a predicate:
///
/// ```ts
/// function findFirstSuperCall(node: Node): SuperCall | undefined {
///     return isSuperCall(node) ? node :
///         isFunctionLike(node) ? undefined :
///         forEachChild(node, findFirstSuperCall);
/// }
/// ```
///
/// The walk stops at every FUNCTION-LIKE node — an arrow, a function
/// expression, a nested class's own method — because a `super()` written
/// inside one belongs to that function's `super` binding, not to this
/// constructor. It is TS2337's business there, not this check's
/// (`superCallInsideClassDeclaration`: `class B extends A { constructor()
/// { class D extends C { constructor() { super(); } } } }` is still TS2377).
///
/// Iterative rather than recursive: a constructor body is arbitrary user
/// syntax, and this walk has no depth limit of its own.
fn hasSuperCall(c: *Checker, body: ast.Node) Error!bool {
    // Cycle-free by construction (a tree), so the worklist is a plain stack;
    // it lives on the scratch arena for the length of one constructor.
    var stack: std.ArrayList(ast.Node) = .empty;
    defer stack.deinit(c.scratch());
    try stack.append(c.scratch(), body);
    while (stack.pop()) |n| {
        switch (c.nodeTag(n)) {
            .call_expr, .call_expr_targs => {
                if (c.nodeTag(c.tree.nodeData(n).lhs) == .super_expr) return true;
            },
            .arrow_fn,
            .function_expr,
            .function_decl,
            .class_method,
            .object_method,
            .method_signature,
            .call_signature,
            .construct_signature,
            .function_type,
            .constructor_type,
            => continue,
            else => {},
        }
        var it = c.tree.childIterator(n);
        while (it.next()) |ch| try stack.append(c.scratch(), ch);
    }
    return false;
}

/// Walk every function body postponed by `defer_bodies`, in queue order.
/// Each entry restores the file and `this` it was queued under; draining a
/// body may queue more (a nested class, another field), so the loop reads
/// the list by index until it stops growing.
pub fn drainDeferredBodies(c: *Checker) Error!void {
    if (c.deferred_bodies.items.len == 0) return;
    std.debug.assert(c.defer_bodies == 0);
    const saved_ctx = c.saveCtx();
    const saved_this = c.this_type;
    defer {
        c.restoreCtx(saved_ctx);
        c.this_type = saved_this;
    }
    var i: usize = 0;
    while (i < c.deferred_bodies.items.len) : (i += 1) {
        const d = c.deferred_bodies.items[i];
        if (d.file != c.cur_file) c.setFile(d.file);
        c.this_type = d.this_type;
        // Nothing lent this body a receiver on the way in, and it is one of
        // the two shapes whose receiver is only knowable once the thing that
        // owns it is finished — an uncontextualized object literal's member,
        // or an expando assignment's right-hand side. Both are exactly what
        // the deferral bought (tsc's `getContextualThisParameterType` last
        // arm — see `Checker.this_bound_fns`).
        if (c.this_type == 0) {
            if (try expr_zig.deferredThisType(c, d.node)) |t| c.this_type = t;
        }
        try c.checkFunctionBody(d.node, d.proto_idx, d.body, d.sig, d.ret_ctx);
    }
    c.deferred_bodies.clearRetainingCapacity();
}

/// The yield element type and the return type a generator's return type
/// carries — `Generator<Y, R, N>`'s first two arguments.
pub const IterationCtx = struct { yield: TypeId, ret: TypeId };

/// The yield and return contexts a generator takes from a CONTEXTUAL return
/// type — tsc's `getContextualIterationType`, which reads
/// `getIterationTypeOfGeneratorFunctionReturnType` off the contextual
/// signature's return type. Null when that type names no generator.
///
/// The contextual type is routinely a UNION with the generator as one arm
/// (`() => number | Generator<(arg: number) => void, any, void>` —
/// `contextualTypeOnYield1`), so the first arm that names one wins; tsc reaches
/// the same place through `getIterationTypesOfType` over the union.
///
/// Purely contextual: both halves only TYPE the operands, and nothing is
/// reported against either — see `FnCtx.yield_ctx`.
pub fn contextualIteration(c: *Checker, ctx: TypeId, is_async: bool) Error!?IterationCtx {
    if (ctx == 0 or ctx == types.no_type) return null;
    if (c.ts.kind(ctx) == .union_type) {
        for (try c.memberList(ctx)) |m| {
            if (try contextualIteration(c, m, is_async)) |it| return it;
        }
        return null;
    }
    const y = if (is_async) c.asyncGeneratorYieldType(ctx) else c.generatorYieldType(ctx);
    if (y == 0) {
        // `Iterable<T, TReturn>` / `AsyncIterable<…>` are legal generator
        // return types too, and `iteration.generatorYieldType` — whose job is
        // the CHECK target — leaves them out because a written `Iterable`
        // annotation is not what tsc relates a `yield` to. As a CONTEXT it is:
        // `function* (): Iterator<Iterable<(x: string) => number>>` types the
        // inner generator of `yield (function*(){…})()` through it.
        if (c.ts.kind(ctx) != .ref) return null;
        const sym = c.ts.refSymbol(ctx);
        const name = try c.atom(if (is_async) "AsyncIterable" else "Iterable");
        const g = c.prog.globals.lookup(name) orelse return null;
        if (sym != g) return null;
        const iargs = c.ts.refArgs(ctx);
        if (iargs.len == 0) return null;
        return .{ .yield = iargs[0], .ret = if (iargs.len >= 2) iargs[1] else types.no_type };
    }
    const args = c.ts.refArgs(ctx);
    return .{ .yield = y, .ret = if (args.len >= 2) args[1] else types.no_type };
}

/// The `<T, TReturn, TNext>` arguments of a type written with one of the
/// lib's iteration interfaces — `Generator`/`Iterator`/`IterableIterator`
/// and the named built-in iterators (via `iteration.generatorYieldType`),
/// plus `Iterable`, which spells its parameters the same way but is not an
/// iterator so the yield helper deliberately leaves it out. Null for
/// anything else.
fn libIterationArgs(c: *Checker, t: TypeId, is_async: bool) Error!?[]const TypeId {
    if (c.ts.kind(t) != .ref) return null;
    const y = if (is_async) c.asyncGeneratorYieldType(t) else c.generatorYieldType(t);
    if (y == 0) {
        const name = try c.atom(if (is_async) "AsyncIterable" else "Iterable");
        const g = c.prog.globals.lookup(name) orelse return null;
        if (c.ts.refSymbol(t) != g) return null;
    }
    const args = c.ts.refArgs(t);
    return if (args.len == 0) null else args;
}

/// tsc's `getIterationTypesOfGeneratorFunctionReturnType` for a WRITTEN
/// generator return type, with `no_type` standing in for each of tsc's
/// `undefined` iteration types (the caller supplies the fallbacks).
///
/// tsc resolves the ITERABLE protocol first and only then the ITERATOR one,
/// which is what makes `interface BadGenerator extends Iterator<number>,
/// Iterable<string>` yield `string`: `[Symbol.iterator]()` comes off the
/// `Iterable<string>` half, and the mismatch against the `Iterator<number>`
/// half is exactly the error this check exists to find. The same order falls
/// out here — the structural arm reads `[Symbol.iterator]`'s return type.
fn generatorReturnIterationTypes(c: *Checker, ann: TypeId, is_async: bool) Error!IterationTypes {
    const r = try c.resolveStructural(ann);
    switch (c.ts.kind(r)) {
        .any, .err => return .{ .yield = types.any_type, .ret = types.any_type, .next = types.any_type },
        else => {},
    }
    // Written as one of the lib interfaces: the three types ARE its arguments.
    if (try libIterationArgs(c, ann, is_async)) |args| return spellIterationArgs(args);
    // Otherwise the protocol supplies them: `[Symbol.iterator]()` (or
    // `[Symbol.asyncIterator]()`) returns the iterator whose arguments they
    // are. A user interface that merely EXTENDS `IterableIterator<number>`
    // reaches its `T` this way (`generatorTypeCheck7`).
    const key = if (is_async) c.atom_sym_asyncIterator else c.atom_sym_iterator;
    if (try c.propOfType(r, key)) |p| {
        const iter = try c.callableReturn(p.ty);
        if (iter != 0) {
            if (try libIterationArgs(c, iter, is_async)) |args| return spellIterationArgs(args);
        }
    }
    // Neither: only the element type is recoverable, through the general
    // `next(): { value }` walk `for..of` uses.
    const elem = if (is_async) try c.asyncIterationElementType(r) else try c.iterationElementType(r);
    return .{ .yield = elem orelse types.no_type, .ret = types.no_type, .next = types.no_type };
}

/// A lib iteration interface's `<T, TReturn, TNext>` read positionally.
fn spellIterationArgs(args: []const TypeId) IterationTypes {
    return .{
        .yield = args[0],
        .ret = if (args.len >= 2) args[1] else types.no_type,
        .next = if (args.len >= 3) args[2] else types.no_type,
    };
}

/// The three iteration types of a generator's return type, `no_type` where
/// tsc has none.
const IterationTypes = struct { yield: TypeId, ret: TypeId, next: TypeId };

/// tsc's generator arm of `checkSignatureDeclaration`: a WRITTEN generator
/// return type must be something the generator's own `Generator<Y, R, N>`
/// is assignable to.
///
/// ```ts
/// if (returnType === voidType) error(returnTypeNode, A_generator_cannot_have_a_void_type_annotation);
/// else {
///     const generatorYieldType  = getIterationTypeOfGeneratorFunctionReturnType(Yield,  returnType, isAsync) || anyType;
///     const generatorReturnType = getIterationTypeOfGeneratorFunctionReturnType(Return, returnType, isAsync) || generatorYieldType;
///     const generatorNextType   = getIterationTypeOfGeneratorFunctionReturnType(Next,   returnType, isAsync) || unknownType;
///     checkTypeAssignableTo(createGeneratorReturnType(...), returnType, returnTypeNode);
/// }
/// ```
///
/// The round trip is the point, and tsc's own comment says why a plain
/// "`Generator<any, any, any>` is assignable to the annotation" probe is not
/// enough: `interface BadGenerator extends Iterator<number>, Iterable<string>
/// {}` is self-contradictory, and only re-forming a `Generator` out of the
/// types the annotation ITSELF implies exposes it. ztsc checked nothing here,
/// so `function* g(): number {}` and `function* g(): void {}` were silent
/// (`generatorTypeCheck6`/`7`/`8`/`9`).
///
/// Nothing is reported when the annotation is an error/`any` type (already
/// diagnosed, or deliberately opaque) or when the program has no lib to name
/// `Generator` with.
fn checkGeneratorReturnAnnotation(c: *Checker, ret_node: Node, ann: TypeId, is_async: bool) Error!void {
    switch (c.ts.kind(ann)) {
        .void => {
            try c.diagFmt(2505, c.nodeSpan(ret_node), "A generator cannot have a 'void' type annotation.", .{});
            return;
        },
        .any, .err, .none => return,
        else => {},
    }
    const gen_sym = c.prog.globals.lookup(
        if (is_async) c.atom_AsyncGenerator else c.atom_Generator,
    ) orelse return;
    if (!c.symFlags(gen_sym).interface) return;
    const it = try generatorReturnIterationTypes(c, ann, is_async);
    const y = if (it.yield == types.no_type) types.any_type else it.yield;
    const r = if (it.ret == types.no_type) y else it.ret;
    const n = if (it.next == types.no_type) types.unknown_type else it.next;
    const inst = try c.ts.makeRef(gen_sym, &.{ y, r, n });
    _ = try c.checkAssignable(inst, ann, null_node, c.nodeSpan(ret_node));
}

/// `ret_ctx` is the contextual signature's return type when this function
/// has no return annotation (0 otherwise / when there is no context). It
/// only supplies a contextual type to the return expressions — the
/// assignability checks stay on the written annotation.
pub fn checkFunctionBody(c: *Checker, node: Node, proto_idx: u32, body: Node, sig: TypeId, ret_ctx: TypeId) Error!void {
    if (body == 0) return;
    // Owned-file guard (see `checkJsxElement`). This function returns
    // `void` — its *result* is input-independent by construction, so the
    // invariant the JSX guard needs holds trivially here. Everything it
    // does is diagnostics (TS2355/2366, parameter-initializer and return
    // assignability, and whatever the statement walk reports), and
    // `diagFmt` files each one under `cur_file`, which `seal` drops unless
    // this checker owns it.
    //
    // The obligation that is *not* trivial is side effects. The body walk
    // populates `node_types` and materializes symbol types, and a foreign
    // file is only ever entered by materializing a dependency's type — so
    // the question is whether any later answer depends on the cache state
    // this walk would have left behind:
    //
    //   * `node_types` is a memo, and every reader outside diagnostics
    //     re-derives on miss (`checkExprCached`). The three readers that
    //     branch on presence — `elaborateLiteralError`, `assignNarrows`'
    //     compound-assign arm, `guardCallOf`'s member callee — are
    //     either diagnostics-only (dropped here) or reached from
    //     `inferReturnType`, and `checkFunctionLikeExpr`/`checkFunctionDecl`
    //     run that probe BEFORE this body walk, so the probe already sees
    //     a cold cache today. Skipping the walk cannot change what it saw.
    //   * Symbol types are materialized lazily and re-entrantly by
    //     `typeOfSymbol`, never by the body walk being reached first: the
    //     inferred type of anything this file exports is reachable from the
    //     probe/`typeOfSymbol` path alone.
    //   * `reassign_scanned`/`scopes_faulted` are per-file syntactic scans
    //     driven by their own lazy faults, not by this walk.
    //
    // Byte-identity across `--checkers=N` is therefore preserved: the walk
    // interns fewer types in a foreign file, and type identity is already
    // required to be order-independent (that is the determinism contract
    // every `--checkers=N` split exercises).
    if (!c.owned_mask[c.cur_file]) return;
    // Reached while materializing a class field's type: postpone the walk
    // until the enclosing class's instance type exists (see `DeferredBody`).
    if (c.defer_bodies > 0) {
        try c.deferred_bodies.append(c.cm(), .{
            .file = c.cur_file,
            .node = node,
            .proto_idx = proto_idx,
            .body = body,
            .sig = sig,
            .ret_ctx = ret_ctx,
            .this_type = c.this_type,
        });
        return;
    }
    const proto = c.tree.extraData(ast.FnProto, proto_idx);
    const saved_scope = c.cur_scope;
    const saved_ctx = c.fn_ctx;
    const saved_this = c.this_type;
    // A function body is its own control-flow container, so it takes over from
    // an enclosing class field's initializer — `x = <U>(a: U) => { var y: T;
    // return y }` still reports TS2454 on `y` (see `field_init_depth`).
    const saved_field_init = c.field_init_depth;
    c.field_init_depth = 0;
    // …and the super-call container: this body is the container for every
    // `super(…)` written directly in it, whatever the enclosing one was.
    const saved_in_ctor = c.in_ctor_body;
    const saved_in_key = c.in_computed_key;
    // …and the `super` container a DECORATOR steps out of its class for: a
    // function written inside the decorator is a container of its own.
    const saved_in_deco = c.in_decorator;
    c.in_ctor_body = c.nodeTag(node) == .class_method and c.isCtorMember(node, proto.flags);
    c.in_computed_key = false;
    c.in_decorator = false;
    defer {
        c.cur_scope = saved_scope;
        c.fn_ctx = saved_ctx;
        c.this_type = saved_this;
        c.field_init_depth = saved_field_init;
        c.in_ctor_body = saved_in_ctor;
        c.in_computed_key = saved_in_key;
        c.in_decorator = saved_in_deco;
    }
    if (try c.scopeOf(node)) |s| c.cur_scope = s;
    // An explicit `this` parameter types `this` inside the body.
    if (c.ts.kind(sig) == .function) {
        const tt = c.ts.fnThisType(sig);
        if (tt != 0) c.this_type = tt;
    }
    const is_async = proto.flags & ast.Flags.async != 0;
    const is_generator = proto.flags & ast.Flags.generator != 0;
    const ann: TypeId = if (proto.return_type != 0) try c.typeFromTypeNode(proto.return_type) else types.no_type;
    // Effective return-check target. For async this is the awaited payload
    // `T` of the declared `Promise<T>`; a non-Promise annotation is TS1064.
    var eff_ann = ann;
    var yield_type: TypeId = 0;
    if (is_async and is_generator) {
        // `async function*`: annotated with an AsyncGenerator-family type,
        // not Promise — TS1064 does not apply. Relate `yield x` to its
        // first type arg (yielded promises are awaited at the yield site).
        yield_type = c.asyncGeneratorYieldType(ann);
        eff_ann = types.no_type;
    } else if (is_async and ann != types.no_type) {
        const k = c.ts.kind(ann);
        const is_promise = c.ts.kind(ann) == .ref and c.prog.globals.lookup(c.atom_Promise) != null and
            c.ts.refSymbol(ann) == c.prog.globals.lookup(c.atom_Promise).?;
        if (is_promise) {
            eff_ann = try c.awaitedType(ann);
        } else if (k != .err and k != .none) {
            try c.diagFmt(1064, c.nodeSpan(proto.return_type), "The return type of an async function or method must be the global Promise<T> type. Did you mean to write 'Promise<{s}>'?", .{try c.typeToString(ann)});
            eff_ann = types.no_type; // suppress payload assignability noise
        }
    } else if (is_generator) {
        // Generators: relate `yield x` to `T` from `Generator<T>`; return
        // values (→ TReturn) are unchecked (gap).
        yield_type = c.generatorYieldType(ann);
        eff_ann = types.no_type;
    }
    // An unannotated GET accessor beside an ANNOTATED set accessor has a
    // return-check target all the same: tsc's `getReturnTypeFromAnnotation`
    // answers the setter's parameter annotation for it, so
    // `get bar() { return 0 }` beside `set bar(n: string)` is TS2322 on the
    // return statement (`inferSetterParamType`, `getSetAccessorContextualTyping`,
    // `divergentAccessorsTypes6`). Applied to `eff_ann` alone, AFTER the
    // async/generator arms: `ann` is what those read to decide whether a
    // `Promise<T>` was WRITTEN, and an accessor is neither.
    if (proto.return_type == 0 and !is_async and !is_generator) {
        const acc = try signatures.getterReturnFromSetter(c, node, proto);
        if (acc != types.no_type) eff_ann = acc;
    }
    // A SET accessor returns `void` whatever it was annotated with. tsc's
    // `checkAccessorDeclaration` never runs the function-like return checks on
    // one at all — it checks the body and the get/set agreement rules and
    // stops — so the annotation is TS1095's business alone (a `return v` in
    // the body is TS2408, a report of its own). Reading it as an ordinary
    // return target instead put a TS2355 on `set Goo(v: string): string {}`
    // and a TS2534 on a `never` one (`gettersAndSettersErrors`).
    if (proto.flags & ast.Flags.set != 0) eff_ann = types.no_type;
    // A WRITTEN generator return type has to be something a generator can
    // actually produce — see `checkGeneratorReturnAnnotation`. Only with a
    // body: tsc's `getFunctionFlags` marks a bodyless declaration `Invalid`
    // and the check is gated on `(flags & (Invalid | Generator)) ===
    // Generator`, so an overload signature and `declare function*` are exempt.
    if (is_generator and proto.return_type != 0) {
        try checkGeneratorReturnAnnotation(c, proto.return_type, ann, is_async);
    }
    // No contextual fallback for an un-annotated generator's yield type.
    // tsc's `getContextualIterationType` exists, but taking it here (plus a
    // union arm in `generatorYieldType`, so
    // `() => number | Generator<F, any, void>` answers) was measured to buy
    // nothing and cost one false TS2322: `generatorTypeCheck63`'s
    // `strategy("Nothing", function*(state: State) { yield 1; … })` earns a
    // per-yield error ztsc would then report and tsgo does not — tsgo blames
    // the ARGUMENT (TS2345) and leaves the yield alone. The family this was
    // meant to fix (`contextualTypeOnYield1/2`, `generatorTypeCheck27-30`) is
    // blocked elsewhere anyway: the parameters of an arrow written as a yield
    // operand are typed while the enclosing generator's return type is
    // INFERRED, and that walk builds its own `fn_ctx` with `yield_type = 0`
    // in `signatures.zig`. (wave 13 B, measured.)
    // Contextual return type: only meaningful when nothing was written and
    // the function is not a generator. Async unwraps to the payload, as
    // `eff_ann` does for a written `Promise<T>`.
    var eff_ret_ctx: TypeId = if (proto.return_type == 0 and !is_generator) ret_ctx else types.no_type;
    if (eff_ret_ctx != types.no_type and is_async) eff_ret_ctx = try c.awaitedType(eff_ret_ctx);
    // A generator's yield and return contexts come from its
    // `Generator<T, TReturn, …>` — the WRITTEN one when there is an
    // annotation, else the contextual signature's return type. Both are
    // contexts only; `yield_type` above is the sole check target, and a
    // generator's `return` expression has never had one (`eff_ann` is cleared
    // for it), so `IterableIterator<F, F>`'s `return x => x.length` was typed
    // by nothing at all. See `contextualIteration`.
    var yield_ctx: TypeId = 0;
    var gen_ret_ctx: TypeId = 0;
    if (is_generator) {
        gen_ret_ctx = if (proto.return_type != 0) ann else ret_ctx;
        if (try contextualIteration(c, gen_ret_ctx, is_async)) |it| {
            yield_ctx = it.yield;
            eff_ret_ctx = it.ret;
        }
    }
    c.fn_ctx = .{
        .ret_ann = eff_ann,
        .ret_ctx = eff_ret_ctx,
        .is_async = is_async,
        .is_generator = is_generator,
        .yield_type = yield_type,
        .yield_ctx = yield_ctx,
        .gen_ret_ctx = gen_ret_ctx,
    };

    // Check parameter initializers against annotations.
    for (c.tree.extraRange(proto.params_start, proto.params_end)) |pn| {
        const pd = c.tree.nodeData(pn);
        // `.param` is the plain spelling (`x`, `x: T`) and carries its
        // annotation directly; `.param_full` is everything with a default,
        // a modifier or a `?`.
        const name: Node, const type_ann: Node, const init: Node = switch (c.nodeTag(pn)) {
            .param => .{ pd.lhs, pd.rhs, null_node },
            .param_full => blk: {
                const e = c.tree.extraData(ast.ParamFull, pd.rhs);
                break :blk .{ pd.lhs, e.type_ann, e.init };
            },
            else => continue,
        };
        // A DESTRUCTURED parameter's own elements each carry a declaration of
        // their own (tsc's `checkVariableLikeDeclaration` runs on every
        // `BindingElement`), so each default inside the pattern is checked and
        // related just as a `var`/`let` pattern's is. Nothing else walked
        // them: `pinPatternParamSyms` only publishes the bound TYPES, so
        // `function f({ a = xyz }: A)` never even resolved `xyz`.
        //
        // Only when the parameter is ANNOTATED: tsc's
        // `getTypeForBindingElementParent` reads the parameter's declaration
        // alone and never consults a contextual signature, so a callback's
        // `({ s = 1 }) => …` has no parent type and reports nothing.
        if (implicit_any.isBindingPattern(c, name)) {
            if (type_ann != 0) {
                // What the pattern destructures is what the BODY sees, which
                // a default takes `undefined` off of
                // (`signatures.paramBodyType`).
                const ann_t = try signatures.paramBodyType(c, pn, try c.typeFromTypeNode(type_ann), init != 0);
                try materializePatternTypes(c, name, ann_t, .relate);
                // …and what the pattern DEMANDS of that type (TS2339/TS2551
                // per element, TS2488 for a non-iterable array pattern), the
                // parameter's half of what `checkDeclPattern` runs for a
                // `var`/`let`. `function f({ q }: { a: number })` was silent.
                try destructure.checkPatternProps(c, name, ann_t);
            } else {
                try materializePatternTypes(c, name, types.no_type, .contextual_only);
            }
        }
        if (init != 0 and type_ann != 0) {
            const ann_t = try c.typeFromTypeNode(type_ann);
            const it = try c.checkExprCached(init, ann_t);
            // tsc's `checkVariableLikeDeclaration` anchors an initializer
            // mismatch at the DECLARATION (`errorNode = node`), not at the
            // initializer, and only descends into the initializer when the
            // elaboration finds something narrower to blame — exactly what a
            // `var`/`const` declarator already does here. A parameter's
            // declaration starts at its name, so `function f<T extends
            // Number>(x: T = 1)` reports on `x`, not on the `1`.
            _ = try c.checkAssignable(it, ann_t, init, c.nodeSpan(pn));
        } else if (init != 0) {
            _ = try c.checkExprCached(init, types.no_type);
        }
    }

    if (c.nodeTag(body) == .block) {
        for (c.tree.nodeRange(body)) |stmt| try c.checkStatement(stmt);
        // tsc's `checkAccessorDeclaration`: a `get` accessor with a body
        // whose END IS REACHABLE and which writes no `return` at all is
        // TS2378, reported at the accessor's NAME.
        //
        // Both halves of the condition are the binder flags the ending-return
        // analysis below reads (`HasImplicitReturn` / `HasExplicitReturn`),
        // so the two questions are the same two asked there — but the ANSWER
        // is independent of the return type: `get g(): void {}` and
        // `get h(): any {}` are TS2378 even though a plain function with
        // either annotation needs no return at all, and `get a(): number {}`
        // is TS2378 *and* TS2355. A bare `return;` satisfies it (the binder
        // sets `hasExplicitReturn` for any return statement), and a `return`
        // inside a NESTED function does not (`collectReturns` stops at
        // function boundaries, as the binder's per-function flag does).
        if (proto.flags & ast.Flags.get != 0 and !c.ambient_ctx and
            !c.stmtListTerminal(c.tree.nodeRange(body)))
        {
            // Only the presence of returns matters, so the scope handed over
            // is irrelevant — see the TS2355 collection below.
            var rets = try c.collectReturns(c.tree.nodeRange(body), binder.file_scope);
            defer rets.deinit(c.scratch());
            if (rets.exprs.items.len == 0 and !rets.bare) {
                // The parser gives an accessor's `FnProto` the key token,
                // which for a computed object-literal key is the `[` — the
                // start of tsc's `node.name` either way.
                const name_span = if (proto.name_token != 0)
                    c.tokSpan(proto.name_token)
                else
                    c.tokSpan(c.tree.nodeMainToken(node));
                try c.diagFmt(2378, name_span, "A 'get' accessor must return a value.", .{});
            }
        }
        // Ending-return analysis (TS2355/2366). For async the target is the
        // Promise payload; generators do not require an ending return.
        if (!is_generator and eff_ann != types.no_type and eff_ann != types.error_type) {
            const k = c.ts.kind(eff_ann);
            const exempt = k == .void or k == .any or k == .err or k == .unknown or k == .none or
                c.containsUndefinedish(eff_ann);
            if (!exempt) {
                // Only the presence of returns matters here, so the scope
                // handed over is irrelevant — nothing re-checks the operands.
                var rets = try c.collectReturns(c.tree.nodeRange(body), binder.file_scope);
                defer rets.deinit(c.scratch());
                // tsc's `checkAllCodePathsInNonVoidFunctionReturnOrThrow`
                // anchors all three of these on
                // `getEffectiveReturnTypeNode(func) || func` — the written
                // RETURN TYPE, not the function's name. Every one of these
                // reports needs an annotation to fire (`eff_ann` comes from
                // `proto.return_type` alone), so the node is always there;
                // the name/keyword fallback only guards the invariant.
                const span = if (proto.return_type != 0)
                    c.nodeSpan(proto.return_type)
                else if (proto.name_token != 0)
                    c.tokSpan(proto.name_token)
                else
                    c.tokSpan(c.tree.nodeMainToken(node));
                if (!c.stmtListTerminal(c.tree.nodeRange(body))) {
                    if (k == .never) {
                        // A `never` return is the FIRST arm in tsc, ahead of
                        // both "must return a value" and the ending-return
                        // message: reaching the end of the body contradicts
                        // the annotation whether or not a return was written.
                        try c.diagFmt(2534, span, "A function returning 'never' cannot have a reachable end point.", .{});
                    } else if (rets.exprs.items.len == 0 and !rets.bare) {
                        try c.diagFmt(2355, span, "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.", .{});
                    } else {
                        try c.diagFmt(2366, span, "Function lacks ending return statement and return type does not include 'undefined'.", .{});
                    }
                }
            }
        }
    } else {
        // Arrow expression body. For async, relate the awaited body type to
        // the Promise payload (`async () => p` returns `Promise<T>`).
        const rt = try c.checkExprCached(body, if (eff_ann != types.no_type) eff_ann else eff_ret_ctx);
        if (eff_ann != types.no_type and eff_ann != types.error_type) {
            const eff_rt = if (is_async) try c.awaitedType(rt) else rt;
            _ = try c.checkAssignable(eff_rt, eff_ann, body, c.nodeSpan(body));
        }
    }
}

// Syntactic reachability lives in `reachability.zig`; re-exported here because
// the statement walk above drives it and `Checker`'s method aliases name this
// file.
pub const containsBreak = reachability.containsBreak;
pub const stmtListTerminal = reachability.stmtListTerminal;
pub const stmtTerminal = reachability.stmtTerminal;
pub const switchIsExhaustive = reachability.switchIsExhaustive;
pub const switchTerminal = reachability.switchTerminal;
pub const typeofSwitchIsExhaustive = reachability.typeofSwitchIsExhaustive;

// --- classes / interfaces / aliases ------------------------------------

/// Check a namespace body: enter the (merged) namespace scope and check
/// each body statement there. Member visibility/typing is materialized by
/// classStaticType (value) and typeFromQualifiedName (type).
fn checkNamespace(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.NamespaceData, d.lhs);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    // `declare namespace N`, `declare module "spec"` and `declare global`
    // all open an ambient context for their body (tsc's `NodeFlags.Ambient`),
    // and it stays open once opened.
    const saved_ambient = c.ambient_ctx;
    defer c.ambient_ctx = saved_ambient;
    if (data.flags & ast.Flags.declare != 0) c.ambient_ctx = true;
    // This block is the body's control-flow container — see `cur_ns_block`.
    const saved_block = c.cur_ns_block;
    defer c.cur_ns_block = saved_block;
    c.cur_ns_block = node;
    // The body scope is the one owned by this node, or — for a merged
    // block whose scope is owned by an earlier block — the namespace
    // symbol's members scope.
    if (try c.scopeOf(node)) |s| {
        c.cur_scope = s;
    } else if (data.name_token != 0) {
        const a = try c.atomOfToken(data.name_token);
        if (c.bind.lookupInScope(saved, a)) |sym| {
            if (c.bind.namespaceScopeOf(sym)) |ns| c.cur_scope = ns;
        }
    }
    for (c.tree.extraRange(data.body_start, data.body_end)) |stmt| {
        if (stmt != null_node) try c.checkStatement(stmt);
    }
}

/// Instantiation budget one derived-vs-base relation may spend
/// (`relatesToBase`). An order of magnitude below the source element's own
/// ceiling (`max_instantiation_count`), and deliberately so: what this
/// relation materializes is the BASE's declaration, and the only question it
/// asks is whether the two sides already agree.
///
/// Measured on drizzle-orm at `--checkers=4`, where the partition puts
/// `prisma/mysql/session.d.ts` on a checker that owns none of `mysql-core`:
/// the full ceiling spends 250,000 instantiations and 272 ms building that
/// package from nothing before answering YES, and 25,000 answers the same YES
/// in 39 ms. On a checker that does own `mysql-core` the relation costs 27
/// instantiations either way — the ceiling is only ever reached by the cold
/// partition, which is exactly the work this bounds.
const max_base_relation_instantiations: u64 = 25_000;

/// One derived-vs-base relation (`D` to `B`, or `typeof D` to `typeof B`),
/// run in its own instantiation WINDOW — the one `measuredVariances` opens for
/// a variance measurement, and for the same reason.
///
/// What this relation materializes is the BASE's declaration, which usually
/// lives in another file. A checker that does not own that file has to build
/// it from nothing, and that is not work the class declaration asked for:
/// charged to the declaration's own budget it spends the source element's
/// whole ceiling, after which every remaining instantiation in the statement
/// truncates and nothing more is published — a regime an order of magnitude
/// more expensive than the work it replaces. drizzle-orm's
/// `PrismaMySqlSession extends MySqlSession` is the case, and it is
/// partition-dependent exactly as that argument predicts: the relation costs
/// 27 instantiations on a checker that already owns `mysql-core` and over
/// 250,000 on one that does not. The window keeps the cost where it belongs
/// and, capped at `max_base_relation_instantiations`, keeps it bounded.
///
/// A window that runs out answers YES, which is what the relation concludes
/// anyway once its subtrees truncate to `error_type` (which relates to
/// everything). So the failure mode is the one the whole check already
/// documents next to `hasUnresolvedBase`: nothing is concluded about a base
/// ztsc could not finish building, and the cost is an under-report.
fn relatesToBase(c: *Checker, derived: TypeId, base: TypeId) Error!bool {
    const saved_count = c.inst_count;
    const saved_epoch = c.budget_epoch;
    const saved_tripped = c.inst_limit_tripped;
    const saved_budget = c.inst_budget;
    c.inst_count = 0;
    c.inst_budget = max_base_relation_instantiations;
    c.newBudgetWindow();
    c.inst_limit_tripped = false;
    const ok = c.isAssignable(derived, base);
    c.inst_budget = saved_budget;
    c.inst_count = saved_count;
    c.budget_epoch = saved_epoch;
    c.inst_limit_tripped = saved_tripped;
    return ok;
}

/// TS2415 / TS2416: the INSTANCE side of a derived class must extend its base
/// — `D` assignable to `B` — which is what makes a derived member that
/// redeclares an inherited one at an incompatible type an error rather than a
/// silent narrowing of the instance type.
///
/// tsc's `checkClassLikeDeclaration`:
///
/// ```ts
/// if (!checkTypeAssignableTo(typeWithThis, baseWithThis, /*errorNode*/ undefined)) {
///     issueMemberSpecificError(node, typeWithThis, baseWithThis,
///         Diagnostics.Class_0_incorrectly_extends_base_class_1);
/// } else {
///     // Report static side error only when instance type is assignable
///     checkTypeAssignableTo(staticType, getTypeWithoutSignatures(staticBaseType), …);
/// }
/// ```
///
/// Two properties of that shape are load-bearing and are reproduced here:
///
///   * the pair is related ONCE with no error node, and the diagnostic is
///     produced by a second, per-member pass (`issueMemberSpecificError`).
///     That pass walks the class's OWN instance members and, for each name the
///     derived and the base BOTH have, relates the two property types; every
///     failing member reports its own TS2416. Only when no member failed —
///     the mismatch is in an index signature, a call signature, or a member
///     the base does not declare — does the broad TS2415 fire, once, on the
///     class name;
///   * the STATIC side (TS2417, `checkStaticSideExtends`) is checked only when
///     the instance side passed, so a class whose members contradict the base
///     reports the member, not both halves of the same story.
///
/// Guarded exactly as the `implements` check next to it: nothing is concluded
/// about a class whose base ztsc could not resolve (`hasUnresolvedBase`), where
/// the instance type is missing whatever that base contributed and the verdict
/// would be about ztsc's gap rather than the code.
///
/// Returns whether the instance side is assignable, i.e. whether the caller
/// should go on to the static side.
fn checkInstanceSideExtends(c: *Checker, class_sym: SymbolId, members: []const Node, this_t: TypeId, name_token: ast.TokenIndex) Error!bool {
    const base_ref = try c.baseClassRef(class_sym) orelse return true;
    if (base_ref == types.error_type or base_ref == types.any_type or base_ref == this_t) return true;
    if (try c.hasUnresolvedBase(class_sym)) return true;
    // Windowed and bounded — see `relatesToBase`.
    if (try relatesToBase(c, this_t, base_ref)) return true;
    if (try privateShadowNeutralized(c, this_t, base_ref)) |neutral| {
        if (try relatesToBase(c, neutral, base_ref)) return true;
    }

    const issued = try issueMemberSpecificError(c, members, this_t, base_ref);
    if (!issued and name_token != 0) {
        try c.diagFmt(2415, c.tokSpan(name_token), "Class '{s}' incorrectly extends base class '{s}'.{s}", .{
            c.symbolName(class_sym),
            try c.typeToString(base_ref),
            try elaborate.chainText(c, this_t, base_ref),
        });
    }
    return false;
}

/// `derived` with every `#name` property it SHADOWS from the base restored to
/// the base's own, or null when it shadows none.
///
/// tsc names each `#foo` declaration `__#<id>@foo`, so a derived class's
/// `#foo` is a DIFFERENT property from its base's and the base's stays on the
/// derived instance type untouched — which is why
///
///     class A { #foo: number }
///     class B extends A { #foo: string }
///
/// is not an error at all (`privateNamesAndFields`). ztsc keys both under the
/// atom `#foo`, so the derived declaration overwrites the inherited entry and
/// the pair reads as an incompatible override.
///
/// Giving private names per-class atoms is the faithful fix, but the atom is
/// what every diagnostic prints as the member's name, so the synthetic key
/// would leak into TS2339/TS2416/`keyof` messages. Undoing the shadowing for
/// the one question that asks it keeps the identity where it is needed and
/// the spelling where the user reads it. Only reached once the plain relation
/// has already failed, so it costs nothing on a class that extends cleanly.
fn privateShadowNeutralized(c: *Checker, derived: TypeId, base: TypeId) Error!?TypeId {
    const d = try c.resolveStructural(derived);
    if (c.ts.kind(d) != .object) return null;
    const b = try c.resolveStructural(base);
    var props: std.ArrayList(types.Prop) = .empty;
    defer props.deinit(c.scratch());
    var shadowed = false;
    for (0..c.ts.objectPropCount(d)) |i| {
        var p = c.ts.objectProp(d, @intCast(i));
        const text = c.atomText(p.name);
        if (text.len != 0 and text[0] == '#') {
            if (try c.propOfTypeEx(b, p.name, false)) |bp| {
                if (bp.ty != p.ty) {
                    p = bp;
                    shadowed = true;
                }
            }
        }
        try props.append(c.scratch(), p);
    }
    if (!shadowed) return null;
    var calls: std.ArrayList(TypeId) = .empty;
    defer calls.deinit(c.scratch());
    for (0..c.ts.objectCallSigCount(d)) |i| {
        try calls.append(c.scratch(), c.ts.objectCallSig(d, @intCast(i)));
    }
    var ctors: std.ArrayList(TypeId) = .empty;
    defer ctors.deinit(c.scratch());
    for (0..c.ts.objectConstructSigCount(d)) |i| {
        try ctors.append(c.scratch(), c.ts.objectConstructSig(d, @intCast(i)));
    }
    return try c.ts.makeObjectSigs(
        props.items,
        c.ts.objectStringIndex(d),
        c.ts.objectNumberIndex(d),
        c.ts.objectFlags(d),
        calls.items,
        ctors.items,
    );
}

/// Does an `implements` clause name a CLASS? tsc's `checkClassLikeDeclaration`
/// reads `t.symbol.flags & SymbolFlags.Class` to choose between TS2720 ("Did
/// you mean to extend…?") and the plain TS2420, and a class instance type is
/// exactly the `.ref` whose symbol carries the class flag.
fn implementsTargetIsClass(c: *Checker, t: TypeId) bool {
    if (c.ts.kind(t) != .ref) return false;
    return c.symFlags(c.ts.refSymbol(t)).class;
}

/// tsc's `issueMemberSpecificError`: when a class fails to relate to its base
/// class or to an `implements` target, the blame goes to the class's OWN
/// instance members first. Every name the class and the target BOTH declare
/// whose property types do not relate reports its own TS2416, and the broad
/// class-level diagnostic (TS2415 / TS2420 / TS2720) is the caller's to emit
/// — only when this pass reported nothing, i.e. when the mismatch is in an
/// index signature, a call signature, or a member the class does not write.
///
/// Walks the SYNTAX members, in source order, exactly as tsc's
/// `for (const member of node.members)` does. That is not just a convenient
/// way to reach the names: it decides which members are candidates at all. A
/// CONSTRUCTOR PARAMETER PROPERTY (`constructor(public a: string)`) declares
/// `a` on the instance type but is not a member node, so tsc never blames it
/// and reports the broad diagnostic instead — walking the member SCOPE, which
/// does contain `a`, would report TS2416 where the oracle does not.
///
/// The span tsc blames on a class member's NAME — its `member.name` node.
///
/// For an ordinary member that is the name token, which `main_token` already
/// is. For a COMPUTED one `member.name` is the whole `[…]`, and `main_token` is
/// deliberately not it: the parser keys the member by a token INSIDE the
/// brackets so that a name lookup has one token to read
/// (`parseComputedMemberName`). `[Symbol.toPrimitive]() {}` is blamed at the
/// `[`, eight columns left of the token that names it (`symbolProperty24`).
///
/// Two of the four computed spellings retain their `[…]` node, and it carries
/// the span outright. The other two do not — a well-known-symbol key and a
/// literal key both have expressions the checker never needs back — so their
/// bracket is recovered from the token stream, whose layout the parser pins:
/// `[`, `Symbol`, `.`, name, `]` for the first and `[`, literal, `]` for the
/// second. A non-computed name is never preceded by `[` in a class body (an
/// index signature is a member node of its own), so the test cannot misfire.
fn memberNameSpan(c: *Checker, member: Node, flags: u32) source.Span {
    if (c.tree.computedKey(member)) |key| return c.nodeSpan(key);
    const name = c.tree.nodeMainToken(member);
    const l_bracket: ast.TokenIndex = if (flags & ast.Flags.computed != 0 and name >= 3)
        name - 3
    else if (name >= 1 and c.tree.tokens.tag(name - 1) == .l_bracket)
        name - 1
    else
        return c.tokSpan(name);
    if (c.tree.tokens.tag(l_bracket) != .l_bracket) return c.tokSpan(name);
    const last = if (c.tree.tokens.tag(name + 1) == .r_bracket) name + 1 else name;
    return .{ .start = c.tree.tokens.start(l_bracket), .end = c.tokSpan(last).end };
}

/// Returns whether any member reported.
fn issueMemberSpecificError(c: *Checker, members: []const Node, this_t: TypeId, target: TypeId) Error!bool {
    const derived = try c.resolveStructural(this_t);
    const base = try c.resolveStructural(target);
    var issued = false;
    for (members) |member| {
        if (member == null_node) continue;
        const md = c.tree.nodeData(member);
        const flags: u32 = switch (c.nodeTag(member)) {
            .class_field => c.tree.extraData(ast.Field, md.lhs).flags,
            .class_method => c.tree.extraData(ast.FnProto, md.lhs).flags,
            // A decorator, an index signature, a static block, a `;` — none of
            // them is a named member (tsc's `member.name` is undefined and
            // `getPropertyOfType` finds nothing for the member's own symbol).
            else => continue,
        };
        // tsc's `if (isStatic(member)) continue;` — this is the INSTANCE side.
        if (flags & ast.Flags.static != 0) continue;
        if (c.isCtorMember(member, flags)) continue;
        const name_atom = try c.memberKey(c.tree.nodeMainToken(member), flags);
        const prop = (try c.propOfTypeEx(derived, name_atom, false)) orelse continue;
        const base_prop = (try c.propOfTypeEx(base, name_atom, false)) orelse continue;
        if (prop.ty == base_prop.ty) continue;
        if (try c.isAssignable(prop.ty, base_prop.ty)) continue;
        issued = true;
        // tsc's `rootChain`: the TS2416 headline is the ROOT of the chain the
        // ordinary relation would have printed, so the "Type 'X' is not
        // assignable to type 'Y'." line the headline usually carries appears
        // one level in, with the structural derivation under it.
        try c.diagFmt(2416, memberNameSpan(c, member, flags), "Property '{s}' in type '{s}' is not assignable to the same property in base type '{s}'.\n  Type '{s}' is not assignable to type '{s}'.{s}", .{
            c.atomText(name_atom),
            try c.typeToString(this_t),
            try c.typeToString(target),
            try c.typeToString(prop.ty),
            try c.typeToString(base_prop.ty),
            try indentChain(c, try elaborate.chainText(c, prop.ty, base_prop.ty)),
        });
    }
    return issued;
}

/// One extra indentation level for a derivation chain nested under a headline
/// that already spent one (`checkInstanceSideExtends`, and `decorators.zig`'s
/// legacy argument failure). `chainText` renders from column 2; TS2416's chain
/// hangs off the relation line the headline pushed down, so every line moves
/// right by two.
pub fn indentChain(c: *Checker, chain: []const u8) Error![]const u8 {
    if (chain.len == 0) return chain;
    var out: std.Io.Writer.Allocating = .init(c.scratch());
    for (chain) |ch| {
        out.writer.writeByte(ch) catch return error.OutOfMemory;
        if (ch == '\n') out.writer.writeAll("  ") catch return error.OutOfMemory;
    }
    return out.written();
}

/// TS2417: the static side of a derived class must extend the static side
/// of its base — `typeof D` assignable to `typeof B`, which is what makes a
/// derived static that shadows a base static with an incompatible type an
/// error rather than a silent narrowing of the constructor object.
///
/// tsc relates `getTypeOfSymbol(class)` against
/// `getTypeWithoutSignatures(staticBaseType)`: construct signatures are
/// dropped (a derived ctor never has to match the base's), and `prototype`
/// is skipped by the `SymbolFlags.Prototype` filter in `propertiesRelatedTo`
/// (it is the instance side's job, TS2415). ztsc's `classStaticType` carries
/// neither signatures nor `prototype`, so relating the two objects directly
/// *is* the filtered relation.
///
/// The source object is the merged one — `classStaticType` already folds the
/// base's statics in with own members winning — so every base member the
/// derived does not shadow is present verbatim and relates trivially. Only a
/// genuine incompatible shadow can fail, which keeps this off valid code.
/// Reported on the class name, tsc's `node.name || node`.
fn checkStaticSideExtends(c: *Checker, class_sym: SymbolId, name_token: ast.TokenIndex) Error!void {
    if (name_token == 0) return;
    const base = try c.baseClassSym(class_sym) orelse return;
    const derived_static = try c.classStaticType(class_sym);
    // The base's `static #name` members are not on `typeof D` — a private
    // identifier is mangled per class, so a derived class inherits none of them
    // (`statics.withoutPrivateNames`) — and they are not on the TARGET side of
    // this relation either: tsc's `getPropertiesOfType` drops them as reserved
    // member names, so `propertiesRelatedTo` never asks the derived side for
    // one. Relating against the unfiltered table instead made every `class D
    // extends B {}` under a `static #p` a false TS2417
    // (`privateNamesConstructorChain-1`, `privateNameStaticAccessorssDerivedClasses`).
    const base_static = try statics.withoutPrivateNames(c, base, try c.classStaticType(base));
    if (derived_static == base_static) return;
    if (try relatesToBase(c, derived_static, base_static)) return;
    try c.diagFmt(2417, c.tokSpan(name_token), "Class static side 'typeof {s}' incorrectly extends base class static side 'typeof {s}'.{s}", .{
        c.symbolName(class_sym),
        c.symbolName(base),
        try elaborate.chainText(c, derived_static, base_static),
    });
}

/// One instance property declaration that `strictPropertyInitialization` has
/// to judge: it has no initializer, no `!`, a type that cannot be `undefined`,
/// and a name the flow graph can key. Collected while the members are checked
/// (the annotation is typed exactly once, by the member walk) and judged after,
/// so the constructor's body has been checked before its flow is queried.
const InitCand = struct { member: Node, ty: TypeId, flags: u32 };

/// tsc's `isPropertyWithoutInitializer` plus the surrounding filters in
/// `checkPropertyInitialization`, applied to one `class_field`:
///
///   * an initializer, a definite-assignment assertion (`x!:`), `abstract`, a
///     `declare` modifier or `static` all exempt the declaration outright
///     (`static` because TS2564 is an *instance* check — the outer loop tests
///     `!isStatic(member)`);
///   * `?` exempts it because the property type then includes `undefined`,
///     which is also what exempts an explicit `| undefined`, `any` and
///     `unknown` (`type.flags & AnyOrUnknown || containsUndefinedType(type)`);
///   * the name must be an identifier, a private name or a computed name —
///     tsc's `isIdentifier(propName) || isPrivateIdentifier(propName) ||
///     isComputedPropertyName(propName)` — so a QUOTED or numeric member name
///     (`"quoted": string`) is silently skipped, verified against the oracle.
///
/// A COMPUTED name passes this filter (tsc's `isComputedPropertyName` arm), and
/// which question gets asked of it depends on whether ztsc can key it:
///
///   * a LITERAL computed name (`["a"]: string`) is keyed by the literal's text
///     exactly as tsc's late binding keys it, so the ordinary flow query
///     answers — and it has to, because `this.a = v`, `this["a"] = v` and
///     `this[1] = v` all count as the assignment (measured against tsgo). The
///     `.string_literal`/`.numeric_literal` skip above must therefore NOT catch
///     it: that arm is for a QUOTED member name, whose name node is a literal
///     rather than a `ComputedPropertyName`;
///   * every other computed spelling is routed to `checkComputedPropertyInit`
///     instead: ztsc keys those by a placeholder atom (`memberNameKey`) that a
///     `this[k] = v` write does not produce, so the flow graph cannot answer
///     for them and only the syntactic question is safe to ask.
fn initCandidate(c: *Checker, member: Node, e: ast.Field, ann: TypeId) bool {
    if (e.init != 0) return false;
    const exempt = ast.Flags.definite | ast.Flags.abstract | ast.Flags.declare |
        ast.Flags.static | ast.Flags.optional;
    if (e.flags & exempt != 0) return false;
    if (e.flags & ast.Flags.computed_lit == 0) {
        switch (c.tree.tokens.tag(c.tree.nodeMainToken(member))) {
            .string_literal, .numeric_literal => return false,
            else => {},
        }
    }
    if (ann == types.no_type or ann == types.error_type) return false;
    switch (c.ts.kind(ann)) {
        .any, .unknown, .err => return false,
        else => {},
    }
    return !c.hasUndefinedMember(ann);
}

/// tsc's `findConstructorDeclaration`: the class's own constructor *with a
/// body* (an overload signature is not the implementation), or `null_node`.
/// A base class's constructor does not count — the check is per class.
/// Does an un-annotated, un-initialized class field really fall to `any` — the
/// TS7008 precondition — or does tsc have another source for its type?
///
/// tsc's `getTypeForVariableLikeDeclaration` answers this for a property
/// declaration under `noImplicitAny` in three ways, and each one has to be
/// respected here or the diagnostic is a false positive on ordinary code
/// (excalidraw's `public code;` / `private _getFiles;` are both assigned in
/// their constructor and carry no annotation):
///
///   * an INSTANCE field takes its type from the control flow of `this.<name>`
///     assignments in the CONSTRUCTOR (`getFlowTypeInConstructor`);
///   * a STATIC field takes it from the class's `static { … }` blocks
///     (`getFlowTypeInStaticBlocks`) — which ztsc parses as `unsupported` and
///     cannot walk, so a class body holding one silences its static fields;
///   * an AMBIENT field takes it from the base class's property of the same name
///     (`getTypeOfPropertyInBaseClass`), so a `declare class D extends B` is
///     silent about a field `B` might declare.
///
/// The constructor scan asks for ANY assignment, not for a definite one
/// (TS2564's question): tsc infers from whatever the flow offers, so a write on
/// one branch is enough to make it not-`any`.
fn fieldTypeIsImplicitAny(c: *Checker, members: []const Node, member: Node, e: ast.Field, extends: Node) Error!bool {
    const name = try c.memberAtom(c.tree.nodeMainToken(member));
    if (e.flags & ast.Flags.static != 0) {
        // `static prototype` is not a declaration tsc types at all — it collides
        // with the constructor function's own `prototype` and is rejected
        // outright (TS2699), so no implicit-`any` claim is made about it.
        if (name == c.atom_prototype) return false;
        // A `static { … }` block is parsed as a plain `.block` member (see the
        // parser's note there) and its statements are not checked, so its writes
        // cannot be found — any block at all silences the class's static fields.
        for (members) |m| {
            if (m == null_node) continue;
            if (c.nodeTag(m) == .block or c.nodeTag(m) == .unsupported) return false;
        }
        return true;
    }
    if (extends != 0 and c.ambient_ctx) return false;
    const ctor = constructorWithBody(c, members);
    if (ctor == null_node) return true;
    return !assignsThisProp(c, c.tree.nodeData(ctor).rhs, name);
}

/// Any syntactic `this.<name> = …` (or `||=` / `??=`) inside `node`. A nested
/// CLASS body belongs to another `this`; a nested function's body does not run
/// at construction time for tsc's flow either, but it is deliberately counted
/// here — over-counting only suppresses a diagnostic, which is the direction a
/// brand-new check must err in.
fn assignsThisProp(c: *Checker, node: Node, name: intern.Atom) bool {
    if (node == null_node) return false;
    if (c.nodeTag(node) == .class_decl) return false;
    if (c.nodeTag(node) == .assign) {
        const d = c.tree.nodeData(node);
        if (writesThisProp(c, d.lhs, name)) return true;
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (assignsThisProp(c, child, name)) return true;
    }
    return false;
}

fn constructorWithBody(c: *Checker, members: []const Node) Node {
    for (members) |m| {
        if (m == null_node or c.nodeTag(m) != .class_method) continue;
        const md = c.tree.nodeData(m);
        if (md.rhs == 0) continue;
        const proto = c.tree.extraData(ast.FnProto, md.lhs);
        if (proto.flags & ast.Flags.static != 0) continue;
        if (c.tree.tokens.tag(c.tree.nodeMainToken(m)) != .keyword_constructor) continue;
        return m;
    }
    return null_node;
}

/// Is `node` (a call expression) an IIFE — tsc's
/// `getImmediatelyInvokedFunctionExpression`, whose body the binder there folds
/// into the *containing* control flow (`isImmediatelyInvoked` in
/// `bindContainer`)? Async and generator functions are excluded, as they are
/// there: their bodies do not run to completion at the call.
fn iifeBody(c: *Checker, node: Node) Node {
    switch (c.nodeTag(node)) {
        .call_expr, .call_expr_targs => {},
        else => return null_node,
    }
    var callee = c.callShape(node).callee;
    while (c.nodeTag(callee) == .paren_expr) callee = c.tree.nodeData(callee).lhs;
    const cd = c.tree.nodeData(callee);
    switch (c.nodeTag(callee)) {
        .arrow_fn, .function_expr => {
            const proto = c.tree.extraData(ast.FnProto, cd.lhs);
            if (proto.flags & (ast.Flags.async | ast.Flags.generator) != 0) return null_node;
            return cd.rhs;
        },
        else => return null_node,
    }
}

/// Does the constructor body contain either construct whose flow ztsc models
/// more widely than tsc — an IIFE, or a `try` with a `finally`? Asked once per
/// constructor so that `writeHiddenFromFlow`, which is a walk per PROPERTY, is
/// only ever run for the constructors that can actually need it (a class with
/// forty uninitialized fields otherwise pays forty body walks for nothing).
fn ctorHasWidenedFlow(c: *Checker, node: Node) bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        .class_decl => return false,
        .arrow_fn, .function_expr, .function_decl, .object_method => return false,
        .try_stmt => {
            if (c.tree.extraData(ast.Try, c.tree.nodeData(node).rhs).finally_block != 0) return true;
        },
        else => {},
    }
    if (iifeBody(c, node) != null_node) return true;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (ctorHasWidenedFlow(c, child)) return true;
    }
    return false;
}

/// Does the constructor body write `this.<name>` somewhere ztsc's flow graph
/// cannot carry the write to the constructor's exit? Two constructs, both of
/// which tsc models more precisely:
///
///   * an IIFE — tsc binds its body into the containing flow, so
///     `(() => { this.x = v; })()` initializes `x`; ztsc gives every
///     function-like its own flow graph, and the write is invisible from
///     outside;
///   * the `try`/`catch` blocks of a `try … finally` — tsc's `FlowReduceLabel`
///     re-runs the finally body's flow restricted to the *normal exit* edges,
///     so `try { this.x = v; } finally {}` initializes `x`; ztsc has no reduce
///     label and joins the pre-`try` edge into the statement's exit, which
///     unions the write away.
///
/// Where the graph is too wide the flow verdict is "not assigned", so both would
/// manufacture a TS2564 on code tsc accepts. Suppressing on the syntactic write
/// is the under-reporting side of both — a write inside a *conditional* IIFE
/// (or one whose `try` sits in a branch) is a report tsc makes and ztsc does
/// not, which is the accepted direction.
fn writeHiddenFromFlow(c: *Checker, node: Node, name: intern.Atom, hidden: bool) Error!bool {
    if (node == null_node) return false;
    switch (c.nodeTag(node)) {
        // A nested class's members are not this constructor's writes, and a
        // non-invoked function body never runs at construction time.
        .class_decl => return false,
        .arrow_fn, .function_expr, .function_decl, .object_method => return false,
        .try_stmt => {
            const d = c.tree.nodeData(node);
            const e = c.tree.extraData(ast.Try, d.rhs);
            const lost = hidden or e.finally_block != 0;
            if (try writeHiddenFromFlow(c, d.lhs, name, lost)) return true;
            if (try writeHiddenFromFlow(c, e.catch_clause, name, lost)) return true;
            return writeHiddenFromFlow(c, e.finally_block, name, hidden);
        },
        .assign => {
            const d = c.tree.nodeData(node);
            // The same "initializes it" predicate `flow.definiteAssignOp` uses:
            // `&&=` is deliberately absent (its skipping branch keeps
            // `undefined`), so a hidden `this.x &&= v` suppresses nothing.
            const definite = switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                .eq, .pipe_pipe_eq, .question_question_eq => true,
                else => false,
            };
            if (hidden and definite and writesThisProp(c, d.lhs, name)) return true;
            if (try writeHiddenFromFlow(c, d.lhs, name, hidden)) return true;
            return writeHiddenFromFlow(c, d.rhs, name, hidden);
        },
        else => {},
    }
    const body = iifeBody(c, node);
    if (body != null_node and try writeHiddenFromFlow(c, body, name, true)) return true;
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (try writeHiddenFromFlow(c, child, name, hidden)) return true;
    }
    return false;
}

/// Is `target` a write of `this.<name>` — either spelling (`this.name`,
/// `this["name"]`)? Used by `writeHiddenFromFlow`, which has no reference key
/// to hand and only needs the name.
fn writesThisProp(c: *Checker, target: Node, name: intern.Atom) bool {
    var n = target;
    while (c.nodeTag(n) == .paren_expr) n = c.tree.nodeData(n).lhs;
    const d = c.tree.nodeData(n);
    switch (c.nodeTag(n)) {
        .member_expr, .optional_member_expr => {
            if (c.nodeTag(d.lhs) != .this_expr) return false;
            return (c.memberAtom(d.rhs) catch return false) == name;
        },
        .index_expr, .optional_index_expr => {
            if (c.nodeTag(d.lhs) != .this_expr) return false;
            var idx = d.rhs;
            while (c.nodeTag(idx) == .paren_expr) idx = c.tree.nodeData(idx).lhs;
            // A NUMERIC key names the same member the string spelling does —
            // tsc's `getAccessedPropertyName` renders it with
            // `isNumericLiteralName`, so `this[0] = v` initializes the member
            // declared `0;` (`classPropInitializationInferenceWithElementAccess`).
            if (c.nodeTag(idx) == .number_literal) {
                var buf: [24]u8 = undefined;
                const v = c.numberTokenValue(c.tree.nodeMainToken(idx));
                if (v != @floor(v) or @abs(v) >= 9007199254740992.0) return false;
                const txt = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch return false;
                return (c.internText(txt) catch return false) == name;
            }
            if (c.nodeTag(idx) != .string_literal) return false;
            return (c.memberAtom(c.tree.nodeMainToken(idx)) catch return false) == name;
        },
        else => return false,
    }
}

/// TS2564 — tsc's `checkPropertyInitialization`, gated on
/// `strictNullChecks && strictPropertyInitialization` (both implied by
/// `strict`, which ztsc always runs) and on the class not being ambient.
///
/// For each candidate: with no constructor at all nothing can have been
/// assigned, so it reports; otherwise it asks the flow graph whether every path
/// out of the constructor wrote `this.<name>` — `thisPropUnassigned` at the
/// constructor's return join, tsc's `isPropertyInitializedInConstructor` over
/// `constructor.returnFlowNode`. Reported at the property NAME (tsc's
/// `member.name`), which `memberNameSpan` answers for every spelling — a
/// modifier list (`private readonly x: T`) does not move the column, and a
/// LITERAL computed name is blamed and rendered as the whole `["a"]`, which is
/// what `declarationNameToString` prints for a `ComputedPropertyName`.
fn checkPropertyInit(c: *Checker, ctor: Node, widened: bool, cands: []const InitCand) Error!void {
    for (cands) |cand| {
        const tok = c.tree.nodeMainToken(cand.member);
        const name = try c.memberAtom(tok);
        if (try propAssignedInCtor(c, ctor, widened, name, cand.ty)) continue;
        if (try numericKeyAssignedInCtor(c, ctor, cand, name)) continue;
        const span = memberNameSpan(c, cand.member, cand.flags);
        try c.diagFmt(2564, span, "Property '{s}' has no initializer and is not definitely assigned in the constructor.", .{c.src[span.start..span.end]});
    }
}

/// Does the constructor write `this[<n>] = …` for a NUMERICALLY named member?
///
/// tsc's `getAccessedPropertyName` renders a numeric-literal element access as
/// the property NAME (`isNumericLiteralName`), so `this[1] = v` initializes the
/// member declared `[1]: string`. ztsc's reference keys deliberately do not:
/// `constIndexOf` turns a constant numeric index into an INDEX path link, which
/// is what makes tuple-element narrowing work, and that link never matches the
/// member-name link the definite-assignment query is spelled with.
///
/// Rather than blur that distinction for every reference, the one check that
/// needs the other reading asks the syntactic question directly, on the rare
/// path where the flow graph already answered "unassigned" for a numerically
/// named member. `writeHiddenFromFlow` with `hidden` set from the top is that
/// scan: it accepts any definite `this[<n>] = …` write anywhere in the body
/// (`writesThisProp` does the numeric-name rendering), which under-reports
/// exactly where a conditional write leaves a path uninitialized.
fn numericKeyAssignedInCtor(c: *Checker, ctor: Node, cand: InitCand, name: intern.Atom) Error!bool {
    if (ctor == null_node) return false;
    if (cand.flags & ast.Flags.computed_lit == 0) return false;
    if (!literals.isNumericName(c.atomText(name))) return false;
    return writeHiddenFromFlow(c, c.tree.nodeData(ctor).rhs, name, true);
}

/// TS2564 for a COMPUTED-name property (`[Symbol.unscopables]: number`).
///
/// ztsc keys such a member by a placeholder atom that no `this[k] = v` write
/// reproduces, so `propAssignedInCtor`'s flow query cannot see a write and
/// would invent the diagnostic. The question it CAN answer is the syntactic,
/// conservative one: a computed member is only ever written through
/// `this[…] = …`, so a constructor that performs no such write at all — and
/// with no constructor there is nothing at all — initializes none of them, and
/// every candidate reports. One such write anywhere in the body gives up on
/// the whole class, which is the under-reporting direction.
///
/// Anchored and named like tsc's, at `member.name`: the whole `[…]` including
/// its brackets, which is what `declarationNameToString` renders for a
/// `ComputedPropertyName`.
fn checkComputedPropertyInit(c: *Checker, ctor: Node, cands: []const Node) Error!void {
    if (ctor != null_node and writesComputedThisProp(c, c.tree.nodeData(ctor).rhs)) return;
    for (cands) |member| {
        const span = computedNameSpan(c, member) orelse continue;
        try c.diagFmt(2564, span, "Property '{s}' has no initializer and is not definitely assigned in the constructor.", .{
            c.src[span.start..span.end],
        });
    }
}

/// The span of a member's computed NAME — tsc's `member.name`, which is the
/// whole `[…]`, both brackets included, and the text `declarationNameToString`
/// renders for it.
///
/// Two shapes reach here. The ordinary one keeps a `.computed_name` node whose
/// span runs from the `[` to the end of the key expression. A WELL-KNOWN
/// symbol name (`[Symbol.iterator]`) keeps none — the parser folds its four
/// tokens `[ Symbol . <name>` into one synthetic atom and discards the key —
/// so the `[` is found at its fixed offset from the member's main token, which
/// for that shape is the `<name>`. Neither span covers the closing `]`, which
/// is scanned for from just past the key.
fn computedNameSpan(c: *Checker, member: Node) ?source.Span {
    var start: u32 = undefined;
    var after: u32 = undefined;
    if (c.tree.computedKey(member)) |k| {
        if (c.nodeTag(k) != .computed_name) return null;
        const s = c.nodeSpan(k);
        start = s.start;
        after = s.end;
    } else {
        const tok = c.tree.nodeMainToken(member);
        if (tok < 3 or c.tree.tokens.tag(tok - 3) != .l_bracket) return null;
        start = c.tree.tokens.start(tok - 3);
        after = c.tokSpan(tok).end;
    }
    var e = after;
    while (e < c.src.len and c.src[e] != ']') e += 1;
    return .{ .start = start, .end = if (e < c.src.len) e + 1 else after };
}

/// Does `node` contain ANY `this[…] = …` write? Nested function bodies count:
/// a constructor may call them, and this walk exists to be conservative about
/// a key it cannot evaluate.
fn writesComputedThisProp(c: *Checker, node: Node) bool {
    if (node == null_node) return false;
    if (c.nodeTag(node) == .assign) {
        var t = c.tree.nodeData(node).lhs;
        while (c.nodeTag(t) == .paren_expr) t = c.tree.nodeData(t).lhs;
        switch (c.nodeTag(t)) {
            .index_expr, .optional_index_expr => {
                if (c.nodeTag(c.tree.nodeData(t).lhs) == .this_expr) return true;
            },
            else => {},
        }
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| {
        if (writesComputedThisProp(c, child)) return true;
    }
    return false;
}

/// tsc's `isPropertyInitializedInConstructor`: does every path out of `ctor`
/// write `this.<name>`? With no constructor at all, nothing was assigned.
///
/// Shared by the two checks that ask it — TS2564 above and `heritage.zig`'s
/// TS2612 — because they must agree: a property the flow graph calls
/// initialized is exempt from both, and a divergence would report one class
/// of property twice and another not at all.
///
/// `widened` is `ctorHasWidenedFlow(body)`, hoisted by the caller so the
/// syntactic scan runs once per class rather than once per property.
pub fn propAssignedInCtor(c: *Checker, ctor: Node, widened: bool, name: intern.Atom, declared: TypeId) Error!bool {
    if (ctor == null_node) return false;
    const ret_flow = c.bind.flowAt(ctor) orelse return false;
    if (!try c.thisPropUnassigned(ret_flow, name, declared)) return true;
    // Writes ztsc's flow graph cannot see (an IIFE body, a `try` under a
    // `finally`) still initialize the property; see `writeHiddenFromFlow`.
    return widened and try writeHiddenFromFlow(c, c.tree.nodeData(ctor).rhs, name, false);
}

/// TS2565 — the `assumeUninitialized` half of tsc's
/// `getFlowTypeOfAccessExpression`: a `this.<name>` READ inside the constructor
/// of the class that declares `<name>`, reached on a path that has not written
/// it yet, is "used before being assigned".
///
/// tsc reaches it from the property-access checker, gated on
/// `getControlFlowContainer(node) === the constructor` and on the declaration
/// being a property with no `!` and no initializer — i.e. exactly the TS2564
/// candidate set (`abstract` differs, but an abstract member read in a
/// constructor is TS2715 there, not this). ztsc walks the constructor body for
/// those reads instead, which keeps the query off the property-access hot path:
/// the answer is a diagnostic only — the *type* of the read is the declared
/// type either way, which is already what ztsc's ordinary walk returns.
///
/// Writes are not reads: tsc's function returns before this check when the
/// access is a DEFINITE assignment target, so `this.x = v` is silent while the
/// read a compound `this.x += v` / `this.x++` performs is not.
fn checkPropertyUseBeforeAssigned(c: *Checker, body: Node, widened: bool, cands: []const InitCand) Error!void {
    if (!widened) return useBeforeAssignedWalk(c, body, cands, false);
    // A write ztsc's flow graph cannot carry (`writeHiddenFromFlow`) hides
    // itself from a read's query exactly as it does from the exit's, so the same
    // properties are dropped here.
    var live: std.ArrayList(InitCand) = .empty;
    defer live.deinit(c.scratch());
    for (cands) |cand| {
        const name = try c.memberAtom(c.tree.nodeMainToken(cand.member));
        if (try writeHiddenFromFlow(c, body, name, false)) continue;
        try live.append(c.scratch(), cand);
    }
    if (live.items.len == 0) return;
    try useBeforeAssignedWalk(c, body, live.items, false);
}

/// Walk one node of a constructor body looking for `this.<candidate>` reads.
/// `is_target` marks a subtree that is the left-hand side of a definite
/// assignment: the access at its root is a write (silent), but everything
/// *inside* it is still an ordinary read (`this.a.b = v` reads `this.a`), and a
/// destructuring pattern's element targets are writes in turn.
fn useBeforeAssignedWalk(c: *Checker, node: Node, cands: []const InitCand, is_target: bool) Error!void {
    if (node == null_node) return;
    switch (c.nodeTag(node)) {
        // A nested function or class is a different control-flow container, so
        // a `this.x` there is not this constructor's business (tsc's
        // `getControlFlowContainer`).
        .arrow_fn, .function_expr, .function_decl, .object_method, .class_decl => return,
        .member_expr, .optional_member_expr => {
            const d = c.tree.nodeData(node);
            if (!is_target and c.nodeTag(d.lhs) == .this_expr) {
                const name = try c.memberAtom(d.rhs);
                for (cands) |cand| {
                    if ((try c.memberAtom(c.tree.nodeMainToken(cand.member))) != name) continue;
                    if (c.bind.flowAt(node)) |flow| {
                        if (try c.thisPropUnassigned(flow, name, cand.ty)) {
                            try c.diagFmt(2565, c.tokSpan(d.rhs), "Property '{s}' is used before being assigned.", .{c.tokenText(d.rhs)});
                        }
                    }
                    break;
                }
            }
            return useBeforeAssignedWalk(c, d.lhs, cands, false);
        },
        .assign => {
            const d = c.tree.nodeData(node);
            // Here the predicate IS tsc's `getAssignmentTargetKind`, which puts
            // all three logical assignments in `Definite` and so returns from
            // `getFlowTypeOfAccessExpression` before the TS2565 check: the read
            // `this.x &&= v` performs is silent, even though the write does not
            // initialize `x` (see `flow.definiteAssignOp`).
            const definite = switch (c.tree.tokens.tag(c.tree.nodeMainToken(node))) {
                .eq, .pipe_pipe_eq, .amp_amp_eq, .question_question_eq => true,
                else => false,
            };
            try useBeforeAssignedWalk(c, d.lhs, cands, definite);
            return useBeforeAssignedWalk(c, d.rhs, cands, false);
        },
        // Inside a destructuring target the element positions stay targets;
        // their defaults (the `.assign`/`binding_default` right side) do not,
        // which the arms above already separate.
        .object_literal, .array_literal, .object_property, .object_shorthand, .spread_element, .paren_expr => {
            if (is_target) {
                var it = c.tree.childIterator(node);
                while (it.next()) |child| try useBeforeAssignedWalk(c, child, cands, true);
                return;
            }
        },
        else => {},
    }
    var it = c.tree.childIterator(node);
    while (it.next()) |child| try useBeforeAssignedWalk(c, child, cands, false);
}

/// Does a class heritage expression's type FAIL tsc's `isConstructorType`?
/// `getBaseConstructorTypeOfClass` accepts `any` and the null widening type
/// outright and otherwise demands a construct signature, reporting TS2507 at
/// the expression when there is none — which is what `class B extends A` says
/// where a local `var A = 1` shadows the class
/// (`classExtendsShadowedConstructorFunction`,
/// `classExtendsClauseClassNotReferringConstructor`), what `extends Alpha.x`
/// says for a namespace's exported `number`, and what `extends Greeter` says
/// for an `import … = require(…)` module OBJECT rather than the class inside
/// it (`importAsBaseClass`).
///
/// Kinds are ALLOW-listed rather than denied: `false` is silence, so anything
/// ztsc models loosely — a `ref` that did not resolve, a type parameter (whose
/// mixin-constraint arm of `isConstructorType` is not modelled here), an
/// intersection (which is what a mixin application produces), a conditional —
/// keeps its existing under-report instead of risking a false TS2507 on a
/// legal base class.
fn heritageNotConstructor(c: *Checker, t: TypeId) Error!bool {
    const r = try c.resolveStructural(t);
    return switch (c.ts.kind(r)) {
        // Primitives, `undefined` and literals: nothing that could carry a
        // construct signature. `null` is tsc's explicit exemption
        // (`baseConstructorType !== nullWideningType`), and `any`/`err`/`never`
        // are the silent ones.
        .unknown,
        .void,
        .undefined,
        .string,
        .number,
        .boolean,
        .bigint,
        .symbol,
        .object_keyword,
        .bool_true,
        .bool_false,
        .string_literal,
        .number_literal,
        .number_literal_fresh,
        .bigint_literal,
        .enum_type,
        .unique_symbol,
        .array,
        .tuple,
        => true,
        // A structural object — a namespace/module value, `{}`, an object
        // literal — is a base class only when it declares a construct
        // signature. A bare `.function` is a CALL signature and never one, so
        // `function foo() {}` + `class C extends foo` is TS2507 too.
        .object => c.ts.objectConstructSigCount(r) == 0,
        .function => true,
        else => false,
    };
}

pub fn checkClass(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.ClassData, d.lhs);
    const saved_scope = c.cur_scope;
    const saved_this = c.this_type;
    defer {
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
    }
    if (try c.scopeOf(node)) |s| c.cur_scope = s;

    // Declaration or expression, named or not — see `classes.classSymbolOf`.
    const class_sym = try c.classSymbolOf(node, saved_scope);

    // Instance type for `this` (generic: tp refs as args).
    var this_t: TypeId = types.any_type;
    if (class_sym != binder.no_symbol) {
        var tps: std.ArrayList(TypeParamInfo) = .empty;
        defer tps.deinit(c.scratch());
        try c.typeParamsOf(class_sym, &tps);
        var args = try c.scratch().alloc(TypeId, tps.items.len);
        for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
        this_t = try c.ts.makeRef(class_sym, args);
        // Eagerly expand so member diagnostics (7006, bad annotations)
        // fire even for unused classes.
        _ = try c.resolveStructural(this_t);
        _ = try c.classStaticType(class_sym);
        try evalTypeParamDecls(c, class_sym);
        // A class merged with a same-named `interface` (or reopened in another
        // file) is the same TS2428 check as the interface arm's.
        try c.checkTypeParamListsIdentical(mergedOrSelf(c, class_sym), data.name_token);
        // …and a class merged with a same-named `namespace` shares ONE export
        // table with it, where a static and an exported member of one name clash.
        try c.checkCloduleMemberDups(class_sym);
        // …and a member declared twice with two different types is TS2717 at
        // the later declaration.
        try c.checkSubsequentMemberDecls(class_sym, node);
        // …and a PRIVATE name shared by the static and the instance side is
        // TS2804 at every one of its declarations.
        try c.checkPrivateNameStaticDups(class_sym, node);
    }

    // Class-position decorators (`@deco class C {}`): evaluated in the
    // scope surrounding the class, with the enclosing `this`. Snapshot and
    // clear the pending set first so a nested decorated class inside a
    // member body cannot re-consume them.
    if (c.pending_class_decos.items.len > 0) {
        const decos = try c.scratch().dupe(Node, c.pending_class_decos.items);
        c.pending_class_decos.clearRetainingCapacity();
        const saved_ds = c.cur_scope;
        c.cur_scope = saved_scope;
        c.this_type = saved_this;
        const class_val: TypeId = if (class_sym != binder.no_symbol)
            try c.ts.makeClassValue(class_sym)
        else
            types.any_type;
        for (decos) |deco| {
            try decorators.checkClassDecorator(c, deco, class_val);
        }
        c.cur_scope = saved_ds;
    }

    // extends: base must be a class (checked in baseClassRef); type
    // args arity checked there too.
    if (class_sym != binder.no_symbol and data.extends != 0) {
        _ = try c.baseClassRef(class_sym);
        const hd = c.tree.nodeData(data.extends);
        // An AMBIENT class's `extends` clause is emitted nowhere, so tsc does
        // not treat it as a value reference: `import type { Base }` followed by
        // `declare class D extends Base<T>` is legal, and a `.d.ts` is ambient
        // throughout. Checking the heritage expression as a value there
        // reported a TS1361 tsc never issues — expo-modules-core's
        // `SharedObject.d.ts` (`import type { EventEmitter }` +
        // `declare class SharedObject … extends EventEmitter<TEventsMap>`) is
        // exactly that shape. A NON-ambient `class D extends Base` still checks
        // the expression, and still reports TS1361, because that clause is real
        // emitted code.
        if (!(c.ambient_ctx or data.flags & ast.Flags.declare != 0)) {
            const base_t = try c.checkExprCached(hd.lhs, types.no_type);
            if (try heritageNotConstructor(c, base_t)) {
                try c.diagFmt(2507, c.nodeSpan(hd.lhs), "Type '{s}' is not a constructor function type.", .{
                    try c.typeToString(base_t),
                });
            }
        }
        // tsc's order: the instance side first, and the static side only when
        // it passed (`checkClassLikeDeclaration`'s "Report static side error
        // only when instance type is assignable").
        const class_members = c.tree.extraRange(data.members_start, data.members_end);
        if (try checkInstanceSideExtends(c, class_sym, class_members, this_t, data.name_token)) {
            try checkStaticSideExtends(c, class_sym, data.name_token);
        }
    }

    // implements clauses: instance assignable to each interface. Skipped
    // entirely when the class inherits from a base ztsc could not resolve —
    // the instance type is then missing whatever that base contributed, and
    // the verdict would be about ztsc's gap, not the code.
    if (class_sym != binder.no_symbol and !try c.hasUnresolvedBase(class_sym)) {
        for (c.tree.extraRange(data.impl_start, data.impl_end)) |h| {
            if (h == null_node or c.nodeTag(h) != .heritage) continue;
            const hd = c.tree.nodeData(h);
            var targs: std.ArrayList(TypeId) = .empty;
            defer targs.deinit(c.scratch());
            if (hd.rhs != 0) {
                const rr = c.tree.extraData(ast.SubRange, hd.rhs);
                for (c.tree.extraRange(rr.start, rr.end)) |an| {
                    if (an != null_node) try targs.append(c.scratch(), try c.typeFromTypeNode(an));
                }
            }
            const iface = try c.typeFromTypeName(hd.lhs, targs.items);
            if (iface != types.error_type and iface != types.any_type) {
                if (!try c.isAssignable(this_t, iface)) {
                    // Same shape as the `extends` side: the per-member pass
                    // blames the offending member (TS2416), and the broad
                    // class-level diagnostic fires only when none did.
                    const members = c.tree.extraRange(data.members_start, data.members_end);
                    if (!try issueMemberSpecificError(c, members, this_t, iface) and data.name_token != 0) {
                        // tsc anchors the broad diagnostic at the class NAME
                        // (`issueMemberSpecificError`'s `node.name || node`),
                        // not at the heritage reference that failed — two
                        // failing `implements` clauses report twice on the
                        // same name. Which diagnostic it is depends on what
                        // the clause NAMES: tsc picks
                        // `Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1…`
                        // when the target symbol is a class, and only
                        // otherwise the plain "implements interface" form.
                        if (implementsTargetIsClass(c, iface)) {
                            try c.diagFmt(2720, c.tokSpan(data.name_token), "Class '{s}' incorrectly implements class '{s}'. Did you mean to extend '{s}' and inherit its members as a subclass?{s}", .{
                                c.symbolName(class_sym),
                                try c.typeToString(iface),
                                try c.typeToString(iface),
                                try elaborate.chainText(c, this_t, iface),
                            });
                        } else {
                            try c.diagFmt(2420, c.tokSpan(data.name_token), "Class '{s}' incorrectly implements interface '{s}'.{s}", .{
                                c.symbolName(class_sym),
                                try c.typeToString(iface),
                                try elaborate.chainText(c, this_t, iface),
                            });
                        }
                    }
                }
            }
        }
    }

    // A concrete class must implement inherited abstract members.
    if (class_sym != binder.no_symbol) try c.checkAbstractImplementation(class_sym, node);

    // `strictPropertyInitialization` (implied by `strict`, and ztsc runs no
    // other mode) checks every instance property for a definite assignment.
    // tsc skips the whole check inside an AMBIENT class — a `declare class`, or
    // any class in a `.d.ts` or `declare namespace` body (`node.flags &
    // NodeFlags.Ambient`) — where there is no constructor body to analyze.
    // The candidates are collected as the members are checked and judged after
    // the loop, so the constructor's body is already checked when its flow is
    // queried. Foreign files are skipped for the same reason
    // `checkFunctionBody` skips them: `seal` drops their diagnostics, and their
    // bodies are never walked, so the query would have nothing to read.
    const check_prop_init = !(c.ambient_ctx or data.flags & ast.Flags.declare != 0) and
        c.owned_mask[c.cur_file];
    var init_cands: std.ArrayList(InitCand) = .empty;
    defer init_cands.deinit(c.scratch());
    var computed_init_cands: std.ArrayList(Node) = .empty;
    defer computed_init_cands.deinit(c.scratch());

    // Members.
    const members = c.tree.extraRange(data.members_start, data.members_end);
    // The class's own name, for the static-initialization-order rule: `C.x`
    // inside `class C` reaches the class being defined (`static_block.zig`).
    const class_name = if (data.name_token != 0) c.tokenText(data.name_token) else "";
    // A `get`/`set` pair whose getter is less accessible than its setter
    // (TS2808) — a property of the declarations alone, so it runs before any
    // member's type is resolved.
    try accessibility.checkAccessorVisibility(c, members);
    // The members' computed NAMES (TS2304 in a key, TS2464 for a key that
    // cannot name a property). Driven from here, like the two calls around it,
    // so it runs once, in the file that owns the class.
    // (wave-10 A: one flagged call into `computed_key.zig`.)
    try computed_key.checkMemberNames(c, members, if (c.ambient_ctx or data.flags & ast.Flags.declare != 0)
        .ambient_class_body
    else
        .class_body, c.tree.extraRange(data.tp_start, data.tp_end));
    // The same pairing, for the other question the two halves answer together:
    // whose annotation supplies the property's type (TS7032/TS7033).
    try implicit_any.reportAccessorImplicitAny(c, members);
    // Each member is its own super-call container: a field initializer of a
    // class written INSIDE a constructor must not inherit that constructor's
    // (`checkFunctionBody` re-establishes it for the constructor itself).
    const saved_in_ctor = c.in_ctor_body;
    c.in_ctor_body = false;
    defer c.in_ctor_body = saved_in_ctor;
    for (members, 0..) |member, mi| {
        if (member == null_node) continue;
        const md = c.tree.nodeData(member);
        switch (c.nodeTag(member)) {
            .class_field => {
                const e = c.tree.extraData(ast.Field, md.lhs);
                const is_static = e.flags & ast.Flags.static != 0;
                c.this_type = if (is_static and class_sym != binder.no_symbol)
                    try c.ts.makeClassValue(class_sym)
                else
                    this_t;
                var ann: TypeId = types.no_type;
                if (e.type_ann != 0) {
                    const ok = is_static and e.flags & ast.Flags.readonly != 0;
                    ann = try c.annTypeMaybeUnique(e.type_ann, ok, 1331, c.tokSpan(c.tree.nodeMainToken(member)));
                } else if (e.init == 0 and try fieldTypeIsImplicitAny(c, members, member, e, data.extends)) {
                    // Neither annotated nor initialized, and nothing else
                    // supplies a type: the field is `any` (TS7008). Reported
                    // from the declaration walk rather than from
                    // `computeMemberType`, so it fires exactly once per
                    // declaration and for an unreferenced class too.
                    try implicit_any.reportMemberImplicitAny(c, c.tree.nodeMainToken(member), e.flags);
                }
                if (check_prop_init and initCandidate(c, member, e, ann)) {
                    // A computed name has no atom the flow graph (or TS2565's
                    // read walk) can key on — see `checkComputedPropertyInit`.
                    if (e.flags & ast.Flags.computed != 0)
                        try computed_init_cands.append(c.scratch(), member)
                    else
                        try init_cands.append(c.scratch(), .{ .member = member, .ty = ann, .flags = e.flags });
                }
                // A `unique symbol` static-readonly field, like a const,
                // takes only a fresh `Symbol()` initializer without TS2322.
                if (e.type_ann != 0 and c.nodeTag(e.type_ann) == .unique_symbol_type and e.init != 0 and c.isFreshSymbolCall(e.init)) {
                    _ = try c.checkExprCached(e.init, ann);
                    continue;
                }
                if (e.init != 0) {
                    // TS2729: the initializer runs while the class is still
                    // being set up, so what it may read is a question about
                    // source order (`init_order.zig`). A static block runs in
                    // the same window and shares the rule.
                    try init_order.checkSelfRefs(c, members, member, e.init, class_name, if (is_static) .static else .instance);
                    // See `instance_field_init_depth`: an instance field's
                    // initializer runs at construction time, so a forward
                    // reference in it is not a TDZ use.
                    if (!is_static) c.instance_field_init_depth += 1;
                    defer if (!is_static) {
                        c.instance_field_init_depth -= 1;
                    };
                    // …and the flow-container half, which the static case
                    // shares (see `field_init_depth`).
                    c.field_init_depth += 1;
                    defer c.field_init_depth -= 1;
                    const it = try c.checkExprCached(e.init, ann);
                    if (ann != types.no_type and ann != types.error_type) {
                        _ = try c.checkAssignable(it, ann, e.init, c.tokSpan(c.tree.nodeMainToken(member)));
                    }
                }
            },
            .class_method => {
                const proto = c.tree.extraData(ast.FnProto, md.lhs);
                const is_static = proto.flags & ast.Flags.static != 0;
                const is_abstract = proto.flags & ast.Flags.abstract != 0;
                // Where `abstract` may SIT is the parser's
                // `modifier_order.zig` (TS1242/TS1244/TS1253, blamed on the
                // modifier). What is left here is the rule about the member's
                // BODY, which tsc words for a MethodDeclaration only: an
                // `abstract constructor() {}` is the TS1242 alone.
                if (is_abstract and md.rhs != 0 and !c.isCtorMember(member, proto.flags)) {
                    try c.diagFmt(1245, c.tokSpan(c.tree.nodeMainToken(member)), "Method '{s}' cannot have an implementation because it is marked abstract.", .{c.tokenText(c.tree.nodeMainToken(member))});
                }
                if (c.isCtorMember(member, proto.flags)) try checkCtorParamPropertyPatterns(c, proto);
                c.this_type = if (is_static and class_sym != binder.no_symbol)
                    try c.ts.makeClassValue(class_sym)
                else
                    this_t;
                const sig = try c.signatureOfProto(member, md.lhs, true, true);
                if (md.rhs != 0) {
                    const is_ctor = c.isCtorMember(member, proto.flags);
                    // TS2394 for a CONSTRUCTOR overload set. Same rule and
                    // same driver as `checkOverloadSet` for a function
                    // declaration — run it from the IMPLEMENTATION so it
                    // fires once — but the declarations are siblings in the
                    // class body rather than a symbol's declaration list: a
                    // constructor has no name to look up.
                    if (is_ctor) {
                        try checkCtorOverloadSet(c, members, member);
                        try checkDerivedCtorSuperCall(c, data.extends, member, md.rhs);
                    }
                    const saved_ctor = c.ctor_class_sym;
                    if (is_ctor) c.ctor_class_sym = class_sym;
                    defer c.ctor_class_sym = saved_ctor;
                    try c.checkFunctionBody(member, md.lhs, md.rhs, sig, types.no_type);
                }
            },
            .decorator => {
                // A member decorator expression is evaluated in the scope
                // surrounding the class (at class-definition time), so its
                // `this` is the enclosing `this`, not the instance — and so is
                // its `super` CONTAINER (`Checker.in_decorator`). The SCOPE is
                // deliberately left alone: tsc resolves a decorator's names in
                // the class's own scope, and moving the walk out convicted
                // every decorator function of TS2454 in
                // `decoratorUsedBeforeDeclaration`.
                const saved_deco = c.in_decorator;
                defer c.in_decorator = saved_deco;
                c.in_decorator = true;
                c.this_type = saved_this;
                // The decorated member is the next non-decorator member. It
                // is needed BEFORE the decorator expression is checked: the
                // expression's contextual type is the call shape the runtime
                // will invoke it with, which is built from the member.
                var target: Node = null_node;
                var k = mi + 1;
                while (k < members.len) : (k += 1) {
                    if (members[k] != null_node and c.nodeTag(members[k]) != .decorator) {
                        target = members[k];
                        break;
                    }
                }
                try decorators.checkMemberDecorator(c, member, target, this_t, class_sym);
            },
            // `static { … }` — the parser's only `.block` class member. The
            // block's statements run with `this` = the static side, in the
            // block's own scope (wave-7 A: `static_block.zig`).
            .block => try static_block.checkStaticBlock(c, members, member, class_sym, class_name, this_t),
            else => {},
        }
    }

    // Both halves of the class must agree with whatever index signature they
    // carry — tsc's two `checkIndexConstraints` calls, which run after the
    // member walk and before `checkPropertyInitialization`.
    if (class_sym != binder.no_symbol) {
        try index_constraints.checkClassIndexConstraints(
            c,
            node,
            class_sym,
            this_t,
            try c.classStaticType(class_sym),
        );
    }

    // Both remaining checks read the constructor's FLOW, so they run after the
    // member walk has checked its body. `check_prop_init` is exactly "not
    // ambient, and this file is ours to report on" — the two conditions TS2612
    // needs as well, for the same two reasons (an ambient member emits no
    // field; a foreign file's flow is never built).
    const wants_2612 = class_sym != binder.no_symbol and check_prop_init and data.extends != 0;
    if (init_cands.items.len != 0 or computed_init_cands.items.len != 0 or wants_2612) {
        c.this_type = this_t;
        const ctor = constructorWithBody(c, members);
        const ctor_body = if (ctor == null_node) null_node else c.tree.nodeData(ctor).rhs;
        // One syntactic scan of the constructor body, shared by both checks.
        const widened = ctorHasWidenedFlow(c, ctor_body);
        if (init_cands.items.len != 0) {
            try checkPropertyInit(c, ctor, widened, init_cands.items);
            if (ctor != null_node) try checkPropertyUseBeforeAssigned(c, ctor_body, widened, init_cands.items);
        }
        if (computed_init_cands.items.len != 0) {
            try checkComputedPropertyInit(c, ctor, computed_init_cands.items);
        }
        if (wants_2612) {
            try heritage.checkBasePropertyOverwrites(c, class_sym, this_t, members, ctor, widened);
        }
    }
}

// Decorator checking lives in `decorators.zig`; the class walk above drives it
// through its two entry points (`checkClassDecorator`, `checkMemberDecorator`)
// and needs no re-export. `globalSymNamed` is the one helper other files reach
// for, and `Checker`'s method alias names this file.
pub const globalSymNamed = decorators.globalSymNamed;

/// The merged-range id a real global symbol folds into, or the symbol itself.
/// A cross-file merged class/interface must be asked about ALL its blocks, and
/// only the merged id knows them (`toGlobal` hands back this file's constituent).
fn mergedOrSelf(c: *Checker, sym: SymbolId) SymbolId {
    return c.prog.mergedOf(sym) orelse sym;
}

fn checkInterfaceDecl(c: *Checker, node: Node) Error!void {
    // Eagerly expand so member-type diagnostics (2304 in bodies, 7006 in
    // method signatures) fire even for unused interfaces.
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.InterfaceData, d.lhs);
    const saved = c.cur_scope;
    defer c.cur_scope = saved;
    // The members' computed NAMES, before the name guard, because a nameless
    // interface's members are still written down.
    // (wave-10 A: one flagged call into `computed_key.zig`.)
    //
    // Checked in the interface's OWN scope — the block's type-parameter scope,
    // which is where the binder bound the key expressions. tsc resolves a
    // computed key in its ordinary lexical scope, and an interface's type
    // parameters are part of it: `interface I<T> { [foo<T>()](): void }` finds
    // `T` and reports only that finding it there is illegal (TS2467). Running
    // in the ENCLOSING scope instead left `T` unresolved and added a TS2304 the
    // oracle does not have (`computedPropertyNames35_ES5`/`_ES6`).
    if (try c.scopeOf(node)) |s| c.cur_scope = s;
    try computed_key.checkMemberNames(
        c,
        c.tree.extraRange(data.members_start, data.members_end),
        .type_space,
        c.tree.extraRange(data.tp_start, data.tp_end),
    );
    c.cur_scope = saved;
    if (data.name_token == 0) return;
    const a = try c.atomOfToken(data.name_token);
    if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
        if (c.bind.symbol_flags[sym].interface) {
            _ = try c.interfaceGeneric(c.toGlobal(sym));
            try evalTypeParamDecls(c, c.toGlobal(sym));
            try c.checkTypeParamListsIdentical(mergedOrSelf(c, c.toGlobal(sym)), data.name_token);
            try c.checkSubsequentMemberDecls(c.toGlobal(sym), node);
            try heritage.checkInterfaceExtends(c, c.toGlobal(sym), node, data.name_token);
            try index_constraints.checkInterfaceIndexConstraints(c, c.toGlobal(sym), node, data.name_token);
        }
    }
}

fn checkTypeAliasDecl(c: *Checker, node: Node) Error!void {
    const d = c.tree.nodeData(node);
    const data = c.tree.extraData(ast.TypeAlias, d.lhs);
    if (data.name_token == 0) return;
    const a = try c.atomOfToken(data.name_token);
    if (c.bind.lookupInScope(c.cur_scope, a)) |sym| {
        if (c.bind.symbol_flags[sym].type_alias) {
            _ = try c.aliasGeneric(c.toGlobal(sym));
            try evalTypeParamDecls(c, c.toGlobal(sym));
        }
    }
}

/// Eagerly evaluate type-parameter constraint/default annotations of a
/// generic declaration so their diagnostics fire during the owner's
/// file walk (partition-independent output; lazy paths only reach them
/// on instantiation). The declaration-site variance check (TS2636) rides
/// along here: its callers — class, interface and type alias — are exactly
/// the three declaration forms that HAVE declaration-site variance, and it
/// is the same "check what the type parameter list declares" pass.
fn evalTypeParamDecls(c: *Checker, sym: SymbolId) Error!void {
    var tps: std.ArrayList(TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(sym, &tps);
    for (tps.items) |tp| {
        // The constraint/default nodes belong to the *type parameter's*
        // declaring file, which for a merged interface need not be the
        // merged symbol's representative file (see `fixTypeArgs`).
        const saved = c.enterSymFile(tp.sym);
        defer c.restoreCtx(saved);
        c.cur_scope = c.symScope(tp.sym);
        if (tp.constraint != 0) _ = try c.typeFromTypeNode(tp.constraint);
        if (tp.default != 0) _ = try c.typeFromTypeNode(tp.default);
    }
    try c.checkVarianceAnnotations(sym);
}
