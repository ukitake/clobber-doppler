const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "doppler_scrub",
        .linkage = .static,
        .root_module = core_mod,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // Also emit a shared library for future OBS/Android consumers
    const lib_shared = b.addLibrary(.{
        .name = "doppler_scrub",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_shared.linkLibC();
    b.installArtifact(lib_shared);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "doppler_scrub", .module = core_mod },
        },
    });

    const cli = b.addExecutable(.{
        .name = "doppler-cli",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const run_step = b.step("run", "Run doppler-cli (pass args after --)");
    run_step.dependOn(&run_cli.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run DSP unit tests (40-200 Hz blank band)");
    test_step.dependOn(&run_unit_tests.step);
}
