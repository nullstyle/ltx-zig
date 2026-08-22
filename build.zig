const std = @import("std");
const valid_chain_manifest = @import("tests/valid_chain_manifest.zig");

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
    const ltx_sqlite = b.addModule("ltx_sqlite", .{
        .root_source_file = b.path("src/sqlite_store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ltx", .module = ltx }},
    });
    const host_sqlite_store = b.createModule(.{
        .root_source_file = b.path("src/sqlite_store.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "ltx", .module = host_ltx }},
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
    const portability_sqlite_tests = b.addTest(.{
        .name = "ltx-sqlite-portability-tests",
        .root_module = ltx_sqlite,
    });

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
    const compactor_tests = b.addTest(.{
        .name = "ltx-compactor-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compactor.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_compactor_tests = b.addRunArtifact(compactor_tests);
    run_compactor_tests.has_side_effects = true;
    const litestream_compaction_tests = b.addTest(.{
        .name = "ltx-litestream-compaction-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/litestream_compaction.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_litestream_compaction_tests = b.addRunArtifact(litestream_compaction_tests);
    run_litestream_compaction_tests.has_side_effects = true;
    const valid_chain_cases = b.createModule(.{
        .root_source_file = b.path("tests/valid_chain_cases.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "ltx", .module = host_ltx }},
    });
    const valid_chain_matrix_tests = b.addTest(.{
        .name = "ltx-valid-chain-matrix-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/valid_chain_matrix.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_valid_chain_matrix_tests = b.addRunArtifact(valid_chain_matrix_tests);
    run_valid_chain_matrix_tests.has_side_effects = true;
    const sqlite_store_unit_tests = b.addTest(.{
        .name = "ltx-sqlite-store-unit-tests",
        .root_module = host_sqlite_store,
    });
    const run_sqlite_store_unit_tests = b.addRunArtifact(sqlite_store_unit_tests);
    const sqlite_store_tests = b.addTest(.{
        .name = "ltx-sqlite-store-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sqlite_store.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = host_ltx },
                .{ .name = "ltx_sqlite", .module = host_sqlite_store },
            },
        }),
    });
    const run_sqlite_store_tests = b.addRunArtifact(sqlite_store_tests);
    run_sqlite_store_tests.has_side_effects = true;
    const sqlite_store_crash_child = b.addExecutable(.{
        .name = "ltx-sqlite-store-crash-child",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sqlite_store_crash_child.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = host_ltx },
                .{ .name = "ltx_sqlite", .module = host_sqlite_store },
            },
        }),
    });
    const crash_options = b.addOptions();
    crash_options.addOptionPath("child_path", sqlite_store_crash_child.getEmittedBin());
    const crash_options_module = crash_options.createModule();
    const sqlite_store_crash_tests = b.addTest(.{
        .name = "ltx-sqlite-store-crash-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sqlite_store_crash.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = host_ltx },
                .{ .name = "ltx_sqlite", .module = host_sqlite_store },
                .{ .name = "crash_options", .module = crash_options_module },
            },
        }),
    });
    const run_sqlite_store_crash_tests = b.addRunArtifact(sqlite_store_crash_tests);
    run_sqlite_store_crash_tests.has_side_effects = true;

    const sqlite_integration_module = b.createModule(.{
        .root_source_file = b.path("tests/sqlite_integration.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ltx", .module = host_ltx },
            .{ .name = "ltx_sqlite", .module = host_sqlite_store },
            .{ .name = "crash_options", .module = crash_options_module },
        },
    });
    sqlite_integration_module.linkSystemLibrary("sqlite3", .{});
    const sqlite_integration_tests = b.addTest(.{
        .name = "ltx-sqlite-integration-tests",
        .root_module = sqlite_integration_module,
    });
    const run_sqlite_integration_tests = b.addRunArtifact(sqlite_integration_tests);
    run_sqlite_integration_tests.has_side_effects = true;
    const sqlite_integration_step = b.step(
        "sqlite-integration",
        "Run live host-SQLite WAL and generation-store integration tests",
    );
    sqlite_integration_step.dependOn(&run_sqlite_integration_tests.step);
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
    test_step.dependOn(&run_compactor_tests.step);
    test_step.dependOn(&run_litestream_compaction_tests.step);
    test_step.dependOn(&run_valid_chain_matrix_tests.step);
    test_step.dependOn(&run_sqlite_store_unit_tests.step);
    test_step.dependOn(&run_sqlite_store_tests.step);
    test_step.dependOn(&run_sqlite_store_crash_tests.step);
    test_step.dependOn(&run_fuzz_lz4_tests.step);

    const compile_tests_step = b.step(
        "compile-tests",
        "Compile the core and SQLite module tests without running them",
    );
    compile_tests_step.dependOn(&unit_tests.step);
    compile_tests_step.dependOn(&portability_sqlite_tests.step);

    const fuzz_step = b.step(
        "fuzz",
        "Replay fuzz corpora; pass --fuzz[=N] to search for failures",
    );
    fuzz_step.dependOn(&run_fuzz_decoder_tests.step);
    fuzz_step.dependOn(&run_apply_tests.step);
    fuzz_step.dependOn(&run_compactor_tests.step);
    fuzz_step.dependOn(&run_fuzz_lz4_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
            "tests",
            "examples",
            "benchmarks",
            "tools/fixturegen",
            "tools/compaction_fixturegen",
            "tools/litestream_compaction_fixturegen",
            "tools/litestream_interop",
            "tools/valid_chain_fixturegen",
            "tools/release_check",
        },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check Zig source formatting");
    fmt_check_step.dependOn(&fmt.step);

    const round_trip_example = b.addExecutable(.{
        .name = "ltx-round-trip-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/round_trip.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const run_round_trip_example = b.addRunArtifact(round_trip_example);
    const round_trip_example_step = b.step(
        "example-round-trip",
        "Run the bounded allocation-free encode/decode example",
    );
    round_trip_example_step.dependOn(&run_round_trip_example.step);

    const consumer_smoke = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--cache-dir",
        "../../.zig-cache/consumer-smoke",
    });
    consumer_smoke.setCwd(b.path("tests/consumer"));
    consumer_smoke.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    consumer_smoke.has_side_effects = true;
    const consumer_smoke_step = b.step(
        "consumer-smoke",
        "Test both public modules through an external path dependency",
    );
    consumer_smoke_step.dependOn(&consumer_smoke.step);

    const release_check = b.addExecutable(.{
        .name = "ltx-release-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/release_check/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_release_check = b.addRunArtifact(release_check);
    run_release_check.addFileArg(b.path("build.zig.zon"));
    run_release_check.addFileArg(b.path("CHANGELOG.md"));
    run_release_check.addFileArg(b.path("LICENSE"));
    run_release_check.addFileArg(b.path("LICENSE.pierrec-lz4"));
    run_release_check.addFileArg(b.path("LICENSE.celld-litestream-apache-2.0"));
    if (b.option([]const u8, "release-tag", "Release tag expected for package version")) |tag| {
        run_release_check.addArg(tag);
    }
    const release_check_step = b.step(
        "release-check",
        "Check package version, changelog, and optional release tag",
    );
    release_check_step.dependOn(&run_release_check.step);
    const release_check_tests = b.addTest(.{
        .name = "ltx-release-check-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/release_check/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_release_check_tests = b.addRunArtifact(release_check_tests);
    test_step.dependOn(&run_release_check_tests.step);

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

    const compaction_fixturegen = b.addExecutable(.{
        .name = "ltx-compaction-fixturegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compaction_fixturegen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ltx", .module = host_ltx }},
        }),
    });
    const compaction_fixture_name = b.option(
        []const u8,
        "compaction-fixture",
        "Zig compaction fixture: merge, deletion, or no-checksum",
    ) orelse "merge";
    const run_compaction_fixturegen = b.addRunArtifact(compaction_fixturegen);
    run_compaction_fixturegen.addArg(compaction_fixture_name);
    const compaction_fixturegen_step = b.step(
        "compaction-fixture",
        "Write a deterministic compacted v3 fixture to stdout",
    );
    compaction_fixturegen_step.dependOn(&run_compaction_fixturegen.step);

    const litestream_compaction_fixturegen = b.addExecutable(.{
        .name = "ltx-litestream-compaction-fixturegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/litestream_compaction_fixturegen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = host_ltx },
                .{
                    .name = "litestream_captures",
                    .module = b.createModule(.{
                        .root_source_file = b.path("tests/litestream_captures.zig"),
                        .target = b.graph.host,
                        .optimize = optimize,
                    }),
                },
            },
        }),
    });
    const run_litestream_compaction_fixturegen = b.addRunArtifact(
        litestream_compaction_fixturegen,
    );
    const generated_litestream_compaction =
        run_litestream_compaction_fixturegen.captureStdOut(.{
            .basename = "0000000000000001-0000000000000004.ltx",
        });

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

    const interop_merge_fixturegen = b.addRunArtifact(compaction_fixturegen);
    interop_merge_fixturegen.addArg("merge");
    const generated_merge_fixture = interop_merge_fixturegen.captureStdOut(.{
        .basename = "ltx-zig-compacted-merge.ltx",
    });
    const interop_deletion_fixturegen = b.addRunArtifact(compaction_fixturegen);
    interop_deletion_fixturegen.addArg("deletion");
    const generated_deletion_fixture = interop_deletion_fixturegen.captureStdOut(.{
        .basename = "ltx-zig-compacted-deletion.ltx",
    });
    const interop_no_checksum_fixturegen = b.addRunArtifact(compaction_fixturegen);
    interop_no_checksum_fixturegen.addArg("no-checksum");
    const generated_no_checksum_fixture = interop_no_checksum_fixturegen.captureStdOut(.{
        .basename = "ltx-zig-compacted-no-checksum.ltx",
    });
    const go_verify_compaction = b.addSystemCommand(&.{
        "go",
        "run",
        "./verify_compaction",
    });
    go_verify_compaction.setCwd(b.path("tools/upstream_verify"));
    go_verify_compaction.setEnvironmentVariable("GOWORK", "off");
    go_verify_compaction.addFileArg(generated_merge_fixture);
    go_verify_compaction.addFileArg(generated_deletion_fixture);
    go_verify_compaction.addFileArg(generated_no_checksum_fixture);
    interop_step.dependOn(&go_verify_compaction.step);

    const fixture_root = "tests/fixtures/celld_litestream_v0511/replica/ltx/0/";
    const go_verify_real_compaction = b.addSystemCommand(&.{
        "go",
        "run",
        "./verify_real_compaction",
    });
    go_verify_real_compaction.setCwd(b.path("tools/upstream_verify"));
    go_verify_real_compaction.setEnvironmentVariable("GOWORK", "off");
    go_verify_real_compaction.addFileArg(generated_litestream_compaction);
    go_verify_real_compaction.addFileArg(b.path(
        fixture_root ++ "0000000000000001-0000000000000001.ltx",
    ));
    go_verify_real_compaction.addFileArg(b.path(
        fixture_root ++ "0000000000000002-0000000000000002.ltx",
    ));
    go_verify_real_compaction.addFileArg(b.path(
        fixture_root ++ "0000000000000003-0000000000000003.ltx",
    ));
    go_verify_real_compaction.addFileArg(b.path(
        fixture_root ++ "0000000000000004-0000000000000004.ltx",
    ));
    interop_step.dependOn(&go_verify_real_compaction.step);

    const valid_chain_fixturegen = b.addExecutable(.{
        .name = "ltx-valid-chain-fixturegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/valid_chain_fixturegen/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ltx", .module = host_ltx },
                .{ .name = "valid_chain_cases", .module = valid_chain_cases },
            },
        }),
    });
    var valid_chain_outputs: [valid_chain_manifest.all.len]std.Build.LazyPath = undefined;
    var valid_chain_inputs: [valid_chain_manifest.total_input_count]std.Build.LazyPath = undefined;
    var generated_input_count: usize = 0;
    for (valid_chain_manifest.all, 0..) |kind, index| {
        const case_name = valid_chain_manifest.name(kind);
        const generate = b.addRunArtifact(valid_chain_fixturegen);
        generate.addArg(case_name);
        valid_chain_outputs[index] = generate.captureStdOut(.{
            .basename = b.fmt("{s}.ltx", .{case_name}),
        });
        for (0..valid_chain_manifest.input_count(kind)) |input_index| {
            const generate_input = b.addRunArtifact(valid_chain_fixturegen);
            generate_input.addArg(case_name);
            generate_input.addArg(b.fmt("{d}", .{input_index}));
            valid_chain_inputs[generated_input_count] = generate_input.captureStdOut(.{
                .basename = b.fmt("{s}-input-{d}.ltx", .{ case_name, input_index + 1 }),
            });
            generated_input_count += 1;
        }
    }
    const go_verify_valid_chain = b.addSystemCommand(&.{
        "go",
        "run",
        "./verify_valid_chain",
    });
    go_verify_valid_chain.setCwd(b.path("tools/upstream_verify"));
    go_verify_valid_chain.setEnvironmentVariable("GOWORK", "off");
    var input_offset: usize = 0;
    for (valid_chain_manifest.all, 0..) |kind, index| {
        go_verify_valid_chain.addFileArg(valid_chain_outputs[index]);
        for (0..valid_chain_manifest.input_count(kind)) |_| {
            go_verify_valid_chain.addFileArg(valid_chain_inputs[input_offset]);
            input_offset += 1;
        }
    }
    go_verify_valid_chain.addFileArg(b.path("tests/fixtures/go_v3_legacy_unflagged.ltx"));
    interop_step.dependOn(&go_verify_valid_chain.step);

    const litestream_interop_module = b.createModule(.{
        .root_source_file = b.path("tools/litestream_interop/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    litestream_interop_module.linkSystemLibrary("sqlite3", .{});
    const litestream_interop = b.addExecutable(.{
        .name = "ltx-litestream-interop",
        .root_module = litestream_interop_module,
    });
    const run_litestream_interop = b.addRunArtifact(litestream_interop);
    run_litestream_interop.addArg(b.option(
        []const u8,
        "litestream",
        "Path to the exact Litestream v0.5.16 binary",
    ) orelse "litestream");
    run_litestream_interop.addFileArg(generated_litestream_compaction);
    run_litestream_interop.addFileArg(b.path(
        fixture_root ++ "0000000000000005-0000000000000005.ltx",
    ));
    run_litestream_interop.addFileArg(b.path(
        fixture_root ++ "0000000000000006-0000000000000006.ltx",
    ));
    run_litestream_interop.addFileArg(valid_chain_outputs[
        valid_chain_manifest.index(
            .checked_grow_512,
        )
    ]);
    run_litestream_interop.addFileArg(valid_chain_outputs[
        valid_chain_manifest.index(
            .no_checksum_max_page_shrink_65536,
        )
    ]);
    const litestream_interop_step = b.step(
        "litestream-interop",
        "Restore Zig-compacted real captures with Litestream v0.5.16",
    );
    litestream_interop_step.dependOn(&run_litestream_interop.step);

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
