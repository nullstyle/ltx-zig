const std = @import("std");
const builtin = @import("builtin");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_wal = @import("ltx_wal");

const SQLite = opaque {};
const Statement = opaque {};

extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    database: *?*SQLite,
    flags: c_int,
    vfs_name: ?[*:0]const u8,
) c_int;
extern fn sqlite3_close(database: ?*SQLite) c_int;
extern fn sqlite3_prepare_v2(
    database: *SQLite,
    sql: [*:0]const u8,
    sql_bytes: c_int,
    statement: *?*Statement,
    tail: ?*?[*:0]const u8,
) c_int;
extern fn sqlite3_step(statement: *Statement) c_int;
extern fn sqlite3_finalize(statement: ?*Statement) c_int;
extern fn sqlite3_column_text(statement: *Statement, column: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(statement: *Statement, column: c_int) c_int;
extern fn sqlite3_db_readonly(database: *SQLite, schema_name: [*:0]const u8) c_int;
extern fn sqlite3_errmsg(database: *SQLite) [*:0]const u8;

const sqlite_ok: c_int = 0;
const sqlite_row: c_int = 100;
const sqlite_done: c_int = 101;
const sqlite_open_readonly: c_int = 0x0000_0001;
const sqlite_open_uri: c_int = 0x0000_0040;
const sqlite_open_fullmutex: c_int = 0x0001_0000;

const required_litestream_version = "0.5.16\n";
const child_output_limit_bytes: usize = 64 * 1024;
const diagnostic_output_limit_bytes: usize = 4096;
const sqlite_message_limit_bytes: usize = 1024;
const child_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(30),
} };
const max_ltx_bytes: u64 = 66 * 1024;
const max_database_bytes: u64 = 64 * 1024;
const copy_buffer_bytes: usize = 4096;
const real_database_bytes: u64 = 5 * 4096;
const max_page_database_bytes: u64 = 64 * 1024;
const tx4_sha256 = "27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a";
const tx6_sha256 = "ee705e74c9788b64f5dc63b9c3dc028ae05aae34f240bad1362d9436c65150e0";
const max_page_sha256 = "1f2d41b212c74e121e69ba1f71cdf254ce7b478dfb675bca590a1bb9c952354f";
const checked_restore_error = "validate trailer: post-apply checksum not allowed";

const compacted_name = "0000000000000001-0000000000000004.ltx";
const tx5_name = "0000000000000005-0000000000000005.ltx";
const tx6_name = "0000000000000006-0000000000000006.ltx";
const grow_name = "0000000000000001-0000000000000003.ltx";
const max_page_name = "0000000000000001-0000000000000002.ltx";
const tx4_value = "0000000000000004";

const BoundedPath = struct {
    bytes: [std.fs.max_path_bytes + 1]u8 = undefined,
    length: usize = 0,

    fn resolve(io: std.Io, path: []const u8) !BoundedPath {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidPath;
        var result: BoundedPath = .{};
        result.length = try std.Io.Dir.cwd().realPathFile(
            io,
            path,
            result.bytes[0..std.fs.max_path_bytes],
        );
        if (result.length >= result.bytes.len) return error.NameTooLong;
        result.bytes[result.length] = 0;
        return result;
    }

    fn join(directory: *const BoundedPath, name: []const u8) !BoundedPath {
        var result: BoundedPath = .{};
        const separator_length: usize = @intFromBool(
            directory.length == 0 or directory.bytes[directory.length - 1] != '/',
        );
        const name_offset = std.math.add(
            usize,
            directory.length,
            separator_length,
        ) catch return error.NameTooLong;
        const end = std.math.add(usize, name_offset, name.len) catch
            return error.NameTooLong;
        if (end >= result.bytes.len) return error.NameTooLong;
        @memcpy(result.bytes[0..directory.length], directory.slice());
        if (separator_length == 1) result.bytes[directory.length] = '/';
        @memcpy(result.bytes[name_offset..end], name);
        result.bytes[end] = 0;
        result.length = end;
        return result;
    }

    fn slice(self: *const BoundedPath) []const u8 {
        return self.bytes[0..self.length];
    }
};

const TemporaryDirectory = struct {
    const prefix = "ltx-zig-litestream-";
    const random_bytes_count = 12;
    const encoded_bytes_count = std.base64.url_safe.Encoder.calcSize(random_bytes_count);
    const name_bytes = prefix.len + encoded_bytes_count;

    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: [name_bytes]u8,

    fn create(io: std.Io) !TemporaryDirectory {
        var parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
        errdefer parent.close(io);
        var attempt_count: u8 = 0;
        while (attempt_count < 8) : (attempt_count += 1) {
            var random_bytes: [random_bytes_count]u8 = undefined;
            io.random(&random_bytes);
            var name: [name_bytes]u8 = undefined;
            @memcpy(name[0..prefix.len], prefix);
            _ = std.base64.url_safe.Encoder.encode(name[prefix.len..], &random_bytes);
            parent.createDir(io, &name, @enumFromInt(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer parent.deleteTree(io, &name) catch {};
            const dir = try parent.openDir(io, &name, .{});
            return .{ .parent = parent, .dir = dir, .name = name };
        }
        return error.TemporaryDirectoryCollision;
    }

    fn cleanup(self: *TemporaryDirectory, io: std.Io) void {
        self.dir.close(io);
        self.parent.deleteTree(io, &self.name) catch {};
        self.parent.close(io);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 7) return error.InvalidArguments;
    try require_bounded_argument(args[1]);
    const compacted = try BoundedPath.resolve(init.io, args[2]);
    const tx5 = try BoundedPath.resolve(init.io, args[3]);
    const tx6 = try BoundedPath.resolve(init.io, args[4]);
    const grow = try BoundedPath.resolve(init.io, args[5]);
    const max_page = try BoundedPath.resolve(init.io, args[6]);
    try require_litestream_version(init, args[1]);

    var temporary = try TemporaryDirectory.create(init.io);
    defer temporary.cleanup(init.io);
    try populate_replica(init.io, temporary.dir, &compacted, &tx5, &tx6);
    try populate_synthetic_replicas(init.io, temporary.dir, &grow, &max_page);

    var root = try directory_path(init.io, temporary.dir);
    const replica = try BoundedPath.join(&root, "replica");
    const grow_replica = try BoundedPath.join(&root, "grow-replica");
    const max_page_replica = try BoundedPath.join(&root, "max-page-replica");
    const tx4_database = try BoundedPath.join(&root, "tx4.sqlite");
    const tx6_database = try BoundedPath.join(&root, "tx6.sqlite");
    const grow_database = try BoundedPath.join(&root, "grow.sqlite");
    const max_page_database = try BoundedPath.join(&root, "max-page.sqlite");
    var replica_url_buffer: ["file://".len + std.fs.max_path_bytes]u8 = undefined;
    var grow_url_buffer: ["file://".len + std.fs.max_path_bytes]u8 = undefined;
    var max_page_url_buffer: ["file://".len + std.fs.max_path_bytes]u8 = undefined;
    const replica_url = try std.fmt.bufPrint(&replica_url_buffer, "file://{s}", .{replica.slice()});
    const grow_url = try std.fmt.bufPrint(&grow_url_buffer, "file://{s}", .{grow_replica.slice()});
    const max_page_url = try std.fmt.bufPrint(&max_page_url_buffer, "file://{s}", .{max_page_replica.slice()});

    try restore(init, args[1], replica_url, &tx4_database, tx4_value, "restore TX4");
    try expect_file_sha256(init.io, &tx4_database, real_database_bytes, tx4_sha256);
    try restore(init, args[1], replica_url, &tx6_database, null, "restore TX6");
    try expect_file_sha256(init.io, &tx6_database, real_database_bytes, tx6_sha256);
    try expect_final_database(&tx6_database);
    try expect_checked_restore_rejection(init, args[1], grow_url, &grow_database);
    try restore(init, args[1], max_page_url, &max_page_database, null, "restore max-page chain");
    try expect_file_sha256(init.io, &max_page_database, max_page_database_bytes, max_page_sha256);

    try run_captured_replica_scenario(init, args[1], temporary.dir);

    var stdout_buffer: [192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        "Litestream 0.5.16 restored real and max-page compactions; checked-input rejection reproduced\n",
    );
    try stdout_writer.interface.flush();
}

/// Builds a real database through the capture session (snapshot, an
/// incremental, a session-initiated passive checkpoint, and a post-checkpoint
/// incremental), then requires Litestream to restore the captured tree to
/// the exact checkpointed image of the live database.
fn run_captured_replica_scenario(
    init: std.process.Init,
    executable: []const u8,
    dir: std.Io.Dir,
) !void {
    var store = try ltx_object.FileClient.init(dir, init.io, "captured-replica");
    var session = try ltx_capture.Session.init(
        dir,
        init.io,
        "captured.db",
        captured_codec_limits,
        captured_wal_limits,
        store.client(),
    );
    defer session.finish();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one'), (2, 'two')");
    _ = try session.sync(&capture_storage, 1000);
    try session.exec("INSERT INTO kv VALUES (3, 'three')");
    _ = try session.sync(&capture_storage, 2000);
    try session.checkpoint_passive(2500);
    try session.exec("INSERT INTO kv VALUES (4, 'four')");
    _ = try session.sync(&capture_storage, 3000);
    if (session.position.txid.value != 3) return error.CapturedPositionMismatch;

    // Freeze the live image at the captured position; the restored file
    // must be byte-identical to it.
    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    var root = try directory_path(init.io, dir);
    const live_database = try BoundedPath.join(&root, "captured.db");

    var restore_url_buffer: ["file://".len + std.fs.max_path_bytes]u8 = undefined;
    const replica = try BoundedPath.join(&root, "captured-replica");
    const restore_url = try std.fmt.bufPrint(
        &restore_url_buffer,
        "file://{s}",
        .{replica.slice()},
    );
    const restored_database = try BoundedPath.join(&root, "captured-restore.sqlite");
    try restore(init, executable, restore_url, &restored_database, null, "restore captured tree");
    try expect_files_identical(init.io, dir, &live_database, &restored_database);
    try expect_captured_rows(init.io, dir, &restored_database);
}

fn expect_files_identical(
    io: std.Io,
    dir: std.Io.Dir,
    live: *const BoundedPath,
    restored: *const BoundedPath,
) !void {
    var live_hash: [32]u8 = undefined;
    try hash_file(io, dir, live, &live_hash);
    var restored_hash: [32]u8 = undefined;
    try hash_file(io, dir, restored, &restored_hash);
    if (!std.mem.eql(u8, &live_hash, &restored_hash)) {
        return error.CapturedImageMismatch;
    }
}

fn hash_file(
    io: std.Io,
    dir: std.Io.Dir,
    path: *const BoundedPath,
    out: *[32]u8,
) !void {
    var file = try dir.openFile(io, path.slice(), .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.CapturedImageTooLarge;
    var buffer: [1 << 16]u8 = undefined;
    if (size > buffer.len) return error.CapturedImageTooLarge;
    const read = try file.readPositionalAll(io, buffer[0..size], 0);
    if (read != size) return error.CapturedImageTooLarge;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buffer[0..size]);
    hasher.final(out);
}

/// Opens the restored capture read-only and requires the four captured rows.
fn expect_captured_rows(io: std.Io, dir: std.Io.Dir, path: *const BoundedPath) !void {
    _ = io;
    _ = dir;
    var uri_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(
        &uri_buffer,
        "file:{s}?mode=ro&immutable=1",
        .{path.slice()},
    );
    var database: ?*SQLite = null;
    if (sqlite3_open_v2(uri.ptr, &database, sqlite_open_readonly | sqlite_open_uri, null) != sqlite_ok) {
        return error.CapturedRestoreOpenFailure;
    }
    defer _ = sqlite3_close(database);
    var statement: ?*Statement = null;
    if (sqlite3_prepare_v2(database.?, "SELECT COUNT(*), MAX(k) FROM kv", -1, &statement, null) != sqlite_ok) {
        return error.CapturedRestoreQueryFailure;
    }
    defer _ = sqlite3_finalize(statement);
    if (sqlite3_step(statement.?) != sqlite_row) return error.CapturedRestoreQueryFailure;
    const count = sqlite3_column_text(statement.?, 0) orelse return error.CapturedRestoreQueryFailure;
    const max = sqlite3_column_text(statement.?, 1) orelse return error.CapturedRestoreQueryFailure;
    if (!std.mem.eql(u8, std.mem.span(count), "4") or
        !std.mem.eql(u8, std.mem.span(max), "4"))
    {
        return error.CapturedRowsMismatch;
    }
}

const captured_codec_limits = ltx.Limits{
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

const captured_wal_limits = ltx_wal.Limits{
    .max_page_size = 4096,
    .max_pages = 64,
    .max_frames = 256,
};

var capture_wal_storage: [1 << 20]u8 = undefined;
var capture_map_slots: [64]ltx_wal.PageSlot = @splat(.{});
var capture_map_pending: [64]u32 = @splat(0);
var capture_map_seen: [8]u8 = @splat(0);
var capture_map_entries: [64]ltx_wal.PageMapEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0 });
var capture_output: [1 << 20]u8 = undefined;
var capture_page: [4096]u8 = undefined;
var capture_compressed: [4200]u8 = undefined;
var capture_compression: ltx.LZ4CompressionWorkspace = undefined;
var capture_index: [64]ltx.PageIndexEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 });
var capture_storage: ltx_capture.Workspaces = .{
    .wal_storage = &capture_wal_storage,
    .map_slots = &capture_map_slots,
    .map_pending = &capture_map_pending,
    .map_seen = &capture_map_seen,
    .map_entries = &capture_map_entries,
    .output_storage = &capture_output,
    .page_workspace = &capture_page,
    .compressed_workspace = &capture_compressed,
    .compression_workspace = &capture_compression,
    .index_workspace = &capture_index,
};

fn require_bounded_argument(argument: []const u8) !void {
    if (argument.len == 0 or argument.len > std.fs.max_path_bytes) return error.InvalidPath;
}

fn directory_path(io: std.Io, dir: std.Io.Dir) !BoundedPath {
    var result: BoundedPath = .{};
    result.length = try dir.realPath(io, result.bytes[0..std.fs.max_path_bytes]);
    if (result.length >= result.bytes.len) return error.NameTooLong;
    result.bytes[result.length] = 0;
    return result;
}

fn populate_replica(
    io: std.Io,
    root: std.Io.Dir,
    compacted: *const BoundedPath,
    tx5: *const BoundedPath,
    tx6: *const BoundedPath,
) !void {
    var level_one = try root.createDirPathOpen(io, "replica/ltx/1", .{});
    defer level_one.close(io);
    var level_zero = try root.createDirPathOpen(io, "replica/ltx/0", .{});
    defer level_zero.close(io);
    try copy_ltx(io, compacted, level_one, compacted_name);
    try copy_ltx(io, tx5, level_zero, tx5_name);
    try copy_ltx(io, tx6, level_zero, tx6_name);
}

fn populate_synthetic_replicas(
    io: std.Io,
    root: std.Io.Dir,
    grow: *const BoundedPath,
    max_page: *const BoundedPath,
) !void {
    var grow_level_one = try root.createDirPathOpen(io, "grow-replica/ltx/1", .{});
    defer grow_level_one.close(io);
    try copy_ltx(io, grow, grow_level_one, grow_name);

    var max_page_level_one = try root.createDirPathOpen(io, "max-page-replica/ltx/1", .{});
    defer max_page_level_one.close(io);
    try copy_ltx(io, max_page, max_page_level_one, max_page_name);
}

fn copy_ltx(
    io: std.Io,
    source_path: *const BoundedPath,
    destination_dir: std.Io.Dir,
    destination_name: []const u8,
) !void {
    var source = try std.Io.Dir.cwd().openFile(io, source_path.slice(), .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer source.close(io);
    const source_stat = try source.stat(io);
    if (source_stat.kind != .file or source_stat.size == 0 or source_stat.size > max_ltx_bytes) {
        return error.InvalidLTXFile;
    }
    var destination = try destination_dir.createFile(io, destination_name, .{
        .truncate = false,
        .exclusive = true,
        .resolve_beneath = true,
    });
    defer destination.close(io);

    var buffer: [copy_buffer_bytes]u8 = undefined;
    var offset_bytes: u64 = 0;
    var chunk_count: u32 = 0;
    const max_chunks: u32 = @intCast((max_ltx_bytes + buffer.len - 1) / buffer.len);
    while (offset_bytes < source_stat.size and chunk_count < max_chunks) : (chunk_count += 1) {
        const remaining_bytes = source_stat.size - offset_bytes;
        const length: usize = @intCast(@min(remaining_bytes, buffer.len));
        const read = try source.readPositionalAll(io, buffer[0..length], offset_bytes);
        if (read != length) return error.LTXFileChanged;
        try destination.writePositionalAll(io, buffer[0..length], offset_bytes);
        offset_bytes += length;
    }
    if (offset_bytes != source_stat.size) return error.InvalidLTXFile;
    const final_stat = try source.stat(io);
    if (final_stat.kind != .file or final_stat.size != source_stat.size) {
        return error.LTXFileChanged;
    }
}

fn require_litestream_version(init: std.process.Init, executable: []const u8) !void {
    const result = try run_child(init, &.{ executable, "version" });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try require_success("litestream version", &result);
    if (result.stderr.len != 0 or
        !std.mem.eql(u8, result.stdout, required_litestream_version))
    {
        print_child_result("litestream version mismatch", &result);
        return error.LitestreamVersionMismatch;
    }
}

fn restore(
    init: std.process.Init,
    executable: []const u8,
    replica_url: []const u8,
    output: *const BoundedPath,
    txid: ?[]const u8,
    operation: []const u8,
) !void {
    const result = if (txid) |value|
        try run_child(init, &.{ executable, "restore", "-o", output.slice(), "-txid", value, replica_url })
    else
        try run_child(init, &.{ executable, "restore", "-o", output.slice(), replica_url });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try require_success(operation, &result);
}

fn expect_checked_restore_rejection(
    init: std.process.Init,
    executable: []const u8,
    replica_url: []const u8,
    output: *const BoundedPath,
) !void {
    const result = try run_child(init, &.{ executable, "restore", "-o", output.slice(), replica_url });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const expected_exit = switch (result.term) {
        .exited => |code| code == 1,
        else => false,
    };
    if (!expected_exit or result.stdout.len != 0 or
        std.mem.indexOf(u8, result.stderr, "Error: decode database:") == null or
        std.mem.indexOf(u8, result.stderr, checked_restore_error) == null)
    {
        print_child_result("restore checked grow rejection mismatch", &result);
        return error.CheckedRestoreRejectionMismatch;
    }
}

fn run_child(init: std.process.Init, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .stdout_limit = .limited(child_output_limit_bytes),
        .stderr_limit = .limited(child_output_limit_bytes),
        .timeout = child_timeout.toDeadline(init.io),
    });
}

fn require_success(operation: []const u8, result: *const std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    print_child_result(operation, result);
    return error.ChildProcessFailed;
}

fn print_child_result(operation: []const u8, result: *const std.process.RunResult) void {
    const stdout = result.stdout[0..@min(result.stdout.len, diagnostic_output_limit_bytes)];
    const stderr = result.stderr[0..@min(result.stderr.len, diagnostic_output_limit_bytes)];
    std.debug.print(
        "{s}: term={any}, stdout {d} bytes: {s}\nstderr {d} bytes: {s}\n",
        .{ operation, result.term, result.stdout.len, stdout, result.stderr.len, stderr },
    );
}

fn expect_file_sha256(
    io: std.Io,
    path: *const BoundedPath,
    expected_size_bytes: u64,
    expected_hex: []const u8,
) !void {
    if (expected_size_bytes > max_database_bytes or
        expected_hex.len != std.crypto.hash.sha2.Sha256.digest_length * 2)
    {
        return error.InvalidExpectedDatabaseImage;
    }
    var file = try std.Io.Dir.cwd().openFile(io, path.slice(), .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size_bytes) return error.InvalidDatabaseImage;

    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [copy_buffer_bytes]u8 = undefined;
    var offset_bytes: u64 = 0;
    var chunk_count: u8 = 0;
    const max_chunk_count: u8 = @intCast(
        (expected_size_bytes + buffer.len - 1) / buffer.len,
    );
    while (offset_bytes < stat.size and chunk_count < max_chunk_count) : (chunk_count += 1) {
        const length: usize = @intCast(@min(stat.size - offset_bytes, buffer.len));
        const read = try file.readPositionalAll(io, buffer[0..length], offset_bytes);
        if (read != length) return error.DatabaseImageChanged;
        digest.update(buffer[0..length]);
        offset_bytes += length;
    }
    if (offset_bytes != stat.size) return error.InvalidDatabaseImage;
    const final_stat = try file.stat(io);
    if (final_stat.kind != .file or final_stat.size != stat.size) {
        return error.DatabaseImageChanged;
    }
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    digest.final(&actual);
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
        std.debug.print(
            "database hash mismatch for {s}: got {s}, want {s}\n",
            .{ path.slice(), actual_hex, expected_hex },
        );
        return error.DatabaseHashMismatch;
    }
}

const ExpectedRow = struct { key: []const u8, value: []const u8 };

const expected_rows = [_]ExpectedRow{
    .{ .key = "a", .value = "upd5" },
    .{ .key = "b", .value = "2" },
    .{ .key = "c", .value = "3" },
    .{ .key = "k1", .value = "v1" },
    .{ .key = "k2", .value = "v2" },
    .{ .key = "k3", .value = "v3" },
    .{ .key = "k4", .value = "v4" },
    .{ .key = "k5", .value = "v5" },
};

fn expect_final_database(path: *const BoundedPath) !void {
    const query = "?mode=ro&immutable=1";
    var uri_buffer: ["file:".len + std.fs.max_path_bytes + query.len + 1]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(&uri_buffer, "file:{s}{s}", .{ path.slice(), query });
    var database_optional: ?*SQLite = null;
    const open_result = sqlite3_open_v2(
        uri.ptr,
        &database_optional,
        sqlite_open_readonly | sqlite_open_uri | sqlite_open_fullmutex,
        null,
    );
    if (open_result != sqlite_ok or database_optional == null) {
        if (database_optional) |database| {
            print_sqlite_failure("open immutable database", database, open_result);
            _ = sqlite3_close(database);
        } else {
            std.debug.print("SQLite open immutable database failed ({d})\n", .{open_result});
        }
        return error.SQLiteOpenFailure;
    }
    const database = database_optional.?;
    errdefer _ = sqlite3_close(database);
    const readonly_result = sqlite3_db_readonly(database, "main");
    if (readonly_result != 1) {
        print_sqlite_failure("verify immutable database is read-only", database, readonly_result);
        return error.SQLiteNotReadOnly;
    }
    try expect_integrity(database);
    try expect_rows(database);
    const close_result = sqlite3_close(database);
    if (close_result != sqlite_ok) {
        print_sqlite_failure("close immutable database", database, close_result);
        return error.SQLiteCloseFailure;
    }
}

fn expect_integrity(database: *SQLite) !void {
    var statement_optional: ?*Statement = try prepare(database, "PRAGMA integrity_check");
    defer {
        if (statement_optional) |statement| _ = sqlite3_finalize(statement);
    }
    const statement = statement_optional.?;
    var result = sqlite3_step(statement);
    if (result != sqlite_row) {
        print_sqlite_failure("step integrity result", database, result);
        return error.SQLiteIntegrityFailure;
    }
    try expect_column(statement, 0, "ok", "integrity result", error.SQLiteIntegrityFailure);
    result = sqlite3_step(statement);
    if (result != sqlite_done) {
        print_sqlite_failure("finish integrity result", database, result);
        return error.SQLiteIntegrityFailure;
    }
    result = sqlite3_finalize(statement);
    statement_optional = null;
    if (result != sqlite_ok) {
        print_sqlite_failure("finalize integrity statement", database, result);
        return error.SQLiteFinalizeFailure;
    }
}

fn expect_rows(database: *SQLite) !void {
    var statement_optional: ?*Statement = try prepare(database, "SELECT k, v FROM kv ORDER BY k");
    defer {
        if (statement_optional) |statement| _ = sqlite3_finalize(statement);
    }
    const statement = statement_optional.?;
    for (expected_rows) |expected| {
        const result = sqlite3_step(statement);
        if (result != sqlite_row) {
            print_sqlite_failure("step expected row", database, result);
            return error.SQLiteRowsMismatch;
        }
        try expect_column(statement, 0, expected.key, "row key", error.SQLiteRowsMismatch);
        try expect_column(statement, 1, expected.value, "row value", error.SQLiteRowsMismatch);
    }
    var result = sqlite3_step(statement);
    if (result != sqlite_done) {
        print_sqlite_failure("finish expected rows", database, result);
        return error.SQLiteRowsMismatch;
    }
    result = sqlite3_finalize(statement);
    statement_optional = null;
    if (result != sqlite_ok) {
        print_sqlite_failure("finalize row statement", database, result);
        return error.SQLiteFinalizeFailure;
    }
}

fn prepare(database: *SQLite, sql: [*:0]const u8) !*Statement {
    var statement: ?*Statement = null;
    const result = sqlite3_prepare_v2(database, sql, -1, &statement, null);
    if (result != sqlite_ok) {
        print_sqlite_failure("prepare statement", database, result);
        if (statement) |value| _ = sqlite3_finalize(value);
        return error.SQLitePrepareFailure;
    }
    return statement orelse error.SQLitePrepareFailure;
}

fn expect_column(
    statement: *Statement,
    column: c_int,
    expected: []const u8,
    label: []const u8,
    mismatch_error: error{ SQLiteIntegrityFailure, SQLiteRowsMismatch },
) !void {
    const text = sqlite3_column_text(statement, column) orelse {
        std.debug.print("SQLite {s} is null; want {s}\n", .{ label, expected });
        return error.SQLiteNullText;
    };
    const length = sqlite3_column_bytes(statement, column);
    if (length < 0) {
        std.debug.print("SQLite {s} has invalid length {d}\n", .{ label, length });
        return error.SQLiteInvalidText;
    }
    const actual = text[0..@intCast(length)];
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print(
            "SQLite {s} mismatch: got {s}, want {s}\n",
            .{ label, actual, expected },
        );
        return mismatch_error;
    }
}

fn print_sqlite_failure(operation: []const u8, database: *SQLite, result: c_int) void {
    const raw_message = sqlite3_errmsg(database);
    var length: usize = 0;
    while (length < sqlite_message_limit_bytes and raw_message[length] != 0) : (length += 1) {}
    std.debug.print(
        "SQLite {s} failed ({d}): {s}\n",
        .{ operation, result, raw_message[0..length] },
    );
}
