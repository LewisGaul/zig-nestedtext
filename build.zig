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

    const lib = b.addStaticLibrary("nestedtext", "src/nestedtext.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    var tests = b.addTest("src/nestedtext.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);

    const exe = b.addExecutable("nt-cli", "src/cli.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("clap", "deps/zig-clap/clap.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(&lib.step);
    run_cmd.step.dependOn(&exe.step);

    const run_step = b.step("run", "Run the NestedText CLI");
    run_step.dependOn(&run_cmd.step);
}
