const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("glean", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "glean",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run glean module tests");
    test_step.dependOn(&run_tests.step);

    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });
    const linux_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = linux_target,
        .optimize = optimize,
    });
    const linux_tests = b.addTest(.{ .root_module = linux_module });
    const linux_exe = b.addExecutable(.{
        .name = "glean-linux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = linux_target,
            .optimize = optimize,
        }),
    });
    const fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "build.zig.zon", "src" });
    const ci = b.step("ci", "Format check, tests, and host and Linux builds");
    ci.dependOn(&fmt.step);
    ci.dependOn(&run_tests.step);
    ci.dependOn(&exe.step);
    ci.dependOn(&linux_tests.step);
    ci.dependOn(&linux_exe.step);
}
