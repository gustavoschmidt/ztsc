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
    // A RADIX literal is read streaming, with no length limit and in `f64`
    // rather than through `u64`. Both halves are load-bearing:
    //
    //   * `0B1111…` with a thousand digits is a real literal
    //     (`binaryIntegerLiteral`), and JavaScript's answer for one past
    //     `f64` range is `Infinity` — so `obj[…]` declares the member
    //     `"Infinity"`. Copying into a fixed buffer first truncated it to
    //     62 digits and named the member `4611686018427388000`;
    //   * `u64` cannot hold 83 bits either, and its overflow was answered
    //     with `0`.
    //
    // The accumulation is exact for a power-of-two radix (`v * r` only moves
    // the exponent) until the significand runs out, at which point it rounds
    // the way the exact value would, and then goes to `inf` on its own.
    if (text.len > 2 and text[0] == '0') {
        const radix: ?f64 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var v: f64 = 0;
            for (text[2..]) |ch| {
                if (ch == '_') continue;
                const d: f64 = switch (ch) {
                    '0'...'9' => @floatFromInt(ch - '0'),
                    'a'...'f' => @floatFromInt(ch - 'a' + 10),
                    'A'...'F' => @floatFromInt(ch - 'A' + 10),
                    else => return 0,
                };
                if (d >= r) return 0;
                v = v * r + d;
            }
            return v;
        }
    }
    var buf: [max_text]u8 = undefined;
    var n: usize = 0;
    var truncated = false;
    var has_point_or_exp = false;
    for (text) |ch| {
        if (ch == '_') continue;
        if (ch == '.' or ch == 'e' or ch == 'E') has_point_or_exp = true;
        if (n >= buf.len) {
            truncated = true;
            continue;
        }
        buf[n] = ch;
        n += 1;
    }
    // A pure-digit literal too long for the buffer is past `f64` range by
    // many orders of magnitude, and truncating it would answer with a
    // finite number `max_text` digits wide instead of `Infinity`.
    if (truncated and !has_point_or_exp) return std.math.inf(f64);
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
}

/// Longest DECIMAL literal text `value` reads; longer input is `Infinity` when
/// it is all digits (see above) and truncated otherwise — a mantissa that long
/// has already lost precision in `f64` either way. Radix literals have no
/// limit; they never reach the buffer.
const max_text = 64;

/// Buffer size that always holds a `write` result: the widest is the 21-digit
/// fixed form or `-1.7976931348623157e+308`.
pub const max_name = 32;

/// Write `v` the way JavaScript's `String(v)` does — ECMA-262's
/// `Number::toString`, which is also how tsc spells a numeric literal type and
/// how it names a numeric property.
///
/// The rule that matters, and that neither of Zig's `{d}`/`{e}` implements, is
/// WHEN the exponential form is used: the shortest round-tripping digits `s`
/// (`k` of them) and the position `n` of the decimal point are chosen first,
/// and the form follows from `n` alone — fixed for `-6 < n <= 21`, exponential
/// otherwise, with an explicit `+` on a positive exponent. `{d}` is always
/// fixed, so `9.671406556917009e+24` was written as its 25 digits, and 1e-30 as
/// 30 zeros and a 1.
pub fn write(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    // JavaScript's spellings, which are also tsc's: a numeric literal too large
    // for `f64` really does declare the member `Infinity`
    // (`binaryAndOctalIntegerLiteral`), and Zig's `{d}` would write `inf`.
    if (std.math.isNan(v)) return w.writeAll("NaN");
    if (std.math.isInf(v)) return w.writeAll(if (v < 0) "-Infinity" else "Infinity");
    // `String(0)` and `String(-0)` are both `"0"`; the general path would
    // write `0` and `-0`.
    if (v == 0) return w.writeAll("0");
    // Shortest round-tripping scientific form: `[-]d[.ddd]e<exp>`, from which
    // the digits and the exponent read off directly.
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{v}) catch return w.print("{d}", .{v});
    var rest = sci;
    if (rest.len != 0 and rest[0] == '-') {
        try w.writeAll("-");
        rest = rest[1..];
    }
    const e_at = std.mem.indexOfScalar(u8, rest, 'e') orelse return w.writeAll(rest);
    const exp = std.fmt.parseInt(i32, rest[e_at + 1 ..], 10) catch return w.writeAll(rest);
    // The mantissa with its point removed: ECMA's `s`, `k` digits long.
    var digits: [32]u8 = undefined;
    var k: usize = 0;
    for (rest[0..e_at]) |ch| {
        if (ch == '.') continue;
        if (k >= digits.len) break;
        digits[k] = ch;
        k += 1;
    }
    const s = digits[0..k];
    // ECMA's `n`: `v = s * 10^(n - k)`, i.e. the decimal point sits after `n`
    // digits of `s`.
    const n: i32 = exp + 1;
    if (n >= @as(i32, @intCast(k)) and n <= 21) {
        // `s` followed by `n - k` zeros.
        try w.writeAll(s);
        var z: i32 = n - @as(i32, @intCast(k));
        while (z > 0) : (z -= 1) try w.writeAll("0");
    } else if (n > 0 and n <= 21) {
        try w.writeAll(s[0..@intCast(n)]);
        try w.writeAll(".");
        try w.writeAll(s[@intCast(n)..]);
    } else if (n > -6 and n <= 0) {
        try w.writeAll("0.");
        var z: i32 = -n;
        while (z > 0) : (z -= 1) try w.writeAll("0");
        try w.writeAll(s);
    } else {
        try w.writeAll(s[0..1]);
        if (k > 1) {
            try w.writeAll(".");
            try w.writeAll(s[1..]);
        }
        try w.print("e{s}{d}", .{ if (n - 1 < 0) "-" else "+", @abs(n - 1) });
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
    // `Number::toString`'s form switch, which `binaryIntegerLiteral` reads
    // back as `obj2["9.671406556917009e+24"]`: fixed for `-6 < n <= 21`,
    // exponential (with an explicit `+`) outside it.
    try t.expectEqualStrings(
        "9.671406556917009e+24",
        name(&buf, "0B11111111111111111111111111111111111111111111111101001010100000010111110001111111111"),
    );
    try t.expectEqualStrings("100000000000000000000", name(&buf, "1e20"));
    try t.expectEqualStrings("1e+21", name(&buf, "1e21"));
    try t.expectEqualStrings("0.000001", name(&buf, "1e-6"));
    try t.expectEqualStrings("1e-7", name(&buf, "1e-7"));
    try t.expectEqualStrings("0", name(&buf, "-0"));
    try t.expectEqualStrings("0.1", name(&buf, "0.1"));
    try t.expectEqualStrings("5e-324", name(&buf, "5e-324"));
    try t.expectEqualStrings("1.7976931348623157e+308", name(&buf, "1.7976931348623157e308"));
}

test "value: the forms the scanner hands over" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 26), value("0b11010"));
    try t.expectEqual(@as(f64, 0), value("0.0"));
    try t.expectEqual(@as(f64, 1000), value("1_000"));
    try t.expectEqual(@as(f64, 0.5), value(".5"));
    try t.expectEqual(@as(f64, 0), value("nonsense"));
    // Past `u64`, and past `f64`: `binaryIntegerLiteral`'s two long keys.
    try t.expectEqual(
        @as(f64, 9.671406556917009e+24),
        value("0B11111111111111111111111111111111111111111111111101001010100000010111110001111111111"),
    );
    try t.expectEqual(std.math.inf(f64), value("0B" ++ ("1" ** 1200)));
    try t.expectEqual(std.math.inf(f64), value("9" ** 400));
}
