//! Conformance suite runner (skeleton).
//!
//! Discovers cases in `test/conformance/`: each case is a `<name>.ts` source
//! file with an expected-diagnostics snapshot `<name>.expected` next to it
//! (see test/conformance/README.md). For every case, the runner will
//! eventually check the .ts file with ztsc and diff the produced diagnostics
//! (error code + span) against the snapshot, differentially validated
//! against tsc.
//!
//! M0: there are no cases and no checker yet, so discovery must find zero
//! cases and the suite passes trivially.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const Case = struct {
    /// File name of the .ts source, allocated by the caller.
    name: []const u8,
};

fn discoverCases(io: Io, gpa: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(Case) {
    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |c| gpa.free(c.name);
        cases.deinit(gpa);
    }

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return cases, // no conformance dir -> zero cases
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;
        try cases.append(gpa, .{ .name = try gpa.dupe(u8, entry.name) });
    }
    return cases;
}

test "conformance: discover and run cases" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var cases = try discoverCases(io, gpa, build_options.conformance_dir);
    defer {
        for (cases.items) |c| gpa.free(c.name);
        cases.deinit(gpa);
    }

    var failed: usize = 0;
    for (cases.items) |case| {
        // M0: no checker yet. Once M4 lands, run the checker here and diff
        // diagnostics against the .expected snapshot.
        std.debug.print("conformance: case {s} skipped (no checker yet)\n", .{case.name});
        failed += 1;
    }

    // Zero cases in M0; any case added before the checker exists must fail
    // loudly so we don't silently skip real cases.
    try std.testing.expectEqual(@as(usize, 0), failed);
}
