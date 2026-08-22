const std = @import("std");
const ltx = @import("ltx");
const sqlite_store = @import("ltx_sqlite");
const crash_options = @import("crash_options");
const crash_protocol = @import("sqlite_crash_protocol.zig");

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
const sqlite_busy: c_int = 5;
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
const max_pages: u32 = 64;
const max_database_bytes = max_pages * page_size;
const max_compressed_bytes: u32 = 1100;
const max_ltx_bytes: u32 = 128 * 1024;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_ltx_bytes,
    .max_output_bytes = max_ltx_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 2048,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const DatabaseImage = struct {
    bytes: [max_database_bytes]u8 = undefined,
    length_bytes: u32 = 0,
    page_count: u32 = 0,
    checksum: ltx.Checksum = .init(0),
};

const EncodedTransition = struct {
    length_bytes: usize,
    verified: ltx.VerifiedLTX,
};

const RealCrashInputs = struct {
    snapshot: []const u8,
    incremental: []const u8,
    reuse: []const u8,
    image_a: *const DatabaseImage,
    image_b: *const DatabaseImage,
    image_c: *const DatabaseImage,
};

const ChainState = enum {
    a,
    b,
    c,
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
        try self.close_sqlite();
        try self.release_generation();
    }

    fn close_sqlite(self: *ManagedLifecycle) !void {
        if (self.held_statement) |statement| {
            self.held_statement = null;
            try std.testing.expectEqual(sqlite_ok, sqlite3_finalize(statement));
        }
        if (self.database) |database| {
            try std.testing.expectEqual(sqlite_ok, sqlite3_close(database));
            self.database = null;
        }
    }

    fn release_generation(self: *ManagedLifecycle) !void {
        if (self.held_statement != null or self.database != null) return error.InvalidState;
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
    const verified = try apply_encoded(
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

test "real SQLite checksummed incrementals grow and shrink generations" {
    try std.testing.expect(sqlite3_libversion_number() >= 3_022_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const seed_path = try DatabasePath.init(temporary.dir, database_name);
    try create_and_drain_wal_database(temporary.dir, seed_path.sentinel());
    try expect_source_sidecars_absent(temporary.dir);

    var image_a: DatabaseImage = .{};
    var image_b: DatabaseImage = .{};
    var image_c: DatabaseImage = .{};
    try load_database_image(temporary.dir, database_name, &image_a);
    var encoded_bytes: [max_ltx_bytes]u8 = undefined;
    const encoded_a = try encode_transition(null, &image_a, 1, &encoded_bytes);

    var lifecycle: ManagedLifecycle = .{};
    var copy_workspace: [4096]u8 = undefined;
    var store = try sqlite_store.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        lifecycle.lifecycle(),
        .{},
    );
    var access_storage: sqlite_store.GenerationAccessStorage = .{};
    var access_workspace: sqlite_store.GenerationAccessWorkspace = .{};
    _ = try apply_and_expect(&store, encoded_bytes[0..encoded_a.length_bytes], encoded_a);
    const current_a = try open_and_expect_generation(
        &store,
        &lifecycle,
        &access_storage,
        &access_workspace,
        temporary.dir,
        &image_a,
        1,
        .a,
        .a,
    );

    try mutate_seed_to_b(temporary.dir, seed_path.sentinel());
    try load_database_image(temporary.dir, database_name, &image_b);
    try std.testing.expect(image_b.page_count > image_a.page_count);
    const encoded_b = try encode_transition(&image_a, &image_b, 2, &encoded_bytes);
    try exercise_corrupt_then_valid_b(
        &store,
        &lifecycle,
        &access_storage,
        &access_workspace,
        temporary.dir,
        current_a,
        &image_a,
        &image_b,
        &encoded_bytes,
        encoded_b,
    );

    try mutate_seed_to_c(temporary.dir, seed_path.sentinel());
    try load_database_image(temporary.dir, database_name, &image_c);
    try std.testing.expect(image_c.page_count < image_b.page_count);
    const encoded_c = try encode_transition(&image_b, &image_c, 3, &encoded_bytes);
    try exercise_blocked_then_valid_c(
        &store,
        &lifecycle,
        &access_storage,
        &access_workspace,
        temporary.dir,
        &image_b,
        &image_c,
        encoded_bytes[0..encoded_c.length_bytes],
        encoded_c,
    );
}

test "real SQLite images recover atomically across publication process crashes" {
    try std.testing.expect(sqlite3_libversion_number() >= 3_022_000);
    var source = std.testing.tmpDir(.{});
    defer source.cleanup();
    var image_a: DatabaseImage = .{};
    var image_b: DatabaseImage = .{};
    var image_c: DatabaseImage = .{};
    var encoded_a_bytes: [max_ltx_bytes]u8 = undefined;
    var encoded_b_bytes: [max_ltx_bytes]u8 = undefined;
    var encoded_c_bytes: [max_ltx_bytes]u8 = undefined;
    const encoded = try prepare_real_crash_inputs(
        source.dir,
        &image_a,
        &image_b,
        &image_c,
        &encoded_a_bytes,
        &encoded_b_bytes,
        &encoded_c_bytes,
    );
    const inputs: RealCrashInputs = .{
        .snapshot = encoded_a_bytes[0..encoded[0].length_bytes],
        .incremental = encoded_b_bytes[0..encoded[1].length_bytes],
        .reuse = encoded_c_bytes[0..encoded[2].length_bytes],
        .image_a = &image_a,
        .image_b = &image_b,
        .image_c = &image_c,
    };

    for (crash_protocol.publication_cases) |case| {
        try run_real_crash_case(
            .real_first_publication,
            case.point,
            if (case.new_visible) .a else null,
            inputs,
        );
        try run_real_crash_case(
            .real_existing_publication,
            case.point,
            if (case.new_visible) .b else .a,
            inputs,
        );
        try run_real_crash_case(
            .real_reuse_publication,
            case.point,
            if (case.new_visible) .c else .b,
            inputs,
        );
    }
    for (crash_protocol.handoff_points) |point| {
        try run_real_crash_case(
            .real_existing_publication,
            point,
            .a,
            inputs,
        );
        try run_real_crash_case(
            .real_reuse_publication,
            point,
            .b,
            inputs,
        );
    }
}

fn prepare_real_crash_inputs(
    dir: std.Io.Dir,
    image_a: *DatabaseImage,
    image_b: *DatabaseImage,
    image_c: *DatabaseImage,
    encoded_a_bytes: *[max_ltx_bytes]u8,
    encoded_b_bytes: *[max_ltx_bytes]u8,
    encoded_c_bytes: *[max_ltx_bytes]u8,
) ![3]EncodedTransition {
    const seed_path = try DatabasePath.init(dir, database_name);
    try create_and_drain_wal_database(dir, seed_path.sentinel());
    try expect_source_sidecars_absent(dir);
    try load_database_image(dir, database_name, image_a);
    const encoded_a = try encode_transition(null, image_a, 1, encoded_a_bytes);
    try mutate_seed_to_b(dir, seed_path.sentinel());
    try load_database_image(dir, database_name, image_b);
    try std.testing.expect(image_b.page_count > image_a.page_count);
    const encoded_b = try encode_transition(image_a, image_b, 2, encoded_b_bytes);
    try expect_incremental(encoded_b, image_a, image_b, 2);
    try mutate_seed_to_c(dir, seed_path.sentinel());
    try load_database_image(dir, database_name, image_c);
    try std.testing.expect(image_c.page_count < image_b.page_count);
    const encoded_c = try encode_transition(image_b, image_c, 3, encoded_c_bytes);
    try expect_incremental(encoded_c, image_b, image_c, 3);
    return .{ encoded_a, encoded_b, encoded_c };
}

fn run_real_crash_case(
    scenario: crash_protocol.Scenario,
    point: sqlite_store.FaultPoint,
    expected: ?ChainState,
    inputs: RealCrashInputs,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try write_crash_transition(
        temporary.dir,
        crash_protocol.real_snapshot_name,
        inputs.snapshot,
    );
    try write_crash_transition(
        temporary.dir,
        crash_protocol.real_incremental_name,
        inputs.incremental,
    );
    try write_crash_transition(temporary.dir, crash_protocol.real_reuse_name, inputs.reuse);
    try crash_protocol.run_child(
        std.testing.allocator,
        std.testing.io,
        crash_options.child_path,
        temporary.dir,
        scenario,
        point,
    );
    try expect_real_crash_recovery(
        temporary.dir,
        expected,
        inputs.image_a,
        inputs.image_b,
        inputs.image_c,
    );
}

fn write_crash_transition(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, name, .{
        .read = false,
        .truncate = true,
        .exclusive = true,
    });
    errdefer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, bytes, 0);
    file.close(std.testing.io);
}

fn expect_real_crash_recovery(
    dir: std.Io.Dir,
    expected: ?ChainState,
    image_a: *const DatabaseImage,
    image_b: *const DatabaseImage,
    image_c: *const DatabaseImage,
) !void {
    var lifecycle: ManagedLifecycle = .{};
    var copy_workspace: [4096]u8 = undefined;
    var store = try sqlite_store.Store.init(
        std.testing.io,
        dir,
        &copy_workspace,
        lifecycle.lifecycle(),
        .{},
    );
    const recovered = try store.recover();
    try std.testing.expectEqual(lifecycle.quiesce_count, lifecycle.release_count);
    try std.testing.expectEqualDeep(recovered, try store.current());
    try std.testing.expect(!try path_exists(dir, sqlite_store.manifest_temporary_name));
    if (expected == null) {
        try std.testing.expectEqual(null, recovered);
        try std.testing.expect(!try path_exists(dir, sqlite_store.database_a_name));
        try std.testing.expect(!try path_exists(dir, sqlite_store.database_b_name));
        return;
    }

    const state = expected.?;
    const image = switch (state) {
        .a => image_a,
        .b => image_b,
        .c => image_c,
    };
    var access_storage: sqlite_store.GenerationAccessStorage = .{};
    var access_workspace: sqlite_store.GenerationAccessWorkspace = .{};
    const current = try open_and_expect_generation(
        &store,
        &lifecycle,
        &access_storage,
        &access_workspace,
        dir,
        image,
        @intFromEnum(state) + 1,
        if (state == .b) .b else .a,
        state,
    );
    try std.testing.expectEqual(current, recovered.?);
    if (state == .c) try expect_file_image(dir, sqlite_store.database_b_name, image_b);
    try lifecycle.close();
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
        apply_encoded(&competing_store, encoded_ltx, .replace_snapshot),
    );
    try std.testing.expectEqual(.store_busy, competing_store.last_failure());
    try expect_integer_query(database, "SELECT count(*) FROM items", 3);
    try expect_no_slot_sidecars(database_dir, current.slot);

    try lifecycle.close();
    try expect_no_slot_sidecars(database_dir, current.slot);
    _ = try apply_encoded(&competing_store, encoded_ltx, .replace_snapshot);
    const replaced = (try competing_store.current()).?;
    try std.testing.expectEqual(current.generation + 1, replaced.generation);
    try std.testing.expect(current.slot != replaced.slot);
    const final_access = try lifecycle.open_generation(store, access_storage, access_workspace);
    try std.testing.expectEqual(replaced, final_access);
    try expect_integer_query(lifecycle.database.?, "SELECT count(*) FROM items", 3);
    try lifecycle.close();
    try expect_no_slot_sidecars(database_dir, replaced.slot);
}

fn apply_and_expect(
    store: *sqlite_store.Store,
    bytes: []const u8,
    encoded: EncodedTransition,
) !ltx.VerifiedLTX {
    const applied = try apply_encoded(store, bytes, .contiguous);
    try std.testing.expectEqualDeep(encoded.verified, applied);
    return applied;
}

fn open_and_expect_generation(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    access_storage: *sqlite_store.GenerationAccessStorage,
    access_workspace: *sqlite_store.GenerationAccessWorkspace,
    database_dir: std.Io.Dir,
    image: *const DatabaseImage,
    generation: u64,
    slot: sqlite_store.Slot,
    state: ChainState,
) !sqlite_store.Current {
    const current = try lifecycle.open_generation(store, access_storage, access_workspace);
    try expect_chain_generation(lifecycle, database_dir, current, image, generation, slot, state);
    return current;
}

fn expect_chain_generation(
    lifecycle: *ManagedLifecycle,
    database_dir: std.Io.Dir,
    current: sqlite_store.Current,
    image: *const DatabaseImage,
    generation: u64,
    slot: sqlite_store.Slot,
    state: ChainState,
) !void {
    try std.testing.expectEqual(generation, current.generation);
    try std.testing.expectEqual(slot, current.slot);
    try std.testing.expectEqual(@as(u64, @intFromEnum(state) + 1), current.position.txid.value);
    try std.testing.expectEqual(image.checksum, current.position.post_apply_checksum);
    try std.testing.expectEqual(page_size, current.page_size);
    try std.testing.expectEqual(@as(u64, image.length_bytes), current.database_size_bytes);
    try expect_file_image(database_dir, current.database_name(), image);
    try expect_wal_header(database_dir, current.database_name());
    try expect_no_slot_sidecars(database_dir, current.slot);

    const database = lifecycle.database orelse return error.ExpectedDatabase;
    try expect_text_query(database, "PRAGMA integrity_check", "ok");
    try expect_integer_query(database, "SELECT length(payload) FROM stable WHERE id=1", 2048);
    try expect_integer_query(
        database,
        "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='items_value_idx'",
        1,
    );
    try expect_read_only_statement(database, "DELETE FROM items");
    try expect_chain_rows(database, state);
}

fn expect_chain_rows(database: *SQLite, state: ChainState) !void {
    switch (state) {
        .a => {
            try expect_integer_query(database, "SELECT count(*) FROM items", 3);
            try expect_text_query(
                database,
                "SELECT group_concat(value, ',') FROM (SELECT value FROM items ORDER BY id)",
                "alpha,beta,gamma",
            );
        },
        .b => {
            try expect_integer_query(database, "SELECT count(*) FROM items", 14);
            try expect_text_query(database, "SELECT value FROM items WHERE id=2", "beta-v2");
            try expect_integer_query(database, "SELECT count(*) FROM items WHERE id=3", 0);
            try expect_integer_query(database, "SELECT count(*) FROM items WHERE id BETWEEN 4 AND 15", 12);
            try expect_integer_query(database, "SELECT min(length(value)) FROM items WHERE id>=4", 708);
        },
        .c => {
            try expect_integer_query(database, "SELECT count(*) FROM items", 2);
            try expect_text_query(
                database,
                "SELECT group_concat(value, ',') FROM (SELECT value FROM items ORDER BY id)",
                "alpha-v3,beta-v2",
            );
        },
    }
}

fn exercise_corrupt_then_valid_b(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    access_storage: *sqlite_store.GenerationAccessStorage,
    access_workspace: *sqlite_store.GenerationAccessWorkspace,
    database_dir: std.Io.Dir,
    current_a: sqlite_store.Current,
    image_a: *const DatabaseImage,
    image_b: *const DatabaseImage,
    encoded_bytes: *[max_ltx_bytes]u8,
    encoded_b: EncodedTransition,
) !void {
    try expect_incremental(encoded_b, image_a, image_b, 2);
    try std.testing.expect(encoded_b.verified.page_count < image_b.page_count);
    const checksum_byte = encoded_b.length_bytes - 1;
    encoded_bytes[checksum_byte] ^= 1;
    try std.testing.expectError(
        error.ChecksumMismatch,
        apply_encoded(store, encoded_bytes[0..encoded_b.length_bytes], .contiguous),
    );
    encoded_bytes[checksum_byte] ^= 1;
    try std.testing.expectEqual(lifecycle.quiesce_count, lifecycle.release_count);
    try std.testing.expectEqual(current_a, (try store.current()).?);
    try expect_file_image(database_dir, current_a.database_name(), image_a);

    _ = try open_and_expect_generation(
        store,
        lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_a,
        1,
        .a,
        .a,
    );
    _ = try apply_and_expect(store, encoded_bytes[0..encoded_b.length_bytes], encoded_b);
    _ = try open_and_expect_generation(
        store,
        lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_b,
        2,
        .b,
        .b,
    );
    try expect_file_image(database_dir, sqlite_store.database_a_name, image_a);
    try std.testing.expectEqual(lifecycle.quiesce_count, lifecycle.release_count);
}

fn exercise_blocked_then_valid_c(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    access_storage: *sqlite_store.GenerationAccessStorage,
    access_workspace: *sqlite_store.GenerationAccessWorkspace,
    database_dir: std.Io.Dir,
    image_b: *const DatabaseImage,
    image_c: *const DatabaseImage,
    encoded_bytes: []const u8,
    encoded_c: EncodedTransition,
) !void {
    try expect_incremental(encoded_c, image_b, image_c, 3);
    var competing_lifecycle: ManagedLifecycle = .{};
    var competing_copy_workspace: [4096]u8 = undefined;
    var competing_store = try sqlite_store.Store.init(
        std.testing.io,
        database_dir,
        &competing_copy_workspace,
        competing_lifecycle.lifecycle(),
        .{},
    );
    var stale_b = try block_c_through_retained_b(
        lifecycle,
        &competing_store,
        &competing_lifecycle,
        encoded_bytes,
    );

    _ = try open_and_expect_generation(
        store,
        lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_b,
        2,
        .b,
        .b,
    );
    try expect_stale_access(&stale_b);
    try expect_competing_apply_busy(&competing_store, &competing_lifecycle, encoded_bytes);
    try lifecycle.close();
    _ = try apply_and_expect(&competing_store, encoded_bytes, encoded_c);
    const current_c = try open_and_expect_generation(
        store,
        lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_c,
        3,
        .a,
        .c,
    );
    try expect_file_image(database_dir, sqlite_store.database_b_name, image_b);
    try lifecycle.close();
    try recover_and_reopen_c(
        store,
        lifecycle,
        &competing_store,
        &competing_lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_c,
        current_c,
    );
    try expect_no_slot_sidecars(database_dir, .a);
    try expect_no_slot_sidecars(database_dir, .b);
}

fn recover_and_reopen_c(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    competing_store: *sqlite_store.Store,
    competing_lifecycle: *ManagedLifecycle,
    access_storage: *sqlite_store.GenerationAccessStorage,
    access_workspace: *sqlite_store.GenerationAccessWorkspace,
    database_dir: std.Io.Dir,
    image_c: *const DatabaseImage,
    current_c: sqlite_store.Current,
) !void {
    try std.testing.expectEqual(current_c, (try competing_store.recover()).?);
    try std.testing.expectEqual(
        competing_lifecycle.quiesce_count,
        competing_lifecycle.release_count,
    );
    _ = try open_and_expect_generation(
        store,
        lifecycle,
        access_storage,
        access_workspace,
        database_dir,
        image_c,
        3,
        .a,
        .c,
    );
    try lifecycle.close();
}

fn block_c_through_retained_b(
    lifecycle: *ManagedLifecycle,
    competing_store: *sqlite_store.Store,
    competing_lifecycle: *ManagedLifecycle,
    encoded_bytes: []const u8,
) !sqlite_store.GenerationAccess {
    var stale_b = lifecycle.generation_access orelse return error.ExpectedGeneration;
    const current_b = try stale_b.current();
    try lifecycle.hold_read_transaction();
    try expect_competing_apply_busy(competing_store, competing_lifecycle, encoded_bytes);

    try lifecycle.close_sqlite();
    try std.testing.expect(lifecycle.database == null);
    try std.testing.expect(lifecycle.held_statement == null);
    const retained = if (lifecycle.generation_access) |*access|
        try access.current()
    else
        return error.ExpectedGeneration;
    try std.testing.expectEqual(current_b, retained);
    try expect_competing_apply_busy(competing_store, competing_lifecycle, encoded_bytes);

    try std.testing.expectError(error.StoreBusy, competing_store.recover());
    try std.testing.expect(competing_lifecycle.admission_closed);
    try std.testing.expectEqual(
        competing_lifecycle.quiesce_count,
        competing_lifecycle.release_count + 1,
    );
    try lifecycle.release_generation();
    try expect_stale_access(&stale_b);
    try std.testing.expectEqual(current_b, (try competing_store.recover()).?);
    try std.testing.expectEqual(
        competing_lifecycle.quiesce_count,
        competing_lifecycle.release_count,
    );
    return stale_b;
}

fn expect_competing_apply_busy(
    store: *sqlite_store.Store,
    lifecycle: *ManagedLifecycle,
    encoded_bytes: []const u8,
) !void {
    try std.testing.expectError(
        error.ApplyBeginFailure,
        apply_encoded(store, encoded_bytes, .contiguous),
    );
    try std.testing.expectEqual(.store_busy, store.last_failure());
    try std.testing.expectEqual(lifecycle.quiesce_count, lifecycle.release_count);
}

fn expect_stale_access(access: *sqlite_store.GenerationAccess) !void {
    try std.testing.expectError(error.InvalidState, access.current());
    try std.testing.expectError(error.InvalidState, access.sqlite_open_spec());
    try std.testing.expectError(error.InvalidState, access.release());
}

fn mutate_seed_to_b(
    database_dir: std.Io.Dir,
    path: [:0]const u8,
) !void {
    var writer: ?*SQLite = try open_database(
        path,
        sqlite_open_readwrite | sqlite_open_fullmutex,
    );
    defer {
        if (writer) |database| _ = sqlite3_close(database);
    }
    try configure_wal(writer.?);

    var reader: ?*SQLite = try open_database(path, sqlite_open_readonly | sqlite_open_fullmutex);
    var held_reader: ?*Statement = null;
    defer {
        if (held_reader) |statement| _ = sqlite3_finalize(statement);
        if (reader) |database| _ = sqlite3_close(database);
    }
    try execute(reader.?, "BEGIN");
    held_reader = try prepare(reader.?, "SELECT value FROM items ORDER BY id");
    try expect_result(reader.?, sqlite3_step(held_reader.?), sqlite_row);
    try expect_statement_text(held_reader.?, "alpha");

    try execute(writer.?, "BEGIN IMMEDIATE");
    try execute(writer.?, "UPDATE items SET value='beta-v2' WHERE id=2");
    try execute(writer.?, "DELETE FROM items WHERE id=3");
    try execute(
        writer.?,
        "WITH RECURSIVE seq(id) AS (SELECT 4 UNION ALL SELECT id+1 FROM seq WHERE id<15) " ++
            "INSERT INTO items SELECT id,printf('bulk-%02d-',id)||hex(zeroblob(350)) FROM seq",
    );
    try execute(writer.?, "COMMIT");
    try expect_chain_rows(writer.?, .b);
    try std.testing.expect(try path_size(database_dir, database_wal_name) > 0);
    try expect_result(reader.?, sqlite3_step(held_reader.?), sqlite_row);
    try expect_statement_text(held_reader.?, "beta");
    try expect_result(reader.?, sqlite3_step(held_reader.?), sqlite_row);
    try expect_statement_text(held_reader.?, "gamma");
    try expect_result(reader.?, sqlite3_step(held_reader.?), sqlite_done);

    var log_frames: c_int = -1;
    var checkpointed_frames: c_int = -1;
    try std.testing.expectEqual(sqlite_busy, sqlite3_wal_checkpoint_v2(
        writer.?,
        "main",
        sqlite_checkpoint_truncate,
        &log_frames,
        &checkpointed_frames,
    ));
    try std.testing.expect(try path_size(database_dir, database_wal_name) > 0);
    try std.testing.expectEqual(sqlite_ok, sqlite3_finalize(held_reader));
    held_reader = null;
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(reader));
    reader = null;

    try drain_wal(writer.?);
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(writer));
    writer = null;
    try expect_source_sidecars_absent(database_dir);
}

fn mutate_seed_to_c(database_dir: std.Io.Dir, path: [:0]const u8) !void {
    var writer: ?*SQLite = try open_database(
        path,
        sqlite_open_readwrite | sqlite_open_fullmutex,
    );
    defer {
        if (writer) |database| _ = sqlite3_close(database);
    }
    try configure_wal(writer.?);
    try execute(writer.?, "BEGIN IMMEDIATE");
    try execute(writer.?, "DELETE FROM items WHERE id>=4");
    try execute(writer.?, "UPDATE items SET value='alpha-v3' WHERE id=1");
    try execute(writer.?, "COMMIT");
    try expect_chain_rows(writer.?, .c);
    try drain_wal(writer.?);
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(writer));
    writer = null;
    try expect_source_sidecars_absent(database_dir);
}

fn configure_wal(database: *SQLite) !void {
    try execute(database, "PRAGMA journal_mode=WAL");
    try execute(database, "PRAGMA synchronous=FULL");
    try execute(database, "PRAGMA wal_autocheckpoint=0");
    try expect_integer_query(database, "PRAGMA auto_vacuum", 1);
}

fn drain_wal(database: *SQLite) !void {
    var persist_wal: c_int = 0;
    try expect_result(
        database,
        sqlite3_file_control(database, "main", sqlite_fcntl_persist_wal, &persist_wal),
        sqlite_ok,
    );
    var log_frames: c_int = -1;
    var checkpointed_frames: c_int = -1;
    try expect_result(database, sqlite3_wal_checkpoint_v2(
        database,
        "main",
        sqlite_checkpoint_truncate,
        &log_frames,
        &checkpointed_frames,
    ), sqlite_ok);
    try std.testing.expectEqual(@as(c_int, 0), log_frames);
    try std.testing.expectEqual(@as(c_int, 0), checkpointed_frames);
}

fn expect_source_sidecars_absent(database_dir: std.Io.Dir) !void {
    try std.testing.expect(!try path_exists(database_dir, database_wal_name));
    try std.testing.expect(!try path_exists(database_dir, database_shm_name));
    try std.testing.expect(!try path_exists(database_dir, database_journal_name));
}

fn path_size(database_dir: std.Io.Dir, name: []const u8) !u64 {
    return (try database_dir.statFile(
        std.testing.io,
        name,
        .{ .follow_symlinks = false },
    )).size;
}

fn create_and_drain_wal_database(dir: std.Io.Dir, path: [:0]const u8) !void {
    const writer = try open_database(
        path,
        sqlite_open_readwrite | sqlite_open_create | sqlite_open_fullmutex,
    );
    errdefer _ = sqlite3_close(writer);
    try execute(writer, "PRAGMA page_size=1024");
    try execute(writer, "PRAGMA auto_vacuum=FULL");
    try execute(writer, "PRAGMA journal_mode=WAL");
    try execute(writer, "PRAGMA synchronous=FULL");
    try execute(writer, "PRAGMA wal_autocheckpoint=0");
    try execute(writer, "CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT NOT NULL)");
    try execute(writer, "CREATE INDEX items_value_idx ON items(value)");
    try execute(writer, "CREATE TABLE stable(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)");
    try execute(writer, "INSERT INTO items VALUES(1,'alpha'),(2,'beta'),(3,'gamma')");
    try execute(writer, "INSERT INTO stable VALUES(1,zeroblob(2048))");
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

    try drain_wal(writer);
    try std.testing.expectEqual(sqlite_ok, sqlite3_close(writer));
}

fn encode_seed_snapshot(dir: std.Io.Dir, output: []u8) !usize {
    var image: DatabaseImage = .{};
    try load_database_image(dir, database_name, &image);
    return (try encode_transition(null, &image, 1, output)).length_bytes;
}

fn load_database_image(
    dir: std.Io.Dir,
    name: []const u8,
    image: *DatabaseImage,
) !void {
    var database = try dir.openFile(std.testing.io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer database.close(std.testing.io);
    const stat = try database.stat(std.testing.io);
    if (stat.size == 0 or stat.size % page_size != 0) return error.InvalidDatabaseSize;
    if (stat.size > image.bytes.len) return error.DatabaseTooLarge;
    image.length_bytes = @intCast(stat.size);
    image.page_count = @intCast(stat.size / page_size);
    const destination = image.bytes[0..image.length_bytes];
    const read = try database.readPositionalAll(std.testing.io, destination, 0);
    if (read != destination.len) return error.ShortDatabaseRead;
    try validate_database_image(image);
    image.checksum = try database_image_checksum(image);
}

fn validate_database_image(image: *const DatabaseImage) !void {
    try std.testing.expectEqualStrings("SQLite format 3\x00", image.bytes[0..16]);
    try std.testing.expectEqual(
        page_size,
        @as(u32, std.mem.readInt(u16, image.bytes[16..18], .big)),
    );
    try std.testing.expectEqualSlices(u8, &.{ 2, 2 }, image.bytes[18..20]);
    try std.testing.expectEqual(
        image.page_count,
        std.mem.readInt(u32, image.bytes[28..32], .big),
    );
}

fn encode_transition(
    previous: ?*const DatabaseImage,
    next: *const DatabaseImage,
    txid: u64,
    output: []u8,
) !EncodedTransition {
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
    try encoder.write_header(transition_header(previous, next, txid));
    const lock_page = try ltx.lock_page_number(page_size);
    var page_number: u32 = 1;
    while (page_number <= next.page_count) : (page_number += 1) {
        if (page_number == lock_page) continue;
        const next_page = database_page(next, page_number);
        const changed = if (previous) |prior|
            page_number > prior.page_count or
                !std.mem.eql(u8, database_page(prior, page_number), next_page)
        else
            true;
        if (changed) try encoder.write_page(page_number, next_page);
    }
    const verified = try encoder.finish(next.checksum);
    return .{ .length_bytes = sink.written().len, .verified = verified };
}

fn transition_header(
    previous: ?*const DatabaseImage,
    next: *const DatabaseImage,
    txid: u64,
) ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size,
        .commit = next.page_count,
        .min_txid = .init(txid),
        .max_txid = .init(txid),
        .timestamp_ms = @intCast(txid),
        .pre_apply_checksum = if (previous) |prior| prior.checksum else .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn database_image_checksum(image: *const DatabaseImage) !ltx.Checksum {
    var checksum = ltx.rolling_checksum_initial();
    const lock_page = try ltx.lock_page_number(page_size);
    var page_number: u32 = 1;
    while (page_number <= image.page_count) : (page_number += 1) {
        if (page_number == lock_page) continue;
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(page_number, database_page(image, page_number)),
        );
    }
    return checksum;
}

fn database_page(image: *const DatabaseImage, page_number: u32) []const u8 {
    std.debug.assert(page_number >= 1 and page_number <= image.page_count);
    const start: usize = @intCast((page_number - 1) * page_size);
    return image.bytes[start .. start + page_size];
}

fn expect_incremental(
    encoded: EncodedTransition,
    previous: *const DatabaseImage,
    next: *const DatabaseImage,
    txid: u64,
) !void {
    try std.testing.expect(!encoded.verified.header.is_snapshot());
    try std.testing.expect(encoded.verified.page_count > 0);
    try std.testing.expectEqual(txid, encoded.verified.header.min_txid.value);
    try std.testing.expectEqual(txid, encoded.verified.header.max_txid.value);
    try std.testing.expectEqual(previous.checksum, encoded.verified.header.pre_apply_checksum);
    try std.testing.expectEqual(next.checksum, encoded.verified.trailer.post_apply_checksum);
    try std.testing.expectEqual(next.page_count, encoded.verified.header.commit);
}

fn expect_file_image(
    dir: std.Io.Dir,
    name: []const u8,
    expected: *const DatabaseImage,
) !void {
    var file = try dir.openFile(std.testing.io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, expected.length_bytes), stat.size);
    var actual: [max_database_bytes]u8 = undefined;
    const destination = actual[0..expected.length_bytes];
    const read = try file.readPositionalAll(std.testing.io, destination, 0);
    try std.testing.expectEqual(destination.len, read);
    try std.testing.expectEqualSlices(
        u8,
        expected.bytes[0..expected.length_bytes],
        destination,
    );
}

fn apply_encoded(
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
    try expect_statement_text(statement, expected);
    try expect_result(database, sqlite3_step(statement), sqlite_done);
}

fn expect_statement_text(statement: *Statement, expected: []const u8) !void {
    const text = sqlite3_column_text(statement, 0) orelse return error.SQLiteNullText;
    const length = sqlite3_column_bytes(statement, 0);
    if (length < 0) return error.SQLiteInvalidText;
    try std.testing.expectEqualStrings(expected, text[0..@intCast(length)]);
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
