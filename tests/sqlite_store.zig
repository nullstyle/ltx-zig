const std = @import("std");
const ltx = @import("ltx");
const sqlite = @import("ltx_sqlite");

const page_size: u32 = 512;
const codec_limits = ltx.Limits{
    .max_input_bytes = 800,
    .max_output_bytes = 800,
    .max_pages = 1,
    .max_page_size = page_size,
    .max_compressed_page_size = 530,
    .max_page_index_bytes = 32,
    .max_page_index_entries = 1,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const Gate = struct {
    quiesce_count: u32 = 0,
    release_count: u32 = 0,
    held: bool = false,
    fail: bool = false,

    fn lifecycle(self: *Gate) sqlite.Lifecycle {
        return .{
            .context = self,
            .quiesce_fn = quiesce,
            .release_fn = release,
        };
    }

    fn quiesce(context: *anyopaque) error{QuiesceFailure}!void {
        const self: *Gate = @ptrCast(@alignCast(context));
        if (self.fail) return error.QuiesceFailure;
        std.debug.assert(!self.held);
        self.held = true;
        self.quiesce_count += 1;
    }

    fn release(context: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(context));
        std.debug.assert(self.held);
        self.held = false;
        self.release_count += 1;
    }
};

fn make_header(min_txid: u64, max_txid: u64, commit: u32) ltx.Header {
    return .{
        .flags = ltx.header_flag_no_checksum,
        .page_size = page_size,
        .commit = commit,
        .min_txid = .init(min_txid),
        .max_txid = .init(max_txid),
        .timestamp_ms = 0,
        .pre_apply_checksum = .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn make_plan(mode: ltx.ApplyMode, header: ltx.Header) ltx.ApplyPlan {
    return .{
        .format_version = .v3,
        .mode = mode,
        .header = header,
        .final_database_size_bytes = @as(u64, header.commit) * header.page_size,
    };
}

fn make_verified(header: ltx.Header) ltx.VerifiedLTX {
    return .{
        .format_version = .v3,
        .header = header,
        .trailer = .{
            .post_apply_checksum = .init(0),
            .file_checksum = .init(@as(u64, 1) << 63),
        },
        .page_count = header.commit,
        .byte_count = 0,
    };
}

fn make_sqlite_page(fill: u8) [page_size]u8 {
    var page: [page_size]u8 = @splat(0);
    @memcpy(page[0..16], "SQLite format 3\x00");
    std.mem.writeInt(u16, page[16..18], page_size, .big);
    page[18] = 1;
    page[19] = 1;
    page[20] = 0;
    page[21] = 64;
    page[22] = 32;
    page[23] = 32;
    std.mem.writeInt(u32, page[24..28], 1, .big);
    std.mem.writeInt(u32, page[28..32], 1, .big);
    std.mem.writeInt(u32, page[40..44], 1, .big);
    std.mem.writeInt(u32, page[44..48], 4, .big);
    std.mem.writeInt(u32, page[56..60], 1, .big);
    std.mem.writeInt(u32, page[92..96], 1, .big);
    std.mem.writeInt(u32, page[96..100], 3_051_000, .big);
    page[100] = 13;
    std.mem.writeInt(u16, page[105..107], page_size, .big);
    @memset(page[108..], fill);
    return page;
}

fn encode_snapshot(output: []u8, page: []const u8) !usize {
    var sink = ltx.SliceWriter.init(output);
    var compressed_workspace: [530]u8 = undefined;
    var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed_workspace,
        &compression_workspace,
        &index_workspace,
    );
    var header = make_header(1, 1, 1);
    header.flags = 0;
    try encoder.write_header(header);
    try encoder.write_page(1, page);
    _ = try encoder.finish(try ltx.checksum_page(1, page));
    return sink.written().len;
}

fn begin(
    store: *sqlite.Store,
    plan: ltx.ApplyPlan,
) error{ApplyBeginFailure}!ltx.ApplyCurrent {
    const backend = store.backend();
    return backend.begin_fn(backend.context, plan);
}

fn stage(store: *sqlite.Store, number: u32, offset: u64, bytes: []const u8) !void {
    const backend = store.backend();
    try backend.stage_page_fn(backend.context, .{
        .page_number = number,
        .offset_bytes = offset,
        .data = bytes,
    });
}

fn publish(
    store: *sqlite.Store,
    expected: ltx.ApplyCurrent,
    verified: ltx.VerifiedLTX,
) !void {
    const backend = store.backend();
    try backend.publish_fn(backend.context, expected, verified);
}

fn abort(store: *sqlite.Store) void {
    const backend = store.backend();
    backend.abort_fn(backend.context);
}

fn publish_empty_generation(store: *sqlite.Store, txid: u64) !sqlite.Current {
    const header = make_header(txid, txid, 0);
    const expected = try begin(store, make_plan(.contiguous, header));
    try publish(store, expected, make_verified(header));
    return (try store.current()).?;
}

fn expected_generation_uri(
    dir: std.Io.Dir,
    database_name: []const u8,
    output: []u8,
) ![:0]const u8 {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var path_length = try dir.realPath(std.testing.io, &path);
    const separator_length: usize = @intFromBool(
        path_length == 0 or path[path_length - 1] != '/',
    );
    const final_length = path_length + separator_length + database_name.len;
    if (final_length > path.len) return error.NameTooLong;
    if (separator_length == 1) {
        path[path_length] = '/';
        path_length += 1;
    }
    @memcpy(path[path_length..final_length], database_name);
    return encode_expected_sqlite_uri(path[0..final_length], output);
}

fn encode_expected_sqlite_uri(path: []const u8, output: []u8) ![:0]const u8 {
    const prefix = "file:";
    const query = "?mode=ro&immutable=1";
    if (output.len < prefix.len + query.len + 1) return error.NoSpaceLeft;
    @memcpy(output[0..prefix.len], prefix);
    var output_index = prefix.len;
    for (path) |byte| {
        const encoded_length: usize = if (is_expected_uri_path_byte(byte)) 1 else 3;
        if (output_index + encoded_length + query.len + 1 > output.len) {
            return error.NoSpaceLeft;
        }
        if (encoded_length == 1) {
            output[output_index] = byte;
        } else {
            output[output_index] = '%';
            output[output_index + 1] = "0123456789ABCDEF"[byte >> 4];
            output[output_index + 2] = "0123456789ABCDEF"[byte & 0x0f];
        }
        output_index += encoded_length;
    }
    @memcpy(output[output_index .. output_index + query.len], query);
    output_index += query.len;
    output[output_index] = 0;
    return output[0..output_index :0];
}

fn is_expected_uri_path_byte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

fn read_exact(file: std.Io.File, bytes: []u8, offset: u64) !void {
    const read = try file.readPositionalAll(std.testing.io, bytes, offset);
    try std.testing.expectEqual(bytes.len, read);
}

fn expect_missing(dir: std.Io.Dir, name: []const u8) !void {
    _ = dir.statFile(std.testing.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

const ReturnedFaultClass = enum {
    baseline,
    loaded_manifest,
    publish_precommit,
    publish_postcommit,
};

const returned_fault_cases = [_]struct {
    point: sqlite.FaultPoint,
    class: ReturnedFaultClass,
}{
    .{ .point = .baseline_manifest_sync, .class = .baseline },
    .{ .point = .baseline_directory_sync, .class = .baseline },
    .{ .point = .baseline_manifest_rename, .class = .baseline },
    .{ .point = .baseline_commit_directory_sync, .class = .baseline },
    .{ .point = .loaded_manifest_directory_sync, .class = .loaded_manifest },
    .{ .point = .database_sync, .class = .publish_precommit },
    .{ .point = .database_directory_sync, .class = .publish_precommit },
    .{ .point = .manifest_sync, .class = .publish_precommit },
    .{ .point = .manifest_directory_sync, .class = .publish_precommit },
    .{ .point = .manifest_rename, .class = .publish_postcommit },
    .{ .point = .commit_directory_sync, .class = .publish_postcommit },
};

comptime {
    const point_count = std.meta.fields(sqlite.FaultPoint).len;
    var seen: [point_count]bool = @splat(false);
    for (returned_fault_cases) |case| {
        mark_returned_fault_covered(&seen, case.point);
    }
    for (seen) |covered| {
        if (!covered) @compileError("SQLite returned fault point lacks coverage");
    }
}

fn mark_returned_fault_covered(seen: []bool, point: sqlite.FaultPoint) void {
    const index = @intFromEnum(point);
    if (seen[index]) @compileError("duplicate SQLite returned fault point");
    seen[index] = true;
}

fn seed_page_generation(
    store: *sqlite.Store,
    txid: u64,
    page: *const [page_size]u8,
) !sqlite.Current {
    const header = make_header(txid, txid, 1);
    const expected = try begin(store, make_plan(.contiguous, header));
    try stage(store, 1, 0, page);
    try publish(store, expected, make_verified(header));
    return (try store.current()).?;
}

fn expect_database_page(
    dir: std.Io.Dir,
    current: sqlite.Current,
    expected_page: *const [page_size]u8,
) !void {
    var file = try dir.openFile(std.testing.io, current.database_name(), .{
        .mode = .read_only,
        .follow_symlinks = false,
    });
    defer file.close(std.testing.io);

    var actual_page: [page_size]u8 = undefined;
    try read_exact(file, &actual_page, 0);
    try std.testing.expectEqualSlices(u8, expected_page, &actual_page);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, page_size), stat.size);
}

fn expect_exclusive_store_lock_held(dir: std.Io.Dir) !void {
    var observer_gate: Gate = .{};
    var observer_workspace: [47]u8 = undefined;
    var observer = try sqlite.Store.init(
        std.testing.io,
        dir,
        &observer_workspace,
        observer_gate.lifecycle(),
        .{},
    );
    try std.testing.expectError(error.StoreBusy, observer.current());
    try std.testing.expectEqual(sqlite.Failure.store_busy, observer.last_failure());
}

fn expected_page_current(slot: sqlite.Slot, generation: u64, txid: u64) sqlite.Current {
    return .{
        .position = .{ .txid = .init(txid), .post_apply_checksum = .init(0) },
        .page_size = page_size,
        .database_size_bytes = page_size,
        .generation = generation,
        .slot = slot,
    };
}

fn exercise_baseline_recovery_fault(point: sqlite.FaultPoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [47]u8 = undefined;
    var faults: sqlite.FaultInjection = .{ .fail_at = point };
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );

    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expectError(error.FaultInjected, store.recover());
    try std.testing.expectEqual(sqlite.StoreState.recovery_required, store.current_state());
    try std.testing.expect(gate.held);
    try std.testing.expectEqual(@as(u32, 1), gate.quiesce_count);
    try std.testing.expectEqual(@as(u32, 0), gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());
    try expect_exclusive_store_lock_held(temporary.dir);

    faults.fail_at = null;
    try std.testing.expectEqual(null, try store.recover());
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
    try std.testing.expectEqual(null, try store.current());
    const manifest_stat = try temporary.dir.statFile(
        std.testing.io,
        sqlite.manifest_name,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(@as(u64, 64), manifest_stat.size);
    try expect_missing(temporary.dir, sqlite.manifest_temporary_name);
    try expect_missing(temporary.dir, sqlite.database_a_name);
    try expect_missing(temporary.dir, sqlite.database_b_name);
}

fn exercise_baseline_begin_fault(point: sqlite.FaultPoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [47]u8 = undefined;
    var faults: sqlite.FaultInjection = .{ .fail_at = point };
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const page = make_sqlite_page(0x31);
    const header = make_header(1, 1, 1);

    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&store, make_plan(.contiguous, header)),
    );
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(@as(u32, 1), gate.quiesce_count);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());

    faults.fail_at = null;
    const current = try seed_page_generation(&store, 1, &page);
    try std.testing.expectEqual(expected_page_current(.a, 1, 1), current);
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
    try expect_database_page(temporary.dir, current, &page);
    try expect_missing(temporary.dir, sqlite.manifest_temporary_name);
}

fn exercise_loaded_manifest_recovery_fault(point: sqlite.FaultPoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [47]u8 = undefined;
    var faults: sqlite.FaultInjection = .{};
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const old_page = make_sqlite_page(0x11);
    const old_current = try seed_page_generation(&store, 1, &old_page);

    faults.fail_at = point;
    try std.testing.expectError(error.FaultInjected, store.recover());
    try std.testing.expectEqual(sqlite.StoreState.recovery_required, store.current_state());
    try std.testing.expect(gate.held);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());
    try expect_exclusive_store_lock_held(temporary.dir);

    faults.fail_at = null;
    try std.testing.expectEqual(old_current, (try store.recover()).?);
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
    try expect_database_page(temporary.dir, old_current, &old_page);
}

fn exercise_loaded_manifest_begin_fault(point: sqlite.FaultPoint) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [47]u8 = undefined;
    var faults: sqlite.FaultInjection = .{};
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const old_page = make_sqlite_page(0x41);
    const new_page = make_sqlite_page(0x42);
    const old_current = try seed_page_generation(&store, 1, &old_page);
    const header = make_header(2, 2, 1);

    faults.fail_at = point;
    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&store, make_plan(.contiguous, header)),
    );
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());

    var observer_gate: Gate = .{};
    var observer_workspace: [47]u8 = undefined;
    var observer = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &observer_workspace,
        observer_gate.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(old_current, (try observer.current()).?);
    try expect_database_page(temporary.dir, old_current, &old_page);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());

    faults.fail_at = null;
    const current = try seed_page_generation(&store, 2, &new_page);
    try std.testing.expectEqual(expected_page_current(.b, 2, 2), current);
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
    try expect_database_page(temporary.dir, current, &new_page);
}

fn exercise_publish_fault(point: sqlite.FaultPoint, postcommit: bool) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [47]u8 = undefined;
    var faults: sqlite.FaultInjection = .{};
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const old_page = make_sqlite_page(0x11);
    const new_page = make_sqlite_page(0x22);
    const old_current = try seed_page_generation(&store, 1, &old_page);

    faults.fail_at = point;
    const header = make_header(2, 2, 1);
    const expected = try begin(&store, make_plan(.contiguous, header));
    try std.testing.expectEqual(sqlite.StoreState.staging, store.current_state());
    try stage(&store, 1, 0, &new_page);
    const verified = make_verified(header);

    if (!postcommit) {
        try std.testing.expectError(error.ApplyPublishFailure, publish(&store, expected, verified));
        try std.testing.expectEqual(sqlite.StoreState.staging, store.current_state());
        try std.testing.expect(gate.held);
        try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());
        try expect_exclusive_store_lock_held(temporary.dir);
        abort(&store);
        try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
        try std.testing.expect(!gate.held);
        try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
        try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());

        var observer_gate: Gate = .{};
        var observer_workspace: [47]u8 = undefined;
        var observer = try sqlite.Store.init(
            std.testing.io,
            temporary.dir,
            &observer_workspace,
            observer_gate.lifecycle(),
            .{},
        );
        try std.testing.expectEqual(old_current, (try observer.current()).?);
        try expect_database_page(temporary.dir, old_current, &old_page);
        try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());
        return;
    }

    try std.testing.expectError(error.ApplyPublishIndeterminate, publish(&store, expected, verified));
    try std.testing.expectEqual(sqlite.StoreState.recovery_required, store.current_state());
    try std.testing.expect(gate.held);
    try std.testing.expectEqual(@as(u32, 2), gate.quiesce_count);
    try std.testing.expectEqual(@as(u32, 1), gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.fault_injected, store.last_failure());
    try expect_exclusive_store_lock_held(temporary.dir);

    faults.fail_at = null;
    const expected_new = expected_page_current(.b, 2, 2);
    const recovered = (try store.recover()).?;
    try std.testing.expectEqual(expected_new, recovered);
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
    try expect_database_page(temporary.dir, recovered, &new_page);
}

test "returned faults preserve canonical SQLite store state" {
    for (returned_fault_cases) |case| {
        switch (case.class) {
            .baseline => {
                try exercise_baseline_recovery_fault(case.point);
                try exercise_baseline_begin_fault(case.point);
            },
            .loaded_manifest => {
                try exercise_loaded_manifest_recovery_fault(case.point);
                try exercise_loaded_manifest_begin_fault(case.point);
            },
            .publish_precommit => try exercise_publish_fault(case.point, false),
            .publish_postcommit => try exercise_publish_fault(case.point, true),
        }
    }
}

test "publish outside staging records invalid state" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [31]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{},
    );
    const header = make_header(1, 1, 0);
    const empty = ltx.ApplyCurrent{
        .position = .{ .txid = .init(0), .post_apply_checksum = .init(0) },
        .page_size = null,
    };

    try std.testing.expectError(
        error.ApplyPublishFailure,
        publish(&store, empty, make_verified(header)),
    );
    try std.testing.expectEqual(sqlite.StoreState.idle, store.current_state());
    try std.testing.expectEqual(sqlite.Failure.invalid_state, store.last_failure());
    try std.testing.expectEqual(null, try store.current());
    try std.testing.expectEqual(sqlite.Failure.none, store.last_failure());
}

test "recovery durably initializes a pristine store" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first_gate: Gate = .{};
    var first_workspace: [17]u8 = undefined;
    var first = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &first_workspace,
        first_gate.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(null, try first.current());
    try std.testing.expectEqual(null, try first.recover());
    const manifest_stat = try temporary.dir.statFile(
        std.testing.io,
        sqlite.manifest_name,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(@as(u64, 64), manifest_stat.size);
    try expect_missing(temporary.dir, sqlite.database_a_name);
    try expect_missing(temporary.dir, sqlite.database_b_name);

    var second_gate: Gate = .{};
    var second_workspace: [19]u8 = undefined;
    var second = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &second_workspace,
        second_gate.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(null, try second.current());
    try std.testing.expectEqual(null, try second.recover());
}

test "interrupted empty initialization and first stage recover automatically" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var partial = try temporary.dir.createFile(
        std.testing.io,
        sqlite.manifest_temporary_name,
        .{},
    );
    try partial.writePositionalAll(std.testing.io, "partial", 0);
    partial.close(std.testing.io);

    var gate: Gate = .{};
    var workspace: [23]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(null, try store.recover());

    var staged = try temporary.dir.createFile(std.testing.io, sqlite.database_a_name, .{});
    try staged.writePositionalAll(std.testing.io, "incomplete", 0);
    staged.close(std.testing.io);
    var next_manifest = try temporary.dir.createFile(
        std.testing.io,
        sqlite.manifest_temporary_name,
        .{},
    );
    try next_manifest.writePositionalAll(std.testing.io, "uncommitted", 0);
    next_manifest.close(std.testing.io);

    try std.testing.expectEqual(null, try store.recover());
    try expect_missing(temporary.dir, sqlite.database_a_name);
    try expect_missing(temporary.dir, sqlite.manifest_temporary_name);
}

test "empty recovery rejects sidecars before cleaning an abandoned first stage" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [29]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{},
    );
    try std.testing.expectEqual(null, try store.recover());
    var staged = try temporary.dir.createFile(std.testing.io, sqlite.database_a_name, .{});
    staged.close(std.testing.io);
    var sidecar = try temporary.dir.createFile(std.testing.io, "ltx.sqlite.a-wal", .{});
    sidecar.close(std.testing.io);

    try std.testing.expectError(error.SidecarPresent, store.recover());
    try std.testing.expect(gate.held);
    try temporary.dir.deleteFile(std.testing.io, "ltx.sqlite.a-wal");
    try std.testing.expectEqual(null, try store.recover());
    try std.testing.expect(!gate.held);
    try expect_missing(temporary.dir, sqlite.database_a_name);
}

test "empty store accepts only a snapshot and abort preserves its baseline" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var workspace: [31]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &workspace,
        gate.lifecycle(),
        .{},
    );
    const incremental = make_header(2, 2, 1);
    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&store, make_plan(.contiguous, incremental)),
    );
    try std.testing.expectEqual(sqlite.Failure.database_missing, store.last_failure());
    try expect_missing(temporary.dir, sqlite.database_a_name);

    const snapshot = make_header(1, 1, 1);
    _ = try begin(&store, make_plan(.contiguous, snapshot));
    _ = try temporary.dir.statFile(
        std.testing.io,
        sqlite.manifest_name,
        .{ .follow_symlinks = false },
    );
    abort(&store);
    try std.testing.expectEqual(null, try store.current());
    try expect_missing(temporary.dir, sqlite.database_a_name);
}

test "snapshot and incremental publication alternate exact SQLite generations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [73]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );

    const snapshot_header = make_header(1, 1, 1);
    const initial = try begin(&store, make_plan(.contiguous, snapshot_header));
    try std.testing.expectEqual(@as(u64, 0), initial.position.txid.value);
    try std.testing.expectEqual(null, initial.page_size);
    const first_page = make_sqlite_page(0x11);
    try stage(&store, 1, 0, &first_page);
    try publish(&store, initial, make_verified(snapshot_header));

    const first = (try store.current()).?;
    try std.testing.expectEqual(sqlite.Slot.a, first.slot);
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    const incremental_header = make_header(2, 2, 2);
    const current = try begin(&store, make_plan(.replace_snapshot, incremental_header));
    var cloned_page: [page_size]u8 = undefined;
    const backend = store.backend();
    try backend.read_page_fn(backend.context, 1, &cloned_page);
    try std.testing.expectEqualSlices(u8, &first_page, &cloned_page);
    var expanded_first_page = first_page;
    std.mem.writeInt(u32, expanded_first_page[24..28], 2, .big);
    std.mem.writeInt(u32, expanded_first_page[28..32], 2, .big);
    std.mem.writeInt(u32, expanded_first_page[32..36], 2, .big);
    std.mem.writeInt(u32, expanded_first_page[36..40], 1, .big);
    std.mem.writeInt(u32, expanded_first_page[92..96], 2, .big);
    try stage(&store, 1, 0, &expanded_first_page);
    const second_page: [page_size]u8 = @splat(0);
    try stage(&store, 2, page_size, &second_page);
    try publish(&store, current, make_verified(incremental_header));

    const second = (try store.current()).?;
    try std.testing.expectEqual(sqlite.Slot.b, second.slot);
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    var opened = try temporary.dir.openFile(
        std.testing.io,
        second.database_name(),
        .{ .mode = .read_only },
    );
    var database: [page_size * 2]u8 = undefined;
    try read_exact(opened, &database, 0);
    try std.testing.expectEqualSlices(u8, &expanded_first_page, database[0..page_size]);
    try std.testing.expectEqualSlices(u8, &second_page, database[page_size..]);
    opened.close(std.testing.io);

    const shrink_header = make_header(3, 3, 1);
    const shrink_current = try begin(&store, make_plan(.contiguous, shrink_header));
    var shrunk_page: [page_size]u8 = undefined;
    const shrink_backend = store.backend();
    try shrink_backend.read_page_fn(shrink_backend.context, 1, &shrunk_page);
    try std.testing.expectEqualSlices(u8, &expanded_first_page, &shrunk_page);
    try stage(&store, 1, 0, &first_page);
    try publish(&store, shrink_current, make_verified(shrink_header));
    const shrunk = (try store.current()).?;
    try std.testing.expectEqual(@as(u64, page_size), shrunk.database_size_bytes);
    try std.testing.expectEqual(@as(u32, 3), gate.quiesce_count);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
}

test "store lock and lifecycle failures do not leak ownership" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first_gate: Gate = .{};
    var second_gate: Gate = .{};
    var first_copy: [32]u8 = undefined;
    var second_copy: [32]u8 = undefined;
    var first = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &first_copy,
        first_gate.lifecycle(),
        .{},
    );
    var second = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &second_copy,
        second_gate.lifecycle(),
        .{},
    );
    const plan = make_plan(.contiguous, make_header(1, 1, 0));
    _ = try begin(&first, plan);
    try std.testing.expectError(error.StoreBusy, second.current());
    try std.testing.expectEqual(sqlite.Failure.store_busy, second.last_failure());
    try std.testing.expectError(error.ApplyBeginFailure, begin(&second, plan));
    try std.testing.expectEqual(sqlite.Failure.store_busy, second.last_failure());
    try std.testing.expectEqual(sqlite.StoreState.idle, second.current_state());
    try std.testing.expectEqual(second_gate.quiesce_count, second_gate.release_count);
    abort(&first);

    second_gate.fail = true;
    try std.testing.expectError(error.ApplyBeginFailure, begin(&second, plan));
    try std.testing.expectEqual(sqlite.Failure.quiesce_failure, second.last_failure());
    try std.testing.expectEqual(sqlite.StoreState.idle, second.current_state());
    try std.testing.expectEqual(second_gate.quiesce_count, second_gate.release_count);
    second_gate.fail = false;
    _ = try begin(&first, plan);
    abort(&first);
    try std.testing.expect(!first_gate.held);
    try std.testing.expect(!second_gate.held);
}

test "backend rejects invalid plans and inconsistent page offsets" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [32]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    var invalid_header = make_header(1, 1, 1);
    invalid_header.page_size = 0;
    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&store, .{
            .format_version = .v3,
            .mode = .contiguous,
            .header = invalid_header,
            .final_database_size_bytes = 0,
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), gate.quiesce_count);

    const header = make_header(1, 1, 1);
    _ = try begin(&store, make_plan(.contiguous, header));
    const page = make_sqlite_page(0);
    const backend = store.backend();
    try std.testing.expectError(error.ApplyStageFailure, backend.stage_page_fn(
        backend.context,
        .{ .page_number = 1, .offset_bytes = 1, .data = &page },
    ));
    abort(&store);
}

test "sidecars and invalid SQLite headers fail before publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [64]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const header = make_header(1, 1, 1);
    const initial = try begin(&store, make_plan(.contiguous, header));
    const bad_page: [page_size]u8 = @splat(0xa5);
    try stage(&store, 1, 0, &bad_page);
    try std.testing.expectError(error.ApplyPublishFailure, publish(&store, initial, make_verified(header)));
    try std.testing.expectEqual(sqlite.Failure.invalid_sqlite_database, store.last_failure());
    abort(&store);

    const mismatched_header = make_header(1, 1, 2);
    const mismatched = try begin(&store, make_plan(.contiguous, mismatched_header));
    const one_page_header = make_sqlite_page(0);
    const empty_page: [page_size]u8 = @splat(0);
    try stage(&store, 1, 0, &one_page_header);
    try stage(&store, 2, page_size, &empty_page);
    try std.testing.expectError(
        error.ApplyPublishFailure,
        publish(&store, mismatched, make_verified(mismatched_header)),
    );
    try std.testing.expectEqual(sqlite.Failure.invalid_sqlite_database, store.last_failure());
    abort(&store);

    const retry = try begin(&store, make_plan(.contiguous, header));
    const page = make_sqlite_page(0);
    try stage(&store, 1, 0, &page);
    try publish(&store, retry, make_verified(header));
    const active = (try store.current()).?.database_name();
    const sidecar = if (std.mem.eql(u8, active, sqlite.database_a_name))
        "ltx.sqlite.a-wal"
    else
        "ltx.sqlite.b-wal";
    var file = try temporary.dir.createFile(std.testing.io, sidecar, .{});
    file.close(std.testing.io);
    const next_header = make_header(2, 2, 1);
    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&store, make_plan(.contiguous, next_header)),
    );
    try std.testing.expectEqual(sqlite.Failure.sidecar_present, store.last_failure());
    try temporary.dir.deleteFile(std.testing.io, sidecar);
    _ = try store.recover();

    const inactive_sidecar = if (std.mem.eql(u8, active, sqlite.database_a_name))
        "ltx.sqlite.b-shm"
    else
        "ltx.sqlite.a-shm";
    var inactive_file = try temporary.dir.createFile(std.testing.io, inactive_sidecar, .{});
    inactive_file.close(std.testing.io);
    try std.testing.expectError(error.SidecarPresent, store.recover());
    try std.testing.expect(gate.held);
    try temporary.dir.deleteFile(std.testing.io, inactive_sidecar);
    _ = try store.recover();
    try std.testing.expect(!gate.held);
}

test "pre-rename failure aborts while post-rename failure requires recovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [31]u8 = undefined;
    var faults: sqlite.FaultInjection = .{ .fail_before_manifest_rename = true };
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const header = make_header(1, 1, 0);
    const initial = try begin(&store, make_plan(.contiguous, header));
    try std.testing.expectError(error.ApplyPublishFailure, publish(&store, initial, make_verified(header)));
    try std.testing.expect(gate.held);
    abort(&store);
    try std.testing.expectEqual(null, try store.current());

    faults.fail_before_manifest_rename = false;
    faults.fail_at = .manifest_rename;
    const retry = try begin(&store, make_plan(.contiguous, header));
    try std.testing.expectError(
        error.ApplyPublishIndeterminate,
        publish(&store, retry, make_verified(header)),
    );
    try std.testing.expect(gate.held);
    try std.testing.expectError(error.InvalidState, store.current());
    faults.fail_at = null;
    const recovered = (try store.recover()).?;
    try std.testing.expectEqual(@as(u64, 1), recovered.generation);
    try std.testing.expectEqual(@as(u64, 1), recovered.position.txid.value);
    try std.testing.expect(!gate.held);

    faults.fail_after_manifest_rename = true;
    const next_header = make_header(2, 2, 0);
    const next = try begin(&store, make_plan(.contiguous, next_header));
    try std.testing.expectError(
        error.ApplyPublishIndeterminate,
        publish(&store, next, make_verified(next_header)),
    );
    faults.fail_after_manifest_rename = false;
    const recovered_next = (try store.recover()).?;
    try std.testing.expectEqual(@as(u64, 2), recovered_next.generation);
    try std.testing.expectEqual(@as(u64, 2), recovered_next.position.txid.value);
    try std.testing.expect(!gate.held);
}

test "manifest checksum corruption is reported without guessing a generation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [64]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const header = make_header(1, 1, 0);
    const initial = try begin(&store, make_plan(.contiguous, header));
    try publish(&store, initial, make_verified(header));
    var manifest = try temporary.dir.openFile(
        std.testing.io,
        sqlite.manifest_name,
        .{ .mode = .read_write },
    );
    defer manifest.close(std.testing.io);
    try manifest.writePositionalAll(std.testing.io, "X", 0);
    try std.testing.expectError(error.ManifestCorrupt, store.current());
    try std.testing.expectEqual(sqlite.Failure.manifest_corrupt, store.last_failure());
}

test "missing manifest with a generation fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var orphan = try temporary.dir.createFile(std.testing.io, sqlite.database_a_name, .{});
    orphan.close(std.testing.io);
    var gate: Gate = .{};
    var copy_workspace: [32]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    try std.testing.expectError(error.ManifestCorrupt, store.current());
    try std.testing.expectError(error.ManifestCorrupt, store.recover());
    try std.testing.expectEqual(sqlite.Failure.manifest_corrupt, store.last_failure());
    try std.testing.expect(gate.held);
    try temporary.dir.deleteFile(std.testing.io, sqlite.database_a_name);
    try std.testing.expectEqual(null, try store.recover());
    try std.testing.expect(!gate.held);
}

test "StagedApplier publishes and recovery detects checksummed database mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [37]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const page = make_sqlite_page(0x42);
    var encoded: [800]u8 = undefined;
    const encoded_length = try encode_snapshot(&encoded, &page);
    var source = ltx.SliceReader.init(encoded[0..encoded_length]);
    var page_workspace: [page_size]u8 = undefined;
    var compressed_workspace: [530]u8 = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        codec_limits,
        .{ .max_database_pages = 1, .max_database_bytes = page_size },
        .contiguous,
        source.reader(),
        store.backend(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    const verified = try applier.apply();
    try std.testing.expect(verified.trailer.post_apply_checksum.has_valid_flag());
    const recovered = (try store.recover()).?;
    try std.testing.expectEqual(verified.post_apply_position(), recovered.position);

    var database = try temporary.dir.openFile(
        std.testing.io,
        recovered.database_name(),
        .{ .mode = .read_write, .follow_symlinks = false },
    );
    try database.writePositionalAll(std.testing.io, "X", 200);
    database.close(std.testing.io);
    try std.testing.expectError(error.DatabaseChecksumMismatch, store.recover());
    try std.testing.expectEqual(sqlite.Failure.database_checksum_mismatch, store.last_failure());
    try std.testing.expect(gate.held);
    var repaired = try temporary.dir.openFile(
        std.testing.io,
        recovered.database_name(),
        .{ .mode = .read_write, .follow_symlinks = false },
    );
    try repaired.writePositionalAll(std.testing.io, &[_]u8{0x42}, 200);
    repaired.close(std.testing.io);
    try std.testing.expectEqual(recovered, (try store.recover()).?);
    try std.testing.expect(!gate.held);
}

test "generation access returns null for empty state and unwinds for reuse" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [31]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    var access_storage: sqlite.GenerationAccessStorage = .{};
    var access_workspace: sqlite.GenerationAccessWorkspace = .{};

    try std.testing.expectEqual(
        null,
        try store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(null, try store.current());
    try std.testing.expectEqual(@as(u32, 0), gate.quiesce_count);

    var orphan = try temporary.dir.createFile(std.testing.io, sqlite.database_a_name, .{});
    orphan.close(std.testing.io);
    try std.testing.expectError(
        error.ManifestCorrupt,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.manifest_corrupt, store.last_failure());
    try temporary.dir.deleteFile(std.testing.io, sqlite.database_a_name);

    try std.testing.expectEqual(
        null,
        try store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(null, try store.recover());
    try std.testing.expectEqual(
        null,
        try store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
}

test "generation access rejects an absolute slot path beyond the OS bound" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_path: [sqlite.max_generation_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &absolute_path);
    const target_length = sqlite.max_generation_path_bytes - sqlite.database_a_name.len;
    if (root_length + 2 >= target_length) return error.SkipZigTest;

    var current_dir = temporary.dir;
    var current_dir_owned = false;
    defer if (current_dir_owned) current_dir.close(std.testing.io);
    var current_length = root_length;
    const component_bytes: [200]u8 = @splat('d');
    var depth: usize = 0;
    while (current_length < target_length and
        depth < sqlite.max_generation_path_bytes) : (depth += 1)
    {
        const remaining = target_length - current_length;
        if (remaining < 2) return error.TestUnexpectedResult;
        var component_length = @min(component_bytes.len, remaining - 1);
        if (remaining - (component_length + 1) == 1) component_length -= 1;
        const component = component_bytes[0..component_length];
        // Some mounted filesystems impose a lower path bound than the host OS.
        current_dir.createDir(std.testing.io, component, .default_dir) catch |err| switch (err) {
            error.NameTooLong => return error.SkipZigTest,
            else => return err,
        };
        const next_dir = current_dir.openDir(std.testing.io, component, .{}) catch |err| switch (err) {
            error.NameTooLong => return error.SkipZigTest,
            else => return err,
        };
        if (current_dir_owned) current_dir.close(std.testing.io);
        current_dir = next_dir;
        current_dir_owned = true;
        current_length += 1 + component_length;
    }
    try std.testing.expectEqual(target_length, current_length);

    var gate: Gate = .{};
    var copy_workspace: [31]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        current_dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const current = try publish_empty_generation(&store, 1);
    try std.testing.expectEqual(sqlite.Slot.a, current.slot);
    var access_storage: sqlite.GenerationAccessStorage = .{};
    var access_workspace: sqlite.GenerationAccessWorkspace = .{};
    try std.testing.expectError(
        error.InvalidDatabasePath,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(
        sqlite.Failure.invalid_database_path,
        store.last_failure(),
    );
    try std.testing.expectEqual(current, (try store.current()).?);
}

test "generation access exposes exact SQLite spec and copied handles release once" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const special_name = "access space?#%utf8\xc3\xa9";
    try temporary.dir.createDir(std.testing.io, special_name, .default_dir);
    var generation_dir = try temporary.dir.openDir(std.testing.io, special_name, .{});
    defer generation_dir.close(std.testing.io);
    var gate: Gate = .{};
    var copy_workspace: [37]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        generation_dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const first = try publish_empty_generation(&store, 1);
    var access_storage: sqlite.GenerationAccessStorage = .{};
    var access_workspace: sqlite.GenerationAccessWorkspace = .{};
    var access = (try store.acquire_generation(&access_storage, &access_workspace)).?;
    var copied = access;

    try std.testing.expectEqual(first, try access.current());
    const spec = try access.sqlite_open_spec();
    var expected_bytes: [std.Io.Dir.max_path_bytes * 3 + 32]u8 = undefined;
    const expected = try expected_generation_uri(
        generation_dir,
        first.database_name(),
        &expected_bytes,
    );
    try std.testing.expectEqualStrings(expected, spec.uri);
    try std.testing.expectEqual(@as(c_int, 0x0000_0001 | 0x0000_0040), spec.required_flags);
    try std.testing.expectEqualStrings("PRAGMA query_only=ON", spec.query_only_sql);
    try std.testing.expectEqual(@as(u8, 0), access_workspace.uri_bytes[spec.uri.len]);
    try std.testing.expectError(
        error.InvalidState,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(first, try access.current());

    try access.release();
    try std.testing.expectError(error.InvalidState, access.release());
    try std.testing.expectError(error.InvalidState, copied.release());
    try std.testing.expectError(error.InvalidState, copied.current());
    try std.testing.expectError(error.InvalidState, copied.sqlite_open_spec());

    var reacquired = (try store.acquire_generation(&access_storage, &access_workspace)).?;
    try std.testing.expectError(error.InvalidState, copied.release());
    try std.testing.expectEqual(first, try reacquired.current());
    try reacquired.release();

    const second = try publish_empty_generation(&store, 2);
    var newest = (try store.acquire_generation(&access_storage, &access_workspace)).?;
    try std.testing.expectEqual(second, try newest.current());
    try std.testing.expectError(error.InvalidState, copied.release());
    try newest.release();
}

test "shared generation accesses coexist and block exclusive store operations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first_gate: Gate = .{};
    var first_copy: [41]u8 = undefined;
    var first_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &first_copy,
        first_gate.lifecycle(),
        .{},
    );
    const first = try publish_empty_generation(&first_store, 1);
    var second_gate: Gate = .{};
    var second_copy: [43]u8 = undefined;
    var second_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &second_copy,
        second_gate.lifecycle(),
        .{},
    );
    var first_storage: sqlite.GenerationAccessStorage = .{};
    var second_storage: sqlite.GenerationAccessStorage = .{};
    var first_uri: sqlite.GenerationAccessWorkspace = .{};
    var second_uri: sqlite.GenerationAccessWorkspace = .{};
    var first_access = (try first_store.acquire_generation(&first_storage, &first_uri)).?;
    var second_access = (try first_store.acquire_generation(&second_storage, &second_uri)).?;

    try std.testing.expectEqual(first, try first_store.current());
    try std.testing.expectEqual(first, try second_store.current());
    try std.testing.expectEqual(first, try first_access.current());
    try std.testing.expectEqual(first, try second_access.current());
    const next_header = make_header(2, 2, 0);
    try std.testing.expectError(
        error.ApplyBeginFailure,
        begin(&second_store, make_plan(.contiguous, next_header)),
    );
    try std.testing.expectEqual(sqlite.Failure.store_busy, second_store.last_failure());
    try std.testing.expect(!second_gate.held);

    try std.testing.expectError(error.StoreBusy, second_store.recover());
    try std.testing.expect(second_gate.held);
    try first_access.release();
    try std.testing.expectError(error.StoreBusy, second_store.recover());
    try second_access.release();
    try std.testing.expectEqual(first, (try second_store.recover()).?);
    try std.testing.expect(!second_gate.held);

    const expected = try begin(&second_store, make_plan(.contiguous, next_header));
    try std.testing.expectEqual(first.position, expected.position);
    abort(&second_store);
}

test "generation access rejects active sidecars and invalid selected databases" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [47]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const header = make_header(1, 1, 1);
    const initial = try begin(&store, make_plan(.contiguous, header));
    const page = make_sqlite_page(0x51);
    try stage(&store, 1, 0, &page);
    try publish(&store, initial, make_verified(header));
    const current = (try store.current()).?;
    const sidecar_name = if (current.slot == .a) "ltx.sqlite.a-wal" else "ltx.sqlite.b-wal";
    var sidecar = try temporary.dir.createFile(std.testing.io, sidecar_name, .{});
    sidecar.close(std.testing.io);
    var access_storage: sqlite.GenerationAccessStorage = .{};
    var access_workspace: sqlite.GenerationAccessWorkspace = .{};

    try std.testing.expectError(
        error.SidecarPresent,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.sidecar_present, store.last_failure());
    try temporary.dir.deleteFile(std.testing.io, sidecar_name);
    var access = (try store.acquire_generation(&access_storage, &access_workspace)).?;
    try std.testing.expectEqual(current, try access.current());
    try access.release();

    const saved_database_name = "saved-generation.sqlite";
    try temporary.dir.rename(
        current.database_name(),
        temporary.dir,
        saved_database_name,
        std.testing.io,
    );
    try std.testing.expectError(
        error.DatabaseMissing,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    try temporary.dir.rename(
        saved_database_name,
        temporary.dir,
        current.database_name(),
        std.testing.io,
    );

    var database = try temporary.dir.openFile(std.testing.io, current.database_name(), .{
        .mode = .read_write,
        .follow_symlinks = false,
    });
    try database.writePositionalAll(std.testing.io, "X", 0);
    database.close(std.testing.io);
    try std.testing.expectError(
        error.InvalidSQLiteDatabase,
        store.acquire_generation(&access_storage, &access_workspace),
    );
    database = try temporary.dir.openFile(std.testing.io, current.database_name(), .{
        .mode = .read_write,
        .follow_symlinks = false,
    });
    try database.writePositionalAll(std.testing.io, "S", 0);
    database.close(std.testing.io);
    access = (try store.acquire_generation(&access_storage, &access_workspace)).?;
    try access.release();
}

test "generation access rejects state and output workspace aliasing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var gate: Gate = .{};
    var copy_workspace: [61]u8 = undefined;
    const StoreWorkspaceAlias = union {
        store: sqlite.Store,
        workspace: sqlite.GenerationAccessWorkspace,
    };
    var aliased: StoreWorkspaceAlias = .{ .store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    ) };
    var storage: sqlite.GenerationAccessStorage = .{};
    const aliased_workspace: *sqlite.GenerationAccessWorkspace = @ptrCast(&aliased);
    try std.testing.expectError(
        error.InvalidWorkspace,
        aliased.store.acquire_generation(&storage, aliased_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.invalid_workspace, aliased.store.last_failure());

    var valid_workspace: sqlite.GenerationAccessWorkspace = .{};
    const store_storage: *sqlite.GenerationAccessStorage = @ptrCast(@alignCast(&aliased.store));
    try std.testing.expectError(
        error.InvalidWorkspace,
        aliased.store.acquire_generation(store_storage, &valid_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.invalid_workspace, aliased.store.last_failure());

    var overlap_bytes: [
        @max(
            @sizeOf(sqlite.GenerationAccessStorage),
            @sizeOf(sqlite.GenerationAccessWorkspace),
        )
    ]u8 align(@max(
        @alignOf(sqlite.GenerationAccessStorage),
        @alignOf(sqlite.GenerationAccessWorkspace),
    )) = undefined;
    const overlap_storage: *sqlite.GenerationAccessStorage = @ptrCast(&overlap_bytes);
    const overlap_workspace: *sqlite.GenerationAccessWorkspace = @ptrCast(&overlap_bytes);
    overlap_workspace.* = .{};
    try std.testing.expectError(
        error.InvalidWorkspace,
        aliased.store.acquire_generation(overlap_storage, overlap_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.invalid_workspace, aliased.store.last_failure());

    try std.testing.expectEqual(
        null,
        try aliased.store.acquire_generation(&storage, &valid_workspace),
    );
    try std.testing.expectEqual(sqlite.Failure.none, aliased.store.last_failure());
}

test "generation access rejects overlap with the store copy workspace" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var storage_backing: sqlite.GenerationAccessStorage = .{};
    var first_gate: Gate = .{};
    var first_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        std.mem.asBytes(&storage_backing),
        first_gate.lifecycle(),
        .{},
    );
    var first_workspace: sqlite.GenerationAccessWorkspace = .{};
    try std.testing.expectError(
        error.InvalidWorkspace,
        first_store.acquire_generation(&storage_backing, &first_workspace),
    );
    var valid_storage: sqlite.GenerationAccessStorage = .{};
    try std.testing.expectEqual(
        null,
        try first_store.acquire_generation(&valid_storage, &first_workspace),
    );

    var workspace_backing: sqlite.GenerationAccessWorkspace = .{};
    var second_gate: Gate = .{};
    var second_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        std.mem.asBytes(&workspace_backing),
        second_gate.lifecycle(),
        .{},
    );
    var second_storage: sqlite.GenerationAccessStorage = .{};
    try std.testing.expectError(
        error.InvalidWorkspace,
        second_store.acquire_generation(&second_storage, &workspace_backing),
    );
    var valid_workspace: sqlite.GenerationAccessWorkspace = .{};
    try std.testing.expectEqual(
        null,
        try second_store.acquire_generation(&second_storage, &valid_workspace),
    );
}

test "indeterminate publication retains exclusive lock until recovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first_gate: Gate = .{};
    var first_copy: [53]u8 = undefined;
    var faults: sqlite.FaultInjection = .{ .fail_at = .manifest_rename };
    var first_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &first_copy,
        first_gate.lifecycle(),
        .{ .fault_injection = &faults },
    );
    const header = make_header(1, 1, 0);
    const initial = try begin(&first_store, make_plan(.contiguous, header));
    try std.testing.expectError(
        error.ApplyPublishIndeterminate,
        publish(&first_store, initial, make_verified(header)),
    );
    try std.testing.expect(first_gate.held);
    var first_storage: sqlite.GenerationAccessStorage = .{};
    var first_uri: sqlite.GenerationAccessWorkspace = .{};
    try std.testing.expectError(
        error.InvalidState,
        first_store.acquire_generation(&first_storage, &first_uri),
    );

    var second_gate: Gate = .{};
    var second_copy: [59]u8 = undefined;
    var second_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &second_copy,
        second_gate.lifecycle(),
        .{},
    );
    var second_storage: sqlite.GenerationAccessStorage = .{};
    var second_uri: sqlite.GenerationAccessWorkspace = .{};
    try std.testing.expectError(
        error.StoreBusy,
        second_store.acquire_generation(&second_storage, &second_uri),
    );
    try std.testing.expectError(error.StoreBusy, second_store.current());
    try std.testing.expectError(error.StoreBusy, second_store.recover());
    try std.testing.expect(second_gate.held);

    faults.fail_at = null;
    const recovered = (try first_store.recover()).?;
    try std.testing.expectEqual(@as(u64, 1), recovered.generation);
    try std.testing.expect(!first_gate.held);
    try std.testing.expectEqual(recovered, (try second_store.recover()).?);
    try std.testing.expect(!second_gate.held);
    var access = (try second_store.acquire_generation(&second_storage, &second_uri)).?;
    try std.testing.expectEqual(recovered, try access.current());
    try access.release();
}
