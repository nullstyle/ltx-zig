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
const read_workspace_bytes: u32 = 1024;
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
    .read_workspace_bytes = read_workspace_bytes,
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
    restore_read_workspace: [read_workspace_bytes]u8 = undefined,
    restore_page: [max_page_bytes]u8 = undefined,
    restore_compressed: [max_compressed_bytes]u8 = undefined,
    restore_index: [max_pages]ltx.PageIndexEntry = undefined,
    job_inputs: [max_compaction_inputs]replica.CompactionJobInput = undefined,
    compaction_inputs: [max_compaction_inputs]ltx.CompactionInput = undefined,
    input_read_workspaces: [max_compaction_inputs][read_workspace_bytes]u8 = undefined,
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
                .read_workspace = &self.input_read_workspaces[index],
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
            .restore_read_workspace = &self.restore_read_workspace,
            .restore_page_workspace = &self.restore_page,
            .restore_compressed_workspace = &self.restore_compressed,
            .restore_index_workspace = &self.restore_index,
            .compaction_job_inputs = &self.job_inputs,
            .compaction_inputs = &self.compaction_inputs,
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

const DeleteFaultMode = enum {
    before_batch,
    after_first,
};

const DeleteFaultClient = struct {
    backing: object.Client,
    mode: DeleteFaultMode,
    enabled: bool = true,
    successful_calls_before_fault: u32 = 0,
    fault_fired: bool = false,
    delete_call_count: u32 = 0,

    fn client(self: *DeleteFaultClient) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .begin_write_fn = begin_write,
            .delete_fn = delete_objects,
        };
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) object.Error![]const ltx.FileInfo {
        const self: *DeleteFaultClient = @ptrCast(@alignCast(context));
        return self.backing.list(level, seek, destination);
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        offset_bytes: u64,
        destination: []u8,
    ) object.Error!void {
        const self: *DeleteFaultClient = @ptrCast(@alignCast(context));
        return self.backing.read_range(info, offset_bytes, destination);
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) object.Error!void {
        const self: *DeleteFaultClient = @ptrCast(@alignCast(context));
        return self.backing.write(level, identity, created_at_ms, bytes);
    }

    fn begin_write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) object.Error!object.WriteSession {
        const self: *DeleteFaultClient = @ptrCast(@alignCast(context));
        return self.backing.begin_write(level, identity, created_at_ms);
    }

    fn delete_objects(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) object.Error!void {
        const self: *DeleteFaultClient = @ptrCast(@alignCast(context));
        self.delete_call_count += 1;
        if (!self.enabled or self.fault_fired) return self.backing.delete(files);
        if (self.successful_calls_before_fault != 0) {
            self.successful_calls_before_fault -= 1;
            return self.backing.delete(files);
        }
        self.fault_fired = true;
        if (self.mode == .after_first and files.len != 0) {
            try self.backing.delete(files[0..1]);
        }
        return error.StorageFailure;
    }
};

const WholeObjectClient = struct {
    backing: object.Client,

    fn client(self: *WholeObjectClient) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .delete_fn = delete_objects,
        };
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) object.Error![]const ltx.FileInfo {
        const self: *WholeObjectClient = @ptrCast(@alignCast(context));
        return self.backing.list(level, seek, destination);
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        offset_bytes: u64,
        destination: []u8,
    ) object.Error!void {
        const self: *WholeObjectClient = @ptrCast(@alignCast(context));
        return self.backing.read_range(info, offset_bytes, destination);
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) object.Error!void {
        const self: *WholeObjectClient = @ptrCast(@alignCast(context));
        return self.backing.write(level, identity, created_at_ms, bytes);
    }

    fn delete_objects(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) object.Error!void {
        const self: *WholeObjectClient = @ptrCast(@alignCast(context));
        return self.backing.delete(files);
    }
};

const resource_arena_alignment = @max(
    @alignOf(replication.Resources),
    @max(
        @alignOf(ltx.LZ4CompressionWorkspace),
        @max(
            @alignOf(ltx.FileInfo),
            @max(
                @alignOf(wal.PageSlot),
                @max(
                    @alignOf(wal.PageMapEntry),
                    @max(
                        @alignOf(ltx.PageIndexEntry),
                        @max(
                            @alignOf(replica.CompactionJobInput),
                            @alignOf(ltx.CompactionInput),
                        ),
                    ),
                ),
            ),
        ),
    ),
);

fn expect_region_in_arena(arena: []const u8, region: []const u8) !void {
    if (region.len == 0) return;
    const arena_start = @intFromPtr(arena.ptr);
    const arena_end = std.math.add(usize, arena_start, arena.len) catch
        return error.TestUnexpectedResult;
    const region_start = @intFromPtr(region.ptr);
    const region_end = std.math.add(usize, region_start, region.len) catch
        return error.TestUnexpectedResult;
    try std.testing.expect(region_start >= arena_start);
    try std.testing.expect(region_end <= arena_end);
}

fn expect_slice_in_arena(
    comptime T: type,
    arena: []const u8,
    slice: []const T,
) !void {
    if (slice.len == 0) return;
    try expect_region_in_arena(arena, std.mem.sliceAsBytes(slice));
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(slice.ptr) % @alignOf(T),
    );
}

fn expect_pointer_in_arena(
    comptime T: type,
    arena: []const u8,
    pointer: *const T,
) !void {
    try expect_region_in_arena(arena, std.mem.asBytes(pointer));
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(pointer) % @alignOf(T),
    );
}

fn expect_bound_resources_in_arena(
    arena: []const u8,
    resources: *const replication.Resources,
) !void {
    try expect_pointer_in_arena(replication.Resources, arena, resources);
    try expect_slice_in_arena(u8, arena, resources.capture.wal_storage);
    try expect_slice_in_arena(wal.PageSlot, arena, resources.capture.map_slots);
    try expect_slice_in_arena(u32, arena, resources.capture.map_pending);
    try expect_slice_in_arena(u8, arena, resources.capture.map_seen);
    try expect_slice_in_arena(wal.PageMapEntry, arena, resources.capture.map_entries);
    try expect_slice_in_arena(u8, arena, resources.capture.output_storage);
    try expect_slice_in_arena(u8, arena, resources.capture.page_workspace);
    try expect_slice_in_arena(u8, arena, resources.capture.compressed_workspace);
    try expect_pointer_in_arena(
        ltx.LZ4CompressionWorkspace,
        arena,
        resources.capture.compression_workspace,
    );
    try expect_slice_in_arena(
        ltx.PageIndexEntry,
        arena,
        resources.capture.index_workspace,
    );
    try expect_slice_in_arena(ltx.FileInfo, arena, resources.level_listings);
    try expect_slice_in_arena(ltx.FileInfo, arena, resources.restore_plan);
    try expect_slice_in_arena(ltx.FileInfo, arena, resources.retention_plan);
    try expect_slice_in_arena(u8, arena, resources.restore_read_workspace);
    try expect_slice_in_arena(u8, arena, resources.restore_page_workspace);
    try expect_slice_in_arena(u8, arena, resources.restore_compressed_workspace);
    try expect_slice_in_arena(
        ltx.PageIndexEntry,
        arena,
        resources.restore_index_workspace,
    );
    try expect_slice_in_arena(
        replica.CompactionJobInput,
        arena,
        resources.compaction_job_inputs,
    );
    try expect_slice_in_arena(
        ltx.CompactionInput,
        arena,
        resources.compaction_inputs,
    );
    for (resources.compaction_job_inputs) |input| {
        try expect_slice_in_arena(u8, arena, input.read_workspace);
        try expect_slice_in_arena(u8, arena, input.page_workspace);
        try expect_slice_in_arena(u8, arena, input.compressed_workspace);
        try expect_slice_in_arena(ltx.PageIndexEntry, arena, input.index_workspace);
    }
    try expect_slice_in_arena(u8, arena, resources.compaction_output_storage);
    try expect_slice_in_arena(
        u8,
        arena,
        resources.compaction_output_compressed_workspace,
    );
    try expect_pointer_in_arena(
        ltx.LZ4CompressionWorkspace,
        arena,
        resources.compaction_output_compression_workspace,
    );
    try expect_slice_in_arena(
        ltx.PageIndexEntry,
        arena,
        resources.compaction_output_index_workspace,
    );
}

fn expect_disjoint(left: []const u8, right: []const u8) !void {
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = try std.math.add(usize, left_start, left.len);
    const right_end = try std.math.add(usize, right_start, right.len);
    try std.testing.expect(left_end <= right_start or right_end <= left_start);
}

fn expect_every_arena_alignment_binds(client: object.Client) !void {
    const capacity = try replication.Resources.arena_capacity_bytes(config, client);
    const allocation_bytes = try std.math.add(
        usize,
        capacity,
        resource_arena_alignment,
    );
    const storage = try std.testing.allocator.alloc(u8, allocation_bytes);
    defer std.testing.allocator.free(storage);
    var seen: [resource_arena_alignment]bool = @splat(false);
    for (0..resource_arena_alignment) |offset_bytes| {
        const arena = storage[offset_bytes..][0..capacity];
        seen[@intFromPtr(arena.ptr) % resource_arena_alignment] = true;
        const resources = try replication.Resources.bind(config, client, arena);
        try expect_bound_resources_in_arena(arena, resources);
    }
    try std.testing.expect(std.mem.allEqual(bool, &seen, true));
}

fn expect_one_byte_short_rejected(client: object.Client) !void {
    const capacity = try replication.Resources.arena_capacity_bytes(config, client);
    try std.testing.expect(capacity > 0);
    const allocation_bytes = try std.math.add(
        usize,
        capacity,
        resource_arena_alignment,
    );
    const storage = try std.testing.allocator.alloc(u8, allocation_bytes);
    defer std.testing.allocator.free(storage);
    const sentinel: u8 = 0xa5;
    for (0..resource_arena_alignment) |offset_bytes| {
        @memset(storage, sentinel);
        const short_arena = storage[offset_bytes..][0 .. capacity - 1];
        try std.testing.expectError(
            error.ArenaCapacityExceeded,
            replication.Resources.bind(config, client, short_arena),
        );
        try std.testing.expect(std.mem.allEqual(u8, storage, sentinel));
    }
}

test "resource arena binder selects transactional or whole-object output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const transactional_client = store.client();
    const transactional_capacity = try replication.Resources.arena_capacity_bytes(
        config,
        transactional_client,
    );
    const transactional_arena = try std.testing.allocator.alloc(
        u8,
        transactional_capacity,
    );
    defer std.testing.allocator.free(transactional_arena);
    const transactional_resources = try replication.Resources.bind(
        config,
        transactional_client,
        transactional_arena,
    );
    try std.testing.expectEqual(@as(usize, 0), transactional_resources.capture.output_storage.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        transactional_resources.compaction_output_storage.len,
    );

    var whole_object = WholeObjectClient{ .backing = store.client() };
    const whole_object_client = whole_object.client();
    const whole_object_capacity = try replication.Resources.arena_capacity_bytes(
        config,
        whole_object_client,
    );
    try std.testing.expect(whole_object_capacity > transactional_capacity);
    try std.testing.expectEqual(
        @as(usize, 2 * max_object_bytes),
        whole_object_capacity - transactional_capacity,
    );
    const whole_object_arena = try std.testing.allocator.alloc(
        u8,
        whole_object_capacity,
    );
    defer std.testing.allocator.free(whole_object_arena);
    const whole_object_resources = try replication.Resources.bind(
        config,
        whole_object_client,
        whole_object_arena,
    );
    try std.testing.expectEqual(
        @as(usize, max_object_bytes),
        whole_object_resources.capture.output_storage.len,
    );
    try std.testing.expectEqual(
        @as(usize, max_object_bytes),
        whole_object_resources.compaction_output_storage.len,
    );
    try expect_disjoint(
        whole_object_resources.capture.output_storage,
        whole_object_resources.compaction_output_storage,
    );
    try expect_bound_resources_in_arena(whole_object_arena, whole_object_resources);
}

test "resource arena capacity covers every base alignment" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    try expect_every_arena_alignment_binds(store.client());
    try expect_one_byte_short_rejected(store.client());

    var whole_object = WholeObjectClient{ .backing = store.client() };
    try expect_every_arena_alignment_binds(whole_object.client());
    try expect_one_byte_short_rejected(whole_object.client());
}

test "resource arena failures are specific and leave storage unchanged" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    const sentinel: u8 = 0x3c;
    var arena: [128]u8 = @splat(sentinel);

    var invalid_config = config;
    invalid_config.read_workspace_bytes = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        replication.Resources.arena_capacity_bytes(invalid_config, client),
    );
    try std.testing.expectError(
        error.InvalidConfiguration,
        replication.Resources.bind(invalid_config, client, &arena),
    );
    try std.testing.expect(std.mem.allEqual(u8, &arena, sentinel));

    var overflow_config = config;
    overflow_config.codec_limits.max_pages = std.math.maxInt(u32);
    overflow_config.codec_limits.max_page_index_entries = std.math.maxInt(u32);
    overflow_config.compaction_limits.max_inputs = std.math.maxInt(u32);
    overflow_config.compaction_limits.max_total_pages = std.math.maxInt(u64);
    overflow_config.max_restore_files = std.math.maxInt(u32);
    overflow_config.max_compaction_input_bytes = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ResourceBudgetOverflow,
        replication.Resources.arena_capacity_bytes(overflow_config, client),
    );
    try std.testing.expectError(
        error.ResourceBudgetOverflow,
        replication.Resources.bind(overflow_config, client, &arena),
    );
    try std.testing.expect(std.mem.allEqual(u8, &arena, sentinel));
}

test "resource arena binding passes controller lifecycle validation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    const client = store.client();
    const capacity = try replication.Resources.arena_capacity_bytes(config, client);
    const arena = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(arena);
    const resources = try replication.Resources.bind(config, client, arena);

    var controller = try replication.Controller.init(
        options(&temporary, client, "bound.db", .require_empty),
        resources,
    );
    try std.testing.expectEqual(@as(u64, 0), (try controller.position()).txid.value);
    controller.finish();
    try std.testing.expectError(error.Finished, controller.position());
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
    resources.restore_read_workspace =
        resources.restore_page_workspace[0..read_workspace_bytes];
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );

    resources = storage.bind();
    var shared_control_options = options(
        &temporary,
        store.client(),
        "never-opened.db",
        .require_empty,
    );
    shared_control_options.config.read_workspace_bytes = 128;
    resources.restore_read_workspace = std.mem.sliceAsBytes(
        resources.compaction_job_inputs,
    )[0..128];
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(shared_control_options, &resources),
    );

    resources = storage.bind();
    const map_seen_bytes = resources.capture.map_seen.len;
    resources.capture.map_seen = std.mem.sliceAsBytes(
        resources.compaction_job_inputs,
    )[0..map_seen_bytes];
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

    resources = storage.bind();
    resources.compaction_job_inputs[0].read_workspace =
        resources.compaction_job_inputs[0].page_workspace[0..read_workspace_bytes];
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );
}

test "init validates configured object-read workspace capacity" {
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
    invalid_options.config.read_workspace_bytes = 0;
    try expect_init_error(
        error.InvalidConfiguration,
        replication.Controller.init(invalid_options, &resources),
    );

    resources = storage.bind();
    resources.restore_read_workspace =
        resources.restore_read_workspace[0 .. read_workspace_bytes - 1];
    try expect_init_error(
        error.InvalidResources,
        replication.Controller.init(
            options(&temporary, store.client(), "never-opened.db", .require_empty),
            &resources,
        ),
    );

    resources = storage.bind();
    resources.compaction_job_inputs[0].read_workspace =
        resources.compaction_job_inputs[0].read_workspace[0 .. read_workspace_bytes - 1];
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

fn expect_reconciliation(
    result: replication.MaintenanceResult,
    deleted_file_count: u64,
) !void {
    switch (result) {
        .reconciled => |report| {
            try std.testing.expectEqual(@as(u8, 1), report.destination_level);
            try std.testing.expectEqual(@as(u64, 4), report.covered_through_txid.value);
            try std.testing.expectEqual(@as(u32, 1), report.verified_file_count);
            try std.testing.expectEqual(deleted_file_count, report.deleted_file_count);
        },
        else => return error.TestExpectedReconciliation,
    }
}

fn run_delete_fault_recovery(
    mode: DeleteFaultMode,
    retained_after_failure: usize,
    deleted_on_recovery: u64,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var fault = DeleteFaultClient{ .backing = store.client(), .mode = mode };
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    use_transactional_output(&resources);
    var controller = try replication.Controller.init(
        options(&temporary, fault.client(), "app.db", .require_empty),
        &resources,
    );
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "app.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
    );
    for (1..6) |row| try publish_row(&controller, &temporary, @intCast(row));
    const expected_position = try controller.position();
    try std.testing.expectError(error.StorageFailure, controller.maintain(1));
    try std.testing.expectError(error.Poisoned, controller.position());
    try std.testing.expectEqual(@as(u32, 1), fault.delete_call_count);
    const retained = try expect_level(store.client(), 0, retained_after_failure);
    defer free_level(retained);
    const published = try expect_level(store.client(), 1, 1);
    defer free_level(published);
    try std.testing.expectEqual(@as(u64, 4), published[0].max_txid.value);
    controller.finish();

    resources = storage.bind();
    use_transactional_output(&resources);
    var recovered = try replication.Controller.init(
        options(
            &temporary,
            store.client(),
            "app.db",
            .{ .verified_local = expected_position },
        ),
        &resources,
    );
    defer recovered.finish();
    try expect_reconciliation(try recovered.maintain(1), deleted_on_recovery);
    const tail = try expect_level(store.client(), 0, 1);
    defer free_level(tail);
    try std.testing.expectEqual(@as(u64, 5), tail[0].max_txid.value);

    var backend = try replica.RestoreBackend.init(
        temporary.dir,
        std.testing.io,
        "verified.db",
    );
    const restored = try recovered.restore(ltx.TXID.init(0), backend.backend());
    try std.testing.expectEqual(expected_position, restored.position);
    try expect_row_count(temporary.dir, std.testing.io, "verified.db", 5);
    try std.testing.expect((try recovered.maintain(1)) == .compacted);
    const empty = try expect_level(store.client(), 0, 0);
    defer free_level(empty);
}

test "maintenance restart reconciles a published output after delete fails" {
    try run_delete_fault_recovery(.before_batch, 5, 4);
}

test "maintenance restart converges after a partial batch delete" {
    try run_delete_fault_recovery(.after_first, 4, 3);
}

test "maintenance restart reconciles covered snapshots after cleanup fails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var fault = DeleteFaultClient{
        .backing = store.client(),
        .mode = .before_batch,
        .enabled = false,
    };
    const storage = try std.testing.allocator.create(TestResources);
    defer std.testing.allocator.destroy(storage);
    var resources = storage.bind();
    use_transactional_output(&resources);
    var controller = try replication.Controller.init(
        options(&temporary, fault.client(), "app.db", .require_empty),
        &resources,
    );
    try exec_sql(
        temporary.dir,
        std.testing.io,
        "app.db",
        "CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)",
    );
    try publish_row(&controller, &temporary, 1);
    try compact_levels(&controller, &.{ 1, 2, 3, ltx.snapshot_level });
    try publish_row(&controller, &temporary, 2);
    try compact_levels(&controller, &.{ 1, 2, 3 });

    fault.enabled = true;
    fault.successful_calls_before_fault = 1;
    const expected_position = try controller.position();
    try std.testing.expectError(
        error.StorageFailure,
        controller.maintain(ltx.snapshot_level),
    );
    try std.testing.expectError(error.Poisoned, controller.position());
    const retained = try expect_level(store.client(), ltx.snapshot_level, 2);
    defer free_level(retained);
    try std.testing.expectEqual(@as(u64, 1), retained[0].max_txid.value);
    try std.testing.expectEqual(@as(u64, 2), retained[1].max_txid.value);
    const source = try expect_level(store.client(), 3, 0);
    defer free_level(source);
    controller.finish();

    resources = storage.bind();
    use_transactional_output(&resources);
    var recovered = try replication.Controller.init(
        options(
            &temporary,
            store.client(),
            "app.db",
            .{ .verified_local = expected_position },
        ),
        &resources,
    );
    defer recovered.finish();
    const result = try recovered.maintain(ltx.snapshot_level);
    switch (result) {
        .reconciled => |report| {
            try std.testing.expectEqual(
                @as(u8, ltx.snapshot_level),
                report.destination_level,
            );
            try std.testing.expectEqual(
                @as(u64, 2),
                report.covered_through_txid.value,
            );
            try std.testing.expectEqual(@as(u32, 1), report.verified_file_count);
            try std.testing.expectEqual(@as(u64, 1), report.deleted_file_count);
        },
        else => return error.TestExpectedReconciliation,
    }
    const snapshots = try expect_level(store.client(), ltx.snapshot_level, 1);
    defer free_level(snapshots);
    try std.testing.expectEqual(@as(u64, 2), snapshots[0].max_txid.value);
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

test "maintenance verifies a covering upper before deleting any source" {
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
    const corrupt_bytes: [256]u8 = @splat(0);
    try client.write(1, first, 1500, &corrupt_bytes);
    try std.testing.expectError(error.InvalidMagic, controller.maintain(1));
    try std.testing.expectError(error.Poisoned, controller.position());

    const retained = try expect_level(client, 0, 2);
    defer free_level(retained);
    try std.testing.expectEqual(@as(u64, 1), retained[0].min_txid.value);
    try std.testing.expectEqual(@as(u64, 1), retained[0].max_txid.value);
    try std.testing.expectEqual(@as(u64, 2), retained[1].min_txid.value);
    try std.testing.expectEqual(@as(u64, 2), retained[1].max_txid.value);
    const upper = try expect_level(client, 1, 1);
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
