//! Public-seam integration coverage for the synchronous replication controller.

const std = @import("std");
const ltx = @import("ltx");
const wal = @import("ltx_wal");
const object = @import("ltx_object");
const replica = @import("ltx_replica");
const replication = @import("ltx_replication");

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
        sql: [*:0]const u8,
        callback: ?*const anyopaque,
        argument: ?*anyopaque,
        error_message: ?*?[*:0]u8,
    ) c_int;
    extern fn sqlite3_prepare_v2(
        database: ?*anyopaque,
        sql: [*:0]const u8,
        byte_count: c_int,
        statement: *?*anyopaque,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(statement: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(statement: ?*anyopaque) c_int;
    extern fn sqlite3_column_int64(statement: ?*anyopaque, column: c_int) i64;
};

const max_object_bytes = 1 << 18;
const max_page_bytes = 4096;
const max_compressed_bytes = 4200;
const max_pages = 64;
const max_frames = 128;
const max_files_per_level = 8;
const max_restore_files = 16;
const max_compaction_inputs = 4;
const max_wal_bytes = wal.header_size_bytes +
    max_frames * (wal.frame_header_size_bytes + max_page_bytes);

const config = replication.Config{
    .codec_limits = .{
        .max_input_bytes = max_object_bytes,
        .max_output_bytes = max_object_bytes,
        .max_pages = max_pages,
        .max_page_size = max_page_bytes,
        .max_compressed_page_size = max_compressed_bytes,
        .max_page_index_bytes = 1 << 16,
        .max_page_index_entries = max_pages,
        .max_varint_bytes = 10,
        .max_transaction_span = max_pages,
    },
    .wal_limits = .{
        .max_page_size = max_page_bytes,
        .max_pages = max_pages,
        .max_frames = max_frames,
    },
    .apply_limits = .{
        .max_database_pages = max_pages,
        .max_database_bytes = max_object_bytes,
    },
    .compaction_limits = .{
        .max_inputs = max_compaction_inputs,
        .max_total_pages = max_pages * max_compaction_inputs,
    },
    .levels = .{ .levels = &replica.default_levels },
    .max_files_per_level = max_files_per_level,
    .max_restore_files = max_restore_files,
    .max_compaction_input_bytes = max_object_bytes * max_compaction_inputs,
};

const TestResources = struct {
    wal_storage: [max_wal_bytes]u8 = undefined,
    map_slots: [max_pages]wal.PageSlot = undefined,
    map_pending: [max_pages]u32 = undefined,
    map_seen: [(max_pages + 7) / 8]u8 = undefined,
    map_entries: [max_pages]wal.PageMapEntry = undefined,
    capture_output: [max_object_bytes]u8 = undefined,
    capture_page: [max_page_bytes]u8 = undefined,
    capture_compressed: [max_compressed_bytes]u8 = undefined,
    capture_compression: ltx.LZ4CompressionWorkspace = undefined,
    capture_index: [max_pages]ltx.PageIndexEntry = undefined,
    level_listings: [
        (@as(usize, ltx.snapshot_level) + 1) *
            max_files_per_level
    ]ltx.FileInfo = undefined,
    restore_plan: [max_restore_files]ltx.FileInfo = undefined,
    retention_plan: [max_files_per_level]ltx.FileInfo = undefined,
    restore_storage: [max_object_bytes]u8 = undefined,
    restore_page: [max_page_bytes]u8 = undefined,
    restore_compressed: [max_compressed_bytes]u8 = undefined,
    restore_index: [max_pages]ltx.PageIndexEntry = undefined,
    job_inputs: [max_compaction_inputs]replica.CompactionJobInput = undefined,
    compaction_inputs: [max_compaction_inputs]ltx.CompactionInput = undefined,
    compaction_readers: [max_compaction_inputs]ltx.SliceReader = undefined,
    input_storage: [max_compaction_inputs][max_object_bytes]u8 = undefined,
    input_pages: [max_compaction_inputs][max_page_bytes]u8 = undefined,
    input_compressed: [max_compaction_inputs][max_compressed_bytes]u8 = undefined,
    input_indexes: [max_compaction_inputs][max_pages]ltx.PageIndexEntry = undefined,
    compaction_output: [max_object_bytes]u8 = undefined,
    compaction_compressed: [max_compressed_bytes]u8 = undefined,
    compaction_compression: ltx.LZ4CompressionWorkspace = undefined,
    compaction_index: [max_pages]ltx.PageIndexEntry = undefined,

    fn bind(self: *TestResources) replication.Resources {
        for (&self.job_inputs, 0..) |*input, index| {
            input.* = .{
                .storage = &self.input_storage[index],
                .page_workspace = &self.input_pages[index],
                .compressed_workspace = &self.input_compressed[index],
                .index_workspace = &self.input_indexes[index],
            };
        }
        return .{
            .capture = self.capture_workspaces(),
            .level_listings = &self.level_listings,
            .restore_plan = &self.restore_plan,
            .retention_plan = &self.retention_plan,
            .restore_storage = &self.restore_storage,
            .restore_page_workspace = &self.restore_page,
            .restore_compressed_workspace = &self.restore_compressed,
            .restore_index_workspace = &self.restore_index,
            .compaction_job_inputs = &self.job_inputs,
            .compaction_inputs = &self.compaction_inputs,
            .compaction_readers = &self.compaction_readers,
            .compaction_output_storage = &self.compaction_output,
            .compaction_output_compressed_workspace = &self.compaction_compressed,
            .compaction_output_compression_workspace = &self.compaction_compression,
            .compaction_output_index_workspace = &self.compaction_index,
        };
    }

    fn capture_workspaces(self: *TestResources) @import("ltx_capture").Workspaces {
        return .{
            .wal_storage = &self.wal_storage,
            .map_slots = &self.map_slots,
            .map_pending = &self.map_pending,
            .map_seen = &self.map_seen,
            .map_entries = &self.map_entries,
            .output_storage = &self.capture_output,
            .page_workspace = &self.capture_page,
            .compressed_workspace = &self.capture_compressed,
            .compression_workspace = &self.capture_compression,
            .index_workspace = &self.capture_index,
        };
    }
};

fn use_transactional_output(resources: *replication.Resources) void {
    resources.capture.output_storage = resources.capture.output_storage[0..0];
    resources.compaction_output_storage = resources.compaction_output_storage[0..0];
}

fn options(
    temporary: *std.testing.TmpDir,
    client: object.Client,
    database_name: []const u8,
    startup: replication.Startup,
) replication.Options {
    return .{
        .dir = temporary.dir,
        .io = std.testing.io,
        .database_name = database_name,
        .client = client,
        .config = config,
        .startup = startup,
    };
}

fn expect_init_error(
    expected: anyerror,
    result: replication.Error!replication.Controller,
) !void {
    if (result) |controller_value| {
        var controller = controller_value;
        controller.finish();
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

fn sqlite_path(
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    destination: []u8,
) ![*:0]const u8 {
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &absolute);
    const path = try std.fmt.bufPrint(
        destination,
        "{s}/{s}",
        .{ absolute[0..length], database_name },
    );
    if (path.len == destination.len) return error.NameTooLong;
    destination[path.len] = 0;
    return @ptrCast(destination.ptr);
}

fn exec_sql(
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    statement: [*:0]const u8,
) !void {
    var path_storage: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try sqlite_path(dir, io, database_name, &path_storage);
    var database: ?*anyopaque = null;
    const flags = sqlite_open_readwrite | sqlite_open_create | sqlite_open_uri;
    if (sqlite.sqlite3_open_v2(path, &database, flags, null) != sqlite_ok) {
        return error.SQLiteOpenFailure;
    }
    defer _ = sqlite.sqlite3_close_v2(database);
    if (sqlite.sqlite3_exec(database, statement, null, null, null) != sqlite_ok) {
        return error.SQLiteExecFailure;
    }
}

fn immutable_sqlite_uri(
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    destination: []u8,
) ![*:0]const u8 {
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &absolute);
    const uri = try std.fmt.bufPrint(
        destination,
        "file:{s}/{s}?immutable=1",
        .{ absolute[0..length], database_name },
    );
    if (uri.len == destination.len) return error.NameTooLong;
    destination[uri.len] = 0;
    return @ptrCast(destination.ptr);
}

fn expect_row_count(
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    expected: i64,
) !void {
    var path_storage: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try immutable_sqlite_uri(dir, io, database_name, &path_storage);
    var database: ?*anyopaque = null;
    if (sqlite.sqlite3_open_v2(
        path,
        &database,
        sqlite_open_readonly | sqlite_open_uri,
        null,
    ) != sqlite_ok) return error.SQLiteOpenFailure;
    defer _ = sqlite.sqlite3_close_v2(database);
    var statement: ?*anyopaque = null;
    if (sqlite.sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM kv",
        -1,
        &statement,
        null,
    ) != sqlite_ok) return error.SQLiteQueryFailure;
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_step(statement) != sqlite_row) return error.SQLiteQueryFailure;
    try std.testing.expectEqual(expected, sqlite.sqlite3_column_int64(statement, 0));
}

fn expect_level(
    client: object.Client,
    level: u8,
    expected_count: usize,
) ![]const ltx.FileInfo {
    var listing: [max_files_per_level]ltx.FileInfo = undefined;
    const files = try client.list(level, ltx.TXID.init(0), &listing);
    try std.testing.expectEqual(expected_count, files.len);
    if (files.len == 0) return &.{};
    const copy = try std.testing.allocator.dupe(ltx.FileInfo, files);
    return copy;
}

fn free_level(files: []const ltx.FileInfo) void {
    if (files.len != 0) std.testing.allocator.free(files);
}

test "sync reports publication and require-empty rejects its object tree" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    resources.restore_plan = resources.restore_plan[0..0];
    try std.testing.expectError(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );
    resources = storage.bind();
    use_transactional_output(&resources);
    var controller = try replication.Controller.init(
        options(&temporary, store.client(), "app.db", .require_empty),
        &resources,
    );
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "app.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT); INSERT INTO kv VALUES (1, 'one');",
    );
    const published = try controller.sync(1000);
    try std.testing.expectEqual(@as(u64, 1), published.published.position.txid.value);
    try std.testing.expect(published.published.page_count > 0);
    try std.testing.expectEqual(replication.SyncResult.unchanged, try controller.sync(1001));
    controller.finish();
    try std.testing.expectError(error.Finished, controller.position());
    controller.finish();

    resources = storage.bind();
    try std.testing.expectError(
        error.ObjectTreeNotEmpty,
        replication.Controller.init(
            options(&temporary, store.client(), "empty.db", .require_empty),
            &resources,
        ),
    );
}

test "init rejects aliased controller-owned planning arrays" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    resources.restore_plan = resources.level_listings[0..max_restore_files];

    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );
}

test "init rejects aliases inside operation workspace families" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    resources.capture.page_workspace = resources.capture.wal_storage[0..max_page_bytes];

    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );

    resources = storage.bind();
    resources.restore_page_workspace = resources.restore_storage[0..max_page_bytes];
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );

    resources = storage.bind();
    resources.compaction_job_inputs[1].page_workspace =
        resources.compaction_job_inputs[0].page_workspace;
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );
}

test "init rejects codec limits below the encoder literal capacity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    var invalid_options = options(
        &temporary,
        store.client(),
        "never-opened.db",
        .require_empty,
    );
    invalid_options.config.codec_limits.max_compressed_page_size = max_page_bytes;

    try expect_init_error(
        error.InvalidConfiguration,
        replication.Controller.init(invalid_options, &resources),
    );
}

test "listing validation rejects zero TXID object identities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    const zero = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(0),
        .max_txid = ltx.TXID.init(0),
    };
    try client.write(0, zero, 0, "invalid");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();

    try expect_init_error(
        error.InvalidListing,
        replication.Controller.init(
            options(&temporary, client, "never-opened.db", .require_empty),
            &resources,
        ),
    );
}

test "restore-latest rejects a target with live SQLite sidecars" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var sidecar = try temporary.dir.createFile(
        std.testing.io,
        "restored.db-wal",
        .{},
    );
    sidecar.close(std.testing.io);
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();

    try expect_init_error(
        error.RestoreTargetNotQuiescent,
        replication.Controller.init(
            options(&temporary, store.client(), "restored.db", .restore_latest),
            &resources,
        ),
    );
}

test "restore-latest restores before opening capture and seeds its position" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    var source = try replication.Controller.init(
        options(&temporary, store.client(), "source.db", .require_empty),
        &resources,
    );
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "source.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT); INSERT INTO kv VALUES (1, 'one');",
    );
    _ = try source.sync(1000);
    source.finish();

    resources = storage.bind();
    var restored = try replication.Controller.init(
        options(&temporary, store.client(), "restored.db", .restore_latest),
        &resources,
    );
    try std.testing.expectEqual(@as(u64, 1), (try restored.position()).txid.value);
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "restored.db",
        "INSERT INTO kv VALUES (2, 'two')",
    );
    const published = try restored.sync(2000);
    try std.testing.expectEqual(@as(u64, 2), published.published.position.txid.value);
    restored.finish();
}

fn publish_row(
    controller: *replication.Controller,
    temporary: *std.testing.TmpDir,
    row: u32,
) !void {
    var statement_storage: [96]u8 = undefined;
    const statement = try std.fmt.bufPrintZ(
        &statement_storage,
        "INSERT INTO kv VALUES ({d}, 'value-{d}')",
        .{ row, row },
    );
    try exec_sql(temporary.dir, std.testing.io, "app.db", statement);
    const result = try controller.sync(1000 * @as(i64, row));
    try std.testing.expectEqual(@as(u64, row), result.published.position.txid.value);
}

fn compact_levels(controller: *replication.Controller, levels: []const u8) !void {
    for (levels) |level| {
        const result = try controller.maintain(level);
        try std.testing.expect(result == .compacted);
    }
}

test "maintenance compacts one adjacent job and safely retains covered files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    use_transactional_output(&resources);
    var controller = try replication.Controller.init(
        options(&temporary, store.client(), "app.db", .require_empty),
        &resources,
    );
    defer controller.finish();
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "app.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
    );
    try publish_row(&controller, &temporary, 1);
    try publish_row(&controller, &temporary, 2);
    try publish_row(&controller, &temporary, 3);
    const first = try controller.maintain(1);
    try std.testing.expectEqual(@as(u32, 3), first.compacted.input_file_count);
    const l0 = try expect_level(store.client(), 0, 0);
    defer free_level(l0);
    const l1 = try expect_level(store.client(), 1, 1);
    defer free_level(l1);
    try compact_levels(&controller, &.{ 2, 3, ltx.snapshot_level });

    try publish_row(&controller, &temporary, 4);
    try compact_levels(&controller, &.{ 1, 2, 3, ltx.snapshot_level });
    const snapshots = try expect_level(store.client(), ltx.snapshot_level, 1);
    defer free_level(snapshots);
    try std.testing.expectEqual(@as(u64, 4), snapshots[0].max_txid.value);
    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "verified.db",
    );
    const restored = try controller.restore(ltx.TXID.init(0), backend.backend());
    try std.testing.expectEqual(@as(u64, 4), restored.position.txid.value);
    try expect_row_count(temporary.dir, std.testing.io, "verified.db", 4);
}

test "maintenance retains unselected source hidden by corrupt upper metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    use_transactional_output(&resources);
    var controller = try replication.Controller.init(
        options(&temporary, client, "app.db", .require_empty),
        &resources,
    );
    defer controller.finish();
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "app.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
    );
    try publish_row(&controller, &temporary, 1);
    try publish_row(&controller, &temporary, 2);

    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    try client.write(1, first, 1500, "not-an-ltx-object");
    try std.testing.expect((try controller.maintain(1)) == .compacted);

    const retained = try expect_level(client, 0, 1);
    defer free_level(retained);
    try std.testing.expectEqual(@as(u64, 1), retained[0].min_txid.value);
    try std.testing.expectEqual(@as(u64, 1), retained[0].max_txid.value);
    const upper = try expect_level(client, 1, 2);
    defer free_level(upper);
}

test "invalid calls stay ready and processing failures poison until finish" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    const seeded = ltx.Position{
        .txid = ltx.TXID.init(7),
        .post_apply_checksum = ltx.Checksum.init(0),
    };
    var controller = try replication.Controller.init(
        options(
            &temporary,
            store.client(),
            "app.db",
            .{ .verified_local = seeded },
        ),
        &resources,
    );
    try std.testing.expectEqual(@as(u64, 7), (try controller.position()).txid.value);
    try std.testing.expectError(error.InvalidDestinationLevel, controller.maintain(0));
    try std.testing.expectEqual(@as(u64, 7), (try controller.position()).txid.value);
    try std.testing.expectError(error.InvalidTimestamp, controller.sync(-1));
    try std.testing.expectEqual(@as(u64, 7), (try controller.position()).txid.value);

    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "restored.db",
    );
    try std.testing.expectError(
        error.TxNotAvailable,
        controller.restore(ltx.TXID.init(0), backend.backend()),
    );
    try std.testing.expectEqual(@as(u64, 7), (try controller.position()).txid.value);

    const corrupt = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    try store.client().write(0, corrupt, 1000, "not-an-ltx-object");
    if (controller.restore(ltx.TXID.init(0), backend.backend())) |_| {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectError(error.Poisoned, controller.position());
    try std.testing.expectError(error.Poisoned, controller.sync(1000));
    controller.finish();
    try std.testing.expectError(error.Finished, controller.position());
}
