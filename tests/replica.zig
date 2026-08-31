//! `ltx_replica` executor tests: a real encoded chain flows through the
//! filesystem object client, restore planning, staged restore-to-path, level
//! compaction, and retention.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");
const replica = @import("ltx_replica");

const page_size = 512;
const read_workspace_bytes = 67;
const codec_limits = ltx.Limits{
    .max_input_bytes = 4096,
    .max_output_bytes = 4096,
    .max_pages = 4,
    .max_page_size = page_size,
    .max_compressed_page_size = 600,
    .max_page_index_bytes = 256,
    .max_page_index_entries = 4,
    .max_varint_bytes = 10,
    .max_transaction_span = 8,
};

const Page = [page_size]u8;

fn fill_page(page: *Page, value: u8) void {
    @memset(page, value);
}

fn rolling_checksum(pages: []const Page, numbers: []const u32) !ltx.Checksum {
    var checksum_value = ltx.rolling_checksum_initial();
    for (pages, numbers) |*page, number| {
        checksum_value = try ltx.rolling_checksum_add(
            checksum_value,
            try ltx.checksum_page(number, page),
        );
    }
    return checksum_value;
}

fn encode_transition(
    min_txid: u64,
    max_txid: u64,
    pre_checksum: ltx.Checksum,
    commit: u32,
    pages: []const Page,
    page_numbers: []const u32,
    post_checksum: ltx.Checksum,
    timestamp_ms: i64,
    writer: ltx.Writer,
) !void {
    var compressed: [600]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [4]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(.v3, codec_limits, writer, &compressed, &compression, &index);
    try encoder.write_header(.{
        .flags = 0,
        .page_size = page_size,
        .commit = commit,
        .min_txid = ltx.TXID.init(min_txid),
        .max_txid = ltx.TXID.init(max_txid),
        .timestamp_ms = timestamp_ms,
        .pre_apply_checksum = pre_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    });
    for (pages, page_numbers) |*page, number| {
        try encoder.write_page(number, page);
    }
    _ = try encoder.finish(post_checksum);
}

/// Snapshot at TXID 1 with pages {1:a1, 2:b2}, then incrementals TXID 2
/// {2:c3, +3:d4} and TXID 3 {3:e5}. Final image: a1, c3, e5.
fn write_chain(store: *object.FileClient) !void {
    const client = store.client();
    var page_one: Page = undefined;
    var page_two: Page = undefined;
    var page_three: Page = undefined;
    fill_page(&page_one, 0xa1);
    fill_page(&page_two, 0xb2);
    fill_page(&page_three, 0xd4);

    const snapshot_checksum = try rolling_checksum(
        &.{ page_one, page_two },
        &.{ 1, 2 },
    );
    var storage: [4096]u8 = undefined;
    var sink = ltx.SliceWriter.init(&storage);
    try encode_transition(
        1,
        1,
        ltx.Checksum.init(0),
        2,
        &.{ page_one, page_two },
        &.{ 1, 2 },
        snapshot_checksum,
        1000,
        sink.writer(),
    );
    try client.write(0, .{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    }, 1000, sink.written());

    fill_page(&page_two, 0xc3);
    const tx2_checksum = try rolling_checksum(
        &.{ page_one, page_two, page_three },
        &.{ 1, 2, 3 },
    );
    sink = ltx.SliceWriter.init(&storage);
    try encode_transition(
        2,
        2,
        snapshot_checksum,
        3,
        &.{ page_two, page_three },
        &.{ 2, 3 },
        tx2_checksum,
        2000,
        sink.writer(),
    );
    try client.write(0, .{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(2),
    }, 2000, sink.written());

    fill_page(&page_three, 0xe5);
    const tx3_checksum = try rolling_checksum(
        &.{ page_one, page_two, page_three },
        &.{ 1, 2, 3 },
    );
    sink = ltx.SliceWriter.init(&storage);
    try encode_transition(
        3,
        3,
        tx2_checksum,
        3,
        &.{page_three},
        &.{3},
        tx3_checksum,
        3000,
        sink.writer(),
    );
    try client.write(0, .{
        .min_txid = ltx.TXID.init(3),
        .max_txid = ltx.TXID.init(3),
    }, 3000, sink.written());
}

fn expected_image() [3]Page {
    var image: [3]Page = undefined;
    fill_page(&image[0], 0xa1);
    fill_page(&image[1], 0xc3);
    fill_page(&image[2], 0xe5);
    return image;
}

fn expect_restored_image(dir: std.Io.Dir, io: std.Io) !void {
    var file = try dir.openFile(io, "database.sqlite", .{});
    defer file.close(io);
    var actual: [3 * page_size]u8 = undefined;
    const read = try file.readPositionalAll(io, &actual, 0);
    try std.testing.expectEqual(@as(usize, 3 * page_size), read);
    const expected = expected_image();
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), actual[0 .. 3 * page_size]);
    // No staging file survives publication.
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(io, "database.sqlite.restore-tmp", .{}),
    );
}

fn list_all_levels(
    client: object.Client,
    lists: *[ltx.snapshot_level + 1][]const ltx.FileInfo,
    buffers: *[ltx.snapshot_level + 1][8]ltx.FileInfo,
) !void {
    for (0..lists.len) |level| {
        lists[level] = try client.list(
            @intCast(level),
            ltx.TXID.init(0),
            &buffers[level],
        );
    }
}

fn find_info(
    client: object.Client,
    level: u8,
    identity: ltx.FileIdentity,
) !ltx.FileInfo {
    var listed_storage: [8]ltx.FileInfo = undefined;
    const listed = try client.list(level, ltx.TXID.init(0), &listed_storage);
    for (listed) |info| {
        if (info.min_txid.value == identity.min_txid.value and
            info.max_txid.value == identity.max_txid.value)
        {
            return info;
        }
    }
    return error.ObjectNotFound;
}

const ReadFaultClient = struct {
    backing: object.Client,
    fail_at_call: u32,
    read_call_count: u32 = 0,

    fn client(self: *ReadFaultClient) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .begin_write_fn = begin_write,
            .delete_fn = delete_objects,
        };
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) object.Error![]const ltx.FileInfo {
        const self: *ReadFaultClient = @ptrCast(@alignCast(context));
        return self.backing.list(level, seek, destination);
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        offset_bytes: u64,
        destination: []u8,
    ) object.Error!void {
        const self: *ReadFaultClient = @ptrCast(@alignCast(context));
        self.read_call_count += 1;
        if (self.read_call_count == self.fail_at_call) {
            return error.StorageFailure;
        }
        return self.backing.read_range(info, offset_bytes, destination);
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) object.Error!void {
        const self: *ReadFaultClient = @ptrCast(@alignCast(context));
        return self.backing.write(level, identity, created_at_ms, bytes);
    }

    fn begin_write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) object.Error!object.WriteSession {
        const self: *ReadFaultClient = @ptrCast(@alignCast(context));
        return self.backing.begin_write(level, identity, created_at_ms);
    }

    fn delete_objects(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) object.Error!void {
        const self: *ReadFaultClient = @ptrCast(@alignCast(context));
        return self.backing.delete(files);
    }
};

const VerificationHarness = struct {
    read_workspace: [read_workspace_bytes]u8 = undefined,
    page_workspace: [page_size]u8 = undefined,
    compressed_workspace: [600]u8 = undefined,
    index_workspace: [4]ltx.PageIndexEntry = undefined,

    fn job(self: *VerificationHarness, client: object.Client) replica.VerificationJob {
        return .{
            .client = client,
            .codec_limits = codec_limits,
            .read_workspace = &self.read_workspace,
            .page_workspace = &self.page_workspace,
            .compressed_workspace = &self.compressed_workspace,
            .index_workspace = &self.index_workspace,
        };
    }
};

test "verification fully decodes a bounded plan and preserves read errors" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var listing: [8]ltx.FileInfo = undefined;
    const plan = try store.client().list(0, ltx.TXID.init(0), &listing);

    var harness = VerificationHarness{};
    var job = harness.job(store.client());
    const position = try job.run(plan);
    try std.testing.expectEqual(@as(u64, 3), position.txid.value);

    var fault = ReadFaultClient{
        .backing = store.client(),
        .fail_at_call = 2,
    };
    var fault_harness = VerificationHarness{};
    var fault_job = fault_harness.job(fault.client());
    try std.testing.expectError(error.StorageFailure, fault_job.run(plan));
    try std.testing.expectEqual(@as(u32, 2), fault.read_call_count);
}

test "verification rejects a fully decoded object under the wrong key" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();
    const source_identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const source_info = try find_info(client, 0, source_identity);
    var storage: [4096]u8 = undefined;
    const bytes = try client.read_all(source_info, &storage);
    const false_identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(9),
    };
    try client.write(1, false_identity, 9000, bytes);
    const false_info = try find_info(client, 1, false_identity);

    var harness = VerificationHarness{};
    var job = harness.job(client);
    try std.testing.expectError(
        error.ObjectIdentityMismatch,
        job.run(&.{false_info}),
    );
}

const NeverBeginBackend = struct {
    begin_count: u32 = 0,
    stage_count: u32 = 0,
    read_count: u32 = 0,
    publish_count: u32 = 0,
    abort_count: u32 = 0,

    fn backend(self: *NeverBeginBackend) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin,
            .stage_page_fn = stage_page,
            .read_page_fn = read_page,
            .publish_fn = publish,
            .abort_fn = abort,
        };
    }

    fn begin(
        context: *anyopaque,
        plan: ltx.ApplyPlan,
    ) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        _ = plan;
        const self: *NeverBeginBackend = @ptrCast(@alignCast(context));
        self.begin_count += 1;
        return error.ApplyBeginFailure;
    }

    fn stage_page(
        context: *anyopaque,
        page: ltx.StagedPage,
    ) error{ApplyStageFailure}!void {
        _ = page;
        const self: *NeverBeginBackend = @ptrCast(@alignCast(context));
        self.stage_count += 1;
        return error.ApplyStageFailure;
    }

    fn read_page(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        _ = page_number;
        _ = destination;
        const self: *NeverBeginBackend = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return error.ApplyReadFailure;
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
        _ = expected;
        _ = verified;
        const self: *NeverBeginBackend = @ptrCast(@alignCast(context));
        self.publish_count += 1;
        return error.ApplyPublishFailure;
    }

    fn abort(context: *anyopaque) void {
        const self: *NeverBeginBackend = @ptrCast(@alignCast(context));
        self.abort_count += 1;
    }
};

test "restore preflights every object bound before reading or staging" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var fault = ReadFaultClient{
        .backing = store.client(),
        .fail_at_call = std.math.maxInt(u32),
    };
    var listing: [8]ltx.FileInfo = undefined;
    const listed = try fault.client().list(0, ltx.TXID.init(0), &listing);
    var plan = [2]ltx.FileInfo{ listed[0], listed[1] };
    plan[1].size_bytes = codec_limits.max_input_bytes + 1;

    var apply_backend = NeverBeginBackend{};
    var read_workspace: [read_workspace_bytes]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var job = replica.RestoreJob{
        .client = fault.client(),
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = apply_backend.backend(),
        .read_workspace = &read_workspace,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    try std.testing.expectError(error.InputLimitExceeded, job.run(&plan));
    try std.testing.expectEqual(@as(u32, 0), fault.read_call_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.begin_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.stage_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.read_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.publish_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.abort_count);
}

test "restore rejects a plan aliased with its mutable read window" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var fault = ReadFaultClient{
        .backing = store.client(),
        .fail_at_call = std.math.maxInt(u32),
    };
    var listing: [8]ltx.FileInfo = undefined;
    _ = try fault.client().list(0, ltx.TXID.init(0), &listing);
    const plan = listing[0..2];

    var apply_backend = NeverBeginBackend{};
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var job = replica.RestoreJob{
        .client = fault.client(),
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = apply_backend.backend(),
        .read_workspace = std.mem.sliceAsBytes(plan),
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    try std.testing.expectError(error.WorkspaceAliasing, job.run(plan));
    try std.testing.expectEqual(@as(u32, 0), fault.read_call_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.begin_count);
    try std.testing.expectEqual(@as(u32, 0), apply_backend.publish_count);
}

test "restore rejects object key and header identity mismatches before staging" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();

    const cases = [_]struct {
        source: ltx.FileIdentity,
        stored_as: ltx.FileIdentity,
    }{
        .{
            .source = .{ .min_txid = ltx.TXID.init(1), .max_txid = ltx.TXID.init(1) },
            .stored_as = .{ .min_txid = ltx.TXID.init(1), .max_txid = ltx.TXID.init(9) },
        },
        .{
            .source = .{ .min_txid = ltx.TXID.init(2), .max_txid = ltx.TXID.init(2) },
            .stored_as = .{ .min_txid = ltx.TXID.init(1), .max_txid = ltx.TXID.init(2) },
        },
    };
    for (cases, 0..) |case, index| {
        var source_storage: [4096]u8 = undefined;
        const source_info = try find_info(client, 0, case.source);
        const source_bytes = try client.read_all(source_info, &source_storage);
        try client.write(0, case.stored_as, @intCast(9000 + index), source_bytes);

        var apply_backend = NeverBeginBackend{};
        var read_workspace: [read_workspace_bytes]u8 = undefined;
        var page_workspace: [page_size]u8 = undefined;
        var compressed_workspace: [600]u8 = undefined;
        var index_workspace: [4]ltx.PageIndexEntry = undefined;
        var job = replica.RestoreJob{
            .client = client,
            .codec_limits = codec_limits,
            .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
            .backend = apply_backend.backend(),
            .read_workspace = &read_workspace,
            .page_workspace = &page_workspace,
            .compressed_workspace = &compressed_workspace,
            .index_workspace = &index_workspace,
        };
        const false_info = ltx.FileInfo{
            .level = 0,
            .min_txid = case.stored_as.min_txid,
            .max_txid = case.stored_as.max_txid,
            .size_bytes = source_bytes.len,
        };
        try std.testing.expectError(error.ObjectIdentityMismatch, job.run(&.{false_info}));
        try std.testing.expectEqual(@as(u32, 0), apply_backend.begin_count);
        try std.testing.expectEqual(@as(u32, 0), apply_backend.stage_count);
        try std.testing.expectEqual(@as(u32, 0), apply_backend.read_count);
        try std.testing.expectEqual(@as(u32, 0), apply_backend.publish_count);
        try std.testing.expectEqual(@as(u32, 0), apply_backend.abort_count);
    }
}

test "restore replans and restores a level-0 chain to an exact image" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();

    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_all_levels(client, &lists, &buffers);
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    try std.testing.expectEqual(@as(usize, 3), plan.len);

    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var read_workspace: [read_workspace_bytes]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var job = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend.backend(),
        .read_workspace = &read_workspace,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const position = try job.run(plan);
    try std.testing.expectEqual(@as(u64, 3), position.txid.value);
    try expect_restored_image(temporary.dir, std.testing.io);

    // A new restore replaces the already-published TXID 3 image with the
    // snapshot at the front of the capped plan, then continues to TXID 2.
    const capped_plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(2), &plan_storage);
    const capped_position = try job.run(capped_plan);
    try std.testing.expectEqual(@as(u64, 2), capped_position.txid.value);
    try std.testing.expectEqual(@as(u64, 2), backend.current().position.txid.value);
}

test "restore preserves a ranged transport error and aborts private staging" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var fault = ReadFaultClient{
        .backing = store.client(),
        .fail_at_call = 3,
    };
    var listing: [8]ltx.FileInfo = undefined;
    const plan = try fault.client().list(0, ltx.TXID.init(0), &listing);
    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "failed.sqlite",
    );
    var read_workspace: [read_workspace_bytes]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var job = replica.RestoreJob{
        .client = fault.client(),
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend.backend(),
        .read_workspace = &read_workspace,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    try std.testing.expectError(error.StorageFailure, job.run(plan));
    try std.testing.expectEqual(@as(u32, 3), fault.read_call_count);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(std.testing.io, "failed.sqlite", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(std.testing.io, "failed.sqlite.restore-tmp", .{}),
    );
}

test "small-window input and zero-buffer output agree on the restored image" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();

    // Compact the first two L0 files into L1.
    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_all_levels(client, &lists, &buffers);
    const compaction_plan = try replica.plan_compaction(
        lists[0],
        lists[1],
        2,
        8192,
    );
    try std.testing.expectEqual(@as(usize, 2), compaction_plan.input_count);

    var input_read_workspaces: [2][read_workspace_bytes]u8 = undefined;
    var input_pages: [2][page_size]u8 = undefined;
    var input_compressed: [2][600]u8 = undefined;
    var input_indexes: [2][4]ltx.PageIndexEntry = undefined;
    var job_inputs = [2]replica.CompactionJobInput{
        .{
            .read_workspace = &input_read_workspaces[0],
            .page_workspace = &input_pages[0],
            .compressed_workspace = &input_compressed[0],
            .index_workspace = &input_indexes[0],
        },
        .{
            .read_workspace = &input_read_workspaces[1],
            .page_workspace = &input_pages[1],
            .compressed_workspace = &input_compressed[1],
            .index_workspace = &input_indexes[1],
        },
    };
    var compaction_inputs: [2]ltx.CompactionInput = undefined;
    var output_storage: [0]u8 = .{};
    var output_compressed: [600]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [4]ltx.PageIndexEntry = undefined;
    var job = replica.CompactionJob{
        .client = client,
        .codec_limits = codec_limits,
        .compaction_limits = .{ .max_inputs = 2, .max_total_pages = 4 },
        .inputs = &job_inputs,
        .compaction_inputs = &compaction_inputs,
        .output_storage = &output_storage,
        .output_compressed_workspace = &output_compressed,
        .output_compression_workspace = &output_compression,
        .output_index_workspace = &output_index,
    };
    const verified = try job.run(lists[0][0..compaction_plan.input_count], 1);
    try std.testing.expectEqual(@as(u64, 1), verified.header.min_txid.value);
    try std.testing.expectEqual(@as(u64, 2), verified.header.max_txid.value);

    // The mixed tree (L1 1-2 plus the L0 tail at 3) restores to the same
    // exact image as the full L0 chain.
    try list_all_levels(client, &lists, &buffers);
    try std.testing.expectEqual(@as(usize, 1), lists[1].len);
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    try std.testing.expectEqual(@as(usize, 2), plan.len);
    try std.testing.expectEqual(@as(u8, 1), plan[0].level);

    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var restore_read_workspace: [read_workspace_bytes]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var restore_job = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend.backend(),
        .read_workspace = &restore_read_workspace,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const position = try restore_job.run(plan);
    try std.testing.expectEqual(@as(u64, 3), position.txid.value);
    try expect_restored_image(temporary.dir, std.testing.io);

    // Retention deletes the two absorbed L0 files; restore still works.
    var retention_storage: [8]ltx.FileInfo = undefined;
    const deletable = replica.plan_retention(lists[0], lists[1], &retention_storage);
    try std.testing.expectEqual(@as(usize, 2), deletable.len);
    try client.delete(deletable);
    try list_all_levels(client, &lists, &buffers);
    try std.testing.expectEqual(@as(usize, 1), lists[0].len);

    var backend_two = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var restore_job_two = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend_two.backend(),
        .read_workspace = &restore_read_workspace,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const replay_plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    _ = try restore_job_two.run(replay_plan);
    try expect_restored_image(temporary.dir, std.testing.io);
}

const CompactionHarness = struct {
    input_read_workspaces: [2][read_workspace_bytes]u8 = undefined,
    input_pages: [2][page_size]u8 = undefined,
    input_compressed: [2][600]u8 = undefined,
    input_indexes: [2][4]ltx.PageIndexEntry = undefined,
    job_inputs: [2]replica.CompactionJobInput = undefined,
    compaction_inputs: [2]ltx.CompactionInput = undefined,
    output_compressed: [600]u8 = undefined,
    output_compression: ltx.LZ4CompressionWorkspace = undefined,
    output_index: [4]ltx.PageIndexEntry = undefined,

    fn job(
        self: *CompactionHarness,
        client: object.Client,
        output_storage: []u8,
    ) replica.CompactionJob {
        for (&self.job_inputs, 0..) |*input, index| {
            input.* = .{
                .read_workspace = &self.input_read_workspaces[index],
                .page_workspace = &self.input_pages[index],
                .compressed_workspace = &self.input_compressed[index],
                .index_workspace = &self.input_indexes[index],
            };
        }
        return .{
            .client = client,
            .codec_limits = codec_limits,
            .compaction_limits = .{ .max_inputs = 2, .max_total_pages = 4 },
            .inputs = &self.job_inputs,
            .compaction_inputs = &self.compaction_inputs,
            .output_storage = output_storage,
            .output_compressed_workspace = &self.output_compressed,
            .output_compression_workspace = &self.output_compression,
            .output_index_workspace = &self.output_index,
        };
    }
};

fn overwrite_second_payload_with_wider_txid(store: *object.FileClient) !void {
    var page_one: Page = undefined;
    var page_two: Page = undefined;
    var page_three: Page = undefined;
    fill_page(&page_one, 0xa1);
    fill_page(&page_two, 0xb2);
    const snapshot_checksum = try rolling_checksum(&.{ page_one, page_two }, &.{ 1, 2 });
    fill_page(&page_two, 0xc3);
    fill_page(&page_three, 0xd4);
    const post_checksum = try rolling_checksum(
        &.{ page_one, page_two, page_three },
        &.{ 1, 2, 3 },
    );
    var storage: [4096]u8 = undefined;
    var sink = ltx.SliceWriter.init(&storage);
    try encode_transition(
        2,
        3,
        snapshot_checksum,
        3,
        &.{ page_two, page_three },
        &.{ 2, 3 },
        post_checksum,
        2000,
        sink.writer(),
    );
    try store.client().write(
        0,
        .{ .min_txid = .init(2), .max_txid = .init(2) },
        2000,
        sink.written(),
    );
}

test "compaction preserves whole-object fallback without write sessions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var client = store.client();
    client.begin_write_fn = null;
    var listing: [8]ltx.FileInfo = undefined;
    const source = try client.list(0, ltx.TXID.init(0), &listing);
    var harness = CompactionHarness{};
    var output_storage: [4096]u8 = undefined;
    var job = harness.job(client, &output_storage);
    const verified = try job.run(source[0..2], 1);
    try std.testing.expectEqual(@as(u64, 2), verified.header.max_txid.value);
    const destination = try client.list(1, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(@as(usize, 1), destination.len);
}

test "compaction rejects aliased mutable read windows before publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();
    var listing: [8]ltx.FileInfo = undefined;
    const source = try client.list(0, ltx.TXID.init(0), &listing);
    var harness = CompactionHarness{};
    var no_output_storage: [0]u8 = .{};
    var job = harness.job(client, &no_output_storage);
    job.inputs[1].read_workspace = job.inputs[0].read_workspace;
    try std.testing.expectError(
        error.WorkspaceAliasing,
        job.run(source[0..2], 1),
    );
    try std.testing.expect(!store.write_session_active);
    const destination = try client.list(1, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(@as(usize, 0), destination.len);
}

test "compaction rejects source metadata aliased with a mutable read window" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var fault = ReadFaultClient{
        .backing = store.client(),
        .fail_at_call = std.math.maxInt(u32),
    };
    const client = fault.client();
    var listing: [8]ltx.FileInfo = undefined;
    _ = try client.list(0, ltx.TXID.init(0), &listing);
    const source = listing[0..2];
    var harness = CompactionHarness{};
    var no_output_storage: [0]u8 = .{};
    var job = harness.job(client, &no_output_storage);
    job.inputs[0].read_workspace = std.mem.sliceAsBytes(source);
    try std.testing.expectError(
        error.WorkspaceAliasing,
        job.run(source, 1),
    );
    try std.testing.expectEqual(@as(u32, 0), fault.read_call_count);
    try std.testing.expect(!store.write_session_active);
}

test "streaming compaction ignores inactive aliased output storage" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();
    var listing: [8]ltx.FileInfo = undefined;
    const source = try client.list(0, ltx.TXID.init(0), &listing);
    var harness = CompactionHarness{};
    var no_output_storage: [0]u8 = .{};
    var job = harness.job(client, &no_output_storage);
    job.output_storage = job.inputs[0].read_workspace;
    const verified = try job.run(source[0..2], 1);
    try std.testing.expectEqual(@as(u64, 2), verified.header.max_txid.value);
    const destination = try client.list(1, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(@as(usize, 1), destination.len);
}

test "streaming compaction preserves a ranged error and aborts output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    var fault = ReadFaultClient{
        .backing = store.client(),
        // Two range reads probe the final header; fail on the first refill
        // after private output staging begins.
        .fail_at_call = 3,
    };
    const client = fault.client();
    var listing: [8]ltx.FileInfo = undefined;
    const source = try client.list(0, ltx.TXID.init(0), &listing);
    var harness = CompactionHarness{};
    var no_output_storage: [0]u8 = .{};
    var job = harness.job(client, &no_output_storage);
    try std.testing.expectError(error.StorageFailure, job.run(source[0..2], 1));
    try std.testing.expectEqual(@as(u32, 3), fault.read_call_count);
    try std.testing.expect(!store.write_session_active);
    const destination = try client.list(1, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(@as(usize, 0), destination.len);
}

test "streaming compaction aborts when object keys mismatch output identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    try overwrite_second_payload_with_wider_txid(&store);
    const client = store.client();
    var listing: [8]ltx.FileInfo = undefined;
    const source = try client.list(0, ltx.TXID.init(0), &listing);
    var harness = CompactionHarness{};
    var no_output_storage: [0]u8 = .{};
    var job = harness.job(client, &no_output_storage);
    try std.testing.expectError(
        error.ObjectIdentityMismatch,
        job.run(source[0..2], 1),
    );
    try std.testing.expect(!store.write_session_active);
    const destination = try client.list(1, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(@as(usize, 0), destination.len);
}
