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
                .{ .name = "ltx_wal", .module = ltx_zig.module("ltx_wal") },
                .{ .name = "ltx_object", .module = ltx_zig.module("ltx_object") },
                .{ .name = "ltx_s3", .module = ltx_zig.module("ltx_s3") },
                .{ .name = "ltx_replica", .module = ltx_zig.module("ltx_replica") },
                .{ .name = "ltx_capture", .module = ltx_zig.module("ltx_capture") },
                .{ .name = "ltx_replication", .module = ltx_zig.module("ltx_replication") },
                .{ .name = "ltx_resources", .module = ltx_zig.module("ltx_resources") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const compile_step = b.step(
        "compile",
        "Compile the current external package consumer without running it",
    );
    compile_step.dependOn(&tests.step);
    const test_step = b.step("test", "Test the public modules as an external dependency");
    test_step.dependOn(&run_tests.step);
}
