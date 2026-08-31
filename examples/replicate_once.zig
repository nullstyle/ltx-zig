//! One-shot SQLite-to-LTX replication and restore — the consumer template.
//!
//! This example exercises the high-level replication controller against the
//! local filesystem: a live SQLite database is captured into a
//! Litestream-layout object tree, then restored to a fresh path and verified.
//! The host supplies SQLite writes, scheduling timestamps, fixed workspaces,
//! the object adapter, and the filesystem apply backend.
//!
//! Run with: `mise exec -- zig build example-replicate-once`.
//! The example executable links the host system SQLite; the library modules
//! themselves never do.

const std = @import("std");
const ltx = @import("ltx");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_replication = @import("ltx_replication");
const ltx_wal = @import("ltx_wal");

const demo_directory = ".zig-cache/replicate-once-demo";
const database_name = "app.db";
const restored_database_name = "restored.db";
const max_object_bytes = 1 << 20;
const max_page_bytes = 4096;
const max_compressed_bytes = 4200;
const max_pages = 64;
const max_frames = 256;
const max_files_per_level = 8;
const max_restore_files = 8;
const max_compaction_inputs = 1;
const read_workspace_bytes: u32 = 64 * 1024;
const level_count = @as(usize, ltx.snapshot_level) + 1;
const max_wal_bytes = ltx_wal.header_size_bytes +
    max_frames * (ltx_wal.frame_header_size_bytes + max_page_bytes);
const checkpoint_threshold_bytes: u64 = ltx_wal.header_size_bytes +
    2 * (ltx_wal.frame_header_size_bytes + max_page_bytes);

const codec_limits = ltx.Limits{
    .max_input_bytes = max_object_bytes,
    .max_output_bytes = max_object_bytes,
    .max_pages = max_pages,
    .max_page_size = max_page_bytes,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 1 << 16,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = max_pages,
};

const wal_limits = ltx_wal.Limits{
    .max_page_size = max_page_bytes,
    .max_pages = max_pages,
    .max_frames = max_frames,
};

const controller_config = ltx_replication.Config{
    .codec_limits = codec_limits,
    .wal_limits = wal_limits,
    .apply_limits = .{
        .max_database_pages = max_pages,
        .max_database_bytes = max_object_bytes,
    },
    .compaction_limits = .{
        .max_inputs = max_compaction_inputs,
        .max_total_pages = max_pages * max_compaction_inputs,
    },
    .levels = .{ .levels = &ltx_replica.default_levels },
    .max_files_per_level = max_files_per_level,
    .max_restore_files = max_restore_files,
    .max_compaction_input_bytes = max_object_bytes * max_compaction_inputs,
    .read_workspace_bytes = read_workspace_bytes,
    // The controller performs checkpoints after capture; the next sync then
    // demonstrates a segment restart without exposing the capture session.
    .checkpoint_threshold_bytes = checkpoint_threshold_bytes,
};

const sqlite_ok: c_int = 0;
const sqlite_row: c_int = 100;
const sqlite_open_readonly: c_int = 0x0000_0001;
const sqlite_open_readwrite: c_int = 0x0000_0002;
const sqlite_open_create: c_int = 0x0000_0004;
const sqlite_open_uri: c_int = 0x0000_0040;

const sqlite = struct {
    extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        database: *?*anyopaque,
        flags: c_int,
        vfs: ?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_close_v2(database: ?*anyopaque) c_int;
    extern fn sqlite3_exec(
        database: ?*anyopaque,
        sql_text: [*:0]const u8,
        callback: ?*const anyopaque,
        argument: ?*anyopaque,
        error_message: ?*?[*:0]u8,
    ) c_int;
    extern fn sqlite3_prepare_v2(
        database: ?*anyopaque,
        sql_text: [*:0]const u8,
        byte_count: c_int,
        statement: *?*anyopaque,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(statement: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(statement: ?*anyopaque) c_int;
    extern fn sqlite3_column_int64(statement: ?*anyopaque, column: c_int) i64;
};

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
    var resources = controller_storage.bind();
    var controller = try ltx_replication.Controller.init(.{
        .dir = dir,
        .io = io,
        .database_name = database_name,
        .client = client,
        .config = controller_config,
        .startup = .require_empty,
    }, &resources);
    defer controller.finish();

    // The host application writes SQLite; the controller owns capture.
    try exec_sql(
        dir,
        io,
        database_name,
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
    );
    try exec_sql(dir, io, database_name, "INSERT INTO kv VALUES (1, 'one')");
    const snapshot = try expect_published(try controller.sync(1000));
    std.debug.print("sync 1: snapshot, {d} pages, position txid {d}\n", .{
        snapshot.page_count, snapshot.position.txid.value,
    });

    try exec_sql(dir, io, database_name, "INSERT INTO kv VALUES (2, 'two')");
    const incremental = try expect_published(try controller.sync(2000));
    std.debug.print("sync 2: incremental, {d} pages, position txid {d}\n", .{
        incremental.page_count, incremental.position.txid.value,
    });

    try exec_sql(dir, io, database_name, "INSERT INTO kv VALUES (3, 'three')");
    const restarted = try expect_published(try controller.sync(3000));
    std.debug.print("sync 3: post-checkpoint incremental, {d} pages, position txid {d}\n", .{
        restarted.page_count, restarted.position.txid.value,
    });

    // Restore planning and execution stay behind the same controller.
    var backend = try ltx_replica.RestoreBackend.init(
        dir,
        io,
        restored_database_name,
    );
    const restored = try controller.restore(
        ltx.TXID.init(0),
        backend.backend(),
    );
    std.debug.print("restored {d} files to txid {d}\n", .{
        restored.file_count,
        restored.position.txid.value,
    });

    controller.finish();
    try verify_restored_rows(dir, io, restored_database_name);
    std.debug.print("verified restored SQLite rows: one, two, three\n", .{});
}

fn expect_published(result: ltx_replication.SyncResult) !ltx_replication.SyncReport {
    return switch (result) {
        .published => |report| report,
        .unchanged => error.UnexpectedUnchanged,
    };
}

fn database_path(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    destination: []u8,
) ![*:0]const u8 {
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &absolute);
    const path = try std.fmt.bufPrint(
        destination,
        "{s}/{s}",
        .{ absolute[0..length], name },
    );
    if (path.len == destination.len) return error.PathTooLong;
    destination[path.len] = 0;
    return @ptrCast(destination.ptr);
}

fn exec_sql(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    statement: [*:0]const u8,
) !void {
    var path_storage: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try database_path(dir, io, name, &path_storage);
    var database: ?*anyopaque = null;
    const flags = sqlite_open_readwrite | sqlite_open_create | sqlite_open_uri;
    if (sqlite.sqlite3_open_v2(path, &database, flags, null) != sqlite_ok) {
        if (database != null) _ = sqlite.sqlite3_close_v2(database);
        return error.SQLiteOpenFailure;
    }
    defer _ = sqlite.sqlite3_close_v2(database);
    if (sqlite.sqlite3_exec(database, statement, null, null, null) != sqlite_ok) {
        return error.SQLiteExecFailure;
    }
}

fn immutable_database_uri(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    destination: []u8,
) ![*:0]const u8 {
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &absolute);
    const uri = try std.fmt.bufPrint(
        destination,
        "file:{s}/{s}?mode=ro&immutable=1",
        .{ absolute[0..length], name },
    );
    if (uri.len == destination.len) return error.PathTooLong;
    destination[uri.len] = 0;
    return @ptrCast(destination.ptr);
}

fn verify_restored_rows(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
) !void {
    var uri_storage: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const uri = try immutable_database_uri(dir, io, name, &uri_storage);
    var database: ?*anyopaque = null;
    if (sqlite.sqlite3_open_v2(
        uri,
        &database,
        sqlite_open_readonly | sqlite_open_uri,
        null,
    ) != sqlite_ok) {
        if (database != null) _ = sqlite.sqlite3_close_v2(database);
        return error.SQLiteOpenFailure;
    }
    defer _ = sqlite.sqlite3_close_v2(database);
    if (sqlite.sqlite3_exec(database, "PRAGMA query_only=ON", null, null, null) != sqlite_ok) {
        return error.SQLiteExecFailure;
    }
    var statement: ?*anyopaque = null;
    if (sqlite.sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM kv WHERE " ++
            "(k=1 AND v='one') OR (k=2 AND v='two') OR (k=3 AND v='three')",
        -1,
        &statement,
        null,
    ) != sqlite_ok) return error.SQLiteQueryFailure;
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_step(statement) != sqlite_row) {
        return error.SQLiteQueryFailure;
    }
    if (sqlite.sqlite3_column_int64(statement, 0) != 3) {
        return error.SQLiteVerificationFailure;
    }
}

const ControllerStorage = struct {
    wal_storage: [max_wal_bytes]u8 = undefined,
    map_slots: [max_pages]ltx_wal.PageSlot = undefined,
    map_pending: [max_pages]u32 = undefined,
    map_seen: [(max_pages + 7) / 8]u8 = undefined,
    map_entries: [max_pages]ltx_wal.PageMapEntry = undefined,
    empty_output: [0]u8 = .{},
    capture_page: [max_page_bytes]u8 = undefined,
    capture_compressed: [max_compressed_bytes]u8 = undefined,
    capture_compression: ltx.LZ4CompressionWorkspace = undefined,
    capture_index: [max_pages]ltx.PageIndexEntry = undefined,
    level_listings: [level_count * max_files_per_level]ltx.FileInfo = undefined,
    restore_plan: [max_restore_files]ltx.FileInfo = undefined,
    retention_plan: [max_files_per_level]ltx.FileInfo = undefined,
    restore_read_workspace: [read_workspace_bytes]u8 = undefined,
    restore_page: [max_page_bytes]u8 = undefined,
    restore_compressed: [max_compressed_bytes]u8 = undefined,
    restore_index: [max_pages]ltx.PageIndexEntry = undefined,
    compaction_job_inputs: [max_compaction_inputs]ltx_replica.CompactionJobInput = undefined,
    compaction_inputs: [max_compaction_inputs]ltx.CompactionInput = undefined,
    compaction_input_read_workspaces: [max_compaction_inputs][read_workspace_bytes]u8 = undefined,
    compaction_input_pages: [max_compaction_inputs][max_page_bytes]u8 = undefined,
    compaction_input_compressed: [max_compaction_inputs][max_compressed_bytes]u8 = undefined,
    compaction_input_indexes: [max_compaction_inputs][max_pages]ltx.PageIndexEntry = undefined,
    compaction_output_compressed: [max_compressed_bytes]u8 = undefined,
    compaction_output_compression: ltx.LZ4CompressionWorkspace = undefined,
    compaction_output_index: [max_pages]ltx.PageIndexEntry = undefined,

    fn bind(self: *ControllerStorage) ltx_replication.Resources {
        for (&self.compaction_job_inputs, 0..) |*input, index| {
            input.* = .{
                .read_workspace = &self.compaction_input_read_workspaces[index],
                .page_workspace = &self.compaction_input_pages[index],
                .compressed_workspace = &self.compaction_input_compressed[index],
                .index_workspace = &self.compaction_input_indexes[index],
            };
        }
        return .{
            .capture = .{
                .wal_storage = &self.wal_storage,
                .map_slots = &self.map_slots,
                .map_pending = &self.map_pending,
                .map_seen = &self.map_seen,
                .map_entries = &self.map_entries,
                // FileClient publishes through a transactional write session,
                // so capture does not need a whole-object output buffer.
                .output_storage = &self.empty_output,
                .page_workspace = &self.capture_page,
                .compressed_workspace = &self.capture_compressed,
                .compression_workspace = &self.capture_compression,
                .index_workspace = &self.capture_index,
            },
            .level_listings = &self.level_listings,
            .restore_plan = &self.restore_plan,
            .retention_plan = &self.retention_plan,
            .restore_read_workspace = &self.restore_read_workspace,
            .restore_page_workspace = &self.restore_page,
            .restore_compressed_workspace = &self.restore_compressed,
            .restore_index_workspace = &self.restore_index,
            .compaction_job_inputs = &self.compaction_job_inputs,
            .compaction_inputs = &self.compaction_inputs,
            .compaction_output_storage = &self.empty_output,
            .compaction_output_compressed_workspace = &self.compaction_output_compressed,
            .compaction_output_compression_workspace = &self.compaction_output_compression,
            .compaction_output_index_workspace = &self.compaction_output_index,
        };
    }
};

var controller_storage: ControllerStorage = .{};
