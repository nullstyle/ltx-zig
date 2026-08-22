const std = @import("std");
const builtin = @import("builtin");

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
const max_ltx_bytes: u64 = 64 * 1024;
const copy_buffer_bytes: usize = 4096;
const database_bytes: u64 = 5 * 4096;
const database_chunk_count: u8 = @intCast(
    (database_bytes + copy_buffer_bytes - 1) / copy_buffer_bytes,
);
const tx4_sha256 = "27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a";
const tx6_sha256 = "ee705e74c9788b64f5dc63b9c3dc028ae05aae34f240bad1362d9436c65150e0";

const compacted_name = "0000000000000001-0000000000000004.ltx";
const tx5_name = "0000000000000005-0000000000000005.ltx";
const tx6_name = "0000000000000006-0000000000000006.ltx";
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
    if (args.len != 5) return error.InvalidArguments;
    try require_bounded_argument(args[1]);
    const compacted = try BoundedPath.resolve(init.io, args[2]);
    const tx5 = try BoundedPath.resolve(init.io, args[3]);
    const tx6 = try BoundedPath.resolve(init.io, args[4]);
    try require_litestream_version(init, args[1]);

    var temporary = try TemporaryDirectory.create(init.io);
    defer temporary.cleanup(init.io);
    try populate_replica(init.io, temporary.dir, &compacted, &tx5, &tx6);

    var root = try directory_path(init.io, temporary.dir);
    const replica = try BoundedPath.join(&root, "replica");
    const tx4_database = try BoundedPath.join(&root, "tx4.sqlite");
    const tx6_database = try BoundedPath.join(&root, "tx6.sqlite");
    var replica_url_buffer: ["file://".len + std.fs.max_path_bytes]u8 = undefined;
    const replica_url = try std.fmt.bufPrint(&replica_url_buffer, "file://{s}", .{replica.slice()});

    try restore(init, args[1], replica_url, &tx4_database, tx4_value);
    try expect_file_sha256(init.io, &tx4_database, tx4_sha256);
    try restore(init, args[1], replica_url, &tx6_database, null);
    try expect_file_sha256(init.io, &tx6_database, tx6_sha256);
    try expect_final_database(&tx6_database);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        "Litestream 0.5.16 restored the Zig TX1-TX4 compaction through legacy TX6\n",
    );
    try stdout_writer.interface.flush();
}

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
) !void {
    const result = if (txid) |value|
        try run_child(init, &.{ executable, "restore", "-o", output.slice(), "-txid", value, replica_url })
    else
        try run_child(init, &.{ executable, "restore", "-o", output.slice(), replica_url });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try require_success(if (txid == null) "restore TX6" else "restore TX4", &result);
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

fn expect_file_sha256(io: std.Io, path: *const BoundedPath, expected_hex: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path.slice(), .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != database_bytes) return error.InvalidDatabaseImage;

    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [copy_buffer_bytes]u8 = undefined;
    var offset_bytes: u64 = 0;
    var chunk_count: u8 = 0;
    while (offset_bytes < stat.size and chunk_count < database_chunk_count) : (chunk_count += 1) {
        const length: usize = @intCast(@min(stat.size - offset_bytes, buffer.len));
        const read = try file.readPositionalAll(io, buffer[0..length], offset_bytes);
        if (read != length) return error.DatabaseImageChanged;
        digest.update(buffer[0..length]);
        offset_bytes += length;
    }
    if (offset_bytes != stat.size) return error.InvalidDatabaseImage;
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
