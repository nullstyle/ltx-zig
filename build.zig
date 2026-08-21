const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ltx = b.addModule("ltx", .{
        .root_source_file = b.path("src/ltx.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library = b.addLibrary(.{
        .name = "ltx",
        .root_module = ltx,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{ .root_module = ltx });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const interoperability = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interoperability.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = ltx }},
        }),
    });
    const run_interoperability = b.addRunArtifact(interoperability);

    const malformed = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/malformed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = ltx }},
        }),
    });
    const run_malformed = b.addRunArtifact(malformed);

    const test_step = b.step("test", "Run all LTX tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_interoperability.step);
    test_step.dependOn(&run_malformed.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
            "tests",
            "tools/fixturegen",
        },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check Zig source formatting");
    fmt_check_step.dependOn(&fmt.step);

    const host_ltx = b.createModule(.{
        .root_source_file = b.path("src/ltx.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const fixturegen = b.addExecutable(.{
        .name = "ltx-fixturegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fixturegen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_fixturegen = b.addRunArtifact(fixturegen);
    const fixturegen_step = b.step("fixturegen", "Write a deterministic v3 fixture to stdout");
    fixturegen_step.dependOn(&run_fixturegen.step);

    const interop_fixturegen = b.addRunArtifact(fixturegen);
    const generated_fixture = interop_fixturegen.captureStdOut(.{
        .basename = "ltx-zig.ltx",
    });
    const go_verify = b.addSystemCommand(&.{ "go", "run", "." });
    go_verify.setCwd(b.path("tools/upstream_verify"));
    go_verify.setEnvironmentVariable("GOWORK", "off");
    go_verify.addFileArg(generated_fixture);
    const interop_step = b.step("interop", "Verify Zig output with pinned Go LTX");
    interop_step.dependOn(&go_verify.step);

    const upstream_fixture_name = b.option(
        []const u8,
        "fixture",
        "Pinned Go fixture name; see tools/upstream_verify/fixturegen",
    ) orelse "incremental";
    const upstream_fixture = b.addSystemCommand(&.{
        "go",
        "run",
        "./fixturegen",
        upstream_fixture_name,
    });
    upstream_fixture.setCwd(b.path("tools/upstream_verify"));
    upstream_fixture.setEnvironmentVariable("GOWORK", "off");
    const upstream_fixture_step = b.step(
        "upstream-fixture",
        "Write a selected pinned-Go fixture to stdout",
    );
    upstream_fixture_step.dependOn(&upstream_fixture.step);

    const materialize_fixtures = b.addSystemCommand(&.{
        "go",
        "run",
        "./materialize",
        "../../tests/fixtures",
    });
    materialize_fixtures.setCwd(b.path("tools/upstream_verify"));
    materialize_fixtures.setEnvironmentVariable("GOWORK", "off");
    const materialize_fixtures_step = b.step(
        "materialize-fixtures",
        "Regenerate committed binary fixtures from reviewed hex mirrors",
    );
    materialize_fixtures_step.dependOn(&materialize_fixtures.step);

    const check_fixtures = b.addSystemCommand(&.{
        "go",
        "run",
        "./materialize",
        "--check",
        "../../tests/fixtures",
    });
    check_fixtures.setCwd(b.path("tools/upstream_verify"));
    check_fixtures.setEnvironmentVariable("GOWORK", "off");
    const check_fixtures_step = b.step(
        "check-fixtures",
        "Check binary fixtures against reviewed hex mirrors",
    );
    check_fixtures_step.dependOn(&check_fixtures.step);
}
