//! ZTSC — Zig TypeScript Checker (library root).
//!
//! Module layout: the public modules re-exported for use across the crate.

pub const source = @import("frontend/source.zig");
pub const intern = @import("intern.zig");
pub const zeropage = @import("zeropage.zig");
pub const scanner = @import("frontend/scanner.zig");
pub const diagnostics = @import("frontend/diagnostics.zig");
pub const directives = @import("frontend/directives.zig");
pub const ast = @import("frontend/ast.zig");
pub const parser = @import("frontend/parser.zig");
pub const binder = @import("frontend/binder.zig");
pub const types = @import("types.zig");
pub const libs = @import("libs.zig");
pub const paths = @import("link/paths.zig");
pub const resolve = @import("link/resolve.zig");
pub const modules = @import("link/modules.zig");
pub const checker = @import("checker.zig");
pub const tsconfig = @import("tsconfig.zig");
pub const render = @import("report/render.zig");
pub const report = @import("report/report.zig");

pub const version = "0.0.1-dev";

test {
    _ = source;
    _ = intern;
    _ = zeropage;
    _ = scanner;
    _ = diagnostics;
    _ = directives;
    _ = ast;
    _ = parser;
    _ = binder;
    _ = types;
    _ = libs;
    _ = paths;
    _ = resolve;
    _ = modules;
    _ = checker;
    _ = tsconfig;
    _ = render;
    _ = report;
}
