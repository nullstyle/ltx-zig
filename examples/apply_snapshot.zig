const std = @import("std");
const ltx = @import("ltx");

const page_size_bytes: usize = 512;
const encoded_capacity_bytes: usize = 800;
const compressed_capacity_bytes: usize = 530;

const codec_limits = ltx.Limits{
    .max_input_bytes = encoded_capacity_bytes,
    .max_output_bytes = encoded_capacity_bytes,
    .max_pages = 1,
    .max_page_size = page_size_bytes,
    .max_compressed_page_size = compressed_capacity_bytes,
    .max_page_index_bytes = 32,
    .max_page_index_entries = 1,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const apply_limits = ltx.ApplyLimits{
    .max_database_pages = 1,
    .max_database_bytes = page_size_bytes,
};

const zero_position = ltx.Position{
    .txid = .init(0),
    .post_apply_checksum = .init(0),
};

const Encoded = struct {
    length_bytes: usize,
    verified: ltx.VerifiedLTX,
};

const MemoryBackend = struct {
    published: [page_size_bytes]u8 = @splat(0),
    staged: [page_size_bytes]u8 = @splat(0),
    published_length_bytes: usize = 0,
    staged_length_bytes: usize = 0,
    position: ltx.Position = zero_position,
    page_size: ?u32 = null,
    plan: ?ltx.ApplyPlan = null,
    active: bool = false,
    stage_count: u8 = 0,
    read_count: u8 = 0,
    publish_count: u8 = 0,
    abort_count: u8 = 0,

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

        @memset(&self.staged, 0);
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
        const expected_offset = std.math.mul(
            u64,
            @as(u64, page.page_number - 1),
            plan.header.page_size,
        ) catch return error.ApplyStageFailure;
        if (page.offset_bytes != expected_offset) return error.ApplyStageFailure;
        const offset = std.math.cast(usize, page.offset_bytes) orelse
            return error.ApplyStageFailure;
        const end = std.math.add(usize, offset, page.data.len) catch
            return error.ApplyStageFailure;
        if (end > self.staged_length_bytes) return error.ApplyStageFailure;
        @memcpy(self.staged[offset..end], page.data);
        self.stage_count += 1;
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
        const offset = std.math.cast(usize, offset_u64) orelse return error.ApplyReadFailure;
        const end = std.math.add(usize, offset, destination.len) catch
            return error.ApplyReadFailure;
        if (end > self.staged_length_bytes) return error.ApplyReadFailure;
        @memcpy(destination, self.staged[offset..end]);
        self.read_count += 1;
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
        const plan = self.plan orelse return error.ApplyPublishFailure;
        if (!self.active or verified.format_version != plan.format_version or
            !std.meta.eql(plan.header, verified.header))
        {
            return error.ApplyPublishFailure;
        }
        if (expected.position.txid.value != self.position.txid.value) {
            return error.NonContiguousTransition;
        }
        if (expected.position.post_apply_checksum.value != self.position.post_apply_checksum.value) {
            return error.DivergentHistory;
        }
        if (expected.page_size != self.page_size) return error.DatabasePageSizeMismatch;

        // This example has one owner and no concurrent observers. Within that
        // model, no fallible work follows this private commit boundary.
        @memset(&self.published, 0);
        @memcpy(self.published[0..self.staged_length_bytes], self.staged[0..self.staged_length_bytes]);
        self.published_length_bytes = self.staged_length_bytes;
        self.position = verified.post_apply_position();
        self.page_size = verified.header.page_size;
        self.plan = null;
        self.active = false;
        self.publish_count += 1;
    }

    fn abort(context: *anyopaque) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        @memset(&self.staged, 0);
        self.staged_length_bytes = 0;
        self.plan = null;
        self.active = false;
        self.abort_count += 1;
    }
};

pub fn main() !void {
    const expected_page: [page_size_bytes]u8 = @splat(0x5a);
    var encoded_bytes: [encoded_capacity_bytes]u8 = @splat(0);
    const encoded = try encode_snapshot(&encoded_bytes, &expected_page);

    var storage: MemoryBackend = .{};
    const applied = try apply_snapshot(
        encoded_bytes[0..encoded.length_bytes],
        storage.backend(),
    );
    try expect_success(&storage, &expected_page, encoded.verified, applied);

    var corrupted = encoded_bytes;
    corrupted[encoded.length_bytes - 1] ^= 1;
    const published_position = storage.position;
    _ = apply_snapshot(corrupted[0..encoded.length_bytes], storage.backend()) catch |err| {
        if (err != error.ChecksumMismatch) return err;
        try expect_failed_apply_discarded(&storage, &expected_page, published_position);
        return;
    };
    return error.CorruptedSnapshotWasPublished;
}

fn encode_snapshot(
    output: *[encoded_capacity_bytes]u8,
    page: *const [page_size_bytes]u8,
) !Encoded {
    var sink = ltx.SliceWriter.init(output);
    var compressed: [compressed_capacity_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(snapshot_header());
    try encoder.write_page(1, page);
    const verified = try encoder.finish(try ltx.checksum_page(1, page));
    return .{ .length_bytes = sink.written().len, .verified = verified };
}

fn apply_snapshot(encoded: []const u8, backend: ltx.ApplyBackend) !ltx.VerifiedLTX {
    var source = ltx.SliceReader.init(encoded);
    var page: [page_size_bytes]u8 = undefined;
    var compressed: [compressed_capacity_bytes]u8 = undefined;
    var index: [1]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        codec_limits,
        apply_limits,
        .replace_snapshot,
        source.reader(),
        backend,
        &page,
        &compressed,
        &index,
    );
    return applier.apply();
}

fn expect_success(
    storage: *const MemoryBackend,
    expected_page: *const [page_size_bytes]u8,
    encoded: ltx.VerifiedLTX,
    applied: ltx.VerifiedLTX,
) !void {
    if (!std.meta.eql(encoded, applied)) return error.VerifiedResultMismatch;
    if (storage.published_length_bytes != page_size_bytes or
        !std.mem.eql(u8, &storage.published, expected_page))
    {
        return error.PublishedImageMismatch;
    }
    if (!std.meta.eql(storage.position, applied.post_apply_position())) {
        return error.PublishedPositionMismatch;
    }
    if (storage.page_size != @as(u32, page_size_bytes) or storage.active) {
        return error.InvalidBackendState;
    }
    if (storage.stage_count != 1 or storage.read_count != 1 or
        storage.publish_count != 1 or storage.abort_count != 0)
    {
        return error.UnexpectedBackendCalls;
    }
}

fn expect_failed_apply_discarded(
    storage: *const MemoryBackend,
    expected_page: *const [page_size_bytes]u8,
    expected_position: ltx.Position,
) !void {
    if (storage.published_length_bytes != page_size_bytes or
        !std.mem.eql(u8, &storage.published, expected_page))
    {
        return error.FailedApplyChangedImage;
    }
    if (!std.meta.eql(storage.position, expected_position)) {
        return error.FailedApplyChangedPosition;
    }
    if (storage.page_size != @as(u32, page_size_bytes) or storage.active or storage.plan != null) {
        return error.FailedApplyRetainedStage;
    }
    if (storage.stage_count != 2 or storage.read_count != 1 or
        storage.publish_count != 1 or storage.abort_count != 1)
    {
        return error.UnexpectedBackendCalls;
    }
}

fn snapshot_header() ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size_bytes,
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
