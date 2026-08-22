const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ltx_zig = b.dependency("ltx_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = ltx_zig.module("ltx") },
                .{ .name = "ltx_sqlite", .module = ltx_zig.module("ltx_sqlite") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const compile_step = b.step(
        "compile",
        "Compile the 0.1 public API contract without running it",
    );
    compile_step.dependOn(&tests.step);
    const test_step = b.step("test", "Test the public modules as an external dependency");
    test_step.dependOn(&run_tests.step);
}
