//! One-shot SQLite-to-LTX replication and restore — the consumer template.
//!
//! This example exercises the full replication library against the local
//! filesystem: a live SQLite database is captured into a Litestream-layout
//! L0 tree (snapshot, incremental, and post-checkpoint incremental), the
//! tree is planned and restored to a fresh path through the replica engine,
//! and every step prints what a host deployment would monitor.
//!
//! Run with: `mise exec -- zig build example-replicate-once`.
//! The example executable links the host system SQLite; the library modules
//! themselves never do.

const std = @import("std");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_wal = @import("ltx_wal");

const demo_directory = ".zig-cache/replicate-once-demo";

const codec_limits = ltx.Limits{
    .max_input_bytes = 1 << 20,
    .max_output_bytes = 1 << 20,
    .max_pages = 64,
    .max_page_size = 4096,
    .max_compressed_page_size = 4200,
    .max_page_index_bytes = 1 << 16,
    .max_page_index_entries = 64,
    .max_varint_bytes = 10,
    .max_transaction_span = 64,
};

const wal_limits = ltx_wal.Limits{
    .max_page_size = 4096,
    .max_pages = 64,
    .max_frames = 256,
};

var sql_buffer: [256]u8 = undefined;

fn sql(comptime format: []const u8, args: anytype) ![*:0]const u8 {
    const text = try std.fmt.bufPrintZ(&sql_buffer, format, args);
    return text.ptr;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, demo_directory) catch {};
    cwd.createDirPath(io, demo_directory) catch
        return error.DemoDirectoryFailure;
    var dir = try cwd.openDir(io, demo_directory, .{
        .access_sub_paths = true,
    });
    defer dir.close(io);

    var store = try ltx_object.FileClient.init(dir, io, "replica");
    const client = store.client();

    // Capture: one session, three transitions across a checkpoint.
    var session = try ltx_capture.Session.init(
        dir,
        io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    session.checkpoint_threshold_bytes = 32 + 3 * (24 + 4096);

    try session.exec(try sql(
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
        .{},
    ));
    try session.exec(try sql("INSERT INTO kv VALUES (1, 'one')", .{}));
    const snapshot_pages = try session.sync(&capture_storage, 1000);
    std.debug.print("sync 1: snapshot, {d} pages, position txid {d}\n", .{
        snapshot_pages, session.position.txid.value,
    });

    try session.exec(try sql("INSERT INTO kv VALUES (2, 'two')", .{}));
    const incremental_pages = try session.sync(&capture_storage, 2000);
    std.debug.print("sync 2: incremental, {d} pages, position txid {d}\n", .{
        incremental_pages, session.position.txid.value,
    });

    try session.checkpoint_passive(2500);
    try session.exec(try sql("INSERT INTO kv VALUES (3, 'three')", .{}));
    const restart_pages = try session.sync(&capture_storage, 3000);
    std.debug.print("sync 3: post-checkpoint incremental, {d} pages, position txid {d}\n", .{
        restart_pages, session.position.txid.value,
    });

    // List the published tree.
    var level_buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var level_lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    for (0..level_lists.len) |level| {
        level_lists[level] = try client.list(
            @intCast(level),
            ltx.TXID.init(0),
            &level_buffers[level],
        );
        for (level_lists[level]) |info| {
            var name: [ltx.file_name_bytes]u8 = undefined;
            std.debug.print("level {d}: {s}\n", .{
                info.level,
                ltx.format_file_name(info.min_txid, info.max_txid, &name),
            });
        }
    }

    // Restore the tree to a fresh path through the replica engine.
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(
        &level_lists,
        ltx.TXID.init(0),
        &plan_storage,
    );
    const backend = try ltx_replica.RestoreBackend.init(dir, io, "restored.db");
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 64, .max_database_bytes = 1 << 20 },
        .backend = backend,
        .storage = &restore_workspaces.storage,
        .page_workspace = &restore_workspaces.page,
        .compressed_workspace = &restore_workspaces.compressed,
        .index_workspace = &restore_workspaces.index,
    };
    const position = try job.run(plan);
    std.debug.print("restored {d} files to txid {d}\n", .{ plan.len, position.txid.value });
}

var capture_storage: ltx_capture.Workspaces = .{
    .wal_storage = &wal_buffer,
    .map_slots = &map_slots,
    .map_pending = &map_pending,
    .map_seen = &map_seen,
    .map_entries = &map_entries,
    .output_storage = &output_buffer,
    .page_workspace = &page_buffer,
    .compressed_workspace = &compressed_buffer,
    .compression_workspace = &compression,
    .index_workspace = &capture_index,
};

var wal_buffer: [1 << 20]u8 = undefined;
var map_slots: [64]ltx_wal.PageSlot =
    [_]ltx_wal.PageSlot{.{}} ** 64;
var map_pending: [64]u32 = [_]u32{0} ** 64;
var map_seen: [8]u8 = [_]u8{0} ** 8;
var map_entries: [64]ltx_wal.PageMapEntry =
    [_]ltx_wal.PageMapEntry{.{ .page_number = 0, .frame_offset_bytes = 0 }} ** 64;
var output_buffer: [1 << 20]u8 = undefined;
var page_buffer: [4096]u8 = undefined;
var compressed_buffer: [4200]u8 = undefined;
var compression: ltx.LZ4CompressionWorkspace = undefined;
var capture_index: [64]ltx.PageIndexEntry =
    [_]ltx.PageIndexEntry{.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 }} ** 64;

var restore_workspaces: struct {
    storage: [1 << 20]u8 = undefined,
    page: [4096]u8 = undefined,
    compressed: [4200]u8 = undefined,
    index: [64]ltx.PageIndexEntry =
        [_]ltx.PageIndexEntry{.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 }} ** 64,
} = .{};
