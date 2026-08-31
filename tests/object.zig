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
    try std.testing.expectError(error.ObjectNotFound, client.open(0, identity, &storage));
    try session.finish();
    try std.testing.expectEqual(object.WriteSessionState.final, session.current_state());
    try std.testing.expectError(error.InvalidState, session.finish());
    session.abort();
    try std.testing.expectEqualStrings("chunked object", try client.open(0, identity, &storage));
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
        try second.open(0, identity, &storage),
    );
    try session.writer().write_all("object");
    try std.testing.expectEqualStrings(
        "whole object",
        try second.open(0, identity, &storage),
    );
    try session.finish();
    try std.testing.expectEqualStrings(
        "session object",
        try second.open(0, identity, &storage),
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
    try std.testing.expectError(error.ObjectNotFound, client.open(0, identity, &storage));

    SyncFault.reset(5);
    try std.testing.expectError(
        error.StorageFailure,
        client.write(0, identity, 0, "object"),
    );
    try std.testing.expectEqual(@as(u32, 5), SyncFault.call_count);

    SyncFault.reset(null);
    try client.write(0, identity, 0, "object");
    try std.testing.expectEqualStrings("object", try client.open(0, identity, &storage));
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
        try client.open(0, whole_identity, &storage),
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
        try client.open(0, session_identity, &storage),
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
    try std.testing.expectError(error.ObjectNotFound, client.open(0, identity, &storage));
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
    try std.testing.expectError(error.ObjectNotFound, client.open(0, identity, &storage));
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
        try client.open(0, identity, &storage),
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
    try std.testing.expectError(error.ObjectNotFound, client.open(0, identity, &storage));
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
        try client.open(0, identity, &storage),
    );
    var infos: [1]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(u64, "snapshot bytes".len), listed[0].size_bytes);
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.ObjectTooLarge, client.open(0, identity, &small));
    try std.testing.expectError(
        error.ObjectNotFound,
        client.open(0, .{ .min_txid = ltx.TXID.init(9), .max_txid = ltx.TXID.init(9) }, &storage),
    );
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
