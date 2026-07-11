//! ZTSC — Zig TypeScript Checker (library root).
//!
//! Module layout. Only the modules used so far exist;
//! scanner/parser/binder/checker land in later milestones.

pub const source = @import("source.zig");
pub const intern = @import("intern.zig");
pub const scanner = @import("scanner.zig");

pub const version = "0.0.1";

test {
    _ = source;
    _ = intern;
    _ = scanner;
}
