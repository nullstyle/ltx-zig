const std = @import("std");
const ltx = @import("ltx");

const max_decoder_input_bytes: usize = 1024;
const max_decoder_page_bytes: usize = 4096;
const max_decoder_compressed_bytes: usize = 4200;
const max_decoder_pages: usize = 8;
const decoder_event_budget: usize = max_decoder_pages + 3;
const decoder_limits = ltx.Limits{
    .max_input_bytes = max_decoder_input_bytes,
    .max_output_bytes = max_decoder_page_bytes * max_decoder_pages,
    .max_pages = max_decoder_pages,
    .max_page_size = max_decoder_page_bytes,
    .max_compressed_page_size = max_decoder_compressed_bytes,
    .max_page_index_bytes = max_decoder_input_bytes,
    .max_page_index_entries = max_decoder_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 100,
};

const snapshot_fixture = @embedFile("fixtures/go_v3_snapshot_zero_page.ltx");
const empty_fixture = @embedFile("fixtures/go_v3_empty_snapshot.ltx");
const incremental_fixture = @embedFile("fixtures/go_v3_incremental.ltx");
const no_checksum_fixture = @embedFile("fixtures/go_v3_no_checksum.ltx");
const celld_fixture = @embedFile("fixtures/celld_v052_two_page_snapshot.ltx");
const legacy_fixture = @embedFile("fixtures/go_v3_legacy_unflagged.ltx");
const legacy_mixed_fixture = @embedFile("fixtures/go_v3_legacy_mixed.ltx");
const v2_mixed_fixture = @embedFile("fixtures/go_v2_mixed_snapshot.ltx");
const v2_empty_fixture = @embedFile("fixtures/go_v2_empty_snapshot.ltx");
const v2_sqlite_empty_fixture = @embedFile("fixtures/go_v2_sqlite_empty.ltx");
const v2_incremental_fixture = @embedFile("fixtures/go_v2_incremental.ltx");
const v2_no_checksum_fixture = @embedFile("fixtures/go_v2_no_checksum.ltx");

const decoder_seed_snapshot = versioned_slice_seed(false, 1, snapshot_fixture);
const decoder_seed_empty = versioned_slice_seed(false, 2, empty_fixture);
const decoder_seed_incremental = versioned_slice_seed(false, 3, incremental_fixture);
const decoder_seed_no_checksum = versioned_slice_seed(false, 7, no_checksum_fixture);
const decoder_seed_celld = versioned_slice_seed(false, 13, celld_fixture);
const decoder_seed_legacy = versioned_slice_seed(false, 31, legacy_fixture);
const decoder_seed_legacy_mixed = versioned_slice_seed(false, 64, legacy_mixed_fixture);
const decoder_seed_v2_mixed = versioned_slice_seed(true, 127, v2_mixed_fixture);
const decoder_seed_v2_empty = versioned_slice_seed(true, 255, v2_empty_fixture);
const decoder_seed_v2_sqlite_empty = versioned_slice_seed(true, 383, v2_sqlite_empty_fixture);
const decoder_seed_v2_incremental = versioned_slice_seed(true, 511, v2_incremental_fixture);
const decoder_seed_v2_no_checksum = versioned_slice_seed(true, 1023, v2_no_checksum_fixture);
const decoder_corpus = [_][]const u8{
    &decoder_seed_snapshot,
    &decoder_seed_empty,
    &decoder_seed_incremental,
    &decoder_seed_no_checksum,
    &decoder_seed_celld,
    &decoder_seed_legacy,
    &decoder_seed_legacy_mixed,
    &decoder_seed_v2_mixed,
    &decoder_seed_v2_empty,
    &decoder_seed_v2_sqlite_empty,
    &decoder_seed_v2_incremental,
    &decoder_seed_v2_no_checksum,
};

const DecoderFixture = struct {
    version: ltx.FormatVersion,
    bytes: []const u8,
};

const decoder_fixtures = [_]DecoderFixture{
    .{ .version = .v3, .bytes = snapshot_fixture },
    .{ .version = .v3, .bytes = empty_fixture },
    .{ .version = .v3, .bytes = incremental_fixture },
    .{ .version = .v3, .bytes = no_checksum_fixture },
    .{ .version = .v3, .bytes = celld_fixture },
    .{ .version = .v3, .bytes = legacy_fixture },
    .{ .version = .v3, .bytes = legacy_mixed_fixture },
    .{ .version = .v2, .bytes = v2_mixed_fixture },
    .{ .version = .v2, .bytes = v2_empty_fixture },
    .{ .version = .v2, .bytes = v2_sqlite_empty_fixture },
    .{ .version = .v2, .bytes = v2_incremental_fixture },
    .{ .version = .v2, .bytes = v2_no_checksum_fixture },
};

const DecoderTerminal = enum { rejected, verified };

const DecoderOutcome = struct {
    terminal: DecoderTerminal = .rejected,
    failure: ?ltx.Error = null,
    consumed_bytes: u64 = 0,
    event_count: u8 = 0,
    header: ?ltx.Header = null,
    page_count: u8 = 0,
    page_numbers: [max_decoder_pages]u32 = @splat(0),
    page_flags: [max_decoder_pages]u16 = @splat(0),
    page_checksums: [max_decoder_pages]u64 = @splat(0),
    page_block_complete_count: u8 = 0,
    verified: ?ltx.VerifiedLTX = null,
};

const ChunkedReader = struct {
    bytes: []const u8,
    max_chunk_bytes: usize,
    offset_bytes: usize = 0,

    fn reader(self: *ChunkedReader) ltx.Reader {
        return .{
            .context = self,
            .read_fn = read,
            .at_end_fn = at_end,
            .backing_bytes = self.bytes,
        };
    }

    fn read(context: *anyopaque, destination: []u8) error{InputFailure}!usize {
        const self: *ChunkedReader = @ptrCast(@alignCast(context));
        const remaining_bytes = self.bytes.len - self.offset_bytes;
        const count = @min(destination.len, remaining_bytes, self.max_chunk_bytes);
        @memcpy(destination[0..count], self.bytes[self.offset_bytes..][0..count]);
        self.offset_bytes += count;
        return count;
    }

    fn at_end(context: *anyopaque) error{InputFailure}!bool {
        const self: *ChunkedReader = @ptrCast(@alignCast(context));
        return self.offset_bytes == self.bytes.len;
    }
};

test "whole-file v2 and v3 decoder fuzz corpus is transport invariant" {
    try std.testing.fuzz({}, fuzz_decoder, .{ .corpus = &decoder_corpus });
}

fn fuzz_decoder(_: void, smith: *std.testing.Smith) !void {
    const version: ltx.FormatVersion = if (smith.value(bool)) .v2 else .v3;
    const chunk_bytes = smith.valueRangeAtMost(u8, 1, 64);
    var input_storage: [max_decoder_input_bytes]u8 = undefined;
    const input_length: usize = smith.slice(&input_storage);
    _ = try expect_decoder_equivalent(version, input_storage[0..input_length], chunk_bytes);
}

test "small fixtures and their deterministic mutations terminate consistently" {
    const chunk_sizes = [_]usize{ 1, 2, 3, 7, 64 };
    var mutated: [max_decoder_input_bytes]u8 = undefined;
    for (decoder_fixtures) |fixture| {
        const baseline = try decode_outcome(
            fixture.version,
            fixture.bytes,
            max_decoder_input_bytes,
        );
        try std.testing.expectEqual(DecoderTerminal.verified, baseline.terminal);
        for (chunk_sizes) |chunk_bytes| {
            const fragmented = try decode_outcome(fixture.version, fixture.bytes, chunk_bytes);
            try std.testing.expectEqualDeep(baseline, fragmented);
        }
        for (0..fixture.bytes.len) |prefix_length| {
            const outcome = try expect_decoder_equivalent(
                fixture.version,
                fixture.bytes[0..prefix_length],
                1 + prefix_length % 64,
            );
            try std.testing.expectEqual(DecoderTerminal.rejected, outcome.terminal);
        }
        @memcpy(mutated[0..fixture.bytes.len], fixture.bytes);
        for (0..fixture.bytes.len) |byte_index| {
            mutated[byte_index] ^= @as(u8, 1) << @intCast(byte_index % 8);
            _ = try expect_decoder_equivalent(
                fixture.version,
                mutated[0..fixture.bytes.len],
                1 + byte_index % 64,
            );
            mutated[byte_index] ^= @as(u8, 1) << @intCast(byte_index % 8);
        }
    }
}

fn expect_decoder_equivalent(
    version: ltx.FormatVersion,
    input: []const u8,
    chunk_bytes: usize,
) !DecoderOutcome {
    const contiguous = try decode_outcome(version, input, max_decoder_input_bytes);
    const fragmented = try decode_outcome(version, input, chunk_bytes);
    try std.testing.expectEqualDeep(contiguous, fragmented);
    return contiguous;
}

fn decode_outcome(
    version: ltx.FormatVersion,
    input: []const u8,
    chunk_bytes: usize,
) !DecoderOutcome {
    if (input.len > max_decoder_input_bytes) return error.TestInputTooLarge;
    if (chunk_bytes == 0) return error.InvalidTestChunkSize;
    var source = ChunkedReader{ .bytes = input, .max_chunk_bytes = chunk_bytes };
    var page_workspace: [max_decoder_page_bytes]u8 = undefined;
    var compressed_workspace: [max_decoder_compressed_bytes]u8 = undefined;
    var index_workspace: [max_decoder_pages]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        version,
        decoder_limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    var outcome = DecoderOutcome{};
    for (0..decoder_event_budget) |_| {
        const before = decoder.current_state();
        const event = decoder.next() catch |err| {
            outcome.failure = err;
            outcome.consumed_bytes = @intCast(source.offset_bytes);
            try std.testing.expectEqual(ltx.DecoderState.failed, decoder.current_state());
            try std.testing.expectError(error.InvalidState, decoder.next());
            return outcome;
        };
        outcome.event_count += 1;
        if (try record_decoder_event(&outcome, &decoder, version, before, event, input.len)) {
            outcome.consumed_bytes = @intCast(source.offset_bytes);
            try std.testing.expectEqual(@as(u64, @intCast(input.len)), outcome.consumed_bytes);
            try std.testing.expectError(error.InvalidState, decoder.next());
            return outcome;
        }
    }
    return error.DecoderDidNotTerminate;
}

fn record_decoder_event(
    outcome: *DecoderOutcome,
    decoder: *ltx.Decoder,
    version: ltx.FormatVersion,
    before: ltx.DecoderState,
    event: ltx.DecoderEvent,
    input_length: usize,
) !bool {
    switch (event) {
        .header => |header| {
            try std.testing.expectEqual(ltx.DecoderState.header, before);
            try std.testing.expectEqual(ltx.DecoderState.pages, decoder.current_state());
            try std.testing.expect(outcome.header == null);
            try header.validate(decoder_limits);
            outcome.header = header;
        },
        .unverified_page => |page| {
            try record_decoder_page(outcome, decoder, before, page);
        },
        .page_block_complete => {
            try std.testing.expectEqual(ltx.DecoderState.pages, before);
            try std.testing.expectEqual(ltx.DecoderState.page_index, decoder.current_state());
            try std.testing.expect(outcome.header != null);
            outcome.page_block_complete_count += 1;
            try std.testing.expectEqual(@as(u8, 1), outcome.page_block_complete_count);
            try expect_page_block_complete(outcome);
        },
        .verified => |verified| {
            try std.testing.expectEqual(ltx.DecoderState.page_index, before);
            try std.testing.expectEqual(ltx.DecoderState.verified, decoder.current_state());
            try std.testing.expectEqual(@as(u8, 1), outcome.page_block_complete_count);
            try std.testing.expectEqual(@as(u32, outcome.page_count), verified.page_count);
            try std.testing.expectEqual(@as(u64, @intCast(input_length)), verified.byte_count);
            try std.testing.expectEqual(version, verified.format_version);
            try std.testing.expectEqualDeep(outcome.header.?, verified.header);
            try expect_verified_checksum(outcome, verified);
            outcome.verified = verified;
            outcome.terminal = .verified;
            return true;
        },
    }
    return false;
}

fn record_decoder_page(
    outcome: *DecoderOutcome,
    decoder: *ltx.Decoder,
    before: ltx.DecoderState,
    page: ltx.UnverifiedPage,
) !void {
    try std.testing.expectEqual(ltx.DecoderState.pages, before);
    try std.testing.expectEqual(ltx.DecoderState.pages, decoder.current_state());
    const header = outcome.header orelse return error.PageBeforeHeader;
    try std.testing.expectEqual(@as(usize, header.page_size), page.data.len);
    try page.header.validate();
    const page_index: usize = outcome.page_count;
    if (page_index >= max_decoder_pages) return error.TestPageLimitExceeded;
    try expect_page_sequence(outcome, header, page.header.page_number);
    outcome.page_numbers[page_index] = page.header.page_number;
    outcome.page_flags[page_index] = page.header.flags;
    outcome.page_checksums[page_index] =
        (try ltx.checksum_page(page.header.page_number, page.data)).value;
    outcome.page_count += 1;
}

fn expect_page_sequence(
    outcome: *const DecoderOutcome,
    header: ltx.Header,
    page_number: u32,
) !void {
    try std.testing.expect(page_number <= header.commit);
    const lock_page = try ltx.lock_page_number(header.page_size);
    try std.testing.expect(page_number != lock_page);
    if (outcome.page_count == 0) {
        if (header.is_snapshot()) try std.testing.expectEqual(@as(u32, 1), page_number);
        return;
    }
    const previous = outcome.page_numbers[outcome.page_count - 1];
    if (!header.is_snapshot()) {
        try std.testing.expect(page_number > previous);
        return;
    }
    const increment: u32 = if (previous == lock_page - 1) 2 else 1;
    const expected = std.math.add(u32, previous, increment) catch {
        return error.TestPageSequenceOverflow;
    };
    try std.testing.expectEqual(expected, page_number);
}

fn expect_page_block_complete(outcome: *const DecoderOutcome) !void {
    const header = outcome.header orelse return error.PageBlockBeforeHeader;
    if (!header.is_snapshot()) return;
    const lock_page = try ltx.lock_page_number(header.page_size);
    const omitted: u32 = @intFromBool(lock_page <= header.commit);
    const expected_count = header.commit - omitted;
    try std.testing.expectEqual(expected_count, @as(u32, outcome.page_count));
}

fn expect_verified_checksum(
    outcome: *const DecoderOutcome,
    verified: ltx.VerifiedLTX,
) !void {
    if (verified.header.no_checksum()) {
        try std.testing.expectEqual(@as(u64, 0), verified.trailer.post_apply_checksum.value);
        return;
    }
    // Incremental pages do not carry the replaced pages needed to derive the
    // post-apply checksum without the database being transitioned.
    if (!verified.header.is_snapshot()) return;
    var rolling = ltx.rolling_checksum_initial();
    for (outcome.page_checksums[0..outcome.page_count]) |page_checksum| {
        rolling = try ltx.rolling_checksum_add(rolling, ltx.Checksum.init(page_checksum));
    }
    try std.testing.expectEqual(rolling.value, verified.trailer.post_apply_checksum.value);
}

fn versioned_slice_seed(
    comptime use_v2: bool,
    comptime selector: u64,
    comptime bytes: []const u8,
) [20 + bytes.len]u8 {
    var result: [20 + bytes.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], @intFromBool(use_v2), .little);
    std.mem.writeInt(u64, result[8..16], selector, .little);
    std.mem.writeInt(u32, result[16..20], bytes.len, .little);
    @memcpy(result[20..], bytes);
    return result;
}
