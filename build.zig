const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // Building the nestedtext lib.
    const lib = b.addStaticLibrary("nestedtext", "src/nestedtext.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    // Building the nt-cli exe.
    const exe = b.addExecutable("nt-cli", "src/cli.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("clap", "deps/zig-clap/clap.zig");
    exe.install();

    // Running tests.
    var inline_tests = b.addTest("src/nestedtext.zig");
    inline_tests.setBuildMode(mode);
    var testsuite = b.addTest("tests/testsuite.zig");
    testsuite.setBuildMode(mode);
    testsuite.addPackagePath("nestedtext", "src/nestedtext.zig");

    // Define the 'test' subcommand.
    // In order:
    //  - Run inline lib tests
    //  - Build the lib and exe
    //  - Run testsuite
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&inline_tests.step);
    test_step.dependOn(&lib.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&testsuite.step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(&exe.step); // TODO: Is this needed?

    // Define the 'run' subcommand.
    const run_step = b.step("run", "Run the NestedText CLI");
    run_step.dependOn(&run_cmd.step);
}
