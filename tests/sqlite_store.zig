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

fn read_exact(file: std.Io.File, bytes: []u8, offset: u64) !void {
    const read = try file.readPositionalAll(std.testing.io, bytes, offset);
    try std.testing.expectEqual(bytes.len, read);
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
    abort(&first);

    second_gate.fail = true;
    try std.testing.expectError(error.ApplyBeginFailure, begin(&second, plan));
    try std.testing.expectEqual(sqlite.Failure.quiesce_failure, second.last_failure());
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
    faults.fail_after_manifest_rename = true;
    const retry = try begin(&store, make_plan(.contiguous, header));
    try std.testing.expectError(
        error.ApplyPublishIndeterminate,
        publish(&store, retry, make_verified(header)),
    );
    try std.testing.expect(gate.held);
    try std.testing.expectError(error.InvalidState, store.current());
    faults.fail_after_manifest_rename = false;
    const recovered = (try store.recover()).?;
    try std.testing.expectEqual(@as(u64, 1), recovered.generation);
    try std.testing.expectEqual(@as(u64, 1), recovered.position.txid.value);
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
}
