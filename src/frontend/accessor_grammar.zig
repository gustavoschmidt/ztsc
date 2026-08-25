//! tsc's `checkGrammarAccessor`, as a pure question about ONE accessor's
//! signature — the rules that make a `get`/`set` declaration ill-formed
//! regardless of any type: parameter count, the `set` parameter's shape, a
//! `set` return annotation, and type parameters on either.
//!
//! Every one of them is decidable from syntax alone, which is why the rule
//! lives beside the parser rather than in the checker where tsc keeps it (its
//! `checkGrammar*` family is a checker pass over parsed nodes, and the codes
//! stay GRAMMAR-class here for exactly that reason — `class C { get a(x: number)
//! {} }` next to a sibling file's TS2322 reports both).
//!
//! tsc `return`s out of the walk at its first hit, so an accessor earns AT MOST
//! ONE of these: `set f<T>(...x: number[] = 1): void` is only the TS1094.
//!
//! The `this` parameter is not a value parameter and is excluded from the
//! count on both sides (tsc's `getAccessorThisParameter` /
//! `getSetAccessorValueParameter`): `get j(this: C)` and `set k(this: C, x:
//! number)` are correctly-shaped accessors as far as this rule is concerned,
//! and what they earn instead is the checker's TS2784. Measured against tsgo
//! 7.0.2, which is also where every anchor below comes from — note that
//! TS1052 lands on the accessor's NAME and not, as tsc's own source reads, on
//! the initializer.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");

const Code = diagnostics.Code;

pub const Kind = enum { get, set };

/// One accessor's signature, reduced to what the rule asks about. Token fields
/// are indices into the parser's token stream; `null` means the construct is
/// absent.
pub const Shape = struct {
    kind: Kind,
    /// The accessor's name token — where all but two of the reports land.
    name_token: u32,
    /// Parameters EXCLUDING a leading `this` parameter.
    value_params: u32,
    /// Whether the accessor carries a type-parameter list.
    type_params: bool,
    /// Whether the accessor carries a `: T` return annotation.
    return_type: bool,
    /// The `...` of the sole value parameter, when it is a rest parameter.
    rest: ?u32 = null,
    /// The `?` of the sole value parameter, when it is optional.
    question: ?u32 = null,
    /// Whether the sole value parameter has an `= …` initializer.
    initializer: bool = false,
};

pub const Report = struct { code: Code, token: u32 };

/// What `s` earns, or null when it is well formed. The three `set`-parameter
/// rules are asked only of an accessor whose count already checks out, exactly
/// as tsc's walk reaches them only past its own `return`.
pub fn check(s: Shape) ?Report {
    if (s.type_params) return .{ .code = .accessor_type_parameters, .token = s.name_token };
    const want: u32 = if (s.kind == .get) 0 else 1;
    if (s.value_params != want) {
        return .{
            .code = if (s.kind == .get) .get_accessor_parameters else .set_accessor_one_parameter,
            .token = s.name_token,
        };
    }
    if (s.kind == .get) return null;
    if (s.return_type) return .{ .code = .set_accessor_return_type, .token = s.name_token };
    if (s.rest) |t| return .{ .code = .set_accessor_rest_parameter, .token = t };
    if (s.question) |t| return .{ .code = .set_accessor_optional_parameter, .token = t };
    if (s.initializer) return .{ .code = .set_accessor_parameter_initializer, .token = s.name_token };
    return null;
}

const testing = std.testing;

fn expectCode(s: Shape, want: ?Code) !void {
    const got = check(s);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqual(w, got.?.code);
    } else {
        try testing.expect(got == null);
    }
}

test "a well-formed accessor earns nothing" {
    try expectCode(.{ .kind = .get, .name_token = 5, .value_params = 0, .type_params = false, .return_type = true }, null);
    try expectCode(.{ .kind = .set, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false }, null);
}

test "parameter count" {
    try expectCode(
        .{ .kind = .get, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false },
        .get_accessor_parameters,
    );
    try expectCode(
        .{ .kind = .set, .name_token = 5, .value_params = 0, .type_params = false, .return_type = false },
        .set_accessor_one_parameter,
    );
    try expectCode(
        .{ .kind = .set, .name_token = 5, .value_params = 2, .type_params = false, .return_type = false },
        .set_accessor_one_parameter,
    );
}

test "type parameters outrank every other rule" {
    try expectCode(
        .{ .kind = .set, .name_token = 5, .value_params = 3, .type_params = true, .return_type = true, .rest = 9 },
        .accessor_type_parameters,
    );
}

test "the set-parameter rules, in tsc's order" {
    const base: Shape = .{ .kind = .set, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false };
    var s = base;
    s.return_type = true;
    s.rest = 9;
    s.question = 10;
    s.initializer = true;
    try expectCode(s, .set_accessor_return_type);
    s.return_type = false;
    try expectCode(s, .set_accessor_rest_parameter);
    s.rest = null;
    try expectCode(s, .set_accessor_optional_parameter);
    s.question = null;
    try expectCode(s, .set_accessor_parameter_initializer);
}

test "a getter is judged on count and type parameters alone" {
    // A `get` accessor MAY have a return type, and the set-only rules cannot
    // fire for one (it has no value parameter to carry them).
    try expectCode(
        .{ .kind = .get, .name_token = 5, .value_params = 0, .type_params = false, .return_type = true, .initializer = true },
        null,
    );
}

test "the anchors" {
    const r = check(.{ .kind = .set, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false, .question = 11 }).?;
    try testing.expectEqual(@as(u32, 11), r.token); // the `?`, not the name
    const r2 = check(.{ .kind = .set, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false, .rest = 7 }).?;
    try testing.expectEqual(@as(u32, 7), r2.token); // the `...`
    const r3 = check(.{ .kind = .set, .name_token = 5, .value_params = 1, .type_params = false, .return_type = false, .initializer = true }).?;
    try testing.expectEqual(@as(u32, 5), r3.token); // the NAME (tsgo, not tsc's source)
}
