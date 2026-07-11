const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Library module ------------------------------------------------
    const mod = b.addModule("ztsc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Executable ------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "ztsc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztsc", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ztsc");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // --- Tests -------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    // Conformance runner: discovers cases in test/conformance (0 cases in M0).
    const conf_opts = b.addOptions();
    conf_opts.addOption([]const u8, "conformance_dir", b.pathFromRoot("test/conformance"));
    const conf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/run_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = conf_opts.createModule() },
                .{ .name = "ztsc", .module = mod },
            },
        }),
    });

    const test_step = b.step("test", "Run unit tests and the conformance suite");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(conf_tests).step);

    // --- Bench -------------------------------------------------------------
    // `zig build bench` builds a ReleaseFast binary into zig-out/bench/ztsc;
    // bench/run.sh drives it.
    const bench_exe = b.addExecutable(.{
        .name = "ztsc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ztsc", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                }) },
            },
        }),
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bench" } },
    });
    const bench_step = b.step("bench", "Build the ReleaseFast benchmark binary");
    bench_step.dependOn(&install_bench.step);
    const echo = b.addSystemCommand(&.{
        "echo", b.fmt("bench binary: {s}", .{b.getInstallPath(.{ .custom = "bench" }, "ztsc")}),
    });
    echo.step.dependOn(&install_bench.step);
    bench_step.dependOn(&echo.step);
}
