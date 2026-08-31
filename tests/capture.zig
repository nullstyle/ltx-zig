//! Live capture integration against the host system SQLite.
//!
//! Builds a real WAL-mode database through a capture session, publishes L0
//! transitions through the filesystem object client, restores the tree with
//! the replica engine, and verifies the restored image by querying it with a
//! separate read-only immutable SQLite connection.

const std = @import("std");
const ltx = @import("ltx");
const ltx_object = @import("ltx_object");
const ltx_wal = @import("ltx_wal");
const ltx_capture = @import("ltx_capture");
const ltx_replica = @import("ltx_replica");

const sqlite_ok: c_int = 0;
const sqlite_row: c_int = 100;
const sqlite_done: c_int = 101;
const sqlite_open_readonly: c_int = 0x0000_0001;
const sqlite_open_uri: c_int = 0x0000_0040;

const sqlite = struct {
    extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        db: *?*anyopaque,
        flags: c_int,
        vfs: ?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_close_v2(db: ?*anyopaque) c_int;
    extern fn sqlite3_prepare_v2(
        db: ?*anyopaque,
        sql: [*:0]const u8,
        byte_count: c_int,
        statement: *?*anyopaque,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(statement: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(statement: ?*anyopaque) c_int;
    extern fn sqlite3_column_int64(statement: ?*anyopaque, column: c_int) i64;
    extern fn sqlite3_errmsg(db: ?*anyopaque) [*:0]const u8;
};

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

const TestWorkspaces = struct {
    wal_storage: [1 << 20]u8 = undefined,
    map_slots: [64]ltx_wal.PageSlot = [_]ltx_wal.PageSlot{.{}} ** 64,
    map_pending: [64]u32 = [_]u32{0} ** 64,
    map_seen: [8]u8 = [_]u8{0} ** 8,
    map_entries: [64]ltx_wal.PageMapEntry =
        [_]ltx_wal.PageMapEntry{.{ .page_number = 0, .frame_offset_bytes = 0 }} ** 64,
    output_storage: [1 << 20]u8 = undefined,
    page_workspace: [4096]u8 = undefined,
    compressed_workspace: [4200]u8 = undefined,
    compression_workspace: ltx.LZ4CompressionWorkspace = undefined,
    index_workspace: [64]ltx.PageIndexEntry =
        [_]ltx.PageIndexEntry{.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 }} ** 64,

    fn workspaces(self: *TestWorkspaces) ltx_capture.Workspaces {
        return .{
            .wal_storage = &self.wal_storage,
            .map_slots = &self.map_slots,
            .map_pending = &self.map_pending,
            .map_seen = &self.map_seen,
            .map_entries = &self.map_entries,
            .output_storage = &self.output_storage,
            .page_workspace = &self.page_workspace,
            .compressed_workspace = &self.compressed_workspace,
            .compression_workspace = &self.compression_workspace,
            .index_workspace = &self.index_workspace,
        };
    }
};

const FaultMode = enum { none, write_once, finish_once };

const FaultingClient = struct {
    backing: ltx_object.Client,
    mode: FaultMode = .none,
    inner: ?ltx_object.WriteSession = null,
    abort_count: u32 = 0,

    fn client(self: *FaultingClient) ltx_object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .open_fn = open,
            .write_fn = write_object,
            .begin_write_fn = begin_write,
            .delete_fn = delete,
        };
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) ltx_object.Error![]const ltx.FileInfo {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        return self.backing.list(level, seek, destination);
    }

    fn open(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        destination: []u8,
    ) ltx_object.Error![]const u8 {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        return self.backing.open(level, identity, destination);
    }

    fn write_object(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) ltx_object.Error!void {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        return self.backing.write(level, identity, created_at_ms, bytes);
    }

    fn begin_write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) ltx_object.Error!ltx_object.WriteSession {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        if (self.inner != null) return error.InvalidState;
        self.inner = try self.backing.begin_write(level, identity, created_at_ms);
        return ltx_object.WriteSession.init(.{
            .context = self,
            .write_fn = write_chunk,
            .finish_fn = finish_write,
            .abort_fn = abort_write,
        });
    }

    fn delete(context: *anyopaque, files: []const ltx.FileInfo) ltx_object.Error!void {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        return self.backing.delete(files);
    }

    fn write_chunk(context: *anyopaque, bytes: []const u8) ltx_object.Error!void {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        if (self.mode == .write_once) {
            self.mode = .none;
            return error.StorageFailure;
        }
        const inner = if (self.inner) |*active| active else return error.InvalidState;
        inner.writer().write_all(bytes) catch return error.StorageFailure;
    }

    fn finish_write(context: *anyopaque) ltx_object.Error!void {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        if (self.mode == .finish_once) {
            self.mode = .none;
            return error.StorageFailure;
        }
        const inner = if (self.inner) |*active| active else return error.InvalidState;
        try inner.finish();
        self.inner = null;
    }

    fn abort_write(context: *anyopaque) void {
        const self: *FaultingClient = @ptrCast(@alignCast(context));
        if (self.inner) |*active| active.abort();
        self.inner = null;
        self.abort_count += 1;
    }
};

const CaptureResumeState = struct {
    position: ltx.Position,
    segment_salt: ltx_wal.SaltPair,
    segment_end_offset_bytes: u64,
    segment_commit_pages: u32,
    segment_restarted: bool,
    last_wal_bytes: u64,
    last_wal_frame_count: u64,
    last_sync_ms: ?i64,
};

fn capture_resume_state(session: *const ltx_capture.Session) CaptureResumeState {
    return .{
        .position = session.position,
        .segment_salt = session.segment_salt,
        .segment_end_offset_bytes = session.segment_end_offset_bytes,
        .segment_commit_pages = session.segment_commit_pages,
        .segment_restarted = session.segment_restarted,
        .last_wal_bytes = session.last_wal_bytes,
        .last_wal_frame_count = session.last_wal_frame_count,
        .last_sync_ms = session.last_sync_ms,
    };
}

fn expect_level_zero_count(client: ltx_object.Client, expected: usize) !void {
    var listed_storage: [4]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &listed_storage);
    try std.testing.expectEqual(expected, listed.len);
}

fn expect_restored_rows(
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    expected_rows: i64,
) !void {
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_length = try dir.realPath(io, &absolute);
    var uri: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &uri,
        "file:{s}/{s}?immutable=1",
        .{ absolute[0..base_length], database_name },
    );
    uri[path.len] = 0;
    var db: ?*anyopaque = null;
    if (sqlite.sqlite3_open_v2(
        @ptrCast(&uri),
        &db,
        sqlite_open_readonly | sqlite_open_uri,
        null,
    ) != sqlite_ok) return error.RestoreOpenFailure;
    defer _ = sqlite.sqlite3_close_v2(db);

    var statement: ?*anyopaque = null;
    if (sqlite.sqlite3_prepare_v2(
        db,
        "SELECT COUNT(*) FROM kv",
        -1,
        &statement,
        null,
    ) != sqlite_ok) return error.RestoreQueryFailure;
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_step(statement) != sqlite_row) return error.RestoreQueryFailure;
    try std.testing.expectEqual(
        expected_rows,
        sqlite.sqlite3_column_int64(statement, 0),
    );
}

fn list_all_levels(
    client: ltx_object.Client,
    lists: *[ltx.snapshot_level + 1][]const ltx.FileInfo,
    buffers: *[ltx.snapshot_level + 1][8]ltx.FileInfo,
) !void {
    for (0..lists.len) |level| {
        lists[level] = try client.list(@intCast(level), ltx.TXID.init(0), &buffers[level]);
    }
}

test "capture streams to FileClient without output storage" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    var empty_output: [0]u8 = .{};
    capture_workspaces.output_storage = &empty_output;

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one'), (2, 'two')");
    try std.testing.expect((try session.sync(&capture_workspaces, 1000)) > 0);
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);
    var listed_storage: [2]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &listed_storage);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].size_bytes > 0);
    try restore_and_expect(&temporary, client, 2);
}

test "capture validates the direct page workspace before publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    var short_page: [4095]u8 = undefined;
    capture_workspaces.page_workspace = &short_page;

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        session.sync(&capture_workspaces, 1000),
    );
    try std.testing.expectEqual(@as(u64, 0), session.position.txid.value);
    var listed_storage: [1]ltx.FileInfo = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        (try client.list(0, ltx.TXID.init(0), &listed_storage)).len,
    );

    capture_workspaces.page_workspace = &workspaces.page_workspace;
    try std.testing.expect((try session.sync(&capture_workspaces, 1000)) > 0);
}

test "capture rejects aliases across workspace families before publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var client = store.client();
    client.begin_write_fn = null;
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    capture_workspaces.output_storage = capture_workspaces.wal_storage;

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    try std.testing.expectError(
        error.WorkspaceAliasing,
        session.sync(&capture_workspaces, 1000),
    );
    try std.testing.expectEqual(@as(u64, 0), session.position.txid.value);
    try expect_level_zero_count(client, 0);
}

test "streaming capture permits an inactive output-storage alias" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    capture_workspaces.output_storage = capture_workspaces.wal_storage;

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    try std.testing.expect((try session.sync(&capture_workspaces, 1000)) > 0);
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);
    try expect_level_zero_count(client, 1);
}

test "capture write failure aborts without advancing and retries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var faulting = FaultingClient{
        .backing = store.client(),
        .mode = .write_once,
    };
    const client = faulting.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    const before = capture_resume_state(&session);

    try std.testing.expectError(
        error.OutputFailure,
        session.sync(&capture_workspaces, 1000),
    );
    try std.testing.expectEqualDeep(before, capture_resume_state(&session));
    try std.testing.expectEqual(@as(u32, 1), faulting.abort_count);
    try std.testing.expect(faulting.inner == null);
    try expect_level_zero_count(client, 0);

    try std.testing.expect((try session.sync(&capture_workspaces, 1000)) > 0);
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);
    try expect_level_zero_count(client, 1);
    try restore_and_expect(&temporary, client, 1);
}

test "capture finish failure aborts without advancing and retries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var faulting = FaultingClient{ .backing = store.client() };
    const client = faulting.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);

    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    const before = capture_resume_state(&session);
    faulting.mode = .finish_once;
    try std.testing.expectError(
        error.StorageFailure,
        session.sync(&capture_workspaces, 2000),
    );
    try std.testing.expectEqualDeep(before, capture_resume_state(&session));
    try std.testing.expectEqual(@as(u32, 1), faulting.abort_count);
    try std.testing.expect(faulting.inner == null);
    try expect_level_zero_count(client, 1);

    try std.testing.expect((try session.sync(&capture_workspaces, 2000)) > 0);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try expect_level_zero_count(client, 2);
    try restore_and_expect(&temporary, client, 2);
}

test "unchanged capture advances the monotonic timestamp baseline" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    session.checkpoint_interval_ms = 1;
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, std.math.minInt(i64));
    try std.testing.expectError(
        error.CaptureUnchanged,
        session.sync(&capture_workspaces, std.math.maxInt(i64)),
    );
    try std.testing.expectError(
        error.TimestampRegression,
        session.checkpoint_passive(std.math.minInt(i64)),
    );
    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    try std.testing.expectError(
        error.TimestampRegression,
        session.sync(&capture_workspaces, std.math.minInt(i64)),
    );
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);
    var listed_storage: [4]ltx.FileInfo = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        (try client.list(0, ltx.TXID.init(0), &listed_storage)).len,
    );

    _ = try session.sync(&capture_workspaces, std.math.maxInt(i64));
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try restore_and_expect(&temporary, client, 2);
}

test "capture publishes snapshot and incremental transitions that restore" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var client = store.client();
    client.begin_write_fn = null;
    try std.testing.expect(!client.supports_write_sessions());

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    // First capture is a snapshot covering the initial schema and rows.
    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one'), (2, 'two')");
    const snapshot_pages = try session.sync(&capture_workspaces, 1000);
    try std.testing.expect(snapshot_pages > 0);
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);

    // The next write produces an incremental transition.
    try session.exec("INSERT INTO kv VALUES (3, 'three')");
    const incremental_pages = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(incremental_pages > 0);
    try std.testing.expect(incremental_pages < snapshot_pages);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);

    // No committed writes means no transition.
    try std.testing.expectError(
        error.CaptureUnchanged,
        session.sync(&capture_workspaces, 2500),
    );

    // Restore the two-file tree and query the image with real SQLite.
    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_all_levels(client, &lists, &buffers);
    try std.testing.expectEqual(@as(usize, 2), lists[0].len);
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(
        &lists,
        ltx.TXID.init(0),
        &plan_storage,
    );
    try std.testing.expectEqual(@as(usize, 2), plan.len);

    var backend = try ltx_replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "restored.db",
    );
    var object_storage: [1 << 20]u8 = undefined;
    var page_workspace: [4096]u8 = undefined;
    var compressed_workspace: [4200]u8 = undefined;
    var index_workspace: [64]ltx.PageIndexEntry = undefined;
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 64, .max_database_bytes = 1 << 20 },
        .backend = backend.backend(),
        .storage = &object_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    const position = try job.run(plan);
    try std.testing.expectEqual(@as(u64, 2), position.txid.value);
    try expect_restored_rows(temporary.dir, std.testing.io, "restored.db", 3);
}

test "checkpoint restart falls back to a full snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);

    // A TRUNCATE checkpoint restarts the WAL segment: the salts change and
    // the committed region no longer extends the captured offset, so the
    // next capture must fall back to a full snapshot rather than emit a
    // bogus incremental.
    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    try session.exec("INSERT INTO kv VALUES (3, 'three')");
    const restart_pages = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(restart_pages > 0);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);

    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    try list_all_levels(client, &lists, &buffers);
    try std.testing.expectEqual(@as(usize, 2), lists[0].len);
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(
        &lists,
        ltx.TXID.init(0),
        &plan_storage,
    );
    try std.testing.expectEqual(@as(usize, 2), plan.len);

    var backend = try ltx_replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "restored.db",
    );
    var object_storage: [1 << 20]u8 = undefined;
    var page_workspace: [4096]u8 = undefined;
    var compressed_workspace: [4200]u8 = undefined;
    var index_workspace: [64]ltx.PageIndexEntry = undefined;
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 64, .max_database_bytes = 1 << 20 },
        .backend = backend.backend(),
        .storage = &object_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    _ = try job.run(plan);
    try expect_restored_rows(temporary.dir, std.testing.io, "restored.db", 3);
}

test "externally truncated WAL captures a database snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);
    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");

    const pages = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(pages > 0);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try restore_and_expect(&temporary, client, 2);
}

test "valid header-only WAL captures a database snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one'), (2, 'two')");

    var valid_header: [ltx_wal.header_size_bytes]u8 = undefined;
    {
        var wal_file = try temporary.dir.openFile(std.testing.io, "app.db-wal", .{});
        defer wal_file.close(std.testing.io);
        try std.testing.expectEqual(
            valid_header.len,
            try wal_file.readPositionalAll(std.testing.io, &valid_header, 0),
        );
    }
    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    {
        var wal_file = try temporary.dir.createFile(std.testing.io, "app.db-wal", .{});
        defer wal_file.close(std.testing.io);
        try wal_file.writePositionalAll(std.testing.io, &valid_header, 0);
        try wal_file.sync(std.testing.io);
    }

    const pages = try session.sync(&capture_workspaces, 1000);
    try std.testing.expect(pages > 0);
    try std.testing.expectEqual(@as(u64, 1), session.position.txid.value);
    try restore_and_expect(&temporary, client, 2);
}

test "valid uncommitted WAL tail captures a database snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);
    try session.exec("INSERT INTO kv VALUES (2, 'two')");

    const frame_offset = ltx_wal.header_size_bytes;
    const max_frame_bytes = ltx_wal.frame_header_size_bytes + 4096;
    var uncommitted: [ltx_wal.header_size_bytes + max_frame_bytes]u8 = undefined;
    var wal_prefix_bytes: usize = 0;
    {
        var wal_file = try temporary.dir.openFile(std.testing.io, "app.db-wal", .{});
        defer wal_file.close(std.testing.io);
        wal_prefix_bytes = try wal_file.readPositionalAll(std.testing.io, &uncommitted, 0);
    }
    try std.testing.expect(wal_prefix_bytes >= ltx_wal.header_size_bytes);
    const header = try ltx_wal.decode_header(
        uncommitted[0..ltx_wal.header_size_bytes],
    );
    const frame_bytes = ltx_wal.frame_header_size_bytes +
        std.math.cast(usize, header.page_size).?;
    const uncommitted_bytes = uncommitted[0 .. ltx_wal.header_size_bytes + frame_bytes];
    try std.testing.expect(wal_prefix_bytes >= uncommitted_bytes.len);
    std.mem.writeInt(u32, uncommitted[frame_offset + 4 ..][0..4], 0, .big);
    var sums = ltx_wal.checksum(
        header.checksum_order,
        .{ .sum_1 = header.checksum_1, .sum_2 = header.checksum_2 },
        uncommitted[frame_offset..][0..8],
    );
    sums = ltx_wal.checksum(
        header.checksum_order,
        sums,
        uncommitted_bytes[frame_offset + ltx_wal.frame_header_size_bytes ..],
    );
    std.mem.writeInt(
        u32,
        uncommitted[frame_offset + 16 ..][0..4],
        sums.sum_1,
        .big,
    );
    std.mem.writeInt(
        u32,
        uncommitted[frame_offset + 20 ..][0..4],
        sums.sum_2,
        .big,
    );
    try std.testing.expect(session.segment_end_offset_bytes > uncommitted_bytes.len);

    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    {
        var wal_file = try temporary.dir.createFile(std.testing.io, "app.db-wal", .{});
        defer wal_file.close(std.testing.io);
        try wal_file.writePositionalAll(std.testing.io, uncommitted_bytes, 0);
        try wal_file.sync(std.testing.io);
    }

    const pages = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(pages > 0);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try restore_and_expect(&temporary, client, 2);
}

test "short nonempty WAL is rejected without advancing capture" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();
    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);
    try session.exec("PRAGMA wal_checkpoint(TRUNCATE)");

    var wal_file = try temporary.dir.createFile(std.testing.io, "app.db-wal", .{});
    const short_header: [16]u8 = @splat(0xa5);
    try wal_file.writePositionalAll(std.testing.io, &short_header, 0);
    try wal_file.sync(std.testing.io);
    wal_file.close(std.testing.io);
    const before = capture_resume_state(&session);

    try std.testing.expectError(
        error.TruncatedHeader,
        session.sync(&capture_workspaces, 2000),
    );
    try std.testing.expectEqualDeep(before, capture_resume_state(&session));
    try expect_level_zero_count(client, 1);
}

fn restore_and_expect(
    temporary: *std.testing.TmpDir,
    client: ltx_object.Client,
    expected_rows: i64,
) !void {
    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    for (0..lists.len) |level| {
        lists[level] = try client.list(@intCast(level), ltx.TXID.init(0), &buffers[level]);
    }
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    try std.testing.expect(plan.len > 0);

    var backend = try ltx_replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "restored.db",
    );
    var object_storage: [1 << 20]u8 = undefined;
    var page_workspace: [4096]u8 = undefined;
    var compressed_workspace: [4200]u8 = undefined;
    var index_workspace: [64]ltx.PageIndexEntry = undefined;
    var job = ltx_replica.RestoreJob{
        .client = client,
        .codec_limits = codec_limits,
        .apply_limits = .{ .max_database_pages = 64, .max_database_bytes = 1 << 20 },
        .backend = backend.backend(),
        .storage = &object_storage,
        .page_workspace = &page_workspace,
        .compressed_workspace = &compressed_workspace,
        .index_workspace = &index_workspace,
    };
    _ = try job.run(plan);
    try expect_restored_rows(temporary.dir, std.testing.io, "restored.db", expected_rows);
}

test "session checkpoint continues with a small incremental" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one'), (2, 'two')");
    const snapshot_pages = try session.sync(&capture_workspaces, 1000);
    try std.testing.expect(snapshot_pages > 0);

    // A session-initiated checkpoint restarts the WAL segment; new writes
    // must continue the position as an incremental, not a fresh snapshot.
    try session.checkpoint_passive(1500);
    try session.exec("INSERT INTO kv VALUES (3, 'three')");
    const incremental_pages = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(incremental_pages > 0);
    try std.testing.expect(incremental_pages < snapshot_pages);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);

    try restore_and_expect(&temporary, client, 3);
}

test "passive checkpoint reports an incomplete held-reader pass" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);

    var reader = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer reader.finish();
    try reader.exec("BEGIN");
    defer reader.exec("ROLLBACK") catch {};
    try reader.exec("SELECT count(*) FROM kv");

    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    _ = try session.sync(&capture_workspaces, 2000);
    try std.testing.expectError(
        error.CheckpointIncomplete,
        session.checkpoint_passive(2500),
    );
    try std.testing.expect(session.checkpoint_pending);
    try std.testing.expect(!session.segment_restarted);
    try std.testing.expectEqual(@as(i64, 1000), session.last_checkpoint_ms);

    try reader.exec("ROLLBACK");
    try session.checkpoint_passive(3000);
    try std.testing.expect(!session.checkpoint_pending);
    try std.testing.expect(session.segment_restarted);
    try std.testing.expectEqual(@as(i64, 3000), session.last_checkpoint_ms);
}

test "automatic checkpoint defers an incomplete pass after publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);

    var reader = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer reader.finish();
    try reader.exec("BEGIN");
    defer reader.exec("ROLLBACK") catch {};
    try reader.exec("SELECT count(*) FROM kv");

    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    session.checkpoint_threshold_bytes = 1;
    const captured = try session.sync(&capture_workspaces, 2000);
    try std.testing.expect(captured > 0);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try std.testing.expect(session.checkpoint_pending);
    try std.testing.expect(!session.segment_restarted);
    try std.testing.expectEqual(@as(i64, 1000), session.last_checkpoint_ms);
    try expect_level_zero_count(client, 2);

    try reader.exec("ROLLBACK");
    try std.testing.expectError(
        error.CaptureUnchanged,
        session.sync(&capture_workspaces, 3000),
    );
    try std.testing.expect(!session.checkpoint_pending);
    try std.testing.expect(session.segment_restarted);
    try std.testing.expectEqual(@as(i64, 3000), session.last_checkpoint_ms);
    try restore_and_expect(&temporary, client, 2);
}

test "checkpoint threshold bounds wal growth across syncs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    session.checkpoint_threshold_bytes = 32 + 3 * (24 + 4096);
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    var value: i64 = 0;
    while (value < 6) : (value += 1) {
        const sql = try std.fmt.bufPrintZ(
            &sql_buffer,
            "INSERT INTO kv VALUES ({d}, 'v{d}')",
            .{ value + 1, value + 1 },
        );
        try session.exec(sql);
        _ = try session.sync(&capture_workspaces, 1000 + value);
    }
    // The WAL never ran far past the threshold.
    const stat = try temporary.dir.statFile(std.testing.io, "app.db-wal", .{});
    try std.testing.expect(stat.size <= session.checkpoint_threshold_bytes + 8 * (24 + 4096));

    try restore_and_expect(&temporary, client, 6);
}

var sql_buffer: [128]u8 = undefined;

test "mid-WAL resume captures every incremental on one continuing segment" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    var value: i64 = 0;
    while (value < 4) : (value += 1) {
        const statement = try std.fmt.bufPrintZ(
            &sql_buffer,
            "INSERT INTO kv VALUES ({d}, 'v{d}')",
            .{ value + 1, value + 1 },
        );
        try session.exec(statement);
        _ = try session.sync(&capture_workspaces, 1000 + value);
        try std.testing.expectEqual(
            @as(u64, @intCast(value + 1)),
            session.position.txid.value,
        );
    }
    // Every sync after the first resumed mid-WAL with a seeded checksum
    // chain; the whole tree must still restore to the final image.
    try restore_and_expect(&temporary, client, 4);
}

test "checkpoint interval bounds wal age for sparse writers" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    session.checkpoint_interval_ms = 5000;
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");

    // Syncs inside the interval neither checkpoint nor restart the segment.
    _ = try session.sync(&capture_workspaces, 1000);
    try session.exec("INSERT INTO kv VALUES (2, 'two')");
    _ = try session.sync(&capture_workspaces, 3000);
    try std.testing.expectEqual(@as(u64, 2), session.position.txid.value);
    try std.testing.expect(!session.segment_restarted);

    // The first sync at or beyond the interval runs a checkpoint; the
    // control-row write means the restarted segment has a committed frame.
    // A passive checkpoint resets the WAL write position without shrinking
    // the file, so the live committed region — not the file size — is what
    // bounds future capture work.
    try session.exec("INSERT INTO kv VALUES (3, 'three')");
    _ = try session.sync(&capture_workspaces, 6000);
    try std.testing.expect(session.segment_restarted);
    {
        var wal_file = try temporary.dir.openFile(std.testing.io, "app.db-wal", .{});
        defer wal_file.close(std.testing.io);
        const wal_stat = try wal_file.stat(std.testing.io);
        const wal_size = std.math.cast(usize, wal_stat.size) orelse
            return error.WALTooLarge;
        try std.testing.expect(wal_size <= workspaces.wal_storage.len);
        _ = try wal_file.readPositionalAll(
            std.testing.io,
            workspaces.wal_storage[0..wal_size],
            0,
        );
        var wal_reader = try ltx_wal.Reader.init(wal_limits, workspaces.wal_storage[0..wal_size]);
        var map_slots: [64]ltx_wal.PageSlot = @splat(.{});
        var map_pending: [64]u32 = @splat(0);
        var map_seen: [8]u8 = @splat(0);
        var map_entries: [64]ltx_wal.PageMapEntry =
            @splat(.{ .page_number = 0, .frame_offset_bytes = 0 });
        const map = try wal_reader.page_map(.{
            .slots = &map_slots,
            .pending_pages = &map_pending,
            .pending_seen = &map_seen,
            .entries = &map_entries,
        });
        try std.testing.expect(map.end_offset_bytes <= 32 + 4 * (24 + 4096));
    }

    // The post-checkpoint write continues as a small incremental.
    try session.exec("INSERT INTO kv VALUES (4, 'four')");
    const pages = try session.sync(&capture_workspaces, 7000);
    try std.testing.expect(pages > 0);
    try std.testing.expectEqual(@as(u64, 4), session.position.txid.value);

    try restore_and_expect(&temporary, client, 4);
}

test "frame-count checkpoint tier bounds WAL length" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try ltx_object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();

    var session = try ltx_capture.Session.init(
        temporary.dir,
        std.testing.io,
        "app.db",
        codec_limits,
        wal_limits,
        client,
    );
    defer session.finish();
    var workspaces = TestWorkspaces{};
    var capture_workspaces = workspaces.workspaces();

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    try session.exec("INSERT INTO kv VALUES (1, 'one')");
    _ = try session.sync(&capture_workspaces, 1000);
    // Start the tier just above the observed committed region so the
    // subsequent bound is independent of SQLite's schema-frame count.
    try std.testing.expect(!session.segment_restarted);
    try std.testing.expect(session.last_wal_frame_count > 0);
    session.checkpoint_max_frames = std.math.cast(
        u32,
        session.last_wal_frame_count + 2,
    ) orelse return error.FrameLimitExceeded;

    // Enough batches to cross the configured frame count must trigger the
    // tier; a timestamp-baseline update alone cannot satisfy this assertion.
    var batch: u64 = 0;
    var checkpointed = false;
    while (batch < 4 and !checkpointed) : (batch += 1) {
        const statement = try std.fmt.bufPrintZ(
            &sql_buffer,
            "INSERT INTO kv VALUES ({d}, 'v{d}')",
            .{ batch + 2, batch + 2 },
        );
        try session.exec(statement);
        _ = try session.sync(&capture_workspaces, @intCast(2000 + batch));
        checkpointed = session.segment_restarted;
    }
    try std.testing.expect(checkpointed);
    try std.testing.expect(session.last_checkpoint_ms >= 2000);
    try restore_and_expect(&temporary, client, @intCast(batch + 1));
}
