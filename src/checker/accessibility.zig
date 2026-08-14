//! `private` / `protected` enforcement at property-ACCESS sites — tsc's
//! `checkPropertyAccessibility`.
//!
//! The rules, verbatim from `checker.ts`:
//!
//!   * `private`: legal only lexically INSIDE the class that declares the
//!     member (`isNodeWithinClass`). Otherwise TS2341.
//!   * `protected`: legal only inside the declaring class or a class derived
//!     from it (`forEachEnclosingClass` + `isClassDerivedFromDeclaringClasses`).
//!     Otherwise TS2445. An INSTANCE member has a second rule on top: the
//!     receiver must be an instance of that enclosing class, not merely of the
//!     declaring one (`hasBaseType`), or it is TS2446 — which is what stops one
//!     subclass from reading a sibling subclass's protected state.
//!
//! WHICH declaration supplies the modifier is a function of the access
//! DIRECTION (`getDeclarationModifierFlagsFromSymbol(prop, isWrite)`): a write
//! reads the `set` accessor's modifiers when the symbol has one, a read the
//! `get` accessor's, and anything else the sole declaration's. A divergent
//! accessor pair (`get x()` public, `private set x(v)`) is therefore readable
//! and not writable — see `divergentAccessorsVisibility1`.
//!
//! COST. Every caller screens on `prop_flag_non_public`, already loaded on the
//! `Prop` the lookup returned, so a program with no non-public member pays one
//! predictable-false branch per property access and nothing else. Only once
//! that bit is set does anything here run, and then it is syntax only: no type
//! is resolved, no member table is built.
//!
//! ztsc carries no parent pointers, so `isNodeWithinClass` is answered through
//! the SCOPE chain instead of the node chain: the binder gives every class body
//! a `.class` scope, and `c.cur_scope` at an access site is that scope's
//! descendant exactly when the access is lexically inside the class.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Atom = intern.Atom;
const Node = ast.Node;
const TokenIndex = ast.TokenIndex;
const ScopeId = binder.ScopeId;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// tsc's `ModifierFlags.AccessibilityModifier`, as the ordered lattice the
/// accessor-pair check (TS2808) compares on: `public` > `protected` > `private`.
pub const Access = enum(u8) {
    public = 0,
    protected = 1,
    private = 2,

    fn of(flags: u32) Access {
        if (flags & ast.Flags.private != 0) return .private;
        if (flags & ast.Flags.protected != 0) return .protected;
        return .public;
    }
};

/// The direction an access reads its modifiers for, or `.none` for an access
/// whose accessibility a sibling call already judged. `.none` exists for the
/// compound-assignment shape: `x.p += 1` is ONE access for tsc
/// (`isWriteAccess` is true, so the check runs once against the setter), while
/// ztsc checks the target and then re-reads the same node as an expression.
pub const Dir = enum { read, write, none };

/// One access, as much of it as the accessibility rules need: which direction it
/// reads its modifiers for, and whether the receiver is the `this`/`super`
/// keyword.
pub const Site = struct {
    dir: Dir,
    /// The receiver EXPRESSION, or `null_node` when the caller has none. Read
    /// only to ask whether it is spelled `this`/`super`, and only once the
    /// non-public screen has already passed — so the hot member-access path
    /// stores a node index and inspects nothing.
    ///
    /// That question decides whether a TYPE-PARAMETER receiver may be followed
    /// to its constraint: doing so is tsc's `getApparentType`, and it earns
    /// `this.privateMember` inside `function f<T extends C>(this: T)` — but ztsc
    /// also lands on a type parameter where tsc has a computed `Omit<T, …>` (the
    /// rest type of a generic destructure, `destructuringUnspreadableIntoRest`),
    /// and there the member is one tsc says does not exist at all. Requiring the
    /// `this` receiver keeps the first and leaves the second to the TS2339 it
    /// should have been.
    recv_node: Node = ast.null_node,

    /// tsc's `left.kind === SyntaxKind.ThisKeyword / SuperKeyword`.
    fn viaThis(site: Site, c: *Checker) bool {
        var n = site.recv_node;
        if (n == ast.null_node) return false;
        while (c.nodeTag(n) == .paren_expr) {
            const inner = c.tree.nodeData(n).lhs;
            if (inner == ast.null_node) break;
            n = inner;
        }
        return switch (c.nodeTag(n)) {
            .this_expr, .super_expr => true,
            else => false,
        };
    }
};

/// Report TS2341/TS2445 when `name` — already known to be non-public, via
/// `Prop.nonPublic()` — is not accessible from the current lexical position.
///
/// `recv` is the receiver type as written (before `resolveStructural`): the
/// declaring class is found by walking the `extends` chain of the class the
/// receiver names, so a receiver that names no class at all (an anonymous
/// object that merely copied the flag, a type parameter, an intersection)
/// reports nothing.
pub fn check(c: *Checker, recv: TypeId, name: Atom, name_tok: TokenIndex, site: Site) Error!void {
    if (site.dir == .none) return;
    const found = (try declaringClass(c, recv, name, site)) orelse return;
    const access = accessOfMember(c, found.msym, site.dir == .write);
    if (access == .public) return;
    if (access == .private) {
        if (try withinClass(c, found.cls, false)) return;
        try c.diagFmt(2341, c.tokSpan(name_tok), "Property '{s}' is private and only accessible within class '{s}'.", .{
            c.atomText(name), try declaringClassName(c, found.cls),
        });
        return;
    }
    const enclosing = try enclosingDerived(c, found.cls) orelse {
        // tsc's "allow accessibility if the context is a function with a `this`
        // parameter" arm, which no lexical class covers: `function f(this: Foo) {
        // foo.protectedMember }` is legal, and so is the same body under a
        // CONTEXTUAL `this` (`const f: (this: Foo) => void = function () {…}`).
        // Both are exactly "the `this` type in effect derives from the declaring
        // class". Static members are excluded — tsc tests `flags &
        // ModifierFlags.Static` before it looks for the parameter at all — and so
        // is `private`, which admits no such relaxation. (tsc then runs the
        // instance test below against that `this` type; leaving it out here only
        // under-reports.)
        if (!found.statics and c.this_type != 0 and try derivesFrom(c, c.this_type, found.cls)) return;
        try c.diagFmt(2445, c.tokSpan(name_tok), "Property '{s}' is protected and only accessible within class '{s}' and its subclasses.", .{
            c.atomText(name), try declaringClassName(c, found.cls),
        });
        return;
    };
    // An INSTANCE member additionally has to be reached through an instance of
    // the enclosing class, not merely of the declaring one: inside `B extends A`,
    // `this.x` and `b.x` are legal while `a.x` and `c.x` are not, because the
    // protection is what stops one subclass from reading a sibling's state
    // (tsc's `hasBaseType(type, enclosingClass)`). "No further restrictions for
    // static properties" is tsc's own comment on the line above it.
    if (found.statics) return;
    if (try derivesFrom(c, found.recv, enclosing)) return;
    try c.diagFmt(2446, c.tokSpan(name_tok), "Property '{s}' is protected and only accessible through an instance of class '{s}'. This is an instance of class '{s}'.", .{
        c.atomText(name), try declaringClassName(c, enclosing), try c.typeToString(found.recv),
    });
}

/// `typeToString(getDeclaringClass(prop))`: the class's own DECLARED type, so a
/// generic class names its parameters (`MyGenericClass<T>`, not
/// `MyGenericClass`).
fn declaringClassName(c: *Checker, cls: SymbolId) Error![]const u8 {
    var tps: std.ArrayList(checker_zig.Checker.TypeParamInfo) = .empty;
    defer tps.deinit(c.scratch());
    try c.typeParamsOf(cls, &tps);
    if (tps.items.len == 0) return c.symbolName(cls);
    const args = try c.scratch().alloc(TypeId, tps.items.len);
    defer c.scratch().free(args);
    for (tps.items, 0..) |tp, i| args[i] = try c.ts.makeTypeParam(tp.sym);
    return c.typeToString(try c.ts.makeRef(cls, args));
}

/// The class that DECLARES `name`, plus the member symbol itself. tsc's
/// `getParentOfSymbol(prop)` — which it has for free because a symbol knows
/// its table; ztsc rediscovers it by walking the receiver's `extends` chain,
/// the same walk `heritage.baseClassMember` makes for TS2612.
/// `recv` is the receiver type after the `this`/class-value/type-parameter hops
/// below — tsc's `getApparentType`ed `type`, which is what the TS2446 instance
/// test and its message both name.
const Declaring = struct { cls: SymbolId, msym: SymbolId, statics: bool, recv: TypeId };

fn declaringClass(c: *Checker, recv: TypeId, name: Atom, site: Site) Error!?Declaring {
    var t = recv;
    // `this.p` inside a class body has the `this` TYPE, whose instance is the
    // class reference; a static member is reached through the class VALUE; and
    // a `this: T` parameter makes the receiver a type PARAMETER, whose apparent
    // type is its constraint (tsc's `getApparentType` before the lookup —
    // `function f<T extends C>(this: T) { this.privateMember }` is TS2341).
    var statics = false;
    var hops: u32 = 0;
    while (hops < 8) : (hops += 1) {
        switch (c.ts.kind(t)) {
            .this_type => t = c.ts.thisTypeInstance(t),
            .class_value => {
                statics = true;
                t = try c.ts.makeRef(c.ts.classSymbol(t), &.{});
            },
            .type_param => {
                if (!site.viaThis(c)) return null;
                const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
                if (con == types.no_type or con == t) return null;
                t = con;
            },
            else => break,
        }
    }
    const recv_norm = t;
    if (c.ts.kind(t) != .ref) return null;
    // Breadth-first over the DECLARED heritage, because an INTERFACE may extend
    // a class (and several bases at once): `interface I extends Foo {}` inherits
    // `Foo`'s `private x`, and `i.x` is TS2341 naming `Foo`. A class-only
    // `extends` walk stops at the interface and reports nothing.
    //
    // Bounded and cycle-checked like every other heritage walk here.
    var queue: [32]SymbolId = undefined;
    var seen: [32]SymbolId = undefined;
    var qn: usize = 1;
    var head: usize = 0;
    var n: usize = 0;
    queue[0] = c.ts.refSymbol(t);
    while (head < qn) {
        const sym = queue[head];
        head += 1;
        if (n == seen.len) return null;
        var dup = false;
        for (seen[0..n]) |s| if (s == sym) {
            dup = true;
        };
        if (dup) continue;
        seen[n] = sym;
        n += 1;
        {
            const saved = c.enterSymFile(sym);
            defer c.restoreCtx(saved);
            const local = c.localOf(sym);
            const scope = if (statics) c.bind.staticsScopeOf(local) else c.bind.membersScopeOf(local);
            if (scope) |ms| {
                const lo = c.bind.scope_members_start[ms];
                const hi = c.bind.scope_members_start[ms + 1];
                for (lo..hi) |i| {
                    if (c.bind.member_atoms[i] != name) continue;
                    return .{ .cls = sym, .msym = c.toGlobal(c.bind.member_syms[i]), .statics = statics, .recv = recv_norm };
                }
            }
        }
        // Statics are not inherited through an interface, and an interface has
        // no static side at all, so the static search stays on the class chain.
        if (statics and !c.symFlags(sym).class) continue;
        for (try c.declaredBaseRefs(sym)) |b| {
            if (c.ts.kind(b) != .ref or qn == queue.len) continue;
            queue[qn] = c.ts.refSymbol(b);
            qn += 1;
        }
    }
    return null;
}

/// `getDeclarationModifierFlagsFromSymbol(msym, writing)`: the setter's
/// modifiers for a write when the symbol has a `set` accessor, the getter's
/// for a read when it has a `get` accessor, else the first class-body
/// declaration's.
fn accessOfMember(c: *Checker, msym: SymbolId, writing: bool) Access {
    const saved = c.enterSymFile(msym);
    defer c.restoreCtx(saved);
    var first: ?u32 = null;
    var wanted: ?u32 = null;
    for (c.declsOf(msym)) |decl| {
        const d = c.tree.nodeData(decl);
        const flags: u32 = switch (c.nodeTag(decl)) {
            .class_field => c.tree.extraData(ast.Field, d.lhs).flags,
            .class_method => c.tree.extraData(ast.FnProto, d.lhs).flags,
            .param_full => c.tree.extraData(ast.ParamFull, d.rhs).flags,
            else => continue,
        };
        if (first == null) first = flags;
        const want: u32 = if (writing) ast.Flags.set else ast.Flags.get;
        if (flags & want != 0 and wanted == null) wanted = flags;
    }
    return Access.of(wanted orelse first orelse 0);
}

/// `private` is tsc's `isNodeWithinClass(location, declaringClassDeclaration)`
/// — the enclosing class must BE the declaring one; `protected` is
/// `forEachEnclosingClass(location, isClassDerivedFromDeclaringClasses)` — any
/// enclosing class derived from it will do. One walk, one flag.
fn withinClass(c: *Checker, cls: SymbolId, derived_ok: bool) Error!bool {
    var it = EnclosingClasses.init(c);
    while (it.next(c)) |sym| {
        if (sym == cls) return true;
        if (derived_ok and try derivesFromSym(c, sym, cls)) return true;
    }
    return false;
}

/// tsc's `forEachEnclosingClass(node, ec => isClassDerivedFromDeclaringClasses(ec, prop) ? ec : undefined)`:
/// the INNERMOST lexically enclosing class that derives from `cls`. It is the
/// class an instance has to be an instance OF for the protected access to be
/// legal (TS2446), which is why the identity of the match matters and not just
/// its existence.
fn enclosingDerived(c: *Checker, cls: SymbolId) Error!?SymbolId {
    var it = EnclosingClasses.init(c);
    while (it.next(c)) |sym| {
        if (sym == cls or try derivesFromSym(c, sym, cls)) return sym;
    }
    return null;
}

/// `hasBaseType(t, base)`: does the class `t` names extend `base` (transitively,
/// equality included)? A type parameter is followed to its constraint, which is
/// what makes `function f<T extends Derived>(this: T)` count as being inside
/// `Derived` (tsc's `getConstraintOfTypeParameter` on the `this` type).
fn derivesFrom(c: *Checker, t0: TypeId, base: SymbolId) Error!bool {
    var t = t0;
    var hops: u32 = 0;
    while (hops < 8) : (hops += 1) {
        switch (c.ts.kind(t)) {
            .this_type => t = c.ts.thisTypeInstance(t),
            .type_param => {
                const con = try c.typeParamConstraint(c.ts.typeParamSymbol(t));
                if (con == types.no_type or con == t) return false;
                t = con;
            },
            .ref => return derivesFromSym(c, c.ts.refSymbol(t), base),
            else => return false,
        }
    }
    return false;
}

fn derivesFromSym(c: *Checker, derived: SymbolId, base: SymbolId) Error!bool {
    var sym = derived;
    var hops: u32 = 0;
    while (hops < 32) : (hops += 1) {
        if (sym == base) return true;
        if (!c.symFlags(sym).class) return false;
        const ref = try c.baseClassRef(sym) orelse return false;
        if (c.ts.kind(ref) != .ref) return false;
        const next = c.ts.refSymbol(ref);
        if (next == sym) return false;
        sym = next;
    }
    return false;
}

/// The class bodies lexically containing the current position, innermost
/// first. The binder gives each class its own `.class` scope, whose
/// `class_members` child is registered against the class symbol — so walking
/// `c.cur_scope`'s parents and inverting that registration is the scope-chain
/// spelling of tsc's node-chain `forEachEnclosingClass`.
const EnclosingClasses = struct {
    scope: ScopeId,

    fn init(c: *const Checker) EnclosingClasses {
        return .{ .scope = c.cur_scope };
    }

    fn next(it: *EnclosingClasses, c: *Checker) ?SymbolId {
        while (true) {
            const s = it.scope;
            if (s == binder.file_scope) return null;
            it.scope = c.bind.scope_parents[s];
            if (c.bind.scope_kinds[s] != .class) continue;
            if (classSymbolOfScope(c, s)) |sym| return sym;
        }
    }
};

/// The class symbol whose body is `cs` (a `.class` scope). The binder records
/// `class symbol -> members scope`, and a members scope's parent is the class
/// scope, so this is that map read backwards. Linear in the file's
/// class/interface count and reached only from a non-public access.
fn classSymbolOfScope(c: *Checker, cs: ScopeId) ?SymbolId {
    for (c.bind.member_scope_ids, c.bind.member_scope_syms) |ms, sym| {
        if (c.bind.scope_parents[ms] == cs) return c.toGlobal(sym);
    }
    return null;
}

/// TS2808, over a class body's accessor PAIRS: tsc's `checkAccessorDeclaration`
/// rejects a `get` that is LESS accessible than its `set`, and reports on both
/// accessors' name tokens. (The converse — a getter more accessible than its
/// setter — is legal, and is what makes a publicly-readable/privately-writable
/// property expressible.)
///
/// The quadratic pairing loop is guarded by a linear pre-scan, so a class body
/// without BOTH a getter and a setter — every class in the benchmark corpus but
/// a handful — walks its members once and stops.
pub fn checkAccessorVisibility(c: *Checker, members: []const Node) Error!void {
    var has_get = false;
    var has_set = false;
    for (members) |m| {
        if (m == ast.null_node or c.nodeTag(m) != .class_method) continue;
        const f = c.tree.extraData(ast.FnProto, c.tree.nodeData(m).lhs).flags;
        if (f & ast.Flags.get != 0) has_get = true;
        if (f & ast.Flags.set != 0) has_set = true;
    }
    if (!has_get or !has_set) return;
    for (members) |g| {
        if (g == ast.null_node or c.nodeTag(g) != .class_method) continue;
        const gf = c.tree.extraData(ast.FnProto, c.tree.nodeData(g).lhs).flags;
        if (gf & ast.Flags.get == 0) continue;
        const get_tok = c.tree.nodeMainToken(g);
        const name = try c.memberAtom(get_tok);
        for (members) |s| {
            if (s == ast.null_node or c.nodeTag(s) != .class_method) continue;
            const sf = c.tree.extraData(ast.FnProto, c.tree.nodeData(s).lhs).flags;
            if (sf & ast.Flags.set == 0) continue;
            if (gf & ast.Flags.static != sf & ast.Flags.static) continue;
            const set_tok = c.tree.nodeMainToken(s);
            if (try c.memberAtom(set_tok) != name) continue;
            if (@intFromEnum(Access.of(gf)) <= @intFromEnum(Access.of(sf))) continue;
            try c.diagFmt(2808, c.tokSpan(get_tok), "A get accessor must be at least as accessible as the setter", .{});
            try c.diagFmt(2808, c.tokSpan(set_tok), "A get accessor must be at least as accessible as the setter", .{});
        }
    }
}
