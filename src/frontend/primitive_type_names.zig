//! The six primitive TYPE names — the names that resolve in the type space and
//! nowhere else, with no declaration in any file behind them.
//!
//! tsc's `checkAndReportErrorForUsingTypeAsValue` carries this list verbatim,
//! and `bigint`, `symbol`, `object`, `void` and `undefined` are deliberately
//! NOT on it: those spell types too, but a name-not-found report for one of
//! them goes through the ordinary spelling-suggestion path
//! (`bigint` → "Did you mean 'BigInt'?"), which is exactly what tells the two
//! groups apart against the oracle.
//!
//! Its own file because two layers ask the same question about the same six
//! names and neither owns the other: the checker, for the value-position
//! TS2693 (`checker/names.zig`), and the linker, for TS2661 — an
//! `export { string }` names something the global scope answers, so it is "not
//! a local declaration" rather than "not a name at all" (`link/modules.zig`).

const std = @import("std");

/// Is `text` one of the six?
pub fn isPrimitiveTypeName(text: []const u8) bool {
    const names = [_][]const u8{ "any", "string", "number", "boolean", "never", "unknown" };
    for (names) |n| {
        if (std.mem.eql(u8, text, n)) return true;
    }
    return false;
}

test isPrimitiveTypeName {
    for ([_][]const u8{ "any", "string", "number", "boolean", "never", "unknown" }) |n| {
        try std.testing.expect(isPrimitiveTypeName(n));
    }
    for ([_][]const u8{ "bigint", "symbol", "object", "void", "undefined", "String", "", "numberx" }) |n| {
        try std.testing.expect(!isPrimitiveTypeName(n));
    }
}
