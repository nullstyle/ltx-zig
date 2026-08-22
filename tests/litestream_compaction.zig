const std = @import("std");
const ltx = @import("ltx");

const page_size: usize = 4096;
const max_pages: usize = 5;
const max_inputs: usize = 4;
const max_total_pages: u64 = 20;
const max_file_bytes: usize = 4096;
const max_compressed_bytes: usize = 4200;
const database_bytes: usize = max_pages * page_size;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_file_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = max_file_bytes,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = max_inputs,
};

const compaction_limits = ltx.CompactionLimits{
    .max_inputs = max_inputs,
    .max_total_pages = max_total_pages,
};

const apply_limits = ltx.ApplyLimits{
    .max_database_pages = max_pages,
    .max_database_bytes = database_bytes,
};

const capture_prefix = "fixtures/celld_litestream_v0511/replica/ltx/0/";
const tx1 = @embedFile(capture_prefix ++ "0000000000000001-0000000000000001.ltx");
const tx2 = @embedFile(capture_prefix ++ "0000000000000002-0000000000000002.ltx");
const tx3 = @embedFile(capture_prefix ++ "0000000000000003-0000000000000003.ltx");
const tx4 = @embedFile(capture_prefix ++ "0000000000000004-0000000000000004.ltx");
const tx5 = @embedFile(capture_prefix ++ "0000000000000005-0000000000000005.ltx");
const tx6 = @embedFile(capture_prefix ++ "0000000000000006-0000000000000006.ltx");

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [page_size]u8 = undefined,
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
};

const Compacted = struct {
    bytes: [max_file_bytes]u8 = undefined,
    length_bytes: usize = 0,
    verified: ltx.VerifiedLTX = undefined,

    fn slice(self: *const Compacted) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

const MemoryBackend = struct {
    published: [database_bytes]u8 = @splat(0),
    staged: [database_bytes]u8 = @splat(0),
    published_length_bytes: usize = 0,
    staged_length_bytes: usize = 0,
    position: ltx.Position = zero_position,
    page_size_value: ?u32 = null,
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
        return .{ .position = self.position, .page_size = self.page_size_value };
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
        if (self.page_size_value != expected.page_size) {
            return error.DatabasePageSizeMismatch;
        }
        @memcpy(
            self.published[0..self.staged_length_bytes],
            self.staged[0..self.staged_length_bytes],
        );
        self.published_length_bytes = self.staged_length_bytes;
        self.position = verified.post_apply_position();
        self.page_size_value = verified.header.page_size;
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

test "compacted real Litestream prefix remains compatible with legacy tail" {
    const prefix = [_][]const u8{ tx1, tx2, tx3, tx4 };
    var compacted: Compacted = .{};
    try compact_prefix(&prefix, &compacted);
    try expect_compacted_metadata(&compacted);

    var backend: MemoryBackend = .{};
    const compacted_verified = try apply_file(
        compacted.slice(),
        backend.backend(),
        .replace_snapshot,
    );
    try expect_applied(&backend, compacted_verified, 4, 1);
    try expect_sha256(
        backend.published[0..backend.published_length_bytes],
        "27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a",
    );

    const legacy_tail = [_][]const u8{ tx5, tx6 };
    const image_hashes = [_][]const u8{
        "a7e0ac305a281beb14c07d8ecce95e7a81369dfaa9f2c67bd168c016c8408261",
        "ee705e74c9788b64f5dc63b9c3dc028ae05aae34f240bad1362d9436c65150e0",
    };
    for (legacy_tail, image_hashes, 0..) |bytes, image_hash, index| {
        try expect_legacy_first_page(bytes);
        const verified = try apply_file(bytes, backend.backend(), .contiguous);
        const txid: u64 = @intCast(index + 5);
        try expect_applied(&backend, verified, txid, @intCast(index + 2));
        try expect_sha256(
            backend.published[0..backend.published_length_bytes],
            image_hash,
        );
    }
}

fn compact_prefix(files: []const []const u8, result: *Compacted) !void {
    if (files.len != max_inputs) return error.InvalidTestInputCount;
    var workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (files, 0..) |bytes, index| inputs[index] = workspaces[index].input(bytes);

    var sink = ltx.SliceWriter.init(&result.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        &inputs,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    result.verified = try compactor.compact();
    try std.testing.expectEqual(ltx.CompactorState.finished, compactor.current_state());
    result.length_bytes = sink.written().len;
}

fn expect_compacted_metadata(compacted: *const Compacted) !void {
    const verified = compacted.verified;
    try std.testing.expectEqual(ltx.header_flag_no_checksum, verified.header.flags);
    try std.testing.expectEqual(@as(u32, page_size), verified.header.page_size);
    try std.testing.expectEqual(@as(u32, max_pages), verified.header.commit);
    try std.testing.expectEqual(@as(u64, 1), verified.header.min_txid.value);
    try std.testing.expectEqual(@as(u64, 4), verified.header.max_txid.value);
    try std.testing.expectEqual(@as(i64, 1_780_109_201_308), verified.header.timestamp_ms);
    try std.testing.expectEqual(@as(u64, 0), verified.header.pre_apply_checksum.value);
    try std.testing.expectEqual(@as(i64, 0), verified.header.wal_offset);
    try std.testing.expectEqual(@as(i64, 0), verified.header.wal_size);
    try std.testing.expectEqual(@as(u32, 0), verified.header.wal_salt_1);
    try std.testing.expectEqual(@as(u32, 0), verified.header.wal_salt_2);
    try std.testing.expectEqual(@as(u64, 0), verified.header.node_id);
    try std.testing.expectEqual(@as(u64, 0), verified.trailer.post_apply_checksum.value);
    try std.testing.expectEqual(@as(u32, max_pages), verified.page_count);
    try expect_current_first_page(compacted.slice(), verified.header);
}

fn expect_current_first_page(bytes: []const u8, expected_header: ltx.Header) !void {
    var source = ltx.SliceReader.init(bytes);
    var page: [page_size]u8 = undefined;
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
    const header = switch (try decoder.next()) {
        .header => |value| value,
        else => return error.ExpectedCompactedHeader,
    };
    try std.testing.expectEqualDeep(expected_header, header);
    switch (try decoder.next()) {
        .unverified_page => |value| {
            try std.testing.expectEqual(@as(u32, 1), value.header.page_number);
            try std.testing.expectEqual(ltx.page_header_flag_size, value.header.flags);
        },
        else => return error.ExpectedCompactedPage,
    }
}

fn apply_file(
    bytes: []const u8,
    backend: ltx.ApplyBackend,
    mode: ltx.ApplyMode,
) !ltx.VerifiedLTX {
    var source = ltx.SliceReader.init(bytes);
    var page: [page_size]u8 = undefined;
    var compressed: [max_compressed_bytes]u8 = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        codec_limits,
        apply_limits,
        mode,
        source.reader(),
        backend,
        &page,
        &compressed,
        &index,
    );
    const verified = try applier.apply();
    try std.testing.expectEqual(ltx.ApplyState.published, applier.current_state());
    return verified;
}

fn expect_applied(
    backend: *const MemoryBackend,
    verified: ltx.VerifiedLTX,
    txid: u64,
    publish_count: u8,
) !void {
    try std.testing.expectEqual(@as(usize, database_bytes), backend.published_length_bytes);
    try std.testing.expectEqual(txid, verified.header.max_txid.value);
    try std.testing.expectEqual(txid, backend.position.txid.value);
    try std.testing.expectEqual(@as(u64, 0), backend.position.post_apply_checksum.value);
    try std.testing.expectEqual(@as(?u32, page_size), backend.page_size_value);
    try std.testing.expectEqual(publish_count, backend.publish_count);
    try std.testing.expect(!backend.active);
}

fn expect_legacy_first_page(bytes: []const u8) !void {
    const end = ltx.header_size + ltx.page_header_size + 4;
    if (bytes.len < end) return error.TruncatedTestFixture;
    try std.testing.expectEqualSlices(
        u8,
        "\x00\x00\x00\x01\x00\x00\x04\x22\x4d\x18",
        bytes[ltx.header_size..end],
    );
}

fn expect_sha256(input: []const u8, expected_hex: []const u8) !void {
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (expected_hex.len != expected.len * 2) return error.InvalidTestHash;
    const decoded = try std.fmt.hexToBytes(&expected, expected_hex);
    if (decoded.len != expected.len) return error.InvalidTestHash;
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
