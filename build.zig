const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    // Building the nestedtext lib.
    const lib = b.addStaticLibrary(.{
        .name = "nestedtext",
        .root_source_file = b.path("src/nestedtext.zig"),
        .target = target,
        .optimize = mode,
    });
    b.installArtifact(lib);

    // Building the nt-cli exe.
    const exe = b.addExecutable(.{
        .name = "nt-cli",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = mode,
    });
    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));
    b.installArtifact(exe);

    // Running tests.
    const inline_tests = b.addTest(.{ .root_source_file = b.path("src/nestedtext.zig") });
    var testsuite = b.addTest(.{ .root_source_file = b.path("tests/testsuite.zig") });
    const module = b.addModule("nestedtext", .{ .root_source_file = b.path("src/nestedtext.zig") });
    testsuite.root_module.addImport("nestedtext", module);
    var inline_tests_run = b.addRunArtifact(inline_tests);
    var testsuite_run = b.addRunArtifact(testsuite);

    // Define the 'test' subcommand.
    // In order:
    //  - Run inline lib tests
    //  - Build the lib and exe
    //  - Run testsuite
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&inline_tests_run.step);
    test_step.dependOn(&lib.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&testsuite_run.step);

    // Define the 'run' subcommand.
    const run_step = b.step("run", "Run the NestedText CLI");
    const exe_run = b.addRunArtifact(exe);
    if (b.args) |argv| exe_run.addArgs(argv);
    run_step.dependOn(&exe_run.step);
}
