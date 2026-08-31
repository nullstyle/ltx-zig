//! Capture crash drill: kill a writer process between reported durable
//! batches, then require that (1) the object tree restores to exactly the
//! last reported batch and (2) a fresh session continues capture from that
//! restored image without history repair. This is the "activation is
//! failover" property of the producer path.

const std = @import("std");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_wal = @import("ltx_wal");
const crash_options = @import("crash_options");

const page_size = 4096;
const kill_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(20),
} };

const codec_limits = ltx.Limits{
    .max_input_bytes = 1 << 20,
    .max_output_bytes = 1 << 20,
    .max_pages = 64,
    .max_page_size = page_size,
    .max_compressed_page_size = page_size + 1024,
    .max_page_index_bytes = 1 << 16,
    .max_page_index_entries = 64,
    .max_varint_bytes = 10,
    .max_transaction_span = 64,
};

const wal_limits = ltx_wal.Limits{
    .max_page_size = page_size,
    .max_pages = 64,
    .max_frames = 256,
};

var wal_storage: [1 << 20]u8 = undefined;
var slots: [64]ltx_wal.PageSlot = @splat(.{});
var pending: [64]u32 = @splat(0);
var seen: [8]u8 = @splat(0);
var entries: [64]ltx_wal.PageMapEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0 });
var output: [1 << 20]u8 = undefined;
var restore_read_workspace: [64 * 1024]u8 = undefined;
var page: [page_size]u8 = undefined;
var compressed: [page_size + 1024]u8 = undefined;
var compression: ltx.LZ4CompressionWorkspace = undefined;
var index: [64]ltx.PageIndexEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 });
var workspaces: ltx_capture.Workspaces = .{
    .wal_storage = &wal_storage,
    .map_slots = &slots,
    .map_pending = &pending,
    .map_seen = &seen,
    .map_entries = &entries,
    .output_storage = &output,
    .page_workspace = &page,
    .compressed_workspace = &compressed,
    .compression_workspace = &compression,
    .index_workspace = &index,
};

const RestoreKit = struct {
    backend: ltx_replica.RestoreBackend,
    job: ltx_replica.RestoreJob,
};

fn spawn_child(root: []const u8) !std.process.Child {
    return std.process.spawn(std.testing.io, .{
        .argv = &.{
            crash_options.child_path,
            root,
            "app.db",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
}

/// Reads child lines until one full "batch N rows R" arrives.
fn read_report(child: *std.process.Child) !struct { batch: u64, rows: u64 } {
    var line: [64]u8 = undefined;
    var filled: usize = 0;
    const deadline = kill_timeout.toDeadline(std.testing.io);
    while (filled < line.len) {
        const result = std.testing.io.operateTimeout(.{ .file_read_streaming = .{
            .file = child.stdout.?,
            .data = &.{line[filled..]},
        } }, deadline) catch |err| switch (err) {
            error.Timeout => return error.ChildReportTimeout,
            else => return err,
        };
        const count = result.file_read_streaming catch |err| switch (err) {
            error.EndOfStream => return error.ChildExited,
            else => return err,
        };
        if (count == 0) return error.ChildExited;
        if (std.mem.indexOfScalar(u8, line[0 .. filled + count], '\n')) |newline| {
            const text = line[0..newline];
            var parts = std.mem.tokenizeScalar(u8, text, ' ');
            const marker = parts.next() orelse return error.BadReport;
            if (!std.mem.eql(u8, marker, "batch")) return error.BadReport;
            const batch = parts.next() orelse return error.BadReport;
            const rows_marker = parts.next() orelse return error.BadReport;
            if (!std.mem.eql(u8, rows_marker, "rows")) return error.BadReport;
            const rows = parts.next() orelse return error.BadReport;
            return .{
                .batch = std.fmt.parseInt(u64, batch, 10) catch return error.BadReport,
                .rows = std.fmt.parseInt(u64, rows, 10) catch return error.BadReport,
            };
        }
        filled += count;
    }
    return error.ReportTooLong;
}

fn list_levels(
    client: ltx_object.Client,
    lists: *[ltx.snapshot_level + 1][]const ltx.FileInfo,
    buffers: *[ltx.snapshot_level + 1][64]ltx.FileInfo,
) !void {
    for (0..lists.len) |level| {
        lists[level] = try client.list(
            @intCast(level),
            ltx.TXID.init(0),
            &buffers[level],
        );
    }
}

fn restore_latest(dir: std.Io.Dir, database_name: []const u8) !ltx.Position {
    var store = try ltx_object.FileClient.init(dir, std.testing.io, "replica");
    const client = store.client();
    var buffers: [ltx.snapshot_level + 1][64]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_levels(client, &lists, &buffers);
    var plan_storage: [64]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    var backend = try ltx_replica.RestoreBackend.init(dir, std.testing.io, database_name);
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 64, .max_database_bytes = 1 << 20 },
        .backend = backend.backend(),
        .read_workspace = &restore_read_workspace,
        .page_workspace = &page,
        .compressed_workspace = &compressed,
        .index_workspace = &index,
    };
    return job.run(plan);
}

fn expect_rows(database_name: []const u8, expected: u64) !void {
    var uri_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(
        &uri_buffer,
        "file:.zig-cache/capture-crash/{s}?mode=ro&immutable=1",
        .{database_name},
    );
    var database: ?*anyopaque = null;
    if (c.sqlite3_open_v2(uri.ptr, &database, c.open_readonly | c.open_uri, null) != c.ok) {
        return error.OpenFailure;
    }
    defer _ = c.sqlite3_close_v2(database);
    var statement: ?*anyopaque = null;
    if (c.sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM kv", -1, &statement, null) != c.ok) {
        return error.QueryFailure;
    }
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.row) return error.QueryFailure;
    try std.testing.expectEqual(expected, @as(u64, @intCast(c.sqlite3_column_int64(statement, 0))));
}

const c = struct {
    const ok: c_int = 0;
    const row: c_int = 100;
    const open_readonly: c_int = 0x0000_0001;
    const open_uri: c_int = 0x0000_0040;
    extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        db: *?*anyopaque,
        flags: c_int,
        vfs_name: ?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_close_v2(db: ?*anyopaque) c_int;
    extern fn sqlite3_prepare_v2(
        db: ?*anyopaque,
        sql_ptr: [*:0]const u8,
        byte_count: c_int,
        statement: *?*anyopaque,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(statement: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(statement: ?*anyopaque) c_int;
    extern fn sqlite3_column_int64(statement: ?*anyopaque, column: c_int) i64;
};

test "kill between batches; activation restores and continues" {
    std.Io.Dir.cwd().deleteTree(std.testing.io, ".zig-cache/capture-crash") catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/capture-crash") catch
        return error.WorkDirectoryFailure;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".zig-cache/capture-crash", .{
        .access_sub_paths = true,
    });
    defer dir.close(std.testing.io);

    var child = try spawn_child(".zig-cache/capture-crash");
    var last_rows: u64 = 0;
    var reports: u64 = 0;
    while (reports < 3) : (reports += 1) {
        const report = try read_report(&child);
        last_rows = report.rows;
    }
    // Kill between durable batches: the tree reflects exactly last_rows.
    const pid = child.id orelse return error.ChildAlreadyExited;
    std.posix.kill(pid, .KILL) catch return error.KillFailed;
    _ = child.wait(std.testing.io) catch {};

    const position = try restore_latest(dir, "recovered.db");
    try std.testing.expect(position.txid.value >= 3);
    try expect_rows("recovered.db", last_rows);

    // Failover continues: seed the recovered position first — without
    // seeding, the new session would restart TXIDs at one and overwrite
    // the original snapshot object. Attach capture,
    // sync, and restore again — no history repair, exact continuation.
    var store = try ltx_object.FileClient.init(dir, std.testing.io, "replica");
    var session = try ltx_capture.Session.init(
        dir,
        std.testing.io,
        "recovered.db",
        codec_limits,
        wal_limits,
        store.client(),
    );
    defer session.finish();
    try session.seed_position(position);
    try session.exec("INSERT INTO kv VALUES (999, 'after-failover')");
    const pages = try session.sync(&workspaces, 9000);
    try std.testing.expect(pages > 0);
    try std.testing.expectEqual(position.txid.value + 1, session.position.txid.value);

    const final = try restore_latest(dir, "final.db");
    try std.testing.expectEqual(session.position.txid.value, final.txid.value);
    try expect_rows("final.db", last_rows + 1);
}
