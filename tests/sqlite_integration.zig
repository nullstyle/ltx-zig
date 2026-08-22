const std = @import("std");
const ltx = @import("ltx");
const sqlite_store = @import("ltx_sqlite");

const SQLite = opaque {};
const Statement = opaque {};

extern fn sqlite3_libversion_number() c_int;
extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    database: *?*SQLite,
    flags: c_int,
    vfs_name: ?[*:0]const u8,
) c_int;
extern fn sqlite3_close(database: ?*SQLite) c_int;
extern fn sqlite3_errmsg(database: *SQLite) [*:0]const u8;
extern fn sqlite3_busy_timeout(database: *SQLite, duration_ms: c_int) c_int;
extern fn sqlite3_prepare_v2(
    database: *SQLite,
    sql: [*:0]const u8,
    sql_bytes: c_int,
    statement: *?*Statement,
    tail: ?*?[*:0]const u8,
) c_int;
extern fn sqlite3_step(statement: *Statement) c_int;
extern fn sqlite3_finalize(statement: ?*Statement) c_int;
extern fn sqlite3_column_int64(statement: *Statement, column: c_int) i64;
extern fn sqlite3_column_text(statement: *Statement, column: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(statement: *Statement, column: c_int) c_int;
extern fn sqlite3_db_readonly(database: *SQLite, schema_name: [*:0]const u8) c_int;
extern fn sqlite3_db_filename(
    database: *SQLite,
    schema_name: [*:0]const u8,
) ?[*:0]const u8;
extern fn sqlite3_file_control(
    database: *SQLite,
    schema_name: [*:0]const u8,
    operation: c_int,
    argument: *anyopaque,
) c_int;
extern fn sqlite3_wal_checkpoint_v2(
    database: *SQLite,
    schema_name: [*:0]const u8,
    mode: c_int,
    log_frames: *c_int,
    checkpointed_frames: *c_int,
) c_int;

const sqlite_ok: c_int = 0;
const sqlite_readonly: c_int = 8;
const sqlite_row: c_int = 100;
const sqlite_done: c_int = 101;
const sqlite_open_readonly: c_int = 0x0000_0001;
const sqlite_open_readwrite: c_int = 0x0000_0002;
const sqlite_open_create: c_int = 0x0000_0004;
const sqlite_open_uri: c_int = 0x0000_0040;
const sqlite_open_fullmutex: c_int = 0x0001_0000;
const sqlite_fcntl_persist_wal: c_int = 10;
const sqlite_checkpoint_truncate: c_int = 3;

const database_name = "seed.sqlite";
const database_wal_name = database_name ++ "-wal";
const database_shm_name = database_name ++ "-shm";
const database_journal_name = database_name ++ "-journal";
const adversarial_directory_name = "db ?mode=rw&immutable=0#x%2F\xc3\xa9";
const encoded_directory_name = "db%20%3Fmode%3Drw%26immutable%3D0%23x%252F%C3%A9";
const page_size: u32 = 1024;
const max_pages: u32 = 32;
const max_database_bytes = max_pages * page_size;
const max_compressed_bytes: u32 = 1100;
const max_ltx_bytes: u32 = 64 * 1024;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_ltx_bytes,
    .max_output_bytes = max_ltx_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 1024,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const DatabasePath = struct {
    bytes: [std.Io.Dir.max_path_bytes]u8 = undefined,
    length: usize = 0,

    fn init(dir: std.Io.Dir, name: []const u8) !DatabasePath {
        var result: DatabasePath = .{};
        const directory_length = try dir.realPath(
            std.testing.io,
            &result.bytes,
        );
        if (directory_length >= result.bytes.len) return error.NameTooLong;
        const separator_length: usize = @intFromBool(
            directory_length == 0 or result.bytes[directory_length - 1] != '/',
        );
        const name_offset = std.math.add(
            usize,
            directory_length,
            separator_length,
        ) catch return error.NameTooLong;
        const end = std.math.add(usize, name_offset, name.len) catch
            return error.NameTooLong;
        if (end >= result.bytes.len) return error.NameTooLong;
        if (separator_length == 1) result.bytes[directory_length] = '/';
        @memcpy(result.bytes[name_offset..end], name);
        result.bytes[end] = 0;
        result.length = end;
        return result;
    }

    fn sentinel(self: *const DatabasePath) [:0]const u8 {
        return self.bytes[0..self.length :0];
    }
};

const ManagedLifecycle = struct {
    database: ?*SQLite = null,
    held_statement: ?*Statement = null,
    generation_access: ?sqlite_store.GenerationAccess = null,
    admission_closed: bool = false,
    quiesce_count: u32 = 0,
    release_count: u32 = 0,

    fn lifecycle(self: *ManagedLifecycle) sqlite_store.Lifecycle {
        return .{
            .context = self,
            .quiesce_fn = quiesce,
            .release_fn = release,
        };
    }

    fn quiesce(context: *anyopaque) error{QuiesceFailure}!void {
        const self: *ManagedLifecycle = @ptrCast(@alignCast(context));
        if (self.admission_closed) return error.QuiesceFailure;
        self.admission_closed = true;
        errdefer self.admission_closed = false;
        if (self.held_statement) |statement| {
            self.held_statement = null;
            if (sqlite3_finalize(statement) != sqlite_ok) return error.QuiesceFailure;
        }
        if (self.database) |database| {
            if (sqlite3_close(database) != sqlite_ok) return error.QuiesceFailure;
            self.database = null;
        }
        if (self.generation_access) |*access| {
            access.release() catch return error.QuiesceFailure;
            self.generation_access = null;
        }
        self.quiesce_count += 1;
    }

    fn release(context: *anyopaque) void {
        const self: *ManagedLifecycle = @ptrCast(@alignCast(context));
        std.debug.assert(self.admission_closed);
        self.admission_closed = false;
        self.release_count += 1;
    }

    fn open_generation(
        self: *ManagedLifecycle,
        store: *sqlite_store.Store,
        storage: *sqlite_store.GenerationAccessStorage,
        workspace: *sqlite_store.GenerationAccessWorkspace,
    ) !sqlite_store.Current {
        if (self.admission_closed or
            self.database != null or
            self.generation_access != null)
        {
            return error.AdmissionClosed;
        }
        var access = (try store.acquire_generation(storage, workspace)) orelse
            return error.ExpectedGeneration;
        errdefer access.release() catch {};
        const current = try access.current();
        const spec = try access.sqlite_open_spec();
        const required_flags: u32 = @intCast(spec.required_flags);
        try std.testing.expectEqual(
            @as(u32, sqlite_open_readonly | sqlite_open_uri),
            required_flags,
        );
        try std.testing.expectEqualStrings("PRAGMA query_only=ON", spec.query_only_sql);
        const database = try open_database(
            spec.uri,
            @as(c_int, @intCast(required_flags)) | sqlite_open_fullmutex,
        );
        errdefer _ = sqlite3_close(database);
        try execute(database, spec.query_only_sql);
        try expect_integer_query(database, "PRAGMA query_only", 1);
        try std.testing.expectEqual(@as(c_int, 1), sqlite3_db_readonly(database, "main"));
        self.database = database;
        self.generation_access = access;
        return current;
    }

    fn hold_read_transaction(self: *ManagedLifecycle) !void {
        if (self.admission_closed) return error.AdmissionClosed;
        const database = self.database orelse return error.InvalidState;
        self.held_statement = try prepare(database, "SELECT value FROM items ORDER BY id");
        errdefer {
            _ = sqlite3_finalize(self.held_statement);
            self.held_statement = null;
        }
        try expect_result(database, sqlite3_step(self.held_statement.?), sqlite_row);
    }

    fn close(self: *ManagedLifecycle) !void {
        if (self.held_statement) |statement| {
            self.held_statement = null;
            try std.testing.expectEqual(sqlite_ok, sqlite3_finalize(statement));
        }
        if (self.database) |database| {
            try std.testing.expectEqual(sqlite_ok, sqlite3_close(database));
            self.database = null;
        }
        if (self.generation_access) |*access| {
            try access.release();
            self.generation_access = null;
        }
    }
};

test "real SQLite WAL lifecycle and checksummed generation apply" {
    try std.testing.expect(sqlite3_libversion_number() >= 3_022_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(
        std.testing.io,
        adversarial_directory_name,
        .default_dir,
    );
    var database_dir = try temporary.dir.openDir(
        std.testing.io,
        adversarial_directory_name,
        .{},
    );
    defer database_dir.close(std.testing.io);
    const seed_path = try DatabasePath.init(database_dir, database_name);

    try create_and_drain_wal_database(database_dir, seed_path.sentinel());
    try std.testing.expect(!try path_exists(database_dir, database_wal_name));
    try std.testing.expect(!try path_exists(database_dir, database_shm_name));
    try std.testing.expect(!try path_exists(database_dir, database_journal_name));
    try expect_wal_header(database_dir, database_name);

    var encoded_ltx: [max_ltx_bytes]u8 = undefined;
    const encoded_length = try encode_seed_snapshot(database_dir, &encoded_ltx);
    var lifecycle: ManagedLifecycle = .{};
    var copy_workspace: [4096]u8 = undefined;
    var store = try sqlite_store.Store.init(
        std.testing.io,
        database_dir,
        &copy_workspace,
        lifecycle.lifecycle(),
        .{},
    );
    const verified = try apply_snapshot(
        &store,
        encoded_ltx[0..encoded_length],
        .contiguous,
    );
    var access_storage: sqlite_store.GenerationAccessStorage = .{};
    var access_workspace: sqlite_store.GenerationAccessWorkspace = .{};
    const current = try lifecycle.open_generation(
        &store,
        &access_storage,
        &access_workspace,
    );
    try std.testing.expectEqual(verified.post_apply_position(), current.position);
    try expect_wal_header(database_dir, current.database_name());
    try expect_no_slot_sidecars(database_dir, current.slot);
    try expect_open_generation(&lifecycle, database_dir, current);
    try recover_held_generation(&store, &lifecycle, database_dir, current);
    try exercise_competing_publication(
        &store,
        &lifecycle,
        &access_storage,
        &access_workspace,
        database_dir,
        current,
        encoded_ltx[0..encoded_length],
    );
}

fn expect_open_generation(
    lifecycle: *ManagedLifecycle,
    database_dir: std.Io.Dir,
    current: sqlite_store.Current,
) !void {
    const access = if (lifecycle.generation_access) |*value|
        value
    else
        return error.ExpectedGeneration;
    const spec = try access.sqlite_open_spec();
    try std.testing.expect(std.mem.indexOf(u8, spec.uri, encoded_directory_name) != null);
    try std.testing.expect(std.mem.endsWith(u8, spec.uri, "?mode=ro&immutable=1"));
    const active_path = try DatabasePath.init(database_dir, current.database_name());
    const database = lifecycle.database orelse return error.ExpectedDatabase;
    const sqlite_path = sqlite3_db_filename(database, "main") orelse
        return error.ExpectedDatabaseFilename;
    try std.testing.expectEqualStrings(active_path.sentinel(), std.mem.span(sqlite_path));
    try expect_integer_query(database, "SELECT count(*) FROM items", 3);
    try expect_integer_query(database, "SELECT sum(id) FROM items", 6);
    try expect_text_query(database, "PRAGMA integrity_check", "ok");
    try expect_read_only_statement(database, "INSERT INTO items VALUES(4,'forbidden')");
    try expect_integer_query(database, "SELECT count(*) FROM items", 3);
}

fn recover_held_generation(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    database_dir: std.Io.Dir,
    current: sqlite_store.Current,
) !void {
    try lifecycle.hold_read_transaction();
    try expect_no_slot_sidecars(database_dir, current.slot);
    const recovered = (try store.recover()).?;
    try std.testing.expectEqual(current, recovered);
    try std.testing.expectEqual(@as(u32, 2), lifecycle.quiesce_count);
    try std.testing.expectEqual(lifecycle.quiesce_count, lifecycle.release_count);
    try std.testing.expect(lifecycle.database == null);
    try std.testing.expect(lifecycle.held_statement == null);
    try std.testing.expect(lifecycle.generation_access == null);
    try expect_no_slot_sidecars(database_dir, current.slot);
}

fn exercise_competing_publication(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    access_storage: *sqlite_store.GenerationAccessStorage,
    access_workspace: *sqlite_store.GenerationAccessWorkspace,
    database_dir: std.Io.Dir,
    current: sqlite_store.Current,
    encoded_ltx: []const u8,
) !void {
    const reopened = try lifecycle.open_generation(store, access_storage, access_workspace);
    try std.testing.expectEqual(current, reopened);
    try expect_no_slot_sidecars(database_dir, current.slot);
    const database = lifecycle.database orelse return error.ExpectedDatabase;
    try expect_text_query(
        database,
        "SELECT group_concat(value, ',') FROM (SELECT value FROM items ORDER BY id)",
        "alpha,beta,gamma",
    );
    try lifecycle.hold_read_transaction();

    var competing_lifecycle: ManagedLifecycle = .{};
    var competing_copy_workspace: [4096]u8 = undefined;
    var competing_store = try sqlite_store.Store.init(
        std.testing.io,
        database_dir,
        &competing_copy_workspace,
        competing_lifecycle.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(current, (try competing_store.current()).?);
    try std.testing.expectError(
        error.ApplyBeginFailure,
        apply_snapshot(&competing_store, encoded_ltx, .replace_snapshot),
    );
    try std.testing.expectEqual(.store_busy, competing_store.last_failure());
    try expect_integer_query(database, "SELECT count(*) FROM items", 3);
    try expect_no_slot_sidecars(database_dir, current.slot);

    try lifecycle.close();
    try expect_no_slot_sidecars(database_dir, current.slot);
    _ = try apply_snapshot(&competing_store, encoded_ltx, .replace_snapshot);
    const replaced = (try competing_store.current()).?;
    try std.testing.expectEqual(current.generation + 1, replaced.generation);
    try std.testing.expect(current.slot != replaced.slot);
    const final_access = try lifecycle.open_generation(store, access_storage, access_workspace);
    try std.testing.expectEqual(replaced, final_access);
    try expect_integer_query(lifecycle.database.?, "SELECT count(*) FROM items", 3);
    try lifecycle.close();
    try expect_no_slot_sidecars(database_dir, replaced.slot);
}

fn create_and_drain_wal_database(dir: std.Io.Dir, path: [:0]const u8) !void {
    const writer = try open_database(
        path,
        sqlite_open_readwrite | sqlite_open_create | sqlite_open_fullmutex,
    );
    errdefer _ = sqlite3_close(writer);
    try execute(writer, "PRAGMA page_size=1024");
    try execute(writer, "PRAGMA journal_mode=WAL");
    try execute(writer, "PRAGMA synchronous=FULL");
    try execute(writer, "PRAGMA wal_autocheckpoint=0");
    try execute(writer, "CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT NOT NULL)");
    try execute(writer, "INSERT INTO items VALUES(1,'alpha'),(2,'beta'),(3,'gamma')");
    var persist_wal: c_int = 1;
    try expect_result(
        writer,
        sqlite3_file_control(writer, "main", sqlite_fcntl_persist_wal, &persist_wal),
        sqlite_ok,
    );

    var reader: ?*SQLite = try open_database(path, sqlite_open_readonly | sqlite_open_fullmutex);
    var held_reader: ?*Statement = null;
    errdefer {
        if (held_reader) |statement| _ = sqlite3_finalize(statement);
        if (reader) |database| _ = sqlite3_close(database);
    }
    held_reader = try prepare(reader.?, "SELECT value FROM items ORDER BY id");
    try expect_result(reader.?, sqlite3_step(held_reader.?), sqlite_row);
    try std.testing.expect(try path_exists(dir, database_wal_name));
    try std.testing.expect(try path_exists(dir, database_shm_name));
    const finalize_result = sqlite3_finalize(held_reader);
    held_reader = null;
    try std.testing.expectEqual(sqlite_ok, finalize_result);
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(reader));
    reader = null;

    persist_wal = 0;
    try expect_result(
        writer,
        sqlite3_file_control(writer, "main", sqlite_fcntl_persist_wal, &persist_wal),
        sqlite_ok,
    );
    var log_frames: c_int = -1;
    var checkpointed_frames: c_int = -1;
    try expect_result(writer, sqlite3_wal_checkpoint_v2(
        writer,
        "main",
        sqlite_checkpoint_truncate,
        &log_frames,
        &checkpointed_frames,
    ), sqlite_ok);
    try std.testing.expectEqual(@as(c_int, 0), log_frames);
    try std.testing.expectEqual(@as(c_int, 0), checkpointed_frames);
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(writer));
}

fn encode_seed_snapshot(dir: std.Io.Dir, output: []u8) !usize {
    var database = try dir.openFile(std.testing.io, database_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer database.close(std.testing.io);
    const stat = try database.stat(std.testing.io);
    if (stat.size == 0 or stat.size % page_size != 0) return error.InvalidDatabaseSize;
    const page_count_u64 = stat.size / page_size;
    if (page_count_u64 > max_pages) return error.DatabaseTooLarge;
    const page_count: u32 = @intCast(page_count_u64);

    var sink = ltx.SliceWriter.init(output);
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed_workspace,
        &compression_workspace,
        &index_workspace,
    );
    try encoder.write_header(snapshot_header(page_count));
    var rolling = ltx.rolling_checksum_initial();
    var page: [page_size]u8 = undefined;
    var page_index: u32 = 0;
    while (page_index < page_count) : (page_index += 1) {
        const page_number = page_index + 1;
        const read = try database.readPositionalAll(
            std.testing.io,
            &page,
            @as(u64, page_index) * page_size,
        );
        if (read != page.len) return error.ShortDatabaseRead;
        try encoder.write_page(page_number, &page);
        rolling = try ltx.rolling_checksum_add(
            rolling,
            try ltx.checksum_page(page_number, &page),
        );
    }
    _ = try encoder.finish(rolling);
    return sink.written().len;
}

fn apply_snapshot(
    store: *sqlite_store.Store,
    encoded: []const u8,
    mode: ltx.ApplyMode,
) !ltx.VerifiedLTX {
    var source = ltx.SliceReader.init(encoded);
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        codec_limits,
        .{
            .max_database_pages = max_pages,
            .max_database_bytes = max_database_bytes,
        },
        mode,
        source.reader(),
        store.backend(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    return applier.apply();
}

fn snapshot_header(page_count: u32) ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size,
        .commit = page_count,
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

fn open_database(path: [:0]const u8, flags: c_int) !*SQLite {
    var database: ?*SQLite = null;
    const result = sqlite3_open_v2(path.ptr, &database, flags, null);
    if (result != sqlite_ok or database == null) {
        if (database) |opened| {
            std.debug.print("sqlite open failed ({d}): {s}\n", .{ result, sqlite3_errmsg(opened) });
            _ = sqlite3_close(opened);
        }
        return error.SQLiteOpenFailure;
    }
    errdefer _ = sqlite3_close(database);
    try expect_result(database.?, sqlite3_busy_timeout(database.?, 1000), sqlite_ok);
    return database.?;
}

fn prepare(database: *SQLite, sql: [*:0]const u8) !*Statement {
    var statement: ?*Statement = null;
    const result = sqlite3_prepare_v2(database, sql, -1, &statement, null);
    try expect_result(database, result, sqlite_ok);
    return statement orelse error.SQLitePrepareFailure;
}

fn execute(database: *SQLite, sql: [*:0]const u8) !void {
    const statement = try prepare(database, sql);
    defer _ = sqlite3_finalize(statement);
    var step_count: u32 = 0;
    while (step_count < 1024) : (step_count += 1) {
        switch (sqlite3_step(statement)) {
            sqlite_row => continue,
            sqlite_done => return,
            else => |result| return sqlite_error(database, result),
        }
    }
    return error.SQLiteStepLimitExceeded;
}

fn expect_integer_query(database: *SQLite, sql: [*:0]const u8, expected: i64) !void {
    const statement = try prepare(database, sql);
    defer _ = sqlite3_finalize(statement);
    try expect_result(database, sqlite3_step(statement), sqlite_row);
    try std.testing.expectEqual(expected, sqlite3_column_int64(statement, 0));
    try expect_result(database, sqlite3_step(statement), sqlite_done);
}

fn expect_text_query(database: *SQLite, sql: [*:0]const u8, expected: []const u8) !void {
    const statement = try prepare(database, sql);
    defer _ = sqlite3_finalize(statement);
    try expect_result(database, sqlite3_step(statement), sqlite_row);
    const text = sqlite3_column_text(statement, 0) orelse return error.SQLiteNullText;
    const length = sqlite3_column_bytes(statement, 0);
    if (length < 0) return error.SQLiteInvalidText;
    try std.testing.expectEqualStrings(expected, text[0..@intCast(length)]);
    try expect_result(database, sqlite3_step(statement), sqlite_done);
}

fn expect_read_only_statement(database: *SQLite, sql: [*:0]const u8) !void {
    const statement = try prepare(database, sql);
    defer _ = sqlite3_finalize(statement);
    try std.testing.expectEqual(sqlite_readonly, sqlite3_step(statement));
}

fn expect_wal_header(dir: std.Io.Dir, name: []const u8) !void {
    var database = try dir.openFile(std.testing.io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer database.close(std.testing.io);
    var journal_versions: [2]u8 = undefined;
    const read = try database.readPositionalAll(std.testing.io, &journal_versions, 18);
    try std.testing.expectEqual(journal_versions.len, read);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2 }, &journal_versions);
}

fn expect_no_slot_sidecars(dir: std.Io.Dir, slot: sqlite_store.Slot) !void {
    const name = slot.database_name();
    const suffixes = [_][]const u8{ "-wal", "-shm", "-journal" };
    var sidecar_name: [sqlite_store.database_a_name.len + "-journal".len]u8 = undefined;
    @memcpy(sidecar_name[0..name.len], name);
    for (suffixes) |suffix| {
        @memcpy(sidecar_name[name.len .. name.len + suffix.len], suffix);
        try std.testing.expect(!try path_exists(dir, sidecar_name[0 .. name.len + suffix.len]));
    }
}

fn expect_result(database: *SQLite, actual: c_int, expected: c_int) !void {
    if (actual != expected) return sqlite_error(database, actual);
}

fn sqlite_error(database: *SQLite, result: c_int) error{SQLiteFailure} {
    std.debug.print("sqlite failure ({d}): {s}\n", .{ result, sqlite3_errmsg(database) });
    return error.SQLiteFailure;
}

fn path_exists(dir: std.Io.Dir, name: []const u8) !bool {
    _ = dir.statFile(std.testing.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
