//! Type printing (diagnostic display strings).
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const binder = @import("../frontend/binder.zig");
const types = @import("../types.zig");

const Io = std.Io;
const SymbolId = binder.SymbolId;
const TypeId = types.TypeId;

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const max_type_string = checker_zig.max_type_string;

const hasValueMeaning = @import("names.zig").hasValueMeaning;
const scratch = Checker.scratch;

// =====================================================================
// type printing
// =====================================================================

/// Render `t` tsc-style into the output arena (for messages).
pub fn typeToString(c: *Checker, t: TypeId) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(c.out);
    defer aw.deinit();
    c.printType(&aw.writer, t, 0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    var s = aw.written();
    if (s.len > max_type_string) {
        s = s[0..max_type_string];
    }
    return c.out.dupe(u8, s);
}

/// The printer's error set deliberately EXCLUDES `Error.OutOfMemory`, so no
/// `Error!` (interning) function is reachable from it with `try` — which is
/// why the printers may hold borrowed `members`/`refArgs`/`fnTypeParams`
/// slices across their recursion. Keep it that way.
pub const PrintErr = std.Io.Writer.Error;

pub fn printType(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32) PrintErr!void {
    if (t == types.no_type) return w.writeAll("any");
    if (depth > 6) return w.writeAll("...");
    const s = &c.ts;
    switch (s.kind(t)) {
        .none => try w.writeAll("any"),
        .any, .err => try w.writeAll("any"),
        .unknown => try w.writeAll("unknown"),
        .never => try w.writeAll("never"),
        .void => try w.writeAll("void"),
        .undefined => try w.writeAll("undefined"),
        .null => try w.writeAll("null"),
        .string => try w.writeAll("string"),
        .number => try w.writeAll("number"),
        .boolean => try w.writeAll("boolean"),
        .bigint => try w.writeAll("bigint"),
        .symbol => try w.writeAll("symbol"),
        .unique_symbol => try w.writeAll("unique symbol"),
        .object_keyword => try w.writeAll("object"),
        .bool_true => try w.writeAll("true"),
        .bool_false => try w.writeAll("false"),
        .string_literal => try w.print("\"{s}\"", .{c.atomText(s.literalAtom(t))}),
        .bigint_literal => try w.print("{s}", .{c.atomText(s.literalAtom(t))}),
        .number_literal, .number_literal_fresh => try printNumber(w, s.numberValue(t)),
        .union_type => {
            // Display order is a *structural* (TypeId-independent) sort so
            // relocating lib types to low base ids never reorders a message
            // null and undefined always go last, matching tsc.
            const all = s.members(t);
            const buf = c.scratch().alloc(TypeId, all.len) catch return error.WriteFailed;
            var m: usize = 0;
            for (all) |x| {
                if (s.kind(x) == .null or s.kind(x) == .undefined) continue;
                buf[m] = x;
                m += 1;
            }
            const sorted = try sortMembersStructural(c, buf[0..m], depth + 1);
            var first = true;
            for (sorted) |x| {
                if (!first) try w.writeAll(" | ");
                first = false;
                try printTypeParen(c, w, x, depth + 1, .union_member);
            }
            for (all) |x| {
                if (s.kind(x) != .null) continue;
                if (!first) try w.writeAll(" | ");
                first = false;
                try w.writeAll("null");
            }
            for (all) |x| {
                if (s.kind(x) != .undefined) continue;
                if (!first) try w.writeAll(" | ");
                first = false;
                try w.writeAll("undefined");
            }
        },
        .intersection => {
            const sorted = try sortMembersStructural(c, s.members(t), depth + 1);
            for (sorted, 0..) |x, i| {
                if (i > 0) try w.writeAll(" & ");
                try printTypeParen(c, w, x, depth + 1, .isect_member);
            }
        },
        .array => {
            try printTypeParen(c, w, s.arrayElem(t), depth + 1, .operand);
            try w.writeAll("[]");
        },
        .tuple => {
            // `as const` tuples are readonly (flag on every element).
            if (s.tupleLen(t) > 0 and s.tupleElem(t, 0).readonly()) try w.writeAll("readonly ");
            try w.writeAll("[");
            for (0..s.tupleLen(t)) |i| {
                if (i > 0) try w.writeAll(", ");
                const e = s.tupleElem(t, @intCast(i));
                if (e.rest()) try w.writeAll("...");
                try c.printType(w, e.ty, depth + 1);
                if (e.optional()) try w.writeAll("?");
            }
            try w.writeAll("]");
        },
        .object => {
            if (s.objectFlags(t) & types.obj_flag_global_this != 0) return w.writeAll("typeof globalThis");
            const n = s.objectPropCount(t);
            const sidx = s.objectStringIndex(t);
            const nidx = s.objectNumberIndex(t);
            const ncall = s.objectCallSigCount(t);
            const nconstruct = s.objectConstructSigCount(t);
            if (n == 0 and sidx == 0 and nidx == 0 and ncall == 0 and nconstruct == 0) return w.writeAll("{}");
            try w.writeAll("{ ");
            var first = true;
            // Call / construct signatures, printed member-style.
            for (0..ncall) |i| {
                if (!first) try w.writeAll(" ");
                first = false;
                try printSigMember(c, w, s.objectCallSig(t, @intCast(i)), false, depth + 1);
            }
            for (0..nconstruct) |i| {
                if (!first) try w.writeAll(" ");
                first = false;
                try printSigMember(c, w, s.objectConstructSig(t, @intCast(i)), true, depth + 1);
            }
            // Properties are *stored* sorted by name atom (canonical for
            // interning), but atom ids depend on the parallel intern order,
            // so displaying in stored order makes messages differ across
            // --workers/--checkers. Render in name-*text* order instead:
            // names are unique within an object, so this is a total order
            // and byte-identical for any worker/checker count (determinism
            // contract). Storage stays atom-sorted (lookup/interning intact).
            const order = propDisplayOrder(c, t, n) catch return error.WriteFailed;
            for (order) |i| {
                const p = s.objectProp(t, i);
                if (!first) try w.writeAll(" ");
                first = false;
                try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.optional()) "?" else "" });
                try c.printType(w, p.ty, depth + 1);
                try w.writeAll(";");
            }
            if (sidx != 0) {
                if (!first) try w.writeAll(" ");
                first = false;
                try w.writeAll("[x: string]: ");
                try c.printType(w, sidx, depth + 1);
                try w.writeAll(";");
            }
            if (nidx != 0) {
                if (!first) try w.writeAll(" ");
                try w.writeAll("[x: number]: ");
                try c.printType(w, nidx, depth + 1);
                try w.writeAll(";");
            }
            try w.writeAll(" }");
        },
        .function => {
            const tps = s.fnTypeParams(t);
            if (tps.len > 0) {
                try w.writeAll("<");
                for (tps, 0..) |tp, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s}", .{c.symbolName(tp)});
                }
                try w.writeAll(">");
            }
            try w.writeAll("(");
            // An explicit `this` parameter is part of the displayed shape
            // (tsc prints it): without it, a signature that differs ONLY in
            // its receiver renders identically on both sides of a TS2322.
            const this_ty = s.fnThisType(t);
            if (this_ty != 0) {
                try w.writeAll("this: ");
                try c.printType(w, this_ty, depth + 1);
                if (s.fnParamCount(t) > 0) try w.writeAll(", ");
            }
            for (0..s.fnParamCount(t)) |i| {
                if (i > 0) try w.writeAll(", ");
                const p = s.fnParam(t, @intCast(i));
                if (p.rest()) try w.writeAll("...");
                if (p.name != 0) {
                    try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.flags & types.param_flag_optional != 0) "?" else "" });
                }
                try c.printType(w, p.ty, depth + 1);
            }
            try w.writeAll(") => ");
            try c.printType(w, s.fnReturn(t), depth + 1);
        },
        .overloads => {
            try w.writeAll("{ ");
            for (s.members(t), 0..) |m, i| {
                if (i > 0) try w.writeAll(" ");
                try c.printType(w, m, depth + 1);
                try w.writeAll(";");
            }
            try w.writeAll(" }");
        },
        .ref => {
            try w.print("{s}", .{c.symbolName(s.refSymbol(t))});
            const args = s.refArgs(t);
            if (args.len > 0) {
                try w.writeAll("<");
                for (args, 0..) |a, i| {
                    if (i > 0) try w.writeAll(", ");
                    try c.printType(w, a, depth + 1);
                }
                try w.writeAll(">");
            }
        },
        .type_param => try w.print("{s}", .{c.symbolName(s.typeParamSymbol(t))}),
        .class_value => try w.print("typeof {s}", .{c.symbolName(s.classSymbol(t))}),
        .enum_type => if (s.isEnumMember(t))
            try w.print("{s}.{s}", .{ c.symbolName(s.enumSymbol(t)), c.atomText(s.enumMemberAtom(t)) })
        else
            try w.print("{s}", .{c.symbolName(s.enumSymbol(t))}),
        .this_type => try w.writeAll("this"),
        .infer_var => try w.print("infer {s}", .{c.atomText(s.inferVarName(t))}),
        .mapped_param => try w.print("{s}", .{c.atomText(s.mappedParamName(t))}),
        .index_access => {
            try printTypeParen(c, w, s.indexAccessObj(t), depth + 1, .operand);
            try w.writeAll("[");
            try c.printType(w, s.indexAccessIndex(t), depth + 1);
            try w.writeAll("]");
        },
        .mapped => {
            try w.writeAll("{ [");
            try c.printType(w, s.mappedKeyParam(t), depth + 1);
            try w.writeAll(" in ");
            if (s.mappedHomomorphic(t)) {
                try w.writeAll("keyof ");
                try c.printType(w, s.mappedSource(t), depth + 1);
            } else {
                try c.printType(w, s.mappedConstraint(t), depth + 1);
            }
            try w.writeAll("]: ");
            try c.printType(w, s.mappedValue(t), depth + 1);
            try w.writeAll(" }");
        },
        .conditional => {
            try printTypeParen(c, w, s.condCheck(t), depth + 1, .operand);
            try w.writeAll(" extends ");
            try printTypeParen(c, w, s.condExtends(t), depth + 1, .operand);
            try w.writeAll(" ? ");
            try c.printType(w, s.condTrue(t), depth + 1);
            try w.writeAll(" : ");
            try c.printType(w, s.condFalse(t), depth + 1);
        },
        .template_literal_type => {
            try w.writeAll("`");
            try w.writeAll(c.atomText(s.templateHead(t)));
            for (0..s.templateHoleCount(t)) |i| {
                try w.writeAll("${");
                try c.printType(w, s.templateHole(t, @intCast(i)), depth + 1);
                try w.writeAll("}");
                try w.writeAll(c.atomText(s.templateChunk(t, @intCast(i))));
            }
            try w.writeAll("`");
        },
        .string_mapping => {
            try w.print("{s}<", .{stringMappingName(s.stringMappingKind(t))});
            try c.printType(w, s.stringMappingArg(t), depth + 1);
            try w.writeAll(">");
        },
        .keyof_op => {
            try w.writeAll("keyof ");
            try printTypeParen(c, w, s.keyofOperand(t), depth + 1, .operand);
        },
    }
}

fn stringMappingName(kind_idx: u32) []const u8 {
    return switch (kind_idx) {
        types.string_mapping_uppercase => "Uppercase",
        types.string_mapping_lowercase => "Lowercase",
        types.string_mapping_capitalize => "Capitalize",
        types.string_mapping_uncapitalize => "Uncapitalize",
        else => "Uppercase",
    };
}

/// Print a call/construct signature in object-member form:
/// `<T>(a: A): R;` for a call sig, `new <T>(a: A): R;` for a construct sig.
fn printSigMember(c: *Checker, w: *std.Io.Writer, sig: TypeId, is_construct: bool, depth: u32) PrintErr!void {
    const s = c.ts;
    if (is_construct) try w.writeAll("new ");
    const tps = s.fnTypeParams(sig);
    if (tps.len > 0) {
        try w.writeAll("<");
        for (tps, 0..) |tp, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}", .{c.symbolName(tp)});
        }
        try w.writeAll(">");
    }
    try w.writeAll("(");
    for (0..s.fnParamCount(sig)) |i| {
        if (i > 0) try w.writeAll(", ");
        const p = s.fnParam(sig, @intCast(i));
        if (p.rest()) try w.writeAll("...");
        if (p.name != 0) {
            try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.flags & types.param_flag_optional != 0) "?" else "" });
        }
        try c.printType(w, p.ty, depth + 1);
    }
    try w.writeAll("): ");
    try c.printType(w, s.fnReturn(sig), depth + 1);
    try w.writeAll(";");
}

/// Where a nested type is being printed, for precedence parenthesization.
/// `&` binds tighter than `|`, so an intersection needs no parens inside a
/// union but a union DOES need them inside an intersection (`(B | C) & A`,
/// not `B | C & A`, which reads as `B | (C & A)`).
const PrintPos = enum { union_member, isect_member, operand };

fn printTypeParen(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32, pos: PrintPos) PrintErr!void {
    const needs = switch (c.ts.kind(t)) {
        .function => true,
        .union_type => pos != .union_member,
        .intersection => pos == .operand,
        else => false,
    };
    if (needs) try w.writeAll("(");
    try c.printType(w, t, depth);
    if (needs) try w.writeAll(")");
}

/// One display-time member of a union/intersection paired with its
/// structural sort key.
const DisplayMember = struct { ty: TypeId, key: []const u8 };

/// Order-preserving 8-byte big-endian encoding of an f64 so number-literal
/// sort keys compare numerically as raw bytes (`-1` < `0` < `2` < `10`).
fn encodeF64Key(v: f64) [8]u8 {
    var bits: u64 = @bitCast(v);
    bits = if (bits >> 63 != 0) ~bits else bits | (@as(u64, 1) << 63);
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, bits, .big);
    return out;
}

/// Writes a **TypeId-independent** structural sort key for `t`: a kind-rank
/// byte (so intrinsics keep their canonical `Kind` order — `string` before
/// `number` before `boolean`) followed by structural content — array
/// element recursion, an order-preserving numeric encoding for number
/// literals, and the human rendering (symbol names / atom text / literal
/// text, never raw TypeIds) for everything else. Keying on *structure*, not
/// on id assignment, is what keeps union/intersection display order stable
/// when lib types are relocated to low base ids.
fn writeSortKey(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32) PrintErr!void {
    const k = c.ts.kind(t);
    try w.writeByte(@intFromEnum(k));
    if (depth > 6) return;
    switch (k) {
        .array => try writeSortKey(c, w, c.ts.arrayElem(t), depth + 1),
        .number_literal, .number_literal_fresh => try w.writeAll(&encodeF64Key(c.ts.numberValue(t))),
        // Render the key at *exactly* the display depth (`depth`, not
        // `depth + 1`): union/intersection members are displayed via
        // `printType(t, depth)`, and `printType` collapses everything past
        // depth 6 to "...". Keying one level deeper made every member at
        // display-depth 6 hash to "..." — equal keys — so the sort fell
        // back to `makeUnion`'s TypeId order, which differs across checker
        // partitions (a deep-union member-order divergence across
        // --checkers). Matching the depth makes the key equal iff the two
        // members render identically, so order is TypeId-independent.
        else => try c.printType(w, t, depth),
    }
}

/// Returns `members` reordered into the structural display order (see
/// `writeSortKey`). Keys are rendered once into scratch, then sorted; a
/// scratch-owned slice of the reordered TypeIds is returned. Members that
/// render identically produce equal keys and print byte-identically either
/// way, so an unstable sort stays deterministic.
fn sortMembersStructural(c: *Checker, members: []const TypeId, depth: u32) PrintErr![]TypeId {
    const sc = c.scratch();
    const items = sc.alloc(DisplayMember, members.len) catch return error.WriteFailed;
    for (members, 0..) |mem, i| {
        var aw: std.Io.Writer.Allocating = .init(sc);
        try writeSortKey(c, &aw.writer, mem, depth);
        items[i] = .{ .ty = mem, .key = aw.written() };
    }
    std.mem.sort(DisplayMember, items, {}, struct {
        fn less(_: void, a: DisplayMember, b: DisplayMember) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);
    const out = sc.alloc(TypeId, members.len) catch return error.WriteFailed;
    for (items, 0..) |it, i| out[i] = it.ty;
    return out;
}

/// Display order for an object type's `n` properties: their stored slots
/// reordered by property-name *text*. Object props are stored sorted by
/// name *atom* (see `types.makeObject`), which is interning order: the front
/// end's ids are scheduling-independent now (`Interner.renumber`), but names
/// the *checker* interns — mapped-type key remaps, template-literal results —
/// are still numbered as the parallel checkers reach them. Text order is
/// content-derived and therefore byte-identical for any worker/checker count
/// either way. Names are unique within an object, so the order
/// is total (an unstable sort stays deterministic). Scratch-owned slice.
fn propDisplayOrder(c: *Checker, t: TypeId, n: usize) Error![]u32 {
    const order = try c.scratch().alloc(u32, n);
    for (order, 0..) |*x, i| x.* = @intCast(i);
    const Ctx = struct { c: *Checker, t: TypeId };
    std.mem.sort(u32, order, Ctx{ .c = c, .t = t }, struct {
        fn less(ctx: Ctx, a: u32, b: u32) bool {
            const na = ctx.c.atomText(ctx.c.ts.objectProp(ctx.t, a).name);
            const nb = ctx.c.atomText(ctx.c.ts.objectProp(ctx.t, b).name);
            return std.mem.order(u8, na, nb) == .lt;
        }
    }.less);
    return order;
}

pub fn printNumber(w: *std.Io.Writer, v: f64) PrintErr!void {
    if (v == @floor(v) and @abs(v) < 1e15) {
        try w.print("{d}", .{@as(i64, @intFromFloat(v))});
    } else {
        try w.print("{d}", .{v});
    }
}

pub fn symbolName(c: *Checker, sym: u32) []const u8 {
    if (c.isFreshTp(sym)) return c.atomText(c.freshTp(sym).name);
    if (sym == 0 or sym >= c.prog.symbolSpace()) return "?";
    return c.atomText(c.symNameAtom(sym));
}

pub fn dumpTypes(c: *Checker, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    for (1..c.bind.symbol_names.len) |i| {
        const local: SymbolId = @intCast(i);
        if (c.bind.symbol_scopes[local] != binder.file_scope) continue;
        const f = c.bind.symbol_flags[local];
        if (!hasValueMeaning(f)) continue;
        const sym = c.toGlobal(local);
        const t = try c.typeOfSymbol(sym);
        const str = try c.typeToString(t);
        try w.print("{s}: {s}\n", .{ c.symbolName(sym), str });
    }
}
