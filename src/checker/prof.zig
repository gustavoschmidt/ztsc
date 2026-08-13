//! Instantiation-demand profiler — a diagnostic instrument, off unless
//! `--inst-profile` is passed.
//!
//! It answers the question "where does a statement's instantiation budget
//! (`max_instantiation_count`) go?" along several independent axes:
//!
//!   * **call site** — the return address of each *top-level* `instantiate`
//!     entry, with the node-visits that entry charged. Symbolized at report
//!     time through `std.debug`, so the output names the `.zig` line that
//!     asked for the substitution.
//!   * **root type** — the type each top-level entry substituted into, so a
//!     single enormous re-instantiated shape is visible even when many
//!     different call sites ask for it.
//!   * **type kind** — `instantiateId` visits bucketed by `types.Kind`,
//!     which separates signature/constraint work from object-member work.
//!   * **expansion** — `expandRef` calls and their cost, per named symbol,
//!     which is where an interface's whole member table is materialized.
//!   * **one root, in isolation** — `--inst-focus=<type-id>` restricts the
//!     per-type histogram and the kind buckets to substitutions rooted at
//!     one type. A run-wide histogram answers "which subterm does this run
//!     re-walk most", which is the wrong question once a SINGLE top-level
//!     entry is itself the outlier; read the `#id` out of the `by root type`
//!     section and feed it back to break that entry down on its own.
//!
//! Plus a per-statement ledger of the statements that spent the most budget,
//! so a profile can be read against the statements that actually trip.
//!
//! Everything here is gated on `Checker.prof.on` (`--inst-profile`); with the
//! flag off the only cost is a predictable-false branch at the instrumentation
//! points. Output goes to stderr at `seal`, so run with `--checkers=1` to read
//! one profile rather than an interleave.
//!
//! ## Reading the report
//!
//! The report opens with the run totals — node visits, memo hits/misses and
//! budget trips — then the bounds accounting (how much of the run went to a
//! signature's OWN type-parameter bounds, and how much of that was minted and
//! then never read back). After that come the axes above, each as its own
//! `--` section, sorted by charged visits:
//!
//!   * `visits by type kind` — where the walk spends itself, structurally.
//!   * `top-level instantiate() by call site` / `by root type` — the two
//!     views of demand. A flat call-site list with no dominant entry means
//!     the cost is structural and no single caller can be fixed.
//!   * `visits under root #N only` — populated only under `--inst-focus`.
//!   * `expandRef() by symbol`, and the same list SELF (nested expansions
//!     subtracted), which is what separates "this interface is expensive" from
//!     "this interface pulls in expensive ones".
//!   * the re-derivation and reuse histograms — how many expansions were
//!     recomputed to the same answer, and how many were never re-read at all.
//!     Both measure the headroom a better cache could win; when they are
//!     small, only doing less work helps.
//!   * `budget trips by the declaration frame that was live` — the source
//!     locations that actually ran out of budget, which is where a profile
//!     meets the diagnostics it explains.
//!
//! Visits are charged to the *enclosing top-level entry*, since `expandRef`
//! runs at `inst_depth > 0`; a nested expansion therefore shows up inside
//! whichever entry first forced it, not on its own.
//!
//! ## Prior findings
//!
//! The dated research log this profiler produced — the immich/kysely
//! investigations, the closed hypotheses and their "do not re-run these"
//! tables — lives in `docs/perf-log.md`.

const std = @import("std");
const types = @import("../types.zig");
const binder = @import("../frontend/binder.zig");

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const TypeId = types.TypeId;
const SymbolId = binder.SymbolId;
const FileId = u32;

// The profiler's two switches — "is it on" and "which root is it focused on" —
// are `checker.Options.profile` / `.profile_focus_root`, read off the checker
// as `c.prof.on` and `c.opts.profile_focus_root`. They were process globals
// until they became per-run options.

const Tally = struct {
    calls: u64 = 0,
    visits: u64 = 0,
    max_visits: u64 = 0,

    fn add(t: *Tally, v: u64) void {
        t.calls += 1;
        t.visits += v;
        if (v > t.max_visits) t.max_visits = v;
    }
};

const Stmt = struct {
    file: FileId,
    /// Byte offset of the statement's start (rendered as line:col).
    pos: u32,
    count: u64,
};

pub const InstProf = struct {
    on: bool = false,
    /// Return address of a top-level `instantiate` -> work charged.
    sites: std.AutoHashMapUnmanaged(usize, Tally) = .empty,
    /// Root type of a top-level `instantiate` -> work charged.
    roots: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `expandRef` by named symbol -> work charged.
    expands: std.AutoHashMapUnmanaged(SymbolId, Tally) = .empty,
    /// `resolveStructural` call sites that actually forced an expansion.
    expand_sites: std.AutoHashMapUnmanaged(usize, Tally) = .empty,
    /// Every `instantiateId` node visit, by the type visited. Names the
    /// individual subterm a runaway substitution keeps re-walking.
    per_type: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `instantiateId` node visits by `types.Kind`.
    kinds: [256]u64 = @splat(0),
    /// Node visits that were served by the memo, by kind (the cache's win).
    kind_hits: [256]u64 = @splat(0),
    /// The costliest statements seen, kept unsorted and truncated at report.
    stmts: std.ArrayListUnmanaged(Stmt) = .empty,
    /// Statements whose budget actually tripped.
    tripped: u64 = 0,
    /// Budget trips by the symbol whose declaration materialization owned the
    /// live budget window (`Checker.epoch_sym`; 0 = a source element's own).
    /// The trip's TS2589 is anchored at the demanding statement, which is a
    /// different thing entirely — this is the frame that spent the budget.
    trip_epochs: std.AutoHashMapUnmanaged(SymbolId, Tally) = .empty,
    /// Non-zero while a top-level `instantiate` of the focused root is live —
    /// see `Options.profile_focus_root`. Nested so a re-entrant focused root
    /// still counts.
    focus_depth: u32 = 0,
    /// `per_type`, restricted to visits charged under the focused root. The
    /// unrestricted histogram sums a whole run and cannot say which subterm
    /// ONE enormous substitution walked; this one can.
    focus_types: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `kinds`, restricted the same way.
    focus_kinds: [256]u64 = @splat(0),
    /// Node visits made while a `cond_check_subst` rebinding is live — i.e.
    /// under the one arm of `instantiateId` that turns the memo off for a
    /// whole subtree, and re-walks it once per union constituent.
    cond_subst_visits: u64 = 0,
    /// Union constituents distributed through that arm.
    cond_subst_laps: u64 = 0,
    /// Per-REFERENCE reuse of a published expansion: `calls` counts the times
    /// `expandRef`'s memo answered for that reference AFTER the one call that
    /// built it, and `visits` carries the build's own inclusive cost. This is
    /// the amortization axis — the whole defence of eager whole-table
    /// expansion is that one consumer pays and every later one reads free, and
    /// nothing had ever counted the later ones. A reference whose entry is
    /// never hit again served exactly ONE consumer.
    expand_reuse: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `expandRef` by named symbol -> SELF (exclusive) work charged. The
    /// inclusive tally above cannot separate the two populations immich shows,
    /// because a repository class's table materialization CONTAINS every
    /// kysely-builder expansion its method bodies force; subtracting the
    /// nested frames says which symbol the visits are really spent in.
    expands_self: std.AutoHashMapUnmanaged(SymbolId, Tally) = .empty,
    /// Node visits the currently-open `expandRef` frame's CHILDREN charged.
    /// Saved and restored by each frame, exactly like `DeclProf.Frame`.
    expand_child_visits: u64 = 0,
    /// The GENERIC member table the innermost `expandRef` is substituting, and
    /// the symbol it belongs to. `instantiateId`'s `.object` arm recognises the
    /// table by identity and charges each property's substitution to that
    /// property's name — the axis that says WHICH of a builder interface's
    /// hundred members the cost is in.
    expand_generic: TypeId = 0,
    expand_sym: SymbolId = 0,
    /// `(symbol << 32) | name atom` -> substitution cost of that member.
    member_costs: std.AutoHashMapUnmanaged(u64, Tally) = .empty,
    /// `(symbol, member name, RESULT type)` triples already seen. A member
    /// whose substitution under a fresh argument list lands on a type some
    /// earlier expansion of the same table already produced is pure
    /// re-derivation — the argument positions that member actually mentions
    /// did not move. This set prices exactly that, and it is a LOWER bound
    /// (`mintFreshTp` keys a rewritten bound on the whole map, so two
    /// otherwise-identical signatures get distinct fresh symbols and are
    /// counted as different results here).
    member_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// `(symbol << 32) | name atom` -> the re-derived share of `member_costs`.
    member_dupes: std.AutoHashMapUnmanaged(u64, Tally) = .empty,
    /// Fresh higher-order type-param symbol -> node visits its substituted
    /// BOUND cost to produce, and whether anything ever read that bound back.
    /// tsc stores a cloned parameter's mapper and resolves the constraint on
    /// demand; ztsc computes it at mint time, so the difference between these
    /// two numbers is what the eager model pays for nothing.
    fresh_bound_cost: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    fresh_bound_read: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(p: *InstProf, gpa: std.mem.Allocator) void {
        p.sites.deinit(gpa);
        p.roots.deinit(gpa);
        p.expands.deinit(gpa);
        p.expand_sites.deinit(gpa);
        p.trip_epochs.deinit(gpa);
        p.per_type.deinit(gpa);
        p.focus_types.deinit(gpa);
        p.expand_reuse.deinit(gpa);
        p.expands_self.deinit(gpa);
        p.member_costs.deinit(gpa);
        p.member_seen.deinit(gpa);
        p.member_dupes.deinit(gpa);
        p.fresh_bound_cost.deinit(gpa);
        p.fresh_bound_read.deinit(gpa);
        p.stmts.deinit(gpa);
    }
};

/// Record that `ref`'s expansion was BUILT, costing `visits` node visits.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteExpandBuild(c: *Checker, ref: TypeId, visits: u64) void {
    if (c.prof.expand_reuse.getOrPut(c.gpa, ref)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.visits += visits;
        gop.value_ptr.max_visits = visits;
    } else |_| {}
}

/// Charge the cost of substituting fresh type-param `fid`'s bound.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteFreshBound(c: *Checker, fid: u32, visits: u64) void {
    if (c.prof.fresh_bound_cost.getOrPut(c.gpa, fid)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += visits;
    } else |_| {}
}

/// Record that fresh type-param `fid`'s bound was READ back.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteFreshBoundRead(c: *Checker, fid: u32) void {
    c.prof.fresh_bound_read.put(c.gpa, fid, {}) catch {};
}

/// Charge one member's substitution inside a generic table expansion.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteMemberCost(c: *Checker, sym: SymbolId, name: u32, result: TypeId, visits: u64) void {
    const key = (@as(u64, sym) << 32) | name;
    if (c.prof.member_costs.getOrPut(c.gpa, key)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
    const seen_key = (key *% 0x9E3779B97F4A7C15) ^ (@as(u64, result) *% 0xD6E8FEB86659FD93);
    const g2 = c.prof.member_seen.getOrPut(c.gpa, seen_key) catch return;
    if (!g2.found_existing) return;
    if (c.prof.member_dupes.getOrPut(c.gpa, key)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one `expandRef`'s SELF (nested frames subtracted) cost to `sym`.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteExpandSelf(c: *Checker, sym: SymbolId, visits: u64) void {
    if (c.prof.expands_self.getOrPut(c.gpa, sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Record that `ref`'s already-published expansion was READ from the memo.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteExpandHit(c: *Checker, ref: TypeId) void {
    if (c.prof.expand_reuse.getOrPut(c.gpa, ref)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.calls += 1;
    } else |_| {}
}

/// Charge one top-level `instantiate` of `t` costing `visits` node visits to
/// the call site `ret_addr`.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteTopLevel(c: *Checker, ret_addr: usize, t: TypeId, visits: u64) void {
    const gpa = c.gpa;
    if (c.prof.sites.getOrPut(gpa, ret_addr)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
    if (c.prof.roots.getOrPut(gpa, t)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one `instantiateId` node visit to the type visited.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteVisit(c: *Checker, t: TypeId) void {
    if (c.cond_check_subst != null) c.prof.cond_subst_visits += 1;
    if (c.prof.per_type.getOrPut(c.gpa, t)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(1);
    } else |_| {}
    if (c.prof.focus_depth > 0) {
        c.prof.focus_kinds[@intFromEnum(c.ts.kind(t))] += 1;
        if (c.prof.focus_types.getOrPut(c.gpa, t)) |gop| {
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(1);
        } else |_| {}
    }
}

/// Open/close a focus window around a top-level `instantiate` (see
/// `Options.profile_focus_root`). Returns whether this entry opened one.
pub fn focusEnter(c: *Checker, t: TypeId) bool {
    const focus_root = c.opts.profile_focus_root;
    if (focus_root == 0 or t != focus_root) return false;
    c.prof.focus_depth += 1;
    return true;
}

pub fn focusExit(c: *Checker) void {
    c.prof.focus_depth -= 1;
}

/// Charge one `resolveStructural` that forced an expansion to its call site.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteExpandSite(c: *Checker, ret_addr: usize, visits: u64) void {
    if (c.prof.expand_sites.getOrPut(c.gpa, ret_addr)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one budget trip to the declaration frame that was live when it
/// fired (`Checker.epoch_sym`).
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteTrip(c: *Checker) void {
    if (c.prof.trip_epochs.getOrPut(c.gpa, c.epoch_sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(1);
    } else |_| {}
}

/// Charge one `expandRef` of a `sym`-rooted reference costing `visits`.
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteExpand(c: *Checker, sym: SymbolId, visits: u64) void {
    if (c.prof.expands.getOrPut(c.gpa, sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Record the budget one statement spent (called at the next statement's
/// reset, so the count is final).
/// Caller must check `c.prof.on`; hot path, deliberately not self-guarded.
pub fn noteStatement(c: *Checker, file: FileId, pos: u32, count: u64) void {
    if (count < 1000) return; // noise floor
    c.prof.stmts.append(c.gpa, .{ .file = file, .pos = pos, .count = count }) catch {};
}

fn lineCol(src: []const u8, pos: u32) struct { u32, u32 } {
    var line: u32 = 1;
    var last_nl: u32 = 0;
    var i: u32 = 0;
    const end = @min(pos, @as(u32, @intCast(src.len)));
    while (i < end) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            last_nl = i + 1;
        }
    }
    return .{ line, end - last_nl + 1 };
}

fn byVisits(comptime K: type) type {
    return struct {
        key: K,
        t: Tally,
        fn desc(_: void, a: @This(), b: @This()) bool {
            return a.t.visits > b.t.visits;
        }
    };
}

fn dumpTally(
    comptime K: type,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    map: *const std.AutoHashMapUnmanaged(K, Tally),
    limit: usize,
    label: fn (*Checker, K, *std.Io.Writer) void,
    c: *Checker,
) !void {
    const Row = byVisits(K);
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);
    var it = map.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        try rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* });
        total += e.value_ptr.visits;
    }
    std.mem.sort(Row, rows.items, {}, Row.desc);
    try w.print("  total visits charged: {d}\n", .{total});
    for (rows.items[0..@min(limit, rows.items.len)]) |r| {
        try w.print("  {d:>12} visits {d:>8} calls {d:>10} max  ", .{ r.t.visits, r.t.calls, r.t.max_visits });
        label(c, r.key, w);
        try w.writeAll("\n");
    }
}

fn labelSite(_: *Checker, addr: usize, w: *std.Io.Writer) void {
    w.print("0x{x}", .{addr}) catch {};
}

fn labelRoot(c: *Checker, t: TypeId, w: *std.Io.Writer) void {
    const s = c.ts.kind(t);
    w.print("#{d} {s}", .{ t, @tagName(s) }) catch {};
    const str = c.typeToString(t) catch return;
    const cut = @min(str.len, 140);
    w.print(" {s}", .{str[0..cut]}) catch {};
}

fn labelSym(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    w.print("{s}", .{c.symbolName(sym)}) catch {};
}

fn labelEpoch(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    if (sym == 0) {
        w.writeAll("<source element>") catch {};
        return;
    }
    labelSym(c, sym, w);
}

/// Render the whole profile to stderr. Called from `seal`.
pub fn report(c: *Checker) void {
    const gpa = c.gpa;
    var buf: [64 * 1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), c.io, &buf);
    const w = &stderr.interface;
    w.print("\n=== ztsc instantiation profile (checker owning {d} file(s)) ===\n", .{c.owned.len}) catch {};
    w.print("total node visits: {d}  memo hits: {d}  misses: {d}  budget trips: {d}\n", .{
        c.inst_total, c.stats.inst_hits, c.stats.inst_misses, c.prof.tripped,
    }) catch {};
    w.print("uncached cond-check rebinding: {d} visits over {d} constituents\n", .{
        c.prof.cond_subst_visits, c.prof.cond_subst_laps,
    }) catch {};
    w.print("visits spent on a signature's OWN type-param bounds: {d} ({d:.1}% of total)\n", .{
        c.stats.inst_bound_visits,
        if (c.inst_total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(c.stats.inst_bound_visits)) / @as(f64, @floatFromInt(c.inst_total)),
    }) catch {};
    w.print("  of which enforced {d} / widen-only {d} / discarded {d}\n", .{
        c.stats.inst_bound_enforced, c.stats.inst_bound_widen, c.stats.inst_bound_discarded,
    }) catch {};
    w.print("  deferred bounds minted {d}, forced {d} ({d:.1}%), speculative-and-forced {d}\n", .{
        c.stats.bound_deferred,
        c.stats.bound_forced,
        if (c.stats.bound_deferred == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(c.stats.bound_forced)) / @as(f64, @floatFromInt(c.stats.bound_deferred)),
        c.stats.bound_speculative,
    }) catch {};
    {
        var minted: u64 = 0;
        var minted_cost: u64 = 0;
        var unread: u64 = 0;
        var unread_cost: u64 = 0;
        var it = c.prof.fresh_bound_cost.iterator();
        while (it.next()) |e| {
            minted += 1;
            minted_cost += e.value_ptr.*;
            if (!c.prof.fresh_bound_read.contains(e.key_ptr.*)) {
                unread += 1;
                unread_cost += e.value_ptr.*;
            }
        }
        w.print("  enforced bounds minted: {d} costing {d} visits; NEVER READ BACK: {d} ({d} visits, {d:.1}% of the run)\n", .{
            minted,                                                                                                               minted_cost,
            unread,                                                                                                               unread_cost,
            if (c.inst_total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(unread_cost)) / @as(f64, @floatFromInt(c.inst_total)),
        }) catch {};
    }

    w.writeAll("\n-- visits by type kind --\n") catch {};
    {
        const Row = struct {
            k: u8,
            v: u64,
            h: u64,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.v > b.v;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        for (c.prof.kinds, 0..) |v, i| {
            if (v == 0 and c.prof.kind_hits[i] == 0) continue;
            rows.append(gpa, .{ .k = @intCast(i), .v = v, .h = c.prof.kind_hits[i] }) catch {};
        }
        std.mem.sort(Row, rows.items, {}, Row.desc);
        for (rows.items) |r| {
            const name = if (r.k < @typeInfo(types.Kind).@"enum".fields.len)
                @tagName(@as(types.Kind, @enumFromInt(r.k)))
            else
                "?";
            w.print("  {d:>12} visits {d:>12} memo-hits  {s}\n", .{ r.v, r.h, name }) catch {};
        }
    }

    w.writeAll("\n-- top-level instantiate() by call site --\n") catch {};
    dumpTally(usize, w, gpa, &c.prof.sites, 25, labelSite, c) catch {};
    w.writeAll("\n-- top-level instantiate() by root type --\n") catch {};
    dumpTally(TypeId, w, gpa, &c.prof.roots, 25, labelRoot, c) catch {};
    w.writeAll("\n-- most re-instantiated individual types --\n") catch {};
    dumpTally(TypeId, w, gpa, &c.prof.per_type, 30, labelRoot, c) catch {};
    if (c.opts.profile_focus_root != 0) {
        w.print("\n-- visits under root #{d} only, by type --\n", .{c.opts.profile_focus_root}) catch {};
        dumpTally(TypeId, w, gpa, &c.prof.focus_types, 40, labelRoot, c) catch {};
        w.writeAll("\n-- visits under that root, by kind --\n") catch {};
        for (c.prof.focus_kinds, 0..) |v, i| {
            if (v == 0) continue;
            const name = if (i < @typeInfo(types.Kind).@"enum".fields.len)
                @tagName(@as(types.Kind, @enumFromInt(@as(u8, @intCast(i)))))
            else
                "?";
            w.print("  {d:>12} visits  {s}\n", .{ v, name }) catch {};
        }
    }
    w.writeAll("\n-- expandRef() by symbol --\n") catch {};
    dumpTally(SymbolId, w, gpa, &c.prof.expands, 25, labelSym, c) catch {};
    w.writeAll("\n-- expandRef() by symbol, SELF (nested expansions subtracted) --\n") catch {};
    dumpTally(SymbolId, w, gpa, &c.prof.expands_self, 25, labelSym, c) catch {};
    w.writeAll("\n-- cost of ONE member, summed over every expansion of its table --\n") catch {};
    {
        const Row = struct {
            key: u64,
            t: Tally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.visits > b.t.visits;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = c.prof.member_costs.iterator();
        var tot: u64 = 0;
        while (it.next()) |e| {
            rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
            tot += e.value_ptr.visits;
        }
        std.mem.sort(Row, rows.items, {}, Row.desc);
        var dup_tot: u64 = 0;
        var dit = c.prof.member_dupes.iterator();
        while (dit.next()) |e| dup_tot += e.value_ptr.visits;
        w.print("  distinct (table, member) pairs: {d}   total charged: {d}\n", .{ rows.items.len, tot }) catch {};
        w.print("  of which RE-DERIVED (same table, same member, same result type as an\n", .{}) catch {};
        w.print("  earlier expansion): {d} visits ({d:.1}% of the charge, {d:.1}% of the whole run)\n", .{
            dup_tot,
            if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(dup_tot)) / @as(f64, @floatFromInt(tot)),
            if (c.inst_total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(dup_tot)) / @as(f64, @floatFromInt(c.inst_total)),
        }) catch {};
        var cum: u64 = 0;
        for (rows.items[0..@min(30, rows.items.len)]) |r| {
            cum += r.t.visits;
            const sym: SymbolId = @intCast(r.key >> 32);
            const d = c.prof.member_dupes.get(r.key) orelse Tally{};
            const cum_pct = if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(cum)) / @as(f64, @floatFromInt(tot));
            w.print("  {d:>10} visits {d:>6} subs  re-derived {d:>10} / {d:>6}  cum {d:>5.1}%  {s}.{s}\n", .{
                r.t.visits, r.t.calls, d.visits, d.calls, cum_pct, c.symbolName(sym), c.atomText(@truncate(r.key)),
            }) catch {};
        }
    }
    w.writeAll("\n-- expansion REUSE (was the published table ever read again?) --\n") catch {};
    {
        // Buckets over the per-reference memo-hit count. Bucket 0 is the
        // population an eager whole-table expansion cannot be defended by
        // amortization for: built once, served exactly the one consumer that
        // forced it, never read again.
        var n_built: u64 = 0;
        var n_zero: u64 = 0;
        var v_total: u64 = 0;
        var v_zero: u64 = 0;
        var hits_total: u64 = 0;
        var b1: u64 = 0;
        var b2: u64 = 0;
        var b5: u64 = 0;
        var b20: u64 = 0;
        var it = c.prof.expand_reuse.iterator();
        while (it.next()) |e| {
            const t = e.value_ptr.*;
            if (t.max_visits == 0 and t.visits == 0 and t.calls == 0) continue;
            n_built += 1;
            v_total += t.visits;
            hits_total += t.calls;
            switch (t.calls) {
                0 => {
                    n_zero += 1;
                    v_zero += t.visits;
                },
                1 => b1 += 1,
                2...4 => b2 += 1,
                5...19 => b5 += 1,
                else => b20 += 1,
            }
        }
        const pct = struct {
            fn f(a: u64, b: u64) f64 {
                return if (b == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
            }
        }.f;
        w.print("  references expanded: {d}   memo re-reads: {d}\n", .{ n_built, hits_total }) catch {};
        w.print("  re-read   0 times: {d:>7} ({d:>5.1}% of expansions, {d:>5.1}% of their node visits)\n", .{ n_zero, pct(n_zero, n_built), pct(v_zero, v_total) }) catch {};
        w.print("  re-read   1 time : {d:>7} ({d:>5.1}%)\n", .{ b1, pct(b1, n_built) }) catch {};
        w.print("  re-read  2-4     : {d:>7} ({d:>5.1}%)\n", .{ b2, pct(b2, n_built) }) catch {};
        w.print("  re-read  5-19    : {d:>7} ({d:>5.1}%)\n", .{ b5, pct(b5, n_built) }) catch {};
        w.print("  re-read 20+      : {d:>7} ({d:>5.1}%)\n", .{ b20, pct(b20, n_built) }) catch {};
    }
    w.writeAll("\n-- expansion reuse by symbol (built / never-re-read / node visits wasted) --\n") catch {};
    {
        const Agg = struct { built: u64 = 0, zero: u64 = 0, visits: u64 = 0, zero_visits: u64 = 0 };
        var by_sym: std.AutoHashMapUnmanaged(SymbolId, Agg) = .empty;
        defer by_sym.deinit(gpa);
        var it = c.prof.expand_reuse.iterator();
        while (it.next()) |e| {
            const ref = e.key_ptr.*;
            if (c.ts.kind(ref) != .ref) continue;
            const sym = c.ts.refSymbol(ref);
            const t = e.value_ptr.*;
            if (by_sym.getOrPut(gpa, sym)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.built += 1;
                gop.value_ptr.visits += t.visits;
                if (t.calls == 0) {
                    gop.value_ptr.zero += 1;
                    gop.value_ptr.zero_visits += t.visits;
                }
            } else |_| {}
        }
        const Row = struct {
            key: SymbolId,
            a: Agg,
            fn desc(_: void, x: @This(), y: @This()) bool {
                return x.a.visits > y.a.visits;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it2 = by_sym.iterator();
        while (it2.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .a = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        for (rows.items[0..@min(20, rows.items.len)]) |r| {
            w.print("  {d:>10} visits {d:>6} built {d:>6} never-re-read ({d:>10} of those visits)  ", .{
                r.a.visits, r.a.built, r.a.zero, r.a.zero_visits,
            }) catch {};
            // Distinct type arguments per POSITION. A symbol whose expansions
            // are 1,019 argument lists but only a handful of distinct values in
            // the positions a given member mentions is re-deriving that member;
            // one whose every position is nearly as wide as the expansion count
            // is not.
            var pos: [4]std.AutoHashMapUnmanaged(TypeId, void) = @splat(.empty);
            defer for (&pos) |*p| p.deinit(gpa);
            var it3 = c.prof.expand_reuse.iterator();
            while (it3.next()) |e| {
                const ref = e.key_ptr.*;
                if (c.ts.kind(ref) != .ref) continue;
                if (c.ts.refSymbol(ref) != r.key) continue;
                const n = @min(4, c.ts.refArgCount(ref));
                for (0..n) |i| pos[i].put(gpa, c.ts.refArgAt(ref, i), {}) catch {};
            }
            w.writeAll("distinct args [") catch {};
            for (&pos, 0..) |*p, i| {
                if (p.count() == 0) break;
                if (i != 0) w.writeAll("/") catch {};
                w.print("{d}", .{p.count()}) catch {};
            }
            w.writeAll("]  ") catch {};
            labelDeclSym(c, r.key, w);
            w.writeAll("\n") catch {};
        }
    }
    w.writeAll("\n-- budget trips by the declaration frame that was live --\n") catch {};
    dumpTally(SymbolId, w, gpa, &c.prof.trip_epochs, 25, labelEpoch, c) catch {};
    w.writeAll("\n-- resolveStructural() sites that forced an expansion --\n") catch {};
    dumpTally(usize, w, gpa, &c.prof.expand_sites, 25, labelSite, c) catch {};

    w.writeAll("\n-- costliest statements --\n") catch {};
    {
        std.mem.sort(Stmt, c.prof.stmts.items, {}, struct {
            fn desc(_: void, a: Stmt, b: Stmt) bool {
                return a.count > b.count;
            }
        }.desc);
        for (c.prof.stmts.items[0..@min(30, c.prof.stmts.items.len)]) |st| {
            const f = &c.prog.files[st.file];
            const line, const col = lineCol(f.src, st.pos);
            w.print("  {d:>10}  {s}:{d}:{d}\n", .{ st.count, f.path, line, col }) catch {};
        }
    }
    w.writeAll("\n(call-site addresses symbolize with: atos / llvm-symbolizer, or see the\n stack traces below)\n") catch {};
    w.flush() catch {};

    // Symbolize the hottest call sites through std.debug — one synthetic
    // one-frame stack trace each, which prints `file:line: function`.
    const Row = byVisits(usize);
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);
    var it = c.prof.sites.iterator();
    while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
    var it2 = c.prof.expand_sites.iterator();
    while (it2.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
    std.mem.sort(Row, rows.items, {}, Row.desc);
    for (rows.items[0..@min(30, rows.items.len)]) |r| {
        std.debug.print("\n[site 0x{x}] {d} visits / {d} calls\n", .{ r.key, r.t.visits, r.t.calls });
        var addrs = [_]usize{r.key};
        const st: std.debug.StackTrace = .{ .return_addresses = &addrs, .skipped = .none };
        std.debug.dumpStackTrace(&st);
    }
}

// =========================================================================
// DECLARATION-WINDOW TIME PROFILER (`--decl-profile`)
// =========================================================================
//
// A separate, much cheaper axis from everything above: not node visits and
// not budget trips, but WALL TIME, split between
//
//   * declaration materialization — the dynamic extent of an
//     `interfaceGeneric` / `classInstanceGeneric` / `aliasGeneric`
//     construction, and of an `expandRef` table construction; and
//   * everything else, i.e. source-element (statement) checking.
//
// It exists to price the *shared frozen declaration base* candidate
// (`checker.buildBaseStore`, "piece 2"): a pre-pass that materializes the
// declaration surface once and hands it to every checker would be SERIAL,
// so the declaration share of a single checker's check phase is a hard
// floor under wall clock however many checkers run afterwards.
//
// **Accounting, precisely.** A timestamp is taken only on the 0 -> 1 and
// 1 -> 0 transitions of `depth`, i.e. around the OUTERMOST window only.
// Every nested window (an `expandRef` inside a class's member table, an
// `interfaceGeneric` inside that) is inside some outermost window, so
// summing outermost durations counts each nanosecond exactly once — there
// is no double counting, and no need to subtract nested frames. The cost is
// two `Instant.now()` reads per outermost window, and there are a few
// thousand of them, so the instrument is invisible in the total (validate
// with the `clock reads` line in the report).
//
// Windows are opened AFTER the memo check in each of the four functions, so
// a memoized re-read is not a window and is charged to whatever it
// interrupted. `interfaceGeneric` calls `enterSymFile` before its memo
// check; the window still starts after it.
//
// Attribution is to the symbol that opened the OUTERMOST window, which is
// the unit a pre-pass would materialize: pre-building that symbol builds
// everything nested under it too.

// `--decl-profile` is `checker.Options.decl_prof`, read off the checker as
// `c.dprof.on`. It was a process global until it became a per-run option.

// =========================================================================
// CROSS-CHECKER DUPLICATION (`--dup-profile`)
// =========================================================================
//
// `--dup-profile` implies `--decl-profile` and adds one thing to it: for
// every memoizable declaration UNIT it records the set of OWNED files that
// ever asked for it, alongside the unit's own (nested-exclusive) build cost.
// That pair is exactly the input a partition-quality question needs.
//
// Read the run at `--checkers=1`, where the memo is global and the demand
// sets are therefore complete: a file that asks for an already-memoized unit
// still records its ask (the ask is logged BEFORE the memo check), so the
// recorded set is "every file that would have to build this unit if it were
// alone on a checker", not "the file that happened to get there first".
//
// With that in hand, the cost of ANY partition P of the owned files is
//
//     cost(P) = sum over parts p of  sum over units u with files(u) & p != {}
//                                        of  self_cost(u)
//
// and `cost({all files})` is the distinct work — the 1x floor. The ratio is
// the duplication a given partition pays, and MINIMIZING it over balanced
// partitions is the ceiling on what any better partition could ever buy.
// `bench/dup_partition.py` does that minimization off the dump.
//
// The unit is deliberately FINER than the symbol: one `expandRef` unit is
// one (symbol, argument-list) substitution, keyed by the reference's TypeId,
// which is stable within the single store a `--checkers=1` run has. Keying
// by symbol instead would charge a file that asks for one of
// `SelectQueryBuilder`'s 1,131 expansions the cost of all of them, and would
// overstate duplication by construction.
//
// The switch itself is `checker.Options.dup_prof`, read as `c.opts.dup_prof`.

const dup_kind_tag = [_]u64{ 2, 3, 4, 1, 1, 1, 1 }; // DeclKind -> key tag

/// Identity of one memoizable declaration unit. `id` is the reference's
/// TypeId for an `expandRef` window and the SYMBOL for a run-once generic
/// form; the tag keeps the two spaces apart.
pub fn dupKey(kind: DeclKind, id: u64) u64 {
    return (dup_kind_tag[@intFromEnum(kind)] << 40) | id;
}

/// Record that the live owned file demands `key`. Call at the TOP of the
/// materializing function, before its memo check — a memo hit is a demand.
pub fn declAsk(c: *Checker, sym: SymbolId, kind: DeclKind, id: u64) void {
    if (!c.opts.dup_prof) return;
    const p = &c.dprof;
    const gop = p.units.getOrPut(c.gpa, dupKey(kind, id)) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .sym = sym, .kind = kind };
    const u = gop.value_ptr;
    u.asks += 1;
    const f = c.owned_file;
    if (u.last_file == f) return;
    u.last_file = f;
    for (u.files.items) |g| if (g == f) return;
    u.files.append(c.gpa, f) catch {};
}

/// Dump the raw (unit, cost, demanding-file-set) table. Machine-read by
/// `bench/dup_partition.py`; deliberately not summarized here, because every
/// interesting question about it is a partitioning question.
fn dupReport(c: *Checker, w: *std.Io.Writer) void {
    const p = &c.dprof;
    w.writeAll("\n-- DUPDATA v1 --\n") catch {};
    var seen: std.AutoHashMapUnmanaged(FileId, void) = .empty;
    defer seen.deinit(c.gpa);
    var it0 = p.units.iterator();
    while (it0.next()) |e| for (e.value_ptr.files.items) |f| {
        _ = seen.getOrPut(c.gpa, f) catch {};
    };
    for (c.owned) |f| _ = seen.getOrPut(c.gpa, f) catch {};
    var itf = seen.keyIterator();
    while (itf.next()) |f| {
        w.print("F {d} {d} {s}\n", .{
            f.*, c.prog.files[f.*].tree.nodes.len, c.prog.files[f.*].path,
        }) catch {};
    }
    var it = p.units.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        w.print("K {d} {s} {d} {d} {d} {d} {d}", .{
            e.key_ptr.*, @tagName(u.kind), u.self_ns,         u.self_visits,
            u.builds,    u.asks,           u.files.items.len,
        }) catch {};
        for (u.files.items) |f| w.print(" {d}", .{f}) catch {};
        w.writeAll("\n") catch {};
    }
    w.writeAll("-- END DUPDATA --\n") catch {};
}

/// The four windows, with `expandRef` split by what the reference names —
/// the split the pre-pass decision turns on. `iface`/`class`/`alias` are the
/// RUN-ONCE-PER-SYMBOL generic forms (what a shared frozen base could
/// actually hold); an `expand_*` window is one SUBSTITUTION under one
/// argument list, of which a symbol has as many as its consumers ask for.
pub const DeclKind = enum(u8) {
    iface = 0,
    class = 1,
    alias = 2,
    expand_iface = 3,
    expand_class = 4,
    expand_alias = 5,
    expand_other = 6,
};
const n_kinds = 7;

/// Token returned by `declEnter`, handed back to `declExit`.
pub const DeclWin = struct { outer: bool = false };

const DeclTally = struct {
    ns: u64 = 0,
    calls: u64 = 0,
    max_ns: u64 = 0,

    fn add(t: *DeclTally, ns: u64) void {
        t.calls += 1;
        t.ns += ns;
        if (ns > t.max_ns) t.max_ns = ns;
    }
};

pub const DeclProf = struct {
    on: bool = false,
    /// Nesting depth of declaration windows.
    depth: u32 = 0,
    /// Start of the currently open OUTERMOST window, in ns.
    t0: u64 = 0,
    /// Symbol that opened the currently open outermost window.
    root: SymbolId = 0,
    root_kind: DeclKind = .iface,
    /// One entry per LIVE window, innermost last. Carries each frame's start
    /// and the time its children already consumed, so `declExit` can charge
    /// SELF time (exclusive of nested windows) to the frame's own symbol.
    stack: std.ArrayListUnmanaged(Frame) = .empty,
    /// Self (exclusive) time by symbol — the concentration measure. The
    /// inclusive-at-the-outermost-root measure (`by_sym`) is order-dependent:
    /// whichever declaration is demanded FIRST absorbs the whole cascade
    /// underneath it. Self time is not.
    self_by_sym: std.AutoHashMapUnmanaged(SymbolId, DeclTally) = .empty,
    /// Self time by kind.
    self_ns: [n_kinds]u64 = @splat(0),
    /// Sum of the outermost windows' durations. See the accounting note.
    total_ns: u64 = 0,
    /// Outermost windows opened (== clock read pairs).
    outermost: u64 = 0,
    /// Constructions by kind, at any depth (memo MISSES only).
    counts: [n_kinds]u64 = @splat(0),
    /// Outermost windows by kind, and their time.
    outer_counts: [n_kinds]u64 = @splat(0),
    outer_ns: [n_kinds]u64 = @splat(0),
    /// Outermost-window time by the root symbol that opened it.
    by_sym: std.AutoHashMapUnmanaged(SymbolId, DeclTally) = .empty,
    /// `checkStatement` / `checkExpr` entries made while a window was live —
    /// the "nested statement work" the accounting would otherwise hide.
    nested_stmts: u64 = 0,
    nested_exprs: u64 = 0,
    /// Total entries, for scale.
    total_exprs: u64 = 0,
    total_stmts: u64 = 0,
    /// OUTERMOST-under-a-window `checkExpr` entries and their inclusive time —
    /// an UPPER BOUND on the source-element-shaped work that happens inside a
    /// declaration window (upper, because a nested `expandRef` opened from
    /// inside such an expression is counted here too).
    expr_in_decl_depth: u32 = 0,
    expr_in_decl_t0: u64 = 0,
    expr_in_decl_roots: u64 = 0,
    expr_in_decl_ns: u64 = 0,
    expr_in_decl_node: u64 = 0,
    /// Those roots by source position (`file << 32 | pos`).
    expr_sites: std.AutoHashMapUnmanaged(u64, DeclTally) = .empty,
    /// `instantiate` node visits charged inside an outermost window — a
    /// second, clock-free corroboration of the time split.
    visits_t0: u64 = 0,
    visits_in_decl: u64 = 0,
    /// The whole check phase (`Checker.run`).
    run_ns: u64 = 0,
    run_t0: u64 = 0,
    /// `--dup-profile` only: one entry per memoizable declaration UNIT
    /// (`dupKey`), carrying the unit's self cost and the set of OWNED files
    /// that ever asked for it. See the cross-checker duplication section.
    units: std.AutoHashMapUnmanaged(u64, DupUnit) = .empty,

    pub fn deinit(p: *DeclProf, gpa: std.mem.Allocator) void {
        p.by_sym.deinit(gpa);
        p.self_by_sym.deinit(gpa);
        p.stack.deinit(gpa);
        p.expr_sites.deinit(gpa);
        var it = p.units.valueIterator();
        while (it.next()) |u| u.files.deinit(gpa);
        p.units.deinit(gpa);
    }

    const Frame = struct {
        sym: SymbolId,
        kind: DeclKind,
        t0: u64,
        child_ns: u64,
        /// `--dup-profile` only.
        key: u64 = 0,
        visits0: u64 = 0,
        child_visits: u64 = 0,
    };
};

/// One memoizable declaration unit, as seen by `--dup-profile`.
const DupUnit = struct {
    sym: SymbolId,
    kind: DeclKind,
    /// Self (nested-window-exclusive) cost of BUILDING it, once.
    self_ns: u64 = 0,
    self_visits: u64 = 0,
    builds: u64 = 0,
    /// Every ask, memo hit or miss.
    asks: u64 = 0,
    /// Last owned file that asked — the run-length filter that keeps the
    /// membership test off the hot path.
    last_file: FileId = std.math.maxInt(FileId),
    /// Owned files that ever asked, deduplicated.
    files: std.ArrayListUnmanaged(FileId) = .empty,
};

/// Monotonic nanoseconds. `CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on
/// Linux — the same clock `main.zig`'s phase `Timer` reads, so the check-phase
/// figure here is directly comparable with `--timing`'s.
fn nowNs(c: *Checker) u64 {
    const ts = std.Io.Clock.now(.awake, c.io);
    const ns = ts.nanoseconds;
    return if (ns > 0) @intCast(ns) else 0;
}

/// Open a declaration-materialization window for `sym`. Call AFTER the
/// memo check, so a memoized re-read is not a window.
///
/// `key` names the memoizable UNIT the window builds (see `dupKey`); it is
/// finer than `sym` for an `expandRef` window, where one symbol has as many
/// units as its consumers ask argument lists for. Read only under
/// `--dup-profile`.
pub fn declEnter(c: *Checker, sym: SymbolId, kind: DeclKind, key: u64) DeclWin {
    if (!c.dprof.on) return .{};
    const p = &c.dprof;
    p.counts[@intFromEnum(kind)] += 1;
    const outer = p.depth == 0;
    p.depth += 1;
    if (outer) {
        p.root = sym;
        p.root_kind = kind;
        p.outermost += 1;
        p.outer_counts[@intFromEnum(kind)] += 1;
        p.visits_t0 = c.inst_total;
    }
    const t0 = nowNs(c);
    if (outer) p.t0 = t0;
    p.stack.append(c.gpa, .{
        .sym = sym,
        .kind = kind,
        .t0 = t0,
        .child_ns = 0,
        .key = key,
        .visits0 = c.inst_total,
        .child_visits = 0,
    }) catch {};
    return .{ .outer = outer };
}

pub fn declExit(c: *Checker, w: DeclWin) void {
    if (!c.dprof.on) return;
    const p = &c.dprof;
    p.depth -= 1;
    const now = nowNs(c);
    if (p.stack.pop()) |fr| {
        const dur = now - fr.t0;
        const self = dur - @min(dur, fr.child_ns);
        p.self_ns[@intFromEnum(fr.kind)] += self;
        if (p.self_by_sym.getOrPut(c.gpa, fr.sym)) |gop| {
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(self);
        } else |_| {}
        if (c.opts.dup_prof) {
            const gross_visits = c.inst_total - fr.visits0;
            const self_visits = gross_visits - @min(gross_visits, fr.child_visits);
            if (p.units.getPtr(fr.key)) |u| {
                u.self_ns += self;
                u.self_visits += self_visits;
                u.builds += 1;
            }
            if (p.stack.items.len > 0) p.stack.items[p.stack.items.len - 1].child_visits += gross_visits;
        }
        if (p.stack.items.len > 0) p.stack.items[p.stack.items.len - 1].child_ns += dur;
    }
    if (!w.outer) return;
    const ns = now - p.t0;
    p.visits_in_decl += c.inst_total - p.visits_t0;
    p.total_ns += ns;
    p.outer_ns[@intFromEnum(p.root_kind)] += ns;
    if (p.by_sym.getOrPut(c.gpa, p.root)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(ns);
    } else |_| {}
}

/// A `checkStatement` entry (any depth). Self-guarded: the counter must not
/// run when the profiler is off, and callers guard too, so this is a no-op
/// either way.
pub fn noteStmtEntry(c: *Checker) void {
    if (!c.dprof.on) return;
    c.dprof.total_stmts += 1;
    if (c.dprof.depth > 0) c.dprof.nested_stmts += 1;
}

/// A `checkExpr` entry (any depth). Opens a timing window only for the
/// OUTERMOST expression entered while a declaration window is live.
/// Self-guarded, like `noteStmtEntry`; callers guard as well.
pub fn exprEnter(c: *Checker, node: u32) DeclWin {
    if (!c.dprof.on) return .{};
    c.dprof.total_exprs += 1;
    if (c.dprof.depth == 0) return .{};
    c.dprof.nested_exprs += 1;
    const outer = c.dprof.expr_in_decl_depth == 0;
    c.dprof.expr_in_decl_depth += 1;
    if (outer) {
        c.dprof.expr_in_decl_roots += 1;
        c.dprof.expr_in_decl_node = (@as(u64, c.cur_file) << 32) | c.nodeSpanStart(node);
        c.dprof.expr_in_decl_t0 = nowNs(c);
    }
    return .{ .outer = outer };
}

pub fn exprExit(c: *Checker, w: DeclWin) void {
    if (c.dprof.expr_in_decl_depth == 0) return;
    c.dprof.expr_in_decl_depth -= 1;
    if (!w.outer) return;
    const ns = nowNs(c) - c.dprof.expr_in_decl_t0;
    c.dprof.expr_in_decl_ns += ns;
    if (c.dprof.expr_sites.getOrPut(c.gpa, c.dprof.expr_in_decl_node)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(ns);
    } else |_| {}
}

pub fn declRunStart(c: *Checker) void {
    if (!c.dprof.on) return;
    c.dprof.run_t0 = nowNs(c);
}

pub fn declRunEnd(c: *Checker) void {
    if (!c.dprof.on) return;
    c.dprof.run_ns = nowNs(c) - c.dprof.run_t0;
}

fn labelDeclSym(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    w.print("{s}", .{c.symbolName(sym)}) catch {};
    const f = c.symFile(sym);
    w.print("  [{s}]", .{c.prog.files[f].path}) catch {};
}

/// Render the declaration-window profile to stderr. Called from `seal`.
pub fn declReport(c: *Checker) void {
    const gpa = c.gpa;
    var buf: [64 * 1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), c.io, &buf);
    const w = &stderr.interface;
    const p = &c.dprof;
    const run_ms = @as(f64, @floatFromInt(p.run_ns)) / 1e6;
    const decl_ms = @as(f64, @floatFromInt(p.total_ns)) / 1e6;
    w.print("\n=== ztsc declaration-window profile (checker owning {d} file(s)) ===\n", .{c.owned.len}) catch {};
    w.print("check phase (Checker.run):   {d:.1} ms\n", .{run_ms}) catch {};
    w.print("declaration windows:         {d:.1} ms  ({d:.2}% of check phase)\n", .{
        decl_ms, if (p.run_ns == 0) 0.0 else 100.0 * decl_ms / run_ms,
    }) catch {};
    w.print("source-element remainder:    {d:.1} ms\n", .{run_ms - decl_ms}) catch {};
    w.print("outermost windows: {d}  (clock reads: {d})\n", .{
        p.outermost, 2 * (p.outermost + p.expr_in_decl_roots),
    }) catch {};
    w.print("nested checkStatement entries: {d} of {d}   nested checkExpr entries: {d} of {d}\n", .{
        p.nested_stmts, p.total_stmts, p.nested_exprs, p.total_exprs,
    }) catch {};
    w.print("statement-shaped work INSIDE windows (upper bound): {d:.1} ms over {d} roots ({d:.2}% of window time)\n", .{
        @as(f64, @floatFromInt(p.expr_in_decl_ns)) / 1e6,
        p.expr_in_decl_roots,
        if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.expr_in_decl_ns)) / @as(f64, @floatFromInt(p.total_ns)),
    }) catch {};
    w.print("instantiate node visits: {d} inside windows of {d} total ({d:.2}%)\n", .{
        p.visits_in_decl,                                                                                                          c.inst_total,
        if (c.inst_total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.visits_in_decl)) / @as(f64, @floatFromInt(c.inst_total)),
    }) catch {};

    w.writeAll("\n-- constructions by kind (memo misses) --\n") catch {};
    const names = [_][]const u8{
        "interfaceGeneric", "classInstanceGeneric", "aliasGeneric",
        "expandRef/iface",  "expandRef/class",      "expandRef/alias",
        "expandRef/other",
    };
    var self_sum: u64 = 0;
    for (p.self_ns) |v| self_sum += v;
    for (names, 0..) |n, i| {
        w.print("  {s:<22} {d:>8} built  {d:>7} outermost  {d:>9.2} ms incl(outer)  {d:>9.2} ms self\n", .{
            n,                                            p.counts[i],                                 p.outer_counts[i],
            @as(f64, @floatFromInt(p.outer_ns[i])) / 1e6, @as(f64, @floatFromInt(p.self_ns[i])) / 1e6,
        }) catch {};
    }
    w.print("  self total {d:.2} ms vs outermost-inclusive total {d:.2} ms (must agree)\n", .{
        @as(f64, @floatFromInt(self_sum)) / 1e6, decl_ms,
    }) catch {};
    w.print("  run-once generic forms (iface+class+alias): {d:.2} ms = {d:.2}% of window time, {d:.2}% of check phase\n", .{
        @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / 1e6,
        if (self_sum == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / @as(f64, @floatFromInt(self_sum)),
        if (p.run_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / @as(f64, @floatFromInt(p.run_ns)),
    }) catch {};
    w.print("  memoized expansions surviving at seal: {d} (of {d} expandRef constructions)\n", .{
        c.expansions.count(), p.counts[3] + p.counts[4] + p.counts[5] + p.counts[6],
    }) catch {};

    w.writeAll("\n-- statement-shaped roots INSIDE declaration windows (top 20) --\n") catch {};
    {
        const Row = struct {
            key: u64,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.expr_sites.iterator();
        while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        for (rows.items[0..@min(20, rows.items.len)]) |r| {
            const fid: FileId = @intCast(r.key >> 32);
            const f = &c.prog.files[fid];
            const line, const col = lineCol(f.src, @truncate(r.key));
            w.print("  {d:>10.3} ms {d:>6} x  {s}:{d}:{d}\n", .{
                @as(f64, @floatFromInt(r.t.ns)) / 1e6, r.t.calls, f.path, line, col,
            }) catch {};
        }
    }

    w.writeAll("\n-- declaration-window time by root symbol (top 60) --\n") catch {};
    {
        const Row = struct {
            key: SymbolId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.by_sym.iterator();
        while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct root symbols: {d}\n", .{rows.items.len}) catch {};
        var cum: u64 = 0;
        for (rows.items[0..@min(60, rows.items.len)], 0..) |r, i| {
            cum += r.t.ns;
            w.print("  {d:>4} {d:>10.3} ms {d:>7} win  cum {d:>6.2}%  ", .{
                i + 1,
                @as(f64, @floatFromInt(r.t.ns)) / 1e6,
                r.t.calls,
                if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(cum)) / @as(f64, @floatFromInt(p.total_ns)),
            }) catch {};
            labelDeclSym(c, r.key, w);
            w.writeAll("\n") catch {};
        }
        // Concentration curve: cumulative share at a few cut points.
        w.writeAll("\n-- concentration curve (cumulative share of declaration time) --\n") catch {};
        const cuts = [_]usize{ 1, 5, 10, 20, 50, 100, 200, 400, 800, 1600, 3200 };
        var acc: u64 = 0;
        var idx: usize = 0;
        for (cuts) |k| {
            if (idx >= rows.items.len) break;
            while (idx < @min(k, rows.items.len)) : (idx += 1) acc += rows.items[idx].t.ns;
            w.print("  top {d:>5} roots: {d:>6.2}%  ({d:.1} ms)\n", .{
                @min(k, rows.items.len),
                if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(acc)) / @as(f64, @floatFromInt(p.total_ns)),
                @as(f64, @floatFromInt(acc)) / 1e6,
            }) catch {};
        }
    }

    w.writeAll("\n-- SELF (exclusive) declaration time by symbol, top 40 + concentration --\n") catch {};
    {
        const Row = struct {
            key: SymbolId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.self_by_sym.iterator();
        var tot: u64 = 0;
        while (it.next()) |e| {
            rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
            tot += e.value_ptr.ns;
        }
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct declarations: {d}   self total {d:.2} ms\n", .{
            rows.items.len, @as(f64, @floatFromInt(tot)) / 1e6,
        }) catch {};
        var cum: u64 = 0;
        for (rows.items[0..@min(40, rows.items.len)], 0..) |r, i| {
            cum += r.t.ns;
            w.print("  {d:>4} {d:>10.3} ms {d:>7} win  cum {d:>6.2}%  ", .{
                i + 1,
                @as(f64, @floatFromInt(r.t.ns)) / 1e6,
                r.t.calls,
                if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(cum)) / @as(f64, @floatFromInt(tot)),
            }) catch {};
            labelDeclSym(c, r.key, w);
            w.writeAll("\n") catch {};
        }
        w.writeAll("\n-- concentration curve on SELF time --\n") catch {};
        const cuts = [_]usize{ 1, 5, 10, 20, 50, 100, 200, 400, 800, 1600, 3200, 6400 };
        var acc: u64 = 0;
        var idx: usize = 0;
        for (cuts) |k| {
            if (idx >= rows.items.len) break;
            while (idx < @min(k, rows.items.len)) : (idx += 1) acc += rows.items[idx].t.ns;
            w.print("  top {d:>5} decls: {d:>6.2}%  ({d:.1} ms)\n", .{
                @min(k, rows.items.len),
                if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(acc)) / @as(f64, @floatFromInt(tot)),
                @as(f64, @floatFromInt(acc)) / 1e6,
            }) catch {};
        }
    }

    // Per-FILE roll-up of the same time.
    w.writeAll("\n-- SELF declaration time by originating file (top 25) --\n") catch {};
    {
        var by_file: std.AutoHashMapUnmanaged(FileId, DeclTally) = .empty;
        defer by_file.deinit(gpa);
        var it = p.self_by_sym.iterator();
        while (it.next()) |e| {
            const f = c.symFile(e.key_ptr.*);
            if (by_file.getOrPut(gpa, f)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.ns += e.value_ptr.ns;
                gop.value_ptr.calls += e.value_ptr.calls;
            } else |_| {}
        }
        const Row = struct {
            key: FileId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it2 = by_file.iterator();
        while (it2.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct files: {d}\n", .{rows.items.len}) catch {};
        for (rows.items[0..@min(25, rows.items.len)]) |r| {
            w.print("  {d:>10.3} ms {d:>7} win  {s}\n", .{
                @as(f64, @floatFromInt(r.t.ns)) / 1e6, r.t.calls, c.prog.files[r.key].path,
            }) catch {};
        }
    }
    if (c.opts.dup_prof) dupReport(c, w);
    w.flush() catch {};
}
