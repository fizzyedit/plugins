const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This tool only ever needs to build in CI (ubuntu-latest) or on a maintainer's Linux/macOS
    // machine — never on an end user's machine, and never on Windows. Zig 0.16's
    // dependency-fetch path has a temp-zip-file bug that zig-sqlite's own migration notes (PR
    // #205) say is still broken on Windows even with their workaround; since this dependency's
    // amalgamation download only runs where `zig build` actually executes, staying off Windows
    // sidesteps it entirely rather than needing a vendored copy.
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const sqlite_mod = sqlite_dep.module("sqlite");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("sqlite", sqlite_mod);

    const exe = b.addExecutable(.{
        .name = "store",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the plugin store CLI (ingest / export / validate)");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
