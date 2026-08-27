//! Scale qualification for the replication path.
//!
//! Builds a real multi-hundred-megabyte SQLite database through
//! `ltx_capture` with periodic syncs and byte-threshold checkpoints,
//! compacts the chain, restores it through the replica engine, and requires
//! the restored file to be byte-identical to the checkpointed live
//! database. Every phase is timed so the numbers recorded in
//! `docs/replication.md` stay measured rather than estimated.
//!
//! Opt-in tool (`zig build scale-check -Dscale-mb=N`); not a CI gate. It
//! links the host system SQLite for the executable only.

const std = @import("std");
const scale_options = @import("scale_options");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_wal = @import("ltx_wal");

const page_size = 4096;
const row_blob_bytes = 1024;
const rows_per_batch = 1024;
const max_pages = 512 * 1024;

const sqlite = struct {
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

var sql_buffer: [192]u8 = undefined;

fn sql(comptime format: []const u8, args: anytype) ![*:0]const u8 {
    const text = try std.fmt.bufPrintZ(&sql_buffer, format, args);
    return text.ptr;
}

fn codec_limits() ltx.Limits {
    return .{
        .max_input_bytes = 1 << 30,
        .max_output_bytes = 1 << 30,
        .max_pages = max_pages,
        .max_page_size = page_size,
        .max_compressed_page_size = page_size + 1024,
        .max_page_index_bytes = 64 << 20,
        .max_page_index_entries = max_pages,
        .max_varint_bytes = 10,
        .max_transaction_span = max_pages,
    };
}

fn report(
    io: std.Io,
    writer: anytype,
    name: []const u8,
    bytes: u64,
    started_ns: i128,
) !void {
    const finished = std.Io.Clock.awake.now(io).nanoseconds;
    const elapsed_ns: u128 = @intCast(finished - started_ns);
    const ms = elapsed_ns / std.time.ns_per_ms;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const throughput = if (seconds > 0) mib / seconds else 0;
    try writer.print("{s:<22} {d:>9} ms {d:>9.1} MiB {d:>9.1} MiB/s\n", .{
        name, ms, mib, throughput,
    });
    try writer.flush();
}

const Workspaces = struct {
    wal_storage: []u8,
    slots: []ltx_wal.PageSlot,
    pending: []u32,
    seen: []u8,
    entries: []ltx_wal.PageMapEntry,
    output: []u8,
    page: []u8,
    compressed: []u8,
    compression: *ltx.LZ4CompressionWorkspace,
    index: []ltx.PageIndexEntry,

    fn deinit(self: *Workspaces, allocator: std.mem.Allocator) void {
        allocator.free(self.wal_storage);
        allocator.free(self.slots);
        allocator.free(self.pending);
        allocator.free(self.seen);
        allocator.free(self.entries);
        allocator.free(self.output);
        allocator.free(self.page);
        allocator.free(self.compressed);
        allocator.destroy(self.compression);
        allocator.free(self.index);
    }

    fn view(self: *Workspaces) ltx_capture.Workspaces {
        return .{
            .wal_storage = self.wal_storage,
            .map_slots = self.slots,
            .map_pending = self.pending,
            .map_seen = self.seen,
            .map_entries = self.entries,
            .output_storage = self.output,
            .page_workspace = self.page,
            .compressed_workspace = self.compressed,
            .compression_workspace = self.compression,
            .index_workspace = self.index,
        };
    }
};

fn make_workspaces(allocator: std.mem.Allocator, wal_bytes: usize) !Workspaces {
    const compression = try allocator.create(ltx.LZ4CompressionWorkspace);
    return .{
        .wal_storage = try allocator.alloc(u8, wal_bytes),
        .slots = try allocator.alloc(ltx_wal.PageSlot, max_pages),
        .pending = try allocator.alloc(u32, max_pages),
        .seen = try allocator.alloc(u8, (max_pages + 7) / 8),
        .entries = try allocator.alloc(ltx_wal.PageMapEntry, max_pages),
        .output = try allocator.alloc(u8, 1 << 28),
        .page = try allocator.alloc(u8, page_size),
        .compressed = try allocator.alloc(u8, page_size + 1024),
        .compression = compression,
        .index = try allocator.alloc(ltx.PageIndexEntry, max_pages),
    };
}

fn hash_file(io: std.Io, dir: std.Io.Dir, name: []const u8, out: *[32]u8) !void {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [1 << 16]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const read = file.readPositionalAll(io, &buffer, offset) catch break;
        if (read == 0) break;
        hasher.update(buffer[0..read]);
        offset += read;
    }
    hasher.final(out);
}

fn query_count(uri: [:0]const u8) !u64 {
    var database: ?*anyopaque = null;
    if (sqlite.sqlite3_open_v2(uri.ptr, &database, sqlite.open_readonly | sqlite.open_uri, null) != sqlite.ok) {
        return error.OpenFailure;
    }
    defer _ = sqlite.sqlite3_close_v2(database);
    var statement: ?*anyopaque = null;
    if (sqlite.sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM kv", -1, &statement, null) != sqlite.ok) {
        return error.QueryFailure;
    }
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_step(statement) != sqlite.row) return error.QueryFailure;
    return @intCast(sqlite.sqlite3_column_int64(statement, 0));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const limits = codec_limits();
    const wal_limits_value = ltx_wal.Limits{
        .max_page_size = page_size,
        .max_pages = max_pages,
        .max_frames = max_pages,
    };

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var target_mb: u64 = scale_options.default_mb;
    if (args.len > 1) {
        if (args.len != 2 or !std.mem.startsWith(u8, args[1], "--mb=")) {
            return error.InvalidArguments;
        }
        target_mb = std.fmt.parseInt(u64, args[1]["--mb=".len..], 10) catch
            return error.InvalidArguments;
    }
    const target_bytes = target_mb * 1024 * 1024;

    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.Writer.init(.stdout(), io, &output_buffer);
    const writer = &output_file.interface;
    try writer.print("scale qualification: {d} MiB target, {d}-byte pages\n\n", .{ target_mb, page_size });
    try writer.flush();

    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/scale-check") catch {};
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/scale-check") catch
        return error.WorkDirectoryFailure;
    var dir = try std.Io.Dir.cwd().openDir(io, ".zig-cache/scale-check", .{
        .access_sub_paths = true,
    });
    defer dir.close(io);

    var workspaces = try make_workspaces(allocator, 256 << 20);
    defer workspaces.deinit(allocator);

    var store = try ltx_object.FileClient.init(dir, io, "replica");
    const client = store.client();

    // ---- capture ------------------------------------------------------
    var session = try ltx_capture.Session.init(
        dir,
        io,
        "app.db",
        limits,
        wal_limits_value,
        client,
    );
    defer session.finish();
    session.checkpoint_threshold_bytes = 32 << 20;

    var capture_ws = workspaces.view();
    var started = std.Io.Clock.awake.now(io).nanoseconds;
    try session.exec(try sql(
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, seq INTEGER, blob BLOB)",
        .{},
    ));
    var rows: u64 = 0;
    var syncs: u64 = 0;
    var statement_buffer: [176]u8 = undefined;
    while (rows * row_blob_bytes < target_bytes) {
        const statement = try std.fmt.bufPrintZ(
            &statement_buffer,
            "INSERT INTO kv VALUES ({d}, {d}, zeroblob({d}))",
            .{ rows, rows, row_blob_bytes },
        );
        try session.exec(statement.ptr);
        rows += 1;
        if (rows % rows_per_batch == 0) {
            _ = try session.sync(&capture_ws, @intCast(1000 + syncs));
            syncs += 1;
        }
    }

    _ = session.sync(&capture_ws, @intCast(1000 + syncs)) catch |err| switch (err) {
        error.CaptureUnchanged => 0,
        else => return err,
    };
    const database_stat = try dir.statFile(io, "app.db", .{});
    try report(io, writer, "capture+sync", database_stat.size, started);

    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    const live_stat = try dir.statFile(io, "app.db", .{});

    // ---- compaction ---------------------------------------------------
    started = std.Io.Clock.awake.now(io).nanoseconds;
    var level_buffers: [ltx.snapshot_level + 1][4096]ltx.FileInfo = undefined;
    var level_lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    for (0..level_lists.len) |level| {
        level_lists[level] = try client.list(
            @intCast(level),
            ltx.TXID.init(0),
            &level_buffers[level],
        );
    }
    if (level_lists[0].len < 2) return error.ChainTooShort;
    const sizes = try allocator.alloc(u64, level_lists[0].len);
    defer allocator.free(sizes);
    for (level_lists[0], 0..) |info, index| {
        const bytes = try client.open(
            0,
            .{ .min_txid = info.min_txid, .max_txid = info.max_txid },
            workspaces.output,
        );
        sizes[index] = bytes.len;
    }
    const compaction_plan = try ltx_replica.plan_compaction(
        level_lists[0],
        level_lists[1],
        @intCast(level_lists[0].len),
        8 << 30,
        sizes,
    );
    if (compaction_plan.input_count < 2) return error.ChainTooShort;

    const inputs = try allocator.alloc(ltx_replica.CompactionJobInput, compaction_plan.input_count);
    defer allocator.free(inputs);
    const compaction_state = try allocator.alloc(ltx.CompactionInput, compaction_plan.input_count);
    defer allocator.free(compaction_state);
    const readers = try allocator.alloc(ltx.SliceReader, compaction_plan.input_count);
    defer allocator.free(readers);
    for (inputs) |*input| {
        input.* = .{
            .storage = try allocator.alloc(u8, 1 << 28),
            .page_workspace = try allocator.alloc(u8, page_size),
            .compressed_workspace = try allocator.alloc(u8, page_size + 1024),
            .index_workspace = try allocator.alloc(ltx.PageIndexEntry, max_pages),
        };
    }
    defer for (inputs) |input| {
        allocator.free(input.storage);
        allocator.free(input.page_workspace);
        allocator.free(input.compressed_workspace);
        allocator.free(input.index_workspace);
    };
    const output_compressed = try allocator.alloc(u8, page_size + 1024);
    defer allocator.free(output_compressed);
    const output_compression = try allocator.create(ltx.LZ4CompressionWorkspace);
    defer allocator.destroy(output_compression);
    const output_index = try allocator.alloc(ltx.PageIndexEntry, max_pages);
    defer allocator.free(output_index);
    var compactor = ltx_replica.CompactionJob{
        .client = client,
        .codec_limits = limits,
        .compaction_limits = .{
            .max_inputs = @intCast(inputs.len),
            .max_total_pages = max_pages * 4,
        },
        .inputs = inputs,
        .compaction_inputs = compaction_state,
        .readers = readers,
        .output_storage = workspaces.output,
        .output_compressed_workspace = output_compressed,
        .output_compression_workspace = output_compression,
        .output_index_workspace = output_index,
    };
    _ = try compactor.run(level_lists[0][0..compaction_plan.input_count], 1);
    // Compaction throughput is reported against the logical volume of the
    // chain, not the compressed wire bytes it reads.
    try report(io, writer, "compact L0->L1", database_stat.size, started);

    // ---- restore ------------------------------------------------------
    started = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..level_lists.len) |level| {
        level_lists[level] = try client.list(
            @intCast(level),
            ltx.TXID.init(0),
            &level_buffers[level],
        );
    }
    var plan_storage: [4096]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(&level_lists, ltx.TXID.init(0), &plan_storage);
    const backend = try ltx_replica.RestoreBackend.init(dir, io, "restored.db");
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = limits,
        .apply_limits = .{
            .max_database_pages = max_pages,
            .max_database_bytes = 1 << 30,
        },
        .backend = backend,
        .storage = workspaces.output,
        .page_workspace = workspaces.page,
        .compressed_workspace = workspaces.compressed,
        .index_workspace = workspaces.index,
    };
    const position = try job.run(plan);
    if (position.txid.value != session.position.txid.value) {
        return error.PositionMismatch;
    }
    try report(io, writer, "restore", live_stat.size, started);

    // ---- verify -------------------------------------------------------
    var live_hash: [32]u8 = undefined;
    try hash_file(io, dir, "app.db", &live_hash);
    var restored_hash: [32]u8 = undefined;
    try hash_file(io, dir, "restored.db", &restored_hash);
    if (!std.mem.eql(u8, &live_hash, &restored_hash)) {
        return error.ImageMismatch;
    }
    var uri_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(
        &uri_buffer,
        "file:.zig-cache/scale-check/restored.db?mode=ro&immutable=1",
        .{},
    );
    const count = try query_count(uri);
    if (count != rows) return error.RowCountMismatch;
    try writer.print(
        "\nverified: {d} rows, {d} L0 files compacted to L1, {d}-file restore plan, images byte-identical\n",
        .{ rows, compaction_plan.input_count, plan.len },
    );
    try writer.flush();
}
