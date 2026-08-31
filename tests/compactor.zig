const std = @import("std");
const ltx = @import("ltx");

const page_size_512: usize = 512;
const page_size_1024: usize = 1024;
const max_page_bytes: usize = page_size_1024;
const max_compressed_bytes: usize = 1044;
const max_pages: usize = 8;
const max_inputs: usize = 4;
const max_file_bytes: usize = 16 * 1024;
const max_output_bytes: usize = 32 * 1024;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_output_bytes,
    .max_pages = max_pages,
    .max_page_size = max_page_bytes,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 4096,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 100,
};

const compaction_limits = ltx.CompactionLimits{
    .max_inputs = max_inputs,
    .max_total_pages = 32,
};

const current_snapshot_fixture = @embedFile("fixtures/go_v3_snapshot_zero_page.ltx");
const legacy_snapshot_fixture = @embedFile("fixtures/go_v3_legacy_unflagged.ltx");
const legacy_mixed_snapshot_fixture = @embedFile("fixtures/go_v3_legacy_mixed.ltx");
const v2_mixed_snapshot_fixture = @embedFile("fixtures/go_v2_mixed_snapshot.ltx");
const v2_incremental_fixture = @embedFile("fixtures/go_v2_incremental.ltx");

const PageSpec = struct {
    page_number: u32,
    data: []const u8,
};

const EncodedFile = struct {
    bytes: [max_file_bytes]u8 = undefined,
    length_bytes: usize = 0,

    fn encode(
        self: *EncodedFile,
        header: ltx.Header,
        pages: []const PageSpec,
        post_apply_checksum: ltx.Checksum,
    ) !void {
        var sink = ltx.SliceWriter.init(&self.bytes);
        var compressed_workspace: [max_compressed_bytes]u8 = undefined;
        var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
        var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
        var encoder = try ltx.Encoder.init(
            .v3,
            codec_limits,
            sink.writer(),
            &compressed_workspace,
            &compression_workspace,
            &index_workspace,
        );
        try encoder.write_header(header);
        for (pages) |page| try encoder.write_page(page.page_number, page.data);
        _ = try encoder.finish(post_apply_checksum);
        self.length_bytes = sink.written().len;
    }

    fn slice(self: *const EncodedFile) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [max_page_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,

    fn input(self: *InputWorkspace, bytes: []const u8) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(bytes);
        return ltx.CompactionInput.init(
            .v3,
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }

    fn input_versioned(
        self: *InputWorkspace,
        version: ltx.FormatVersion,
        bytes: []const u8,
    ) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(bytes);
        return ltx.CompactionInput.init(
            version,
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }
};

const CompactResult = struct {
    bytes: [max_output_bytes]u8 = undefined,
    length_bytes: usize = 0,
    verified: ltx.VerifiedLTX = undefined,

    fn slice(self: *const CompactResult) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

const FailedCompaction = struct {
    bytes: [max_output_bytes]u8 = undefined,
    length_bytes: usize = 0,
    failure: ltx.Error,
};

const DecodedFile = struct {
    verified: ltx.VerifiedLTX = undefined,
    page_count: usize = 0,
    page_numbers: [max_pages]u32 = @splat(0),
    page_flags: [max_pages]u16 = @splat(0),
    page_data: [max_pages][max_page_bytes]u8 = @splat(@splat(0)),
};

test "single current file compacts to the canonical bytes" {
    const files = [_][]const u8{current_snapshot_fixture};
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);

    try std.testing.expectEqualSlices(u8, current_snapshot_fixture, result.slice());
    try std.testing.expectEqual(@as(u32, 1), result.verified.page_count);
    try std.testing.expectEqual(@as(u64, 1), result.verified.header.max_txid.value);
}

test "v2-only and mixed-version inputs migrate to identical canonical v3 bytes" {
    const page_zero: [page_size_512]u8 = @splat(0);
    const page_random = xorshift_page();
    const page_31: [page_size_512]u8 = @splat(0x31);
    const page_33: [page_size_512]u8 = @splat(0x33);
    const snapshot_pages = [_]PageSpec{
        .{ .page_number = 1, .data = &page_zero },
        .{ .page_number = 2, .data = &page_random },
    };
    const final_pages = [_]PageSpec{
        .{ .page_number = 1, .data = &page_31 },
        snapshot_pages[1],
        .{ .page_number = 3, .data = &page_33 },
    };
    const snapshot_checksum = try checksum_pages(&snapshot_pages);
    const final_checksum = try checksum_pages(&final_pages);
    const changed_pages = [_]PageSpec{ final_pages[0], final_pages[2] };

    var current_incremental: EncodedFile = .{};
    var incremental_header = make_header(512, 3, 2, 4, snapshot_checksum);
    incremental_header.timestamp_ms = -1000;
    try current_incremental.encode(incremental_header, &changed_pages, final_checksum);

    var canonical_expected: EncodedFile = .{};
    var canonical_header = make_header(512, 3, 1, 4, .init(0));
    canonical_header.timestamp_ms = -1000;
    try canonical_expected.encode(canonical_header, &final_pages, final_checksum);

    const v2_files = [_][]const u8{ v2_mixed_snapshot_fixture, v2_incremental_fixture };
    const v2_versions = [_]ltx.FormatVersion{ .v2, .v2 };
    var v2_result: CompactResult = undefined;
    try compact_versioned(&v2_files, &v2_versions, compaction_limits, &v2_result);

    const mixed_files = [_][]const u8{ v2_mixed_snapshot_fixture, current_incremental.slice() };
    const mixed_versions = [_]ltx.FormatVersion{ .v2, .v3 };
    var mixed_result: CompactResult = undefined;
    try compact_versioned(&mixed_files, &mixed_versions, compaction_limits, &mixed_result);

    try std.testing.expectEqualSlices(u8, canonical_expected.slice(), v2_result.slice());
    try std.testing.expectEqualSlices(u8, canonical_expected.slice(), mixed_result.slice());
    try std.testing.expectEqual(ltx.FormatVersion.v3, v2_result.verified.format_version);
    try std.testing.expectEqual(ltx.FormatVersion.v3, mixed_result.verified.format_version);
}

test "snapshot and incrementals merge newest pages and grow" {
    const page_11 = filled_page(page_size_512, 0x11);
    const page_22 = filled_page(page_size_512, 0x22);
    const page_31 = filled_page(page_size_512, 0x31);
    const page_33 = filled_page(page_size_512, 0x33);
    const page_42 = filled_page(page_size_512, 0x42);
    const page_44 = filled_page(page_size_512, 0x44);
    const snapshot_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_11[0..page_size_512] },
        .{ .page_number = 2, .data = page_22[0..page_size_512] },
    };
    const second_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_31[0..page_size_512] },
        .{ .page_number = 3, .data = page_33[0..page_size_512] },
    };
    const third_pages = [_]PageSpec{
        .{ .page_number = 2, .data = page_42[0..page_size_512] },
        .{ .page_number = 4, .data = page_44[0..page_size_512] },
    };
    const snapshot_checksum = try checksum_pages(&snapshot_pages);
    const second_database = [_]PageSpec{
        second_pages[0],
        snapshot_pages[1],
        second_pages[1],
    };
    const second_checksum = try checksum_pages(&second_database);
    const final_database = [_]PageSpec{
        second_pages[0],
        third_pages[0],
        second_pages[1],
        third_pages[1],
    };
    const final_checksum = try checksum_pages(&final_database);

    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    var third: EncodedFile = .{};
    try first.encode(
        make_header(512, 2, 1, 1, .init(0)),
        &snapshot_pages,
        snapshot_checksum,
    );
    try second.encode(
        make_header(512, 3, 2, 2, snapshot_checksum),
        &second_pages,
        second_checksum,
    );
    try third.encode(
        make_header(512, 4, 3, 4, second_checksum),
        &third_pages,
        final_checksum,
    );

    const files = [_][]const u8{ first.slice(), second.slice(), third.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expectEqual(@as(u64, 1), decoded.verified.header.min_txid.value);
    try std.testing.expectEqual(@as(u64, 4), decoded.verified.header.max_txid.value);
    try std.testing.expectEqual(@as(u32, 4), decoded.verified.header.commit);
    try std.testing.expectEqual(final_checksum.value, decoded.verified.trailer.post_apply_checksum.value);
    try expect_page_fill(&decoded, 0, 1, 0x31);
    try expect_page_fill(&decoded, 1, 2, 0x42);
    try expect_page_fill(&decoded, 2, 3, 0x33);
    try expect_page_fill(&decoded, 3, 4, 0x44);
}

test "incremental-only compaction preserves a sparse newest-wins transition" {
    const page_11 = filled_page(page_size_512, 0x11);
    const page_15 = filled_page(page_size_512, 0x15);
    const page_22 = filled_page(page_size_512, 0x22);
    const page_25 = filled_page(page_size_512, 0x25);
    const first_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_11[0..page_size_512] },
        .{ .page_number = 5, .data = page_15[0..page_size_512] },
    };
    const second_pages = [_]PageSpec{
        .{ .page_number = 2, .data = page_22[0..page_size_512] },
        .{ .page_number = 5, .data = page_25[0..page_size_512] },
    };
    const pre = ltx.Checksum.init(ltx.checksum_flag | 0x100);
    const middle = ltx.Checksum.init(ltx.checksum_flag | 0x200);
    const post = ltx.Checksum.init(ltx.checksum_flag | 0x300);
    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    try first.encode(make_header(512, 5, 2, 3, pre), &first_pages, middle);
    try second.encode(make_header(512, 5, 4, 6, middle), &second_pages, post);

    const files = [_][]const u8{ first.slice(), second.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expect(!decoded.verified.header.is_snapshot());
    try std.testing.expectEqual(pre.value, decoded.verified.header.pre_apply_checksum.value);
    try std.testing.expectEqual(post.value, decoded.verified.trailer.post_apply_checksum.value);
    try expect_page_fill(&decoded, 0, 1, 0x11);
    try expect_page_fill(&decoded, 1, 2, 0x22);
    try expect_page_fill(&decoded, 2, 5, 0x25);
}

test "final commit shrinks a compacted snapshot and drops high pages" {
    const page_11 = filled_page(page_size_512, 0x11);
    const page_22 = filled_page(page_size_512, 0x22);
    const page_33 = filled_page(page_size_512, 0x33);
    const page_44 = filled_page(page_size_512, 0x44);
    const page_a1 = filled_page(page_size_512, 0xa1);
    const snapshot_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_11[0..page_size_512] },
        .{ .page_number = 2, .data = page_22[0..page_size_512] },
        .{ .page_number = 3, .data = page_33[0..page_size_512] },
        .{ .page_number = 4, .data = page_44[0..page_size_512] },
    };
    const incremental_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_a1[0..page_size_512] },
    };
    const final_pages = [_]PageSpec{ incremental_pages[0], snapshot_pages[1] };
    const pre = try checksum_pages(&snapshot_pages);
    const post = try checksum_pages(&final_pages);
    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    try first.encode(make_header(512, 4, 1, 1, .init(0)), &snapshot_pages, pre);
    try second.encode(make_header(512, 2, 2, 2, pre), &incremental_pages, post);

    const files = [_][]const u8{ first.slice(), second.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expectEqual(@as(u32, 2), decoded.verified.header.commit);
    try std.testing.expectEqual(@as(usize, 2), decoded.page_count);
    try expect_page_fill(&decoded, 0, 1, 0xa1);
    try expect_page_fill(&decoded, 1, 2, 0x22);
}

test "checksummed incremental deletion compacts to commit zero" {
    const page = filled_page(page_size_512, 0x51);
    const snapshot_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page[0..page_size_512] },
    };
    const empty_pages = [_]PageSpec{};
    const pre = try checksum_pages(&snapshot_pages);
    const empty_checksum = ltx.rolling_checksum_initial();
    var first: EncodedFile = .{};
    var deletion: EncodedFile = .{};
    try first.encode(make_header(512, 1, 1, 1, .init(0)), &snapshot_pages, pre);
    try deletion.encode(make_header(512, 0, 2, 2, pre), &empty_pages, empty_checksum);

    const files = [_][]const u8{ first.slice(), deletion.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expect(decoded.verified.header.is_snapshot());
    try std.testing.expectEqual(@as(u32, 0), decoded.verified.header.commit);
    try std.testing.expectEqual(@as(usize, 0), decoded.page_count);
    try std.testing.expectEqual(empty_checksum.value, decoded.verified.trailer.post_apply_checksum.value);
}

test "compaction clears source-specific WAL and node metadata" {
    const page_11 = filled_page(page_size_512, 0x11);
    const page_22 = filled_page(page_size_512, 0x22);
    const first_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_11[0..page_size_512] },
    };
    const second_pages = [_]PageSpec{
        .{ .page_number = 2, .data = page_22[0..page_size_512] },
    };
    const pre = ltx.Checksum.init(ltx.checksum_flag | 9);
    const middle = ltx.Checksum.init(ltx.checksum_flag | 11);
    const post = ltx.Checksum.init(ltx.checksum_flag | 13);
    var first_header = make_header(512, 2, 10, 11, pre);
    first_header.timestamp_ms = 1111;
    first_header.wal_offset = 32;
    first_header.wal_size = 4096;
    first_header.wal_salt_1 = 0x1122_3344;
    first_header.wal_salt_2 = 0x5566_7788;
    first_header.node_id = 0x0102_0304_0506_0708;
    var second_header = make_header(512, 2, 12, 13, middle);
    second_header.timestamp_ms = 2222;
    second_header.wal_offset = 64;
    second_header.wal_size = 8192;
    second_header.wal_salt_1 = 0x99aa_bbcc;
    second_header.wal_salt_2 = 0xddee_ff00;
    second_header.node_id = 0x8877_6655_4433_2211;
    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    try first.encode(first_header, &first_pages, middle);
    try second.encode(second_header, &second_pages, post);

    const files = [_][]const u8{ first.slice(), second.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const header = (try decode_file(result.slice())).verified.header;

    try std.testing.expectEqual(@as(u64, 10), header.min_txid.value);
    try std.testing.expectEqual(@as(u64, 13), header.max_txid.value);
    try std.testing.expectEqual(@as(i64, 2222), header.timestamp_ms);
    try std.testing.expectEqual(pre.value, header.pre_apply_checksum.value);
    try std.testing.expectEqual(@as(i64, 0), header.wal_offset);
    try std.testing.expectEqual(@as(i64, 0), header.wal_size);
    try std.testing.expectEqual(@as(u32, 0), header.wal_salt_1);
    try std.testing.expectEqual(@as(u32, 0), header.wal_salt_2);
    try std.testing.expectEqual(@as(u64, 0), header.node_id);
}

test "consistent no-checksum inputs compact without inventing checksums" {
    const page_11 = filled_page(page_size_512, 0x11);
    const page_22 = filled_page(page_size_512, 0x22);
    const page_a2 = filled_page(page_size_512, 0xa2);
    const snapshot_pages = [_]PageSpec{
        .{ .page_number = 1, .data = page_11[0..page_size_512] },
        .{ .page_number = 2, .data = page_22[0..page_size_512] },
    };
    const incremental_pages = [_]PageSpec{
        .{ .page_number = 2, .data = page_a2[0..page_size_512] },
    };
    var snapshot_header = make_header(512, 2, 1, 1, .init(0));
    snapshot_header.flags = ltx.header_flag_no_checksum;
    var incremental_header = make_header(512, 2, 2, 3, .init(0));
    incremental_header.flags = ltx.header_flag_no_checksum;
    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    try first.encode(snapshot_header, &snapshot_pages, .init(0));
    try second.encode(incremental_header, &incremental_pages, .init(0));

    const files = [_][]const u8{ first.slice(), second.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expect(decoded.verified.header.no_checksum());
    try std.testing.expectEqual(@as(u64, 0), decoded.verified.header.pre_apply_checksum.value);
    try std.testing.expectEqual(@as(u64, 0), decoded.verified.trailer.post_apply_checksum.value);
    try expect_page_fill(&decoded, 0, 1, 0x11);
    try expect_page_fill(&decoded, 1, 2, 0xa2);
}

test "compaction rejects a TXID gap and poisons the session" {
    const pair = try make_failure_pair(.txid_gap);
    const files = [_][]const u8{ pair.first.slice(), pair.second.slice() };
    var failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&files, compaction_limits, &failed);
    try std.testing.expectEqual(error.NonContiguousTransition, failed.failure);
}

test "compaction rejects checksum-divergent history" {
    const pair = try make_failure_pair(.checksum_divergence);
    const files = [_][]const u8{ pair.first.slice(), pair.second.slice() };
    var failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&files, compaction_limits, &failed);
    try std.testing.expectEqual(error.DivergentHistory, failed.failure);
    try std.testing.expect(failed.length_bytes > ltx.header_size);
    try expect_not_verified(failed.bytes[0..failed.length_bytes]);
}

test "compaction rejects page-size and checksum-mode changes" {
    const page_pair = try make_failure_pair(.page_size);
    const page_files = [_][]const u8{ page_pair.first.slice(), page_pair.second.slice() };
    var page_failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&page_files, compaction_limits, &page_failed);
    try std.testing.expectEqual(error.CompactionPageSizeMismatch, page_failed.failure);

    const mode_pair = try make_failure_pair(.checksum_mode);
    const mode_files = [_][]const u8{ mode_pair.first.slice(), mode_pair.second.slice() };
    var mode_failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&mode_files, compaction_limits, &mode_failed);
    try std.testing.expectEqual(error.CompactionChecksumModeMismatch, mode_failed.failure);
}

test "late input corruption leaves only poisoned partial output" {
    var pair = try make_failure_pair(.valid);
    pair.second.bytes[pair.second.length_bytes - 1] ^= 1;
    const files = [_][]const u8{ pair.first.slice(), pair.second.slice() };
    var failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&files, compaction_limits, &failed);

    try std.testing.expectEqual(error.ChecksumMismatch, failed.failure);
    try std.testing.expect(failed.length_bytes > ltx.header_size);
    try expect_not_verified(failed.bytes[0..failed.length_bytes]);
}

test "compaction limits reject zero, excess inputs, and aggregate pages" {
    const files = [_][]const u8{current_snapshot_fixture};
    try expect_init_error_version(
        error.UnsupportedFormatVersion,
        .v2,
        &files,
        compaction_limits,
    );
    try expect_init_error(
        error.InvalidLimits,
        &files,
        .{ .max_inputs = 0, .max_total_pages = 1 },
    );
    try expect_init_error(
        error.InvalidLimits,
        &files,
        .{ .max_inputs = 1, .max_total_pages = 0 },
    );
    const no_files = [_][]const u8{};
    try expect_init_error(
        error.CompactionInputRequired,
        &no_files,
        .{ .max_inputs = 1, .max_total_pages = 1 },
    );
    const too_many = [_][]const u8{ current_snapshot_fixture, current_snapshot_fixture };
    try expect_init_error(
        error.CompactionInputLimitExceeded,
        &too_many,
        .{ .max_inputs = 1, .max_total_pages = 2 },
    );

    const pair = try make_failure_pair(.valid);
    const page_files = [_][]const u8{ pair.first.slice(), pair.second.slice() };
    var exact: CompactResult = undefined;
    try compact_files(
        &page_files,
        .{ .max_inputs = 2, .max_total_pages = 2 },
        &exact,
    );
    _ = try decode_file(exact.slice());

    var failed: FailedCompaction = undefined;
    try compact_files_expect_failure(
        &page_files,
        .{ .max_inputs = 2, .max_total_pages = 1 },
        &failed,
    );
    try std.testing.expectEqual(error.CompactionPageLimitExceeded, failed.failure);
}

test "v2 aggregate page limit uses the four-byte page header" {
    const files = [_][]const u8{v2_mixed_snapshot_fixture};
    const versions = [_]ltx.FormatVersion{.v2};
    var exact: CompactResult = undefined;
    try compact_versioned(
        &files,
        &versions,
        .{ .max_inputs = 1, .max_total_pages = 2 },
        &exact,
    );
    _ = try decode_file(exact.slice());

    const second_header_offset = try page_end_offset(.v2, v2_mixed_snapshot_fixture);
    var input_workspace: InputWorkspace = undefined;
    var inputs = [_]ltx.CompactionInput{
        input_workspace.input_versioned(.v2, v2_mixed_snapshot_fixture),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        .{ .max_inputs = 1, .max_total_pages = 1 },
        &inputs,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    try std.testing.expectError(error.CompactionPageLimitExceeded, compactor.compact());
    try std.testing.expectEqual(ltx.CompactorState.failed, compactor.current_state());
    try std.testing.expectError(error.InvalidState, compactor.compact());
    try std.testing.expectEqual(
        second_header_offset + ltx.v2_page_header_size,
        input_workspace.source.offset,
    );
}

test "compactor rejects an unknown per-input format version" {
    const unknown: ltx.FormatVersion = @enumFromInt(4);
    var input_workspace: InputWorkspace = undefined;
    var inputs = [_]ltx.CompactionInput{
        input_workspace.input_versioned(unknown, current_snapshot_fixture),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(error.UnsupportedFormatVersion, ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    ));
}

test "aggregate page limit rejects before reading an extra page payload" {
    const pair = try make_failure_pair(.valid);
    var input_workspaces: [2]InputWorkspace = undefined;
    var inputs = [_]ltx.CompactionInput{
        input_workspaces[0].input(pair.first.slice()),
        input_workspaces[1].input(pair.second.slice()),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        .{ .max_inputs = 2, .max_total_pages = 1 },
        &inputs,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );

    try std.testing.expectError(error.CompactionPageLimitExceeded, compactor.compact());
    try std.testing.expectEqual(ltx.CompactorState.failed, compactor.current_state());
    try std.testing.expectEqual(
        @as(usize, ltx.header_size + ltx.page_header_size),
        input_workspaces[1].source.offset,
    );
}

test "combined output transaction span remains bounded" {
    const first_page = filled_page(page_size_512, 0x11);
    const second_page = filled_page(page_size_512, 0x22);
    const first_pages = [_]PageSpec{
        .{ .page_number = 1, .data = first_page[0..page_size_512] },
    };
    const second_pages = [_]PageSpec{
        .{ .page_number = 1, .data = second_page[0..page_size_512] },
    };
    const first_post = try checksum_pages(&first_pages);
    const second_post = try checksum_pages(&second_pages);
    var first: EncodedFile = .{};
    var second: EncodedFile = .{};
    try first.encode(
        make_header(512, 1, 1, 60, .init(0)),
        &first_pages,
        first_post,
    );
    try second.encode(
        make_header(512, 1, 61, 120, first_post),
        &second_pages,
        second_post,
    );

    const files = [_][]const u8{ first.slice(), second.slice() };
    var failed: FailedCompaction = undefined;
    try compact_files_expect_failure(&files, compaction_limits, &failed);
    try std.testing.expectEqual(error.TransactionSpanLimitExceeded, failed.failure);
}

test "compactor rejects per-input workspace aliasing" {
    var source = ltx.SliceReader.init(current_snapshot_fixture);
    var shared: [max_compressed_bytes]u8 = undefined;
    var input_index: [max_pages]ltx.PageIndexEntry = undefined;
    var inputs = [_]ltx.CompactionInput{ltx.CompactionInput.init(
        .v3,
        source.reader(),
        shared[0..max_page_bytes],
        &shared,
        &input_index,
    )};
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var output_compressed: [max_compressed_bytes]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    ));
}

test "compactor rejects cross-input workspace aliasing" {
    var source_a = ltx.SliceReader.init(current_snapshot_fixture);
    var source_b = ltx.SliceReader.init(current_snapshot_fixture);
    var shared_page: [max_page_bytes]u8 = undefined;
    var compressed_a: [max_compressed_bytes]u8 = undefined;
    var compressed_b: [max_compressed_bytes]u8 = undefined;
    var index_a: [max_pages]ltx.PageIndexEntry = undefined;
    var index_b: [max_pages]ltx.PageIndexEntry = undefined;
    var inputs = [_]ltx.CompactionInput{
        ltx.CompactionInput.init(.v3, source_a.reader(), &shared_page, &compressed_a, &index_a),
        ltx.CompactionInput.init(.v3, source_b.reader(), &shared_page, &compressed_b, &index_b),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var output_compressed: [max_compressed_bytes]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    ));
}

test "compactor rejects overlapping mutable reader backings" {
    var source_a = ltx.SliceReader.init(current_snapshot_fixture);
    var source_b = ltx.SliceReader.init(current_snapshot_fixture);
    var reader_a = source_a.reader();
    reader_a.backing_is_mutable = true;
    var page_a: [max_page_bytes]u8 = undefined;
    var page_b: [max_page_bytes]u8 = undefined;
    var compressed_a: [max_compressed_bytes]u8 = undefined;
    var compressed_b: [max_compressed_bytes]u8 = undefined;
    var index_a: [max_pages]ltx.PageIndexEntry = undefined;
    var index_b: [max_pages]ltx.PageIndexEntry = undefined;
    var inputs = [_]ltx.CompactionInput{
        ltx.CompactionInput.init(.v3, reader_a, &page_a, &compressed_a, &index_a),
        ltx.CompactionInput.init(.v3, source_b.reader(), &page_b, &compressed_b, &index_b),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var output_compressed: [max_compressed_bytes]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    ));
}

test "compactor permits overlapping immutable reader backings" {
    var source_a = ltx.SliceReader.init(current_snapshot_fixture);
    var source_b = ltx.SliceReader.init(current_snapshot_fixture);
    var page_a: [max_page_bytes]u8 = undefined;
    var page_b: [max_page_bytes]u8 = undefined;
    var compressed_a: [max_compressed_bytes]u8 = undefined;
    var compressed_b: [max_compressed_bytes]u8 = undefined;
    var index_a: [max_pages]ltx.PageIndexEntry = undefined;
    var index_b: [max_pages]ltx.PageIndexEntry = undefined;
    var inputs = [_]ltx.CompactionInput{
        ltx.CompactionInput.init(.v3, source_a.reader(), &page_a, &compressed_a, &index_a),
        ltx.CompactionInput.init(.v3, source_b.reader(), &page_b, &compressed_b, &index_b),
    };
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var output_compressed: [max_compressed_bytes]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    );
    try std.testing.expectEqual(ltx.CompactorState.initialized, compactor.current_state());
}

test "compactor rejects input workspace aliasing output storage" {
    var workspace: InputWorkspace = undefined;
    var inputs = [_]ltx.CompactionInput{workspace.input(current_snapshot_fixture)};
    var sink = ltx.SliceWriter.init(&workspace.page);
    var output_compressed: [max_compressed_bytes]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    ));
}

test "legacy and current page frames compact into current canonical frames" {
    const page = filled_page(page_size_512, 0x7a);
    const pages = [_]PageSpec{
        .{ .page_number = 1, .data = page[0..page_size_512] },
    };
    const legacy_post = ltx.Checksum.init(0xefb1_f44f_ecd9_9000);
    const current_post = try checksum_pages(&pages);
    var current: EncodedFile = .{};
    try current.encode(make_header(512, 1, 2, 2, legacy_post), &pages, current_post);

    const files = [_][]const u8{ legacy_snapshot_fixture, current.slice() };
    var result: CompactResult = undefined;
    try compact_files(&files, compaction_limits, &result);
    const decoded = try decode_file(result.slice());

    try std.testing.expectEqual(@as(u64, 2), decoded.verified.header.max_txid.value);
    try expect_page_fill(&decoded, 0, 1, 0x7a);
    try std.testing.expectEqual(ltx.page_header_flag_size, decoded.page_flags[0]);
}

const compactor_fuzz_seed_current = compactor_single_seed(false, current_snapshot_fixture);
const compactor_fuzz_seed_v2 = compactor_single_seed(true, v2_mixed_snapshot_fixture);
const compactor_fuzz_seed_v2_chain = compactor_pair_seed(
    true,
    v2_mixed_snapshot_fixture,
    true,
    v2_incremental_fixture,
);
const compactor_fuzz_seed_mixed = compactor_pair_seed(
    false,
    legacy_mixed_snapshot_fixture,
    true,
    v2_incremental_fixture,
);
const compactor_fuzz_seed_malformed = compactor_single_seed(false, "not an ltx stream");
const compactor_fuzz_corpus = [_][]const u8{
    &compactor_fuzz_seed_current,
    &compactor_fuzz_seed_v2,
    &compactor_fuzz_seed_v2_chain,
    &compactor_fuzz_seed_mixed,
    &compactor_fuzz_seed_malformed,
};

test "bounded v2 and v3 compactor fuzz inputs terminate in one terminal state" {
    try std.testing.fuzz({}, fuzz_compactor, .{ .corpus = &compactor_fuzz_corpus });
}

fn fuzz_compactor(_: void, smith: *std.testing.Smith) !void {
    const input_count: usize = smith.valueRangeAtMost(u8, 1, 2);
    var input_storage: [2][1024]u8 = undefined;
    var files: [2][]const u8 = undefined;
    var versions: [2]ltx.FormatVersion = undefined;
    for (0..input_count) |index| {
        versions[index] = if (smith.value(bool)) .v2 else .v3;
        const input_length: usize = smith.slice(&input_storage[index]);
        files[index] = input_storage[index][0..input_length];
    }
    try expect_fuzz_terminal(files[0..input_count], versions[0..input_count]);
}

fn expect_fuzz_terminal(
    files: []const []const u8,
    versions: []const ltx.FormatVersion,
) !void {
    if (files.len != versions.len or files.len > max_inputs) return error.InvalidTestInput;
    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, versions, 0..) |bytes, version, index| {
        inputs[index] = input_workspaces[index].input_versioned(version, bytes);
    }
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        inputs[0..files.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    const verified = compactor.compact() catch {
        try std.testing.expectEqual(ltx.CompactorState.failed, compactor.current_state());
        try std.testing.expectError(error.InvalidState, compactor.compact());
        try std.testing.expect(sink.written().len <= max_output_bytes);
        if (sink.written().len != 0) try expect_not_verified(sink.written());
        return;
    };
    try std.testing.expectEqual(ltx.CompactorState.finished, compactor.current_state());
    try std.testing.expectEqual(ltx.FormatVersion.v3, verified.format_version);
    try std.testing.expect(sink.written().len <= max_output_bytes);
    const decoded = try decode_file(sink.written());
    try std.testing.expectEqualDeep(verified, decoded.verified);
    try std.testing.expectError(error.InvalidState, compactor.compact());
}

fn compact_files(
    files: []const []const u8,
    limits: ltx.CompactionLimits,
    result: *CompactResult,
) !void {
    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, 0..) |bytes, index| inputs[index] = input_workspaces[index].input(bytes);
    var sink = ltx.SliceWriter.init(&result.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        limits,
        inputs[0..files.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    result.verified = try compactor.compact();
    try std.testing.expectEqual(ltx.CompactorState.finished, compactor.current_state());
    try std.testing.expectError(error.InvalidState, compactor.compact());
    result.length_bytes = sink.written().len;
}

fn compact_versioned(
    files: []const []const u8,
    versions: []const ltx.FormatVersion,
    limits: ltx.CompactionLimits,
    result: *CompactResult,
) !void {
    if (files.len != versions.len or files.len > max_inputs) return error.InvalidTestInput;
    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, versions, 0..) |bytes, version, index| {
        inputs[index] = input_workspaces[index].input_versioned(version, bytes);
    }
    var sink = ltx.SliceWriter.init(&result.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        limits,
        inputs[0..files.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    result.verified = try compactor.compact();
    result.length_bytes = sink.written().len;
}

fn page_end_offset(version: ltx.FormatVersion, bytes: []const u8) !usize {
    var workspace: InputWorkspace = undefined;
    workspace.source = ltx.SliceReader.init(bytes);
    var decoder = try ltx.Decoder.init(
        version,
        codec_limits,
        workspace.source.reader(),
        &workspace.page,
        &workspace.compressed,
        &workspace.index,
    );
    switch (try decoder.next()) {
        .header => {},
        else => return error.ExpectedHeader,
    }
    switch (try decoder.next()) {
        .unverified_page => {},
        else => return error.ExpectedPage,
    }
    return workspace.source.offset;
}

fn compact_files_expect_failure(
    files: []const []const u8,
    limits: ltx.CompactionLimits,
    result: *FailedCompaction,
) !void {
    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, 0..) |bytes, index| inputs[index] = input_workspaces[index].input(bytes);
    var sink = ltx.SliceWriter.init(&result.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        limits,
        inputs[0..files.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    if (compactor.compact()) |_| {
        return error.ExpectedCompactionFailure;
    } else |err| {
        result.failure = err;
    }
    if (compactor.current_state() != .failed) return error.ExpectedCompactionFailure;
    result.length_bytes = sink.written().len;
    try std.testing.expectError(error.InvalidState, compactor.compact());
}

fn expect_init_error(
    expected: ltx.Error,
    files: []const []const u8,
    limits: ltx.CompactionLimits,
) !void {
    try expect_init_error_version(expected, .v3, files, limits);
}

fn expect_init_error_version(
    expected: ltx.Error,
    output_version: ltx.FormatVersion,
    files: []const []const u8,
    limits: ltx.CompactionLimits,
) !void {
    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, 0..) |bytes, index| inputs[index] = input_workspaces[index].input(bytes);
    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(expected, ltx.Compactor.init(
        output_version,
        codec_limits,
        limits,
        inputs[0..files.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    ));
}

fn decode_file(bytes: []const u8) !DecodedFile {
    var source = ltx.SliceReader.init(bytes);
    var page: [max_page_bytes]u8 = undefined;
    var compressed: [max_compressed_bytes]u8 = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        codec_limits,
        source.reader(),
        &page,
        &compressed,
        &index,
    );
    var decoded = DecodedFile{};
    for (0..decoder.event_budget()) |_| {
        switch (try decoder.next()) {
            .header, .page_block_complete => {},
            .unverified_page => |event| {
                if (decoded.page_count >= max_pages) return error.TestPageLimitExceeded;
                const page_index = decoded.page_count;
                decoded.page_numbers[page_index] = event.header.page_number;
                decoded.page_flags[page_index] = event.header.flags;
                @memcpy(decoded.page_data[page_index][0..event.data.len], event.data);
                decoded.page_count += 1;
            },
            .verified => |verified| {
                decoded.verified = verified;
                return decoded;
            },
        }
    }
    return error.DecoderDidNotTerminate;
}

fn expect_not_verified(bytes: []const u8) !void {
    _ = decode_file(bytes) catch return;
    return error.PartialCompactionWasVerified;
}

fn expect_page_fill(
    decoded: *const DecodedFile,
    index: usize,
    page_number: u32,
    fill: u8,
) !void {
    if (index >= decoded.page_count) return error.MissingExpectedPage;
    try std.testing.expectEqual(page_number, decoded.page_numbers[index]);
    const page_size: usize = @intCast(decoded.verified.header.page_size);
    try std.testing.expect(std.mem.allEqual(u8, decoded.page_data[index][0..page_size], fill));
}

fn filled_page(length: usize, fill: u8) [max_page_bytes]u8 {
    std.debug.assert(length <= max_page_bytes);
    var page: [max_page_bytes]u8 = @splat(0);
    @memset(page[0..length], fill);
    return page;
}

fn xorshift_page() [page_size_512]u8 {
    var page: [page_size_512]u8 = undefined;
    var state: u32 = 0x9e37_79b9;
    for (&page) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    return page;
}

fn checksum_pages(pages: []const PageSpec) !ltx.Checksum {
    var checksum = ltx.rolling_checksum_initial();
    for (pages) |page| {
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(page.page_number, page.data),
        );
    }
    return checksum;
}

fn make_header(
    page_size: u32,
    commit: u32,
    min_txid: u64,
    max_txid: u64,
    pre_apply_checksum: ltx.Checksum,
) ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size,
        .commit = commit,
        .min_txid = .init(min_txid),
        .max_txid = .init(max_txid),
        .timestamp_ms = 0,
        .pre_apply_checksum = pre_apply_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

const FailurePairKind = enum {
    valid,
    txid_gap,
    checksum_divergence,
    page_size,
    checksum_mode,
};

const FailurePair = struct {
    first: EncodedFile,
    second: EncodedFile,
};

fn make_failure_pair(kind: FailurePairKind) !FailurePair {
    const first_page = filled_page(page_size_512, 0x11);
    const second_page = filled_page(page_size_1024, 0x22);
    const first_pages = [_]PageSpec{
        .{ .page_number = 1, .data = first_page[0..page_size_512] },
    };
    const first_post = try checksum_pages(&first_pages);
    const second_page_size: usize = if (kind == .page_size) page_size_1024 else page_size_512;
    const second_pages = [_]PageSpec{
        .{ .page_number = 1, .data = second_page[0..second_page_size] },
    };
    const second_post = try checksum_pages(&second_pages);
    const min_txid: u64 = if (kind == .txid_gap) 3 else 2;
    const pre = if (kind == .checksum_divergence)
        ltx.Checksum.init(first_post.value ^ 1)
    else
        first_post;
    var second_header = make_header(
        @intCast(second_page_size),
        1,
        min_txid,
        min_txid,
        pre,
    );
    var post = second_post;
    if (kind == .checksum_mode) {
        second_header.flags = ltx.header_flag_no_checksum;
        second_header.pre_apply_checksum = .init(0);
        post = .init(0);
    }
    var pair = FailurePair{ .first = .{}, .second = .{} };
    try pair.first.encode(
        make_header(512, 1, 1, 1, .init(0)),
        &first_pages,
        first_post,
    );
    try pair.second.encode(second_header, &second_pages, post);
    return pair;
}

fn compactor_single_seed(
    comptime use_v2: bool,
    comptime bytes: []const u8,
) [20 + bytes.len]u8 {
    var result: [20 + bytes.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], 1, .little);
    std.mem.writeInt(u64, result[8..16], @intFromBool(use_v2), .little);
    std.mem.writeInt(u32, result[16..20], bytes.len, .little);
    @memcpy(result[20..], bytes);
    return result;
}

fn compactor_pair_seed(
    comptime first_v2: bool,
    comptime first: []const u8,
    comptime second_v2: bool,
    comptime second: []const u8,
) [32 + first.len + second.len]u8 {
    var result: [32 + first.len + second.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], 2, .little);
    std.mem.writeInt(u64, result[8..16], @intFromBool(first_v2), .little);
    std.mem.writeInt(u32, result[16..20], first.len, .little);
    @memcpy(result[20..][0..first.len], first);
    const second_offset = 20 + first.len;
    std.mem.writeInt(
        u64,
        result[second_offset..][0..8],
        @intFromBool(second_v2),
        .little,
    );
    std.mem.writeInt(u32, result[second_offset + 8 ..][0..4], second.len, .little);
    @memcpy(result[second_offset + 12 ..], second);
    return result;
}
