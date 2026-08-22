const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ltx = b.addModule("ltx", .{
        .root_source_file = b.path("src/ltx.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host_ltx = b.createModule(.{
        .root_source_file = b.path("src/ltx.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const host_lz4 = b.createModule(.{
        .root_source_file = b.path("src/lz4_block.zig"),
        .target = b.graph.host,
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

    const fuzz_decoder_tests = b.addTest(.{
        .name = "ltx-decoder-fuzz-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_fuzz_decoder_tests = b.addRunArtifact(fuzz_decoder_tests);
    // Zig 0.16 does not restore discovered fuzz-test names from a cached run.
    run_fuzz_decoder_tests.has_side_effects = true;
    const apply_tests = b.addTest(.{
        .name = "ltx-apply-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/apply.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_apply_tests = b.addRunArtifact(apply_tests);
    run_apply_tests.has_side_effects = true;
    const fuzz_lz4_tests = b.addTest(.{
        .name = "ltx-lz4-fuzz-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_lz4.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "lz4_block", .module = host_lz4 }},
        }),
    });
    const run_fuzz_lz4_tests = b.addRunArtifact(fuzz_lz4_tests);
    run_fuzz_lz4_tests.has_side_effects = true;

    const test_step = b.step("test", "Run all LTX tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_interoperability.step);
    test_step.dependOn(&run_malformed.step);
    test_step.dependOn(&run_fuzz_decoder_tests.step);
    test_step.dependOn(&run_apply_tests.step);
    test_step.dependOn(&run_fuzz_lz4_tests.step);

    const fuzz_step = b.step(
        "fuzz",
        "Replay fuzz corpora; pass --fuzz[=N] to search for failures",
    );
    fuzz_step.dependOn(&run_fuzz_decoder_tests.step);
    fuzz_step.dependOn(&run_apply_tests.step);
    fuzz_step.dependOn(&run_fuzz_lz4_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
            "tests",
            "benchmarks",
            "tools/fixturegen",
        },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check Zig source formatting");
    fmt_check_step.dependOn(&fmt.step);

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

    const benchmark_lz4 = b.createModule(.{
        .root_source_file = b.path("src/lz4_block.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const benchmark_executable = b.addExecutable(.{
        .name = "ltx-lz4-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/lz4.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "lz4_block", .module = benchmark_lz4 }},
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark_executable);
    const benchmark_step = b.step("bench", "Benchmark raw LZ4 page compression");
    benchmark_step.dependOn(&run_benchmark.step);

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

    const legacy_fixture_name = b.option(
        []const u8,
        "legacy-fixture",
        "Historical pinned-Go fixture: snapshot-zero or mixed",
    ) orelse "mixed";
    const legacy_fixture = b.addSystemCommand(&.{
        "go",
        "run",
        ".",
        legacy_fixture_name,
    });
    legacy_fixture.setCwd(b.path("tools/legacy_fixturegen"));
    legacy_fixture.setEnvironmentVariable("GOWORK", "off");
    const legacy_fixture_step = b.step(
        "upstream-legacy-fixture",
        "Write a selected historical pinned-Go fixture to stdout",
    );
    legacy_fixture_step.dependOn(&legacy_fixture.step);

    const check_legacy_snapshot = b.addSystemCommand(&.{
        "go",
        "run",
        ".",
        "--check",
        "snapshot-zero",
        "../../tests/fixtures/go_v3_legacy_unflagged.ltx",
    });
    check_legacy_snapshot.setCwd(b.path("tools/legacy_fixturegen"));
    check_legacy_snapshot.setEnvironmentVariable("GOWORK", "off");
    const check_legacy_mixed = b.addSystemCommand(&.{
        "go",
        "run",
        ".",
        "--check",
        "mixed",
        "../../tests/fixtures/go_v3_legacy_mixed.ltx",
    });
    check_legacy_mixed.setCwd(b.path("tools/legacy_fixturegen"));
    check_legacy_mixed.setEnvironmentVariable("GOWORK", "off");
    const check_legacy_step = b.step(
        "check-legacy-fixtures",
        "Check historical Go output against committed legacy fixtures",
    );
    check_legacy_step.dependOn(&check_legacy_snapshot.step);
    check_legacy_step.dependOn(&check_legacy_mixed.step);

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
