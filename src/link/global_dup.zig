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

/// Where one contributor's declarations are: the file that declared it and the
/// declaration nodes, so the reporter can turn each into a name span.
pub const Contributor = struct {
    file: program.FileId,
    tree: *const ast.Ast,
    src: []const u8,
    decls: []const ast.Node,
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
    }
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
