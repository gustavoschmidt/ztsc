//! TS2595: `import { Foo } from "./a"` where `a`'s whole body is `class Foo {}
//! export = Foo` — "'Foo' can only be imported by using a default import."
//! tsc's `reportInvalidImportEqualsExportMember`, reached from
//! `getExternalModuleMember` when a named import of an `export =` module found
//! the name through neither the exported entity's members nor the property set
//! of the exported value's type, and the name turns out to BE the exported
//! entity.
//!
//! Split across the two phases because tsc's condition is:
//!
//!     symbolFromModule   = getExportOfModule(exportEquals, name)      -- link
//!     symbolFromVariable = getPropertyOfType(typeof exportEquals, name) -- HERE
//!     if (!symbolFromModule && !symbolFromVariable
//!         && locals.get(name) is the export-assigned symbol) error
//!
//! Only the middle line needs a type, and it is not a formality: `class Foo {
//! static Foo: number }` really does carry the property, and tsc then binds the
//! import and reports nothing (verified against tsgo 7.0.2). So `link/modules.
//! zig` settles the other two lines and parks the rest as an
//! `EqDefaultImport`; this file finishes them.
//!
//! Runs once per owned file over a list that is empty for virtually every
//! program — the specifier is an error, so no compiling code parks one.

const std = @import("std");
const modules = @import("../link/modules.zig");
const props_zig = @import("props.zig");

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;

/// Answer this file's parked TS2595 questions. The import binding itself is
/// already resolved (leniently, to the missing property's `any`) — this adds
/// only the diagnostic, exactly as tsc does: the error does not stop the name
/// from being usable, so a `let x: Foo` beside it stays quiet.
pub fn checkFileExportEqualsImports(c: *Checker) Error!void {
    for (c.prog.eqDefaultImportsOf(c.cur_file)) |q| {
        const base = try c.typeOfSymbol(c.toGlobalIn(q.sym_file, q.sym));
        // The same property lookup `targetValueType` uses to give the binding
        // its type, so "reported" and "bound to something real" can never
        // disagree about whether the property was there.
        if (try props_zig.propOfType(c, base, q.name) != null) continue;
        try c.diagFmt(2595, q.span, "'{s}' can only be imported by using a default import.", .{c.atomText(q.name)});
    }
}
