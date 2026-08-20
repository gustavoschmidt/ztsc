//! JSONC (JSON + comments + trailing commas) value parser.
//!
//! A small self-contained recursive-descent parser producing arena-allocated
//! values. It is a general utility, not a policy module: `tsconfig.zig` reads
//! `tsconfig.json` through it, and `link/resolve.zig` reads every dependency's
//! `package.json` through it.
//!
//! Comments (`//` and `/* */`) and trailing commas are accepted anywhere
//! whitespace is, which is what "JSONC" buys over strict JSON. Strings are
//! unescaped copies owned by the arena; `\uXXXX` decodes to UTF-8 and a lone
//! surrogate becomes U+FFFD (config files do not need astral-plane fidelity).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parse JSONC (JSON + comments + trailing commas) into an arena-backed
/// `Value`. Strings are unescaped copies.
pub fn parseJsonc(arena: Allocator, text: []const u8) JsonError!Value {
    return parse(arena, text, false);
}

/// `parseJsonc`, plus `Object.key_pos` on every object: the byte offset of
/// each key's opening quote. That is what a diagnostic anchored at a config
/// key needs (`tsconfig.zig` and its TS5102). It is a separate entry point
/// because the offsets cost an allocation per object and the hot JSONC
/// consumer — the `package.json` reader, thousands of files on a real project
/// — has no use for them.
pub fn parseJsoncKeyed(arena: Allocator, text: []const u8) JsonError!Value {
    return parse(arena, text, true);
}

fn parse(arena: Allocator, text: []const u8, key_positions: bool) JsonError!Value {
    var p: JsonParser = .{ .arena = arena, .text = text, .key_positions = key_positions };
    p.skipWs();
    const v = try p.parseValue(0);
    p.skipWs();
    if (p.pos != p.text.len) return error.SyntaxError;
    return v;
}

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: Object,

    pub const Object = struct {
        keys: []const []const u8 = &.{},
        vals: []const Value = &.{},
        /// Byte offset of each key's opening quote, parallel to `keys`.
        /// Empty unless the value came from `parseJsoncKeyed`.
        key_pos: []const u32 = &.{},

        pub fn get(o: Object, key: []const u8) ?Value {
            for (o.keys, o.vals) |k, v| {
                if (std.mem.eql(u8, k, key)) return v;
            }
            return null;
        }

        /// Byte offset of `key`'s opening quote, or null when the key is
        /// absent or the value was parsed without positions.
        pub fn keyPos(o: Object, key: []const u8) ?u32 {
            if (o.key_pos.len != o.keys.len) return null;
            for (o.keys, o.key_pos) |k, at| {
                if (std.mem.eql(u8, k, key)) return at;
            }
            return null;
        }
    };
};

pub const JsonError = error{ SyntaxError, OutOfMemory };

// ===========================================================================
// private implementation
// ===========================================================================

const JsonParser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,
    /// Record each object key's opening-quote offset (see `parseJsoncKeyed`).
    key_positions: bool = false,

    const max_depth = 64;

    fn skipWs(p: *JsonParser) void {
        while (p.pos < p.text.len) {
            const c = p.text[p.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => p.pos += 1,
                '/' => {
                    if (p.pos + 1 >= p.text.len) return;
                    switch (p.text[p.pos + 1]) {
                        '/' => {
                            p.pos += 2;
                            while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
                        },
                        '*' => {
                            p.pos += 2;
                            while (p.pos + 1 < p.text.len and
                                !(p.text[p.pos] == '*' and p.text[p.pos + 1] == '/')) p.pos += 1;
                            p.pos = @min(p.pos + 2, p.text.len);
                        },
                        else => return,
                    }
                },
                else => return,
            }
        }
    }

    fn parseValue(p: *JsonParser, depth: u32) JsonError!Value {
        if (depth > max_depth) return error.SyntaxError;
        if (p.pos >= p.text.len) return error.SyntaxError;
        switch (p.text[p.pos]) {
            '{' => return p.parseObject(depth),
            '[' => return p.parseArray(depth),
            '"' => return .{ .string = try p.parseString() },
            't' => {
                try p.expectWord("true");
                return .{ .boolean = true };
            },
            'f' => {
                try p.expectWord("false");
                return .{ .boolean = false };
            },
            'n' => {
                try p.expectWord("null");
                return .null;
            },
            '-', '0'...'9' => return .{ .number = try p.parseNumber() },
            else => return error.SyntaxError,
        }
    }

    fn expectWord(p: *JsonParser, word: []const u8) JsonError!void {
        if (p.pos + word.len > p.text.len) return error.SyntaxError;
        if (!std.mem.eql(u8, p.text[p.pos..][0..word.len], word)) return error.SyntaxError;
        p.pos += word.len;
    }

    fn parseNumber(p: *JsonParser) JsonError!f64 {
        const start = p.pos;
        if (p.pos < p.text.len and p.text[p.pos] == '-') p.pos += 1;
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        return std.fmt.parseFloat(f64, p.text[start..p.pos]) catch error.SyntaxError;
    }

    fn parseString(p: *JsonParser) JsonError![]const u8 {
        std.debug.assert(p.text[p.pos] == '"');
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= p.text.len) return error.SyntaxError;
            const c = p.text[p.pos];
            if (c == '"') {
                p.pos += 1;
                return out.toOwnedSlice(p.arena);
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.pos >= p.text.len) return error.SyntaxError;
                const e = p.text[p.pos];
                p.pos += 1;
                switch (e) {
                    '"', '\\', '/' => try out.append(p.arena, e),
                    'b' => try out.append(p.arena, 8),
                    'f' => try out.append(p.arena, 12),
                    'n' => try out.append(p.arena, '\n'),
                    'r' => try out.append(p.arena, '\r'),
                    't' => try out.append(p.arena, '\t'),
                    'u' => {
                        if (p.pos + 4 > p.text.len) return error.SyntaxError;
                        const cp = std.fmt.parseInt(u16, p.text[p.pos..][0..4], 16) catch
                            return error.SyntaxError;
                        p.pos += 4;
                        var buf: [4]u8 = undefined;
                        // Lone surrogates encode as U+FFFD (config files
                        // don't need astral-plane fidelity).
                        const n = std.unicode.utf8Encode(cp, &buf) catch
                            std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                        try out.appendSlice(p.arena, buf[0..n]);
                    },
                    else => return error.SyntaxError,
                }
                continue;
            }
            try out.append(p.arena, c);
            p.pos += 1;
        }
    }

    fn parseArray(p: *JsonParser, depth: u32) JsonError!Value {
        p.pos += 1; // '['
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            if (p.text[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            try items.append(p.arena, try p.parseValue(depth + 1));
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            switch (p.text[p.pos]) {
                ',' => p.pos += 1, // trailing comma allowed: loop re-checks ']'
                ']' => {},
                else => return error.SyntaxError,
            }
        }
        return .{ .array = try items.toOwnedSlice(p.arena) };
    }

    fn parseObject(p: *JsonParser, depth: u32) JsonError!Value {
        p.pos += 1; // '{'
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList(Value) = .empty;
        var key_pos: std.ArrayList(u32) = .empty;
        while (true) {
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            if (p.text[p.pos] == '}') {
                p.pos += 1;
                break;
            }
            if (p.text[p.pos] != '"') return error.SyntaxError;
            if (p.key_positions) try key_pos.append(p.arena, @intCast(p.pos));
            const key = try p.parseString();
            p.skipWs();
            if (p.pos >= p.text.len or p.text[p.pos] != ':') return error.SyntaxError;
            p.pos += 1;
            p.skipWs();
            try keys.append(p.arena, key);
            try vals.append(p.arena, try p.parseValue(depth + 1));
            p.skipWs();
            if (p.pos >= p.text.len) return error.SyntaxError;
            switch (p.text[p.pos]) {
                ',' => p.pos += 1,
                '}' => {},
                else => return error.SyntaxError,
            }
        }
        return .{ .object = .{
            .keys = try keys.toOwnedSlice(p.arena),
            .vals = try vals.toOwnedSlice(p.arena),
            .key_pos = try key_pos.toOwnedSlice(p.arena),
        } };
    }
};

// ===========================================================================
// tests
// ===========================================================================

const testing = std.testing;

test "jsonc: comments, trailing commas, escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parseJsonc(arena.allocator(),
        \\{
        \\  // line comment
        \\  "a": [1, 2, 3,], /* block
        \\     comment */
        \\  "b": { "nested": true, },
        \\  "s": "q\"\\\nA",
        \\  "n": -1.5e2,
        \\  "z": null,
        \\}
    );
    try testing.expect(v == .object);
    const a = v.object.get("a").?;
    try testing.expectEqual(@as(usize, 3), a.array.len);
    try testing.expectEqual(@as(f64, 2), a.array[1].number);
    try testing.expect(v.object.get("b").?.object.get("nested").?.boolean);
    try testing.expectEqualStrings("q\"\\\nA", v.object.get("s").?.string);
    try testing.expectEqual(@as(f64, -150), v.object.get("n").?.number);
    try testing.expect(v.object.get("z").? == .null);
    try testing.expectEqual(@as(?Value, null), v.object.get("missing"));
}

test "jsonc: key positions are opt-in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\{
        \\  "a": 1,
        \\  "b": { "c": 2 }
        \\}
    ;
    const plain = try parseJsonc(arena.allocator(), text);
    try testing.expectEqual(@as(usize, 0), plain.object.key_pos.len);
    try testing.expectEqual(@as(?u32, null), plain.object.keyPos("a"));

    const keyed = try parseJsoncKeyed(arena.allocator(), text);
    try testing.expectEqual(@as(?u32, 4), keyed.object.keyPos("a"));
    try testing.expectEqual(@as(?u32, 14), keyed.object.keyPos("b"));
    try testing.expectEqualStrings("\"a\"", text[4..7]);
    try testing.expectEqualStrings("\"b\"", text[14..17]);
    try testing.expectEqual(@as(?u32, 21), keyed.object.get("b").?.object.keyPos("c"));
    try testing.expectEqual(@as(?u32, null), keyed.object.keyPos("missing"));
}

test "jsonc: syntax errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "",         "{",   "{\"a\" 1}",      "[1 2]",
        "{,}",      "tru", "\"unterminated", "{\"a\": }",
        "[1] junk", "01a",
    };
    for (bad) |text| {
        try testing.expectError(error.SyntaxError, parseJsonc(arena.allocator(), text));
    }
}
