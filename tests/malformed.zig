const std = @import("std");
const ltx = @import("ltx");

test "unsupported versions remain explicit" {
    const version: ltx.FormatVersion = @enumFromInt(2);
    try std.testing.expectError(error.UnsupportedFormatVersion, version.validate());
}

const limits = ltx.Limits{
    .max_input_bytes = 4096,
    .max_output_bytes = 4096,
    .max_pages = 8,
    .max_page_size = 65_536,
    .max_compressed_page_size = 66_000,
    .max_page_index_bytes = 1024,
    .max_page_index_entries = 8,
    .max_varint_bytes = 10,
    .max_transaction_span = 100,
};

test "initialization rejects undersized caller workspaces" {
    var input: [1]u8 = undefined;
    var source = ltx.SliceReader.init(&input);
    var page_workspace: [511]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        ltx.Decoder.init(
            .v3,
            limits,
            source.reader(),
            &page_workspace,
            &compressed_workspace,
            &index_workspace,
        ),
    );
}

test "decoder rejects overlapping page and index workspaces" {
    var input: [1]u8 = undefined;
    var source = ltx.SliceReader.init(&input);
    var shared: [2731]ltx.PageIndexEntry = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    const shared_bytes = std.mem.sliceAsBytes(shared[0..]);
    try std.testing.expect(shared_bytes.len >= 65_536);
    try std.testing.expectError(
        error.WorkspaceAliasing,
        ltx.Decoder.init(
            .v3,
            limits,
            source.reader(),
            shared_bytes[0..65_536],
            &compressed_workspace,
            shared[0..8],
        ),
    );
}

test "encoder rejects a page that aliases index workspace" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var shared: [22]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        shared[0..8],
    );
    try encoder.write_header(valid_header());
    const page = std.mem.sliceAsBytes(shared[0..])[0..512];
    try std.testing.expectError(error.WorkspaceAliasing, encoder.write_page(1, page));
}

test "header validation covers page, TXID, checksum, and WAL invariants" {
    var header = valid_header();
    try header.validate(limits);
    header.page_size = 1000;
    try std.testing.expectError(error.InvalidPageSize, header.validate(limits));

    header = valid_header();
    header.min_txid = .init(0);
    try std.testing.expectError(error.InvalidTXIDRange, header.validate(limits));
    header = valid_header();
    header.max_txid = .init(0);
    try std.testing.expectError(error.InvalidTXIDRange, header.validate(limits));

    header = valid_header();
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    header.pre_apply_checksum = .init(0);
    try std.testing.expectError(error.InvalidPreApplyChecksum, header.validate(limits));

    header = valid_header();
    header.wal_salt_1 = 1;
    try std.testing.expectError(error.InvalidWALMetadata, header.validate(limits));
    header = valid_header();
    header.flags = 1;
    try std.testing.expectError(error.InvalidHeaderFlags, header.validate(limits));
}

test "checksummed deletion trailer requires the empty database checksum" {
    var header = valid_header();
    header.commit = 0;
    const invalid = ltx.Trailer{
        .post_apply_checksum = .init(ltx.checksum_flag | 1),
        .file_checksum = .init(ltx.checksum_flag),
    };
    try std.testing.expectError(error.InvalidTrailer, invalid.validate(header));
    const valid = ltx.Trailer{
        .post_apply_checksum = .init(ltx.checksum_flag),
        .file_checksum = .init(ltx.checksum_flag),
    };
    try valid.validate(header);
}

test "every truncation of a known-good Go file is rejected without panic" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var prefix_length: usize = 0;
    while (prefix_length < fixture.len) : (prefix_length += 1) {
        try expect_decode_failure(fixture[0..prefix_length]);
    }
}

test "bad magic poisons the decoder" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[0] = 'X';
    var harness: DecoderHarness = undefined;
    try harness.init(&fixture);
    try std.testing.expectError(error.InvalidMagic, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
    try std.testing.expectError(error.InvalidState, harness.decoder.next());
}

test "zero compressed size is structurally invalid" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    @memset(fixture[106..110], 0);
    var harness: DecoderHarness = undefined;
    try harness.init(&fixture);
    _ = try harness.decoder.next();
    try std.testing.expectError(error.InvalidCompressedSize, harness.decoder.next());
}

test "decoder rejects unknown page flags and a flagged zero page number" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);

    var unknown_flags = fixture;
    unknown_flags[105] |= 0x02;
    var flags_harness: DecoderHarness = undefined;
    try flags_harness.init(&unknown_flags);
    _ = try flags_harness.decoder.next();
    try std.testing.expectError(error.InvalidPageFlags, flags_harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, flags_harness.decoder.current_state());

    var flagged_zero = fixture;
    @memset(flagged_zero[100..104], 0);
    var zero_harness: DecoderHarness = undefined;
    try zero_harness.init(&flagged_zero);
    _ = try zero_harness.decoder.next();
    try std.testing.expectError(error.InvalidPageNumber, zero_harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, zero_harness.decoder.current_state());
}

test "decoder refuses an incomplete snapshot page block" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[15] = 2;
    var harness: DecoderHarness = undefined;
    try harness.init(&fixture);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.SnapshotPageSequence, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
}

test "decoder rejects out-of-order incremental pages" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var encoder_compressed: [66_000]u8 = undefined;
    var encoder_index: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &encoder_compressed,
        &encoder_index,
    );
    var header = valid_header();
    header.commit = 2;
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    header.pre_apply_checksum = .init(ltx.checksum_flag);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    try encoder.write_page(2, &page);
    _ = try encoder.finish(.init(ltx.checksum_flag));

    const second_frame_offset: usize = @intCast(encoder_index[1].frame_offset_bytes);
    output[second_frame_offset + 3] = 1;
    var harness: DecoderHarness = undefined;
    try harness.init(sink.written());
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.PageOutOfOrder, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
}

test "page index must match observed frame metadata" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[141] += 1;
    var harness: DecoderHarness = undefined;
    try harness.init(&fixture);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.PageIndexMismatch, harness.decoder.next());
}

test "page index validates every tuple field" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);

    var wrong_page_number = fixture;
    wrong_page_number[140] = 2;
    try expect_terminal_failure(&wrong_page_number, error.PageIndexMismatch);

    var wrong_frame_size = fixture;
    wrong_frame_size[142] += 1;
    try expect_terminal_failure(&wrong_frame_size, error.PageIndexMismatch);
}

test "page index rejects premature and missing terminators" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);

    var premature_terminator = fixture;
    premature_terminator[140] = 0;
    try expect_terminal_failure(&premature_terminator, error.InvalidPageIndex);

    var missing_terminator = fixture;
    missing_terminator[143] = 1;
    try expect_terminal_failure(&missing_terminator, error.InvalidPageIndex);
}

test "page index rejects a false encoded-size declaration" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[151] += 1;
    try expect_terminal_failure(&fixture, error.InvalidPageIndexSize);
}

test "page index rejects an overflowing u64 varint" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var overflowing: [177]u8 = undefined;
    @memcpy(overflowing[0..140], fixture[0..140]);
    @memset(overflowing[140..149], 0xff);
    overflowing[149] = 0x02;
    @memcpy(overflowing[150..], fixture[141..]);
    try expect_terminal_failure(&overflowing, error.VarintOverflow);
}

test "overlong page-index varints are rejected" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var overlong: [169]u8 = undefined;
    @memcpy(overlong[0..140], fixture[0..140]);
    overlong[140] = 0x81;
    overlong[141] = 0x00;
    @memcpy(overlong[142..], fixture[141..]);
    var harness: DecoderHarness = undefined;
    try harness.init(&overlong);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.OverlongVarint, harness.decoder.next());
}

test "valid files with trailing bytes are rejected" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var trailing: [169]u8 = undefined;
    @memcpy(trailing[0..168], &fixture);
    trailing[168] = 0xff;
    var harness: DecoderHarness = undefined;
    try harness.init(&trailing);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.TrailingBytes, harness.decoder.next());
}

test "file checksum corruption is distinguished" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[167] ^= 1;
    var harness: DecoderHarness = undefined;
    try harness.init(&fixture);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(error.ChecksumMismatch, harness.decoder.next());
}

test "decoder input limit applies to the complete file" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var constrained = limits;
    constrained.max_input_bytes = fixture.len - 1;
    try expect_terminal_failure_with_limits(
        &fixture,
        constrained,
        error.InputLimitExceeded,
    );
}

test "decoder compressed-page limit applies before reading the payload" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var constrained = limits;
    constrained.max_compressed_page_size = 23;
    var harness: DecoderHarness = undefined;
    try harness.init_with_limits(&fixture, constrained);
    _ = try harness.decoder.next();
    try std.testing.expectError(error.CompressedPageLimitExceeded, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
}

test "decoder page-index byte limit includes its size suffix" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var constrained = limits;
    constrained.max_page_index_bytes = 11;
    try expect_terminal_failure_with_limits(
        &fixture,
        constrained,
        error.PageIndexLimitExceeded,
    );
}

test "decoder transaction-span limit is checked at the header" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    fixture[31] = 2;
    var constrained = limits;
    constrained.max_transaction_span = 1;
    var harness: DecoderHarness = undefined;
    try harness.init_with_limits(&fixture, constrained);
    try std.testing.expectError(error.TransactionSpanLimitExceeded, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
}

test "encoder output limit fails before exceeding the bound" {
    var constrained = limits;
    constrained.max_output_bytes = 99;
    var output: [1024]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        constrained,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try std.testing.expectError(error.OutputLimitExceeded, encoder.write_header(valid_header()));
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
    try std.testing.expectEqual(ltx.EncoderState.failed, encoder.current_state());
}

test "encoder preflights each page frame before its first write" {
    var constrained = limits;
    constrained.max_output_bytes = ltx.header_size;
    var output: [1024]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        constrained,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try encoder.write_header(valid_header());
    try std.testing.expectEqual(@as(usize, ltx.header_size), sink.written().len);
    const page: [512]u8 = @splat(0);
    try std.testing.expectError(error.OutputLimitExceeded, encoder.write_page(1, &page));
    try std.testing.expectEqual(@as(usize, ltx.header_size), sink.written().len);
}

test "encoder preflights the complete terminal section against output limit" {
    var constrained = limits;
    constrained.max_output_bytes = 659;
    var output: [1024]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        constrained,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try encoder.write_header(valid_header());
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    const before_finish = sink.written().len;
    try std.testing.expectError(
        error.OutputLimitExceeded,
        encoder.finish(try ltx.checksum_page(1, &page)),
    );
    try std.testing.expectEqual(before_finish, sink.written().len);
}

test "encoder preflights the complete terminal section against index limit" {
    var constrained = limits;
    constrained.max_page_index_bytes = 12;
    var output: [1024]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        constrained,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try encoder.write_header(valid_header());
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    const before_finish = sink.written().len;
    try std.testing.expectError(
        error.PageIndexLimitExceeded,
        encoder.finish(try ltx.checksum_page(1, &page)),
    );
    try std.testing.expectEqual(before_finish, sink.written().len);
}

test "independent index-entry limit bounds incremental encoder pages" {
    var constrained = limits;
    constrained.max_page_index_entries = 1;
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        constrained,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    var header = valid_header();
    header.commit = 2;
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    header.pre_apply_checksum = .init(ltx.checksum_flag);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    const before_second_page = sink.written().len;
    try std.testing.expectError(error.PageIndexLimitExceeded, encoder.write_page(2, &page));
    try std.testing.expectEqual(before_second_page, sink.written().len);
}

test "independent index-entry limit bounds incremental decoder pages" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var encoder_compressed: [66_000]u8 = undefined;
    var encoder_index: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &encoder_compressed,
        &encoder_index,
    );
    var header = valid_header();
    header.commit = 2;
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    header.pre_apply_checksum = .init(ltx.checksum_flag);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    try encoder.write_page(2, &page);
    _ = try encoder.finish(.init(ltx.checksum_flag));

    var constrained = limits;
    constrained.max_page_index_entries = 1;
    var source = ltx.SliceReader.init(sink.written());
    var page_workspace: [65_536]u8 = undefined;
    var decoder_compressed: [66_000]u8 = undefined;
    var decoder_index: [1]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        constrained,
        source.reader(),
        &page_workspace,
        &decoder_compressed,
        &decoder_index,
    );
    _ = try decoder.next();
    _ = try decoder.next();
    try std.testing.expectError(error.PageIndexLimitExceeded, decoder.next());
}

test "encoder rejects incremental page regression and becomes failed" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    var header = valid_header();
    header.commit = 2;
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    header.pre_apply_checksum = .init(ltx.checksum_flag);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(2, &page);
    try std.testing.expectError(error.PageOutOfOrder, encoder.write_page(1, &page));
    try std.testing.expectEqual(ltx.EncoderState.failed, encoder.current_state());
}

test "encoder refuses an incomplete snapshot at finish" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    var header = valid_header();
    header.commit = 2;
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    try std.testing.expectError(
        error.SnapshotPageSequence,
        encoder.finish(try ltx.checksum_page(1, &page)),
    );
}

test "decoder accepts one-byte transport reads" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var probe = ProbeReader{ .bytes = &fixture, .max_chunk = 1 };
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        probe.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    _ = try decoder.next();
    _ = try decoder.next();
    _ = try decoder.next();
    const event = try decoder.next();
    switch (event) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 1), verified.page_count);
            try std.testing.expectEqual(@as(u64, fixture.len), verified.byte_count);
        },
        else => return error.ExpectedVerifiedEvent,
    }
    try std.testing.expectEqual(fixture.len, probe.read_calls);
}

test "decoder propagates reader failures and becomes failed" {
    var probe = ProbeReader{ .bytes = "", .fail_read = true };
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        probe.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    try std.testing.expectError(error.InputFailure, decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, decoder.current_state());
    try std.testing.expectError(error.InvalidState, decoder.next());
}

test "decoder propagates end-of-input callback failures" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var probe = ProbeReader{ .bytes = &fixture, .fail_at_end = true };
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        probe.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    _ = try decoder.next();
    _ = try decoder.next();
    _ = try decoder.next();
    try std.testing.expectError(error.InputFailure, decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, decoder.current_state());
}

test "encoder propagates writer failures and becomes failed" {
    var probe = FailingWriter{};
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        probe.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try std.testing.expectError(error.OutputFailure, encoder.write_header(valid_header()));
    try std.testing.expectEqual(@as(usize, 1), probe.write_calls);
    try std.testing.expectEqual(ltx.EncoderState.failed, encoder.current_state());
    try std.testing.expectError(error.InvalidState, encoder.write_header(valid_header()));
}

const ProbeReader = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_chunk: usize = std.math.maxInt(usize),
    read_calls: usize = 0,
    fail_read: bool = false,
    fail_at_end: bool = false,

    fn reader(self: *ProbeReader) ltx.Reader {
        return .{
            .context = self,
            .read_fn = read,
            .at_end_fn = at_end,
        };
    }

    fn read(context: *anyopaque, destination: []u8) error{InputFailure}!usize {
        const self: *ProbeReader = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        if (self.fail_read) return error.InputFailure;
        const remaining = self.bytes.len - self.offset;
        const count = @min(destination.len, @min(self.max_chunk, remaining));
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }

    fn at_end(context: *anyopaque) error{InputFailure}!bool {
        const self: *ProbeReader = @ptrCast(@alignCast(context));
        if (self.fail_at_end) return error.InputFailure;
        return self.offset == self.bytes.len;
    }
};

const FailingWriter = struct {
    write_calls: usize = 0,

    fn writer(self: *FailingWriter) ltx.Writer {
        return .{
            .context = self,
            .write_all_fn = write_all,
        };
    }

    fn write_all(context: *anyopaque, _: []const u8) error{OutputFailure}!void {
        const self: *FailingWriter = @ptrCast(@alignCast(context));
        self.write_calls += 1;
        return error.OutputFailure;
    }
};

const DecoderHarness = struct {
    source: ltx.SliceReader,
    page_workspace: [65_536]u8,
    compressed_workspace: [66_000]u8,
    index_workspace: [8]ltx.PageIndexEntry,
    decoder: ltx.Decoder,

    fn init(self: *DecoderHarness, input: []const u8) !void {
        try self.init_with_limits(input, limits);
    }

    fn init_with_limits(
        self: *DecoderHarness,
        input: []const u8,
        selected_limits: ltx.Limits,
    ) !void {
        self.source = ltx.SliceReader.init(input);
        self.decoder = try ltx.Decoder.init(
            .v3,
            selected_limits,
            self.source.reader(),
            &self.page_workspace,
            &self.compressed_workspace,
            &self.index_workspace,
        );
    }
};

fn expect_terminal_failure(input: []const u8, comptime expected_error: anyerror) !void {
    try expect_terminal_failure_with_limits(input, limits, expected_error);
}

fn expect_terminal_failure_with_limits(
    input: []const u8,
    selected_limits: ltx.Limits,
    comptime expected_error: anyerror,
) !void {
    var harness: DecoderHarness = undefined;
    try harness.init_with_limits(input, selected_limits);
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    _ = try harness.decoder.next();
    try std.testing.expectError(expected_error, harness.decoder.next());
    try std.testing.expectEqual(ltx.DecoderState.failed, harness.decoder.current_state());
}

fn expect_decode_failure(input: []const u8) !void {
    var harness: DecoderHarness = undefined;
    try harness.init(input);
    var event_count: u8 = 0;
    while (event_count < 12) : (event_count += 1) {
        const event = harness.decoder.next() catch return;
        switch (event) {
            .verified => return error.TruncatedFileVerified,
            else => {},
        }
    }
    return error.DecoderDidNotTerminate;
}

fn valid_header() ltx.Header {
    return .{
        .flags = 0,
        .page_size = 512,
        .commit = 1,
        .min_txid = .init(1),
        .max_txid = .init(1),
        .timestamp_ms = 0,
        .pre_apply_checksum = .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn load_fixture(comptime path: []const u8, destination: []u8) !void {
    const source = @embedFile(path);
    if (source.len != destination.len) return error.InvalidBinaryFixture;
    @memcpy(destination, source);
}
