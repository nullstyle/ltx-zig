const std = @import("std");
const ltx = @import("ltx");
const cases = @import("valid_chain_cases.zig");

const MemoryBackend = struct {
    published: [cases.database_capacity_bytes]u8 = @splat(0),
    staged: [cases.database_capacity_bytes]u8 = @splat(0),
    published_length_bytes: usize = 0,
    staged_length_bytes: usize = 0,
    position: ltx.Position = zero_position,
    page_size: ?u32 = null,
    plan: ?ltx.ApplyPlan = null,
    active: bool = false,
    publish_count: u8 = 0,

    const zero_position = ltx.Position{
        .txid = .init(0),
        .post_apply_checksum = .init(0),
    };

    fn backend(self: *MemoryBackend) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin,
            .stage_page_fn = stage_page,
            .read_page_fn = read_page,
            .publish_fn = publish,
            .abort_fn = abort,
            .backing_bytes = &self.staged,
        };
    }

    fn begin(
        context: *anyopaque,
        plan: ltx.ApplyPlan,
    ) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.active) return error.ApplyBeginFailure;
        const target_length = std.math.cast(usize, plan.final_database_size_bytes) orelse
            return error.ApplyBeginFailure;
        if (target_length > self.staged.len) return error.ApplyBeginFailure;

        @memset(self.staged[0..target_length], 0);
        if (!plan.header.is_snapshot()) {
            const clone_length = @min(target_length, self.published_length_bytes);
            @memcpy(self.staged[0..clone_length], self.published[0..clone_length]);
        }
        self.staged_length_bytes = target_length;
        self.plan = plan;
        self.active = true;
        return .{ .position = self.position, .page_size = self.page_size };
    }

    fn stage_page(
        context: *anyopaque,
        page: ltx.StagedPage,
    ) error{ApplyStageFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        const plan = self.plan orelse return error.ApplyStageFailure;
        if (!self.active or page.page_number == 0) return error.ApplyStageFailure;
        if (page.data.len != plan.header.page_size) return error.ApplyStageFailure;
        const offset = std.math.cast(usize, page.offset_bytes) orelse
            return error.ApplyStageFailure;
        const end = std.math.add(usize, offset, page.data.len) catch
            return error.ApplyStageFailure;
        if (end > self.staged_length_bytes) return error.ApplyStageFailure;
        @memcpy(self.staged[offset..end], page.data);
    }

    fn read_page(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        const plan = self.plan orelse return error.ApplyReadFailure;
        if (!self.active or page_number == 0) return error.ApplyReadFailure;
        if (destination.len != plan.header.page_size) return error.ApplyReadFailure;
        const page_index = @as(u64, page_number - 1);
        const offset_u64 = std.math.mul(u64, page_index, plan.header.page_size) catch
            return error.ApplyReadFailure;
        const offset = std.math.cast(usize, offset_u64) orelse
            return error.ApplyReadFailure;
        const end = std.math.add(usize, offset, destination.len) catch
            return error.ApplyReadFailure;
        if (end > self.staged_length_bytes) return error.ApplyReadFailure;
        @memcpy(destination, self.staged[offset..end]);
    }

    fn publish(
        context: *anyopaque,
        expected: ltx.ApplyCurrent,
        verified: ltx.VerifiedLTX,
    ) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (!self.active or self.plan == null) return error.ApplyPublishFailure;
        if (self.position.txid.value != expected.position.txid.value) {
            return error.NonContiguousTransition;
        }
        if (self.position.post_apply_checksum.value !=
            expected.position.post_apply_checksum.value)
        {
            return error.DivergentHistory;
        }
        if (self.page_size != expected.page_size) return error.DatabasePageSizeMismatch;
        @memcpy(
            self.published[0..self.staged_length_bytes],
            self.staged[0..self.staged_length_bytes],
        );
        self.published_length_bytes = self.staged_length_bytes;
        self.position = verified.post_apply_position();
        self.page_size = verified.header.page_size;
        self.plan = null;
        self.active = false;
        self.publish_count += 1;
    }

    fn abort(context: *anyopaque) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.plan = null;
        self.active = false;
    }
};

test "valid chain matrix checksummed growth at 512 bytes" {
    try run_case(.checked_grow_512);
}

test "valid chain matrix checksummed sparse update then shrink at 4096 bytes" {
    try run_case(.checked_sparse_shrink_4096);
}

test "valid chain matrix no-checksum shrink at the maximum page size" {
    try run_case(.no_checksum_max_page_shrink_65536);
}

test "valid chain matrix checksummed deletion at 1024 bytes" {
    try run_case(.checked_delete_1024);
}

test "valid chain matrix legacy snapshot followed by a current incremental" {
    try run_case(.legacy_current_512);
}

fn run_case(kind: cases.CaseKind) !void {
    var chain: cases.BuiltChain = undefined;
    try cases.build(kind, &chain);
    try expect_sha256(chain.expected_slice(), chain.expected_hash_hex);
    try expect_source_metadata(&chain);
    if (kind == .legacy_current_512) try expect_legacy_first_page(&chain);

    var sequential: MemoryBackend = .{};
    for (0..chain.input_count) |index| {
        const mode: ltx.ApplyMode = if (index == 0) .replace_snapshot else .contiguous;
        const verified = try apply_file(chain.inputs[index].slice(), sequential.backend(), mode);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), verified.header.max_txid.value);
        try std.testing.expectEqualDeep(chain.expected_positions[index], sequential.position);
    }
    try expect_final_backend(&sequential, &chain, @intCast(chain.input_count));

    var compacted: cases.Compacted = .{};
    try cases.compact(&chain, &compacted);
    try expect_compacted(&chain, &compacted);
    var collapsed: MemoryBackend = .{};
    const verified = try apply_file(compacted.slice(), collapsed.backend(), .replace_snapshot);
    try std.testing.expectEqualDeep(compacted.verified, verified);
    try expect_final_backend(&collapsed, &chain, 1);
    try std.testing.expectEqualSlices(u8, sequential.published[0..sequential.published_length_bytes], collapsed.published[0..collapsed.published_length_bytes]);
}

fn apply_file(
    bytes: []const u8,
    backend: ltx.ApplyBackend,
    mode: ltx.ApplyMode,
) !ltx.VerifiedLTX {
    var source = ltx.SliceReader.init(bytes);
    var page: [cases.max_page_bytes]u8 = undefined;
    var compressed: [cases.max_compressed_bytes]u8 = undefined;
    var index: [cases.max_database_pages]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        cases.codec_limits,
        cases.apply_limits,
        mode,
        source.reader(),
        backend,
        &page,
        &compressed,
        &index,
    );
    const verified = try applier.apply();
    try std.testing.expectEqual(ltx.ApplyState.published, applier.current_state());
    try std.testing.expectError(error.InvalidState, applier.apply());
    return verified;
}

fn expect_final_backend(
    backend: *const MemoryBackend,
    chain: *const cases.BuiltChain,
    publish_count: u8,
) !void {
    try std.testing.expectEqual(chain.expected_length_bytes, backend.published_length_bytes);
    try std.testing.expectEqualSlices(u8, chain.expected_slice(), backend.published[0..backend.published_length_bytes]);
    try std.testing.expectEqualDeep(
        chain.expected_positions[chain.input_count - 1],
        backend.position,
    );
    try std.testing.expectEqual(@as(?u32, chain.expected_page_size), backend.page_size);
    try std.testing.expectEqual(publish_count, backend.publish_count);
    try std.testing.expect(!backend.active);
    try expect_sha256(
        backend.published[0..backend.published_length_bytes],
        chain.expected_hash_hex,
    );
}

fn expect_compacted(chain: *const cases.BuiltChain, compacted: *const cases.Compacted) !void {
    const verified = compacted.verified;
    try std.testing.expect(verified.header.is_snapshot());
    try std.testing.expectEqual(chain.expected_header_flags, verified.header.flags);
    try std.testing.expectEqual(chain.expected_page_size, verified.header.page_size);
    try std.testing.expectEqual(chain.expected_commit, verified.header.commit);
    try std.testing.expectEqual(@as(u64, 1), verified.header.min_txid.value);
    try std.testing.expectEqual(@as(u64, @intCast(chain.input_count)), verified.header.max_txid.value);
    try std.testing.expectEqual(chain.expected_timestamp_ms, verified.header.timestamp_ms);
    try std.testing.expectEqual(@as(u64, 0), verified.header.pre_apply_checksum.value);
    try std.testing.expectEqual(@as(i64, 0), verified.header.wal_offset);
    try std.testing.expectEqual(@as(i64, 0), verified.header.wal_size);
    try std.testing.expectEqual(@as(u32, 0), verified.header.wal_salt_1);
    try std.testing.expectEqual(@as(u32, 0), verified.header.wal_salt_2);
    try std.testing.expectEqual(@as(u64, 0), verified.header.node_id);
    const expected_position = chain.expected_positions[chain.input_count - 1];
    try std.testing.expectEqual(
        expected_position.post_apply_checksum.value,
        verified.trailer.post_apply_checksum.value,
    );
    try std.testing.expectEqual(chain.expected_commit, verified.page_count);
    try std.testing.expectEqual(@as(u64, compacted.length_bytes), verified.byte_count);
    try expect_current_pages(chain, compacted);
}

fn expect_current_pages(
    chain: *const cases.BuiltChain,
    compacted: *const cases.Compacted,
) !void {
    var source = ltx.SliceReader.init(compacted.slice());
    var page: [cases.max_page_bytes]u8 = undefined;
    var compressed: [cases.max_compressed_bytes]u8 = undefined;
    var index: [cases.max_database_pages]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        cases.codec_limits,
        source.reader(),
        &page,
        &compressed,
        &index,
    );
    switch (try decoder.next()) {
        .header => |header| try std.testing.expectEqualDeep(compacted.verified.header, header),
        else => return error.TestExpectedHeader,
    }
    var page_count: usize = 0;
    for (0..decoder.event_budget()) |_| {
        switch (try decoder.next()) {
            .header => return error.TestUnexpectedHeader,
            .page_block_complete => {},
            .unverified_page => |event| {
                if (page_count >= chain.expected_commit) return error.TestUnexpectedPage;
                try std.testing.expectEqual(@as(u32, @intCast(page_count + 1)), event.header.page_number);
                try std.testing.expectEqual(ltx.page_header_flag_size, event.header.flags);
                const page_size: usize = @intCast(chain.expected_page_size);
                const offset = page_count * page_size;
                try std.testing.expectEqualSlices(
                    u8,
                    chain.expected_database[offset .. offset + page_size],
                    event.data,
                );
                page_count += 1;
            },
            .verified => |verified| {
                try std.testing.expectEqualDeep(compacted.verified, verified);
                try std.testing.expectEqual(@as(usize, chain.expected_commit), page_count);
                return;
            },
        }
    }
    return error.TestDecoderDidNotTerminate;
}

fn expect_source_metadata(chain: *const cases.BuiltChain) !void {
    const header = try decode_header(chain.inputs[chain.input_count - 1].slice());
    try std.testing.expect(header.wal_offset != 0);
    try std.testing.expect(header.wal_size != 0);
    try std.testing.expect(header.wal_salt_1 != 0);
    try std.testing.expect(header.wal_salt_2 != 0);
    try std.testing.expect(header.node_id != 0);
}

fn decode_header(bytes: []const u8) !ltx.Header {
    var source = ltx.SliceReader.init(bytes);
    var page: [cases.max_page_bytes]u8 = undefined;
    var compressed: [cases.max_compressed_bytes]u8 = undefined;
    var index: [cases.max_database_pages]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        cases.codec_limits,
        source.reader(),
        &page,
        &compressed,
        &index,
    );
    return switch (try decoder.next()) {
        .header => |header| header,
        else => error.TestExpectedHeader,
    };
}

fn expect_legacy_first_page(chain: *const cases.BuiltChain) !void {
    const bytes = chain.inputs[0].slice();
    const flags_start: usize = ltx.header_size + 4;
    if (bytes.len < flags_start + 2) return error.TestTruncatedLegacyFixture;
    try std.testing.expectEqualSlices(u8, "\x00\x00", bytes[flags_start .. flags_start + 2]);
}

fn expect_sha256(input: []const u8, expected_hex: []const u8) !void {
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (expected_hex.len != expected.len * 2) return error.TestInvalidHash;
    const decoded = try std.fmt.hexToBytes(&expected, expected_hex);
    if (decoded.len != expected.len) return error.TestInvalidHash;
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
