//! Diagnostic filing, source spans, and the speculation protocol.
//!
//! This is where a diagnostic becomes a fact. `diagFmt` files one, deduped by
//! `(file, code, span-start)` in `diag_seen`, and that dedupe key is a
//! *permanent* record — which is exactly why withdrawing a diagnostic is not
//! `diags.items.len = saved`.
//!
//! **The speculation protocol lives here.** A speculative check — an overload
//! candidate, a probe — must leave the state a silent run would have left, and
//! `rollbackDiags` is the only correct way to get there. It withdraws both the
//! diagnostic AND its suppression key, and it withdraws them only inside the
//! `SpecRegion` the probe was speaking about: everything filed *outside* that
//! region is collateral from work the probe merely triggered (materializing a
//! symbol from another file walks that file's bodies, once, memoized), and
//! deleting it loses it forever. `rollbackArgDiags` is the argument-list
//! specialization. Read the comment on `rollbackDiags` before changing any of
//! it — every clause in it is a reported bug.
//!
//! The instantiation-limit anchor is the other half: `InstAnchor` /
//! `anchorInst` / `instSpanHere` keep TS2589 and TS2590 pinned to the *demand*
//! site rather than to wherever the budget happened to run out, and
//! `instDiagAllowed` decides whether a trip is a user-facing diagnostic at all
//! or the silent "no evidence" cut a relation answers `Maybe` to. Both exist
//! so the reported position is a function of the program and not of the
//! `--checkers` partition.
//!
//! Split mechanically from checker.zig; functions take the `Checker` context
//! as their first parameter and are re-exported as `Checker` methods there.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const scanner = @import("../frontend/scanner.zig");
const source = @import("../frontend/source.zig");
const modules = @import("../link/modules.zig");

const Node = ast.Node;
const null_node = ast.null_node;
const TokenIndex = ast.TokenIndex;
const Span = source.Span;
const FileId = modules.FileId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

pub fn tokSpan(c: *const Checker, tok: TokenIndex) Span {
    const start = c.tree.tokens.start(tok);
    return .{ .start = start, .end = scanner.tokenEnd(c.src, c.tree.tokens.tag(tok), start) };
}

pub fn nodeSpan(c: *const Checker, node: Node) Span {
    return c.tree.span(c.src, node);
}

/// `nodeSpan(node).start` without the O(subtree) walk where the AST
/// shape makes the start derivable from `main_token`. Debug builds
/// cross-check every fast answer against the real span, so a wrong
/// `Ast.spanStart` arm trips the conformance suite instead of silently
/// moving a diagnostic.
pub fn nodeSpanStart(c: *const Checker, node: Node) u32 {
    if (c.tree.spanStart(node)) |start| {
        if (std.debug.runtime_safety) std.debug.assert(start == c.nodeSpan(node).start);
        return start;
    }
    return c.nodeSpan(node).start;
}

/// Deferred `inst_span`: either a node (span computed on demand) or an
/// explicit span pushed by a caller that has one in hand already. Both
/// carry the file they were recorded in — a byte offset is only a
/// position in the tree it came from.
pub const InstAnchor = union(enum) {
    node: struct { file: FileId, node: Node },
    span: struct { file: FileId, span: Span },
};

/// The anchor resolved to the (file, span) pair it was recorded at.
///
/// Materializing a type switches the current-file context
/// (`enterSymFile`) without moving the anchor, so a limit tripped deep
/// inside a foreign declaration still carries the *demand* site's node —
/// and the demand site is the position to report. `cur_file` at the
/// moment of the trip is not: whether the expansion happened to route
/// through a foreign declaration, rather than meeting this checker's
/// already-materialized copy of it, is a property of the partition.
/// The anchor's own file is the only frame its byte offset means
/// anything in, so the span is computed against that file's tree and
/// source rather than `c.tree`/`c.src`, which follow `cur_file`.
pub fn instSpanHere(c: *const Checker) struct { FileId, Span } {
    return switch (c.inst_anchor) {
        .span => |s| .{ s.file, s.span },
        .node => |n| .{ n.file, c.prog.files[n.file].tree.span(c.prog.files[n.file].src, n.node) },
    };
}

/// Whether an instantiation-budget trip happening *right now* is a
/// user-facing TS2589, or a silent "no evidence" cut. Every guard site
/// that would `instLimitDiag(2589, …)` asks this first.
///
/// The two are different questions and tsc keeps them apart by WHERE the
/// recursion is detected. At the CHECKING level — materializing an
/// annotation, a cast, a call's return — tsc's `instantiateType` guard
/// (`instantiationDepth`/`instantiationCount`) reports
/// `Type_instantiation_is_excessively_deep_and_possibly_infinite` and
/// hands back `errorType`. Inside the assignability RELATION it does not:
/// `recursiveTypeRelatedTo` detects a same-symbol recursion with
/// `isDeeplyNestedType` and answers `Ternary.Maybe` — the pair is assumed
/// related, silently, with no diagnostic and nothing cached. A relation is
/// a *question*, and running out of budget while answering it is an
/// absence of evidence, not a property of the program.
///
/// ztsc needs the separation more than tsc does, because its relation asks
/// for orders of magnitude more instantiation than tsc's: ztsc substitutes
/// eagerly and structurally where tsc defers. Relating one pair of kysely
/// builder references — `ExpressionBuilder<DB & {sharedBy: UserTable},
/// 'partner'|'sharedBy'>` against `ExpressionBuilder<DB, 'partner'>`,
/// immich's shape, on which tsc is clean — walks a spine of
/// `SelectQueryBuilder`/`ExpressionBuilder` frames that mints a fresh
/// interned pair at every level. Nothing repeats, so neither the relation
/// memo nor `relIdDeeplyNested`'s growth test closes it (the refs SHRINK
/// down that spine, and the growth test counts only strictly later
/// instantiations), and the walk was measured still running past
/// 40,000,000 node visits at `max_instantiation_depth` 400. Whatever
/// budget it is given it will exhaust, so the trip carries exactly one
/// bit of information — "ztsc gave up" — which is what tsc answers
/// `Maybe` to.
///
/// Reporting it anyway is a false positive, and unlike the report the
/// truncation itself is harmless here: `error_type` relates to everything,
/// so the relation's answer with the cut is the assumed-YES it would have
/// given at `max_relation_depth` one layer up. `inst_limit_tripped` still
/// fires, so the truncated result is still kept out of every memo.
///
/// The direction of the unsoundness is the one `max_relation_depth` and
/// `max_relation_identity_repeats` already take, and the one tsc takes:
/// assume-related can only DROP a diagnostic, never invent one. What it
/// deliberately does NOT do is suppress TS2589 generally — a trip while
/// materializing an annotation still reports (conformance
/// instantiation/002), because that one is a property of the type.
pub fn instDiagAllowed(c: *const Checker) bool {
    return !c.suppress_inst_diag and c.rel_depth == 0;
}

/// Report an instantiation-limit diagnostic (TS2589 / TS2590) at a
/// canonical, partition-independent anchor: at most one per file and
/// code, at the lexically-first anchor seen in that file.
///
/// The record is filed under the *anchor's* file, never `cur_file`. The
/// anchor is only ever set while walking a file this checker owns
/// (`checkStatement`/`anchorInst` and the expression boundaries), so it
/// always survives `seal`'s owned-file filter — and a trip that unwound
/// through a foreign `.d.ts` is reported at the site that demanded it
/// instead of dropped.
///
/// The limit is a resource cap, not a property of a single expression:
/// `instantiateId`'s memo short-circuits before the depth guard, so
/// *which* of a file's several deep materializations actually trips
/// depends on what this checker instance already had cached — i.e. on
/// the partition. Collapsing a file's trips to their lexically-first
/// anchor makes the reported position a function of the program alone.
/// Costs one hash lookup per trip (a handful per run).
pub fn instLimitDiag(c: *Checker, code: u16, msg: []const u8) Error!void {
    const file, const span = c.instSpanHere();
    const gop = try c.inst_diag_at.getOrPut(c.cm(), (@as(u64, file) << 32) | code);
    if (gop.found_existing) {
        const prev = &c.diags.items[gop.value_ptr.*];
        if (span.start < prev.span.start) prev.span = span;
        return;
    }
    gop.value_ptr.* = c.diags.items.len;
    try c.diags.append(c.gpa, .{ .code = code, .file = file, .span = span, .msg = try c.out.dupe(u8, msg) });
}

pub fn anchorInst(c: *Checker, node: Node) void {
    c.inst_anchor = .{ .node = .{ .file = c.cur_file, .node = node } };
}

pub fn diagFmt(c: *Checker, code: u16, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
    // A side query re-checks an expression out of order to inspect its
    // type; the authoritative top-down check reports at the resolved type.
    if (c.side_query_depth > 0) return;
    const key = (@as(u128, c.cur_file) << 64) | (@as(u128, code) << 32) | span.start;
    const gop = try c.diag_seen.getOrPut(c.gpa, key);
    if (gop.found_existing) return;
    const msg = try std.fmt.allocPrint(c.out, fmt, args);
    try c.diags.append(c.gpa, .{ .code = code, .file = c.cur_file, .span = span, .msg = msg });
}

/// Has a diagnostic with this code already been filed at this span?
/// (`diagFmt`'s dedupe key, asked without filing anything.)
///
/// An elaboration that ran once has to keep answering "yes, I elaborated"
/// on every re-check of the same expression, even when its own diagnostic
/// would now be swallowed as a duplicate — otherwise the caller concludes
/// nothing was reported and falls back to the whole-expression error,
/// which lands *beside* the earlier nested one.
pub fn diagAlreadyFiled(c: *Checker, code: u16, span: Span) bool {
    return c.diag_seen.contains((@as(u128, c.cur_file) << 64) | (@as(u128, code) << 32) | span.start);
}

/// The source region a speculative check is allowed to have spoken about:
/// everything a rejected overload candidate says *inside* it is an artifact
/// of that candidate and must be withdrawn; everything outside it is
/// collateral from work the probe merely happened to trigger and must
/// survive. `hi == 0` means "the whole file" (unused today, but it makes an
/// empty region unrepresentable).
/// `codes`, when given, narrows the withdrawal to those diagnostic CODES:
/// a probe that replaces one FAMILY of diagnostics with a summary (the JSX
/// overload set's TS2769) must not also swallow what the same walk said about
/// the expressions inside — tsc types those regardless of which overload it
/// settles on.
const SpecRegion = struct { file: FileId, lo: u32, hi: u32, codes: ?[]const u16 = null };

/// Withdraw the diagnostics a speculative stretch of checking filed inside
/// `spec`, restoring the state a *silent* probe would have left.
///
/// Two things make this more than `diags.items.len = saved`.
///
/// (1) `diagFmt` writes a second, permanent record: the (file, code,
///     span-start) key in `diag_seen`. Truncating the list alone erases the
///     diagnostic *and keeps its suppression*, so the next check of the same
///     expression is swallowed forever. A rejected overload candidate
///     contextually types an arrow argument, walks its body, files the body's
///     errors, and the truncation then poisons every one of those spans
///     against the WINNING candidate's re-walk: the body is checked twice
///     and reported zero times, which is indistinguishable from never being
///     checked at all.
///
/// (2) The probe also drags in work that is not speculative at all. Checking
///     an argument materializes whatever symbols it mentions, and
///     materializing `const f = (…) => {…}` from another file walks that
///     arrow's body — under `no_publish_depth == 0`, so its type IS memoized.
///     Those diagnostics belong to the other file's own check, are produced
///     exactly once, and the blanket truncation deleted them with no second
///     chance: the memo makes sure the body is never walked again. That is
///     how whole top-level bodies (data/encryption.ts's `decryptData`, via a
///     `new Uint8Array(await decryptData(…))` overload probe in data/encode.ts)
///     went unreported. Restricting the withdrawal to `spec` keeps them.
///
/// `instLimitDiag` stores *indices* into `diags`; any pointing into the
/// window are dropped rather than remapped (the map is empty on nearly every
/// run — hence the count guard — and a dropped anchor at worst lets a later
/// trip re-file the file's single TS2589, where the previous code left the
/// index dangling onto an unrelated diagnostic).
///
/// KNOWN RESIDUAL. A withdrawal is only recoverable if the winning candidate
/// re-walks the same expression. It does for the argument itself (the
/// contextual type differs per candidate, so `node_types` misses) and for an
/// argument that IS a function expression (`no_publish_depth`), but not for
/// a function expression nested inside an argument and typed context-free —
/// an IIFE, `promises.concat((async () => { … })())`. That body's answer is
/// published, so the re-check hits the memo and its diagnostics stay
/// withdrawn. One site in the excalidraw corpus (element/image.ts:54 of
/// 4166 instrumented arrow bodies). Withholding the whole probed argument
/// from `node_types` closes it and was measured TWICE:
///   - first pass: +3 excess keys — a duplicate whole-argument TS2345
///     beside its own nested elaboration, plus two partition-dependent keys
///     including a TS1308;
///   - re-measured after `diagAlreadyFiled` fixed the duplicate: +2 excess
///     keys, exactly `data/encryption.ts:86:5 TS2345` and
///     `packages/utils/export.ts:126:18 TS1308`, for zero matched keys and
///     zero under-reports closed on the oracle's key set.
/// Still not worth taking: the one site it fixes is an under-report the
/// oracle does not name, and it costs two false positives.
pub fn rollbackDiags(c: *Checker, saved: usize, spec: SpecRegion) void {
    if (c.diags.items.len == saved) return;
    // `remove` invalidates the iterator, so restart after each hit.
    while (c.inst_diag_at.count() > 0) {
        var stale: ?u64 = null;
        var it = c.inst_diag_at.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* >= saved) {
                stale = e.key_ptr.*;
                break;
            }
        }
        _ = c.inst_diag_at.remove(stale orelse break);
    }
    var w = saved;
    for (c.diags.items[saved..]) |d| {
        if (d.file == spec.file and d.span.start >= spec.lo and
            (spec.hi == 0 or d.span.start < spec.hi) and
            (spec.codes == null or std.mem.indexOfScalar(u16, spec.codes.?, d.code) != null))
        {
            _ = c.diag_seen.remove((@as(u128, d.file) << 64) | (@as(u128, d.code) << 32) | d.span.start);
            continue;
        }
        c.diags.items[w] = d;
        w += 1;
    }
    c.diags.items.len = w;
}

/// `rollbackDiags` for an overload probe: the speculative region is the
/// argument list's own byte range in `file`. Computed here rather than by
/// the caller because the span of the last argument is an O(subtree) walk
/// and the overwhelmingly common rejection files no diagnostic at all.
pub fn rollbackArgDiags(c: *Checker, saved: usize, file: FileId, arg_nodes: []const Node) void {
    if (c.diags.items.len == saved) return;
    // Arguments are in source order, so the region is [start of the first,
    // end of the last] — one cheap start and one subtree walk, not one per
    // argument.
    var first: Node = null_node;
    var last: Node = null_node;
    for (arg_nodes) |an| {
        if (an == null_node) continue;
        if (first == null_node) first = an;
        last = an;
    }
    // No arguments at all: nothing the candidate said can be about them.
    if (first == null_node) return;
    c.rollbackDiags(saved, .{ .file = file, .lo = c.nodeSpanStart(first), .hi = c.nodeSpan(last).end });
}
