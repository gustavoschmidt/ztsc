//! Numeric literals: source text → value → the string JavaScript names it by.
//!
//! Two places need this and must agree exactly, which is why it is one module
//! rather than a helper in each: the CHECKER turns a numeric literal token into
//! an `f64` (`numberTokenValue`) and a numeric literal TYPE back into text
//! (`printNumber`, `literalKeyAtom`), and the front end turns a numeric
//! PROPERTY NAME into its member atom. tsc has the same single source: its
//! scanner stores `tokenValue = "" + numericValue`, so by the time the binder
//! asks for a property name the spelling is already canonical and
//! `{ 0: x, 0.0: y, "0": z }` is one member three times over.

const std = @import("std");

/// The value a numeric-literal token's source text denotes. Handles the radix
/// prefixes (`0x`/`0o`/`0b`, either case) and numeric separators (`1_000`);
/// everything else goes through `parseFloat`, which covers the decimal,
/// fractional and exponent forms.
///
/// A text this cannot parse yields 0 rather than an error: the token came out of
/// the scanner, so a failure here means a malformed literal the parser has
/// already reported, and inventing a second diagnostic for it would be noise.
pub fn value(text: []const u8) f64 {
    var buf: [max_text]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        if (n >= buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    const t = buf[0..n];
    if (t.len > 2 and t[0] == '0') {
        const radix: ?u8 = switch (t[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            const v = std.fmt.parseInt(u64, t[2..], r) catch return 0;
            return @floatFromInt(v);
        }
    }
    return std.fmt.parseFloat(f64, t) catch 0;
}

/// Longest literal text `value` reads; longer input is truncated (a literal that
/// long has already lost precision in `f64` either way).
const max_text = 64;

/// Buffer size that always holds a `write` result.
pub const max_name = 32;

/// Write `v` the way JavaScript's `String(v)` does: an integral magnitude below
/// 1e15 as plain digits (so `0.0` prints `0`, not `0e0`), anything else through
/// the shortest round-tripping form.
pub fn write(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    // JavaScript's spellings, which are also tsc's: a numeric literal too large
    // for `f64` really does declare the member `Infinity`
    // (`binaryAndOctalIntegerLiteral`), and Zig's `{d}` would write `inf`.
    if (std.math.isNan(v)) return w.writeAll("NaN");
    if (std.math.isInf(v)) return w.writeAll(if (v < 0) "-Infinity" else "Infinity");
    if (v == @floor(v) and @abs(v) < 1e15) {
        try w.print("{d}", .{@as(i64, @intFromFloat(v))});
    } else {
        try w.print("{d}", .{v});
    }
}

/// The member name a numeric property-name token declares: its value, written
/// back canonically. Borrows `buf`, so the result must be copied (or interned)
/// before `buf` goes out of scope.
pub fn name(buf: *[max_name]u8, text: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    write(&w, value(text)) catch return text;
    return w.buffered();
}

test "numeric literal names are canonical" {
    const t = std.testing;
    var buf: [max_name]u8 = undefined;
    // The spellings the suite pins: `numericClassMembers1`,
    // `binaryAndOctalIntegerLiteral`, `duplicateObjectLiteralProperty`.
    try t.expectEqualStrings("0", name(&buf, "0"));
    try t.expectEqualStrings("0", name(&buf, "0.0"));
    try t.expectEqualStrings("0", name(&buf, "0.00"));
    try t.expectEqualStrings("26", name(&buf, "0b11010"));
    try t.expectEqualStrings("26", name(&buf, "0B11010"));
    try t.expectEqualStrings("511", name(&buf, "0o777"));
    try t.expectEqualStrings("255", name(&buf, "0xff"));
    try t.expectEqualStrings("1000", name(&buf, "1_000"));
    try t.expectEqualStrings("100", name(&buf, "1e2"));
    try t.expectEqualStrings("1.5", name(&buf, "1.5"));
    try t.expectEqualStrings("1.5", name(&buf, "1.50"));
    // A leading `0` that is NOT a radix prefix is a legacy octal in
    // non-strict code and a decimal here; either way `parseFloat` decides.
    try t.expectEqualStrings("12", name(&buf, "012"));
    // A literal past `f64` range names the member `Infinity`, JavaScript's
    // spelling (`binaryIntegerLiteral` reads `obj1["Infinity"]` back).
    try t.expectEqualStrings("Infinity", name(&buf, "1e999"));
}

test "value: the forms the scanner hands over" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 26), value("0b11010"));
    try t.expectEqual(@as(f64, 0), value("0.0"));
    try t.expectEqual(@as(f64, 1000), value("1_000"));
    try t.expectEqual(@as(f64, 0.5), value(".5"));
    try t.expectEqual(@as(f64, 0), value("nonsense"));
}
