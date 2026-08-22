const std = @import("std");
const ltx = @import("ltx");
const sqlite_store = @import("ltx_sqlite");

const page_size_bytes: usize = 512;
const encoded_capacity_bytes: usize = 800;
const compressed_capacity_bytes: usize = 530;

const codec_limits = ltx.Limits{
    .max_input_bytes = encoded_capacity_bytes,
    .max_output_bytes = encoded_capacity_bytes,
    .max_pages = 1,
    .max_page_size = page_size_bytes,
    .max_compressed_page_size = compressed_capacity_bytes,
    .max_page_index_bytes = 32,
    .max_page_index_entries = 1,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const apply_limits = ltx.ApplyLimits{
    .max_database_pages = 1,
    .max_database_bytes = page_size_bytes,
};

const Gate = struct {
    held: bool = false,
    quiesce_count: u8 = 0,
    release_count: u8 = 0,

    fn lifecycle(self: *Gate) sqlite_store.Lifecycle {
        return .{
            .context = self,
            .quiesce_fn = quiesce,
            .release_fn = release,
        };
    }

    fn quiesce(context: *anyopaque) error{QuiesceFailure}!void {
        const self: *Gate = @ptrCast(@alignCast(context));
        if (self.held) return error.QuiesceFailure;
        // A host closes all admitted SQLite resources before returning here.
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

const TemporaryDirectory = struct {
    const prefix = "ltx-zig-store-example-";
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
    var temporary = try TemporaryDirectory.create(init.io);
    defer temporary.cleanup(init.io);

    var gate: Gate = .{};
    var copy_workspace: [128]u8 = undefined;
    var store = try sqlite_store.Store.init(
        init.io,
        temporary.dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    if (try store.recover() != null) return error.ExpectedEmptyStore;

    const sqlite_page = make_sqlite_page();
    var encoded_bytes: [encoded_capacity_bytes]u8 = @splat(0);
    const encoded_length = try encode_snapshot(&encoded_bytes, &sqlite_page);
    const verified = try apply_snapshot(&store, encoded_bytes[0..encoded_length]);
    const current = (try store.current()) orelse return error.MissingGeneration;
    if (!std.meta.eql(current.position, verified.post_apply_position())) {
        return error.GenerationPositionMismatch;
    }

    var access_storage: sqlite_store.GenerationAccessStorage = .{};
    var access_workspace: sqlite_store.GenerationAccessWorkspace = .{};
    var access = (try store.acquire_generation(
        &access_storage,
        &access_workspace,
    )) orelse return error.MissingGeneration;
    var access_held = true;
    defer if (access_held) access.release() catch {};
    try demonstrate_sqlite_open_contract(&access, current);

    var competing_gate: Gate = .{};
    var competing_copy_workspace: [128]u8 = undefined;
    var competing_store = try sqlite_store.Store.init(
        init.io,
        temporary.dir,
        &competing_copy_workspace,
        competing_gate.lifecycle(),
        .{},
    );
    try expect_generation_blocks_recovery(&competing_store, &competing_gate);

    // Close every SQLite statement and connection before ending this lease.
    try access.release();
    access_held = false;
    const recovered = (try competing_store.recover()) orelse return error.MissingGeneration;
    if (!std.meta.eql(current, recovered) or competing_gate.held) {
        return error.RecoveryMismatch;
    }
    try expect_balanced_gate(&gate);
    try expect_balanced_gate(&competing_gate);
}

fn encode_snapshot(
    output: *[encoded_capacity_bytes]u8,
    page: *const [page_size_bytes]u8,
) !usize {
    var sink = ltx.SliceWriter.init(output);
    var compressed: [compressed_capacity_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(snapshot_header());
    try encoder.write_page(1, page);
    _ = try encoder.finish(try ltx.checksum_page(1, page));
    return sink.written().len;
}

fn apply_snapshot(store: *sqlite_store.Store, encoded: []const u8) !ltx.VerifiedLTX {
    var source = ltx.SliceReader.init(encoded);
    var page: [page_size_bytes]u8 = undefined;
    var compressed: [compressed_capacity_bytes]u8 = undefined;
    var index: [1]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        codec_limits,
        apply_limits,
        .replace_snapshot,
        source.reader(),
        store.backend(),
        &page,
        &compressed,
        &index,
    );
    const verified = try applier.apply();
    if (applier.current_state() != .published or store.current_state() != .idle) {
        return error.UnexpectedApplyState;
    }
    return verified;
}

fn demonstrate_sqlite_open_contract(
    access: *const sqlite_store.GenerationAccess,
    expected: sqlite_store.Current,
) !void {
    if (!std.meta.eql(try access.current(), expected)) return error.GenerationChanged;
    const spec = try access.sqlite_open_spec();
    if (!std.mem.startsWith(u8, spec.uri, "file:") or
        !std.mem.endsWith(u8, spec.uri, "?mode=ro&immutable=1") or
        std.mem.indexOf(u8, spec.uri, expected.database_name()) == null)
    {
        return error.InvalidSQLiteOpenURI;
    }
    const sqlite_open_readonly: c_int = 0x0000_0001;
    const sqlite_open_uri: c_int = 0x0000_0040;
    if ((spec.required_flags & (sqlite_open_readonly | sqlite_open_uri)) !=
        sqlite_open_readonly | sqlite_open_uri)
    {
        return error.InvalidSQLiteOpenFlags;
    }
    if (!std.mem.eql(u8, spec.query_only_sql, "PRAGMA query_only=ON")) {
        return error.InvalidSQLiteQueryOnlySQL;
    }
    // The host would open this URI, set query_only, use SQLite, then close it.
    // No SQLite symbols are needed to exercise the store and lease contract.
}

fn expect_generation_blocks_recovery(
    store: *sqlite_store.Store,
    gate: *const Gate,
) !void {
    _ = store.recover() catch |err| {
        if (err != error.StoreBusy) return err;
        if (store.current_state() != .recovery_required or
            store.last_failure() != .store_busy or !gate.held)
        {
            return error.LockDidNotBlockRecovery;
        }
        return;
    };
    return error.GenerationLockWasNotHeld;
}

fn expect_balanced_gate(gate: *const Gate) !void {
    if (gate.held or gate.quiesce_count == 0 or gate.quiesce_count != gate.release_count) {
        return error.UnbalancedLifecycleGate;
    }
}

fn make_sqlite_page() [page_size_bytes]u8 {
    var page: [page_size_bytes]u8 = @splat(0);
    @memcpy(page[0..16], "SQLite format 3\x00");
    std.mem.writeInt(u16, page[16..18], page_size_bytes, .big);
    page[18] = 1;
    page[19] = 1;
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
    std.mem.writeInt(u16, page[105..107], page_size_bytes, .big);
    return page;
}

fn snapshot_header() ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size_bytes,
        .commit = 1,
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
