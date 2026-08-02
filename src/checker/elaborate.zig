//! Error elaboration chains: the indented "why" lines tsc prints under an
//! assignability error.
//!
//! ztsc's relation (`assign.zig`) answers one bit. tsc's answers a bit AND a
//! narrative, because every level of `isRelatedTo` carries a `reportErrors`
//! flag and pushes message fragments onto a chain as the walk unwinds. Paying
//! for that on the *success* path — the path that runs millions of times per
//! program — is exactly the trade ztsc refuses: the relation stays a bare
//! `bool` and allocates nothing.
//!
//! So the chain is reconstructed instead, and only where it is about to be
//! printed. `reportNotAssignable` has a pair it has already decided is
//! unrelated; this module re-descends that pair, at each level asking the
//! relation (`isAssignable`) which single sub-pair fails, and records the
//! property / parameter / return / index step it took. Nothing here runs
//! unless a diagnostic is being emitted, so the machinery is invisible to
//! every clean file, and errors are rare enough that the re-walk's cost is
//! noise. The re-walk asks the relation the same questions the failing walk
//! asked, so the memo answers most of them outright; nothing is written to
//! the memo that a normal query would not have written, and the memo's cached
//! `false` for the *top* pair is never consulted (we only ask about strictly
//! smaller pairs).
//!
//! ## Rendering model (reverse-engineered from tsgo 7.0.2)
//!
//! tsc does not print one line per level. Property and return steps are
//! *deferred* onto an "incompatible stack" that is flushed as a single dotted
//! path (`The types of 'a.b' are incompatible between these types.`), while
//! parameter and index-signature steps print immediately. Levels strictly
//! inside a deferred run print no line of their own. Mirrored here as:
//!
//!   - steps split into STACK kinds (property, call/construct return, tuple
//!     position) and PLAIN kinds (parameter, index signature, boundary);
//!   - a maximal run of consecutive stack steps renders as one line: the
//!     step's own message when the run is a singleton, otherwise the joined
//!     path. A singleton *return* run renders as nothing (tsc marks those
//!     messages `elidedInCompatabilityPyramid`);
//!   - a return step may not extend a run that is empty or already ends in a
//!     call, so `() => { b: { c } }` splits into `[return] [b, c]` — measured
//!     against tsgo, which differs from upstream tsc here (tsc would build
//!     `b.c` plus a secondary "Call signature return types … are
//!     incompatible" root);
//!   - the run's headline is "The types returned by" exactly when the run's
//!     SECOND entry is a return (i.e. the path's first segment is a call),
//!     which is likewise tsgo's behaviour and not upstream tsc's
//!     "path ends in `)`" test;
//!   - after each run (or plain step) the level the walk landed on prints its
//!     own `Type 'S' is not assignable to type 'T'.` line, except where a
//!     missing-property tail replaces it.
//!
//! tsgo 7.0.2 does NOT elide long chains: a 30-deep `number[]…` mismatch
//! prints all 31 lines. `max_levels` is a resource cap, not a tsc behaviour.
//!
//! Every phrasing here was copied from tsgo 7.0.2 output on a repro, never
//! invented; `checker/tests.zig` pins them as exact strings.

const std = @import("std");
const intern = @import("../intern.zig");
const types = @import("../types.zig");

const Io = std.Io;
const Atom = intern.Atom;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Deepest chain rendered. tsgo has no cutoff; this is a resource bound so a
/// pathological (or cyclic-but-unequal) type pair cannot produce an unbounded
/// message. Well past anything a real program produces.
const max_levels: usize = 48;

const StepKind = enum {
    /// `Types of property 'p' are incompatible.` — deferred onto the path.
    property,
    /// Call-signature return, both signatures parameterless.
    call_ret_noargs,
    /// Call-signature return, at least one signature takes parameters.
    call_ret_args,
    ctor_ret_noargs,
    ctor_ret_args,
    /// `Type at position N in source is not compatible with …` — deferred,
    /// but never joins a path (always a singleton run).
    tuple_pos,
    /// `Types of parameters 'a' and 'b' are incompatible.` — printed at once.
    param,
    string_index,
    number_index,
    /// A relation boundary with no message of its own (array element, union
    /// constituent, intersection member, type argument): the next level's
    /// relation line is the whole story.
    boundary,

    fn isStack(k: StepKind) bool {
        return switch (k) {
            .property, .call_ret_noargs, .call_ret_args, .ctor_ret_noargs, .ctor_ret_args, .tuple_pos => true,
            else => false,
        };
    }

    fn isReturn(k: StepKind) bool {
        return switch (k) {
            .call_ret_noargs, .call_ret_args, .ctor_ret_noargs, .ctor_ret_args => true,
            else => false,
        };
    }
};

const Step = struct {
    kind: StepKind,
    /// Property name, or the SOURCE parameter name for `.param`.
    name: Atom = 0,
    /// The TARGET parameter name for `.param`.
    name2: Atom = 0,
    /// Element index for `.tuple_pos`.
    pos: u32 = 0,
};

/// One level of the descent: the step taken into it and the pair it relates.
const Level = struct { step: Step, s: TypeId, t: TypeId };

/// How the chain ends, when it ends with something other than a plain
/// relation line.
const Tail = union(enum) {
    none,
    /// Required target properties absent from the source. REPLACES the last
    /// level's relation line (tsc suppresses it).
    missing: []const Atom,
    /// A tuple too short for its target. Prints BELOW the last level's
    /// relation line (tsc does not suppress that one).
    tuple_arity: struct { have: u32, need: u32 },
};

const Found = union(enum) { step: Level, tail: Tail };

/// The elaboration lines for a failed `s0 → t0`, ready to append to the
/// headline message: each line is `"\n"`, an indent, and the text. Empty when
/// the failure has no derivation worth showing.
///
/// Allocated in the checker's scratch arena — consume it immediately (the
/// caller formats it into the output arena via `diagFmt`).
pub fn chainText(c: *Checker, s0: TypeId, t0: TypeId) Error![]const u8 {
    var levels: std.ArrayList(Level) = .empty;
    defer levels.deinit(c.scratch());
    // Cycle guard: `interface A { n: A }` against `interface B { n: B }`
    // descends onto the same pair forever otherwise.
    var seen: std.ArrayList(u64) = .empty;
    defer seen.deinit(c.scratch());
    var tail: Tail = .none;

    var s = s0;
    var t = t0;
    while (levels.items.len < max_levels) {
        const key = (@as(u64, s) << 32) | t;
        var dup = false;
        for (seen.items) |k| {
            if (k == key) {
                dup = true;
                break;
            }
        }
        if (dup) break;
        try seen.append(c.scratch(), key);
        const found = (try findStep(c, s, t, levels.items.len)) orelse break;
        switch (found) {
            .tail => |tl| {
                tail = tl;
                break;
            },
            .step => |lv| {
                try levels.append(c.scratch(), lv);
                s = lv.s;
                t = lv.t;
            },
        }
    }
    if (levels.items.len == 0 and tail == .none) return "";
    return render(c, levels.items, tail);
}

// =====================================================================
// the descent
// =====================================================================

fn stepTo(kind: StepKind, s: TypeId, t: TypeId) Found {
    return .{ .step = .{ .step = .{ .kind = kind }, .s = s, .t = t } };
}

/// The single most informative sub-relation of a pair already known to fail,
/// or null when nothing below it explains the failure (the pair is the leaf).
///
/// Every branch is guarded by an `isAssignable` call on the sub-pair, so a
/// step is only ever taken where ztsc's own relation says "no" — the chain can
/// never claim a cause ztsc does not hold.
fn findStep(c: *Checker, s0: TypeId, t0: TypeId, depth: usize) Error!?Found {
    const store = &c.ts;

    // Two references to the same generic: tsc relates them by ARGUMENTS, and
    // reports the failing argument pair directly (`Box<number>` → `Box<string>`
    // says `Type 'number' is not assignable to type 'string'.`, not a walk
    // through `v`). Checked before `resolveStructural`, which erases the ref.
    if (c.refFacetOf(s0, store.kind(s0))) |sr| {
        if (c.refFacetOf(t0, store.kind(t0))) |tr| {
            if (sr != tr and store.refSymbol(sr) == store.refSymbol(tr)) {
                // `refArgs` borrows `extra`; `isAssignable` may intern.
                const sa = try c.scratch().dupe(TypeId, store.refArgs(sr));
                const ta = try c.scratch().dupe(TypeId, store.refArgs(tr));
                if (sa.len == ta.len) {
                    for (sa, ta) |a, b| {
                        if (a != b and !try c.isAssignable(a, b)) return stepTo(.boundary, a, b);
                    }
                }
            }
        }
    }

    const s = try c.resolveStructural(s0);
    const t = try c.resolveStructural(t0);
    switch (store.kind(s)) {
        .err, .none, .any, .never => return null,
        else => {},
    }
    switch (store.kind(t)) {
        .err, .none, .any, .unknown => return null,
        else => {},
    }

    // A union SOURCE relates member-wise: report the first member that fails.
    // When the target is a union too, the member goes straight to the target
    // constituent that best matches it — tsgo prints one line for the pair,
    // not one for the member-against-the-whole-union and another for the
    // member-against-the-match.
    if (store.kind(s) == .union_type) {
        const members = try c.scratch().dupe(TypeId, try c.memberList(s));
        for (members) |m| {
            if (try c.isAssignable(m, t0)) continue;
            if (try bestUnionMatch(c, m, t)) |best| return stepTo(.boundary, m, best);
            return stepTo(.boundary, m, t0);
        }
        return null;
    }

    if (try bestUnionMatch(c, s0, t)) |best| return stepTo(.boundary, s0, best);

    // An intersection TARGET must be satisfied member-wise.
    if (store.kind(t) == .intersection) {
        const members = try c.scratch().dupe(TypeId, try c.memberList(t));
        for (members) |m| {
            if (!try c.isAssignable(s0, m)) return stepTo(.boundary, s0, m);
        }
        return null;
    }

    if (store.kind(s) == .array and store.kind(t) == .array) {
        const se = store.arrayElem(s);
        const te = store.arrayElem(t);
        if (!try c.isAssignable(se, te)) return stepTo(.boundary, se, te);
        return null;
    }

    if (store.kind(s) == .tuple and store.kind(t) == .tuple) {
        const sl = store.tupleLen(s);
        const tl = store.tupleLen(t);
        var need: u32 = 0;
        var fixed = true;
        for (0..tl) |i| {
            const e = store.tupleElem(t, @intCast(i));
            if (e.rest()) fixed = false else if (!e.optional()) need += 1;
        }
        for (0..sl) |i| {
            if (store.tupleElem(s, @intCast(i)).rest()) fixed = false;
        }
        if (fixed and sl < need) {
            return .{ .tail = .{ .tuple_arity = .{ .have = sl, .need = need } } };
        }
        var i: u32 = 0;
        while (i < @min(sl, tl)) : (i += 1) {
            const se = store.tupleElem(s, i).ty;
            const te = store.tupleElem(t, i).ty;
            if (!try c.isAssignable(se, te)) {
                return .{ .step = .{
                    .step = .{ .kind = .tuple_pos, .pos = i },
                    .s = se,
                    .t = te,
                } };
            }
        }
        return null;
    }

    // --- object target: properties, then signatures, then index signatures.
    // tsc's `structuredTypeRelatedTo` order, and the order the messages must
    // nest in.
    if (store.kind(t) == .object) {
        if (try propertyStep(c, s0, s, t, depth)) |f| return f;
    }

    if (try signatureStep(c, s, t, false)) |f| return f;
    if (try signatureStep(c, s, t, true)) |f| return f;

    if (store.kind(t) == .object and store.kind(s) == .object) {
        const tsi = store.objectStringIndex(t);
        const ssi = store.objectStringIndex(s);
        if (tsi != 0 and ssi != 0 and !try c.isAssignable(ssi, tsi)) {
            return stepTo(.string_index, ssi, tsi);
        }
        const tni = store.objectNumberIndex(t);
        const sni = store.objectNumberIndex(s);
        if (tni != 0 and sni != 0 and !try c.isAssignable(sni, tni)) {
            return stepTo(.number_index, sni, tni);
        }
    }
    return null;
}

/// tsc's `getBestMatchingType`: the constituent of a union TARGET that a
/// source should be blamed against. tsc stays silent when nothing matches —
/// which is why `boolean → string | number` stops at one line — so this
/// returns null unless an object constituent actually shares property names
/// with the source (`findMostOverlappyType`), and unless relating to it fails.
/// `t` must already be `resolveStructural`ed; `s` need not be.
fn bestUnionMatch(c: *Checker, s: TypeId, t: TypeId) Error!?TypeId {
    const store = &c.ts;
    if (store.kind(t) != .union_type) return null;
    const rs = try c.resolveStructural(s);
    if (store.kind(rs) != .object) return null;
    const members = try c.scratch().dupe(TypeId, try c.memberList(t));
    var best: TypeId = 0;
    var best_score: u32 = 0;
    for (members) |m| {
        const rm = try c.resolveStructural(m);
        if (store.kind(rm) != .object) continue;
        var score: u32 = 0;
        for (0..store.objectPropCount(rm)) |i| {
            const p = store.objectProp(rm, @intCast(i));
            if ((try c.propOfTypeEx(s, p.name, false)) != null) score += 1;
        }
        if (score > best_score) {
            best_score = score;
            best = m;
        }
    }
    if (best_score == 0) return null;
    if (try c.isAssignable(s, best)) return null;
    return best;
}

/// A missing required property (the chain's tail) or the first incompatible
/// one (a `.property` step).
fn propertyStep(c: *Checker, s0: TypeId, s: TypeId, t: TypeId, depth: usize) Error!?Found {
    const store = &c.ts;
    const objecty = switch (store.kind(s)) {
        .object, .intersection => true,
        else => false,
    };
    if (!objecty) return null;
    const n = store.objectPropCount(t);

    // tsc checks for an UNMATCHED property before relating any matched one.
    // Skipped at depth 0: there the caller has already morphed the headline
    // into TS2741/TS2739 (`tryReportMissingProps`), so repeating it would
    // print the same sentence twice.
    if (depth > 0) {
        var missing: std.ArrayList(Atom) = .empty;
        for (0..n) |i| {
            const tp = store.objectProp(t, @intCast(i));
            if (tp.optional()) continue;
            if ((try c.propOfTypeEx(s0, tp.name, false)) == null) {
                try missing.append(c.scratch(), tp.name);
            }
        }
        if (missing.items.len > 0) {
            std.mem.sort(Atom, missing.items, c, atomTextLess);
            return .{ .tail = .{ .missing = missing.items } };
        }
    }

    // The first incompatible property, in name-TEXT order. The stored order is
    // by name ATOM, i.e. by interning order, which depends on how the program
    // was partitioned across checker instances — text order keeps the rendered
    // message a function of the program alone (the determinism contract
    // `tryReportMissingProps` observes for the same reason).
    var best_name: Atom = 0;
    var best_s: TypeId = 0;
    var best_t: TypeId = 0;
    var have = false;
    for (0..n) |i| {
        const tp = store.objectProp(t, @intCast(i));
        const sp = (try c.propOfTypeEx(s0, tp.name, false)) orelse continue;
        var st = sp.ty;
        if (sp.optional()) st = try c.makeUnion2(st, types.undefined_type);
        var tt = tp.ty;
        if (tp.optional()) tt = try c.makeUnion2(tt, types.undefined_type);
        if (try c.isAssignable(st, tt)) continue;
        if (have and !std.mem.lessThan(u8, c.atomText(tp.name), c.atomText(best_name))) continue;
        have = true;
        best_name = tp.name;
        best_s = st;
        best_t = tt;
    }
    if (!have) return null;
    return .{ .step = .{
        .step = .{ .kind = .property, .name = best_name },
        .s = best_s,
        .t = best_t,
    } };
}

fn atomTextLess(c: *Checker, a: Atom, b: Atom) bool {
    return std.mem.order(u8, c.atomText(a), c.atomText(b)) == .lt;
}

/// The single call (or construct) signature of `ty`, when it has exactly one.
/// tsc only elaborates the 1-vs-1 case; with overload sets it cannot say which
/// signature was meant, and neither can we.
fn singleSig(c: *Checker, ty: TypeId, is_ctor: bool) ?TypeId {
    const store = &c.ts;
    switch (store.kind(ty)) {
        .function => return if (is_ctor) null else ty,
        .object => {
            const n = if (is_ctor) store.objectConstructSigCount(ty) else store.objectCallSigCount(ty);
            if (n != 1) return null;
            return if (is_ctor) store.objectConstructSig(ty, 0) else store.objectCallSig(ty, 0);
        },
        else => return null,
    }
}

fn signatureStep(c: *Checker, s: TypeId, t: TypeId, is_ctor: bool) Error!?Found {
    const store = &c.ts;
    const ss = singleSig(c, s, is_ctor) orelse return null;
    const ts_ = singleSig(c, t, is_ctor) orelse return null;
    const sn = store.fnParamCount(ss);
    const tn = store.fnParamCount(ts_);
    // A method's parameters relate bivariantly (`fn_flag_method`), so only a
    // pair that fails BOTH ways is what made the relation fail.
    const bivariant = (store.fnFlags(ss) & types.fn_flag_method) != 0 or
        (store.fnFlags(ts_) & types.fn_flag_method) != 0;
    var i: u32 = 0;
    while (i < @min(sn, tn)) : (i += 1) {
        const sp = store.fnParam(ss, i);
        const tp = store.fnParam(ts_, i);
        if (sp.rest() or tp.rest()) break;
        // Parameters are contravariant: the TARGET's parameter type has to be
        // accepted by the SOURCE's, and that is the pair tsc reports.
        if (try c.isAssignable(tp.ty, sp.ty)) continue;
        if (bivariant and try c.isAssignable(sp.ty, tp.ty)) continue;
        return .{ .step = .{
            .step = .{ .kind = .param, .name = sp.name, .name2 = tp.name },
            .s = tp.ty,
            .t = sp.ty,
        } };
    }
    const sret = store.fnReturn(ss);
    const tret = store.fnReturn(ts_);
    switch (store.kind(tret)) {
        .void, .any, .none, .err => return null,
        else => {},
    }
    if (try c.isAssignable(sret, tret)) return null;
    const noargs = sn == 0 and tn == 0;
    const kind: StepKind = if (is_ctor)
        (if (noargs) .ctor_ret_noargs else .ctor_ret_args)
    else
        (if (noargs) .call_ret_noargs else .call_ret_args);
    return stepTo(kind, sret, tret);
}

// =====================================================================
// rendering
// =====================================================================

/// May a run already holding `run` absorb `next`?
fn runAccepts(run: []const Level, next: Step) bool {
    const first = run[0].step.kind;
    const last = run[run.len - 1].step.kind;
    // A tuple position never shares a path with anything.
    if (last == .tuple_pos or next.kind == .tuple_pos) return false;
    // A run that OPENS with a return has an empty path, and tsgo closes it
    // there rather than carrying the call into the following segments.
    if (first.isReturn()) return false;
    // Nor may one call follow another in the same path.
    if (next.kind.isReturn()) return !last.isReturn();
    return true;
}

fn render(c: *Checker, levels: []const Level, tail: Tail) Error![]const u8 {
    var out: Io.Writer.Allocating = .init(c.scratch());
    var indent: usize = 2;
    var i: usize = 0;
    while (i < levels.len) {
        const kind = levels[i].step.kind;
        if (kind.isStack()) {
            var j = i;
            while (j + 1 < levels.len and levels[j + 1].step.kind.isStack() and
                runAccepts(levels[i .. j + 1], levels[j + 1].step)) j += 1;
            try writeRun(c, &out.writer, &indent, levels[i .. j + 1]);
            i = j;
        } else {
            try writeStepMessage(c, &out.writer, &indent, levels[i].step);
        }
        if (i + 1 == levels.len and tail == .missing) {
            try writeMissing(c, &out.writer, &indent, levels[i].s, levels[i].t, tail.missing);
        } else {
            try writeRelation(c, &out.writer, &indent, levels[i].s, levels[i].t);
        }
        i += 1;
    }
    if (tail == .tuple_arity) {
        try line(&out.writer, &indent, "Source has {d} element(s) but target requires {d}.", .{
            tail.tuple_arity.have, tail.tuple_arity.need,
        });
    }
    return out.written();
}

fn line(w: *Io.Writer, indent: *usize, comptime fmt: []const u8, args: anytype) Error!void {
    w.writeByte('\n') catch return error.OutOfMemory;
    w.splatByteAll(' ', indent.*) catch return error.OutOfMemory;
    w.print(fmt, args) catch return error.OutOfMemory;
    indent.* += 2;
}

fn writeRelation(c: *Checker, w: *Io.Writer, indent: *usize, s: TypeId, t: TypeId) Error!void {
    try line(w, indent, "Type '{s}' is not assignable to type '{s}'.", .{
        try c.typeToString(s), try c.typeToString(t),
    });
}

fn writeMissing(c: *Checker, w: *Io.Writer, indent: *usize, s: TypeId, t: TypeId, names: []const Atom) Error!void {
    if (names.len == 1) {
        try line(w, indent, "Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{
            c.atomText(names[0]), try c.typeToString(s), try c.typeToString(t),
        });
        return;
    }
    try line(w, indent, "Type '{s}' is missing the following properties from type '{s}': {s}", .{
        try c.typeToString(s), try c.typeToString(t), try missingList(c, names),
    });
}

/// The name list of the missing-properties message. Past five names tsc names
/// only the first four and counts the rest — and switches its error code from
/// TS2739 to TS2740, which `missingPropsCode` reports.
pub fn missingList(c: *Checker, names: []const Atom) Error![]const u8 {
    var list: Io.Writer.Allocating = .init(c.scratch());
    defer list.deinit();
    const shown = if (names.len > 5) @as(usize, 4) else names.len;
    for (names[0..shown], 0..) |a, i| {
        if (i > 0) list.writer.writeAll(", ") catch return error.OutOfMemory;
        list.writer.writeAll(c.atomText(a)) catch return error.OutOfMemory;
    }
    if (names.len > 5) {
        list.writer.print(", and {d} more.", .{names.len - shown}) catch return error.OutOfMemory;
    }
    return c.scratch().dupe(u8, list.written());
}

/// TS2739, or TS2740 once the list is long enough to be abbreviated.
pub fn missingPropsCode(count: usize) u16 {
    return if (count > 5) 2740 else 2739;
}

fn writeStepMessage(c: *Checker, w: *Io.Writer, indent: *usize, step: Step) Error!void {
    switch (step.kind) {
        .param => try line(w, indent, "Types of parameters '{s}' and '{s}' are incompatible.", .{
            c.atomText(step.name), c.atomText(step.name2),
        }),
        .string_index => try line(w, indent, "'string' index signatures are incompatible.", .{}),
        .number_index => try line(w, indent, "'number' index signatures are incompatible.", .{}),
        .boundary => {},
        else => unreachable,
    }
}

fn writeRun(c: *Checker, w: *Io.Writer, indent: *usize, run: []const Level) Error!void {
    if (run.len == 1) {
        const step = run[0].step;
        switch (step.kind) {
            // tsc marks the bare return-type messages `elidedInCompatabilityPyramid`:
            // alone they say nothing the two relation lines around them do not.
            .call_ret_noargs, .call_ret_args, .ctor_ret_noargs, .ctor_ret_args => {},
            .property => try line(w, indent, "Types of property '{s}' are incompatible.", .{
                try propDisplay(c, step.name),
            }),
            .tuple_pos => try line(
                w,
                indent,
                "Type at position {d} in source is not compatible with type at position {d} in target.",
                .{ step.pos, step.pos },
            ),
            else => unreachable,
        }
        return;
    }
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(c.scratch());
    for (run) |lv| {
        switch (lv.step.kind) {
            .property => {
                // A path that is currently a constructor call needs wrapping
                // before a member access: `new mk()` → `(new mk()).b`.
                if (std.mem.startsWith(u8, path.items, "new ")) {
                    try path.insert(c.scratch(), 0, '(');
                    try path.append(c.scratch(), ')');
                }
                const text = c.atomText(lv.step.name);
                if (needsBrackets(text)) {
                    try path.appendSlice(c.scratch(), "[\"");
                    try path.appendSlice(c.scratch(), text);
                    try path.appendSlice(c.scratch(), "\"]");
                } else {
                    if (path.items.len > 0) try path.append(c.scratch(), '.');
                    try path.appendSlice(c.scratch(), text);
                }
            },
            .call_ret_noargs => try path.appendSlice(c.scratch(), "()"),
            .call_ret_args => try path.appendSlice(c.scratch(), "(...)"),
            .ctor_ret_noargs, .ctor_ret_args => {
                try path.insertSlice(c.scratch(), 0, "new ");
                try path.appendSlice(c.scratch(), if (lv.step.kind == .ctor_ret_noargs) "()" else "(...)");
            },
            else => unreachable,
        }
    }
    // "returned by" exactly when the path's FIRST segment is a call.
    if (run[1].step.kind.isReturn()) {
        try line(w, indent, "The types returned by '{s}' are incompatible between these types.", .{path.items});
    } else {
        try line(w, indent, "The types of '{s}' are incompatible between these types.", .{path.items});
    }
}

/// A property name as tsc's `symbolToString` renders it inside a message:
/// bare when it is spellable as an identifier (or a plain number), quoted
/// otherwise.
fn propDisplay(c: *Checker, name: Atom) Error![]const u8 {
    const text = c.atomText(name);
    if (!needsBrackets(text)) return text;
    return std.fmt.allocPrint(c.scratch(), "\"{s}\"", .{text});
}

fn needsBrackets(text: []const u8) bool {
    return !isIdentifierText(text) and !isNumericText(text);
}

fn isIdentifierText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text, 0..) |ch, i| {
        const ok = std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$' or
            (i > 0 and std.ascii.isDigit(ch));
        if (!ok) return false;
    }
    return true;
}

fn isNumericText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}
