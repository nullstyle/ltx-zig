//! `ltx_replica` executor tests: a real encoded chain flows through the
//! filesystem object client, restore planning, staged restore-to-path, level
//! compaction, and retention.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");
const replica = @import("ltx_replica");

const page_size = 512;
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

    const backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var object_storage: [4096]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var job = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend,
        .storage = &object_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const position = try job.run(plan);
    try std.testing.expectEqual(@as(u64, 3), position.txid.value);
    try expect_restored_image(temporary.dir, std.testing.io);

    // A targeted restore to TXID 2 stops at the second image.
    const backend_two = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var job_two = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend_two,
        .storage = &object_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const capped_plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(2), &plan_storage);
    const capped_position = try job_two.run(capped_plan);
    try std.testing.expectEqual(@as(u64, 2), capped_position.txid.value);
}

test "compaction, mixed-level restore, and retention agree on the image" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try write_chain(&store);
    const client = store.client();

    // Compact the first two L0 files into L1.
    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_all_levels(client, &lists, &buffers);
    var sizes: [8]u64 = undefined;
    for (lists[0], 0..) |info, index| {
        var object_storage: [4096]u8 = undefined;
        const bytes = try client.open(
            0,
            .{ .min_txid = info.min_txid, .max_txid = info.max_txid },
            &object_storage,
        );
        sizes[index] = bytes.len;
    }
    const compaction_plan = try replica.plan_compaction(
        lists[0],
        lists[1],
        2,
        8192,
        sizes[0..lists[0].len],
    );
    try std.testing.expectEqual(@as(usize, 2), compaction_plan.input_count);

    var input_storage: [2][4096]u8 = undefined;
    var input_pages: [2][page_size]u8 = undefined;
    var input_compressed: [2][600]u8 = undefined;
    var input_indexes: [2][4]ltx.PageIndexEntry = undefined;
    var job_inputs = [2]replica.CompactionJobInput{
        .{
            .storage = &input_storage[0],
            .page_workspace = &input_pages[0],
            .compressed_workspace = &input_compressed[0],
            .index_workspace = &input_indexes[0],
        },
        .{
            .storage = &input_storage[1],
            .page_workspace = &input_pages[1],
            .compressed_workspace = &input_compressed[1],
            .index_workspace = &input_indexes[1],
        },
    };
    var compaction_inputs: [2]ltx.CompactionInput = undefined;
    var readers: [2]ltx.SliceReader = undefined;
    var output_storage: [4096]u8 = undefined;
    var output_compressed: [600]u8 = undefined;
    var output_compression: ltx.LZ4CompressionWorkspace = undefined;
    var output_index: [4]ltx.PageIndexEntry = undefined;
    var job = replica.CompactionJob{
        .client = client,
        .codec_limits = codec_limits,
        .compaction_limits = .{ .max_inputs = 2, .max_total_pages = 4 },
        .inputs = &job_inputs,
        .compaction_inputs = &compaction_inputs,
        .readers = &readers,
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

    const backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var restore_storage: [4096]u8 = undefined;
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [600]u8 = undefined;
    var index_workspace: [4]ltx.PageIndexEntry = undefined;
    var restore_job = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend,
        .storage = &restore_storage,
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

    const backend_two = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "database.sqlite",
    );
    var restore_job_two = replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 4, .max_database_bytes = 4096 },
        .backend = backend_two,
        .storage = &restore_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const replay_plan = try replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    _ = try restore_job_two.run(replay_plan);
    try expect_restored_image(temporary.dir, std.testing.io);
}
