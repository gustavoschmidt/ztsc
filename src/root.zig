//! ZTSC — Zig TypeScript Checker (library root).
//!
//! Module layout: the public modules re-exported for use across the crate.
//!
//! This file serves two roles with different membership rules: the `pub const`
//! list is the crate's public surface (what a consumer may name), while the
//! `test {}` block at the bottom is the unit-test roster `zig build test`
//! walks. Every module with in-file tests belongs in the roster whether or not
//! it belongs in the surface — a module left out of it is silently untested.

pub const source = @import("frontend/source.zig");
pub const intern = @import("intern.zig");
pub const spelling = @import("spelling.zig");
pub const zeropage = @import("zeropage.zig");
pub const scanner = @import("frontend/scanner.zig");
pub const diagnostics = @import("frontend/diagnostics.zig");
pub const directives = @import("frontend/directives.zig");
pub const literals = @import("frontend/literals.zig");
pub const ast = @import("frontend/ast.zig");
pub const parser = @import("frontend/parser.zig");
pub const binder = @import("frontend/binder.zig");
pub const decl_spaces = @import("frontend/decl_spaces.zig");
pub const impl_expected = @import("frontend/impl_expected.zig");
pub const types = @import("types.zig");
pub const numeric_lit = @import("numeric_lit.zig");
pub const libs = @import("libs.zig");
pub const paths = @import("link/paths.zig");
pub const resolve = @import("link/resolve.zig");
pub const modules = @import("link/modules.zig");
pub const global_dup = @import("link/global_dup.zig");
pub const package_id = @import("link/package_id.zig");
pub const checker = @import("checker.zig");
pub const driver = @import("driver.zig");
pub const schedule = @import("schedule.zig");
pub const tsconfig = @import("tsconfig.zig");
pub const jsonc = @import("jsonc.zig");
pub const glob = @import("glob.zig");
pub const render = @import("report/render.zig");
pub const report = @import("report/report.zig");

pub const version = "0.0.1-dev";

test {
    _ = source;
    _ = intern;
    _ = spelling;
    _ = zeropage;
    _ = scanner;
    _ = diagnostics;
    _ = directives;
    _ = literals;
    _ = ast;
    _ = parser;
    _ = binder;
    _ = decl_spaces;
    _ = impl_expected;
    _ = types;
    _ = libs;
    _ = paths;
    _ = resolve;
    _ = modules;
    _ = global_dup;
    _ = checker;
    _ = driver;
    _ = schedule;
    _ = tsconfig;
    _ = jsonc;
    _ = glob;
    _ = render;
    _ = report;
}
