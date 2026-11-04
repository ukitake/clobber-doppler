const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPffft(b, core_mod);

    const lib = b.addLibrary(.{
        .name = "doppler_scrub",
        .linkage = .static,
        .root_module = core_mod,
    });
    b.installArtifact(lib);

    // Also emit a shared library for future OBS/Android consumers
    const shared_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPffft(b, shared_mod);
    const lib_shared = b.addLibrary(.{
        .name = "doppler_scrub",
        .linkage = .dynamic,
        .root_module = shared_mod,
    });
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

    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPffft(b, unit_test_mod);
    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run DSP unit tests (Doppler ridge scrub)");
    test_step.dependOn(&run_unit_tests.step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doppler_scrub", .module = core_mod },
            },
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
}

fn linkPffft(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("third_party/pffft"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/pffft/pffft.c"),
        .flags = &.{ "-std=c99", "-O3", "-ffast-math" },
    });
}
