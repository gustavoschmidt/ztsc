//! ZTSC — Zig TypeScript Checker (library root).
//!
//! Module layout (PLAN.md §2.4). Only the modules that M0 uses exist;
//! scanner/parser/binder/checker land in later milestones.

pub const source = @import("source.zig");
pub const intern = @import("intern.zig");
pub const scanner = @import("scanner.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

pub const version = "0.0.1";

test {
    _ = source;
    _ = intern;
    _ = scanner;
    _ = diagnostics;
    _ = ast;
    _ = parser;
}
