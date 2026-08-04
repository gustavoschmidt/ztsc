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
//! ## What it has already established (immich / kysely, 2026-08-03)
//!
//! Repro: one kysely builder chain against immich's `DB`, 110 files pulled in
//! by its imports; `--checkers=1 --inst-profile`. 5.07 M node visits, 2.62 M
//! of them memo misses, 1,674 budget trips.
//!
//! * **Demand is spread, not concentrated.** `expandRef`'s
//!   `instantiate(interfaceGeneric, args)` is 52% (2.58 M over 4,004 calls),
//!   `instantiateSigForCall` 19%, `eraseParamsOf` 22%, `baseConstraintOf` 5%.
//!   No single call site is a keystone; a fix has to be structural.
//! * **The memo already catches the repeats — what is left is unique work.**
//!   59.5 k distinct types are instantiated under 120 k distinct substitution
//!   maps, 44 misses per distinct type. Better *caching* has nothing left to
//!   win; only doing less work does.
//! * **The expansions are forced by the relation and inference machinery,**
//!   not by member access: `isAssignableInner` (1.06 M), `paramAcceptsVoid`
//!   (485 k), `unify` (442 k), `inferFromExtendsInner` (413 k),
//!   `isArrayShaped` (361 k), `isGenericObjectForIndex` (324 k),
//!   `typeHasMapped` (310 k) — several of which expand a whole member table
//!   only to answer a yes/no structural predicate. Four of them no longer
//!   do (`refExpandsToObject`); what is left — `isAssignableInner`, `unify`,
//!   `inferFromExtendsInner`, `propertyTypeOf` — genuinely reads members.
//! * **A single signature instantiation can exceed the whole budget.**
//!   kysely's `QueryCreator.with<N, E>` costs 316,401 node visits for ONE
//!   `instantiateSigForCall`, against a 250,000 statement budget.
//!   `--inst-focus` on that entry showed it is NOT a runaway substitution of
//!   the signature: its own params and return type are references and cost
//!   nothing. It is the reductions the substitution triggers —
//!   `ExtractRowFromCommonTableExpression<E>` matching the callback's return
//!   against `Expression<infer QO>` and three builder interfaces — each of
//!   which calls `resolveStructural` and expands a whole kysely builder
//!   table, charged to the enclosing top-level entry because `expandRef`
//!   runs at `inst_depth > 0`. So the outlier is the SAME problem as the
//!   predicates, not a separate bug: ~1,400 expansions of two builder
//!   interfaces at ~1,500 visits each, under distinct argument lists.
//!   Its own histogram is a long flat tail (top subterm 1,583 visits of
//!   219 k), every visit a memo MISS under a distinct substitution map.
//!
//! ## Ruled out, with numbers (do not re-run these)
//!
//! * **Raising the budget.** At tsc's own constant (5 M instead of 250 k):
//!   41 s wall (from 3.5 s) and immich excess got WORSE, 498 -> 556, with
//!   TS7006 nearly doubling (108 -> 187). Excess is not monotone in the
//!   budget — the intermediate regime just moves which materializations come
//!   back truncated, and a lost contextual parameter type costs more
//!   diagnostics than a lost deep instantiation.
//! * **Lazy per-member instantiation of an interface reference** (tsc's
//!   `createInstantiatedSymbolTable`; read one member out of the memoized
//!   generic table and substitute only it, instead of expanding all ~50).
//!   Structurally correct and it does cut work (5.28 M -> 4.89 M visits, 315
//!   fewer expansions), but immich went 498 -> 567: it removes the
//!   *amortization* that `expansions` provides. Today one statement pays for
//!   a builder interface's whole table and every later statement reads it
//!   free; per-member, each statement pays for its own members, and any
//!   member whose substitution is truncated is never memoized at all, so it
//!   is re-paid and re-truncated forever.
//! * **The same laziness PAIRED with a per-`(ref, member)` memo** that
//!   restores the amortization at member granularity — one substitution per
//!   `(ref, member)` for the whole run, never published when the
//!   substitution truncated (the `inst_limit_tripped` subtree rule
//!   `eraseParamsOf` follows). It does cut work — immich wall 3.82 -> 3.58 s,
//!   peak RSS 1.59 -> 1.26 GB, the kysely repro 4.92 M -> 4.53 M node visits,
//!   `SelectQueryBuilder` expansions 694 -> 609 — and immich still went
//!   497 -> 566, the same magnitude and the same family (96 new TS7006) as
//!   the un-memoized attempt. **The memo was not the missing piece, and
//!   amortization was not the mechanism.**
//!
//!   The mechanism is BUDGET TIMING. An eager expansion at the member-access
//!   site runs EARLY in a source element, while `inst_count` is still low, so
//!   the table completes and is memoized complete for the rest of the run —
//!   the eager expansion is a cheap prepayment. Read one member instead and
//!   the element runs much deeper before anything forces the table; the first
//!   consumer that does force it is `isAssignableInner` / `unify` /
//!   `inferFromExtendsInner`, deep inside a walk with the budget nearly
//!   spent, so the table comes back TRUNCATED — and `expandRef` publishes
//!   that truncation as the answer for every later reader. Corroborating:
//!   per-symbol expansion cost RISES under laziness even as the count falls
//!   (`ZodObject` 230 calls / 241 k visits -> 221 / 332 k, max 8,379 ->
//!   32,296), because the eager table also warmed `inst_cache` for what the
//!   later consumers ask.
//!
//!   The 2x2 is measured, and today's cell is the best one on excess
//!   (immich excess / wall):
//!
//!   | | eager | lazy + memo |
//!   |---|---|---|
//!   | publish truncated (today) | **497 / 3.8 s** | 566 / 3.6 s |
//!   | withdraw truncated | 522 / 4.2 s | 530 / 4.3 s |
//!   | own budget epoch | 503 / 8.0 s | 501 / 7.2 s |
//!
//!   Routing the memo only from `propOfTypeEx` — the half of the earlier
//!   route bisect that read neutral — is a literal no-op: byte-identical
//!   visits (4,923,741) and an identical key set, because `isAssignableInner`
//!   resolves BOTH sides with `resolveStructural` before the property loop
//!   ever sees a `.ref`. Nothing is winnable on that route without changing
//!   the relation itself.
//!
//!   What would have to change first: the relation and inference sites must
//!   stop forcing whole tables, which is tsc's actual split (symbols eagerly,
//!   types lazily) and not reachable from member access. Member-access
//!   laziness alone reaches only `propertyTypeOf`'s share of the forcing
//!   sites — 1.14 M visits of 6.0 M charged, 12% of expansions — while
//!   `checkClass` (1.90 M / 118), `inferFromExtendsInner` (476 k + 160 k),
//!   `callbackSigOf` (454 k), `isAssignableInner` (383 k + 192 k + 135 k) and
//!   `unify` (350 k + 125 k) still expand.
//! * **A free-parameter Bloom summary + map-aware early-out, and narrowing
//!   the memo key to the relevant sub-map.** See the revert commit: 1.5% of
//!   visits and 498 -> 500 for the first; a 4x *increase* in distinct maps
//!   and 13% more misses for the second.
//! * **Refusing to memoize a TRUNCATED expansion** (`expandRef`), scoped to
//!   the budget epoch that truncated it so the element that paid still
//!   amortizes its own re-reads. Aimed at the cross-partition divergence,
//!   which it does dent (c1^c8 108 -> 83, c4^c8 34 -> 31, c1^c4 unchanged),
//!   but the causation runs the wrong way: the next reader re-expands, the
//!   re-expansion is charged to ITS budget, and more statements trip.
//!   immich 496 -> 522, wall 3.4 -> 4.2 s, and the 26 new keys are a
//!   truncation signature (TS2589 plus its TS7006/TS2769 cascade), not
//!   hidden diagnostics. See the revert commit.
//! * **Giving each `expandRef` its own budget epoch** — which DOES make the
//!   table a function of the ref (`enterSymFile`'s rule, one layer down) and
//!   is the right answer in principle. 503 excess but wall 3.4 -> 8.0 s and
//!   peak RSS 1.58 -> 2.66 GB; charging the cost back to the outer element
//!   on exit lands at 512 excess, 5.9 s, 1.96 GB. The extra time is real
//!   work: tables that used to come back truncated now complete.
//!
//!   Re-measured on top of the per-member memo above, which was supposed to
//!   be its precondition: 501 excess, 7.23 s, 2.51 GB. Laziness buys the
//!   epoch 10% of its wall and two keys — it is not the lever. Neither is
//!   BOUNDING the epoch: capping one table at 24,000 visits instead of the
//!   full 250,000 lands on the same 501 at 7.13 s / 1.90 GB, because the cost
//!   is not a few enormous tables but the many ordinary ones (1.5 k - 15 k
//!   visits each) that used to come back truncated. On the kysely repro the
//!   epoch simply doubles the work: 4.92 M -> 9.47 M node visits, budget
//!   trips 1,750 -> 18,104. Read the other way, ztsc's immich wall is today
//!   partly BOUGHT by truncation, and the epoch costs exactly what the
//!   truncation was saving.
//! * **The one `instantiateId` arm that turns the memo off for a whole
//!   subtree** (`cond_check_subst`, the second distribution rule, which
//!   re-walks the branches once per union constituent with `map_id = null`).
//!   A plausible-looking suspect for the `with<N, E>` outlier, and the
//!   counter in the report header ruled it out: 32 k of 5.23 M visits.
//!
//! ## What LANDED: the lazy member layer (`lazyShapeOf` / `lazyTableOf`)
//!
//! The negatives above were all measured on the kysely mini-repro, where
//! `expandRef` is 52% of the demand and the forcing sites are the relation and
//! inference walks. Profiled on the WHOLE immich server package the ranking is
//! different, and the answer was in the part of the split the earlier attempts
//! never reached — the consumers that materialize a member table and then read
//! nothing off it but NAMES:
//!
//!     keyofType           8.08 M visits / 184 calls
//!     propertyTypeOf      3.36 M / 1,962
//!     expandRef itself    2.47 M / 8,324
//!     isCallableSource    1.57 M / 1,324
//!     callbackSigOf       1.12 M / 238
//!
//! `instantiateId`'s `.object` arm substitutes `Prop.ty` and copies
//! `Prop.name` and `Prop.flags` through untouched, so a member table's names,
//! optionality, readonly-ness, `private`/`protected`-ness, property COUNT and
//! index-signature PRESENCE are all functions of the generic table alone.
//! Every question above is answerable off it: `keyof` enumerates names,
//! `isWeakType` asks whether every property is optional, `isCallableSource`
//! and `callbackSigOf` ask whether the shape has properties. Converting those
//! five took immich 461 -> 458 excess with total node visits 11.99 M ->
//! 10.55 M (-12%), budget trips 12,501 -> 11,095, user CPU 12.4 s -> 11.0 s
//! and peak RSS 1.83 -> 1.81 GB, with excalidraw still CONVERGED at 17/0/0 and
//! parity 8/8 at 0/0.
//!
//! Signature counts are the one thing that does NOT carry through
//! (`higherOrderSigEligible` drops a higher-order signature the substitution
//! cannot rewrite), so a table that has any stays on the eager path.
//!
//! **The load-bearing rule, and it is not obvious: the lazy route may READ a
//! generic member table but must never BUILD one.** Materializing a table is
//! not a pure function of the symbol — it runs the declaration walk under
//! `enterSymFile`, folds `extends` bases, resolves every member's annotation
//! and can re-enter the very reference being asked about — and `expandRef`
//! marks `expansions[ref]` in progress before it starts, so a table built from
//! anywhere else is built outside that mark. Hoisting the construction into
//! `keyofType` alone (nothing else changed, the key set it computed was
//! byte-identical every time) took the excalidraw sweep from 17 diagnostics to
//! 279. Reading a table an earlier `expandRef` already built has no such
//! effect, and it is the case that pays: a generic interface is materialized
//! once and read thousands of times.
//!
//! Still eager, in demand order, and the next places to look:
//! `propertyTypeOf` (3.45 M — the member-access route, whose laziness is the
//! measured negative above), `expandRef` itself (2.17 M), `isAssignableInner`
//! (931 k + 441 k + 168 k), `eraseParamsOf` (604 k), `inferFromExtendsInner`
//! (490 k + 252 k + 164 k), `typeParamAtTopLevel` (483 k), `unify` (456 k +
//! 397 k), `isArrayShaped` (333 k).

const std = @import("std");
const types = @import("../types.zig");
const binder = @import("../frontend/binder.zig");

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const TypeId = types.TypeId;
const SymbolId = binder.SymbolId;
const FileId = u32;

/// Process-global switch, set once by `main` from `--inst-profile` before any
/// checker thread starts, and read once per `Checker.init`. Write-once before
/// the pool spawns, so no synchronization is needed.
pub var profile_on: bool = false;

/// `--inst-focus=<type-id>`: the ONE root type whose substitution the
/// per-type histogram should be restricted to. The unrestricted histogram
/// answers "which subterm does this run re-walk most", which a run-wide sum
/// answers badly when one top-level entry is itself the outlier — read a
/// root's id out of the `by root type` section and feed it back here to get
/// that entry's own breakdown. Write-once alongside `profile_on`.
pub var focus_root: TypeId = 0;

/// Whether the profiler is enabled for this process.
pub fn enabled() bool {
    return profile_on;
}

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
    /// Non-zero while a top-level `instantiate` of `focus_root` is live —
    /// see `focus_root`. Nested so a re-entrant focused root still counts.
    focus_depth: u32 = 0,
    /// `per_type`, restricted to visits charged under `focus_root`. The
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

    pub fn deinit(p: *InstProf, gpa: std.mem.Allocator) void {
        p.sites.deinit(gpa);
        p.roots.deinit(gpa);
        p.expands.deinit(gpa);
        p.expand_sites.deinit(gpa);
        p.per_type.deinit(gpa);
        p.focus_types.deinit(gpa);
        p.stmts.deinit(gpa);
    }
};

/// Charge one top-level `instantiate` of `t` costing `visits` node visits to
/// the call site `ret_addr`.
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
/// `focus_root`). Returns whether this entry opened one.
pub fn focusEnter(c: *Checker, t: TypeId) bool {
    if (focus_root == 0 or t != focus_root) return false;
    c.prof.focus_depth += 1;
    return true;
}

pub fn focusExit(c: *Checker) void {
    c.prof.focus_depth -= 1;
}

/// Charge one `resolveStructural` that forced an expansion to its call site.
pub fn noteExpandSite(c: *Checker, ret_addr: usize, visits: u64) void {
    if (c.prof.expand_sites.getOrPut(c.gpa, ret_addr)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one `expandRef` of a `sym`-rooted reference costing `visits`.
pub fn noteExpand(c: *Checker, sym: SymbolId, visits: u64) void {
    if (c.prof.expands.getOrPut(c.gpa, sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Record the budget one statement spent (called at the next statement's
/// reset, so the count is final).
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
    if (focus_root != 0) {
        w.print("\n-- visits under root #{d} only, by type --\n", .{focus_root}) catch {};
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
