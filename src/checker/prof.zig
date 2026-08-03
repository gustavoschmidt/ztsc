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
//!   only to answer a yes/no structural predicate.
//! * **A single signature instantiation can exceed the whole budget.**
//!   kysely's `QueryCreator.with<N, E>` costs 316,401 node visits for ONE
//!   `instantiateSigForCall`, against a 250,000 statement budget.
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
//!   is re-paid and re-truncated forever. Revisit only after per-statement
//!   demand fits the budget.
//! * **A free-parameter Bloom summary + map-aware early-out, and narrowing
//!   the memo key to the relevant sub-map.** See the revert commit: 1.5% of
//!   visits and 498 -> 500 for the first; a 4x *increase* in distinct maps
//!   and 13% more misses for the second.

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

    pub fn deinit(p: *InstProf, gpa: std.mem.Allocator) void {
        p.sites.deinit(gpa);
        p.roots.deinit(gpa);
        p.expands.deinit(gpa);
        p.expand_sites.deinit(gpa);
        p.per_type.deinit(gpa);
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
    if (c.prof.per_type.getOrPut(c.gpa, t)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(1);
    } else |_| {}
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
