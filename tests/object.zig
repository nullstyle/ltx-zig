//! `ltx_object` tests: the filesystem backend against the backend-agnostic
//! conformance suite, plus the exact Litestream on-disk layout.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");

const encoder_limits = ltx.Limits{
    .max_input_bytes = 4096,
    .max_output_bytes = 4096,
    .max_pages = 2,
    .max_page_size = 512,
    .max_compressed_page_size = 600,
    .max_page_index_bytes = 256,
    .max_page_index_entries = 2,
    .max_varint_bytes = 10,
    .max_transaction_span = 8,
};

fn file_info(
    level: u8,
    identity: ltx.FileIdentity,
    size_bytes: u64,
) ltx.FileInfo {
    return .{
        .level = level,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = size_bytes,
    };
}

fn read_object(
    client: object.Client,
    level: u8,
    identity: ltx.FileIdentity,
    size_bytes: u64,
    destination: []u8,
) object.Error![]const u8 {
    return client.read_all(file_info(level, identity, size_bytes), destination);
}

const FailingWriteBackend = struct {
    fail_write: bool = false,
    fail_finish: bool = false,
    write_count: u32 = 0,
    abort_count: u32 = 0,
    published: bool = false,

    fn session(self: *FailingWriteBackend) object.WriteSession {
        return object.WriteSession.init(.{
            .context = self,
            .write_fn = write,
            .finish_fn = finish,
            .abort_fn = abort,
        });
    }

    fn write(context: *anyopaque, bytes: []const u8) object.Error!void {
        const self: *FailingWriteBackend = @ptrCast(@alignCast(context));
        _ = bytes;
        self.write_count += 1;
        if (self.fail_write) return error.StorageFailure;
    }

    fn finish(context: *anyopaque) object.Error!void {
        const self: *FailingWriteBackend = @ptrCast(@alignCast(context));
        if (self.fail_finish) return error.StorageFailure;
        self.published = true;
    }

    fn abort(context: *anyopaque) void {
        const self: *FailingWriteBackend = @ptrCast(@alignCast(context));
        self.abort_count += 1;
    }
};

const FailingReadBackend = struct {
    bytes: []const u8,
    generation_bytes: []const u8 = "generation-1",
    invalid_generation_length_bytes: ?u8 = null,
    fail_at_call: ?u32 = null,
    call_count: u32 = 0,

    fn client(self: *FailingReadBackend) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .delete_fn = delete,
        };
    }

    fn list(
        _: *anyopaque,
        _: u8,
        _: ltx.TXID,
        destination: []ltx.FileInfo,
    ) object.Error![]const ltx.FileInfo {
        return destination[0..0];
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        expected_generation: ?object.ReadGeneration,
        offset_bytes: u64,
        destination: []u8,
    ) object.Error!object.ReadGeneration {
        const self: *FailingReadBackend = @ptrCast(@alignCast(context));
        self.call_count += 1;
        if (self.fail_at_call == self.call_count) return error.StorageFailure;
        if (info.size_bytes != self.bytes.len) return error.ObjectChanged;
        const generation = if (self.invalid_generation_length_bytes) |length_bytes|
            object.ReadGeneration{
                .bytes = undefined,
                .length_bytes = length_bytes,
            }
        else
            try object.ReadGeneration.init(self.generation_bytes);
        if (expected_generation) |expected| {
            if (!expected.eql(generation)) return error.ObjectChanged;
        }
        const offset = std.math.cast(usize, offset_bytes) orelse
            return error.InvalidReadRange;
        @memcpy(destination, self.bytes[offset..][0..destination.len]);
        return generation;
    }

    fn write(
        _: *anyopaque,
        _: u8,
        _: ltx.FileIdentity,
        _: i64,
        _: []const u8,
    ) object.Error!void {
        return error.StorageFailure;
    }

    fn delete(_: *anyopaque, _: []const ltx.FileInfo) object.Error!void {
        return error.StorageFailure;
    }
};

const SyncFault = struct {
    var call_count: u32 = 0;
    var fail_at: ?u32 = null;

    fn reset(target: ?u32) void {
        call_count = 0;
        fail_at = target;
    }

    fn file_sync(
        userdata: ?*anyopaque,
        file: std.Io.File,
    ) std.Io.File.SyncError!void {
        call_count += 1;
        if (fail_at == call_count) return error.InputOutput;
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

test "read generation enforces nonempty fixed-capacity receipts" {
    try std.testing.expectError(
        error.GenerationUnavailable,
        object.ReadGeneration.init(""),
    );
    var maximum: [object.max_read_generation_bytes]u8 = undefined;
    @memset(&maximum, 0xa5);
    const first = try object.ReadGeneration.init(&maximum);
    const second = try object.ReadGeneration.init(&maximum);
    try std.testing.expectEqual(maximum.len, first.value().len);
    try std.testing.expect(first.eql(second));

    var oversized: [object.max_read_generation_bytes + 1]u8 = undefined;
    @memset(&oversized, 0xa5);
    try std.testing.expectError(
        error.GenerationTooLarge,
        object.ReadGeneration.init(&oversized),
    );

    const identity = ltx.FileIdentity{
        .min_txid = .init(1),
        .max_txid = .init(1),
    };
    var destination: [1]u8 = undefined;
    var backend = FailingReadBackend{
        .bytes = "x",
        .invalid_generation_length_bytes = 0,
    };
    try std.testing.expectError(
        error.GenerationUnavailable,
        backend.client().read_range(
            file_info(0, identity, 1),
            0,
            &destination,
        ),
    );
    backend.invalid_generation_length_bytes = object.max_read_generation_bytes + 1;
    try std.testing.expectError(
        error.GenerationTooLarge,
        backend.client().read_range(
            file_info(0, identity, 1),
            0,
            &destination,
        ),
    );
}

fn fault_io(vtable: *std.Io.VTable, fail_at: ?u32) std.Io {
    SyncFault.reset(fail_at);
    vtable.* = std.testing.io.vtable.*;
    vtable.fileSync = SyncFault.file_sync;
    return .{ .userdata = std.testing.io.userdata, .vtable = vtable };
}

fn snapshot_header() ltx.Header {
    return .{
        .flags = 0,
        .page_size = 512,
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

test "object reader uses a one-byte window across the complete object" {
    var backend = FailingReadBackend{ .bytes = "bounded" };
    const identity = ltx.FileIdentity{
        .min_txid = .init(1),
        .max_txid = .init(1),
    };
    const info = file_info(0, identity, backend.bytes.len);
    var zero_info = info;
    zero_info.size_bytes = 0;
    var zero_destination: [0]u8 = .{};
    try std.testing.expectError(
        error.InvalidReadRange,
        backend.client().read_all(zero_info, &zero_destination),
    );
    var empty_workspace: [0]u8 = .{};
    try std.testing.expectError(
        error.ReadWorkspaceTooSmall,
        object.ObjectReader.init(backend.client(), info, &empty_workspace),
    );

    var workspace: [1]u8 = undefined;
    var source = try object.ObjectReader.init(backend.client(), info, &workspace);
    const reader = source.reader();
    try std.testing.expect(reader.backing_is_mutable);
    const backing = reader.backing_bytes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(workspace.len, backing.len);
    try std.testing.expectEqual(@intFromPtr(workspace[0..].ptr), @intFromPtr(backing.ptr));

    var output: ["bounded".len]u8 = undefined;
    var output_bytes: usize = 0;
    var iteration_count: usize = 0;
    while (!try reader.at_end()) : (iteration_count += 1) {
        try std.testing.expect(iteration_count < output.len);
        const count_bytes = try reader.read(output[output_bytes..]);
        try std.testing.expectEqual(@as(usize, 1), count_bytes);
        output_bytes += count_bytes;
    }
    try std.testing.expectEqual(output.len, output_bytes);
    try std.testing.expectEqualStrings("bounded", &output);
    try std.testing.expectEqual(@as(u32, output.len), backend.call_count);
    try std.testing.expectEqual(@as(usize, 0), try reader.read(output[0..1]));
    try std.testing.expectEqual(@as(?object.Error, null), source.failure());
}

test "object reader retains a range failure and remains poisoned" {
    var backend = FailingReadBackend{
        .bytes = "abcdef",
        .fail_at_call = 2,
    };
    const identity = ltx.FileIdentity{
        .min_txid = .init(2),
        .max_txid = .init(2),
    };
    var workspace: [2]u8 = undefined;
    var source = try object.ObjectReader.init(
        backend.client(),
        file_info(0, identity, backend.bytes.len),
        &workspace,
    );
    const reader = source.reader();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&output));
    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectEqual(error.StorageFailure, source.failure().?);
    try std.testing.expectEqual(@as(u32, 2), backend.call_count);

    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectError(error.InputFailure, reader.at_end());
    try std.testing.expectEqual(@as(u32, 2), backend.call_count);
}

test "object reader rejects an equal-size replacement and remains poisoned" {
    var backend = FailingReadBackend{ .bytes = "abcdef" };
    const identity = ltx.FileIdentity{
        .min_txid = .init(3),
        .max_txid = .init(3),
    };
    var workspace: [2]u8 = undefined;
    var source = try object.ObjectReader.init(
        backend.client(),
        file_info(0, identity, backend.bytes.len),
        &workspace,
    );
    const reader = source.reader();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&output));
    try std.testing.expectEqualStrings("ab", output[0..2]);

    backend.bytes = "UVWXYZ";
    backend.generation_bytes = "generation-2";
    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
    try std.testing.expectEqual(@as(u32, 2), backend.call_count);

    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectError(error.InputFailure, reader.at_end());
    try std.testing.expectEqual(@as(u32, 2), backend.call_count);
}

test "file write session keeps chunked bytes private until finish" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };

    var session = try client.begin_write(0, identity, 1234);
    try session.writer().write_all("chunked ");
    try session.writer().write_all("");
    try session.writer().write_all("object");

    var storage: [32]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(client, 0, identity, "chunked object".len, &storage),
    );
    try session.finish();
    try std.testing.expectEqual(object.WriteSessionState.final, session.current_state());
    try std.testing.expectError(error.InvalidState, session.finish());
    session.abort();
    try std.testing.expectEqualStrings(
        "chunked object",
        try read_object(client, 0, identity, "chunked object".len, &storage),
    );
}

test "two file clients isolate whole and session staging" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var first_store = try object.FileClient.init(temporary.dir, std.testing.io, "");
    var second_store = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const first = first_store.client();
    const second = second_store.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(9),
        .max_txid = ltx.TXID.init(9),
    };

    var session = try first.begin_write(0, identity, 9000);
    defer session.abort();
    try session.writer().write_all("session ");
    try second.write(0, identity, 9001, "whole object");

    var storage: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "whole object",
        try read_object(second, 0, identity, "whole object".len, &storage),
    );
    try session.writer().write_all("object");
    try std.testing.expectEqualStrings(
        "whole object",
        try read_object(second, 0, identity, "whole object".len, &storage),
    );
    try session.finish();
    try std.testing.expectEqualStrings(
        "session object",
        try read_object(second, 0, identity, "session object".len, &storage),
    );
}

test "file client retries synchronization of the complete created directory chain" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var vtable: std.Io.VTable = undefined;
    const io = fault_io(&vtable, 5);
    var store = try object.FileClient.init(temporary.dir, io, "nested/root");
    const client = store.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(7),
        .max_txid = ltx.TXID.init(7),
    };

    try std.testing.expectError(
        error.StorageFailure,
        client.write(0, identity, 0, "object"),
    );
    try std.testing.expectEqual(@as(u32, 5), SyncFault.call_count);
    var storage: [16]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(client, 0, identity, "object".len, &storage),
    );

    SyncFault.reset(5);
    try std.testing.expectError(
        error.StorageFailure,
        client.write(0, identity, 0, "object"),
    );
    try std.testing.expectEqual(@as(u32, 5), SyncFault.call_count);

    SyncFault.reset(null);
    try client.write(0, identity, 0, "object");
    try std.testing.expectEqualStrings(
        "object",
        try read_object(client, 0, identity, "object".len, &storage),
    );
}

test "file client retains objects after post-rename synchronization failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "ltx/0");
    var vtable: std.Io.VTable = undefined;
    const io = fault_io(&vtable, 5);
    var store = try object.FileClient.init(temporary.dir, io, "");
    const client = store.client();
    const whole_identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(11),
        .max_txid = ltx.TXID.init(11),
    };

    try std.testing.expectError(
        error.PublicationIndeterminate,
        client.write(0, whole_identity, 0, "whole"),
    );
    var storage: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "whole",
        try read_object(client, 0, whole_identity, "whole".len, &storage),
    );

    const session_identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(12),
        .max_txid = ltx.TXID.init(12),
    };
    SyncFault.reset(2);
    var session = try client.begin_write(0, session_identity, 0);
    try session.writer().write_all("streamed");
    try std.testing.expectError(error.PublicationIndeterminate, session.finish());
    try std.testing.expectEqual(object.WriteSessionState.failed, session.current_state());
    try std.testing.expectEqualStrings(
        "streamed",
        try read_object(client, 0, session_identity, "streamed".len, &storage),
    );

    var replacement = try client.begin_write(0, session_identity, 1);
    replacement.abort();
}

test "file write session reports bounded staging exhaustion" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "ltx/0");
    var candidate: u16 = 0;
    while (candidate < 256) : (candidate += 1) {
        var path_storage: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_storage,
            "ltx/0/000000000000000a-000000000000000a.ltx.tmp-{x:0>4}",
            .{candidate},
        );
        var file = try temporary.dir.createFile(std.testing.io, path, .{ .exclusive = true });
        file.close(std.testing.io);
    }
    var store = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = store.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(10),
        .max_txid = ltx.TXID.init(10),
    };

    try std.testing.expectError(
        error.StagingCapacityExceeded,
        client.begin_write(0, identity, 0),
    );
}

test "file write session aborts privately and enforces one active writer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(2),
    };

    var session = try client.begin_write(0, identity, 2000);
    try session.writer().write_all("private");
    try std.testing.expectError(
        error.InvalidState,
        client.begin_write(0, identity, 2000),
    );
    try std.testing.expectError(
        error.InvalidState,
        client.write(0, identity, 2000, "whole object"),
    );
    session.abort();
    session.abort();
    try std.testing.expectEqual(object.WriteSessionState.final, session.current_state());
    try std.testing.expectError(error.InvalidState, session.finish());
    try std.testing.expectError(error.OutputFailure, session.writer().write_all("late"));

    var storage: [16]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(client, 0, identity, 1, &storage),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(
            std.testing.io,
            "ltx/0/0000000000000002-0000000000000002.ltx.tmp-0000",
            .{},
        ),
    );
    var replacement = try client.begin_write(0, identity, 2001);
    replacement.abort();
}

test "file write session rejects offset overflow and cleans staging" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(3),
        .max_txid = ltx.TXID.init(3),
    };
    var session = try client.begin_write(0, identity, 0);
    file_client.write_offset_bytes = std.math.maxInt(u64);

    try std.testing.expectError(error.OutputFailure, session.writer().write_all("x"));
    try std.testing.expectEqual(object.WriteSessionState.failed, session.current_state());
    var storage: [1]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(client, 0, identity, 1, &storage),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(
            std.testing.io,
            "ltx/0/0000000000000003-0000000000000003.ltx.tmp-0000",
            .{},
        ),
    );
}

test "client reports the optional write session seam as unsupported" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    var client = file_client.client();
    try std.testing.expect(client.supports_write_sessions());
    client.begin_write_fn = null;
    try std.testing.expect(!client.supports_write_sessions());
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    try std.testing.expectError(
        error.WriteSessionUnsupported,
        client.begin_write(0, identity, 0),
    );
    try std.testing.expectError(
        error.InvalidLevel,
        client.begin_write(ltx.max_level + 1, identity, 0),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        client.begin_write(0, .{ .min_txid = .init(2), .max_txid = .init(1) }, 0),
    );
}

test "encoder streams a Go-compatible object through a file write session" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    var session = try client.begin_write(0, identity, 0);
    errdefer session.abort();
    var compressed: [600]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [2]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        encoder_limits,
        session.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(snapshot_header());
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    _ = try encoder.finish(try ltx.checksum_page(1, &page));
    try session.finish();

    var storage: [4096]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        @embedFile("fixtures/go_v3_snapshot_zero_page.ltx"),
        try read_object(
            client,
            0,
            identity,
            @embedFile("fixtures/go_v3_snapshot_zero_page.ltx").len,
            &storage,
        ),
    );
}

test "failed encoder output is aborted without publication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    var session = try client.begin_write(0, identity, 0);
    var compressed: [600]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [2]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        encoder_limits,
        session.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(snapshot_header());
    const page: [512]u8 = @splat(0);
    try std.testing.expectError(error.InvalidPageDataSize, encoder.write_page(1, page[0..511]));
    try std.testing.expectEqual(ltx.EncoderState.failed, encoder.current_state());
    session.abort();

    var storage: [4096]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(client, 0, identity, 1, &storage),
    );
}

test "write session poisons and aborts after an encoder output failure" {
    var backend = FailingWriteBackend{ .fail_write = true };
    var session = backend.session();
    var compressed: [600]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [2]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        encoder_limits,
        session.writer(),
        &compressed,
        &compression,
        &index,
    );

    try std.testing.expectError(error.OutputFailure, encoder.write_header(snapshot_header()));
    try std.testing.expectEqual(ltx.EncoderState.failed, encoder.current_state());
    try std.testing.expectEqual(object.WriteSessionState.failed, session.current_state());
    try std.testing.expectEqual(@as(u32, 1), backend.abort_count);
    try std.testing.expect(!backend.published);
    try std.testing.expectError(error.InvalidState, session.finish());
    session.abort();
    try std.testing.expectEqual(@as(u32, 1), backend.abort_count);
}

test "write session poisons and aborts after finish failure" {
    var backend = FailingWriteBackend{ .fail_finish = true };
    var session = backend.session();
    try session.writer().write_all("private");

    try std.testing.expectError(error.StorageFailure, session.finish());
    try std.testing.expectEqual(object.WriteSessionState.failed, session.current_state());
    try std.testing.expectEqual(@as(u32, 1), backend.write_count);
    try std.testing.expectEqual(@as(u32, 1), backend.abort_count);
    try std.testing.expect(!backend.published);
    try std.testing.expectError(error.InvalidState, session.finish());
}

test "file client passes the backend conformance suite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    try object.run_conformance(file_client.client());

    // The suite cleaned up after itself: levels 0 and 1 are empty again.
    var infos: [8]ltx.FileInfo = undefined;
    var client = file_client.client();
    try std.testing.expectEqual(
        @as(usize, 0),
        (try client.list(0, ltx.TXID.init(0), &infos)).len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try client.list(1, ltx.TXID.init(0), &infos)).len,
    );
}

test "file client writes the litestream filesystem layout" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    try client.write(0, identity, 1234, "snapshot bytes");
    _ = try temporary.dir.statFile(
        std.testing.io,
        "replica/ltx/0/0000000000000001-0000000000000001.ltx",
        .{},
    );
    // No temporary file survives publication.
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(
            std.testing.io,
            "replica/ltx/0/0000000000000001-0000000000000001.ltx.tmp",
            .{},
        ),
    );

    var storage: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "snapshot bytes",
        try read_object(client, 0, identity, "snapshot bytes".len, &storage),
    );
    var infos: [1]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(u64, "snapshot bytes".len), listed[0].size_bytes);
    var prefix: [4]u8 = undefined;
    try client.read_range(listed[0], 0, &prefix);
    try std.testing.expectEqualStrings("snap", &prefix);
    var middle: [4]u8 = undefined;
    try client.read_range(listed[0], 5, &middle);
    try std.testing.expectEqualStrings("hot ", &middle);
    var suffix: [2]u8 = undefined;
    try client.read_range(listed[0], listed[0].size_bytes - suffix.len, &suffix);
    try std.testing.expectEqualStrings("es", &suffix);

    var small: [4]u8 = undefined;
    try std.testing.expectError(
        error.ObjectTooLarge,
        read_object(client, 0, identity, "snapshot bytes".len, &small),
    );
    var stale = listed[0];
    stale.size_bytes -= 1;
    try std.testing.expectError(error.ObjectChanged, client.read_range(stale, 0, small[0..1]));
    try std.testing.expectError(
        error.InvalidReadRange,
        client.read_range(listed[0], listed[0].size_bytes, small[0..1]),
    );
    try std.testing.expectError(
        error.ObjectNotFound,
        read_object(
            client,
            0,
            .{ .min_txid = ltx.TXID.init(9), .max_txid = ltx.TXID.init(9) },
            1,
            &storage,
        ),
    );
}

test "file object reader rejects an equal-size rename replacement" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(21),
        .max_txid = ltx.TXID.init(21),
    };
    try client.write(0, identity, 1, "abcdef");

    var workspace: [2]u8 = undefined;
    var source = try object.ObjectReader.init(
        client,
        file_info(0, identity, "abcdef".len),
        &workspace,
    );
    const reader = source.reader();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&output));
    try client.write(0, identity, 2, "UVWXYZ");

    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
}

test "file object reader rejects same-path in-place mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(22),
        .max_txid = ltx.TXID.init(22),
    };
    try client.write(0, identity, 1, "abcdef");

    var workspace: [2]u8 = undefined;
    var source = try object.ObjectReader.init(
        client,
        file_info(0, identity, "abcdef".len),
        &workspace,
    );
    const reader = source.reader();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(&output));

    var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try ltx.format_file_path("", 0, identity, &path_storage);
    {
        const file = try temporary.dir.openFile(
            std.testing.io,
            path,
            .{ .mode = .read_write },
        );
        defer file.close(std.testing.io);
        const before = try file.stat(std.testing.io);
        try file.writePositionalAll(std.testing.io, "ZZ", 2);
        try file.setTimestamps(std.testing.io, .{
            .modify_timestamp = .{ .new = .{
                .nanoseconds = before.mtime.nanoseconds + 2 * std.time.ns_per_s,
            } },
        });
    }

    try std.testing.expectError(error.InputFailure, reader.read(output[2..]));
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
}

test "file object readers keep independent interleaved generations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    const client = file_client.client();
    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(31),
        .max_txid = ltx.TXID.init(31),
    };
    const second = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(32),
        .max_txid = ltx.TXID.init(32),
    };
    try client.write(0, first, 1, "abc");
    try client.write(0, second, 1, "XYZ");

    var first_workspace: [1]u8 = undefined;
    var second_workspace: [1]u8 = undefined;
    var first_source = try object.ObjectReader.init(
        client,
        file_info(0, first, 3),
        &first_workspace,
    );
    var second_source = try object.ObjectReader.init(
        client,
        file_info(0, second, 3),
        &second_workspace,
    );
    const first_reader = first_source.reader();
    const second_reader = second_source.reader();
    var first_output: [3]u8 = undefined;
    var second_output: [3]u8 = undefined;
    for (0..3) |index| {
        try std.testing.expectEqual(
            @as(usize, 1),
            try first_reader.read(first_output[index..]),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            try second_reader.read(second_output[index..]),
        );
    }
    try std.testing.expectEqualStrings("abc", &first_output);
    try std.testing.expectEqualStrings("XYZ", &second_output);
    try std.testing.expectEqual(@as(?object.Error, null), first_source.failure());
    try std.testing.expectEqual(@as(?object.Error, null), second_source.failure());
}

test "file client ignores foreign and hidden files when listing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    var client = file_client.client();
    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const second = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(5),
    };
    try client.write(0, first, 1, "one");
    try client.write(0, second, 2, "two");

    // Foreign names in the level directory are ignored by listings.
    const foreign = try temporary.dir.createFile(std.testing.io, "ltx/0/README.md", .{});
    foreign.close(std.testing.io);
    const stale = try temporary.dir.createFile(
        std.testing.io,
        "ltx/0/0000000000000001-0000000000000001.ltx.tmp",
        .{ .truncate = true },
    );
    stale.close(std.testing.io);

    var infos: [4]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqual(@as(u64, 1), listed[0].min_txid.value);
    try std.testing.expectEqual(@as(u64, 1), listed[0].max_txid.value);
    try std.testing.expectEqual(@as(u64, 3), listed[0].size_bytes);
    try std.testing.expectEqual(@as(u64, 2), listed[1].min_txid.value);
    try std.testing.expectEqual(@as(u64, 5), listed[1].max_txid.value);
    try std.testing.expectEqual(@as(u64, 3), listed[1].size_bytes);
}
