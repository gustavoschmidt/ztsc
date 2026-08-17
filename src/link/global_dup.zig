//! Cross-file duplicate-declaration detection over the program's GLOBAL merge.
//!
//! The binder catches a name declared twice inside ONE file: `declareSymbol`
//! meets an existing symbol whose flags the newcomer excludes and reports at
//! every declaration of the name (binder.zig `reportDuplicate`). Two *files*
//! declaring the same global never meet a binder — they meet the linker's
//! `mergeGlobals`, which until now folded them silently, so
//!
//!     // file1.ts          // file2.ts
//!     class A { }          class A { }
//!
//! passed without a word while tsc reports TS2300 at both.
//!
//! tsc does this in `initializeTypeChecker`: every non-module file's top level
//! is folded into one `globals` table with `mergeSymbolTable`, and `mergeSymbol`
//! reports at every declaration of BOTH sides when the target's flags and the
//! source's excludes mask overlap. Which message it picks is a slightly
//! different rule from `declareSymbol`'s — an `enum` or a block-scoped variable
//! on EITHER side wins, not just on the target — and `mergeClash` reproduces
//! that rule and only that rule.
//!
//! Scope, deliberately: the TOP-LEVEL global name merge only. The nested
//! namespace-member merge (`Merger.buildNsMembers`) indexes members the merged
//! view needs, including ones tsc keeps in separate symbol tables — a namespace
//! local that was never `export`ed lands there too — so a "duplicate" found in
//! it would be an artifact of the index rather than a fact about the program.
//!
//! Cost: one excludes test per contributor of a name that has 2+ of them, which
//! is a handful of `u32` ops on a set `mergeGlobals` already walks to fold
//! flags. The declaration walk — the only part that touches an AST — runs only
//! for a name that actually clashes, so a program with no cross-file duplicate
//! pays nothing beyond the flag test.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../frontend/ast.zig");
const bind_result = @import("../frontend/bind_result.zig");
const diagnostics = @import("../frontend/diagnostics.zig");
const program = @import("program.zig");
const source = @import("../frontend/source.zig");
const scanner = @import("../frontend/scanner.zig");

const Code = diagnostics.Code;
const LinkDiag = program.LinkDiag;
const Span = source.Span;
const SymbolFlags = bind_result.SymbolFlags;

const Error = error{OutOfMemory};

/// The clash among the contributors of ONE global name, in merge order, or null
/// when they all merge. Pure: flags in, diagnostic code out.
///
/// `flags[0]` is the merge target (the first visit of the name, which tsc's
/// `mergeSymbolTable` keeps as the target for every later one); each later
/// contributor is merged into the accumulated target the way `mergeSymbol`
/// does, and a contributor whose merge FAILS is not folded in — tsc leaves the
/// target untouched on the error path.
pub fn mergeClash(flags: []const SymbolFlags) ?Code {
    if (flags.len < 2) return null;
    var acc = flags[0];
    for (flags[1..]) |f| {
        if (bind_result.effectiveBits(acc) & bind_result.excludesOfFlags(f) != 0) {
            // tsc's `mergeSymbol` takes a DIFFERENT arm before the duplicate
            // one when the target carries `SymbolFlags.NamespaceModule` — a
            // namespace whose every block is type-only. That arm reports
            // TS2649 ("cannot augment module 'A' … non-module entity") on the
            // source, or nothing at all for `globalThis`; either way the name
            // is not a duplicate. `interface A {} namespace A {}` in one file
            // beside `type A = {}` in another is exactly that shape.
            if (acc.ns_uninstantiated) return null;
            // tsc's `mergeSymbol` message order, which reads BOTH sides (unlike
            // `declareSymbol`, which reads the existing symbol alone): an `enum`
            // anywhere in the failing pair, then a block-scoped variable
            // anywhere in it, then the plain duplicate. `class` is not one of
            // tsc's `SymbolFlags.BlockScopedVariable` bits here either.
            if (acc.enum_decl or f.enum_decl) return .enum_merge_conflict;
            if (acc.let_decl or acc.const_decl or f.let_decl or f.const_decl) return .block_scoped_redeclare;
            return .duplicate_identifier;
        }
        acc = acc.merge(f);
    }
    return null;
}

/// The member-space bits of a symbol: which KIND of interface/class member it
/// declares.
fn memberBits(f: SymbolFlags) u32 {
    return f.bits() & bind_result.mask_member;
}

/// The clash between a class's STATIC member and the same-named EXPORTED member
/// of the namespace it merges with, or null when they merge.
///
/// This is `mergeClash`'s rule read across ztsc's member/value split. tsc has no
/// such split: `SymbolFlags.Value` *includes* `Property | Method | Accessor`, and
/// a class's statics ARE its `exports` table, so every `…Excludes` mask that
/// covers `Value` covers a static member too. `VariableExcludes`,
/// `FunctionExcludes`, `ClassExcludes` and `ValueModuleExcludes` all do —
/// meaning any value-meaning namespace export collides with any static of the
/// same name — while the type-space-only masks (`InterfaceExcludes`,
/// `TypeAliasExcludes`) do not, so
///
///     class C { static X: number }
///     namespace C { export interface X {} }     // legal
///     namespace C { export var X = 1 }          // TS2300 on both
///
/// The static side must actually BE a member: an entry the binder filed in the
/// statics table without a member kind (a shape this walk does not model) is not
/// judged, the same refusal `membersMerge` makes.
pub fn cloduleClash(static_flags: SymbolFlags, ns_flags: SymbolFlags) ?Code {
    if (memberBits(static_flags) == 0) return null;
    if (bind_result.effectiveBits(ns_flags) & bind_result.mask_value == 0) return null;
    // `mergeClash`'s message order, with the same two special cases.
    if (ns_flags.enum_decl) return .enum_merge_conflict;
    if (ns_flags.let_decl or ns_flags.const_decl) return .block_scoped_redeclare;
    return .duplicate_identifier;
}

/// The clash among the same-named MEMBERS contributed by the blocks of one
/// cross-file merged interface, or null when they all merge.
///
/// This is NOT `excludesOfFlags`: tsc's `PropertyExcludes` is empty, so two
/// property signatures of one name MERGE and their disagreement, if any, is
/// TS2717 ("subsequent property declarations must have the same type") rather
/// than a duplicate — verified against the oracle in both orders. What tsc calls
/// a duplicate is a clash of member KINDS, and that is what this decides:
///
///   * two properties merge (TS2717's business),
///   * two methods merge (they are overload signatures),
///   * a getter and a setter merge (they are one accessor pair),
///   * anything else — a property beside a method, two getters — is TS2300 at
///     every declaration, whichever block came first.
pub fn memberClash(flags: []const SymbolFlags) ?Code {
    if (flags.len < 2) return null;
    var acc = memberBits(flags[0]);
    for (flags[1..]) |f| {
        const m = memberBits(f);
        if (!membersMerge(acc, m)) return .duplicate_identifier;
        acc |= m;
    }
    return null;
}

fn membersMerge(a: u32, b: u32) bool {
    const prop = bind_result.fbits(.{ .property = true });
    const meth = bind_result.fbits(.{ .method = true });
    const accessors = bind_result.fbits(.{ .getter = true }) | bind_result.fbits(.{ .setter = true });
    if (a == prop and b == prop) return true;
    if (a == meth and b == meth) return true;
    // A get/set pair, and only a pair: a second getter overlaps the first.
    if (a != 0 and b != 0 and a & ~accessors == 0 and b & ~accessors == 0 and a & b == 0) return true;
    // A member ztsc gave no member kind at all (an index/call signature, or a
    // shape this walk does not model) is not judged.
    return a == 0 or b == 0;
}

/// Where one contributor's declarations are: the file that declared it and the
/// declaration nodes, so the reporter can turn each into a name span.
pub const Contributor = struct {
    file: program.FileId,
    tree: *const ast.Ast,
    src: []const u8,
    decls: []const ast.Node = &.{},
    /// Spans of declarations that own no declaration NODE the name walk can
    /// reach — today only `export as namespace X`, whose name is a bare token
    /// (see umd.zig). Reported verbatim, alongside `decls`.
    spans: []const Span = &.{},
};

/// Report `code` at the name of EVERY declaration of every contributor — tsc's
/// `addDuplicateDeclarationErrorsForSymbols`, run over both sides of the failed
/// merge and deduplicated by its diagnostic collection. Reporting each
/// declaration exactly once here needs no dedup pass.
///
/// A declaration whose name is not a single identifier token (a destructuring
/// pattern) is skipped: there is no span to report it at. That is an
/// under-report, and the safe direction.
pub fn reportAll(
    arena: Allocator,
    diags: []std.ArrayList(LinkDiag),
    contributors: []const Contributor,
    code: Code,
) Error!void {
    const msg = code.message();
    const ts = code.tsCode();
    for (contributors) |c| {
        for (c.decls) |decl| {
            const tok = c.tree.declNameToken(decl) orelse continue;
            const start = c.tree.tokens.start(tok);
            const span: Span = .{
                .start = start,
                .end = scanner.tokenEnd(c.src, c.tree.tokens.tag(tok), start),
            };
            try diags[c.file].append(arena, .{ .code = ts, .span = span, .msg = msg });
        }
        for (c.spans) |span| {
            try diags[c.file].append(arena, .{ .code = ts, .span = span, .msg = msg });
        }
    }
}

test "cloduleClash: a class static against its namespace's exports" {
    const t = std.testing;
    const clash = cloduleClash;
    // Every value-meaning export collides with a static of the same name.
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(.{ .property = true }, .{ .var_decl = true }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(.{ .method = true }, .{ .function = true }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(.{ .getter = true }, .{ .function = true }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(.{ .property = true }, .{ .class = true }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(.{ .property = true }, .{ .namespace_decl = true }));
    try t.expectEqual(@as(?Code, .block_scoped_redeclare), clash(.{ .property = true }, .{ .const_decl = true }));
    try t.expectEqual(@as(?Code, .enum_merge_conflict), clash(.{ .property = true }, .{ .enum_decl = true }));
    // Type space alone never reaches the statics table.
    try t.expectEqual(@as(?Code, null), clash(.{ .property = true }, .{ .interface = true }));
    try t.expectEqual(@as(?Code, null), clash(.{ .property = true }, .{ .type_alias = true }));
    // A non-instantiated namespace occupies no exclusion space (tsc's
    // `NamespaceModuleExcludes = 0`), and neither side is judged without a
    // member kind on the static.
    try t.expectEqual(@as(?Code, null), clash(
        .{ .property = true },
        .{ .namespace_decl = true, .ns_uninstantiated = true },
    ));
    try t.expectEqual(@as(?Code, null), clash(.{}, .{ .var_decl = true }));
}

test "memberClash: two interface blocks' same-named members" {
    const t = std.testing;
    const clash = memberClash;
    // Merge: the pairs tsc lets share one member symbol.
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .property = true }, .{ .property = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .method = true }, .{ .method = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .getter = true }, .{ .setter = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .setter = true }, .{ .getter = true } }));
    // An optional/readonly property is still a property.
    try t.expectEqual(@as(?Code, null), clash(&.{
        .{ .property = true, .optional_member = true },
        .{ .property = true, .readonly_member = true },
    }));
    // Clash: a KIND disagreement, in either order.
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .property = true }, .{ .method = true } }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .method = true }, .{ .property = true } }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .getter = true }, .{ .getter = true } }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .property = true }, .{ .getter = true } }));
    // A third block overlapping an already-complete accessor pair.
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{
        .{ .getter = true },
        .{ .setter = true },
        .{ .setter = true },
    }));
    // A symbol with no member kind at all is not judged.
    try t.expectEqual(@as(?Code, null), clash(&.{ .{}, .{ .method = true } }));
}

test "mergeClash: the pairs tsc merges across files, and the codes it picks" {
    const t = std.testing;
    const clash = mergeClash;
    // Legal declaration merging: interface+interface, class+interface,
    // var+var, namespace+anything, function overloads, enum+enum.
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .interface = true }, .{ .interface = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .class = true }, .{ .interface = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .interface = true }, .{ .class = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .var_decl = true }, .{ .var_decl = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .namespace_decl = true }, .{ .class = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .function = true }, .{ .function = true } }));
    try t.expectEqual(@as(?Code, null), clash(&.{ .{ .enum_decl = true }, .{ .enum_decl = true } }));
    // A non-instantiated namespace excludes nothing and is excluded by nothing.
    try t.expectEqual(@as(?Code, null), clash(&.{
        .{ .namespace_decl = true, .ns_uninstantiated = true },
        .{ .const_decl = true },
    }));
    // Single contributor: never a duplicate, whatever it is.
    try t.expectEqual(@as(?Code, null), clash(&.{.{ .let_decl = true }}));
    // A target carrying tsc's `NamespaceModule` takes its own `mergeSymbol` arm
    // (TS2649), never the duplicate one: `interface A {} namespace A {}` in one
    // file beside `type A = {}` in another.
    try t.expectEqual(@as(?Code, null), clash(&.{
        .{ .interface = true, .namespace_decl = true, .ns_uninstantiated = true },
        .{ .type_alias = true },
    }));
    // The three messages.
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .class = true }, .{ .class = true } }));
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{ .{ .type_alias = true }, .{ .type_alias = true } }));
    try t.expectEqual(@as(?Code, .block_scoped_redeclare), clash(&.{ .{ .let_decl = true }, .{ .let_decl = true } }));
    // Block-scoped on EITHER side (tsc's `mergeSymbol`, unlike `declareSymbol`).
    try t.expectEqual(@as(?Code, .block_scoped_redeclare), clash(&.{ .{ .var_decl = true }, .{ .let_decl = true } }));
    try t.expectEqual(@as(?Code, .block_scoped_redeclare), clash(&.{ .{ .let_decl = true }, .{ .var_decl = true } }));
    try t.expectEqual(@as(?Code, .enum_merge_conflict), clash(&.{ .{ .enum_decl = true }, .{ .var_decl = true } }));
    try t.expectEqual(@as(?Code, .enum_merge_conflict), clash(&.{ .{ .var_decl = true }, .{ .enum_decl = true } }));
    // An enum beats a block-scoped variable in the same failing pair.
    try t.expectEqual(@as(?Code, .enum_merge_conflict), clash(&.{ .{ .const_decl = true }, .{ .enum_decl = true } }));
    // Three contributors: the first two merge, the third clashes with the fold.
    try t.expectEqual(@as(?Code, .duplicate_identifier), clash(&.{
        .{ .var_decl = true },
        .{ .var_decl = true },
        .{ .class = true },
    }));
    // ...and a third that merges with the fold is still no error.
    try t.expectEqual(@as(?Code, null), clash(&.{
        .{ .interface = true },
        .{ .interface = true },
        .{ .class = true },
    }));
}
