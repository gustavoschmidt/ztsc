//! Type printing (diagnostic display strings).
//! Split mechanically from checker.zig; functions take the
//! `Checker` context as their first parameter.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const numeric_lit = @import("../numeric_lit.zig");
const string_value = @import("../frontend/string_value.zig");
const types = @import("../types.zig");

const Io = std.Io;
const Atom = @import("../intern.zig").Atom;
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
    printType(c, &aw.writer, t, 0, max_type_string) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        // The rendering ran past what the truncation below keeps; the bytes
        // already on the writer are exactly the ones an unbudgeted render
        // would have produced (see `budget`).
        error.BudgetSpent => {},
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
///
/// `BudgetSpent` is not a failure: it is how a render that has already
/// produced every byte `typeToString` keeps unwinds out of the recursion
/// instead of walking the rest of the type (see `budget`).
pub const PrintErr = std.Io.Writer.Error || error{BudgetSpent};

/// A `budget` meaning "render the whole thing" — for the structural sort keys,
/// which are compared, not displayed.
const no_budget = std.math.maxInt(usize);

/// Renders `t` into `w`, stopping once `w` holds `budget` bytes.
///
/// `typeToString` truncates its result to `max_type_string`, and the printers
/// only ever APPEND, so every byte a render produces past that offset is
/// discarded — as is every type-store read, member-table walk and structural
/// sort that produced it. On social-app the same @types/react props types are
/// spelled by 31 diagnostics whose headline shows ~160 characters of an object
/// running to tens of kilobytes, so the discarded part was the bulk of the
/// work: a union nested inside it was still `sortMembersStructural`-sorted,
/// which renders a full key per member.
///
/// Stopping is byte-exact rather than approximate. The first `budget` bytes
/// are already final when the check trips, so the truncated string is
/// identical to the one an unbudgeted render would have produced — including
/// its display ORDER, because the sort keys that fix that order are rendered
/// unbudgeted (`writeSortKey`).
fn printType(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32, budget: usize) PrintErr!void {
    // `Allocating` never drains, so `end` is the total byte count.
    if (w.end >= budget) return error.BudgetSpent;
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
        // The atom holds the literal's VALUE (escapes decoded — `atoms.cookedAtom`),
        // so printing it back re-escapes: tsc renders a string-literal type as
        // `"` ++ `escapeString(value)` ++ `"`.
        .string_literal => {
            try w.writeByte('"');
            try string_value.writeEscaped(w, c.atomText(s.literalAtom(t)), '"');
            try w.writeByte('"');
        },
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
                try printTypeParen(c, w, x, depth + 1, .union_member, budget);
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
                try printTypeParen(c, w, x, depth + 1, .isect_member, budget);
            }
        },
        .array => {
            if (s.arrayIsReadonly(t)) try w.writeAll("readonly ");
            try printTypeParen(c, w, s.arrayElem(t), depth + 1, .array_elem, budget);
            try w.writeAll("[]");
        },
        // An evolving array never leaves the flow walk (see
        // `Kind.evolving_array`); tsc prints one as its finalized form, and
        // the still-empty state — its only reachable spelling here — is
        // `any[]`.
        .evolving_array => {
            const elem = s.arrayElem(t);
            if (elem == types.never_type) return w.writeAll("any[]");
            try printTypeParen(c, w, elem, depth + 1, .array_elem, budget);
            try w.writeAll("[]");
        },
        .tuple => {
            // Either provenance of a readonly tuple: the tuple-level modifier
            // (`readonly [A, B]`) or an every-element marking (`as const`).
            if (s.tupleIsReadonly(t) or (s.tupleLen(t) > 0 and s.tupleElem(t, 0).readonly()))
                try w.writeAll("readonly ");
            try w.writeAll("[");
            for (0..s.tupleLen(t)) |i| {
                if (i > 0) try w.writeAll(", ");
                const e = s.tupleElem(t, @intCast(i));
                if (e.rest()) try w.writeAll("...");
                if (e.optional() and !e.rest()) {
                    try printOptionalElem(c, w, e.ty, depth + 1, budget);
                    try w.writeAll("?");
                    continue;
                }
                try printType(c, w, e.ty, depth + 1, budget);
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
            // tsc's `createAnonymousTypeNode`: a resolved type carrying exactly
            // ONE call signature and nothing else is a FunctionType, and one
            // carrying exactly one CONSTRUCT signature and nothing else a
            // ConstructorType — so `var AAA: new() => A` reads back as
            // `new () => A`, not `{ new (): A; }`
            // (`classAbstractAssignabilityConstructorFunction`).
            if (objectPrintsAsSignature(c, t)) {
                const is_construct = nconstruct == 1;
                const sig = if (is_construct) s.objectConstructSig(t, 0) else s.objectCallSig(t, 0);
                return printSig(c, w, sig, is_construct, .arrow, depth, budget);
            }
            try w.writeAll("{ ");
            var first = true;
            // Call / construct signatures, printed member-style.
            for (0..ncall) |i| {
                if (!first) try w.writeAll(" ");
                first = false;
                try printSig(c, w, s.objectCallSig(t, @intCast(i)), false, .member, depth + 1, budget);
            }
            for (0..nconstruct) |i| {
                if (!first) try w.writeAll(" ");
                first = false;
                try printSig(c, w, s.objectConstructSig(t, @intCast(i)), true, .member, depth + 1, budget);
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
                try writeMemberName(c, w, p.name);
                try w.print("{s}: ", .{if (p.optional()) "?" else ""});
                try printType(c, w, p.ty, depth + 1, budget);
                try w.writeAll(";");
            }
            if (sidx != 0) {
                if (!first) try w.writeAll(" ");
                first = false;
                // A `[k: symbol]` signature is stored in the STRING slot with
                // `obj_flag_symbol_index` marking the key domain (see
                // `index_constraints.indexKindOf`), so the printed key type
                // comes off the flag, not the slot.
                try w.writeAll(if (s.objectFlags(t) & types.obj_flag_symbol_index != 0)
                    "[x: symbol]: "
                else
                    "[x: string]: ");
                try printType(c, w, sidx, depth + 1, budget);
                try w.writeAll(";");
            }
            if (nidx != 0) {
                if (!first) try w.writeAll(" ");
                try w.writeAll("[x: number]: ");
                try printType(c, w, nidx, depth + 1, budget);
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
                try printType(c, w, this_ty, depth + 1, budget);
                if (s.fnParamCount(t) > 0) try w.writeAll(", ");
            }
            for (0..s.fnParamCount(t)) |i| {
                if (i > 0) try w.writeAll(", ");
                const p = s.fnParam(t, @intCast(i));
                if (p.rest()) try w.writeAll("...");
                if (p.name != 0) {
                    try w.print("{s}{s}: ", .{ c.atomText(p.name), if (p.flags & types.param_flag_optional != 0) "?" else "" });
                }
                try printType(c, w, p.ty, depth + 1, budget);
            }
            try w.writeAll(") => ");
            try printType(c, w, s.fnReturn(t), depth + 1, budget);
        },
        .overloads => {
            try w.writeAll("{ ");
            for (s.members(t), 0..) |m, i| {
                if (i > 0) try w.writeAll(" ");
                try printType(c, w, m, depth + 1, budget);
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
                    try printType(c, w, a, depth + 1, budget);
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
            try printTypeParen(c, w, s.indexAccessObj(t), depth + 1, .operand, budget);
            try w.writeAll("[");
            try printType(c, w, s.indexAccessIndex(t), depth + 1, budget);
            try w.writeAll("]");
        },
        .mapped => {
            try w.writeAll("{ [");
            try printType(c, w, s.mappedKeyParam(t), depth + 1, budget);
            try w.writeAll(" in ");
            if (s.mappedHomomorphic(t)) {
                try w.writeAll("keyof ");
                try printType(c, w, s.mappedSource(t), depth + 1, budget);
            } else {
                try printType(c, w, s.mappedConstraint(t), depth + 1, budget);
            }
            try w.writeAll("]: ");
            try printType(c, w, s.mappedValue(t), depth + 1, budget);
            try w.writeAll(" }");
        },
        .conditional => {
            try printTypeParen(c, w, s.condCheck(t), depth + 1, .operand, budget);
            try w.writeAll(" extends ");
            try printTypeParen(c, w, s.condExtends(t), depth + 1, .operand, budget);
            try w.writeAll(" ? ");
            try printType(c, w, s.condTrue(t), depth + 1, budget);
            try w.writeAll(" : ");
            try printType(c, w, s.condFalse(t), depth + 1, budget);
        },
        .template_literal_type => {
            try w.writeAll("`");
            try w.writeAll(c.atomText(s.templateHead(t)));
            for (0..s.templateHoleCount(t)) |i| {
                try w.writeAll("${");
                try printType(c, w, s.templateHole(t, @intCast(i)), depth + 1, budget);
                try w.writeAll("}");
                try w.writeAll(c.atomText(s.templateChunk(t, @intCast(i))));
            }
            try w.writeAll("`");
        },
        .string_mapping => {
            try w.print("{s}<", .{stringMappingName(s.stringMappingKind(t))});
            try printType(c, w, s.stringMappingArg(t), depth + 1, budget);
            try w.writeAll(">");
        },
        .keyof_op => {
            try w.writeAll("keyof ");
            try printTypeParen(c, w, s.keyofOperand(t), depth + 1, .operand, budget);
        },
    }
}

/// How a member NAME renders inside an object type. A member declared with a
/// computed `[…]` key is printed by tsc as the bracketed expression that named
/// it, never as the internal key it is filed under: `{ [Symbol.iterator]: T }`,
/// not `{ __@iterator: T }`. ztsc's synthetic key for a well-known symbol is
/// exactly `"__@" ++ <name>` (`ast.wellKnownSymbolKey`), so round-tripping the
/// suffix through that table is the recognizer — no second copy of the list to
/// drift from it.
///
/// The other two synthetic key families still print raw, because neither
/// carries a name to recover here: `__@u<id>` (a `unique symbol` key) is
/// identified by a global NODE id whose declaring name lives in whichever
/// file's tree it points into, and `__@k$…` is the placeholder for a computed
/// key that never resolved. tsc prints the first as `[s]`.
fn writeMemberName(c: *Checker, w: *std.Io.Writer, name: Atom) PrintErr!void {
    const text = c.atomText(name);
    const prefix = "__@";
    if (std.mem.startsWith(u8, text, prefix)) {
        const well_known = text[prefix.len..];
        if (ast.wellKnownSymbolKey(well_known) != null) {
            try w.print("[Symbol.{s}]", .{well_known});
            return;
        }
    }
    // A member's atom holds the name's VALUE, so a name that cannot be spelled
    // bare goes back out as tsc writes it: quoted, escapes restored
    // (`{ "a\nb": number }`). Only names that actually need an escape are
    // quoted here — a plain non-identifier (`a-b`) prints bare, as it always
    // has, so nothing that used to round-trip through the source text moves.
    if (string_value.needsEscape(text)) {
        const q = string_value.quoteFor(text);
        try w.writeByte(q);
        try string_value.writeEscaped(w, text, q);
        try w.writeByte(q);
        return;
    }
    try w.writeAll(text);
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
/// How a signature joins its return type: as a type-literal MEMBER
/// (`new (a: T): R;`) or as a standalone signature TYPE (`new (a: T) => R`).
/// tsc's `signatureToSignatureDeclarationHelper` picks between
/// `SyntaxKind.ConstructSignature` and `SyntaxKind.ConstructorType` the same
/// way, and the two spellings differ in exactly this suffix.
const SigForm = enum { member, arrow };

/// Does this object type print as a bare signature rather than a type literal?
/// tsc's `createAnonymousTypeNode`: exactly one call signature and nothing
/// else, or exactly one construct signature and nothing else. Shared with
/// `printTypeParen`, because a signature type needs the same parentheses a
/// function type does.
fn objectPrintsAsSignature(c: *Checker, t: TypeId) bool {
    const s = c.ts;
    if (s.kind(t) != .object) return false;
    if (s.objectFlags(t) & types.obj_flag_global_this != 0) return false;
    if (s.objectPropCount(t) != 0 or s.objectStringIndex(t) != 0 or s.objectNumberIndex(t) != 0) return false;
    const ncall = s.objectCallSigCount(t);
    const nconstruct = s.objectConstructSigCount(t);
    return (ncall == 1 and nconstruct == 0) or (nconstruct == 1 and ncall == 0);
}

fn printSig(c: *Checker, w: *std.Io.Writer, sig: TypeId, is_construct: bool, form: SigForm, depth: u32, budget: usize) PrintErr!void {
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
        try printType(c, w, p.ty, depth + 1, budget);
    }
    try w.writeAll(if (form == .arrow) ") => " else "): ");
    try printType(c, w, s.fnReturn(sig), depth + 1, budget);
    if (form == .member) try w.writeAll(";");
}

/// Where a nested type is being printed, for precedence parenthesization.
/// `&` binds tighter than `|`, so an intersection needs no parens inside a
/// union but a union DOES need them inside an intersection (`(B | C) & A`,
/// not `B | C & A`, which reads as `B | (C & A)`).
const PrintPos = enum { union_member, isect_member, operand, array_elem };

/// The DECLARED type of an optional tuple element, rendered the way tsc
/// renders it: `[string?]` displays as `[(string | undefined)?]`.
///
/// tsc adds `undefined` to an optional element's type under
/// `strictNullChecks` (`addOptionality` on the element, which is what makes
/// `t[1]` read `string | undefined`) and then parenthesizes, because the
/// result is a union and `?` binds to the whole element. ztsc stores the
/// element as WRITTEN and carries the optionality in the element flag, so the
/// `| undefined` has to be supplied here — textually, because the printer's
/// error set deliberately excludes interning (see `PrintErr`) and
/// `makeUnion2` allocates.
///
/// Appending it textually is the same string the interned union would print:
/// `printType`'s union arm emits `undefined` LAST, after the structurally
/// sorted members and after `null`. The four types that absorb it are spelled
/// out rather than unioned, matching the oracle:
///
///     [any?]     -> [any?]        [unknown?] -> [unknown?]
///     [undefined?] -> [undefined?]  [never?] -> [undefined?]
fn printOptionalElem(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32, budget: usize) PrintErr!void {
    const s = &c.ts;
    switch (s.kind(t)) {
        // `T | undefined` is `T` for these three: no union, so no parentheses.
        .any, .unknown, .undefined => return printType(c, w, t, depth, budget),
        // `never | undefined` reduces to `undefined` (tsc prints `[undefined?]`
        // for `[never?]`).
        .never => return w.writeAll("undefined"),
        .union_type => {
            var has_undef = false;
            for (0..s.memberCount(t)) |i| {
                if (s.kind(s.memberAt(t, @intCast(i))) == .undefined) has_undef = true;
            }
            try w.writeAll("(");
            try printType(c, w, t, depth, budget);
            if (!has_undef) try w.writeAll(" | undefined");
            try w.writeAll(")");
        },
        else => {
            try w.writeAll("(");
            // As a union member: a function or an intersection takes its own
            // parentheses inside the pair this adds — tsc's
            // `[((() => void) | undefined)?]`.
            try printTypeParen(c, w, t, depth, .union_member, budget);
            try w.writeAll(" | undefined)");
        },
    }
}

fn printTypeParen(c: *Checker, w: *std.Io.Writer, t: TypeId, depth: u32, pos: PrintPos, budget: usize) PrintErr!void {
    const needs = switch (c.ts.kind(t)) {
        .function => true,
        // A lone call/construct signature prints as `(…) => R` / `new (…) => R`
        // and binds exactly as loosely as a function type does.
        .object => objectPrintsAsSignature(c, t),
        .union_type => pos != .union_member,
        // `&` already binds tighter than `|`, so the parentheses around an
        // intersection written as a union member are redundant — and tsc
        // emits them anyway (`typeToString` of `(A & B) | string` is
        // `string | (A & B)`, oracle-verified). Matching the oracle's
        // spelling is the whole job of this file.
        .intersection => pos != .isect_member,
        // `readonly` binds looser than the `[]` suffix, so an array OF readonly
        // arrays is `(readonly T[])[]`. Only there: `keyof readonly T[]` and
        // `readonly T[] extends X ? …` need no parentheses and tsc prints none.
        .array => pos == .array_elem and c.ts.arrayIsReadonly(t),
        else => false,
    };
    if (needs) try w.writeAll("(");
    try printType(c, w, t, depth, budget);
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
        // A sort key is rendered UNBUDGETED. It is not display text: two
        // members that agree on the first `max_type_string` bytes and diverge
        // after would tie, and an unstable sort would then order them by
        // `makeUnion`'s TypeId order — the very cross-partition divergence
        // this key exists to remove.
        else => try printType(c, w, t, depth, no_budget),
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
    try numeric_lit.write(w, v);
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
